// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Darwin
import Foundation
import ObjectiveC

/// executor外部同步入口的固定34槽映射；值类型本身不分配数组或第二张运行时表。
struct PlaybackExternalSyncProducerReservation: Sendable, Equatable {
    struct Slot: Sendable, Equatable, Hashable {
        fileprivate let ordinal: UInt8
        var index: Int { Int(ordinal) }
        static func ownedRunner(_ index: Int) -> Self? {
            guard (0..<32).contains(index) else { return nil }
            return .init(ordinal: UInt8(index))
        }
        static let laneCompletion = Self(ordinal: 32)
        static let serializedUserControl = Self(ordinal: 33)
    }

    enum Entrant: Sendable, Equatable {
        case ownedRunner(Int)
        case audioSessionLaneCompletion
        case serializedUserControl
        case stateTermination
        case mediaTermination
        case audioPipelineRouteResample
        case registryDeinitialization
    }

    enum ReuseProof: Sendable, Equatable {
        case uniqueReservation
        case requiresRuntimeUnreachable
    }

    enum FixedLedgerCharge: Sendable, Equatable {
        case ownedStateTerminationSyncBridge
        case ownedMediaTerminationSyncBridge
        case routeResampleSyncBridge

        var bytes: Int { 32 + 48 }
    }

    struct Assignment: Sendable, Equatable {
        let slot: Slot
        let proof: ReuseProof
    }

    enum Coverage: Sendable, Equatable {
        case baseSlot(Assignment)
        case fixedLedgerCharge(FixedLedgerCharge)
    }

    static let slotCount = 34
    static let environmentBytes = 32
    static let blockBytes = 48
    var total: Int { Self.slotCount * (Self.environmentBytes + Self.blockBytes) }

    func assignment(for entrant: Entrant) -> Assignment? {
        switch entrant {
        case .ownedRunner(let index):
            guard let slot = Slot.ownedRunner(index) else { return nil }
            return .init(slot: slot, proof: .uniqueReservation)
        case .audioSessionLaneCompletion:
            return .init(slot: .laneCompletion, proof: .uniqueReservation)
        case .serializedUserControl:
            return .init(slot: .serializedUserControl, proof: .uniqueReservation)
        case .stateTermination, .mediaTermination, .audioPipelineRouteResample:
            return nil
        case .registryDeinitialization:
            // Registry析构仅在全部runtime owner不可达后发生，与活跃用户入口互斥。
            return .init(slot: .serializedUserControl, proof: .requiresRuntimeUnreachable)
        }
    }

    func coverage(for entrant: Entrant) -> Coverage? {
        switch entrant {
        case .stateTermination:
            return .fixedLedgerCharge(.ownedStateTerminationSyncBridge)
        case .mediaTermination:
            return .fixedLedgerCharge(.ownedMediaTerminationSyncBridge)
        case .audioPipelineRouteResample:
            return .fixedLedgerCharge(.routeResampleSyncBridge)
        default:
            return assignment(for: entrant).map(Coverage.baseSlot)
        }
    }

    func requireFixedLedgerCharge(_ charge: FixedLedgerCharge, for entrant: Entrant) {
        precondition(coverage(for: entrant) == .fixedLedgerCharge(charge),
            "外部同步入口没有匹配的固定ledger charge")
    }

    func fixedLedgerChargeBytes(for entrant: Entrant) -> Int {
        guard case .fixedLedgerCharge(let charge) = coverage(for: entrant) else { return 0 }
        return charge.bytes
    }
}

/// 只有真正拥有 SampleBuffer pipeline rate owner 的后端才能保存 Registry 安装的签发器。
/// 签发器构造器仍封闭在 Registry 文件内，普通调用方不能自行制造。
protocol SampleBufferQuiescenceIssuerInstalling: AnyObject {
    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    )
}

final class ControlTaskRegistry: @unchecked Sendable {
    struct BackendPrepareInvocation: Sendable {
        let ticket: PrepareTicket
        let replacementAuthority: BackendPublicationReplacementAuthority

        var outputLifecycleEpoch: OutputLifecycleEpoch {
            replacementAuthority.lifecycle
        }
    }

    /// prepare 时由 Registry 签发、与当前 backend lifecycle 精确绑定的单次替换能力。
    /// 它不依赖正 rate interval，因此 publication 冲突可在 prepare/authorized/activated
    /// 任一阶段进入同一 output cleanup single-flight。
    final class BackendPublicationReplacementAuthority: @unchecked Sendable {
        fileprivate weak var registry: ControlTaskRegistry?
        fileprivate let sourceTaskNonce: UInt64
        fileprivate let lifecycle: OutputLifecycleEpoch
        fileprivate let replacesRetiredLifecycle: Bool
        // 只能在签发 Registry 的 transaction 中访问；复用原 safety Cell。
        fileprivate var consumed = false

        fileprivate init(registry: ControlTaskRegistry,
                         sourceTask: ControlTaskTicket,
                         prepareTicket: PrepareTicket,
                         lifecycle: OutputLifecycleEpoch,
                         contextNonce: UInt64,
                         replacesRetiredLifecycle: Bool) {
            self.registry = registry
            precondition(prepareTicket.backendIdentity == lifecycle.backendIdentity)
            self.sourceTaskNonce = sourceTask.nonce
            self.lifecycle = lifecycle
            self.replacesRetiredLifecycle = replacesRetiredLifecycle
        }

        func requestReplacement() -> Bool {
            registry?.requestBackendPublicationReplacement(self) == true
        }

        func matches(lifecycle: OutputLifecycleEpoch,
                     ticket: PrepareTicket) -> Bool {
            guard self.lifecycle == lifecycle, let registry else { return false }
            return registry.projection {
                guard !self.consumed,
                      case .installed(let context, let backend) = registry.authority.resourceState,
                      backend.lifecycle == lifecycle,
                      context.prepareTicket == ticket,
                      let record = registry.authority.commands.first(where: {
                          $0?.controlTaskTicket.nonce == self.sourceTaskNonce
                      }) ?? nil else { return false }
                return record.slot == .prepare
                    && record.groupTicket == context.reservation.workGroup
                    && backend.identity == ticket.backendIdentity
            }
        }
    }

    /// backend 在构造时预拥有该固定槽；槽本只是 Registry authority 的一次安装点，
    /// 不自行签发、解释或替换控制身份。
    final class BackendPublicationReplacementAuthoritySlot: @unchecked Sendable {
        // 实例地址稳定，锁内嵌于唯一槽对象；不再隐式持有另一个 NSLock allocation。
        private var lock = os_unfair_lock_s()
        private var backendObjectIdentity: ObjectIdentifier?
        private var authority: BackendPublicationReplacementAuthority?

        func requestReplacement() -> Bool {
            withLock { authority }?.requestReplacement() == true
        }

        func currentAuthority() -> BackendPublicationReplacementAuthority? {
            withLock { authority }
        }

        fileprivate func install(
            _ replacement: BackendPublicationReplacementAuthority,
            backendObject: AnyObject
        ) -> Bool { withLock {
            let identity = ObjectIdentifier(backendObject)
            if let backendObjectIdentity,
               backendObjectIdentity != identity { return false }
            if let authority, authority.lifecycle == replacement.lifecycle {
                return authority === replacement
            }
            backendObjectIdentity = identity
            authority = replacement
            return true
        } }

        private func withLock<T>(_ body: () -> T) -> T {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return body()
        }
    }

    /// publication 冲突已由同一 Cell 准入后保留的固定单槽状态。这里保存的是
    /// 旧 lifecycle 的清理责任；未来 item/publication bundle 仍只能由 backend
    /// 在新的 BackendPrepareInvocation 中提供，Registry 不生成媒体身份。
    private struct BackendPublicationReplacementTransition: Sendable {
        let capability: BackendPublicationReplacementAuthority
        let owner: OutputTransitionOwnerTicket
        let suspend: OutputSuspendTicket
        let backendIdentity: PlaybackBackendIdentity
        let retiredLifecycle: OutputLifecycleEpoch
        let originalContextNonce: UInt64
        let shouldReactivate: Bool
    }

    /// 同一个已登记 Task 从旧 suspend record 原子换手到新 prepare record 后，
    /// 只携带执行新 backend invocation 所需的不可变投影。
    private struct BackendPublicationReprepareHandoff: Sendable {
        let ticket: ControlTaskTicket
        let runner: OwnedPlaybackBackendOperation
        let backend: any PlaybackBackend
        let invocation: BackendPrepareInvocation
        let shouldReactivate: Bool
    }

    /// Registry 在既有 activation command 上签发的单次后端调用能力。
    /// 构造器仅属于本文件，后端只能消费而不能自行制造新的播放授权。
    struct BackendPositiveRateInvocation: Sendable, Equatable {
        struct CurrentSnapshot: Sendable, Equatable {
            let sourceTask: ControlTaskTicket
            let interval: PotentiallyAudibleOutputIntervalKey
        }

        static var retainedCapabilityAllocationBytes: Int {
            malloc_good_size(class_getInstanceSize(BackendPositiveRateCapability.self))
        }

        private let sourceTaskNonce: UInt64
        private let frozenActivation: ActivationEpoch
        private let capability: BackendPositiveRateCapability

        fileprivate init(sourceTask: ControlTaskTicket, interval: PotentiallyAudibleOutputIntervalKey,
                         capability: BackendPositiveRateCapability) {
            sourceTaskNonce = sourceTask.nonce
            frozenActivation = interval.activation
            self.capability = capability
        }

        /// 这是签发时的冻结身份，不代表当前授权。当前性只能由下面的
        /// `revalidateCurrentAuthority`/`performPositiveRateSideEffect` 判定。
        var activation: ActivationEpoch { frozenActivation }

        /// source/interval 只允许从原 Registry 的当前权威原子读取。interval 已关闭、
        /// command 已撤销或 Registry 已释放时返回 nil，调用方不得持有第二份完整投影。
        var currentSnapshot: CurrentSnapshot? {
            capability.snapshot(sourceTaskNonce: sourceTaskNonce,
                                activation: frozenActivation)
        }

        /// SDK actor 把真正的正 rate closure 交回原 Registry/Cell；复验、单次消费
        /// 与副作用共享同一临界区，调用方不能把三步拆开。
        func performPositiveRateSideEffect(_ sideEffect: () -> Void) -> Bool {
            capability.perform(sourceTaskNonce: sourceTaskNonce,
                               activation: frozenActivation,
                               sideEffect: sideEffect)
        }

        /// await 返回及 KVO `.playing` 发布前均复验原 Registry 的当前权威。
        func revalidateCurrentAuthority() -> Bool {
            capability.revalidate(sourceTaskNonce: sourceTaskNonce,
                                  activation: frozenActivation)
        }

        /// 当前播放观察发现权威失效时，仍由原 Registry 建立唯一 pause/suspend record。
        func requestAutomaticSuspend() -> Bool {
            capability.requestAutomaticSuspend(sourceTaskNonce: sourceTaskNonce,
                                                activation: frozenActivation)
        }

        func scheduleNaturalEnd(item: AVPlayerItemInstanceIdentity, identity: UUID,
                                receiver: any PlaybackNaturalEndDeadlineReceiving) -> Bool {
            capability.scheduleNaturalEnd(invocation: self, item: item,
                identity: identity, receiver: receiver)
        }

        func retireNaturalEnd(identity: UUID) { capability.retireNaturalEnd(identity: identity) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sourceTaskNonce == rhs.sourceTaskNonce
                && lhs.frozenActivation == rhs.frozenActivation
                && lhs.capability === rhs.capability
        }
    }

    fileprivate final class BackendPositiveRateCapability: @unchecked Sendable {
        private weak var registry: ControlTaskRegistry?
        private var consumed = false

        init(registry: ControlTaskRegistry) { self.registry = registry }

        func scheduleNaturalEnd(invocation: BackendPositiveRateInvocation,
                                item: AVPlayerItemInstanceIdentity, identity: UUID,
                                receiver: any PlaybackNaturalEndDeadlineReceiving) -> Bool {
            registry?.deadlineScheduler?.armNaturalEnd(invocation: invocation,
                item: item, identity: identity, receiver: receiver) == true
        }

        func retireNaturalEnd(identity: UUID) { registry?.deadlineScheduler?.cancelNaturalEnd(identity) }

        func snapshot(sourceTaskNonce: UInt64,
                      activation: ActivationEpoch) -> BackendPositiveRateInvocation.CurrentSnapshot? {
            guard let snapshot = registry?.positiveRateInvocationSnapshot(
                sourceTaskNonce: sourceTaskNonce,
                activation: activation) else { return nil }
            return .init(sourceTask: snapshot.0, interval: snapshot.1)
        }

        func perform(sourceTaskNonce: UInt64,
                     activation: ActivationEpoch,
                     sideEffect: () -> Void) -> Bool {
            registry?.performPositiveRateSideEffect(
                capability: self, sourceTaskNonce: sourceTaskNonce,
                activation: activation, sideEffect: sideEffect) == true
        }

        func revalidate(sourceTaskNonce: UInt64,
                        activation: ActivationEpoch) -> Bool {
            registry?.revalidatePositiveRateInvocation(
                sourceTaskNonce: sourceTaskNonce,
                activation: activation) == true
        }

        func requestAutomaticSuspend(sourceTaskNonce: UInt64,
                                     activation: ActivationEpoch) -> Bool {
            registry?.requestAutomaticSuspend(
                sourceTaskNonce: sourceTaskNonce,
                activation: activation) == true
        }

        fileprivate func consumeWhileSafetyCellLocked() -> Bool {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }

    /// Registry 在既有 suspend command 上投递给后端的停止能力。
    /// 未曾开放正 rate interval 时 closeClaim 必须为空。
    struct BackendSuspendInvocation: Sendable, Equatable {
        let registryIssuerIdentity: UInt64
        let suspendTicket: OutputSuspendTicket
        let closeClaim: PotentiallyAudibleOutputCloseClaim?

        fileprivate init(
            registryIssuerIdentity: UInt64,
            suspendTicket: OutputSuspendTicket,
            closeClaim: PotentiallyAudibleOutputCloseClaim?
        ) {
            self.registryIssuerIdentity = registryIssuerIdentity
            self.suspendTicket = suspendTicket
            self.closeClaim = closeClaim
        }

        var lifecycle: OutputLifecycleEpoch { suspendTicket.lifecycle }


    }

    /// 每个 output lifecycle 在 Registry 安装时取得唯一 issuer。issuer 可为同一 lifecycle
    /// 的后继 suspend 签发新证明，但每张证明本身只能被消费一次。
    final class SampleBufferQuiescenceIssuer: @unchecked Sendable {
        fileprivate let backendIdentity: PlaybackBackendIdentity
        fileprivate let lifecycle: OutputLifecycleEpoch

        fileprivate init(backendIdentity: PlaybackBackendIdentity,
                         lifecycle: OutputLifecycleEpoch) {
            self.backendIdentity = backendIdentity
            self.lifecycle = lifecycle
        }

        func issue(
            backendIdentity: PlaybackBackendIdentity,
            invocation: BackendSuspendInvocation,
            observedRate: Float,
            preparedPreserved: Bool
        ) -> BackendQuiescenceProof? {
            guard observedRate == 0, observedRate.isFinite,
                  self.backendIdentity == backendIdentity,
                  lifecycle.backendIdentity == backendIdentity,
                  invocation.lifecycle == lifecycle else { return nil }
            return .init(kind: .sampleBuffer, backendIdentity: backendIdentity,
                         itemGeneration: nil, invocation: invocation,
                         preparedPreserved: preparedPreserved,
                         sampleBufferIssuer: self)
        }
    }

    final class BackendQuiescenceProof: @unchecked Sendable, Equatable {
        fileprivate enum Kind: Sendable, Equatable {
            case sampleBuffer
            case avPlayer
        }
        fileprivate let kind: Kind
        fileprivate let backendIdentity: PlaybackBackendIdentity
        fileprivate let itemGeneration: UInt64?
        fileprivate let invocation: BackendSuspendInvocation
        fileprivate let preparedPreserved: Bool
        fileprivate let sampleBufferIssuer: SampleBufferQuiescenceIssuer?
        fileprivate let avPlayerReceipt: AVPlayerQuiescenceReceipt?
        private let consumptionLock = NSLock()
        private var consumed = false

        fileprivate init(kind: Kind, backendIdentity: PlaybackBackendIdentity,
                         itemGeneration: UInt64?, invocation: BackendSuspendInvocation,
                         preparedPreserved: Bool,
                         sampleBufferIssuer: SampleBufferQuiescenceIssuer? = nil,
                         avPlayerReceipt: AVPlayerQuiescenceReceipt? = nil) {
            self.kind = kind
            self.backendIdentity = backendIdentity
            self.itemGeneration = itemGeneration
            self.invocation = invocation
            self.preparedPreserved = preparedPreserved
            self.sampleBufferIssuer = sampleBufferIssuer
            self.avPlayerReceipt = avPlayerReceipt
        }

        static func avPlayer(
            _ attestation: AVPlayerBackendQuiescenceAttestation
        ) -> BackendQuiescenceProof {
            .init(kind: .avPlayer,
                  backendIdentity: attestation.backendIdentity,
                  itemGeneration: attestation.receipt.item.itemGeneration,
                  invocation: attestation.invocation,
                  preparedPreserved: attestation.preparedPreserved,
                  avPlayerReceipt: attestation.receipt)
        }

        fileprivate func consumeOnce() -> Bool { consumptionLock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        } }

        static func == (lhs: BackendQuiescenceProof,
                        rhs: BackendQuiescenceProof) -> Bool {
            lhs.kind == rhs.kind && lhs.backendIdentity == rhs.backendIdentity
                && lhs.itemGeneration == rhs.itemGeneration
                && lhs.invocation == rhs.invocation
                && lhs.preparedPreserved == rhs.preparedPreserved
                && lhs.sampleBufferIssuer === rhs.sampleBufferIssuer
                && lhs.avPlayerReceipt == rhs.avPlayerReceipt
        }
    }

    /// owned-control唯一allocation预留：不累计编译器瞬时栈，不建立第二资源Authority。
    /// 对象含heap头/内联字段；固定池、捕获、原/新投递及暂存分别收费。
    struct ControlAllocationReservation {
        let fixedObjects: Int
        let commandBacking: Int
        let groupBacking: Int
        let counterBacking: Int
        let dispatchObjects: Int
        let permanentCaptures: Int
        let inFlightDeliveries: Int
        let registrations: Int
        let fixedScratch: Int
        let routeWrapper: Int
        let transientArrays: Int
        let externalSyncReservation: Int
        let weakSideTables: Int
        let fixedErrorReservation: Int
        let fixedBridgeReservation: Int
        let processGlobals: Int
        let controllerAndProgressObjects: Int
        let backendAndCleanupRunnerObjects: Int
        let taskSlabs: Int
        let escapingCaptures: Int
        let progressContinuationStorage: Int
        let stateContinuationStorage: Int
        let mediaContinuationStorage: Int
        let cleanupDispositionContinuationStorage: Int
        let stateTerminationSyncBridge: Int
        let mediaTerminationSyncBridge: Int
        let externalProducerAssignments: PlaybackExternalSyncProducerReservation

        /// 以下为上面唯一charge的具名子归属，不再次进入total。
        var overlappingOldTails: Int { taskSlabs / 2 }
        var progressWaiterTaskSlab: Int { taskSlabs / 4 }
        var progressWaiterCapture: Int { escapingCaptures / 6 }
        var stateSubscriptionStorage: Int { stateContinuationStorage + stateTerminationSyncBridge }
        var mediaSubscriptionStorage: Int { mediaContinuationStorage + mediaTerminationSyncBridge }
        var continuations: Int {
            progressContinuationStorage + stateContinuationStorage + mediaContinuationStorage +
                cleanupDispositionContinuationStorage
        }
        var fixedObjectAllocationCharges: Int {
            fixedObjects + controllerAndProgressObjects + backendAndCleanupRunnerObjects
        }
        var fixedBackingAllocationCharges: Int { commandBacking + groupBacking + counterBacking }

        var total: Int {
            fixedObjects + commandBacking + groupBacking + counterBacking + dispatchObjects +
                permanentCaptures + inFlightDeliveries + registrations + fixedScratch + routeWrapper +
                transientArrays + externalSyncReservation + weakSideTables + fixedErrorReservation +
                fixedBridgeReservation + processGlobals + controllerAndProgressObjects +
                backendAndCleanupRunnerObjects + taskSlabs + escapingCaptures + continuations +
                stateTerminationSyncBridge + mediaTerminationSyncBridge
        }
    }

    static let commandBackingCapacity = 32
    static let groupBackingCapacity = 32

    static var ownedControlAllocationReservation: ControlAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        let externalProducers = PlaybackExternalSyncProducerReservation()
        return .init(
            fixedObjects: object(ControlTaskRegistry.self) + object(Authority.self) +
                object(PlaybackControlExecutor.self) + object(SynchronousSafetyIngressCell.self) +
                object(PlaybackAudioSessionOwner.self) + object(AudioSessionBlockingCallLane.self) +
                object(SystemPlaybackAudioSessionSDK.self) + object(PlaybackDeadlineScheduler.self) +
                2 * object(NSLock.self) + object(DispatchSpecificKey<UInt8>.self) +
                malloc_good_size(16 + MemoryLayout<UInt8>.stride) + // setSpecific的单字段Swift wrapper。
                PlaybackIdentityAllocator.fixedObjectAllocationBytes + DispatchPlaybackMonotonicClock.fixedObjectAllocationBytes,
            // 同tvOS Swift Array frozen layout的tail offset为32；repeating构造固定count，按实际allocator取整。
            commandBacking: malloc_good_size(32 + commandBackingCapacity * MemoryLayout<OwnedPostIngressControlCommand?>.stride),
            groupBacking: malloc_good_size(32 + groupBackingCapacity * MemoryLayout<Group?>.stride),
            counterBacking: PlaybackIdentityAllocator.counterBackingAllocationBytes,
            dispatchObjects: 4 * 128, // 两queue、executor source、deadline timer的可见对象本体。
            permanentCaptures: 2 * 48 + 2 * (32 + 48), // 两hook环境；两weak handler环境和Block。
            inFlightDeliveries: 2 * (object(AudioSessionCallDelivery.self) + 32 + 48),
            registrations: 2 * object(PlaybackAudioSessionRegistration.self), // 原退出与新registration准备可交叠。
            fixedScratch: malloc_good_size(1024) + malloc_good_size(256),
            routeWrapper: object(SystemAudioSessionRouteSnapshot.self),
            transientArrays: 2 * malloc_good_size(32 + 16 * MemoryLayout<Int>.stride) + 160,
            // 预留已准入32 owned runner＋1 lane completion＋1串行用户入口；不授权任意无界caller。
            externalSyncReservation: externalProducers.total,
            weakSideTables: 5 * 32, // executor、scheduler、Registry、controller、cleanup runner五个唯一target。
            fixedErrorReservation: 34 * 2 * 80,
            fixedBridgeReservation: 64,
            processGlobals: 4 * MemoryLayout<UnsafeRawPointer>.stride,
            controllerAndProgressObjects: object(PlaybackController.self) +
                object(PlaybackControlProgressSignal.self) + object(NSLock.self) +
                object(SystemPlaybackBackendFactory.self) + object(SystemPlaybackPipelineFactory.self) +
                object(DefaultAudioSessionCompletionReceiver.self),
            // 可达峰允许原/新runner交叠；对象charge与其Task slab分开。
            // positive-rate capability 在 HLS item install 时已按真实类对象预留，
            // Registry 仅保留 weak issuer 关系，不在 owned-control 重复计费。
            backendAndCleanupRunnerObjects: 2 * object(OwnedPlaybackBackendOperation.self) +
                2 * object(OwnedPlaybackCleanupTask.self) +
                // Registry 签发并在 prepare runner / replacement transition 之间共享。
                // 旧能力尾部与新 prepare 能力可交叠；消费同步复用原 safety Cell。
                2 * object(BackendPublicationReplacementAuthority.self),
            // Swift Task runtime没有稳定公开allocation identity；四份512B覆盖controller、
            // backend（含同一Task帧内的replacement固定值）、cleanup及旧尾。
            taskSlabs: 4 * 512,
            escapingCaptures: 6 * (32 + 48),
            // Swift continuation没有稳定公开allocation identity；原四种责任各保守256B。
            progressContinuationStorage: 256,
            stateContinuationStorage: 256,
            mediaContinuationStorage: 256,
            cleanupDispositionContinuationStorage: 256,
            // onTermination可与完整continuation同时存活，两份sync bridge各独立计费一次。
            stateTerminationSyncBridge: externalProducers.fixedLedgerChargeBytes(for: .stateTermination),
            mediaTerminationSyncBridge: externalProducers.fixedLedgerChargeBytes(for: .mediaTermination),
            externalProducerAssignments: externalProducers)
    }

    /// Task6兼容入口；与owned ledger是同一值，不建立第二本账。
    static var controlAllocationReservation: ControlAllocationReservation {
        ownedControlAllocationReservation
    }

    struct Occupancy {
        let ordinarySlots: Int
        let safetySlots: Int
        let groups: Int
        var reservedSafetySlots: Int = 0
        var safetyReserveInUse: Bool { safetySlots + reservedSafetySlots > 8 }
    }
    static var ordinaryPoolValueBytes: Int { 16 * MemoryLayout<OwnedPostIngressControlCommand?>.stride }
    static var safetyPoolValueBytes: Int { 16 * MemoryLayout<OwnedPostIngressControlCommand?>.stride }
    static var groupValueBytes: Int { 32 * MemoryLayout<Group?>.stride }
    /// 压缩Group的计算属性每次只投影一张完整票，不保留数组或缓存。
    static var groupTicketProjectionPreparationValueBytes: Int {
        MemoryLayout<ControlTaskGroupTicket>.stride
    }
    static var authoritySnapshotValueBytes: Int {
        MemoryLayout<PlaybackSafetySnapshot>.stride +
        MemoryLayout<OutputAuthoritativeRoute>.stride +
        MemoryLayout<RegisteredAudioSessionPhase?>.stride + MemoryLayout<ActivationClaim?>.stride +
        PlaybackIdentityAllocator.activationProvenanceValueBytes + PlaybackIdentityAllocator.configurationProvenanceValueBytes +
        MemoryLayout<CleanupReservation?>.stride +
        MemoryLayout<OutputResourceState?>.stride + MemoryLayout<OutputRegisteredDrainProof?>.stride +
        MemoryLayout<ProcessAudioSessionConfigurationReceipt?>.stride + MemoryLayout<RouteObservationState?>.stride +
        MemoryLayout<OutputRouteSampleClaim?>.stride + MemoryLayout<OutputRouteStabilityCandidate?>.stride +
        2 * MemoryLayout<MediaServicesResetRootIdentity?>.stride +
        MemoryLayout<ResetPreRouteRecoveryDeadlineState?>.stride +
        MemoryLayout<PostConfigurationRouteState?>.stride + MemoryLayout<ResetPostConfigurationProof?>.stride +
        MemoryLayout<StableRouteCommitIdentity?>.stride + MemoryLayout<any PlaybackMonotonicClock>.stride + 2 * MemoryLayout<UInt64>.stride
        + MemoryLayout<Authority.AudioSessionInFlightPermit?>.stride + MemoryLayout<SessionEndpointFingerprint?>.stride +
        MemoryLayout<OutputConfigurationIncarnation?>.stride + MemoryLayout<AudioSessionBlockingCallLane?>.stride
    }
    /// 历史源码值stride诊断，不是64KiB allocation门槛；真实预留见controlAllocationReservation。
    static var fixedValueStorageBytes: Int {
        ordinaryPoolValueBytes + safetyPoolValueBytes + groupValueBytes + authoritySnapshotValueBytes +
        PlaybackControlExecutor.ingressHookValueBytes
    }
    var occupancy: Occupancy {
        // 只读统计持同一Cell锁，不消费pending ingress，也不暴露可变数组。
        projection {
            Occupancy(ordinarySlots: authority.commands[0..<16].reduce(0) { $0 + ($1 == nil ? 0 : 1) },
                      safetySlots: authority.commands[16..<32].reduce(0) { $0 + ($1 == nil ? 0 : 1) },
                      groups: authority.groups.reduce(0) { $0 + ($1 == nil ? 0 : 1) },
                      reservedSafetySlots: (16..<32).filter {
                          authority.commands[$0] == nil && authority.cleanupReservation?.reserves($0) == true
                      }.count)
        }
    }

    /// 原executor与Cell锁内同步借用两个生产Array的元素区间；不复制Array，
    /// 不暴露buffer，也不让地址参与任何控制流程。
    func inspectOriginalControlBackingAllocations(
        _ body: (String, VPMallocAllocationRange, UInt, Int) -> Void
    ) {
        projection {
            authority.commands.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let borrowedBytes = buffer.count
                    * MemoryLayout<OwnedPostIngressControlCommand?>.stride
                body("owned/registry commands backing",
                     VPInspectMallocAllocationContainingRange(base, borrowedBytes),
                     UInt(bitPattern: base), borrowedBytes)
            }
            authority.groups.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let borrowedBytes = buffer.count * MemoryLayout<Group?>.stride
                body("owned/registry groups backing",
                     VPInspectMallocAllocationContainingRange(base, borrowedBytes),
                     UInt(bitPattern: base), borrowedBytes)
            }
        }
    }

    private final class Authority: @unchecked Sendable {
        /// 完整原票仍在不可退休的running/cancelRequested record与delivery中；nonce不能用于查找或补票。
        struct AudioSessionInFlightPermit: Equatable {
            let recordNonce: UInt64
            let operation: AudioSessionBlockingCallOperation
        }
        var commands: [OwnedPostIngressControlCommand?] = Array(repeating: nil, count: 32)
        var groups: [Group?] = Array(repeating: nil, count: 32)
        var snapshot = PlaybackSafetySnapshot()
        var authoritativeRoute = OutputAuthoritativeRoute.unknown
        var routeSemantic: PlaybackRouteSemanticIdentity? { authoritativeRoute.semantic }
        var audioPhase: RegisteredAudioSessionPhase?
        var activationClaim: ActivationClaim?
        var audioSessionPermit: AudioSessionInFlightPermit?
        var audioSessionLane: AudioSessionBlockingCallLane?
        var lastEndpointFingerprint: SessionEndpointFingerprint?
        var outputConfigurationIncarnation: OutputConfigurationIncarnation?
        var cleanupReservation: CleanupReservation?
        var resourceState: OutputResourceState?
        // 固定单槽只保存最新请求的原始身份/预算；前驱资源仍保留在resourceState直到原owner排空。
        var playbackRequestAdmission: CurrentPlaybackOperationDeadlineTicket?
        var stateSubscription: PlaybackStateSubscription?
        var publicState: PlaybackState = .idle
        var mediaSubscription: PlaybackMediaSubscription?
        var registeredDrainProof: OutputRegisteredDrainProof?
        var pendingReactivationReceipt: AudioSessionReactivationCompletionReceipt?
        var processConfigurationReceipt: ProcessAudioSessionConfigurationReceipt?
        // receipt在reset时销毁；权威generation仅在真实交接/commit时前进，不能读candidate phase猜测。
        var currentConfigurationGeneration: UInt64 = 0
        var routeObservationState: RouteObservationState?
        var stableRouteCommit: StableRouteCommitIdentity?
        var routeSampleClaim: OutputRouteSampleClaim?
        var routeStabilityCandidate: OutputRouteStabilityCandidate?
        var currentResetRoot: MediaServicesResetRootIdentity?
        var emptyResetDrainSource: MediaServicesResetRootIdentity?
        var resetPreRouteState: ResetPreRouteRecoveryDeadlineState?
        var postConfigurationRouteState: PostConfigurationRouteState?
        var registeredPostConfigurationProof: ResetPostConfigurationProof?
        var ownedResource: OutputResourceOwnership? {
            get { resourceState?.ownership }
            set {
                // Swift可选链会写回nil；它不能清除shape，资源释放只走具名整体CAS。
                guard let newValue else { return }
                resourceState?.updateOwnedPayload(newValue.payload)
            }
        }
        var ownedBackendResources: OwnedBackendResources? {
            switch resourceState {
            case .predecessorCleanup(_, let backend), .installed(_, let backend),
                 .quiescentBackend(_, let backend): backend
            default: nil
            }
        }
        var ownedLeaseResources: OwnedAudioSessionLeaseResources? {
            switch resourceState {
            case .acquiringLease(_, let state): state.lease
            case .pendingCreation(_, let lease), .pendingSuccessorLease(_, let lease),
                 .leaseOnlyCleanup(_, .owned(let lease)): lease
            case .predecessorCleanup(_, let backend), .installed(_, let backend),
                 .quiescentBackend(_, let backend): backend.lease
            default: nil
            }
        }
        var outputContext: OutputResourceContext? {
            get { resourceState?.context }
            set {
                guard let newValue else { return }
                resourceState?.context = newValue
            }
        }
        var resourceTransactionActive = false

        func belongsToCurrentOutputGraph(_ ticket: ControlTaskTicket) -> Bool {
            guard let context = outputContext, cleanupReservation?.ticket == context.reservation else { return false }
            return ticket.group == context.reservation.ownerGroup || ticket.group == context.reservation.workGroup ||
                isDescendant(ticket.group, of: context.reservation.workGroup)
        }

        func prepareCommand(group: ControlTaskGroupTicket, slot: ControlTaskSlot,
            policy: ControlGatePolicy, audioIdentity: AudioSessionPhaseIdentity?, audioPolicy: AudioSessionPhasePolicy?,
            excludingIndex: Int? = nil, preparedCycle: PreparedOutputCycle? = nil,
            replacingRetiredCommandIndex: Int? = nil,
            retiringCommandMask: UInt32 = 0,
            allocator: PlaybackIdentityAllocator) throws -> PreparedCommand {
            guard preparedCycle != nil || retiringCommandMask == 0 else {
                throw Failure.invalidGroup
            }
            if let replacingRetiredCommandIndex {
                guard case .terminal = commands[replacingRetiredCommandIndex]?.phase,
                      commands[replacingRetiredCommandIndex].map({ mayDiscard($0) }) == true else { throw Failure.invalidGroup }
            }
            if cleanupReservation?.ticket.ownerGroup == group, policy != .safetyBypass { throw Failure.invalidGroup }
            if slot == .accounting || slot == .systemEventRelay,
               !allowsOutputRelayBinding(group) { throw Failure.invalidGroup }
            guard snapshot.failure == nil || policy == .safetyBypass else { throw Failure.invalidGroup }
            guard preparedCycle?.reservation.ticket.workGroup == group ||
                groups.contains(where: { $0?.ticket == group && $0?.sealed == false }) else {
                throw Failure.invalidGroup
            }
            guard slot.requiredPolicy == policy else { throw Failure.invalidPolicy }
            if slot == .audioSessionRecovery && commands.indices.contains(where: {
                $0 != replacingRetiredCommandIndex && commands[$0]?.slot == .audioSessionRecovery
            }) {
                throw Failure.slotOccupied
            }
            guard !commands.indices.contains(where: {
                $0 != replacingRetiredCommandIndex
                    && retiringCommandMask & (1 << $0) == 0
                    && commands[$0]?.resourceIdentity == group.resourceIdentity
                    && commands[$0]?.slot == slot
            }) else {
                throw Failure.slotOccupied
            }
            // AudioSession顺序恢复链与其他安全工作共享保留池；gate语义保持独立。
            let range = policy == .safetyBypass || slot == .audioSessionRecovery ? 16..<32 : 0..<16
            let reservedAudioIndex: Int?
            if let reservation = preparedCycle?.reservation ?? cleanupReservation, slot == .audioSessionRecovery,
               group == reservation.ticket.workGroup || group == reservation.ticket.ownerGroup,
               !reservation[.audioSession].consumed {
                reservedAudioIndex = reservation[.audioSession].index
            } else { reservedAudioIndex = nil }
            guard let index = reservedAudioIndex ?? replacingRetiredCommandIndex ?? range.first(where: {
                $0 != excludingIndex && commands[$0] == nil && cleanupReservation?.reserves($0) != true
            }), commands[index] == nil || index == replacingRetiredCommandIndex else { throw Failure.capacity }
            let ticket = ControlTaskTicket(group: group, nonce: try allocator.next(in: .controlTask))
            let frozen: ControlCommandSafetySnapshot
            switch policy {
            case .safetyBypass: frozen = .cleanupOwnership
            case .routeSpeculativeRateZero:
                frozen = .speculative(ControlSystemSafetySnapshot(snapshot), routeSemantic)
            case .activationRequiresOpen:
                frozen = .system(ControlSystemSafetySnapshot(snapshot))
            case .routeNeutral, .audioSession:
                frozen = .reservation(mediaServicesEpoch: snapshot.mediaServicesEpoch)
            }
            let record = try OwnedPostIngressControlCommand(controlTaskTicket: ticket,
                slot: slot, safetySnapshot: frozen, gatePolicy: policy,
                audioPhaseIdentity: audioIdentity, audioPolicy: audioPolicy)
            return .init(index: index, ticket: ticket, record: record, reservedStage: nil)
        }

        /// 只退休原清理图；running root必须已由外部join移走payload，不能吃掉在途runner。
        func retainedCleanupRetiringMask(_ context: OutputResourceContext) -> UInt32? {
            let reservation = context.reservation
            var mask: UInt32 = 0
            for index in commands.indices {
                guard let record = commands[index],
                      record.groupTicket == reservation.ownerGroup || record.groupTicket == reservation.workGroup ||
                        isDescendant(record.groupTicket, of: reservation.workGroup) else { continue }
                guard mayDiscard(record) else { return nil }
                if case .terminal = record.phase { mask |= 1 << index }
                else {
                    guard record.ownerTicket == reservation.ownerGroup.ownerTicket,
                          record.slot == ReservedCleanupStage.owner.slot, record.phase == .running else { return nil }
                    mask |= 1 << index
                }
            }
            return mask
        }

        func prepareOutputCycleLocked(_ context: inout OutputResourceContext,
            replacingRetiredCommandIndex: Int? = nil, retiringCommandMask: UInt32 = 0,
            allocator: PlaybackIdentityAllocator) throws -> PreparedOutputCycle? {
            guard context.phase == .quiescentBackend || context.phase == .pendingSuccessorLease,
                  var renewed = cleanupReservation, renewed.ticket == context.reservation,
                  !renewed.terminal, context.disposition != .releaseAfterTeardown,
                  isTerminal(renewed.ticket.workGroup), context.delivery == nil,
                  let groupIndex = groups.firstIndex(where: { $0?.ticket == renewed.ticket.workGroup }) else { return nil }
            guard commands.indices.allSatisfy({ index in
                guard index != replacingRetiredCommandIndex, retiringCommandMask & (1 << index) == 0,
                    let record = commands[index],
                    record.groupTicket == renewed.ticket.ownerGroup || record.groupTicket == renewed.ticket.workGroup ||
                    isDescendant(record.groupTicket, of: renewed.ticket.workGroup) else { return true }
                return false
            }) else { return nil }
            var mask: UInt32 = 0
            for index in groups.indices {
                guard let group = groups[index], isDescendant(group.ticket, of: renewed.ticket.workGroup) else { continue }
                guard group.sealed, isTerminal(group.ticket) else { return nil }
                mask |= 1 << index
            }
            guard !allocator.isExhausted else { throw Failure.invalidGroup }
            let previous = renewed.ticket
            let owner = ControlTaskOwnerTicket(resourceIdentity: previous.workGroup.resourceIdentity,
                nonce: try allocator.next(in: .nonce))
            let work = ControlTaskGroupTicket(resourceIdentity: previous.workGroup.resourceIdentity, ownerTicket: owner,
                nonce: try allocator.next(in: .controlTask))
            for stage in ReservedCleanupStage.allCases where renewed[stage].consumed {
                renewed[stage] = .init(index: renewed[stage].index, nonce: try allocator.next(in: .controlTask))
                if stage == .audioSession { renewed.deactivationPhaseNonce = try allocator.next(in: .nonce) }
            }
            for conversion in CleanupReservation.Conversion.allCases where renewed.nonce(for: conversion) == nil {
                let nonce = try allocator.next(in: .nonce)
                switch conversion {
                case .predecessor: renewed.predecessorContextNonce = nonce
                case .leaseOnly: renewed.leaseOnlyContextNonce = nonce
                case .monitorOnly: renewed.monitorOnlyContextNonce = nonce
                case .retainedSuccessor: renewed.retainedSuccessorContextNonce = nonce
                }
            }
            renewed.consumedConversions = 0
            renewed.ticket = .init(ownerGroup: previous.ownerGroup, workGroup: work, nonce: previous.nonce)
            return .init(reservation: renewed, groupIndex: groupIndex, retiredDescendantMask: mask,
                group: try Group(ticket: work, parent: previous.ownerGroup))
        }


        func installOutputCycleLocked(_ prepared: PreparedOutputCycle, context: inout OutputResourceContext) {
            context.reservation = prepared.reservation.ticket
            context.sourceTask = nil
            context.suspend = nil
            context.suspendConfirmed = false
            context.suspendRequiresRetirement = false
            context.suspendTimedOut = false
            context.retirement = nil
            context.retirementConfirmed = context.phase == .quiescentBackend
            context.teardown = nil
            context.teardownRequested = false
            context.monitorStop = nil
            context.budget = nil
            context.closeClaim = nil
            for index in groups.indices where prepared.retiredDescendantMask & (1 << index) != 0 {
                groups[index] = nil
            }
            groups[prepared.groupIndex] = prepared.group
            cleanupReservation = prepared.reservation
        }


        func parentEffectiveElapsed(_ parent: PlaybackProgressBudgetTicket, at instant: UInt64) -> UInt64? {
            guard let running = parent.runningSince else { return parent.accumulatedEffectiveTime }
            guard instant >= running else { return nil }
            let (elapsed, overflow) = parent.accumulatedEffectiveTime.addingReportingOverflow(instant - running)
            return overflow ? nil : elapsed
        }


        enum ReactivationPreparation {
            case waiting, expired, ready
        }

        func prepareReactivation(context: inout OutputResourceContext, phase: inout RegisteredAudioSessionPhase,
            stage: inout PostConfigurationRouteState?, pending: inout PendingRouteObservation,
            command: inout PreparedCommand?, cycle: inout PreparedOutputCycle?,
            snapshot incoming: PlaybackSafetySnapshot, contextNonce: UInt64, mandatorySuffix: UInt64,
            instant: UInt64, replacingRetiredCommandIndex: Int? = nil,
            newlyPreparedInterruptionProof: InterruptionDrainProof? = nil,
            allocator: PlaybackIdentityAllocator) throws -> ReactivationPreparation {
            guard context.contextNonce == contextNonce,
                  context.phase == .pendingSuccessorLease || context.phase == .quiescentBackend,
                  !context.poisoned, context.disposition != .releaseAfterTeardown, !incoming.userPaused,
                  context.pendingActivationCall == nil, !incoming.interruptionVeto,
                  case .ended = incoming.interruptionState,
                  let receipts = context.sessionReceipts, receipts.active == nil,
                  receipts.process == processConfigurationReceipt,
              receipts.process.identity.configurationGeneration == currentConfigurationGeneration,
              let lease = ownedResource?.payload.lease, let originalParent = context.parentDeadline else { return .waiting }
            guard !commands.indices.contains(where: {
                $0 != replacingRetiredCommandIndex && commands[$0]?.slot == .audioSessionRecovery
            }) else { return .waiting }
            var parent: PlaybackProgressBudgetTicket
            switch originalParent { case .coldStart(let value), .outputRecovery(let value): parent = value }
            guard let elapsed = parentEffectiveElapsed(parent, at: instant), mandatorySuffix > 0,
                  mandatorySuffix < parent.cap else { return .waiting }
            let proof: AudioSessionReactivationProof
            if let post = stage, let registered = registeredPostConfigurationProof,
               let binding = context.systemRecoveryBinding,
               registered.incarnationIdentity == binding.incarnation.identity,
               registered.resetDrainProofIdentity == binding.resetDrainProof.identity,
               registered.postConfigurationStageIdentity == post.budget.stageIdentity,
               registered.retainedContextNonce == contextNonce, registered.leaseID == lease.leaseID,
               registered.committedGeneration == currentConfigurationGeneration {
                proof = .resetPostConfiguration(registered)
            } else if context.pendingReset == nil, let registered = context.interruptionProof,
                      registeredDrainProof == .interruption(registered) || newlyPreparedInterruptionProof == registered,
                      !context.interruptionDrainRequired,
                      registered.sessionIdentity == context.sessionIdentity, registered.contextNonce == contextNonce,
                      registered.configuredGeneration == currentConfigurationGeneration {
                // ended推进attempt的当前epoch，但不撤销准确旧drain；只有下一began会清掉此登记。
                proof = .interruption(registered)
            } else { return .waiting }
            var cutoff = parent.cap - mandatorySuffix
            let stageElapsed: UInt64?
            if let current = stage {
                guard let used = current.effectiveElapsed(at: instant), used < current.budget.maximumEffectiveDuration else {
                    return .expired
                }
                let (stageCutoff, overflow) = elapsed.addingReportingOverflow(current.budget.maximumEffectiveDuration - used)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                cutoff = min(cutoff, stageCutoff)
                stageElapsed = used
            } else { stageElapsed = nil }
            var state: AudioSessionReactivationBudgetState
            if let previous = phase.reactivationState {
                guard previous.ticket.identity.sessionIdentity == context.sessionIdentity,
                      previous.ticket.committedGeneration == currentConfigurationGeneration,
                      previous.ticket.parentOperationTicketIdentity == parent.identity,
                      previous.ticket.postConfigurationStageIdentity == stage?.budget.stageIdentity,
                      previous.ticket.mandatorySuffix >= mandatorySuffix,
                      previous.basePhase == .awaitingActivation else { return .waiting }
                state = previous
            } else {
                state = .init(ticket: .init(identity: .init(sessionIdentity: context.sessionIdentity,
                    recoveryLineageIdentity: try allocator.next(in: .nonce), budgetNonce: try allocator.next(in: .deadline)),
                    committedGeneration: currentConfigurationGeneration, parentOperationTicketIdentity: parent.identity,
                    postConfigurationStageIdentity: stage?.budget.stageIdentity, mandatorySuffix: mandatorySuffix,
                    activationCutoffEffectiveElapsed: cutoff), basePhase: .awaitingActivation, freezeCauses: [], cutoffArmTicket: nil)
            }
            state.freezeCauses.remove(.systemInterruption)
            guard !state.freezeCauses.activationBlocked else { return .waiting }
            if authoritativeRoute == .none { state.freezeCauses.insert(.routeUnavailable) }
            guard elapsed < state.ticket.activationCutoffEffectiveElapsed,
                  pending.deadline.map({ instant < $0.deadlineInstant }) ?? true,
                  stage?.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute.map({ instant < $0.deadlineInstant }) ?? true else {
                return .expired
            }
            if groups.contains(where: { $0?.ticket == context.reservation.workGroup && $0?.sealed == true }) {
                cycle = try prepareOutputCycleLocked(&context, replacingRetiredCommandIndex: replacingRetiredCommandIndex,
                    allocator: allocator)
                guard cycle != nil else { return .waiting }
            } else { cycle = nil }
            if stage == nil, pending.ordinaryDeadlineState == nil {
                guard let monitor = lease.monitor else { return .waiting }
                let (deadline, overflow) = instant.addingReportingOverflow(3_000_000_000)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                pending.ordinaryDeadlineState = .init(ticket: .init(identity: .init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: monitor.lifecycle, mediaServicesEpochAtCreation: incoming.mediaServicesEpoch,
                    deadlineAnchorInstant: instant, deadlineNonce: try allocator.next(in: .deadline)), deadlineInstant: deadline),
                    armNonce: try allocator.next(in: .deadline))
            }
            let invocation = try AudioSessionActivationInvocationIdentity(allocator: allocator)
            let attempt = AudioSessionReactivationAttemptTicket(reactivationBudgetIdentity: state.ticket.identity,
                reactivationProof: proof, interruptionEpoch: incoming.interruptionEpoch,
                retainedContextNonce: contextNonce, attemptNonce: invocation)
            parent.accumulatedEffectiveTime = elapsed
            parent.runningSince = state.freezeCauses.isEmpty ? instant : nil
            parent.freezeGeneration = incoming.freezeGeneration
            state.cutoffArmTicket = state.freezeCauses.isEmpty ? .init(reactivationBudgetIdentity: state.ticket.identity,
                reactivationAttemptIdentity: invocation, parentFreezeGeneration: parent.freezeGeneration,
                activationCutoffEffectiveElapsed: state.ticket.activationCutoffEffectiveElapsed,
                armNonce: try allocator.next(in: .deadline)) : nil
            let group = cycle?.reservation.ticket.workGroup ?? context.reservation.workGroup
            phase.identity = .init(owner: group.ownerTicket,
                sessionIdentity: context.sessionIdentity, leaseID: lease.leaseID, contextNonce: contextNonce,
                mediaServicesEpoch: incoming.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce))
            phase.policy = .activate(purpose: .reactivateConfiguredGeneration(sessionIdentity: context.sessionIdentity,
                    configurationTransitionIdentity: stage?.budget.configurationTransitionIdentity,
                    committedGeneration: currentConfigurationGeneration, reactivationAttempt: attempt),
                    interruptionEpoch: incoming.interruptionEpoch,
                    audioAdmissionFenceRevision: incoming.audioAdmissionFenceRevision, invocationIdentity: invocation)
            // 只改锁内局部候选；逐字段填齐当前事实，不保留旧acquisition/reset引用。
            phase.configurationAttempt = receipts.process.attemptLineage
            phase.parent = parent.identity
            phase.resetBinding = context.resetPreRouteBinding
            phase.incarnation = context.systemRecoveryBinding?.incarnation
            phase.reactivationState = state
            phase.configurationProgress = .complete(actualPolicy: receipts.process.actualPolicy,
                preferredFailure: receipts.process.preferredFailureReason, multichannel: receipts.process.multichannelCapability)
            phase.permitsFurtherCalls = true
            phase.acquisitionOwnershipProof = nil
            phase.processReceipt = receipts.process
            phase.configuredReceipt = receipts.configured
            phase.inactiveReceipt = context.systemRecoveryBinding?.inactiveConfigurationReceipt
            phase.currentReactivationProof = proof
            command = try prepareCommand(group: group, slot: .audioSessionRecovery, policy: .audioSession,
                audioIdentity: phase.identity, audioPolicy: phase.policy, preparedCycle: cycle,
                replacingRetiredCommandIndex: replacingRetiredCommandIndex, allocator: allocator)
            if let stageElapsed {
                stage?.budget.accumulatedEffectiveTime = stageElapsed
                stage?.runningSince = instant
                stage?.freezeGeneration = incoming.freezeGeneration
            }
            switch originalParent { case .coldStart: context.parentDeadline = .coldStart(parent)
            case .outputRecovery: context.parentDeadline = .outputRecovery(parent) }
            return .ready

        }

        func applyOutputControl(_ request: OutputControlRequest, snapshot incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64) -> OutputControlApplication {
            precondition(!resourceTransactionActive, "具名控制不能重入资源CAS")
            switch request {
            case .playbackAdmission(let requestID):
                guard resourceState != nil || !commands.contains(where: {
                    if case .controllerCleanup = $0?.payload { return true }; return false
                }) else { return .playbackAdmissionNeedsCleanupJoin }
                do {
                    let session = PlaybackSessionIdentity(sessionID: try allocator.next(in: .session), requestID: requestID)
                    var budget = PlaybackProgressBudgetTicket.coldStart(sessionIdentity: session,
                        originInstant: instant, nonce: try allocator.next(in: .deadline),
                        freezeGeneration: try allocator.next(in: .freezeGeneration))
                    if !incoming.interruptionVeto { budget.resume(at: instant, freezeGeneration: budget.freezeGeneration) }
                    var output = incoming.output
                    if let predecessor = outputContext {
                        _ = try AudioSessionLockedOperations(authority: self, allocator: allocator,
                            instant: instant).beginOutputTransitionLocked(contextNonce: predecessor.contextNonce,
                                reason: .stop, anchorInstant: instant, teardown: true,
                                sourceActivation: nil, output: &output)
                    }
                    let admission = CurrentPlaybackOperationDeadlineTicket.coldStart(budget)
                    playbackRequestAdmission = admission
                    // 新请求只清旧用户pause，不越过任何物理interruption veto；同锁提交Cell与Authority。
                    snapshot.userPaused = false
                    snapshot.output = output
                    snapshot.freezeGeneration = budget.freezeGeneration
                    return .playbackAdmitted(admission, output, freezeGeneration: budget.freezeGeneration)
                } catch let failure as PlaybackSafetyFailure { return .failed(failure) }
                catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
                catch { return .failed(.invalidEvidence) }
            case .audioEventRelayLookup:
                guard let context = outputContext, let lease = ownedLeaseResources,
                      let monitor = lease.monitor else { return .rejected }
                for record in commands {
                    guard let record, record.slot == .systemEventRelay,
                          record.phase == .queued || record.phase == .running,
                          record.groupTicket.resourceIdentity == .monitor(session: context.sessionIdentity,
                            lifecycle: monitor.lifecycle),
                          groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false }),
                          case .eventDrain(let runner) = record.payload, !runner.joining,
                          case .audio(let relay) = runner.relay,
                          relay.lease.id == lease.leaseID, relay.lease.generation == lease.leaseID else { continue }
                    return .audioEventRelay(relay)
                }
                return .rejected
            case .audioRelayOverflow(let nonce):
                guard var context = outputContext, let monitor = ownedLeaseResources?.monitor,
                      let record = commands.first(where: { $0?.controlTaskTicket.nonce == nonce }) ?? nil,
                      record.slot == .systemEventRelay,
                      record.phase == .queued || record.phase == .running,
                      record.groupTicket.resourceIdentity == .monitor(session: context.sessionIdentity,
                        lifecycle: monitor.lifecycle),
                      case .eventDrain(let runner) = record.payload, !runner.joining,
                      case .audio = runner.relay,
                      groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false })
                else { return .rejected }
                // 撤权不能替换已在途retirement的owner；原回执继续归还原资源，
                // ring中的唯一failure在receiver返回后交给原owned terminal cleanup。
                context.poisoned = true
                context.disposition = .releaseAfterTeardown
                context.relayClosing = true
                context.teardownRequested = true
                outputContext = context
                registeredDrainProof = nil
                pendingReactivationReceipt = nil
                audioPhase?.permitsFurtherCalls = false
                routeStabilityCandidate = nil
                stableRouteCommit = nil
                snapshot.output.revokeForSafety()
                return .terminated
            case .registrationIngress(let registration):
                return ownsRegistration(registration, allowsClosing: false) ? .registrationValidated : .rejected
            case .audioSessionCall(let action):
                return .audioSessionCall(applyAudioSessionCall(action, snapshot: incoming, allocator: allocator, instant: instant))
            case .user(let request): return applyUserControl(request, snapshot: incoming, allocator: allocator, instant: instant)
            case .suspend(let action):
                do { return try prepareAndApplyOutputSuspend(action, snapshot: incoming, instant: instant) }
                catch let failure as PlaybackSafetyFailure { return .failed(failure) }
                catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
                catch { return .failed(.invalidEvidence) }
            case .interruptionDrain(let owner):
                do { return try prepareAndSettleInterruptionDrain(owner: owner, snapshot: incoming, allocator: allocator, instant: instant) }
                catch let failure as PlaybackSafetyFailure { return .failed(failure) }
                catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
                catch { return .failed(.invalidEvidence) }
            case .retire(let ticket):
                do { return try prepareAndRetireOutputRecord(ticket, snapshot: incoming, allocator: allocator, instant: instant) }
                catch let failure as PlaybackSafetyFailure { return .failed(failure) }
                catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
                catch { return .failed(.invalidEvidence) }
            case .budget(let action):
                do { return try prepareAndApplyPlaybackBudget(action, snapshot: incoming,
                    allocator: allocator, instant: instant) }
                catch let failure as PlaybackSafetyFailure { return .failed(failure) }
                catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
                catch { return .failed(.invalidEvidence) }
            }
        }

        /// 原handle与完整lease/monitor身份都必须属于当前唯一资源图；不按最新session补权。
        func ownsRegistration(_ registration: PlaybackAudioSessionRegistration, allowsClosing: Bool) -> Bool {
            guard let context = outputContext, !context.monitorStopped,
                  allowsClosing || !context.relayClosing,
                  let lease = ownedLeaseResources, lease.object === registration,
                  lease.leaseID == registration.identity.leaseID,
                  let monitor = lease.monitor, monitor.object === registration,
                  monitor.lifecycle == registration.identity.monitorLifecycle,
                  monitor.sessionIdentity == context.sessionIdentity else { return false }
            if let relay = context.committedRelay {
                return relay.relayIdentity.acquisitionTicket == registration.identity.acquisition &&
                    relay.relayIdentity.sessionIdentity == context.sessionIdentity && relay.relayIdentity.leaseID == lease.leaseID &&
                    relay.relayIdentity.monitorLifecycle == monitor.lifecycle
            }
            return context.sourceTask == registration.identity.acquisition ||
                audioPhase?.acquisitionOwnershipProof?.acquisitionTicket == registration.identity.acquisition
        }

        /// 唯一permit与原record在Cell同锁claim；busy不改变queued，也不登记第二lane责任。
        private enum AudioSessionCompletionPurpose {
            case acquisitionConfiguration, retainedConfiguration, acquisitionActivation, resetActivation, reactivation, other
        }
        private func completionPurpose(_ ticket: ControlTaskTicket) -> AudioSessionCompletionPurpose {
            guard let index = commands.firstIndex(where: { $0?.controlTaskTicket == ticket }) else { return .other }
            switch commands[index]?.audioPolicy {
            case .configureAcquisition: return .acquisitionConfiguration
            case .configureInactive: return .retainedConfiguration
            case .activate(.activateAcquiredConfiguredGeneration, _, _, _): return .acquisitionActivation
            case .activate(.commitResetConfiguration, _, _, _): return .resetActivation
            case .activate(.reactivateConfiguredGeneration, _, _, _): return .reactivation
            default: return .other
            }
        }

        /// 只在本次completion的同锁调用链消费；大context在分类返回时结束，不携出授权。
        private func audioSessionFailureTransitionContext(purpose: AudioSessionCompletionPurpose,
            result: AudioSessionBlockingCallResult) -> UInt64? {
            guard let context = outputContext else { return nil }
            let configurationFailed: Bool
            if case .failed = audioPhase?.configurationProgress {
                configurationFailed = purpose == .acquisitionConfiguration || purpose == .retainedConfiguration
            } else { configurationFailed = false }
            let activationFailed: Bool
            if case .activation(.some) = result {
                activationFailed = purpose == .acquisitionActivation || purpose == .reactivation || purpose == .resetActivation
            }
            else { activationFailed = false }
            return configurationFailed || activationFailed ? context.contextNonce : nil
        }

        private enum AudioSessionCompletionFollowUp {
            case acquisitionConfiguration(UInt64, CurrentPlaybackOperationDeadlineTicket)
            case acquisitionActivation(UInt64)
            case retainedConfiguration(UInt64)
            case resetActivation(UInt64)
        }

        /// 原record已退休后才分类；每个begin叶仍完整核验原nonce/parent/phase及期限。
        private func audioSessionCompletionFollowUp(purpose: AudioSessionCompletionPurpose,
            operation: AudioSessionBlockingCallOperation, accepted: Bool) -> AudioSessionCompletionFollowUp? {
            guard cleanupReservation?.terminal == false, let context = outputContext,
                  context.disposition != .releaseAfterTeardown, !context.poisoned else { return nil }
            if case .acquiringLease(_, .configuring) = resourceState, let parent = context.parentDeadline {
                return .acquisitionConfiguration(context.contextNonce, parent)
            }
            if case .acquiringLease(_, .awaitingActivation) = resourceState {
                return .acquisitionActivation(context.contextNonce)
            }
            guard purpose == .retainedConfiguration else { return nil }
            if operation == .multichannel, accepted { return .resetActivation(context.contextNonce) }
            return .retainedConfiguration(context.contextNonce)
        }

        static var audioSessionCompletionFollowUpValueBytes: Int {
            MemoryLayout<AudioSessionCompletionFollowUp?>.stride
        }

        private enum AudioSessionClaimPreparation {
            case rejected, parked
            case operation(AudioSessionBlockingCallOperation)
        }

        /// 先保持原queued/family/sticky及busy顺序；record在返回后结束，不跨入begin准备。
        private func prepareAudioSessionClaim(_ ticket: ControlTaskTicket, lane: AudioSessionBlockingCallLane,
            family: AudioSessionCallFamily, failure: PlaybackSafetyFailure?) -> AudioSessionClaimPreparation {
            guard audioSessionLane === lane,
                  let record = commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .queued else { return .rejected }
            guard (record.slot == .sampler) == (family == .sampler) else { return .rejected }
            guard failure == nil || (record.gatePolicy == .safetyBypass && record.deactivationRequest != nil)
            else { return .rejected }
            guard audioSessionPermit == nil else { return .parked }
            if record.slot == .sampler { return .operation(.currentRoute) }
            if record.deactivationRequest != nil { return .operation(.deactivate) }
            switch record.audioPolicy {
            case .activate: return .operation(.activate)
            case .configureAcquisition(_, _, _, let step), .configureInactive(_, _, _, let step):
                switch step {
                case .longFormCategoryAttempt: return .operation(.longFormCategory)
                case .defaultCategoryFallbackAttempt: return .operation(.defaultCategory)
                case .multichannelCapability: return .operation(.multichannel)
                }
            default: return .rejected
            }
        }

        static var audioSessionClaimPreparationValueBytes: Int {
            MemoryLayout<AudioSessionClaimPreparation>.stride
        }

        func applyAudioSessionCall(_ action: AudioSessionBlockingCallAction, snapshot incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64) -> AudioSessionBlockingCallApplication {
            var output = incoming.output
            let operations = AudioSessionLockedOperations(authority: self, allocator: allocator, instant: instant)
            switch action {
            case .claim(let ticket, let lane, let family):
                let operation: AudioSessionBlockingCallOperation
                switch prepareAudioSessionClaim(ticket, lane: lane, family: family, failure: incoming.failure) {
                case .rejected: return .rejected
                case .parked: return .parked
                case .operation(let value): operation = value
                }
                let registration: PlaybackAudioSessionRegistration?
                do {
                    if operation == .currentRoute {
                        guard case .pending(let pending) = routeObservationState,
                              let observation = pending.ticket, pending.sampler == ticket,
                              let handle = ownedLeaseResources?.monitor?.object as? PlaybackAudioSessionRegistration,
                              ownsRegistration(handle, allowsClosing: false) else { return .rejected }
                        guard try operations.beginOutputRouteSample(observation, source: ticket, output: &output) != nil else {
                            return rejectedAudioSessionClaim(output: output, failure: nil)
                        }
                        registration = handle
                    } else {
                        registration = nil
                        guard try operations.claimStart(ticket, output: &output) else {
                            return rejectedAudioSessionClaim(output: output, failure: nil)
                        }
                    }
                    let permit = AudioSessionBlockingCallPermit(record: ticket, operation: operation)
                    audioSessionPermit = .init(recordNonce: ticket.nonce, operation: operation)
                    return .claimed(.init(permit: permit, registration: registration))
                } catch {
                    let failure: PlaybackSafetyFailure = (error as? PlaybackSafetyFailure) ??
                        (error is PlaybackIdentityAllocationError ? .identitySpaceExhausted : .invalidEvidence)
                    return rejectedAudioSessionClaim(output: output, failure: failure)
                }
            case .complete(let returned, let lane):
                guard let index = commands.firstIndex(where: { $0?.controlTaskTicket == returned.permit.record }),
                      commands[index]?.phase == .running || commands[index]?.phase == .cancelRequested else { return .rejected }
                guard audioSessionLane === lane,
                      audioSessionPermit == .init(recordNonce: returned.permit.record.nonce,
                          operation: returned.permit.operation) else { return .rejected }
                let ticket = returned.permit.record
                let purpose = completionPurpose(ticket)
                let failureBelongsToCurrentPhase = commands[index]?.phase == .running &&
                    commands[index]?.audioPhaseIdentity == audioPhase?.identity
                var followUp: ControlTaskTicket?
                var reactivationReceipt: AudioSessionReactivationCompletionReceipt?
                var terminalOwner: OutputTransitionOwnerTicket?
                var accepted = false
                do {
                    switch (returned.permit.operation, returned.result) {
                    case (.longFormCategory, .configuration(.categorySucceeded)),
                         (.longFormCategory, .configuration(.failed)),
                         (.defaultCategory, .configuration(.categorySucceeded)),
                         (.defaultCategory, .configuration(.failed)),
                         (.multichannel, .configuration(.multichannelCapability)):
                        guard case .configuration(let result) = returned.result,
                              try operations.completeAudioSessionConfiguration(ticket, result: result) else { return .rejected }
                        audioSessionPermit = nil
                        if incoming.failure == nil {
                            if purpose == .acquisitionConfiguration {
                                accepted = try operations.settleOutputAcquisitionConfiguration(ticket, output: &output)
                            } else if purpose == .retainedConfiguration {
                                accepted = try operations.settleOutputRetainedResetConfiguration(ticket, output: &output)
                            }
                        }
                    case (.activate, .activation(let failure)):
                        guard try operations.completeAudioSessionActivation(ticket, failure: failure) else { return .rejected }
                        audioSessionPermit = nil
                        if incoming.failure == nil {
                            switch purpose {
                            case .acquisitionActivation:
                                accepted = try operations.settleOutputAcquisitionActivation(ticket, output: &output)
                            case .resetActivation:
                                accepted = try operations.settleOutputResetConfigurationActivation(ticket, output: &output, followUp: &followUp)
                                if accepted, let context = outputContext,
                                   let active = context.sessionReceipts?.active,
                                   let proof = registeredPostConfigurationProof {
                                    reactivationReceipt = .init(sourceRecordNonce: ticket.nonce,
                                        contextNonce: context.contextNonce, proofNonce: proof.proofNonce,
                                        leaseID: active.leaseID, activationNonce: active.activationNonce,
                                        interruptionEpoch: active.interruptionEpoch,
                                        mediaServicesEpoch: incoming.mediaServicesEpoch,
                                        audioAdmissionFenceRevision: incoming.audioAdmissionFenceRevision)
                                    pendingReactivationReceipt = reactivationReceipt
                                }
                            case .reactivation:
                                accepted = try operations.settleOutputReactivation(ticket, output: &output, followUp: &followUp)
                                if accepted, let context = outputContext,
                                   let active = context.sessionReceipts?.active,
                                   let proof = context.interruptionProof,
                                   registeredDrainProof == .interruption(proof) {
                                    reactivationReceipt = .init(sourceRecordNonce: ticket.nonce,
                                        contextNonce: context.contextNonce, proofNonce: proof.proofNonce,
                                        leaseID: active.leaseID, activationNonce: active.activationNonce,
                                        interruptionEpoch: active.interruptionEpoch,
                                        mediaServicesEpoch: incoming.mediaServicesEpoch,
                                        audioAdmissionFenceRevision: incoming.audioAdmissionFenceRevision)
                                    pendingReactivationReceipt = reactivationReceipt
                                }
                            default: break
                            }
                        }
                        if !accepted { _ = operations.transferActivationDispositionLocked(ticket) }
                    case (.deactivate, .deactivation(let result)):
                        guard try operations.completeAudioSessionDeactivation(ticket, result: result) else { return .rejected }
                        audioSessionPermit = nil
                    case (.currentRoute, .route(let evidence)):
                        guard let claim = routeSampleClaim, claim.source == ticket else { return .rejected }
                        // 精确claim保留到同一次typed接纳；任意throw仍结束已返回的物理责任。
                        defer {
                            audioSessionPermit = nil
                            if routeSampleClaim == claim {
                                commands[index]?.phase = .terminal(.canceled)
                                routeSampleClaim = nil
                                if case .pending(var pending) = routeObservationState, pending.sampler == ticket {
                                    pending.sampleInFlight = false
                                    pending.sampler = nil
                                    routeObservationState = .pending(pending)
                                }
                            }
                        }
                        let application = try prepareAndCompleteRouteSample(claim, result: .none, rawEvidence: evidence,
                            snapshot: incoming, allocator: allocator, instant: instant)
                        switch application {
                        case .routeSampled(_, _, _, let replacement): accepted = true; followUp = replacement
                        case .routeSampleSettled(let replacement): followUp = replacement
                        case .failed(let failure): throw failure
                        default: break
                        }
                        output = snapshot.output
                    default: return .rejected
                    }
                    if incoming.failure == nil, failureBelongsToCurrentPhase,
                       let contextNonce = audioSessionFailureTransitionContext(purpose: purpose, result: returned.result) {
                        terminalOwner = try operations.beginOutputTransitionLocked(contextNonce: contextNonce,
                            reason: .terminal, anchorInstant: instant, teardown: true,
                            sourceActivation: nil, output: &output)
                    }
                    // available sampler的准确terminal source仍承接stability责任；不能在这里提前删掉。
                    if returned.permit.operation != .currentRoute,
                       case .retired(let successor, _) = try prepareAndRetireOutputRecord(ticket, snapshot: snapshot,
                        allocator: allocator, instant: instant) { followUp = followUp ?? successor }
                    if incoming.failure == nil, followUp == nil,
                       let next = audioSessionCompletionFollowUp(purpose: purpose,
                        operation: returned.permit.operation, accepted: accepted) {
                        switch next {
                        case .acquisitionConfiguration(let contextNonce, let parent):
                            followUp = try operations.beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent, output: &output)
                        case .acquisitionActivation(let contextNonce):
                            followUp = try operations.beginOutputAcquisitionActivation(contextNonce: contextNonce, output: &output)
                        case .retainedConfiguration(let contextNonce):
                            followUp = try operations.beginOutputRetainedResetConfigurationStep(contextNonce: contextNonce, output: &output)
                        case .resetActivation(let contextNonce):
                            followUp = try operations.beginOutputResetConfigurationActivation(contextNonce: contextNonce, output: &output)
                        }
                    }
                    snapshot.output = output
                    return .completed(.init(disposition: accepted ? .accepted : .settled, followUp: followUp, failure: nil,
                        reactivationReceipt: reactivationReceipt, terminalOwner: terminalOwner),
                        output, freezeGeneration: snapshot.freezeGeneration, audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision)
                } catch {
                    // 已归还permit和真实terminal不回滚；尤其success不能因后继耗尽而遗失deactivate责任。
                    _ = operations.transferActivationDispositionLocked(ticket)
                    let failure: PlaybackSafetyFailure = (error as? PlaybackSafetyFailure) ??
                        (error is PlaybackIdentityAllocationError ? .identitySpaceExhausted : .invalidEvidence)
                    return .completed(.init(disposition: .failed, followUp: nil, failure: failure), output,
                        freezeGeneration: snapshot.freezeGeneration, audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision)
                }
            }
        }

        private func rejectedAudioSessionClaim(output: PlaybackOutputSafetyState,
            failure: PlaybackSafetyFailure?) -> AudioSessionBlockingCallApplication {
            snapshot.output = output
            return .claimRejected(output, freezeGeneration: snapshot.freezeGeneration,
                audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision, failure: failure)
        }

        func prepareRecoveryParent(context: OutputResourceContext, snapshot incoming: PlaybackSafetySnapshot,
            originInstant: UInt64, resetPreRoute: Bool, allocator: PlaybackIdentityAllocator
        ) throws -> CurrentPlaybackOperationDeadlineTicket {
            if let current = context.parentDeadline { return current }
            var parent = PlaybackProgressBudgetTicket.outputRecovery(
                sessionIdentity: context.sessionIdentity, originInstant: originInstant,
                nonce: try allocator.next(in: .deadline), freezeGeneration: incoming.freezeGeneration
            )
            let shouldRun = resetPreRoute
                ? !incoming.userPaused && incoming.interruptionState != .began
                : !incoming.userPaused && !incoming.interruptionVeto &&
                    context.sessionReceipts?.active != nil && authoritativeRoute.semantic != nil
            if shouldRun { parent.runningSince = originInstant }
            return .outputRecovery(parent)
        }

        private func currentPostConfigurationArm(
            _ state: PostConfigurationRouteState
        ) -> PostConfigurationRouteDeadlineArmTicket {
            .init(configurationTransitionIdentity: state.budget.configurationTransitionIdentity,
                stageIdentity: state.budget.stageIdentity,
                configurationGeneration: state.budget.configurationGeneration,
                parentOperationTicketIdentity: state.budget.parentOperationDeadline,
                attemptNonce: state.budget.attemptNonce, freezeGeneration: state.freezeGeneration)
        }

        private func settledResetParent(
            _ state: ResetPreRouteRecoveryDeadlineState, context: OutputResourceContext
        ) throws -> CurrentPlaybackOperationDeadlineTicket {
            guard let original = context.parentDeadline else { throw PlaybackSafetyFailure.invalidEvidence }
            var parent: PlaybackProgressBudgetTicket
            switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
            guard parent.identity == state.ticketIdentity.parentOperationTicketIdentity,
                  state.accumulatedEffectiveTime >= parent.accumulatedEffectiveTime else {
                throw PlaybackSafetyFailure.invalidEvidence
            }
            parent.accumulatedEffectiveTime = state.accumulatedEffectiveTime
            parent.runningSince = state.runningSince
            parent.freezeGeneration = state.freezeGeneration
            switch original {
            case .coldStart: return .coldStart(parent)
            case .outputRecovery: return .outputRecovery(parent)
            }
        }

        private func terminatePlaybackBudget(
            _ context: inout OutputResourceContext, instant: UInt64,
            resetState: ResetPreRouteRecoveryDeadlineState? = nil
        ) throws -> OutputControlApplication {
            guard let reservation = cleanupReservation, reservation.ticket == context.reservation else {
                return .rejected
            }
            if context.poisoned {
                outputContext = context
                return .terminated
            }
            let budget = try context.budget ?? CleanupBudgetTicket(
                predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                anchorInstant: instant, nonce: context.reservation.nonce
            )
            let command = try prepareTerminalCleanupOwner(context.reservation)
            context.budget = budget
            context.owner = runningCleanupOwner(context.reservation) ?? .init(identity: reservation.terminalOwner, reason: .terminal)
            context.poisoned = true
            context.disposition = .releaseAfterTeardown
            context.relayClosing = true
            context.teardownRequested = true
            if let resetState { resetPreRouteState = resetState }
            outputContext = context
            audioPhase?.reactivationState?.cutoffArmTicket = nil
            audioPhase?.permitsFurtherCalls = false
            routeStabilityCandidate = nil
            stableRouteCommit = nil
            snapshot.output.revokeForSafety()
            installPreparedCommand(command)
            terminateCleanupReservation()
            return .terminated
        }

        /// evaluate返回以后，具体timer/progress的局部值先退栈；终态owner准备只与此封闭decision重叠。
        private enum PlaybackBudgetEvaluation {
            case application(OutputControlApplication)
            case terminate
            case terminateReset(CurrentPlaybackOperationDeadlineTicket, ResetPreRouteRecoveryDeadlineState)
        }

        static var playbackBudgetEvaluationValueBytes: Int {
            MemoryLayout<PlaybackBudgetEvaluation>.stride
        }

        private func replacingOrdinaryArm(
            _ inherited: InheritedRouteAvailabilityConstraint, with armNonce: UInt64
        ) -> InheritedRouteAvailabilityConstraint {
            guard let ordinary = inherited.ordinaryAbsolute else { return inherited }
            return .init(ordinaryAbsolute: .init(ticketIdentity: ordinary.ticketIdentity,
                deadlineInstant: ordinary.deadlineInstant, timerArmIdentity: armNonce),
                carriedPostConfigurationStage: inherited.carriedPostConfigurationStage)
        }

        private func installInheritedConstraint(
            _ inherited: InheritedRouteAvailabilityConstraint, context: inout OutputResourceContext
        ) {
            switch context.resetResourceBinding {
            case .draining(let binding):
                context.resetResourceBinding = .draining(.init(
                    preRouteBinding: binding.preRouteBinding,
                    inheritedRouteAvailabilityConstraint: inherited))
            case .acquiring(let binding):
                context.resetResourceBinding = .acquiring(.init(proof: binding.proof,
                    preRouteTicket: binding.preRouteTicket, binding: binding.binding,
                    inheritedRouteAvailabilityConstraint: inherited))
            case .retained(let binding):
                let incarnation = binding.incarnation
                let updated = SystemRecoveryIncarnation(identity: incarnation.identity,
                    drainProof: incarnation.drainProof,
                    baseConfigurationGeneration: incarnation.baseConfigurationGeneration,
                    configurationPlan: incarnation.configurationPlan,
                    outerDeadlineTicket: incarnation.outerDeadlineTicket,
                    resetPreRouteDeadlineTicket: incarnation.resetPreRouteDeadlineTicket,
                    inheritedRouteAvailabilityConstraint: inherited)
                context.resetResourceBinding = .retained(.init(incarnation: updated,
                    inactiveConfigurationReceipt: binding.inactiveConfigurationReceipt,
                    resetPreRouteBinding: binding.resetPreRouteBinding,
                    configurationState: binding.configurationState))
            case nil: break
            }
            if var stage = postConfigurationRouteState,
               let stageInherited = stage.budget.inheritedRouteAvailabilityConstraint,
               stageInherited.ordinaryAbsolute?.ticketIdentity == inherited.ordinaryAbsolute?.ticketIdentity {
                stage.budget = .init(
                    configurationTransitionIdentity: stage.budget.configurationTransitionIdentity,
                    stageIdentity: stage.budget.stageIdentity,
                    carriedStageLineageIdentity: stage.budget.carriedStageLineageIdentity,
                    configurationGeneration: stage.budget.configurationGeneration,
                    parentOperationDeadline: stage.budget.parentOperationDeadline,
                    inheritedRouteAvailabilityConstraint: inherited,
                    maximumEffectiveDuration: stage.budget.maximumEffectiveDuration,
                    accumulatedEffectiveTime: stage.budget.accumulatedEffectiveTime,
                    attemptNonce: stage.budget.attemptNonce)
                postConfigurationRouteState = stage
            }
        }

        private func prepareAndApplyPlaybackBudget(_ action: PlaybackBudgetControlAction,
            snapshot incoming: PlaybackSafetySnapshot, allocator: PlaybackIdentityAllocator,
            instant: UInt64) throws -> OutputControlApplication {
            let evaluation = try evaluatePlaybackBudget(action, snapshot: incoming,
                allocator: allocator, instant: instant)
            switch evaluation {
            case .application(let result): return result
            case .terminate:
                guard var context = outputContext else { return .rejected }
                return try terminatePlaybackBudget(&context, instant: instant)
            case .terminateReset(let parent, let state):
                guard var context = outputContext else { return .rejected }
                context.parentDeadline = parent
                return try terminatePlaybackBudget(&context, instant: instant, resetState: state)
            }
        }

        private func evaluatePlaybackBudget(_ action: PlaybackBudgetControlAction,
            snapshot incoming: PlaybackSafetySnapshot, allocator: PlaybackIdentityAllocator,
            instant: UInt64) throws -> PlaybackBudgetEvaluation {
            func rearm<Arm: Sendable & Equatable>(
                _ arm: Arm, remainingNanoseconds: UInt64
            ) throws -> PlaybackDeadlineRearm<Arm> {
                let (notAfter, overflow) = instant.addingReportingOverflow(remainingNanoseconds)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                return .init(arm: arm, remainingNanoseconds: remainingNanoseconds,
                    notAfterInstant: notAfter)
            }
            switch action {
            case .acquisitionTimer(let expected):
                guard let context = outputContext, context.acquisitionDeadline == expected else {
                    return .application(.budget(.rejected))
                }
                if instant < expected.deadlineInstant {
                    return .application(.budget(.acquisitionRearmed(expected,
                        remainingNanoseconds: expected.deadlineInstant - instant,
                        notAfterInstant: expected.deadlineInstant)))
                }
                return .terminate

            case .cleanupTimer(let expected):
                guard let context = outputContext, context.budget == expected else {
                    return .application(.budget(.rejected))
                }
                if instant < expected.deadlineInstant {
                    return .application(.budget(.cleanupRearmed(expected,
                        remainingNanoseconds: expected.deadlineInstant - instant,
                        notAfterInstant: expected.deadlineInstant)))
                }
                return .terminate

            case .ordinaryRouteTimer(let expected):
                guard incoming.failure == nil, var context = outputContext, !context.poisoned else {
                    return .application(.budget(.rejected))
                }
                if case .pending(var pending) = routeObservationState,
                   var state = pending.ordinaryDeadlineState, state.arm == expected {
                    if instant >= state.ticket.deadlineInstant {
                        return .terminate
                    }
                    state.armNonce = try allocator.next(in: .deadline)
                    pending.ordinaryDeadlineState = state
                    routeObservationState = .pending(pending)
                    return .application(.budget(.ordinaryRouteRearmed(try rearm(state.arm,
                        remainingNanoseconds: state.ticket.deadlineInstant - instant))))
                }
                guard let inherited = context.resetInheritedRouteAvailabilityConstraint,
                      let ordinary = inherited.ordinaryAbsolute,
                      ordinary.ticketIdentity == expected.ticketIdentity,
                      ordinary.timerArmIdentity == expected.armNonce else {
                    return .application(.budget(.rejected))
                }
                if instant >= ordinary.deadlineInstant {
                    return .terminate
                }
                let arm = RouteUnavailableDeadlineArmTicket(ticketIdentity: ordinary.ticketIdentity,
                    armNonce: try allocator.next(in: .deadline))
                installInheritedConstraint(replacingOrdinaryArm(inherited, with: arm.armNonce), context: &context)
                outputContext = context
                return .application(.budget(.ordinaryRouteRearmed(try rearm(arm,
                    remainingNanoseconds: ordinary.deadlineInstant - instant))))

            case .resetPreRouteTimer(let expected):
                guard incoming.failure == nil, let context = outputContext, !context.poisoned,
                      let binding = context.resetPreRouteBinding,
                      var state = resetPreRouteState, state.deadlineArm == expected,
                      binding.ticketIdentity == state.ticketIdentity,
                      context.parentDeadline != nil, state.runningSince != nil else {
                    return .application(.budget(.rejected))
                }
                let elapsed = try state.checkedEffectiveElapsed(at: instant)
                let ordinaryExpired = context.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute
                    .map { instant >= $0.deadlineInstant } ?? false
                if elapsed >= state.boundaryEffectiveElapsed || ordinaryExpired {
                    state.accumulatedEffectiveTime = elapsed
                    state.runningSince = nil
                    state.deadlineArm = nil
                    let parent = try settledResetParent(state, context: context)
                    return .terminateReset(parent, state)
                }
                var remaining = state.boundaryEffectiveElapsed - elapsed
                if let ordinary = context.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute {
                    remaining = min(remaining, ordinary.deadlineInstant - instant)
                }
                return .application(.budget(.resetPreRouteRearmed(try rearm(expected,
                    remainingNanoseconds: remaining))))

            case .postConfigurationTimer(let expected):
                guard incoming.failure == nil, let context = outputContext, !context.poisoned,
                      let original = context.parentDeadline, let state = postConfigurationRouteState,
                      state.runningSince != nil, currentPostConfigurationArm(state) == expected else {
                    return .application(.budget(.rejected))
                }
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                guard parent.identity == expected.parentOperationTicketIdentity else {
                    return .application(.budget(.rejected))
                }
                let elapsed = try state.checkedEffectiveElapsed(at: instant)
                let parentElapsed = try parent.effectiveElapsed(at: instant)
                let ordinaryExpired = state.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute
                    .map { instant >= $0.deadlineInstant } ?? false
                if elapsed >= state.budget.maximumEffectiveDuration || parentElapsed >= parent.cap || ordinaryExpired {
                    return .terminate
                }
                var remaining = min(state.budget.maximumEffectiveDuration - elapsed, parent.cap - parentElapsed)
                if let ordinary = state.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute {
                    remaining = min(remaining, ordinary.deadlineInstant - instant)
                }
                return .application(.budget(.postConfigurationRearmed(try rearm(expected,
                    remainingNanoseconds: remaining))))

            case .reactivationTimer(let expected):
                guard incoming.failure == nil, let context = outputContext, !context.poisoned,
                      let phase = audioPhase, let state = phase.reactivationState,
                      state.cutoffArmTicket == expected, state.basePhase == .awaitingActivation,
                      state.freezeCauses.isEmpty,
                      case .activate(let purpose, _, _, let invocation) = phase.policy,
                      invocation == expected.reactivationAttemptIdentity,
                      matchesPurpose(purpose, phase: phase), context.contextNonce == phase.identity.contextNonce,
                      let original = context.parentDeadline else {
                    return .application(.budget(.rejected))
                }
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                guard parent.identity == state.ticket.parentOperationTicketIdentity,
                      parent.freezeGeneration == expected.parentFreezeGeneration,
                      parent.runningSince != nil,
                      state.ticket.identity == expected.reactivationBudgetIdentity,
                      state.ticket.activationCutoffEffectiveElapsed == expected.activationCutoffEffectiveElapsed else {
                    return .application(.budget(.rejected))
                }
                let elapsed = try parent.effectiveElapsed(at: instant)
                var expired = elapsed >= expected.activationCutoffEffectiveElapsed
                var remaining = expired ? 0 : expected.activationCutoffEffectiveElapsed - elapsed
                if let stage = postConfigurationRouteState {
                    let used = try stage.checkedEffectiveElapsed(at: instant)
                    if used >= stage.budget.maximumEffectiveDuration { expired = true }
                    else { remaining = min(remaining, stage.budget.maximumEffectiveDuration - used) }
                    if let ordinary = stage.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute {
                        if instant >= ordinary.deadlineInstant { expired = true }
                        else { remaining = min(remaining, ordinary.deadlineInstant - instant) }
                    }
                } else if case .pending(let pending) = routeObservationState,
                          let deadline = pending.deadline {
                    if instant >= deadline.deadlineInstant { expired = true }
                    else { remaining = min(remaining, deadline.deadlineInstant - instant) }
                }
                if expired { return .terminate }
                return .application(.budget(.reactivationRearmed(try rearm(expected,
                    remainingNanoseconds: remaining))))

            case .playbackOperationTimer(let expected):
                guard incoming.failure == nil, let context = outputContext, !context.poisoned,
                      let original = context.parentDeadline else {
                    return .application(.budget(.rejected))
                }
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                guard parent.identity == expected.parentOperationTicketIdentity,
                      parent.freezeGeneration == expected.freezeGeneration,
                      parent.runningSince != nil else { return .application(.budget(.rejected)) }
                let elapsed = try parent.effectiveElapsed(at: instant)
                if elapsed >= parent.cap { return .terminate }
                return .application(.budget(.playbackOperationRearmed(try rearm(expected,
                    remainingNanoseconds: parent.cap - elapsed))))

            case .mediaProgress(let receipt):
                guard incoming.failure == nil, !incoming.userPaused, !incoming.interruptionVeto,
                      incoming.outputPermitPresent, incoming.readinessOpen,
                      incoming.routeObservationGateOpen,
                      case .installed(var context, let backend) = resourceState,
                      !context.poisoned, context.disposition != .releaseAfterTeardown,
                      context.sessionIdentity == receipt.sessionIdentity,
                      context.contextNonce == receipt.contextNonce,
                      context.mediaServicesEpoch == receipt.mediaServicesEpoch,
                      context.interruptionEpoch == receipt.interruptionEpoch,
                      context.audioAdmissionFenceRevision == receipt.audioAdmissionFenceRevision,
                      incoming.mediaServicesEpoch == receipt.mediaServicesEpoch,
                      incoming.interruptionEpoch == receipt.interruptionEpoch,
                      incoming.audioAdmissionFenceRevision == receipt.audioAdmissionFenceRevision,
                      context.interval == receipt.intervalKey,
                      context.activation == receipt.intervalKey.activation,
                      context.backendObjectNonce == receipt.intervalKey.backendObjectNonce,
                      backend.identity == receipt.intervalKey.backendIdentity,
                      backend.lifecycle == receipt.intervalKey.outputLifecycle,
                      let active = context.sessionReceipts?.active,
                      active.leaseID == backend.lease.leaseID,
                      active.interruptionEpoch == receipt.interruptionEpoch,
                      active.configurationGeneration == currentConfigurationGeneration,
                      stableRouteCommit == receipt.stableRouteCommit,
                      let currentRoute = currentRouteAuthority(),
                      receipt.stableRouteCommit.exactlyMatches(currentRoute,
                        observationGateOpen: incoming.routeObservationGateOpen),
                      authoritativeRoute.semantic != nil,
                      let original = context.parentDeadline else {
                    return .application(.budget(.rejected))
                }
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                let elapsed = try parent.effectiveElapsed(at: instant)
                guard elapsed < parent.cap else { return .terminate }
                context.parentDeadline = nil
                resourceState = .installed(context, backend)
                if audioPhase?.reactivationState?.ticket.parentOperationTicketIdentity == parent.identity {
                    audioPhase?.reactivationState = nil
                    audioPhase?.currentReactivationProof = nil
                }
                return .application(.budget(.progressCompleted))
            }
        }

        private func outputSuspendDeadline(_ ticket: OutputSuspendTicket,
            context: OutputResourceContext) throws -> UInt64 {
            let (deadline, overflow) = ticket.anchorInstant.addingReportingOverflow(1_000_000_000)
            guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
            return min(deadline, context.budget?.deadlineInstant ?? deadline)
        }

        private func prepareSuspendTimeout(_ context: inout OutputResourceContext,
            reservation: CleanupReservation, ticket: OutputSuspendTicket) throws -> PreparedCommand {
            let owner = try prepareTerminalCleanupOwner(reservation.ticket)
            let budget = try context.budget ?? CleanupBudgetTicket(
                predecessorIdentity: reservation.ticket.ownerGroup.resourceIdentity,
                anchorInstant: ticket.anchorInstant, nonce: reservation.ticket.nonce)
            // 所有可失败准备已经完成；以下只修改唯一锁内候选，尚未安装Authority。
            let ownerIdentity = owner.record == nil ? (context.owner?.identity ?? reservation.terminalOwner) : reservation.terminalOwner
            context.suspendTimedOut = true
            context.poisoned = true
            context.disposition = .releaseAfterTeardown
            context.relayClosing = true
            context.teardownRequested = true
            context.budget = budget
            context.owner = runningCleanupOwner(context.reservation) ?? .init(identity: ownerIdentity, reason: .terminal)
            return owner
        }

        private func installSuspendTimeout(_ context: OutputResourceContext, owner: PreparedCommand) {
            outputContext = context
            snapshot.output.revokeForSafety()
            installPreparedCommand(owner)
            terminateCleanupReservation()
        }

        private func suspendReceiptIsValid(_ receipt: OutputQuiescenceReceipt,
            context: OutputResourceContext) -> Bool {
            guard receipt.directlyConfirmedRateZero else { return false }
            if let interval = context.interval {
                guard let close = context.closeClaim, close == receipt.closeClaim, close.intervalKey == interval,
                      close.stopNonce == receipt.suspendTicket.task.nonce else { return false }
            } else if receipt.closeClaim != nil { return false }
            return commands.allSatisfy { record in
                guard let record,
                      record.groupTicket == context.reservation.workGroup ||
                        isDescendant(record.groupTicket, of: context.reservation.workGroup),
                      record.slot == .prepare || record.slot == .activation else { return true }
                guard case .terminal = record.phase else { return false }
                return mayDiscard(record)
            }
        }

        private func prepareAndApplyOutputSuspend(_ action: OutputSuspendControlAction,
            snapshot incoming: PlaybackSafetySnapshot, instant: UInt64) throws -> OutputControlApplication {
            switch action {
            case .timeout(let ticket):
                guard var context = outputContext, context.suspend == ticket, !context.suspendConfirmed,
                      !context.suspendRequiresRetirement,
                      let reservation = cleanupReservation else { return .rejected }
                if context.suspendTimedOut { return .suspend(.timedOut) }
                let deadline = try outputSuspendDeadline(ticket, context: context)
                guard instant >= deadline else {
                    return .suspend(.rearmed(remainingNanoseconds: deadline - instant,
                        notAfterInstant: deadline))
                }
                let owner = try prepareSuspendTimeout(&context, reservation: reservation, ticket: ticket)
                installSuspendTimeout(context, owner: owner)
                return .suspend(.timedOut)

            case .complete(let receipt):
                guard var context = outputContext, context.suspend == receipt.suspendTicket,
                      let index = commands.firstIndex(where: { $0?.controlTaskTicket == receipt.suspendTicket.task }),
                      commands[index]?.phase == .running || commands[index]?.phase == .cancelRequested else { return .rejected }
                var timeoutOwner: PreparedCommand?
                if !context.suspendTimedOut, incoming.failure == nil,
                   instant >= (try outputSuspendDeadline(receipt.suspendTicket, context: context)) {
                    guard let reservation = cleanupReservation else { return .rejected }
                    timeoutOwner = try prepareSuspendTimeout(&context, reservation: reservation, ticket: receipt.suspendTicket)
                }
                guard suspendReceiptIsValid(receipt, context: context) else {
                    if let timeoutOwner {
                        installSuspendTimeout(context, owner: timeoutOwner)
                        return .suspend(.timedOut)
                    }
                    return .rejected
                }
                commands[index]?.phase = .terminal(.completed)
                context.interval = nil
                context.activation = nil
                context.suspendConfirmed = true
                context.suspendPreparedPreserved = timeoutOwner == nil && incoming.failure == nil &&
                    !context.poisoned && receipt.preparedPreserved
                if let timeoutOwner { installSuspendTimeout(context, owner: timeoutOwner) }
                else { outputContext = context }
                return .suspend(.accepted, preservesRoute: context.owner?.reason == .pause &&
                    context.suspendPreparedPreserved && !context.suspendTimedOut && !context.poisoned)
            }
        }

        func currentRouteAuthority() -> PlaybackRouteAuthorityIdentity? {
            guard var context = outputContext else { return nil }
            return currentRouteAuthority(context: &context)
        }

        /// 只读借用同CAS已提交的准确context；不复制大值、不接受尚未安装的候选作为事实。
        func currentRouteAuthority(context: inout OutputResourceContext) -> PlaybackRouteAuthorityIdentity? {
            guard let relay = context.committedRelay,
                  let active = context.sessionReceipts?.active else { return nil }
            let revision: UInt64
            switch routeObservationState {
            case .pending(let pending): revision = pending.latestNotificationRevision
            case .open(let current): revision = current.routeObservationRevision
            case nil: revision = 0
            }
            return .init(sessionIdentity: context.sessionIdentity, monitorLifecycle: relay.relayIdentity.monitorLifecycle,
                mediaServicesEpoch: snapshot.mediaServicesEpoch, interruptionEpoch: snapshot.interruptionEpoch,
                audioSessionConfigurationGeneration: currentConfigurationGeneration, audioSessionActivationNonce: active.activationNonce,
                audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision, routeObservationRevision: revision,
                semanticIdentity: routeSemantic,
                configurationTransitionIdentity: postConfigurationRouteState?.budget.configurationTransitionIdentity,
                postConfigurationStageIdentity: postConfigurationRouteState?.budget.stageIdentity,
                systemOpenConfigurationGeneration: context.pendingReset == nil ? currentConfigurationGeneration : nil)
        }

        private func prepareAndCompleteRouteSample(_ claim: OutputRouteSampleClaim, result: OutputRouteSampleResult,
            rawEvidence: AudioSessionRouteSampleEvidence? = nil,
            snapshot incoming: PlaybackSafetySnapshot, allocator: PlaybackIdentityAllocator, instant: UInt64) throws -> OutputControlApplication {
            guard routeSampleClaim == claim,
                  let index = commands.firstIndex(where: { $0?.controlTaskTicket == claim.source }) else { return .rejected }
            if commands[index]?.phase == .cancelRequested {
                commands[index]?.phase = .terminal(.canceled)
                routeSampleClaim = nil
                if case .pending(var pending) = routeObservationState, pending.sampler == claim.source {
                    pending.sampleInFlight = false
                    pending.resamplePending = false
                    pending.sampler = nil
                    routeObservationState = .pending(pending)
                }
                return .routeSampleSettled(followUp: nil)
            }
            guard incoming.failure == nil, case .pending(var pending) = routeObservationState,
                  pending.ticket == claim.observation, pending.sampler == claim.source, pending.sampleInFlight,
                  commands[index]?.phase == .running, var context = outputContext,
                  cleanupReservation?.ticket == context.reservation,
                  !context.poisoned, context.disposition != .releaseAfterTeardown else { return .rejected }
            // 一次SDK返回必结束准确原record；其后任一checked准备失败也不能留下running/cancelRequested死等。
            var returnedSampleNeedsTerminal = true
            defer {
                if returnedSampleNeedsTerminal {
                    finishReturnedRouteSample(claim, index: index, pending: &pending)
                }
            }
            let boundary: OutputRouteAvailabilityBoundary
            if let deadline = pending.deadline, claim.observation.configurationTransitionIdentity == nil {
                boundary = .ordinary(deadline)
                guard instant < deadline.deadlineInstant else {
                    let application = try terminateRouteSample(&context, index: index, instant: instant)
                    returnedSampleNeedsTerminal = false
                    return application
                }
            } else {
                guard let stage = postConfigurationRouteState,
                      claim.observation.configurationTransitionIdentity == stage.budget.configurationTransitionIdentity else {
                    return .rejected
                }
                guard let elapsed = stage.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
                guard elapsed < stage.budget.maximumEffectiveDuration,
                      stage.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute.map({ instant < $0.deadlineInstant }) ?? true
                else {
                    let application = try terminateRouteSample(&context, index: index, instant: instant)
                    returnedSampleNeedsTerminal = false
                    return application
                }
                boundary = .postConfiguration(stage.budget.configurationTransitionIdentity,
                    stageIdentity: stage.budget.stageIdentity)
            }
            var parentElapsed: UInt64?
            if let original = context.parentDeadline {
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                guard let elapsed = parentEffectiveElapsed(parent, at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
                guard elapsed < parent.cap else {
                    let application = try terminateRouteSample(&context, index: index, instant: instant)
                    returnedSampleNeedsTerminal = false
                    return application
                }
                parentElapsed = elapsed
            }
            guard currentRouteAuthority(context: &context) == claim.authority, !pending.resamplePending else {
                // 旧getter只结束自己的单次request；先准备新票，再原子替换同一固定slot。
                let replacement = try prepareRouteSamplerReplacement(pending: pending,
                    sourceIndex: index, returnedInFlight: true, allocator: allocator)
                pending.sampleInFlight = false
                pending.resamplePending = true
                pending.sampler = replacement.ticket
                routeObservationState = .pending(pending)
                routeSampleClaim = nil
                commands[index]?.phase = .terminal(.completed)
                commands[index]?.resultClaimed = true
                installPreparedCommand(replacement)
                returnedSampleNeedsTerminal = false
                return .routeSampleSettled(followUp: replacement.ticket)
            }
            var normalized = result
            var fingerprint = lastEndpointFingerprint
            var configuration = outputConfigurationIncarnation
            if let rawEvidence {
                if configuration == nil || pending.outputConfigurationChanged {
                    configuration = .init(rawValue: try allocator.next(in: .nonce))
                }
                switch rawEvidence {
                case .invalid: throw PlaybackSafetyFailure.invalidEvidence
                case .none:
                    normalized = .none
                    fingerprint = nil
                case .available(let ports, let evidence):
                    guard !ports.isEmpty, ports.rawValue & ~UInt8(31) == 0,
                          let backend = try PlaybackBackendSelection.select(ports: ports, actualPolicy: .longFormAudio)
                    else { throw PlaybackSafetyFailure.invalidEvidence }
                    let token: EndpointTopologyToken
                    if evidence == lastEndpointFingerprint, !pending.topologyChangeHint, let previous = routeSemantic {
                        token = previous.endpointTopologyToken
                    } else { token = .init(rawValue: try allocator.next(in: .nonce)) }
                    fingerprint = evidence
                    normalized = .available(.init(ports: ports,
                        backend: backend,
                        outputConfigurationIncarnation: configuration!, endpointTopologyToken: token))
                }
            }
            let fact: OutputAuthoritativeRoute
            switch normalized {
            case .none: fact = .none
            case .available(let semantic):
                guard !semantic.ports.isEmpty, semantic.ports.rawValue & ~UInt8(31) == 0,
                      try PlaybackBackendSelection.select(ports: semantic.ports,
                        actualPolicy: .longFormAudio) == semantic.backend else {
                    finishReturnedRouteSample(claim, index: index, pending: &pending, keepIdleSampler: true)
                    returnedSampleNeedsTerminal = false
                    return .rejected
                }
                fact = .available(semantic)
            }
            let closesGateForAirPlayPolicy: Bool
            if fact.semantic?.backend == .hlsAVPlayer {
                guard let receipt = processConfigurationReceipt,
                      context.sessionReceipts?.process == receipt,
                      receipt.identity.mediaServicesEpoch == incoming.mediaServicesEpoch,
                      receipt.identity.configurationGeneration == currentConfigurationGeneration else {
                    finishReturnedRouteSample(claim, index: index, pending: &pending, keepIdleSampler: true)
                    returnedSampleNeedsTerminal = false
                    return .rejected
                }
                closesGateForAirPlayPolicy = receipt.actualPolicy == .default
            } else { closesGateForAirPlayPolicy = false }
            var next = incoming
            var state = audioPhase?.reactivationState
            if let original = context.parentDeadline, let elapsed = parentElapsed {
                var parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                let hadNone = authoritativeRoute == .none
                let hasNone = fact == .none
                if hadNone != hasNone {
                    if hasNone { state?.freezeCauses.insert(.routeUnavailable) }
                    else { state?.freezeCauses.remove(.routeUnavailable) }
                    state?.cutoffArmTicket = nil
                }
                let shouldRun = fact.semantic != nil && !incoming.userPaused && !incoming.interruptionVeto &&
                    context.sessionReceipts?.active != nil && state?.freezeCauses.activationBlocked != true
                if hadNone != hasNone || shouldRun != (parent.runningSince != nil) {
                    next.freezeGeneration = try allocator.next(in: .freezeGeneration)
                    parent.accumulatedEffectiveTime = elapsed
                    parent.freezeGeneration = next.freezeGeneration
                    parent.runningSince = shouldRun ? instant : nil
                    switch original { case .coldStart: context.parentDeadline = .coldStart(parent)
                    case .outputRecovery: context.parentDeadline = .outputRecovery(parent) }
                }
            }
            if authoritativeRoute != fact {
                next.audioAdmissionFenceRevision = try allocator.next(in: .admissionFence)
            }
            let replacement = fact == .none ? try prepareRouteSamplerReplacement(pending: pending,
                sourceIndex: index, returnedInFlight: true, allocator: allocator) : nil
            pending.sampleInFlight = false
            pending.resamplePending = fact == .none
            if rawEvidence != nil {
                pending.topologyChangeHint = false
                pending.outputConfigurationChanged = false
            }
            // 所有checked时钟及身份准备已成功；route原因不改post stage的runningSince或累计。
            outputContext = context
            audioPhase?.reactivationState = state
            authoritativeRoute = fact
            if rawEvidence != nil {
                lastEndpointFingerprint = fingerprint
                outputConfigurationIncarnation = configuration
            }
            // 通知hint只会park；只有本次typed getter发布的真实semantic变化才能撤销旧推测工作。
            for commandIndex in commands.indices where commands[commandIndex]?.gatePolicy == .routeSpeculativeRateZero {
                guard let record = commands[commandIndex], !matches(record.safetySnapshot) else { continue }
                cancel(commandIndex)
            }
            routeObservationState = .pending(pending)
            routeSampleClaim = nil
            snapshot = next
            let hasSemantic = fact.semantic != nil
            let gateOpen = hasSemantic && !closesGateForAirPlayPolicy
            snapshot.output.routeObservationGateOpen = gateOpen
            commands[index]?.phase = .terminal(.completed)
            commands[index]?.resultClaimed = true
            if hasSemantic {
                let anchor = routeStabilityCandidate.flatMap {
                    $0.authority.semanticIdentity == fact.semantic ? $0.firstMatchingSampleInstant : nil
                } ?? instant
                routeStabilityCandidate = .init(source: claim.source, observation: claim.observation,
                    // 上方outputContext已安装同一context，再从已提交值投影最终authority。
                    authority: currentRouteAuthority(context: &context)!, firstMatchingSampleInstant: anchor, boundary: boundary, arm: nil)
            } else {
                routeStabilityCandidate = nil
                stableRouteCommit = nil
                pending.sampler = replacement!.ticket
                routeObservationState = .pending(pending)
                installPreparedCommand(replacement!)
            }
            returnedSampleNeedsTerminal = false
            return .routeSampled(freezeGeneration: next.freezeGeneration,
                audioAdmissionFenceRevision: next.audioAdmissionFenceRevision, gateOpen: gateOpen,
                followUp: replacement?.ticket)
        }

        private func terminateRouteSample(_ context: inout OutputResourceContext, index: Int, instant: UInt64) throws -> OutputControlApplication {
            let result = try terminateUserControl(&context, instant: instant)
            // 原getter已经返回；终态owner全准备成功以后才结束原单飞责任。
            commands[index]?.phase = .terminal(.canceled)
            routeSampleClaim = nil
            routeStabilityCandidate = nil
            stableRouteCommit = nil
            if case .pending(var pending) = routeObservationState,
               pending.sampler == commands[index]?.controlTaskTicket {
                pending.sampleInFlight = false
                pending.resamplePending = false
                pending.sampler = nil
                routeObservationState = .pending(pending)
            }
            return result
        }

        private func finishReturnedRouteSample(_ claim: OutputRouteSampleClaim, index: Int,
            pending: inout PendingRouteObservation, keepIdleSampler: Bool = false) {
            commands[index]?.phase = .terminal(.canceled)
            commands[index]?.resultInvalidated = true
            routeSampleClaim = nil
            guard pending.sampler == claim.source else { return }
            pending.sampleInFlight = false
            pending.resamplePending = false
            if !keepIdleSampler { pending.sampler = nil }
            routeObservationState = .pending(pending)
        }

        private func prepareAndSettleInterruptionDrain(owner: OutputTransitionOwnerTicket, snapshot incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64) throws -> OutputControlApplication {
            guard var context = outputContext, context.owner == owner, context.pendingReset == nil,
                  !context.poisoned, context.disposition != .releaseAfterTeardown,
                  owner.reason != .stop, owner.reason != .terminal else { return .rejected }
            if let proof = context.interruptionProof, !context.interruptionDrainRequired,
               registeredDrainProof == .interruption(proof) {
                return .interruptionSettled(proof: proof, followUp: nil,
                    clearsInterruptionVeto: false)
            }
            guard isTerminal(context.reservation.workGroup), context.interval == nil,
                  context.pendingActivationCall == nil,
                  commands.allSatisfy({ record in
                      guard let record, record.groupTicket == context.reservation.workGroup ||
                          isDescendant(record.groupTicket, of: context.reservation.workGroup) else { return true }
                      guard case .terminal = record.phase else { return false }
                      return mayDiscard(record)
                  }) else { return .rejected }
            guard context.interruptionDrainRequired, context.interruptionProof == nil else { return .rejected }
            let shape: InterruptionDrainedResourceShape
            switch resourceState {
            case .quiescentBackend(_, let backend):
                guard context.retirementConfirmed, context.retiredLifecycle != nil, backend.lifecycle == nil,
                      let monitor = backend.lease.monitor else { return .rejected }
                shape = .quiescentBackend(backend.identity, .init(sessionIdentity: context.sessionIdentity,
                    leaseID: backend.lease.leaseID, monitorLifecycle: monitor.lifecycle, contextNonce: context.contextNonce))
            case .pendingSuccessorLease(_, let lease):
                guard let monitor = lease.monitor else { return .rejected }
                shape = .retainedSuccessor(.init(sessionIdentity: context.sessionIdentity, leaseID: lease.leaseID,
                    monitorLifecycle: monitor.lifecycle, contextNonce: context.contextNonce))
            case .leaseOnlyCleanup(_, .runner(let ticket)), .routeMonitorCleanup(_, .runner(let ticket)):
                guard context.monitorStopped,
                      commands.contains(where: { $0?.controlTaskTicket == ticket && $0?.phase == .terminal(.completed) }) else { return .rejected }
                shape = .noResources
            case .acquiringWithoutLease:
                guard context.acquisitionNoLeaseReceipt?.acquisitionTicket.group == context.reservation.workGroup else { return .rejected }
                shape = .noResources
            default: return .rejected
            }
            let proof = InterruptionDrainProof(sessionIdentity: context.sessionIdentity, configuredGeneration: currentConfigurationGeneration,
                interruptionEpoch: incoming.interruptionEpoch, contextNonce: context.contextNonce,
                retiredOutputLifecycleEpoch: context.retiredLifecycle, resultingResourceShape: shape,
                proofNonce: try allocator.next(in: .nonce))
            context.interruptionProof = proof
            context.interruptionDrainRequired = false
            var recoverySnapshot = incoming
            let consumesPendingResume = context.userResumeRequested && incoming.interruptionState != .began
            if consumesPendingResume { recoverySnapshot.interruptionVeto = false }
            var command: PreparedCommand?
            var cycle: PreparedOutputCycle?
            if var phase = audioPhase, case .pending(var pending) = routeObservationState {
                var stage = postConfigurationRouteState
                phase.currentReactivationProof = .interruption(proof)
                switch try prepareReactivation(context: &context, phase: &phase, stage: &stage, pending: &pending,
                    command: &command, cycle: &cycle, snapshot: recoverySnapshot, contextNonce: context.contextNonce,
                    mandatorySuffix: phase.reactivationState?.ticket.mandatorySuffix ?? context.resetRecoveryMandatorySuffix,
                    instant: instant, newlyPreparedInterruptionProof: proof, allocator: allocator) {
                case .waiting: break
                case .expired:
                    // 尚未登记的proof候选不能随业务terminal混入真实图。
                    context.interruptionProof = nil
                    context.interruptionDrainRequired = true
                    return try terminateUserControl(&context, instant: instant)
                case .ready:
                    if let cycle { installOutputCycleLocked(cycle, context: &context) }
                    context.userResumeRequested = false
                    postConfigurationRouteState = stage
                    routeObservationState = .pending(pending)
                    installPreparedCommand(command!)
                }
                audioPhase = phase
            }
            // proof与本次后继的全部准备结束，至此才一次登记到唯一Authority。
            outputContext = context
            registeredDrainProof = .interruption(proof)
            if command != nil, consumesPendingResume { snapshot = recoverySnapshot }
            return .interruptionSettled(proof: proof, followUp: command?.ticket,
                clearsInterruptionVeto: command != nil && consumesPendingResume)
        }

        private func prepareAndRetireOutputRecord(_ ticket: ControlTaskTicket, snapshot incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64) throws -> OutputControlApplication {
            guard let index = commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  belongsToCurrentOutputGraph(ticket),
                  case .terminal = commands[index]?.phase,
                  commands[index].map({ mayDiscard($0) }) == true else { return .rejected }
            if incoming.failure != nil {
                commands[index] = nil
                return .retired(followUp: nil, clearsInterruptionVeto: false)
            }
            var command: PreparedCommand?
            var cycle: PreparedOutputCycle?
            if var context = outputContext, var phase = audioPhase,
               case .pending(var pending) = routeObservationState {
                var stage = postConfigurationRouteState
                var recoverySnapshot = incoming
                let consumesPendingResume = context.userResumeRequested && incoming.interruptionState != .began
                if consumesPendingResume { recoverySnapshot.interruptionVeto = false }
                switch try prepareReactivation(context: &context, phase: &phase, stage: &stage, pending: &pending,
                    command: &command, cycle: &cycle, snapshot: recoverySnapshot, contextNonce: context.contextNonce,
                    mandatorySuffix: phase.reactivationState?.ticket.mandatorySuffix ?? context.resetRecoveryMandatorySuffix,
                    instant: instant, replacingRetiredCommandIndex: index, allocator: allocator) {
                case .waiting: break
                case .expired:
                    let terminal = try terminateUserControl(&context, instant: instant)
                    commands[index] = nil
                    return terminal
                case .ready:
                    // 原terminal记录在全部后继准备成功之前一直占着原槽。
                    commands[index] = nil
                    if let cycle { installOutputCycleLocked(cycle, context: &context) }
                    context.userResumeRequested = false
                    outputContext = context
                    audioPhase = phase
                    postConfigurationRouteState = stage
                    routeObservationState = .pending(pending)
                    if consumesPendingResume { snapshot = recoverySnapshot }
                    return .retired(followUp: installPreparedCommand(command!),
                        clearsInterruptionVeto: consumesPendingResume)
                }
            }
            commands[index] = nil
            return .retired(followUp: nil, clearsInterruptionVeto: false)

        }

        func applyUserControl(_ request: OutputUserControlRequest, snapshot incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64) -> OutputControlApplication {
            precondition(!resourceTransactionActive, "用户控制不能重入资源CAS")
            guard var context = outputContext, var phase = audioPhase,
                  context.phase == .pendingSuccessorLease || context.phase == .quiescentBackend ||
                    context.phase == .installed || context.phase == .pendingLeaseAcquisition,
                  !context.poisoned, context.disposition != .releaseAfterTeardown,
                  context.owner?.reason != .stop, context.owner?.reason != .terminal,
                  request.sessionIdentity == context.sessionIdentity, request.expectedOwner == context.owner,
                  request.contextNonce == context.contextNonce, request.interruptionEpoch == incoming.interruptionEpoch,
                  request.mediaServicesEpoch == incoming.mediaServicesEpoch,
                  request.resetPreRouteBinding == context.resetPreRouteBinding else { return .rejected }
            // 无proof的resume只记录用户意图；只有准确lease或当前排空proof可以清除物理veto。
            var resumeAuthorizesRecovery = !incoming.interruptionVeto
            if let requestedLease = request.explicitResumeLease {
                guard request.kind == .resume, case .ended = incoming.interruptionState,
                      let lease = ownedLeaseResources, requestedLease.id == lease.leaseID,
                      requestedLease.generation == lease.leaseID,
                      let registration = lease.object as? PlaybackAudioSessionRegistration,
                      ownsRegistration(registration, allowsClosing: false),
                      context.pendingActivationCall == nil, context.sessionReceipts?.active == nil
                else { return .rejected }
                if case .acquiringLease(_, .awaitingActivation(let configured)) = resourceState {
                    // 尚未创建输出的acquisition已有自己的真实所有权证明，不借旧输出drain proof。
                    let proof = configured.acquired.proof
                    guard context.pendingReset == nil, context.resetAcquisitionBinding == nil,
                          context.interval == nil, audioSessionPermit == nil,
                          phase.acquisitionOwnershipProof == proof,
                          proof.acquisitionTicket == registration.identity.acquisition,
                          proof.sessionIdentity == context.sessionIdentity, proof.contextNonce == context.contextNonce,
                          proof.leaseID == lease.leaseID, configured.acquired.lease.object === registration,
                          phase.identity.sessionIdentity == context.sessionIdentity,
                          phase.identity.contextNonce == context.contextNonce, phase.identity.leaseID == lease.leaseID,
                          phase.identity.mediaServicesEpoch == incoming.mediaServicesEpoch,
                          phase.processReceipt == configured.processReceipt,
                          phase.configuredReceipt == configured.configuredReceipt,
                          configured.processReceipt.identity.mediaServicesEpoch == incoming.mediaServicesEpoch,
                          case .confirmedInactive = configured.acquired.lease.deactivation,
                          commands.allSatisfy({ record in
                              guard let record, record.groupTicket == context.reservation.workGroup else { return true }
                              guard case .terminal = record.phase else { return false }
                              return mayDiscard(record)
                          }) else { return .rejected }
                } else if let binding = context.systemRecoveryBinding {
                    guard context.pendingReset == binding.incarnation.identity.root,
                          binding.incarnation.identity.root.mediaServicesEpoch == incoming.mediaServicesEpoch,
                          registeredDrainProof == .reset(binding.resetDrainProof),
                          binding.inactiveConfigurationReceipt != nil,
                          !context.interruptionDrainRequired else { return .rejected }
                } else {
                    guard let proof = context.interruptionProof,
                          registeredDrainProof == .interruption(proof), !context.interruptionDrainRequired,
                          proof.sessionIdentity == context.sessionIdentity, proof.contextNonce == context.contextNonce,
                          proof.configuredGeneration == currentConfigurationGeneration else { return .rejected }
                }
                resumeAuthorizesRecovery = true
            } else if request.kind == .resume, incoming.interruptionVeto,
                      incoming.interruptionState != .began {
                if let post = postConfigurationRouteState,
                   let proof = registeredPostConfigurationProof,
                   let binding = context.systemRecoveryBinding,
                   proof.incarnationIdentity == binding.incarnation.identity,
                   context.pendingReset == binding.incarnation.identity.root,
                   proof.resetDrainProofIdentity == binding.resetDrainProof.identity,
                   proof.postConfigurationStageIdentity == post.budget.stageIdentity,
                   proof.retainedContextNonce == context.contextNonce,
                   proof.leaseID == ownedLeaseResources?.leaseID,
                   proof.committedGeneration == currentConfigurationGeneration,
                   binding.incarnation.identity.root.mediaServicesEpoch == incoming.mediaServicesEpoch {
                    resumeAuthorizesRecovery = true
                } else if let proof = context.interruptionProof,
                          registeredDrainProof == .interruption(proof), !context.interruptionDrainRequired,
                          proof.sessionIdentity == context.sessionIdentity,
                          proof.contextNonce == context.contextNonce,
                          proof.configuredGeneration == currentConfigurationGeneration {
                    resumeAuthorizesRecovery = true
                }
            }
            var next = incoming
            next.userPaused = request.kind == .pause
            if request.kind == .resume, incoming.interruptionState != .began, resumeAuthorizesRecovery {
                next.interruptionVeto = false
            }
            let changed = next.userPaused != incoming.userPaused || next.interruptionVeto != incoming.interruptionVeto
            do {
                var preRoute = resetPreRouteState
                var post = postConfigurationRouteState
                if changed {
                    next.freezeGeneration = try allocator.next(in: .freezeGeneration)
                    if request.kind == .resume, context.parentDeadline == nil {
                        context.parentDeadline = try prepareRecoveryParent(context: context,
                            snapshot: next, originInstant: instant, resetPreRoute: false,
                            allocator: allocator)
                    }
                    if let original = context.parentDeadline {
                        var parent: PlaybackProgressBudgetTicket
                        switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
                        if var state = preRoute {
                            guard let elapsed = state.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
                            guard elapsed < state.boundaryEffectiveElapsed else { return try terminateUserControl(&context, instant: instant) }
                            state.accumulatedEffectiveTime = elapsed
                            state.runningSince = next.userPaused || next.interruptionState == .began ? nil : instant
                            state.freezeGeneration = next.freezeGeneration
                            state.deadlineArm = state.runningSince == nil ? nil : .init(ticketIdentity: state.ticketIdentity,
                                boundaryEffectiveElapsed: state.boundaryEffectiveElapsed, freezeGeneration: state.freezeGeneration,
                                armNonce: try allocator.next(in: .deadline))
                            parent.accumulatedEffectiveTime = elapsed
                            parent.runningSince = state.runningSince
                            preRoute = state
                        } else {
                            if let running = parent.runningSince {
                                guard instant >= running else { throw PlaybackSafetyFailure.clockOverflow }
                                let (elapsed, overflow) = parent.accumulatedEffectiveTime.addingReportingOverflow(instant - running)
                                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                                parent.accumulatedEffectiveTime = elapsed
                            }
                            guard parent.accumulatedEffectiveTime < parent.cap else {
                                return try terminateUserControl(&context, instant: instant)
                            }
                            parent.runningSince = !next.userPaused && !next.interruptionVeto &&
                                context.sessionReceipts?.active != nil && authoritativeRoute.semantic != nil ? instant : nil
                        }
                        parent.freezeGeneration = next.freezeGeneration
                        if var state = post {
                            guard let elapsed = state.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
                            guard elapsed < state.budget.maximumEffectiveDuration else {
                                return try terminateUserControl(&context, instant: instant)
                            }
                            state.budget.accumulatedEffectiveTime = elapsed
                            state.runningSince = next.userPaused || next.interruptionState == .began ||
                                context.sessionReceipts?.active == nil ? nil : instant
                            state.freezeGeneration = next.freezeGeneration
                            post = state
                        }
                        switch original { case .coldStart: context.parentDeadline = .coldStart(parent)
                        case .outputRecovery: context.parentDeadline = .outputRecovery(parent) }
                    }
                    if next.userPaused { phase.reactivationState?.freezeCauses.insert(.userPause) }
                    else { phase.reactivationState?.freezeCauses.remove(.userPause) }
                    phase.reactivationState?.cutoffArmTicket = nil
                }
                var preparation = ReactivationPreparation.waiting
                var preparedCommand: PreparedCommand?
                var preparedCycle: PreparedOutputCycle?
                if request.kind == .resume, request.explicitResumeLease != nil,
                   case .acquiringLease(_, .awaitingActivation(let configured)) = resourceState {
                    guard phase.acquisitionOwnershipProof == configured.acquired.proof,
                          phase.processReceipt == configured.processReceipt,
                          context.pendingActivationCall == nil, !next.interruptionVeto else { return .rejected }
                    phase.policy = .activate(purpose: .activateAcquiredConfiguredGeneration(
                        sessionIdentity: context.sessionIdentity,
                        committedGeneration: configured.processReceipt.identity.configurationGeneration,
                        acquisitionOwnershipProof: configured.acquired.proof), interruptionEpoch: next.interruptionEpoch,
                        audioAdmissionFenceRevision: next.audioAdmissionFenceRevision,
                        invocationIdentity: try AudioSessionActivationInvocationIdentity(allocator: allocator))
                    preparedCommand = try prepareCommand(group: context.reservation.workGroup,
                        slot: .audioSessionRecovery, policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy,
                        allocator: allocator)
                    preparation = .ready
                } else if request.kind == .resume, !next.interruptionVeto,
                          case .pending(var pending) = routeObservationState {
                    preparation = try prepareReactivation(context: &context, phase: &phase, stage: &post, pending: &pending,
                        command: &preparedCommand, cycle: &preparedCycle,
                        snapshot: next, contextNonce: context.contextNonce,
                        mandatorySuffix: phase.reactivationState?.ticket.mandatorySuffix ?? context.resetRecoveryMandatorySuffix,
                        instant: instant, allocator: allocator)
                    switch preparation {
                    case .expired: return try terminateUserControl(&context, instant: instant)
                    case .ready:
                        // 全部checked准备已经结束；从这里开始只安装固定候选。
                        routeObservationState = .pending(pending)
                    case .waiting: break
                    }
                }
                if request.kind == .pause { next.output.revokeForUserPause() }
                // 所有checked准备完成；以下只有唯一Authority及Cell随后同锁安装的固定值。
                let result: OutputUserControlResult
                if case .ready = preparation {
                    if let preparedCycle { installOutputCycleLocked(preparedCycle, context: &context) }
                    context.userResumeRequested = false
                    result = .acceptedAndPrepared(installPreparedCommand(preparedCommand!))
                } else {
                    context.userResumeRequested = request.kind == .resume && incoming.interruptionVeto &&
                        !resumeAuthorizesRecovery
                    result = .acceptedWaiting
                }
                outputContext = context
                resetPreRouteState = preRoute
                postConfigurationRouteState = post
                snapshot = next
                audioPhase = phase
                if next.userPaused {
                    for index in commands.indices {
                        if case .activate = commands[index]?.audioPolicy { cancel(index) }
                    }
                }
                return .applied(.init(userPaused: next.userPaused, interruptionVeto: next.interruptionVeto,
                    freezeGeneration: next.freezeGeneration), result)
            } catch let failure as PlaybackSafetyFailure { return .failed(failure) }
            catch PlaybackIdentityAllocationError.identitySpaceExhausted { return .failed(.identitySpaceExhausted) }
            catch { return .failed(.invalidEvidence) }
        }

        private func terminateUserControl(_ context: inout OutputResourceContext, instant: UInt64) throws -> OutputControlApplication {
            let budget = try context.budget ?? CleanupBudgetTicket(
                predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                anchorInstant: instant, nonce: context.reservation.nonce)
            let command = try prepareTerminalCleanupOwner(context.reservation)
            // 截止点胜过用户意图；仅安装原预留的终态，不发布候选pause/freeze。
            context.budget = budget
            context.owner = runningCleanupOwner(context.reservation) ?? .init(identity: cleanupReservation!.terminalOwner, reason: .terminal)
            context.poisoned = true
            context.disposition = .releaseAfterTeardown
            context.relayClosing = true
            context.teardownRequested = true
            outputContext = context
            audioPhase?.reactivationState?.cutoffArmTicket = nil
            audioPhase?.permitsFurtherCalls = false
            snapshot.output.revokeForSafety()
            installPreparedCommand(command)
            terminateCleanupReservation()
            return .terminated
        }

        /// 所有可失败首票准备均先于普通折叠；失败由cell调用非失败终态hook。
        func apply(_ incoming: PlaybackSafetySnapshot, allocator: PlaybackIdentityAllocator,
            instant: UInt64) -> PlaybackSafetyIngressApplication {
            do {
                let routeResample = try preparePendingRouteResample(incoming, allocator: allocator)
                let parent = try prepareInterruptionParent(incoming, allocator: allocator)
                let post = try preparePostConfigurationInterruption(incoming)
                let route = try prepareOpenRouteObservation(incoming, allocator: allocator)
                let prepared = try prepareResetIngress(incoming, allocator: allocator, instant: instant, settledParent: parent, settledPost: post)
                fold(incoming)
                if let parent { outputContext?.parentDeadline = parent }
                if let post { postConfigurationRouteState = post }
                if let route {
                    outputContext?.parentDeadline = route.parent
                    routeObservationState = .pending(route.pending)
                    stableRouteCommit = nil
                    routeStabilityCandidate = nil
                    routeSampleClaim = nil
                    installPreparedCommand(route.sampler)
                }
                if let routeResample, case .pending(var pending) = routeObservationState {
                    pending.sampler = routeResample.ticket
                    pending.sampleInFlight = false
                    pending.resamplePending = true
                    routeObservationState = .pending(pending)
                    installPreparedCommand(routeResample)
                }
                if let prepared {
                    outputContext?.parentDeadline = prepared.parent
                    if incoming.system.latestResetIngress != nil {
                        outputContext?.resetResourceBinding = .draining(.init(preRouteBinding: prepared.binding,
                            inheritedRouteAvailabilityConstraint: prepared.inherited))
                        if case .pending(var pending) = routeObservationState {
                            if let source = pending.sampler,
                               let index = commands.firstIndex(where: { $0?.controlTaskTicket == source }) { cancel(index) }
                            pending.ordinaryDeadlineState = nil
                            pending.ticket = nil
                            pending.sampler = nil
                            pending.sampleInFlight = false
                            routeObservationState = .pending(pending)
                        }
                        postConfigurationRouteState = nil
                        registeredPostConfigurationProof = nil
                    }
                    resetPreRouteState = prepared.state
                    if let terminal = prepared.terminal {
                        outputContext?.budget = terminal.budget
                        outputContext?.owner = .init(identity: cleanupReservation!.terminalOwner, reason: .terminal)
                        outputContext?.poisoned = true
                        outputContext?.disposition = .releaseAfterTeardown
                        outputContext?.relayClosing = true
                        outputContext?.teardownRequested = true
                        installPreparedCommand(terminal.command)
                        terminateCleanupReservation()
                    }
                }
                return .applied
            } catch let failure as PlaybackSafetyFailure {
                return .failed(failure)
            } catch PlaybackIdentityAllocationError.identitySpaceExhausted {
                return .failed(.identitySpaceExhausted)
            } catch {
                return .failed(.invalidEvidence)
            }
        }

        struct PreparedResetIngress {
            let parent: CurrentPlaybackOperationDeadlineTicket
            let state: ResetPreRouteRecoveryDeadlineState
            let binding: ResetPreRouteTicketBinding
            let inherited: InheritedRouteAvailabilityConstraint?
            let terminal: PreparedResetTerminal?
        }
        struct PreparedResetTerminal {
            let budget: CleanupBudgetTicket
            let command: PreparedCommand
        }

        struct PreparedOpenRouteObservation {
            let parent: CurrentPlaybackOperationDeadlineTicket
            let pending: PendingRouteObservation
            let sampler: PreparedCommand
        }

        private func prepareRouteSamplerReplacement(pending: PendingRouteObservation, sourceIndex: Int,
            returnedInFlight: Bool, allocator: PlaybackIdentityAllocator) throws -> PreparedCommand {
            guard let source = pending.sampler, pending.ticket != nil,
                  commands[sourceIndex]?.controlTaskTicket == source,
                  commands[sourceIndex]?.slot == .sampler,
                  commands[sourceIndex]?.gatePolicy == .safetyBypass,
                  groups.contains(where: { $0?.ticket == source.group && $0?.sealed == false }),
                  cleanupReservation?.ticket.workGroup == source.group,
                  !commands.indices.contains(where: { $0 != sourceIndex &&
                      commands[$0]?.resourceIdentity == source.group.resourceIdentity && commands[$0]?.slot == .sampler })
            else { throw Failure.invalidGroup }
            if returnedInFlight {
                // SDK已返回但尚未发布：用准确原字段预验terminal后可丢弃，不先改原record。
                guard pending.sampleInFlight, routeSampleClaim?.source == source,
                      commands[sourceIndex]?.phase == .running,
                      commands[sourceIndex]?.ownedResult == nil, commands[sourceIndex]?.factoryResult == nil,
                      commands[sourceIndex]?.audioPolicy == nil, commands[sourceIndex]?.deactivationRequest == nil
                else { throw Failure.invalidGroup }
            } else {
                guard !pending.sampleInFlight, routeSampleClaim?.source != source,
                      case .terminal = commands[sourceIndex]?.phase,
                      commands[sourceIndex]?.ownedResult == nil, commands[sourceIndex]?.factoryResult == nil,
                      commands[sourceIndex]?.audioPolicy == nil, commands[sourceIndex]?.deactivationRequest == nil
                else { throw Failure.invalidGroup }
            }
            let ticket = ControlTaskTicket(group: source.group, nonce: try allocator.next(in: .controlTask))
            let record = try OwnedPostIngressControlCommand(controlTaskTicket: ticket,
                slot: .sampler, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
            return .init(index: sourceIndex, ticket: ticket, record: record, reservedStage: nil)
        }

        private func preparePendingRouteResample(_ incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator) throws -> PreparedCommand? {
            guard incoming.failure == nil, incoming.throughRevision != snapshot.throughRevision,
                  incoming.mediaServicesEpoch == snapshot.mediaServicesEpoch,
                  incoming.interruptionEpoch == snapshot.interruptionEpoch,
                  incoming.interruptionVeto == snapshot.interruptionVeto,
                  let route = incoming.route, case .pending(let pending) = routeObservationState,
                  route.notificationRevision > pending.latestNotificationRevision,
                  let source = pending.sampler,
                  route.sessionIdentity == (pending.ticket?.sessionIdentity ?? pending.latestObservation?.sessionIdentity),
                  route.monitorLifecycle == (pending.ticket?.monitorLifecycle ?? pending.latestObservation?.monitorLifecycle),
                  let index = commands.firstIndex(where: { $0?.controlTaskTicket == source }),
                  !pending.sampleInFlight, routeSampleClaim?.source != source,
                  case .terminal = commands[index]?.phase,
                  commands[index]?.ownedResult == nil, commands[index]?.factoryResult == nil,
                  commands[index]?.audioPolicy == nil, commands[index]?.deactivationRequest == nil,
                  currentRouteAuthority() != nil else { return nil }
            return try prepareRouteSamplerReplacement(pending: pending,
                sourceIndex: index, returnedInFlight: false, allocator: allocator)
        }

        private func prepareOpenRouteObservation(_ incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator) throws -> PreparedOpenRouteObservation? {
            guard incoming.failure == nil, incoming.throughRevision != snapshot.throughRevision,
                  let route = incoming.route, let firstInstant = incoming.firstRouteEventObservedInstant,
                  case .open(let open) = routeObservationState,
                  open == currentRouteAuthority(), route.notificationRevision > open.routeObservationRevision,
                  let context = outputContext, context.disposition != .releaseAfterTeardown, !context.poisoned,
                  cleanupReservation?.ticket == context.reservation,
                  route.sessionIdentity == open.sessionIdentity, route.monitorLifecycle == open.monitorLifecycle,
                  incoming.mediaServicesEpoch == open.mediaServicesEpoch,
                  incoming.interruptionEpoch == open.interruptionEpoch,
                  incoming.audioAdmissionFenceRevision == open.audioAdmissionFenceRevision,
                  context.sessionReceipts?.active?.activationNonce == open.audioSessionActivationNonce,
                  currentConfigurationGeneration == open.audioSessionConfigurationGeneration,
                  open.configurationTransitionIdentity == nil, open.postConfigurationStageIdentity == nil,
                  open.systemOpenConfigurationGeneration == currentConfigurationGeneration else { return nil }
            let (deadlineInstant, overflow) = firstInstant.addingReportingOverflow(3_000_000_000)
            guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
            let deadline = RouteUnavailableDeadlineTicket(identity: .init(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, mediaServicesEpochAtCreation: incoming.mediaServicesEpoch,
                deadlineAnchorInstant: firstInstant, deadlineNonce: try allocator.next(in: .deadline)),
                deadlineInstant: deadlineInstant)
            let observation = RouteObservationTicket(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, mediaServicesEpoch: incoming.mediaServicesEpoch,
                interruptionEpoch: incoming.interruptionEpoch,
                audioSessionConfigurationGeneration: currentConfigurationGeneration,
                audioSessionActivationNonce: open.audioSessionActivationNonce,
                configurationTransitionIdentity: nil, observationNonce: try allocator.next(in: .nonce))
            let sampler = try prepareCommand(group: context.reservation.workGroup, slot: .sampler,
                policy: .safetyBypass, audioIdentity: nil, audioPolicy: nil, allocator: allocator)
            let parent = try prepareRecoveryParent(context: context, snapshot: incoming,
                originInstant: firstInstant, resetPreRoute: false, allocator: allocator)
            let pending = PendingRouteObservation(ticket: observation,
                ordinaryDeadlineState: .init(ticket: deadline, armNonce: try allocator.next(in: .deadline)),
                sampler: sampler.ticket, firstEventObservedInstant: firstInstant,
                latestNotificationRevision: route.notificationRevision, latestObservation: route,
                reasons: .init(rawValue: UInt16(route.reasonBits)), topologyChangeHint: route.topologyChangeHint,
                outputConfigurationChanged: route.outputConfigurationChanged, sampleInFlight: false, resamplePending: true)
            return .init(parent: parent, pending: pending, sampler: sampler)
        }

        private func prepareResetIngress(_ incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator, instant: UInt64,
            settledParent: CurrentPlaybackOperationDeadlineTicket?, settledPost: PostConfigurationRouteState?) throws -> PreparedResetIngress? {
            guard let context = outputContext,
                  incoming.mediaServicesEpoch != snapshot.mediaServicesEpoch ||
                    resetPreRouteState != nil && incoming.system.interruptionClockFold != nil else { return nil }
            guard let events = incoming.system.interruptionClockFold else {
                throw PlaybackSafetyFailure.invalidEvidence
            }
            let originalParent: CurrentPlaybackOperationDeadlineTicket
            if let current = settledParent ?? context.parentDeadline { originalParent = current }
            else {
                let origin = incoming.system.firstUndrainedResetIngressInstant ?? instant
                originalParent = try prepareRecoveryParent(context: context, snapshot: incoming,
                    originInstant: origin, resetPreRoute: true, allocator: allocator)
            }
            var parent: PlaybackProgressBudgetTicket
            switch originalParent { case .coldStart(let value), .outputRecovery(let value): parent = value }
            let suffix = max(context.resetRecoveryMandatorySuffix, resetPreRouteState?.mandatorySuffix ?? 0)
            guard suffix > 0, suffix < parent.cap, instant >= events.lastIngressInstant else {
                throw PlaybackSafetyFailure.invalidEvidence
            }
            func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
                let (value, overflow) = a.addingReportingOverflow(b)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                return value
            }
            var inherited = context.resetInheritedRouteAvailabilityConstraint
            if incoming.system.latestResetIngress != nil,
               case .pending(let pending) = routeObservationState, let ordinary = pending.ordinaryDeadlineState {
                inherited = .init(ordinaryAbsolute: .init(ticketIdentity: ordinary.ticket.identity,
                    deadlineInstant: ordinary.ticket.deadlineInstant, timerArmIdentity: ordinary.armNonce),
                    carriedPostConfigurationStage: inherited?.carriedPostConfigurationStage)
            }
            if let resetInstant = incoming.system.firstUndrainedResetIngressInstant,
               let stage = settledPost ?? postConfigurationRouteState {
                guard let elapsed = stage.effectiveElapsed(at: resetInstant) else { throw PlaybackSafetyFailure.clockOverflow }
                let remaining = elapsed < stage.budget.maximumEffectiveDuration ? stage.budget.maximumEffectiveDuration - elapsed : 0
                inherited = .init(ordinaryAbsolute: inherited?.ordinaryAbsolute ?? stage.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute,
                    carriedPostConfigurationStage: .init(
                        originStageIdentity: stage.budget.carriedStageLineageIdentity ?? stage.budget.stageIdentity,
                        sourceTransitionIdentity: stage.budget.configurationTransitionIdentity,
                        sourceStageIdentity: stage.budget.stageIdentity,
                        parentOperationTicketIdentity: stage.budget.parentOperationDeadline,
                        remainingEffectiveTime: remaining, freezeGeneration: stage.freezeGeneration))
            }
            var state: ResetPreRouteRecoveryDeadlineState
            if let previous = resetPreRouteState {
                guard previous.ticketIdentity.sessionIdentity == context.sessionIdentity,
                      previous.ticketIdentity.parentOperationTicketIdentity == parent.identity else {
                    throw PlaybackSafetyFailure.invalidEvidence
                }
                state = previous
                var elapsed = previous.accumulatedEffectiveTime
                if let running = previous.runningSince {
                    guard events.windowStartInstant >= running else { throw PlaybackSafetyFailure.clockOverflow }
                    elapsed = try add(elapsed, events.windowStartInstant - running)
                }
                elapsed = try add(elapsed, events.effectiveNanoseconds)
                if !events.frozen { elapsed = try add(elapsed, instant - events.lastIngressInstant) }
                state.accumulatedEffectiveTime = elapsed
            } else {
                guard let resetFold = incoming.system.resetPreRouteClockFold else { throw PlaybackSafetyFailure.invalidEvidence }
                var elapsed = parent.accumulatedEffectiveTime
                if let running = parent.runningSince {
                    guard events.windowStartInstant >= running,
                          events.effectiveNanoseconds >= resetFold.effectiveNanoseconds else {
                        throw PlaybackSafetyFailure.clockOverflow
                    }
                    elapsed = try add(elapsed, events.windowStartInstant - running)
                    elapsed = try add(elapsed, events.effectiveNanoseconds - resetFold.effectiveNanoseconds)
                }
                elapsed = try add(elapsed, resetFold.effectiveNanoseconds)
                if !resetFold.frozen { elapsed = try add(elapsed, instant - resetFold.lastIngressInstant) }
                let ticket = ResetPreRouteRecoveryDeadlineTicket.Identity(
                    lineageIdentity: try allocator.next(in: .nonce), sessionIdentity: context.sessionIdentity,
                    parentOperationTicketIdentity: parent.identity, nonce: try allocator.next(in: .deadline))
                state = .init(ticketIdentity: ticket, mandatorySuffix: suffix,
                    boundaryEffectiveElapsed: parent.cap - suffix, accumulatedEffectiveTime: elapsed,
                    runningSince: nil, freezeGeneration: incoming.freezeGeneration, deadlineArm: nil)
            }
            state.mandatorySuffix = suffix
            state.boundaryEffectiveElapsed = min(state.boundaryEffectiveElapsed, parent.cap - suffix)
            state.freezeGeneration = incoming.freezeGeneration
            state.runningSince = incoming.userPaused || incoming.interruptionState == .began ? nil : instant
            if state.runningSince == nil { state.deadlineArm = nil }
            else if state.deadlineArm?.boundaryEffectiveElapsed != state.boundaryEffectiveElapsed ||
                state.deadlineArm?.freezeGeneration != state.freezeGeneration {
                state.deadlineArm = .init(ticketIdentity: state.ticketIdentity,
                    boundaryEffectiveElapsed: state.boundaryEffectiveElapsed, freezeGeneration: state.freezeGeneration,
                    armNonce: try allocator.next(in: .deadline))
            }
            let binding: ResetPreRouteTicketBinding
            if let reset = incoming.system.latestResetIngress {
                binding = .init(rootIdentity: .init(resetTicket: reset.rootIdentity,
                    mediaServicesEpoch: reset.mediaServicesEpoch), ticketIdentity: state.ticketIdentity,
                    bindingNonce: try allocator.next(in: .nonce))
            } else if let current = context.resetPreRouteBinding { binding = current }
            else { throw PlaybackSafetyFailure.invalidEvidence }
            let terminal: PreparedResetTerminal?
            if state.accumulatedEffectiveTime >= state.boundaryEffectiveElapsed ||
                inherited?.ordinaryAbsolute.map({ instant >= $0.deadlineInstant }) == true ||
                inherited?.carriedPostConfigurationStage?.remainingEffectiveTime == 0 {
                let budget = try context.budget ?? CleanupBudgetTicket(
                    predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                    anchorInstant: instant, nonce: context.reservation.nonce)
                let command = try prepareTerminalCleanupOwner(context.reservation)
                terminal = .init(budget: budget, command: command)
                state.runningSince = nil
                state.deadlineArm = nil
            } else { terminal = nil }
            parent.accumulatedEffectiveTime = state.accumulatedEffectiveTime
            parent.runningSince = state.runningSince
            parent.freezeGeneration = state.freezeGeneration
            let updated: CurrentPlaybackOperationDeadlineTicket
            switch originalParent { case .coldStart: updated = .coldStart(parent); case .outputRecovery: updated = .outputRecovery(parent) }
            return .init(parent: updated, state: state, binding: binding, inherited: inherited, terminal: terminal)
        }

        private func prepareInterruptionParent(_ incoming: PlaybackSafetySnapshot,
            allocator: PlaybackIdentityAllocator) throws -> CurrentPlaybackOperationDeadlineTicket? {
            guard resetPreRouteState == nil, let began = incoming.system.firstInterruptionBeganIngressInstant,
                  let context = outputContext else { return nil }
            let original = try context.parentDeadline ?? prepareRecoveryParent(context: context,
                snapshot: incoming, originInstant: began, resetPreRoute: false, allocator: allocator)
            let cutoff = min(began, incoming.system.firstUndrainedResetIngressInstant ?? began)
            var parent: PlaybackProgressBudgetTicket
            switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
            if let running = parent.runningSince {
                guard cutoff >= running else { throw PlaybackSafetyFailure.clockOverflow }
                let (elapsed, overflow) = parent.accumulatedEffectiveTime.addingReportingOverflow(cutoff - running)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                parent.accumulatedEffectiveTime = elapsed
            }
            parent.runningSince = nil
            parent.freezeGeneration = incoming.freezeGeneration
            switch original { case .coldStart: return .coldStart(parent); case .outputRecovery: return .outputRecovery(parent) }
        }

        private func preparePostConfigurationInterruption(_ incoming: PlaybackSafetySnapshot) throws -> PostConfigurationRouteState? {
            guard let began = incoming.system.firstInterruptionBeganIngressInstant,
                  var stage = postConfigurationRouteState else { return nil }
            let cutoff = min(began, incoming.system.firstUndrainedResetIngressInstant ?? began)
            guard let elapsed = stage.effectiveElapsed(at: cutoff) else { throw PlaybackSafetyFailure.clockOverflow }
            stage.budget.accumulatedEffectiveTime = elapsed
            stage.runningSince = nil
            stage.freezeGeneration = incoming.freezeGeneration
            return stage
        }

        /// 不签身份、不重试prepare；保留原record/资源及预留，撤销进一步准入。
        func foldTerminal(_ incoming: PlaybackSafetySnapshot) {
            fold(incoming)
            audioPhase?.permitsFurtherCalls = false
            outputContext?.poisoned = true
            outputContext?.disposition = .releaseAfterTeardown
            outputContext?.relayClosing = true
            outputContext?.teardownRequested = true
            terminateCleanupReservation()
        }

        func runningCleanupOwner(_ reservation: CleanupReservationTicket) -> OutputTransitionOwnerTicket? {
            for record in commands {
                guard let record, record.groupTicket == reservation.ownerGroup,
                      case .controllerCleanup(let runner) = record.payload else { continue }
                return runner.owner
            }
            return nil
        }

        func terminateCleanupReservation() {
            guard let ticket = cleanupReservation?.ticket else { return }
            cleanupReservation?.terminal = true
            for index in groups.indices {
                guard let group = groups[index]?.ticket else { continue }
                if group == ticket.workGroup || isDescendant(group, of: ticket.workGroup) { groups[index]?.sealed = true }
            }
            for index in commands.indices {
                guard let group = commands[index]?.groupTicket else { continue }
                if group == ticket.workGroup || isDescendant(group, of: ticket.workGroup) { cancel(index) }
            }
        }

        func prepareTerminalCleanupOwner(_ reservation: CleanupReservationTicket) throws -> PreparedCommand {
            guard cleanupReservation?.ticket == reservation else { throw Failure.invalidGroup }
            if let index = commands.firstIndex(where: {
                $0?.groupTicket == reservation.ownerGroup && $0?.slot == ReservedCleanupStage.owner.slot
            }), let record = commands[index] {
                if case .terminal = record.phase { throw Failure.invalidGroup }
                return .init(index: index, ticket: record.controlTaskTicket, record: nil, reservedStage: nil)
            }
            return try prepareReservedCleanup(reservation, stage: .owner)
        }

        func prepareReservedCleanup(_ reservation: CleanupReservationTicket,
            stage: ReservedCleanupStage) throws -> PreparedCommand {
            guard cleanupReservation?.ticket == reservation, stage != .audioSession,
                  let reserved = cleanupReservation?[stage],
                  let ticket = cleanupReservation?.task(for: stage) else { throw Failure.invalidPolicy }
            if let record = commands[reserved.index] {
                guard record.controlTaskTicket == ticket else { throw Failure.slotOccupied }
                return .init(index: reserved.index, ticket: ticket, record: nil, reservedStage: nil)
            }
            guard !reserved.consumed,
                  !commands.contains(where: { $0?.resourceIdentity == reservation.ownerGroup.resourceIdentity && $0?.slot == stage.slot }) else {
                throw Failure.slotOccupied
            }
            let record = try OwnedPostIngressControlCommand(controlTaskTicket: ticket,
                slot: stage.slot, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
            return .init(index: reserved.index, ticket: ticket, record: record, reservedStage: stage)
        }

        @discardableResult
        func installPreparedCommand(_ prepared: PreparedCommand) -> ControlTaskTicket {
            installPreparedCommandFields(prepared)
            return prepared.ticket
        }

        /// 唯一不可失败安装叶；nil仅为准确已有record的join，不覆盖槽或消费预留。
        func installPreparedCommandFields(_ prepared: borrowing PreparedCommand) {
            guard prepared.record != nil else { return }
            commands[prepared.index] = prepared.record
            if let stage = prepared.reservedStage { cleanupReservation?[stage].consumed = true }
        }

        func fold(_ snapshot: PlaybackSafetySnapshot) {
            if snapshot.audioAdmissionFenceRevision != self.snapshot.audioAdmissionFenceRevision ||
               snapshot.mediaServicesEpoch != self.snapshot.mediaServicesEpoch ||
               snapshot.interruptionEpoch != self.snapshot.interruptionEpoch {
                stableRouteCommit = nil
                routeStabilityCandidate = nil
            }
            if snapshot.mediaServicesEpoch != self.snapshot.mediaServicesEpoch {
                authoritativeRoute = .unknown
                currentResetRoot = snapshot.system.latestResetIngress.map {
                    .init(resetTicket: $0.rootIdentity, mediaServicesEpoch: $0.mediaServicesEpoch)
                }
                // 只在新root物化这一刻建立来源；以后再次看见nil不能重建旧来源。
                emptyResetDrainSource = resourceState == nil && cleanupReservation == nil &&
                    commands.allSatisfy({ $0 == nil }) && groups.allSatisfy({ $0 == nil }) ? currentResetRoot : nil
                processConfigurationReceipt = nil
                stableRouteCommit = nil
                outputContext?.sessionReceipts = nil
                registeredDrainProof = nil
                outputContext?.resetProof = nil
                outputContext?.interruptionProof = nil
                outputContext?.userResumeRequested = false
                audioPhase?.reactivationState = nil
                outputContext?.teardownRequested = true
                if let reset = snapshot.system.latestResetIngress {
                    outputContext?.pendingReset = .init(resetTicket: reset.rootIdentity, mediaServicesEpoch: reset.mediaServicesEpoch)
                }
                ownedResource?.payload.lease?.deactivation = .invalidatedByMediaServicesReset(mediaServicesEpoch: snapshot.mediaServicesEpoch)
                for index in commands.indices {
                    guard let request = commands[index]?.deactivationRequest,
                          request.call.phaseIdentity.mediaServicesEpoch != snapshot.mediaServicesEpoch else { continue }
                    cancel(index)
                }
            }
            if snapshot.throughRevision != self.snapshot.throughRevision && snapshot.system.interruptionBeganObserved {
                outputContext?.sessionReceipts?.active = nil
                stableRouteCommit = nil
                if case .acquiringLease(let context, .readyToCommit(.ordinary(let configured, _))) = resourceState {
                    resourceState = .acquiringLease(context, .awaitingActivation(configured))
                }
                if case .interruption = registeredDrainProof { registeredDrainProof = nil }
                audioPhase?.currentReactivationProof = nil
                outputContext?.interruptionProof = nil
                outputContext?.userResumeRequested = false
                outputContext?.interruptionDrainRequired = true
                audioPhase?.reactivationState?.basePhase = .awaitingActivation
                audioPhase?.reactivationState?.freezeCauses.insert(.systemInterruption)
                audioPhase?.reactivationState?.cutoffArmTicket = nil
                var pending: PendingRouteObservation
                if case .pending(let current) = routeObservationState { pending = current }
                else { pending = .init(ticket: nil, ordinaryDeadlineState: nil, sampler: nil, latestObservation: nil,
                    reasons: .initialAuthoritativeSampleRequired, topologyChangeHint: false, outputConfigurationChanged: false) }
                if let source = pending.sampler,
                   let index = commands.firstIndex(where: { $0?.controlTaskTicket == source }) {
                    cancel(index)
                    if let record = commands[index], case .terminal = record.phase,
                       routeSampleClaim?.source != source, mayDiscard(record) {
                        commands[index] = nil
                        pending.sampler = nil
                    }
                }
                pending.ticket = nil
                routeObservationState = .pending(pending)
            }
            if snapshot.throughRevision != self.snapshot.throughRevision,
               let route = snapshot.route, let context = outputContext,
               route.sessionIdentity == context.sessionIdentity,
               context.phase == .pendingLeaseAcquisition || routeObservationState?.isPending == true {
                var pending: PendingRouteObservation
                if case .pending(let previous) = routeObservationState,
                   (previous.ticket?.sessionIdentity ?? previous.latestObservation?.sessionIdentity) == route.sessionIdentity,
                   (previous.ticket?.monitorLifecycle ?? previous.latestObservation?.monitorLifecycle) == route.monitorLifecycle {
                    pending = previous
                } else {
                    pending = .init(ticket: nil, ordinaryDeadlineState: nil, sampler: nil, latestObservation: nil,
                        reasons: [], topologyChangeHint: false, outputConfigurationChanged: false)
                }
                pending.firstEventObservedInstant = pending.firstEventObservedInstant ?? snapshot.firstRouteEventObservedInstant
                if route.notificationRevision >= pending.latestNotificationRevision { pending.latestObservation = route }
                pending.latestNotificationRevision = max(pending.latestNotificationRevision, route.notificationRevision)
                pending.reasons.formUnion(.init(rawValue: UInt16(route.reasonBits)))
                pending.topologyChangeHint = pending.topologyChangeHint || route.topologyChangeHint
                pending.outputConfigurationChanged = pending.outputConfigurationChanged || route.outputConfigurationChanged
                pending.resamplePending = true
                routeObservationState = .pending(pending)
            }
            self.snapshot = snapshot
            for index in commands.indices {
                guard let record = commands[index], record.gatePolicy != .safetyBypass else { continue }
                let routeCanceled = record.gatePolicy == .activationRequiresOpen && !snapshot.routeObservationGateOpen
                // hint只关闭gate；只有实际semantic变化才能取消speculative结果。
                if !matches(record.safetySnapshot) || !matchesAudio(record) || routeCanceled || snapshot.failure != nil {
                    cancel(index)
                }
            }
        }
        func matchesAudio(_ record: OwnedPostIngressControlCommand) -> Bool {
            guard record.gatePolicy == .audioSession else { return true }
            guard let phase = audioPhase, phase.permitsFurtherCalls,
                  phase.identity == record.audioPhaseIdentity, phase.policy == record.audioPolicy,
                  phase.identity.owner == record.ownerTicket,
                  phase.identity.mediaServicesEpoch == snapshot.mediaServicesEpoch,
                  phase.configurationAttempt.mediaServicesEpoch == snapshot.mediaServicesEpoch,
                  phase.parent.sessionIdentity == phase.identity.sessionIdentity else { return false }
            switch phase.policy {
            case .configureAcquisition(let ticket, let nonce, let attempt, _):
                guard phase.hasConsistentConfigurationProofReferences, ticket.group.resourceIdentity == record.resourceIdentity,
                      let proof = phase.acquisitionOwnershipProof,
                      proof.acquisitionTicket == ticket, proof.ownershipNonce == nonce,
                      proof.sessionIdentity == phase.identity.sessionIdentity,
                      proof.leaseID == phase.identity.leaseID, proof.contextNonce == phase.identity.contextNonce,
                      attempt == phase.configurationAttempt.nonce else { return false }
                if let context = outputContext, context.resetAcquisitionBinding != nil {
                    guard matchesManagedAcquisitionReset(context), phase.incarnation == nil,
                          phase.resetBinding == context.resetPreRouteBinding,
                          phase.identity.contextNonce == context.contextNonce else { return false }
                } else if phase.incarnation != nil || phase.resetBinding != nil {
                    guard matchesResetBinding(phase) else { return false }
                }
                return phase.hasConsistentConfigurationStep
            case .configureInactive(let incarnation, let proof, let attempt, _):
                guard phase.hasConsistentConfigurationProofReferences, let current = phase.incarnation, let binding = phase.resetBinding,
                      registeredDrainProof == .reset(current.drainProof),
                      current.identity == incarnation, current.drainProof.identity == proof,
                      current.identity.root == proof.root,
                      incarnation.root.mediaServicesEpoch == snapshot.mediaServicesEpoch,
                      incarnation.sessionIdentity == phase.identity.sessionIdentity,
                      current.configurationPlan == phase.configurationAttempt.plan,
                      current.outerDeadlineTicket == phase.parent,
                      binding.rootIdentity == incarnation.root,
                      binding.ticketIdentity == current.resetPreRouteDeadlineTicket.identity,
                      binding.ticketIdentity.parentOperationTicketIdentity == phase.parent,
                      attempt == phase.configurationAttempt.nonce else { return false }
                return phase.hasConsistentConfigurationStep
            case .activate(let purpose, let epoch, let fence, let invocation):
                if case .reactivateConfiguredGeneration(_, _, _, let attempt) = purpose,
                   attempt.attemptNonce != invocation { return false }
                return !snapshot.interruptionVeto && !snapshot.userPaused && epoch == snapshot.interruptionEpoch &&
                    fence == snapshot.audioAdmissionFenceRevision && matchesPurpose(purpose, phase: phase)
            }
        }
        func matchesResetBinding(_ phase: RegisteredAudioSessionPhase) -> Bool {
            guard phase.hasConsistentResetReferences, let incarnation = phase.incarnation else { return false }
            return registeredDrainProof == .reset(incarnation.drainProof) &&
                incarnation.identity.root.mediaServicesEpoch == snapshot.mediaServicesEpoch
        }
        func matchesManagedAcquisitionReset(_ context: OutputResourceContext) -> Bool {
            guard let binding = context.resetAcquisitionBinding,
                  binding.proof.identity.root == currentResetRoot,
                  context.pendingReset == binding.proof.identity.root,
                  registeredDrainProof == .reset(binding.proof),
                  binding.proof.currentConfigurationGeneration == currentConfigurationGeneration,
                  binding.binding.rootIdentity == binding.proof.identity.root,
                  binding.binding.ticketIdentity == binding.preRouteTicket.identity,
                  resetPreRouteState?.ticketIdentity == binding.preRouteTicket.identity,
                  binding.preRouteTicket.identity.sessionIdentity == context.sessionIdentity else { return false }
            return true
        }
        func matchesPurpose(_ purpose: AudioSessionActivationPurpose, phase: RegisteredAudioSessionPhase) -> Bool {
            guard phase.hasConsistentActivationConfiguration, phase.hasConsistentActivationProofReferences else { return false }
            switch purpose {
            case .activateAcquiredConfiguredGeneration(let session, let generation, let proof):
                return session == phase.identity.sessionIdentity && proof == phase.acquisitionOwnershipProof &&
                    proof.sessionIdentity == session && proof.leaseID == phase.identity.leaseID &&
                    proof.contextNonce == phase.identity.contextNonce &&
                    matchesConfiguredReceipt(phase, generation: generation)
            case .commitResetConfiguration(let identity, let base, let receiptIdentity):
                guard let incarnation = phase.incarnation, let binding = phase.resetBinding,
                      let receipt = phase.inactiveReceipt else { return false }
                return incarnation.identity == identity && incarnation.baseConfigurationGeneration == base &&
                    registeredDrainProof == .reset(incarnation.drainProof) &&
                    identity.sessionIdentity == phase.identity.sessionIdentity &&
                    identity.root.mediaServicesEpoch == snapshot.mediaServicesEpoch &&
                    incarnation.drainProof.identity.root == identity.root &&
                    incarnation.drainProof.currentConfigurationGeneration == base &&
                    incarnation.configurationPlan == phase.configurationAttempt.plan &&
                    incarnation.outerDeadlineTicket == phase.parent && binding.rootIdentity == identity.root &&
                    binding.ticketIdentity == incarnation.resetPreRouteDeadlineTicket.identity &&
                    binding.ticketIdentity.parentOperationTicketIdentity == phase.parent &&
                    receipt.identity == receiptIdentity && receipt.identity.mediaServicesEpoch == snapshot.mediaServicesEpoch &&
                    receipt.identity.attemptNonce == phase.configurationAttempt.nonce &&
                    receipt.planDigest == incarnation.configurationPlan
            case .reactivateConfiguredGeneration(let session, let transition, let generation, let attempt):
                guard let budget = phase.reactivationBudget,
                      session == phase.identity.sessionIdentity, budget.identity.sessionIdentity == session,
                      budget.identity == attempt.reactivationBudgetIdentity, budget.committedGeneration == generation,
                      budget.parentOperationTicketIdentity == phase.parent,
                      attempt.interruptionEpoch == snapshot.interruptionEpoch,
                      attempt.reactivationProof == phase.currentReactivationProof,
                      attempt.retainedContextNonce == phase.identity.contextNonce,
                      matchesConfiguredReceipt(phase, generation: generation) else { return false }
                switch (transition, attempt.reactivationProof) {
                case (nil, .interruption(let proof)):
                    return registeredDrainProof == .interruption(proof) &&
                        budget.postConfigurationStageIdentity == nil && proof.sessionIdentity == session &&
                        proof.configuredGeneration == generation && proof.contextNonce == phase.identity.contextNonce
                case (.reset(let identity), .resetPostConfiguration(let proof)):
                    return matchesResetBinding(phase) && phase.incarnation?.identity == identity && proof.incarnationIdentity == identity &&
                        identity.sessionIdentity == session && identity.root.mediaServicesEpoch == snapshot.mediaServicesEpoch &&
                        proof.resetDrainProofIdentity == phase.incarnation?.drainProof.identity &&
                        proof.retainedContextNonce == phase.identity.contextNonce && proof.leaseID == phase.identity.leaseID &&
                        proof.committedGeneration == generation && proof.postConfigurationStageIdentity == budget.postConfigurationStageIdentity
                default: return false
                }
            }
        }
        func matchesConfiguredReceipt(_ phase: RegisteredAudioSessionPhase, generation: UInt64) -> Bool {
            guard phase.hasConsistentConfiguredReceiptReferences, let process = phase.processReceipt else { return false }
            return process.identity.mediaServicesEpoch == snapshot.mediaServicesEpoch && process.identity.configurationGeneration == generation
        }
        func matches(_ frozen: ControlCommandSafetySnapshot) -> Bool {
            switch frozen {
            case .cleanupOwnership: true
            case .reservation(let mediaServicesEpoch): mediaServicesEpoch == snapshot.mediaServicesEpoch
            case .system(let system): system == ControlSystemSafetySnapshot(snapshot)
            case .speculative(let system, let semantic):
                system == ControlSystemSafetySnapshot(snapshot) && semantic == routeSemantic
            }
        }
        func cancel(_ index: Int) {
            if let record = commands[index], record.phase == .queued || record.phase == .running,
               record.audioPhaseIdentity == audioPhase?.identity, record.audioPolicy == audioPhase?.policy {
                switch record.audioPolicy {
                case .configureAcquisition, .configureInactive: audioPhase?.permitsFurtherCalls = false
                default: break
                }
            }
            commands[index]?.resultInvalidated = true
            switch commands[index]?.phase {
            case .queued:
                if let record = commands[index], record.slot == .acquire,
                   case .acquiringWithoutLease(var context) = resourceState,
                   context.sourceTask == record.controlTaskTicket {
                    context.acquisitionNoLeaseReceipt = .init(acquisitionTicket: record.controlTaskTicket, outcome: .canceledBeforeClaim)
                    context.sourceTask = nil
                    resourceState = .acquiringWithoutLease(context)
                    commands[index]?.resultClaimed = true
                }
                if let record = commands[index], case .activate = record.audioPolicy,
                   let identity = record.audioPhaseIdentity {
                    commands[index]?.activationOutcome = .notInvoked(.init(callIdentity:
                        .init(record: record.controlTaskTicket, phaseIdentity: identity)))
                }
                commands[index]?.phase = .terminal(.canceled)
            case .running: commands[index]?.phase = .cancelRequested
            default: break
            }
        }
        func invalidateEmptyResetDrainSource() {
            if let source = emptyResetDrainSource,
               case .reset(let proof) = registeredDrainProof, proof.identity.root == source {
                registeredDrainProof = nil
            }
            emptyResetDrainSource = nil
        }
        func isDescendant(_ child: ControlTaskGroupTicket, of ancestor: ControlTaskGroupTicket) -> Bool {
            var current = groups.first(where: { $0?.ticket == child })??.parent
            for _ in groups.indices {
                guard let parent = current else { return false }
                if parent == ancestor { return true }
                current = groups.first(where: { $0?.ticket == parent })??.parent
            }
            return false
        }
        /// 游标清理开始后，任何本组/兄弟/后代的空槽都不能补绑新relay；后继须先完成原cycle交接。
        func allowsOutputRelayBinding(_ group: ControlTaskGroupTicket) -> Bool {
            guard groups.contains(where: { $0?.ticket == group && $0?.sealed == false }) else { return false }
            guard let context = outputContext,
                  group == context.reservation.ownerGroup || isDescendant(group, of: context.reservation.ownerGroup)
            else { return true }
            guard !context.poisoned, !context.teardownRequested,
                  context.disposition != .releaseAfterTeardown else { return false }
            return !commands.contains(where: {
                guard $0?.groupTicket == context.reservation.ownerGroup else { return false }
                if case .controllerCleanup = $0?.payload { return true }
                return false
            })
        }
        func isTerminal(_ group: ControlTaskGroupTicket) -> Bool {
            guard groups.contains(where: { $0?.ticket == group && $0?.sealed == true }) else { return false }
            return commands.allSatisfy {
                guard let record = $0,
                      record.groupTicket == group || isDescendant(record.groupTicket, of: group) else { return true }
                if case .terminal = record.phase { return true }
                return false
            }
        }
        func mayDiscard(_ record: OwnedPostIngressControlCommand) -> Bool {
            if case .backendOperation(let runner) = record.payload {
                guard case .terminal = record.phase,
                      runner.factoryResult == nil, runner.result != nil else { return false }
            }
            if case .eventDrain = record.payload { return false }
            if case .controllerCleanup = record.payload { return false }
            guard record.ownedResult == nil, record.factoryResult == nil else { return false }
            if case .activate = record.audioPolicy, !record.activationResponsibilityTransferred {
                if case .returnedSuccess = record.activationOutcome { return false }
                if ownedResource != nil { return false }
            }
            if record.deactivationRequest != nil,
               record.phase != .terminal(.canceled), record.deactivationOutcome == nil { return false }
            return true
        }

        func canRelease(_ resource: OutputResourceOwnership) -> Bool {
            // 后端对象必须先由准确teardown结果转走，lease释放不能代替后端停止。
            if case .backend = resource.payload { return false }
            guard outputContext?.monitorStopped == true else { return false }
            guard let lease = resource.payload.lease else { return true }
            switch lease.deactivation {
            case .confirmedInactive, .invalidatedByMediaServicesReset, .deactivationSettled: break
            case .awaitingActivationOutcome, .requiresDeactivate, .deactivationInFlight: return false
            }
            return commands.allSatisfy { record in
                guard let record else { return true }
                if let identity = record.audioPhaseIdentity,
                   identity.leaseID == lease.leaseID, identity.sessionIdentity == resource.sessionIdentity {
                    guard case .terminal = record.phase else { return false }
                    if case .activate = record.audioPolicy { return record.activationResponsibilityTransferred }
                    return true
                }
                if let request = record.deactivationRequest, request.reservation == resource.reservation {
                    if case .terminal = record.phase { return true }
                    return false
                }
                return true
            }
        }
    }
    private struct Group {
        let resourceIdentity: ControlResourceIdentity
        let ownerNonce: UInt64
        let groupNonce: UInt64
        private let frozenParent: FrozenControlTaskGroupTicket?
        var parent: ControlTaskGroupTicket? { frozenParent?.ticket }
        var sealed = false

        init(ticket: ControlTaskGroupTicket, parent: ControlTaskGroupTicket?) throws {
            // 三个内部安装点都必须先构造完整自洽票；绝不归一化外来错resource。
            guard ticket.resourceIdentity == ticket.ownerTicket.resourceIdentity else {
                throw Failure.invalidGroup
            }
            resourceIdentity = ticket.resourceIdentity
            ownerNonce = ticket.ownerTicket.nonce
            groupNonce = ticket.nonce
            frozenParent = try parent.map(FrozenControlTaskGroupTicket.init)
        }

        var ticket: ControlTaskGroupTicket {
            .init(resourceIdentity: resourceIdentity,
                ownerTicket: .init(resourceIdentity: resourceIdentity, nonce: ownerNonce),
                nonce: groupNonce)
        }
    }
    private struct ActivationClaim {
        // 同issuer专用域的永久消费边界；后继只推进，retire/登记/reset均不清零。
        let invocationIdentity: AudioSessionActivationInvocationIdentity
        let record: ControlTaskTicket
    }
    func reserveCleanup(resource: ControlResourceIdentity) throws -> CleanupReservation {
        try transaction { _ in try reserveCleanupLocked(resource: resource) }
    }

    private func reserveCleanupLocked(resource: ControlResourceIdentity) throws -> CleanupReservation {
        guard authority.snapshot.failure == nil, !allocator.isExhausted else { throw Failure.invalidGroup }
        if let existing = authority.cleanupReservation {
            guard existing.ticket.ownerGroup.resourceIdentity == resource, !existing.terminal else { throw Failure.slotOccupied }
            return existing
        }
        // 只在栈上计算固定掩码；容量与所有身份齐备以后才写入authority。
        var freeGroups: UInt32 = 0
        for index in authority.groups.indices where authority.groups[index] == nil { freeGroups |= 1 << index }
        guard freeGroups.nonzeroBitCount >= 2 else { throw Failure.capacity }
        let parentIndex = freeGroups.trailingZeroBitCount
        freeGroups &= ~(1 << parentIndex)
        let childIndex = freeGroups.trailingZeroBitCount
        var freeSlots: UInt32 = 0
        for index in 16..<32 where authority.commands[index] == nil { freeSlots |= 1 << index }
        guard freeSlots.nonzeroBitCount >= 8 else { throw Failure.capacity }
        let parentOwner = ControlTaskOwnerTicket(resourceIdentity: resource, nonce: try allocator.next(in: .nonce))
        let parent = ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: parentOwner,
            nonce: try allocator.next(in: .controlTask))
        let childOwner = ControlTaskOwnerTicket(resourceIdentity: resource, nonce: try allocator.next(in: .nonce))
        let child = ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: childOwner,
            nonce: try allocator.next(in: .controlTask))
        let ticket = CleanupReservationTicket(ownerGroup: parent, workGroup: child, nonce: try allocator.next(in: .nonce))
        func reserveSlot() throws -> ReservedCleanupSlot {
            let index = freeSlots.trailingZeroBitCount
            freeSlots &= ~(1 << index)
            return .init(index: index, nonce: try allocator.next(in: .controlTask))
        }
        let reservation = CleanupReservation(ticket: ticket, contextNonce: try allocator.next(in: .nonce),
            terminalOwner: .init(resourceIdentity: resource, nonce: try allocator.next(in: .nonce)),
            deactivationPhaseNonce: try allocator.next(in: .nonce),
            predecessorContextNonce: try allocator.next(in: .nonce), leaseOnlyContextNonce: try allocator.next(in: .nonce),
            monitorOnlyContextNonce: try allocator.next(in: .nonce), retainedSuccessorContextNonce: try allocator.next(in: .nonce),
            slots: (try reserveSlot(), try reserveSlot(), try reserveSlot(), try reserveSlot(),
                try reserveSlot(), try reserveSlot(), try reserveSlot(), try reserveSlot()))
        let parentGroup = try Group(ticket: parent, parent: nil)
        let childGroup = try Group(ticket: child, parent: parent)
        authority.groups[parentIndex] = parentGroup
        authority.groups[childIndex] = childGroup
        authority.cleanupReservation = reservation
        authority.invalidateEmptyResetDrainSource()
        return reservation
    }

    func enqueueReservedCleanup(_ reservation: CleanupReservationTicket, stage: ReservedCleanupStage) throws -> ControlTaskTicket {
        try transaction { _ in try enqueueReservedCleanupLocked(reservation, stage: stage) }
    }

    private func enqueueReservedCleanupLocked(_ reservation: CleanupReservationTicket,
                                              stage: ReservedCleanupStage) throws -> ControlTaskTicket {
        installPreparedCommand(try prepareReservedCleanup(reservation, stage: stage))
    }

    private func prepareReservedCleanup(_ reservation: CleanupReservationTicket,
                                        stage: ReservedCleanupStage) throws -> PreparedCommand {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).prepareReservedCleanup(reservation, stage: stage)
    }

    /// 可retain owner使用未承诺槽；终态升级只join准确在途owner，不能重开已完成task。
    private func prepareOutputCleanupOwner(_ reservation: CleanupReservationTicket, terminal: Bool) throws -> PreparedCommand {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).prepareOutputCleanupOwner(reservation, terminal: terminal)
    }

    func terminateCleanupReservation(_ ticket: CleanupReservationTicket) -> ControlTaskOwnerTicket? {
        try? transaction { output in
            guard authority.cleanupReservation?.ticket == ticket else { return nil }
            terminateCleanupReservationLocked(ticket, output: &output)
            return authority.cleanupReservation?.terminalOwner
        }
    }

    private func terminateCleanupReservationLocked(_ ticket: CleanupReservationTicket, output: inout PlaybackOutputSafetyState) {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).terminateCleanupReservationLocked(ticket, output: &output)
    }

    func completeWithOwnedResult(_ ticket: ControlTaskTicket, ownership: OutputResourceOwnership) -> Bool {
        (try? transaction { _ in
            if authority.outputContext?.phase == .pendingCreation,
               authority.outputContext?.sourceTask == ticket { return false }
            guard let context = authority.outputContext, context.sourceTask == ticket,
                  let reservation = authority.cleanupReservation, reservation.ticket == ownership.reservation,
                  context.contextNonce == ownership.contextNonce,
                  ticket.group == reservation.ticket.workGroup,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.payload == nil,
                  record.phase == .running || record.phase == .cancelRequested else { return false }
            // 结果不能换session、伪造backend与lease/monitor之间的归属关系。
            guard ownership.payload.matches(ticket.group.resourceIdentity,
                sessionIdentity: context.sessionIdentity) else { return false }
            if case .backend(let value) = ownership.payload {
                guard let monitor = value.lease.monitor,
                      value.identity.sessionIdentity == monitor.sessionIdentity,
                      value.lifecycle.map({ $0.backendIdentity == value.identity }) ?? true else { return false }
            }
            try authority.commands[index]?.installOwnedResult(ownership)
            authority.commands[index]?.phase = record.phase == .running ? .terminal(.completed) : .terminal(.canceled)
            return true
        }) ?? false
    }

    private func validatedOwnedResultIndex(_ ticket: ControlTaskTicket, reservation: CleanupReservationTicket,
        contextNonce: UInt64, forCleanup: Bool, output: PlaybackOutputSafetyState,
        acquisitionSettlement: Bool = false) -> Int? {
        guard acquisitionSettlement || authority.outputContext?.phase != .pendingLeaseAcquisition else { return nil }
        guard let context = authority.outputContext, context.contextNonce == contextNonce,
              context.reservation == reservation, context.sourceTask == ticket,
              authority.cleanupReservation?.ticket == reservation, authority.ownedResource == nil,
              let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
              let record = authority.commands[index], let resource = record.ownedResult,
              case .terminal = record.phase, !record.resultClaimed,
              resource.reservation == reservation, resource.contextNonce == contextNonce,
              record.groupTicket == reservation.workGroup else { return nil }
        if !forCleanup {
            guard authority.cleanupReservation?.terminal == false,
                  record.phase == .terminal(.completed), !record.resultInvalidated,
                  authority.matches(record.safetySnapshot), authority.snapshot.failure == nil,
                  authority.groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false }) else { return nil }
            if record.gatePolicy == .routeSpeculativeRateZero || record.gatePolicy == .activationRequiresOpen {
                guard output.routeObservationGateOpen, !authority.snapshot.interruptionVeto else { return nil }
            }
        }
        return index
    }

    func claimOwnedResourceReleaseRunner(_ ticket: ControlTaskTicket) -> OwnedOutputResourceRunner? {
        try? transaction { output in
            guard let reservation = authority.cleanupReservation, let resource = authority.ownedResource,
                  resource.reservation == reservation.ticket, ticket == reservation.task(for: .leaseRelease),
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.phase == .queued else { return nil }
            terminateCleanupReservationLocked(reservation.ticket, output: &output)
            guard authority.canRelease(resource), authority.isTerminal(reservation.ticket.workGroup) else { return nil }
            let runner = OwnedOutputResourceRunner(task: ticket, ownership: resource)
            authority.commands[index]?.phase = .running
            guard let context = authority.outputContext else { return nil }
            switch resource.payload {
            case .lease: authority.resourceState = .leaseOnlyCleanup(context, .runner(ticket))
            case .monitor: authority.resourceState = .routeMonitorCleanup(context, .runner(ticket))
            case .backend: return nil
            }
            return runner
        }
    }

    func transferActivationDisposition(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in transferActivationDispositionLocked(ticket) }) ?? false
    }

    private func transferActivationDispositionLocked(_ ticket: ControlTaskTicket) -> Bool {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).transferActivationDispositionLocked(ticket)
    }

    func enqueueCleanupDeactivation(_ ticket: CleanupReservationTicket) throws -> ControlTaskTicket {
        try transaction { _ in try enqueueCleanupDeactivationLocked(ticket) }
    }

    private func enqueueCleanupDeactivationLocked(_ ticket: CleanupReservationTicket) throws -> ControlTaskTicket {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).enqueueCleanupDeactivationLocked(ticket)
    }

    func ownedDeactivationDisposition() -> AudioSessionDeactivationDisposition? {
        projection { authority.ownedResource?.payload.lease?.deactivation }
    }

    func refreshCleanupReservation(_ ticket: CleanupReservationTicket) -> Bool {
        (try? transaction { output in
            guard var renewed = authority.cleanupReservation, renewed.ticket == ticket, !renewed.terminal else { return false }
            guard !allocator.isExhausted else {
                terminateCleanupReservationLocked(ticket, output: &output)
                return false
            }
            var freeMask: UInt32 = 0
            for index in 16..<32 where authority.commands[index] == nil && !renewed.reserves(index) { freeMask |= 1 << index }
            var required = 0
            for stage in ReservedCleanupStage.allCases where renewed[stage].consumed {
                guard authority.commands[renewed[stage].index] == nil else { return false }
                required += 1
            }
            guard freeMask.nonzeroBitCount >= required else {
                terminateCleanupReservationLocked(ticket, output: &output)
                return false
            }
            do {
                for stage in ReservedCleanupStage.allCases where renewed[stage].consumed {
                    let index = freeMask.trailingZeroBitCount
                    freeMask &= ~(1 << index)
                    renewed[stage] = .init(index: index, nonce: try allocator.next(in: .controlTask))
                    if stage == .audioSession { renewed.deactivationPhaseNonce = try allocator.next(in: .nonce) }
                }
            } catch {
                terminateCleanupReservationLocked(ticket, output: &output)
                return false
            }
            authority.cleanupReservation = renewed
            return true
        }) ?? false
    }

    func releaseCleanupReservation(_ ticket: CleanupReservationTicket) -> Bool {
        (try? transaction { _ in
            guard authority.cleanupReservation?.ticket == ticket, authority.ownedResource == nil else { return false }
            func belongs(_ group: ControlTaskGroupTicket) -> Bool {
                group == ticket.ownerGroup || authority.isDescendant(group, of: ticket.ownerGroup)
            }
            guard authority.commands.allSatisfy({ optional in
                guard let record = optional, belongs(record.groupTicket) else { return true }
                guard case .terminal = record.phase else { return false }
                return authority.mayDiscard(record)
            }) else { return false }
            var groupMask: UInt32 = 0
            for index in authority.groups.indices {
                if let group = authority.groups[index]?.ticket, belongs(group) { groupMask |= 1 << index }
            }
            for index in authority.commands.indices {
                if let record = authority.commands[index], belongs(record.groupTicket) { authority.commands[index] = nil }
            }
            for index in authority.groups.indices where groupMask & (1 << index) != 0 { authority.groups[index] = nil }
            authority.cleanupReservation = nil
            authority.resourceState = nil
            authority.authoritativeRoute = .unknown
            authority.routeObservationState = nil
            authority.stableRouteCommit = nil
            authority.routeSampleClaim = nil
            authority.routeStabilityCandidate = nil
            return true
        }) ?? false
    }

    func cancelAcquisitionSession() -> Bool {
        (try? transaction { _ in
            guard let reservation = authority.cleanupReservation, authority.ownedResource == nil else { return false }
            func belongs(_ group: ControlTaskGroupTicket) -> Bool {
                group == reservation.ticket.ownerGroup || authority.isDescendant(group, of: reservation.ticket.ownerGroup)
            }
            // 无backend不等于无责任：真实lease、SDK call、relay及任务尾部必须交给原owner排空。
            guard authority.commands.allSatisfy({ optional in
                guard let record = optional, belongs(record.groupTicket) else { return true }
                guard case .terminal = record.phase else { return false }
                return authority.mayDiscard(record)
            }) else { return false }
            var groupMask: UInt32 = 0
            for index in authority.groups.indices {
                if let group = authority.groups[index]?.ticket, belongs(group) { groupMask |= 1 << index }
            }
            for index in authority.commands.indices {
                if let record = authority.commands[index], belongs(record.groupTicket) { authority.commands[index] = nil }
            }
            for index in authority.groups.indices where groupMask & (1 << index) != 0 { authority.groups[index] = nil }
            authority.cleanupReservation = nil
            authority.resourceState = nil
            authority.authoritativeRoute = .unknown
            authority.routeObservationState = nil
            authority.stableRouteCommit = nil
            authority.routeSampleClaim = nil
            authority.routeStabilityCandidate = nil
            return true
        }) ?? false
    }

    enum Failure: Error { case capacity, invalidGroup, slotOccupied, invalidPolicy, cleanupTailPending }
    let executor: PlaybackControlExecutor
    let allocator: PlaybackIdentityAllocator
    private let authority: Authority
    // scheduler对象由controller独占；此处只保存弱绑定，所有票据仍在Authority。
    private weak var deadlineScheduler: PlaybackDeadlineScheduler?
    private weak var terminalReceiver: (any PlaybackOwnedCleanupReceiving)?
    private var reconcilingRuntime = false
    let progressSignal = PlaybackControlProgressSignal()
    let monotonicClock: any PlaybackMonotonicClock
    var clock: any PlaybackMonotonicClock { monotonicClock }

    init(allocator: PlaybackIdentityAllocator = .shared,
        clock: any PlaybackMonotonicClock = DispatchPlaybackMonotonicClock()) {
        // 只验证此构建固定ABI，不改变运行中checked耗尽/输入失败的处理。
        PlaybackRuntimeAllocationReservations.validateOwnedAndGlobalCaps()
        let authority = Authority()
        self.authority = authority
        self.allocator = allocator
        monotonicClock = clock
        executor = PlaybackControlExecutor(allocator: allocator, clock: clock,
            applyIngress: { authority.apply($0, allocator: allocator, instant: clock.nowNanoseconds) },
            applyTerminalIngress: { authority.foldTerminal($0) },
            applyOutputControl: { authority.applyOutputControl($0, snapshot: $1, allocator: allocator,
                instant: clock.nowNanoseconds) })
        executor.bindEventDrainRegistry(self)
    }

    deinit {
        // 已无runtime owner；原固定record里的等待必须结束，否则runner与Task彼此保留。
        // 不把cancel冒充join/物理静止；此处只唤醒没有在执行SDK的disposition尾。
        precondition(PlaybackExternalSyncProducerReservation().coverage(for: .registryDeinitialization) ==
            .baseSlot(.init(slot: .serializedUserControl, proof: .requiresRuntimeUnreachable)))
        executor.sync {
            for record in authority.commands {
                guard case .controllerCleanup(let runner) = record?.payload else { continue }
                let waiter = runner.dispositionWaiter
                runner.dispositionWaiter = nil
                let task = runner.task
                runner.task = nil
                task?.cancel()
                waiter?.resume()
            }
        }
    }

    func makePlaybackDeadlineTimer() -> any PlaybackDeadlineTimer {
        executor.makePlaybackDeadlineTimer(clock: monotonicClock)
    }

    func bindPlaybackRuntime(scheduler: PlaybackDeadlineScheduler, receiver: any PlaybackOwnedCleanupReceiving) {
        executor.sync {
            precondition(deadlineScheduler == nil && terminalReceiver == nil)
            deadlineScheduler = scheduler
            terminalReceiver = receiver
            reconcilePlaybackRuntime()
        }
    }

    func notifyPlaybackProgress() {
        reconcilePlaybackRuntime()
        progressSignal.signal()
    }

    @discardableResult
    func waitForPlaybackProgress(_ expected: PlaybackControlProgressWait) async -> Bool {
        await withCheckedContinuation { continuation in
            var acquisitionFailureOwner: OutputTransitionOwnerTicket?
            let registration: PlaybackControlProgressSignal.Registration = (try? transaction { _ in
                guard let context = authority.outputContext else { return .rejected }
                if case .acquisition(let ticket) = expected,
                   ticket.group == context.reservation.workGroup,
                   let owner = context.owner, owner.reason == .terminal,
                   context.disposition == .releaseAfterTeardown, !context.poisoned {
                    acquisitionFailureOwner = owner
                }
                let key: PlaybackControlProgressSignal.Key
                switch expected {
                case .acquisition(let ticket):
                    guard context.sourceTask == ticket, context.phase == .pendingLeaseAcquisition,
                          !context.poisoned, context.disposition != .releaseAfterTeardown,
                          case .coldStart(let admission) = authority.playbackRequestAdmission,
                          admission.identity.sessionIdentity == context.sessionIdentity else { return .rejected }
                    key = .init(phase: 0, nonce: ticket.nonce)
                case .route(let session):
                    guard context.sessionIdentity == session, !context.poisoned,
                          context.disposition != .releaseAfterTeardown,
                          case .coldStart(let admission) = authority.playbackRequestAdmission,
                          admission.identity.sessionIdentity == session else { return .rejected }
                    key = .init(phase: 1, nonce: context.contextNonce)
                case .cleanup(let owner):
                    guard context.owner == owner else { return .rejected }
                    key = .init(phase: 2, nonce: owner.identity.nonce)
                }
                return progressSignal.register(continuation, key: key)
            }) ?? .rejected
            // resume始终在Cell锁外；signal只交付进展，所有caller返回后再验原Authority。
            switch registration {
            case .parked: break
            case .ready: continuation.resume(returning: true)
            case .rejected:
                // 登记barrier可能刚消费terminal；先公开/启动原owner再交还caller。
                // stale/第二waiter本身不制造终态，唯一入口仍核对真实poisoned context。
                reconcilePlaybackRuntime()
                if let owner = acquisitionFailureOwner { startAudioSessionFailureCleanup(owner: owner) }
                continuation.resume(returning: false)
            }
        }
    }

    func reconcilePlaybackRuntime() {
        executor.sync {
            guard !reconcilingRuntime else { return }
            reconcilingRuntime = true
            defer { reconcilingRuntime = false }
            deadlineScheduler?.reconcile(playbackDeadlineScheduleSnapshot())
            consumeAutomaticTerminal()
        }
    }

    func playbackDeadlineScheduleSnapshot() -> PlaybackDeadlineScheduleSnapshot {
        projection {
            guard let context = authority.outputContext, !context.poisoned,
                  authority.snapshot.failure == nil else { return .init() }
            var value = PlaybackDeadlineScheduleSnapshot()
            value.acquisition = context.acquisitionDeadline
            value.cleanup = context.budget
            if case .pending(let pending) = authority.routeObservationState {
                value.ordinaryRoute = pending.ordinaryDeadlineState?.arm
            }
            if value.ordinaryRoute == nil,
               let inherited = context.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute {
                value.ordinaryRoute = .init(ticketIdentity: inherited.ticketIdentity, armNonce: inherited.timerArmIdentity)
            }
            if let state = authority.resetPreRouteState, state.runningSince != nil { value.resetPreRoute = state.deadlineArm }
            if let state = authority.postConfigurationRouteState, state.runningSince != nil {
                value.postConfiguration = .init(configurationTransitionIdentity: state.budget.configurationTransitionIdentity,
                    stageIdentity: state.budget.stageIdentity, configurationGeneration: state.budget.configurationGeneration,
                    parentOperationTicketIdentity: state.budget.parentOperationDeadline,
                    attemptNonce: state.budget.attemptNonce, freezeGeneration: state.freezeGeneration)
            }
            value.reactivation = authority.audioPhase?.reactivationState?.cutoffArmTicket
            if let original = context.parentDeadline {
                let parent: PlaybackProgressBudgetTicket
                switch original { case .coldStart(let p), .outputRecovery(let p): parent = p }
                if parent.runningSince != nil {
                    value.playbackOperation = .init(parentOperationTicketIdentity: parent.identity, freezeGeneration: parent.freezeGeneration)
                }
            }
            if !context.suspendConfirmed, !context.suspendRequiresRetirement,
               !context.suspendTimedOut { value.suspend = context.suspend }
            return value
        }
    }

    func makeStateStream() -> AsyncStream<PlaybackState> {
        let pair = AsyncStream.makeStream(of: PlaybackState.self, bufferingPolicy: .bufferingNewest(1))
        var previous: PlaybackStateSubscription?
        var installed = false
        executor.sync {
            let initial: (UInt64, PlaybackState)? = try? transaction { _ in
                let token = try allocator.next(in: .subscription)
                previous = authority.stateSubscription
                authority.stateSubscription = .init(token: token, continuation: pair.continuation)
                return (token, authority.publicState)
            }
            guard let (token, state) = initial else { return }
            pair.continuation.onTermination = { [weak self] _ in self?.endStateSubscription(token: token) }
            // Cell已解锁，executor仍排序；snapshot/安装/yield没有跨caller窗口。
            _ = pair.continuation.yield(state)
            installed = true
        }
        // finish可同步回调；旧token在新slot安装后失效，回调与析构均不在Cell锁内。
        previous?.continuation.finish()
        if !installed { pair.continuation.finish() }
        return pair.stream
    }

    func makeMediaStream(initial: PlaybackMediaInformation?) -> AsyncStream<PlaybackMediaInformation?> {
        let pair = AsyncStream.makeStream(of: PlaybackMediaInformation?.self, bufferingPolicy: .bufferingNewest(1))
        var previous: PlaybackMediaSubscription?
        var installed = false
        executor.sync {
            guard let token = try? transaction({ _ in try allocator.next(in: .subscription) }) else { return }
            pair.continuation.onTermination = { [weak self] _ in self?.endMediaSubscription(token: token) }
            _ = pair.continuation.yield(initial)
            installed = (try? transaction { _ in
                previous = authority.mediaSubscription
                authority.mediaSubscription = .init(token: token, continuation: pair.continuation)
                return true
            }) == true
        }
        previous?.continuation.finish()
        if !installed { pair.continuation.finish() }
        return pair.stream
    }

    private func endStateSubscription(token: UInt64) {
        PlaybackExternalSyncProducerReservation().requireFixedLedgerCharge(
            .ownedStateTerminationSyncBridge, for: .stateTermination)
        let released: PlaybackStateSubscription? = try? transaction { _ in
            guard let current = authority.stateSubscription, current.token == token else { return nil }
            authority.stateSubscription = nil
            return current
        }
        withExtendedLifetime(released) {}
    }

    private func endMediaSubscription(token: UInt64) {
        PlaybackExternalSyncProducerReservation().requireFixedLedgerCharge(
            .ownedMediaTerminationSyncBridge, for: .mediaTermination)
        let released: PlaybackMediaSubscription? = try? transaction { _ in
            guard let current = authority.mediaSubscription, current.token == token else { return nil }
            authority.mediaSubscription = nil
            return current
        }
        withExtendedLifetime(released) {}
    }

    func publishState(_ value: PlaybackState) {
        executor.sync {
            let current: PlaybackStateSubscription? = try? transaction { output in
                switch value {
                case .preparing, .buffering, .recovering, .paused, .playing:
                    guard authority.snapshot.failure == nil, authority.outputContext?.poisoned != true else { return nil }
                case .idle, .stopped, .failed: break
                }
                if case .playing = value {
                    guard output.outputPermitPresent, output.readinessOpen,
                          !authority.snapshot.interruptionVeto, !authority.snapshot.userPaused else { return nil }
                }
                guard authority.publicState != value else { return nil }
                authority.publicState = value
                return authority.stateSubscription
            }
            _ = current?.continuation.yield(value)
        }
    }

    func playbackStateSnapshot() -> PlaybackState {
        projection { authority.publicState }
    }

    /// 任意Cell fail-closed或准确预算终态都通过这一个锁外入口消费原预留owner。
    private func consumeAutomaticTerminal() {
        guard let receiver = terminalReceiver else { return }
        var subscription: PlaybackStateSubscription?
        var published = false
        var wake: CheckedContinuation<Void, Never>?
        let failure = PlaybackState.failed(.init(code: "playback.control-terminal",
            userMessage: "播放控制已到达安全边界，请重新选择频道。"))
        let owner: OutputTransitionOwnerTicket? = try? transaction { output in
            guard var context = authority.outputContext, context.poisoned,
                  let reservation = authority.cleanupReservation, reservation.ticket == context.reservation else { return nil }
            if authority.runningCleanupOwner(context.reservation) == nil {
                // 预算终态先预留owner，但不代表已准备backend的suspend/close。
                // 在启动原runner前把完整transition补齐；迟到prepare/activation只能被这条原链接走。
                guard let prepared = try AudioSessionLockedOperations(authority: authority, allocator: allocator,
                    instant: monotonicClock.nowNanoseconds).beginOutputTransitionLocked(contextNonce: context.contextNonce,
                        reason: .terminal, anchorInstant: monotonicClock.nowNanoseconds, teardown: true,
                        sourceActivation: nil, output: &output) else { return nil }
                context = authority.outputContext!
                context.owner = prepared
            }
            guard let owner = context.owner else { return nil }
            for record in authority.commands {
                guard let record, record.groupTicket == context.reservation.ownerGroup,
                      case .controllerCleanup(let runner) = record.payload else { continue }
                runner.terminalRequested = true
                wake = runner.dispositionWaiter
                runner.dispositionWaiter = nil
            }
            if case .coldStart(let admitted) = authority.playbackRequestAdmission,
               admitted.identity.sessionIdentity != context.sessionIdentity { return owner }
            authority.playbackRequestAdmission = nil
            if authority.publicState != failure {
                authority.publicState = failure
                subscription = authority.stateSubscription
                published = true
            }
            return owner
        }
        subscription?.continuation.yield(failure)
        wake?.resume()
        guard let owner else { return }
        // 已在执行的原cleanup不被替换；仅原owner可继续真实SDK/Task尾。
        let started = startOwnedTerminalCleanup(owner: owner, receiver: receiver, terminalState: failure)
        if started || published { progressSignal.signal() }
    }

    func publishMediaInformation(_ value: PlaybackMediaInformation?) {
        executor.sync {
            let current = try? transaction { _ in authority.mediaSubscription }
            _ = current?.continuation.yield(value)
        }
    }

    func startOutputFactoryOperation(_ ticket: ControlTaskTicket,
        input: OwnedPlaybackBackendOperation.FactoryInput) -> Bool {
        startOwnedBackendOperation(ticket, operation: .factory(input))
    }

    func startOutputPrepareOperation(_ ticket: ControlTaskTicket) -> Bool {
        startOwnedBackendOperation(ticket, operation: .prepare)
    }

    func startOutputActivationOperation(_ ticket: ControlTaskTicket) -> Bool {
        startOwnedBackendOperation(ticket, operation: .activation)
    }

    func startOutputSuspendOperation(_ ticket: ControlTaskTicket, owner: OutputTransitionOwnerTicket) -> Bool {
        startOwnedBackendOperation(ticket, operation: .suspend, suspendOwner: owner)
    }

    private func startOwnedBackendOperation(_ ticket: ControlTaskTicket,
        operation: OwnedPlaybackBackendOperation.Operation, suspendOwner: OutputTransitionOwnerTicket? = nil) -> Bool {
        var started = false
        executor.sync {
            let runner = OwnedPlaybackBackendOperation(operation: operation)
            guard (try? transaction({ _ in
                guard let context = authority.outputContext,
                      let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                      let record = authority.commands[index], record.slot == operation.slot,
                      record.phase == .queued, record.payload == nil,
                      authority.groups.contains(where: { $0?.ticket == ticket.group && $0?.sealed == false })
                else { return false }
                if case .suspend = operation {
                    guard context.suspend?.task == ticket, context.owner == suspendOwner,
                          suspendOwner?.reason == .pause else { return false }
                    // pause立即撤销原activation；物理调用与原Task仍保留，suspend body必须先join。
                    for index in 0..<32 where authority.commands[index]?.slot == .activation &&
                        authority.commands[index]?.groupTicket == context.reservation.workGroup {
                        authority.cancel(index)
                    }
                } else if context.sourceTask != ticket { return false }
                if case .factory(let input) = operation {
                    guard context.candidateBackendIdentity == input.identity,
                          context.desiredBackendKind == input.kind,
                          context.sessionIdentity.requestID == input.request.id else { return false }
                }
                authority.commands[index]?.payload = .backendOperation(runner)
                return true
            })) == true else { return }
            started = launchPreinstalledBackendOperation(ticket, runner: runner)
        }
        return started
    }

    /// record/payload 已在同一 safety transaction 完整安装后，唯一不可失败叶才
    /// 分配 Task 并把 handle 换入原 record。publication replacement 也复用此叶，
    /// 因而不会出现能力已消费但 suspend runner 尚未登记的窗口。
    private func launchPreinstalledBackendOperation(_ ticket: ControlTaskTicket,
        runner: OwnedPlaybackBackendOperation,
        publicationReplacement: BackendPublicationReplacementTransition? = nil
    ) -> Bool {
        precondition(executor.isIsolated, "backend Task 必须在唯一串行 executor 内建立并安装")
        let task = Task { [weak self, runner, publicationReplacement] in
            guard let self else { return }
            await self.performOwnedBackendOperation(
                ticket, runner: runner,
                publicationReplacement: publicationReplacement)
        }
        while true {
            switch executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership, operation: { _ in
                precondition(authority.commands.contains(where: {
                    $0?.controlTaskTicket == ticket && $0?.backendOperation === runner
                }), "原backend操作record必须持有Task换手尾")
                runner.task = task
            }) {
            case .retry, .rejected: continue
            case .performed:
                // launch 的所有 caller 均持有唯一串行 executor。新 Task 的首次
                // transaction 只能在本栈退出 executor 后进入，因而看到的必是已
                // 安装 handle 的同一 record；不需要额外 gate 或未记账 continuation。
                return true
            }
        }
    }

    private func performOwnedBackendOperation(_ ticket: ControlTaskTicket,
        runner: OwnedPlaybackBackendOperation,
        publicationReplacement: BackendPublicationReplacementTransition?
    ) async {
        defer { notifyPlaybackProgress() }
        if case .suspend = runner.operation {
            // 固定扫描原owner work图，只join正向backend调用，不join自己或另一cleanup。
            for index in 0..<32 {
                let predecessor: ControlTaskTicket? = try? transaction { _ in
                    guard let original = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                          original.backendOperation === runner,
                          let record = authority.commands[index], record.backendOperation != nil,
                          record.slot != .suspend, authority.isDescendant(record.groupTicket, of: ticket.group)
                    else { return nil }
                    return record.controlTaskTicket
                }
                if let predecessor { _ = await joinOutputBackendOperation(predecessor) }
            }
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("registry_perform_start_\(runner.operation.slot)")
        #endif
        let claimed = (try? transaction { output in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.backendOperation === runner else { return false }
            if case .suspend = runner.operation {
                guard authority.outputContext?.suspend?.task == ticket else { return false }
            } else if authority.outputContext?.sourceTask != ticket { return false }
            return try AudioSessionLockedOperations(authority: authority, allocator: allocator,
                instant: monotonicClock.nowNanoseconds).claimStart(ticket, output: &output)
        }) == true
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("registry_perform_claimed_\(claimed)_\(runner.operation.slot)")
        #endif
        var result = PlaybackBackendOperationResult.canceled
        if claimed {
            do {
                switch runner.operation {
                case .factory(let input):
                    let channelName = input.request.title.isEmpty ? input.request.channelID : input.request.title
                    let backend = try await input.factory.makeBackend(kind: input.kind, identity: input.identity,
                        tuning: input.tuning, channelID: channelName, url: input.request.streamURL,
                        eventSink: { [relay = input.relay] event in relay.send(event) })
                    result = try completeOutputFactory(ticket, candidate: backend) ? .succeeded : .canceled
                case .prepare:
                    let candidate: (any PlaybackBackend)? = try transaction { _ in
                        guard let context = authority.outputContext,
                              context.sourceTask == ticket,
                              let owned = authority.ownedBackendResources else { return nil }
                        return owned.object as? any PlaybackBackend
                    }
                    let replacementSlot = (candidate as?
                        any BackendPublicationReplacementAuthorityInstalling)?
                        .backendPublicationReplacementAuthoritySlot
                    let installedReplacement = replacementSlot?.currentAuthority()
                    let invocation: (any PlaybackBackend, BackendPrepareInvocation)? = try transaction { _ in
                        guard let context = authority.outputContext, context.sourceTask == ticket,
                              let prepare = context.prepareTicket, let owned = authority.ownedBackendResources,
                              owned.identity == prepare.backendIdentity, let lifecycle = owned.lifecycle,
                              lifecycle.backendIdentity == owned.identity,
                              let backend = candidate, owned.object === backend else { return nil }
                        let replacement: BackendPublicationReplacementAuthority
                        if replacementSlot != nil {
                            guard let installedReplacement,
                                  installedReplacement.registry === self,
                                  !installedReplacement.consumed,
                                  installedReplacement.sourceTaskNonce == ticket.nonce,
                                  installedReplacement.lifecycle == lifecycle else {
                                return nil
                            }
                            replacement = installedReplacement
                        } else {
                            replacement = BackendPublicationReplacementAuthority(
                                registry: self, sourceTask: ticket, prepareTicket: prepare,
                                lifecycle: lifecycle, contextNonce: context.contextNonce,
                                replacesRetiredLifecycle: false)
                        }
                        return (backend, .init(ticket: prepare,
                            replacementAuthority: replacement))
                    }
                    if let (backend, prepare) = invocation {
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.set("registry_prepare_calling_backend")
                        #endif
                        if prepare.replacementAuthority.replacesRetiredLifecycle {
                            try await backend.reprepare(invocation: prepare)
                        } else {
                            try await backend.prepare(invocation: prepare)
                        }
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.set("registry_prepare_backend_returned")
                        #endif
                        result = completeOutputPrepare(ticket) ? .succeeded : .canceled
                    } else {
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.set("registry_prepare_invocation_nil")
                        #endif
                    }
                case .activation:
                    let backend: (any PlaybackBackend)? = try transaction { _ in
                        guard let owned = authority.ownedBackendResources,
                              authority.outputContext?.sourceTask == ticket else { return nil }
                        return owned.object as? any PlaybackBackend
                    }
                    if let backend,
                       let interval = openOutputInterval(ticket,
                           itemGeneration: backend.outputItemGeneration) {
                        let invocation = BackendPositiveRateInvocation(
                            sourceTask: ticket, interval: interval,
                            capability: BackendPositiveRateCapability(registry: self))
                        try await backend.activateOutput(invocation: invocation)
                        result = revalidatePositiveRateInvocation(invocation) ? .succeeded : .canceled
                    }
                case .suspend:
                    let invocation: (any PlaybackBackend, BackendSuspendInvocation)? = try transaction { _ in
                        guard let context = authority.outputContext, let stop = context.suspend,
                              stop.task == ticket, let owned = authority.ownedBackendResources,
                              owned.lifecycle == stop.lifecycle, owned.identity == stop.lifecycle.backendIdentity,
                              let backend = owned.object as? any PlaybackBackend else { return nil }
                        if let close = context.closeClaim {
                            guard close.suspendTicket == stop, close.intervalKey == context.interval else { return nil }
                        } else if context.interval != nil {
                            return nil
                        }
                        guard let issuer = allocator.issuerIdentity else { return nil }
                        return (backend, BackendSuspendInvocation(registryIssuerIdentity: issuer,
                            suspendTicket: stop, closeClaim: context.closeClaim))
                    }
                    if let (backend, invocation) = invocation {
                        let suspended = await backend.suspendOutput(invocation: invocation)
                        result = completeOutputSuspend(suspended, invocation: invocation,
                            backend: backend)
                            ? .succeeded : .canceled
                        if case .requiresRetirement = suspended, case .succeeded = result {
                            // suspend 的合法失败结果只转移停止责任；物理退休确认前不释放屏障。
                            guard let owner = outputResourceContextSnapshot()?.owner,
                                  let retirement = try advanceOutputCleanup(owner: owner),
                                  let cleanup = claimOutputBackendCleanup(retirement, owner: owner),
                                  cleanup.lifecycle == invocation.lifecycle else {
                                result = .canceled
                                break
                            }
                            let retired = await cleanup.backend.retireOutput(epoch: invocation.lifecycle)
                            result = retired == .confirmedLocalOutputStopped &&
                                completeOutputRetirement(retirement, lifecycle: invocation.lifecycle)
                                ? .succeeded : .canceled
                        }
                    }
                }
            } catch is CancellationError {
                result = .canceled
            } catch {
                result = .failed((error as? PlaybackCoreError) ?? .demuxOpen(-1))
            }
        }
        if case .succeeded = result,
           case .suspend = runner.operation,
           let publicationReplacement,
           isCurrentBackendPublicationReplacement(
                publicationReplacement, ticket: ticket, runner: runner) {
            await performOwnedBackendPublicationReplacement(
                publicationReplacement,
                suspendTicket: ticket, suspendRunner: runner)
            return
        }
        if case .succeeded = result {} else {
            _ = requestCancel(ticket)
            switch runner.operation {
            case .factory:
                _ = try? completeOutputFactory(ticket, candidate: nil, notInvoked: claimed ? nil : runner)
            case .prepare: _ = completeOutputPrepare(ticket)
            case .activation, .suspend: break
            }
        }
        _ = try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.backendOperation === runner else { return }
            if case .succeeded = result,
               authority.commands[index]?.phase == .cancelRequested || authority.commands[index]?.phase == .terminal(.canceled) {
                runner.result = .canceled
            } else { runner.result = result }
            // 完成只结清原调用，保留runner及Task；原owner或等待caller在body退出后join。
            if authority.commands[index]?.phase == .running { authority.commands[index]?.phase = .terminal(.completed) }
            else if authority.commands[index]?.phase == .cancelRequested { authority.commands[index]?.phase = .terminal(.canceled) }
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("registry_perform_ended_\(result)")
        #endif
    }

    private func isCurrentBackendPublicationReplacement(
        _ pending: BackendPublicationReplacementTransition,
        ticket: ControlTaskTicket,
        runner: OwnedPlaybackBackendOperation
    ) -> Bool {
        (try? transaction { _ in
            guard pending.suspend.task == ticket,
                  let context = authority.outputContext,
                  context.owner == pending.owner,
                  context.suspend == pending.suspend,
                  let record = authority.commands.first(where: {
                    $0?.controlTaskTicket == ticket
                  }) ?? nil,
                  record.backendOperation === runner else { return false }
            return true
        }) == true
    }

    /// publication replacement 的旧 suspend runner 是唯一物理 Task：它先领取准确
    /// retirement 调用，待旧 item 退休后再把自己的 Task handle 原子换手到新
    /// prepare record。整个过程不创建未登记 Task，也不销毁仍需复用的 backend。
    private func performOwnedBackendPublicationReplacement(
        _ pending: BackendPublicationReplacementTransition,
        suspendTicket: ControlTaskTicket,
        suspendRunner: OwnedPlaybackBackendOperation
    ) async {
        guard pending.suspend.task == suspendTicket else {
            finishFailedBackendPublicationReplacement(
                ticket: suspendTicket, runner: suspendRunner)
            return
        }
        do {
            guard let retirement = try advanceOutputCleanup(owner: pending.owner),
                  retirement != suspendTicket,
                  let cleanup = claimOutputBackendCleanup(retirement, owner: pending.owner),
                  cleanup.lifecycle == pending.retiredLifecycle,
                  cleanup.backend.identity == pending.backendIdentity else {
                finishFailedBackendPublicationReplacement(
                    ticket: suspendTicket, runner: suspendRunner)
                return
            }
            let retirementResult = await cleanup.backend.retireOutput(
                epoch: pending.retiredLifecycle)
            guard retirementResult == .confirmedLocalOutputStopped,
                  completeOutputRetirement(
                    retirement, lifecycle: pending.retiredLifecycle),
                  let handoff = try handoffBackendPublicationReplacementToReprepare(
                    pending: pending,
                    suspendTicket: suspendTicket,
                    suspendRunner: suspendRunner) else {
                finishFailedBackendPublicationReplacement(
                    ticket: suspendTicket, runner: suspendRunner)
                return
            }
            await performOwnedBackendPublicationReprepare(handoff)
        } catch {
            finishFailedBackendPublicationReplacement(
                ticket: suspendTicket, runner: suspendRunner)
        }
    }

    /// 退休旧 item 后，以同一 stable route 权威重建 work cycle。这里仅签发新的
    /// lifecycle/prepare invocation；generation、URL、publication 以及 response
    /// capability 均由 backend 的真实 replacement bundle 提供。
    private func handoffBackendPublicationReplacementToReprepare(
        pending: BackendPublicationReplacementTransition,
        suspendTicket: ControlTaskTicket,
        suspendRunner: OwnedPlaybackBackendOperation
    ) throws -> BackendPublicationReprepareHandoff? {
        let backendObject: (any OwnedPlaybackResource)? = projection {
            authority.ownedBackendResources?.object
        }
        guard let backend = backendObject as? any PlaybackBackend,
              let replacementSlot = (backendObject as?
                any BackendPublicationReplacementAuthorityInstalling)?
                .backendPublicationReplacementAuthoritySlot,
              replacementSlot.currentAuthority() === pending.capability
        else { return nil }
        let prepareRunner = OwnedPlaybackBackendOperation(operation: .prepare)
        return try transaction(operationDescriptor: .resourceOwnership) { output in
            guard case .quiescentBackend(var context, var resources) = authority.resourceState,
                  backendObject === resources.object,
                  resources.object === backend,
                  resources.identity == pending.backendIdentity,
                  resources.lifecycle == nil,
                  context.owner == pending.owner,
                  pending.owner.reason == .recovery,
                  context.contextNonce == pending.originalContextNonce,
                  context.suspend == pending.suspend,
                  context.suspendConfirmed,
                  !context.suspendTimedOut,
                  context.retirementConfirmed,
                  context.retiredLifecycle == pending.retiredLifecycle,
                  context.disposition == .retainForSession(context.sessionIdentity),
                  !context.poisoned, context.pendingReset == nil,
                  let suspendIndex = authority.commands.firstIndex(where: {
                    $0?.controlTaskTicket == suspendTicket
                  }),
                  let suspendRecord = authority.commands[suspendIndex],
                  suspendRecord.backendOperation === suspendRunner,
                  suspendRecord.phase == .terminal(.completed),
                  suspendRunner.task != nil,
                  let stableCommit = authority.stableRouteCommit,
                  let current = authority.currentRouteAuthority(),
                  stableCommit.authority == current,
                  current.semanticIdentity != nil,
                  current.systemOpenConfigurationGeneration
                    == current.audioSessionConfigurationGeneration,
                  let backendKind = current.semanticIdentity?.backend,
                  backendKind == context.desiredBackendKind,
                  !authority.snapshot.interruptionVeto,
                  parentAllowsWork(
                    context.parentDeadline, at: monotonicClock.nowNanoseconds)
            else { return nil }

            // 旧 owner/work 图除当前 Task record 外必须都已达到可退休终态。
            // owner root 是纯值 cleanup 责任，可与其余终态 record 同批换手。
            var retiringMask: UInt32 = 0
            for index in authority.commands.indices where index != suspendIndex {
                guard let record = authority.commands[index],
                      record.groupTicket == context.reservation.ownerGroup ||
                        record.groupTicket == context.reservation.workGroup ||
                        authority.isDescendant(
                            record.groupTicket, of: context.reservation.workGroup)
                else { continue }
                switch record.phase {
                case .terminal:
                    guard authority.mayDiscard(record) else { return nil }
                case .running:
                    guard record.groupTicket == context.reservation.ownerGroup,
                          record.slot == ReservedCleanupStage.owner.slot,
                          record.payload == nil else { return nil }
                case .queued, .cancelRequested:
                    return nil
                }
                retiringMask |= 1 << index
            }

            // prepareOutputCycle 的替换校验需要看到当前 Task 的物理结果；设置后
            // 所有后续步骤都只操作局部 prepared 值，直到 slot install 的不可失败叶。
            suspendRunner.result = .succeeded
            guard let cycle = try authority.prepareOutputCycleLocked(
                &context,
                replacingRetiredCommandIndex: suspendIndex,
                retiringCommandMask: retiringMask,
                allocator: allocator) else {
                suspendRunner.result = nil
                return nil
            }
            let rebasedNonce = try allocator.next(in: .nonce)
            let rebase = OutputRetainedRebaseResult(
                contextNonce: rebasedNonce, owner: pending.owner,
                stableCommit: stableCommit, successorClaim: nil)
            let lifecycle = OutputLifecycleEpoch(
                backendIdentity: resources.identity,
                outputNonce: try allocator.next(in: .outputLifecycle))
            let prepareTicket = PrepareTicket(
                backendIdentity: resources.identity,
                stableRouteCommitEpoch: stableCommit.epoch,
                audioAdmissionFenceRevision: current.audioAdmissionFenceRevision,
                prepareNonce: try allocator.next(in: .prepare))
            let command = try authority.prepareCommand(
                group: cycle.reservation.ticket.workGroup,
                slot: .prepare, policy: .routeSpeculativeRateZero,
                audioIdentity: nil, audioPolicy: nil,
                preparedCycle: cycle,
                replacingRetiredCommandIndex: suspendIndex,
                retiringCommandMask: retiringMask,
                allocator: allocator)
            let replacement = BackendPublicationReplacementAuthority(
                registry: self, sourceTask: command.ticket,
                prepareTicket: prepareTicket, lifecycle: lifecycle,
                contextNonce: rebasedNonce,
                replacesRetiredLifecycle: true)
            guard replacementSlot.install(
                replacement, backendObject: resources.object) else {
                suspendRunner.result = nil
                return nil
            }

            // 从这里开始均为固定槽写入，不再分配、不再调用外部实现。
            for index in authority.commands.indices
                where retiringMask & (1 << index) != 0 {
                authority.commands[index] = nil
            }
            authority.installOutputCycleLocked(cycle, context: &context)
            context.contextNonce = rebasedNonce
            context.mediaServicesEpoch = current.mediaServicesEpoch
            context.interruptionEpoch = current.interruptionEpoch
            context.audioAdmissionFenceRevision =
                current.audioAdmissionFenceRevision
            context.desiredBackendKind = backendKind
            context.claimOrigin = .replacement(pending.owner)
            context.retainedRebase = rebase
            context.prepareTicket = prepareTicket
            context.sourceTask = command.ticket
            context.retirementConfirmed = false
            context.retiredLifecycle = nil
            context.retainedRebase = nil
            context.prepared = false
            context.owner = nil
            resources.lifecycle = lifecycle
            authority.resourceState = .installed(context, resources)
            authority.registeredDrainProof = nil
            var prepareRecord = command.record!
            prepareRecord.payload = .backendOperation(prepareRunner)
            authority.commands[command.index] = prepareRecord
            prepareRunner.task = suspendRunner.task
            // recovery suspend 为禁止旧 item 继续输出而关闭 route gate；只有这里在同一
            // Cell 内复验原 stable authority 未变后，才为新 item 的 rate-0 prepare 重开。
            // 正 rate permit/readiness 仍保持关闭，必须由新 prepare/activation 重新签发。
            output.routeObservationGateOpen = true
            return .init(ticket: command.ticket, runner: prepareRunner,
                backend: backend, invocation: .init(
                    ticket: prepareTicket,
                    replacementAuthority: replacement),
                shouldReactivate: pending.shouldReactivate)
        }
    }

    private func performOwnedBackendPublicationReprepare(
        _ handoff: BackendPublicationReprepareHandoff
    ) async {
        let claimed = (try? transaction { output in
            guard let context = authority.outputContext,
                  context.sourceTask == handoff.ticket,
                  let record = authority.commands.first(where: {
                    $0?.controlTaskTicket == handoff.ticket
                  }) ?? nil,
                  record.backendOperation === handoff.runner else { return false }
            return try AudioSessionLockedOperations(
                authority: authority, allocator: allocator,
                instant: monotonicClock.nowNanoseconds
            ).claimStart(handoff.ticket, output: &output)
        }) == true
        var result = PlaybackBackendOperationResult.canceled
        if claimed {
            do {
                try await handoff.backend.reprepare(
                    invocation: handoff.invocation)
                result = completeOutputPrepare(handoff.ticket)
                    ? .succeeded : .canceled
            } catch is CancellationError {
                result = .canceled
            } catch {
                result = .failed(
                    (error as? PlaybackCoreError) ?? .demuxOpen(-1))
            }
        }
        if case .succeeded = result {} else {
            _ = requestCancel(handoff.ticket)
            _ = completeOutputPrepare(handoff.ticket)
        }
        _ = try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: {
                $0?.controlTaskTicket == handoff.ticket
            }),
            authority.commands[index]?.backendOperation === handoff.runner
            else { return }
            handoff.runner.result = result
            if authority.commands[index]?.phase == .running {
                authority.commands[index]?.phase = .terminal(.completed)
            } else if authority.commands[index]?.phase == .cancelRequested {
                authority.commands[index]?.phase = .terminal(.canceled)
            }
        }
        guard case .succeeded = result, handoff.shouldReactivate,
              let context = outputResourceContextSnapshot(), context.prepared,
              let activation = try? beginOutputActivation(
                contextNonce: context.contextNonce
              ),
              startOutputActivationOperation(activation) else { return }
        // 旧 item 在自然终点前持有正 rate interval 时，新 publication 仍属于同一
        // 用户播放意图。Registry 在新 lifecycle 上重新签发正式 activation；backend
        // 不能绕过该权威直接调用 AVPlayer.play()。
        _ = await joinOutputBackendOperation(activation)
    }

    private func finishFailedBackendPublicationReplacement(
        ticket: ControlTaskTicket,
        runner: OwnedPlaybackBackendOperation
    ) {
        _ = try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: {
                $0?.controlTaskTicket == ticket
            }), authority.commands[index]?.backendOperation === runner else {
                return
            }
            runner.result = .failed(.demuxOpen(-1))
            if authority.commands[index]?.phase == .running {
                authority.commands[index]?.phase = .terminal(.completed)
            } else if authority.commands[index]?.phase == .cancelRequested {
                authority.commands[index]?.phase = .terminal(.canceled)
            }
            authority.outputContext?.poisoned = true
            authority.outputContext?.teardownRequested = true
        }
    }

    func joinOutputBackendOperation(_ ticket: ControlTaskTicket) async -> PlaybackBackendOperationResult {
        let runner: OwnedPlaybackBackendOperation? = try? transaction { _ in
            authority.commands.first(where: { $0?.controlTaskTicket == ticket })??.backendOperation
        }
        guard let runner else { return .canceled }
        await runner.task?.value
        return (try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  case .terminal = authority.commands[index]?.phase,
                  authority.commands[index]?.backendOperation === runner,
                  runner.factoryResult == nil, let result = runner.result else { return .canceled }
            // completion 留在原固定 record，直到 owner 显式退休；同一 ticket
            // 的并发或晚到 caller 都读取同一物理终态，不复制底层 Task。
            return result
        }) ?? .canceled
    }

    func joinOutputBackendOperations(owner: OutputTransitionOwnerTicket) async -> Bool {
        var cursor = 0
        while cursor < 32 {
            let ticket: ControlTaskTicket? = try? transaction { _ in
                guard let context = authority.outputContext, context.owner == owner else { cursor = 32; return nil }
                while cursor < 32 {
                    let index = cursor
                    cursor += 1
                    guard let record = authority.commands[index], record.backendOperation != nil,
                          record.groupTicket == context.reservation.ownerGroup ||
                            authority.isDescendant(record.groupTicket, of: context.reservation.ownerGroup) else { continue }
                    return record.controlTaskTicket
                }
                return nil
            }
            if let ticket { _ = await joinOutputBackendOperation(ticket) }
        }
        return outputResourceContextSnapshot()?.owner == owner
    }

    /// receiver只提交原owner；任务分配、handle换手及退出尾部均留在原固定record。
    func startOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
        receiver: any PlaybackOwnedCleanupReceiving, terminalState: PlaybackState) -> Bool {
        startOwnedCleanup(owner: owner, receiver: receiver, terminalState: terminalState)
    }

    /// 真实SDK失败在同锁completion签发terminal owner；只借原图relay中的接收者，不能投到新session。
    func startAudioSessionFailureCleanup(owner: OutputTransitionOwnerTicket) {
        let receiver: (any PlaybackOwnedCleanupReceiving)? = try? transaction { _ in
            guard let context = authority.outputContext, context.owner == owner,
                  owner.reason.releasesLease else { return nil }
            for record in authority.commands {
                guard let record, record.slot == .systemEventRelay,
                      case .eventDrain(let runner) = record.payload,
                      case .audio(let relay) = runner.relay else { continue }
                return relay.terminalReceiver
            }
            return nil
        }
        guard let receiver else { return }
        let failure = PlaybackState.failed(.init(code: "audio.session.activation",
            userMessage: "无法启用音频播放，请检查播放设备后重试。"))
        executor.sync {
            _ = startOwnedTerminalCleanup(owner: owner, receiver: receiver, terminalState: failure)
            let subscription: PlaybackStateSubscription? = try? transaction { _ in
                guard let context = authority.outputContext, context.owner == owner,
                      context.disposition == .releaseAfterTeardown, !context.poisoned,
                      authority.runningCleanupOwner(context.reservation) == owner else { return nil }
                if case .coldStart(let admission) = authority.playbackRequestAdmission,
                   admission.identity.sessionIdentity != context.sessionIdentity { return nil }
                guard authority.publicState != failure else { return nil }
                authority.publicState = failure
                return authority.stateSubscription
            }
            subscription?.continuation.yield(failure)
        }
    }

    func startOwnedInterruptionCleanup(owner: OutputTransitionOwnerTicket,
        receiver: any PlaybackOwnedInterruptionCleanupReceiving) -> Bool {
        startOwnedCleanup(owner: owner, receiver: receiver, terminalState: nil)
    }

    private func startOwnedCleanup(owner: OutputTransitionOwnerTicket,
        receiver: any PlaybackOwnedCleanupReceiving, terminalState: PlaybackState?) -> Bool {
        var started = false
        executor.sync {
            let runner = OwnedPlaybackCleanupTask(owner: owner, receiver: receiver)
            let ticket: ControlTaskTicket? = try? transaction { output in
                guard let context = authority.outputContext, context.owner == owner,
                      terminalState == nil ? owner.reason == .recovery : owner.reason.releasesLease,
                      let index = authority.commands.firstIndex(where: {
                          $0?.groupTicket == context.reservation.ownerGroup &&
                          $0?.slot == ReservedCleanupStage.owner.slot
                      }), let record = authority.commands[index], record.payload == nil
                else { return nil }
                // 外部join已确认原runner退出并清掉payload，但root record继续running
                // 保留清理责任；新terminal owner只在这个原槽内接手，不能重新claimStart。
                guard try record.phase == .running ||
                    AudioSessionLockedOperations(authority: authority, allocator: allocator,
                        instant: monotonicClock.nowNanoseconds).claimStart(record.controlTaskTicket, output: &output)
                else { return nil }
                authority.commands[index]?.payload = .controllerCleanup(runner)
                return record.controlTaskTicket
            }
            guard let ticket else { return }
            let task = Task { [weak self, weak runner] in
                do {
                    guard let current = runner, self?.claimOwnedCleanupBody(ticket, runner: current) == true else { return }
                    if let terminalState {
                        await current.receiver?.performOwnedTerminalCleanup(owner: owner, task: ticket, terminalState: terminalState)
                        return
                    }
                    // receiver/runner只在真实调用期间借用，不能跨无限disposition等待。
                    await (current.receiver as? any PlaybackOwnedInterruptionCleanupReceiving)?
                        .performOwnedInterruptionCleanup(owner: owner, task: ticket)
                }
                await withCheckedContinuation { [weak self, weak runner] continuation in
                    guard let current = runner,
                          self?.registerOwnedCleanupDisposition(continuation, ticket: ticket, runner: current) == true else {
                        continuation.resume()
                        return
                    }
                }
                guard let current = runner, let terminal = self?.upgradeOwnedCleanupToTerminal(ticket, runner: current),
                      let state = self?.playbackStateSnapshot() else { return }
                await current.receiver?.performOwnedTerminalCleanup(owner: terminal, task: ticket, terminalState: state)
            }
            // executor仍串行占有本次换手；安全事件可以撤权，但不能删除带payload的原record。
            while true {
                switch executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership, operation: { _ in
                    precondition(authority.commands.contains(where: {
                        guard $0?.controlTaskTicket == ticket,
                              case .controllerCleanup(let current) = $0?.payload else { return false }
                        return current === runner
                    }))
                    runner.task = task
                }) {
                case .retry, .rejected: continue
                case .performed: started = true; return
                }
            }
        }
        return started
    }

    private func claimOwnedCleanupBody(_ ticket: ControlTaskTicket, runner: OwnedPlaybackCleanupTask) -> Bool {
        (try? transaction { _ in
            guard authority.outputContext?.owner == runner.owner,
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .running, case .controllerCleanup(let current) = record.payload else { return false }
            return current === runner
        }) == true
    }

    private func registerOwnedCleanupDisposition(_ continuation: CheckedContinuation<Void, Never>,
        ticket: ControlTaskTicket, runner: OwnedPlaybackCleanupTask) -> Bool {
        (try? transaction { _ in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  case .controllerCleanup(let current) = record.payload, current === runner,
                  !runner.joinRequested, !runner.terminalRequested,
                  authority.outputContext?.poisoned != true else { return false }
            runner.dispositionWaiter = continuation
            return true
        }) == true
    }

    private func upgradeOwnedCleanupToTerminal(_ ticket: ControlTaskTicket,
        runner: OwnedPlaybackCleanupTask) -> OutputTransitionOwnerTicket? {
        try? transaction { output in
            guard let context = authority.outputContext, context.owner == runner.owner, context.poisoned,
                  !runner.recoveryReturnCommitted,
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  case .controllerCleanup(let current) = record.payload, current === runner,
                  let terminal = try AudioSessionLockedOperations(authority: authority, allocator: allocator,
                    instant: monotonicClock.nowNanoseconds).beginOutputTransitionLocked(contextNonce: context.contextNonce,
                        reason: .terminal, anchorInstant: monotonicClock.nowNanoseconds, teardown: true,
                        sourceActivation: nil, output: &output) else { return nil }
            runner.owner = terminal
            return terminal
        }
    }

    /// 资源终态与Task退出分开：清空已释放资源形态，但不退休仍执行的cleanup record。
    func finishOwnedCleanupResources(_ ticket: ControlTaskTicket, owner: OutputTransitionOwnerTicket) -> Bool {
        defer { notifyPlaybackProgress() }
        return (try? transaction { _ in
            guard authority.outputContext?.owner == owner, authority.ownedResource == nil,
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .running, case .controllerCleanup(let runner) = record.payload,
                  runner.owner == owner else { return false }
            if let reservation = authority.cleanupReservation, reservation.terminal {
                // 只释放业务图；唯一root record/Task仍作为未join尾保留，不能冒充Task已经退出。
                for index in authority.commands.indices {
                    guard let record = authority.commands[index], record.controlTaskTicket != ticket,
                          record.groupTicket == reservation.ticket.ownerGroup ||
                            authority.isDescendant(record.groupTicket, of: reservation.ticket.ownerGroup) else { continue }
                    guard case .terminal = record.phase, authority.mayDiscard(record) else { return false }
                }
                var groups: UInt32 = 0
                for index in authority.groups.indices {
                    guard let group = authority.groups[index]?.ticket,
                          group == reservation.ticket.ownerGroup ||
                            authority.isDescendant(group, of: reservation.ticket.ownerGroup) else { continue }
                    groups |= 1 << index
                }
                for index in authority.commands.indices {
                    guard let record = authority.commands[index], record.controlTaskTicket != ticket,
                          record.groupTicket == reservation.ticket.ownerGroup ||
                            authority.isDescendant(record.groupTicket, of: reservation.ticket.ownerGroup) else { continue }
                    authority.commands[index] = nil
                }
                for index in authority.groups.indices where groups & (1 << index) != 0 { authority.groups[index] = nil }
                authority.cleanupReservation = nil
            }
            authority.resourceState = nil
            authority.authoritativeRoute = .unknown
            authority.routeObservationState = nil
            authority.stableRouteCommit = nil
            authority.routeSampleClaim = nil
            authority.routeStabilityCandidate = nil
            return true
        }) == true
    }

    /// stop/new-play在启动任何后继前真实join；只有同一handle的尾部可被原CAS清除。
    func joinOwnedTerminalCleanup(session: PlaybackSessionIdentity? = nil) async {
        defer { notifyPlaybackProgress() }
        for index in 0..<32 {
            var wake: CheckedContinuation<Void, Never>?
            let retained: (ControlTaskTicket, OwnedPlaybackCleanupTask)? = try? transaction { _ in
                guard let record = authority.commands[index],
                      case .controllerCleanup(let runner) = record.payload else { return nil }
                if let session, record.groupTicket.resourceIdentity != .session(session) { return nil }
                runner.joinRequested = true
                wake = runner.dispositionWaiter
                runner.dispositionWaiter = nil
                return (record.controlTaskTicket, runner)
            }
            wake?.resume()
            guard let (ticket, runner) = retained else { continue }
            await runner.task?.value
            let reservation: CleanupReservationTicket? = try? transaction { _ in
                guard authority.commands[index]?.controlTaskTicket == ticket,
                      case .controllerCleanup(let current) = authority.commands[index]?.payload,
                      current === runner else { return nil }
                authority.commands[index]?.payload = nil
                if authority.resourceState == nil {
                    if authority.cleanupReservation == nil { authority.commands[index] = nil; return nil }
                    authority.commands[index]?.phase = .terminal(.completed)
                    return authority.cleanupReservation?.ticket
                }
                return nil
            }
            if let reservation { _ = releaseCleanupReservation(reservation) }
        }
    }

    func joinAutomaticCleanupTailBeforeAdmission() async {
        await joinOwnedTerminalCleanup()
    }

    /// audio receiver不能等待会反向join自己的terminal阶段。CAS先决定正常退出或终态接管。
    func finishAudioEventRecoveryDisposition(owner: OutputTransitionOwnerTicket) async -> Bool {
        var wake: CheckedContinuation<Void, Never>?
        var accepted = false
        let retained: (ControlTaskTicket, OwnedPlaybackCleanupTask)? = try? transaction { _ in
            guard let context = authority.outputContext, context.owner == owner,
                  owner.reason == .recovery, !context.poisoned,
                  context.disposition != .releaseAfterTeardown else { return nil }
            guard let record = authority.commands.first(where: {
                $0?.groupTicket == context.reservation.ownerGroup && $0?.slot == ReservedCleanupStage.owner.slot
            }) ?? nil, case .controllerCleanup(let runner) = record.payload else {
                accepted = true
                return nil
            }
            guard runner.owner == owner, !runner.terminalRequested else { return nil }
            // 正常退出先赢后，迟到terminal由这个handle真实join后接手；原Task不再转向audio join。
            runner.recoveryReturnCommitted = true
            runner.joinRequested = true
            wake = runner.dispositionWaiter
            runner.dispositionWaiter = nil
            accepted = true
            return (record.controlTaskTicket, runner)
        }
        wake?.resume()
        if let (ticket, runner) = retained {
            await runner.task?.value
            _ = try? transaction { _ in
                guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                      case .controllerCleanup(let current) = authority.commands[index]?.payload,
                      current === runner else { return }
                authority.commands[index]?.payload = nil
            }
            notifyPlaybackProgress()
        }
        return accepted && outputResourceContextSnapshot()?.owner == owner &&
            outputResourceContextSnapshot()?.poisoned == false
    }

    func bindEventRelay(_ relay: PlaybackSessionEventRelay, to ticket: ControlTaskTicket) -> Bool {
        bindEventRelay(.pipeline(relay), to: ticket)
    }

    /// 物理callback不等待executor；同Cell锁只借当前原relay，离锁发送后由原ticket再次CAS消费。
    func forwardAudioSessionEvent(_ envelope: PlaybackAudioSessionEventEnvelope) {
        guard let relay = executor.safetyIngress.currentOwnedAudioEventRelay() else { return }
        relay.send(lease: relay.lease, event: envelope)
    }

    func deactivateOutputEventRelays(session: PlaybackSessionIdentity) {
        for index in 0..<32 {
            let borrowed: OwnedPlaybackEventDrain? = try? transaction { _ in
                guard let context = authority.outputContext, context.sessionIdentity == session,
                      let record = authority.commands[index],
                      authority.isDescendant(record.groupTicket, of: context.reservation.ownerGroup),
                      case .eventDrain(let runner) = record.payload else { return nil }
                return runner
            }
            borrowed?.relay.deactivate()
        }
    }

    func audioSessionLease(session: PlaybackSessionIdentity) -> PlaybackAudioSessionLease? {
        projection {
            guard authority.outputContext?.sessionIdentity == session, let lease = authority.ownedLeaseResources,
                  let registration = lease.object as? PlaybackAudioSessionRegistration,
                  authority.ownsRegistration(registration, allowsClosing: false) else { return nil }
            return .init(id: lease.leaseID, generation: lease.leaseID)
        }
    }

    func startPreparedSampleBuffer(contextNonce: UInt64, backendIdentity: PlaybackBackendIdentity,
        readinessCycle: UInt64, initiallyPaused: Bool) {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_begin")
        #endif
        let backend: SampleBufferPlaybackBackend? = try? transaction { _ in
            guard let context = authority.outputContext else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_no_context")
                #endif
                return nil
            }
            guard context.contextNonce == contextNonce else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_nonce_mismatch_\(context.contextNonce)_\(contextNonce)")
                #endif
                return nil
            }
            guard context.prepared else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_not_prepared")
                #endif
                return nil
            }
            guard context.owner == nil else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_has_owner")
                #endif
                return nil
            }
            guard let owned = authority.ownedBackendResources else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_no_owned_resources")
                #endif
                return nil
            }
            guard owned.identity == backendIdentity else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_identity_mismatch")
                #endif
                return nil
            }
            return owned.object as? SampleBufferPlaybackBackend
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("startPreparedSampleBuffer_backend_\(backend != nil)")
        #endif
        backend?.startPipeline(readinessCycle: readinessCycle, initiallyPaused: initiallyPaused)
    }

    func updatePreparedSampleBufferPause(contextNonce: UInt64, paused: Bool, readinessCycle: UInt64) {
        let backend: SampleBufferPlaybackBackend? = try? transaction { _ in
            guard let context = authority.outputContext, context.contextNonce == contextNonce,
                  context.prepared, context.owner == nil else { return nil }
            return authority.ownedBackendResources?.object as? SampleBufferPlaybackBackend
        }
        backend?.pipeline?.setPaused(paused, readinessCycle: readinessCycle)
    }

    func updateInstalledSampleBufferTuning(_ tuning: PlaybackTuning) {
        let backend: SampleBufferPlaybackBackend? = try? transaction { _ in
            guard authority.outputContext?.owner == nil else { return nil }
            return authority.ownedBackendResources?.object as? SampleBufferPlaybackBackend
        }
        backend?.pipeline?.setTuning(tuning)
    }

    enum PresentationCommitResult: Sendable, Equatable {
        case committed
        case supersededBySafety
    }

    private struct InstalledPresentationCandidate {
        let context: OutputResourceContext
        let backendIdentity: PlaybackBackendIdentity
        let lifecycle: OutputLifecycleEpoch
        let presentation: PlaybackPresentation
    }

    /// 所有presentation发布与mount claim复用同一份最终installed/safety投影。
    private func installedPresentationCandidateLocked(
        output: PlaybackOutputSafetyState
    ) -> InstalledPresentationCandidate? {
        guard authority.snapshot.failure == nil,
              !authority.snapshot.interruptionVeto,
              case .installed(let context, let backend) = authority.resourceState,
              context.phase == .installed,
              context.prepared,
              context.sourceTask == nil,
              context.owner == nil,
              context.suspend == nil,
              context.pendingReset == nil,
              !context.interruptionDrainRequired,
              !context.poisoned,
              !context.relayClosing,
              !context.teardownRequested,
              context.disposition == .retainForSession(context.sessionIdentity),
              context.sessionIdentity == backend.identity.sessionIdentity,
              case .coldStart(let admission) = authority.playbackRequestAdmission,
              admission.identity.sessionIdentity == context.sessionIdentity,
              context.candidateBackendIdentity == backend.identity,
              let lifecycle = backend.lifecycle,
              lifecycle.backendIdentity == backend.identity,
              let prepare = context.prepareTicket,
              prepare.backendIdentity == backend.identity,
              prepare.audioAdmissionFenceRevision == context.audioAdmissionFenceRevision,
              context.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
              context.interruptionEpoch == authority.snapshot.interruptionEpoch,
              context.audioAdmissionFenceRevision == authority.snapshot.audioAdmissionFenceRevision,
              let reservation = authority.cleanupReservation,
              reservation.ticket == context.reservation,
              !reservation.terminal,
              reservation.consumedConversions == 0,
              let stable = authority.stableRouteCommit,
              stable.epoch == prepare.stableRouteCommitEpoch,
              let current = currentOutputRouteAuthorityLocked(),
              stable.exactlyMatches(current, observationGateOpen: output.routeObservationGateOpen),
              current.semanticIdentity?.backend == context.desiredBackendKind,
              let presentation = (backend.object as? any PlaybackBackend)?.presentation else {
            return nil
        }
        return .init(
            context: context,
            backendIdentity: backend.identity,
            lifecycle: lifecycle,
            presentation: presentation
        )
    }

    /// UI在engine.play返回后才申领mount；此时cold-start预算可已消费，
    /// 但installed backend、route/fence与safety必须仍是当前值。
    private func currentMountablePresentationLocked(
        output: PlaybackOutputSafetyState
    ) -> InstalledPresentationCandidate? {
        guard authority.snapshot.failure == nil,
              !authority.snapshot.interruptionVeto,
              case .installed(let context, let backend) = authority.resourceState,
              context.phase == .installed,
              context.prepared,
              context.owner == nil,
              context.suspend == nil,
              context.pendingReset == nil,
              !context.interruptionDrainRequired,
              !context.poisoned,
              !context.relayClosing,
              !context.teardownRequested,
              context.disposition == .retainForSession(context.sessionIdentity),
              context.sessionIdentity == backend.identity.sessionIdentity,
              context.candidateBackendIdentity == backend.identity,
              let lifecycle = backend.lifecycle,
              lifecycle.backendIdentity == backend.identity,
              let prepare = context.prepareTicket,
              prepare.backendIdentity == backend.identity,
              prepare.audioAdmissionFenceRevision == context.audioAdmissionFenceRevision,
              context.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
              context.interruptionEpoch == authority.snapshot.interruptionEpoch,
              context.audioAdmissionFenceRevision == authority.snapshot.audioAdmissionFenceRevision,
              let reservation = authority.cleanupReservation,
              reservation.ticket == context.reservation,
              !reservation.terminal,
              let stable = authority.stableRouteCommit,
              stable.epoch == prepare.stableRouteCommitEpoch,
              let current = currentOutputRouteAuthorityLocked(),
              stable.exactlyMatches(current, observationGateOpen: output.routeObservationGateOpen),
              current.semanticIdentity?.backend == context.desiredBackendKind,
              let presentation = (backend.object as? any PlaybackBackend)?.presentation else {
            return nil
        }
        return .init(
            context: context,
            backendIdentity: backend.identity,
            lifecycle: lifecycle,
            presentation: presentation
        )
    }

    /// 最终route/safety fence与Relay固定状态提交属于同一个权威事务；continuation副作用锁外执行。
    func commitInstalledPresentation(
        to relay: PlaybackPresentationRelay
    ) throws -> PresentationCommitResult {
        let outcome: PlaybackPresentationRelay.PreparedReplacementOutcome?
        do {
            outcome = try transaction(operationDescriptor: .prepareAdmission) { output in
                guard let candidate = installedPresentationCandidateLocked(output: output) else { return nil }
                let identity = PresentationIdentity(
                    sessionIdentity: candidate.context.sessionIdentity,
                    backendIdentity: candidate.backendIdentity,
                    outputLifecycleEpoch: candidate.lifecycle,
                    itemGeneration: nil,
                    presentationNonce: try allocator.next(in: .presentation)
                )
                return relay.prepareAuthoritativeReplacement(with: .init(
                    identity: identity,
                    presentation: candidate.presentation
                ))
            }
        } catch PlaybackIdentityAllocationError.identitySpaceExhausted {
            consumeCheckedIdentityExhaustion()
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        } catch is ControlTaskRegistry.Failure {
            // Safety ingress在同一transaction先线性化时，这是合法的提交拒绝，不是异常逃逸。
            return .supersededBySafety
        }
        guard let outcome else { return .supersededBySafety }
        switch outcome {
        case .prepared(let delivery):
            relay.deliver(delivery)
            return .committed
        case .identitySpaceExhausted(let terminalDelivery):
            // 先把最终nil/EOF交付，再允许automatic owner开始真实backend teardown。
            relay.deliver(terminalDelivery)
            allocator.markIdentitySpaceExhausted()
            consumeCheckedIdentityExhaustion()
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        case .terminal(let empty):
            relay.deliver(empty)
            throw PlaybackPresentationRelayError.terminal
        }
    }

    /// UI挂载身份与完整replacement在同一Cell/Relay fence核对并签发完整owner。
    func claimPresentationMountOwnership(for replacement: PlaybackPresentationReplacement,
        relay: PlaybackPresentationRelay
    ) -> PlaybackPresentationMountClaimResult {
        do {
            let operation: PlaybackControlOperationDescriptor = replacement.desired == nil
                ? .cleanupOwnership : .resourceOwnership
            return try transaction(operationDescriptor: operation) { output in
                guard relay.isExactCurrentReplacement(replacement) else { return .stale }
                if let desired = replacement.desired {
                    guard let candidate = currentMountablePresentationLocked(output: output),
                          desired.identity.sessionIdentity == candidate.context.sessionIdentity,
                          desired.identity.backendIdentity == candidate.backendIdentity,
                          desired.identity.outputLifecycleEpoch == candidate.lifecycle,
                          desired.identity.itemGeneration == nil,
                          Self.samePresentationContext(desired.presentation, candidate.presentation) else {
                        return .stale
                    }
                }
                let nonce = try allocator.next(in: .nonce)
                return .claimed(.init(
                    subscriptionGeneration: replacement.subscriptionGeneration,
                    presentationIdentity: replacement.desired?.identity,
                    mountNonce: nonce
                ))
            }
        } catch PlaybackIdentityAllocationError.identitySpaceExhausted {
            consumeCheckedIdentityExhaustion()
            return .exhausted
        } catch {
            return .stale
        }
    }

    private static func samePresentationContext(
        _ lhs: PlaybackPresentation,
        _ rhs: PlaybackPresentation
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.sampleBuffer(left), .sampleBuffer(right)):
            return left === right
        case let (.avPlayer(left), .avPlayer(right)):
            return left === right
        default:
            return false
        }
    }

    /// UI本地generation耗尽也只能经共享Cell终态入口撤权，不能成为第二控制authority。
    func failPresentationControl() {
        allocator.markIdentitySpaceExhausted()
        consumeCheckedIdentityExhaustion()
    }

    func metricsProjection(window: Duration) -> PlaybackMetricsSnapshot? {
        let backend: (any PlaybackBackend)? = projection {
            authority.ownedBackendResources?.object as? any PlaybackBackend
        }
        return backend?.metricsSnapshot(window: window)
    }

    func terminalMetricsProjection(backendIdentity: PlaybackBackendIdentity?) -> (any PlaybackTerminalMetricsProviding)? {
        let backend: (any PlaybackBackend)? = projection {
            guard let owned = authority.ownedBackendResources, owned.identity == backendIdentity else { return nil }
            return owned.object as? any PlaybackBackend
        }
        return backend?.terminalMetricsProvider
    }

    func bindEventRelay(_ relay: PlaybackAudioSessionEventRelay, to ticket: ControlTaskTicket) -> Bool {
        // 组件的一步绑定同样经过原record登记；生产在暴露入口前显式完成第一阶段。
        let needsRegistration = (try? transaction { _ in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil
            else { return false }
            return record.payload == nil
        }) == true
        if needsRegistration, !prepareAudioEventRelayBinding(relay, to: ticket) { return false }
        let bound = (try? transaction { _ in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .queued, case .eventDrain(let runner) = record.payload, !runner.joining,
                  case .audio(let original) = runner.relay, original === relay,
                  authority.groups.contains(where: { $0?.ticket == ticket.group && $0?.sealed == false })
            else { return false }
            // 原record已预登记；overflow撤权后仍须开放其唯一terminal排空，不是空槽补绑。
            // cleanup一旦取消record、封组或领取joining，以上准确CAS即拒绝。
            return relay.bindOwnedExecutor(executor, recordNonce: ticket.nonce)
        }) == true
        if bound { relay.signalAfterOwnedBinding() } else { relay.deactivate() }
        return bound
    }

    /// 同一record先持有原relay及cursor，receiver仍关闭；之后暴露入口便能同步归属overflow。
    func prepareAudioEventRelayBinding(_ relay: PlaybackAudioSessionEventRelay, to ticket: ControlTaskTicket) -> Bool {
        bindEventRelay(.audio(relay), to: ticket)
    }

    private func bindEventRelay(_ relay: OwnedPlaybackEventDrain.Relay, to ticket: ControlTaskTicket) -> Bool {
        let runner = OwnedPlaybackEventDrain(relay: relay)
        let bound = (try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.slot == .accounting || authority.commands[index]?.slot == .systemEventRelay,
                  authority.commands[index]?.phase == .queued,
                  authority.commands[index]?.payload == nil,
                  authority.allowsOutputRelayBinding(ticket.group) else { return false }
            if case .audio(let audioRelay) = relay, let context = authority.outputContext {
                guard let lease = authority.ownedLeaseResources,
                      let registration = lease.object as? PlaybackAudioSessionRegistration,
                      authority.ownsRegistration(registration, allowsClosing: false),
                      audioRelay.lease.id == lease.leaseID, audioRelay.lease.generation == lease.leaseID,
                      ticket.group.resourceIdentity == .monitor(session: context.sessionIdentity,
                        lifecycle: registration.identity.monitorLifecycle) else { return false }
                if let committed = context.committedRelay {
                    guard committed.relayIdentity.sessionIdentity == context.sessionIdentity else { return false }
                    // 仅继承原handoff已吸收的cursor；不能读bind时latest而丢掉交接后的新事件。
                    runner.consumedSystemRevision = committed.ownerEventCursor
                } else {
                    guard context.phase == .pendingLeaseAcquisition,
                          context.sourceTask == registration.identity.acquisition else { return false }
                    // 原acquisition准入CAS冻结的边界；不读取bind时latest而吞掉在途历史key。
                    runner.consumedSystemRevision = context.ownerIngressRevision
                }
            }
            // 原record、executor和cursor同锁换手；audio只登记，不签发drain permit。
            switch relay {
            case .audio(let audio):
                guard audio.prepareOwnedExecutor(executor, recordNonce: ticket.nonce) else { return false }
            case .pipeline:
                guard relay.bind(to: executor, recordNonce: ticket.nonce) else { return false }
            }
            authority.commands[index]?.payload = .eventDrain(runner)
            return true
        }) == true
        if !bound { relay.deactivate() }
        return bound
    }

    func joinEventRelay(_ ticket: ControlTaskTicket, from owner: ControlTaskTicket) async -> Bool {
        let runner: OwnedPlaybackEventDrain? = try? transaction { _ in
            guard mayJoinEventDrain(ticket, from: owner),
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  case .eventDrain(let runner) = record.payload,
                  !runner.joining else { return nil }
            runner.joining = true
            return runner
        }
        guard let runner else { return false }
        runner.relay.deactivate()
        // joining在原CAS关闭新runner admission；当前handle随后保持不变。
        await runner.task?.value
        return (try? transaction { _ in
            guard mayJoinEventDrain(ticket, from: owner),
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  case .eventDrain(let current) = authority.commands[index]?.payload,
                  current === runner, current.joining else { return false }
            authority.commands[index]?.phase = .terminal(.canceled)
            authority.commands[index]?.payload = nil
            return true
        }) == true
    }

    /// 原transition owner从既有32槽逐条封口/join；不复制relay或创建待清理数组。
    func joinOutputEventRelays(owner: OutputTransitionOwnerTicket, pipelineOnly: Bool = false) async -> Bool {
        var cursor = 0
        while cursor < 32 {
            let pair: (ControlTaskTicket, ControlTaskTicket)? = try? transaction { _ in
                guard let context = authority.outputContext, context.owner == owner,
                      let cleanup = authority.commands.first(where: {
                          $0?.groupTicket == context.reservation.ownerGroup &&
                          $0?.slot == ReservedCleanupStage.owner.slot && $0?.phase == .running
                      }) ?? nil else { cursor = 32; return nil }
                while cursor < 32 {
                    let index = cursor
                    cursor += 1
                    guard let record = authority.commands[index],
                          record.slot == .accounting || record.slot == .systemEventRelay,
                          record.groupTicket == cleanup.groupTicket || authority.isDescendant(record.groupTicket, of: cleanup.groupTicket),
                          let groupIndex = authority.groups.firstIndex(where: { $0?.ticket == record.groupTicket }) else { continue }
                    guard case .eventDrain(let runner) = record.payload else {
                        if pipelineOnly, record.slot == .systemEventRelay { continue }
                        if record.groupTicket != cleanup.groupTicket { authority.groups[groupIndex]?.sealed = true }
                        authority.cancel(index)
                        continue
                    }
                    if pipelineOnly, case .audio = runner.relay { continue }
                    // ownerGroup还要承接reserved cleanup；只封同组relay record，不封其cleanup入口。
                    if record.groupTicket != cleanup.groupTicket { authority.groups[groupIndex]?.sealed = true }
                    authority.cancel(index)
                    return (record.controlTaskTicket, cleanup.controlTaskTicket)
                }
                return nil
            }
            guard let (ticket, cleanup) = pair else { continue }
            guard await joinEventRelay(ticket, from: cleanup) else { return false }
        }
        return outputResourceContextSnapshot()?.owner == owner
    }

    private func mayJoinEventDrain(_ ticket: ControlTaskTicket, from owner: ControlTaskTicket) -> Bool {
        guard let cleanup = authority.commands.first(where: { $0?.controlTaskTicket == owner }) ?? nil,
              cleanup.phase == .running, cleanup.gatePolicy == .safetyBypass,
              ticket.group == cleanup.groupTicket ||
                authority.isDescendant(ticket.group, of: cleanup.groupTicket) &&
                authority.groups.contains(where: { $0?.ticket == ticket.group && $0?.sealed == true }) else { return false }
        return true
    }

    /// 唯一预登记source调用；只扫描原32槽，无额外任务数组或动态mailbox。
    func drainOwnedEventRelays() {
        precondition(executor.isIsolated)
        for index in authority.commands.indices {
            // 先在同锁barrier拒绝旧epoch，才允许分配Task；record持续强持原runner。
            let launch: (ControlTaskTicket, OwnedPlaybackEventDrain, Task<Void, Never>?)? = try? transaction { _ in
                guard let record = authority.commands[index],
                      case .eventDrain(let runner) = record.payload, !runner.joining,
                      record.phase == .queued || record.phase == .running,
                      (authority.snapshot.failure == nil || record.gatePolicy == .safetyBypass),
                      authority.matches(record.safetySnapshot),
                      authority.groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false }),
                      runner.relay.claimDrainRequest() else { return nil }
                return (record.controlTaskTicket, runner, runner.task)
            }
            guard let (ticket, runner, previous) = launch else { continue }
            let next = Task { [weak self, runner, previous] in
                // 下一轮只有确认前一Task已真实退出才进入同一record的工作段。
                await previous?.value
                guard let self, self.claimEventDrainWork(ticket, runner: runner) else { return }
                await runner.relay.drain(registry: self, ticket: ticket)
            }
            withExtendedLifetime(previous) {
                installEventDrainHandle(next, ticket: ticket, runner: runner)
            }
        }
    }

    private func installEventDrainHandle(_ task: Task<Void, Never>, ticket: ControlTaskTicket,
        runner: OwnedPlaybackEventDrain) {
        // source始终持有executor，其他所有权操作不能越过本次安装；并发Cell事件
        // 只能撤权，不能释放仍含eventDrain payload的原record。Task首个claim需等本栈退出。
        while true {
            switch executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership, operation: { _ in
                precondition(authority.commands.contains(where: { record in
                    guard let record, record.controlTaskTicket == ticket,
                          case .eventDrain(let current) = record.payload else { return false }
                    return current === runner
                }), "排空任务换手不能丢失原owned record")
                runner.task = task
            }) {
            case .retry, .rejected:
                // fold首次失败先安装sticky终态；继续走cleanup barrier保留已创建Task，
                // 不能因普通admission关闭而把真实退出尾部丢在record外。
                continue
            case .performed: return
            }
        }
    }

    private func claimEventDrainWork(_ ticket: ControlTaskTicket, runner: OwnedPlaybackEventDrain) -> Bool {
        (try? transaction { output in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  case .eventDrain(let current) = authority.commands[index]?.payload,
                  current === runner, !current.joining else { return false }
            if authority.commands[index]?.phase == .running { return true }
            return try AudioSessionLockedOperations(authority: authority, allocator: allocator,
                instant: monotonicClock.nowNanoseconds).claimStart(ticket, output: &output)
        }) == true
    }

    func claimEventDrainDelivery(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  case .eventDrain(let runner) = record.payload,
                  !runner.joining, record.phase == .running,
                  authority.groups.contains(where: { $0?.ticket == ticket.group && $0?.sealed == false }),
                  authority.matches(record.safetySnapshot) else { return false }
            return true
        }) == true
    }

    /// 一次初始化绑定：Authority只强持有queue+SDK的lane，lane不反向持有owner或registry。
    func bindAudioSessionLane(_ lane: AudioSessionBlockingCallLane) -> Bool {
        (try? transaction { _ in
            if let bound = authority.audioSessionLane { return bound === lane }
            guard authority.snapshot.failure == nil, authority.audioSessionPermit == nil else { return false }
            authority.audioSessionLane = lane
            return true
        }) ?? false
    }

    func performOutputUserControl(_ request: OutputUserControlRequest) -> OutputUserControlResult {
        executor.performUserControl(request)
    }

    /// 借用快照只形成CAS期望值；lease、proof和最新物理epoch在同一Authority内重新核验。
    func prepareExplicitResume(for lease: PlaybackAudioSessionLease) -> ControlTaskTicket? {
        guard let context = outputResourceContextSnapshot() else { return nil }
        let safety = executor.safetyIngress.snapshot
        let request = OutputUserControlRequest(kind: .resume, sessionIdentity: context.sessionIdentity,
            expectedOwner: context.owner, contextNonce: context.contextNonce,
            interruptionEpoch: safety.interruptionEpoch, mediaServicesEpoch: safety.mediaServicesEpoch,
            resetPreRouteBinding: context.resetPreRouteBinding, explicitResumeLease: lease)
        switch executor.performUserControl(request) {
        case .acceptedAndPrepared(let ticket): return ticket
        case .acceptedWaiting:
            return try? beginOutputResetConfigurationActivation(contextNonce: context.contextNonce)
        default: return nil
        }
    }

    func acceptsReactivationCompletion(_ receipt: AudioSessionReactivationCompletionReceipt) -> Bool {
        recoveryCompletionEvent(receipt) != nil
    }

    func recoveryCompletionEvent(_ receipt: AudioSessionReactivationCompletionReceipt) -> PlaybackAudioSessionEvent? {
        (try? transaction(operationDescriptor: .resourceOwnership) { _ in
            recoveryCompletionEventLocked(receipt)
        })
    }

    private func recoveryCompletionEventLocked(_ receipt: AudioSessionReactivationCompletionReceipt) -> PlaybackAudioSessionEvent? {
            guard authority.pendingReactivationReceipt == receipt, let context = authority.outputContext,
                  !context.poisoned, context.disposition != .releaseAfterTeardown,
                  context.contextNonce == receipt.contextNonce,
                  let active = context.sessionReceipts?.active,
                  active.leaseID == receipt.leaseID, active.activationNonce == receipt.activationNonce,
                  active.interruptionEpoch == receipt.interruptionEpoch,
                  authority.snapshot.mediaServicesEpoch == receipt.mediaServicesEpoch,
                  authority.snapshot.interruptionEpoch == receipt.interruptionEpoch,
                  authority.snapshot.audioAdmissionFenceRevision == receipt.audioAdmissionFenceRevision,
                  !authority.snapshot.interruptionVeto else { return nil }
            if let proof = context.interruptionProof, proof.proofNonce == receipt.proofNonce,
               authority.registeredDrainProof == .interruption(proof),
               case .ended = authority.snapshot.interruptionState { return .explicitResumeSucceeded }
            guard let proof = authority.registeredPostConfigurationProof,
                  proof.proofNonce == receipt.proofNonce, proof.retainedContextNonce == receipt.contextNonce,
                  proof.leaseID == receipt.leaseID, proof.committedGeneration == active.configurationGeneration,
                  let binding = context.systemRecoveryBinding,
                  proof.incarnationIdentity == binding.incarnation.identity,
                  context.pendingReset == proof.incarnationIdentity.root,
                  proof.incarnationIdentity.root.mediaServicesEpoch == receipt.mediaServicesEpoch,
                  authority.registeredDrainProof == .reset(binding.resetDrainProof),
                  proof.resetDrainProofIdentity == binding.resetDrainProof.identity,
                  authority.postConfigurationRouteState?.budget.stageIdentity == proof.postConfigurationStageIdentity
            else { return nil }
            return .resetConfigurationSucceeded
    }

    /// actor只消费原relay的key。历史kind不是当前授权快照；出声仍须走后续准确proof CAS。
    func consumeAudioSessionEvent(_ key: PlaybackAudioSessionEventKey, run: PlaybackRunIdentity,
        lease: PlaybackAudioSessionLease, drain: ControlTaskTicket) -> PlaybackAudioSessionEventEnvelope? {
        try? transaction { _ in
            let session = PlaybackSessionIdentity(sessionID: run.sessionID, requestID: run.requestID)
            guard authority.snapshot.failure == nil,
                  let context = authority.outputContext, context.sessionIdentity == session,
                  let actualLease = authority.ownedLeaseResources, actualLease.leaseID == lease.id,
                  lease.generation == lease.id, let monitor = actualLease.monitor,
                  drain.group.resourceIdentity == .monitor(session: session, lifecycle: monitor.lifecycle),
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == drain }) ?? nil,
                  record.slot == .systemEventRelay, record.phase == .running,
                  case .eventDrain(let runner) = record.payload, !runner.joining,
                  authority.groups.contains(where: { $0?.ticket == drain.group && $0?.sealed == false }),
                  case .coldStart(let admission) = authority.playbackRequestAdmission,
                  admission.identity.sessionIdentity == session else { return nil }
            switch key.event {
            case .interruptionBegan, .interruptionEnded, .mediaServicesWereReset:
                let maximumEpoch: UInt64
                if key.event == .mediaServicesWereReset { maximumEpoch = authority.snapshot.mediaServicesEpoch }
                else { maximumEpoch = authority.snapshot.interruptionEpoch }
                guard key.revisionOrActivationNonce > runner.consumedSystemRevision,
                      key.revisionOrActivationNonce <= authority.snapshot.throughRevision,
                      key.eventEpoch > 0, key.eventEpoch <= maximumEpoch else { return nil }
                runner.consumedSystemRevision = key.revisionOrActivationNonce
                return .init(event: key.event, systemReceipt: nil)
            case .explicitResumeSucceeded, .resetConfigurationSucceeded:
                guard let receipt = authority.pendingReactivationReceipt,
                      receipt.activationNonce == key.revisionOrActivationNonce,
                      recoveryCompletionEventLocked(receipt) == key.event else { return nil }
                authority.pendingReactivationReceipt = nil
                return .init(event: key.event, systemReceipt: nil, reactivationReceipt: receipt)
            case .recoveryFailed:
                return .init(event: key.event, systemReceipt: nil)
            }
        }
    }

    private func transaction<Value>(operationDescriptor: PlaybackControlOperationDescriptor = .cleanupOwnership,
        safetyFailureFallback: ((inout PlaybackOutputSafetyState) throws -> Value)? = nil,
        _ body: (inout PlaybackOutputSafetyState) throws -> Value) throws -> Value {
        var result: Result<Value, Error>?
        executor.sync {
            precondition(!authority.resourceTransactionActive, "持锁组合CAS不能再次调用公开registry入口")
            var fallback = false
            while result == nil {
                switch executor.withSafetyIngressBarrier(operationDescriptor: fallback ? .cleanupOwnership : operationDescriptor,
                    operation: { output in
                        authority.resourceTransactionActive = true
                        defer { authority.resourceTransactionActive = false }
                        return Result {
                            if fallback {
                                guard authority.snapshot.failure != nil, let safetyFailureFallback else { throw Failure.invalidGroup }
                                return try safetyFailureFallback(&output)
                            }
                            return try body(&output)
                        }
                    }) {
                case .retry: continue
                case .rejected:
                    // 仅barrier未执行body的明确拒绝可转入cleanup；body错误不重试。
                    if !fallback, operationDescriptor == .resourceOwnership, safetyFailureFallback != nil { fallback = true }
                    else { result = .failure(Failure.invalidGroup) }
                case .performed(let value): result = value
                }
            }
        }
        // 非callback checked分配失败只在这个失败返回边界唤醒；成功getter绝不kick。
        if case .failure(let error) = result,
           error as? PlaybackIdentityAllocationError == .identitySpaceExhausted {
            executor.signalOwnedEventDrain()
        }
        return try result!.get()
    }

    /// checked allocator失败不能只依赖异步source尾声；调用边界内先让Cell折叠终态，再归并原automatic owner。
    private func consumeCheckedIdentityExhaustion() {
        guard allocator.isExhausted else { return }
        _ = try? transaction(operationDescriptor: .cleanupOwnership) { _ in () }
        consumeAutomaticTerminal()
    }

    /// 只复制已经由Authority提交的值；不得通过查询折叠ingress或启动timer/terminal。
    private func projection<Value>(_ body: () -> Value) -> Value {
        var value: Value?
        executor.sync { value = executor.safetyIngress.withReadOnlyAuthorityProjection(body) }
        return value!
    }

    func ownedResourceSnapshot() -> OutputResourceOwnershipSnapshot? {
        projection { authority.ownedResource?.snapshot }
    }

    func cleanupReservationSnapshot() -> CleanupReservation? {
        projection { authority.cleanupReservation }
    }

    /// 仅在同一Cell持锁期间借用唯一Authority；不得保存、捕获或跨await传递此值。
    private struct AudioSessionLockedOperations {
        let authority: Authority
        let allocator: PlaybackIdentityAllocator
        let instant: UInt64

        func prepareReservedCleanup(_ reservation: CleanupReservationTicket,
                                            stage: ReservedCleanupStage) throws -> PreparedCommand {
            try authority.prepareReservedCleanup(reservation, stage: stage)    }

        func prepareOutputCleanupOwner(_ reservation: CleanupReservationTicket, terminal: Bool) throws -> PreparedCommand {
            guard authority.cleanupReservation?.ticket == reservation else { throw Failure.invalidGroup }
            if let index = authority.commands.firstIndex(where: {
                $0?.groupTicket == reservation.ownerGroup && $0?.slot == ReservedCleanupStage.owner.slot
            }), let record = authority.commands[index] {
                if case .terminal = record.phase { throw Failure.invalidGroup }
                return .init(index: index, ticket: record.controlTaskTicket, record: nil, reservedStage: nil)
            }
            if terminal { return try prepareReservedCleanup(reservation, stage: .owner) }
            return try prepareCommand(group: reservation.ownerGroup, slot: ReservedCleanupStage.owner.slot,
                policy: .safetyBypass, audioIdentity: nil, audioPolicy: nil)    }

        func terminateCleanupReservationLocked(_ ticket: CleanupReservationTicket, output: inout PlaybackOutputSafetyState) {
            guard authority.cleanupReservation?.ticket == ticket else { return }
            authority.terminateCleanupReservation()    }

        func transferActivationDispositionLocked(_ ticket: ControlTaskTicket) -> Bool {
                guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                      let record = authority.commands[index], case .activate = record.audioPolicy,
                      let identity = record.audioPhaseIdentity, let resource = authority.ownedResource,
                      let lease = resource.payload.lease,
                      (resource.contextNonce == identity.contextNonce ||
                       authority.outputContext?.pendingActivationCall == AudioSessionCallIdentity(record: ticket, phaseIdentity: identity)),
                      lease.leaseID == identity.leaseID, resource.sessionIdentity == identity.sessionIdentity,
                      !record.activationResponsibilityTransferred else { return false }
                let disposition: AudioSessionDeactivationDisposition
                let call = AudioSessionCallIdentity(record: ticket, phaseIdentity: identity)
                if identity.mediaServicesEpoch != authority.snapshot.mediaServicesEpoch {
                    disposition = .invalidatedByMediaServicesReset(mediaServicesEpoch: authority.snapshot.mediaServicesEpoch)
                } else {
                    switch record.activationOutcome {
                    case .notInvoked(let proof): disposition = .confirmedInactive(.activationNotInvoked(proof))
                    case .returnedFailure(let returned, let failure): disposition = .confirmedInactive(.activationReturnedFailure(returned, failure))
                    case .returnedSuccess(let returned): disposition = .requiresDeactivate(.returnedSuccess(returned))
                    case nil: disposition = .awaitingActivationOutcome(call)
                    }
                }
                authority.ownedResource?.payload.lease?.deactivation = disposition
                authority.outputContext?.pendingActivationCall = record.activationOutcome == nil ? call : nil
                authority.commands[index]?.activationResponsibilityTransferred = record.activationOutcome != nil
                return true    }

        func enqueueCleanupDeactivationLocked(_ ticket: CleanupReservationTicket) throws -> ControlTaskTicket {
                guard var reservation = authority.cleanupReservation, reservation.ticket == ticket,
                      let resource = authority.ownedResource, resource.reservation == ticket,
                      let lease = resource.payload.lease, authority.outputContext?.monitorStopped == true else { throw Failure.invalidGroup }
                let stage = reservation[.audioSession]
                let task = reservation.task(for: .audioSession)
                if let record = authority.commands[stage.index], record.controlTaskTicket == task,
                   record.deactivationRequest != nil { return task }
                guard !stage.consumed, !authority.commands.contains(where: { $0?.slot == .audioSessionRecovery }),
                      case .requiresDeactivate(let source) = lease.deactivation else { throw Failure.slotOccupied }
                let previousIdentity: AudioSessionPhaseIdentity
                switch source {
                case .activeReceipt(_, let identity): previousIdentity = identity
                case .returnedSuccess(let call): previousIdentity = call.phaseIdentity
                }
                guard previousIdentity.leaseID == lease.leaseID,
                      previousIdentity.sessionIdentity == resource.sessionIdentity,
                      previousIdentity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else { throw Failure.invalidPolicy }
                let identity = AudioSessionPhaseIdentity(owner: ticket.ownerGroup.ownerTicket,
                    sessionIdentity: previousIdentity.sessionIdentity, leaseID: lease.leaseID,
                    contextNonce: resource.contextNonce, mediaServicesEpoch: previousIdentity.mediaServicesEpoch,
                    phaseNonce: reservation.deactivationPhaseNonce)
                guard let request = AudioSessionCleanupDeactivationRequest(reservation: ticket,
                    contextNonce: resource.contextNonce, leaseID: lease.leaseID, source: source,
                    call: .init(record: task, phaseIdentity: identity)) else { throw Failure.invalidPolicy }
                var command = try OwnedPostIngressControlCommand(controlTaskTicket: task,
                    slot: .audioSessionRecovery, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
                try command.installDeactivation(request)
                authority.commands[stage.index] = command
                reservation[.audioSession].consumed = true
                authority.cleanupReservation = reservation
                return task    }

        func completeAudioSessionDeactivation(_ ticket: ControlTaskTicket, result: AudioSessionDeactivationResult) throws -> Bool {
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], let request = record.deactivationRequest,
                  record.phase == .running || record.phase == .cancelRequested,
                  authority.ownedResource?.reservation == request.reservation,
                  authority.ownedResource?.contextNonce == request.contextNonce,
                  authority.ownedResource?.payload.lease?.leaseID == request.leaseID else { return false }
            if request.call.phaseIdentity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch {
                guard authority.ownedResource?.payload.lease?.deactivation == .deactivationInFlight(request.call) else { return false }
                authority.ownedResource?.payload.lease?.deactivation = .deactivationSettled(request.call, result)
            }
            authority.commands[index]?.completeDeactivation(result)
            authority.commands[index]?.phase = record.phase == .running ? .terminal(.completed) : .terminal(.canceled)
            return true
        }

        func installPreparedCommand(_ prepared: PreparedCommand) -> ControlTaskTicket {
            authority.installPreparedCommand(prepared)    }

        func prepareCommand(group: ControlTaskGroupTicket, slot: ControlTaskSlot,
            policy: ControlGatePolicy, audioIdentity: AudioSessionPhaseIdentity?, audioPolicy: AudioSessionPhasePolicy?,
            excludingIndex: Int? = nil, preparedCycle: PreparedOutputCycle? = nil) throws -> PreparedCommand {
            try authority.prepareCommand(group: group, slot: slot, policy: policy, audioIdentity: audioIdentity,
                audioPolicy: audioPolicy, excludingIndex: excludingIndex, preparedCycle: preparedCycle, allocator: allocator)    }

        func claimStart(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.phase == .queued else { return false }
            if record.slot == .acquire || record.slot == .factory {
                guard let context = authority.outputContext, context.sourceTask == ticket,
                      context.reservation.workGroup == record.groupTicket,
                      context.phase == (record.slot == .acquire ? .pendingLeaseAcquisition : .pendingCreation) else {
                    authority.cancel(index)
                    return false
                }
            }
            if authority.outputContext?.phase == .pendingLeaseAcquisition,
               record.groupTicket == authority.outputContext?.reservation.workGroup,
               try expireOutputAcquisitionLocked(output: &output) { return false }
            if record.groupTicket == authority.outputContext?.reservation.workGroup,
               try expireResetPreRouteLocked(output: &output) { return false }
            if case .activate(.reactivateConfiguredGeneration, _, _, _) = record.audioPolicy {
                switch classifyReactivationClaimDeadline() {
                case .continueClaim: break
                case .rejectWithoutTimeout: return false
                case .timeout(let contextNonce):
                    try timeoutOutputRouteBoundaryLocked(contextNonce: contextNonce,
                        at: self.instant, output: &output)
                    return false
                }
            }
            if record.slot == .monitorStop || record.slot == .committedCleanup,
               authority.outputContext?.delivery != nil { return false }
            if let context = authority.outputContext {
                if context.retirement == ticket, !context.suspendConfirmed &&
                    !context.suspendRequiresRetirement && !context.suspendTimedOut { return false }
                if context.teardown == ticket, !authority.isTerminal(context.reservation.workGroup) { return false }
            }
            guard authority.groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false }),
                  record.ownerTicket == record.groupTicket.ownerTicket,
                  record.resourceIdentity == record.groupTicket.resourceIdentity,
                  authority.matches(record.safetySnapshot), authority.matchesAudio(record) else {
                authority.cancel(index)
                return false
            }
            if record.gatePolicy != .safetyBypass &&
                (authority.snapshot.failure != nil ||
                 (record.gatePolicy != .routeNeutral && record.gatePolicy != .audioSession && authority.snapshot.interruptionVeto)) {
                authority.cancel(index)
                return false
            }
            if record.gatePolicy == .activationRequiresOpen && !output.routeObservationGateOpen {
                authority.commands[index]?.phase = .terminal(.canceled)
                return false
            }
            if record.gatePolicy == .routeSpeculativeRateZero && !output.routeObservationGateOpen {
                return false
            }
            if case .activate(_, _, _, let invocation) = record.audioPolicy {
                guard invocation.wasIssued(by: allocator),
                      authority.activationClaim.map({ invocation.isLater(than: $0.invocationIdentity) }) ?? true else {
                    authority.cancel(index)
                    return false
                }
                authority.activationClaim = ActivationClaim(invocationIdentity: invocation, record: ticket)
                if let identity = record.audioPhaseIdentity,
                   authority.ownedResource?.contextNonce == identity.contextNonce,
                   authority.ownedResource?.payload.lease?.leaseID == identity.leaseID {
                    let call = AudioSessionCallIdentity(record: ticket, phaseIdentity: identity)
                    authority.outputContext?.pendingActivationCall = call
                    authority.ownedResource?.payload.lease?.deactivation = .awaitingActivationOutcome(call)
                }
            }
            if let request = record.deactivationRequest {
                guard authority.ownedResource?.reservation == request.reservation,
                      authority.ownedResource?.contextNonce == request.contextNonce,
                      authority.ownedResource?.payload.lease?.leaseID == request.leaseID,
                      authority.ownedResource?.payload.lease?.deactivation == .requiresDeactivate(request.source),
                      request.call.phaseIdentity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else {
                    authority.cancel(index)
                    return false
                }
                authority.ownedResource?.payload.lease?.deactivation = .deactivationInFlight(request.call)
            }
            if let reservation = authority.cleanupReservation, ticket == reservation.task(for: .leaseRelease),
               authority.ownedResource != nil { return false }
            if record.slot == .acquire, authority.outputContext?.sourceTask == ticket,
               authority.outputContext?.phase == .pendingLeaseAcquisition {
                authority.outputContext?.acquisitionDeadline = try .init(acquisitionTicket: ticket,
                    anchorInstant: self.instant)
            }
            authority.commands[index]?.phase = .running
            return true
        }

        func completeAudioSessionActivation(_ ticket: ControlTaskTicket,
                                            failure: AudioSessionFixedFailure?) throws -> Bool {
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], case .activate = record.audioPolicy,
                  let identity = record.audioPhaseIdentity,
                  record.phase == .running || record.phase == .cancelRequested else { return false }
            let call = AudioSessionCallIdentity(record: ticket, phaseIdentity: identity)
            authority.commands[index]?.activationOutcome = failure.map { .returnedFailure(call, $0) } ?? .returnedSuccess(call)
            authority.commands[index]?.phase = record.phase == .running ? .terminal(.completed) : .terminal(.canceled)
            return true
        }

        func completeAudioSessionConfiguration(_ ticket: ControlTaskTicket,
            result: AudioSessionConfigurationCallResult) throws -> Bool {
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index],
                  record.phase == .running || record.phase == .cancelRequested else { return false }
            let step: AudioSessionConfigurationStep
            switch record.audioPolicy {
            case .configureAcquisition(_, _, _, let value), .configureInactive(_, _, _, let value): step = value
            default: return false
            }
            let accepted = authority.matchesAudio(record) && !record.resultInvalidated
            authority.commands[index]?.phase = accepted ? .terminal(.completed) : .terminal(.canceled)
            guard accepted, let current = authority.audioPhase else { return true }
            let next: AudioSessionConfigurationProgress
            switch (step, current.configurationProgress, result) {
            case (.longFormCategoryAttempt, .awaitingLongForm, .categorySucceeded):
                next = .awaitingMultichannel(actualPolicy: .longFormAudio, preferredFailure: nil)
            case (.longFormCategoryAttempt, .awaitingLongForm, .failed(let failure)):
                next = .awaitingFallback(preferredFailure: failure)
            case (.defaultCategoryFallbackAttempt, .awaitingFallback(let failure), .categorySucceeded):
                next = .awaitingMultichannel(actualPolicy: .default, preferredFailure: failure)
            case (.multichannelCapability, .awaitingMultichannel(let policy, let failure), .multichannelCapability(let capability)):
                next = .complete(actualPolicy: policy, preferredFailure: failure, multichannel: capability)
            case (_, _, .failed(let failure)): next = .failed(failure)
            default:
                authority.commands[index]?.resultInvalidated = true
                authority.commands[index]?.phase = .terminal(.canceled)
                return false
            }
            authority.commands[index]?.resultClaimed = true
            authority.audioPhase?.configurationProgress = next
            return true
        }

        func beginOutputAcquisitionConfiguration(contextNonce: UInt64,
            parent: CurrentPlaybackOperationDeadlineTicket, output: inout PlaybackOutputSafetyState) throws -> ControlTaskTicket? {
            guard try !expireOutputAcquisitionLocked(output: &output) else { return nil }
            guard case .acquiringLease(let context, .configuring(let acquired, let attempt)) = authority.resourceState,
                  context.contextNonce == contextNonce, context.disposition != .releaseAfterTeardown,
                  (context.pendingReset == nil || authority.matchesManagedAcquisitionReset(context)),
                  !context.poisoned, attempt.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
                  context.parentDeadline == parent else { return nil }
            let parentIdentity: PlaybackProgressBudgetTicket.Identity
            switch parent { case .coldStart(let value), .outputRecovery(let value): parentIdentity = value.identity }
            guard parentIdentity.sessionIdentity == context.sessionIdentity else { return nil }
            var phase: RegisteredAudioSessionPhase
            if let existing = authority.audioPhase, existing.configurationAttempt == attempt {
                guard existing.identity.contextNonce == contextNonce, existing.acquisitionOwnershipProof == acquired.proof,
                      existing.parent == parentIdentity, existing.permitsFurtherCalls else { return nil }
                phase = existing
            } else {
                phase = .init(identity: .init(owner: context.reservation.workGroup.ownerTicket,
                    sessionIdentity: context.sessionIdentity, leaseID: acquired.lease.leaseID, contextNonce: contextNonce,
                    mediaServicesEpoch: attempt.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce)),
                    policy: .configureAcquisition(acquisitionTicket: acquired.proof.acquisitionTicket,
                        ownershipNonce: acquired.proof.ownershipNonce, configurationAttemptNonce: attempt.nonce,
                        step: .longFormCategoryAttempt), configurationAttempt: attempt, parent: parentIdentity,
                    resetBinding: context.resetPreRouteBinding, incarnation: nil, reactivationState: nil, configurationProgress: .awaitingLongForm,
                    permitsFurtherCalls: true, acquisitionOwnershipProof: acquired.proof,
                    processReceipt: nil, configuredReceipt: nil, inactiveReceipt: nil)
            }
            let step: AudioSessionConfigurationStep
            switch phase.configurationProgress {
            case .awaitingLongForm: step = .longFormCategoryAttempt
            case .awaitingFallback: step = .defaultCategoryFallbackAttempt
            case .awaitingMultichannel: step = .multichannelCapability
            default: return nil
            }
            phase.policy = .configureAcquisition(acquisitionTicket: acquired.proof.acquisitionTicket,
                ownershipNonce: acquired.proof.ownershipNonce, configurationAttemptNonce: attempt.nonce, step: step)
            let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .audioSessionRecovery,
                policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy)
            authority.resourceState = .acquiringLease(context, .configuring(acquired, attempt))
            authority.audioPhase = phase
            return installPreparedCommand(prepared)
        }

        func settleOutputAcquisitionConfiguration(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard try !expireOutputAcquisitionLocked(output: &output) else { return false }
            guard case .acquiringLease(let context, .configuring(let acquired, let attempt)) = authority.resourceState,
                  context.disposition != .releaseAfterTeardown,
                  (context.pendingReset == nil || authority.matchesManagedAcquisitionReset(context)), !context.poisoned,
                  let phase = authority.audioPhase, phase.configurationAttempt == attempt,
                  phase.identity.contextNonce == context.contextNonce, phase.acquisitionOwnershipProof == acquired.proof,
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .terminal(.completed), record.resultClaimed, !record.resultInvalidated,
                  record.audioPhaseIdentity == phase.identity,
                  case .configureAcquisition(_, _, _, .multichannelCapability) = record.audioPolicy,
                  case .complete(let policy, let failure, let multichannel) = phase.configurationProgress,
                  attempt.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else { return false }
            if context.resetAcquisitionBinding != nil {
                let receipt = InactiveAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: attempt.mediaServicesEpoch,
                    attemptNonce: attempt.nonce, receiptNonce: try allocator.next(in: .nonce)), actualPolicy: policy,
                    preferredFailureReason: failure, planDigest: attempt.plan, attemptLineage: attempt,
                    multichannelCapability: multichannel)
                authority.resourceState = .acquiringLease(context, .readyToCommit(.inactive(acquired, receipt)))
                authority.audioPhase?.inactiveReceipt = receipt
                return true
            }
            let (expectedGeneration, overflow) = authority.currentConfigurationGeneration.addingReportingOverflow(1)
            guard !overflow else { throw PlaybackSafetyFailure.identitySpaceExhausted }
            let process = ProcessAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: attempt.mediaServicesEpoch,
                configurationGeneration: expectedGeneration, receiptNonce: try allocator.next(in: .nonce)),
                actualPolicy: policy, preferredFailureReason: failure, multichannelCapability: multichannel,
                planDigest: attempt.plan, attemptLineage: attempt)
            let configured = OutputConfiguredAcquisition(acquired: acquired, processReceipt: process)
            authority.resourceState = .acquiringLease(context, .awaitingActivation(configured))
            authority.audioPhase?.processReceipt = process
            authority.audioPhase?.configuredReceipt = configured.configuredReceipt
            return true
        }

        func beginOutputAcquisitionActivation(contextNonce: UInt64, output: inout PlaybackOutputSafetyState) throws -> ControlTaskTicket? {
            guard try !expireOutputAcquisitionLocked(output: &output) else { return nil }
            guard case .acquiringLease(let context, .awaitingActivation(let configured)) = authority.resourceState,
                  context.contextNonce == contextNonce, context.disposition != .releaseAfterTeardown,
                  context.pendingReset == nil, !context.poisoned,
                  context.pendingActivationCall == nil, var phase = authority.audioPhase,
                  phase.acquisitionOwnershipProof == configured.acquired.proof,
                  phase.processReceipt == configured.processReceipt,
                  phase.configuredReceipt == configured.configuredReceipt,
                  configured.processReceipt.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else { return nil }
            if authority.snapshot.interruptionVeto { return nil }
            phase.policy = .activate(purpose: .activateAcquiredConfiguredGeneration(sessionIdentity: context.sessionIdentity,
                committedGeneration: configured.processReceipt.identity.configurationGeneration,
                acquisitionOwnershipProof: configured.acquired.proof), interruptionEpoch: authority.snapshot.interruptionEpoch,
                audioAdmissionFenceRevision: authority.snapshot.audioAdmissionFenceRevision,
                invocationIdentity: try AudioSessionActivationInvocationIdentity(allocator: allocator))
            let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .audioSessionRecovery,
                policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy)
            authority.audioPhase = phase
            return installPreparedCommand(prepared)
        }

        func settleOutputAcquisitionActivation(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard try !expireOutputAcquisitionLocked(output: &output) else { return false }
            guard case .acquiringLease(var context, .awaitingActivation(var configured)) = authority.resourceState,
                  context.disposition != .releaseAfterTeardown, context.pendingReset == nil, !context.poisoned,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], let identity = record.audioPhaseIdentity,
                  record.phase == .terminal(.completed), !record.resultInvalidated,
                  authority.matchesAudio(record), !record.activationResponsibilityTransferred,
                  case .returnedSuccess(let call) = record.activationOutcome,
                  context.pendingActivationCall == call, call.record == ticket,
                  identity.contextNonce == context.contextNonce,
                  configured.acquired.proof == authority.audioPhase?.acquisitionOwnershipProof else { return false }
            let receipt = ActiveSessionReceipt(leaseID: configured.acquired.lease.leaseID,
                configurationGeneration: configured.processReceipt.identity.configurationGeneration,
                interruptionEpoch: authority.snapshot.interruptionEpoch, activationNonce: try allocator.next(in: .activation))
            configured.acquired.lease.deactivation = .requiresDeactivate(.activeReceipt(receipt, identity))
            context.pendingActivationCall = nil
            authority.resourceState = .acquiringLease(context, .readyToCommit(.ordinary(configured, receipt)))
            authority.commands[index]?.activationResponsibilityTransferred = true
            authority.commands[index]?.resultClaimed = true
            return true
        }

        func beginOutputResetConfigurationActivation(contextNonce: UInt64, output: inout PlaybackOutputSafetyState) throws -> ControlTaskTicket? {
            guard try !expireResetPreRouteLocked(output: &output),
                  var context = authority.outputContext, context.phase == .pendingSuccessorLease,
                  context.contextNonce == contextNonce, context.disposition != .releaseAfterTeardown,
                  !context.poisoned, !authority.snapshot.interruptionVeto, !authority.snapshot.userPaused,
                  context.pendingActivationCall == nil,
                  let binding = context.systemRecoveryBinding, let receipt = binding.inactiveConfigurationReceipt,
                  binding.incarnation.baseConfigurationGeneration == authority.currentConfigurationGeneration,
                  authority.postConfigurationRouteState == nil, var phase = authority.audioPhase,
                  phase.identity.contextNonce == contextNonce, phase.incarnation == binding.incarnation,
                  phase.inactiveReceipt == receipt, authority.matchesResetBinding(phase),
                  context.interval == nil, authority.audioSessionPermit == nil,
                  authority.registeredDrainProof == .reset(binding.resetDrainProof) else { return nil }
            phase.policy = .activate(purpose: .commitResetConfiguration(incarnation: binding.incarnation.identity,
                baseGeneration: binding.incarnation.baseConfigurationGeneration, receiptIdentity: receipt.identity),
                interruptionEpoch: authority.snapshot.interruptionEpoch,
                audioAdmissionFenceRevision: authority.snapshot.audioAdmissionFenceRevision,
                invocationIdentity: try .init(allocator: allocator))
            let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .audioSessionRecovery,
                policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy)
            // 当前reset仍只有retained lease，原SDK责任已归还且配置有效；准确新epoch的activation才可结清began排空。
            context.interruptionDrainRequired = false
            authority.outputContext = context
            authority.audioPhase = phase
            return installPreparedCommand(prepared)
        }

        /// 只借原未修改context；完整record/call校验返回后才物化reset提交候选。
        private func validateResetActivationRecord(_ ticket: ControlTaskTicket,
            context: inout OutputResourceContext) -> (index: Int, identity: AudioSessionPhaseIdentity)? {
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], let identity = record.audioPhaseIdentity,
                  record.phase == .terminal(.completed), !record.resultInvalidated, !record.activationResponsibilityTransferred,
                  case .returnedSuccess(let call) = record.activationOutcome, context.pendingActivationCall == call,
                  call.record == ticket, authority.matchesAudio(record) else { return nil }
            return (index, identity)
        }

        func settleOutputResetConfigurationActivation(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState,
            followUp: inout ControlTaskTicket?) throws -> Bool {
            guard try !expireResetPreRouteLocked(output: &output),
                  var context = authority.outputContext, context.phase == .pendingSuccessorLease,
                  let binding = context.systemRecoveryBinding, let inactive = binding.inactiveConfigurationReceipt,
                  context.disposition != .releaseAfterTeardown, !context.poisoned,
                  let validated = validateResetActivationRecord(ticket, context: &context), var phase = authority.audioPhase,
                  phase.incarnation == binding.incarnation, phase.inactiveReceipt == inactive,
                  binding.incarnation.baseConfigurationGeneration == authority.currentConfigurationGeneration,
                  authority.postConfigurationRouteState == nil, var preRoute = authority.resetPreRouteState,
                  let relay = context.committedRelay, let lease = authority.ownedResource?.payload.lease else { return false }
            let instant = self.instant
            guard let elapsed = preRoute.effectiveElapsed(at: instant), elapsed < preRoute.boundaryEffectiveElapsed,
                  parentAllowsWork(context.parentDeadline, at: instant) else { return false }
            let (generation, overflow) = authority.currentConfigurationGeneration.addingReportingOverflow(1)
            guard !overflow else { throw PlaybackSafetyFailure.identitySpaceExhausted }
            let process = ProcessAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: authority.snapshot.mediaServicesEpoch,
                configurationGeneration: generation, receiptNonce: try allocator.next(in: .nonce)), actualPolicy: inactive.actualPolicy,
                preferredFailureReason: inactive.preferredFailureReason, multichannelCapability: inactive.multichannelCapability,
                planDigest: inactive.planDigest, attemptLineage: inactive.attemptLineage)
            let configured = ConfiguredSessionReceipt(leaseID: lease.leaseID, processConfigurationReceiptIdentity: process.identity)
            let active = ActiveSessionReceipt(leaseID: lease.leaseID, configurationGeneration: generation,
                interruptionEpoch: authority.snapshot.interruptionEpoch, activationNonce: try allocator.next(in: .activation))
            let transition = ConfigurationTransitionIdentity.reset(binding.incarnation.identity)
            let stage = try allocator.next(in: .deadline)
            let carried = binding.inheritedRouteAvailabilityConstraint?.carriedPostConfigurationStage
            let budget = PostConfigurationRouteBudget(configurationTransitionIdentity: transition, stageIdentity: stage,
                carriedStageLineageIdentity: carried?.originStageIdentity, configurationGeneration: generation,
                parentOperationDeadline: binding.outerDeadlineTicket,
                inheritedRouteAvailabilityConstraint: binding.inheritedRouteAvailabilityConstraint,
                maximumEffectiveDuration: min(3_000_000_000, carried?.remainingEffectiveTime ?? 3_000_000_000),
                accumulatedEffectiveTime: 0, attemptNonce: try allocator.next(in: .nonce))
            let observation = RouteObservationTicket(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: relay.relayIdentity.monitorLifecycle, mediaServicesEpoch: authority.snapshot.mediaServicesEpoch,
                interruptionEpoch: active.interruptionEpoch, audioSessionConfigurationGeneration: generation,
                audioSessionActivationNonce: active.activationNonce, configurationTransitionIdentity: transition,
                observationNonce: try allocator.next(in: .nonce))
            let proof = ResetPostConfigurationProof(incarnationIdentity: binding.incarnation.identity,
                resetDrainProofIdentity: binding.resetDrainProof.identity, retainedContextNonce: context.contextNonce,
                leaseID: lease.leaseID, committedGeneration: generation, postConfigurationStageIdentity: stage,
                proofNonce: try allocator.next(in: .nonce))
            let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .sampler,
                policy: .safetyBypass, audioIdentity: nil, audioPolicy: nil)
            let failureBudget = try context.budget ?? CleanupBudgetTicket(predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                anchorInstant: instant, nonce: context.reservation.nonce)
            let failureOwner = try prepareOutputCleanupOwner(context.reservation, terminal: true)
            do {
                guard try allocator.next(in: .audioSessionConfigurationGeneration) == generation else { throw PlaybackSafetyFailure.invalidEvidence }
            } catch {
                context.poisoned = true
                context.disposition = .releaseAfterTeardown
                context.relayClosing = true
                context.teardownRequested = true
                context.budget = failureBudget
                context.owner = .init(identity: authority.cleanupReservation!.terminalOwner, reason: .terminal)
                authority.outputContext = context
                _ = installPreparedCommand(failureOwner)
                terminateCleanupReservationLocked(context.reservation, output: &output)
                output.outputPermitPresent = false
                output.readinessOpen = false
                output.routeObservationGateOpen = false
                throw error
            }
            // 所有准备已经成功；从此到安装结束不再签发身份或拒绝。
            preRoute.accumulatedEffectiveTime = elapsed
            if preRoute.runningSince != nil { preRoute.runningSince = instant }
            settleResetParentClockLocked(preRoute, context: &context)
            context.sessionReceipts = .init(process: process, configured: configured, active: active)
            context.pendingActivationCall = nil
            phase.processReceipt = process
            phase.configuredReceipt = configured
            phase.currentReactivationProof = .resetPostConfiguration(proof)
            authority.outputContext = context
            authority.ownedResource?.payload.lease?.deactivation = .requiresDeactivate(.activeReceipt(active, validated.identity))
            authority.audioPhase = phase
            authority.processConfigurationReceipt = process
            authority.currentConfigurationGeneration = generation
            authority.resetPreRouteState = nil
            authority.postConfigurationRouteState = .init(budget: budget, runningSince: instant, freezeGeneration: preRoute.freezeGeneration)
            authority.registeredPostConfigurationProof = proof
            authority.commands[validated.index]?.activationResponsibilityTransferred = true
            authority.commands[validated.index]?.resultClaimed = true
            authority.routeObservationState = .pending(.init(ticket: observation, ordinaryDeadlineState: nil, sampler: prepared.ticket,
                latestObservation: nil, reasons: .initialAuthoritativeSampleRequired, topologyChangeHint: false,
                outputConfigurationChanged: false))
            output.routeObservationGateOpen = false
            followUp = installPreparedCommand(prepared)
            return true
        }

        func beginOutputRouteSample(_ observation: RouteObservationTicket, source: ControlTaskTicket, output: inout PlaybackOutputSafetyState) throws -> OutputRouteSampleClaim? {
            guard case .pending(var pending) = authority.routeObservationState,
                  pending.ticket == observation, pending.sampler == source, !pending.sampleInFlight,
                  let boundary = routeBoundaryLocked(pending), var context = authority.outputContext,
                  context.disposition != .releaseAfterTeardown, !context.poisoned,
                  let current = authority.currentRouteAuthority(context: &context), matchesRouteObservation(observation, current),
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == source }),
                  let record = authority.commands[index], record.slot == .sampler,
                  record.phase == .queued || record.phase == .running,
                  authority.groups.contains(where: { $0?.ticket == source.group && $0?.sealed == false }) else { return nil }
            let instant = self.instant
            guard routeBoundaryAllowsWorkLocked(boundary, at: instant), parentAllowsWork(context.parentDeadline, at: instant) else {
                try timeoutOutputRouteBoundaryLocked(context: &context, at: instant, output: &output)
                return nil
            }
            let claim = OutputRouteSampleClaim(source: source, observation: observation, authority: current)
            pending.sampleInFlight = true
            pending.resamplePending = false
            authority.routeObservationState = .pending(pending)
            authority.routeSampleClaim = claim
            authority.commands[index]?.phase = .running
            return claim
        }

        func currentOutputRouteAuthorityLocked() -> PlaybackRouteAuthorityIdentity? {
            authority.currentRouteAuthority()    }

        func matchesRouteObservation(_ ticket: RouteObservationTicket, _ current: PlaybackRouteAuthorityIdentity) -> Bool {
            ticket.sessionIdentity == current.sessionIdentity && ticket.monitorLifecycle == current.monitorLifecycle &&
                ticket.mediaServicesEpoch == current.mediaServicesEpoch && ticket.interruptionEpoch == current.interruptionEpoch &&
                ticket.audioSessionConfigurationGeneration == current.audioSessionConfigurationGeneration &&
                ticket.audioSessionActivationNonce == current.audioSessionActivationNonce &&
                ticket.configurationTransitionIdentity == current.configurationTransitionIdentity    }

        func routeBoundaryLocked(_ pending: PendingRouteObservation) -> OutputRouteAvailabilityBoundary? {
            if let deadline = pending.deadline, pending.ticket?.configurationTransitionIdentity == nil { return .ordinary(deadline) }
            guard let stage = authority.postConfigurationRouteState,
                  pending.ticket?.configurationTransitionIdentity == stage.budget.configurationTransitionIdentity else { return nil }
            return .postConfiguration(stage.budget.configurationTransitionIdentity, stageIdentity: stage.budget.stageIdentity)    }

        func routeBoundaryAllowsWorkLocked(_ boundary: OutputRouteAvailabilityBoundary, at instant: UInt64) -> Bool {
            switch boundary {
            case .ordinary(let deadline): return instant < deadline.deadlineInstant
            case .postConfiguration(let transition, let identity):
                guard let stage = authority.postConfigurationRouteState, stage.budget.configurationTransitionIdentity == transition,
                      stage.budget.stageIdentity == identity, let elapsed = stage.effectiveElapsed(at: instant),
                      elapsed < stage.budget.maximumEffectiveDuration else { return false }
                return stage.budget.inheritedRouteAvailabilityConstraint?.ordinaryAbsolute.map { instant < $0.deadlineInstant } ?? true
            }    }

        func timeoutOutputRouteBoundaryLocked(contextNonce: UInt64, at instant: UInt64,
            output: inout PlaybackOutputSafetyState) throws {
            guard var context = authority.outputContext, context.contextNonce == contextNonce else { return }
            try timeoutOutputRouteBoundaryLocked(context: &context, at: instant, output: &output)
        }

        /// 借用已准确校验的原context；begin提交以后不以caller旧副本覆盖Authority的poison/清理状态。
        func timeoutOutputRouteBoundaryLocked(context: inout OutputResourceContext, at instant: UInt64,
            output: inout PlaybackOutputSafetyState) throws {
            guard try beginOutputTransitionLocked(context: &context, reason: .terminal,
                anchorInstant: instant, teardown: true, sourceActivation: nil, output: &output) != nil else { return }
            authority.outputContext?.poisoned = true
            authority.routeStabilityCandidate = nil
            authority.stableRouteCommit = nil
            authority.registeredPostConfigurationProof = nil
            output.routeObservationGateOpen = false    }

        func parentAllowsWork(_ parent: CurrentPlaybackOperationDeadlineTicket?, at instant: UInt64) -> Bool {
            guard let parent else { return false }
            let value: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let ticket), .outputRecovery(let ticket): value = ticket }
            let elapsed = value.runningSince.map { instant >= $0 ? instant - $0 : UInt64.max } ?? 0
            let (used, overflow) = value.accumulatedEffectiveTime.addingReportingOverflow(elapsed)
            return !overflow && used < value.cap    }

        func beginOutputTransitionLocked(contextNonce: UInt64, reason: OutputTransitionReason,
            anchorInstant: UInt64, teardown: Bool, sourceActivation: ActivationEpoch?,
            output: inout PlaybackOutputSafetyState) throws -> OutputTransitionOwnerTicket? {
                guard var context = authority.outputContext, context.contextNonce == contextNonce else { return nil }
                return try beginOutputTransitionLocked(context: &context, reason: reason, anchorInstant: anchorInstant,
                    teardown: teardown, sourceActivation: sourceActivation, output: &output)    }

        func beginOutputTransitionLocked(context: inout OutputResourceContext, reason: OutputTransitionReason,
            anchorInstant: UInt64, teardown: Bool, sourceActivation: ActivationEpoch?,
            output: inout PlaybackOutputSafetyState) throws -> OutputTransitionOwnerTicket? {
                guard let reservation = authority.cleanupReservation, reservation.ticket == context.reservation else { return nil }
                let originalPhase = context.phase
                if let sourceActivation, sourceActivation != context.activation { return nil }
                if let owner = context.owner, owner.reason.rawValue > reason.rawValue { return owner }
                if reason == .recovery, context.parentDeadline == nil {
                    context.parentDeadline = try authority.prepareRecoveryParent(context: context,
                        snapshot: authority.snapshot, originInstant: self.instant, resetPreRoute: false,
                        allocator: allocator)
                }
                let owner: OutputTransitionOwnerTicket
                if let existing = context.owner, existing.reason == reason,
                   context.ownerIngressRevision == authority.snapshot.throughRevision { owner = existing }
                else if reason.releasesLease || allocator.isExhausted {
                    owner = .init(identity: reservation.terminalOwner, reason: allocator.isExhausted ? .terminal : reason)
                } else {
                    owner = .init(identity: .init(resourceIdentity: reservation.ticket.ownerGroup.resourceIdentity,
                        nonce: try allocator.next(in: .nonce)), reason: reason)
                }
                let releases = owner.reason.releasesLease || context.disposition == .releaseAfterTeardown
                let needsTeardown = teardown || releases || context.pendingReset != nil
                let finishedPause = context.owner?.reason == .pause && reason != .pause &&
                    context.suspendConfirmed && !context.suspendTimedOut ? context.suspend : nil
                if needsTeardown && context.budget == nil {
                    let budgetAnchor: UInt64
                    if context.poisoned {
                        let failureAnchor = authority.snapshot.firstFailureInstant ?? anchorInstant
                        budgetAnchor = context.suspend.map { min($0.anchorInstant, failureAnchor) } ?? failureAnchor
                    } else {
                        budgetAnchor = finishedPause == nil ?
                            (context.suspend?.anchorInstant ?? anchorInstant) : anchorInstant
                    }
                    do {
                        context.budget = try .init(
                            predecessorIdentity: reservation.ticket.ownerGroup.resourceIdentity,
                            anchorInstant: budgetAnchor, nonce: reservation.ticket.nonce)
                    } catch PlaybackSafetyFailure.clockOverflow where context.poisoned {
                        // 首次失败已位于时钟尾部时不能制造可续杯预算；终态仍沿原预留执行纯清理。
                    }
                }
                var preparedSuspend: PreparedCommand?
                var preparedOwner = reason == .pause ? nil : try prepareOutputCleanupOwner(reservation.ticket, terminal: releases)
                if finishedPause != nil {
                    context.suspend = nil
                    context.suspendConfirmed = false
                    context.suspendRequiresRetirement = false
                    context.suspendPreparedPreserved = false
                    context.closeClaim = nil
                }
                if context.suspend == nil, let backend = authority.ownedBackendResources, let lifecycle = backend.lifecycle {
                    if let finishedPause {
                        preparedSuspend = try prepareSuspendReplacingCompletedPause(finishedPause, reservation: reservation, releases: releases)
                    } else {
                        preparedSuspend = releases ? try prepareReservedCleanup(reservation.ticket, stage: .suspend) :
                            try prepareCommand(group: reservation.ticket.ownerGroup, slot: .suspend,
                                policy: .safetyBypass, audioIdentity: nil, audioPolicy: nil, excludingIndex: preparedOwner?.index)
                    }
                    let ticket = OutputSuspendTicket(task: preparedSuspend!.ticket, lifecycle: lifecycle,
                        priorActivation: context.activation, anchorInstant: anchorInstant)
                    context.suspend = ticket
                    if let interval = context.interval {
                        guard context.closeClaim == nil else { return nil }
                        context.closeClaim = .init(intervalKey: interval, suspendTicket: ticket, stopNonce: ticket.task.nonce)
                    }
                }
                context.owner = owner
                if authority.snapshot.failure != nil { context.poisoned = true }
                context.ownerIngressRevision = authority.snapshot.throughRevision
                context.teardownRequested = context.teardownRequested || needsTeardown
                if releases { context.disposition = .releaseAfterTeardown; context.relayClosing = true }
                if context.phase == .pendingSuccessorLease && releases {
                    guard let nonce = reservation.nonce(for: .leaseOnly) else { return nil }
                    context.contextNonce = nonce
                    context.phase = .leaseOnlyCleanup
                }
                if case .acquiringLease = authority.resourceState, releases,
                   authority.commands.allSatisfy({ record in
                       guard let record, record.groupTicket == reservation.ticket.workGroup else { return true }
                       guard case .terminal = record.phase else { return false }
                       return authority.mayDiscard(record)
                   }) {
                    guard let nonce = reservation.nonce(for: .leaseOnly) else { return nil }
                    context.contextNonce = nonce
                    context.phase = .leaseOnlyCleanup
                }
                // prepare以后固定安装；不会在消费转换票之后再签发身份或拒绝。
                if context.phase == .leaseOnlyCleanup, originalPhase != .leaseOnlyCleanup {
                    authority.cleanupReservation?.consume(.leaseOnly)
                    if let lease = authority.ownedLeaseResources {
                        authority.resourceState = .leaseOnlyCleanup(context, .owned(lease))
                    }
                }
                if let finishedPause, let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == finishedPause.task }) {
                    authority.commands[index] = nil
                }
                preparedSuspend?.installForOutputTransition(on: authority)
                preparedOwner?.installForOutputTransition(on: authority)
                authority.outputContext = context
                output.outputPermitPresent = false
                output.readinessOpen = false
                if releases { terminateCleanupReservationLocked(reservation.ticket, output: &output) }
                else if reason != .pause {
                    sealOutputWorkLocked(reservation.ticket.workGroup)
                }
                return owner    }

        func sealOutputWorkLocked(_ group: ControlTaskGroupTicket) {
            for index in authority.groups.indices {
                guard let ticket = authority.groups[index]?.ticket else { continue }
                if ticket == group || authority.isDescendant(ticket, of: group) { authority.groups[index]?.sealed = true }
            }
            for index in authority.commands.indices {
                guard let ticket = authority.commands[index]?.groupTicket else { continue }
                if ticket == group || authority.isDescendant(ticket, of: group) { authority.cancel(index) }
            }    }

        func prepareSuspendReplacingCompletedPause(_ old: OutputSuspendTicket,
            reservation: CleanupReservation, releases: Bool) throws -> PreparedCommand {
            guard let oldIndex = authority.commands.firstIndex(where: { $0?.controlTaskTicket == old.task }),
                  let oldRecord = authority.commands[oldIndex], oldRecord.phase == .terminal(.completed),
                  oldRecord.slot == .suspend, authority.mayDiscard(oldRecord) else { throw Failure.invalidPolicy }
            let index: Int
            let ticket: ControlTaskTicket
            if releases {
                let reserved = reservation[.suspend]
                guard !reserved.consumed, authority.commands[reserved.index] == nil else { throw Failure.slotOccupied }
                index = reserved.index
                ticket = reservation.task(for: .suspend)
            } else {
                index = oldIndex
                ticket = .init(group: reservation.ticket.ownerGroup, nonce: try allocator.next(in: .controlTask))
            }
            let record = try OwnedPostIngressControlCommand(controlTaskTicket: ticket,
                slot: .suspend, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
            return .init(index: index, ticket: ticket, record: record, reservedStage: releases ? .suspend : nil)    }

        func expireOutputAcquisitionLocked(output: inout PlaybackOutputSafetyState) throws -> Bool {
                if try expireResetPreRouteLocked(output: &output) { return true }
                guard var context = authority.outputContext, context.phase == .pendingLeaseAcquisition,
                      let deadline = context.acquisitionDeadline, let reservation = authority.cleanupReservation else { return false }
                let instant = self.instant
                guard instant >= deadline.deadlineInstant else { return false }
                if context.poisoned { return true }
                let budget = try context.budget ?? CleanupBudgetTicket(predecessorIdentity: reservation.ticket.ownerGroup.resourceIdentity,
                    anchorInstant: instant, nonce: reservation.ticket.nonce)
                let preparedOwner = try prepareOutputCleanupOwner(reservation.ticket, terminal: true)
                context.owner = .init(identity: reservation.terminalOwner, reason: .terminal)
                context.poisoned = true
                context.disposition = .releaseAfterTeardown
                context.relayClosing = true
                context.teardownRequested = true
                context.budget = budget
                authority.outputContext = context
                _ = installPreparedCommand(preparedOwner)
                terminateCleanupReservationLocked(reservation.ticket, output: &output)
                output.outputPermitPresent = false
                output.readinessOpen = false
                return true    }

        func beginOutputRetainedResetConfigurationStep(contextNonce: UInt64, output: inout PlaybackOutputSafetyState) throws -> ControlTaskTicket? {
            guard try !expireResetPreRouteLocked(output: &output),
                  let context = authority.outputContext, context.phase == .pendingSuccessorLease,
                  context.contextNonce == contextNonce, !context.poisoned, context.disposition != .releaseAfterTeardown,
                  let binding = context.systemRecoveryBinding, binding.inactiveConfigurationReceipt == nil,
                  context.pendingReset == authority.currentResetRoot,
                  binding.incarnation.identity.root == context.pendingReset,
                  binding.incarnation.baseConfigurationGeneration == authority.currentConfigurationGeneration,
                  var phase = authority.audioPhase, phase.identity.contextNonce == contextNonce,
                  phase.identity.owner == context.reservation.workGroup.ownerTicket,
                  phase.incarnation == binding.incarnation, phase.resetBinding == binding.resetPreRouteBinding,
                  phase.inactiveReceipt == nil, phase.permitsFurtherCalls, authority.matchesResetBinding(phase) else { return nil }
            let step: AudioSessionConfigurationStep
            switch phase.configurationProgress {
            case .awaitingLongForm: step = .longFormCategoryAttempt
            case .awaitingFallback: step = .defaultCategoryFallbackAttempt
            case .awaitingMultichannel: step = .multichannelCapability
            default: return nil
            }
            phase.policy = .configureInactive(incarnation: binding.incarnation.identity,
                resetDrainProof: binding.resetDrainProof.identity, configurationAttemptNonce: phase.configurationAttempt.nonce,
                step: step)
            let command = try prepareCommand(group: context.reservation.workGroup, slot: .audioSessionRecovery,
                policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy)
            authority.audioPhase = phase
            return installPreparedCommand(command)
        }

        func settleOutputRetainedResetConfiguration(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard try !expireResetPreRouteLocked(output: &output),
                  var context = authority.outputContext, context.phase == .pendingSuccessorLease,
                  !context.poisoned, context.disposition != .releaseAfterTeardown,
                  let binding = context.systemRecoveryBinding, binding.inactiveConfigurationReceipt == nil,
                  context.pendingReset == authority.currentResetRoot,
                  binding.incarnation.identity.root == context.pendingReset,
                  binding.incarnation.baseConfigurationGeneration == authority.currentConfigurationGeneration,
                  let phase = authority.audioPhase, phase.identity.contextNonce == context.contextNonce,
                  phase.identity.owner == context.reservation.workGroup.ownerTicket,
                  phase.incarnation == binding.incarnation, phase.resetBinding == binding.resetPreRouteBinding,
                  phase.inactiveReceipt == nil, phase.permitsFurtherCalls, authority.matchesResetBinding(phase),
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.groupTicket == context.reservation.workGroup, record.audioPhaseIdentity == phase.identity,
                  record.phase == .terminal(.completed), record.resultClaimed, !record.resultInvalidated,
                  case .configureInactive(let incarnation, let proof, let attempt, .multichannelCapability) = record.audioPolicy,
                  incarnation == binding.incarnation.identity, proof == binding.resetDrainProof.identity,
                  attempt == phase.configurationAttempt.nonce,
                  case .complete(let policy, let failure, let multichannel) = phase.configurationProgress else { return false }
            let receipt = InactiveAudioSessionConfigurationReceipt(identity: .init(
                mediaServicesEpoch: phase.configurationAttempt.mediaServicesEpoch,
                attemptNonce: attempt, receiptNonce: try allocator.next(in: .nonce)), actualPolicy: policy,
                preferredFailureReason: failure, planDigest: phase.configurationAttempt.plan,
                attemptLineage: phase.configurationAttempt, multichannelCapability: multichannel)
            context.resetResourceBinding = .retained(.init(incarnation: binding.incarnation,
                inactiveConfigurationReceipt: receipt, resetPreRouteBinding: binding.resetPreRouteBinding,
                configurationState: phase.configurationProgress))
            authority.outputContext = context
            authority.audioPhase?.inactiveReceipt = receipt
            return true
        }

        func parentEffectiveElapsed(_ parent: PlaybackProgressBudgetTicket, at instant: UInt64) -> UInt64? {
            authority.parentEffectiveElapsed(parent, at: instant)    }

        func reactivationAllowsWorkLocked(_ phase: RegisteredAudioSessionPhase, at instant: UInt64) -> Bool {
            guard let state = phase.reactivationState, state.basePhase == .awaitingActivation,
                  !state.freezeCauses.activationBlocked, let context = authority.outputContext,
                  context.contextNonce == phase.identity.contextNonce, !context.poisoned,
                  context.disposition != .releaseAfterTeardown, let original = context.parentDeadline,
                  case .activate(let purpose, _, _, _) = phase.policy, authority.matchesPurpose(purpose, phase: phase) else { return false }
            let parent: PlaybackProgressBudgetTicket
            switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
            guard parent.identity == state.ticket.parentOperationTicketIdentity,
                  let elapsed = parentEffectiveElapsed(parent, at: instant), elapsed < state.ticket.activationCutoffEffectiveElapsed else { return false }
            if let stage = authority.postConfigurationRouteState {
                return routeBoundaryAllowsWorkLocked(.postConfiguration(stage.budget.configurationTransitionIdentity,
                    stageIdentity: stage.budget.stageIdentity), at: instant)
            }
            guard case .pending(let pending) = authority.routeObservationState, let deadline = pending.deadline else { return false }
            return instant < deadline.deadlineInstant    }

        private enum ReactivationClaimDeadline {
            case continueClaim, rejectWithoutTimeout, timeout(UInt64)
        }

        /// 仅供原reactivate记录的同CAS截止判断；大值退出后才由caller执行原timeout。
        private func classifyReactivationClaimDeadline() -> ReactivationClaimDeadline {
            guard let phase = authority.audioPhase else { return .continueClaim }
            guard !reactivationAllowsWorkLocked(phase, at: instant) else { return .continueClaim }
            guard let context = authority.outputContext else { return .rejectWithoutTimeout }
            return .timeout(context.contextNonce)
        }

        private enum ReactivationCompletionValidation {
            case rejected, originalContext(UInt64)
        }

        private enum ReactivationCompletionDeadline {
            case rejected, eligible, expired(UInt64)
        }

        /// 先验证原票与原call；本函数返回以前不调用deadline/timeout，也不授权离锁工作。
        private func validateOriginalReactivationCompletion(_ ticket: ControlTaskTicket) -> ReactivationCompletionValidation {
            guard let context = authority.outputContext, authority.audioPhase != nil,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.phase == .terminal(.completed),
                  !record.resultInvalidated, !record.activationResponsibilityTransferred,
                  case .returnedSuccess(let call) = record.activationOutcome, context.pendingActivationCall == call,
                  call.record == ticket, authority.matchesAudio(record), record.audioPhaseIdentity != nil,
                  context.sessionReceipts != nil, context.committedRelay != nil,
                  case .pending = authority.routeObservationState else { return .rejected }
            return .originalContext(context.contextNonce)
        }

        /// 验证栈已退出；此处只有原context标识，完整phase/第二context不与settle大值并存。
        private func classifyReactivationCompletionDeadline(_ ticket: ControlTaskTicket) -> ReactivationCompletionDeadline {
            guard case .originalContext(let contextNonce) = validateOriginalReactivationCompletion(ticket),
                  let phase = authority.audioPhase else { return .rejected }
            return reactivationAllowsWorkLocked(phase, at: instant) ? .eligible : .expired(contextNonce)
        }

        /// deadline栈也完整退出后才执行准确原timeout；旧票拒绝不能触碰新版context。
        private func prepareReactivationCompletion(_ ticket: ControlTaskTicket,
            output: inout PlaybackOutputSafetyState) throws -> Bool {
            switch classifyReactivationCompletionDeadline(ticket) {
            case .rejected: return false
            case .eligible: return true
            case .expired(let contextNonce):
                try timeoutOutputRouteBoundaryLocked(contextNonce: contextNonce, at: instant, output: &output)
                return false
            }
        }

        func settleOutputReactivation(_ ticket: ControlTaskTicket, output: inout PlaybackOutputSafetyState,
            followUp: inout ControlTaskTicket?) throws -> Bool {
            guard try prepareReactivationCompletion(ticket, output: &output) else { return false }
            // 仍在同一Cell/CAS，重新取准确原票；验证分类从不返回给外部或变成可复用权限。
            guard var context = authority.outputContext, var phase = authority.audioPhase,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.phase == .terminal(.completed),
                  !record.resultInvalidated, !record.activationResponsibilityTransferred,
                  case .returnedSuccess(let call) = record.activationOutcome, context.pendingActivationCall == call,
                  call.record == ticket, authority.matchesAudio(record), let identity = record.audioPhaseIdentity,
                  var receipts = context.sessionReceipts, let relay = context.committedRelay,
                  case .pending(var pending) = authority.routeObservationState else { return false }
            guard authority.routeSampleClaim == nil,
                  !authority.commands.contains(where: { $0?.slot == .sampler }) else { return false }
            let active = ActiveSessionReceipt(leaseID: identity.leaseID, configurationGeneration: authority.currentConfigurationGeneration,
                interruptionEpoch: authority.snapshot.interruptionEpoch, activationNonce: try allocator.next(in: .activation))
            let observation = RouteObservationTicket(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: relay.relayIdentity.monitorLifecycle,
                mediaServicesEpoch: authority.snapshot.mediaServicesEpoch, interruptionEpoch: authority.snapshot.interruptionEpoch,
                audioSessionConfigurationGeneration: authority.currentConfigurationGeneration, audioSessionActivationNonce: active.activationNonce,
                configurationTransitionIdentity: authority.postConfigurationRouteState?.budget.configurationTransitionIdentity,
                observationNonce: try allocator.next(in: .nonce))
            let sampler = try prepareCommand(group: context.reservation.workGroup, slot: .sampler, policy: .safetyBypass,
                audioIdentity: nil, audioPolicy: nil)
            receipts.active = active
            context.sessionReceipts = receipts
            context.pendingActivationCall = nil
            phase.reactivationState?.basePhase = .activatedAwaitingFirstProgress
            phase.reactivationState?.cutoffArmTicket = nil
            pending.ticket = observation
            pending.sampler = sampler.ticket
            pending.sampleInFlight = false
            pending.resamplePending = false
            authority.outputContext = context
            authority.ownedResource?.payload.lease?.deactivation = .requiresDeactivate(.activeReceipt(active, identity))
            authority.audioPhase = phase
            authority.routeObservationState = .pending(pending)
            authority.commands[index]?.activationResponsibilityTransferred = true
            authority.commands[index]?.resultClaimed = true
            followUp = installPreparedCommand(sampler)
            output.routeObservationGateOpen = false
            return true
        }

        func settleResetParentClockLocked(_ state: ResetPreRouteRecoveryDeadlineState,
            context: inout OutputResourceContext) {
            guard let parent = context.parentDeadline else { return }
            var value: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let current), .outputRecovery(let current): value = current }
            precondition(value.identity == state.ticketIdentity.parentOperationTicketIdentity)
            precondition(state.accumulatedEffectiveTime >= value.accumulatedEffectiveTime)
            value.accumulatedEffectiveTime = state.accumulatedEffectiveTime
            value.runningSince = state.runningSince
            value.freezeGeneration = state.freezeGeneration
            switch parent {
            case .coldStart: context.parentDeadline = .coldStart(value)
            case .outputRecovery: context.parentDeadline = .outputRecovery(value)
            }    }

        func expireResetPreRouteLocked(output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard var context = authority.outputContext, let binding = context.resetPreRouteBinding,
                  var state = authority.resetPreRouteState, state.ticketIdentity == binding.ticketIdentity,
                  context.pendingReset == binding.rootIdentity, authority.currentResetRoot == binding.rootIdentity else { return false }
            if context.poisoned { return true }
            let instant = self.instant
            guard let elapsed = state.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
            guard elapsed >= state.boundaryEffectiveElapsed ||
                context.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute.map({ instant >= $0.deadlineInstant }) == true else { return false }
            try timeoutResetPreRouteLocked(context: &context, state: &state, elapsed: elapsed, instant: instant, output: &output)
            return true    }

        func timeoutResetPreRouteLocked(context: inout OutputResourceContext,
            state: inout ResetPreRouteRecoveryDeadlineState, elapsed: UInt64, instant: UInt64,
            output: inout PlaybackOutputSafetyState) throws {
            let budget = try context.budget ?? CleanupBudgetTicket(predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                anchorInstant: instant, nonce: context.reservation.nonce)
            let preparedOwner = try prepareOutputCleanupOwner(context.reservation, terminal: true)
            state.accumulatedEffectiveTime = elapsed
            state.runningSince = nil
            state.deadlineArm = nil
            settleResetParentClockLocked(state, context: &context)
            context.poisoned = true
            context.disposition = .releaseAfterTeardown
            context.relayClosing = true
            context.teardownRequested = true
            context.budget = budget
            context.owner = .init(identity: authority.cleanupReservation!.terminalOwner, reason: .terminal)
            authority.outputContext = context
            authority.resetPreRouteState = state
            _ = installPreparedCommand(preparedOwner)
            terminateCleanupReservationLocked(context.reservation, output: &output)
            output.outputPermitPresent = false
            output.readinessOpen = false
            output.routeObservationGateOpen = false    }
    }

    private struct PreparedCommand {
        let index: Int
        let ticket: ControlTaskTicket
        // nil仅表示准确已有record的join，不是新增可执行phase或持久槽。
        let record: OwnedPostIngressControlCommand?
        let reservedStage: ReservedCleanupStage?

        /// 可变optional chaining只借原本地payload；字段不变，安装判定仍只有Authority一份。
        mutating func installForOutputTransition(on authority: Authority) {
            authority.installPreparedCommandFields(self)
        }
    }
    static var boundedCommandPreparationValueBytes: Int { MemoryLayout<PreparedCommand>.stride }
    static var audioSessionLockedOperationsValueBytes: Int { MemoryLayout<AudioSessionLockedOperations>.stride }
    static var audioSessionCompletionFollowUpValueBytes: Int { Authority.audioSessionCompletionFollowUpValueBytes }
    static var audioSessionClaimPreparationValueBytes: Int { Authority.audioSessionClaimPreparationValueBytes }
    static var audioSessionInFlightPermitValueBytes: Int { MemoryLayout<Authority.AudioSessionInFlightPermit?>.stride }
    static var boundedReactivationPreparationValueBytes: Int {
        return MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OwnedAudioSessionLeaseResources>.stride +
            MemoryLayout<RegisteredAudioSessionPhase>.stride + MemoryLayout<OutputSessionReceipts>.stride +
            MemoryLayout<AudioSessionPhaseIdentity>.stride + MemoryLayout<AudioSessionPhasePolicy>.stride +
            MemoryLayout<AudioSessionConfigurationAttempt>.stride + MemoryLayout<PlaybackProgressBudgetTicket.Identity>.stride +
            MemoryLayout<SystemRecoveryIncarnation?>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + MemoryLayout<PlaybackProgressBudgetTicket>.stride +
            MemoryLayout<PostConfigurationRouteState?>.stride + MemoryLayout<AudioSessionReactivationProof>.stride +
            MemoryLayout<InterruptionDrainProof?>.stride +
            MemoryLayout<PendingRouteObservation>.stride + MemoryLayout<AudioSessionReactivationBudgetState>.stride +
            MemoryLayout<PreparedOutputCycle?>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<AudioSessionActivationInvocationIdentity>.stride + MemoryLayout<AudioSessionReactivationAttemptTicket>.stride +
            MemoryLayout<PreparedCommand?>.stride + MemoryLayout<OwnedPostIngressControlCommand>.stride +
            MemoryLayout<RouteUnavailableDeadlineTicket>.stride + MemoryLayout<ActiveSessionReceipt>.stride +
            MemoryLayout<RouteObservationTicket>.stride + MemoryLayout<PlaybackSafetySnapshot>.stride +
            MemoryLayout<ControlTaskGroupTicket>.stride + MemoryLayout<ControlCommandSafetySnapshot>.stride +
            max(MemoryLayout<Authority.ReactivationPreparation>.stride, 8) + 10 * MemoryLayout<UInt64>.stride
    }

    static var boundedUserControlPreparationValueBytes: Int {
        let reactivation = boundedReactivationPreparationValueBytes + MemoryLayout<OutputUserControlRequest>.stride +
            MemoryLayout<PlaybackSafetySnapshot>.stride + MemoryLayout<ResetPreRouteRecoveryDeadlineState?>.stride +
            MemoryLayout<OutputUserControlResult>.stride + MemoryLayout<OutputUserControlSafetyUpdate>.stride +
            2 * MemoryLayout<UInt64>.stride
        let terminal = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<RegisteredAudioSessionPhase>.stride +
            MemoryLayout<OutputUserControlRequest>.stride + MemoryLayout<PlaybackSafetySnapshot>.stride +
            MemoryLayout<ResetPreRouteRecoveryDeadlineState?>.stride + MemoryLayout<PostConfigurationRouteState?>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + MemoryLayout<PlaybackProgressBudgetTicket>.stride +
            MemoryLayout<CleanupBudgetTicket>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<PreparedCommand?>.stride + MemoryLayout<PreparedOutputCycle?>.stride +
            max(MemoryLayout<Authority.ReactivationPreparation>.stride, 8) + MemoryLayout<PendingRouteObservation?>.stride +
            MemoryLayout<OutputControlApplication>.stride + 8 * MemoryLayout<UInt64>.stride
        return max(reactivation, terminal) + MemoryLayout<OutputControlRequest>.stride +
            MemoryLayout<OutputControlApplication>.stride
    }

    static var boundedInterruptionDrainPreparationValueBytes: Int {
        boundedReactivationPreparationValueBytes + MemoryLayout<InterruptionDrainProof>.stride +
            MemoryLayout<InterruptionDrainedResourceShape>.stride + MemoryLayout<OutputTransitionOwnerTicket>.stride +
            MemoryLayout<OutputControlRequest>.stride + MemoryLayout<OutputControlApplication>.stride +
            MemoryLayout<OutputInterruptionDrainSettlement>.stride
    }

    static var boundedRouteSamplerReplacementPreparationValueBytes: Int {
        MemoryLayout<PendingRouteObservation>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + 2 * MemoryLayout<ControlTaskTicket>.stride +
            4 * MemoryLayout<UInt64>.stride
    }

    static var boundedRouteSamplePreparationValueBytes: Int {
        // dispatch完整请求/参数与锁内候选；current权威投影显式借同一已提交context。
        // deadline分支另计原terminal owner准备，未以增量字段代替嵌套峰。
        let common = MemoryLayout<OutputControlRequest>.stride + MemoryLayout<OutputControlApplication>.stride +
            MemoryLayout<OutputRouteSampleClaim>.stride + MemoryLayout<OutputRouteSampleResult>.stride +
            2 * MemoryLayout<PlaybackSafetySnapshot>.stride + MemoryLayout<PendingRouteObservation>.stride +
            MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OutputAuthoritativeRoute>.stride +
            MemoryLayout<OutputRouteAvailabilityBoundary>.stride + MemoryLayout<AudioSessionReactivationBudgetState?>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + MemoryLayout<PlaybackProgressBudgetTicket>.stride +
            MemoryLayout<PostConfigurationRouteState>.stride + 10 * MemoryLayout<UInt64>.stride +
            MemoryLayout<AudioSessionRouteSampleEvidence?>.stride + MemoryLayout<OutputRouteSampleResult>.stride +
            MemoryLayout<SessionEndpointFingerprint?>.stride + MemoryLayout<OutputConfigurationIncarnation?>.stride +
            MemoryLayout<SessionEndpointFingerprint>.stride + MemoryLayout<EndpointTopologyToken>.stride
        let projection = 2 * MemoryLayout<UnsafeRawPointer>.stride + MemoryLayout<OutputAcquisitionCommitToken>.stride +
            MemoryLayout<ActiveSessionReceipt>.stride + 2 * MemoryLayout<PlaybackRouteAuthorityIdentity>.stride +
            MemoryLayout<OutputRouteStabilityCandidate>.stride
        let terminal = MemoryLayout<CleanupBudgetTicket>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<CleanupReservation>.stride
        // 单次getter结束后准备后继时，caller的pending/context仍活；callee另持pending参数、原/新ticket、
        // 新record和PreparedCommand返回槽。旧record留在Authority固定池，不重复计入临时峰。
        return common + max(projection, terminal, boundedRouteSamplerReplacementPreparationValueBytes)
    }

    static var boundedSuspendControlPreparationValueBytes: Int {
        MemoryLayout<OutputControlRequest>.stride + MemoryLayout<OutputControlApplication>.stride +
            MemoryLayout<OutputSuspendControlAction>.stride + MemoryLayout<OutputSuspendControlResult>.stride +
            MemoryLayout<OutputQuiescenceReceipt>.stride + MemoryLayout<OutputSuspendTicket>.stride +
            2 * MemoryLayout<PlaybackSafetySnapshot>.stride + 2 * MemoryLayout<OutputResourceContext>.stride +
            MemoryLayout<CleanupReservation>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<CleanupBudgetTicket>.stride +
            8 * MemoryLayout<UInt64>.stride
    }

    static var boundedPlaybackBudgetDecisionPreparationValueBytes: Int {
        // evaluate阶段持闭合请求、Authority参数与返回decision槽；终态owner尚未开始准备。
        // 两份context覆盖media progress最坏形态：resourceState完整枚举投影与其解构出的可变context候选。
        // reset分支的原state在构造返回值时与含settled-parent/state的紧凑decision短暂重叠。
        let common = MemoryLayout<OutputControlRequest>.stride + MemoryLayout<OutputControlApplication>.stride +
            MemoryLayout<PlaybackBudgetControlAction>.stride + MemoryLayout<PlaybackBudgetControlResult>.stride +
            2 * MemoryLayout<PlaybackSafetySnapshot>.stride + 2 * MemoryLayout<OutputResourceContext>.stride +
            Authority.playbackBudgetEvaluationValueBytes +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride +
            MemoryLayout<PlaybackProgressBudgetTicket>.stride + 8 * MemoryLayout<UInt64>.stride
        let reset = MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            MemoryLayout<ResetPreRouteRecoveryDeadlineArmTicket>.stride +
            MemoryLayout<PlaybackDeadlineRearm<ResetPreRouteRecoveryDeadlineArmTicket>>.stride +
            MemoryLayout<ResetPreRouteTicketBinding>.stride +
            MemoryLayout<InheritedRouteAvailabilityConstraint?>.stride
        let inheritedOrdinary = MemoryLayout<PendingRouteObservation>.stride +
            MemoryLayout<OrdinaryRouteDeadlineState>.stride +
            MemoryLayout<InheritedRouteAvailabilityConstraint>.stride +
            MemoryLayout<SystemRecoveryIncarnation>.stride + MemoryLayout<SystemRecoveryLeaseBinding>.stride +
            MemoryLayout<PostConfigurationRouteState?>.stride +
            MemoryLayout<PlaybackDeadlineRearm<RouteUnavailableDeadlineArmTicket>>.stride
        let post = MemoryLayout<PostConfigurationRouteState>.stride +
            MemoryLayout<PostConfigurationRouteDeadlineArmTicket>.stride +
            MemoryLayout<PlaybackDeadlineRearm<PostConfigurationRouteDeadlineArmTicket>>.stride +
            MemoryLayout<InheritedRouteAvailabilityConstraint?>.stride
        let reactivation = MemoryLayout<RegisteredAudioSessionPhase>.stride +
            MemoryLayout<AudioSessionReactivationBudgetState>.stride +
            MemoryLayout<AudioSessionReactivationCutoffArmTicket>.stride +
            MemoryLayout<PlaybackDeadlineRearm<AudioSessionReactivationCutoffArmTicket>>.stride +
            max(MemoryLayout<PostConfigurationRouteState?>.stride,
                MemoryLayout<PendingRouteObservation?>.stride)
        let progress = MemoryLayout<PlaybackMediaProgressReceipt>.stride +
            MemoryLayout<OwnedBackendResources>.stride + MemoryLayout<ActiveSessionReceipt>.stride +
            MemoryLayout<PlaybackRouteAuthorityIdentity>.stride + MemoryLayout<StableRouteCommitIdentity>.stride +
            MemoryLayout<PotentiallyAudibleOutputIntervalKey>.stride
        let parent = MemoryLayout<PlaybackOperationDeadlineArmTicket>.stride +
            MemoryLayout<PlaybackDeadlineRearm<PlaybackOperationDeadlineArmTicket>>.stride
        return common + max(reset, inheritedOrdinary, post, reactivation, progress, parent)
    }

    static var playbackBudgetEvaluationDecisionValueBytes: Int {
        Authority.playbackBudgetEvaluationValueBytes
    }

    private static var boundedPlaybackBudgetTerminalCommonValueBytes: Int {
        // evaluate已返回；具体timer/phase/pending局部不再存活。Cell/request返回槽、decision及switch投影仍在，
        // 与唯一终态owner/budget准备重叠；scheduler在另一同步ingress持Cell锁时另行叠加。
        MemoryLayout<OutputControlRequest>.stride + MemoryLayout<OutputControlApplication>.stride +
            MemoryLayout<PlaybackBudgetControlAction>.stride + MemoryLayout<PlaybackBudgetControlResult>.stride +
            2 * MemoryLayout<PlaybackSafetySnapshot>.stride + Authority.playbackBudgetEvaluationValueBytes +
            MemoryLayout<OutputResourceContext>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<CleanupBudgetTicket>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<OutputTransitionOwnerTicket>.stride +
            6 * MemoryLayout<UInt64>.stride
    }

    static var boundedPlaybackBudgetTerminalPreparationValueBytes: Int {
        boundedPlaybackBudgetTerminalCommonValueBytes
    }

    static var boundedPlaybackBudgetResetTerminalPreparationValueBytes: Int {
        // terminateReset的settled parent/state从decision投影出来，在全部可失败准备结束后才统一安装。
        boundedPlaybackBudgetTerminalCommonValueBytes +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride +
            MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride
    }

    static var boundedPlaybackBudgetPreparationValueBytes: Int {
        max(boundedPlaybackBudgetDecisionPreparationValueBytes,
            boundedPlaybackBudgetTerminalPreparationValueBytes,
            boundedPlaybackBudgetResetTerminalPreparationValueBytes)
    }

    static var boundedOpenRouteObservationPreparationValueBytes: Int {
        // 已open普通观察要求双epoch/fence完全不变，所以不能与interruption/reset准备同时存活；
        // 这里完整计入apply参数、helper局部、返回候选及PreparedCommand内的owned record。
        let open = MemoryLayout<PlaybackSafetySnapshot>.stride + MemoryLayout<Authority.PreparedOpenRouteObservation>.stride +
            MemoryLayout<PendingRouteObservation>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<OutputResourceContext>.stride +
            MemoryLayout<PlaybackRouteAuthorityIdentity>.stride + MemoryLayout<PlaybackRouteIngress>.stride +
            MemoryLayout<RouteUnavailableDeadlineTicket>.stride + MemoryLayout<OrdinaryRouteDeadlineState>.stride +
            MemoryLayout<RouteObservationTicket>.stride + MemoryLayout<CleanupReservation>.stride +
            8 * MemoryLayout<UInt64>.stride
        // 已pending且sampler idle时，apply保留可选返回槽；helper的pending参数与后继record准备重叠。
        // current authority投影先于checked后继准备结束，两者取max而非虚构同时存活。
        return max(open, boundedPendingRouteResamplePreparationValueBytes)
    }

    static var boundedPendingRouteResamplePreparationValueBytes: Int {
        let pendingCommon = MemoryLayout<PlaybackSafetySnapshot>.stride +
            MemoryLayout<PlaybackRouteIngress>.stride + MemoryLayout<PendingRouteObservation>.stride +
            MemoryLayout<PreparedCommand?>.stride + MemoryLayout<CleanupReservation>.stride +
            8 * MemoryLayout<UInt64>.stride
        let authorityProjection = MemoryLayout<OutputResourceContext>.stride +
            MemoryLayout<ActiveSessionReceipt>.stride + MemoryLayout<PlaybackRouteAuthorityIdentity>.stride
        return pendingCommon + max(authorityProjection, boundedRouteSamplerReplacementPreparationValueBytes)
    }

    static var boundedOutputTransitionPreparationValueBytes: Int {
        let common = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<OutputTransitionOwnerTicket>.stride + MemoryLayout<OwnedBackendResources>.stride +
            MemoryLayout<OutputLifecycleEpoch>.stride + MemoryLayout<OutputSuspendTicket?>.stride +
            MemoryLayout<CleanupBudgetTicket>.stride + 6 * MemoryLayout<UInt64>.stride
        // 第二次prepare调用时，首个返回值、第二个返回槽与callee的record/ticket/reserved局部同时存活。
        let commandPreparation = 2 * MemoryLayout<PreparedCommand?>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<ControlTaskTicket>.stride +
            MemoryLayout<ReservedCleanupSlot>.stride
        // suspend/close claim构造发生在prepare返回后；不和callee record局部相加。
        let suspendInstallation = 2 * MemoryLayout<PreparedCommand?>.stride +
            MemoryLayout<OutputSuspendTicket>.stride + MemoryLayout<PotentiallyAudibleOutputIntervalKey>.stride +
            MemoryLayout<PotentiallyAudibleOutputCloseClaim>.stride
        return common + max(commandPreparation, suspendInstallation)
    }

    static var boundedClosedAirPlayPolicyTerminalPreparationValueBytes: Int {
        // commit的局部context直接传入私有准备，故这里只另计外层candidate/ticket；transition已含唯一context。
        boundedOutputTransitionPreparationValueBytes + MemoryLayout<OutputRouteStabilityCandidate>.stride +
            MemoryLayout<RouteStabilityTicket>.stride
    }

    static var boundedResourceTransitionPreparationValueBytes: Int {
        let resetIngress = MemoryLayout<Authority.PreparedResetIngress>.stride +
            MemoryLayout<OutputResourceContext>.stride + 2 * MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            2 * MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + MemoryLayout<PlaybackProgressBudgetTicket>.stride +
            2 * MemoryLayout<ResetPreRouteClockFold>.stride + MemoryLayout<ResetPreRouteTicketBinding>.stride +
            MemoryLayout<Authority.PreparedResetTerminal>.stride + MemoryLayout<OwnedPostIngressControlCommand>.stride +
            MemoryLayout<CleanupReservation>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<ResetPreRouteRecoveryDeadlineTicket.Identity>.stride + MemoryLayout<CleanupBudgetTicket>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket?>.stride +
            2 * MemoryLayout<PostConfigurationRouteState?>.stride +
            MemoryLayout<InheritedRouteAvailabilityConstraint?>.stride + MemoryLayout<OrdinaryRouteDeadlineState>.stride +
            8 * MemoryLayout<UInt64>.stride
        let retainedReset = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OwnedAudioSessionLeaseResources>.stride +
            MemoryLayout<OutputResetDrainingBinding>.stride + MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + MemoryLayout<PlaybackProgressBudgetTicket>.stride +
            MemoryLayout<PreparedOutputCycle>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<ResetDrainProof>.stride + MemoryLayout<SystemRecoveryIncarnation>.stride +
            MemoryLayout<ResetPreRouteTicketBinding>.stride + MemoryLayout<AudioSessionConfigurationAttempt>.stride +
            MemoryLayout<RegisteredAudioSessionPhase>.stride + MemoryLayout<PreparedCommand>.stride +
            MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<SystemRecoveryLeaseBinding>.stride +
            8 * MemoryLayout<UInt64>.stride
        let reactivation = boundedReactivationPreparationValueBytes
        let userControl = boundedUserControlPreparationValueBytes
        let handoff = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OutputConfiguredAcquisition>.stride +
            MemoryLayout<ActiveSessionReceipt>.stride + 2 * MemoryLayout<PreparedCommand>.stride + MemoryLayout<CleanupBudgetTicket>.stride +
            MemoryLayout<PendingRouteObservation>.stride + MemoryLayout<OutputAcquisitionCommitToken>.stride +
            MemoryLayout<OutputAcquisitionHandoff>.stride + MemoryLayout<PlaybackRouteAuthorityIdentity>.stride +
            MemoryLayout<RouteUnavailableDeadlineTicket>.stride + MemoryLayout<RouteObservationTicket>.stride
        let rebase = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OutputRetainedRebaseResult>.stride +
            MemoryLayout<OutputSuccessorClaim?>.stride + MemoryLayout<StableRouteCommitIdentity>.stride +
            MemoryLayout<PlaybackRouteAuthorityIdentity>.stride + MemoryLayout<OutputSuccessorCreationOwner>.stride
        let resetAdmission = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<PreparedCommand>.stride + MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            MemoryLayout<ResetPreRouteRecoveryDeadlineTicket>.stride + MemoryLayout<OutputResetAcquisitionBinding>.stride +
            MemoryLayout<OutputResetAcquisitionAdmission>.stride + MemoryLayout<OutputRegisteredDrainProof?>.stride +
            MemoryLayout<MediaServicesResetRootIdentity?>.stride + MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride +
            MemoryLayout<PlaybackProgressBudgetTicket>.stride
        let inactiveHandoff = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<OutputAcquiredLease>.stride +
            MemoryLayout<InactiveAudioSessionConfigurationReceipt>.stride + MemoryLayout<OutputResetAcquisitionBinding>.stride +
            MemoryLayout<SystemRecoveryIncarnation>.stride + MemoryLayout<SystemRecoveryLeaseBinding>.stride +
            2 * MemoryLayout<RegisteredAudioSessionPhase>.stride + MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride + 2 * MemoryLayout<OutputAcquisitionCommitToken>.stride +
            MemoryLayout<OutputSessionRelayIdentity>.stride + MemoryLayout<OutputAcquisitionHandoff>.stride
        let resetCommit = boundedAudioSessionResetCommitPreparationValueBytes
        let resetStable = MemoryLayout<OutputResourceContext>.stride + MemoryLayout<SystemRecoveryLeaseBinding>.stride +
            MemoryLayout<PostConfigurationRouteState>.stride + MemoryLayout<ResetPostConfigurationProof>.stride +
            MemoryLayout<PlaybackRouteAuthorityIdentity>.stride + MemoryLayout<StableRouteCommitIdentity>.stride +
            MemoryLayout<OutputSuccessorCreationOwner>.stride + MemoryLayout<OutputSuccessorClaim>.stride +
            MemoryLayout<OutputRetainedRebaseResult>.stride + MemoryLayout<OutputRouteStabilityCandidate>.stride +
            MemoryLayout<RouteStabilityTicket>.stride
        let factorySettlement = 2 * MemoryLayout<OutputResourceContext>.stride +
            3 * MemoryLayout<OwnedPostIngressControlCommand>.stride + MemoryLayout<CleanupReservation>.stride +
            MemoryLayout<OwnedFactoryResult>.stride +
            MemoryLayout<OwnedAudioSessionLeaseResources>.stride + MemoryLayout<OwnedBackendResources>.stride +
            MemoryLayout<PreparedCommand>.stride + 2 * MemoryLayout<PlaybackBackendIdentity>.stride +
            MemoryLayout<OutputLifecycleEpoch>.stride + MemoryLayout<CleanupBudgetTicket>.stride
        return max(resetIngress, retainedReset, reactivation, userControl, boundedInterruptionDrainPreparationValueBytes,
            boundedRouteSamplePreparationValueBytes, boundedSuspendControlPreparationValueBytes,
            boundedPlaybackBudgetPreparationValueBytes,
            boundedOpenRouteObservationPreparationValueBytes,
            boundedOutputTransitionPreparationValueBytes, boundedClosedAirPlayPolicyTerminalPreparationValueBytes,
            handoff, rebase, resetAdmission, inactiveHandoff, resetCommit, resetStable, factorySettlement)
    }

    /// 原reset activation提交准备项单独具名，供lane完成栈合账；不删减原总峰分支。
    static var boundedAudioSessionResetCommitPreparationValueBytes: Int {
        MemoryLayout<OutputResourceContext>.stride + MemoryLayout<SystemRecoveryLeaseBinding>.stride +
            MemoryLayout<InactiveAudioSessionConfigurationReceipt>.stride + MemoryLayout<OwnedPostIngressControlCommand>.stride +
            MemoryLayout<AudioSessionPhaseIdentity>.stride + MemoryLayout<AudioSessionCallIdentity>.stride +
            MemoryLayout<RegisteredAudioSessionPhase>.stride + MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride +
            MemoryLayout<OutputAcquisitionCommitToken>.stride + MemoryLayout<OwnedAudioSessionLeaseResources>.stride +
            MemoryLayout<ProcessAudioSessionConfigurationReceipt>.stride + MemoryLayout<ConfiguredSessionReceipt>.stride +
            MemoryLayout<ActiveSessionReceipt>.stride + MemoryLayout<ConfigurationTransitionIdentity>.stride +
            MemoryLayout<PostConfigurationRouteBudget>.stride + MemoryLayout<PostConfigurationRouteState>.stride +
            MemoryLayout<RouteObservationTicket>.stride + MemoryLayout<ResetPostConfigurationProof>.stride +
            2 * MemoryLayout<PreparedCommand>.stride + MemoryLayout<CleanupBudgetTicket>.stride +
            2 * MemoryLayout<PlaybackProgressBudgetTicket>.stride
    }

    private func installPreparedCommand(_ prepared: PreparedCommand) -> ControlTaskTicket {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).installPreparedCommand(prepared)
    }

    func createGroup(resource: ControlResourceIdentity, parent: ControlTaskGroupTicket? = nil) throws -> ControlTaskGroupTicket {
        try transaction { _ in
            guard authority.snapshot.failure == nil else { throw Failure.invalidGroup }
            if let parent {
                guard authority.groups.contains(where: { $0?.ticket == parent && $0?.sealed == false }) else {
                    throw Failure.invalidGroup
                }
            }
            guard let index = authority.groups.firstIndex(where: { $0 == nil }) else { throw Failure.capacity }
            let owner = ControlTaskOwnerTicket(resourceIdentity: resource, nonce: try allocator.next(in: .nonce))
            let ticket = ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: owner,
                                                nonce: try allocator.next(in: .controlTask))
            authority.groups[index] = try Group(ticket: ticket, parent: parent)
            authority.invalidateEmptyResetDrainSource()
            return ticket
        }
    }
    func enqueue(group: ControlTaskGroupTicket, slot: ControlTaskSlot,
                 policy: ControlGatePolicy, audioIdentity: AudioSessionPhaseIdentity? = nil,
                 audioPolicy: AudioSessionPhasePolicy? = nil) throws -> ControlTaskTicket {
        try transaction { _ in try enqueueLocked(group: group, slot: slot, policy: policy,
            audioIdentity: audioIdentity, audioPolicy: audioPolicy) }
    }

    private func enqueueLocked(group: ControlTaskGroupTicket, slot: ControlTaskSlot,
        policy: ControlGatePolicy, audioIdentity: AudioSessionPhaseIdentity?, audioPolicy: AudioSessionPhasePolicy?) throws -> ControlTaskTicket {
        installPreparedCommand(try prepareCommand(group: group, slot: slot, policy: policy,
            audioIdentity: audioIdentity, audioPolicy: audioPolicy))
    }

    private func prepareCommand(group: ControlTaskGroupTicket, slot: ControlTaskSlot,
        policy: ControlGatePolicy, audioIdentity: AudioSessionPhaseIdentity?, audioPolicy: AudioSessionPhasePolicy?,
        excludingIndex: Int? = nil, preparedCycle: PreparedOutputCycle? = nil) throws -> PreparedCommand {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).prepareCommand(group: group, slot: slot, policy: policy, audioIdentity: audioIdentity, audioPolicy: audioPolicy, excludingIndex: excludingIndex, preparedCycle: preparedCycle)
    }
    func claimStart(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { output in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.slot != .sampler else { return false }
            switch authority.commands[index]?.payload {
            case .audio, .deactivation, .eventDrain, .controllerCleanup, .backendOperation: return false
            default: break
            }
            return try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).claimStart(ticket, output: &output)
        }) ?? false
    }
    func phase(of ticket: ControlTaskTicket) -> ControlTaskPhase? {
        projection { authority.commands.first(where: { $0?.controlTaskTicket == ticket })??.phase }
    }
    func complete(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }) else { return false }
            // SDK物理返回只能经原lane组合完成；取消/重置也不能开放通用terminal旁路。
            guard authority.commands[index]?.slot != .sampler else { return false }
            switch authority.commands[index]?.payload {
            case .audio, .deactivation, .eventDrain, .controllerCleanup, .backendOperation: return false
            default: break
            }
            if authority.routeSampleClaim?.source == ticket || authority.routeStabilityCandidate?.source == ticket { return false }
            if (authority.outputContext?.phase == .pendingLeaseAcquisition || authority.outputContext?.phase == .pendingCreation),
               authority.outputContext?.sourceTask == ticket { return false }
            if let context = authority.outputContext,
               context.monitorStop == ticket || context.suspend?.task == ticket ||
               context.retirement == ticket || context.teardown == ticket { return false }
            switch authority.commands[index]?.phase {
            case .running: authority.commands[index]?.phase = .terminal(.completed)
            case .cancelRequested: authority.commands[index]?.phase = .terminal(.canceled)
            default: return false
            }
            return true
        }) ?? false
    }
    func retireOutputControlRecord(_ ticket: ControlTaskTicket) throws -> OutputControlRecordRetirement {
        executor.retireOutputControlRecord(ticket)
    }

    func retire(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  !authority.belongsToCurrentOutputGraph(ticket),
                  case .terminal = authority.commands[index]?.phase,
                  let record = authority.commands[index], authority.mayDiscard(record) else { return false }
            authority.commands[index] = nil
            return true
        }) ?? false
    }
    func seal(_ group: ControlTaskGroupTicket) -> Bool {
        (try? transaction { _ in
            guard let index = authority.groups.firstIndex(where: { $0?.ticket == group }) else { return false }
            authority.groups[index]?.sealed = true
            for index in authority.groups.indices {
                guard let ticket = authority.groups[index]?.ticket, authority.isDescendant(ticket, of: group) else { continue }
                authority.groups[index]?.sealed = true
            }
            for index in authority.commands.indices {
                guard let ticket = authority.commands[index]?.groupTicket else { continue }
                if ticket == group || authority.isDescendant(ticket, of: group) { authority.cancel(index) }
            }
            return true
        }) ?? false
    }
    func isTerminal(_ group: ControlTaskGroupTicket) -> Bool {
        projection { authority.isTerminal(group) }
    }
    /// 无等待者数组；清理owner继续持有原ticket，收到准确completion后重验。
    func join(_ child: ControlTaskGroupTicket, from owner: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == owner }) ?? nil,
                  record.phase == .running, record.gatePolicy == .safetyBypass,
                  authority.isDescendant(child, of: record.groupTicket) else { return false }
            return authority.isTerminal(child)
        }) ?? false
    }
    func releaseGroup(_ group: ControlTaskGroupTicket) -> Bool {
        (try? transaction { _ in
            guard authority.isTerminal(group) else { return false }
            if let reservation = authority.cleanupReservation,
               group == reservation.ticket.ownerGroup || group == reservation.ticket.workGroup { return false }
            guard !authority.commands.contains(where: {
                guard let record = $0 else { return false }
                return !authority.mayDiscard(record) &&
                    (record.groupTicket == group || authority.isDescendant(record.groupTicket, of: group))
            }) else { return false }
            for index in authority.commands.indices {
                guard let ticket = authority.commands[index]?.groupTicket else { continue }
                if ticket == group || authority.isDescendant(ticket, of: group) { authority.commands[index] = nil }
            }
            // 先定位完整后代集合，再移除父链；固定32位标记不分配集合。
            var removalMask: UInt32 = 0
            for index in authority.groups.indices {
                guard let ticket = authority.groups[index]?.ticket else { continue }
                if ticket == group || authority.isDescendant(ticket, of: group) { removalMask |= 1 << index }
            }
            for index in authority.groups.indices where removalMask & (1 << index) != 0 { authority.groups[index] = nil }
            return true
        }) ?? false
    }
    func requestCancel(_ ticket: ControlTaskTicket) -> Bool {
        var runnerTask: Task<Void, Never>?
        let accepted = (try? transaction { _ in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }) else { return false }
            authority.cancel(index)
            runnerTask = authority.commands[index]?.backendOperation?.task
            return true
        }) ?? false
        // phase 与 runner handle 必须在同一 safety cell 中取样；真实 Task 取消放在锁外，
        // 避免 cancellation handler 重入 Registry 时形成锁序反转。runner 的 join 仍由
        // 唯一 owner 经 joinOutputBackendOperation 完成。
        if accepted { runnerTask?.cancel() }
        return accepted
    }

    /// commit必须只做有界资源所有权CAS，禁止SDK、await、重入和资源析构。
    /// SDK completion只结束执行，不等于结果已获提交资格。
    func claimCompletedResult(_ ticket: ControlTaskTicket, commit: () -> Void = {}) -> Bool {
        (try? transaction { output in
            guard let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.phase == .terminal(.completed),
                  record.ownedResult == nil, record.factoryResult == nil,
                  !record.resultInvalidated, !record.resultClaimed,
                  authority.groups.contains(where: { $0?.ticket == record.groupTicket && $0?.sealed == false }),
                  authority.matches(record.safetySnapshot), authority.matchesAudio(record) else { return false }
            if case .activate = record.audioPolicy {
                guard case .returnedSuccess = record.activationOutcome,
                      authority.activationClaim?.record == ticket else { return false }
            }
            switch record.gatePolicy {
            case .activationRequiresOpen, .routeSpeculativeRateZero:
                guard output.routeObservationGateOpen, !authority.snapshot.interruptionVeto,
                      authority.snapshot.failure == nil else { return false }
            case .routeNeutral, .audioSession:
                guard authority.snapshot.failure == nil else { return false }
            case .safetyBypass: break
            }
            authority.commands[index]?.resultClaimed = true
            commit()
            return true
        }) ?? false
    }

    func enqueueAudioSession(group: ControlTaskGroupTicket, identity: AudioSessionPhaseIdentity,
                             policy: AudioSessionPhasePolicy) throws -> ControlTaskTicket {
        try enqueue(group: group, slot: .audioSessionRecovery, policy: .audioSession,
                    audioIdentity: identity, audioPolicy: policy)
    }

    /// Task6须先释放准确lane permit再交付本次真实调用结果；迟到success仍保留物理责任。
    func registeredAudioSessionPhase() -> RegisteredAudioSessionPhase? {
        projection { authority.audioPhase }
    }

    func activationOutcome(of ticket: ControlTaskTicket) -> AudioSessionActivationTerminalOutcome? {
        projection { authority.commands.first(where: { $0?.controlTaskTicket == ticket })??.activationOutcome }
    }

    func activationDeactivationDisposition(of ticket: ControlTaskTicket) -> AudioSessionDeactivationDisposition? {
        projection {
            guard let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  case .activate = record.audioPolicy, let identity = record.audioPhaseIdentity else { return nil }
            switch record.activationOutcome {
            case .notInvoked(let proof): return .confirmedInactive(.activationNotInvoked(proof))
            case .returnedFailure(let call, let failure): return .confirmedInactive(.activationReturnedFailure(call, failure))
            case .returnedSuccess(let call): return .requiresDeactivate(.returnedSuccess(call))
            case nil: return .awaitingActivationOutcome(.init(record: ticket, phaseIdentity: identity))
            }
        }
    }

    func outputResourceContextSnapshot() -> OutputResourceContext? {
        projection { authority.outputContext }
    }

    /// 准确acquire已启动且尚无lease；所有checked身份准备后一次安装真实registration与reservation证明。
    func registerAudioSessionLease(_ ticket: ControlTaskTicket, salt: AudioSessionEndpointSalt) throws -> PlaybackAudioSessionRegistration? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard try !expireOutputAcquisitionLocked(output: &output),
                  case .acquiringWithoutLease(var context) = authority.resourceState,
                  context.sourceTask == ticket, context.disposition != .releaseAfterTeardown,
                  !context.poisoned, !context.relayClosing, authority.audioSessionPermit == nil,
                  authority.cleanupReservation?.ticket == context.reservation,
                  ticket.group == context.reservation.workGroup,
                  let parent = context.parentDeadline,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.slot == .acquire, record.phase == .running,
                  record.payload == nil, authority.matches(record.safetySnapshot) else { return nil }
            let leaseID = try allocator.next(in: .lease)
            let ownershipNonce = try allocator.next(in: .nonce)
            let monitorLifecycle = try allocator.next(in: .nonce)
            let process = authority.processConfigurationReceipt.flatMap {
                $0.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch ? $0 : nil
            }
            let stepNonce = try allocator.next(in: .nonce)
            // 从这里起没有可失败准备，也没有SDK调用；未完整安装的对象不会逃逸。
            let registration = PlaybackAudioSessionRegistration(identity: .init(acquisition: ticket,
                leaseID: leaseID, monitorLifecycle: monitorLifecycle), salt: salt, registry: self)
            let proof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: ticket,
                sessionIdentity: context.sessionIdentity, leaseID: leaseID,
                contextNonce: context.contextNonce, ownershipNonce: ownershipNonce)
            let monitor = OwnedRouteMonitorResource(sessionIdentity: context.sessionIdentity,
                lifecycle: monitorLifecycle, object: registration)
            let lease = OwnedAudioSessionLeaseResources(leaseID: leaseID, object: registration,
                monitor: monitor, deactivation: .confirmedInactive(.reservation(proof)))
            let acquired = OutputAcquiredLease(lease: lease, proof: proof)
            context.monitorStopped = false
            if let process {
                let parentIdentity: PlaybackProgressBudgetTicket.Identity
                switch parent { case .coldStart(let value), .outputRecovery(let value): parentIdentity = value.identity }
                let configured = OutputConfiguredAcquisition(acquired: acquired, processReceipt: process)
                let phase = RegisteredAudioSessionPhase(identity: .init(owner: context.reservation.workGroup.ownerTicket,
                    sessionIdentity: context.sessionIdentity, leaseID: leaseID, contextNonce: context.contextNonce,
                    mediaServicesEpoch: process.identity.mediaServicesEpoch, phaseNonce: stepNonce),
                    policy: .configureAcquisition(acquisitionTicket: ticket, ownershipNonce: ownershipNonce,
                        configurationAttemptNonce: process.attemptLineage.nonce, step: .multichannelCapability),
                    configurationAttempt: process.attemptLineage, parent: parentIdentity, resetBinding: nil, incarnation: nil,
                    reactivationState: nil, configurationProgress: .complete(actualPolicy: process.actualPolicy,
                        preferredFailure: process.preferredFailureReason, multichannel: process.multichannelCapability),
                    permitsFurtherCalls: true, acquisitionOwnershipProof: proof, processReceipt: process,
                    configuredReceipt: configured.configuredReceipt, inactiveReceipt: nil)
                authority.resourceState = .acquiringLease(context, .awaitingActivation(configured))
                authority.audioPhase = phase
            } else {
                authority.resourceState = .acquiringLease(context, .configuring(acquired, .init(nonce: stepNonce,
                    plan: .preferredLongFormThenDefault, mediaServicesEpoch: authority.snapshot.mediaServicesEpoch)))
            }
            authority.commands[index]?.phase = .terminal(.completed)
            authority.commands[index]?.resultClaimed = true
            return registration
        }
    }

    func beginRegisteredAudioSessionConfiguration(_ registration: PlaybackAudioSessionRegistration) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard authority.ownsRegistration(registration, allowsClosing: false),
                  let context = authority.outputContext, let parent = context.parentDeadline else { return nil }
            let operations = AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds)
            if case .acquiringLease(_, .awaitingActivation) = authority.resourceState {
                return try operations.beginOutputAcquisitionActivation(contextNonce: context.contextNonce, output: &output)
            }
            return try operations.beginOutputAcquisitionConfiguration(contextNonce: context.contextNonce, parent: parent, output: &output)
        }
    }

    func acquisitionIsParkedForPhysicalResume(_ registration: PlaybackAudioSessionRegistration) -> Bool {
        projection {
            guard authority.ownsRegistration(registration, allowsClosing: false), authority.snapshot.interruptionVeto,
                  case .acquiringLease(let context, .awaitingActivation) = authority.resourceState,
                  !context.poisoned, context.pendingActivationCall == nil else { return false }
            return true
        }
    }

    func audioSessionRegistration(for acquisition: ControlTaskTicket) -> PlaybackAudioSessionRegistration? {
        projection {
            guard let handle = authority.ownedLeaseResources?.monitor?.object as? PlaybackAudioSessionRegistration,
                  handle.identity.acquisition == acquisition,
                  authority.ownsRegistration(handle, allowsClosing: true) else { return nil }
            return handle
        }
    }

    func stopAudioSessionRegistration(_ registration: PlaybackAudioSessionRegistration, task: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard authority.ownsRegistration(registration, allowsClosing: true),
                  let context = authority.outputContext, context.relayClosing, context.monitorStop == task,
                  context.delivery == nil, authority.snapshot.callbackDepth == 0,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == task }),
                  authority.commands[index]?.phase == .running,
                  authority.commands.allSatisfy({ record in
                      guard let record, record.slot == .sampler, record.groupTicket == context.reservation.workGroup else { return true }
                      if case .terminal = record.phase { return true }
                      return false
                  }) else { return false }
            authority.commands[index]?.phase = .terminal(.completed)
            authority.outputContext?.monitorStopped = true
            return true
        }) ?? false
    }

    func outputCleanupOwnerTask(_ owner: OutputTransitionOwnerTicket) -> ControlTaskTicket? {
        projection {
            guard let context = authority.outputContext, context.owner == owner else { return nil }
            return authority.commands.first(where: {
                $0?.groupTicket == context.reservation.ownerGroup && $0?.slot == ReservedCleanupStage.owner.slot
            })??.controlTaskTicket
        }
    }

    func beginOutputMonitorDelivery(contextNonce: UInt64) throws -> OutputMonitorDeliveryTicket? {
        try transaction { _ in
            guard let context = authority.outputContext, context.contextNonce == contextNonce,
                  !context.relayClosing, context.delivery == nil, let ownership = authority.ownedResource else { return nil }
            let lifecycle: UInt64
            switch ownership.payload {
            case .monitor(let value): lifecycle = value.lifecycle
            case .lease(let value): guard let monitor = value.monitor else { return nil }; lifecycle = monitor.lifecycle
            case .backend(let value): guard let monitor = value.lease.monitor else { return nil }; lifecycle = monitor.lifecycle
            }
            let ticket = OutputMonitorDeliveryTicket(contextNonce: contextNonce, monitorLifecycle: lifecycle,
                nonce: try allocator.next(in: .nonce))
            authority.outputContext?.delivery = ticket
            return ticket
        }
    }

    func acknowledgeOutputMonitorDelivery(_ ticket: OutputMonitorDeliveryTicket) -> Bool {
        (try? transaction { _ in
            guard authority.outputContext?.delivery == ticket else { return false }
            authority.outputContext?.delivery = nil
            return true
        }) ?? false
    }

    func beginOutputMonitorStop(contextNonce: UInt64) throws -> ControlTaskTicket? {
        try transaction { _ in
            guard let context = authority.outputContext, context.contextNonce == contextNonce,
                  let resource = authority.ownedResource else { return nil }
            switch resource.payload {
            case .backend: return nil
            case .lease(let lease) where lease.monitor == nil: return nil
            case .monitor, .lease: break
            }
            if let ticket = context.monitorStop { return ticket }
            let command = try prepareReservedCleanup(context.reservation, stage: .monitorStop)
            let ticket = installPreparedCommand(command)
            authority.outputContext?.relayClosing = true
            authority.outputContext?.monitorStop = ticket
            return ticket
        }
    }

    func completeOutputMonitorStop(_ ticket: ControlTaskTicket, monitorLifecycle: UInt64) -> Bool {
        (try? transaction { _ in
            guard let context = authority.outputContext, context.monitorStop == ticket,
                  context.delivery == nil, let ownership = authority.ownedResource,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.phase == .running else { return false }
            let actual: UInt64
            switch ownership.payload {
            case .monitor(let value): actual = value.lifecycle
            case .lease(let value): guard let monitor = value.monitor else { return false }; actual = monitor.lifecycle
            case .backend: return false
            }
            guard actual == monitorLifecycle, authority.snapshot.callbackDepth == 0,
                  authority.commands.allSatisfy({ record in
                      guard let record, record.slot == .sampler,
                            record.groupTicket == context.reservation.workGroup else { return true }
                      if case .terminal = record.phase { return true }
                      return false
                  }) else { return false }
            authority.commands[index]?.phase = .terminal(.completed)
            authority.outputContext?.monitorStopped = true
            return true
        }) ?? false
    }

    /// 用户请求准入与旧输出撤权同锁提交；在任何前驱等待、SDK调用或factory之前冻结真实起点。
    func admitPlaybackRequest(requestID: UUID) throws -> CurrentPlaybackOperationDeadlineTicket {
        var admission: CurrentPlaybackOperationDeadlineTicket?
        var needsJoin = false
        executor.sync {
            while true {
                switch executor.safetyIngress.performPlaybackAdmission(requestID: requestID) {
                case .retry: continue
                case .rejected: return
                case .performed(.admitted(let value)): admission = value; return
                case .performed(.needsCleanupJoin): needsJoin = true; return
                }
            }
        }
        if needsJoin { throw Failure.cleanupTailPending }
        guard let admission else { throw Failure.invalidGroup }
        return admission
    }

    func playbackRequestAdmissionSnapshot() -> CurrentPlaybackOperationDeadlineTicket? {
        projection { authority.playbackRequestAdmission }
    }

    func cancelPlaybackRequest(_ expected: PlaybackSessionIdentity) -> Bool {
        defer { notifyPlaybackProgress() }
        return (try? transaction { _ in
            guard case .coldStart(let current) = authority.playbackRequestAdmission,
                  current.identity.sessionIdentity == expected else { return false }
            authority.playbackRequestAdmission = nil
            return true
        }) ?? false
    }

    func beginOutputAcquisition(admission: CurrentPlaybackOperationDeadlineTicket,
        resetRecoveryMandatorySuffix: UInt64) throws -> ControlTaskTicket? {
        defer { notifyPlaybackProgress() }
        return try transaction(operationDescriptor: .resourceOwnership) { _ in
            guard authority.playbackRequestAdmission == admission,
                  case .coldStart(let budget) = admission,
                  try !budget.isExpired(at: monotonicClock.nowNanoseconds) else { return nil }
            return try beginOutputAcquisitionLocked(session: budget.identity.sessionIdentity,
                parent: admission, resetRecoveryMandatorySuffix: resetRecoveryMandatorySuffix)
        }
    }

    /// acquire前一次安装完整最终预留与pending形态；准备失败不留下半份group。
    func beginOutputAcquisition(session: PlaybackSessionIdentity,
        parent: CurrentPlaybackOperationDeadlineTicket, resetRecoveryMandatorySuffix: UInt64) throws -> ControlTaskTicket? {
        defer { notifyPlaybackProgress() }
        return try transaction(operationDescriptor: .resourceOwnership) { _ in
            try beginOutputAcquisitionLocked(session: session, parent: parent,
                resetRecoveryMandatorySuffix: resetRecoveryMandatorySuffix)
        }
    }

    private func beginOutputAcquisitionLocked(session: PlaybackSessionIdentity,
        parent: CurrentPlaybackOperationDeadlineTicket, resetRecoveryMandatorySuffix: UInt64) throws -> ControlTaskTicket? {
            let parentValue: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let value), .outputRecovery(let value): parentValue = value }
            let parentIdentity = parentValue.identity
            guard resetRecoveryMandatorySuffix > 0, resetRecoveryMandatorySuffix < parentValue.cap else { return nil }
            guard parentIdentity.sessionIdentity == session else { return nil }
            guard authority.currentResetRoot == nil ||
                  authority.processConfigurationReceipt?.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else { return nil }
            guard authority.cleanupReservation == nil, authority.outputContext == nil,
                  authority.ownedResource == nil else { return nil }
            let reservation = try reserveCleanupLocked(resource: .session(session))
            do {
                let prepared = try prepareCommand(group: reservation.ticket.workGroup, slot: .acquire,
                    policy: .routeNeutral, audioIdentity: nil, audioPolicy: nil)
                let ticket = installPreparedCommand(prepared)
                var context = OutputResourceContext(session: session, reservation: reservation, source: ticket,
                    parent: parent, resetRecoveryMandatorySuffix: resetRecoveryMandatorySuffix)
                context.mediaServicesEpoch = authority.snapshot.mediaServicesEpoch
                context.interruptionEpoch = authority.snapshot.interruptionEpoch
                context.audioAdmissionFenceRevision = authority.snapshot.audioAdmissionFenceRevision
                context.ownerIngressRevision = authority.snapshot.throughRevision
                authority.resourceState = .acquiringWithoutLease(context)
                authority.authoritativeRoute = .unknown
                authority.lastEndpointFingerprint = nil
                authority.outputConfigurationIncarnation = nil
                return ticket
            } catch {
                for index in authority.groups.indices where authority.groups[index]?.ticket == reservation.ticket.ownerGroup ||
                    authority.groups[index]?.ticket == reservation.ticket.workGroup { authority.groups[index] = nil }
                authority.cleanupReservation = nil
                throw error
            }
    }

    /// SDK结果先由原record强持有；此CAS只接纳准确pending acquire的终态。
    func settleOutputAcquisition(_ ticket: ControlTaskTicket) throws -> Bool {
        try transaction { output in
            _ = try expireOutputAcquisitionLocked(output: &output)
            guard var context = authority.outputContext, context.phase == .pendingLeaseAcquisition,
                  context.sourceTask == ticket,
                  let index = validatedOwnedResultIndex(ticket, reservation: context.reservation,
                    contextNonce: context.contextNonce, forCleanup: true, output: output, acquisitionSettlement: true),
                  let ownership = authority.commands[index]?.ownedResult else { return false }
            let releasing = context.disposition == .releaseAfterTeardown || authority.cleanupReservation?.terminal == true
            if case .lease(let lease) = ownership.payload, !releasing {
                // reservation不是配置/激活完成事实；保留原acquisition及context身份直到最终交接。
                guard case .confirmedInactive(.reservation(let proof)) = lease.deactivation,
                      proof.acquisitionTicket == ticket, proof.contextNonce == context.contextNonce,
                      proof.sessionIdentity == context.sessionIdentity, proof.leaseID == lease.leaseID else { return false }
                context.monitorStopped = lease.monitor == nil
                let acquired = OutputAcquiredLease(lease: lease, proof: proof)
                if let process = authority.processConfigurationReceipt,
                   process.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
                   let parent = context.parentDeadline {
                    let parentIdentity: PlaybackProgressBudgetTicket.Identity
                    switch parent { case .coldStart(let value), .outputRecovery(let value): parentIdentity = value.identity }
                    let configured = OutputConfiguredAcquisition(acquired: acquired, processReceipt: process)
                    let phase = RegisteredAudioSessionPhase(identity: .init(owner: context.reservation.workGroup.ownerTicket,
                        sessionIdentity: context.sessionIdentity, leaseID: lease.leaseID, contextNonce: context.contextNonce,
                        mediaServicesEpoch: process.identity.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce)),
                        policy: .configureAcquisition(acquisitionTicket: ticket, ownershipNonce: proof.ownershipNonce,
                            configurationAttemptNonce: process.attemptLineage.nonce, step: .multichannelCapability),
                        configurationAttempt: process.attemptLineage, parent: parentIdentity, resetBinding: nil, incarnation: nil,
                        reactivationState: nil, configurationProgress: .complete(actualPolicy: process.actualPolicy,
                            preferredFailure: process.preferredFailureReason, multichannel: process.multichannelCapability),
                        permitsFurtherCalls: true, acquisitionOwnershipProof: proof, processReceipt: process,
                        configuredReceipt: configured.configuredReceipt, inactiveReceipt: nil)
                    authority.resourceState = .acquiringLease(context, .awaitingActivation(configured))
                    authority.audioPhase = phase
                } else {
                    let attempt = AudioSessionConfigurationAttempt(nonce: try allocator.next(in: .nonce),
                        plan: .preferredLongFormThenDefault, mediaServicesEpoch: authority.snapshot.mediaServicesEpoch)
                    authority.resourceState = .acquiringLease(context, .configuring(acquired, attempt))
                }
                authority.commands[index]?.payload = nil
                authority.commands[index]?.resultClaimed = true
                return true
            }
            let conversion: CleanupReservation.Conversion
            let phase: OutputResourcePhase
            switch ownership.payload {
            case .backend: return false
            case .monitor: conversion = .monitorOnly; phase = .routeMonitorCleanup
            case .lease: conversion = releasing ? .leaseOnly : .retainedSuccessor
                phase = releasing ? .leaseOnlyCleanup : .pendingSuccessorLease
            }
            guard let nonce = authority.cleanupReservation?.nonce(for: conversion) else { return false }
            var next = context
            next.contextNonce = nonce
            next.phase = phase
            next.sourceTask = nil
            next.acquisitionDeadline = nil
            switch ownership.payload {
            case .lease(let lease):
                authority.resourceState = releasing ? .leaseOnlyCleanup(next, .owned(lease)) : .pendingSuccessorLease(next, lease)
            case .monitor(let monitor): authority.resourceState = .routeMonitorCleanup(next, .owned(monitor))
            case .backend: return false
            }
            authority.cleanupReservation?.consume(conversion)
            authority.commands[index] = nil
            return true
        }
    }

    /// 高优先级owner和release只可单向升级；已有在途stop始终返回同一准确ticket。
    func beginOutputAcquisitionConfiguration(contextNonce: UInt64,
        parent: CurrentPlaybackOperationDeadlineTicket) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent, output: &output)
        }
    }

    func beginOutputAcquisitionActivation(contextNonce: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputAcquisitionActivation(contextNonce: contextNonce, output: &output)
        }
    }

    func outputAcquisitionCommitSnapshot() -> OutputAcquisitionCommitToken? {
        projection {
            guard case .acquiringLease(let context, .readyToCommit(let ready)) = authority.resourceState,
                  let monitor = ready.acquired.lease.monitor else { return nil }
            return .init(relayIdentity: .init(acquisitionTicket: ready.acquired.proof.acquisitionTicket,
                sessionIdentity: context.sessionIdentity, leaseID: ready.acquired.lease.leaseID,
                monitorLifecycle: monitor.lifecycle), contextNonce: context.contextNonce,
                ownerEventCursor: authority.snapshot.throughRevision,
                audioAdmissionFenceRevision: authority.snapshot.audioAdmissionFenceRevision)
        }
    }

    func commitAcquisitionRelayAndContext(_ expected: OutputAcquisitionCommitToken) throws -> OutputAcquisitionCommitResult {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard try !expireOutputAcquisitionLocked(output: &output) else { return .rejected }
            if case .acquiringLease(var context, .readyToCommit(.inactive(let acquired, let receipt))) = authority.resourceState {
                return try commitInactiveAcquisitionLocked(expected, context: &context, acquired: acquired, receipt: receipt, output: &output)
            }
            guard case .acquiringLease(var context, .readyToCommit(.ordinary(let configured, let active))) = authority.resourceState,
                  context.contextNonce == expected.contextNonce, context.parentDeadline != nil,
                  context.disposition != .releaseAfterTeardown, !context.relayClosing, !context.poisoned,
                  context.pendingReset == nil, !authority.snapshot.interruptionVeto,
                  configured.processReceipt.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
                  active.interruptionEpoch == authority.snapshot.interruptionEpoch,
                  active.leaseID == configured.acquired.lease.leaseID,
                  active.configurationGeneration == configured.processReceipt.identity.configurationGeneration,
                  let monitor = configured.acquired.lease.monitor else { return .rejected }
            let relay = OutputSessionRelayIdentity(acquisitionTicket: configured.acquired.proof.acquisitionTicket,
                sessionIdentity: context.sessionIdentity, leaseID: configured.acquired.lease.leaseID,
                monitorLifecycle: monitor.lifecycle)
            guard relay == expected.relayIdentity else { return .rejected }
            let current = OutputAcquisitionCommitToken(relayIdentity: relay, contextNonce: context.contextNonce,
                ownerEventCursor: authority.snapshot.throughRevision,
                audioAdmissionFenceRevision: authority.snapshot.audioAdmissionFenceRevision)
            guard expected == current else { return .retry(current) }
            guard authority.commands.allSatisfy({ record in
                guard let record, record.slot == .audioSessionRecovery,
                      record.groupTicket == context.reservation.workGroup else { return true }
                guard case .terminal = record.phase else { return false }
                return authority.mayDiscard(record)
            }), let successorNonce = authority.cleanupReservation?.nonce(for: .retainedSuccessor) else { return .rejected }
            let latest = authority.snapshot.route.flatMap { value in
                value.sessionIdentity == context.sessionIdentity && value.monitorLifecycle == relay.monitorLifecycle ? value : nil
            }
            let routeAuthority = PlaybackRouteAuthorityIdentity(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: relay.monitorLifecycle, mediaServicesEpoch: authority.snapshot.mediaServicesEpoch,
                interruptionEpoch: active.interruptionEpoch, audioSessionConfigurationGeneration: active.configurationGeneration,
                audioSessionActivationNonce: active.activationNonce, audioAdmissionFenceRevision: current.audioAdmissionFenceRevision,
                routeObservationRevision: latest?.notificationRevision ?? 0, semanticIdentity: authority.routeSemantic,
                configurationTransitionIdentity: nil, postConfigurationStageIdentity: nil,
                systemOpenConfigurationGeneration: active.configurationGeneration)
            let needsSample = authority.routeObservationState?.isPending == true ||
                authority.stableRouteCommit?.exactlyMatches(routeAuthority, observationGateOpen: output.routeObservationGateOpen) != true
            let prepared: PreparedCommand?
            let pending: PendingRouteObservation?
            if needsSample {
                // 使用与同步入口同一只时钟；本行实际在executor及cell锁内执行。
                let instant = monotonicClock.nowNanoseconds
                let (deadlineInstant, overflow) = instant.addingReportingOverflow(3_000_000_000)
                guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
                let deadline = RouteUnavailableDeadlineTicket(identity: .init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: relay.monitorLifecycle, mediaServicesEpochAtCreation: authority.snapshot.mediaServicesEpoch,
                    deadlineAnchorInstant: instant, deadlineNonce: try allocator.next(in: .deadline)), deadlineInstant: deadlineInstant)
                let observation = RouteObservationTicket(sessionIdentity: context.sessionIdentity, monitorLifecycle: relay.monitorLifecycle,
                    mediaServicesEpoch: authority.snapshot.mediaServicesEpoch, interruptionEpoch: active.interruptionEpoch,
                    audioSessionConfigurationGeneration: active.configurationGeneration, audioSessionActivationNonce: active.activationNonce,
                    configurationTransitionIdentity: nil, observationNonce: try allocator.next(in: .nonce))
                prepared = try prepareCommand(group: context.reservation.workGroup, slot: .sampler,
                    policy: .safetyBypass, audioIdentity: nil, audioPolicy: nil)
                var reasons = RouteObservationReasons.initialAuthoritativeSampleRequired
                reasons.formUnion(.init(rawValue: UInt16(latest?.reasonBits ?? 0)))
                let ordinary = OrdinaryRouteDeadlineState(ticket: deadline, armNonce: try allocator.next(in: .deadline))
                var accumulated = PendingRouteObservation(ticket: observation, ordinaryDeadlineState: ordinary, sampler: prepared!.ticket,
                    latestObservation: latest, reasons: reasons, topologyChangeHint: latest?.topologyChangeHint ?? false,
                    outputConfigurationChanged: latest?.outputConfigurationChanged ?? false)
                accumulated.latestNotificationRevision = latest?.notificationRevision ?? 0
                if case .pending(let previous) = authority.routeObservationState {
                    accumulated.firstEventObservedInstant = previous.firstEventObservedInstant
                    accumulated.latestNotificationRevision = max(accumulated.latestNotificationRevision, previous.latestNotificationRevision)
                    if (previous.latestObservation?.notificationRevision ?? 0) > (latest?.notificationRevision ?? 0) {
                        accumulated.latestObservation = previous.latestObservation
                    }
                    accumulated.reasons.formUnion(previous.reasons)
                    accumulated.topologyChangeHint = accumulated.topologyChangeHint || previous.topologyChangeHint
                    accumulated.outputConfigurationChanged = accumulated.outputConfigurationChanged || previous.outputConfigurationChanged
                }
                pending = accumulated
            } else { prepared = nil; pending = nil }
            // 候选预期generation不是权威身份。全部其他准备成功后才消费，随后只有不可失败安装。
            if authority.processConfigurationReceipt != configured.processReceipt {
                let failureBudget = try context.budget ?? CleanupBudgetTicket(
                    predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                    anchorInstant: monotonicClock.nowNanoseconds, nonce: context.reservation.nonce)
                let failureOwner = try prepareOutputCleanupOwner(context.reservation, terminal: true)
                do {
                    let (expectedGeneration, overflow) = authority.currentConfigurationGeneration.addingReportingOverflow(1)
                    guard !overflow, configured.processReceipt.identity.configurationGeneration == expectedGeneration,
                          try allocator.next(in: .audioSessionConfigurationGeneration) == expectedGeneration else {
                        throw PlaybackSafetyFailure.invalidEvidence
                    }
                } catch {
                    context.poisoned = true
                    context.disposition = .releaseAfterTeardown
                    context.relayClosing = true
                    context.teardownRequested = true
                    context.budget = failureBudget
                    context.owner = .init(identity: authority.cleanupReservation!.terminalOwner, reason: .terminal)
                    authority.resourceState = .acquiringLease(context, .readyToCommit(.ordinary(configured, active)))
                    _ = installPreparedCommand(failureOwner)
                    terminateCleanupReservationLocked(context.reservation, output: &output)
                    output.outputPermitPresent = false
                    output.readinessOpen = false
                    output.routeObservationGateOpen = false
                    throw error
                }
            }
            // 所有checked身份和唯一sampler容量先准备；以下资源/relay/receipt/窗口一起安装。
            context.contextNonce = successorNonce
            context.sourceTask = nil
            context.committedRelay = current
            context.acquisitionDeadline = nil
            context.sessionReceipts = .init(process: configured.processReceipt, configured: configured.configuredReceipt, active: active)
            context.mediaServicesEpoch = authority.snapshot.mediaServicesEpoch
            context.interruptionEpoch = authority.snapshot.interruptionEpoch
            context.audioAdmissionFenceRevision = current.audioAdmissionFenceRevision
            authority.resourceState = .pendingSuccessorLease(context, configured.acquired.lease)
            authority.cleanupReservation?.consume(.retainedSuccessor)
            authority.processConfigurationReceipt = configured.processReceipt
            authority.currentConfigurationGeneration = configured.processReceipt.identity.configurationGeneration
            if let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == relay.acquisitionTicket }) {
                authority.commands[index] = nil
            }
            if let pending, let prepared {
                authority.routeObservationState = .pending(pending)
                output.routeObservationGateOpen = false
                _ = installPreparedCommand(prepared)
            } else { authority.routeObservationState = .open(routeAuthority) }
            return .committed(.init(committed: current, successorContextNonce: successorNonce,
                sampler: prepared?.ticket, routeDeadline: pending?.deadline, routeObservation: pending?.ticket))
        }
    }

    private func commitInactiveAcquisitionLocked(_ expected: OutputAcquisitionCommitToken,
        context: inout OutputResourceContext, acquired: OutputAcquiredLease,
        receipt: InactiveAudioSessionConfigurationReceipt,
        output: inout PlaybackOutputSafetyState) throws -> OutputAcquisitionCommitResult {
        guard context.contextNonce == expected.contextNonce,
              context.disposition != .releaseAfterTeardown, !context.poisoned, !context.relayClosing,
              authority.matchesManagedAcquisitionReset(context), let reset = context.resetAcquisitionBinding,
              let parent = context.parentDeadline, let previous = authority.audioPhase,
              previous.identity.contextNonce == context.contextNonce, previous.acquisitionOwnershipProof == acquired.proof,
              previous.inactiveReceipt == receipt, previous.configurationAttempt == receipt.attemptLineage,
              receipt.identity.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
              case .complete = previous.configurationProgress,
              authority.commands.allSatisfy({ record in
                  guard let record, record.slot == .audioSessionRecovery,
                        record.groupTicket == context.reservation.workGroup else { return true }
                  guard case .terminal = record.phase else { return false }
                  return authority.mayDiscard(record)
              }), let nonce = authority.cleanupReservation?.nonce(for: .retainedSuccessor),
              var state = authority.resetPreRouteState,
              let monitor = acquired.lease.monitor else { return .rejected }
        let relay = OutputSessionRelayIdentity(acquisitionTicket: acquired.proof.acquisitionTicket,
            sessionIdentity: context.sessionIdentity, leaseID: acquired.lease.leaseID, monitorLifecycle: monitor.lifecycle)
        guard relay == expected.relayIdentity else { return .rejected }
        let current = OutputAcquisitionCommitToken(relayIdentity: relay, contextNonce: context.contextNonce,
            ownerEventCursor: authority.snapshot.throughRevision, audioAdmissionFenceRevision: authority.snapshot.audioAdmissionFenceRevision)
        guard expected == current else { return .retry(current) }
        let instant = monotonicClock.nowNanoseconds
        guard let elapsed = state.effectiveElapsed(at: instant), elapsed < state.boundaryEffectiveElapsed,
              parentAllowsWork(parent, at: instant) else { return .rejected }
        let parentIdentity: PlaybackProgressBudgetTicket.Identity
        switch parent { case .coldStart(let value), .outputRecovery(let value): parentIdentity = value.identity }
        let incarnation = SystemRecoveryIncarnation(identity: .init(root: reset.proof.identity.root,
            incarnationNonce: try allocator.next(in: .nonce), sessionIdentity: context.sessionIdentity),
            drainProof: reset.proof, baseConfigurationGeneration: reset.proof.currentConfigurationGeneration,
            configurationPlan: receipt.planDigest, outerDeadlineTicket: parentIdentity,
            resetPreRouteDeadlineTicket: reset.preRouteTicket,
            inheritedRouteAvailabilityConstraint: reset.inheritedRouteAvailabilityConstraint)
        let binding = SystemRecoveryLeaseBinding(incarnation: incarnation, inactiveConfigurationReceipt: receipt,
            resetPreRouteBinding: reset.binding, configurationState: previous.configurationProgress)
        let phase = RegisteredAudioSessionPhase(identity: .init(owner: context.reservation.workGroup.ownerTicket,
            sessionIdentity: context.sessionIdentity, leaseID: acquired.lease.leaseID, contextNonce: nonce,
            mediaServicesEpoch: authority.snapshot.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce)),
            policy: .configureInactive(incarnation: incarnation.identity, resetDrainProof: reset.proof.identity,
                configurationAttemptNonce: receipt.attemptLineage.nonce, step: .multichannelCapability),
            configurationAttempt: receipt.attemptLineage, parent: parentIdentity, resetBinding: reset.binding,
            incarnation: incarnation, reactivationState: nil, configurationProgress: previous.configurationProgress,
            permitsFurtherCalls: true, acquisitionOwnershipProof: nil, processReceipt: nil, configuredReceipt: nil,
            inactiveReceipt: receipt)
        // 原source、SDK强资源、唯一binding/时钟和relay一起移交；不创建activation或提升generation。
        state.accumulatedEffectiveTime = elapsed
        if state.runningSince != nil { state.runningSince = instant }
        settleResetParentClockLocked(state, context: &context)
        context.contextNonce = nonce
        context.sourceTask = nil
        context.acquisitionDeadline = nil
        context.committedRelay = current
        context.audioAdmissionFenceRevision = current.audioAdmissionFenceRevision
        context.resetResourceBinding = .retained(binding)
        authority.resourceState = .pendingSuccessorLease(context, acquired.lease)
        authority.audioPhase = phase
        authority.resetPreRouteState = state
        authority.cleanupReservation?.consume(.retainedSuccessor)
        if let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == acquired.proof.acquisitionTicket }) {
            authority.commands[index] = nil
        }
        output.routeObservationGateOpen = false
        return .committed(.init(committed: current, successorContextNonce: nonce, sampler: nil,
            routeDeadline: nil, routeObservation: nil))
    }

    func outputRouteObservationSnapshot() -> RouteObservationState? {
        // route-service在同步ingress之后由此领取新sampler；这是生产drain边界，不是UI纯观察。
        try? transaction { _ in authority.routeObservationState }
    }

    func stableRouteCommitSnapshot() -> StableRouteCommitIdentity? {
        projection { authority.stableRouteCommit }
    }

    func beginOutputResetConfigurationActivation(contextNonce: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputResetConfigurationActivation(contextNonce: contextNonce, output: &output)
        }
    }

    func armOutputRouteStability(observation: RouteObservationTicket) throws -> RouteStabilityTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard var candidate = authority.routeStabilityCandidate, candidate.observation == observation,
                  candidate.authority == currentOutputRouteAuthorityLocked(),
                  routeCandidateCanConfirmLocked(candidate, output: output),
                  let context = authority.outputContext else { return nil }
            let instant = monotonicClock.nowNanoseconds
            guard routeBoundaryAllowsWorkLocked(candidate.boundary, at: instant), parentAllowsWork(context.parentDeadline, at: instant) else {
                try timeoutOutputRouteBoundaryLocked(contextNonce: context.contextNonce, at: instant, output: &output)
                return nil
            }
            if let ticket = candidate.stabilityTicket { return ticket }
            let (deadline, overflow) = candidate.firstMatchingSampleInstant.addingReportingOverflow(120_000_000)
            guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
            let ticket = RouteStabilityTicket(observation: observation, authority: candidate.authority,
                source: candidate.source, anchorInstant: candidate.firstMatchingSampleInstant,
                deadlineInstant: deadline, nonce: try allocator.next(in: .nonce))
            candidate.arm = .init(deadlineInstant: ticket.deadlineInstant, nonce: ticket.nonce)
            authority.routeStabilityCandidate = candidate
            return ticket
        }
    }

    func commitOutputRouteStability(_ ticket: RouteStabilityTicket) throws -> StableRouteCommitIdentity? {
        defer { notifyPlaybackProgress() }
        return try transaction(operationDescriptor: .resourceOwnership) { output in
            guard let candidate = authority.routeStabilityCandidate, candidate.stabilityTicket == ticket,
                  ticket.authority == currentOutputRouteAuthorityLocked(),
                  routeCandidateCanConfirmLocked(candidate, output: output),
                  !authority.snapshot.interruptionVeto, var context = authority.outputContext,
                  context.disposition != .releaseAfterTeardown, !context.poisoned,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket.source }),
                  authority.commands[index]?.phase == .terminal(.completed), authority.commands[index]?.resultClaimed == true else { return nil }
            let instant = monotonicClock.nowNanoseconds
            guard routeBoundaryAllowsWorkLocked(candidate.boundary, at: instant), parentAllowsWork(context.parentDeadline, at: instant) else {
                try timeoutOutputRouteBoundaryLocked(contextNonce: context.contextNonce, at: instant, output: &output)
                return nil
            }
            guard instant >= ticket.deadlineInstant else { return nil }
            if isClosedAirPlayPolicyCandidateLocked(candidate) {
                guard try beginOutputTransitionLocked(context: &context, reason: .terminal,
                    anchorInstant: instant, teardown: true, sourceActivation: nil, output: &output) != nil else {
                    throw PlaybackSafetyFailure.invalidEvidence
                }
                authority.outputContext?.poisoned = true
                authority.routeStabilityCandidate = nil
                authority.stableRouteCommit = nil
                authority.registeredPostConfigurationProof = nil
                output.routeObservationGateOpen = false
                throw PlaybackBackendSelectionError.airPlayLongFormUnavailable
            }
            if case .postConfiguration = candidate.boundary {
                return try commitResetRouteStabilityLocked(ticket, context: &context, sourceIndex: index, output: &output)
            }
            guard ticket.authority.configurationTransitionIdentity == nil, ticket.authority.postConfigurationStageIdentity == nil,
                  ticket.authority.systemOpenConfigurationGeneration == authority.currentConfigurationGeneration,
                  context.pendingReset == nil else { return nil }
            let commit = StableRouteCommitIdentity(epoch: try allocator.next(in: .routeCommit), authority: ticket.authority)
            context.audioAdmissionFenceRevision = ticket.authority.audioAdmissionFenceRevision
            authority.outputContext = context
            authority.stableRouteCommit = commit
            authority.routeStabilityCandidate = nil
            authority.routeObservationState = .open(ticket.authority)
            authority.commands[index] = nil
            output.routeObservationGateOpen = true
            return commit
        }
    }

    private func currentOutputRouteAuthorityLocked() -> PlaybackRouteAuthorityIdentity? {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).currentOutputRouteAuthorityLocked()
    }

    private func routeCandidateCanConfirmLocked(_ candidate: OutputRouteStabilityCandidate,
        output: PlaybackOutputSafetyState) -> Bool {
        output.routeObservationGateOpen || isClosedAirPlayPolicyCandidateLocked(candidate)
    }

    private func isClosedAirPlayPolicyCandidateLocked(_ candidate: OutputRouteStabilityCandidate) -> Bool {
        guard candidate.authority.semanticIdentity?.backend == .hlsAVPlayer,
              candidate.authority == currentOutputRouteAuthorityLocked(),
              let context = authority.outputContext, let receipt = authority.processConfigurationReceipt,
              context.sessionReceipts?.process == receipt, receipt.actualPolicy == .default,
              receipt.identity.mediaServicesEpoch == candidate.authority.mediaServicesEpoch,
              receipt.identity.configurationGeneration == candidate.authority.audioSessionConfigurationGeneration
        else { return false }
        return true
    }

    private func matchesRouteObservation(_ ticket: RouteObservationTicket, _ current: PlaybackRouteAuthorityIdentity) -> Bool {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).matchesRouteObservation(ticket, current)
    }

    private func routeBoundaryLocked(_ pending: PendingRouteObservation) -> OutputRouteAvailabilityBoundary? {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).routeBoundaryLocked(pending)
    }

    func ordinaryRouteDeadlineArmSnapshot() -> RouteUnavailableDeadlineArmTicket? {
        projection {
            if case .pending(let pending) = authority.routeObservationState, let arm = pending.ordinaryDeadlineState?.arm { return arm }
            guard let inherited = authority.outputContext?.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute else { return nil }
            return .init(ticketIdentity: inherited.ticketIdentity, armNonce: inherited.timerArmIdentity)
        }
    }

    func postConfigurationRouteDeadlineSnapshot() -> PostConfigurationRouteState? {
        projection { authority.postConfigurationRouteState }
    }

    func postConfigurationRouteDeadlineArmSnapshot() -> PostConfigurationRouteDeadlineArmTicket? {
        guard let state = postConfigurationRouteDeadlineSnapshot(), state.runningSince != nil else { return nil }
        return .init(configurationTransitionIdentity: state.budget.configurationTransitionIdentity,
            stageIdentity: state.budget.stageIdentity, configurationGeneration: state.budget.configurationGeneration,
            parentOperationTicketIdentity: state.budget.parentOperationDeadline,
            attemptNonce: state.budget.attemptNonce, freezeGeneration: state.freezeGeneration)
    }

    func playbackOperationDeadlineArmSnapshot() -> PlaybackOperationDeadlineArmTicket? {
        projection {
            guard let original = authority.outputContext?.parentDeadline else { return nil }
            let parent: PlaybackProgressBudgetTicket
            switch original { case .coldStart(let value), .outputRecovery(let value): parent = value }
            guard parent.runningSince != nil else { return nil }
            return .init(parentOperationTicketIdentity: parent.identity,
                freezeGeneration: parent.freezeGeneration)
        }
    }

    func rearmOutputPlaybackOperationDeadline(
        _ expected: PlaybackOperationDeadlineArmTicket
    ) -> PlaybackDeadlineRearm<PlaybackOperationDeadlineArmTicket>? {
        defer { notifyPlaybackProgress() }
        guard case .budget(.playbackOperationRearmed(let schedule))? =
            executor.performPlaybackBudget(.playbackOperationTimer(expected)) else { return nil }
        return schedule
    }

    func rearmOutputResetPreRouteDeadline(
        _ expected: ResetPreRouteRecoveryDeadlineArmTicket
    ) -> PlaybackDeadlineRearm<ResetPreRouteRecoveryDeadlineArmTicket>? {
        defer { notifyPlaybackProgress() }
        guard case .budget(.resetPreRouteRearmed(let schedule))? =
            executor.performPlaybackBudget(.resetPreRouteTimer(expected)) else { return nil }
        return schedule
    }

    func rearmOutputPostConfigurationRouteDeadline(
        _ expected: PostConfigurationRouteDeadlineArmTicket
    ) -> PlaybackDeadlineRearm<PostConfigurationRouteDeadlineArmTicket>? {
        defer { notifyPlaybackProgress() }
        guard case .budget(.postConfigurationRearmed(let schedule))? =
            executor.performPlaybackBudget(.postConfigurationTimer(expected)) else { return nil }
        return schedule
    }

    func completePlaybackMediaProgress(_ receipt: PlaybackMediaProgressReceipt) -> Bool {
        defer { notifyPlaybackProgress() }
        return executor.performPlaybackBudget(.mediaProgress(receipt)) == .budget(.progressCompleted)
    }

    func completeSampleBufferReadiness(_ backend: PlaybackBackendIdentity) -> Bool {
        defer { notifyPlaybackProgress() }
        var accepted = false
        executor.sync {
            let current: (PlaybackMediaProgressReceipt, Bool)? = try? transaction { output in
                var safety = authority.snapshot
                safety.output = output
                guard safety.failure == nil else { return nil }
                guard !safety.userPaused else { return nil }
                guard !safety.interruptionVeto else { return nil }
                guard safety.outputPermitPresent else { return nil }
                guard safety.readinessOpen else { return nil }
                guard safety.routeObservationGateOpen else { return nil }
                guard case .installed(let context, let owned) = authority.resourceState else {
                    return nil
                }
                guard !context.poisoned else { return nil }
                guard context.owner == nil else { return nil }
                guard context.disposition != .releaseAfterTeardown else { return nil }
                guard context.desiredBackendKind == .sampleBuffer || context.desiredBackendKind == .hlsAVPlayer else { return nil }
                guard owned.identity == backend else { return nil }
                guard context.sessionIdentity == backend.sessionIdentity else { return nil }
                guard let interval = context.interval, context.activation == interval.activation,
                      context.backendObjectNonce == interval.backendObjectNonce,
                      owned.identity == interval.backendIdentity, owned.lifecycle == interval.outputLifecycle else {
                    return nil
                }
                guard context.mediaServicesEpoch == safety.mediaServicesEpoch else { return nil }
                guard context.interruptionEpoch == safety.interruptionEpoch else { return nil }
                guard context.audioAdmissionFenceRevision == safety.audioAdmissionFenceRevision else { return nil }
                guard let active = context.sessionReceipts?.active, active.leaseID == owned.lease.leaseID,
                      active.interruptionEpoch == safety.interruptionEpoch,
                      active.configurationGeneration == authority.currentConfigurationGeneration else {
                    return nil
                }
                guard let stable = authority.stableRouteCommit else { return nil }
                guard let route = authority.currentRouteAuthority() else { return nil }
                guard stable.exactlyMatches(route, observationGateOpen: safety.routeObservationGateOpen) else {
                    return nil
                }
                guard authority.authoritativeRoute.semantic != nil else { return nil }
                return (.init(intervalKey: interval, sessionIdentity: context.sessionIdentity,
                    contextNonce: context.contextNonce, mediaServicesEpoch: context.mediaServicesEpoch,
                    interruptionEpoch: context.interruptionEpoch,
                    audioAdmissionFenceRevision: context.audioAdmissionFenceRevision, stableRouteCommit: stable),
                    context.parentDeadline != nil)
            }
            guard let (receipt, hasParent) = current else {
                return
            }
            let budgetResult = executor.performPlaybackBudget(.mediaProgress(receipt))
            accepted = !hasParent || budgetResult == .budget(.progressCompleted)
        }
        return accepted
    }

    func rearmOutputOrdinaryRouteDeadline(
        _ expected: RouteUnavailableDeadlineArmTicket
    ) throws -> PlaybackDeadlineRearm<RouteUnavailableDeadlineArmTicket>? {
        defer { notifyPlaybackProgress() }
        guard case .budget(.ordinaryRouteRearmed(let schedule))? =
            executor.performPlaybackBudget(.ordinaryRouteTimer(expected)) else { return nil }
        return schedule
    }

    private func routeBoundaryAllowsWorkLocked(_ boundary: OutputRouteAvailabilityBoundary, at instant: UInt64) -> Bool {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).routeBoundaryAllowsWorkLocked(boundary, at: instant)
    }

    private func timeoutOutputRouteBoundaryLocked(contextNonce: UInt64, at instant: UInt64,
        output: inout PlaybackOutputSafetyState) throws {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).timeoutOutputRouteBoundaryLocked(contextNonce: contextNonce, at: instant, output: &output)
    }

    private func commitResetRouteStabilityLocked(_ ticket: RouteStabilityTicket, context: inout OutputResourceContext, sourceIndex: Int,
        output: inout PlaybackOutputSafetyState) throws -> StableRouteCommitIdentity? {
        guard context.phase == .pendingSuccessorLease,
              let binding = context.systemRecoveryBinding, let stage = authority.postConfigurationRouteState,
              context.pendingReset == binding.incarnation.identity.root,
              authority.currentResetRoot == binding.incarnation.identity.root,
              stage.budget.configurationTransitionIdentity == .reset(binding.incarnation.identity),
              ticket.authority.configurationTransitionIdentity == stage.budget.configurationTransitionIdentity,
              ticket.authority.postConfigurationStageIdentity == stage.budget.stageIdentity,
              let proof = authority.registeredPostConfigurationProof,
              proof.incarnationIdentity == binding.incarnation.identity, proof.retainedContextNonce == context.contextNonce,
              proof.postConfigurationStageIdentity == stage.budget.stageIdentity,
              proof.committedGeneration == authority.currentConfigurationGeneration,
              let semantic = ticket.authority.semanticIdentity else { return nil }
        let open = PlaybackRouteAuthorityIdentity(sessionIdentity: ticket.authority.sessionIdentity,
            monitorLifecycle: ticket.authority.monitorLifecycle, mediaServicesEpoch: ticket.authority.mediaServicesEpoch,
            interruptionEpoch: ticket.authority.interruptionEpoch,
            audioSessionConfigurationGeneration: ticket.authority.audioSessionConfigurationGeneration,
            audioSessionActivationNonce: ticket.authority.audioSessionActivationNonce,
            audioAdmissionFenceRevision: ticket.authority.audioAdmissionFenceRevision,
            routeObservationRevision: ticket.authority.routeObservationRevision, semanticIdentity: semantic,
            configurationTransitionIdentity: nil, postConfigurationStageIdentity: nil,
            systemOpenConfigurationGeneration: authority.currentConfigurationGeneration)
        let commit = StableRouteCommitIdentity(epoch: try allocator.next(in: .routeCommit), authority: open)
        let nonce = try allocator.next(in: .nonce)
        let claimant: OutputSuccessorCreationOwner
        switch context.claimOrigin {
        case .initial:
            claimant = .initialRetry(.init(origin: context.claimOrigin, stableRouteCommitEpoch: commit.epoch,
                nonce: try allocator.next(in: .nonce)))
        case .replacement:
            guard let owner = context.owner else { return nil }
            claimant = .replacement(owner)
        }
        let claim = OutputSuccessorClaim(leaseClaim: .init(contextNonce: nonce, nonce: try allocator.next(in: .nonce)),
            creationOwner: claimant, stableCommit: commit)
        let rebase = OutputRetainedRebaseResult(contextNonce: nonce, owner: context.owner, stableCommit: commit, successorClaim: claim)
        context.contextNonce = nonce
        context.mediaServicesEpoch = open.mediaServicesEpoch
        context.interruptionEpoch = open.interruptionEpoch
        context.audioAdmissionFenceRevision = open.audioAdmissionFenceRevision
        context.desiredBackendKind = semantic.backend
        if case .replacement = context.claimOrigin, let owner = context.owner { context.claimOrigin = .replacement(owner) }
        context.retainedRebase = rebase
        context.resetResourceBinding = nil
        context.pendingReset = nil
        context.resetProof = nil
        authority.outputContext = context
        authority.postConfigurationRouteState = nil
        authority.registeredPostConfigurationProof = nil
        authority.registeredDrainProof = nil
        authority.stableRouteCommit = commit
        authority.routeObservationState = .open(open)
        authority.routeStabilityCandidate = nil
        authority.commands[sourceIndex] = nil
        authority.audioPhase?.resetBinding = nil
        authority.audioPhase?.reactivationState = nil
        authority.audioPhase?.currentReactivationProof = nil
        output.routeObservationGateOpen = true
        return commit
    }

    private func parentAllowsWork(_ parent: CurrentPlaybackOperationDeadlineTicket?, at instant: UInt64) -> Bool {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).parentAllowsWork(parent, at: instant)
    }

    func processAudioSessionReceiptSnapshot() -> ProcessAudioSessionConfigurationReceipt? {
        projection { authority.processConfigurationReceipt }
    }

    func beginOutputTransition(contextNonce: UInt64, reason: OutputTransitionReason,
        anchorInstant: UInt64, teardown: Bool, sourceActivation: ActivationEpoch? = nil) throws -> OutputTransitionOwnerTicket? {
        defer { notifyPlaybackProgress() }
        return try transaction(operationDescriptor: .resourceOwnership, safetyFailureFallback: { output in
            try self.beginOutputTransitionLocked(contextNonce: contextNonce, reason: .terminal,
                anchorInstant: anchorInstant, teardown: true, sourceActivation: sourceActivation, output: &output)
        }) { output in
            try beginOutputTransitionLocked(contextNonce: contextNonce, reason: reason,
                anchorInstant: anchorInstant, teardown: teardown, sourceActivation: sourceActivation, output: &output)
        }
    }

    private func beginOutputTransitionLocked(contextNonce: UInt64, reason: OutputTransitionReason,
        anchorInstant: UInt64, teardown: Bool, sourceActivation: ActivationEpoch?,
        output: inout PlaybackOutputSafetyState) throws -> OutputTransitionOwnerTicket? {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputTransitionLocked(contextNonce: contextNonce, reason: reason, anchorInstant: anchorInstant, teardown: teardown, sourceActivation: sourceActivation, output: &output)
    }

    /// 只接受调用方从本Authority复制并验证的局部context；可失败准备不直接inout权威存储。
    private func beginOutputTransitionLocked(context: inout OutputResourceContext, reason: OutputTransitionReason,
        anchorInstant: UInt64, teardown: Bool, sourceActivation: ActivationEpoch?,
        output: inout PlaybackOutputSafetyState) throws -> OutputTransitionOwnerTicket? {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputTransitionLocked(context: &context, reason: reason, anchorInstant: anchorInstant, teardown: teardown, sourceActivation: sourceActivation, output: &output)
    }

    private func sealOutputWorkLocked(_ group: ControlTaskGroupTicket) {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).sealOutputWorkLocked(group)
    }

    /// 只替换同一已完成普通pause的准确record；失败前不会移除旧责任或消费最终预留。
    private func prepareSuspendReplacingCompletedPause(_ old: OutputSuspendTicket,
        reservation: CleanupReservation, releases: Bool) throws -> PreparedCommand {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).prepareSuspendReplacingCompletedPause(old, reservation: reservation, releases: releases)
    }

    func completeOutputSuspend(_ receipt: OutputQuiescenceReceipt) -> Bool {
        // 普通值 receipt 只保留旧控制测试的编译形状；生产 interval 关闭必须先消费
        // kind-specific opaque proof，调用方布尔值不能进入 executor。
        _ = receipt
        return false
    }

    private func completeValidatedOutputSuspend(_ receipt: OutputQuiescenceReceipt) -> Bool {
        defer { notifyPlaybackProgress() }
        return executor.performOutputSuspend(.complete(receipt)) == .accepted
    }

    /// 只有后端由原 suspend invocation 投影的 kind-specific proof 才能关闭 interval。
    func completeOutputSuspend(_ result: BackendSuspendResult,
                               invocation: BackendSuspendInvocation,
                               backend: any PlaybackBackend) -> Bool {
        if case .requiresRetirement = result {
            defer { notifyPlaybackProgress() }
            return (try? transaction { _ in
                guard var context = authority.outputContext,
                      invocation.registryIssuerIdentity == allocator.issuerIdentity,
                      context.owner != nil, context.suspend == invocation.suspendTicket,
                      context.closeClaim == invocation.closeClaim,
                      !context.suspendConfirmed, !context.suspendRequiresRetirement,
                      let resource = authority.ownedBackendResources,
                      resource.object === backend, resource.identity == backend.identity,
                      resource.lifecycle == invocation.lifecycle,
                      let index = authority.commands.firstIndex(where: {
                          $0?.controlTaskTicket == invocation.suspendTicket.task
                      }), let record = authority.commands[index],
                      record.phase == .running || record.phase == .cancelRequested else { return false }
                context.budget = try context.budget ?? CleanupBudgetTicket(
                    predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                    anchorInstant: invocation.suspendTicket.anchorInstant, nonce: context.reservation.nonce)
                context.suspendRequiresRetirement = true
                context.suspendPreparedPreserved = false
                authority.commands[index]?.phase = .terminal(.completed)
                sealOutputWorkLocked(context.reservation.workGroup)
                authority.outputContext = context
                return true
            }) ?? false
        }
        guard case .quiescent(let proof) = result,
              proof.invocation == invocation,
              proof.backendIdentity == backend.identity,
              proof.itemGeneration == backend.outputItemGeneration else { return false }
        switch proof.kind {
        case .sampleBuffer:
            guard backend.outputItemGeneration == nil,
                  proof.avPlayerReceipt == nil,
                  let issuer = proof.sampleBufferIssuer,
                  issuer.backendIdentity == backend.identity,
                  issuer.lifecycle == invocation.lifecycle,
                  invocation.lifecycle.backendIdentity == backend.identity else { return false }
        case .avPlayer:
            guard let itemGeneration = backend.outputItemGeneration,
                  let receipt = proof.avPlayerReceipt,
                  proof.sampleBufferIssuer == nil,
                  receipt.item.itemGeneration == itemGeneration,
                  receipt.item.outputLifecycleEpoch == invocation.lifecycle,
                  invocation.lifecycle.backendIdentity == backend.identity,
                  receipt.suspendTicket == invocation.suspendTicket,
                  receipt.closeClaim == invocation.closeClaim,
                  receipt.directlyConfirmedRateZero else { return false }
            if let claim = invocation.closeClaim {
                guard receipt.matches(item: receipt.item,
                                      suspendTicket: invocation.suspendTicket,
                                      priorActivationEpoch: invocation.suspendTicket.priorActivation,
                                      closeClaim: claim) else { return false }
            } else {
                guard receipt.priorActivationEpoch == nil,
                      receipt.stopNonce == nil else { return false }
            }
        }
        guard proof.consumeOnce() else { return false }
        return completeValidatedOutputSuspend(.init(
            suspendTicket: invocation.suspendTicket,
            closeClaim: invocation.closeClaim,
            directlyConfirmedRateZero: true,
            preparedPreserved: proof.preparedPreserved))
    }

    /// kind只是路由变化提示；后继种类仍只能由退休后的真实stable commit决定。
    func admitOutputHandoff(session: PlaybackSessionIdentity,
        requestedKind: PlaybackBackendKind) throws -> OutputHandoffAdmission? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard let context = authority.outputContext, context.sessionIdentity == session,
                  context.disposition == .retainForSession(session), !context.poisoned else { return nil }
            if let owner = context.owner {
                guard owner.reason == .recovery else { return nil }
                return .init(owner: owner, startsCleanup: false)
            }
            guard context.phase == .installed, requestedKind != context.desiredBackendKind,
                  let owner = try beginOutputTransitionLocked(contextNonce: context.contextNonce,
                    reason: .recovery, anchorInstant: monotonicClock.nowNanoseconds,
                    teardown: true, sourceActivation: nil, output: &output) else { return nil }
            return .init(owner: owner, startsCleanup: true)
        }
    }

    /// 同kind的endpoint变更（如AirPlay A->B或HDMI内部切換）：不销毁backend与lease，保留在quiescent状态重准备。
    func admitOutputQuiescentEndpointHandoff(session: PlaybackSessionIdentity) throws -> OutputHandoffAdmission? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard let context = authority.outputContext, context.sessionIdentity == session,
                  context.disposition == .retainForSession(session), !context.poisoned else { return nil }
            if let owner = context.owner {
                guard owner.reason == .recovery else { return nil }
                return .init(owner: owner, startsCleanup: false)
            }
            guard context.phase == .installed,
                  let owner = try beginOutputTransitionLocked(contextNonce: context.contextNonce,
                    reason: .recovery, anchorInstant: monotonicClock.nowNanoseconds,
                    teardown: false, sourceActivation: nil, output: &output) else { return nil }
            return .init(owner: owner, startsCleanup: true)
        }
    }


    /// 原backend已经退休并转成retained lease后，原owner才可退休纯值records并重用固定cycle。
    func finishRetainedOutputCleanup(owner: OutputTransitionOwnerTicket) throws -> UInt64? {
        try transaction { output in
            guard var context = authority.outputContext, context.owner == owner,
                  (context.phase == .pendingSuccessorLease || context.phase == .quiescentBackend),
                  owner.reason == .recovery,
                  context.disposition == .retainForSession(context.sessionIdentity),
                  context.delivery == nil, authority.isTerminal(context.reservation.workGroup) else { return nil }
            guard let retiringMask = authority.retainedCleanupRetiringMask(context) else { return nil }
            // 所有checked allocation先在纯值副本完成；失败不丢失旧owner或清理责任。
            guard let cycle = try authority.prepareOutputCycleLocked(&context,
                retiringCommandMask: retiringMask, allocator: allocator) else { return nil }
            for index in authority.commands.indices where retiringMask & (1 << index) != 0 {
                authority.commands[index] = nil
            }
            installOutputCycleLocked(cycle, context: &context)
            authority.outputContext = context
            if let commit = authority.stableRouteCommit,
               let current = currentOutputRouteAuthorityLocked(),
               commit.authority == current, current.semanticIdentity != nil,
               current.systemOpenConfigurationGeneration == current.audioSessionConfigurationGeneration {
                output.routeObservationGateOpen = true
            }
            return context.contextNonce
        }
    }

    func authoritativeRouteSnapshot() -> OutputAuthoritativeRoute {
        projection { authority.authoritativeRoute }
    }

    /// 领取原owner的准确SDK对象与lifecycle；并行caller、旧owner和重复领取一律拒绝。
    func claimOutputBackendCleanup(_ ticket: ControlTaskTicket,
        owner: OutputTransitionOwnerTicket) -> OutputBackendCleanupInvocation? {
        try? transaction { output in
            guard let context = authority.outputContext, context.owner == owner,
                  context.suspend?.task == ticket || context.retirement == ticket || context.teardown == ticket,
                  authority.commands.first(where: { $0?.controlTaskTicket == ticket })??.backendOperation == nil,
                  let resource = authority.ownedBackendResources,
                  let backend = resource.object as? any PlaybackBackend,
                  backend.identity == resource.identity,
                  try AudioSessionLockedOperations(authority: authority, allocator: allocator,
                    instant: monotonicClock.nowNanoseconds).claimStart(ticket, output: &output) else { return nil }
            let suspendInvocation: BackendSuspendInvocation?
            if let stop = context.suspend, stop.task == ticket {
                guard stop.lifecycle == resource.lifecycle else { return nil }
                if let close = context.closeClaim {
                    guard close.suspendTicket == stop, close.intervalKey == context.interval else { return nil }
                } else if context.interval != nil {
                    return nil
                }
                guard let issuer = allocator.issuerIdentity else { return nil }
                suspendInvocation = .init(registryIssuerIdentity: issuer,
                    suspendTicket: stop, closeClaim: context.closeClaim)
            } else {
                suspendInvocation = nil
            }
            return .init(task: ticket, owner: owner, contextNonce: context.contextNonce,
                backend: backend, lifecycle: resource.lifecycle, suspendInvocation: suspendInvocation)
        }
    }

    func advanceOutputCleanup(owner: OutputTransitionOwnerTicket) throws -> ControlTaskTicket? {
        try transaction { _ in
            guard var context = authority.outputContext, context.owner == owner,
                  var resource = authority.ownedResource else { return nil }
            if context.delivery != nil { return nil }
            if let index = authority.commands.firstIndex(where: {
                $0?.groupTicket == context.reservation.ownerGroup && $0?.slot == ReservedCleanupStage.owner.slot
            }), authority.commands[index]?.phase == .queued { authority.commands[index]?.phase = .running }
            if let stop = context.suspend, !context.suspendConfirmed &&
                !context.suspendRequiresRetirement && !context.suspendTimedOut { return stop.task }
            if owner.reason == .pause && context.suspendPreparedPreserved && !context.suspendTimedOut { return nil }
            if case .backend(let backend) = resource.payload {
                if backend.lifecycle != nil && !context.retirementConfirmed {
                    if let task = context.retirement { return task }
                    let prepared = try prepareReservedCleanup(context.reservation, stage: .retirement)
                    context.retirement = prepared.ticket
                    authority.outputContext = context
                    return installPreparedCommand(prepared)
                }
                guard context.teardownRequested || backend.lifecycle == nil && context.phase != .quiescentBackend else { return nil }
                if let task = context.teardown { return task }
                guard authority.isTerminal(context.reservation.workGroup) else { return nil }
                let prepared = try prepareReservedCleanup(context.reservation, stage: .teardown)
                context.teardown = prepared.ticket
                if context.phase != .predecessorCleanup {
                    guard let nonce = authority.cleanupReservation?.nonce(for: .predecessor) else { return nil }
                    context.contextNonce = nonce
                    context.phase = .predecessorCleanup
                    context.claimOrigin = .replacement(owner)
                    authority.cleanupReservation?.consume(.predecessor)
                }
                authority.resourceState = .predecessorCleanup(context, backend)
                return installPreparedCommand(prepared)
            }
            // pending acquisition保留链不能停止monitor；release链的ACK必须先于等待旧activation结果。
            if context.phase == .pendingLeaseAcquisition,
               context.disposition != .releaseAfterTeardown { return nil }
            if !context.monitorStopped {
                if let task = context.monitorStop { return task }
                let prepared = try prepareReservedCleanup(context.reservation, stage: .monitorStop)
                context.monitorStop = prepared.ticket
                context.relayClosing = true
                authority.outputContext = context
                return installPreparedCommand(prepared)
            }
            // acquisition的SDK调用责任仍属于原shape；monitor已停后，只有所有原record终态并转移责任才变lease-only。
            if context.phase == .pendingLeaseAcquisition {
                guard context.disposition == .releaseAfterTeardown else { return nil }
                for index in authority.commands.indices {
                    guard let record = authority.commands[index], record.groupTicket == context.reservation.workGroup else { continue }
                    guard case .terminal = record.phase else { return nil }
                    if case .activate = record.audioPolicy, !record.activationResponsibilityTransferred {
                        guard transferActivationDispositionLocked(record.controlTaskTicket) else { return nil }
                    }
                }
                guard authority.isTerminal(context.reservation.workGroup),
                      let nonce = authority.cleanupReservation?.nonce(for: .leaseOnly),
                      let lease = authority.ownedResource?.payload.lease else { return nil }
                context = authority.outputContext!
                context.contextNonce = nonce
                context.acquisitionDeadline = nil
                authority.resourceState = .leaseOnlyCleanup(context, .owned(lease))
                authority.cleanupReservation?.consume(.leaseOnly)
                context = authority.outputContext!
                resource = authority.ownedResource!
            }
            if let pending = context.pendingActivationCall {
                guard let record = authority.commands.first(where: { $0?.controlTaskTicket == pending.record }) ?? nil,
                      case .terminal = record.phase, transferActivationDispositionLocked(pending.record) else { return nil }
            }
            // 唯一音频slot只能在旧调用真实terminal且物理责任已移交以后归还。
            for index in authority.commands.indices {
                guard let record = authority.commands[index], record.groupTicket == context.reservation.workGroup,
                      record.slot == .audioSessionRecovery, case .terminal = record.phase,
                      authority.mayDiscard(record) else { continue }
                authority.commands[index] = nil
            }
            if let lease = authority.ownedResource?.payload.lease {
                switch lease.deactivation {
                case .awaitingActivationOutcome: return nil
                case .deactivationInFlight(let call): return call.record
                case .requiresDeactivate: return try enqueueCleanupDeactivationLocked(context.reservation)
                case .confirmedInactive, .invalidatedByMediaServicesReset, .deactivationSettled: break
                }
            }
            resource = authority.ownedResource ?? resource
            guard authority.canRelease(resource), authority.isTerminal(context.reservation.workGroup) else { return nil }
            return installPreparedCommand(try prepareReservedCleanup(context.reservation, stage: .leaseRelease))
        }
    }

    func completeOutputRetirement(_ ticket: ControlTaskTicket, lifecycle: OutputLifecycleEpoch) -> Bool {
        (try? transaction { _ in
            guard var context = authority.outputContext, context.retirement == ticket,
                  context.suspendConfirmed || context.suspendRequiresRetirement,
                  context.suspend?.lifecycle == lifecycle,
                  authority.isTerminal(context.reservation.workGroup),
                  case .backend(var backend) = authority.ownedResource?.payload, backend.lifecycle == lifecycle,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.phase == .running else { return false }
            let movesToPredecessor = context.teardownRequested
            if movesToPredecessor {
                guard let owner = context.owner,
                      let nonce = authority.cleanupReservation?.nonce(for: .predecessor) else { return false }
                context.contextNonce = nonce
                context.phase = .predecessorCleanup
                context.claimOrigin = .replacement(owner)
            }
            backend.lifecycle = nil
            // 准确 retirement 的物理停止确认也能结清无法签发 quiescence proof 的原 interval。
            context.interval = nil
            context.activation = nil
            context.suspendConfirmed = true
            authority.commands[index]?.phase = .terminal(.completed)
            context.retirementConfirmed = true
            context.retiredLifecycle = lifecycle
            if movesToPredecessor {
                authority.resourceState = .predecessorCleanup(context, backend)
                authority.cleanupReservation?.consume(.predecessor)
            } else {
                context.phase = .quiescentBackend
                authority.resourceState = .quiescentBackend(context, backend)
            }
            return true
        }) ?? false
    }

    func completeOutputTeardown(_ ticket: ControlTaskTicket, backendIdentity: PlaybackBackendIdentity,
        contextNonce: UInt64) -> OutputBackendDisposalRunner? {
        try? transaction { _ in
            guard var context = authority.outputContext, context.contextNonce == contextNonce,
                  context.phase == .predecessorCleanup, context.teardown == ticket,
                  case .backend(let backend) = authority.ownedResource?.payload,
                  backend.identity == backendIdentity, backend.lifecycle == nil,
                  authority.isTerminal(context.reservation.workGroup),
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  authority.commands[index]?.phase == .running else { return nil }
            let conversion: CleanupReservation.Conversion = context.disposition == .releaseAfterTeardown ? .leaseOnly : .retainedSuccessor
            guard let nonce = authority.cleanupReservation?.nonce(for: conversion) else { return nil }
            let disposal = OutputBackendDisposalRunner(ticket: ticket, object: backend.object)
            context.contextNonce = nonce
            context.phase = conversion == .leaseOnly ? .leaseOnlyCleanup : .pendingSuccessorLease
            authority.resourceState = conversion == .leaseOnly ?
                .leaseOnlyCleanup(context, .owned(backend.lease)) : .pendingSuccessorLease(context, backend.lease)
            authority.cleanupReservation?.consume(conversion)
            authority.commands[index]?.phase = .terminal(.completed)
            return disposal
        }
    }

    private struct PreparedOutputCycle {
        let reservation: CleanupReservation
        let groupIndex: Int
        let retiredDescendantMask: UInt32
        let group: Group
    }

    /// 只准备固定候选；原group及全部SDK责任未退休时继续join。
    private func prepareOutputCycleLocked(_ context: inout OutputResourceContext) throws -> PreparedOutputCycle? {
        try authority.prepareOutputCycleLocked(&context, allocator: allocator)
    }

    private func installOutputCycleLocked(_ prepared: PreparedOutputCycle, context: inout OutputResourceContext) {
        authority.installOutputCycleLocked(prepared, context: &context)
    }

    func renewOutputCycle(contextNonce: UInt64) throws -> CleanupReservationTicket? {
        try transaction(operationDescriptor: .resourceOwnership, safetyFailureFallback: { output in
            try self.terminateOutputCycleRenewalLocked(contextNonce: contextNonce, output: &output)
            return nil
        }) { output in
            guard var context = authority.outputContext, context.contextNonce == contextNonce else { return nil }
            do {
                guard let prepared = try prepareOutputCycleLocked(&context) else { return nil }
                installOutputCycleLocked(prepared, context: &context)
                authority.outputContext = context
                return prepared.reservation.ticket
            } catch {
                try terminateOutputCycleRenewalLocked(contextNonce: contextNonce, output: &output)
                return nil
            }
        }
    }

    private func terminateOutputCycleRenewalLocked(contextNonce: UInt64, output: inout PlaybackOutputSafetyState) throws {
        guard let context = authority.outputContext, context.contextNonce == contextNonce,
              context.phase == .quiescentBackend || context.phase == .pendingSuccessorLease else { return }
        _ = try beginOutputTransitionLocked(contextNonce: contextNonce, reason: .terminal,
            anchorInstant: monotonicClock.nowNanoseconds, teardown: true, sourceActivation: nil, output: &output)
        authority.outputContext?.poisoned = true
    }

    func rebaseRetainedOutput(contextNonce: UInt64, stableCommit: StableRouteCommitIdentity,
        owner: OutputTransitionOwnerTicket?) throws -> OutputRetainedRebaseResult? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard var context = authority.outputContext else { return nil }
            guard context.contextNonce == contextNonce else { return nil }
            guard context.phase == .pendingSuccessorLease || context.phase == .quiescentBackend else { return nil }
            guard context.owner == owner else { return nil }
            guard context.disposition == .retainForSession(context.sessionIdentity) else { return nil }
            guard !context.poisoned else { return nil }
            guard context.pendingReset == nil else { return nil }
            guard !authority.snapshot.interruptionVeto else { return nil }
            guard authority.stableRouteCommit == stableCommit else { return nil }
            guard let current = currentOutputRouteAuthorityLocked() else { return nil }
            if stableCommit.authority == current, current.semanticIdentity != nil,
               current.systemOpenConfigurationGeneration == current.audioSessionConfigurationGeneration {
                output.routeObservationGateOpen = true
            }
            guard stableCommit.exactlyMatches(current, observationGateOpen: output.routeObservationGateOpen) else { return nil }
            guard let kind = current.semanticIdentity?.backend else { return nil }
            guard parentAllowsWork(context.parentDeadline, at: monotonicClock.nowNanoseconds) else { return nil }
            if let existing = context.retainedRebase,
               existing.contextNonce == contextNonce,
               existing.owner == owner,
               existing.stableCommit == stableCommit { return existing }
            let nonce = try allocator.next(in: .nonce)
            let claim: OutputSuccessorClaim?
            if context.phase == .pendingSuccessorLease {
                let claimant: OutputSuccessorCreationOwner
                switch context.claimOrigin {
                case .initial:
                    claimant = .initialRetry(.init(origin: context.claimOrigin, stableRouteCommitEpoch: stableCommit.epoch,
                        nonce: try allocator.next(in: .nonce)))
                case .replacement:
                    guard let owner else { return nil }
                    claimant = .replacement(owner)
                }
                claim = .init(leaseClaim: .init(contextNonce: nonce, nonce: try allocator.next(in: .nonce)),
                    creationOwner: claimant, stableCommit: stableCommit)
            } else {
                claim = nil
            }
            let result = OutputRetainedRebaseResult(contextNonce: nonce, owner: owner, stableCommit: stableCommit, successorClaim: claim)
            context.contextNonce = nonce
            context.mediaServicesEpoch = current.mediaServicesEpoch
            context.interruptionEpoch = current.interruptionEpoch
            context.audioAdmissionFenceRevision = current.audioAdmissionFenceRevision
            context.desiredBackendKind = kind
            if case .replacement = context.claimOrigin, let owner { context.claimOrigin = .replacement(owner) }
            context.retainedRebase = result
            context.interruptionProof = nil
            context.resetProof = nil
            authority.outputContext = context
            authority.registeredDrainProof = nil
            return result
        }
    }

    func claimOutputSuccessor(_ claim: OutputSuccessorClaim) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .factoryAdmission) { output in
            guard case .pendingSuccessorLease(var context, let lease) = authority.resourceState,
                  context.retainedRebase?.successorClaim == claim, context.contextNonce == claim.leaseClaim.contextNonce,
                  context.retainedRebase?.owner == context.owner,
                  authority.stableRouteCommit == claim.stableCommit,
                  let current = currentOutputRouteAuthorityLocked(),
                  claim.stableCommit.exactlyMatches(current, observationGateOpen: output.routeObservationGateOpen),
                  context.disposition == .retainForSession(context.sessionIdentity), !context.poisoned,
                  context.pendingReset == nil, !authority.snapshot.interruptionVeto,
                  let reservation = authority.cleanupReservation, !reservation.terminal, reservation.consumedConversions == 0,
                  context.mediaServicesEpoch == current.mediaServicesEpoch,
                  context.interruptionEpoch == current.interruptionEpoch,
                  context.audioAdmissionFenceRevision == current.audioAdmissionFenceRevision,
                  let kind = current.semanticIdentity?.backend, case .requiresDeactivate = lease.deactivation,
                  parentAllowsWork(context.parentDeadline, at: monotonicClock.nowNanoseconds) else { return nil }
            switch (context.claimOrigin, claim.creationOwner) {
            case (.initial, .initialRetry(let retry)):
                guard retry.origin == context.claimOrigin, retry.stableRouteCommitEpoch == claim.stableCommit.epoch else { return nil }
            case (.replacement(let owner), .replacement(let claimant)):
                guard owner == claimant, context.owner == claimant else { return nil }
            default: return nil
            }
            let backend = PlaybackBackendIdentity(sessionIdentity: context.sessionIdentity,
                backendGeneration: try allocator.next(in: .backend))
            let lifecycleNonce = try allocator.next(in: .outputLifecycle)
            let nonce = try allocator.next(in: .nonce)
            let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .factory,
                policy: .routeSpeculativeRateZero, audioIdentity: nil, audioPolicy: nil)
            let prepare = PrepareTicket(backendIdentity: backend, stableRouteCommitEpoch: claim.stableCommit.epoch,
                audioAdmissionFenceRevision: current.audioAdmissionFenceRevision, prepareNonce: try allocator.next(in: .prepare))
            context.contextNonce = nonce
            context.candidateBackendIdentity = backend
            context.candidateLifecycleNonce = lifecycleNonce
            context.backendObjectNonce = nonce
            context.desiredBackendKind = kind
            context.sourceTask = prepared.ticket
            context.prepareTicket = prepare
            context.retainedRebase = nil
            authority.resourceState = .pendingCreation(context, lease)
            return installPreparedCommand(prepared)
        }
    }

    private func installSampleBufferQuiescenceIssuerIfSupported(
        _ object: any OwnedPlaybackResource,
        identity: PlaybackBackendIdentity,
        lifecycle: OutputLifecycleEpoch
    ) {
        guard let backend = object as? any SampleBufferQuiescenceIssuerInstalling else { return }
        backend.installSampleBufferQuiescenceIssuer(.init(
            backendIdentity: identity, lifecycle: lifecycle))
    }

    func reprepareQuiescentOutput(_ rebase: OutputRetainedRebaseResult) throws -> ControlTaskTicket? {
        let backendObject: (any OwnedPlaybackResource)? = projection {
            authority.ownedBackendResources?.object
        }
        let replacementSlot = (backendObject as?
            any BackendPublicationReplacementAuthorityInstalling)?
            .backendPublicationReplacementAuthoritySlot
        return try transaction(operationDescriptor: .prepareAdmission) { output in
            guard case .quiescentBackend(var context, var backend) = authority.resourceState,
                  backendObject === backend.object,
                  context.retainedRebase == rebase, context.contextNonce == rebase.contextNonce,
                  context.owner == rebase.owner, rebase.successorClaim == nil,
                  context.retirementConfirmed, context.retiredLifecycle != nil, backend.lifecycle == nil,
                  context.disposition == .retainForSession(context.sessionIdentity), !context.poisoned,
                  context.pendingReset == nil, authority.cleanupReservation?.consumedConversions == 0,
                  authority.stableRouteCommit == rebase.stableCommit,
                  let current = currentOutputRouteAuthorityLocked(),
                  rebase.stableCommit.exactlyMatches(current, observationGateOpen: output.routeObservationGateOpen),
                  current.semanticIdentity?.backend == context.desiredBackendKind,
                  parentAllowsWork(context.parentDeadline, at: monotonicClock.nowNanoseconds) else { return nil }
            let lifecycle = OutputLifecycleEpoch(backendIdentity: backend.identity, outputNonce: try allocator.next(in: .outputLifecycle))
            let prepare = PrepareTicket(backendIdentity: backend.identity, stableRouteCommitEpoch: rebase.stableCommit.epoch,
                audioAdmissionFenceRevision: current.audioAdmissionFenceRevision, prepareNonce: try allocator.next(in: .prepare))
            let command = try prepareCommand(group: context.reservation.workGroup, slot: .prepare,
                policy: .routeSpeculativeRateZero, audioIdentity: nil, audioPolicy: nil)
            installSampleBufferQuiescenceIssuerIfSupported(
                backend.object, identity: backend.identity, lifecycle: lifecycle)
            if let replacementSlot {
                let replacement = BackendPublicationReplacementAuthority(
                    registry: self, sourceTask: command.ticket,
                    prepareTicket: prepare, lifecycle: lifecycle,
                    contextNonce: context.contextNonce,
                    replacesRetiredLifecycle: true)
                guard replacementSlot.install(
                    replacement, backendObject: backend.object) else { return nil }
            }
            backend.lifecycle = lifecycle
            context.candidateBackendIdentity = backend.identity
            context.suspendRequiresRetirement = false
            context.prepareTicket = prepare
            context.sourceTask = command.ticket
            context.retirementConfirmed = false
            context.retiredLifecycle = nil
            context.retainedRebase = nil
            context.prepared = false
            context.owner = nil
            authority.resourceState = .installed(context, backend)
            return installPreparedCommand(command)
        }
    }

    func completeOutputFactory(_ ticket: ControlTaskTicket, candidate: (any OwnedPlaybackResource)?) throws -> Bool {
        let replacementSlot = (candidate as? any BackendPublicationReplacementAuthorityInstalling)?
            .backendPublicationReplacementAuthoritySlot
        return try completeOutputFactory(ticket, candidate: candidate, notInvoked: nil,
            replacementSlot: replacementSlot)
    }

    private func completeOutputFactory(_ ticket: ControlTaskTicket, candidate: (any OwnedPlaybackResource)?,
        notInvoked: OwnedPlaybackBackendOperation?,
        replacementSlot: BackendPublicationReplacementAuthoritySlot? = nil) throws -> Bool {
        try transaction { output in
            guard case .pendingCreation(let context, _) = authority.resourceState,
                  context.sourceTask == ticket, let identity = context.candidateBackendIdentity,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.slot == .factory,
                  record.factoryResult == nil, !record.resultClaimed,
                  record.payload == nil || record.backendOperation != nil,
                  record.phase == .running || record.phase == .cancelRequested ||
                    (candidate == nil && notInvoked != nil && record.backendOperation === notInvoked &&
                     record.phase == .terminal(.canceled)) else { return false }
            // SDK已经返回：无论后续准备是否成功，准确结果先成为原record的唯一责任。
            let result: OwnedFactoryResult = candidate.map {
                .candidate(identity, contextNonce: context.contextNonce, object: $0)
            } ?? .noObject(contextNonce: context.contextNonce)
            if let runner = record.backendOperation { runner.factoryResult = result }
            else { authority.commands[index]?.payload = .factoryResult(result) }
            authority.commands[index]?.phase = record.phase == .running ? .terminal(.completed) : .terminal(.canceled)
            return try settleOutputFactoryLocked(ticket, replacementSlot: replacementSlot,
                output: &output)
        }
    }

    func settleOutputFactory(_ ticket: ControlTaskTicket) throws -> Bool {
        let candidate: (any OwnedPlaybackResource)? = projection {
            guard let record = authority.commands.first(where: {
                $0?.controlTaskTicket == ticket
            }) ?? nil,
                  case .candidate(_, _, let object) = record.factoryResult else { return nil }
            return object
        }
        let replacementSlot = (candidate as? any BackendPublicationReplacementAuthorityInstalling)?
            .backendPublicationReplacementAuthoritySlot
        return try transaction { output in
            try settleOutputFactoryLocked(ticket, replacementSlot: replacementSlot,
                output: &output)
        }
    }

    private func settleOutputFactoryLocked(_ ticket: ControlTaskTicket,
        replacementSlot: BackendPublicationReplacementAuthoritySlot?,
        output: inout PlaybackOutputSafetyState) throws -> Bool {
            guard case .pendingCreation(var context, let lease) = authority.resourceState,
                  context.sourceTask == ticket, let identity = context.candidateBackendIdentity,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], case .terminal = record.phase,
                  !record.resultClaimed, let result = record.factoryResult, result.contextNonce == context.contextNonce else { return false }
            let releasing = context.disposition == .releaseAfterTeardown || authority.cleanupReservation?.terminal == true
            if case .candidate(let candidateIdentity, _, let candidate) = result {
                guard candidateIdentity == identity else { return false }
                guard context.candidateLifecycleNonce != 0 else { return false }
                let lifecycle = OutputLifecycleEpoch(backendIdentity: identity,
                    outputNonce: context.candidateLifecycleNonce)
                let accepts = !releasing && !context.poisoned && record.phase == .terminal(.completed) && !record.resultInvalidated &&
                    authority.matches(record.safetySnapshot) && output.routeObservationGateOpen &&
                    !authority.snapshot.interruptionVeto && authority.snapshot.failure == nil && context.pendingReset == nil
                if accepts {
                    do {
                        let prepared = try prepareCommand(group: context.reservation.workGroup, slot: .prepare,
                            policy: .routeSpeculativeRateZero, audioIdentity: nil, audioPolicy: nil)
                        installSampleBufferQuiescenceIssuerIfSupported(
                            candidate, identity: identity, lifecycle: lifecycle)
                        if let replacementSlot {
                            guard let prepareTicket = context.prepareTicket,
                                  prepareTicket.backendIdentity == identity else {
                                throw Failure.invalidGroup
                            }
                            let replacement = BackendPublicationReplacementAuthority(
                                registry: self, sourceTask: prepared.ticket,
                                prepareTicket: prepareTicket, lifecycle: lifecycle,
                                contextNonce: context.contextNonce,
                                replacesRetiredLifecycle: false)
                            guard replacementSlot.install(
                                replacement, backendObject: candidate) else {
                                throw Failure.invalidGroup
                            }
                        }
                        let backend = OwnedBackendResources(identity: identity, object: candidate, lifecycle: lifecycle, lease: lease)
                        context.suspendRequiresRetirement = false
                        context.sourceTask = prepared.ticket
                        context.owner = nil
                        authority.commands[index]?.clearFactoryResultKeepingOperation()
                        authority.commands[index]?.resultClaimed = true
                        authority.resourceState = .installed(context, backend)
                        _ = installPreparedCommand(prepared)
                        return true
                    } catch {
                        context.disposition = .releaseAfterTeardown
                        context.poisoned = true
                        context.owner = .init(identity: authority.cleanupReservation!.terminalOwner, reason: .terminal)
                        context.relayClosing = true
                        context.teardownRequested = true
                        authority.outputContext = context
                        terminateCleanupReservationLocked(context.reservation, output: &output)
                        _ = installPreparedCommand(try prepareOutputCleanupOwner(context.reservation, terminal: true))
                    }
                }
                guard let nonce = authority.cleanupReservation?.nonce(for: .predecessor) else { return false }
                if candidate is any PlaybackBackend {
                    if context.owner == nil {
                        // 撤权可以先于 owner 安装；真实对象仍沿原预留建立退休责任。
                        guard try beginOutputTransitionLocked(contextNonce: context.contextNonce,
                            reason: .terminal,
                            anchorInstant: context.budget?.anchorInstant ?? monotonicClock.nowNanoseconds,
                            teardown: true, sourceActivation: nil, output: &output) != nil,
                              let updated = authority.outputContext else { return false }
                        context = updated
                    }
                    guard let owner = context.owner else { return false }
                    // 原factory结果已归档，原owner保留；尚未prepare的真实对象也需suspend/retire。
                    // 生命周期在factory调用前已预留，结果返回时不再依赖身份分配成功。
                    context.sourceTask = nil
                    context.teardownRequested = true
                    authority.commands[index]?.phase = .terminal(.canceled)
                    authority.commands[index]?.resultClaimed = true
                    authority.commands[index]?.clearFactoryResultKeepingOperation()
                    sealOutputWorkLocked(context.reservation.workGroup)
                    authority.resourceState = .quiescentBackend(context,
                        .init(identity: identity, object: candidate, lifecycle: lifecycle, lease: lease))
                    _ = try beginOutputTransitionLocked(contextNonce: context.contextNonce, reason: owner.reason,
                        anchorInstant: monotonicClock.nowNanoseconds, teardown: true,
                        sourceActivation: nil, output: &output)
                    return true
                }
                let prepared = try prepareReservedCleanup(context.reservation, stage: .teardown)
                context.contextNonce = nonce
                context.teardown = prepared.ticket
                context.sourceTask = nil
                context.teardownRequested = true
                context.budget = try context.budget ?? CleanupBudgetTicket(
                    predecessorIdentity: context.reservation.ownerGroup.resourceIdentity,
                    anchorInstant: monotonicClock.nowNanoseconds, nonce: context.reservation.nonce)
                authority.commands[index]?.phase = .terminal(.canceled)
                authority.commands[index]?.resultClaimed = true
                authority.commands[index]?.clearFactoryResultKeepingOperation()
                sealOutputWorkLocked(context.reservation.workGroup)
                authority.resourceState = .predecessorCleanup(context, .init(identity: identity, object: candidate, lifecycle: nil, lease: lease))
                authority.cleanupReservation?.consume(.predecessor)
                _ = installPreparedCommand(prepared)
            } else {
                let conversion: CleanupReservation.Conversion = releasing ? .leaseOnly : .retainedSuccessor
                guard let nonce = authority.cleanupReservation?.nonce(for: conversion) else { return false }
                context.contextNonce = nonce
                context.sourceTask = nil
                authority.commands[index]?.resultClaimed = true
                authority.commands[index]?.clearFactoryResultKeepingOperation()
                sealOutputWorkLocked(context.reservation.workGroup)
                authority.resourceState = releasing ? .leaseOnlyCleanup(context, .owned(lease)) : .pendingSuccessorLease(context, lease)
                authority.cleanupReservation?.consume(conversion)
            }
            return true
    }

    func timeoutOutputSuspend(_ ticket: OutputSuspendTicket) -> Bool {
        defer { notifyPlaybackProgress() }
        return executor.performOutputSuspend(.timeout(ticket)) == .timedOut
    }

    func timeoutOutputCleanup(_ budget: CleanupBudgetTicket) -> Bool {
        defer { notifyPlaybackProgress() }
        return executor.performPlaybackBudget(.cleanupTimer(budget)) == .terminated
    }

    func timeoutOutputAcquisition(_ deadline: AudioSessionAcquisitionDeadline) -> Bool {
        defer { notifyPlaybackProgress() }
        return executor.performPlaybackBudget(.acquisitionTimer(deadline)) == .terminated
    }

    private func expireOutputAcquisitionLocked(output: inout PlaybackOutputSafetyState) throws -> Bool {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).expireOutputAcquisitionLocked(output: &output)
    }

    func completeOutputAcquisitionWithoutLease(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard case .acquiringWithoutLease(var context) = authority.resourceState,
                  context.sourceTask == ticket,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.slot == .acquire, record.ownedResult == nil,
                  record.phase == .running || record.phase == .cancelRequested else { return false }
            context.acquisitionNoLeaseReceipt = .init(acquisitionTicket: ticket, outcome: .confirmedNoLease)
            context.acquisitionDeadline = nil
            context.sourceTask = nil
            authority.resourceState = .acquiringWithoutLease(context)
            authority.commands[index]?.phase = record.phase == .running ? .terminal(.completed) : .terminal(.canceled)
            authority.commands[index]?.resultClaimed = true
            return true
        }) ?? false
    }

    func completeOutputPrepare(_ ticket: ControlTaskTicket) -> Bool {
        (try? transaction { _ in
            guard let context = authority.outputContext, context.phase == .installed, context.sourceTask == ticket,
                  let index = authority.commands.firstIndex(where: { $0?.controlTaskTicket == ticket }),
                  let record = authority.commands[index], record.slot == .prepare,
                  record.phase == .running || record.phase == .cancelRequested else { return false }
            let accepted = record.phase == .running && !record.resultInvalidated && authority.matches(record.safetySnapshot) &&
                context.suspend == nil && context.disposition != .releaseAfterTeardown
            authority.commands[index]?.phase = accepted ? .terminal(.completed) : .terminal(.canceled)
            if accepted {
                authority.outputContext?.prepared = true
                authority.outputContext?.sourceTask = nil
                if record.backendOperation == nil { authority.commands[index] = nil }
            }
            return true
        }) ?? false
    }

    func beginOutputActivation(contextNonce: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .activationAdmission) { output in
            guard case .installed(var context, let backend) = authority.resourceState,
                  context.contextNonce == contextNonce, context.prepared, context.suspend == nil,
                  context.owner == nil, context.activation == nil, context.interval == nil,
                  context.pendingReset == nil, !context.interruptionDrainRequired, !context.poisoned,
                  let lifecycle = backend.lifecycle, case .requiresDeactivate = backend.lease.deactivation,
                  authority.cleanupReservation?.consumedConversions == 0,
                  authority.cleanupReservation?.terminal == false,
                  context.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch,
                  context.interruptionEpoch == authority.snapshot.interruptionEpoch,
                  context.audioAdmissionFenceRevision == authority.snapshot.audioAdmissionFenceRevision else {
                return nil
            }
            let epoch = ActivationEpoch(outputLifecycleEpoch: lifecycle,
                audioAdmissionFenceRevision: context.audioAdmissionFenceRevision, activationNonce: try allocator.next(in: .activation))
            let command = try prepareCommand(group: context.reservation.workGroup, slot: .activation,
                policy: .activationRequiresOpen, audioIdentity: nil, audioPolicy: nil)
            context.activation = epoch
            context.sourceTask = command.ticket
            authority.resourceState = .installed(context, backend)
            output.outputPermitPresent = true
            output.readinessOpen = true
            return installPreparedCommand(command)
        }
    }

    func openOutputInterval(_ ticket: ControlTaskTicket, itemGeneration: UInt64? = nil) -> PotentiallyAudibleOutputIntervalKey? {
        try? transaction(operationDescriptor: .positiveRateAdmission) { output in
            guard case .installed(var context, let backend) = authority.resourceState,
                  context.sourceTask == ticket, let activation = context.activation, context.suspend == nil,
                  context.interval == nil, context.owner == nil, output.outputPermitPresent,
                  let record = authority.commands.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
                  record.phase == .running, authority.matches(record.safetySnapshot) else { return nil }
            let key = PotentiallyAudibleOutputIntervalKey(backendObjectNonce: context.backendObjectNonce,
                backendIdentity: backend.identity, outputLifecycle: activation.outputLifecycleEpoch,
                itemGeneration: itemGeneration, activation: activation)
            context.interval = key
            context.closeClaim = nil
            authority.resourceState = .installed(context, backend)
            return key
        }
    }

    /// 后端的 await 返回后，再在原 command/interval 上执行一次权威 CAS。
    /// play() 返回期间发生的 cancel、route/session/intent/fence 或 lifecycle 变化都会关闭成功路径。
    func revalidatePositiveRateInvocation(_ invocation: BackendPositiveRateInvocation) -> Bool {
        invocation.revalidateCurrentAuthority()
    }

    private func positiveRateInvocationSnapshot(
        sourceTaskNonce: UInt64,
        activation: ActivationEpoch
    ) -> (ControlTaskTicket, PotentiallyAudibleOutputIntervalKey)? {
        try? transaction(operationDescriptor: .positiveRateAdmission) { output in
            guard output.outputPermitPresent,
                  case .installed(let context, let backend) = authority.resourceState,
                  let sourceTask = context.sourceTask,
                  sourceTask.nonce == sourceTaskNonce,
                  let interval = context.interval,
                  interval.activation == activation,
                  context.activation == activation,
                  context.suspend == nil, context.owner == nil,
                  backend.identity == interval.backendIdentity,
                  backend.lifecycle == interval.outputLifecycle,
                  let record = authority.commands.first(where: {
                      $0?.controlTaskTicket == sourceTask
                  }) ?? nil,
                  !record.resultInvalidated,
                  record.phase == .running || record.phase == .terminal(.completed),
                  authority.matches(record.safetySnapshot) else { return nil }
            return (sourceTask, interval)
        }
    }

    /// MainActor SDK closure 不经过 executor 排队：所有 Registry transaction 都必须先取
    /// 同一 Cell 锁，因此这里持锁读取 Authority 时不存在并发 writer。
    private func performPositiveRateSideEffect(
        capability: BackendPositiveRateCapability,
        sourceTaskNonce: UInt64,
        activation: ActivationEpoch,
        sideEffect: () -> Void
    ) -> Bool {
        executor.safetyIngress.performPositiveRateSideEffect(
            validateAndConsume: { _ in
                guard case .installed(let context, let backend) = self.authority.resourceState,
                      let sourceTask = context.sourceTask,
                      sourceTask.nonce == sourceTaskNonce,
                      let interval = context.interval,
                      interval.activation == activation,
                      context.activation == activation,
                      context.suspend == nil, context.owner == nil,
                      backend.identity == interval.backendIdentity,
                      backend.lifecycle == interval.outputLifecycle,
                      let record = self.authority.commands.first(where: {
                          $0?.controlTaskTicket == sourceTask
                      }) ?? nil,
                      !record.resultInvalidated,
                      record.phase == .running || record.phase == .terminal(.completed),
                      self.authority.matches(record.safetySnapshot),
                      capability.consumeWhileSafetyCellLocked() else { return false }
                return true
            }, sideEffect: sideEffect)
    }

    private func revalidatePositiveRateInvocation(
        sourceTaskNonce: UInt64,
        activation: ActivationEpoch
    ) -> Bool {
        (try? transaction(operationDescriptor: .positiveRateAdmission) { output in
            guard output.outputPermitPresent,
                  case .installed(let context, let backend) = authority.resourceState,
                  let sourceTask = context.sourceTask,
                  sourceTask.nonce == sourceTaskNonce,
                  let interval = context.interval,
                  interval.activation == activation,
                  context.activation == activation,
                  context.suspend == nil, context.owner == nil,
                  backend.identity == interval.backendIdentity,
                  backend.lifecycle == interval.outputLifecycle,
                  let record = authority.commands.first(where: {
                      $0?.controlTaskTicket == sourceTask
                  }) ?? nil,
                  !record.resultInvalidated,
                  record.phase == .running || record.phase == .terminal(.completed),
                  authority.matches(record.safetySnapshot) else { return false }
            return true
        }) ?? false
    }

    /// KVO/HTTP 观察失败闭合时复用当前 lifecycle 的既有 Registry 单飞 stop。
    private func requestAutomaticSuspend(
        sourceTaskNonce: UInt64,
        activation: ActivationEpoch
    ) -> Bool {
        guard let (sourceTask, interval) = positiveRateInvocationSnapshot(
            sourceTaskNonce: sourceTaskNonce, activation: activation),
              let context = outputResourceContextSnapshot(),
              context.activation == interval.activation,
              context.interval == interval,
              context.sourceTask == sourceTask else { return false }
        let owner: OutputTransitionOwnerTicket
        do {
            guard let value = try beginOutputTransition(
                contextNonce: context.contextNonce,
                reason: .pause,
                anchorInstant: monotonicClock.nowNanoseconds,
                teardown: false,
                sourceActivation: interval.activation
            ) else { return false }
            owner = value
        } catch { return false }
        guard let stop = outputResourceContextSnapshot()?.suspend else { return false }
        return startOutputSuspendOperation(stop.task, owner: owner)
    }

    /// publication 失败与正 rate authority 独立：能力仍需精确命中签发时的
    /// prepare/backend/lifecycle/context，并只可消费一次。成功后复用原 recovery
    /// owner 与 registered suspend runner，后继 retirement/reprepare 继续由同一
    /// output cleanup 状态机推进。
    private func requestBackendPublicationReplacement(
        _ capability: BackendPublicationReplacementAuthority
    ) -> Bool {
        var started = false
        executor.sync {
            let runner = OwnedPlaybackBackendOperation(operation: .suspend)
            let prepared: BackendPublicationReplacementTransition? = try? transaction(
                operationDescriptor: .resourceOwnership
            ) { output in
                guard capability.registry === self,
                      !capability.consumed,
                      case .installed(var context, let backend) = authority.resourceState,
                      context.prepareTicket?.backendIdentity == backend.identity,
                      backend.identity == capability.lifecycle.backendIdentity,
                      backend.lifecycle == capability.lifecycle,
                      let prepareRecord = authority.commands.first(where: {
                        $0?.controlTaskTicket.nonce == capability.sourceTaskNonce
                      }) ?? nil,
                      prepareRecord.slot == .prepare,
                      prepareRecord.groupTicket == context.reservation.workGroup,
                      prepareRecord.phase == .queued ||
                        prepareRecord.phase == .running ||
                        prepareRecord.phase == .terminal(.completed),
                      context.suspend == nil, context.owner == nil,
                      context.disposition == .retainForSession(context.sessionIdentity),
                      !context.poisoned,
                      let owner = try beginOutputTransitionLocked(
                        context: &context, reason: .recovery,
                        anchorInstant: monotonicClock.nowNanoseconds,
                        // publication replacement 只退休旧 item；backend/lease 由
                        // 后继 reprepare 继续拥有，不能进入 predecessor cleanup。
                        teardown: false, sourceActivation: context.activation,
                        output: &output),
                      let current = authority.outputContext,
                      current.owner == owner,
                      owner.reason == .recovery,
                      let suspend = current.suspend,
                      let suspendIndex = authority.commands.firstIndex(where: {
                        $0?.controlTaskTicket == suspend.task
                      }),
                      authority.commands[suspendIndex]?.phase == .queued,
                      authority.commands[suspendIndex]?.payload == nil,
                      authority.groups.contains(where: {
                        $0?.ticket == suspend.task.group && $0?.sealed == false
                      }) else { return nil }
                // 这里之后只剩不可失败的固定槽写入；能力消费与 runner 登记属于
                // 同一 Cell 临界区，不会暴露“已失权但无 stop task”的半状态。
                authority.commands[suspendIndex]?.payload = .backendOperation(runner)
                let transition = BackendPublicationReplacementTransition(
                    capability: capability, owner: owner, suspend: suspend,
                    backendIdentity: backend.identity,
                    retiredLifecycle: capability.lifecycle,
                    originalContextNonce: context.contextNonce,
                    shouldReactivate: suspend.priorActivation != nil)
                capability.consumed = true
                return transition
            }
            guard let prepared else { return }
            started = launchPreinstalledBackendOperation(
                prepared.suspend.task, runner: runner,
                publicationReplacement: prepared)
        }
        return started
    }

    func finishOutputPause(owner: OutputTransitionOwnerTicket) -> Bool {
        (try? transaction { _ in
            guard var context = authority.outputContext, context.owner == owner, owner.reason == .pause,
                  context.suspendConfirmed, context.suspendPreparedPreserved, !context.suspendTimedOut,
                  let stop = context.suspend, context.interval == nil,
                  authority.commands.allSatisfy({ record in
                      guard let record, record.groupTicket == context.reservation.workGroup,
                            record.slot == .prepare || record.slot == .activation else { return true }
                      if case .terminal = record.phase { return true }
                      return false
                  }) else { return false }
            for index in authority.commands.indices {
                guard let record = authority.commands[index] else { continue }
                if record.controlTaskTicket == stop.task ||
                    record.groupTicket == context.reservation.workGroup && record.slot == .activation {
                    guard case .terminal = record.phase, authority.mayDiscard(record) else { return false }
                }
            }
            for index in authority.commands.indices {
                if authority.commands[index]?.controlTaskTicket == stop.task ||
                    authority.commands[index]?.groupTicket == context.reservation.workGroup && authority.commands[index]?.slot == .activation {
                    authority.commands[index] = nil
                }
            }
            context.suspend = nil
            context.suspendConfirmed = false
            context.suspendPreparedPreserved = false
            context.suspendRequiresRetirement = false
            context.closeClaim = nil
            context.owner = nil
            context.sourceTask = nil
            authority.outputContext = context
            return true
        }) ?? false
    }

    func settleOutputInterruptionDrain(owner: OutputTransitionOwnerTicket) -> OutputInterruptionDrainSettlement {
        executor.settleOutputInterruptionDrain(owner: owner)
    }

    func issueOutputDrainProof(owner: OutputTransitionOwnerTicket, kind: OutputDrainKind) throws -> OutputRegisteredDrainProof? {
        try transaction(operationDescriptor: .resourceOwnership) { _ in
            guard var context = authority.outputContext, context.owner == owner,
                  authority.isTerminal(context.reservation.workGroup), context.interval == nil,
                  context.pendingActivationCall == nil,
                  authority.commands.allSatisfy({ record in
                      guard let record, record.groupTicket == context.reservation.workGroup ||
                          authority.isDescendant(record.groupTicket, of: context.reservation.workGroup) else { return true }
                      guard case .terminal = record.phase else { return false }
                      return authority.mayDiscard(record)
                  }) else { return nil }
            let retained: RetainedAudioSessionResourceShape?
            let quiescent: PlaybackBackendIdentity?
            switch authority.resourceState {
            case .quiescentBackend(_, let backend):
                guard context.retirementConfirmed, context.retiredLifecycle != nil, backend.lifecycle == nil,
                      let monitor = backend.lease.monitor else { return nil }
                retained = .init(sessionIdentity: context.sessionIdentity, leaseID: backend.lease.leaseID,
                    monitorLifecycle: monitor.lifecycle, contextNonce: context.contextNonce)
                quiescent = backend.identity
            case .pendingSuccessorLease(_, let lease):
                guard let monitor = lease.monitor else { return nil }
                retained = .init(sessionIdentity: context.sessionIdentity, leaseID: lease.leaseID,
                    monitorLifecycle: monitor.lifecycle, contextNonce: context.contextNonce)
                quiescent = nil
            case .leaseOnlyCleanup(_, .runner(let ticket)), .routeMonitorCleanup(_, .runner(let ticket)):
                guard context.monitorStopped,
                      authority.commands.contains(where: { $0?.controlTaskTicket == ticket && $0?.phase == .terminal(.completed) }) else { return nil }
                retained = nil; quiescent = nil
            case .acquiringWithoutLease:
                guard let receipt = context.acquisitionNoLeaseReceipt,
                      receipt.acquisitionTicket.group == context.reservation.workGroup else { return nil }
                retained = nil; quiescent = nil
            default: return nil
            }
            let generation = authority.currentConfigurationGeneration
            let result: OutputRegisteredDrainProof
            switch kind {
            case .interruption: return nil
            case .reset:
                guard quiescent == nil, let root = context.pendingReset,
                      root.mediaServicesEpoch == authority.snapshot.mediaServicesEpoch else { return nil }
                let shape: ResetDrainedResourceShape = retained.map { .retainedSuccessor($0) } ?? .noResources
                if let proof = context.resetProof, proof.identity.root == root, proof.resultingResourceShape == shape {
                    return .reset(proof)
                }
                guard retained == nil else { return nil }
                let proof = ResetDrainProof(identity: .init(root: root, proofNonce: try allocator.next(in: .nonce)),
                    parentProofNonce: context.resetProof?.identity.root == root ? context.resetProof?.identity.proofNonce : nil,
                    drainedSessionIdentity: context.sessionIdentity, resultingResourceShape: shape,
                    currentConfigurationGeneration: generation)
                context.resetProof = proof
                result = .reset(proof)
            }
            authority.outputContext = context
            authority.registeredDrainProof = result
            return result
        }
    }

    func beginRetainedOutputResetConfiguration(owner: OutputTransitionOwnerTicket,
        mandatorySuffix: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard try !expireResetPreRouteLocked(output: &output),
                  case .pendingSuccessorLease(var context, let lease) = authority.resourceState,
                  context.owner == owner, context.disposition == .retainForSession(context.sessionIdentity),
                  !context.poisoned, context.interval == nil, context.pendingActivationCall == nil,
                  let root = context.pendingReset, root == authority.currentResetRoot,
                  case .draining(let draining) = context.resetResourceBinding,
                  draining.preRouteBinding.rootIdentity == root,
                  var state = authority.resetPreRouteState, state.ticketIdentity == draining.preRouteBinding.ticketIdentity,
                  let parent = context.parentDeadline else { return nil }
            let parentValue: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let value), .outputRecovery(let value): parentValue = value }
            let suffix = max(state.mandatorySuffix, mandatorySuffix)
            guard suffix > 0, suffix < parentValue.cap else { return nil }
            let instant = monotonicClock.nowNanoseconds
            guard let elapsed = state.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
            let boundary = min(state.boundaryEffectiveElapsed, parentValue.cap - suffix)
            if elapsed >= boundary {
                state.mandatorySuffix = suffix
                state.boundaryEffectiveElapsed = boundary
                try timeoutResetPreRouteLocked(context: &context, state: &state, elapsed: elapsed, instant: instant, output: &output)
                return nil
            }
            do {
                guard let retiringMask = authority.retainedCleanupRetiringMask(context),
                      let cycle = try authority.prepareOutputCycleLocked(&context,
                        retiringCommandMask: retiringMask, allocator: allocator) else { return nil }
                guard let monitor = lease.monitor else { return nil }
                let proof = ResetDrainProof(identity: .init(root: root, proofNonce: try allocator.next(in: .nonce)),
                    parentProofNonce: nil, drainedSessionIdentity: context.sessionIdentity,
                    resultingResourceShape: .retainedSuccessor(.init(sessionIdentity: context.sessionIdentity,
                        leaseID: lease.leaseID, monitorLifecycle: monitor.lifecycle, contextNonce: context.contextNonce)),
                    currentConfigurationGeneration: authority.currentConfigurationGeneration)
                let incarnation = SystemRecoveryIncarnation(identity: .init(root: root,
                    incarnationNonce: try allocator.next(in: .nonce), sessionIdentity: context.sessionIdentity),
                    drainProof: proof, baseConfigurationGeneration: authority.currentConfigurationGeneration,
                    configurationPlan: .preferredLongFormThenDefault, outerDeadlineTicket: parentValue.identity,
                    resetPreRouteDeadlineTicket: .init(identity: state.ticketIdentity),
                    inheritedRouteAvailabilityConstraint: draining.inheritedRouteAvailabilityConstraint)
                let binding = ResetPreRouteTicketBinding(rootIdentity: root, ticketIdentity: state.ticketIdentity,
                    bindingNonce: try allocator.next(in: .nonce))
                let attempt = AudioSessionConfigurationAttempt(nonce: try allocator.next(in: .nonce),
                    plan: .preferredLongFormThenDefault, mediaServicesEpoch: root.mediaServicesEpoch)
                let phase = RegisteredAudioSessionPhase(identity: .init(owner: cycle.reservation.ticket.workGroup.ownerTicket,
                    sessionIdentity: context.sessionIdentity, leaseID: lease.leaseID, contextNonce: context.contextNonce,
                    mediaServicesEpoch: root.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce)),
                    policy: .configureInactive(incarnation: incarnation.identity, resetDrainProof: proof.identity,
                        configurationAttemptNonce: attempt.nonce, step: .longFormCategoryAttempt),
                    configurationAttempt: attempt, parent: parentValue.identity, resetBinding: binding,
                    incarnation: incarnation, reactivationState: nil, configurationProgress: .awaitingLongForm,
                    permitsFurtherCalls: true, acquisitionOwnershipProof: nil, processReceipt: nil,
                    configuredReceipt: nil, inactiveReceipt: nil)
                let command = try prepareCommand(group: cycle.reservation.ticket.workGroup, slot: .audioSessionRecovery,
                    policy: .audioSession, audioIdentity: phase.identity, audioPolicy: phase.policy, preparedCycle: cycle)
                state.mandatorySuffix = suffix
                state.accumulatedEffectiveTime = elapsed
                if state.runningSince != nil {
                    state.runningSince = instant
                    if state.boundaryEffectiveElapsed != boundary {
                        state.deadlineArm = .init(ticketIdentity: state.ticketIdentity,
                            boundaryEffectiveElapsed: boundary, freezeGeneration: state.freezeGeneration,
                            armNonce: try allocator.next(in: .deadline))
                    }
                }
                state.boundaryEffectiveElapsed = boundary
                let retained = SystemRecoveryLeaseBinding(incarnation: incarnation, inactiveConfigurationReceipt: nil,
                    resetPreRouteBinding: binding, configurationState: .awaitingLongForm)
                // 全部checked准备完成；原lease/parent/票据、proof/phase和新group一次安装。
                for index in authority.commands.indices where retiringMask & (1 << index) != 0 {
                    authority.commands[index] = nil
                }
                installOutputCycleLocked(cycle, context: &context)
                context.resetProof = proof
                // 本次reset proof在同锁确认原work全排空，覆盖此前已fold的began。
                // 后续新began仍由Cell重新置位，不能让旧proof跨过新epoch。
                context.interruptionDrainRequired = false
                context.resetResourceBinding = .retained(retained)
                context.resetRecoveryMandatorySuffix = suffix
                context.owner = .init(identity: cycle.reservation.ticket.workGroup.ownerTicket, reason: .recovery)
                context.ownerIngressRevision = authority.snapshot.throughRevision
                settleResetParentClockLocked(state, context: &context)
                authority.resourceState = .pendingSuccessorLease(context, lease)
                authority.registeredDrainProof = .reset(proof)
                authority.audioPhase = phase
                authority.resetPreRouteState = state
                return installPreparedCommand(command)
            } catch {
                try terminateOutputCycleRenewalLocked(contextNonce: context.contextNonce, output: &output)
                return nil
            }
        }
    }

    func beginOutputRetainedResetConfigurationStep(contextNonce: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).beginOutputRetainedResetConfigurationStep(contextNonce: contextNonce, output: &output)
        }
    }

    func beginOutputReactivation(contextNonce: UInt64, mandatorySuffix: UInt64) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard var context = authority.outputContext, var phase = authority.audioPhase,
                  case .pending(var pending) = authority.routeObservationState else { return nil }
            var stage = authority.postConfigurationRouteState
            var command: PreparedCommand?
            var cycle: PreparedOutputCycle?
            switch try authority.prepareReactivation(context: &context, phase: &phase, stage: &stage, pending: &pending,
                command: &command, cycle: &cycle,
                snapshot: authority.snapshot, contextNonce: contextNonce, mandatorySuffix: mandatorySuffix,
                instant: monotonicClock.nowNanoseconds, allocator: allocator) {
            case .waiting: return nil
            case .expired:
                try timeoutOutputRouteBoundaryLocked(contextNonce: contextNonce,
                    at: monotonicClock.nowNanoseconds, output: &output)
                return nil
            case .ready:
                if let cycle { installOutputCycleLocked(cycle, context: &context) }
                authority.outputContext = context
                authority.audioPhase = phase
                authority.postConfigurationRouteState = stage
                authority.routeObservationState = .pending(pending)
                return installPreparedCommand(command!)
            }
        }
    }

    private func parentEffectiveElapsed(_ parent: PlaybackProgressBudgetTicket, at instant: UInt64) -> UInt64? {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).parentEffectiveElapsed(parent, at: instant)
    }

    func evaluateOutputReactivationCutoffArm(_ expected: AudioSessionReactivationCutoffArmTicket) throws -> UInt64? {
        guard case .budget(.reactivationRearmed(let schedule))? =
            executor.performPlaybackBudget(.reactivationTimer(expected)) else { return nil }
        return schedule.remainingNanoseconds
    }

    private func reactivationAllowsWorkLocked(_ phase: RegisteredAudioSessionPhase, at instant: UInt64) -> Bool {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).reactivationAllowsWorkLocked(phase, at: instant)
    }

    func registeredOutputDrainProof() -> OutputRegisteredDrainProof? {
        projection { authority.registeredDrainProof }
    }

    func issueEmptyOutputResetDrainProof(root: MediaServicesResetRootIdentity) throws -> ResetDrainProof? {
        try transaction(operationDescriptor: .resourceOwnership) { _ in
            guard authority.currentResetRoot == root, authority.emptyResetDrainSource == root,
                  authority.resourceState == nil, authority.cleanupReservation == nil,
                  authority.commands.allSatisfy({ $0 == nil }), authority.groups.allSatisfy({ $0 == nil }) else { return nil }
            if case .reset(let proof) = authority.registeredDrainProof, proof.identity.root == root { return proof }
            let proof = ResetDrainProof(identity: .init(root: root, proofNonce: try allocator.next(in: .nonce)),
                parentProofNonce: nil, drainedSessionIdentity: nil, resultingResourceShape: .noResources,
                currentConfigurationGeneration: authority.currentConfigurationGeneration)
            authority.registeredDrainProof = .reset(proof)
            return proof
        }
    }

    func beginResetOutputAcquisition(session: PlaybackSessionIdentity, parent: CurrentPlaybackOperationDeadlineTicket,
        admission: OutputResetAcquisitionAdmission) throws -> ControlTaskTicket? {
        try transaction(operationDescriptor: .resourceOwnership) { _ in
            let parentValue: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let value), .outputRecovery(let value): parentValue = value }
            guard parentValue.identity.sessionIdentity == session,
                  admission.proof.identity.root == authority.currentResetRoot,
                  authority.registeredDrainProof == .reset(admission.proof),
                  admission.proof.resultingResourceShape == .noResources,
                  admission.proof.currentConfigurationGeneration == authority.currentConfigurationGeneration,
                  authority.resourceState == nil, authority.cleanupReservation == nil,
                  admission.mandatorySuffix > 0, admission.mandatorySuffix < parentValue.cap else { return nil }
            let instant = monotonicClock.nowNanoseconds
            let state: ResetPreRouteRecoveryDeadlineState
            let preRoute: ResetPreRouteRecoveryDeadlineTicket
            if let existing = authority.resetPreRouteState,
               existing.ticketIdentity.sessionIdentity == session,
               existing.ticketIdentity.parentOperationTicketIdentity == parentValue.identity {
                guard existing.mandatorySuffix >= admission.mandatorySuffix,
                      let elapsed = existing.effectiveElapsed(at: instant), elapsed < existing.boundaryEffectiveElapsed else { return nil }
                state = existing
                preRoute = .init(identity: existing.ticketIdentity)
            } else {
                preRoute = .init(identity: .init(lineageIdentity: try allocator.next(in: .nonce), sessionIdentity: session,
                    parentOperationTicketIdentity: parentValue.identity, nonce: try allocator.next(in: .deadline)))
                let boundary = parentValue.cap - admission.mandatorySuffix
                guard parentValue.accumulatedEffectiveTime < boundary else { return nil }
                let arm: ResetPreRouteRecoveryDeadlineArmTicket? = authority.snapshot.interruptionVeto ? nil :
                    .init(ticketIdentity: preRoute.identity, boundaryEffectiveElapsed: boundary,
                        freezeGeneration: parentValue.freezeGeneration, armNonce: try allocator.next(in: .deadline))
                state = .init(ticketIdentity: preRoute.identity, mandatorySuffix: admission.mandatorySuffix,
                    boundaryEffectiveElapsed: boundary, accumulatedEffectiveTime: parentValue.accumulatedEffectiveTime,
                    runningSince: authority.snapshot.interruptionVeto ? nil : instant,
                    freezeGeneration: parentValue.freezeGeneration, deadlineArm: arm)
            }
            let binding = OutputResetAcquisitionBinding(proof: admission.proof, preRouteTicket: preRoute,
                binding: .init(rootIdentity: admission.proof.identity.root, ticketIdentity: preRoute.identity,
                    bindingNonce: try allocator.next(in: .nonce)),
                inheritedRouteAvailabilityConstraint: admission.inheritedRouteAvailabilityConstraint)
            let originalProof = authority.registeredDrainProof
            let originalSource = authority.emptyResetDrainSource
            let reservation = try reserveCleanupLocked(resource: .session(session))
            do {
                let prepared = try prepareCommand(group: reservation.ticket.workGroup, slot: .acquire,
                    policy: .routeNeutral, audioIdentity: nil, audioPolicy: nil)
                var context = OutputResourceContext(session: session, reservation: reservation, source: prepared.ticket,
                    parent: parent, resetRecoveryMandatorySuffix: admission.mandatorySuffix)
                settleResetParentClockLocked(state, context: &context)
                context.pendingReset = admission.proof.identity.root
                context.resetProof = admission.proof
                context.resetResourceBinding = .acquiring(binding)
                context.mediaServicesEpoch = authority.snapshot.mediaServicesEpoch
                context.interruptionEpoch = authority.snapshot.interruptionEpoch
                context.audioAdmissionFenceRevision = authority.snapshot.audioAdmissionFenceRevision
                authority.resourceState = .acquiringWithoutLease(context)
                authority.resetPreRouteState = state
                authority.registeredDrainProof = .reset(admission.proof)
                return installPreparedCommand(prepared)
            } catch {
                for index in authority.groups.indices where authority.groups[index]?.ticket == reservation.ticket.ownerGroup ||
                    authority.groups[index]?.ticket == reservation.ticket.workGroup { authority.groups[index] = nil }
                authority.cleanupReservation = nil
                authority.registeredDrainProof = originalProof
                authority.emptyResetDrainSource = originalSource
                throw error
            }
        }
    }

    func resetPreRouteDeadlineSnapshot() -> ResetPreRouteRecoveryDeadlineState? {
        projection { authority.resetPreRouteState }
    }

    func freezeOutputResetPreRouteClock(_ binding: ResetPreRouteTicketBinding) throws -> ResetPreRouteRecoveryDeadlineState? {
        try updateOutputResetPreRouteClock(binding, change: .freeze)
    }

    func resumeOutputResetPreRouteClock(_ binding: ResetPreRouteTicketBinding) throws -> ResetPreRouteRecoveryDeadlineState? {
        try updateOutputResetPreRouteClock(binding, change: .resume)
    }

    func tightenOutputResetPreRouteBoundary(_ binding: ResetPreRouteTicketBinding,
        mandatorySuffix: UInt64) throws -> ResetPreRouteRecoveryDeadlineState? {
        try updateOutputResetPreRouteClock(binding, change: .tighten(mandatorySuffix))
    }

    private enum ResetClockChange { case freeze, resume, tighten(UInt64) }

    private func updateOutputResetPreRouteClock(_ binding: ResetPreRouteTicketBinding,
        change: ResetClockChange) throws -> ResetPreRouteRecoveryDeadlineState? {
        try transaction(operationDescriptor: .resourceOwnership) { output in
            guard var context = authority.outputContext, context.resetPreRouteBinding == binding,
                  context.disposition != .releaseAfterTeardown, !context.poisoned,
                  authority.currentResetRoot == binding.rootIdentity,
                  var state = authority.resetPreRouteState, state.ticketIdentity == binding.ticketIdentity,
                  let parent = context.parentDeadline else { return nil }
            let parentValue: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let value), .outputRecovery(let value): parentValue = value }
            guard parentValue.identity == state.ticketIdentity.parentOperationTicketIdentity else { return nil }
            let instant = monotonicClock.nowNanoseconds
            guard let elapsed = state.effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
            if elapsed >= state.boundaryEffectiveElapsed {
                try timeoutResetPreRouteLocked(context: &context, state: &state, elapsed: elapsed, instant: instant, output: &output)
                return nil
            }
            switch change {
            case .freeze:
                guard state.runningSince != nil else { return state }
                state.accumulatedEffectiveTime = elapsed
                state.runningSince = nil
                state.freezeGeneration = try allocator.next(in: .freezeGeneration)
                state.deadlineArm = nil
            case .resume:
                guard state.runningSince == nil else { return state }
                guard !authority.snapshot.interruptionVeto else { return nil }
                state.runningSince = instant
                state.freezeGeneration = try allocator.next(in: .freezeGeneration)
                state.deadlineArm = .init(ticketIdentity: state.ticketIdentity,
                    boundaryEffectiveElapsed: state.boundaryEffectiveElapsed, freezeGeneration: state.freezeGeneration,
                    armNonce: try allocator.next(in: .deadline))
            case .tighten(let requested):
                let suffix = max(state.mandatorySuffix, requested)
                let boundary = min(state.boundaryEffectiveElapsed, suffix < parentValue.cap ? parentValue.cap - suffix : 0)
                state.mandatorySuffix = suffix
                if elapsed >= boundary {
                    state.boundaryEffectiveElapsed = boundary
                    try timeoutResetPreRouteLocked(context: &context, state: &state, elapsed: elapsed, instant: instant, output: &output)
                    return nil
                }
                if boundary == state.boundaryEffectiveElapsed { return state }
                state.boundaryEffectiveElapsed = boundary
                state.accumulatedEffectiveTime = elapsed
                if state.runningSince != nil {
                    state.runningSince = instant
                    state.deadlineArm = .init(ticketIdentity: state.ticketIdentity,
                        boundaryEffectiveElapsed: boundary, freezeGeneration: state.freezeGeneration,
                        armNonce: try allocator.next(in: .deadline))
                }
            }
            settleResetParentClockLocked(state, context: &context)
            authority.outputContext = context
            authority.resetPreRouteState = state
            return state
        }
    }

    /// state与parent使用同一累计坐标；保留原identity/origin/cap，禁止在移交时续杯。
    private func settleResetParentClockLocked(_ state: ResetPreRouteRecoveryDeadlineState,
        context: inout OutputResourceContext) {
        AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).settleResetParentClockLocked(state, context: &context)
    }

    private func expireResetPreRouteLocked(output: inout PlaybackOutputSafetyState) throws -> Bool {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).expireResetPreRouteLocked(output: &output)
    }

    private func timeoutResetPreRouteLocked(context: inout OutputResourceContext,
        state: inout ResetPreRouteRecoveryDeadlineState, elapsed: UInt64, instant: UInt64,
        output: inout PlaybackOutputSafetyState) throws {
        try AudioSessionLockedOperations(authority: authority, allocator: allocator, instant: monotonicClock.nowNanoseconds).timeoutResetPreRouteLocked(context: &context, state: &state, elapsed: elapsed, instant: instant, output: &output)
    }
}
