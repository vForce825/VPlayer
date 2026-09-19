// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import ObjectiveC

struct PlaybackRunIdentity: Equatable, Sendable {
    let sessionID: UInt64
    let requestID: UUID
}


final class PlaybackSessionEventRelay: @unchecked Sendable {
    typealias Receiver = @Sendable (PlaybackRunIdentity, PlaybackPipelineEvent) async -> Void
    static let maximumCapacity = 32
    /// reservation只冻结逻辑请求数；allocator公开capacity可随Swift runtime变化。
    static let fixedBackingCapacity = maximumCapacity

    struct SystemAndPipelineRelayAllocationReservation {
        let monitorObject: Int
        let monitorLock: Int
        let observerTokens: Int
        let observerCaptures: Int
        let pipelineRelayObject: Int
        let pipelineRelayLock: Int
        let pipelineBacking: Int
        let receiverCapture: Int
        let drainRunnerObject: Int
        let relayTaskSlabs: Int
        let drainTaskCaptures: Int
        let weakTargetAllocationCharges: Int

        /// previous/next各512B已包含旧尾同时存活；此别名不重复进入total。
        var relayOldTailOverlap: Int { relayTaskSlabs / 2 }
        var fixedObjectAllocationCharges: Int {
            monitorObject + monitorLock + pipelineRelayObject + pipelineRelayLock + drainRunnerObject
        }
        var fixedBackingAllocationCharges: Int { pipelineBacking }
        var total: Int {
            monitorObject + monitorLock + observerTokens + observerCaptures + pipelineRelayObject +
                pipelineRelayLock + pipelineBacking + receiverCapture + drainRunnerObject +
                relayTaskSlabs + drainTaskCaptures + weakTargetAllocationCharges
        }
    }

    static var systemAndPipelineRelayAllocationReservation: SystemAndPipelineRelayAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return .init(
            monitorObject: object(SystemAudioEventMonitor.self),
            monitorLock: object(NSLock.self),
            // 私有token当前目标实测32B/个；跨tvOS runtime按64B/个保守，framework其余opaque内部仍是盲区。
            observerTokens: 2 * 64,
            observerCaptures: 2 * (32 + 48),
            pipelineRelayObject: object(PlaybackSessionEventRelay.self),
            pipelineRelayLock: object(NSLock.self),
            pipelineBacking: malloc_good_size(32 + fixedBackingCapacity * MemoryLayout<PlaybackPipelineEvent>.stride),
            receiverCapture: 32 + 48,
            drainRunnerObject: object(OwnedPlaybackEventDrain.self),
            // Swift Task无稳定公开allocation identity；原/新drain各保守512B。
            relayTaskSlabs: 2 * 512,
            drainTaskCaptures: 2 * (32 + 48),
            weakTargetAllocationCharges: 32)
    }

    private let identity: PlaybackRunIdentity
    private let receiver: Receiver
    private let lock = NSLock()
    // 固定32槽背板，出队后用无载荷值释放旧引用；从不append或扩容。
    private var pending: [PlaybackPipelineEvent] = Array(repeating: .stopped, count: maximumCapacity)
    private var pendingIndex = 0
    private var pendingCount = 0
    private var isDraining = false
    private var isActive = true
    private var overflowed = false
    // Executor由Registry持有；relay只能弱借用，避免Authority→relay→Cell→Authority环。
    private weak var ownedExecutor: PlaybackControlExecutor?
    private var ownedDrainRequested = false

    init(identity: PlaybackRunIdentity, receiver: @escaping Receiver) {
        self.identity = identity
        self.receiver = receiver
        precondition(pending.count == Self.maximumCapacity, "pipeline relay固定背板逻辑槽数不一致")
        PlaybackRuntimeAllocationReservations.validateSystemAndPipelineAndGlobalCaps()
    }

    func bindOwnedExecutor(_ executor: PlaybackControlExecutor) -> Bool {
        lock.withLock {
            guard ownedExecutor == nil, !isDraining, pendingCount == 0 else { return false }
            ownedExecutor = executor
            return true
        }
    }

    func claimOwnedDrainRequest() -> Bool {
        lock.withLock {
            guard ownedDrainRequested else { return false }
            ownedDrainRequested = false
            return true
        }
    }

    func send(_ event: PlaybackPipelineEvent) {
        let executor = lock.withLock { () -> PlaybackControlExecutor? in
            guard let ownedExecutor, isActive, !overflowed else { return nil }
            if pendingCount >= Self.maximumCapacity - (isDraining ? 1 : 0) {
                // 不可折叠溢出成为一次终态；用原槽保存，不另排队或继续接纳。
                overflowed = true
                for index in pending.indices { pending[index] = .stopped }
                pendingIndex = 0
                pending[0] = .failed(.controlEventCapacityExceeded)
                pendingCount = 1
                return nil
            }
            pending[(pendingIndex + pendingCount) % Self.maximumCapacity] = event
            pendingCount += 1
            guard !isDraining else { return nil }
            isDraining = true
            ownedDrainRequested = true
            return ownedExecutor
        }
        executor?.signalOwnedEventDrain()
    }

    func deactivate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            for index in pending.indices { pending[index] = .stopped }
            pendingIndex = 0
            pendingCount = 0
        }
    }

    func drainOwned(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
        while let event = nextEvent() {
            guard registry.claimEventDrainDelivery(ticket) else { deactivate(); return }
            await receiver(identity, event)
        }
    }

    private func nextEvent() -> PlaybackPipelineEvent? {
        lock.withLock {
            guard isActive else {
                for index in pending.indices { pending[index] = .stopped }
                pendingIndex = 0
                pendingCount = 0
                isDraining = false
                return nil
            }
            guard pendingCount > 0 else {
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = pending[pendingIndex]
            pending[pendingIndex] = .stopped
            pendingIndex = (pendingIndex + 1) % Self.maximumCapacity
            pendingCount -= 1
            return event
        }
    }
}

