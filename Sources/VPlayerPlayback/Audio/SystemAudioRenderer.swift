// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Dispatch
import Foundation
import VPlayerCore

final class SystemAudioRenderer: AudioRenderer, @unchecked Sendable {
    let identity: AudioRendererIdentity
    let mediaKind: AudioRendererMediaKind
    let renderer: AVSampleBufferAudioRenderer

    private let stateLock = NSLock()
    private var receiverOwner: (any AudioReceiverEndpoint)?
    private var feedTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var detachedResult: Bool?
    private var removalInFlight = false
    private var removalWaiters: [@Sendable (Bool) -> Void] = []
    private var readyHandler: (@Sendable () -> Void)?
    private var eventHandler: (@Sendable (AudioRendererEvent) -> Void)?
    private let failureLock = NSLock()
    private var firstFailureEvent: AudioRendererEvent?

    init(identity: AudioRendererIdentity, mediaKind: AudioRendererMediaKind,
        renderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer(),
        notificationCenter: NotificationCenter = .default,
        receiverEndpoint: (any AudioReceiverEndpoint)? = nil) {
        self.identity = identity
        self.mediaKind = mediaKind
        self.renderer = renderer
        receiverOwner = receiverEndpoint
        _ = notificationCenter
    }

    deinit { feedTask?.cancel(); controlTask?.cancel() }

    // Receiver suspension supplies backpressure. This reports the capacity of
    // our single submission slot, never the deprecated renderer readiness flag.
    var isReadyForMoreMediaData: Bool {
        stateLock.withLock { receiverOwner != nil && feedTask == nil }
    }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { false }
    var canObserveConsumption: Bool { false }

