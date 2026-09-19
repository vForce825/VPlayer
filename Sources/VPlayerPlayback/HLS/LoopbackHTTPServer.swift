// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import CoreMedia
import Darwin
import Foundation
import Network

struct LoopbackStorageLayout: Sendable {
    static let current = Self()
    let decodeSampleStride = MemoryLayout<SealedDecodeSampleEntry>.stride
    let initEvidenceAllocationBytes = 16 * 1_024
    let initMaximumBodyBytes = 48 * 1_024
    let stagingPayloadBytes = 64 * 1_024
    let stagingAllocationBytes = Int(malloc_good_size(64 * 1_024))
    let parserWireStorageBytes = LoopbackRequestParser.fixedStorageBytes
    var parserAllocationBytes: Int {
        Int(malloc_good_size(parserWireStorageBytes))
    }
    let coverageAccumulatorAllocationBytes = 64 * 1_024
    let coverageAccumulatorDependencyCapacity = 16
    let coverageAccumulatorRangeCapacity = 64
    let aacHTTPFinalizationMetadataBytes = 8 * 1_024
    let serverHardApplicationBytes = 128 * 1_048_576
    let httpSoftTemporaryBytes = 576 * 1_024
    let httpHardTemporaryBytes = 768 * 1_024

    func decodeMapAllocation(sampleCount: Int, commonSpanCount: Int) throws -> Int {
        guard (1...256).contains(sampleCount), (0...48).contains(commonSpanCount) else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        let samples = try HLSChecked.multiply(sampleCount, decodeSampleStride)
        let spans = try HLSChecked.multiply(commonSpanCount, MemoryLayout<Range<Int>>.stride)
        let raw = try HLSChecked.add(MemoryLayout<SealedDecodeCoverageMap>.stride,
                                     try HLSChecked.add(samples, spans))
        let rounded = (try HLSChecked.add(raw, 15)) & ~15
        guard rounded <= 32 * 1_024 else { throw CompletedMediaEvidenceError.capacityExceeded }
        return rounded
    }
}

enum LoopbackHTTPReservationError: Error, Equatable {
    case backpressure
    case hardCapacityExceeded
}

/// server/rendition 生命周期的固定 AAC HTTP 终态元数据账。server、observer 与
/// 已排队尾沿共享同一 lease；只有最后一个真实 alias 析构时才归还全局 delivery 账。
final class AACHTTPFinalizationChargeLease: @unchecked Sendable {
    let reservation: PlaybackApplicationChargeReservation
    private let ledger: HLSDeliveryApplicationChargeLedger

    init(bytes: Int, ledger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        self.ledger = ledger
        reservation = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: bytes)
    }

    deinit { ledger.release(reservation) }
}


final class PlaybackResourceContextReservation: @unchecked Sendable {
    fileprivate var allocationIdentity: PlaybackApplicationAllocationIdentity
    fileprivate let bytes: Int
    fileprivate weak var ledger: PlaybackResourceContextLedger?
    fileprivate var isActive = true

    fileprivate init(allocationIdentity: PlaybackApplicationAllocationIdentity, bytes: Int,
                     ledger: PlaybackResourceContextLedger) {
        self.allocationIdentity = allocationIdentity
        self.bytes = bytes
        self.ledger = ledger
    }

    deinit { ledger?.release(self) }
}

/// backend/bundle应用对象的进程级统一局部账；全局charge仍进入唯一application ledger。
final class PlaybackResourceContextLedger: @unchecked Sendable {
    private struct AllocationEntry {
        var identity: PlaybackApplicationAllocationIdentity?
        var bytes = 0
        var references: UInt8 = 0
        var applicationReservation: PlaybackApplicationChargeReservation?
    }

    static let softBytes = 96 * 1_024
    static let hardBytes = 128 * 1_024
    static let maximumAllocationCount = 30
    static let maximumReservationCount = 64
    /// 覆盖统一账本对象、锁、30槽allocation表及bootstrap两级token。
    static let bootstrapBytes = 2 * 1_024
    static let shared: PlaybackResourceContextLedger = {
        let applicationLedger = HLSDeliveryApplicationChargeLedger.shared
        let identity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let applicationReservation = try! applicationLedger.reserve(
            allocationIdentity: identity, bytes: bootstrapBytes)
        let ledger = PlaybackResourceContextLedger(applicationLedger: applicationLedger)
        ledger.installBootstrapEscrow(identity: identity,
                                      applicationReservation: applicationReservation)
        return ledger
    }()

    private let lock = NSLock()
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private let allocations: UnsafeMutablePointer<AllocationEntry>
    private var allocationCount = 0
    private var activeReservationCount = 0
    private var maximum = 0
    private var bootstrapReservation: PlaybackResourceContextReservation?

    init(applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) {
        self.applicationLedger = applicationLedger
        allocations = .allocate(capacity: Self.maximumAllocationCount)
        allocations.initialize(repeating: AllocationEntry(),
                               count: Self.maximumAllocationCount)
    }

    deinit {
        allocations.deinitialize(count: Self.maximumAllocationCount)
        allocations.deallocate()
    }

    /// 全局reserve先于本ledger及固定表制造；这里接管原token并绑定真实identity。
    private func installBootstrapEscrow(
        identity: PlaybackApplicationAllocationIdentity,
        applicationReservation: PlaybackApplicationChargeReservation
    ) {
        precondition(bootstrapReservation == nil)
        allocations[0] = AllocationEntry(identity: identity, bytes: Self.bootstrapBytes,
            references: 1, applicationReservation: applicationReservation)
        allocationCount = 1
        activeReservationCount = 1
        maximum = Self.bootstrapBytes
        let reservation = PlaybackResourceContextReservation(
            allocationIdentity: identity, bytes: Self.bootstrapBytes, ledger: self)
        bootstrapReservation = reservation
        do { try rebind(reservation, to: .object(ObjectIdentifier(self))) }
        catch { preconditionFailure("resource-context bootstrap绑定失败: \(error)") }
    }

    private func index(of identity: PlaybackApplicationAllocationIdentity) -> Int? {
        (0..<Self.maximumAllocationCount).first { allocations[$0].identity == identity }
    }

    private func freeAllocationIndex() -> Int? {
        (0..<Self.maximumAllocationCount).first { allocations[$0].identity == nil }
    }

    private var chargedBytesLocked: Int {
        (0..<Self.maximumAllocationCount).reduce(0) { $0 + allocations[$1].bytes }
    }

    var chargedBytes: Int { lock.withLock { chargedBytesLocked } }
    var maximumChargedBytes: Int { lock.withLock { maximum } }
    var shouldBackpressure: Bool { chargedBytes >= Self.softBytes }
    var bootstrapActualBytes: Int {
        let object = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let lockObject = UnsafeRawPointer(Unmanaged.passUnretained(lock).toOpaque())
        return malloc_size(object) + malloc_size(lockObject)
            + malloc_size(UnsafeRawPointer(allocations))
            + malloc_good_size(class_getInstanceSize(PlaybackResourceContextReservation.self))
            + malloc_good_size(class_getInstanceSize(PlaybackApplicationChargeReservation.self))
    }

    func reserve(allocationIdentity: PlaybackApplicationAllocationIdentity, bytes: Int) throws
        -> PlaybackResourceContextReservation { try lock.withLock {
        guard bytes >= 0 else { throw LoopbackHTTPReservationError.hardCapacityExceeded }
        guard activeReservationCount < Self.maximumReservationCount else {
            throw LoopbackHTTPReservationError.hardCapacityExceeded
        }
        activeReservationCount += 1
        var retainedSlot = false
        defer { if !retainedSlot { activeReservationCount -= 1 } }
        if let index = index(of: allocationIdentity) {
            guard allocations[index].bytes == bytes,
                  allocations[index].references < .max else {
                throw LoopbackHTTPReservationError.hardCapacityExceeded
            }
            allocations[index].references += 1
            let reservation = PlaybackResourceContextReservation(
                allocationIdentity: allocationIdentity, bytes: bytes, ledger: self)
            retainedSlot = true
            return reservation
        }
        guard allocationCount < Self.maximumAllocationCount,
              let freeIndex = freeAllocationIndex() else {
            throw LoopbackHTTPReservationError.hardCapacityExceeded
        }
        let currentBytes = chargedBytesLocked
        let projected = try HLSChecked.add(currentBytes, bytes)
        guard projected <= Self.hardBytes else {
            throw LoopbackHTTPReservationError.hardCapacityExceeded
        }
        guard currentBytes < Self.softBytes else { throw LoopbackHTTPReservationError.backpressure }
        let global = try applicationLedger.reserve(
            allocationIdentity: allocationIdentity, bytes: bytes)
        let reservation = PlaybackResourceContextReservation(
            allocationIdentity: allocationIdentity, bytes: bytes, ledger: self)
        allocations[freeIndex] = AllocationEntry(identity: allocationIdentity, bytes: bytes,
            references: 1, applicationReservation: global)
        allocationCount += 1
        maximum = max(maximum, projected)
        retainedSlot = true
        return reservation
    } }

    func release(_ reservation: PlaybackResourceContextReservation) { lock.withLock {
        guard reservation.ledger === self, reservation.isActive,
              let index = index(of: reservation.allocationIdentity) else { return }
        reservation.isActive = false
        reservation.ledger = nil
        activeReservationCount -= 1
        if allocations[index].references == 1 {
            if let global = allocations[index].applicationReservation {
                applicationLedger.release(global)
            }
            allocations[index] = AllocationEntry()
            allocationCount -= 1
        } else {
            allocations[index].references -= 1
        }
    } }

    func rebind(_ reservation: PlaybackResourceContextReservation,
                to allocationIdentity: PlaybackApplicationAllocationIdentity) throws {
        try lock.withLock {
            guard reservation.ledger === self, reservation.isActive,
                  let oldIndex = index(of: reservation.allocationIdentity) else {
                throw LoopbackHTTPReservationError.hardCapacityExceeded
            }
            guard reservation.allocationIdentity != allocationIdentity else { return }
            if let targetIndex = index(of: allocationIdentity) {
                guard allocations[targetIndex].bytes == reservation.bytes,
                      allocations[targetIndex].references < .max else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
                allocations[targetIndex].references += 1
                if allocations[oldIndex].references == 1 {
                    if let global = allocations[oldIndex].applicationReservation {
                        applicationLedger.release(global)
                    }
                    allocations[oldIndex] = AllocationEntry()
                    allocationCount -= 1
                } else { allocations[oldIndex].references -= 1 }
            } else if allocations[oldIndex].references == 1 {
                guard let global = allocations[oldIndex].applicationReservation else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
                try applicationLedger.rebind(global, to: allocationIdentity)
                allocations[oldIndex].identity = allocationIdentity
            } else {
                guard allocationCount < Self.maximumAllocationCount,
                      let freeIndex = freeAllocationIndex() else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
                let global = try applicationLedger.reserve(
                    allocationIdentity: allocationIdentity, bytes: reservation.bytes)
                allocations[oldIndex].references -= 1
                allocations[freeIndex] = AllocationEntry(identity: allocationIdentity,
                    bytes: reservation.bytes, references: 1,
                    applicationReservation: global)
                allocationCount += 1
                maximum = max(maximum, chargedBytesLocked)
            }
            reservation.allocationIdentity = allocationIdentity
        }
    }
}

struct LoopbackHTTPReservationUsage: Sendable {
    let distinctBackingBytes: Int
    let distinctBackingCount: Int
    let backingReferenceCount: Int
}

final class LoopbackHTTPBackingReservation: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate let backingIdentity: SealedMediaBackingIdentity
    fileprivate let bytes: Int
    fileprivate let applicationReservation: PlaybackApplicationChargeReservation
    fileprivate init(backingIdentity: SealedMediaBackingIdentity, bytes: Int,
                     applicationReservation: PlaybackApplicationChargeReservation) {
        self.backingIdentity = backingIdentity
        self.bytes = bytes
        self.applicationReservation = applicationReservation
    }
}

/// 服务器与独立容量验证共用同一个真实 backing identity 账本。
final class LoopbackHTTPReservationLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private let permitsSoftCapacitySaturation: Bool
    private var entries: [SealedMediaBackingIdentity: (bytes: Int, references: Int)] = [:]
    private var reservations: [UUID: LoopbackHTTPBackingReservation] = [:]

    init(applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
         testing: LoopbackHTTPTestingCapability? = nil) {
        self.applicationLedger = applicationLedger
        permitsSoftCapacitySaturation = testing != nil
    }

    var usage: LoopbackHTTPReservationUsage { lock.withLock {
        .init(distinctBackingBytes: entries.values.reduce(0) { $0 + $1.bytes },
              distinctBackingCount: entries.count,
              backingReferenceCount: entries.values.reduce(0) { $0 + $1.references })
    } }

    func additionalBytes(for identity: SealedMediaBackingIdentity, bytes: Int) -> Int {
        lock.withLock { entries[identity] == nil ? bytes : 0 }
    }

    func reserve(backing: SealedMediaBacking) throws -> LoopbackHTTPBackingReservation? {
        try reserve(identity: backing.identity, bytes: backing.bytes.count)
    }

    func reserve(identity: SealedMediaBackingIdentity,
                 bytes: Int) throws -> LoopbackHTTPBackingReservation? { try lock.withLock {
        guard bytes >= 0 else { throw LoopbackHTTPReservationError.hardCapacityExceeded }
        if let entry = entries[identity] {
            guard entry.bytes == bytes else { throw LoopbackHTTPReservationError.hardCapacityExceeded }
            let global: PlaybackApplicationChargeReservation
            do {
                global = try applicationLedger.reserve(
                    allocationIdentity: identity.rawValue, bytes: bytes)
            } catch LoopbackHTTPReservationError.backpressure {
                return nil
            }
            let reservation = LoopbackHTTPBackingReservation(backingIdentity: identity, bytes: bytes,
                applicationReservation: global)
            entries[identity] = (entry.bytes, entry.references + 1)
            reservations[reservation.identity] = reservation
            return reservation
        }
        let current = entries.values.reduce(0) { $0 + $1.bytes }
        let projected = try HLSChecked.add(current, bytes)
        if projected > 128 * 1_048_576 { throw LoopbackHTTPReservationError.hardCapacityExceeded }
        guard permitsSoftCapacitySaturation || projected < 96 * 1_048_576 else { return nil }
        let global: PlaybackApplicationChargeReservation
        do {
            global = try applicationLedger.reserve(
                allocationIdentity: identity.rawValue, bytes: bytes)
        } catch LoopbackHTTPReservationError.backpressure {
            return nil
        }
        let reservation = LoopbackHTTPBackingReservation(backingIdentity: identity, bytes: bytes,
            applicationReservation: global)
        entries[identity] = (bytes, 1)
        reservations[reservation.identity] = reservation
        return reservation
    } }

    func release(_ reservation: LoopbackHTTPBackingReservation) { lock.withLock {
        guard reservations.removeValue(forKey: reservation.identity) != nil,
              let entry = entries[reservation.backingIdentity] else { return }
        applicationLedger.release(reservation.applicationReservation)
        if entry.references == 1 { entries.removeValue(forKey: reservation.backingIdentity) }
        else { entries[reservation.backingIdentity] = (entry.bytes, entry.references - 1) }
    } }
}

struct LoopbackHTTPUsage: Sendable {
    let connections: Int
    let activeResponses: Int
    let distinctBackingBytes: Int
    let parserAndStagingBytes: Int
}

struct LoopbackAcceptedGETSnapshot: Sendable, Equatable {
    let playlistCount: Int
    let initializationCount: Int
    let mediaCount: Int
}

enum LoopbackCapacityState: Sendable, Equatable { case normal, backpressure, hardExceeded }

struct LoopbackHTTPLimits: Sendable {
    static let standard = Self()
    func classify(_ usage: LoopbackHTTPUsage) -> LoopbackCapacityState {
        let layout = LoopbackStorageLayout.current
        if usage.connections > 16 || usage.activeResponses > 8
            || usage.distinctBackingBytes > 128 * 1_048_576
            || usage.parserAndStagingBytes > layout.httpHardTemporaryBytes {
            return .hardExceeded
        }
        if usage.connections >= 12 || usage.activeResponses >= 6
            || usage.distinctBackingBytes >= 96 * 1_048_576
            || usage.parserAndStagingBytes >= layout.httpSoftTemporaryBytes {
            return .backpressure
        }
        return .normal
    }
}

enum LoopbackHTTPServerError: Error, Equatable {
    case transportUnavailable
    case invalidBinding
    case invalidConfiguration
    case randomnessUnavailable
}

struct LoopbackSocketBindingEvidence: Sendable, Equatable {
    let family: Int32
    let address: String
    let port: UInt16
    let requiredEndpointWasAudited: Bool
    let ipv6LoopbackWasRejected: Bool
    let rejectedNonLoopbackIPv4Count: Int
}

struct LoopbackPreparedPublication: @unchecked Sendable {
    let store: SealedMediaStore
    let declaration: HLSItemDeclaration
    let snapshot: HLSPublishedSnapshot
}

struct LoopbackHTTPSessionFactory: Sendable {
    private let testing: LoopbackHTTPTestingConfiguration?

    init(testing: LoopbackHTTPTestingConfiguration? = nil) {
        self.testing = testing
    }

    func start(itemGeneration: UInt64, now: @escaping @Sendable () -> Int64,
               logger: @escaping @Sendable (String) -> Void,
               responseFailure: @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void,
               prepare: (LoopbackSessionToken) throws -> LoopbackPreparedPublication) async throws -> LoopbackHTTPServer {
        try await startPreparingAsynchronously(
            itemGeneration: itemGeneration, now: now, logger: logger,
            responseFailure: responseFailure,
            prepare: { token in try prepare(token) })
    }

    /// 真实长流可以在 factory 签发 session 后继续异步产出启动窗；同步入口仍保持
    /// 原有取消/清理语义，避免调用者为等待 writer rollover 建立阻塞桥。
    func startPreparingAsynchronously(
        itemGeneration: UInt64, now: @escaping @Sendable () -> Int64,
        logger: @escaping @Sendable (String) -> Void,
        responseFailure: @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void,
        prepare: (LoopbackSessionToken) async throws -> LoopbackPreparedPublication
    ) async throws -> LoopbackHTTPServer {
        try Task.checkCancellation()
        let token: LoopbackSessionToken
        do { token = try LoopbackSessionToken.generateSystemCapability(testing: testing) }
        catch { throw LoopbackHTTPServerError.randomnessUnavailable }
        try Task.checkCancellation()
        let publication = try await prepare(token)
        do {
            try Task.checkCancellation()
            guard publication.store.itemGeneration == itemGeneration,
                  publication.store.belongs(to: token),
                  publication.declaration.itemGeneration == itemGeneration,
                  publication.declaration.token == token.value else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            return try await LoopbackHTTPServer.start(store: publication.store,
                declaration: publication.declaration, publishedSnapshot: publication.snapshot,
                sessionCapability: token, now: now, logger: logger,
                responseFailure: responseFailure, testing: testing)
        } catch {
            publication.store.close()
            throw error
        }
    }
}

final class LoopbackHTTPCleanupTicket: @unchecked Sendable {
    fileprivate let identity = UUID()
}

enum LoopbackHTTPLifecyclePhase: Sendable, Equatable { case open, closed, drained, retired }

/// 只能由真实连接在全部 `contentProcessed` 成功后签发的一次性终态能力。
final class HLSResponseSendTerminalCapability: @unchecked Sendable {
    private let lock = NSLock()
    private let leaseIdentity: UUID
    private let backingIdentity: SealedMediaBackingIdentity
    private let completedRange: Range<Int>
    private let connectionIdentity: UUID
    private let sendIdentity: UUID
    fileprivate let terminalIdentity = UUID()
    private var consumed = false

    fileprivate init(lease: HLSMediaResponseLease, connectionIdentity: UUID,
                     sendIdentity: UUID) {
        leaseIdentity = lease.terminalBindingIdentity
        backingIdentity = lease.backingIdentity
        completedRange = lease.completedRange
        self.connectionIdentity = connectionIdentity
        self.sendIdentity = sendIdentity
    }

    func consume(matching lease: HLSMediaResponseLease) -> Bool { lock.withLock {
        guard !consumed, lease.terminalBindingIdentity == leaseIdentity,
              lease.backingIdentity == backingIdentity,
              lease.completedRange == completedRange,
              connectionIdentity != UUID(), sendIdentity != UUID() else { return false }
        consumed = true
        return true
    } }
}

/// 同一 server 的不可变签发域只保存一次，历史与 selection 保留原对象身份。
private final class LoopbackPublicationOrigin: Sendable, Hashable {
    let serverIdentity: UUID
    let sessionCapabilityIdentity: UUID
    let sessionToken: String
    let port: UInt16
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: UInt64
    init(serverIdentity: UUID, sessionCapabilityIdentity: UUID, sessionToken: String,
         port: UInt16, outputLifecycleEpoch: OutputLifecycleEpoch, itemGeneration: UInt64) {
        self.serverIdentity = serverIdentity; self.sessionCapabilityIdentity = sessionCapabilityIdentity
        self.sessionToken = sessionToken; self.port = port
        self.outputLifecycleEpoch = outputLifecycleEpoch; self.itemGeneration = itemGeneration
    }
    static func == (lhs: LoopbackPublicationOrigin, rhs: LoopbackPublicationOrigin) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private protocol PreparationHistoryValue { var publicationSequence: UInt64 { get } }

private struct LoopbackPublicationAuthorityBinding: Sendable, Hashable, PreparationHistoryValue {
    let origin: LoopbackPublicationOrigin
    let publicationSequence: UInt64
    let publicationSnapshotIdentity: UUID
    var serverIdentity: UUID { origin.serverIdentity }
    var sessionCapabilityIdentity: UUID { origin.sessionCapabilityIdentity }
    var sessionToken: String { origin.sessionToken }
    var port: UInt16 { origin.port }
    var outputLifecycleEpoch: OutputLifecycleEpoch { origin.outputLifecycleEpoch }
    var itemGeneration: UInt64 { origin.itemGeneration }
}

/// 只有同一 Loopback server 的 audio media send terminal 已形成连续三秒完成窗口后
/// 才能签发。能力对象本身就是身份；复制字段不能制造新的选择权。
final class LoopbackAudioMediaSelectionCapability: @unchecked Sendable, Hashable, PreparationHistoryValue {
    private static let storageLock = PreparationStorageLock()
    nonisolated(unsafe) private static var occupiedRecords: UInt8 = 0
    fileprivate static func reserveRecord() -> Bool {
        storageLock.withLock {
            guard occupiedRecords < 14 else { return false }
            occupiedRecords += 1
            return true
        }
    }
    fileprivate static func releaseRecord() {
        storageLock.withLock {
            let next = occupiedRecords.subtractingReportingOverflow(1)
            precondition(!next.overflow, "选择 record 不可重复归还")
            occupiedRecords = next.partialValue
        }
    }
#if DEBUG
    static func inspectStorageLock(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        storageLock.inspect("owned/selection 独立 storageLock", body)
    }
#endif
    deinit {
        metadataStore.releaseSelectionMetadata(slot: metadataSlot)
        Self.releaseRecord()
        FrozenPreparationOwner.releaseAdmission(slot: admissionSlot)
        PlaybackResourceContextLedger.shared.release(resourceContextReservation)
    }
    var outputLifecycleEpoch: OutputLifecycleEpoch { authorityBinding.outputLifecycleEpoch }
    var itemGeneration: UInt64 { authorityBinding.itemGeneration }
    var publicationSequence: UInt64 { authorityBinding.publicationSequence }
    private let metadataStore: SealedMediaStore
    private let metadataSlot: UInt16
    private let admissionSlot: UInt8
    var participantID: UInt64 {
        metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.key.participantID
    }
    var renditionIdentity: AudioRenditionIdentity {
        metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.rendition
    }
    let responseLeaseIdentity: UUID
    var backingIdentity: SealedMediaBackingIdentity {
        metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.backing
    }
    var sealedDigest: Data {
        metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.digest
    }
    var completedByteRange: Range<Int> {
        0..<metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.length
    }
    var presentationRange: FMP4PresentationRange {
        metadataStore.preparationResource(slot: Int(metadataSlot), ownerSlot: 0)!.presentationRange!
    }
    private let selectionEnd: ExactMediaTime
    private let effectiveOffset: ExactMediaTime
    var selectionWindow: FMP4PresentationRange {
        let lead = ExactMediaTime(value: 3, timescale: 1)
        return try! .init(start: selectionEnd.subtracting(lead), duration: lead)
    }
    var overlap: FMP4PresentationRange {
        let physical = presentationRange
        let effective = try! FMP4PresentationRange(start: physical.start.adding(effectiveOffset),
            duration: physical.duration)
        let window = selectionWindow
        let start = CMTimeCompare(effective.start.cmTime, window.start.cmTime) >= 0
            ? effective.start : window.start
        let end = CMTimeCompare(effective.end.cmTime, window.end.cmTime) <= 0
            ? effective.end : window.end
        return try! .init(start: start, duration: end.subtracting(start))
    }
    let sendTerminalIdentity: UUID
    let nonce: UUID
    fileprivate let authorityBinding: LoopbackPublicationAuthorityBinding
    private let resourceContextReservation: PlaybackResourceContextReservation

