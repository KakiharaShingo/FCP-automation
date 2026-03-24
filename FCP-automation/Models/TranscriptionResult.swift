import Foundation

struct TranscriptionResult: Codable, Identifiable {
    let id: UUID
    var segments: [TranscriptionSegment]
    let language: String
    let duration: TimeInterval

    var fullText: String {
        segments.map { $0.text }.joined(separator: "")
    }

    init(segments: [TranscriptionSegment], language: String = "ja", duration: TimeInterval = 0) {
        self.id = UUID()
        self.segments = segments
        self.language = language
        self.duration = duration
    }

    // MARK: - Editing Operations

    mutating func updateText(segmentID: UUID, newText: String) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[idx].text = newText
    }

    mutating func deleteSegment(segmentID: UUID) {
        segments.removeAll { $0.id == segmentID }
    }

    mutating func splitSegment(segmentID: UUID, atTextPosition position: Int) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let segment = segments[idx]
        let text = segment.text

        guard position > 0 && position < text.count else { return }

        let splitIndex = text.index(text.startIndex, offsetBy: position)
        let firstText = String(text[..<splitIndex])
        let secondText = String(text[splitIndex...])

        // 時間をテキスト比率で按分
        let ratio = Double(position) / Double(text.count)
        let splitTime = segment.startTime + (segment.endTime - segment.startTime) * ratio

        let first = TranscriptionSegment(
            startTime: segment.startTime,
            endTime: splitTime,
            text: firstText
        )
        let second = TranscriptionSegment(
            startTime: splitTime,
            endTime: segment.endTime,
            text: secondText
        )

        segments.replaceSubrange(idx...idx, with: [first, second])
    }

    mutating func mergeWithNext(segmentID: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }),
              idx + 1 < segments.count else { return }

        let current = segments[idx]
        let next = segments[idx + 1]

        let merged = TranscriptionSegment(
            startTime: current.startTime,
            endTime: next.endTime,
            text: current.text + next.text
        )

        segments.replaceSubrange(idx...(idx + 1), with: [merged])
    }

    mutating func mergeWithPrevious(segmentID: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }),
              idx > 0 else { return }
        mergeWithNext(segmentID: segments[idx - 1].id)
    }

    func segmentIndex(for id: UUID) -> Int? {
        segments.firstIndex(where: { $0.id == id })
    }

    func currentSegment(at time: TimeInterval) -> TranscriptionSegment? {
        segments.first { time >= $0.startTime && time < $0.endTime }
    }
}

struct TranscriptionSegment: Codable, Identifiable, Equatable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var isDeleted: Bool

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, isDeleted: Bool = false) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isDeleted = isDeleted
    }

    var durationSeconds: TimeInterval {
        endTime - startTime
    }

    var formattedTimeRange: String {
        "\(Self.formatTime(startTime)) → \(Self.formatTime(endTime))"
    }

    var formattedStart: String {
        Self.formatTime(startTime)
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, ms)
    }

    static func == (lhs: TranscriptionSegment, rhs: TranscriptionSegment) -> Bool {
        lhs.id == rhs.id
    }
}
