// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeReceiverAdapterTests: XCTestCase {
    func testRealSDKPCMAudioReceiverEOFRegistrationResumeFlushAndRemoval() async throws {
        let samples = try (0..<3).map { index in
            try PCMSampleBufferBuilder.make(bytes: Data(repeating: 0, count: 480 * 2 * 4),
                frameCount: 480, sampleRate: 48_000, channels: 2,
                channelOrder: .native, channelLayoutMask: 3,
                presentationTimeStamp: CMTime(value: Int64(index * 480), timescale: 48_000))
        }
        try await NativeAudioReceiverSmoke.assertLifecycle(samples: samples, mediaKind: .linearPCM)
    }

    func testRealSDKVideoReceiverCanResumeAfterIdleEventsFlushAndRemove() async throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let layer = AVSampleBufferDisplayLayer()
        let backend = VideoRendererBackend(renderer: layer.sampleBufferRenderer,
            synchronizer: synchronizer)
        let builder = VideoImageSampleBufferBuilder()
        let pixelBuffer = try VideoTestFactories.nv12(width: 64, height: 36)
        func sample(_ sequence: UInt64) throws -> CMSampleBuffer {
            try builder.make(frame: VideoPresentationFrame(pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), generation: .init(rawValue: 0),
                sequenceNumber: sequence, sourceAccessUnitID: sequence,
                formatMetadata: VideoTestFactories.metadata()))
        }
        let first = expectation(description: "SDK Receiver accepts copied ready image header")
        let firstResult = NativeSmokeResult()
        backend.enqueue(try sample(1)) { result in firstResult.record(result); first.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        guard firstResult.accepted else {
            XCTFail("First native enqueue failed: \(firstResult.description)")
            backend.cancelPendingEnqueue()
            backend.remove { _ in }
            return
        }
        backend.finishedEnqueuing()
        // Give the real SDK iterator an idle interval with no producer work.
        // Every wait here is bounded; no task-group timeout can inherit a stuck
        // iterator child and prevent XCTest from reporting the failure.
        let idle = expectation(description: "SDK event iterator idle interval")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { idle.fulfill() }
        await fulfillment(of: [idle], timeout: 1)
        try await eventually { backend.isReadyForMoreMediaData }
        let resumed = expectation(description: "SDK idle iterator cancels and native enqueue resumes")
        let resumedResult = NativeSmokeResult()
        backend.enqueue(try sample(2)) { result in resumedResult.record(result); resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 3)
        guard resumedResult.accepted else {
            XCTFail("Native EOF/resume did not settle: \(resumedResult.description)")
            backend.cancelPendingEnqueue()
            backend.remove { _ in }
            return
        }
        backend.finishedEnqueuing()
        let flushed = expectation(description: "SDK Receiver physical flush settles")
        let flushCount = NativeAdapterCounter()
        backend.flush(removeDisplayedImage: true) { settled in
            XCTAssertTrue(settled); flushCount.increment(); flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 3)
        guard flushCount.value == 1 else {
            XCTFail("Native event cancellation/flush did not settle")
            backend.remove { _ in }
            return
        }
        let removed = expectation(description: "SDK sending Receiver removal settles")
        let removedCount = NativeAdapterCounter()
        backend.remove { success in
            if success { removedCount.increment() }
            removed.fulfill()
        }
        await fulfillment(of: [removed], timeout: 3)
        XCTAssertEqual(removedCount.value, 1, "SDK did not report physical Receiver removal")
    }

    func testVideoResetRetainsRetiredSurfaceUntilNativeEnqueueSettles() async throws {
        let endpoint = ControlledVideoReceiverEndpoint()
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        let oldFrame = try videoFrame(sequence: 1, generation: 0)
        let newFrame = try videoFrame(sequence: 2, generation: 1)
        let ledger = VideoSurfaceBudgetLedger(limit: oldFrame.estimatedStorageBytes)
        let output = SystemVideoOutput(backend: backend, ledger: ledger,
            removeRenderer: backend.remove, failureSink: { _, _ in })
        let oldReceipt = NativeAdapterCounter()
        let resetReceipt = NativeAdapterCounter()
        let capacityRejection = NativeAdapterCounter()
        XCTAssertTrue(ledger.retain(oldFrame), "Model the timeline's shared surface reference")
        output.enqueue([oldFrame]) { result in
            if case .success = result { XCTFail("A retired enqueue must never complete its old receipt") }
            oldReceipt.increment()
        }
        try await eventually { await endpoint.operations == ["enqueue"] }
        XCTAssertEqual(ledger.snapshot.referenceCount, 2)
        output.flush(to: .init(rawValue: 1))
        output.waitUntilIdleForTesting()
        XCTAssertEqual(oldReceipt.value, 1, "Logical cancellation is immediate")
        ledger.release(oldFrame) // Timeline discontinuity drops its independent reference.
        XCTAssertEqual(ledger.snapshot.referenceCount, 1,
            "The native submission still owns the full one-surface budget")
        output.enqueue([newFrame]) { result in
            if case .success = result { XCTFail("The retired native surface still occupies the budget") }
            capacityRejection.increment()
        }
        output.waitUntilIdleForTesting()
        XCTAssertEqual(capacityRejection.value, 1)
        XCTAssertTrue(output.pendingSequenceNumbersForTesting.isEmpty)
        XCTAssertEqual(ledger.snapshot.retainedBytes, oldFrame.estimatedStorageBytes)

        // An independent same-surface owner detects any double release when the
        // stale native completion and the queued physical flushes finally run.
        XCTAssertTrue(ledger.retain(oldFrame))
        output.reset(.init(generation: .init(rawValue: 1), reason: .timelineDiscontinuity,
            removeDisplayedImage: true, seedFrames: [])) { result in
            if case .failure = result { XCTFail("The replacement reset should complete after settlement") }
            resetReceipt.increment()
        }
        output.waitUntilIdleForTesting()
        await endpoint.complete(.init(result: .accepted, events: []))
        try await eventually { resetReceipt.value == 1 }
        output.waitUntilIdleForTesting()
        XCTAssertEqual(oldReceipt.value, 1)
        XCTAssertEqual(capacityRejection.value, 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 1, "Release only the retired submission's reference")
        ledger.release(oldFrame)
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)

        let accepted = expectation(description: "Budget can be reused after physical settlement")
        output.enqueue([newFrame]) { result in
            XCTAssertEqual(try? result.get().sequenceNumbers, [2])
            accepted.fulfill()
        }
        try await eventually { await endpoint.operations.filter { $0 == "enqueue" }.count == 2 }
        await endpoint.complete(.init(result: .accepted, events: []))
        await fulfillment(of: [accepted], timeout: 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
        let removed = expectation(description: "Reset surface test receiver removed")
        backend.remove { _ in removed.fulfill() }
        await fulfillment(of: [removed], timeout: 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 0)
    }

    func testVideoStopDeadlineRetainsSurfaceUntilNativeEnqueueSettles() async throws {
        let endpoint = ControlledVideoReceiverEndpoint()
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        let frame = try videoFrame(sequence: 1, generation: 0)
        let ledger = VideoSurfaceBudgetLedger(limit: frame.estimatedStorageBytes)
        let output = SystemVideoOutput(backend: backend, ledger: ledger,
            removeRenderer: backend.remove, failureSink: { _, _ in })
        let receipt = NativeAdapterCounter()
        output.enqueue([frame]) { result in
            if case .success = result { XCTFail("Stopped receipt must be rejected") }
            receipt.increment()
        }
        try await eventually { await endpoint.operations == ["enqueue"] }
        let stopped = expectation(description: "Outer stop deadline completes independently of native enqueue")
        Task { await output.stopAwaitingRendererRemoval(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(receipt.value, 1)
        XCTAssertEqual(ledger.snapshot.referenceCount, 1,
            "A stop timeout cannot release an application-owned native submission")
        await endpoint.complete(.init(result: .accepted, events: []))
        try await eventually { ledger.snapshot.referenceCount == 0 }
        XCTAssertEqual(receipt.value, 1)
        try await eventually { await endpoint.operations.contains("remove") }
        XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    }

    private func videoFrame(sequence: UInt64, generation: UInt64) throws -> VideoPresentationFrame {
        VideoPresentationFrame(pixelBuffer: try VideoTestFactories.nv12(width: 64, height: 36),
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30),
            duration: CMTime(value: 1, timescale: 30), generation: .init(rawValue: generation),
            sequenceNumber: sequence, sourceAccessUnitID: sequence,
            formatMetadata: VideoTestFactories.metadata())
    }

    func testAudioControlBurstCoalescesBehindHeldPhysicalFlush() async throws {
        let endpoint = ControlledAudioReceiverEndpoint(holdFlush: true)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 10), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        renderer.flush()
        try await eventually { await endpoint.operations == ["flush"] }
        for _ in 0..<64 { renderer.flush(); renderer.finishedEnqueuing() }
        XCTAssertEqual(renderer.controlWorkSnapshot.workers, 1)
        XCTAssertEqual(renderer.controlWorkSnapshot.pendingIntents, 2)
        XCTAssertEqual(renderer.controlWorkSnapshot.completionWaiters, 0)
        XCTAssertFalse(renderer.isReadyForMoreMediaData)
        await endpoint.completeFlush()
        try await eventually { await endpoint.operations == ["flush", "flush"] }
        XCTAssertFalse(renderer.isReadyForMoreMediaData)
        await endpoint.completeFlush()
        try await eventually { renderer.isReadyForMoreMediaData }
        let operations = await endpoint.operations
        XCTAssertEqual(operations, ["flush", "flush", "observe"],
            "A burst must retain only one pending physical flush and latest idle intent")
    }

    func testVideoControlBurstSupersedesPendingWaitersAndPreservesImageClear() async throws {
        let endpoint = ControlledVideoReceiverEndpoint(holdFlush: true)
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        let results = NativeControlResults()
        requestFlush(backend, removeDisplayedImage: false) { results.record($0) }
        try await eventually { await endpoint.operations == ["flush"] }
        for index in 0..<64 {
            requestFlush(backend, removeDisplayedImage: index == 0) { results.record($0) }
            backend.finishedEnqueuing()
        }
        XCTAssertEqual(backend.controlWorkSnapshot.workers, 1)
        XCTAssertEqual(backend.controlWorkSnapshot.pendingIntents, 2)
        XCTAssertEqual(backend.controlWorkSnapshot.completionWaiters, 2)
        XCTAssertEqual(results.values, Array(repeating: false, count: 63),
            "Superseded pending callbacks must settle explicitly without retained waiters")
        XCTAssertFalse(backend.isReadyForMoreMediaData)
        await endpoint.completeFlush()
        try await eventually { await endpoint.operations == ["flush", "flush"] }
        XCTAssertEqual(results.values.filter { $0 }.count, 1)
        let imageClears = await endpoint.flushImageClears
        XCTAssertEqual(imageClears, [false, true], "Keep the strongest coalesced clear intent")
        await endpoint.completeFlush()
        try await eventually { results.values.count == 65 && backend.isReadyForMoreMediaData }
        XCTAssertEqual(results.values.filter { $0 }.count, 2)
        let operations = await endpoint.operations
        XCTAssertEqual(operations, ["flush", "flush", "observe"])
        let accepted = expectation(description: "Feed resumes after the final physical barrier")
        backend.enqueue(try pcm()) { result in
            if case .success(.accepted) = result {} else { XCTFail("Expected genuine native acceptance") }
            accepted.fulfill()
        }
        try await eventually { await endpoint.operations.last == "enqueue" }
        await endpoint.complete(.init(result: .accepted, events: []))
        await fulfillment(of: [accepted], timeout: 1)
    }

    func testVideoControlAndRemovalOverflowRemainBoundedUntilNativeSettlement() async throws {
        let endpoint = ControlledVideoReceiverEndpoint(holdFlush: true)
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        let flushes = NativeControlResults()
        let removals = NativeControlResults()
        backend.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        backend.flush(removeDisplayedImage: false) { flushes.record($0) }
        try await eventually { await endpoint.operations == ["enqueue", "flush"] }
        for index in 0..<64 {
            backend.flush(removeDisplayedImage: index == 0) { flushes.record($0) }
        }
        backend.cancelPendingEnqueue() // Must preserve the newest logical flush waiter.
        for _ in 0..<65 { backend.remove { removals.record($0) }; backend.finishedEnqueuing() }
        XCTAssertEqual(flushes.values, Array(repeating: false, count: 63))
        XCTAssertEqual(removals.values, Array(repeating: false, count: 63))
        XCTAssertEqual(backend.controlWorkSnapshot.workers, 1)
        XCTAssertEqual(backend.controlWorkSnapshot.pendingIntents, 2)
        XCTAssertEqual(backend.controlWorkSnapshot.completionWaiters, 4)
        backend.enqueue(try pcm()) { result in
            if case .success(.cancelled) = result {} else { XCTFail("Removal must close admission") }
        }
        await endpoint.completeFlush()
        // Flush returning is insufficient while native enqueue ignores cancellation.
        XCTAssertEqual(flushes.values.filter { $0 }.count, 0)
        await endpoint.complete(.init(result: .accepted, events: []))
        try await eventually { await endpoint.operations == ["enqueue", "flush", "flush"] }
        XCTAssertEqual(flushes.values.filter { $0 }.count, 1)
        XCTAssertEqual(removals.values.filter { $0 }.count, 0)
        let imageClears = await endpoint.flushImageClears
        XCTAssertEqual(imageClears, [false, true])
        await endpoint.completeFlush()
        try await eventually { removals.values.count == 65 && backend.controlWorkSnapshot.workers == 0 }
        XCTAssertEqual(flushes.values.filter { $0 }.count, 2)
        XCTAssertEqual(removals.values.filter { $0 }.count, 2)
        XCTAssertEqual(backend.controlWorkSnapshot.completionWaiters, 0)
        XCTAssertFalse(backend.isReadyForMoreMediaData)
        let operations = await endpoint.operations
        XCTAssertEqual(operations, ["enqueue", "flush", "flush", "remove"],
            "Removal dominates idle monitoring and occurs once after the true physical barriers")
    }

    func testSupersededVideoFlushKeepsNativeFailureUntilCurrentPhysicalBarrier() async throws {
        let endpoint = ControlledVideoReceiverEndpoint(holdFlush: true)
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        backend.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        await endpoint.complete(.init(result: .requiresRecovery(.failed(
            NSError(domain: "Receiver.CurrentFailure", code: -1))), events: []))
        try await eventually { backend.health == .failed }
        let results = NativeControlResults()
        backend.flush(removeDisplayedImage: false) { results.record($0) }
        try await eventually { await endpoint.operations == ["enqueue", "flush"] }
        backend.flush(removeDisplayedImage: false) { results.record($0) }
        backend.flush(removeDisplayedImage: false) { results.record($0) }
        XCTAssertEqual(results.values, [false])
        XCTAssertEqual(backend.health, .failed)
        await endpoint.completeFlush()
        try await eventually { await endpoint.operations == ["enqueue", "flush", "flush"] }
        XCTAssertEqual(backend.health, .failed, "An older barrier cannot clear the current failure fence")
        XCTAssertFalse(backend.isReadyForMoreMediaData)
        await endpoint.completeFlush()
        try await eventually { backend.isReadyForMoreMediaData }
        XCTAssertEqual(backend.health, .noKnownFailure)
        XCTAssertEqual(results.values, [false, true, true])
    }

    func testAudioRemovalOverflowKeepsOnlyFirstAndNewestWaiter() async throws {
        let endpoint = ControlledAudioReceiverEndpoint(holdFlush: true)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 11), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        renderer.flush()
        try await eventually { await endpoint.operations == ["flush"] }
        let removals = NativeControlResults()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        for _ in 0..<65 {
            renderer.remove(from: synchronizer, at: .invalid) { removals.record($0) }
            renderer.finishedEnqueuing()
        }
        XCTAssertEqual(removals.values, Array(repeating: false, count: 63))
        XCTAssertEqual(renderer.controlWorkSnapshot.workers, 1)
        XCTAssertEqual(renderer.controlWorkSnapshot.pendingIntents, 2)
        XCTAssertEqual(renderer.controlWorkSnapshot.completionWaiters, 2)
        await endpoint.completeFlush()
        try await eventually { await endpoint.operations == ["flush", "flush"] }
        XCTAssertEqual(removals.values.filter { $0 }.count, 0)
        await endpoint.completeFlush()
        try await eventually { removals.values.count == 65 && renderer.controlWorkSnapshot.workers == 0 }
        XCTAssertEqual(removals.values.filter { $0 }.count, 2)
        let operations = await endpoint.operations
        XCTAssertEqual(operations, ["flush", "flush", "remove"])
        XCTAssertFalse(renderer.isReadyForMoreMediaData)
    }

    private func requestFlush(_ backend: VideoRendererBackend, removeDisplayedImage: Bool,
        completion: @escaping @Sendable (Bool) -> Void) {
        backend.flush(removeDisplayedImage: removeDisplayedImage, completion: completion)
    }

    func testAudioSuggestedAutomaticFlushSettlesBeforeNextNativeEnqueue() async throws {
        let endpoint = ControlledAudioReceiverEndpoint(holdFlush: true)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 1), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        let sample = RendererReceiverSample(buffer: try pcm())
        let accepted = expectation(description: "accepted after required flush")
        renderer.enqueue(sample.buffer) { result in
            XCTAssertEqual(try? result.get(), .acceptedWithSuggestedFlush)
            renderer.enqueue(sample.buffer) { _ in }
            accepted.fulfill()
        }
        try await eventually { await endpoint.operations == ["enqueue"] }
        await endpoint.complete(.init(result: .acceptedWithSuggestedFlush,
            events: [.automaticFlush(.zero)]))
        try await eventually { await endpoint.operations == ["enqueue", "flush"] }
        XCTAssertFalse(renderer.isReadyForMoreMediaData)
        await endpoint.completeFlush()
        await fulfillment(of: [accepted], timeout: 1)
        try await eventually { await endpoint.operations == ["enqueue", "flush", "enqueue"] }
        await endpoint.complete(.init(result: .accepted, events: []))
    }

    func testAudioEOFNoticeFencesNextEnqueueBehindPhysicalFlush() async throws {
        let endpoint = ControlledAudioReceiverEndpoint(holdFlush: true)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 2), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        renderer.finishedEnqueuing()
        try await eventually { await endpoint.operations == ["observe"] }
        await endpoint.emit(.automaticFlush(.zero))
        renderer.enqueue(try pcm()) { result in XCTAssertEqual(try? result.get(), .backpressured) }
        try await eventually { await endpoint.operations == ["observe", "flush"] }
        await endpoint.completeFlush()
        try await eventually { renderer.isReadyForMoreMediaData }
        renderer.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["observe", "flush", "enqueue"] }
        await endpoint.complete(.init(result: .accepted, events: []))
    }

    func testAudioDetachWaitsForIgnoredCancellationToPhysicallySettle() async throws {
        let endpoint = ControlledAudioReceiverEndpoint()
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 3), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        let result = NativeAdapterCounter()
        renderer.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        renderer.remove(from: AVSampleBufferRenderSynchronizer(), at: .invalid) { _ in result.increment() }
        try await eventually { await endpoint.operations.contains("flush") }
        XCTAssertEqual(result.value, 0)
        let before = await endpoint.operations
        XCTAssertFalse(before.contains("remove"))
        await endpoint.complete(.init(result: .accepted, events: []))
        try await eventually { result.value == 1 }
        let after = await endpoint.operations
        XCTAssertEqual(after.last, "remove")
    }

    func testAudioNewEnqueueWaitsForFlushEvenAfterOldFeedSettles() async throws {
        let endpoint = ControlledAudioReceiverEndpoint(holdFlush: true)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 4), mediaKind: .linearPCM,
            receiverEndpoint: endpoint)
        renderer.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        renderer.flush()
        try await eventually { await endpoint.operations == ["enqueue", "flush"] }
        await endpoint.complete(.init(result: .accepted, events: []))
        XCTAssertFalse(renderer.isReadyForMoreMediaData)
        renderer.enqueue(try pcm()) { result in XCTAssertEqual(try? result.get(), .backpressured) }
        let beforeFlushSettlement = await endpoint.operations
        XCTAssertEqual(beforeFlushSettlement, ["enqueue", "flush"])
        await endpoint.completeFlush()
        try await eventually { renderer.isReadyForMoreMediaData }
        renderer.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue", "flush", "enqueue"] }
        await endpoint.complete(.init(result: .accepted, events: []))
    }

    func testVideoConcurrentDetachRequestsShareOnePhysicalRemoval() async throws {
        let endpoint = ControlledVideoReceiverEndpoint()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: synchronizer, receiverEndpoint: endpoint)
        let completed = NativeAdapterCounter()
        backend.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        backend.remove { removed in XCTAssertTrue(removed); completed.increment() }
        backend.remove { removed in XCTAssertTrue(removed); completed.increment() }
        try await eventually { await endpoint.operations.contains("flush") }
        XCTAssertEqual(completed.value, 0)
        await endpoint.complete(.init(result: .accepted, events: []))
        try await eventually { completed.value == 2 }
        let operations = await endpoint.operations
        XCTAssertEqual(operations.filter { $0 == "remove" }.count, 1)
    }

    func testStaleVideoFailureCannotPoisonResetEpisode() async throws {
        let endpoint = ControlledVideoReceiverEndpoint()
        let backend = VideoRendererBackend(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer,
            synchronizer: AVSampleBufferRenderSynchronizer(), receiverEndpoint: endpoint)
        let notices = NativeAdapterCounter()
        let flushed = NativeAdapterCounter()
        backend.startObserving { _ in notices.increment() }
        backend.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["enqueue"] }
        backend.flush(removeDisplayedImage: false) { settled in XCTAssertTrue(settled); flushed.increment() }
        try await eventually { await endpoint.operations.contains("flush") }
        XCTAssertEqual(flushed.value, 0)
        await endpoint.complete(.init(result: .requiresRecovery(.failed(
            NSError(domain: "OldReceiver", code: -1))), events: []))
        try await eventually { flushed.value == 1 && backend.isReadyForMoreMediaData }
        XCTAssertTrue(backend.isReadyForMoreMediaData)
        XCTAssertFalse(backend.requiresFlushToResumeDecoding)
        XCTAssertNil(backend.error)
        XCTAssertEqual(notices.value, 0)
    }

    private func pcm() throws -> CMSampleBuffer {
        try PCMSampleBufferBuilder.make(bytes: Data(repeating: 0, count: 16), frameCount: 2,
            sampleRate: 48_000, channels: 2, channelOrder: .native, channelLayoutMask: 3,
            presentationTimeStamp: .zero)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("receiver adapter did not reach the expected state")
    }
}

