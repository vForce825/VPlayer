// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CryptoKit
import Darwin
import Foundation
import ObjectiveC

enum AudioServiceSemantic: UInt8, Sendable, Hashable, CaseIterable {
    case independentMain = 1
    case associated = 2
    case dvs = 3
    case dependent = 4
    case joc = 5
    case unknown = 6

    static let unsupportedCases: [Self] = [
        .associated, .dvs, .dependent, .joc, .unknown,
    ]
}

enum AudioServiceSemanticFailure: Error, Sendable, Equatable {
    case invalidInputUnit
    case unsupportedAudioServiceSemantic
    case staleProof
    case registryCapacityExceeded
    case identitySpaceExhausted
}

struct AudioSourceTrackIdentity: Sendable, Hashable {
    let streamIndex: Int32
    let trackNonce: UInt64
}

struct AudioInputFormatGeneration: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct AudioServiceInputUnitIdentity: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct AudioServiceBackingIdentity: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct AudioServiceSemanticValidationNonce: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct AudioServiceSemanticProofNonce: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum AudioServiceInputUnitKind: UInt8, Sendable, Hashable {
    case aacAccessUnit = 1
    case ac3Frame = 2
    case eac3Syncframe = 3
    case mpegAudioFrame = 4
}

struct AudioServiceByteRange: Sendable, Hashable {
    let offset: Int
    let length: Int
    let endOffset: Int

    init?(offset: Int, length: Int) {
        guard offset >= 0, length >= 0 else { return nil }
        let (endOffset, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { return nil }
        self.offset = offset
        self.length = length
        self.endOffset = endOffset
    }
}

struct AudioServiceEvidenceDigest: Sendable, Hashable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64

    static let zero = Self(word0: 0, word1: 0, word2: 0, word3: 0)

    private init(word0: UInt64, word1: UInt64, word2: UInt64, word3: UInt64) {
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
        self.word3 = word3
    }

    init(bytes: UnsafeRawBufferPointer) {
        var hasher = SHA256()
        hasher.update(bufferPointer: bytes)
        let digest = hasher.finalize()
        word0 = digest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian }
        word1 = digest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian }
        word2 = digest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self).bigEndian }
        word3 = digest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self).bigEndian }
    }
}

/// proof 持有该对象时，进程内 backing owner 地址不会被释放后复用。
final class AudioServiceBackingOwnerIdentity: @unchecked Sendable, Hashable {
    init() {}

    static func == (lhs: AudioServiceBackingOwnerIdentity, rhs: AudioServiceBackingOwnerIdentity) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// 单个音频最小分类单元的不可变 backing；解析闭包之外不暴露借用指针。
final class AudioServiceInputBacking: @unchecked Sendable {
    let identity: AudioServiceBackingIdentity
    let ownerIdentity = AudioServiceBackingOwnerIdentity()
    let byteCount: Int
    private let storage: Data

    init(identity: AudioServiceBackingIdentity, bytes: Data) {
        self.identity = identity
        storage = bytes
        byteCount = bytes.count
    }

    func data(in range: AudioServiceByteRange) throws -> Data {
        guard range.endOffset <= byteCount else {
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
        return storage.subdata(in: range.offset..<range.endOffset)
    }

    func digest(in range: AudioServiceByteRange) throws -> AudioServiceEvidenceDigest {
        let data = try data(in: range)
        return data.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:))
    }
}

struct AudioServiceInputUnit: @unchecked Sendable {
    let identity: AudioServiceInputUnitIdentity
    let backing: AudioServiceInputBacking
    let byteRange: AudioServiceByteRange
    let presentationTimeStamp: CMTime
    let parserSampleCount: Int32?
    let parserSampleRate: Int32?
    let parserChannelLayout: AudioChannelLayout?
    let containerMarkedCorrupt: Bool

