import SwiftUI

struct PluginView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPresetID: UUID?
    @State private var showAddPreset = false
    @State private var newPresetName = ""
    @State private var showAddPlugin = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            HSplitView {
                presetList
                    .frame(minWidth: 220, maxWidth: 280)
                presetDetail
            }
        }
        .sheet(isPresented: $showAddPreset) {
            addPresetSheet
        }
        .sheet(isPresented: $showAddPlugin) {
            addPluginSheet
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("プラグイン")
                    .font(.title2.bold())
                Text("FCPプラグインのプリセットを管理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if appState.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }

            Button(action: { appState.scanMotionTemplates() }) {
                Label("再スキャン", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { showAddPreset = true }) {
                Label("プリセット追加", systemImage: "plus")
            }
        }
        .padding()
    }

    // MARK: - Preset List

    private var presetList: some View {
        List(appState.pluginPresets, selection: $selectedPresetID) { preset in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body)
                    HStack(spacing: 4) {
                        if preset.hasCustomTitle {
                            Label(preset.titleTemplateName ?? "テロップ", systemImage: "textformat")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if !preset.effectTemplates.isEmpty {
                            Label("\(preset.effectTemplates.count)エフェクト", systemImage: "camera.filters")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                        if !preset.plugins.isEmpty {
                            Label("\(preset.plugins.count)カスタム", systemImage: "puzzlepiece")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if preset.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            .tag(preset.id)
            .contextMenu {
                Button("デフォルトに設定") {
                    setDefault(preset.id)
                }
                Divider()
                Button("削除", role: .destructive) {
                    deletePreset(preset.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Preset Detail

    private var presetDetail: some View {
        Group {
            if let presetID = selectedPresetID,
               let presetIndex = appState.pluginPresets.firstIndex(where: { $0.id == presetID }) {
                ScrollView {
                    VStack(spacing: 0) {
                        // ヘッダー
                        HStack {
                            Text(appState.pluginPresets[presetIndex].name)
                                .font(.headline)
                            Spacer()
                            Button(action: { showAddPlugin = true }) {
                                Label("カスタムプラグイン追加", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }
                        .padding()
                        Divider()

                        VStack(spacing: 16) {
                            // テロップテンプレート選択
                            titleTemplateSection(presetIndex: presetIndex)

                            // エフェクトテンプレート選択
                            effectTemplateSection(presetIndex: presetIndex)

                            // カスタムプラグイン一覧
                            if !appState.pluginPresets[presetIndex].plugins.isEmpty {
                                customPluginsSection(presetIndex: presetIndex)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                VStack {
                    Text("プリセットを選択してください")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Title Template Section

    private func titleTemplateSection(presetIndex: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("テロップテンプレート", systemImage: "textformat")
                    .font(.system(size: 14, weight: .semibold))

                if appState.titleTemplates.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Motionテンプレートが見つかりません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    MotionTemplatePicker(
                        templates: appState.titleTemplates,
                        selectedUID: Binding(
                            get: { appState.pluginPresets[presetIndex].titleTemplateUID },
                            set: { uid in
                                appState.pluginPresets[presetIndex].titleTemplateUID = uid
                                if let uid = uid,
                                   let t = appState.titleTemplates.first(where: { $0.fcpxmlUID == uid }) {
                                    appState.pluginPresets[presetIndex].titleTemplateName = t.name
                                } else {
                                    appState.pluginPresets[presetIndex].titleTemplateName = nil
                                }
                            }
                        ),
                        label: "テロップ"
                    )
                }

                if let name = appState.pluginPresets[presetIndex].titleTemplateName {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("選択中: \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("クリア") {
                            appState.pluginPresets[presetIndex].titleTemplateUID = nil
                            appState.pluginPresets[presetIndex].titleTemplateName = nil
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } else {
                    Text("未選択（Basic Title を使用）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Effect Template Section

    private func effectTemplateSection(presetIndex: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("エフェクトテンプレート", systemImage: "camera.filters")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    AddEffectButton(appState: appState, presetIndex: presetIndex)
                }

                if appState.pluginPresets[presetIndex].effectTemplates.isEmpty {
                    Text("エフェクトなし")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(appState.pluginPresets[presetIndex].effectTemplates) { ref in
                        HStack {
                            Image(systemName: "camera.filters")
                                .foregroundStyle(.purple)
                                .font(.caption)
                            VStack(alignment: .leading) {
                                Text(ref.templateName)
                                    .font(.system(size: 12))
                                Text(ref.fcpxmlUID)
                                    .font(.system(size: 9).monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.pluginPresets[presetIndex].effectTemplates.removeAll { $0.id == ref.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Custom Plugins Section

    private func customPluginsSection(presetIndex: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("カスタムプラグイン", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))

                ForEach(appState.pluginPresets[presetIndex].plugins) { plugin in
                    HStack {
                        Image(systemName: pluginCategoryIcon(plugin.category))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(plugin.effectName)
                            Text(plugin.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(plugin.effectID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Sheets

    private var addPresetSheet: some View {
        VStack(spacing: 20) {
            Text("新しいプリセット")
                .font(.headline)
            TextField("プリセット名", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("キャンセル") {
                    showAddPreset = false
                    newPresetName = ""
                }
                Button("作成") {
                    let preset = PluginPreset(name: newPresetName)
                    appState.pluginPresets.append(preset)
                    selectedPresetID = preset.id
                    showAddPreset = false
                    newPresetName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30)
    }

    private var addPluginSheet: some View {
        AddPluginSheetView(
            presets: $appState.pluginPresets,
            selectedPresetID: selectedPresetID,
            onDismiss: { showAddPlugin = false }
        )
    }

    // MARK: - Actions

    private func pluginCategoryIcon(_ category: PluginEntry.PluginCategory) -> String {
        switch category {
        case .videoFilter: return "camera.filters"
        case .audioFilter: return "waveform"
        case .transition: return "arrow.right.arrow.left"
        case .title: return "textformat"
        case .generator: return "sparkles"
        }
    }

    private func setDefault(_ id: UUID) {
        for i in appState.pluginPresets.indices {
            appState.pluginPresets[i].isDefault = (appState.pluginPresets[i].id == id)
        }
    }

    private func deletePreset(_ id: UUID) {
        appState.pluginPresets.removeAll { $0.id == id }
        if selectedPresetID == id {
            selectedPresetID = nil
        }
    }
}

// MARK: - Motion Template Picker

struct MotionTemplatePicker: View {
    let templates: [MotionTemplate]
    @Binding var selectedUID: String?
    let label: String

    @State private var selectedPack: String = ""
    @State private var selectedCategory: String = ""

    private var packs: [String] {
        Array(Set(templates.map(\.packName))).sorted()
    }

    private var categoriesForPack: [String] {
        guard !selectedPack.isEmpty else { return [] }
        return Array(Set(templates.filter { $0.packName == selectedPack }.map(\.category))).sorted()
    }

    private var templatesForCategory: [MotionTemplate] {
        guard !selectedPack.isEmpty else { return [] }
        if selectedCategory.isEmpty {
            return templates.filter { $0.packName == selectedPack }
        }
        return templates.filter { $0.packName == selectedPack && $0.category == selectedCategory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // パック選択
            HStack {
                Text("パック:")
                    .font(.caption)
                    .frame(width: 60, alignment: .trailing)
                Picker("", selection: $selectedPack) {
                    Text("選択...").tag("")
                    ForEach(packs, id: \.self) { pack in
                        Text(pack).tag(pack)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedPack) { _ in
                    selectedCategory = ""
                }
            }

            // カテゴリ選択
            if !categoriesForPack.isEmpty {
                HStack {
                    Text("カテゴリ:")
                        .font(.caption)
                        .frame(width: 60, alignment: .trailing)
                    Picker("", selection: $selectedCategory) {
                        Text("全て").tag("")
                        ForEach(categoriesForPack, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // テンプレート選択
            if !templatesForCategory.isEmpty {
                HStack {
                    Text("\(label):")
                        .font(.caption)
                        .frame(width: 60, alignment: .trailing)
                    Picker("", selection: $selectedUID) {
                        Text("未選択").tag(String?.none)
                        ForEach(templatesForCategory) { t in
                            Text(t.name).tag(String?.some(t.fcpxmlUID))
                        }
                    }
                    .pickerStyle(.menu)
                }

                // サムネイルプレビュー
                if let uid = selectedUID,
                   let template = templates.first(where: { $0.fcpxmlUID == uid }),
                   let thumbPath = template.thumbnailPath,
                   let image = NSImage(contentsOfFile: thumbPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 80)
                        .cornerRadius(4)
                        .padding(.leading, 64)
                }
            }
        }
    }
}

// MARK: - Add Effect Button

struct AddEffectButton: View {
    @ObservedObject var appState: AppState
    let presetIndex: Int
    @State private var showPicker = false

    var body: some View {
        Button("追加") {
            showPicker = true
        }
        .controlSize(.small)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            EffectPickerPopover(
                templates: appState.effectTemplates,
                onSelect: { template in
                    let ref = MotionTemplateRef(from: template)
                    appState.pluginPresets[presetIndex].effectTemplates.append(ref)
                    showPicker = false
                },
                onCancel: { showPicker = false }
            )
        }
    }
}

struct EffectPickerPopover: View {
    let templates: [MotionTemplate]
    let onSelect: (MotionTemplate) -> Void
    let onCancel: () -> Void

    @State private var selectedPack = ""
    @State private var selectedCategory = ""
    @State private var searchText = ""

    private var packs: [String] {
        Array(Set(templates.map(\.packName))).sorted()
    }

    private var categories: [String] {
        guard !selectedPack.isEmpty else { return [] }
        return Array(Set(templates.filter { $0.packName == selectedPack }.map(\.category))).sorted()
    }

    private var filtered: [MotionTemplate] {
        var result = templates
        if !selectedPack.isEmpty {
            result = result.filter { $0.packName == selectedPack }
        }
        if !selectedCategory.isEmpty {
            result = result.filter { $0.category == selectedCategory }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("エフェクト選択")
                .font(.headline)

            HStack {
                Picker("パック", selection: $selectedPack) {
                    Text("全て").tag("")
                    ForEach(packs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedPack) { _ in selectedCategory = "" }

                if !categories.isEmpty {
                    Picker("カテゴリ", selection: $selectedCategory) {
                        Text("全て").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }

            TextField("検索...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filtered) { template in
                Button {
                    onSelect(template)
                } label: {
                    HStack {
                        if let thumb = template.thumbnailPath,
                           let image = NSImage(contentsOfFile: thumb) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: 40, height: 30)
                                .cornerRadius(3)
                        }
                        VStack(alignment: .leading) {
                            Text(template.name)
                                .font(.system(size: 12))
                            Text("\(template.packName) / \(template.category)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 200)

            Button("キャンセル", action: onCancel)
                .controlSize(.small)
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Add Plugin Sheet (Legacy)

struct AddPluginSheetView: View {
    @Binding var presets: [PluginPreset]
    let selectedPresetID: UUID?
    let onDismiss: () -> Void

    @State private var effectName = ""
    @State private var effectID = ""
    @State private var effectUID = ""
    @State private var category: PluginEntry.PluginCategory = .videoFilter

    var body: some View {
        VStack(spacing: 20) {
            Text("カスタムプラグインを追加")
                .font(.headline)

            Form {
                TextField("エフェクト名", text: $effectName)
                TextField("エフェクトID (FCPXML用)", text: $effectID)
                TextField("エフェクトUID (FCP識別子)", text: $effectUID)
                    .textFieldStyle(.roundedBorder)
                Text("例: FxPlug:14B39AEF-607D-42DF-... や .../Filters.localized/...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("カテゴリ", selection: $category) {
                    ForEach(PluginEntry.PluginCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
            }
            .frame(width: 400)

            HStack {
                Button("キャンセル") { onDismiss() }
                Button("追加") {
                    guard let presetID = selectedPresetID,
                          let idx = presets.firstIndex(where: { $0.id == presetID }) else { return }
                    let plugin = PluginEntry(
                        effectID: effectID,
                        effectName: effectName,
                        effectUID: effectUID,
                        category: category
                    )
                    presets[idx].plugins.append(plugin)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectName.isEmpty || effectID.isEmpty)
            }
        }
        .padding(30)
    }
}
