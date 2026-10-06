// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import ObjectiveC
import VPlayerCore
import os

/// 值包装不分配第二锁；SDK ManagedBuffer 提供稳定地址，不借 Swift stored value 的临时指针。
struct PreparationStorageLock: Sendable {
    private let storage = OSAllocatedUnfairLock<Void>()
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try storage.withLockUnchecked(body)
    }
#if DEBUG
    func inspect(_ role: String, _ body: (String, UnsafeRawPointer, Int) -> Void) {
        // SDK表示只用于诊断，不参与任何生产准入或合法播放判定。
        guard MemoryLayout.size(ofValue: storage) == MemoryLayout<UInt>.size else {
            print("TASK21_OWNER_STORAGE 未验证SDK锁表示 \(role)"); return
        }
        let address = withUnsafeBytes(of: storage) { $0.load(as: UInt.self) }
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              malloc_zone_from_ptr(pointer) != nil, malloc_size(pointer) > 0 else {
            print("TASK21_OWNER_STORAGE 未验证SDK原锁backing \(role)"); return
        }
        body(role, pointer, malloc_size(pointer))
        withExtendedLifetime(storage) {}
    }
#endif
}

#if DEBUG
/// 只支持已知原纯Swift准备对象；6.2公开布局仅作条件依据，实际runtime另记UUID。
func inspectNativePreparationWeakSideTable(_ role: String, _ object: AnyObject,
                                          _ body: (String, UnsafeRawPointer, Int) -> Void) {
    guard object is FrozenPreparationOwner || object is LoopbackAVPlayerPreparationEvidenceSource
        || object is PlayerItemTimelineMappingAuthority || object is SystemAVPlayerDriver
        || object is AVPlayerDriverEventHub || object is AVPlayerItemCoordinator
        || object is AACWriterTerminalBinding else {
        print("TASK21_OWNER_STORAGE weak 未验证：非限定原纯Swift准备类型 \(role)")
        return
    }
#if compiler(>=6.2) && compiler(<6.3) && arch(arm64)
    let pointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
    var result = withExtendedLifetime(object) { VPInspectPreparationWeakSideTable(pointer) }
    let runtime = withUnsafeBytes(of: &result.runtimeUUID) {
        $0.map { String(format: "%02x", $0) }.joined()
    }
    print("TASK21_OWNER_STORAGE weak \(role) 原对象=\(UInt(bitPattern: pointer)) runtimeUUID=\(runtime) status=\(result.status)")
    if result.status == 0, let allocation = UnsafeRawPointer(bitPattern: result.allocation) {
        body("owned/\(role) 原weak侧表", allocation, result.bytes)
    } else if result.status != 1 {
        print("TASK21_OWNER_STORAGE weak 未验证，不能记零：\(role)")
    }
#else
    print("TASK21_OWNER_STORAGE weak 未验证：compiler/arch不在6.2 arm64诊断范围 \(role)")
#endif
}
#endif

enum AVPlayerPlaybackEndBoundary: Sendable {
    case constrained, natural

    func containsFinalClock(_ current: ExactMediaTime, expected: ExactMediaTime, quantum: ExactMediaTime?) -> Bool {
        if case .constrained = self { return CMTimeCompare(current.cmTime, expected.cmTime) >= 0 }
        guard let quantum else { return CMTimeCompare(current.cmTime, expected.cmTime) >= 0 }
        guard quantum.value > 0, CMTimeCompare(quantum.cmTime, expected.cmTime) < 0,
              let lower = try? expected.subtracting(quantum) else { return false }
        // Native presentation recognition only. Strictly inside the final
        // quantum: a complete missing frame at the lower boundary is rejected.
        return CMTimeCompare(current.cmTime, lower.cmTime) > 0 && CMTimeCompare(current.cmTime, expected.cmTime) <= 0
    }

    func observedEndpoint(forwardEnd: CMTime, duration: CMTime) -> ExactMediaTime? {
        let observed: CMTime
        switch self {
        case .constrained: observed = forwardEnd
        case .natural:
            // AVPlayer's invalid/default forward end delegates to item.duration.
            // A later explicit trim cannot reuse this full-source observation.
            guard !forwardEnd.isValid else { return nil }
            observed = duration
        }
        guard let result = try? ExactMediaTime(observed), result.value > 0 else { return nil }
        return result
    }
}

struct AVPlayerNaturalEndObservation: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let expectedEndpoint: ExactMediaTime
    /// Directly observed effective endpoint: explicit trim or native duration.
    let constrainedEndpoint: ExactMediaTime
    let firstCurrentTime: ExactMediaTime
    let stableCurrentTime: ExactMediaTime?
}

enum AVPlayerNaturalEndTerminalFailure: Sendable, Equatable {
    case unstableDirectRead
    case endpointMismatch
    case deadlineCapacityExceeded
    case staleItem
}

enum AVPlayerNaturalEndFailurePredicate: String, Sendable {
    case ingressEndpoint = "ingress.endpoint"
    case ingressNotReady = "ingress.notReady"
    case ingressItemError = "ingress.itemError"
    case ingressQuantum = "ingress.quantum"
    case confirmNotReady = "confirm.notReady"
    case confirmItemError = "confirm.itemError"
    case confirmRate = "confirm.rate"
    case confirmControl = "confirm.control"
    case confirmQuantum = "confirm.quantum"
    case confirmFirstEndpoint = "confirm.firstEndpoint"
    case confirmEffectiveEndpoint = "confirm.effectiveEndpoint"
    case confirmFinalClock = "confirm.finalClock"
    case confirmStableClock = "confirm.stableClock"
    case ingressAuthority = "ingress.authority"
    case ingressDeadlineCapacity = "ingress.deadlineCapacity"
    case ingressRegistryDeadline = "ingress.registryDeadline"
    case refreshBoundary = "refresh.boundary"
    case refreshIdentity = "refresh.identity"
    case refreshQuantum = "refresh.quantum"
    case refreshDuration = "refresh.duration"
    case refreshPendingBinding = "refresh.pendingBinding"
}

#if DEBUG
/// One fixed scalar slot, no SDK/error/source objects or retained event history.
struct AVPlayerNaturalEndFailureDiagnostic: Sendable {
    let predicate: AVPlayerNaturalEndFailurePredicate
    let quantumFailure: NativeHLSQuantumValidationFailure?
    var revision: NativeHLSSelectionRevisionMismatch?
    var binding: NativeHLSQuantumBindingComparison?
    var sdkIdentity: NativeHLSQuantumSDKIdentityComparison?
    var first: ExactMediaTime?
    var stable: ExactMediaTime?
    var expected: ExactMediaTime?
    var effective: ExactMediaTime?
    var quantum: ExactMediaTime?

    var summary: String {
        func time(_ value: ExactMediaTime?) -> String {
            value.map { "\($0.value)/\($0.timescale)" } ?? "none"
        }
        let code = predicate.rawValue + (quantumFailure.map { "." + $0.rawValue } ?? "")
        let revisionDetail = revision.map {
            " r=\($0.expected)/\($0.current) why=\($0.reason.rawValue)" + ($0.exhausted ? " x=1" : "")
        } ?? ""
        let bindingDetail = binding.map { " b=\($0.presence)/\($0.equalFields)/\($0.visualSelections)" } ?? ""
        let sdkDetail = sdkIdentity.map { " i=\($0.equalFields)/\($0.visualSelection.rawValue)" } ?? ""
        let value = "predicate=\(code)\(revisionDetail)\(bindingDetail)\(sdkDetail) f=\(time(first)) s=\(time(stable)) e=\(time(expected)) a=\(time(effective)) q=\(time(quantum))"
        // Scalar values and enum codes are ASCII. Keep the complete diagnosis
        // inside the original coordinator's 384-byte first-failure record.
        return String(value.prefix(288))
    }
}
#endif

enum AVPlayerNaturalEndTerminalResult: Sendable, Equatable {
    case success(AVPlayerNaturalEndObservation)
    case failure(AVPlayerNaturalEndTerminalFailure)
}

/// 为 AVPlayer 的有界等待提供固定容量 deadline。生产实现使用真实时钟；测试只可
/// 控制 deadline 何时触发，不能替换 AVPlayer 的两次 direct read。
protocol AVPlayerWaitDeadlineScheduling: AnyObject, Sendable {
    func schedule(after seconds: TimeInterval,
                  handler: @escaping @Sendable () -> Void) -> UUID?
    func cancel(_ identity: UUID)
}

/// 只能由 SystemAVPlayerDriver 两次 direct read 的终态签发；普通调用方不能构造。
struct AVPlayerNaturalEndTerminalCapability: Sendable {
    fileprivate let issuerIdentity: UUID
    fileprivate let item: AVPlayerItemInstanceIdentity
    fileprivate let observationIdentity: UUID

    fileprivate init(issuerIdentity: UUID, item: AVPlayerItemInstanceIdentity,
                     observationIdentity: UUID) {
        self.issuerIdentity = issuerIdentity
        self.item = item
        self.observationIdentity = observationIdentity
    }
}

/// 单物理driver的原准入世代；值引用不能自行签发或查当前driver补票。
struct AVPlayerDriverAdmission: Sendable {
    fileprivate let generation: UInt64
}

/// 实际交给SDK的callback持有本租约；执行、取消和driver退休均不提前归还。
final class AVPlayerSDKCallbackLease: @unchecked Sendable {
    enum Kind: UInt8, Sendable { case timeControl, accessLog, endpoint, ready, seek, loaded, preroll, errorLog, logFetch, systemAudio, nativeObservation }
    nonisolated(unsafe) private static var occupied: UInt8 = 0
    private let slot: UInt8
    let kind: Kind
    private let admission: AVPlayerDriverAdmission
    private let resourceContextReservation: PlaybackResourceContextReservation
    private let installationResourceContextReservation: PlaybackResourceContextReservation?
    private let creditPool: AVPlayerSDKCallbackCreditPool?
    private let creditBorrow: AVPlayerSDKCallbackCreditPool.Borrow?

    fileprivate static func claimSlotLocked(admission: AVPlayerDriverAdmission) throws -> UInt8 {
        guard let slot = (UInt8(0)..<8).first(where: { occupied & (1 << $0) == 0 }) else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        try SystemAVPlayerDriver.retainAdmissionLocked(admission)
        occupied |= 1 << slot
        return slot
    }

    fileprivate static func releaseSlotLocked(_ slot: UInt8, admission: AVPlayerDriverAdmission) {
        precondition(occupied & (1 << slot) != 0)
        occupied &= ~(1 << slot)
        SystemAVPlayerDriver.releaseAdmissionLocked(admission)
    }

