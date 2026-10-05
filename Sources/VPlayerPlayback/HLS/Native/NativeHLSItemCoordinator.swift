// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

/// Native readiness is distinct from locally generated publication proof. Every
/// mutation still consumes the original Registry prepare/activation authority.
@MainActor
final class NativeHLSItemCoordinator: PlaybackHLSProgressDeadlineReceiving {
    let item: AVPlayerItemInstanceIdentity
    let owned: HLSOwnedSourcePlan
    nonisolated let metadata = NativeHLSMetadataStore()
    private let driver: any AVPlayerDriving
    private let inspector: any NativeHLSAssetInspecting
    private let prepareInvocation: ControlTaskRegistry.BackendPrepareInvocation
    private let metadataChanged: @Sendable (ActivationEpoch?) async -> Void
    private let failure: @MainActor @Sendable (HLSSourceError, ActivationEpoch?) -> Void
    private let retention: HLSApplicationLifetimeCharge
    private var selected: NativeHLSSelectionSnapshot?
    private var pausedCursor: (time: ExactMediaTime, item: ObjectIdentifier)?
    private var monitor: NativeHLSObservation?
    private var authorization: ControlTaskRegistry.BackendPositiveRateInvocation?
    private var armed = false, prepared = false, retired = false, failureDelivered = false, stopInFlight = false
    private var installed = false, naturalEndVerified = false, progressReported = false
    private var lastReceipt: AVPlayerQuiescenceReceipt?
    private var retirement: Task<Bool, Never>?
    private var stopTask: OutputPlayerStopTask?
    private var progressIdentity: UUID?
    private var progress = HLSPlaybackProgressWatch()

    init(driver: any AVPlayerDriving, inspector: any NativeHLSAssetInspecting, owned: HLSOwnedSourcePlan,
         invocation: ControlTaskRegistry.BackendPrepareInvocation,
         metadataChanged: @escaping @Sendable (ActivationEpoch?) async -> Void,
         failure: @escaping @MainActor @Sendable (HLSSourceError, ActivationEpoch?) -> Void) throws {
        retention = try HLSApplicationLifetimeCharge(bytes: 32 * 1_024)
        self.driver = driver; self.inspector = inspector; self.owned = owned; prepareInvocation = invocation
        item = .init(outputLifecycleEpoch: invocation.outputLifecycleEpoch, itemGeneration: invocation.outputLifecycleEpoch.outputNonce)
        self.metadataChanged = metadataChanged; self.failure = failure
    }
    var hasInstalledItem: Bool { installed || driver.currentItemIdentity == item }
    var isPrepared: Bool { prepared && !retired && !failureDelivered }
    var currentActivation: ActivationEpoch? { authorization?.activation }

