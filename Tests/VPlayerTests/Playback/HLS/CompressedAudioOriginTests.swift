// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class CompressedAudioOriginTests: XCTestCase {
    func testCompressedAuthorityWithoutSharedExecutorCannotBindOutputPlan() throws {
        let harness = try Task16AC3Harness(
            sampleRate: 48_000,
            fscod: 0,
            ownerSeed: 39_000,
            usesSharedControlExecutor: false
        )

        XCTAssertNil(harness.coordinator.bindCompressedOutputPlan(),
                     "配置压缩 authority 但没有共享控制 executor 时不得签发 binding")
    }

    func testSharedExecutorQueuesConcurrentTimelineResetBeforeStaleRegistration() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 39_100)
        let raw = try harness.makeUnregisteredMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero
        )
        let timeline = try harness.makeTimeline(origin: .zero)
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
        let authorization = try XCTUnwrap(harness.coordinator.authorizeCompressedCandidate(plan))
        let executor = try XCTUnwrap(harness.sharedControlExecutor)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        executor.submit {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        let reset = Task16TimelineResetProbe(
            timeline: timeline,
            tracks: harness.timelineTracks
        )
        DispatchQueue.global().async { reset.run() }
        XCTAssertEqual(reset.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(reset.completed.wait(timeout: .now() + 0.1), .timedOut,
                       "timeline reset 必须排到共享 executor，不能与 AudioService CAS 并发改状态")
        release.signal()
        XCTAssertEqual(reset.completed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(reset.succeeded)

        XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(
            authorization,
            for: raw.proof
        ))
        XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.branchGates, 0)
        XCTAssertEqual(harness.coordinator.issuedBranchLeaseCount, 0)
    }

    func testStaleAuthorizationAfterRegistrationCannotIssueLeaseOrConsumeOwnership() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 39_300)
        let ownership = AudioServiceInputUnitOwnership()
        let raw = try harness.makeUnregisteredMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero,
            ownership: ownership
        )
        let timeline = try harness.makeTimeline(origin: .zero)
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
        let authorization = try XCTUnwrap(harness.coordinator.authorizeCompressedCandidate(plan))
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
            authorization,
            for: raw.proof
        ))
        let before = harness.coordinator.withAudioServiceCAS {
            let gate = harness.coordinator.audioServiceLeaseState.branchGates.first {
                $0.admissionIdentity == harness.admission
            }
            return (harness.coordinator.issuedBranchLeaseCount, gate?.outstandingCount)
        }

        _ = try timeline.consume(.discontinuity(harness.timelineTracks, reason: .timelineReset))

        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: raw.proof,
            admission: harness.admission
        ))
        let after = harness.coordinator.withAudioServiceCAS {
            let gate = harness.coordinator.audioServiceLeaseState.branchGates.first {
                $0.admissionIdentity == harness.admission
            }
            return (harness.coordinator.issuedBranchLeaseCount, gate?.outstandingCount)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(ownership.releaseCount, 0)
    }

    func testCompressedAuthorizationGraphDoesNotRetainCoordinatorTimelineStateOrPlan() throws {
        weak var weakCoordinator: AudioServiceSemanticCoordinator?
        weak var weakTimeline: HLSTimelineCoordinator?
        weak var weakState: AudioServiceLeaseState?
        weak var weakPlan: HLSTimelineCompressedAudioCandidatePlan?
        weak var weakAuthorization: CompressedAudioCandidatePlanAuthorization?

        do {
            let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 39_500)
            let raw = try harness.makeUnregisteredMember(
                fscod: 0,
                frmsizecod: 20,
                presentationTimeStamp: .zero
            )
            let timeline = try harness.makeTimeline(origin: .zero)
            let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
            let authorization = try XCTUnwrap(harness.coordinator.authorizeCompressedCandidate(plan))
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
                authorization,
                for: raw.proof
            ))

            weakCoordinator = harness.coordinator
            weakTimeline = timeline
            weakState = harness.coordinator.audioServiceLeaseState
            weakPlan = plan
            weakAuthorization = authorization
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertNil(weakTimeline)
        XCTAssertNil(weakState, "gate/participation 的 authorization 不得反向保活 lease state")
        XCTAssertNil(weakPlan)
        XCTAssertNil(weakAuthorization)
    }

    func testTimelineOpaquePlanBindsRealOriginTargetCoordinatorAndFullAdmission() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_000)
        let raw = try harness.makeUnregisteredMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero
        )
        let timeline = try harness.makeTimeline(origin: .zero)
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
        let authorization = try XCTUnwrap(harness.coordinator.authorizeCompressedCandidate(plan))
        XCTAssertTrue(harness.coordinator.bindCompressedOutputPlan() === plan.outputBinding)
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(authorization, for: raw.proof))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: raw.proof,
            admission: harness.admission
        ))
        XCTAssertEqual(harness.coordinator.branchLeaseState(lease.identity), .available)

        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: raw.proof,
            admission: harness.mutatedAdmissions()[0]
        ))

        let other = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_200)
        XCTAssertNil(other.coordinator.authorizeCompressedCandidate(plan),
                     "绑定目标 coordinator 的 plan 不能跨 issuer 使用")
    }

    func testAuthorizedDirectLeaseRejectsLegacyTransferBeforeAnyStateMutation() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_300)
        let member = try harness.makeMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero
        )
        let proof = member.proof.identity.proofIdentity
        let bundle = CompressedAccessUnitBundleIdentity(
            inputUnitIdentity: member.unit.identity,
            audioBranchAdmissionIdentity: harness.admission,
            backingIdentity: member.unit.backing.identity,
            backingOwnerIdentity: member.unit.backing.ownerIdentity,
            byteRange: member.unit.byteRange,
            digest: proof.evidenceDigest,
            bundleNonce: .init(rawValue: 40_301)
        )

        XCTAssertEqual(harness.coordinator.transferCompressedLease(
            member.lease.identity,
            to: bundle
        ), .invalidTransition)
        XCTAssertEqual(harness.coordinator.branchLeaseState(member.lease.identity), .available)
    }

    func testTimelineUnknownOrMiddleOriginCannotSignPlanOpenGateOrIssueLease() throws {
        let unknownHarness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_400)
        let raw = try unknownHarness.makeUnregisteredMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero
        )
        let unknown = try unknownHarness.makeTimelineWithoutOrigin()
        XCTAssertNil(unknown.makeCompressedAudioCandidatePlan())
        let middleHarness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_500)
        let middle = try middleHarness.makeTimelineWithMiddleVideoOrigin()
        XCTAssertNil(middle.makeCompressedAudioCandidatePlan())
        XCTAssertEqual(unknownHarness.coordinator.audioServiceRegistryUsage.branchGates, 0)
        XCTAssertEqual(middleHarness.coordinator.audioServiceRegistryUsage.branchGates, 0)
        XCTAssertEqual(unknownHarness.coordinator.issuedBranchLeaseCount, 0)
        XCTAssertEqual(middleHarness.coordinator.issuedBranchLeaseCount, 0)
        XCTAssertNil(try unknownHarness.coordinator.issueAudioServiceBranchLease(
            for: raw.proof,
            admission: unknownHarness.admission
        ))
    }

    func testTimelinePlanAndAuthorizationExpireAcrossGenerationChange() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 40_600)
        let raw = try harness.makeUnregisteredMember(
            fscod: 0,
            frmsizecod: 20,
            presentationTimeStamp: .zero
        )
        let timeline = try harness.makeTimeline(origin: .zero)
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
        let authorization = try XCTUnwrap(harness.coordinator.authorizeCompressedCandidate(plan))

        _ = try timeline.consume(.discontinuity(
            harness.timelineTracks,
            reason: .timelineReset
        ))

        XCTAssertNil(harness.coordinator.authorizeCompressedCandidate(plan))
        XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(authorization, for: raw.proof))
        XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.branchGates, 0)
        XCTAssertEqual(harness.coordinator.issuedBranchLeaseCount, 0)
    }

    func testAC3DirectAccessUnitPreservesExactInputBackingAtEveryPrimaryRate() throws {
        let cases: [(UInt8, Int32)] = [(0, 48_000), (1, 44_100), (2, 32_000)]

        for (fscod, sampleRate) in cases {
            let harness = try Task16AC3Harness(sampleRate: sampleRate, fscod: fscod, ownerSeed: UInt64(sampleRate))
            let member = try harness.makeMember(fscod: fscod, frmsizecod: 20, presentationTimeStamp: .zero)
            let builder = try AC3DirectAccessUnitBuilder(
                coordinator: harness.coordinator,
                authorization: member.authorization
            )

            let accessUnit = try builder.makeAccessUnit(
                inputUnit: member.unit,
                admittedProof: member.proof,
                directLease: member.lease,
                bundleNonce: .init(rawValue: UInt64(sampleRate + 1))
            )

            XCTAssertEqual(accessUnit.kind, .ac3Direct)
            XCTAssertEqual(accessUnit.codec, .ac3)
            XCTAssertEqual(accessUnit.sampleRate, sampleRate)
            XCTAssertEqual(accessUnit.channelCount, 2)
            XCTAssertEqual(accessUnit.sampleCount, 1_536)
            XCTAssertEqual(accessUnit.framesPerPacket, 1_536)
            XCTAssertEqual(accessUnit.presentationStart, .zero)
            XCTAssertEqual(accessUnit.presentationEnd, CMTime(value: 1_536, timescale: sampleRate))
            XCTAssertEqual(accessUnit.payload, member.unit.bytes)
            XCTAssertEqual(accessUnit.payloadRange, member.unit.byteRange)
            XCTAssertEqual(accessUnit.payloadDigest, member.proof.identity.proofIdentity.evidenceDigest)
            XCTAssertEqual(
                accessUnit.payloadIdentity,
                .audioService(
                    member.unit.backing.identity,
                    member.unit.backing.ownerIdentity
                )
            )
            XCTAssertTrue(accessUnit.directInputBacking === member.unit.backing)
            XCTAssertEqual(accessUnit.directBundleIdentity?.inputUnitIdentity, member.unit.identity)
            XCTAssertEqual(accessUnit.directBundleIdentity?.audioBranchAdmissionIdentity, harness.admission)
            XCTAssertEqual(
                harness.coordinator.branchLeaseState(member.lease.identity),
                .transferred(.compressedAccessUnit(try XCTUnwrap(accessUnit.directBundleIdentity)))
            )
            XCTAssertTrue(harness.coordinator.claimCompressedAudioWriterSubmission(
                accessUnit.writerSubmission,
                expectedIdentity: CompressedAudioWriterExpectedIdentity(
                    codec: .ac3,
                    admissionIdentity: harness.admission,
                    formatConfiguration: accessUnit.formatConfiguration
                )
            ))
            XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 1)
            XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 0)
        }
    }

    func testAC3Dac3UsesBitRateCodeAndAllowsOnly44100FrameSizeParityAlternation() throws {
        let harness = try Task16AC3Harness(sampleRate: 44_100, fscod: 1, ownerSeed: 50_000)
        let even = try harness.makeMember(fscod: 1, frmsizecod: 20, presentationTimeStamp: .zero)
        let builder = try AC3DirectAccessUnitBuilder(
            coordinator: harness.coordinator,
            authorization: even.authorization
        )
        let first = try builder.makeAccessUnit(
            inputUnit: even.unit,
            admittedProof: even.proof,
            directLease: even.lease,
            bundleNonce: .init(rawValue: 50_100)
        )
        let odd = try harness.makeMember(
            fscod: 1,
            frmsizecod: 21,
            presentationTimeStamp: CMTime(value: 1_536, timescale: 44_100)
        )
        let second = try builder.makeAccessUnit(
            inputUnit: odd.unit,
            admittedProof: odd.proof,
            directLease: odd.lease,
            bundleNonce: .init(rawValue: 50_101)
        )

        XCTAssertEqual(first.payload.count, 834)
        XCTAssertEqual(second.payload.count, 836)
        XCTAssertEqual(first.formatConfiguration, second.formatConfiguration)
        XCTAssertEqual(first.formatConfiguration.serializedBox, Data([
            0x00, 0x00, 0x00, 0x0B, 0x64, 0x61, 0x63, 0x33,
            0x50, 0x11, 0x40,
        ]))
        XCTAssertNoThrow(try first.formatConfiguration.validateFinalBoxes([
            first.formatConfiguration.serializedBox,
        ]))

        for (offset, mutation) in [(0, (UInt8(22), UInt8(2))), (1, (UInt8(20), UInt8(0)))] {
            let driftHarness = try Task16AC3Harness(
                sampleRate: 48_000,
                fscod: 0,
                ownerSeed: UInt64(51_000 + offset * 100)
            )
            let baseline = try driftHarness.makeMember(
                fscod: 0,
                frmsizecod: 20,
                presentationTimeStamp: .zero
            )
            let driftBuilder = try AC3DirectAccessUnitBuilder(
                coordinator: driftHarness.coordinator,
                authorization: baseline.authorization
            )
            _ = try driftBuilder.makeAccessUnit(
                inputUnit: baseline.unit,
                admittedProof: baseline.proof,
                directLease: baseline.lease,
                bundleNonce: .init(rawValue: UInt64(51_050 + offset * 100))
            )
            let changed = try driftHarness.makeMember(
                fscod: 0,
                frmsizecod: mutation.0,
                acmod: mutation.1,
                presentationTimeStamp: CMTime(value: Int64((offset + 1) * 1_536), timescale: 48_000)
            )
            XCTAssertThrowsError(try driftBuilder.makeAccessUnit(
                inputUnit: changed.unit,
                admittedProof: changed.proof,
                directLease: changed.lease,
                bundleNonce: .init(rawValue: UInt64(51_051 + offset * 100))
            ))
            XCTAssertEqual(driftHarness.coordinator.branchLeaseState(changed.lease.identity), .released)
        }
    }

    func testAC3AndEAC3OriginBoundaryMatrixFreezesOnlyEligibleCurrentOrNextAU() throws {
        for codec in [VPlayerPlayback.AudioCodec.ac3, .eac3] {
            let start = CMTime(value: 10_000, timescale: 48_000)
            let end = CMTime(value: 11_536, timescale: 48_000)
            let interval = try CompressedAudioAccessUnitInterval(start: start, end: end)
            let generation = AudioItemGenerationIdentity(rawValue: codec == .ac3 ? 60_000 : 60_001)

            let atStart = try CompressedAudioOriginPlanner.evaluate(
                codec: codec,
                accessUnitInterval: interval,
                mediaOrigin: start,
                itemGeneration: generation
            )
            let inMiddle = try CompressedAudioOriginPlanner.evaluate(
                codec: codec,
                accessUnitInterval: interval,
                mediaOrigin: CMTime(value: 10_001, timescale: 48_000),
                itemGeneration: generation
            )
            let atEnd = try CompressedAudioOriginPlanner.evaluate(
                codec: codec,
                accessUnitInterval: interval,
                mediaOrigin: end,
                itemGeneration: generation
            )
            let unknown = try CompressedAudioOriginPlanner.evaluate(
                codec: codec,
                accessUnitInterval: nil,
                mediaOrigin: start,
                itemGeneration: generation
            )

            XCTAssertEqual(atStart.decision, .eligible(.currentAccessUnit))
            XCTAssertEqual(atEnd.decision, .eligible(.nextAccessUnit))
            XCTAssertNotNil(atStart.compressedSideEffectAuthorization)
            XCTAssertNotNil(atEnd.compressedSideEffectAuthorization)
            for plan in [inMiddle, unknown] {
                XCTAssertEqual(plan.decision, .ineligible(.mediaOriginCutsCompressedAccessUnit))
                XCTAssertNil(plan.compressedSideEffectAuthorization)
                XCTAssertEqual(plan.sideEffects, .zero)
                XCTAssertFalse(plan.mayFreezePublicationParticipant)
                XCTAssertTrue(plan.sameChannelAACRemainsEligible)
                XCTAssertFalse(plan.mayReduceChannelCountToKeepCompressedCandidate)
            }
        }
    }

    func testOriginPlanCannotCrossItemGenerationAndNewGenerationReevaluatesNewOrigin() throws {
        let interval = try CompressedAudioAccessUnitInterval(
            start: CMTime(value: 100, timescale: 1_000),
            end: CMTime(value: 132, timescale: 1_000)
        )
        let oldGeneration = AudioItemGenerationIdentity(rawValue: 70_000)
        let newGeneration = AudioItemGenerationIdentity(rawValue: 70_001)
        let old = try CompressedAudioOriginPlanner.evaluate(
            codec: .eac3,
            accessUnitInterval: interval,
            mediaOrigin: CMTime(value: 101, timescale: 1_000),
            itemGeneration: oldGeneration
        )
        let reevaluated = try CompressedAudioOriginPlanner.evaluate(
            codec: .eac3,
            accessUnitInterval: interval,
            mediaOrigin: CMTime(value: 100, timescale: 1_000),
            itemGeneration: newGeneration
        )

        XCTAssertEqual(old.decision, .ineligible(.mediaOriginCutsCompressedAccessUnit))
        XCTAssertFalse(old.authorizes(itemGeneration: newGeneration))
        XCTAssertEqual(reevaluated.decision, .eligible(.currentAccessUnit))
        XCTAssertTrue(reevaluated.authorizes(itemGeneration: newGeneration))
        XCTAssertNotEqual(old.planIdentity, reevaluated.planIdentity)
    }

    func testWriterExpectedIdentityRejectsEveryOwnerAdmissionAndBundleFieldMutation() throws {
        for ownerKind in [Task16OwnerKind.audioVideo, .audioOnly] {
            let harness = try Task16AC3Harness(
                sampleRate: 48_000,
                fscod: 0,
                ownerSeed: ownerKind == .audioVideo ? 80_000 : 81_000,
                ownerKind: ownerKind
            )
            let member = try harness.makeMember(fscod: 0, frmsizecod: 20, presentationTimeStamp: .zero)
            let valid = try harness.build(member: member, admission: harness.admission, bundleNonce: 82_000)
            let expected = CompressedAudioWriterExpectedIdentity(
                codec: .ac3,
                admissionIdentity: harness.admission,
                formatConfiguration: valid.formatConfiguration
            )
            XCTAssertTrue(expected.accepts(valid.writerSubmission))

            for (name, admission) in harness.mutatedAdmissions().enumerated() {
                let mutationHarness = try Task16AC3Harness(
                    sampleRate: 48_000,
                    fscod: 0,
                    ownerSeed: ownerKind == .audioVideo ? 80_000 : 81_000,
                    ownerKind: ownerKind,
                    admissionAuthority: admission
                )
                let changed = try mutationHarness.makeMember(
                    fscod: 0,
                    frmsizecod: 20,
                    presentationTimeStamp: CMTime(value: Int64(name + 1) * 1_536, timescale: 48_000),
                    admission: admission
                )
                let output = try mutationHarness.build(
                    member: changed,
                    admission: admission,
                    bundleNonce: UInt64(82_100 + name)
                )
                XCTAssertFalse(expected.accepts(output.writerSubmission), "mutation=\(name), owner=\(ownerKind)")
            }

            let bundle = try XCTUnwrap(valid.directBundleIdentity)
            let wrongEAC3Bundle = EAC3AccessUnitBundleIdentity(
                accessUnitIdentity: .init(rawValue: 83_000),
                audioBranchAdmissionIdentity: harness.aggregationAdmission,
                outputBackingIdentity: .init(rawValue: 83_001),
                outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity(),
                outputByteRange: valid.payloadRange,
                outputDigest: valid.payloadDigest,
                bundleNonce: .init(rawValue: bundle.bundleNonce.rawValue)
            )
            XCTAssertFalse(expected.accepts(CompressedAudioWriterSubmission(
                accessUnit: valid,
                bundleIdentity: .eac3(wrongEAC3Bundle),
                admissionIdentity: valid.admissionIdentity,
                payloadIdentity: valid.payloadIdentity,
                payloadRange: valid.payloadRange,
                payloadDigest: valid.payloadDigest,
                formatConfiguration: valid.formatConfiguration
            )))

            let wrongRange = AudioServiceByteRange(offset: 0, length: valid.payloadRange.length - 1)!
            let badSubmissions = [
                CompressedAudioWriterSubmission(
                    accessUnit: valid,
                    bundleIdentity: .direct(bundle),
                    admissionIdentity: harness.mutatedAdmissions()[0],
                    payloadIdentity: valid.payloadIdentity,
                    payloadRange: valid.payloadRange,
                    payloadDigest: valid.payloadDigest,
                    formatConfiguration: valid.formatConfiguration
                ),
                CompressedAudioWriterSubmission(
                    accessUnit: valid,
                    bundleIdentity: .direct(bundle),
                    admissionIdentity: valid.admissionIdentity,
                    payloadIdentity: .eac3(.init(rawValue: 1), EAC3OutputBackingOwnerIdentity()),
                    payloadRange: valid.payloadRange,
                    payloadDigest: valid.payloadDigest,
                    formatConfiguration: valid.formatConfiguration
                ),
                CompressedAudioWriterSubmission(
                    accessUnit: valid,
                    bundleIdentity: .direct(bundle),
                    admissionIdentity: valid.admissionIdentity,
                    payloadIdentity: valid.payloadIdentity,
                    payloadRange: wrongRange,
                    payloadDigest: valid.payloadDigest,
                    formatConfiguration: valid.formatConfiguration
                ),
                CompressedAudioWriterSubmission(
                    accessUnit: valid,
                    bundleIdentity: .direct(bundle),
                    admissionIdentity: valid.admissionIdentity,
                    payloadIdentity: valid.payloadIdentity,
                    payloadRange: valid.payloadRange,
                    payloadDigest: .zero,
                    formatConfiguration: valid.formatConfiguration
                ),
            ]
            for submission in badSubmissions {
                XCTAssertFalse(expected.accepts(submission))
            }
        }
    }

    func testWriterClaimIsOneShotAndReplayCannotReleaseOrAppendAgain() throws {
        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 88_000)
        let member = try harness.makeMember(fscod: 0, frmsizecod: 20, presentationTimeStamp: .zero)
        let accessUnit = try harness.build(member: member, admission: harness.admission, bundleNonce: 88_100)
        let expected = CompressedAudioWriterExpectedIdentity(
            codec: .ac3,
            admissionIdentity: harness.admission,
            formatConfiguration: accessUnit.formatConfiguration
        )

        XCTAssertTrue(harness.coordinator.claimCompressedAudioWriterSubmission(
            accessUnit.writerSubmission,
            expectedIdentity: expected
        ))
        XCTAssertFalse(harness.coordinator.claimCompressedAudioWriterSubmission(
            accessUnit.writerSubmission,
            expectedIdentity: expected
        ))
        XCTAssertEqual(harness.coordinator.branchLeaseState(member.lease.identity),
                       .transferred(.compressedAccessUnit(try XCTUnwrap(accessUnit.directBundleIdentity))))
        XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 1)
        XCTAssertFalse(harness.coordinator.claimCompressedAudioWriterSubmission(
            accessUnit.writerSubmission,
            expectedIdentity: expected
        ))
        XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 1)
    }

    func testPayloadRangeFailureIsExplicitAndCannotCreateWriterClaim() throws {
        let backing = EAC3AccessUnitBacking(identity: .init(rawValue: 89_000), bytes: Data([1, 2, 3, 4]))
        let invalidRange = AudioServiceByteRange(offset: 0, length: 5)!
        XCTAssertThrowsError(try CompressedAudioPayloadSeal.eac3(
            backing: backing,
            range: invalidRange,
            digest: .zero
        ))

        let harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 89_100)
        XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)
    }

    func testDac3AndDec3FinalValidationRejectsMissingDuplicateWrongTypeReservedAndTamperedFields() throws {
        let ac3Harness = try Task16AC3Harness(sampleRate: 48_000, fscod: 0, ownerSeed: 90_000)
        let ac3Member = try ac3Harness.makeMember(fscod: 0, frmsizecod: 20, presentationTimeStamp: .zero)
        let ac3 = try ac3Harness.build(member: ac3Member, admission: ac3Harness.admission, bundleNonce: 90_100)
            .formatConfiguration
        let eac3 = CompressedAudioFormatConfiguration.eac3(try EAC3CompressedAudioConfiguration(
            sampleRate: 48_000,
            bsid: 16,
            bsmod: 0,
            audioCodingMode: 2,
            hasLFE: false,
            asvc: false,
            maximumDataRateKbps: 24
        ))

        XCTAssertEqual(ac3.serializedBox, Data([
            0x00, 0x00, 0x00, 0x0B, 0x64, 0x61, 0x63, 0x33,
            0x10, 0x11, 0x40,
        ]))
        XCTAssertEqual(eac3.serializedBox, Data([
            0x00, 0x00, 0x00, 0x0D, 0x64, 0x65, 0x63, 0x33,
            0x00, 0xC0, 0x20, 0x04, 0x00,
        ]))

        for configuration in [ac3, eac3] {
            let valid = configuration.serializedBox
            XCTAssertThrowsError(try configuration.validateFinalBoxes([]))
            XCTAssertThrowsError(try configuration.validateFinalBoxes([valid, valid]))

            var wrongType = valid
            wrongType.replaceSubrange(4..<8, with: Data([0x66, 0x72, 0x65, 0x65]))
            XCTAssertThrowsError(try configuration.validateFinalBoxes([wrongType]))

            var wrongSize = valid
            wrongSize[3] &-= 1
            XCTAssertThrowsError(try configuration.validateFinalBoxes([wrongSize]))

            var reserved = valid
            if configuration.codec == .ac3 {
                reserved[10] |= 0x01
            } else {
                reserved[10] |= 0x01
            }
            XCTAssertThrowsError(try configuration.validateFinalBoxes([reserved]))

            var tampered = valid
            tampered[9] ^= 0x20
            XCTAssertThrowsError(try configuration.validateFinalBoxes([tampered]))
        }

        XCTAssertThrowsError(try ac3.validateFinalBoxes([eac3.serializedBox]))
        XCTAssertThrowsError(try eac3.validateFinalBoxes([ac3.serializedBox]))
        var associatedService = eac3.serializedBox
        associatedService[11] |= 0x80
        XCTAssertThrowsError(try eac3.validateFinalBoxes([associatedService]))
        let mismatchedEAC3 = CompressedAudioFormatConfiguration.eac3(try EAC3CompressedAudioConfiguration(
            sampleRate: 48_000,
            bsid: 15,
            bsmod: 0,
            audioCodingMode: 2,
            hasLFE: false,
            asvc: false,
            maximumDataRateKbps: 24
        ))
        XCTAssertThrowsError(try eac3.validateFinalBoxes([mismatchedEAC3.serializedBox]))
    }

    func testConfigurationEvidenceStopsAtVerifiedBoxesUntilTask17ProvidesRealSealedBacking() throws {
        let configuration = CompressedAudioFormatConfiguration.eac3(try EAC3CompressedAudioConfiguration(
            sampleRate: 48_000,
            bsid: 16,
            bsmod: 0,
            audioCodingMode: 2,
            hasLFE: false,
            asvc: false,
            maximumDataRateKbps: 24
        ))
        XCTAssertNoThrow(try configuration.validateFinalBoxes([configuration.serializedBox]))
        var wrongDigestEvidence = configuration.serializedBox
        wrongDigestEvidence[9] ^= 0x01
        XCTAssertThrowsError(try configuration.validateFinalBoxes([wrongDigestEvidence]))
    }

    func testIneligibleOriginCannotOpenCompressedGateOrIssueLeaseAndDecoderSiblingConsumesOnce() throws {
        for originKind in 0..<2 {
            let harness = try Task16AC3Harness(
                sampleRate: 48_000,
                fscod: 0,
                ownerSeed: UInt64(101_000 + originKind * 100)
            )
            let raw = try harness.makeUnregisteredMember(
                fscod: 0,
                frmsizecod: 20,
                presentationTimeStamp: .zero
            )
            let timeline = originKind == 0
                ? try harness.makeTimelineWithMiddleVideoOrigin()
                : try harness.makeTimelineWithoutOrigin()
            XCTAssertNil(timeline.makeCompressedAudioCandidatePlan())
            XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.branchGates, 0)
            XCTAssertEqual(harness.coordinator.issuedBranchLeaseCount, 0)
            XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)

            let decoder = SharedDecoderAdmissionIdentity(
                sourceTrackIdentity: raw.proof.identity.proofIdentity.parentReceiptIdentity.sourceTrackIdentity,
                inputFormatGeneration: raw.proof.identity.proofIdentity.inputFormatGeneration,
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 101_500),
                decoderLifecycleGeneration: 101_501,
                decoderAdmissionFenceRevision: 101_502
            )
            XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(decoder, for: raw.proof))
            let decoderLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
                for: raw.proof,
                admission: .decoder(decoder)
            ))
            XCTAssertEqual(harness.coordinator.transferDecoderLease(
                decoderLease.identity,
                to: .init(rawValue: 101_503)
            ), .transferred)
            XCTAssertEqual(harness.coordinator.transferDecoderLease(
                decoderLease.identity,
                to: .init(rawValue: 101_503)
            ), .alreadyDisposed)
        }
    }
}