    fileprivate static func reserve(_ kind: Kind, admission: AVPlayerDriverAdmission,
        installationResourceContextReservation: PlaybackResourceContextReservation?) throws
        -> AVPlayerSDKCallbackLease {
        let resourceReservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: kind == .logFetch ? 4 * 1_024 : 2 * 1_024)
        do {
            let lease = try SystemAVPlayerDriver.creationLock.withLock {
                let slot = try claimSlotLocked(admission: admission)
                return AVPlayerSDKCallbackLease(slot: slot, kind: kind, admission: admission,
                    resourceContextReservation: resourceReservation,
                    installationResourceContextReservation: installationResourceContextReservation)
            }
            try PlaybackResourceContextLedger.shared.rebind(
                resourceReservation, to: .object(ObjectIdentifier(lease)))
            return lease
        } catch {
            PlaybackResourceContextLedger.shared.release(resourceReservation)
            throw error
        }
    }
    fileprivate init(slot: UInt8, kind: Kind, admission: AVPlayerDriverAdmission,
                 resourceContextReservation: PlaybackResourceContextReservation,
                 installationResourceContextReservation: PlaybackResourceContextReservation?,
                 creditPool: AVPlayerSDKCallbackCreditPool? = nil,
                 creditBorrow: AVPlayerSDKCallbackCreditPool.Borrow? = nil) {
        self.slot = slot; self.kind = kind; self.admission = admission
        self.resourceContextReservation = resourceContextReservation
        self.installationResourceContextReservation = installationResourceContextReservation
        self.creditPool = creditPool
        self.creditBorrow = creditBorrow
    }
    func assertRegistered() {
        SystemAVPlayerDriver.creationLock.withLock {
            precondition(Self.occupied & (1 << slot) != 0, "SDK callback 的原物理租约不可提前释放")
            precondition(SystemAVPlayerDriver.isAdmissionActiveLocked(admission))
            if let creditPool, let creditBorrow { creditPool.assertBorrowedLocked(creditBorrow, slot: slot) }
        }
    }
    deinit {
        if let creditPool, let creditBorrow {
            creditPool.returnFromPhysicalDeinit(creditBorrow, slot: slot,
                reservation: resourceContextReservation)
        } else {
            SystemAVPlayerDriver.creationLock.withLock {
                Self.releaseSlotLocked(slot, admission: admission)
            }
            PlaybackResourceContextLedger.shared.release(resourceContextReservation)
        }
    }
#if DEBUG
    nonisolated(unsafe) private static var diagnostics = false
    static func setDiagnosticsEnabled(_ enabled: Bool) {
        SystemAVPlayerDriver.creationLock.withLock { diagnostics = enabled }
    }
    func inspectRegistration() {
        guard SystemAVPlayerDriver.creationLock.withLock({ Self.diagnostics }) else { return }
        inspectAllocations { role, pointer, bytes in
            print("TASK21_OWNER_STORAGE \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
        }
    }
    static var occupiedCount: Int {
        SystemAVPlayerDriver.creationLock.withLock { occupied.nonzeroBitCount }
    }
    func inspectAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        body("owned/实际SDK callback lease kind=\(kind.rawValue)", pointer, malloc_size(pointer))
    }
#else
    @inline(__always) func inspectRegistration() {}
#endif
}

/// Prepaid callback capacity for one original driver/item. This object contains
/// no task, timer, native callback or proof. One inline continuation can wait
/// for a physical credit return. Its caller retains it through registered
/// cleanup; closing it is not quiescence evidence.
final class AVPlayerSDKCallbackCreditPool: @unchecked Sendable {
    struct AllocationBreakdown: Sendable {
        let poolBytes: Int
        let contextReservationBytes: Int
        let applicationReservationBytes: Int
        let totalBytes: Int
    }

    fileprivate enum Role: UInt8, Sendable { case operation, rollback, observer }
    fileprivate struct Borrow: Sendable {
        let role: Role
        let generation: UInt64
    }
    private struct Credit {
        let slot: UInt8
        var reservation: PlaybackResourceContextReservation?
        var generation: UInt64 = 0
        var borrowed = false
        static var absent: Self { .init(slot: 8, reservation: nil) }
    }

    fileprivate let admission: AVPlayerDriverAdmission
    fileprivate let itemIdentity: AVPlayerItemInstanceIdentity?
    fileprivate let itemObjectIdentity: ObjectIdentifier?
    private let resourceContextReservation: PlaybackResourceContextReservation
    private var installationResourceContextReservation: PlaybackResourceContextReservation?
    // All mutable fields are protected by the existing driver creation lock.
    private var operation: Credit
    private var rollback: Credit
    private var observer: Credit
    private var cancelled = false
    private var closed = false
    private var rollbackProtected = false
    private var operationReturnWaiter: (UUID, CheckedContinuation<Void, any Error>)?
    var hasOperationReturnWaiter: Bool {
        SystemAVPlayerDriver.creationLock.withLock { operationReturnWaiter != nil }
    }

    /// A completed SDK operation may still retain its callback. Reuse the one
    /// prepaid operation credit only after that exact physical alias releases.
    func waitForOperationReturn() async throws {
        let identity = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = SystemAVPlayerDriver.creationLock.withLock {
                    guard !Task.isCancelled else { return .failure(CancellationError()) }
                    guard !closed, !cancelled else {
                        return .failure(AVPlayerItemCoordinatorFailure.staleIdentity)
                    }
                    if !operation.borrowed { return .success(()) }
                    guard operationReturnWaiter == nil else {
                        return .failure(AVPlayerItemCoordinatorFailure.operationInFlight)
                    }
                    operationReturnWaiter = (identity, continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = SystemAVPlayerDriver.creationLock.withLock {
                () -> CheckedContinuation<Void, any Error>? in
                guard self.operationReturnWaiter?.0 == identity else { return nil }
                defer { self.operationReturnWaiter = nil }
                return self.operationReturnWaiter?.1
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    static func allocationBreakdown() throws -> AllocationBreakdown {
        let pool = malloc_good_size(class_getInstanceSize(Self.self))
        let context = malloc_good_size(class_getInstanceSize(PlaybackResourceContextReservation.self))
        let application = malloc_good_size(class_getInstanceSize(PlaybackApplicationChargeReservation.self))
        return .init(poolBytes: pool, contextReservationBytes: context,
            applicationReservationBytes: application,
            totalBytes: try HLSChecked.add(try HLSChecked.add(pool, context), application))
    }

    fileprivate static func reserve(admission: AVPlayerDriverAdmission,
        itemIdentity: AVPlayerItemInstanceIdentity?, itemObjectIdentity: ObjectIdentifier?,
        includingObserver: Bool,
        installationResourceContextReservation: PlaybackResourceContextReservation?) throws -> Self {
        let layout = try allocationBreakdown()
        let pool = try SystemAVPlayerDriver.creationLock.withLock {
            guard SystemAVPlayerDriver.isAdmissionActiveLocked(admission) else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            let root = try PlaybackResourceContextLedger.shared.reserve(
                allocationIdentity: .stable(UUID()), bytes: layout.totalBytes)
            var operation = Credit.absent
            var rollback = Credit.absent
            var observer = Credit.absent
            var transferred = false
            defer {
                if !transferred {
                    releaseUnusedLocked(&observer, admission: admission)
                    releaseUnusedLocked(&rollback, admission: admission)
                    releaseUnusedLocked(&operation, admission: admission)
                    PlaybackResourceContextLedger.shared.release(root)
                }
            }
            operation = try reserveCreditLocked(admission: admission, layout: layout)
            rollback = try reserveCreditLocked(admission: admission, layout: layout)
            if includingObserver { observer = try reserveCreditLocked(admission: admission, layout: layout) }
            let pool = Self(admission: admission, itemIdentity: itemIdentity,
                itemObjectIdentity: itemObjectIdentity, root: root,
                installationResourceContextReservation: installationResourceContextReservation,
                operation: operation, rollback: rollback, observer: observer)
            transferred = true
            return pool
        }
        // No caller can borrow before all identities and measured roots validate.
        try PlaybackResourceContextLedger.shared.rebind(pool.resourceContextReservation,
            to: .object(ObjectIdentifier(pool)))
        try pool.registerUnusedCreditIdentities()
        guard let actual = pool.allocationUsage(), actual.pool <= layout.poolBytes,
              actual.context <= layout.contextReservationBytes,
              actual.application <= layout.applicationReservationBytes else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        return pool
    }

    private static func reserveCreditLocked(admission: AVPlayerDriverAdmission,
        layout: AllocationBreakdown) throws -> Credit {
        let reservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 2 * 1_024)
        do {
            let leaseBytes = malloc_good_size(class_getInstanceSize(AVPlayerSDKCallbackLease.self))
            let tokenBytes = try HLSChecked.add(layout.contextReservationBytes, layout.applicationReservationBytes)
            guard try HLSChecked.add(leaseBytes, tokenBytes) <= 2 * 1_024,
                  let actual = PlaybackResourceContextLedger.shared.reservationAllocationBytes(for: reservation),
                  actual.context <= layout.contextReservationBytes,
                  actual.application <= layout.applicationReservationBytes else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            let slot = try AVPlayerSDKCallbackLease.claimSlotLocked(admission: admission)
            return .init(slot: slot, reservation: reservation)
        } catch {
            PlaybackResourceContextLedger.shared.release(reservation)
            throw error
        }
    }

    private init(admission: AVPlayerDriverAdmission,
        itemIdentity: AVPlayerItemInstanceIdentity?, itemObjectIdentity: ObjectIdentifier?,
        root: PlaybackResourceContextReservation,
        installationResourceContextReservation: PlaybackResourceContextReservation?,
        operation: Credit, rollback: Credit, observer: Credit) {
        self.admission = admission
        self.itemIdentity = itemIdentity
        self.itemObjectIdentity = itemObjectIdentity
        resourceContextReservation = root
        self.installationResourceContextReservation = installationResourceContextReservation
        self.operation = operation; self.rollback = rollback; self.observer = observer
    }

    private func withCredit<Result>(_ role: Role,
        _ body: (inout Credit) throws -> Result) rethrows -> Result {
        switch role {
        case .operation: return try body(&operation)
        case .rollback: return try body(&rollback)
        case .observer: return try body(&observer)
        }
    }

    private func registerUnusedCreditIdentities() throws {
        try SystemAVPlayerDriver.creationLock.withLock {
            try registerUnusedCreditIdentityLocked(.operation)
            try registerUnusedCreditIdentityLocked(.rollback)
            try registerUnusedCreditIdentityLocked(.observer)
        }
    }

    private func registerUnusedCreditIdentityLocked(_ role: Role) throws {
        try withCredit(role) { credit in
            if let reservation = credit.reservation {
                try PlaybackResourceContextLedger.shared.rebind(reservation,
                    to: .owned(ObjectIdentifier(self), role.rawValue))
            }
        }
    }

    fileprivate func borrowOperation(_ kind: AVPlayerSDKCallbackLease.Kind) throws -> AVPlayerSDKCallbackLease {
        switch kind {
        case .ready, .seek, .loaded, .preroll, .systemAudio: break
        default: throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        return try borrow(.operation, kind: kind)
    }
    fileprivate func borrowObserver() throws -> AVPlayerSDKCallbackLease {
        try borrow(.observer, kind: .timeControl)
    }
    /// This transfers storage only. Returning/dropping this lease never proves
    /// that a native disconnect ran or that registered cleanup accepted ownership.
    fileprivate func borrowRollback() throws -> AVPlayerSDKCallbackLease {
        try borrow(.rollback, kind: .systemAudio)
    }

    private func borrow(_ role: Role, kind: AVPlayerSDKCallbackLease.Kind) throws
        -> AVPlayerSDKCallbackLease {
        let claimed = try SystemAVPlayerDriver.creationLock.withLock {
            guard SystemAVPlayerDriver.isAdmissionActiveLocked(admission),
                  role == .rollback || (!cancelled && !closed) else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            let claim = try withCredit(role) { credit in
                guard !credit.borrowed else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
                guard let reservation = credit.reservation else {
                    throw AVPlayerItemCoordinatorFailure.capacityExceeded
                }
                let next = credit.generation.addingReportingOverflow(1)
                guard !next.overflow else { throw AVPlayerItemCoordinatorFailure.capacityExceeded }
                credit.generation = next.partialValue
                credit.borrowed = true
                credit.reservation = nil
                return (credit.slot, reservation, Borrow(role: role, generation: next.partialValue))
            }
            rollbackProtected = true
            if role == .rollback { cancelled = true }
            return (claim, installationResourceContextReservation)
        }
        let (claim, installation) = claimed
        let lease = AVPlayerSDKCallbackLease(slot: claim.0, kind: kind, admission: admission,
            resourceContextReservation: claim.1,
            installationResourceContextReservation: installation,
            creditPool: self, creditBorrow: claim.2)
        guard Self.actualBytes(of: lease)
            <= malloc_good_size(class_getInstanceSize(AVPlayerSDKCallbackLease.self)) else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        try PlaybackResourceContextLedger.shared.rebind(claim.1,
            to: .object(ObjectIdentifier(lease)))
        return lease
    }

    private func takeOperationReturnWaiterLocked() -> CheckedContinuation<Void, any Error>? {
        defer { operationReturnWaiter = nil }
        return operationReturnWaiter?.1
    }

    func cancel() {
        let waiter = SystemAVPlayerDriver.creationLock.withLock {
            cancelled = true
            return takeOperationReturnWaiterLocked()
        }
        waiter?.resume(throwing: CancellationError())
    }

    /// Never-started admission can release everything. Once any borrower was
    /// admitted, only an original-driver native readback can release rollback.
    func close() {
        let waiter = SystemAVPlayerDriver.creationLock.withLock {
            closed = true; cancelled = true
            Self.releaseUnusedLocked(&operation, admission: admission)
            Self.releaseUnusedLocked(&observer, admission: admission)
            if !rollbackProtected {
                Self.releaseUnusedLocked(&rollback, admission: admission)
                installationResourceContextReservation = nil
            }
            return takeOperationReturnWaiterLocked()
        }
        waiter?.resume(throwing: CancellationError())
    }

    fileprivate func resolveUnusedRollbackAfterDriverReadback() -> Bool {
        SystemAVPlayerDriver.creationLock.withLock {
            guard closed, rollbackProtected, !operation.borrowed, !rollback.borrowed,
                  rollback.reservation != nil,
                  SystemAVPlayerDriver.isAdmissionActiveLocked(admission) else { return false }
            rollbackProtected = false
            Self.releaseUnusedLocked(&rollback, admission: admission)
            installationResourceContextReservation = nil
            return true
        }
    }

    fileprivate func assertBorrowedLocked(_ borrow: Borrow, slot: UInt8) {
        withCredit(borrow.role) { credit in
            precondition(credit.slot == slot && credit.borrowed
                && credit.generation == borrow.generation && credit.reservation == nil,
                "Only the exact outstanding physical callback owns this prepaid credit")
        }
    }

    fileprivate func returnFromPhysicalDeinit(_ borrow: Borrow, slot: UInt8,
        reservation: PlaybackResourceContextReservation) {
        let waiter = SystemAVPlayerDriver.creationLock.withLock {
            () -> CheckedContinuation<Void, any Error>? in
            assertBorrowedLocked(borrow, slot: slot)
            let keepReserved = !closed || (borrow.role == .rollback && rollbackProtected)
            withCredit(borrow.role) { credit in
                credit.borrowed = false
                if keepReserved {
                    do {
                        try PlaybackResourceContextLedger.shared.rebind(reservation,
                            to: .owned(ObjectIdentifier(self), borrow.role.rawValue))
                    } catch { preconditionFailure("The original exclusive callback reservation must rebind: \(error)") }
                    credit.reservation = reservation
                } else {
                    AVPlayerSDKCallbackLease.releaseSlotLocked(slot, admission: admission)
                    PlaybackResourceContextLedger.shared.release(reservation)
                }
            }
            guard borrow.role == .operation else { return nil }
            defer { operationReturnWaiter = nil }
            return operationReturnWaiter?.1
        }
        waiter?.resume()
    }

    private static func releaseUnusedLocked(_ credit: inout Credit, admission: AVPlayerDriverAdmission) {
        guard !credit.borrowed, let reservation = credit.reservation else { return }
        credit.reservation = nil
        AVPlayerSDKCallbackLease.releaseSlotLocked(credit.slot, admission: admission)
        PlaybackResourceContextLedger.shared.release(reservation)
    }

    deinit {
        // Every outstanding borrower retains this pool. The registered caller is
        // responsible for retaining its own pool reference until cleanup resolves.
        SystemAVPlayerDriver.creationLock.withLock {
            precondition(!operation.borrowed && !rollback.borrowed && !observer.borrowed)
            Self.releaseUnusedLocked(&operation, admission: admission)
            Self.releaseUnusedLocked(&rollback, admission: admission)
            Self.releaseUnusedLocked(&observer, admission: admission)
        }
        PlaybackResourceContextLedger.shared.release(resourceContextReservation)
    }

    private static func actualBytes(of object: AnyObject) -> Int {
        malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque()))
    }
    /// Sizes of this exact live registration, including its real application
    /// token. Estimated allocator classes are never reported as measured bytes.
    func allocationUsage() -> (pool: Int, context: Int, application: Int)? {
        guard let tokens = PlaybackResourceContextLedger.shared.reservationAllocationBytes(
            for: resourceContextReservation) else { return nil }
        return (Self.actualBytes(of: self), tokens.context, tokens.application)
    }
#if DEBUG
    func inspectAllocations(_ body: (String, UnsafeRawPointer, Int, Int) -> Void) {
        guard let layout = try? Self.allocationBreakdown() else { return }
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        body("owned/callback credit pool", pointer, malloc_size(pointer), layout.poolBytes)
        let token = UnsafeRawPointer(Unmanaged.passUnretained(resourceContextReservation).toOpaque())
        body("owned/callback pool context reservation", token, malloc_size(token), layout.contextReservationBytes)
    }
#endif
}

@MainActor
final class SystemAVPlayerDriver: AVPlayerDriving, PlaybackNaturalEndDeadlineReceiving {
#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        func object(_ role: String, _ value: AnyObject) {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque())
            body(role, pointer, malloc_size(pointer))
        }
        object("HLS/原 SystemAVPlayerDriver 壳", self)
        logSnapshotCache.inspectPreparationAllocations(body)
        object("owned/async AVPlayer log reader", logReader)
        inspectNativePreparationWeakSideTable("driver", self, body)
        Self.creationLock.inspect("owned/单 driver 准入锁", body)
        eventHub.inspectPreparationAllocations(body)
        prepareWait.inspectPreparationAllocations(body)
        if let timeControlObservation { object("owned/公开 timeControl KVO wrapper", timeControlObservation) }
        if let accessLogObserver { object("owned/公开 accessLog notification wrapper", accessLogObserver) }
        if let errorLogObserver { object("owned/公开 errorLog notification wrapper", errorLogObserver) }
        if let endpointObserver { object("owned/公开 endpoint notification wrapper", endpointObserver) }
    }
#endif
    nonisolated fileprivate static let creationLock = PreparationStorageLock()
    nonisolated(unsafe) private static var admissionGeneration: UInt64 = 0
    nonisolated(unsafe) private static var admissionReferences: UInt16 = 0
    nonisolated(unsafe) private static var nativeTailWaiter: (UInt64, CheckedContinuation<Void, Never>)?