    fileprivate init(authorityBinding: LoopbackPublicationAuthorityBinding,
                     metadataStore: SealedMediaStore, metadataSlot: UInt16,
                     admissionSlot: UInt8,
                     responseLeaseIdentity: UUID,
                     selectionEnd: ExactMediaTime,
                     effectiveOffset: ExactMediaTime,
                     sendTerminalIdentity: UUID,
                     resourceContextReservation: PlaybackResourceContextReservation) {
        self.metadataStore = metadataStore
        self.metadataSlot = metadataSlot
        self.admissionSlot = admissionSlot
        self.responseLeaseIdentity = responseLeaseIdentity
        self.selectionEnd = selectionEnd
        self.effectiveOffset = effectiveOffset
        self.sendTerminalIdentity = sendTerminalIdentity
        self.resourceContextReservation = resourceContextReservation
        nonce = UUID()
        self.authorityBinding = authorityBinding
    }

    fileprivate func belongs(to binding: LoopbackPublicationAuthorityBinding) -> Bool {
        authorityBinding == binding
    }

    fileprivate func belongs(serverIdentity: UUID,
                             sessionCapabilityIdentity: UUID,
                             port: UInt16) -> Bool {
        authorityBinding.serverIdentity == serverIdentity
            && authorityBinding.sessionCapabilityIdentity == sessionCapabilityIdentity
            && authorityBinding.port == port
    }

    static func == (lhs: LoopbackAudioMediaSelectionCapability,
                    rhs: LoopbackAudioMediaSelectionCapability) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// 不承载任何 server 权威的纯时间轴值。单元测试可以用它验证换算，
/// 但它不能放入 `PreparedPlayheadIdentity`，也不能通过 Loopback admission。
struct PlayerItemCommonSampleBoundaries: Sequence, Sendable, Equatable {
    private let owner: FrozenPreparationOwner?
    private let participantID: UInt64
    private let offset: ExactMediaTime
    private let initial: ExactMediaTime
    private let horizon: ExactMediaTime
    private let explicit: [ExactMediaTime]

    init(_ values: [ExactMediaTime]) {
        owner = nil
        participantID = 0
        offset = .init(value: 0, timescale: 1)
        initial = offset
        horizon = offset
        explicit = values
    }

    fileprivate init(evidence: some LoopbackPublicationFacts,
                     participantID: UInt64, offset: ExactMediaTime,
                     initial: ExactMediaTime, horizon: ExactMediaTime) throws {
        self.owner = evidence.preparationOwner
        self.participantID = participantID
        self.offset = offset
        self.initial = initial
        self.horizon = horizon
        explicit = []
        // 先验证所有精确加法；迭代器只投影同一不可变证据，不吞算术错误。
        for media in LoopbackCompletedResourceCollection(owner: evidence.preparationOwner,
            participantID: participantID, mode: 1) {
            _ = try media.presentationRange.start.adding(offset)
        }
    }

    var count: Int { reduce(0) { count, _ in count + 1 } }
    var isEmpty: Bool { var iterator = makeIterator(); return iterator.next() == nil }

    struct Iterator: IteratorProtocol {
        let boundaries: PlayerItemCommonSampleBoundaries
        var previous: ExactMediaTime?
        var explicitIndex = 0

        mutating func next() -> ExactMediaTime? {
            guard let owner = boundaries.owner else {
                guard explicitIndex < boundaries.explicit.count else { return nil }
                defer { explicitIndex += 1 }
                return boundaries.explicit[explicitIndex]
            }
            var candidate: ExactMediaTime?
            func consider(_ value: ExactMediaTime) {
                guard previous.map({ CMTimeCompare(value.cmTime, $0.cmTime) > 0 }) ?? true,
                      candidate.map({ CMTimeCompare(value.cmTime, $0.cmTime) < 0 }) ?? true else { return }
                candidate = value
            }
            consider(boundaries.initial)
            for media in LoopbackCompletedResourceCollection(owner: owner,
                participantID: boundaries.participantID, mode: 1) {
                let value = try! media.presentationRange.start.adding(boundaries.offset)
                if CMTimeCompare(value.cmTime, boundaries.horizon.cmTime) <= 0 {
                    consider(value)
                }
            }
            previous = candidate ?? previous
            return candidate
        }
    }

    func makeIterator() -> Iterator { Iterator(boundaries: self) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}

struct PlayerItemTimelineMapping: Sendable, Equatable {
    let effectiveSourceOrigin: ExactMediaTime
    let effectivePlaybackHorizon: ExactMediaTime
    let commonSampleBoundaries: PlayerItemCommonSampleBoundaries

    init(effectiveSourceOrigin: ExactMediaTime, effectivePlaybackHorizon: ExactMediaTime,
         commonSampleBoundaries: [ExactMediaTime]) {
        self.init(effectiveSourceOrigin: effectiveSourceOrigin,
                  effectivePlaybackHorizon: effectivePlaybackHorizon,
                  commonSampleBoundaries: PlayerItemCommonSampleBoundaries(commonSampleBoundaries))
    }

    init(effectiveSourceOrigin: ExactMediaTime, effectivePlaybackHorizon: ExactMediaTime,
         commonSampleBoundaries: PlayerItemCommonSampleBoundaries) {
        self.effectiveSourceOrigin = effectiveSourceOrigin
        self.effectivePlaybackHorizon = effectivePlaybackHorizon
        self.commonSampleBoundaries = commonSampleBoundaries
    }

    func playerItemTime(for sourceTime: ExactMediaTime) throws -> ExactMediaTime {
        let mapped = try sourceTime.subtracting(effectiveSourceOrigin)
        guard mapped.value >= 0 else { throw AVPlayerItemCoordinatorFailure.invalidTimeline }
        return mapped
    }

    func sourceTime(for playerItemTime: ExactMediaTime) throws -> ExactMediaTime {
        guard playerItemTime.value >= 0 else {
            throw AVPlayerItemCoordinatorFailure.invalidTimeline
        }
        return try effectiveSourceOrigin.adding(playerItemTime)
    }

    func latestBoundary(withLead lead: ExactMediaTime) throws -> ExactMediaTime? {
        let limit = try effectivePlaybackHorizon.subtracting(lead)
        return commonSampleBoundaries.lazy
            .filter { CMTimeCompare($0.cmTime, limit.cmTime) <= 0 }
            .max { CMTimeCompare($0.cmTime, $1.cmTime) < 0 }
    }
}

/// 由同一 Loopback publication 在 completed-response 与 writer endpoint 均验真后
/// 签发的时间轴映射。调用方只可请求映射，不能填写 source origin 或 trim offset。
struct FrozenTimelineMappingStorage: Sendable {
    let identity: UUID
    let visiblePhysicalOrigin: ExactMediaTime
    let effectiveSourceOrigin: ExactMediaTime
    let effectivePlaybackHorizon: ExactMediaTime
    let endpointAuthority: AACEffectiveEndpointAuthority?
    let prefixReceipt: AACPrefixPlaybackMappingReceipt?
}

final class PlayerItemTimelineMappingAuthority: @unchecked Sendable, Hashable {
    private let owner: FrozenPreparationOwner
    private var storage: FrozenTimelineMappingStorage { owner.timelineStorage! }
    var outputLifecycleEpoch: OutputLifecycleEpoch { selectedCapability.outputLifecycleEpoch }
    var itemGeneration: UInt64 { selectedCapability.itemGeneration }
    var publicationSequence: UInt64 { selectedCapability.publicationSequence }
    var participantID: UInt64? { selectedCapability.participantID }
    var renditionIdentity: AudioRenditionIdentity? { selectedCapability.renditionIdentity }
    var visiblePhysicalOrigin: ExactMediaTime { storage.visiblePhysicalOrigin }
    var writtenPhysicalBase: ExactMediaTime {
        aacEndpointReceipt?.writtenPhysicalBase
            ?? storage.prefixReceipt?.mapping.writtenPhysicalBase
            ?? visiblePhysicalOrigin
    }
    var writtenEffectiveBase: ExactMediaTime {
        aacEndpointReceipt?.writtenEffectiveBase
            ?? storage.prefixReceipt?.mapping.writtenEffectiveBase
            ?? visiblePhysicalOrigin
    }
    var mapping: PlayerItemTimelineMapping {
        .init(effectiveSourceOrigin: effectiveSourceOrigin, effectivePlaybackHorizon: effectivePlaybackHorizon,
            commonSampleBoundaries: commonSampleBoundaries)
    }
    var effectiveSourceOrigin: ExactMediaTime { storage.effectiveSourceOrigin }
    var effectivePlaybackHorizon: ExactMediaTime { storage.effectivePlaybackHorizon }
    var commonSampleBoundaries: PlayerItemCommonSampleBoundaries {
        let basis = LoopbackPreparationPublicationBasis(preparationOwner: owner)
        let reference = basis.participants.first(where: { $0.mediaType == .video })
            ?? basis.participants.first(where: { $0.participantID == selectedCapability.participantID })!
        let offset = reference.mediaType == .audio
            ? try! writtenEffectiveBase.subtracting(writtenPhysicalBase) : ExactMediaTime(value: 0, timescale: 1)
        return try! .init(evidence: basis, participantID: reference.participantID,
            offset: offset, initial: selectedCapability.selectionWindow.start, horizon: effectivePlaybackHorizon)
    }
    private var endpointAuthority: AACEffectiveEndpointAuthority? { storage.endpointAuthority }
    var aacEndpointReceipt: AACEffectiveEndpointReceipt? { endpointAuthority?.receipt }
    var aacPrefixReceipt: AACPrefixPlaybackMappingReceipt? { storage.prefixReceipt }

    private var identity: UUID { storage.identity }
    private var authorityBinding: LoopbackPublicationAuthorityBinding { selectedCapability.authorityBinding }
    private var selectedCapability: LoopbackAudioMediaSelectionCapability {
        owner.frozenPublication!.audioSelectionCapability!
    }

    fileprivate init(owner: FrozenPreparationOwner) {
        precondition(owner.timelineStorage != nil)
        self.owner = owner
    }

    fileprivate func matchesEndpoint(_ authority: AACEffectiveEndpointAuthority?) -> Bool {
        endpointAuthority === authority
    }

    func matchesCoverageDependencies(_ dependencies: AVPlayerCoverageDependencies,
                                    rendition: AudioRenditionIdentity) -> Bool {
        guard owner.completionIsFrozen else { return false }
        for index: UInt8 in 0..<2 {
            guard let coverage = owner.coverage(at: index), coverage.rendition == rendition else { continue }
            let original = AVPlayerCoverageDependencies(served:
                .init(storage: .frozen(owner: owner, coverageIndex: index)))
            return !original.isEmpty && original.elementsEqual(dependencies)
        }
        return false
    }

    func playerItemTime(for sourceTime: ExactMediaTime) throws -> ExactMediaTime {
        try mapping.playerItemTime(for: sourceTime)
    }

    func sourceTime(for playerItemTime: ExactMediaTime) throws -> ExactMediaTime {
        try mapping.sourceTime(for: playerItemTime)
    }

    /// completed-response decode map 使用 writer 的物理 PTS；coordinator 使用去掉
    /// AAC leading trim 后的有效 source timeline。转换只来自同一 server 签发的两个
    /// base，调用方不能提供 offset。
    fileprivate func physicalRange(
        forEffectiveSourceRange range: FMP4PresentationRange
    ) throws -> FMP4PresentationRange {
        let offset = try writtenEffectiveBase.subtracting(writtenPhysicalBase)
        let physicalStart = try range.start.subtracting(offset)
        return try FMP4PresentationRange(start: physicalStart,
                                         duration: range.duration)
    }

    func matches(
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        selection: LoopbackAudioMediaSelectionCapability?
    ) -> Bool {
        guard item.outputLifecycleEpoch == outputLifecycleEpoch,
              itemURL == owner.frozenPublication!.itemURL,
              item.outputLifecycleEpoch == authorityBinding.outputLifecycleEpoch,
              item.itemGeneration == itemGeneration,
              publicationSequence == self.publicationSequence,
              itemURL.scheme == "http",
              itemURL.host == "127.0.0.1",
              itemURL.port == Int(authorityBinding.port),
              selection === selectedCapability,
              selectedCapability.belongs(to: authorityBinding) else { return false }
        return true
    }

    fileprivate func belongs(
        to binding: LoopbackPublicationAuthorityBinding,
        selection: LoopbackAudioMediaSelectionCapability
    ) -> Bool {
        authorityBinding == binding
            && selectedCapability === selection
            && selection.belongs(to: binding)
    }

    static func == (lhs: PlayerItemTimelineMappingAuthority,
                    rhs: PlayerItemTimelineMappingAuthority) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Store 的 decode map 与 completed-response ledger 均使用封装内的物理 PTS，
/// coordinator 则只接受去除 AAC priming 后的有效 source 区间。两者必须由同一
/// server-signed timeline authority 关联，不能把物理 receipt 直接冒充有效 coverage。
struct LoopbackAVPlayerCoverageEvidence {
    let physicalReceipt: ServedRenditionCoverageReceipt
    let effectivePresentationRange: FMP4PresentationRange
}

/// timeline admission 明确区分“selection 尚未被真实 E-3...E response 签出”和
/// 永久身份冲突；evidence source 只对前者保留固定单槽 waiter。
enum LoopbackPlayerItemTimelineMappingAdmission {
    case waitingForSelection
    case invalid
    case ready(PlayerItemTimelineMappingAuthority)
}

struct LoopbackCompletedInitializationResponseEvidence: Sendable {
    let key: HLSResourceKey
    let backingIdentity: SealedMediaBackingIdentity
}

struct LoopbackCompletedMediaResponseEvidence: Sendable {
    let key: HLSResourceKey
    let backingIdentity: SealedMediaBackingIdentity
    let presentationRange: FMP4PresentationRange

    init(key: HLSResourceKey, backingIdentity: SealedMediaBackingIdentity,
                     presentationRange: FMP4PresentationRange) {
        self.key = key
        self.backingIdentity = backingIdentity
        self.presentationRange = presentationRange
    }
}

struct LoopbackFrozenParticipantDescriptor: Sendable {
    let mediaPlaylistSnapshotIdentity: UUID
    let metadataSlot: UInt16
    let mediaType: FinalFMP4MediaType
}

struct LoopbackCompletedResourceCollection: Collection, Sendable {
    let owner: FrozenPreparationOwner
    let participantID: UInt64
    var mode: UInt8 = 0 // 0：已发布完成位；1：不可变元数据；2：内部同步当前完成事实。
    var endIndex: Int { 300 }
    var startIndex: Int { nextIndex(after: -1) }
    func index(after index: Int) -> Int { nextIndex(after: index) }
    private func nextIndex(after index: Int) -> Int {
        guard index < 299 else { return endIndex }
        for candidate in (index + 1)..<300 {
            guard mode != 0 || owner.containsCompletedResource(candidate),
                  mode != 2 || owner.metadataStore?.preparationResourceIsComplete(
                    slot: candidate, ownerSlot: owner.slot) == true else { continue }
            guard let resource = owner.metadataStore?.preparationResource(
                slot: candidate, ownerSlot: owner.slot),
                  resource.key.participantID == participantID, resource.key.kind == .media,
                  resource.presentationRange != nil else {
                continue
            }
            return candidate
        }
        return endIndex
    }
    subscript(index: Int) -> LoopbackCompletedMediaResponseEvidence {
        precondition(mode != 0 || owner.containsCompletedResource(index))
        let resource = owner.metadataStore!.preparationResource(slot: index, ownerSlot: owner.slot)!
        return .init(key: resource.key, backingIdentity: resource.backing,
                     presentationRange: resource.presentationRange!)
    }
}

struct LoopbackCompletedParticipantEvidence: Sendable {
    let owner: FrozenPreparationOwner
    let descriptor: LoopbackFrozenParticipantDescriptor
    var mode: UInt8 = 0
    var participantID: UInt64 {
        owner.metadataStore!.preparationResource(slot: Int(descriptor.metadataSlot), ownerSlot: owner.slot)!.key.participantID
    }
    var renditionIdentity: AudioRenditionIdentity {
        owner.metadataStore!.preparationResource(slot: Int(descriptor.metadataSlot), ownerSlot: owner.slot)!.rendition
    }
    var mediaType: FinalFMP4MediaType { descriptor.mediaType }
    var mediaPlaylistSnapshotIdentity: UUID { descriptor.mediaPlaylistSnapshotIdentity }
    var mediaPlaylistVersion: UInt64 { owner.frozenPublication!.authorityBinding.publicationSequence }
    var completedMedia: LoopbackCompletedResourceCollection {
        .init(owner: owner, participantID: participantID, mode: mode)
    }
    var hasCompletedInitialization: Bool { containsInitializationBacking(nil) }
    func containsInitializationBacking(_ backing: SealedMediaBackingIdentity?) -> Bool {
        for index in 0..<300 {
            guard mode != 0 || owner.containsCompletedResource(index),
                  mode != 2 || owner.metadataStore?.preparationResourceIsComplete(
                    slot: index, ownerSlot: owner.slot) == true else { continue }
            guard let resource = owner.metadataStore?.preparationResource(slot: index, ownerSlot: owner.slot),
                  resource.key.participantID == participantID,
                  resource.key.kind == .initialization else { continue }
            if backing == nil || resource.backing == backing { return true }
        }
        return false
    }
}

struct LoopbackFrozenPublicationStorage: @unchecked Sendable {
    fileprivate let itemURL: URL
    fileprivate let masterPlaylistCompleted: Bool
    fileprivate let audioSelectionCapability: LoopbackAudioMediaSelectionCapability?
    fileprivate let authorityBinding: LoopbackPublicationAuthorityBinding
    fileprivate var descriptors: (LoopbackFrozenParticipantDescriptor?,
                                  LoopbackFrozenParticipantDescriptor?,
                                  LoopbackFrozenParticipantDescriptor?,
                                  LoopbackFrozenParticipantDescriptor?) = (nil, nil, nil, nil)
}

struct LoopbackCompletedParticipants: RandomAccessCollection, Sendable {
    let owner: FrozenPreparationOwner
    var mode: UInt8 = 0
    var startIndex: Int { 0 }
    var endIndex: Int {
        let value = owner.frozenPublication!.descriptors
        return value.3 != nil ? 4 : value.2 != nil ? 3 : value.1 != nil ? 2 : value.0 != nil ? 1 : 0
    }
    subscript(index: Int) -> LoopbackCompletedParticipantEvidence {
        let value = owner.frozenPublication!.descriptors
        let descriptor: LoopbackFrozenParticipantDescriptor
        switch index {
        case 0: descriptor = value.0!
        case 1: descriptor = value.1!
        case 2: descriptor = value.2!
        case 3: descriptor = value.3!
        default: preconditionFailure("冻结participant索引越界")
        }
        return .init(owner: owner, descriptor: descriptor, mode: mode)
    }
}

/// 值视图只持有原owner；重复查询不新建publication对象、数组或消费锁。
protocol LoopbackPublicationFacts: Sendable {
    var preparationOwner: FrozenPreparationOwner { get }
    var itemURL: URL { get }
    var itemGeneration: UInt64 { get }
    var publicationSequence: UInt64 { get }
    var masterPlaylistCompleted: Bool { get }
    var participants: LoopbackCompletedParticipants { get }
    var audioSelectionCapability: LoopbackAudioMediaSelectionCapability? { get }
}

/// 只供同一准备事务内部绑定/时间轴验真；不能作为已发布 completed capability 返回。
struct LoopbackPreparationPublicationBasis: LoopbackPublicationFacts {
    let preparationOwner: FrozenPreparationOwner
    private var value: LoopbackFrozenPublicationStorage { preparationOwner.frozenPublication! }
    var itemURL: URL { value.itemURL }
    var itemGeneration: UInt64 { value.authorityBinding.itemGeneration }
    var publicationSequence: UInt64 { value.authorityBinding.publicationSequence }
    var masterPlaylistCompleted: Bool { value.masterPlaylistCompleted }
    var participants: LoopbackCompletedParticipants {
        .init(owner: preparationOwner, mode: preparationOwner.completionIsFrozen ? 0 : 2)
    }
    var audioSelectionCapability: LoopbackAudioMediaSelectionCapability? { value.audioSelectionCapability }
}

struct LoopbackCompletedPublicationEvidence: LoopbackPublicationFacts {
    let preparationOwner: FrozenPreparationOwner
    var itemURL: URL { preparationOwner.frozenPublication!.itemURL }
    var itemGeneration: UInt64 { authorityBinding.itemGeneration }
    var publicationSequence: UInt64 { authorityBinding.publicationSequence }
    var masterPlaylistCompleted: Bool { preparationOwner.frozenPublication!.masterPlaylistCompleted }
    var participants: LoopbackCompletedParticipants { .init(owner: preparationOwner) }
    var audioSelectionCapability: LoopbackAudioMediaSelectionCapability? {
        preparationOwner.frozenPublication!.audioSelectionCapability
    }
    fileprivate var authorityBinding: LoopbackPublicationAuthorityBinding {
        preparationOwner.frozenPublication!.authorityBinding
    }

    fileprivate func belongs(to binding: LoopbackPublicationAuthorityBinding) -> Bool {
        authorityBinding == binding
    }

    fileprivate func belongs(serverIdentity: UUID,
                             sessionCapabilityIdentity: UUID,
                             port: UInt16) -> Bool {
        authorityBinding.serverIdentity == serverIdentity
            && authorityBinding.sessionCapabilityIdentity == sessionCapabilityIdentity
            && authorityBinding.port == port
    }
}

/// 查询只返回不可构造且单次消费的能力；值字段本身不授予 completed-response 权限。
final class LoopbackCompletedPublicationCapability: @unchecked Sendable {
    private let lock = NSLock()
    private let authorityBinding: LoopbackPublicationAuthorityBinding
    private let evidence: LoopbackCompletedPublicationEvidence
    private var consumed = false

    fileprivate init(evidence: LoopbackCompletedPublicationEvidence,
                     authorityBinding: LoopbackPublicationAuthorityBinding) {
        self.evidence = evidence
        self.authorityBinding = authorityBinding
    }

    fileprivate func consume(serverIdentity: UUID,
                             sessionCapabilityIdentity: UUID,
                             port: UInt16)
        -> LoopbackCompletedPublicationEvidence? { lock.withLock {
        guard !consumed,
              evidence.belongs(serverIdentity: serverIdentity,
                               sessionCapabilityIdentity: sessionCapabilityIdentity,
                               port: port) else {
            return nil
        }
        consumed = true
        return evidence
    } }
}

private final class LoopbackSendCompletionTracker: @unchecked Sendable {
    private let expectedRange: Range<Int>
    private let lease: HLSMediaResponseLease
    private let connectionIdentity: UUID
    private let sendIdentity = UUID()
    private var cursor: Int
    private var invalid = false

    init(lease: HLSMediaResponseLease, connectionIdentity: UUID) {
        expectedRange = lease.completedRange
        self.lease = lease
        self.connectionIdentity = connectionIdentity
        cursor = lease.completedRange.lowerBound
    }

    func registerCompletedChunk(_ range: Range<Int>) {
        guard !invalid, !range.isEmpty, range.lowerBound == cursor,
              range.upperBound <= expectedRange.upperBound else { invalid = true; return }
        cursor = range.upperBound
    }

    func terminalCapability(_ terminal: LoopbackSendTerminal)
        -> HLSResponseSendTerminalCapability? {
        guard terminal == .success, !invalid, cursor == expectedRange.upperBound else { return nil }
        return HLSResponseSendTerminalCapability(lease: lease,
            connectionIdentity: connectionIdentity, sendIdentity: sendIdentity)
    }
}

struct LoopbackHTTPRuntimeUsage: Sendable {
    let connections: Int
    let activeResponses: Int
    let distinctBackingBytes: Int
    let parserAndStagingBytes: Int
    let maximumConnections: Int
    let maximumActiveResponses: Int
    let maximumDistinctBackingBytes: Int
    let maximumParserAndStagingBytes: Int
    let softBackpressureCount: Int
    let maximumOwnedStagingAllocationBytes: Int
    let borrowedAsynchronousSendCount: Int
    let maximumReservedApplicationBytes: Int
    let applicationLedgerIdentity: UUID
    let applicationChargedBytes: Int
    let maximumDistinctBackingCount: Int
}

enum LoopbackEndpointValidator {
    static func accepts(listener: NWEndpoint, local: NWEndpoint, remote: NWEndpoint,
                        expectedPort: UInt16) -> Bool {
        guard expectedPort > 0,
              case let .hostPort(listenerHost, listenerPort) = listener,
              case let .hostPort(localHost, localPort) = local,
              case let .hostPort(remoteHost, _) = remote,
              listenerPort.rawValue == expectedPort, localPort.rawValue == expectedPort else { return false }
        return isIPv4Loopback(listenerHost) && isIPv4Loopback(localHost) && isIPv4Loopback(remoteHost)
    }

