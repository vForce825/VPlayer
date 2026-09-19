// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class EAC3AccessUnitAssemblerTests: XCTestCase {
    func testSamePlanConsecutiveAccessUnitsAdvanceOnceAndGapOrReplayCannotAdvanceGate() throws {
        func exercise(invalidStart: CMTime, seed: UInt64) throws {
            let harness = try Task16EAC3Harness(ownerSeed: seed)
            let authorization = try harness.makeAuthorization()
            func assemble(at start: CMTime) throws
                -> (CompressedAudioAccessUnit, Task16EAC3Member) {
                let assembler = EAC3AccessUnitAssembler(
                    coordinator: harness.coordinator,
                    authorization: authorization,
                    allocator: PlaybackIdentityAllocator()
                )
                let member = try harness.makeMember(
                    blockCount: 6, convsync: nil,
                    presentationTimeStamp: start, authorization: authorization)
                return (try XCTUnwrap(try assembler.append(
                    inputUnit: member.unit, admittedProof: member.proof,
                    aggregationLease: member.aggregationLease)), member)
            }
            let first = try assemble(at: .zero)
            let second = try assemble(at: CMTime(value: 1_536, timescale: 48_000))
            XCTAssertEqual(first.0.presentationStart, .zero)
            XCTAssertEqual(second.0.presentationStart,
                           CMTime(value: 1_536, timescale: 48_000))
            let expectedNext = CMTime(value: 3_072, timescale: 48_000)
            XCTAssertTrue(harness.coordinator.acceptsNextCompressedPresentationStart(
                expectedNext, authorization: authorization))
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: authorization,
                allocator: PlaybackIdentityAllocator()
            )
            let member = try harness.makeMember(
                blockCount: 6,
                convsync: nil,
                presentationTimeStamp: invalidStart,
                authorization: authorization
            )
            XCTAssertThrowsError(try assembler.append(
                inputUnit: member.unit,
                admittedProof: member.proof,
                aggregationLease: member.aggregationLease
            ))
            XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)
            XCTAssertEqual(harness.coordinator.branchLeaseState(
                member.aggregationLease.identity), .released)
            XCTAssertTrue(harness.coordinator.retireAdmittedProof(member.proof))
            XCTAssertEqual(member.ownership.releaseCount, 1)
            for pair in [first, second] {
                let bundle = try XCTUnwrap(pair.0.eac3BundleIdentity)
                XCTAssertEqual(harness.coordinator.releaseAudioServiceBranchLease(
                    pair.1.aggregationLease.identity,
                    expectedOwner: .eac3AccessUnit(bundle)
                ), .released)
                XCTAssertTrue(harness.coordinator.retireAdmittedProof(pair.1.proof))
            }
        }
        try exercise(invalidStart: CMTime(value: 4_608, timescale: 48_000), seed: 12_800)
        try exercise(invalidStart: .zero, seed: 13_000)
    }

    func testStaleAuthorizationBeforeHoldKeepsLeaseAvailableAndCountersUnchanged() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 1_100)
        let authorization = try harness.makeAuthorization()
        let member = try harness.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero,
            authorization: authorization
        )
        let before = harness.coordinator.withAudioServiceCAS {
            let gate = harness.coordinator.audioServiceLeaseState.branchGates.first {
                $0.admissionIdentity == harness.admission
            }
            return (harness.coordinator.issuedBranchLeaseCount, gate?.outstandingCount)
        }

        try harness.resetAuthorizationTimeline()

        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(
            member.aggregationLease.identity,
            partial: .init(rawValue: 1_101)
        ), .invalidTransition)
        XCTAssertEqual(harness.coordinator.branchLeaseState(member.aggregationLease.identity), .available)
        let after = harness.coordinator.withAudioServiceCAS {
            let gate = harness.coordinator.audioServiceLeaseState.branchGates.first {
                $0.admissionIdentity == harness.admission
            }
            return (harness.coordinator.issuedBranchLeaseCount, gate?.outstandingCount)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(member.ownership.releaseCount, 0)
    }

    func testStaleAuthorizationRejectsSealedCommitAndWriterClaimWithoutLeaseMutation() throws {
        let commitHarness = try Task16EAC3Harness(ownerSeed: 1_200)
        let authorization = try commitHarness.makeAuthorization()
        let first = try commitHarness.makeMember(
            blockCount: 3,
            convsync: true,
            presentationTimeStamp: .zero,
            authorization: authorization
        )
        let second = try commitHarness.makeMember(
            blockCount: 3,
            convsync: false,
            presentationTimeStamp: CMTime(value: 768, timescale: 48_000),
            authorization: authorization
        )
        let partial = PartialAudioAggregationIdentity(rawValue: 1_201)
        XCTAssertEqual(commitHarness.coordinator.holdEAC3AggregationLease(
            first.aggregationLease.identity,
            partial: partial
        ), .held)
        XCTAssertEqual(commitHarness.coordinator.holdEAC3AggregationLease(
            second.aggregationLease.identity,
            partial: partial
        ), .held)
        let request = try commitHarness.sealedCommitRequest(
            authorization: authorization,
            partial: partial,
            members: [first, second]
        )
        try commitHarness.resetAuthorizationTimeline()

        XCTAssertEqual(commitHarness.coordinator.commitSealedEAC3AccessUnit(request), .identityMismatch)
        XCTAssertEqual(commitHarness.coordinator.branchLeaseState(first.aggregationLease.identity), .held(partial))
        XCTAssertEqual(commitHarness.coordinator.branchLeaseState(second.aggregationLease.identity), .held(partial))

        let writerHarness = try Task16EAC3Harness(ownerSeed: 1_250)
        let writerAuthorization = try writerHarness.makeAuthorization()
        let assembler = EAC3AccessUnitAssembler(
            coordinator: writerHarness.coordinator,
            authorization: writerAuthorization,
            allocator: PlaybackIdentityAllocator()
        )
        let writerMember = try writerHarness.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero,
            authorization: writerAuthorization
        )
        let output = try XCTUnwrap(try assembler.append(
            inputUnit: writerMember.unit,
            admittedProof: writerMember.proof,
            aggregationLease: writerMember.aggregationLease
        ))
        try writerHarness.resetAuthorizationTimeline()

        XCTAssertFalse(writerHarness.coordinator.claimCompressedAudioWriterSubmission(
            output.writerSubmission,
            expectedIdentity: CompressedAudioWriterExpectedIdentity(
                codec: .eac3,
                admissionIdentity: writerHarness.admission,
                formatConfiguration: output.formatConfiguration
            )
        ))
        XCTAssertEqual(writerHarness.coordinator.claimedCompressedWriterSubmissionCount, 0)
        XCTAssertEqual(
            writerHarness.coordinator.branchLeaseState(writerMember.aggregationLease.identity),
            .transferred(.eac3AccessUnit(try XCTUnwrap(output.eac3BundleIdentity)))
        )
    }

    func testSealedCommitRejectsSubsetReverseAndWrongOutputBeforeAtomicTransfer() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 500)
        let authorization = try harness.makeAuthorization()
        let first = try harness.makeMember(
            blockCount: 3,
            convsync: true,
            presentationTimeStamp: .zero,
            authorization: authorization
        )
        let second = try harness.makeMember(
            blockCount: 3,
            convsync: false,
            presentationTimeStamp: CMTime(value: 768, timescale: 48_000),
            authorization: authorization
        )
        let partial = PartialAudioAggregationIdentity(rawValue: 550)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(
            first.aggregationLease.identity,
            partial: partial
        ), .held)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(
            second.aggregationLease.identity,
            partial: partial
        ), .held)
        let exact = try harness.sealedCommitRequest(
            authorization: authorization,
            partial: partial,
            members: [first, second]
        )

        XCTAssertEqual(harness.coordinator.commitSealedEAC3AccessUnit(
            try harness.sealedCommitRequest(
                authorization: authorization,
                partial: partial,
                members: [first]
            )
        ), .identityMismatch)
        XCTAssertEqual(harness.coordinator.commitSealedEAC3AccessUnit(
            try harness.sealedCommitRequest(
                authorization: authorization,
                partial: partial,
                members: [second, first]
            )
        ), .identityMismatch)
        XCTAssertEqual(harness.coordinator.commitSealedEAC3AccessUnit(
            exact.replacingOutput(
                backing: EAC3AccessUnitBacking(identity: .init(rawValue: 551), bytes: Data(repeating: 0, count: 32)),
                range: AudioServiceByteRange(offset: 0, length: 31)!,
                digest: .zero
            )
        ), .identityMismatch)
        XCTAssertEqual(harness.coordinator.branchLeaseState(first.aggregationLease.identity), .held(partial))
        XCTAssertEqual(harness.coordinator.branchLeaseState(second.aggregationLease.identity), .held(partial))

        XCTAssertEqual(harness.coordinator.commitSealedEAC3AccessUnit(exact), .transferred)
        XCTAssertEqual(
            harness.coordinator.branchLeaseState(first.aggregationLease.identity),
            .transferred(.eac3AccessUnit(exact.bundleIdentity))
        )
        XCTAssertEqual(
            harness.coordinator.branchLeaseState(second.aggregationLease.identity),
            .transferred(.eac3AccessUnit(exact.bundleIdentity))
        )
    }

    func testTrustedEAC3ParserDomainRateLimitAcceptsBelowAndExactRejectsAboveAndChecksOverflow() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 1_300)
        let authorization = try harness.makeAuthorization()
        let assembler = EAC3AccessUnitAssembler(
            coordinator: harness.coordinator,
            authorization: authorization,
            allocator: PlaybackIdentityAllocator()
        )
        let member = try harness.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero,
            byteCount: 32,
            authorization: authorization
        )
        let output = try XCTUnwrap(try assembler.append(
            inputUnit: member.unit,
            admittedProof: member.proof,
            aggregationLease: member.aggregationLease
        ))
        guard case let .eac3(configuration) = output.formatConfiguration else {
            return XCTFail("应生成 E-AC-3 配置")
        }
        XCTAssertEqual(output.aggregationProof?.actualDataRateKbps, 8)
        XCTAssertEqual(configuration.maximumDataRateKbps, 6_144,
                       "dec3 data_rate 必须来自可信 parser 支持域，而非调用方标量或首 AU 猜测")
        XCTAssertNoThrow(try EAC3AccessUnitAssembler.validateActualDataRateKbps(6_143))
        XCTAssertNoThrow(try EAC3AccessUnitAssembler.validateActualDataRateKbps(6_144))
        XCTAssertThrowsError(try EAC3AccessUnitAssembler.validateActualDataRateKbps(6_145))
        XCTAssertThrowsError(try EAC3AccessUnitAssembler.checkedDataRateKbps(
            byteCount: Int.max,
            sampleRate: 48_000
        ))
    }

    func testEveryLegalGroupingProducesOneOrdered1536SampleAccessUnit() throws {
        let groupings = [[1, 1, 1, 1, 1, 1], [2, 2, 2], [3, 3], [6]]

        for (groupIndex, grouping) in groupings.enumerated() {
            let expectedActualDataRateKbps = UInt16(grouping.count * 4)
            let harness = try Task16EAC3Harness(ownerSeed: UInt64(1_000 + groupIndex * 100))
            let authorization = try harness.makeAuthorization()
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: authorization,
                allocator: PlaybackIdentityAllocator()
            )
            var members: [Task16EAC3Member] = []
            var output: CompressedAudioAccessUnit?
            var pts = CMTime.zero

            for (index, blockCount) in grouping.enumerated() {
                let member = try harness.makeMember(
                    blockCount: blockCount,
                    convsync: blockCount < 6 ? index == 0 : nil,
                    presentationTimeStamp: pts
                )
                members.append(member)
                output = try assembler.append(
                    inputUnit: member.unit,
                    admittedProof: member.proof,
                    aggregationLease: member.aggregationLease
                )
                pts = CMTimeAdd(pts, CMTime(value: Int64(blockCount * 256), timescale: 48_000))
            }

            let accessUnit = try XCTUnwrap(output, "grouping=\(grouping)")
            XCTAssertEqual(assembler.producedAccessUnitCount, 1)
            XCTAssertEqual(accessUnit.kind, .eac3Aggregated)
            XCTAssertEqual(accessUnit.codec, .eac3)
            XCTAssertEqual(accessUnit.sampleRate, 48_000)
            XCTAssertEqual(accessUnit.channelCount, 2)
            XCTAssertEqual(accessUnit.sampleCount, 1_536)
            XCTAssertEqual(accessUnit.framesPerPacket, 1_536)
            XCTAssertEqual(accessUnit.presentationStart, .zero)
            XCTAssertEqual(accessUnit.presentationEnd, CMTime(value: 1_536, timescale: 48_000))
            XCTAssertEqual(accessUnit.payload, members.reduce(into: Data()) { $0.append($1.unit.bytes) })
            XCTAssertEqual(accessUnit.payloadRange, AudioServiceByteRange(
                offset: 0,
                length: members.reduce(0) { $0 + $1.unit.byteRange.length }
            ))
            XCTAssertEqual(accessUnit.payloadDigest, accessUnit.payload.withUnsafeBytes(
                AudioServiceEvidenceDigest.init(bytes:)
            ))
            XCTAssertEqual(accessUnit.admissionIdentity, harness.admission)
            XCTAssertEqual(
                accessUnit.aggregationProof?.orderedSyncframeProofIdentities.values,
                members.map { $0.proof.identity }
            )
            XCTAssertEqual(
                accessUnit.aggregationProof?.orderedAggregationLeaseIdentities.values,
                members.map { $0.aggregationLease.identity }
            )
            XCTAssertEqual(accessUnit.aggregationProof?.blockCount, 6)
            XCTAssertEqual(accessUnit.aggregationProof?.sampleCount, 1_536)
            XCTAssertEqual(accessUnit.aggregationProof?.actualDataRateKbps, expectedActualDataRateKbps)
            XCTAssertFalse(accessUnit.formatConfiguration.declaresDolbyAtmos)
            for member in members {
                XCTAssertEqual(
                    harness.coordinator.branchLeaseState(member.aggregationLease.identity),
                    .transferred(.eac3AccessUnit(try XCTUnwrap(accessUnit.eac3BundleIdentity)))
                )
            }

            XCTAssertTrue(harness.coordinator.claimCompressedAudioWriterSubmission(
                accessUnit.writerSubmission,
                expectedIdentity: CompressedAudioWriterExpectedIdentity(
                    codec: .eac3,
                    admissionIdentity: harness.admission,
                    formatConfiguration: accessUnit.formatConfiguration
                )
            ))
            XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), grouping.count)
            XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 0)
            for member in members {
                XCTAssertEqual(harness.coordinator.branchLeaseState(member.aggregationLease.identity), .released)
            }
        }
    }

    func testEAC3WriterExpectedIdentityRejectsEveryOwnerAdmissionAndBundleFieldMutation() throws {
        for ownerKind in [Task16EAC3OwnerKind.audioVideo, .audioOnly] {
            let harness = try Task16EAC3Harness(
                ownerSeed: ownerKind == .audioVideo ? 2_500 : 2_600,
                ownerKind: ownerKind
            )
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: try harness.makeAuthorization(),
                allocator: PlaybackIdentityAllocator()
            )
            let member = try harness.makeMember(blockCount: 6, convsync: nil, presentationTimeStamp: .zero)
            let accessUnit = try XCTUnwrap(try assembler.append(
                inputUnit: member.unit,
                admittedProof: member.proof,
                aggregationLease: member.aggregationLease
            ))
            let expected = CompressedAudioWriterExpectedIdentity(
                codec: .eac3,
                admissionIdentity: harness.admission,
                formatConfiguration: accessUnit.formatConfiguration
            )
            XCTAssertTrue(expected.accepts(accessUnit.writerSubmission))

            for (index, admission) in harness.mutatedAdmissions().enumerated() {
                let nextWriter = CompressedAudioWriterExpectedIdentity(
                    codec: .eac3,
                    admissionIdentity: admission,
                    formatConfiguration: accessUnit.formatConfiguration
                )
                XCTAssertFalse(nextWriter.accepts(accessUnit.writerSubmission), "mutation=\(index)")
            }

            let bundle = try XCTUnwrap(accessUnit.eac3BundleIdentity)
            let wrongRange = AudioServiceByteRange(
                offset: bundle.outputByteRange.offset,
                length: bundle.outputByteRange.length - 1
            )!
            let bundleMutations = [
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: .init(rawValue: bundle.accessUnitIdentity.rawValue + 1),
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: harness.mutatedAdmissions()[0],
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: .init(rawValue: bundle.outputBackingIdentity.rawValue + 1),
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity(),
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: wrongRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: .zero,
                    bundleNonce: bundle.bundleNonce
                ),
                EAC3AccessUnitBundleIdentity(
                    accessUnitIdentity: bundle.accessUnitIdentity,
                    audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
                    outputBackingIdentity: bundle.outputBackingIdentity,
                    outputBackingOwnerIdentity: bundle.outputBackingOwnerIdentity,
                    outputByteRange: bundle.outputByteRange,
                    outputDigest: bundle.outputDigest,
                    bundleNonce: .init(rawValue: bundle.bundleNonce.rawValue + 1)
                ),
            ]
            for (index, mutation) in bundleMutations.enumerated() {
                let submission = CompressedAudioWriterSubmission(
                    accessUnit: accessUnit,
                    bundleIdentity: .eac3(mutation),
                    admissionIdentity: accessUnit.admissionIdentity,
                    payloadIdentity: accessUnit.payloadIdentity,
                    payloadRange: accessUnit.payloadRange,
                    payloadDigest: accessUnit.payloadDigest,
                    formatConfiguration: accessUnit.formatConfiguration
                )
                XCTAssertFalse(expected.accepts(submission), "bundle mutation=\(index)")
            }

            let directBundle = CompressedAccessUnitBundleIdentity(
                inputUnitIdentity: member.unit.identity,
                audioBranchAdmissionIdentity: harness.directAdmission,
                backingIdentity: member.unit.backing.identity,
                backingOwnerIdentity: member.unit.backing.ownerIdentity,
                byteRange: member.unit.byteRange,
                digest: member.proof.identity.proofIdentity.evidenceDigest,
                bundleNonce: bundle.bundleNonce
            )
            XCTAssertFalse(expected.accepts(CompressedAudioWriterSubmission(
                accessUnit: accessUnit,
                bundleIdentity: .direct(directBundle),
                admissionIdentity: accessUnit.admissionIdentity,
                payloadIdentity: accessUnit.payloadIdentity,
                payloadRange: accessUnit.payloadRange,
                payloadDigest: accessUnit.payloadDigest,
                formatConfiguration: accessUnit.formatConfiguration
            )))
        }
    }

    func testOneThroughFiveHeldMembersAreAllReleasedByEveryPartialTerminal() throws {
        let cases: [(Int, EAC3AggregationTerminationReason)] = [
            (1, .structuralFailure),
            (2, .cancelled),
            (3, .endOfStream),
            (4, .discontinuity),
            (5, .ownerRetired),
        ]

        for (memberCount, reason) in cases {
            let harness = try Task16EAC3Harness(ownerSeed: UInt64(3_000 + memberCount * 100))
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: try harness.makeAuthorization(),
                allocator: PlaybackIdentityAllocator()
            )
            var members: [Task16EAC3Member] = []
            var pts = CMTime.zero
            for index in 0..<memberCount {
                let member = try harness.makeMember(
                    blockCount: 1,
                    convsync: index == 0,
                    presentationTimeStamp: pts,
                    issueDecoderSibling: true
                )
                XCTAssertNil(try assembler.append(
                    inputUnit: member.unit,
                    admittedProof: member.proof,
                    aggregationLease: member.aggregationLease
                ))
                members.append(member)
                pts = CMTimeAdd(pts, CMTime(value: 256, timescale: 48_000))
            }

            assembler.terminate(reason)

            XCTAssertEqual(assembler.heldLeaseCount, 0, "memberCount=\(memberCount)")
            XCTAssertEqual(assembler.retainedInputByteCount, 0, "memberCount=\(memberCount)")
            XCTAssertEqual(assembler.failure, .terminated(reason), "memberCount=\(memberCount)")
            for member in members {
                XCTAssertEqual(
                    harness.coordinator.branchLeaseState(member.aggregationLease.identity),
                    .released,
                    "memberCount=\(memberCount)"
                )
                let sibling = try XCTUnwrap(member.decoderLease)
                XCTAssertEqual(harness.coordinator.branchLeaseState(sibling.identity), .available)
                XCTAssertEqual(
                    harness.coordinator.transferDecoderLease(
                        sibling.identity,
                        to: .init(rawValue: UInt64(5_000 + memberCount))
                    ),
                    .transferred
                )
            }
        }
    }

    func testStructuralRejectionsAreCandidateLocalAndReleaseEveryCollectedLease() throws {
        enum Mutation: Equatable {
            case wrongStart, unexpectedStart, nonzeroSubstream, tooManyBlocks
            case nonContinuousPTS, duplicateLease, mismatchedProofAndUnit, invariantDrift
        }
        let mutations: [Mutation] = [
            .wrongStart, .unexpectedStart, .nonzeroSubstream, .tooManyBlocks,
            .nonContinuousPTS, .duplicateLease, .mismatchedProofAndUnit, .invariantDrift,
        ]

        for (index, mutation) in mutations.enumerated() {
            let harness = try Task16EAC3Harness(ownerSeed: UInt64(6_000 + index * 100))
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: try harness.makeAuthorization(),
                allocator: PlaybackIdentityAllocator()
            )
            let first = try harness.makeMember(
                blockCount: mutation == .tooManyBlocks ? 3 : 1,
                convsync: mutation == .wrongStart ? false : true,
                presentationTimeStamp: .zero,
                issueDecoderSibling: true
            )

            if mutation == .wrongStart || mutation == .nonzeroSubstream {
                let rejected = mutation == .nonzeroSubstream
                    ? try harness.makeMember(
                        blockCount: 1,
                        convsync: true,
                        presentationTimeStamp: .zero,
                        substreamID: 1,
                        issueDecoderSibling: true
                    )
                    : first
                XCTAssertThrowsError(try assembler.append(
                    inputUnit: rejected.unit,
                    admittedProof: rejected.proof,
                    aggregationLease: rejected.aggregationLease
                ))
                XCTAssertEqual(harness.coordinator.branchLeaseState(rejected.aggregationLease.identity), .released)
                XCTAssertEqual(harness.coordinator.branchLeaseState(try XCTUnwrap(rejected.decoderLease).identity), .available)
                continue
            }

            XCTAssertNil(try assembler.append(
                inputUnit: first.unit,
                admittedProof: first.proof,
                aggregationLease: first.aggregationLease
            ))
            let second: Task16EAC3Member
            switch mutation {
            case .unexpectedStart:
                second = try harness.makeMember(
                    blockCount: 1,
                    convsync: true,
                    presentationTimeStamp: CMTime(value: 256, timescale: 48_000),
                    issueDecoderSibling: true
                )
            case .tooManyBlocks:
                second = try harness.makeMember(
                    blockCount: 6,
                    convsync: nil,
                    presentationTimeStamp: CMTime(value: 768, timescale: 48_000),
                    issueDecoderSibling: true
                )
            case .nonContinuousPTS:
                second = try harness.makeMember(
                    blockCount: 1,
                    convsync: false,
                    presentationTimeStamp: CMTime(value: 257, timescale: 48_000),
                    issueDecoderSibling: true
                )
            case .duplicateLease:
                second = first
            case .mismatchedProofAndUnit:
                second = try harness.makeMember(
                    blockCount: 1,
                    convsync: false,
                    presentationTimeStamp: CMTime(value: 256, timescale: 48_000),
                    issueDecoderSibling: true
                )
            case .invariantDrift:
                second = try harness.makeMember(
                    blockCount: 1,
                    convsync: false,
                    presentationTimeStamp: CMTime(value: 256, timescale: 48_000),
                    bsid: 15,
                    issueDecoderSibling: true
                )
            case .wrongStart, .nonzeroSubstream:
                fatalError("已在前面处理")
            }

            XCTAssertThrowsError(try assembler.append(
                inputUnit: mutation == .mismatchedProofAndUnit ? first.unit : second.unit,
                admittedProof: second.proof,
                aggregationLease: second.aggregationLease
            ), "mutation=\(mutation)")
            XCTAssertEqual(assembler.heldLeaseCount, 0, "mutation=\(mutation)")
            XCTAssertEqual(assembler.retainedInputByteCount, 0, "mutation=\(mutation)")
            XCTAssertEqual(harness.coordinator.branchLeaseState(first.aggregationLease.identity), .released)
            if second.aggregationLease.identity != first.aggregationLease.identity {
                XCTAssertEqual(harness.coordinator.branchLeaseState(second.aggregationLease.identity), .released)
            }
            XCTAssertEqual(harness.coordinator.branchLeaseState(try XCTUnwrap(first.decoderLease).identity), .available)
        }
    }

    func testUnsupportedServiceSemanticsNeverReachAggregationLayer() throws {
        let cases: [(UInt8, UInt8, Bool)] = [
            (0, 1, false), // associated
            (0, 2, false), // DVS
            (1, 0, false), // dependent
            (2, 0, false), // converted
            (0, 0, true),  // JOC
        ]

        for (index, entry) in cases.enumerated() {
            let bytes = Task16EAC3Fixture.make(
                blockCount: 6,
                streamType: entry.0,
                substreamID: 0,
                bsid: 16,
                bsmod: entry.1,
                convsync: nil,
                hasJOC: entry.2
            )
            let harness = try Task16EAC3Harness(
                ownerSeed: UInt64(8_000 + index * 100),
                receiptFrame: bytes
            )
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: try harness.makeAuthorization(),
                allocator: PlaybackIdentityAllocator()
            )

            XCTAssertThrowsError(try harness.makeMember(from: bytes, blockCount: 6, presentationTimeStamp: .zero))
            XCTAssertEqual(assembler.appendCallCount, 0)
            XCTAssertEqual(assembler.producedAccessUnitCount, 0)
            XCTAssertEqual(harness.coordinator.issuedBranchLeaseCount, 0)
            XCTAssertEqual(harness.coordinator.failure, .unsupportedAudioServiceSemantic)
        }
    }

    func testAuthorizedEAC3BatchRejectsLegacyTransferBeforeAnyMemberMutation() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 9_000)
        let first = try harness.makeMember(
            blockCount: 3,
            convsync: true,
            presentationTimeStamp: .zero
        )
        let second = try harness.makeMember(
            blockCount: 3,
            convsync: false,
            presentationTimeStamp: CMTime(value: 768, timescale: 48_000)
        )
        let partial = PartialAudioAggregationIdentity(rawValue: 9_100)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(first.aggregationLease.identity, partial: partial), .held)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(second.aggregationLease.identity, partial: partial), .held)
        let payload = first.unit.bytes + second.unit.bytes
        let backing = EAC3AccessUnitBacking(identity: .init(rawValue: 9_101), bytes: payload)
        let bundle = EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: .init(rawValue: 9_102),
            audioBranchAdmissionIdentity: harness.admission,
            outputBackingIdentity: backing.identity,
            outputBackingOwnerIdentity: backing.ownerIdentity,
            outputByteRange: AudioServiceByteRange(offset: 0, length: payload.count)!,
            outputDigest: payload.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:)),
            bundleNonce: .init(rawValue: 9_103)
        )

        XCTAssertEqual(
            harness.coordinator.transferEAC3AggregationLeases(
                [first.aggregationLease.identity, first.aggregationLease.identity],
                partial: partial,
                to: bundle
            ),
            .identityMismatch
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(first.aggregationLease.identity), .held(partial))
        XCTAssertEqual(harness.coordinator.branchLeaseState(second.aggregationLease.identity), .held(partial))
        XCTAssertEqual(
            harness.coordinator.transferEAC3AggregationLeases(
                [first.aggregationLease.identity, second.aggregationLease.identity],
                partial: .init(rawValue: 9_104),
                to: bundle
            ),
            .invalidTransition
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(first.aggregationLease.identity), .held(partial))
        XCTAssertEqual(harness.coordinator.branchLeaseState(second.aggregationLease.identity), .held(partial))

        XCTAssertEqual(
            harness.coordinator.transferEAC3AggregationLeases(
                [first.aggregationLease.identity, second.aggregationLease.identity],
                partial: partial,
                to: bundle
            ),
            .invalidTransition
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(first.aggregationLease.identity), .held(partial))
        XCTAssertEqual(harness.coordinator.branchLeaseState(second.aggregationLease.identity), .held(partial))
        let wrongBacking = EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: bundle.accessUnitIdentity,
            audioBranchAdmissionIdentity: bundle.audioBranchAdmissionIdentity,
            outputBackingIdentity: .init(rawValue: bundle.outputBackingIdentity.rawValue + 1),
            outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity(),
            outputByteRange: bundle.outputByteRange,
            outputDigest: .zero,
            bundleNonce: bundle.bundleNonce
        )
        XCTAssertEqual(
            harness.coordinator.transferEAC3AggregationLeases(
                [first.aggregationLease.identity, second.aggregationLease.identity],
                partial: partial,
                to: wrongBacking
            ),
            .invalidTransition
        )
    }

    func testAuthorizedEAC3SingleLeaseRejectsLegacyTransferBeforeHeldStateMutation() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 9_300)
        let member = try harness.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero
        )
        let partial = PartialAudioAggregationIdentity(rawValue: 9_301)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(
            member.aggregationLease.identity,
            partial: partial
        ), .held)
        let bundle = harness.bundleIdentity(for: member.unit.bytes)

        XCTAssertEqual(harness.coordinator.transferEAC3AggregationLease(
            member.aggregationLease.identity,
            to: bundle
        ), .invalidTransition)
        XCTAssertEqual(harness.coordinator.branchLeaseState(member.aggregationLease.identity), .held(partial))
    }

    func testCloseHoldRetireAndBatchTransferLinearizationNeverRevivesTerminalLease() throws {
        let closeFirst = try Task16EAC3Harness(ownerSeed: 10_000)
        let closeFirstMember = try closeFirst.makeMember(blockCount: 6, convsync: nil, presentationTimeStamp: .zero)
        let closeFence = try XCTUnwrap(closeFirst.coordinator.closeCompressedGate(closeFirst.admission))
        XCTAssertEqual(closeFirst.coordinator.branchLeaseState(closeFirstMember.aggregationLease.identity), .released)
        XCTAssertEqual(
            closeFirst.coordinator.holdEAC3AggregationLease(
                closeFirstMember.aggregationLease.identity,
                partial: .init(rawValue: 10_050)
            ),
            .alreadyDisposed
        )
        XCTAssertTrue(closeFirst.coordinator.isDrained(closeFence))

        let holdFirst = try Task16EAC3Harness(ownerSeed: 10_100)
        let heldMember = try holdFirst.makeMember(blockCount: 6, convsync: nil, presentationTimeStamp: .zero)
        let partial = PartialAudioAggregationIdentity(rawValue: 10_150)
        XCTAssertEqual(holdFirst.coordinator.holdEAC3AggregationLease(heldMember.aggregationLease.identity, partial: partial), .held)
        XCTAssertTrue(holdFirst.coordinator.retireAdmittedProof(heldMember.proof))
        // Task 14 会在最后一张 lease 释放后回收 proof；nil 表示 terminal 记录已离开 registry。
        XCTAssertNil(holdFirst.coordinator.branchLeaseState(heldMember.aggregationLease.identity))
        XCTAssertEqual(
            holdFirst.coordinator.transferEAC3AggregationLeases(
                [heldMember.aggregationLease.identity],
                partial: partial,
                to: holdFirst.bundleIdentity(for: heldMember.unit.bytes)
            ),
            .identityMismatch
        )

        let transferFirst = try Task16EAC3Harness(ownerSeed: 10_200)
        let transferredMember = try transferFirst.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero,
            bindAuthorization: false
        )
        let transferPartial = PartialAudioAggregationIdentity(rawValue: 10_250)
        XCTAssertEqual(
            transferFirst.coordinator.holdEAC3AggregationLease(
                transferredMember.aggregationLease.identity,
                partial: transferPartial
            ),
            .held
        )
        let bundle = transferFirst.bundleIdentity(for: transferredMember.unit.bytes)
        XCTAssertEqual(
            transferFirst.coordinator.transferEAC3AggregationLeases(
                [transferredMember.aggregationLease.identity],
                partial: transferPartial,
                to: bundle
            ),
            .transferred
        )
        let transferFence = try XCTUnwrap(transferFirst.coordinator.closeCompressedGate(transferFirst.admission))
        XCTAssertFalse(transferFirst.coordinator.isDrained(transferFence))
        XCTAssertEqual(
            transferFirst.coordinator.releaseAudioServiceBranchLease(
                transferredMember.aggregationLease.identity,
                expectedOwner: .eac3AccessUnit(bundle)
            ),
            .released
        )
        XCTAssertTrue(transferFirst.coordinator.isDrained(transferFence))
    }

    func testConvsyncVariableFrameSizesDataRateBoundaryAndConfigurationEvidence() throws {
        let harness = try Task16EAC3Harness(ownerSeed: 11_000)
        let assembler = EAC3AccessUnitAssembler(
            coordinator: harness.coordinator,
            authorization: try harness.makeAuthorization(),
            allocator: PlaybackIdentityAllocator()
        )
        let first = try harness.makeMember(
            blockCount: 3,
            convsync: true,
            presentationTimeStamp: .zero,
            byteCount: 16
        )
        let second = try harness.makeMember(
            blockCount: 3,
            convsync: false,
            presentationTimeStamp: CMTime(value: 768, timescale: 48_000),
            byteCount: 16
        )
        XCTAssertNil(try assembler.append(
            inputUnit: first.unit,
            admittedProof: first.proof,
            aggregationLease: first.aggregationLease
        ))
        let output = try XCTUnwrap(try assembler.append(
            inputUnit: second.unit,
            admittedProof: second.proof,
            aggregationLease: second.aggregationLease
        ))

        XCTAssertEqual(output.aggregationProof?.actualDataRateKbps, 8)
        XCTAssertEqual(output.formatConfiguration.serializedBox, Data([
            0x00, 0x00, 0x00, 0x0D, 0x64, 0x65, 0x63, 0x33,
            0xC0, 0x00, 0x20, 0x04, 0x00,
        ]))
        XCTAssertNoThrow(try output.formatConfiguration.validateFinalBoxes([
            output.formatConfiguration.serializedBox,
        ]))

    }

    func testCapacityIsSixAndIdenticalInputsHaveStablePayloadConfigurationAndDigest() throws {
        XCTAssertEqual(FixedEAC3MemberVector<AudioServiceBranchLeaseIdentity>.capacity, 6)
        XCTAssertThrowsError(try FixedEAC3MemberVector(Array(repeating: Task16IdentityFixtures.lease, count: 7)))

        var stable: [(Data, Data, AudioServiceEvidenceDigest)] = []
        for offset in 0..<2 {
            let harness = try Task16EAC3Harness(ownerSeed: UInt64(12_000 + offset * 100))
            let assembler = EAC3AccessUnitAssembler(
                coordinator: harness.coordinator,
                authorization: try harness.makeAuthorization(),
                allocator: PlaybackIdentityAllocator()
            )
            let member = try harness.makeMember(blockCount: 6, convsync: nil, presentationTimeStamp: .zero)
            let output = try XCTUnwrap(try assembler.append(
                inputUnit: member.unit,
                admittedProof: member.proof,
                aggregationLease: member.aggregationLease
            ))
            stable.append((output.payload, output.formatConfiguration.serializedBox, output.payloadDigest))
        }

        XCTAssertEqual(stable[0].0, stable[1].0)
        XCTAssertEqual(stable[0].1, stable[1].1)
        XCTAssertEqual(stable[0].2, stable[1].2)

        let exhaustionHarness = try Task16EAC3Harness(ownerSeed: 12_400)
        let exhaustionAllocator = PlaybackIdentityAllocator()
        exhaustionAllocator.setIssuedValueForTesting(UInt64.max - 2, in: .nonce)
        let exhaustionAssembler = EAC3AccessUnitAssembler(
            coordinator: exhaustionHarness.coordinator,
            authorization: try exhaustionHarness.makeAuthorization(),
            allocator: exhaustionAllocator
        )
        let exhaustionMember = try exhaustionHarness.makeMember(
            blockCount: 6,
            convsync: nil,
            presentationTimeStamp: .zero
        )
        XCTAssertThrowsError(try exhaustionAssembler.append(
            inputUnit: exhaustionMember.unit,
            admittedProof: exhaustionMember.proof,
            aggregationLease: exhaustionMember.aggregationLease
        ))
        XCTAssertEqual(exhaustionAssembler.producedAccessUnitCount, 0)
        XCTAssertEqual(
            exhaustionHarness.coordinator.branchLeaseState(exhaustionMember.aggregationLease.identity),
            .released
        )
    }
}

