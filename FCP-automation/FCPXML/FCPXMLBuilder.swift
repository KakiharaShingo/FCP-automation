import Foundation
import AVFoundation

class FCPXMLBuilder {

    enum FCPXMLError: LocalizedError {
        case invalidMedia
        case buildFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidMedia: return "メディアファイルが無効です"
            case .buildFailed(let reason): return "FCPXML生成に失敗: \(reason)"
            }
        }
    }

    private let fcpxmlVersion = "1.11"
    private let eventName = "FCP-automation"

    // MARK: - Transcription Timeline

    func buildTranscriptionTimeline(mediaURL: URL, transcription: TranscriptionResult) throws -> String {
        let mediaInfo = try getMediaInfo(url: mediaURL)
        let duration = transcription.duration

        let durationFrames = secondsToFrames(duration, fps: mediaInfo.fps)
        let formatID = "r1"
        let assetID = "r2"

        var xml = xmlHeader()
        xml += "  <resources>\n"
        xml += "    <format id=\"\(formatID)\" name=\"\(formatName(width: mediaInfo.width, height: mediaInfo.height, fps: mediaInfo.fps))\" frameDuration=\"\(frameDuration(mediaInfo.fps))\" " +
               "width=\"\(mediaInfo.width)\" height=\"\(mediaInfo.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"
        let fps = mediaInfo.fps
        let tcStart = mediaInfo.tcStartFrames
        xml += assetElement(id: assetID, name: mediaURL.lastPathComponent, src: mediaURL.absoluteString,
                             duration: timeValue(duration, fps: fps), fps: fps, tcStartFrames: tcStart)
        xml += "  </resources>\n"

        xml += "  <library>\n"
        xml += "    <event name=\"\(eventName)\">\n"
        xml += "      <project name=\"\(escapeXML(mediaURL.deletingPathExtension().lastPathComponent))_transcription\">\n"
        xml += "        <sequence format=\"\(formatID)\" duration=\"\(timeValue(duration, fps: fps))\" " +
               "tcStart=\"0s\" tcFormat=\"\(tcFormat(fps: fps))\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"

        // メディアクリップを配置（startはタイムコード空間）
        xml += "            <asset-clip ref=\"\(assetID)\" offset=\"0s\" " +
               "name=\"\(mediaURL.lastPathComponent)\" duration=\"\(timeValue(duration, fps: fps))\" " +
               "start=\"\(timeValueInTCSpace(0, fps: fps, tcStartFrames: tcStart))\">\n"

        // 文字起こしをマーカーとして追加
        for segment in transcription.segments {
            xml += "              <marker start=\"\(timeValue(segment.startTime, fps: fps))\" duration=\"\(frameDuration(fps))\" " +
                   "value=\"\(escapeXML(segment.text))\"/>\n"
        }

        xml += "            </asset-clip>\n"
        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        return xml
    }

    // MARK: - Auto Cut Timeline

    func buildAutoCutTimeline(mediaURL: URL, cutSegments: [AudioSegment], settings: ProjectSettings) throws -> String {
        let mediaInfo = try getMediaInfo(url: mediaURL)

        // カット区間をソートしてマージ
        let sortedCuts = cutSegments.sorted { $0.startTime < $1.startTime }

        // 残す区間を計算
        let keepSegments = calculateKeepSegments(totalDuration: mediaInfo.duration, cuts: sortedCuts)

        let formatID = "r1"
        let assetID = "r2"

        var xml = xmlHeader()
        xml += "  <resources>\n"
        xml += "    <format id=\"\(formatID)\" name=\"\(formatName(width: mediaInfo.width, height: mediaInfo.height, fps: mediaInfo.fps))\" frameDuration=\"\(frameDuration(mediaInfo.fps))\" " +
               "width=\"\(mediaInfo.width)\" height=\"\(mediaInfo.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"
        let fps = mediaInfo.fps
        let tcStart = mediaInfo.tcStartFrames
        xml += assetElement(id: assetID, name: mediaURL.lastPathComponent, src: mediaURL.absoluteString,
                             duration: timeValue(mediaInfo.duration, fps: fps), fps: fps, tcStartFrames: tcStart)
        xml += "  </resources>\n"

        // 残す区間の合計長（整数フレーム演算）
        let (_, den) = timeRational(0, fps: fps)
        var totalNum = 0
        for segment in keepSegments {
            let (durNum, _) = timeRational(segment.end - segment.start, fps: fps)
            totalNum += durNum
        }

        xml += "  <library>\n"
        xml += "    <event name=\"\(eventName)\">\n"
        xml += "      <project name=\"\(escapeXML(mediaURL.deletingPathExtension().lastPathComponent))_autocut\">\n"
        xml += "        <sequence format=\"\(formatID)\" duration=\"\(timeValueFromRational(totalNum, den))\" " +
               "tcStart=\"0s\" tcFormat=\"\(tcFormat(fps: fps))\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"

        var offsetNum = 0
        for segment in keepSegments {
            let (durNum, _) = timeRational(segment.end - segment.start, fps: fps)
            xml += "            <asset-clip ref=\"\(assetID)\" " +
                   "offset=\"\(timeValueFromRational(offsetNum, den))\" " +
                   "name=\"\(mediaURL.lastPathComponent)\" " +
                   "duration=\"\(timeValueFromRational(durNum, den))\" " +
                   "start=\"\(timeValueInTCSpace(segment.start, fps: fps, tcStartFrames: tcStart))\"/>\n"
            offsetNum += durNum
        }

        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        return xml
    }

    // MARK: - Integrated Timeline (Auto Cut + Subtitles)

    func buildIntegratedTimeline(
        mediaURL: URL,
        cutSegments: [AudioSegment],
        transcription: TranscriptionResult,
        subtitleStyle: SubtitleStyle,
        settings: ProjectSettings
    ) throws -> String {
        let mediaInfo = try getMediaInfo(url: mediaURL)

        let sortedCuts = cutSegments.sorted { $0.startTime < $1.startTime }
        let keepSegments = calculateKeepSegments(totalDuration: mediaInfo.duration, cuts: sortedCuts)

        let formatID = "r1"
        let assetID = "r2"
        let effectID = "r3"

        var xml = xmlHeader()
        xml += "  <resources>\n"
        xml += "    <format id=\"\(formatID)\" name=\"\(formatName(width: mediaInfo.width, height: mediaInfo.height, fps: mediaInfo.fps))\" frameDuration=\"\(frameDuration(mediaInfo.fps))\" " +
               "width=\"\(mediaInfo.width)\" height=\"\(mediaInfo.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"
        let fps = mediaInfo.fps
        let tcStart = mediaInfo.tcStartFrames
        xml += assetElement(id: assetID, name: mediaURL.lastPathComponent, src: mediaURL.absoluteString,
                             duration: timeValue(mediaInfo.duration, fps: fps), fps: fps, tcStartFrames: tcStart)
        xml += "    <effect id=\"\(effectID)\" name=\"Basic Title\" " +
               "uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"
        xml += "  </resources>\n"

        // 整数フレーム単位で累積（浮動小数点誤差防止）
        let (_, den) = timeRational(0, fps: fps)
        var totalKeepNum = 0
        for seg in keepSegments {
            let (durNum, _) = timeRational(seg.end - seg.start, fps: fps)
            totalKeepNum += durNum
        }

        // テロップ位置のY値を算出
        let positionY: Int
        switch subtitleStyle.verticalPosition {
        case .bottom: positionY = -450
        case .center: positionY = 0
        case .top: positionY = 450
        }

        xml += "  <library>\n"
        xml += "    <event name=\"\(eventName)\">\n"
        xml += "      <project name=\"\(mediaURL.deletingPathExtension().lastPathComponent)_integrated\">\n"
        xml += "        <sequence format=\"\(formatID)\" duration=\"\(timeValueFromRational(totalKeepNum, den))\" " +
               "tcStart=\"0s\" tcFormat=\"\(tcFormat(fps: fps))\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"

        var offsetNum = 0
        var titleIndex = 0

        for keepSeg in keepSegments {
            let (durNum, _) = timeRational(keepSeg.end - keepSeg.start, fps: fps)

            xml += "            <asset-clip ref=\"\(assetID)\" " +
                   "offset=\"\(timeValueFromRational(offsetNum, den))\" " +
                   "name=\"\(mediaURL.lastPathComponent)\" " +
                   "duration=\"\(timeValueFromRational(durNum, den))\" " +
                   "start=\"\(timeValueInTCSpace(keepSeg.start, fps: fps, tcStartFrames: tcStart))\">\n"

            // このkeep区間に重なるテロップを配置
            for segment in transcription.segments {
                // セグメントがkeep区間と重なるか判定
                let overlapStart = max(segment.startTime, keepSeg.start)
                let overlapEnd = min(segment.endTime, keepSeg.end)
                guard overlapEnd > overlapStart else { continue }

                // keep区間内での相対位置（asset-clip内のオフセット）
                let relativeStart = overlapStart - keepSeg.start
                let relativeDuration = overlapEnd - overlapStart

                titleIndex += 1
                let tsID = "ts\(titleIndex)"

                xml += "              <title ref=\"\(effectID)\" lane=\"1\" " +
                       "offset=\"\(timeValue(relativeStart, fps: fps))\" " +
                       "name=\"\(escapeXML(segment.text))\" " +
                       "duration=\"\(timeValue(relativeDuration, fps: fps))\" " +
                       "start=\"\(titleStartValue(relativeStart: relativeStart, fps: fps))\">\n"
                xml += "                <param name=\"Position\" key=\"9999/999166631/999166633/1/100/101\" " +
                       "value=\"0 \(positionY)\"/>\n"
                xml += "                <text>\n"
                xml += "                  <text-style ref=\"\(tsID)\">\(escapeXML(segment.text))</text-style>\n"
                xml += "                </text>\n"
                xml += "                <text-style-def id=\"\(tsID)\">\n"
                let intStroke = subtitleStyle.strokeEnabled
                    ? " strokeColor=\"\(subtitleStyle.fcpxmlStrokeColor)\" strokeWidth=\"\(String(format: "%.1f", subtitleStyle.strokeWidth))\""
                    : ""
                xml += "                  <text-style font=\"\(escapeXML(subtitleStyle.fontName))\" " +
                       "fontSize=\"\(subtitleStyle.fcpxmlFontSize)\" " +
                       "fontColor=\"\(subtitleStyle.fcpxmlFontColor)\" " +
                       "alignment=\"center\"\(intStroke)/>\n"
                xml += "                </text-style-def>\n"
                xml += "              </title>\n"
            }

            xml += "            </asset-clip>\n"
            offsetNum += durNum
        }

        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        return xml
    }

    // MARK: - YouTube Multi-Clip Timeline

    /// tcFormat判定: 29.97/59.94fps → DF（ドロップフレーム）、それ以外 → NDF
    private func tcFormat(fps: Double) -> String {
        let nfps = normalizedFPS(fps)
        return (nfps == 29.97 || nfps == 59.94) ? "DF" : "NDF"
    }

    /// チャプターのタイムライン上での開始フレーム位置を計算
    private func calculateChapterTimelineOffsets(
        chapters: [StoryChapter],
        enabledSections: [KeptSection],
        clips: [ProjectClip],
        fps: Double
    ) -> [Int] {
        // チャプター数だけオフセットを返す
        // チャプターiの開始 = enabledSectionsをorderIndex順に並べたとき、
        // セクションをチャプター数で均等分割した各グループの先頭のオフセット
        guard !chapters.isEmpty, !enabledSections.isEmpty else { return [] }

        let (_, den) = timeRational(0, fps: fps)

        // 各セクションの開始フレームオフセットを計算
        var sectionOffsets: [Int] = []
        var currentOffset = 0
        for section in enabledSections {
            sectionOffsets.append(currentOffset)
            guard section.clipIndex < clips.count else { continue }
            let clip = clips[section.clipIndex]
            // セクション範囲をクリップduration内にクランプ
            let clampedEnd = min(section.endTime, clip.duration)
            let clampedStart = min(section.startTime, clampedEnd)
            guard clampedEnd > clampedStart else { continue }
            let subKeep = calculateSubKeepSegments(
                sectionStart: clampedStart,
                sectionEnd: clampedEnd,
                cutSegments: clip.allCutSegments
            )
            for subSeg in subKeep {
                let (durNum, _) = timeRational(subSeg.end - subSeg.start, fps: fps)
                currentOffset += durNum
            }
        }

        // セクションをチャプター数で均等分割
        let sectionsPerChapter = max(1, enabledSections.count / chapters.count)
        var chapterOffsets: [Int] = []
        for chIdx in 0..<chapters.count {
            let sectionIndex = min(chIdx * sectionsPerChapter, sectionOffsets.count - 1)
            chapterOffsets.append(sectionOffsets[sectionIndex])
        }
        return chapterOffsets
    }

    func buildYouTubeTimeline(
        project: YouTubeProject,
        subtitleStyle: SubtitleStyle,
        settings: ProjectSettings,
        pluginPreset: PluginPreset? = nil,
        exportSettings: ExportSettings = .default
    ) throws -> String {
        guard let analysis = project.storyAnalysis else {
            throw FCPXMLError.buildFailed("ストーリー分析結果がありません")
        }

        let enabledSections = analysis.keptSections
            .filter { $0.isEnabled }
            .sorted { $0.orderIndex < $1.orderIndex }

        guard !enabledSections.isEmpty else {
            throw FCPXMLError.buildFailed("有効なセクションがありません")
        }

        // エクスポート時クロスクリップハルシネーションフィルタ:
        // 全クリップのテロップを収集し、同一テキストが多数クリップに出現する場合は除去
        let hallucinationTexts = detectCrossClipHallucinationTexts(project: project)

        let effectID = "rEffect"
        let transitionID = "rTransition"

        // 各クリップのメディア情報を取得
        var clipMediaInfos: [(clip: ProjectClip, info: MediaInfo)] = []
        for clip in project.clips {
            let info = try getMediaInfo(url: clip.fileURL)
            clipMediaInfos.append((clip, info))
        }

        // 最初のクリップの解像度/fpsをプロジェクト基準にする
        let baseInfo = clipMediaInfos.first?.info ?? MediaInfo(width: 1920, height: 1080, fps: 30.0, duration: 0, startTime: 0, tcStartFrames: 0)

        let fps = baseInfo.fps
        let (_, den) = timeRational(0, fps: fps)

        // トランジション尺（0.5秒、フレーム精度）
        let transitionSeconds: TimeInterval = 0.5
        let (transitionDurNum, _) = timeRational(transitionSeconds, fps: fps)

        // オーディオフェード尺
        let audioFadeSeconds: TimeInterval = 0.8
        let (audioFadeDurNum, _) = timeRational(audioFadeSeconds, fps: fps)

        // --- FPS別format要素を収集 ---
        // sequence(プロジェクト)のformat = baseInfoのFPS（formatID "r1"）
        // 各クリップ固有のFPSが異なる場合は追加のformat要素を生成
        struct FormatEntry {
            let id: String
            let width: Int
            let height: Int
            let fps: Double
        }
        let baseFormatID = "r1"
        var formatEntries: [FormatEntry] = [FormatEntry(id: baseFormatID, width: baseInfo.width, height: baseInfo.height, fps: baseInfo.fps)]
        // クリップindex → format ID のマッピング
        var clipFormatIDs: [Int: String] = [:]
        var nextFormatIndex = 1  // r1は使用済み
        for (i, pair) in clipMediaInfos.enumerated() {
            let clipNFPS = normalizedFPS(pair.info.fps)
            let baseNFPS = normalizedFPS(baseInfo.fps)
            if clipNFPS == baseNFPS {
                clipFormatIDs[i] = baseFormatID
            } else {
                // 既存のformat要素で同じFPS+解像度があるか確認
                if let existing = formatEntries.first(where: {
                    normalizedFPS($0.fps) == clipNFPS && $0.width == pair.info.width && $0.height == pair.info.height
                }) {
                    clipFormatIDs[i] = existing.id
                } else {
                    nextFormatIndex += 1
                    let newFormatID = "r1_\(nextFormatIndex)"
                    formatEntries.append(FormatEntry(id: newFormatID, width: pair.info.width, height: pair.info.height, fps: pair.info.fps))
                    clipFormatIDs[i] = newFormatID
                }
            }
        }

        // --- resources ---
        var xml = xmlHeader()
        xml += "  <resources>\n"
        // 全format要素を出力
        for fmt in formatEntries {
            xml += "    <format id=\"\(fmt.id)\" name=\"\(formatName(width: fmt.width, height: fmt.height, fps: fmt.fps))\" frameDuration=\"\(frameDuration(fmt.fps))\" " +
                   "width=\"\(fmt.width)\" height=\"\(fmt.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"
        }

        // 各クリップをアセットとして登録（各クリップ固有のFPSを使用）
        for (i, pair) in clipMediaInfos.enumerated() {
            let assetID = "r\(i + 2)"
            let clipFPS = pair.info.fps
            let formatRef = clipFormatIDs[i] ?? baseFormatID
            xml += assetElement(id: assetID, name: pair.clip.fileName, src: pair.clip.fileURL.absoluteString,
                                duration: timeValue(pair.info.duration, fps: clipFPS),
                                formatRef: formatRef,
                                hasAudio: pair.clip.metadata.hasAudio, fps: clipFPS,
                                tcStartFrames: pair.info.tcStartFrames)
        }

        // テロップテンプレート: カスタム or Basic Title
        if let preset = pluginPreset, preset.hasCustomTitle,
           let titleUID = preset.titleTemplateUID, let titleName = preset.titleTemplateName {
            xml += "    <effect id=\"\(effectID)\" name=\"\(escapeXML(titleName))\" " +
                   "uid=\"\(escapeXML(titleUID))\"/>\n"
        } else {
            xml += "    <effect id=\"\(effectID)\" name=\"Basic Title\" " +
                   "uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"
        }

        // Cross Dissolveトランジション（セクション間）
        xml += "    <effect id=\"\(transitionID)\" name=\"Cross Dissolve\" " +
               "uid=\"FxPlug:4731E73A-8DAC-4113-9F71-5F9F71B3DD4E\"/>\n"

        // プラグインプリセットのエフェクト宣言
        if let preset = pluginPreset {
            for (i, plugin) in preset.plugins.enumerated() {
                guard plugin.category == .videoFilter || plugin.category == .audioFilter else { continue }
                let pluginRefID = "rPlugin\(i + 1)"
                let uid = plugin.effectUID.isEmpty ? plugin.effectID : plugin.effectUID
                xml += "    <effect id=\"\(pluginRefID)\" name=\"\(escapeXML(plugin.effectName))\" uid=\"\(escapeXML(uid))\"/>\n"
            }
            for (i, ref) in preset.effectTemplates.enumerated() {
                let effectRefID = "rMotionEffect\(i + 1)"
                xml += "    <effect id=\"\(effectRefID)\" name=\"\(escapeXML(ref.templateName))\" uid=\"\(escapeXML(ref.fcpxmlUID))\"/>\n"
            }
        }

        xml += "  </resources>\n"

        // --- テロップ設定 ---
        let positionY: Int
        switch subtitleStyle.verticalPosition {
        case .bottom: positionY = -450
        case .center: positionY = 0
        case .top: positionY = 450
        }

        // ストローク属性
        let strokeAttrs: String
        if subtitleStyle.strokeEnabled {
            strokeAttrs = " strokeColor=\"\(subtitleStyle.fcpxmlStrokeColor)\" strokeWidth=\"\(String(format: "%.1f", subtitleStyle.strokeWidth))\""
        } else {
            strokeAttrs = ""
        }

        // --- 各セクションのsub-keepセグメントを事前計算 ---
        struct SectionClipInfo {
            let sectionIndex: Int
            let clipIndex: Int
            let assetID: String
            let clipTCStart: Int
            let clipFPS: Double  // クリップ固有のFPS
            let subKeepSegments: [(start: TimeInterval, end: TimeInterval)]
        }

        var allClipInfos: [SectionClipInfo] = []
        for (sIdx, section) in enabledSections.enumerated() {
            guard section.clipIndex < project.clips.count else { continue }
            let clip = project.clips[section.clipIndex]
            let assetID = "r\(section.clipIndex + 2)"
            let clipTCStart = (section.clipIndex < clipMediaInfos.count) ? clipMediaInfos[section.clipIndex].info.tcStartFrames : 0
            let clipFPS = (section.clipIndex < clipMediaInfos.count) ? clipMediaInfos[section.clipIndex].info.fps : fps
            // セクション範囲をクリップのメディアduration内にクランプ
            let clipDuration = (section.clipIndex < clipMediaInfos.count) ? clipMediaInfos[section.clipIndex].info.duration : clip.duration
            let clampedStart = min(section.startTime, clipDuration)
            let clampedEnd = min(section.endTime, clipDuration)
            guard clampedEnd > clampedStart else { continue }
            let subKeep = calculateSubKeepSegments(
                sectionStart: clampedStart,
                sectionEnd: clampedEnd,
                cutSegments: clip.allCutSegments
            )
            allClipInfos.append(SectionClipInfo(
                sectionIndex: sIdx, clipIndex: section.clipIndex,
                assetID: assetID, clipTCStart: clipTCStart, clipFPS: clipFPS, subKeepSegments: subKeep
            ))
        }

        // spine上の全asset-clipをフラット化（トランジション挿入位置を特定するため）
        struct SpineClip {
            let sectionIndex: Int
            let subSegIndex: Int
            let assetID: String
            let clipTCStart: Int
            let clipFPS: Double  // クリップ固有のFPS（asset-clip start属性に使用）
            let start: TimeInterval
            let end: TimeInterval
            let durNum: Int
            let clip: ProjectClip
            let isLastInSection: Bool
            let isFirstInSection: Bool
        }

        var spineClips: [SpineClip] = []
        for info in allClipInfos {
            let clip = project.clips[info.clipIndex]
            for (subIdx, subSeg) in info.subKeepSegments.enumerated() {
                let (durNum, _) = timeRational(subSeg.end - subSeg.start, fps: fps)
                spineClips.append(SpineClip(
                    sectionIndex: info.sectionIndex, subSegIndex: subIdx,
                    assetID: info.assetID, clipTCStart: info.clipTCStart,
                    clipFPS: info.clipFPS,
                    start: subSeg.start, end: subSeg.end, durNum: durNum,
                    clip: clip,
                    isLastInSection: subIdx == info.subKeepSegments.count - 1,
                    isFirstInSection: subIdx == 0
                ))
            }
        }

        // トランジション挿入可能かをセクション境界ごとに判定
        // （前クリップの末尾と次クリップの先頭にメディアハンドル余裕が必要）
        var transitionEnabledAtBoundary: [Int: Bool] = [:] // sectionIndex → 可否
        do {
            var prevSection: SpineClip?
            for sc in spineClips {
                if sc.isFirstInSection, let prev = prevSection, prev.sectionIndex != sc.sectionIndex {
                    // 前クリップ: メディア末尾にトランジション分の余裕があるか
                    let prevClipIdx = project.clips.firstIndex(where: { $0.id == prev.clip.id }) ?? 0
                    let prevClipInfo = clipMediaInfos[prevClipIdx]
                    let prevMediaEnd = prevClipInfo.info.duration
                    let prevClipEnd = prev.end
                    let prevHasHandle = (prevMediaEnd - prevClipEnd) >= transitionSeconds * 0.5

                    // 次クリップ: メディア先頭にトランジション分の余裕があるか
                    let nextClipStart = sc.start
                    let nextHasHandle = nextClipStart >= transitionSeconds * 0.5

                    transitionEnabledAtBoundary[sc.sectionIndex] = prevHasHandle && nextHasHandle
                }
                if sc.isLastInSection {
                    prevSection = sc
                }
            }
        }

        // 合計尺を計算（トランジション分の重複を考慮）
        var totalFrameNumerator = 0
        var prevSectionIndex = -1
        for (_, sc) in spineClips.enumerated() {
            totalFrameNumerator += sc.durNum
            // セクション境界にトランジションを挿入する場合、トランジション分を減算
            if sc.isFirstInSection && prevSectionIndex >= 0 && prevSectionIndex != sc.sectionIndex {
                if transitionEnabledAtBoundary[sc.sectionIndex] == true {
                    totalFrameNumerator -= transitionDurNum
                }
            }
            if sc.isLastInSection {
                prevSectionIndex = sc.sectionIndex
            }
        }

        // --- チャプターマーカーのタイムライン位置を計算 ---
        let chapterOffsets = calculateChapterTimelineOffsets(
            chapters: analysis.chapters,
            enabledSections: enabledSections,
            clips: project.clips,
            fps: fps
        )

        // --- sequence ---
        xml += "  <library>\n"
        xml += "    <event name=\"\(eventName)\">\n"
        xml += "      <project name=\"\(escapeXML(project.name))\">\n"
        xml += "        <sequence format=\"\(baseFormatID)\" duration=\"\(timeValueFromRational(totalFrameNumerator, den))\" " +
               "tcStart=\"0s\" tcFormat=\"\(tcFormat(fps: fps))\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"

        var offsetNumerator = 0
        var titleIndex = 0
        var prevSpineSectionIndex = -1

        for (clipIdx, sc) in spineClips.enumerated() {
            let isFirstClip = clipIdx == 0
            let isLastClip = clipIdx == spineClips.count - 1

            // セクション境界でトランジション挿入（メディアハンドル余裕がある場合のみ）
            let insertTransition = sc.isFirstInSection && prevSpineSectionIndex >= 0 && prevSpineSectionIndex != sc.sectionIndex
                && transitionEnabledAtBoundary[sc.sectionIndex] == true
            if insertTransition {
                // トランジションはoffset = 前のクリップの終端 - 半分
                let transOffsetNum = offsetNumerator - transitionDurNum
                xml += "            <transition name=\"Cross Dissolve\" " +
                       "offset=\"\(timeValueFromRational(transOffsetNum, den))\" " +
                       "duration=\"\(timeValueFromRational(transitionDurNum, den))\">\n"
                xml += "              <filter-video ref=\"\(transitionID)\" name=\"Cross Dissolve\"/>\n"
                xml += "            </transition>\n"
                // トランジションは前後クリップに重なるのでoffsetを戻す
                offsetNumerator -= transitionDurNum
            }

            // asset-clip: offset/durationはspineタイムベース(プロジェクトFPS)、startはassetタイムベース(クリップ固有FPS)
            xml += "            <asset-clip ref=\"\(sc.assetID)\" " +
                   "offset=\"\(timeValueFromRational(offsetNumerator, den))\" " +
                   "name=\"\(escapeXML(sc.clip.fileName))\" " +
                   "duration=\"\(timeValueFromRational(sc.durNum, den))\" " +
                   "start=\"\(timeValueInTCSpace(sc.start, fps: sc.clipFPS, tcStartFrames: sc.clipTCStart))\">\n"

            // DTD順序: adjust-volume → title(anchor_item) → chapter-marker(marker_item) → filter-video → filter-audio

            // [1] adjust-volume（音量ノーマライズ + フェードイン/アウト）
            // DTD: adjust-volume → param* で、param → fadeIn?, fadeOut?
            do {
                let gainDB = exportSettings.applyVolumeNormalization ? (sc.clip.volumeGainDB ?? 0) : Float(0)
                let needsFadeIn = isFirstClip && sc.durNum > audioFadeDurNum * 2
                let needsFadeOut = isLastClip && sc.durNum > audioFadeDurNum * 2
                let hasGain = abs(gainDB) > 0.1

                if hasGain || needsFadeIn || needsFadeOut {
                    let amountStr = hasGain ? String(format: "%+.1fdB", gainDB) : "0dB"
                    xml += "              <adjust-volume amount=\"\(amountStr)\">\n"
                    if needsFadeIn || needsFadeOut {
                        xml += "                <param name=\"amount\">\n"
                        if needsFadeIn {
                            xml += "                  <fadeIn type=\"easeIn\" duration=\"\(timeValueFromRational(audioFadeDurNum, den))\"/>\n"
                        }
                        if needsFadeOut {
                            xml += "                  <fadeOut type=\"easeOut\" duration=\"\(timeValueFromRational(audioFadeDurNum, den))\"/>\n"
                        }
                        xml += "                </param>\n"
                    }
                    xml += "              </adjust-volume>\n"
                }
            }

            // [2] title（テロップ = anchor_item）
            if let transcription = sc.clip.bestTranscription {
                for segment in transcription.segments {
                    let overlapStart = max(segment.startTime, sc.start)
                    let overlapEnd = min(segment.endTime, sc.end)
                    guard overlapEnd > overlapStart else { continue }

                    // ハルシネーションテキストをスキップ
                    let segText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if hallucinationTexts.contains(where: { segText.contains($0) }) {
                        continue
                    }

                    let relativeStart = overlapStart - sc.start
                    let relativeDuration = overlapEnd - overlapStart

                    titleIndex += 1
                    let tsID = "ts\(titleIndex)"

                    xml += "              <title ref=\"\(effectID)\" lane=\"1\" " +
                           "offset=\"\(timeValue(relativeStart, fps: fps))\" " +
                           "name=\"\(escapeXML(segment.text))\" " +
                           "duration=\"\(timeValue(relativeDuration, fps: fps))\" " +
                           "start=\"\(titleStartValue(relativeStart: relativeStart, fps: fps))\">\n"
                    xml += "                <param name=\"Position\" key=\"9999/999166631/999166633/1/100/101\" " +
                           "value=\"0 \(positionY)\"/>\n"
                    xml += "                <text>\n"
                    xml += "                  <text-style ref=\"\(tsID)\">\(escapeXML(segment.text))</text-style>\n"
                    xml += "                </text>\n"
                    xml += "                <text-style-def id=\"\(tsID)\">\n"
                    xml += "                  <text-style font=\"\(escapeXML(subtitleStyle.fontName))\" " +
                           "fontSize=\"\(subtitleStyle.fcpxmlFontSize)\" " +
                           "fontColor=\"\(subtitleStyle.fcpxmlFontColor)\" " +
                           "alignment=\"center\"" +
                           "\(strokeAttrs)/>\n"
                    xml += "                </text-style-def>\n"
                    xml += "              </title>\n"
                }
            }

            // [2b] chapter-title（チャプター開始点にタイトルテロップを3秒間表示）
            for (chIdx, chOffset) in chapterOffsets.enumerated() {
                // 最初のチャプター（0:00）はスキップ（冒頭にタイトルは不要）
                guard chIdx > 0 else { continue }
                if chOffset >= offsetNumerator && chOffset < offsetNumerator + sc.durNum {
                    let markerOffsetInClip = chOffset - offsetNumerator
                    let chapterTitleDurNum = timeRational(3.0, fps: fps).0
                    // クリップ内に収まるようクランプ
                    let actualDurNum = min(chapterTitleDurNum, sc.durNum - markerOffsetInClip)
                    guard actualDurNum > 0 else { continue }

                    titleIndex += 1
                    let chTsID = "chts\(titleIndex)"
                    let chapterTitle = analysis.chapters[chIdx].title

                    xml += "              <title ref=\"\(effectID)\" lane=\"2\" " +
                           "offset=\"\(timeValueFromRational(markerOffsetInClip, den))\" " +
                           "name=\"Chapter: \(escapeXML(chapterTitle))\" " +
                           "duration=\"\(timeValueFromRational(actualDurNum, den))\" " +
                           "start=\"3600s\">\n"
                    // チャプタータイトルは画面上部に配置
                    xml += "                <param name=\"Position\" key=\"9999/999166631/999166633/1/100/101\" " +
                           "value=\"0 420\"/>\n"
                    xml += "                <text>\n"
                    xml += "                  <text-style ref=\"\(chTsID)\">\(escapeXML(chapterTitle))</text-style>\n"
                    xml += "                </text>\n"
                    xml += "                <text-style-def id=\"\(chTsID)\">\n"
                    xml += "                  <text-style font=\"Helvetica Neue\" " +
                           "fontSize=\"72\" " +
                           "fontColor=\"1 1 1 1\" " +
                           "alignment=\"center\" " +
                           "strokeColor=\"0 0 0 1\" strokeWidth=\"3\"/>\n"
                    xml += "                </text-style-def>\n"
                    xml += "              </title>\n"
                }
            }

            // [3] chapter-marker（marker_item）
            for (chIdx, chOffset) in chapterOffsets.enumerated() {
                if chOffset >= offsetNumerator && chOffset < offsetNumerator + sc.durNum {
                    let markerOffsetInClip = chOffset - offsetNumerator
                    xml += "              <chapter-marker start=\"\(timeValueFromRational(markerOffsetInClip, den))\" " +
                           "duration=\"\(frameDuration(fps))\" " +
                           "value=\"\(escapeXML(analysis.chapters[chIdx].title))\"/>\n"
                }
            }

            // [4] filter-video → [5] filter-audio
            if let preset = pluginPreset {
                // filter-video: カスタムプラグイン
                for (i, plugin) in preset.plugins.enumerated() {
                    guard plugin.category == .videoFilter else { continue }
                    let pluginRefID = "rPlugin\(i + 1)"
                    xml += "              <filter-video ref=\"\(pluginRefID)\" name=\"\(escapeXML(plugin.effectName))\">\n"
                    for param in plugin.parameters {
                        xml += "                <param name=\"\(escapeXML(param.key))\" value=\"\(escapeXML(param.value))\"/>\n"
                    }
                    xml += "              </filter-video>\n"
                }
                // filter-video: Motionエフェクトテンプレート
                for (i, ref) in preset.effectTemplates.enumerated() {
                    let effectRefID = "rMotionEffect\(i + 1)"
                    xml += "              <filter-video ref=\"\(effectRefID)\" name=\"\(escapeXML(ref.templateName))\"/>\n"
                }
                // filter-audio: カスタムプラグイン
                for (i, plugin) in preset.plugins.enumerated() {
                    guard plugin.category == .audioFilter else { continue }
                    let pluginRefID = "rPlugin\(i + 1)"
                    xml += "              <filter-audio ref=\"\(pluginRefID)\" name=\"\(escapeXML(plugin.effectName))\">\n"
                    for param in plugin.parameters {
                        xml += "                <param name=\"\(escapeXML(param.key))\" value=\"\(escapeXML(param.value))\"/>\n"
                    }
                    xml += "              </filter-audio>\n"
                }
            }

            xml += "            </asset-clip>\n"
            offsetNumerator += sc.durNum
            if sc.isLastInSection {
                prevSpineSectionIndex = sc.sectionIndex
            }
        }

        xml += "          </spine>\n"

        // [BGM] BGMオーディオトラック（spine外、sequence内のconnected clip, lane=-1）
        if let bgmURL = exportSettings.bgmFileURL {
            let bgmAssetID = "rBGM"
            let bgmVolDB = exportSettings.bgmVolumeDB
            let totalDurationValue = timeValueFromRational(totalFrameNumerator, den)

            // BGM assetをresourcesに追加（stringの置換で挿入）
            xml = xml.replacingOccurrences(
                of: "  </resources>",
                with: "    <asset id=\"\(bgmAssetID)\" name=\"BGM\" src=\"\(escapeXML(bgmURL.absoluteString))\" " +
                      "hasVideo=\"0\" hasAudio=\"1\" " +
                      "audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"/>\n" +
                      "  </resources>"
            )

            // BGMをspine外に配置（lane=-1）
            let bgmAmountStr = String(format: "%+.1fdB", bgmVolDB)
            xml += "          <asset-clip ref=\"\(bgmAssetID)\" lane=\"-1\" " +
                   "offset=\"0s\" " +
                   "name=\"BGM\" " +
                   "duration=\"\(totalDurationValue)\" " +
                   "start=\"0s\">\n"
            xml += "            <adjust-volume amount=\"\(bgmAmountStr)\"/>\n"
            xml += "          </asset-clip>\n"
        }

        // [B-Roll] Bロール自動配置（lane=3）
        if exportSettings.autoBRollPlacement && !analysis.brollSuggestions.isEmpty {
            let brollClipEntries = project.clips.enumerated().filter { $0.element.isBRoll }

            if !brollClipEntries.isEmpty {
            for (sugIdx, suggestion) in analysis.brollSuggestions.enumerated() {
                let brollEntry = brollClipEntries[sugIdx % brollClipEntries.count]
                let brollClip = brollEntry.element
                let brollAssetID = "r\(brollEntry.offset + 2)"

                let brollDuration = min(suggestion.duration, brollClip.duration)
                guard brollDuration > 0.5 else { continue }

                // タイムライン上の挿入位置を計算
                var targetOffset = 0
                var accum = 0
                for sc in spineClips {
                    accum += sc.durNum
                }
                // 簡易計算: 提案のstartTimeをタイムライン全体の割合で配置
                let ratio = min(1.0, suggestion.startTime / max(1, project.totalRawDuration))
                targetOffset = Int(Double(totalFrameNumerator) * ratio)

                let (brollDurNum, _) = timeRational(brollDuration, fps: fps)
                xml += "          <asset-clip ref=\"\(brollAssetID)\" lane=\"3\" " +
                       "offset=\"\(timeValueFromRational(targetOffset, den))\" " +
                       "name=\"B-Roll: \(escapeXML(brollClip.displayName))\" " +
                       "duration=\"\(timeValueFromRational(brollDurNum, den))\" " +
                       "start=\"0s\"/>\n"
            }
            } // if !brollClipEntries.isEmpty
        }

        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        return xml
    }

    /// KeptSection範囲内でさらにauto-cut（無音/フィラー除去）を適用した残り区間を計算
    private func calculateSubKeepSegments(
        sectionStart: TimeInterval,
        sectionEnd: TimeInterval,
        cutSegments: [AudioSegment]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        // セクション範囲内のカットセグメントだけをフィルタ
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

    // MARK: - Timeline from Items

    func buildTimelineFromItems(items: [TimelineItem], settings: ProjectSettings = .default) throws -> String {
        guard !items.isEmpty else { throw FCPXMLError.buildFailed("アイテムがありません") }

        let formatID = "r1"

        var xml = xmlHeader()
        xml += "  <resources>\n"
        xml += "    <format id=\"\(formatID)\" name=\"\(formatName(width: settings.width, height: settings.height, fps: settings.framerate))\" frameDuration=\"\(frameDuration(settings.framerate))\" " +
               "width=\"\(settings.width)\" height=\"\(settings.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"

        let fps = settings.framerate

        // 各メディアファイルをアセットとして登録（タイムコード情報も取得）
        var itemTCFrames: [Int] = []
        for (i, item) in items.enumerated() {
            let assetID = "r\(i + 2)"
            let tcFrames = readTimecodeFrames(url: item.fileURL, fps: fps)
            itemTCFrames.append(tcFrames)
            xml += assetElement(id: assetID, name: item.fileName, src: item.fileURL.absoluteString,
                                duration: timeValue(item.duration, fps: fps),
                                hasVideo: item.metadata.hasVideo, hasAudio: item.metadata.hasAudio, fps: fps,
                                tcStartFrames: tcFrames)
        }

        xml += "  </resources>\n"

        // メインクリップをspineに配置、Bロール/インサートをconnectedとして配置
        let mainItems = items.filter { $0.clipType == .main }.sorted { $0.startTime < $1.startTime }
        let connectedItems = items.filter { $0.clipType != .main }

        // 整数フレーム単位で累積（浮動小数点誤差防止）
        let (_, den) = timeRational(0, fps: fps)
        var totalDurNum = 0
        for item in mainItems {
            let (durNum, _) = timeRational(item.duration, fps: fps)
            totalDurNum += durNum
        }

        xml += "  <library>\n"
        xml += "    <event name=\"\(eventName)\">\n"
        xml += "      <project name=\"\(settings.projectName)\">\n"
        xml += "        <sequence format=\"\(formatID)\" duration=\"\(timeValueFromRational(totalDurNum, den))\" " +
               "tcStart=\"0s\" tcFormat=\"\(tcFormat(fps: fps))\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"

        var offsetNum = 0
        var offsetSeconds: TimeInterval = 0
        for item in mainItems {
            let assetIndex = items.firstIndex(where: { $0.id == item.id })!
            let assetID = "r\(assetIndex + 2)"
            let (durNum, _) = timeRational(item.duration, fps: fps)
            let tcFrames = itemTCFrames[assetIndex]

            xml += "            <asset-clip ref=\"\(assetID)\" " +
                   "offset=\"\(timeValueFromRational(offsetNum, den))\" " +
                   "name=\"\(escapeXML(item.fileName))\" " +
                   "duration=\"\(timeValueFromRational(durNum, den))\" " +
                   "start=\"\(timeValueInTCSpace(0, fps: fps, tcStartFrames: tcFrames))\">\n"

            // このクリップの時間範囲内にある接続クリップを追加
            for connected in connectedItems {
                if connected.startTime >= offsetSeconds && connected.startTime < offsetSeconds + item.duration {
                    let connAssetIndex = items.firstIndex(where: { $0.id == connected.id })!
                    let connAssetID = "r\(connAssetIndex + 2)"
                    let relativeOffset = connected.startTime - offsetSeconds

                    xml += "              <asset-clip ref=\"\(connAssetID)\" " +
                           "lane=\"\(connected.trackIndex + 1)\" " +
                           "offset=\"\(timeValue(relativeOffset, fps: fps))\" " +
                           "name=\"\(escapeXML(connected.fileName))\" " +
                           "duration=\"\(timeValue(connected.duration, fps: fps))\" " +
                           "start=\"0s\"/>\n"
                }
            }

            xml += "            </asset-clip>\n"
            offsetNum += durNum
            offsetSeconds += item.duration
        }

        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        return xml
    }

    // MARK: - Plugin Application

    func applyPlugins(to xml: String, preset: PluginPreset) throws -> String {
        // asset-clipタグの閉じタグ前にfilterを挿入
        var result = xml

        for plugin in preset.plugins {
            let filterXML: String
            switch plugin.category {
            case .videoFilter:
                filterXML = "              <filter-video ref=\"\(plugin.effectID)\" name=\"\(escapeXML(plugin.effectName))\"/>\n"
            case .audioFilter:
                filterXML = "              <filter-audio ref=\"\(plugin.effectID)\" name=\"\(escapeXML(plugin.effectName))\"/>\n"
            default:
                continue
            }

            // 各asset-clipの閉じタグ前に挿入
            result = result.replacingOccurrences(of: "            </asset-clip>",
                                                  with: filterXML + "            </asset-clip>")
        }

        return result
    }

    // MARK: - Helper Methods

    private func xmlHeader() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE fcpxml>\n" +
        "\n" +
        "<fcpxml version=\"\(fcpxmlVersion)\">\n"
    }

    /// fpsを正規化（Float→Double変換の誤差を吸収）
    private func normalizedFPS(_ fps: Double) -> Double {
        let known: [(range: ClosedRange<Double>, value: Double)] = [
            (23.97...23.99, 23.976),
            (24.0...24.0, 24),
            (25.0...25.0, 25),
            (29.96...29.98, 29.97),
            (30.0...30.0, 30),
            (50.0...50.0, 50),
            (59.93...59.95, 59.94),
            (60.0...60.0, 60),
        ]
        for k in known {
            if k.range.contains(fps) { return k.value }
        }
        return fps
    }

    private func frameDuration(_ fps: Double) -> String {
        switch normalizedFPS(fps) {
        case 23.976: return "1001/24000s"
        case 24: return "100/2400s"
        case 25: return "100/2500s"
        case 29.97: return "1001/30000s"
        case 30: return "100/3000s"
        case 50: return "100/5000s"
        case 59.94: return "1001/60000s"
        case 60: return "100/6000s"
        default: return "100/\(Int(fps * 100))s"
        }
    }

    /// FCP準拠のFFVideoFormatフォーマット名を生成
    /// 例: FFVideoFormat1080p2997, FFVideoFormat3840x2160p24, FFVideoFormat1080p30
    private func formatName(width: Int, height: Int, fps: Double) -> String {
        // 解像度部分: 1080p, 720p は省略形、それ以外は WxH
        let resolution: String
        switch (width, height) {
        case (1920, 1080): resolution = "1080p"
        case (1280, 720): resolution = "720p"
        default: resolution = "\(width)x\(height)p"
        }

        // FPS部分: NTSC系は特殊表記
        let fpsStr: String
        switch normalizedFPS(fps) {
        case 23.976: fpsStr = "2398"
        case 29.97: fpsStr = "2997"
        case 59.94: fpsStr = "5994"
        default: fpsStr = "\(Int(fps))"
        }

        return "FFVideoFormat\(resolution)\(fpsStr)"
    }

    private func secondsToFrames(_ seconds: TimeInterval, fps: Double) -> Int {
        Int(seconds * fps)
    }

    private func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 秒数をFCPXML互換のフレーム精度分数形式に変換
    /// fps指定時: フレーム境界にスナップ（例: 59.94fps → "x/60000s"）
    /// fps未指定: 1/1000s精度
    private func timeValue(_ seconds: TimeInterval, fps: Double = 0) -> String {
        let (num, den) = timeRational(seconds, fps: fps)
        return "\(num)/\(den)s"
    }

    /// 秒数をフレーム精度の有理数(分子, 分母)に変換
    /// 整数演算で蓄積可能にする（浮動小数点丸め誤差を防ぐ）
    private func timeRational(_ seconds: TimeInterval, fps: Double = 0) -> (Int, Int) {
        let nfps = normalizedFPS(fps)
        switch nfps {
        case 23.976:
            let frames = Int(round(seconds * 24000.0 / 1001.0))
            return (frames * 1001, 24000)
        case 29.97:
            let frames = Int(round(seconds * 30000.0 / 1001.0))
            return (frames * 1001, 30000)
        case 59.94:
            let frames = Int(round(seconds * 60000.0 / 1001.0))
            return (frames * 1001, 60000)
        case 24:
            let frames = Int(round(seconds * 24))
            return (frames * 100, 2400)
        case 25:
            let frames = Int(round(seconds * 25))
            return (frames * 100, 2500)
        case 30:
            let frames = Int(round(seconds * 30))
            return (frames * 100, 3000)
        case 50:
            let frames = Int(round(seconds * 50))
            return (frames * 100, 5000)
        case 60:
            let frames = Int(round(seconds * 60))
            return (frames * 100, 6000)
        default:
            let ms = Int(round(seconds * 1000))
            return (ms, 1000)
        }
    }

    /// 有理数時間値を文字列化
    private func timeValueFromRational(_ numerator: Int, _ denominator: Int) -> String {
        "\(numerator)/\(denominator)s"
    }

    /// タイトルのstart属性を整数フレーム演算で計算
    /// Basic TitleのデフォルトTC開始は "3600 × 整数fps" フレーム目
    /// relativeStartSeconds: タイトルのクリップ内相対開始位置（秒）
    private func titleStartValue(relativeStart: TimeInterval, fps: Double) -> String {
        let nfps = normalizedFPS(fps)
        let (relNum, den) = timeRational(relativeStart, fps: fps)
        let baseFrames: Int
        switch nfps {
        case 23.976: baseFrames = 3600 * 24    // 86400 frames
        case 29.97:  baseFrames = 3600 * 30    // 108000 frames
        case 59.94:  baseFrames = 3600 * 60    // 216000 frames
        case 24:     baseFrames = 3600 * 24
        case 25:     baseFrames = 3600 * 25
        case 30:     baseFrames = 3600 * 30
        case 50:     baseFrames = 3600 * 50
        case 60:     baseFrames = 3600 * 60
        default:     baseFrames = 3600 * 30
        }
        let multiplier: Int
        switch nfps {
        case 23.976, 29.97, 59.94: multiplier = 1001
        default: multiplier = den / max(Int(round(nfps)), 1)
        }
        let baseNumerator = baseFrames * multiplier
        return "\(baseNumerator + relNum)/\(den)s"
    }

    /// メディア内の秒数をタイムコード空間のFCPXML時間値に変換
    /// tcStartFrames: メディアのタイムコード開始フレーム番号
    /// seconds: メディア内の相対秒数（0から始まる）
    private func timeValueInTCSpace(_ seconds: TimeInterval, fps: Double, tcStartFrames: Int) -> String {
        let (relNum, den) = timeRational(seconds, fps: fps)
        let nfps = normalizedFPS(fps)
        let multiplier: Int
        switch nfps {
        case 23.976: multiplier = 1001
        case 29.97: multiplier = 1001
        case 59.94: multiplier = 1001
        default: multiplier = den / max(Int(round(nfps)), 1)
        }
        let tcOffset = tcStartFrames * multiplier
        return "\(tcOffset + relNum)/\(den)s"
    }

    /// FCPXML v1.11準拠のasset要素を生成（media-rep子要素を使用）
    /// tcStartFrames: メディアのタイムコード開始フレーム番号（0の場合はstart="0s"を使用）
    private func assetElement(
        id: String,
        name: String,
        src: String,
        start: String = "0s",
        duration: String,
        formatRef: String = "r1",
        hasVideo: Bool = true,
        hasAudio: Bool = true,
        fps: Double = 0,
        tcStartFrames: Int = 0
    ) -> String {
        // srcをfile:// URL形式に変換（日本語・スペース等をパーセントエンコード）
        let encodedSrc: String
        if src.hasPrefix("file://") {
            encodedSrc = src
        } else {
            encodedSrc = URL(fileURLWithPath: src).absoluteString
        }

        // uidはファイルパスから再現可能なユニークIDを生成
        let uid = stableUID(from: encodedSrc)

        // タイムコード開始位置がある場合はそれをassetのstartに使用
        let assetStart: String
        if tcStartFrames > 0 {
            let (_, den) = timeRational(0, fps: fps)
            let nfps = normalizedFPS(fps)
            let multiplier: Int
            switch nfps {
            case 23.976: multiplier = 1001
            case 29.97: multiplier = 1001
            case 59.94: multiplier = 1001
            default: multiplier = den / max(Int(round(nfps)), 1)
            }
            assetStart = "\(tcStartFrames * multiplier)/\(den)s"
        } else {
            assetStart = start
        }

        var xml = "    <asset id=\"\(id)\" name=\"\(escapeXML(name))\" uid=\"\(uid)\" " +
                  "start=\"\(assetStart)\" duration=\"\(duration)\" " +
                  "hasVideo=\"\(hasVideo ? "1" : "0")\" format=\"\(formatRef)\" " +
                  "hasAudio=\"\(hasAudio ? "1" : "0")\" " +
                  (hasVideo ? "videoSources=\"1\" " : "") +
                  "audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n"
        xml += "      <media-rep kind=\"original-media\" src=\"\(encodedSrc)\"/>\n"
        xml += "    </asset>\n"
        return xml
    }

    /// ファイルパスから再現可能なUID文字列を生成
    private func stableUID(from path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llX%016llX", hash, hash ^ 0xDEADBEEF12345678)
    }

    private struct MediaInfo {
        let width: Int
        let height: Int
        let fps: Double
        let duration: TimeInterval
        let startTime: TimeInterval // ソースメディアのタイムコード開始位置
        let tcStartFrames: Int      // タイムコード開始位置（フレーム番号、ドロップフレーム補正済み）
    }

    private func getMediaInfo(url: URL) throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        // 同期的にメタデータを取得（互換性のため）
        let tracks = asset.tracks(withMediaType: .video)
        if let videoTrack = tracks.first {
            let size = videoTrack.naturalSize
            let fps = Double(videoTrack.nominalFrameRate)
            let duration = CMTimeGetSeconds(asset.duration)
            let segmentStart = videoTrack.segments.first.map { CMTimeGetSeconds($0.timeMapping.target.start) } ?? 0
            // タイムコードをffprobeで取得
            let tcFrames = readTimecodeFrames(url: url, fps: fps)
            return MediaInfo(width: Int(size.width), height: Int(size.height),
                           fps: fps > 0 ? fps : 30.0, duration: duration,
                           startTime: segmentStart, tcStartFrames: tcFrames)
        }

        // 音声のみのファイル
        let duration = CMTimeGetSeconds(asset.duration)
        return MediaInfo(width: 1920, height: 1080, fps: 30.0, duration: duration, startTime: 0, tcStartFrames: 0)
    }

    /// ffprobeでメディアファイルのタイムコードを読み取り、フレーム番号に変換
    private func readTimecodeFrames(url: URL, fps: Double) -> Int {
        // ffprobeでタイムコード取得
        let tcString = readTimecodeString(url: url)
        guard !tcString.isEmpty else { return 0 }
        return parseTimecodeToFrames(tcString, fps: fps)
    }

    /// ffprobeでタイムコード文字列を取得（例: "14:56:34;12"）
    private func readTimecodeString(url: URL) -> String {
        let ffprobePaths = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        guard let ffprobePath = ffprobePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return ""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = ["-v", "quiet", "-show_entries", "format_tags=timecode",
                           "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 複数行の場合は最初の行を使用
            return output.components(separatedBy: "\n").first ?? ""
        } catch {
            return ""
        }
    }

    /// タイムコード文字列をフレーム番号に変換
    /// ドロップフレーム（;区切り）とノンドロップフレーム（:区切り）両方に対応
    private func parseTimecodeToFrames(_ tc: String, fps: Double) -> Int {
        let isDropFrame = tc.contains(";")
        let parts = tc.replacingOccurrences(of: ";", with: ":").split(separator: ":")
        guard parts.count == 4,
              let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let f = Int(parts[3]) else { return 0 }

        let nfps = normalizedFPS(fps)
        let nominalFPS: Int
        let dropsPerMinute: Int

        switch nfps {
        case 23.976:
            nominalFPS = 24; dropsPerMinute = 0 // 23.976は通常ドロップフレームを使わない
        case 29.97:
            nominalFPS = 30; dropsPerMinute = isDropFrame ? 2 : 0
        case 59.94:
            nominalFPS = 60; dropsPerMinute = isDropFrame ? 4 : 0
        default:
            nominalFPS = Int(round(nfps)); dropsPerMinute = 0
        }

        // ドロップフレームなしの総フレーム数
        let totalFrames = h * 3600 * nominalFPS + m * 60 * nominalFPS + s * nominalFPS + f

        // ドロップフレーム補正
        if dropsPerMinute > 0 {
            let totalMinutes = h * 60 + m
            let dropped = dropsPerMinute * (totalMinutes - totalMinutes / 10)
            return totalFrames - dropped
        }

        return totalFrames
    }

    // MARK: - Cross-Clip Hallucination Detection (Export-time)

    /// エクスポート時にクリップ横断でハルシネーションテキストを検出
    /// 方式1: 同一テキスト（句読点・空白正規化後）が複数クリップに出現
    /// 方式2: 長いn-gram（6文字以上）が多数のセグメント/クリップに出現
    private func detectCrossClipHallucinationTexts(project: YouTubeProject) -> [String] {
        // クリップごとにテロップテキスト集合を作成
        var clipTextSets: [[String]] = []  // クリップindex → [テキスト]
        var allTexts: [String] = []

        for clip in project.clips {
            guard let transcription = clip.bestTranscription else {
                clipTextSets.append([])
                continue
            }
            let texts = transcription.segments.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            clipTextSets.append(texts)
            allTexts.append(contentsOf: texts)
        }

        guard allTexts.count >= 2 else { return [] }

        var hallucinationPhrases: Set<String> = []

        // --- 方式1: 同一テキスト（正規化後）が3クリップ以上に出現 → ハルシネーション ---
        // 正規化: 句読点と空白を除去して比較
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "。", with: "")
                .replacingOccurrences(of: "、", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
        }

        // 正規化テキスト → 出現クリップ数
        var normalizedClipCount: [String: Int] = [:]
        var normalizedToOriginals: [String: Set<String>] = [:]

        for texts in clipTextSets {
            var seenInThisClip: Set<String> = []
            for text in texts {
                let norm = normalize(text)
                guard !norm.isEmpty else { continue }
                if !seenInThisClip.contains(norm) {
                    seenInThisClip.insert(norm)
                    normalizedClipCount[norm, default: 0] += 1
                    normalizedToOriginals[norm, default: []].insert(text)
                }
            }
        }

        // 3クリップ以上に出現するテキスト = ハルシネーション
        let clipThreshold = max(3, project.clips.count / 5)
        for (norm, count) in normalizedClipCount where count >= clipThreshold {
            if let originals = normalizedToOriginals[norm] {
                for original in originals {
                    hallucinationPhrases.insert(original)
                    print("[FCPXMLBuilder] ハルシネーション検出（\(count)クリップに出現）: \(original.prefix(40))")
                }
            }
        }

        // --- 方式2: 長いn-gram（6-15文字）が多数のクリップに出現 ---
        var gramClipCount: [String: Int] = [:]
        for texts in clipTextSets {
            var seenInThisClip: Set<String> = []
            for text in texts {
                let chars = Array(text)
                let maxGram = min(15, chars.count)
                guard maxGram >= 6 else { continue }
                for gramLen in 6...maxGram {
                    for i in 0...(chars.count - gramLen) {
                        let gram = String(chars[i..<(i + gramLen)])
                        if !seenInThisClip.contains(gram) {
                            seenInThisClip.insert(gram)
                            gramClipCount[gram, default: 0] += 1
                        }
                    }
                }
            }
        }

        let gramClipThreshold = max(3, project.clips.count / 5)
        let suspiciousGrams = gramClipCount.filter { $0.value >= gramClipThreshold }
            .sorted { $0.key.count > $1.key.count }
            .map { $0.key }

        // 重複排除（長いフレーズが短いフレーズを含む場合）
        for gram in suspiciousGrams {
            if !hallucinationPhrases.contains(where: { $0.contains(gram) }) {
                hallucinationPhrases.insert(gram)
                print("[FCPXMLBuilder] n-gramハルシネーション検出（\(gramClipCount[gram] ?? 0)クリップ）: \(gram.prefix(40))")
            }
        }

        // --- 方式3: 環境音でClaude AIが生成しがちな特徴的パターン ---
        // クリップに1つしかセグメントがなく、かつそのテキストが「説明的で汎用的」なパターン
        let genericPatterns = [
            "電車", "マンション", "ボタンをクリック", "スイッチを使用",
            "動画はここまで", "画面に進んで", "方向を望む",
            "することができます", "見ることができます", "動かすことができます",
            "ここにあります", "中にあります",
        ]

        for (clipIdx, texts) in clipTextSets.enumerated() {
            // 1セグメントのみのクリップで、汎用パターンにマッチ
            guard texts.count == 1 else { continue }
            let text = texts[0]
            let matchCount = genericPatterns.filter { text.contains($0) }.count
            // 2つ以上のパターンにマッチ → ハルシネーション疑い
            // ただし、同じテキストが他のクリップにもある場合のみ確定
            if matchCount >= 2 {
                let norm = normalize(text)
                if (normalizedClipCount[norm] ?? 0) >= 2 {
                    hallucinationPhrases.insert(text)
                    print("[FCPXMLBuilder] 汎用パターンハルシネーション（\(project.clips[clipIdx].fileName)）: \(text.prefix(40))")
                }
            }
        }

        return Array(hallucinationPhrases)
    }

    private func calculateKeepSegments(totalDuration: TimeInterval, cuts: [AudioSegment]) -> [(start: TimeInterval, end: TimeInterval)] {
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
