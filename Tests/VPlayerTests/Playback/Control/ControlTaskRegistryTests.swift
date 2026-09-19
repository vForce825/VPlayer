// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation
import XCTest
@testable import VPlayerPlayback

final class ControlTaskRegistryTests: XCTestCase {
    func testFrozenReactivationRejectsOnlyDeletedDuplicatesBeforeInstallingRecord() throws {
        let fixture = try AudioPhaseFixture(ownsResources: false)
        let phase = fixture.phase.identity
        let invocationAllocator = PlaybackIdentityAllocator()
        let invocation = try AudioSessionActivationInvocationIdentity(allocator: invocationAllocator)
        let foreignInvocation = try AudioSessionActivationInvocationIdentity(allocator: PlaybackIdentityAllocator())
        let laterInvocation = try AudioSessionActivationInvocationIdentity(allocator: invocationAllocator)
        let session = phase.sessionIdentity
        let wrongSessions = [PlaybackSessionIdentity(sessionID: session.sessionID + 1, requestID: session.requestID),
                             PlaybackSessionIdentity(sessionID: session.sessionID, requestID: UUID())]
        let proof = AudioSessionReactivationProof.interruption(.init(sessionIdentity: session,
            configuredGeneration: 801, interruptionEpoch: 802, contextNonce: phase.contextNonce,
            retiredOutputLifecycleEpoch: nil, resultingResourceShape: .noResources, proofNonce: 803))
        func policy(purposeSession: PlaybackSessionIdentity, budgetSession: PlaybackSessionIdentity,
                    context: UInt64, epoch: UInt64, attemptInvocation: AudioSessionActivationInvocationIdentity,
                    proof: AudioSessionReactivationProof) -> AudioSessionPhasePolicy {
            .activate(purpose: .reactivateConfiguredGeneration(sessionIdentity: purposeSession,
                configurationTransitionIdentity: nil, committedGeneration: 801,
                reactivationAttempt: .init(reactivationBudgetIdentity: .init(sessionIdentity: budgetSession,
                    recoveryLineageIdentity: 804, budgetNonce: 805), reactivationProof: proof,
                    interruptionEpoch: epoch, retainedContextNonce: context, attemptNonce: attemptInvocation)),
                interruptionEpoch: 806, audioAdmissionFenceRevision: 807, invocationIdentity: invocation)
        }
        let valid = policy(purposeSession: session, budgetSession: session, context: phase.contextNonce,
            epoch: 806, attemptInvocation: invocation, proof: proof)
        var invalid: [AudioSessionPhasePolicy] = []
        for wrong in wrongSessions {
            invalid.append(policy(purposeSession: wrong, budgetSession: wrong, context: phase.contextNonce,
                epoch: 806, attemptInvocation: invocation, proof: proof))
            invalid.append(policy(purposeSession: session, budgetSession: wrong, context: phase.contextNonce,
                epoch: 806, attemptInvocation: invocation, proof: proof))
        }
        invalid.append(policy(purposeSession: session, budgetSession: session, context: phase.contextNonce + 1,
            epoch: 806, attemptInvocation: invocation, proof: proof))
        invalid.append(policy(purposeSession: session, budgetSession: session, context: phase.contextNonce,
            epoch: 802, attemptInvocation: invocation, proof: proof))
        for wrong in [foreignInvocation, laterInvocation] {
            invalid.append(policy(purposeSession: session, budgetSession: session, context: phase.contextNonce,
                epoch: 806, attemptInvocation: wrong, proof: proof))
        }
        let before = fixture.registry.occupancy
        for (index, value) in invalid.enumerated() {
            XCTAssertThrowsError(try OwnedPostIngressControlCommand(
                controlTaskTicket: .init(group: fixture.group, nonce: 808), slot: .audioSessionRecovery,
                safetySnapshot: .cleanupOwnership, gatePolicy: .audioSession,
                audioPhaseIdentity: phase, audioPolicy: value), "私有冻结变异 \(index)")
            XCTAssertThrowsError(try fixture.registry.enqueueAudioSession(group: fixture.group,
                identity: phase, policy: value), "冗余字段变异 \(index) 必须在安装槽前拒绝") { error in
                XCTAssertEqual(error as? ControlTaskRegistry.Failure, .invalidGroup,
                    "不能让前一个错误占槽产生的 slotOccupied 冒充自洽性拒绝")
            }
            XCTAssertEqual(fixture.registry.occupancy.safetySlots, before.safetySlots)
        }
        let task = ControlTaskTicket(group: fixture.group, nonce: 808)
        var command = try OwnedPostIngressControlCommand(controlTaskTicket: task, slot: .audioSessionRecovery,
            safetySnapshot: .cleanupOwnership, gatePolicy: .audioSession, audioPhaseIdentity: phase, audioPolicy: valid)
        XCTAssertEqual(command.audioPolicy, valid, "原旧 drain epoch 802 不得被 attempt 的 806 覆盖")
        let call = AudioSessionCallIdentity(record: task, phaseIdentity: phase)
        command.activationOutcome = .returnedSuccess(call)
        XCTAssertEqual(command.audioPolicy, valid)
        XCTAssertEqual(command.activationOutcome, .returnedSuccess(call))
        let root = MediaServicesResetRootIdentity(resetTicket: 809, mediaServicesEpoch: 810)
        let resetProof = AudioSessionReactivationProof.resetPostConfiguration(.init(
            incarnationIdentity: .init(root: root, incarnationNonce: 811, sessionIdentity: session),
            resetDrainProofIdentity: .init(root: root, proofNonce: 812), retainedContextNonce: phase.contextNonce,
            leaseID: phase.leaseID, committedGeneration: 801, postConfigurationStageIdentity: 813, proofNonce: 814))
        let resetPolicy = policy(purposeSession: session, budgetSession: session, context: phase.contextNonce,
            epoch: 806, attemptInvocation: invocation, proof: resetProof)
        let resetCommand = try OwnedPostIngressControlCommand(controlTaskTicket: task, slot: .audioSessionRecovery,
            safetySnapshot: .cleanupOwnership, gatePolicy: .audioSession, audioPhaseIdentity: phase, audioPolicy: resetPolicy)
        XCTAssertEqual(resetCommand.audioPolicy, resetPolicy, "私有冻结不替代后续 transition/currentness 授权")
    }

