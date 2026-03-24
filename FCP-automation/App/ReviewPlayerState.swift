import AVFoundation
import SwiftUI

@MainActor
class ReviewPlayerState: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var currentSubtitle: String = ""
    @Published var currentClipIndex: Int = -1
    @Published var previewStartTime: TimeInterval = 0
    @Published var previewEndTime: TimeInterval = 0

    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var clips: [ProjectClip] = []
    private var sequentialSections: [KeptSection] = []
    private var sequentialIndex: Int = 0
    @Published var isSequentialPreview = false

    // MARK: - Setup

    func setClips(_ clips: [ProjectClip]) {
        self.clips = clips
    }

    // MARK: - Preview Section

    func previewSection(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval) {
        guard clipIndex >= 0, clipIndex < clips.count else { return }

        let clip = clips[clipIndex]

        // 同じクリップならseekだけ
        if currentClipIndex == clipIndex, let player = player {
            seekAndPlay(player: player, start: startTime, end: endTime)
        } else {
            // 新しいクリップをロード
            cleanup()
            let playerItem = AVPlayerItem(url: clip.fileURL)
            let newPlayer = AVPlayer(playerItem: playerItem)
            self.player = newPlayer
            self.currentClipIndex = clipIndex
            seekAndPlay(player: newPlayer, start: startTime, end: endTime)
        }

        previewStartTime = startTime
        previewEndTime = endTime
    }

    private func seekAndPlay(player: AVPlayer, start: TimeInterval, end: TimeInterval) {
        let startCMTime = CMTime(seconds: start, preferredTimescale: 600)
        let endCMTime = CMTime(seconds: end, preferredTimescale: 600)

        player.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.setupTimeObserver(player: player)
                self.setupBoundaryObserver(player: player, endTime: endCMTime)
                self.updateSubtitle(at: start)
                player.play()
                self.isPlaying = true
            }
        }
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateSubtitle(at: time)
    }

    // MARK: - Time Observer

    private func setupTimeObserver(player: AVPlayer) {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = time.seconds
                self.updateSubtitle(at: time.seconds)
            }
        }
    }

    private func setupBoundaryObserver(player: AVPlayer, endTime: CMTime) {
        removeBoundaryObserver()
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isSequentialPreview {
                    self.advanceSequentialPreview()
                } else {
                    player.pause()
                    self.isPlaying = false
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    private func removeBoundaryObserver() {
        if let observer = boundaryObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        boundaryObserver = nil
    }

    // MARK: - Subtitle

    private func updateSubtitle(at time: TimeInterval) {
        guard currentClipIndex >= 0, currentClipIndex < clips.count else {
            currentSubtitle = ""
            return
        }
        let clip = clips[currentClipIndex]
        guard let transcription = clip.bestTranscription else {
            currentSubtitle = ""
            return
        }

        // 現在時刻に該当するセグメントを探す
        if let segment = transcription.segments.first(where: { time >= $0.startTime && time <= $0.endTime }) {
            currentSubtitle = segment.text
        } else {
            currentSubtitle = ""
        }
    }

    // MARK: - Sequential Preview (繋ぎプレビュー)

    /// 有効なkeptSectionsを順番に連結再生
    func startSequentialPreview(analysis: StoryAnalysis) {
        let sections = analysis.keptSections
            .filter { $0.isEnabled }
            .sorted { $0.orderIndex < $1.orderIndex }
        guard !sections.isEmpty else { return }

        sequentialSections = sections
        sequentialIndex = 0
        isSequentialPreview = true
        playSequentialSection()
    }

    func stopSequentialPreview() {
        isSequentialPreview = false
        sequentialSections = []
        sequentialIndex = 0
        player?.pause()
        isPlaying = false
    }

    private func playSequentialSection() {
        guard isSequentialPreview,
              sequentialIndex < sequentialSections.count else {
            // 全セクション再生完了
            stopSequentialPreview()
            return
        }

        let section = sequentialSections[sequentialIndex]
        previewSection(clipIndex: section.clipIndex, startTime: section.startTime, endTime: section.endTime)
    }

    /// 現在のセクションが終了したら次へ進む（setupBoundaryObserverのコールバックから呼ぶ）
    private func advanceSequentialPreview() {
        guard isSequentialPreview else { return }
        sequentialIndex += 1
        playSequentialSection()
    }

    // MARK: - Cleanup

    func cleanup() {
        removeTimeObserver()
        removeBoundaryObserver()
        player?.pause()
        player = nil
        isPlaying = false
        currentClipIndex = -1
        currentSubtitle = ""
    }

    deinit {
        // Note: cleanup() must be called from MainActor before deallocation
    }
}
