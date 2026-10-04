// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class SystemVideoOutputTests: XCTestCase {
    func testNaturalEOFDrainWaitsForPhysicalTailAcceptanceWithoutFlushing() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()
        XCTAssertFalse(harness.output.isDrainedForNaturalEOF)
        XCTAssertEqual(backend.flushCount, 0)
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertTrue(harness.output.isDrainedForNaturalEOF)
        XCTAssertEqual(backend.flushCount, 0)
    }

    func testCancelledFinalVideoEnqueueCannotCertifyNaturalEOFDrain() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.cancelled)
        harness.output.waitUntilIdleForTesting()
        XCTAssertFalse(harness.output.isDrainedForNaturalEOF)
        XCTAssertEqual(harness.output.naturalEOFDrainFailure, .videoRendererFailed("renderer.enqueue-cancelled"))
    }

    func testCapacityRejectedFinalTailCannotCertifyDrainButLaterAcceptedTailCan() throws {
        let first = try frame(sequence: 1, pts: 1)
        let ledger = VideoSurfaceBudgetLedger(limit: first.estimatedStorageBytes)
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let harness = makeHarness(backend: backend, ledger: ledger)
        harness.output.enqueue(first)
        harness.output.enqueue(try frame(sequence: 2, pts: 2))
        harness.output.waitUntilIdleForTesting()
        backend.ready = true
        backend.fireReadiness()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1])
        XCTAssertFalse(harness.output.isDrainedForNaturalEOF)
        XCTAssertEqual(harness.output.naturalEOFDrainFailure, .videoRendererFailed("renderer.queue-capacity"))
        harness.output.enqueue(try frame(sequence: 3, pts: 3))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1, 3])
        XCTAssertTrue(harness.output.isDrainedForNaturalEOF)
        XCTAssertNil(harness.output.naturalEOFDrainFailure)
    }

    func testLateCancelledOldQueueCannotPoisonReplacementEOFTailReceipt() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()
        harness.output.reset(.init(generation: .init(rawValue: 1), reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 2, pts: 2, generation: .init(rawValue: 1))])) { _ in }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.cancelled)
        harness.output.waitUntilIdleForTesting()
        XCTAssertNil(harness.output.naturalEOFDrainFailure)
        XCTAssertFalse(harness.output.isDrainedForNaturalEOF)
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertTrue(harness.output.isDrainedForNaturalEOF)
        XCTAssertNil(harness.output.naturalEOFDrainFailure)
    }

    func testSupersededPhysicalFlushCannotCertifyResetOrAdmitSeeds() throws {
        let backend = FakeVideoRendererBackend()
        let harness = makeHarness(backend: backend)
        let result = VideoResetResultBox()
        harness.output.reset(.init(generation: .init(rawValue: 1), reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 1, pts: 1, generation: .init(rawValue: 1))])) {
            result.record($0)
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0, settled: false)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(backend.submittedPTS.isEmpty)
    }

    func testLatestResetContinuesAfterOlderPhysicalFlushIsSuperseded() throws {
        let backend = FakeVideoRendererBackend()
        let harness = makeHarness(backend: backend)
        let old = VideoResetResultBox()
        let latest = VideoReceiptBox()
        harness.output.reset(.init(generation: .init(rawValue: 1), reason: .timelineDiscontinuity,
            removeDisplayedImage: false, seedFrames: [])) { old.record($0) }
        harness.output.reset(.init(generation: .init(rawValue: 2), reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 2, pts: 2, generation: .init(rawValue: 2))])) {
            latest.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0, settled: false)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(old.count, 1)
        XCTAssertNotNil(old.error)
        XCTAssertNil(latest.value)
        XCTAssertEqual(backend.flushCount, 2)
        XCTAssertTrue(backend.submittedPTS.isEmpty)
        backend.completeFlush(at: 1)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(latest.value?.generation, .init(rawValue: 2))
        XCTAssertEqual(latest.value?.sequenceNumbers, [2])
    }

    func testSupersededRecoveryFlushFailsReceiptWithoutRetryAdmission() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let ledger = VideoSurfaceBudgetLedger()
        let failures = VideoResetResultBox()
        let receipt = VideoResetResultBox()
        let harness = makeHarness(backend: backend, ledger: ledger,
            failureSink: { error, _ in failures.record(.failure(error)) })
        harness.output.enqueue([try frame(sequence: 1, pts: 1)]) { receipt.record($0) }
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.requiresRecovery(.requiresFlushToResumeDecoding))
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0, settled: false)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(receipt.count, 1)
        XCTAssertNotNil(receipt.error)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(backend.submittedPTS, [1])
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testCapacityEvictedReceiptStillRecoversCurrentFlushRequiredRenderer() throws {
        try verifyRecoveryAfterReceiptCapacityEviction(.requiresFlushToResumeDecoding)
    }

    func testCapacityEvictedReceiptStillRecoversCurrentFailedRenderer() throws {
        try verifyRecoveryAfterReceiptCapacityEviction(.failed(NSError(domain: "Receiver.Evicted", code: -1)))
    }

    private func verifyRecoveryAfterReceiptCapacityEviction(_ reason: VideoRendererBackendEvent) throws {
        let a = try frame(sequence: 1, pts: 1)
        let c = try frame(sequence: 3, pts: 3)
        let b = try frame(sequence: 2, pts: 2)
        let ledger = VideoSurfaceBudgetLedger(limit: a.estimatedStorageBytes * 2)
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        backend.latchesRecoveryUntilFlush = true
        let harness = makeHarness(backend: backend, ledger: ledger)
        let rejected = VideoResetResultBox()
        let survivor = VideoReceiptBox()
        harness.output.enqueue([a, c]) { rejected.record($0) }
        harness.output.waitUntilIdleForTesting()
        harness.output.enqueue([b]) { survivor.value = try? $0.get() }
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(rejected.count, 1)
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(backend.submittedPTS, [1])
        backend.completeEnqueue(.requiresRecovery(reason))
        harness.output.waitUntilIdleForTesting()
        XCTAssertFalse(backend.isReadyForMoreMediaData,
            "The fake models the native latch until physical flush completion")
        XCTAssertEqual(backend.flushCount, 1)
        guard backend.flushCount == 1 else { return }
        XCTAssertEqual(ledger.snapshot.referenceCount, 1, "Rejected A must not be retained/replayed")
        XCTAssertNil(survivor.value)
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.submittedPTS, [1, 2])
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(survivor.value?.sequenceNumbers, [2])
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testFlushRequiredAfterAcceptedPrefixReplaysEntireSeedReceipt() throws {
        try verifyMultiSeedRecovery(.requiresFlushToResumeDecoding, failRetry: false)
    }

    func testNativeErrorAfterAcceptedPrefixReplaysEntireSeedReceipt() throws {
        try verifyMultiSeedRecovery(.failed(NSError(domain: "Receiver.Recoverable", code: -1)),
            failRetry: false)
    }

    func testReacceptedSeedPrefixCannotResetTransactionRetryBudget() throws {
        try verifyMultiSeedRecovery(.requiresFlushToResumeDecoding, failRetry: true)
    }

    private func verifyMultiSeedRecovery(_ reason: VideoRendererBackendEvent,
        failRetry: Bool) throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let ledger = VideoSurfaceBudgetLedger()
        let harness = makeHarness(backend: backend, ledger: ledger)
        let receipt = VideoReceiptBox()
        let finished = VideoResetResultBox()
        harness.output.reset(.init(generation: .init(rawValue: 0), reason: .decoderRecovery,
            removeDisplayedImage: false,
            seedFrames: [try frame(sequence: 1, pts: 1), try frame(sequence: 2, pts: 2)])) {
            receipt.value = try? $0.get()
            finished.record($0)
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.requiresRecovery(reason))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(finished.count, 0)
        XCTAssertEqual(ledger.snapshot.referenceCount, 2,
            "The accepted prefix remains budgeted until its full receipt is settled")
        backend.completeFlush(at: 1)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.submittedPTS, [1, 2, 1])
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.submittedPTS, [1, 2, 1, 2])
        XCTAssertNil(receipt.value)
        XCTAssertEqual(finished.count, 0, "Reaccepted A alone cannot certify flushed B")
        backend.completeEnqueue(failRetry ? .requiresRecovery(reason) : .accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.flushCount, 2, "A replayed prefix cannot buy another retry")
        XCTAssertEqual(finished.count, 1)
        if failRetry {
            XCTAssertNil(receipt.value)
            XCTAssertNotNil(finished.error)
        } else {
            XCTAssertEqual(receipt.value?.sequenceNumbers, [1, 2])
            XCTAssertNil(finished.error)
        }
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testSupersedingSeedRetryReleasesEveryRetainedSurface() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let ledger = VideoSurfaceBudgetLedger()
        let harness = makeHarness(backend: backend, ledger: ledger)
        let finished = VideoResetResultBox()
        harness.output.reset(.init(generation: .init(rawValue: 0), reason: .decoderRecovery,
            removeDisplayedImage: false,
            seedFrames: [try frame(sequence: 1, pts: 1), try frame(sequence: 2, pts: 2)])) {
            finished.record($0)
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.requiresRecovery(.requiresFlushToResumeDecoding))
        harness.output.waitUntilIdleForTesting()
        harness.output.flush(to: .init(rawValue: 1))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(finished.count, 1)
        XCTAssertNotNil(finished.error)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
        backend.completeFlush(at: 1)
        backend.completeFlush(at: 2)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.submittedPTS, [1, 2])
        XCTAssertEqual(finished.count, 1)
    }

    func testSeedRetryFlushTimeoutRejectsEntireReceiptAndReleasesPrefix() async throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let ledger = VideoSurfaceBudgetLedger()
        let harness = makeHarness(backend: backend, ledger: ledger)
        let finished = VideoResetResultBox()
        let timedOut = expectation(description: "multi-seed retry flush timeout")
        harness.output.reset(.init(generation: .init(rawValue: 0), reason: .decoderRecovery,
            removeDisplayedImage: false,
            seedFrames: [try frame(sequence: 1, pts: 1), try frame(sequence: 2, pts: 2)])) {
            finished.record($0)
            timedOut.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.requiresRecovery(.requiresFlushToResumeDecoding))
        harness.output.waitUntilIdleForTesting()
        await fulfillment(of: [timedOut], timeout: 3)
        XCTAssertEqual(finished.count, 1)
        XCTAssertNotNil(finished.error)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
        backend.completeFlush(at: 1)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.submittedPTS, [1, 2])
        XCTAssertEqual(finished.count, 1)
    }

    func testFlushRequiredSeedRetriesWithoutPrematureAnchorFailure() throws {
        try verifyRecoverableSeed(.requiresFlushToResumeDecoding)
    }

    func testNativeErrorSeedRetriesWithoutPrematureAnchorFailure() throws {
        try verifyRecoverableSeed(.failed(NSError(domain: "Receiver.Recoverable", code: -1)))
    }

    private func verifyRecoverableSeed(_ reason: VideoRendererBackendEvent) throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let failures = VideoResetResultBox()
        let receipt = VideoReceiptBox()
        let harness = makeHarness(backend: backend,
            failureSink: { error, _ in failures.record(.failure(error)) })
        harness.output.reset(.init(generation: .init(rawValue: 0), reason: .decoderRecovery,
            removeDisplayedImage: false, seedFrames: [try frame(sequence: 1, pts: 1)])) {
            failures.record($0)
            receipt.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.requiresRecovery(reason))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(failures.count, 0)
        XCTAssertNil(receipt.value)
        XCTAssertEqual(backend.flushCount, 2)
        backend.completeFlush(at: 1)
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue(.accepted)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(receipt.value?.sequenceNumbers, [1])
        XCTAssertNil(failures.error)
    }

    func testReceiverSuspensionDoesNotCompleteVideoAcceptanceEarly() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        let receipt = VideoReceiptBox()
        harness.output.enqueue([try frame(sequence: 1, pts: 1)]) {
            receipt.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.heldEnqueueCount, 1)
        XCTAssertNil(receipt.value)
        backend.completeEnqueue()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(receipt.value?.sequenceNumbers, [1])
    }

    func testReceiverLateVideoAcceptanceAfterResetIsIgnored() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        let receipt = VideoReceiptBox()
        harness.output.enqueue([try frame(sequence: 1, pts: 1)]) {
            receipt.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        harness.output.flush(to: MediaGeneration(rawValue: 1))
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue()
        harness.output.waitUntilIdleForTesting()
        XCTAssertNil(receipt.value)
        XCTAssertEqual(backend.heldEnqueueCount, 0)
    }

    func testAcceptedVideoWithDecodeWarningStillCompletesReceipt() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let failures = VideoResetResultBox()
        let harness = makeHarness(backend: backend,
            failureSink: { error, _ in failures.record(.failure(error)) })
        let receipt = VideoReceiptBox()
        harness.output.enqueue([try frame(sequence: 1, pts: 1)]) {
            receipt.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue()
        backend.emit(.decodeFailure(NSError(domain: "Receiver.DecodeWarning", code: -1)))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(receipt.value?.sequenceNumbers, [1])
        XCTAssertEqual(failures.count, 1)
    }

    func testOldReceiverEventAfterResetCannotFailNewVideoEpisode() throws {
        let backend = FakeVideoRendererBackend()
        let failures = VideoResetResultBox()
        let harness = makeHarness(backend: backend,
            failureSink: { error, _ in failures.record(.failure(error)) })
        let oldHandler = backend.captureEventHandler()
        harness.output.flush(to: MediaGeneration(rawValue: 1))
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        oldHandler?(.failed(NSError(domain: "Receiver.OldEpisode", code: -1)))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(failures.count, 0)
    }

    func testDelayedReceiverFailureAfterFinalVideoEnqueueStillRequestsRecovery() throws {
        let backend = FakeVideoRendererBackend()
        let recoveries = VideoOutputEventBox()
        let harness = makeHarness(backend: backend, recoverySink: { _ in recoveries.record() })
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.finishedEnqueuingCount, 1)
        backend.requiresFlushToResumeDecoding = true
        backend.emit(.requiresFlushToResumeDecoding)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(recoveries.count, 1)
    }

    func testRendererFailurePreservesOriginalErrorDetails() throws {
        let backend = FakeVideoRendererBackend()
        let failures = VideoResetResultBox()
        let harness = makeHarness(backend: backend,
            failureSink: { error, _ in failures.record(.failure(error)) })
        backend.emit(.failed(NSError(domain: "VideoRenderer.Test", code: -91,
            userInfo: [NSLocalizedDescriptionKey: "视频渲染器原始异常"])))
        harness.output.waitUntilIdleForTesting()

        let error = try XCTUnwrap(failures.error)
        let failure = PlaybackController.failure(for: error)
        XCTAssertTrue(failure.userMessage.contains("NSError"))
        XCTAssertTrue(failure.userMessage.contains("VideoRenderer.Test"))
        XCTAssertTrue(failure.userMessage.contains("-91"))
        XCTAssertTrue(failure.userMessage.contains("视频渲染器原始异常"))
        XCTAssertEqual(failures.count, 1)
    }

    func testPerformanceMetricsRefreshIsSingleFlightAndFeedsSharedCollector() throws {
        let backend = FakeVideoRendererBackend()
        let metrics = PlaybackMetrics(channelID: "renderer-native-metrics", now: { 1 })
        let harness = makeHarness(backend: backend, metrics: metrics)

        harness.output.refreshPerformanceMetrics()
        harness.output.refreshPerformanceMetrics()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.performanceMetricsRequestCount, 1)

        backend.completePerformanceMetrics(
            VideoRendererPerformanceSnapshot(
                totalFrameCount: 12,
                droppedFrameCount: 2,
                corruptedFrameCount: 1,
                optimizedFrameCount: 9,
                accumulatedFrameDelaySeconds: 0.125
            )
        )
        harness.output.waitUntilIdleForTesting()

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.videoRendererMetricsSampleCount, 1)
        XCTAssertEqual(snapshot.videoRendererTotalFrameCount, 12)
        XCTAssertEqual(snapshot.videoRendererDroppedFrameCount, 2)
        XCTAssertEqual(
            snapshot.videoRendererAccumulatedFrameDelayMilliseconds,
            125,
            accuracy: 0.000_001
        )
    }

    func testBackpressureKeepsSingleRequestArmedAndDrainsInTimestampOrder() throws {
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let harness = makeHarness(backend: backend)
        let generation = MediaGeneration(rawValue: 0)

        harness.output.enqueue(try frame(sequence: 3, pts: 3, generation: generation))
        harness.output.enqueue(try frame(sequence: 1, pts: 1, generation: generation))
        harness.output.enqueue(try frame(sequence: 2, pts: 2, generation: generation))
        harness.output.waitUntilIdleForTesting()

        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(backend.stopRequestCount, 0)
        XCTAssertTrue(backend.enqueuedPTS.isEmpty)

        backend.ready = true
        backend.fireReadiness()
        harness.output.waitUntilIdleForTesting()

        XCTAssertEqual(backend.enqueuedPTS, [1, 2, 3])
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(backend.stopRequestCount, 1)
    }

    func testAcceptanceCompletesOnlyAfterEveryFrameReachedBackend() throws {
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let harness = makeHarness(backend: backend)
        let generation = MediaGeneration(rawValue: 0)
        let accepted = expectation(description: "accepted")
        let receipt = VideoReceiptBox()

        harness.output.enqueue([
            try frame(sequence: 10, pts: 1, generation: generation),
            try frame(sequence: 11, pts: 2, generation: generation),
        ]) { result in
            receipt.value = try? result.get()
            accepted.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        XCTAssertNil(receipt.value)

        backend.ready = true
        backend.fireReadiness()
        wait(for: [accepted], timeout: 1)

        XCTAssertEqual(
            receipt.value,
            VideoEnqueueReceipt(generation: generation, sequenceNumbers: [10, 11])
        )
    }

    func testBudgetDeduplicatesSameIOSurfaceAndRejectsDistinctOverflow() throws {
        let buffer = try VideoTestFactories.nv12(width: 64, height: 36)
        let first = frame(sequence: 1, pts: 1, pixelBuffer: buffer)
        let duplicate = frame(sequence: 2, pts: 2, pixelBuffer: buffer)
        let distinct = try frame(sequence: 3, pts: 3)
        let ledger = VideoSurfaceBudgetLedger(limit: first.estimatedStorageBytes)

        XCTAssertTrue(ledger.retain(first))
        XCTAssertTrue(ledger.retain(duplicate))
        XCTAssertFalse(ledger.retain(distinct))
        XCTAssertEqual(ledger.snapshot.retainedSurfaceCount, 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 2)
        XCTAssertEqual(ledger.snapshot.retainedBytes, first.estimatedStorageBytes)

        ledger.release(first)
        XCTAssertEqual(ledger.snapshot.referenceCount, 1)
        ledger.release(duplicate)
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    }

    func testOverflowDropsFarthestFutureFrame() throws {
        let sample = try frame(sequence: 1, pts: 1)
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let ledger = VideoSurfaceBudgetLedger(limit: sample.estimatedStorageBytes * 2)
        let harness = makeHarness(backend: backend, ledger: ledger)

        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.enqueue(try frame(sequence: 3, pts: 3))
        harness.output.enqueue(try frame(sequence: 2, pts: 2))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(harness.output.pendingSequenceNumbersForTesting, [1, 2])

        backend.ready = true
        backend.fireReadiness()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1, 2])
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    }

    func testOutOfOrderBatchOverflowRejectsAtomicallyWithoutLeakingLedgerReference() throws {
        let sample = try frame(sequence: 1, pts: 1)
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let ledger = VideoSurfaceBudgetLedger(limit: sample.estimatedStorageBytes * 2)
        let harness = makeHarness(backend: backend, ledger: ledger)
        let rejected = expectation(description: "批次被整体拒绝")

        harness.output.enqueue([
            try frame(sequence: 3, pts: 3),
            try frame(sequence: 1, pts: 1),
            try frame(sequence: 2, pts: 2),
        ]) { result in
            if case .success = result { XCTFail("超出预算的批次不应部分成功") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        harness.output.waitUntilIdleForTesting()

        XCTAssertTrue(harness.output.pendingSequenceNumbersForTesting.isEmpty)
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testResetCoalescesWithoutOverlappingPhysicalFlushes() throws {
        let backend = FakeVideoRendererBackend()
        let harness = makeHarness(backend: backend)
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)
        let first = expectation(description: "first reset superseded")
        let second = expectation(description: "second reset completed")

        harness.output.reset(.init(
            generation: firstGeneration,
            reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 1, pts: 1, generation: firstGeneration)]
        )) { result in
            if case .success = result {
                XCTFail("被新周期取代的刷新不应成功")
            }
            first.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.flushCount, 1)

        harness.output.reset(.init(
            generation: secondGeneration,
            reason: .audioGap,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 2, pts: 2, generation: secondGeneration)]
        )) { result in
            switch result {
            case let .success(receipt):
                XCTAssertEqual(receipt.generation, secondGeneration)
            case let .failure(error):
                XCTFail("unexpected failure: \(error)")
            }
            second.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.flushCount, 1, "物理刷新不得重叠")

        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.flushCount, 2)
        XCTAssertTrue(backend.enqueuedPTS.isEmpty, "旧刷新完成不得播种新周期")

        backend.completeFlush(at: 1)
        wait(for: [first, second], timeout: 1)
        XCTAssertEqual(backend.enqueuedPTS, [2])
    }

    func testCoalescedResetPreservesFramesArrivingAfterLatestRequest() throws {
        let backend = FakeVideoRendererBackend()
        let harness = makeHarness(backend: backend)
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)
        let first = expectation(description: "首次刷新被取代")
        let second = expectation(description: "最新刷新及后续帧完成")

        harness.output.reset(.init(
            generation: firstGeneration,
            reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 1, pts: 1, generation: firstGeneration)]
        )) { result in
            if case .success = result { XCTFail("被取代的刷新不应成功") }
            first.fulfill()
        }
        harness.output.waitUntilIdleForTesting()

        harness.output.reset(.init(
            generation: secondGeneration,
            reason: .audioGap,
            removeDisplayedImage: true,
            seedFrames: [try frame(sequence: 2, pts: 2, generation: secondGeneration)]
        )) { result in
            if case let .failure(error) = result {
                XCTFail("最新刷新不应失败：\(error)")
            }
            second.fulfill()
        }
        harness.output.waitUntilIdleForTesting()

        harness.output.enqueue(try frame(
            sequence: 3,
            pts: 3,
            generation: secondGeneration
        ))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(harness.output.pendingSequenceNumbersForTesting, [3])

        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.flushCount, 2)
        XCTAssertTrue(backend.enqueuedPTS.isEmpty)

        backend.completeFlush(at: 1)
        wait(for: [first, second], timeout: 1)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [2, 3])
    }

    func testResetSeedOverflowRejectsAtomicallyWithoutTrailingLedgerOwner() throws {
        let sample = try frame(sequence: 1, pts: 1)
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let ledger = VideoSurfaceBudgetLedger(limit: sample.estimatedStorageBytes * 2)
        let harness = makeHarness(backend: backend, ledger: ledger)
        let rejected = expectation(description: "刷新种子被整体拒绝")

        harness.output.reset(.init(
            generation: MediaGeneration(rawValue: 0),
            reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: [
                try frame(sequence: 4, pts: 4),
                try frame(sequence: 1, pts: 1),
                try frame(sequence: 2, pts: 2),
                try frame(sequence: 3, pts: 3),
            ]
        )) { result in
            if case .success = result { XCTFail("超出预算的刷新种子不应部分成功") }
            rejected.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        wait(for: [rejected], timeout: 1)
        harness.output.waitUntilIdleForTesting()

        XCTAssertTrue(harness.output.pendingSequenceNumbersForTesting.isEmpty)
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testDecoderGenerationAdvancePreservesAdmittedInFlightReceipt() throws {
        let backend = FakeVideoRendererBackend()
        backend.holdEnqueueCompletions = true
        let harness = makeHarness(backend: backend)
        let oldReceipt = VideoReceiptBox()
        let newReceipt = VideoReceiptBox()
        harness.output.enqueue([try frame(sequence: 1, pts: 1)]) { oldReceipt.value = try? $0.get() }
        harness.output.waitUntilIdleForTesting()
        harness.output.advanceDecoderGeneration(to: .init(rawValue: 1))
        harness.output.enqueue([try frame(sequence: 2, pts: 2, generation: .init(rawValue: 1))]) {
            newReceipt.value = try? $0.get()
        }
        harness.output.waitUntilIdleForTesting()
        backend.completeEnqueue()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(oldReceipt.value?.generation, .init(rawValue: 0))
        XCTAssertNil(newReceipt.value)
        backend.completeEnqueue()
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(newReceipt.value?.generation, .init(rawValue: 1))
        XCTAssertEqual(backend.flushCount, 0)
        XCTAssertEqual(backend.requestCount, 1)
    }

    func testDecoderGenerationAdvanceDoesNotFlushOrRestartRequest() throws {
        let backend = FakeVideoRendererBackend()
        backend.ready = false
        let harness = makeHarness(backend: backend)
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()
        let requestCount = backend.requestCount

        harness.output.advanceDecoderGeneration(to: MediaGeneration(rawValue: 1))
        harness.output.waitUntilIdleForTesting()

        XCTAssertEqual(backend.flushCount, 0)
        XCTAssertEqual(backend.requestCount, requestCount)
        XCTAssertEqual(backend.stopRequestCount, 0)
    }

    func testStopWaitsForFlushAndSynchronizerRemoval() async throws {
        let backend = FakeVideoRendererBackend()
        let removal = FakeVideoRendererRemoval()
        let harness = makeHarness(backend: backend, removal: removal)
        harness.output.enqueue(try frame(sequence: 1, pts: 1))
        harness.output.waitUntilIdleForTesting()

        let stop = Task { await harness.output.stopAwaitingRendererRemoval() }
        try await eventually { backend.flushCount == 1 }
        XCTAssertEqual(backend.flushCount, 1)
        XCTAssertEqual(removal.requestCount, 0)

        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(removal.requestCount, 1)
        XCTAssertFalse(stop.isCancelled)

        removal.complete(false)
        try await eventually { removal.requestCount == 2 }
        XCTAssertEqual(removal.requestCount, 2)

        removal.complete(true)
        await stop.value
        XCTAssertEqual(removal.requestCount, 2)
    }

    func testResetFlushDeadlineFailsExactlyOnceAndFencesLateCompletion() async throws {
        let backend = FakeVideoRendererBackend()
        let harness = makeHarness(backend: backend)
        let result = VideoResetResultBox()
        let completed = expectation(description: "刷新超时完成")

        harness.output.reset(.init(
            generation: MediaGeneration(rawValue: 1),
            reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: []
        )) { value in
            result.record(value)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result.error,
            .videoRendererFailed("renderer.flush-timeout")
        )
        backend.completeFlush(at: 0)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(result.count, 1)
    }

    func testRecoveryCoalescesBackendEventsAndReplaysPipelineSeeds() throws {
        let backend = FakeVideoRendererBackend()
        let recovery = VideoOutputEventBox()
        let failures = VideoResetResultBox()
        let harness = makeHarness(
            backend: backend,
            recoverySink: { _ in recovery.record() },
            failureSink: { error, _ in failures.record(.failure(error)) }
        )
        let generation = MediaGeneration(rawValue: 0)
        let first = try frame(sequence: 1, pts: 1, generation: generation)
        let second = try frame(sequence: 2, pts: 2, generation: generation)
        harness.output.enqueue(first)
        harness.output.enqueue(second)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1, 2])

        backend.requiresFlushToResumeDecoding = true
        backend.health = .failed
        backend.emit(.requiresFlushToResumeDecoding)
        backend.emit(.failed(NSError(domain: "renderer", code: 1)))
        backend.emit(.requiresFlushToResumeDecoding)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(failures.count, 0)

        let accepted = expectation(description: "恢复种子到达后端")
        harness.output.reset(.init(
            generation: generation,
            reason: .failure,
            removeDisplayedImage: false,
            seedFrames: [first, second]
        )) { result in
            if case let .failure(error) = result {
                XCTFail("unexpected failure: \(error)")
            }
            accepted.fulfill()
        }
        harness.output.waitUntilIdleForTesting()
        backend.emit(.failed(NSError(domain: "renderer", code: 2)))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(recovery.count, 1, "物理刷新进行中必须合并相关失败事件")
        XCTAssertEqual(failures.count, 0)

        backend.completeFlush(at: 0)
        wait(for: [accepted], timeout: 1)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1, 2, 1, 2])

        backend.emit(.failed(NSError(domain: "renderer", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "恢复后视频渲染器再次失败"])))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(failures.count, 1, "恢复后无新进展的再次失败应升级为终止错误")
        XCTAssertEqual(recovery.count, 1)
        let failure = PlaybackController.failure(for: try XCTUnwrap(failures.error))
        XCTAssertTrue(failure.userMessage.contains("恢复后视频渲染器再次失败"),
            "终态应使用本次回调的真实错误，即使 backend.error 尚未更新")
    }

    func testPostRecoveryFrameAllowsOneNewCoalescedRecoveryRequest() throws {
        let backend = FakeVideoRendererBackend()
        let recovery = VideoOutputEventBox()
        let failures = VideoOutputEventBox()
        let harness = makeHarness(
            backend: backend,
            recoverySink: { _ in recovery.record() },
            failureSink: { _, _ in failures.record() }
        )
        backend.requiresFlushToResumeDecoding = true
        backend.health = .failed
        backend.emit(.requiresFlushToResumeDecoding)
        harness.output.waitUntilIdleForTesting()

        let reset = expectation(description: "首次恢复完成")
        harness.output.reset(.init(
            generation: MediaGeneration(rawValue: 0),
            reason: .failure,
            removeDisplayedImage: false,
            seedFrames: []
        )) { _ in reset.fulfill() }
        harness.output.waitUntilIdleForTesting()
        backend.completeFlush(at: 0)
        wait(for: [reset], timeout: 1)

        harness.output.enqueue(try frame(sequence: 3, pts: 3))
        harness.output.waitUntilIdleForTesting()
        backend.emit(.requiresFlushToResumeDecoding)
        backend.emit(.failed(NSError(domain: "renderer", code: 4)))
        harness.output.waitUntilIdleForTesting()

        XCTAssertEqual(recovery.count, 2)
        XCTAssertEqual(failures.count, 0)
    }

    private func makeHarness(
        backend: FakeVideoRendererBackend,
        ledger: VideoSurfaceBudgetLedger = VideoSurfaceBudgetLedger(),
        metrics: PlaybackMetrics? = nil,
        removal: FakeVideoRendererRemoval = FakeVideoRendererRemoval(),
        recoverySink: @escaping @Sendable (MediaGeneration) -> Void = { _ in },
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void = { _, _ in }
    ) -> (output: SystemVideoOutput, removal: FakeVideoRendererRemoval) {
        let output = SystemVideoOutput(
            backend: backend,
            ledger: ledger,
            metrics: metrics,
            removeRenderer: removal.remove,
            recoverySink: recoverySink,
            failureSink: failureSink
        )
        return (output, removal)
    }

    private func frame(
        sequence: UInt64,
        pts: Int64,
        generation: MediaGeneration = MediaGeneration(rawValue: 0),
        pixelBuffer: CVPixelBuffer? = nil
    ) throws -> VideoPresentationFrame {
        frame(
            sequence: sequence,
            pts: pts,
            generation: generation,
            pixelBuffer: try pixelBuffer ?? VideoTestFactories.nv12()
        )
    }

    private func frame(
        sequence: UInt64,
        pts: Int64,
        generation: MediaGeneration = MediaGeneration(rawValue: 0),
        pixelBuffer: CVPixelBuffer
    ) -> VideoPresentationFrame {
        VideoPresentationFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: pts, timescale: 1),
            duration: CMTime(value: 1, timescale: 1),
            generation: generation,
            sequenceNumber: sequence,
            sourceAccessUnitID: sequence,
            formatMetadata: VideoTestFactories.metadata()
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        _ condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待异步状态超时")
    }
}

