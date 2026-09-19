// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Darwin
import Foundation
import XCTest
@testable import VPlayerPlayback

/// Task 14 既有测试只验证未授权 lease 状态机；测试目标建立不含 Task 16 授权的旧记录。
extension AudioServiceSemanticCoordinator {
    func registerEligibleCompressedPlan(
        _ admission: AudioBranchAdmissionIdentity,
        for proof: AdmittedAudioServiceInputUnitProof
    ) throws -> Bool {
        try withAudioServiceCAS {
            guard isCurrentAdmittedProof(proof) else { return false }
            switch (admission, proof.identity.proofIdentity.unitKind) {
            case (.directCompressed, .ac3Frame), (.eac3Aggregation, .eac3Syncframe):
                break
            default:
                return false
            }
            if let existing = proof.branchState.participations.first(where: {
                $0.admissionIdentity == admission
            }) {
                return existing.gate.isOpen && !existing.isSuppressed
                    && existing.compressedAuthorization == nil
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
                let opened = AudioServiceBranchGateRecord(admissionIdentity: admission)
                guard audioServiceLeaseState.branchGates.insert(opened) else {
                    throw AudioServiceSemanticFailure.registryCapacityExceeded
                }
                gate = opened
            }
            let participation = AudioServiceBranchParticipation(
                admissionIdentity: admission,
                gate: gate
            )
            return proof.branchState.participations.insert(participation)
        }
    }
}

