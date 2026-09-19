// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Darwin
import Foundation
import ObjectiveC

enum AudioServiceRegistryCapacity {
    static let admittedProofs = 16
    static let audioAccessUnits = CompressedAudioRetentionPolicy.pendingHardCount
    static let compressedWriterInputs = SegmentedFMP4WriterOwnershipLimits.standard.hardCapacity
    static let maximumCompressedConstituents = 6
    /// 16 个尚未转交的 active/decoder tail，加上一个媒体 owner 的 AU 与
    /// 单个当前物理 writer hard envelope；EAC3 sibling 逐 proof 索引。
    static let authoritativeAdmittedProofs = admittedProofs
        + (audioAccessUnits + compressedWriterInputs) * maximumCompressedConstituents
    static let branchGates = 16
    static let branchPlansPerProof = 16
    static let pcmSubscriptionGates = 16
    static let pcmBundles = 16
    static var authoritativeAdmittedProofIndexChargeBytes: Int {
        AudioServiceLeaseState.maximumRetainedStructureChargeBytes
    }
}

enum AudioServiceRetainedStructureCharge {
    static func checkedTotal(
        indexSlotCount: Int,
        indexSlotStride: Int,
        indexObjectBytes: Int,
        escrowObjectBytes: Int,
        lockObjectBytes: Int,
        reservationObjectBytes: Int,
        proofCount: Int,
        proofGraphBytes: Int
    ) -> Int? {
        let values = [indexSlotCount, indexSlotStride, indexObjectBytes,
                      escrowObjectBytes, lockObjectBytes, reservationObjectBytes,
                      proofCount, proofGraphBytes]
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        let slotProduct = indexSlotCount.multipliedReportingOverflow(by: indexSlotStride)
        let proofProduct = proofCount.multipliedReportingOverflow(by: proofGraphBytes)
        guard !slotProduct.overflow, !proofProduct.overflow else { return nil }
        var total = malloc_good_size(slotProduct.partialValue)
        for value in [indexObjectBytes, escrowObjectBytes, lockObjectBytes,
                      reservationObjectBytes, proofProduct.partialValue] {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}

final class AudioServiceApplicationEscrow: @unchecked Sendable {
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let reservation: PlaybackApplicationChargeReservation
    private let lock = NSLock()
    private var availableCredits: Int
    private init(ledger: HLSDeliveryApplicationChargeLedger,
                 reservation: PlaybackApplicationChargeReservation,
                 credits: Int) {
        self.ledger = ledger; self.reservation = reservation
        availableCredits = credits
    }
    static func reserve(bytes: Int, credits: Int,
                        ledger: HLSDeliveryApplicationChargeLedger)
        -> AudioServiceApplicationEscrow? {
        guard let reservation = try? ledger.reserve(
            allocationIdentity: UUID(), bytes: bytes) else { return nil }
        return AudioServiceApplicationEscrow(
            ledger: ledger, reservation: reservation, credits: credits)
    }
    var hasAvailableCredit: Bool { lock.withLock { availableCredits > 0 } }
    func claimCredit() -> Bool { lock.withLock {
        guard availableCredits > 0 else { return false }
        availableCredits -= 1
        return true
    } }
    func releaseCredit() { lock.withLock {
        precondition(availableCredits < AudioServiceRegistryCapacity.authoritativeAdmittedProofs)
        availableCredits += 1
    } }
    deinit { ledger.release(reservation) }
}

/// 唯一 authoritative proof 索引；固定 backing 一次分配，不随 AU append 扩容。
private final class AudioServiceAdmittedProofIndex: @unchecked Sendable {
    private let applicationEscrow: AudioServiceApplicationEscrow
    private let slots: UnsafeMutablePointer<AdmittedAudioServiceInputUnitProof?>
    private var occupiedCount = 0
    fileprivate init(applicationEscrow: AudioServiceApplicationEscrow) {
        self.applicationEscrow = applicationEscrow
        slots = .allocate(capacity: AudioServiceRegistryCapacity.authoritativeAdmittedProofs)
        slots.initialize(repeating: nil,
                         count: AudioServiceRegistryCapacity.authoritativeAdmittedProofs)
    }
    deinit {
        slots.deinitialize(count: AudioServiceRegistryCapacity.authoritativeAdmittedProofs)
        slots.deallocate()
    }
    var count: Int { occupiedCount }
    var hasSpace: Bool {
        occupiedCount < AudioServiceRegistryCapacity.authoritativeAdmittedProofs
    }
    func first(where predicate: (AdmittedAudioServiceInputUnitProof) -> Bool)
        -> AdmittedAudioServiceInputUnitProof? {
        for index in 0..<AudioServiceRegistryCapacity.authoritativeAdmittedProofs {
            if let value = slots[index], predicate(value) { return value }
        }
        return nil
    }
    func forEach(_ body: (AdmittedAudioServiceInputUnitProof) -> Void) {
        for index in 0..<AudioServiceRegistryCapacity.authoritativeAdmittedProofs {
            if let value = slots[index] { body(value) }
        }
    }
    func count(where predicate: (AdmittedAudioServiceInputUnitProof) -> Bool) -> Int {
        var result = 0
        forEach { if predicate($0) { result += 1 } }
        return result
    }
    func insert(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        for index in 0..<AudioServiceRegistryCapacity.authoritativeAdmittedProofs
            where slots[index] == nil {
            slots[index] = proof
            occupiedCount += 1
            return true
        }
        return false
    }
    @discardableResult
    func remove(where predicate: (AdmittedAudioServiceInputUnitProof) -> Bool)
        -> AdmittedAudioServiceInputUnitProof? {
        for index in 0..<AudioServiceRegistryCapacity.authoritativeAdmittedProofs {
            guard let value = slots[index], predicate(value) else { continue }
            slots[index] = nil
            occupiedCount -= 1
            return value
        }
        return nil
    }
}

struct AudioServiceRegistryUsage: Sendable, Equatable {
    let admittedProofs: Int
    let branchGates: Int
    let pcmSubscriptionGates: Int
    let pcmBundles: Int
}

/// 固定十六槽引用容器；槽退休后复用，不形成按AU增长的第二份ledger。
struct AudioServiceFixedReferenceSlots<Element: AnyObject> {
    private var slot0: Element?
    private var slot1: Element?
    private var slot2: Element?
    private var slot3: Element?
    private var slot4: Element?
    private var slot5: Element?
    private var slot6: Element?
    private var slot7: Element?
    private var slot8: Element?
    private var slot9: Element?
    private var slot10: Element?
    private var slot11: Element?
    private var slot12: Element?
    private var slot13: Element?
    private var slot14: Element?
    private var slot15: Element?

    static var capacity: Int { 16 }
    var count: Int {
        var result = 0
        for index in 0..<Self.capacity where self[index] != nil { result += 1 }
        return result
    }
    var hasSpace: Bool { count < Self.capacity }

    mutating func insert(_ element: Element) -> Bool {
        for index in 0..<Self.capacity where self[index] == nil {
            self[index] = element
            return true
        }
        return false
    }

    func first(where predicate: (Element) -> Bool) -> Element? {
        for index in 0..<Self.capacity {
            if let element = self[index], predicate(element) { return element }
        }
        return nil
    }

    func forEach(_ body: (Element) -> Void) {
        for index in 0..<Self.capacity {
            if let element = self[index] { body(element) }
        }
    }

    @discardableResult
    mutating func remove(where predicate: (Element) -> Bool) -> Element? {
        for index in 0..<Self.capacity {
            if let element = self[index], predicate(element) {
                self[index] = nil
                return element
            }
        }
        return nil
    }

    private subscript(index: Int) -> Element? {
        get {
            switch index {
            case 0: slot0
            case 1: slot1
            case 2: slot2
            case 3: slot3
            case 4: slot4
            case 5: slot5
            case 6: slot6
            case 7: slot7
            case 8: slot8
            case 9: slot9
            case 10: slot10
            case 11: slot11
            case 12: slot12
            case 13: slot13
            case 14: slot14
            case 15: slot15
            default: nil
            }
        }
        set {
            switch index {
            case 0: slot0 = newValue
            case 1: slot1 = newValue
            case 2: slot2 = newValue
            case 3: slot3 = newValue
            case 4: slot4 = newValue
            case 5: slot5 = newValue
            case 6: slot6 = newValue
            case 7: slot7 = newValue
            case 8: slot8 = newValue
            case 9: slot9 = newValue
            case 10: slot10 = newValue
            case 11: slot11 = newValue
            case 12: slot12 = newValue
            case 13: slot13 = newValue
            case 14: slot14 = newValue
            case 15: slot15 = newValue
            default: preconditionFailure("固定槽索引越界")
            }
        }
    }
}

struct AudioItemGenerationIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct AudioMediaEpochIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct AudioPublicationParticipantIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct AudioRenditionIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct AudioSelectionTransactionIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct AudioCandidateTicket: Sendable, Hashable { let rawValue: UInt64 }

struct SharedDecoderAdmissionIdentity: Sendable, Hashable {
    let sourceTrackIdentity: AudioSourceTrackIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let decoderLifecycleGeneration: UInt64
    let decoderAdmissionFenceRevision: UInt64
}

enum CompressedAudioBranchOwnerIdentity: Sendable, Hashable {
    case audioVideo(
        outputLifecycleEpoch: OutputLifecycleEpoch,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        publicationParticipantID: AudioPublicationParticipantIdentity,
        renditionIdentity: AudioRenditionIdentity
    )
    case audioOnly(
        outputLifecycleEpoch: OutputLifecycleEpoch,
        selectionTransactionIdentity: AudioSelectionTransactionIdentity,
        candidateTicket: AudioCandidateTicket,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        publicationParticipantID: AudioPublicationParticipantIdentity,
        renditionIdentity: AudioRenditionIdentity
    )
}

enum AudioBranchAdmissionIdentity: Sendable, Hashable {
    case decoder(SharedDecoderAdmissionIdentity)
    case directCompressed(
        CompressedAudioBranchOwnerIdentity,
        branchGeneration: UInt64,
        admissionFenceRevision: UInt64
    )
    case eac3Aggregation(
        CompressedAudioBranchOwnerIdentity,
        branchGeneration: UInt64,
        admissionFenceRevision: UInt64
    )
}

/// AudioService 先把完整输出候选冻结成一次性、不可由调用方改写的绑定。
final class CompressedAudioOutputPlanBinding: @unchecked Sendable, Hashable {
    fileprivate weak var targetCoordinator: AudioServiceSemanticCoordinator?
    fileprivate weak var targetIssuer: AudioServiceLeaseState?
    let sharedControlExecutor: PlaybackControlExecutor
    let admissionIdentity: AudioBranchAdmissionIdentity
    let ownerIdentity: CompressedAudioBranchOwnerIdentity
    let itemGeneration: AudioItemGenerationIdentity
    let mediaEpoch: AudioMediaEpochIdentity
    let sourceTrackIdentity: AudioSourceTrackIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let codec: AudioCodec
    let sourceStreamIndex: Int32
    let sourceSampleRate: Int32
    private var timelineIssuer: AnyObject?

    fileprivate init(
        targetCoordinator: AudioServiceSemanticCoordinator,
        targetIssuer: AudioServiceLeaseState,
        sharedControlExecutor: PlaybackControlExecutor,
        admissionIdentity: AudioBranchAdmissionIdentity,
        ownerIdentity: CompressedAudioBranchOwnerIdentity,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        sourceTrackIdentity: AudioSourceTrackIdentity,
        inputFormatGeneration: AudioInputFormatGeneration,
        codec: AudioCodec,
        sourceStreamIndex: Int32,
        sourceSampleRate: Int32
    ) {
        self.targetCoordinator = targetCoordinator
        self.targetIssuer = targetIssuer
        self.sharedControlExecutor = sharedControlExecutor
        self.admissionIdentity = admissionIdentity
        self.ownerIdentity = ownerIdentity
        self.itemGeneration = itemGeneration
        self.mediaEpoch = mediaEpoch
        self.sourceTrackIdentity = sourceTrackIdentity
        self.inputFormatGeneration = inputFormatGeneration
        self.codec = codec
        self.sourceStreamIndex = sourceStreamIndex
        self.sourceSampleRate = sourceSampleRate
    }

    func claimTimeline(_ issuer: AnyObject) -> Bool {
        precondition(sharedControlExecutor.isIsolated)
        if let timelineIssuer { return timelineIssuer === issuer }
        timelineIssuer = issuer
        return true
    }

    func isClaimed(by issuer: AnyObject) -> Bool {
        precondition(sharedControlExecutor.isIsolated)
        return timelineIssuer === issuer
    }

    func isCurrent() -> Bool {
        targetCoordinator?.acceptsCompressedOutputPlanBinding(self) == true
    }

    static func == (lhs: CompressedAudioOutputPlanBinding, rhs: CompressedAudioOutputPlanBinding) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// 构造器对调用方不可见；对象地址和签发 coordinator 状态共同组成进程内防伪身份。
final class CompressedAudioCandidatePlanAuthorization: @unchecked Sendable, Hashable {
    fileprivate weak var issuer: AudioServiceLeaseState?
    let timelinePlan: HLSTimelineCompressedAudioCandidatePlan
    let admissionIdentity: AudioBranchAdmissionIdentity
    let ownerIdentity: CompressedAudioBranchOwnerIdentity
    let itemGeneration: AudioItemGenerationIdentity
    let mediaEpoch: AudioMediaEpochIdentity
    let codec: AudioCodec
    let evaluatedAccessUnitInterval: CompressedAudioAccessUnitInterval
    let mediaOrigin: CMTime
    let firstAuthorizedAccessUnitStart: CMTime
    let originDecision: CompressedAudioOriginDecision

    fileprivate init(
        issuer: AudioServiceLeaseState,
        timelinePlan: HLSTimelineCompressedAudioCandidatePlan,
        admissionIdentity: AudioBranchAdmissionIdentity,
        ownerIdentity: CompressedAudioBranchOwnerIdentity,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        codec: AudioCodec,
        evaluatedAccessUnitInterval: CompressedAudioAccessUnitInterval,
        mediaOrigin: CMTime,
        firstAuthorizedAccessUnitStart: CMTime,
        originDecision: CompressedAudioOriginDecision
    ) {
        self.issuer = issuer
        self.timelinePlan = timelinePlan
        self.admissionIdentity = admissionIdentity
        self.ownerIdentity = ownerIdentity
        self.itemGeneration = itemGeneration
        self.mediaEpoch = mediaEpoch
        self.codec = codec
        self.evaluatedAccessUnitInterval = evaluatedAccessUnitInterval
        self.mediaOrigin = mediaOrigin
        self.firstAuthorizedAccessUnitStart = firstAuthorizedAccessUnitStart
        self.originDecision = originDecision
    }

    static func == (
        lhs: CompressedAudioCandidatePlanAuthorization,
        rhs: CompressedAudioCandidatePlanAuthorization
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct AudioServiceBranchLeaseNonce: Sendable, Hashable { let rawValue: UInt64 }
struct DecoderInputOwnerIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct PartialAudioAggregationIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct CompressedAccessUnitBundleNonce: Sendable, Hashable { let rawValue: UInt64 }
struct EAC3AccessUnitIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct EAC3OutputBackingIdentity: Sendable, Hashable { let rawValue: UInt64 }

/// 输出 bundle 持有该对象时，进程内 backing identity 不能由另一 allocation 冒充。
final class EAC3OutputBackingOwnerIdentity: @unchecked Sendable, Hashable {
    init() {}

    static func == (lhs: EAC3OutputBackingOwnerIdentity, rhs: EAC3OutputBackingOwnerIdentity) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct CompressedAccessUnitBundleIdentity: Sendable, Hashable {
    let inputUnitIdentity: AudioServiceInputUnitIdentity
    let audioBranchAdmissionIdentity: AudioBranchAdmissionIdentity
    let backingIdentity: AudioServiceBackingIdentity
    let backingOwnerIdentity: AudioServiceBackingOwnerIdentity
    let byteRange: AudioServiceByteRange
    let digest: AudioServiceEvidenceDigest
    let bundleNonce: CompressedAccessUnitBundleNonce
}

struct EAC3AccessUnitBundleIdentity: Sendable, Hashable {
    let accessUnitIdentity: EAC3AccessUnitIdentity
    let audioBranchAdmissionIdentity: AudioBranchAdmissionIdentity
    let outputBackingIdentity: EAC3OutputBackingIdentity
    let outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity
    let outputByteRange: AudioServiceByteRange
    let outputDigest: AudioServiceEvidenceDigest
    let bundleNonce: CompressedAccessUnitBundleNonce
}

enum AudioServiceBranchTransferOwnerIdentity: Sendable, Hashable {
    case decoder(DecoderInputOwnerIdentity)
    case compressedAccessUnit(CompressedAccessUnitBundleIdentity)
    case eac3AccessUnit(EAC3AccessUnitBundleIdentity)
}

enum AudioServiceBranchLeaseState: Sendable, Hashable {
    case available
    case held(PartialAudioAggregationIdentity)
    case transferred(AudioServiceBranchTransferOwnerIdentity)
    case released
}

struct AudioServiceBranchLeaseIdentity: Sendable, Hashable {
    let proofIdentity: AdmittedAudioServiceInputUnitProofIdentity
    let admissionIdentity: AudioBranchAdmissionIdentity
    let leaseNonce: AudioServiceBranchLeaseNonce
}

struct AudioServiceBranchLease: Sendable, Hashable {
    let identity: AudioServiceBranchLeaseIdentity
    let state: AudioServiceBranchLeaseState
}

struct AudioServiceBranchDrainFence: Sendable, Hashable {
    let admissionIdentity: AudioBranchAdmissionIdentity
    let lastIssuedLeaseSequence: UInt64
    let expectedOutstandingCount: Int
}

enum AudioServiceLeaseMutationResult: Sendable, Equatable {
    case held
    case transferred
    case released
    case alreadyDisposed
    case invalidTransition
    case identityMismatch
}

final class AudioServiceBranchGateRecord: @unchecked Sendable {
    let admissionIdentity: AudioBranchAdmissionIdentity
    var isOpen = true
    var lastIssuedSequence: UInt64 = 0
    var outstandingCount = 0
    var closeFence: AudioServiceBranchDrainFence?
    var compressedAuthorization: CompressedAudioCandidatePlanAuthorization?
    var nextCompressedPresentationStart: CMTime?

    init(admissionIdentity: AudioBranchAdmissionIdentity) {
        self.admissionIdentity = admissionIdentity
    }
}

final class AudioServiceBranchLeaseRecord: @unchecked Sendable {
    let identity: AudioServiceBranchLeaseIdentity
    let sequence: UInt64
    var state: AudioServiceBranchLeaseState = .available
    var lastTransferOwner: AudioServiceBranchTransferOwnerIdentity?
    var compressedAuthorization: CompressedAudioCandidatePlanAuthorization?
    var writerClaimed = false
    var wasSealedEAC3Commit = false

    init(identity: AudioServiceBranchLeaseIdentity, sequence: UInt64) {
        self.identity = identity
        self.sequence = sequence
    }
}

final class AudioServiceBranchParticipation: @unchecked Sendable {
    let admissionIdentity: AudioBranchAdmissionIdentity
    let gate: AudioServiceBranchGateRecord
    var lease: AudioServiceBranchLeaseRecord?
    var compressedAuthorization: CompressedAudioCandidatePlanAuthorization?
    var isSuppressed = false

    init(admissionIdentity: AudioBranchAdmissionIdentity, gate: AudioServiceBranchGateRecord) {
        self.admissionIdentity = admissionIdentity
        self.gate = gate
    }
}

final class AdmittedAudioServiceBranchState: @unchecked Sendable {
    var participations = AudioServiceFixedReferenceSlots<AudioServiceBranchParticipation>()
    var decodedPCMUnits = AudioServiceFixedReferenceSlots<DecodedPCMUnitIdentity>()
    var isSealed = false
    var isRetired = false
    var isGenerationRevoked = false
    var ownershipReleaseClaimed = false
    var hasTransferredCompressedOwner: Bool {
        participations.first { participation in
            guard let lease = participation.lease,
                  case let .transferred(owner) = lease.state else { return false }
            switch owner {
            case .compressedAccessUnit, .eac3AccessUnit: return true
            case .decoder: return false
            }
        } != nil
    }
    var hasTransferredDecoderOwner: Bool {
        participations.first { participation in
            guard let lease = participation.lease,
                  case .transferred(.decoder) = lease.state else { return false }
            return true
        } != nil
    }
}

final class AudioServiceLeaseState: @unchecked Sendable {
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    let applicationEscrow: AudioServiceApplicationEscrow?
    private var admittedProofIndex: AudioServiceAdmittedProofIndex?
    var branchGates = AudioServiceFixedReferenceSlots<AudioServiceBranchGateRecord>()
    var issuedBranchLeaseCount = 0
    var claimedCompressedWriterSubmissionCount = 0
    var compressedOutputPlanBinding: CompressedAudioOutputPlanBinding?
    let pcm = PCMConsumerLeaseState()

    init(applicationLedger: HLSDeliveryApplicationChargeLedger) {
        self.applicationLedger = applicationLedger
        let escrow = Self.checkedMaximumRetainedStructureChargeBytes.flatMap {
            AudioServiceApplicationEscrow.reserve(
                bytes: $0,
                credits: AudioServiceRegistryCapacity.authoritativeAdmittedProofs,
                ledger: applicationLedger)
        }
        applicationEscrow = escrow
        admittedProofIndex = escrow.map {
            AudioServiceAdmittedProofIndex(applicationEscrow: $0)
        }
    }

    /// 一个 coordinator 只登记一个 application reservation；它预付唯一索引与
    /// 全部可能 proof 分支图的固定峰值，proof 外部 alias 与索引共同持有 escrow。
    static var maximumRetainedStructureChargeBytes: Int {
        guard let value = checkedMaximumRetainedStructureChargeBytes else {
            preconditionFailure("固定 audio service 结构费用发生算术溢出")
        }
        return value
    }

    private static var checkedMaximumRetainedStructureChargeBytes: Int? {
        guard let proofGraphBytes = AdmittedAudioServiceInputUnitProof
            .checkedMaximumRetainedGraphChargeBytes else { return nil }
        return AudioServiceRetainedStructureCharge.checkedTotal(
            indexSlotCount: AudioServiceRegistryCapacity.authoritativeAdmittedProofs,
            indexSlotStride: MemoryLayout<AdmittedAudioServiceInputUnitProof?>.stride,
            indexObjectBytes: malloc_good_size(
                class_getInstanceSize(AudioServiceAdmittedProofIndex.self)),
            escrowObjectBytes: malloc_good_size(
                class_getInstanceSize(AudioServiceApplicationEscrow.self)),
            lockObjectBytes: malloc_good_size(class_getInstanceSize(NSLock.self)),
            reservationObjectBytes: malloc_good_size(
                class_getInstanceSize(PlaybackApplicationChargeReservation.self)),
            proofCount: AudioServiceRegistryCapacity.authoritativeAdmittedProofs,
            proofGraphBytes: proofGraphBytes)
    }

    var admittedProofCount: Int { admittedProofIndex?.count ?? 0 }
    var hasAdmittedProofSpace: Bool {
        guard let index = admittedProofIndex else { return false }
        return index.hasSpace
            && applicationEscrow?.hasAvailableCredit == true
            && retainedDecoderTailCount(in: index)
                < AudioServiceRegistryCapacity.admittedProofs
    }

    func canTransferDecoderOwner(for proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        guard let index = admittedProofIndex else { return false }
        let targetAlreadyCounted = !proof.branchState.hasTransferredCompressedOwner
            || proof.branchState.hasTransferredDecoderOwner
        let projected = retainedDecoderTailCount(in: index)
            + (targetAlreadyCounted ? 0 : 1)
        return projected <= AudioServiceRegistryCapacity.admittedProofs
    }

    private func retainedDecoderTailCount(in index: AudioServiceAdmittedProofIndex)
        -> Int {
        index.count {
            !$0.branchState.hasTransferredCompressedOwner
                || $0.branchState.hasTransferredDecoderOwner
        }
    }

    func registerAdmittedProof(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        admittedProofIndex?.insert(proof) == true
    }

    func isRegistered(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        admittedProofIndex?.first { $0 === proof } != nil && !proof.branchState.isRetired
    }

    func containsAdmittedOwnership(_ ownership: AudioServiceInputUnitOwnership) -> Bool {
        admittedProofIndex?.first { $0.ownership === ownership } != nil
    }

    func admittedProof(
        identity: AdmittedAudioServiceInputUnitProofIdentity
    ) -> AdmittedAudioServiceInputUnitProof? {
        admittedProofIndex?.first { $0.identity == identity }
    }

    @discardableResult
    func removeAdmittedProof(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        admittedProofIndex?.remove { $0 === proof } != nil
    }

    func forEachAdmittedProof(_ body: (AdmittedAudioServiceInputUnitProof) -> Void) {
        admittedProofIndex?.forEach(body)
    }
}

extension AudioServiceSemanticCoordinator {
    var issuedBranchLeaseCount: Int {
        withAudioServiceCAS { audioServiceLeaseState.issuedBranchLeaseCount }
    }

    var claimedCompressedWriterSubmissionCount: Int {
        withAudioServiceCAS { audioServiceLeaseState.claimedCompressedWriterSubmissionCount }
    }

    var audioServiceRegistryUsage: AudioServiceRegistryUsage {
        withAudioServiceCAS {
            AudioServiceRegistryUsage(
                admittedProofs: audioServiceLeaseState.admittedProofCount,
                branchGates: audioServiceLeaseState.branchGates.count,
                pcmSubscriptionGates: audioServiceLeaseState.pcm.gates.count,
                pcmBundles: audioServiceLeaseState.pcm.bundles.count
            )
        }
    }

    func openDecoderGate(_ identity: SharedDecoderAdmissionIdentity) -> Bool {
        withAudioServiceCAS {
            guard hasCurrentAudioServiceGenerationAuthority(),
                  identity.sourceTrackIdentity == sourceTrackIdentity,
                  identity.inputFormatGeneration == inputFormatGeneration else { return false }
            return openGate(.decoder(identity)) != nil
        }
    }

    /// 完整候选只冻结一次；timeline 后续只能读取，不能重新自报 owner 或 admission。
    func bindCompressedOutputPlan() -> CompressedAudioOutputPlanBinding? {
        withAudioServiceCAS {
            guard hasCurrentAudioServiceGenerationAuthority(),
                  source.sampleRate > 0,
                  let sharedControlExecutor,
                  let admission = compressedOutputAdmissionAuthority,
                  let owner = admission.compressedOwner,
                  admission.accepts(codec: source.codec),
                  let itemGeneration = owner.itemGeneration,
                  let mediaEpoch = owner.mediaEpoch else { return nil }
            if let existing = audioServiceLeaseState.compressedOutputPlanBinding { return existing }
            let binding = CompressedAudioOutputPlanBinding(
                targetCoordinator: self,
                targetIssuer: audioServiceLeaseState,
                sharedControlExecutor: sharedControlExecutor,
                admissionIdentity: admission,
                ownerIdentity: owner,
                itemGeneration: itemGeneration,
                mediaEpoch: mediaEpoch,
                sourceTrackIdentity: sourceTrackIdentity,
                inputFormatGeneration: inputFormatGeneration,
                codec: source.codec,
                sourceStreamIndex: source.streamIndex,
                sourceSampleRate: source.sampleRate
            )
            audioServiceLeaseState.compressedOutputPlanBinding = binding
            return binding
        }
    }

    /// origin 与 AU 区间只能来自 timeline 当前真实状态；这里只消费 opaque plan。
    func authorizeCompressedCandidate(
        _ plan: HLSTimelineCompressedAudioCandidatePlan
    ) -> CompressedAudioCandidatePlanAuthorization? {
        withAudioServiceCAS {
            guard hasCurrentAudioServiceGenerationAuthority(),
                  let binding = audioServiceLeaseState.compressedOutputPlanBinding,
                  plan.outputBinding === binding,
                  binding.targetIssuer === audioServiceLeaseState,
                  binding.targetCoordinator === self,
                  let sharedControlExecutor,
                  binding.sharedControlExecutor === sharedControlExecutor,
                  plan.sharedControlExecutor === sharedControlExecutor,
                  binding.sourceTrackIdentity == sourceTrackIdentity,
                  binding.inputFormatGeneration == inputFormatGeneration,
                  binding.codec == source.codec,
                  binding.sourceStreamIndex == source.streamIndex,
                  binding.sourceSampleRate == source.sampleRate,
                  plan.isCurrent else { return nil }
            return CompressedAudioCandidatePlanAuthorization(
                issuer: audioServiceLeaseState,
                timelinePlan: plan,
                admissionIdentity: binding.admissionIdentity,
                ownerIdentity: binding.ownerIdentity,
                itemGeneration: binding.itemGeneration,
                mediaEpoch: binding.mediaEpoch,
                codec: binding.codec,
                evaluatedAccessUnitInterval: plan.accessUnitInterval,
                mediaOrigin: plan.mediaOrigin,
                firstAuthorizedAccessUnitStart: plan.firstAuthorizedAccessUnitStart,
                originDecision: plan.originDecision
            )
        }
    }

    func acceptsCompressedOutputPlanBinding(
        _ binding: CompressedAudioOutputPlanBinding
    ) -> Bool {
        withAudioServiceCAS {
            hasCurrentAudioServiceGenerationAuthority()
                && audioServiceLeaseState.compressedOutputPlanBinding === binding
                && binding.targetIssuer === audioServiceLeaseState
                && binding.targetCoordinator === self
                && binding.sharedControlExecutor === sharedControlExecutor
        }
    }

    func acceptsCompressedAuthorization(
        _ authorization: CompressedAudioCandidatePlanAuthorization
    ) -> Bool {
        withAudioServiceCAS { acceptsCompressedAuthorizationInCurrentCAS(authorization) }
    }

    /// 只读当前唯一 compressed gate 的下一起点；不签发 authority、不推进状态。
    /// 最终 commit 仍须在同一 CAS 中再次逐字段验证并原子推进。
    func acceptsNextCompressedPresentationStart(
        _ start: CMTime,
        authorization: CompressedAudioCandidatePlanAuthorization
    ) -> Bool {
        withAudioServiceCAS {
            guard acceptsCompressedAuthorizationInCurrentCAS(authorization),
                  let gate = audioServiceLeaseState.branchGates.first(where: {
                      $0.admissionIdentity == authorization.admissionIdentity
                        && $0.compressedAuthorization === authorization
                        && $0.isOpen
                  }), let expected = gate.nextCompressedPresentationStart else { return false }
            return CMTimeCompare(start, expected) == 0
        }
    }

    /// decoder admission先固定到proof wrapper；后续issue和close只认这个完整身份。
    func registerEligibleDecoderPlan(
        _ identity: SharedDecoderAdmissionIdentity,
        for proof: AdmittedAudioServiceInputUnitProof
    ) throws -> Bool {
        try withAudioServiceCAS {
            guard isCurrentAdmittedProof(proof), proofMatchesDecoderAdmission(proof, identity: identity) else {
                return false
            }
            let admission = AudioBranchAdmissionIdentity.decoder(identity)
            if let existing = proof.branchState.participations.first(where: {
                if case .decoder = $0.admissionIdentity { return true }
                return false
            }) {
                return existing.admissionIdentity == admission && existing.gate.isOpen && !existing.isSuppressed
            }
            guard proof.branchState.participations.hasSpace else {
                throw AudioServiceSemanticFailure.registryCapacityExceeded
            }
            let gate: AudioServiceBranchGateRecord
            if let existing = audioServiceLeaseState.branchGates.first(where: {
                $0.admissionIdentity == admission
            }) {
                gate = existing
            } else {
                guard let opened = openGate(admission) else {
                    throw AudioServiceSemanticFailure.registryCapacityExceeded
                }
                gate = opened
            }
            let participation = AudioServiceBranchParticipation(admissionIdentity: admission, gate: gate)
            if !gate.isOpen {
                participation.isSuppressed = true
                proof.decoderDisposition = .suppressed
            }
            guard proof.branchState.participations.insert(participation) else {
                throw AudioServiceSemanticFailure.registryCapacityExceeded
            }
            return gate.isOpen
        }
    }

    func registerEligibleCompressedPlan(
        _ authorization: CompressedAudioCandidatePlanAuthorization,
        for proof: AdmittedAudioServiceInputUnitProof
    ) throws -> Bool {
        try withAudioServiceCAS {
            let admission = authorization.admissionIdentity
            guard acceptsCompressedAuthorizationInCurrentCAS(authorization),
                  isCurrentAdmittedProof(proof),
                  authorization.codec == source.codec,
                  admission.compressedOwner == authorization.ownerIdentity,
                  authorization.itemGeneration == authorization.ownerIdentity.itemGeneration,
                  authorization.mediaEpoch == authorization.ownerIdentity.mediaEpoch,
                  admission.accepts(codec: authorization.codec),
                  admission.accepts(proof.identity.proofIdentity.unitKind) else { return false }
            if let existing = proof.branchState.participations.first(where: {
                $0.admissionIdentity == admission
            }) {
                return existing.compressedAuthorization === authorization
                    && existing.gate.compressedAuthorization === authorization
                    && existing.gate.isOpen && !existing.isSuppressed
            }
            guard proof.branchState.participations.hasSpace else {
                throw AudioServiceSemanticFailure.registryCapacityExceeded
            }
            let gate: AudioServiceBranchGateRecord
            if let existing = audioServiceLeaseState.branchGates.first(where: {
                $0.admissionIdentity == admission
            }) {
                guard existing.isOpen,
                      existing.compressedAuthorization == nil
                        || existing.compressedAuthorization === authorization else { return false }
                gate = existing
            } else {
                guard let opened = openGate(admission) else {
                    throw AudioServiceSemanticFailure.registryCapacityExceeded
                }
                gate = opened
            }
            if gate.compressedAuthorization == nil {
                gate.compressedAuthorization = authorization
                gate.nextCompressedPresentationStart = authorization.firstAuthorizedAccessUnitStart
            }
            let participation = AudioServiceBranchParticipation(admissionIdentity: admission, gate: gate)
            participation.compressedAuthorization = authorization
            return proof.branchState.participations.insert(participation)
        }
    }

    func closeDecoderGate(_ identity: SharedDecoderAdmissionIdentity) -> AudioServiceBranchDrainFence? {
        closeAudioServiceGate(.decoder(identity), suppressUnclaimedDecoderProofs: true)
    }

    func closeCompressedGate(_ identity: AudioBranchAdmissionIdentity) -> AudioServiceBranchDrainFence? {
        guard identity.isCompressed else { return nil }
        return closeAudioServiceGate(identity, suppressUnclaimedDecoderProofs: false)
    }

    func retireAudioServiceGate(_ fence: AudioServiceBranchDrainFence) -> Bool {
        let decision: (retired: Bool, ownerships: [AudioServiceInputUnitOwnership]) = withAudioServiceCAS {
            guard let gate = audioServiceLeaseState.branchGates.first(where: {
                $0.admissionIdentity == fence.admissionIdentity
            }), gate.closeFence == fence, !gate.isOpen, gate.outstandingCount == 0 else {
                return (false, [])
            }
            var ownerships: [AudioServiceInputUnitOwnership] = []
            var finishedRetiredProofs: [AdmittedAudioServiceInputUnitProof] = []
            audioServiceLeaseState.forEachAdmittedProof { proof in
                if let ownership = takeOwnershipForReleaseIfFinished(proof) { ownerships.append(ownership) }
                if proof.branchState.canLeaveRegistry {
                    finishedRetiredProofs.append(proof)
                }
            }
            finishedRetiredProofs.forEach { _ = audioServiceLeaseState.removeAdmittedProof($0) }
            _ = audioServiceLeaseState.branchGates.remove { $0 === gate }
            return (true, ownerships)
        }
        decision.ownerships.forEach { $0.release() }
        return decision.retired
    }

    func issueAudioServiceBranchLease(
        for proof: AdmittedAudioServiceInputUnitProof,
        admission: AudioBranchAdmissionIdentity
    ) throws -> AudioServiceBranchLease? {
        try withAudioServiceCAS {
            guard isCurrentAdmittedProof(proof), audioServiceLeaseState.isRegistered(proof),
                  !proof.branchState.isSealed, !proof.branchState.isRetired else { return nil }

            let gate: AudioServiceBranchGateRecord
            let participation: AudioServiceBranchParticipation
            switch admission {
            case let .decoder(identity):
                guard proof.decoderDisposition == .unclaimed,
                      proofMatchesDecoderAdmission(proof, identity: identity),
                      let existing = proof.branchState.participations.first(where: {
                          $0.admissionIdentity == admission && $0.gate.isOpen && !$0.isSuppressed
                      }) else { return nil }
                participation = existing
                gate = existing.gate
            case .directCompressed, .eac3Aggregation:
                guard let existing = proof.branchState.participations.first(where: {
                    $0.admissionIdentity == admission && $0.gate.isOpen && !$0.isSuppressed
                }), admission.accepts(proof.identity.proofIdentity.unitKind),
                      acceptsCurrentCompressedParticipationInCurrentCAS(existing) else { return nil }
                participation = existing
                gate = existing.gate
            }
            guard participation.lease == nil else { return nil }

            let nonce = AudioServiceBranchLeaseNonce(rawValue: try nextIdentity(in: .lease))
            let sequence = try nextIdentity(in: .sequence)
            let identity = AudioServiceBranchLeaseIdentity(
                proofIdentity: proof.identity,
                admissionIdentity: admission,
                leaseNonce: nonce
            )
            let record = AudioServiceBranchLeaseRecord(identity: identity, sequence: sequence)
            participation.lease = record
            gate.lastIssuedSequence = sequence
            gate.outstandingCount += 1
            audioServiceLeaseState.issuedBranchLeaseCount += 1
            if case .decoder = admission { proof.decoderDisposition = .leased(nonce) }
            return AudioServiceBranchLease(identity: identity, state: .available)
        }
    }

    func transferDecoderLease(
        _ identity: AudioServiceBranchLeaseIdentity,
        to owner: DecoderInputOwnerIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard case .decoder = identity.admissionIdentity,
                  let located = locateBranchLease(identity) else { return .identityMismatch }
            guard located.record.state != .available || isCurrentAdmittedProof(located.proof) else {
                return .invalidTransition
            }
            guard located.record.state == .available,
                  located.proof.decoderDisposition == .leased(identity.leaseNonce),
                  audioServiceLeaseState.canTransferDecoderOwner(for: located.proof) else {
                return located.record.state.isTerminalOrTransferred ? .alreadyDisposed : .invalidTransition
            }
            let transferOwner = AudioServiceBranchTransferOwnerIdentity.decoder(owner)
            located.record.state = .transferred(transferOwner)
            located.record.lastTransferOwner = transferOwner
            located.proof.decoderDisposition = .transferred(owner)
            return .transferred
        }
    }

    func holdEAC3AggregationLease(
        _ identity: AudioServiceBranchLeaseIdentity,
        partial: PartialAudioAggregationIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard case .eac3Aggregation = identity.admissionIdentity,
                  let located = locateBranchLease(identity) else { return .invalidTransition }
            guard acceptsCurrentCompressedParticipationInCurrentCAS(located.participation) else {
                return .invalidTransition
            }
            guard located.record.state != .available || isCurrentAdmittedProof(located.proof) else {
                return .invalidTransition
            }
            guard located.record.state == .available else {
                return located.record.state.isTerminalOrTransferred ? .alreadyDisposed : .invalidTransition
            }
            located.record.state = .held(partial)
            return .held
        }
    }

    func transferCompressedLease(
        _ identity: AudioServiceBranchLeaseIdentity,
        to bundle: CompressedAccessUnitBundleIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard case .directCompressed = identity.admissionIdentity,
                  let located = locateBranchLease(identity) else { return .invalidTransition }
            guard located.participation.compressedAuthorization == nil,
                  located.participation.gate.compressedAuthorization == nil,
                  located.record.compressedAuthorization == nil else { return .invalidTransition }
            guard identity.admissionIdentity == bundle.audioBranchAdmissionIdentity,
                  bundle.matches(located.proof.identity.proofIdentity) else { return .identityMismatch }
            guard located.record.state != .available || isCurrentAdmittedProof(located.proof) else {
                return .invalidTransition
            }
            guard located.record.state == .available else {
                return located.record.state.isTerminalOrTransferred ? .alreadyDisposed : .invalidTransition
            }
            let owner = AudioServiceBranchTransferOwnerIdentity.compressedAccessUnit(bundle)
            located.record.state = .transferred(owner)
            located.record.lastTransferOwner = owner
            return .transferred
        }
    }

    /// direct AU 的授权、proof、PTS 与 transfer 在同一个 CAS 中复验。
    func commitAuthorizedCompressedLease(
        authorization: CompressedAudioCandidatePlanAuthorization,
        inputUnit: AudioServiceInputUnit,
        proof: AdmittedAudioServiceInputUnitProof,
        leaseIdentity: AudioServiceBranchLeaseIdentity,
        bundle: CompressedAccessUnitBundleIdentity,
        sampleRate: Int32
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard acceptsCompressedAuthorizationInCurrentCAS(authorization),
                  authorization.codec == .ac3,
                  authorization.admissionIdentity == leaseIdentity.admissionIdentity,
                  let located = locateBranchLease(leaseIdentity),
                  located.proof === proof,
                  located.participation.compressedAuthorization === authorization,
                  located.participation.gate.compressedAuthorization === authorization,
                  identityMatches(inputUnit, proof: proof),
                  leaseIdentity.admissionIdentity == bundle.audioBranchAdmissionIdentity,
                  bundle.matches(proof.identity.proofIdentity),
                  sampleRate > 0,
                  let expectedStart = located.participation.gate.nextCompressedPresentationStart,
                  CMTimeCompare(inputUnit.presentationTimeStamp, expectedStart) == 0 else {
                return .identityMismatch
            }
            guard located.record.state != .available || isCurrentAdmittedProof(proof) else {
                return .invalidTransition
            }
            guard located.record.state == .available else {
                return located.record.state.isTerminalOrTransferred ? .alreadyDisposed : .invalidTransition
            }
            let owner = AudioServiceBranchTransferOwnerIdentity.compressedAccessUnit(bundle)
            located.record.state = .transferred(owner)
            located.record.lastTransferOwner = owner
            located.record.compressedAuthorization = authorization
            located.participation.gate.nextCompressedPresentationStart = CMTimeAdd(
                inputUnit.presentationTimeStamp,
                CMTime(value: 1_536, timescale: sampleRate)
            )
            return .transferred
        }
    }

    func transferEAC3AggregationLease(
        _ identity: AudioServiceBranchLeaseIdentity,
        to bundle: EAC3AccessUnitBundleIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard case .eac3Aggregation = identity.admissionIdentity,
                  let located = locateBranchLease(identity) else { return .invalidTransition }
            guard located.participation.compressedAuthorization == nil,
                  located.participation.gate.compressedAuthorization == nil,
                  located.record.compressedAuthorization == nil else { return .invalidTransition }
            guard identity.admissionIdentity == bundle.audioBranchAdmissionIdentity else {
                return .identityMismatch
            }
            guard !located.record.state.isHeld || isCurrentAdmittedProof(located.proof) else {
                return .invalidTransition
            }
            guard case .held = located.record.state else {
                return located.record.state.isTerminalOrTransferred ? .alreadyDisposed : .invalidTransition
            }
            let owner = AudioServiceBranchTransferOwnerIdentity.eac3AccessUnit(bundle)
            located.record.state = .transferred(owner)
            located.record.lastTransferOwner = owner
            return .transferred
        }
    }

    /// sealed request 把 exact held set、有序真实输入与真实输出绑定后才整批改写状态。
    func commitSealedEAC3AccessUnit(
        _ request: EAC3SealedCommitRequest
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            let authorization = request.authorization
            let orderedMembers = request.orderedMembers
            guard acceptsCompressedAuthorizationInCurrentCAS(authorization),
                  authorization.codec == .eac3,
                  (1...6).contains(orderedMembers.count),
                  request.bundleIdentity.audioBranchAdmissionIdentity == authorization.admissionIdentity,
                  request.bundleIdentity.outputBackingIdentity == request.outputBacking.identity,
                  request.bundleIdentity.outputBackingOwnerIdentity === request.outputBacking.ownerIdentity,
                  request.bundleIdentity.outputByteRange == request.outputByteRange,
                  request.bundleIdentity.outputDigest == request.outputDigest else {
                return .identityMismatch
            }

            var locatedEntries: [(
                proof: AdmittedAudioServiceInputUnitProof,
                participation: AudioServiceBranchParticipation,
                record: AudioServiceBranchLeaseRecord
            )] = []
            locatedEntries.reserveCapacity(6)
            for member in orderedMembers {
                guard member.leaseIdentity.admissionIdentity == authorization.admissionIdentity,
                      member.leaseIdentity.proofIdentity == member.admittedProof.identity,
                      let located = locateBranchLease(member.leaseIdentity),
                      located.proof === member.admittedProof,
                      located.participation.compressedAuthorization === authorization,
                      located.participation.gate.compressedAuthorization === authorization else {
                    return .identityMismatch
                }
                locatedEntries.append(located)
            }

            let owner = AudioServiceBranchTransferOwnerIdentity.eac3AccessUnit(request.bundleIdentity)
            if locatedEntries.allSatisfy({ $0.record.state.isTerminalOrTransferred }) {
                guard locatedEntries.allSatisfy({
                    $0.record.lastTransferOwner == owner && $0.record.wasSealedEAC3Commit
                }) else { return .identityMismatch }
                return .alreadyDisposed
            }

            var exactHeldCount = 0
            var containsUnlistedHeldMember = false
            audioServiceLeaseState.forEachAdmittedProof { admitted in
                admitted.branchState.participations.forEach { participation in
                    guard participation.admissionIdentity == authorization.admissionIdentity,
                          participation.compressedAuthorization === authorization,
                          let record = participation.lease,
                          record.state == .held(request.partialIdentity) else { return }
                    exactHeldCount += 1
                    if !orderedMembers.contains(where: { $0.leaseIdentity == record.identity }) {
                        containsUnlistedHeldMember = true
                    }
                }
            }
            guard !containsUnlistedHeldMember, exactHeldCount == orderedMembers.count else {
                return .identityMismatch
            }

            for (member, located) in zip(orderedMembers, locatedEntries) {
                let proof = member.admittedProof.identity.proofIdentity
                guard isCurrentAdmittedProof(located.proof),
                      located.record.state == .held(request.partialIdentity),
                      proof.inputUnitIdentity == member.inputUnit.identity,
                      proof.backingIdentity == member.inputUnit.backing.identity,
                      proof.backingOwnerIdentity === member.inputUnit.backing.ownerIdentity,
                      proof.byteRange == member.inputUnit.byteRange,
                      proof.observedSemantic == .independentMain,
                      proof.unitKind == .eac3Syncframe,
                      proof.codecFacts?.profileID == .eac3 else { return .identityMismatch }
            }
            guard request.blockCount == 6,
                  request.hasValidOrderingAndStart,
                  request.actualDataRateKbps > 0,
                  request.actualDataRateKbps <= EAC3AccessUnitAssembler
                    .trustedParserDomainMaximumDataRateKbps,
                  request.outputByteRange == request.outputBacking.fullRange,
                  request.outputDigest == request.outputBacking.fullDigest,
                  let nextStart = locatedEntries.first?.participation.gate.nextCompressedPresentationStart,
                  CMTimeCompare(request.firstPresentationTimeStamp, nextStart) == 0 else {
                return .identityMismatch
            }

            for entry in locatedEntries {
                entry.record.state = .transferred(owner)
                entry.record.lastTransferOwner = owner
                entry.record.compressedAuthorization = authorization
                entry.record.wasSealedEAC3Commit = true
            }
            locatedEntries.first?.participation.gate.nextCompressedPresentationStart = CMTimeAdd(
                request.firstPresentationTimeStamp,
                request.duration
            )
            return .transferred
        }
    }

