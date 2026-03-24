import SwiftUI
import UniformTypeIdentifiers

struct YouTubeEditorView: View {
    @EnvironmentObject var youtubeState: YouTubeEditorState
    @EnvironmentObject var appState: AppState

    @State private var isDragOver = false
    @State private var startPhase: YouTubeEditorState.PipelinePhase = .transcribing

    let themeColor = Color(red: 0.15, green: 0.95, blue: 0.65)

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            phaseIndicator
            Divider()

            // コンテンツエリア
            Group {
                switch youtubeState.pipelinePhase {
                case .idle:
                    dropZoneView
                case .importing:
                    importingView
                case .transcribing, .reformatting, .analyzing, .storyAnalysis:
                    PipelineProgressView()
                case .review:
                    StoryReviewView()
                case .export:
                    YouTubeExportView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("YouTube自動編集")
                    .font(.title2.bold())
                Text("フォルダ投入 → 一括処理 → AI編集 → FCPXML出力")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if youtubeState.hasProject {
                Button(action: {
                    youtubeState.reset()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("リセット")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Phase Indicator

    private var phaseIndicator: some View {
        let phases: [YouTubeEditorState.PipelinePhase] = [
            .importing, .transcribing, .reformatting, .analyzing, .storyAnalysis, .review, .export
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(phases, id: \.self) { phase in
                    phaseStep(phase: phase)
                    if phase != .export {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func phaseStep(phase: YouTubeEditorState.PipelinePhase) -> some View {
        let isCurrent = youtubeState.pipelinePhase == phase
        let isPast = youtubeState.pipelinePhase.stepIndex > phase.stepIndex

        return HStack(spacing: 4) {
            Image(systemName: isPast ? "checkmark.circle.fill" : phase.icon)
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? themeColor : isPast ? .green : .secondary)

            Text(phase.rawValue)
                .font(.system(size: 11, weight: isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? themeColor : isPast ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? themeColor.opacity(0.15) : Color.clear)
        )
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 12)

                if youtubeState.project == nil {
                    // まだファイル未選択: ドロップゾーン表示
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 48))
                            .foregroundStyle(isDragOver ? themeColor : .secondary)

                        Text("フォルダまたは動画ファイルをドロップ")
                            .font(.title3.bold())

                        Text("対応形式: MP4, MOV, M4V, AVI, MKV, MTS, MXF")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("ファイルを選択...") {
                            openFilePicker()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: 500)
                    .padding(40)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isDragOver ? themeColor : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                            )
                    )
                    .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
                } else {
                    // ファイル読み込み済み: クリップ情報表示
                    importedClipsSummary
                }

                // 設定セクション（常に表示）
                genrePresetSection
                targetDurationSection
                startPhaseSection
                styleProfileSection

                if youtubeState.project != nil {
                    // 開始ボタン
                    Button(action: startPipeline) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                            Text("編集パイプライン開始")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: 300)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor)
                    .controlSize(.large)
                }

                Spacer(minLength: 12)
            }
            .padding()
        }
    }

