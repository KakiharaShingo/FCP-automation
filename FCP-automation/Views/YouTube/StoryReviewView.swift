import SwiftUI

struct StoryReviewView: View {
    @EnvironmentObject var youtubeState: YouTubeEditorState
    @EnvironmentObject var appState: AppState
    @StateObject private var reviewPlayerState = ReviewPlayerState()
    @StateObject private var chatState = EditChatState()
    @State private var isRetrying = false

    let themeColor = Color(red: 0.15, green: 0.95, blue: 0.65)

    var body: some View {
        VStack(spacing: 0) {
            // 上部: サマリー
            summaryHeader
            Divider()

            if let analysis = youtubeState.project?.storyAnalysis {
                HSplitView {
                    // 左: チャプター + クリップ順
                    leftPanel(analysis: analysis)
                        .frame(minWidth: 180, idealWidth: 220)

                    // 中央: セクション一覧 + AIチャット
                    VSplitView {
                        centerPanel(analysis: analysis)
                            .frame(minHeight: 200)

                        EditChatView(chatState: chatState, onSend: handleChatSend)
                            .frame(minHeight: 150, idealHeight: 200)
                    }
                    .frame(minWidth: 350)

                    // 右: 動画プレビュー
                    ReviewPlayerView(playerState: reviewPlayerState)
                        .frame(minWidth: 280, idealWidth: 350)
                }
            } else {
                noAnalysisView
            }
        }
        .onAppear {
            if let clips = youtubeState.project?.clips {
                reviewPlayerState.setClips(clips)
            }
        }
        .onChange(of: youtubeState.project?.clips.count) { _ in
            if let clips = youtubeState.project?.clips {
                reviewPlayerState.setClips(clips)
            }
        }
        .onDisappear {
            reviewPlayerState.cleanup()
        }
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI編集レビュー")
                    .font(.system(size: 16, weight: .bold))

                if let analysis = youtubeState.project?.storyAnalysis {
                    Text(analysis.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // 推定尺表示
            if let project = youtubeState.project {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("推定最終尺:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(formatMinutes(project.estimatedFinalDuration ?? 0))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(themeColor)
                    }
                    if let target = youtubeState.targetDurationSeconds {
                        HStack(spacing: 4) {
                            Text("目標尺:")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(formatMinutes(target))
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                        }
                    }
                }

                // フック提案
                if let hook = youtubeState.project?.storyAnalysis?.hookSuggestion {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.yellow)
                            Text("フック提案")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(hook.reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button(action: {
                            // フックシーンをプレビュー
                            reviewPlayerState.previewSection(
                                clipIndex: hook.clipIndex,
                                startTime: hook.startTime,
                                endTime: hook.endTime
                            )
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8))
                                Text("プレビュー")
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                // 低信頼度セクション数
                if let analysis = youtubeState.project?.storyAnalysis {
                    let lowConfCount = analysis.keptSections.filter { $0.confidence < 0.5 }.count +
                                       analysis.removedSections.filter { $0.confidence < 0.5 }.count
                    if lowConfCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("\(lowConfCount)件の要確認セクション")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // プラグインプリセット選択
            if !appState.pluginPresets.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $youtubeState.selectedPluginPresetID) {
                            Text("プラグインなし").tag(UUID?.none)
                            ForEach(appState.pluginPresets) { preset in
                                Text(preset.name).tag(UUID?.some(preset.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    // 選択プリセットの内容プレビュー
                    if let presetID = youtubeState.selectedPluginPresetID,
                       let preset = appState.pluginPresets.first(where: { $0.id == presetID }) {
                        HStack(spacing: 6) {
                            if preset.hasCustomTitle {
                                HStack(spacing: 2) {
                                    Image(systemName: "textformat")
                                        .font(.system(size: 8))
                                    Text(preset.titleTemplateName ?? "")
                                        .lineLimit(1)
                                }
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                                .foregroundStyle(.blue)
                            }
                            if !preset.effectTemplates.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "camera.filters")
                                        .font(.system(size: 8))
                                    Text("\(preset.effectTemplates.count)エフェクト")
                                }
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundStyle(.purple)
                            }
                            if !preset.plugins.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "puzzlepiece")
                                        .font(.system(size: 8))
                                    Text("\(preset.plugins.count)カスタム")
                                }
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // 繋ぎプレビューボタン
            Button(action: {
                if reviewPlayerState.isSequentialPreview {
                    reviewPlayerState.stopSequentialPreview()
                } else if let analysis = youtubeState.project?.storyAnalysis {
                    reviewPlayerState.startSequentialPreview(analysis: analysis)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: reviewPlayerState.isSequentialPreview ? "stop.fill" : "play.rectangle")
                    Text(reviewPlayerState.isSequentialPreview ? "プレビュー停止" : "繋ぎプレビュー")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button(action: {
                youtubeState.pipelinePhase = .export
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text("承認してエクスポートへ")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding()
    }

    // MARK: - Left Panel

    private func leftPanel(analysis: StoryAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // クリップ順序
                VStack(alignment: .leading, spacing: 8) {
                    Label("クリップ順序", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(analysis.clipOrder.enumerated()), id: \.offset) { idx, clipIndex in
                        if let clips = youtubeState.project?.clips, clipIndex < clips.count {
                            HStack(spacing: 8) {
                                Text("\(idx + 1).")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(themeColor)
                                Text(clips[clipIndex].displayName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Divider()

                // チャプター
                VStack(alignment: .leading, spacing: 8) {
                    Label("チャプター構成", systemImage: "list.bullet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(analysis.chapters.enumerated()), id: \.offset) { idx, chapter in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(idx + 1). \(chapter.title)")
                                .font(.system(size: 12, weight: .medium))
                            Text(chapter.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                // BGM提案
                if !analysis.bgmSuggestions.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("BGM提案 (\(analysis.bgmSuggestions.count))", systemImage: "music.note.list")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(analysis.bgmSuggestions) { bgm in
                            HStack(spacing: 6) {
                                Image(systemName: bgm.moodIcon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bgm.mood)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(bgm.description)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                // Bロール挿入点提案
                if !analysis.brollSuggestions.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Bロール挿入点 (\(analysis.brollSuggestions.count))", systemImage: "rectangle.stack.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(analysis.brollSuggestions.sorted { $0.importance > $1.importance }) { broll in
                            HStack(spacing: 6) {
                                // 重要度を星で表示
                                Text(String(repeating: "\u{2605}", count: min(broll.importance, 5)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(broll.description)
                                        .font(.system(size: 11))
                                        .lineLimit(2)
                                    HStack(spacing: 4) {
                                        Text("Clip\(broll.clipIndex)")
                                            .font(.system(size: 9).monospacedDigit())
                                        Text("\(formatTime(broll.startTime))-\(formatTime(broll.endTime))")
                                            .font(.system(size: 9).monospacedDigit())
                                    }
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .onTapGesture {
                                reviewPlayerState.previewSection(
                                    clipIndex: broll.clipIndex,
                                    startTime: max(0, broll.startTime - 2),
                                    endTime: broll.endTime + 2
                                )
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Center Panel

    private func centerPanel(analysis: StoryAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Keep sections
                VStack(alignment: .leading, spacing: 8) {
                    let lowConfKeptCount = analysis.keptSections.filter { $0.confidence < 0.5 }.count
                    Label("残すセクション (\(analysis.keptSections.filter(\.isEnabled).count))" +
                          (lowConfKeptCount > 0 ? " \u{26A0}\(lowConfKeptCount)" : ""),
                          systemImage: "checkmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)

                    ForEach(Array(analysis.keptSections.indices), id: \.self) { idx in
                        keepSectionRow(index: idx)
                            .onTapGesture {
                                selectSection(.kept(index: idx))
                            }
                    }
                }

                Divider()

                // Remove sections
                VStack(alignment: .leading, spacing: 8) {
                    let lowConfRemovedCount = analysis.removedSections.filter { $0.confidence < 0.5 }.count
                    Label("削除セクション (\(analysis.removedSections.filter(\.isRemoved).count))" +
                          (lowConfRemovedCount > 0 ? " \u{26A0}\(lowConfRemovedCount)" : ""),
                          systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)

                    ForEach(Array(analysis.removedSections.indices), id: \.self) { idx in
                        removeSectionRow(index: idx)
                            .onTapGesture {
                                selectSection(.removed(index: idx))
                            }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Section Selection

    private func selectSection(_ section: YouTubeEditorState.SelectedSection) {
        youtubeState.selectedSection = section

        switch section {
        case .kept(let index):
            guard let s = youtubeState.project?.storyAnalysis?.keptSections[safe: index] else { return }
            reviewPlayerState.previewSection(clipIndex: s.clipIndex, startTime: s.startTime, endTime: s.endTime)

        case .removed(let index):
            guard let s = youtubeState.project?.storyAnalysis?.removedSections[safe: index] else { return }
            reviewPlayerState.previewSection(clipIndex: s.clipIndex, startTime: s.startTime, endTime: s.endTime)
        }
    }

    // MARK: - Section Rows

    @ViewBuilder
    private func keepSectionRow(index: Int) -> some View {
        if let section = youtubeState.project?.storyAnalysis?.keptSections[index] {
            let clips = youtubeState.project?.clips ?? []
            let clipName = section.clipIndex < clips.count ? clips[section.clipIndex].displayName : "?"
            let isSelected = youtubeState.selectedSection == .kept(index: index)

            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { youtubeState.project?.storyAnalysis?.keptSections[index].isEnabled ?? true },
                    set: { youtubeState.project?.storyAnalysis?.keptSections[index].isEnabled = $0 }
                ))
                .labelsHidden()
                .controlSize(.small)

                // 信頼度インジケーター
                confidenceIndicator(section.confidence)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green.opacity(0.6))
                    .frame(width: 4, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(clipName)
                            .font(.system(size: 11, weight: .medium))
                        Text("\(formatTime(section.startTime)) - \(formatTime(section.endTime))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("(\(formatDuration(section.duration)))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(section.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(section.confidence < 0.5
                          ? Color.orange.opacity(0.08)
                          : section.isEnabled ? Color.green.opacity(0.05) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func removeSectionRow(index: Int) -> some View {
        if let section = youtubeState.project?.storyAnalysis?.removedSections[index] {
            let clips = youtubeState.project?.clips ?? []
            let clipName = section.clipIndex < clips.count ? clips[section.clipIndex].displayName : "?"
            let isSelected = youtubeState.selectedSection == .removed(index: index)

            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { youtubeState.project?.storyAnalysis?.removedSections[index].isRemoved ?? true },
                    set: { youtubeState.project?.storyAnalysis?.removedSections[index].isRemoved = $0 }
                ))
                .labelsHidden()
                .controlSize(.small)

                // 信頼度インジケーター
                confidenceIndicator(section.confidence)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.red.opacity(0.6))
                    .frame(width: 4, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: section.reason.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(clipName)
                            .font(.system(size: 11, weight: .medium))
                        Text("\(formatTime(section.startTime)) - \(formatTime(section.endTime))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(section.explanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(section.reason.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.red.opacity(0.15))
                    )
                    .foregroundStyle(.red)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(section.confidence < 0.5
                          ? Color.orange.opacity(0.08)
                          : section.isRemoved ? Color.red.opacity(0.05) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
    }

    // MARK: - AI Chat Handler

    private func handleChatSend(_ message: String) {
        guard let project = youtubeState.project,
              let analysis = project.storyAnalysis else { return }

        chatState.isProcessing = true

        Task {
            do {
                let apiService = try ClaudeAPIService()
                let history = chatState.messages.map { ($0.role, $0.content) }
                let result = try await apiService.sendMessageForRefinement(
                    currentAnalysis: analysis,
                    clips: project.clips,
                    chatHistory: history,
                    userInstruction: message
                )

                youtubeState.project?.storyAnalysis = result.updatedAnalysis
                chatState.addMessage(role: "assistant", content: result.explanation)
                chatState.isProcessing = false
            } catch {
                chatState.errorMessage = error.localizedDescription
                chatState.isProcessing = false
            }
        }
    }

    // MARK: - No Analysis

    private var noAnalysisView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ストーリー分析結果がありません")
                .font(.headline)
                .foregroundStyle(.secondary)

            if let error = youtubeState.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if isRetrying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("再実行中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    // 失敗した文字起こしを再実行
                    let failedTranscriptionCount = youtubeState.project?.clips.filter { $0.bestTranscription == nil }.count ?? 0
                    if failedTranscriptionCount > 0 {
                        Button("文字起こしから再実行（\(failedTranscriptionCount)クリップ）") {
                            retryFromTranscription()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // 文字起こしはあるがストーリー分析だけ失敗
                    let hasTranscription = youtubeState.project?.clips.contains { $0.bestTranscription != nil } ?? false
                    if hasTranscription {
                        Button("ストーリー分析だけ再実行") {
                            retryStoryAnalysis()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    Button("エクスポートへ進む（分析なし）") {
                        youtubeState.pipelinePhase = .export
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
    }

    // MARK: - Retry Actions

    private func retryFromTranscription() {
        isRetrying = true
        youtubeState.errorMessage = nil

        Task {
            let pipeline = YouTubePipelineService(whisperSpeedPreset: appState.whisperSpeedPreset)
            await pipeline.runFullPipeline(state: youtubeState, appState: appState, resumeFrom: .transcribing)
            isRetrying = false
        }
    }

    private func retryStoryAnalysis() {
        isRetrying = true
        youtubeState.errorMessage = nil

        Task {
            let pipeline = YouTubePipelineService(whisperSpeedPreset: appState.whisperSpeedPreset)
            await pipeline.runFullPipeline(state: youtubeState, appState: appState, resumeFrom: .storyAnalysis)
            isRetrying = false
        }
    }

    // MARK: - Helpers

    private func confidenceIndicator(_ confidence: Double) -> some View {
        let (color, label): (Color, String) = {
            switch confidence {
            case 0.7...: return (.green, "\(Int(confidence * 100))%")
            case 0.4..<0.7: return (.orange, "\(Int(confidence * 100))%")
            default: return (.red, "\(Int(confidence * 100))%")
            }
        }()

        return Text(label)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: 32)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        TranscriptionSegment.formatTime(seconds)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)分\(secs)秒"
    }
}
