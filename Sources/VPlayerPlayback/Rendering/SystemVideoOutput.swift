// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Dispatch
import Foundation

struct VideoEnqueueReceipt: Sendable, Equatable {
    let generation: MediaGeneration
    let sequenceNumbers: Set<UInt64>
}

struct VideoRendererResetRequest: @unchecked Sendable {
    enum Reason: Sendable {
        case timelineDiscontinuity
        case audioGap
        case decoderRecovery
        case stop
        case failure
    }

    let generation: MediaGeneration
    let reason: Reason
    let removeDisplayedImage: Bool
    let seedFrames: [VideoPresentationFrame]
    // nil 表示保留当前偏移；共享时钟重新锚定时传入新路由对应的值。
    let presentationTimeOffset: CMTime?

    init(
        generation: MediaGeneration,
        reason: Reason,
        removeDisplayedImage: Bool,
        seedFrames: [VideoPresentationFrame],
        presentationTimeOffset: CMTime? = nil
    ) {
        self.generation = generation
        self.reason = reason
        self.removeDisplayedImage = removeDisplayedImage
        self.seedFrames = seedFrames
        self.presentationTimeOffset = presentationTimeOffset
    }
}

final class SystemVideoOutput: @unchecked Sendable {
    typealias Acceptance = @Sendable (Result<VideoEnqueueReceipt, PlaybackCoreError>) -> Void
    typealias RendererRemoval = @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    private struct PendingFrame {
        let frame: VideoPresentationFrame
        let acceptanceID: UInt64?
    }

    private struct PendingAcceptance {
        let generation: MediaGeneration
        let allSequenceNumbers: Set<UInt64>
        var remaining: Set<UInt64>
        let completion: Acceptance
    }

    private struct ResetTransaction {
        let id: UInt64
        let request: VideoRendererResetRequest
        let completion: Acceptance
    }