    private static func isIPv4Loopback(_ host: NWEndpoint.Host) -> Bool {
        guard case let .ipv4(address) = host, let loopback = IPv4Address("127.0.0.1") else { return false }
        return address == loopback
    }
}

private final class LoopbackStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func claim() -> Bool { lock.withLock {
        guard !completed else { return false }
        completed = true
        return true
    } }
}

private final class LoopbackStartupCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var pending = false

    func install(_ handler: @escaping () -> Void) {
        let fire = lock.withLock { () -> Bool in
            if pending { return true }
            self.handler = handler
            return false
        }
        if fire { handler() }
    }

    func cancel() {
        let current = lock.withLock { () -> (() -> Void)? in
            guard let handler else { pending = true; return nil }
            self.handler = nil
            return handler
        }
        current?()
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private enum AdmissionPhase {
        case open
        case closed(LoopbackHTTPCleanupTicket)
        case drained(LoopbackHTTPCleanupTicket)
        case retired(LoopbackHTTPCleanupTicket)
    }
    private struct PlaylistRoute {
        let participantID: UInt64?
        let rawLength: Int
        let gzipLength: Int
        let rawETag: String
        let gzipETag: String
    }
    private final class ResourceRoute {
        let key: HLSResourceKey
        let path: String
        let length: Int
        let backingIdentity: SealedMediaBackingIdentity
        let sealedDigest: Data
        let etag: String
        let mediaType: FinalFMP4MediaType
        let aacMediaMembershipLeaf: AACMediaMembershipLeaf?
        let aacPublicationAdmission: AACPublicationLeafAdmission?
        init(key: HLSResourceKey, path: String, length: Int,
             backingIdentity: SealedMediaBackingIdentity, sealedDigest: Data,
             etag: String,
             mediaType: FinalFMP4MediaType,
             aacMediaMembershipLeaf: AACMediaMembershipLeaf?,
             aacPublicationAdmission: AACPublicationLeafAdmission?) {
            self.key = key; self.path = path; self.length = length
            self.backingIdentity = backingIdentity; self.sealedDigest = sealedDigest
            self.etag = etag
            self.mediaType = mediaType
            self.aacMediaMembershipLeaf = aacMediaMembershipLeaf
            self.aacPublicationAdmission = aacPublicationAdmission
        }
    }
    private enum Route { case playlist(PlaylistRoute), resource(ResourceRoute) }
    private enum CompletedPlaylistKey: Hashable {
        case master
        case media(participantID: UInt64)
    }
    private final class FrozenParticipantDefinition: @unchecked Sendable {
        private struct NonAACBinding {
            let mediaEpoch: AudioMediaEpochIdentity
            let participant: AudioPublicationParticipantIdentity
            let rendition: AudioRenditionIdentity
            let writer: FMP4WriterIdentity
        }
        private enum TimelineBinding {
            case aac(AACWriterTerminalBinding)
            case other(NonAACBinding)
        }
        let store: SealedMediaStore
        private let origin: LoopbackPublicationOrigin
        var participantID: UInt64 { writerBinding.publicationParticipantID.rawValue }
        var renditionIdentity: AudioRenditionIdentity { writerBinding.renditionIdentity }
        var mediaType: FinalFMP4MediaType { audioCodec == nil ? .video : .audio }
        private let timelineBinding: TimelineBinding
        var writerBinding: FMP4WriterBinding {
            switch timelineBinding {
            case .aac(let value): value.binding
            case .other(let value):
                .init(outputLifecycleEpoch: origin.outputLifecycleEpoch,
                      itemGeneration: .init(rawValue: origin.itemGeneration),
                      mediaEpoch: value.mediaEpoch, publicationParticipantID: value.participant,
                      renditionIdentity: value.rendition, writerIdentity: value.writer)
            }
        }
        /// participant candidate 可以拥有与 master 不同但合法的完整 declaration；
        /// route、direct item 与后续 authority 必须统一读取这个冻结路径。
        let playlistPath: String
        let audioCodec: HLSAudioCodec?
        var aacTimelineMapping: AACWriterTimelineMappingReceipt? {
            if case .aac(let value) = timelineBinding { return value.timelineMappingReceipt }; return nil
        }
        init(store: SealedMediaStore, origin: LoopbackPublicationOrigin, writerBinding: FMP4WriterBinding,
             playlistPath: String, audioCodec: HLSAudioCodec?,
             aacTimelineMapping: AACWriterTerminalBinding?) {
            self.store = store; self.playlistPath = playlistPath
            self.origin = origin
            self.audioCodec = audioCodec
            timelineBinding = aacTimelineMapping.map(TimelineBinding.aac) ?? .other(.init(
                mediaEpoch: writerBinding.mediaEpoch, participant: writerBinding.publicationParticipantID,
                rendition: writerBinding.renditionIdentity, writer: writerBinding.writerIdentity))
        }
    }
    private struct FrozenResourceMembership: Sequence {
        let definition: FrozenParticipantDefinition
        let sequence: UInt64
        let kind: SealedMediaObjectKind
        func contains(_ key: HLSResourceKey) -> Bool {
            key.participantID == definition.participantID && key.kind == kind
                && definition.store.preparationPublicationContains(key, sequence: sequence)
        }
        struct Iterator: IteratorProtocol {
            let membership: FrozenResourceMembership
            var previous: HLSResourceKey?
            mutating func next() -> HLSResourceKey? {
                let next = membership.definition.store.nextPreparationPublicationResource(
                    sequence: membership.sequence, participantID: membership.definition.participantID,
                    kind: membership.kind, after: previous)
                previous = next
                return next
            }
        }
        func makeIterator() -> Iterator { .init(membership: self) }
    }
    private struct FrozenParticipant: Equatable {
        let definition: FrozenParticipantDefinition
        let playlistIdentity: UUID
        let playlistVersion: UInt64
        let effectivePlaybackHorizon: ExactMediaTime
        var participantID: UInt64 { definition.participantID }
        var renditionIdentity: AudioRenditionIdentity { definition.renditionIdentity }
        var mediaType: FinalFMP4MediaType { definition.mediaType }
        var writerBinding: FMP4WriterBinding { definition.writerBinding }
        var playlistPath: String { definition.playlistPath }
        var audioCodec: HLSAudioCodec? { definition.audioCodec }
        var aacTimelineMapping: AACWriterTimelineMappingReceipt? { definition.aacTimelineMapping }
        var initializationKeys: FrozenResourceMembership {
            .init(definition: definition, sequence: playlistVersion, kind: .initialization)
        }
        var mediaKeys: FrozenResourceMembership {
            .init(definition: definition, sequence: playlistVersion, kind: .media)
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.definition === rhs.definition && lhs.playlistIdentity == rhs.playlistIdentity
                && lhs.playlistVersion == rhs.playlistVersion
                && lhs.effectivePlaybackHorizon == rhs.effectivePlaybackHorizon
        }
    }
    private struct FrozenParticipantTable: RandomAccessCollection, ExpressibleByDictionaryLiteral {
        private var entries: (FrozenParticipant?, FrozenParticipant?, FrozenParticipant?, FrozenParticipant?)
            = (nil, nil, nil, nil)
        init(dictionaryLiteral elements: (UInt64, FrozenParticipant)...) {
            for (key, value) in elements { self[key] = value }
        }
        var startIndex: Int { 0 }
        var endIndex: Int {
            entries.3 != nil ? 4 : entries.2 != nil ? 3 : entries.1 != nil ? 2 : entries.0 != nil ? 1 : 0
        }
        var values: Self { self }
        var keys: LazyMapCollection<Self, UInt64> { lazy.map(\.participantID) }
        func reserveCapacity(_ count: Int) { precondition(count <= 4) }
        subscript(index: Int) -> FrozenParticipant {
            switch index {
            case 0: entries.0!
            case 1: entries.1!
            case 2: entries.2!
            case 3: entries.3!
            default: preconditionFailure("participant容量越界")
            }
        }
        subscript(key: UInt64) -> FrozenParticipant? {
            get { first { $0.participantID == key } }
            set {
                guard let newValue else { preconditionFailure("participant不能独立删除") }
                let index = indices.first { self[$0].participantID == key } ?? endIndex
                switch index {
                case 0: entries.0 = newValue
                case 1: entries.1 = newValue
                case 2: entries.2 = newValue
                case 3: entries.3 = newValue
                default: preconditionFailure("participant容量越界")
                }
            }
        }
    }

    /// 九历史只保存原 participant 槽上的变化字段；definition 与共同 version
    /// 分别从唯一活动 server 的原表、已验证 publication sequence 投影。
    private struct FrozenParticipantHistoryTable: Collection, ExpressibleByDictionaryLiteral, PreparationHistoryValue {
        private var sequence: UInt64 = 0
        var publicationSequence: UInt64 { sequence }
        private var present: UInt8 = 0
        private var identities: (UUID, UUID, UUID, UUID) = (
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        private var horizons: (ExactMediaTime, ExactMediaTime, ExactMediaTime, ExactMediaTime) = (
            .init(value: 0, timescale: 1), .init(value: 0, timescale: 1),
            .init(value: 0, timescale: 1), .init(value: 0, timescale: 1))

        init(dictionaryLiteral elements: (UInt64, FrozenParticipant)...) {
            for (key, value) in elements { self[key] = value }
        }
        init(_ original: FrozenParticipantTable) {
            for value in original { self[value.participantID] = value }
        }
        var values: Self { self }
        var startIndex: Int { nextIndex(after: -1) }
        var endIndex: Int { 4 }
        func index(after index: Int) -> Int { nextIndex(after: index) }
        private func nextIndex(after index: Int) -> Int {
            for candidate in (index + 1)..<4 where present & (1 << candidate) != 0 { return candidate }
            return endIndex
        }
        subscript(index: Int) -> FrozenParticipant {
            precondition((0..<4).contains(index) && present & (1 << index) != 0)
            let definition = FrozenPreparationOwner.activeHistoryServer!.frozenParticipants[index].definition
            let identity: UUID
            let horizon: ExactMediaTime
            switch index {
            case 0: identity = identities.0; horizon = horizons.0
            case 1: identity = identities.1; horizon = horizons.1
            case 2: identity = identities.2; horizon = horizons.2
            default: identity = identities.3; horizon = horizons.3
            }
            return .init(definition: definition, playlistIdentity: identity,
                playlistVersion: sequence, effectivePlaybackHorizon: horizon)
        }
        subscript(key: UInt64) -> FrozenParticipant? {
            get { first { $0.participantID == key } }
            set {
                guard let value = newValue, let server = FrozenPreparationOwner.activeHistoryServer,
                      let index = server.frozenParticipants.indices.first(where: {
                          server.frozenParticipants[$0].participantID == key
                            && server.frozenParticipants[$0].definition === value.definition
                      }) else { preconditionFailure("历史只能借用原 participant definition") }
                precondition(present == 0 || sequence == value.playlistVersion,
                             "历史 participant version 必须与原 sequence 相等")
                sequence = value.playlistVersion
                switch index {
                case 0: identities.0 = value.playlistIdentity; horizons.0 = value.effectivePlaybackHorizon
                case 1: identities.1 = value.playlistIdentity; horizons.1 = value.effectivePlaybackHorizon
                case 2: identities.2 = value.playlistIdentity; horizons.2 = value.effectivePlaybackHorizon
                default: identities.3 = value.playlistIdentity; horizons.3 = value.effectivePlaybackHorizon
                }
                present |= 1 << index
            }
        }
    }

    /// server lane独占固定九槽；外部只获取值投影，历史改写不触发字典COW。
    private final class FixedHistory<Value: PreparationHistoryValue>: Sequence {
        struct Entry { let key: UInt64; var value: Value }
        private var slots: UnsafeMutablePointer<Value?>?
        private(set) var count = 0
        init() {}
        deinit { slots?.deinitialize(count: 9); slots?.deallocate() }
        subscript(key: UInt64) -> Value? {
            get {
                guard let slots else { return nil }
                for index in 0..<9 where slots[index]?.publicationSequence == key { return slots[index]! }
                return nil
            }
            set {
                precondition(newValue == nil || newValue!.publicationSequence == key,
                             "历史外键必须与同原值sequence完全相等")
                if slots == nil {
                    guard case .some = newValue else { return }
                    slots = .allocate(capacity: 9)
                    slots!.initialize(repeating: nil, count: 9)
                }
                let slots = slots!
                for index in 0..<9 where slots[index]?.publicationSequence == key {
                    if let newValue { slots[index] = newValue }
                    else { slots[index] = nil; count -= 1 }
                    return
                }
                guard let newValue else { return }
                guard let index = (0..<9).first(where: {
                    if case .none = slots[$0] { return true }; return false
                }) else {
                    preconditionFailure("历史必须先退最旧槽")
                }
                slots[index] = newValue
                count += 1
            }
        }
        @discardableResult func removeValue(forKey key: UInt64) -> Value? {
            let prior = self[key]; self[key] = nil; return prior
        }
        func removeAll(keepingCapacity: Bool) {
            guard let slots else { return }
            for index in 0..<9 { slots[index] = nil }; count = 0
            if !keepingCapacity {
                slots.deinitialize(count: 9); slots.deallocate(); self.slots = nil
            }
        }
        struct Iterator: IteratorProtocol {
            let history: FixedHistory
            var index = 0
            mutating func next() -> Entry? {
                guard let slots = history.slots else { return nil }
                while index < 9 {
                    let value = slots[index]; index += 1
                    if let value { return .init(key: value.publicationSequence, value: value) }
                }
                return nil
            }
        }
        func makeIterator() -> Iterator { .init(history: self) }
        var keys: LazyMapSequence<FixedHistory<Value>, UInt64> { lazy.map(\.key) }
        func slot(for key: UInt64) -> UInt8? {
            guard let slots else { return nil }
            return (0..<9).first(where: { slots[$0]?.publicationSequence == key }).map(UInt8.init)
        }
        func value(at slot: UInt8) -> Value? { slots?[Int(slot)] }
#if DEBUG
        func inspectAllocations(_ body: (UnsafeRawPointer, Int) -> Void) {
            let object = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body(object, malloc_size(object))
            if let slots { body(UnsafeRawPointer(slots), malloc_size(slots)) }
        }
#endif
    }
    private final class FixedFacts<Value>: RandomAccessCollection {
        let maximumCapacity: Int
        private var slots: UnsafeMutablePointer<Value>?
        private(set) var count = 0
        init(maximumCapacity: Int) { self.maximumCapacity = maximumCapacity }
        deinit { slots?.deinitialize(count: count); slots?.deallocate() }
        var startIndex: Int { 0 }
        var endIndex: Int { count }
        subscript(index: Int) -> Value { precondition(index >= 0 && index < count); return slots![index] }
        func reserveCapacity(_ capacity: Int) {
            precondition(capacity <= maximumCapacity)
            if slots == nil { slots = .allocate(capacity: maximumCapacity) }
        }
        func append(_ value: Value) {
            precondition(count < maximumCapacity)
            reserveCapacity(maximumCapacity)
            slots!.advanced(by: count).initialize(to: value)
            count += 1
        }
        func removeAll(where predicate: (Value) -> Bool) {
            guard let slots else { return }
            var next = 0
            for index in 0..<count {
                let value = slots[index]
                if !predicate(value) {
                    if next != index { slots[next] = value }
                    next += 1
                }
            }
            slots.advanced(by: next).deinitialize(count: count - next)
            count = next
        }
        func removeAll(keepingCapacity: Bool) {
            slots?.deinitialize(count: count); count = 0
            if !keepingCapacity { slots?.deallocate(); slots = nil }
        }
#if DEBUG
        func inspectAllocations(_ body: (UnsafeRawPointer, Int) -> Void) {
            let object = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body(object, malloc_size(object))
            if let slots { body(UnsafeRawPointer(slots), malloc_size(slots)) }
        }
#endif
    }
    private struct CompletedPlaylistFact {
        let publicationSlot: UInt8
        let participantSlot: UInt8
        var authority: LoopbackPublicationAuthorityBinding {
            FrozenPreparationOwner.activeHistoryServer!.authorityBindings.value(at: publicationSlot)!
        }
        var key: CompletedPlaylistKey {
            participantSlot == .max ? .master
                : .media(participantID: FrozenPreparationOwner.activeHistoryServer!
                    .frozenParticipants[Int(participantSlot)].participantID)
        }
        var snapshotVersion: UInt64 { authority.publicationSequence }
        var snapshotIdentity: UUID {
            let server = FrozenPreparationOwner.activeHistoryServer!
            if participantSlot == .max { return authority.publicationSnapshotIdentity }
            let participantID = server.frozenParticipants[Int(participantSlot)].participantID
            return server.participantsByPublication[authority.publicationSequence]![participantID]!.playlistIdentity
        }
    }
    private struct CompletedResourceFact {
        let resourceSlot: UInt16
        let rangeSlot: UInt8
        let publicationSlot: UInt8
        private var server: LoopbackHTTPServer { FrozenPreparationOwner.activeHistoryServer! }
        var authority: LoopbackPublicationAuthorityBinding { server.authorityBindings.value(at: publicationSlot)! }
        var key: HLSResourceKey { server.store.preparationResource(slot: Int(resourceSlot), ownerSlot: .max)!.key }
        var participantID: UInt64 { key.participantID }
        var backingIdentity: SealedMediaBackingIdentity {
            server.store.preparationResource(slot: Int(resourceSlot), ownerSlot: .max)!.backing
        }
        var completedByteRange: Range<Int> {
            server.store.completedResponseRange(resourceSlot: resourceSlot, rangeSlot: rangeSlot)!
        }
        var residentByteCount: Int { server.store.preparationResource(slot: Int(resourceSlot), ownerSlot: .max)!.length }
        var presentationRange: FMP4PresentationRange? {
            server.store.preparationResource(slot: Int(resourceSlot), ownerSlot: .max)!.presentationRange
        }
    }
    private struct ResourceResponseAuthority {
        let binding: LoopbackPublicationAuthorityBinding
        let participant: FrozenParticipant
    }
    private struct PreparationHistoryAdmissionToken: Sendable, Equatable {
        let ownerSlot: UInt8
        let generation: UInt64
    }

    let localHost = "127.0.0.1"
    let port: UInt16
    let baseURL: URL
    let masterPath: String
    let socketBindingEvidence: LoopbackSocketBindingEvidence
    var sessionToken: String { declaration.token }
    var sessionCapabilityIdentity: UUID { sessionCapability.identity }
    var lifecyclePhase: LoopbackHTTPLifecyclePhase {
        queueSync {
            switch phase {
            case .open: return .open
            case .closed: return .closed
            case .drained: return .drained
            case .retired: return .retired
            }
        }
    }
    var usage: LoopbackHTTPRuntimeUsage { queueSync {
        .init(connections: connections.count + closingConnections.count,
              activeResponses: activeResponses,
              distinctBackingBytes: reservedBackingBytes,
              parserAndStagingBytes: parserAndStagingBytes,
              maximumConnections: maximumConnections,
              maximumActiveResponses: maximumActiveResponses,
              maximumDistinctBackingBytes: maximumDistinctBackingBytes,
              maximumParserAndStagingBytes: maximumParserAndStagingBytes,
              softBackpressureCount: softBackpressureCount,
              maximumOwnedStagingAllocationBytes: maximumOwnedStagingAllocationBytes,
              borrowedAsynchronousSendCount: 0,
              maximumReservedApplicationBytes: maximumReservedApplicationBytes,
              applicationLedgerIdentity: HLSDeliveryApplicationChargeLedger.shared.identity,
              applicationChargedBytes: HLSDeliveryApplicationChargeLedger.shared.chargedBytes,
              maximumDistinctBackingCount: backingLedger.usage.distinctBackingCount)
    } }

    private let store: SealedMediaStore
    private let sessionCapability: LoopbackSessionToken
    private let declaration: HLSItemDeclaration
    private let now: @Sendable () -> Int64
    private let logger: @Sendable (String) -> Void
    private let responseFailure: @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void
    private let testing: LoopbackHTTPTestingConfiguration?
    private let serverIdentity: UUID
    private let publisherIdentity: UUID
    private let authorityBinding: LoopbackPublicationAuthorityBinding
    private let requiresMasterPlaylist: Bool
    private let frozenParticipants: FrozenParticipantTable
    private let aacTerminalBindings: [UInt64: AACWriterTerminalBinding]
    private let aacRenditionBindings: [UInt64: AACRenditionTerminalBinding]
    private let authorityBindings = FixedHistory<LoopbackPublicationAuthorityBinding>()
    private let participantsByPublication = FixedHistory<FrozenParticipantHistoryTable>()
    private var publicationEventHandler: (@Sendable (UInt64) -> Void)?
    private var completedResourceEventHandler: (@Sendable () -> Void)?
    private var renditionSelectionEventHandler:
        (@Sendable (LoopbackAudioMediaSelectionCapability) -> Void)?
    private var timelineFailureEventHandler:
        (@Sendable (LoopbackTimelineFailureEvent) -> Void)?
    private var timelineFailureEvent: LoopbackTimelineFailureEvent?
    private var timelineFailureWasDelivered = false
    private let audioSelectionByPublication = FixedHistory<LoopbackAudioMediaSelectionCapability>()
    private var latestEmittedPublicationSequence: UInt64?
    fileprivate let queue = DispatchQueue(label: "org.vplayer.loopback-http")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let listener: NWListener
    private var phase: AdmissionPhase = .open
    private var routes: [String: Route] = [:]
    private var registeredResources: [HLSResourceKey: ResourceRoute] = [:]
    private var coverageContexts: Set<LoopbackCoverageContext> = []
    private var connections: [ObjectIdentifier: LoopbackHTTPConnection] = [:]
    private var closingConnections: [ObjectIdentifier: LoopbackHTTPConnection] = [:]
    private var startupEndpointProbe: ((Bool) -> Void)?
    private var pausedBodySends: [ObjectIdentifier: () -> Void] = [:]
    private var automaticCleanupTicket: LoopbackHTTPCleanupTicket?
    private var activeResponses = 0
    private let backingLedger = LoopbackHTTPReservationLedger()
    private var reservedBackingBytes: Int { backingLedger.usage.distinctBackingBytes }
    private var parserAndStagingBytes: Int {
        (connections.count + closingConnections.count)
            * LoopbackStorageLayout.current.parserAllocationBytes
            + activeResponses * LoopbackStorageLayout.current.stagingAllocationBytes
            + coverageContexts.count
                * LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes
    }
    private var maximumConnections = 0
    private var maximumActiveResponses = 0
    private var maximumDistinctBackingBytes = 0
    private var maximumParserAndStagingBytes = 0
    private var softBackpressureCount = 0
    private var maximumOwnedStagingAllocationBytes = 0
    private var maximumReservedApplicationBytes = 0
    private var acceptedPlaylistGETCount = 0
    private var acceptedInitializationGETCount = 0
    private var acceptedMediaGETCount = 0
    /// media range 最多保留 64 个真实 response；playlist/init 另有固定小槽，
    /// 避免准备事实挤占“≤64 个 206 可联合覆盖完整 backing”的合同。
    private static let completedResponseFactCapacity = 64
    private static let completedInitializationFactCapacity = 36
    private let completedPlaylistFacts = FixedFacts<CompletedPlaylistFact>(maximumCapacity: 64)
    private let completedResourceFacts = FixedFacts<CompletedResourceFact>(maximumCapacity: 100)
    private var aacHTTPMembership: [UInt64: AACMediaMembershipAccumulator] = [:]
    private let aacHTTPIssuer = UUID()
    private var terminalAACHTTPLeaves: [UInt64: AACMediaMembershipLeaf] = [:]
    private var terminalAACHTTPKeys: [UInt64: HLSResourceKey] = [:]
    private var aacHTTPFinalizationGates: [UInt64: AACHTTPFinalizationGate] = [:]
    private var aacPublicationSealObserverTokens: [UInt64: UUID] = [:]
    /// ≤4 participant：三个固定字典buffer、observer closure/context及最多四个
    /// publication 单次queued tail，共用8KiB delivery metadata包络。
    private var aacFinalizationChargeLease: AACHTTPFinalizationChargeLease?
    /// range 明细联合完整后压成真实 key/backing；只保留固定 64 个近期成员。
    private var compactAACCompleted: [HLSResourceKey: SealedMediaBackingIdentity] = [:]
    private var activePreparationOwnerSlot: UInt8 = 0
    private var activePreparationHistoryGeneration: UInt64 = 0
    private weak var activePreparationOwner: FrozenPreparationOwner?
    private var preparationHistoryResourceReservation: PlaybackResourceContextReservation?

#if DEBUG
    /// 在原 server lane 同步借用真实分配基址，不复制 backing，不让指针逃逸。
    func inspectPreparationHistoryAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        queueSync {
            LoopbackAudioMediaSelectionCapability.inspectStorageLock(body)
            let origin = UnsafeRawPointer(Unmanaged.passUnretained(authorityBinding.origin).toOpaque())
            body("owned/共享签发域", origin, malloc_size(origin))
            authorityBindings.inspectAllocations { body("owned/历史 authority wrapper或原槽", $0, $1) }
            participantsByPublication.inspectAllocations { body("owned/历史 participant wrapper或原槽", $0, $1) }
            audioSelectionByPublication.inspectAllocations { body("owned/历史 selection wrapper或原槽", $0, $1) }
            completedPlaylistFacts.inspectAllocations { body("owned/playlist fact wrapper或原槽", $0, $1) }
            completedResourceFacts.inspectAllocations { body("owned/resource fact wrapper或原槽", $0, $1) }
            for participant in frozenParticipants {
                let pointer = UnsafeRawPointer(Unmanaged.passUnretained(participant.definition).toOpaque())
                body("owned/共享 participant definition", pointer, malloc_size(pointer))
            }
            for entry in audioSelectionByPublication {
                let pointer = UnsafeRawPointer(Unmanaged.passUnretained(entry.value).toOpaque())
                body("owned/selection record", pointer, malloc_size(pointer))
            }
        }
    }

    var preparationHistoryFactCounts:
        (authorities: Int, participants: Int, playlists: Int,
         resources: Int, selections: Int) {
        queueSync {
            (authorityBindings.count, participantsByPublication.count,
             completedPlaylistFacts.count, completedResourceFacts.count,
             audioSelectionByPublication.count)
        }
    }

    var aacHTTPMembershipSnapshots: [UInt64: AACMediaMembershipSnapshot] {
        queueSync { aacHTTPMembership.mapValues(\.snapshot) }
    }

    var preparationHistoryFenceStorageCost:
        (serverAllocationBytes: Int, incrementalServerAllocationBytes: Int,
         generationValueBytes: Int, responseTokenValueBytes: Int) {
        queueSync {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let generationBytes = MemoryLayout<UInt64>.stride
            let previousClassBytes = max(0, class_getInstanceSize(Self.self) - generationBytes)
            return (malloc_size(pointer),
                    malloc_size(pointer) - malloc_good_size(previousClassBytes),
                    generationBytes,
                    MemoryLayout<PreparationHistoryAdmissionToken?>.stride)
        }
    }
#endif

    func activatePreparationHistory(owner: FrozenPreparationOwner) -> Bool {
        queueSync {
            guard isAdmissionOpen else { return false }
            if activePreparationOwnerSlot != 0 {
                return activePreparationOwnerSlot == owner.slot
                    && activePreparationOwner === owner
                    && activePreparationHistoryGeneration != 0
            }
            guard let resourceReservation = try? PlaybackResourceContextLedger.shared.reserve(
                    allocationIdentity: .owned(ObjectIdentifier(self), 1), bytes: 16 * 1_024)
            else { return false }
            guard let generation = try? PlaybackIdentityAllocator.shared.next(in: .nonce),
                  FrozenPreparationOwner.claimHistoryDomain(serverIdentity, server: self) else {
                PlaybackResourceContextLedger.shared.release(resourceReservation)
                return false
            }
            preparationHistoryResourceReservation = resourceReservation
            activePreparationOwnerSlot = owner.slot
            activePreparationHistoryGeneration = generation
            activePreparationOwner = owner
            if participantsByPublication.count == 0 {
                authorityBindings[authorityBinding.publicationSequence] = authorityBinding
                participantsByPublication[authorityBinding.publicationSequence] = .init(frozenParticipants)
                store.retainCurrentPreparationPublication(sequence: authorityBinding.publicationSequence)
                completedPlaylistFacts.reserveCapacity(Self.completedResponseFactCapacity)
                completedResourceFacts.reserveCapacity(Self.completedResponseFactCapacity)
            }
            return true
        }
    }

    func retirePreparationHistory(ownerSlot: UInt8) {
        let resourceReservation = queueSync { () -> PlaybackResourceContextReservation? in
            guard activePreparationOwnerSlot == ownerSlot else { return nil }
            activePreparationOwnerSlot = 0
            activePreparationHistoryGeneration = 0
            activePreparationOwner = nil
            publicationEventHandler = nil
            completedResourceEventHandler = nil
            renditionSelectionEventHandler = nil
            timelineFailureEventHandler = nil
            audioSelectionByPublication.removeAll(keepingCapacity: false)
            authorityBindings.removeAll(keepingCapacity: false)
            participantsByPublication.removeAll(keepingCapacity: false)
            completedPlaylistFacts.removeAll(keepingCapacity: false)
            completedResourceFacts.removeAll(keepingCapacity: false)
            compactAACCompleted.removeAll(keepingCapacity: false)
            store.releasePreparationHistory()
            FrozenPreparationOwner.releaseHistoryDomain(serverIdentity)
            let reservation = preparationHistoryResourceReservation
            preparationHistoryResourceReservation = nil
            return reservation
        }
        if let resourceReservation {
            PlaybackResourceContextLedger.shared.release(resourceReservation)
        }
    }

    private var activePreparationHistoryAdmissionToken: PreparationHistoryAdmissionToken? {
        guard activePreparationOwnerSlot != 0,
              activePreparationHistoryGeneration != 0 else { return nil }
        return .init(ownerSlot: activePreparationOwnerSlot,
                     generation: activePreparationHistoryGeneration)
    }

    private init(listener: NWListener, port: UInt16, store: SealedMediaStore,
                 declaration: HLSItemDeclaration, publishedSnapshot: HLSPublishedSnapshot,
                 sessionCapability: LoopbackSessionToken,
                 socketBindingEvidence: LoopbackSocketBindingEvidence,
                 now: @escaping @Sendable () -> Int64,
                 logger: @escaping @Sendable (String) -> Void,
                 responseFailure: @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void,
                 testing: LoopbackHTTPTestingConfiguration?) throws {
        guard port > 0, declaration.itemGeneration == store.itemGeneration,
              store.belongs(to: sessionCapability), declaration.token == sessionCapability.value else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        try HLSPlaylistSerializer.validate(declaration)
        let serverIdentity = UUID()
        let publicationSnapshotIdentity = UUID()
        guard let outputLifecycleEpoch = publishedSnapshot.participantVector.first?.binding.outputLifecycleEpoch
        else { throw LoopbackHTTPServerError.invalidConfiguration }
        let origin = LoopbackPublicationOrigin(serverIdentity: serverIdentity,
            sessionCapabilityIdentity: sessionCapability.identity,
            sessionToken: sessionCapability.value, port: port,
            outputLifecycleEpoch: outputLifecycleEpoch, itemGeneration: declaration.itemGeneration)
        let frozenParticipants = try Self.freezeParticipants(
            snapshot: publishedSnapshot, declaration: declaration, store: store, origin: origin)
        let frozenAACParticipantIDs = Set(frozenParticipants.values.compactMap {
            $0.mediaType == .audio && $0.audioCodec == .aac ? $0.participantID : nil
        })
        guard frozenParticipants.values.allSatisfy({
                  $0.writerBinding.outputLifecycleEpoch == outputLifecycleEpoch
              }),
              frozenAACParticipantIDs
                == Set(publishedSnapshot.aacTerminalBindings.keys),
              frozenAACParticipantIDs
                == Set(publishedSnapshot.aacTimelineMappings.keys),
              publishedSnapshot.aacRenditionBindings.isEmpty
                || frozenAACParticipantIDs
                    == Set(publishedSnapshot.aacRenditionBindings.keys),
              publishedSnapshot.aacTerminalBindings.allSatisfy({ participantID, binding in
                  guard let frozen = frozenParticipants[participantID],
                        let mapping = publishedSnapshot.aacTimelineMappings[participantID]
                  else { return false }
                  return frozen.mediaType == .audio
                    && frozen.audioCodec == .aac
                    && frozen.writerBinding == binding.binding
                    && frozen.renditionIdentity == binding.binding.renditionIdentity
                    && binding.binding.itemGeneration.rawValue == declaration.itemGeneration
                    && binding.binding.publicationParticipantID.rawValue == participantID
                    && mapping.binding == binding.binding
              }),
              publishedSnapshot.aacRenditionBindings.allSatisfy({ participantID, binding in
                  guard let frozen = frozenParticipants[participantID] else { return false }
                  return binding.outputLifecycleEpoch == frozen.writerBinding.outputLifecycleEpoch
                    && binding.itemGeneration == frozen.writerBinding.itemGeneration
                    && binding.mediaEpoch == frozen.writerBinding.mediaEpoch
                    && binding.publicationParticipantID == frozen.writerBinding.publicationParticipantID
                    && binding.renditionIdentity == frozen.renditionIdentity
              }) else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        self.listener = listener; self.port = port; self.store = store
        self.sessionCapability = sessionCapability
        self.socketBindingEvidence = socketBindingEvidence
        self.declaration = declaration; self.now = now; self.logger = logger
        self.responseFailure = responseFailure
        self.testing = testing
        self.serverIdentity = serverIdentity
        publisherIdentity = publishedSnapshot.publisherIdentity
        self.requiresMasterPlaylist = publishedSnapshot.master != nil
        self.frozenParticipants = frozenParticipants
        aacTerminalBindings = publishedSnapshot.aacTerminalBindings
        aacRenditionBindings = publishedSnapshot.aacRenditionBindings
        authorityBinding = .init(origin: origin,
            publicationSequence: publishedSnapshot.publicationSequence,
            publicationSnapshotIdentity: publicationSnapshotIdentity)
        queue.setSpecific(key: queueKey, value: 1)
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            throw LoopbackHTTPServerError.invalidBinding
        }
        self.baseURL = baseURL
        masterPath = "/v1/\(declaration.token)/\(declaration.itemGeneration)/master.m3u8"
        try install(snapshot: publishedSnapshot)
        var installedObservers: [(AACRenditionTerminalBinding, UUID)] = []
        let finalizationLease = try AACHTTPFinalizationChargeLease(
            bytes: LoopbackStorageLayout.current.aacHTTPFinalizationMetadataBytes)
        do {
            aacFinalizationChargeLease = finalizationLease
            maximumReservedApplicationBytes = max(
                maximumReservedApplicationBytes,
                LoopbackStorageLayout.current.aacHTTPFinalizationMetadataBytes)
            try queue.sync {
                // 登记、gate 和 token 在同一 server lane 内成为一个就绪点。
                // 已先 seal 的同步补发只能排在该块之后，不能越过字典安装。
                for (participantID, binding) in aacRenditionBindings {
                    guard let identity = binding.installPublicationSealObserver(
                        { [weak self, weak binding, finalizationLease] receipt in
                            _ = finalizationLease
                            guard let self, let binding else { return }
                            self.queue.async { [weak self, weak binding, finalizationLease] in
                                _ = finalizationLease
                                guard let self, let binding else { return }
                                self.observeAACPublicationSeal(
                                    receipt, participantID: participantID,
                                    binding: binding)
                            }
                        }) else {
                        throw LoopbackHTTPServerError.invalidConfiguration
                    }
                    installedObservers.append((binding, identity))
                    aacPublicationSealObserverTokens[participantID] = identity
                    aacHTTPFinalizationGates[participantID] = .init()
                }
            }
        } catch {
            for (binding, identity) in installedObservers {
                binding.removePublicationSealObserver(identity)
            }
            aacFinalizationChargeLease = nil
            throw error
        }
    }

