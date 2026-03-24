//
//  FCP_automationTests.swift
//  FCP-automationTests
//
//  Created by 垣原親伍 on 2026/03/14.
//

import XCTest
@testable import FCP_automation

final class FCP_automationTests: XCTestCase {

    // MARK: - ProjectClip.isBRoll

    func testIsBRoll_pendingTranscription_returnsFalse() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.pipelineState.transcription = .pending
        XCTAssertFalse(clip.isBRoll)
    }

    func testIsBRoll_completedWithNilTranscription_returnsTrue() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.pipelineState.transcription = .completed
        clip.transcriptionResult = nil
        XCTAssertTrue(clip.isBRoll)
    }

    func testIsBRoll_completedWithEmptySegments_returnsTrue() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.pipelineState.transcription = .completed
        clip.transcriptionResult = TranscriptionResult(segments: [], language: "ja", duration: 10)
        XCTAssertTrue(clip.isBRoll)
    }

    func testIsBRoll_completedWithShortText_returnsTrue() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.pipelineState.transcription = .completed
        clip.transcriptionResult = TranscriptionResult(
            segments: [TranscriptionSegment(startTime: 0, endTime: 1, text: "あ")],
            language: "ja", duration: 10
        )
        XCTAssertTrue(clip.isBRoll)
    }

    func testIsBRoll_completedWithNormalText_returnsFalse() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.pipelineState.transcription = .completed
        clip.transcriptionResult = TranscriptionResult(
            segments: [TranscriptionSegment(startTime: 0, endTime: 5, text: "こんにちは、今日は天気がいいですね")],
            language: "ja", duration: 10
        )
        XCTAssertFalse(clip.isBRoll)
    }

    // MARK: - WhisperService.filterHallucinations

    func testFilterHallucinations_removesRepeatedPatterns() {
        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 5, text: "JR東日本E233系電車"),
        ]
        let filtered = WhisperService.filterHallucinations(segments)
        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilterHallucinations_removesStockPhrases() {
        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 5, text: "ご視聴ありがとうございました。"),
        ]
        let filtered = WhisperService.filterHallucinations(segments)
        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilterHallucinations_keepsNormalText() {
        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 5, text: "今日は東京駅周辺を散歩しながら、おいしいランチを探します。"),
        ]
        let filtered = WhisperService.filterHallucinations(segments)
        XCTAssertEqual(filtered.count, 1)
    }

    func testFilterHallucinations_removesExcessiveRepetition() {
        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 10, text: "高尾駅は高尾駅で、高尾駅から高尾駅まで行くことができます。"),
        ]
        let filtered = WhisperService.filterHallucinations(segments)
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - TimelineCalculator

    func testTimelineCalculator_emptyAnalysis() {
        let analysis = StoryAnalysis(
            clipOrder: [], chapters: [], keptSections: [], removedSections: [], summary: "test"
        )
        let segments = TimelineCalculator.buildTimelineSegments(analysis: analysis, clips: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testTimelineCalculator_singleSection() {
        var clip = ProjectClip(fileURL: URL(fileURLWithPath: "/tmp/test.mov"))
        clip.duration = 30.0
        clip.pipelineState.transcription = .completed

        let analysis = StoryAnalysis(
            clipOrder: [0],
            chapters: [StoryChapter(title: "Intro", description: "")],
            keptSections: [KeptSection(clipIndex: 0, startTime: 5.0, endTime: 25.0, orderIndex: 0, reason: "test")],
            removedSections: [],
            summary: "test"
        )

        let segments = TimelineCalculator.buildTimelineSegments(analysis: analysis, clips: [clip])
        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments[0].sourceStart, 5.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].sourceEnd, 25.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].timelineStart, 0.0, accuracy: 0.001)
    }

    // MARK: - ExportSettings Defaults

    func testExportSettings_defaults() {
        let settings = ExportSettings.default
        XCTAssertEqual(settings.exportMode, .fcpxml)
        XCTAssertTrue(settings.generateSRT)
        XCTAssertTrue(settings.applyVolumeNormalization)
        XCTAssertNil(settings.bgmFileURL)
        XCTAssertFalse(settings.burnInSubtitles)
        XCTAssertFalse(settings.uploadToYouTube)
    }

    // MARK: - YouTubeUploadMetadata

    func testUploadMetadata_apiJSON() {
        let metadata = YouTubeUploadMetadata(title: "Test Video", description: "A test", tags: ["test", "video"])
        let json = metadata.apiJSON()
        let snippet = json["snippet"] as? [String: Any]
        XCTAssertEqual(snippet?["title"] as? String, "Test Video")
        XCTAssertEqual((snippet?["tags"] as? [String])?.count, 2)
    }

    func testUploadMetadata_fromYouTubeMetadata() {
        let ytMeta = YouTubeMetadata(
            title: "My Video",
            description: "Great video",
            tags: ["vlog", "travel"],
            chapters: [YouTubeMetadata.ChapterEntry(timestamp: "0:00", title: "Intro")]
        )
        let upload = YouTubeUploadMetadata(from: ytMeta, privacyStatus: .unlisted)
        XCTAssertEqual(upload.title, "My Video")
        XCTAssertEqual(upload.privacyStatus, .unlisted)
        XCTAssertTrue(upload.description.contains("Great video"))
    }

    // MARK: - StoryAnalysis Validation

    func testStoryAnalysis_validatesClipIndices() {
        let analysis = StoryAnalysis(
            clipOrder: [0, 1, 99],
            chapters: [],
            keptSections: [
                KeptSection(clipIndex: 0, startTime: 0, endTime: 10, orderIndex: 0, reason: "test"),
                KeptSection(clipIndex: 99, startTime: 0, endTime: 5, orderIndex: 1, reason: "invalid"),
            ],
            removedSections: [],
            summary: "test"
        )
        let validated = analysis.validated(clipCount: 2, clipDurations: [30.0, 20.0])
        XCTAssertFalse(validated.clipOrder.contains(99))
        XCTAssertTrue(validated.keptSections.allSatisfy { $0.clipIndex < 2 })
    }
}
