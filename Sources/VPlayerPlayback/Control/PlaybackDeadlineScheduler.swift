// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation

protocol PlaybackNaturalEndDeadlineReceiving: AnyObject, Sendable {
    func naturalEndDeadlineFired(identity: UUID)
}

/// 八张准确票的一次Authority投影；仅在reconcile栈上存在，不是第二份常驻账本。
struct PlaybackDeadlineScheduleSnapshot: Sendable, Equatable {
    var acquisition: AudioSessionAcquisitionDeadline?
    var cleanup: CleanupBudgetTicket?
    var ordinaryRoute: RouteUnavailableDeadlineArmTicket?
    var resetPreRoute: ResetPreRouteRecoveryDeadlineArmTicket?
    var postConfiguration: PostConfigurationRouteDeadlineArmTicket?
    var reactivation: AudioSessionReactivationCutoffArmTicket?
    var playbackOperation: PlaybackOperationDeadlineArmTicket?
    var suspend: OutputSuspendTicket?
}

/// owned-control归属：固定对象、锁和最多一个准确等待键；不保存事件或动态队列。
enum PlaybackControlProgressWait: Sendable {
    case acquisition(ControlTaskTicket)
    case route(PlaybackSessionIdentity)
    case cleanup(OutputTransitionOwnerTicket)
}

final class PlaybackControlProgressSignal: @unchecked Sendable {
    struct Key: Equatable { let phase: UInt8; let nonce: UInt64 }
    enum Registration { case parked, ready, rejected }
    private struct Waiter {
        let key: Key
        let continuation: CheckedContinuation<Bool, Never>
    }
    private let lock = NSLock()
    private var pendingWake = false
    private var waiter: Waiter?

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            if let current = waiter { waiter = nil; return current.continuation }
            pendingWake = true
            return nil
        }
        continuation?.resume(returning: true)
    }

    /// 仅由Registry在准确owner/phase CAS内部登记；第二个caller被拒绝并退出原流程。
    func register(_ continuation: CheckedContinuation<Bool, Never>, key: Key) -> Registration {
        lock.withLock {
            guard waiter == nil else { return .rejected }
            if pendingWake { pendingWake = false; return .ready }
            waiter = .init(key: key, continuation: continuation)
            return .parked
        }
    }
}

/// 只保存八个固定具名timer槽；票据是否仍有权由第三Cell receiver内的唯一Authority裁决。
final class PlaybackDeadlineScheduler: @unchecked Sendable {
    private struct Slot<Value: Sendable & Equatable>: Sendable, Equatable {
        let value: Value
        let notAfterInstant: UInt64
        var deliveryInFlight: Bool
    }

    /// 本枚举只在一次投递栈上存在，不会以最大payload乘八常驻。
    private enum Delivery: Sendable, Equatable {
        case acquisition(AudioSessionAcquisitionDeadline)
        case cleanup(CleanupBudgetTicket)
        case ordinaryRoute(RouteUnavailableDeadlineArmTicket)
        case resetPreRoute(ResetPreRouteRecoveryDeadlineArmTicket)
        case postConfiguration(PostConfigurationRouteDeadlineArmTicket)
        case reactivation(AudioSessionReactivationCutoffArmTicket)
        case playbackOperation(PlaybackOperationDeadlineArmTicket)
        case suspend(OutputSuspendTicket)
        case naturalEnd(UUID)
    }

    private enum Scheduled: Sendable, Equatable {
        case acquisition(AudioSessionAcquisitionDeadline, UInt64)
        case cleanup(CleanupBudgetTicket, UInt64)
        case ordinaryRoute(RouteUnavailableDeadlineArmTicket, UInt64)
        case resetPreRoute(ResetPreRouteRecoveryDeadlineArmTicket, UInt64)
        case postConfiguration(PostConfigurationRouteDeadlineArmTicket, UInt64)
        case reactivation(AudioSessionReactivationCutoffArmTicket, UInt64)
        case playbackOperation(PlaybackOperationDeadlineArmTicket, UInt64)
    }

