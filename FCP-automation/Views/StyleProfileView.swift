import SwiftUI

struct StyleProfileView: View {
    @EnvironmentObject var appState: AppState

    @State private var youtubeURL: String = ""
    @State private var isAnalyzing: Bool = false
    @State private var analysisStatus: String = ""
    @State private var errorMessage: String?
    @State private var videoCount: Int = 3

    private let ytdlp = YTDLPService()

    var body: some View {
        Form {
            // yt-dlpインストール状態
            if !ytdlp.checkInstallation() {
                Section {
                    installationGuide
                }
            }

            Section("YouTube動画 / チャンネルからスタイル分析") {
                Text("動画URL → その1本を分析。チャンネルURL → 最新N本をまとめて分析し、チャンネル全体のスタイルを抽出します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("YouTube URL (動画 or チャンネル)", text: $youtubeURL)
                        .textFieldStyle(.roundedBorder)
                    Button("分析") {
                        analyzeURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(youtubeURL.trimmingCharacters(in: .whitespaces).isEmpty || isAnalyzing || !ytdlp.checkInstallation())
                }

                if isChannelURL {
                    HStack {
                        Text("分析する動画数:")
                            .font(.system(size: 12))
                        Picker("", selection: $videoCount) {
                            Text("3本").tag(3)
                            Text("5本").tag(5)
                            Text("8本").tag(8)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }

                if isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(analysisStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("保存済みプロファイル (\(appState.styleProfiles.count)件)") {
                if appState.styleProfiles.isEmpty {
                    Text("まだプロファイルがありません")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(appState.styleProfiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Profile Row

    private func profileRow(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(profile.videoTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // デフォルトトグル
                Button(profile.isDefault ? "デフォルト" : "デフォルトに設定") {
                    setDefault(profileID: profile.id)
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(profile.isDefault ? .green : .secondary)

                Button {
                    deleteProfile(profileID: profile.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
            }

            // スタイル詳細（折り畳み可能）
            DisclosureGroup("スタイル詳細") {
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("テンポ", profile.pacing)
                    detailRow("構成", profile.chapterStyle)
                    detailRow("編集", profile.editingNotes)
                    Divider()
                    Text("AIガイダンス:")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(profile.guidance)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 11))

            HStack {
                Text(profile.durationFormatted)
                Text("•")
                Text(profile.createdDate, style: .date)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    // MARK: - Installation Guide

    private var installationGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("yt-dlpがインストールされていません")
                    .font(.system(size: 13, weight: .medium))
            }

            Text("ターミナルで以下を実行してください:")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox {
                Text("brew install yt-dlp")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Computed

    private var isChannelURL: Bool {
        ytdlp.isChannelOrPlaylist(url: youtubeURL.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Actions

    private func analyzeURL() {
        let url = youtubeURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        isAnalyzing = true
        errorMessage = nil

        if isChannelURL {
            analyzeChannel(url: url)
        } else {
            analyzeSingleVideo(url: url)
        }
    }

    private func analyzeSingleVideo(url: String) {
        analysisStatus = "動画情報を取得中..."

        Task {
            do {
                let videoInfo = try await ytdlp.extractInfo(url: url) { status in
                    Task { @MainActor in
                        analysisStatus = status
                    }
                }
                analysisStatus = "AIがスタイルを分析中（Sonnet）..."

                let claude = try ClaudeAPIService()
                var profile = try await claude.analyzeYouTubeStyle(videoInfo: videoInfo)
                profile.sourceURL = url

                appState.styleProfiles.append(profile)
                youtubeURL = ""
                analysisStatus = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func analyzeChannel(url: String) {
        analysisStatus = "チャンネルの動画一覧を取得中..."

        Task {
            do {
                // Step 1: 動画URL一覧を取得
                let videoURLs = try await ytdlp.listVideoURLs(channelURL: url, maxCount: videoCount)
                analysisStatus = "0/\(videoURLs.count) 本の動画情報を取得中..."

                // Step 2: 各動画の情報取得
                let videoInfos = try await ytdlp.extractMultipleInfos(urls: videoURLs) { current, total in
                    Task { @MainActor in
                        analysisStatus = "\(current)/\(total) 本の動画情報を取得中..."
                    }
                }

                guard !videoInfos.isEmpty else {
                    errorMessage = "字幕付きの動画が見つかりませんでした"
                    isAnalyzing = false
                    return
                }

                // Step 3: 2段階スタイル分析（Haiku要約 → Sonnet統合）
                let channelName = url.components(separatedBy: "/").last ?? "チャンネル"
                let claude = try ClaudeAPIService()
                var profile = try await claude.analyzeChannelStyle(
                    videoInfos: videoInfos,
                    channelName: channelName,
                    progressCallback: { status in
                        Task { @MainActor in
                            analysisStatus = status
                        }
                    }
                )
                profile.sourceURL = url

                appState.styleProfiles.append(profile)
                youtubeURL = ""
                analysisStatus = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func setDefault(profileID: UUID) {
        for i in appState.styleProfiles.indices {
            appState.styleProfiles[i].isDefault = (appState.styleProfiles[i].id == profileID)
        }
    }

    private func deleteProfile(profileID: UUID) {
        appState.styleProfiles.removeAll { $0.id == profileID }
    }
}
