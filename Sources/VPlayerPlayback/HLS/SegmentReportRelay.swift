// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import CryptoKit

/// 三个真实 owner 共同归约的单个 AAC media 成员。成员承诺直接来自 relay
/// 已接纳的 sealed object；不使用 callback 完成顺序或 Swift 随机 Hashable。
struct AACMediaMembershipLeaf: Sendable, Hashable {
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: AudioItemGenerationIdentity
    let mediaEpoch: AudioMediaEpochIdentity
    let publicationParticipantID: AudioPublicationParticipantIdentity
    let renditionIdentity: AudioRenditionIdentity
    let logicalSequence: UInt64
    let objectCommitment: FMP4Digest

    init?(_ object: SealedMediaObject) {
        guard object.kind == .media,
              object.publicationEvidence?.format.codec == "mp4a.40.2",
              let identity = try? FMP4ObjectIdentity(object) else { return nil }
        let binding = object.binding
        outputLifecycleEpoch = binding.outputLifecycleEpoch
        itemGeneration = binding.itemGeneration
        mediaEpoch = binding.mediaEpoch
        publicationParticipantID = binding.publicationParticipantID
        renditionIdentity = binding.renditionIdentity
        logicalSequence = object.logicalSequence
        objectCommitment = identity.commitment
    }
}

struct AACMediaMembershipSnapshot: Sendable, Hashable {
    let count: UInt64
    let digest: Data
    let firstLogicalSequence: UInt64?
    let lastLogicalSequence: UInt64?
    let pendingCount: Int
}

/// callback owner 在终段处冻结的全 rendition 成员凭据。issuer nonce 只由
/// `AACRenditionTerminalBinding` 持有，复制公开 snapshot 不能制造同源 receipt。
final class AACCallbackMembershipReceipt: @unchecked Sendable {
    let snapshot: AACMediaMembershipSnapshot
    let terminalLeaf: AACMediaMembershipLeaf
    private let issuer: UUID

    init(snapshot: AACMediaMembershipSnapshot,
         terminalLeaf: AACMediaMembershipLeaf,
         issuer: UUID) {
        self.snapshot = snapshot
        self.terminalLeaf = terminalLeaf
        self.issuer = issuer
    }

    func belongs(to issuer: UUID) -> Bool { self.issuer == issuer }
}

/// publisher 接纳真实 leaf 时签出的逐成员 inclusion。HTTP 只能消费仍随
/// route/response lease 存活的原对象，不能从 key 或全局 digest 重建。
final class AACPublicationLeafAdmission: @unchecked Sendable {
    private let lock = NSLock()
    let leaf: AACMediaMembershipLeaf
    private let issuer: UUID
    private var wasClaimedByHTTP = false

    init(leaf: AACMediaMembershipLeaf, issuer: UUID) {
        self.leaf = leaf
        self.issuer = issuer
    }

    func belongs(to issuer: UUID) -> Bool { self.issuer == issuer }

    /// 去重状态随 store 中的真实 sealed resource 及其 response lease 存活；
    /// 不为全流另建成员表，也不能从 key/digest 重建一次 HTTP 接纳。
    func claimHTTPMembership(
        for binding: AACRenditionTerminalBinding
    ) -> AACMediaMembershipAcceptance {
        lock.withLock {
            guard binding.acceptsPublicationAdmission(self) else {
                return .identityMismatch
            }
            guard !wasClaimedByHTTP else { return .duplicate }
            wasClaimedByHTTP = true
            return .accepted
        }
    }
}

final class AACPublicationMembershipReceipt: @unchecked Sendable {
    let snapshot: AACMediaMembershipSnapshot
    let terminalLeaf: AACMediaMembershipLeaf
    private let issuer: UUID

    init(snapshot: AACMediaMembershipSnapshot,
         terminalLeaf: AACMediaMembershipLeaf,
         issuer: UUID) {
        self.snapshot = snapshot
        self.terminalLeaf = terminalLeaf
        self.issuer = issuer
    }

    func belongs(to issuer: UUID) -> Bool { self.issuer == issuer }
}

/// HTTP receipt 只承诺实际完整服务过的成员集合；它不声称未 GET 的历史成员。
final class AACHTTPMembershipReceipt: @unchecked Sendable {
    let snapshot: AACMediaMembershipSnapshot
    let terminalLeaf: AACMediaMembershipLeaf
    private let issuer: UUID

    init(snapshot: AACMediaMembershipSnapshot,
         terminalLeaf: AACMediaMembershipLeaf,
         issuer: UUID) {
        self.snapshot = snapshot
        self.terminalLeaf = terminalLeaf
        self.issuer = issuer
    }