    init(
        identity: AudioServiceInputUnitIdentity,
        backing: AudioServiceInputBacking,
        byteRange: AudioServiceByteRange,
        presentationTimeStamp: CMTime,
        parserSampleCount: Int32?,
        parserSampleRate: Int32?,
        parserChannelLayout: AudioChannelLayout?,
        containerMarkedCorrupt: Bool
    ) throws {
        guard byteRange.length > 0, byteRange.endOffset <= backing.byteCount else {
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
        self.identity = identity
        self.backing = backing
        self.byteRange = byteRange
        self.presentationTimeStamp = presentationTimeStamp
        self.parserSampleCount = parserSampleCount
        self.parserSampleRate = parserSampleRate
        self.parserChannelLayout = parserChannelLayout
        self.containerMarkedCorrupt = containerMarkedCorrupt
    }

    var bytes: Data { try! backing.data(in: byteRange) }

    func framedFrame() throws -> FramedCompressedAudioFrame {
        FramedCompressedAudioFrame(
            payload: try backing.data(in: byteRange),
            presentationTimeStamp: presentationTimeStamp,
            parserSampleCount: parserSampleCount,
            parserSampleRate: parserSampleRate,
            parserChannelLayout: parserChannelLayout,
            containerMarkedCorrupt: containerMarkedCorrupt
        )
    }
}

/// 输入 wrapper 的唯一所有权；迟到、失败与最终分支收敛都只能释放一次。
final class AudioServiceInputUnitOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var releases = 0
    private let onRelease: (@Sendable () -> Void)?

    init(onRelease: (@Sendable () -> Void)? = nil) {
        self.onRelease = onRelease
    }

    var releaseCount: Int { lock.withLock { releases } }

    func release() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard !released else { return nil }
            released = true
            releases += 1
            return onRelease
        }
        callback?()
    }
}

struct AudioTrackRoleReceiptIdentity: Sendable, Hashable {
    let sourceTrackIdentity: AudioSourceTrackIdentity
    let selectedProgramID: Int32?
    let streamIndex: Int32
    let role: DemuxTrackRole?
    let serviceEvidence: DemuxTrackServiceEvidence
    let dispositions: DemuxTrackDisposition
    let audioPrimaryEvidence: DemuxTrackSet.AudioPrimaryEvidence?
    let receiptNonce: UInt64

    init(
        sourceTrackIdentity: AudioSourceTrackIdentity,
        selectedProgramID: Int32?, streamIndex: Int32, role: DemuxTrackRole?,
        serviceEvidence: DemuxTrackServiceEvidence, dispositions: DemuxTrackDisposition,
        audioPrimaryEvidence: DemuxTrackSet.AudioPrimaryEvidence? = nil, receiptNonce: UInt64
    ) {
        self.sourceTrackIdentity = sourceTrackIdentity
        self.selectedProgramID = selectedProgramID
        self.streamIndex = streamIndex
        self.role = role
        self.serviceEvidence = serviceEvidence
        self.dispositions = dispositions
        self.audioPrimaryEvidence = audioPrimaryEvidence
        self.receiptNonce = receiptNonce
    }
}

struct AudioServiceSemanticEvidenceIdentity: Sendable, Hashable {
    let trackRoleReceiptIdentity: AudioTrackRoleReceiptIdentity
    let firstInputUnitIdentity: AudioServiceInputUnitIdentity?
    let headerBackingIdentity: AudioServiceBackingIdentity?
    let headerBackingOwnerIdentity: AudioServiceBackingOwnerIdentity?
    let headerByteRange: AudioServiceByteRange?
    let evidenceDigest: AudioServiceEvidenceDigest
}

struct AudioServiceSemanticReceipt: Sendable, Hashable {
    struct Identity: Sendable, Hashable {
        let sourceTrackIdentity: AudioSourceTrackIdentity
        let inputFormatGeneration: AudioInputFormatGeneration
        let classificationEvidenceIdentity: AudioServiceSemanticEvidenceIdentity
        let semantic: AudioServiceSemantic
        let receiptNonce: UInt64

        func replacing(receiptNonce: UInt64) -> Self {
            Self(
                sourceTrackIdentity: sourceTrackIdentity,
                inputFormatGeneration: inputFormatGeneration,
                classificationEvidenceIdentity: classificationEvidenceIdentity,
                semantic: semantic,
                receiptNonce: receiptNonce
            )
        }
    }

    let sourceTrackIdentity: AudioSourceTrackIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let classificationEvidenceIdentity: AudioServiceSemanticEvidenceIdentity
    let semantic: AudioServiceSemantic
    let receiptNonce: UInt64

