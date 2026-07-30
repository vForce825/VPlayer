// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackMetricsTests: XCTestCase {
    func testMetricsSnapshotTracksBoundedQueuesRatesAndRequiredCounters() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "https://secret.example/live?token=do-not-export",
            now: { clock.value },
            residentMemoryProvider: { 123_456 }
        )
        let generation = MediaGeneration(rawValue: 7)
        let top = ResolvedFieldOrder(
            parity: .top,
            confidence: .signaled,
            source: .parser
        )
        metrics.update(scanType: .interlaced(top))
        metrics.update(activeRoute: .metalYADIF2x)
        metrics.updateReadinessDiagnostics(
            audioRoute: .ffmpegPCM,
            audioReady: true,
            readinessOpen: false,
            retainedAudioCount: 48,
            retainedVideoCount: 2,
            audioFirstPTS: CMTime(value: 100, timescale: 10),
            audioDuration: CMTime(value: 15, timescale: 10),
            videoFirstPTS: CMTime(value: 103, timescale: 10)
        )

        for second in 1...60 {
            clock.value = TimeInterval(second)
            metrics.recordDecoderCallback()
            if second.isMultiple(of: 2) {
                let presentationTime = CMTime(seconds: TimeInterval(second), preferredTimescale: 1_000)
                metrics.recordPresentationCompletion(
                    generation: generation,
                    activeGeneration: generation,
                    isUniquePresentation: true,
                    presentationTimeStamp: presentationTime,
                    targetMediaTime: CMTimeAdd(
                        presentationTime,
                        CMTime(value: Int64(second % 20 + 1), timescale: 1_000)
                    )
                )
                metrics.recordVideoDrop(count: second == 60 ? 2 : 0, source: .presentationExpired)
                metrics.recordPresentationQueueDepth(min(12, second))
            }
        }
        for duration in 1...20 {
            metrics.recordYADIFKernelDispatch(inFlightCount: min(3, duration), inputDepth: min(4, duration))
            metrics.recordGPUDuration(milliseconds: Double(duration))
            metrics.recordYADIFCPUEncode(milliseconds: Double(duration) / 10)
            metrics.recordRenderCPUPreparation(milliseconds: Double(duration) / 20)
        }
        metrics.recordStaleGenerationDrop()
        metrics.recordVideoDrop(count: 1, source: .deinterlaceQueueFull)
        metrics.recordDemuxPacket()
        metrics.recordDemuxPacket()
        metrics.recordVideoAccessUnit()
        metrics.recordAudioSample()
        metrics.recordAudioSample()
        metrics.recordAudioSample()
        metrics.recordVideoDecodeSubmission(milliseconds: 2.5)
        metrics.recordVideoDecodeSubmission(milliseconds: 7.5)

        clock.value = 60
        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.scanType, "interlaced")
        XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
        XCTAssertEqual(snapshot.elapsedSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentationsPerSecond, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 30)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 20)
        XCTAssertEqual(snapshot.staleGenerationDropCount, 1)
        XCTAssertEqual(snapshot.droppedVideoFrames, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 19, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 1.9, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.renderCPUPreparationP95Milliseconds, 0.95, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(snapshot.avDriftP95Milliseconds, 20)
        XCTAssertLessThanOrEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 20)
        XCTAssertEqual(snapshot.residentMemoryBytes, 123_456)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
        XCTAssertEqual(snapshot.audioRoute, "ffmpegPCM")
        XCTAssertTrue(snapshot.audioReady)
        XCTAssertFalse(snapshot.readinessOpen)
        XCTAssertEqual(snapshot.retainedAudioCount, 48)
        XCTAssertEqual(snapshot.retainedVideoCount, 2)
        XCTAssertEqual(snapshot.audioFirstPTSSeconds, 10)
        XCTAssertEqual(snapshot.audioDurationSeconds, 1.5)
        XCTAssertEqual(snapshot.videoFirstPTSSeconds, 10.3)
        XCTAssertEqual(snapshot.demuxPacketCount, 2)
        XCTAssertEqual(snapshot.videoAccessUnitCount, 1)
        XCTAssertEqual(snapshot.audioSampleCount, 3)
        XCTAssertEqual(snapshot.videoDecodeSubmissionCount, 2)
        XCTAssertEqual(snapshot.maximumVideoDecodeSubmissionMilliseconds, 7.5)
    }

    // A 50 Hz panel presenting every frame and a 60 Hz panel losing one tick in
    // six produce the same callback rate, and only the native period tells them
    // apart.
    func testDisplayLinkCadenceReportsTheNativePeriodAndCountsOnlyWholeMissedVSyncs() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let period = 1.0 / 60
        var timestamp = 100.0
        for step in [1, 1, 2, 1, 3, 1] {
            metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
            timestamp += period * Double(step)
        }
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        // A stall is not a cadence: folding it in would bury the single-vsync
        // gaps this counter exists to find.
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp + 5)

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.displayLinkCallbackCount, 8)
        XCTAssertEqual(snapshot.nativeDisplayIntervalMilliseconds, period * 1_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.missedDisplayLinkVSyncCount, 3)
    }

    // The shortest gap ever seen reads short of the true period, so one outlier
    // would rescale every later gap into a miss. The screen's own rate does not.
    func testReportedRefreshRateRatherThanTheShortestGapDecidesWhatCountsAsAMiss() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        metrics.recordDisplayRefreshRate(framesPerSecond: 60)
        var timestamp = 100.0
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        // An early outlier three quarters of a period long.
        timestamp += 0.75 / 60
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        for _ in 0..<4 {
            timestamp += 1.0 / 60
            metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        }

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.displayRefreshHz, 60)
        XCTAssertLessThan(snapshot.nativeDisplayIntervalMilliseconds, 1_000 / 60)
        XCTAssertEqual(snapshot.missedDisplayLinkVSyncCount, 0)
    }

    func testWindowedRatesAndPercentilesExcludeOldSamplesWithoutResettingSessionTotals() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 99)
        metrics.recordYADIFCPUEncode(milliseconds: 88)
        metrics.recordRenderCPUPreparation(milliseconds: 77)
        clock.value = 120
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 4)
        metrics.recordYADIFCPUEncode(milliseconds: 3)
        metrics.recordRenderCPUPreparation(milliseconds: 2)
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: MediaGeneration(rawValue: 2),
            isUniquePresentation: true,
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 9, timescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentationsPerSecond, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.renderCPUPreparationP95Milliseconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 0)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 1)
    }

    func testFiveSecondReanchorGraceExcludesTransientDrift() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        clock.value = 10
        metrics.beginAVDriftGracePeriod(seconds: 5)
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: generation,
            isUniquePresentation: true,
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 900, timescale: 1_000)
        )
        clock.value = 15
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: generation,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(value: 15_000, timescale: 1_000),
            targetMediaTime: CMTime(value: 15_025, timescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.avDriftP95Milliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 2)
    }

    func testUniquePresentationPTSRegressionIsCountedWithinOneGeneration() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let generation = MediaGeneration(rawValue: 1)

        for pts in [10.0, 10.04, 9.0] {
            let time = CMTime(seconds: pts, preferredTimescale: 1_000)
            metrics.recordPresentationCompletion(
                generation: generation,
                activeGeneration: generation,
                isUniquePresentation: true,
                presentationTimeStamp: time,
                targetMediaTime: time
            )
        }

        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).presentationPTSRegressionCount,
            1
        )
    }

    func testUniquePresentationPTSRegressionSurvivesDecoderGenerationChange() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)

        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 10, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 9, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 9, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: secondGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 1, preferredTimescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.presentationPTSRegressionCount, 1)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 1)
    }

    func testExplicitTimelineResetAllowsAnEarlierPTSWithoutErasingEvidence() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)

        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 10, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 9, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 9, preferredTimescale: 1_000)
        )
        metrics.resetPresentationTimeline()
        metrics.recordPresentationCompletion(
            generation: secondGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 1, preferredTimescale: 1_000)
        )

        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).presentationPTSRegressionCount,
            1
        )
    }

    func testSnapshotNeverClaimsAWindowLongerThanItsRetainedHistory() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        clock.value = 300

        let snapshot = metrics.snapshot(window: .seconds(300))

        XCTAssertEqual(snapshot.windowDurationSeconds, 120, accuracy: 0.000_001)
    }

    func testCollectorIsThreadSafeAcrossRealCallbackLanes() {
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 4)

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            metrics.recordDecoderCallback()
            metrics.recordYADIFKernelDispatch(
                inFlightCount: index % 4,
                inputDepth: index % 5
            )
            metrics.recordPresentationCompletion(
                generation: generation,
                activeGeneration: generation,
                isUniquePresentation: true,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 1_000),
                targetMediaTime: CMTime(value: Int64(index + 1), timescale: 1_000)
            )
            metrics.recordPresentationQueueDepth(index % 13)
        }

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.presentedVideoFrames, 1_000)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 1_000)
        XCTAssertEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertEqual(snapshot.maximumYADIFInputDepth, 4)
    }

    func testSnapshotJSONAndSignpostChannelIdentifierAreIrreversiblyRedacted() throws {
        let secret = "五星体育 HD https://iptv.router/live?token=secret"
        let metrics = PlaybackMetrics(
            channelID: secret,
            now: { 1 },
            residentMemoryProvider: { 42 }
        )
        let encoded = try JSONEncoder().encode(metrics.snapshot(window: .seconds(60)))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let identifier = PlaybackDiagnosticsChannelID(rawValue: secret)

        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("iptv.router"))
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(identifier.value.contains("五星体育"))
        XCTAssertFalse(identifier.value.contains("iptv.router"))
        XCTAssertEqual(identifier.value.count, 12)
        XCTAssertTrue(identifier.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testSignpostLifetimeFinishesExactlyOnceIncludingDeinitFallback() {
        let recorder = SignpostFinishRecorder()
        var lifetime: PlaybackSignpostLifetime? = PlaybackSignpostLifetime {
            recorder.record()
        }
        lifetime?.finish()
        lifetime?.finish()
        lifetime = nil
        XCTAssertEqual(recorder.count, 1)

        var fallback: PlaybackSignpostLifetime? = PlaybackSignpostLifetime {
            recorder.record()
        }
        XCTAssertNotNil(fallback)
        fallback = nil
        XCTAssertEqual(recorder.count, 2)
    }

    func testSignpostCorrelationIsHashedAndBounded() {
        let identifier = PlaybackDiagnosticsChannelID(rawValue: "channel")
        let correlation = PlaybackDiagnosticsCorrelationID(
            channelIdentifier: identifier,
            rawValue: 12_345_678_901_234_567_890
        )

        XCTAssertEqual(correlation.value.count, 12)
        XCTAssertFalse(correlation.value.contains("12345678901234567890"))
        XCTAssertTrue(correlation.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

private final class MetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class SignpostFinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.withLock { storage } }
    func record() { lock.withLock { storage += 1 } }
}