    func belongs(to issuer: UUID) -> Bool { self.issuer == issuer }
}

/// publication seal 与 terminal HTTP completion 可按任意顺序到达；每个
/// participant 只保留这两个真实 leaf 身份和一次性线性化位，不保存历史数组。
struct AACHTTPFinalizationGate: Sendable {
    private var publicationTerminal: AACMediaMembershipLeaf?
    private var httpTerminal: AACMediaMembershipLeaf?
    private var sealed = false

    mutating func observePublication(
        _ receipt: AACPublicationMembershipReceipt
    ) -> Bool {
        guard !sealed else { return false }
        publicationTerminal = receipt.terminalLeaf
        return claimIfReady()
    }

    mutating func observeTerminalHTTP(_ leaf: AACMediaMembershipLeaf) -> Bool {
        guard !sealed else { return false }
        if httpTerminal.map({ $0.logicalSequence < leaf.logicalSequence }) ?? true {
            httpTerminal = leaf
        }
        return claimIfReady()
    }

    private mutating func claimIfReady() -> Bool {
        guard !sealed, let publicationTerminal, let httpTerminal,
              publicationTerminal == httpTerminal else { return false }
        sealed = true
        return true
    }
}

enum AACMediaMembershipAcceptance: Sendable, Equatable {
    case accepted
    case duplicate
    case identityMismatch
    case capacityExceeded
}

/// HTTP 子集摘要只提供固定尺寸、与完成顺序无关的集合承诺；成员资格本身始终
/// 来自每个 sealed resource 的私签 admission，不能用此摘要反推或伪造 inclusion。
struct AACServedSubsetDigest: Sendable, Equatable {
    private var bytes = Data(
        SHA256.hash(data: Data("VPlayer.AAC.served-subset.v1".utf8)))

    mutating func include(_ leaf: AACMediaMembershipLeaf) {
        include(commitment: leaf.objectCommitment)
    }

    mutating func include(commitment: FMP4Digest) {
        var hasher = SHA256()
        hasher.update(data: Data("VPlayer.AAC.served-leaf.v1".utf8))
        hasher.update(data: commitment.bytes)
        let component = Data(hasher.finalize())
        for index in bytes.indices { bytes[index] ^= component[index] }
    }

    var value: Data { bytes }
}

/// 最多暂存 64 个乱序真实成员；连续前缀被归约为固定 32-byte 状态。
/// 已归约的迟到 completion 只可来自仍由 store 提供的真实 leaf，因此不重复计数。
final class AACMediaMembershipAccumulator: @unchecked Sendable {
    private enum Ordering: Equatable { case unset, contiguous, servedSubset }
    private let lock = NSLock()
    private var ordering: Ordering = .unset
    private var lifecycle: OutputLifecycleEpoch?
    private var item: AudioItemGenerationIdentity?
    private var epoch: AudioMediaEpochIdentity?
    private var participant: AudioPublicationParticipantIdentity?
    private var rendition: AudioRenditionIdentity?
    private var nextLogicalSequence: UInt64?
    private var firstLogicalSequence: UInt64?
    private var lastLogicalSequence: UInt64?
    private var count: UInt64 = 0
    private var digest = Data(SHA256.hash(data: Data("VPlayer.AAC.membership.v1".utf8)))
    private var servedSubsetDigest = AACServedSubsetDigest()
    private var pending: [UInt64: AACMediaMembershipLeaf] = [:]
    private static let pendingCapacity = 64

    @discardableResult
    func accept(_ leaf: AACMediaMembershipLeaf, expectedFloor: UInt64? = nil)
        -> AACMediaMembershipAcceptance {
        lock.withLock {
            guard ordering != .servedSubset else { return .identityMismatch }
            ordering = .contiguous
            if let lifecycle {
                guard lifecycle == leaf.outputLifecycleEpoch,
                      item == leaf.itemGeneration,
                      epoch == leaf.mediaEpoch,
                      participant == leaf.publicationParticipantID,
                      rendition == leaf.renditionIdentity else { return .identityMismatch }
            } else {
                lifecycle = leaf.outputLifecycleEpoch
                item = leaf.itemGeneration
                epoch = leaf.mediaEpoch
                participant = leaf.publicationParticipantID
                rendition = leaf.renditionIdentity
            }
            if nextLogicalSequence == nil {
                nextLogicalSequence = expectedFloor ?? leaf.logicalSequence
            }
            guard let next = nextLogicalSequence else { return .identityMismatch }
            guard count < .max else { return .capacityExceeded }
            if let expectedFloor, leaf.logicalSequence < expectedFloor, count == 0 {
                return .identityMismatch
            }
            if leaf.logicalSequence < next { return .duplicate }
            if let existing = pending[leaf.logicalSequence] {
                return existing == leaf ? .duplicate : .identityMismatch
            }
            let distance = leaf.logicalSequence - next
            guard distance < UInt64(Self.pendingCapacity),
                  pending.count < Self.pendingCapacity else { return .capacityExceeded }
            pending[leaf.logicalSequence] = leaf
            foldContiguousPrefix()
            return .accepted
        }
    }