    var identity: Identity {
        Identity(
            sourceTrackIdentity: sourceTrackIdentity,
            inputFormatGeneration: inputFormatGeneration,
            classificationEvidenceIdentity: classificationEvidenceIdentity,
            semantic: semantic,
            receiptNonce: receiptNonce
        )
    }
}

typealias AudioServiceSemanticReceiptIdentity = AudioServiceSemanticReceipt.Identity

struct AudioServiceCodecFacts: Sendable, Hashable {
    let profileID: AudioCodecProfileID
    let sampleRate: Int32
    let sampleCount: Int32
    let channelCount: Int32
    let eac3BlockCount: Int?
}

struct AudioServiceSemanticInputUnitProof: Sendable, Hashable {
    let parentReceiptIdentity: AudioServiceSemanticReceiptIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let inputUnitIdentity: AudioServiceInputUnitIdentity
    let unitKind: AudioServiceInputUnitKind
    let backingIdentity: AudioServiceBackingIdentity
    let backingOwnerIdentity: AudioServiceBackingOwnerIdentity
    let byteRange: AudioServiceByteRange
    let evidenceDigest: AudioServiceEvidenceDigest
    let observedSemantic: AudioServiceSemantic
    let validationNonce: AudioServiceSemanticValidationNonce
    let proofNonce: AudioServiceSemanticProofNonce
    let codecFacts: AudioServiceCodecFacts?

    func replacing(
        parentReceiptIdentity: AudioServiceSemanticReceiptIdentity? = nil,
        inputFormatGeneration: AudioInputFormatGeneration? = nil,
        inputUnitIdentity: AudioServiceInputUnitIdentity? = nil,
        unitKind: AudioServiceInputUnitKind? = nil,
        backingIdentity: AudioServiceBackingIdentity? = nil,
        backingOwnerIdentity: AudioServiceBackingOwnerIdentity? = nil,
        byteRange: AudioServiceByteRange? = nil,
        evidenceDigest: AudioServiceEvidenceDigest? = nil,
        observedSemantic: AudioServiceSemantic? = nil,
        validationNonce: AudioServiceSemanticValidationNonce? = nil,
        proofNonce: AudioServiceSemanticProofNonce? = nil
    ) -> Self {
        Self(
            parentReceiptIdentity: parentReceiptIdentity ?? self.parentReceiptIdentity,
            inputFormatGeneration: inputFormatGeneration ?? self.inputFormatGeneration,
            inputUnitIdentity: inputUnitIdentity ?? self.inputUnitIdentity,
            unitKind: unitKind ?? self.unitKind,
            backingIdentity: backingIdentity ?? self.backingIdentity,
            backingOwnerIdentity: backingOwnerIdentity ?? self.backingOwnerIdentity,
            byteRange: byteRange ?? self.byteRange,
            evidenceDigest: evidenceDigest ?? self.evidenceDigest,
            observedSemantic: observedSemantic ?? self.observedSemantic,
            validationNonce: validationNonce ?? self.validationNonce,
            proofNonce: proofNonce ?? self.proofNonce,
            codecFacts: codecFacts
        )
    }
}

struct AdmittedAudioServiceInputUnitProofIdentity: Sendable, Hashable {
    let proofIdentity: AudioServiceSemanticInputUnitProof
    let admissionNonce: UInt64
}

enum AudioServiceDecoderDisposition: Sendable, Equatable {
    case unclaimed
    case leased(AudioServiceBranchLeaseNonce)
    case transferred(DecoderInputOwnerIdentity)
    case released
    case suppressed
}

final class AdmittedAudioServiceInputUnitProof: @unchecked Sendable {
    let identity: AdmittedAudioServiceInputUnitProofIdentity
    let ownership: AudioServiceInputUnitOwnership
    let branchState: AdmittedAudioServiceBranchState
    private let applicationEscrow: AudioServiceApplicationEscrow
    var decoderDisposition: AudioServiceDecoderDisposition = .unclaimed

