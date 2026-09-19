// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import CryptoKit
import CoreMedia

struct HLSResourceKey: Sendable, Hashable {
    var itemGeneration: UInt64
    var mediaEpoch: UInt64
    var participantID: UInt64
    var logicalSequence: UInt64
    var kind: SealedMediaObjectKind
    var authentication = ""
    init(_ object: SealedMediaObject) {
        itemGeneration = object.binding.itemGeneration.rawValue
        mediaEpoch = object.binding.mediaEpoch.rawValue
        participantID = object.binding.publicationParticipantID.rawValue
        logicalSequence = object.kind == .initialization ? 0 : object.logicalSequence
        kind = object.kind
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemGeneration == rhs.itemGeneration && lhs.mediaEpoch == rhs.mediaEpoch
            && lhs.participantID == rhs.participantID && lhs.logicalSequence == rhs.logicalSequence && lhs.kind == rhs.kind
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(itemGeneration); hasher.combine(mediaEpoch); hasher.combine(participantID)
        hasher.combine(logicalSequence); hasher.combine(kind)
    }
    init(itemGeneration item: UInt64, mediaEpoch epoch: UInt64,
         participantID participant: UInt64, logicalSequence sequence: UInt64,
         kind: SealedMediaObjectKind, authentication: String = "") {
        itemGeneration = item; mediaEpoch = epoch; participantID = participant
        logicalSequence = sequence; self.kind = kind; self.authentication = authentication
    }
    fileprivate init(item: UInt64, epoch: UInt64, participant: UInt64,
                     sequence: UInt64, kind: SealedMediaObjectKind,
                     authentication: String) {
        self.init(itemGeneration: item, mediaEpoch: epoch,
                  participantID: participant, logicalSequence: sequence,
                  kind: kind, authentication: authentication)
    }
}

/// store 独占的 publication 资格；不存在重置版本或替换 owner 的公开操作。
final class HLSPublicationOwner: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate init() {}
}

/// candidate 的 item、声明与 proof 在同一 bundle 注册；普通整数 ticket 本身不授予资格。
final class HLSAudioCandidateRegistration: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate let previousIdentity: UUID?
    let ticket: AudioCandidateTicket
    let binding: FMP4WriterBinding
    let declaration: HLSItemDeclaration
    fileprivate let proofIdentity: UUID
    fileprivate let storeIdentity: UUID
    fileprivate init(ticket: AudioCandidateTicket, proof: EpochFormatProof,
                     declaration: HLSItemDeclaration, storeIdentity: UUID, previousIdentity: UUID? = nil) {
        self.ticket = ticket; binding = proof.binding; proofIdentity = proof.identity
        self.declaration = declaration; self.storeIdentity = storeIdentity
        self.previousIdentity = previousIdentity
    }
}

enum HLSResourceAvailability: Sendable { case available, gone, notFound }

struct HLSHTTPResourceDescriptor: @unchecked Sendable {
    let key: HLSResourceKey
    let byteCount: Int
    let backingIdentity: SealedMediaBackingIdentity
    let sealedDigest: Data
    let mediaType: FinalFMP4MediaType
    let aacMediaMembershipLeaf: AACMediaMembershipLeaf?
    let aacPublicationAdmission: AACPublicationLeafAdmission?
}

enum HLSHTTPResourceResolution: @unchecked Sendable {
    case available(HLSHTTPResourceDescriptor)
    case gone
    case notFound
}

struct SealedCoverageInput: @unchecked Sendable {
    let media: CompletedBodyEvidenceSnapshot
    let map: SealedDecodeCoverageMap
    let initialization: CompletedBodyEvidenceSnapshot
}

/// 只有 store 自身能构造的签发权；coverage 类型虽可见，外部无法创建有效 receipt。
final class SealedCoverageIssuanceAuthority: @unchecked Sendable {
    fileprivate init() {}
}

struct SealedMediaReservation: Sendable, Hashable {
    fileprivate let identity: UUID
    fileprivate let storeIdentity: UUID
    fileprivate let binding: FMP4WriterBinding
    fileprivate let kind: SealedMediaObjectKind
    fileprivate let bytes: Int
    fileprivate var reservationOverheadBytes: Int {
        kind == .initialization ? LoopbackStorageLayout.current.initEvidenceAllocationBytes : 32 * 1_024
    }
}
struct HLSSnapshotBatchReservation: Sendable, Hashable {
    fileprivate let identity: UUID
    fileprivate let storeIdentity: UUID
    fileprivate let mediaCount: Int
    fileprivate let includeMaster: Bool
    fileprivate let bytes: Int
    fileprivate var count: Int { mediaCount + (includeMaster ? 1 : 0) }
}
struct SnapshotResidencyLedger {
    struct Projection {
        let shouldBackpressure: Bool
        let exceedsHardLimit: Bool
    }
    static func project(count: Int, bytes: Int) throws -> Projection {
        guard count >= 0, bytes >= 0 else { throw HLSPublicationFailure.capacityExceeded }
        return Projection(shouldBackpressure: count >= 9 || bytes >= 5 * 1_048_576,
            exceedsHardLimit: count > 10 || bytes > 6 * 1_048_576)
    }
}

struct SealedMediaRetrofitCharge: Sendable {
    let existingMapBytes: Int
    let replacementMapBytes: Int
}

enum SealedMediaStoreCapacityProjection {
    static let mediaEvidenceBytes = 4_096

    static func project(currentChargeableBytes: Int, reservedChargeableBytes: Int,
                        retrofits: [SealedMediaRetrofitCharge],
                        hardApplicationBytes: Int = SealedMediaStoreCapacityLimits.standard
                            .hardApplicationBytes) throws -> Int {
        let enforcedHardApplicationBytes = min(
            hardApplicationBytes, SealedMediaStoreCapacityLimits.maximumHardApplicationBytes)
        guard currentChargeableBytes >= 0, reservedChargeableBytes >= 0,
              enforcedHardApplicationBytes >= 0 else {
            throw HLSPublicationFailure.capacityExceeded
        }
        let projected = try retrofits.reduce(
            HLSChecked.add(currentChargeableBytes, reservedChargeableBytes)
        ) { partial, charge in
            guard charge.existingMapBytes >= 0,
                  charge.replacementMapBytes >= charge.existingMapBytes,
                  try HLSChecked.add(charge.replacementMapBytes, mediaEvidenceBytes)
                    <= 32 * 1_024 else { throw HLSPublicationFailure.capacityExceeded }
            return try HLSChecked.add(partial,
                                      charge.replacementMapBytes - charge.existingMapBytes)
        }
        guard projected <= enforcedHardApplicationBytes else {
            throw HLSPublicationFailure.capacityExceeded
        }
        return projected
    }
}

struct SealedMediaStoreCapacityLimits: Sendable {
    static let maximumHardApplicationBytes = 688 * 1_048_576
    static let standard = Self(hardApplicationBytes: maximumHardApplicationBytes)
    let hardApplicationBytes: Int

    init(hardApplicationBytes: Int) {
        self.hardApplicationBytes = min(max(0, hardApplicationBytes),
                                        Self.maximumHardApplicationBytes)
    }
}

struct HLSPlaylistSnapshot: Sendable {
    let identity: UUID
    let version: UInt64
    let representation: HLSPlaylistRepresentation
    let logicalSequences: [UInt64]
    let resources: [HLSResourceKey]
    let initializationResources: [HLSResourceKey]
    let bandwidth: HLSBandwidthMeasurement
    /// publisher 在同一 publication CAS 中冻结的有效播放终点。AAC 物理封装
    /// 可以结束于 Q，但 selection/EOS 只能使用去除 trailing trim 后的 N。
    let effectivePlaybackHorizon: ExactMediaTime?
    var raw: Data { representation.raw }
    var gzip: Data { representation.gzip }
    var text: String { representation.text }
}

final class HLSMediaResponseLease: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate let storeIdentity: UUID
    fileprivate let key: HLSResourceKey
    fileprivate var backing: SealedMediaBacking?
    private let domain: HLSLinearizationDomain
    let completedRange: Range<Int>
    let backingIdentity: SealedMediaBackingIdentity
    let residentByteCount: Int
    var terminalBindingIdentity: UUID { identity }
    var byteCount: Int { completedRange.count }
    fileprivate init(storeIdentity: UUID, key: HLSResourceKey, backing: SealedMediaBacking, range: Range<Int>, domain: HLSLinearizationDomain) {
        self.storeIdentity = storeIdentity
        self.key = key
        self.backing = backing
        completedRange = range
        self.domain = domain
        backingIdentity = backing.identity
        residentByteCount = backing.bytes.count
    }
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try domain.sync {
            guard let backing else { return try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
            return try backing.bytes.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[completedRange])) }
        }
    }
}

final class HLSPlaylistResponseLease: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate let storeIdentity: UUID
    fileprivate let snapshotIdentity: UUID
    /// GET admission 时冻结的完整 publication 版本；master representation 可以跨
    /// publication 复用，但完成事实不能因此退回它初次生成时的版本。
    let publicationVersion: UInt64
    fileprivate var storage: HLSPlaylistSnapshot?
    private let domain: HLSLinearizationDomain
    var snapshot: HLSPlaylistSnapshot? { domain.sync { storage } }
    func withSnapshot<T>(_ body: (HLSPlaylistSnapshot) throws -> T) rethrows -> T? {
        try domain.sync { guard let storage else { return nil }; return try body(storage) }
    }
    fileprivate init(storeIdentity: UUID, snapshot: HLSPlaylistSnapshot,
                     publicationVersion: UInt64, domain: HLSLinearizationDomain) {
        self.storeIdentity = storeIdentity
        snapshotIdentity = snapshot.identity
        self.publicationVersion = publicationVersion
        storage = snapshot
        self.domain = domain
    }
}

struct SealedMediaStoreUsage: Sendable {
    let resourceCount: Int
    let segmentCount: Int
    let residentBytes: Int
    let reservedBytes: Int
    let reservedSegmentCount: Int
    let shouldBackpressure: Bool
    let responseBackingBytes: Int
    let distinctResponseBackings: Int
    let responseTailCount: Int
    let shouldBackpressureResponses: Bool
    let snapshotCount: Int
    let snapshotBytes: Int
    let reservedSnapshotCount: Int
    let reservedSnapshotBytes: Int
    let tombstoneCount: Int
}

