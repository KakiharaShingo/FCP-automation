import Foundation

struct ExportSettings {
    // MARK: - Export Mode
    enum ExportMode: String, CaseIterable {
        case fcpxml = "FCP (FCPXML)"
        case directRender = "直接レンダリング (ffmpeg)"

        var icon: String {
            switch self {
            case .fcpxml: return "film.stack"
            case .directRender: return "video.badge.waveform"
            }
        }
    }

    var exportMode: ExportMode = .fcpxml

    // MARK: - Shared Settings
    var generateSRT: Bool = true
    var generateMetadata: Bool = true

    // MARK: - BGM
    var bgmFileURL: URL?
    var bgmVolumeDB: Float = -12.0  // BGM音量（メイン音声との相対値）

    // MARK: - Volume Normalization
    var applyVolumeNormalization: Bool = true
    var targetLoudnessDB: Float = -16.0  // YouTube推奨ラウドネス

    // MARK: - FCPXML-specific
    var insertTransitions: Bool = true
    var transitionDuration: TimeInterval = 0.5
    var autoBRollPlacement: Bool = true

    // MARK: - Direct Render specific
    var burnInSubtitles: Bool = false
    var outputFormat: String = "mp4"

    // MARK: - YouTube Upload
    var uploadToYouTube: Bool = false
    var privacyStatus: YouTubeUploadMetadata.PrivacyStatus = .private
    var categoryId: String = "22"  // People & Blogs
    var selectedThumbnailIndex: Int?

    static let `default` = ExportSettings()
}