    init(
        identity: AdmittedAudioServiceInputUnitProofIdentity,
        ownership: AudioServiceInputUnitOwnership,
        branchState: AdmittedAudioServiceBranchState,
        applicationEscrow: AudioServiceApplicationEscrow
    ) {
        self.identity = identity
        self.ownership = ownership
        self.branchState = branchState
        self.applicationEscrow = applicationEscrow
    }

    deinit { applicationEscrow.releaseCredit() }

    static func checkedMaximumRetainedGraphChargeBytes(
        proofBytes: Int,
        branchStateBytes: Int,
        branchParticipationBytes: Int,
        branchLeaseRecordBytes: Int,
        branchPlanCount: Int
    ) -> Int? {
        guard proofBytes >= 0, branchStateBytes >= 0,
              branchParticipationBytes >= 0, branchLeaseRecordBytes >= 0,
              branchPlanCount >= 0 else { return nil }
        let perPlan = branchParticipationBytes.addingReportingOverflow(branchLeaseRecordBytes)
        guard !perPlan.overflow else { return nil }
        let plans = branchPlanCount.multipliedReportingOverflow(by: perPlan.partialValue)
        guard !plans.overflow else { return nil }
        let proofAndState = proofBytes.addingReportingOverflow(branchStateBytes)
        guard !proofAndState.overflow else { return nil }
        let total = proofAndState.partialValue.addingReportingOverflow(plans.partialValue)
        return total.overflow ? nil : total.partialValue
    }

    static var checkedMaximumRetainedGraphChargeBytes: Int? {
        func object(_ type: AnyClass) -> Int {
            malloc_good_size(class_getInstanceSize(type))
        }
        return checkedMaximumRetainedGraphChargeBytes(
            proofBytes: object(AdmittedAudioServiceInputUnitProof.self),
            branchStateBytes: object(AdmittedAudioServiceBranchState.self),
            branchParticipationBytes: object(AudioServiceBranchParticipation.self),
            branchLeaseRecordBytes: object(AudioServiceBranchLeaseRecord.self),
            branchPlanCount: AudioServiceRegistryCapacity.branchPlansPerProof
        )
    }
}

enum AudioServiceProofAdmissionOutcome: Sendable, Equatable {
    case admitted(AdmittedAudioServiceInputUnitProof)
    case failed(AudioServiceSemanticFailure)
    case ignored

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.admitted(left), .admitted(right)): left === right
        case let (.failed(left), .failed(right)): left == right
        case (.ignored, .ignored): true
        default: false
        }
    }

    var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }
}

/// 服务 receipt、逐单元 proof 与后续 branch registry 共用这一把 CAS 锁和 allocator。
final class AudioServiceSemanticCoordinator: @unchecked Sendable {
    private struct ExpectedValidation {
        let inputUnitIdentity: AudioServiceInputUnitIdentity
        let unitKind: AudioServiceInputUnitKind
        let backingIdentity: AudioServiceBackingIdentity
        let backingOwnerIdentity: AudioServiceBackingOwnerIdentity
        let byteRange: AudioServiceByteRange
        let evidenceDigest: AudioServiceEvidenceDigest
        let nonce: AudioServiceSemanticValidationNonce
        var issuedProof: AudioServiceSemanticInputUnitProof?
        var admitted: AdmittedAudioServiceInputUnitProof?
    }

    let source: AudioTrackDescriptor
    let sourceTrackIdentity: AudioSourceTrackIdentity
    let inputFormatGeneration: AudioInputFormatGeneration
    let compressedOutputAdmissionAuthority: AudioBranchAdmissionIdentity?
    let allocator: PlaybackIdentityAllocator
    let audioServiceLeaseState: AudioServiceLeaseState
    let sharedControlExecutor: PlaybackControlExecutor?
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private let isolatedTestLock = NSLock()

    private var receipt: AudioServiceSemanticReceipt?
    private var expectedValidation: ExpectedValidation?
    private var storedFailure: AudioServiceSemanticFailure?
    private var publishedFailureCount = 0