    private let backend: any SampleBufferVideoRenderingBackend
    private let ledger: VideoSurfaceBudgetLedger
    private let metrics: PlaybackMetrics?
    private let builder = VideoImageSampleBufferBuilder()
    private let removeRenderer: RendererRemoval
    private let recoverySink: @Sendable (MediaGeneration) -> Void
    private let failureSink: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    private let stateQueue = DispatchQueue(
        label: "org.vplayer.playback.video.system-output",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()

    // All mutable properties are stateQueue-isolated.
    private var generation = MediaGeneration(rawValue: 0)
    private var presentationTimeOffset = CMTime.zero
    private var pending: [PendingFrame] = []
    private var acceptances: [UInt64: PendingAcceptance] = [:]
    private var nextAcceptanceID: UInt64 = 1
    private var nextResetID: UInt64 = 1
    private var nextFlushOperationID: UInt64 = 1
    private var stopFlushOperationID: UInt64 = 0
    private var requestToken: UInt64 = 0
    private var requestArmed = false
    private var inFlightFlush: (operationID: UInt64, transaction: ResetTransaction)?
    private var pendingReset: ResetTransaction?
    private var stopped = false
    private var stopFlushInProgress = false
    private var rendererRemovalCompleted = false
    private var rendererRemovalInFlight = false
    private var rendererRemovalAttempt = 0
    private var rendererRemovalToken: UInt64 = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryRequestInFlight = false
    private var recoveryCompletedWithoutProgress = false
    private var performanceMetricsRequestInFlight = false
    private var performanceMetricsRequestToken: UInt64 = 0

    init(
        backend: any SampleBufferVideoRenderingBackend,
        ledger: VideoSurfaceBudgetLedger = VideoSurfaceBudgetLedger(),
        metrics: PlaybackMetrics? = nil,
        removeRenderer: @escaping RendererRemoval,
        recoverySink: @escaping @Sendable (MediaGeneration) -> Void = { _ in },
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) {
        self.backend = backend
        self.ledger = ledger
        self.metrics = metrics
        self.removeRenderer = removeRenderer
        self.recoverySink = recoverySink
        self.failureSink = failureSink
        stateQueue.setSpecific(key: queueKey, value: 1)
        backend.startObserving { [weak self] event in
            self?.stateQueue.async { [weak self] in self?.handleBackendEventIsolated(event) }
        }
    }

    convenience init(
        renderer: AVSampleBufferVideoRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer,
        ledger: VideoSurfaceBudgetLedger = VideoSurfaceBudgetLedger(),
        metrics: PlaybackMetrics? = nil,
        recoverySink: @escaping @Sendable (MediaGeneration) -> Void,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) {
        let removal = SystemVideoRendererRemoval(
            renderer: renderer,
            synchronizer: synchronizer
        )
        self.init(
            backend: VideoRendererBackend(renderer: renderer),
            ledger: ledger,
            metrics: metrics,
            removeRenderer: removal.remove,
            recoverySink: recoverySink,
            failureSink: failureSink
        )
    }

    func enqueue(_ frame: VideoPresentationFrame) {
        enqueue([frame]) { _ in }
    }

    func enqueue(_ frames: [VideoPresentationFrame], acceptance: @escaping Acceptance) {
        stateQueue.async { [self] in
            guard !stopped else {
                acceptance(.failure(.videoRendererFailed("renderer.stopped")))
                return
            }
            guard !frames.isEmpty else {
                acceptance(.success(VideoEnqueueReceipt(
                    generation: generation,
                    sequenceNumbers: []
                )))
                return
            }
            let frameGeneration = frames[0].generation
            guard frames.allSatisfy({ $0.generation == frameGeneration }),
                  frameGeneration == generation else {
                acceptance(.failure(.videoRendererFailed("renderer.generation")))
                return
            }
            let acceptanceID = allocateAcceptanceIDIsolated()
            let sequenceNumbers = Set(frames.map(\.sequenceNumber))
            acceptances[acceptanceID] = PendingAcceptance(
                generation: frameGeneration,
                allSequenceNumbers: sequenceNumbers,
                remaining: sequenceNumbers,
                completion: acceptance
            )
            for frame in frames {
                guard acceptances[acceptanceID] != nil else { break }
                insertIsolated(frame, acceptanceID: acceptanceID)
            }
            finishEmptyAcceptanceIsolated(acceptanceID)
            guard inFlightFlush == nil, pendingReset == nil else { return }
            armRequestIfNeededIsolated()
            drainIsolated(token: requestToken)
        }
    }

    func reset(_ request: VideoRendererResetRequest, completion: @escaping Acceptance) {
        stateQueue.async { [self] in
            guard !stopped else {
                completion(.failure(.videoRendererFailed("renderer.stopped")))
                return
            }
            if let offset = request.presentationTimeOffset,
               !offset.isNumeric || CMTimeCompare(offset, .zero) < 0 {
                completion(.failure(.videoRendererFailed("renderer.presentation-offset")))
                return
            }
            let transaction = ResetTransaction(
                id: allocateResetIDIsolated(),
                request: request,
                completion: completion
            )
            if let replaced = pendingReset {
                finishResetIsolated(
                    replaced,
                    result: .failure(.videoRendererFailed("renderer.reset-superseded"))
                )
            }
            if inFlightFlush != nil {
                generation = request.generation
                clearPendingIsolated(reason: "renderer.reset-superseded")
                pendingReset = transaction
            } else {
                startResetIsolated(transaction, clearPending: true)
            }
        }
    }

    func flush(to generation: MediaGeneration) {
        reset(VideoRendererResetRequest(
            generation: generation,
            reason: .timelineDiscontinuity,
            removeDisplayedImage: true,
            seedFrames: []
        )) { _ in }
    }

    func advanceDecoderGeneration(to generation: MediaGeneration) {
        stateQueue.async { [self] in
            guard !stopped else { return }
            self.generation = generation
        }
    }

    func resetPresentationTiming() {
        // The shared AVSampleBufferRenderSynchronizer is the only clock.
    }

    func refreshPerformanceMetrics() {
        stateQueue.async { [self] in
            guard !stopped, !performanceMetricsRequestInFlight else { return }
            performanceMetricsRequestInFlight = true
            performanceMetricsRequestToken &+= 1
            let token = performanceMetricsRequestToken
            backend.loadPerformanceMetrics { [weak self] snapshot in
                self?.stateQueue.async { [weak self] in
                    guard let self,
                          !stopped,
                          performanceMetricsRequestInFlight,
                          performanceMetricsRequestToken == token else { return }
                    performanceMetricsRequestInFlight = false
                    if let snapshot {
                        metrics?.recordVideoRendererPerformance(snapshot)
                    }
                }
            }
        }
    }

    func stopAwaitingRendererRemoval() async {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                if rendererRemovalCompleted {
                    continuation.resume()
                    return
                }
                stopWaiters.append(continuation)
                guard !stopped else { return }
                stopped = true
                performanceMetricsRequestToken &+= 1
                performanceMetricsRequestInFlight = false
                stopRequestIsolated()
                backend.stopObserving()
                clearPendingIsolated(reason: "renderer.stopped")
                if let pendingReset {
                    finishResetIsolated(
                        pendingReset,
                        result: .failure(.videoRendererFailed("renderer.stopped"))
                    )
                }
                pendingReset = nil
                startStopFlushIsolated()
                stateQueue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                    guard let self, stopped, !rendererRemovalCompleted else { return }
                    finishStopIsolated()
                }
            }
        }
    }

    private func insertIsolated(_ frame: VideoPresentationFrame, acceptanceID: UInt64?) {
        guard frame.generation == generation else {
            rejectIsolated(frame, acceptanceID: acceptanceID, reason: "renderer.generation")
            return
        }
        while !ledger.retain(frame) {
            guard let tail = pending.last,
                  Self.precedes(frame, tail.frame) else {
                rejectIsolated(
                    frame,
                    acceptanceID: acceptanceID,
                    reason: "renderer.queue-capacity"
                )
                return
            }
            pending.removeLast()
            ledger.release(tail.frame)
            rejectIsolated(
                tail.frame,
                acceptanceID: tail.acceptanceID,
                reason: "renderer.queue-capacity"
            )
            if let acceptanceID, acceptances[acceptanceID] == nil {
                // Evicting another frame from the same batch rejects the whole
                // acceptance and removes every one of its pending entries.
                return
            }
        }
        pending.append(PendingFrame(frame: frame, acceptanceID: acceptanceID))
        sortPendingIsolated()
    }

    private func sortPendingIsolated() {
        pending.sort { Self.precedes($0.frame, $1.frame) }
    }

    private static func precedes(
        _ lhs: VideoPresentationFrame,
        _ rhs: VideoPresentationFrame
    ) -> Bool {
        let comparison = CMTimeCompare(lhs.presentationTimeStamp, rhs.presentationTimeStamp)
        return comparison == 0
            ? lhs.sequenceNumber < rhs.sequenceNumber
            : comparison < 0
    }

    private func armRequestIfNeededIsolated() {
        guard !stopped, !pending.isEmpty, !requestArmed else { return }
        requestArmed = true
        requestToken &+= 1
        let token = requestToken
        backend.requestMediaDataWhenReady(on: stateQueue) { [weak self] in
            self?.drainIsolated(token: token)
        }
    }

    private func drainIsolated(token: UInt64) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !stopped,
              requestArmed,
              token == requestToken,
              inFlightFlush == nil,
              pendingReset == nil else { return }
        while backend.isReadyForMoreMediaData, !pending.isEmpty {
            let next = pending.removeFirst()
            do {
                backend.enqueue(try builder.make(
                    frame: next.frame,
                    presentationTimeOffset: presentationTimeOffset
                ))
                if recoveryCompletedWithoutProgress, !recoveryRequestInFlight {
                    recoveryCompletedWithoutProgress = false
                }
                ledger.release(next.frame)
                completeAcceptanceFrameIsolated(next)
            } catch let error as PlaybackCoreError {
                ledger.release(next.frame)
                rejectIsolated(next.frame, acceptanceID: next.acceptanceID, error: error)
                failureSink(error, generation)
            } catch {
                ledger.release(next.frame)
                let failure = PlaybackCoreError.videoSampleBuffer("sample.unknown")
                rejectIsolated(next.frame, acceptanceID: next.acceptanceID, error: failure)
                failureSink(failure, generation)
            }
        }
        if pending.isEmpty { stopRequestIsolated() }
    }

    private func stopRequestIsolated() {
        guard requestArmed else { return }
        requestArmed = false
        requestToken &+= 1
        backend.stopRequestingMediaData()
    }

    private func startResetIsolated(
        _ transaction: ResetTransaction,
        clearPending: Bool
    ) {
        stopRequestIsolated()
        generation = transaction.request.generation
        if let offset = transaction.request.presentationTimeOffset {
            presentationTimeOffset = offset
        }
        if clearPending {
            clearPendingIsolated(reason: "renderer.reset")
        }
        builder.reset()
        let operationID = allocateFlushOperationIDIsolated()
        inFlightFlush = (operationID, transaction)
        backend.flush(
            removeDisplayedImage: transaction.request.removeDisplayedImage
        ) { [weak self] in
            self?.stateQueue.async { [weak self] in
                self?.physicalFlushCompletedIsolated(operationID: operationID)
            }
        }
        stateQueue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.resetFlushDeadlineFiredIsolated(operationID: operationID)
        }
    }

    private func resetFlushDeadlineFiredIsolated(operationID: UInt64) {
        guard let timedOut = inFlightFlush,
              timedOut.operationID == operationID else { return }
        inFlightFlush = nil
        finishResetIsolated(
            timedOut.transaction,
            result: .failure(.videoRendererFailed("renderer.flush-timeout"))
        )
        if stopped {
            startStopFlushIsolated()
        } else if let latest = pendingReset {
            pendingReset = nil
            startResetIsolated(latest, clearPending: false)
        }
    }

    private func physicalFlushCompletedIsolated(operationID: UInt64) {
        guard let finished = inFlightFlush,
              finished.operationID == operationID else { return }
        inFlightFlush = nil
        if stopped {
            finishResetIsolated(
                finished.transaction,
                result: .failure(.videoRendererFailed("renderer.stopped"))
            )
            startStopFlushIsolated()
            return
        }
        if let latest = pendingReset {
            pendingReset = nil
            finishResetIsolated(
                finished.transaction,
                result: .failure(.videoRendererFailed("renderer.reset-superseded"))
            )
            // `reset(latest)` already cleared the previous epoch when it became
            // pending. Preserve frames accepted after that request; they belong
            // behind the latest reset's physical flush barrier.
            startResetIsolated(latest, clearPending: false)
            return
        }
        let transaction = finished.transaction
        let seeds = transaction.request.seedFrames
        if seeds.isEmpty {
            finishResetIsolated(
                transaction,
                result: .success(VideoEnqueueReceipt(
                    generation: transaction.request.generation,
                    sequenceNumbers: []
                ))
            )
            armRequestIfNeededIsolated()
            drainIsolated(token: requestToken)
            return
        }
        enqueueSeedsIsolated(seeds, transaction: transaction)
    }

    private func enqueueSeedsIsolated(
        _ seeds: [VideoPresentationFrame],
        transaction: ResetTransaction
    ) {
        let acceptanceID = allocateAcceptanceIDIsolated()
        let sequenceNumbers = Set(seeds.map(\.sequenceNumber))
        acceptances[acceptanceID] = PendingAcceptance(
            generation: transaction.request.generation,
            allSequenceNumbers: sequenceNumbers,
            remaining: sequenceNumbers,
            completion: { [weak self] result in
                self?.finishResetIsolated(transaction, result: result)
            }
        )
        for seed in seeds {
            guard acceptances[acceptanceID] != nil else { break }
            insertIsolated(seed, acceptanceID: acceptanceID)
        }
        finishEmptyAcceptanceIsolated(acceptanceID)
        armRequestIfNeededIsolated()
        drainIsolated(token: requestToken)
    }

    private func startStopFlushIsolated() {
        guard inFlightFlush == nil, !stopFlushInProgress else { return }
        stopFlushInProgress = true
        stopFlushOperationID &+= 1
        let operationID = stopFlushOperationID
        backend.flush(removeDisplayedImage: true) { [weak self] in
            self?.stateQueue.async { [weak self] in
                self?.completeStopFlushIsolated(operationID: operationID)
            }
        }
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.completeStopFlushIsolated(operationID: operationID)
        }
    }

    private func completeStopFlushIsolated(operationID: UInt64) {
        guard stopFlushInProgress,
              operationID == stopFlushOperationID else { return }
        stopFlushInProgress = false
        requestRendererRemovalIsolated()
    }

    private func requestRendererRemovalIsolated() {
        guard stopped,
              !rendererRemovalCompleted,
              !rendererRemovalInFlight else { return }
        guard rendererRemovalAttempt < 2 else {
            finishStopIsolated()
            return
        }
        rendererRemovalAttempt += 1
        rendererRemovalInFlight = true
        rendererRemovalToken &+= 1
        let token = rendererRemovalToken
        removeRenderer { [weak self] removed in
            self?.stateQueue.async { [weak self] in
                guard let self else { return }
                guard rendererRemovalInFlight,
                      rendererRemovalToken == token else { return }
                rendererRemovalInFlight = false
                if removed {
                    finishStopIsolated()
                } else {
                    stateQueue.asyncAfter(deadline: .now() + .milliseconds(25)) {
                        [weak self] in self?.requestRendererRemovalIsolated()
                    }
                }
            }
        }
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self,
                  rendererRemovalInFlight,
                  rendererRemovalToken == token else { return }
            rendererRemovalInFlight = false
            requestRendererRemovalIsolated()
        }
    }

    private func finishStopIsolated() {
        guard !rendererRemovalCompleted else { return }
        rendererRemovalCompleted = true
        rendererRemovalInFlight = false
        rendererRemovalToken &+= 1
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func handleBackendEventIsolated(_ event: VideoRendererBackendEvent) {
        guard !stopped else { return }
        let shouldRecover: Bool
        switch event {
        case .requiresFlushToResumeDecoding:
            shouldRecover = true
        case let .failed(error):
            shouldRecover = backend.requiresFlushToResumeDecoding
                || backend.status == .failed
            if !shouldRecover {
                failureSink(.videoRendererFailed(Self.sanitized(error)), generation)
            }
        }
        guard shouldRecover else { return }
        guard !recoveryRequestInFlight else { return }
        guard !recoveryCompletedWithoutProgress else {
            failureSink(.videoRendererFailed(Self.sanitized(backend.error)), generation)
            return
        }
        recoveryRequestInFlight = true
        recoverySink(generation)
    }

    private func finishResetIsolated(
        _ transaction: ResetTransaction,
        result: Result<VideoEnqueueReceipt, PlaybackCoreError>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if case .success = result, recoveryRequestInFlight {
            recoveryRequestInFlight = false
            // A second failure before a subsequently submitted frame reaches the
            // backend indicates that recovery made no forward progress.
            recoveryCompletedWithoutProgress = true
        }
        transaction.completion(result)
    }

    private func completeAcceptanceFrameIsolated(_ pendingFrame: PendingFrame) {
        guard let acceptanceID = pendingFrame.acceptanceID,
              var acceptance = acceptances[acceptanceID] else { return }
        acceptance.remaining.remove(pendingFrame.frame.sequenceNumber)
        if acceptance.remaining.isEmpty {
            acceptances[acceptanceID] = nil
            acceptance.completion(.success(VideoEnqueueReceipt(
                generation: acceptance.generation,
                sequenceNumbers: acceptance.allSequenceNumbers
            )))
        } else {
            acceptances[acceptanceID] = acceptance
        }
    }

    private func rejectIsolated(
        _ frame: VideoPresentationFrame,
        acceptanceID: UInt64?,
        reason: String
    ) {
        rejectIsolated(
            frame,
            acceptanceID: acceptanceID,
            error: .videoRendererFailed(reason)
        )
    }

    private func rejectIsolated(
        _ frame: VideoPresentationFrame,
        acceptanceID: UInt64?,
        error: PlaybackCoreError
    ) {
        _ = frame
        guard let acceptanceID,
              let acceptance = acceptances.removeValue(forKey: acceptanceID) else { return }
        acceptance.completion(.failure(error))
        let retained = pending.filter { $0.acceptanceID == acceptanceID }
        pending.removeAll { $0.acceptanceID == acceptanceID }
        for item in retained { ledger.release(item.frame) }
    }

    private func finishEmptyAcceptanceIsolated(_ acceptanceID: UInt64) {
        guard let acceptance = acceptances[acceptanceID],
              acceptance.remaining.isEmpty else { return }
        acceptances[acceptanceID] = nil
        acceptance.completion(.success(VideoEnqueueReceipt(
            generation: acceptance.generation,
            sequenceNumbers: acceptance.allSequenceNumbers
        )))
    }

    private func clearPendingIsolated(reason: String) {
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        for pendingFrame in frames { ledger.release(pendingFrame.frame) }
        let completions = acceptances.values.map(\.completion)
        acceptances.removeAll(keepingCapacity: true)
        for completion in completions {
            completion(.failure(.videoRendererFailed(reason)))
        }
    }

    private func allocateAcceptanceIDIsolated() -> UInt64 {
        let value = nextAcceptanceID
        nextAcceptanceID &+= 1
        return value
    }

    private func allocateResetIDIsolated() -> UInt64 {
        let value = nextResetID
        nextResetID &+= 1
        return value
    }

    private func allocateFlushOperationIDIsolated() -> UInt64 {
        let value = nextFlushOperationID
        nextFlushOperationID &+= 1
        return value
    }

    private static func sanitized(_ error: (any Error)?) -> String {
        guard let error else { return "AVFoundation:unknown" }
        let value = error as NSError
        return "\(String(value.domain.prefix(96))):\(value.code)"
    }

    // Deterministic inspection hooks kept internal to the testable framework.
    func waitUntilIdleForTesting() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { stateQueue.sync {} }
    }

    var pendingSequenceNumbersForTesting: [UInt64] {
        stateQueue.sync { pending.map(\.frame.sequenceNumber) }
    }
}

private final class SystemVideoRendererRemoval: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    init(
        renderer: AVSampleBufferVideoRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer
    ) {
        self.renderer = renderer
        self.synchronizer = synchronizer
    }

    lazy var remove: SystemVideoOutput.RendererRemoval = { [self] completion in
        synchronizer.removeRenderer(
            renderer,
            at: .invalid,
            completionHandler: { [self] didRemove in
                let isStillAttached = synchronizer.renderers.contains { candidate in
                    (candidate as AnyObject) === renderer
                }
                // AVFoundation returns false when the renderer was never added;
                // that still satisfies our teardown barrier because it is absent.
                completion(didRemove || !isStillAttached)
            }
        )
    }
}