private actor ControlledAudioReceiverEndpoint: AudioReceiverEndpoint {
    private(set) var operations: [String] = []
    private var enqueueContinuation: CheckedContinuation<AudioReceiverOutcome, Never>?
    private var flushContinuation: CheckedContinuation<Void, Never>?
    private var handler: (@Sendable (AudioRendererEvent) -> Void)?
    private let holdFlush: Bool

    init(holdFlush: Bool = false) { self.holdFlush = holdFlush }
    func enqueue(_ sample: RendererReceiverSample) async throws -> AudioReceiverOutcome {
        _ = sample
        operations.append("enqueue")
        return await withCheckedContinuation { enqueueContinuation = $0 }
    }
    func complete(_ outcome: AudioReceiverOutcome) {
        let continuation = enqueueContinuation
        enqueueContinuation = nil
        continuation?.resume(returning: outcome)
    }
    func flush() async {
        operations.append("flush")
        handler = nil
        if holdFlush { await withCheckedContinuation { flushContinuation = $0 } }
    }
    func completeFlush() {
        let continuation = flushContinuation
        flushContinuation = nil
        continuation?.resume()
    }
    func finishedEnqueuing(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void) {
        operations.append("observe")
        self.handler = handler
    }
    func emit(_ event: AudioRendererEvent) { handler?(event) }
    func remove(from synchronizer: AVSampleBufferRenderSynchronizer, at time: CMTime) async -> Bool {
        _ = synchronizer; _ = time
        operations.append("remove")
        return true
    }
}