/// 先预留再接管已封口 backing；当前、未发布、协议 horizon、snapshot 与 response 各自保护对象。
final class SealedMediaStore: @unchecked Sendable {
    private struct AACWriterInitializationAlias {
        let canonicalKey: HLSResourceKey
        let compatibility: AACWriterInitializationCompatibility
    }
    private struct WriterInitializationAlias {
        let canonicalKey: HLSResourceKey
        let compatibility: WriterInitializationCompatibility
    }
    private struct Resource {
        let object: SealedMediaObject
        let proof: EpochFormatProof
        let receipt: SegmentValidationReceipt?
        let evidence: CompletedBodyEvidenceState
        let decodeMap: SealedDecodeCoverageMap?
        var aacPublicationAdmission: AACPublicationLeafAdmission? = nil
        var visible = false
        var unpublished = true
        var everPublished = false
        // 原三个Bool后的五字节padding：两owner、14选择引用、原槽、两watermark、九历史bit。
        fileprivate var metadataBits: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0xC0, 0x7F, 0, 0, 0)
        private var metadataWord: UInt64 {
            get {
                withUnsafeBytes(of: metadataBits) { bytes in
                    bytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
                }
            }
            set {
                withUnsafeMutableBytes(of: &metadataBits) { bytes in
                    for index in 0..<5 { bytes[index] = UInt8(truncatingIfNeeded: newValue >> (index * 8)) }
                }
            }
        }
        private mutating func setMetadata(_ value: UInt64, mask: UInt64, shift: Int) {
            metadataWord = (metadataWord & ~(mask << shift)) | ((value & mask) << shift)
        }
        var preparationPins: UInt8 {
            get { UInt8(metadataWord & 63) }
            set { setMetadata(UInt64(newValue), mask: 63, shift: 0) }
        }
        var preparationSlot: UInt16 {
            get { let value = UInt16((metadataWord >> 6) & 511); return value == 511 ? .max : value }
            set { setMetadata(UInt64(newValue == .max ? 511 : newValue), mask: 511, shift: 6) }
        }
        var preparationCompletionCounts: (UInt8, UInt8) {
            get { (UInt8((metadataWord >> 15) & 127), UInt8((metadataWord >> 22) & 127)) }
            set {
                setMetadata(UInt64(newValue.0), mask: 127, shift: 15)
                setMetadata(UInt64(newValue.1), mask: 127, shift: 22)
            }
        }
        var preparationHistoryPins: UInt16 {
            get { UInt16((metadataWord >> 29) & 511) }
            set { setMetadata(UInt64(newValue), mask: 511, shift: 29) }
        }
        var removedAt: Int64?
        var lastSnapshotCompletion: Int64?
        var longestPlaylistDuration: Int64 = 0
        var snapshotReferences = 0
        var responseReferences = 0
        var initializationKey: HLSResourceKey?
        var backingApplicationReservation: PlaybackApplicationChargeReservation?
        var evidenceApplicationReservation: PlaybackApplicationChargeReservation?
        var mapApplicationReservation: PlaybackApplicationChargeReservation?
        var applicationChargeableBytes: Int {
            object.backing.bytes.count
                + (object.kind == .initialization
                    ? LoopbackStorageLayout.current.initEvidenceAllocationBytes : 4_096)
                + (decodeMap?.applicationChargeableBytes ?? 0)
        }
        var duration: Int64 { (try? receipt.map { try HLSChecked.nanoseconds($0.presentationRange.duration) }) ?? 0 }
        func horizon() -> Int64? {
            guard let removedAt else { return nil }
            return try? HLSChecked.add(HLSChecked.add(max(removedAt, lastSnapshotCompletion ?? removedAt), duration), longestPlaylistDuration)
        }
    }
    private struct SnapshotEntry {
        let snapshot: HLSPlaylistSnapshot
        var current: Bool
        var leases = 0
    }

    let domain: HLSLinearizationDomain
    let itemGeneration: UInt64
    private let identity = UUID()
    private let token: String
    private let loopbackSessionIdentity: UUID?
    private let capacityLimits: SealedMediaStoreCapacityLimits
    private var closed = false
    private var resources: [HLSResourceKey: Resource] = [:]
    private let coverageAuthority = SealedCoverageIssuanceAuthority()
    private var coverageRequests: [LoopbackCoverageContext: [FMP4PresentationRange]] = [:]
    private var coverageReservations: [LoopbackCoverageContext: PlaybackApplicationChargeReservation] = [:]
    private var reservations: [UUID: SealedMediaReservation] = [:]
    private let publicationSecret = SymmetricKey(size: .bits256)
    private var uriDeclarations: [UInt64: HLSItemDeclaration] = [:]
    private var owner: HLSPublicationOwner?
    private var expectedTicket: PlaylistPublishTicket?
    private var currentVersion: UInt64 = 0
    private var candidates: [UInt64: HLSAudioCandidateRegistration] = [:]
    private struct CapacityWaiter {
        let owner: HLSPublicationOwner
        let ticket: PlaylistPublishTicket
        let wake: (Int64) -> Void
    }
    private var capacityWaiter: CapacityWaiter?
    private var mediaLeases: [UUID: HLSMediaResponseLease] = [:]
    private var snapshotLeases: [UUID: HLSPlaylistResponseLease] = [:]
    private var snapshots: [UUID: SnapshotEntry] = [:]
    private var currentSnapshots: [UInt64: UUID] = [:]
    private var masterIdentity: UUID?
    private var snapshotReservation: HLSSnapshotBatchReservation?
    private var pendingSnapshotGeneration: Set<UUID> = []
    private var retiredParticipants: Set<UInt64> = []
    /// 每个 participant 仅保留当前后继 writer 到 canonical init 的一条兼容边；
    /// 已封存 media map 自带完整身份，不依赖历史 alias 常驻。
    private var aacWriterInitializationAliases: [UInt64: AACWriterInitializationAlias] = [:]
    private var writerInitializationAliases: [UInt64: WriterInitializationAlias] = [:]
    private var instant: Int64 = 0
    private var preparationHistorySequences:
        (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0,0,0)

    private func preparationHistoryIndex(_ sequence: UInt64) -> Int? {
        withUnsafeBytes(of: preparationHistorySequences) { bytes in
            bytes.bindMemory(to: UInt64.self).firstIndex(of: sequence)
        }
    }

    func retainPreparationPublication(_ snapshot: HLSPlaylistSnapshot) {
        domain.sync {
            let index: Int
            if let existing = preparationHistoryIndex(snapshot.version) { index = existing }
            else {
                index = withUnsafeBytes(of: preparationHistorySequences) { bytes in
                    let values = bytes.bindMemory(to: UInt64.self)
                    return values.firstIndex(of: 0) ?? values.indices.min { values[$0] < values[$1] }!
                }
                let mask = UInt16(1) << index
                var cursor = resources.startIndex
                while cursor != resources.endIndex {
                    resources.values[cursor].preparationHistoryPins &= ~mask
                    resources.formIndex(after: &cursor)
                }
                withUnsafeMutableBytes(of: &preparationHistorySequences) {
                    $0.bindMemory(to: UInt64.self)[index] = snapshot.version
                }
            }
            let mask = UInt16(1) << index
            for key in snapshot.resources { resources[key]?.preparationHistoryPins |= mask }
            for key in snapshot.initializationResources { resources[key]?.preparationHistoryPins |= mask }
        }
    }

    func retainCurrentPreparationPublication(sequence: UInt64) {
        domain.sync {
            for entry in snapshots.values where entry.snapshot.version == sequence {
                retainPreparationPublication(entry.snapshot)
            }
        }
    }

    func retainCompletedResponseSlot(key: HLSResourceKey, range: Range<Int>)
        throws -> (resource: UInt16, range: UInt8) {
        try domain.sync {
            guard let resource = resources[key], resource.preparationHistoryPins != 0,
                  let rangeSlot = resource.evidence.completedRangeSlot(range) else {
                throw CompletedMediaEvidenceError.retired
            }
            let slot: UInt16
            if resource.preparationSlot != .max { slot = resource.preparationSlot }
            else {
                guard let available = (UInt16(0)..<300).first(where: { candidate in
                    !resources.values.contains(where: {
                        ($0.preparationPins != 0 || $0.preparationHistoryPins != 0)
                            && $0.preparationSlot == candidate
                    })
                }) else { throw CompletedMediaEvidenceError.capacityExceeded }
                slot = available
                resources[key]?.preparationSlot = slot
            }
            return (slot, rangeSlot)
        }
    }

    func completedResponseRange(resourceSlot: UInt16, rangeSlot: UInt8) -> Range<Int>? {
        domain.sync {
            resources.values.first(where: {
                $0.preparationSlot == resourceSlot && $0.preparationHistoryPins != 0
            })?.evidence.completedRange(at: rangeSlot)
        }
    }

    func preparationPublicationContains(_ key: HLSResourceKey, sequence: UInt64) -> Bool {
        domain.sync {
            if let index = preparationHistoryIndex(sequence) {
                return resources[key].map { $0.preparationHistoryPins & (UInt16(1) << index) != 0 } ?? false
            }
            return snapshots.values.contains {
                $0.snapshot.version == sequence
                    && ($0.snapshot.resources.contains(key) || $0.snapshot.initializationResources.contains(key))
            }
        }
    }

    func nextPreparationPublicationResource(sequence: UInt64, participantID: UInt64,
                                            kind: SealedMediaObjectKind,
                                            after previous: HLSResourceKey?) -> HLSResourceKey? {
        domain.sync {
            func less(_ lhs: HLSResourceKey, _ rhs: HLSResourceKey) -> Bool {
                lhs.logicalSequence < rhs.logicalSequence
                    || (lhs.logicalSequence == rhs.logicalSequence && lhs.mediaEpoch < rhs.mediaEpoch)
            }
            var next: HLSResourceKey?
            for key in resources.keys where key.participantID == participantID && key.kind == kind {
                guard previous.map({ less($0, key) }) ?? true,
                      next.map({ less(key, $0) }) ?? true,
                      preparationPublicationContains(key, sequence: sequence) else { continue }
                next = key
            }
            return next
        }
    }

    func releasePreparationHistory() {
        domain.sync {
            var cursor = resources.startIndex
            while cursor != resources.endIndex {
                resources.values[cursor].preparationHistoryPins = 0
                resources.formIndex(after: &cursor)
            }
            preparationHistorySequences = (0,0,0,0,0,0,0,0,0)
            evict()
        }
    }

    init(token: String, itemGeneration: UInt64, domain: HLSLinearizationDomain = HLSLinearizationDomain(),
         capacityLimits: SealedMediaStoreCapacityLimits = .standard) {
        self.token = token
        self.itemGeneration = itemGeneration
        self.domain = domain
        self.capacityLimits = capacityLimits
        loopbackSessionIdentity = nil
    }

    init(loopbackSession: LoopbackSessionToken, itemGeneration: UInt64,
         domain: HLSLinearizationDomain = HLSLinearizationDomain(),
         capacityLimits: SealedMediaStoreCapacityLimits = .standard) {
        token = loopbackSession.value
        self.itemGeneration = itemGeneration
        self.domain = domain
        self.capacityLimits = capacityLimits
        loopbackSessionIdentity = loopbackSession.identity
    }

    deinit { close() }

    func belongs(to session: LoopbackSessionToken) -> Bool {
        domain.sync { !closed && loopbackSessionIdentity == session.identity && token == session.value }
    }

    var isClosed: Bool { domain.sync { closed } }
#if DEBUG
    /// 只读原 Resource reservation；诊断数组不进入生产持有图。
    func preparationLeaseChargeSnapshot(ownerSlot: UInt8)
        -> (residentBytes: Int, identities: [ObjectIdentifier], charge: HLSDeliveryOwnedChargeSnapshot) {
        domain.sync {
            var bytes = 0
            var reservations: [PlaybackApplicationChargeReservation] = []
            for resource in resources.values where resource.preparationPins & ownerSlot != 0 {
                bytes += resource.object.backing.bytes.count
                if let value = resource.backingApplicationReservation { reservations.append(value) }
                if let value = resource.evidenceApplicationReservation { reservations.append(value) }
                if let value = resource.mapApplicationReservation { reservations.append(value) }
            }
            return (bytes, reservations.map(ObjectIdentifier.init),
                HLSDeliveryApplicationChargeLedger.shared.snapshot(ownedBy: reservations))
        }
    }
