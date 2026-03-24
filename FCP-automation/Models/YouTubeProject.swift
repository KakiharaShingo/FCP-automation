import Foundation

struct YouTubeProject: Identifiable {
    let id: UUID
    var name: String
    var clips: [ProjectClip]
    var targetDurationSeconds: TimeInterval?
    var storyAnalysis: StoryAnalysis?
    var createdAt: Date

    init(name: String, clips: [ProjectClip] = [], targetDurationSeconds: TimeInterval? = nil) {
        self.id = UUID()
        self.name = name
        self.clips = clips
        self.targetDurationSeconds = targetDurationSeconds
        self.storyAnalysis = nil
        self.createdAt = Date()
    }

    // MARK: - Computed Properties

    var totalRawDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.duration }
    }

    var totalClipCount: Int {
        clips.count
    }

    var allTranscriptionText: String {
        clips.compactMap { $0.reformattedResult?.fullText ?? $0.transcriptionResult?.fullText }
            .joined(separator: "\n\n")
    }

    /// ストーリー分析後の推定最終尺
    var estimatedFinalDuration: TimeInterval? {
        guard let analysis = storyAnalysis else { return nil }
        return analysis.keptSections.reduce(0.0) { total, section in
            total + (section.endTime - section.startTime)
        }
    }
}
