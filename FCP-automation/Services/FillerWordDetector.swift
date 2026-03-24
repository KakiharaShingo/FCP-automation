import Foundation

class FillerWordDetector {
    let fillerWords: [String]
    let paddingMs: Int

    init(fillerWords: [String]? = nil, paddingMs: Int = 100) {
        self.fillerWords = fillerWords ?? ProjectSettings.default.fillerWords
        self.paddingMs = paddingMs
    }

    func detect(in transcription: TranscriptionResult) -> [AudioSegment] {
        var segments: [AudioSegment] = []

        for segment in transcription.segments {
            let detected = detectInSegment(segment)
            segments.append(contentsOf: detected)
        }

        return segments
    }

    private func detectInSegment(_ segment: TranscriptionSegment) -> [AudioSegment] {
        var results: [AudioSegment] = []
        let text = segment.text

        for fillerWord in fillerWords {
            var searchRange = text.startIndex..<text.endIndex

            while let range = text.range(of: fillerWord, range: searchRange) {
                // テキスト内の位置比率からタイムスタンプを推定
                let startFraction = Double(text.distance(from: text.startIndex, to: range.lowerBound))
                    / Double(text.count)
                let endFraction = Double(text.distance(from: text.startIndex, to: range.upperBound))
                    / Double(text.count)

                let segmentDuration = segment.endTime - segment.startTime
                let startTime = segment.startTime + segmentDuration * startFraction
                let endTime = segment.startTime + segmentDuration * endFraction

                // 前後のパディングを含む（他の発話にかぶらないよう制限）
                let padding = Double(paddingMs) / 1000.0
                let paddedStart = max(segment.startTime, startTime - padding)
                let paddedEnd = min(segment.endTime, endTime + padding)

                // 前後にテキストがある場合のみフィラーワードとして検出
                // （単語そのものが文の主要部分でないことを確認）
                let isStandalone = isFillerStandalone(text: text, range: range)

                if isStandalone {
                    results.append(AudioSegment(
                        startTime: paddedStart,
                        endTime: paddedEnd,
                        type: .fillerWord,
                        label: fillerWord
                    ))
                }

                searchRange = range.upperBound..<text.endIndex
            }
        }

        return mergeOverlapping(results)
    }

    private func isFillerStandalone(text: String, range: Range<String.Index>) -> Bool {
        // セグメント全体がフィラーワードのみの場合
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = String(text[range])
        if trimmed == matched { return true }

        // フィラーワードの前後が空白/句読点/文頭/文末かチェック
        let beforeOK: Bool
        if range.lowerBound == text.startIndex {
            beforeOK = true
        } else {
            let prevChar = text[text.index(before: range.lowerBound)]
            beforeOK = prevChar.isWhitespace || "、。,.!?　".contains(prevChar)
        }

        let afterOK: Bool
        if range.upperBound == text.endIndex {
            afterOK = true
        } else {
            let nextChar = text[range.upperBound]
            afterOK = nextChar.isWhitespace || "、。,.!?　".contains(nextChar)
        }

        return beforeOK || afterOK
    }

    private func mergeOverlapping(_ segments: [AudioSegment]) -> [AudioSegment] {
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var merged: [AudioSegment] = []

        for segment in sorted {
            if let last = merged.last, segment.startTime <= last.endTime {
                // 重複区間をマージ
                let mergedEnd = max(last.endTime, segment.endTime)
                let label = last.label.contains(segment.label) ? last.label : "\(last.label), \(segment.label)"
                merged[merged.count - 1] = AudioSegment(
                    startTime: last.startTime,
                    endTime: mergedEnd,
                    type: .fillerWord,
                    label: label
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
    }
}
