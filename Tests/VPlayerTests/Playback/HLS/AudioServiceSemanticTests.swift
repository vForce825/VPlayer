// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioServiceSemanticTests: XCTestCase {
    func testIndependentMainReceiptAndProofPrecedeEveryBranchLease() throws {
        let harness = try AudioServiceSemanticTestHarness(codec: .aac)

        XCTAssertEqual(harness.receipt.semantic, .independentMain)
        XCTAssertEqual(harness.branchLeaseCount, 0)
        let admitted = try harness.admitCurrentUnit()

        XCTAssertEqual(admitted.identity.proofIdentity.parentReceiptIdentity, harness.receipt.identity)
        XCTAssertEqual(harness.branchLeaseCount, 0, "准入只冻结proof与sidecar，不得提前签branch lease")
        XCTAssertEqual(harness.coordinator.admit(admitted.identity.proofIdentity, ownership: harness.currentOwnership), .ignored)
        XCTAssertEqual(harness.currentOwnership.releaseCount, 0, "重复准入不得释放当前proof持有的所有权")
        let duplicateOwnership = AudioServiceInputUnitOwnership()
        XCTAssertEqual(harness.coordinator.admit(admitted.identity.proofIdentity, ownership: duplicateOwnership), .ignored)
        XCTAssertEqual(duplicateOwnership.releaseCount, 1, "不同的重复所有权只清理自身")
        XCTAssertNil(harness.failure)
    }

    func testHeaderlessCodecWithoutPrimaryRoleIsUnknownAndFailsBeforeSideEffects() throws {
        let harness = try AudioServiceSemanticTestHarness(
            codec: .mp3,
            metadata: DemuxTrackMetadata(role: nil, service: nil)
        )

        XCTAssertEqual(harness.receipt.semantic, .unknown)
        try harness.admitCurrentUnitExpectingFailure()
        XCTAssertEqual(harness.failure, .unsupportedAudioServiceSemantic)
    }

    func testCurrentAssociatedDVSDependentJOCAndUnknownProofFailWholeGenerationOnce() throws {
        for semantic in AudioServiceSemantic.unsupportedCases {
            let harness = try AudioServiceSemanticTestHarness(
                codec: .aac,
                metadata: AudioServiceSemanticTestHarness.metadata(for: semantic)
            )
            let proof = try harness.makeCurrentProof()

            XCTAssertEqual(harness.coordinator.admit(proof, ownership: harness.currentOwnership), .failed(.unsupportedAudioServiceSemantic))
            XCTAssertEqual(harness.coordinator.admit(proof, ownership: harness.currentOwnership), .ignored)
            XCTAssertEqual(harness.failure, .unsupportedAudioServiceSemantic, "semantic=\(semantic)")
            XCTAssertEqual(harness.failureCount, 1, "semantic=\(semantic)")
            XCTAssertEqual(harness.branchLeaseCount, 0, "semantic=\(semantic)")
        }
    }

    func testContainerAndHeaderConflictClassifiesUnknown() throws {
        let source = AudioServiceSemanticTestHarness.source(
            codec: .ac3,
            metadata: DemuxTrackMetadata(role: .main, service: .associated)
        )
        let unit = AudioServiceSemanticTestHarness.unit(
            codec: .ac3,
            rawValue: 1,
            bytes: AssemblerTestFixtures.syntheticAC3Frame(bsmod: 0)
        )
        let coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: AudioSourceTrackIdentity(streamIndex: 1, trackNonce: 10),
            inputFormatGeneration: AudioInputFormatGeneration(rawValue: 20),
            allocator: PlaybackIdentityAllocator()
        )

        let receipt = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: unit)

        XCTAssertEqual(receipt.semantic, .unknown)
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        XCTAssertEqual(proof.observedSemantic, .unknown)
        XCTAssertEqual(
            coordinator.admit(proof, ownership: AudioServiceInputUnitOwnership()),
            .failed(.unsupportedAudioServiceSemantic)
        )
        XCTAssertEqual(coordinator.issuedBranchLeaseCount, 0)
    }

    func testDemuxConflictEvidenceCannotCollapseIntoAbsentEvidence() throws {
        let metadata = DemuxTrackMetadata(
            role: .main,
            serviceEvidence: .unclassifiable,
            dispositions: [.default]
        )
        let harness = try AudioServiceSemanticTestHarness(codec: .aac, metadata: metadata)

        XCTAssertEqual(harness.receipt.classificationEvidenceIdentity.trackRoleReceiptIdentity.serviceEvidence, .unclassifiable)
        XCTAssertEqual(harness.receipt.semantic, .unknown)

        let contradictory = DemuxTrackMetadata(
            role: .main,
            service: .independentMain,
            serviceEvidence: .resolved(.associated),
            dispositions: [.default]
        )
        XCTAssertEqual(contradictory.serviceEvidence, .unclassifiable)
        XCTAssertNil(contradictory.service)
    }

    func testStaleProofFieldMatrixOnlyReleasesItsOwnOwnership() throws {
        let mutations: [(String, (AudioServiceSemanticInputUnitProof) -> AudioServiceSemanticInputUnitProof)] = [
            ("parent", { $0.replacing(parentReceiptIdentity: $0.parentReceiptIdentity.replacing(receiptNonce: 9_001)) }),
            ("format generation", { $0.replacing(inputFormatGeneration: .init(rawValue: 9_002)) }),
            ("unit", { $0.replacing(inputUnitIdentity: .init(rawValue: 9_003)) }),
            ("kind", { $0.replacing(unitKind: .ac3Frame) }),
            ("backing", { $0.replacing(backingIdentity: .init(rawValue: 9_004)) }),
            ("backing owner", { $0.replacing(backingOwnerIdentity: AudioServiceBackingOwnerIdentity()) }),
            ("range", { $0.replacing(byteRange: AudioServiceByteRange(offset: 0, length: 1)!) }),
            ("digest", { $0.replacing(evidenceDigest: .zero) }),
            ("validation nonce", { $0.replacing(validationNonce: .init(rawValue: 9_005)) }),
            ("proof nonce", { $0.replacing(proofNonce: .init(rawValue: 9_006)) }),
        ]

        for (name, mutate) in mutations {
            let harness = try AudioServiceSemanticTestHarness(codec: .aac)
            let proof = try harness.makeCurrentProof()
            let staleOwnership = AudioServiceInputUnitOwnership()

            XCTAssertEqual(harness.coordinator.admit(mutate(proof), ownership: staleOwnership), .ignored, name)
            XCTAssertEqual(staleOwnership.releaseCount, 1, name)
            XCTAssertTrue(harness.coordinator.receiptCommitIsValid, name)
            XCTAssertNil(harness.failure, name)
            XCTAssertEqual(harness.branchLeaseCount, 0, name)
            _ = try harness.admitCurrentUnit()
        }
    }

    func testProofForPreviousUnitCannotAdmitCurrentUnitButNewBackingAndNonceCan() throws {
        let harness = try AudioServiceSemanticTestHarness(codec: .aac)
        let oldProof = try harness.makeCurrentProof()
        let newUnit = AudioServiceSemanticTestHarness.unit(
            codec: .aac,
            rawValue: 2,
            bytes: harness.currentUnit.bytes
        )
        try harness.replaceExpectedUnit(with: newUnit)

        let oldOwnership = AudioServiceInputUnitOwnership()
        XCTAssertEqual(harness.coordinator.admit(oldProof, ownership: oldOwnership), .ignored)
        XCTAssertEqual(oldOwnership.releaseCount, 1)

        let newProof = try harness.coordinator.makeProof(
            for: newUnit,
            validationNonce: try harness.coordinator.installValidation(for: newUnit)
        )
        XCTAssertEqual(harness.coordinator.admit(newProof, ownership: AudioServiceInputUnitOwnership()).isAdmitted, true)
    }

    func testRepeatedCallbackForPreviouslyAdmittedUnitCannotReleaseItsLiveOwnership() throws {
        let harness = try AudioServiceSemanticTestHarness(codec: .aac)
        let admitted = try harness.admitCurrentUnit()
        let oldOwnership = harness.currentOwnership
        let nextUnit = AudioServiceSemanticTestHarness.unit(
            codec: .aac,
            rawValue: 2,
            bytes: harness.currentUnit.bytes
        )
        try harness.replaceExpectedUnit(with: nextUnit)

        XCTAssertEqual(
            harness.coordinator.admit(admitted.identity.proofIdentity, ownership: oldOwnership),
            .ignored
        )
        XCTAssertEqual(oldOwnership.releaseCount, 0)
        XCTAssertTrue(harness.coordinator.receiptCommitIsValid)
        XCTAssertTrue(try harness.admitCurrentUnit().identity.proofIdentity.inputUnitIdentity == nextUnit.identity)
    }

    func testUnitKindIsBoundToCodecSpecificMinimumClassificationUnit() throws {
        let cases: [(AudioCodec, AudioServiceInputUnitKind)] = [
            (.aac, .aacAccessUnit),
            (.mp1, .mpegAudioFrame),
            (.mp2, .mpegAudioFrame),
            (.mp3, .mpegAudioFrame),
            (.ac3, .ac3Frame),
            (.eac3, .eac3Syncframe),
        ]

        for (codec, expectedKind) in cases {
            let harness = try AudioServiceSemanticTestHarness(codec: codec)
            let proof = try harness.makeCurrentProof()
            XCTAssertEqual(proof.unitKind, expectedKind, "codec=\(codec)")
            XCTAssertEqual(harness.coordinator.admit(proof, ownership: harness.currentOwnership).isAdmitted, true)
        }
    }

    func testEAC3EveryLegalBlockCountGetsIndependentMainSyncframeProof() throws {
        for blockCount in [1, 2, 3, 6] {
            let harness = try AudioServiceSemanticTestHarness(
                codec: .eac3,
                eac3BlockCount: blockCount
            )
            let proof = try harness.makeCurrentProof()

            XCTAssertEqual(proof.unitKind, .eac3Syncframe)
            XCTAssertEqual(proof.observedSemantic, .independentMain)
            XCTAssertEqual(proof.codecFacts?.eac3BlockCount, blockCount)
            XCTAssertEqual(harness.coordinator.admit(proof, ownership: harness.currentOwnership).isAdmitted, true)
        }
    }

    func testIndependentNonzeroEAC3SubstreamRemainsMainForDecoder() throws {
        let bytes = EAC3SemanticFixture.make(
            sampleRate: 48_000,
            blockCount: 6,
            streamType: 0,
            substreamID: 3,
            bsid: 16,
            bsmod: 0,
            audioCodingMode: 2,
            hasLFE: false,
            hasInfoMetadata: true,
            hasJOC: false
        )
        let harness = try AudioServiceSemanticTestHarness(codec: .eac3, bytes: bytes)
        let admitted = try harness.admitCurrentUnit()
        let decoder = SharedDecoderAdmissionIdentity(
            sourceTrackIdentity: admitted.identity.proofIdentity.parentReceiptIdentity.sourceTrackIdentity,
            inputFormatGeneration: admitted.identity.proofIdentity.inputFormatGeneration,
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 50_000),
            decoderLifecycleGeneration: 50_001,
            decoderAdmissionFenceRevision: 50_002
        )

        XCTAssertEqual(admitted.identity.proofIdentity.observedSemantic, .independentMain)
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(decoder, for: admitted))
        XCTAssertNotNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: admitted,
            admission: .decoder(decoder)
        ))
        XCTAssertNil(harness.failure)
    }

    func testCurrentUnsupportedProofRevokesExistingRealBranchAndPCMConsumption() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let blockedConsumer = harness.pcmAdmission(offset: 600)
        let transferredConsumer = harness.pcmAdmission(offset: 601)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(blockedConsumer))
        XCTAssertTrue(harness.coordinator.openPCMSubscription(transferredConsumer))
        let decoderLease = try harness.prepareDecoderLineage()
        let pcmBundle = try harness.makePCMBundle(
            consumers: [blockedConsumer, transferredConsumer],
            unit: 60_000
        )
        let pcmLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: pcmBundle,
            consumerAdmissionIdentity: transferredConsumer
        ))
        let pcmOwner = PCMInputOwnerIdentity(rawValue: 60_001)
        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(pcmLease.identity, to: pcmOwner), .transferred)

        let compressedAdmission = harness.directAdmission(branchGeneration: 60_002, fence: 60_003)
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
            compressedAdmission,
            for: harness.admitted
        ))
        let availableCompressed = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: compressedAdmission
        ))
        let invalid = try harness.makeNextUnsupportedProof(rawValue: 60_004)

        XCTAssertEqual(
            harness.coordinator.admit(invalid.proof, ownership: invalid.ownership),
            .failed(.unsupportedAudioServiceSemantic)
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(availableCompressed.identity), .released)
        XCTAssertEqual(
            harness.coordinator.transferCompressedLease(
                availableCompressed.identity,
                to: harness.directBundle(admission: compressedAdmission)
            ),
            .alreadyDisposed
        )
        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(
            from: pcmBundle,
            consumerAdmissionIdentity: blockedConsumer
        ))
        XCTAssertFalse(harness.coordinator.openPCMSubscription(harness.pcmAdmission(offset: 602)))
        XCTAssertThrowsError(try harness.makePCMBundle(consumers: [], unit: 60_005)) {
            XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .staleProof)
        }
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(pcmLease.identity, expectedOwner: pcmOwner),
            .released
        )
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                decoderLease,
                expectedOwner: .decoder(harness.decoderInputOwner)
            ),
            .released
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)
        XCTAssertEqual(invalid.ownership.releaseCount, 1)
        XCTAssertEqual(harness.coordinator.failurePublicationCount, 1)
    }

    func testAC3AndEAC3HeaderSemanticsRejectEveryNonMainServiceBeforeBranches() throws {
        let cases: [(String, AudioCodec, DemuxTrackMetadata, Data, AudioServiceSemantic)] = [
            (
                "AC3 associated",
                .ac3,
                AudioServiceSemanticTestHarness.metadata(service: .associated),
                AssemblerTestFixtures.syntheticAC3Frame(bsmod: 1),
                .associated
            ),
            (
                "AC3 DVS",
                .ac3,
                AudioServiceSemanticTestHarness.metadata(service: .dvs),
                AssemblerTestFixtures.syntheticAC3Frame(bsmod: 2),
                .dvs
            ),
            (
                "EAC3 associated",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .associated),
                syntheticEAC3Frame(bsmod: 1),
                .associated
            ),
            (
                "EAC3 DVS",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .dvs),
                syntheticEAC3Frame(bsmod: 2),
                .dvs
            ),
            (
                "EAC3 dependent",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .dependent),
                syntheticEAC3Frame(streamType: 1),
                .dependent
            ),
            (
                "EAC3 converted",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .independentMain),
                syntheticEAC3Frame(streamType: 2),
                .unknown
            ),
            (
                "EAC3 JOC",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .joc),
                syntheticEAC3Frame(hasJOC: true),
                .joc
            ),
            (
                "EAC3 no service header",
                .eac3,
                AudioServiceSemanticTestHarness.metadata(service: .independentMain),
                syntheticEAC3Frame(hasInfoMetadata: false),
                .unknown
            ),
        ]

        for (name, codec, metadata, bytes, expected) in cases {
            let harness = try AudioServiceSemanticTestHarness(
                codec: codec,
                metadata: metadata,
                bytes: bytes
            )
            let proof = try harness.makeCurrentProof()

            XCTAssertEqual(proof.observedSemantic, expected, name)
            XCTAssertEqual(
                harness.coordinator.admit(proof, ownership: harness.currentOwnership),
                .failed(.unsupportedAudioServiceSemantic),
                name
            )
            XCTAssertEqual(harness.failureCount, 1, name)
            XCTAssertEqual(harness.branchLeaseCount, 0, name)
        }
    }

    func testOldInvalidSemanticProofCannotTerminateNewReceipt() throws {
        let harness = try AudioServiceSemanticTestHarness(codec: .aac)
        let stale = try harness.makeCurrentProof(overriding: .associated)
            .replacing(validationNonce: .init(rawValue: 77_777))

        XCTAssertEqual(harness.coordinator.admit(stale, ownership: AudioServiceInputUnitOwnership()), .ignored)
        XCTAssertNil(harness.failure)
        XCTAssertTrue(harness.coordinator.receiptCommitIsValid)
        XCTAssertEqual(harness.coordinator.admit(try harness.makeCurrentProof(), ownership: harness.currentOwnership).isAdmitted, true)
    }
}

