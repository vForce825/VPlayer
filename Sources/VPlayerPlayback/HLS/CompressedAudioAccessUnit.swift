// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum CompressedAudioAccessUnitKind: UInt8, Sendable, Hashable {
    case ac3Direct = 1
    case eac3Aggregated = 2
}

enum EAC3AccessUnitAssemblyFailure: Error, Sendable, Equatable {
    case invalidAdmissionIdentity
    case invalidInputIdentity
    case invalidSyncframe
    case invalidAccessUnitStart
    case discontinuousMember
    case unsupportedSubstream
    case invariantDrift
    case blockCountMismatch
    case dataRateExceeded
    case memberCapacityExceeded
    case leaseTransitionFailed
    case terminated(EAC3AggregationTerminationReason)
}

struct FixedEAC3MemberVector<Element: Sendable & Hashable>: Sendable, Hashable {
    static var capacity: Int { 6 }

    private let value0: Element?
    private let value1: Element?
    private let value2: Element?
    private let value3: Element?
    private let value4: Element?
    private let value5: Element?
    let count: Int

    init(_ values: [Element]) throws {
        guard (1...Self.capacity).contains(values.count) else {
            throw EAC3AccessUnitAssemblyFailure.memberCapacityExceeded
        }
        value0 = values.indices.contains(0) ? values[0] : nil
        value1 = values.indices.contains(1) ? values[1] : nil
        value2 = values.indices.contains(2) ? values[2] : nil
        value3 = values.indices.contains(3) ? values[3] : nil
        value4 = values.indices.contains(4) ? values[4] : nil
        value5 = values.indices.contains(5) ? values[5] : nil
        count = values.count
    }

    var values: [Element] {
        [value0, value1, value2, value3, value4, value5].compactMap { $0 }
    }
}

final class EAC3AccessUnitBacking: @unchecked Sendable {
    let identity: EAC3OutputBackingIdentity
    let ownerIdentity = EAC3OutputBackingOwnerIdentity()
    let byteCount: Int
    let fullRange: AudioServiceByteRange
    let fullDigest: AudioServiceEvidenceDigest
    private let storage: Data

    init(identity: EAC3OutputBackingIdentity, bytes: Data) {
        self.identity = identity
        storage = bytes
        byteCount = bytes.count
        fullRange = AudioServiceByteRange(offset: 0, length: bytes.count)!
        fullDigest = bytes.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:))
    }

    func data(in range: AudioServiceByteRange) throws -> Data {
        guard range.endOffset <= byteCount else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        return storage.subdata(in: range.offset..<range.endOffset)
    }
}

struct EAC3AccessUnitAggregationProof: @unchecked Sendable, Hashable {
    let parentReceiptIdentity: AudioServiceSemanticReceiptIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let audioBranchAdmissionIdentity: AudioBranchAdmissionIdentity
    let accessUnitIdentity: EAC3AccessUnitIdentity
    let eac3AccessUnitBundleIdentity: EAC3AccessUnitBundleIdentity
    let orderedSyncframeProofIdentities: FixedEAC3MemberVector<AdmittedAudioServiceInputUnitProofIdentity>
    let orderedAggregationLeaseIdentities: FixedEAC3MemberVector<AudioServiceBranchLeaseIdentity>
    let outputBackingIdentity: EAC3OutputBackingIdentity
    let outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity
    let outputByteRange: AudioServiceByteRange
    let outputDigest: AudioServiceEvidenceDigest
    let blockCount: Int
    let sampleCount: Int32
    let firstPresentationTimeStamp: CMTime
    let duration: CMTime
    let actualDataRateKbps: UInt16
    let aggregationNonce: UInt64
}

enum CompressedAudioPayloadIdentity: Sendable, Hashable {
    case audioService(AudioServiceBackingIdentity, AudioServiceBackingOwnerIdentity)
    case eac3(EAC3OutputBackingIdentity, EAC3OutputBackingOwnerIdentity)
}

enum CompressedAudioBundleIdentity: Sendable, Hashable {
    case direct(CompressedAccessUnitBundleIdentity)
    case eac3(EAC3AccessUnitBundleIdentity)
}

