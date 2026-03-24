import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragOver = false
    @State private var isAnalyzing = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if appState.timelineItems.isEmpty {
                dropZone
            } else {
                timelineContent
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
                Text("タイムライン")
                    .font(.title2.bold())
                Text("素材をドロップして自動配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !appState.timelineItems.isEmpty {
                HStack(spacing: 12) {
                    Button("クリア") {
                        appState.timelineItems = []
                    }
                    Button("FCPXMLにエクスポート") {
                        exportTimelineFCPXML()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(isDragOver ? .blue : .secondary)

            Text("素材ファイルをここにドロップ")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("複数ファイル対応 (MP4, MOV)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("ファイルを選択...") {
                selectFiles()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragOver ? Color.blue : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding()
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
    }

    private var timelineContent: some View {
        VStack(spacing: 0) {
            if isAnalyzing {
                ProgressView("素材を解析中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(TimelineItem.ClipType.allCases, id: \.self) { clipType in
                        let items = appState.timelineItems.filter { $0.clipType == clipType }
                        if !items.isEmpty {
                            Section("\(clipType.rawValue) (\(items.count))") {
                                ForEach(items) { item in
                                    timelineItemRow(item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func timelineItemRow(_ item: TimelineItem) -> some View {
        HStack {
            clipTypeIcon(item.clipType)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.body)
                HStack(spacing: 8) {
                    if item.metadata.width > 0 {
                        Text("\(item.metadata.width)x\(item.metadata.height)")
                    }
                    if item.metadata.fps > 0 {
                        Text(String(format: "%.0f fps", item.metadata.fps))
                    }
                    Text(formatDuration(item.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { item.clipType },
                set: { newType in
                    if let idx = appState.timelineItems.firstIndex(where: { $0.id == item.id }) {
                        appState.timelineItems[idx].clipType = newType
                    }
                }
            )) {
                ForEach(TimelineItem.ClipType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .frame(width: 120)
        }
        .padding(.vertical, 2)
    }

    private func clipTypeIcon(_ type: TimelineItem.ClipType) -> some View {
        let (icon, color): (String, Color) = switch type {
        case .main: ("video.fill", .blue)
        case .bRoll: ("video", .green)
        case .insert: ("photo.fill", .orange)
        case .audio: ("waveform", .purple)
        }
        return Image(systemName: icon)
            .foregroundStyle(color)
            .frame(width: 24)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Actions

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            analyzeFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let serialQueue = DispatchQueue(label: "handleDrop.urls")
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    serialQueue.sync { urls.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            analyzeFiles(urls)
        }
        return true
    }

    private func analyzeFiles(_ urls: [URL]) {
        isAnalyzing = true
        Task {
            let analyzer = VideoAnalyzer()
            var items: [TimelineItem] = []
            for url in urls {
                if let item = await analyzer.analyze(fileURL: url) {
                    items.append(item)
                }
            }
            appState.timelineItems = items
            isAnalyzing = false
        }
    }

    private func exportTimelineFCPXML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "timeline_auto.fcpxml"

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                let builder = FCPXMLBuilder()
                let xml = try builder.buildTimelineFromItems(items: appState.timelineItems)
                try xml.write(to: saveURL, atomically: true, encoding: .utf8)
            } catch {
                exportErrorMessage = "FCPXML書き出しに失敗: \(error.localizedDescription)"
                showExportError = true
            }
        }
    }
}