    static var fixedValueStorageBytes: Int {
        MemoryLayout<any PlaybackDeadlineTimer>.stride +
            DispatchPlaybackMonotonicClock.deadlineTimerAdapterFixedValueBytes +
            MemoryLayout<ControlTaskRegistry>.stride +
            MemoryLayout<NSLock>.stride +
            MemoryLayout<Slot<AudioSessionAcquisitionDeadline>?>.stride +
            MemoryLayout<Slot<CleanupBudgetTicket>?>.stride +
            MemoryLayout<Slot<RouteUnavailableDeadlineArmTicket>?>.stride +
            MemoryLayout<Slot<ResetPreRouteRecoveryDeadlineArmTicket>?>.stride +
            MemoryLayout<Slot<PostConfigurationRouteDeadlineArmTicket>?>.stride +
            MemoryLayout<Slot<AudioSessionReactivationCutoffArmTicket>?>.stride +
            MemoryLayout<Slot<PlaybackOperationDeadlineArmTicket>?>.stride +
            MemoryLayout<Slot<OutputSuspendTicket>?>.stride +
            MemoryLayout<@Sendable () -> Void>.stride
    }

    static var boundedDeliveryPreparationValueBytes: Int {
        // 一个在途票、一个返回的准确排期和caller返回槽与Registry预算准备同时存活。
        MemoryLayout<Delivery>.stride + MemoryLayout<Scheduled?>.stride +
            MemoryLayout<OutputControlApplication?>.stride + MemoryLayout<UInt64?>.stride
    }

    static var deliveryValueBytes: Int { MemoryLayout<Delivery>.stride }
    static var scheduledOptionalValueBytes: Int { MemoryLayout<Scheduled?>.stride }

    private let registry: ControlTaskRegistry
    private let timer: any PlaybackDeadlineTimer
    private let lock = NSLock()
    private var acquisition: Slot<AudioSessionAcquisitionDeadline>?
    private var cleanup: Slot<CleanupBudgetTicket>?
    private var ordinaryRoute: Slot<RouteUnavailableDeadlineArmTicket>?
    private var resetPreRoute: Slot<ResetPreRouteRecoveryDeadlineArmTicket>?
    private var postConfiguration: Slot<PostConfigurationRouteDeadlineArmTicket>?
    private var reactivation: Slot<AudioSessionReactivationCutoffArmTicket>?
    private var playbackOperation: Slot<PlaybackOperationDeadlineArmTicket>?
    private var suspend: Slot<OutputSuspendTicket>?
    private struct NaturalEndSlot {
        let identity: UUID
        let invocation: ControlTaskRegistry.BackendPositiveRateInvocation
        let item: AVPlayerItemInstanceIdentity
        let notAfterInstant: UInt64
        weak var receiver: (any PlaybackNaturalEndDeadlineReceiving)?
        var deliveryInFlight = false
    }
    private var naturalEnd: NaturalEndSlot?

    func armNaturalEnd(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
                       item: AVPlayerItemInstanceIdentity, identity: UUID,
                       receiver: any PlaybackNaturalEndDeadlineReceiving) -> Bool {
        registry.executor.sync {
            guard let snapshot = invocation.currentSnapshot,
                  snapshot.interval.outputLifecycle == item.outputLifecycleEpoch,
                  snapshot.interval.itemGeneration == item.itemGeneration else { return false }
            let deadline = registry.clock.nowNanoseconds.addingReportingOverflow(100_000_000)
            guard !deadline.overflow else { return false }
            return lock.withLock {
                guard naturalEnd == nil else { return false }
                naturalEnd = .init(identity: identity, invocation: invocation, item: item,
                    notAfterInstant: deadline.partialValue, receiver: receiver)
                rescheduleLocked()
                return true
            }
        }
    }

    func cancelNaturalEnd(_ identity: UUID) {
        lock.withLock {
            guard naturalEnd?.identity == identity else { return }
            naturalEnd = nil
            rescheduleLocked()
        }
    }

    init(registry: ControlTaskRegistry) {
        self.registry = registry
        timer = registry.makePlaybackDeadlineTimer()
        timer.schedule(notAfterInstant: nil)
        timer.setEventHandler { [weak self] in self?.deliverDueSlots() }
        timer.activate()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }

    func armAcquisition(_ expected: AudioSessionAcquisitionDeadline) { arm(.acquisition(expected)) }
    func armCleanup(_ expected: CleanupBudgetTicket) { arm(.cleanup(expected)) }
    func armOrdinaryRoute(_ expected: RouteUnavailableDeadlineArmTicket) { arm(.ordinaryRoute(expected)) }
    func armResetPreRoute(_ expected: ResetPreRouteRecoveryDeadlineArmTicket) { arm(.resetPreRoute(expected)) }
    func armPostConfiguration(_ expected: PostConfigurationRouteDeadlineArmTicket) {
        arm(.postConfiguration(expected))
    }
    func armReactivation(_ expected: AudioSessionReactivationCutoffArmTicket) { arm(.reactivation(expected)) }
    func armPlaybackOperation(_ expected: PlaybackOperationDeadlineArmTicket) { arm(.playbackOperation(expected)) }

    func armSuspend(_ expected: OutputSuspendTicket) {
        arm(.suspend(expected))
    }

    func cancelAcquisition(_ expected: AudioSessionAcquisitionDeadline) {
        cancel(expected, at: \Self.acquisition)
    }
    func cancelCleanup(_ expected: CleanupBudgetTicket) { cancel(expected, at: \Self.cleanup) }
    func cancelOrdinaryRoute(_ expected: RouteUnavailableDeadlineArmTicket) {
        cancel(expected, at: \Self.ordinaryRoute)
    }
    func cancelResetPreRoute(_ expected: ResetPreRouteRecoveryDeadlineArmTicket) {
        cancel(expected, at: \Self.resetPreRoute)
    }
    func cancelPostConfiguration(_ expected: PostConfigurationRouteDeadlineArmTicket) {
        cancel(expected, at: \Self.postConfiguration)
    }
    func cancelReactivation(_ expected: AudioSessionReactivationCutoffArmTicket) {
        cancel(expected, at: \Self.reactivation)
    }
    func cancelPlaybackOperation(_ expected: PlaybackOperationDeadlineArmTicket) {
        cancel(expected, at: \Self.playbackOperation)
    }
    func cancelSuspend(_ expected: OutputSuspendTicket) { cancel(expected, at: \Self.suspend) }

    func cancelAll() {
        registry.executor.sync {
            lock.withLock {
                acquisition = nil
                cleanup = nil
                ordinaryRoute = nil
                resetPreRoute = nil
                postConfiguration = nil
                reactivation = nil
                playbackOperation = nil
                suspend = nil
                naturalEnd = nil
                rescheduleLocked()
            }
        }
    }

    /// 准确差异才arm/cancel；同票reconcile不再次签发ordinary arm或续绝对边界。
    func reconcile(_ snapshot: PlaybackDeadlineScheduleSnapshot) {
        registry.executor.sync {
            func update<Value: Sendable & Equatable>(_ expected: Value?,
                at path: ReferenceWritableKeyPath<PlaybackDeadlineScheduler, Slot<Value>?>,
                delivery: (Value) -> Delivery) {
                let current = lock.withLock { self[keyPath: path]?.value }
                guard current != expected else { return }
                if let current { cancel(current, at: path) }
                if let expected { arm(delivery(expected)) }
            }
            update(snapshot.acquisition, at: \Self.acquisition, delivery: Delivery.acquisition)
            update(snapshot.cleanup, at: \Self.cleanup, delivery: Delivery.cleanup)
            update(snapshot.ordinaryRoute, at: \Self.ordinaryRoute, delivery: Delivery.ordinaryRoute)
            update(snapshot.resetPreRoute, at: \Self.resetPreRoute, delivery: Delivery.resetPreRoute)
            update(snapshot.postConfiguration, at: \Self.postConfiguration, delivery: Delivery.postConfiguration)
            update(snapshot.reactivation, at: \Self.reactivation, delivery: Delivery.reactivation)
            update(snapshot.playbackOperation, at: \Self.playbackOperation, delivery: Delivery.playbackOperation)
            update(snapshot.suspend, at: \Self.suspend, delivery: Delivery.suspend)
        }
    }

