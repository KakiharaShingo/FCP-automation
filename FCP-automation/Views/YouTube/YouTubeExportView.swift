import SwiftUI
import UniformTypeIdentifiers

struct YouTubeExportView: View {
    @EnvironmentObject var youtubeState: YouTubeEditorState
    @EnvironmentObject var appState: AppState

    @State private var showSubtitleSettings = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var generatedChapters = ""
    @State private var generatedDescription = ""
    @State private var isGeneratingMeta = false
    @State private var thumbnailCandidates: [VideoAnalyzer.ThumbnailCandidate] = []
    @State private var isExtractingThumbnails = false

    let themeColor = Color(red: 0.15, green: 0.95, blue: 0.65)

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("エクスポート")
                        .font(.system(size: 16, weight: .bold))
                    Text("統合FCPXMLを書き出してFinal Cut Proにインポート")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button(action: {
                    youtubeState.pipelinePhase = .review
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("レビューに戻る")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // エクスポートモード選択
                    exportModeSection

                    // プロジェクト情報
                    projectInfoSection

                    // モード別オプション
                    if youtubeState.exportSettings.exportMode == .fcpxml {
                        // プラグイン情報
                        pluginInfoSection
                        // 字幕設定
                        subtitleSection
                    }

                    // 共通オプション
                    sharedOptionsSection

                    // YouTubeメタデータ
                    youtubeMetadataSection

                    // サムネイル候補
                    thumbnailSection

                    // YouTubeアップロード設定（直接レンダー時のみ）
                    if youtubeState.exportSettings.exportMode == .directRender {
                        youtubeUploadSection
                    }

                    // エクスポートボタン
                    exportSection
                }
                .padding(24)
            }
        }
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .alert("完了", isPresented: $showSuccess) {
            Button("OK") {}
        } message: {
            Text(successMessage)
        }
    }

    // MARK: - Export Mode Selector

    private var exportModeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("エクスポートモード", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))

                Picker("", selection: $youtubeState.exportSettings.exportMode) {
                    Text("FCP (FCPXML)").tag(ExportSettings.ExportMode.fcpxml)
                    Text("直接レンダリング (ffmpeg)").tag(ExportSettings.ExportMode.directRender)
                }
                .pickerStyle(.segmented)

                switch youtubeState.exportSettings.exportMode {
                case .fcpxml:
                    Text("FCPXMLを出力 → Final Cut Proで開いて最終調整・レンダリング")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .directRender:
                    Text("ffmpegで直接MP4を生成 → FCPなしで完成動画を出力")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Shared Options

    private var sharedOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("共通オプション", systemImage: "gearshape.2")
                    .font(.system(size: 14, weight: .semibold))

                Toggle("SRT字幕ファイルを生成", isOn: $youtubeState.exportSettings.generateSRT)
                    .font(.system(size: 12))

                Toggle("音量ノーマライズ適用", isOn: $youtubeState.exportSettings.applyVolumeNormalization)
                    .font(.system(size: 12))

                if youtubeState.exportSettings.exportMode == .directRender {
                    Toggle("字幕を動画に焼き込み", isOn: $youtubeState.exportSettings.burnInSubtitles)
                        .font(.system(size: 12))
                }

                // BGMファイル選択
                HStack {
                    Text("BGM:")
                        .font(.system(size: 12))
                    if let bgmURL = youtubeState.exportSettings.bgmFileURL {
                        Text(bgmURL.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("解除") {
                            youtubeState.exportSettings.bgmFileURL = nil
                        }
                        .controlSize(.mini)
                    } else {
                        Text("なし")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("選択...") {
                        selectBGMFile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if youtubeState.exportSettings.bgmFileURL != nil {
                    HStack {
                        Text("BGM音量:")
                            .font(.system(size: 11))
                        Slider(value: $youtubeState.exportSettings.bgmVolumeDB, in: -30...0, step: 1)
                        Text("\(Int(youtubeState.exportSettings.bgmVolumeDB))dB")
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 40)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - YouTube Upload Section

    private var youtubeUploadSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("YouTubeアップロード", systemImage: "icloud.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))

                Toggle("レンダリング後にYouTubeにアップロード", isOn: $youtubeState.exportSettings.uploadToYouTube)
                    .font(.system(size: 12))

                if youtubeState.exportSettings.uploadToYouTube {
                    // 認証状態
                    HStack {
                        if youtubeState.isAuthenticated {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("YouTube認証済み")
                                .font(.system(size: 11))
                        } else {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("未認証 — 設定画面で認証してください")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }

                    // 公開設定
                    HStack {
                        Text("公開設定:")
                            .font(.system(size: 12))
                        Picker("", selection: $youtubeState.exportSettings.privacyStatus) {
                            Text("公開").tag(YouTubeUploadMetadata.PrivacyStatus.public)
                            Text("限定公開").tag(YouTubeUploadMetadata.PrivacyStatus.unlisted)
                            Text("非公開").tag(YouTubeUploadMetadata.PrivacyStatus.private)
                        }
                        .frame(width: 140)
                    }

                    // カテゴリ
                    HStack {
                        Text("カテゴリ:")
                            .font(.system(size: 12))
                        Picker("", selection: $youtubeState.exportSettings.categoryId) {
                            ForEach(YouTubeUploadMetadata.categoryOptions, id: \.id) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        .frame(width: 200)
                    }

                    // アップロード進捗
                    if youtubeState.isUploading {
                        VStack(spacing: 4) {
                            ProgressView(value: youtubeState.uploadProgress)
                            Text("YouTubeにアップロード中... \(Int(youtubeState.uploadProgress * 100))%")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // アップロード完了
                    if let videoId = youtubeState.uploadedVideoId {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("アップロード完了")
                                .font(.system(size: 11))
                            Spacer()
                            Button("YouTubeで開く") {
                                NSWorkspace.shared.open(URL(string: "https://youtube.com/watch?v=\(videoId)")!)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func selectBGMFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.message = "BGM音声ファイルを選択してください"
        if panel.runModal() == .OK, let url = panel.url {
            youtubeState.exportSettings.bgmFileURL = url
        }
    }

    // MARK: - Project Info

    private var projectInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("プロジェクト情報", systemImage: "info.circle")
                    .font(.system(size: 14, weight: .semibold))

                if let project = youtubeState.project {
                    HStack(spacing: 24) {
                        infoItem(icon: "film.stack", label: "クリップ数", value: "\(project.totalClipCount)")
                        infoItem(icon: "clock", label: "元素材合計", value: formatMinutes(project.totalRawDuration))

                        if let estimated = project.estimatedFinalDuration {
                            infoItem(icon: "scissors", label: "推定最終尺", value: formatMinutes(estimated))
                        }

                        if let analysis = project.storyAnalysis {
                            infoItem(icon: "checkmark.circle", label: "残すセクション",
                                     value: "\(analysis.keptSections.filter(\.isEnabled).count)")
                            infoItem(icon: "trash", label: "削除セクション",
                                     value: "\(analysis.removedSections.filter(\.isRemoved).count)")
                        }

                        // 音量ノーマライズ情報
                        let clipsWithGain = project.clips.filter { $0.volumeGainDB != nil }
                        if !clipsWithGain.isEmpty {
                            infoItem(icon: "speaker.wave.2", label: "音量調整",
                                     value: "\(clipsWithGain.count)クリップ")
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func infoItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Plugin Info

    private var pluginInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("プラグイン設定", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))

                if let presetID = youtubeState.selectedPluginPresetID,
                   let preset = appState.pluginPresets.first(where: { $0.id == presetID }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("プリセット:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                        }

                        if preset.hasCustomTitle {
                            HStack(spacing: 4) {
                                Image(systemName: "textformat")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue)
                                Text("テロップ: \(preset.titleTemplateName ?? "カスタム")")
                                    .font(.system(size: 11))
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "textformat")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text("テロップ: Basic Title")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !preset.effectTemplates.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "camera.filters")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.purple)
                                    Text("エフェクト:")
                                        .font(.system(size: 11))
                                }
                                ForEach(preset.effectTemplates) { ref in
                                    Text("  \(ref.templateName)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !preset.plugins.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "puzzlepiece")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text("カスタムプラグイン: \(preset.plugins.count)個")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("プラグインプリセット未選択（レビュー画面で選択可能）")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Subtitle Settings

    private var subtitleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("字幕スタイル", systemImage: "captions.bubble")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Text("\(youtubeState.subtitleStyle.fontName) \(Int(youtubeState.subtitleStyle.fontSize))pt")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button("設定") {
                        showSubtitleSettings.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showSubtitleSettings, arrowEdge: .bottom) {
                        SubtitleSettingsPanel(style: $youtubeState.subtitleStyle)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - YouTube Metadata

    private var youtubeMetadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("YouTubeメタデータ", systemImage: "play.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()

                    if isGeneratingMeta {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("自動生成") {
                            generateMetadata()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(youtubeState.project == nil)
                    }
                }

                if !generatedChapters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("チャプター")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("コピー") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generatedChapters, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        Text(generatedChapters)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                    }
                }

                if !generatedDescription.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("概要欄")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("コピー") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generatedDescription, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        Text(generatedDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                    }
                }

                if generatedChapters.isEmpty && generatedDescription.isEmpty {
                    Text("「自動生成」ボタンで、ストーリー分析結果からYouTubeチャプター・概要欄テキストを生成します")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    private func generateMetadata() {
        guard let project = youtubeState.project else { return }

        isGeneratingMeta = true

        Task {
            do {
                let service = YouTubeMetadataService()
                let metadata = try await service.generateMetadata(project: project)

                await MainActor.run {
                    youtubeState.youtubeMetadata = metadata
                    generatedChapters = metadata.chapters
                        .map { "\($0.timestamp) \($0.title)" }
                        .joined(separator: "\n")
                    generatedDescription = metadata.fullDescriptionText
                    isGeneratingMeta = false
                }
            } catch {
                await MainActor.run {
                    generatedDescription = "生成に失敗: \(error.localizedDescription)"
                    isGeneratingMeta = false
                }
            }
        }
    }

    // MARK: - Thumbnail Candidates

    private var thumbnailSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("サムネイル候補", systemImage: "photo.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if isExtractingThumbnails {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("抽出") {
                            extractThumbnails()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(youtubeState.project == nil)
                    }
                }

                if thumbnailCandidates.isEmpty {
                    Text("「抽出」ボタンで動画から良いサムネイル候補を自動抽出します")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                        ForEach(thumbnailCandidates) { candidate in
                            VStack(spacing: 4) {
                                Image(nsImage: candidate.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 90)
                                    .cornerRadius(6)
                                    .contextMenu {
                                        Button("画像を保存...") {
                                            saveThumbnail(candidate.image)
                                        }
                                    }

                                HStack(spacing: 4) {
                                    Text(String(format: "%.0f%%", candidate.score * 100))
                                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                                        .foregroundStyle(candidate.score >= 0.7 ? .green : candidate.score >= 0.4 ? .orange : .secondary)
                                    Text(candidate.reason)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func extractThumbnails() {
        guard let project = youtubeState.project else { return }
        isExtractingThumbnails = true
        Task {
            let analyzer = VideoAnalyzer()
            let candidates = await analyzer.extractThumbnailCandidates(clips: project.clips)
            thumbnailCandidates = candidates
            isExtractingThumbnails = false
        }
    }

    private func saveThumbnail(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "thumbnail.png"
        if panel.runModal() == .OK, let url = panel.url {
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
            try? pngData.write(to: url)
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(spacing: 12) {
            if youtubeState.isRendering {
                VStack(spacing: 8) {
                    ProgressView(value: youtubeState.renderProgress)
                    Text("レンダリング中... \(Int(youtubeState.renderProgress * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 300)
            } else {
                switch youtubeState.exportSettings.exportMode {
                case .fcpxml:
                    Button(action: exportYouTubeFCPXML) {
                        HStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 16))
                            Text("FCPXMLエクスポート")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: 300)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(youtubeState.project == nil)

                    Text("Final Cut Proで開いて最終調整・レンダリング")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                case .directRender:
                    Button(action: exportDirectRender) {
                        HStack(spacing: 8) {
                            Image(systemName: "video.badge.waveform")
                                .font(.system(size: 16))
                            Text("動画を直接レンダリング")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: 300)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(youtubeState.project == nil)

                    Text("ffmpegで直接MP4ファイルを生成（FCP不要）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func exportYouTubeFCPXML() {
        guard let project = youtubeState.project else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "\(project.name)_youtube.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let selectedPreset: PluginPreset? = youtubeState.selectedPluginPresetID.flatMap { id in
                    appState.pluginPresets.first { $0.id == id }
                }
                let builder = FCPXMLBuilder()
                let xml = try builder.buildYouTubeTimeline(
                    project: project,
                    subtitleStyle: youtubeState.subtitleStyle,
                    settings: .default,
                    pluginPreset: selectedPreset,
                    exportSettings: youtubeState.exportSettings
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)

                // SRT生成（オプション）
                if youtubeState.exportSettings.generateSRT {
                    let srtURL = saveURL.deletingPathExtension().appendingPathExtension("srt")
                    let srtGen = SRTGenerator()
                    _ = try srtGen.generate(project: project, outputURL: srtURL)
                    successMessage = "FCPXML + SRT字幕を書き出しました"
                } else {
                    successMessage = "YouTube FCPXMLを書き出しました"
                }
                showSuccess = true
            } catch {
                errorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func exportDirectRender() {
        guard let project = youtubeState.project else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name)_final.mp4"

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        youtubeState.isRendering = true
        youtubeState.renderProgress = 0

        Task {
            do {
                // SRT生成
                var srtURL: URL?
                if youtubeState.exportSettings.generateSRT || youtubeState.exportSettings.burnInSubtitles {
                    let srtGen = SRTGenerator()
                    srtURL = try srtGen.generate(project: project)

                    // SRTファイルを動画と同じディレクトリにもコピー
                    if youtubeState.exportSettings.generateSRT {
                        let srtSaveURL = saveURL.deletingPathExtension().appendingPathExtension("srt")
                        try? FileManager.default.copyItem(at: srtURL!, to: srtSaveURL)
                    }
                }

                // ffmpegレンダリング
                let renderer = try FFmpegRenderService()
                try await renderer.render(
                    project: project,
                    exportSettings: youtubeState.exportSettings,
                    srtURL: srtURL,
                    outputURL: saveURL,
                    progressCallback: { progress in
                        Task { @MainActor in
                            youtubeState.renderProgress = progress
                        }
                    }
                )

                await MainActor.run {
                    youtubeState.isRendering = false
                }

                // YouTubeアップロード（オプション）
                if youtubeState.exportSettings.uploadToYouTube && youtubeState.isAuthenticated {
                    await MainActor.run {
                        youtubeState.isUploading = true
                        youtubeState.uploadProgress = 0
                    }

                    do {
                        // メタデータ構築
                        let uploadMetadata: YouTubeUploadMetadata
                        if let meta = youtubeState.youtubeMetadata {
                            uploadMetadata = YouTubeUploadMetadata(
                                from: meta,
                                privacyStatus: youtubeState.exportSettings.privacyStatus,
                                categoryId: youtubeState.exportSettings.categoryId
                            )
                        } else {
                            uploadMetadata = YouTubeUploadMetadata(
                                title: project.name,
                                description: ""
                            )
                        }

                        let uploader = YouTubeUploadService()
                        let videoId = try await uploader.uploadVideo(
                            fileURL: saveURL,
                            metadata: uploadMetadata,
                            progressCallback: { progress in
                                Task { @MainActor in
                                    youtubeState.uploadProgress = progress
                                }
                            }
                        )

                        // サムネイルアップロード（選択されている場合）
                        if let thumbIdx = youtubeState.exportSettings.selectedThumbnailIndex,
                           thumbIdx < thumbnailCandidates.count {
                            let thumbnail = thumbnailCandidates[thumbIdx]
                            try? await uploader.uploadThumbnail(videoId: videoId, image: thumbnail.image)
                        }

                        await MainActor.run {
                            youtubeState.isUploading = false
                            youtubeState.uploadedVideoId = videoId
                            successMessage = "レンダリング＋YouTubeアップロード完了！"
                            showSuccess = true
                        }
                    } catch {
                        await MainActor.run {
                            youtubeState.isUploading = false
                            errorMessage = "アップロード失敗: \(error.localizedDescription)"
                            showError = true
                        }
                    }
                } else {
                    await MainActor.run {
                        successMessage = "動画レンダリング完了: \(saveURL.lastPathComponent)"
                        showSuccess = true
                    }
                }
            } catch {
                await MainActor.run {
                    youtubeState.isRendering = false
                    errorMessage = "レンダリング失敗: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)分\(secs)秒"
    }
}