    /// HTTP 只承诺真正完整服务过的 leaf 子集；子集可以跳过未 GET 的历史成员。
    /// 去重由每个资源随生命周期保存的一次性 claim 完成，归约器自身只保留固定尺寸状态。
    @discardableResult
    func acceptServedSubset(_ admission: AACPublicationLeafAdmission,
                            binding: AACRenditionTerminalBinding)
        -> AACMediaMembershipAcceptance {
        lock.withLock {
            guard ordering != .contiguous else { return .identityMismatch }
            ordering = .servedSubset
            let leaf = admission.leaf
            if let lifecycle {
                guard lifecycle == leaf.outputLifecycleEpoch,
                      item == leaf.itemGeneration,
                      epoch == leaf.mediaEpoch,
                      participant == leaf.publicationParticipantID,
                      rendition == leaf.renditionIdentity else { return .identityMismatch }
            } else {
                lifecycle = leaf.outputLifecycleEpoch
                item = leaf.itemGeneration
                epoch = leaf.mediaEpoch
                participant = leaf.publicationParticipantID
                rendition = leaf.renditionIdentity
            }
            guard count < .max else { return .capacityExceeded }
            switch admission.claimHTTPMembership(for: binding) {
            case .duplicate: return .duplicate
            case .identityMismatch: return .identityMismatch
            case .capacityExceeded: return .capacityExceeded
            case .accepted: break
            }
            servedSubsetDigest.include(leaf)
            firstLogicalSequence = min(firstLogicalSequence ?? leaf.logicalSequence,
                                       leaf.logicalSequence)
            lastLogicalSequence = max(lastLogicalSequence ?? leaf.logicalSequence,
                                      leaf.logicalSequence)
            count += 1
            return .accepted
        }
    }

    var snapshot: AACMediaMembershipSnapshot {
        lock.withLock {
            return .init(count: count,
                  digest: ordering == .servedSubset
                    ? servedSubsetDigest.value : digest,
                  firstLogicalSequence: firstLogicalSequence,
                  lastLogicalSequence: lastLogicalSequence,
                  pendingCount: ordering == .servedSubset ? 0 : pending.count)
        }
    }

    private func foldContiguousPrefix() {
        while let next = nextLogicalSequence, let leaf = pending.removeValue(forKey: next) {
            var hasher = SHA256()
            hasher.update(data: digest)
            hasher.update(data: leaf.objectCommitment.bytes)
            digest = Data(hasher.finalize())
            if firstLogicalSequence == nil { firstLogicalSequence = next }
            lastLogicalSequence = next
            count += 1
            nextLogicalSequence = next == .max ? nil : next + 1
        }
    }
}

enum SegmentReportRelayFailure: Error, Sendable, Equatable {
    case controlCapacityExceeded
    case writerHardCapacityExceeded
    case unpublishedHardCapacityExceeded
    case duplicateLogicalSequence
    case callbackIdentityMismatch
    case arithmeticOverflow
}

struct FMP4WriterLimits: Sendable, Equatable {
    let writerSoftSegmentCount: Int
    let writerHardSegmentCount: Int
    let writerSoftByteCount: Int
    let writerHardByteCount: Int

    static let video = Self(
        writerSoftSegmentCount: 2,
        writerHardSegmentCount: 3,
        writerSoftByteCount: 48 * 1_024 * 1_024,
        writerHardByteCount: 64 * 1_024 * 1_024
    )
    static let audio = Self(
        writerSoftSegmentCount: 2,
        writerHardSegmentCount: 3,
        writerSoftByteCount: 4 * 1_024 * 1_024,
        writerHardByteCount: 8 * 1_024 * 1_024
    )
}

struct SegmentReportRelayUsage: Sendable, Equatable {
    let reservedSlots: Int
    let writerBacklogSegmentCount: Int
    let writerBacklogBytes: Int
    let publicationCapabilityCount: Int
    let initializationSealedObjectByteCount: Int
    let mediaSealedObjectByteCount: Int
    let sealedObjectByteCount: Int
    let unpublishedLogicalSegmentCount: Int
    let shouldBackpressureWriter: Bool
    let shouldBackpressurePublication: Bool
}

