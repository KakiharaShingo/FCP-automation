import Foundation

/// ffmpegを使用して編集計画から直接動画をレンダリング
class FFmpegRenderService {

    enum RenderError: LocalizedError {
        case ffmpegNotFound
        case noAnalysis
        case renderFailed(String)
        case noSegments

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound: return "ffmpegが見つかりません。brew install ffmpeg を実行してください。"
            case .noAnalysis: return "ストーリー分析結果がありません"
            case .renderFailed(let reason): return "レンダリング失敗: \(reason)"
            case .noSegments: return "レンダリングするセグメントがありません"
            }
        }
    }

    private let ffmpegPath: String

    init() throws {
        guard let path = Self.findFFmpeg() else {
            throw RenderError.ffmpegNotFound
        }
        self.ffmpegPath = path
    }

    /// 編集計画に基づいて動画をレンダリング
    func render(
        project: YouTubeProject,
        exportSettings: ExportSettings,
        srtURL: URL?,
        outputURL: URL,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let analysis = project.storyAnalysis else {
            throw RenderError.noAnalysis
        }

        let segments = TimelineCalculator.buildTimelineSegments(analysis: analysis, clips: project.clips)
        guard !segments.isEmpty else {
            throw RenderError.noSegments
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcp-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1: セグメントを個別に切り出し
        print("[FFmpegRender] Step 1: セグメント切り出し (\(segments.count)個)")
        var segmentFiles: [URL] = []

        for (i, segment) in segments.enumerated() {
            let clip = project.clips[segment.clipIndex]
            let outputFile = tempDir.appendingPathComponent("seg_\(String(format: "%04d", i)).mp4")

            let gainDB = exportSettings.applyVolumeNormalization ? (clip.volumeGainDB ?? 0) : 0

            var args = [
                "-ss", String(format: "%.3f", segment.sourceStart),
                "-to", String(format: "%.3f", segment.sourceEnd),
                "-i", clip.fileURL.path,
                "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            ]

            if gainDB != 0 {
                args += ["-af", "volume=\(String(format: "%.1f", gainDB))dB",
                         "-c:a", "aac", "-b:a", "192k"]
            } else {
                args += ["-c:a", "aac", "-b:a", "192k"]
            }

            args += ["-y", outputFile.path]

            try await runFFmpeg(args: args)
            segmentFiles.append(outputFile)

            await MainActor.run {
                progressCallback(Double(i + 1) / Double(segments.count) * 0.6)
            }
        }

        // Step 2: concat リストファイル作成
        print("[FFmpegRender] Step 2: セグメント結合")
        let concatListURL = tempDir.appendingPathComponent("concat.txt")
        let concatContent = segmentFiles.map { "file '\($0.path)'" }.joined(separator: "\n")
        try concatContent.write(to: concatListURL, atomically: true, encoding: .utf8)

        let concatOutput = tempDir.appendingPathComponent("concat_output.mp4")
        try await runFFmpeg(args: [
            "-f", "concat", "-safe", "0",
            "-i", concatListURL.path,
            "-c", "copy",
            "-y", concatOutput.path
        ])
        await MainActor.run { progressCallback(0.7) }

        // Step 3: BGM合成（オプション）
        var currentOutput = concatOutput
        if let bgmURL = exportSettings.bgmFileURL {
            print("[FFmpegRender] Step 3: BGM合成")
            let bgmOutput = tempDir.appendingPathComponent("with_bgm.mp4")
            let bgmVol = String(format: "%.1f", pow(10, exportSettings.bgmVolumeDB / 20))

            try await runFFmpeg(args: [
                "-i", currentOutput.path,
                "-stream_loop", "-1", "-i", bgmURL.path,
                "-filter_complex",
                "[0:a]volume=1.0[voice];[1:a]volume=\(bgmVol)[bgm];[voice][bgm]amix=inputs=2:duration=first[out]",
                "-map", "0:v", "-map", "[out]",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                "-shortest",
                "-y", bgmOutput.path
            ])
            currentOutput = bgmOutput
            await MainActor.run { progressCallback(0.8) }
        }

        // Step 4: 字幕焼き込み（オプション）
        if exportSettings.burnInSubtitles, let srtURL = srtURL {
            print("[FFmpegRender] Step 4: 字幕焼き込み")
            let subtitleOutput = tempDir.appendingPathComponent("with_subs.mp4")
            // SRTパスのエスケープ（ffmpeg subtitlesフィルタ用）
            let escapedSRT = srtURL.path
                .replacingOccurrences(of: ":", with: "\\:")
                .replacingOccurrences(of: "'", with: "\\'")

            try await runFFmpeg(args: [
                "-i", currentOutput.path,
                "-vf", "subtitles='\(escapedSRT)':force_style='FontSize=22,PrimaryColour=&Hffffff,OutlineColour=&H000000,Outline=2,MarginV=30'",
                "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                "-c:a", "copy",
                "-y", subtitleOutput.path
            ])
            currentOutput = subtitleOutput
            await MainActor.run { progressCallback(0.9) }
        }

        // Step 5: 最終出力にコピー
        print("[FFmpegRender] Step 5: 出力ファイル生成")
        if currentOutput != outputURL {
            try FileManager.default.copyItem(at: currentOutput, to: outputURL)
        }

        await MainActor.run { progressCallback(1.0) }
        print("[FFmpegRender] 完了: \(outputURL.lastPathComponent)")
    }

    // MARK: - FFmpeg Execution

    private func runFFmpeg(args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw RenderError.renderFailed(String(errMsg.suffix(500)))
        }
    }

    // MARK: - FFmpeg Discovery

    private static func findFFmpeg() -> String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}
