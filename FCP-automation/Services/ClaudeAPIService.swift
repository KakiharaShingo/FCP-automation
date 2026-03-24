import Foundation

class ClaudeAPIService {
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"

    // タスク別モデル選択
    // Haiku: チャプター検出・要約（軽量・安価）
    // Sonnet: テキスト校正・ストーリー分析（判断力が必要）
    private let haikuModel = "claude-haiku-4-5-20251001"
    private let sonnetModel = "claude-sonnet-4-5-20250929"

    /// Sonnet指定タスクを強制的にHaikuで実行するモード（テスト・コスト削減用）
    var forceHaikuMode: Bool = false

    /// forceHaikuMode時はSonnetの代わりにHaikuを返す
    private var effectiveSonnetModel: String {
        forceHaikuMode ? haikuModel : sonnetModel
    }

    // MARK: - ローカルLLM設定（Ollama互換）
    /// ローカルLLMモード有効時はClaude APIの代わりにOllama互換エンドポイントを使用
    var useLocalLLM: Bool = false
    var localLLMEndpoint: String = "http://localhost:11434"
    var localLLMModel: String = "llama3.1:8b"

    enum APIError: LocalizedError {
        case noAPIKey
        case requestFailed(String)
        case invalidResponse
        case rateLimited(retryAfter: Double?)
        case localLLMUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Claude APIキーが設定されていません。設定画面で入力してください。"
            case .requestFailed(let reason): return "API呼び出しに失敗: \(reason)"
            case .invalidResponse: return "APIからの応答が無効です"
            case .rateLimited: return "APIレートリミットに達しました。しばらく待ってから再試行します。"
            case .localLLMUnavailable(let reason): return "ローカルLLMに接続できません: \(reason)"
            }
        }
    }

    init() throws {
        self.forceHaikuMode = UserDefaults.standard.bool(forKey: "forceHaikuMode")
        self.useLocalLLM = UserDefaults.standard.bool(forKey: "useLocalLLM")
        self.localLLMEndpoint = UserDefaults.standard.string(forKey: "localLLMEndpoint") ?? "http://localhost:11434"
        self.localLLMModel = UserDefaults.standard.string(forKey: "localLLMModel") ?? "llama3.1:8b"

        // ローカルLLMモード時はAPIキー不要
        if useLocalLLM {
            self.apiKey = ""
        } else {
            guard let key = APIConfig.loadClaudeAPIKey(), !key.isEmpty else {
                throw APIError.noAPIKey
            }
            self.apiKey = key
        }
    }

    // MARK: - Chapter Detection

    struct Chapter: Codable, Identifiable {
        let id: UUID
        let title: String
        let startTime: TimeInterval
        let summary: String

        init(title: String, startTime: TimeInterval, summary: String = "") {
            self.id = UUID()
            self.title = title
            self.startTime = startTime
            self.summary = summary
        }
    }

    func detectChapters(transcription: TranscriptionResult) async throws -> [Chapter] {
        let prompt = """
        以下は動画の文字起こしです。話題の区切りを検出し、チャプターを生成してください。

        ルール:
        - チャプターは3〜10個程度
        - 各チャプターにはタイトル（15文字以内）と開始時間（秒数）を付けてください
        - JSON形式で出力: [{"title": "チャプター名", "start_time": 秒数, "summary": "1行要約"}]
        - JSON以外のテキストは出力しないでください

        文字起こし:
        \(formatTranscriptionForAPI(transcription))
        """

        let response = try await sendMessage(prompt)

        // JSONの部分を抽出（前後の余分なテキストを除去）
        let jsonString = extractJSON(from: response)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        struct ChapterDTO: Codable {
            let title: String
            let start_time: Double
            let summary: String?
        }

        let chapters = try JSONDecoder().decode([ChapterDTO].self, from: jsonData)
        return chapters.map { Chapter(title: $0.title, startTime: $0.start_time, summary: $0.summary ?? "") }
    }

    // MARK: - Content Summary

    /// 汎用プロンプト送信（メタデータ生成等に使用）
    func sendPrompt(_ prompt: String, maxTokens: Int = 4096) async throws -> String {
        return try await sendMessage(prompt, maxTokens: maxTokens)
    }

    func generateSummary(transcription: TranscriptionResult) async throws -> String {
        let prompt = """
        以下は動画の文字起こしです。YouTube概要欄に使える要約を日本語で作成してください。

        フォーマット:
        1. 動画の概要（2〜3行）
        2. 主なトピック（箇条書き）
        3. ハッシュタグ提案（5個程度）

        文字起こし:
        \(formatTranscriptionForAPI(transcription))
        """

        return try await sendMessage(prompt)
    }

    // MARK: - Text Reformatting (句読点で整形)

    struct ReformattedSegment: Codable {
        let text: String
        let start_time: Double
        let end_time: Double
    }

    /// リテイク検出結果のDTO
    private struct RetakeSegmentDTO: Codable {
        let start_time: Double
        let end_time: Double
        let original_text: String
        let reason: String
    }

    /// AI整形のレスポンス（新形式: セグメント + リテイク）
    private struct ReformatResponseDTO: Codable {
        let segments: [ReformattedSegment]
        let retakes: [RetakeSegmentDTO]?
    }

    /// AI整形の結果（整形済みセグメント + リテイク検出結果）
    struct ReformatResult {
        let segments: [TranscriptionSegment]
        let retakeSegments: [AudioSegment]
    }

    func reformatTranscription(
        transcription: TranscriptionResult,
        userDictionary: [String] = [],
        maxSegmentLength: Int = 40,
        progressCallback: @escaping (Double) -> Void = { _ in }
    ) async throws -> ReformatResult {
        let dictionarySection: String
        if !userDictionary.isEmpty {
            let wordList = userDictionary.map { "- \($0)" }.joined(separator: "\n")
            dictionarySection = "\n★★★【ユーザー辞書 — 最優先で適用せよ】★★★\n" +
                "以下は話者が実際に使う正しい単語リストです。\n" +
                "音声認識は音が似た別の単語に誤変換することが非常に多いため、\n" +
                "テキスト中に以下の単語と「読みが近い・音が似ている」文字列があれば、\n" +
                "必ず辞書の正しい表記に置換してください。\n\n" +
                "具体例:\n" +
                "- 辞書に「屋根裏」がある場合: 「屋根寄り」「やねうり」「屋根売り」→ 全て「屋根裏」に修正\n" +
                "- 辞書に「SwiftUI」がある場合: 「スイフトUI」「Swift UI」→「SwiftUI」に修正\n" +
                "- 辞書に「FCPXML」がある場合: 「FCPエックスML」→「FCPXML」に修正\n\n" +
                "辞書単語:\n\(wordList)\n"
        } else {
            dictionarySection = ""
        }

        // セグメントをバッチに分割（50セグメントずつ）
        let batchSize = 50
        let allSegments = transcription.segments
        let batches = stride(from: 0, to: allSegments.count, by: batchSize).map {
            Array(allSegments[$0..<min($0 + batchSize, allSegments.count)])
        }

        var allResults: [TranscriptionSegment] = []
        var allRetakes: [AudioSegment] = []
        let totalBatches = batches.count

        for (batchIndex, batch) in batches.enumerated() {
            // レートリミット回避: 2バッチ目以降は3秒待機（ローカルLLM時はスキップ）
            if batchIndex > 0 && !useLocalLLM {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }

            let batchData = batch.map { segment in
                "{\"text\": \"\(segment.text.replacingOccurrences(of: "\"", with: "\\\""))\", \"start_time\": \(String(format: "%.2f", segment.startTime)), \"end_time\": \(String(format: "%.2f", segment.endTime))}"
            }.joined(separator: "\n")

            let prompt = """
            以下は音声認識（whisper）による動画の文字起こしデータです。
            テキストのクリーンアップ・校正と、句読点による自然な文単位への分割を行ってください。
            また、リテイク（言い直し）箇所を検出してください。
            \(dictionarySection)
            【削除ルール（最優先）】:
            - フィラーワードを完全に削除する（えー、あー、うーん、えっと、あのー、まあ、なんか、こう 等）
            - フィラーワードだけのセグメントは丸ごと削除（出力に含めない）
            - 文頭・文中・文末のフィラーワードも全て除去

            【ノイズ・ハルシネーション除去ルール（重要）】:
            - 音声認識が環境音・無音区間で幻聴した文は必ず削除する
            - 典型的なハルシネーションパターンを削除:
              ・同じフレーズの不自然な繰り返し（「ありがとうございます」が連続する等）
              ・前後の文脈と全く無関係な唐突な文
              ・意味が通らない短い断片（「はい」「うん」「そうですね」が孤立）
              ・BGM・効果音・環境音しかない区間に出現するテキスト
              ・話者が明らかに話していない区間の文（風の音、足音、食器の音などの区間）
            - 音声認識が周囲の雑音（ラジオ、テレビ、BGM等）を拾った文は削除する
            - 話者の発言と明らかに無関係な断片は削除する
            - 判断に迷う場合は削除する（存在しないテロップより、誤テロップの方が問題）

            【リテイク検出ルール】:
            - 話者が同じ内容を言い直している箇所を検出する
            - 文を途中で止めて最初から言い直した場合、古い方（最初の試行）をリテイクとしてマーク
            - 短い訂正（1-2語の言い換え）はマークしない。明確な文単位のやり直しのみ
            - リテイク区間は元のセグメントのstart_time/end_timeを使って正確に指定する
            - segmentsからは整理後のクリーンなテキストを出力し、リテイク区間はretakesに別途記録する

            【校正ルール】:
            - ★ユーザー辞書の単語と音が似ている誤変換は、必ず辞書の表記に修正する（最重要）
            - 音声認識の誤変換を修正（同音異義語の間違い、漢字の誤変換）
            - 不自然な単語の区切りを修正（例: 「き ょう は」→「今日は」）
            - 話者が実際に伝えたい内容（挨拶、説明等）は必ず残す
            - 話し言葉のニュアンスは維持する（過度に書き言葉にしない）

            【分割ルール】:
            - 句読点（。！？）を文の区切りとして使用
            - 読点（、）では基本的に分割しない（ただし長すぎる場合は分割可）
            - 1セグメントあたり最大\(maxSegmentLength)文字以内に収める（厳守）
            - \(maxSegmentLength)文字を超える場合は、読点や助詞の位置で強制的に分割する

            【タイムスタンプルール — 最重要】:
            - 入力データのstart_timeとend_timeは絶対に変更しないこと
            - セグメントを削除せずそのまま残す場合: start_timeとend_timeをそのまま返す
            - セグメントを丸ごと削除する場合: 出力に含めない
            - 複数セグメントを結合する場合: 最初のセグメントのstart_time + 最後のセグメントのend_timeを使う
            - 1つのセグメントを分割する場合: 元のstart_timeからend_timeの範囲内でテキスト長の比率で按分する

            【出力形式】:
            - JSONオブジェクトで出力:
            {"segments": [{"text": "クリーンアップ済みテキスト", "start_time": 秒数, "end_time": 秒数}], "retakes": [{"start_time": 秒数, "end_time": 秒数, "original_text": "リテイク部分の元テキスト", "reason": "言い直し"}]}
            - segmentsには整形済みの残すべきテキストを入れる
            - retakesにはカットすべきリテイク区間を入れる（なければ空配列 []）
            - 削除したセグメント（フィラーのみ・意味不明）はsegmentsに含めない
            - JSON以外のテキストは出力しないでください

            文字起こしデータ:
            \(batchData)
            """

            let response = try await sendMessage(prompt, model: effectiveSonnetModel)

            let jsonString = extractJSON(from: response)
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw APIError.invalidResponse
            }

            // 新形式（オブジェクト: segments + retakes）をtry → フォールバックで旧形式（配列）
            var reformatted: [ReformattedSegment]
            if let dto = try? JSONDecoder().decode(ReformatResponseDTO.self, from: jsonData) {
                reformatted = dto.segments
                if let retakes = dto.retakes {
                    for retake in retakes {
                        allRetakes.append(AudioSegment(
                            startTime: retake.start_time,
                            endTime: retake.end_time,
                            type: .retake,
                            label: retake.reason
                        ))
                    }
                }
            } else {
                reformatted = try JSONDecoder().decode([ReformattedSegment].self, from: jsonData)
            }

            // AIが返したタイムスタンプを元のセグメントと突き合わせて補正
            let corrected = correctTimestamps(reformatted: reformatted, originals: batch)
            allResults.append(contentsOf: corrected)

            let progress = Double(batchIndex + 1) / Double(totalBatches)
            progressCallback(progress)
        }

        return ReformatResult(segments: allResults, retakeSegments: allRetakes)
    }

    // MARK: - YouTube Style Analysis

    func analyzeYouTubeStyle(videoInfo: YTDLPService.YouTubeVideoInfo) async throws -> StyleProfile {
        var chaptersDetail = ""
        if !videoInfo.chapters.isEmpty {
            chaptersDetail = videoInfo.chapters.enumerated().map { (i, ch) in
                "  \(i+1). [\(formatSeconds(ch.startTime))-\(formatSeconds(ch.endTime))] \(ch.title)"
            }.joined(separator: "\n")
        }

        // 字幕テキストが長すぎる場合は先頭と末尾を使う
        let subtitleText: String
        if videoInfo.subtitleText.count > 30000 {
            let prefix = String(videoInfo.subtitleText.prefix(15000))
            let suffix = String(videoInfo.subtitleText.suffix(15000))
            subtitleText = prefix + "\n...(中略)...\n" + suffix
        } else {
            subtitleText = videoInfo.subtitleText
        }

        let prompt = """
        あなたはYouTube動画の編集スタイルアナリストです。
        以下の動画の字幕とメタデータから、この動画の編集スタイルを詳細に分析してください。

        【動画情報】:
        - タイトル: \(videoInfo.title)
        - 尺: \(formatSeconds(videoInfo.duration))
        - チャプター数: \(videoInfo.chapters.count)
        \(chaptersDetail)

        【字幕テキスト】:
        \(subtitleText)

        【分析項目と出力JSON】:
        {
          "pacing": "テンポの特徴（テンポ速め/標準/ゆったり + 具体的な説明）",
          "chapter_style": "チャプター構成の特徴",
          "editing_notes": "カット頻度、間の取り方、トーク密度の特徴",
          "guidance": "このスタイルを再現するためのAI編集アシスタント向け指示文（200-400字）"
        }

        guidanceは最重要項目です。別の動画を編集するAIに「この人っぽく編集して」と
        指示するときに使うガイダンスです。具体的かつ再現可能な指示にしてください。
        例: 「冒頭15秒以内にフックを入れる。チャプター間にブリッジ（振り返り+次の話題予告）を挟む。テンポは1セクション平均60秒以内。脱線トークは大胆にカットするが、笑いのある脱線は残す。」

        JSON以外のテキストは出力しないでください。
        """

        let response = try await sendMessage(prompt, model: effectiveSonnetModel, maxTokens: 4096)
        let jsonString = extractJSON(from: response)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        struct StyleDTO: Codable {
            let pacing: String
            let chapter_style: String
            let editing_notes: String
            let guidance: String
        }

        let dto = try JSONDecoder().decode(StyleDTO.self, from: jsonData)

        return StyleProfile(
            name: videoInfo.title,
            sourceURL: "",
            videoTitle: videoInfo.title,
            videoDuration: videoInfo.duration,
            pacing: dto.pacing,
            chapterStyle: dto.chapter_style,
            editingNotes: dto.editing_notes,
            guidance: dto.guidance
        )
    }

    /// 複数動画から統合的なスタイルプロファイルを生成（2段階: Haikuで要約 → Sonnetで統合分析）
    func analyzeChannelStyle(
        videoInfos: [YTDLPService.YouTubeVideoInfo],
        channelName: String,
        progressCallback: @escaping (String) -> Void = { _ in }
    ) async throws -> StyleProfile {
        // Phase 1: 各動画をHaikuで要約（トークン節約）
        var summaries: [String] = []
        for (i, info) in videoInfos.enumerated() {
            // レートリミット回避: 2番目以降は3秒待機（ローカルLLM時はスキップ）
            if i > 0 && !useLocalLLM {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            progressCallback("Haiku要約中: \(i+1)/\(videoInfos.count)本...")

            var chaptersText = ""
            if !info.chapters.isEmpty {
                chaptersText = "\nチャプター: " + info.chapters.map { $0.title }.joined(separator: " → ")
            }

            // 字幕が長い場合は先頭+末尾で渡す
            let subText: String
            if info.subtitleText.count > 8000 {
                subText = String(info.subtitleText.prefix(4000)) + "\n...\n" + String(info.subtitleText.suffix(4000))
            } else {
                subText = info.subtitleText
            }

            let summaryPrompt = """
            以下のYouTube動画の「編集スタイル」を200字以内で要約してください。
            内容の要約ではなく、テンポ・構成・話し方の特徴に注目してください。

            タイトル: \(info.title)
            尺: \(formatSeconds(info.duration))\(chaptersText)

            字幕:
            \(subText)
            """

            let summary = try await sendMessage(summaryPrompt, model: haikuModel, maxTokens: 512)
            summaries.append("【\(info.title)】(\(formatSeconds(info.duration)))\n\(summary)")
        }

        // Phase 2: 要約をSonnetで統合分析
        progressCallback("Sonnet統合分析中...")

        let totalDuration = videoInfos.reduce(0.0) { $0 + $1.duration }
        let avgDuration = totalDuration / Double(max(videoInfos.count, 1))
        let allSummaries = summaries.joined(separator: "\n\n")

        let prompt = """
        あなたはYouTube動画の編集スタイルアナリストです。
        以下は同じチャンネルの\(videoInfos.count)本の動画のスタイル要約です。
        チャンネル全体の編集スタイルを統合分析してください。

        【チャンネル情報】:
        - 分析対象: \(videoInfos.count)本
        - 平均動画尺: \(formatSeconds(avgDuration))

        \(allSummaries)

        【分析項目と出力JSON】:
        {
          "pacing": "テンポの特徴（テンポ速め/標準/ゆったり + 具体的な説明）",
          "chapter_style": "チャプター構成の特徴（共通パターン）",
          "editing_notes": "カット頻度、間の取り方、トーク密度の特徴",
          "guidance": "このチャンネルのスタイルを再現するためのAI編集アシスタント向け指示文（300-500字）"
        }

        guidanceは最重要項目です。別の動画を編集するAIに「このチャンネルっぽく編集して」と
        指示するときに使うガイダンスです。\(videoInfos.count)本の動画に共通する編集パターンを
        抽出し、具体的かつ再現可能な指示にしてください。

        JSON以外のテキストは出力しないでください。
        """

        let response = try await sendMessage(prompt, model: effectiveSonnetModel, maxTokens: 4096)
        let jsonString = extractJSON(from: response)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        struct StyleDTO: Codable {
            let pacing: String
            let chapter_style: String
            let editing_notes: String
            let guidance: String
        }

        let dto = try JSONDecoder().decode(StyleDTO.self, from: jsonData)
        let videoTitles = videoInfos.map { $0.title }.prefix(3).joined(separator: ", ")

        return StyleProfile(
            name: channelName,
            sourceURL: "",
            videoTitle: "\(videoInfos.count)本分析: \(videoTitles)...",
            videoDuration: avgDuration,
            pacing: dto.pacing,
            chapterStyle: dto.chapter_style,
            editingNotes: dto.editing_notes,
            guidance: dto.guidance
        )
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    // MARK: - Story Analysis (YouTube Auto-Editor)

    struct StoryAnalysisDTO: Codable {
        let clip_order: [Int]
        let chapters: [ChapterDTO]
        let keep_sections: [KeepSectionDTO]
        let remove_sections: [RemoveSectionDTO]?
        let summary: String?
        let bgm_suggestions: [BGMSuggestionDTO]?
        let hook_suggestion: HookSuggestionDTO?
        let broll_suggestions: [BRollSuggestionDTO]?

        struct ChapterDTO: Codable {
            let title: String
            let description: String
        }

        struct KeepSectionDTO: Codable {
            let clip_index: Int
            let start_time: Double
            let end_time: Double
            let reason: String
            let confidence: Double?
        }

        struct RemoveSectionDTO: Codable {
            let clip_index: Int
            let start_time: Double
            let end_time: Double
            let reason: String
            let explanation: String
            let confidence: Double?
        }

        struct BGMSuggestionDTO: Codable {
            let clip_index: Int
            let start_time: Double
            let end_time: Double
            let mood: String
            let description: String
        }

        struct HookSuggestionDTO: Codable {
            let clip_index: Int
            let start_time: Double
            let end_time: Double
            let reason: String
            let hook_duration: Double?
        }

        struct BRollSuggestionDTO: Codable {
            let clip_index: Int
            let start_time: Double
            let end_time: Double
            let description: String
            let importance: Int?
        }
    }

    func analyzeStory(clips: [ProjectClip], targetDurationSeconds: TimeInterval?, styleGuidance: String? = nil, genreGuidance: String? = nil) async throws -> StoryAnalysis {
        // Step 1: 各クリップの内容構造化（並列処理）
        let maxConcurrency = useLocalLLM ? 3 : 3  // Claude API: 3並列、ローカルLLM: 3並列

        // 各クリップのプロンプトを事前生成
        struct ClipTask {
            let index: Int
            let prompt: String?   // nil = Bロール or スキップ
            let brollJSON: String? // Bロールの場合のJSON
        }

        var tasks: [ClipTask] = []
        for (i, clip) in clips.enumerated() {
            if clip.isBRoll {
                let brollJSON = """
                {"clip_index": \(i), "is_broll": true, "sections": [
                  {"start_time": 0.0, "end_time": \(clip.duration), "type": "broll", "summary": "Bロール素材（無音・環境音のみ）", "importance": 3, "key_topics": ["Bロール", "インサート"]}
                ]}
                """
                tasks.append(ClipTask(index: i, prompt: nil, brollJSON: brollJSON))
                print("[StoryAnalysis] クリップ\(i) (\(clip.fileName)) → Bロール判定（文字起こし空）")
                continue
            }

            guard let transcription = clip.bestTranscription else {
                tasks.append(ClipTask(index: i, prompt: nil, brollJSON: nil))
                continue
            }

            let text = transcription.segments.map { segment in
                "[\(TranscriptionSegment.formatTime(segment.startTime))-\(TranscriptionSegment.formatTime(segment.endTime))] \(segment.text)"
            }.joined(separator: "\n")

            let clipText = text.count > 15000
                ? String(text.prefix(7500)) + "\n...(中略)...\n" + String(text.suffix(7500))
                : text

            let prompt = """
            以下は動画クリップの文字起こしです。内容を構造化してください。

            【タスク】:
            テキストを意味のまとまり（セクション）に分割し、各セクションを分類してください。

            【セクション分類】:
            - greeting: 挨拶・自己紹介
            - intro: 本題の導入・テーマ説明
            - main: 本題・核心的な内容
            - detail: 詳細な説明・具体例
            - tangent: 脱線・余談
            - filler: 無意味な間・言い淀み区間
            - recap: まとめ・振り返り
            - outro: 締めの挨拶・次回予告

            【出力JSON】:
            {"clip_index": \(i), "sections": [
              {"start_time": 0.0, "end_time": 30.5, "type": "greeting", "summary": "挨拶と自己紹介", "importance": 3, "key_topics": ["挨拶"]},
              {"start_time": 30.5, "end_time": 120.0, "type": "main", "summary": "メインの説明", "importance": 5, "key_topics": ["トピックA", "トピックB"]}
            ]}

            - importance は 1(不要) 〜 5(必須) の5段階
            - key_topics はそのセクションの主要キーワード（重複検出に使用）
            - JSON以外のテキストは出力しないでください

            クリップ\(i) (\(clip.fileName), \(String(format: "%.0f", clip.duration))秒):
            \(clipText)
            """
            tasks.append(ClipTask(index: i, prompt: prompt, brollJSON: nil))
        }

        // 並列実行でStep 1を処理
        let apiTasks = tasks.filter { $0.prompt != nil }
        print("[StoryAnalysis] Step1: \(apiTasks.count)クリップをAPI解析（最大\(maxConcurrency)並列）")

        var clipStructures: [(index: Int, json: String)] = []

        // Bロール/スキップ分を先に追加
        for task in tasks {
            if let brollJSON = task.brollJSON {
                clipStructures.append((task.index, brollJSON))
            }
        }

        // API呼び出しを並列実行（セマフォ的制御）
        // クロージャ内で self を直接キャプチャしないようメソッド参照をローカル変数に退避
        let sendMsg = { [self] (prompt: String) async throws -> String in
            try await self.sendMessage(prompt, model: self.haikuModel, maxTokens: 4096)
        }
        let extractJSONFn = { [self] (text: String) -> String in
            self.extractJSON(from: text)
        }
        let isLocal = self.useLocalLLM

        let results = await withTaskGroup(of: (index: Int, json: String?).self) { group in
            var pending = apiTasks.makeIterator()
            var collected: [(index: Int, json: String?)] = []

            // 最初のmaxConcurrency個を投入
            for _ in 0..<min(maxConcurrency, apiTasks.count) {
                if let task = pending.next() {
                    let prompt = task.prompt!
                    let idx = task.index
                    group.addTask {
                        do {
                            let response = try await sendMsg(prompt)
                            let jsonStr = extractJSONFn(response)
                            return (index: idx, json: jsonStr)
                        } catch {
                            print("[StoryAnalysis] クリップ\(idx) Step1失敗: \(error.localizedDescription)")
                            return (index: idx, json: nil)
                        }
                    }
                }
            }

            // 1つ完了するたびに次を投入
            for await result in group {
                collected.append(result)
                if let task = pending.next() {
                    let prompt = task.prompt!
                    let idx = task.index
                    group.addTask {
                        if !isLocal {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        do {
                            let response = try await sendMsg(prompt)
                            let jsonStr = extractJSONFn(response)
                            return (index: idx, json: jsonStr)
                        } catch {
                            return (index: idx, json: nil)
                        }
                    }
                }
            }
            return collected
        }

        // 結果をindex順にマージ
        for result in results {
            if let json = result.json {
                clipStructures.append((result.index, json))
            }
        }
        clipStructures.sort { $0.index < $1.index }
        let sortedStructures = clipStructures.map(\.json)

        // Step 2: 統合編集判断（Sonnetで判断力重視）
        let structuresSummary = sortedStructures.joined(separator: "\n\n")

        let targetInfo: String
        if let target = targetDurationSeconds {
            let mins = Int(target) / 60
            targetInfo = "\(mins)分（この尺に収まるよう積極的にカット）"
        } else {
            targetInfo = "指定なし（冗長な部分のみカット、核心的な内容は全て残す）"
        }

        let styleSection: String
        if let guidance = styleGuidance {
            styleSection = """

            【編集スタイルガイド】:
            \(guidance)

            """
        } else {
            styleSection = ""
        }

        let genreSection: String
        if let genre = genreGuidance {
            genreSection = """

            【ジャンル別編集ルール（最優先で適用）】:
            \(genre)

            """
        } else {
            genreSection = ""
        }

        let step2Prompt = """
        あなたはプロのYouTube動画編集者です。
        Step1で構造化された各クリップの内容をもとに、1本の完成動画の編集計画を立ててください。

        【目標動画長】: \(targetInfo)
        \(styleSection)\(genreSection)
        【Step1の構造化データ】:
        \(structuresSummary)

        【編集判断の指針】:
        1. **残す基準**: importance 4-5 のセクションは原則残す。importance 3 は文脈に応じて判断
        2. **カット基準**:
           - importance 1-2 は原則カット
           - 複数クリップで同じ key_topics → 良い方（importance高い方）を残し、他はカット
           - type="tangent" は内容が面白ければ残す、そうでなければカット
           - type="filler" は必ずカット
        3. **順序最適化**: ストーリーの流れが自然になるよう並べ替え（時系列 or テーマ順）
        4. **チャプター**: 視聴者にとって分かりやすい区切りを3-8個
        5. **Bロール活用**: is_broll=true のクリップは映像のみの素材です。broll_suggestions にこれらのクリップを積極的に活用し、トークの合間や場面転換に差し込む位置を提案してください。keep_sections には含めず broll_suggestions にのみ記載すること

        【各判断にconfidence（0.0-1.0）を付けること】:
        - 1.0: 確実にこの判断が正しい（明らかな重複、明らかに重要）
        - 0.7-0.9: かなり自信がある
        - 0.4-0.6: 判断に迷う（ユーザーのレビュー推奨）
        - 0.1-0.3: 自信が低い（ユーザーが確認すべき）

        【出力JSON】:
        {
          "clip_order": [0, 2, 1],
          "chapters": [{"title": "イントロ", "description": "挨拶と本日のテーマ紹介"}],
          "keep_sections": [
            {"clip_index": 0, "start_time": 0.0, "end_time": 30.5, "reason": "挨拶部分、動画の導入として必要", "confidence": 0.9}
          ],
          "remove_sections": [
            {"clip_index": 0, "start_time": 30.5, "end_time": 45.0, "reason": "duplicate", "explanation": "クリップ2の0:15-0:30と同内容、クリップ2の方が説明が明瞭", "confidence": 0.8}
          ],
          "bgm_suggestions": [
            {"clip_index": 0, "start_time": 0.0, "end_time": 30.0, "mood": "upbeat", "description": "冒頭の挨拶区間、明るいBGM"}
          ],
          "hook_suggestion": {"clip_index": 1, "start_time": 45.0, "end_time": 55.0, "reason": "最も印象的な結果発表シーン、視聴者の興味を引く", "hook_duration": 8.0},
          "broll_suggestions": [
            {"clip_index": 0, "start_time": 60.0, "end_time": 65.0, "description": "商品のアップショットを差し込む", "importance": 4}
          ],
          "summary": "動画全体の概要"
        }

        【重要】:
        - keep_sections と remove_sections で各クリップの全時間をカバーすること（ギャップを作らない）
        - start_time / end_time はStep1のデータに基づく正確な値を使うこと
        - reason は視聴者目線で「なぜ残す/切るのか」を具体的に書くこと
        - JSON以外のテキストは出力しないでください
        - 必ず半角ASCII文字のみでJSON構文を記述してください
        """

        // Step 2はJSON品質が重要なので、失敗時は1回リトライ
        for attempt in 1...2 {
            let response = try await sendMessage(step2Prompt, model: effectiveSonnetModel, maxTokens: 16384)
            let jsonString = extractJSON(from: response)

            // JSONとして有効か事前チェック
            guard jsonString.contains("{"), jsonString.contains("keep_sections") else {
                if attempt < 2 {
                    print("[StoryAnalysis] Step2: JSON未検出、リトライ (\(attempt)/2)")
                    continue
                }
                throw APIError.requestFailed("ストーリー分析のレスポンスがJSON形式ではありません。モデルをSonnetに変更するか、ローカルLLMの場合はより大きなモデルを使用してください。")
            }

            do {
                return try parseStoryAnalysis(jsonString: jsonString)
            } catch {
                if attempt < 2 {
                    print("[StoryAnalysis] Step2: JSONパース失敗、リトライ (\(attempt)/2): \(error.localizedDescription)")
                    continue
                }
                throw error
            }
        }
        throw APIError.requestFailed("ストーリー分析に失敗しました")
    }

    private func parseStoryAnalysis(jsonString: String) throws -> StoryAnalysis {
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        let dto: StoryAnalysisDTO
        do {
            dto = try JSONDecoder().decode(StoryAnalysisDTO.self, from: jsonData)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, _):
                detail = "必須キー '\(key.stringValue)' が見つかりません"
            case .typeMismatch(let type, let context):
                detail = "型不一致: \(context.codingPath.map(\.stringValue).joined(separator: ".")) に \(type) が必要"
            case .valueNotFound(let type, let context):
                detail = "値なし: \(context.codingPath.map(\.stringValue).joined(separator: ".")) に \(type) が必要"
            case .dataCorrupted(let context):
                detail = "データ破損: \(context.debugDescription)"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            let preview = String(jsonString.prefix(300))
            print("[ClaudeAPI] JSONパース失敗: \(detail)\nJSON先頭300文字: \(preview)")
            throw APIError.requestFailed("JSONパース失敗: \(detail)\nAI応答: \(String(preview.prefix(150)))...")
        } catch {
            let preview = String(jsonString.prefix(200))
            throw APIError.requestFailed("JSONパース失敗: \(error.localizedDescription)\nAI応答: \(preview)...")
        }

        let chapters = dto.chapters.map { StoryChapter(title: $0.title, description: $0.description) }

        let keptSections = dto.keep_sections.enumerated().map { (i, section) in
            KeptSection(
                clipIndex: section.clip_index,
                startTime: section.start_time,
                endTime: section.end_time,
                orderIndex: i,
                reason: section.reason,
                confidence: section.confidence ?? 1.0
            )
        }

        let removedSections = (dto.remove_sections ?? []).map { section in
            let reason: RemovedSection.RemovalReason
            switch section.reason.lowercased() {
            case "duplicate": reason = .duplicate
            case "unnecessary": reason = .unnecessary
            case "toolong", "too_long": reason = .tooLong
            case "lowquality", "low_quality": reason = .lowQuality
            case "offtopic", "off_topic": reason = .offTopic
            default: reason = .unnecessary
            }
            return RemovedSection(
                clipIndex: section.clip_index,
                startTime: section.start_time,
                endTime: section.end_time,
                reason: reason,
                explanation: section.explanation,
                confidence: section.confidence ?? 1.0
            )
        }

        let bgmSuggestions = (dto.bgm_suggestions ?? []).map { s in
            BGMSuggestion(clipIndex: s.clip_index, startTime: s.start_time, endTime: s.end_time, mood: s.mood, description: s.description)
        }

        let hookSuggestion: HookSuggestion? = dto.hook_suggestion.map { h in
            HookSuggestion(clipIndex: h.clip_index, startTime: h.start_time, endTime: h.end_time, reason: h.reason, hookDuration: h.hook_duration ?? 10.0)
        }

        let brollSuggestions = (dto.broll_suggestions ?? []).map { s in
            BRollSuggestion(clipIndex: s.clip_index, startTime: s.start_time, endTime: s.end_time, description: s.description, importance: s.importance ?? 3)
        }

        return StoryAnalysis(
            clipOrder: dto.clip_order,
            chapters: chapters,
            keptSections: keptSections,
            removedSections: removedSections,
            summary: dto.summary ?? "（要約なし）",
            bgmSuggestions: bgmSuggestions,
            hookSuggestion: hookSuggestion,
            brollSuggestions: brollSuggestions
        )
    }

    // MARK: - Edit Refinement (AI Chat)

    struct RefinementResult {
        let updatedAnalysis: StoryAnalysis
        let explanation: String
    }

    func sendMessageForRefinement(
        currentAnalysis: StoryAnalysis,
        clips: [ProjectClip],
        chatHistory: [(role: String, content: String)],
        userInstruction: String
    ) async throws -> RefinementResult {
        let analysisJSON = currentAnalysis.toJSON() ?? "{}"

        let clipInfo = clips.enumerated().map { (i, clip) in
            "- クリップ\(i): \(clip.fileName), \(String(format: "%.0f", clip.duration))秒"
        }.joined(separator: "\n")

        let historyText = chatHistory.suffix(6).map { msg in
            "\(msg.role == "user" ? "ユーザー" : "アシスタント"): \(msg.content)"
        }.joined(separator: "\n")

        let prompt = """
        あなたはYouTube動画の編集アシスタントです。
        ユーザーの指示に基づいて、現在の編集計画を修正してください。

        【現在の編集計画（JSON）】:
        \(analysisJSON)

        【クリップ情報】:
        \(clipInfo)

        【最近の会話】:
        \(historyText)

        【ユーザーの新しい指示】:
        \(userInstruction)

        【出力フォーマット】:
        まず修正後の完全なJSONを```json```ブロックで出力し、
        その後に「説明:」で始まる変更内容の説明を日本語で出力してください。

        ```json
        {完全な編集計画JSON}
        ```
        説明: {変更内容の説明}
        """

        let response = try await sendMessage(prompt, model: effectiveSonnetModel, maxTokens: 8192)

        // JSONとexplanationを分離
        let jsonString = extractJSON(from: response)
        let updatedAnalysis = try parseStoryAnalysisFromRefinement(jsonString: jsonString)

        var explanation = "編集計画を更新しました。"
        if let range = response.range(of: "説明:") ?? response.range(of: "説明：") {
            explanation = String(response[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return RefinementResult(updatedAnalysis: updatedAnalysis, explanation: explanation)
    }

    private func parseStoryAnalysisFromRefinement(jsonString: String) throws -> StoryAnalysis {
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        // まずCodableで直接デコードを試みる
        if let analysis = try? JSONDecoder().decode(StoryAnalysis.self, from: jsonData) {
            return analysis
        }

        // フォールバック: DTO経由でパース
        return try parseStoryAnalysis(jsonString: jsonString)
    }

    // MARK: - API Communication

    /// レートリミット時の最大リトライ回数
    private let maxRetries = 3

    private func sendMessage(_ content: String, model: String? = nil, maxTokens: Int = 4096) async throws -> String {
        // ローカルLLMモード時はOllama互換エンドポイントに送信
        if useLocalLLM {
            return try await sendMessageLocalLLM(content, maxTokens: maxTokens)
        }

        let useModel = model ?? haikuModel
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                // リトライ前のログ
                print("[ClaudeAPI] リトライ \(attempt)/\(maxRetries)...")
            }

            do {
                return try await sendMessageOnce(content, model: useModel, maxTokens: maxTokens)
            } catch let error as APIError {
                // レートリミット(429)の場合のみリトライ
                if case .rateLimited(let retryAfter) = error, attempt < maxRetries {
                    let waitSeconds = retryAfter ?? Double(pow(2.0, Double(attempt)) * 10) // デフォルト: 10s, 20s, 40s
                    print("[ClaudeAPI] レートリミット。\(String(format: "%.0f", waitSeconds))秒待機...")
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? APIError.requestFailed("リトライ上限に達しました")
    }

    private func sendMessageOnce(_ content: String, model: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // レートリミット(429): retry-afterヘッダーがあれば使う
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                .flatMap { Double($0) }
            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.requestFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        struct APIResponse: Codable {
            struct Content: Codable {
                let text: String
            }
            let content: [Content]
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let text = apiResponse.content.first?.text else {
            throw APIError.invalidResponse
        }

        return text
    }

    // MARK: - ローカルLLM送信（Ollama OpenAI互換API）

    /// ローカルLLM接続確認済みフラグ（全インスタンス共有、NSLockで保護）
    private static var localLLMHealthChecked = false
    private static var healthCheckTask: Task<Void, Error>?
    private static let healthCheckLock = NSLock()

    private func ensureLocalLLMAvailable() async throws {
        // ロック内で状態確認とTask設定を原子的に行う
        let taskToAwait: Task<Void, Error> = Self.healthCheckLock.withLock {
            if Self.localLLMHealthChecked {
                return Task { } // 何もしないTask
            }
            if let existing = Self.healthCheckTask {
                return existing
            }
            let endpoint = self.localLLMEndpoint
            let task = Task {
                try await ClaudeAPIService.performHealthCheck(endpoint: endpoint)
            }
            Self.healthCheckTask = task
            return task
        }

        do {
            try await taskToAwait.value
        } catch {
            Self.healthCheckLock.withLock {
                Self.healthCheckTask = nil
            }
            throw error
        }
    }

    private static func performHealthCheck(endpoint: String) async throws {
        let endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw APIError.localLLMUnavailable("無効なエンドポイント: \(endpoint)")
        }

        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    localLLMHealthChecked = true
                    print("[LocalLLM] ヘルスチェック成功 (試行\(attempt)/\(maxAttempts))")
                    return
                }
            } catch {
                // 接続失敗 — リトライ
            }
            if attempt < maxAttempts {
                let wait = Double(attempt) * 2.0 // 2s, 4s, 6s, 8s
                print("[LocalLLM] 接続待機中... \(Int(wait))秒後にリトライ (\(attempt)/\(maxAttempts))")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw APIError.localLLMUnavailable("Ollamaサーバー (\(endpoint)) に接続できません。起動しているか確認してください。")
    }

    private func sendMessageLocalLLM(_ content: String, maxTokens: Int = 4096) async throws -> String {
        // 初回のみヘルスチェック
        try await ensureLocalLLMAvailable()

        let endpoint = localLLMEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/v1/chat/completions") else {
            throw APIError.localLLMUnavailable("無効なエンドポイント: \(localLLMEndpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 600 // ローカルLLMは遅い場合があるので10分

        let body: [String: Any] = [
            "model": localLLMModel,
            "messages": [
                ["role": "user", "content": content]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.1,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[LocalLLM] \(localLLMModel) @ \(endpoint) に送信中...")

        let maxRetries = 3
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw APIError.requestFailed("LocalLLM HTTP \(httpResponse.statusCode): \(errorBody)")
                }

                // OpenAI互換レスポンス: {"choices": [{"message": {"content": "..."}}]}
                struct OAIResponse: Codable {
                    struct Choice: Codable {
                        struct Message: Codable {
                            let content: String
                        }
                        let message: Message
                    }
                    let choices: [Choice]
                }

                let oaiResponse = try JSONDecoder().decode(OAIResponse.self, from: data)
                guard let text = oaiResponse.choices.first?.message.content else {
                    throw APIError.invalidResponse
                }

                print("[LocalLLM] レスポンス受信 (\(text.count)文字)")
                return text
            } catch let error as APIError {
                throw error // APIError（パースエラー等）はリトライしない
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let wait = Double(attempt) * 2.0
                    print("[LocalLLM] 接続エラー、\(Int(wait))秒後にリトライ (\(attempt)/\(maxRetries)): \(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
        throw APIError.localLLMUnavailable("接続失敗 (\(endpoint)): \(lastError?.localizedDescription ?? "不明なエラー")")
    }

    /// ローカルLLMの接続テスト
    func testLocalLLMConnection() async throws -> String {
        let endpoint = localLLMEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw APIError.localLLMUnavailable("無効なエンドポイント")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.localLLMUnavailable("サーバーが応答しません")
        }

        // モデル一覧を取得
        struct ModelsResponse: Codable {
            struct Model: Codable {
                let id: String
            }
            let data: [Model]?
            // Ollama /api/tags 形式
            let models: [OllamaModel]?
        }
        struct OllamaModel: Codable {
            let name: String
        }

        if let modelsResponse = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
            let modelNames: [String]
            if let models = modelsResponse.data {
                modelNames = models.map(\.id)
            } else if let models = modelsResponse.models {
                modelNames = models.map(\.name)
            } else {
                modelNames = []
            }
            return "接続成功 — 利用可能モデル: \(modelNames.joined(separator: ", "))"
        }

        return "接続成功（モデル一覧取得不可）"
    }

    // MARK: - Timestamp Correction

    /// AIが返したセグメントのタイムスタンプを、元のセグメントと突き合わせて補正する。
    /// AIのstart_timeで最も近い元セグメントを探し、元のタイムスタンプ範囲内で正確に割り当てる。
    private func correctTimestamps(reformatted: [ReformattedSegment], originals: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !reformatted.isEmpty, !originals.isEmpty else {
            return reformatted.map { TranscriptionSegment(startTime: $0.start_time, endTime: $0.end_time, text: $0.text) }
        }

        // 元セグメントをソート
        let sortedOriginals = originals.sorted { $0.startTime < $1.startTime }
        let timelineStart = sortedOriginals.first!.startTime
        let timelineEnd = sortedOriginals.last!.endTime

        var result: [TranscriptionSegment] = []

        for seg in reformatted {
            // AIが返したstart_timeに最も近い元セグメントを探す
            let bestMatch = sortedOriginals.min(by: {
                abs($0.startTime - seg.start_time) < abs($1.startTime - seg.start_time)
            })!

            // 補正したstart_time: AIが返した値が元セグメントの範囲から大きくずれていたら元の値を使う
            var correctedStart = seg.start_time
            var correctedEnd = seg.end_time

            // AIのstart_timeと最も近い元セグメントのstart_timeの差が2秒以上なら補正
            if abs(correctedStart - bestMatch.startTime) > 2.0 {
                correctedStart = bestMatch.startTime
            }

            // end_timeも同様にチェック
            let bestEndMatch = sortedOriginals.min(by: {
                abs($0.endTime - seg.end_time) < abs($1.endTime - seg.end_time)
            })!
            if abs(correctedEnd - bestEndMatch.endTime) > 2.0 {
                correctedEnd = bestEndMatch.endTime
            }

            // タイムラインの範囲内にクランプ
            correctedStart = max(timelineStart, min(correctedStart, timelineEnd))
            correctedEnd = max(correctedStart + 0.1, min(correctedEnd, timelineEnd))

            // 前のセグメントとの重なりを防ぐ
            if let prev = result.last, correctedStart < prev.endTime {
                correctedStart = prev.endTime
            }
            if correctedEnd <= correctedStart {
                correctedEnd = correctedStart + 0.5
            }

            result.append(TranscriptionSegment(
                startTime: correctedStart,
                endTime: correctedEnd,
                text: seg.text
            ))
        }

        return result
    }

    // MARK: - Helpers

    private func formatTranscriptionForAPI(_ transcription: TranscriptionResult) -> String {
        transcription.segments.map { segment in
            "[\(TranscriptionSegment.formatTime(segment.startTime))] \(segment.text)"
        }.joined(separator: "\n")
    }

    private func extractJSON(from text: String) -> String {
        // まず全角記号を正規化してから検索
        let normalized = sanitizeJSON(text)

        // ```json ... ``` ブロックを検出
        if let range = normalized.range(of: "```json"),
           let endRange = normalized.range(of: "```", range: range.upperBound..<normalized.endIndex) {
            return repairJSON(String(normalized[range.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // ``` ... ``` ブロック（json指定なし）
        if let range = normalized.range(of: "```\n"),
           let endRange = normalized.range(of: "```", range: range.upperBound..<normalized.endIndex) {
            let inner = String(normalized[range.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.hasPrefix("{") || inner.hasPrefix("[") {
                return repairJSON(inner)
            }
        }
        // { で始まり } で終わる部分を検出
        if let startIdx = normalized.firstIndex(of: "{"),
           let endIdx = normalized.lastIndex(of: "}") {
            return repairJSON(String(normalized[startIdx...endIdx]))
        }
        // [ で始まり ] で終わる部分を検出
        if let startIdx = normalized.firstIndex(of: "["),
           let endIdx = normalized.lastIndex(of: "]") {
            return repairJSON(String(normalized[startIdx...endIdx]))
        }
        return repairJSON(normalized)
    }

    /// AIが返すJSONに含まれる全角記号をASCIIに正規化
    private func sanitizeJSON(_ text: String) -> String {
        var s = text
        // 全角→半角の置換（JSON構文文字）
        let replacements: [(String, String)] = [
            ("：", ":"), ("，", ","), ("｛", "{"), ("｝", "}"),
            ("［", "["), ("］", "]"), ("\u{201C}", "\""), ("\u{201D}", "\""),  // ""
            ("\u{2018}", "'"), ("\u{2019}", "'"),  // ''
            ("＂", "\""), ("\u{FF02}", "\""),  // 全角ダブルクォート
            ("\u{FF1A}", ":"),   // 全角コロン（別コードポイント）
            ("\u{FF0C}", ","),   // 全角カンマ（別コードポイント）
        ]
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// AIが返すJSONの軽微な構文エラーを修復
    private func repairJSON(_ text: String) -> String {
        var s = text

        // 末尾の余分なカンマを除去 (trailing comma before } or ])
        s = s.replacingOccurrences(of: #",\s*}"#, with: "}", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*\]"#, with: "]", options: .regularExpression)

        // "\n" の後にキー（"で始まる）が続くがカンマがない場合、カンマを補完
        // ただし ": " のパターンは除外（値の区切りであってカンマ抜けではない）
        s = s.replacingOccurrences(
            of: #"(?<=["\d\]\}])\s*\n\s*(?=")"#,
            with: ",\n",
            options: .regularExpression
        )

        // true/false/null の後にキーが続くがカンマがない場合
        s = s.replacingOccurrences(
            of: #"(true|false|null)\s*\n\s*""#,
            with: "$1,\n\"",
            options: .regularExpression
        )

        // 再度 trailing comma を除去（repair で入れすぎた場合の保険）
        s = s.replacingOccurrences(of: #",\s*}"#, with: "}", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*\]"#, with: "]", options: .regularExpression)

        // 切り詰められたJSON修復: 閉じていない括弧を閉じる
        var openBraces = 0
        var openBrackets = 0
        var inString = false
        var prevChar: Character = " "
        for ch in s {
            if ch == "\"" && prevChar != "\\" {
                inString.toggle()
            }
            if !inString {
                switch ch {
                case "{": openBraces += 1
                case "}": openBraces -= 1
                case "[": openBrackets += 1
                case "]": openBrackets -= 1
                default: break
                }
            }
            prevChar = ch
        }
        // 文字列が閉じていない場合
        if inString {
            s += "\""
        }
        // 末尾の不完全なキー/値を除去してから括弧を閉じる
        s = s.replacingOccurrences(of: #",\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",?\s*"[^"]*"\s*:\s*$"#, with: "", options: .regularExpression)
        for _ in 0..<max(0, openBrackets) {
            s += "]"
        }
        for _ in 0..<max(0, openBraces) {
            s += "}"
        }

        return s
    }
}