final class AudioServiceLeaseTests: XCTestCase {
    func testDecoderDispositionIsGlobalOnceWhileEachCompressedBranchIssuesOnce() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let direct = harness.directAdmission()
        let secondDirect = harness.directAdmission(branchGeneration: 82, fence: 83)
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(secondDirect, for: harness.admitted))

        let decoder = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let firstCompressed = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: direct
        ))
        let secondCompressed = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: secondDirect
        ))

        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(for: harness.admitted, admission: direct))
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(for: harness.admitted, admission: secondDirect))
        XCTAssertNotEqual(decoder.identity.leaseNonce, firstCompressed.identity.leaseNonce)
        XCTAssertNotEqual(firstCompressed.identity.leaseNonce, secondCompressed.identity.leaseNonce)
        XCTAssertEqual(harness.coordinator.issuedBranchLeaseCount, 3)
    }

    func testDecoderDispositionTransfersAndReleasesWithLeaseInSameCAS() throws {
        let harness = try AudioServiceLeaseTestHarness()
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let owner = DecoderInputOwnerIdentity(rawValue: 101)

        XCTAssertEqual(harness.coordinator.transferDecoderLease(lease.identity, to: owner), .transferred)
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: harness.admitted), .transferred(owner))
        XCTAssertEqual(harness.coordinator.transferDecoderLease(lease.identity, to: owner), .alreadyDisposed)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(lease.identity, expectedOwner: .decoder(owner)),
            .released
        )
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: harness.admitted), .released)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(lease.identity, expectedOwner: .decoder(owner)),
            .alreadyDisposed
        )
    }

    func testDecoderCloseBeforeIssueSuppressesSidecarAndCannotReopen() throws {
        let harness = try AudioServiceLeaseTestHarness()
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))

        let firstFence = try XCTUnwrap(harness.coordinator.closeDecoderGate(harness.decoderAdmission))
        let repeatedFence = try XCTUnwrap(harness.coordinator.closeDecoderGate(harness.decoderAdmission))

        XCTAssertEqual(firstFence, repeatedFence)
        XCTAssertEqual(firstFence.lastIssuedLeaseSequence, 0)
        XCTAssertEqual(firstFence.expectedOutstandingCount, 0)
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: harness.admitted), .suppressed)
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        XCTAssertFalse(harness.coordinator.openDecoderGate(harness.decoderAdmission))
        XCTAssertTrue(harness.coordinator.isDrained(firstFence))
    }

    func testDecoderCloseAfterIssueReleasesAvailableLeaseAndSidecarTogether() throws {
        let harness = try AudioServiceLeaseTestHarness()
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))

        let fence = try XCTUnwrap(harness.coordinator.closeDecoderGate(harness.decoderAdmission))

        XCTAssertEqual(fence.lastIssuedLeaseSequence, 1)
        XCTAssertEqual(fence.expectedOutstandingCount, 1)
        XCTAssertEqual(harness.coordinator.branchLeaseState(lease.identity), .released)
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: harness.admitted), .released)
        XCTAssertTrue(harness.coordinator.isDrained(fence))
    }

    func testEAC3LeaseSupportsHeldTransferReleaseAndCloseReleasesHeld() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .eac3)
        let admission = harness.aggregationAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
        let first = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: admission
        ))
        let partial = PartialAudioAggregationIdentity(rawValue: 201)
        XCTAssertEqual(harness.coordinator.holdEAC3AggregationLease(first.identity, partial: partial), .held)

        let bundle = harness.eac3Bundle(admission: admission, bundleNonce: 202)
        XCTAssertEqual(harness.coordinator.transferEAC3AggregationLease(first.identity, to: bundle), .transferred)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(first.identity, expectedOwner: .eac3AccessUnit(bundle)),
            .released
        )

        let secondHarness = try AudioServiceLeaseTestHarness(codec: .eac3)
        let secondAdmission = secondHarness.aggregationAdmission()
        XCTAssertTrue(try secondHarness.coordinator.registerEligibleCompressedPlan(
            secondAdmission,
            for: secondHarness.admitted
        ))
        let held = try XCTUnwrap(try secondHarness.coordinator.issueAudioServiceBranchLease(
            for: secondHarness.admitted,
            admission: secondAdmission
        ))
        XCTAssertEqual(secondHarness.coordinator.holdEAC3AggregationLease(
            held.identity,
            partial: .init(rawValue: 203)
        ), .held)
        let fence = try XCTUnwrap(secondHarness.coordinator.closeCompressedGate(secondAdmission))

        XCTAssertEqual(secondHarness.coordinator.branchLeaseState(held.identity), .released)
        XCTAssertEqual(fence.expectedOutstandingCount, 1)
        XCTAssertEqual(fence.lastIssuedLeaseSequence, 1)
        XCTAssertTrue(secondHarness.coordinator.isDrained(fence))
    }

    func testOrdinaryCompressedLeaseRejectsHeldAndRequiresExactBundleAdmission() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let direct = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: direct
        ))

        XCTAssertEqual(
            harness.coordinator.holdEAC3AggregationLease(
                lease.identity,
                partial: PartialAudioAggregationIdentity(rawValue: 1)
            ),
            .invalidTransition
        )
        XCTAssertEqual(
            harness.coordinator.transferCompressedLease(
                lease.identity,
                to: harness.directBundle(admission: harness.directAdmission(branchGeneration: 8_000, fence: 81))
            ),
            .identityMismatch
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(lease.identity), .available)
        XCTAssertEqual(
            harness.coordinator.transferCompressedLease(
                lease.identity,
                to: harness.directBundle(admission: direct)
            ),
            .transferred
        )
    }

    func testCloseBeforeIssueProducesZeroLeaseAndSingleStableFence() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let direct = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))

        let firstFence = try XCTUnwrap(harness.coordinator.closeCompressedGate(direct))
        let secondFence = try XCTUnwrap(harness.coordinator.closeCompressedGate(direct))

        XCTAssertEqual(firstFence, secondFence)
        XCTAssertEqual(firstFence.lastIssuedLeaseSequence, 0)
        XCTAssertEqual(firstFence.expectedOutstandingCount, 0)
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(for: harness.admitted, admission: direct))
        XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))
    }

    func testClosingUnissuedCompressedPlanTerminatesOwnershipAcrossGateRetirementOrdersAndReusesSlots() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission(branchGeneration: 9_200, fence: 9_201)
        var proof = harness.admitted
        var previousRetiredProof: AdmittedAudioServiceInputUnitProof?

        for offset in 0...AudioServiceRegistryCapacity.admittedProofs {
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: proof))
            if let previousRetiredProof {
                XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(
                    admission,
                    for: previousRetiredProof
                ))
            }

            let fence = try XCTUnwrap(harness.coordinator.closeCompressedGate(admission))
            XCTAssertEqual(fence.lastIssuedLeaseSequence, 0)
            XCTAssertEqual(fence.expectedOutstandingCount, 0)

            if offset.isMultiple(of: 2) {
                XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: proof))
                XCTAssertTrue(harness.coordinator.retireAudioServiceGate(fence))
            } else {
                XCTAssertTrue(harness.coordinator.retireAudioServiceGate(fence))
                XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: proof))
            }

            XCTAssertEqual(proof.ownership.releaseCount, 1, "offset=\(offset)")
            XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(admission, for: proof))
            XCTAssertTrue(harness.coordinator.retireAdmittedProof(proof))
            XCTAssertEqual(proof.ownership.releaseCount, 1, "offset=\(offset)")
            XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
            XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.branchGates, 0)

            previousRetiredProof = proof
            if offset < AudioServiceRegistryCapacity.admittedProofs {
                proof = try harness.admitNextUnit(rawValue: UInt64(9_300 + offset))
            }
        }
    }

    func testIssueBeforeCloseRegistersLeaseBeforeFenceAndCloseReleasesAvailable() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let direct = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: direct
        ))

        let fence = try XCTUnwrap(harness.coordinator.closeCompressedGate(direct))

        XCTAssertEqual(fence.lastIssuedLeaseSequence, 1)
        XCTAssertEqual(fence.expectedOutstandingCount, 1)
        XCTAssertEqual(harness.coordinator.branchLeaseState(lease.identity), .released)
        XCTAssertTrue(harness.coordinator.isDrained(fence))
    }

    func testTransferredCompressedLeaseKeepsFenceUndrainedUntilWriterTerminal() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let direct = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(direct, for: harness.admitted))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: direct
        ))
        let bundle = harness.directBundle(admission: direct)
        XCTAssertEqual(harness.coordinator.transferCompressedLease(
            lease.identity,
            to: bundle
        ), .transferred)

        let fence = try XCTUnwrap(harness.coordinator.closeCompressedGate(direct))

        XCTAssertEqual(fence.expectedOutstandingCount, 1)
        XCTAssertFalse(harness.coordinator.isDrained(fence))
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                lease.identity,
                expectedOwner: .compressedAccessUnit(bundle)
            ),
            .released
        )
        XCTAssertTrue(harness.coordinator.isDrained(fence))
    }

    func testCompressedOwnerTwoCasesAndEveryAdmissionFieldAreAuthoritative() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let expected = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(expected, for: harness.admitted))

        for stale in harness.staleCompressedAdmissions(from: expected) {
            XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(for: harness.admitted, admission: stale))
        }
        XCTAssertNotEqual(harness.audioVideoOwner, harness.audioOnlyOwner)
        XCTAssertNotNil(try harness.coordinator.issueAudioServiceBranchLease(for: harness.admitted, admission: expected))
    }

    func testPCMBundleUsesExactlyThreePhysicalSlotsAndRejectsDuplicateAndOverflowBeforeVisible() throws {
        for count in 0...3 {
            let harness = try AudioServiceLeaseTestHarness()
            let consumers = (0..<count).map { harness.pcmAdmission(offset: UInt64($0)) }
            consumers.forEach { XCTAssertTrue(harness.coordinator.openPCMSubscription($0)) }

            let bundle = try harness.makePCMBundle(consumers: consumers, unit: UInt64(300 + count))
            XCTAssertEqual(bundle.consumerCount, count)
            XCTAssertEqual(bundle.consumerDispositionSlots.capacity, 3)
            XCTAssertEqual(bundle.consumerDispositionSlots.storageSlotCount, 3)
        }

        let harness = try AudioServiceLeaseTestHarness()
        let a = harness.pcmAdmission(offset: 0)
        XCTAssertThrowsError(try harness.makePCMBundle(consumers: [a, a], unit: 400)) {
            XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .duplicateConsumer)
        }
        XCTAssertThrowsError(try harness.makePCMBundle(
            consumers: [a, harness.pcmAdmission(offset: 1), harness.pcmAdmission(offset: 2), harness.pcmAdmission(offset: 3)],
            unit: 402
        )) {
            XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .consumerCapacityExceeded)
        }
        XCTAssertEqual(harness.coordinator.visiblePCMUnitCount, 0)
    }

    func testPCMEachUnitAndStableSubscriptionIssuesExactlyOneLease() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let first = try harness.makePCMBundle(consumers: [consumer], unit: 501)
        let second = try harness.makePCMBundle(consumers: [consumer], unit: 502)

        let firstLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: first,
            consumerAdmissionIdentity: consumer
        ))
        let secondLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: second,
            consumerAdmissionIdentity: consumer
        ))

        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(from: first, consumerAdmissionIdentity: consumer))
        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(from: second, consumerAdmissionIdentity: consumer))
        XCTAssertEqual(firstLease.identity.decodedPCMUnitIdentity, first.identity)
        XCTAssertEqual(secondLease.identity.decodedPCMUnitIdentity, second.identity)
        XCTAssertEqual(firstLease.identity.pcmConsumerAdmissionIdentity, consumer)
        XCTAssertNotEqual(firstLease.identity.leaseNonce, secondLease.identity.leaseNonce)
    }

    func testClosingConsumerSuppressesOnlyItsSlotWhileSiblingsContinue() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let a = harness.pcmAdmission(offset: 0)
        let b = harness.pcmAdmission(offset: 1)
        let c = harness.pcmAdmission(offset: 2)
        [a, b, c].forEach { XCTAssertTrue(harness.coordinator.openPCMSubscription($0)) }
        let bundle = try harness.makePCMBundle(consumers: [a, b, c])

        let fenceA = try XCTUnwrap(harness.coordinator.closePCMSubscription(a))

        XCTAssertEqual(harness.coordinator.pcmDisposition(in: bundle, consumer: a), .suppressed)
        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: a))
        XCTAssertNotNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: b))
        XCTAssertNotNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: c))
        XCTAssertEqual(fenceA.expectedOutstandingCount, 0)
        XCTAssertTrue(harness.coordinator.receiptCommitIsValid)
    }

    func testLatePCMOutputStartsClosedConsumerSuppressedAndOpenSiblingUnclaimed() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let closed = harness.pcmAdmission(offset: 0)
        let open = harness.pcmAdmission(offset: 1)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(closed))
        XCTAssertTrue(harness.coordinator.openPCMSubscription(open))
        _ = harness.coordinator.closePCMSubscription(closed)

        let bundle = try harness.makePCMBundle(consumers: [closed, open], unit: 601)

        XCTAssertEqual(harness.coordinator.pcmDisposition(in: bundle, consumer: closed), .suppressed)
        XCTAssertEqual(harness.coordinator.pcmDisposition(in: bundle, consumer: open), .unclaimed)
        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: closed))
        XCTAssertNotNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: open))
    }

    func testPCMTransferReleaseAndCloseFenceCountsAreAtomicAndIdempotent() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let first = try harness.makePCMBundle(consumers: [consumer], unit: 701)
        let second = try harness.makePCMBundle(consumers: [consumer], unit: 702)
        let firstLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(from: first, consumerAdmissionIdentity: consumer))
        let secondLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(from: second, consumerAdmissionIdentity: consumer))
        let owner = PCMInputOwnerIdentity(rawValue: 703)

        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(firstLease.identity, to: owner), .transferred)
        let fence = try XCTUnwrap(harness.coordinator.closePCMSubscription(consumer))

        XCTAssertEqual(fence.lastIssuedLeaseSequence, 3, "decoder lease先占用同一checked sequence命名空间")
        XCTAssertEqual(fence.expectedOutstandingCount, 2)
        XCTAssertEqual(harness.coordinator.pcmDisposition(in: second, consumer: consumer), .released)
        XCTAssertFalse(harness.coordinator.isDrained(fence))
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(firstLease.identity, expectedOwner: owner),
            .released
        )
        XCTAssertTrue(harness.coordinator.isDrained(fence))
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(firstLease.identity, expectedOwner: owner),
            .alreadyDisposed
        )
        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(secondLease.identity, to: owner), .alreadyDisposed)
    }

    func testPCMOwnerTwoCasesAndEveryAdmissionFieldCannotBeInterchanged() throws {
        let harness = try AudioServiceLeaseTestHarness()
        let expected = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(expected))
        let bundle = try harness.makePCMBundle(consumers: [expected])
        let staleAdmissions = harness.stalePCMAdmissions(from: expected)

        for stale in staleAdmissions {
            XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: stale))
        }
        XCTAssertNotEqual(harness.audioVideoPCMOwner, harness.audioOnlyPCMOwner)
        XCTAssertNotNil(try harness.coordinator.issuePCMConsumerLease(from: bundle, consumerAdmissionIdentity: expected))
    }

    func testCompressedPlanIsBoundToExactProofEvenWhenStaleGateIsOpen() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let currentAdmission = harness.directAdmission()
        let nextAdmission = harness.directAdmission(branchGeneration: 8_002, fence: 8_003)
        let nextProof = try harness.admitNextUnit(rawValue: 2)

        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
            currentAdmission,
            for: harness.admitted
        ))
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
            nextAdmission,
            for: nextProof
        ))

        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: nextAdmission
        ))
        XCTAssertNotNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: currentAdmission
        ))
        XCTAssertNotNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: nextProof,
            admission: nextAdmission
        ))
    }

    func testBothOwnerCasesCanRegisterDirectAndAggregationPlans() throws {
        let directHarness = try AudioServiceLeaseTestHarness(codec: .ac3)
        for (offset, owner) in [directHarness.audioVideoOwner, directHarness.audioOnlyOwner].enumerated() {
            let admission = AudioBranchAdmissionIdentity.directCompressed(
                owner,
                branchGeneration: UInt64(9_000 + offset),
                admissionFenceRevision: UInt64(9_100 + offset)
            )
            XCTAssertTrue(try directHarness.coordinator.registerEligibleCompressedPlan(
                admission,
                for: directHarness.admitted
            ))
            XCTAssertNotNil(try directHarness.coordinator.issueAudioServiceBranchLease(
                for: directHarness.admitted,
                admission: admission
            ))
        }

        let aggregationHarness = try AudioServiceLeaseTestHarness(codec: .eac3)
        for (offset, owner) in [aggregationHarness.audioVideoOwner, aggregationHarness.audioOnlyOwner].enumerated() {
            let admission = AudioBranchAdmissionIdentity.eac3Aggregation(
                owner,
                branchGeneration: UInt64(9_200 + offset),
                admissionFenceRevision: UInt64(9_300 + offset)
            )
            XCTAssertTrue(try aggregationHarness.coordinator.registerEligibleCompressedPlan(
                admission,
                for: aggregationHarness.admitted
            ))
            XCTAssertNotNil(try aggregationHarness.coordinator.issueAudioServiceBranchLease(
                for: aggregationHarness.admitted,
                admission: admission
            ))
        }
    }

    func testWrongTransferredOwnerCannotReleaseBranchOrPCMLease() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
        let branchLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: admission
        ))
        let bundle = harness.directBundle(admission: admission)
        XCTAssertEqual(harness.coordinator.transferCompressedLease(branchLease.identity, to: bundle), .transferred)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                branchLease.identity,
                expectedOwner: .compressedAccessUnit(harness.directBundle(admission: admission, bundleNonce: 9_999))
            ),
            .identityMismatch
        )
        XCTAssertEqual(harness.coordinator.branchLeaseState(branchLease.identity), .transferred(.compressedAccessUnit(bundle)))
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                branchLease.identity,
                expectedOwner: .compressedAccessUnit(bundle)
            ),
            .released
        )

        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let pcmBundle = try harness.makePCMBundle(consumers: [consumer], unit: 9_500)
        let pcmLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: pcmBundle,
            consumerAdmissionIdentity: consumer
        ))
        let inputOwner = PCMInputOwnerIdentity(rawValue: 9_501)
        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(pcmLease.identity, to: inputOwner), .transferred)
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(
                pcmLease.identity,
                expectedOwner: .init(rawValue: 9_502)
            ),
            .identityMismatch
        )
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(pcmLease.identity, expectedOwner: inputOwner),
            .released
        )
    }

    func testPCMBundleRequiresExactTransferredDecoderLineage() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        let decoderLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let owner = DecoderInputOwnerIdentity(rawValue: 9_600)

        XCTAssertThrowsError(try harness.coordinator.makeDecodedPCMUnitBundle(
            proof: harness.admitted,
            sharedDecoderAdmissionIdentity: harness.decoderAdmission,
            decoderLeaseIdentity: decoderLease.identity,
            decoderInputOwner: owner,
            backingIdentity: .init(rawValue: 9_602),
            consumers: [consumer]
        )) { XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .decoderLineageMismatch) }

        XCTAssertEqual(harness.coordinator.transferDecoderLease(decoderLease.identity, to: owner), .transferred)
        let staleDecoder = SharedDecoderAdmissionIdentity(
            sourceTrackIdentity: harness.decoderAdmission.sourceTrackIdentity,
            inputFormatGeneration: harness.decoderAdmission.inputFormatGeneration,
            outputLifecycleEpoch: harness.lifecycle,
            decoderLifecycleGeneration: harness.decoderAdmission.decoderLifecycleGeneration,
            decoderAdmissionFenceRevision: harness.decoderAdmission.decoderAdmissionFenceRevision + 1
        )
        XCTAssertThrowsError(try harness.coordinator.makeDecodedPCMUnitBundle(
            proof: harness.admitted,
            sharedDecoderAdmissionIdentity: staleDecoder,
            decoderLeaseIdentity: decoderLease.identity,
            decoderInputOwner: owner,
            backingIdentity: .init(rawValue: 9_604),
            consumers: [consumer]
        )) { XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .decoderLineageMismatch) }

        XCTAssertNoThrow(try harness.coordinator.makeDecodedPCMUnitBundle(
            proof: harness.admitted,
            sharedDecoderAdmissionIdentity: harness.decoderAdmission,
            decoderLeaseIdentity: decoderLease.identity,
            decoderInputOwner: owner,
            backingIdentity: .init(rawValue: 9_606),
            consumers: [consumer]
        ))
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                decoderLease.identity,
                expectedOwner: .decoder(owner)
            ),
            .released
        )
        XCTAssertNoThrow(try harness.coordinator.makeDecodedPCMUnitBundle(
            proof: harness.admitted,
            sharedDecoderAdmissionIdentity: harness.decoderAdmission,
            decoderLeaseIdentity: decoderLease.identity,
            decoderInputOwner: owner,
            backingIdentity: .init(rawValue: 9_608),
            consumers: [consumer]
        ))
    }

    func testFixedRegistriesFailBeforeSideEffectsAndReuseRetiredSlots() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        var proofs = [harness.admitted]
        for rawValue in 2...AudioServiceRegistryCapacity.admittedProofs {
            proofs.append(try harness.admitNextUnit(rawValue: UInt64(rawValue)))
        }
        XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, AudioServiceRegistryCapacity.admittedProofs)
        XCTAssertThrowsError(try harness.admitNextUnit(rawValue: 99_000)) {
            XCTAssertEqual($0 as? AudioServiceSemanticFailure, .registryCapacityExceeded)
        }

        XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: proofs[0]))
        XCTAssertTrue(harness.coordinator.retireAdmittedProof(proofs[0]))
        XCTAssertEqual(proofs[0].ownership.releaseCount, 1)
        XCTAssertNoThrow(try harness.admitNextUnit(rawValue: 99_001))
        XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, AudioServiceRegistryCapacity.admittedProofs)
    }

    func testAuthoritativeProofIndexKeepsActiveTailAt16AndRetainsTransferredMediaOwners()
        throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        var harness: AudioServiceLeaseTestHarness? = try AudioServiceLeaseTestHarness(
            codec: .ac3, applicationLedger: ledger)
        let admission = try XCTUnwrap(harness).directAdmission()
        var entries: [(AdmittedAudioServiceInputUnitProof,
                       AudioServiceBranchLeaseIdentity,
                       CompressedAccessUnitBundleIdentity)] = []
        for index in 0..<32 {
            let value = try XCTUnwrap(harness)
            let proof = index == 0 ? value.admitted
                : try value.admitNextUnit(rawValue: UInt64(100_000 + index))
            XCTAssertTrue(try value.coordinator.registerEligibleCompressedPlan(
                admission, for: proof))
            let lease = try XCTUnwrap(try value.coordinator.issueAudioServiceBranchLease(
                for: proof, admission: admission))
            let identity = proof.identity.proofIdentity
            let bundle = CompressedAccessUnitBundleIdentity(
                inputUnitIdentity: identity.inputUnitIdentity,
                audioBranchAdmissionIdentity: admission,
                backingIdentity: identity.backingIdentity,
                backingOwnerIdentity: identity.backingOwnerIdentity,
                byteRange: identity.byteRange,
                digest: identity.evidenceDigest,
                bundleNonce: .init(rawValue: UInt64(200_000 + index)))
            XCTAssertEqual(value.coordinator.transferCompressedLease(
                lease.identity, to: bundle), .transferred)
            XCTAssertTrue(value.coordinator.retireAdmittedProof(proof))
            entries.append((proof, lease.identity, bundle))
        }
        XCTAssertEqual(try XCTUnwrap(harness).coordinator.audioServiceRegistryUsage.admittedProofs, 32)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        var escapedProof: AdmittedAudioServiceInputUnitProof? = entries.first?.0
        XCTAssertNotNil(escapedProof)
        for entry in entries {
            XCTAssertEqual(try XCTUnwrap(harness).coordinator.releaseAudioServiceBranchLease(
                entry.1, expectedOwner: .compressedAccessUnit(entry.2)), .released)
            XCTAssertEqual(entry.0.ownership.releaseCount, 1)
        }
        entries.removeAll()
        XCTAssertEqual(try XCTUnwrap(harness).coordinator.audioServiceRegistryUsage.admittedProofs, 0)
        harness = nil
        XCTAssertGreaterThan(ledger.chargedBytes, 0,
                             "索引退休不能回收外部proof alias占用的graph信用")
        escapedProof = nil
        XCTAssertEqual(ledger.chargedBytes, 0,
                       "proof graph末alias及authoritative索引owner都销毁后必须全额退费")
    }

    func testAuthoritativeProofEscrowExhaustsAt3472UntilLastRetiredAliasDeinitializes()
        throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission()
        var escapedProofs: [AdmittedAudioServiceInputUnitProof] = []
        escapedProofs.reserveCapacity(AudioServiceRegistryCapacity.authoritativeAdmittedProofs)

        for index in 0..<AudioServiceRegistryCapacity.authoritativeAdmittedProofs {
            let proof = index == 0 ? harness.admitted
                : try harness.admitNextUnit(rawValue: UInt64(400_000 + index))
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
                admission, for: proof))
            let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
                for: proof, admission: admission))
            let identity = proof.identity.proofIdentity
            let bundle = CompressedAccessUnitBundleIdentity(
                inputUnitIdentity: identity.inputUnitIdentity,
                audioBranchAdmissionIdentity: admission,
                backingIdentity: identity.backingIdentity,
                backingOwnerIdentity: identity.backingOwnerIdentity,
                byteRange: identity.byteRange,
                digest: identity.evidenceDigest,
                bundleNonce: .init(rawValue: UInt64(500_000 + index)))
            XCTAssertEqual(harness.coordinator.transferCompressedLease(
                lease.identity, to: bundle), .transferred)
            XCTAssertTrue(harness.coordinator.retireAdmittedProof(proof))
            XCTAssertEqual(harness.coordinator.releaseAudioServiceBranchLease(
                lease.identity, expectedOwner: .compressedAccessUnit(bundle)), .released)
            escapedProofs.append(proof)
        }
        XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, 0,
                       "语义索引已空，但外部proof alias仍须持有费用信用")
        XCTAssertThrowsError(try harness.admitNextUnit(rawValue: 900_000)) {
            XCTAssertEqual($0 as? AudioServiceSemanticFailure, .registryCapacityExceeded)
        }

        escapedProofs.removeLast()
        let reused = try harness.admitNextUnit(rawValue: 900_001)
        XCTAssertTrue(harness.coordinator.retireAdmittedProof(reused))
    }

    func testAuthoritativeProofIndexDerivationAndApplicationByteBoundaryHaveNoPartialInstall()
        throws {
        XCTAssertEqual(
            AudioServiceRegistryCapacity.authoritativeAdmittedProofs,
            16 + (192 + 384) * 6)
        XCTAssertEqual(AudioServiceRegistryCapacity.audioAccessUnits,
                       CompressedAudioRetentionPolicy.pendingHardCount)
        XCTAssertEqual(AudioServiceRegistryCapacity.compressedWriterInputs,
                       SegmentedFMP4WriterOwnershipLimits.standard.hardCapacity)
        let charge = AudioServiceRegistryCapacity.authoritativeAdmittedProofIndexChargeBytes
        XCTAssertGreaterThan(charge, 0)
        let soft = HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes

        let exactLedger = HLSDeliveryApplicationChargeLedger(
            fixedBookkeepingChargeBytes: soft - 1)
        var exact: AudioServiceLeaseState? = AudioServiceLeaseState(
            applicationLedger: exactLedger)
        XCTAssertEqual(exactLedger.chargedBytes, soft - 1 + charge)
        XCTAssertTrue(try XCTUnwrap(exact).hasAdmittedProofSpace)
        exact = nil
        XCTAssertEqual(exactLedger.chargedBytes, soft - 1)

        let overflowLedger = HLSDeliveryApplicationChargeLedger(
            fixedBookkeepingChargeBytes: soft)
        let overflow = AudioServiceLeaseState(applicationLedger: overflowLedger)
        XCTAssertFalse(overflow.hasAdmittedProofSpace)
        XCTAssertEqual(overflow.admittedProofCount, 0)
        XCTAssertEqual(overflowLedger.chargedBytes, soft,
                       "越界拒绝不得留下局部索引reservation")
    }

    func testRetainedStructureChargeUsesCheckedMultiplicationAndAddition() {
        XCTAssertEqual(AudioServiceRetainedStructureCharge.checkedTotal(
            indexSlotCount: 1,
            indexSlotStride: 2,
            indexObjectBytes: 3,
            escrowObjectBytes: 4,
            lockObjectBytes: 5,
            reservationObjectBytes: 6,
            proofCount: 7,
            proofGraphBytes: 8
        ), malloc_good_size(2) + 74)
        XCTAssertNil(AudioServiceRetainedStructureCharge.checkedTotal(
            indexSlotCount: Int.max,
            indexSlotStride: 2,
            indexObjectBytes: 0,
            escrowObjectBytes: 0,
            lockObjectBytes: 0,
            reservationObjectBytes: 0,
            proofCount: 0,
            proofGraphBytes: 0
        ), "索引 backing 乘法溢出必须在分配/预费前失败")
        XCTAssertNil(AudioServiceRetainedStructureCharge.checkedTotal(
            indexSlotCount: 0,
            indexSlotStride: 0,
            indexObjectBytes: 0,
            escrowObjectBytes: 0,
            lockObjectBytes: 0,
            reservationObjectBytes: 0,
            proofCount: Int.max,
            proofGraphBytes: 2
        ), "proof 图乘法溢出必须在分配/预费前失败")
        XCTAssertNil(AudioServiceRetainedStructureCharge.checkedTotal(
            indexSlotCount: 1,
            indexSlotStride: 1,
            indexObjectBytes: Int.max,
            escrowObjectBytes: 0,
            lockObjectBytes: 0,
            reservationObjectBytes: 0,
            proofCount: 0,
            proofGraphBytes: 0
        ), "固定项加法溢出必须在分配/预费前失败")
    }

    func testProofGraphChargeRejectsInnerMultiplicationOverflowBeforeOuterReservation() {
        let overflowCases: [(String, Int, Int, Int, Int, Int)] = [
            ("per-plan加法", 0, 0, Int.max, 1, 1),
            ("plan乘法", 0, 0, Int.max / 2 + 1, 0, 2),
            ("proof-state加法", Int.max, 1, 0, 0, 0),
            ("最终总和", 1, 0, Int.max, 0, 1),
            ("负值", -1, 0, 0, 0, 0)
        ]
        for (name, proof, state, participation, lease, count) in overflowCases {
            XCTAssertNil(AdmittedAudioServiceInputUnitProof.checkedMaximumRetainedGraphChargeBytes(
                proofBytes: proof, branchStateBytes: state,
                branchParticipationBytes: participation,
                branchLeaseRecordBytes: lease, branchPlanCount: count
            ), "\(name)必须在传给外层 reservation 前受控拒绝")
        }
        XCTAssertEqual(AdmittedAudioServiceInputUnitProof.checkedMaximumRetainedGraphChargeBytes(
            proofBytes: 1, branchStateBytes: 2, branchParticipationBytes: 3,
            branchLeaseRecordBytes: 4, branchPlanCount: 5), 38)
    }

    func testDuplicateAdmitUnderGlobalBackpressureDoesNotReleaseActiveOwnership()
        throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let harness = try AudioServiceLeaseTestHarness(
            codec: .ac3, applicationLedger: ledger)
        let bytes = HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes
            - ledger.chargedBytes
        let pressure = try ledger.reserve(
            allocationIdentity: UUID(), bytes: bytes)
        XCTAssertTrue(ledger.shouldBackpressure)

        XCTAssertEqual(harness.coordinator.admit(
            harness.admitted.identity.proofIdentity,
            ownership: harness.admitted.ownership), .ignored)
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 0,
                       "重复admit不能在容量路径提前释放活跃media owner")
        ledger.release(pressure)
    }

    func testDecoderTransferUsesProjectedJointTailAtSixteen() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let compressed = harness.directAdmission()
        var entries: [(proof: AdmittedAudioServiceInputUnitProof,
                       compressedLease: AudioServiceBranchLeaseIdentity,
                       bundle: CompressedAccessUnitBundleIdentity,
                       decoderLease: AudioServiceBranchLeaseIdentity)] = []
        for index in 0..<17 {
            let proof = index == 0 ? harness.admitted
                : try harness.admitNextUnit(rawValue: UInt64(300_000 + index))
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
                compressed, for: proof))
            let compressedLease = try XCTUnwrap(
                try harness.coordinator.issueAudioServiceBranchLease(
                    for: proof, admission: compressed))
            let identity = proof.identity.proofIdentity
            let bundle = CompressedAccessUnitBundleIdentity(
                inputUnitIdentity: identity.inputUnitIdentity,
                audioBranchAdmissionIdentity: compressed,
                backingIdentity: identity.backingIdentity,
                backingOwnerIdentity: identity.backingOwnerIdentity,
                byteRange: identity.byteRange,
                digest: identity.evidenceDigest,
                bundleNonce: .init(rawValue: UInt64(310_000 + index)))
            XCTAssertEqual(harness.coordinator.transferCompressedLease(
                compressedLease.identity, to: bundle), .transferred)
            XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
                harness.decoderAdmission, for: proof))
            let decoderLease = try XCTUnwrap(
                try harness.coordinator.issueAudioServiceBranchLease(
                    for: proof, admission: .decoder(harness.decoderAdmission)))
            entries.append((proof, compressedLease.identity, bundle,
                            decoderLease.identity))
        }
        for index in 0..<15 {
            XCTAssertEqual(harness.coordinator.transferDecoderLease(
                entries[index].decoderLease,
                to: .init(rawValue: UInt64(320_000 + index))), .transferred)
        }
        XCTAssertEqual(harness.coordinator.releaseAudioServiceBranchLease(
            entries[15].compressedLease,
            expectedOwner: .compressedAccessUnit(entries[15].bundle)), .released)
        XCTAssertEqual(harness.coordinator.transferDecoderLease(
            entries[15].decoderLease, to: .init(rawValue: 320_015)), .transferred,
            "目标proof已在联合集合中时，count==16的原地transfer必须允许")
        XCTAssertEqual(harness.coordinator.transferDecoderLease(
            entries[16].decoderLease, to: .init(rawValue: 320_016)), .invalidTransition,
            "第17个decoder owner必须在同CAS拒绝且不得改写lease")
        XCTAssertEqual(harness.coordinator.branchLeaseState(entries[16].decoderLease),
                       .available)
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: entries[16].proof),
                       .leased(entries[16].decoderLease.leaseNonce))
    }

    func testGateAndPCMBundleFixedSlotsRejectCapPlusOneAndReuseAfterRetirement() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        var decoderAdmissions: [SharedDecoderAdmissionIdentity] = []
        for offset in 0..<AudioServiceRegistryCapacity.branchGates {
            let admission = SharedDecoderAdmissionIdentity(
                sourceTrackIdentity: harness.decoderAdmission.sourceTrackIdentity,
                inputFormatGeneration: harness.decoderAdmission.inputFormatGeneration,
                outputLifecycleEpoch: harness.lifecycle,
                decoderLifecycleGeneration: UInt64(50_000 + offset),
                decoderAdmissionFenceRevision: UInt64(51_000 + offset)
            )
            XCTAssertTrue(harness.coordinator.openDecoderGate(admission))
            decoderAdmissions.append(admission)
        }
        let overflowDecoder = SharedDecoderAdmissionIdentity(
            sourceTrackIdentity: harness.decoderAdmission.sourceTrackIdentity,
            inputFormatGeneration: harness.decoderAdmission.inputFormatGeneration,
            outputLifecycleEpoch: harness.lifecycle,
            decoderLifecycleGeneration: 59_000,
            decoderAdmissionFenceRevision: 59_001
        )
        XCTAssertFalse(harness.coordinator.openDecoderGate(overflowDecoder))
        let retiredDecoderFence = try XCTUnwrap(harness.coordinator.closeDecoderGate(decoderAdmissions[0]))
        XCTAssertTrue(harness.coordinator.retireAudioServiceGate(retiredDecoderFence))
        XCTAssertTrue(harness.coordinator.openDecoderGate(overflowDecoder))

        let pcmHarness = try AudioServiceLeaseTestHarness(codec: .ac3)
        var subscriptions: [PCMConsumerAdmissionIdentity] = []
        for offset in 0..<AudioServiceRegistryCapacity.pcmSubscriptionGates {
            let admission = pcmHarness.pcmAdmission(offset: UInt64(offset))
            XCTAssertTrue(pcmHarness.coordinator.openPCMSubscription(admission))
            subscriptions.append(admission)
        }
        let overflowAdmission = pcmHarness.pcmAdmission(offset: 99_000)
        XCTAssertFalse(pcmHarness.coordinator.openPCMSubscription(overflowAdmission))
        let retiredFence = try XCTUnwrap(pcmHarness.coordinator.closePCMSubscription(subscriptions[0]))
        XCTAssertTrue(pcmHarness.coordinator.retirePCMSubscription(retiredFence))
        XCTAssertTrue(pcmHarness.coordinator.openPCMSubscription(overflowAdmission))

        var bundles: [DecodedPCMUnitBundle] = []
        for offset in 0..<AudioServiceRegistryCapacity.pcmBundles {
            bundles.append(try pcmHarness.makePCMBundle(consumers: [], unit: UInt64(20_000 + offset)))
        }
        XCTAssertThrowsError(try pcmHarness.makePCMBundle(consumers: [], unit: 29_999)) {
            XCTAssertEqual($0 as? PCMConsumerSubscriptionFailure, .registryCapacityExceeded)
        }
        XCTAssertTrue(pcmHarness.coordinator.retireDecodedPCMUnitBundle(bundles[0]))
        XCTAssertNoThrow(try pcmHarness.makePCMBundle(consumers: [], unit: 30_000))
        XCTAssertEqual(pcmHarness.coordinator.audioServiceRegistryUsage.pcmBundles, AudioServiceRegistryCapacity.pcmBundles)
    }

    func testLongRunningUnitsReuseAdmittedSlotsWithoutGrowingRegistry() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        var proof = harness.admitted
        for rawValue in 2...65 {
            XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: proof))
            XCTAssertTrue(harness.coordinator.retireAdmittedProof(proof))
            XCTAssertEqual(proof.ownership.releaseCount, 1)
            proof = try harness.admitNextUnit(rawValue: UInt64(rawValue))
            XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, 1)
        }

        let pcmHarness = try AudioServiceLeaseTestHarness(codec: .ac3)
        for rawValue in 80_000..<80_064 {
            let bundle = try pcmHarness.makePCMBundle(consumers: [], unit: UInt64(rawValue))
            XCTAssertTrue(pcmHarness.coordinator.retireDecodedPCMUnitBundle(bundle))
            XCTAssertEqual(pcmHarness.coordinator.audioServiceRegistryUsage.pcmBundles, 0)
        }
    }

    func testDecoderGateClosedBeforeLateAdmissionSuppressesItsSidecar() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        XCTAssertTrue(harness.coordinator.openDecoderGate(harness.decoderAdmission))
        _ = try XCTUnwrap(harness.coordinator.closeDecoderGate(harness.decoderAdmission))

        let lateProof = try harness.admitNextUnit(rawValue: 70_000)

        XCTAssertFalse(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: lateProof
        ))
        XCTAssertEqual(harness.coordinator.decoderDisposition(of: lateProof), .suppressed)
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: lateProof,
            admission: .decoder(harness.decoderAdmission)
        ))
    }

    func testConcurrentPCMClaimAndTransferReleaseProduceOneLeaseAndOneTerminal() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let bundle = try harness.makePCMBundle(consumers: [consumer], unit: 31_000)
        let leaseBox = AudioServiceLockedValues<PCMConsumerSubscriptionLease>()

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if let lease = try? harness.coordinator.issuePCMConsumerLease(
                from: bundle,
                consumerAdmissionIdentity: consumer
            ) {
                leaseBox.append(lease)
            }
        }
        let lease = try XCTUnwrap(leaseBox.values.first)
        XCTAssertEqual(leaseBox.values.count, 1)

        let owner = PCMInputOwnerIdentity(rawValue: 31_001)
        let results = AudioServiceLockedValues<AudioServiceLeaseMutationResult>()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = index == 0
                ? harness.coordinator.transferPCMConsumerLease(lease.identity, to: owner)
                : harness.coordinator.releasePCMConsumerLease(lease.identity, expectedOwner: nil)
            results.append(result)
        }
        if harness.coordinator.pcmDisposition(in: bundle, consumer: consumer) != .released {
            XCTAssertEqual(
                harness.coordinator.releasePCMConsumerLease(lease.identity, expectedOwner: owner),
                .released
            )
        }
        XCTAssertEqual(harness.coordinator.pcmDisposition(in: bundle, consumer: consumer), .released)
        XCTAssertEqual(results.values.filter { $0 == .transferred || $0 == .released }.count, 1)
    }

    func testConcurrentIssueCloseDuplicateAndTransferReleaseHaveOneTerminal() throws {
        for iteration in 0..<12 {
            let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
            let admission = harness.directAdmission(
                branchGeneration: UInt64(10_000 + iteration),
                fence: UInt64(11_000 + iteration)
            )
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
            let leasesBox = AudioServiceLockedValues<AudioServiceBranchLease>()
            let fenceBox = AudioServiceLockedValue<AudioServiceBranchDrainFence?>(nil)
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                if index == 0 {
                    fenceBox.set(harness.coordinator.closeCompressedGate(admission))
                } else if let lease = try? harness.coordinator.issueAudioServiceBranchLease(
                    for: harness.admitted,
                    admission: admission
                ) {
                    leasesBox.append(lease)
                }
            }
            let leases = leasesBox.values
            XCTAssertLessThanOrEqual(leases.count, 1)
            let closed = try XCTUnwrap(fenceBox.value)
            XCTAssertEqual(closed.lastIssuedLeaseSequence, UInt64(leases.count))
            XCTAssertTrue(harness.coordinator.isDrained(closed))
        }

        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        let lease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let owner = DecoderInputOwnerIdentity(rawValue: 12_000)
        let resultsBox = AudioServiceLockedValues<AudioServiceLeaseMutationResult>()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = index == 0
                ? harness.coordinator.transferDecoderLease(lease.identity, to: owner)
                : harness.coordinator.releaseAudioServiceBranchLease(lease.identity, expectedOwner: nil)
            resultsBox.append(result)
        }
        if harness.coordinator.branchLeaseState(lease.identity) != .released {
            XCTAssertEqual(
                harness.coordinator.releaseAudioServiceBranchLease(
                    lease.identity,
                    expectedOwner: .decoder(owner)
                ),
                .released
            )
        }
        XCTAssertEqual(harness.coordinator.branchLeaseState(lease.identity), .released)
        XCTAssertEqual(resultsBox.values.filter { $0 == .transferred || $0 == .released }.count, 1)
    }

    func testBranchTerminalAndGenerationRetirementReleaseInputOwnershipExactlyOnce() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission()
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
        let decoderLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let compressedLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: admission
        ))
        let decoderOwner = DecoderInputOwnerIdentity(rawValue: 13_000)
        let compressedOwner = harness.directBundle(admission: admission)
        XCTAssertEqual(harness.coordinator.transferDecoderLease(decoderLease.identity, to: decoderOwner), .transferred)
        XCTAssertEqual(harness.coordinator.transferCompressedLease(compressedLease.identity, to: compressedOwner), .transferred)
        XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: harness.admitted))

        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                decoderLease.identity,
                expectedOwner: .decoder(decoderOwner)
            ),
            .released
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 0)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                compressedLease.identity,
                expectedOwner: .compressedAccessUnit(compressedOwner)
            ),
            .released
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)
        XCTAssertTrue(harness.coordinator.retireAdmittedProof(harness.admitted))
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)

        let cleanupHarness = try AudioServiceLeaseTestHarness(codec: .ac3)
        XCTAssertTrue(cleanupHarness.coordinator.openDecoderGate(cleanupHarness.decoderAdmission))
        XCTAssertTrue(cleanupHarness.coordinator.retireAdmittedProof(cleanupHarness.admitted))
        XCTAssertEqual(cleanupHarness.admitted.ownership.releaseCount, 1)
        let cleanupFence = try XCTUnwrap(
            cleanupHarness.coordinator.closeDecoderGate(cleanupHarness.decoderAdmission)
        )
        XCTAssertEqual(cleanupHarness.admitted.ownership.releaseCount, 1)
        XCTAssertTrue(cleanupHarness.coordinator.retireAudioServiceGate(cleanupFence))
        XCTAssertEqual(cleanupHarness.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
    }

    func testPCMTerminalChainAndDecoderTerminalReleaseInputOwnershipExactlyOnce() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let consumer = harness.pcmAdmission(offset: 0)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let bundle = try harness.makePCMBundle(consumers: [consumer], unit: 90_000)
        let lease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: bundle,
            consumerAdmissionIdentity: consumer
        ))
        let pcmOwner = PCMInputOwnerIdentity(rawValue: 90_001)
        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(lease.identity, to: pcmOwner), .transferred)
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(lease.identity, expectedOwner: pcmOwner),
            .released
        )
        let pcmFence = try XCTUnwrap(harness.coordinator.closePCMSubscription(consumer))
        XCTAssertTrue(harness.coordinator.retirePCMSubscription(pcmFence))
        XCTAssertTrue(harness.coordinator.retireDecodedPCMUnitBundle(bundle))

        let decoderLease = try harness.prepareDecoderLineage()
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                decoderLease,
                expectedOwner: .decoder(harness.decoderInputOwner)
            ),
            .released
        )
        XCTAssertTrue(harness.coordinator.sealAudioServiceBranches(for: harness.admitted))
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)
        XCTAssertTrue(harness.coordinator.retireAdmittedProof(harness.admitted))
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)
    }

    func testRetiredProofWithTransferredOwnersProtectsOwnershipFromLateAdmissionCallback() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            harness.decoderAdmission,
            for: harness.admitted
        ))
        let decoderLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(harness.decoderAdmission)
        ))
        let decoderOwner = DecoderInputOwnerIdentity(rawValue: 91_000)
        XCTAssertEqual(harness.coordinator.transferDecoderLease(decoderLease.identity, to: decoderOwner), .transferred)
        let compressedAdmission = harness.directAdmission(branchGeneration: 91_001, fence: 91_002)
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(
            compressedAdmission,
            for: harness.admitted
        ))
        let compressedLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: compressedAdmission
        ))
        let compressedOwner = harness.directBundle(admission: compressedAdmission, bundleNonce: 91_003)
        XCTAssertEqual(harness.coordinator.transferCompressedLease(compressedLease.identity, to: compressedOwner), .transferred)

        XCTAssertTrue(harness.coordinator.retireAdmittedProof(harness.admitted))
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 0)
        _ = try harness.admitNextUnit(rawValue: 91_004)
        XCTAssertEqual(
            harness.coordinator.admit(
                harness.admitted.identity.proofIdentity,
                ownership: harness.admitted.ownership
            ),
            .ignored
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 0)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                decoderLease.identity,
                expectedOwner: .decoder(decoderOwner)
            ),
            .released
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 0)
        XCTAssertEqual(
            harness.coordinator.releaseAudioServiceBranchLease(
                compressedLease.identity,
                expectedOwner: .compressedAccessUnit(compressedOwner)
            ),
            .released
        )
        XCTAssertEqual(harness.admitted.ownership.releaseCount, 1)
    }

    func testRetiringUnissuedPlanTerminatesParticipationAndReusesAdmittedCapacity() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission(branchGeneration: 92_000, fence: 92_001)
        var proof = harness.admitted

        for offset in 0...AudioServiceRegistryCapacity.admittedProofs {
            XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: proof))
            XCTAssertTrue(harness.coordinator.retireAdmittedProof(proof))
            XCTAssertEqual(proof.ownership.releaseCount, 1, "offset=\(offset)")
            XCTAssertEqual(harness.coordinator.audioServiceRegistryUsage.admittedProofs, 0, "offset=\(offset)")
            if offset < AudioServiceRegistryCapacity.admittedProofs {
                proof = try harness.admitNextUnit(rawValue: UInt64(92_100 + offset))
            }
        }
    }

    func testRetiredGateAndPCMBundleCannotReissueOldIdentityWhileNewIdentityReusesSlots() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let admission = harness.directAdmission(branchGeneration: 93_000, fence: 93_001)
        XCTAssertTrue(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
        let branchLease = try XCTUnwrap(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: admission
        ))
        let branchFence = try XCTUnwrap(harness.coordinator.closeCompressedGate(admission))
        XCTAssertEqual(harness.coordinator.branchLeaseState(branchLease.identity), .released)
        XCTAssertTrue(harness.coordinator.retireAudioServiceGate(branchFence))
        XCTAssertFalse(try harness.coordinator.registerEligibleCompressedPlan(admission, for: harness.admitted))
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: admission
        ))

        let consumer = harness.pcmAdmission(offset: 930)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let oldBundle = try harness.makePCMBundle(consumers: [consumer], unit: 93_100)
        let oldLease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: oldBundle,
            consumerAdmissionIdentity: consumer
        ))
        XCTAssertEqual(harness.coordinator.releasePCMConsumerLease(oldLease.identity), .released)
        XCTAssertTrue(harness.coordinator.retireDecodedPCMUnitBundle(oldBundle))
        XCTAssertNil(try harness.coordinator.issuePCMConsumerLease(
            from: oldBundle,
            consumerAdmissionIdentity: consumer
        ))
        XCTAssertTrue(oldBundle.identity.isRetired)
        let newBundle = try harness.makePCMBundle(consumers: [consumer], unit: 93_100)
        XCTAssertFalse(oldBundle.identity === newBundle.identity)
        XCTAssertNotEqual(oldBundle.identity.rawValue, newBundle.identity.rawValue)
        XCTAssertNotNil(try harness.coordinator.issuePCMConsumerLease(
            from: newBundle,
            consumerAdmissionIdentity: consumer
        ))
    }

    func testPCMTransferredLeaseRejectsForgedNonceFromSameUnitSubscriptionAndOwner() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let consumer = harness.pcmAdmission(offset: 940)
        XCTAssertTrue(harness.coordinator.openPCMSubscription(consumer))
        let bundle = try harness.makePCMBundle(consumers: [consumer], unit: 94_000)
        let lease = try XCTUnwrap(try harness.coordinator.issuePCMConsumerLease(
            from: bundle,
            consumerAdmissionIdentity: consumer
        ))
        let owner = PCMInputOwnerIdentity(rawValue: 94_001)
        XCTAssertEqual(harness.coordinator.transferPCMConsumerLease(lease.identity, to: owner), .transferred)
        let forged = PCMConsumerSubscriptionLeaseIdentity(
            decodedPCMUnitIdentity: lease.identity.decodedPCMUnitIdentity,
            pcmConsumerAdmissionIdentity: lease.identity.pcmConsumerAdmissionIdentity,
            leaseNonce: .init(rawValue: lease.identity.leaseNonce.rawValue + 1)
        )

        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(forged, expectedOwner: owner),
            .identityMismatch
        )
        XCTAssertEqual(
            harness.coordinator.releasePCMConsumerLease(lease.identity, expectedOwner: owner),
            .released
        )
    }

    func testClosingOldExactDecoderGateCannotSuppressDifferentCurrentAdmission() throws {
        let harness = try AudioServiceLeaseTestHarness(codec: .ac3)
        let oldAdmission = harness.decoderAdmission
        let newAdmission = SharedDecoderAdmissionIdentity(
            sourceTrackIdentity: oldAdmission.sourceTrackIdentity,
            inputFormatGeneration: oldAdmission.inputFormatGeneration,
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 95_000),
            decoderLifecycleGeneration: oldAdmission.decoderLifecycleGeneration + 1,
            decoderAdmissionFenceRevision: oldAdmission.decoderAdmissionFenceRevision + 1
        )
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            oldAdmission,
            for: harness.admitted
        ))
        let nextProof = try harness.admitNextUnit(rawValue: 95_001)
        XCTAssertTrue(try harness.coordinator.registerEligibleDecoderPlan(
            newAdmission,
            for: nextProof
        ))

        _ = try XCTUnwrap(harness.coordinator.closeDecoderGate(oldAdmission))

        XCTAssertEqual(harness.coordinator.decoderDisposition(of: nextProof), .unclaimed)
        XCTAssertNotNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: nextProof,
            admission: .decoder(newAdmission)
        ))
        XCTAssertNil(try harness.coordinator.issueAudioServiceBranchLease(
            for: harness.admitted,
            admission: .decoder(newAdmission)
        ))
    }
}