private final class AudioServiceSemanticTestHarness {
    let coordinator: AudioServiceSemanticCoordinator
    let receipt: AudioServiceSemanticReceipt
    private(set) var currentUnit: AudioServiceInputUnit
    private(set) var currentOwnership = AudioServiceInputUnitOwnership()
    private var validationNonce: AudioServiceSemanticValidationNonce

    var failure: AudioServiceSemanticFailure? { coordinator.failure }
    var failureCount: Int { coordinator.failurePublicationCount }
    var branchLeaseCount: Int { coordinator.issuedBranchLeaseCount }

    init(
        codec: AudioCodec,
        metadata: DemuxTrackMetadata = DemuxTrackMetadata(
            role: .main,
            service: .independentMain,
            dispositions: [.default]
        ),
        eac3BlockCount: Int = 6,
        bytes: Data? = nil
    ) throws {
        let unit = Self.unit(
            codec: codec,
            rawValue: 1,
            bytes: bytes ?? Self.bytes(codec: codec, eac3BlockCount: eac3BlockCount),
            eac3BlockCount: eac3BlockCount
        )
        currentUnit = unit
        coordinator = AudioServiceSemanticCoordinator(
            source: Self.source(codec: codec, metadata: metadata),
            sourceTrackIdentity: AudioSourceTrackIdentity(streamIndex: 1, trackNonce: 10),
            inputFormatGeneration: AudioInputFormatGeneration(rawValue: 20),
            allocator: PlaybackIdentityAllocator()
        )
        receipt = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: unit)
        validationNonce = try coordinator.installValidation(for: unit)
    }

    func makeCurrentProof(
        overriding semantic: AudioServiceSemantic? = nil
    ) throws -> AudioServiceSemanticInputUnitProof {
        let proof = try coordinator.makeProof(for: currentUnit, validationNonce: validationNonce)
        return semantic.map { proof.replacing(observedSemantic: $0) } ?? proof
    }

    func admitCurrentUnit() throws -> AdmittedAudioServiceInputUnitProof {
        switch coordinator.admit(try makeCurrentProof(), ownership: currentOwnership) {
        case let .admitted(proof): return proof
        case let .failed(failure): throw failure
        case .ignored: throw AudioServiceSemanticFailure.staleProof
        }
    }

    func admitCurrentUnitExpectingFailure() throws {
        let proof = try makeCurrentProof()
        guard case .failed = coordinator.admit(proof, ownership: currentOwnership) else {
            XCTFail("当前非main proof必须整代失败")
            return
        }
    }

    func replaceExpectedUnit(with unit: AudioServiceInputUnit) throws {
        currentUnit = unit
        currentOwnership = AudioServiceInputUnitOwnership()
        validationNonce = try coordinator.installValidation(for: unit)
    }

    static func source(
        codec: AudioCodec,
        metadata: DemuxTrackMetadata
    ) -> AudioTrackDescriptor {
        let sampleRate: Int32 = codec == .eac3 ? 48_000 : 48_000
        return AudioTrackDescriptor(
            streamIndex: 1,
            codec: codec,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: sampleRate,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: codec == .aac ? Data([0x11, 0x90]) : Data(),
            metadata: metadata
        )
    }

    static func metadata(for semantic: AudioServiceSemantic) -> DemuxTrackMetadata {
        let evidence: DemuxTrackServiceEvidence
        switch semantic {
        case .independentMain: evidence = .resolved(.independentMain)
        case .associated: evidence = .resolved(.associated)
        case .dvs: evidence = .resolved(.dvs)
        case .dependent: evidence = .resolved(.dependent)
        case .joc: evidence = .resolved(.joc)
        case .unknown: evidence = .unclassifiable
        }
        return DemuxTrackMetadata(
            role: .main,
            serviceEvidence: evidence,
            dispositions: [.default]
        )
    }

    static func metadata(service: DemuxTrackService) -> DemuxTrackMetadata {
        DemuxTrackMetadata(role: .main, service: service, dispositions: [.default])
    }

    static func unit(
        codec: AudioCodec,
        rawValue: UInt64,
        bytes: Data,
        eac3BlockCount: Int = 6
    ) -> AudioServiceInputUnit {
        let sampleCount: Int32?
        switch codec {
        case .aac: sampleCount = nil
        case .mp1: sampleCount = 384
        case .mp2, .mp3: sampleCount = 1_152
        case .ac3: sampleCount = 1_536
        case .eac3: sampleCount = Int32(eac3BlockCount * 256)
        }
        return try! AudioServiceInputUnit(
            identity: AudioServiceInputUnitIdentity(rawValue: rawValue),
            backing: AudioServiceInputBacking(
                identity: AudioServiceBackingIdentity(rawValue: rawValue),
                bytes: bytes
            ),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: .zero,
            parserSampleCount: sampleCount,
            parserSampleRate: codec == .aac ? nil : 48_000,
            parserChannelLayout: codec == .aac ? nil : AudioChannelLayout(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
    }

    static func bytes(codec: AudioCodec, eac3BlockCount: Int) -> Data {
        switch codec {
        case .aac: Data([0x21, 0x22])
        case .ac3: AssemblerTestFixtures.syntheticAC3Frame(bsmod: 0, acmod: 2, lfeon: false)
        case .eac3: syntheticEAC3Frame(blockCount: eac3BlockCount)
        case .mp1: syntheticMPEGFrame(versionBits: 3, layerBits: 3, bitrateIndex: 1)
        case .mp2: syntheticMPEGFrame(versionBits: 3, layerBits: 2, bitrateIndex: 1)
        case .mp3: syntheticMPEGFrame(versionBits: 3, layerBits: 1, bitrateIndex: 1)
        }
    }

    private static func syntheticMPEGFrame(
        versionBits: UInt32,
        layerBits: UInt32,
        bitrateIndex: UInt32
    ) -> Data {
        let bitrate: Int
        switch layerBits {
        case 3: bitrate = 32_000
        case 2: bitrate = 32_000
        default: bitrate = 32_000
        }
        let length: Int
        if layerBits == 3 {
            length = 12 * bitrate / 48_000 * 4
        } else {
            length = 144 * bitrate / 48_000
        }
        let syncWord = UInt32(0x7FF) << 21
        let version = versionBits << 19
        let layer = layerBits << 17
        let crcAbsent = UInt32(1) << 16
        let bitrateField = bitrateIndex << 12
        let sampleRateField = UInt32(1) << 10
        let header = syncWord | version | layer | crcAbsent | bitrateField | sampleRateField
        return Data([
            UInt8((header >> 24) & 0xFF), UInt8((header >> 16) & 0xFF),
            UInt8((header >> 8) & 0xFF), UInt8(header & 0xFF),
        ]) + Data(repeating: 0, count: max(0, length - 4))
    }
}

func syntheticEAC3Frame(
    blockCount: Int = 6,
    streamType: UInt8 = 0,
    bsmod: UInt8 = 0,
    hasInfoMetadata: Bool = true,
    hasJOC: Bool = false
) -> Data {
    EAC3SemanticFixture.make(
        sampleRate: 48_000,
        blockCount: blockCount,
        streamType: streamType,
        substreamID: 0,
        bsid: 16,
        bsmod: bsmod,
        audioCodingMode: 2,
        hasLFE: false,
        hasInfoMetadata: hasInfoMetadata,
        hasJOC: hasJOC
    )
}

enum EAC3SemanticFixture {
    static func make(
        sampleRate: Int32,
        blockCount: Int,
        streamType: UInt8,
        substreamID: UInt8,
        bsid: UInt8,
        bsmod: UInt8,
        audioCodingMode: UInt8,
        hasLFE: Bool,
        hasInfoMetadata: Bool,
        hasJOC: Bool
    ) -> Data {
        precondition([1, 2, 3, 6].contains(blockCount))
        let byteCount = 16
        var bits = EAC3SemanticBitWriter()
        bits.write(0x0B77, count: 16)
        bits.write(UInt64(streamType), count: 2)
        bits.write(UInt64(substreamID), count: 3)
        bits.write(UInt64(byteCount / 2 - 1), count: 11)
        if let fscod = [48_000: 0, 44_100: 1, 32_000: 2][sampleRate] {
            bits.write(UInt64(fscod), count: 2)
            let blockCode = [1: 0, 2: 1, 3: 2, 6: 3][blockCount]!
            bits.write(UInt64(blockCode), count: 2)
        } else {
            precondition(blockCount == 6)
            let fscod2 = [24_000: 0, 22_050: 1, 16_000: 2][sampleRate]!
            bits.write(3, count: 2)
            bits.write(UInt64(fscod2), count: 2)
        }
        bits.write(UInt64(audioCodingMode), count: 3)
        bits.write(hasLFE ? 1 : 0, count: 1)
        bits.write(UInt64(bsid), count: 5)
        bits.write(0, count: 5) // dialnorm
        bits.write(0, count: 1) // compre
        if streamType == 1 { bits.write(0, count: 1) } // chanmape
        bits.write(0, count: 1) // mixmdate
        bits.write(hasInfoMetadata ? 1 : 0, count: 1) // infomdate
        if hasInfoMetadata {
            bits.write(UInt64(bsmod), count: 3)
            bits.write(0, count: 1) // copyrightb
            bits.write(1, count: 1) // origbs
            if audioCodingMode == 2 {
                bits.write(0, count: 2) // dsurmod
                bits.write(0, count: 2) // dheadphonmod
            }
            if audioCodingMode >= 6 { bits.write(0, count: 2) }
            if audioCodingMode == 0 { bits.write(0, count: 2) }
            bits.write(0, count: 1) // audprodie
            if audioCodingMode == 0 { bits.write(0, count: 1) }
            bits.write(0, count: 1) // sourcefscod
        }
        if streamType == 0, blockCount < 6 { bits.write(1, count: 1) }
        if streamType == 2 { bits.write(0, count: 6) } // frmsizecod
        bits.write(hasJOC ? 1 : 0, count: 1) // addbsie
        if hasJOC {
            bits.write(1, count: 6) // addbsil: extension byte + complexity byte
            bits.write(1, count: 8) // extension type A flag is the least-significant bit
            bits.write(1, count: 8) // complexity index
        }
        return bits.data(paddedTo: byteCount)
    }
}

private struct EAC3SemanticBitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt64, count: Int) {
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            let bit = UInt8((value >> UInt64(offset)) & 1)
            bytes[bytes.count - 1] |= bit << UInt8(7 - bitCount % 8)
            bitCount += 1
        }
    }

    func data(paddedTo byteCount: Int) -> Data {
        precondition(bytes.count <= byteCount)
        return Data(bytes + Array(repeating: 0, count: byteCount - bytes.count))
    }
}
