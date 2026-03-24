import SwiftUI

struct ClipListView: View {
    let clips: [ProjectClip]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("クリップ一覧")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(clips) { clip in
                clipRow(clip)
            }
        }
    }

    private func clipRow(_ clip: ProjectClip) -> some View {
        HStack(spacing: 12) {
            // 番号
            Text("\(clip.sortOrder + 1)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .frame(width: 24, height: 24)
                .background(Circle().fill(.ultraThinMaterial))

            // ファイル情報
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let date = clip.creationDate {
                        Text(date.formatted(.dateTime.month().day().hour().minute()))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(formatDuration(clip.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // パイプラインステータス
            HStack(spacing: 6) {
                stepIcon(clip.pipelineState.transcription, label: "文字起こし")
                stepIcon(clip.pipelineState.reformat, label: "AI整形")
                stepIcon(clip.pipelineState.audioAnalysis, label: "解析")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
    }

    private func stepIcon(_ status: ClipPipelineState.StepStatus, label: String) -> some View {
        Image(systemName: status.icon)
            .font(.system(size: 12))
            .foregroundStyle(statusColor(status))
            .help(label + ": " + status.rawValue)
    }

    private func statusColor(_ status: ClipPipelineState.StepStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