struct CompressedAudioPayloadSeal: @unchecked Sendable {
    private enum Storage: @unchecked Sendable {
        case direct(AudioServiceInputBacking, AudioServiceByteRange)
        case eac3(EAC3AccessUnitBacking, AudioServiceByteRange)
    }

    private let storage: Storage
    let digest: AudioServiceEvidenceDigest

    static func direct(
        backing: AudioServiceInputBacking,
        range: AudioServiceByteRange,
        digest: AudioServiceEvidenceDigest
    ) throws -> Self {
        let bytes = try backing.data(in: range)
        guard bytes.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:)) == digest else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        return Self(storage: .direct(backing, range), digest: digest)
    }

    static func eac3(
        backing: EAC3AccessUnitBacking,
        range: AudioServiceByteRange,
        digest: AudioServiceEvidenceDigest
    ) throws -> Self {
        let bytes = try backing.data(in: range)
        guard bytes.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:)) == digest else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        return Self(storage: .eac3(backing, range), digest: digest)
    }

    /// backing 与 range 已在封口时验证；这里若失败表示内部不变量被破坏，不能伪装为空 AU。
    var data: Data {
        do {
            switch storage {
            case let .direct(backing, range): return try backing.data(in: range)
            case let .eac3(backing, range): return try backing.data(in: range)
            }
        } catch {
            preconditionFailure("压缩音频 payload 封口后失效")
        }
    }

    var directInputBacking: AudioServiceInputBacking? {
        if case let .direct(backing, _) = storage { return backing }
        return nil
    }
}

struct CompressedAudioAccessUnit: @unchecked Sendable {
    let kind: CompressedAudioAccessUnitKind
    let codec: AudioCodec
    let sampleRate: Int32
    let channelCount: Int32
    let sampleCount: Int32
    let presentationStart: CMTime
    let presentationEnd: CMTime
    let payloadIdentity: CompressedAudioPayloadIdentity
    let payloadRange: AudioServiceByteRange
    let payloadDigest: AudioServiceEvidenceDigest
    let formatConfiguration: CompressedAudioFormatConfiguration
    let admissionIdentity: AudioBranchAdmissionIdentity
    let directBundleIdentity: CompressedAccessUnitBundleIdentity?
    let eac3BundleIdentity: EAC3AccessUnitBundleIdentity?
    let aggregationProof: EAC3AccessUnitAggregationProof?
    let directProofIdentity: AdmittedAudioServiceInputUnitProofIdentity?
    let directLeaseIdentity: AudioServiceBranchLeaseIdentity?
    let authorization: CompressedAudioCandidatePlanAuthorization
    private let payloadSeal: CompressedAudioPayloadSeal

    var framesPerPacket: UInt32 { 1_536 }
    var payload: Data { payloadSeal.data }

    var directInputBacking: AudioServiceInputBacking? {
        payloadSeal.directInputBacking
    }

    var writerSubmission: CompressedAudioWriterSubmission {
        CompressedAudioWriterSubmission(
            accessUnit: self,
            bundleIdentity: directBundleIdentity.map(CompressedAudioBundleIdentity.direct)
                ?? .eac3(eac3BundleIdentity!),
            admissionIdentity: admissionIdentity,
            payloadIdentity: payloadIdentity,
            payloadRange: payloadRange,
            payloadDigest: payloadDigest,
            formatConfiguration: formatConfiguration
        )
    }

    @discardableResult
    func confirmWriterTerminal(using coordinator: AudioServiceSemanticCoordinator) -> Int {
        coordinator.finishCompressedAudioWriterSubmission(writerSubmission)
    }

