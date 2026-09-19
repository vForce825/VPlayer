// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// HLS item 的唯一资源图 owner。它不复制 AVPlayer request，也不把 producer 的
/// 生命周期藏在 backend 的临时 Task 内：producer 在 prepare 内启动，只有 Registry
/// 明确退休该 item 时才取消并等待其真实收尾。
///
/// 媒体图构造者必须在 `replacement` 中携带同一 Loopback server 的 request/evidence
/// source；因此 AVPlayer 永远不能绕过该 bundle 去读取原始节目 URL。
final class HLSOutputItemBundle: @unchecked Sendable {
    typealias ProducerStart = @Sendable () async throws -> AVPlayerItemReplacementBundle
    typealias ProducerRetirement = @Sendable () async -> Bool

    enum Lifecycle: Sendable, Equatable {
        case dormant
        case producing
        case retiring
        case retired
    }

    private var replacementStorage: AVPlayerItemReplacementBundle?
    private let startProducer: ProducerStart
    private let retireProducer: ProducerRetirement
    private let lock = NSLock()
    private var lifecycle: Lifecycle = .dormant
    /// 所有并发 retire caller 必须 join 同一真实 graph retirement receipt；不能由
    /// lifecycle 标记替代实际 producer 已停止的证据。
    private var retirementTask: Task<Bool, Never>?

    init(
        replacement: AVPlayerItemReplacementBundle,
        startProducer: @escaping ProducerStart,
        retireProducer: @escaping ProducerRetirement
    ) {
        replacementStorage = replacement
        self.startProducer = {
            _ = try await startProducer()
            return replacement
        }
        self.retireProducer = retireProducer
    }

    /// 延迟 replacement 仅供 production graph 使用：在 backend 已强持 bundle 后才启动唯一
    /// source，取得全选轨三秒真实前缀并创建同一 loopback item。
    init(
        startProducer: @escaping ProducerStart,
        retireProducer: @escaping ProducerRetirement
    ) {
        replacementStorage = nil
        self.startProducer = startProducer
        self.retireProducer = retireProducer
    }

    var replacement: AVPlayerItemReplacementBundle {
        lock.withLock {
            precondition(replacementStorage != nil, "prefix 未完成前不得安装 AVPlayer item")
            return replacementStorage!
        }
    }

    var itemGeneration: UInt64 { replacement.request.item.itemGeneration }
    var currentLifecycle: Lifecycle { lock.withLock { lifecycle } }

    /// producer 的 source read 只可启动一次。调用方在成功返回后才可把同一 request
    /// 安装进 coordinator；若启动失败，bundle 立即回到 retired，禁止后续激活半成品。
    func prepareProducer() async throws {
        let mayStart = lock.withLock { () -> Bool in
            guard lifecycle == .dormant else { return false }
            lifecycle = .producing
            return true
        }
        guard mayStart else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        do {
            let replacement = try await startProducer()
            lock.withLock { replacementStorage = replacement }
        } catch {
            _ = await retireProducerGraph()
            throw error
        }
    }

    /// 退役是幂等的。`false` 是真实 graph 尚未可证明停止，调用方必须 fail-closed，
    /// 不能用伪造 AVPlayer receipt 换取 Registry cleanup。
    func retireProducerGraph() async -> Bool {
        let retirement = lock.withLock { () -> Task<Bool, Never>? in
            switch lifecycle {
            case .retired, .retiring:
                return retirementTask
            case .dormant, .producing:
                lifecycle = .retiring
                let producer = retireProducer
                let task = Task { await producer() }
                retirementTask = task
                return task
            }
        }
        guard let retirement else {
            // 只有已经从同一 receipt 确认成功的 retired 状态才可幂等确认。
            return currentLifecycle == .retired
        }
        let confirmed = await retirement.value
        lock.withLock {
            if confirmed { lifecycle = .retired }
        }
        return confirmed
    }
}

/// bundle factory 是生产媒体 graph 的装配点。它收到 Registry 已冻结的 prepare
/// invocation，必须用该 lifecycle 生成 item identity，不能自增或复用旧 request。
protocol HLSOutputItemBundleBuilding: Sendable {
    func makeBundle(
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) async throws -> HLSOutputItemBundle
}