private actor ControlledVideoReceiverEndpoint: VideoReceiverEndpoint {
    private(set) var operations: [String] = []
    private(set) var flushImageClears: [Bool] = []
    private var continuation: CheckedContinuation<VideoReceiverOutcome, Never>?
    private var flushContinuation: CheckedContinuation<Void, Never>?
    private let holdFlush: Bool
    init(holdFlush: Bool = false) { self.holdFlush = holdFlush }
    func enqueue(_ sample: RendererReceiverSample) async throws -> VideoReceiverOutcome {
        _ = sample
        operations.append("enqueue")
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ result: VideoReceiverOutcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
    func flush(removeDisplayedImage: Bool) async {
        operations.append("flush")
        flushImageClears.append(removeDisplayedImage)
        if holdFlush { await withCheckedContinuation { flushContinuation = $0 } }
    }
    func completeFlush() {
        let pending = flushContinuation
        flushContinuation = nil
        pending?.resume()
    }
    func finishedEnqueuing(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void) {
        _ = handler; operations.append("observe")
    }
    func remove(from synchronizer: AVSampleBufferRenderSynchronizer) async -> Bool {
        _ = synchronizer; operations.append("remove"); return true
    }
}

private final class NativeAdapterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class NativeSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didAccept = false
    private var failure = "no native completion"
    var accepted: Bool { lock.withLock { didAccept } }
    var description: String { lock.withLock { failure } }
    func record(_ result: Result<VideoRendererEnqueueResult, any Error>) {
        lock.withLock {
            switch result {
            case .success(.accepted): didAccept = true; failure = "accepted"
            case .success(.cancelled): failure = "cancelled"
            case .success(.requiresRecovery): failure = "requires renderer recovery"
            case let .failure(error): failure = String(describing: error)
            }
        }
    }
}