    func playbackOperationArmSnapshot() -> PlaybackOperationDeadlineArmTicket? {
        lock.withLock { playbackOperation?.value }
    }
    func acquisitionDeadlineSnapshot() -> AudioSessionAcquisitionDeadline? {
        lock.withLock { acquisition?.value }
    }
    func cleanupDeadlineSnapshot() -> CleanupBudgetTicket? { lock.withLock { cleanup?.value } }
    func ordinaryRouteArmSnapshot() -> RouteUnavailableDeadlineArmTicket? {
        lock.withLock { ordinaryRoute?.value }
    }
    func resetPreRouteArmSnapshot() -> ResetPreRouteRecoveryDeadlineArmTicket? {
        lock.withLock { resetPreRoute?.value }
    }
    func resetPreRouteNotAfterInstantSnapshot() -> UInt64? {
        lock.withLock { resetPreRoute?.notAfterInstant }
    }
    func postConfigurationArmSnapshot() -> PostConfigurationRouteDeadlineArmTicket? {
        lock.withLock { postConfiguration?.value }
    }
    func reactivationArmSnapshot() -> AudioSessionReactivationCutoffArmTicket? {
        lock.withLock { reactivation?.value }
    }
    func suspendTicketSnapshot() -> OutputSuspendTicket? { lock.withLock { suspend?.value } }
    func suspendNotAfterInstantSnapshot() -> UInt64? {
        lock.withLock { suspend?.notAfterInstant }
    }

    private func arm(_ delivery: Delivery) {
        registry.executor.sync {
            // 在唯一executor上先让Authority验票，较早返回的arm不能覆盖后来准备。
            var suspendNotAfter: UInt64?
            let scheduled = deliver(delivery, suspendNotAfter: &suspendNotAfter)
            lock.withLock {
                guard scheduled != nil || suspendNotAfter != nil else {
                    clearIfMatchingLocked(delivery)
                    rescheduleLocked()
                    return
                }
                if let scheduled { installLocked(scheduled) }
                if case .suspend(let ticket) = delivery, let suspendNotAfter {
                    suspend = .init(value: ticket, notAfterInstant: suspendNotAfter,
                        deliveryInFlight: false)
                }
                rescheduleLocked()
            }
        }
    }

    private func cancel<Value: Sendable & Equatable>(
        _ expected: Value, at keyPath: ReferenceWritableKeyPath<PlaybackDeadlineScheduler, Slot<Value>?>
    ) {
        registry.executor.sync {
            lock.withLock {
                guard self[keyPath: keyPath]?.value == expected else { return }
                self[keyPath: keyPath] = nil
                rescheduleLocked()
            }
        }
    }

    private func rescheduleLocked() {
        var earliest: UInt64?
        func include<Value>(_ slot: Slot<Value>?) {
            guard let slot, !slot.deliveryInFlight else { return }
            earliest = min(earliest ?? slot.notAfterInstant, slot.notAfterInstant)
        }
        include(acquisition)
        include(cleanup)
        include(ordinaryRoute)
        include(resetPreRoute)
        include(postConfiguration)
        include(reactivation)
        include(playbackOperation)
        include(suspend)
        if let naturalEnd, !naturalEnd.deliveryInFlight {
            earliest = min(earliest ?? naturalEnd.notAfterInstant, naturalEnd.notAfterInstant)
        }
        guard let earliest else {
            timer.schedule(notAfterInstant: nil)
            return
        }
        timer.schedule(notAfterInstant: earliest)
    }