    func attach(to synchronizer: AVSampleBufferRenderSynchronizer) {
        let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        let owner = AudioReceiverOwner(receiver: receiver)
        stateLock.withLock { receiverOwner = owner }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
        completion: @escaping @Sendable (Result<AudioRendererEnqueueResult, any Error>) -> Void) {
        let formatID = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map(CMFormatDescriptionGetMediaSubType) ?? 0
        guard (formatID == kAudioFormatLinearPCM) == (mediaKind == .linearPCM) else {
            completion(.failure(PlaybackCoreError.audioRendererFailed("renderer.media-kind")))
            return
        }
        let sample = RendererReceiverSample(buffer: sampleBuffer)
        let started = stateLock.withLock { () -> Bool in
            guard let owner = receiverOwner, feedTask == nil else { return false }
            let barrier = controlTask
            let submissionRevision = revision
            feedTask = Task { [weak self] in
                await barrier?.value
                let result: Result<AudioReceiverOutcome, any Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await owner.enqueue(sample))
                } catch is CancellationError {
                    result = .success(.init(result: .cancelled, events: []))
                } catch { result = .failure(error) }
                if case let .success(outcome) = result,
                   outcome.events.contains(where: { event in
                       if case .automaticFlush = event { return true }
                       return false
                   }) {
                    // Only an actual automatic-flush reason requires this
                    // immediate physical barrier. Configuration-only suggestions
                    // stay under the pipeline's coalescing/replay policy.
                    // The accepted sample remains accepted. Keep the sole feed
                    // slot occupied until the SDK-required flush has settled;
                    // an acceptance callback may synchronously submit the next sample.
                    await owner.flush()
                }
                guard let self else { return }
                let state = stateLock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
                    feedTask = nil
                    return (revision == submissionRevision, readyHandler)
                }
                if state.0 {
                    switch result {
                    case let .success(outcome):
                        completion(.success(outcome.result))
                        for event in outcome.events { emit(event, revision: submissionRevision) }
                    case let .failure(error): completion(.failure(error))
                    }
                } else { completion(.success(.cancelled)) }
                state.1?()
            }
            return true
        }
        if !started { completion(.success(.backpressured)) }
    }

    func cancelPendingEnqueue() {
        let pending = stateLock.withLock { () -> Bool in
            guard let feedTask else { return false }
            feedTask.cancel()
            return true
        }
        if pending { flush() }
    }

    func flush() {
        stateLock.withLock {
            guard let owner = receiverOwner else { return }
            revision += 1
            feedTask?.cancel()
            let previous = controlTask
            let feed = feedTask
            controlTask = Task {
                await previous?.value
                await owner.flush()
                await feed?.value
            }
        }
    }

    func finishedEnqueuing() {
        stateLock.withLock {
            guard let owner = receiverOwner, feedTask == nil else { return }
            let previous = controlTask
            let eventRevision = revision
            controlTask = Task { [weak self] in
                await previous?.value
                await owner.finishedEnqueuing { [weak self] event in
                    self?.receiveRenderingEvent(event, revision: eventRevision)
                }
            }
        }
    }

    func remove(from synchronizer: AVSampleBufferRenderSynchronizer, at time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void) {
        let settled = stateLock.withLock { () -> Bool? in
            if let detachedResult { return detachedResult }
            if removalInFlight { removalWaiters.append(completion); return nil }
            guard let owner = receiverOwner else { return false }
            removalInFlight = true
            removalWaiters.append(completion)
            revision += 1
            receiverOwner = nil
            feedTask?.cancel()
            let previous = controlTask
            let feed = feedTask
            controlTask = Task {
                await previous?.value
                await owner.flush()
                await feed?.value
                let result = await owner.remove(from: synchronizer, at: time)
                let waiters = self.stateLock.withLock {
                    self.detachedResult = result
                    self.removalInFlight = false
                    let waiters = self.removalWaiters
                    self.removalWaiters.removeAll()
                    return waiters
                }
                for waiter in waiters { waiter(result) }
            }
            return nil
        }
        if let settled { completion(settled) }
    }

    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void) {
        stateLock.withLock { readyHandler = handler }
    }
    func stopRequestingMediaData() { stateLock.withLock { readyHandler = nil } }
    func startObserving(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void) {
        stateLock.withLock { eventHandler = handler }
    }
    func stopObserving() { stateLock.withLock { eventHandler = nil } }
    private func receiveRenderingEvent(_ event: AudioRendererEvent, revision expected: UInt64) {
        let deliveryRevision = stateLock.withLock { () -> UInt64? in
            guard revision == expected, let owner = receiverOwner else { return nil }
            if case .automaticFlush = event {
                // Close admission synchronously with receipt of the native event.
                // Resumed producers wait for this barrier even before the
                // playback executor has processed the recovery notice.
                revision += 1
                feedTask?.cancel()
                let previous = controlTask
                let feed = feedTask
                controlTask = Task {
                    await previous?.value
                    await owner.flush()
                    await feed?.value
                }
            }
            return revision
        }
        if let deliveryRevision { emit(event, revision: deliveryRevision) }
    }

    private func emit(_ event: AudioRendererEvent, revision expected: UInt64) {
        let value: AudioRendererEvent
        if case .failedWithDiagnostic = event {
            value = failureLock.withLock {
                if let firstFailureEvent { return firstFailureEvent }
                firstFailureEvent = event
                return event
            }
        } else { value = event }
        stateLock.withLock { revision == expected ? eventHandler : nil }?(value)
    }

    /// 首错属于真实 renderer 实例；监听重绑不为同一失败实例重建诊断实体。
    func recordedFailureEvent(_ error: (any Error)?) -> AudioRendererEvent {
        failureLock.lock()
        defer { failureLock.unlock() }
        if let firstFailureEvent { return firstFailureEvent }
        let event = Self.failureEvent(error)
        firstFailureEvent = event
        return event
    }

    static func failureEvent(_ error: (any Error)?) -> AudioRendererEvent {
        guard let error else {
            return .failedWithDiagnostic(reason: "AVFoundation:unknown", diagnostic: .init(
                typeName: "AVSampleBufferAudioRenderer", code: "error-unavailable",
                message: "系统报告音频渲染器失败，但未提供错误详情。"))
        }
        let value = error as NSError
        // 先截取借用的 NSString，避免为旧 metrics 复制未知长度的原始域。
        let selector = #selector(getter: NSError.domain)
        let borrowedDomain = value.responds(to: selector)
            ? value.perform(selector)?.takeUnretainedValue() as? NSString : nil
        let domain = borrowedDomain?.substring(to: min(borrowedDomain?.length ?? 0, 96)) ?? "unknown"
        return .failedWithDiagnostic(reason: "\(domain):\(value.code)", diagnostic: .init(error))
    }
}