/// 同一record持续持有relay及最后一份Task；空队列不等于record terminal。
/// task与joining只在Registry的唯一executor访问；join后的最后引用在锁外释放。
final class OwnedPlaybackEventDrain: @unchecked Sendable {
    enum Relay: Sendable {
        case pipeline(PlaybackSessionEventRelay)
        case audio(PlaybackAudioSessionEventRelay)

        func bind(to executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
            switch self {
            case .pipeline(let relay): relay.bindOwnedExecutor(executor)
            case .audio(let relay): relay.bindOwnedExecutor(executor, recordNonce: recordNonce)
            }
        }

        func claimDrainRequest() -> Bool {
            switch self {
            case .pipeline(let relay): relay.claimOwnedDrainRequest()
            case .audio(let relay): relay.claimOwnedDrainRequest()
            }
        }

        func deactivate() {
            switch self {
            case .pipeline(let relay): relay.deactivate()
            case .audio(let relay): relay.deactivate()
            }
        }

        func drain(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
            switch self {
            case .pipeline(let relay): await relay.drainOwned(registry: registry, ticket: ticket)
            case .audio(let relay): await relay.drainOwned(registry: registry, ticket: ticket)
            }
        }
    }
    let relay: Relay
    var task: Task<Void, Never>?
    var joining = false
    var consumedSystemRevision: UInt64 = 0

    init(relay: Relay) { self.relay = relay }
}

final class PlaybackAudioSessionEventRelay: Equatable, @unchecked Sendable {
    static func == (lhs: PlaybackAudioSessionEventRelay, rhs: PlaybackAudioSessionEventRelay) -> Bool { lhs === rhs }
    weak var terminalReceiver: (any PlaybackOwnedCleanupReceiving)?
    typealias Receiver = @Sendable (
        PlaybackRunIdentity,
        PlaybackAudioSessionLease,
        PlaybackAudioSessionEventKey,
        ControlTaskTicket
    ) async -> Void
    static let maximumCapacity = 32
    static let fixedBackingCapacity = maximumCapacity

    struct AudioRelayAllocationReservation {
        let relayObject: Int
        let relayLock: Int
        let fixedBacking: Int
        let receiverCapture: Int
        let drainRunnerObject: Int
        let relayTaskSlabs: Int
        let drainTaskCaptures: Int

        var relayOldTailOverlap: Int { relayTaskSlabs / 2 }
        var fixedObjectAllocationCharges: Int { relayObject + relayLock + drainRunnerObject }
        var fixedBackingAllocationCharges: Int { fixedBacking }
        var total: Int {
            relayObject + relayLock + fixedBacking + receiverCapture + drainRunnerObject +
                relayTaskSlabs + drainTaskCaptures
        }
    }

