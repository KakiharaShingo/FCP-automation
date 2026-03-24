import Foundation

struct AudioSegment: Identifiable, Codable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let type: SegmentType
    let label: String

    init(startTime: TimeInterval, endTime: TimeInterval, type: SegmentType, label: String = "") {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.type = type
        self.label = label
    }

    var duration: TimeInterval {
        endTime - startTime
    }

    var formattedTimeRange: String {
        "\(TranscriptionSegment.formatTime(startTime)) → \(TranscriptionSegment.formatTime(endTime))"
    }

    enum SegmentType: String, Codable {
        case silence = "無音"
        case fillerWord = "フィラーワード"
        case speech = "発話"
        case retake = "リテイク"
    }
}
