// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum EAC3AggregationTerminationReason: UInt8, Sendable, Hashable {
    case structuralFailure = 1
    case cancelled = 2
    case endOfStream = 3
    case discontinuity = 4
    case ownerRetired = 5
}

struct EAC3SealedCommitMember: @unchecked Sendable {
    let inputUnit: AudioServiceInputUnit
    let admittedProof: AdmittedAudioServiceInputUnitProof
    let leaseIdentity: AudioServiceBranchLeaseIdentity
}

/// 解析、拼接和输出证明均在 coordinator CAS 之前完成。
struct EAC3SealedCommitRequest: @unchecked Sendable {
    let authorization: CompressedAudioCandidatePlanAuthorization
    let partialIdentity: PartialAudioAggregationIdentity
    let orderedMembers: [EAC3SealedCommitMember]
    let outputBacking: EAC3AccessUnitBacking
    let outputByteRange: AudioServiceByteRange
    let outputDigest: AudioServiceEvidenceDigest
    let bundleIdentity: EAC3AccessUnitBundleIdentity
    let blockCount: Int
    let sampleRate: Int32
    let channelCount: Int32
    let firstPresentationTimeStamp: CMTime
    let duration: CMTime
    let actualDataRateKbps: UInt16
    let hasValidOrderingAndStart: Bool