private final class NativeControlResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.withLock { stored } }
    func record(_ value: Bool) { lock.withLock { stored.append(value) } }
}

/// Shared by the generated PCM test and the real demux/assembler AAC fixture test.
/// This checks native Receiver acceptance and ownership, not audible playback.
@MainActor
enum NativeAudioReceiverSmoke {
    static func assertLifecycle(samples: [CMSampleBuffer], mediaKind: AudioRendererMediaKind) async throws {
        XCTAssertEqual(samples.count, 3)
        guard samples.count == 3 else { throw SmokeFailure.invalidSamples }
        for sample in samples {
            XCTAssertTrue(CMSampleBufferDataIsReady(sample))
            XCTAssertGreaterThan(CMSampleBufferGetNumSamples(sample), 0)
            XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
        }
        let ownership = try await exercise(samples: samples, mediaKind: mediaKind)
        try await waitUntil("adapter and native renderer ownership released after removal") {
            ownership.adapter == nil && ownership.renderer == nil
        }
    }

    private static func exercise(samples: [CMSampleBuffer], mediaKind: AudioRendererMediaKind)
        async throws -> WeakAudioRendererProbe {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let synchronization = SystemAudioSynchronizer(synchronizer)
        let renderer = SystemAudioRenderer(identity: .init(rawValue: 100), mediaKind: mediaKind)
        let ownership = WeakAudioRendererProbe(renderer)
        let ready = NativeAdapterCounter()
        let events = NativeAudioSmokeEvents()
        XCTAssertFalse(renderer.isReadyForMoreMediaData, "Unattached renderer has no native Receiver")
        try synchronization.attach(renderer)
        // A paused clock keeps the three tiny submissions bounded. These
        // assertions require neither clock advancement nor audible playback.
        synchronization.setRate(0, time: CMSampleBufferGetPresentationTimeStamp(samples[0]))
        XCTAssertTrue(renderer.isReadyForMoreMediaData)
        renderer.startObserving(events.record)
        renderer.requestMediaDataWhenReady { ready.increment() }

        var lifecycleFailure: (any Error)?
        do {
            try await enqueue(samples[0], into: renderer, ready: ready, stage: "first native audio acceptance")
            let beforeEOF = ready.value
            renderer.finishedEnqueuing()
            try await waitUntil("native EOF registration control worker completion") {
                ready.value > beforeEOF && renderer.isReadyForMoreMediaData
            }
            // This barrier proves the real owner registered its SDK sequence.
            // The SDK exposes no first-next/suspension signal: resumed acceptance
            // exercises cancellation but is not proof of an idle-next race.
            try await enqueue(samples[1], into: renderer, ready: ready, stage: "native audio acceptance after EOF registration")
            let beforeSecondEOF = ready.value
            renderer.finishedEnqueuing()
            try await waitUntil("second native EOF registration control worker completion") {
                ready.value > beforeSecondEOF && renderer.isReadyForMoreMediaData
            }
            let beforeFlush = ready.value
            renderer.flush()
            try await waitUntil("native audio flush and event-task settlement") {
                ready.value > beforeFlush && renderer.isReadyForMoreMediaData
            }
            try await enqueue(samples[2], into: renderer, ready: ready, stage: "native audio acceptance after physical flush")
            let beforeFinalEOF = ready.value
            renderer.finishedEnqueuing()
            try await waitUntil("final native EOF registration before removal") {
                ready.value > beforeFinalEOF && renderer.isReadyForMoreMediaData
            }
        } catch { lifecycleFailure = error }

        // Removal is attempted even when enqueue/control times out. Never await
        // an SDK task directly: a stuck native iterator must remain a test failure,
        // rather than trapping XCTest in an unbounded task-group join.
        let removed = XCTestExpectation(description: "SDK audio Receiver removal completes")
        let removals = NativeControlResults()
        synchronization.remove(renderer, at: .invalid) { success in
            removals.record(success)
            removed.fulfill()
        }
        let removalWait = await XCTWaiter.fulfillment(of: [removed], timeout: 3)
        renderer.stopRequestingMediaData()
        renderer.stopObserving()
        XCTAssertEqual(removalWait, .completed, "Native audio Receiver removal timed out")
        XCTAssertEqual(removals.values, [true], "SDK must confirm physical Receiver removal exactly once")
        XCTAssertFalse(renderer.isReadyForMoreMediaData, "Detached Receiver cannot admit more samples")
        XCTAssertNil(events.failure, "Native audio Receiver failed: \(events.failure ?? "")")
        if let lifecycleFailure { throw lifecycleFailure }
        guard removalWait == .completed, removals.values == [true] else { throw SmokeFailure.removal }
        return ownership
    }