    private func takeDueLocked() -> Delivery? {
        var selected: (wake: UInt64, ordinal: Int)?
        func consider<Value>(_ slot: Slot<Value>?, ordinal: Int) {
            guard let slot, !slot.deliveryInFlight,
                  slot.notAfterInstant <= (selected?.wake ?? .max) else { return }
            selected = (slot.notAfterInstant, ordinal)
        }
        consider(acquisition, ordinal: 0)
        consider(cleanup, ordinal: 1)
        consider(ordinaryRoute, ordinal: 2)
        consider(resetPreRoute, ordinal: 3)
        consider(postConfiguration, ordinal: 4)
        consider(reactivation, ordinal: 5)
        consider(playbackOperation, ordinal: 6)
        consider(suspend, ordinal: 7)
        if let naturalEnd, !naturalEnd.deliveryInFlight,
           naturalEnd.notAfterInstant <= (selected?.wake ?? .max) {
            selected = (naturalEnd.notAfterInstant, 8)
        }
        guard let ordinal = selected?.ordinal else { return nil }
        switch ordinal {
        case 0: acquisition!.deliveryInFlight = true; return .acquisition(acquisition!.value)
        case 1: cleanup!.deliveryInFlight = true; return .cleanup(cleanup!.value)
        case 2: ordinaryRoute!.deliveryInFlight = true; return .ordinaryRoute(ordinaryRoute!.value)
        case 3: resetPreRoute!.deliveryInFlight = true; return .resetPreRoute(resetPreRoute!.value)
        case 4: postConfiguration!.deliveryInFlight = true; return .postConfiguration(postConfiguration!.value)
        case 5: reactivation!.deliveryInFlight = true; return .reactivation(reactivation!.value)
        case 6: playbackOperation!.deliveryInFlight = true; return .playbackOperation(playbackOperation!.value)
        case 7: suspend!.deliveryInFlight = true; return .suspend(suspend!.value)
        default: naturalEnd!.deliveryInFlight = true; return .naturalEnd(naturalEnd!.identity)
        }
    }

    private func deliverDueSlots() {
        // 每个source事件只投递一票；即使测试时钟暂停于早醒时刻，也会归还串行executor。
        let due = lock.withLock { () -> Delivery? in
            let value = takeDueLocked()
            rescheduleLocked()
            return value
        }
        guard let due else { return }
        if case .naturalEnd(let identity) = due {
            let slot = lock.withLock { naturalEnd?.identity == identity ? naturalEnd : nil }
            guard let slot else { return }
            guard registry.clock.nowNanoseconds >= slot.notAfterInstant else {
                lock.withLock {
                    if naturalEnd?.identity == identity { naturalEnd?.deliveryInFlight = false }
                    rescheduleLocked()
                }
                return
            }
            guard let snapshot = slot.invocation.currentSnapshot,
                  snapshot.interval.outputLifecycle == slot.item.outputLifecycleEpoch,
                  snapshot.interval.itemGeneration == slot.item.itemGeneration,
                  let receiver = slot.receiver else {
                cancelNaturalEnd(identity)
                return
            }
            receiver.naturalEndDeadlineFired(identity: identity)
            return
        }
        var suspendNotAfter: UInt64?
        let scheduled = deliver(due, suspendNotAfter: &suspendNotAfter)
        lock.withLock {
            finishLocked(due, scheduled: scheduled, suspendNotAfter: suspendNotAfter)
            rescheduleLocked()
        }
        if registry.outputResourceContextSnapshot()?.poisoned == true { cancelAll() }
        registry.notifyPlaybackProgress()
    }

    private func deliver(_ value: Delivery, suspendNotAfter: inout UInt64?) -> Scheduled? {
        let application: OutputControlApplication?
        switch value {
        case .naturalEnd: return nil
        case .acquisition(let deadline):
            application = registry.executor.performPlaybackBudget(.acquisitionTimer(deadline))
        case .cleanup(let budget):
            application = registry.executor.performPlaybackBudget(.cleanupTimer(budget))
        case .ordinaryRoute(let arm):
            application = registry.executor.performPlaybackBudget(.ordinaryRouteTimer(arm))
        case .resetPreRoute(let arm):
            application = registry.executor.performPlaybackBudget(.resetPreRouteTimer(arm))
        case .postConfiguration(let arm):
            application = registry.executor.performPlaybackBudget(.postConfigurationTimer(arm))
        case .reactivation(let arm):
            application = registry.executor.performPlaybackBudget(.reactivationTimer(arm))
        case .playbackOperation(let arm):
            application = registry.executor.performPlaybackBudget(.playbackOperationTimer(arm))
        case .suspend(let ticket):
            guard let result = registry.executor.performOutputSuspend(.timeout(ticket)) else { return nil }
            switch result {
            case .rearmed(_, let notAfter): suspendNotAfter = notAfter; return nil
            case .accepted, .timedOut: return nil
            }
        }
        guard case .budget(let result) = application else { return nil }
        switch result {
        case .acquisitionRearmed(let deadline, _, let notAfter): return .acquisition(deadline, notAfter)
        case .cleanupRearmed(let budget, _, let notAfter): return .cleanup(budget, notAfter)
        case .ordinaryRouteRearmed(let value): return .ordinaryRoute(value.arm, value.notAfterInstant)
        case .resetPreRouteRearmed(let value): return .resetPreRoute(value.arm, value.notAfterInstant)
        case .postConfigurationRearmed(let value): return .postConfiguration(value.arm, value.notAfterInstant)
        case .reactivationRearmed(let value): return .reactivation(value.arm, value.notAfterInstant)
        case .playbackOperationRearmed(let value): return .playbackOperation(value.arm, value.notAfterInstant)
        case .rejected, .progressCompleted: return nil
        }
    }