    private static func freezeParticipants(
        snapshot: HLSPublishedSnapshot,
        declaration: HLSItemDeclaration, store: SealedMediaStore, origin: LoopbackPublicationOrigin
    ) throws -> FrozenParticipantTable {
        guard (1...4).contains(snapshot.participantVector.count),
              snapshot.media.count == snapshot.participantVector.count else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        var result: FrozenParticipantTable = [:]
        result.reserveCapacity(4)
        var playlistPaths = Set<String>()
        for entry in snapshot.participantVector {
            let participantDeclaration = entry.declaration
            let playlistPath = try participantDeclaration.playlistURI(
                participantID: entry.participantID)
            guard result[entry.participantID] == nil,
                  entry.binding.outputLifecycleEpoch == origin.outputLifecycleEpoch,
                  entry.binding.itemGeneration.rawValue == origin.itemGeneration,
                  entry.binding.publicationParticipantID.rawValue == entry.participantID,
                  participantDeclaration.itemGeneration == declaration.itemGeneration,
                  participantDeclaration.token == declaration.token,
                  playlistPath != "/v1/\(declaration.token)/\(declaration.itemGeneration)/master.m3u8",
                  playlistPaths.insert(playlistPath).inserted,
                  let playlist = snapshot.media[entry.participantID],
                  playlist.version == snapshot.publicationSequence,
                  let effectivePlaybackHorizon = playlist.effectivePlaybackHorizon,
                  playlist.resources.count <= Self.completedResponseFactCapacity,
                  playlist.initializationResources.count <= Self.completedResponseFactCapacity,
                  playlist.resources.allSatisfy({
                      $0.itemGeneration == declaration.itemGeneration
                        && $0.participantID == entry.participantID && $0.kind == .media
                  }),
                  playlist.initializationResources.allSatisfy({
                      $0.itemGeneration == declaration.itemGeneration
                        && $0.participantID == entry.participantID
                        && $0.kind == .initialization
                  }) else { throw LoopbackHTTPServerError.invalidConfiguration }
            let audioCodec: HLSAudioCodec?
            if participantDeclaration.video?.participantID == entry.participantID {
                audioCodec = nil
            } else if let audio = participantDeclaration.audio.first(where: {
                $0.participantID == entry.participantID
            }) {
                audioCodec = audio.codec
            } else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            if let mapping = snapshot.aacTimelineMappings[entry.participantID] {
                guard mapping.binding == entry.binding,
                      let original = snapshot.aacTerminalBindings[entry.participantID],
                      original.binding == entry.binding,
                      original.timelineMappingReceipt == mapping else {
                    throw LoopbackHTTPServerError.invalidConfiguration
                }
            }
            result[entry.participantID] = FrozenParticipant(
                definition: .init(store: store, origin: origin, writerBinding: entry.binding,
                playlistPath: playlistPath,
                audioCodec: audioCodec,
                aacTimelineMapping: snapshot.aacTerminalBindings[entry.participantID]),
                playlistIdentity: playlist.identity,
                playlistVersion: playlist.version,
                effectivePlaybackHorizon: effectivePlaybackHorizon
            )
        }
        return result
    }

    private static func freezeParticipant(
        participantID: UInt64,
        snapshot: HLSPlaylistSnapshot,
        declaration: HLSItemDeclaration,
        fallback: FrozenParticipant?
    ) throws -> FrozenParticipant {
        guard let fallback,
              let effectivePlaybackHorizon = snapshot.effectivePlaybackHorizon,
              snapshot.resources.count <= completedResponseFactCapacity,
              snapshot.initializationResources.count <= completedResponseFactCapacity,
              snapshot.resources.allSatisfy({
                  $0.itemGeneration == declaration.itemGeneration
                    && $0.participantID == participantID && $0.kind == .media
              }),
              snapshot.initializationResources.allSatisfy({
                  $0.itemGeneration == declaration.itemGeneration
                    && $0.participantID == participantID && $0.kind == .initialization
              }) else { throw LoopbackHTTPServerError.invalidConfiguration }
        fallback.definition.store.retainPreparationPublication(snapshot)
        return .init(definition: fallback.definition,
            playlistIdentity: snapshot.identity,
            playlistVersion: snapshot.version,
            effectivePlaybackHorizon: effectivePlaybackHorizon)
    }