    init(
        source: AudioTrackDescriptor,
        sourceTrackIdentity: AudioSourceTrackIdentity,
        inputFormatGeneration: AudioInputFormatGeneration,
        allocator: PlaybackIdentityAllocator,
        compressedOutputAdmissionAuthority: AudioBranchAdmissionIdentity? = nil,
        sharedControlExecutor: PlaybackControlExecutor? = nil,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared
    ) {
        self.source = source
        self.sourceTrackIdentity = sourceTrackIdentity
        self.inputFormatGeneration = inputFormatGeneration
        self.compressedOutputAdmissionAuthority = compressedOutputAdmissionAuthority
        self.allocator = allocator
        self.sharedControlExecutor = sharedControlExecutor
        self.applicationLedger = applicationLedger
        audioServiceLeaseState = AudioServiceLeaseState(applicationLedger: applicationLedger)
    }

    var failure: AudioServiceSemanticFailure? { withAudioServiceCAS { storedFailure } }
    var failurePublicationCount: Int { withAudioServiceCAS { publishedFailureCount } }
    var receiptCommitIsValid: Bool { withAudioServiceCAS { receipt != nil && storedFailure == nil } }

    func establishReceipt(
        selectedProgramID: Int32?,
        firstInputUnit: AudioServiceInputUnit?,
        audioPrimaryEvidence: DemuxTrackSet.AudioPrimaryEvidence? = nil
    ) throws -> AudioServiceSemanticReceipt {
        try withAudioServiceCAS {
            if let receipt { return receipt }
            guard source.streamIndex == sourceTrackIdentity.streamIndex else {
                throw AudioServiceSemanticFailure.invalidInputUnit
            }
            let receiptNonce = try nextIdentity(in: .nonce)
            let trackRole = AudioTrackRoleReceiptIdentity(
                sourceTrackIdentity: sourceTrackIdentity,
                selectedProgramID: selectedProgramID,
                streamIndex: source.streamIndex,
                role: source.metadata.role,
                serviceEvidence: source.metadata.serviceEvidence,
                dispositions: source.metadata.dispositions,
                audioPrimaryEvidence: audioPrimaryEvidence,
                receiptNonce: try nextIdentity(in: .nonce)
            )
            let headerUnit = Self.requiresHeaderSemantic(source.codec) ? firstInputUnit : nil
            if Self.requiresHeaderSemantic(source.codec), headerUnit == nil {
                throw AudioServiceSemanticFailure.invalidInputUnit
            }
            let digest: AudioServiceEvidenceDigest
            if let headerUnit {
                digest = try headerUnit.backing.digest(in: headerUnit.byteRange)
            } else {
                var canonical = Data("VPlayer.AudioTrackRoleReceipt.v1".utf8)
                withUnsafeBytes(of: trackRole.receiptNonce.bigEndian) { canonical.append(contentsOf: $0) }
                digest = canonical.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:))
            }
            let evidence = AudioServiceSemanticEvidenceIdentity(
                trackRoleReceiptIdentity: trackRole,
                firstInputUnitIdentity: headerUnit?.identity,
                headerBackingIdentity: headerUnit?.backing.identity,
                headerBackingOwnerIdentity: headerUnit?.backing.ownerIdentity,
                headerByteRange: headerUnit?.byteRange,
                evidenceDigest: digest
            )
            let headerSemantic = try headerUnit.map {
                try Self.headerSemantic(for: source.codec, bytes: $0.backing.data(in: $0.byteRange))
            }
            let semantic = Self.combine(
                container: Self.containerSemantic(
                    metadata: source.metadata,
                    selectedProgramID: selectedProgramID,
                    audioPrimaryEvidence: audioPrimaryEvidence,
                    selectedStreamIndex: source.streamIndex
                ),
                header: headerSemantic
            )
            let result = AudioServiceSemanticReceipt(
                sourceTrackIdentity: sourceTrackIdentity,
                inputFormatGeneration: inputFormatGeneration,
                classificationEvidenceIdentity: evidence,
                semantic: semantic,
                receiptNonce: receiptNonce
            )
            receipt = result
            return result
        }
    }

    func installValidation(
        for unit: AudioServiceInputUnit
    ) throws -> AudioServiceSemanticValidationNonce {
        try withAudioServiceCAS {
            guard receipt != nil, storedFailure == nil else {
                throw AudioServiceSemanticFailure.invalidInputUnit
            }
            let framed = try unit.framedFrame()
            _ = try SupportedAudioInputDomain.inspect(framed, source: source)
            let nonce = AudioServiceSemanticValidationNonce(rawValue: try nextIdentity(in: .nonce))
            expectedValidation = ExpectedValidation(
                inputUnitIdentity: unit.identity,
                unitKind: Self.unitKind(for: source.codec),
                backingIdentity: unit.backing.identity,
                backingOwnerIdentity: unit.backing.ownerIdentity,
                byteRange: unit.byteRange,
                evidenceDigest: try unit.backing.digest(in: unit.byteRange),
                nonce: nonce,
                issuedProof: nil,
                admitted: nil
            )
            return nonce
        }
    }

    func makeProof(
        for unit: AudioServiceInputUnit,
        validationNonce: AudioServiceSemanticValidationNonce
    ) throws -> AudioServiceSemanticInputUnitProof {
        try withAudioServiceCAS {
            let incomingDigest = try unit.backing.digest(in: unit.byteRange)
            guard let receipt, storedFailure == nil,
                  var expected = expectedValidation,
                  expected.inputUnitIdentity == unit.identity,
                  expected.unitKind == Self.unitKind(for: source.codec),
                  expected.backingIdentity == unit.backing.identity,
                  expected.backingOwnerIdentity === unit.backing.ownerIdentity,
                  expected.byteRange == unit.byteRange,
                  expected.evidenceDigest == incomingDigest,
                  expected.nonce == validationNonce else {
                throw AudioServiceSemanticFailure.staleProof
            }
            if let proof = expected.issuedProof { return proof }
            let inspected = try SupportedAudioInputDomain.inspect(unit.framedFrame(), source: source)
            let observedHeader = try Self.requiresHeaderSemantic(source.codec)
                ? Self.headerSemantic(for: source.codec, bytes: unit.backing.data(in: unit.byteRange))
                : nil
            let observed = Self.combine(container: receipt.semantic, header: observedHeader)
            let sampleCount = inspected.sampleCount
            let proof = AudioServiceSemanticInputUnitProof(
                parentReceiptIdentity: receipt.identity,
                inputFormatGeneration: inputFormatGeneration,
                inputUnitIdentity: unit.identity,
                unitKind: expected.unitKind,
                backingIdentity: unit.backing.identity,
                backingOwnerIdentity: unit.backing.ownerIdentity,
                byteRange: unit.byteRange,
                evidenceDigest: expected.evidenceDigest,
                observedSemantic: observed,
                validationNonce: validationNonce,
                proofNonce: AudioServiceSemanticProofNonce(rawValue: try nextIdentity(in: .nonce)),
                codecFacts: AudioServiceCodecFacts(
                    profileID: inspected.profileID,
                    sampleRate: inspected.sampleRate,
                    sampleCount: sampleCount,
                    channelCount: inspected.channelCount,
                    eac3BlockCount: source.codec == .eac3 ? Int(sampleCount / 256) : nil
                )
            )
            expected.issuedProof = proof
            expectedValidation = expected
            return proof
        }
    }

    func admit(
        _ proof: AudioServiceSemanticInputUnitProof,
        ownership: AudioServiceInputUnitOwnership
    ) -> AudioServiceProofAdmissionOutcome {
        let decision: (
            outcome: AudioServiceProofAdmissionOutcome,
            releaseIncomingOwnership: Bool,
            revokedOwnerships: [AudioServiceInputUnitOwnership]
        ) = withAudioServiceCAS {
            guard storedFailure == nil,
                  let receipt,
                  var expected = expectedValidation,
                  let issued = expected.issuedProof,
                  proof == issued,
                  proof.parentReceiptIdentity == receipt.identity,
                  proof.inputFormatGeneration == inputFormatGeneration else {
                return (.ignored, !audioServiceLeaseState.containsAdmittedOwnership(ownership), [])
            }
            if let admitted = expected.admitted {
                return (.ignored, admitted.ownership !== ownership, [])
            }
            guard proof.observedSemantic == .independentMain else {
                let revokedOwnerships = revokeAudioServiceGenerationForUnsupportedSemantic()
                self.receipt = nil
                storedFailure = .unsupportedAudioServiceSemantic
                publishedFailureCount += 1
                return (.failed(.unsupportedAudioServiceSemantic), true, revokedOwnerships)
            }
            guard audioServiceLeaseState.hasAdmittedProofSpace else {
                return (.failed(.registryCapacityExceeded), true, [])
            }
            guard let applicationEscrow = audioServiceLeaseState.applicationEscrow,
                  applicationEscrow.claimCredit() else {
                return (.failed(.registryCapacityExceeded),
                        !audioServiceLeaseState.containsAdmittedOwnership(ownership), [])
            }
            let branchState = AdmittedAudioServiceBranchState()
            let admitted = AdmittedAudioServiceInputUnitProof(
                identity: AdmittedAudioServiceInputUnitProofIdentity(
                    proofIdentity: proof,
                    admissionNonce: (try? nextIdentity(in: .nonce)) ?? 0
                ),
                ownership: ownership,
                branchState: branchState,
                applicationEscrow: applicationEscrow
            )
            guard admitted.identity.admissionNonce != 0 else {
                storedFailure = .identitySpaceExhausted
                publishedFailureCount += 1
                self.receipt = nil
                return (.failed(.identitySpaceExhausted), true, [])
            }
            precondition(audioServiceLeaseState.registerAdmittedProof(admitted))
            expected.admitted = admitted
            expectedValidation = expected
            return (.admitted(admitted), false, [])
        }
        if decision.releaseIncomingOwnership { ownership.release() }
        decision.revokedOwnerships.forEach { $0.release() }
        return decision.outcome
    }

    func withAudioServiceCAS<Result>(_ body: () throws -> Result) rethrows -> Result {
        if let sharedControlExecutor {
            return try sharedControlExecutor.sync(body)
        }
        // Task22接线前的独立单测不构造完整控制器；仍以同一把锁保持完全线性化。
        isolatedTestLock.lock()
        defer { isolatedTestLock.unlock() }
        return try body()
    }

    func nextIdentity(in namespace: PlaybackIdentityNamespace) throws -> UInt64 {
        do { return try allocator.next(in: namespace) }
        catch { throw AudioServiceSemanticFailure.identitySpaceExhausted }
    }

    /// 仅供同一CAS中的branch/PCM实现验证，不返回可在锁外复用的授权。
    func isCurrentAdmittedProof(_ proof: AdmittedAudioServiceInputUnitProof) -> Bool {
        guard storedFailure == nil,
              let receipt,
              audioServiceLeaseState.isRegistered(proof),
              !proof.branchState.isGenerationRevoked else { return false }
        return proof.identity.proofIdentity.parentReceiptIdentity == receipt.identity
            && proof.identity.proofIdentity.inputFormatGeneration == inputFormatGeneration
    }

    /// 只在同一CAS内部查询；失败后新gate、lease和bundle都不得再建立。
    func hasCurrentAudioServiceGenerationAuthority() -> Bool {
        storedFailure == nil && receipt != nil
    }

    private static func unitKind(for codec: AudioCodec) -> AudioServiceInputUnitKind {
        switch codec {
        case .aac: .aacAccessUnit
        case .ac3: .ac3Frame
        case .eac3: .eac3Syncframe
        case .mp1, .mp2, .mp3: .mpegAudioFrame
        }
    }

    private static func requiresHeaderSemantic(_ codec: AudioCodec) -> Bool {
        codec == .ac3 || codec == .eac3
    }

    private static func headerSemantic(for codec: AudioCodec, bytes: Data) throws -> AudioServiceSemantic {
        switch codec {
        case .ac3:
            return semantic(forBSMod: try AC3FrameInspector.inspect(bytes).bsmod)
        case .eac3:
            let info = try EAC3FrameInspector.inspect(bytes)
            guard info.streamType == .independent else {
                return info.streamType == .dependent ? .dependent : .unknown
            }
            if info.hasJOC == true { return .joc }
            guard info.hasJOC == false else { return .unknown }
            guard let bsmod = info.bsmod else { return .unknown }
            return semantic(forBSMod: bsmod)
        case .aac, .mp1, .mp2, .mp3:
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
    }

    private static func semantic(forBSMod bsmod: UInt8) -> AudioServiceSemantic {
        switch bsmod {
        case 0: .independentMain
        case 2: .dvs
        case 1, 3, 4, 5, 6, 7: .associated
        default: .unknown
        }
    }

    private static func containerSemantic(
        metadata: DemuxTrackMetadata,
        selectedProgramID: Int32?,
        audioPrimaryEvidence: DemuxTrackSet.AudioPrimaryEvidence?,
        selectedStreamIndex: Int32
    ) -> AudioServiceSemantic {
        guard metadata.roleEvidence != .unclassifiable else { return .unknown }
        let dispositionSemantic: AudioServiceSemantic?
        if metadata.dispositions.contains(.dependent) {
            dispositionSemantic = .dependent
        } else if metadata.dispositions.contains(.visualImpaired) {
            dispositionSemantic = .dvs
        } else if metadata.dispositions.intersection([.hearingImpaired, .commentary]).isEmpty == false {
            dispositionSemantic = .associated
        } else {
            dispositionSemantic = nil
        }
        let serviceSemantic: AudioServiceSemantic?
        switch metadata.serviceEvidence {
        case .absent: serviceSemantic = nil
        case .unclassifiable: return .unknown
        case let .resolved(service): serviceSemantic = semantic(for: service)
        }
        if let dispositionSemantic, let serviceSemantic,
           dispositionSemantic != serviceSemantic {
            return .unknown
        }
        if let serviceSemantic {
            if serviceSemantic == .independentMain,
               !hasPrimaryContainerEvidence(metadata: metadata, evidence: audioPrimaryEvidence,
                                            selectedProgramID: selectedProgramID,
                                            selectedStreamIndex: selectedStreamIndex) {
                return .unknown
            }
            return serviceSemantic
        }
        if let dispositionSemantic { return dispositionSemantic }
        guard hasPrimaryContainerEvidence(metadata: metadata, evidence: audioPrimaryEvidence,
                                          selectedProgramID: selectedProgramID,
                                          selectedStreamIndex: selectedStreamIndex) else {
            return metadata.role == .commentary ? .associated : .unknown
        }
        return .independentMain
    }

    private static func hasPrimaryContainerEvidence(
        metadata: DemuxTrackMetadata,
        evidence: DemuxTrackSet.AudioPrimaryEvidence?,
        selectedProgramID: Int32?,
        selectedStreamIndex: Int32
    ) -> Bool {
        // 历史调用尚未拿到 C 回执时保留原有 main 行为；真实 demux 路径一旦携带
        // 回执，必须完全以该作用域事实裁决，绝不由 Swift 重算或补填 program。
        guard let evidence else { return selectedProgramID != nil && metadata.role == .main }
        guard evidence.selectedStreamIndex == selectedStreamIndex,
              evidence.unclassifiableRoleStreamCount == 0 else { return false }
        switch evidence.scope {
        case let .avProgram(_, id): guard selectedProgramID == id else { return false }
        case .formatStreamTableWithoutProgram: guard selectedProgramID == nil else { return false }
        }
        switch evidence.primaryBasis {
        case .explicitMain:
            return metadata.roleEvidence == .resolved(.main) &&
                evidence.explicitMainStreamCount == 1 &&
                (evidence.defaultAudioStreamCount == 0 ||
                 (metadata.dispositions.contains(.default) && evidence.defaultAudioStreamCount == 1))
        case .soleAudio:
            return metadata.roleEvidence == .absent && evidence.audioStreamCount == 1
        case .uniqueDefault:
            return metadata.roleEvidence == .absent &&
                metadata.dispositions.contains(.default) &&
                evidence.audioStreamCount > 1 && evidence.defaultAudioStreamCount == 1 &&
                evidence.explicitMainStreamCount == 0
        case nil: return false
        }
    }

    private static func semantic(for service: DemuxTrackService) -> AudioServiceSemantic {
        switch service {
        case .independentMain: .independentMain
        case .associated: .associated
        case .dvs: .dvs
        case .dependent: .dependent
        case .joc: .joc
        }
    }

    private static func combine(
        container: AudioServiceSemantic,
        header: AudioServiceSemantic?
    ) -> AudioServiceSemantic {
        guard let header else { return container }
        return container == header ? header : .unknown
    }
}
