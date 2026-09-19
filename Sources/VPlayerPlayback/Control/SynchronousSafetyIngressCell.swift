// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation

/// 只持有固定值安全shadow；资源context与SDK对象归共享executor的owner所有。
final class SynchronousSafetyIngressCell: @unchecked Sendable {
    private let lock = NSLock()
    private let allocator: PlaybackIdentityAllocator
    private let wakeSource: any DispatchSourceUserDataOr
    private let clock: any PlaybackMonotonicClock
    private let applyIngress: @Sendable (PlaybackSafetySnapshot) -> PlaybackSafetyIngressApplication
    private let applyTerminalIngress: @Sendable (PlaybackSafetySnapshot) -> Void
    private let applyOutputControl: @Sendable (OutputControlRequest, PlaybackSafetySnapshot) -> OutputControlApplication
    private var state = PlaybackSafetySnapshot()
    private var callbackDepth = PlaybackCallbackDepth(value: 0)

    init(
        allocator: PlaybackIdentityAllocator,
        wakeSource: any DispatchSourceUserDataOr,
        clock: any PlaybackMonotonicClock,
        applyIngress: @escaping @Sendable (PlaybackSafetySnapshot) -> PlaybackSafetyIngressApplication,
        applyTerminalIngress: @escaping @Sendable (PlaybackSafetySnapshot) -> Void,
        applyOutputControl: @escaping @Sendable (OutputControlRequest, PlaybackSafetySnapshot) -> OutputControlApplication
    ) {
        self.allocator = allocator
        self.wakeSource = wakeSource
        self.clock = clock
        self.applyIngress = applyIngress
        self.applyTerminalIngress = applyTerminalIngress
        self.applyOutputControl = applyOutputControl
    }

    var snapshot: PlaybackSafetySnapshot { lock.withLock { state } }

    /// 不执行barrier prelude：仅在原Cell锁内复制Authority已提交的只读投影。
    /// callback也能在此锁下折叠Authority，因此executor排序本身不足以保护读取。
    func withReadOnlyAuthorityProjection<Value>(_ body: () -> Value) -> Value {
        lock.withLock(body)
    }

    /// 正 rate SDK 副作用的唯一同步入口。调用线程必须已经在 SDK 所属 actor；
    /// Cell 在同一把锁内先折叠安全 ingress，再验收 Registry authority、消费单次
    /// capability，最后执行副作用，因此 callback 不可能插进“消费后、play 前”的窗口。
    func performPositiveRateSideEffect(
        validateAndConsume: (PlaybackOutputSafetyState) -> Bool,
        sideEffect: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while true {
            switch prepareBarrierLocked(.positiveRateAdmission) {
            case .retry: continue
            case .rejected: return false
            case .ready: break
            }
            break
        }
        guard state.failure == nil, !state.interruptionVeto, !state.userPaused,
              state.routeObservationGateOpen, state.readinessOpen,
              state.outputPermitPresent, validateAndConsume(state.output) else {
            return false
        }
        sideEffect()
        return true
    }

    /// 必须是framework callback的首个可观察动作；不生成排队闭包。
    func beginRouteObservation(_ ingress: PlaybackRouteIngress) {
        receive(route: ingress, system: nil)
    }

    @discardableResult
    func performSyncIngress(_ event: PlaybackSystemSafetyEvent) -> PlaybackSystemSafetyReceipt? {
        receive(route: nil, system: event)
    }

    func receiveRegisteredRoute(_ ingress: PlaybackRouteIngress, registration: PlaybackAudioSessionRegistration) {
        receive(route: ingress, system: nil, registration: registration)
    }