    static func start(store: SealedMediaStore, declaration: HLSItemDeclaration,
                      publishedSnapshot: HLSPublishedSnapshot,
                      sessionCapability: LoopbackSessionToken,
                      now: @escaping @Sendable () -> Int64,
                      logger: @escaping @Sendable (String) -> Void,
                      responseFailure: @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void = { _, _ in },
                      testing: LoopbackHTTPTestingConfiguration? = nil) async throws -> LoopbackHTTPServer {
        guard let loopback = IPv4Address("127.0.0.1") else { throw LoopbackHTTPServerError.invalidBinding }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw LoopbackHTTPServerError.transportUnavailable }
        let startupQueue = DispatchQueue(label: "org.vplayer.loopback-http.start")
        let gate = LoopbackStartupGate()
        let cancellationRelay = LoopbackStartupCancellationRelay()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                cancellationRelay.install {
                    continuation.resume(throwing: CancellationError())
                }
                listener.newConnectionHandler = { connection in connection.cancel() }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.append("lb_ready")
                        #endif
                        guard !Task.isCancelled,
                              let assignedPort = listener.port?.rawValue, assignedPort > 0,
                              let loopbackPort = NWEndpoint.Port(rawValue: assignedPort) else {
                            listener.cancel()
                            guard gate.claim() else { return }
                            continuation.resume(throwing: Task.isCancelled ? CancellationError()
                                : LoopbackHTTPServerError.invalidBinding)
                            return
                        }
                        do {
                            #if DEBUG
                            PlaybackDiagnosticTracker.shared.append("lb_kb_start")
                            #endif
                            let bindingEvidence = try kernelBindingEvidence(port: assignedPort,
                                                                           testing: testing)
                            #if DEBUG
                            PlaybackDiagnosticTracker.shared.append("lb_kb_ok")
                            #endif
                            let server = try LoopbackHTTPServer(listener: listener, port: assignedPort, store: store,
                                declaration: declaration, publishedSnapshot: publishedSnapshot,
                                sessionCapability: sessionCapability,
                                socketBindingEvidence: bindingEvidence,
                                now: now, logger: logger, responseFailure: responseFailure,
                                testing: testing)
                            listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
                            listener.stateUpdateHandler = { [weak server] state in server?.listenerChanged(state) }
                            let endpoint: NWEndpoint = .hostPort(host: .ipv4(loopback), port: loopbackPort)
                            let probe = NWConnection(to: endpoint, using: .tcp)
                            #if DEBUG
                            PlaybackDiagnosticTracker.shared.append("lb_probe_start")
                            #endif
                            server.installStartupEndpointProbe { accepted in
                                #if DEBUG
                                PlaybackDiagnosticTracker.shared.append("lb_probe_cb_\(accepted)")
                                #endif
                                probe.cancel()
                                guard gate.claim() else { return }
                                if testing?.cancelAfterStartupProbeAccepted == true {
                                    let ticket = server.closeAdmission()
                                    try? server.drain(cleanupTicket: ticket)
                                    try? server.retire(cleanupTicket: ticket)
                                    continuation.resume(throwing: CancellationError())
                                } else if accepted, !Task.isCancelled {
                                    continuation.resume(returning: server)
                                } else {
                                    let ticket = server.closeAdmission()
                                    try? server.drain(cleanupTicket: ticket)
                                    try? server.retire(cleanupTicket: ticket)
                                    continuation.resume(throwing: Task.isCancelled ? CancellationError()
                                        : LoopbackHTTPServerError.invalidBinding)
                                }
                            }
                            probe.stateUpdateHandler = { probeState in
                                guard case .failed = probeState, gate.claim() else { return }
                                server.cancelStartupEndpointProbe()
                                let ticket = server.closeAdmission()
                                try? server.drain(cleanupTicket: ticket)
                                try? server.retire(cleanupTicket: ticket)
                                continuation.resume(throwing: Task.isCancelled ? CancellationError()
                                    : LoopbackHTTPServerError.invalidBinding)
                            }
                            probe.start(queue: startupQueue)
                        } catch {
                            #if DEBUG
                            PlaybackDiagnosticTracker.shared.append("lb_catch_\(error)")
                            #endif
                            listener.cancel()
                            guard gate.claim() else { return }
                            continuation.resume(throwing: error)
                        }
                    case .failed(let err):
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.append("lb_failed_\(err)")
                        #endif
                        guard gate.claim() else { return }
                        continuation.resume(throwing: Task.isCancelled ? CancellationError()
                            : LoopbackHTTPServerError.transportUnavailable)
                    case .cancelled:
                        #if DEBUG
                        PlaybackDiagnosticTracker.shared.append("lb_cancelled")
                        #endif
                        guard gate.claim() else { return }
                        continuation.resume(throwing: Task.isCancelled ? CancellationError()
                            : LoopbackHTTPServerError.transportUnavailable)
                    default: break
                    }
                }
                listener.start(queue: startupQueue)
            }
        }, onCancel: {
            listener.cancel()
            if gate.claim() { cancellationRelay.cancel() }
        })
    }

    func path(for key: HLSResourceKey) throws -> String {
        do { return try store.resourceURI(key) }
        catch { throw LoopbackHTTPServerError.invalidConfiguration }
    }

    func resumePausedBodySends(testing capability: LoopbackHTTPTestingCapability) {
        queueSync {
            let pending = Array(pausedBodySends.values)
            pausedBodySends.removeAll(keepingCapacity: true)
            pending.forEach { $0() }
        }
    }

    func cancelListenerForTesting(_ capability: LoopbackHTTPTestingCapability) {
        listener.cancel()
    }

    fileprivate var configuredBodyChunkBytes: Int {
        min(64 * 1_024, max(1, testing?.bodyChunkBytes ?? 64 * 1_024))
    }

    fileprivate var configuredFailureAfterBodyChunks: Int? {
        testing?.failAfterSuccessfulBodyChunks
    }

    fileprivate func pauseBodySend(_ context: LoopbackHTTPConnection,
                                    resume: @escaping () -> Void) -> Bool {
        guard testing?.pauseBeforeBodySend == true else { return false }
        pausedBodySends[ObjectIdentifier(context)] = resume
        return true
    }

    func completedEvidence(for key: HLSResourceKey) -> CompletedBodyEvidenceSnapshot? {
        store.completedEvidenceSnapshot(for: key)
    }

    #if DEBUG
    func completedPublicationCapability(itemURL: URL, itemGeneration: UInt64,
                                        publicationSequence: UInt64,
                                        preparationOwner: FrozenPreparationOwner? = nil)
        -> LoopbackCompletedPublicationCapability? {
        guard let evidence = frozenCompletedPublication(itemURL: itemURL,
            itemGeneration: itemGeneration, publicationSequence: publicationSequence,
            preparationOwner: preparationOwner) else { return nil }
        return .init(evidence: evidence, authorityBinding: evidence.authorityBinding)
    }
    #endif

    func frozenCompletedPublication(itemURL: URL, itemGeneration: UInt64,
                                        publicationSequence: UInt64,
                                        preparationOwner: FrozenPreparationOwner? = nil)
        -> LoopbackCompletedPublicationEvidence? {
        queueSync {
            guard let basis = preparationPublicationBasis(itemURL: itemURL,
                itemGeneration: itemGeneration, publicationSequence: publicationSequence,
                preparationOwner: preparationOwner),
                  (try? basis.preparationOwner.freezeCompletedResources()) != nil else { return nil }
            return .init(preparationOwner: basis.preparationOwner)
        }
    }

    func freezePreparationCompletedEvidence(owner: FrozenPreparationOwner)
        -> LoopbackCompletedPublicationEvidence? {
        queueSync {
            guard owner.frozenPublication?.authorityBinding.origin === authorityBinding.origin,
                  (try? owner.freezeCompletedResources()) != nil else { return nil }
            return .init(preparationOwner: owner)
        }
    }

    func preparationPublicationBasis(itemURL: URL, itemGeneration: UInt64,
                                     publicationSequence: UInt64,
                                     preparationOwner: FrozenPreparationOwner? = nil)
        -> LoopbackPreparationPublicationBasis? {
        queueSync {
            func reject(_ marker: String) -> LoopbackPreparationPublicationBasis? {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(marker)
                #endif
                return nil
            }
            guard let owner = preparationOwner ?? activePreparationOwner
                    ?? (try? FrozenPreparationOwner.reserve()) else {
                return reject("pubwait_no_owner")
            }
            if let frozen = owner.frozenPublication {
                guard frozen.itemURL == itemURL,
                      frozen.authorityBinding.itemGeneration == itemGeneration,
                      frozen.authorityBinding.publicationSequence == publicationSequence,
                      frozen.authorityBinding.serverIdentity == serverIdentity else { return nil }
                return .init(preparationOwner: owner)
            }
            guard isAdmissionOpen,
                  itemGeneration == declaration.itemGeneration,
                  let binding = authorityBindings[publicationSequence],
                  let participants = participantsByPublication[publicationSequence],
                  itemURL.scheme == "http", itemURL.host == localHost,
                  itemURL.port == Int(port), itemURL.query == nil,
                  itemURL.fragment == nil else { return nil }
            let itemPath = itemURL.path
            let directParticipant = participants.values.first { participant in
                participant.playlistPath == itemPath
            }
            guard itemPath == masterPath || directParticipant != nil else { return nil }
            let masterCompleted = completedPlaylistFacts.contains {
                $0.authority == binding && $0.key == .master
            }
            if itemPath == masterPath, requiresMasterPlaylist, !masterCompleted {
                return reject("pubwait_master")
            }

            let selection = audioSelectionByPublication[publicationSequence]
            if preparationOwner != nil, selection == nil,
               participants.values.contains(where: { $0.mediaType == .audio }) {
                return reject("pubwait_selection")
            }
            if let directParticipant, let selection,
               selection.participantID != directParticipant.participantID {
                return nil
            }
            var frozen = LoopbackFrozenPublicationStorage(itemURL: itemURL,
                masterPlaylistCompleted: masterCompleted, audioSelectionCapability: selection,
                authorityBinding: binding)
            var metadataTransferred = false
            defer { if !metadataTransferred { owner.rollbackUnpublishedMetadata() } }
            var count = 0
            var previousID: UInt64?
            var hasAudio = false
            var hasVideo = false
            for _ in 0..<4 {
                var next: FrozenParticipant?
                for candidate in participants.values {
                    guard previousID.map({ candidate.participantID > $0 }) ?? true,
                          directParticipant.map({ $0.participantID == candidate.participantID })
                            ?? (candidate.mediaType == .video
                                || selection?.participantID == candidate.participantID
                                || selection == nil),
                          next.map({ candidate.participantID < $0.participantID }) ?? true else {
                        continue
                    }
                    next = candidate
                }
                guard let participant = next else { break }
                previousID = participant.participantID
                guard completedPlaylistFacts.contains(where: {
                    $0.authority == binding
                        && $0.key == .media(participantID: participant.participantID)
                        && $0.snapshotIdentity == participant.playlistIdentity
                        && $0.snapshotVersion == participant.playlistVersion
                }) else {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append(participant.mediaType == .audio
                        ? "pubwait_audio_playlist" : "pubwait_video_playlist")
                    #endif
                    continue
                }
                var hasInitialization = false
                var hasMedia = false
                for fact in completedResourceFacts {
                    guard fact.authority == binding,
                          fact.participantID == participant.participantID,
                          participant.initializationKeys.contains(fact.key)
                            || participant.mediaKeys.contains(fact.key),
                          completedResourceFactsFullyCover(key: fact.key,
                            backing: fact.backingIdentity, authority: binding) else { continue }
                    if fact.key.kind == .media, fact.presentationRange == nil { continue }
                    if fact.key.kind == .initialization { hasInitialization = true }
                    else if fact.presentationRange != nil { hasMedia = true }
                }
                guard hasInitialization && hasMedia else {
                    #if DEBUG
                    let kind = participant.mediaType == .audio ? "audio" : "video"
                    PlaybackDiagnosticTracker.shared.append(
                        "pubwait_\(kind)_i\(hasInitialization)_m\(hasMedia)"
                    )
                    #endif
                    continue
                }
                guard participant.playlistVersion == binding.publicationSequence else { return nil }
                var descriptorSlot: UInt16?
                for key in participant.initializationKeys {
                    guard (try? owner.retainMetadata(in: store, key: key)) != nil else { return nil }
                }
                for key in participant.mediaKeys {
                    guard let slot = try? owner.retainMetadata(in: store, key: key),
                          let resource = store.preparationResource(slot: slot, ownerSlot: owner.slot),
                          resource.key == key, resource.key.participantID == participant.participantID,
                          resource.rendition == participant.renditionIdentity else { return nil }
                    if descriptorSlot == nil { descriptorSlot = UInt16(slot) }
                }
                guard let descriptorSlot else { return nil }
                let descriptor = LoopbackFrozenParticipantDescriptor(
                    mediaPlaylistSnapshotIdentity: participant.playlistIdentity,
                    metadataSlot: descriptorSlot, mediaType: participant.mediaType)
                switch count {
                case 0: frozen.descriptors.0 = descriptor
                case 1: frozen.descriptors.1 = descriptor
                case 2: frozen.descriptors.2 = descriptor
                case 3: frozen.descriptors.3 = descriptor
                default: return nil
                }
                count += 1
                hasAudio = hasAudio || participant.mediaType == .audio
                hasVideo = hasVideo || participant.mediaType == .video
            }
            if directParticipant != nil {
                guard count == 1 else { return nil }
            } else {
                guard hasVideo || !participants.values.contains(where: { $0.mediaType == .video }),
                      hasAudio || !participants.values.contains(where: { $0.mediaType == .audio })
                else { return reject("pubwait_missing_a\(hasAudio)_v\(hasVideo)") }
            }
            // publication 元数据先取得原 store 租约。未完成 body 只进入内部时间轴依据，
            // 不设置任何 completed 位，也不预支未来 response 的水位。
            owner.frozenPublication = frozen
            metadataTransferred = true
            let evidence = LoopbackPreparationPublicationBasis(preparationOwner: owner)
            return evidence
        }
    }

    /// 只验不可变原签发域与原路径，不依赖当前 publication 或未来 HTTP 完成。
    func preparationRoute(itemURL: URL, item: AVPlayerItemInstanceIdentity) -> UInt8? {
        queueSync {
            guard item.itemGeneration == authorityBinding.origin.itemGeneration,
                  item.outputLifecycleEpoch == authorityBinding.origin.outputLifecycleEpoch,
                  itemURL.scheme == "http", itemURL.host == localHost,
                  itemURL.port == Int(port), itemURL.user == nil, itemURL.password == nil,
                  itemURL.query == nil, itemURL.fragment == nil else { return nil }
            if itemURL.path == masterPath { return 0 }
            for index in frozenParticipants.indices {
                if itemURL.path == frozenParticipants[index].playlistPath { return UInt8(index + 1) }
            }
            return nil
        }
    }

    func preparationRouteValues(_ route: UInt8) -> (URL, AVPlayerItemInstanceIdentity) {
        queueSync {
            precondition(route <= frozenParticipants.count)
            let path = route == 0 ? masterPath : frozenParticipants[Int(route) - 1].playlistPath
            // route 只由上面的完整检查产生；路径、端口和原 origin 均不随 roll 改变。
            let url = URL(string: path, relativeTo: baseURL)!.absoluteURL
            let origin = authorityBinding.origin
            return (url, .init(outputLifecycleEpoch: origin.outputLifecycleEpoch,
                               itemGeneration: origin.itemGeneration))
        }
    }

    /// 从同一 publication snapshot 归约 AVPlayer 准备输入。调用方只提供 Registry
    /// 已签发的 item identity，不能填写 URL、origin、live edge 或 participant binding。
    func makeAVPlayerPreparationRequest(
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64? = nil,
        source: LoopbackAVPlayerPreparationEvidenceSource? = nil
    ) throws -> AVPlayerItemPreparationRequest {
        try queueSync {
            let sequence = publicationSequence ?? authorityBindings.keys.max()
            guard isAdmissionOpen, item.itemGeneration == declaration.itemGeneration,
                  let sequence, let binding = authorityBindings[sequence],
                  binding.itemGeneration == item.itemGeneration,
                  binding.outputLifecycleEpoch == item.outputLifecycleEpoch,
                  let participants = participantsByPublication[sequence],
                  !participants.isEmpty else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            return try makeAVPlayerPreparationRequestLocked(
                item: item, publicationSequence: sequence,
                participants: participants, source: source)
        }
    }

    /// Live writer 的请求由同一 publisher 对下一次 publication 的一次性预约生成。
    /// URL、terminal binding 与 future sequence 都在 server lane 内归约；调用方不能
    /// 用裸序号把一个 server 的 pending writer 接到另一个 publication。
    func makeAVPlayerPreparationRequest(
        item: AVPlayerItemInstanceIdentity,
        pendingPublication: HLSPendingPublicationAuthority,
        source: LoopbackAVPlayerPreparationEvidenceSource? = nil
    ) throws -> AVPlayerItemPreparationRequest {
        try queueSync {
            guard isAdmissionOpen, item.itemGeneration == declaration.itemGeneration,
                  frozenParticipants.values.allSatisfy({
                      $0.writerBinding.outputLifecycleEpoch == item.outputLifecycleEpoch
                  }),
                  let sequence = pendingPublication.consume(
                    serverPublisherIdentity: publisherIdentity,
                    itemGeneration: declaration.itemGeneration,
                    terminalBindings: aacTerminalBindings) else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            return try makeAVPlayerPreparationRequestLocked(
                item: item, publicationSequence: sequence,
                participants: frozenParticipants, source: source)
        }
    }

    private func makeAVPlayerPreparationRequestLocked(
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        participants: some Collection<FrozenParticipant>,
        source: LoopbackAVPlayerPreparationEvidenceSource?
    ) throws -> AVPlayerItemPreparationRequest {
        if let source {
            guard source.belongs(to: self), participants.count == frozenParticipants.count,
                  participants.allSatisfy({ value in frozenParticipants.contains {
                      $0.definition === value.definition
                  } }) else { throw LoopbackHTTPServerError.invalidConfiguration }
        }
        var audioCount = 0
        var onlyAudio: FrozenParticipant?
        for frozen in participants where frozen.mediaType == .audio {
            audioCount += 1; onlyAudio = frozen
            if frozen.audioCodec == .aac {
                guard let terminalBinding = aacTerminalBindings[frozen.participantID],
                      terminalBinding.binding.renditionIdentity
                        == frozen.renditionIdentity,
                      terminalBinding.binding.outputLifecycleEpoch
                        == item.outputLifecycleEpoch else {
                    throw LoopbackHTTPServerError.invalidConfiguration
                }
            }
        }
        let requirements: AVPlayerAudioRequirements
        if let source { requirements = .init(source: source) }
        else {
            // 无准备source的旧直接调用仍拥有显式值数组；生产路径不制造此backing。
            requirements = .init((0..<preparationAudioRequirementCount).map { preparationAudioRequirement(at: $0) })
        }
        let path: String
        let directAudioOnlyRendition: AudioRenditionIdentity?
        if participants.allSatisfy({ $0.mediaType != .video }),
           audioCount == 1, let participant = onlyAudio {
            path = participant.playlistPath
            directAudioOnlyRendition = participant.renditionIdentity
        } else {
            path = masterPath
            directAudioOnlyRendition = nil
        }
        guard let itemURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        return AVPlayerItemPreparationRequest(
            itemURL: itemURL,
            item: item,
            publicationSequence: publicationSequence,
            audioRequirements: requirements,
            directAudioOnlyRendition: directAudioOnlyRendition)
    }

    var preparationAudioRequirementCount: Int {
        frozenParticipants.reduce(0) { $0 + ($1.mediaType == .audio ? 1 : 0) }
    }

    func preparationAudioRequirement(at index: Int) -> AVPlayerAudioParticipantRequirement {
        precondition(index >= 0 && index < preparationAudioRequirementCount)
        var previous: UInt64 = 0
        var selected: FrozenParticipant?
        for _ in 0...index {
            selected = nil
            for value in frozenParticipants where value.mediaType == .audio && value.participantID > previous {
                if selected.map({ value.participantID < $0.participantID }) ?? true { selected = value }
            }
            previous = selected!.participantID
        }
        let value = selected!
        return .init(renditionIdentity: value.renditionIdentity,
            codec: value.audioCodec == .aac ? .aac : .explicitlyNonAAC,
            terminalBinding: aacTerminalBindings[value.participantID],
            renditionBinding: aacRenditionBindings[value.participantID])
    }

    /// completed HTTP facts、selection capability 与 writer terminal authority 在同一
    /// server lane 汇合后才签时间轴。AAC endpoint 的单次消费也在此完成。
    func makePlayerItemTimelineMappingAuthority(
        endpointAuthority: AACEffectiveEndpointAuthority?,
        completedPublication: some LoopbackPublicationFacts,
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        expectedSelection: LoopbackAudioMediaSelectionCapability?
    ) throws -> LoopbackPlayerItemTimelineMappingAdmission {
        try queueSync {
            func reject(_ marker: String) -> LoopbackPlayerItemTimelineMappingAdmission {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("tl_invalid_\(marker)")
                #endif
                return .invalid
            }
            let owner = completedPublication.preparationOwner
            if owner.timelineStorage != nil {
                let cached = owner.timelineAuthority ?? PlayerItemTimelineMappingAuthority(owner: owner)
                guard owner.frozenPublication?.authorityBinding.origin === authorityBinding.origin,
                      cached.matches(itemURL: itemURL, item: item,
                        publicationSequence: publicationSequence, selection: expectedSelection),
                      cached.matchesEndpoint(endpointAuthority) else { return reject("cached") }
                owner.timelineAuthority = cached
                return .ready(cached)
            }
            guard isAdmissionOpen,
                  completedPublication.preparationOwner.frozenPublication?.authorityBinding.origin
                    === authorityBinding.origin,
                  completedPublication.itemURL == itemURL,
                  item.itemGeneration == declaration.itemGeneration,
                  completedPublication.itemGeneration == item.itemGeneration,
                  completedPublication.publicationSequence == publicationSequence,
                  let binding = authorityBindings[publicationSequence],
                  binding.outputLifecycleEpoch == item.outputLifecycleEpoch,
                  completedPublication.preparationOwner.frozenPublication?.authorityBinding == binding else {
                return reject("admission")
            }
            guard let selection = completedPublication.audioSelectionCapability else {
                return .waitingForSelection
            }
            guard let expectedSelection, expectedSelection === selection,
                  audioSelectionByPublication[publicationSequence] === selection,
                  selection.outputLifecycleEpoch == item.outputLifecycleEpoch,
                  selection.belongs(to: binding),
                  let selected = participantsByPublication[publicationSequence]?[selection.participantID],
                  selected.mediaType == .audio,
                  selected.renditionIdentity == selection.renditionIdentity else {
                return reject("selection")
            }
            guard let selectedCodec = selected.audioCodec else { return reject("codec") }

            var origin: ExactMediaTime?
            var referenceParticipant: LoopbackCompletedParticipantEvidence?
            for participant in completedPublication.participants where participant.mediaType == .video
                || participant.participantID == selected.participantID {
                // PTS 对应关系属于原 publication 元数据；尚未 GET 的区间不能改变
                // item 原点。这里只读租约，不为这些 body 签发完成事实。
                var participantOrigin: ExactMediaTime?
                for media in LoopbackCompletedResourceCollection(owner: completedPublication.preparationOwner,
                    participantID: participant.participantID, mode: 1) {
                    let candidate = media.presentationRange.start
                    if participantOrigin.map({ CMTimeCompare(candidate.cmTime, $0.cmTime) < 0 }) ?? true {
                        participantOrigin = candidate
                    }
                }
                guard let participantOrigin else { return reject("origin_\(participant.participantID)") }
                if origin.map({ CMTimeCompare(participantOrigin.cmTime, $0.cmTime) > 0 }) ?? true {
                    origin = participantOrigin
                }
                if referenceParticipant == nil || participant.mediaType == .video {
                    referenceParticipant = participant
                }
            }
            guard let visiblePhysicalOrigin = origin, let reference = referenceParticipant else {
                return reject("reference")
            }

            let endpointReceipt: AACEffectiveEndpointReceipt?
            let writtenPhysicalBase: ExactMediaTime
            let writtenEffectiveBase: ExactMediaTime
            let effectivePlaybackHorizon: ExactMediaTime
            var endpointToConsume: (
                authority: AACEffectiveEndpointAuthority,
                receipt: AACEffectiveEndpointReceipt
            )?
            var prefixReceipt: AACPrefixPlaybackMappingReceipt?
            switch selectedCodec {
            case .aac:
                guard let frozenMapping = selected.aacTimelineMapping else {
                    return reject("aac_mapping")
                }
                if let renditionBinding = aacRenditionBindings[selected.participantID],
                   endpointAuthority == nil {
                    guard let completedParticipant = completedPublication.participants
                        .first(where: { $0.participantID == selected.participantID }) else {
                        return reject("aac_participant")
                    }
                    // 沿传入 facts 的 mode 读取：准备期为 mode 2（真实当前完成），
                    // freeze 后为 mode 0。不得退化成 mode 1 元数据存在即完成。
                    let completedCollection = completedParticipant.completedMedia
                    let completedSlot = completedCollection.indices.first(where: {
                        completedCollection[$0].backingIdentity == selection.backingIdentity
                    })
                    let admission = completedSlot.flatMap {
                        store.aacPublicationAdmission(
                            preparationSlot: $0,
                            ownerSlot: completedPublication.preparationOwner.slot)
                    }
                    let prefix = admission.flatMap {
                        renditionBinding.issuePrefixMapping(
                            publicationSequence: publicationSequence,
                            mapping: frozenMapping,
                            completedLeaf: $0.leaf,
                            admission: $0)
                    }
                    guard let prefix else { return reject("aac_prefix") }
                    endpointReceipt = nil
                    writtenPhysicalBase = prefix.mapping.writtenPhysicalBase
                    writtenEffectiveBase = prefix.mapping.writtenEffectiveBase
                    guard try HLSChecked.compare(selection.selectionWindow.end,
                                                 selected.effectivePlaybackHorizon) <= 0 else {
                        return reject(
                            "aac_horizon_e\(selection.selectionWindow.end.value)_"
                                + "t\(selection.selectionWindow.end.timescale)_"
                                + "h\(selected.effectivePlaybackHorizon.value)_"
                                + "t\(selected.effectivePlaybackHorizon.timescale)"
                        )
                    }
                    effectivePlaybackHorizon = selection.selectionWindow.end
                    prefixReceipt = prefix
                    break
                }
                if let renditionBinding = aacRenditionBindings[selected.participantID] {
                    guard let endpointAuthority else { return .invalid }
                    let terminalBinding = endpointAuthority.terminalBinding
                    let snapshotTerminalBinding = aacTerminalBindings[selected.participantID]
                    guard renditionBinding.owns(endpointAuthority),
                          endpointAuthority.renditionBinding === renditionBinding,
                          let writerFinal = renditionBinding.finalWriterReceipt,
                          writerFinal.terminalBinding === terminalBinding,
                          writerFinal.binding == endpointAuthority.receipt.binding,
                          endpointAuthority.receipt.binding == terminalBinding.binding,
                          endpointAuthority.receipt.binding.outputLifecycleEpoch
                            == item.outputLifecycleEpoch,
                          snapshotTerminalBinding?.acceptsRenditionAnchor(
                            renditionBinding, mapping: frozenMapping) == true else {
                        return .invalid
                    }
                    let receipt = try AVPlayerAACEndpointValidator.preflight(
                        authority: endpointAuthority,
                        completedPublication: completedPublication)
                    guard receipt.timelineOffset == frozenMapping.offset else { return .invalid }
                    guard try HLSChecked.compare(selection.selectionWindow.end,
                                                 selected.effectivePlaybackHorizon) <= 0 else {
                        return .invalid
                    }
                    if participantsByPublication[publicationSequence]?.values.allSatisfy({
                        $0.mediaType != .video
                    }) == true {
                        guard try HLSChecked.compare(receipt.lastEffectiveEnd,
                                                     selected.effectivePlaybackHorizon) == 0 else {
                            return .invalid
                        }
                    } else {
                        guard try HLSChecked.compare(receipt.lastEffectiveEnd,
                                                     selected.effectivePlaybackHorizon) >= 0 else {
                            return .invalid
                        }
                    }
                    endpointReceipt = receipt
                    writtenPhysicalBase = receipt.writtenPhysicalBase
                    writtenEffectiveBase = receipt.writtenEffectiveBase
                    effectivePlaybackHorizon = selection.selectionWindow.end
                    endpointToConsume = (endpointAuthority, receipt)
                    break
                }
                guard let endpointAuthority,
                      let terminalBinding = aacTerminalBindings[selected.participantID],
                      terminalBinding === endpointAuthority.terminalBinding,
                      terminalBinding.endpointAuthority === endpointAuthority,
                      endpointAuthority.receipt.binding
                        == terminalBinding.binding,
                      endpointAuthority.receipt.binding.outputLifecycleEpoch
                        == item.outputLifecycleEpoch,
                      frozenMapping.binding == terminalBinding.binding else { return .invalid }
                let receipt = try AVPlayerAACEndpointValidator.preflight(
                    authority: endpointAuthority,
                    completedPublication: completedPublication)
                guard receipt.mappingReportIdentity == frozenMapping.reportIdentity,
                      receipt.sampleRate == frozenMapping.sampleRate,
                      receipt.inputPhysicalBase == frozenMapping.inputPhysicalBase,
                      receipt.inputEffectiveBase == frozenMapping.inputEffectiveBase,
                      receipt.writtenPhysicalBase == frozenMapping.writtenPhysicalBase,
                      receipt.writtenEffectiveBase == frozenMapping.writtenEffectiveBase,
                      receipt.timelineOffset == frozenMapping.offset else { return .invalid }
                // selection window、playlist horizon 与 writer 有效端 N 必须是同一
                // 数值；timescale 表示不同不应把同一媒体时间误判为跨 authority。
                guard try HLSChecked.compare(selection.selectionWindow.end,
                                             selected.effectivePlaybackHorizon) <= 0 else {
                    return .invalid
                }
                if participantsByPublication[publicationSequence]?.values.allSatisfy({
                    $0.mediaType != .video
                }) == true {
                    guard try HLSChecked.compare(receipt.lastEffectiveEnd,
                                                 selected.effectivePlaybackHorizon) == 0 else {
                        return .invalid
                    }
                } else {
                    guard try HLSChecked.compare(receipt.lastEffectiveEnd,
                                                 selected.effectivePlaybackHorizon) >= 0 else {
                        return .invalid
                    }
                }
                endpointReceipt = receipt
                writtenPhysicalBase = frozenMapping.writtenPhysicalBase
                writtenEffectiveBase = frozenMapping.writtenEffectiveBase
                effectivePlaybackHorizon = selection.selectionWindow.end
                endpointToConsume = (endpointAuthority, receipt)
            case .ac3, .eac3:
                guard endpointAuthority == nil else { return .invalid }
                endpointReceipt = nil
                writtenPhysicalBase = visiblePhysicalOrigin
                writtenEffectiveBase = visiblePhysicalOrigin
                guard try HLSChecked.compare(selection.selectionWindow.end,
                                             selected.effectivePlaybackHorizon) <= 0 else {
                    return .invalid
                }
                effectivePlaybackHorizon = selection.selectionWindow.end
            }
            let effectiveOffset = try writtenEffectiveBase.subtracting(writtenPhysicalBase)
            let effectiveSourceOrigin = try visiblePhysicalOrigin.adding(effectiveOffset)
            guard try HLSChecked.compare(effectiveSourceOrigin,
                                         effectivePlaybackHorizon) <= 0 else {
                return reject("effective_origin")
            }
            let referenceOffset = reference.mediaType == .audio
                ? effectiveOffset : ExactMediaTime(value: 0, timescale: 1)
            let commonSampleBoundaries = try PlayerItemCommonSampleBoundaries(
                evidence: completedPublication, participantID: reference.participantID,
                offset: referenceOffset, initial: selection.selectionWindow.start,
                horizon: effectivePlaybackHorizon)
            guard !commonSampleBoundaries.isEmpty,
                  commonSampleBoundaries.count <= 128 else { return reject("boundaries") }
            if let endpointToConsume {
                _ = try AVPlayerAACEndpointValidator.consume(
                    authority: endpointToConsume.authority,
                    verifiedReceipt: endpointToConsume.receipt)
            }
            owner.timelineStorage = .init(identity: UUID(),
                visiblePhysicalOrigin: visiblePhysicalOrigin,
                effectiveSourceOrigin: effectiveSourceOrigin,
                effectivePlaybackHorizon: effectivePlaybackHorizon,
                endpointAuthority: endpointReceipt == nil ? nil : endpointAuthority,
                prefixReceipt: prefixReceipt)
            let mappingAuthority = PlayerItemTimelineMappingAuthority(owner: owner)
            owner.timelineAuthority = mappingAuthority
            return .ready(mappingAuthority)
        }
    }

    func consumeCompletedPublicationCapability(
        _ capability: LoopbackCompletedPublicationCapability
    ) -> LoopbackCompletedPublicationEvidence? {
        capability.consume(serverIdentity: serverIdentity,
                           sessionCapabilityIdentity: sessionCapability.identity,
                           port: port)
    }

    /// 真实 response send terminal 的单槽通知；值仅用于要求消费者重新取得 opaque evidence。
    func installCompletedPublicationEventHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        queueSync { publicationEventHandler = handler }
    }

    /// 每次真实 resource full-body/range union 进入 completed ledger 后只发一个边沿；
    /// 消费者必须重新取得同 server 的 opaque publication capability，边沿本身不授予权限。
    func installCompletedResourceEventHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        queueSync { completedResourceEventHandler = handler }
    }

    /// rendition selection 与 publication sequence 前进是两条独立通道。
    func installRenditionSelectionEventHandler(
        _ handler: @escaping @Sendable (LoopbackAudioMediaSelectionCapability) -> Void
    ) {
        queueSync { renditionSelectionEventHandler = handler }
    }

    /// 只保留一个 evidence-source waiter。失败先于安装时会保存首个终态，并在安装
    /// 后补发；一旦交付，后续 response failure 或 close/retire 不会重复恢复 waiter。
    func installTimelineFailureEventHandler(
        _ handler: @escaping @Sendable (LoopbackTimelineFailureEvent) -> Void
    ) {
        let immediate = queueSync { () -> LoopbackTimelineFailureEvent? in
            guard timelineFailureEventHandler == nil,
                  !timelineFailureWasDelivered else { return nil }
            if let event = timelineFailureEvent {
                timelineFailureWasDelivered = true
                return event
            }
            timelineFailureEventHandler = handler
            return nil
        }
        if let immediate { deliverTimelineFailure(immediate, to: handler) }
    }

    func currentAudioSelectionCapability(itemGeneration: UInt64,
                                         publicationSequence: UInt64)
        -> LoopbackAudioMediaSelectionCapability? {
        queueSync {
            guard itemGeneration == declaration.itemGeneration,
                  let binding = authorityBindings[publicationSequence],
                  let capability = audioSelectionByPublication[publicationSequence],
                  capability.belongs(to: binding) else { return nil }
            return capability
        }
    }

    /// 由 server 冻结的 route/HMAC/store availability 回答，不能从 path 数字猜 rendition。
    func classifyAccessLogURI(_ observed: URL,
                              itemGeneration: UInt64,
                              publicationSequence: UInt64,
                              selected: AudioRenditionIdentity?)
        -> AccessLogURIClassification {
        queueSync {
            guard observed.host == localHost else { return .unrelated }
            guard observed.scheme == "http", observed.port == Int(port),
                  observed.user == nil, observed.password == nil,
                  observed.fragment == nil,
                  let binding = authorityBindings[publicationSequence],
                  binding.itemGeneration == itemGeneration,
                  let participants = participantsByPublication[publicationSequence],
                  let components = URLComponents(url: observed,
                                                 resolvingAgainstBaseURL: false),
                  components.percentEncodedPath == observed.path,
                  !observed.absoluteString.lowercased().contains("%2e") else {
                return .invalidLocalResource
            }
            let target = components.percentEncodedPath
                + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            let participant: FrozenParticipant?
            if let route = routes[target] {
                switch route {
                case .playlist(let playlist):
                    participant = playlist.participantID.flatMap { participants[$0] }
                case .resource(let resource):
                    participant = participants[resource.key.participantID]
                }
            } else {
                switch store.resolveHTTPResourceURI(target, now: now()) {
                case .available(let descriptor):
                    guard let frozen = participants[descriptor.key.participantID],
                          frozen.initializationKeys.contains(descriptor.key)
                            || frozen.mediaKeys.contains(descriptor.key) else {
                        return .invalidLocalResource
                    }
                    participant = frozen
                case .gone, .notFound:
                    return .invalidLocalResource
                }
            }
            guard let participant, participant.mediaType == .audio else {
                return .unrelated
            }
            guard let selected else { return .unrelated }
            return participant.renditionIdentity == selected ? .matching : .conflicting
        }
    }

    func verifiedCoverage(using evidence: LoopbackCompletedPublicationEvidence,
                          context: LoopbackCoverageContext,
                          requested: FMP4PresentationRange) throws
        -> ServedRenditionCoverageReceipt? {
        try verifiedCoverageEvidence(using: evidence, context: context,
                                     effectiveRequested: requested)?.physicalReceipt
    }

    /// AVPlayer 准备路径明确区分有效播放区间与 fMP4 物理区间。返回值中的
    /// dependency 仍来自物理 completed-response receipt，而暴露给 coordinator 的
    /// presentation range 只能是 server authority 验证过的有效区间。
    func verifiedAVPlayerCoverage(
        using evidence: LoopbackCompletedPublicationEvidence,
        context: LoopbackCoverageContext,
        requested: FMP4PresentationRange
    ) throws -> LoopbackAVPlayerCoverageEvidence? {
        try verifiedCoverageEvidence(using: evidence, context: context,
                                     effectiveRequested: requested)
    }

    /// `loadedTimeRanges` 可以先于本地 HTTP send-terminal 回调可见。冻结 owner
    /// 之前先用当前单调完成事实确认所有必需 rendition 已具备目标闭包；一旦返回
    /// true，后续 freeze 只会取得同一事实或其超集，不会把暂缺的 body 永久冻结。
    func preparationCoverageCanFreeze(
        owner: FrozenPreparationOwner,
        context: LoopbackCoverageContext,
        requested: FMP4PresentationRange
    ) throws -> Bool {
        try queueSync {
            func reject(_ marker: String) -> Bool {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(marker)
                #endif
                return false
            }
            guard !owner.completionIsFrozen else { return reject("covwait_already_frozen") }
            guard let publication = owner.frozenPublication else {
                return reject("covwait_no_publication")
            }
            guard publication.authorityBinding.origin === authorityBinding.origin,
                  publication.authorityBinding.itemGeneration == declaration.itemGeneration else {
                return reject("covwait_authority")
            }
            guard let selection = publication.audioSelectionCapability,
                  audioSelectionByPublication[publication.authorityBinding.publicationSequence]
                    === selection,
                  context.preparedPlayheadIdentity.audioSelectionCapability === selection else {
                return reject("covwait_selection")
            }
            guard context.observedRenditionSetReceipt.preparedPlayheadIdentity
                    == context.preparedPlayheadIdentity,
                  context.observedRenditionSetReceipt.orderedRenditionIdentities
                    .contains(context.renditionIdentity) else {
                return reject("covwait_receipt")
            }
            guard let participant = LoopbackPreparationPublicationBasis(
                preparationOwner: owner
            ).participants.first(where: {
                $0.renditionIdentity == context.renditionIdentity
            }) else {
                return reject("covwait_participant")
            }
            guard participant.mediaType != .audio
                    || participant.renditionIdentity == selection.renditionIdentity else {
                return reject("covwait_audio_selection")
            }
            guard CMTimeCompare(selection.selectionWindow.start.cmTime,
                                requested.start.cmTime) <= 0,
                  CMTimeCompare(selection.selectionWindow.end.cmTime,
                                requested.end.cmTime) >= 0 else {
                return reject("covwait_selection_window")
            }
            let timeline = context.preparedPlayheadIdentity.timelineMappingAuthority
            let physicalRequested: FMP4PresentationRange
            if participant.mediaType == .audio,
               timeline.aacPrefixReceipt != nil || timeline.aacEndpointReceipt != nil {
                physicalRequested = try timeline.physicalRange(
                    forEffectiveSourceRange: requested
                )
            } else {
                physicalRequested = requested
            }
            guard Self.completedMediaCovers(
                participant.completedMedia,
                requested: physicalRequested
            ) else {
                return reject(participant.mediaType == .audio
                    ? "covwait_audio_http_range" : "covwait_video_http_range")
            }
            let storeReady = try store.preparationCoverageCanFreeze(
                owner: owner,
                rendition: context.renditionIdentity,
                requested: physicalRequested
            )
            if !storeReady {
                return reject(participant.mediaType == .audio
                    ? "covwait_audio_decode_map" : "covwait_video_decode_map")
            }
            return true
        }
    }

    private func verifiedCoverageEvidence(
        using evidence: LoopbackCompletedPublicationEvidence,
        context: LoopbackCoverageContext,
        effectiveRequested: FMP4PresentationRange
    ) throws -> LoopbackAVPlayerCoverageEvidence? {
        try queueSync {
            let timeline = context.preparedPlayheadIdentity.timelineMappingAuthority
            guard evidence.belongs(serverIdentity: serverIdentity,
                                   sessionCapabilityIdentity: sessionCapability.identity,
                                   port: port),
                  evidence.itemGeneration == declaration.itemGeneration,
                  case let binding = evidence.authorityBinding,
                  evidence.belongs(to: binding),
                  let selection = evidence.audioSelectionCapability,
                  audioSelectionByPublication[evidence.publicationSequence].map({
                      $0 === selection
                  }) ?? true,
                  selection.belongs(serverIdentity: serverIdentity,
                                    sessionCapabilityIdentity: sessionCapability.identity,
                                    port: port),
                  context.preparedPlayheadIdentity.audioSelectionCapability === selection,
                  timeline.belongs(to: binding, selection: selection),
                  context.preparedPlayheadIdentity.itemGeneration == evidence.itemGeneration,
                  context.observedRenditionSetReceipt.preparedPlayheadIdentity
                    == context.preparedPlayheadIdentity,
                  let participant = evidence.participants.first(where: {
                      $0.renditionIdentity == context.renditionIdentity
                  }),
                  participant.mediaType != .audio
                    || participant.renditionIdentity == selection.renditionIdentity,
                  CMTimeCompare(selection.selectionWindow.start.cmTime,
                                effectiveRequested.start.cmTime) <= 0,
                  CMTimeCompare(selection.selectionWindow.end.cmTime,
                                effectiveRequested.end.cmTime) >= 0 else { return nil }
            let physicalRequested: FMP4PresentationRange
            if participant.mediaType == .audio,
               timeline.aacPrefixReceipt != nil || timeline.aacEndpointReceipt != nil {
                physicalRequested = try timeline.physicalRange(
                    forEffectiveSourceRange: effectiveRequested)
            } else {
                physicalRequested = effectiveRequested
            }
            guard
                  Self.completedMediaCovers(
                      participant.completedMedia,
                      requested: physicalRequested
                  ) else { return nil }
            guard let receipt = try store.preparationCoverageReceipt(
                owner: evidence.preparationOwner, context: context,
                requested: physicalRequested) else {
                return nil
            }
            return .init(physicalReceipt: receipt,
                         effectivePresentationRange: effectiveRequested)
        }
    }

    /// full-body terminal 按单个 HTTP response 记录；readiness 的三秒合同则要求
    /// 同一冻结 participant 的连续联合区间。这里只在 128 个有界事实内排序并合并
    /// 重叠/相邻区间，不能由某一个一秒 segment 冒充三秒 coverage。
    private static func completedMediaCovers(
        _ media: LoopbackCompletedResourceCollection,
        requested: FMP4PresentationRange
    ) -> Bool {
        guard !media.isEmpty, media.count <= completedResponseFactCapacity else {
            return false
        }
        var cursor = requested.start
        for _ in 0..<completedResponseFactCapacity {
            var next = cursor
            for item in media {
                let range = item.presentationRange
                if CMTimeCompare(range.start.cmTime, cursor.cmTime) <= 0,
                   CMTimeCompare(range.end.cmTime, next.cmTime) > 0 { next = range.end }
            }
            if CMTimeCompare(next.cmTime, requested.end.cmTime) >= 0 { return true }
            guard CMTimeCompare(next.cmTime, cursor.cmTime) > 0 else { return false }
            cursor = next
        }
        return false
    }

    func acceptedGETSnapshot() -> LoopbackAcceptedGETSnapshot { queueSync {
        .init(playlistCount: acceptedPlaylistGETCount,
              initializationCount: acceptedInitializationGETCount,
              mediaCount: acceptedMediaGETCount)
    } }

    func coverageReceipt(for context: LoopbackCoverageContext,
                         adding requested: FMP4PresentationRange) throws
        -> ServedRenditionCoverageReceipt? { try queueSync {
        guard context.preparedPlayheadIdentity.itemGeneration == declaration.itemGeneration,
              context.observedRenditionSetReceipt.preparedPlayheadIdentity
                == context.preparedPlayheadIdentity,
              context.observedRenditionSetReceipt.orderedRenditionIdentities
                .contains(context.renditionIdentity) else { return nil }
        if !coverageContexts.contains(context) {
            guard coverageContexts.count < 8 else {
                throw CompletedMediaEvidenceError.capacityExceeded
            }
            coverageContexts.insert(context)
            maximumParserAndStagingBytes = max(maximumParserAndStagingBytes,
                                                 parserAndStagingBytes)
        }
        return try store.coverageReceipt(for: context, adding: requested)
    } }

    func closeAdmission() -> LoopbackHTTPCleanupTicket {
        var shouldLog = false
        var timelineDelivery: (
            LoopbackTimelineFailureEvent,
            @Sendable (LoopbackTimelineFailureEvent) -> Void
        )?
        let ticket = queueSync {
            switch phase {
            case .open:
                let ticket = LoopbackHTTPCleanupTicket()
                phase = .closed(ticket)
                timelineDelivery = recordTimelineFailureLocked(
                    .serverTerminated(itemGeneration: declaration.itemGeneration))
                for connection in Array(connections.values) { connection.stop(terminal: .cancelled) }
                shouldLog = true
                return ticket
            case .closed(let ticket), .drained(let ticket), .retired(let ticket): return ticket
            }
        }
        if let (event, handler) = timelineDelivery {
            deliverTimelineFailure(event, to: handler)
        }
        if shouldLog { logger("loopback admission closed") }
        return ticket
    }

    func drain(cleanupTicket: LoopbackHTTPCleanupTicket) throws {
        try queueSync {
            guard case .closed(let expected) = phase, expected === cleanupTicket,
                  connections.isEmpty, closingConnections.isEmpty,
                  activeResponses == 0 else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            phase = .drained(cleanupTicket)
        }
    }

    func retire(cleanupTicket: LoopbackHTTPCleanupTicket) throws {
        let cleanup = try queueSync { () throws
            -> [(AACRenditionTerminalBinding, UUID)] in
            guard case .drained(let expected) = phase, expected === cleanupTicket else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            guard backingLedger.usage.distinctBackingCount == 0,
                  connections.isEmpty, closingConnections.isEmpty,
                  activeResponses == 0 else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            coverageContexts.removeAll(keepingCapacity: false)
            aacHTTPMembership.removeAll(keepingCapacity: false)
            terminalAACHTTPLeaves.removeAll(keepingCapacity: false)
            terminalAACHTTPKeys.removeAll(keepingCapacity: false)
            aacHTTPFinalizationGates.removeAll(keepingCapacity: false)
            let observers = aacPublicationSealObserverTokens.compactMap {
                participantID, identity in
                aacRenditionBindings[participantID].map { ($0, identity) }
            }
            aacPublicationSealObserverTokens.removeAll(keepingCapacity: false)
            // observer/已排队尾沿仍各持同一lease；server只放弃自身alias，
            // 最后一个真实尾沿退出后由lease析构退全局delivery账。
            aacFinalizationChargeLease = nil
            phase = .retired(cleanupTicket)
            store.close()
            return observers
        }
        for (binding, identity) in cleanup {
            binding.removePublicationSealObserver(identity)
        }
        listener.cancel()
        logger("loopback retired")
    }

    private func recordTimelineFailureLocked(
        _ event: LoopbackTimelineFailureEvent
    ) -> (LoopbackTimelineFailureEvent,
          @Sendable (LoopbackTimelineFailureEvent) -> Void)? {
        guard timelineFailureEvent == nil else { return nil }
        timelineFailureEvent = event
        guard let handler = timelineFailureEventHandler else { return nil }
        timelineFailureEventHandler = nil
        timelineFailureWasDelivered = true
        return (event, handler)
    }

    private func publishTimelineFailure(_ event: LoopbackTimelineFailureEvent) {
        let delivery = queueSync { recordTimelineFailureLocked(event) }
        if let (event, handler) = delivery {
            deliverTimelineFailure(event, to: handler)
        }
    }

    private func deliverTimelineFailure(
        _ event: LoopbackTimelineFailureEvent,
        to handler: @escaping @Sendable (LoopbackTimelineFailureEvent) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { handler(event) }
    }

    /// 复用HTTP原串行lane承载准备域唯一retry唤醒，不另建队列或Task。
    /// retry只同步核metadata；它调用的queueSync在原lane上直接执行，
    /// 不等待未来HTTP，也不持source锁跨入此lane。
    func enqueuePreparationRetry(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    private func queueSync<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }

    private func installStartupEndpointProbe(_ completion: @escaping (Bool) -> Void) {
        queueSync { startupEndpointProbe = completion }
    }

    private func cancelStartupEndpointProbe() {
        queueSync { startupEndpointProbe = nil }
    }

    private func install(snapshot: HLSPublishedSnapshot) throws {
        guard snapshot.participantVector.allSatisfy({
            $0.declaration.itemGeneration == declaration.itemGeneration
                && $0.declaration.token == declaration.token
        }) else { throw LoopbackHTTPServerError.invalidConfiguration }
        if let master = snapshot.master {
            routes[masterPath] = .playlist(.init(participantID: nil,
                rawLength: master.raw.count, gzipLength: master.gzip.count,
                rawETag: Self.etag(master.raw), gzipETag: Self.etag(master.gzip)))
        }
        guard Set(snapshot.media.keys) == Set(frozenParticipants.keys),
              Set(frozenParticipants.values.map(\.playlistPath)).count
                == frozenParticipants.count else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        for (participantID, playlist) in snapshot.media {
            guard let participant = frozenParticipants[participantID] else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            let playlistPath = participant.playlistPath
            routes[playlistPath] = .playlist(.init(participantID: participantID,
                rawLength: playlist.raw.count, gzipLength: playlist.gzip.count,
                rawETag: Self.etag(playlist.raw), gzipETag: Self.etag(playlist.gzip)))
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, self.isIPv4Loopback(connection.endpoint) else {
                connection.cancel(); return
            }
            let closing: Bool
            switch self.phase {
            case .drained, .retired:
                connection.cancel()
                return
            case .closed:
                closing = true
            case .open:
                closing = false
            }
            let projectedConnectionCount = self.connections.count + self.closingConnections.count + 1
            let projected = LoopbackHTTPUsage(connections: projectedConnectionCount,
                activeResponses: self.activeResponses,
                distinctBackingBytes: self.reservedBackingBytes,
                parserAndStagingBytes: projectedConnectionCount
                    * LoopbackStorageLayout.current.parserAllocationBytes
                    + self.activeResponses * LoopbackStorageLayout.current.stagingAllocationBytes
                    + self.coverageContexts.count
                        * LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes)
            let capacity = LoopbackHTTPLimits.standard.classify(projected)
            guard capacity != .hardExceeded else { connection.cancel(); return }
            let parserReservation: PlaybackApplicationChargeReservation
            do {
                parserReservation = try HLSDeliveryApplicationChargeLedger.shared.reserve(
                    allocationIdentity: UUID(),
                    bytes: LoopbackStorageLayout.current.parserAllocationBytes)
            } catch LoopbackHTTPReservationError.backpressure {
                self.softBackpressureCount += 1
                connection.cancel()
                return
            } catch {
                connection.cancel(); return
            }
            let context = LoopbackHTTPConnection(connection: connection, server: self,
                parserReservation: parserReservation)
            if closing { self.closingConnections[ObjectIdentifier(context)] = context }
            else { self.connections[ObjectIdentifier(context)] = context }
            self.maximumConnections = max(self.maximumConnections,
                                          self.connections.count + self.closingConnections.count)
            self.maximumParserAndStagingBytes = max(self.maximumParserAndStagingBytes,
                                                     self.parserAndStagingBytes)
            if capacity == .backpressure { self.softBackpressureCount += 1 }
            // closed 连接只解析一个请求并返回 410；仍记 soft 水位，但保留到 hard cap 才能证明同一 admission gate。
            context.start(overloaded: !closing && capacity == .backpressure)
        }
    }

    fileprivate func connectionReady(_ context: LoopbackHTTPConnection) -> Bool {
        let accepted: Bool
        if let local = context.connection.currentPath?.localEndpoint,
           let remote = context.connection.currentPath?.remoteEndpoint,
           let listenerHost = IPv4Address("127.0.0.1"),
           let listenerPort = NWEndpoint.Port(rawValue: port) {
            let listenerEndpoint: NWEndpoint = .hostPort(host: .ipv4(listenerHost), port: listenerPort)
            accepted = LoopbackEndpointValidator.accepts(listener: listenerEndpoint, local: local,
                remote: remote, expectedPort: port)
        } else {
            accepted = false
        }
        if let probe = startupEndpointProbe {
            startupEndpointProbe = nil
            probe(accepted)
        }
        return accepted
    }

    fileprivate func handle(_ request: LoopbackHTTPRequest, on context: LoopbackHTTPConnection) {
        guard request.values(forHeader: "Host") == ["127.0.0.1:\(port)"],
              Self.validTargetShape(request.target) else {
            sendStatus(400, on: context); return
        }
        switch request.method {
        case .unsupported: sendStatus(405, on: context); return
        case .get, .head: break
        }
        guard let authorization = Self.authorizationComponents(request.target),
              authorization.itemGeneration == declaration.itemGeneration,
              LoopbackSessionToken.matches(candidate: authorization.token,
                                           expected: declaration.token) else {
            sendStatus(404, on: context); return
        }
        guard let route = routes[request.target] else {
            let pathOnly = request.target.split(separator: "?", maxSplits: 1,
                omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if request.target.contains("?"), routes[pathOnly].map({ route in
                if case .playlist = route { return true }; return false
            }) == true { sendStatus(400, on: context) }
            else {
                switch store.resolveHTTPResourceURI(request.target, now: now()) {
                case .notFound: sendStatus(404, on: context)
                case .gone: sendStatus(410, on: context)
                case .available(let descriptor):
                    guard isAdmissionOpen else { sendStatus(410, on: context); return }
                    guard store.completedEvidenceSnapshot(for: descriptor.key) != nil else {
                        sendStatus(404, on: context); return
                    }
                    let resource = ResourceRoute(key: descriptor.key, path: request.target,
                        length: descriptor.byteCount, backingIdentity: descriptor.backingIdentity,
                        sealedDigest: descriptor.sealedDigest,
                        etag: Self.etag(digest: descriptor.sealedDigest),
                        mediaType: descriptor.mediaType,
                        aacMediaMembershipLeaf: descriptor.aacMediaMembershipLeaf,
                        aacPublicationAdmission: descriptor.aacPublicationAdmission)
                    if request.method == .get {
                        if resource.key.kind == .initialization {
                            acceptedInitializationGETCount += 1
                        } else {
                            acceptedMediaGETCount += 1
                        }
                    }
                    serveResource(resource, request: request, on: context)
                }
            }
            return
        }
        switch route {
        case .playlist(let playlist):
            guard isAdmissionOpen else { sendStatus(410, on: context); return }
            if request.method == .get { acceptedPlaylistGETCount += 1 }
            servePlaylist(playlist, request: request, on: context)
        case .resource(let resource):
            guard isAdmissionOpen else { sendStatus(410, on: context); return }
            if request.method == .get {
                if resource.key.kind == .initialization { acceptedInitializationGETCount += 1 }
                else { acceptedMediaGETCount += 1 }
            }
            serveResource(resource, request: request, on: context)
        }
    }

    private var isAdmissionOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    private static func covers(_ actual: FMP4PresentationRange,
                               _ requested: FMP4PresentationRange) -> Bool {
        CMTimeCompare(actual.start.cmTime, requested.start.cmTime) <= 0
            && CMTimeCompare(actual.end.cmTime, requested.end.cmTime) >= 0
    }

    private func servePlaylist(_ route: PlaylistRoute, request: LoopbackHTTPRequest,
                               on context: LoopbackHTTPConnection) {
        let gzip = Self.acceptsGzip(request.values(forHeader: "Accept-Encoding"))
        let head = request.method == .head
        if !head, !beginActive(on: context) {
            sendStatus(503, on: context)
            return
        }
        let lease: HLSPlaylistResponseLease?
        do {
            if let participantID = route.participantID {
                lease = try store.acquireSnapshot(participantID: participantID, now: now())
            } else {
                lease = try store.acquireMasterSnapshot(now: now())
            }
        } catch {
            if !head { activeFinished(context) }
            sendStatus(503, on: context)
            return
        }
        guard let lease, let body = lease.withSnapshot({ gzip ? $0.gzip : $0.raw }) else {
            if let lease { store.release(lease, completedAt: nil, now: now()) }
            if !head { activeFinished(context) }
            sendStatus(410, on: context); return
        }
        let headers = playlistHeaders(length: body.count, etag: Self.etag(body), gzip: gzip)
        if head {
            store.release(lease, completedAt: nil, now: now())
            context.send(status: 200, headers: headers, close: Self.mustClose(request))
            return
        }
        let playlistSnapshot = lease.withSnapshot { $0 }
        let playlistKey: CompletedPlaylistKey = route.participantID.map {
            .media(participantID: $0)
        } ?? .master
        // master 内容可跨 publication 复用；response admission 必须冻结当时 store
        // 的完整 publication 版本，不能拿 master snapshot 自身的历史 version(0/1)。
        let masterResponseAuthority: LoopbackPublicationAuthorityBinding? =
            route.participantID == nil && playlistSnapshot != nil
            ? publicationAuthority(
                sequence: lease.publicationVersion,
                snapshotIdentity: playlistSnapshot!.identity)
            : nil
        let historyAdmissionToken = activePreparationHistoryAdmissionToken
        let terminalIdentity = UUID()
        let responseLeaseIdentity = ObjectIdentifier(lease)
        context.setActiveCleanup { [weak self, store, now] terminal in
            if terminal == .success, let playlistSnapshot {
                self?.recordCompletedPlaylist(key: playlistKey,
                    snapshot: playlistSnapshot,
                    masterResponseAuthority: masterResponseAuthority,
                    historyAdmissionToken: historyAdmissionToken,
                    responseLeaseIdentity: responseLeaseIdentity,
                    connectionIdentity: context.identity,
                    sendTerminalIdentity: terminalIdentity)
            }
            store.release(lease, completedAt: terminal == .success ? now() : nil, now: now())
        }
        context.send(status: 200, headers: headers, body: body, close: Self.mustClose(request))
    }

    private func serveResource(_ route: ResourceRoute, request: LoopbackHTTPRequest,
                               on context: LoopbackHTTPConnection) {
        switch store.lookup(route.key, token: declaration.token, now: now()) {
        case .gone: sendStatus(410, on: context); return
        case .notFound: sendStatus(404, on: context); return
        case .available: break
        }
        if request.method == .head {
            context.send(status: 200, headers: resourceHeaders(route: route, range: nil),
                         close: Self.mustClose(request)); return
        }
        // publication 归属在 GET admission 冻结；长响应完成期间即使 playlist
        // 前进，也不能把旧响应的 terminal 追记到新版本。
        let responseAuthority = resourceResponseAuthority(for: route)
        let historyAdmissionToken = activePreparationHistoryAdmissionToken
        var selected = 0..<route.length
        var status = 200
        let ranges = request.values(forHeader: "Range")
        if let header = ranges.first {
            guard ranges.count == 1 else { sendStatus(400, on: context); return }
            do {
                switch try HTTPRange.parse(header, resourceLength: route.length) {
                case .single(let range): selected = range; status = 206
                case .ignoreAndServeFull: break
                case .unsatisfied:
                    context.send(status: 416,
                        headers: ["Content-Range": "bytes */\(route.length)", "Accept-Ranges": "bytes"],
                        close: Self.mustClose(request)); return
                }
            } catch { sendStatus(400, on: context); return }
        }
        guard beginActive(on: context, backingIdentity: route.backingIdentity,
                          backingBytes: route.length) else {
            sendStatus(503, on: context); return
        }
        let lease: HLSMediaResponseLease?
        do { lease = try store.acquireResponse(route.key, token: declaration.token, now: now(), range: selected) }
        catch { activeFinished(context); sendStatus(503, on: context); return }
        guard let lease, lease.backingIdentity == route.backingIdentity else {
            if let lease { store.release(lease, now: now()) }
            activeFinished(context); sendStatus(410, on: context); return
        }
        let tracker = LoopbackSendCompletionTracker(lease: lease,
            connectionIdentity: context.identity)
        context.setActiveCleanup { [weak self, store, now, responseFailure,
                                    key = route.key] terminal in
            var failure: CompletedMediaEvidenceError?
            do {
                if let capability = tracker.terminalCapability(terminal) {
                    try store.complete(lease, terminal: capability, now: now())
                    self?.recordCompletedResource(route: route,
                        responseAuthority: responseAuthority,
                        historyAdmissionToken: historyAdmissionToken, lease: lease,
                        sendTerminalIdentity: capability.terminalIdentity)
                } else { store.release(lease, now: now()) }
            } catch let error as CompletedMediaEvidenceError {
                failure = error
                store.release(lease, now: now())
            } catch {
                failure = .identityMismatch
                store.release(lease, now: now())
            }
            if let failure, let responseAuthority {
                self?.publishTimelineFailure(.publicationTerminated(
                    itemGeneration: responseAuthority.binding.itemGeneration,
                    publicationSequence: responseAuthority.binding.publicationSequence,
                    resource: key,
                    failure: failure))
            }
            if let failure {
                DispatchQueue.global(qos: .userInitiated).async { responseFailure(key, failure) }
            }
        }
        context.send(status: status,
            headers: resourceHeaders(route: route, range: status == 206 ? selected : nil),
            lease: lease, absoluteRange: selected, tracker: tracker, close: Self.mustClose(request))
    }

    private func recordCompletedPlaylist(
        key: CompletedPlaylistKey,
        snapshot: HLSPlaylistSnapshot,
        masterResponseAuthority: LoopbackPublicationAuthorityBinding?,
        historyAdmissionToken: PreparationHistoryAdmissionToken?,
        responseLeaseIdentity: ObjectIdentifier,
        connectionIdentity: UUID,
        sendTerminalIdentity: UUID
    ) {
        queueSync {
            guard let historyAdmissionToken,
                  historyAdmissionToken.ownerSlot == activePreparationOwnerSlot,
                  historyAdmissionToken.generation == activePreparationHistoryGeneration
            else { return }
            let binding: LoopbackPublicationAuthorityBinding
            switch key {
            case .master:
                guard let masterResponseAuthority,
                      authorityBindings[masterResponseAuthority.publicationSequence]
                        == masterResponseAuthority else { return }
                binding = masterResponseAuthority
            case .media(let participantID):
                guard let frozen = try? Self.freezeParticipant(
                    participantID: participantID, snapshot: snapshot,
                    declaration: declaration, fallback: frozenParticipants[participantID])
                else { return }
                let existing = authorityBindings[snapshot.version]
                if let existing {
                    guard existing.outputLifecycleEpoch
                            == frozen.writerBinding.outputLifecycleEpoch else { return }
                }
                if participantsByPublication[snapshot.version] == nil,
                   participantsByPublication.count == 9,
                   let oldest = participantsByPublication.keys.min() {
                    participantsByPublication.removeValue(forKey: oldest)
                    if let slot = authorityBindings.slot(for: oldest) {
                        completedPlaylistFacts.removeAll { $0.publicationSlot == slot }
                        completedResourceFacts.removeAll { $0.publicationSlot == slot }
                    }
                    authorityBindings.removeValue(forKey: oldest)
                    audioSelectionByPublication.removeValue(forKey: oldest)
                }
                var participants = participantsByPublication[snapshot.version] ?? [:]
                participants[participantID] = frozen
                participantsByPublication[snapshot.version] = participants
                if let existing {
                    binding = existing
                } else {
                    binding = .init(origin: authorityBinding.origin,
                        publicationSequence: snapshot.version,
                        publicationSnapshotIdentity: snapshot.identity)
                    authorityBindings[snapshot.version] = binding
                }
            }
            guard !completedPlaylistFacts.contains(where: {
                $0.authority == binding && $0.key == key
                    && (key == .master || $0.snapshotIdentity == snapshot.identity)
            }), completedPlaylistFacts.count < Self.completedResponseFactCapacity else { return }
            guard let publicationSlot = authorityBindings.slot(for: binding.publicationSequence) else { return }
            let participantSlot: UInt8
            switch key {
            case .master: participantSlot = .max
            case .media(let participantID):
                guard let index = frozenParticipants.indices.first(where: {
                    frozenParticipants[$0].participantID == participantID
                }) else { return }
                participantSlot = UInt8(index)
            }
            completedPlaylistFacts.append(.init(publicationSlot: publicationSlot,
                participantSlot: participantSlot))
        }
    }

    private func publicationAuthority(
        sequence: UInt64,
        snapshotIdentity: UUID
    ) -> LoopbackPublicationAuthorityBinding {
        if let existing = authorityBindings[sequence] { return existing }
        let binding = LoopbackPublicationAuthorityBinding(
            origin: authorityBinding.origin,
            publicationSequence: sequence,
            publicationSnapshotIdentity: snapshotIdentity)
        if activePreparationOwnerSlot != 0 {
            if authorityBindings.count == 9, let oldest = authorityBindings.keys.min(),
               let slot = authorityBindings.slot(for: oldest) {
                completedPlaylistFacts.removeAll { $0.publicationSlot == slot }
                completedResourceFacts.removeAll { $0.publicationSlot == slot }
                participantsByPublication.removeValue(forKey: oldest)
                audioSelectionByPublication.removeValue(forKey: oldest)
                authorityBindings.removeValue(forKey: oldest)
            }
            authorityBindings[sequence] = binding
        }
        return binding
    }

    private func observeAACPublicationSeal(
        _ publication: AACPublicationMembershipReceipt,
        participantID: UInt64,
        binding: AACRenditionTerminalBinding
    ) {
        if case .retired = phase { return }
        guard aacRenditionBindings[participantID] === binding,
              binding.sealedPublicationReceipt === publication,
              var gate = aacHTTPFinalizationGates[participantID] else { return }
        let shouldSeal = gate.observePublication(publication)
        aacHTTPFinalizationGates[participantID] = gate
        guard shouldSeal else { return }
        do {
            try finalizeAACHTTPMembershipLocked(
                participantID: participantID, binding: binding,
                publication: publication)
        } catch {
            failAACHTTPFinalizationLocked(participantID: participantID)
        }
    }

    private func finalizeAACHTTPMembershipLocked(
        participantID: UInt64,
        binding: AACRenditionTerminalBinding,
        publication: AACPublicationMembershipReceipt
    ) throws {
        guard aacRenditionBindings[participantID] === binding,
              binding.sealedPublicationReceipt === publication,
              binding.sealedHTTPReceipt == nil,
              let accumulator = aacHTTPMembership[participantID],
              let terminal = terminalAACHTTPLeaves[participantID],
              terminal == publication.terminalLeaf,
              accumulator.snapshot.pendingCount == 0 else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        let receipt = AACHTTPMembershipReceipt(
            snapshot: accumulator.snapshot,
            terminalLeaf: terminal,
            issuer: aacHTTPIssuer)
        do { try binding.acceptHTTP(receipt, issuer: aacHTTPIssuer) }
        catch { throw LoopbackHTTPServerError.invalidConfiguration }
    }

    private func failAACHTTPFinalizationLocked(participantID: UInt64) {
        guard let key = terminalAACHTTPKeys[participantID] else { return }
        let sequence = authorityBindings.keys.max() ?? authorityBinding.publicationSequence
        let event = LoopbackTimelineFailureEvent.publicationTerminated(
            itemGeneration: declaration.itemGeneration,
            publicationSequence: sequence,
            resource: key,
            failure: .invalidDecodeMap)
        if let delivery = recordTimelineFailureLocked(event) {
            deliverTimelineFailure(delivery.0, to: delivery.1)
        }
        responseFailure(key, .invalidDecodeMap)
    }

    private func recordCompletedResource(
        route: ResourceRoute,
        responseAuthority: ResourceResponseAuthority?,
        historyAdmissionToken: PreparationHistoryAdmissionToken?,
        lease: HLSMediaResponseLease,
        sendTerminalIdentity: UUID
    ) {
        var publicationEvent: (UInt64, @Sendable (UInt64) -> Void)?
        var completedResourceEvent: (@Sendable () -> Void)?
        var selectionEvent: (LoopbackAudioMediaSelectionCapability,
                             @Sendable (LoopbackAudioMediaSelectionCapability) -> Void)?
        var capacityFailed = false
        queueSync {
            var membershipWasNew = false
            if let leaf = route.aacMediaMembershipLeaf,
               let completed = store.completedEvidenceSnapshot(for: route.key),
               completed.isComplete,
               completed.resourceIdentity == route.backingIdentity,
               completed.sealedDigest == route.sealedDigest,
               completed.sealedBodyLength == lease.residentByteCount,
               frozenParticipants[route.key.participantID] != nil {
                if let renditionBinding = aacRenditionBindings[route.key.participantID] {
                    guard let admission = route.aacPublicationAdmission,
                          admission.leaf == leaf,
                          renditionBinding.acceptsPublicationAdmission(admission) else {
                        capacityFailed = true
                        return
                    }
                    let accumulator = aacHTTPMembership[route.key.participantID]
                        ?? AACMediaMembershipAccumulator()
                    switch accumulator.acceptServedSubset(
                        admission, binding: renditionBinding) {
                    case .accepted:
                        membershipWasNew = true
                        aacHTTPMembership[route.key.participantID] = accumulator
                        if terminalAACHTTPLeaves[route.key.participantID].map({
                            $0.logicalSequence < leaf.logicalSequence
                        }) ?? true {
                            terminalAACHTTPLeaves[route.key.participantID] = leaf
                            terminalAACHTTPKeys[route.key.participantID] = route.key
                        }
                        var gate = aacHTTPFinalizationGates[route.key.participantID]
                            ?? AACHTTPFinalizationGate()
                        let shouldSeal = gate.observeTerminalHTTP(leaf)
                        aacHTTPFinalizationGates[route.key.participantID] = gate
                        if shouldSeal {
                            guard let publication = renditionBinding.sealedPublicationReceipt else {
                                capacityFailed = true
                                return
                            }
                            do {
                                try finalizeAACHTTPMembershipLocked(
                                    participantID: route.key.participantID,
                                    binding: renditionBinding,
                                    publication: publication)
                            } catch {
                                capacityFailed = true
                                return
                            }
                        }
                    case .duplicate:
                        break
                    case .identityMismatch, .capacityExceeded:
                        capacityFailed = true
                        return
                    }
                }
            }
            guard let historyAdmissionToken,
                  historyAdmissionToken.ownerSlot == activePreparationOwnerSlot,
                  historyAdmissionToken.generation == activePreparationHistoryGeneration,
                  let responseAuthority,
                  authorityBindings[responseAuthority.binding.publicationSequence]
                    == responseAuthority.binding,
                  participantsByPublication[responseAuthority.binding.publicationSequence]?[
                    responseAuthority.participant.participantID
                  ] == responseAuthority.participant else { return }
            let binding = responseAuthority.binding
            let participant = responseAuthority.participant
            guard
                  route.backingIdentity == lease.backingIdentity,
                  !completedResourceFacts.contains(where: {
                    $0.authority == binding
                        && $0.key == route.key && $0.completedByteRange == lease.completedRange
                  }) else { return }
            let sameKindFactCount = completedResourceFacts.reduce(into: 0) {
                if $1.key.kind == route.key.kind { $0 += 1 }
            }
            let factCapacity = route.key.kind == .media
                ? Self.completedResponseFactCapacity
                : Self.completedInitializationFactCapacity
            guard sameKindFactCount < factCapacity else { capacityFailed = true; return }
            let presentationRange: FMP4PresentationRange?
            if route.key.kind == .media,
               let map = store.decodeCoverageMap(for: route.key),
               let first = map.samples.min(by: {
                   CMTimeCompare($0.presentationRange.start.cmTime,
                                 $1.presentationRange.start.cmTime) < 0
               }),
               let last = map.samples.max(by: {
                   CMTimeCompare($0.presentationRange.end.cmTime,
                                 $1.presentationRange.end.cmTime) < 0
               }) {
                presentationRange = try? FMP4PresentationRange(
                    start: first.presentationRange.start,
                    duration: last.presentationRange.end.subtracting(
                        first.presentationRange.start))
            } else {
                presentationRange = nil
            }
            guard let completed = store.completedEvidenceSnapshot(for: route.key),
                  completed.resourceIdentity == route.backingIdentity,
                  completed.sealedDigest == route.sealedDigest,
                  completed.sealedBodyLength == lease.residentByteCount else { return }
            guard let publicationSlot = authorityBindings.slot(for: binding.publicationSequence),
                  let slots = try? store.retainCompletedResponseSlot(key: route.key,
                    range: lease.completedRange) else { return }
            if route.aacMediaMembershipLeaf != nil, completed.isComplete,
               membershipWasNew
                    || compactAACCompleted[route.key] == route.backingIdentity {
                if membershipWasNew {
                    if compactAACCompleted.count == Self.completedResponseFactCapacity,
                       let oldest = compactAACCompleted.keys.min(by: {
                           $0.logicalSequence < $1.logicalSequence
                       }) {
                        compactAACCompleted.removeValue(forKey: oldest)
                    }
                    compactAACCompleted[route.key] = route.backingIdentity
                }
                if compactAACCompleted[route.key] == route.backingIdentity {
                    completedResourceFacts.removeAll {
                        $0.key == route.key
                            && $0.backingIdentity == route.backingIdentity
                    }
                }
            }
            // AAC 完整 body 已由 compact map 证明 union 后，仍保留本次真实 send-terminal
            // 的一个 slot-backed fact，供 publication 冻结枚举成员；旧 range facts 才释放。
            completedResourceFacts.append(.init(resourceSlot: slots.resource,
                rangeSlot: slots.range, publicationSlot: publicationSlot))
            completedResourceEvent = completedResourceEventHandler

            #if DEBUG
            PlaybackDiagnosticTracker.shared.append(
                "http_\(participant.mediaType == .audio ? "a" : "v")_"
                    + "\(route.key.kind == .media ? "m" : "i")_"
                    + "r\(lease.completedRange.lowerBound)-\(lease.completedRange.upperBound)-"
                    + "\(lease.residentByteCount)"
            )
            if participant.mediaType == .audio, route.key.kind == .media,
               lease.completedRange == 0..<lease.residentByteCount {
                let effective = presentationRange.flatMap {
                    effectivePresentationRange($0, for: participant)
                }
                let window = selectionContract(for: participant, binding: binding,
                                               intersecting: effective)
                let overlaps = effective.flatMap { effective in
                    window.flatMap { Self.intersection(effective, $0) }
                }
                PlaybackDiagnosticTracker.shared.append(
                    "asel_p\(presentationRange != nil ? 1 : 0)_"
                        + "w\(window != nil ? 1 : 0)_e\(effective != nil ? 1 : 0)_"
                        + "x\(overlaps != nil ? 1 : 0)"
                )
            }
            #endif

            if participant.mediaType == .audio, route.key.kind == .media,
               lease.completedRange == 0..<lease.residentByteCount,
               let presentationRange,
               let effectivePresentationRange = effectivePresentationRange(
                    presentationRange, for: participant),
               let window = selectionContract(for: participant, binding: binding,
                                              intersecting: effectivePresentationRange),
               Self.intersection(effectivePresentationRange, window) != nil,
               let effectiveOffset = try? effectivePresentationRange.start.subtracting(presentationRange.start),
               audioSelectionByPublication[binding.publicationSequence]?.renditionIdentity
                    != participant.renditionIdentity {
                guard LoopbackAudioMediaSelectionCapability.reserveRecord() else {
                    capacityFailed = true; return
                }
                guard let resourceReservation = try? PlaybackResourceContextLedger.shared.reserve(
                    allocationIdentity: .stable(UUID()), bytes: 1 * 1_024) else {
                    LoopbackAudioMediaSelectionCapability.releaseRecord()
                    capacityFailed = true; return
                }
                let admissionSlot = activePreparationOwnerSlot
                guard FrozenPreparationOwner.retainAdmission(slot: admissionSlot) else {
                    PlaybackResourceContextLedger.shared.release(resourceReservation)
                    LoopbackAudioMediaSelectionCapability.releaseRecord()
                    capacityFailed = true; return
                }
                guard let metadataSlot = try? store.retainSelectionMetadata(route.key) else {
                    FrozenPreparationOwner.releaseAdmission(slot: admissionSlot)
                    PlaybackResourceContextLedger.shared.release(resourceReservation)
                    LoopbackAudioMediaSelectionCapability.releaseRecord()
                    return
                }
                let capability = LoopbackAudioMediaSelectionCapability(
                    authorityBinding: binding,
                    metadataStore: store, metadataSlot: metadataSlot,
                    admissionSlot: admissionSlot,
                    responseLeaseIdentity: lease.terminalBindingIdentity,
                    selectionEnd: window.end,
                    effectiveOffset: effectiveOffset,
                    sendTerminalIdentity: sendTerminalIdentity,
                    resourceContextReservation: resourceReservation)
                guard (try? PlaybackResourceContextLedger.shared.rebind(
                    resourceReservation, to: .object(ObjectIdentifier(capability)))) != nil else {
                    capacityFailed = true; return
                }
                audioSelectionByPublication[binding.publicationSequence] = capability
                if let handler = renditionSelectionEventHandler {
                    selectionEvent = (capability, handler)
                }
            }
            if publicationIsReady(binding),
               (latestEmittedPublicationSequence.map({ binding.publicationSequence > $0 })
                ?? true), let handler = publicationEventHandler {
                latestEmittedPublicationSequence = binding.publicationSequence
                publicationEvent = (binding.publicationSequence, handler)
            }
        }
        // selection terminal 与 generic completed/publication retry 属于同一批事件。
        // 必须先发布精确 capability，让 evidence source 在同锁域采用后再重试；
        // 否则 retry 会看到 server 已有 selection、调用方仍为 nil，并正确地
        // fail-closed 成 invalid，随后到达的 selection 边沿已经无法恢复 waiter。
        if capacityFailed, let responseAuthority {
            publishTimelineFailure(.publicationTerminated(itemGeneration: declaration.itemGeneration,
                publicationSequence: responseAuthority.binding.publicationSequence,
                resource: route.key, failure: .capacityExceeded))
            responseFailure(route.key, .capacityExceeded)
            return
        }
        if let (capability, handler) = selectionEvent { handler(capability) }
        completedResourceEvent?()
        if let (sequence, handler) = publicationEvent { handler(sequence) }
    }

    private func resourceResponseAuthority(for route: ResourceRoute)
        -> ResourceResponseAuthority? {
        authorityBindings.keys.sorted(by: >).compactMap {
            sequence -> ResourceResponseAuthority? in
            guard let binding = authorityBindings[sequence],
                  let participant = participantsByPublication[sequence]?[route.key.participantID],
                  participant.initializationKeys.contains(route.key)
                    || participant.mediaKeys.contains(route.key),
                  completedPlaylistFacts.contains(where: {
                    $0.authority == binding
                        && $0.key == .media(participantID: participant.participantID)
                        && $0.snapshotIdentity == participant.playlistIdentity
                  }) else { return nil }
            return ResourceResponseAuthority(binding: binding, participant: participant)
        }.first
    }

    private func completedResourceFactsFullyCover(
        key: HLSResourceKey,
        backing: SealedMediaBackingIdentity,
        authority: LoopbackPublicationAuthorityBinding
    ) -> Bool {
        if compactAACCompleted[key] == backing { return true }
        guard let length = completedResourceFacts.first(where: {
            $0.authority == authority && $0.key == key && $0.backingIdentity == backing
        })?.residentByteCount else { return false }
        var cursor = 0
        for _ in 0..<Self.completedResponseFactCapacity {
            var next = cursor
            for fact in completedResourceFacts where fact.authority == authority
                && fact.key == key && fact.backingIdentity == backing {
                guard fact.residentByteCount == length else { return false }
                if fact.completedByteRange.lowerBound <= cursor {
                    next = max(next, fact.completedByteRange.upperBound)
                }
            }
            if next >= length { return true }
            guard next > cursor else { return false }
            cursor = next
        }
        return false
    }

    private func publicationIsReady(_ binding: LoopbackPublicationAuthorityBinding) -> Bool {
        guard let participants = participantsByPublication[binding.publicationSequence],
              let selection = audioSelectionByPublication[binding.publicationSequence],
              !requiresMasterPlaylist || completedPlaylistFacts.contains(where: {
                $0.authority == binding && $0.key == .master
              }) else { return false }
        let required = participants.values.filter {
            $0.mediaType == .video || $0.participantID == selection.participantID
        }
        return !required.isEmpty && required.allSatisfy { participant in
            completedPlaylistFacts.contains(where: {
                $0.authority == binding
                    && $0.key == .media(participantID: participant.participantID)
                    && $0.snapshotIdentity == participant.playlistIdentity
            }) && participant.initializationKeys.contains(where: { key in
                completedResourceFacts.contains(where: {
                    $0.authority == binding && $0.key == key
                        && completedResourceFactsFullyCover(
                            key: key, backing: $0.backingIdentity, authority: binding)
                })
            }) && participant.mediaKeys.contains(where: { key in
                completedResourceFacts.contains(where: {
                    $0.authority == binding && $0.key == key
                        && completedResourceFactsFullyCover(
                            key: key, backing: $0.backingIdentity, authority: binding)
                })
            })
        }
    }

    private func selectionContract(
        for participant: FrozenParticipant,
        binding: LoopbackPublicationAuthorityBinding,
        intersecting terminalRange: FMP4PresentationRange?
    ) -> FMP4PresentationRange? {
        let lead = ExactMediaTime(value: 3, timescale: 1)
        var selected: FMP4PresentationRange?
        for fact in completedResourceFacts where fact.authority == binding
            && fact.participantID == participant.participantID
            && fact.key.kind == .media
            && participant.mediaKeys.contains(fact.key)
            && completedResourceFactsFullyCover(
                key: fact.key, backing: fact.backingIdentity, authority: binding
            ) {
            guard let physical = fact.presentationRange,
                  let effective = effectivePresentationRange(
                    physical,
                    for: participant
                  ) else { continue }
            // AAC writer 的一个物理分片可以越过与视频共同冻结的播放上界。
            // selection 只能落在当前 playlist 宣告的共同有效区间内；否则
            // 三段冷启动时会把 AAC 尾部的少量超前误签成可播窗口。
            let selectionEnd = CMTimeCompare(
                effective.end.cmTime,
                participant.effectivePlaybackHorizon.cmTime
            ) <= 0 ? effective.end : participant.effectivePlaybackHorizon
            guard let start = try? selectionEnd.subtracting(lead),
                  start.value >= 0,
                  let candidate = try? FMP4PresentationRange(
                    start: start,
                    duration: lead
                  ),
                  terminalRange.map({ Self.intersection($0, candidate) != nil }) ?? false,
                  completedAudioMediaCovers(
                    participant: participant, binding: binding, requested: candidate
                  ) else { continue }
            if selected.map({
                CMTimeCompare(candidate.end.cmTime, $0.end.cmTime) > 0
            }) ?? true {
                selected = candidate
            }
        }
        return selected
    }

    private func completedAudioMediaCovers(
        participant: FrozenParticipant,
        binding: LoopbackPublicationAuthorityBinding,
        requested: FMP4PresentationRange
    ) -> Bool {
        var cursor = requested.start
        for _ in 0..<Self.completedResponseFactCapacity {
            var next = cursor
            for fact in completedResourceFacts where fact.authority == binding
                && fact.participantID == participant.participantID
                && fact.key.kind == .media
                && participant.mediaKeys.contains(fact.key)
                && completedResourceFactsFullyCover(
                    key: fact.key, backing: fact.backingIdentity, authority: binding
                ) {
                guard let physical = fact.presentationRange,
                      let effective = effectivePresentationRange(physical, for: participant),
                      CMTimeCompare(effective.start.cmTime, cursor.cmTime) <= 0,
                      CMTimeCompare(effective.end.cmTime, next.cmTime) > 0 else { continue }
                next = effective.end
            }
            if CMTimeCompare(next.cmTime, requested.end.cmTime) >= 0 { return true }
            guard CMTimeCompare(next.cmTime, cursor.cmTime) > 0 else { return false }
            cursor = next
        }
        return false
    }

    /// writer report 的区间属于物理 PTS；selection 合同属于去除 AAC leading trim
    /// 后的有效播放时间轴。偏移来自 publisher 同次 CAS 冻结的首个 writer report，
    /// 不读取 terminal endpoint；没有 writer 绑定的兼容 participant 明确按零偏移。
    private func effectivePresentationRange(
        _ physical: FMP4PresentationRange,
        for participant: FrozenParticipant
    ) -> FMP4PresentationRange? {
        guard participant.mediaType == .audio,
              participant.audioCodec == .aac else {
            return physical
        }
        guard let mapping = participant.aacTimelineMapping else {
            return aacTerminalBindings[participant.participantID] == nil ? physical : nil
        }
        guard mapping.binding.renditionIdentity == participant.renditionIdentity,
              let offset = try? mapping.writtenEffectiveBase.subtracting(
                  mapping.writtenPhysicalBase),
              let start = try? physical.start.adding(offset),
              let range = try? FMP4PresentationRange(start: start,
                                                     duration: physical.duration) else {
            return nil
        }
        return range
    }

    private static func intersection(_ lhs: FMP4PresentationRange,
                                     _ rhs: FMP4PresentationRange)
        -> FMP4PresentationRange? {
        let start = CMTimeCompare(lhs.start.cmTime, rhs.start.cmTime) >= 0
            ? lhs.start : rhs.start
        let end = CMTimeCompare(lhs.end.cmTime, rhs.end.cmTime) <= 0 ? lhs.end : rhs.end
        guard CMTimeCompare(start.cmTime, end.cmTime) < 0 else { return nil }
        return try? FMP4PresentationRange(start: start, duration: end.subtracting(start))
    }

    private func beginActive(on context: LoopbackHTTPConnection,
                             backingIdentity: SealedMediaBackingIdentity? = nil,
                             backingBytes: Int = 0) -> Bool {
        let currentBacking = reservedBackingBytes
        let newBackingBytes = backingIdentity.map {
            backingLedger.additionalBytes(for: $0, bytes: backingBytes)
        } ?? 0
        let projected = LoopbackHTTPUsage(connections: connections.count,
            activeResponses: activeResponses + 1,
            distinctBackingBytes: currentBacking + newBackingBytes,
            parserAndStagingBytes: (connections.count + closingConnections.count)
                * LoopbackStorageLayout.current.parserAllocationBytes
                + (activeResponses + 1) * LoopbackStorageLayout.current.stagingAllocationBytes
                + coverageContexts.count
                    * LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes)
        let capacity = LoopbackHTTPLimits.standard.classify(projected)
        let projectedApplicationBytes = currentBacking + newBackingBytes
            + projected.parserAndStagingBytes
            + LoopbackStorageLayout.current.aacHTTPFinalizationMetadataBytes
        guard capacity != .hardExceeded,
              projectedApplicationBytes
                <= LoopbackStorageLayout.current.serverHardApplicationBytes else {
            return false
        }
        if capacity == .backpressure && testing?.permitsSoftCapacitySaturation != true {
            let current = LoopbackHTTPUsage(connections: connections.count,
                activeResponses: activeResponses,
                distinctBackingBytes: reservedBackingBytes,
                parserAndStagingBytes: parserAndStagingBytes)
            guard LoopbackHTTPLimits.standard.classify(current) == .normal else {
                softBackpressureCount += 1
                return false
            }
            softBackpressureCount += 1
        }
        if let backingIdentity {
            do {
                guard let reservation = try backingLedger.reserve(identity: backingIdentity,
                                                                  bytes: backingBytes) else {
                    softBackpressureCount += 1
                    return false
                }
                context.backingReservation = reservation
            } catch {
                return false
            }
        }
        do {
            context.stagingReservation = try HLSDeliveryApplicationChargeLedger.shared.reserve(
                allocationIdentity: UUID(), bytes: LoopbackStorageLayout.current.stagingAllocationBytes)
        } catch LoopbackHTTPReservationError.backpressure {
            softBackpressureCount += 1
            if let reservation = context.backingReservation { backingLedger.release(reservation) }
            context.backingReservation = nil
            return false
        } catch {
            if let reservation = context.backingReservation { backingLedger.release(reservation) }
            context.backingReservation = nil
            return false
        }
        activeResponses += 1
        context.countsAsActive = true
        maximumActiveResponses = max(maximumActiveResponses, activeResponses)
        maximumDistinctBackingBytes = max(maximumDistinctBackingBytes, reservedBackingBytes)
        maximumParserAndStagingBytes = max(maximumParserAndStagingBytes, parserAndStagingBytes)
        maximumOwnedStagingAllocationBytes = max(maximumOwnedStagingAllocationBytes,
                                                  LoopbackStorageLayout.current.stagingAllocationBytes)
        maximumReservedApplicationBytes = max(
            maximumReservedApplicationBytes,
            reservedBackingBytes + parserAndStagingBytes
                + LoopbackStorageLayout.current.aacHTTPFinalizationMetadataBytes)
        return true
    }

    fileprivate func activeFinished(_ context: LoopbackHTTPConnection) {
        guard context.countsAsActive else { return }
        context.countsAsActive = false
        activeResponses -= 1
        if let reservation = context.backingReservation { backingLedger.release(reservation) }
        context.backingReservation = nil
        if let reservation = context.stagingReservation {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
        context.stagingReservation = nil
        continueAutomaticCleanupIfPossible()
    }

    fileprivate func connectionFinished(_ context: LoopbackHTTPConnection) {
        connections.removeValue(forKey: ObjectIdentifier(context))
        closingConnections.removeValue(forKey: ObjectIdentifier(context))
        pausedBodySends.removeValue(forKey: ObjectIdentifier(context))
        HLSDeliveryApplicationChargeLedger.shared.release(context.parserReservation)
        continueAutomaticCleanupIfPossible()
    }

    private func sendStatus(_ status: Int, on context: LoopbackHTTPConnection) {
        var headers: [String: String] = [:]
        if status == 405 { headers["Allow"] = "GET, HEAD" }
        context.send(status: status, headers: headers, close: true)
    }

    private func playlistHeaders(length: Int, etag: String, gzip: Bool) -> [String: String] {
        var headers = ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "\(length)",
            "Cache-Control": "no-store", "Vary": "Accept-Encoding", "ETag": etag]
        if gzip { headers["Content-Encoding"] = "gzip" }
        return headers
    }

    private func resourceHeaders(route: ResourceRoute, range: Range<Int>?) -> [String: String] {
        let length = range?.count ?? route.length
        let prefix = route.mediaType == .audio ? "audio" : "video"
        var headers = ["Content-Type": route.key.kind == .initialization
            ? "\(prefix)/mp4" : "\(prefix)/iso.segment",
            "Content-Length": "\(length)", "Cache-Control": "public, max-age=31536000, immutable",
            "Accept-Ranges": "bytes", "ETag": route.etag]
        if let range { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(route.length)" }
        return headers
    }

    fileprivate static func responseHead(status: Int, headers: [String: String], close: Bool) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"; case 206: reason = "Partial Content"; case 400: reason = "Bad Request"
        case 404: reason = "Not Found"; case 405: reason = "Method Not Allowed"; case 410: reason = "Gone"
        case 416: reason = "Range Not Satisfiable"; case 431: reason = "Request Header Fields Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var fields = headers
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        fields["Date"] = dateFormatter.string(from: Date())
        fields["Content-Length"] = fields["Content-Length"] ?? "0"
        fields["Connection"] = close ? "close" : "keep-alive"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in fields.keys.sorted() { text += "\(key): \(fields[key]!)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func isIPv4Loopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint,
              case let .ipv4(address) = host,
              let loopback = IPv4Address("127.0.0.1") else { return false }
        return address == loopback
    }

    private static func validTargetShape(_ target: String) -> Bool {
        guard target.utf8.count <= 1_024, target.first == "/", !target.isEmpty,
              target.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              !target.contains("#"), !target.contains("%"), !target.contains("\\") else { return false }
        let path = target.split(separator: "?", maxSplits: 1,
            omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !path.contains("//") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private static func authorizationComponents(_ target: String) -> (token: String, itemGeneration: UInt64)? {
        let path = target.split(separator: "?", maxSplits: 1,
            omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count >= 3, pieces[0] == "v1", let generation = UInt64(pieces[2]) else { return nil }
        return (String(pieces[1]), generation)
    }

    private static func acceptsGzip(_ values: [String]) -> Bool {
        var gzipQuality: Double?
        var wildcardQuality: Double?
        var seen: Set<String> = []
        var invalid: Set<String> = []
        for raw in values.flatMap({ $0.split(separator: ",", omittingEmptySubsequences: false) }) {
            let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
            let coding = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard coding == "gzip" || coding == "*" else { continue }
            guard seen.insert(coding).inserted else {
                invalid.insert(coding)
                continue
            }
            var quality = 1.0
            var valid = true
            var foundQuality = false
            for parameter in fields.dropFirst() {
                let pieces = parameter.split(separator: "=", maxSplits: 1,
                    omittingEmptySubsequences: false).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                guard !foundQuality, pieces.count == 2, pieces[0].lowercased() == "q",
                      let parsed = strictQuality(pieces[1]) else {
                    valid = false; break
                }
                foundQuality = true
                quality = parsed
            }
            guard valid else {
                invalid.insert(coding)
                if coding == "gzip" { gzipQuality = 0 }
                continue
            }
            if coding == "gzip" { gzipQuality = max(gzipQuality ?? 0, quality) }
            else { wildcardQuality = max(wildcardQuality ?? 0, quality) }
        }
        if seen.contains("gzip") {
            return !invalid.contains("gzip") && (gzipQuality ?? 0) > 0
        }
        return !invalid.contains("*") && (wildcardQuality ?? 0) > 0
    }

    private static func strictQuality(_ value: String) -> Double? {
        if value == "0" { return 0 }
        if value == "1" { return 1 }
        guard (2...5).contains(value.count),
              value.first == "0" || value.first == "1",
              value.dropFirst().first == "." else { return nil }
        let fraction = value.dropFirst(2)
        guard fraction.count <= 3,
              fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if value.first == "1", fraction.contains(where: { $0 != "0" }) { return nil }
        return Double(value)
    }

    private static func mustClose(_ request: LoopbackHTTPRequest) -> Bool {
        request.values(forHeader: "Connection").contains { $0.caseInsensitiveCompare("close") == .orderedSame }
    }

    private static func kernelBindingEvidence(
        port: UInt16, testing: LoopbackHTTPTestingConfiguration?
    ) throws -> LoopbackSocketBindingEvidence {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackHTTPServerError.invalidBinding }
        defer { Darwin.close(descriptor) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw LoopbackHTTPServerError.invalidBinding }
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &length)
            }
        }
        guard queried == 0, peer.sin_family == sa_family_t(AF_INET),
              UInt16(bigEndian: peer.sin_port) == port else {
            throw LoopbackHTTPServerError.invalidBinding
        }
        var address = peer.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw LoopbackHTTPServerError.invalidBinding
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let host = String(decoding: bytes, as: UTF8.self)
        guard host == "127.0.0.1" else { throw LoopbackHTTPServerError.invalidBinding }
        let nonLoopback = testing?.nonLoopbackIPv4AddressesOverride
            ?? nonLoopbackIPv4Addresses()
        guard nonLoopback.allSatisfy({ !canConnectIPv4($0, port: port) }),
              !canConnectIPv6Loopback(port: port) else {
            throw LoopbackHTTPServerError.invalidBinding
        }
        return .init(family: Int32(peer.sin_family), address: host, port: port,
                     requiredEndpointWasAudited: true,
                     ipv6LoopbackWasRejected: true,
                     rejectedNonLoopbackIPv4Count: nonLoopback.count)
    }

    private static func nonLoopbackIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<String> = []
        var cursor = first
        while let interface = cursor?.pointee {
            cursor = interface.ifa_next
            guard let pointer = interface.ifa_addr,
                  pointer.pointee.sa_family == UInt8(AF_INET) else { continue }
            var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { continue }
            let host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            if host != "127.0.0.1" && host != "0.0.0.0" { result.insert(host) }
        }
        return result.sorted()
    }

    private static func canConnectIPv4(_ host: String, port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &value.sin_addr) == 1 else { return false }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let res = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        if errno == EINPROGRESS {
            var pollFd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollRes = Darwin.poll(&pollFd, 1, 50)
            if pollRes > 0 && (pollFd.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &errLen) == 0, error == 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func canConnectIPv6Loopback(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = port.bigEndian
        value.sin6_addr = in6addr_loopback
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let res = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if res == 0 { return true }
        if errno == EINPROGRESS {
            var pollFd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollRes = Darwin.poll(&pollFd, 1, 50)
            if pollRes > 0 && (pollFd.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &errLen) == 0, error == 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func etag(_ body: Data) -> String { etag(digest: Data(SHA256.hash(data: body))) }
    private static func etag(digest: Data) -> String {
        "\"" + digest.map { String(format: "%02x", $0) }.joined() + "\""
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed, .cancelled: break
        default: return
        }
        let ticket = closeAdmission()
        queue.async { [weak self] in
            self?.automaticCleanupTicket = ticket
            self?.continueAutomaticCleanupIfPossible()
        }
    }

    private func continueAutomaticCleanupIfPossible() {
        guard let ticket = automaticCleanupTicket else { return }
        if case .closed(let expected) = phase, expected === ticket,
           connections.isEmpty, closingConnections.isEmpty, activeResponses == 0 {
            phase = .drained(ticket)
        }
        if case .drained(let expected) = phase, expected === ticket {
            guard backingLedger.usage.distinctBackingCount == 0 else { return }
            coverageContexts.removeAll(keepingCapacity: false)
            phase = .retired(ticket)
            automaticCleanupTicket = nil
            store.close()
            listener.cancel()
            DispatchQueue.global(qos: .utility).async { [logger] in
                logger("loopback listener failed closed")
            }
        }
    }
}

private final class LoopbackHTTPConnection: @unchecked Sendable {
    let identity = UUID()
    let connection: NWConnection
    weak var server: LoopbackHTTPServer?
    var countsAsActive = false
    var backingReservation: LoopbackHTTPBackingReservation?
    var stagingReservation: PlaybackApplicationChargeReservation?
    let parserReservation: PlaybackApplicationChargeReservation
    private var parser = LoopbackRequestParser()
    private var ended = false
    private var awaitingRequest = false
    private let deadlineTimer: DispatchSourceTimer
    private var requestDeadline: UInt64?
    private var responseTotalDeadline: UInt64?
    private var responseProgressDeadline: UInt64?
    private var responseInFlight = false
    private var activeCleanup: ((LoopbackSendTerminal) -> Void)?
    private var bodySendWasPaused = false
    private var successfulBodyChunks = 0

    init(connection: NWConnection, server: LoopbackHTTPServer,
         parserReservation: PlaybackApplicationChargeReservation) {
        self.connection = connection; self.server = server
        self.parserReservation = parserReservation
        deadlineTimer = DispatchSource.makeTimerSource(queue: server.queue)
    }

    func start(overloaded: Bool) {
        guard let server else { connection.cancel(); return }
        deadlineTimer.setEventHandler { [weak self] in self?.deadlineFired() }
        deadlineTimer.schedule(deadline: .distantFuture)
        deadlineTimer.resume()
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state, overloaded: overloaded) }
        connection.start(queue: server.queue)
    }

    func setActiveCleanup(_ cleanup: @escaping (LoopbackSendTerminal) -> Void) {
        activeCleanup = cleanup
    }

    func send(status: Int, headers: [String: String], close: Bool) {
        responseInFlight = true
        armResponseDeadline(seconds: 1)
        sendHead(status: status, headers: headers, close: close) { [weak self] error in
            self?.finishResponse(terminal: error == nil ? .success : .failed, close: close)
        }
    }

    func send(status: Int, headers: [String: String], body: Data, close: Bool) {
        responseInFlight = true
        armResponseDeadline(seconds: 1)
        sendHead(status: status, headers: headers, close: false) { [weak self] error in
            guard let self else { return }
            guard error == nil else { self.finishResponse(terminal: .failed, close: true); return }
            self.sendBuffered(body, offset: 0, close: close)
        }
    }

    func send(status: Int, headers: [String: String], lease: HLSMediaResponseLease,
              absoluteRange: Range<Int>, tracker: LoopbackSendCompletionTracker, close: Bool) {
        responseInFlight = true
        armResponseDeadline(seconds: 15)
        sendHead(status: status, headers: headers, close: false) { [weak self] error in
            guard let self else { return }
            guard error == nil else { self.finishResponse(terminal: .failed, close: true); return }
            self.sendLease(lease, offset: 0, absoluteRange: absoluteRange, tracker: tracker, close: close)
        }
    }

    func stop(terminal: LoopbackSendTerminal) {
        guard !ended else { return }
        ended = true; responseInFlight = false
        requestDeadline = nil
        responseTotalDeadline = nil
        responseProgressDeadline = nil
        deadlineTimer.setEventHandler {}
        deadlineTimer.cancel()
        let cleanup = activeCleanup; activeCleanup = nil
        cleanup?(terminal)
        server?.activeFinished(self)
        connection.cancel()
        server?.connectionFinished(self)
    }

    private func changed(_ state: NWConnection.State, overloaded: Bool) {
        guard !ended else { return }
        switch state {
        case .ready:
            guard server?.connectionReady(self) == true else { stop(terminal: .disconnected); return }
            if overloaded { send(status: 503, headers: [:], close: true) }
            else { receive(timeout: 1) }
        case .failed(_): stop(terminal: .failed)
        case .cancelled: stop(terminal: .cancelled)
        default: break
        }
    }

    private func receive(timeout: TimeInterval) {
        guard !ended else { return }
        parser = LoopbackRequestParser(); awaitingRequest = true
        requestDeadline = Self.deadline(after: timeout)
        scheduleDeadlineTimer()
        receiveMore()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if error != nil { self.stop(terminal: .failed); return }
            do {
                if let data, !data.isEmpty, let request = try self.parser.append(data) {
                    self.awaitingRequest = false; self.requestDeadline = nil
                    self.scheduleDeadlineTimer()
                    self.server?.handle(request, on: self)
                    return
                }
            } catch let requestError as LoopbackRequestError {
                self.awaitingRequest = false; self.requestDeadline = nil
                self.scheduleDeadlineTimer()
                let status = requestError == .headerTooLarge ? 431 : 400
                self.send(status: status, headers: [:], close: true)
                return
            } catch {
                self.awaitingRequest = false; self.requestDeadline = nil
                self.scheduleDeadlineTimer()
                self.send(status: 400, headers: [:], close: true)
                return
            }
            if complete { self.stop(terminal: .disconnected) }
            else { self.receiveMore() }
        }
    }

    private func sendHead(status: Int, headers: [String: String], close: Bool,
                          completion: @escaping @Sendable (NWError?) -> Void) {
        guard let server, !ended else { completion(NWError.posix(.ECANCELED)); return }
        let head = LoopbackHTTPServer.responseHead(status: status, headers: headers, close: close)
        connection.send(content: head, contentContext: .defaultMessage, isComplete: close,
                        completion: .contentProcessed { error in
            server.queue.async { completion(error) }
        })
    }

    private func sendBuffered(_ body: Data, offset: Int, close: Bool) {
        guard !ended else { return }
        if offset == 0, !bodySendWasPaused, let server {
            bodySendWasPaused = true
            if server.pauseBodySend(self, resume: { [weak self] in
                self?.sendBuffered(body, offset: offset, close: close)
            }) { return }
        }
        if offset == body.count { finishResponse(terminal: .success, close: close); return }
        let end = min(body.count, offset + 64 * 1_024)
        let chunk = body.subdata(in: offset..<end)
        connection.send(content: chunk, contentContext: .defaultMessage,
                        isComplete: close && end == body.count,
                        completion: .contentProcessed { [weak self] error in
            guard let self, let server = self.server else { return }
            server.queue.async {
                if error != nil { self.finishResponse(terminal: .failed, close: true) }
                else { self.sendBuffered(body, offset: end, close: close) }
            }
        })
    }

    private func sendLease(_ lease: HLSMediaResponseLease, offset: Int, absoluteRange: Range<Int>,
                           tracker: LoopbackSendCompletionTracker, close: Bool) {
        guard !ended else { return }
        if offset == 0, !bodySendWasPaused, let server {
            bodySendWasPaused = true
            if server.pauseBodySend(self, resume: { [weak self] in
                self?.sendLease(lease, offset: offset, absoluteRange: absoluteRange,
                                tracker: tracker, close: close)
            }) { return }
        }
        if offset == lease.byteCount { finishResponse(terminal: .success, close: close); return }
        let end = min(lease.byteCount,
                      offset + (server?.configuredBodyChunkBytes ?? 64 * 1_024))
        let chunk = lease.withUnsafeBytes { bytes -> Data in
            guard let baseAddress = bytes.baseAddress else { return Data() }
            // 在同步借用期内复制到 owned staging；异步 Network.framework 不持有 Swift Data 借用地址。
            return Data(bytes: baseAddress.advanced(by: offset), count: end - offset)
        }
        guard chunk.count == end - offset else { finishResponse(terminal: .failed, close: true); return }
        let completedRange = (absoluteRange.lowerBound + offset)..<(absoluteRange.lowerBound + end)
        armNoProgressDeadline()
        connection.send(content: chunk, contentContext: .defaultMessage,
                        isComplete: close && end == lease.byteCount,
                        completion: .contentProcessed { [weak self] error in
            guard let self, let server = self.server else { return }
            server.queue.async {
                if error != nil { self.finishResponse(terminal: .failed, close: true) }
                else {
                    tracker.registerCompletedChunk(completedRange)
                    self.successfulBodyChunks += 1
                    if self.server?.configuredFailureAfterBodyChunks == self.successfulBodyChunks,
                       end < lease.byteCount {
                        self.finishResponse(terminal: .failed, close: true)
                        return
                    }
                    self.sendLease(lease, offset: end, absoluteRange: absoluteRange,
                                   tracker: tracker, close: close)
                }
            }
        })
    }

    private func finishResponse(terminal: LoopbackSendTerminal, close: Bool) {
        guard !ended else { return }
        responseInFlight = false
        responseTotalDeadline = nil
        responseProgressDeadline = nil
        scheduleDeadlineTimer()
        let cleanup = activeCleanup; activeCleanup = nil
        cleanup?(terminal)
        server?.activeFinished(self)
        if terminal != .success || close { stop(terminal: terminal) }
        else { receive(timeout: 5) }
    }

    private func armResponseDeadline(seconds: TimeInterval) {
        responseTotalDeadline = Self.deadline(after: seconds)
        scheduleDeadlineTimer()
    }

    private func armNoProgressDeadline() {
        responseProgressDeadline = Self.deadline(after: 5)
        scheduleDeadlineTimer()
    }

    private func deadlineFired() {
        guard !ended else { return }
        let instant = DispatchTime.now().uptimeNanoseconds
        if awaitingRequest, let requestDeadline, instant >= requestDeadline {
            stop(terminal: .disconnected); return
        }
        if responseInFlight,
           [responseTotalDeadline, responseProgressDeadline].compactMap({ $0 }).contains(where: { instant >= $0 }) {
            stop(terminal: .failed); return
        }
        scheduleDeadlineTimer()
    }

    private func scheduleDeadlineTimer() {
        guard !ended else { return }
        let deadlines = [requestDeadline, responseTotalDeadline, responseProgressDeadline].compactMap { $0 }
        guard let earliest = deadlines.min() else {
            deadlineTimer.schedule(deadline: .distantFuture)
            return
        }
        deadlineTimer.schedule(deadline: DispatchTime(uptimeNanoseconds: earliest), leeway: .milliseconds(10))
    }

    private static func deadline(after interval: TimeInterval) -> UInt64 {
        let delta = UInt64(max(0, interval) * 1_000_000_000)
        let result = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(delta)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