private final class VideoReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VideoEnqueueReceipt?

    var value: VideoEnqueueReceipt? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class VideoResetResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private var storedError: PlaybackCoreError?

    var count: Int { lock.withLock { storedCount } }
    var error: PlaybackCoreError? { lock.withLock { storedError } }

    func record(_ result: Result<VideoEnqueueReceipt, PlaybackCoreError>) {
        lock.withLock {
            storedCount += 1
            if case let .failure(error) = result { storedError = error }
        }
    }
}

private final class FakeVideoRendererBackend: SampleBufferVideoRenderingBackend,
    @unchecked Sendable {
    private let lock = NSLock()
    var ready = true
    var health: VideoRendererHealth = .noKnownFailure
    var error: (any Error)?
    var requiresFlushToResumeDecoding = false
    private(set) var requestCount = 0
    private(set) var stopRequestCount = 0
    private(set) var flushCount = 0
    private(set) var enqueuedPTS: [Int64] = []
    private(set) var submittedPTS: [Int64] = []
    private var readiness: (@Sendable () -> Void)?
    private var flushCompletions: [@Sendable (Bool) -> Void] = []
    private var eventHandler: (@Sendable (VideoRendererBackendEvent) -> Void)?
    private var performanceMetricsCompletions: [
        @Sendable (VideoRendererPerformanceSnapshot?) -> Void
    ] = []
    private(set) var performanceMetricsRequestCount = 0

    var isReadyForMoreMediaData: Bool {
        lock.withLock { ready && (!latchesRecoveryUntilFlush ||
            (health != .failed && !requiresFlushToResumeDecoding)) }
    }

    var holdEnqueueCompletions = false
    var latchesRecoveryUntilFlush = false
    private var heldEnqueues: [@Sendable (Result<VideoRendererEnqueueResult, any Error>) -> Void] = []
    var heldEnqueueCount: Int { lock.withLock { heldEnqueues.count } }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
        completion: @escaping @Sendable (Result<VideoRendererEnqueueResult, any Error>) -> Void) {
        lock.withLock { submittedPTS.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value) }
        if holdEnqueueCompletions {
            lock.withLock { heldEnqueues.append(completion) }
        } else {
            enqueue(sampleBuffer)
            completion(.success(.accepted))
        }
    }

    func completeEnqueue(_ result: VideoRendererEnqueueResult = .accepted) {
        let completion = lock.withLock {
            if latchesRecoveryUntilFlush, case let .requiresRecovery(reason) = result {
                switch reason {
                case .requiresFlushToResumeDecoding: requiresFlushToResumeDecoding = true
                case let .failed(failure): health = .failed; error = failure
                case .decodeFailure: break
                }
            }
            return heldEnqueues.isEmpty ? nil : heldEnqueues.removeFirst()
        }
        completion?(.success(result))
    }

    func cancelPendingEnqueue() {}
    private(set) var finishedEnqueuingCount = 0
    func finishedEnqueuing() { lock.withLock { finishedEnqueuingCount += 1 } }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            enqueuedPTS.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value)
        }
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            requestCount += 1
            readiness = { queue.async(execute: block) }
        }
    }

    func stopRequestingMediaData() {
        lock.withLock {
            stopRequestCount += 1
            readiness = nil
        }
    }

    func flush(
        removeDisplayedImage: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        _ = removeDisplayedImage
        lock.withLock {
            flushCount += 1
            flushCompletions.append(completion)
        }
    }

    func loadPerformanceMetrics(
        completion: @escaping @Sendable (VideoRendererPerformanceSnapshot?) -> Void
    ) {
        lock.withLock {
            performanceMetricsRequestCount += 1
            performanceMetricsCompletions.append(completion)
        }
    }

    func startObserving(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    func stopObserving() {
        lock.withLock { eventHandler = nil }
    }

    func fireReadiness() {
        lock.withLock { readiness }?()
    }

    func completeFlush(at index: Int, settled: Bool = true) {
        let completion = lock.withLock {
            if settled, latchesRecoveryUntilFlush {
                health = .noKnownFailure
                error = nil
                requiresFlushToResumeDecoding = false
            }
            return flushCompletions[index]
        }
        completion(settled)
    }

    func completePerformanceMetrics(_ snapshot: VideoRendererPerformanceSnapshot?) {
        let completion = lock.withLock { performanceMetricsCompletions.removeFirst() }
        completion(snapshot)
    }

    func captureEventHandler() -> (@Sendable (VideoRendererBackendEvent) -> Void)? {
        lock.withLock { eventHandler }
    }

    func emit(_ event: VideoRendererBackendEvent) {
        lock.withLock { eventHandler }?(event)
    }
}

private final class FakeVideoRendererRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?
    private(set) var requestCount = 0

    lazy var remove: SystemVideoOutput.RendererRemoval = { [weak self] completion in
        self?.lock.withLock {
            self?.requestCount += 1
            self?.completion = completion
        }
    }

    func complete(_ removed: Bool) {
        lock.withLock { completion }?(removed)
    }
}

private final class VideoOutputEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}