    private func installLocked(_ value: Scheduled) {
        switch value {
        case .acquisition(let ticket, let wake):
            acquisition = .init(value: ticket, notAfterInstant: wake, deliveryInFlight: false)
        case .cleanup(let ticket, let wake):
            cleanup = .init(value: ticket, notAfterInstant: wake, deliveryInFlight: false)
        case .ordinaryRoute(let arm, let wake):
            ordinaryRoute = .init(value: arm, notAfterInstant: wake, deliveryInFlight: false)
        case .resetPreRoute(let arm, let wake):
            resetPreRoute = .init(value: arm, notAfterInstant: wake, deliveryInFlight: false)
        case .postConfiguration(let arm, let wake):
            postConfiguration = .init(value: arm, notAfterInstant: wake, deliveryInFlight: false)
        case .reactivation(let arm, let wake):
            reactivation = .init(value: arm, notAfterInstant: wake, deliveryInFlight: false)
        case .playbackOperation(let arm, let wake):
            playbackOperation = .init(value: arm, notAfterInstant: wake, deliveryInFlight: false)
        }
    }

    private func clearIfMatchingLocked(_ value: Delivery) {
        switch value {
        case .acquisition(let expected) where acquisition?.value == expected: acquisition = nil
        case .cleanup(let expected) where cleanup?.value == expected: cleanup = nil
        case .ordinaryRoute(let expected) where ordinaryRoute?.value == expected: ordinaryRoute = nil
        case .resetPreRoute(let expected) where resetPreRoute?.value == expected: resetPreRoute = nil
        case .postConfiguration(let expected) where postConfiguration?.value == expected: postConfiguration = nil
        case .reactivation(let expected) where reactivation?.value == expected: reactivation = nil
        case .playbackOperation(let expected) where playbackOperation?.value == expected: playbackOperation = nil
        case .suspend(let expected) where suspend?.value == expected: suspend = nil
        default: break
        }
    }

    private func finishLocked(_ delivered: Delivery, scheduled: Scheduled?, suspendNotAfter: UInt64?) {
        func matches<Value>(_ expected: Value, _ slot: Slot<Value>?) -> Bool {
            slot?.value == expected && slot?.deliveryInFlight == true
        }
        switch delivered {
        case .naturalEnd: return
        case .acquisition(let expected): guard matches(expected, acquisition) else { return }; acquisition = nil
        case .cleanup(let expected): guard matches(expected, cleanup) else { return }; cleanup = nil
        case .ordinaryRoute(let expected): guard matches(expected, ordinaryRoute) else { return }; ordinaryRoute = nil
        case .resetPreRoute(let expected): guard matches(expected, resetPreRoute) else { return }; resetPreRoute = nil
        case .postConfiguration(let expected):
            guard matches(expected, postConfiguration) else { return }; postConfiguration = nil
        case .reactivation(let expected): guard matches(expected, reactivation) else { return }; reactivation = nil
        case .playbackOperation(let expected):
            guard matches(expected, playbackOperation) else { return }; playbackOperation = nil
        case .suspend(let expected): guard matches(expected, suspend) else { return }; suspend = nil
        }
        if let scheduled { installLocked(scheduled) }
        if case .suspend(let ticket) = delivered, let suspendNotAfter {
            suspend = .init(value: ticket, notAfterInstant: suspendNotAfter,
                deliveryInFlight: false)
        }
    }
}
