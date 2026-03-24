import SwiftUI
import AVKit

struct ReviewPlayerView: View {
    @ObservedObject var playerState: ReviewPlayerState
    @EnvironmentObject var youtubeState: YouTubeEditorState

    var body: some View {
        VStack(spacing: 0) {
            // 動画プレーヤー
            ZStack(alignment: .bottom) {
                if let player = playerState.player {
                    VideoPlayerView(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    // 字幕オーバーレイ
                    if !playerState.currentSubtitle.isEmpty {
                        subtitleOverlay
                    }
                } else {
                    placeholderView
                }
            }

            // 再生コントロール
            if playerState.player != nil {
                playerControls
            }

            // セクション情報
            sectionInfoBadge
        }
        .padding(12)
    }

    // MARK: - Subtitle

    private var subtitleOverlay: some View {
        Text(playerState.currentSubtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.7))
            )
            .padding(.bottom, 12)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("セクションを選択すると\nプレビューが表示されます")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.05))
        )
    }

    // MARK: - Controls

    private var playerControls: some View {
        HStack(spacing: 12) {
            // 現在時刻
            Text(TranscriptionSegment.formatTime(playerState.currentTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            // シークバー
            GeometryReader { geometry in
                let range = playerState.previewEndTime - playerState.previewStartTime
                let progress = range > 0
                    ? (playerState.currentTime - playerState.previewStartTime) / range
                    : 0

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: max(0, geometry.size.width * min(1, max(0, progress))), height: 4)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geometry.size.width))
                            let time = playerState.previewStartTime + (playerState.previewEndTime - playerState.previewStartTime) * fraction
                            playerState.seek(to: time)
                        }
                )
            }
            .frame(height: 16)

            // 再生/一時停止
            Button(action: { playerState.togglePlayback() }) {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 終了時刻
            Text(TranscriptionSegment.formatTime(playerState.previewEndTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    // MARK: - Section Info

    private var sectionInfoBadge: some View {
        Group {
            if let selected = youtubeState.selectedSection {
                switch selected {
                case .kept(let index):
                    if let section = youtubeState.project?.storyAnalysis?.keptSections[safe: index] {
                        let clipName = clipDisplayName(for: section.clipIndex)
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text(clipName)
                                .font(.system(size: 11, weight: .medium))
                            Text(section.reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.08))
                        )
                        .padding(.top, 8)
                    }

                case .removed(let index):
                    if let section = youtubeState.project?.storyAnalysis?.removedSections[safe: index] {
                        let clipName = clipDisplayName(for: section.clipIndex)
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text(clipName)
                                .font(.system(size: 11, weight: .medium))
                            Text(section.reason.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                            Text(section.explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.08))
                        )
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func clipDisplayName(for clipIndex: Int) -> String {
        guard let clips = youtubeState.project?.clips,
              clipIndex >= 0, clipIndex < clips.count else { return "?" }
        return clips[clipIndex].displayName
    }
}

// MARK: - Safe Array Access

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
