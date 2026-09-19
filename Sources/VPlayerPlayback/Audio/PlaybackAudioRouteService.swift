// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import ObjectiveC

public final class PlaybackAudioRouteService: PlaybackAudioSessionCompletionReceiving, @unchecked Sendable {
    struct RouteAllocationReservation {
        let serviceObject: Int
        let serviceLock: Int
        let timerWrapper: Int
        let timerSource: Int
        let permanentHandlerCapture: Int
        let routeMonitorObject: Int
        let subscriberAdapterCapture: Int
        let resampleSyncBridge: Int
        let weakTargetAllocationCharges: Int

        var timerSourceAndPermanentHandlerAllocationCharges: Int {
            timerWrapper + timerSource + permanentHandlerCapture
        }
        var fixedObjectAllocationCharges: Int {
            serviceObject + serviceLock + timerWrapper + timerSource + routeMonitorObject
        }
        var total: Int {
            serviceObject + serviceLock + timerWrapper + timerSource + permanentHandlerCapture +
                routeMonitorObject + subscriberAdapterCapture + resampleSyncBridge + weakTargetAllocationCharges
        }
    }

    static var routeAllocationReservation: RouteAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return .init(
            serviceObject: object(PlaybackAudioRouteService.self),
            serviceLock: object(NSLock.self),
            timerWrapper: DispatchPlaybackMonotonicClock.deadlineTimerObjectAllocationBytes,
            timerSource: 128,
            permanentHandlerCapture: 32 + 48,
            routeMonitorObject: object(AudioOutputRouteMonitor.self),
            subscriberAdapterCapture: 32 + 48,
            resampleSyncBridge: PlaybackExternalSyncProducerReservation.FixedLedgerCharge
                .routeResampleSyncBridge.bytes,
            weakTargetAllocationCharges: 32)
    }
    private let registry: ControlTaskRegistry
    private let owner: PlaybackAudioSessionOwner
    private let safetyIngress: SynchronousSafetyIngressCell
    private var subscriber: (@Sendable (AudioOutputRouteSnapshot) -> Void)?
    private var routeCommitHandler: (@Sendable (StableRouteCommitIdentity) -> Void)?
    private var routeUnavailableHandler: (@Sendable () -> Void)?
    private var sessionRegistration: PlaybackAudioSessionRegistration?
    private let timer: any PlaybackDeadlineTimer
    // 只有唯一executor读写本槽；handler不捕获票或timer，不产生逐次arm逃逸环境。
    private var stabilityTicket: RouteStabilityTicket?
    private let lock = NSLock()
    private var revision: UInt64 = 0
    
    init(registry: ControlTaskRegistry, owner: PlaybackAudioSessionOwner) {
        PlaybackRuntimeAllocationReservations.validateRouteAndGlobalCaps()
        self.registry = registry
        self.owner = owner
        self.safetyIngress = registry.executor.safetyIngress
        self.timer = registry.makePlaybackDeadlineTimer()
        // 服务从创建到销毁始终拥有同一已激活源，尚未绑定session时仅无排期。
        timer.schedule(notAfterInstant: nil)
        timer.setEventHandler { [weak self] in self?.deliverStabilityWake() }
        timer.activate()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
    
    func bindSession(registration: PlaybackAudioSessionRegistration, initialSampler: ControlTaskTicket? = nil) {
        registry.executor.sync {
            lock.withLock { self.sessionRegistration = registration }
        }
        if let sampler = initialSampler {
            _ = owner.sample(sampler, receiver: self)
        }
    }
    
    func unbindSession() {
        registry.executor.sync {
            stabilityTicket = nil
            timer.schedule(notAfterInstant: nil)
            lock.withLock { sessionRegistration = nil }
        }
    }
    
    func addSubscriber(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void) {
        registry.executor.sync {
            let registration = lock.withLock {
                self.subscriber = handler
                return sessionRegistration
            }
            guard let registration,
                  case .open(let authority)? = registry.outputRouteObservationSnapshot(),
                  authority.sessionIdentity == registration.identity.sessionIdentity,
                  authority.monitorLifecycle == registration.identity.monitorLifecycle,
                  let commit = registry.stableRouteCommitSnapshot(),
                  commit.exactlyMatches(authority, observationGateOpen: true) else { return }
            let committedSnapshot = Self.snapshot(for: commit.authority,
                revision: lock.withLock { revision })
            handler(committedSnapshot)
        }
    }
    
    func removeSubscriber() {
        lock.withLock {
            self.subscriber = nil
        }
    }

    func setRouteCommitHandler(_ handler: @escaping @Sendable (StableRouteCommitIdentity) -> Void) {
        lock.withLock {
            self.routeCommitHandler = handler
        }
    }

    func setRouteUnavailableHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.routeUnavailableHandler = handler
        }
    }
    
    func resample(reason: AudioRouteChangeReason) {
        PlaybackExternalSyncProducerReservation().requireFixedLedgerCharge(
            .routeResampleSyncBridge, for: .audioPipelineRouteResample)
        lock.lock()
        let reg = sessionRegistration
        self.revision += 1
        let currentRevision = self.revision
        lock.unlock()
        guard let reg = reg else { return }
        
        let ingress = PlaybackRouteIngress(
            sessionIdentity: reg.identity.sessionIdentity,
            monitorLifecycle: reg.identity.monitorLifecycle,
            notificationRevision: currentRevision,
            reasonBits: 0,
            topologyChangeHint: reason == .routeConfigurationChange || reason == .categoryChange,
            outputConfigurationChanged: false,
            observedRoute: nil
        )
        safetyIngress.receiveRegisteredRoute(ingress, registration: reg)
        
        registry.executor.sync {
            let state = self.registry.outputRouteObservationSnapshot()
            if case .pending(let pending) = state, let sampler = pending.sampler {
                _ = self.owner.sample(sampler, receiver: self)
            }
        }
    }
    
    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit, completion: AudioSessionBlockingCallCompletion) {
        registry.executor.sync {
            let snapshot = self.registry.outputRouteObservationSnapshot()
            guard case .pending(let pending) = snapshot, let observation = pending.ticket else { return }
            if let ticket = try? self.registry.armOutputRouteStability(observation: observation) {
                self.scheduleTimer(for: ticket)
            } else if self.registry.authoritativeRouteSnapshot() == .none {
                let (subscriberCopy, routeSnapshot, unavailableHandler) = self.lock.withLock {
                    self.revision += 1
                    let sub = self.subscriber
                    let handler = self.routeUnavailableHandler
                    let s = AudioOutputRouteSnapshot(ports: [], category: .none,
                        reason: .routeConfigurationChange, revision: self.revision, outputLatency: 0, ioBufferDuration: 0)
                    return (sub, s, handler)
                }
                subscriberCopy?(routeSnapshot)
                unavailableHandler?()
            }
        }
    }
    
    private func scheduleTimer(for ticket: RouteStabilityTicket) {
        precondition(registry.executor.isIsolated)
        guard lock.withLock({ sessionRegistration != nil }) else { return }
        stabilityTicket = ticket
        timer.schedule(notAfterInstant: ticket.deadlineInstant)
    }

    private func deliverStabilityWake() {
        precondition(registry.executor.isIsolated)
        guard let ticket = stabilityTicket else { return }
        if registry.clock.nowNanoseconds < ticket.deadlineInstant {
            timer.schedule(notAfterInstant: ticket.deadlineInstant)
            return
        }
        // 到期先移走本次准确槽；拒绝/错误都不重排，后续票只能来自新的合法样本。
        stabilityTicket = nil
        let commitResult = Result { try registry.commitOutputRouteStability(ticket) }
        guard case .success(let optCommit) = commitResult, let commit = optCommit else { return }
        registry.notifyPlaybackProgress()
        let commitHandler = lock.withLock { routeCommitHandler }
        commitHandler?(commit)
        let (subscriberCopy, snapshot) = lock.withLock {
            revision += 1
            return (subscriber, Self.snapshot(for: commit.authority, revision: revision))
        }
        subscriberCopy?(snapshot)
    }

    private static func snapshot(
        for authority: PlaybackRouteAuthorityIdentity,
        revision: UInt64
    ) -> AudioOutputRouteSnapshot {
        let ports = authority.semanticIdentity?.ports ?? []
        let category: AudioOutputRouteCategory
        if ports.contains(.airPlay) { category = .airPlay }
        else if ports.contains(.hdmi) { category = .hdmi }
        else if ports.contains(.bluetooth) { category = .bluetooth }
        else if ports.isEmpty { category = .none }
        else { category = .other }
        return AudioOutputRouteSnapshot(ports: ports, category: category,
            reason: .initial, revision: revision, outputLatency: 0, ioBufferDuration: 0)
    }
}
