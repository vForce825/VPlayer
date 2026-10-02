// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFAudio
import Foundation

/// Fixed Swift projection; framework context objects never escape their main-actor callback.
enum PlaybackAudioSessionLifecycleEvent: Sendable, Equatable {
    case becameActive
    case becameInactive(systemInitiated: Bool)
    case resumptionRecommended(shouldResume: Bool)
}

/// Exact legacy wire values verified on tvOS27 by the runtime probe in
/// https://github.com/vForce825/VPlayer/actions/runs/36949943097 (1 test, 0 failures).
/// Keep this narrow compatibility ingress synchronous: the safety veto must be
/// folded on the posting thread before playback can admit another positive rate.
/// Typed lifecycle messages remain advisory until their timing equivalence is proven.
private enum LegacyAudioSessionInterruption {
    static let notificationName = Notification.Name("AVAudioSessionInterruptionNotification")
    static let typeKey = "AVAudioSessionInterruptionTypeKey"
    static let optionKey = "AVAudioSessionInterruptionOptionKey"
    static let began: UInt = 1
    static let ended: UInt = 0
    static let shouldResume: UInt = 1
}

public final class SystemAudioEventMonitor: @unchecked Sendable {
    /// 与pipeline relay共享同一本4KiB账；这里只提供类型化alias，不重复计费。
    static var systemAndPipelineRelayAllocationReservation:
        PlaybackSessionEventRelay.SystemAndPipelineRelayAllocationReservation {
        PlaybackSessionEventRelay.systemAndPipelineRelayAllocationReservation
    }
    static var weakTargetAllocationCharges: Int {
        systemAndPipelineRelayAllocationReservation.weakTargetAllocationCharges
    }
    private let safetyIngress: SynchronousSafetyIngressCell
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?
    private var activeObserver: NotificationCenter.ObservationToken?
    private var inactiveObserver: NotificationCenter.ObservationToken?
    private var resumptionObserver: NotificationCenter.ObservationToken?
    private var observerGeneration: UInt64 = 0
    private struct TypedInterruption {
        var epoch: AudioSessionLifecycleEpoch
        var recommendation: Bool?
        var activationAccepted = false
    }
    private var typedInterruption: TypedInterruption?
    private typealias Delivery = (PlaybackAudioSessionEventEnvelope,
        (@Sendable (PlaybackAudioSessionEventEnvelope) -> Void)?)
    // 生产转发与可替换测试observer分离；Registry已在owned账按同一weak target计费。
    private weak var productionRegistry: ControlTaskRegistry?
    private var eventHandler: (@Sendable (PlaybackAudioSessionEventEnvelope) -> Void)?
    
    init(
        safetyIngress: SynchronousSafetyIngressCell,
        notificationCenter: NotificationCenter = .default,
        eventHandler: (@Sendable (PlaybackAudioSessionEventEnvelope) -> Void)? = nil
    ) {
        self.safetyIngress = safetyIngress
        self.notificationCenter = notificationCenter
        self.eventHandler = eventHandler
        PlaybackRuntimeAllocationReservations.validateSystemAndPipelineAndGlobalCaps()
    }

    deinit { stop() }
    
    func setEventHandler(_ handler: @escaping @Sendable (PlaybackAudioSessionEventEnvelope) -> Void) {
        lock.withLock { self.eventHandler = handler }
    }

    func bindProductionRegistry(_ registry: ControlTaskRegistry) {
        lock.withLock {
            precondition(productionRegistry == nil || productionRegistry === registry,
                "SystemAudioEventMonitor不能改绑另一Registry")
            productionRegistry = registry
        }
    }
    
    @discardableResult
    func emit(_ event: PlaybackAudioSessionEvent,
        beforeProductionDelivery: (@Sendable () -> Void)? = nil) -> PlaybackAudioSessionEventEnvelope? {
        guard Self.systemEvent(event) != nil else {
            let envelope = PlaybackAudioSessionEventEnvelope(event: event, systemReceipt: nil)
            beforeProductionDelivery?()
            deliver(envelope)
            return envelope
        }
        lock.lock()
        var effectiveEvent = event
        let current = safetyIngress.snapshot
        if case .interruptionEnded(let shouldResume) = event {
            let episode = typedInterruption.flatMap { $0.epoch == AudioSessionLifecycleEpoch(current) ? $0 : nil }
            if episode?.activationAccepted == true {
                lock.unlock()
                return nil
            }
            let permitted = shouldResume && episode?.recommendation != false && !current.mediaServicesResumeRequired
            effectiveEvent = .interruptionEnded(shouldResume: permitted)
            // Only an exactly scoped typed recommendation deduplicates its legacy counterpart.
            if episode?.recommendation != nil, current.interruptionState == .ended(shouldResume: permitted) {
                lock.unlock()
                return nil
            }
        }
        let delivery = emitSystemLocked(effectiveEvent, beforeProductionDelivery: beforeProductionDelivery)
        lock.unlock()
        if let delivery { delivery.1?(delivery.0) }
        return delivery?.0
    }

