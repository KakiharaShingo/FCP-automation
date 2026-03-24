import Foundation

struct ProjectClip: Identifiable {
    let id: UUID
    var fileURL: URL
    var sortOrder: Int
    var creationDate: Date?
    var duration: TimeInterval
    var metadata: ClipMetadata

    // 処理結果
    var transcriptionResult: TranscriptionResult?
    var reformattedResult: TranscriptionResult?
    var silentSegments: [AudioSegment]
    var fillerSegments: [AudioSegment]
    var retakeSegments: [AudioSegment]
    var volumeGainDB: Float?  // ノーマライズ用ゲイン調整値 (dB)

    // パイプライン状態
    var pipelineState: ClipPipelineState

    init(fileURL: URL, sortOrder: Int = 0) {
        self.id = UUID()
        self.fileURL = fileURL
        self.sortOrder = sortOrder
        self.creationDate = nil
        self.duration = 0
        self.metadata = ClipMetadata()
        self.transcriptionResult = nil
        self.reformattedResult = nil
        self.silentSegments = []
        self.fillerSegments = []
        self.retakeSegments = []
        self.volumeGainDB = nil
        self.pipelineState = ClipPipelineState()
    }

    var fileName: String {
        fileURL.lastPathComponent
    }

    var displayName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    /// このクリップの全カットセグメント（無音+フィラー+リテイク）
    var allCutSegments: [AudioSegment] {
        silentSegments + fillerSegments + retakeSegments
    }

    /// 使用する文字起こし結果（AI整形済みがあればそちら優先）
    var bestTranscription: TranscriptionResult? {
        reformattedResult ?? transcriptionResult
    }

    /// Bロール判定: 文字起こし完了済みかつ結果が空/極短（無音・環境音のみのクリップ）
    var isBRoll: Bool {
        // 文字起こし未完了なら判定不可 → Bロールではない
        guard pipelineState.transcription == .completed else { return false }
        guard let transcription = bestTranscription else {
            // 文字起こし完了したが結果がnil → 全セグメントがフィルタ除去された → Bロール
            return true
        }
        // セグメントが空、または合計テキストが極端に短い（5文字以下）
        if transcription.segments.isEmpty { return true }
        let totalText = transcription.segments.map(\.text).joined()
        return totalText.count <= 5
    }
}

// MARK: - Pipeline State

struct ClipPipelineState {
    var transcription: StepStatus = .pending
    var reformat: StepStatus = .pending
    var audioAnalysis: StepStatus = .pending

    enum StepStatus: String {
        case pending = "待機中"
        case inProgress = "処理中"
        case completed = "完了"
        case failed = "失敗"
        case skipped = "スキップ"

        var icon: String {
            switch self {
            case .pending: return "circle.dashed"
            case .inProgress: return "arrow.triangle.2.circlepath"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.circle.fill"
            case .skipped: return "forward.fill"
            }
        }

        var isTerminal: Bool {
            self == .completed || self == .failed || self == .skipped
        }
    }

    var isAllCompleted: Bool {
        transcription.isTerminal && reformat.isTerminal && audioAnalysis.isTerminal
    }

    var overallProgress: Double {
        let steps: [StepStatus] = [transcription, reformat, audioAnalysis]
        let completed = steps.filter { $0.isTerminal }.count
        return Double(completed) / Double(steps.count)
    }
}