    nonisolated fileprivate static func isAdmissionActiveLocked(_ admission: AVPlayerDriverAdmission) -> Bool {
        admissionReferences > 0 && admissionGeneration == admission.generation
    }
    nonisolated fileprivate static func retainAdmissionLocked(_ admission: AVPlayerDriverAdmission) throws {
        let next = admissionReferences.addingReportingOverflow(1)
        guard isAdmissionActiveLocked(admission), !next.overflow else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        admissionReferences = next.partialValue
    }
    nonisolated fileprivate static func releaseAdmissionLocked(_ admission: AVPlayerDriverAdmission) {
        precondition(isAdmissionActiveLocked(admission), "只能归还准确原driver准入引用，不能下溢或消费后继世代")
        admissionReferences -= 1
        // Driver + hub are the two canonical owners. Every additional reference
        // is an original SDK callback/credit whose physical tail must retire.
        if admissionReferences == 2, let waiter = nativeTailWaiter, waiter.0 == admission.generation {
            nativeTailWaiter = nil
            waiter.1.resume()
        }
    }

    static func make(
        player: AVPlayer? = nil,
        deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)? = nil,
        logReader: (any AVPlayerLogReading)? = nil,
        preferredForwardBufferDuration: TimeInterval = 3
    ) throws -> SystemAVPlayerDriver {
        // Existing core 8 KiB plus a fixed 4 KiB envelope for scalar cache/lock,
        // notification wake and connection-state bookkeeping. The physical log
        // reader separately retains a 4 KiB callback lease until SDK completion.
        let resourceReservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 12 * 1_024)
        var resourceTransferred = false
        defer {
            if !resourceTransferred {
                PlaybackResourceContextLedger.shared.release(resourceReservation)
            }
        }
        let admission = try creationLock.withLock {
            let next = admissionGeneration.addingReportingOverflow(1)
            guard admissionReferences == 0, !next.overflow else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            admissionGeneration = next.partialValue
            admissionReferences = 1
            return AVPlayerDriverAdmission(generation: next.partialValue)
        }
        var transferred = false
        defer {
            if !transferred { creationLock.withLock { releaseAdmissionLocked(admission) } }
        }
        guard player?.currentItem == nil else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        let driver = try SystemAVPlayerDriver(player: player ?? AVPlayer(),
            deadlineScheduler: deadlineScheduler, admission: admission,
            preferredForwardBufferDuration: preferredForwardBufferDuration,
            resourceContextReservation: resourceReservation,
            logReader: logReader ?? SystemAVPlayerLogReader())
        transferred = true
        try PlaybackResourceContextLedger.shared.rebind(
            resourceReservation, to: .object(ObjectIdentifier(driver)))
        resourceTransferred = true
        return driver
    }
    let player: AVPlayer
    let preferredForwardBufferDuration: TimeInterval
    private var item: AVPlayerItem?
    private(set) var currentItemIdentity: AVPlayerItemInstanceIdentity?
    let prepareWait = AVPlayerPrepareWaitSlot()
    private let deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)?
    private var naturalEndAuthority: ControlTaskRegistry.BackendPositiveRateInvocation?
    let eventHub: AVPlayerDriverEventHub
    private let resourceContextReservation: PlaybackResourceContextReservation
    private var installationResourceContextReservation: PlaybackResourceContextReservation?
    private var timeControlObservation: NSKeyValueObservation?
    nonisolated let logSnapshotCache: AVPlayerLogSnapshotCache
    private var accessLogObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var logRefreshTask: Task<Void, Never>?
    private var nativeTailJoinTask: Task<Void, Never>?
    private let logReader: any AVPlayerLogReading
    private var systemAudioTransitionInFlight = false
    private var pausedResumeCallbackPool: AVPlayerSDKCallbackCreditPool?
    private var endpointObserver: NSObjectProtocol?
    private var endpointStabilityDeadline: UUID?
    private var endpointObservationIdentity: UUID?
    private(set) var naturalEndObservation: AVPlayerNaturalEndObservation?
    private var endpointBoundary = AVPlayerPlaybackEndBoundary.constrained
    private var nativeEndQuantum: NativeHLSFinalPresentationQuantum?
    private var nativeEndQuantumWindow = NativeHLSQuantumWindow()
    nonisolated let nativeSelectionRevision = NativeHLSSelectionRevision()
    private(set) var naturalEndTerminalResult: AVPlayerNaturalEndTerminalResult?
    #if DEBUG
    private(set) var naturalEndFailureDiagnosticForTesting: AVPlayerNaturalEndFailureDiagnostic?
    private(set) var naturalEndQuantumUpdateFailureDiagnosticForTesting: AVPlayerNaturalEndFailureDiagnostic?
    #endif
    private let naturalEndIssuerIdentity = UUID()
    private var naturalEndTerminalIssued = false
    private var naturalEndTerminalConsumed = false
    private var naturalEndTerminalHandler: (@MainActor @Sendable (
        AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
    ) -> Void)?

    private init(player: AVPlayer, deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)?,
                 admission: AVPlayerDriverAdmission,
                 preferredForwardBufferDuration: TimeInterval,
                 resourceContextReservation: PlaybackResourceContextReservation,
                 logReader: any AVPlayerLogReading) throws {
        self.player = player
        self.deadlineScheduler = deadlineScheduler
        self.preferredForwardBufferDuration = preferredForwardBufferDuration
        self.resourceContextReservation = resourceContextReservation
        self.logReader = logReader
        let hub = try AVPlayerDriverEventHub.make(
            admission: admission, resourceContextReservation: resourceContextReservation)
        eventHub = hub
        logSnapshotCache = AVPlayerLogSnapshotCache(lifetimeOwner: hub)
    }

    deinit { Self.creationLock.withLock { Self.releaseAdmissionLocked(eventHub.admission) } }

    func reserveSDKCallbackLease(_ kind: AVPlayerSDKCallbackLease.Kind) throws -> AVPlayerSDKCallbackLease {
        if let pool = pausedResumeCallbackPool {
            switch kind {
            case .seek, .loaded, .preroll: return try borrowSDKOperationCredit(kind, from: pool)
            case .timeControl: return try borrowSDKObserverCredit(from: pool)
            default: break
            }
        }
        return try .reserve(kind, admission: eventHub.admission,
            installationResourceContextReservation: installationResourceContextReservation)
    }

    func reservePausedResumeCallbacks(item identity: AVPlayerItemInstanceIdentity) throws {
        guard pausedResumeCallbackPool == nil, pausedItemObjectIdentity(item: identity) != nil,
              disconnectedFromSystemAudio else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        pausedResumeCallbackPool = try reserveSDKCallbackCredits(includingObserver: true)
    }

    func finishPausedResumeCallbacks(item identity: AVPlayerItemInstanceIdentity) {
        guard let pool = pausedResumeCallbackPool, pool.itemIdentity == identity else { return }
        pool.close()
        // After play, the driver keeps prepaid rollback until the original
        // physical disconnect. Callback aliases retain their exact pool too.
        if ownsCurrentCallbackCreditPool(pool), !systemAudioTransitionInFlight,
           player.disconnectedFromSystemAudio, player.rate == 0, player.timeControlStatus == .paused {
            _ = releaseUnusedSDKRollbackCreditIfDisconnected(pool)
            pausedResumeCallbackPool = nil
        }
    }

    private func awaitPausedResumeOperationCredit(item identity: AVPlayerItemInstanceIdentity) async throws {
        guard let pool = pausedResumeCallbackPool else { return }
        try Task.checkCancellation()
        try await pool.waitForOperationReturn()
        try Task.checkCancellation()
        guard pool === pausedResumeCallbackPool, pool.itemIdentity == identity,
              ownsCurrentCallbackCreditPool(pool) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
    }

    /// Capacity only: no native method is invoked and no activation is authorized.
    func reserveSDKCallbackCredits(includingObserver: Bool = false) throws -> AVPlayerSDKCallbackCreditPool {
        guard player.currentItem === item else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        return try .reserve(admission: eventHub.admission,
            itemIdentity: currentItemIdentity, itemObjectIdentity: item.map(ObjectIdentifier.init),
            includingObserver: includingObserver,
            installationResourceContextReservation: installationResourceContextReservation)
    }

    private func ownsCurrentCallbackCreditPool(_ pool: AVPlayerSDKCallbackCreditPool) -> Bool {
        pool.admission.generation == eventHub.admission.generation
            && pool.itemIdentity == currentItemIdentity
            && pool.itemObjectIdentity == item.map(ObjectIdentifier.init)
            && pool.itemObjectIdentity == player.currentItem.map(ObjectIdentifier.init)
    }

    func borrowSDKOperationCredit(_ kind: AVPlayerSDKCallbackLease.Kind,
        from pool: AVPlayerSDKCallbackCreditPool) throws -> AVPlayerSDKCallbackLease {
        guard ownsCurrentCallbackCreditPool(pool) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        return try pool.borrowOperation(kind)
    }

    func borrowSDKObserverCredit(from pool: AVPlayerSDKCallbackCreditPool) throws -> AVPlayerSDKCallbackLease {
        guard ownsCurrentCallbackCreditPool(pool) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        return try pool.borrowObserver()
    }

    func borrowSDKRollbackCredit(from pool: AVPlayerSDKCallbackCreditPool) throws -> AVPlayerSDKCallbackLease {
        guard ownsCurrentCallbackCreditPool(pool) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        return try pool.borrowRollback()
    }

    /// Only the original driver can retire unused rollback capacity. This is a
    /// direct state check, not a stop receipt or authorization to resume playback.
    func releaseUnusedSDKRollbackCreditIfDisconnected(_ pool: AVPlayerSDKCallbackCreditPool) -> Bool {
        guard ownsCurrentCallbackCreditPool(pool),
              !systemAudioTransitionInFlight, player.disconnectedFromSystemAudio,
              player.rate == 0, player.timeControlStatus == .paused else { return false }
        return pool.resolveUnusedRollbackAfterDriverReadback()
    }

    func retainInstallationResourceContext(_ reservation: PlaybackResourceContextReservation) {
        installationResourceContextReservation = reservation
        eventHub.retainInstallationResourceContext(reservation)
    }

    var disconnectedFromSystemAudio: Bool {
        !systemAudioTransitionInFlight && player.disconnectedFromSystemAudio
    }

    /// Cancellation cannot complete this physical transition early. The signed
    /// prepare/activation/stop runner keeps ownership until AVFoundation calls back.
    func setDisconnectedFromSystemAudio(_ disconnected: Bool,
        item identity: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) {
        guard currentItemIdentity == identity, let item, player.currentItem === item else {
            throw .staleIdentity
        }
        guard !systemAudioTransitionInFlight else { throw .operationInFlight }
        // A settled matching state needs no new SDK transition or callback
        // lease. Do not use the public disconnected projection for this check:
        // it is also false while a physical transition is still in flight.
        // Callers retain cancellation/authority checks around this operation;
        // cleanup must still be able to settle audio after cancellation.
        guard player.disconnectedFromSystemAudio != disconnected else {
            if disconnected { finishPausedResumeCallbacks(item: identity) }
            return
        }
        let lease: AVPlayerSDKCallbackLease
        do {
            if let pool = pausedResumeCallbackPool {
                lease = try disconnected ? borrowSDKRollbackCredit(from: pool)
                    : borrowSDKOperationCredit(.systemAudio, from: pool)
            } else { lease = try reserveSDKCallbackLease(.systemAudio) }
        }
        catch {
#if DEBUG
            print("NATIVE_ADMISSION system-audio-reserve-failed error=\(error) contextBytes=\(PlaybackResourceContextLedger.shared.chargedBytes) callbackCount=\(AVPlayerSDKCallbackLease.occupiedCount)")
#endif
            throw .capacityExceeded
        }
        lease.inspectRegistration()
        systemAudioTransitionInFlight = true
        defer { systemAudioTransitionInFlight = false }
        await withCheckedContinuation { continuation in
            player.setDisconnectedFromSystemAudio(disconnected) {
                lease.assertRegistered()
                continuation.resume()
            }
        }
        guard currentItemIdentity == identity, self.item === item,
              player.currentItem === item else { throw .staleIdentity }
        guard player.disconnectedFromSystemAudio == disconnected else {
            throw .systemAudioConnectionNotConfirmed
        }
        if disconnected {
            systemAudioTransitionInFlight = false
            finishPausedResumeCallbacks(item: identity)
        }
    }

    var rate: Float { player.rate }
    var timeControlStatus: AVPlayer.TimeControlStatus { player.timeControlStatus }

    func playbackTime(item identity: AVPlayerItemInstanceIdentity) -> ExactMediaTime? {
        guard case .currentItem(let time) = playbackClockObservation(item: identity) else { return nil }
        return time
    }

    func playbackClockObservation(item identity: AVPlayerItemInstanceIdentity) -> AVPlayerPlaybackClockObservation {
        guard currentItemIdentity == identity, let item, player.currentItem === item else { return .staleItem }
        return .currentItem(try? ExactMediaTime(player.currentTime()))
    }
    var activeWaiterCount: Int {
        (prepareWait.isActive ? 1 : 0)
            + (pausedResumeCallbackPool?.hasOperationReturnWaiter == true ? 1 : 0)
    }
    var fixedTimerCount: Int { 0 }

    func nativeCurrentItem(_ identity: AVPlayerItemInstanceIdentity) -> AVPlayerItem? {
        guard currentItemIdentity == identity, let item, player.currentItem === item else { return nil }
        return item
    }

    func joinNativeCallbackTails() async {
        if let nativeTailJoinTask { await nativeTailJoinTask.value; return }
        let task = Task { [self] in
            let logs = logRefreshTask
            logs?.cancel()
            await logs?.value
            await withCheckedContinuation { continuation in
                let ready = Self.creationLock.withLock { () -> Bool in
                    precondition(Self.isAdmissionActiveLocked(eventHub.admission))
                    if Self.admissionReferences == 2 { return true }
                    precondition(Self.nativeTailWaiter == nil)
                    Self.nativeTailWaiter = (eventHub.admission.generation, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
        nativeTailJoinTask = task
        await task.value
        nativeTailJoinTask = nil
    }

    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws {
        try install(url: url, identity: identity, admission: { operation in operation(); return true })
    }

    func install(url: URL, identity: AVPlayerItemInstanceIdentity, admission: AVPlayerInstallationMutation) throws {
        guard !systemAudioTransitionInFlight else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        // These can deliver/cancel callbacks and must precede the Registry lock.
        cancelAllWaiters()
        installationResourceContextReservation = nil
        eventHub.releaseInstallationResourceContext()
        player.pause()
        player.automaticallyWaitsToMinimizeStalling = true
        let installed = AVPlayerItem(url: url)
        installed.preferredForwardBufferDuration = AVPlayerStartupBufferPolicy.selectionBufferSeconds(configured: preferredForwardBufferDuration)
        installed.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        // No app observer is installed on the new item yet. Only the exact SDK
        // mutation and driver identity CAS run under the original prepare fence.
        guard try admission({
            player.replaceCurrentItem(with: installed)
            item = installed
            currentItemIdentity = identity
        }) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        eventHub.activate(identity)
        logSnapshotCache.activate(item: identity, objectIdentity: ObjectIdentifier(installed))
    }

    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item identity: AVPlayerItemInstanceIdentity) {
        precondition(currentItemIdentity == identity,
                     "prepare fence 必须属于当前 System AVPlayer item")
        if fence == .seek {
            // Coordinator reaches this only after authenticating the selection.
            // Keep the configured latency/coverage policy; the larger value merely
            // bootstraps paused network fetching and never counts as HTTP evidence.
            item?.preferredForwardBufferDuration = preferredForwardBufferDuration
        }
    }

    func waitUntilReady(item identity: AVPlayerItemInstanceIdentity) async throws
        -> AVPlayerItemInstanceIdentity {
        guard currentItemIdentity == identity, let item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if item.status == .readyToPlay { return identity }
        let callbackLease = try reserveSDKCallbackLease(.ready)
        let gate = prepareWait
        let token = try gate.begin(.ready)
        defer { gate.retire(token) }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                let callback: @Sendable (AVPlayerItem, NSKeyValueObservedChange<AVPlayerItem.Status>) -> Void = { observed, _ in
                    callbackLease.assertRegistered()
                    switch observed.status {
                    case .readyToPlay: gate.resolve(.success(true), token: token)
                    case .failed:
                        let failure: any Error
                        if let error = observed.error { failure = PlaybackErrorDiagnostics.snapshot(error) }
                        else { failure = AVPlayerItemCoordinatorFailure.itemFailed }
                        gate.resolve(.failure(failure), token: token)
                    default: break
                    }
                }
                callbackLease.inspectRegistration()
                let observation = item.observe(\.status, options: [.initial, .new], changeHandler: callback)
                gate.retain(observation, token: token)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()), token: token)
        }
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return identity
    }

    func selectAudibleMedia(item identity: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == identity, let item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        guard let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
              let option = group.defaultOption ?? group.options.first else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        guard currentItemIdentity == identity, self.item === item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        item.select(option, in: group)
    }

    func seek(to time: ExactMediaTime, item identity: AVPlayerItemInstanceIdentity,
              playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt {
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try await awaitPausedResumeOperationCredit(item: identity)
        let callbackLease = try reserveSDKCallbackLease(.seek)
        let gate = prepareWait
        let token = try gate.begin(.seek)
        defer { gate.retire(token) }
        let succeeded = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                let callback: @Sendable (Bool) -> Void = {
                    callbackLease.assertRegistered()
                    gate.resolve(.success($0), token: token)
                }
                callbackLease.inspectRegistration()
                player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero,
                            completionHandler: callback)
            }
        } onCancel: { gate.resolve(.failure(CancellationError()), token: token) }
        guard succeeded, currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return AVPlayerSeekReceipt(item: identity, playhead: playhead,
                                   actualTime: try ExactMediaTime(player.currentTime()))
    }

    func seekNative(to time: ExactMediaTime, item identity: AVPlayerItemInstanceIdentity) async throws -> ExactMediaTime {
        guard currentItemIdentity == identity else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        try await awaitPausedResumeOperationCredit(item: identity)
        let callbackLease = try reserveSDKCallbackLease(.seek)
        let gate = prepareWait
        let token = try gate.begin(.seek)
        defer { gate.retire(token) }
        let succeeded = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { success in
                    callbackLease.assertRegistered(); gate.resolve(.success(success), token: token)
                }
            }
        } onCancel: { gate.resolve(.failure(CancellationError()), token: token) }
        guard succeeded, nativeCurrentItem(identity) != nil else { throw AVPlayerItemCoordinatorFailure.seekMismatch }
        return try ExactMediaTime(player.currentTime())
    }

    func waitForLoadedTimeRanges(item identity: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: ExactMediaInterval) async throws
        -> AVPlayerLoadedRangeReceipt {
        guard currentItemIdentity == identity, let item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try Task.checkCancellation()
        if try Self.hasLoadedCoverage(item, requested: requested) {
            return .init(item: identity, playhead: playhead, requested: requested)
        }
        try await awaitPausedResumeOperationCredit(item: identity)
        let callbackLease = try reserveSDKCallbackLease(.loaded)
        let gate = prepareWait
        let token = try gate.begin(.loaded)
        defer { gate.retire(token) }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                // 不请求 KVO newValue，避免通知载荷把 NSArray 桥接成 Swift Array。
                let callback: @Sendable (AVPlayerItem, NSKeyValueObservedChange<[NSValue]>) -> Void = {
                    observed, _ in
                    callbackLease.assertRegistered()
                    do {
                        if try Self.hasLoadedCoverage(observed, requested: requested) {
                            gate.resolve(.success(true), token: token)
                        }
                    } catch {
                        gate.resolve(.failure(error), token: token)
                    }
                }
                callbackLease.inspectRegistration()
                let observation = item.observe(\.loadedTimeRanges, options: [.initial], changeHandler: callback)
                gate.retain(observation, token: token)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()), token: token)
        }
        guard currentItemIdentity == identity, self.item === item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try Task.checkCancellation()
        guard try Self.hasLoadedCoverage(item, requested: requested) else {
            throw AVPlayerItemCoordinatorFailure.loadedRangeMismatch
        }
        return .init(item: identity, playhead: playhead, requested: requested)
    }

    func primeMediaData(item identity: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try await awaitPausedResumeOperationCredit(item: identity)
        let callbackLease = try reserveSDKCallbackLease(.preroll)
        let gate = prepareWait
        let token = try gate.begin(.preroll)
        defer { gate.retire(token) }
        let succeeded = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                let callback: @Sendable (Bool) -> Void = {
                    callbackLease.assertRegistered()
                    gate.resolve(.success($0), token: token)
                }
                callbackLease.inspectRegistration()
                player.preroll(atRate: 1, completionHandler: callback)
            }
        } onCancel: {
            player.cancelPendingPrerolls()
            gate.resolve(.failure(CancellationError()), token: token)
        }
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.prerollFailed
        }
        guard succeeded else {
            if let error = item?.error { throw PlaybackErrorDiagnostics.snapshot(error) }
            throw AVPlayerItemCoordinatorFailure.prerollFailed
        }
    }

    func preroll(item identity: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt {
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try await awaitPausedResumeOperationCredit(item: identity)
        let callbackLease = try reserveSDKCallbackLease(.preroll)
        let gate = prepareWait
        let token = try gate.begin(.preroll)
        defer { gate.retire(token) }
        let succeeded = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, token: token)
                let callback: @Sendable (Bool) -> Void = {
                    callbackLease.assertRegistered()
                    gate.resolve(.success($0), token: token)
                }
                callbackLease.inspectRegistration()
                player.preroll(atRate: 1, completionHandler: callback)
            }
        } onCancel: {
            player.cancelPendingPrerolls()
            gate.resolve(.failure(CancellationError()), token: token)
        }
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if !succeeded, let error = item?.error { throw PlaybackErrorDiagnostics.snapshot(error) }
        return AVPlayerPrerollReceipt(item: identity, playhead: playhead, succeeded: succeeded)
    }

    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item identity: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == identity, !systemAudioTransitionInFlight,
              !player.disconnectedFromSystemAudio,
              let snapshot = invocation.currentSnapshot,
              snapshot.interval.outputLifecycle == identity.outputLifecycleEpoch,
              snapshot.interval.itemGeneration == identity.itemGeneration else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        // Classification and this native admission run on MainActor. Inspect the
        // current pending scalar without holding the hub lock across AVPlayer.
        if let failure = eventHub.pendingAccessFailure(item: identity) { throw failure }
        guard invocation.performPositiveRateSideEffect({ player.play() }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        naturalEndAuthority = invocation
    }

    func installTimeControlStatusRelay(
        item identity: AVPlayerItemInstanceIdentity,
        activation: ActivationEpoch,
        handler: @escaping @MainActor @Sendable (
            AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
        ) -> Void
    ) throws {
        guard currentItemIdentity == identity, timeControlObservation == nil else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let callbackLease = try reserveSDKCallbackLease(.timeControl)
        let hub = eventHub
        hub.installTimeControl(activation: activation, handler: handler)
        let callback: @Sendable (AVPlayer, NSKeyValueObservedChange<AVPlayer.TimeControlStatus>) -> Void = {
            [weak hub] observed, _ in
            callbackLease.assertRegistered()
            hub?.receive(observed.timeControlStatus, item: identity, activation: activation)
        }
        callbackLease.inspectRegistration()
        timeControlObservation = player.observe(\.timeControlStatus,
            options: [.initial, .new], changeHandler: callback)
    }

    func installAccessLogURIObservation(
        item identity: AVPlayerItemInstanceIdentity,
        classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
        handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    ) throws {
        guard currentItemIdentity == identity, let item,
              accessLogObserver == nil, errorLogObserver == nil else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        // Reserve both observers before installation so a capacity failure cannot
        // leave an untracked observer or an unbudgeted callback behind.
        let accessLease = try reserveSDKCallbackLease(.accessLog)
        let errorLease = try reserveSDKCallbackLease(.errorLog)
        accessLease.inspectRegistration()
        errorLease.inspectRegistration()
        let cache = logSnapshotCache
        let objectIdentity = ObjectIdentifier(item)
        eventHub.installAccessLog(classify: classify, handler: handler)
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification, object: item, queue: nil
        ) { _ in
            accessLease.assertRegistered()
            cache.requestRefresh(item: identity, objectIdentity: objectIdentity)
        }
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: nil
        ) { _ in
            errorLease.assertRegistered()
            cache.requestRefresh(item: identity, objectIdentity: objectIdentity)
        }
        // activate() already marked an initial read pending. Installing the wake
        // now starts it even when no log notification was emitted after observation.
        cache.installWake { [weak self] in self?.startLogRefresh() }
    }

    private func startLogRefresh() {
        guard logRefreshTask == nil else { return }
        let lease: AVPlayerSDKCallbackLease
        do { lease = try reserveSDKCallbackLease(.logFetch) }
        catch { logSnapshotCache.deferRefresh(); return }
        lease.inspectRegistration()
        logRefreshTask = Task { [self, lease] in
            defer { logRefreshTask = nil }
            while let ticket = logSnapshotCache.beginRefresh() {
                lease.assertRegistered()
                guard let item, currentItemIdentity == ticket.scope.item,
                      ObjectIdentifier(item) == ticket.scope.objectIdentity,
                      player.currentItem === item else {
                    logSnapshotCache.complete(ticket, snapshot: .empty)
                    continue
                }
                let accessCount = await readAccessLog(item, ticket: ticket)
                guard logSnapshotCache.isCurrent(ticket), self.item === item,
                      player.currentItem === item else {
                    logSnapshotCache.complete(ticket, snapshot: .empty)
                    continue
                }
                let errorCount = await logReader.readErrorLogCount(item: item)
                guard self.item === item, player.currentItem === item else {
                    logSnapshotCache.complete(ticket, snapshot: .empty)
                    continue
                }
                logSnapshotCache.complete(ticket, snapshot: .init(
                    accessEventCount: accessCount, errorEventCount: errorCount))
            }
        }
    }

    /// Reduce the complete fetched batch into one scalar. The visitor runs after
    /// the SDK await and validates the original ticket before any classification.
    /// A benign tail cannot erase a fault. Queue a known fault immediately so it
    /// fences native admission before delivery and never waits for another SDK read.
    private func readAccessLog(_ item: AVPlayerItem,
                               ticket: AVPlayerLogSnapshotCache.Ticket) async -> Int {
        var reduced: AccessLogURIClassification?
        var faultEnqueued = false
        let count = await logReader.readAccessLog(item: item) { [self] rawURI in
            guard logSnapshotCache.isCurrent(ticket), self.item === item,
                  player.currentItem === item, let url = URL(string: rawURI),
                  let classification = eventHub.classify(url, item: ticket.scope.item) else { return }
            reduced = reduced?.coalescing(classification) ?? classification
            if classification.isTerminalFault {
                // The reader visits its complete batch synchronously on MainActor.
                // One coalesced wake therefore sees the full fault priority.
                eventHub.receive(classification, item: ticket.scope.item)
                faultEnqueued = true
            }
        }
        guard logSnapshotCache.isCurrent(ticket), self.item === item,
              player.currentItem === item else { return 0 }
        // The queued handler may have consumed the fault while this async call
        // returned. Never emit that same batch again after its first delivery.
        if !faultEnqueued, let reduced { eventHub.receive(reduced, item: ticket.scope.item) }
        return count
    }

    func cancelPendingPrerolls(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity else { return }
        player.cancelPendingPrerolls()
        prepareWait.cancelCurrent()
    }

    func pause(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity else { return }
        // A retained prepared item can resume under a new activation. Retire the
        // old activation-specific KVO while its late callbacks keep their own
        // leases and are rejected by the hub's cleared activation identity.
        eventHub.cancelTimeControl()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        cancelNaturalEndDeadline()
        naturalEndAuthority = nil
        player.pause()
    }

    func waitUntilPaused(item identity: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == identity, let item, player.currentItem === item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        // AVPlayer.pause 同步令 rate=0/timeControlStatus=paused；证明仍由直接读取签发。
        // 不为 suspend 增设 KVO、continuation 或另一个可续杯的 deadline。
        guard player.rate == 0, player.timeControlStatus == .paused else {
            throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
        }
    }

    func directState(item identity: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
        guard currentItemIdentity == identity, let item, player.currentItem === item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        guard !systemAudioTransitionInFlight else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        return AVPlayerDirectState(item: identity, rate: player.rate,
                            timeControlStatus: player.timeControlStatus)
    }

    /// This must be read immediately after the owned pause and before the
    /// asynchronous audio disconnect. Invalid metadata cannot fail teardown.
    func pausedTime(item identity: AVPlayerItemInstanceIdentity) -> ExactMediaTime? {
        guard currentItemIdentity == identity, let item, player.currentItem === item,
              !systemAudioTransitionInFlight,
              player.rate == 0, player.timeControlStatus == .paused else { return nil }
        // ExactMediaTime rejects nonnumeric times, nonpositive timescales and
        // nonzero epochs instead of dropping epoch or converting via seconds.
        return try? ExactMediaTime(player.currentTime())
    }

    func pausedItemObjectIdentity(item identity: AVPlayerItemInstanceIdentity) -> ObjectIdentifier? {
        guard currentItemIdentity == identity, let item, player.currentItem === item,
              !systemAudioTransitionInFlight else { return nil }
        return ObjectIdentifier(item)
    }

    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item identity: AVPlayerItemInstanceIdentity) throws {
        try installEndpointObservation(expected: time, item: identity, boundary: .constrained)
    }

    func observeNaturalPlaybackEnd(expected time: ExactMediaTime,
                                   presentationQuantum: NativeHLSFinalPresentationQuantum?,
                                   item identity: AVPlayerItemInstanceIdentity) throws {
        guard currentItemIdentity == identity, let item, player.currentItem === item,
              AVPlayerPlaybackEndBoundary.natural.observedEndpoint(forwardEnd: item.forwardPlaybackEndTime,
                  duration: item.duration) == time,
              presentationQuantum.map({ $0.duration == time && $0.isCurrent(item: identity, physical: item) }) ?? true else {
            throw AVPlayerItemCoordinatorFailure.invalidTimeline
        }
        try installEndpointObservation(expected: time, item: identity, boundary: .natural)
        nativeEndQuantum = presentationQuantum
    }

    func updateNaturalPlaybackEndQuantum(_ quantum: NativeHLSFinalPresentationQuantum?, item identity: AVPlayerItemInstanceIdentity) throws {
        #if DEBUG
        naturalEndQuantumUpdateFailureDiagnosticForTesting = nil
        #endif
        var observedDuration: ExactMediaTime?
        func reject(_ predicate: AVPlayerNaturalEndFailurePredicate,
                    cause: NativeHLSQuantumValidationFailure? = nil,
                    revision: NativeHLSSelectionRevisionMismatch? = nil,
                    binding: NativeHLSQuantumBindingComparison? = nil,
                    sdkIdentity: NativeHLSQuantumSDKIdentityComparison? = nil) -> AVPlayerItemCoordinatorFailure {
            #if DEBUG
            naturalEndQuantumUpdateFailureDiagnosticForTesting = .init(predicate: predicate, quantumFailure: cause, revision: revision, binding: binding, sdkIdentity: sdkIdentity,
                first: naturalEndObservation?.firstCurrentTime, stable: nil,
                expected: quantum?.duration ?? nativeEndQuantum?.duration, effective: observedDuration, quantum: quantum?.period)
            #endif
            return .selectionChanged
        }
        guard case .natural = endpointBoundary else { throw reject(.refreshBoundary) }
        guard currentItemIdentity == identity, let item, player.currentItem === item else { throw reject(.refreshIdentity) }
        // Establish every terminal condition before classifying a stale revision
        // as retryable. A changed binding cannot hide behind simultaneous staleness.
        var currentSDKIdentity: NativeHLSQuantumSDKIdentityComparison?
        if let quantum {
            let validation = quantum.validation(item: identity, physical: item, requiresFreshness: false)
            currentSDKIdentity = validation.sdkIdentity
            if let failure = validation.rejection {
                throw reject(.refreshQuantum, cause: failure.cause, sdkIdentity: failure.sdkIdentity)
            }
            observedDuration = try? ExactMediaTime(item.duration)
            guard observedDuration == quantum.duration else { throw reject(.refreshDuration) }
        }
        var usedWrapperRenewal = false
        if endpointStabilityDeadline != nil {
            let binding = NativeHLSFinalPresentationQuantum.compareBindings(prior: nativeEndQuantum, current: quantum)
            guard binding.matchesPendingWindow else { throw reject(.refreshPendingBinding, binding: binding) }
            guard nativeEndQuantumWindow.permits(quantum?.visualSelection) else {
                throw reject(.refreshQuantum, cause: .visualSelection, binding: binding, sdkIdentity: currentSDKIdentity)
            }
            usedWrapperRenewal = binding.usesWrapperRenewal
        }
        if let mismatch = quantum?.revisionMismatch() {
            let terminal = reject(.refreshQuantum, cause: .revision, revision: mismatch)
            guard !mismatch.exhausted else { throw terminal }
            throw NativeHLSQuantumRevisionSuperseded()
        }
        nativeEndQuantum = quantum
        nativeEndQuantumWindow.recordWrapperRenewal(usedWrapperRenewal)
    }

    private func installEndpointObservation(expected time: ExactMediaTime,
        item identity: AVPlayerItemInstanceIdentity, boundary: AVPlayerPlaybackEndBoundary) throws {
        guard currentItemIdentity == identity, let item,
              player.currentItem === item, time.value > 0 else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let callbackLease = try reserveSDKCallbackLease(.endpoint)
        removeEndpointObserver()
        endpointBoundary = boundary
        if case .constrained = boundary { item.forwardPlaybackEndTime = time.cmTime }
        naturalEndObservation = nil
        naturalEndTerminalIssued = false
        naturalEndTerminalConsumed = false
        naturalEndTerminalResult = nil
        #if DEBUG
        naturalEndFailureDiagnosticForTesting = nil
        #endif
        let observationIdentity = UUID()
        endpointObservationIdentity = observationIdentity
        if case .natural = boundary { nativeSelectionRevision.installEndpoint(token: observationIdentity) }
        eventHub.installEndpoint(endpoint: time, token: observationIdentity) {
            [weak self, weak item] observedIdentity, endpoint in
            guard let self else { return }
            guard self.endpointStabilityDeadline == nil else { return }
            guard let item,
                  self.endpointObservationIdentity == observationIdentity,
                  self.currentItemIdentity == observedIdentity,
                  self.item === item, self.player.currentItem === item,
                  let first = try? ExactMediaTime(self.player.currentTime()),
                  let constrained = self.endpointBoundary.observedEndpoint(forwardEnd: item.forwardPlaybackEndTime,
                      duration: item.duration) else {
                self.publishNaturalEnd(.failure(.staleItem), item: observedIdentity)
                return
            }
            guard self.checkNaturalEndPredicate(constrained == endpoint, .ingressEndpoint) else {
                self.captureNaturalEndFailureClocks(first: first, stable: nil, expected: endpoint, effective: constrained)
                self.publishNaturalEnd(.failure(.endpointMismatch), item: observedIdentity)
                return
            }
            if case .natural = self.endpointBoundary {
                // Native EOS can precede AVPlayer's rate/time-control settlement.
                // Keep this notification's first clock and original deadline;
                // completeNaturalEndRead still requires rate zero and paused.
                guard self.checkNaturalEndPredicate(item.status == .readyToPlay, .ingressNotReady),
                      self.checkNaturalEndPredicate(item.error == nil, .ingressItemError),
                      self.checkNaturalEndQuantum(item: observedIdentity, physical: item, requiresFreshness: false) else {
                    self.captureNaturalEndFailureClocks(first: first, stable: nil, expected: endpoint, effective: constrained)
                    self.publishNaturalEnd(.failure(.endpointMismatch), item: observedIdentity)
                    return
                }
            }
            #if DEBUG
            if case .natural = self.endpointBoundary {
                print("NATIVE_EOF_NOTIFICATION output=\(observedIdentity.outputLifecycleEpoch.outputNonce) " +
                    "current=\(first.value)/\(first.timescale) quantum=\(self.nativeEndQuantum.map { "\($0.period.value)/\($0.period.timescale)" } ?? "none")")
            }
            #endif
            self.naturalEndObservation = .init(item: observedIdentity,
                expectedEndpoint: endpoint, constrainedEndpoint: constrained,
                firstCurrentTime: first,
                stableCurrentTime: nil)
            guard self.checkNaturalEndPredicate(self.naturalEndAuthority?.revalidateCurrentAuthority() == true, .ingressAuthority) else {
                self.captureNaturalEndFailureClocks(first: first, stable: nil, expected: endpoint, effective: constrained)
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(
                    "eos_first_read_authority_rejected_present_\(self.naturalEndAuthority != nil)")
                #endif
                self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                return
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("eos_first_read_authority_accepted")
            #endif
            guard self.endpointStabilityDeadline == nil else { return }
            if let scheduler = self.deadlineScheduler {
                guard let deadline = scheduler.schedule(after: 0.1, handler: { [weak self] in
                    self?.naturalEndDeadlineFired(identity: observationIdentity)
                }) else {
                    _ = self.checkNaturalEndPredicate(false, .ingressDeadlineCapacity)
                    self.captureNaturalEndFailureClocks(first: first, stable: nil, expected: endpoint, effective: constrained)
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("eos_manual_deadline_slot_rejected")
                    #endif
                    self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                    return
                }
                self.endpointStabilityDeadline = deadline
            } else {
                guard self.checkNaturalEndPredicate(self.naturalEndAuthority?.scheduleNaturalEnd(item: observedIdentity,
                    identity: observationIdentity, receiver: self) == true, .ingressRegistryDeadline) else {
                    self.captureNaturalEndFailureClocks(first: first, stable: nil, expected: endpoint, effective: constrained)
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("eos_registry_deadline_rejected")
                    #endif
                    self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                    return
                }
                self.endpointStabilityDeadline = observationIdentity
            }
        }
        let hub = eventHub
        let nativeRevision: NativeHLSSelectionRevision?
        if case .natural = boundary { nativeRevision = nativeSelectionRevision } else { nativeRevision = nil }
        let callback: @Sendable (Notification) -> Void = { [weak hub] _ in
            callbackLease.assertRegistered()
            // This exact private EOS ingress, not another observer's ordering,
            // revokes pre-EOS timing and requests the original joined refresh.
            nativeRevision?.receiveNativeEnd(token: observationIdentity)
            hub?.receiveEndpoint(item: identity, token: observationIdentity)
        }
        callbackLease.inspectRegistration()
        endpointObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: nil, using: callback)
    }

    func installNaturalEndTerminalHandler(
        item identity: AVPlayerItemInstanceIdentity,
        handler: @escaping @MainActor @Sendable (
            AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
        ) -> Void
    ) throws {
        guard currentItemIdentity == identity, naturalEndTerminalHandler == nil else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        naturalEndTerminalHandler = handler
    }

    nonisolated func naturalEndDeadlineFired(identity: UUID) {
        DispatchQueue.main.async { [weak self] in self?.completeNaturalEndRead(identity: identity) }
    }

    func hasPendingNaturalEndVerification(item identity: AVPlayerItemInstanceIdentity,
                                          activation: ActivationEpoch) -> Bool {
        guard currentItemIdentity == identity, let item, player.currentItem === item,
              player.rate == 0, player.timeControlStatus == .paused,
              endpointObservationIdentity != nil, endpointStabilityDeadline != nil,
              !naturalEndTerminalIssued, naturalEndTerminalResult == nil,
              let observation = naturalEndObservation, observation.item == identity,
              observation.stableCurrentTime == nil,
              observation.constrainedEndpoint == observation.expectedEndpoint,
              let constraint = endpointBoundary.observedEndpoint(forwardEnd: item.forwardPlaybackEndTime, duration: item.duration),
              constraint == observation.expectedEndpoint,
              naturalEndAuthority?.activation == activation,
              naturalEndAuthority?.revalidateCurrentAuthority() == true,
              acceptPendingNaturalEndQuantum(item: identity, physical: item) else { return false }
        // Only the private matching notification installs the first observation
        // and its original deadline. Completion, cancellation and owned pause
        // clear that deadline; this query creates no grace period or EOS proof.
        return true
    }

    private func acceptPendingNaturalEndQuantum(item identity: AVPlayerItemInstanceIdentity, physical: AVPlayerItem) -> Bool {
        guard case .natural = endpointBoundary else {
            return nativeEndQuantum?.hasCurrentIdentity(item: identity, physical: physical) ?? true
        }
        let validation = nativeEndQuantum?.validation(item: identity, physical: physical,
            requiresFreshness: false, allowingWrapperRenewal: true)
        guard validation?.rejection == nil, nativeEndQuantumWindow.permits(nativeEndQuantum?.visualSelection) else { return false }
        if let comparison = validation?.sdkIdentity, comparison.usesWrapperRenewal {
            guard comparison.permitsPendingPause(isReady: physical.status == .readyToPlay, errorFree: physical.error == nil) else { return false }
        }
        nativeEndQuantumWindow.recordWrapperRenewal(validation?.sdkIdentity?.usesWrapperRenewal == true)
        return true
    }

    private func completeNaturalEndRead(identity: UUID) {
        guard endpointObservationIdentity == identity, endpointStabilityDeadline != nil else { return }
        defer { cancelNaturalEndDeadline() }
        // 同一原activation的interval在投递后可能被安全首入口关闭；失效事件不能发布结果。
        guard naturalEndAuthority?.revalidateCurrentAuthority() == true,
              let item, let currentItemIdentity, player.currentItem === item,
              let prior = naturalEndObservation, prior.item == currentItemIdentity,
              let stable = try? ExactMediaTime(player.currentTime()),
              let constraint = endpointBoundary.observedEndpoint(forwardEnd: item.forwardPlaybackEndTime, duration: item.duration) else { return }
        if case .natural = endpointBoundary {
            guard checkNaturalEndPredicate(item.status == .readyToPlay, .confirmNotReady),
                  checkNaturalEndPredicate(item.error == nil, .confirmItemError),
                  checkNaturalEndPredicate(player.rate == 0, .confirmRate),
                  checkNaturalEndPredicate(player.timeControlStatus == .paused, .confirmControl),
                  checkNaturalEndQuantum(item: currentItemIdentity, physical: item, requiresFreshness: true) else {
                captureNaturalEndFailureClocks(first: prior.firstCurrentTime, stable: stable,
                    expected: prior.expectedEndpoint, effective: constraint)
                publishNaturalEnd(.failure(.endpointMismatch), item: currentItemIdentity)
                return
            }
        }
        guard checkNaturalEndPredicate(prior.firstCurrentTime == stable, .confirmStableClock) else {
            captureNaturalEndFailureClocks(first: prior.firstCurrentTime, stable: stable,
                expected: prior.expectedEndpoint, effective: constraint)
            publishNaturalEnd(.failure(.unstableDirectRead), item: currentItemIdentity)
            return
        }
        guard checkNaturalEndPredicate(prior.constrainedEndpoint == prior.expectedEndpoint, .confirmFirstEndpoint),
              checkNaturalEndPredicate(constraint == prior.expectedEndpoint, .confirmEffectiveEndpoint),
              checkNaturalEndPredicate(endpointBoundary.containsFinalClock(stable, expected: prior.expectedEndpoint,
                  quantum: nativeEndQuantum?.period), .confirmFinalClock) else {
            captureNaturalEndFailureClocks(first: prior.firstCurrentTime, stable: stable,
                expected: prior.expectedEndpoint, effective: constraint, firstEffective: prior.constrainedEndpoint)
            publishNaturalEnd(.failure(.endpointMismatch), item: currentItemIdentity)
            return
        }
        let result = AVPlayerNaturalEndObservation(item: currentItemIdentity,
            expectedEndpoint: prior.expectedEndpoint, constrainedEndpoint: constraint,
            firstCurrentTime: prior.firstCurrentTime, stableCurrentTime: stable)
        guard naturalEndAuthority?.revalidateCurrentAuthority() == true else { return }
        naturalEndObservation = result
        publishNaturalEnd(.success(result), item: currentItemIdentity)
    }

    /// Return each existing predicate unchanged. Only the first failed operand
    /// writes diagnostics; conjunction order and the number of SDK reads stay fixed.
    private func checkNaturalEndPredicate(_ accepted: Bool, _ predicate: AVPlayerNaturalEndFailurePredicate) -> Bool {
        #if DEBUG
        if !accepted, naturalEndFailureDiagnosticForTesting == nil {
            naturalEndFailureDiagnosticForTesting = .init(predicate: predicate, quantumFailure: nil)
        }
        #endif
        return accepted
    }

    private func checkNaturalEndQuantum(item: AVPlayerItemInstanceIdentity, physical: AVPlayerItem,
                                       requiresFreshness: Bool) -> Bool {
        let validation = nativeEndQuantum?.validation(item: item, physical: physical, requiresFreshness: requiresFreshness,
            allowingWrapperRenewal: !requiresFreshness)
        let failure = validation?.rejection ?? (nativeEndQuantumWindow.permits(nativeEndQuantum?.visualSelection) ? nil :
            NativeHLSQuantumValidationRejection(cause: .visualSelection, sdkIdentity: validation?.sdkIdentity))
        #if DEBUG
        if let failure, naturalEndFailureDiagnosticForTesting == nil {
            naturalEndFailureDiagnosticForTesting = .init(
                predicate: requiresFreshness ? .confirmQuantum : .ingressQuantum,
                quantumFailure: failure.cause, revision: failure.revision, sdkIdentity: failure.sdkIdentity)
        }
        #endif
        if failure == nil, !requiresFreshness {
            nativeEndQuantumWindow.recordWrapperRenewal(validation?.sdkIdentity?.usesWrapperRenewal == true)
        }
        // A missing quantum keeps exact-endpoint-only behavior only if this
        // window has never borrowed the presentation-wrapper exception.
        return failure == nil
    }

    private func captureNaturalEndFailureClocks(first: ExactMediaTime, stable: ExactMediaTime?,
                                               expected: ExactMediaTime, effective: ExactMediaTime,
                                               firstEffective: ExactMediaTime? = nil) {
        #if DEBUG
        guard !naturalEndTerminalIssued else { return }
        naturalEndFailureDiagnosticForTesting?.first = first
        naturalEndFailureDiagnosticForTesting?.stable = stable
        naturalEndFailureDiagnosticForTesting?.expected = expected
        // Report the endpoint used by the failed comparison, not a later read.
        let observedEndpoint = naturalEndFailureDiagnosticForTesting?.predicate == .confirmFirstEndpoint ? firstEffective : effective
        naturalEndFailureDiagnosticForTesting?.effective = observedEndpoint
        naturalEndFailureDiagnosticForTesting?.quantum = nativeEndQuantum?.period
        #endif
    }

    private func cancelNaturalEndDeadline() {
        if let endpointStabilityDeadline {
            if let deadlineScheduler { deadlineScheduler.cancel(endpointStabilityDeadline) }
            else { naturalEndAuthority?.retireNaturalEnd(identity: endpointStabilityDeadline) }
        }
        endpointStabilityDeadline = nil
        nativeEndQuantumWindow.reset()
    }

    func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) -> AVPlayerNaturalEndTerminalResult? {
        guard capability.issuerIdentity == naturalEndIssuerIdentity,
              capability.item == item, currentItemIdentity == item,
              capability.observationIdentity == endpointObservationIdentity,
              naturalEndTerminalIssued, !naturalEndTerminalConsumed,
              let result = naturalEndTerminalResult else { return nil }
        naturalEndTerminalConsumed = true
        return result
    }

    private func publishNaturalEnd(_ result: AVPlayerNaturalEndTerminalResult,
                                   item: AVPlayerItemInstanceIdentity) {
        guard !naturalEndTerminalIssued, let observationIdentity = endpointObservationIdentity else { return }
        naturalEndTerminalIssued = true
        naturalEndTerminalResult = result
        let capability = AVPlayerNaturalEndTerminalCapability(
            issuerIdentity: naturalEndIssuerIdentity, item: item, observationIdentity: observationIdentity)
        naturalEndTerminalHandler?(capability, item)
    }

    func replaceCurrentItemWithNil(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity, !systemAudioTransitionInFlight else { return }
        cancelAllWaiters()
        player.replaceCurrentItem(with: nil)
        item = nil
        currentItemIdentity = nil
        installationResourceContextReservation = nil
        eventHub.releaseInstallationResourceContext()
    }

    func removeObservers(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity || currentItemIdentity == nil else { return }
        cancelAllWaiters()
    }

    private func cancelAllWaiters() {
        logSnapshotCache.invalidate()
        prepareWait.cancelCurrent()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }
        accessLogObserver = nil
        if let errorLogObserver { NotificationCenter.default.removeObserver(errorLogObserver) }
        errorLogObserver = nil
        eventHub.cancel()
        removeEndpointObserver()
        naturalEndTerminalHandler = nil
        naturalEndTerminalIssued = false
        naturalEndTerminalConsumed = false
        naturalEndAuthority = nil
    }

    private func removeEndpointObserver() {
        if let token = endpointObservationIdentity { nativeSelectionRevision.clearEndpoint(token: token) }
        if let endpointObserver {
            NotificationCenter.default.removeObserver(endpointObserver)
        }
        endpointObserver = nil
        cancelNaturalEndDeadline()
        endpointObservationIdentity = nil
        endpointBoundary = .constrained
        nativeEndQuantum = nil
        #if DEBUG
        naturalEndFailureDiagnosticForTesting = nil
        naturalEndQuantumUpdateFailureDiagnosticForTesting = nil
        #endif
        eventHub.cancelEndpoint()
    }

    nonisolated private static func hasLoadedCoverage(_ item: AVPlayerItem,
        requested: ExactMediaInterval) throws(AVPlayerItemCoordinatorFailure) -> Bool {
        let result = VPReadLoadedIntervalCoverage(item, requested.start.cmTime, requested.end.cmTime)
        switch result.code {
        case 0: return true
        case 1: return false
        case 2: throw .capacityExceeded
        default: throw .invalidTimeline
        }
    }
}

