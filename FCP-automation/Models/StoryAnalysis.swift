import Foundation

struct StoryAnalysis: Codable {
    var clipOrder: [Int]
    var chapters: [StoryChapter]
    var keptSections: [KeptSection]
    var removedSections: [RemovedSection]
    var summary: String
    var bgmSuggestions: [BGMSuggestion]
    var hookSuggestion: HookSuggestion?
    var brollSuggestions: [BRollSuggestion]

    init(clipOrder: [Int], chapters: [StoryChapter], keptSections: [KeptSection], removedSections: [RemovedSection], summary: String, bgmSuggestions: [BGMSuggestion] = [], hookSuggestion: HookSuggestion? = nil, brollSuggestions: [BRollSuggestion] = []) {
        self.clipOrder = clipOrder
        self.chapters = chapters
        self.keptSections = keptSections
        self.removedSections = removedSections
        self.summary = summary
        self.bgmSuggestions = bgmSuggestions
        self.hookSuggestion = hookSuggestion
        self.brollSuggestions = brollSuggestions
    }

    /// 推定最終尺
    var estimatedDuration: TimeInterval {
        keptSections.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
    }

    /// AI送信用JSON文字列
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 分析結果のバリデーションと自動補正
    /// - clipCount: 元のProjectClipの数
    /// - clipDurations: 各クリップの長さ
    /// - Returns: 補正済みのStoryAnalysis
    func validated(clipCount: Int, clipDurations: [TimeInterval]) -> StoryAnalysis {
        var result = self

        // 1. clip_order のバリデーション: 存在しないインデックスを除去
        result.clipOrder = result.clipOrder.filter { $0 >= 0 && $0 < clipCount }
        // 全クリップがclipOrderに含まれていない場合は追加
        for i in 0..<clipCount {
            if !result.clipOrder.contains(i) {
                result.clipOrder.append(i)
            }
        }

        // 2. keptSections のバリデーション
        result.keptSections = result.keptSections.compactMap { section in
            var s = section
            // clip_index 範囲チェック
            guard s.clipIndex >= 0 && s.clipIndex < clipCount else { return nil }
            let clipDuration = clipDurations[s.clipIndex]
            // 時間範囲をクランプ
            s.startTime = max(0, min(s.startTime, clipDuration))
            s.endTime = max(s.startTime + 0.1, min(s.endTime, clipDuration))
            return s
        }

        // 3. removedSections のバリデーション
        result.removedSections = result.removedSections.compactMap { section in
            var s = section
            guard s.clipIndex >= 0 && s.clipIndex < clipCount else { return nil }
            let clipDuration = clipDurations[s.clipIndex]
            s.startTime = max(0, min(s.startTime, clipDuration))
            s.endTime = max(s.startTime + 0.1, min(s.endTime, clipDuration))
            return s
        }

        // 4. 同一クリップ内でkept同士の重なりを解消
        result.keptSections = resolveOverlaps(result.keptSections)

        // 5. ギャップをkeptSectionsで埋める（keep/removeどちらにも含まれない区間）
        result.keptSections = fillGaps(kept: result.keptSections, removed: result.removedSections, clipCount: clipCount, clipDurations: clipDurations)

        // 6. orderIndex を振り直す
        for i in result.keptSections.indices {
            result.keptSections[i].orderIndex = i
        }

        return result
    }