    private func validatePrepare() throws {
        try Task.checkCancellation()
        guard !retired, !failureDelivered, owned.sourceIsCurrent, owned.source.refreshReason() == nil,
              prepareInvocation.revalidateCurrentPreparation() else { throw CancellationError() }
    }
    private func validateActive(_ invocation: ControlTaskRegistry.BackendPositiveRateInvocation) throws {
        try Task.checkCancellation()
        guard !retired, !failureDelivered, !stopInFlight, owned.sourceIsCurrent, owned.source.refreshReason() == nil,
              authorization == invocation, invocation.revalidateCurrentAuthority(), driver.currentItemIdentity == item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }
    func prepare(url: URL) async throws {
        try validatePrepare()
        try driver.install(url: url, identity: item) { operation in
            try prepareInvocation.performCurrentPreparationMutation {
                guard owned.source.withCurrentResolution(owner: owned.plan.owner, generation: owned.source.generation, operation: {
                    operation(); return true
                }) == true else { throw HLSSourceError.staleResolution }
            }
        }
        installed = true
        try validatePrepare()
        guard driver.rate == 0, driver.timeControlStatus != .playing else { throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed }
        try await driver.setDisconnectedFromSystemAudio(false, item: item)
        try validatePrepare()
        guard try await driver.waitUntilReady(item: item) == item else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        try validatePrepare()
        // AVPlayer retains its original default/alternate media selections.
        try await driver.primeMediaData(item: item)
        try validatePrepare()
        let snapshot = try await inspector.snapshot(item: item, source: owned)
        try validatePrepare()
        guard driver.currentItemIdentity == item, driver.rate == 0 else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        selected = snapshot; prepared = true
        metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: snapshot.information))
    }
    func activate(_ invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        guard isPrepared, let interval = invocation.currentSnapshot?.interval,
              interval.outputLifecycle == item.outputLifecycleEpoch, interval.itemGeneration == item.itemGeneration,
              !stopInFlight else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        let alreadyArmed = armed && authorization == invocation
        authorization = invocation
        // Reload before EVERY rate admission, including ordinary pause/resume.
        // A same-size SPS or audio-format change cannot hide behind cached facts.
        let snapshot = try await inspector.snapshot(item: item, source: owned)
        try validateActive(invocation)
        if let selected, !snapshot.permitsTransition(from: selected) { throw HLSSourceError.unsupportedMedia }
        selected = snapshot
        if alreadyArmed {
            metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: snapshot.information))
            await metadataChanged(invocation.activation)
            try validateActive(invocation)
            return
        }
        let resuming = lastReceipt != nil
        let cursor = pausedCursor
        if resuming {
            guard let cursor, cursor.item == snapshot.physicalItem,
                  driver.pausedItemObjectIdentity(item: item) == cursor.item, driver.disconnectedFromSystemAudio else {
                throw AVPlayerItemCoordinatorFailure.seekMismatch
            }
            try driver.reservePausedResumeCallbacks(item: item)
        }
        defer { if resuming { driver.finishPausedResumeCallbacks(item: item) } }
        lastReceipt = nil; stopTask = nil; pausedCursor = nil; naturalEndVerified = false
        try driver.installTimeControlStatusRelay(item: item, activation: invocation.activation) { [weak self] status, item, activation in
            self?.observe(status, item: item, activation: activation)
        }
        try await driver.setDisconnectedFromSystemAudio(false, item: item)
        try validateActive(invocation)
        if let cursor, resuming {
            let actual = try await driver.seekNative(to: cursor.time, item: item)
            try validateActive(invocation)
            guard actual == cursor.time else { throw AVPlayerItemCoordinatorFailure.seekMismatch }
        }
        try await driver.primeMediaData(item: item)
        try validateActive(invocation)
        let afterPreroll = try await inspector.snapshot(item: item, source: owned)
        try validateActive(invocation)
        guard afterPreroll.permitsTransition(from: snapshot) else { throw HLSSourceError.unsupportedMedia }
        selected = afterPreroll
        if let endpoint = afterPreroll.duration {
            try driver.installNaturalEndTerminalHandler(item: item) { [weak self] capability, item in self?.naturalEnd(capability, item: item) }
            try driver.constrainPlaybackEnd(to: endpoint, item: item)
        }
        try await driver.play(invocation: invocation, item: item)
        try validateActive(invocation)
        armed = true
        if let system = driver as? SystemAVPlayerDriver, let physical = system.nativeCurrentItem(item) {
            monitor = try NativeHLSObservation(item: physical, driver: system) { [weak self] failed in await self?.refresh(failed: failed) }
        }
        metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: afterPreroll.information))
        await metadataChanged(invocation.activation)
        try validateActive(invocation)
        startProgress(invocation)
    }
    #if DEBUG
    func observeSelectedFormatChangeForTesting() async { await refresh(failed: false) }
    #endif
    private func refresh(failed: Bool) async {
        guard !retired, !failureDelivered, armed, let invocation = authorization, invocation.revalidateCurrentAuthority() else { return }
        if failed || owned.source.refreshReason() != nil { fail(.network); return }
        do {
            let snapshot = try await inspector.snapshot(item: item, source: owned)
            try validateActive(invocation)
            if let selected, !snapshot.permitsTransition(from: selected) { throw HLSSourceError.unsupportedMedia }
            selected = snapshot
            metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: snapshot.information))
            await metadataChanged(invocation.activation)
        } catch is CancellationError {} catch { if authorization == invocation && invocation.revalidateCurrentAuthority() { fail(.unsupportedMedia) } }
    }
    private func fail(_ reason: HLSSourceError) {
        guard !retired, !failureDelivered else { return }
        failureDelivered = true; cancelProgress()
        metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: nil))
        failure(reason, authorization?.activation)
    }
    private func observe(_ status: AVPlayer.TimeControlStatus, item: AVPlayerItemInstanceIdentity, activation: ActivationEpoch) {
        guard self.item == item, authorization?.activation == activation, authorization?.revalidateCurrentAuthority() == true,
              !retired, !stopInFlight, armed else { return }
        if status == .paused, progress.hasObservedProgress, !naturalEndVerified, !driver.hasPendingNaturalEndVerification(item: item, activation: activation) { fail(.network) }
    }
    private func naturalEnd(_ capability: AVPlayerNaturalEndTerminalCapability, item: AVPlayerItemInstanceIdentity) {
        guard self.item == item, authorization?.revalidateCurrentAuthority() == true,
              let result = driver.consumeNaturalEndTerminal(capability, item: item) else { return }
        if case .success = result { naturalEndVerified = true; cancelProgress() } else { fail(.network) }
    }
    private func startProgress(_ invocation: ControlTaskRegistry.BackendPositiveRateInvocation) {
        cancelProgress()
        guard let now = invocation.observationInstant, case .currentItem(let time) = driver.playbackClockObservation(item: item) else { return }
        _ = progress.observe(mediaTime: time.map { Double($0.value) / Double($0.timescale) }, at: now)
        let id = UUID()
        if invocation.scheduleHLSProgress(item: item, identity: id, receiver: self) { progressIdentity = id }
    }
    private func cancelProgress() {
        if let progressIdentity { authorization?.retireHLSProgress(identity: progressIdentity) }
        progressIdentity = nil; progress = .init(); progressReported = false
    }
    nonisolated func hlsProgressDeadlineFired(identity: UUID) {
        DispatchQueue.main.async { [weak self] in self?.sampleProgress(identity) }
    }
    private func sampleProgress(_ identity: UUID) {
        guard progressIdentity == identity, let invocation = authorization, armed, !stopInFlight,
              !retired, !failureDelivered, !naturalEndVerified, invocation.revalidateCurrentAuthority(),
              let now = invocation.observationInstant else { if progressIdentity == identity { cancelProgress() }; return }
        invocation.retireHLSProgress(identity: identity)
        guard case .currentItem(let time) = driver.playbackClockObservation(item: item) else { cancelProgress(); return }
        if owned.source.refreshReason() != nil || progress.observe(mediaTime: time.map { Double($0.value) / Double($0.timescale) }, at: now) { fail(.network); return }
        if progress.hasObservedProgress && !progressReported { progressReported = invocation.completeObservedMediaProgress() }
        let next = UUID()
        if invocation.scheduleHLSProgress(item: item, identity: next, receiver: self, delayNanoseconds: progress.nextPollDelay(at: now)) {
            progressIdentity = next
        } else { cancelProgress() }
    }

    func stop(_ invocation: ControlTaskRegistry.BackendSuspendInvocation) async throws -> AVPlayerQuiescenceReceipt {
        if let stopTask {
            return try await stopTask.value(registryIssuerIdentity: invocation.registryIssuerIdentity,
                suspendTicket: invocation.suspendTicket, closeClaim: invocation.closeClaim)
        }
        let prior = authorization?.activation
        guard !retired, !stopInFlight, hasInstalledItem, invocation.lifecycle == item.outputLifecycleEpoch,
              invocation.suspendTicket.priorActivation == prior else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        if let close = invocation.closeClaim {
            guard prior != nil, close.suspendTicket == invocation.suspendTicket,
                  close.intervalKey.outputLifecycle == item.outputLifecycleEpoch,
                  close.intervalKey.itemGeneration == item.itemGeneration, close.intervalKey.activation == prior else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
        } else if prior != nil { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        let task = OutputPlayerStopTask(item: item, registryIssuerIdentity: invocation.registryIssuerIdentity,
            suspendTicket: invocation.suspendTicket, closeClaim: invocation.closeClaim)
        stopTask = task; stopInFlight = true
        defer { stopInFlight = false }
        cancelProgress(); authorization = nil; armed = false
        driver.cancelPendingPrerolls(item: item); driver.pause(item: item)
        let pausedTime = driver.pausedTime(item: item), physicalItem = driver.pausedItemObjectIdentity(item: item)
        let observation = monitor; monitor = nil
        await observation?.close()
        do throws(AVPlayerItemCoordinatorFailure) {
            try await driver.setDisconnectedFromSystemAudio(true, item: item)
            let direct = try await driver.directState(item: item)
            guard direct.item == item, direct.rate == 0, direct.timeControlStatus == .paused,
                  driver.disconnectedFromSystemAudio else { throw .directPauseNotConfirmed }
            driver.removeObservers(item: item)
            await driver.joinNativeCallbackTails()
            let receipt = AVPlayerQuiescenceReceipt(item: item, suspendTicket: invocation.suspendTicket,
                priorActivationEpoch: prior, stopNonce: invocation.closeClaim?.stopNonce,
                closeClaim: invocation.closeClaim, directlyConfirmedRateZero: true)
            lastReceipt = receipt; task.complete(.success(receipt))
            pausedCursor = nil
            if isPrepared, let pausedTime, let physicalItem, driver.pausedItemObjectIdentity(item: item) == physicalItem {
                pausedCursor = (pausedTime, physicalItem)
            }
            metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: nil))
            await metadataChanged(nil)
            return receipt
        } catch {
            pausedCursor = nil; task.complete(.failure(error)); throw error
        }
    }
    func accepts(_ receipt: AVPlayerQuiescenceReceipt) -> Bool {
        guard lastReceipt?.identity === receipt.identity, stopTask?.receiptIdentity === receipt.identity,
              receipt.item == item, driver.currentItemIdentity == item, driver.disconnectedFromSystemAudio,
              driver.rate == 0, driver.timeControlStatus == .paused else { return false }
        if let close = receipt.closeClaim {
            return receipt.matches(item: item, suspendTicket: receipt.suspendTicket,
                priorActivationEpoch: receipt.priorActivationEpoch, closeClaim: close)
        }
        return receipt.priorActivationEpoch == nil && receipt.stopNonce == nil &&
            receipt.suspendTicket.lifecycle == item.outputLifecycleEpoch && receipt.suspendTicket.priorActivation == nil && receipt.directlyConfirmedRateZero
    }
    func retire() async -> Bool {
        if let retirement { return await retirement.value }
        let task = Task { @MainActor [self] in await retireOnce() }
        retirement = task
        return await task.value
    }
    private func retireOnce() async -> Bool {
        if retired { return true }
        if hasInstalledItem { guard let lastReceipt, accepts(lastReceipt) else { return false } }
        retired = true; prepared = false; cancelProgress()
        let observation = monitor; monitor = nil
        await observation?.close()
        if hasInstalledItem {
            driver.replaceCurrentItemWithNil(item: item); driver.removeObservers(item: item)
            await driver.joinNativeCallbackTails()
            guard driver.currentItemIdentity != item else { return false }
        }
        selected = nil; pausedCursor = nil; metadata.publish(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        return true
    }
}
