// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class SystemVideoOutputTests: XCTestCase {
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

    func testRecoveryCoalescesBackendEventsAndReplaysPipelineSeeds() throws {
        let backend = FakeVideoRendererBackend()
        let recovery = VideoOutputEventBox()
        let failures = VideoOutputEventBox()
        let harness = makeHarness(
            backend: backend,
            recoverySink: { _ in recovery.record() },
            failureSink: { _, _ in failures.record() }
        )
        let generation = MediaGeneration(rawValue: 0)
        let first = try frame(sequence: 1, pts: 1, generation: generation)
        let second = try frame(sequence: 2, pts: 2, generation: generation)
        harness.output.enqueue(first)
        harness.output.enqueue(second)
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(backend.enqueuedPTS, [1, 2])

        backend.requiresFlushToResumeDecoding = true
        backend.status = .failed
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

        backend.emit(.failed(NSError(domain: "renderer", code: 3)))
        harness.output.waitUntilIdleForTesting()
        XCTAssertEqual(failures.count, 1, "恢复后无新进展的再次失败应升级为终止错误")
        XCTAssertEqual(recovery.count, 1)
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
        backend.status = .failed
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
        removal: FakeVideoRendererRemoval = FakeVideoRendererRemoval(),
        recoverySink: @escaping @Sendable (MediaGeneration) -> Void = { _ in },
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void = { _, _ in }
    ) -> (output: SystemVideoOutput, removal: FakeVideoRendererRemoval) {
        let output = SystemVideoOutput(
            backend: backend,
            ledger: ledger,
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

private final class FakeVideoRendererBackend: SampleBufferVideoRenderingBackend,
    @unchecked Sendable {
    private let lock = NSLock()
    var ready = true
    var status: AVQueuedSampleBufferRenderingStatus = .unknown
    var error: (any Error)?
    var requiresFlushToResumeDecoding = false
    private(set) var requestCount = 0
    private(set) var stopRequestCount = 0
    private(set) var flushCount = 0
    private(set) var enqueuedPTS: [Int64] = []
    private var readiness: (@Sendable () -> Void)?
    private var flushCompletions: [@Sendable () -> Void] = []
    private var eventHandler: (@Sendable (VideoRendererBackendEvent) -> Void)?

    var isReadyForMoreMediaData: Bool { lock.withLock { ready } }

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
        completion: @escaping @Sendable () -> Void
    ) {
        _ = removeDisplayedImage
        lock.withLock {
            flushCount += 1
            flushCompletions.append(completion)
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

    func completeFlush(at index: Int) {
        lock.withLock { flushCompletions[index] }()
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