    init(
        authorization: CompressedAudioCandidatePlanAuthorization,
        partialIdentity: PartialAudioAggregationIdentity,
        orderedMembers: [EAC3SealedCommitMember],
        outputBacking: EAC3AccessUnitBacking,
        outputByteRange: AudioServiceByteRange,
        outputDigest: AudioServiceEvidenceDigest,
        bundleIdentity: EAC3AccessUnitBundleIdentity
    ) throws {
        guard authorization.codec == .eac3,
              (1...6).contains(orderedMembers.count),
              outputByteRange == outputBacking.fullRange,
              outputDigest == outputBacking.fullDigest,
              bundleIdentity.audioBranchAdmissionIdentity == authorization.admissionIdentity,
              bundleIdentity.outputBackingIdentity == outputBacking.identity,
              bundleIdentity.outputBackingOwnerIdentity === outputBacking.ownerIdentity,
              bundleIdentity.outputByteRange == outputByteRange,
              bundleIdentity.outputDigest == outputDigest else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        for left in orderedMembers.indices {
            for right in orderedMembers.indices where left < right {
                guard orderedMembers[left].leaseIdentity != orderedMembers[right].leaseIdentity else {
                    throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
                }
            }
        }

        var payload = Data()
        guard let firstMember = orderedMembers.first else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        // 这里只证明本 AU 内部从真实首 member 起连续；跨 AU 的正式起点由
        // AudioService commit CAS 对当前 gate 再验并推进。
        var expectedPTS = firstMember.inputUnit.presentationTimeStamp
        var totalBlocks = 0
        var invariant: EAC3InvariantSignature?
        var hasValidOrderingAndStart = true
        for index in orderedMembers.indices {
            let member = orderedMembers[index]
            let proof = member.admittedProof.identity.proofIdentity
            let digest = try member.inputUnit.backing.digest(in: member.inputUnit.byteRange)
            guard member.leaseIdentity.proofIdentity == member.admittedProof.identity,
                  member.leaseIdentity.admissionIdentity == authorization.admissionIdentity,
                  proof.inputUnitIdentity == member.inputUnit.identity,
                  proof.backingIdentity == member.inputUnit.backing.identity,
                  proof.backingOwnerIdentity === member.inputUnit.backing.ownerIdentity,
                  proof.byteRange == member.inputUnit.byteRange,
                  proof.evidenceDigest == digest,
                  proof.observedSemantic == .independentMain,
                  proof.unitKind == .eac3Syncframe else {
                throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
            }
            if CMTimeCompare(member.inputUnit.presentationTimeStamp, expectedPTS) != 0 {
                hasValidOrderingAndStart = false
            }
            let inspection = try EAC3FrameInspector.inspect(member.inputUnit.bytes)
            guard inspection.streamType == .independent,
                  inspection.substreamID == 0,
                  inspection.hasJOC == false,
                  inspection.bsmod == 0,
                  proof.codecFacts?.profileID == .eac3,
                  proof.codecFacts?.sampleRate == inspection.sampleRate,
                  proof.codecFacts?.sampleCount == inspection.sampleCount,
                  proof.codecFacts?.channelCount == inspection.channelCount,
                  proof.codecFacts?.eac3BlockCount == inspection.blockCount else {
                throw EAC3AccessUnitAssemblyFailure.invalidSyncframe
            }
            if inspection.blockCount < 6 {
                if inspection.convsync != (index == 0) {
                    hasValidOrderingAndStart = false
                }
            } else if inspection.convsync != nil {
                hasValidOrderingAndStart = false
            }
            let signature = try EAC3InvariantSignature(inspection: inspection)
            guard invariant == nil || invariant == signature else {
                throw EAC3AccessUnitAssemblyFailure.invariantDrift
            }
            invariant = signature
            let (nextBlocks, overflow) = totalBlocks.addingReportingOverflow(inspection.blockCount)
            guard !overflow, nextBlocks <= 6 else {
                throw EAC3AccessUnitAssemblyFailure.blockCountMismatch
            }
            totalBlocks = nextBlocks
            expectedPTS = CMTimeAdd(
                member.inputUnit.presentationTimeStamp,
                CMTime(value: Int64(inspection.sampleCount), timescale: inspection.sampleRate)
            )
            payload.append(member.inputUnit.bytes)
        }
        guard let first = orderedMembers.first,
              let signature = invariant,
              try outputBacking.data(in: outputByteRange) == payload else {
            throw EAC3AccessUnitAssemblyFailure.blockCountMismatch
        }
        let actualRate = try EAC3AccessUnitAssembler.checkedDataRateKbps(
            byteCount: payload.count,
            sampleRate: signature.sampleRate
        )
        try EAC3AccessUnitAssembler.validateActualDataRateKbps(actualRate)

        self.authorization = authorization
        self.partialIdentity = partialIdentity
        self.orderedMembers = orderedMembers
        self.outputBacking = outputBacking
        self.outputByteRange = outputByteRange
        self.outputDigest = outputDigest
        self.bundleIdentity = bundleIdentity
        blockCount = totalBlocks
        sampleRate = signature.sampleRate
        channelCount = signature.channelCount
        firstPresentationTimeStamp = first.inputUnit.presentationTimeStamp
        duration = CMTime(value: 1_536, timescale: signature.sampleRate)
        actualDataRateKbps = actualRate
        self.hasValidOrderingAndStart = hasValidOrderingAndStart
    }

    private init(
        replacing request: Self,
        outputBacking: EAC3AccessUnitBacking,
        outputByteRange: AudioServiceByteRange,
        outputDigest: AudioServiceEvidenceDigest
    ) {
        authorization = request.authorization
        partialIdentity = request.partialIdentity
        orderedMembers = request.orderedMembers
        self.outputBacking = outputBacking
        self.outputByteRange = outputByteRange
        self.outputDigest = outputDigest
        bundleIdentity = request.bundleIdentity
        blockCount = request.blockCount
        sampleRate = request.sampleRate
        channelCount = request.channelCount
        firstPresentationTimeStamp = request.firstPresentationTimeStamp
        duration = request.duration
        actualDataRateKbps = request.actualDataRateKbps
        hasValidOrderingAndStart = request.hasValidOrderingAndStart
    }

    func replacingOutput(
        backing: EAC3AccessUnitBacking,
        range: AudioServiceByteRange,
        digest: AudioServiceEvidenceDigest
    ) -> Self {
        Self(replacing: self, outputBacking: backing, outputByteRange: range, outputDigest: digest)
    }
}

