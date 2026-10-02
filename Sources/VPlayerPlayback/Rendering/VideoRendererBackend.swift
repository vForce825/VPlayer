// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Dispatch
import Foundation

enum VideoRendererBackendEvent: @unchecked Sendable {
    case failed(any Error)
    case decodeFailure(any Error)
    case requiresFlushToResumeDecoding
}

/// Application-owned projection of Receiver results/events. This says whether
/// a failure is known; it does not claim that a frame was rendered or displayed.
enum VideoRendererHealth: Sendable, Equatable {
    case noKnownFailure
    case failed
}

enum VideoRendererEnqueueResult: Sendable {
    case accepted
    case cancelled
    case requiresRecovery(VideoRendererBackendEvent)
}

struct VideoRendererPerformanceSnapshot: Sendable, Equatable {
    let totalFrameCount: UInt64
    let droppedFrameCount: UInt64
    let corruptedFrameCount: UInt64
    let optimizedFrameCount: UInt64
    let accumulatedFrameDelaySeconds: Double
}

protocol SampleBufferVideoRenderingBackend: AnyObject, Sendable {
    var isReadyForMoreMediaData: Bool { get }
    var health: VideoRendererHealth { get }
    var error: (any Error)? { get }
    var requiresFlushToResumeDecoding: Bool { get }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
        completion: @escaping @Sendable (Result<VideoRendererEnqueueResult, any Error>) -> Void)
    func cancelPendingEnqueue()
    func finishedEnqueuing()
    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    )
    func stopRequestingMediaData()
    func flush(
        removeDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    )
    func loadPerformanceMetrics(
        completion: @escaping @Sendable (VideoRendererPerformanceSnapshot?) -> Void
    )
    func startObserving(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void)
    func stopObserving()
}

