// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import VPlayerCore

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
}

final class SystemVideoOutput: @unchecked Sendable {
    typealias Acceptance = @Sendable (Result<VideoEnqueueReceipt, PlaybackCoreError>) -> Void
    typealias RendererRemoval = @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    private struct PendingFrame: Sendable {
        let frame: VideoPresentationFrame
        let acceptanceID: UInt64?
    }

    private struct PendingAcceptance {
        let generation: MediaGeneration
        let allSequenceNumbers: Set<UInt64>
        var remaining: Set<UInt64>
        // Keep accepted prefixes budgeted while a multi-frame receipt is still
        // pending. A retry flush destroys those admissions and must replay them.
        var acceptedFrames: [PendingFrame] = []
        var hasRetriedAfterFlush = false
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
    private var pending: [PendingFrame] = []
    private var acceptances: [UInt64: PendingAcceptance] = [:]
    private var nextAcceptanceID: UInt64 = 1
    private var nextResetID: UInt64 = 1
    private var nextFlushOperationID: UInt64 = 1
    private var stopFlushOperationID: UInt64 = 0
    private var requestToken: UInt64 = 0
    private var requestArmed = false
    private var eventEpoch: UInt64 = 0
    private var activeFrame: PendingFrame?
    private var receiverRecoveryInFlight = false
    private var receiverRecoveryAttemptedWithoutAcceptance = false
    private var receiverRecoveryOperationID: UInt64 = 0
    private var draining = false
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
        installBackendObservationIsolated()
    }

    convenience init(
        renderer: AVSampleBufferVideoRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer,
        ledger: VideoSurfaceBudgetLedger = VideoSurfaceBudgetLedger(),
        metrics: PlaybackMetrics? = nil,
        recoverySink: @escaping @Sendable (MediaGeneration) -> Void,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) {
        let backend = VideoRendererBackend(renderer: renderer, synchronizer: synchronizer)
        self.init(
            backend: backend,
            ledger: ledger,
            metrics: metrics,
            removeRenderer: backend.remove,
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
            guard !stopped, self.generation != generation else { return }
            // A decoder-only generation change changes admission, not the
            // physical renderer episode. Frames already admitted remain valid;
            // destructive reset/stop still revoke their request token.
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
        guard !stopped, !receiverRecoveryInFlight,
              !pending.isEmpty, !requestArmed else { return }
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
              pendingReset == nil, !receiverRecoveryInFlight else { return }
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while activeFrame == nil, requestArmed, token == requestToken,
              !receiverRecoveryInFlight, backend.isReadyForMoreMediaData, !pending.isEmpty {
            let next = pending.removeFirst()
            do {
                let sample = try builder.make(frame: next.frame)
                activeFrame = next
                backend.enqueue(sample) { [weak self] result in
                    guard let self else { return }
                    if DispatchQueue.getSpecific(key: queueKey) != nil {
                        completeEnqueueIsolated(next, token: token, result: result)
                    } else {
                        stateQueue.async { [weak self] in
                            self?.completeEnqueueIsolated(next, token: token, result: result)
                        }
                    }
                }
            } catch {
                ledger.release(next.frame)
                let failure = (error as? PlaybackCoreError) ?? .unexpected(
                    stage: "video.sample-buffer", diagnostic: .init(error))
                rejectIsolated(next.frame, acceptanceID: next.acceptanceID, error: failure)
                failureSink(failure, generation)
            }
        }
        if pending.isEmpty, activeFrame == nil {
            stopRequestIsolated()
            backend.finishedEnqueuing()
        }
    }

    private func completeEnqueueIsolated(_ next: PendingFrame, token: UInt64,
        result: Result<VideoRendererEnqueueResult, any Error>) {
        guard !stopped, requestArmed, token == requestToken,
              activeFrame?.frame.generation == next.frame.generation,
              activeFrame?.frame.sequenceNumber == next.frame.sequenceNumber,
              inFlightFlush == nil, pendingReset == nil else { return }
        activeFrame = nil
        switch result {
        case .success(.accepted):
            receiverRecoveryAttemptedWithoutAcceptance = false
            if recoveryCompletedWithoutProgress, !recoveryRequestInFlight {
                recoveryCompletedWithoutProgress = false
            }
            completeAcceptanceFrameIsolated(next)
        case let .success(.requiresRecovery(reason)):
            // These are decoded image buffers, so one renderer flush can retry
            // the exact retained seed. Keep its anchor receipt pending until the
            // receiver genuinely accepts it; never turn recovery into acceptance.
            recoverRejectedFrameIsolated(next, reason: reason)
            return
        case .success(.cancelled):
            ledger.release(next.frame)
            rejectIsolated(next.frame, acceptanceID: next.acceptanceID,
                reason: "renderer.enqueue-cancelled")
        case let .failure(error):
            ledger.release(next.frame)
            let failure = Self.rendererFailure(error)
            rejectIsolated(next.frame, acceptanceID: next.acceptanceID, error: failure)
            if !(error is CancellationError) { failureSink(failure, generation) }
        }
        if !draining { drainIsolated(token: token) }
    }

    private func recoverRejectedFrameIsolated(_ next: PendingFrame,
        reason: VideoRendererBackendEvent) {
        let failure: PlaybackCoreError
        switch reason {
        case let .failed(error), let .decodeFailure(error): failure = Self.rendererFailure(error)
        case .requiresFlushToResumeDecoding: failure = Self.rendererFailure(backend.error)
        }
        let receiptWasRejected = next.acceptanceID.map { acceptances[$0] == nil } ?? false
        if receiptWasRejected { ledger.release(next.frame) }
        // A capacity-evicted receipt does not invalidate this physical renderer
        // episode. Discard its unwanted frame but still clear the native failure
        // latch, otherwise surviving receipts can never receive a new enqueue.
        let retryConsumed = next.acceptanceID.flatMap { acceptances[$0]?.hasRetriedAfterFlush }
            ?? receiverRecoveryAttemptedWithoutAcceptance
        guard !retryConsumed else {
            if !receiptWasRejected { ledger.release(next.frame) }
            rejectIsolated(next.frame, acceptanceID: next.acceptanceID, error: failure)
            if receiptWasRejected { clearPendingIsolated(reason: "renderer.recovery-exhausted") }
            failureSink(failure, generation)
            return
        }
        receiverRecoveryAttemptedWithoutAcceptance = true
        receiverRecoveryInFlight = true
        receiverRecoveryOperationID += 1
        let operationID = receiverRecoveryOperationID
        if !receiptWasRejected { pending.append(next) }
        // A full flush invalidates every accepted prefix belonging to an
        // outstanding receipt, not just the rejected frame. Transfer their
        // existing ledger references back to pending and restart the required
        // set. The retry budget belongs to the whole transaction.
        for acceptanceID in Array(acceptances.keys) {
            guard var acceptance = acceptances[acceptanceID] else { continue }
            pending.append(contentsOf: acceptance.acceptedFrames)
            acceptance.acceptedFrames.removeAll()
            acceptance.remaining = acceptance.allSequenceNumbers
            acceptance.hasRetriedAfterFlush = true
            acceptances[acceptanceID] = acceptance
        }
        sortPendingIsolated()
        stopRequestIsolated()
        backend.flush(removeDisplayedImage: false) { [weak self] in
            self?.stateQueue.async { [weak self] in
                guard let self, !stopped, receiverRecoveryInFlight,
                      receiverRecoveryOperationID == operationID,
                      inFlightFlush == nil, pendingReset == nil else { return }
                receiverRecoveryInFlight = false
                armRequestIfNeededIsolated()
                drainIsolated(token: requestToken)
            }
        }
        stateQueue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self, !stopped, receiverRecoveryInFlight,
                  receiverRecoveryOperationID == operationID else { return }
            receiverRecoveryInFlight = false
            clearPendingIsolated(reason: "renderer.recovery-flush-timeout")
            failureSink(.videoRendererFailed("renderer.recovery-flush-timeout"), generation)
        }
    }