/// 三类事件各有固定槽，只安排一个 MainActor delivery；URI 在入口同步分类后释放。
final class AVPlayerDriverEventHub: @unchecked Sendable {
    fileprivate let admission: AVPlayerDriverAdmission
    private let resourceContextReservation: PlaybackResourceContextReservation
    fileprivate static func make(admission: AVPlayerDriverAdmission,
        resourceContextReservation: PlaybackResourceContextReservation) throws
        -> AVPlayerDriverEventHub {
        try SystemAVPlayerDriver.creationLock.withLock {
            try SystemAVPlayerDriver.retainAdmissionLocked(admission)
        }
        return .init(admission: admission, resourceContextReservation: resourceContextReservation)
    }
    private init(admission: AVPlayerDriverAdmission,
                 resourceContextReservation: PlaybackResourceContextReservation) {
        self.admission = admission
        self.resourceContextReservation = resourceContextReservation
    }
    deinit {
        SystemAVPlayerDriver.creationLock.withLock { SystemAVPlayerDriver.releaseAdmissionLocked(admission) }
    }
#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        lock.withLock {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body("owned/driver event hub", pointer, malloc_size(pointer))
            inspectNativePreparationWeakSideTable("hub", self, body)
            lock.inspect("owned/driver event hub lock", body)
        }
    }
