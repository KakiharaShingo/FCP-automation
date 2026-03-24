import SwiftUI
import AVKit

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct PlaybackControlsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHoveringSeekBar = false

    var body: some View {
        VStack(spacing: 4) {
            // シークバー
            seekBar

            // コントロール
            HStack(spacing: 0) {
                // 現在時刻
                Text(TranscriptionSegment.formatTime(appState.currentPlaybackTime))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                Spacer()

                // 再生コントロール
                HStack(spacing: 16) {
                    Button(action: { appState.seekBackward(5) }) {
                        Image(systemName: "gobackward.5")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("j", modifiers: [])
                    .help("5秒戻る (J)")

                    Button(action: { appState.togglePlayback() }) {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("再生/一時停止")

                    Button(action: { appState.seekForward(5) }) {
                        Image(systemName: "goforward.5")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("l", modifiers: [])
                    .help("5秒進む (L)")
                }

                Spacer()

                // 総時間
                Text(TranscriptionSegment.formatTime(appState.videoDuration))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var seekBar: some View {
        GeometryReader { geometry in
            let progress = appState.videoDuration > 0
                ? appState.currentPlaybackTime / appState.videoDuration
                : 0
            let trackHeight: CGFloat = isHoveringSeekBar ? 6 : 4
            let handleSize: CGFloat = isHoveringSeekBar ? 14 : 10

            ZStack(alignment: .leading) {
                // トラック背景
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: trackHeight)

                // バッファ表示
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: geometry.size.width, height: trackHeight)

                // 進捗バー
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: max(0, geometry.size.width * progress), height: trackHeight)

                // ドラッグハンドル
                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: max(0, min(geometry.size.width - handleSize, geometry.size.width * progress - handleSize / 2)))
                    .opacity(isHoveringSeekBar ? 1 : 0.7)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        let time = appState.videoDuration * fraction
                        appState.seek(to: time)
                    }
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringSeekBar = hovering
                }
            }
        }
        .frame(height: 20)
    }
}
