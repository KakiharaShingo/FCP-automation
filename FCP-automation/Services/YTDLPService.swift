import Foundation

class YTDLPService {

    enum YTDLPError: LocalizedError {
        case notInstalled
        case executionFailed(String)
        case noSubtitles
        case invalidMetadata
        case noVideosFound

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "yt-dlpがインストールされていません。ターミナルで brew install yt-dlp を実行してください。"
            case .executionFailed(let reason):
                return "yt-dlp実行エラー: \(reason)"
            case .noSubtitles:
                return "字幕が取得できませんでした（自動字幕が無い動画の可能性があります）"
            case .invalidMetadata:
                return "動画メタデータの解析に失敗しました"
            case .noVideosFound:
                return "動画が見つかりませんでした"
            }
        }
    }

    struct YouTubeVideoInfo {
        let title: String
        let duration: TimeInterval
        let chapters: [Chapter]
        let subtitleText: String

        struct Chapter {
            let startTime: TimeInterval
            let endTime: TimeInterval
            let title: String
        }
    }

    // MARK: - Installation Check

    func checkInstallation() -> Bool {
        findYTDLP() != nil
    }

    private func findYTDLP() -> String? {
        let paths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Async Process Runner

    private func runProcess(executablePath: String, arguments: [String], collectStdout: Bool = true) async throws -> (stdout: Data, stderr: Data, status: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                if collectStdout {
                    process.standardOutput = outPipe
                } else {
                    process.standardOutput = FileHandle.nullDevice
                }
                process.standardError = errPipe

                do {
                    try process.run()

                    // Pipeバッファ(64KB)満杯によるデッドロック防止:
                    // waitUntilExit()の前にデータを読み取る
                    let outData = collectStdout ? outPipe.fileHandleForReading.readDataToEndOfFile() : Data()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                    process.waitUntilExit()

                    continuation.resume(returning: (outData, errData, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Channel Video Listing

    /// チャンネル/プレイリストURLから最新N本の動画URLを取得
    func listVideoURLs(channelURL: String, maxCount: Int = 5) async throws -> [String] {
        guard let ytdlpPath = findYTDLP() else {
            throw YTDLPError.notInstalled
        }

        let result = try await runProcess(executablePath: ytdlpPath, arguments: [
            "--flat-playlist",
            "--print", "url",
            "--playlist-end", "\(maxCount)",
            "--no-warnings",
            channelURL
        ])

        guard result.status == 0 else {
            let errMsg = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            throw YTDLPError.executionFailed(String(errMsg.suffix(300)))
        }

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        let urls = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !urls.isEmpty else { throw YTDLPError.noVideosFound }
        return urls
    }

    /// URLがチャンネル/プレイリストかどうかを判定
    func isChannelOrPlaylist(url: String) -> Bool {
        let patterns = ["/channel/", "/@", "/c/", "/user/", "/playlist?", "/videos"]
        return patterns.contains { url.contains($0) }
    }

    // MARK: - Multi-Video Info Extraction

    /// 複数動画の情報を並列取得（字幕取得失敗は個別スキップ）
    func extractMultipleInfos(
        urls: [String],
        progressCallback: @escaping (Int, Int) -> Void
    ) async throws -> [YouTubeVideoInfo] {
        var results: [YouTubeVideoInfo] = []
        for (i, url) in urls.enumerated() {
            progressCallback(i + 1, urls.count)
            do {
                let info = try await extractInfo(url: url)
                results.append(info)
            } catch YTDLPError.noSubtitles {
                // 字幕なしの動画はスキップ（メタデータだけでも取れるように）
                continue
            }
        }
        return results
    }

    // MARK: - Extract Info (Single Video)

    func extractInfo(url: String, progressCallback: ((String) -> Void)? = nil) async throws -> YouTubeVideoInfo {
        guard let ytdlpPath = findYTDLP() else {
            throw YTDLPError.notInstalled
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytdlp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // メタデータ取得
        progressCallback?("メタデータを取得中...")
        let metadata = try await fetchMetadata(ytdlpPath: ytdlpPath, url: url)
        progressCallback?("「\(metadata.title)」の字幕を取得中...")

        // 字幕取得
        let subtitleText = try await fetchSubtitles(ytdlpPath: ytdlpPath, url: url, tempDir: tempDir)
        progressCallback?("字幕取得完了（\(subtitleText.count)文字）")

        return YouTubeVideoInfo(
            title: metadata.title,
            duration: metadata.duration,
            chapters: metadata.chapters,
            subtitleText: subtitleText
        )
    }

    // MARK: - Metadata

    private func fetchMetadata(ytdlpPath: String, url: String) async throws -> (title: String, duration: TimeInterval, chapters: [YouTubeVideoInfo.Chapter]) {
        let result = try await runProcess(executablePath: ytdlpPath, arguments: ["--dump-json", "--no-warnings", url])

        guard result.status == 0 else {
            let errMsg = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            throw YTDLPError.executionFailed(String(errMsg.suffix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw YTDLPError.invalidMetadata
        }

        let title = json["title"] as? String ?? "不明"
        let duration = json["duration"] as? Double ?? 0

        var chapters: [YouTubeVideoInfo.Chapter] = []
        if let chaptersArray = json["chapters"] as? [[String: Any]] {
            chapters = chaptersArray.compactMap { ch in
                guard let startTime = ch["start_time"] as? Double,
                      let endTime = ch["end_time"] as? Double,
                      let title = ch["title"] as? String else { return nil }
                return YouTubeVideoInfo.Chapter(startTime: startTime, endTime: endTime, title: title)
            }
        }

        return (title, duration, chapters)
    }

    // MARK: - Subtitles

    private func fetchSubtitles(ytdlpPath: String, url: String, tempDir: URL) async throws -> String {
        _ = try await runProcess(executablePath: ytdlpPath, arguments: [
            "--write-auto-subs",
            "--sub-langs", "ja",
            "--sub-format", "vtt",
            "--skip-download",
            "--no-warnings",
            "-o", tempDir.appendingPathComponent("sub").path,
            url
        ], collectStdout: false)

        // 字幕ファイルを探す
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard let vttFile = files.first(where: { $0.pathExtension == "vtt" }) else {
            // 自動字幕がない場合
            throw YTDLPError.noSubtitles
        }

        let vttContent = try String(contentsOf: vttFile, encoding: .utf8)
        return parseVTTToPlainText(vttContent)
    }

    // MARK: - VTT Parser

    private func parseVTTToPlainText(_ vtt: String) -> String {
        let lines = vtt.components(separatedBy: "\n")
        var texts: [String] = []
        var prevLine = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // タイムスタンプ行、空行、ヘッダーをスキップ
            if trimmed.isEmpty || trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("Kind:") ||
               trimmed.hasPrefix("Language:") || trimmed.contains("-->") || trimmed.hasPrefix("NOTE") {
                continue
            }
            // HTMLタグを除去
            let cleaned = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if cleaned.isEmpty { continue }
            // 重複行を除去（VTTは重複が多い）
            if cleaned != prevLine {
                texts.append(cleaned)
                prevLine = cleaned
            }
        }

        return texts.joined(separator: "\n")
    }
}