    static var audioRelayAllocationReservation: AudioRelayAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return .init(
            relayObject: object(PlaybackAudioSessionEventRelay.self),
            relayLock: object(NSLock.self),
            fixedBacking: malloc_good_size(32 + fixedBackingCapacity * MemoryLayout<PlaybackAudioSessionEventKey?>.stride),
            receiverCapture: 32 + 48,
            drainRunnerObject: object(OwnedPlaybackEventDrain.self),
            relayTaskSlabs: 2 * 512,
            drainTaskCaptures: 2 * (32 + 48))
    }

    private let identity: PlaybackRunIdentity
    let lease: PlaybackAudioSessionLease
    private let receiver: Receiver
    private let lock = NSLock()
    private var pending: [PlaybackAudioSessionEventKey?] = Array(repeating: nil, count: maximumCapacity)
    private var pendingIndex = 0
    private var pendingCount = 0
    private var isDraining = false
    private var deliveryInFlight = false
    private var isActive = true
    private var overflowed = false
    private weak var ownedExecutor: PlaybackControlExecutor?
    private var ownedRecordNonce: UInt64?
    private var ownedDrainRequested = false
    private var ownedDrainEnabled = false

    init(identity: PlaybackRunIdentity, lease: PlaybackAudioSessionLease, receiver: @escaping Receiver) {
        self.identity = identity
        self.lease = lease
        self.receiver = receiver
        precondition(pending.count == Self.maximumCapacity, "audio relay固定背板逻辑槽数不一致")
        PlaybackRuntimeAllocationReservations.validateAudioAndGlobalCaps()
    }

    func prepareOwnedExecutor(_ executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
        lock.withLock {
            guard ownedExecutor == nil, !isDraining, isActive, !overflowed else { return false }
            ownedExecutor = executor
            ownedRecordNonce = recordNonce
            return true
        }
    }

    func bindOwnedExecutor(_ executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
        lock.withLock {
            guard ownedExecutor === executor, ownedRecordNonce == recordNonce,
                  !ownedDrainEnabled, !isDraining, isActive else { return false }
            ownedDrainEnabled = true
            if pendingCount > 0 { isDraining = true; ownedDrainRequested = true }
            return true
        }
    }

    /// 原record已持有relay；最终bind只开放其单票。并发source已领取时无需重复唤醒。
    func signalAfterOwnedBinding() {
        let executor = lock.withLock { () -> PlaybackControlExecutor? in
            guard ownedDrainEnabled, ownedDrainRequested else { return nil }
            return ownedExecutor
        }
        executor?.signalOwnedEventDrain()
    }

    func claimOwnedDrainRequest() -> Bool {
        lock.withLock {
            guard ownedDrainEnabled, ownedDrainRequested else { return false }
            ownedDrainRequested = false
            return true
        }
    }

    func send(lease: PlaybackAudioSessionLease, event: PlaybackAudioSessionEventEnvelope) {
        guard lease == self.lease, let key = PlaybackAudioSessionEventKey(envelope: event) else { return }
        var overflowRecord: UInt64?
        let executor = lock.withLock { () -> PlaybackControlExecutor? in
            guard isActive, !overflowed else { return nil }
            if pendingCount >= Self.maximumCapacity - (deliveryInFlight ? 1 : 0) {
                overflowed = true
                for index in pending.indices { pending[index] = nil }
                pendingIndex = 0
                pending[0] = PlaybackAudioSessionEventKey(envelope:
                    .init(event: .recoveryFailed(stage: .eventRelayCapacity), systemReceipt: nil))
                pendingCount = 1
                overflowRecord = ownedRecordNonce
                return ownedExecutor
            }
            pending[(pendingIndex + pendingCount) % Self.maximumCapacity] = key
            pendingCount += 1
            guard let ownedExecutor, ownedDrainEnabled else { return nil }
            guard !isDraining else { return nil }
            isDraining = true
            ownedDrainRequested = true
            return ownedExecutor
        }
        if let overflowRecord {
            executor?.safetyIngress.receiveAudioRelayOverflow(recordNonce: overflowRecord)
        } else {
            executor?.signalOwnedEventDrain()
        }
    }

    func deactivate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            for index in pending.indices { pending[index] = nil }
            pendingIndex = 0
            pendingCount = 0
        }
    }

    func drainOwned(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
        while let event = nextEvent() {
            guard registry.claimEventDrainDelivery(ticket) else { deactivate(); return }
            await receiver(identity, lease, event, ticket)
        }
    }

    private func nextEvent() -> PlaybackAudioSessionEventKey? {
        lock.withLock {
            // 只有receiver真正返回后才释放其in-flight份额；排期本身不占事件槽。
            deliveryInFlight = false
            guard isActive else {
                for index in pending.indices { pending[index] = nil }
                pendingIndex = 0
                pendingCount = 0
                isDraining = false
                return nil
            }
            guard pendingCount > 0 else {
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = pending[pendingIndex]
            pending[pendingIndex] = nil
            pendingIndex = (pendingIndex + 1) % Self.maximumCapacity
            pendingCount -= 1
            deliveryInFlight = true
            return event
        }
    }
}

