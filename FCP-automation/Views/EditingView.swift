import SwiftUI
import UniformTypeIdentifiers

struct EditingView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings = ProjectSettings.default
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var isDragOver = false
    @State private var isSilenceAnalyzing = false
    @State private var silenceCutFileURL: URL?
    @State private var silenceCutSegments: [AudioSegment] = []
    // バッチ処理
    @State private var batchFiles: [URL] = []
    @State private var batchResults: [URL: [AudioSegment]] = [:]
    @State private var batchProgress: Int = 0
    @State private var isBatchProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if appState.transcriptionResult == nil {
                noDataSection
            } else {
                HSplitView {
                    settingsPanel
                        .frame(minWidth: 280, maxWidth: 320)
                    resultPanel
                }
            }
        }
        .alert("エラー", isPresented: $showExportError) {
            Button("OK") {}
        } message: {
            Text(exportErrorMessage)
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("無音カット")
                    .font(.title2.bold())
                Text("無音区間を自動検出してカット（フォルダ一括対応）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !appState.silentSegments.isEmpty || !appState.fillerSegments.isEmpty {
                Button("FCPXMLにエクスポート") {
                    exportCutFCPXML()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var noDataSection: some View {
        VStack(spacing: 0) {
            // 文字起こし済みファイルがある場合のメッセージ
            if appState.importedFileURL == nil {
                silenceCutDropZone
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("「解析を実行」で無音・フィラーを検出します")
                        .foregroundStyle(.secondary)
                    Text("または下の「無音カットのみ」に動画をドロップ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Divider().padding(.vertical, 8)

                    silenceCutDropZone
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "mts", "mxf"]

    private var silenceCutDropZone: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ドロップゾーン
                VStack(spacing: 12) {
                    Image(systemName: "scissors.badge.ellipsis")
                        .font(.system(size: 36))
                        .foregroundStyle(isDragOver ? .blue : .secondary)

                    Text("無音カット")
                        .font(.headline)

                    Text("動画ファイルまたはフォルダをドロップ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("フォルダ内の全動画を一括処理して個別にFCPXML出力")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if batchFiles.isEmpty && silenceCutFileURL == nil {
                        Button("ファイル/フォルダを選択...") {
                            selectSilenceCutFile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: 500)
                .padding(30)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isDragOver ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                )
                .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                    handleSilenceCutDrop(providers: providers)
                    return true
                }

                // 設定
                if !batchFiles.isEmpty || silenceCutFileURL != nil {
                    silenceCutSettings
                }

                // 処理中
                if isSilenceAnalyzing || isBatchProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        if isBatchProcessing {
                            Text("無音検出中: \(batchProgress)/\(batchFiles.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("無音を検出中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 単一ファイル結果
                if let fileURL = silenceCutFileURL, !silenceCutSegments.isEmpty, batchFiles.isEmpty {
                    singleFileResult(fileURL: fileURL)
                }

                // バッチ結果
                if !batchResults.isEmpty {
                    batchResultsView
                }
            }
            .padding()
        }
    }

    private var silenceCutSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("無音検出設定")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    Text("閾値")
                        .font(.system(size: 11))
                    Slider(value: Binding(
                        get: { Double(settings.silenceThresholdDB) },
                        set: { settings.silenceThresholdDB = Float($0) }
                    ), in: -60...(-10))
                    Text("\(Int(settings.silenceThresholdDB))dB")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 40)
                }
                HStack {
                    Text("最小長")
                        .font(.system(size: 11))
                    Slider(value: $settings.minimumSilenceDuration, in: 0.1...3.0, step: 0.1)
                    Text(String(format: "%.1fs", settings.minimumSilenceDuration))
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 40)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 500)
    }

    private func singleFileResult(fileURL: URL) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(silenceCutSegments.count)箇所の無音")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            let totalCut = silenceCutSegments.reduce(0.0) { $0 + $1.duration }
            Text(String(format: "カット合計: %.1f秒", totalCut))
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            HStack(spacing: 12) {
                Button(action: { exportSilenceCutFCPXML() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("FCPXMLエクスポート")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("クリア") {
                    silenceCutFileURL = nil
                    silenceCutSegments = []
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        .frame(maxWidth: 500)
    }

    private var batchResultsView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(batchResults.count)ファイル処理完了")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { exportBatchFCPXML() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("全てエクスポート")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("クリア") {
                    batchFiles = []
                    batchResults = [:]
                    batchProgress = 0
                }
                .buttonStyle(.bordered)
            }

            // ファイルごとの結果一覧
            VStack(spacing: 4) {
                ForEach(batchFiles.filter { batchResults[$0] != nil }, id: \.self) { url in
                    let segments = batchResults[url] ?? []
                    let totalCut = segments.reduce(0.0) { $0 + $1.duration }
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text("\(segments.count)箇所")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1fs削減", totalCut))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        .frame(maxWidth: 500)
    }

    private var settingsPanel: some View {
        Form {
            Section("無音検出") {
                HStack {
                    Text("閾値 (dB)")
                    Slider(value: Binding(
                        get: { Double(settings.silenceThresholdDB) },
                        set: { settings.silenceThresholdDB = Float($0) }
                    ), in: -60...(-10))
                    Text("\(Int(settings.silenceThresholdDB)) dB")
                        .frame(width: 50)
                }
                HStack {
                    Text("最小長 (秒)")
                    Slider(value: $settings.minimumSilenceDuration, in: 0.1...3.0, step: 0.1)
                    Text(String(format: "%.1f s", settings.minimumSilenceDuration))
                        .frame(width: 50)
                }
            }

            Section("フィラーワード") {
                ForEach(settings.fillerWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(action: {
                            settings.fillerWords.removeAll { $0 == word }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                AddFillerWordRow(fillerWords: $settings.fillerWords)
            }

            Section {
                Button("解析を実行") {
                    runAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isAnalyzing)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            if appState.isAnalyzing {
                ProgressView("解析中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.silentSegments.isEmpty && appState.fillerSegments.isEmpty {
                Text("解析結果がありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                segmentList
            }
        }
    }

    private var segmentList: some View {
        List {
            if !appState.silentSegments.isEmpty {
                Section("無音区間 (\(appState.silentSegments.count)箇所)") {
                    ForEach(appState.silentSegments) { segment in
                        segmentRow(segment, color: .orange)
                    }
                }
            }
            if !appState.fillerSegments.isEmpty {
                Section("フィラーワード (\(appState.fillerSegments.count)箇所)") {
                    ForEach(appState.fillerSegments) { segment in
                        segmentRow(segment, color: .red)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: AudioSegment, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(segment.formattedTimeRange)
                .font(.caption.monospaced())
            if !segment.label.isEmpty {
                Text("「\(segment.label)」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1f秒", segment.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func runAnalysis() {
        guard let fileURL = appState.importedFileURL else { return }
        appState.isAnalyzing = true

        Task {
            // 無音検出
            let audioAnalyzer = AudioAnalyzer()
            let silentSegments = await audioAnalyzer.detectSilence(
                in: fileURL,
                thresholdDB: settings.silenceThresholdDB,
                minimumDuration: settings.minimumSilenceDuration
            )
            appState.silentSegments = silentSegments

            // フィラーワード検出
            if let transcription = appState.transcriptionResult {
                let fillerDetector = FillerWordDetector(fillerWords: settings.fillerWords)
                let fillerSegments = fillerDetector.detect(in: transcription)
                appState.fillerSegments = fillerSegments
            }

            appState.isAnalyzing = false
        }
    }

    private func exportCutFCPXML() {
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
                    settings: settings
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
            } catch {
                exportErrorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showExportError = true
            }
        }
    }

    private func selectSilenceCutFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            processDroppedURLs(panel.urls)
        }
    }

    private func handleSilenceCutDrop(providers: [NSItemProvider]) {
        let serialQueue = DispatchQueue(label: "silenceCutDrop")
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
            processDroppedURLs(urls)
        }
    }

    private func processDroppedURLs(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                collectVideoFiles(in: url, into: &files)
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return }

        if files.count == 1 {
            // 単一ファイル
            batchFiles = []
            batchResults = [:]
            analyzeSilenceOnly(fileURL: files[0])
        } else {
            // バッチ処理
            silenceCutFileURL = nil
            silenceCutSegments = []
            batchFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            batchResults = [:]
            runBatchAnalysis()
        }
    }

    private func collectVideoFiles(in folderURL: URL, into files: inout [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            if videoExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
    }

    private func analyzeSilenceOnly(fileURL: URL) {
        silenceCutFileURL = fileURL
        silenceCutSegments = []
        isSilenceAnalyzing = true

        Task {
            let analyzer = AudioAnalyzer()
            let segments = await analyzer.detectSilence(
                in: fileURL,
                thresholdDB: settings.silenceThresholdDB,
                minimumDuration: settings.minimumSilenceDuration
            )
            silenceCutSegments = segments
            isSilenceAnalyzing = false
        }
    }

    private func runBatchAnalysis() {
        isBatchProcessing = true
        batchProgress = 0
        batchResults = [:]

        Task {
            let analyzer = AudioAnalyzer()
            for (i, url) in batchFiles.enumerated() {
                let segments = await analyzer.detectSilence(
                    in: url,
                    thresholdDB: settings.silenceThresholdDB,
                    minimumDuration: settings.minimumSilenceDuration
                )
                batchResults[url] = segments
                batchProgress = i + 1
            }
            isBatchProcessing = false
        }
    }

    private func exportSilenceCutFCPXML() {
        guard let fileURL = silenceCutFileURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "\(fileURL.deletingPathExtension().lastPathComponent)_silencecut.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let builder = FCPXMLBuilder()
                let xml = try builder.buildAutoCutTimeline(
                    mediaURL: fileURL,
                    cutSegments: silenceCutSegments,
                    settings: settings
                )
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
            } catch {
                exportErrorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showExportError = true
            }
        }
    }

    private func exportBatchFCPXML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "出力先フォルダを選択"

        guard panel.runModal() == .OK, let outputDir = panel.url else { return }

        var successCount = 0
        var errors: [String] = []
        let builder = FCPXMLBuilder()

        for url in batchFiles {
            guard let segments = batchResults[url], !segments.isEmpty else { continue }
            let outputName = url.deletingPathExtension().lastPathComponent + "_silencecut.fcpxml"
            let outputURL = outputDir.appendingPathComponent(outputName)
            do {
                let xml = try builder.buildAutoCutTimeline(
                    mediaURL: url,
                    cutSegments: segments,
                    settings: settings
                )
                try xml.write(to: outputURL, atomically: true, encoding: .utf8)
                successCount += 1
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if errors.isEmpty {
            // 成功
            exportErrorMessage = ""
        } else {
            exportErrorMessage = "\(successCount)件成功、\(errors.count)件失敗:\n" + errors.joined(separator: "\n")
            showExportError = true
        }
    }
}

struct AddFillerWordRow: View {
    @Binding var fillerWords: [String]
    @State private var newWord = ""

    var body: some View {
        HStack {
            TextField("新しいワード", text: $newWord)
                .textFieldStyle(.roundedBorder)
            Button("追加") {
                let trimmed = newWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !fillerWords.contains(trimmed) {
                    fillerWords.append(trimmed)
                    newWord = ""
                }
            }
            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
