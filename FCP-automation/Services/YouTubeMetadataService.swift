import Foundation

/// YouTubeアップロード用メタデータ（タイトル・概要・タグ・チャプター）をAI生成
class YouTubeMetadataService {

    func generateMetadata(project: YouTubeProject) async throws -> YouTubeMetadata {
        guard let analysis = project.storyAnalysis else {
            throw MetadataError.noAnalysis
        }

        // チャプタータイムスタンプ: タイムラインから正確に計算
        let chapters = calculateChapterTimestamps(analysis: analysis, clips: project.clips)

        // 全クリップの文字起こしテキストを結合
        let allText = project.clips.compactMap { clip -> String? in
            clip.bestTranscription?.segments.map(\.text).joined()
        }.joined(separator: "\n")

        let summaryText = allText.count > 5000
            ? String(allText.prefix(2500)) + "\n...\n" + String(allText.suffix(2500))
            : allText

        // AI呼び出し: タイトル・概要・タグを一括生成
        let claude = try ClaudeAPIService()

        let prompt = """
        以下は動画の文字起こしとストーリー分析の結果です。YouTube用のメタデータを生成してください。

        【ストーリー概要】: \(analysis.summary)
        【チャプター】: \(analysis.chapters.map(\.title).joined(separator: " → "))
        【動画の推定尺】: \(Int(analysis.estimatedDuration / 60))分

        【出力JSON】:
        {
          "title": "動画タイトル（50文字以内、視聴者の興味を引く）",
          "description": "動画概要（2-3行の説明 + 主なトピック箇条書き5-8個）",
          "tags": ["タグ1", "タグ2", "タグ3"]
        }

        - JSON以外のテキストは出力しないでください
        - tagsは検索されやすいキーワード5-10個
        - titleは日本語で、視聴者クリックを誘う表現

        文字起こし:
        \(summaryText)
        """

        let response = try await claude.sendPrompt(prompt)

        // JSONパース
        let parsed = try parseMetadataJSON(response)

        return YouTubeMetadata(
            title: parsed.title,
            description: parsed.description,
            tags: parsed.tags,
            chapters: chapters
        )
    }

    // MARK: - Chapter Timestamps

    private func calculateChapterTimestamps(analysis: StoryAnalysis, clips: [ProjectClip]) -> [YouTubeMetadata.ChapterEntry] {
        let segments = TimelineCalculator.buildTimelineSegments(analysis: analysis, clips: clips)
        guard !segments.isEmpty, !analysis.chapters.isEmpty else { return [] }

        let totalDuration = segments.last?.timelineEnd ?? 0
        let chapterCount = analysis.chapters.count

        // セクションをチャプター数で均等分割してタイムスタンプを算出
        var entries: [YouTubeMetadata.ChapterEntry] = []
        let durationPerChapter = totalDuration / Double(chapterCount)

        for (i, chapter) in analysis.chapters.enumerated() {
            let timestamp = durationPerChapter * Double(i)
            let mins = Int(timestamp) / 60
            let secs = Int(timestamp) % 60
            entries.append(YouTubeMetadata.ChapterEntry(
                timestamp: String(format: "%d:%02d", mins, secs),
                title: chapter.title
            ))
        }

        // 先頭が0:00でない場合は修正
        if let first = entries.first, first.timestamp != "0:00" {
            entries[0].timestamp = "0:00"
        }

        return entries
    }

    // MARK: - JSON Parse

    private struct MetadataDTO: Codable {
        let title: String
        let description: String
        let tags: [String]
    }

    private func parseMetadataJSON(_ response: String) throws -> MetadataDTO {
        // JSONブロックを抽出
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw MetadataError.parseFailed
        }
        return try JSONDecoder().decode(MetadataDTO.self, from: data)
    }

    private func extractJSON(from text: String) -> String {
        // ```json ... ``` ブロックまたは { ... } を抽出
        if let start = text.range(of: "{"),
           let end = text.range(of: "}", options: .backwards) {
            return String(text[start.lowerBound...end.upperBound])
        }
        return text
    }

    // MARK: - Errors

    enum MetadataError: LocalizedError {
        case noAnalysis
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .noAnalysis: return "ストーリー分析結果がありません"
            case .parseFailed: return "メタデータJSONのパースに失敗しました"
            }
        }
    }
}