/// 五本静态reservation只描述同一运行时可达峰；没有可变计数器、第二Authority或运行时allocation。
enum PlaybackRuntimeAllocationReservations {
    static let ownedControlHardCap = 64 * 1_024
    static let audioRelayHardCap = 16 * 1_024
    static let systemAndPipelineRelayHardCap = 4 * 1_024
    static let routeHardCap = 4 * 1_024
    static let presentationHardCap = 2 * 1_024
    static let globalHardCap = 96 * 1_024

    static var ownedControl: ControlTaskRegistry.ControlAllocationReservation {
        ControlTaskRegistry.ownedControlAllocationReservation
    }
    static var audioRelay: PlaybackAudioSessionEventRelay.AudioRelayAllocationReservation {
        PlaybackAudioSessionEventRelay.audioRelayAllocationReservation
    }
    static var systemAndPipelineRelay: PlaybackSessionEventRelay.SystemAndPipelineRelayAllocationReservation {
        PlaybackSessionEventRelay.systemAndPipelineRelayAllocationReservation
    }
    static var route: PlaybackAudioRouteService.RouteAllocationReservation {
        PlaybackAudioRouteService.routeAllocationReservation
    }
    static var presentation: PlaybackPresentationAllocationReservation {
        PlaybackPresentationRelay.allocationReservation
    }
    static var globalReachablePeak: Int {
        var total = 0
        guard checkedAccumulate(ownedControl.total, into: &total),
              checkedAccumulate(audioRelay.total, into: &total),
              checkedAccumulate(systemAndPipelineRelay.total, into: &total),
              checkedAccumulate(route.total, into: &total),
              checkedAccumulate(presentation.total, into: &total) else { return Int.max }
        return total
    }

    static func validateOwnedAndGlobalCaps() {
        precondition(ownedControl.total <= ownedControlHardCap, "owned-control allocation超出64KiB")
        validateGlobalCap()
    }
    static func validateAudioAndGlobalCaps() {
        precondition(audioRelay.total <= audioRelayHardCap, "audio relay allocation超出16KiB")
        validateGlobalCap()
    }
    static func validateSystemAndPipelineAndGlobalCaps() {
        precondition(systemAndPipelineRelay.total <= systemAndPipelineRelayHardCap,
            "system/pipeline relay allocation超出4KiB")
        validateGlobalCap()
    }
    static func validateRouteAndGlobalCaps() {
        precondition(route.total <= routeHardCap, "route allocation超出4KiB")
        validateGlobalCap()
    }
    static func validatePresentationAndGlobalCaps() {
        precondition(
            presentation.total <= presentationHardCap,
            "presentation allocation超出2KiB：\(presentation.total)B"
        )
        validateGlobalCap()
    }
    static func checkedAccumulate(_ value: Int, into total: inout Int) -> Bool {
        guard value >= 0 else { return false }
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = next
        return true
    }
    private static func validateGlobalCap() {
        precondition(globalReachablePeak <= globalHardCap, "控制运行时全局allocation超出96KiB")
    }
}

struct PlaybackPresentationAllocationReservation {
    let relayObject: Int
    let relayLock: Int
    let asyncStreamOpaqueStorage: Int
    let newestBufferBacking: Int
    let terminationClosureContext: Int
    let relayWeakSideTable: Int
    let consumerTaskSlab: Int
    let consumerCaptureCompletionAndPendingIntent: Int
    let consumerOwnerObject: Int
    let consumerOwnerWeakSideTable: Int
    let mountObject: Int
    let hostOwnershipState: Int
    let hostWeakSideTable: Int
    let coordinatorObject: Int
    let consumerInFlightEnvelope: Int
    var total: Int {
        var total = 0
        guard PlaybackRuntimeAllocationReservations.checkedAccumulate(relayObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(relayLock, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                asyncStreamOpaqueStorage, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                newestBufferBacking, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                terminationClosureContext, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                relayWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerTaskSlab, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerCaptureCompletionAndPendingIntent, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerOwnerObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerOwnerWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                mountObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                hostOwnershipState, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                hostWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                coordinatorObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerInFlightEnvelope, into: &total) else { return Int.max }
        return total
    }
}

enum PlaybackPresentationAllocationCapacityResult: Equatable {
    case admitted(totalBytes: Int)
    case capacityExceeded
    case integerOverflow
}

enum PlaybackPresentationAllocationCapacity {
    static func evaluate(
        baseBytes: Int,
        additionalBytes: Int
    ) -> PlaybackPresentationAllocationCapacityResult {
        guard baseBytes >= 0, additionalBytes >= 0 else { return .capacityExceeded }
        let (total, overflow) = baseBytes.addingReportingOverflow(additionalBytes)
        guard !overflow else { return .integerOverflow }
        guard total <= PlaybackRuntimeAllocationReservations.presentationHardCap else {
            return .capacityExceeded
        }
        return .admitted(totalBytes: total)
    }
}