private enum Task16OwnerKind: Equatable {
    case audioVideo
    case audioOnly
}

private struct Task16AC3Member {
    let unit: AudioServiceInputUnit
    let proof: AdmittedAudioServiceInputUnitProof
    let lease: AudioServiceBranchLease
    let authorization: CompressedAudioCandidatePlanAuthorization
}

private struct Task16UnregisteredAC3Member {
    let unit: AudioServiceInputUnit
    let proof: AdmittedAudioServiceInputUnitProof
}

private final class Task16AC3Harness {
    let coordinator: AudioServiceSemanticCoordinator
    let sharedControlExecutor: PlaybackControlExecutor?
    let admission: AudioBranchAdmissionIdentity
    let aggregationAdmission: AudioBranchAdmissionIdentity
    private let source: AudioTrackDescriptor
    private let fscod: UInt8
    private let ownerSeed: UInt64
    private let ownerKind: Task16OwnerKind
    private var nextIdentity: UInt64

    var timelineTracks: DemuxTrackSet {
        DemuxTrackSet(selectedProgramID: 7, video: nil, audio: source)
    }

    init(
        sampleRate: Int32,
        fscod: UInt8,
        ownerSeed: UInt64,
        ownerKind: Task16OwnerKind = .audioVideo,
        admissionAuthority: AudioBranchAdmissionIdentity? = nil,
        usesSharedControlExecutor: Bool = true
    ) throws {
        self.fscod = fscod
        self.ownerSeed = ownerSeed
        self.ownerKind = ownerKind
        nextIdentity = ownerSeed + 100
        source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .ac3,
            timeBase: MediaRational(num: 1, den: sampleRate)!,
            sampleRate: sampleRate,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default])
        )
        let owner = Self.owner(kind: ownerKind, seed: ownerSeed)
        admission = .directCompressed(
            owner,
            branchGeneration: ownerSeed + 10,
            admissionFenceRevision: ownerSeed + 11
        )
        aggregationAdmission = .eac3Aggregation(
            owner,
            branchGeneration: ownerSeed + 10,
            admissionFenceRevision: ownerSeed + 11
        )
        sharedControlExecutor = usesSharedControlExecutor
            ? Self.makeControlExecutor()
            : nil
        coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: ownerSeed + 1),
            inputFormatGeneration: .init(rawValue: ownerSeed + 2),
            allocator: PlaybackIdentityAllocator(),
            compressedOutputAdmissionAuthority: admissionAuthority ?? admission,
            sharedControlExecutor: sharedControlExecutor
        )
        let receiptBytes = AssemblerTestFixtures.syntheticAC3Frame(fscod: fscod, frmsizecod: 20, bsmod: 0)
        let receiptUnit = makeUnit(bytes: receiptBytes, presentationTimeStamp: .zero)
        _ = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: receiptUnit)
    }

    func makeMember(
        fscod: UInt8,
        frmsizecod: UInt8,
        acmod: UInt8 = 2,
        presentationTimeStamp: CMTime,
        admission: AudioBranchAdmissionIdentity? = nil
    ) throws -> Task16AC3Member {
        let bytes = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: fscod,
            frmsizecod: frmsizecod,
            bsid: 8,
            bsmod: 0,
            acmod: acmod,
            lfeon: false
        )
        let unit = makeUnit(bytes: bytes, presentationTimeStamp: presentationTimeStamp)
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        guard case let .admitted(admitted) = coordinator.admit(
            proof,
            ownership: AudioServiceInputUnitOwnership()
        ) else {
            throw coordinator.failure ?? AudioServiceSemanticFailure.staleProof
        }
        let selectedAdmission = admission ?? self.admission
        let existingAuthorization = coordinator.withAudioServiceCAS {
            coordinator.audioServiceLeaseState.branchGates.first {
                $0.admissionIdentity == selectedAdmission
            }?.compressedAuthorization
        }
        let authorization: CompressedAudioCandidatePlanAuthorization
        if let existingAuthorization {
            authorization = existingAuthorization
        } else {
            let timeline = try makeTimeline(origin: presentationTimeStamp)
            let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())
            authorization = try XCTUnwrap(coordinator.authorizeCompressedCandidate(plan))
        }
        guard try coordinator.registerEligibleCompressedPlan(authorization, for: admitted),
              let lease = try coordinator.issueAudioServiceBranchLease(
                  for: admitted,
                  admission: selectedAdmission
              ) else {
            throw AudioServiceSemanticFailure.staleProof
        }
        return Task16AC3Member(
            unit: unit,
            proof: admitted,
            lease: lease,
            authorization: authorization
        )
    }

    func makeTimelineWithoutOrigin() throws -> HLSTimelineCoordinator {
        let binding = try XCTUnwrap(coordinator.bindCompressedOutputPlan())
        let sampleRate = source.sampleRate
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                sampleRate: sampleRate,
                channels: 2,
                frameSamples: 1_536,
                nativeMask: 3
            ))
        }
        let timeline = HLSTimelineCoordinator(
            parserFactory: parserFactory,
            compressedAudioOutputPlanBinding: binding
        )
        _ = try timeline.consume(.tracks(timelineTracks))
        return timeline
    }

    func makeTimeline(origin: CMTime) throws -> HLSTimelineCoordinator {
        let timeline = try makeTimelineWithoutOrigin()
        let frame = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: fscod,
            frmsizecod: 20,
            bsmod: 0
        )
        let events = try timeline.consume(.packet(DemuxPacket(
            streamIndex: source.streamIndex,
            codec: .audio(.ac3),
            data: frame,
            presentationTimeStamp: origin,
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )))
        XCTAssertEqual(events.reduce(into: 0) { count, event in
            if case .originEstablished = event { count += 1 }
        }, 1, "真实完整 AC-3 AU 必须先建立 timeline origin")
        return timeline
    }

    func makeTimelineWithMiddleVideoOrigin() throws -> HLSTimelineCoordinator {
        let binding = try XCTUnwrap(coordinator.bindCompressedOutputPlan())
        let sampleRate = source.sampleRate
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            if handle.handleIndex == 0 {
                try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                    bytes: bytes,
                    pts: pts,
                    sampleRate: sampleRate,
                    channels: 2,
                    frameSamples: 1_536,
                    nativeMask: 3
                ))
            } else {
                try handle.emit(FFmpegParsedFrame(
                    bytes: bytes,
                    pts: pts,
                    dts: dts,
                    duration: CMTime(value: 1, timescale: 48_000),
                    fieldOrder: Int32(CodedFieldOrder.progressive.rawValue),
                    pictureStructure: Int32(PictureStructure.frame.rawValue),
                    keyFrame: true,
                    repeatPicture: false,
                    topFieldFirst: nil,
                    interlaced: false,
                    sampleRate: 0,
                    channels: 0,
                    frameSamples: 0,
                    channelLayout: nil
                ))
            }
        }
        let video = VideoTrackDescriptor(
            streamIndex: 2,
            codec: .hevc,
            timeBase: MediaRational(num: 1, den: 48_000)!,
            width: 16,
            height: 16,
            videoDelay: 0,
            extradata: Data(),
            frameRate: MediaRational(num: 24, den: 1),
            fieldOrder: .progressive
        )
        let timeline = HLSTimelineCoordinator(
            parserFactory: parserFactory,
            compressedAudioOutputPlanBinding: binding
        )
        _ = try timeline.consume(.tracks(DemuxTrackSet(
            selectedProgramID: 7,
            video: video,
            audio: source
        )))
        let frame = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: fscod,
            frmsizecod: 20,
            bsmod: 0
        )
        _ = try timeline.consume(.packet(DemuxPacket(
            streamIndex: source.streamIndex,
            codec: .audio(.ac3),
            data: frame,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )))
        for value in -7 ... -1 {
            _ = try timeline.consume(.packet(DemuxPacket(
                streamIndex: 2,
                codec: .video(.hevc),
                data: AssemblerTestFixtures.hevcAccessUnit(nal: Data([0x02, 0x01, 0x80])),
                presentationTimeStamp: CMTime(value: Int64(value), timescale: 48_000),
                decodeTimeStamp: .invalid,
                duration: CMTime(value: 1, timescale: 48_000),
                isKey: false,
                isCorrupt: false
            )))
        }
        let events = try timeline.consume(.packet(DemuxPacket(
            streamIndex: 2,
            codec: .video(.hevc),
            data: AssemblerTestFixtures.hevcAccessUnit(),
            presentationTimeStamp: CMTime(value: 1, timescale: 48_000),
            decodeTimeStamp: .invalid,
            duration: CMTime(value: 1, timescale: 48_000),
            isKey: true,
            isCorrupt: false
        )))
        XCTAssertEqual(events.reduce(into: 0) { count, event in
            if case .originEstablished = event { count += 1 }
        }, 1, "视频 IDR 必须在完整 AC-3 AU 中间建立真实 timeline origin")
        return timeline
    }

    func makeUnregisteredMember(
        fscod: UInt8,
        frmsizecod: UInt8,
        presentationTimeStamp: CMTime,
        ownership: AudioServiceInputUnitOwnership = AudioServiceInputUnitOwnership()
    ) throws -> Task16UnregisteredAC3Member {
        let bytes = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: fscod,
            frmsizecod: frmsizecod,
            bsid: 8,
            bsmod: 0,
            acmod: 2,
            lfeon: false
        )
        let unit = makeUnit(bytes: bytes, presentationTimeStamp: presentationTimeStamp)
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        guard case let .admitted(admitted) = coordinator.admit(
            proof,
            ownership: ownership
        ) else {
            throw coordinator.failure ?? AudioServiceSemanticFailure.staleProof
        }
        return Task16UnregisteredAC3Member(unit: unit, proof: admitted)
    }

    func build(
        member: Task16AC3Member,
        admission: AudioBranchAdmissionIdentity,
        bundleNonce: UInt64
    ) throws -> CompressedAudioAccessUnit {
        try AC3DirectAccessUnitBuilder(
            coordinator: coordinator,
            authorization: member.authorization
        ).makeAccessUnit(
            inputUnit: member.unit,
            admittedProof: member.proof,
            directLease: member.lease,
            bundleNonce: .init(rawValue: bundleNonce)
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
            AudioBranchAdmissionIdentity.directCompressed(
                $0,
                branchGeneration: seed + 10,
                admissionFenceRevision: seed + 11
            )
        }
        admissions.append(.directCompressed(
            expectedOwner,
            branchGeneration: seed + 12,
            admissionFenceRevision: seed + 11
        ))
        admissions.append(.directCompressed(
            expectedOwner,
            branchGeneration: seed + 10,
            admissionFenceRevision: seed + 12
        ))
        return admissions
    }

    private func makeUnit(bytes: Data, presentationTimeStamp: CMTime) -> AudioServiceInputUnit {
        defer { nextIdentity += 1 }
        return try! AudioServiceInputUnit(
            identity: .init(rawValue: nextIdentity),
            backing: AudioServiceInputBacking(identity: .init(rawValue: nextIdentity + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: presentationTimeStamp,
            parserSampleCount: 1_536,
            parserSampleRate: source.sampleRate,
            parserChannelLayout: .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
    }

    private static func owner(
        kind: Task16OwnerKind,
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
                itemGeneration: .init(rawValue: seed + 3 + itemDelta),
                mediaEpoch: .init(rawValue: seed + 4 + mediaDelta),
                publicationParticipantID: .init(rawValue: seed + 5 + participantDelta),
                renditionIdentity: .init(rawValue: seed + 6 + renditionDelta)
            )
        case .audioOnly:
            return .audioOnly(
                outputLifecycleEpoch: lifecycle,
                selectionTransactionIdentity: .init(rawValue: seed + 7 + selectionDelta),
                candidateTicket: .init(rawValue: seed + 8 + candidateDelta),
                itemGeneration: .init(rawValue: seed + 3 + itemDelta),
                mediaEpoch: .init(rawValue: seed + 4 + mediaDelta),
                publicationParticipantID: .init(rawValue: seed + 5 + participantDelta),
                renditionIdentity: .init(rawValue: seed + 6 + renditionDelta)
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

private final class Task16TimelineResetProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let timeline: HLSTimelineCoordinator
    private let tracks: DemuxTrackSet
    private let lock = NSLock()
    private var storedSucceeded = false

    init(timeline: HLSTimelineCoordinator, tracks: DemuxTrackSet) {
        self.timeline = timeline
        self.tracks = tracks
    }

    var succeeded: Bool { lock.withLock { storedSucceeded } }

    func run() {
        started.signal()
        let result = (try? timeline.consume(.discontinuity(tracks, reason: .timelineReset))) != nil
        lock.withLock { storedSucceeded = result }
        completed.signal()
    }
}
