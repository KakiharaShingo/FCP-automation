import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @EnvironmentObject var appState: AppState
    @State private var exportMode: ExportMode = .integrated
    @State private var subtitleStyle = SubtitleStyle()
    @State private var showSubtitleSettings = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var isRunningAnalysis = false

    enum ExportMode: String, CaseIterable {
        case integrated = "統合"
        case individual = "個別"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    modeSelector
                    statusSection

                    if exportMode == .integrated {
                        integratedSection
                    } else {
                        individualSection
                    }
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

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("エクスポート")
                    .font(.title2.bold())
                Text("FCPXMLを書き出してFinal Cut Proにインポート")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        Picker("エクスポートモード", selection: $exportMode) {
            ForEach(ExportMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                statusCard(
                    icon: "text.bubble",
                    title: "文字起こし",
                    isReady: appState.transcriptionResult != nil,
                    detail: appState.transcriptionResult.map { "\($0.segments.count)セグメント" } ?? "未実行"
                )

                statusCard(
                    icon: "scissors",
                    title: "自動カット解析",
                    isReady: hasAnalysisResults,
                    detail: hasAnalysisResults
                        ? "無音\(appState.silentSegments.count) / フィラー\(appState.fillerSegments.count)"
                        : "未実行"
                )
            }

            if let fileName = appState.importedFileURL?.lastPathComponent {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusCard(icon: String, title: String, isReady: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(isReady ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Integrated Section

    private var integratedSection: some View {
        VStack(spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("統合エクスポート", systemImage: "rectangle.stack.badge.play")
                        .font(.system(size: 14, weight: .semibold))

                    Text("自動カット（無音・フィラー除去）＋ テロップ（字幕）を1つのFCPXMLにまとめて出力します。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if canIntegratedExport {
                        integratedPreview
                    }

                    Divider()

                    // 字幕スタイル設定
                    HStack {
                        Text("字幕スタイル:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Text("\(subtitleStyle.fontName) \(Int(subtitleStyle.fontSize))pt")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("設定") {
                            showSubtitleSettings.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $showSubtitleSettings, arrowEdge: .bottom) {
                            SubtitleSettingsPanel(style: $subtitleStyle)
                        }
                    }

                    Divider()

                    HStack {
                        if !hasAnalysisResults && appState.transcriptionResult != nil {
                            Button(action: runQuickAnalysis) {
                                HStack(spacing: 4) {
                                    if isRunningAnalysis {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.7)
                                    }
                                    Text(isRunningAnalysis ? "解析中..." : "自動カット解析を実行")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRunningAnalysis)
                        }

                        Spacer()

                        Button(action: exportIntegrated) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                Text("統合エクスポート")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canIntegratedExport)
                    }
                }
                .padding(4)
            }
        }
    }

    private var integratedPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("プレビュー")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            HStack(spacing: 20) {
                previewItem(icon: "scissors", label: "カット箇所", value: "\(totalCutCount)箇所")
                previewItem(icon: "captions.bubble", label: "テロップ", value: "\(appState.transcriptionResult?.segments.count ?? 0)件")
                previewItem(icon: "clock", label: "推定動画長", value: estimatedDuration)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Individual Section

    private var individualSection: some View {
        VStack(spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("文字起こしFCPXML", systemImage: "text.bubble")
                        .font(.system(size: 14, weight: .semibold))

                    Text("文字起こし結果をマーカーとして配置したFCPXMLを出力します。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(action: exportTranscription) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("エクスポート")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.transcriptionResult == nil)
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("自動カットFCPXML", systemImage: "scissors")
                        .font(.system(size: 14, weight: .semibold))

                    Text("無音・フィラーワードを除去したカット済みタイムラインを出力します。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(action: exportAutoCut) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("エクスポート")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasAnalysisResults)
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: - Computed Properties

    private var hasAnalysisResults: Bool {
        !appState.silentSegments.isEmpty || !appState.fillerSegments.isEmpty
    }

    private var canIntegratedExport: Bool {
        appState.transcriptionResult != nil && hasAnalysisResults && appState.importedFileURL != nil
    }

    private var totalCutCount: Int {
        appState.silentSegments.count + appState.fillerSegments.count
    }

    private var estimatedDuration: String {
        let totalCutTime = (appState.silentSegments + appState.fillerSegments)
            .reduce(0.0) { $0 + $1.duration }
        let remaining = max(appState.videoDuration - totalCutTime, 0)
        return TranscriptionSegment.formatTime(remaining)
    }

    // MARK: - Actions

    private func runQuickAnalysis() {
        guard let fileURL = appState.importedFileURL else { return }
        isRunningAnalysis = true

        Task {
            let audioAnalyzer = AudioAnalyzer()
            let settings = ProjectSettings.default
            let silentSegments = await audioAnalyzer.detectSilence(
                in: fileURL,
                thresholdDB: settings.silenceThresholdDB,
                minimumDuration: settings.minimumSilenceDuration
            )
            appState.silentSegments = silentSegments

            if let transcription = appState.transcriptionResult {
                let fillerDetector = FillerWordDetector(fillerWords: settings.fillerWords)
                let fillerSegments = fillerDetector.detect(in: transcription)
                appState.fillerSegments = fillerSegments
            }

            isRunningAnalysis = false
        }
    }

    private func exportIntegrated() {
        guard let fileURL = appState.importedFileURL,
              let transcription = appState.transcriptionResult else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "\(appState.importedFileName)_integrated.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let cutSegments = appState.silentSegments + appState.fillerSegments
                let builder = FCPXMLBuilder()
                let xml = try builder.buildIntegratedTimeline(
                    mediaURL: fileURL,
                    cutSegments: cutSegments,
                    transcription: transcription,
                    subtitleStyle: subtitleStyle,
                    settings: .default
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
                successMessage = "統合FCPXMLを書き出しました"
                showSuccess = true
            } catch {
                errorMessage = "統合FCPXML書き出しに失敗: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func exportTranscription() {
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
                successMessage = "文字起こしFCPXMLを書き出しました"
                showSuccess = true
            } catch {
                errorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func exportAutoCut() {
        guard let fileURL = appState.importedFileURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "\(appState.importedFileName)_autocut.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let cutSegments = appState.silentSegments + appState.fillerSegments
                let builder = FCPXMLBuilder()
                let xml = try builder.buildAutoCutTimeline(
                    mediaURL: fileURL,
                    cutSegments: cutSegments,
                    settings: .default
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
                successMessage = "自動カットFCPXMLを書き出しました"
                showSuccess = true
            } catch {
                errorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showError = true
            }
        }
    }
}
