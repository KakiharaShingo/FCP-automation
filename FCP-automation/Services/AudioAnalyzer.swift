import Foundation
import AVFoundation
import Accelerate

class AudioAnalyzer {

    /// AVAudioFileが対応する拡張子
    private static let directAudioExtensions: Set<String> = [
        "wav", "aif", "aiff", "caf", "m4a", "aac", "mp3", "flac", "alac"
    ]

    func detectSilence(in fileURL: URL, thresholdDB: Float = -40.0, minimumDuration: TimeInterval = 0.5) async -> [AudioSegment] {
        let ext = fileURL.pathExtension.lowercased()

        // AVAudioFileが対応しない拡張子（動画等）は直接AVAssetReader経由で処理
        guard Self.directAudioExtensions.contains(ext) else {
            print("[AudioAnalyzer] 動画ファイル検出 (.\(ext)) — AVAssetReader経由で処理: \(fileURL.lastPathComponent)")
            return await detectSilenceFromVideo(fileURL: fileURL, thresholdDB: thresholdDB, minimumDuration: minimumDuration)
        }

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            return analyzeAudioFile(audioFile, thresholdDB: thresholdDB, minimumDuration: minimumDuration)
        } catch {
            print("[AudioAnalyzer] AVAudioFileオープン失敗 (.\(ext)): \(error.localizedDescription) — AVAssetReader経由にフォールバック: \(fileURL.lastPathComponent)")
            return await detectSilenceFromVideo(fileURL: fileURL, thresholdDB: thresholdDB, minimumDuration: minimumDuration)
        }
    }

    private func detectSilenceFromVideo(fileURL: URL, thresholdDB: Float, minimumDuration: TimeInterval) async -> [AudioSegment] {
        let asset = AVURLAsset(url: fileURL)
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("[AudioAnalyzer] AVAssetReader作成失敗: \(fileURL.lastPathComponent)")
            return []
        }
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            print("[AudioAnalyzer] 音声トラックなし: \(fileURL.lastPathComponent)")
            return []
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        var allSamples: [Float] = []
        let sampleRate: Double = 16000

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }

            // Int16 → Float 変換（中間配列なしで直接変換）
            let int16Count = length / 2
            data.withUnsafeBytes { ptr in
                guard let base = ptr.bindMemory(to: Int16.self).baseAddress else { return }
                let scale = 1.0 / Float(Int16.max)
                allSamples.reserveCapacity(allSamples.count + int16Count)
                for i in 0..<int16Count {
                    allSamples.append(Float(base[i]) * scale)
                }
            }
        }

        return findSilentSegments(samples: allSamples, sampleRate: sampleRate,
                                   thresholdDB: thresholdDB, minimumDuration: minimumDuration)
    }

    private func analyzeAudioFile(_ audioFile: AVAudioFile, thresholdDB: Float, minimumDuration: TimeInterval) -> [AudioSegment] {
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        return findSilentSegments(samples: samples, sampleRate: sampleRate,
                                   thresholdDB: thresholdDB, minimumDuration: minimumDuration)
    }

    private func findSilentSegments(samples: [Float], sampleRate: Double,
                                     thresholdDB: Float, minimumDuration: TimeInterval) -> [AudioSegment] {
        let thresholdLinear = powf(10.0, thresholdDB / 20.0)
        let windowSize = Int(sampleRate * 0.02) // 20ms window
        let hopSize = windowSize / 2

        var segments: [AudioSegment] = []
        var silenceStart: TimeInterval?

        var i = 0
        while i < samples.count - windowSize {
            let window = Array(samples[i..<(i + windowSize)])
            let rms = calculateRMS(window)

            let currentTime = Double(i) / sampleRate

            if rms < thresholdLinear {
                if silenceStart == nil {
                    silenceStart = currentTime
                }
            } else {
                if let start = silenceStart {
                    let duration = currentTime - start
                    if duration >= minimumDuration {
                        segments.append(AudioSegment(
                            startTime: start,
                            endTime: currentTime,
                            type: .silence,
                            label: String(format: "%.1f秒の無音", duration)
                        ))
                    }
                    silenceStart = nil
                }
            }

            i += hopSize
        }

        // 末尾の無音を処理
        if let start = silenceStart {
            let endTime = Double(samples.count) / sampleRate
            let duration = endTime - start
            if duration >= minimumDuration {
                segments.append(AudioSegment(
                    startTime: start,
                    endTime: endTime,
                    type: .silence,
                    label: String(format: "%.1f秒の無音", duration)
                ))
            }
        }

        return segments
    }

    private func calculateRMS(_ samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        vDSP_svesq(samples, 1, &sumOfSquares, vDSP_Length(samples.count))
        return sqrtf(sumOfSquares / Float(samples.count))
    }

    // MARK: - Volume Level Analysis

    struct ClipVolumeInfo {
        let averageDB: Float    // 平均音量 (dB)
        let peakDB: Float       // ピーク音量 (dB)
        let gainAdjustment: Float  // ノーマライズに必要なゲイン調整 (dB)
    }

    /// クリップの平均音量とピーク音量を測定
    func measureVolume(fileURL: URL) async -> ClipVolumeInfo? {
        let asset = AVURLAsset(url: fileURL)
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("[AudioAnalyzer] 音量測定: AVAssetReader作成失敗: \(fileURL.lastPathComponent)")
            return nil
        }
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            print("[AudioAnalyzer] 音量測定: 音声トラックなし: \(fileURL.lastPathComponent)")
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        var sumSquared: Double = 0
        var peakAmplitude: Float = 0
        var sampleCount: Int = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let data = dataPointer else { continue }
            let int16Ptr = data.withMemoryRebound(to: Int16.self, capacity: length / 2) { $0 }
            let count = length / 2

            for i in 0..<count {
                let sample = Float(int16Ptr[i]) / Float(Int16.max)
                let absSample = abs(sample)
                sumSquared += Double(sample * sample)
                if absSample > peakAmplitude {
                    peakAmplitude = absSample
                }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }

        let rms = sqrt(sumSquared / Double(sampleCount))
        let averageDB = 20.0 * log10(max(rms, 1e-10))
        let peakDB = 20.0 * log10(max(Double(peakAmplitude), 1e-10))

        // ターゲット音量: -16 dB (YouTube推奨のラウドネス)
        let targetDB: Float = -16.0
        let gainAdjustment = targetDB - Float(averageDB)
        // ゲイン調整を -12dB ~ +12dB にクランプ
        let clampedGain = max(-12.0, min(12.0, gainAdjustment))

        return ClipVolumeInfo(
            averageDB: Float(averageDB),
            peakDB: Float(peakDB),
            gainAdjustment: clampedGain
        )
    }
}
