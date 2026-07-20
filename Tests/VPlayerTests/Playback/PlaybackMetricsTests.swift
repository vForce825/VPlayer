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
            selectedAlgorithm: .metalYADIF2x,
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

        for second in 1...60 {
            clock.value = TimeInterval(second)
            metrics.recordDecoderCallback()
            if second.isMultiple(of: 2) {
                let presentationTime = CMTime(seconds: TimeInterval(second), preferredTimescale: 1_000)
                metrics.recordPresentation(
                    generation: generation,
                    activeGeneration: generation,
                    presentationTimeStamp: presentationTime,
                    targetMediaTime: CMTimeAdd(
                        presentationTime,
                        CMTime(value: Int64(second % 20 + 1), timescale: 1_000)
                    ),
                    droppedFrames: second == 60 ? 2 : 0,
                    presentationQueueDepth: min(12, second)
                )
            }
        }
        for duration in 1...20 {
            metrics.recordYADIFKernelDispatch(inFlightCount: min(3, duration), inputDepth: min(4, duration))
            metrics.recordGPUDuration(milliseconds: Double(duration))
        }
        metrics.recordTemporalPropertySet(count: 2)
        metrics.recordTemporalDecodeFlag()
        metrics.recordStaleGenerationDrop()
        metrics.recordVideoDrop(count: 1)
        metrics.recordTemporalUnavailableNotice()

        clock.value = 60
        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.scanType, "interlaced")
        XCTAssertEqual(snapshot.selectedAlgorithm, .metalYADIF2x)
        XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
        XCTAssertEqual(snapshot.elapsedSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentationsPerSecond, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 30)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 20)
        XCTAssertEqual(snapshot.temporalPropertySetCount, 2)
        XCTAssertEqual(snapshot.temporalDecodeFlagCount, 1)
        XCTAssertEqual(snapshot.staleGenerationDropCount, 1)
        XCTAssertEqual(snapshot.droppedVideoFrames, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 19, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(snapshot.avDriftP95Milliseconds, 20)
        XCTAssertLessThanOrEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 20)
        XCTAssertEqual(snapshot.residentMemoryBytes, 123_456)
        XCTAssertEqual(snapshot.temporalUnavailableNoticeCount, 1)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
        XCTAssertEqual(snapshot.automaticAlgorithmSwitchCount, 0)
    }

    func testWindowedRatesAndPercentilesExcludeOldSamplesWithoutResettingSessionTotals() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            selectedAlgorithm: .appleTemporal,
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 99)
        clock.value = 120
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 4)
        metrics.recordPresentation(
            generation: generation,
            activeGeneration: MediaGeneration(rawValue: 2),
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 9, timescale: 1_000),
            droppedFrames: 0,
            presentationQueueDepth: 1
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentationsPerSecond, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 1)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 1)
    }

    func testFiveSecondReanchorGraceExcludesTransientDrift() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            selectedAlgorithm: .appleTemporal,
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        clock.value = 10
        metrics.beginAVDriftGracePeriod(seconds: 5)
        metrics.recordPresentation(
            generation: generation,
            activeGeneration: generation,
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 900, timescale: 1_000),
            droppedFrames: 0,
            presentationQueueDepth: 1
        )
        clock.value = 15
        metrics.recordPresentation(
            generation: generation,
            activeGeneration: generation,
            presentationTimeStamp: CMTime(value: 15_000, timescale: 1_000),
            targetMediaTime: CMTime(value: 15_025, timescale: 1_000),
            droppedFrames: 0,
            presentationQueueDepth: 1
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.avDriftP95Milliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 2)
    }

    func testSnapshotNeverClaimsAWindowLongerThanItsRetainedHistory() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            selectedAlgorithm: .appleTemporal,
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
            selectedAlgorithm: .metalYADIF2x,
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
            metrics.recordPresentation(
                generation: generation,
                activeGeneration: generation,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 1_000),
                targetMediaTime: CMTime(value: Int64(index + 1), timescale: 1_000),
                droppedFrames: 0,
                presentationQueueDepth: index % 13
            )
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
            selectedAlgorithm: .appleTemporal,
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
}

private final class MetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