enum Task16EAC3OwnerKind {
    case audioVideo
    case audioOnly
}

struct Task16EAC3Member {
    let unit: AudioServiceInputUnit
    let proof: AdmittedAudioServiceInputUnitProof
    let aggregationLease: AudioServiceBranchLease
    let decoderLease: AudioServiceBranchLease?
    let ownership: AudioServiceInputUnitOwnership
}

final class Task16EAC3Harness {
    let coordinator: AudioServiceSemanticCoordinator
    let sharedControlExecutor: PlaybackControlExecutor
    let admission: AudioBranchAdmissionIdentity
    let directAdmission: AudioBranchAdmissionIdentity
    private let source: AudioTrackDescriptor
    private let ownerSeed: UInt64
    private let ownerKind: Task16EAC3OwnerKind
    private var nextIdentity: UInt64
    private var currentAuthorization: CompressedAudioCandidatePlanAuthorization?
    private var currentTimeline: HLSTimelineCoordinator?

    init(
        ownerSeed: UInt64,
        receiptFrame: Data? = nil,
        ownerKind: Task16EAC3OwnerKind = .audioVideo
    ) throws {
        self.ownerSeed = ownerSeed
        self.ownerKind = ownerKind
        nextIdentity = ownerSeed + 20
        source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .eac3,
            timeBase: MediaRational(num: 1, den: 48_000)!,
            sampleRate: 48_000,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default])
        )
        let owner = Self.owner(kind: ownerKind, seed: ownerSeed)
        admission = .eac3Aggregation(
            owner,
            branchGeneration: ownerSeed + 5,
            admissionFenceRevision: ownerSeed + 6
        )
        directAdmission = .directCompressed(
            owner,
            branchGeneration: ownerSeed + 5,
            admissionFenceRevision: ownerSeed + 6
        )
        sharedControlExecutor = Self.makeControlExecutor()
        coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: ownerSeed + 7),
            inputFormatGeneration: .init(rawValue: ownerSeed + 8),
            allocator: PlaybackIdentityAllocator(),
            compressedOutputAdmissionAuthority: admission,
            sharedControlExecutor: sharedControlExecutor
        )
        let receiptBytes = receiptFrame ?? Task16EAC3Fixture.make(
            blockCount: 6,
            streamType: 0,
            substreamID: 0,
            bsid: 16,
            bsmod: 0,
            convsync: nil,
            hasJOC: false
        )
        let receiptUnit = makeUnit(bytes: receiptBytes, blockCount: 6, presentationTimeStamp: .zero)
        _ = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: receiptUnit)
    }

    func makeMember(
        blockCount: Int,
        convsync: Bool?,
        presentationTimeStamp: CMTime,
        substreamID: UInt8 = 0,
        bsid: UInt8 = 16,
        audioCodingMode: UInt8 = 2,
        hasLFE: Bool = false,
        byteCount: Int = 16,
        issueDecoderSibling: Bool = false,
        authorization: CompressedAudioCandidatePlanAuthorization? = nil,
        bindAuthorization: Bool = true
    ) throws -> Task16EAC3Member {
        try makeMember(
            from: Task16EAC3Fixture.make(
                blockCount: blockCount,
                streamType: 0,
                substreamID: substreamID,
                bsid: bsid,
                bsmod: 0,
                convsync: convsync,
                hasJOC: false,
                byteCount: byteCount,
                audioCodingMode: audioCodingMode,
                hasLFE: hasLFE
            ),
            blockCount: blockCount,
            presentationTimeStamp: presentationTimeStamp,
            issueDecoderSibling: issueDecoderSibling,
            authorization: authorization,
            bindAuthorization: bindAuthorization
        )
    }

    func makeMember(
        from bytes: Data,
        blockCount: Int,
        presentationTimeStamp: CMTime,
        issueDecoderSibling: Bool = false,
        authorization: CompressedAudioCandidatePlanAuthorization? = nil,
        bindAuthorization: Bool = true
    ) throws -> Task16EAC3Member {
        let unit = makeUnit(bytes: bytes, blockCount: blockCount, presentationTimeStamp: presentationTimeStamp)
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        let ownership = AudioServiceInputUnitOwnership()
        guard case let .admitted(admitted) = coordinator.admit(proof, ownership: ownership) else {
            throw coordinator.failure ?? AudioServiceSemanticFailure.staleProof
        }
        let registered: Bool
        if bindAuthorization {
            let planAuthorization: CompressedAudioCandidatePlanAuthorization
            if let authorization {
                planAuthorization = authorization
            } else if let currentAuthorization {
                planAuthorization = currentAuthorization
            } else {
                planAuthorization = try makeAuthorization()
            }
            registered = try coordinator.registerEligibleCompressedPlan(planAuthorization, for: admitted)
        } else {
            registered = try coordinator.registerEligibleCompressedPlan(admission, for: admitted)
        }
        guard registered,
              let aggregationLease = try coordinator.issueAudioServiceBranchLease(
                  for: admitted,
                  admission: admission
              ) else {
            throw AudioServiceSemanticFailure.staleProof
        }
        let decoderLease: AudioServiceBranchLease?
        if issueDecoderSibling {
            let decoderIdentity = SharedDecoderAdmissionIdentity(
                sourceTrackIdentity: admitted.identity.proofIdentity.parentReceiptIdentity.sourceTrackIdentity,
                inputFormatGeneration: admitted.identity.proofIdentity.inputFormatGeneration,
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 90_000),
                decoderLifecycleGeneration: 90_001,
                decoderAdmissionFenceRevision: 90_002
            )
            guard try coordinator.registerEligibleDecoderPlan(decoderIdentity, for: admitted) else {
                throw AudioServiceSemanticFailure.staleProof
            }
            decoderLease = try coordinator.issueAudioServiceBranchLease(
                for: admitted,
                admission: .decoder(decoderIdentity)
            )
        } else {
            decoderLease = nil
        }
        return Task16EAC3Member(
            unit: unit,
            proof: admitted,
            aggregationLease: aggregationLease,
            decoderLease: decoderLease,
            ownership: ownership
        )
    }

    func makeAuthorization() throws -> CompressedAudioCandidatePlanAuthorization {
        if let currentAuthorization {
            return currentAuthorization
        }
        let binding = try XCTUnwrap(coordinator.bindCompressedOutputPlan())
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                sampleRate: 48_000,
                channels: 2,
                frameSamples: 1_536,
                nativeMask: 3
            ))
        }
        let timeline = HLSTimelineCoordinator(
            parserFactory: parserFactory,
            compressedAudioOutputPlanBinding: binding
        )
        _ = try timeline.consume(.tracks(DemuxTrackSet(
            selectedProgramID: 7,
            video: nil,
            audio: source
        )))
        let frame = Task16EAC3Fixture.make(
            blockCount: 6,
            streamType: 0,
            substreamID: 0,
            bsid: 16,
            bsmod: 0,
            convsync: nil,
            hasJOC: false
        )
        let events = try timeline.consume(.packet(DemuxPacket(
            streamIndex: source.streamIndex,
            codec: .audio(.eac3),
            data: frame,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )))
        XCTAssertEqual(events.filter {
            if case .originEstablished = $0 { return true }
            return false
        }.count, 1, "真实完整 E-AC-3 AU 必须先建立 timeline origin")
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
        let authorization = try XCTUnwrap(coordinator.authorizeCompressedCandidate(plan))
        currentTimeline = timeline
        currentAuthorization = authorization
        return authorization
    }

    func resetAuthorizationTimeline() throws {
        let timeline = try XCTUnwrap(currentTimeline)
        _ = try timeline.consume(.discontinuity(
            DemuxTrackSet(selectedProgramID: 7, video: nil, audio: source),
            reason: .timelineReset
        ))
    }

    func sealedCommitRequest(
        authorization: CompressedAudioCandidatePlanAuthorization,
        partial: PartialAudioAggregationIdentity,
        members: [Task16EAC3Member]
    ) throws -> EAC3SealedCommitRequest {
        let payload = members.reduce(into: Data()) { $0.append($1.unit.bytes) }
        let backing = EAC3AccessUnitBacking(
            identity: .init(rawValue: nextIdentity + 2_000),
            bytes: payload
        )
        let range = AudioServiceByteRange(offset: 0, length: payload.count)!
        let digest = payload.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:))
        let bundle = EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: .init(rawValue: nextIdentity + 2_001),
            audioBranchAdmissionIdentity: admission,
            outputBackingIdentity: backing.identity,
            outputBackingOwnerIdentity: backing.ownerIdentity,
            outputByteRange: range,
            outputDigest: digest,
            bundleNonce: .init(rawValue: nextIdentity + 2_002)
        )
        return try EAC3SealedCommitRequest(
            authorization: authorization,
            partialIdentity: partial,
            orderedMembers: members.map {
                EAC3SealedCommitMember(
                    inputUnit: $0.unit,
                    admittedProof: $0.proof,
                    leaseIdentity: $0.aggregationLease.identity
                )
            },
            outputBacking: backing,
            outputByteRange: range,
            outputDigest: digest,
            bundleIdentity: bundle
        )
    }

    func bundleIdentity(for payload: Data) -> EAC3AccessUnitBundleIdentity {
        let backing = EAC3AccessUnitBacking(identity: .init(rawValue: nextIdentity + 1_000), bytes: payload)
        return EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: .init(rawValue: nextIdentity + 1_001),
            audioBranchAdmissionIdentity: admission,
            outputBackingIdentity: backing.identity,
            outputBackingOwnerIdentity: backing.ownerIdentity,
            outputByteRange: AudioServiceByteRange(offset: 0, length: payload.count)!,
            outputDigest: payload.withUnsafeBytes(AudioServiceEvidenceDigest.init(bytes:)),
            bundleNonce: .init(rawValue: nextIdentity + 1_002)
        )
    }

    func mutatedAdmissions() -> [AudioBranchAdmissionIdentity] {
        let seed = ownerSeed
        let expectedOwner = Self.owner(kind: ownerKind, seed: seed)
        var owners = [
            Self.owner(kind: ownerKind == .audioVideo ? .audioOnly : .audioVideo, seed: seed),
            Self.owner(kind: ownerKind, seed: seed, lifecycleDelta: 1),
            Self.owner(kind: ownerKind, seed: seed, itemDelta: 1),
            Self.owner(kind: ownerKind, seed: seed, mediaDelta: 1),
            Self.owner(kind: ownerKind, seed: seed, participantDelta: 1),
            Self.owner(kind: ownerKind, seed: seed, renditionDelta: 1),
        ]
        if ownerKind == .audioOnly {
            owners.append(Self.owner(kind: ownerKind, seed: seed, selectionDelta: 1))
            owners.append(Self.owner(kind: ownerKind, seed: seed, candidateDelta: 1))
        }
        var admissions = owners.map {
            AudioBranchAdmissionIdentity.eac3Aggregation(
                $0,
                branchGeneration: seed + 5,
                admissionFenceRevision: seed + 6
            )
        }
        admissions.append(.eac3Aggregation(
            expectedOwner,
            branchGeneration: seed + 7,
            admissionFenceRevision: seed + 6
        ))
        admissions.append(.eac3Aggregation(
            expectedOwner,
            branchGeneration: seed + 5,
            admissionFenceRevision: seed + 8
        ))
        return admissions
    }

    private func makeUnit(bytes: Data, blockCount: Int, presentationTimeStamp: CMTime) -> AudioServiceInputUnit {
        defer { nextIdentity += 1 }
        let inspection = try? EAC3FrameInspector.inspect(bytes)
        let channelCount = inspection?.channelCount ?? 2
        let mask: UInt64 = channelCount == 6 ? 0x3F : 3
        return try! AudioServiceInputUnit(
            identity: .init(rawValue: nextIdentity),
            backing: AudioServiceInputBacking(identity: .init(rawValue: nextIdentity + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: presentationTimeStamp,
            parserSampleCount: Int32(blockCount * 256),
            parserSampleRate: 48_000,
            parserChannelLayout: .init(channelCount: channelCount, nativeMask: mask),
            containerMarkedCorrupt: false
        )
    }

    private static func owner(
        kind: Task16EAC3OwnerKind,
        seed: UInt64,
        lifecycleDelta: UInt64 = 0,
        selectionDelta: UInt64 = 0,
        candidateDelta: UInt64 = 0,
        itemDelta: UInt64 = 0,
        mediaDelta: UInt64 = 0,
        participantDelta: UInt64 = 0,
        renditionDelta: UInt64 = 0
    ) -> CompressedAudioBranchOwnerIdentity {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: seed + lifecycleDelta)
        switch kind {
        case .audioVideo:
            return .audioVideo(
                outputLifecycleEpoch: lifecycle,
                itemGeneration: .init(rawValue: seed + 1 + itemDelta),
                mediaEpoch: .init(rawValue: seed + 2 + mediaDelta),
                publicationParticipantID: .init(rawValue: seed + 3 + participantDelta),
                renditionIdentity: .init(rawValue: seed + 4 + renditionDelta)
            )
        case .audioOnly:
            return .audioOnly(
                outputLifecycleEpoch: lifecycle,
                selectionTransactionIdentity: .init(rawValue: seed + 9 + selectionDelta),
                candidateTicket: .init(rawValue: seed + 10 + candidateDelta),
                itemGeneration: .init(rawValue: seed + 1 + itemDelta),
                mediaEpoch: .init(rawValue: seed + 2 + mediaDelta),
                publicationParticipantID: .init(rawValue: seed + 3 + participantDelta),
                renditionIdentity: .init(rawValue: seed + 4 + renditionDelta)
            )
        }
    }

    private static func makeControlExecutor() -> PlaybackControlExecutor {
        PlaybackControlExecutor(
            allocator: PlaybackIdentityAllocator(),
            applyIngress: { _ in .applied },
            applyTerminalIngress: { _ in },
            applyOutputControl: { _, _ in .rejected }
        )
    }
}