private struct EAC3PartialMember {
    let inputUnit: AudioServiceInputUnit
    let proof: AdmittedAudioServiceInputUnitProof
    let leaseIdentity: AudioServiceBranchLeaseIdentity
    let inspection: EAC3FrameInspection
}

/// 六个字段就是 partial 的全部成员容量，不建立按 syncframe 增长的旁路账本。
private struct EAC3PartialMemberSlots {
    private var member0: EAC3PartialMember?
    private var member1: EAC3PartialMember?
    private var member2: EAC3PartialMember?
    private var member3: EAC3PartialMember?
    private var member4: EAC3PartialMember?
    private var member5: EAC3PartialMember?
    private(set) var count = 0

    mutating func append(_ member: EAC3PartialMember) -> Bool {
        guard count < 6 else { return false }
        switch count {
        case 0: member0 = member
        case 1: member1 = member
        case 2: member2 = member
        case 3: member3 = member
        case 4: member4 = member
        case 5: member5 = member
        default: return false
        }
        count += 1
        return true
    }

    var values: [EAC3PartialMember] {
        [member0, member1, member2, member3, member4, member5].compactMap { $0 }
    }

    mutating func removeAll() {
        member0 = nil
        member1 = nil
        member2 = nil
        member3 = nil
        member4 = nil
        member5 = nil
        count = 0
    }
}

private struct EAC3InvariantSignature: Equatable {
    let sampleRate: Int32
    let channelCount: Int32
    let bsid: UInt8
    let bsmod: UInt8
    let audioCodingMode: UInt8
    let hasLFE: Bool

    init(inspection: EAC3FrameInspection) throws {
        guard let bsmod = inspection.bsmod else {
            throw EAC3AccessUnitAssemblyFailure.invalidSyncframe
        }
        sampleRate = inspection.sampleRate
        channelCount = inspection.channelCount
        bsid = inspection.bsid
        self.bsmod = bsmod
        audioCodingMode = inspection.acmod
        hasLFE = inspection.lfeon
    }

    init(
        sampleRate: Int32,
        channelCount: Int32,
        bsid: UInt8,
        bsmod: UInt8,
        audioCodingMode: UInt8,
        hasLFE: Bool
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bsid = bsid
        self.bsmod = bsmod
        self.audioCodingMode = audioCodingMode
        self.hasLFE = hasLFE
    }
}

final class EAC3AccessUnitAssembler {
    private let coordinator: AudioServiceSemanticCoordinator
    private let authorization: CompressedAudioCandidatePlanAuthorization
    private let admissionIdentity: AudioBranchAdmissionIdentity
    private let allocator: PlaybackIdentityAllocator
    private var partialIdentity: PartialAudioAggregationIdentity?
    private var members = EAC3PartialMemberSlots()
    private var blockCount = 0
    private var invariant: EAC3InvariantSignature?
    private(set) var producedAccessUnitCount = 0
    private(set) var appendCallCount = 0
    private(set) var failure: EAC3AccessUnitAssemblyFailure?

    init(
        coordinator: AudioServiceSemanticCoordinator,
        authorization: CompressedAudioCandidatePlanAuthorization,
        allocator: PlaybackIdentityAllocator
    ) {
        self.coordinator = coordinator
        self.authorization = authorization
        admissionIdentity = authorization.admissionIdentity
        self.allocator = allocator
    }

    var heldLeaseCount: Int { members.count }

    var retainedInputByteCount: Int {
        members.values.reduce(0) { $0 + $1.inputUnit.byteRange.length }
    }