/// 系统 bundle builder 的唯一生产入口。它刻意不接受另一个 URL、demuxer 或 item
/// identity：这些值全部从已冻结的 prepare invocation 与唯一 graph authority 取得，避免
/// AVPlayer 旁路同一 source/store/server 图。
final class SystemHLSOutputItemBundleBuilder: HLSOutputItemBundleBuilding, @unchecked Sendable {
    typealias GraphFactory = @Sendable (
        URL,
        ControlTaskRegistry.BackendPrepareInvocation,
        HLSDeliveryApplicationChargeLedger
    ) throws -> HLSMediaGraphAssembler

    let sourceURLForDiagnostics: URL
    let demuxerCardinality = 1
    let playablePrefixMinimumSeconds = 6
    private let graphFactory: GraphFactory
    private let applicationLedger: HLSDeliveryApplicationChargeLedger

    convenience init(sourceURL: URL) throws {
        try self.init(sourceURL: sourceURL, applicationLedger: .shared, graphFactory: { source, invocation, ledger in
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: invocation.outputLifecycleEpoch)
            return HLSMediaGraphAssembler(
                sourceURL: source,
                applicationLedger: ledger,
                graph: SystemHLSDeliveryGraph(authority: authority))
        })
    }

    init(validating sourceURL: URL) throws {
        let scheme = sourceURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw PlaybackCoreError.unsupportedProtocol(scheme)
        }
        self.sourceURLForDiagnostics = sourceURL
        applicationLedger = .shared
        graphFactory = { source, invocation, ledger in
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: invocation.outputLifecycleEpoch)
            return HLSMediaGraphAssembler(
                sourceURL: source,
                applicationLedger: ledger,
                graph: SystemHLSDeliveryGraph(authority: authority))
        }
    }

    init(
        sourceURL: URL,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
        graphFactory: @escaping GraphFactory
    ) throws {
        let scheme = sourceURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw PlaybackCoreError.unsupportedProtocol(scheme)
        }
        self.sourceURLForDiagnostics = sourceURL
        self.applicationLedger = applicationLedger
        self.graphFactory = graphFactory
    }

    func makeBundle(
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) async throws -> HLSOutputItemBundle {
        let assembler = try graphFactory(sourceURLForDiagnostics, invocation, applicationLedger)
        return HLSOutputItemBundle(
            startProducer: { try await assembler.startUntilPlayablePrefix() },
            retireProducer: { await assembler.retireAndAwaitReceipt() }
        )
    }
}

struct HLSDataPlaneAdmissionUsage: Sendable, Equatable {
    let count: Int
    let bytes: Int
    let cancelled: Bool
}

enum HLSDataPlaneAdmissionPermanentRejection: Sendable, Equatable {
    case invalidUnits(required: Int, capacity: Int)
    case invalidBytes(required: Int, maximum: Int)
    case invalidApplicationCharge(required: Int, minimum: Int, maximum: Int)
}

enum HLSDataPlaneAdmissionResult: Sendable {
    case accepted(HLSDataPlaneAdmission.Lease)
    case temporarilyUnavailable(requiredUnits: Int, availableUnits: Int)
    case cancelled
    case permanentlyRejected(HLSDataPlaneAdmissionPermanentRejection)
}

/// demux 在制造下一个下游工作项之前必须先取得的同步、有界准入。
/// release 由真正消费该工作项的尾引用持有，不能在 enqueue 返回时提前归还。
final class HLSDataPlaneAdmission: @unchecked Sendable {
    static let applicationLeaseOverheadBytes = 256

    /// 一个真实 application reservation 的共享 owner。普通 lease 只能归还自己的
    /// local admission；预付 capability 存活时，真实费用不得被提前归还。
    fileprivate final class ApplicationChargeOwner: @unchecked Sendable {
        private let lock = NSLock()
        private let ledger: HLSDeliveryApplicationChargeLedger
        let ledgerIdentity: UUID
        private var reservation: PlaybackApplicationChargeReservation?
        private var references = 1

        init(reservation: PlaybackApplicationChargeReservation,
             ledger: HLSDeliveryApplicationChargeLedger) {
            self.reservation = reservation
            self.ledger = ledger
            ledgerIdentity = ledger.identity
        }

        func retain() -> Bool {
            lock.withLock {
                guard reservation != nil else { return false }
                references += 1
                return true
            }
        }

        var isActive: Bool { lock.withLock { reservation != nil } }

        func release() {
            let released: PlaybackApplicationChargeReservation? = lock.withLock {
                precondition(references > 0, "application reservation owner 不可重复归还")
                references -= 1
                guard references == 0 else { return nil }
                defer { reservation = nil }
                return reservation
            }
            if let released { ledger.release(released) }
        }
    }