enum Task16EAC3Fixture {
    static func make(
        blockCount: Int,
        streamType: UInt8,
        substreamID: UInt8,
        bsid: UInt8,
        bsmod: UInt8,
        convsync: Bool?,
        hasJOC: Bool,
        byteCount: Int = 16,
        audioCodingMode: UInt8 = 2,
        hasLFE: Bool = false
    ) -> Data {
        precondition([1, 2, 3, 6].contains(blockCount))
        precondition(byteCount >= 16 && byteCount <= 4_096 && byteCount.isMultiple(of: 2))
        var bits = Task16EAC3BitWriter()
        bits.write(0x0B77, count: 16)
        bits.write(UInt64(streamType), count: 2)
        bits.write(UInt64(substreamID), count: 3)
        bits.write(UInt64(byteCount / 2 - 1), count: 11)
        bits.write(0, count: 2) // 48 kHz
        bits.write(UInt64([1: 0, 2: 1, 3: 2, 6: 3][blockCount]!), count: 2)
        bits.write(UInt64(audioCodingMode), count: 3)
        bits.write(hasLFE ? 1 : 0, count: 1)
        bits.write(UInt64(bsid), count: 5)
        bits.write(0, count: 5) // dialnorm
        bits.write(0, count: 1) // compre
        if streamType == 1 { bits.write(0, count: 1) }
        bits.write(0, count: 1) // mixmdate
        bits.write(1, count: 1) // infomdate
        bits.write(UInt64(bsmod), count: 3)
        bits.write(0, count: 1) // copyrightb
        bits.write(1, count: 1) // origbs
        bits.write(0, count: 2) // dsurmod
        bits.write(0, count: 2) // dheadphonmod
        bits.write(0, count: 1) // audprodie
        bits.write(0, count: 1) // sourcefscod
        if streamType == 0, blockCount < 6 {
            bits.write(convsync == true ? 1 : 0, count: 1)
        }
        if streamType == 2 { bits.write(0, count: 6) }
        bits.write(hasJOC ? 1 : 0, count: 1)
        if hasJOC {
            bits.write(1, count: 6)
            bits.write(1, count: 8)
            bits.write(1, count: 8)
        }
        return bits.data(paddedTo: byteCount)
    }
}