    /// Typed recommendations are reconciled with the current synchronous safety epoch.
    /// A newer legacy began/reset invalidates this advisory scope; never infer a shared system ID.
    @discardableResult
    func emitLifecycle(_ event: PlaybackAudioSessionLifecycleEvent,
        observationGeneration: UInt64? = nil) -> PlaybackAudioSessionEventEnvelope? {
        lock.lock()
        if let observationGeneration,
           observationGeneration != observerGeneration || activeObserver == nil {
            lock.unlock()
            return nil
        }
        let current = safetyIngress.snapshot
        let epoch = AudioSessionLifecycleEpoch(current)
        var delivery: Delivery?
        switch event {
        case .becameActive:
            // A notification is not the SDK call's Bool/completion. Only close an old
            // advisory episode if Registry already holds the matching accepted receipt.
            if !current.interruptionVeto, !current.userPaused, !current.mediaServicesResumeRequired,
               productionRegistry?.hasAcceptedAudioSessionActivation(matching: epoch) == true {
                typedInterruption?.activationAccepted = true
            }
        case .becameInactive(systemInitiated: false):
            // App deactivation is settled exclusively by its original async call permit.
            break
        case .becameInactive(systemInitiated: true):
            if current.interruptionState == .began {
                if typedInterruption?.epoch != epoch {
                    typedInterruption = .init(epoch: epoch, recommendation: nil)
                }
            } else {
                delivery = emitSystemLocked(.interruptionBegan, matching: epoch)
                if let receipt = delivery?.0.systemReceipt {
                    typedInterruption = .init(epoch: .init(interruption: receipt.interruptionEpoch,
                        mediaServices: receipt.mediaServicesEpoch), recommendation: nil)
                }
            }
        case .resumptionRecommended(let shouldResume):
            if var episode = typedInterruption, episode.epoch == epoch, !episode.activationAccepted {
                // A positive hint cannot override a prior negative decision or reset/user pause.
                let permitted = shouldResume && episode.recommendation != false &&
                    current.interruptionState != .ended(shouldResume: false) &&
                    !current.mediaServicesResumeRequired && !current.userPaused
                episode.recommendation = permitted
                typedInterruption = episode
                if current.interruptionState == .began ||
                    (current.interruptionState == .ended(shouldResume: true) && !permitted) {
                    delivery = emitSystemLocked(.interruptionEnded(shouldResume: permitted), matching: epoch)
                }
            }
        }
        lock.unlock()
        if let delivery { delivery.1?(delivery.0) }
        return delivery?.0
    }

    private static func systemEvent(_ event: PlaybackAudioSessionEvent) -> PlaybackSystemSafetyEvent? {
        switch event {
        case .interruptionBegan: .interruptionBegan
        case .interruptionEnded(let shouldResume): .interruptionEnded(shouldResume: shouldResume)
        case .mediaServicesWereReset: .mediaServicesReset
        case .explicitResumeSucceeded, .resetConfigurationSucceeded, .recoveryFailed: nil
        }
    }

    /// Caller holds monitor lock; Cell validates any advisory scope in its original fold lock.
    private func emitSystemLocked(_ event: PlaybackAudioSessionEvent,
        matching epoch: AudioSessionLifecycleEpoch? = nil,
        beforeProductionDelivery: (@Sendable () -> Void)? = nil) -> Delivery? {
        guard let system = Self.systemEvent(event) else { return nil }
        let priorEpoch = AudioSessionLifecycleEpoch(safetyIngress.snapshot)
        let receipt: PlaybackSystemSafetyReceipt?
        if let epoch { receipt = safetyIngress.performSyncIngress(system, matching: epoch) }
        else { receipt = safetyIngress.performSyncIngress(system) }
        guard let receipt else { return nil }
        switch event {
        case .interruptionBegan, .mediaServicesWereReset:
            typedInterruption = nil
        case .interruptionEnded:
            if typedInterruption?.epoch == priorEpoch {
                typedInterruption?.epoch = .init(interruption: receipt.interruptionEpoch,
                    mediaServices: receipt.mediaServicesEpoch)
            }
        default: break
        }
        let envelope = PlaybackAudioSessionEventEnvelope(event: event, systemReceipt: receipt)
        beforeProductionDelivery?()
        productionRegistry?.forwardAudioSessionEvent(envelope)
        return (envelope, eventHandler)
    }