    /// 仅由同一文件内真实 paid lease 签发的不可构造能力。它不是 UUID：持有它
    /// 就持有原 reservation 的一个真实引用，且只覆盖签发时明确的预付 byte 上界。
    final class PrepaidCapability: @unchecked Sendable {
        private let chargeOwner: ApplicationChargeOwner
        private let ledgerIdentity: UUID
        let maximumPrepaidBytes: Int

        fileprivate init(
            chargeOwner: ApplicationChargeOwner,
            ledgerIdentity: UUID,
            maximumPrepaidBytes: Int
        ) {
            self.chargeOwner = chargeOwner
            self.ledgerIdentity = ledgerIdentity
            self.maximumPrepaidBytes = maximumPrepaidBytes
        }

        func permits(
            ledgerIdentity: UUID,
            bytes requestedBytes: Int
        ) -> Bool {
            chargeOwner.isActive && self.ledgerIdentity == ledgerIdentity &&
                requestedBytes >= 0 && requestedBytes <= maximumPrepaidBytes
        }

        deinit { chargeOwner.release() }
    }

    final class Lease: DemuxDataPlaneAdmissionLease, @unchecked Sendable {
        private let lock = NSLock()
        private weak var owner: HLSDataPlaneAdmission?
        private var applicationChargeOwner: ApplicationChargeOwner?
        /// prepaid local lease 只强持已有 capability，不能成为新的签发根。
        private var prepaidCapability: PrepaidCapability?
        let units: Int
        let bytes: Int

        fileprivate init(
            owner: HLSDataPlaneAdmission,
            units: Int,
            bytes: Int,
            applicationReservation: PlaybackApplicationChargeReservation?,
            applicationLedger: HLSDeliveryApplicationChargeLedger,
            prepaidCapability: PrepaidCapability? = nil
        ) {
            self.owner = owner
            self.units = units
            self.bytes = bytes
            if let applicationReservation {
                applicationChargeOwner = ApplicationChargeOwner(
                    reservation: applicationReservation, ledger: applicationLedger
                )
            }
            self.prepaidCapability = prepaidCapability
        }

        /// 只能从仍实际持有 application reservation 的 lease 签发。local-only
        /// prepaid lease 没有 charge owner，因此无法重新签发或扩大预付范围。
        func makePrepaidCapability(maximumPrepaidBytes: Int) -> PrepaidCapability? {
            guard (0...bytes).contains(maximumPrepaidBytes) else { return nil }
            return lock.withLock {
                guard let chargeOwner = applicationChargeOwner,
                      chargeOwner.retain() else { return nil }
                return PrepaidCapability(
                    chargeOwner: chargeOwner,
                    ledgerIdentity: chargeOwner.ledgerIdentity,
                    maximumPrepaidBytes: maximumPrepaidBytes
                )
            }
        }

        func release() {
            let released = lock.withLock { () -> (
                HLSDataPlaneAdmission?, ApplicationChargeOwner?, PrepaidCapability?
            ) in
                defer { owner = nil }
                defer { applicationChargeOwner = nil }
                defer { prepaidCapability = nil }
                return (owner, applicationChargeOwner, prepaidCapability)
            }
            released.0?.release(units: units, bytes: bytes)
            released.1?.release()
        }

        deinit { release() }
    }

    private let condition = NSCondition()
    let ledgerIdentity: UUID
    private let capacity: Int
    private let maximumBytes: Int
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private var count = 0
    private var bytes = 0
    private var cancelled = false
#if DEBUG
    private var waitingCountStorage = 0
    /// 仅在已经确认 temporarilyUnavailable、且即将进入 condition.wait 时计数；
    /// 因而不会把立即 accepted 的 reservation 误报为等待者。
    var waitingCount: Int { condition.withLock { waitingCountStorage } }
#endif

    init(
        capacity: Int,
        maximumBytes: Int,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared
    ) {
        self.capacity = max(0, capacity)
        self.maximumBytes = max(0, maximumBytes)
        self.applicationLedger = applicationLedger
        ledgerIdentity = applicationLedger.identity
    }

    var usage: HLSDataPlaneAdmissionUsage {
        condition.withLock {
            .init(count: count, bytes: bytes, cancelled: cancelled)
        }
    }

