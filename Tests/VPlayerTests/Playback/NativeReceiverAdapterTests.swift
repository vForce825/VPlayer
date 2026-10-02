// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeReceiverAdapterTests: XCTestCase {
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
        backend.flush(removeDisplayedImage: true) { flushCount.increment(); flushed.fulfill() }
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
        renderer.enqueue(try pcm()) { _ in }
        try await eventually { await endpoint.operations == ["observe", "flush"] }
        await endpoint.completeFlush()
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
        try await eventually { renderer.isReadyForMoreMediaData }
        renderer.enqueue(try pcm()) { _ in }
        let beforeFlushSettlement = await endpoint.operations
        XCTAssertEqual(beforeFlushSettlement, ["enqueue", "flush"])
        await endpoint.completeFlush()
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
        backend.flush(removeDisplayedImage: false) { flushed.increment() }
        try await eventually { await endpoint.operations.contains("flush") }
        XCTAssertEqual(flushed.value, 0)
        await endpoint.complete(.init(result: .requiresRecovery(.failed(
            NSError(domain: "OldReceiver", code: -1))), events: []))
        try await eventually { flushed.value == 1 }
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
    private var continuation: CheckedContinuation<VideoReceiverOutcome, Never>?
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
    func flush(removeDisplayedImage: Bool) { _ = removeDisplayedImage; operations.append("flush") }
    func finishedEnqueuing(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void) { _ = handler }
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