#endif
    typealias StatusHandler = @MainActor @Sendable (AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch) -> Void
    typealias AccessHandler = @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    typealias EndHandler = @MainActor @Sendable (AVPlayerItemInstanceIdentity, ExactMediaTime) -> Void
    private let lock = PreparationStorageLock()
    private var item: AVPlayerItemInstanceIdentity?
    private var activation: ActivationEpoch?
    private var statusHandler: StatusHandler?
    private var classifier: (@Sendable (URL) -> AccessLogURIClassification)?
    private var accessHandler: AccessHandler?
    private var endpoint: ExactMediaTime?
    private var endpointToken: UUID?
    private var endHandler: EndHandler?
    private var pendingStatus: AVPlayer.TimeControlStatus?
    private var pendingAccess: AccessLogURIClassification?
    private var pendingEnd = false
    private var deliveryScheduled = false
    private var installationResourceContextReservation: PlaybackResourceContextReservation?
    private var pendingResourceContextReservation: PlaybackResourceContextReservation?

    func retainInstallationResourceContext(_ reservation: PlaybackResourceContextReservation) {
        lock.withLock { installationResourceContextReservation = reservation }
    }

    func releaseInstallationResourceContext() {
        lock.withLock { installationResourceContextReservation = nil }
    }

    func activate(_ item: AVPlayerItemInstanceIdentity) {
        cancel()
        lock.withLock { self.item = item }
    }

    func installTimeControl(activation: ActivationEpoch, handler: @escaping StatusHandler) {
        lock.withLock {
            self.activation = activation
            statusHandler = handler
            pendingStatus = nil
        }
    }
    func cancelTimeControl() {
        lock.withLock { activation = nil; statusHandler = nil; pendingStatus = nil }
    }
    func installAccessLog(classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
                          handler: @escaping AccessHandler) {
        lock.withLock { classifier = classify; accessHandler = handler }
    }
    func installEndpoint(endpoint: ExactMediaTime, token: UUID, handler: @escaping EndHandler) {
        lock.withLock {
            self.endpoint = endpoint; endpointToken = token; endHandler = handler; pendingEnd = false
        }
    }

    func receive(_ status: AVPlayer.TimeControlStatus, item: AVPlayerItemInstanceIdentity,
                 activation: ActivationEpoch) {
        let schedule = lock.withLock {
            guard self.item == item, self.activation == activation, statusHandler != nil else { return false }
            pendingStatus = status
            return reserveDeliveryLocked()
        }
        if schedule { deliver() }
    }

    func classify(_ url: URL, item: AVPlayerItemInstanceIdentity) -> AccessLogURIClassification? {
        let classifier = lock.withLock { self.item == item ? self.classifier : nil }
        // 不持 hub 锁进入 server/source，避免 queueSync 或 evidence 回调形成锁环。
        return classifier?(url)
    }

    func receive(_ url: URL, item: AVPlayerItemInstanceIdentity) {
        guard let classification = classify(url, item: item) else { return }
        receive(classification, item: item)
    }

    func receive(_ classification: AccessLogURIClassification, item: AVPlayerItemInstanceIdentity) {
        let schedule = lock.withLock {
            guard self.item == item, accessHandler != nil else { return false }
            pendingAccess = pendingAccess?.coalescing(classification) ?? classification
            return reserveDeliveryLocked()
        }
        if schedule { deliver() }
    }

    func pendingAccessFailure(item: AVPlayerItemInstanceIdentity) -> AVPlayerItemCoordinatorFailure? {
        lock.withLock {
            guard self.item == item else { return nil }
            switch pendingAccess {
            case .invalidLocalResource: return .itemFailed
            case .conflicting: return .selectionChanged
            case .matching, .unrelated, nil: return nil
            }
        }
    }

    func receiveEndpoint(item: AVPlayerItemInstanceIdentity, token: UUID) {
        let schedule = lock.withLock {
            guard self.item == item, endpointToken == token, endHandler != nil else { return false }
            pendingEnd = true
            return reserveDeliveryLocked()
        }
        if schedule { deliver() }
    }

    private func reserveDeliveryLocked() -> Bool {
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        pendingResourceContextReservation = installationResourceContextReservation
        return true
    }

    private func deliver() {
        let resourceTail = lock.withLock { pendingResourceContextReservation }
        DispatchQueue.main.async { [self, resourceTail] in
            let delivery = lock.withLock { () -> (AVPlayerItemInstanceIdentity,
                AVPlayer.TimeControlStatus?, ActivationEpoch?, StatusHandler?,
                AccessLogURIClassification?, AccessHandler?, ExactMediaTime?, EndHandler?)? in
                defer {
                    pendingStatus = nil; pendingAccess = nil; pendingEnd = false
                    deliveryScheduled = false; pendingResourceContextReservation = nil
                }
                guard let item else { return nil }
                return (item, pendingStatus, activation, statusHandler, pendingAccess, accessHandler,
                    pendingEnd ? endpoint : nil, pendingEnd ? endHandler : nil)
            }
            guard let delivery else { return }
            #if DEBUG
            if delivery.6 != nil || delivery.1 == .paused {
                PlaybackDiagnosticTracker.shared.append(
                    "avrelay_batch_output_\(delivery.0.outputLifecycleEpoch.outputNonce)"
                    + "_item_\(delivery.0.itemGeneration)"
                    + "_activation_\(delivery.2?.activationNonce ?? 0)"
                    + "_status_\(delivery.1?.rawValue ?? -1)"
                    + "_access_\(delivery.4.map { String(describing: $0) } ?? "nil")"
                    + "_endpoint_\(delivery.6 != nil)")
            }
            #endif
            // Access faults revoke authority first. A matching endpoint then
            // admits its bounded direct-read verification before a coalesced
            // paused status asks whether that exact verification is pending.
            if let classification = delivery.4 { delivery.5?(classification, delivery.0) }
            if let endpoint = delivery.6 { delivery.7?(delivery.0, endpoint) }
            if let status = delivery.1, let activation = delivery.2 { delivery.3?(status, delivery.0, activation) }
            withExtendedLifetime(resourceTail) {}
        }
    }

    func cancelEndpoint() {
        lock.withLock { endpoint = nil; endpointToken = nil; endHandler = nil; pendingEnd = false }
    }
    func cancel() {
        lock.withLock {
            item = nil; activation = nil; statusHandler = nil; classifier = nil; accessHandler = nil
            endpoint = nil; endpointToken = nil; endHandler = nil
            pendingStatus = nil; pendingAccess = nil; pendingEnd = false
            // 已排队 delivery 是固定的唯一唤醒；新item复用该唤醒，不再排第二个closure。
        }
    }
}