    var availableUnits: Int {
        condition.withLock { max(0, capacity - count) }
    }

    func acquire(bytes requestedBytes: Int) -> Lease? {
        acquire(units: 1, bytes: requestedBytes)
    }

    func acquire(
        units requestedUnits: Int,
        bytes requestedBytes: Int,
        applicationBytes requestedApplicationBytes: Int? = nil
    ) -> Lease? {
        guard case let .accepted(lease) = admit(
            units: requestedUnits,
            bytes: requestedBytes,
            applicationBytes: requestedApplicationBytes
        ) else {
            return nil
        }
        return lease
    }

    /// 非阻塞正式入口。只有当前局部/全局占用可释放时才返回 temporarilyUnavailable；
    /// 单对象永远无法装入本 admission/ledger 时稳定返回 permanentlyRejected。
    func admit(
        units requestedUnits: Int,
        bytes requestedBytes: Int,
        applicationBytes requestedApplicationBytes: Int? = nil
    ) -> HLSDataPlaneAdmissionResult {
        switch classify(
            units: requestedUnits,
            bytes: requestedBytes,
            applicationBytes: requestedApplicationBytes
        ) {
        case let .permanentlyRejected(rejection):
            return .permanentlyRejected(rejection)
        case let .valid(request):
            return condition.withLock { attemptAdmission(request) }
        }
    }

    /// 仅 demux I/O lane 使用。控制 lane 从不等待本条件，因此 cancel/stop 可前进。
    func waitForAdmission(bytes requestedBytes: Int) -> Lease? {
        guard case let .accepted(lease) = waitForConcreteAdmission(
            bytes: requestedBytes,
            applicationBytes: nil
        ) else { return nil }
        return lease
    }

    func waitForAdmission(bytes requestedBytes: Int, applicationBytes: Int)
        -> DemuxDataPlaneAdmissionResult {
        switch waitForConcreteAdmission(
            bytes: requestedBytes,
            applicationBytes: Optional(applicationBytes)
        ) {
        case let .accepted(lease): .accepted(lease)
        case .cancelled: .cancelled
        case .permanentlyRejected: .permanentlyRejected
        case .temporarilyUnavailable:
            preconditionFailure("blocking demux admission cannot expose temporary unavailability")
        }
    }