    @discardableResult
    private func receive(route: PlaybackRouteIngress?, system: PlaybackSystemSafetyEvent?,
        registration: PlaybackAudioSessionRegistration? = nil) -> PlaybackSystemSafetyReceipt? {
        lock.lock()
        guard state.failure == nil else { lock.unlock(); return nil }
        if let registration {
            guard let route, route.monitorLifecycle == registration.identity.monitorLifecycle,
                  route.sessionIdentity == registration.identity.sessionIdentity,
                  case .registrationValidated = applyOutputControl(.registrationIngress(registration), state)
            else { lock.unlock(); return nil }
        }
        let entered = callbackDepth.enter()
        if !entered {
            failClosed(.callbackDepthOverflow)
        } else {
            state.callbackDepth = callbackDepth.value
            // 所有新身份先签发到局部值，失败时只允许进入终态和撤权。
            do {
                let revision = try allocator.next(in: .safetyIngress)
                let instant = clock.nowNanoseconds // 持锁采样，避免线程竞争制造时间倒退。
                if let system {
                    try fold(system, at: instant, revision: revision)
                }
                if let route {
                    if state.firstRouteEventObservedInstant == nil { state.firstRouteEventObservedInstant = instant }
                    try fold(route)
                }
                state.throughRevision = revision
                state.safetyIngressPending = true
                revokeOutput()
            } catch let failure as PlaybackSafetyFailure {
                failClosed(failure)
            } catch {
                failClosed(.identitySpaceExhausted)
            }
        }
        let wake = !state.drainScheduled
        state.drainScheduled = true
        // 在原fold锁内冻结准确身份；解锁后再读snapshot会把后来的回调冒充本次事件。
        let receipt = state.failure == nil ? system.map {
            PlaybackSystemSafetyReceipt(event: $0, revision: state.throughRevision,
                mediaServicesEpoch: state.mediaServicesEpoch, interruptionEpoch: state.interruptionEpoch,
                audioAdmissionFenceRevision: state.audioAdmissionFenceRevision)
        } : nil
        lock.unlock()

        // 唤醒和callback退出均不创建Task、continuation或事件对象。
        if wake { wakeSource.or(data: 1) }
        if entered {
            lock.lock()
            if !callbackDepth.leave() { failClosed(.callbackDepthOverflow) }
            state.callbackDepth = callbackDepth.value
            lock.unlock()
        }
        return receipt
    }

    private func revokeOutput() {
        state.output.revokeForSafety()
    }

    private func failClosed(_ failure: PlaybackSafetyFailure) {
        if state.failure == nil {
            state.failure = failure
            state.firstFailureInstant = clock.nowNanoseconds
        }
        state.safetyIngressPending = true
        revokeOutput()
        // callback与非callback失败共用已登记user-data源；不会新增投递闭包。
        if !state.drainScheduled { state.drainScheduled = true; wakeSource.or(data: 1) }
    }

    private func fold(_ route: PlaybackRouteIngress) throws {
        guard route.reasonBits & 0b1100_0000 == 0,
              route.observedRoute.map({ $0.ports.rawValue & 0b1110_0000 == 0 }) ?? true else {
            throw PlaybackSafetyFailure.invalidEvidence
        }
        var latest = route
        if let previous = state.route {
            guard previous.sessionIdentity == route.sessionIdentity,
                  previous.monitorLifecycle == route.monitorLifecycle else {
                throw PlaybackSafetyFailure.invalidEvidence
            }
            if previous.notificationRevision > route.notificationRevision { latest = previous }
            latest.reasonBits = route.reasonBits | previous.reasonBits
            latest.topologyChangeHint = route.topologyChangeHint || previous.topologyChangeHint
            latest.outputConfigurationChanged = route.outputConfigurationChanged || previous.outputConfigurationChanged
            // 倒序证据不被当成稳定证明；pending gate始终关闭，后续sampler必须重读。
        }
        state.route = latest
    }

