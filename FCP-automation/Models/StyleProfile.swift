import Foundation

struct StyleProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var sourceURL: String
    var createdDate: Date
    var isDefault: Bool

    // 分析結果
    var pacing: String
    var chapterStyle: String
    var editingNotes: String
    var guidance: String  // analyzeStoryプロンプトに注入されるAI向け指示文

    // 元動画情報
    var videoTitle: String
    var videoDuration: TimeInterval

    init(
        name: String,
        sourceURL: String,
        videoTitle: String,
        videoDuration: TimeInterval,
        pacing: String,
        chapterStyle: String,
        editingNotes: String,
        guidance: String
    ) {
        self.id = UUID()
        self.name = name
        self.sourceURL = sourceURL
        self.createdDate = Date()
        self.isDefault = false
        self.pacing = pacing
        self.chapterStyle = chapterStyle
        self.editingNotes = editingNotes
        self.guidance = guidance
        self.videoTitle = videoTitle
        self.videoDuration = videoDuration
    }

    var durationFormatted: String {
        let mins = Int(videoDuration) / 60
        let secs = Int(videoDuration) % 60
        return "\(mins)分\(secs)秒"
    }
}