    private func waitForConcreteAdmission(
        bytes requestedBytes: Int,
        applicationBytes requestedApplicationBytes: Int?
    ) -> HLSDataPlaneAdmissionResult {
        let request: ValidatedRequest
        switch classify(
            units: 1,
            bytes: requestedBytes,
            applicationBytes: requestedApplicationBytes
        ) {
        case let .permanentlyRejected(rejection):
            return .permanentlyRejected(rejection)
        case let .valid(validated):
            request = validated
        }
        condition.lock()
        defer { condition.unlock() }
        while true {
            switch attemptAdmission(request) {
            case let .accepted(lease):
                return .accepted(lease)
            case .cancelled:
                return .cancelled
            case .permanentlyRejected:
                preconditionFailure("validated request cannot become permanently invalid")
            case .temporarilyUnavailable:
                // 其他 admission 也共用全局 application ledger；其释放不会 signal
                // 本地条件，因此 I/O lane 以有界条件等待重试，同时 cancel 可立即广播唤醒。
                #if DEBUG
                waitingCountStorage += 1
                #endif
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                #if DEBUG
                waitingCountStorage -= 1
                #endif
            }
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    /// 已由同一 ledger 的不可伪造 conversion credit 预付的 backing 交接。
    /// 仍占本 admission 的 units/bytes；仅免除对同一 backing 的第二次全局 charge。
    func admitPrepaid(
        units requestedUnits: Int,
        bytes requestedBytes: Int,
        capability: PrepaidCapability
    ) -> HLSDataPlaneAdmissionResult {
        guard capability.permits(ledgerIdentity: ledgerIdentity, bytes: requestedBytes) else {
            return .permanentlyRejected(.invalidApplicationCharge(
                required: requestedBytes, minimum: requestedBytes, maximum: 0
            ))
        }
        guard case .valid = classify(units: requestedUnits, bytes: requestedBytes,
                                     applicationBytes: requestedBytes) else {
            return .permanentlyRejected(.invalidBytes(required: requestedBytes, maximum: maximumBytes))
        }
        return condition.withLock {
            guard !cancelled else { return .cancelled }
            let availableUnits = max(0, capacity - count)
            guard requestedUnits <= availableUnits,
                  requestedBytes <= maximumBytes - bytes else {
                return .temporarilyUnavailable(requiredUnits: requestedUnits, availableUnits: availableUnits)
            }
            count += requestedUnits
            bytes += requestedBytes
            return .accepted(Lease(owner: self, units: requestedUnits, bytes: requestedBytes,
                                   applicationReservation: nil, applicationLedger: applicationLedger,
                                   prepaidCapability: capability))
        }
    }

    private func release(units releasedUnits: Int, bytes releasedBytes: Int) {
        condition.withLock {
            precondition(
                releasedUnits > 0 && count >= releasedUnits && bytes >= releasedBytes,
                "HLS data-plane lease 不可重复归还"
            )
            count -= releasedUnits
            bytes -= releasedBytes
            condition.broadcast()
        }
    }

    private struct ValidatedRequest {
        let units: Int
        let bytes: Int
        let applicationBytes: Int
    }

    private enum RequestClassification {
        case valid(ValidatedRequest)
        case permanentlyRejected(HLSDataPlaneAdmissionPermanentRejection)
    }

    private func classify(
        units requestedUnits: Int,
        bytes requestedBytes: Int,
        applicationBytes requestedApplicationBytes: Int?
    ) -> RequestClassification {
        guard requestedUnits > 0, requestedUnits <= capacity else {
            return .permanentlyRejected(.invalidUnits(
                required: requestedUnits,
                capacity: capacity
            ))
        }
        guard requestedBytes >= 0, requestedBytes <= maximumBytes else {
            return .permanentlyRejected(.invalidBytes(
                required: requestedBytes,
                maximum: maximumBytes
            ))
        }
        guard let maximumApplicationBytes = applicationLedger.maximumSingleReservationBytes else {
            return .permanentlyRejected(.invalidApplicationCharge(
                required: requestedApplicationBytes ?? requestedBytes,
                minimum: requestedBytes,
                maximum: 0
            ))
        }
        let applicationBytes: Int
        if let requestedApplicationBytes {
            guard requestedApplicationBytes >= requestedBytes,
                  requestedApplicationBytes <= maximumApplicationBytes else {
                return .permanentlyRejected(.invalidApplicationCharge(
                    required: requestedApplicationBytes,
                    minimum: requestedBytes,
                    maximum: maximumApplicationBytes
                ))
            }
            applicationBytes = requestedApplicationBytes
        } else {
            let charge = requestedBytes.addingReportingOverflow(
                Self.applicationLeaseOverheadBytes
            )
            guard !charge.overflow, charge.partialValue <= maximumApplicationBytes else {
                return .permanentlyRejected(.invalidApplicationCharge(
                    required: charge.overflow ? Int.max : charge.partialValue,
                    minimum: requestedBytes,
                    maximum: maximumApplicationBytes
                ))
            }
            applicationBytes = charge.partialValue
        }
        return .valid(.init(
            units: requestedUnits,
            bytes: requestedBytes,
            applicationBytes: applicationBytes
        ))
    }

    /// 调用方必须持有 condition；所有入口共享此处的动态状态与 reserve 判定。
    private func attemptAdmission(
        _ request: ValidatedRequest
    ) -> HLSDataPlaneAdmissionResult {
        guard !cancelled else { return .cancelled }
        let availableUnits = max(0, capacity - count)
        guard request.units <= availableUnits,
              request.bytes <= maximumBytes - bytes else {
            return .temporarilyUnavailable(
                requiredUnits: request.units,
                availableUnits: availableUnits
            )
        }
        let reservation: PlaybackApplicationChargeReservation
        do {
            reservation = try applicationLedger.reserve(
                allocationIdentity: .stable(UUID()),
                bytes: request.applicationBytes
            )
        } catch {
            // classify 已证明该单 reservation 在固定占用基线上可容纳；此处失败只可能
            // 来自其他可释放 reservation 的 soft/hard 暂时占用。
            return .temporarilyUnavailable(
                requiredUnits: request.units,
                availableUnits: availableUnits
            )
        }
        count += request.units
        bytes += request.bytes
        return .accepted(Lease(
            owner: self,
            units: request.units,
            bytes: request.bytes,
            applicationReservation: reservation,
            applicationLedger: applicationLedger
        ))
    }
}

extension HLSDataPlaneAdmission: DemuxDataPlaneAdmitting {}

private extension NSCondition {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
