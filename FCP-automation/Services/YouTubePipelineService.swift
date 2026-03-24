import Foundation
import AVFoundation

class YouTubePipelineService {

    /// 並列実行の同時実行数
    private let whisperConcurrency: Int
    private let apiConcurrency = 3       // Claude API rate limit考慮
    private let analysisConcurrency = 4  // 音声解析は軽め

    /// Whisper速度プリセット
    private let whisperSpeedPreset: Int

    init(whisperSpeedPreset: Int = 1) {
        self.whisperSpeedPreset = whisperSpeedPreset
        // 高速モードではCPUに余裕がないので1並列、それ以外は2並列
        self.whisperConcurrency = whisperSpeedPreset == 0 ? 1 : 2
    }

    enum PipelineError: LocalizedError {
        case noFiles
        case cancelled
        case clipFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .noFiles: return "ファイルが選択されていません"
            case .cancelled: return "処理がキャンセルされました"
            case .clipFailed(let name, let error): return "\(name) の処理に失敗: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Import & Sort

    func importAndSort(urls: [URL]) async -> [ProjectClip] {
        var clips: [ProjectClip] = []

        for url in urls {
            // ディレクトリを除外
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { continue }

            let ext = url.pathExtension.lowercased()
            let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "mts", "mxf"]
            guard videoExtensions.contains(ext) else { continue }

            var clip = ProjectClip(fileURL: url)

            // 撮影日時を取得
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                clip.duration = CMTimeGetSeconds(duration)
            }

            // メタデータから撮影日時を取得
            clip.creationDate = await getCreationDate(for: url, asset: asset)

