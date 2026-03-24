import Foundation

/// 編集計画からタイムライン上のセグメント情報を計算する共有ユーティリティ
/// FCPXMLBuilder, SRTGenerator, FFmpegRenderService が共通で使用
struct TimelineCalculator {

    struct TimelineSegment {
        let clipIndex: Int
        let sourceStart: TimeInterval  // クリップ内の開始位置
        let sourceEnd: TimeInterval    // クリップ内の終了位置
        let timelineStart: TimeInterval // タイムライン上の開始位置
        let timelineEnd: TimeInterval   // タイムライン上の終了位置

        var sourceDuration: TimeInterval { sourceEnd - sourceStart }
        var timelineDuration: TimeInterval { timelineEnd - timelineStart }
    }

    /// StoryAnalysisのkeptSectionsから、カット除去済みのタイムラインセグメントリストを生成
    /// - Parameters:
    ///   - analysis: ストーリー分析結果
    ///   - clips: プロジェクトクリップ配列
    /// - Returns: タイムライン上に配置されるセグメントの配列（時系列順）
    static func buildTimelineSegments(analysis: StoryAnalysis, clips: [ProjectClip]) -> [TimelineSegment] {
        let enabledSections = analysis.keptSections
            .filter { $0.isEnabled }
            .sorted { $0.orderIndex < $1.orderIndex }

        var segments: [TimelineSegment] = []
        var timelineCursor: TimeInterval = 0

        for section in enabledSections {
            guard section.clipIndex >= 0, section.clipIndex < clips.count else { continue }
            let clip = clips[section.clipIndex]
            let clipDuration = clip.duration

            let clampedStart = max(0, min(section.startTime, clipDuration))
            let clampedEnd = max(clampedStart, min(section.endTime, clipDuration))
            guard clampedEnd > clampedStart else { continue }

            let subKeep = calculateSubKeepSegments(
                sectionStart: clampedStart,
                sectionEnd: clampedEnd,
                cutSegments: clip.allCutSegments
            )

            for sub in subKeep {
                let duration = sub.end - sub.start
                guard duration > 0.01 else { continue }
                segments.append(TimelineSegment(
                    clipIndex: section.clipIndex,
                    sourceStart: sub.start,
                    sourceEnd: sub.end,
                    timelineStart: timelineCursor,
                    timelineEnd: timelineCursor + duration
                ))
                timelineCursor += duration
            }
        }

        return segments
    }

    /// KeptSection範囲内でカットセグメント（無音/フィラー）を除去した残り区間を計算
    static func calculateSubKeepSegments(
        sectionStart: TimeInterval,
        sectionEnd: TimeInterval,
        cutSegments: [AudioSegment]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let relevantCuts = cutSegments
            .filter { $0.endTime > sectionStart && $0.startTime < sectionEnd }
            .map { AudioSegment(
                startTime: max($0.startTime, sectionStart),
                endTime: min($0.endTime, sectionEnd),
                type: $0.type,
                label: $0.label
            )}
            .sorted { $0.startTime < $1.startTime }

        return calculateKeepSegments(totalDuration: sectionEnd, cuts: relevantCuts)
            .filter { $0.start >= sectionStart }
            .map { (start: max($0.start, sectionStart), end: min($0.end, sectionEnd)) }
            .filter { $0.end > $0.start }
    }

    /// カットセグメントの間を「残す区間」として計算
    private static func calculateKeepSegments(totalDuration: TimeInterval, cuts: [AudioSegment]) -> [(start: TimeInterval, end: TimeInterval)] {
        var keep: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0

        for cut in cuts {
            if cut.startTime > currentStart {
                keep.append((start: currentStart, end: cut.startTime))
            }
            currentStart = max(currentStart, cut.endTime)
        }

        if currentStart < totalDuration {
            keep.append((start: currentStart, end: totalDuration))
        }

        return keep
    }
}
