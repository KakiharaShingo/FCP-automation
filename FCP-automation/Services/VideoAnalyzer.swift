import Foundation
import AVFoundation
import Vision
import AppKit

class VideoAnalyzer {

    func analyze(fileURL: URL) async -> TimelineItem? {
        let asset = AVURLAsset(url: fileURL)
        var metadata = ClipMetadata()

        // 基本メタデータ取得
        do {
            let duration = try await CMTimeGetSeconds(asset.load(.duration))
            let tracks = try await asset.loadTracks(withMediaType: .video)

            if let videoTrack = tracks.first {
                let size = try await videoTrack.load(.naturalSize)
                let fps = try await videoTrack.load(.nominalFrameRate)
                metadata.width = Int(size.width)
                metadata.height = Int(size.height)
                metadata.fps = Double(fps)
                metadata.hasVideo = true
            } else {
                metadata.hasVideo = false
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            metadata.hasAudio = !audioTracks.isEmpty

            // ファイルサイズ
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                metadata.fileSize = size
            }

            // クリップタイプを自動判定
            let clipType = await classifyClip(asset: asset, metadata: metadata)

            return TimelineItem(
                fileName: fileURL.lastPathComponent,
                fileURL: fileURL,
                startTime: 0,
                duration: duration,
                trackIndex: 0,
                clipType: clipType,
                metadata: metadata
            )
        } catch {
            return nil
        }
    }

    // MARK: - Clip Classification

    private func classifyClip(asset: AVURLAsset, metadata: ClipMetadata) async -> TimelineItem.ClipType {
        // 音声のみ → オーディオ
        if !metadata.hasVideo {
            return .audio
        }

        // サムネイル画像で人物検出
        let hasPerson = await detectPerson(in: asset)

        // 長い動画で人物あり → メイン
        let duration = CMTimeGetSeconds(asset.duration)
        if duration > 60 && hasPerson {
            return .main
        }

        // 短い動画 → インサート
        if duration < 10 {
            return .insert
        }

        // それ以外 → Bロール
        if !hasPerson {
            return .bRoll
        }

        return .main
    }

    private func detectPerson(in asset: AVURLAsset) async -> Bool {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        // 動画の中間地点のサムネイルを取得
        let duration = CMTimeGetSeconds(asset.duration)
        let midTime = CMTime(seconds: duration / 2, preferredTimescale: 600)

        do {
            let (image, _) = try await generator.image(at: midTime)
            let ciImage = CIImage(cgImage: image)

            return try await withCheckedThrowingContinuation { continuation in
                let request = VNDetectHumanRectanglesRequest { request, error in
                    if let error = error {
                        continuation.resume(returning: false)
                        return
                    }
                    let results = request.results as? [VNHumanObservation] ?? []
                    continuation.resume(returning: !results.isEmpty)
                }

                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: false)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - Batch Analysis

    func analyzeMultiple(fileURLs: [URL]) async -> [TimelineItem] {
        var items: [TimelineItem] = []

        for url in fileURLs {
            if let item = await analyze(fileURL: url) {
                items.append(item)
            }
        }

        // メインクリップを先に配置し、Bロール/インサートを後に配置
        return arrangeOnTimeline(items: items)
    }

    // MARK: - Thumbnail Extraction

    struct ThumbnailCandidate: Identifiable {
        let id = UUID()
        let image: NSImage
        let time: TimeInterval
        let clipIndex: Int
        let score: Double  // 0.0-1.0
        let reason: String // "人物あり", "表情豊か" etc.
    }

    /// 動画から良いサムネイル候補を抽出
    func extractThumbnailCandidates(clips: [ProjectClip], maxCandidates: Int = 6) async -> [ThumbnailCandidate] {
        var candidates: [ThumbnailCandidate] = []

        for (clipIdx, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 720)

            // サンプリングポイント: 10%, 25%, 40%, 50%, 60%, 75%, 90% の位置
            let samplePoints: [Double] = [0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9]

            for fraction in samplePoints {
                let time = CMTime(seconds: clip.duration * fraction, preferredTimescale: 600)
                do {
                    let (cgImage, _) = try await generator.image(at: time)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    let ciImage = CIImage(cgImage: cgImage)

                    // Vision で顔検出
                    let (hasFace, faceCount) = await detectFaces(in: ciImage)

                    var score = 0.3  // ベーススコア
                    var reasons: [String] = []

                    if hasFace {
                        score += 0.4
                        reasons.append("人物あり(\(faceCount)人)")
                    }

                    // 中央付近のフレームは少し加点（見栄えが良い傾向）
                    if fraction >= 0.3 && fraction <= 0.7 {
                        score += 0.1
                        reasons.append("中盤")
                    }

                    // 画像の明るさチェック（暗すぎ/明るすぎは減点）
                    let brightness = averageBrightness(cgImage: cgImage)
                    if brightness > 0.2 && brightness < 0.8 {
                        score += 0.1
                        reasons.append("適正露出")
                    } else {
                        score -= 0.1
                    }

                    candidates.append(ThumbnailCandidate(
                        image: nsImage,
                        time: clip.duration * fraction,
                        clipIndex: clipIdx,
                        score: min(1.0, max(0.0, score)),
                        reason: reasons.isEmpty ? "候補" : reasons.joined(separator: ", ")
                    ))
                } catch {
                    continue
                }
            }
        }

        // スコア順でソートして上位を返す
        return Array(candidates.sorted { $0.score > $1.score }.prefix(maxCandidates))
    }

    private func detectFaces(in ciImage: CIImage) async -> (hasFace: Bool, count: Int) {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, _ in
                let results = request.results as? [VNFaceObservation] ?? []
                continuation.resume(returning: (!results.isEmpty, results.count))
            }
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            try? handler.perform([request])
        }
    }

    private func averageBrightness(cgImage: CGImage) -> Double {
        let width = min(cgImage.width, 100)  // リサイズして軽量化
        let height = min(cgImage.height, 100)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0.5 }

        let pointer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var totalBrightness: Double = 0
        let pixelCount = width * height
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(pointer[offset])
            let g = Double(pointer[offset + 1])
            let b = Double(pointer[offset + 2])
            totalBrightness += (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
        }
        return totalBrightness / Double(pixelCount)
    }

    private func arrangeOnTimeline(items: [TimelineItem]) -> [TimelineItem] {
        var arranged: [TimelineItem] = []
        var mainOffset: TimeInterval = 0

        // メインクリップを順番に配置
        let mainClips = items.filter { $0.clipType == .main }
        for var clip in mainClips {
            clip.startTime = mainOffset
            clip.trackIndex = 0
            arranged.append(clip)
            mainOffset += clip.duration
        }

        // Bロール/インサートを上のトラックに配置
        var bRollOffset: TimeInterval = 0
        let otherClips = items.filter { $0.clipType != .main && $0.clipType != .audio }
        for var clip in otherClips {
            clip.startTime = bRollOffset
            clip.trackIndex = 1
            arranged.append(clip)
            bRollOffset += clip.duration
        }

        // オーディオを下のトラックに
        var audioOffset: TimeInterval = 0
        let audioClips = items.filter { $0.clipType == .audio }
        for var clip in audioClips {
            clip.startTime = audioOffset
            clip.trackIndex = -1
            arranged.append(clip)
            audioOffset += clip.duration
        }

        return arranged
    }
}