    /// カット点を無音境界にスナップする
    /// - clipSilentSegments: 各クリップの silentSegments 配列
    /// - searchRadius: スナップ先を探す範囲（秒）
    /// - silencePadding: 無音のうちカット点から残す余白（秒）
    func snappedToSilence(clipSilentSegments: [[AudioSegment]], searchRadius: TimeInterval = 1.5, silencePadding: TimeInterval = 0.15) -> StoryAnalysis {
        var result = self

        result.keptSections = result.keptSections.map { section in
            var s = section
            guard section.clipIndex < clipSilentSegments.count else { return s }
            let silences = clipSilentSegments[section.clipIndex]

            // startTime をスナップ（無音の終わり際にスナップ = 発話開始直前）
            if let snapped = findNearestSilenceBoundary(
                time: s.startTime, silences: silences, searchRadius: searchRadius,
                preferEnd: true, padding: silencePadding
            ) {
                s.startTime = snapped
            }

            // endTime をスナップ（無音の始まり際にスナップ = 発話終了直後）
            if let snapped = findNearestSilenceBoundary(
                time: s.endTime, silences: silences, searchRadius: searchRadius,
                preferEnd: false, padding: silencePadding
            ) {
                s.endTime = snapped
            }

            // startTime < endTime を保証
            if s.endTime <= s.startTime {
                s.endTime = s.startTime + 0.5
            }

            return s
        }

        result.removedSections = result.removedSections.map { section in
            var s = section
            guard section.clipIndex < clipSilentSegments.count else { return s }
            let silences = clipSilentSegments[section.clipIndex]

            if let snapped = findNearestSilenceBoundary(
                time: s.startTime, silences: silences, searchRadius: searchRadius,
                preferEnd: true, padding: silencePadding
            ) {
                s.startTime = snapped
            }

            if let snapped = findNearestSilenceBoundary(
                time: s.endTime, silences: silences, searchRadius: searchRadius,
                preferEnd: false, padding: silencePadding
            ) {
                s.endTime = snapped
            }

            if s.endTime <= s.startTime {
                s.endTime = s.startTime + 0.5
            }

            return s
        }

        return result
    }

    private enum CodingKeys: String, CodingKey {
        case clipOrder = "clip_order"
        case chapters, keptSections = "kept_sections"
        case removedSections = "removed_sections"
        case summary
        case bgmSuggestions = "bgm_suggestions"
        case hookSuggestion = "hook_suggestion"
        case brollSuggestions = "broll_suggestions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clipOrder = try container.decode([Int].self, forKey: .clipOrder)
        chapters = try container.decode([StoryChapter].self, forKey: .chapters)
        keptSections = try container.decode([KeptSection].self, forKey: .keptSections)
        removedSections = try container.decode([RemovedSection].self, forKey: .removedSections)
        summary = try container.decode(String.self, forKey: .summary)
        bgmSuggestions = try container.decodeIfPresent([BGMSuggestion].self, forKey: .bgmSuggestions) ?? []
        hookSuggestion = try container.decodeIfPresent(HookSuggestion.self, forKey: .hookSuggestion)
        brollSuggestions = try container.decodeIfPresent([BRollSuggestion].self, forKey: .brollSuggestions) ?? []
    }
}

struct StoryChapter: Codable {
    let title: String
    let description: String
}

struct KeptSection: Identifiable, Codable {
    let id: UUID
    var clipIndex: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var orderIndex: Int
    var reason: String
    var isEnabled: Bool
    var confidence: Double

    init(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval, orderIndex: Int, reason: String, confidence: Double = 1.0) {
        self.id = UUID()
        self.clipIndex = clipIndex
        self.startTime = startTime
        self.endTime = endTime
        self.orderIndex = orderIndex
        self.reason = reason
        self.isEnabled = true
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIndex = try container.decode(Int.self, forKey: .clipIndex)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        reason = try container.decode(String.self, forKey: .reason)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
    }

    var duration: TimeInterval {
        endTime - startTime
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clipIndex = "clip_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case orderIndex = "order_index"
        case reason
        case isEnabled = "is_enabled"
        case confidence
    }
}

struct RemovedSection: Identifiable, Codable {
    let id: UUID
    var clipIndex: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var reason: RemovalReason
    var explanation: String
    var isRemoved: Bool
    var confidence: Double

    init(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval, reason: RemovalReason, explanation: String, confidence: Double = 1.0) {
        self.id = UUID()
        self.clipIndex = clipIndex
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
        self.explanation = explanation
        self.isRemoved = true
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIndex = try container.decode(Int.self, forKey: .clipIndex)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        reason = try container.decode(RemovalReason.self, forKey: .reason)
        explanation = try container.decode(String.self, forKey: .explanation)
        isRemoved = try container.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? true
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
    }