/// 真实 writer 封口且本 relay 全部 publication 所有权归零后才签发；不能从 terminal 值复制构造。
final class WriterPublicationDrainReceipt: @unchecked Sendable {
    let source: SegmentedFMP4CallbackContext
    private let relayIdentity: UUID
    fileprivate init(source: SegmentedFMP4CallbackContext, relayIdentity: UUID) {
        self.source = source; self.relayIdentity = relayIdentity
    }
    fileprivate func belongs(to relay: UUID) -> Bool { relayIdentity == relay }
}

struct SegmentCallbackDelivery: @unchecked Sendable {
    let binding: FMP4WriterBinding
    let writerIdentity: FMP4WriterIdentity
    let ticket: SegmentCallbackTicket
    let logicalSequence: UInt64
    let kind: SealedMediaObjectKind
    let bytes: NSData
    let report: SegmentReportReference
    let publicationEvidence: SegmentedFMP4PublicationEvidence?
    init(binding: FMP4WriterBinding, writerIdentity: FMP4WriterIdentity, ticket: SegmentCallbackTicket,
         logicalSequence: UInt64, kind: SealedMediaObjectKind, bytes: NSData, report: SegmentReportReference,
         publicationEvidence: SegmentedFMP4PublicationEvidence? = nil) {
        self.binding = binding; self.writerIdentity = writerIdentity; self.ticket = ticket
        self.logicalSequence = logicalSequence; self.kind = kind; self.bytes = bytes; self.report = report
        self.publicationEvidence = publicationEvidence
    }

    func replacing(writerIdentity: FMP4WriterIdentity) -> Self {
        Self(
            binding: binding,
            writerIdentity: writerIdentity,
            ticket: ticket,
            logicalSequence: logicalSequence,
            kind: kind,
            bytes: bytes,
            report: report,
            publicationEvidence: publicationEvidence
        )
    }
}

struct SegmentCallbackAcceptance: @unchecked Sendable, Equatable {
    let backingIdentity: SealedMediaBackingIdentity
    let byteRange: AudioServiceByteRange
    let digest: Data
    let reportIdentity: UUID
    let aacMediaMembershipLeaf: AACMediaMembershipLeaf?
    fileprivate let capabilityIdentity: UUID
    fileprivate let relayIdentity: UUID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backingIdentity == rhs.backingIdentity
            && lhs.byteRange == rhs.byteRange
            && lhs.digest == rhs.digest
            && lhs.reportIdentity == rhs.reportIdentity
            && lhs.aacMediaMembershipLeaf == rhs.aacMediaMembershipLeaf
            && lhs.capabilityIdentity == rhs.capabilityIdentity
            && lhs.relayIdentity == rhs.relayIdentity
    }
}

enum SegmentReportRelayReceiveResult: Sendable, Equatable {
    case accepted(SegmentCallbackAcceptance)
    case discarded
    case fatal(SegmentReportRelayFailure)
}

/// 一个未发布逻辑段的唯一释放权；错误 relay、错误序号和重复释放都失败关闭。
final class UnpublishedLogicalSegmentLease: @unchecked Sendable {
    fileprivate let identity: UUID
    fileprivate let relayIdentity: UUID
    let logicalSequence: UInt64

    fileprivate init(identity: UUID, relayIdentity: UUID, logicalSequence: UInt64) {
        self.identity = identity
        self.relayIdentity = relayIdentity
        self.logicalSequence = logicalSequence
    }
}

final class SegmentReportRelay: @unchecked Sendable {
    private final class PublicationOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var body: (@Sendable () -> Void)?