    private static func enqueue(_ sample: CMSampleBuffer, into renderer: SystemAudioRenderer,
        ready: NativeAdapterCounter, stage: String) async throws {
        let beforeEnqueue = ready.value
        let completed = XCTestExpectation(description: stage)
        let result = NativeAudioSmokeResult()
        renderer.enqueue(sample) { outcome in result.record(outcome); completed.fulfill() }
        let wait = await XCTWaiter.fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(wait, .completed, "\(stage) timed out")
        XCTAssertTrue(result.accepted, "\(stage): \(result.description)")
        guard wait == .completed, result.accepted else { throw SmokeFailure.enqueue }
        // Completion is delivered before the feed's readiness callback. Settle
        // that callback so it cannot satisfy the next EOF/control barrier.
        try await waitUntil("\(stage) readiness callback") {
            ready.value > beforeEnqueue && renderer.isReadyForMoreMediaData
        }
    }

    private static func waitUntil(_ stage: String, condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(stage)")
        throw SmokeFailure.timeout
    }

    private enum SmokeFailure: Error { case invalidSamples, enqueue, removal, timeout }

    @MainActor
    private final class WeakAudioRendererProbe {
        weak var adapter: SystemAudioRenderer?
        weak var renderer: AVSampleBufferAudioRenderer?
        init(_ adapter: SystemAudioRenderer) {
            self.adapter = adapter
            renderer = adapter.renderer
        }
    }
}

private final class NativeAudioSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didAccept = false
    private var summary = "no native completion"
    var accepted: Bool { lock.withLock { didAccept } }
    var description: String { lock.withLock { summary } }
    func record(_ result: Result<AudioRendererEnqueueResult, any Error>) {
        lock.withLock {
            switch result {
            case let .success(value): didAccept = value.isAccepted; summary = String(describing: value)
            case let .failure(error): summary = String(describing: error)
            }
        }
    }
}

private final class NativeAudioSmokeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: String?
    var failure: String? { lock.withLock { firstFailure } }
    func record(_ event: AudioRendererEvent) {
        lock.withLock {
            switch event {
            case let .failed(reason), let .failedWithDiagnostic(reason, _):
                if firstFailure == nil { firstFailure = reason }
            case .automaticFlush, .outputConfigurationChanged: break
            }
        }
    }
}