/// prepare 持久终态保存固定业务错误或内联诊断快照，不继续持有任意原异常对象。
enum AVPlayerFixedPreparationFailure: Error, Sendable, Equatable {
    case coordinator(AVPlayerItemCoordinatorFailure)
    case aac(AVPlayerAACEndpointValidationFailure)
    case timeline(HLSTimelineError)
    case completed(CompletedMediaEvidenceError)
    case publication(HLSPublicationFailure)
    case cancelled
    case unexpected(ErrorDiagnosticSnapshot)

    init(_ error: any Error) {
        switch error {
        case let value as Self: self = value
        case let value as AVPlayerItemCoordinatorFailure: self = .coordinator(value)
        case let value as AVPlayerAACEndpointValidationFailure: self = .aac(value)
        case let value as HLSTimelineError: self = .timeline(value)
        case let value as CompletedMediaEvidenceError: self = .completed(value)
        case let value as HLSPublicationFailure: self = .publication(value)
        case is CancellationError: self = .cancelled
        default: self = .unexpected(PlaybackErrorDiagnostics.snapshot(error))
        }
    }

    var boundaryError: any Error {
        switch self {
        case .coordinator(let value): value
        case .aac(let value): value
        case .timeline(let value): value
        case .completed(let value): value
        case .publication(let value): value
        case .cancelled: CancellationError()
        case .unexpected(let value): value
        }
    }
}

