import SwiftUI
import AVFoundation
import Combine

@MainActor
class AppState: ObservableObject {
    // MARK: - Navigation
    @Published var selectedTab: TabItem = .transcription

    // MARK: - File State
    @Published var importedFileURL: URL?
    @Published var importedFileName: String = ""

    // MARK: - Transcription State
    @Published var transcriptionResult: TranscriptionResult?
    @Published var isTranscribing: Bool = false
    @Published var transcriptionProgress: Double = 0.0
    var transcriptionStartTime: Date?

    var transcriptionETA: String? {
        guard let start = transcriptionStartTime, transcriptionProgress > 0.05, transcriptionProgress < 1.0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = (elapsed / transcriptionProgress) - elapsed
        guard remaining > 0 else { return nil }
        if remaining < 60 {
            return "残り約\(Int(remaining))秒"
        } else {
            return "残り約\(Int(remaining) / 60)分\(Int(remaining) % 60)秒"
        }
    }

    // MARK: - Playback State
    @Published var player: AVPlayer?
    @Published var currentPlaybackTime: TimeInterval = 0.0
    @Published var isPlaying: Bool = false
    @Published var videoDuration: TimeInterval = 0.0
    @Published var currentSegmentID: UUID?

    private var timeObserver: Any?
    private var endPlaybackObserver: NSObjectProtocol?

    // MARK: - Audio Analysis State
    @Published var silentSegments: [AudioSegment] = []
    @Published var fillerSegments: [AudioSegment] = []
    @Published var isAnalyzing: Bool = false

    // MARK: - Timeline State
    @Published var timelineItems: [TimelineItem] = []

    // MARK: - Plugin State
    @Published var pluginPresets: [PluginPreset] = [] {
        didSet { savePluginPresets() }
    }

    // MARK: - Motion Template State
    @Published var motionTemplates: [MotionTemplate] = []
    @Published var isScanning: Bool = false

    // MARK: - AI Reformat State
    @Published var reformatProgress: Double = 0.0

    // MARK: - Settings
    @Published var whisperModelPath: String = ""
    @Published var isWhisperModelLoaded: Bool = false
    @Published var maxSegmentLength: Int = 40 {
        didSet { UserDefaults.standard.set(maxSegmentLength, forKey: "maxSegmentLength") }
    }

    /// Whisper速度プリセット: 0=高速, 1=バランス, 2=高精度
    @Published var whisperSpeedPreset: Int = 1 {
        didSet { UserDefaults.standard.set(whisperSpeedPreset, forKey: "whisperSpeedPreset") }
    }

    /// APIモデルモード: Sonnetタスクを強制的にHaikuで実行するかどうか
    @Published var forceHaikuMode: Bool = false {
        didSet { UserDefaults.standard.set(forceHaikuMode, forKey: "forceHaikuMode") }
    }

    /// ローカルLLMモード: Claude APIの代わりにOllama互換エンドポイントを使用
    @Published var useLocalLLM: Bool = false {
        didSet { UserDefaults.standard.set(useLocalLLM, forKey: "useLocalLLM") }
    }
    @Published var localLLMEndpoint: String = "http://localhost:11434" {
        didSet { UserDefaults.standard.set(localLLMEndpoint, forKey: "localLLMEndpoint") }
    }
    @Published var localLLMModel: String = "llama3.1:8b" {
        didSet { UserDefaults.standard.set(localLLMModel, forKey: "localLLMModel") }
    }

    // MARK: - Style Profiles
    @Published var styleProfiles: [StyleProfile] = [] {
        didSet { saveStyleProfiles() }
    }

    var defaultStyleProfile: StyleProfile? {
        styleProfiles.first { $0.isDefault }
    }

    private static let styleProfilesKey = "styleProfiles"

