import Foundation

struct TimelineItem: Identifiable, Codable {
    let id: UUID
    var fileName: String
    var fileURL: URL
    var startTime: TimeInterval
    var duration: TimeInterval
    var trackIndex: Int
    var clipType: ClipType
    var metadata: ClipMetadata

    init(fileName: String, fileURL: URL, startTime: TimeInterval = 0, duration: TimeInterval = 0,
         trackIndex: Int = 0, clipType: ClipType = .main, metadata: ClipMetadata = ClipMetadata()) {
        self.id = UUID()
        self.fileName = fileName
        self.fileURL = fileURL
        self.startTime = startTime
        self.duration = duration
        self.trackIndex = trackIndex
        self.clipType = clipType
        self.metadata = metadata
    }

    enum ClipType: String, Codable, CaseIterable {
        case main = "メイン"
        case bRoll = "Bロール"
        case insert = "インサート"
        case audio = "オーディオ"
    }
}

struct ClipMetadata: Codable {
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var codec: String = ""
    var hasAudio: Bool = true
    var hasVideo: Bool = true
    var fileSize: Int64 = 0
}