struct Task16EAC3BitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt64, count: Int) {
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> UInt64(offset)) & 1) << UInt8(7 - bitCount % 8)
            bitCount += 1
        }
    }

    func data(paddedTo byteCount: Int) -> Data {
        precondition(bytes.count <= byteCount)
        return Data(bytes + Array(repeating: 0, count: byteCount - bytes.count))
    }
}

private enum Task16IdentityFixtures {
    static let lease = AudioServiceBranchLeaseIdentity(
        proofIdentity: .init(
            proofIdentity: .init(
                parentReceiptIdentity: .init(
                    sourceTrackIdentity: .init(streamIndex: 1, trackNonce: 1),
                    inputFormatGeneration: .init(rawValue: 1),
                    classificationEvidenceIdentity: .init(
                        trackRoleReceiptIdentity: .init(
                            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: 1),
                            selectedProgramID: 1,
                            streamIndex: 1,
                            role: .main,
                            serviceEvidence: .resolved(.independentMain),
                            dispositions: [.default],
                            receiptNonce: 1
                        ),
                        firstInputUnitIdentity: nil,
                        headerBackingIdentity: nil,
                        headerBackingOwnerIdentity: nil,
                        headerByteRange: nil,
                        evidenceDigest: .zero
                    ),
                    semantic: .independentMain,
                    receiptNonce: 1
                ),
                inputFormatGeneration: .init(rawValue: 1),
                inputUnitIdentity: .init(rawValue: 1),
                unitKind: .eac3Syncframe,
                backingIdentity: .init(rawValue: 1),
                backingOwnerIdentity: AudioServiceBackingOwnerIdentity(),
                byteRange: AudioServiceByteRange(offset: 0, length: 1)!,
                evidenceDigest: .zero,
                observedSemantic: .independentMain,
                validationNonce: .init(rawValue: 1),
                proofNonce: .init(rawValue: 1),
                codecFacts: nil
            ),
            admissionNonce: 1
        ),
        admissionIdentity: .eac3Aggregation(
            .audioVideo(
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 1),
                itemGeneration: .init(rawValue: 1),
                mediaEpoch: .init(rawValue: 1),
                publicationParticipantID: .init(rawValue: 1),
                renditionIdentity: .init(rawValue: 1)
            ),
            branchGeneration: 1,
            admissionFenceRevision: 1
        ),
        leaseNonce: .init(rawValue: 1)
    )
}
