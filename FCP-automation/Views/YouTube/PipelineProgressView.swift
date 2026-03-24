import SwiftUI

struct PipelineProgressView: View {
    @EnvironmentObject var youtubeState: YouTubeEditorState

    let themeColor = Color(red: 0.15, green: 0.95, blue: 0.65)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 全体進捗
            VStack(spacing: 12) {
                Image(systemName: youtubeState.pipelinePhase.icon)
                    .font(.system(size: 36))
                    .foregroundStyle(themeColor)

                Text(youtubeState.pipelinePhase.rawValue)
                    .font(.title2.bold())

                Text(youtubeState.currentOperation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // 進捗バー
                VStack(spacing: 4) {
                    ProgressView(value: youtubeState.overallProgress)
                        .tint(themeColor)
                        .frame(maxWidth: 400)

                    HStack(spacing: 12) {
                        Text("\(Int(youtubeState.overallProgress * 100))%")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(themeColor)

                        if let eta = youtubeState.estimatedTimeRemaining {
                            Text(eta)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 素材尺の参考表示
                    if let project = youtubeState.project {
                        let totalMins = Int(project.totalRawDuration) / 60
                        Text("素材合計: \(totalMins)分 / \(project.clips.count)クリップ")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 12) {
                    // 停止ボタン
                    Button(action: {
                        youtubeState.cancelPipeline()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("処理を停止")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(youtubeState.isCancelled)

                    // スキップしてレビューへ
                    Button(action: {
                        youtubeState.cancelPipeline()
                        youtubeState.pipelinePhase = .review
                        youtubeState.currentOperation = "フェーズをスキップしました"
                        youtubeState.overallProgress = 1.0
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.end.fill")
                            Text("スキップ → レビュー")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // エラー表示
            if let error = youtubeState.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.1))
                )
                .frame(maxWidth: 500)
            }

            // クリップ一覧
            if let project = youtubeState.project {
                ScrollView {
                    ClipListView(clips: project.clips)
                        .padding(.horizontal)
                }
                .frame(maxHeight: 300)
            }

            Spacer()
        }
        .padding()
    }
}