    var duration: TimeInterval {
        endTime - startTime
    }

    enum RemovalReason: String, Codable {
        case duplicate = "重複"
        case unnecessary = "不要"
        case tooLong = "冗長"
        case lowQuality = "低品質"
        case offTopic = "脱線"

        var icon: String {
            switch self {
            case .duplicate: return "doc.on.doc"
            case .unnecessary: return "trash"
            case .tooLong: return "clock.badge.exclamationmark"
            case .lowQuality: return "exclamationmark.triangle"
            case .offTopic: return "arrow.uturn.right"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clipIndex = "clip_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case reason, explanation
        case isRemoved = "is_removed"
        case confidence
    }
}

// MARK: - Validation Helpers

private extension StoryAnalysis {

    /// 指定時間に最も近い無音境界を見つける
    /// - time: スナップしたい元の時間
    /// - silences: 無音セグメントの配列
    /// - searchRadius: 探索範囲（秒）
    /// - preferEnd: true=無音の終了点(発話開始前)を優先、false=無音の開始点(発話終了後)を優先
    /// - padding: 無音からカット点までの余白
    func findNearestSilenceBoundary(time: TimeInterval, silences: [AudioSegment], searchRadius: TimeInterval, preferEnd: Bool, padding: TimeInterval) -> TimeInterval? {
        // 検索範囲内の無音セグメントを探す
        let candidates = silences.filter { silence in
            let silenceCenter = (silence.startTime + silence.endTime) / 2
            return abs(silenceCenter - time) < searchRadius + (silence.endTime - silence.startTime) / 2
        }

        guard !candidates.isEmpty else { return nil }

        var bestTime: TimeInterval?
        var bestDistance = Double.infinity

        for silence in candidates {
            // 無音の開始点と終了点の両方を候補に
            let boundaries: [(TimeInterval, Bool)] = [
                (silence.startTime + padding, false),  // 無音の始まり（発話が終わった直後）
                (silence.endTime - padding, true)       // 無音の終わり（発話が始まる直前）
            ]

            for (boundary, isEnd) in boundaries {
                let distance = abs(boundary - time)
                if distance < searchRadius {
                    // preferEnd に合致する境界を優先
                    let priorityBonus = (isEnd == preferEnd) ? 0.0 : 0.2
                    let adjustedDistance = distance + priorityBonus

                    if adjustedDistance < bestDistance {
                        bestDistance = adjustedDistance
                        bestTime = boundary
                    }
                }
            }
        }

        return bestTime
    }

    func resolveOverlaps(_ sections: [KeptSection]) -> [KeptSection] {
        // clipIndex ごとにグループ化し、startTimeでソート
        var byClip: [Int: [KeptSection]] = [:]
        for s in sections {
            byClip[s.clipIndex, default: []].append(s)
        }

        var result: [KeptSection] = []
        for (_, clipSections) in byClip {
            let sorted = clipSections.sorted { $0.startTime < $1.startTime }
            var merged: [KeptSection] = []
            for section in sorted {
                if var last = merged.last, section.startTime < last.endTime {
                    // 重なり: endTime を拡張
                    last.endTime = max(last.endTime, section.endTime)
                    // confidence は高い方を採用
                    last.confidence = max(last.confidence, section.confidence)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(section)
                }
            }
            result.append(contentsOf: merged)
        }
        return result
    }