            // ビデオメタデータ
            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
                let size = try? await videoTrack.load(.naturalSize)
                let fps = try? await videoTrack.load(.nominalFrameRate)
                clip.metadata.width = Int(size?.width ?? 0)
                clip.metadata.height = Int(size?.height ?? 0)
                clip.metadata.fps = Double(fps ?? 0)
            }
            clip.metadata.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            clip.metadata.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            clips.append(clip)
        }

        // 撮影日時でソート（nilは末尾）
        clips.sort { a, b in
            switch (a.creationDate, b.creationDate) {
            case (let dateA?, let dateB?): return dateA < dateB
            case (nil, _): return false
            case (_, nil): return true
            }
        }

        // sortOrderを設定
        for i in clips.indices {
            clips[i].sortOrder = i
        }

        return clips
    }

    private func getCreationDate(for url: URL, asset: AVURLAsset) async -> Date? {
        // 1. AVFoundation メタデータから取得
        if let metadata = try? await asset.load(.creationDate),
           let dateValue = try? await metadata.load(.dateValue) {
            return dateValue
        }

        // 2. ファイル属性から取得
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.creationDate] as? Date {
            return date
        }

        return nil
    }

    // MARK: - Transcribe Clip

    func transcribeClip(
        clip: ProjectClip,
        whisperModelPath: String?,
        userDictionary: [String],
        maxSegmentLength: Int,
        progressCallback: @escaping (Double) -> Void
    ) async throws -> TranscriptionResult {
        let whisper = WhisperService(modelPath: whisperModelPath, speedPreset: whisperSpeedPreset)
        return try await whisper.transcribe(
            fileURL: clip.fileURL,
            userDictionary: userDictionary,
            maxSegmentLength: maxSegmentLength,
            progressCallback: progressCallback
        )
    }

    // MARK: - Reformat Clip

    func reformatClip(
        transcription: TranscriptionResult,
        userDictionary: [String],
        maxSegmentLength: Int,
        progressCallback: @escaping (Double) -> Void
    ) async throws -> ClaudeAPIService.ReformatResult {
        let claude = try ClaudeAPIService()
        return try await claude.reformatTranscription(
            transcription: transcription,
            userDictionary: userDictionary,
            maxSegmentLength: maxSegmentLength,
            progressCallback: progressCallback
        )
    }

    // MARK: - Audio Analysis

    func analyzeAudio(clip: ProjectClip, settings: ProjectSettings) async -> (silent: [AudioSegment], filler: [AudioSegment], volume: AudioAnalyzer.ClipVolumeInfo?) {
        let audioAnalyzer = AudioAnalyzer()
        let silentSegments = await audioAnalyzer.detectSilence(
            in: clip.fileURL,
            thresholdDB: settings.silenceThresholdDB,
            minimumDuration: settings.minimumSilenceDuration
        )

        var fillerSegments: [AudioSegment] = []
        if let transcription = clip.bestTranscription {
            let fillerDetector = FillerWordDetector(fillerWords: settings.fillerWords)
            fillerSegments = fillerDetector.detect(in: transcription)
        }

        let volumeInfo = await audioAnalyzer.measureVolume(fileURL: clip.fileURL)
        return (silentSegments, fillerSegments, volumeInfo)
    }

    // MARK: - Story Analysis

    func runStoryAnalysis(clips: [ProjectClip], targetDurationSeconds: TimeInterval?, styleGuidance: String? = nil, genreGuidance: String? = nil) async throws -> StoryAnalysis {
        let claude = try ClaudeAPIService()
        return try await claude.analyzeStory(clips: clips, targetDurationSeconds: targetDurationSeconds, styleGuidance: styleGuidance, genreGuidance: genreGuidance)
    }

    // MARK: - Full Pipeline

    @MainActor
    func runFullPipeline(state: YouTubeEditorState, appState: AppState, resumeFrom: YouTubeEditorState.PipelinePhase = .transcribing) async {
        guard var project = state.project, !project.clips.isEmpty else {
            state.errorMessage = "クリップがありません"
            return
        }

        state.isCancelled = false
        state.errorMessage = nil
        state.pipelineStartTime = Date()

        let settings = ProjectSettings.default
        let userDictionary = appState.userDictionary
        let maxSegmentLength = appState.maxSegmentLength
        let whisperModelPath = appState.whisperModelPath.isEmpty ? nil : appState.whisperModelPath
        let styleGuidance: String? = {
            if let selectedID = state.selectedStyleProfileID,
               let profile = appState.styleProfiles.first(where: { $0.id == selectedID }) {
                return profile.guidance
            }
            return appState.defaultStyleProfile?.guidance
        }()

        // Phase 1: Transcription (並列) — 未完了のクリップだけ処理
        if resumeFrom.stepIndex <= YouTubeEditorState.PipelinePhase.transcribing.stepIndex {
            state.pipelinePhase = .transcribing
            state.currentOperation = "文字起こし中... (最大\(whisperConcurrency)並列)"

            for i in project.clips.indices where project.clips[i].transcriptionResult == nil {
                project.clips[i].pipelineState.transcription = .inProgress
            }
            state.project = project

            project = await runParallelPhase(
                project: project,
                state: state,
                maxConcurrency: whisperConcurrency,
                phaseLabel: "文字起こし",
                progressRange: (0.0, 0.33),
                shouldProcess: { clip, _ in clip.transcriptionResult == nil },
                process: { [self] clip, _ in
                    let result = try await self.transcribeClip(
                        clip: clip,
                        whisperModelPath: whisperModelPath,
                        userDictionary: userDictionary,
                        maxSegmentLength: maxSegmentLength,
                        progressCallback: { _ in }
                    )
                    return { (clip: inout ProjectClip) in
                        clip.transcriptionResult = result
                        clip.pipelineState.transcription = .completed
                    }
                },
                onFailure: { (clip: inout ProjectClip, error: Error) in
                    clip.pipelineState.transcription = .failed
                    return "\(clip.fileName) の文字起こしに失敗: \(error.localizedDescription)"
                }
            )

            // 文字起こしが1つもない場合はここで停止
            let hasAnyTranscription = project.clips.contains { $0.bestTranscription != nil }
            if !hasAnyTranscription {
                state.errorMessage = "全クリップの文字起こしに失敗しました。設定画面でWhisperモデルのパスを確認してください。"
                state.pipelinePhase = .review
                state.project = project
                return
            }
        }

        // Phase 2: AI Reformat (並列) — 未完了のクリップだけ処理
        if state.isCancelled { return handleCancellation(state: state, project: project) }
        if resumeFrom.stepIndex <= YouTubeEditorState.PipelinePhase.reformatting.stepIndex {
            state.pipelinePhase = .reformatting
            state.currentOperation = "AI整形中... (最大\(apiConcurrency)並列)"

            for i in project.clips.indices {
                if project.clips[i].transcriptionResult != nil && project.clips[i].reformattedResult == nil {
                    project.clips[i].pipelineState.reformat = .inProgress
                } else if project.clips[i].transcriptionResult == nil {
                    project.clips[i].pipelineState.reformat = .skipped
                }
            }
            state.project = project

            project = await runParallelPhase(
                project: project,
                state: state,
                maxConcurrency: apiConcurrency,
                phaseLabel: "AI整形",
                progressRange: (0.33, 0.55),
                shouldProcess: { clip, _ in clip.transcriptionResult != nil && clip.reformattedResult == nil },
                process: { [self] clip, _ in
                    guard let transcription = clip.transcriptionResult else {
                        return { (clip: inout ProjectClip) in
                            clip.pipelineState.reformat = .skipped
                        }
                    }
                    let result = try await self.reformatClip(
                        transcription: transcription,
                        userDictionary: userDictionary,
                        maxSegmentLength: maxSegmentLength,
                        progressCallback: { _ in }
                    )
                    let language = transcription.language
                    let duration = transcription.duration
                    // AI整形後にもハルシネーションフィルタを適用
                    // （Claudeが環境音のWhisper出力をもっともらしい文に書き換えるケース対策）
                    let filteredSegments = WhisperService.filterHallucinations(result.segments)
                    if filteredSegments.count != result.segments.count {
                        print("[YouTubePipeline] AI整形後ハルシネーション除去: \(result.segments.count) → \(filteredSegments.count)セグメント")
                    }
                    return { (clip: inout ProjectClip) in
                        clip.reformattedResult = TranscriptionResult(
                            segments: filteredSegments,
                            language: language,
                            duration: duration
                        )
                        clip.retakeSegments = result.retakeSegments
                        clip.pipelineState.reformat = .completed
                    }
                },
                onFailure: { (clip: inout ProjectClip, error: Error) in
                    clip.pipelineState.reformat = .failed
                    return "\(clip.fileName) のAI整形に失敗: \(error.localizedDescription)"
                }
            )
        }

        // クロスクリップハルシネーション検出: 全クリップの整形結果をまとめて分析
        // 環境音クリップでClaude AIが「もっともらしい文」を生成するケースを検出
        project = filterCrossClipHallucinations(project)
        state.project = project

        // Phase 3: Audio Analysis (並列) — 未完了のクリップだけ処理
        if state.isCancelled { return handleCancellation(state: state, project: project) }
        if resumeFrom.stepIndex <= YouTubeEditorState.PipelinePhase.analyzing.stepIndex {
            state.pipelinePhase = .analyzing
            state.currentOperation = "音声解析中... (最大\(analysisConcurrency)並列)"

            for i in project.clips.indices where project.clips[i].pipelineState.audioAnalysis != .completed {
                project.clips[i].pipelineState.audioAnalysis = .inProgress
            }
            state.project = project

            project = await runParallelPhase(
                project: project,
                state: state,
                maxConcurrency: analysisConcurrency,
                phaseLabel: "音声解析",
                progressRange: (0.55, 0.77),
                shouldProcess: { clip, _ in clip.pipelineState.audioAnalysis != .completed },
                process: { [self] clip, _ in
                    let (silent, filler, volume) = await self.analyzeAudio(clip: clip, settings: settings)
                    return { (clip: inout ProjectClip) in
                        clip.silentSegments = silent
                        clip.fillerSegments = filler
                        clip.volumeGainDB = volume?.gainAdjustment
                        clip.pipelineState.audioAnalysis = .completed
                    }
                },
                onFailure: { (clip: inout ProjectClip, error: Error) in
                    clip.pipelineState.audioAnalysis = .failed
                    return "\(clip.fileName) の音声解析に失敗: \(error.localizedDescription)"
                }
            )
        }

        // Phase 4: Story Analysis
        if state.isCancelled { return handleCancellation(state: state, project: project) }

        // 文字起こしが1つもない場合はストーリー分析をスキップ（Bロールのみでも不可）
        let hasMainClip = project.clips.contains { $0.bestTranscription != nil && !$0.isBRoll }
        guard hasMainClip else {
            let brollCount = project.clips.filter(\.isBRoll).count
            if brollCount == project.clips.count {
                state.errorMessage = "全クリップがBロール（無音）です。トーク素材を含むクリップを追加してください。"
            } else {
                state.errorMessage = "文字起こしが完了しているクリップがありません。"
            }
            state.pipelinePhase = .review
            state.project = project
            return
        }

        let brollClipCount = project.clips.filter(\.isBRoll).count
        if brollClipCount > 0 {
            print("[YouTubePipeline] Bロール検出: \(brollClipCount)/\(project.clips.count)クリップ")
        }

        state.pipelinePhase = .storyAnalysis
        state.currentOperation = "AIストーリー分析中..."
        state.overallProgress = 0.77

        do {
            let analysis = try await runStoryAnalysis(
                clips: project.clips,
                targetDurationSeconds: state.targetDurationSeconds,
                styleGuidance: styleGuidance,
                genreGuidance: state.selectedGenrePreset.editingGuidance
            )
            if state.isCancelled { return handleCancellation(state: state, project: project) }

            // バリデーション＆自動補正
            let clipDurations = project.clips.map { $0.duration }
            let validated = analysis.validated(clipCount: project.clips.count, clipDurations: clipDurations)

            // バリデーションログ
            let keptDiff = validated.keptSections.count - analysis.keptSections.count
            let removedDiff = validated.removedSections.count - analysis.removedSections.count
            if keptDiff != 0 || removedDiff != 0 {
                print("[YouTubePipeline] バリデーション補正: kept \(analysis.keptSections.count)→\(validated.keptSections.count), removed \(analysis.removedSections.count)→\(validated.removedSections.count)")
            }

            // カット点を無音境界にスナップ
            let clipSilentSegments = project.clips.map { $0.silentSegments }
            let snapped = validated.snappedToSilence(
                clipSilentSegments: clipSilentSegments,
                searchRadius: 1.5,
                silencePadding: state.selectedGenrePreset.silencePadding
            )
            print("[YouTubePipeline] カット点スナップ完了")

            project.storyAnalysis = snapped
            logCoverageStats(analysis: snapped, clips: project.clips)
            state.project = project
            state.overallProgress = 1.0
            state.pipelinePhase = .review
            state.currentOperation = "完了 — レビューしてください"
        } catch {
            state.errorMessage = "ストーリー分析に失敗: \(error.localizedDescription)"
            state.pipelinePhase = .review
            state.project = project
        }
    }

    // MARK: - Parallel Phase Runner

    /// 汎用的な並列フェーズ実行
    /// - process: クリップを受け取り、結果をクリップに適用するクロージャを返す（nonisolated）
    /// - onFailure: エラー時のクリップ更新とエラーメッセージ生成
    @MainActor
    private func runParallelPhase(
        project: YouTubeProject,
        state: YouTubeEditorState,
        maxConcurrency: Int,
        phaseLabel: String,
        progressRange: (start: Double, end: Double),
        shouldProcess: (ProjectClip, Int) -> Bool,
        process: @escaping @Sendable (ProjectClip, Int) async throws -> (@Sendable (inout ProjectClip) -> Void),
        onFailure: @escaping (inout ProjectClip, Error) -> String
    ) async -> YouTubeProject {
        var project = project
        let clipCount = project.clips.count
        let indices = project.clips.indices.filter { shouldProcess(project.clips[$0], $0) }

        guard !indices.isEmpty else {
            state.overallProgress = progressRange.end
            state.project = project
            return project
        }

        // セマフォ的な同時実行制御をTaskGroupで実現
        let results = await withTaskGroup(
            of: (index: Int, apply: (@Sendable (inout ProjectClip) -> Void)?, errorMsg: String?).self
        ) { group in
            var pending = indices.makeIterator()
            var completedCount = 0
            var resultList: [(index: Int, apply: (@Sendable (inout ProjectClip) -> Void)?, errorMsg: String?)] = []

            // 最初のmaxConcurrency個を投入
            for _ in 0..<min(maxConcurrency, indices.count) {
                if let idx = pending.next() {
                    let clip = project.clips[idx]
                    group.addTask {
                        do {
                            let apply = try await process(clip, idx)
                            return (index: idx, apply: apply, errorMsg: nil)
                        } catch {
                            return (index: idx, apply: nil, errorMsg: error.localizedDescription)
                        }
                    }
                }
            }

            // 完了するたびに次を投入
            for await result in group {
                resultList.append(result)
                completedCount += 1

                // 進捗更新（MainActorなのでOK）
                let progress = progressRange.start +
                    (progressRange.end - progressRange.start) * Double(completedCount) / Double(indices.count)
                state.overallProgress = progress
                state.currentOperation = "\(phaseLabel)中: \(completedCount)/\(clipCount) 完了"
                state.project = project

                // キャンセルチェック
                if state.isCancelled {
                    group.cancelAll()
                    break
                }

                // 次のタスクを投入
                if let idx = pending.next() {
                    let clip = project.clips[idx]
                    group.addTask {
                        do {
                            let apply = try await process(clip, idx)
                            return (index: idx, apply: apply, errorMsg: nil)
                        } catch {
                            return (index: idx, apply: nil, errorMsg: error.localizedDescription)
                        }
                    }
                }
            }

            return resultList
        }

        // 結果をprojectに適用
        for result in results {
            if let apply = result.apply {
                apply(&project.clips[result.index])
            } else if let errorMsg = result.errorMsg {
                let msg = onFailure(&project.clips[result.index],
                                     NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
                state.errorMessage = msg
            }
        }

        state.project = project
        return project
    }

    @MainActor
    private func handleCancellation(state: YouTubeEditorState, project: YouTubeProject) {
        state.project = project  // 途中結果は保持
        state.pipelinePhase = .review
        state.currentOperation = "処理を途中で停止しました"
        state.errorMessage = "パイプラインがキャンセルされました。途中結果でレビューできます。"
        state.isCancelled = false
    }

    // MARK: - Coverage Stats

    /// バリデーション後のカバレッジ統計をログ出力
    private func logCoverageStats(analysis: StoryAnalysis, clips: [ProjectClip]) {
        for (i, clip) in clips.enumerated() {
            let kept = analysis.keptSections.filter { $0.clipIndex == i }
            let removed = analysis.removedSections.filter { $0.clipIndex == i }
            let keptDuration = kept.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            let removedDuration = removed.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            let coverage = (keptDuration + removedDuration) / max(clip.duration, 0.1) * 100
            let lowConfKept = kept.filter { $0.confidence < 0.5 }.count
            let lowConfRemoved = removed.filter { $0.confidence < 0.5 }.count

            print("[YouTubePipeline] クリップ\(i) (\(clip.fileName)): " +
                  "kept=\(String(format: "%.0f", keptDuration))s, " +
                  "removed=\(String(format: "%.0f", removedDuration))s, " +
                  "coverage=\(String(format: "%.0f", coverage))%, " +
                  "低信頼度: kept=\(lowConfKept) removed=\(lowConfRemoved)")
        }
    }

    // MARK: - Cross-Clip Hallucination Filter

    /// 全クリップのbestTranscriptionをまとめて分析し、クリップ間で同じフレーズが異常に繰り返されている場合に除去
    /// Claude AIが環境音クリップで「もっともらしい嘘」を生成するケース（例: 「JR東日本E233系電車」が多数のクリップに出現）
    private func filterCrossClipHallucinations(_ project: YouTubeProject) -> YouTubeProject {
        var project = project

        // クリップ単位でテキストを収集（セグメント数ではなくクリップ数で閾値を計算）
        var clipTextSets: [[String]] = []
        for clip in project.clips {
            guard let transcription = clip.bestTranscription else {
                clipTextSets.append([])
                continue
            }
            clipTextSets.append(transcription.segments.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        }

        let clipCount = clipTextSets.filter { !$0.isEmpty }.count
        guard clipCount >= 3 else { return project }

        var hallPhrases: [String] = []

        // 方式1: 同一テキスト（句読点正規化後）が複数クリップに出現
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "。", with: "")
                .replacingOccurrences(of: "、", with: "")
                .replacingOccurrences(of: " ", with: "")
        }

        var normalizedClipCount: [String: Int] = [:]
        var normalizedToOriginals: [String: Set<String>] = [:]
        for texts in clipTextSets {
            var seenInClip: Set<String> = []
            for text in texts {
                let norm = normalize(text)
                guard !norm.isEmpty else { continue }
                if !seenInClip.contains(norm) {
                    seenInClip.insert(norm)
                    normalizedClipCount[norm, default: 0] += 1
                    normalizedToOriginals[norm, default: []].insert(text)
                }
            }
        }

        let clipThreshold = max(3, clipCount / 5)
        for (norm, count) in normalizedClipCount where count >= clipThreshold {
            if let originals = normalizedToOriginals[norm] {
                for original in originals {
                    hallPhrases.append(original)
                }
            }
        }

        // 方式2: 長いn-gram（6-15文字）が複数クリップに出現
        var gramClipCount: [String: Int] = [:]
        for texts in clipTextSets {
            var seenInClip: Set<String> = []
            for text in texts {
                let chars = Array(text)
                let maxGram = min(15, chars.count)
                guard maxGram >= 6 else { continue }
                for gramLen in 6...maxGram {
                    for i in 0...(chars.count - gramLen) {
                        let gram = String(chars[i..<(i + gramLen)])
                        if !seenInClip.contains(gram) {
                            seenInClip.insert(gram)
                            gramClipCount[gram, default: 0] += 1
                        }
                    }
                }
            }
        }

        let gramThreshold = max(3, clipCount / 5)
        let suspiciousGrams = gramClipCount.filter { $0.value >= gramThreshold }
            .sorted { $0.key.count > $1.key.count }
            .map { $0.key }

        for gram in suspiciousGrams {
            if !hallPhrases.contains(where: { $0.contains(gram) }) {
                hallPhrases.append(gram)
            }
        }

        guard !hallPhrases.isEmpty else { return project }

        print("[YouTubePipeline] クロスクリップハルシネーション検出: \(hallPhrases.map { "\"\(String($0.prefix(20)))\"" })")

        // 各クリップのreformattedResultからハルシネーションセグメントを除去
        for i in project.clips.indices {
            guard let transcription = project.clips[i].reformattedResult else { continue }
            let filtered = transcription.segments.filter { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                for phrase in hallPhrases {
                    if text.contains(phrase) {
                        print("[YouTubePipeline] クロスクリップ除去（\(project.clips[i].fileName)）: \(text.prefix(40))")
                        return false
                    }
                }
                return true
            }
            if filtered.count != transcription.segments.count {
                project.clips[i].reformattedResult = TranscriptionResult(
                    segments: filtered,
                    language: transcription.language,
                    duration: transcription.duration
                )
            }
        }

        return project
    }
}
