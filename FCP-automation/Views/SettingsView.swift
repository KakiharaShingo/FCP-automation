import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var claudeAPIKey: String = ""
    @State private var whisperModelPath: String = ""
    @State private var showModelDownloadInfo = false
    @State private var statusMessage: String = ""
    @State private var statusMessageColor: Color = .green
    @State private var isTestingAPI = false
    @State private var apiResponseDetail: String = ""
    @State private var projectSettings = ProjectSettings.default
    @State private var newDictionaryWord: String = ""
    @State private var googleClientID: String = ""
    @State private var isAuthenticatingGoogle: Bool = false
    @State private var googleAuthStatus: String = ""

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            apiSettings
                .tabItem {
                    Label("API", systemImage: "key")
                }

            dictionarySettings
                .tabItem {
                    Label("辞書", systemImage: "character.book.closed")
                }

            editingSettings
                .tabItem {
                    Label("編集", systemImage: "scissors")
                }

            StyleProfileView()
                .tabItem {
                    Label("スタイル", systemImage: "paintpalette")
                }

            youtubeSettings
                .tabItem {
                    Label("YouTube", systemImage: "play.rectangle")
                }
        }
        .frame(width: 600, height: 600)
        .onAppear {
            claudeAPIKey = APIConfig.loadClaudeAPIKey() ?? ""
            whisperModelPath = appState.whisperModelPath
            appState.loadUserDictionary()
            appState.loadSettings()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Whisper モデル") {
                // 利用可能なモデルをピッカーで選択
                let availableModels = detectAvailableModels()
                if availableModels.count > 1 {
                    Picker("モデル選択", selection: Binding(
                        get: {
                            // 現在のパスがリストに存在しなければ最初のモデルを返す
                            if availableModels.contains(where: { $0.path == whisperModelPath }) {
                                return whisperModelPath
                            }
                            return availableModels.first?.path ?? ""
                        },
                        set: { whisperModelPath = $0 }
                    )) {
                        ForEach(availableModels, id: \.path) { model in
                            Text(model.label).tag(model.path)
                        }
                    }
                    if whisperModelPath.contains("turbo") {
                        Text("turboモデル: large-v3と同等精度で4〜6倍高速（蒸留モデル）")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                HStack {
                    TextField("モデルファイルパス", text: $whisperModelPath)
                        .textFieldStyle(.roundedBorder)
                    Button("選択...") {
                        selectModelFile()
                    }
                }

                Button("モデルのダウンロード方法を表示") {
                    showModelDownloadInfo = true
                }
                .font(.caption)
            }

            Section("文字起こし設定") {
                HStack {
                    Text("処理速度")
                    Picker("", selection: $appState.whisperSpeedPreset) {
                        Text("高速（精度やや低）").tag(0)
                        Text("バランス").tag(1)
                        Text("高精度（時間かかる）").tag(2)
                    }
                    .frame(width: 200)
                }
                Text(whisperSpeedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("セグメント最大文字数")
                    Picker("", selection: $appState.maxSegmentLength) {
                        Text("20文字（短い）").tag(20)
                        Text("30文字").tag(30)
                        Text("40文字（標準）").tag(40)
                        Text("60文字").tag(60)
                        Text("80文字（長い）").tag(80)
                    }
                    .frame(width: 180)
                }
                Text("短くすると改行が増え、字幕表示に適します。長くするとタイムスタンプ精度が下がります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("出力設定") {
                HStack {
                    Text("プロジェクト名")
                    TextField("", text: $projectSettings.projectName)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("フレームレート")
                    Picker("", selection: $projectSettings.framerate) {
                        Text("23.976 fps").tag(23.976)
                        Text("24 fps").tag(24.0)
                        Text("29.97 fps").tag(29.97)
                        Text("30 fps").tag(30.0)
                        Text("59.94 fps").tag(59.94)
                        Text("60 fps").tag(60.0)
                    }
                    .frame(width: 150)
                }
                HStack {
                    Text("解像度")
                    Picker("", selection: Binding(
                        get: { "\(projectSettings.width)x\(projectSettings.height)" },
                        set: { val in
                            let parts = val.split(separator: "x")
                            if parts.count == 2 {
                                projectSettings.width = Int(parts[0]) ?? 1920
                                projectSettings.height = Int(parts[1]) ?? 1080
                            }
                        }
                    )) {
                        Text("1920x1080 (FHD)").tag("1920x1080")
                        Text("3840x2160 (4K)").tag("3840x2160")
                        Text("1280x720 (HD)").tag("1280x720")
                    }
                    .frame(width: 180)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("保存") {
                        appState.whisperModelPath = whisperModelPath
                        statusMessage = "設定を保存しました"
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showModelDownloadInfo) {
            modelDownloadInfoSheet
        }
    }

    @State private var isTestingLocalLLM = false
    @State private var localLLMStatus: String = ""
    @State private var localLLMStatusColor: Color = .green

    private var apiSettings: some View {
        Form {
            Section("LLMバックエンド選択") {
                Picker("使用するLLM", selection: $appState.useLocalLLM) {
                    Text("Claude API（Anthropic）").tag(false)
                    Text("ローカルLLM（Ollama互換）").tag(true)
                }
                .pickerStyle(.radioGroup)

                if appState.useLocalLLM {
                    Text("開発・テスト用: ローカルまたはLAN内のOllama互換サーバーを使用します。APIコスト不要。")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Text("本番用: Anthropic Claude APIを使用します。高精度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if appState.useLocalLLM {
                Section("ローカルLLM設定") {
                    HStack {
                        Text("エンドポイント")
                        TextField("http://localhost:11434", text: $appState.localLLMEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Ollamaデフォルト: http://localhost:11434\nLAN内PC: http://192.168.x.x:11434")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("モデル名")
                        TextField("llama3.1:8b", text: $appState.localLLMModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("推奨: llama3.1:8b（軽量）/ llama3.1:70b（高精度）/ gemma2:27b")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Spacer()
                        Button("接続テスト") {
                            testLocalLLMConnection()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTestingLocalLLM)
                    }
                    if isTestingLocalLLM {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("ローカルLLMに接続中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !localLLMStatus.isEmpty {
                        Text(localLLMStatus)
                            .font(.caption)
                            .foregroundStyle(localLLMStatusColor)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Section("Claude API (Anthropic)") {
                    SecureField("APIキー", text: $claudeAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("チャプター分割・内容要約に使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("モデル設定") {
                    Toggle("全タスクをHaikuで実行（テスト・コスト削減用）", isOn: $appState.forceHaikuMode)
                    if appState.forceHaikuMode {
                        Text("ON: ストーリー分析・スタイル分析など全てHaiku 4.5で実行します。精度は下がりますがコストが大幅に安くなります。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("OFF: 通常モード — 軽量タスクはHaiku、分析タスクはSonnetを使用します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("APIキーを保存") {
                            guard !claudeAPIKey.isEmpty else {
                                statusMessage = "APIキーを入力してください"
                                statusMessageColor = .orange
                                return
                            }
                            APIConfig.saveClaudeAPIKey(claudeAPIKey)
                            if let saved = APIConfig.loadClaudeAPIKey(), saved == claudeAPIKey {
                                statusMessage = "APIキーを保存しました"
                                statusMessageColor = .green
                            } else {
                                statusMessage = "保存に失敗しました。再度お試しください"
                                statusMessageColor = .red
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("接続テスト") {
                            testAPIConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingAPI)
                    }
                    if isTestingAPI {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("APIに接続中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusMessageColor)
                    }
                    if !apiResponseDetail.isEmpty {
                        GroupBox {
                            Text(apiResponseDetail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dictionarySettings: some View {
        Form {
            Section("ユーザー辞書") {
                Text("よく使う単語・固有名詞を登録すると、AI校正時に参照して正確に変換します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("単語を入力（例: SwiftUI, Final Cut Pro, FCPXML）", text: $newDictionaryWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDictionaryWord() }
                    Button("追加") { addDictionaryWord() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newDictionaryWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("登録済み単語 (\(appState.userDictionary.count)件)") {
                if appState.userDictionary.isEmpty {
                    Text("まだ単語が登録されていません")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        FlowLayout(spacing: 6) {
                            ForEach(appState.userDictionary, id: \.self) { word in
                                HStack(spacing: 4) {
                                    Text(word)
                                        .font(.system(size: 12))
                                    Button {
                                        appState.userDictionary.removeAll { $0 == word }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addDictionaryWord() {
        let word = newDictionaryWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !appState.userDictionary.contains(word) else { return }
        appState.userDictionary.append(word)
        newDictionaryWord = ""
    }

    private var editingSettings: some View {
        Form {
            Section("FCPXML") {
                HStack {
                    Text("FCPXMLバージョン")
                    Text(projectSettings.fcpxmlVersion)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var modelDownloadInfoSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Whisperモデルのダウンロード")
                .font(.headline)

            Text("ターミナルで以下を実行してください:")
                .font(.body)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("# Homebrew でインストール")
                        .foregroundStyle(.secondary)
                    Text("brew install whisper-cpp")
                        .font(.system(.body, design: .monospaced))

                    Divider()

                    Text("# または直接モデルをダウンロード")
                        .foregroundStyle(.secondary)
                    Text("""
                    mkdir -p ~/Library/Application\\ Support/FCP-automation/Models
                    cd ~/Library/Application\\ Support/FCP-automation/Models
                    curl -L -o ggml-large-v3.bin \\
                      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
                    """)
                    .font(.system(.caption, design: .monospaced))
                }
                .padding(8)
                .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("閉じる") {
                    showModelDownloadInfo = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 550)
    }

    private struct WhisperModelInfo: Identifiable {
        let path: String
        let label: String
        var id: String { path }
    }

    private func detectAvailableModels() -> [WhisperModelInfo] {
        let modelsDir = APIConfig.defaultModelDirectory
        var models: [WhisperModelInfo] = []

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else {
            return models
        }

        for file in files.sorted() where file.hasSuffix(".bin") && file.hasPrefix("ggml-") {
            let path = modelsDir.appendingPathComponent(file).path
            let label: String
            if file.contains("turbo") {
                label = "\(file)  (高速・推奨)"
            } else if file.contains("large") {
                label = "\(file)  (高精度)"
            } else if file.contains("medium") {
                label = "\(file)  (中精度)"
            } else if file.contains("small") {
                label = "\(file)  (軽量)"
            } else {
                label = file
            }
            models.append(WhisperModelInfo(path: path, label: label))
        }
        return models
    }

    // MARK: - YouTube Settings

    private var youtubeSettings: some View {
        Form {
            Section("Google OAuth 設定") {
                HStack {
                    Text("Client ID")
                    TextField("Google OAuth Client ID", text: $googleClientID)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Client IDを保存") {
                    GoogleOAuthConfig.saveClientID(googleClientID)
                    googleAuthStatus = "Client IDを保存しました"
                }
                .disabled(googleClientID.isEmpty)

                Text("Google Cloud Console → APIとサービス → 認証情報 → OAuth 2.0 クライアントID（デスクトップアプリ）で作成してください。YouTube Data API v3 を有効化する必要があります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("認証状態") {
                if GoogleOAuthConfig.hasValidTokens {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("YouTube認証済み")
                        Spacer()
                        Button("サインアウト") {
                            GoogleOAuthConfig.deleteAllTokens()
                            googleAuthStatus = "サインアウトしました"
                        }
                        .foregroundStyle(.red)
                    }
                } else {
                    HStack {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                        Text("未認証")
                        Spacer()
                        if isAuthenticatingGoogle {
                            ProgressView()
                                .controlSize(.small)
                            Text("ブラウザで認証中...")
                                .font(.caption)
                        } else {
                            Button("Googleで認証") {
                                authenticateGoogle()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!GoogleOAuthConfig.isConfigured)
                        }
                    }
                }

                if !googleAuthStatus.isEmpty {
                    Text(googleAuthStatus)
                        .font(.caption)
                        .foregroundStyle(googleAuthStatus.contains("失敗") ? .red : .green)
                }
            }

            Section("注意事項") {
                Text("・YouTube Data API の無料枠は 1日10,000ユニット（動画アップロード = 1,600ユニット → 約6回/日）\n・アップロードは非公開で開始し、確認後に公開に変更することを推奨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            googleClientID = GoogleOAuthConfig.loadClientID() ?? ""
        }
    }

    private func authenticateGoogle() {
        isAuthenticatingGoogle = true
        googleAuthStatus = "ブラウザで認証してください..."

        Task {
            do {
                let oauth = GoogleOAuthService()
                try await oauth.authorize()
                await MainActor.run {
                    isAuthenticatingGoogle = false
                    googleAuthStatus = "認証成功！"
                }
            } catch {
                await MainActor.run {
                    isAuthenticatingGoogle = false
                    googleAuthStatus = "認証失敗: \(error.localizedDescription)"
                }
            }
        }
    }

    private var whisperSpeedDescription: String {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch appState.whisperSpeedPreset {
        case 0:
            let threads = max(4, cores - 2)
            return "best-of=1, \(threads)スレッド使用。処理速度を最優先。ハルシネーションが若干増える可能性あり。"
        case 2:
            let threads = max(4, cores / 2)
            return "best-of=5, \(threads)スレッド使用。最高精度だが処理時間が長い。"
        default:
            let threads = max(4, cores / 2)
            return "best-of=3, \(threads)スレッド使用。速度と精度のバランス。"
        }
    }

    private func selectModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = "Whisperモデルファイル (.bin) を選択してください"
        if panel.runModal() == .OK, let url = panel.url {
            whisperModelPath = url.path
        }
    }

    private func testAPIConnection() {
        // まず保存されたキーがあるか確認
        guard let key = APIConfig.loadClaudeAPIKey(), !key.isEmpty else {
            statusMessage = "APIキーが保存されていません。先にAPIキーを保存してください"
            statusMessageColor = .orange
            return
        }
        isTestingAPI = true
        statusMessage = ""
        apiResponseDetail = ""

        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.timeoutInterval = 15

                let body: [String: Any] = [
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 16,
                    "messages": [["role": "user", "content": "ping"]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

                await MainActor.run {
                    isTestingAPI = false
                    switch httpResponse?.statusCode {
                    case 200:
                        statusMessage = "API接続成功 ✓"
                        statusMessageColor = .green
                        // レスポンス詳細を構築
                        var details: [String] = []
                        if let model = json?["model"] as? String {
                            details.append("モデル: \(model)")
                        }
                        if let usage = json?["usage"] as? [String: Any] {
                            let input = usage["input_tokens"] as? Int ?? 0
                            let output = usage["output_tokens"] as? Int ?? 0
                            details.append("トークン: 入力 \(input) / 出力 \(output)")
                        }
                        if let content = json?["content"] as? [[String: Any]],
                           let text = content.first?["text"] as? String {
                            details.append("応答: \"\(text)\"")
                        }
                        if let stopReason = json?["stop_reason"] as? String {
                            details.append("停止理由: \(stopReason)")
                        }
                        apiResponseDetail = details.joined(separator: "\n")
                    case 401:
                        statusMessage = "認証失敗: APIキーが無効です"
                        statusMessageColor = .red
                        if let error = json?["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            apiResponseDetail = message
                        }
                    case 403:
                        statusMessage = "アクセス拒否: APIキーの権限を確認してください"
                        statusMessageColor = .red
                        if let error = json?["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            apiResponseDetail = message
                        }
                    case 429:
                        statusMessage = "API接続成功 (レートリミット中、しばらく待ってください)"
                        statusMessageColor = .orange
                    case let code?:
                        let bodyStr = String(data: data, encoding: .utf8) ?? ""
                        statusMessage = "API応答エラー (HTTP \(code))"
                        statusMessageColor = .red
                        apiResponseDetail = String(bodyStr.prefix(300))
                    case nil:
                        statusMessage = "レスポンスを取得できませんでした"
                        statusMessageColor = .red
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingAPI = false
                    statusMessage = "接続エラー: \(error.localizedDescription)"
                    statusMessageColor = .red
                }
            }
        }
    }

    private func testLocalLLMConnection() {
        isTestingLocalLLM = true
        localLLMStatus = ""

        Task {
            do {
                let service = try ClaudeAPIService()
                let result = try await service.testLocalLLMConnection()
                await MainActor.run {
                    isTestingLocalLLM = false
                    localLLMStatus = result
                    localLLMStatusColor = .green
                }
            } catch {
                await MainActor.run {
                    isTestingLocalLLM = false
                    localLLMStatus = "接続失敗: \(error.localizedDescription)"
                    localLLMStatusColor = .red
                }
            }
        }
    }
}

// MARK: - Flow Layout (タグ用)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if i < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