    /// 先在同一CAS中验证完整批次，再统一改写；不能留下部分 transferred 状态。
    func transferEAC3AggregationLeases(
        _ identities: [AudioServiceBranchLeaseIdentity],
        partial: PartialAudioAggregationIdentity,
        to bundle: EAC3AccessUnitBundleIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard (1...6).contains(identities.count),
                  bundle.outputByteRange.length > 0 else { return .identityMismatch }
            for left in identities.indices {
                for right in identities.indices where left < right {
                    guard identities[left] != identities[right] else { return .identityMismatch }
                }
            }

            var entries: [(
                proof: AdmittedAudioServiceInputUnitProof,
                participation: AudioServiceBranchParticipation,
                record: AudioServiceBranchLeaseRecord
            )] = []
            entries.reserveCapacity(6)
            for identity in identities {
                guard case .eac3Aggregation = identity.admissionIdentity,
                      identity.admissionIdentity == bundle.audioBranchAdmissionIdentity,
                      let entry = locateBranchLease(identity) else { return .identityMismatch }
                entries.append(entry)
            }
            guard entries.allSatisfy({
                $0.participation.compressedAuthorization == nil
                    && $0.participation.gate.compressedAuthorization == nil
                    && $0.record.compressedAuthorization == nil
            }) else { return .invalidTransition }
            guard let first = entries.first else { return .identityMismatch }
            let firstProof = first.proof.identity.proofIdentity
            for entry in entries {
                guard entry.proof.identity.proofIdentity.parentReceiptIdentity ==
                        firstProof.parentReceiptIdentity,
                      entry.proof.identity.proofIdentity.inputFormatGeneration ==
                        firstProof.inputFormatGeneration else {
                    return .identityMismatch
                }
            }
            let owner = AudioServiceBranchTransferOwnerIdentity.eac3AccessUnit(bundle)
            if entries.allSatisfy({ $0.record.state.isTerminalOrTransferred }) {
                guard entries.allSatisfy({ $0.record.lastTransferOwner == owner }) else {
                    return .identityMismatch
                }
                return .alreadyDisposed
            }
            for entry in entries {
                guard isCurrentAdmittedProof(entry.proof) else {
                    return .invalidTransition
                }
                guard case let .held(actualPartial) = entry.record.state,
                      actualPartial == partial else {
                    return entry.record.state.isTerminalOrTransferred
                        ? .invalidTransition
                        : .identityMismatch
                }
            }
            for entry in entries {
                entry.record.state = .transferred(owner)
                entry.record.lastTransferOwner = owner
            }
            return .transferred
        }
    }

    func releaseAudioServiceBranchLease(
        _ identity: AudioServiceBranchLeaseIdentity,
        expectedOwner: AudioServiceBranchTransferOwnerIdentity? = nil
    ) -> AudioServiceLeaseMutationResult {
        let decision: (result: AudioServiceLeaseMutationResult, ownership: AudioServiceInputUnitOwnership?) =
            withAudioServiceCAS {
                guard let located = locateBranchLease(identity) else { return (.identityMismatch, nil) }
                switch located.record.state {
                case .released:
                    return (.alreadyDisposed, nil)
                case .available, .held:
                    guard expectedOwner == nil else { return (.identityMismatch, nil) }
                case let .transferred(owner):
                    guard expectedOwner == owner else { return (.identityMismatch, nil) }
                }
                releaseRecord(located.record, proof: located.proof, gate: located.participation.gate)
                let ownership = takeOwnershipForReleaseIfFinished(located.proof)
                if located.proof.branchState.canLeaveRegistry {
                    _ = audioServiceLeaseState.removeAdmittedProof(located.proof)
                }
                return (.released, ownership)
            }
        decision.ownership?.release()
        return decision.result
    }

    /// writer 的 append 权限只能在 coordinator CAS 中领取一次；领取不改变 transfer owner。
    func claimCompressedAudioWriterSubmission(
        _ submission: CompressedAudioWriterSubmission,
        expectedIdentity: CompressedAudioWriterExpectedIdentity
    ) -> Bool {
        withAudioServiceCAS {
            let authorization = submission.accessUnit.authorization
            guard expectedIdentity.accepts(submission),
                  acceptsCompressedAuthorizationInCurrentCAS(authorization) else { return false }
            let (nextCount, overflow) = audioServiceLeaseState.claimedCompressedWriterSubmissionCount
                .addingReportingOverflow(1)
            guard !overflow else { return false }

            switch submission.bundleIdentity {
            case let .direct(bundle):
                guard let leaseIdentity = submission.accessUnit.directLeaseIdentity,
                      let located = locateBranchLease(leaseIdentity),
                      located.participation.compressedAuthorization === authorization,
                      located.record.compressedAuthorization === authorization,
                      located.record.state == .transferred(.compressedAccessUnit(bundle)),
                      located.record.lastTransferOwner == .compressedAccessUnit(bundle),
                      !located.record.writerClaimed else { return false }
                located.record.writerClaimed = true
            case let .eac3(bundle):
                guard let proof = submission.accessUnit.aggregationProof else { return false }
                var records: [AudioServiceBranchLeaseRecord] = []
                records.reserveCapacity(6)
                for leaseIdentity in proof.orderedAggregationLeaseIdentities.values {
                    guard let located = locateBranchLease(leaseIdentity),
                          located.participation.compressedAuthorization === authorization,
                          located.record.compressedAuthorization === authorization,
                          located.record.state == .transferred(.eac3AccessUnit(bundle)),
                          located.record.lastTransferOwner == .eac3AccessUnit(bundle),
                          located.record.wasSealedEAC3Commit,
                          !located.record.writerClaimed else { return false }
                    records.append(located.record)
                }
                guard records.count == proof.orderedAggregationLeaseIdentities.count else { return false }
                records.forEach { $0.writerClaimed = true }
            }
            audioServiceLeaseState.claimedCompressedWriterSubmissionCount = nextCount
            return true
        }
    }

    /// terminal 只释放已领取 writer 权限且 owner 仍精确匹配的 lease。
    func finishCompressedAudioWriterSubmission(_ submission: CompressedAudioWriterSubmission) -> Int {
        let decision: (count: Int, ownerships: [AudioServiceInputUnitOwnership]) = withAudioServiceCAS {
            let expectedOwner: AudioServiceBranchTransferOwnerIdentity
            let leaseIdentities: [AudioServiceBranchLeaseIdentity]
            switch submission.bundleIdentity {
            case let .direct(bundle):
                guard let lease = submission.accessUnit.directLeaseIdentity else { return (0, []) }
                expectedOwner = .compressedAccessUnit(bundle)
                leaseIdentities = [lease]
            case let .eac3(bundle):
                guard let proof = submission.accessUnit.aggregationProof else { return (0, []) }
                expectedOwner = .eac3AccessUnit(bundle)
                leaseIdentities = proof.orderedAggregationLeaseIdentities.values
            }

            var entries: [(
                proof: AdmittedAudioServiceInputUnitProof,
                participation: AudioServiceBranchParticipation,
                record: AudioServiceBranchLeaseRecord
            )] = []
            entries.reserveCapacity(6)
            for lease in leaseIdentities {
                guard let located = locateBranchLease(lease),
                      located.record.writerClaimed,
                      located.record.state == .transferred(expectedOwner),
                      located.record.lastTransferOwner == expectedOwner else { return (0, []) }
                entries.append(located)
            }

            var ownerships: [AudioServiceInputUnitOwnership] = []
            for entry in entries {
                releaseRecord(entry.record, proof: entry.proof, gate: entry.participation.gate)
                if let ownership = takeOwnershipForReleaseIfFinished(entry.proof) {
                    ownerships.append(ownership)
                }
                if entry.proof.branchState.canLeaveRegistry {
                    _ = audioServiceLeaseState.removeAdmittedProof(entry.proof)
                }
            }
            return (entries.count, ownerships)
        }
        decision.ownerships.forEach { $0.release() }
        return decision.count
    }

    func branchLeaseState(_ identity: AudioServiceBranchLeaseIdentity) -> AudioServiceBranchLeaseState? {
        withAudioServiceCAS { locateBranchLease(identity)?.record.state }
    }

    func decoderDisposition(of proof: AdmittedAudioServiceInputUnitProof) -> AudioServiceDecoderDisposition {
        withAudioServiceCAS { proof.decoderDisposition }
    }

    func isDrained(_ fence: AudioServiceBranchDrainFence) -> Bool {
        withAudioServiceCAS {
            guard let gate = audioServiceLeaseState.branchGates.first(where: {
                $0.admissionIdentity == fence.admissionIdentity
            }), gate.closeFence == fence else { return false }
            return gate.outstandingCount == 0
        }
    }

    func sealAudioServiceBranches(for proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        let decision: (sealed: Bool, ownership: AudioServiceInputUnitOwnership?) = withAudioServiceCAS {
            guard audioServiceLeaseState.isRegistered(proof) else { return (false, nil) }
            proof.branchState.isSealed = true
            return (true, takeOwnershipForReleaseIfFinished(proof))
        }
        decision.ownership?.release()
        return decision.sealed
    }

    func retireAdmittedProof(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        let decision: (retired: Bool, ownership: AudioServiceInputUnitOwnership?) = withAudioServiceCAS {
            guard audioServiceLeaseState.isRegistered(proof) else { return (false, nil) }
            proof.branchState.isRetired = true
            proof.branchState.isSealed = true
            if proof.decoderDisposition == .unclaimed { proof.decoderDisposition = .suppressed }
            proof.branchState.participations.forEach { participation in
                guard let lease = participation.lease else {
                    participation.isSuppressed = true
                    return
                }
                if lease.state.isReleasableByRetirement {
                    releaseRecord(lease, proof: proof, gate: participation.gate)
                }
            }
            let ownership = takeOwnershipForReleaseIfFinished(proof)
            if proof.branchState.canLeaveRegistry {
                _ = audioServiceLeaseState.removeAdmittedProof(proof)
            }
            return (true, ownership)
        }
        decision.ownership?.release()
        return decision.retired
    }

    /// 必须由semantic失败路径在同一CAS内调用；只撤销新消费权，transferred仍由准确owner收尾。
    func revokeAudioServiceGenerationForUnsupportedSemantic() -> [AudioServiceInputUnitOwnership] {
        audioServiceLeaseState.branchGates.forEach { gate in
            guard gate.closeFence == nil else { return }
            gate.isOpen = false
            gate.closeFence = AudioServiceBranchDrainFence(
                admissionIdentity: gate.admissionIdentity,
                lastIssuedLeaseSequence: gate.lastIssuedSequence,
                expectedOutstandingCount: gate.outstandingCount
            )
        }
        audioServiceLeaseState.pcm.gates.forEach { gate in
            guard gate.closeFence == nil else { return }
            gate.isOpen = false
            gate.closeFence = PCMConsumerDrainFence(
                consumerAdmissionIdentity: gate.identity,
                lastIssuedLeaseSequence: gate.lastIssuedSequence,
                expectedOutstandingCount: gate.outstandingCount
            )
        }
        audioServiceLeaseState.pcm.bundles.forEach { bundle in
            var identities: [PCMConsumerAdmissionIdentity] = []
            bundle.consumerDispositionSlots.forEach { identities.append($0.consumerAdmissionIdentity) }
            identities.forEach { identity in
                switch bundle.consumerDispositionSlots.disposition(for: identity) {
                case .unclaimed?:
                    _ = bundle.consumerDispositionSlots.setDisposition(.suppressed, for: identity)
                case .leased?:
                    _ = bundle.consumerDispositionSlots.setDisposition(.released, for: identity)
                    if let gate = audioServiceLeaseState.pcm.gates.first(where: { $0.identity == identity }) {
                        precondition(gate.outstandingCount > 0)
                        gate.outstandingCount -= 1
                    }
                case .transferred?, .released?, .suppressed?, nil:
                    break
                }
            }
        }

        var ownerships: [AudioServiceInputUnitOwnership] = []
        var finishedProofs: [AdmittedAudioServiceInputUnitProof] = []
        audioServiceLeaseState.forEachAdmittedProof { proof in
            proof.branchState.isGenerationRevoked = true
            proof.branchState.isSealed = true
            if proof.decoderDisposition == .unclaimed { proof.decoderDisposition = .suppressed }
            proof.branchState.participations.forEach { participation in
                guard let lease = participation.lease else {
                    participation.isSuppressed = true
                    return
                }
                if lease.state.isReleasableByRetirement {
                    releaseRecord(lease, proof: proof, gate: participation.gate)
                }
            }
            if let ownership = takeOwnershipForReleaseIfFinished(proof) { ownerships.append(ownership) }
            if proof.branchState.canLeaveRegistry { finishedProofs.append(proof) }
        }
        finishedProofs.forEach { _ = audioServiceLeaseState.removeAdmittedProof($0) }
        return ownerships
    }

    func decoderLineageMatches(
        proof: AdmittedAudioServiceInputUnitProof,
        admission: SharedDecoderAdmissionIdentity,
        leaseIdentity: AudioServiceBranchLeaseIdentity,
        owner: DecoderInputOwnerIdentity
    ) -> Bool {
        guard let located = locateBranchLease(leaseIdentity), located.proof === proof,
              leaseIdentity.admissionIdentity == .decoder(admission),
              located.record.lastTransferOwner == .decoder(owner) else { return false }
        switch located.record.state {
        case let .transferred(.decoder(actualOwner)):
            return actualOwner == owner
        case .released:
            return located.proof.decoderDisposition == .released
        case .available, .held, .transferred:
            return false
        }
    }

    private func openGate(_ admission: AudioBranchAdmissionIdentity) -> AudioServiceBranchGateRecord? {
        if let existing = audioServiceLeaseState.branchGates.first(where: {
            $0.admissionIdentity == admission
        }) {
            return existing.isOpen ? existing : nil
        }
        guard audioServiceLeaseState.branchGates.hasSpace else { return nil }
        let gate = AudioServiceBranchGateRecord(admissionIdentity: admission)
        return audioServiceLeaseState.branchGates.insert(gate) ? gate : nil
    }

    private func closeAudioServiceGate(
        _ identity: AudioBranchAdmissionIdentity,
        suppressUnclaimedDecoderProofs: Bool
    ) -> AudioServiceBranchDrainFence? {
        let decision: (fence: AudioServiceBranchDrainFence?, ownerships: [AudioServiceInputUnitOwnership]) =
            withAudioServiceCAS {
                guard let gate = audioServiceLeaseState.branchGates.first(where: {
                    $0.admissionIdentity == identity
                }) else { return (nil, []) }
                if let fence = gate.closeFence { return (fence, []) }
                let fence = AudioServiceBranchDrainFence(
                    admissionIdentity: identity,
                    lastIssuedLeaseSequence: gate.lastIssuedSequence,
                    expectedOutstandingCount: gate.outstandingCount
                )
                gate.isOpen = false
                gate.closeFence = fence
                var ownerships: [AudioServiceInputUnitOwnership] = []
                var finishedRetiredProofs: [AdmittedAudioServiceInputUnitProof] = []
                audioServiceLeaseState.forEachAdmittedProof { proof in
                    if let participation = proof.branchState.participations.first(where: {
                        $0.admissionIdentity == identity
                    }) {
                        if let lease = participation.lease {
                            if lease.state.isReleasableByRetirement {
                                releaseRecord(lease, proof: proof, gate: gate)
                            }
                        } else {
                            participation.isSuppressed = true
                            if suppressUnclaimedDecoderProofs, proof.decoderDisposition == .unclaimed {
                                proof.decoderDisposition = .suppressed
                            }
                        }
                    }
                    if let ownership = takeOwnershipForReleaseIfFinished(proof) { ownerships.append(ownership) }
                    if proof.branchState.canLeaveRegistry {
                        finishedRetiredProofs.append(proof)
                    }
                }
                finishedRetiredProofs.forEach { _ = audioServiceLeaseState.removeAdmittedProof($0) }
                return (fence, ownerships)
            }
        decision.ownerships.forEach { $0.release() }
        return decision.fence
    }

    private func locateBranchLease(
        _ identity: AudioServiceBranchLeaseIdentity
    ) -> (
        proof: AdmittedAudioServiceInputUnitProof,
        participation: AudioServiceBranchParticipation,
        record: AudioServiceBranchLeaseRecord
    )? {
        guard let proof = audioServiceLeaseState.admittedProof(identity:
            identity.proofIdentity),
              let participation = proof.branchState.participations.first(where: {
            $0.admissionIdentity == identity.admissionIdentity && $0.lease?.identity == identity
        }), let record = participation.lease else { return nil }
        return (proof, participation, record)
    }

    private func proofMatchesDecoderAdmission(
        _ proof: AdmittedAudioServiceInputUnitProof,
        identity: SharedDecoderAdmissionIdentity
    ) -> Bool {
        let value = proof.identity.proofIdentity
        return identity.sourceTrackIdentity == value.parentReceiptIdentity.sourceTrackIdentity &&
            identity.inputFormatGeneration == value.inputFormatGeneration
    }

    private func releaseRecord(
        _ record: AudioServiceBranchLeaseRecord,
        proof: AdmittedAudioServiceInputUnitProof,
        gate: AudioServiceBranchGateRecord
    ) {
        guard record.state != .released else { return }
        record.state = .released
        precondition(gate.outstandingCount > 0)
        gate.outstandingCount -= 1
        if case .decoder = record.identity.admissionIdentity { proof.decoderDisposition = .released }
    }

    private func takeOwnershipForReleaseIfFinished(
        _ proof: AdmittedAudioServiceInputUnitProof
    ) -> AudioServiceInputUnitOwnership? {
        guard proof.branchState.isSealed, !proof.branchState.ownershipReleaseClaimed else { return nil }
        var allTerminal = true
        proof.branchState.participations.forEach { participation in
            if let lease = participation.lease {
                if lease.state != .released { allTerminal = false }
            } else if !participation.isSuppressed {
                allTerminal = false
            }
        }
        guard allTerminal else { return nil }
        proof.branchState.ownershipReleaseClaimed = true
        return proof.ownership
    }
}

