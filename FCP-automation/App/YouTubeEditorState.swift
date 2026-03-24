import SwiftUI

@MainActor
class YouTubeEditorState: ObservableObject {
    // MARK: - Project
    @Published var project: YouTubeProject?

    // MARK: - Pipeline
    @Published var pipelinePhase: PipelinePhase = .idle
    @Published var overallProgress: Double = 0.0
    @Published var currentOperation: String = ""
    @Published var errorMessage: String?
    @Published var isCancelled: Bool = false
    var pipelineStartTime: Date?

    /// 残り時間の推定文字列
    var estimatedTimeRemaining: String? {
        guard let start = pipelineStartTime, overallProgress > 0.05, overallProgress < 1.0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let totalEstimate = elapsed / overallProgress
        let remaining = totalEstimate - elapsed
        guard remaining > 0 else { return nil }
        if remaining < 60 {
            return "残り約\(Int(remaining))秒"
        } else {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            return "残り約\(mins)分\(secs)秒"
        }
    }

    // MARK: - Review Selection
    @Published var selectedSection: SelectedSection?

    enum SelectedSection: Equatable {
        case kept(index: Int)
        case removed(index: Int)
    }

    // MARK: - Export
    @Published var exportSettings = ExportSettings()
    @Published var youtubeMetadata: YouTubeMetadata?
    @Published var isRendering: Bool = false
    @Published var renderProgress: Double = 0.0

    // MARK: - YouTube Upload
    @Published var isUploading: Bool = false
    @Published var uploadProgress: Double = 0.0
    @Published var uploadedVideoId: String?
    @Published var isAuthenticated: Bool = GoogleOAuthConfig.hasValidTokens

    // MARK: - Settings
    @Published var selectedGenrePreset: GenrePreset = .talk
    @Published var targetDurationMinutes: Double = 10.0
    @Published var enableTargetDuration: Bool = false
    @Published var subtitleStyle = SubtitleStyle()
    @Published var selectedStyleProfileID: UUID?
    @Published var selectedPluginPresetID: UUID?

    // MARK: - Pipeline Phase

    enum PipelinePhase: String, CaseIterable {
        case idle = "待機"
        case importing = "読込"
        case transcribing = "文字起こし"
        case reformatting = "AI整形"
        case analyzing = "音声解析"
        case storyAnalysis = "ストーリー分析"
        case review = "レビュー"
        case export = "エクスポート"

        var icon: String {
            switch self {
            case .idle: return "folder"
            case .importing: return "folder.badge.plus"
            case .transcribing: return "text.bubble"
            case .reformatting: return "wand.and.stars"
            case .analyzing: return "waveform"
            case .storyAnalysis: return "brain"
            case .review: return "eye"
            case .export: return "square.and.arrow.up"
            }
        }

        var stepIndex: Int {
            switch self {
            case .idle: return 0
            case .importing: return 1
            case .transcribing: return 2
            case .reformatting: return 3
            case .analyzing: return 4
            case .storyAnalysis: return 5
            case .review: return 6
            case .export: return 7
            }
        }

        static var processingPhases: [PipelinePhase] {
            [.importing, .transcribing, .reformatting, .analyzing, .storyAnalysis]
        }
    }

    // MARK: - Computed Properties

    var targetDurationSeconds: TimeInterval? {
        enableTargetDuration ? targetDurationMinutes * 60.0 : nil
    }

    var hasProject: Bool {
        project != nil
    }

    var clipCount: Int {
        project?.clips.count ?? 0
    }

    var allClipsProcessed: Bool {
        guard let project = project, !project.clips.isEmpty else { return false }
        return project.clips.allSatisfy { $0.pipelineState.isAllCompleted }
    }

    var hasStoryAnalysis: Bool {
        project?.storyAnalysis != nil
    }

    var isProcessing: Bool {
        PipelinePhase.processingPhases.contains(pipelinePhase)
    }

    // MARK: - Actions

    func reset() {
        isCancelled = true
        project = nil
        pipelinePhase = .idle
        overallProgress = 0.0
        currentOperation = ""
        errorMessage = nil
        isCancelled = false
    }

    func cancelPipeline() {
        isCancelled = true
        currentOperation = "停止中..."
    }

    func updateClipPipelineState(clipID: UUID, step: WritableKeyPath<ClipPipelineState, ClipPipelineState.StepStatus>, status: ClipPipelineState.StepStatus) {
        guard let idx = project?.clips.firstIndex(where: { $0.id == clipID }) else { return }
        project?.clips[idx].pipelineState[keyPath: step] = status
    }

    func updateOverallProgress() {
        guard let project = project, !project.clips.isEmpty else {
            overallProgress = 0.0
            return
        }
        let total = project.clips.reduce(0.0) { $0 + $1.pipelineState.overallProgress }
        overallProgress = total / Double(project.clips.count)
    }
}
