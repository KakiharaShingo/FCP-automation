import Foundation

/// 編集計画に基づくSRT字幕ファイルを生成
class SRTGenerator {

    /// SRTファイルを生成してURLを返す
    /// - Parameters:
    ///   - project: YouTubeProject（クリップ＋ストーリー分析）
    ///   - outputURL: 保存先URL（nilならtempディレクトリに生成）
    /// - Returns: 生成されたSRTファイルのURL
    func generate(project: YouTubeProject, outputURL: URL? = nil) throws -> URL {
        guard let analysis = project.storyAnalysis else {
            throw SRTError.noAnalysis
        }

        let segments = TimelineCalculator.buildTimelineSegments(analysis: analysis, clips: project.clips)
        var srtEntries: [SRTEntry] = []
        var entryIndex = 1

        for segment in segments {
            guard segment.clipIndex >= 0, segment.clipIndex < project.clips.count else { continue }
            let clip = project.clips[segment.clipIndex]
            guard let transcription = clip.bestTranscription else { continue }

            // このセグメントのソース範囲に重なる文字起こしセグメントを取得
            let overlapping = transcription.segments.filter { ts in
                ts.endTime > segment.sourceStart && ts.startTime < segment.sourceEnd
            }

            for ts in overlapping {
                // ソース時間からタイムライン時間に変換
                let relativeStart = max(0, ts.startTime - segment.sourceStart)
                let relativeEnd = min(segment.sourceDuration, ts.endTime - segment.sourceStart)

                let timelineStart = segment.timelineStart + relativeStart
                let timelineEnd = segment.timelineStart + relativeEnd

                guard timelineEnd > timelineStart else { continue }

                srtEntries.append(SRTEntry(
                    index: entryIndex,
                    startTime: timelineStart,
                    endTime: timelineEnd,
                    text: ts.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                entryIndex += 1
            }
        }

        let srtContent = srtEntries.map(\.srtString).joined(separator: "\n\n")

        let url = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".srt")

        try srtContent.write(to: url, atomically: true, encoding: .utf8)
        print("[SRTGenerator] \(srtEntries.count)エントリ生成 → \(url.lastPathComponent)")
        return url
    }

    // MARK: - Types

    enum SRTError: LocalizedError {
        case noAnalysis

        var errorDescription: String? {
            switch self {
            case .noAnalysis: return "ストーリー分析結果がありません"
            }
        }
    }

    private struct SRTEntry {
        let index: Int
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String

        var srtString: String {
            "\(index)\n\(formatSRTTime(startTime)) --> \(formatSRTTime(endTime))\n\(text)"
        }

        private func formatSRTTime(_ time: TimeInterval) -> String {
            let hours = Int(time) / 3600
            let minutes = (Int(time) % 3600) / 60
            let seconds = Int(time) % 60
            let millis = Int((time - Double(Int(time))) * 1000)
            return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
        }
    }
}