final class VideoRendererBackend: SampleBufferVideoRenderingBackend, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer

    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let owner: any VideoReceiverEndpoint
    private let lock = NSLock()
    private var feedTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var readiness: (@Sendable () -> Void)?
    private var eventHandler: (@Sendable (VideoRendererBackendEvent) -> Void)?
    private var observedError: (any Error)?
    private var flushRequired = false
    private var removed = false
    private var removalResult: Bool?
    private var removalInFlight = false
    private var removalWaiters: [@Sendable (Bool) -> Void] = []
    private var revision: UInt64 = 0

    init(renderer: AVSampleBufferVideoRenderer, synchronizer: AVSampleBufferRenderSynchronizer,
        receiverEndpoint: (any VideoReceiverEndpoint)? = nil) {
        self.renderer = renderer
        self.synchronizer = synchronizer
        if let receiverEndpoint { owner = receiverEndpoint }
        else { owner = VideoReceiverOwner(receiver: synchronizer.sampleBufferReceiver(adding: renderer)) }
    }

    deinit { feedTask?.cancel(); controlTask?.cancel() }

    var isReadyForMoreMediaData: Bool { lock.withLock { !removed && feedTask == nil && !flushRequired && observedError == nil } }
    var health: VideoRendererHealth {
        lock.withLock { observedError == nil ? .noKnownFailure : .failed }
    }
    var error: (any Error)? { lock.withLock { observedError } }
    var requiresFlushToResumeDecoding: Bool { lock.withLock { flushRequired } }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
        completion: @escaping @Sendable (Result<VideoRendererEnqueueResult, any Error>) -> Void) {
        let sample = RendererReceiverSample(buffer: sampleBuffer)
        let started = lock.withLock { () -> Bool in
            guard !removed, feedTask == nil else { return false }
            let barrier = controlTask
            let submissionRevision = revision
            feedTask = Task { [weak self, owner] in
                await barrier?.value
                let outcome: Result<VideoReceiverOutcome, any Error>
                do {
                    try Task.checkCancellation()
                    outcome = .success(try await owner.enqueue(sample))
                } catch { outcome = .failure(error) }
                guard let self else { return }
                let state = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
                    feedTask = nil
                    guard revision == submissionRevision else { return (false, readiness) }
                    // Validate the revision and commit every outcome cache field
                    // atomically. A reset cannot slip between these operations.
                    if case let .success(value) = outcome,
                       case let .requiresRecovery(reason) = value.result {
                        switch reason {
                        case let .failed(error): observedError = error
                        case .requiresFlushToResumeDecoding: flushRequired = true
                        case .decodeFailure: break
                        }
                    }
                    return (true, readiness)
                }
                guard state.0 else {
                    completion(.success(.cancelled))
                    state.1?()
                    return
                }
                switch outcome {
                case let .success(value):
                    completion(.success(value.result))
                    for event in value.events { emit(event, revision: submissionRevision) }
                case let .failure(error): completion(.failure(error))
                }
                state.1?()
            }
            return true
        }
        if !started { completion(.success(.cancelled)) }
    }

    func cancelPendingEnqueue() {
        let needsCancel = lock.withLock { () -> Bool in
            guard let feedTask else { return false }
            feedTask.cancel()
            return true
        }
        if needsCancel { flush(removeDisplayedImage: false) {} }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void) {
        lock.withLock { readiness = { queue.async(execute: block) } }
    }
    func stopRequestingMediaData() { lock.withLock { readiness = nil } }

    func flush(removeDisplayedImage: Bool, completion: @escaping @Sendable () -> Void) {
        lock.withLock {
            revision += 1
            let flushRevision = revision
            feedTask?.cancel()
            let previous = controlTask
            let feed = feedTask
            controlTask = Task { [weak self, owner] in
                await previous?.value
                await owner.flush(removeDisplayedImage: removeDisplayedImage)
                await feed?.value
                if let self {
                    lock.withLock {
                        guard revision == flushRevision else { return }
                        flushRequired = false
                        observedError = nil
                    }
                }
                completion()
            }
        }
    }

    func finishedEnqueuing() {
        lock.withLock {
            let previous = controlTask
            let eventRevision = revision
            controlTask = Task { [weak self, owner] in
                await previous?.value
                await owner.finishedEnqueuing { [weak self] event in
                    self?.emit(event, revision: eventRevision)
                }
            }
        }
    }

    func remove(completion: @escaping @Sendable (Bool) -> Void) {
        let settled = lock.withLock { () -> Bool? in
            if let removalResult { return removalResult }
            removalWaiters.append(completion)
            guard !removalInFlight else { return nil }
            removalInFlight = true
            removed = true
            revision += 1
            feedTask?.cancel()
            let previous = controlTask
            let feed = feedTask
            controlTask = Task { [self, owner, synchronizer] in
                await previous?.value
                await owner.flush(removeDisplayedImage: true)
                await feed?.value
                let result = await owner.remove(from: synchronizer)
                let waiters = lock.withLock {
                    removalResult = result
                    removalInFlight = false
                    let waiters = removalWaiters
                    removalWaiters.removeAll()
                    return waiters
                }
                for waiter in waiters { waiter(result) }
            }
            return nil
        }
        if let settled { completion(settled) }
    }

    func loadPerformanceMetrics(
        completion: @escaping @Sendable (VideoRendererPerformanceSnapshot?) -> Void
    ) {
        renderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics,
                  metrics.totalNumberOfFrames >= 0,
                  metrics.numberOfDroppedFrames >= 0,
                  metrics.numberOfCorruptedFrames >= 0,
                  metrics.numberOfFramesDisplayedUsingOptimizedCompositing >= 0,
                  metrics.totalAccumulatedFrameDelay.isFinite,
                  metrics.totalAccumulatedFrameDelay >= 0 else {
                completion(nil)
                return
            }
            completion(VideoRendererPerformanceSnapshot(
                totalFrameCount: UInt64(metrics.totalNumberOfFrames),
                droppedFrameCount: UInt64(metrics.numberOfDroppedFrames),
                corruptedFrameCount: UInt64(metrics.numberOfCorruptedFrames),
                optimizedFrameCount: UInt64(
                    metrics.numberOfFramesDisplayedUsingOptimizedCompositing
                ),
                accumulatedFrameDelaySeconds: metrics.totalAccumulatedFrameDelay
            ))
        }
    }

    func startObserving(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void) {
        lock.withLock { eventHandler = handler }
    }
    func stopObserving() { lock.withLock { eventHandler = nil } }

    private func emit(_ event: VideoRendererBackendEvent, revision expected: UInt64) {
        let handler = lock.withLock { () -> (@Sendable (VideoRendererBackendEvent) -> Void)? in
            guard revision == expected else { return nil }
            switch event {
            case let .failed(error): observedError = error
            case .requiresFlushToResumeDecoding: flushRequired = true
            case .decodeFailure: break
            }
            return eventHandler
        }
        handler?(event)
    }
}

