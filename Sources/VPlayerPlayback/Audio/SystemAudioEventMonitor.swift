// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFAudio
import Foundation

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
        let system: PlaybackSystemSafetyEvent?
        switch event {
        case .interruptionBegan:
            system = .interruptionBegan
        case .interruptionEnded(let shouldResume):
            system = .interruptionEnded(shouldResume: shouldResume)
        case .mediaServicesWereReset:
            system = .mediaServicesReset
        case .explicitResumeSucceeded, .resetConfigurationSucceeded, .recoveryFailed:
            system = nil
        }
        if let system {
            // 原回调fold与production relay共用monitor现有锁排序；测试observer始终锁外观察。
            lock.lock()
            guard let receipt = safetyIngress.performSyncIngress(system) else {
                lock.unlock()
                return nil
            }
            let envelope = PlaybackAudioSessionEventEnvelope(event: event, systemReceipt: receipt)
            beforeProductionDelivery?()
            productionRegistry?.forwardAudioSessionEvent(envelope)
            let observer = eventHandler
            lock.unlock()
            observer?(envelope)
            return envelope
        }
        let envelope = PlaybackAudioSessionEventEnvelope(event: event, systemReceipt: nil)
        beforeProductionDelivery?()
        deliver(envelope)
        return envelope
    }
    
    public func start() {
        lock.withLock {
            if interruptionObserver == nil {
                interruptionObserver = notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
                    guard let self = self else { return }
                    let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard let typeValue = typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                    
                    if type == .began {
                        self.emit(.interruptionBegan)
                    } else if type == .ended {
                        let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        let shouldResume = options.contains(.shouldResume)
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