    static func direct(
        inputUnit: AudioServiceInputUnit,
        proof: AdmittedAudioServiceInputUnitProof,
        lease: AudioServiceBranchLeaseIdentity,
        bundle: CompressedAccessUnitBundleIdentity,
        inspection: AC3FrameInspection,
        configuration: CompressedAudioFormatConfiguration,
        authorization: CompressedAudioCandidatePlanAuthorization
    ) throws -> Self {
        let end = CMTimeAdd(
            inputUnit.presentationTimeStamp,
            CMTime(value: 1_536, timescale: inspection.sampleRate)
        )
        let seal = try CompressedAudioPayloadSeal.direct(
            backing: inputUnit.backing,
            range: inputUnit.byteRange,
            digest: proof.identity.proofIdentity.evidenceDigest
        )
        return Self(
            kind: .ac3Direct,
            codec: .ac3,
            sampleRate: inspection.sampleRate,
            channelCount: inspection.channelCount,
            sampleCount: 1_536,
            presentationStart: inputUnit.presentationTimeStamp,
            presentationEnd: end,
            payloadIdentity: .audioService(inputUnit.backing.identity, inputUnit.backing.ownerIdentity),
            payloadRange: inputUnit.byteRange,
            payloadDigest: proof.identity.proofIdentity.evidenceDigest,
            formatConfiguration: configuration,
            admissionIdentity: bundle.audioBranchAdmissionIdentity,
            directBundleIdentity: bundle,
            eac3BundleIdentity: nil,
            aggregationProof: nil,
            directProofIdentity: proof.identity,
            directLeaseIdentity: lease,
            authorization: authorization,
            payloadSeal: seal
        )
    }

    static func eac3(
        backing: EAC3AccessUnitBacking,
        proof: EAC3AccessUnitAggregationProof,
        sampleRate: Int32,
        channelCount: Int32,
        configuration: CompressedAudioFormatConfiguration,
        authorization: CompressedAudioCandidatePlanAuthorization
    ) throws -> Self {
        let end = CMTimeAdd(proof.firstPresentationTimeStamp, proof.duration)
        let seal = try CompressedAudioPayloadSeal.eac3(
            backing: backing,
            range: proof.outputByteRange,
            digest: proof.outputDigest
        )
        return Self(
            kind: .eac3Aggregated,
            codec: .eac3,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sampleCount: 1_536,
            presentationStart: proof.firstPresentationTimeStamp,
            presentationEnd: end,
            payloadIdentity: .eac3(backing.identity, backing.ownerIdentity),
            payloadRange: proof.outputByteRange,
            payloadDigest: proof.outputDigest,
            formatConfiguration: configuration,
            admissionIdentity: proof.audioBranchAdmissionIdentity,
            directBundleIdentity: nil,
            eac3BundleIdentity: proof.eac3AccessUnitBundleIdentity,
            aggregationProof: proof,
            directProofIdentity: nil,
            directLeaseIdentity: nil,
            authorization: authorization,
            payloadSeal: seal
        )
    }
}

struct CompressedAudioWriterSubmission: @unchecked Sendable {
    let accessUnit: CompressedAudioAccessUnit
    let bundleIdentity: CompressedAudioBundleIdentity
    let admissionIdentity: AudioBranchAdmissionIdentity
    let payloadIdentity: CompressedAudioPayloadIdentity
    let payloadRange: AudioServiceByteRange
    let payloadDigest: AudioServiceEvidenceDigest
    let formatConfiguration: CompressedAudioFormatConfiguration
}

struct CompressedAudioWriterExpectedIdentity: Sendable, Hashable {
    let codec: AudioCodec
    let admissionIdentity: AudioBranchAdmissionIdentity
    let formatConfiguration: CompressedAudioFormatConfiguration

