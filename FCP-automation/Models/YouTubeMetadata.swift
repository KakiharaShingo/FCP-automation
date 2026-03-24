import Foundation

struct YouTubeMetadata {
    var title: String
    var description: String
    var tags: [String]
    var chapters: [ChapterEntry]

    struct ChapterEntry {
        var timestamp: String   // "0:00", "3:45" etc.
        var title: String
    }

    /// YouTube概要欄テキスト（チャプター＋概要＋タグ）
    var fullDescriptionText: String {
        var lines: [String] = []

        if !description.isEmpty {
            lines.append(description)
            lines.append("")
        }

        if !chapters.isEmpty {
            lines.append("--- チャプター ---")
            for chapter in chapters {
                lines.append("\(chapter.timestamp) \(chapter.title)")
            }
            lines.append("")
        }

        if !tags.isEmpty {
            lines.append(tags.map { "#\($0)" }.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }
}