struct VideoReceiverOutcome: Sendable {
    let result: VideoRendererEnqueueResult
    let events: [VideoRendererBackendEvent]
}

protocol VideoReceiverEndpoint: Actor {
    func enqueue(_ sample: RendererReceiverSample) async throws -> VideoReceiverOutcome
    func flush(removeDisplayedImage: Bool) async
    func finishedEnqueuing(_ eventSink: @escaping @Sendable (VideoRendererBackendEvent) -> Void) async
    func remove(from synchronizer: AVSampleBufferRenderSynchronizer) async -> Bool
}

private actor VideoReceiverOwner: VideoReceiverEndpoint {
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var isEnqueuing = false
    private var events: Task<Void, Never>?

    init(receiver: sending AVSampleBufferVideoRenderer.Receiver) { self.receiver = receiver }

    func enqueue(_ sample: RendererReceiverSample) async throws -> VideoReceiverOutcome {
        await stopEvents()
        guard !isEnqueuing, receiver != nil else { throw CancellationError() }
        isEnqueuing = true
        defer { isEnqueuing = false }
        return try await performEnqueue(sample)
    }

    private func performEnqueue(_ sample: RendererReceiverSample) async throws -> VideoReceiverOutcome {
        guard let receiver else { throw CancellationError() }
        try Task.checkCancellation()
        let ready = try sample.makeReady()
        do {
            return try await enqueueReady(ready, into: receiver)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(result: .requiresRecovery(.failed(error)), events: [])
        }
    }

    private func enqueueReady(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
        into receiver: AVSampleBufferVideoRenderer.Receiver) async throws -> VideoReceiverOutcome {
        switch try await receiver.enqueue(sample) {
        case .enqueued: return .init(result: .accepted, events: [])
        case let .enqueuedWithDecodeFailures(errors):
            return .init(result: .accepted, events: errors.map { .decodeFailure($0) })
        case .cancelledDueToFlush: return .init(result: .cancelled, events: [])
        case .cancelledDueToFlushRequiredToResume:
            return .init(result: .requiresRecovery(.requiresFlushToResumeDecoding), events: [])
        case let .cancelledDueToError(error):
            return .init(result: .requiresRecovery(.failed(error)), events: [])
        @unknown default: throw CancellationError()
        }
    }

    func flush(removeDisplayedImage: Bool) async {
        await stopEvents()
        await receiver?.flush(removingDisplayedImage: removeDisplayedImage)
    }

    func finishedEnqueuing(_ eventSink: @escaping @Sendable (VideoRendererBackendEvent) -> Void) {
        guard !isEnqueuing, events == nil, let receiver else { return }
        let sequence = receiver.renderingEventsAfterFinishedEnqueuing
        events = Task {
            for await event in sequence {
                guard !Task.isCancelled else { break }
                switch event {
                case let .didFailToDecode(errors):
                    for error in errors { eventSink(.decodeFailure(error)) }
                case .requiresFlushToResumeDecoding: eventSink(.requiresFlushToResumeDecoding)
                case let .failed(error): eventSink(.failed(error))
                @unknown default: break
                }
            }
        }
    }

    private func stopEvents() async {
        let previous = events
        events = nil
        previous?.cancel()
        await previous?.value
    }

    func remove(from synchronizer: AVSampleBufferRenderSynchronizer) async -> Bool {
        await flush(removeDisplayedImage: true)
        guard let value = receiver else { return false }
        receiver = nil
        // Enqueue and event tasks have settled; no actor-owned alias remains.
        nonisolated(unsafe) let removed = value
        return await synchronizer.removeReceiver(removed, at: .invalid)
    }
}
