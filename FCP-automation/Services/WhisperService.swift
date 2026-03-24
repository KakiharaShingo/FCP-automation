import Foundation
import AVFoundation

class WhisperService {
    enum WhisperError: LocalizedError {
        case modelNotFound(String)
        case audioExtractionFailed(String)
        case transcriptionFailed(String)
        case fileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Whisperモデルが見つかりません: \(path)"
            case .audioExtractionFailed(let reason):
                return "音声の抽出に失敗: \(reason)"
            case .transcriptionFailed(let reason):
                return "文字起こしに失敗: \(reason)"
            case .fileNotFound(let path):
                return "ファイルが見つかりません: \(path)"
            }
        }
    }

    /// 速度プリセット: 0=高速, 1=バランス, 2=高精度
    enum SpeedPreset: Int {
        case fast = 0
        case balanced = 1
        case quality = 2

        /// best-of候補数（デコード精度 vs 速度のトレードオフ）
        var bestOf: Int {
            switch self {
            case .fast: return 1
            case .balanced: return 3
            case .quality: return 5
            }
        }

        /// whisper.cppスレッド数
        var threadCount: Int {
            let cores = ProcessInfo.processInfo.activeProcessorCount
            switch self {
            case .fast: return max(4, cores - 2)      // ほぼ全コア使用
            case .balanced: return max(4, cores / 2)   // 半分
            case .quality: return max(4, cores / 2)    // 半分（-bo増加分で十分遅い）
            }
        }

        /// エントロピー閾値（低い=厳格でハルシネーション減、高い=許容的）
        var entropyThreshold: String {
            switch self {
            case .fast: return "2.40"
            case .balanced: return "2.20"
            case .quality: return "2.20"
            }
        }
    }

    private let modelPath: String
    private let speedPreset: SpeedPreset

    init(modelPath: String? = nil, speedPreset: Int = 1) {
        if let path = modelPath, !path.isEmpty {
            self.modelPath = path
        } else {
            // turboモデルがあれば優先使用（高速・同等精度）
            let modelsDir = APIConfig.defaultModelDirectory
            let turboPath = modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin").path
            let largePath = modelsDir.appendingPathComponent("ggml-large-v3.bin").path
            if FileManager.default.fileExists(atPath: turboPath) {
                self.modelPath = turboPath
            } else {
                self.modelPath = largePath
            }
        }
        self.speedPreset = SpeedPreset(rawValue: speedPreset) ?? .balanced
    }

    func transcribe(fileURL: URL, userDictionary: [String] = [], maxSegmentLength: Int = 40, progressCallback: @escaping (Double) -> Void) async throws -> TranscriptionResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw WhisperError.audioExtractionFailed("動画ファイルを選択してください（フォルダは指定できません）: \(fileURL.lastPathComponent)")
        }

        // 音声ファイルに変換（WAV 16kHz mono）
        let wavURL = try await extractAudio(from: fileURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // whisper-cpp CLIを使って文字起こし
        let result = try await runWhisperCLI(wavURL: wavURL, userDictionary: userDictionary, maxSegmentLength: maxSegmentLength, progressCallback: progressCallback)
        return result
    }

    // MARK: - Audio Extraction

    private func extractAudio(from inputURL: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        // ffmpegの方が確実なので、まずffmpegを試み、なければAVFoundationを使う
        if let ffmpegPath = findFFmpeg() {
            try await extractWithFFmpeg(ffmpegPath: ffmpegPath, inputURL: inputURL, outputURL: wavURL)
        } else {
            try await extractWithAVFoundation(inputURL: inputURL, outputURL: wavURL)
        }

        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw WhisperError.audioExtractionFailed("WAVファイルの生成に失敗しました")
        }

        return wavURL
    }

    private func findFFmpeg() -> String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func extractWithFFmpeg(ffmpegPath: String, inputURL: URL, outputURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", inputURL.path,
            "-ar", "16000",
            "-ac", "1",
            "-f", "wav",
            "-y",
            outputURL.path
        ]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw WhisperError.audioExtractionFailed("ffmpeg失敗: \(errMsg.suffix(200))")
        }
    }

    private func extractWithAVFoundation(inputURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        let composition = AVMutableComposition()

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionTrack = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw WhisperError.audioExtractionFailed("音声トラックが見つかりません")
        }

        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack, at: .zero
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw WhisperError.audioExtractionFailed("AVAssetExportSessionの作成に失敗")
        }

        // m4aで書き出し（whisper-cliはm4a非対応なのでffmpegが必要）
        let m4aURL = outputURL.deletingPathExtension().appendingPathExtension("m4a")
        exportSession.outputURL = m4aURL
        exportSession.outputFileType = .m4a
        await exportSession.export()

        guard exportSession.status == .completed else {
            let errMsg = exportSession.error?.localizedDescription ?? "unknown"
            throw WhisperError.audioExtractionFailed("AVFoundation書き出し失敗: \(errMsg)")
        }

        // m4aをwavに変換する必要がある（whisper-cliはwav/mp3/flac/oggのみ）
        // ffmpegがない場合はm4aのままでは使えない
        throw WhisperError.audioExtractionFailed(
            "ffmpegが見つかりません。AVFoundationはM4A出力のみ対応ですが、whisper-cppはWAV形式が必要です。ターミナルで brew install ffmpeg を実行してください。"
        )
    }

    // MARK: - Whisper CLI Execution

    private func runWhisperCLI(wavURL: URL, userDictionary: [String] = [], maxSegmentLength: Int = 40, progressCallback: @escaping (Double) -> Void) async throws -> TranscriptionResult {
        guard let whisperPath = findWhisperCLI() else {
            throw WhisperError.transcriptionFailed(
                "whisper-cppが見つかりません。ターミナルで arch -arm64 brew install whisper-cpp を実行してください。"
            )
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        print("[Whisper] 速度プリセット: \(speedPreset) (bo=\(speedPreset.bestOf), threads=\(speedPreset.threadCount))")

        var args = [
            "-m", modelPath,
            "-l", "ja",
            "-osrt",
            "-of", outputBase,
            "-t", "\(speedPreset.threadCount)",        // スレッド数（速度プリセットに応じて調整）
            "-ml", "\(maxSegmentLength)",               // セグメント最大文字数
            "-sow",                                     // 単語単位で分割
            "-bo", "\(speedPreset.bestOf)",             // best-of候補数（速度に最も影響）
            "-wt", "0.01",                              // ワード境界検出の閾値
            "-et", speedPreset.entropyThreshold,        // エントロピー閾値
            "-ac", "768",                               // audio context（環境音ハルシネーション抑制）
            "-mc", "0",                                 // テキストコンテキスト無効化（ループ防止）
            "-pp",                                      // 進捗表示を有効化
        ]

        // ユーザー辞書をinitial promptとして渡す（語彙ヒントで認識精度向上）
        if !userDictionary.isEmpty {
            let prompt = userDictionary.joined(separator: "、")
            args += ["--prompt", prompt]
        }

        args.append(wavURL.path)
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        // 進捗をstderrから別スレッドで読み取る
        let progressTask = Task.detached {
            let handle = errPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                if line.contains("%") {
                    if let percentStr = line.components(separatedBy: "%").first?
                        .components(separatedBy: " ").last,
                       let percent = Double(percentStr) {
                        await MainActor.run {
                            progressCallback(min(percent / 100.0, 1.0))
                        }
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        progressTask.cancel()

        guard process.terminationStatus == 0 else {
            let code = process.terminationStatus
            if code == 6 {
                throw WhisperError.transcriptionFailed(
                    "モデルファイルが読み込めません（code: 6）。設定画面でモデルパスを確認してください。現在: \(modelPath)"
                )
            }
            throw WhisperError.transcriptionFailed(
                "whisper-cppが異常終了（code: \(code)）"
            )
        }

        // SRTファイルをパース
        let srtURL = URL(fileURLWithPath: outputBase + ".srt")
        defer { try? FileManager.default.removeItem(at: srtURL) }

        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            throw WhisperError.transcriptionFailed("SRTファイルが生成されませんでした: \(srtURL.path)")
        }

        let srtContent = try String(contentsOf: srtURL, encoding: .utf8)
        let rawSegments = parseSRT(srtContent)
        let segments = WhisperService.filterHallucinations(rawSegments)

        await MainActor.run {
            progressCallback(1.0)
        }

        // 動画の長さを取得
        let asset = AVURLAsset(url: wavURL)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))

        print("[Whisper] フィルタ結果: \(rawSegments.count)セグメント → \(segments.count)セグメント")
        if rawSegments.count != segments.count {
            print("[Whisper] ハルシネーションフィルタ: \(rawSegments.count - segments.count)件除去")
        }
        // デバッグ: 生セグメントを全てログ出力（問題調査用）
        if segments.isEmpty && rawSegments.count > 0 {
            print("[Whisper] ⚠️ 全セグメントが除去されました。生データ:")
            for (i, seg) in rawSegments.prefix(20).enumerated() {
                print("[Whisper]   raw[\(i)]: \(String(format: "%.1f", seg.startTime))-\(String(format: "%.1f", seg.endTime))s \"\(seg.text.prefix(60))\"")
            }
            if rawSegments.count > 20 {
                print("[Whisper]   ... 他\(rawSegments.count - 20)件")
            }
        }

        return TranscriptionResult(segments: segments, language: "ja", duration: duration)
    }

    private func findWhisperCLI() -> String? {
        let paths = [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper-cpp",
            "/usr/local/bin/whisper"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - SRT Parser

    private func parseSRT(_ content: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        let blocks = content.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            let timeLine = lines[1]
            let text = lines[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)

            let timeParts = timeLine.components(separatedBy: " --> ")
            guard timeParts.count == 2 else { continue }

            let startTime = parseSRTTime(timeParts[0])
            let endTime = parseSRTTime(timeParts[1])

            if !text.isEmpty {
                segments.append(TranscriptionSegment(
                    startTime: startTime,
                    endTime: endTime,
                    text: text
                ))
            }
        }

        return segments
    }

    // MARK: - Hallucination Filter

    /// whisper出力からハルシネーション（幻聴）セグメントを除去
    /// staticにして外部（YouTubePipelineService等）からも呼べるようにする
    static func filterHallucinations(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !segments.isEmpty else { return segments }

        // 全セグメントのテキストを収集（クロスセグメント分析用）
        let allTexts = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // セグメント間で共通する短いフレーズを抽出（ハルシネーションは同じ単語を繰り返しがち）
        let crossSegmentPhrases = findCrossSegmentRepetition(allTexts)

        var filtered = segments.filter { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. 空テキスト除去
            if text.isEmpty { return false }

            // 2. 同じ単語/フレーズの異常な繰り返し検出
            //    例: "高尾駅は高尾駅で、高尾駅から高尾駅まで行くことができます。"
            if hasExcessiveRepetition(text) {
                print("[Whisper] 繰り返しハルシネーション除去: \(text.prefix(50))")
                return false
            }

            // 3. 典型的なハルシネーションフレーズ（whisperが環境音で生成しがちなパターン）
            let hallucinationPatterns = [
                "ご視聴ありがとうございました",
                "チャンネル登録",
                "お疲れ様でした",
                "おやすみなさい",
                "いってらっしゃい",
                "ただいま",
                "いらっしゃいませ",
                "ありがとうございました",
                "よろしくお願いします",
                "お願いいたします",
                "それではまた",
                "今回の動画はここまで",
                "See you",
                "Thank you",
                "Bye bye",
                "music",
                "Music",
                "♪",
                "Subtitles",
                "subtitles",
            ]
            let lowerText = text.lowercased()
            for pattern in hallucinationPatterns {
                // テキスト全体がほぼパターンだけの場合のみ除去（長い文の一部なら残す）
                if text.count <= pattern.count + 10 && lowerText.contains(pattern.lowercased()) {
                    print("[Whisper] 定型ハルシネーション除去: \(text)")
                    return false
                }
            }

            // 3b. Whisper環境音ハルシネーション特有パターン
            //     環境音（電車の走行音、風、機械音等）からWhisperが生成する典型的な幻聴
            //     特徴: 鉄道用語、Wikipedia風説明文、UI操作指示、不自然な汎用説明
            if isEnvironmentSoundHallucination(text) {
                print("[Whisper] 環境音ハルシネーション除去: \(text.prefix(50))")
                return false
            }

            // 4. 極端に短い孤立セグメント（1-2文字で前後と無関係）
            if text.count <= 2 {
                let isSingleChar = ["あ", "え", "お", "う", "ん", "は", "の", "へ", "と", "か"].contains(text)
                if isSingleChar {
                    print("[Whisper] 短断片除去: \(text)")
                    return false
                }
            }

            // 5. クロスセグメント重複: 短いテキスト（≤8文字）が他セグメントの部分文字列として頻出
            if text.count <= 8 && !crossSegmentPhrases.isEmpty {
                for phrase in crossSegmentPhrases {
                    if text.contains(phrase) || phrase.contains(text) {
                        print("[Whisper] クロスセグメント重複除去: \(text)")
                        return false
                    }
                }
            }

            return true
        }

        // 6. 全セグメントが同じキーフレーズの繰り返しなら全除去（環境音の典型パターン）
        if !filtered.isEmpty && isAllSegmentsRepetitive(filtered) {
            print("[Whisper] 全セグメント繰り返しハルシネーション: 全\(filtered.count)件除去")
            filtered = []
        }

        // 7. 同一テキストの大量繰り返し除去
        //    同じテキストが大量に（40%以上かつ5回以上）繰り返される場合のみ除去
        //    注意: 閾値を低くしすぎると実際の発話（口癖等）も消してしまう
        if filtered.count >= 10 {
            var textCounts: [String: Int] = [:]
            for seg in filtered {
                let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                textCounts[t, default: 0] += 1
            }
            // 40%以上かつ5回以上繰り返すテキストのみ除去（厳し目の閾値）
            let repeatThreshold = max(5, filtered.count * 4 / 10)
            let loopTexts = Set(textCounts.filter { $0.value >= repeatThreshold }.keys)
            if !loopTexts.isEmpty {
                let before = filtered.count
                filtered = filtered.filter { seg in
                    let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !loopTexts.contains(t)
                }
                print("[Whisper] ループ除去: \(loopTexts.map { "\($0.prefix(20))" }) — \(before) → \(filtered.count)セグメント")

                // ループで60%以上除去された場合のみ、残りの3回以上繰り返しも除去
                let removedByLoop = before - filtered.count
                if removedByLoop >= before * 6 / 10 && filtered.count >= 2 {
                    var textCounts2: [String: Int] = [:]
                    for seg in filtered {
                        let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        textCounts2[t, default: 0] += 1
                    }
                    let duplicateTexts = Set(textCounts2.filter { $0.value >= 3 }.keys)
                    if !duplicateTexts.isEmpty {
                        let before2 = filtered.count
                        filtered = filtered.filter { seg in
                            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !duplicateTexts.contains(t)
                        }
                        print("[Whisper] 残存重複除去: \(duplicateTexts.map { "\($0.prefix(20))" }) — \(before2) → \(filtered.count)セグメント")
                    }
                }
            }
        }

        return filtered
    }

    /// 複数セグメントに共通して出現する短いフレーズを検出
    private static func findCrossSegmentRepetition(_ texts: [String]) -> [String] {
        guard texts.count >= 2 else { return [] }
        // 各テキストから2-6文字のn-gramを抽出し、複数セグメントに出現するものを探す
        var gramSegmentCount: [String: Int] = [:]  // gram → 何セグメントに出現するか

        for text in texts {
            let chars = Array(text)
            var seenInThisSegment: Set<String> = []
            let maxGram = min(6, chars.count)
            guard maxGram >= 2 else { continue }
            for gramLen in 2...maxGram {
                for i in 0...(chars.count - gramLen) {
                    let gram = String(chars[i..<(i + gramLen)])
                    // 助詞のみのgramは無視
                    let particleOnly = gram.allSatisfy { "のをはがでにへとも、。".contains($0) }
                    if particleOnly { continue }
                    if !seenInThisSegment.contains(gram) {
                        seenInThisSegment.insert(gram)
                        gramSegmentCount[gram, default: 0] += 1
                    }
                }
            }
        }

        // 全セグメント（または大半）に出現するフレーズ = ハルシネーションの繰り返しキーワード
        let threshold = max(2, texts.count * 2 / 3)
        let repeated = gramSegmentCount.filter { $0.value >= threshold }
            .sorted { $0.key.count > $1.key.count }  // 長いgramを優先
            .map { $0.key }

        // 短いgramが長いgramの部分文字列なら除外（重複排除）
        var result: [String] = []
        for gram in repeated {
            if !result.contains(where: { $0.contains(gram) }) {
                result.append(gram)
            }
        }
        return result
    }

    /// 全セグメントが同じキーフレーズの繰り返しかどうか判定
    private static func isAllSegmentsRepetitive(_ segments: [TranscriptionSegment]) -> Bool {
        guard segments.count >= 2 else { return false }
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 最短テキストを基準に、全セグメントがそれを含んでいるかチェック
        guard let shortest = texts.min(by: { $0.count < $1.count }), shortest.count >= 2 else { return false }

        let allContain = texts.allSatisfy { $0.contains(shortest) }
        if allContain {
            return true
        }

        return false
    }

    /// テキスト内に同じフレーズが異常に繰り返されているか検出
    private static func hasExcessiveRepetition(_ text: String) -> Bool {
        let maxGram = min(10, text.count / 2)
        guard maxGram >= 2 else { return false }
        // 2-10文字のn-gramで繰り返しチェック
        for gramLen in 2...maxGram {
            var gramCounts: [String: Int] = [:]
            let chars = Array(text)
            for i in 0...(chars.count - gramLen) {
                let gram = String(chars[i..<(i + gramLen)])
                gramCounts[gram, default: 0] += 1
            }
            // 同じn-gramが3回以上出現 → 異常な繰り返し
            if let maxCount = gramCounts.values.max(), maxCount >= 3 {
                // ただし「の」「を」「は」等の助詞は除外
                let topGram = gramCounts.first { $0.value == maxCount }?.key ?? ""
                let particleOnly = topGram.allSatisfy { "のをはがでにへとも、。".contains($0) }
                if !particleOnly {
                    return true
                }
            }
        }
        return false
    }

    /// 環境音からWhisperが生成する典型的なハルシネーションパターンを検出
    /// 電車の走行音、風、機械音などからWhisperが「もっともらしい文」を幻聴するケース
    private static func isEnvironmentSoundHallucination(_ text: String) -> Bool {
        // --- パターンA: 鉄道・交通系ハルシネーション ---
        // Whisperは電車の走行音・モーター音から鉄道用語を幻聴しがち
        let railwayPatterns = [
            "形電車",          // "E233系電車" "8000形電車" など
            "交通局",          // "東京都交通局"
            "として開業",      // Wikipedia風の説明
            "系電車",          // "E233系電車"
        ]
        let railwayMatchCount = railwayPatterns.filter { text.contains($0) }.count
        if railwayMatchCount >= 1 {
            return true
        }

        // --- パターンB: Wikipedia風の説明文ハルシネーション ---
        // 「〜年〜月〜日に」+ 説明文 = 環境音から生成されたWikipedia的ハルシネーション
        let wikiPattern = try? NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日")
        if let wikiPattern = wikiPattern,
           wikiPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }

        // --- パターンC: UI操作指示風ハルシネーション ---
        // 機械音・キー操作音からWhisperが操作説明を幻聴
        let uiPatterns = [
            ("ボタンをクリック", "画面"),    // 両方含む
            ("スイッチを使用", ""),           // 単独でも
            ("スイッチを動かす", ""),
        ]
        for (p1, p2) in uiPatterns {
            if text.contains(p1) && (p2.isEmpty || text.contains(p2)) {
                return true
            }
        }

        // --- パターンD: 汎用説明文 + 方向指示 ---
        // 「〜方向を望む」はカメラ撮影ハルシネーションの典型
        if text.hasSuffix("方向を望む。") || text.hasSuffix("方向を望む") {
            return true
        }

        // --- パターンE: 複数の汎用パターンの組み合わせ ---
        // 単独では正当な文になりうるが、組み合わさるとハルシネーションの疑い
        let genericIndicators = [
            "することができます",
            "見ることができます",
            "動かすことができます",
            "行くことができます",
            "ここにあります",
            "中にあります",
            "ここまでです",
        ]
        let genericHitCount = genericIndicators.filter { text.contains($0) }.count
        // 2つ以上の汎用パターンにマッチ = ハルシネーション
        if genericHitCount >= 2 {
            return true
        }

        return false
    }

    private func parseSRTTime(_ timeStr: String) -> TimeInterval {
        // Format: HH:MM:SS,mmm
        let cleaned = timeStr.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let mins = Double(parts[1]),
              let secs = Double(parts[2]) else {
            return 0
        }
        return hours * 3600 + mins * 60 + secs
    }
}