final class AudioServiceLeaseTestHarness: @unchecked Sendable {
    let coordinator: AudioServiceSemanticCoordinator
    let admitted: AdmittedAudioServiceInputUnitProof
    let decoderAdmission: SharedDecoderAdmissionIdentity
    let lifecycle: OutputLifecycleEpoch
    let codec: AudioCodec
    private var decoderLeaseIdentity: AudioServiceBranchLeaseIdentity?
    let decoderInputOwner = DecoderInputOwnerIdentity(rawValue: 49)

    static func makeLifecycle(outputNonce: UInt64) -> OutputLifecycleEpoch {
        let session = PlaybackSessionIdentity(
            sessionID: outputNonce,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        return OutputLifecycleEpoch(
            backendIdentity: PlaybackBackendIdentity(
                sessionIdentity: session,
                backendGeneration: outputNonce + 1
            ),
            outputNonce: outputNonce
        )
    }

    init(codec: AudioCodec = .ac3,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        self.codec = codec
        let session = PlaybackSessionIdentity(
            sessionID: 1,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: 2)
        lifecycle = OutputLifecycleEpoch(backendIdentity: backend, outputNonce: 3)
        let source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: codec,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: codec == .aac ? Data([0x11, 0x90]) : Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default])
        )
        let bytes: Data
        switch codec {
        case .aac: bytes = Data([0x21, 0x22])
        case .ac3: bytes = AssemblerTestFixtures.syntheticAC3Frame(bsmod: 0)
        case .eac3: bytes = syntheticEAC3Frame()
        case .mp1, .mp2, .mp3: throw AudioServiceSemanticFailure.invalidInputUnit
        }
        let unit = try AudioServiceInputUnit(
            identity: .init(rawValue: 1),
            backing: AudioServiceInputBacking(identity: .init(rawValue: 2), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: .zero,
            parserSampleCount: codec == .ac3 || codec == .eac3 ? 1_536 : nil,
            parserSampleRate: codec == .aac ? nil : 48_000,
            parserChannelLayout: codec == .aac ? nil : .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
        coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: 4),
            inputFormatGeneration: .init(rawValue: 5),
            allocator: PlaybackIdentityAllocator(),
            applicationLedger: applicationLedger
        )
        _ = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: unit)
        let validationNonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: validationNonce)
        let admission = coordinator.admit(
            proof,
            ownership: AudioServiceInputUnitOwnership()
        )
        switch admission {
        case let .admitted(current): admitted = current
        case let .failed(failure): throw failure
        case .ignored: throw AudioServiceSemanticFailure.staleProof
        }
        decoderAdmission = SharedDecoderAdmissionIdentity(
            sourceTrackIdentity: admitted.identity.proofIdentity.parentReceiptIdentity.sourceTrackIdentity,
            inputFormatGeneration: admitted.identity.proofIdentity.inputFormatGeneration,
            outputLifecycleEpoch: lifecycle,
            decoderLifecycleGeneration: 50,
            decoderAdmissionFenceRevision: 51
        )
    }

    var audioVideoOwner: CompressedAudioBranchOwnerIdentity {
        .audioVideo(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: .init(rawValue: 60),
            mediaEpoch: .init(rawValue: 61),
            publicationParticipantID: .init(rawValue: 62),
            renditionIdentity: .init(rawValue: 63)
        )
    }

    var audioOnlyOwner: CompressedAudioBranchOwnerIdentity {
        .audioOnly(
            outputLifecycleEpoch: lifecycle,
            selectionTransactionIdentity: .init(rawValue: 64),
            candidateTicket: .init(rawValue: 65),
            itemGeneration: .init(rawValue: 60),
            mediaEpoch: .init(rawValue: 61),
            publicationParticipantID: .init(rawValue: 62),
            renditionIdentity: .init(rawValue: 63)
        )
    }

    var audioVideoPCMOwner: PCMConsumerOwnerIdentity {
        .audioVideo(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: .init(rawValue: 70),
            mediaEpoch: .init(rawValue: 71),
            publicationParticipantID: .init(rawValue: 72),
            renditionIdentity: .init(rawValue: 73)
        )
    }

    var audioOnlyPCMOwner: PCMConsumerOwnerIdentity {
        .audioOnly(
            outputLifecycleEpoch: lifecycle,
            selectionTransactionIdentity: .init(rawValue: 74),
            candidateTicket: .init(rawValue: 75),
            itemGeneration: .init(rawValue: 70),
            mediaEpoch: .init(rawValue: 71),
            publicationParticipantID: .init(rawValue: 72),
            renditionIdentity: .init(rawValue: 73)
        )
    }

    func directAdmission(
        branchGeneration: UInt64 = 80,
        fence: UInt64 = 81
    ) -> AudioBranchAdmissionIdentity {
        .directCompressed(audioVideoOwner, branchGeneration: branchGeneration, admissionFenceRevision: fence)
    }

    func aggregationAdmission() -> AudioBranchAdmissionIdentity {
        .eac3Aggregation(audioVideoOwner, branchGeneration: 84, admissionFenceRevision: 85)
    }

    func pcmAdmission(offset: UInt64) -> PCMConsumerAdmissionIdentity {
        PCMConsumerAdmissionIdentity(
            owner: .audioVideo(
                outputLifecycleEpoch: lifecycle,
                itemGeneration: .init(rawValue: 90 + offset),
                mediaEpoch: .init(rawValue: 100 + offset),
                publicationParticipantID: .init(rawValue: 110 + offset),
                renditionIdentity: .init(rawValue: 120 + offset)
            ),
            subscriptionGeneration: 130 + offset,
            admissionFenceRevision: 140 + offset
        )
    }

    func makePCMBundle(
        consumers: [PCMConsumerAdmissionIdentity],
        unit: UInt64 = 300
    ) throws -> DecodedPCMUnitBundle {
        let decoderLeaseIdentity = try prepareDecoderLineage()
        return try coordinator.makeDecodedPCMUnitBundle(
            proof: admitted,
            sharedDecoderAdmissionIdentity: decoderAdmission,
            decoderLeaseIdentity: decoderLeaseIdentity,
            decoderInputOwner: decoderInputOwner,
            backingIdentity: .init(rawValue: unit + 1_000),
            consumers: consumers
        )
    }

    func prepareDecoderLineage() throws -> AudioServiceBranchLeaseIdentity {
        if let decoderLeaseIdentity { return decoderLeaseIdentity }
        XCTAssertTrue(try coordinator.registerEligibleDecoderPlan(
            decoderAdmission,
            for: admitted
        ))
        let lease = try XCTUnwrap(try coordinator.issueAudioServiceBranchLease(
            for: admitted,
            admission: .decoder(decoderAdmission)
        ))
        XCTAssertEqual(coordinator.transferDecoderLease(lease.identity, to: decoderInputOwner), .transferred)
        decoderLeaseIdentity = lease.identity
        return lease.identity
    }

    func admitNextUnit(rawValue: UInt64) throws -> AdmittedAudioServiceInputUnitProof {
        let bytes: Data
        switch codec {
        case .aac: bytes = Data([0x21, 0x22])
        case .ac3: bytes = AssemblerTestFixtures.syntheticAC3Frame(bsmod: 0)
        case .eac3: bytes = syntheticEAC3Frame()
        case .mp1, .mp2, .mp3: throw AudioServiceSemanticFailure.invalidInputUnit
        }
        let unit = try AudioServiceInputUnit(
            identity: .init(rawValue: rawValue),
            backing: AudioServiceInputBacking(identity: .init(rawValue: rawValue + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: .zero,
            parserSampleCount: codec == .ac3 || codec == .eac3 ? 1_536 : nil,
            parserSampleRate: codec == .aac ? nil : 48_000,
            parserChannelLayout: codec == .aac ? nil : .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        switch coordinator.admit(proof, ownership: AudioServiceInputUnitOwnership()) {
        case let .admitted(admitted): return admitted
        case let .failed(failure): throw failure
        case .ignored: throw AudioServiceSemanticFailure.staleProof
        }
    }

    func makeNextUnsupportedProof(
        rawValue: UInt64
    ) throws -> (proof: AudioServiceSemanticInputUnitProof, ownership: AudioServiceInputUnitOwnership) {
        guard codec == .ac3 else { throw AudioServiceSemanticFailure.invalidInputUnit }
        let bytes = AssemblerTestFixtures.syntheticAC3Frame(bsmod: 1)
        let unit = try AudioServiceInputUnit(
            identity: .init(rawValue: rawValue),
            backing: AudioServiceInputBacking(identity: .init(rawValue: rawValue + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: .zero,
            parserSampleCount: 1_536,
            parserSampleRate: 48_000,
            parserChannelLayout: .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
        let nonce = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: nonce)
        XCTAssertEqual(proof.observedSemantic, .unknown)
        return (proof, AudioServiceInputUnitOwnership())
    }

    func directBundle(
        admission: AudioBranchAdmissionIdentity,
        bundleNonce: UInt64 = 500
    ) -> CompressedAccessUnitBundleIdentity {
        let proof = admitted.identity.proofIdentity
        return CompressedAccessUnitBundleIdentity(
            inputUnitIdentity: proof.inputUnitIdentity,
            audioBranchAdmissionIdentity: admission,
            backingIdentity: proof.backingIdentity,
            backingOwnerIdentity: proof.backingOwnerIdentity,
            byteRange: proof.byteRange,
            digest: proof.evidenceDigest,
            bundleNonce: .init(rawValue: bundleNonce)
        )
    }

    func eac3Bundle(
        admission: AudioBranchAdmissionIdentity,
        bundleNonce: UInt64
    ) -> EAC3AccessUnitBundleIdentity {
        let proof = admitted.identity.proofIdentity
        return EAC3AccessUnitBundleIdentity(
            accessUnitIdentity: .init(rawValue: 800),
            audioBranchAdmissionIdentity: admission,
            outputBackingIdentity: .init(rawValue: 801),
            outputBackingOwnerIdentity: EAC3OutputBackingOwnerIdentity(),
            outputByteRange: proof.byteRange,
            outputDigest: proof.evidenceDigest,
            bundleNonce: .init(rawValue: bundleNonce)
        )
    }

    func staleCompressedAdmissions(
        from expected: AudioBranchAdmissionIdentity
    ) -> [AudioBranchAdmissionIdentity] {
        guard case let .directCompressed(owner, generation, fence) = expected else { return [] }
        return [
            .directCompressed(audioOnlyOwner, branchGeneration: generation, admissionFenceRevision: fence),
            .directCompressed(owner, branchGeneration: generation + 1, admissionFenceRevision: fence),
            .directCompressed(owner, branchGeneration: generation, admissionFenceRevision: fence + 1),
            .eac3Aggregation(owner, branchGeneration: generation, admissionFenceRevision: fence),
        ]
    }

    func stalePCMAdmissions(
        from expected: PCMConsumerAdmissionIdentity
    ) -> [PCMConsumerAdmissionIdentity] {
        [
            PCMConsumerAdmissionIdentity(
                owner: audioOnlyPCMOwner,
                subscriptionGeneration: expected.subscriptionGeneration,
                admissionFenceRevision: expected.admissionFenceRevision
            ),
            PCMConsumerAdmissionIdentity(
                owner: expected.owner,
                subscriptionGeneration: expected.subscriptionGeneration + 1,
                admissionFenceRevision: expected.admissionFenceRevision
            ),
            PCMConsumerAdmissionIdentity(
                owner: expected.owner,
                subscriptionGeneration: expected.subscriptionGeneration,
                admissionFenceRevision: expected.admissionFenceRevision + 1
            ),
        ]
    }
}

private final class AudioServiceLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class AudioServiceLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}