    private func fold(_ event: PlaybackSystemSafetyEvent, at instant: UInt64, revision: UInt64) throws {
        let systemRevision = try allocator.next(in: .systemEvent)
        let fence = try allocator.next(in: .admissionFence)
        var pending = state.system
        var interruption = state.interruptionState
        var interruptionEpoch = state.interruptionEpoch
        var mediaServicesEpoch = state.mediaServicesEpoch
        var freezeGeneration = state.freezeGeneration
        var veto = state.interruptionVeto
        if pending.interruptionClockFold == nil {
            pending.interruptionClockFold = ResetPreRouteClockFold(
                windowStartInstant: instant, lastIngressInstant: instant,
                frozen: state.userPaused || interruption == .began, freezeGeneration: freezeGeneration
            )
        }
        switch event {
        case .mediaServicesReset:
            let root = try allocator.next(in: .resetRoot)
            mediaServicesEpoch = try allocator.next(in: .mediaServices)
            if pending.firstUndrainedResetIngressInstant == nil {
                pending.firstUndrainedResetIngressInstant = instant
                pending.resetPreRouteClockFold = ResetPreRouteClockFold(
                    windowStartInstant: instant, lastIngressInstant: instant,
                    frozen: state.userPaused || interruption == .began, freezeGeneration: freezeGeneration
                )
            }
            pending.latestResetIngress = PendingResetIngress(
                rootIdentity: root, mediaServicesEpoch: mediaServicesEpoch,
                audioAdmissionFenceRevision: fence, ingressInstant: instant
            )
        case .interruptionBegan:
            if pending.firstInterruptionBeganIngressInstant == nil { pending.firstInterruptionBeganIngressInstant = instant }
            interruptionEpoch = try allocator.next(in: .interruption)
            if interruption != .began { freezeGeneration = try allocator.next(in: .freezeGeneration) }
            interruption = .began
            veto = true
        case .interruptionEnded(let shouldResume):
            interruptionEpoch = try allocator.next(in: .interruption)
            if interruption == .began { freezeGeneration = try allocator.next(in: .freezeGeneration) }
            interruption = .ended(shouldResume: shouldResume)
            veto = !shouldResume
        }
        try pending.resetPreRouteClockFold?.advance(
            to: instant, frozen: state.userPaused || interruption == .began, freezeGeneration: freezeGeneration
        )
        try pending.interruptionClockFold?.advance(
            to: instant, frozen: state.userPaused || interruption == .began, freezeGeneration: freezeGeneration
        )
        pending.latestInterruptionState = interruption
        pending.throughRevision = revision
        state.system = pending
        state.ownerSystemEventRevision = systemRevision
        state.audioAdmissionFenceRevision = fence
        state.mediaServicesEpoch = mediaServicesEpoch
        state.interruptionEpoch = interruptionEpoch
        state.freezeGeneration = freezeGeneration
        state.interruptionState = interruption
        state.interruptionVeto = veto
    }

    /// 仅由共享executor调用。apply与目标CAS均无逃逸、无await且持有同一cell锁。
    /// 只能改固定值/转移预留owned record，不得调用SDK、重入或在这里析构资源对象。
    func withSafetyIngressBarrier<Value>(
        operationDescriptor: PlaybackControlOperationDescriptor,
        operation: (inout PlaybackOutputSafetyState) -> Value
    ) -> PlaybackSafetyBarrierResult<Value> {
        lock.lock()
        defer { lock.unlock() }
        switch prepareBarrierLocked(operationDescriptor) {
        case .retry: return .retry
        case .rejected: return .rejected
        case .ready: break
        }
        if operationDescriptor == .cleanupOwnership {
            let output = state.output
            let value = operation(&state.output)
            state.output = output
            return .performed(value)
        }
        guard state.failure == nil else { return .rejected }
        switch operationDescriptor {
        case .factoryAdmission, .prepareAdmission, .selectionAdmission, .probeAdmission:
            // 普通用户pause仅撤正rate授权；rate-0准备不失效，也不能被暂停意图饿死。
            guard !state.interruptionVeto, state.routeObservationGateOpen else { return .rejected }
        case .activationAdmission, .positiveRateAdmission:
            guard !state.interruptionVeto, !state.userPaused, state.routeObservationGateOpen else { return .rejected }
            if operationDescriptor == .positiveRateAdmission {
                guard state.readinessOpen, state.outputPermitPresent else { return .rejected }
            }
        case .resourceOwnership, .cleanupOwnership, .drain: break
        }
        return .performed(operation(&state.output))
    }