private extension AudioServiceSemanticCoordinator {
    func acceptsCurrentCompressedParticipationInCurrentCAS(
        _ participation: AudioServiceBranchParticipation
    ) -> Bool {
        switch (
            participation.compressedAuthorization,
            participation.gate.compressedAuthorization
        ) {
        case (nil, nil):
            return true
        case let (authorization?, gateAuthorization?) where authorization === gateAuthorization:
            return acceptsCompressedAuthorizationInCurrentCAS(authorization)
        default:
            return false
        }
    }

    func acceptsCompressedAuthorizationInCurrentCAS(
        _ authorization: CompressedAudioCandidatePlanAuthorization
    ) -> Bool {
        guard authorization.issuer === audioServiceLeaseState,
              let binding = audioServiceLeaseState.compressedOutputPlanBinding,
              authorization.timelinePlan.outputBinding === binding,
              authorization.timelinePlan.isCurrent,
              authorization.admissionIdentity == binding.admissionIdentity,
              authorization.ownerIdentity == binding.ownerIdentity,
              authorization.itemGeneration == binding.itemGeneration,
              authorization.mediaEpoch == binding.mediaEpoch,
              authorization.codec == binding.codec,
              binding.sourceTrackIdentity == sourceTrackIdentity,
              binding.inputFormatGeneration == inputFormatGeneration,
              binding.sourceStreamIndex == source.streamIndex,
              binding.sourceSampleRate == source.sampleRate else { return false }
        return true
    }
}