#endif
    var coverageContextCount: Int { domain.sync { coverageRequests.count } }
    var coverageApplicationChargeSnapshot: HLSDeliveryOwnedChargeSnapshot { domain.sync {
        HLSDeliveryApplicationChargeLedger.shared.snapshot(
            ownedBy: Array(coverageReservations.values))
    } }

    var usage: SealedMediaStoreUsage { domain.sync {
        let reserved = reservations.values.reduce(0) { $0 + $1.bytes }
        let resident = resources.values.reduce(0) { $0 + $1.object.backing.bytes.count }
        let chargedResident = resources.values.reduce(0) { $0 + $1.applicationChargeableBytes }
        let chargedReserved = reservations.values.reduce(0) { $0 + $1.bytes + $1.reservationOverheadBytes }
        let media = resources.values.filter { $0.object.kind == .media }
        let reservedMedia = reservations.values.filter { $0.kind == .media }
        let counts = Dictionary(grouping: media.map { $0.object.binding.publicationParticipantID.rawValue }
            + reservedMedia.map { $0.binding.publicationParticipantID.rawValue }, by: { $0 })
        let responses = resources.values.filter { $0.responseReferences > 0 }
        let responseBytes = responses.reduce(0) { $0 + $1.object.backing.bytes.count }
        return SealedMediaStoreUsage(resourceCount: resources.count, segmentCount: media.count,
            residentBytes: resident, reservedBytes: reserved, reservedSegmentCount: reservedMedia.count,
            shouldBackpressure: HLSDeliveryApplicationChargeLedger.shared.shouldBackpressure
                || chargedResident + chargedReserved >= 560 * 1_048_576
                || counts.values.contains { $0.count >= 42 },
            responseBackingBytes: responseBytes, distinctResponseBackings: responses.count,
            responseTailCount: responses.filter { $0.horizon().map { instant >= $0 } ?? false }.count,
            shouldBackpressureResponses: responses.count >= 6 || responseBytes >= 96 * 1_048_576,
            snapshotCount: snapshots.count, snapshotBytes: snapshots.values.reduce(0) { $0 + $1.snapshot.representation.residentBytes },
            reservedSnapshotCount: snapshotReservation?.count ?? 0, reservedSnapshotBytes: snapshotReservation?.bytes ?? 0,
            tombstoneCount: 0)
    } }

    var capacityWaiterCount: Int { domain.sync { capacityWaiter == nil ? 0 : 1 } }
    func registerAudioCandidate(initialization: SealedMediaObject, proof: EpochFormatProof,
                                declaration: HLSItemDeclaration,
                                replacing previous: HLSAudioCandidateRegistration? = nil) throws -> HLSAudioCandidateRegistration { try domain.sync {
        let id = proof.binding.publicationParticipantID.rawValue
        guard !closed, !retiredParticipants.contains(id), proof.matches(initialization: initialization), proof.mediaType == .audio,
              declaration.video == nil, declaration.audio.count == 1, declaration.audio[0].participantID == id,
              declaration.itemGeneration == proof.binding.itemGeneration.rawValue, declaration.token == token else {
            throw HLSPublicationFailure.identityMismatch
        }
        try HLSPlaylistSerializer.validate(declaration)
        let ticket: AudioCandidateTicket
        if let previous {
            guard candidates[id] === previous, previous.storeIdentity == identity,
                  previous.declaration == declaration,
                  previous.binding.itemGeneration == proof.binding.itemGeneration,
                  previous.binding.outputLifecycleEpoch == proof.binding.outputLifecycleEpoch,
                  previous.binding.renditionIdentity == proof.binding.renditionIdentity,
                  previous.binding.mediaEpoch.rawValue < proof.binding.mediaEpoch.rawValue else { throw HLSPublicationFailure.identityMismatch }
            ticket = previous.ticket
        } else {
            guard candidates[id] == nil, candidates.count < 3,
                  !candidates.values.contains(where: { $0.binding.itemGeneration == proof.binding.itemGeneration }) else {
                throw HLSPublicationFailure.identityMismatch
            }
            ticket = .init(rawValue: try PlaybackIdentityAllocator.shared.next(in: .nonce))
        }
        let candidate = HLSAudioCandidateRegistration(ticket: ticket, proof: proof, declaration: declaration,
            storeIdentity: identity, previousIdentity: previous?.identity)
        // epoch 替换仅签发有前置身份的准备资格；准确 init batch 成功后才替换 active。
        if previous == nil { candidates[id] = candidate }
        return candidate
    } }
    func acceptsCandidate(_ candidate: HLSAudioCandidateRegistration, proof: EpochFormatProof) -> Bool {
        domain.sync {
            let current = candidates[proof.binding.publicationParticipantID.rawValue]
            return !closed && !retiredParticipants.contains(proof.binding.publicationParticipantID.rawValue)
                && candidate.storeIdentity == identity
                && (current === candidate || (current != nil && current?.identity == candidate.previousIdentity))
                && current?.declaration == candidate.declaration
                && candidate.binding == proof.binding && candidate.proofIdentity == proof.identity
        }
    }
    func claimPublicationOwner() throws -> HLSPublicationOwner { try domain.sync {
        guard !closed, owner == nil else { throw HLSPublicationFailure.staleTicket }
        let value = HLSPublicationOwner(); owner = value; return value
    } }
    func abandonPublicationOwner(_ value: HLSPublicationOwner) { domain.sync {
        if owner === value && currentVersion == 0 && expectedTicket == nil { owner = nil }
    } }
    func bindPublication(_ ticket: PlaylistPublishTicket, owner value: HLSPublicationOwner,
                         declarations: [UInt64: HLSItemDeclaration]) throws { try domain.sync {
        guard !closed, owner === value, ticket.publicationSequence == currentVersion,
              (1...4).contains(ticket.participantVector.count), declarations.count <= 4,
              Set(declarations.keys) == Set(ticket.participantVector.map(\.participantID)),
              ticket.participantVector.allSatisfy({ declarations[$0.participantID] == $0.declaration }),
              ticket.participantVector.allSatisfy({ $0.expectedPreviousSnapshotVersion == currentVersion }) else {
            throw HLSPublicationFailure.staleTicket
        }
        expectedTicket = ticket
        for (id, declaration) in declarations { uriDeclarations[id] = declaration }
        cancelCapacityWait(owner: value)
    } }
    func validatePublication(_ ticket: PlaylistPublishTicket, owner value: HLSPublicationOwner) throws { try domain.sync {
        guard !closed, owner === value, expectedTicket == ticket,
              ticket.publicationSequence == currentVersion,
              ticket.participantVector.allSatisfy({ uriDeclarations[$0.participantID] == $0.declaration }),
              ticket.participantVector.allSatisfy({ $0.expectedPreviousSnapshotVersion == currentVersion }) else {
            throw HLSPublicationFailure.staleTicket
        }
    } }
    func waitForSnapshotCapacity(owner value: HLSPublicationOwner, ticket: PlaylistPublishTicket,
                                wake: @escaping (Int64) -> Void) throws { try domain.sync {
        try validatePublication(ticket, owner: value)
        guard capacityWaiter == nil || capacityWaiter?.ticket == ticket else { throw HLSPublicationFailure.staleTicket }
        if capacityWaiter == nil { capacityWaiter = CapacityWaiter(owner: value, ticket: ticket, wake: wake) }
    } }
    func cancelCapacityWait(owner value: HLSPublicationOwner, ticket: PlaylistPublishTicket? = nil) { domain.sync {
        guard capacityWaiter?.owner === value, ticket == nil || capacityWaiter?.ticket == ticket else { return }
        capacityWaiter = nil
        pendingSnapshotGeneration.removeAll(keepingCapacity: true)
    } }

    /// 只有持有准确 owner/ticket 的待提交 batch 才能生成可序列化的发布身份；失败 batch 不对外返回它。
    func authenticatedKey(_ key: HLSResourceKey,
                          authority: HLSPublicationCoordinator.PreparationAuthority) throws -> HLSResourceKey { try domain.sync {
        try authority.validate(store: self)
        guard snapshotReservation != nil, resources[key] != nil else { throw HLSPublicationFailure.staleTicket }
        var result = key
        result.authentication = authentication(key)
        return result
    } }
    private func authentication(_ key: HLSResourceKey) -> String {
        let message = "\(key.itemGeneration)/\(key.mediaEpoch)/\(key.participantID)/\(key.logicalSequence)/\(key.kind.rawValue)"
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: publicationSecret).map { String(format: "%02x", $0) }.joined()
    }
    private func authentic(_ key: HLSResourceKey) -> Bool {
        let expected = Array(authentication(key).utf8), actual = Array(key.authentication.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func resourceURI(_ key: HLSResourceKey, declaration: HLSItemDeclaration) throws -> String { try domain.sync {
        guard authentic(key), uriDeclarations[key.participantID] != nil else { throw HLSPublicationFailure.identityMismatch }
        return try declaration.resourceURI(key)
    } }

    func resourceURI(_ key: HLSResourceKey) throws -> String { try domain.sync {
        guard let declaration = uriDeclarations[key.participantID] else {
            throw HLSPublicationFailure.identityMismatch
        }
        return try resourceURI(key, declaration: declaration)
    } }

    func completedEvidenceSnapshot(for key: HLSResourceKey) -> CompletedBodyEvidenceSnapshot? { domain.sync {
        guard authentic(key) else { return nil }
        return resources[key]?.evidence.snapshot
    } }

    func aacPublicationAdmission(for key: HLSResourceKey)
        -> AACPublicationLeafAdmission? {
        domain.sync { authentic(key) ? resources[key]?.aacPublicationAdmission : nil }
    }

    /// preparation owner 只可沿其已固定的资源槽取得 publisher 私签 admission；
    /// 不接受调用方 key，也不会把任意历史成员提升成当前 HTTP 证明。
    func aacPublicationAdmission(preparationSlot: Int, ownerSlot: UInt8)
        -> AACPublicationLeafAdmission? {
        domain.sync {
            guard (ownerSlot == 1 || ownerSlot == 2),
                  let resource = resources.values.first(where: {
                      Int($0.preparationSlot) == preparationSlot
                        && ($0.preparationPins & ownerSlot) != 0
                  }) else { return nil }
            return resource.aacPublicationAdmission
        }
    }

    func retainPreparationResource(_ key: HLSResourceKey, ownerSlot: UInt8,
                                   requiresCompleted: Bool = true) throws -> Int {
        try domain.sync {
            guard !closed, ownerSlot == 1 || ownerSlot == 2,
                  let resource = resources[key], !requiresCompleted || resource.evidence.isComplete else {
                throw CompletedMediaEvidenceError.retired
            }
            let slot: UInt16
            if resource.preparationSlot != .max,
               resource.preparationPins != 0 || resource.preparationHistoryPins != 0 {
                slot = resource.preparationSlot
            }
            else {
                guard let available = (UInt16(0)..<300).first(where: { candidate in
                    !resources.values.contains(where: {
                        ($0.preparationPins != 0 || $0.preparationHistoryPins != 0)
                            && $0.preparationSlot == candidate
                    })
                }) else { throw CompletedMediaEvidenceError.capacityExceeded }
                slot = available
            }
            resources[key]?.preparationSlot = slot
            if requiresCompleted {
                let count = UInt8(resource.evidence.uniqueCompletedResponseCount)
                if ownerSlot == 1 { resources[key]?.preparationCompletionCounts.0 = count }
                else { resources[key]?.preparationCompletionCounts.1 = count }
            }
            resources[key]?.preparationPins |= ownerSlot
            return Int(slot)
        }
    }

    func preparationResourceIsComplete(slot: Int, ownerSlot: UInt8) -> Bool {
        domain.sync {
            resources.values.first(where: {
                $0.preparationPins & ownerSlot != 0 && Int($0.preparationSlot) == slot
            })?.evidence.isComplete == true
        }
    }

    func preparationCoverageInput(slot: Int, ownerSlot: UInt8) -> SealedCoverageInput? {
        domain.sync {
            guard let resource = resources.values.first(where: {
                $0.preparationPins & ownerSlot != 0 && Int($0.preparationSlot) == slot
            }), resource.object.kind == .media, let map = resource.decodeMap,
                  let initialization = resources.values.first(where: {
                      $0.preparationPins & ownerSlot != 0
                        && $0.object.backing.identity == map.initializationBackingIdentity
                  }) else { return nil }
            let count = ownerSlot == 1 ? resource.preparationCompletionCounts.0
                : resource.preparationCompletionCounts.1
            let initCount = ownerSlot == 1 ? initialization.preparationCompletionCounts.0
                : initialization.preparationCompletionCounts.1
            return .init(media: resource.evidence.preparationSnapshot(completedCount: Int(count),
                authority: coverageAuthority),
                map: map,
                initialization: initialization.evidence.preparationSnapshot(completedCount: Int(initCount),
                    authority: coverageAuthority))
        }
    }

    func preparationResource(slot: Int, ownerSlot: UInt8)
        -> (key: HLSResourceKey, backing: SealedMediaBackingIdentity,
            rendition: AudioRenditionIdentity, digest: Data, length: Int,
            presentationRange: FMP4PresentationRange?)? {
        domain.sync {
            guard let resource = resources.values.first(where: {
                (ownerSlot == .max ? $0.preparationHistoryPins != 0
                    : ownerSlot == 0 ? $0.preparationPins >= 4 : $0.preparationPins & ownerSlot != 0)
                    && Int($0.preparationSlot) == slot
            }) else { return nil }
            let range: FMP4PresentationRange?
            if let map = resource.decodeMap,
               let first = map.samples.min(by: {
                   CMTimeCompare($0.presentationRange.start.cmTime,
                                 $1.presentationRange.start.cmTime) < 0
               }), let last = map.samples.max(by: {
                   CMTimeCompare($0.presentationRange.end.cmTime,
                                 $1.presentationRange.end.cmTime) < 0
               }) {
                range = try? .init(start: first.presentationRange.start,
                    duration: last.presentationRange.end.subtracting(first.presentationRange.start))
            } else { range = nil }
            return (HLSResourceKey(resource.object), resource.object.backing.identity,
                    resource.proof.binding.renditionIdentity, resource.object.digest,
                    resource.object.backing.bytes.count, range)
        }
    }

    func retainSelectionMetadata(_ key: HLSResourceKey) throws -> UInt16 {
        try domain.sync {
            guard !closed, let resource = resources[key], resource.decodeMap != nil,
                  resource.preparationPins >> 2 < 14 else { throw CompletedMediaEvidenceError.retired }
            let slot: UInt16
            if resource.preparationSlot != .max,
               resource.preparationPins != 0 || resource.preparationHistoryPins != 0 {
                slot = resource.preparationSlot
            }
            else {
                guard let available = (UInt16(0)..<300).first(where: { candidate in
                    !resources.values.contains(where: {
                        ($0.preparationPins != 0 || $0.preparationHistoryPins != 0)
                            && $0.preparationSlot == candidate
                    })
                }) else { throw CompletedMediaEvidenceError.capacityExceeded }
                slot = available
            }
            resources[key]?.preparationSlot = slot
            resources[key]?.preparationPins += 4
            return slot
        }
    }

    func releaseSelectionMetadata(slot: UInt16) {
        domain.sync {
            guard let key = resources.first(where: {
                $0.value.preparationSlot == slot && $0.value.preparationPins >= 4
            })?.key else { return }
            resources[key]?.preparationPins -= 4
            evict()
        }
    }

    func releasePreparationMetadata(ownerSlot: UInt8) {
        domain.sync {
            var cursor = resources.startIndex
            while cursor != resources.endIndex {
                resources.values[cursor].preparationPins &= ~ownerSlot
                resources.formIndex(after: &cursor)
            }
            evict()
        }
    }
    func decodeCoverageMap(for key: HLSResourceKey) -> SealedDecodeCoverageMap? { domain.sync {
        return resources[key]?.decodeMap
    } }
    func coverageInputs(renditionIdentity: AudioRenditionIdentity) -> [SealedCoverageInput] { domain.sync {
        resources.values.compactMap { resource in
            guard resource.object.kind == .media,
                  resource.object.binding.renditionIdentity == renditionIdentity,
                  let media = resource.evidence as? CompletedMediaBodyEvidenceState,
                  let map = resource.decodeMap,
                  let initialization = resources.values.first(where: {
                      $0.object.kind == .initialization
                        && $0.object.backing.identity == map.initializationBackingIdentity
                  })?.evidence as? CompletedInitBodyEvidenceState,
                  initialization.stateIdentity == map.initializationStateIdentity else { return nil }
            return .init(media: media.snapshot, map: map,
                         initialization: initialization.snapshot)
        }
    } }

    /// history、存活依赖复验、join 与 opaque receipt 签发都在线性化域内完成。
    func preparationCoverageReceipt(owner: FrozenPreparationOwner,
                                    context: LoopbackCoverageContext,
                                    requested: FMP4PresentationRange) throws
        -> ServedRenditionCoverageReceipt? {
        try domain.sync {
            guard owner.metadataStore === self,
                  context.preparedPlayheadIdentity.itemGeneration == itemGeneration else { return nil }
            guard let dependencies = try ServedCoverageDependencies.frozen(owner: owner,
                rendition: context.renditionIdentity, requested: requested) else { return nil }
            var cursor = requested.start
            for _ in 0..<dependencies.count {
                var next = cursor
                for ordinal in dependencies.indices {
                    guard let input = dependencies.input(atOrdinal: ordinal),
                          let range = try input.map.intersection(with: requested) else { continue }
                    if try HLSChecked.compare(range.start, cursor) <= 0,
                       try HLSChecked.compare(range.end, next) > 0 { next = range.end }
                }
                if try HLSChecked.compare(next, requested.end) >= 0 { cursor = next; break }
                guard try HLSChecked.compare(next, cursor) > 0 else { return nil }
                cursor = next
            }
            guard try HLSChecked.compare(cursor, requested.end) >= 0 else { return nil }
            var hash = SHA256()
            func append<T: FixedWidthInteger>(_ value: T) {
                var bigEndian = value.bigEndian
                withUnsafeBytes(of: &bigEndian) { hash.update(bufferPointer: $0) }
            }
            func appendUUID(_ value: UUID) {
                withUnsafeBytes(of: value.uuid) { hash.update(bufferPointer: $0) }
            }
            func appendDigest(_ value: Data) {
                append(UInt64(value.count))
                hash.update(data: value)
            }
            append(itemGeneration)
            append(context.renditionIdentity.rawValue)
            for ordinal in dependencies.indices {
                let dependency = dependencies[ordinal]
                let input = dependencies.input(atOrdinal: ordinal)!
                let range = try input.map.intersection(with: requested)!
                append(dependency.mediaEpoch)
                appendUUID(dependency.epochProofIdentity)
                appendUUID(dependency.segmentReceiptIdentity)
                appendUUID(dependency.initializationBackingIdentity.rawValue)
                appendUUID(dependency.mediaBackingIdentity.rawValue)
                appendUUID(dependency.initializationEvidenceIdentity)
                appendUUID(dependency.mediaEvidenceIdentity)
                appendDigest(input.initialization.sealedDigest)
                appendDigest(input.media.sealedDigest)
                append(range.start.value)
                append(UInt64(range.start.timescale))
                append(range.end.value)
                append(UInt64(range.end.timescale))
            }
            return .init(authority: coverageAuthority,
                preparedPlayheadIdentity: context.preparedPlayheadIdentity,
                observedRenditionSetReceiptIdentity: context.observedRenditionSetReceipt.identity,
                renditionIdentity: context.renditionIdentity, itemGeneration: itemGeneration,
                canonicalCoverageDigest: .init(hash.finalize()), presentationRange: requested,
                dependencies: dependencies)
        }
    }

    /// 冻结前只读预检。仅遍历该 owner 已钉住且 HTTP full-body 完成的对象，
    /// 并复用正式 decode-map 闭包算法；不签发 receipt，也不改变 owner 状态。
    func preparationCoverageCanFreeze(
        owner: FrozenPreparationOwner,
        rendition: AudioRenditionIdentity,
        requested: FMP4PresentationRange
    ) throws -> Bool {
        try domain.sync {
            guard owner.metadataStore === self else { return false }
            var ranges: [FMP4PresentationRange] = []
            ranges.reserveCapacity(128)
            var pinnedMedia = 0
            var completedMedia = 0
            var matchingInitialization = 0
            var completedInitialization = 0
            var intersectingMaps = 0
            for resource in resources.values {
                guard resource.preparationPins & owner.slot != 0,
                      resource.object.kind == .media,
                      resource.object.binding.renditionIdentity == rendition else {
                    continue
                }
                pinnedMedia += 1
                guard resource.evidence.isComplete else { continue }
                completedMedia += 1
                guard let map = resource.decodeMap,
                      let initialization = resources.values.first(where: {
                          $0.preparationPins & owner.slot != 0
                            && $0.object.kind == .initialization
                            && $0.object.backing.identity
                                == map.initializationBackingIdentity
                      }) else {
                    continue
                }
                matchingInitialization += 1
                guard initialization.evidence.isComplete else { continue }
                completedInitialization += 1
                let media = resource.evidence.snapshot
                guard try map.intersection(with: requested) != nil else {
                    continue
                }
                intersectingMaps += 1
                let fragments = try map.coveredFragments(
                    by: media,
                    intersecting: requested
                )
                guard ranges.count + fragments.count <= 128 else {
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
                ranges.append(contentsOf: fragments)
            }
            #if DEBUG
            let diagnostic = "covstore_\(rendition.rawValue)_p\(pinnedMedia)" +
                "_m\(completedMedia)_i\(matchingInitialization)" +
                "_ic\(completedInitialization)_x\(intersectingMaps)_c\(ranges.count)"
            #endif
            guard !ranges.isEmpty else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(diagnostic)
                #endif
                return false
            }
            var cursor = requested.start
            for _ in 0..<ranges.count {
                var next = cursor
                for range in ranges where
                    try HLSChecked.compare(range.start, cursor) <= 0
                        && HLSChecked.compare(range.end, next) > 0 {
                    next = range.end
                }
                if try HLSChecked.compare(next, requested.end) >= 0 { return true }
                guard try HLSChecked.compare(next, cursor) > 0 else {
                    #if DEBUG
                    let following = ranges
                        .filter { CMTimeCompare($0.start.cmTime, cursor.cmTime) > 0 }
                        .min { CMTimeCompare($0.start.cmTime, $1.start.cmTime) < 0 }
                    let gap = following.flatMap { try? $0.start.subtracting(cursor) }
                    PlaybackDiagnosticTracker.shared.append(
                        diagnostic + "_gap_"
                            + "c\(cursor.value)x\(cursor.timescale)_"
                            + "n\(following?.start.value ?? -1)x"
                            + "\(following?.start.timescale ?? 1)_"
                            + "d\(gap?.value ?? -1)x\(gap?.timescale ?? 1)"
                    )
                    #endif
                    return false
                }
                cursor = next
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append(diagnostic + "_short")
            #endif
            return false
        }
    }

    /// 非player的HTTP覆盖累计器保留原delivery预算；player消费走原metadata租约视图。
    func coverageReceipt(for context: LoopbackCoverageContext,
                         adding requested: FMP4PresentationRange) throws
        -> ServedRenditionCoverageReceipt? { try domain.sync {
        guard !closed,
              context.preparedPlayheadIdentity.itemGeneration == itemGeneration,
              context.observedRenditionSetReceipt.preparedPlayheadIdentity
                == context.preparedPlayheadIdentity,
              context.observedRenditionSetReceipt.orderedRenditionIdentities
                .contains(context.renditionIdentity) else { return nil }
        if coverageReservations[context] == nil {
            guard coverageReservations.count < 8 else {
                throw CompletedMediaEvidenceError.capacityExceeded
            }
            do {
                coverageReservations[context] = try HLSDeliveryApplicationChargeLedger.shared.reserve(
                    allocationIdentity: UUID(),
                    bytes: LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes)
            } catch let error as LoopbackHTTPReservationError {
                switch error {
                case .backpressure, .hardCapacityExceeded:
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
            }
        }
        let requests = try Self.canonicalCoverageRanges(
            (coverageRequests[context] ?? []) + [requested])
        guard requests.count <= LoopbackStorageLayout.current.coverageAccumulatorRangeCapacity else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        coverageRequests[context] = requests

        let accumulator = ServedRenditionCoverageAccumulator(authority: coverageAuthority,
            preparedPlayheadIdentity: context.preparedPlayheadIdentity,
            observedRenditionSetReceipt: context.observedRenditionSetReceipt,
            renditionIdentity: context.renditionIdentity)
        let liveInputs: [SealedCoverageInput] = resources.values.compactMap { resource in
            guard resource.object.kind == .media,
                  resource.object.binding.renditionIdentity == context.renditionIdentity,
                  let media = resource.evidence as? CompletedMediaBodyEvidenceState,
                  let map = resource.decodeMap,
                  map.resourceIdentity == resource.object.backing.identity,
                  map.epochProofIdentity == resource.proof.identity,
                  map.segmentReceiptIdentity == resource.receipt?.identity,
                  let initialization = resources.values.first(where: {
                      $0.object.kind == .initialization
                          && $0.object.backing.identity == map.initializationBackingIdentity
                  }), let initEvidence = initialization.evidence as? CompletedInitBodyEvidenceState,
                  map.evidenceStateIdentity == media.stateIdentity,
                  map.initializationStateIdentity == initEvidence.stateIdentity else { return nil }
            return .init(media: media.snapshot, map: map,
                         initialization: initEvidence.snapshot)
        }
        var receipt: ServedRenditionCoverageReceipt?
        for wanted in requests {
            for input in liveInputs {
                guard let intersection = try input.map.intersection(with: wanted) else { continue }
                receipt = try accumulator.join(media: input.media, map: input.map,
                    initialization: input.initialization,
                    requestedPresentationRange: intersection) ?? receipt
            }
        }
        guard let receipt,
              try HLSChecked.compare(receipt.presentationRange.start, requested.start) <= 0,
              try HLSChecked.compare(receipt.presentationRange.end, requested.end) >= 0 else {
            return nil
        }
        return receipt
    } }

    /// 请求历史只保存规范并集；嵌套、重复与相邻请求不会消耗新的固定槽位。
    private static func canonicalCoverageRanges(_ input: [FMP4PresentationRange]) throws
        -> [FMP4PresentationRange] {
        let ordered = try input.sorted {
            let start = try HLSChecked.compare($0.start, $1.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare($0.end, $1.end) < 0
        }
        var result: [FMP4PresentationRange] = []
        result.reserveCapacity(min(LoopbackStorageLayout.current.coverageAccumulatorRangeCapacity,
                                   ordered.count))
        for range in ordered {
            guard let previous = result.last else { result.append(range); continue }
            if try HLSChecked.compare(range.start, previous.end) <= 0 {
                let end = try HLSChecked.compare(range.end, previous.end) > 0
                    ? range.end : previous.end
                result[result.count - 1] = try FMP4PresentationRange(start: previous.start,
                    duration: end.subtracting(previous.start))
            } else {
                guard result.count < LoopbackStorageLayout.current.coverageAccumulatorRangeCapacity else {
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
                result.append(range)
            }
        }
        return result
    }
    func resolveHTTPResourceURI(_ uri: String, now: Int64) -> HLSHTTPResourceResolution { domain.sync {
        guard let key = authenticatedKey(forURI: uri) else { return .notFound }
        switch lookup(key, token: token, now: now) {
        case .notFound: return .notFound
        case .gone: return .gone
        case .available:
            guard let resource = resources[key] else { return .gone }
            return .available(.init(key: key, byteCount: resource.object.bytes.count,
                backingIdentity: resource.object.backing.identity,
                sealedDigest: resource.object.digest, mediaType: resource.proof.mediaType,
                aacMediaMembershipLeaf: resource.object.aacMediaMembershipLeaf,
                aacPublicationAdmission: resource.aacPublicationAdmission))
        }
    } }

    private func authenticatedKey(forURI uri: String) -> HLSResourceKey? {
        guard uri.utf8.count <= 1_024,
              let components = URLComponents(string: uri), components.scheme == nil, components.host == nil,
              let items = components.queryItems, items.count == 2,
              items[0].name == "p", let participant = items[0].value.flatMap(UInt64.init),
              items[1].name == "a", let auth = items[1].value,
              let declaration = uriDeclarations[participant] else { return nil }
        let pieces = components.path.split(separator: "/").map(String.init)
        guard pieces.count >= 6, pieces[0] == "v1", pieces[1] == token,
              let item = UInt64(pieces[2]), let epoch = UInt64(pieces[3]), let file = pieces.last else { return nil }
        let kind: SealedMediaObjectKind = file == "init.mp4" ? .initialization : .media
        guard kind == .initialization || file.hasSuffix(".m4s"),
              let sequence = kind == .initialization ? UInt64(0) : UInt64(file.dropLast(4)) else { return nil }
        let key = HLSResourceKey(item: item, epoch: epoch, participant: participant,
            sequence: sequence, kind: kind, authentication: auth)
        guard authentic(key), (try? declaration.resourceURI(key)) == uri else { return nil }
        return key
    }
    func lookupURI(_ uri: String, now: Int64) -> HLSResourceAvailability { domain.sync {
        guard uri.utf8.count <= 1_024,
              let components = URLComponents(string: uri), components.scheme == nil, components.host == nil,
              let items = components.queryItems, items.count == 2,
              items[0].name == "p", let participant = items[0].value.flatMap(UInt64.init),
              items[1].name == "a", let auth = items[1].value,
              let declaration = uriDeclarations[participant] else { return .notFound }
        let pieces = components.path.split(separator: "/").map(String.init)
        guard pieces.count >= 6, pieces[0] == "v1", pieces[1] == token,
              let item = UInt64(pieces[2]), let epoch = UInt64(pieces[3]), let file = pieces.last else { return .notFound }
        let kind: SealedMediaObjectKind = file == "init.mp4" ? .initialization : .media
        guard kind == .initialization || file.hasSuffix(".m4s"),
              let sequence = kind == .initialization ? UInt64(0) : UInt64(file.dropLast(4)) else { return .notFound }
        let key = HLSResourceKey(item: item, epoch: epoch, participant: participant, sequence: sequence, kind: kind, authentication: auth)
        guard authentic(key), (try? declaration.resourceURI(key)) == uri else { return .notFound }
        return lookup(key, token: token, now: now)
    } }

    func reserveMedia(binding: FMP4WriterBinding, kind: SealedMediaObjectKind, bodyBytes: Int,
                      candidate: HLSAudioCandidateRegistration? = nil) throws -> SealedMediaReservation {
        try domain.sync {
            guard !closed, !retiredParticipants.contains(binding.publicationParticipantID.rawValue) else { throw HLSPublicationFailure.closed }
            let active = candidates[binding.publicationParticipantID.rawValue]
            let preparedInitialization = kind == .initialization && candidate?.storeIdentity == identity
                && candidate?.binding == binding && active != nil && active?.identity == candidate?.previousIdentity
            guard (binding.itemGeneration.rawValue == itemGeneration
                || active?.binding == binding || preparedInitialization), bodyBytes >= 0 else {
                throw HLSPublicationFailure.identityMismatch
            }
            let activeIDs = Set(resources.keys.map(\.participantID) + reservations.values.map { $0.binding.publicationParticipantID.rawValue })
            guard activeIDs.contains(binding.publicationParticipantID.rawValue) || activeIDs.count < 4 else {
                throw HLSPublicationFailure.capacityExceeded
            }
            let chargedResident = resources.values.reduce(0) { $0 + $1.applicationChargeableBytes }
            let chargedReserved = reservations.values.reduce(0) { $0 + $1.bytes + $1.reservationOverheadBytes }
            let overhead = kind == .initialization ? LoopbackStorageLayout.current.initEvidenceAllocationBytes : 32 * 1_024
            let total = try HLSChecked.add(HLSChecked.add(chargedResident, chargedReserved),
                                           HLSChecked.add(bodyBytes, overhead))
            guard total <= capacityLimits.hardApplicationBytes else {
                throw HLSPublicationFailure.capacityExceeded
            }
            if kind == .initialization {
                guard bodyBytes <= LoopbackStorageLayout.current.initMaximumBodyBytes,
                      resources.values.filter({ $0.object.kind == .initialization }).count
                        + reservations.values.filter({ $0.kind == .initialization }).count < 160 else { throw HLSPublicationFailure.capacityExceeded }
            } else {
                let count = resources.values.filter { $0.object.kind == .media && $0.object.binding.publicationParticipantID == binding.publicationParticipantID }.count
                    + reservations.values.filter { $0.kind == .media && $0.binding.publicationParticipantID == binding.publicationParticipantID }.count
                guard count < 48 else { throw HLSPublicationFailure.capacityExceeded }
            }
            let reservation = SealedMediaReservation(identity: UUID(), storeIdentity: identity, binding: binding, kind: kind, bytes: bodyBytes)
            reservations[reservation.identity] = reservation
            return reservation
        }
    }
    func cancel(_ reservation: SealedMediaReservation) { domain.sync {
        if reservation.storeIdentity == identity { reservations.removeValue(forKey: reservation.identity) }
    } }

    @discardableResult
    func admit(_ object: SealedMediaObject, proof: EpochFormatProof, receipt: SegmentValidationReceipt?,
               relay: SegmentReportRelay, reservation: SealedMediaReservation) throws -> HLSResourceKey {
        try domain.sync {
            guard !closed, reservations[reservation.identity] == reservation, reservation.storeIdentity == identity,
                  reservation.binding == object.binding, reservation.kind == object.kind,
                  reservation.bytes == object.backing.bytes.count,
                  !retiredParticipants.contains(object.binding.publicationParticipantID.rawValue),
                  proof.binding == object.binding else { throw HLSPublicationFailure.identityMismatch }
            let exact = try FinalFMP4Validator.validateObject(object, kind: object.kind, binding: proof.binding)
            if let ticket = expectedTicket {
                guard let entry = ticket.participantVector.first(where: { $0.participantID == object.binding.publicationParticipantID.rawValue }),
                      entry.binding == object.binding,
                      entry.proofIdentity == proof.identity,
                      uriDeclarations[entry.participantID] == entry.declaration,
                      object.kind == .initialization || object.logicalSequence >= entry.expectedLogicalSequence else {
                    throw HLSPublicationFailure.staleTicket
                }
            }
            if object.kind == .initialization {
                guard proof.matches(initializationIdentity: exact), receipt == nil else { throw HLSPublicationFailure.identityMismatch }
            } else {
                guard let receipt, receipt.matches(mediaIdentity: exact, proof: proof) else { throw HLSPublicationFailure.identityMismatch }
            }
            let key = HLSResourceKey(object)
            guard resources[key] == nil else { throw HLSPublicationFailure.identityMismatch }
            let unchargedResource = try makeResource(object: object, proof: proof, receipt: receipt)
            let unchargedRetrofits = try prepareRetrofits(initializations:
                object.kind == .initialization ? [key: unchargedResource] : [:])
            var resource: Resource?
            var retrofits: [HLSResourceKey: Resource] = [:]
            do {
                resource = try registerApplicationCharges(for: unchargedResource)
                retrofits = try registerRetrofitMapCharges(unchargedRetrofits)
                try relay.transferToStore(object) {
                    resources[key] = resource
                    for (mediaKey, retrofitted) in retrofits { resources[mediaKey] = retrofitted }
                    reservations.removeValue(forKey: reservation.identity)
                }
            } catch {
                if let resource { releaseApplicationCharges(resource) }
                for retrofit in retrofits.values { releaseMapApplicationCharge(retrofit) }
                throw error
            }
            return key
        }
    }

    /// publisher 已验证 rendition/window 顺序且释放后继 init 的 relay owner 后，
    /// store 才把一次性 writer admission 绑定到实际服务的 canonical init。
    func advanceAACWriterWindowInitialization(
        canonicalKey: HLSResourceKey,
        predecessorInitialization: SealedMediaObject,
        predecessorProof: EpochFormatProof,
        successorInitialization: SealedMediaObject,
        successorProof: EpochFormatProof,
        admission: AACWriterWindowAdmission,
        relay: SegmentReportRelay,
        terminalBinding: AACWriterTerminalBinding?,
        renditionBinding: AACRenditionTerminalBinding?
    ) -> Bool { domain.sync {
        let id = successorProof.binding.publicationParticipantID.rawValue
        guard !closed, !retiredParticipants.contains(id),
              canonicalKey.participantID == id,
              let canonical = resources[canonicalKey],
              canonical.object.kind == .initialization else { return false }
        let canonicalProof = canonical.proof
        if let previousAlias = aacWriterInitializationAliases[id] {
            guard previousAlias.canonicalKey == canonicalKey,
                  previousAlias.compatibility.successorProofIdentity
                    == predecessorProof.identity else { return false }
        } else {
            guard canonicalProof == predecessorProof else { return false }
        }
        guard let compatibility = admission.claimInitializationCompatibility(
            successorInitialization, proof: successorProof,
            predecessorInitialization: predecessorInitialization,
            predecessorProof: predecessorProof,
            canonicalInitialization: canonical.object,
            canonicalProof: canonicalProof,
            relay: relay, terminalBinding: terminalBinding,
            renditionBinding: renditionBinding),
              compatibility.predecessorProofIdentity == predecessorProof.identity,
              compatibility.authorizes(canonicalInitialization: canonical.object,
                  canonicalProof: canonicalProof, successorProof: successorProof) else { return false }
        aacWriterInitializationAliases[id] = .init(
            canonicalKey: canonicalKey, compatibility: compatibility)
        return true
    } }

    func advanceWriterWindowInitialization(
        canonicalKey: HLSResourceKey,
        predecessorInitialization: SealedMediaObject,
        predecessorProof: EpochFormatProof,
        successorInitialization: SealedMediaObject,
        successorProof: EpochFormatProof,
        admission: WriterWindowAdmission,
        relay: SegmentReportRelay
    ) -> Bool { domain.sync {
        let id = successorProof.binding.publicationParticipantID.rawValue
        guard !closed, !retiredParticipants.contains(id),
              canonicalKey.participantID == id,
              let canonical = resources[canonicalKey],
              canonical.object.kind == .initialization else { return false }
        let canonicalProof = canonical.proof
        if let previousAlias = writerInitializationAliases[id] {
            guard previousAlias.canonicalKey == canonicalKey,
                  previousAlias.compatibility.successorProofIdentity
                    == predecessorProof.identity else { return false }
        } else {
            guard canonicalProof == predecessorProof else { return false }
        }
        guard let compatibility = admission.claimInitializationCompatibility(
            successorInitialization,
            successorProof: successorProof,
            predecessorInitialization: predecessorInitialization,
            predecessorProof: predecessorProof,
            canonicalInitialization: canonical.object,
            canonicalProof: canonicalProof,
            relay: relay),
              compatibility.predecessorProofIdentity == predecessorProof.identity,
              compatibility.authorizes(
                canonicalInitialization: canonical.object,
                canonicalProof: canonicalProof,
                successorProof: successorProof) else { return false }
        writerInitializationAliases[id] = .init(
            canonicalKey: canonicalKey, compatibility: compatibility)
        return true
    } }

    func attachAACPublicationAdmission(_ admission: AACPublicationLeafAdmission,
                                       to key: HLSResourceKey) throws {
        try domain.sync {
            guard let resource = resources[key],
                  resource.object.aacMediaMembershipLeaf == admission.leaf,
                  resource.aacPublicationAdmission == nil else {
                throw HLSPublicationFailure.identityMismatch
            }
            resources[key]?.aacPublicationAdmission = admission
        }
    }

    func admitInitializations(_ authority: HLSPublicationCoordinator.InitializationAuthority,
                              reservations batch: [SealedMediaReservation]) throws -> [HLSResourceKey] {
        try domain.sync { try authority.consume(store: self) { inputs, value, previous, next, declarations in
            guard !closed, owner === value, expectedTicket == previous, inputs.count == batch.count,
                  (1...4).contains(inputs.count), next.publicationSequence == currentVersion,
                  Set(next.participantVector.map(\.participantID)) == Set(declarations.keys),
                  next.participantVector.count == inputs.count,
                  next.participantVector.allSatisfy({ $0.expectedPreviousSnapshotVersion == currentVersion }) else {
                throw HLSPublicationFailure.identityMismatch
            }
            var keys: [HLSResourceKey] = []
            for (input, reservation) in zip(inputs, batch) {
                let object = input.initialization
                let key = HLSResourceKey(object)
                guard reservations[reservation.identity] == reservation, reservation.storeIdentity == identity,
                      reservation.kind == .initialization, reservation.binding == object.binding,
                      reservation.bytes == object.bytes.count, !retiredParticipants.contains(key.participantID),
                      resources[key] == nil, !keys.contains(key),
                      input.proof.matches(initialization: object),
                      let entry = next.participantVector.first(where: { $0.participantID == key.participantID }),
                      entry.binding == input.proof.binding, entry.proofIdentity == input.proof.identity,
                      declarations[key.participantID] == entry.declaration,
                      entry.candidateTicket == input.candidateTicket else { throw HLSPublicationFailure.identityMismatch }
                if let candidate = input.candidate {
                    guard acceptsCandidate(candidate, proof: input.proof), candidate.declaration == entry.declaration else {
                        throw HLSPublicationFailure.identityMismatch
                    }
                }
                _ = try FinalFMP4Validator.validateObject(object, kind: .initialization, binding: input.proof.binding)
                keys.append(key)
            }
            var prepared: [HLSResourceKey: Resource] = [:]
            for (index, input) in inputs.enumerated() {
                prepared[keys[index]] = try makeResource(object: input.initialization,
                    proof: input.proof, receipt: nil)
            }
            let unchargedRetrofits = try prepareRetrofits(initializations: prepared)
            var chargedPrepared: [HLSResourceKey: Resource] = [:]
            var chargedRetrofits: [HLSResourceKey: Resource] = [:]
            do {
                for (key, resource) in prepared {
                    chargedPrepared[key] = try registerApplicationCharges(for: resource)
                }
                chargedRetrofits = try registerRetrofitMapCharges(unchargedRetrofits)
                try SegmentReportRelay.transferBatchToStore(inputs.map { ($0.relay, $0.initialization) }) {
                    for (index, input) in inputs.enumerated() {
                        resources[keys[index]] = chargedPrepared[keys[index]]
                        reservations.removeValue(forKey: batch[index].identity)
                        if let candidate = input.candidate { candidates[keys[index].participantID] = candidate }
                    }
                    for (mediaKey, resource) in chargedRetrofits { resources[mediaKey] = resource }
                    expectedTicket = next
                    for (id, declaration) in declarations { uriDeclarations[id] = declaration }
                    cancelCapacityWait(owner: value)
                }
            } catch {
                for resource in chargedPrepared.values { releaseApplicationCharges(resource) }
                for resource in chargedRetrofits.values { releaseMapApplicationCharge(resource) }
                throw error
            }
            return keys
        } }
    }

    private func makeResource(object: SealedMediaObject, proof: EpochFormatProof,
                              receipt: SegmentValidationReceipt?) throws -> Resource {
        let rendition = proof.binding.renditionIdentity
        if object.kind == .initialization {
            let evidence = CompletedInitBodyEvidenceState(itemGeneration: object.binding.itemGeneration.rawValue,
                renditionIdentity: rendition, mediaEpoch: object.binding.mediaEpoch.rawValue,
                resourceIdentity: object.backing.identity, sealedDigest: object.digest,
                sealedBodyLength: object.bytes.count)
            return Resource(object: object, proof: proof, receipt: nil,
                            evidence: evidence, decodeMap: nil)
        }
        guard let receipt else {
            throw HLSPublicationFailure.identityMismatch
        }
        let evidence = CompletedMediaBodyEvidenceState(itemGeneration: object.binding.itemGeneration.rawValue,
            renditionIdentity: rendition, mediaEpoch: object.binding.mediaEpoch.rawValue,
            resourceIdentity: object.backing.identity, sealedDigest: object.digest,
            sealedBodyLength: object.bytes.count)
        if let initialization = resources.values.first(where: {
            $0.object.kind == .initialization && $0.proof == proof
        }), let initEvidence = initialization.evidence as? CompletedInitBodyEvidenceState {
            let map = try SealedDecodeCoverageMap.seal(media: object, proof: proof, receipt: receipt,
                initialization: initialization.object, evidence: evidence,
                initializationEvidence: initEvidence)
            guard map.applicationChargeableBytes + 4_096 <= 32 * 1_024 else {
                throw HLSPublicationFailure.capacityExceeded
            }
            return Resource(object: object, proof: proof, receipt: receipt,
                            evidence: evidence, decodeMap: map)
        }
        let participantID = object.binding.publicationParticipantID.rawValue
        if let alias = writerInitializationAliases[participantID],
           alias.compatibility.successorProofIdentity == proof.identity,
           let initialization = resources[alias.canonicalKey],
           let initEvidence = initialization.evidence as? CompletedInitBodyEvidenceState {
            let map = try SealedDecodeCoverageMap.sealWriterWindow(
                media: object, proof: proof, receipt: receipt,
                canonicalInitialization: initialization.object,
                canonicalProof: initialization.proof,
                compatibility: alias.compatibility,
                evidence: evidence, initializationEvidence: initEvidence)
            guard map.applicationChargeableBytes + 4_096 <= 32 * 1_024 else {
                throw HLSPublicationFailure.capacityExceeded
            }
            return Resource(object: object, proof: proof, receipt: receipt,
                            evidence: evidence, decodeMap: map)
        }
        guard let alias = aacWriterInitializationAliases[participantID],
              alias.compatibility.successorProofIdentity == proof.identity,
              let initialization = resources[alias.canonicalKey],
              let initEvidence = initialization.evidence as? CompletedInitBodyEvidenceState else {
            // Task 19 允许仅封存、尚未发布的媒体先进入 store；没有匹配 init 或
            // 当前 writer alias 时不能签发 coverage map。
            return Resource(object: object, proof: proof, receipt: receipt,
                            evidence: evidence, decodeMap: nil)
        }
        let map = try SealedDecodeCoverageMap.sealAACWriterWindow(
            media: object, proof: proof, receipt: receipt,
            canonicalInitialization: initialization.object,
            canonicalProof: initialization.proof,
            compatibility: alias.compatibility,
            evidence: evidence, initializationEvidence: initEvidence)
        guard map.applicationChargeableBytes + 4_096 <= 32 * 1_024 else {
            throw HLSPublicationFailure.capacityExceeded
        }
        return Resource(object: object, proof: proof, receipt: receipt,
                        evidence: evidence, decodeMap: map)
    }

    /// 单对象 admit 与 initialization batch 共用同一封闭准备阶段：先 seal 全部 map，
    /// 再逐对象复验 32 KiB，最后按完整 batch delta 复验 688 MiB（或注入的测试 hard limit）。
    private func prepareRetrofits(
        initializations: [HLSResourceKey: Resource]
    ) throws -> [HLSResourceKey: Resource] {
        guard !initializations.isEmpty else { return [:] }
        var retrofits: [HLSResourceKey: Resource] = [:]
        var charges: [SealedMediaRetrofitCharge] = []
        for (initKey, initialization) in initializations {
            guard let initEvidence = initialization.evidence as? CompletedInitBodyEvidenceState else {
                throw HLSPublicationFailure.identityMismatch
            }
            for (mediaKey, pending) in resources where pending.object.kind == .media
                && pending.proof == initialization.proof && pending.decodeMap == nil {
                guard retrofits[mediaKey] == nil,
                      let mediaEvidence = pending.evidence as? CompletedMediaBodyEvidenceState,
                      let mediaReceipt = pending.receipt else {
                    throw HLSPublicationFailure.identityMismatch
                }
                let map = try SealedDecodeCoverageMap.seal(media: pending.object,
                    proof: pending.proof, receipt: mediaReceipt,
                    initialization: initialization.object, evidence: mediaEvidence,
                    initializationEvidence: initEvidence)
                charges.append(.init(existingMapBytes: pending.decodeMap?.applicationChargeableBytes ?? 0,
                                     replacementMapBytes: map.applicationChargeableBytes))
                retrofits[mediaKey] = Resource(object: pending.object, proof: pending.proof,
                    receipt: pending.receipt, evidence: pending.evidence, decodeMap: map,
                    aacPublicationAdmission: pending.aacPublicationAdmission,
                    visible: pending.visible, unpublished: pending.unpublished,
                    everPublished: pending.everPublished, metadataBits: pending.metadataBits,
                    removedAt: pending.removedAt,
                    lastSnapshotCompletion: pending.lastSnapshotCompletion,
                    longestPlaylistDuration: pending.longestPlaylistDuration,
                    snapshotReferences: pending.snapshotReferences,
                    responseReferences: pending.responseReferences,
                    initializationKey: initKey,
                    backingApplicationReservation: pending.backingApplicationReservation,
                    evidenceApplicationReservation: pending.evidenceApplicationReservation,
                    mapApplicationReservation: pending.mapApplicationReservation)
            }
        }
        let current = resources.values.reduce(0) { $0 + $1.applicationChargeableBytes }
        let reserved = reservations.values.reduce(0) { $0 + $1.bytes + $1.reservationOverheadBytes }
        _ = try SealedMediaStoreCapacityProjection.project(
            currentChargeableBytes: current, reservedChargeableBytes: reserved,
            retrofits: charges, hardApplicationBytes: capacityLimits.hardApplicationBytes)
        return retrofits
    }

    /// store 接管 sealed object 时登记 body/evidence/map；backing identity 与 HTTP 共用，跨层引用只计一次。
    private func registerApplicationCharges(for uncharged: Resource) throws -> Resource {
        var resource = uncharged
        do {
            resource.backingApplicationReservation = try reserveApplicationCharge(
                allocationIdentity: resource.object.backing.identity.rawValue,
                bytes: resource.object.backing.bytes.count)
            resource.evidenceApplicationReservation = try reserveApplicationCharge(
                allocationIdentity: UUID(),
                bytes: resource.object.kind == .initialization
                    ? LoopbackStorageLayout.current.initEvidenceAllocationBytes : 4_096)
            if let map = resource.decodeMap {
                resource.mapApplicationReservation = try reserveApplicationCharge(
                    allocationIdentity: UUID(), bytes: map.applicationChargeableBytes)
            }
            return resource
        } catch {
            releaseApplicationCharges(resource)
            throw error
        }
    }

    private func registerRetrofitMapCharges(
        _ uncharged: [HLSResourceKey: Resource]
    ) throws -> [HLSResourceKey: Resource] {
        var charged: [HLSResourceKey: Resource] = [:]
        do {
            for (key, value) in uncharged {
                var resource = value
                guard let map = resource.decodeMap else {
                    throw HLSPublicationFailure.identityMismatch
                }
                resource.mapApplicationReservation = try reserveApplicationCharge(
                    allocationIdentity: UUID(), bytes: map.applicationChargeableBytes)
                charged[key] = resource
            }
            return charged
        } catch {
            for resource in charged.values { releaseMapApplicationCharge(resource) }
            throw error
        }
    }

    private func releaseMapApplicationCharge(_ resource: Resource) {
        if let reservation = resource.mapApplicationReservation {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
    }

    private func reserveApplicationCharge(allocationIdentity: UUID, bytes: Int) throws
        -> PlaybackApplicationChargeReservation {
        do {
            return try HLSDeliveryApplicationChargeLedger.shared.reserve(
                allocationIdentity: allocationIdentity, bytes: bytes)
        } catch let error as LoopbackHTTPReservationError {
            switch error {
            case .backpressure, .hardCapacityExceeded:
                throw HLSPublicationFailure.capacityExceeded
            }
        }
    }

    private func releaseApplicationCharges(_ resource: Resource) {
        if let reservation = resource.mapApplicationReservation {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
        if let reservation = resource.evidenceApplicationReservation {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
        if let reservation = resource.backingApplicationReservation {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
    }

    func lookup(_ key: HLSResourceKey, token: String, now: Int64) -> HLSResourceAvailability { domain.sync {
        advance(now)
        guard token == self.token, authentic(key) else { return .notFound }
        guard let resource = resources[key] else { return authentic(key) ? .gone : .notFound }
        guard resource.everPublished else { return .notFound }
        guard !closed else { return .gone }
        if resource.visible || resource.snapshotReferences > 0 { return .available }
        if key.kind == .initialization {
            let protected = resources.values.contains { media in
                guard media.initializationKey == key else { return false }
                return media.visible || media.unpublished || media.snapshotReferences > 0
                    || media.horizon().map({ instant < $0 }) == true
            }
            return protected ? .available : .gone
        }
        if let horizon = resource.horizon(), instant >= horizon { return .gone }
        return .available
    } }

    func acquireResponse(_ key: HLSResourceKey, token: String, now: Int64, range: Range<Int>? = nil) throws -> HLSMediaResponseLease? {
        try domain.sync {
            guard lookup(key, token: token, now: now) == .available, var resource = resources[key] else { return nil }
            let range = range ?? 0..<resource.object.backing.bytes.count
            guard range.lowerBound >= 0, range.upperBound <= resource.object.backing.bytes.count, !range.isEmpty else {
                throw HLSPublicationFailure.invalidSequence
            }
            if resource.responseReferences == 0 {
                let state = usage
                guard state.distinctResponseBackings < 8,
                      try HLSChecked.add(state.responseBackingBytes, resource.object.backing.bytes.count) <= 128 * 1_048_576 else {
                    throw HLSPublicationFailure.capacityExceeded
                }
            }
            guard mediaLeases.count < 16 else { throw HLSPublicationFailure.capacityExceeded }
            let lease = HLSMediaResponseLease(storeIdentity: identity, key: key, backing: resource.object.backing, range: range, domain: domain)
            resource.responseReferences += 1
            resources[key] = resource
            mediaLeases[lease.identity] = lease
            return lease
        }
    }
    /// 同一域原子消费真实 send-terminal capability 与仍由本 store 持有的 lease。
    func complete(_ lease: HLSMediaResponseLease,
                  terminal: HLSResponseSendTerminalCapability,
                  now: Int64) throws { try domain.sync {
        guard lease.storeIdentity == identity,
              terminal.consume(matching: lease),
              mediaLeases.removeValue(forKey: lease.identity) != nil,
              let state = resources[lease.key]?.evidence else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        defer {
            resources[lease.key]?.responseReferences -= 1
            lease.backing = nil
            advance(now)
            evict()
        }
        try state.joinCompletedLease(lease)
    } }

    func release(_ lease: HLSMediaResponseLease, now: Int64) { domain.sync {
        guard lease.storeIdentity == identity, mediaLeases.removeValue(forKey: lease.identity) != nil else { return }
        resources[lease.key]?.responseReferences -= 1
        lease.backing = nil
        advance(now)
        evict()
    } }

    func acquireSnapshot(participantID: UInt64, now: Int64) throws -> HLSPlaylistResponseLease? { try domain.sync {
        advance(now)
        guard let id = currentSnapshots[participantID] else { return nil }
        return try acquirePlaylist(id, publicationVersion: nil)
    } }
    func acquireMasterSnapshot(now: Int64) throws -> HLSPlaylistResponseLease? { try domain.sync {
        advance(now)
        guard let id = masterIdentity else { return nil }
        return try acquirePlaylist(id, publicationVersion: currentVersion)
    } }
    private func acquirePlaylist(_ id: UUID,
                                 publicationVersion: UInt64?) throws
        -> HLSPlaylistResponseLease? {
        guard !closed, var entry = snapshots[id], entry.current else { return nil }
        guard snapshotLeases.count < 16 else { throw HLSPublicationFailure.capacityExceeded }
        let lease = HLSPlaylistResponseLease(storeIdentity: identity,
            snapshot: entry.snapshot,
            publicationVersion: publicationVersion ?? entry.snapshot.version,
            domain: domain)
        entry.leases += 1
        snapshots[id] = entry
        snapshotLeases[lease.identity] = lease
        return lease
    }
    func release(_ lease: HLSPlaylistResponseLease, completedAt: Int64?, now: Int64) { domain.sync {
        guard lease.storeIdentity == identity, snapshotLeases.removeValue(forKey: lease.identity) != nil,
              var entry = snapshots[lease.snapshotIdentity] else { return }
        if let completedAt {
            for key in entry.snapshot.resources {
                let completion = max(resources[key]?.lastSnapshotCompletion ?? completedAt, completedAt)
                resources[key]?.lastSnapshotCompletion = completion
            }
        }
        entry.leases -= 1
        snapshots[entry.snapshot.identity] = entry
        lease.storage = nil
        if !entry.current && entry.leases == 0 { removeSnapshot(entry.snapshot.identity) }
        if entry.leases == 0 { pendingSnapshotGeneration.remove(entry.snapshot.identity) }
        advance(now)
        evict()
        wakeCapacityWaiter()
    } }

    private func wakeCapacityWaiter() {
        guard let waiter = capacityWaiter else { return }
        if closed || expectedTicket != waiter.ticket || waiter.ticket.absoluteDeadline.map({ instant > $0 }) == true {
            capacityWaiter = nil; pendingSnapshotGeneration.removeAll(keepingCapacity: true); return
        }
        guard pendingSnapshotGeneration.isEmpty else { return }
        capacityWaiter = nil
        waiter.wake(instant)
    }

    func reserveSnapshotBatch(mediaCount: Int, includeMaster: Bool) throws -> HLSSnapshotBatchReservation? { try domain.sync {
        guard !closed else { throw HLSPublicationFailure.closed }
        guard (1...4).contains(mediaCount) else { throw HLSPublicationFailure.capacityExceeded }
        guard snapshotReservation == nil else { return nil }
        pendingSnapshotGeneration = pendingSnapshotGeneration.filter { snapshots[$0] != nil }
        guard pendingSnapshotGeneration.isEmpty else { return nil }
        let bytes = try HLSChecked.add(HLSChecked.multiply(mediaCount, 532_480), includeMaster ? 135_168 : 0)
        let count = mediaCount + (includeMaster ? 1 : 0)
        let state = usage
        if state.snapshotCount + count > 9 || state.snapshotBytes + bytes > 5 * 1_048_576 {
            pendingSnapshotGeneration = Set(snapshots.filter { !$0.value.current && $0.value.leases > 0 }.keys)
            return nil
        }
        let reservation = HLSSnapshotBatchReservation(identity: UUID(), storeIdentity: identity,
            mediaCount: mediaCount, includeMaster: includeMaster, bytes: bytes)
        snapshotReservation = reservation
        return reservation
    } }
    func cancel(_ reservation: HLSSnapshotBatchReservation) { domain.sync {
        if snapshotReservation == reservation { snapshotReservation = nil }
    } }

    /// 只有 coordinator 在完整向量 CAS 成功后能签发此能力；普通 caller 不能自行公开资源。
    func commit(_ authority: HLSPublicationCoordinator.CommitAuthority) throws { try domain.sync {
        try authority.consume(store: self) { owner, ticket, reservation, media, master, records, now in
            try validatePublication(ticket, owner: owner)
            let newVersion = try HLSChecked.increment(currentVersion)
            guard !closed, snapshotReservation == reservation,
                  media.count == reservation.mediaCount,
                  Set(media.keys) == Set(ticket.participantVector.map(\.participantID)), Set(records.keys) == Set(media.keys),
                  media.values.allSatisfy({ $0.version == newVersion }),
                  (master != nil) == reservation.includeMaster else { throw HLSPublicationFailure.staleTicket }
            let newBytes = media.values.reduce(0) { $0 + $1.representation.residentBytes } + (master?.residentBytes ?? 0)
            guard newBytes <= reservation.bytes else { throw HLSPublicationFailure.capacityExceeded }
            for segments in records.values { for segment in segments {
                guard let owned = resources[segment.key], let map = owned.decodeMap,
                      let initialization = resources[segment.initializationKey],
                      map.authorizesPublication(media: owned.object,
                          proof: segment.proof, receipt: segment.receipt,
                          initialization: initialization.object,
                          mediaEvidence: owned.evidence,
                          initializationEvidence: initialization.evidence) else {
                    throw HLSPublicationFailure.identityMismatch
                }
            } }
            var durations: [UInt64: Int64] = [:]
            for (id, segments) in records {
                durations[id] = try segments.reduce(Int64(0)) { try HLSChecked.add($0, HLSChecked.nanoseconds($1.receipt.presentationRange.duration)) }
            }
            let nextKeys = Set(records.values.flatMap { $0.map(\.key) })
            for key in Array(resources.keys) where resources[key]!.visible && key.kind == .media && !nextKeys.contains(key) {
                resources[key]!.visible = false
                resources[key]!.removedAt = now
            }
            for (id, segments) in records { for segment in segments {
                resources[segment.key]!.visible = true
                resources[segment.key]!.unpublished = false
                resources[segment.key]!.everPublished = true
                resources[segment.key]!.initializationKey = segment.initializationKey
                let longest = max(resources[segment.key]!.longestPlaylistDuration, durations[id]!)
                resources[segment.key]!.longestPlaylistDuration = longest
                resources[segment.initializationKey]!.unpublished = false
                resources[segment.initializationKey]!.everPublished = true
            } }
            for oldID in currentSnapshots.values {
                snapshots[oldID]?.current = false
                if snapshots[oldID]?.leases == 0 { removeSnapshot(oldID) }
            }
            currentSnapshots.removeAll(keepingCapacity: true)
            for (participant, snapshot) in media {
                snapshots[snapshot.identity] = SnapshotEntry(snapshot: snapshot, current: true)
                currentSnapshots[participant] = snapshot.identity
                for key in snapshot.resources + snapshot.initializationResources { resources[key]?.snapshotReferences += 1 }
            }
            if let master {
                let snapshot = HLSPlaylistSnapshot(identity: UUID(), version: 0, representation: master,
                    logicalSequences: [], resources: [], initializationResources: [],
                    bandwidth: .init(peak: 0, average: 0), effectivePlaybackHorizon: nil)
                masterIdentity = snapshot.identity
                snapshots[snapshot.identity] = SnapshotEntry(snapshot: snapshot, current: true)
            }
            snapshotReservation = nil
            currentVersion = newVersion
            advance(now)
            evict()
        }
    } }

    func sweep(now: Int64) { domain.sync { advance(now); evict() } }
    func retireParticipants(_ ids: Set<UInt64>) { domain.sync {
        retiredParticipants.formUnion(ids)
        for id in ids {
            aacWriterInitializationAliases.removeValue(forKey: id)
            writerInitializationAliases.removeValue(forKey: id)
        }
        for key in Array(resources.keys) where ids.contains(key.participantID) {
            resources[key]?.visible = false
            resources[key]?.unpublished = false
            resources[key]?.removedAt = instant
        }
        for id in ids {
            if let snapshotID = currentSnapshots.removeValue(forKey: id) {
                snapshots[snapshotID]?.current = false
                if snapshots[snapshotID]?.leases == 0 { removeSnapshot(snapshotID) }
            }
        }
        snapshotReservation = nil
        capacityWaiter = nil
        pendingSnapshotGeneration.removeAll(keepingCapacity: true)
        evict()
    } }
    func close() { domain.sync {
        guard !closed else { return }
        closed = true
        snapshotReservation = nil
        capacityWaiter = nil
        pendingSnapshotGeneration.removeAll(keepingCapacity: true)
        expectedTicket = nil
        aacWriterInitializationAliases.removeAll(keepingCapacity: true)
        writerInitializationAliases.removeAll(keepingCapacity: true)
        for reservation in coverageReservations.values {
            HLSDeliveryApplicationChargeLedger.shared.release(reservation)
        }
        coverageReservations.removeAll(keepingCapacity: true)
        coverageRequests.removeAll(keepingCapacity: true)
        reservations.removeAll(keepingCapacity: true)
        currentSnapshots.removeAll(keepingCapacity: true)
        for id in Array(snapshots.keys) {
            snapshots[id]?.current = false
            if snapshots[id]?.leases == 0 { removeSnapshot(id) }
        }
        for key in Array(resources.keys) { resources[key]?.visible = false; resources[key]?.unpublished = false }
        evict()
    } }
    private func advance(_ now: Int64) { instant = max(instant, now) }
    private func removeSnapshot(_ id: UUID) {
        guard let entry = snapshots.removeValue(forKey: id) else { return }
        for key in entry.snapshot.resources + entry.snapshot.initializationResources { resources[key]?.snapshotReferences -= 1 }
    }
    private func evict() {
        let mediaKeys = resources.keys.filter { $0.kind == .media }.sorted { $0.logicalSequence < $1.logicalSequence }
        for key in mediaKeys {
            guard let resource = resources[key], !resource.visible, !resource.unpublished,
                  resource.snapshotReferences == 0, resource.responseReferences == 0,
                  resource.preparationPins == 0,
                  resource.preparationHistoryPins == 0,
                  closed || resource.horizon().map({ instant >= $0 }) == true else { continue }
            resources[key]?.evidence.retire()
            releaseApplicationCharges(resource)
            resources.removeValue(forKey: key)
        }
        for key in Array(resources.keys) where key.kind == .initialization {
            guard let resource = resources[key], !resource.unpublished, resource.snapshotReferences == 0,
                  resource.responseReferences == 0, resource.preparationPins == 0,
                  resource.preparationHistoryPins == 0,
                  !resources.values.contains(where: { $0.initializationKey == key }) else { continue }
            resources[key]?.evidence.retire()
            releaseApplicationCharges(resource)
            resources.removeValue(forKey: key)
        }
    }
}