        init(body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func run() {
            let claimed = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { body = nil }
                return body
            }
            claimed?()
        }
    }

    private struct Reservation {
        let binding: FMP4WriterBinding
        let kind: SealedMediaObjectKind
        let logicalSequence: UInt64
        let projectedByteCount: Int
    }

    private struct UnpublishedEntry {
        let logicalSequence: UInt64
        let byteCount: Int
    }

    private let lock = NSLock()
    private let identity = UUID()
    private let limits: FMP4WriterLimits
    private let capacity: Int
    private let objectSink: @Sendable (SealedMediaObject) -> Void
    private var binding: FMP4WriterBinding
    private var nextTicket: UInt64 = 1
    private var reservations: [SegmentCallbackTicket: Reservation] = [:]
    private var writerBacklogBytes = 0
    private var unpublished: [UUID: UnpublishedEntry] = [:]
    private var unpublishedSequences: Set<UInt64> = []
    private var publicationCapabilities: [UUID: SealedMediaObject] = [:]
    private var storeTransfers: [SealedMediaBackingIdentity: SealedMediaObject] = [:]
    private var publicationsAreOpen = true
    private var mediaSealedObjectBytes = 0
    private var initializationSealedObjectBytes = 0
    private var publicationSource: SegmentedFMP4CallbackContext?
    private var drainReceipt: WriterPublicationDrainReceipt?
    private var drainObserver: (@Sendable (WriterPublicationDrainReceipt) -> Void)?
    private var drainObserverInstalled = false
    private var drainWaiter: CheckedContinuation<WriterPublicationDrainReceipt?, Never>?

    /// init 不占 media reservation，且有独立固定字节上限。
    private static let initializationByteHardCount = 1 * 1_024 * 1_024

    init(
        binding: FMP4WriterBinding,
        limits: FMP4WriterLimits,
        capacity: Int,
        objectSink: @escaping @Sendable (SealedMediaObject) -> Void
    ) {
        precondition(capacity > 0)
        self.binding = binding
        self.limits = limits
        self.capacity = capacity
        self.objectSink = objectSink
    }

    var usage: SegmentReportRelayUsage {
        lock.withLock { usageInLock }
    }

    func bindPublicationSource(_ source: SegmentedFMP4CallbackContext) throws {
        try lock.withLock {
            guard publicationSource == nil, source.belongs(to: self), source.binding == binding else {
                throw SegmentReportRelayFailure.callbackIdentityMismatch
            }
            publicationSource = source
        }
    }
    func canObservePublicationDrain(source: SegmentedFMP4CallbackContext) -> Bool {
        lock.withLock { publicationSource === source && !drainObserverInstalled }
    }
    @discardableResult
    func observePublicationDrain(source: SegmentedFMP4CallbackContext,
        _ observer: @escaping @Sendable (WriterPublicationDrainReceipt) -> Void) -> Bool {
        let installed = lock.withLock {
            guard publicationSource === source, !drainObserverInstalled else { return false }
            drainObserverInstalled = true; drainObserver = observer
            return true
        }
        if installed { notifyPublicationDrainIfReady() }
        return installed
    }
    func accepts(_ receipt: WriterPublicationDrainReceipt, source: SegmentedFMP4CallbackContext) -> Bool {
        lock.withLock { drainReceipt === receipt && receipt.source === source && receipt.belongs(to: identity) }
    }
    /// publisher 保留唯一 observer；rollover 仅能另挂一个有界 waiter，并取得同一份
    /// relay 私签 receipt。receipt 已产生时直接返回，不重新签发或夺走 retire 通知。
    func waitForPublicationDrain(
        source: SegmentedFMP4CallbackContext
    ) async -> WriterPublicationDrainReceipt? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<WriterPublicationDrainReceipt?, Never>) in
            let immediate = lock.withLock { () -> WriterPublicationDrainReceipt?? in
                guard publicationSource === source else { return .some(nil) }
                if let drainReceipt { return .some(drainReceipt) }
                guard drainWaiter == nil else { return .some(nil) }
                drainWaiter = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else {
                notifyPublicationDrainIfReady()
            }
        }
    }
    /// 锁内只签发固定一份能力；回调必须在 relay 锁外，避免反向进入 publisher 锁域。
    func notifyPublicationDrainIfReady() {
        let delivery = lock.withLock { () -> (
            (@Sendable (WriterPublicationDrainReceipt) -> Void)?,
            CheckedContinuation<WriterPublicationDrainReceipt?, Never>?,
            WriterPublicationDrainReceipt
        )? in
            guard let source = publicationSource else { return nil }
            guard source.isTerminal, !publicationsAreOpen,
                  reservations.isEmpty, publicationCapabilities.isEmpty, storeTransfers.isEmpty,
                  unpublished.isEmpty, unpublishedSequences.isEmpty, writerBacklogBytes == 0,
                  mediaSealedObjectBytes == 0, initializationSealedObjectBytes == 0 else { return nil }
            if drainReceipt == nil { drainReceipt = WriterPublicationDrainReceipt(source: source, relayIdentity: identity) }
            guard drainObserver != nil || drainWaiter != nil else { return nil }
            let observer = drainObserver
            let waiter = drainWaiter
            drainObserver = nil
            drainWaiter = nil
            return (observer, waiter, drainReceipt!)
        }
        if let (observer, waiter, receipt) = delivery {
            observer?(receipt)
            waiter?.resume(returning: receipt)
        }
    }

    func canReserve(projectedByteCount: Int) -> Bool {
        lock.withLock {
            guard projectedByteCount >= 0,
                  mediaReservationCount < capacity,
                  mediaReservationCount < limits.writerHardSegmentCount else { return false }
            let backlog = writerBacklogBytes.addingReportingOverflow(projectedByteCount)
            guard !backlog.overflow else { return false }
            let total = backlog.partialValue.addingReportingOverflow(mediaSealedObjectBytes)
            return !total.overflow && total.partialValue <= limits.writerHardByteCount
        }
    }

    func reserve(
        kind: SealedMediaObjectKind,
        logicalSequence: UInt64,
        projectedByteCount: Int
    ) throws -> SegmentCallbackTicket {
        try lock.withLock {
            guard projectedByteCount >= 0 else { throw SegmentReportRelayFailure.arithmeticOverflow }
            let mediaCount = mediaReservationCount
            guard kind == .initialization || mediaCount < capacity else {
                throw SegmentReportRelayFailure.controlCapacityExceeded
            }
            guard kind == .initialization || mediaCount < limits.writerHardSegmentCount else {
                throw SegmentReportRelayFailure.writerHardCapacityExceeded
            }
            if kind == .initialization,
               reservations.values.contains(where: { $0.kind == .initialization }) {
                throw SegmentReportRelayFailure.controlCapacityExceeded
            }
            let backlog: (partialValue: Int, overflow: Bool)
            if kind == .media {
                backlog = writerBacklogBytes.addingReportingOverflow(projectedByteCount)
                guard !backlog.overflow else { throw SegmentReportRelayFailure.arithmeticOverflow }
                let total = backlog.partialValue.addingReportingOverflow(mediaSealedObjectBytes)
                guard !total.overflow else { throw SegmentReportRelayFailure.arithmeticOverflow }
                guard total.partialValue <= limits.writerHardByteCount else {
                    throw SegmentReportRelayFailure.writerHardCapacityExceeded
                }
            } else {
                guard projectedByteCount <= Self.initializationByteHardCount else {
                    throw SegmentReportRelayFailure.writerHardCapacityExceeded
                }
                backlog = (writerBacklogBytes, false)
            }
            guard nextTicket != UInt64.max else { throw SegmentReportRelayFailure.arithmeticOverflow }
            let ticket = SegmentCallbackTicket(rawValue: nextTicket)
            nextTicket += 1
            reservations[ticket] = Reservation(
                binding: binding,
                kind: kind,
                logicalSequence: logicalSequence,
                projectedByteCount: projectedByteCount
            )
            if kind == .media { writerBacklogBytes = backlog.partialValue }
            return ticket
        }
    }

    @discardableResult
    func receive(_ delivery: SegmentCallbackDelivery) -> SegmentReportRelayReceiveResult {
        let decision: Result<
            (object: SealedMediaObject, capabilityIdentity: UUID),
            SegmentReportRelayFailure
        >? = lock.withLock {
            guard let reservation = reservations.removeValue(forKey: delivery.ticket) else {
                return nil
            }
            if reservation.kind == .media { writerBacklogBytes -= reservation.projectedByteCount }
            guard reservation.binding == binding,
                  delivery.binding == binding,
                  delivery.writerIdentity == binding.writerIdentity,
                  delivery.binding.writerIdentity == binding.writerIdentity,
                  delivery.logicalSequence == reservation.logicalSequence,
                  delivery.kind == reservation.kind else {
                return .failure(.callbackIdentityMismatch)
            }
            guard publicationsAreOpen,
                  publicationCapabilities.count < capacity + 1 else {
                return .failure(.controlCapacityExceeded)
            }
            let actual = delivery.bytes.length
            var nextInitializationBytes: Int?
            var nextMediaBytes: Int?
            switch delivery.kind {
            case .initialization:
                guard actual <= Self.initializationByteHardCount else {
                    return .failure(.writerHardCapacityExceeded)
                }
                let total = initializationSealedObjectBytes.addingReportingOverflow(actual)
                guard !total.overflow else { return .failure(.arithmeticOverflow) }
                nextInitializationBytes = total.partialValue
            case .media:
                let withSealed = writerBacklogBytes.addingReportingOverflow(mediaSealedObjectBytes)
                let total = withSealed.partialValue.addingReportingOverflow(actual)
                guard !withSealed.overflow, !total.overflow else {
                    return .failure(.arithmeticOverflow)
                }
                guard total.partialValue <= limits.writerHardByteCount else {
                    return .failure(.writerHardCapacityExceeded)
                }
                nextMediaBytes = mediaSealedObjectBytes.addingReportingOverflow(actual).partialValue
            }

            var publicationLease: UnpublishedLogicalSegmentLease?
            if delivery.kind == .media {
                guard unpublished.count < 8 else {
                    return .failure(.unpublishedHardCapacityExceeded)
                }
                guard !unpublishedSequences.contains(delivery.logicalSequence) else {
                    return .failure(.duplicateLogicalSequence)
                }
                let leaseIdentity = UUID()
                unpublished[leaseIdentity] = UnpublishedEntry(
                    logicalSequence: delivery.logicalSequence,
                    byteCount: actual
                )
                unpublishedSequences.insert(delivery.logicalSequence)
                publicationLease = UnpublishedLogicalSegmentLease(
                    identity: leaseIdentity,
                    relayIdentity: identity,
                    logicalSequence: delivery.logicalSequence
                )
            }
            if let nextInitializationBytes {
                initializationSealedObjectBytes = nextInitializationBytes
            }
            if let nextMediaBytes { mediaSealedObjectBytes = nextMediaBytes }
            let object = SealedMediaObject(
                binding: binding,
                writerIdentity: delivery.writerIdentity,
                callbackTicket: delivery.ticket,
                logicalSequence: delivery.logicalSequence,
                kind: delivery.kind,
                sourceBytes: delivery.bytes,
                report: delivery.report,
                publicationLease: publicationLease,
                publicationEvidence: delivery.publicationEvidence
            )
            let capabilityIdentity = UUID()
            publicationCapabilities[capabilityIdentity] = object
            return .success((object, capabilityIdentity))
        }
        guard let decision else { return .discarded }
        switch decision {
        case let .success(value):
            let object = value.object
            return .accepted(SegmentCallbackAcceptance(
                backingIdentity: object.backing.identity,
                byteRange: object.byteRange,
                digest: object.digest,
                reportIdentity: object.report.identity,
                aacMediaMembershipLeaf: AACMediaMembershipLeaf(object),
                capabilityIdentity: value.capabilityIdentity,
                relayIdentity: identity
            ))
        case let .failure(failure):
            return .fatal(failure)
        }
    }

    /// 原子领取一次性 capability；即便调度器重复执行 closure，sink 也只会收到一次。
    @discardableResult
    func consumePublication(
        _ acceptance: SegmentCallbackAcceptance,
        schedule: (@escaping @Sendable () -> Void) -> Void
    ) -> Bool {
        let object = lock.withLock { () -> SealedMediaObject? in
            guard publicationsAreOpen,
                  acceptance.relayIdentity == identity,
                  let object = publicationCapabilities.removeValue(
                    forKey: acceptance.capabilityIdentity
                  ),
                  object.backing.identity == acceptance.backingIdentity,
                  object.byteRange == acceptance.byteRange,
                  object.digest == acceptance.digest,
                  object.report.identity == acceptance.reportIdentity else {
                return nil
            }
            storeTransfers[object.backing.identity] = object
            return object
        }
        guard let object else { return false }
        let operation = PublicationOperation { [objectSink] in objectSink(object) }
        schedule { operation.run() }
        return true
    }

    /// writer 进入真实终态后撤销尚未领取的 capability。
    func closePublications() {
        lock.withLock {
            guard publicationsAreOpen else { return }
            publicationsAreOpen = false
            for object in publicationCapabilities.values {
                switch object.kind {
                case .initialization:
                    initializationSealedObjectBytes -= object.byteRange.length
                case .media:
                    if let lease = object.publicationLease {
                        _ = releaseUnpublishedLogicalSegmentInLock(lease)
                    }
                }
            }
            publicationCapabilities.removeAll(keepingCapacity: true)
        }
        notifyPublicationDrainIfReady()
    }

    @discardableResult
    func discard(_ ticket: SegmentCallbackTicket) -> Bool {
        lock.withLock {
            guard let reservation = reservations.removeValue(forKey: ticket) else { return false }
            if reservation.kind == .media { writerBacklogBytes -= reservation.projectedByteCount }
            return true
        }
    }

    func discardAll() {
        lock.withLock {
            reservations.removeAll(keepingCapacity: true)
            writerBacklogBytes = 0
        }
    }

    @discardableResult
    func rebind(to binding: FMP4WriterBinding) -> Bool {
        lock.withLock {
            guard binding != self.binding else { return false }
            self.binding = binding
            return true
        }
    }

    func reserveUnpublishedLogicalSegment(
        logicalSequence: UInt64
    ) throws -> UnpublishedLogicalSegmentLease {
        try lock.withLock {
            guard unpublished.count < 8 else {
                throw SegmentReportRelayFailure.unpublishedHardCapacityExceeded
            }
            guard !unpublishedSequences.contains(logicalSequence) else {
                throw SegmentReportRelayFailure.duplicateLogicalSequence
            }
            let leaseIdentity = UUID()
            unpublished[leaseIdentity] = UnpublishedEntry(
                logicalSequence: logicalSequence,
                byteCount: 0
            )
            unpublishedSequences.insert(logicalSequence)
            return UnpublishedLogicalSegmentLease(
                identity: leaseIdentity,
                relayIdentity: identity,
                logicalSequence: logicalSequence
            )
        }
    }

    @discardableResult
    func releaseUnpublishedLogicalSegment(
        _ lease: UnpublishedLogicalSegmentLease
    ) -> Bool {
        let released = lock.withLock { releaseUnpublishedLogicalSegmentInLock(lease) }
        notifyPublicationDrainIfReady()
        return released
    }

    /// 只接管已由正式 capability 交出的准确对象；接收事务失败时保留原释放权和账本。
    /// publisher/store 必须先持有自己的共同域，relay 不从锁内反向调用 publisher。
    func transferToStore(_ object: SealedMediaObject, receiving: () throws -> Void) throws {
        try Self.transferBatchToStore([(self, object)], receiving: receiving)
    }

    /// 固定最多四条 init 的完整交接；按稳定 relay 身份取锁，所有预检成功后才搬账。
    static func transferBatchToStore(_ inputs: [(SegmentReportRelay, SealedMediaObject)],
                                     receiving: () throws -> Void) throws {
        guard (1...4).contains(inputs.count), Set(inputs.map { $0.1.backing.identity }).count == inputs.count else {
            throw HLSPublicationFailure.identityMismatch
        }
        let relays = Dictionary(inputs.map { ($0.0.identity, $0.0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.identity.uuidString < $1.identity.uuidString }
        for relay in relays { relay.lock.lock() }
        defer {
            for relay in relays.reversed() { relay.lock.unlock() }
            for relay in relays { relay.notifyPublicationDrainIfReady() }
        }
        for (relay, object) in inputs { try relay.validateStoreTransferInLock(object) }
        try receiving()
        for (relay, object) in inputs {
            if let lease = object.publicationLease { _ = relay.releaseUnpublishedLogicalSegmentInLock(lease) }
            else { relay.initializationSealedObjectBytes -= object.backing.bytes.count }
            relay.storeTransfers.removeValue(forKey: object.backing.identity)
        }
    }

    private func validateStoreTransferInLock(_ object: SealedMediaObject) throws {
        guard let owned = storeTransfers[object.backing.identity],
              try FMP4ObjectIdentity(owned) == FMP4ObjectIdentity(object),
              owned.publicationLease === object.publicationLease else { throw HLSPublicationFailure.identityMismatch }
        if object.kind == .media {
            guard let lease = object.publicationLease, lease.relayIdentity == identity,
                  let entry = unpublished[lease.identity], entry.logicalSequence == object.logicalSequence,
                  entry.byteCount == object.backing.bytes.count else { throw HLSPublicationFailure.identityMismatch }
        }
    }

    /// retirement fence 后的迟到 callback 只撤销本对象所有权，不能访问 successor。
    @discardableResult
    func releaseForControl(_ object: SealedMediaObject) -> Bool {
        do { try transferToStore(object, receiving: {}); return true }
        catch { return false }
    }

    private func releaseUnpublishedLogicalSegmentInLock(
        _ lease: UnpublishedLogicalSegmentLease
    ) -> Bool {
        guard lease.relayIdentity == identity,
              let entry = unpublished[lease.identity],
              entry.logicalSequence == lease.logicalSequence else { return false }
        unpublished.removeValue(forKey: lease.identity)
        unpublishedSequences.remove(entry.logicalSequence)
        mediaSealedObjectBytes -= entry.byteCount
        if let key = storeTransfers.first(where: { $0.value.publicationLease === lease })?.key {
            storeTransfers.removeValue(forKey: key)
        }
        return true
    }

    private var usageInLock: SegmentReportRelayUsage {
        SegmentReportRelayUsage(
            reservedSlots: reservations.count,
            writerBacklogSegmentCount: mediaReservationCount,
            writerBacklogBytes: writerBacklogBytes,
            publicationCapabilityCount: publicationCapabilities.count,
            initializationSealedObjectByteCount: initializationSealedObjectBytes,
            mediaSealedObjectByteCount: mediaSealedObjectBytes,
            sealedObjectByteCount: mediaSealedObjectBytes + initializationSealedObjectBytes,
            unpublishedLogicalSegmentCount: unpublished.count,
            shouldBackpressureWriter: mediaReservationCount >= limits.writerSoftSegmentCount
                || writerBacklogBytes >= limits.writerSoftByteCount,
            shouldBackpressurePublication: unpublished.count >= 4
        )
    }

    private var mediaReservationCount: Int {
        reservations.values.reduce(into: 0) { count, reservation in
            if reservation.kind == .media { count += 1 }
        }
    }
}