    func fillGaps(kept: [KeptSection], removed: [RemovedSection], clipCount: Int, clipDurations: [TimeInterval]) -> [KeptSection] {
        var result = kept

        for clipIdx in 0..<clipCount {
            let clipDuration = clipDurations[clipIdx]
            guard clipDuration > 0 else { continue }

            // このクリップの全カバー区間を収集
            var covered: [(start: TimeInterval, end: TimeInterval)] = []
            for s in kept where s.clipIndex == clipIdx {
                covered.append((s.startTime, s.endTime))
            }
            for s in removed where s.clipIndex == clipIdx {
                covered.append((s.startTime, s.endTime))
            }
            covered.sort { $0.start < $1.start }

            // ギャップを検出して低信頼度のkeptSectionとして追加
            var cursor: TimeInterval = 0
            for (start, end) in covered {
                if start > cursor + 0.5 { // 0.5秒以上のギャップ
                    result.append(KeptSection(
                        clipIndex: clipIdx,
                        startTime: cursor,
                        endTime: start,
                        orderIndex: 0,
                        reason: "未分析区間（自動補完）",
                        confidence: 0.3
                    ))
                }
                cursor = max(cursor, end)
            }
            // 末尾のギャップ
            if cursor + 0.5 < clipDuration {
                result.append(KeptSection(
                    clipIndex: clipIdx,
                    startTime: cursor,
                    endTime: clipDuration,
                    orderIndex: 0,
                    reason: "未分析区間（自動補完）",
                    confidence: 0.3
                ))
            }
        }

        return result
    }
}

// MARK: - BGM Suggestion

struct BGMSuggestion: Identifiable, Codable {
    let id: UUID
    var clipIndex: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var mood: String        // "upbeat", "calm", "dramatic" etc.
    var description: String // "メインの説明区間、落ち着いたBGMが合う"

    init(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval, mood: String, description: String) {
        self.id = UUID()
        self.clipIndex = clipIndex
        self.startTime = startTime
        self.endTime = endTime
        self.mood = mood
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIndex = try container.decode(Int.self, forKey: .clipIndex)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        mood = try container.decode(String.self, forKey: .mood)
        description = try container.decode(String.self, forKey: .description)
    }

    var duration: TimeInterval { endTime - startTime }

    var moodIcon: String {
        switch mood.lowercased() {
        case "upbeat", "energetic": return "bolt.fill"
        case "calm", "peaceful": return "leaf.fill"
        case "dramatic", "intense": return "flame.fill"
        case "funny", "playful": return "face.smiling.fill"
        case "sad", "emotional": return "drop.fill"
        default: return "music.note"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clipIndex = "clip_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case mood, description
    }
}

// MARK: - Hook Suggestion

struct HookSuggestion: Codable, Identifiable {
    let id: UUID
    var clipIndex: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var reason: String        // なぜこのシーンがフックとして効果的か
    var hookDuration: TimeInterval  // 冒頭に使う推奨尺（5-15秒程度）

    init(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval, reason: String, hookDuration: TimeInterval = 10.0) {
        self.id = UUID()
        self.clipIndex = clipIndex
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
        self.hookDuration = hookDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIndex = try container.decode(Int.self, forKey: .clipIndex)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        reason = try container.decode(String.self, forKey: .reason)
        hookDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .hookDuration) ?? 10.0
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clipIndex = "clip_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case reason
        case hookDuration = "hook_duration"
    }
}

// MARK: - B-Roll Suggestion

struct BRollSuggestion: Identifiable, Codable {
    let id: UUID
    var clipIndex: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var description: String   // "商品のアップショット", "作業風景" etc.
    var importance: Int       // 1-5

    init(clipIndex: Int, startTime: TimeInterval, endTime: TimeInterval, description: String, importance: Int) {
        self.id = UUID()
        self.clipIndex = clipIndex
        self.startTime = startTime
        self.endTime = endTime
        self.description = description
        self.importance = importance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIndex = try container.decode(Int.self, forKey: .clipIndex)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        description = try container.decode(String.self, forKey: .description)
        importance = try container.decodeIfPresent(Int.self, forKey: .importance) ?? 3
    }

    var duration: TimeInterval { endTime - startTime }

    private enum CodingKeys: String, CodingKey {
        case id
        case clipIndex = "clip_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case description, importance
    }
}
