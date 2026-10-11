// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFAudio
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
        let notificationObserver: Int
        let weakTargetAllocationCharges: Int

        var timerSourceAndPermanentHandlerAllocationCharges: Int {
            timerWrapper + timerSource + permanentHandlerCapture
        }
        var fixedObjectAllocationCharges: Int {
            serviceObject + serviceLock + timerWrapper + timerSource + routeMonitorObject
        }
        var total: Int {
            serviceObject + serviceLock + timerWrapper + timerSource + permanentHandlerCapture +
                routeMonitorObject + subscriberAdapterCapture + resampleSyncBridge + notificationObserver + weakTargetAllocationCharges
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
            // 原生 token 及包含弱引用、绑定 UUID 的回调；不保存逐通知任务或媒体数据。
            notificationObserver: 64 + 32 + 48 + 16,
            weakTargetAllocationCharges: 32)
    }
    private let registry: ControlTaskRegistry
    private let owner: PlaybackAudioSessionOwner
    private let safetyIngress: SynchronousSafetyIngressCell
    private var subscriber: (@Sendable (AudioOutputRouteSnapshot) -> Void)?
    private var routeCommitHandler: (@Sendable (StableRouteCommitIdentity) -> Void)?
    private var routeUnavailableHandler: (@Sendable () -> Void)?
    private var sessionRegistration: PlaybackAudioSessionRegistration?
    private let notificationCenter: NotificationCenter
    private var routeObserver: NSObjectProtocol?
    private var bindingID: UUID?
    private var routeSamplingPending = false
    private let timer: any PlaybackDeadlineTimer
    // 只有唯一executor读写本槽；handler不捕获票或timer，不产生逐次arm逃逸环境。
    private var stabilityTicket: RouteStabilityTicket?
    private let lock = NSLock()
    private var revision: UInt64 = 0
    
    init(registry: ControlTaskRegistry, owner: PlaybackAudioSessionOwner,
         notificationCenter: NotificationCenter = .default) {
        PlaybackRuntimeAllocationReservations.validateRouteAndGlobalCaps()
        self.registry = registry
        self.owner = owner
        self.safetyIngress = registry.executor.safetyIngress
        self.notificationCenter = notificationCenter
        self.timer = registry.makePlaybackDeadlineTimer()
        // 服务从创建到销毁始终拥有同一已激活源，尚未绑定session时仅无排期。
        timer.schedule(notAfterInstant: nil)
        timer.setEventHandler { [weak self] in self?.deliverStabilityWake() }
        timer.activate()
        registry.executor.bindRouteSamplingService(self)
    }

    deinit {
        if let routeObserver { notificationCenter.removeObserver(routeObserver) }
        timer.setEventHandler {}
        timer.cancel()
    }
    
    func bindSession(registration: PlaybackAudioSessionRegistration, initialSampler: ControlTaskTicket? = nil) {
        registry.executor.sync {
            if !lock.withLock({ sessionRegistration === registration }) {
                unbindSession()
                let id = UUID()
                lock.withLock {
                    self.sessionRegistration = registration
                    bindingID = id
                }
                // 先发布绑定再安装监听，安装过程中同步到达的通知也必须使旧输出失效。
                routeObserver = notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
                    object: nil, queue: nil) { [weak self] notification in
                        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                        self?.receiveRouteNotification(reason, bindingID: id)
                    }
            }
            if let sampler = initialSampler {
                _ = owner.sample(sampler, receiver: self)
            }
        }
    }
    
    func unbindSession() {
        registry.executor.sync {
            stabilityTicket = nil
            timer.schedule(notAfterInstant: nil)
            lock.withLock {
                sessionRegistration = nil
                bindingID = nil
                routeSamplingPending = false
            }
            if let routeObserver { notificationCenter.removeObserver(routeObserver) }
            routeObserver = nil
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
            let committedSnapshot = Self.snapshot(for: commit,
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
        guard publishRouteIngress(topologyChangeHint: reason == .routeConfigurationChange || reason == .categoryChange) else { return }
        registry.executor.sync { drainRouteSampling() }
    }

    private func receiveRouteNotification(_ reason: AVAudioSession.RouteChangeReason, bindingID: UUID) {
        _ = publishRouteIngress(topologyChangeHint: reason == .routeConfigurationChange || reason == .categoryChange,
            expectedBindingID: bindingID)
    }

    private func publishRouteIngress(topologyChangeHint: Bool, expectedBindingID: UUID? = nil) -> Bool {
        lock.withLock {
            guard let registration = sessionRegistration,
                  expectedBindingID == nil || expectedBindingID == bindingID else { return false }
            revision += 1
            routeSamplingPending = true
            // 同一把锁串行化解绑和发布；旧绑定的回调不能在重新绑定后撤销新路由。
            // Cell 仅折叠固定状态并唤醒既有事件源，不调用 SDK 或反向进入服务锁。
            safetyIngress.receiveRegisteredRoute(.init(
                sessionIdentity: registration.identity.sessionIdentity,
                monitorLifecycle: registration.identity.monitorLifecycle,
                notificationRevision: revision, reasonBits: 0,
                topologyChangeHint: topologyChangeHint,
                outputConfigurationChanged: false, observedRoute: nil), registration: registration)
            return true
        }
    }

    /// 在共享控制队列上领取唯一采样票；突发通知由既有 Cell 和事件源合并。
    func drainRouteSampling() {
        precondition(registry.executor.isIsolated)
        let registration = lock.withLock { () -> PlaybackAudioSessionRegistration? in
            guard routeSamplingPending else { return nil }
            routeSamplingPending = false
            return sessionRegistration
        }
        guard let registration,
              case .pending(let pending) = registry.outputRouteObservationSnapshot(),
              pending.ticket?.sessionIdentity == registration.identity.sessionIdentity,
              pending.ticket?.monitorLifecycle == registration.identity.monitorLifecycle,
              let sampler = pending.sampler else { return }
        _ = owner.sample(sampler, receiver: self)
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
            return (subscriber, Self.snapshot(for: commit, revision: revision))
        }
        subscriberCopy?(snapshot)
    }

    private static func snapshot(
        for commit: StableRouteCommitIdentity,
        revision: UInt64
    ) -> AudioOutputRouteSnapshot {
        let ports = commit.authority.semanticIdentity?.ports ?? []
        let category: AudioOutputRouteCategory
        if ports.contains(.airPlay) { category = .airPlay }
        else if ports.contains(.hdmi) { category = .hdmi }
        else if ports.contains(.bluetooth) { category = .bluetooth }
        else if ports.isEmpty { category = .none }
        else { category = .other }
        return AudioOutputRouteSnapshot(ports: ports, category: category,
            reason: .initial, revision: revision,
            outputLatency: commit.outputTiming.outputLatency,
            ioBufferDuration: commit.outputTiming.ioBufferDuration)
    }
}