private extension AudioBranchAdmissionIdentity {
    var compressedOwner: CompressedAudioBranchOwnerIdentity? {
        switch self {
        case .decoder: nil
        case let .directCompressed(owner, _, _), let .eac3Aggregation(owner, _, _): owner
        }
    }

    var isCompressed: Bool {
        switch self {
        case .decoder: false
        case .directCompressed, .eac3Aggregation: true
        }
    }

    func accepts(_ unitKind: AudioServiceInputUnitKind) -> Bool {
        switch self {
        case .decoder: true
        case .directCompressed: unitKind == .ac3Frame
        case .eac3Aggregation: unitKind == .eac3Syncframe
        }
    }

    func accepts(codec: AudioCodec) -> Bool {
        switch self {
        case .decoder: false
        case .directCompressed: codec == .ac3
        case .eac3Aggregation: codec == .eac3
        }
    }
}

private extension CompressedAudioBranchOwnerIdentity {
    var itemGeneration: AudioItemGenerationIdentity? {
        switch self {
        case let .audioVideo(_, item, _, _, _),
             let .audioOnly(_, _, _, item, _, _, _): item
        }
    }

    var mediaEpoch: AudioMediaEpochIdentity? {
        switch self {
        case let .audioVideo(_, _, media, _, _),
             let .audioOnly(_, _, _, _, media, _, _): media
        }
    }
}