    func accepts(_ submission: CompressedAudioWriterSubmission) -> Bool {
        let unit = submission.accessUnit
        guard unit.codec == codec,
              unit.admissionIdentity == admissionIdentity,
              unit.formatConfiguration == formatConfiguration,
              formatConfiguration.codec == codec,
              formatConfiguration.sampleRate == unit.sampleRate,
              submission.admissionIdentity == admissionIdentity,
              submission.payloadIdentity == unit.payloadIdentity,
              submission.payloadRange == unit.payloadRange,
              submission.payloadDigest == unit.payloadDigest,
              submission.formatConfiguration == formatConfiguration,
              unit.sampleCount == 1_536,
              unit.framesPerPacket == 1_536,
              unit.payload.count == unit.payloadRange.length,
              unit.payload.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:)) == unit.payloadDigest,
              (try? formatConfiguration.validateFinalBoxes([formatConfiguration.serializedBox])) != nil else {
            return false
        }
        switch (unit.kind, submission.bundleIdentity) {
        case let (.ac3Direct, .direct(bundle)):
            guard unit.directBundleIdentity == bundle,
                  unit.eac3BundleIdentity == nil,
                  bundle.audioBranchAdmissionIdentity == admissionIdentity,
                  bundle.byteRange == unit.payloadRange,
                  bundle.digest == unit.payloadDigest,
                  case let .audioService(backing, owner) = unit.payloadIdentity else {
                return false
            }
            guard let proofIdentity = unit.directProofIdentity,
                  let leaseIdentity = unit.directLeaseIdentity,
                  proofIdentity == leaseIdentity.proofIdentity,
                  leaseIdentity.admissionIdentity == admissionIdentity else {
                return false
            }
            let proof = proofIdentity.proofIdentity
            return bundle.inputUnitIdentity == proof.inputUnitIdentity
                && bundle.backingIdentity == backing
                && bundle.backingIdentity == proof.backingIdentity
                && bundle.backingOwnerIdentity === owner
                && bundle.backingOwnerIdentity === proof.backingOwnerIdentity
                && bundle.byteRange == proof.byteRange
                && bundle.digest == proof.evidenceDigest
                && proof.observedSemantic == .independentMain
                && proof.unitKind == .ac3Frame
                && proof.codecFacts?.profileID == .ac3
                && proof.codecFacts?.sampleRate == unit.sampleRate
                && proof.codecFacts?.sampleCount == unit.sampleCount
                && proof.codecFacts?.channelCount == unit.channelCount
        case let (.eac3Aggregated, .eac3(bundle)):
            guard unit.directBundleIdentity == nil,
                  unit.eac3BundleIdentity == bundle,
                  let proof = unit.aggregationProof,
                  proof.eac3AccessUnitBundleIdentity == bundle,
                  proof.audioBranchAdmissionIdentity == admissionIdentity,
                  proof.accessUnitIdentity == bundle.accessUnitIdentity,
                  proof.blockCount == 6,
                  proof.sampleCount == 1_536,
                  proof.firstPresentationTimeStamp == unit.presentationStart,
                  CMTimeCompare(CMTimeAdd(proof.firstPresentationTimeStamp, proof.duration),
                                unit.presentationEnd) == 0,
                  bundle.outputByteRange == unit.payloadRange,
                  bundle.outputDigest == unit.payloadDigest,
                  case let .eac3(backing, owner) = unit.payloadIdentity else {
                return false
            }
            let proofIdentities = proof.orderedSyncframeProofIdentities.values
            let leaseIdentities = proof.orderedAggregationLeaseIdentities.values
            guard (1...6).contains(proofIdentities.count),
                  proofIdentities.count == leaseIdentities.count,
                  bundle.outputBackingIdentity == backing,
                  bundle.outputBackingOwnerIdentity === owner,
                  proof.outputBackingIdentity == backing,
                  proof.outputBackingOwnerIdentity === owner,
                  proof.outputByteRange == unit.payloadRange,
                  proof.outputDigest == unit.payloadDigest,
                  case let .eac3(configuration) = formatConfiguration,
                  proof.actualDataRateKbps <= configuration.maximumDataRateKbps else {
                return false
            }
            var totalBlocks = 0
            for index in proofIdentities.indices {
                let member = proofIdentities[index]
                let memberProof = member.proofIdentity
                let lease = leaseIdentities[index]
                guard lease.proofIdentity == member,
                      lease.admissionIdentity == admissionIdentity,
                      memberProof.parentReceiptIdentity == proof.parentReceiptIdentity,
                      memberProof.inputFormatGeneration == proof.inputFormatGeneration,
                      memberProof.observedSemantic == .independentMain,
                      memberProof.unitKind == .eac3Syncframe,
                      memberProof.codecFacts?.profileID == .eac3,
                      memberProof.codecFacts?.sampleRate == unit.sampleRate,
                      memberProof.codecFacts?.channelCount == unit.channelCount,
                      let memberBlocks = memberProof.codecFacts?.eac3BlockCount else {
                    return false
                }
                let (nextBlocks, overflow) = totalBlocks.addingReportingOverflow(memberBlocks)
                guard !overflow, nextBlocks <= 6 else { return false }
                totalBlocks = nextBlocks
            }
            return totalBlocks == 6
        case (.ac3Direct, .eac3), (.eac3Aggregated, .direct):
            return false
        }
    }
}

final class AC3DirectAccessUnitBuilder {
    private let coordinator: AudioServiceSemanticCoordinator
    private let authorization: CompressedAudioCandidatePlanAuthorization
    private let admissionIdentity: AudioBranchAdmissionIdentity
    private var frozenConfiguration: CompressedAudioFormatConfiguration?