    private func stopRequestIsolated() {
        guard requestArmed else { return }
        requestArmed = false
        requestToken &+= 1
        backend.stopRequestingMediaData()
        backend.cancelPendingEnqueue()
    }

    private func startResetIsolated(
        _ transaction: ResetTransaction,
        clearPending: Bool
    ) {
        stopRequestIsolated()
        receiverRecoveryInFlight = false
        receiverRecoveryOperationID += 1
        receiverRecoveryAttemptedWithoutAcceptance = false
        eventEpoch += 1
        backend.stopObserving()
        generation = transaction.request.generation
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
        installBackendObservationIsolated()
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

    private func installBackendObservationIsolated() {
        eventEpoch += 1
        let epoch = eventEpoch
        backend.startObserving { [weak self] event in
            self?.stateQueue.async { [weak self] in
                guard let self, eventEpoch == epoch else { return }
                handleBackendEventIsolated(event)
            }
        }
    }

    private func handleBackendEventIsolated(_ event: VideoRendererBackendEvent) {
        guard !stopped else { return }
        let shouldRecover: Bool
        let observedFailure: PlaybackCoreError?
        switch event {
        case .requiresFlushToResumeDecoding:
            shouldRecover = true
            observedFailure = nil
        case let .failed(error), let .decodeFailure(error):
            observedFailure = Self.rendererFailure(error)
            shouldRecover = backend.requiresFlushToResumeDecoding
                || backend.health == .failed
            if !shouldRecover, let observedFailure {
                failureSink(observedFailure, generation)
            }
        }
        guard shouldRecover else { return }
        guard !recoveryRequestInFlight else { return }
        guard !recoveryCompletedWithoutProgress else {
            failureSink(observedFailure ?? Self.rendererFailure(backend.error), generation)
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
              var acceptance = acceptances[acceptanceID] else {
            ledger.release(pendingFrame.frame)
            return
        }
        acceptance.acceptedFrames.append(pendingFrame)
        acceptance.remaining.remove(pendingFrame.frame.sequenceNumber)
        if acceptance.remaining.isEmpty {
            acceptances[acceptanceID] = nil
            for accepted in acceptance.acceptedFrames { ledger.release(accepted.frame) }
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
        for accepted in acceptance.acceptedFrames { ledger.release(accepted.frame) }
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
        if let activeFrame {
            ledger.release(activeFrame.frame)
            self.activeFrame = nil
        }
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        for pendingFrame in frames { ledger.release(pendingFrame.frame) }
        for acceptance in acceptances.values {
            for accepted in acceptance.acceptedFrames { ledger.release(accepted.frame) }
        }
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

    private static func rendererFailure(_ error: (any Error)?) -> PlaybackCoreError {
        if let core = error as? PlaybackCoreError { return core }
        if let error {
            return .unexpected(stage: "video.renderer", diagnostic: .init(error))
        }
        return .unexpected(stage: "video.renderer", diagnostic: .init(
            typeName: "AVSampleBufferVideoRenderer", code: "error-unavailable",
            message: "系统报告视频渲染器失败，但未提供错误详情。"))
    }

    // Deterministic inspection hooks kept internal to the testable framework.
    func waitUntilIdleForTesting() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { stateQueue.sync {} }
    }

    var pendingSequenceNumbersForTesting: [UInt64] {
        stateQueue.sync { pending.map(\.frame.sequenceNumber) }
    }
}