    public func start() {
        lock.withLock {
            guard interruptionObserver == nil, observerGeneration < .max else { return }
            observerGeneration += 1
            let generation = observerGeneration
            activeObserver = notificationCenter.addObserver(for: AVAudioSession.DidBecomeActiveMessage.self) { [weak self] _ in
                self?.emitLifecycle(.becameActive, observationGeneration: generation)
            }
            inactiveObserver = notificationCenter.addObserver(for: AVAudioSession.DidBecomeInactiveMessage.self) { [weak self] message in
                switch message.deactivationResult {
                case .appDeactivated:
                    self?.emitLifecycle(.becameInactive(systemInitiated: false), observationGeneration: generation)
                case .systemInterruption:
                    self?.emitLifecycle(.becameInactive(systemInitiated: true), observationGeneration: generation)
                @unknown default:
                    self?.emitLifecycle(.becameInactive(systemInitiated: true), observationGeneration: generation)
                }
            }
            resumptionObserver = notificationCenter.addObserver(for: AVAudioSession.ResumptionRecommendationMessage.self) { [weak self] message in
                self?.emitLifecycle(.resumptionRecommended(shouldResume: message.recommendation == .shouldResume),
                    observationGeneration: generation)
            }
            if interruptionObserver == nil {
                interruptionObserver = notificationCenter.addObserver(forName: LegacyAudioSessionInterruption.notificationName, object: nil, queue: nil) { [weak self] notification in
                    guard let self = self else { return }
                    guard let type = notification.userInfo?[LegacyAudioSessionInterruption.typeKey] as? UInt else { return }
                    
                    if type == LegacyAudioSessionInterruption.began {
                        self.emit(.interruptionBegan)
                    } else if type == LegacyAudioSessionInterruption.ended {
                        let options = notification.userInfo?[LegacyAudioSessionInterruption.optionKey] as? UInt ?? 0
                        let shouldResume = options & LegacyAudioSessionInterruption.shouldResume != 0
                        self.emit(.interruptionEnded(shouldResume: shouldResume))
                    }
                }
            }
            if resetObserver == nil {
                resetObserver = notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                    guard let self = self else { return }
                    self.emit(.mediaServicesWereReset)
                }
            }
        }
    }
    
    public func stop() {
        lock.withLock {
            if observerGeneration < .max { observerGeneration += 1 }
            if let activeObserver { notificationCenter.removeObserver(activeObserver) }
            if let inactiveObserver { notificationCenter.removeObserver(inactiveObserver) }
            if let resumptionObserver { notificationCenter.removeObserver(resumptionObserver) }
            activeObserver = nil
            inactiveObserver = nil
            resumptionObserver = nil
            typedInterruption = nil
            if let observer = interruptionObserver {
                notificationCenter.removeObserver(observer)
                interruptionObserver = nil
            }
            if let observer = resetObserver {
                notificationCenter.removeObserver(observer)
                resetObserver = nil
            }
        }
    }

    func emitReactivationCompletion(_ receipt: AudioSessionReactivationCompletionReceipt,
        event: PlaybackAudioSessionEvent = .explicitResumeSucceeded) {
        lock.withLock {
            let epoch = AudioSessionLifecycleEpoch(interruption: receipt.interruptionEpoch,
                mediaServices: receipt.mediaServicesEpoch)
            if typedInterruption?.epoch == epoch,
               productionRegistry?.hasAcceptedAudioSessionActivation(matching: epoch) == true {
                typedInterruption?.activationAccepted = true
            }
        }
        let envelope = PlaybackAudioSessionEventEnvelope(event: event,
            systemReceipt: nil, reactivationReceipt: receipt)
        deliver(envelope)
    }

    private func deliver(_ envelope: PlaybackAudioSessionEventEnvelope) {
        let targets = lock.withLock { (productionRegistry, eventHandler) }
        targets.0?.forwardAudioSessionEvent(envelope)
        targets.1?(envelope)
    }
}