    init(
        coordinator: AudioServiceSemanticCoordinator,
        authorization: CompressedAudioCandidatePlanAuthorization
    ) throws {
        guard authorization.codec == .ac3,
              case .directCompressed = authorization.admissionIdentity,
              coordinator.acceptsCompressedAuthorization(authorization) else {
            throw EAC3AccessUnitAssemblyFailure.invalidAdmissionIdentity
        }
        self.coordinator = coordinator
        self.authorization = authorization
        admissionIdentity = authorization.admissionIdentity
    }

    func makeAccessUnit(
        inputUnit: AudioServiceInputUnit,
        admittedProof: AdmittedAudioServiceInputUnitProof,
        directLease: AudioServiceBranchLease,
        bundleNonce: CompressedAccessUnitBundleNonce
    ) throws -> CompressedAudioAccessUnit {
        guard case .directCompressed = admissionIdentity else {
            return try reject(directLease.identity, failure: .invalidAdmissionIdentity)
        }
        let proof = admittedProof.identity.proofIdentity
        let incomingDigest = try inputUnit.backing.digest(in: inputUnit.byteRange)
        guard proof.observedSemantic == .independentMain,
              proof.unitKind == .ac3Frame,
              proof.inputUnitIdentity == inputUnit.identity,
              proof.backingIdentity == inputUnit.backing.identity,
              proof.backingOwnerIdentity === inputUnit.backing.ownerIdentity,
              proof.byteRange == inputUnit.byteRange,
              proof.evidenceDigest == incomingDigest,
              directLease.identity.proofIdentity == admittedProof.identity,
              directLease.identity.admissionIdentity == admissionIdentity else {
            return try reject(directLease.identity, failure: .invalidInputIdentity)
        }
        let inspection = try AC3FrameInspector.inspect(inputUnit.bytes)
        guard inspection.sampleCount == 1_536,
              proof.codecFacts?.profileID == .ac3,
              proof.codecFacts?.sampleRate == inspection.sampleRate,
              proof.codecFacts?.sampleCount == 1_536,
              proof.codecFacts?.channelCount == inspection.channelCount else {
            return try reject(directLease.identity, failure: .invalidSyncframe)
        }
        let configuration = CompressedAudioFormatConfiguration.ac3(
            try AC3CompressedAudioConfiguration(inspection: inspection)
        )
        if let frozenConfiguration, frozenConfiguration != configuration {
            return try reject(directLease.identity, failure: .invariantDrift)
        }
        let bundle = CompressedAccessUnitBundleIdentity(
            inputUnitIdentity: inputUnit.identity,
            audioBranchAdmissionIdentity: admissionIdentity,
            backingIdentity: inputUnit.backing.identity,
            backingOwnerIdentity: inputUnit.backing.ownerIdentity,
            byteRange: inputUnit.byteRange,
            digest: incomingDigest,
            bundleNonce: bundleNonce
        )
        let result = try CompressedAudioAccessUnit.direct(
            inputUnit: inputUnit,
            proof: admittedProof,
            lease: directLease.identity,
            bundle: bundle,
            inspection: inspection,
            configuration: configuration,
            authorization: authorization
        )
        guard coordinator.commitAuthorizedCompressedLease(
            authorization: authorization,
            inputUnit: inputUnit,
            proof: admittedProof,
            leaseIdentity: directLease.identity,
            bundle: bundle,
            sampleRate: inspection.sampleRate
        ) == .transferred else {
            return try reject(directLease.identity, failure: .leaseTransitionFailed)
        }
        frozenConfiguration = configuration
        return result
    }

    private func reject(
        _ lease: AudioServiceBranchLeaseIdentity,
        failure: EAC3AccessUnitAssemblyFailure
    ) throws -> CompressedAudioAccessUnit {
        _ = coordinator.closeCompressedGate(admissionIdentity)
        _ = coordinator.releaseAudioServiceBranchLease(lease)
        throw failure
    }
}

struct CompressedAudioAccessUnitInterval: Sendable, Hashable {
    let start: CMTime
    let end: CMTime