    func testFrozenResourceRejectsMalformedDuplicatesWithoutReplacingOriginalOwnership() throws {
        final class Resource: OwnedPlaybackResource {}
        let object = Resource()
        let session = PlaybackSessionIdentity(sessionID: 820, requestID: UUID())
        let other = PlaybackSessionIdentity(sessionID: 821, requestID: session.requestID)
        let resource = ControlResourceIdentity.context(session: session, nonce: 822)
        let group = ControlTaskGroupTicket(resourceIdentity: resource,
            ownerTicket: .init(resourceIdentity: resource, nonce: 823), nonce: 824)
        let task = ControlTaskTicket(group: group, nonce: 825)
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: 826)
        let independentBackend = PlaybackBackendIdentity(sessionIdentity: other, backendGeneration: 827)
        let lifecycle = OutputLifecycleEpoch(backendIdentity: .init(sessionIdentity: other,
            backendGeneration: 848), outputNonce: 828)
        let monitor = OwnedRouteMonitorResource(sessionIdentity: session, lifecycle: 829, object: object)
        func ownership(_ payload: OutputOwnedResourcePayload) -> OutputResourceOwnership {
            .init(reservation: .init(ownerGroup: group, workGroup: group, nonce: 830), contextNonce: 831,
                mediaServicesEpoch: 832, interruptionEpoch: 833, audioAdmissionFenceRevision: 834, payload: payload)
        }
        let original = ownership(.monitor(monitor))
        var command = try OwnedPostIngressControlCommand(controlTaskTicket: task, slot: .leaseRelease,
            safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
        try command.installOwnedResult(original)
        func assertRejected(_ payload: OutputOwnedResourcePayload, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try command.installOwnedResult(ownership(payload)), file: file, line: line)
            guard case .monitor(let restored) = command.ownedResult?.payload else {
                return XCTFail("失败安装覆盖了原 monitor 所有权", file: file, line: line)
            }
            XCTAssertTrue(restored.object === object, file: file, line: line)
        }
        for wrongMonitor in [nil, OwnedRouteMonitorResource(sessionIdentity: other, lifecycle: 829, object: object),
            OwnedRouteMonitorResource(sessionIdentity: .init(sessionID: session.sessionID, requestID: UUID()), lifecycle: 829, object: object)] {
            let lease = OwnedAudioSessionLeaseResources(leaseID: 835, object: object, monitor: wrongMonitor,
                deactivation: .invalidatedByMediaServicesReset(mediaServicesEpoch: 832))
            assertRejected(.backend(.init(identity: backend, object: object, lifecycle: nil, lease: lease)))
        }
        let lease = OwnedAudioSessionLeaseResources(leaseID: 835, object: object, monitor: monitor,
            deactivation: .invalidatedByMediaServicesReset(mediaServicesEpoch: 832))
        assertRejected(.backend(.init(identity: backend, object: object, lifecycle: lifecycle, lease: lease)))
        assertRejected(.backend(.init(identity: backend, object: object,
            lifecycle: .init(backendIdentity: .init(sessionIdentity: session, backendGeneration: 849),
                outputNonce: 828), lease: lease)))
        let oldResource = ControlResourceIdentity.context(session: other, nonce: 836)
        let oldGroup = ControlTaskGroupTicket(resourceIdentity: oldResource,
            ownerTicket: .init(resourceIdentity: oldResource, nonce: 837), nonce: 838)
        for badGroup in [ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: oldGroup.ownerTicket, nonce: 838),
                         ControlTaskGroupTicket(resourceIdentity: oldResource, ownerTicket: group.ownerTicket, nonce: 838)] {
            let proof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: .init(group: badGroup, nonce: 839),
                sessionIdentity: other, leaseID: 840, contextNonce: 841, ownershipNonce: 842)
            assertRejected(.lease(.init(leaseID: 835, object: object, monitor: monitor,
                deactivation: .confirmedInactive(.reservation(proof)))))
        }
        let oldProof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: .init(group: oldGroup, nonce: 839),
            sessionIdentity: other, leaseID: 840, contextNonce: 841, ownershipNonce: 842)
        var legal: [AudioSessionDeactivationDisposition] = [.confirmedInactive(.reservation(oldProof))]
        for retired in [nil, lifecycle] {
            for shape in [InterruptionDrainedResourceShape.retainedSuccessor(.init(sessionIdentity: session,
                    leaseID: 835, monitorLifecycle: 829, contextNonce: 843)),
                .quiescentBackend(independentBackend, .init(sessionIdentity: session,
                    leaseID: 835, monitorLifecycle: 829, contextNonce: 843))] {
                let proof = InterruptionDrainProof(sessionIdentity: session, configuredGeneration: 844,
                    interruptionEpoch: 845, contextNonce: 843, retiredOutputLifecycleEpoch: retired,
                    resultingResourceShape: shape, proofNonce: 846)
                legal.append(.confirmedInactive(.interruption(proof)))
                for (wrongSession, wrongContext) in [(other, UInt64(843)),
                    (.init(sessionID: session.sessionID, requestID: UUID()), UInt64(843)), (session, UInt64(847))] {
                    let retained = RetainedAudioSessionResourceShape(sessionIdentity: wrongSession,
                        leaseID: 835, monitorLifecycle: 829, contextNonce: wrongContext)
                    let wrongShape: InterruptionDrainedResourceShape
                    if case .quiescentBackend = shape { wrongShape = .quiescentBackend(independentBackend, retained) }
                    else { wrongShape = .retainedSuccessor(retained) }
                    let wrong = InterruptionDrainProof(sessionIdentity: session, configuredGeneration: 844,
                        interruptionEpoch: 845, contextNonce: 843, retiredOutputLifecycleEpoch: retired,
                        resultingResourceShape: wrongShape, proofNonce: 846)
                    assertRejected(.lease(.init(leaseID: 835, object: object, monitor: monitor,
                        deactivation: .confirmedInactive(.interruption(wrong)))))
                }
            }
        }
        for disposition in legal {
            try command.installOwnedResult(ownership(.lease(.init(leaseID: 835, object: object,
                monitor: monitor, deactivation: disposition))))
            XCTAssertEqual(command.ownedResult?.payload.lease?.deactivation, disposition,
                "独立旧 acquisition 票、旧 proof epoch、独立 backend/lifecycle 不得借当前票改写")
        }
    }

    func testFrozenAudioPayloadRejectsForeignOwnerAndReplaysExactPhase() throws {
        let session = PlaybackSessionIdentity(sessionID: 600, requestID: UUID())
        let resource = ControlResourceIdentity.context(session: session, nonce: 601)
        let owner = ControlTaskOwnerTicket(resourceIdentity: resource, nonce: 602)
        let group = ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: owner, nonce: 603)
        let task = ControlTaskTicket(group: group, nonce: 604)
        let phase = AudioSessionPhaseIdentity(owner: owner, sessionIdentity: session,
            leaseID: 605, contextNonce: 606, mediaServicesEpoch: 607, phaseNonce: 608)
        let policy = AudioSessionPhasePolicy.configureAcquisition(acquisitionTicket: task,
            ownershipNonce: 609, configurationAttemptNonce: 610, step: .multichannelCapability)
        var command = try OwnedPostIngressControlCommand(controlTaskTicket: task,
            slot: .audioSessionRecovery, safetySnapshot: .cleanupOwnership,
            gatePolicy: .audioSession, audioPhaseIdentity: phase, audioPolicy: policy)
        XCTAssertEqual(command.audioPhaseIdentity, phase)
        XCTAssertEqual(command.audioPolicy, policy)
        let exactCall = AudioSessionCallIdentity(record: task, phaseIdentity: phase)
        command.activationOutcome = .returnedSuccess(exactCall)
        XCTAssertEqual(command.activationOutcome, .returnedSuccess(exactCall))
        let foreign = AudioSessionPhaseIdentity(owner: .init(resourceIdentity: resource, nonce: 999),
            sessionIdentity: session, leaseID: 605, contextNonce: 606,
            mediaServicesEpoch: 607, phaseNonce: 608)
        XCTAssertThrowsError(try OwnedPostIngressControlCommand(controlTaskTicket: task,
            slot: .audioSessionRecovery, safetySnapshot: .cleanupOwnership,
            gatePolicy: .audioSession, audioPhaseIdentity: foreign, audioPolicy: policy))
        command.activationOutcome = .returnedSuccess(.init(record: task, phaseIdentity: foreign))
        XCTAssertEqual(command.activationOutcome, .returnedSuccess(exactCall),
                       "错票结果不得归一化，也不得覆盖原终态")
    }

    func testFrozenResourceAndDeactivationPreserveEveryDispositionAndRejectWrongTickets() throws {
        final class Resource: OwnedPlaybackResource {}
        let object = Resource()
        let monitorObject = Resource()
        let session = PlaybackSessionIdentity(sessionID: 700, requestID: UUID())
        let ownerResource = ControlResourceIdentity.context(session: session, nonce: 701)
        let workResource = ControlResourceIdentity.context(session: session, nonce: 702)
        let owner = ControlTaskGroupTicket(resourceIdentity: ownerResource,
            ownerTicket: .init(resourceIdentity: ownerResource, nonce: 703), nonce: 704)
        let work = ControlTaskGroupTicket(resourceIdentity: workResource,
            ownerTicket: .init(resourceIdentity: workResource, nonce: 705), nonce: 706)
        let reservation = CleanupReservationTicket(ownerGroup: owner, workGroup: work, nonce: 707)
        let task = ControlTaskTicket(group: work, nonce: 708)
        let oldPhase = AudioSessionPhaseIdentity(owner: work.ownerTicket, sessionIdentity: session,
            leaseID: 702, contextNonce: 709, mediaServicesEpoch: 710, phaseNonce: 711)
        let oldCall = AudioSessionCallIdentity(record: task, phaseIdentity: oldPhase)
        let failure = AudioSessionFixedFailure(domain: .osStatus, code: -712)
        let proof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: task,
            sessionIdentity: session, leaseID: 702, contextNonce: 709, ownershipNonce: 713)
        let interruption = InterruptionDrainProof(sessionIdentity: session, configuredGeneration: 714,
            interruptionEpoch: 715, contextNonce: 709, retiredOutputLifecycleEpoch: nil,
            resultingResourceShape: .noResources, proofNonce: 716)
        let receipt = ActiveSessionReceipt(leaseID: 702, configurationGeneration: 717,
            interruptionEpoch: 715, activationNonce: 718)
        let dispositions: [AudioSessionDeactivationDisposition] = [
            .confirmedInactive(.reservation(proof)),
            .confirmedInactive(.activationNotInvoked(.init(callIdentity: oldCall))),
            .confirmedInactive(.activationReturnedFailure(oldCall, failure)),
            .confirmedInactive(.interruption(interruption)), .awaitingActivationOutcome(oldCall),
            .requiresDeactivate(.activeReceipt(receipt, oldPhase)),
            .requiresDeactivate(.returnedSuccess(oldCall)), .deactivationInFlight(oldCall),
            .invalidatedByMediaServicesReset(mediaServicesEpoch: 719),
            .deactivationSettled(oldCall, .succeeded), .deactivationSettled(oldCall, .failed(failure))
        ]
        let monitor = OwnedRouteMonitorResource(sessionIdentity: session, lifecycle: 720, object: monitorObject)
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: 721)
        let lifecycle = OutputLifecycleEpoch(backendIdentity: backend, outputNonce: 722)
        for disposition in dispositions {
            let lease = OwnedAudioSessionLeaseResources(leaseID: 702, object: object,
                monitor: monitor, deactivation: disposition)
            for payload in [OutputOwnedResourcePayload.lease(lease),
                            .backend(.init(identity: backend, object: object, lifecycle: lifecycle, lease: lease)),
                            .backend(.init(identity: backend, object: object, lifecycle: nil, lease: lease)),
                            .monitor(monitor)] {
                let ownership = OutputResourceOwnership(reservation: reservation, contextNonce: 709,
                    mediaServicesEpoch: 710, interruptionEpoch: 715, audioAdmissionFenceRevision: 723,
                    payload: payload)
                var command = try OwnedPostIngressControlCommand(controlTaskTicket: task,
                    slot: .leaseRelease, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
                try command.installOwnedResult(ownership)
                let restored = try XCTUnwrap(command.ownedResult)
                XCTAssertEqual(restored.reservation, reservation)
                XCTAssertEqual(restored.contextNonce, 709)
                XCTAssertEqual(restored.mediaServicesEpoch, 710)
                XCTAssertEqual(restored.interruptionEpoch, 715)
                XCTAssertEqual(restored.audioAdmissionFenceRevision, 723)
                XCTAssertEqual(restored.payload.lease?.deactivation, payload.lease?.deactivation)
                XCTAssertEqual(restored.payload.lease?.leaseID, payload.lease?.leaseID)
                XCTAssertEqual(restored.payload.monitorSessionIdentity, session)
                if let restoredLease = restored.payload.lease {
                    XCTAssertTrue(restoredLease.object === object)
                    XCTAssertTrue(restoredLease.monitor?.object === monitorObject)
                    XCTAssertEqual(restoredLease.monitor?.lifecycle, 720)
                }
                if case .backend(let original) = payload {
                    guard case .backend(let result) = restored.payload else { return XCTFail("backend shape 丢失") }
                    XCTAssertEqual(result.identity, original.identity)
                    XCTAssertEqual(result.lifecycle, original.lifecycle)
                    XCTAssertTrue(result.object === original.object)
                }
                var wrong = ownership
                wrong.reservation = .init(ownerGroup: owner, workGroup: owner, nonce: 707)
                XCTAssertThrowsError(try command.installOwnedResult(wrong))
                XCTAssertEqual(command.ownedResult?.reservation, reservation)
                let inconsistent = ControlTaskGroupTicket(resourceIdentity: workResource,
                    ownerTicket: owner.ownerTicket, nonce: owner.nonce)
                wrong.reservation = .init(ownerGroup: inconsistent, workGroup: work, nonce: 707)
                XCTAssertThrowsError(try command.installOwnedResult(wrong))
                XCTAssertEqual(command.ownedResult?.reservation, reservation)
            }
        }
        let deactivationTask = ControlTaskTicket(group: owner, nonce: 724)
        let deactivationPhase = AudioSessionPhaseIdentity(owner: owner.ownerTicket, sessionIdentity: session,
            leaseID: 702, contextNonce: 709, mediaServicesEpoch: 710, phaseNonce: 725)
        for source in [AudioSessionActiveAuthority.activeReceipt(receipt, oldPhase), .returnedSuccess(oldCall)] {
            let request = try XCTUnwrap(AudioSessionCleanupDeactivationRequest(reservation: reservation,
                contextNonce: 709, leaseID: 702, source: source,
                call: .init(record: deactivationTask, phaseIdentity: deactivationPhase)))
            var command = try OwnedPostIngressControlCommand(controlTaskTicket: deactivationTask,
                slot: .audioSessionRecovery, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
            try command.installDeactivation(request)
            XCTAssertEqual(command.deactivationRequest, request)
            command.completeDeactivation(.failed(failure))
            XCTAssertEqual(command.deactivationRequest, request)
            XCTAssertEqual(command.deactivationOutcome, .failed(failure))
            let wrong = try XCTUnwrap(AudioSessionCleanupDeactivationRequest(reservation: reservation,
                contextNonce: 709, leaseID: 702, source: source,
                call: .init(record: .init(group: owner, nonce: 999), phaseIdentity: deactivationPhase)))
            XCTAssertThrowsError(try command.installDeactivation(wrong))
            XCTAssertEqual(command.deactivationRequest, request)
            XCTAssertEqual(command.deactivationOutcome, .failed(failure))
        }
    }

    func testConsistentForgedResetProofCannotAuthorizeWithOrWithoutOwnedResources() throws {
        for ownsResources in [false, true] {
            let fixture = try AudioPhaseFixture(ownsResources: ownsResources)
            let phase = try fixture.unregisteredResetPhase()
            XCTAssertTrue(phase.hasConsistentResetReferences)
            XCTAssertNil(fixture.registry.registeredAudioSessionPhase(), "自洽外来phase没有生产发行入口")
            let task = try fixture.registry.enqueueAudioSession(group: fixture.group, identity: phase.identity, policy: phase.policy)
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(task, lane: fixture.lane)), .rejected, "root、incarnation和policy自洽仍不能代替真实旧资源drain")
        }
    }

    func testAudioSessionRecoveryUsesSafetyReserveWhenOrdinaryPoolIsFull() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        while fixture.registry.occupancy.ordinarySlots < 16 {
            let group = try fixture.registry.createGroup(resource: .context(session: phase.identity.sessionIdentity,
                nonce: UInt64(fixture.registry.occupancy.ordinarySlots + 100)))
            _ = try fixture.registry.enqueue(group: group, slot: .accounting, policy: .routeNeutral)
        }
        let command = fixture.ticket
        XCTAssertEqual(fixture.registry.occupancy.ordinarySlots, 16)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, 1)
        guard case .claimed(let request) = fixture.registry.executor.performAudioSessionCall(.claim(command, lane: fixture.lane))
        else { return XCTFail("真实queued票必须取得唯一lane请求") }
        XCTAssertEqual(request.permit.operation, .longFormCategory)
        let returned = AudioSessionBlockingCallReturned(permit: request.permit, result: .configuration(.categorySucceeded))
        guard case .completed(let completion, _, _, _) = fixture.registry.executor.performAudioSessionCall(.complete(returned, lane: fixture.lane))
        else { return XCTFail("准确SDK返回必须同CAS结清并交付后继") }
        let next = try XCTUnwrap(completion.followUp)
        XCTAssertNotEqual(next, command)
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
        XCTAssertNil(fixture.registry.phase(of: command), "原record在真实结果处理后退休，不能再领取旧结果")
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(returned, lane: fixture.lane)), .rejected)
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.configurationProgress,
            .awaitingMultichannel(actualPolicy: .longFormAudio, preferredFailure: nil))
    }

    func testFullSafetyPoolRejectsAudioSessionBeforeInvocationWithoutDuplicateRecord() throws {
        let fixture = try AudioPhaseFixture(ownsResources: false)
        for _ in 0..<16 {
            let group = try fixture.registry.createGroup(resource: .context(session: fixture.phase.identity.sessionIdentity,
                nonce: try fixture.allocator.next(in: .nonce)))
            _ = try fixture.registry.enqueue(group: group, slot: .suspend, policy: .safetyBypass)
        }
        let calls = ExternalControlCallSpy()
        for _ in 0..<2 {
            do {
                let command = try fixture.registry.enqueueAudioSession(group: fixture.group,
                    identity: fixture.phase.identity, policy: fixture.phase.policy)
                if case .claimed = fixture.registry.executor.performAudioSessionCall(.claim(command, lane: fixture.lane)) {
                    calls.invoke(onControlExecutor: fixture.registry.executor.isIsolated)
                }
                XCTFail("安全池满时不得登记或执行AudioSession调用")
            } catch ControlTaskRegistry.Failure.capacity {
                // 拒绝发生在登记及SDK副作用之前。
            }
        }
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots + fixture.registry.occupancy.reservedSafetySlots, 16)
        XCTAssertNil(fixture.registry.registeredAudioSessionPhase(), "纯容量拒绝不能安装外来phase或启动SDK")
    }

    func testActivationRejectsForeignIssuerAndNewInvocationAttachedToOldAttempt() throws {
        for foreignIssuer in [false, true] {
            let fixture = try ActualAudioActivationFixture(kind: foreignIssuer ? 0 : 2)
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            guard case .activate(let purpose, let epoch, let fence, _) = phase.policy else { return XCTFail("缺少激活事务") }
            let invalid = try AudioSessionActivationInvocationIdentity(allocator: foreignIssuer ? PlaybackIdentityAllocator() : fixture.allocator)
            phase.policy = .activate(purpose: purpose, interruptionEpoch: epoch,
                audioAdmissionFenceRevision: fence, invocationIdentity: invalid)
            XCTAssertTrue(fixture.registry.requestCancel(fixture.ticket))
            XCTAssertTrue(fixture.registry.transferActivationDisposition(fixture.ticket))
            XCTAssertThrowsError(try fixture.registry.enqueueAudioSession(group: fixture.ticket.group, identity: phase.identity, policy: phase.policy))
            if !foreignIssuer { XCTAssertFalse(phase.hasConsistentActivationProofReferences, "新invocation不能附着旧attempt") }
            guard case .retired(let followUp) = try fixture.registry.retireOutputControlRecord(fixture.ticket) else { return XCTFail("准确原not-invoked应可退休") }
            if let followUp {
                let completion = try graphAudioCall(fixture.registry, lane: fixture.lane, followUp, .activation(nil))
                XCTAssertEqual(completion.disposition, .accepted)
                XCTAssertNil(fixture.registry.phase(of: followUp))
                XCTAssertEqual(fixture.registry.phase(of: try XCTUnwrap(completion.followUp)), .queued)
            }
            if foreignIssuer {
                let ticket = try fixture.registry.enqueueAudioSession(group: fixture.ticket.group, identity: phase.identity, policy: phase.policy)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(ticket, lane: fixture.lane)), .rejected)
                XCTAssertEqual(fixture.registry.phase(of: ticket), .terminal(.canceled))
            } else {
                let before = fixture.registry.occupancy.safetySlots
                XCTAssertThrowsError(try fixture.registry.enqueueAudioSession(group: fixture.ticket.group,
                    identity: phase.identity, policy: phase.policy)) { error in
                    XCTAssertEqual(error as? ControlTaskRegistry.Failure, .invalidGroup)
                }
                XCTAssertEqual(fixture.registry.occupancy.safetySlots, before,
                    "旧 attempt 与新 invocation 的重复字段不自洽，现在于私有冻结前拒绝")
            }
        }
    }

    func testRetiredExactActivationPermitCompletionCannotReplay() throws {
        let fixture = try ActualAudioActivationFixture(kind: 2)
        let first = fixture.ticket
        let firstRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, first)
        let result: AudioSessionBlockingCallResult = .activation(nil)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane,
            firstRequest, result)
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertNil(fixture.registry.phase(of: first), "原物理结果和责任已在组合CAS消费并退休")
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(
            permit: firstRequest.permit, result: result), lane: fixture.lane)), .rejected,
            "旧permit的真实completion replay不能复活已退休调用")
    }

    func testActivationTransactionCannotBeClaimedAgainAfterSuccessOrFailure() throws {
        for (kind, succeeded) in [(0, false), (0, true), (1, false), (1, true), (2, false), (2, true)] {
            let fixture = try ActualAudioActivationFixture(kind: kind)
            let first = fixture.ticket
            let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, first)
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(first, lane: fixture.lane)), .rejected)
            let result: AudioSessionBlockingCallResult = .activation(succeeded ? nil : .init(domain: .audioSession, code: -1))
            let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, result)
            XCTAssertEqual(completion.disposition, succeeded ? .accepted : .settled)
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
                result: result), lane: fixture.lane)), .rejected, "准确结果只能由同CAS消费一次")
            XCTAssertFalse(fixture.registry.claimCompletedResult(first))
            XCTAssertNil(fixture.registry.phase(of: first))
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(first, lane: fixture.lane)), .rejected, "原ticket退休后不能重放")
            if let followUp = completion.followUp {
                XCTAssertNotEqual(followUp, first)
                if succeeded && kind != 0 {
                    XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(
                        .claim(followUp, lane: fixture.lane, family: .audio)), .rejected,
                        "成功后的准确sampler后继不能被audio入口领取")
                    XCTAssertEqual(fixture.registry.phase(of: followUp), .queued,
                        "错family拒绝不得消耗准确后继")
                    let next = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, followUp, family: .sampler)
                    XCTAssertEqual(next.permit.operation, .currentRoute)
                } else {
                    let next = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, followUp, family: .audio)
                    XCTAssertEqual(next.permit.operation, .activate)
                }
            } else if fixture.registry.outputResourceContextSnapshot()?.disposition == .releaseAfterTeardown {
                XCTAssertThrowsError(try fixture.registry.enqueueAudioSession(group: first.group,
                    identity: phase.identity, policy: phase.policy), "terminal清理已封存原group，不能重排旧invocation")
            } else {
                let duplicate = try fixture.registry.enqueueAudioSession(group: first.group, identity: phase.identity, policy: phase.policy)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(duplicate, lane: fixture.lane)), .rejected, "重新排队旧invocation仍不得调用SDK")
            }
        }
    }

    func testNewReactivationAttemptAfterInterruptionCanClaimAndCommitOriginalRecord() throws {
        let fixture = try ActualAudioActivationFixture(kind: 2)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let first = fixture.ticket
        let firstRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, first)
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane,
            firstRequest, .activation(nil)).disposition, .accepted)
        XCTAssertNil(fixture.registry.phase(of: first))
        fixture.registry.executor.sync {
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        }
        let next = try XCTUnwrap(fixture.registry.beginOutputReactivation(contextNonce: phase.identity.contextNonce,
            mandatorySuffix: 1_000_000_000))
        let nextPhase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        XCTAssertNotEqual(nextPhase.policy, phase.policy, "新的实际epoch/attempt必须不同，不能人工重签proof")
        XCTAssertEqual(nextPhase.reactivationBudget?.identity, phase.reactivationBudget?.identity)
        let nextRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, next)
        XCTAssertFalse(fixture.registry.claimCompletedResult(first))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, nextRequest, .activation(nil)).disposition, .accepted)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: nextRequest.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected)
        XCTAssertFalse(fixture.registry.claimCompletedResult(next))
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: firstRequest.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected,
            "真实下一attempt退休后，第一attempt的旧permit仍须被ABA oracle拒绝")
    }

    func testResetPostConfigurationRequiresPresentAndMatchingPreRouteBinding() throws {
        for mismatch in 0..<3 {
            let fixture = try ActualAudioActivationFixture(kind: 2)
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            let old = try XCTUnwrap(phase.resetBinding)
            phase.resetBinding = mismatch == 0 ? nil : .init(rootIdentity: old.rootIdentity,
                ticketIdentity: .init(lineageIdentity: 999,
                    sessionIdentity: phase.identity.sessionIdentity, parentOperationTicketIdentity: phase.parent,
                    nonce: 999), bindingNonce: old.bindingNonce)
            if mismatch == 2 {
                phase.resetBinding = .init(rootIdentity: .init(resetTicket: try fixture.allocator.next(in: .resetRoot),
                    mediaServicesEpoch: old.rootIdentity.mediaServicesEpoch), ticketIdentity: old.ticketIdentity,
                    bindingNonce: old.bindingNonce)
            }
            XCTAssertFalse(phase.hasConsistentResetReferences)
            XCTAssertFalse(phase.hasConsistentActivationProofReferences)
            _ = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
        }
    }

    func testAllActivationPurposesAcceptConsistentFalseMultichannelCapability() throws {
        for (capabilityMatches, kind) in [(false, 0), (false, 1), (false, 2), (true, 0), (true, 1), (true, 2)] {
            let fixture = try ActualAudioActivationFixture(kind: kind, capability: false)
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            XCTAssertEqual(phase.configurationProgress, .complete(actualPolicy: .longFormAudio, preferredFailure: nil, multichannel: false))
            if kind != 1, let receipt = phase.processReceipt {
                phase.processReceipt = .init(identity: receipt.identity, actualPolicy: receipt.actualPolicy,
                    preferredFailureReason: receipt.preferredFailureReason, multichannelCapability: !capabilityMatches,
                    planDigest: receipt.planDigest, attemptLineage: receipt.attemptLineage)
            }
            if kind == 1, let receipt = phase.inactiveReceipt {
                phase.inactiveReceipt = .init(identity: receipt.identity, actualPolicy: receipt.actualPolicy,
                    preferredFailureReason: receipt.preferredFailureReason, planDigest: receipt.planDigest,
                    attemptLineage: receipt.attemptLineage, multichannelCapability: !capabilityMatches)
            }
            XCTAssertEqual(phase.hasConsistentActivationConfiguration, capabilityMatches, "purpose \(kind)")
            if capabilityMatches {
                let ticket = fixture.ticket
                let completion = try graphAudioCall(fixture.registry, lane: fixture.lane, ticket, .activation(nil))
                XCTAssertEqual(completion.disposition, .accepted, "实际capability(false)必须能激活")
                XCTAssertNil(fixture.registry.phase(of: ticket))
                if kind == 0 { XCTAssertNil(completion.followUp) }
                else { XCTAssertEqual(fixture.registry.phase(of: try XCTUnwrap(completion.followUp)), .queued) }
            }
        }
    }

    func testCanceledRunningConfigurationCannotInvokeStepAgain() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let first = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, first)
        XCTAssertTrue(fixture.registry.requestCancel(first))
        XCTAssertFalse(fixture.registry.complete(first), "SDK仍在途；通用complete不能把cancelRequested配置提前变成terminal")
        XCTAssertEqual(fixture.registry.phase(of: first), .cancelRequested)
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(first), .rejected)
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request,
            .configuration(.categorySucceeded)).disposition, .settled)
        XCTAssertNil(fixture.registry.phase(of: first))
        let retry = try fixture.registry.enqueueAudioSession(group: first.group, identity: phase.identity, policy: phase.policy)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(retry, lane: fixture.lane)), .rejected)
    }

    func testCoalescedBeganEndedInvalidatesRegisteredReactivationProof() throws {
        let fixture = try ActualAudioActivationFixture(kind: 2)
        XCTAssertNotNil(fixture.registry.registeredAudioSessionPhase()?.currentReactivationProof)
        fixture.registry.executor.sync {
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            _ = fixture.registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
            XCTAssertNil(fixture.registry.registeredAudioSessionPhase()?.currentReactivationProof)
        }
    }

    func testResetCommitAndPostConfigurationActivationUseExactReceiptAndProof() throws {
        for postConfiguration in [false, true] {
            let fixture = try ActualAudioActivationFixture(kind: postConfiguration ? 2 : 1)
            let ticket = fixture.ticket
            let completion = try graphAudioCall(fixture.registry, lane: fixture.lane, ticket, .activation(nil))
            XCTAssertEqual(completion.disposition, .accepted)
            XCTAssertEqual(fixture.registry.phase(of: try XCTUnwrap(completion.followUp)), .queued)
            XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
        }
    }

    func testResetActivationRejectsMissingReceiptOrMismatchedRegisteredProof() throws {
        for postConfiguration in [false, true] {
            let fixture = try ActualAudioActivationFixture(kind: postConfiguration ? 2 : 1)
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            if postConfiguration { phase.currentReactivationProof = nil } else { phase.inactiveReceipt = nil }
            XCTAssertFalse(phase.hasConsistentActivationProofReferences)
            if !postConfiguration { XCTAssertFalse(phase.hasConsistentActivationConfiguration) }
            _ = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
        }
    }

    func testResetAcquisitionCannotDropPreRouteBinding() throws {
        let fixture = try ActualAudioConfigurationFixture(resetAcquisition: true)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let binding = try XCTUnwrap(context.resetPreRouteBinding)
        XCTAssertEqual(binding.ticketIdentity, fixture.registry.resetPreRouteDeadlineSnapshot()?.ticketIdentity)
        let first = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        XCTAssertEqual(first.resetBinding, binding, "首reset的phase必须从唯一context复制完整非nil binding")
        let wrongParent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
            identity: .init(sessionIdentity: context.sessionIdentity, nonce: 999), kind: .coldStart,
            originInstant: 50, cap: 40_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        XCTAssertNil(try fixture.registry.beginOutputAcquisitionConfiguration(contextNonce: context.contextNonce, parent: wrongParent))
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase(), first)
        let completion = try graphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket, .configuration(.categorySucceeded))
        XCTAssertNil(fixture.registry.phase(of: fixture.ticket))
        let next = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.resetBinding, binding)
        let nextRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, next)
        fixture.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertEqual(fixture.registry.phase(of: next), .cancelRequested)
        let late = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, nextRequest, .configuration(.multichannelCapability(true)))
        XCTAssertEqual(late.disposition, .settled)
        XCTAssertNil(late.followUp)
        XCTAssertNil(fixture.registry.phase(of: next))
        XCTAssertNil(fixture.registry.processAudioSessionReceiptSnapshot())
    }

    func testRunningConfigurationCannotUseGenericCompletionAndRepeatSameStep() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let ticket = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
        XCTAssertFalse(fixture.registry.complete(ticket))
        XCTAssertEqual(fixture.registry.phase(of: ticket), .running)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .configuration(.categorySucceeded))
        XCTAssertNil(fixture.registry.phase(of: ticket))
        let next = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
        XCTAssertTrue(fixture.registry.requestCancel(next))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(next), .retired(followUp: nil))
        let duplicate = try fixture.registry.enqueueAudioSession(group: ticket.group,
            identity: phase.identity, policy: phase.policy)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(duplicate, lane: fixture.lane)), .rejected)
    }

    func testReactivationUsesRegisteredDrainProofAcrossEndedEpochAndRejectsNextBegan() async throws {
        for drainBeforeEnded in [false, true] {
            let fixture = try await ActualOrdinaryReactivationFixture(drainBeforeEnded: drainBeforeEnded)
            let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            let snapshot = fixture.registry.executor.safetyIngress.snapshot
            XCTAssertEqual(fixture.proof.interruptionEpoch, drainBeforeEnded ? 1 : 2)
            XCTAssertEqual(snapshot.interruptionEpoch, 2)
            XCTAssertEqual(phase.currentReactivationProof, .interruption(fixture.proof))
            let ticket = fixture.ticket
            let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            XCTAssertEqual(fixture.registry.phase(of: ticket), .cancelRequested)
            XCTAssertNil(fixture.registry.registeredAudioSessionPhase()?.currentReactivationProof)
            let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .activation(nil))
            XCTAssertEqual(completion.disposition, .settled)
            XCTAssertNil(completion.followUp)
            XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
        }
    }

    func testResetInactivePhaseCrossesRouteAndInterruptionButRejectsNewReset() throws {
        let fixture = try ActualAudioConfigurationFixture(resetInactive: true)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let ticket = fixture.ticket
        fixture.registry.executor.safetyIngress.beginRouteObservation(.init(
            sessionIdentity: phase.identity.sessionIdentity, monitorLifecycle: 1,
            notificationRevision: 1, reasonBits: 1, topologyChangeHint: true,
            outputConfigurationChanged: false, observedRoute: nil))
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(fixture.registry.phase(of: ticket), .running)
        fixture.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertEqual(fixture.registry.phase(of: ticket), .cancelRequested)
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request,
            .configuration(.categorySucceeded)).disposition, .settled)
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.configurationProgress, .awaitingLongForm)
        XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
    }

    func testResetInactiveWrongProofIsRejectedAndConfigurationSuccessSkipsFallback() throws {
        let fixture = try ActualAudioConfigurationFixture(resetInactive: true)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let incarnation = try XCTUnwrap(phase.incarnation)
        let wrong = AudioSessionPhasePolicy.configureInactive(incarnation: incarnation.identity,
            resetDrainProof: .init(root: incarnation.identity.root, proofNonce: 999),
            configurationAttemptNonce: phase.configurationAttempt.nonce, step: .longFormCategoryAttempt)
        var forged = phase
        forged.policy = wrong
        XCTAssertFalse(forged.hasConsistentConfigurationProofReferences, "错proof拒绝来自生产同一纯引用校验，不借slotOccupied")
        XCTAssertTrue(phase.hasConsistentConfigurationProofReferences)
        XCTAssertTrue(fixture.registry.requestCancel(fixture.ticket))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(fixture.ticket), .retired(followUp: nil),
            "必须先准确取消并typed退休原queued record，给真实错policy留下空槽")
        let rejected = try fixture.registry.enqueueAudioSession(group: fixture.ticket.group,
            identity: phase.identity, policy: wrong)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(rejected, lane: fixture.lane)), .rejected, "外部可表达的错误reset proof必须由真实claim拒绝")
        XCTAssertEqual(fixture.registry.phase(of: rejected), .terminal(.canceled))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(rejected), .retired(followUp: nil))
        let acceptedFixture = try ActualAudioConfigurationFixture(resetInactive: true)
        let completion = try graphAudioCall(acceptedFixture.registry, lane: acceptedFixture.lane,
            acceptedFixture.ticket, .configuration(.categorySucceeded))
        XCTAssertEqual(acceptedFixture.registry.phase(of: try XCTUnwrap(completion.followUp)), .queued)
        XCTAssertEqual(acceptedFixture.registry.registeredAudioSessionPhase()?.configurationProgress,
            .awaitingMultichannel(actualPolicy: .longFormAudio, preferredFailure: nil))
    }

    func testActivationRejectsInconsistentPurposeProofAndMissingConfiguredReceipt() throws {
        for mismatch in 0..<3 {
            let fixture = try ActualAudioActivationFixture(kind: 0)
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            if mismatch == 0 { phase.configuredReceipt = nil }
            if mismatch == 1 {
                guard case .activate(.activateAcquiredConfiguredGeneration(let session, let generation, let proof), let epoch, let fence, let invocation) = phase.policy else { return XCTFail("真实acquired purpose缺失") }
                phase.policy = .activate(purpose: .activateAcquiredConfiguredGeneration(
                    sessionIdentity: session, committedGeneration: generation,
                    acquisitionOwnershipProof: .init(acquisitionTicket: proof.acquisitionTicket,
                        sessionIdentity: session, leaseID: proof.leaseID,
                        contextNonce: 999, ownershipNonce: proof.ownershipNonce)),
                    interruptionEpoch: epoch, audioAdmissionFenceRevision: fence, invocationIdentity: invocation)
            }
            if mismatch == 2 { phase.configurationProgress = .awaitingLongForm }
            XCTAssertFalse(phase.hasConsistentActivationConfiguration && phase.hasConsistentActivationProofReferences,
                "内层不匹配项 \(mismatch)")
            if mismatch == 1 {
                XCTAssertTrue(fixture.registry.requestCancel(fixture.ticket))
                XCTAssertTrue(fixture.registry.transferActivationDisposition(fixture.ticket))
                XCTAssertEqual(try fixture.registry.retireOutputControlRecord(fixture.ticket), .retired(followUp: nil))
                let forged = try fixture.registry.enqueueAudioSession(group: fixture.ticket.group, identity: phase.identity, policy: phase.policy)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(forged, lane: fixture.lane)), .rejected, "外部仍可表达的错policy保持真实拒绝")
            } else {
                _ = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
            }
        }
    }

    func testAudioFailureCannotCommitActivationAndGenericCompletionCannotLoseOutcome() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let ticket = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
        XCTAssertFalse(fixture.registry.complete(ticket))
        let failure = AudioSessionFixedFailure(domain: .audioSession, code: -50)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .activation(failure))
        XCTAssertEqual(completion.disposition, .settled)
        XCTAssertNil(completion.followUp)
        XCTAssertNil(fixture.registry.phase(of: ticket))
        XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
        XCTAssertEqual(graphOwnedDeactivation(fixture.registry),
            .confirmedInactive(.activationReturnedFailure(.init(record: ticket, phaseIdentity: phase.identity), failure)))
    }

    func testConfigurationFallbackRequiresAccurateCompletedFailureAndAdvancesOnce() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let failure = AudioSessionFixedFailure(domain: .osStatus, code: -1)
        let first = fixture.ticket
        let initial = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        XCTAssertThrowsError(try fixture.next(), "原longForm仍在途时不得发行fallback或第二命令") {
            guard case ControlTaskRegistry.Failure.slotOccupied = $0 else { return XCTFail("必须在原slot拒绝") }
        }
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.configurationProgress, .awaitingLongForm)
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, first)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .configuration(.failed(failure)))
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.configurationProgress,
            .awaitingFallback(preferredFailure: failure))
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
            result: .configuration(.categorySucceeded)), lane: fixture.lane)), .rejected)
        XCTAssertNil(fixture.registry.phase(of: first))
        let second = try XCTUnwrap(completion.followUp)
        let fallback = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        XCTAssertEqual(fallback.configurationAttempt, initial.configurationAttempt)
        guard case .configureAcquisition(_, _, _, .defaultCategoryFallbackAttempt) = fallback.policy else { return XCTFail("准确失败后必须发行fallback") }
        let secondCompletion = try graphAudioCall(fixture.registry, lane: fixture.lane, second, .configuration(.categorySucceeded))
        XCTAssertEqual(fixture.registry.phase(of: try XCTUnwrap(secondCompletion.followUp)), .queued)
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.configurationProgress,
            .awaitingMultichannel(actualPolicy: .default, preferredFailure: failure))
    }

    func testCleanupDeadlineIsCheckedAbsoluteFiveSeconds() throws {
        let fixture = try AudioPhaseFixture()
        let budget = try CleanupBudgetTicket(predecessorIdentity: fixture.group.resourceIdentity,
            anchorInstant: 7, nonce: fixture.otherNonce)
        XCTAssertEqual(budget.deadlineInstant, 5_000_000_007)
        XCTAssertThrowsError(try CleanupBudgetTicket(predecessorIdentity: fixture.group.resourceIdentity,
            anchorInstant: UInt64.max, nonce: fixture.otherNonce))
    }

    func testQueuedAudioActivationCancellationProducesNotInvokedAndRunningLateSuccessRequiresDeactivate() throws {
        for running in [false, true] {
            let fixture = try ActualAudioActivationFixture(kind: 0)
            let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            let ticket = fixture.ticket
            let call = AudioSessionCallIdentity(record: ticket, phaseIdentity: phase.identity)
            var request: AudioSessionBlockingCallRequest?
            if running {
                request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
                XCTAssertEqual(fixture.registry.activationDeactivationDisposition(of: ticket), .awaitingActivationOutcome(call))
            }
            XCTAssertTrue(fixture.registry.requestCancel(ticket))
            if running {
                fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
                XCTAssertEqual(fixture.registry.activationDeactivationDisposition(of: ticket), .awaitingActivationOutcome(call))
                let original = try XCTUnwrap(request)
                let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, original, .activation(nil))
                XCTAssertEqual(completion.disposition, .settled)
                XCTAssertNil(fixture.registry.phase(of: ticket))
                XCTAssertEqual(graphOwnedDeactivation(fixture.registry), .requiresDeactivate(.returnedSuccess(call)))
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: original.permit,
                    result: .activation(nil)), lane: fixture.lane)), .rejected)
            } else {
                let proof = AudioSessionCanceledBeforeClaimProof(callIdentity: call)
                XCTAssertEqual(fixture.registry.activationOutcome(of: ticket), .notInvoked(proof))
                XCTAssertEqual(fixture.registry.activationDeactivationDisposition(of: ticket), .confirmedInactive(.activationNotInvoked(proof)))
            }
            XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(ticket, lane: fixture.lane)), .rejected)
        }
    }

    func testAudioSlotCannotBeReusedAcrossResourcesUntilRecordTerminalAndRetired() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let ticket = fixture.ticket
        let other = try fixture.registry.createGroup(resource: .context(session: phase.identity.sessionIdentity, nonce: 999))
        XCTAssertThrowsError(try fixture.registry.enqueueAudioSession(group: other,
            identity: phase.identity, policy: phase.policy))
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
        XCTAssertTrue(fixture.registry.requestCancel(ticket))
        XCTAssertFalse(fixture.registry.retire(ticket))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request,
            .configuration(.categorySucceeded)).disposition, .settled)
        XCTAssertNil(fixture.registry.phase(of: ticket))
    }

    func testAudioConfigurationRejectsUnregisteredPhaseWrongOwnerProofAndStep() throws {
        for mismatch in 0..<4 {
            if mismatch == 0 {
                let fixture = try AudioPhaseFixture(ownsResources: false)
                let ticket = try fixture.registry.enqueueAudioSession(group: fixture.group, identity: fixture.phase.identity, policy: fixture.phase.policy)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(ticket, lane: fixture.lane)), .rejected, "无发行phase不能调用")
                XCTAssertEqual(fixture.registry.phase(of: ticket), .terminal(.canceled))
                continue
            }
            let fixture = try ActualAudioConfigurationFixture()
            var phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
            if mismatch == 1 {
                let group = fixture.ticket.group
                let wrongOwner = ControlTaskTicket(group: .init(resourceIdentity: group.resourceIdentity,
                    ownerTicket: .init(resourceIdentity: group.resourceIdentity, nonce: 999), nonce: group.nonce), nonce: fixture.ticket.nonce)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(wrongOwner, lane: fixture.lane)), .rejected, "外部错误owner仍由实际record匹配拒绝")
            } else {
                guard case .configureAcquisition(let source, let ownership, let attempt, _) = phase.policy else { return XCTFail("真实acquisition配置缺失") }
                phase.policy = .configureAcquisition(acquisitionTicket: source, ownershipNonce: mismatch == 2 ? 999 : ownership,
                    configurationAttemptNonce: attempt, step: mismatch == 3 ? .defaultCategoryFallbackAttempt : .longFormCategoryAttempt)
                XCTAssertFalse(phase.hasConsistentConfigurationProofReferences && phase.hasConsistentConfigurationStep,
                    "内部proof/step不匹配项 \(mismatch)由生产同一predicate拒绝")
                XCTAssertTrue(fixture.registry.requestCancel(fixture.ticket))
                XCTAssertEqual(try fixture.registry.retireOutputControlRecord(fixture.ticket), .retired(followUp: nil),
                    "必须先准确取消并typed退休原queued record，不能用slotOccupied代替真实拒绝")
                let rejected = try fixture.registry.enqueueAudioSession(group: fixture.ticket.group,
                    identity: phase.identity, policy: phase.policy)
                XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(rejected, lane: fixture.lane)), .rejected,
                    "外部可表达的错误ownership nonce/fallback step必须由真实claim拒绝")
                XCTAssertEqual(fixture.registry.phase(of: rejected), .terminal(.canceled))
                XCTAssertEqual(try fixture.registry.retireOutputControlRecord(rejected), .retired(followUp: nil))
                continue
            }
            _ = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
        }
    }

    func testAudioInactiveConfigurationSurvivesInterruptionButReleaseDisablesCalls() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let ticket = fixture.ticket
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, ticket)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertNotNil(try OutputCleanupCoordinator(registry: fixture.registry).begin(contextNonce: context.contextNonce,
            reason: .terminal, at: 100, teardown: true))
        XCTAssertEqual(fixture.registry.phase(of: ticket), .cancelRequested)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .configuration(.categorySucceeded))
        XCTAssertEqual(completion.disposition, .settled)
        XCTAssertNil(completion.followUp)
        XCTAssertFalse(fixture.registry.claimCompletedResult(ticket))
    }

    // 如果runner先调用SDK再复验route，正rate计数就会增加。
    func testRouteIngressCancelsQueuedActivationBeforeSideEffect() throws {
        let harness = try ControlCommandTestHarness()
        let command = try harness.enqueue(.activation, policy: .activationRequiresOpen)
        harness.ingressRouteChange()
        XCTAssertFalse(harness.run(command))
        XCTAssertEqual(harness.calls, 0)
        XCTAssertEqual(harness.registry.phase(of: command), .terminal(.canceled))
    }

    // 同一个安全slot只能被claim一次，关闭route不能阻止停止旧输出。
    func testSafetyCommandClaimsOnceWithClosedRouteGate() throws {
        let harness = try ControlCommandTestHarness()
        harness.ingressRouteChange()
        let command = try harness.enqueue(.suspend, policy: .safetyBypass)
        XCTAssertTrue(harness.run(command))
        XCTAssertFalse(harness.run(command))
        XCTAssertEqual(harness.calls, 1)
    }

    func testOpenRouteAllowsActivationAndCancellationKeepsRunningRecordUntilCompletion() throws {
        let harness = try ControlCommandTestHarness()
        harness.openRoute()
        let command = try harness.enqueue(.activation, policy: .activationRequiresOpen)
        XCTAssertTrue(harness.run(command))
        harness.ingressRouteChange()
        XCTAssertEqual(harness.registry.phase(of: command), .cancelRequested)
        XCTAssertTrue(harness.registry.complete(command))
        XCTAssertEqual(harness.registry.phase(of: command), .terminal(.canceled))
        XCTAssertFalse(harness.registry.complete(command))
    }

    func testSpeculativeWorkParksButNeutralAndSafetyWorkRunWhileRoutePending() throws {
        let harness = try ControlCommandTestHarness()
        let prepare = try harness.enqueue(.prepare, policy: .routeSpeculativeRateZero)
        let accounting = try harness.enqueue(.accounting, policy: .routeNeutral)
        XCTAssertFalse(harness.run(prepare))
        XCTAssertEqual(harness.registry.phase(of: prepare), .queued)
        XCTAssertTrue(harness.run(accounting))
        harness.openRoute()
        XCTAssertTrue(harness.run(prepare))
    }

    func testSystemChangeCancelsSpeculativeAndNeutralButNotCleanup() throws {
        let harness = try ControlCommandTestHarness()
        let factory = try harness.enqueue(.factory, policy: .routeSpeculativeRateZero)
        let acquire = try harness.enqueue(.acquire, policy: .routeNeutral)
        let stop = try harness.enqueue(.suspend, policy: .safetyBypass)
        harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertFalse(harness.run(factory))
        XCTAssertFalse(harness.run(acquire))
        XCTAssertTrue(harness.run(stop))
    }

    func testOrdinaryPoolCannotBorrowSafetyCapacity() throws {
        let registry = ControlTaskRegistry()
        var lastGroup: ControlTaskGroupTicket?
        for index in 0..<16 {
            let group = try registry.createGroup(resource: .context(session: testSession, nonce: UInt64(index)))
            _ = try registry.enqueue(group: group, slot: .factory, policy: .routeSpeculativeRateZero)
            lastGroup = group
        }
        let group = try registry.createGroup(resource: .context(session: testSession, nonce: 20))
        XCTAssertThrowsError(try registry.enqueue(group: group, slot: .factory, policy: .routeSpeculativeRateZero))
        let safety = try registry.enqueue(group: try XCTUnwrap(lastGroup), slot: .suspend, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(safety))
        XCTAssertThrowsError(try registry.enqueue(group: group, slot: .factory, policy: .safetyBypass))
    }

    func testTerminalRecordMustBeRetiredBeforeSlotCanBeReusedAndOldTicketNeverClaims() throws {
        let harness = try ControlCommandTestHarness()
        let first = try harness.enqueue(.suspend, policy: .safetyBypass)
        XCTAssertThrowsError(try harness.enqueue(.suspend, policy: .safetyBypass))
        XCTAssertTrue(harness.run(first))
        XCTAssertFalse(harness.registry.retire(first))
        XCTAssertTrue(harness.registry.complete(first))
        XCTAssertThrowsError(try harness.enqueue(.suspend, policy: .safetyBypass))
        XCTAssertTrue(harness.registry.retire(first))
        let second = try harness.enqueue(.suspend, policy: .safetyBypass)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(harness.run(first))
        XCTAssertTrue(harness.run(second))
    }

    func testSealedGroupRejectsNewWorkAndJoinsRunningChildren() throws {
        let harness = try ControlCommandTestHarness()
        let command = try harness.enqueue(.suspend, policy: .safetyBypass)
        XCTAssertTrue(harness.run(command))
        XCTAssertTrue(harness.registry.seal(harness.group))
        XCTAssertFalse(harness.registry.isTerminal(harness.group))
        XCTAssertThrowsError(try harness.enqueue(.activation, policy: .activationRequiresOpen))
        XCTAssertTrue(harness.registry.complete(command))
        XCTAssertTrue(harness.registry.isTerminal(harness.group))
    }

    func testIdentityExhaustionDoesNotInstallPartialGroup() {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator(initialIssuedValue: UInt64.max))
        XCTAssertThrowsError(try registry.createGroup(resource: .session(testSession)))
    }

    func testSameResourceCannotObtainDuplicateSlotThroughSecondGroup() throws {
        let registry = ControlTaskRegistry()
        let first = try registry.createGroup(resource: .session(testSession))
        let second = try registry.createGroup(resource: .session(testSession))
        _ = try registry.enqueue(group: first, slot: .suspend, policy: .safetyBypass)
        XCTAssertThrowsError(try registry.enqueue(group: second, slot: .suspend, policy: .safetyBypass))
    }

    func testTicketsRejectForgedResourceOwnerAndForeignRegistry() throws {
        let harness = try ControlCommandTestHarness()
        let ticket = try harness.enqueue(.suspend, policy: .safetyBypass)
        let wrongOwner = ControlTaskOwnerTicket(resourceIdentity: harness.group.resourceIdentity,
                                                nonce: harness.group.ownerTicket.nonce + 1)
        let forged = ControlTaskGroupTicket(resourceIdentity: harness.group.resourceIdentity,
                                            ownerTicket: wrongOwner, nonce: harness.group.nonce)
        XCTAssertFalse(harness.registry.claimStart(ControlTaskTicket(group: forged, nonce: ticket.nonce)))
        XCTAssertThrowsError(try harness.registry.enqueue(group: forged, slot: .factory, policy: .routeSpeculativeRateZero))
        let wrongResource = ControlTaskGroupTicket(
            resourceIdentity: .context(session: testSession, nonce: 9_999),
            ownerTicket: harness.group.ownerTicket, nonce: harness.group.nonce)
        XCTAssertFalse(harness.registry.claimStart(ControlTaskTicket(group: wrongResource, nonce: ticket.nonce)))
        XCTAssertThrowsError(try harness.registry.enqueue(group: wrongResource,
            slot: .factory, policy: .routeSpeculativeRateZero))
        XCTAssertFalse(ControlTaskRegistry().claimStart(ticket))
        XCTAssertTrue(harness.run(ticket))
    }

    func testFrozenCommandRejectsInconsistentResourceBeforeInstallation() throws {
        let harness = try ControlCommandTestHarness()
        let valid = try harness.enqueue(.suspend, policy: .safetyBypass)
        let other = ControlResourceIdentity.context(session: testSession, nonce: 99_999)
        func install(_ group: ControlTaskGroupTicket) throws -> OwnedPostIngressControlCommand {
            try OwnedPostIngressControlCommand(controlTaskTicket: .init(group: group, nonce: valid.nonce),
                slot: .suspend, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
        }
        for group in [
            ControlTaskGroupTicket(resourceIdentity: other,
                ownerTicket: valid.group.ownerTicket, nonce: valid.group.nonce),
            ControlTaskGroupTicket(resourceIdentity: valid.group.resourceIdentity,
                ownerTicket: .init(resourceIdentity: other, nonce: valid.group.ownerTicket.nonce),
                nonce: valid.group.nonce)
        ] {
            XCTAssertThrowsError(try install(group))
            XCTAssertThrowsError(try harness.registry.createGroup(resource: other, parent: group))
            XCTAssertThrowsError(try harness.registry.enqueue(group: group,
                slot: .factory, policy: .routeSpeculativeRateZero))
        }
        XCTAssertTrue(harness.run(valid))
    }

    func testCleanupOwnerCanOnlyJoinDescendantAndCannotWaitForItself() throws {
        let registry = ControlTaskRegistry()
        let parent = try registry.createGroup(resource: .context(session: testSession, nonce: 1))
        let child = try registry.createGroup(resource: .context(session: testSession, nonce: 2), parent: parent)
        let unrelated = try registry.createGroup(resource: .context(session: testSession, nonce: 3))
        let cleanup = try registry.enqueue(group: parent, slot: .suspend, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        let childWork = try registry.enqueue(group: child, slot: .suspend, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(childWork))
        XCTAssertTrue(registry.seal(child))
        XCTAssertFalse(registry.join(parent, from: cleanup))
        XCTAssertFalse(registry.join(unrelated, from: cleanup))
        XCTAssertFalse(registry.join(child, from: cleanup))
        XCTAssertTrue(registry.complete(childWork))
        XCTAssertTrue(registry.join(child, from: cleanup))
    }

    func testFrozenTicketRejectsEveryIdentityMutationAndPreservesDifferentParentResource() throws {
        let session = PlaybackSessionIdentity(sessionID: 401, requestID: UUID())
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: 402)
        let lifecycle = OutputLifecycleEpoch(backendIdentity: backend, outputNonce: 403)
        let resource = ControlResourceIdentity.outputLifecycle(lifecycle)
        let registry = ControlTaskRegistry()
        let parent = try registry.createGroup(resource: .context(session: session, nonce: 404))
        let group = try registry.createGroup(resource: resource, parent: parent)
        let task = try registry.enqueue(group: group, slot: .suspend, policy: .safetyBypass)
        let changedSessionID = PlaybackSessionIdentity(sessionID: 999, requestID: session.requestID)
        let changedRequestID = PlaybackSessionIdentity(sessionID: session.sessionID, requestID: UUID())
        let resources: [ControlResourceIdentity] = [
            .outputLifecycle(.init(backendIdentity: .init(sessionIdentity: changedSessionID,
                backendGeneration: 402), outputNonce: 403)),
            .outputLifecycle(.init(backendIdentity: .init(sessionIdentity: changedRequestID,
                backendGeneration: 402), outputNonce: 403)),
            .outputLifecycle(.init(backendIdentity: .init(sessionIdentity: session,
                backendGeneration: 999), outputNonce: 403)),
            .outputLifecycle(.init(backendIdentity: backend, outputNonce: 999)),
            .backend(backend)
        ]
        var mutations = resources.map { changed in
            ControlTaskTicket(group: .init(resourceIdentity: changed,
                ownerTicket: .init(resourceIdentity: changed, nonce: group.ownerTicket.nonce),
                nonce: group.nonce), nonce: task.nonce)
        }
        mutations += [
            .init(group: .init(resourceIdentity: resource,
                ownerTicket: .init(resourceIdentity: resource, nonce: group.ownerTicket.nonce + 1),
                nonce: group.nonce), nonce: task.nonce),
            .init(group: .init(resourceIdentity: resource, ownerTicket: group.ownerTicket,
                nonce: group.nonce + 1), nonce: task.nonce),
            .init(group: group, nonce: task.nonce + 1)
        ]
        for (index, changed) in mutations.enumerated() {
            XCTAssertFalse(registry.claimStart(changed), "身份变异\(index)不能开启原命令")
            XCTAssertFalse(registry.requestCancel(changed), "身份变异\(index)不能取消原命令")
            XCTAssertFalse(registry.complete(changed), "身份变异\(index)不能退休原命令")
            XCTAssertNil(registry.phase(of: changed))
            let frozen = try OwnedPostIngressControlCommand(controlTaskTicket: changed,
                slot: .suspend, safetySnapshot: .cleanupOwnership, gatePolicy: .safetyBypass)
            XCTAssertEqual(frozen.controlTaskTicket, changed, "投影必须保存原错票，不能规范化成当前票")
        }
        XCTAssertTrue(registry.claimStart(task))
        let cleanup = try registry.enqueue(group: parent, slot: .suspend, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        XCTAssertTrue(registry.seal(group))
        XCTAssertFalse(registry.join(group, from: task), "不能自join")
        XCTAssertFalse(registry.join(group, from: cleanup), "原子任务仍在运行")
        XCTAssertTrue(registry.complete(task))
        XCTAssertTrue(registry.join(group, from: cleanup), "parent必须保留自己的不同resource")
        let projected = try FrozenControlTaskGroupTicket(parent)
        XCTAssertEqual(projected.ticket, parent)
        let remainingResourceFields: [(ControlResourceIdentity, ControlResourceIdentity)] = [
            (.lease(session: session, leaseID: 501), .lease(session: session, leaseID: 502)),
            (.monitor(session: session, lifecycle: 503), .monitor(session: session, lifecycle: 504)),
            (.context(session: session, nonce: 505), .context(session: session, nonce: 506)),
            (.session(session), .session(changedSessionID)),
            (.session(session), .session(changedRequestID))
        ]
        for (original, changed) in remainingResourceFields {
            let ownerRegistry = ControlTaskRegistry()
            let ownedGroup = try ownerRegistry.createGroup(resource: original)
            let ownedTask = try ownerRegistry.enqueue(group: ownedGroup, slot: .suspend, policy: .safetyBypass)
            let forged = ControlTaskTicket(group: .init(resourceIdentity: changed,
                ownerTicket: .init(resourceIdentity: changed, nonce: ownedGroup.ownerTicket.nonce),
                nonce: ownedGroup.nonce), nonce: ownedTask.nonce)
            XCTAssertFalse(ownerRegistry.claimStart(forged))
            XCTAssertFalse(ownerRegistry.requestCancel(forged))
            XCTAssertFalse(ownerRegistry.complete(forged))
            XCTAssertTrue(ownerRegistry.claimStart(ownedTask))
        }
    }

    func testGroupCannotReleaseRunningChildOrAcceptChildAfterSeal() throws {
        let harness = try ControlCommandTestHarness()
        let command = try harness.enqueue(.suspend, policy: .safetyBypass)
        XCTAssertTrue(harness.run(command))
        XCTAssertFalse(harness.registry.releaseGroup(harness.group))
        XCTAssertTrue(harness.registry.seal(harness.group))
        XCTAssertThrowsError(try harness.registry.createGroup(resource: .session(testSession), parent: harness.group))
        XCTAssertTrue(harness.registry.complete(command))
        XCTAssertTrue(harness.registry.releaseGroup(harness.group))
        XCTAssertNil(harness.registry.phase(of: command))
        XCTAssertFalse(harness.registry.complete(command))
    }

    func testNotificationRouteHintsOnlyParkSpeculativeWorkUntilAuthoritativeSample() throws {
        let harness = try ControlCommandTestHarness()
        harness.ingressRouteChange(semantic: localRoute)
        let first = try harness.enqueue(.prepare, policy: .routeSpeculativeRateZero)
        harness.ingressRouteChange(semantic: localRoute)
        XCTAssertFalse(harness.run(first))
        XCTAssertEqual(harness.registry.phase(of: first), .queued)
        harness.openRoute()
        XCTAssertTrue(harness.run(first))
        harness.ingressRouteChange(semantic: airPlayRoute)
        XCTAssertEqual(harness.registry.phase(of: first), .running,
            "notification里的semantic只是hint；真实getter结果才有权撤销旧semantic工作")
    }

    func testTopologyHintWithoutChangedSemanticOnlyParksSpeculativeWork() throws {
        let harness = try ControlCommandTestHarness()
        harness.ingressRouteChange(semantic: localRoute)
        let ticket = try harness.enqueue(.prepare, policy: .routeSpeculativeRateZero)
        harness.ingressRouteChange(semantic: localRoute, topologyHint: true)
        XCTAssertFalse(harness.run(ticket))
        XCTAssertEqual(harness.registry.phase(of: ticket), .queued)
        harness.openRoute()
        XCTAssertTrue(harness.run(ticket))
    }

    func testEverySafetyOperationUsesSafetyPoolAndEligibleSpeculativeOperationParks() throws {
        let harness = try ControlCommandTestHarness()
        let safety: [ControlTaskSlot] = [.sampler, .cancel, .suspend, .retirement, .candidateCleanup,
                                        .committedCleanup, .teardown, .monitorStop, .leaseRelease]
        for slot in safety {
            let ticket = try harness.enqueue(slot, policy: .safetyBypass)
            if slot == .sampler {
                XCTAssertFalse(harness.run(ticket), "sampler仍占安全池，但无真实注册/组合lane不能裸claim")
                XCTAssertEqual(harness.registry.phase(of: ticket), .queued)
            } else { XCTAssertTrue(harness.run(ticket)) }
        }
        let factory = try harness.enqueue(.factory, policy: .routeSpeculativeRateZero)
        XCTAssertEqual(harness.registry.phase(of: factory), .queued,
            "factory仍占普通池；无正式admission时的claim拒绝由资源图测试覆盖")
        for slot: ControlTaskSlot in [.prepare, .candidateItem, .probe] {
            let ticket = try harness.enqueue(slot, policy: .routeSpeculativeRateZero)
            XCTAssertFalse(harness.run(ticket))
            XCTAssertEqual(harness.registry.phase(of: ticket), .queued)
        }
        XCTAssertEqual(harness.registry.occupancy.safetySlots, 9)
        XCTAssertEqual(harness.registry.occupancy.ordinarySlots, 4)
    }

    func testSafetyHardCapacityAndGroupCapacityRejectBeforeSideEffect() throws {
        let registry = ControlTaskRegistry()
        for index in 0..<16 {
            let group = try registry.createGroup(resource: .context(session: testSession, nonce: UInt64(index)))
            _ = try registry.enqueue(group: group, slot: .suspend, policy: .safetyBypass)
        }
        let extra = try registry.createGroup(resource: .context(session: testSession, nonce: 16))
        XCTAssertThrowsError(try registry.enqueue(group: extra, slot: .suspend, policy: .safetyBypass))
        _ = try registry.enqueue(group: extra, slot: .factory, policy: .routeSpeculativeRateZero)
        for index in 17..<32 {
            _ = try registry.createGroup(resource: .context(session: testSession, nonce: UInt64(index)))
        }
        XCTAssertThrowsError(try registry.createGroup(resource: .context(session: testSession, nonce: 32)))
    }

    func testRouteNeutralCanAcquireDuringExistingInterruptionButDataPlaneCannotStart() throws {
        let registry = ControlTaskRegistry()
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        let acquire = try beginManagedAcquisition(registry)
        let prepare = try registry.enqueue(group: acquire.group, slot: .prepare, policy: .routeSpeculativeRateZero)
        XCTAssertTrue(registry.claimStart(acquire))
        XCTAssertFalse(registry.claimStart(prepare))
        XCTAssertEqual(registry.phase(of: prepare), .terminal(.canceled),
            "已有interruption会取消数据面工作，但不能取消真实route-neutral reservation")
    }

    func testQueuedAndRunningReservationSurviveInterruptionEpochAndFenceChanges() throws {
        for running in [false, true] {
            let registry = ControlTaskRegistry()
            let acquire = try beginManagedAcquisition(registry)
            if running { XCTAssertTrue(registry.claimStart(acquire)) }
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            XCTAssertEqual(registry.phase(of: acquire), running ? .running : .queued)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
            XCTAssertEqual(registry.phase(of: acquire), running ? .running : .queued)
            if !running { XCTAssertTrue(registry.claimStart(acquire)) }
            XCTAssertFalse(registry.claimStart(acquire), "同一真实acquisition只能取得一次SDK调用权")
            XCTAssertTrue(registry.completeOutputAcquisitionWithoutLease(acquire))
            XCTAssertEqual(registry.phase(of: acquire), .terminal(.completed))
        }
    }

    func testExplicitQueuedCancelIsTerminalWithoutSDKCompletion() throws {
        let harness = try ControlCommandTestHarness()
        let ticket = try harness.enqueue(.factory, policy: .routeSpeculativeRateZero)
        XCTAssertTrue(harness.registry.requestCancel(ticket))
        XCTAssertEqual(harness.registry.phase(of: ticket), .terminal(.canceled))
        XCTAssertFalse(harness.registry.complete(ticket))
        XCTAssertTrue(harness.registry.retire(ticket))
        XCTAssertEqual(harness.calls, 0)
    }

    func testPendingSpeculativeResultCannotCommitAndSameSemanticOnlyCommitsOnce() throws {
        let harness = try ControlCommandTestHarness()
        harness.ingressRouteChange(semantic: localRoute)
        harness.openRoute()
        let ticket = try harness.enqueue(.prepare, policy: .routeSpeculativeRateZero)
        XCTAssertTrue(harness.run(ticket))
        harness.ingressRouteChange(semantic: localRoute)
        XCTAssertTrue(harness.registry.complete(ticket))
        XCTAssertFalse(harness.registry.claimCompletedResult(ticket))
        harness.openRoute()
        XCTAssertTrue(harness.registry.claimCompletedResult(ticket))
        XCTAssertFalse(harness.registry.claimCompletedResult(ticket))
    }

    func testCompletedResultCannotCommitAfterSystemChangeOrGroupSeal() throws {
        for reset in [false, true] {
            let harness = try ControlCommandTestHarness()
            harness.openRoute()
            let ticket = try harness.enqueue(.prepare, policy: .routeSpeculativeRateZero)
            XCTAssertTrue(harness.run(ticket))
            XCTAssertTrue(harness.registry.complete(ticket))
            if reset {
                harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            } else {
                XCTAssertTrue(harness.registry.seal(harness.group))
            }
            XCTAssertFalse(harness.registry.claimCompletedResult(ticket))
        }
    }

    func testConcurrentRunnersProduceOneExternalCall() throws {
        let harness = try ControlCommandTestHarness()
        let registry = harness.registry
        let ticket = try harness.enqueue(.suspend, policy: .safetyBypass)
        let calls = ExternalControlCallSpy()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if registry.claimStart(ticket) { calls.invoke(onControlExecutor: registry.executor.isIsolated) }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls.calledOnControlExecutor)
    }

    func testCallbackRevokesWhileAsyncDrainCannotRun() throws {
        let harness = try ControlCommandTestHarness()
        harness.openRoute()
        let ticket = try harness.enqueue(.activation, policy: .activationRequiresOpen)
        harness.registry.executor.sync {
            harness.ingressRouteChange()
            XCTAssertFalse(harness.registry.claimStart(ticket))
        }
        XCTAssertEqual(harness.registry.phase(of: ticket), .terminal(.canceled))
    }

    func testSafetyReserveBeginsAfterEightSlotsAndFixedStorageFitsControlBudget() throws {
        let registry = ControlTaskRegistry()
        for index in 0..<9 {
            let group = try registry.createGroup(resource: .context(session: testSession, nonce: UInt64(index)))
            _ = try registry.enqueue(group: group, slot: .suspend, policy: .safetyBypass)
            XCTAssertEqual(registry.occupancy.safetyReserveInUse, index >= 8)
        }
        XCTAssertEqual(registry.occupancy.safetySlots, 9)
        XCTAssertEqual(registry.occupancy.ordinarySlots, 0)
        XCTAssertEqual(registry.occupancy.groups, 9)
        XCTAssertLessThanOrEqual(MemoryLayout<OwnedPostIngressControlCommand>.stride, 2_048)
        XCTAssertLessThanOrEqual(ControlTaskRegistry.controlAllocationReservation.total, 64 * 1_024)
        let fixedOwnedControlBytes = ControlTaskRegistry.fixedValueStorageBytes +
            PlaybackDeadlineScheduler.fixedValueStorageBytes
        let conservativePreparationPeak = fixedOwnedControlBytes +
            max(ControlTaskRegistry.boundedResourceTransitionPreparationValueBytes +
                    PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
                    ControlTaskRegistry.groupTicketProjectionPreparationValueBytes,
                ControlTaskRegistry.boundedPlaybackBudgetPreparationValueBytes +
                    PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
                    ControlTaskRegistry.groupTicketProjectionPreparationValueBytes,
                ControlTaskRegistry.boundedCommandPreparationValueBytes +
                    ControlTaskRegistry.groupTicketProjectionPreparationValueBytes) +
            MemoryLayout<OutputResourceOwnershipSnapshot>.stride
        // 以下value-stride式只保留历史ABI诊断，不能充作allocation或真实线程栈上界。
        let attachment = XCTAttachment(string: """
        唯一实际allocation预留=\(ControlTaskRegistry.controlAllocationReservation)
        以下为非cap源码stride诊断；不等同实际临时栈。
        单record步长=\(MemoryLayout<OwnedPostIngressControlCommand>.stride)
        普通池固定值=\(ControlTaskRegistry.ordinaryPoolValueBytes)
        安全池固定值=\(ControlTaskRegistry.safetyPoolValueBytes)
        group固定值=\(ControlTaskRegistry.groupValueBytes)
        压缩Group单槽值=\(ControlTaskRegistry.groupValueBytes / 32)
        Group计算票投影临时值=\(ControlTaskRegistry.groupTicketProjectionPreparationValueBytes)
        authority快照固定值=\(ControlTaskRegistry.authoritySnapshotValueBytes)
        唯一清理预留=\(MemoryLayout<CleanupReservation?>.stride)
        唯一真实资源state=\(MemoryLayout<OutputResourceState?>.stride)
        state内纯metadata=\(MemoryLayout<OutputResourceContext>.stride)
        acquisition配置值=\(MemoryLayout<OutputConfiguredAcquisition>.stride)
        acquisition期限=\(MemoryLayout<AudioSessionAcquisitionDeadline?>.stride)
        acquisition无租约证明=\(MemoryLayout<OutputAcquisitionNoLeaseReceipt?>.stride)
        稳定sample claim=\(MemoryLayout<OutputRouteSampleClaim?>.stride)
        稳定candidate=\(MemoryLayout<OutputRouteStabilityCandidate?>.stride)
        retained rebase值=\(MemoryLayout<OutputRetainedRebaseResult?>.stride)
        唯一route状态=\(MemoryLayout<RouteObservationState?>.stride)
        唯一reset有效state=\(MemoryLayout<ResetPreRouteRecoveryDeadlineState?>.stride)
        唯一post-config有效state=\(MemoryLayout<PostConfigurationRouteState?>.stride)
        登记post-config证明=\(MemoryLayout<ResetPostConfigurationProof?>.stride)
        retained reset binding=\(MemoryLayout<SystemRecoveryLeaseBinding>.stride)
        reset准入binding=\(MemoryLayout<OutputResetAcquisitionBinding?>.stride)
        当前及空drain来源root=\(2 * MemoryLayout<MediaServicesResetRootIdentity?>.stride)
        checked配置generation独立域=8
        权威current generation独立值=8
        单record互斥载荷=\(MemoryLayout<OwnedControlCommandPayload?>.stride)
        八项预留槽描述=\(8 * MemoryLayout<ReservedCleanupSlot>.stride)
        组合CAS标志及保守对齐=8
        固定值总和=\(ControlTaskRegistry.fixedValueStorageBytes)
        单次有界命令准备临时值=\(ControlTaskRegistry.boundedCommandPreparationValueBytes)
        多命令及资源交接准备峰=\(ControlTaskRegistry.boundedResourceTransitionPreparationValueBytes)
        八类预算交付嵌套准备峰=\(ControlTaskRegistry.boundedPlaybackBudgetPreparationValueBytes)
        共享reactivation嵌套准备峰=\(ControlTaskRegistry.boundedReactivationPreparationValueBytes)
        用户控制嵌套准备峰=\(ControlTaskRegistry.boundedUserControlPreparationValueBytes)
        普通drain proof嵌套准备峰=\(ControlTaskRegistry.boundedInterruptionDrainPreparationValueBytes)
        准确route sample嵌套准备峰=\(ControlTaskRegistry.boundedRouteSamplePreparationValueBytes)
        单次sampler替换callee准备峰=\(ControlTaskRegistry.boundedRouteSamplerReplacementPreparationValueBytes)
        pending通知后继sampler嵌套准备峰=\(ControlTaskRegistry.boundedPendingRouteResamplePreparationValueBytes)
        准确suspend控制嵌套准备峰=\(ControlTaskRegistry.boundedSuspendControlPreparationValueBytes)
        已open普通route观察嵌套准备峰=\(ControlTaskRegistry.boundedOpenRouteObservationPreparationValueBytes)
        普通输出转换嵌套准备峰=\(ControlTaskRegistry.boundedOutputTransitionPreparationValueBytes)
        AirPlay默认策略终态嵌套准备峰=\(ControlTaskRegistry.boundedClosedAirPlayPolicyTerminalPreparationValueBytes)
        唯一route fact值=\(MemoryLayout<OutputAuthoritativeRoute>.stride)
        完整AudioSession phase值=\(MemoryLayout<RegisteredAudioSessionPhase>.stride)
        唯一reactivation state值=\(MemoryLayout<AudioSessionReactivationBudgetState?>.stride)
        普通drain proof参数值=\(MemoryLayout<InterruptionDrainProof?>.stride)
        三个Cell初始化hook及固定捕获=\(PlaybackControlExecutor.ingressHookValueBytes)
        用户请求值=\(MemoryLayout<OutputUserControlRequest>.stride)
        六分支闭合控制请求值=\(MemoryLayout<OutputControlRequest>.stride)
        闭合控制返回值=\(MemoryLayout<OutputControlApplication>.stride)
        八类预算动作值=\(MemoryLayout<PlaybackBudgetControlAction>.stride)
        封闭预算结果值=\(MemoryLayout<PlaybackBudgetControlResult>.stride)
        八槽单source scheduler固定值=\(PlaybackDeadlineScheduler.fixedValueStorageBytes)
        scheduler单次投递临时值=\(PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes)
        含scheduler固定控制值=\(fixedOwnedControlBytes)
        suspend动作值=\(MemoryLayout<OutputSuspendControlAction>.stride)
        suspend结果值=\(MemoryLayout<OutputSuspendControlResult>.stride)
        无SDK只读资源快照=\(MemoryLayout<OutputResourceOwnershipSnapshot>.stride)
        固定值加真实多准备及快照保守峰值=\(conservativePreparationPeak)
        Task3单shadow步长=\(MemoryLayout<PlaybackSafetySnapshot>.stride)
        """)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class ExternalControlCallSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private var storedOnExecutor = false
    var count: Int { lock.withLock { storedCount } }
    var calledOnControlExecutor: Bool { lock.withLock { storedOnExecutor } }
    func invoke(onControlExecutor: Bool) {
        lock.withLock { storedCount += 1; storedOnExecutor = storedOnExecutor || onControlExecutor }
    }
}

struct AudioPhaseFixture {
    let allocator: PlaybackIdentityAllocator
    let activationInvocationIdentity: AudioSessionActivationInvocationIdentity
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let reservation: CleanupReservation?
    private let initialGroup: ControlTaskGroupTicket
    var group: ControlTaskGroupTicket { registry.cleanupReservationSnapshot()?.ticket.workGroup ?? initialGroup }
    let acquisition: ControlTaskTicket
    let ownershipNonce: UInt64
    let otherNonce: UInt64
    let phase: RegisteredAudioSessionPhase
    let otherIdentity: AudioSessionPhaseIdentity

    func resetActivationPhase(postConfiguration: Bool) throws -> RegisteredAudioSessionPhase {
        var value = try resetPhase()
        let invocation = try AudioSessionActivationInvocationIdentity(allocator: allocator)
        let incarnation = try XCTUnwrap(value.incarnation)
        let snapshot = registry.executor.safetyIngress.snapshot
        let inactive = InactiveAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: snapshot.mediaServicesEpoch,
            attemptNonce: value.configurationAttempt.nonce, receiptNonce: try allocator.next(in: .nonce)),
            actualPolicy: .longFormAudio, preferredFailureReason: nil, planDigest: .preferredLongFormThenDefault,
            attemptLineage: value.configurationAttempt, multichannelCapability: true)
        value.inactiveReceipt = inactive
        value.configurationProgress = .complete(actualPolicy: .longFormAudio, preferredFailure: nil, multichannel: true)
        var purpose = AudioSessionActivationPurpose.commitResetConfiguration(incarnation: incarnation.identity,
            baseGeneration: 0, receiptIdentity: inactive.identity)
        if postConfiguration {
            let stage = try allocator.next(in: .deadline)
            let budget = AudioSessionReactivationBudgetTicket(identity: .init(sessionIdentity: value.identity.sessionIdentity,
                recoveryLineageIdentity: try allocator.next(in: .nonce), budgetNonce: try allocator.next(in: .deadline)),
                committedGeneration: 1, parentOperationTicketIdentity: value.parent, postConfigurationStageIdentity: stage,
                mandatorySuffix: 3_000_000_000, activationCutoffEffectiveElapsed: 37_000_000_000)
            let proof = AudioSessionReactivationProof.resetPostConfiguration(.init(incarnationIdentity: incarnation.identity,
                resetDrainProofIdentity: incarnation.drainProof.identity, retainedContextNonce: value.identity.contextNonce,
                leaseID: value.identity.leaseID, committedGeneration: 1, postConfigurationStageIdentity: stage,
                proofNonce: try allocator.next(in: .nonce)))
            let process = ProcessAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: snapshot.mediaServicesEpoch,
                configurationGeneration: 1, receiptNonce: try allocator.next(in: .nonce)), actualPolicy: .longFormAudio,
                preferredFailureReason: nil, multichannelCapability: true, planDigest: .preferredLongFormThenDefault,
                attemptLineage: value.configurationAttempt)
            value.processReceipt = process
            value.configuredReceipt = .init(leaseID: value.identity.leaseID, processConfigurationReceiptIdentity: process.identity)
            value.reactivationState = .init(ticket: budget, basePhase: .awaitingActivation, freezeCauses: [], cutoffArmTicket: nil)
            value.currentReactivationProof = proof
            purpose = .reactivateConfiguredGeneration(sessionIdentity: value.identity.sessionIdentity,
                configurationTransitionIdentity: .reset(incarnation.identity), committedGeneration: 1,
                reactivationAttempt: .init(reactivationBudgetIdentity: budget.identity, reactivationProof: proof,
                    interruptionEpoch: snapshot.interruptionEpoch, retainedContextNonce: value.identity.contextNonce,
                    attemptNonce: invocation))
        }
        value.policy = .activate(purpose: purpose, interruptionEpoch: snapshot.interruptionEpoch,
            audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision, invocationIdentity: invocation)
        return value
    }

    func reactivationPhase(proofEpoch: UInt64) throws -> RegisteredAudioSessionPhase {
        let registered = registry.registeredOutputDrainProof()
        let actual: InterruptionDrainProof
        if case .interruption(let proof) = registered { actual = proof }
        else if case .interruption(let proof) = try prepareRetainedDrain(kind: .interruption) { actual = proof }
        else { throw ControlTaskRegistry.Failure.invalidGroup }
        XCTAssertEqual(actual.interruptionEpoch, proofEpoch)
        let original = activationPhase
        var value = RegisteredAudioSessionPhase(identity: .init(owner: group.ownerTicket,
            sessionIdentity: original.identity.sessionIdentity, leaseID: original.identity.leaseID,
            contextNonce: actual.contextNonce, mediaServicesEpoch: original.identity.mediaServicesEpoch,
            phaseNonce: original.identity.phaseNonce), policy: original.policy,
            configurationAttempt: original.configurationAttempt, parent: original.parent,
            resetBinding: original.resetBinding, incarnation: original.incarnation,
            reactivationState: original.reactivationState, configurationProgress: original.configurationProgress,
            permitsFurtherCalls: original.permitsFurtherCalls, acquisitionOwnershipProof: original.acquisitionOwnershipProof,
            processReceipt: original.processReceipt, configuredReceipt: original.configuredReceipt, inactiveReceipt: original.inactiveReceipt)
        let invocation = try AudioSessionActivationInvocationIdentity(allocator: allocator)
        let budget = AudioSessionReactivationBudgetTicket(identity: .init(sessionIdentity: phase.identity.sessionIdentity,
            recoveryLineageIdentity: try allocator.next(in: .nonce), budgetNonce: try allocator.next(in: .deadline)),
            committedGeneration: 0, parentOperationTicketIdentity: phase.parent, postConfigurationStageIdentity: nil,
            mandatorySuffix: 3_000_000_000, activationCutoffEffectiveElapsed: 37_000_000_000)
        let proof = AudioSessionReactivationProof.interruption(actual)
        value.reactivationState = .init(ticket: budget, basePhase: .awaitingActivation, freezeCauses: [], cutoffArmTicket: nil)
        value.currentReactivationProof = proof
        value.policy = .activate(purpose: .reactivateConfiguredGeneration(sessionIdentity: phase.identity.sessionIdentity,
            configurationTransitionIdentity: nil, committedGeneration: 0,
            reactivationAttempt: .init(reactivationBudgetIdentity: budget.identity, reactivationProof: proof,
                interruptionEpoch: 2, retainedContextNonce: phase.identity.contextNonce,
                attemptNonce: invocation)), interruptionEpoch: 2, audioAdmissionFenceRevision: 2, invocationIdentity: invocation)
        return value
    }

    // 这里只登记明确的纯值；不声称测试真实资源drain或证明签发。
    func resetPhase() throws -> RegisteredAudioSessionPhase {
        let value = try unregisteredResetPhase()
        guard case .reset(let proof) = try prepareRetainedDrain(kind: .reset) else { throw ControlTaskRegistry.Failure.invalidGroup }
        let old = try XCTUnwrap(value.incarnation)
        let incarnation = SystemRecoveryIncarnation(identity: .init(root: proof.identity.root,
            incarnationNonce: try allocator.next(in: .nonce), sessionIdentity: value.identity.sessionIdentity),
            drainProof: proof, baseConfigurationGeneration: old.baseConfigurationGeneration,
            configurationPlan: old.configurationPlan, outerDeadlineTicket: old.outerDeadlineTicket,
            resetPreRouteDeadlineTicket: old.resetPreRouteDeadlineTicket,
            inheritedRouteAvailabilityConstraint: old.inheritedRouteAvailabilityConstraint)
        return RegisteredAudioSessionPhase(identity: .init(owner: group.ownerTicket,
            sessionIdentity: value.identity.sessionIdentity, leaseID: value.identity.leaseID,
            contextNonce: value.identity.contextNonce, mediaServicesEpoch: value.identity.mediaServicesEpoch,
            phaseNonce: value.identity.phaseNonce), policy: .configureInactive(incarnation: incarnation.identity,
                resetDrainProof: proof.identity, configurationAttemptNonce: value.configurationAttempt.nonce,
                step: .longFormCategoryAttempt), configurationAttempt: value.configurationAttempt,
            parent: value.parent, resetBinding: value.resetBinding, incarnation: incarnation, reactivationState: nil,
            configurationProgress: value.configurationProgress, permitsFurtherCalls: true,
            acquisitionOwnershipProof: nil, processReceipt: nil, configuredReceipt: nil, inactiveReceipt: nil)
    }

    func prepareRetainedDrain(kind: OutputDrainKind) throws -> OutputRegisteredDrainProof {
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .recovery, at: 1,
            teardown: kind == .reset))
        let proof = try XCTUnwrap(registry.issueOutputDrainProof(owner: owner, kind: kind))
        if registry.phase(of: acquisition) != nil { XCTAssertTrue(registry.retire(acquisition)) }
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        if registry.phase(of: ownerTask) == .queued { XCTAssertTrue(registry.claimStart(ownerTask)) }
        if registry.phase(of: ownerTask) == .running { XCTAssertTrue(registry.complete(ownerTask)) }
        XCTAssertTrue(registry.retire(ownerTask))
        XCTAssertNotNil(try registry.renewOutputCycle(contextNonce: context.contextNonce))
        return proof
    }

    func unregisteredResetPhase() throws -> RegisteredAudioSessionPhase {
        var snapshot = PlaybackSafetySnapshot()
        registry.executor.sync {
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            snapshot = registry.executor.safetyIngress.snapshot
        }
        let ingress = try XCTUnwrap(snapshot.system.latestResetIngress)
        let root = MediaServicesResetRootIdentity(resetTicket: ingress.rootIdentity, mediaServicesEpoch: ingress.mediaServicesEpoch)
        let proof = ResetDrainProof(identity: .init(root: root, proofNonce: try allocator.next(in: .nonce)),
            parentProofNonce: nil, drainedSessionIdentity: phase.identity.sessionIdentity,
            resultingResourceShape: .noResources, currentConfigurationGeneration: 0)
        let preRoute = ResetPreRouteRecoveryDeadlineTicket(identity: .init(lineageIdentity: try allocator.next(in: .nonce),
            sessionIdentity: phase.identity.sessionIdentity, parentOperationTicketIdentity: phase.parent,
            nonce: try allocator.next(in: .deadline)))
        let incarnation = SystemRecoveryIncarnation(identity: .init(root: root,
            incarnationNonce: try allocator.next(in: .nonce), sessionIdentity: phase.identity.sessionIdentity),
            drainProof: proof, baseConfigurationGeneration: 0, configurationPlan: .preferredLongFormThenDefault,
            outerDeadlineTicket: phase.parent, resetPreRouteDeadlineTicket: preRoute,
            inheritedRouteAvailabilityConstraint: nil)
        let identity = AudioSessionPhaseIdentity(owner: group.ownerTicket, sessionIdentity: phase.identity.sessionIdentity,
            leaseID: phase.identity.leaseID, contextNonce: phase.identity.contextNonce,
            mediaServicesEpoch: root.mediaServicesEpoch, phaseNonce: try allocator.next(in: .nonce))
        let attempt = AudioSessionConfigurationAttempt(nonce: try allocator.next(in: .nonce),
            plan: .preferredLongFormThenDefault, mediaServicesEpoch: root.mediaServicesEpoch)
        return RegisteredAudioSessionPhase(identity: identity, policy: .configureInactive(incarnation: incarnation.identity,
            resetDrainProof: proof.identity, configurationAttemptNonce: attempt.nonce, step: .longFormCategoryAttempt),
            configurationAttempt: attempt, parent: phase.parent,
            resetBinding: .init(rootIdentity: root, ticketIdentity: preRoute.identity, bindingNonce: try allocator.next(in: .nonce)),
            incarnation: incarnation, reactivationState: nil, configurationProgress: .awaitingLongForm,
            permitsFurtherCalls: true, acquisitionOwnershipProof: nil, processReceipt: nil, configuredReceipt: nil, inactiveReceipt: nil)
    }

    var activationPhase: RegisteredAudioSessionPhase {
        var value = phase
        value.policy = .activate(purpose: .activateAcquiredConfiguredGeneration(
            sessionIdentity: phase.identity.sessionIdentity, committedGeneration: 0,
            acquisitionOwnershipProof: .init(acquisitionTicket: acquisition,
                sessionIdentity: phase.identity.sessionIdentity, leaseID: phase.identity.leaseID,
                contextNonce: phase.identity.contextNonce, ownershipNonce: ownershipNonce)),
            interruptionEpoch: 0, audioAdmissionFenceRevision: 0, invocationIdentity: activationInvocationIdentity)
        value.configurationProgress = .complete(actualPolicy: .longFormAudio, preferredFailure: nil, multichannel: true)
        let receipt = ProcessAudioSessionConfigurationReceipt(identity: .init(mediaServicesEpoch: 0,
            configurationGeneration: 0, receiptNonce: otherNonce), actualPolicy: .longFormAudio,
            preferredFailureReason: nil, multichannelCapability: true,
            planDigest: .preferredLongFormThenDefault, attemptLineage: phase.configurationAttempt)
        value.processReceipt = receipt
        value.configuredReceipt = .init(leaseID: phase.identity.leaseID, processConfigurationReceiptIdentity: receipt.identity)
        return value
    }

    init(ownsResources: Bool = true) throws {
        allocator = PlaybackIdentityAllocator()
        activationInvocationIdentity = try AudioSessionActivationInvocationIdentity(allocator: allocator)
        registry = ControlTaskRegistry(allocator: allocator)
        lane = try bindGraphAudioSessionLane(registry)
        let session = PlaybackSessionIdentity(sessionID: try allocator.next(in: .session), requestID: UUID())
        let parentIdentity = PlaybackProgressBudgetTicket.Identity(sessionIdentity: session, nonce: try allocator.next(in: .deadline))
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: parentIdentity, kind: .coldStart,
            originInstant: 0, cap: 40_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        if ownsResources {
            acquisition = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
            reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
            initialGroup = acquisition.group
        } else {
            reservation = nil
            initialGroup = try registry.createGroup(resource: .session(session))
            acquisition = try registry.enqueue(group: initialGroup, slot: .acquire, policy: .routeNeutral)
        }
        let group = initialGroup
        ownershipNonce = try allocator.next(in: .nonce)
        otherNonce = try allocator.next(in: .nonce)
        let identity = AudioSessionPhaseIdentity(owner: group.ownerTicket, sessionIdentity: session,
            leaseID: try allocator.next(in: .lease), contextNonce: try reservation?.contextNonce ?? allocator.next(in: .nonce),
            mediaServicesEpoch: 0, phaseNonce: try allocator.next(in: .nonce))
        otherIdentity = AudioSessionPhaseIdentity(owner: ControlTaskOwnerTicket(
            resourceIdentity: group.resourceIdentity, nonce: try allocator.next(in: .nonce)),
            sessionIdentity: session, leaseID: identity.leaseID, contextNonce: identity.contextNonce,
            mediaServicesEpoch: 0, phaseNonce: identity.phaseNonce)
        let attempt = AudioSessionConfigurationAttempt(nonce: try allocator.next(in: .nonce),
            plan: .preferredLongFormThenDefault, mediaServicesEpoch: 0)
        phase = RegisteredAudioSessionPhase(identity: identity,
            policy: .configureAcquisition(acquisitionTicket: acquisition, ownershipNonce: ownershipNonce,
                configurationAttemptNonce: attempt.nonce, step: .longFormCategoryAttempt),
            configurationAttempt: attempt, parent: parentIdentity,
            resetBinding: nil, incarnation: nil, reactivationState: nil,
            configurationProgress: .awaitingLongForm, permitsFurtherCalls: true,
            acquisitionOwnershipProof: .init(acquisitionTicket: acquisition, sessionIdentity: session,
                leaseID: identity.leaseID, contextNonce: identity.contextNonce, ownershipNonce: ownershipNonce),
            processReceipt: nil, configuredReceipt: nil, inactiveReceipt: nil)
        if let reservation {
            let proof = try XCTUnwrap(phase.acquisitionOwnershipProof)
            XCTAssertTrue(registry.claimStart(acquisition))
            XCTAssertTrue(registry.completeWithOwnedResult(acquisition, ownership: .init(
                reservation: reservation.ticket, contextNonce: reservation.contextNonce, mediaServicesEpoch: 0,
                interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
                payload: .lease(.init(leaseID: identity.leaseID, object: AudioOwnedResourceSpy(),
                    monitor: .init(sessionIdentity: session, lifecycle: 1, object: AudioOwnedResourceSpy()),
                    deactivation: .confirmedInactive(.reservation(proof)))))))
            XCTAssertTrue(try registry.settleOutputAcquisition(acquisition))
        }
    }

    func retire(_ ticket: ControlTaskTicket) -> Bool {
        if registry.activationOutcome(of: ticket) != nil {
            guard registry.transferActivationDisposition(ticket) else { return false }
        }
        return registry.retire(ticket)
    }
}