    private var importedClipsSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("読み込み済み")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("クリア") {
                        youtubeState.project = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if let project = youtubeState.project {
                    HStack(spacing: 16) {
                        Label("\(project.clips.count) クリップ", systemImage: "film.stack")
                        Label(formatMinutes(project.totalRawDuration), systemImage: "clock")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    // クリップ一覧（コンパクト）
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(project.clips.prefix(8)) { clip in
                            HStack(spacing: 6) {
                                Text(clip.displayName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                Text(formatMinutes(clip.duration))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if project.clips.count > 8 {
                            Text("... 他 \(project.clips.count - 8) クリップ")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 500)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private var genrePresetSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film.stack")
                        .font(.system(size: 12))
                        .foregroundStyle(themeColor)
                    Text("動画ジャンル")
                        .font(.system(size: 13, weight: .medium))
                }

                HStack(spacing: 8) {
                    ForEach(GenrePreset.allPresets) { preset in
                        Button(action: {
                            youtubeState.selectedGenrePreset = preset
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 16))
                                Text(preset.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(youtubeState.selectedGenrePreset.id == preset.id
                                          ? themeColor.opacity(0.2)
                                          : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(youtubeState.selectedGenrePreset.id == preset.id
                                            ? themeColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(youtubeState.selectedGenrePreset.id == preset.id
                                        ? themeColor : .secondary)
                    }
                }

                Text(youtubeState.selectedGenrePreset.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .frame(maxWidth: 500)
    }

    private var targetDurationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("目標動画尺を指定", isOn: $youtubeState.enableTargetDuration)
                    .font(.system(size: 13, weight: .medium))

                if youtubeState.enableTargetDuration {
                    HStack {
                        Slider(value: $youtubeState.targetDurationMinutes, in: 1...60, step: 1)
                        Text("\(Int(youtubeState.targetDurationMinutes))分")
                            .font(.system(size: 13).monospacedDigit())
                            .frame(width: 40)
                    }
                    Text("AIが目標尺に合わせてカットを調整します")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 400)
    }

    private var startPhaseSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "forward.end")
                        .font(.system(size: 12))
                        .foregroundStyle(themeColor)
                    Text("開始フェーズ")
                        .font(.system(size: 13, weight: .medium))
                }

                Picker("", selection: $startPhase) {
                    Text("文字起こしから（通常）").tag(YouTubeEditorState.PipelinePhase.transcribing)
                    Text("AI整形から").tag(YouTubeEditorState.PipelinePhase.reformatting)
                    Text("音声解析から").tag(YouTubeEditorState.PipelinePhase.analyzing)
                    Text("ストーリー分析から").tag(YouTubeEditorState.PipelinePhase.storyAnalysis)
                    Text("エクスポートのみ").tag(YouTubeEditorState.PipelinePhase.export)
                }
                .labelsHidden()

                if startPhase != .transcribing {
                    Text("前回の処理結果が残っている場合、指定フェーズから再開します。未実行のフェーズはスキップされます。")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 400)
    }

    private var styleProfileSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 12))
                        .foregroundStyle(themeColor)
                    Text("編集スタイル")
                        .font(.system(size: 13, weight: .medium))
                }

                if appState.styleProfiles.isEmpty {
                    Text("スタイルプロファイル未登録（設定 → スタイルから追加）")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Picker("", selection: $youtubeState.selectedStyleProfileID) {
                        Text("なし（デフォルト）").tag(nil as UUID?)
                        ForEach(appState.styleProfiles) { profile in
                            Text("\(profile.name) — \(profile.videoTitle)")
                                .tag(profile.id as UUID?)
                        }
                    }
                    .labelsHidden()

                    if let selected = appState.styleProfiles.first(where: { $0.id == youtubeState.selectedStyleProfileID }) {
                        Text(selected.guidance)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.top, 2)
                    } else if let defaultProfile = appState.defaultStyleProfile {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text("デフォルト: \(defaultProfile.name)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Importing View

    private var importingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("ファイルを読み込み中...")
                .font(.headline)
        }
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType.movie, UTType.mpeg4Movie, UTType.quickTimeMovie, UTType.avi
        ]

        if panel.runModal() == .OK {
            processSelectedURLs(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let serialQueue = DispatchQueue(label: "handleDrop.urls")
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    serialQueue.sync { urls.append(url) }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            processSelectedURLs(urls)
        }
    }

    private func processSelectedURLs(_ urls: [URL]) {
        var fileURLs: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // フォルダ内のファイルを再帰的に列挙（サブフォルダも探索）
                collectVideoFiles(in: url, into: &fileURLs)
            } else {
                fileURLs.append(url)
            }
        }

        guard !fileURLs.isEmpty else { return }

        youtubeState.pipelinePhase = .importing
        youtubeState.currentOperation = "ファイルを読み込み中..."

        Task {
            let pipeline = YouTubePipelineService(whisperSpeedPreset: appState.whisperSpeedPreset)
            let clips = await pipeline.importAndSort(urls: fileURLs)

            guard !clips.isEmpty else {
                youtubeState.errorMessage = "対応する動画ファイルが見つかりませんでした"
                youtubeState.pipelinePhase = .idle
                return
            }

            let projectName = urls.first?.deletingPathExtension().lastPathComponent ?? "YouTube Project"
            youtubeState.project = YouTubeProject(
                name: projectName,
                clips: clips,
                targetDurationSeconds: youtubeState.targetDurationSeconds
            )

            // インポート完了 → idle に戻して設定画面を表示（ユーザーが開始ボタンを押すまで待つ）
            youtubeState.pipelinePhase = .idle
            youtubeState.currentOperation = ""
        }
    }

    private func startPipeline() {
        guard youtubeState.project != nil else { return }

        // エクスポートのみの場合はパイプラインをスキップしてレビュー画面へ
        if startPhase == .export {
            youtubeState.pipelinePhase = .review
            youtubeState.currentOperation = "パイプラインをスキップしました"
            youtubeState.overallProgress = 1.0
            return
        }

        Task {
            let pipeline = YouTubePipelineService(whisperSpeedPreset: appState.whisperSpeedPreset)
            await pipeline.runFullPipeline(state: youtubeState, appState: appState, resumeFrom: startPhase)
        }
    }

    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "mts", "mxf"]

    private func collectVideoFiles(in folderURL: URL, into files: inout [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            // ディレクトリはスキップ
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if videoExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
    }
}
