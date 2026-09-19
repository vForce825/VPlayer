// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
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

struct AVPlayerNaturalEndObservation: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let expectedEndpoint: ExactMediaTime
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
    enum Kind: UInt8, Sendable { case timeControl, accessLog, endpoint, ready, seek, loaded, preroll }
    nonisolated(unsafe) private static var occupied: UInt8 = 0
    private let slot: UInt8
    let kind: Kind
    private let admission: AVPlayerDriverAdmission
    private let resourceContextReservation: PlaybackResourceContextReservation
    private let installationResourceContextReservation: PlaybackResourceContextReservation?

    fileprivate static func reserve(_ kind: Kind, admission: AVPlayerDriverAdmission,
        installationResourceContextReservation: PlaybackResourceContextReservation?) throws
        -> AVPlayerSDKCallbackLease {
        let resourceReservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 2 * 1_024)
        do {
            let lease = try SystemAVPlayerDriver.creationLock.withLock {
                guard let slot = (UInt8(0)..<8).first(where: { occupied & (1 << $0) == 0 }) else {
                    throw AVPlayerItemCoordinatorFailure.capacityExceeded
                }
                try SystemAVPlayerDriver.retainAdmissionLocked(admission)
                occupied |= 1 << slot
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
    private init(slot: UInt8, kind: Kind, admission: AVPlayerDriverAdmission,
                 resourceContextReservation: PlaybackResourceContextReservation,
                 installationResourceContextReservation: PlaybackResourceContextReservation?) {
        self.slot = slot; self.kind = kind; self.admission = admission
        self.resourceContextReservation = resourceContextReservation
        self.installationResourceContextReservation = installationResourceContextReservation
    }
    func assertRegistered() {
        SystemAVPlayerDriver.creationLock.withLock {
            precondition(Self.occupied & (1 << slot) != 0, "SDK callback 的原物理租约不可提前释放")
            precondition(SystemAVPlayerDriver.isAdmissionActiveLocked(admission))
        }
    }
    deinit {
        SystemAVPlayerDriver.creationLock.withLock {
            precondition(Self.occupied & (1 << slot) != 0)
            Self.occupied &= ~(1 << slot)
            SystemAVPlayerDriver.releaseAdmissionLocked(admission)
        }
        PlaybackResourceContextLedger.shared.release(resourceContextReservation)
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

@MainActor
final class SystemAVPlayerDriver: AVPlayerDriving, PlaybackNaturalEndDeadlineReceiving {
#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        func object(_ role: String, _ value: AnyObject) {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque())
            body(role, pointer, malloc_size(pointer))
        }
        object("HLS/原 SystemAVPlayerDriver 壳", self)
        inspectNativePreparationWeakSideTable("driver", self, body)
        Self.creationLock.inspect("owned/单 driver 准入锁", body)
        eventHub.inspectPreparationAllocations(body)
        prepareWait.inspectPreparationAllocations(body)
        if let timeControlObservation { object("owned/公开 timeControl KVO wrapper", timeControlObservation) }
        if let accessLogObserver { object("owned/公开 accessLog notification wrapper", accessLogObserver) }
        if let endpointObserver { object("owned/公开 endpoint notification wrapper", endpointObserver) }
    }
#endif
    nonisolated fileprivate static let creationLock = PreparationStorageLock()
    nonisolated(unsafe) private static var admissionGeneration: UInt64 = 0
    nonisolated(unsafe) private static var admissionReferences: UInt16 = 0

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
    }

    static func make(player: AVPlayer? = nil,
                     deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)? = nil) throws -> SystemAVPlayerDriver {
        let resourceReservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 8 * 1_024)
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
            resourceContextReservation: resourceReservation)
        transferred = true
        try PlaybackResourceContextLedger.shared.rebind(
            resourceReservation, to: .object(ObjectIdentifier(driver)))
        resourceTransferred = true
        return driver
    }
    let player: AVPlayer
    private var item: AVPlayerItem?
    private(set) var currentItemIdentity: AVPlayerItemInstanceIdentity?
    let prepareWait = AVPlayerPrepareWaitSlot()
    private let deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)?
    private var naturalEndAuthority: ControlTaskRegistry.BackendPositiveRateInvocation?
    let eventHub: AVPlayerDriverEventHub
    private let resourceContextReservation: PlaybackResourceContextReservation
    private var installationResourceContextReservation: PlaybackResourceContextReservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var accessLogObserver: NSObjectProtocol?
    private var endpointObserver: NSObjectProtocol?
    private var endpointStabilityDeadline: UUID?
    private var endpointObservationIdentity: UUID?
    private(set) var naturalEndObservation: AVPlayerNaturalEndObservation?
    private(set) var naturalEndTerminalResult: AVPlayerNaturalEndTerminalResult?
    private let naturalEndIssuerIdentity = UUID()
    private var naturalEndTerminalIssued = false
    private var naturalEndTerminalConsumed = false
    private var naturalEndTerminalHandler: (@MainActor @Sendable (
        AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
    ) -> Void)?

    private init(player: AVPlayer, deadlineScheduler: (any AVPlayerWaitDeadlineScheduling)?,
                 admission: AVPlayerDriverAdmission,
                 resourceContextReservation: PlaybackResourceContextReservation) throws {
        self.player = player
        self.deadlineScheduler = deadlineScheduler
        self.resourceContextReservation = resourceContextReservation
        eventHub = try AVPlayerDriverEventHub.make(
            admission: admission, resourceContextReservation: resourceContextReservation)
    }

    deinit { Self.creationLock.withLock { Self.releaseAdmissionLocked(eventHub.admission) } }

    func reserveSDKCallbackLease(_ kind: AVPlayerSDKCallbackLease.Kind) throws -> AVPlayerSDKCallbackLease {
        try .reserve(kind, admission: eventHub.admission,
            installationResourceContextReservation: installationResourceContextReservation)
    }

    func retainInstallationResourceContext(_ reservation: PlaybackResourceContextReservation) {
        installationResourceContextReservation = reservation
        eventHub.retainInstallationResourceContext(reservation)
    }

    var rate: Float { player.rate }
    var timeControlStatus: AVPlayer.TimeControlStatus { player.timeControlStatus }
    var activeWaiterCount: Int {
        prepareWait.isActive ? 1 : 0
    }
    var fixedTimerCount: Int { 0 }

    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws {
        cancelAllWaiters()
        installationResourceContextReservation = nil
        eventHub.releaseInstallationResourceContext()
        player.pause()
        player.automaticallyWaitsToMinimizeStalling = true
        let installed = AVPlayerItem(url: url)
        installed.preferredForwardBufferDuration = 3
        installed.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.replaceCurrentItem(with: installed)
        item = installed
        currentItemIdentity = identity
        eventHub.activate(identity)
    }

    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item identity: AVPlayerItemInstanceIdentity) {
        precondition(currentItemIdentity == identity,
                     "prepare fence 必须属于当前 System AVPlayer item")
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
                        gate.resolve(.failure(AVPlayerItemCoordinatorFailure.itemFailed), token: token)
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

    func waitForLoadedTimeRanges(item identity: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: FMP4PresentationRange) async throws
        -> AVPlayerLoadedRangeReceipt {
        guard currentItemIdentity == identity, let item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        try Task.checkCancellation()
        if try Self.hasLoadedCoverage(item, requested: requested) {
            return .init(item: identity, playhead: playhead, requested: requested)
        }
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
        guard succeeded, currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.prerollFailed
        }
    }

    func preroll(item identity: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt {
        guard currentItemIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
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
        return AVPlayerPrerollReceipt(item: identity, playhead: playhead, succeeded: succeeded)
    }

    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item identity: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == identity,
              let snapshot = invocation.currentSnapshot,
              snapshot.interval.outputLifecycle == identity.outputLifecycleEpoch,
              snapshot.interval.itemGeneration == identity.itemGeneration else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
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
              accessLogObserver == nil else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let callbackLease = try reserveSDKCallbackLease(.accessLog)
        let hub = eventHub
        hub.installAccessLog(classify: classify, handler: handler)
        let callback: @Sendable (Notification) -> Void = { [weak item, weak hub] _ in
            callbackLease.assertRegistered()
            guard let value = item?.accessLog()?.events.last?.uri,
                  let url = URL(string: value) else { return }
            hub?.receive(url, item: identity)
        }
        callbackLease.inspectRegistration()
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item, queue: nil, using: callback)
    }

    func cancelPendingPrerolls(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity else { return }
        player.cancelPendingPrerolls()
        prepareWait.cancelCurrent()
    }

    func pause(item identity: AVPlayerItemInstanceIdentity) {
        guard currentItemIdentity == identity else { return }
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
        return AVPlayerDirectState(item: identity, rate: player.rate,
                            timeControlStatus: player.timeControlStatus)
    }

    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item identity: AVPlayerItemInstanceIdentity) throws {
        guard currentItemIdentity == identity, let item,
              player.currentItem === item, time.value > 0 else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let callbackLease = try reserveSDKCallbackLease(.endpoint)
        removeEndpointObserver()
        item.forwardPlaybackEndTime = time.cmTime
        naturalEndTerminalIssued = false
        naturalEndTerminalConsumed = false
        naturalEndTerminalResult = nil
        let observationIdentity = UUID()
        endpointObservationIdentity = observationIdentity
        eventHub.installEndpoint(endpoint: time, token: observationIdentity) {
            [weak self, weak item] observedIdentity, endpoint in
            guard let self else { return }
            guard self.endpointStabilityDeadline == nil else { return }
            guard let item,
                  self.endpointObservationIdentity == observationIdentity,
                  self.currentItemIdentity == observedIdentity,
                  self.item === item, self.player.currentItem === item,
                  let first = try? ExactMediaTime(self.player.currentTime()),
                  let constrained = try? ExactMediaTime(item.forwardPlaybackEndTime) else {
                self.publishNaturalEnd(.failure(.staleItem), item: observedIdentity)
                return
            }
            guard constrained == endpoint else {
                self.publishNaturalEnd(.failure(.endpointMismatch), item: observedIdentity)
                return
            }
            self.naturalEndObservation = .init(item: observedIdentity,
                expectedEndpoint: endpoint, constrainedEndpoint: constrained,
                firstCurrentTime: first,
                stableCurrentTime: nil)
            guard self.naturalEndAuthority?.revalidateCurrentAuthority() == true else {
                self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                return
            }
            guard self.endpointStabilityDeadline == nil else { return }
            if let scheduler = self.deadlineScheduler {
                guard let deadline = scheduler.schedule(after: 0.1, handler: { [weak self] in
                    self?.naturalEndDeadlineFired(identity: observationIdentity)
                }) else {
                    self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                    return
                }
                self.endpointStabilityDeadline = deadline
            } else {
                guard self.naturalEndAuthority?.scheduleNaturalEnd(item: observedIdentity,
                    identity: observationIdentity, receiver: self) == true else {
                    self.publishNaturalEnd(.failure(.deadlineCapacityExceeded), item: observedIdentity)
                    return
                }
                self.endpointStabilityDeadline = observationIdentity
            }
        }
        let hub = eventHub
        let callback: @Sendable (Notification) -> Void = { [weak hub] _ in
            callbackLease.assertRegistered()
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

    private func completeNaturalEndRead(identity: UUID) {
        guard endpointObservationIdentity == identity, endpointStabilityDeadline != nil else { return }
        defer { cancelNaturalEndDeadline() }
        // 同一原activation的interval在投递后可能被安全首入口关闭；失效事件不能发布结果。
        guard naturalEndAuthority?.revalidateCurrentAuthority() == true,
              let item, let currentItemIdentity, player.currentItem === item,
              let prior = naturalEndObservation, prior.item == currentItemIdentity,
              let stable = try? ExactMediaTime(player.currentTime()),
              let constraint = try? ExactMediaTime(item.forwardPlaybackEndTime) else { return }
        guard prior.firstCurrentTime == stable else {
            publishNaturalEnd(.failure(.unstableDirectRead), item: currentItemIdentity)
            return
        }
        guard prior.constrainedEndpoint == prior.expectedEndpoint,
              constraint == prior.expectedEndpoint,
              CMTimeCompare(stable.cmTime, prior.expectedEndpoint.cmTime) >= 0 else {
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

    private func cancelNaturalEndDeadline() {
        if let endpointStabilityDeadline {
            if let deadlineScheduler { deadlineScheduler.cancel(endpointStabilityDeadline) }
            else { naturalEndAuthority?.retireNaturalEnd(identity: endpointStabilityDeadline) }
        }
        endpointStabilityDeadline = nil
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
        guard currentItemIdentity == identity else { return }
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
        prepareWait.cancelCurrent()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }
        accessLogObserver = nil
        eventHub.cancel()
        removeEndpointObserver()
        naturalEndTerminalHandler = nil
        naturalEndTerminalIssued = false
        naturalEndTerminalConsumed = false
        naturalEndAuthority = nil
    }

    private func removeEndpointObserver() {
        if let endpointObserver {
            NotificationCenter.default.removeObserver(endpointObserver)
        }
        endpointObserver = nil
        cancelNaturalEndDeadline()
        endpointObservationIdentity = nil
        eventHub.cancelEndpoint()
    }

    nonisolated private static func hasLoadedCoverage(_ item: AVPlayerItem,
        requested: FMP4PresentationRange) throws(AVPlayerItemCoordinatorFailure) -> Bool {
        let result = VPReadLoadedRangeCoverage(item,
            CMTimeRange(start: requested.start.cmTime, duration: requested.duration.cmTime))
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
        lock.withLock { self.activation = activation; statusHandler = handler }
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

    func receive(_ url: URL, item: AVPlayerItemInstanceIdentity) {
        let classifier = lock.withLock { self.item == item ? self.classifier : nil }
        guard let classifier else { return }
        // 不持 hub 锁进入 server/source，避免 queueSync 或 evidence 回调形成锁环。
        let classification = classifier(url)
        let schedule = lock.withLock {
            guard self.item == item, accessHandler != nil else { return false }
            // conflict 不能被随后 matching/unrelated 覆盖而丢失撤销语义。
            if pendingAccess != .conflicting { pendingAccess = classification }
            return reserveDeliveryLocked()
        }
        if schedule { deliver() }
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
            // 先交付 conflict，使其撤销对后续 playing/EOS 发布可见。
            if let classification = delivery.4 { delivery.5?(classification, delivery.0) }
            if let status = delivery.1, let activation = delivery.2 { delivery.3?(status, delivery.0, activation) }
            if let endpoint = delivery.6 { delivery.7?(delivery.0, endpoint) }
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

/// prepare 持久终态只保存固定业务错误码；开放错误在同步边界立即归约。
enum AVPlayerFixedPreparationFailure: Error, Sendable, Equatable {
    case coordinator(AVPlayerItemCoordinatorFailure)
    case aac(AVPlayerAACEndpointValidationFailure)
    case timeline(HLSTimelineError)
    case completed(CompletedMediaEvidenceError)
    case publication(HLSPublicationFailure)
    case cancelled

    init(_ error: any Error) {
        switch error {
        case let value as Self: self = value
        case let value as AVPlayerItemCoordinatorFailure: self = .coordinator(value)
        case let value as AVPlayerAACEndpointValidationFailure: self = .aac(value)
        case let value as HLSTimelineError: self = .timeline(value)
        case let value as CompletedMediaEvidenceError: self = .completed(value)
        case let value as HLSPublicationFailure: self = .publication(value)
        case is CancellationError: self = .cancelled
        default: self = .coordinator(.itemFailed)
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