final class SystemAudioRendererFactory: AudioRendererFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var nextIdentity: UInt64? = 1

    func makeRenderer(mediaKind: AudioRendererMediaKind) throws -> any AudioRenderer {
        let identity: UInt64? = withLock {
            guard let current = nextIdentity else { return nil }
            nextIdentity = current == UInt64.max ? nil : current + 1
            return current
        }
        guard let identity else {
            throw PlaybackCoreError.audioRendererFailed("renderer.identity-exhausted")
        }
        return SystemAudioRenderer(
            identity: AudioRendererIdentity(rawValue: identity),
            mediaKind: mediaKind
        )
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class SystemAudioSynchronizer: AudioRenderSynchronizing, @unchecked Sendable {
    let synchronizer: AVSampleBufferRenderSynchronizer

    init(_ synchronizer: AVSampleBufferRenderSynchronizer) {
        self.synchronizer = synchronizer
    }

    func currentTime() -> CMTime { synchronizer.currentTime() }
    var rate: Float { synchronizer.rate }

    func attach(_ renderer: any AudioRenderer) throws {
        guard let renderer = renderer as? SystemAudioRenderer else {
            throw PlaybackCoreError.audioRendererFailed("audio.renderer.type-mismatch")
        }
        renderer.attach(to: synchronizer)
    }

    func remove(
        _ renderer: any AudioRenderer,
        at time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let renderer = renderer as? SystemAudioRenderer else {
            completion(false)
            return
        }
        renderer.remove(from: synchronizer, at: time, completion: completion)
    }

    func setRate(_ rate: Float, time: CMTime) {
        synchronizer.setRate(rate, time: time)
    }
}

/// One actor owns the non-Sendable Receiver. The operation task is cancelled and
/// physically settled before flushing/removal admits a later submission.
struct AudioReceiverOutcome: Sendable {
    let result: AudioRendererEnqueueResult
    let events: [AudioRendererEvent]
}

/// Injectable ownership boundary: the real Receiver stays actor-confined.
/// Fakes can suspend physical operations without making the SDK Receiver Sendable.
protocol AudioReceiverEndpoint: Actor {
    func enqueue(_ sample: RendererReceiverSample) async throws -> AudioReceiverOutcome
    func flush() async
    func finishedEnqueuing(_ eventSink: @escaping @Sendable (AudioRendererEvent) -> Void) async
    func remove(from synchronizer: AVSampleBufferRenderSynchronizer, at time: CMTime) async -> Bool
}

private actor AudioReceiverOwner: AudioReceiverEndpoint {
    private var receiver: AVSampleBufferAudioRenderer.Receiver?
    private var isEnqueuing = false
    private var events: Task<Void, Never>?
    init(receiver: sending AVSampleBufferAudioRenderer.Receiver) { self.receiver = receiver }

    func enqueue(_ sample: RendererReceiverSample) async throws -> AudioReceiverOutcome {
        await stopEvents()
        guard !isEnqueuing, receiver != nil else { return .init(result: .cancelled, events: []) }
        isEnqueuing = true
        defer { isEnqueuing = false }
        return try await performEnqueue(sample)
    }

    private func performEnqueue(_ sample: RendererReceiverSample) async throws -> AudioReceiverOutcome {
        guard let receiver else { return .init(result: .cancelled, events: []) }
        try Task.checkCancellation()
        let ready = try sample.makeReady()
        do {
            return try await enqueueReady(ready, into: receiver)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(result: .cancelled, events: [SystemAudioRenderer.failureEvent(error)])
        }
    }

    private func enqueueReady(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
        into receiver: AVSampleBufferAudioRenderer.Receiver) async throws -> AudioReceiverOutcome {
        switch try await receiver.enqueue(sample) {
        case .enqueued: return .init(result: .accepted, events: [])
        case let .enqueuedWithSuggestedFlush(reasons):
            let notices: [AudioRendererEvent] = reasons.compactMap { reason in
                switch reason {
                case .outputConfigurationChanged: .outputConfigurationChanged
                case let .wasFlushedAutomatically(at: time): .automaticFlush(time)
                @unknown default: nil
                }
            }
            return .init(result: .acceptedWithSuggestedFlush, events: notices)
        case .cancelledDueToFlush: return .init(result: .cancelled, events: [])
        case let .cancelledDueToError(error):
            return .init(result: .cancelled, events: [SystemAudioRenderer.failureEvent(error)])
        @unknown default:
            throw PlaybackCoreError.audioRendererFailed("renderer.unknown-enqueue-result")
        }
    }

    func flush() async {
        await stopEvents()
        receiver?.flush()
    }

    func finishedEnqueuing(_ eventSink: @escaping @Sendable (AudioRendererEvent) -> Void) {
        guard !isEnqueuing, events == nil, let receiver else { return }
        let sequence = receiver.renderingEventsAfterFinishedEnqueuing
        events = Task { [eventSink] in
            for await event in sequence {
                guard !Task.isCancelled else { break }
                switch event {
                case .outputConfigurationChanged: eventSink(.outputConfigurationChanged)
                case let .wasFlushedAutomatically(at: time): eventSink(.automaticFlush(time))
                case let .failed(error): eventSink(SystemAudioRenderer.failureEvent(error))
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

    func remove(from synchronizer: AVSampleBufferRenderSynchronizer, at time: CMTime) async -> Bool {
        await flush()
        guard let value = receiver else { return false }
        receiver = nil
        // Both tasks have physically settled and the actor released its only
        // stored alias. The compiler cannot express this detached property region.
        nonisolated(unsafe) let removed = value
        return await synchronizer.removeReceiver(removed, at: time)
    }
}