    func performUserControl(_ request: OutputUserControlRequest) -> PlaybackSafetyBarrierResult<OutputUserControlResult> {
        switch performOutputControl(.user(request)) {
        case .retry: return .retry
        case .rejected: return .rejected
        case .performed(.applied(_, let result)): return .performed(result)
        default: return .performed(.rejected)
        }
    }

    func retireOutputControlRecord(_ ticket: ControlTaskTicket) -> PlaybackSafetyBarrierResult<OutputControlRecordRetirement> {
        switch performOutputControl(.retire(ticket)) {
        case .retry: return .retry
        case .rejected: return .rejected
        case .performed(.retired(let followUp, _)): return .performed(.retired(followUp: followUp))
        case .performed(.terminated): return .performed(.retired(followUp: nil))
        default: return .performed(.rejected)
        }
    }

    func settleOutputInterruptionDrain(owner: OutputTransitionOwnerTicket) -> PlaybackSafetyBarrierResult<OutputInterruptionDrainSettlement> {
        switch performOutputControl(.interruptionDrain(owner)) {
        case .retry: return .retry
        case .rejected: return .rejected
        case .performed(.interruptionSettled(let proof, let followUp, _)):
            return .performed(.settled(proof: proof, followUp: followUp))
        default: return .performed(.rejected)
        }
    }

    func performOutputSuspend(_ action: OutputSuspendControlAction) -> PlaybackSafetyBarrierResult<OutputSuspendControlResult> {
        switch performOutputControl(.suspend(action)) {
        case .retry: return .retry
        case .rejected: return .rejected
        case .performed(.suspend(let result, _)): return .performed(result)
        default: return .rejected
        }
    }

    func performPlaybackBudget(
        _ action: PlaybackBudgetControlAction
    ) -> PlaybackSafetyBarrierResult<OutputControlApplication> {
        performOutputControl(.budget(action))
    }

    func performAudioSessionCall(_ action: AudioSessionBlockingCallAction)
        -> PlaybackSafetyBarrierResult<AudioSessionBlockingCallApplication> {
        switch performOutputControl(.audioSessionCall(action)) {
        case .retry: .retry
        case .performed(.audioSessionCall(let value)): .performed(value)
        default: .rejected
        }
    }

    /// relay先释放自己的锁；这里只持有唯一Cell锁，不排队、不等待receiver。
    func currentOwnedAudioEventRelay() -> PlaybackAudioSessionEventRelay? {
        while true {
            switch performOutputControl(.audioEventRelayLookup) {
            case .retry: continue
            case .performed(.audioEventRelay(let relay)): return relay
            default: return nil
            }
        }
    }

    func receiveAudioRelayOverflow(recordNonce: UInt64) {
        while true {
            switch performOutputControl(.audioRelayOverflow(recordNonce: recordNonce)) {
            case .retry: continue
            case .performed, .rejected: return
            }
        }
    }

    func performPlaybackAdmission(requestID: UUID) -> PlaybackSafetyBarrierResult<PlaybackRequestAdmissionResult> {
        switch performOutputControl(.playbackAdmission(requestID)) {
        case .retry: .retry
        case .performed(.playbackAdmitted(let admission, _, _)): .performed(.admitted(admission))
        case .performed(.playbackAdmissionNeedsCleanupJoin): .performed(.needsCleanupJoin)
        default: .rejected
        }
    }