/// 同一 prepare runner 顺序复用的唯一 continuation；token 退休前不准入下一阶段。
final class AVPlayerPrepareWaitSlot: @unchecked Sendable {
#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        lock.withLock {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body("owned/prepare wait slot", pointer, malloc_size(pointer))
            lock.inspect("owned/prepare wait slot lock", body)
            if let observation {
                let observationPointer = UnsafeRawPointer(Unmanaged.passUnretained(observation).toOpaque())
                body("owned/公开 prepare KVO wrapper", observationPointer, malloc_size(observationPointer))
            }
        }
    }
#endif
    enum Phase: UInt8, Sendable { case ready, mapping, seek, loaded, preroll }
    struct Token: Sendable, Equatable { let generation: UInt64; let phase: Phase }
    private let lock = PreparationStorageLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var observation: NSKeyValueObservation?
    private var generation: UInt64 = 0
    private var current: Token?
    private var terminal: Result<Bool, AVPlayerFixedPreparationFailure>?

    var isActive: Bool { lock.withLock { current != nil } }
    var activePhase: Phase? { lock.withLock { current?.phase } }

    func begin(_ phase: Phase) throws -> Token {
        try lock.withLock {
            guard current == nil else { throw AVPlayerItemCoordinatorFailure.capacityExceeded }
            guard generation < .max else { throw AVPlayerItemCoordinatorFailure.identitySpaceExhausted }
            generation += 1
            let token = Token(generation: generation, phase: phase)
            current = token
            return token
        }
    }

    func install(_ continuation: CheckedContinuation<Bool, Error>, token: Token) {
        let pending = lock.withLock { () -> Result<Bool, AVPlayerFixedPreparationFailure>? in
            guard current == token else { return .failure(.coordinator(.staleIdentity)) }
            if let terminal { return terminal }
            guard self.continuation == nil else { return .failure(.coordinator(.capacityExceeded)) }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending.mapError(\.boundaryError)) }
    }

    func retain(_ observation: NSKeyValueObservation, token: Token) {
        let keep = lock.withLock {
            guard current == token, terminal == nil else { return false }
            self.observation = observation
            return true
        }
        if !keep { observation.invalidate() }
    }

    func resolve(_ result: Result<Bool, Error>, token: Token) {
        resolveFixed(result.mapError(AVPlayerFixedPreparationFailure.init), token: token)
    }

    func resolveFixed(_ result: Result<Bool, AVPlayerFixedPreparationFailure>, token: Token) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Error>? in
            guard current == token, terminal == nil else { return nil }
            terminal = result
            defer { self.continuation = nil }
            return self.continuation
        }
        if let continuation { continuation.resume(with: result.mapError(\.boundaryError)) }
    }

    func cancelCurrent() {
        if let token = lock.withLock({ current }) {
            resolve(.failure(CancellationError()), token: token)
        }
    }

    func retire(_ token: Token) {
        let observation = lock.withLock { () -> NSKeyValueObservation? in
            guard current == token else { return nil }
            defer { self.observation = nil }
            return self.observation
        }
        observation?.invalidate()
        lock.withLock {
            guard current == token else { return }
            current = nil
            terminal = nil
        }
    }
}