    func append(
        inputUnit: AudioServiceInputUnit,
        admittedProof: AdmittedAudioServiceInputUnitProof,
        aggregationLease: AudioServiceBranchLease
    ) throws -> CompressedAudioAccessUnit? {
        appendCallCount += 1
        if let failure { throw failure }
        do {
            let inspection = try validate(
                inputUnit: inputUnit,
                admittedProof: admittedProof,
                aggregationLease: aggregationLease
            )
            let currentSignature = try signature(for: inspection)
            if let invariant, invariant != currentSignature {
                throw EAC3AccessUnitAssemblyFailure.invariantDrift
            }
            if invariant == nil { invariant = currentSignature }

            let (nextBlockCount, overflow) = blockCount.addingReportingOverflow(inspection.blockCount)
            guard !overflow, nextBlockCount <= 6 else {
                throw EAC3AccessUnitAssemblyFailure.blockCountMismatch
            }
            let partial: PartialAudioAggregationIdentity
            if let partialIdentity {
                partial = partialIdentity
            } else {
                partial = PartialAudioAggregationIdentity(rawValue: try allocator.next(in: .nonce))
                partialIdentity = partial
            }
            guard coordinator.holdEAC3AggregationLease(
                aggregationLease.identity,
                partial: partial
            ) == .held else {
                throw EAC3AccessUnitAssemblyFailure.leaseTransitionFailed
            }
            guard members.append(EAC3PartialMember(
                inputUnit: inputUnit,
                proof: admittedProof,
                leaseIdentity: aggregationLease.identity,
                inspection: inspection
            )) else {
                throw EAC3AccessUnitAssemblyFailure.memberCapacityExceeded
            }
            blockCount = nextBlockCount
            guard blockCount == 6 else { return nil }
            return try finishAccessUnit()
        } catch let error as EAC3AccessUnitAssemblyFailure {
            failCandidate(error)
            throw error
        } catch {
            let failure = EAC3AccessUnitAssemblyFailure.invalidSyncframe
            failCandidate(failure)
            throw failure
        }
    }

    func terminate(_ reason: EAC3AggregationTerminationReason) {
        guard failure == nil else { return }
        failCandidate(.terminated(reason))
    }

    private func validate(
        inputUnit: AudioServiceInputUnit,
        admittedProof: AdmittedAudioServiceInputUnitProof,
        aggregationLease: AudioServiceBranchLease
    ) throws -> EAC3FrameInspection {
        guard authorization.codec == .eac3,
              case .eac3Aggregation = admissionIdentity,
              coordinator.acceptsCompressedAuthorization(authorization),
              aggregationLease.identity.admissionIdentity == admissionIdentity else {
            throw EAC3AccessUnitAssemblyFailure.invalidAdmissionIdentity
        }
        let proof = admittedProof.identity.proofIdentity
        let digest = try inputUnit.backing.digest(in: inputUnit.byteRange)
        guard proof.observedSemantic == .independentMain,
              proof.unitKind == .eac3Syncframe,
              proof.inputUnitIdentity == inputUnit.identity,
              proof.backingIdentity == inputUnit.backing.identity,
              proof.backingOwnerIdentity === inputUnit.backing.ownerIdentity,
              proof.byteRange == inputUnit.byteRange,
              proof.evidenceDigest == digest,
              aggregationLease.identity.proofIdentity == admittedProof.identity,
              coordinator.branchLeaseState(aggregationLease.identity) == .available else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        let inspection = try EAC3FrameInspector.inspect(inputUnit.bytes)
        guard proof.codecFacts?.profileID == .eac3,
              proof.codecFacts?.sampleRate == inspection.sampleRate,
              proof.codecFacts?.sampleCount == inspection.sampleCount,
              proof.codecFacts?.channelCount == inspection.channelCount,
              proof.codecFacts?.eac3BlockCount == inspection.blockCount else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        guard inspection.streamType == .independent,
              inspection.substreamID == 0 else {
            throw EAC3AccessUnitAssemblyFailure.unsupportedSubstream
        }
        guard inspection.hasJOC == false,
              let bsmod = inspection.bsmod,
              bsmod == 0 else {
            throw EAC3AccessUnitAssemblyFailure.invalidSyncframe
        }
        if inspection.blockCount < 6 {
            if members.count == 0 {
                guard inspection.convsync == true else {
                    throw EAC3AccessUnitAssemblyFailure.invalidAccessUnitStart
                }
            } else {
                guard inspection.convsync == false else {
                    throw EAC3AccessUnitAssemblyFailure.invalidAccessUnitStart
                }
            }
        } else if inspection.convsync != nil {
            throw EAC3AccessUnitAssemblyFailure.invalidAccessUnitStart
        }
        guard inputUnit.presentationTimeStamp.isNumeric,
              inputUnit.presentationTimeStamp.epoch == 0 else {
            throw EAC3AccessUnitAssemblyFailure.discontinuousMember
        }
        if let previous = members.values.last {
            let expected = CMTimeAdd(
                previous.inputUnit.presentationTimeStamp,
                CMTime(
                    value: Int64(previous.inspection.sampleCount),
                    timescale: previous.inspection.sampleRate
                )
            )
            guard CMTimeCompare(inputUnit.presentationTimeStamp, expected) == 0 else {
                throw EAC3AccessUnitAssemblyFailure.discontinuousMember
            }
        } else if !coordinator.acceptsNextCompressedPresentationStart(
            inputUnit.presentationTimeStamp,
            authorization: authorization
        ) {
            throw EAC3AccessUnitAssemblyFailure.discontinuousMember
        }
        return inspection
    }