    private func performOutputControl(_ request: OutputControlRequest) -> PlaybackSafetyBarrierResult<OutputControlApplication> {
        lock.lock()
        defer { lock.unlock() }
        let descriptor: PlaybackControlOperationDescriptor
        switch request {
        case .playbackAdmission, .user, .interruptionDrain: descriptor = .resourceOwnership
        case .retire, .suspend, .budget, .audioSessionCall, .registrationIngress, .audioRelayOverflow,
             .audioEventRelayLookup: descriptor = .cleanupOwnership
        }
        switch prepareBarrierLocked(descriptor) {
        case .retry: return .retry
        case .rejected:
            // 只有已返回的准确SDK completion可在fold失败后继续归还物理责任。
            guard case .audioSessionCall(.complete) = request else { return .rejected }
        case .ready: break
        }
        if descriptor == .resourceOwnership, state.failure != nil { return .rejected }
        let application = applyOutputControl(request, state)
        switch application {
        case .playbackAdmitted(_, let output, let freeze):
            state.userPaused = false
            state.output = output
            state.freezeGeneration = freeze
            return .performed(application)
        case .registrationValidated: return .performed(.rejected) // 验证值只供receive在同锁立即消费。
        case .audioSessionCall(let value):
            if case .claimRejected(let output, let freeze, let fence, let failure) = value {
                if let failure { failClosed(failure) }
                if state.failure == nil {
                    state.output = output
                    state.freezeGeneration = freeze
                    state.audioAdmissionFenceRevision = fence
                } else { revokeOutput(); applyTerminalIngress(state) }
                // 只结算claim的安全更新，不签发permit或伪造SDK completion。
                return .performed(.audioSessionCall(.rejected))
            }
            if case .completed(let completion, let output, let freeze, let fence) = value {
                if let failure = completion.failure { failClosed(failure) }
                if state.failure == nil {
                    state.output = output
                    state.freezeGeneration = freeze
                    state.audioAdmissionFenceRevision = fence
                } else { revokeOutput(); applyTerminalIngress(state) }
            }
            return .performed(application)
        case .playbackAdmissionNeedsCleanupJoin: return .performed(application)
        case .rejected: return .performed(.rejected)
        case .terminated:
            revokeOutput()
            return .performed(.terminated)
        case .applied(let update, let result):
            state.userPaused = update.userPaused
            state.interruptionVeto = update.interruptionVeto
            state.freezeGeneration = update.freezeGeneration
            if case .user(let user) = request, user.kind == .pause { state.output.revokeForUserPause() }
            return .performed(.applied(update, result))
        case .retired(_, let clearsVeto), .interruptionSettled(_, _, let clearsVeto):
            if clearsVeto { state.interruptionVeto = false }
            return .performed(application)
        case .routeSampleSettled, .audioEventRelay: return .performed(application)
        case .routeSampled(let generation, let fence, let gateOpen, _):
            state.freezeGeneration = generation
            state.audioAdmissionFenceRevision = fence
            state.output.routeObservationGateOpen = gateOpen
            return .performed(application)
        case .suspend(let result, let preservesRoute):
            switch result {
            case .accepted:
                if preservesRoute { state.output.revokeForUserPause() }
                else { revokeOutput() }
            case .timedOut: revokeOutput()
            case .rearmed: break
            }
            return .performed(application)
        case .budget:
            return .performed(application)
        case .failed(let failure):
            failClosed(failure)
            applyTerminalIngress(state)
            clearPendingIngress()
            return .rejected
        }
    }

    private enum BarrierPrelude { case retry, rejected, ready }

    private func prepareBarrierLocked(_ operationDescriptor: PlaybackControlOperationDescriptor) -> BarrierPrelude {
        if state.safetyIngressPending {
            if state.failure != nil {
                applyTerminalIngress(state)
            } else if case .failed(let failure) = applyIngress(state) {
                failClosed(failure)
                applyTerminalIngress(state)
                clearPendingIngress()
                if operationDescriptor == .drain { state.drainScheduled = false }
                return .rejected
            }
            clearPendingIngress()
            if operationDescriptor == .drain { state.drainScheduled = false }
            return .retry
        }
        if operationDescriptor == .drain { state.drainScheduled = false }
        // allocator可能由别的身份使用方耗尽；这里同样先交付终态再retry。
        if state.failure == nil, allocator.isExhausted {
            failClosed(.identitySpaceExhausted)
            applyTerminalIngress(state)
            clearPendingIngress()
            return .retry
        }
        return .ready
    }

    private func clearPendingIngress() {
        state.safetyIngressPending = false
        state.system = PendingSystemSafetyIngress(latestInterruptionState: state.interruptionState)
        state.route = nil
        state.firstRouteEventObservedInstant = nil
    }
}