private extension AudioServiceBranchLeaseState {
    var isTerminalOrTransferred: Bool {
        switch self {
        case .transferred, .released: true
        case .available, .held: false
        }
    }

    var isReleasableByRetirement: Bool {
        switch self {
        case .available, .held: true
        case .transferred, .released: false
        }
    }

    var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}

private extension AdmittedAudioServiceBranchState {
    var canLeaveRegistry: Bool {
        ownershipReleaseClaimed && (isRetired || isGenerationRevoked)
    }
}

private extension CompressedAccessUnitBundleIdentity {
    func matches(_ proof: AudioServiceSemanticInputUnitProof) -> Bool {
        inputUnitIdentity == proof.inputUnitIdentity &&
            backingIdentity == proof.backingIdentity &&
            backingOwnerIdentity === proof.backingOwnerIdentity &&
            byteRange == proof.byteRange &&
            digest == proof.evidenceDigest
    }
}

private extension AudioServiceSemanticCoordinator {
    func identityMatches(
        _ inputUnit: AudioServiceInputUnit,
        proof admittedProof: AdmittedAudioServiceInputUnitProof
    ) -> Bool {
        let proof = admittedProof.identity.proofIdentity
        return proof.inputUnitIdentity == inputUnit.identity
            && proof.backingIdentity == inputUnit.backing.identity
            && proof.backingOwnerIdentity === inputUnit.backing.ownerIdentity
            && proof.byteRange == inputUnit.byteRange
    }
}