private final class AudioOwnedResourceSpy: OwnedPlaybackResource {}

private let testSession = PlaybackSessionIdentity(sessionID: 42, requestID: UUID())
private let localRoute = PlaybackRouteSemanticIdentity(ports: .hdmi, backend: .sampleBuffer,
    outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 1),
    endpointTopologyToken: EndpointTopologyToken(rawValue: 1))
private let airPlayRoute = PlaybackRouteSemanticIdentity(ports: .airPlay, backend: .hlsAVPlayer,
    outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 2),
    endpointTopologyToken: EndpointTopologyToken(rawValue: 2))

private func beginManagedAcquisition(_ registry: ControlTaskRegistry) throws -> ControlTaskTicket {
    let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
        identity: .init(sessionIdentity: testSession, nonce: 1), kind: .coldStart,
        originInstant: 0, cap: 15_000_000_000, accumulatedEffectiveTime: 0,
        runningSince: nil, freezeGeneration: 0
    ))
    return try XCTUnwrap(registry.beginOutputAcquisition(
        session: testSession, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000
    ))
}

private final class ControlCommandTestHarness {
    let registry = ControlTaskRegistry()
    let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
    let group: ControlTaskGroupTicket
    var calls = 0

    init() throws {
        group = try registry.createGroup(resource: .session(session))
    }

    func enqueue(_ slot: ControlTaskSlot, policy: ControlGatePolicy) throws -> ControlTaskTicket {
        try registry.enqueue(group: group, slot: slot, policy: policy)
    }

    func ingressRouteChange(semantic: PlaybackRouteSemanticIdentity? = nil, topologyHint: Bool = false) {
        registry.executor.safetyIngress.beginRouteObservation(PlaybackRouteIngress(
            sessionIdentity: session, monitorLifecycle: 1, notificationRevision: 1,
            reasonBits: 1, topologyChangeHint: topologyHint, outputConfigurationChanged: false,
            observedRoute: semantic
        ))
    }

    func openRoute() {
        registry.executor.sync {
            while true {
                let result = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) {
                    $0.routeObservationGateOpen = true
                }
                if case .retry = result { continue }
                break
            }
        }
    }

    func run(_ ticket: ControlTaskTicket) -> Bool {
        guard registry.claimStart(ticket) else { return false }
        calls += 1
        return true
    }
}