    init(start: CMTime, end: CMTime) throws {
        guard start.isNumeric, end.isNumeric,
              start.epoch == 0, end.epoch == 0,
              CMTimeCompare(start, end) < 0 else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        self.start = start
        self.end = end
    }
}

enum CompressedAudioOriginEligibleUnit: UInt8, Sendable, Hashable {
    case currentAccessUnit = 1
    case nextAccessUnit = 2
}

enum CompressedAudioCandidateIneligibility: UInt8, Sendable, Hashable {
    case mediaOriginCutsCompressedAccessUnit = 1
}

enum CompressedAudioOriginDecision: Sendable, Hashable {
    case eligible(CompressedAudioOriginEligibleUnit)
    case ineligible(CompressedAudioCandidateIneligibility)
}

struct CompressedAudioCandidateSideEffects: Sendable, Hashable {
    let writerCreations: Int
    let playlistCreations: Int
    let probeCreations: Int
    let bandwidthEvidenceCreations: Int
    let candidateBudgetConsumptions: Int

    static let zero = Self(
        writerCreations: 0,
        playlistCreations: 0,
        probeCreations: 0,
        bandwidthEvidenceCreations: 0,
        candidateBudgetConsumptions: 0
    )
}

struct CompressedAudioOriginPlanIdentity: Sendable, Hashable {
    let codec: AudioCodec
    let itemGeneration: AudioItemGenerationIdentity
    let mediaOrigin: CMTime
    let accessUnitInterval: CompressedAudioAccessUnitInterval?
    let decision: CompressedAudioOriginDecision
}

struct CompressedAudioSideEffectAuthorization: Sendable, Hashable {
    let planIdentity: CompressedAudioOriginPlanIdentity
}

struct CompressedAudioOriginEligibilityPlan: Sendable, Hashable {
    let planIdentity: CompressedAudioOriginPlanIdentity
    let decision: CompressedAudioOriginDecision
    let compressedSideEffectAuthorization: CompressedAudioSideEffectAuthorization?
    let sideEffects: CompressedAudioCandidateSideEffects
    let mayFreezePublicationParticipant: Bool
    let sameChannelAACRemainsEligible: Bool
    let mayReduceChannelCountToKeepCompressedCandidate: Bool

    func authorizes(itemGeneration: AudioItemGenerationIdentity) -> Bool {
        guard planIdentity.itemGeneration == itemGeneration,
              compressedSideEffectAuthorization?.planIdentity == planIdentity,
              case .eligible = decision else { return false }
        return true
    }
}

enum CompressedAudioOriginPlanner {
    static func evaluate(
        codec: AudioCodec,
        accessUnitInterval: CompressedAudioAccessUnitInterval?,
        mediaOrigin: CMTime,
        itemGeneration: AudioItemGenerationIdentity
    ) throws -> CompressedAudioOriginEligibilityPlan {
        guard codec == .ac3 || codec == .eac3,
              mediaOrigin.isNumeric, mediaOrigin.epoch == 0 else {
            throw EAC3AccessUnitAssemblyFailure.invalidInputIdentity
        }
        let decision: CompressedAudioOriginDecision
        if let interval = accessUnitInterval,
           CMTimeCompare(mediaOrigin, interval.start) == 0 {
            decision = .eligible(.currentAccessUnit)
        } else if let interval = accessUnitInterval,
                  CMTimeCompare(mediaOrigin, interval.end) == 0 {
            decision = .eligible(.nextAccessUnit)
        } else {
            decision = .ineligible(.mediaOriginCutsCompressedAccessUnit)
        }
        let identity = CompressedAudioOriginPlanIdentity(
            codec: codec,
            itemGeneration: itemGeneration,
            mediaOrigin: mediaOrigin,
            accessUnitInterval: accessUnitInterval,
            decision: decision
        )
        let eligible: Bool
        if case .eligible = decision { eligible = true } else { eligible = false }
        return CompressedAudioOriginEligibilityPlan(
            planIdentity: identity,
            decision: decision,
            compressedSideEffectAuthorization: eligible
                ? CompressedAudioSideEffectAuthorization(planIdentity: identity)
                : nil,
            sideEffects: .zero,
            mayFreezePublicationParticipant: eligible,
            sameChannelAACRemainsEligible: true,
            mayReduceChannelCountToKeepCompressedCandidate: false
        )
    }
}