    func loadStyleProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Self.styleProfilesKey) else { return }
        styleProfiles = (try? JSONDecoder().decode([StyleProfile].self, from: data)) ?? []
    }

    private func saveStyleProfiles() {
        guard let data = try? JSONEncoder().encode(styleProfiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.styleProfilesKey)
    }

    // MARK: - Plugin Presets Persistence
    private static let pluginPresetsKey = "pluginPresets"

    func loadPluginPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.pluginPresetsKey) else { return }
        pluginPresets = (try? JSONDecoder().decode([PluginPreset].self, from: data)) ?? []
    }

    private func savePluginPresets() {
        guard let data = try? JSONEncoder().encode(pluginPresets) else { return }
        UserDefaults.standard.set(data, forKey: Self.pluginPresetsKey)
    }

    func loadSettings() {
        let saved = UserDefaults.standard.integer(forKey: "maxSegmentLength")
        maxSegmentLength = saved > 0 ? saved : 40
        whisperSpeedPreset = UserDefaults.standard.object(forKey: "whisperSpeedPreset") as? Int ?? 1
        forceHaikuMode = UserDefaults.standard.bool(forKey: "forceHaikuMode")
        useLocalLLM = UserDefaults.standard.bool(forKey: "useLocalLLM")
        localLLMEndpoint = UserDefaults.standard.string(forKey: "localLLMEndpoint") ?? "http://localhost:11434"
        localLLMModel = UserDefaults.standard.string(forKey: "localLLMModel") ?? "llama3.1:8b"
        loadStyleProfiles()
        loadPluginPresets()
        loadUserDictionary()
        scanMotionTemplates()
    }

    // MARK: - Motion Template Scanning

    func scanMotionTemplates() {
        isScanning = true
        Task.detached { [weak self] in
            let scanner = MotionTemplateScanner.shared
            let templates = scanner.scanAllPacks()
            await MainActor.run {
                self?.motionTemplates = templates
                self?.isScanning = false
            }
        }
    }

    /// タイトル系テンプレートのみ
    var titleTemplates: [MotionTemplate] {
        motionTemplates.filter { $0.templateType == .title }
    }

    /// エフェクト系テンプレートのみ
    var effectTemplates: [MotionTemplate] {
        motionTemplates.filter { $0.templateType == .effect }
    }

    /// パック名一覧（タイトル系）
    var titlePackNames: [String] {
        Array(Set(titleTemplates.map(\.packName))).sorted()
    }

    /// パック名一覧（エフェクト系）
    var effectPackNames: [String] {
        Array(Set(effectTemplates.map(\.packName))).sorted()
    }

    /// 指定パック・カテゴリのテンプレート
    func templates(pack: String, category: String? = nil, type: TemplateType? = nil) -> [MotionTemplate] {
        motionTemplates.filter { t in
            t.packName == pack &&
            (category == nil || t.category == category) &&
            (type == nil || t.templateType == type)
        }
    }

    /// カテゴリ一覧（指定パック内）
    func categories(pack: String, type: TemplateType? = nil) -> [String] {
        let filtered = motionTemplates.filter { t in
            t.packName == pack && (type == nil || t.templateType == type)
        }
        return Array(Set(filtered.map(\.category))).sorted()
    }

    // MARK: - User Dictionary
    @Published var userDictionary: [String] = [] {
        didSet { saveUserDictionary() }
    }

    private static let userDictionaryKey = "userDictionary"

    func loadUserDictionary() {
        userDictionary = UserDefaults.standard.stringArray(forKey: Self.userDictionaryKey) ?? []
    }

    private func saveUserDictionary() {
        UserDefaults.standard.set(userDictionary, forKey: Self.userDictionaryKey)
    }

    enum TabItem: String, CaseIterable {
        case transcription = "文字起こし"
        case editing = "無音カット"
        case timeline = "タイムライン"
        case plugins = "プラグイン"
        case export = "エクスポート"
        case youtubeEditor = "YouTube編集"

        var icon: String {
            switch self {
            case .transcription: return "text.bubble"
            case .editing: return "scissors"
            case .timeline: return "film"
            case .plugins: return "puzzlepiece.extension"
            case .export: return "square.and.arrow.up"
            case .youtubeEditor: return "play.rectangle.on.rectangle"
            }
        }
    }

    // MARK: - File Actions

    func importFile(url: URL) {
        // ディレクトリチェック
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            print("[AppState] ディレクトリが選択されました: \(url.path) — 動画ファイルを選択してください")
            return
        }
        // 前のデータを全てクリア
        reset()
        importedFileURL = url
        importedFileName = url.lastPathComponent
        setupPlayer(url: url)
    }

    func reset() {
        stopPlayback()
        removeTimeObserver()
        player = nil
        importedFileURL = nil
        importedFileName = ""
        transcriptionResult = nil
        isTranscribing = false
        transcriptionProgress = 0.0
        reformatProgress = 0.0
        currentPlaybackTime = 0.0
        isPlaying = false
        videoDuration = 0.0
        currentSegmentID = nil
        silentSegments = []
        fillerSegments = []
        isAnalyzing = false
        timelineItems = []
    }

    // MARK: - Playback Actions

    func setupPlayer(url: URL) {
        removeTimeObserver()
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        Task {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                self.videoDuration = CMTimeGetSeconds(duration)
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentPlaybackTime = CMTimeGetSeconds(time)
                self.updateCurrentSegment()
            }
        }

        if let oldObserver = endPlaybackObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func stopPlayback() {
        player?.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentPlaybackTime = time
        updateCurrentSegment()
    }

    func seekForward(_ seconds: TimeInterval = 5.0) {
        seek(to: min(currentPlaybackTime + seconds, videoDuration))
    }

    func seekBackward(_ seconds: TimeInterval = 5.0) {
        seek(to: max(currentPlaybackTime - seconds, 0))
    }

    func seekToSegment(_ segment: TranscriptionSegment) {
        seek(to: segment.startTime)
    }

    // MARK: - Segment Editing

    func updateSegmentText(segmentID: UUID, newText: String) {
        transcriptionResult?.updateText(segmentID: segmentID, newText: newText)
    }

    func deleteSegment(segmentID: UUID) {
        transcriptionResult?.deleteSegment(segmentID: segmentID)
    }

    func splitSegment(segmentID: UUID, atTextPosition position: Int) {
        transcriptionResult?.splitSegment(segmentID: segmentID, atTextPosition: position)
    }

    func mergeWithNext(segmentID: UUID) {
        transcriptionResult?.mergeWithNext(segmentID: segmentID)
    }

    func mergeWithPrevious(segmentID: UUID) {
        transcriptionResult?.mergeWithPrevious(segmentID: segmentID)
    }

    // MARK: - Private

    private func updateCurrentSegment() {
        guard let result = transcriptionResult else {
            currentSegmentID = nil
            return
        }
        let segment = result.currentSegment(at: currentPlaybackTime)
        if segment?.id != currentSegmentID {
            currentSegmentID = segment?.id
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
            endPlaybackObserver = nil
        }
    }

    // Note: timeObserver is cleaned up in removeTimeObserver() called from reset()
}