    private func signature(for inspection: EAC3FrameInspection) throws -> EAC3InvariantSignature {
        guard let bsmod = inspection.bsmod else {
            throw EAC3AccessUnitAssemblyFailure.invalidSyncframe
        }
        return EAC3InvariantSignature(
            sampleRate: inspection.sampleRate,
            channelCount: inspection.channelCount,
            bsid: inspection.bsid,
            bsmod: bsmod,
            audioCodingMode: inspection.acmod,
            hasLFE: inspection.lfeon
        )
    }

    private func finishAccessUnit() throws -> CompressedAudioAccessUnit {
        let collected = members.values
        guard collected.count == members.count, blockCount == 6,
              let first = collected.first, let invariant, let partialIdentity else {
            throw EAC3AccessUnitAssemblyFailure.blockCountMismatch
        }
        var payload = Data()
        let totalLength = collected.reduce(0) { $0 + $1.inputUnit.byteRange.length }
        payload.reserveCapacity(totalLength)
        for member in collected { payload.append(member.inputUnit.bytes) }
        let actualDataRateKbps = try Self.checkedDataRateKbps(
            byteCount: payload.count,
            sampleRate: invariant.sampleRate
        )
        try Self.validateActualDataRateKbps(actualDataRateKbps)

        let backing = EAC3AccessUnitBacking(
            identity: .init(rawValue: try allocator.next(in: .resource)),
            bytes: payload
        )
        let range = AudioServiceByteRange(offset: 0, length: payload.count)!
        let digest = payload.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:))
        let accessUnitIdentity = EAC3AccessUnitIdentity(rawValue: try allocator.next(in: .nonce))
        let bundleNonce = CompressedAccessUnitBundleNonce(rawValue: try allocator.next(in: .nonce))
        let aggregationNonce = try allocator.next(in: .nonce)
        let bundle = EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: accessUnitIdentity,
            audioBranchAdmissionIdentity: admissionIdentity,
            outputBackingIdentity: backing.identity,
            outputBackingOwnerIdentity: backing.ownerIdentity,
            outputByteRange: range,
            outputDigest: digest,
            bundleNonce: bundleNonce
        )
        let proofIdentities = try FixedEAC3MemberVector(collected.map { $0.proof.identity })
        let leaseIdentities = try FixedEAC3MemberVector(collected.map { $0.leaseIdentity })
        let duration = CMTime(value: 1_536, timescale: invariant.sampleRate)
        // asvc 由已准入且逐帧复核的 independent main 服务语义推导为零；data_rate
        // 来自 parser 支持域的保守上界，不把首个 AU 或调用方标量冒充媒体峰值。
        let configuration = CompressedAudioFormatConfiguration.eac3(
            try EAC3CompressedAudioConfiguration(
                sampleRate: invariant.sampleRate,
                bsid: invariant.bsid,
                bsmod: invariant.bsmod,
                audioCodingMode: invariant.audioCodingMode,
                hasLFE: invariant.hasLFE,
                asvc: false,
                maximumDataRateKbps: Self.trustedParserDomainMaximumDataRateKbps
            )
        )
        let aggregationProof = EAC3AccessUnitAggregationProof(
            parentReceiptIdentity: first.proof.identity.proofIdentity.parentReceiptIdentity,
            inputFormatGeneration: first.proof.identity.proofIdentity.inputFormatGeneration,
            audioBranchAdmissionIdentity: admissionIdentity,
            accessUnitIdentity: bundle.accessUnitIdentity,
            eac3AccessUnitBundleIdentity: bundle,
            orderedSyncframeProofIdentities: proofIdentities,
            orderedAggregationLeaseIdentities: leaseIdentities,
            outputBackingIdentity: backing.identity,
            outputBackingOwnerIdentity: backing.ownerIdentity,
            outputByteRange: range,
            outputDigest: digest,
            blockCount: 6,
            sampleCount: 1_536,
            firstPresentationTimeStamp: first.inputUnit.presentationTimeStamp,
            duration: duration,
            actualDataRateKbps: actualDataRateKbps,
            aggregationNonce: aggregationNonce
        )
        let result = try CompressedAudioAccessUnit.eac3(
            backing: backing,
            proof: aggregationProof,
            sampleRate: invariant.sampleRate,
            channelCount: invariant.channelCount,
            configuration: configuration,
            authorization: authorization
        )
        let commitRequest = try EAC3SealedCommitRequest(
            authorization: authorization,
            partialIdentity: partialIdentity,
            orderedMembers: collected.map {
                EAC3SealedCommitMember(
                    inputUnit: $0.inputUnit,
                    admittedProof: $0.proof,
                    leaseIdentity: $0.leaseIdentity
                )
            },
            outputBacking: backing,
            outputByteRange: range,
            outputDigest: digest,
            bundleIdentity: bundle
        )
        // 此 CAS 是本方法最后一个可失败点；成功后只清空固定槽并返回既成 AU。
        guard coordinator.commitSealedEAC3AccessUnit(commitRequest) == .transferred else {
            throw EAC3AccessUnitAssemblyFailure.leaseTransitionFailed
        }
        members.removeAll()
        blockCount = 0
        self.partialIdentity = nil
        producedAccessUnitCount += 1
        return result
    }

    static func checkedDataRateKbps(byteCount: Int, sampleRate: Int32) throws -> UInt16 {
        guard byteCount > 0, sampleRate > 0 else {
            throw EAC3AccessUnitAssemblyFailure.invalidSyncframe
        }
        let (bits, bitsOverflow) = UInt64(byteCount).multipliedReportingOverflow(by: 8)
        let (scaled, scaledOverflow) = bits.multipliedReportingOverflow(by: UInt64(sampleRate))
        let denominator = UInt64(1_536_000)
        guard !bitsOverflow, !scaledOverflow else {
            throw EAC3AccessUnitAssemblyFailure.dataRateExceeded
        }
        let quotient = scaled / denominator
        let rounded = quotient + (scaled % denominator == 0 ? 0 : 1)
        guard let result = UInt16(exactly: rounded), result <= 8_191 else {
            throw EAC3AccessUnitAssemblyFailure.dataRateExceeded
        }
        return result
    }

    /// 六个最大 4,096-byte syncframe 在 48 kHz/1,536 samples 下的可解析上界。
    static let trustedParserDomainMaximumDataRateKbps: UInt16 = 6_144

    static func validateActualDataRateKbps(_ actual: UInt16) throws {
        guard actual > 0, actual <= trustedParserDomainMaximumDataRateKbps else {
            throw EAC3AccessUnitAssemblyFailure.dataRateExceeded
        }
    }

    private func failCandidate(_ cause: EAC3AccessUnitAssemblyFailure) {
        if failure == nil { failure = cause }
        _ = coordinator.closeCompressedGate(admissionIdentity)
        members.removeAll()
        blockCount = 0
        invariant = nil
        partialIdentity = nil
    }
}
