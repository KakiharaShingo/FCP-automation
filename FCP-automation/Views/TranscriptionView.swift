import SwiftUI
import UniformTypeIdentifiers
import AVKit
import AppKit

struct TranscriptionView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragOver = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var autoScroll = true
    @State private var isReformatting = false
    @State private var showSubtitle = true
    @State private var showSubtitleSettings = false
    @State private var subtitleStyle = SubtitleStyle()

    var body: some View {
        VStack(spacing: 0) {
            if appState.importedFileURL == nil {
                dropZone
            } else if appState.isTranscribing {
                progressSection
            } else if appState.transcriptionResult != nil {
                editorLayout
            } else {
                fileLoadedSection
            }
        }
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Editor Layout (Vrew風)

    private var editorLayout: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()

            HSplitView {
                playerPane
                    .frame(minWidth: 380, idealWidth: 500)

                segmentListPane
                    .frame(minWidth: 340, idealWidth: 520)
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.importedFileName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let result = appState.transcriptionResult {
                            Label("\(result.segments.count)", systemImage: "text.bubble")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if appState.videoDuration > 0 {
                            Label(TranscriptionSegment.formatTime(appState.videoDuration),
                                  systemImage: "clock")
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Toggle(isOn: $showSubtitle) {
                    Image(systemName: "captions.bubble")
                }
                .toggleStyle(.checkbox)
                .help("字幕プレビュー")

                Button(action: { showSubtitleSettings.toggle() }) {
                    Image(systemName: "textformat.size")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("字幕スタイル設定")
                .popover(isPresented: $showSubtitleSettings, arrowEdge: .bottom) {
                    SubtitleSettingsPanel(style: $subtitleStyle)
                }

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line.compact")
                }
                .toggleStyle(.checkbox)
                .help("自動追従")

                Divider()
                    .frame(height: 16)

                Button(action: reformatWithAI) {
                    HStack(spacing: 4) {
                        if isReformatting {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        if isReformatting && appState.reformatProgress > 0 {
                            Text("\(Int(appState.reformatProgress * 100))%")
                                .font(.system(size: 12).monospacedDigit())
                        } else {
                            Text("AI整形")
                                .font(.system(size: 12))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReformatting || appState.transcriptionResult == nil)
                .help("AIで句読点区切りに整形")

                Button(action: copyAllText) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("全文コピー")

                Button(action: exportFCPXML) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("FCPXML")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("FCPXMLエクスポート")

                Divider()
                    .frame(height: 16)

                Button(action: { appState.reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("リセット")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Player Pane

    private var playerPane: some View {
        VStack(spacing: 0) {
            // 動画プレイヤー + 字幕オーバーレイ
            if let player = appState.player {
                ZStack(alignment: .center) {
                    VideoPlayerView(player: player)

                    // 字幕オーバーレイ（動画の上に直接重ねる）
                    if showSubtitle {
                        subtitleOverlay
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black)
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 32, weight: .thin))
                            Text("プレビューなし")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            PlaybackControlsView()
                .environmentObject(appState)

            Spacer(minLength: 8)

            currentSegmentInfo
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Subtitle Overlay

    private var subtitleOverlay: some View {
        VStack {
            if subtitleStyle.verticalPosition == .bottom || subtitleStyle.verticalPosition == .center {
                Spacer()
            }

            if let segmentID = appState.currentSegmentID,
               let result = appState.transcriptionResult,
               let segment = result.segments.first(where: { $0.id == segmentID }) {
                Text(segment.text)
                    .font(.custom(subtitleStyle.fontName, size: subtitleStyle.fontSize).weight(subtitleStyle.fontWeight))
                    .foregroundStyle(subtitleStyle.textColor)
                    .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, subtitleStyle.horizontalPadding)
                    .padding(.vertical, subtitleStyle.verticalPadding)
                    .frame(maxWidth: .infinity)
                    .background(
                        subtitleStyle.backgroundColor
                            .opacity(subtitleStyle.backgroundOpacity)
                    )
            }

            if subtitleStyle.verticalPosition == .top || subtitleStyle.verticalPosition == .center {
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.currentSegmentID)
    }

    private var currentSegmentInfo: some View {
        Group {
            if let segmentID = appState.currentSegmentID,
               let result = appState.transcriptionResult,
               let segment = result.segments.first(where: { $0.id == segmentID }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(segment.formattedTimeRange)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(segment.text)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Segment List Pane

    private var segmentListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("セグメント")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = appState.transcriptionResult {
                    Text("\(result.segments.count) 件")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let result = appState.transcriptionResult {
                            ForEach(Array(result.segments.enumerated()), id: \.element.id) { index, segment in
                                SegmentEditorView(
                                    segment: segment,
                                    index: index,
                                    isActive: segment.id == appState.currentSegmentID,
                                    totalSegments: result.segments.count
                                )
                                .id(segment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .onChange(of: appState.currentSegmentID) { _, newID in
                    if autoScroll, let id = newID {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drop Zone (初期状態)

    private var dropZone: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(isDragOver ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        .frame(width: 100, height: 100)

                    Image(systemName: isDragOver ? "arrow.down.circle.fill" : "film.stack")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(isDragOver ? Color.accentColor : .secondary)
                        .symbolEffect(.bounce, value: isDragOver)
                }

                VStack(spacing: 8) {
                    Text("動画・音声ファイルをドロップ")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isDragOver ? .primary : .secondary)

                    Text("MP4, MOV, M4A, WAV, MP3")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                }

                Button(action: selectFile) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("ファイルを選択")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isDragOver ? Color.accentColor.opacity(0.05) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isDragOver ? Color.accentColor : Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: isDragOver ? 2 : 1.5, dash: [10, 6])
                    )
            )
            .padding(40)
            .animation(.easeInOut(duration: 0.2), value: isDragOver)

            Spacer()
        }
    }

    // MARK: - Progress (文字起こし中 + キャンセル)

    private var progressSection: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                        .frame(width: 80, height: 80)

                    Circle()
                        .trim(from: 0, to: appState.transcriptionProgress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: appState.transcriptionProgress)

                    Text("\(Int(appState.transcriptionProgress * 100))%")
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }

                VStack(spacing: 6) {
                    Text("文字起こし中")
                        .font(.system(size: 15, weight: .medium))

                    Text(appState.importedFileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: appState.transcriptionProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
                    .tint(.accentColor)

                if appState.transcriptionProgress > 0 && appState.transcriptionProgress < 1 {
                    VStack(spacing: 4) {
                        if let eta = appState.transcriptionETA {
                            Text(eta)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if appState.videoDuration > 0 {
                            Text("素材尺: \(Int(appState.videoDuration) / 60)分\(Int(appState.videoDuration) % 60)秒")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // キャンセル（リセット）ボタン
                Button(action: { appState.reset() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text("キャンセルして削除")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(40)

            Spacer()
        }
    }

    // MARK: - File Loaded (文字起こし前 + 削除可能)

    private var fileLoadedSection: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                if let player = appState.player {
                    VideoPlayerView(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)

                    PlaybackControlsView()
                        .environmentObject(appState)
                        .frame(maxWidth: 520)
                }

                VStack(spacing: 4) {
                    Text(appState.importedFileName)
                        .font(.system(size: 15, weight: .medium))

                    if appState.videoDuration > 0 {
                        Text(TranscriptionSegment.formatTime(appState.videoDuration))
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(action: startTranscription) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble")
                            Text("文字起こしを開始")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: { appState.reset() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("削除")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(32)

            Spacer()
        }
    }

    // MARK: - Actions

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.mpeg4Movie, UTType.quickTimeMovie,
            UTType.audio, UTType.wav, UTType.mp3
        ]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.importFile(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                appState.importFile(url: url)
            }
        }
        return true
    }

    private func startTranscription() {
        guard let url = appState.importedFileURL else { return }
        appState.isTranscribing = true
        appState.transcriptionProgress = 0.0
        appState.transcriptionStartTime = Date()

        Task {
            do {
                let service = WhisperService(modelPath: appState.whisperModelPath, speedPreset: appState.whisperSpeedPreset)
                let result = try await service.transcribe(
                    fileURL: url,
                    userDictionary: appState.userDictionary,
                    maxSegmentLength: appState.maxSegmentLength,
                    progressCallback: { progress in
                        Task { @MainActor in
                            appState.transcriptionProgress = progress
                        }
                    }
                )
                appState.transcriptionResult = result
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            appState.isTranscribing = false
        }
    }

    private func exportFCPXML() {
        guard let result = appState.transcriptionResult,
              let fileURL = appState.importedFileURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "\(appState.importedFileName)_transcription.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let builder = FCPXMLBuilder()
                let xml = try builder.buildTranscriptionTimeline(
                    mediaURL: fileURL,
                    transcription: result
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func reformatWithAI() {
        guard let result = appState.transcriptionResult else { return }
        isReformatting = true
        appState.reformatProgress = 0.0

        Task {
            do {
                let service = try ClaudeAPIService()
                let reformatResult = try await service.reformatTranscription(
                    transcription: result,
                    userDictionary: appState.userDictionary,
                    maxSegmentLength: appState.maxSegmentLength,
                    progressCallback: { progress in
                        Task { @MainActor in
                            appState.reformatProgress = progress
                        }
                    }
                )
                appState.transcriptionResult = TranscriptionResult(
                    segments: reformatResult.segments,
                    language: result.language,
                    duration: result.duration
                )
            } catch {
                errorMessage = "AI整形に失敗: \(error.localizedDescription)"
                showError = true
            }
            appState.reformatProgress = 0.0
            isReformatting = false
        }
    }

    private func copyAllText() {
        guard let result = appState.transcriptionResult else { return }
        let text = result.segments.map { segment in
            "[\(segment.formattedStart)] \(segment.text)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Subtitle Settings Panel

struct SubtitleSettingsPanel: View {
    @Binding var style: SubtitleStyle
    @State private var fontSearchText = ""

    private var filteredFonts: [(name: String, display: String)] {
        let all = SubtitleStyle.availableFonts
        if fontSearchText.isEmpty { return all }
        return all.filter { $0.display.localizedCaseInsensitiveContains(fontSearchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字幕スタイル")
                .font(.system(size: 13, weight: .semibold))

            // フォント検索 + 選択
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("フォント")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)

                    VStack(spacing: 4) {
                        TextField("フォント検索...", text: $fontSearchText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 200)

                        Picker("", selection: $style.fontName) {
                            ForEach(filteredFonts, id: \.name) { font in
                                Text(font.display)
                                    .font(.system(size: 11))
                                    .tag(font.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }

            // 文字サイズ
            HStack {
                Text("サイズ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Slider(value: $style.fontSize, in: 10...40, step: 1)
                    .frame(width: 120)
                Text("\(Int(style.fontSize))pt")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }

            // 太さ
            HStack {
                Text("太さ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Picker("", selection: $style.fontWeight) {
                    Text("細い").tag(Font.Weight.light)
                    Text("標準").tag(Font.Weight.regular)
                    Text("中太").tag(Font.Weight.semibold)
                    Text("太い").tag(Font.Weight.bold)
                    Text("極太").tag(Font.Weight.black)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Divider()

            // 文字色
            HStack {
                Text("文字色")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                ColorPicker("", selection: $style.textColor)
                    .labelsHidden()
            }

            // 背景色 + 透明度
            HStack {
                Text("背景色")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                ColorPicker("", selection: $style.backgroundColor)
                    .labelsHidden()
                Slider(value: $style.backgroundOpacity, in: 0...1, step: 0.1)
                    .frame(width: 80)
                Text("\(Int(style.backgroundOpacity * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }

            Divider()

            // 縁取り（ストローク）
            HStack {
                Text("縁取り")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Toggle("", isOn: $style.strokeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if style.strokeEnabled {
                    ColorPicker("", selection: $style.strokeColor)
                        .labelsHidden()
                    Slider(value: $style.strokeWidth, in: 0.5...5.0, step: 0.5)
                        .frame(width: 80)
                    Text("\(String(format: "%.1f", style.strokeWidth))px")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                }
            }

            Divider()

            // 位置
            HStack {
                Text("位置")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Picker("", selection: $style.verticalPosition) {
                    ForEach(SubtitleStyle.SubtitlePosition.allCases, id: \.self) { pos in
                        Text(pos.rawValue).tag(pos)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            // プレビュー
            previewBox
        }
        .padding(16)
        .frame(width: 320)
    }

    private var previewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.black)
                .frame(height: 80)

            VStack {
                if style.verticalPosition == .bottom || style.verticalPosition == .center {
                    Spacer()
                }

                Text("字幕プレビュー")
                    .font(.custom(style.fontName, size: style.fontSize * 0.7).weight(style.fontWeight))
                    .foregroundStyle(style.textColor)
                    .shadow(color: style.strokeEnabled ? style.strokeColor : .black.opacity(0.9),
                            radius: style.strokeEnabled ? style.strokeWidth : 2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(style.backgroundColor.opacity(style.backgroundOpacity))

                if style.verticalPosition == .top || style.verticalPosition == .center {
                    Spacer()
                }
            }
        }
        .frame(height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
