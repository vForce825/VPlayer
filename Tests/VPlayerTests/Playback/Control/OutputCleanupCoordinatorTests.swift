// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import Security
import XCTest
@testable import VPlayerPlayback

final class OutputCleanupCoordinatorTests: XCTestCase {
    func testRawAvailableEmptyOrUnknownPortsFailsClosedAndSettlesOnlyOriginalCall() throws {
        for invalidPorts in [PlaybackRoutePorts(), PlaybackRoutePorts(rawValue: 128)] {
            let fixture = try AcquiringOutputFixture()
            _ = try fixture.configureAndActivate()
            let registry = fixture.registry
            let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
            guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("真实handoff失败") }
            let call = try claimGraphRoute(registry, lane: fixture.lane,
                observation: try XCTUnwrap(handoff.routeObservation), source: try XCTUnwrap(handoff.sampler))
            let registration = try XCTUnwrap(call.request.registration)
            guard case .available(_, let fingerprint) = AudioSessionBlockingCallLane.project(
                GraphRouteSnapshot.builtIn, salt: registration.salt) else { return XCTFail("真实SDK端点投影必须有效") }
            let result = AudioSessionBlockingCallResult.route(.available(ports: invalidPorts, endpointFingerprint: fingerprint))
            let completion = try completeGraphAudioCall(registry, lane: fixture.lane, call.request, result)
            XCTAssertEqual(completion.disposition, .failed)
            XCTAssertEqual(completion.failure, .invalidEvidence)
            XCTAssertNil(completion.followUp)
            XCTAssertEqual(registry.phase(of: call.source), .terminal(.canceled))
            XCTAssertFalse(testRouteGate(registry: registry))
            XCTAssertThrowsError(try registry.armOutputRouteStability(observation: call.observation),
                "sticky failure拒绝后续普通准入，不存在可稳定提交的候选")
            XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: call.request.permit,
                result: result), lane: fixture.lane)), .rejected, "畸形返回已结清，不能复用原permit补发事实")
        }
    }

    func testRawMixedPortsChooseHLSAndAirPlayDefaultPolicyInstallsTerminalCleanup() throws {
        let longForm = try AcquiringOutputFixture()
        let activation = try longForm.configureAndActivate()
        let registry = longForm.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("long-form真实handoff失败")
        }
        let claim = try claimGraphRoute(registry, lane: longForm.lane,
            observation: try XCTUnwrap(handoff.routeObservation), source: try XCTUnwrap(handoff.sampler))
        let mixed = GraphRouteSnapshot.ports([.hdmi, .airPlay])
        XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: mixed).disposition, .accepted)
        let accepted = try XCTUnwrap(registry.armOutputRouteStability(observation: claim.observation))
        XCTAssertEqual(accepted.authority.semanticIdentity?.ports, [.hdmi, .airPlay])
        XCTAssertEqual(accepted.authority.semanticIdentity?.backend, .hlsAVPlayer,
            "raw结果不能附带caller backend，含AirPlay只能由Authority选择HLS")
        XCTAssertNil(registry.phase(of: activation))

        let fallback = try AcquiringOutputFixture()
        let fallbackActivation = try fallback.configureAndActivate(actualPolicy: .default)
        let fallbackRegistry = fallback.registry
        let fallbackToken = try XCTUnwrap(fallbackRegistry.outputAcquisitionCommitSnapshot())
        guard case .committed(let fallbackHandoff) = try fallbackRegistry.commitAcquisitionRelayAndContext(fallbackToken) else {
            return XCTFail("default真实handoff失败")
        }
        XCTAssertEqual(fallbackRegistry.processAudioSessionReceiptSnapshot()?.actualPolicy, .default)
        let fallbackClaim = try claimGraphRoute(fallbackRegistry, lane: fallback.lane,
            observation: try XCTUnwrap(fallbackHandoff.routeObservation), source: try XCTUnwrap(fallbackHandoff.sampler))
        XCTAssertEqual(try completeGraphRoute(fallbackRegistry, fallbackClaim, snapshot: mixed).disposition, .accepted)
        XCTAssertFalse(fallbackRegistry.executor.safetyIngress.snapshot.routeObservationGateOpen,
            "unsupported AirPlay必须闭门完成稳定确认，不能临时开放backend准入")
        let stability = try XCTUnwrap(fallbackRegistry.armOutputRouteStability(observation: fallbackClaim.observation))
        fallback.clock.set(stability.deadlineInstant)
        XCTAssertThrowsError(try fallbackRegistry.commitOutputRouteStability(stability)) { error in
            XCTAssertEqual(error as? PlaybackBackendSelectionError, .airPlayLongFormUnavailable)
        }
        let terminal = try XCTUnwrap(fallbackRegistry.outputResourceContextSnapshot())
        XCTAssertTrue(terminal.poisoned)
        XCTAssertEqual(terminal.disposition, .releaseAfterTeardown)
        XCTAssertEqual(terminal.owner?.reason, .terminal)
        XCTAssertTrue(terminal.relayClosing)
        XCTAssertTrue(terminal.teardownRequested)
        XCTAssertTrue(try XCTUnwrap(fallbackRegistry.cleanupReservationSnapshot()).terminal)
        XCTAssertNotNil(terminal.owner.flatMap(fallbackRegistry.outputCleanupOwnerTask))
        XCTAssertFalse(fallbackRegistry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertFalse(fallbackRegistry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        let reservation = try XCTUnwrap(fallbackRegistry.cleanupReservationSnapshot())
        let owner = try XCTUnwrap(terminal.owner)
        let coordinator = OutputCleanupCoordinator(registry: fallbackRegistry)
        let monitorStop = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(fallbackRegistry.claimStart(monitorStop))
        XCTAssertTrue(coordinator.completeMonitorStop(monitorStop, lifecycle: try graphMonitorLifecycle(fallbackRegistry)))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try graphAudioCall(fallbackRegistry, lane: fallback.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var releaseRunner = fallbackRegistry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(releaseRunner)
        releaseRunner = nil
        XCTAssertTrue(fallbackRegistry.complete(release))
        XCTAssertNil(fallbackRegistry.phase(of: fallbackActivation),
            "lease清理推进已在准确terminal+责任转移后退休唯一audio record")
        XCTAssertEqual(try fallbackRegistry.retireOutputControlRecord(fallbackClaim.source), .retired(followUp: nil))
        XCTAssertTrue(fallbackRegistry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(fallbackRegistry.releaseCleanupReservation(reservation.ticket))
        XCTAssertNil(fallbackRegistry.ownedResourceSnapshot())
        XCTAssertNil(fallbackRegistry.cleanupReservationSnapshot())
        XCTAssertEqual(fallbackRegistry.occupancy.groups, 0)
        XCTAssertEqual(fallbackRegistry.occupancy.safetySlots, 0)
    }

    func testOpenRouteNotificationCreatesOneSamplerAndTypedSemanticControlsWakeCancelAndEarliestWindow() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let speculativePrepare = try XCTUnwrap(context.sourceTask)
        guard case .open(let firstOpen) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("fixture必须从已稳定open route开始")
        }
        let firstInstant = clock.read() + 10
        clock.set(firstInstant)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
            monitorLifecycle: firstOpen.monitorLifecycle, notificationRevision: firstOpen.routeObservationRevision + 1,
            reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
            observedRoute: firstOpen.semanticIdentity))
        guard case .pending(let firstPending) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("open后的新通知必须原子建立pending、唯一sampler和D")
        }
        let firstObservation = try XCTUnwrap(firstPending.ticket)
        let firstSampler = try XCTUnwrap(firstPending.sampler)
        XCTAssertEqual(firstPending.deadline?.identity.deadlineAnchorInstant, firstInstant)
        XCTAssertEqual(firstPending.deadline?.deadlineInstant, firstInstant + 3_000_000_000)
        let sameClaim = try claimGraphRoute(registry, lane: fixture.lane, observation: firstObservation, source: firstSampler)
        let sameSemanticInstant = firstInstant + 10
        clock.set(sameSemanticInstant)
        XCTAssertEqual(try completeGraphRoute(registry, sameClaim, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        XCTAssertTrue(registry.claimStart(speculativePrepare),
            "相同typed semantic重新开gate后必须唤醒原parked speculative工作")
        let firstArm = try XCTUnwrap(registry.armOutputRouteStability(observation: firstObservation))
        XCTAssertEqual(firstArm.anchorInstant, sameSemanticInstant, "稳定窗必须从首个匹配typed getter事实开始")
        clock.set(firstArm.deadlineInstant - 1)
        XCTAssertNil(try registry.commitOutputRouteStability(firstArm))
        clock.set(firstArm.deadlineInstant)
        _ = try XCTUnwrap(registry.commitOutputRouteStability(firstArm))

        guard case .open(let secondOpen) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("同semantic稳定后必须重新open")
        }
        clock.set(firstArm.deadlineInstant + 10)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
            monitorLifecycle: secondOpen.monitorLifecycle, notificationRevision: secondOpen.routeObservationRevision + 1,
            reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: true,
            observedRoute: nil))
        guard case .pending(let secondPending) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("第二次open通知也必须取得新且唯一的sampler")
        }
        let changedClaim = try claimGraphRoute(registry, lane: fixture.lane, observation: try XCTUnwrap(secondPending.ticket),
            source: try XCTUnwrap(secondPending.sampler))
        clock.set(firstArm.deadlineInstant + 20)
        XCTAssertEqual(try completeGraphRoute(registry, changedClaim, snapshot: GraphRouteSnapshot.ports(.airPlay)).disposition, .accepted)
        XCTAssertEqual(registry.phase(of: speculativePrepare), .cancelRequested,
            "只有不同的typed getter semantic才能取消原running speculative工作")
    }

    func testOpenRouteCoalescedNotificationsKeepFirstCallbackDeadlineAcrossDelayedDrain() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("fixture必须从open route开始")
        }
        let firstInstant = clock.read() + 10
        let secondInstant = firstInstant + 20
        let drainInstant = firstInstant + 2_000_000_000
        registry.executor.sync {
            clock.set(firstInstant)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 1,
                reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
                observedRoute: open.semanticIdentity))
            clock.set(secondInstant)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 2,
                reasonBits: 2, topologyChangeHint: true, outputConfigurationChanged: true,
                observedRoute: open.semanticIdentity))
            clock.set(drainInstant)
        }
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("延迟drain也必须建立一个合并pending")
        }
        XCTAssertEqual(pending.firstEventObservedInstant, firstInstant)
        XCTAssertEqual(pending.deadline?.identity.deadlineAnchorInstant, firstInstant)
        XCTAssertEqual(pending.deadline?.deadlineInstant, firstInstant + 3_000_000_000,
            "D必须从首callback算，不能从延迟drain时刻续杯")
        XCTAssertEqual(pending.latestNotificationRevision, open.routeObservationRevision + 2)
        XCTAssertEqual(pending.reasons.rawValue & 3, 3)
        XCTAssertTrue(pending.topologyChangeHint)
        XCTAssertTrue(pending.outputConfigurationChanged)
        XCTAssertNotNil(pending.ticket)
        XCTAssertNotNil(pending.sampler)
    }

    func testOpenRouteNotificationCoalescedWithSystemBoundaryCannotReuseOldCallbackInstantForDeadline() throws {
        for reset in [false, true] {
            let fixture = try OutputGraphFixture()
            let registry = fixture.registry
            let clock = fixture.stable.acquisition.clock
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("fixture必须从open route开始")
            }
            let firstInstant = clock.read() + 10
            registry.executor.sync {
                clock.set(firstInstant)
                registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 1,
                    reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: true,
                    observedRoute: open.semanticIdentity))
                clock.set(firstInstant + 100)
                registry.executor.safetyIngress.performSyncIngress(reset ? .mediaServicesReset : .interruptionBegan)
            }
            let state = registry.outputRouteObservationSnapshot()
            if case .pending(let pending) = state {
                XCTAssertNil(pending.deadline, "跨system边界不得用边界前callback instant造普通D")
                XCTAssertNil(pending.sampler, "跨system边界必须由对应恢复链重新发行sampler")
            }
            XCTAssertNil(registry.ordinaryRouteDeadlineArmSnapshot())
            XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        }
    }

    func testTypedRouteSemanticChangesAdvanceFenceAndReturningValueCannotRestoreOldAuthority() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let clock = fixture.acquisition.clock
        let initialFence = registry.executor.safetyIngress.snapshot.audioAdmissionFenceRevision
        let semanticA = try XCTUnwrap(fixture.stable.authority.semanticIdentity)

        func publish(_ raw: GraphRouteSnapshot) throws -> StableRouteCommitIdentity? {
            guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            clock.set(clock.read() + 10)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: open.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 1,
                reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
                observedRoute: open.semanticIdentity))
            guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: try XCTUnwrap(pending.ticket),
                source: try XCTUnwrap(pending.sampler))
            XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: raw).disposition, .accepted)
            guard raw.endpointCount > 0 else { return nil }
            let ticket = try XCTUnwrap(registry.armOutputRouteStability(observation: claim.observation))
            clock.set(ticket.deadlineInstant)
            return try XCTUnwrap(registry.commitOutputRouteStability(ticket))
        }

        let sameA = try XCTUnwrap(publish(.builtIn))
        XCTAssertEqual(sameA.authority.semanticIdentity, semanticA)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.audioAdmissionFenceRevision, initialFence,
            "相同typed semantic不得推进fence")
        _ = try XCTUnwrap(publish(.ports(.airPlay)))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.audioAdmissionFenceRevision, initialFence + 1)
        let returnedA = try XCTUnwrap(publish(.builtIn))
        XCTAssertNotEqual(returnedA.authority.semanticIdentity?.endpointTopologyToken, semanticA.endpointTopologyToken,
            "相同原始A回归时须发行新endpoint身份，不能复活旧A")
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.audioAdmissionFenceRevision, initialFence + 2,
            "A→B→A也必须保留两次真实变化，不能凭值相等恢复旧权威")
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNil(try registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: sameA, owner: nil), "旧A票不能在值回到A以后复活")
        XCTAssertNotNil(try registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: returnedA, owner: nil))
        XCTAssertNil(try publish(.init([])))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.audioAdmissionFenceRevision, initialFence + 3,
            "available→none也是typed权威变化")
    }

    func testRoutePauseAndInterruptionCausesRemainIndependentAcrossBothGetterPauseOrders() throws {
        for pauseFirst in [false, true] {
            let fixture = try ResetAcquiringOutputFixture()
            try fixture.configureAndHandoff()
            let previous = try fixture.activateResetAndCommit()
            let registry = fixture.registry
            XCTAssertNil(registry.phase(of: previous), "组合完成已退休此准确原票")
            fixture.clock.set(200)
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.clock.set(300)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let activation = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce, mandatorySuffix: 1_000_000_000))
            let request = try claimGraphAudioCall(registry, lane: fixture.lane, activation)
            fixture.clock.set(400)
            let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
            XCTAssertEqual(completion.disposition, .accepted)
            XCTAssertNil(registry.phase(of: activation))
            guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("getter缺失") }
            let claim = try claimGraphRoute(registry, lane: fixture.lane,
                observation: try XCTUnwrap(pending.ticket), source: try XCTUnwrap(pending.sampler))
            fixture.clock.set(500)
            if pauseFirst { XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .pause)), .acceptedWaiting) }
            XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot([])).disposition, .accepted)
            if !pauseFirst { XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .pause)), .acceptedWaiting) }
            XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses, [.routeUnavailable, .userPause])
            fixture.clock.set(600)
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses, [.routeUnavailable, .userPause, .systemInterruption])
            XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)), .acceptedWaiting)
            XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
            XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses, [.routeUnavailable, .systemInterruption])
            fixture.clock.set(700)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            let next = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce, mandatorySuffix: 1_000_000_000))
            XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses, [.routeUnavailable])
            XCTAssertNil(registry.registeredAudioSessionPhase()?.reactivationState?.cutoffArmTicket)
            _ = try claimGraphAudioCall(registry, lane: fixture.lane, next)
        }
    }

    func testUnknownRouteHintCannotFreezeParentWhenRealUserPauseResumesWithActiveReceipt() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        _ = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        let active = registry.outputResourceContextSnapshot()?.sessionReceipts?.active
        fixture.clock.set(200)
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .pause)), .acceptedWaiting)
        fixture.clock.set(300)
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)), .acceptedWaiting)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.active, active)
        guard case .coldStart(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else { return XCTFail("parent缺失") }
        XCTAssertEqual(parent.accumulatedEffectiveTime, 100)
        XCTAssertNil(parent.runningSince, "普通cold/user-resume须有typed available才能起算，unknown不是运行授权")
    }

    func testRouteFreezePreparationFailureClosesSameCellAndTerminalsReturnedSource() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 1000, initialNamespace: .freezeGeneration)
        let fixture = try ResetAcquiringOutputFixture(allocator: allocator)
        try fixture.configureAndHandoff()
        _ = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("真实route任务缺失") }
        let source = try XCTUnwrap(pending.sampler)
        let claim = try claimGraphRoute(registry, lane: fixture.lane,
            observation: try XCTUnwrap(pending.ticket), source: source)
        let before = registry.executor.safetyIngress.snapshot.freezeGeneration
        var last = try allocator.next(in: .freezeGeneration)
        while last < UInt64.max { last = try allocator.next(in: .freezeGeneration) }
        fixture.clock.set(200)
        XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot([])).disposition, .failed)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.freezeGeneration, before, "失败不能发布半freeze候选")
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled),
            "getter已实际返回，checked准备失败必须同CAS结束原source而非等待第二次回调")
        XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
    }

    func testExplicitRouteNoneFreezesReactivationParentAndUnknownHintCannotClearItsCause() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previous = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        XCTAssertNil(registry.phase(of: previous), "组合完成已退休此准确原票")
        fixture.clock.set(200)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        fixture.clock.set(300)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let source = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce,
            mandatorySuffix: 1_000_000_000))
        let oldArm = try XCTUnwrap(registry.registeredAudioSessionPhase()?.reactivationState?.cutoffArmTicket)
        let request = try claimGraphAudioCall(registry, lane: fixture.lane, source)
        fixture.clock.set(400)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("必须建立真实getter任务") }
        let noneClaim = try claimGraphRoute(registry, lane: fixture.lane,
            observation: try XCTUnwrap(pending.ticket), source: try XCTUnwrap(pending.sampler))
        fixture.clock.set(500)
        XCTAssertEqual(try completeGraphRoute(registry, noneClaim, snapshot: GraphRouteSnapshot([])).disposition, .accepted)
        let frozen = try XCTUnwrap(registry.registeredAudioSessionPhase()?.reactivationState)
        XCTAssertTrue(frozen.freezeCauses.contains(.routeUnavailable))
        XCTAssertFalse(frozen.freezeCauses.activationBlocked, "route-none不能禁止需要读取真实路由的activation")
        XCTAssertNil(frozen.cutoffArmTicket)
        guard case .coldStart(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("原parent必须整值保留")
        }
        XCTAssertEqual(parent.accumulatedEffectiveTime, 300)
        XCTAssertNil(parent.runningSince)
        XCTAssertNil(try registry.evaluateOutputReactivationCutoffArm(oldArm), "冻结后旧arm不得续权")
        fixture.clock.set(600)
        let freeze = registry.executor.safetyIngress.snapshot.freezeGeneration
        let hints: [PlaybackRouteSemanticIdentity?] = [nil,
            .init(ports: [], backend: .sampleBuffer, outputConfigurationIncarnation: .init(rawValue: 1), endpointTopologyToken: .init(rawValue: 1)),
            .init(ports: .builtIn, backend: .sampleBuffer, outputConfigurationIncarnation: .init(rawValue: 1), endpointTopologyToken: .init(rawValue: 1))]
        registry.executor.sync {
            for (index, hint) in hints.enumerated() {
                registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: noneClaim.observation.monitorLifecycle,
                    notificationRevision: noneClaim.notificationRevision + UInt64(index + 1),
                    reasonBits: 1, topologyChangeHint: false,
                    outputConfigurationChanged: false, observedRoute: hint))
            }
        }
        XCTAssertTrue(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses.contains(.routeUnavailable) == true,
            "未知hint不是none解除事实")
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.freezeGeneration, freeze, "coalesced伪none/非空通知都不能改变route原因")
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        XCTAssertEqual(registry.postConfigurationRouteDeadlineSnapshot()?.effectiveElapsed(at: 600), 400,
            "route-none冻结parent，但post stage必须继续计时")
        guard case .pending(let hinted) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("合并hint后必须保留新单次getter")
        }
        let next = try claimGraphRoute(registry, lane: fixture.lane,
            observation: noneClaim.observation, source: try XCTUnwrap(hinted.sampler))
        fixture.clock.set(700)
        XCTAssertEqual(try completeGraphRoute(registry, next, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        XCTAssertFalse(registry.registeredAudioSessionPhase()?.reactivationState?.freezeCauses.contains(.routeUnavailable) == true)
        guard case .coldStart(let resumed) = registry.outputResourceContextSnapshot()?.parentDeadline else { return XCTFail("parent丢失") }
        XCTAssertEqual(resumed.accumulatedEffectiveTime, 300)
        XCTAssertEqual(resumed.runningSince, 700)
    }

    func testRetirementPrepareFailureKeepsOriginalRecordAndClosesCellBeforeReturning() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 1000, initialNamespace: .nonce)
        let (fixture, previous) = try quiescentResumeWaitingForOwner(allocator: allocator)
        let registry = fixture.registry
        XCTAssertEqual(registry.phase(of: previous), .terminal(.completed),
            "audio组合完成已自行退休；仍需验证真实末个非audio owner退休准备失败不丢原槽")
        var last = try allocator.next(in: .nonce)
        while last < UInt64.max - 1 { last = try allocator.next(in: .nonce) }
        do {
            let result = try registry.retireOutputControlRecord(previous)
            XCTAssertEqual(result, .rejected)
        } catch {
            // 准备错误也必须在本次返回以前由同一Cell接纳，不能等下一次barrier。
        }
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
        XCTAssertNotNil(registry.phase(of: previous), "准备失败不能提前丢掉原terminal record")
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertEqual(try registry.retireOutputControlRecord(previous), .retired(followUp: nil),
            "同CAS失败后仍允许准确原record纯清理，不能被user准入guard封死")
        XCTAssertNil(registry.phase(of: previous))
    }

    func testEarlyResumeBeforeProofIsDeliveredByLastNonAudioOwnerRetirement() throws {
        let (fixture, ownerTask) = try quiescentResumeWaitingForOwner()
        let registry = fixture.registry
        XCTAssertFalse(registry.retire(ownerTask), "正式图内末个owner不能由Bool路径丢弃后继")
        guard case .retired(let followUp) = try registry.retireOutputControlRecord(ownerTask) else {
            return XCTFail("准确旧owner必须退休")
        }
        let source = try XCTUnwrap(followUp, "早于proof的用户意图必须由末个非audio原record的CAS交付")
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .rejected)
        _ = try claimGraphAudioCall(registry, lane: fixture.lane, source)
    }

    func testAutomaticTerminalUsesFirstCellFailureInstantInsteadOfDelayedCleanupInstant() throws {
        for confirmedPause in [false, true] {
            let pauseAnchor: UInt64 = 500
            let firstFailureInstant: UInt64 = 1_000
            let delayedTerminalInstant: UInt64 = 8_000_001_000
            let clock = OutputTestClock(pauseAnchor)
            let graph = try OutputGraphFixture(clock: clock)
            let registry = graph.registry
            let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let prepare = try XCTUnwrap(installed.sourceTask)
            XCTAssertTrue(registry.claimStart(prepare))
            XCTAssertTrue(registry.completeOutputPrepare(prepare))
            if confirmedPause {
                _ = try graph.coordinator.begin(contextNonce: installed.contextNonce,
                    reason: .pause, at: pauseAnchor, teardown: false)
                let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
                XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .pause)
                XCTAssertTrue(registry.claimStart(suspend.task))
                XCTAssertTrue(graph.coordinator.completeSuspend(.init(suspendTicket: suspend, closeClaim: nil,
                    directlyConfirmedRateZero: true, preparedPreserved: true)))
                XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .pause)
                XCTAssertNil(registry.outputResourceContextSnapshot()?.budget)
            }
            let scheduler = PlaybackDeadlineScheduler(registry: registry)
            let receiver = OutputNoopTerminalCleanupReceiver()
            registry.bindPlaybackRuntime(scheduler: scheduler, receiver: receiver)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())

            registry.executor.sync {
                clock.set(firstFailureInstant)
                registry.executor.safetyIngress.beginRouteObservation(.init(
                    sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: 1,
                    notificationRevision: 1,
                    reasonBits: 0b1100_0000,
                    topologyChangeHint: false,
                    outputConfigurationChanged: false,
                    observedRoute: nil))
                XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .invalidEvidence)
                clock.set(delayedTerminalInstant)
            }

            registry.notifyPlaybackProgress()
            let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertTrue(failed.poisoned)
            XCTAssertEqual(failed.owner?.reason, .terminal)
            XCTAssertEqual(failed.budget?.anchorInstant,
                confirmedPause ? pauseAnchor : firstFailureInstant,
                "延迟自动终态须保留不晚于首次Cell失败的准确清理锚点，不能续杯")
            withExtendedLifetime((graph, scheduler, receiver)) {}
        }
    }

    func testRetirementClockOverflowClosesSameCellWithoutAllocatorStickyAndStillAllowsCleanup() throws {
        let (fixture, ownerTask) = try quiescentResumeWaitingForOwner()
        let registry = fixture.registry
        fixture.stable.acquisition.clock.set(UInt64.max)
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .rejected)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .clockOverflow,
            "新ordinary D的clock加法溢出不能等allocator sticky或下一次barrier")
        XCTAssertNotNil(registry.phase(of: ownerTask))
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        XCTAssertNil(registry.phase(of: ownerTask))
    }

    func testProofLastSettlesOriginalDrainedShapeAndDeliversOneReactivationWithoutSecondUserAction() throws {
        let (fixture, ownerTask) = try quiescentResumeWaitingForOwner(issueProof: false)
        let registry = fixture.registry
        let owner = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        XCTAssertNil(registry.registeredOutputDrainProof())
        guard case .settled(let proof, let followUp) = registry.settleOutputInterruptionDrain(owner: owner) else {
            return XCTFail("最后到达的真实drain proof也必须同CAS安装后继")
        }
        let source = try XCTUnwrap(followUp)
        XCTAssertEqual(registry.registeredOutputDrainProof(), .interruption(proof))
        XCTAssertEqual(registry.settleOutputInterruptionDrain(owner: owner), .settled(proof: proof, followUp: nil),
            "重复settle只确认原proof，不能重复交付后继")
        _ = try claimGraphAudioCall(registry, lane: fixture.lane, source)
    }

    func testProofLastPreparationFailuresPublishNeitherProofNorNewCycleAndCloseCellImmediately() throws {
        for identityFailure in [false, true] {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 1000, initialNamespace: .nonce)
            let (fixture, ownerTask) = try quiescentResumeWaitingForOwner(issueProof: false, allocator: allocator)
            let registry = fixture.registry
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(context.owner)
            XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
            if identityFailure {
                var last = try allocator.next(in: .nonce)
                while last < UInt64.max - 1 { last = try allocator.next(in: .nonce) }
            } else { fixture.stable.acquisition.clock.set(UInt64.max) }
            XCTAssertEqual(registry.settleOutputInterruptionDrain(owner: owner), .rejected)
            XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure,
                identityFailure ? .identitySpaceExhausted : .clockOverflow)
            XCTAssertEqual(allocator.isExhausted, identityFailure)
            XCTAssertNil(registry.registeredOutputDrainProof())
            XCTAssertNil(registry.outputResourceContextSnapshot()?.interruptionProof)
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.reservation, context.reservation)
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
            XCTAssertNotNil(registry.ownedResourceSnapshot())
        }
    }

    func testProofBeforeUserIntentWaitsAndOldOwnerCannotSettleAcrossReset() throws {
        let (fixture, ownerTask) = try quiescentResumeWaitingForOwner(issueProof: false, resume: false)
        let registry = fixture.registry
        let owner = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        guard case .settled(let proof, let followUp) = registry.settleOutputInterruptionDrain(owner: owner) else {
            return XCTFail("veto只阻activation，不丢真实已完成的drain proof")
        }
        XCTAssertNil(followUp)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
        guard case .acceptedAndPrepared(let source) = registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)) else {
            return XCTFail("proof先到，真实用户意图后到时应同CAS交付attempt")
        }
        _ = try claimGraphAudioCall(registry, lane: fixture.lane, source)
        _ = try capturedResetRoot(registry)
        XCTAssertEqual(registry.settleOutputInterruptionDrain(owner: owner), .rejected)
        XCTAssertNotEqual(registry.registeredOutputDrainProof(), .interruption(proof))
    }

    private func quiescentResumeWaitingForOwner(issueProof: Bool = true, resume: Bool = true,
        allocator: PlaybackIdentityAllocator = .init()) throws -> (OutputGraphFixture, ControlTaskTicket) {
        let fixture = try OutputGraphFixture(allocator: allocator)
        let registry = fixture.registry
        let initial = try XCTUnwrap(registry.outputResourceContextSnapshot())
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = registry.outputResourceContextSnapshot()
        if let prepare = initial.sourceTask {
            XCTAssertEqual(try registry.retireOutputControlRecord(prepare), .retired(followUp: nil))
        }
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: initial.contextNonce,
            reason: .recovery, at: fixture.stable.acquisition.clock.read(), teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
        if resume { XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)), .acceptedWaiting) }
        XCTAssertNil(registry.registeredOutputDrainProof())
        if issueProof {
            guard case .settled(_, let followUp) = registry.settleOutputInterruptionDrain(owner: owner) else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            XCTAssertNil(followUp, "原记录尚未退休不能提前轮换新cycle")
        }
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        return (fixture, ownerTask)
    }

    func testCombinedAudioRetirementLetsResumePrepareOneAttemptWithoutRevivingOriginalRecord() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previous = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        fixture.clock.set(200)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        fixture.clock.set(300)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
        let request = try userControlRequest(registry, kind: .resume)
        XCTAssertNil(registry.phase(of: previous), "原activation已在组合完成交付sampler时准确退休")
        guard case .acceptedAndPrepared(let source) = registry.performOutputUserControl(request) else {
            return XCTFail("没有待join的旧audio record时，resume本CAS直接交付唯一新attempt")
        }
        XCTAssertNil(registry.executor.safetyIngress.snapshot.failure)
        guard case .activate(.reactivateConfiguredGeneration, _, _, _) = registry.registeredAudioSessionPhase()?.policy else {
            return XCTFail("resume同CAS必须消费真实用户意图并准备attempt")
        }
        XCTAssertEqual(registry.postConfigurationRouteDeadlineSnapshot()?.runningSince, 300)
        XCTAssertEqual(try registry.retireOutputControlRecord(previous), .rejected, "原record只能退休一次")
        XCTAssertEqual(registry.performOutputUserControl(request), .acceptedWaiting, "重复resume只保留原queued attempt")
        _ = try claimGraphAudioCall(registry, lane: fixture.lane, source)
    }

    func testRepeatedReadyResumeDoesNotReplaceQueuedAttemptOrFailClosed() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previous = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        XCTAssertNil(registry.phase(of: previous), "组合完成已退休此准确原票")
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
        let request = try userControlRequest(registry, kind: .resume)
        guard case .acceptedAndPrepared(let source) = registry.performOutputUserControl(request) else {
            return XCTFail("首resume应准备真实attempt")
        }
        let phase = registry.registeredAudioSessionPhase()
        let freeze = registry.executor.safetyIngress.snapshot.freezeGeneration
        XCTAssertEqual(registry.performOutputUserControl(request), .acceptedWaiting)
        XCTAssertNil(registry.executor.safetyIngress.snapshot.failure)
        XCTAssertEqual(registry.registeredAudioSessionPhase(), phase)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.freezeGeneration, freeze)
        XCTAssertFalse(try XCTUnwrap(registry.outputResourceContextSnapshot()).userResumeRequested,
            "准确proof已消费且原attempt仍在途时，重复resume不能挂成待消费意图")
        _ = try claimGraphAudioCall(registry, lane: fixture.lane, source)
    }

    func testNoProofResumeSurvivesRealInFlightAcquisitionCallRetirementWithoutReplacingAttempt() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        let category = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(
            contextNonce: fixture.contextNonce, parent: fixture.parent))
        let originalPhase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        let call = try claimGraphAudioCall(registry, lane: fixture.lane, category)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))

        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)),
            .acceptedWaiting)
        XCTAssertTrue(try XCTUnwrap(registry.outputResourceContextSnapshot()).userResumeRequested,
            "真实配置调用在途不能冒充恢复授权并吞掉无proof的resume意图")
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)

        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, call,
            .configuration(.categorySucceeded))
        XCTAssertNil(registry.phase(of: category), "真实SDK返回必须退休准确原record")
        XCTAssertNotNil(completion.followUp, "配置链只可继续原attempt的下一真实步骤")
        let currentPhase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        XCTAssertEqual(currentPhase.configurationAttempt, originalPhase.configurationAttempt,
            "无proof resume不能伪造或替换配置attempt")
        XCTAssertTrue(try XCTUnwrap(registry.outputResourceContextSnapshot()).userResumeRequested,
            "原在途调用退休后，尚未被proof消费的resume意图不能丢失")
        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
    }

    func testReadyProofUserResumePreparesExactAttemptInSameCASAndSDKConsumesStage() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previous = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        XCTAssertNil(registry.phase(of: previous), "组合完成已退休此准确原票")
        fixture.clock.set(200)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        fixture.clock.set(300)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
        let request = try userControlRequest(registry, kind: .resume)
        guard case .acceptedAndPrepared(let source) = registry.performOutputUserControl(request) else {
            return XCTFail("真实当前post proof已ready时resume必须同CAS发行准确attempt")
        }
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionState, .ended(shouldResume: false))
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        XCTAssertEqual(registry.postConfigurationRouteDeadlineSnapshot()?.runningSince, 300)
        XCTAssertEqual(registry.postConfigurationRouteDeadlineSnapshot()?.budget.accumulatedEffectiveTime, 100)
        let sdkRequest = try claimGraphAudioCall(registry, lane: fixture.lane, source)
        fixture.clock.set(400)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, sdkRequest, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertEqual(registry.postConfigurationRouteDeadlineSnapshot()?.effectiveElapsed(at: 400), 200)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.active?.configurationGeneration, 1)
    }

    func testUserPauseAtPostStageBoundaryCannotFreezeAwayTimeout() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        _ = try fixture.activateResetAndCommit()
        fixture.clock.set(3_000_000_100)
        let request = try userControlRequest(fixture.registry, kind: .pause)
        XCTAssertEqual(fixture.registry.performOutputUserControl(request), .rejected)
        XCTAssertTrue(fixture.registry.outputResourceContextSnapshot()?.poisoned == true,
            "恰到界时pause不能冻结已经耗尽的stage")
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
        XCTAssertFalse(fixture.registry.executor.safetyIngress.snapshot.userPaused, "终态胜出，不半提交pause意图")
    }

    func testUserFreezeIdentityFailurePublishesNoPartialIntentOrClockAndUsesTerminalHook() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 1, initialNamespace: .freezeGeneration)
        let fixture = try StableOutputFixture(allocator: allocator)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let request = try userControlRequest(registry, kind: .pause)
        XCTAssertEqual(registry.performOutputUserControl(request), .rejected)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.userPaused)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline, context.parentDeadline)
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.reservation, context.reservation)
        XCTAssertNotNil(registry.ownedResourceSnapshot())
    }

    func testStaleUserResumeCannotCrossOwnerEpochOrResetBinding() throws {
        for supersession in 0..<3 {
            let fixture = try StableOutputFixture()
            let registry = fixture.registry
            XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .pause)), .acceptedWaiting)
            let request = try userControlRequest(registry, kind: .resume)
            switch supersession {
            case 0:
                _ = try OutputCleanupCoordinator(registry: registry).begin(contextNonce: request.contextNonce,
                    reason: .recovery, at: fixture.acquisition.clock.read())
            case 1:
                registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
                registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            default: _ = try capturedResetRoot(registry)
            }
            XCTAssertEqual(registry.performOutputUserControl(request), .rejected)
            XCTAssertTrue(registry.executor.safetyIngress.snapshot.userPaused)
        }
    }

    func testEarlyUserResumeIsAcceptedBeforeDrainProofWithoutForgingEndedOrActivation() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
        let request = try userControlRequest(registry, kind: .resume)
        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertEqual(registry.performOutputUserControl(request), .acceptedWaiting)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionState, .ended(shouldResume: false))
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto,
            "无当前proof的resume只能记录意图，不能清除物理veto")
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        XCTAssertNil(try registry.beginOutputReactivation(contextNonce: request.contextNonce, mandatorySuffix: 1_000_000_000))
        XCTAssertEqual(registry.occupancy.safetySlots, 0, "接受意图不伪造proof或提前调SDK")
    }

    func testUserPausePersistsAcrossEndedAndResumeDuringBeganClearsOnlyPause() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let pause = try userControlRequest(registry, kind: .pause)
        let active = registry.outputResourceContextSnapshot()?.sessionReceipts?.active
        XCTAssertEqual(registry.performOutputUserControl(pause), .acceptedWaiting)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.userPaused)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.readinessOpen)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.routeObservationGateOpen,
            "普通用户pause保留真实stable route，rate-0 prepare不能被错误迫停")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.active, active)
        let frozen = registry.executor.safetyIngress.snapshot.freezeGeneration
        XCTAssertEqual(registry.performOutputUserControl(pause), .acceptedWaiting)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.freezeGeneration, frozen, "重复pause不能换freeze identity")
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen,
            "真实系统中断仍立即撤销route权威")
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.userPaused, "系统ended不能取消真实用户pause")
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen,
            "ended本身不能重新打开route门")
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)), .acceptedWaiting)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.userPaused)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionState, .began)
    }

    func testRealConfigurationPhaseRejectsForgedReceiptConsistencyWithoutMutatingAuthority() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.registry.beginOutputAcquisitionConfiguration(contextNonce: fixture.contextNonce, parent: fixture.parent)
        let current = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        var forged = current
        forged.processReceipt = .init(identity: .init(mediaServicesEpoch: 0, configurationGeneration: 1, receiptNonce: 123),
            actualPolicy: .longFormAudio, preferredFailureReason: nil, multichannelCapability: true,
            planDigest: current.configurationAttempt.plan, attemptLineage: current.configurationAttempt)
        XCTAssertFalse(forged.hasConsistentActivationConfiguration,
            "真实配置未完成时，外来process receipt不能成为可激活事实")
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase(), current)
        XCTAssertNil(fixture.registry.processAudioSessionReceiptSnapshot())
    }

    func testPostStageLateSampleArmAndStableCommitUseStrictAdjacentThreeSecondBoundary() throws {
        for path in 0..<3 {
            for delta: Int64 in [-1_000_000, 0, 1_000_000] {
                let fixture = try ResetAcquiringOutputFixture()
                try fixture.configureAndHandoff()
                _ = try fixture.activateResetAndCommit()
                let registry = fixture.registry
                guard case .pending(let pending) = registry.outputRouteObservationSnapshot(),
                      let observation = pending.ticket, let source = pending.sampler else { return XCTFail("真实post sampler缺失") }
                let stage = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
                let runningSince = try XCTUnwrap(stage.runningSince)
                let remaining = stage.budget.maximumEffectiveDuration - stage.budget.accumulatedEffectiveTime
                let boundary = runningSince + remaining
                let target = delta < 0 ? boundary - UInt64(-delta) : boundary + UInt64(delta)
                let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
                if path == 0 {
                    fixture.clock.set(target)
                    XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted, delta < 0)
                    if delta >= 0 {
                        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled),
                            "迟到getter的SDK已经返回，不能留running/cancelRequested")
                        XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
                    }
                } else {
                    fixture.clock.set(200)
                    XCTAssertTrue(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
                    let arm = path == 2 ? try XCTUnwrap(registry.armOutputRouteStability(observation: observation)) : nil
                    fixture.clock.set(target)
                    if let arm {
                        XCTAssertEqual(try registry.commitOutputRouteStability(arm) != nil, delta < 0)
                    } else {
                        XCTAssertEqual(try registry.armOutputRouteStability(observation: observation) != nil, delta < 0)
                    }
                }
                let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
                if delta < 0 {
                    XCTAssertFalse(context.poisoned, "path=\(path)：2.999秒仍须接纳准确事实")
                } else {
                    XCTAssertTrue(context.poisoned, "path=\(path)：3.000/3.001秒必须由terminal owner胜出")
                    XCTAssertEqual(context.owner?.reason, .terminal)
                    XCTAssertFalse(testRouteGate(registry: registry))
                }
            }
        }
    }

    func testOrdinaryLateSampleArmAndStableCommitUseStrictAdjacentThreeSecondBoundary() throws {
        for path in 0..<3 {
            for delta: Int64 in [-1_000_000, 0, 1_000_000] {
                let fixture = try AcquiringOutputFixture()
                _ = try fixture.configureAndActivate()
                let registry = fixture.registry
                let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
                guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token),
                      let observation = handoff.routeObservation, let source = handoff.sampler,
                      let deadline = handoff.routeDeadline else { return XCTFail("真实ordinary D/sampler缺失") }
                let boundary = deadline.deadlineInstant
                let target = delta < 0 ? boundary - UInt64(-delta) : boundary + UInt64(delta)
                let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
                if path == 0 {
                    fixture.clock.set(target)
                    XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted, delta < 0)
                    if delta >= 0 {
                        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled),
                            "迟到ordinary getter已经返回，不能留下running/cancelRequested")
                        XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
                    }
                } else {
                    fixture.clock.set(100)
                    XCTAssertTrue(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
                    let arm = path == 2 ? try XCTUnwrap(registry.armOutputRouteStability(observation: observation)) : nil
                    fixture.clock.set(target)
                    if let arm {
                        XCTAssertEqual(try registry.commitOutputRouteStability(arm) != nil, delta < 0)
                    } else {
                        XCTAssertEqual(try registry.armOutputRouteStability(observation: observation) != nil, delta < 0)
                    }
                }
                let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
                if delta < 0 {
                    XCTAssertFalse(context.poisoned, "path=\(path)：ordinary 2.999秒仍须接纳准确事实")
                } else {
                    XCTAssertTrue(context.poisoned, "path=\(path)：ordinary 3.000/3.001秒必须由terminal owner胜出")
                    XCTAssertEqual(context.owner?.reason, .terminal)
                    XCTAssertFalse(testRouteGate(registry: registry))
                }
            }
        }
    }

    func testPendingStabilityNotificationInstallsFreshSingleUseSamplerWithoutRenewingBoundary() throws {
        func makePending(post: Bool) throws -> (ControlTaskRegistry, AudioSessionBlockingCallLane, OutputTestClock, PendingRouteObservation, UInt64) {
            if post {
                let fixture = try ResetAcquiringOutputFixture()
                try fixture.configureAndHandoff()
                _ = try fixture.activateResetAndCommit()
                guard case .pending(let pending) = fixture.registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                let stage = try XCTUnwrap(fixture.registry.postConfigurationRouteDeadlineSnapshot())
                let runningSince = try XCTUnwrap(stage.runningSince)
                return (fixture.registry, fixture.lane, fixture.clock, pending,
                    runningSince + stage.budget.maximumEffectiveDuration - stage.budget.accumulatedEffectiveTime)
            }
            let fixture = try AcquiringOutputFixture()
            _ = try fixture.configureAndActivate()
            let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
            guard case .committed = try fixture.registry.commitAcquisitionRelayAndContext(token),
                  case .pending(let pending) = fixture.registry.outputRouteObservationSnapshot() else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            return (fixture.registry, fixture.lane, fixture.clock, pending, try XCTUnwrap(pending.deadline).deadlineInstant)
        }

        for post in [false, true] {
            for resultKind in 0..<3 {
                let (registry, lane, clock, initial, originalBoundary) = try makePending(post: post)
                let observation = try XCTUnwrap(initial.ticket)
                let firstSource = try XCTUnwrap(initial.sampler)
                let firstSample = try claimGraphRoute(registry, lane: lane, observation: observation, source: firstSource)
                let firstSampleInstant = clock.read() + 10
                clock.set(firstSampleInstant)
                XCTAssertEqual(try completeGraphRoute(registry, firstSample, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
                XCTAssertEqual(registry.phase(of: firstSource), .terminal(.completed),
                    "每个currentRoute请求返回都必须terminal自己的单次record")

                let oldArm = resultKind == 0 ? nil : try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
                let notificationInstant = firstSampleInstant + 10
                clock.set(notificationInstant)
                let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
                registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: observation.monitorLifecycle,
                    notificationRevision: firstSample.notificationRevision + 1,
                    reasonBits: 1, topologyChangeHint: resultKind != 0,
                    outputConfigurationChanged: resultKind == 1,
                    observedRoute: nil))
                guard case .pending(let resampling) = registry.outputRouteObservationSnapshot() else {
                    return XCTFail("稳定窗内通知必须保持pending")
                }
                XCTAssertEqual(resampling.ticket, observation, "通知不能重签观察票或外层预算")
                XCTAssertEqual(post ? originalBoundary : resampling.deadline?.deadlineInstant, originalBoundary)
                let secondSource = try XCTUnwrap(resampling.sampler)
                XCTAssertNotEqual(secondSource, firstSource, "每次currentRoute必须绑定新且不可复用的sampler record")
                XCTAssertEqual(registry.phase(of: secondSource), .queued)
                XCTAssertNil(registry.phase(of: firstSource))
                if let oldArm {
                    clock.set(oldArm.deadlineInstant)
                    XCTAssertNil(try registry.commitOutputRouteStability(oldArm), "新通知必须使旧稳定票永久失权")
                }

                let secondSample = try claimGraphRoute(registry, lane: lane, observation: observation, source: secondSource)
                let secondSampleInstant = max(clock.read(), notificationInstant) + 10
                clock.set(secondSampleInstant)
                let secondResult = resultKind == 2 ? GraphRouteSnapshot([]) : resultKind == 1 ? .ports(.airPlay) : .builtIn
                let secondCompletion = try completeGraphRoute(registry, secondSample, snapshot: secondResult)
                XCTAssertEqual(secondCompletion.disposition, .accepted)
                if resultKind == 2 {
                    guard case .pending(let nonePending) = registry.outputRouteObservationSnapshot() else {
                        return XCTFail("none必须继续等待原边界")
                    }
                    XCTAssertEqual(post ? originalBoundary : nonePending.deadline?.deadlineInstant, originalBoundary)
                    let retrySource = try XCTUnwrap(nonePending.sampler)
                    XCTAssertNotEqual(retrySource, secondSource, "none后的下一次getter也必须取得新单次record")
                    clock.set(originalBoundary)
                    XCTAssertEqual(secondCompletion.followUp, retrySource)
                    XCTAssertEqual(registry.executor.performAudioSessionCall(.claim(retrySource, lane: lane, family: .sampler)), .rejected)
                    XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
                } else {
                    let currentArm = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
                    XCTAssertEqual(currentArm.anchorInstant,
                        resultKind == 0 ? firstSampleInstant : secondSampleInstant,
                        "只有semantic变化才重置120ms窗口")
                    clock.set(currentArm.deadlineInstant)
                    XCTAssertNotNil(try registry.commitOutputRouteStability(currentArm))
                    XCTAssertNil(registry.phase(of: secondSource))
                }
            }
        }
    }

    func testRouteSamplerCancellationDiscardsIdleRecordButJoinsInFlightGetter() throws {

        do {
            let fixture = try AcquiringOutputFixture()
            _ = try fixture.configureAndActivate()
            let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
            guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
                return XCTFail("ordinary handoff失败")
            }
            let observation = try XCTUnwrap(handoff.routeObservation)
            let source = try XCTUnwrap(handoff.sampler)
            let claim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation, source: source)
            XCTAssertTrue(try completeGraphRoute(fixture.registry, claim, snapshot: GraphRouteSnapshot([])).disposition == .accepted)
            guard case .pending(let retry) = fixture.registry.outputRouteObservationSnapshot() else {
                return XCTFail("none必须留下下一次单次getter")
            }
            let idle = try XCTUnwrap(retry.sampler)
            XCTAssertNotEqual(idle, source)
            XCTAssertEqual(fixture.registry.phase(of: idle), .queued)
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            guard case .pending(let canceled) = fixture.registry.outputRouteObservationSnapshot() else {
                return XCTFail("began后必须保留pending壳")
            }
            XCTAssertNil(canceled.sampler, "没有在途getter时取消必须当场清掉idle sampler绑定")
            XCTAssertNil(fixture.registry.phase(of: idle), "idle queued取消不能等待不存在的completion")
        }

        do {
            let fixture = try AcquiringOutputFixture()
            _ = try fixture.configureAndActivate()
            let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
            guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
                return XCTFail("ordinary handoff失败")
            }
            let observation = try XCTUnwrap(handoff.routeObservation)
            let source = try XCTUnwrap(handoff.sampler)
            let claim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation, source: source)
            fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            XCTAssertEqual(fixture.registry.phase(of: source), .cancelRequested,
                "真实在途getter必须保持原责任等待返回")
            XCTAssertFalse(try completeGraphRoute(fixture.registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
            XCTAssertEqual(fixture.registry.phase(of: source), .terminal(.canceled))
            guard case .pending(let joined) = fixture.registry.outputRouteObservationSnapshot() else {
                return XCTFail("began后必须保留pending壳")
            }
            XCTAssertFalse(joined.sampleInFlight)
            XCTAssertNil(joined.sampler, "原getter返回后必须结束准确绑定，不能留下cancelRequested死等")
            XCTAssertEqual(try fixture.registry.retireOutputControlRecord(source), .retired(followUp: nil))
        }
    }

    func testNotificationCrossingInFlightGetterReplacesReturnedRecordAndFinalReleaseReachesZero() throws {
        let fixture = try AcquiringOutputFixture()
        let activation = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("ordinary handoff失败")
        }
        let observation = try XCTUnwrap(handoff.routeObservation)
        let firstSource = try XCTUnwrap(handoff.sampler)
        let staleClaim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: firstSource)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        fixture.clock.set(200)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
            monitorLifecycle: observation.monitorLifecycle,
            notificationRevision: staleClaim.notificationRevision + 1,
            reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false,
            observedRoute: staleClaim.observationHint))
        XCTAssertFalse(try completeGraphRoute(registry, staleClaim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted,
            "通知穿越的旧getter只能结束自己的单次record，不能提交旧revision")
        guard case .pending(let resampling) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("旧getter返回后必须继续pending")
        }
        let secondSource = try XCTUnwrap(resampling.sampler)
        XCTAssertNotEqual(secondSource, firstSource)
        XCTAssertNil(registry.phase(of: firstSource))
        XCTAssertEqual(registry.phase(of: secondSource), .queued)
        let current = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: secondSource)
        fixture.clock.set(210)
        XCTAssertTrue(try completeGraphRoute(registry, current, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
        let arm = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
        fixture.clock.set(arm.deadlineInstant)
        XCTAssertNotNil(try registry.commitOutputRouteStability(arm))
        XCTAssertNil(registry.phase(of: activation), "组合完成已退休此准确原票")

        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: retained.contextNonce, reason: .stop,
            at: fixture.clock.read()))
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let deactivate = try registry.enqueueCleanupDeactivation(reservation.ticket)
        XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        XCTAssertNil(registry.phase(of: deactivate))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release)) as OwnedOutputResourceRunner?
        XCTAssertNotNil(runner)
        XCTAssertTrue(registry.complete(release))
        runner = nil
        XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
        XCTAssertEqual(registry.occupancy.safetySlots, 0)
    }

    func testReturnedRouteSampleReplacementIdentityFailureTerminalsExactSourceBeforeFailClosedCleanup() throws {

        for staleReturn in [false, true] {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 256,
                initialNamespace: .controlTask)
            let clock = OutputTestClock(100)
            let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
            let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
            _ = try fixture.configureAndActivate()
            let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
            guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
                return XCTFail("ordinary handoff失败")
            }
            let observation = try XCTUnwrap(handoff.routeObservation)
            let source = try XCTUnwrap(handoff.sampler)
            let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
            if staleReturn {
                let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
                registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: observation.monitorLifecycle,
                    notificationRevision: claim.notificationRevision + 1,
                    reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false,
                    observedRoute: claim.observationHint))
            }
            while try allocator.next(in: .controlTask) != .max {}

            XCTAssertFalse(try completeGraphRoute(registry, claim, snapshot: staleReturn ? GraphRouteSnapshot.builtIn : GraphRouteSnapshot([])).disposition == .accepted)
            XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
            XCTAssertEqual(registry.phase(of: source), .terminal(.canceled),
                "本次getter已经返回；后继准备失败也不能留下cancelRequested等待不存在的第二次回调")
            guard case .pending(let failed) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("失败关闭仍须保留原观察壳供准确清理")
            }
            XCTAssertFalse(failed.sampleInFlight)
            XCTAssertNil(failed.sampler)
            XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil),
                "准备失败不能先删原槽，但同CAS终态后必须允许准确原source纯退休")
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
            let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
            XCTAssertTrue(reservation.terminal)
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.disposition, .releaseAfterTeardown)
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.teardownRequested == true,
                "资源失败关闭必须进入原预签terminal清理边界，不能依赖新的身份或SDK回调")
        }
    }

    func testStaleInFlightRouteSampleRechecksOriginalOrdinaryPostAndParentBoundaryBeforeReplacement() throws {

        func makeStaleClaim(boundaryKind: Int) throws ->
            (ControlTaskRegistry, OutputTestClock, PendingRouteObservation, ControlTaskTicket, GraphRouteCall, UInt64) {
            if boundaryKind == 2 {
                let fixture = try AcquiringOutputFixture(parentCap: 500_000_000,
                    resetRecoveryMandatorySuffix: 100_000_000)
                _ = try fixture.configureAndActivate()
                let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
                guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                let observation = try XCTUnwrap(handoff.routeObservation)
                let none = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation,
                    source: try XCTUnwrap(handoff.sampler))
                fixture.clock.set(200)
                XCTAssertTrue(try completeGraphRoute(fixture.registry, none, snapshot: GraphRouteSnapshot([])).disposition == .accepted)
                guard case .pending(let retry) = fixture.registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                let available = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation,
                    source: try XCTUnwrap(retry.sampler))
                fixture.clock.set(300)
                XCTAssertTrue(try completeGraphRoute(fixture.registry, available, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
                let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
                fixture.clock.set(310)
                fixture.registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: observation.monitorLifecycle,
                    notificationRevision: available.notificationRevision + 1,
                    reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false,
                    observedRoute: nil))
                guard case .pending(let idle) = fixture.registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                let source = try XCTUnwrap(idle.sampler)
                let claim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation, source: source)
                fixture.clock.set(320)
                fixture.registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                    monitorLifecycle: observation.monitorLifecycle,
                    notificationRevision: claim.notificationRevision + 1,
                    reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false,
                    observedRoute: nil))
                guard case .coldStart(let parent) = fixture.registry.outputResourceContextSnapshot()?.parentDeadline else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                let boundary = try XCTUnwrap(parent.runningSince) + parent.cap - parent.accumulatedEffectiveTime
                return (fixture.registry, fixture.clock, idle, source, claim, boundary)
            }

            let registry: ControlTaskRegistry
            let lane: AudioSessionBlockingCallLane
            let clock: OutputTestClock
            let pending: PendingRouteObservation
            let boundary: UInt64
            if boundaryKind == 1 {
                let fixture = try ResetAcquiringOutputFixture()
                try fixture.configureAndHandoff()
                _ = try fixture.activateResetAndCommit()
                registry = fixture.registry
                lane = fixture.lane
                clock = fixture.clock
                guard case .pending(let value) = registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                pending = value
                let stage = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
                boundary = try XCTUnwrap(stage.runningSince) + stage.budget.maximumEffectiveDuration -
                    stage.budget.accumulatedEffectiveTime
            } else {
                let fixture = try AcquiringOutputFixture()
                _ = try fixture.configureAndActivate()
                let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
                guard case .committed = try fixture.registry.commitAcquisitionRelayAndContext(token),
                      case .pending(let value) = fixture.registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                registry = fixture.registry
                lane = fixture.lane
                clock = fixture.clock
                pending = value
                boundary = try XCTUnwrap(value.deadline).deadlineInstant
            }
            let observation = try XCTUnwrap(pending.ticket)
            let source = try XCTUnwrap(pending.sampler)
            let claim = try claimGraphRoute(registry, lane: lane, observation: observation, source: source)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            clock.set(200)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: observation.monitorLifecycle,
                notificationRevision: claim.notificationRevision + 1,
                reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false,
                observedRoute: nil))
            return (registry, clock, pending, source, claim, boundary)
        }

        for boundaryKind in 0..<3 {
            for delta: Int64 in [-1_000_000, 0, 1_000_000] {
                let (registry, clock, pending, source, claim, boundary) = try makeStaleClaim(boundaryKind: boundaryKind)
                clock.set(delta < 0 ? boundary - UInt64(-delta) : boundary + UInt64(delta))
                XCTAssertFalse(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
                guard case .pending(let after) = registry.outputRouteObservationSnapshot() else {
                    return XCTFail("旧getter返回后必须保留准确观察壳")
                }
                if delta < 0 {
                    XCTAssertFalse(registry.outputResourceContextSnapshot()?.poisoned == true)
                    let replacement = try XCTUnwrap(after.sampler)
                    XCTAssertNotEqual(replacement, source)
                    XCTAssertEqual(registry.phase(of: replacement), .queued)
                    XCTAssertNil(registry.phase(of: source))
                    XCTAssertEqual(after.ticket, pending.ticket)
                } else {
                    XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true,
                        "旧getter返回时已到原边界，必须本CAS terminal而非登记新SDK请求")
                    XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
                    XCTAssertEqual(registry.phase(of: source), .terminal(.canceled))
                    XCTAssertFalse(after.sampleInFlight)
                    XCTAssertNil(after.sampler)
                }
            }
        }
    }

    func testRepeatedStabilityArmRechecksOrdinaryPostAndEarlierParentBoundaries() throws {

        func assertRepeatedArm(post: Bool, delta: Int64) throws {
            let registry: ControlTaskRegistry
            let lane: AudioSessionBlockingCallLane
            let clock: OutputTestClock
            let pending: PendingRouteObservation
            let boundary: UInt64
            if post {
                let fixture = try ResetAcquiringOutputFixture()
                try fixture.configureAndHandoff()
                _ = try fixture.activateResetAndCommit()
                registry = fixture.registry
                lane = fixture.lane
                clock = fixture.clock
                guard case .pending(let value) = registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                pending = value
                let stage = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
                boundary = try XCTUnwrap(stage.runningSince) + stage.budget.maximumEffectiveDuration -
                    stage.budget.accumulatedEffectiveTime
            } else {
                let fixture = try AcquiringOutputFixture()
                _ = try fixture.configureAndActivate()
                let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
                guard case .committed = try fixture.registry.commitAcquisitionRelayAndContext(token),
                      case .pending(let value) = fixture.registry.outputRouteObservationSnapshot() else {
                    throw ControlTaskRegistry.Failure.invalidGroup
                }
                registry = fixture.registry
                lane = fixture.lane
                clock = fixture.clock
                pending = value
                boundary = try XCTUnwrap(value.deadline).deadlineInstant
            }
            let observation = try XCTUnwrap(pending.ticket)
            let claim = try claimGraphRoute(registry, lane: lane, observation: observation, source: try XCTUnwrap(pending.sampler))
            clock.set(200)
            XCTAssertTrue(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
            let first = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
            clock.set(delta < 0 ? boundary - UInt64(-delta) : boundary + UInt64(delta))
            let repeated = try registry.armOutputRouteStability(observation: observation)
            if delta < 0 {
                XCTAssertEqual(repeated, first, "2.999秒必须幂等返回原准确票")
                XCTAssertFalse(registry.outputResourceContextSnapshot()?.poisoned == true)
            } else {
                XCTAssertNil(repeated, "3.000/3.001秒不得返回已经无权的旧票")
                XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
                XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
            }
        }

        for post in [false, true] {
            for delta: Int64 in [-1_000_000, 0, 1_000_000] {
                try assertRepeatedArm(post: post, delta: delta)
            }
        }

        for delta: Int64 in [-1_000_000, 0, 1_000_000] {
            let fixture = try AcquiringOutputFixture(parentCap: 500_000_000,
                resetRecoveryMandatorySuffix: 100_000_000)
            _ = try fixture.configureAndActivate()
            let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
            guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
                return XCTFail("更早parent的handoff失败")
            }
            let observation = try XCTUnwrap(handoff.routeObservation)
            let noneClaim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation,
                source: try XCTUnwrap(handoff.sampler))
            fixture.clock.set(200)
            XCTAssertTrue(try completeGraphRoute(fixture.registry, noneClaim, snapshot: GraphRouteSnapshot([])).disposition == .accepted)
            guard case .pending(let retry) = fixture.registry.outputRouteObservationSnapshot() else {
                return XCTFail("none后必须保留原观察窗口")
            }
            let availableClaim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation,
                source: try XCTUnwrap(retry.sampler))
            fixture.clock.set(300)
            XCTAssertTrue(try completeGraphRoute(fixture.registry, availableClaim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
            let first = try XCTUnwrap(fixture.registry.armOutputRouteStability(observation: observation))
            guard case .coldStart(let parent) = fixture.registry.outputResourceContextSnapshot()?.parentDeadline else {
                return XCTFail("更早parent缺失")
            }
            let parentBoundary = try XCTUnwrap(parent.runningSince) + parent.cap - parent.accumulatedEffectiveTime
            XCTAssertLessThan(parentBoundary, try XCTUnwrap(handoff.routeDeadline).deadlineInstant)
            fixture.clock.set(delta < 0 ? parentBoundary - UInt64(-delta) : parentBoundary + UInt64(delta))
            let repeated = try fixture.registry.armOutputRouteStability(observation: observation)
            if delta < 0 {
                XCTAssertEqual(repeated, first)
            } else {
                XCTAssertNil(repeated, "更早parent到界同样必须在重复arm入口终态收敛")
                XCTAssertTrue(fixture.registry.outputResourceContextSnapshot()?.poisoned == true)
            }
        }
    }

    func testOrdinaryReactivationUsesRealQuiescentProofAndCreatesOneDeadlineAtAttemptAdmission() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let initial = try XCTUnwrap(registry.outputResourceContextSnapshot())
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = registry.outputResourceContextSnapshot()
        if let prepare = initial.sourceTask { XCTAssertEqual(try registry.retireOutputControlRecord(prepare), .retired(followUp: nil)) }
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: initial.contextNonce, reason: .recovery,
            at: fixture.stable.acquisition.clock.read(), teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        guard case .settled(let proof, let followUp) = registry.settleOutputInterruptionDrain(owner: owner) else { return XCTFail("真实Q必须发行普通proof") }
        XCTAssertNil(followUp, "began时只能登记proof，不能激活")
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        XCTAssertNil(registry.ordinaryRouteDeadlineArmSnapshot())
        XCTAssertNil(try registry.beginOutputReactivation(contextNonce: initial.contextNonce, mandatorySuffix: 1_000_000_000))
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let source = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: initial.contextNonce, mandatorySuffix: 1_000_000_000))
        let arm = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot())
        XCTAssertEqual(arm.ticketIdentity.deadlineAnchorInstant, fixture.stable.acquisition.clock.read())
        let phase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        XCTAssertEqual(phase.currentReactivationProof, .interruption(proof))
        XCTAssertEqual(phase.reactivationState?.ticket.committedGeneration, 1)
        let request = try claimGraphAudioCall(registry, lane: fixture.lane, source)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertEqual(registry.ordinaryRouteDeadlineArmSnapshot(), arm)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.active?.configurationGeneration, 1)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .quiescentBackend)
    }

    func testExactReactivationCutoffArmRecomputesClockAndTimeoutJoinsLateSDK() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previous = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        XCTAssertNil(registry.phase(of: previous), "组合完成已退休此准确原票")
        fixture.clock.set(200)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        fixture.clock.set(300)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let source = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce, mandatorySuffix: 1_000_000_000))
        let state = try XCTUnwrap(registry.registeredAudioSessionPhase()?.reactivationState)
        let arm = try XCTUnwrap(state.cutoffArmTicket)
        XCTAssertEqual(try registry.evaluateOutputReactivationCutoffArm(arm), 2_999_999_900)
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.cutoffArmTicket, arm,
            "提前唤醒只重算remaining，不换arm或budget")
        let sdkRequest = try claimGraphAudioCall(registry, lane: fixture.lane, source)
        fixture.clock.set(3_000_000_200)
        XCTAssertNil(try registry.evaluateOutputReactivationCutoffArm(arm))
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
        XCTAssertEqual(registry.phase(of: source), .cancelRequested)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, sdkRequest, .activation(nil))
        XCTAssertEqual(completion.disposition, .settled)
        XCTAssertNil(completion.followUp)
        XCTAssertNil(registry.phase(of: source), "同CAS已移交原success清理责任后才退休")
        guard case .requiresDeactivate(.returnedSuccess(let call)) = graphOwnedDeactivation(registry) else {
            return XCTFail("到界后的真实success仍须保留原调用的deactivate责任")
        }
        XCTAssertEqual(call.record, source)
    }

    func testPostConfigurationReactivationResumesOriginalStageBeforeSDKAndPreservesGeneration() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let previousActivation = try fixture.activateResetAndCommit()
        let registry = fixture.registry
        XCTAssertNil(registry.phase(of: previousActivation), "组合完成已退休此准确原票")
        let before = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
        fixture.clock.set(200)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        fixture.clock.set(300)
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNil(registry.postConfigurationRouteDeadlineSnapshot()?.runningSince)
        let reactivation = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce,
            mandatorySuffix: 1_000_000_000))
        let during = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
        XCTAssertEqual(during.budget.stageIdentity, before.budget.stageIdentity)
        XCTAssertEqual(during.budget.accumulatedEffectiveTime, 100)
        XCTAssertEqual(during.runningSince, 300)
        let budget = try XCTUnwrap(registry.registeredAudioSessionPhase()?.reactivationState)
        XCTAssertEqual(budget.basePhase, .awaitingActivation)
        XCTAssertNotNil(budget.cutoffArmTicket)
        let request = try claimGraphAudioCall(registry, lane: fixture.lane, reactivation)
        fixture.clock.set(400)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        let after = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
        XCTAssertEqual(after.budget.stageIdentity, before.budget.stageIdentity)
        XCTAssertEqual(after.effectiveElapsed(at: 400), 200, "setActive调用必须消耗同stage")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.process.identity.configurationGeneration, 1)
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.reactivationState?.basePhase, .activatedAwaitingFirstProgress)
        XCTAssertNil(registry.registeredAudioSessionPhase()?.reactivationState?.cutoffArmTicket)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected)
    }

    func testResetWhileSamplerRunningRetiresOnlyOriginalLateRecord() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token),
              let observation = handoff.routeObservation, let source = handoff.sampler else { return XCTFail("真实sampler缺失") }
        let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
        _ = try capturedResetRoot(registry)
        XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot([])).disposition, .settled)
        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled), "旧getter返回必须收敛准确原record")
        XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
        XCTAssertFalse(testRouteGate(registry: registry))
    }

    func testOrdinaryDeadlineAndArmRemainOwnedThroughStabilityWindowUntilCommit() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token),
              let observation = handoff.routeObservation, let source = handoff.sampler else { return XCTFail("真实sampler缺失") }
        let arm = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot())
        let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
        XCTAssertTrue(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
        XCTAssertEqual(registry.ordinaryRouteDeadlineArmSnapshot(), arm, "样本成功不能提前完成尚在120ms稳定期的D")
        _ = try capturedResetRoot(registry)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute?.timerArmIdentity,
            arm.armNonce)
    }

    func testCoalescedBeganEndedResetCarriesPostStageOnlyThroughFirstBeganAndKeepsRemainingDormant() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        try fixture.activateResetAndCommit()
        let registry = fixture.registry
        let stage = try XCTUnwrap(registry.postConfigurationRouteDeadlineSnapshot())
        registry.executor.sync {
            fixture.clock.set(200)
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.clock.set(300)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            fixture.clock.set(400)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            fixture.clock.set(500)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        let inherited = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint)
        let carried = try XCTUnwrap(inherited.carriedPostConfigurationStage)
        XCTAssertEqual(carried.remainingEffectiveTime, 2_999_999_900, "ended事实不能在没有合法attempt时恢复stage")
        XCTAssertEqual(carried.sourceStageIdentity, stage.budget.stageIdentity)
        XCTAssertEqual(carried.originStageIdentity, stage.budget.stageIdentity)
        XCTAssertNil(registry.postConfigurationRouteDeadlineSnapshot(), "原stage须转入唯一carried约束")
        fixture.clock.set(1_000)
        _ = try capturedResetRoot(registry)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint, inherited)
    }

    func testResetConsumesAccurateOrdinaryDeadlineArmAndNewRootCannotRenewInheritedBoundary() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("必须从真实普通交接建立D与arm")
        }
        let deadline = try XCTUnwrap(handoff.routeDeadline)
        let firstArm = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot())
        XCTAssertEqual(firstArm.ticketIdentity, deadline.identity)
        XCTAssertNotEqual(firstArm.armNonce, deadline.identity.deadlineNonce, "不能拿D nonce冒充arm")
        let rearmed = try XCTUnwrap(registry.rearmOutputOrdinaryRouteDeadline(firstArm))
        XCTAssertNotEqual(rearmed.arm, firstArm)
        XCTAssertNil(try registry.rearmOutputOrdinaryRouteDeadline(firstArm))
        fixture.clock.set(200)
        _ = try capturedResetRoot(registry)
        let inherited = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint)
        XCTAssertEqual(inherited.ordinaryAbsolute?.ticketIdentity, deadline.identity)
        XCTAssertEqual(inherited.ordinaryAbsolute?.deadlineInstant, deadline.deadlineInstant)
        XCTAssertEqual(inherited.ordinaryAbsolute?.timerArmIdentity, rearmed.arm.armNonce)
        XCTAssertNil(rawOrdinaryRouteDeadlineArm(registry), "原pending ordinary arm须移入唯一draining约束")
        XCTAssertEqual(registry.ordinaryRouteDeadlineArmSnapshot()?.armNonce, rearmed.arm.armNonce,
            "公开投影须从唯一inherited约束回退读取")
        let inheritedRearm = try XCTUnwrap(registry.rearmOutputOrdinaryRouteDeadline(rearmed.arm))
        XCTAssertEqual(inheritedRearm.arm.ticketIdentity, deadline.identity)
        XCTAssertEqual(inheritedRearm.notAfterInstant, deadline.deadlineInstant)
        XCTAssertNotEqual(inheritedRearm.arm.armNonce, rearmed.arm.armNonce)
        XCTAssertNil(try registry.rearmOutputOrdinaryRouteDeadline(rearmed.arm))
        fixture.clock.set(300)
        _ = try capturedResetRoot(registry)
        let afterNewRoot = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint)
        XCTAssertEqual(afterNewRoot.ordinaryAbsolute?.ticketIdentity, inherited.ordinaryAbsolute?.ticketIdentity)
        XCTAssertEqual(afterNewRoot.ordinaryAbsolute?.deadlineInstant, inherited.ordinaryAbsolute?.deadlineInstant)
        XCTAssertEqual(afterNewRoot.ordinaryAbsolute?.timerArmIdentity, inheritedRearm.arm.armNonce)
        XCTAssertEqual(afterNewRoot.carriedPostConfigurationStage, inherited.carriedPostConfigurationStage)
    }

    func testResetAtInheritedOrdinaryDeadlineImmediatelyPoisonsDuringIngressConsumption() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token),
              let deadline = handoff.routeDeadline else { return XCTFail("真实ordinary D缺失") }
        fixture.clock.set(deadline.deadlineInstant)
        _ = try capturedResetRoot(registry)
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true, "reset不能续杯已经到界的ordinary D")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
    }

    func testRetainedResetBeginsConfigurationWithProofBindingLeaseAndRenewedWorkGroupAtomically() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        _ = try capturedResetRoot(registry)
        let preRoute = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        if let prepare = original.sourceTask {
            XCTAssertEqual(try registry.retireOutputControlRecord(prepare), .retired(followUp: nil))
        }
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: original.contextNonce,
            reason: .recovery, at: fixture.stable.acquisition.clock.read(), teardown: true))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let teardown = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        XCTAssertNotNil(fixture.coordinator.completeTeardown(teardown, backend: fixture.lifecycle.backendIdentity,
            contextNonce: predecessor.contextNonce))
        XCTAssertEqual(try registry.retireOutputControlRecord(teardown), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let originalResource = try XCTUnwrap(registry.ownedResourceSnapshot())
        XCTAssertEqual(retained.phase, .pendingSuccessorLease)
        XCTAssertNil(try registry.issueOutputDrainProof(owner: owner, kind: .reset), "retained proof不能独立发行")
        let command = try XCTUnwrap(registry.beginRetainedOutputResetConfiguration(owner: owner,
            mandatorySuffix: 3_000_000_000))
        let configured = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let binding = try XCTUnwrap(configured.systemRecoveryBinding)
        XCTAssertEqual(registry.registeredOutputDrainProof(), .reset(binding.resetDrainProof))
        XCTAssertEqual(binding.resetPreRouteDeadlineTicket.identity, preRoute.ticketIdentity)
        XCTAssertEqual(configured.parentDeadline, retained.parentDeadline)
        XCTAssertEqual(configured.reservation.ownerGroup, retained.reservation.ownerGroup)
        XCTAssertNotEqual(configured.reservation.workGroup, retained.reservation.workGroup)
        XCTAssertEqual(command.group, configured.reservation.workGroup)
        guard case .lease(let session, let leaseID, let monitor, _) = originalResource.payload,
              case .lease(let nextSession, let nextLeaseID, let nextMonitor, _) = registry.ownedResourceSnapshot()?.payload else {
            return XCTFail("retained配置必须继续持有原lease/monitor")
        }
        XCTAssertEqual(nextSession, session)
        XCTAssertEqual(nextLeaseID, leaseID)
        XCTAssertEqual(nextMonitor, monitor)
        let categoryCompletion = try graphAudioCall(registry, lane: fixture.lane, command, .configuration(.categorySucceeded))
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.configurationProgress,
            .awaitingMultichannel(actualPolicy: .longFormAudio, preferredFailure: nil))
        XCTAssertNil(binding.inactiveConfigurationReceipt)
        XCTAssertNil(registry.phase(of: command))
        let multichannel = try XCTUnwrap(categoryCompletion.followUp)
        let multichannelRequest = try claimGraphAudioCall(registry, lane: fixture.lane, multichannel)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt,
            "SDK尚未返回不得签receipt")
        let multichannelCompletion = try completeGraphAudioCall(registry, lane: fixture.lane,
            multichannelRequest, .configuration(.multichannelCapability(true)))
        XCTAssertEqual(multichannelCompletion.disposition, .accepted)
        let receipt = try XCTUnwrap(registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt)
        XCTAssertEqual(receipt.actualPolicy, .longFormAudio)
        XCTAssertEqual(receipt.multichannelCapability, true)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: multichannelRequest.permit,
            result: .configuration(.multichannelCapability(true))), lane: fixture.lane)), .rejected, "原terminal只签一次receipt")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt, receipt)
        XCTAssertNil(registry.phase(of: multichannel))
        let activation = try XCTUnwrap(multichannelCompletion.followUp)
        let activationCompletion = try graphAudioCall(registry, lane: fixture.lane, activation, .activation(nil))
        XCTAssertEqual(activationCompletion.disposition, .accepted)
        XCTAssertNotNil(activationCompletion.followUp, "原activate完成必须交付准确首sampler")
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.processReceipt?.identity.configurationGeneration, 2)
        XCTAssertNotNil(registry.postConfigurationRouteDeadlineSnapshot())
    }

    func testRetainedResetFinalCommandPreparationFailurePublishesNoProofBindingOrPhaseAndCleansOriginalGraph() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 256,
            initialNamespace: .controlTask)
        let fixture = try OutputGraphFixture(allocator: allocator)
        let registry = fixture.registry
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        _ = try capturedResetRoot(registry)
        if let prepare = original.sourceTask {
            XCTAssertEqual(try registry.retireOutputControlRecord(prepare), .retired(followUp: nil))
        }
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: original.contextNonce,
            reason: .recovery, at: fixture.stable.acquisition.clock.read(), teardown: true))
        let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(suspend.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: suspend, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertEqual(try registry.retireOutputControlRecord(suspend.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let teardown = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        XCTAssertNotNil(fixture.coordinator.completeTeardown(teardown, backend: fixture.lifecycle.backendIdentity,
            contextNonce: predecessor.contextNonce))
        XCTAssertEqual(try registry.retireOutputControlRecord(teardown), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))

        let originalReservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let previousPhase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        let cycleControlTaskCount = 1 + ReservedCleanupStage.allCases.reduce(into: UInt64(0)) {
            if originalReservation[$1].consumed { $0 += 1 }
        }
        let lastValueBeforeCandidate = UInt64.max - cycleControlTaskCount
        while try allocator.next(in: .controlTask) != lastValueBeforeCandidate {}
        XCTAssertNil(try registry.beginRetainedOutputResetConfiguration(owner: owner,
            mandatorySuffix: 3_000_000_000), "最终command身份失败不能安装局部候选")

        let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(failed.poisoned)
        XCTAssertEqual(failed.disposition, .releaseAfterTeardown)
        XCTAssertEqual(failed.owner?.reason, .terminal)
        XCTAssertNil(failed.systemRecoveryBinding)
        XCTAssertNil(failed.resetProof)
        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.identity, previousPhase.identity,
            "局部phase候选不能覆盖原准确phase")
        XCTAssertEqual(registry.cleanupReservationSnapshot()?.ticket, originalReservation.ticket,
            "失败不能安装局部renewed cycle")

        let terminal = try XCTUnwrap(failed.owner)
        let monitor = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(fixture.coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        XCTAssertEqual(registry.ownedDeactivationDisposition(),
            .invalidatedByMediaServicesReset(mediaServicesEpoch: registry.executor.safetyIngress.snapshot.mediaServicesEpoch))
        let release = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        runner = nil
        XCTAssertTrue(registry.complete(release))
        let terminalTask = try XCTUnwrap(registry.outputCleanupOwnerTask(terminal))
        XCTAssertTrue(registry.complete(terminalTask))
        XCTAssertTrue(registry.releaseCleanupReservation(originalReservation.ticket))
        XCTAssertEqual(registry.occupancy.groups, 0)
        XCTAssertEqual(registry.occupancy.safetySlots, 0)
        XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
    }

    func testGenericResourceProducerCannotStartWithoutManagedAdmissionContext() throws {
        for slot: ControlTaskSlot in [.acquire, .factory] {
            let registry = ControlTaskRegistry(allocator: .init())
            let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
            let reservation = try registry.reserveCleanup(resource: .session(session))
            setTestRouteGate(true, registry: registry)
            let task = try registry.enqueue(group: reservation.ticket.workGroup, slot: slot,
                policy: slot == .acquire ? .routeNeutral : .routeSpeculativeRateZero)
            XCTAssertFalse(registry.claimStart(task), "没有真实admission/creation context，SDK不得开始")
            XCTAssertNil(registry.outputResourceContextSnapshot())
        }
    }

    func testQuiescentAndTornDownSuccessorRenewFailurePreservesUnusedFinalOwnerAndCompletesCleanup() throws {
        for tornDown in [false, true] {
            for exhaustedBeforeCall in [false, true] {
                // 真实admission先完成lease/config/activation/route/factory，再只耗尽本用例针对的身份域。
                let exhaustedNamespace: PlaybackIdentityNamespace = exhaustedBeforeCall ? .activation : .controlTask
                let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 256,
                    initialNamespace: exhaustedNamespace)
                let fixture = try OutputGraphFixture(allocator: allocator)
                let registry = fixture.registry
                let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
                let prepare = try XCTUnwrap(installed.sourceTask)
                XCTAssertTrue(registry.claimStart(prepare))
                XCTAssertTrue(registry.completeOutputPrepare(prepare))
                XCTAssertNil(registry.phase(of: prepare), "成功prepare由typed completion消费原record")
                let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
                let backend = fixture.lifecycle.backendIdentity
                let lifecycle = fixture.lifecycle
                let coordinator = OutputCleanupCoordinator(registry: registry)
                let recovery = try XCTUnwrap(coordinator.begin(contextNonce: installed.contextNonce,
                    reason: .recovery, at: 100, teardown: tornDown))
                let ordinaryOwner = try XCTUnwrap(registry.outputCleanupOwnerTask(recovery))
                XCTAssertNotEqual(ordinaryOwner, reservation.task(for: .owner))
                let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
                XCTAssertTrue(registry.claimStart(stop.task))
                XCTAssertTrue(coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
                    directlyConfirmedRateZero: true, preparedPreserved: false)))
                let retirement = try XCTUnwrap(coordinator.advance(owner: recovery))
                XCTAssertTrue(registry.claimStart(retirement))
                XCTAssertTrue(coordinator.completeRetirement(retirement, lifecycle: lifecycle))
                XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
                XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
                if tornDown {
                    let teardown = try XCTUnwrap(coordinator.advance(owner: recovery))
                    let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
                    XCTAssertTrue(registry.claimStart(teardown))
                    XCTAssertNotNil(coordinator.completeTeardown(teardown, backend: backend, contextNonce: predecessor.contextNonce))
                    XCTAssertEqual(try registry.retireOutputControlRecord(teardown), .retired(followUp: nil))
                }
                XCTAssertTrue(registry.complete(ordinaryOwner))
                XCTAssertEqual(try registry.retireOutputControlRecord(ordinaryOwner), .retired(followUp: nil))
                let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
                XCTAssertEqual(retained.phase, tornDown ? .pendingSuccessorLease : .quiescentBackend)
                XCTAssertNil(registry.phase(of: reservation.task(for: .owner)))
                if exhaustedBeforeCall {
                    while !allocator.isExhausted { _ = try? allocator.next(in: .activation) }
                } else {
                    while try allocator.next(in: .controlTask) != UInt64.max {}
                }
                XCTAssertNil(try? registry.renewOutputCycle(contextNonce: retained.contextNonce))
                XCTAssertEqual(registry.cleanupReservationSnapshot()?.ticket, reservation.ticket)
                let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
                XCTAssertTrue(failed.poisoned)
                XCTAssertEqual(failed.budget?.anchorInstant, 100, "失败不续杯，保留首停止/清理anchor")
                let terminal = try XCTUnwrap(failed.owner)
                XCTAssertEqual(registry.outputCleanupOwnerTask(terminal), reservation.task(for: .owner))
                if !tornDown {
                    let teardown = try XCTUnwrap(coordinator.advance(owner: terminal))
                    let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
                    XCTAssertTrue(registry.claimStart(teardown))
                    XCTAssertNotNil(coordinator.completeTeardown(teardown, backend: backend, contextNonce: predecessor.contextNonce))
                }
                let monitor = try XCTUnwrap(coordinator.advance(owner: terminal))
                XCTAssertTrue(registry.claimStart(monitor))
                XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
                let deactivate = try XCTUnwrap(coordinator.advance(owner: terminal))
                XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
                let release = try XCTUnwrap(coordinator.advance(owner: terminal))
                var runner = registry.claimOwnedResourceReleaseRunner(release)
                XCTAssertNotNil(runner)
                runner = nil
                XCTAssertTrue(registry.complete(release))
                XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
                XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
                XCTAssertEqual(registry.occupancy.groups, 0)
                XCTAssertEqual(registry.occupancy.safetySlots, 0)
                XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
            }
        }
    }

    func testRetainOwnerKeepsFinalReservationAndTerminalUpgradeJoinsExactRunningOwner() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let initial = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let reserved = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let recovery = try XCTUnwrap(fixture.coordinator.begin(contextNonce: initial.contextNonce,
            reason: .recovery, at: 200, teardown: false))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(recovery))
        XCTAssertNotEqual(ownerTask, reserved.task(for: .owner), "可retain恢复不能先消费最终owner预签task")
        XCTAssertNil(registry.phase(of: reserved.task(for: .owner)))
        let stopTask = try XCTUnwrap(fixture.coordinator.advance(owner: recovery))
        XCTAssertEqual(registry.phase(of: ownerTask), .running)
        let terminal = try XCTUnwrap(fixture.coordinator.begin(contextNonce: initial.contextNonce,
            reason: .stop, at: 300))
        XCTAssertNil(registry.outputCleanupOwnerTask(recovery), "旧owner身份不能通过current查询续权")
        XCTAssertEqual(registry.outputCleanupOwnerTask(terminal), ownerTask)
        XCTAssertNil(registry.phase(of: reserved.task(for: .owner)), "在途owner升级只能join原record")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.budget?.anchorInstant, 200)
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertEqual(stop.task, stopTask)
        XCTAssertTrue(registry.claimStart(stopTask))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        let teardown = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        XCTAssertNotNil(fixture.coordinator.completeTeardown(teardown, backend: fixture.lifecycle.backendIdentity,
            contextNonce: predecessor.contextNonce))
        let monitor = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(fixture.coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let deactivate = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        runner = nil
        XCTAssertTrue(registry.complete(release))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertTrue(registry.releaseCleanupReservation(reserved.ticket))
    }

    func testRenewFailureBeforeOrDuringPreparationUsesOriginalReservationForCompleteFinalCleanup() throws {
        for exhaustedBeforeCall in [false, true] {
            let exhaustedNamespace: PlaybackIdentityNamespace = exhaustedBeforeCall ? .activation : .controlTask
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 128,
                initialNamespace: exhaustedNamespace)
            let fixture = try StableOutputFixture(allocator: allocator)
            let registry = fixture.registry
            let original = try XCTUnwrap(registry.cleanupReservationSnapshot())
            XCTAssertTrue(registry.seal(original.ticket.workGroup))
            let contextNonce = try XCTUnwrap(registry.outputResourceContextSnapshot()).contextNonce
            if exhaustedBeforeCall {
                while !allocator.isExhausted { _ = try? allocator.next(in: .activation) }
            } else {
                while try allocator.next(in: .controlTask) != UInt64.max {}
            }
            XCTAssertNil(try? registry.renewOutputCycle(contextNonce: contextNonce))
            XCTAssertTrue(allocator.isExhausted)
            XCTAssertEqual(registry.cleanupReservationSnapshot()?.ticket, original.ticket)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertTrue(context.poisoned)
            XCTAssertEqual(context.disposition, .releaseAfterTeardown)
            XCTAssertNotNil(context.budget, "耗尽后不能丢掉最后清理期限")
            XCTAssertNotNil(registry.phase(of: original.task(for: .owner)))
            let owner = try XCTUnwrap(context.owner)
            let coordinator = OutputCleanupCoordinator(registry: registry)
            let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
            XCTAssertTrue(registry.claimStart(monitor))
            XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
            let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
            XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
            let release = try XCTUnwrap(coordinator.advance(owner: owner))
            var runner = registry.claimOwnedResourceReleaseRunner(release)
            XCTAssertNotNil(runner)
            runner = nil
            XCTAssertTrue(registry.complete(release))
            XCTAssertTrue(registry.complete(original.task(for: .owner)))
            XCTAssertTrue(registry.releaseCleanupReservation(original.ticket))
            XCTAssertEqual(registry.occupancy.groups, 0)
            XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
        }
    }

    func testRenewCycleJoinsRetiredDescendantRecordsAndRemovesSealedDescendantGroupsAtomically() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let original = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let child = try registry.createGroup(resource: original.ticket.workGroup.resourceIdentity,
            parent: original.ticket.workGroup)
        let task = try registry.enqueue(group: child, slot: .accounting, policy: .routeNeutral)
        XCTAssertTrue(registry.claimStart(task))
        XCTAssertTrue(registry.complete(task))
        XCTAssertTrue(registry.seal(original.ticket.workGroup))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNil(try registry.renewOutputCycle(contextNonce: context.contextNonce),
            "terminal不是retired，旧descendant record尚在就不能换票")
        XCTAssertEqual(registry.cleanupReservationSnapshot()?.ticket, original.ticket)
        XCTAssertEqual(try registry.retireOutputControlRecord(task), .retired(followUp: nil))
        let renewed = try XCTUnwrap(registry.renewOutputCycle(contextNonce: context.contextNonce))
        XCTAssertNotEqual(renewed, original.ticket)
        XCTAssertEqual(registry.occupancy.groups, 2, "旧sealed descendant随同CAS退还，不遗留断开的group")
        XCTAssertThrowsError(try registry.enqueue(group: child, slot: .accounting, policy: .routeNeutral))
        XCTAssertThrowsError(try registry.enqueueReservedCleanup(original.ticket, stage: .owner))
    }

    func testManagedFactoryRejectsGenericOwnedResultInsteadOfLosingTypedJoinResponsibility() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let pending = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let ownership = OutputResourceOwnership(reservation: pending.reservation,
            contextNonce: pending.contextNonce, mediaServicesEpoch: 0, interruptionEpoch: 0,
            audioAdmissionFenceRevision: 0,
            payload: .monitor(.init(sessionIdentity: pending.sessionIdentity, lifecycle: 1,
                object: ResourceLifetimeSpy(ResourceLifetimeObservation(registry: registry)))))
        XCTAssertFalse(registry.completeWithOwnedResult(factory, ownership: ownership),
            "factory只接纳准确candidate/no-object typed结果，不接受任意资源包")
        XCTAssertEqual(registry.phase(of: factory), .running)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: nil))
    }

    func testGenericFactoryCompletionCannotInventNoObjectReceipt() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        XCTAssertFalse(registry.complete(factory), "generic completion不能代替准确factory no-object结果")
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .rejected)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: nil))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingSuccessorLease)
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
    }

    func testFactoryCandidateRemainsOwnedByOriginalRecordWhenInstallAndCleanupPreparationFail() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let claim = try XCTUnwrap(rebase.successorClaim)
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(claim))
        XCTAssertTrue(registry.claimStart(factory))
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let blockedPrepare = try registry.enqueue(group: reservation.ticket.workGroup, slot: .prepare, policy: .routeSpeculativeRateZero)
        let blockedTeardown = try registry.enqueue(group: reservation.ticket.ownerGroup, slot: .teardown, policy: .safetyBypass)
        var candidate: ResourceLifetimeSpy? = ResourceLifetimeSpy(ResourceLifetimeObservation(registry: registry))
        weak var weakCandidate = candidate
        _ = try? registry.completeOutputFactory(factory, candidate: candidate)
        candidate = nil
        XCTAssertNotNil(weakCandidate, "安装与fallback准备都失败仍必须由原record持有准确candidate，不得锁外丢失")
        XCTAssertFalse(try registry.completeOutputFactory(factory, candidate: nil),
            "原候选已归档，二次无对象完成不能覆盖尚未settle的责任")
        XCTAssertNotNil(weakCandidate)
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .rejected)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingCreation,
            "无可安装的清理命令时不能半提交predecessor")
        XCTAssertNotNil(registry.phase(of: reservation.task(for: .owner)), "准备失败的终态owner仍有真实父record")
        XCTAssertEqual(try registry.retireOutputControlRecord(blockedPrepare), .retired(followUp: nil))
        XCTAssertTrue(registry.claimStart(blockedTeardown))
        XCTAssertTrue(registry.complete(blockedTeardown))
        XCTAssertEqual(try registry.retireOutputControlRecord(blockedTeardown), .retired(followUp: nil))
        XCTAssertTrue(try registry.settleOutputFactory(factory))
        XCTAssertFalse(try registry.settleOutputFactory(factory), "准确结果只能转移一次")
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(predecessor.phase, .predecessorCleanup)
        let teardown = try XCTUnwrap(predecessor.teardown)
        XCTAssertTrue(registry.claimStart(teardown))
        var disposal = registry.completeOutputTeardown(teardown, backendIdentity: try XCTUnwrap(predecessor.candidateBackendIdentity),
            contextNonce: predecessor.contextNonce)
        XCTAssertNotNil(disposal)
        XCTAssertNotNil(weakCandidate, "准确teardown之后先交付锁外disposal runner")
        disposal = nil
        XCTAssertNil(weakCandidate, "runner释放才释放候选对象")
        weakCandidate = nil
    }

    func testResetCommitGenerationMismatchPoisonsWithoutCompletingPreRouteOrPublishingStage() throws {
        let allocator = PlaybackIdentityAllocator()
        let fixture = try ResetAcquiringOutputFixture(allocator: allocator)
        try fixture.configureAndHandoff()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce))
        let request = try claimGraphAudioCall(registry, lane: fixture.lane, activation)
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 1)
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
        XCTAssertEqual(completion.disposition, .failed)
        XCTAssertNil(completion.followUp)
        let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(failed.poisoned)
        XCTAssertEqual(failed.owner?.reason, .terminal)
        XCTAssertEqual(failed.disposition, .releaseAfterTeardown)
        XCTAssertNotNil(registry.resetPreRouteDeadlineSnapshot(), "失败不能冒充commit完成pre-route")
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertNil(registry.outputRouteObservationSnapshot())
        guard case .requiresDeactivate(.returnedSuccess(let call)) = registry.ownedDeactivationDisposition() else {
            return XCTFail("后继generation失败不能回滚原returnedSuccess清理责任")
        }
        XCTAssertEqual(call.record, activation)
    }

    func testPostConfigurationBoundaryClaimsTimeoutWithoutTimerAndRetainsOriginalSamplerRecord() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        try fixture.activateResetAndCommit()
        let registry = fixture.registry
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("缺少post pending") }
        let source = try XCTUnwrap(pending.sampler)
        XCTAssertNotNil(pending.ticket)
        fixture.clock.set(3_000_000_100)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.claim(source, lane: fixture.lane, family: .sampler)), .rejected)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned, "等于stage 3秒时，claim自身必须让timeout owner胜出")
        XCTAssertEqual(context.owner?.reason, .terminal)
        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled))
        XCTAssertNil(pending.deadline)
        XCTAssertFalse(testRouteGate(registry: registry))
    }

    func testResetCommitActivationPublishesOneGenerationAndStableCASRebasesAndClearsBinding() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let binding = try XCTUnwrap(context.systemRecoveryBinding)
        let activation = try XCTUnwrap(registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce),
            "inactive交接后必须由独立reset-purpose activation前进")
        let request = try claimGraphAudioCall(registry, lane: fixture.lane, activation)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot(), "未返回的调用不能提升inactive候选")
        let completion = try completeGraphAudioCall(registry, lane: fixture.lane, request, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected, "同incarnation只能递增一次")
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot()?.identity.configurationGeneration, 1)
        XCTAssertNil(registry.resetPreRouteDeadlineSnapshot(), "准确commit success才完成pre-route票")
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("缺少post-config pending") }
        XCTAssertNil(pending.deadline, "reset post-config不能偷建ordinary绝对D")
        let observation = try XCTUnwrap(pending.ticket)
        XCTAssertEqual(observation.configurationTransitionIdentity, .reset(binding.incarnation.identity))
        let source = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(pending.sampler, source)
        let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
        XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        let stability = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
        XCTAssertNotNil(stability.authority.postConfigurationStageIdentity)
        XCTAssertNil(try registry.commitOutputRouteStability(stability))
        fixture.clock.set(fixture.clock.read() + 120_000_000)
        let stable = try XCTUnwrap(registry.commitOutputRouteStability(stability))
        let rebased = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNil(rebased.systemRecoveryBinding)
        XCTAssertNil(rebased.pendingReset)
        XCTAssertNotEqual(rebased.contextNonce, context.contextNonce)
        XCTAssertEqual(rebased.retainedRebase?.stableCommit, stable)
        XCTAssertNotNil(rebased.retainedRebase?.successorClaim)
        XCTAssertTrue(testRouteGate(registry: registry))
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected)
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot()?.identity.configurationGeneration, 1)
    }

    func testInstalledNonAllocatorSafetyFailureUsesOriginalTerminalCleanupChain() throws {
        let allocator = PlaybackIdentityAllocator()
        let fixture = try OutputGraphFixture(allocator: allocator)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
            monitorLifecycle: 1, notificationRevision: 1, reasonBits: 128, topologyChangeHint: false,
            outputConfigurationChanged: false, observedRoute: nil))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .invalidEvidence)
        XCTAssertFalse(allocator.isExhausted)
        let owner = try XCTUnwrap(try? fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 200),
            "非allocator sticky failure也必须接管原清理票")
        XCTAssertEqual(owner.reason, .terminal)
        XCTAssertTrue(try XCTUnwrap(registry.outputResourceContextSnapshot()).poisoned)
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertEqual(try fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 201), owner)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        let teardown = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        XCTAssertNotNil(fixture.coordinator.completeTeardown(teardown, backend: fixture.lifecycle.backendIdentity,
            contextNonce: predecessor.contextNonce))
        let monitor = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(fixture.coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let deactivate = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        var runner: OwnedOutputResourceRunner? = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertNotNil(runner)
        runner = nil
        XCTAssertTrue(registry.complete(release))
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .invalidEvidence)
    }

    func testResetInactiveConfigurationHandsOffWithoutActivationOrRetiringPreRouteClock() throws {
        let fixture = try ResetAcquiringOutputFixture()
        let registry = fixture.registry
        try fixture.acceptLease()
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let binding = try XCTUnwrap(original.resetAcquisitionBinding)
        let parent = try XCTUnwrap(original.parentDeadline)
        let category = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(contextNonce: original.contextNonce, parent: parent),
            "reset acquisition必须允许准确原proof/binding的inactive配置")
        let categoryCompletion = try graphAudioCall(registry, lane: fixture.lane, category, .configuration(.categorySucceeded))
        XCTAssertNil(registry.phase(of: category))
        let multichannel = try XCTUnwrap(categoryCompletion.followUp)
        let multichannelCompletion = try graphAudioCall(registry, lane: fixture.lane, multichannel,
            .configuration(.multichannelCapability(true)))
        XCTAssertEqual(multichannelCompletion.disposition, .accepted)
        XCTAssertNil(multichannelCompletion.followUp, "reset初次inactive配置等待真实handoff")
        XCTAssertNil(registry.phase(of: multichannel))
        XCTAssertNil(try registry.beginOutputAcquisitionActivation(contextNonce: original.contextNonce))
        XCTAssertNotNil(registry.registeredAudioSessionPhase()?.inactiveReceipt)
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        let before = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        fixture.clock.set(2_000_000_100)
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("inactive交接失败") }
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(context.phase, .pendingSuccessorLease)
        XCTAssertEqual(context.resetProof, binding.proof)
        XCTAssertNil(context.acquisitionDeadline)
        XCTAssertNil(registry.phase(of: fixture.acquire))
        XCTAssertNil(handoff.sampler)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot(), "inactive交接不能提前提升权威generation")
        let phase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        XCTAssertEqual(phase.incarnation?.drainProof, binding.proof)
        XCTAssertEqual(phase.incarnation?.baseConfigurationGeneration, 0)
        XCTAssertEqual(phase.identity.contextNonce, context.contextNonce)
        XCTAssertEqual(phase.resetBinding, binding.binding)
        let after = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(after.ticketIdentity, before.ticketIdentity)
        XCTAssertEqual(after.boundaryEffectiveElapsed, before.boundaryEffectiveElapsed)
        XCTAssertEqual(after.effectiveElapsed(at: fixture.clock.read()), 2_000_000_000)
        guard case .coldStart(let inherited) = context.parentDeadline else { return XCTFail("原parent丢失") }
        XCTAssertEqual(inherited.identity, fixture.parentIdentity)
        XCTAssertEqual(inherited.accumulatedEffectiveTime, 2_000_000_000)
    }

    func testInitialResetRootCannotUseOrdinaryAcquisitionAdmission() throws {
        let registry = ControlTaskRegistry(allocator: .init())
        _ = try capturedResetRoot(registry)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 0, cap: 40_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        XCTAssertNil(try registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000), "不能绕过真实reset proof与同parent边界")
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    // 首reset消费必须已经拥有有效票；不能等旧acquire或backend drain后重锚。
    func testFirstSessionResetMaterializesDeadlineBeforeDrainAndTransfersSameTicketToNewRoot() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        registry.executor.sync {
            fixture.clock.set(200)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            fixture.clock.set(220)
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.clock.set(270)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
            fixture.clock.set(300)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                XCTFail("首票物化不能同时执行目标")
            }
        }
        let first = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot(), "drain前必须有完整有效state")
        let binding = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetPreRouteBinding)
        XCTAssertEqual(first.accumulatedEffectiveTime, 50)
        XCTAssertEqual(first.runningSince, 300, "ended(false)不再是物理冻结")
        XCTAssertEqual(first.boundaryEffectiveElapsed, 12_000_000_000)
        XCTAssertNotNil(first.deadlineArm)
        XCTAssertNil(registry.registeredOutputDrainProof(), "首票不能伪造尚未完成的drain")
        registry.executor.sync {
            fixture.clock.set(400)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        let next = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(next.ticketIdentity, first.ticketIdentity)
        XCTAssertEqual(next.accumulatedEffectiveTime, 150)
        XCTAssertEqual(next.boundaryEffectiveElapsed, first.boundaryEffectiveElapsed)
        XCTAssertEqual(next.deadlineArm, first.deadlineArm, "仅换root不能换稳定边界的arm")
        XCTAssertNotEqual(registry.outputResourceContextSnapshot()?.resetPreRouteBinding, binding)
        XCTAssertNil(try registry.freezeOutputResetPreRouteClock(binding), "旧binding永久无权")
    }

    func testAcquisitionRejectsMissingOrUnpayableResetSuffixBeforeReservation() throws {
        for suffix: UInt64 in [0, 40_000_000_000, .max] {
            let registry = ControlTaskRegistry(allocator: .init())
            let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
            let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
                identity: .init(sessionIdentity: session, nonce: 1), kind: .coldStart, originInstant: 0,
                cap: 40_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
            XCTAssertNil(try registry.beginOutputAcquisition(session: session, parent: parent,
                resetRecoveryMandatorySuffix: suffix))
            XCTAssertNil(registry.cleanupReservationSnapshot())
        }
    }

    func testLiveResetClockConsumesInterruptionOnlyWindowAndTimesOutDuringDrain() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        registry.executor.sync {
            fixture.clock.set(200)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        let first = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        registry.executor.sync {
            fixture.clock.set(220)
            registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            fixture.clock.set(270)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        let frozen = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(frozen.accumulatedEffectiveTime, 20)
        XCTAssertNil(frozen.runningSince)
        XCTAssertNil(frozen.deadlineArm)
        registry.executor.sync {
            fixture.clock.set(300)
            registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: false))
            fixture.clock.set(320)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        let resumed = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(resumed.accumulatedEffectiveTime, 40)
        XCTAssertEqual(resumed.runningSince, 320)
        XCTAssertNotEqual(resumed.deadlineArm, first.deadlineArm)
        registry.executor.sync {
            fixture.clock.set(12_000_000_280)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            _ = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true, "消费恰到界必须terminal赢，不能等drain")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.disposition, .releaseAfterTeardown)
        let terminalOwner = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertEqual(terminalOwner.reason, .terminal)
        XCTAssertNotNil(registry.outputCleanupOwnerTask(terminalOwner), "到界必须安装或join准确父owner record")
    }

    func testFirstResetCheckedPreparationFailurePublishesNoPartialBindingAndKeepsOwnedLease() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 100)
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
        let original = try XCTUnwrap(registry.ownedResourceSnapshot())
        while try allocator.next(in: .deadline) != .max {}
        registry.executor.sync {
            clock.set(200)
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            let result = registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                XCTFail("身份准备失败不能执行目标")
            }
            if case .rejected = result {} else { XCTFail("必须拒绝失败CAS") }
        }
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
        XCTAssertNil(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertNil(registry.outputResourceContextSnapshot()?.resetPreRouteBinding)
        XCTAssertEqual(registry.ownedResourceSnapshot()?.contextNonce, original.contextNonce)
        XCTAssertEqual(registry.ownedResourceSnapshot()?.reservation, original.reservation)
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.contextNonce, fixture.contextNonce)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.safetyIngressPending)
    }

    func testResetClockSettlesOriginalParentAndTighteningPastElapsedPoisonsOwner() throws {
        let fixture = try ResetAcquiringOutputFixture()
        let registry = fixture.registry
        let binding = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetAcquisitionBinding?.binding)
        XCTAssertTrue(registry.claimStart(fixture.acquire))
        fixture.clock.set(2_000_000_100)
        _ = try registry.freezeOutputResetPreRouteClock(binding)
        guard case .coldStart(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("原parent丢失")
        }
        XCTAssertEqual(parent.identity, fixture.parentIdentity)
        XCTAssertEqual(parent.accumulatedEffectiveTime, 2_000_000_000, "reset结算必须同步原parent，不能只更新边界副本")
        XCTAssertNil(parent.runningSince)
        XCTAssertNil(try registry.tightenOutputResetPreRouteBoundary(binding, mandatorySuffix: 39_000_000_000))
        let state = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(state.boundaryEffectiveElapsed, 1_000_000_000)
        XCTAssertEqual(state.mandatorySuffix, 39_000_000_000)
        XCTAssertEqual(state.accumulatedEffectiveTime, 2_000_000_000)
        XCTAssertNil(state.deadlineArm)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned, "收紧后已过界必须同CAS由timeout owner胜出")
        XCTAssertEqual(context.owner?.reason, .terminal)
        XCTAssertEqual(registry.phase(of: fixture.acquire), .cancelRequested, "running旧source仍join")
        XCTAssertTrue(registry.completeOutputAcquisitionWithoutLease(fixture.acquire))
    }

    func testResetBoundaryRejectsQueuedAcquireBeforeTimerAndKeepsExactNoInvocationProof() throws {
        let fixture = try ResetAcquiringOutputFixture()
        fixture.clock.set(10_000_000_100)
        XCTAssertFalse(fixture.registry.claimStart(fixture.acquire), "claim自身必须读唯一有效边界，不能等timer回调")
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned)
        XCTAssertEqual(context.owner?.reason, .terminal)
        XCTAssertEqual(context.acquisitionNoLeaseReceipt?.acquisitionTicket, fixture.acquire)
        XCTAssertEqual(context.acquisitionNoLeaseReceipt?.outcome, .canceledBeforeClaim)
        XCTAssertEqual(fixture.registry.phase(of: fixture.acquire), .terminal(.canceled))
    }

    func testHandoffGenerationMismatchPoisonsOriginalOwnerWithoutPublishingCandidate() throws {
        let allocator = PlaybackIdentityAllocator()
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 1)
        XCTAssertThrowsError(try registry.commitAcquisitionRelayAndContext(token))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned, "counter/base失配必须进入原资源sticky清理，不仅抛错后继续重试")
        XCTAssertEqual(context.disposition, .releaseAfterTeardown)
        XCTAssertEqual(context.owner?.reason, .terminal)
        XCTAssertNil(context.committedRelay)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertNil(registry.outputRouteObservationSnapshot())
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 3, "不得回滚或校准counter")
    }

    func testHandoffConsumesOneGenerationAndReplayCannotConsumeAnother() throws {
        let allocator = PlaybackIdentityAllocator()
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("交接失败") }
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot()?.identity.configurationGeneration, 1)
        guard case .rejected = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("旧token必须拒绝") }
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 2)
    }

    func testCandidateConfigurationDoesNotConsumeAuthoritativeGeneration() throws {
        let allocator = PlaybackIdentityAllocator()
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
        _ = try fixture.configureAndActivate()
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 1,
            "候选只能持有base+1预期值，不能消耗权威generation域")
    }

    func testHandoffPreparationFailureDoesNotConsumeAuthoritativeGeneration() throws {
        let allocator = PlaybackIdentityAllocator()
        let clock = OutputTestClock(UInt64.max - 5_000_000_001)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry, clock: clock)
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        clock.set(UInt64.max - 2_000_000_000)
        XCTAssertThrowsError(try registry.commitAcquisitionRelayAndContext(token)) {
            XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow)
        }
        XCTAssertEqual(registry.outputAcquisitionCommitSnapshot(), token)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertEqual(try allocator.next(in: .audioSessionConfigurationGeneration), 1,
            "交接准备失败必须发生在最后权威generation消费之前")
    }

    func testCanceledOrdinaryCandidateThenTwoResetIncarnationsCommitGenerationsOneAndTwoExactlyOnce() throws {
        let allocator = PlaybackIdentityAllocator()
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        let ordinary = try AcquiringOutputFixture(registry: registry, clock: clock)
        _ = try ordinary.configureAndActivate()
        let staleOrdinary = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot(), "普通候选尚未handoff，不能成为权威generation")

        _ = try capturedResetRoot(registry)
        XCTAssertEqual(try registry.commitAcquisitionRelayAndContext(staleOrdinary), .rejected,
            "reset后的普通候选票永久失权")
        let draining = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let session = draining.sessionIdentity
        let parent = try XCTUnwrap(draining.parentDeadline)
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let terminal = try XCTUnwrap(coordinator.begin(contextNonce: draining.contextNonce,
            reason: .stop, at: clock.read()))
        let monitor = try XCTUnwrap(coordinator.advance(owner: terminal))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let release = try XCTUnwrap(coordinator.advance(owner: terminal))
        var oldRunner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(oldRunner)
        oldRunner = nil
        XCTAssertTrue(registry.complete(release))
        guard case .reset(let firstProof) = try registry.issueOutputDrainProof(owner: terminal, kind: .reset) else {
            return XCTFail("普通候选原资源清空后必须签准确首reset proof")
        }
        XCTAssertEqual(firstProof.currentConfigurationGeneration, 0)
        let oldReservation = draining.reservation
        let terminalTask = try XCTUnwrap(registry.outputCleanupOwnerTask(terminal))
        XCTAssertTrue(registry.complete(terminalTask))
        XCTAssertTrue(registry.releaseCleanupReservation(oldReservation))

        let acquire = try XCTUnwrap(registry.beginResetOutputAcquisition(session: session, parent: parent,
            admission: .init(proof: firstProof, mandatorySuffix: 3_000_000_000,
                inheritedRouteAvailabilityConstraint: nil)))
        XCTAssertTrue(registry.claimStart(acquire))
        let acquiring = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let salt = try XCTUnwrap(ordinary.lane.makeEndpointSalt())
        XCTAssertNotNil(try registry.registerAudioSessionLease(acquire, salt: salt))
        let resetParent = try XCTUnwrap(registry.outputResourceContextSnapshot()?.parentDeadline)
        let firstCategory = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(
            contextNonce: acquiring.contextNonce, parent: resetParent))
        let firstCategoryCompletion = try graphAudioCall(registry, lane: ordinary.lane, firstCategory,
            .configuration(.categorySucceeded))
        XCTAssertNil(registry.phase(of: firstCategory))
        let firstMultichannel = try XCTUnwrap(firstCategoryCompletion.followUp)
        let firstConfigurationCompletion = try graphAudioCall(registry, lane: ordinary.lane, firstMultichannel,
            .configuration(.multichannelCapability(true)))
        XCTAssertEqual(firstConfigurationCompletion.disposition, .accepted)
        XCTAssertNil(firstConfigurationCompletion.followUp, "inactive reset配置等待准确handoff")
        XCTAssertNil(registry.phase(of: firstMultichannel))
        let firstRelay = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try registry.commitAcquisitionRelayAndContext(firstRelay) else {
            return XCTFail("首reset inactive交接失败")
        }
        let firstContext = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let firstActivation = try XCTUnwrap(registry.beginOutputResetConfigurationActivation(
            contextNonce: firstContext.contextNonce))
        let firstActivationRequest = try claimGraphAudioCall(registry, lane: ordinary.lane, firstActivation)
        let firstActivationCompletion = try completeGraphAudioCall(registry, lane: ordinary.lane, firstActivationRequest, .activation(nil))
        XCTAssertEqual(firstActivationCompletion.disposition, .accepted)
        XCTAssertNotNil(firstActivationCompletion.followUp)
        let firstReturned = AudioSessionBlockingCallReturned(permit: firstActivationRequest.permit, result: .activation(nil))
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(firstReturned, lane: ordinary.lane)), .rejected)
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot()?.identity.configurationGeneration, 1)
        XCTAssertNil(registry.phase(of: firstActivation))

        guard case .pending(let firstPending) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("首reset commit必须建立post getter")
        }
        let firstSample = try claimGraphRoute(registry, lane: ordinary.lane,
            observation: try XCTUnwrap(firstPending.ticket), source: try XCTUnwrap(firstPending.sampler))
        XCTAssertEqual(firstActivationCompletion.followUp, firstSample.source)
        XCTAssertEqual(try completeGraphRoute(registry, firstSample, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        let firstStability = try XCTUnwrap(registry.armOutputRouteStability(observation: firstSample.observation))
        clock.set(firstStability.deadlineInstant)
        _ = try XCTUnwrap(registry.commitOutputRouteStability(firstStability))
        let firstRebase = try XCTUnwrap(registry.outputResourceContextSnapshot()?.retainedRebase)
        XCTAssertTrue(registry.seal(try XCTUnwrap(registry.outputResourceContextSnapshot()).reservation.workGroup))
        XCTAssertNotNil(try registry.renewOutputCycle(contextNonce: firstRebase.contextNonce),
            "inactive handoff消费旧conversion后必须先轮换完整work ticket")
        let firstClaim = try XCTUnwrap(firstRebase.successorClaim)
        let firstFactory = try XCTUnwrap(registry.claimOutputSuccessor(firstClaim))
        XCTAssertTrue(registry.claimStart(firstFactory))
        XCTAssertTrue(try registry.completeOutputFactory(firstFactory,
            candidate: ResourceLifetimeSpy(ResourceLifetimeObservation(registry: registry))))
        XCTAssertEqual(try registry.retireOutputControlRecord(firstFactory), .retired(followUp: nil))

        let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        _ = try capturedResetRoot(registry)
        if let prepare = installed.sourceTask {
            XCTAssertEqual(try registry.retireOutputControlRecord(prepare), .retired(followUp: nil))
        }
        let secondOwner = try XCTUnwrap(coordinator.begin(contextNonce: installed.contextNonce,
            reason: .recovery, at: clock.read(), teardown: true))
        let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(suspend.task))
        XCTAssertTrue(coordinator.completeSuspend(.init(suspendTicket: suspend, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(coordinator.advance(owner: secondOwner))
        XCTAssertTrue(registry.claimStart(retirement))
        guard case .backend(_, let lifecycle?, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
            return XCTFail("第二incarnation前必须持有准确backend lifecycle")
        }
        XCTAssertTrue(coordinator.completeRetirement(retirement, lifecycle: lifecycle))
        XCTAssertEqual(try registry.retireOutputControlRecord(suspend.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let teardown = try XCTUnwrap(coordinator.advance(owner: secondOwner))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        XCTAssertNotNil(coordinator.completeTeardown(teardown, backend: lifecycle.backendIdentity,
            contextNonce: predecessor.contextNonce))
        XCTAssertEqual(try registry.retireOutputControlRecord(teardown), .retired(followUp: nil))
        let secondOwnerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(secondOwner))
        XCTAssertTrue(registry.complete(secondOwnerTask))
        XCTAssertEqual(try registry.retireOutputControlRecord(secondOwnerTask), .retired(followUp: nil))

        let secondCategory = try XCTUnwrap(registry.beginRetainedOutputResetConfiguration(owner: secondOwner,
            mandatorySuffix: 3_000_000_000))
        let secondCategoryCompletion = try graphAudioCall(registry, lane: ordinary.lane, secondCategory,
            .configuration(.categorySucceeded))
        XCTAssertNil(registry.phase(of: secondCategory))
        let secondMultichannel = try XCTUnwrap(secondCategoryCompletion.followUp)
        let secondConfigurationCompletion = try graphAudioCall(registry, lane: ordinary.lane, secondMultichannel,
            .configuration(.multichannelCapability(true)))
        XCTAssertEqual(secondConfigurationCompletion.disposition, .accepted)
        XCTAssertNil(registry.phase(of: secondMultichannel))
        let secondActivation = try XCTUnwrap(secondConfigurationCompletion.followUp)
        let secondActivationRequest = try claimGraphAudioCall(registry, lane: ordinary.lane, secondActivation)
        let secondActivationCompletion = try completeGraphAudioCall(registry, lane: ordinary.lane,
            secondActivationRequest, .activation(nil))
        XCTAssertEqual(secondActivationCompletion.disposition, .accepted)
        XCTAssertNotNil(secondActivationCompletion.followUp)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: secondActivationRequest.permit,
            result: .activation(nil)), lane: ordinary.lane)), .rejected)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(firstReturned, lane: ordinary.lane)), .rejected,
            "前一incarnation完整旧request不能在generation变化后复活")
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot()?.identity.configurationGeneration, 2)
    }

    func testResetAcquisitionAdmissionOwnsOriginalParentAndSingleEffectiveBoundaryState() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(clock: clock)
        let root = try capturedResetRoot(registry)
        let proof = try XCTUnwrap(registry.issueEmptyOutputResetDrainProof(root: root))
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 50, cap: 40_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        let acquire = try XCTUnwrap(registry.beginResetOutputAcquisition(session: session, parent: parent,
            admission: .init(proof: proof, mandatorySuffix: 30_000_000_000, inheritedRouteAvailabilityConstraint: nil)),
            "reset-mode admission必须一次安装原parent、唯一边界及binding")
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let reset = try XCTUnwrap(context.resetAcquisitionBinding)
        guard case .coldStart(let currentParent) = context.parentDeadline,
              case .coldStart(let originalParent) = parent else { return XCTFail("必须保留原cold-start parent") }
        XCTAssertEqual(currentParent.identity, originalParent.identity)
        XCTAssertEqual(currentParent.originInstant, originalParent.originInstant)
        XCTAssertEqual(currentParent.cap, originalParent.cap)
        XCTAssertEqual(currentParent.runningSince, 100, "reset准入启动同一个parent的特例有效时钟")
        XCTAssertEqual(reset.proof, proof)
        let state = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        XCTAssertEqual(state.ticketIdentity, reset.preRouteTicket.identity)
        XCTAssertEqual(state.boundaryEffectiveElapsed, 10_000_000_000)
        XCTAssertEqual(state.runningSince, 100)
        XCTAssertNotNil(state.deadlineArm)
        XCTAssertNil(context.acquisitionDeadline, "acquire自己5秒必须从实际claim才启动")
        XCTAssertTrue(registry.claimStart(acquire))
        clock.set(1_000_000_100)
        let frozen = try XCTUnwrap(registry.freezeOutputResetPreRouteClock(reset.binding))
        XCTAssertEqual(frozen.accumulatedEffectiveTime, 1_000_000_000)
        XCTAssertNil(frozen.runningSince)
        XCTAssertNil(frozen.deadlineArm)
        clock.set(2_000_000_100)
        let tightened = try XCTUnwrap(registry.tightenOutputResetPreRouteBoundary(reset.binding, mandatorySuffix: 32_000_000_000))
        XCTAssertEqual(tightened.ticketIdentity, state.ticketIdentity)
        XCTAssertEqual(tightened.boundaryEffectiveElapsed, 8_000_000_000)
        XCTAssertEqual(tightened.accumulatedEffectiveTime, frozen.accumulatedEffectiveTime)
        XCTAssertNil(tightened.deadlineArm)
        let resumed = try XCTUnwrap(registry.resumeOutputResetPreRouteClock(reset.binding))
        XCTAssertEqual(resumed.runningSince, clock.read())
        XCTAssertNotEqual(resumed.deadlineArm, state.deadlineArm)
        let unchanged = try XCTUnwrap(registry.tightenOutputResetPreRouteBoundary(reset.binding, mandatorySuffix: 1))
        XCTAssertEqual(unchanged.boundaryEffectiveElapsed, resumed.boundaryEffectiveElapsed)
        XCTAssertEqual(unchanged.mandatorySuffix, 32_000_000_000)
    }

    func testInitialEmptyResetUsesMaterializedRootSourceAndAdmissionPermanentlyInvalidatesIt() throws {
        let registry = ControlTaskRegistry()
        let root = try capturedResetRoot(registry)
        let proof = try XCTUnwrap(registry.issueEmptyOutputResetDrainProof(root: root), "真正empty root必须有合法的明确物化来源")
        XCTAssertEqual(proof.resultingResourceShape, .noResources)
        XCTAssertNil(proof.drainedSessionIdentity)
        XCTAssertEqual(try registry.issueEmptyOutputResetDrainProof(root: root), proof)
        XCTAssertEqual(registry.occupancy.groups, 0)
        let group = try registry.createGroup(resource: .session(.init(sessionID: 1, requestID: UUID())))
        XCTAssertTrue(registry.seal(group))
        XCTAssertTrue(registry.releaseGroup(group))
        XCTAssertNil(try registry.issueEmptyOutputResetDrainProof(root: root), "admission之后即使再次nil也不能重造旧来源")
        let nextRoot = try capturedResetRoot(registry)
        XCTAssertNil(try registry.issueEmptyOutputResetDrainProof(root: root))
        XCTAssertNotNil(try registry.issueEmptyOutputResetDrainProof(root: nextRoot))
    }

    func testInitialEmptyResetCannotIgnoreUnclaimedLateOwnedLeaseResult() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        let root = try capturedResetRoot(fixture.registry)
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertNil(try fixture.registry.issueEmptyOutputResetDrainProof(root: root))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .rejected,
            "未接管准确owned结果仍然负责真实lease，不能拿当前owner=nil当空")
    }

    func testLateSamplerAfterRecoveryCancellationRetiresExactOriginalResponsibility() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("交接失败") }
        let source = try XCTUnwrap(handoff.sampler)
        let observation = try XCTUnwrap(handoff.routeObservation)
        let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = try OutputCleanupCoordinator(registry: registry).begin(contextNonce: handoff.successorContextNonce, reason: .recovery, at: 200)
        XCTAssertEqual(registry.phase(of: source), .cancelRequested)
        XCTAssertFalse(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
        XCTAssertEqual(registry.phase(of: source), .terminal(.canceled), "结果不提交，但实际SDK责任已经结束，不得永远阻塞旧group")
        XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
        XCTAssertNil(try registry.armOutputRouteStability(observation: observation))
    }

    func testMonitorDeactivateAndReleaseTimeoutKeepOriginalRecordsJoinedAndPoisoned() throws {
        for stage in 1...3 {
            let fixture = try StableOutputFixture()
            let registry = fixture.registry
            let coordinator = OutputCleanupCoordinator(registry: registry)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .stop,
                at: fixture.acquisition.clock.read()))
            let budget = try XCTUnwrap(registry.outputResourceContextSnapshot()?.budget)
            let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
            let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
            XCTAssertTrue(registry.claimStart(monitor))
            var blocked = monitor
            var runner: OwnedOutputResourceRunner?
            var deactivationRequest: AudioSessionBlockingCallRequest?
            if stage >= 2 {
                XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
                blocked = try XCTUnwrap(coordinator.advance(owner: owner))
                deactivationRequest = try claimGraphAudioCall(registry, lane: fixture.lane, blocked)
            }
            if stage == 3 {
                XCTAssertEqual(try completeGraphAudioCall(registry, lane: fixture.lane,
                    try XCTUnwrap(deactivationRequest), .deactivation(.succeeded)).disposition, .settled)
                blocked = try XCTUnwrap(coordinator.advance(owner: owner))
                runner = registry.claimOwnedResourceReleaseRunner(blocked)
                XCTAssertNotNil(runner)
            }
            fixture.acquisition.clock.set(budget.deadlineInstant)
            XCTAssertTrue(registry.timeoutOutputCleanup(budget), "阶段\(stage)必须保留原绝对预算并发布poison")
            XCTAssertTrue(try XCTUnwrap(registry.outputResourceContextSnapshot()).poisoned)
            XCTAssertEqual(registry.phase(of: blocked), .running)
            XCTAssertFalse(registry.releaseCleanupReservation(reservation.ticket))
            XCTAssertNil(try coordinator.advance(owner: owner))
            let terminal = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
            if stage == 1 {
                XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
                blocked = try XCTUnwrap(coordinator.advance(owner: terminal))
                deactivationRequest = try claimGraphAudioCall(registry, lane: fixture.lane, blocked)
            }
            if stage < 3 {
                XCTAssertEqual(try completeGraphAudioCall(registry, lane: fixture.lane,
                    try XCTUnwrap(deactivationRequest), .deactivation(.succeeded)).disposition, .settled)
                blocked = try XCTUnwrap(coordinator.advance(owner: terminal))
                runner = registry.claimOwnedResourceReleaseRunner(blocked)
                XCTAssertNotNil(runner)
            }
            runner = nil
            XCTAssertTrue(registry.complete(blocked))
            XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
            XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        }
    }

    func testTwoRealQuiescentReprepareCyclesUseFreshStableWithoutSigningUnusedSuccessorClaim() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 256, initialNamespace: .nonce)
        let fixture = try OutputGraphFixture(allocator: allocator)
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let semantic = try XCTUnwrap(fixture.stable.stable.authority.semanticIdentity)
        let backend = fixture.lifecycle.backendIdentity
        var lifecycle = fixture.lifecycle
        for cycle in 1...2 {
            let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
            XCTAssertTrue(registry.claimStart(prepare))
            XCTAssertTrue(registry.completeOutputPrepare(prepare))
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let original = try XCTUnwrap(registry.cleanupReservationSnapshot())
            let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
                reason: .recovery, at: UInt64(cycle), teardown: false))
            let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
            XCTAssertTrue(registry.claimStart(stop.task))
            XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
                directlyConfirmedRateZero: true, preparedPreserved: false)))
            let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
            XCTAssertTrue(registry.claimStart(retirement))
            XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: lifecycle))
            XCTAssertNil(try registry.renewOutputCycle(contextNonce: context.contextNonce), "准确旧record尚在，不得轮换")
            XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
            XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
            let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
            XCTAssertTrue(registry.complete(ownerTask))
            XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
            let renewed = try XCTUnwrap(registry.renewOutputCycle(contextNonce: context.contextNonce))
            XCTAssertNotEqual(renewed, original.ticket)
            XCTAssertEqual(renewed.ownerGroup, original.ticket.ownerGroup)
            XCTAssertThrowsError(try registry.enqueue(group: original.ticket.workGroup, slot: .prepare, policy: .routeSpeculativeRateZero))
            XCTAssertThrowsError(try registry.enqueueReservedCleanup(original.ticket, stage: .owner))
            guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("第\(cycle)轮Q必须保留准确route authority供真实getter重验")
            }
            clock.set(clock.read() + 10)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: context.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 1,
                reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
                observedRoute: semantic))
            guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("第\(cycle)轮Q必须建立新pending getter")
            }
            let sample = try claimGraphRoute(registry, lane: fixture.lane, observation: try XCTUnwrap(pending.ticket),
                source: try XCTUnwrap(pending.sampler))
            XCTAssertTrue(try completeGraphRoute(registry, sample, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
            let stability = try XCTUnwrap(registry.armOutputRouteStability(observation: sample.observation))
            clock.set(stability.deadlineInstant)
            let freshStable = try XCTUnwrap(registry.commitOutputRouteStability(stability))
            if cycle == 2 {
                while try allocator.next(in: .nonce) != UInt64.max - 1 {}
            }
            let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
                stableCommit: freshStable, owner: owner),
                "Q在只剩一个nonce时只能换context身份，不能额外签无用途initialRetry")
            XCTAssertNil(rebase.successorClaim)
            let next = try XCTUnwrap(registry.reprepareQuiescentOutput(rebase), "Q必须用同backend及真实rebase建立新rate-0 prepare")
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.sourceTask, next)
            guard case .backend(let identity, let newLifecycle, _, _, _) = registry.ownedResourceSnapshot()?.payload else { return XCTFail("必须保留准确backend") }
            XCTAssertEqual(identity, backend)
            XCTAssertNotEqual(newLifecycle, lifecycle)
            lifecycle = try XCTUnwrap(newLifecycle)
            XCTAssertEqual(registry.occupancy.groups, 2)
            XCTAssertEqual(registry.occupancy.reservedSafetySlots, 8)
        }
    }

    func testRealStableClaimRebasesAndCreatesExactlyOneFactoryWithoutRawEpochAuthority() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil), "真实stable才能具名rebase并签一次lease claim")
        XCTAssertNotEqual(rebase.contextNonce, context.contextNonce)
        let claim = try XCTUnwrap(rebase.successorClaim)
        XCTAssertNotNil(try registry.claimOutputSuccessor(claim))
        XCTAssertNil(try registry.claimOutputSuccessor(claim))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingCreation)
        XCTAssertEqual(registry.occupancy.groups, 2)
    }

    func testInstalledInitialOriginBecomesExactReplacementAndTwoSuccessorRoundsCannotResignOrDoubleClaim() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let semantic = try XCTUnwrap(fixture.stable.stable.authority.semanticIdentity)
        var previousClaim: OutputSuccessorClaim?
        for round in 1...2 {
            let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let prepare = try XCTUnwrap(installed.sourceTask)
            XCTAssertTrue(registry.claimStart(prepare))
            XCTAssertTrue(registry.completeOutputPrepare(prepare))
            guard case .backend(_, let lifecycle?, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
                return XCTFail("第\(round)轮必须持有准确installed lifecycle")
            }
            let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: installed.contextNonce,
                reason: .recovery, at: UInt64(300 + round), teardown: true))
            let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
            XCTAssertTrue(registry.claimStart(suspend.task))
            XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: suspend, closeClaim: nil,
                directlyConfirmedRateZero: true, preparedPreserved: false)))
            let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
            XCTAssertTrue(registry.claimStart(retirement))
            XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: lifecycle))
            let retired = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(retired.phase, .predecessorCleanup,
                "已确定teardown时retirement确认必须同CAS进入predecessor，不能停在无lifecycle installed")
            XCTAssertEqual(retired.claimOrigin, .replacement(owner))
            XCTAssertNil(retired.teardown, "teardown command仍由advance在delivery/drain边界后准备")
            let teardown = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
            let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(predecessor.contextNonce, retired.contextNonce,
                "advance不能二次消费predecessor conversion或重签context")
            XCTAssertEqual(predecessor.claimOrigin, retired.claimOrigin)
            XCTAssertTrue(registry.claimStart(teardown))
            XCTAssertNotNil(fixture.coordinator.completeTeardown(teardown, backend: lifecycle.backendIdentity,
                contextNonce: predecessor.contextNonce))
            let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(retained.claimOrigin, .replacement(owner),
                "一旦真实backend安装并teardown，初始谱系必须收敛为准确replacement owner")
            XCTAssertEqual(try registry.retireOutputControlRecord(suspend.task), .retired(followUp: nil))
            XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
            XCTAssertEqual(try registry.retireOutputControlRecord(teardown), .retired(followUp: nil))
            let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
            XCTAssertTrue(registry.complete(ownerTask))
            XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
            XCTAssertNotNil(try registry.renewOutputCycle(contextNonce: retained.contextNonce))
            guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("第\(round)轮teardown后必须保留准确route authority供真实getter重验")
            }
            clock.set(clock.read() + 10)
            registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: retained.sessionIdentity,
                monitorLifecycle: open.monitorLifecycle, notificationRevision: open.routeObservationRevision + 1,
                reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
                observedRoute: semantic))
            guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else {
                return XCTFail("第\(round)轮闭门后必须由具名通知建立新pending getter")
            }
            let sample = try claimGraphRoute(registry, lane: fixture.lane, observation: try XCTUnwrap(pending.ticket),
                source: try XCTUnwrap(pending.sampler))
            XCTAssertTrue(try completeGraphRoute(registry, sample, snapshot: GraphRouteSnapshot.builtIn).disposition == .accepted)
            let stability = try XCTUnwrap(registry.armOutputRouteStability(observation: sample.observation))
            clock.set(stability.deadlineInstant)
            let freshStable = try XCTUnwrap(registry.commitOutputRouteStability(stability))
            let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
                stableCommit: freshStable, owner: owner))
            XCTAssertEqual(try registry.rebaseRetainedOutput(contextNonce: rebase.contextNonce,
                stableCommit: freshStable, owner: owner), rebase,
                "同一当前stable/owner的重复rebase只能返回原准确实例，不能重签claim")
            let claim = try XCTUnwrap(rebase.successorClaim)
            if let previousClaim { XCTAssertNil(try registry.claimOutputSuccessor(previousClaim)) }
            let factory = try XCTUnwrap(registry.claimOutputSuccessor(claim))
            XCTAssertNil(try registry.claimOutputSuccessor(claim), "同一successor claim只能消费一次")
            XCTAssertTrue(registry.claimStart(factory))
            XCTAssertTrue(try registry.completeOutputFactory(factory,
                candidate: ResourceLifetimeSpy(ResourceLifetimeObservation(registry: registry))))
            XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
            previousClaim = claim
        }
    }

    func testStableCommitRequiresRealSamplerAndFullLockedClockWindow() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("交接失败") }
        let observation = try XCTUnwrap(handoff.routeObservation)
        let source = try XCTUnwrap(handoff.sampler)
        XCTAssertNil(try registry.armOutputRouteStability(observation: observation))
        let claim = try claimGraphRoute(registry, lane: fixture.lane, observation: observation, source: source)
        let evidence = AudioSessionBlockingCallLane.project(GraphRouteSnapshot.builtIn,
            salt: try XCTUnwrap(claim.request.registration).salt)
        let completed = try completeGraphAudioCall(registry, lane: fixture.lane, claim.request, .route(evidence))
        XCTAssertEqual(completed.disposition, .accepted)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: claim.request.permit,
            result: .route(evidence)), lane: fixture.lane)), .rejected, "准确原request只能完成一次")
        let stability = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
        let semantic = try XCTUnwrap(stability.authority.semanticIdentity)
        XCTAssertEqual(semantic.ports, .builtIn)
        XCTAssertEqual(semantic.backend, .sampleBuffer)
        XCTAssertEqual(stability.deadlineInstant - stability.anchorInstant, 120_000_000)
        XCTAssertNil(try registry.commitOutputRouteStability(stability))
        fixture.clock.set(stability.deadlineInstant - 1)
        XCTAssertNil(try registry.commitOutputRouteStability(stability))
        fixture.clock.set(stability.deadlineInstant)
        let stable = try XCTUnwrap(registry.commitOutputRouteStability(stability))
        XCTAssertEqual(stable.authority.semanticIdentity, semantic)
        XCTAssertEqual(stable.authority.audioSessionActivationNonce, stability.authority.audioSessionActivationNonce)
        XCTAssertNil(try registry.commitOutputRouteStability(stability), "稳定票只能消费一次")
        XCTAssertTrue(testRouteGate(registry: registry))
    }

    func testUncommittedAcquisitionReceiptCannotAdvanceResetProofCurrentGeneration() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: fixture.contextNonce, reason: .stop, at: 100))
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner: OwnedOutputResourceRunner? = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertNotNil(runner)
        runner = nil
        XCTAssertTrue(registry.complete(release))
        guard case .reset(let proof) = try registry.issueOutputDrainProof(owner: owner, kind: .reset) else {
            return XCTFail("准确旧资源已清理，应签真实reset proof")
        }
        XCTAssertEqual(proof.currentConfigurationGeneration, 0, "未交接candidate receipt不是权威generation")
    }

    func testCompletedPauseUpgradedBeforeOwnerFinishCreatesNewSuspendAndBudgetAnchor() throws {
        let fixture = try OutputGraphFixture()
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(context.sourceTask)
        XCTAssertTrue(fixture.registry.claimStart(prepare))
        XCTAssertTrue(fixture.registry.completeOutputPrepare(prepare),
            "pause receipt只能在原真实producer终态后确认drain")
        _ = try fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .pause, at: 10)
        let old = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(fixture.registry.claimStart(old.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: old, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 20))
        let updated = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertNotEqual(updated.suspend?.task, old.task, "只有仍在途stop可join；已完成pause不可复用success")
        XCTAssertEqual(updated.budget?.anchorInstant, 20)
        XCTAssertEqual(try fixture.coordinator.advance(owner: owner), updated.suspend?.task)
    }

    func testExpiredAcquisitionRejectsConfigurationClaimAndHandoffBeforeTimerDelivery() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let deadline = try XCTUnwrap(context.acquisitionDeadline)
        let configuration = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(
            contextNonce: context.contextNonce, parent: fixture.parent))
        fixture.clock.set(deadline.deadlineInstant)
        XCTAssertFalse(registry.claimStart(configuration), "计时事件尚未投递也不得开始过期SDK调用")
        XCTAssertNil(try registry.beginOutputAcquisitionConfiguration(contextNonce: context.contextNonce, parent: fixture.parent))

        let ready = try AcquiringOutputFixture()
        _ = try ready.configureAndActivate()
        let token = try XCTUnwrap(ready.registry.outputAcquisitionCommitSnapshot())
        ready.clock.set(try XCTUnwrap(ready.registry.outputResourceContextSnapshot()?.acquisitionDeadline).deadlineInstant)
        XCTAssertEqual(try ready.registry.commitAcquisitionRelayAndContext(token), .rejected)
        XCTAssertNil(ready.registry.processAudioSessionReceiptSnapshot())
    }

    func testQueuedAcquisitionCancellationProducesExactNotInvokedEmptyProof() throws {
        let registry = ControlTaskRegistry()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 0, cap: 15_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        let acquire = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
        registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(OutputCleanupCoordinator(registry: registry).begin(contextNonce: context.contextNonce, reason: .terminal, at: 1))
        XCTAssertFalse(registry.claimStart(acquire))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.acquisitionNoLeaseReceipt,
            .init(acquisitionTicket: acquire, outcome: .canceledBeforeClaim))
        guard case .reset(let proof) = try registry.issueOutputDrainProof(owner: owner, kind: .reset) else {
            return XCTFail("排队原record取消应由同CAS签发not-invoked责任")
        }
        XCTAssertEqual(proof.resultingResourceShape, .noResources)
    }

    func testAcquisitionTimeoutJoinsRunningSourceAndLateLeaseInheritsOriginalCleanupBudget() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(clock: clock)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 0, cap: 15_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        let acquire = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
        XCTAssertNil(registry.outputResourceContextSnapshot()?.acquisitionDeadline)
        XCTAssertTrue(registry.claimStart(acquire))
        let deadline = try XCTUnwrap(registry.outputResourceContextSnapshot()?.acquisitionDeadline)
        XCTAssertEqual(deadline.anchorInstant, 100)
        XCTAssertEqual(deadline.deadlineInstant, 5_000_000_100)
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        clock.set(deadline.deadlineInstant)
        XCTAssertTrue(registry.timeoutOutputAcquisition(deadline))
        let timedOut = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(timedOut.poisoned)
        XCTAssertEqual(timedOut.disposition, .releaseAfterTeardown)
        XCTAssertEqual(timedOut.budget?.anchorInstant, deadline.deadlineInstant)
        XCTAssertEqual(registry.phase(of: acquire), .cancelRequested)
        XCTAssertFalse(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertNil(try registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
        let lifetime = ResourceLifetimeObservation(registry: registry)
        let proof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: acquire, sessionIdentity: session,
            leaseID: 1, contextNonce: reservation.contextNonce, ownershipNonce: 1)
        XCTAssertTrue(registry.completeWithOwnedResult(acquire, ownership: .init(reservation: reservation.ticket,
            contextNonce: reservation.contextNonce, mediaServicesEpoch: 0, interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
            payload: .lease(.init(leaseID: 1, object: ResourceLifetimeSpy(lifetime),
                monitor: .init(sessionIdentity: session, lifecycle: 1, object: ResourceLifetimeSpy(lifetime)),
                deactivation: .confirmedInactive(.reservation(proof)))))))
        clock.set(6_000_000_100)
        XCTAssertTrue(try registry.settleOutputAcquisition(acquire))
        let late = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(late.phase, .leaseOnlyCleanup)
        XCTAssertTrue(late.poisoned)
        XCTAssertEqual(late.parentDeadline, parent)
        XCTAssertEqual(late.budget, timedOut.budget)
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(late.owner)
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertNotNil(registry.claimOwnedResourceReleaseRunner(release))
    }

    func testExplicitNoLeaseCompletionProvidesEmptyDrainEvidenceWhileGenericCompleteCannot() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(clock: clock)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 0, cap: 15_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        let acquire = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
        XCTAssertTrue(registry.claimStart(acquire))
        registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(OutputCleanupCoordinator(registry: registry).begin(
            contextNonce: context.contextNonce, reason: .terminal, at: 200))
        XCTAssertFalse(registry.complete(acquire), "generic completion不能证明真实没有取得lease")
        XCTAssertNil(try registry.issueOutputDrainProof(owner: owner, kind: .reset))
        XCTAssertTrue(registry.completeOutputAcquisitionWithoutLease(acquire))
        guard case .reset(let proof) = try registry.issueOutputDrainProof(owner: owner, kind: .reset) else {
            return XCTFail("明确原source no-lease终态才能签发empty proof")
        }
        XCTAssertEqual(proof.resultingResourceShape, .noResources)
        XCTAssertEqual(registry.registeredOutputDrainProof(), .reset(proof))
        XCTAssertFalse(registry.releaseCleanupReservation(context.reservation),
            "准确no-lease仍不能越过尚未完成的最终owner")
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.claimStart(ownerTask))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertTrue(registry.releaseCleanupReservation(context.reservation))
        XCTAssertNil(registry.outputResourceContextSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testLeaseWithoutMonitorSkipsMonitorStopButRequiresLeaseRunnerAndFinalOwnerBeforeEmpty() throws {
        let fixture = try OwnedResourceFixture()
        let registry = fixture.registry
        let acquire = fixture.acquisition
        XCTAssertTrue(registry.claimStart(acquire))
        var lease: ResourceLifetimeSpy? = ResourceLifetimeSpy(fixture.lifetime)
        weak var weakLease: ResourceLifetimeSpy?
        weakLease = lease
        XCTAssertTrue(registry.completeWithOwnedResult(acquire, ownership: .init(
            reservation: fixture.reservation.ticket, contextNonce: fixture.reservation.contextNonce,
            mediaServicesEpoch: 0, interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
            payload: .lease(.init(leaseID: 1, object: try XCTUnwrap(lease), monitor: nil,
                deactivation: .confirmedInactive(.reservation(.init(acquisitionTicket: acquire,
                    sessionIdentity: fixture.session, leaseID: 1,
                    contextNonce: fixture.reservation.contextNonce, ownershipNonce: 1))))))))
        XCTAssertTrue(try registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(try registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 200))
        let release = try XCTUnwrap(coordinator.advance(owner: owner),
            "无monitor的合法lease不得虚构monitor-stop SDK工作")
        XCTAssertEqual(release, fixture.reservation.task(for: .leaseRelease))
        XCTAssertNil(try registry.beginOutputMonitorDelivery(contextNonce: context.contextNonce))
        XCTAssertNil(try registry.beginOutputMonitorStop(contextNonce: context.contextNonce))
        var runner = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release)) as OwnedOutputResourceRunner?
        XCTAssertNotNil(runner)
        lease = nil
        XCTAssertFalse(registry.releaseCleanupReservation(fixture.reservation.ticket),
            "runner强持有且原release record未终态时不得报告empty")
        XCTAssertTrue(registry.complete(release))
        XCTAssertFalse(registry.releaseCleanupReservation(fixture.reservation.ticket),
            "最终owner未完成时仍不得释放整张reservation")
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertTrue(registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertNotNil(weakLease)
        runner = nil
        XCTAssertNil(weakLease)
    }

    func testMonitorOnlyRequiresDeliveryACKStopAndRunnerTerminalBeforeEmpty() throws {
        let fixture = try OwnedResourceFixture()
        let registry = fixture.registry
        let acquire = fixture.acquisition
        XCTAssertTrue(registry.claimStart(acquire))
        var monitor: ResourceLifetimeSpy? = ResourceLifetimeSpy(fixture.lifetime)
        weak var weakMonitor: ResourceLifetimeSpy?
        weakMonitor = monitor
        XCTAssertTrue(registry.completeWithOwnedResult(acquire, ownership: .init(
            reservation: fixture.reservation.ticket, contextNonce: fixture.reservation.contextNonce,
            mediaServicesEpoch: 0, interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
            payload: .monitor(.init(sessionIdentity: fixture.session, lifecycle: 1,
                object: try XCTUnwrap(monitor))))))
        XCTAssertTrue(try registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .routeMonitorCleanup)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let delivery = try XCTUnwrap(registry.beginOutputMonitorDelivery(contextNonce: context.contextNonce))
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 200))
        XCTAssertNil(try coordinator.advance(owner: owner), "未ACK的delivery必须阻止monitor-stop登记")
        XCTAssertTrue(registry.acknowledgeOutputMonitorDelivery(delivery))
        let stop = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(stop))
        XCTAssertTrue(coordinator.completeMonitorStop(stop, lifecycle: try graphMonitorLifecycle(registry)))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release)) as OwnedOutputResourceRunner?
        XCTAssertNotNil(runner)
        monitor = nil
        XCTAssertFalse(registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertTrue(registry.complete(release))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertTrue(registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertNotNil(weakMonitor)
        runner = nil
        XCTAssertNil(weakMonitor)
    }

    func testHandoffClockOverflowCannotPublishAnyReceiptRelayOrRouteWindow() throws {
        let clock = OutputTestClock(UInt64.max - 5_000_000_001)
        let fixture = try AcquiringOutputFixture(clock: clock)
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        clock.set(UInt64.max - 2_000_000_000)
        XCTAssertThrowsError(try registry.commitAcquisitionRelayAndContext(token)) {
            XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow)
        }
        XCTAssertEqual(registry.outputAcquisitionCommitSnapshot(), token)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.committedRelay)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertNil(registry.outputRouteObservationSnapshot())
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingLeaseAcquisition)
        assertSameReservation(try XCTUnwrap(registry.cleanupReservationSnapshot()), reservation)
    }

    func testCommittedPendingKeepsOriginalWindowAndSamplerWhenFirstCallbackArrives() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("交接失败") }
        fixture.clock.set(1_000)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: token.relayIdentity.sessionIdentity,
            monitorLifecycle: token.relayIdentity.monitorLifecycle, notificationRevision: 1,
            reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false, observedRoute: nil))
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("缺少原pending") }
        XCTAssertEqual(pending.ticket, handoff.routeObservation)
        XCTAssertEqual(pending.deadline, handoff.routeDeadline, "首callback不能清掉/重锚已经存在的3秒窗口")
        XCTAssertEqual(pending.sampler, handoff.sampler)
        XCTAssertEqual(pending.latestNotificationRevision, 1)
        XCTAssertTrue(pending.resamplePending)
    }

    func testHandoffRetiresOriginalAcquisitionRecord() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("交接失败") }
        XCTAssertNil(registry.phase(of: token.relayIdentity.acquisitionTicket), "交接成功同CAS退休原acquisition记录")
    }

    func testHandoffUsesClockSampleInsideQueuedCASInsteadOfCallerInstant() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry)
        _ = try fixture.configureAndActivate()
        let expected = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        registry.executor.submit { entered.signal(); release.wait() }
        guard entered.wait(timeout: .now() + 3) == .success else { release.signal(); return XCTFail("未进入确定性队列屏障") }
        let finished = expectation(description: "交接CAS完成")
        registry.executor.submit {
            do {
                guard case .committed(let value) = try registry.commitAcquisitionRelayAndContext(expected) else {
                    XCTFail("交接失败"); finished.fulfill(); return
                }
                XCTAssertEqual(value.routeDeadline?.identity.deadlineAnchorInstant, 500)
                XCTAssertEqual(value.routeDeadline?.deadlineInstant, 3_000_000_500)
            } catch { XCTFail("交接异常：\(error)") }
            finished.fulfill()
        }
        clock.set(500)
        release.signal()
        wait(for: [finished], timeout: 3)
    }

    func testAcquisitionRoutePendingBeforeHandoffHasNoTicketsAndPreservesFoldedFields() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(clock: clock)
        let fixture = try AcquiringOutputFixture(registry: registry)
        let session = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sessionIdentity)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: session, monitorLifecycle: 1,
            notificationRevision: 1, reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false, observedRoute: nil))
        _ = registry.outputResourceContextSnapshot() // 确定性消费首窗口，再发送后继，不能依赖调度合并。
        clock.set(200)
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: session, monitorLifecycle: 1,
            notificationRevision: 2, reasonBits: 2, topologyChangeHint: false, outputConfigurationChanged: true, observedRoute: nil))
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("acquisition也必须持有同一pending state") }
        XCTAssertNil(pending.ticket)
        XCTAssertNil(pending.deadline)
        XCTAssertNil(pending.sampler)
        XCTAssertEqual(pending.firstEventObservedInstant, 100)
        XCTAssertEqual(pending.latestNotificationRevision, 2)
        XCTAssertEqual(pending.reasons.rawValue, 3)
        XCTAssertTrue(pending.topologyChangeHint)
        XCTAssertTrue(pending.outputConfigurationChanged)
        XCTAssertFalse(pending.sampleInFlight)
        XCTAssertTrue(pending.resamplePending)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline, fixture.parent)
    }

    func testNextSessionReusesActualProcessReceiptWithoutConfigurationCommands() throws {
        let first = try AcquiringOutputFixture()
        let registry = first.registry
        let activation = try first.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("首次真实交接失败")
        }
        let process = try XCTUnwrap(registry.processAudioSessionReceiptSnapshot())
        XCTAssertNil(registry.phase(of: activation), "组合完成已退休此准确原票")
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: handoff.successorContextNonce, reason: .stop, at: 2))
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let deactivate = try registry.enqueueCleanupDeactivation(reservation.ticket)
        XCTAssertEqual(try graphAudioCall(registry, lane: first.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        XCTAssertNil(registry.phase(of: deactivate))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner = try XCTUnwrap(registry.claimOwnedResourceReleaseRunner(release)) as OwnedOutputResourceRunner?
        XCTAssertNotNil(runner)
        XCTAssertTrue(registry.complete(release))
        runner = nil
        XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertNil(registry.outputRouteObservationSnapshot(), "旧lease的route state不能跨session遗留")
        XCTAssertEqual(registry.processAudioSessionReceiptSnapshot(), process)
        let second = try AcquiringOutputFixture(registry: registry, sessionID: 2, audioLane: first.lane)
        XCTAssertNil(try registry.beginOutputAcquisitionConfiguration(contextNonce: second.contextNonce, parent: second.parent),
            "普通release/new play不能重跑仍有效的配置计划")
        let next = try XCTUnwrap(registry.beginOutputAcquisitionActivation(contextNonce: second.contextNonce))
        XCTAssertEqual(registry.registeredAudioSessionPhase()?.processReceipt, process)
        _ = try claimGraphAudioCall(registry, lane: first.lane, next)
    }

    func testAcquisitionHandoffCapacityFailureLeavesReceiptRelayAndResourcesUncommitted() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let expected = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        while registry.occupancy.safetySlots + registry.occupancy.reservedSafetySlots < 16 {
            let group = try registry.createGroup(resource: .context(session: expected.relayIdentity.sessionIdentity,
                nonce: UInt64(registry.occupancy.groups)))
            _ = try registry.enqueue(group: group, slot: .suspend, policy: .safetyBypass)
        }
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        XCTAssertThrowsError(try registry.commitAcquisitionRelayAndContext(expected))
        XCTAssertEqual(registry.outputAcquisitionCommitSnapshot(), expected)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingLeaseAcquisition)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.committedRelay)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts)
        XCTAssertNil(registry.processAudioSessionReceiptSnapshot())
        XCTAssertNil(registry.outputRouteObservationSnapshot())
        assertSameReservation(try XCTUnwrap(registry.cleanupReservationSnapshot()), reservation)
    }

    func testAcquisitionRouteCursorAdvanceReturnsFreshSnapshotWithoutPublishingPartialHandoff() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let expected = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        registry.executor.safetyIngress.beginRouteObservation(.init(sessionIdentity: expected.relayIdentity.sessionIdentity,
            monitorLifecycle: expected.relayIdentity.monitorLifecycle, notificationRevision: 1,
            reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: false, observedRoute: nil))
        guard case .retry(let fresh) = try registry.commitAcquisitionRelayAndContext(expected) else {
            return XCTFail("route cursor前进只返回新快照，不切relay")
        }
        XCTAssertGreaterThan(fresh.ownerEventCursor, expected.ownerEventCursor)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.committedRelay)
        guard case .pending(let before) = registry.outputRouteObservationSnapshot() else { return XCTFail("预交接pending必须保留") }
        XCTAssertNil(before.deadline)
        XCTAssertNil(before.ticket)
        fixture.clock.set(200)
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(fresh) else {
            return XCTFail("重折叠后原active receipt仍可合法交接")
        }
        XCTAssertEqual(handoff.routeDeadline?.identity.deadlineAnchorInstant, 200)
        guard case .pending(let pending) = registry.outputRouteObservationSnapshot() else { return XCTFail("需要pending权威采样") }
        XCTAssertEqual(pending.latestObservation?.notificationRevision, 1)
        XCTAssertTrue(pending.topologyChangeHint)
        XCTAssertEqual(pending.reasons.rawValue, 257)
    }

    func testAcquisitionHandoffAtomicallyInstallsSuccessorAndFirstAuthoritativeSamplerWindow() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let expected = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        let result = try registry.commitAcquisitionRelayAndContext(expected)
        guard case .committed(let handoff) = result else { return XCTFail("ready必须与权威采样资源一次交接") }
        XCTAssertEqual(handoff.committed, expected)
        XCTAssertNotEqual(handoff.successorContextNonce, expected.contextNonce)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingSuccessorLease)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.contextNonce, handoff.successorContextNonce)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline, fixture.parent)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.sessionReceipts?.process, registry.processAudioSessionReceiptSnapshot())
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.committedRelay, expected)
        XCTAssertEqual(handoff.routeDeadline?.identity.deadlineAnchorInstant, 100)
        XCTAssertEqual(handoff.routeDeadline?.deadlineInstant, 3_000_000_100)
        XCTAssertEqual(handoff.routeObservation?.sessionIdentity, expected.relayIdentity.sessionIdentity)
        let sampler = try XCTUnwrap(handoff.sampler)
        XCTAssertEqual(registry.phase(of: sampler), .queued)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.routeObservationGateOpen)
        XCTAssertEqual(try registry.commitAcquisitionRelayAndContext(expected), .rejected)
        _ = try claimGraphRoute(registry, lane: fixture.lane,
            observation: try XCTUnwrap(handoff.routeObservation), source: sampler)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.claim(sampler, lane: fixture.lane, family: .sampler)), .rejected,
            "同一准确sampler不能重复claim")
    }

    func testAcquisitionOwnsOriginalParentBeforeAnyConfigurationAndRejectsReplacement() throws {
        let fixture = try AcquiringOutputFixture()
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.parentDeadline, fixture.parent)
        let forged: CurrentPlaybackOperationDeadlineTicket
        switch fixture.parent {
        case .coldStart(var value): value.accumulatedEffectiveTime = 1; forged = .coldStart(value)
        case .outputRecovery: return XCTFail("fixture应为原冻结cold-start")
        }
        XCTAssertNil(try fixture.registry.beginOutputAcquisitionConfiguration(
            contextNonce: fixture.contextNonce, parent: forged), "首次配置不能用旁路字段覆盖acquisition admission的parent")
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, 0)
    }

    func testAcquisitionReadyBeganReturnsToAwaitingWithoutReconfiguring() throws {
        let fixture = try AcquiringOutputFixture()
        let first = try fixture.configureAndActivate()
        let receipt = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase()?.processReceipt)
        XCTAssertNil(fixture.registry.phase(of: first))
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertNil(try fixture.registry.beginOutputAcquisitionActivation(contextNonce: fixture.contextNonce))
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let next = try XCTUnwrap(fixture.registry.beginOutputAcquisitionActivation(contextNonce: fixture.contextNonce))
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(fixture.registry.registeredAudioSessionPhase()?.processReceipt, receipt)
        XCTAssertEqual(try graphAudioCall(fixture.registry, lane: fixture.lane, next, .activation(nil)).disposition, .accepted)
        XCTAssertNotNil(fixture.registry.outputAcquisitionCommitSnapshot())
    }

    func testAcquisitionReadyStopTransfersWholeLeaseAndOriginalActiveAuthority() throws {
        let fixture = try AcquiringOutputFixture()
        let activation = try fixture.configureAndActivate()
        let disposition = fixture.registry.ownedDeactivationDisposition()
        let owner = try XCTUnwrap(OutputCleanupCoordinator(registry: fixture.registry).begin(
            contextNonce: fixture.contextNonce, reason: .stop, at: 10))
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertEqual(context.phase, .leaseOnlyCleanup)
        XCTAssertNotEqual(context.contextNonce, fixture.contextNonce)
        XCTAssertEqual(context.owner, owner)
        XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), disposition)
        XCTAssertNil(fixture.registry.phase(of: activation), "原已完成activation退休后，资源仍完整持有原active责任")
        XCTAssertNil(try fixture.registry.beginOutputAcquisitionActivation(contextNonce: context.contextNonce))
    }

    func testAcquisitionConfigurationAndActivationUseThreeSeparateAccurateRecords() throws {
        let fixture = try AcquiringOutputFixture()
        let registry = fixture.registry
        let category = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(
            contextNonce: fixture.contextNonce, parent: fixture.parent))
        let categoryResult = try graphAudioCall(registry, lane: fixture.lane, category, .configuration(.categorySucceeded))
        XCTAssertNil(registry.registeredAudioSessionPhase()?.processReceipt, "category成功不是完整process receipt")
        XCTAssertNil(registry.phase(of: category))
        let multichannel = try XCTUnwrap(categoryResult.followUp)
        XCTAssertNotEqual(category, multichannel)
        let capabilityRequest = try claimGraphAudioCall(registry, lane: fixture.lane, multichannel)
        let capabilityResult = try completeGraphAudioCall(registry, lane: fixture.lane, capabilityRequest,
            .configuration(.multichannelCapability(true)))
        XCTAssertEqual(capabilityResult.disposition, .accepted)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: capabilityRequest.permit,
            result: .configuration(.multichannelCapability(true))), lane: fixture.lane)), .rejected)
        XCTAssertNotNil(registry.registeredAudioSessionPhase()?.processReceipt)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingLeaseAcquisition)
        XCTAssertNil(registry.phase(of: multichannel))
        let activation = try XCTUnwrap(capabilityResult.followUp)
        XCTAssertNotEqual(activation, multichannel)
        let activationRequest = try claimGraphAudioCall(registry, lane: fixture.lane, activation)
        XCTAssertNil(registry.outputAcquisitionCommitSnapshot(), "未返回的SDK调用不能提供active事实")
        XCTAssertEqual(try completeGraphAudioCall(registry, lane: fixture.lane, activationRequest, .activation(nil)).disposition, .accepted)
        XCTAssertEqual(registry.executor.performAudioSessionCall(.complete(.init(permit: activationRequest.permit,
            result: .activation(nil)), lane: fixture.lane)), .rejected)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingLeaseAcquisition,
            "activation只进入ready，最终relay/context交接仍未发生")
    }

    func testReservationCannotSkipConfigurationActivationAndRelayHandoff() throws {
        let registry = ControlTaskRegistry()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
            identity: .init(sessionIdentity: session, nonce: 1), kind: .coldStart, originInstant: 0,
            cap: 15_000_000_000, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        let acquisition = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline, parent)
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        XCTAssertTrue(registry.claimStart(acquisition))
        let lifetime = ResourceLifetimeObservation(registry: registry)
        let proof = AcquisitionConfiguredLeaseOwnershipProof(acquisitionTicket: acquisition,
            sessionIdentity: session, leaseID: 1, contextNonce: reservation.contextNonce, ownershipNonce: 1)
        XCTAssertTrue(registry.completeWithOwnedResult(acquisition, ownership: .init(
            reservation: reservation.ticket, contextNonce: reservation.contextNonce,
            mediaServicesEpoch: 0, interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
            payload: .lease(.init(leaseID: 1, object: ResourceLifetimeSpy(lifetime),
                monitor: .init(sessionIdentity: session, lifecycle: 1, object: ResourceLifetimeSpy(lifetime)),
                deactivation: .confirmedInactive(.reservation(proof)))))))
        XCTAssertTrue(try registry.settleOutputAcquisition(acquisition))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(context.phase, .pendingLeaseAcquisition,
            "reservation只取得lease；没有配置、激活和relay原子交接不能变successor")
        XCTAssertEqual(context.contextNonce, reservation.contextNonce)
        XCTAssertEqual(registry.cleanupReservationSnapshot()?.consumedConversions, 0,
            "不得提前消费retained-successor转换身份")
        setTestRouteGate(true, registry: registry)
        XCTAssertNil(try registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: forgedStableCommit(session: context.sessionIdentity), owner: nil))
    }

    func testRealQuiescentInterruptionProofSurvivesEndedAndNextBeganRevokesIt() throws {
        let fixture = try OutputGraphFixture()
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: 10, teardown: false))
        XCTAssertNil(try fixture.registry.issueOutputDrainProof(owner: owner, kind: .interruption))
        if let prepare = context.sourceTask {
            XCTAssertEqual(try fixture.registry.retireOutputControlRecord(prepare), .retired(followUp: nil))
        }
        let stop = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(fixture.registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: owner))
        XCTAssertTrue(fixture.registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.phase, .quiescentBackend)
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(fixture.registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(fixture.registry.complete(ownerTask))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        guard case .settled(let proof, nil) = fixture.registry.settleOutputInterruptionDrain(owner: owner) else {
            return XCTFail("需要由准确旧record终态签发真实普通中断证明")
        }
        let result = OutputRegisteredDrainProof.interruption(proof)
        guard case .quiescentBackend(let backend, let retained) = proof.resultingResourceShape else { return XCTFail("准确shape必须是Q") }
        XCTAssertEqual(backend, fixture.lifecycle.backendIdentity)
        XCTAssertEqual(retained.contextNonce, context.contextNonce)
        XCTAssertEqual(proof.retiredOutputLifecycleEpoch, fixture.lifecycle)
        XCTAssertEqual(fixture.registry.registeredOutputDrainProof(), result)
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(fixture.registry.registeredOutputDrainProof(), result)
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        XCTAssertNil(fixture.registry.registeredOutputDrainProof())
        let replacement = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: 20, teardown: false))
        XCTAssertNotEqual(replacement, owner)
        let replacementTask = try XCTUnwrap(fixture.registry.outputCleanupOwnerTask(replacement))
        XCTAssertNil(try fixture.coordinator.advance(owner: replacement))
        XCTAssertTrue(fixture.registry.complete(replacementTask))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(replacementTask), .retired(followUp: nil))
        guard case .settled(let next, _) = fixture.registry.settleOutputInterruptionDrain(owner: replacement) else {
            return XCTFail("下一began必须由新owner签发新proof")
        }
        XCTAssertNotEqual(.interruption(next), result)
    }

    func testTimeoutKeepsOriginalStopAndForcedRetirementJoinedUntilLateReceipt() throws {
        let fixture = try OutputGraphFixture()
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 100))
        let stop = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(fixture.registry.claimStart(stop.task))
        fixture.stable.acquisition.clock.set(stop.anchorInstant + 1_000_000_000)
        XCTAssertTrue(fixture.registry.timeoutOutputSuspend(stop))
        XCTAssertEqual(fixture.registry.phase(of: stop.task), .running)
        XCTAssertTrue(try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()).poisoned)
        XCTAssertNil(try fixture.coordinator.advance(owner: owner), "旧owner不可在timeout抢占后继续")
        let terminal = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.owner)
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: terminal))
        XCTAssertTrue(fixture.registry.claimStart(retirement))
        XCTAssertFalse(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertNotNil(try fixture.coordinator.advance(owner: terminal))
        XCTAssertTrue(try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()).poisoned)
    }

    func testSuspendReceiptCannotInventDrainWhileOriginalActivationStillRunning() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(registry.beginOutputActivation(contextNonce: context.contextNonce))
        let activationEpoch = try XCTUnwrap(registry.outputResourceContextSnapshot()?.activation)
        XCTAssertTrue(registry.claimStart(activation))
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .stop, at: fixture.stable.acquisition.clock.read()))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertEqual(stop.priorActivation, activationEpoch)
        XCTAssertTrue(registry.claimStart(stop.task))
        let receipt = OutputQuiescenceReceipt(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)
        XCTAssertFalse(fixture.coordinator.completeSuspend(receipt),
            "rate-0事实不能越过仍为cancelRequested的准确原activation record")
        XCTAssertTrue(registry.complete(activation), "迟到原activation必须先结束准确SDK责任")
        XCTAssertTrue(fixture.coordinator.completeSuspend(receipt))
        XCTAssertNotNil(try fixture.coordinator.advance(owner: owner))
    }

    func testSuspendTimeoutUsesStrictOneSecondBoundaryAndJoinsInFlightOwnerTask() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let anchor = clock.read()
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: anchor, teardown: false))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        clock.set(anchor + 999_999_999)
        XCTAssertFalse(registry.timeoutOutputSuspend(stop), "1秒之前的early wake不能伪造timeout")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner, owner)
        clock.set(anchor + 1_000_000_000)
        XCTAssertTrue(registry.timeoutOutputSuspend(stop), "恰到1秒边界必须由锁内时钟超时")
        let terminal = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertEqual(terminal.identity, owner.identity, "在途owner升级terminal只能join原身份")
        XCTAssertEqual(terminal.reason, .terminal)
        XCTAssertEqual(registry.outputCleanupOwnerTask(terminal), ownerTask)
        XCTAssertNil(registry.phase(of: try XCTUnwrap(registry.cleanupReservationSnapshot()).task(for: .owner)),
            "在途owner尚未退休时不能提前消费最终预签owner")
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        XCTAssertNotNil(try fixture.coordinator.advance(owner: terminal))
    }

    func testSuspendReceiptAtOneSecondBoundaryForcesCleanupAndOnlyJoinsLateRecord() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let anchor = clock.read()
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: anchor, teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        clock.set(anchor + 1_000_000_000)
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        let forced = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(forced.suspendConfirmed, "迟到准确receipt仍须结束原stop record")
        XCTAssertTrue(forced.suspendTimedOut, "恰到边界只能由强制cleanup胜出")
        XCTAssertTrue(forced.poisoned)
        XCTAssertFalse(forced.suspendPreparedPreserved, "迟到preserved hint不能逆转已到界的强制cleanup")
        XCTAssertEqual(forced.owner?.identity, owner.identity, "在途owner只能按原身份升级terminal")
        XCTAssertEqual(forced.owner?.reason, .terminal)
        XCTAssertEqual(registry.phase(of: stop.task), .terminal(.completed))
    }

    func testSuspendDeadlineOverflowForcesTerminalCleanupInsteadOfBecomingInfinite() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let anchor = UInt64.max - 500_000_000
        clock.set(anchor)
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: anchor, teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertFalse(registry.timeoutOutputSuspend(stop),
            "时钟算术溢出不是正常业务到期，不能伪装成timeout成功")
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .clockOverflow)
        let forced = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(forced.poisoned)
        XCTAssertFalse(forced.suspendTimedOut)
        XCTAssertEqual(forced.owner, owner, "失败关闭保留准确在途owner责任，由终态reservation继续收敛")
        XCTAssertTrue(try XCTUnwrap(registry.cleanupReservationSnapshot()).terminal)
    }

    func testSuspendReceiptWaitsForRunningDescendantProducerRecord() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let current = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(current.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let child = try registry.createGroup(resource: current.reservation.workGroup.resourceIdentity,
            parent: current.reservation.workGroup)
        let descendant = try registry.enqueue(group: child, slot: .prepare,
            policy: .routeSpeculativeRateZero)
        XCTAssertTrue(registry.claimStart(descendant))
        _ = try XCTUnwrap(fixture.coordinator.begin(contextNonce: current.contextNonce,
            reason: .stop, at: fixture.stable.acquisition.clock.read()))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        let receipt = OutputQuiescenceReceipt(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)
        XCTAssertFalse(fixture.coordinator.completeSuspend(receipt),
            "准确workGroup descendant仍持有producer责任时不能确认drain")
        XCTAssertTrue(registry.complete(descendant))
        XCTAssertTrue(fixture.coordinator.completeSuspend(receipt))
    }

    func testSuspendTimeoutUsesEarlierExistingCleanupBudgetBoundary() throws {
        let fixture = try OutputGraphFixture()
        let registry = fixture.registry
        let clock = fixture.stable.acquisition.clock
        let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let firstAnchor = clock.read()
        let pause = try XCTUnwrap(fixture.coordinator.begin(contextNonce: original.contextNonce,
            reason: .pause, at: firstAnchor, teardown: true))
        let firstStop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(firstStop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: firstStop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        XCTAssertTrue(registry.finishOutputPause(owner: pause))
        let budget = try XCTUnwrap(registry.outputResourceContextSnapshot()?.budget)
        clock.set(budget.deadlineInstant)
        let current = try XCTUnwrap(registry.outputResourceContextSnapshot())
        _ = try XCTUnwrap(fixture.coordinator.begin(contextNonce: current.contextNonce,
            reason: .stop, at: budget.deadlineInstant))
        let laterStop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertGreaterThan(laterStop.anchorInstant + 1_000_000_000, budget.deadlineInstant)
        XCTAssertTrue(registry.timeoutOutputSuspend(laterStop),
            "已有cleanup budget更早到界时必须夹紧新的1秒suspend窗口")
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.suspendTimedOut == true)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
    }

    func testAudibleIntervalClosesOnlyWithSingleExactClaimAndPauseGetsNewStop() throws {
        let fixture = try OutputGraphFixture()
        let prepare = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(fixture.registry.claimStart(prepare))
        XCTAssertTrue(fixture.registry.completeOutputPrepare(prepare))
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(fixture.registry.beginOutputActivation(contextNonce: context.contextNonce))
        XCTAssertTrue(fixture.registry.claimStart(activation))
        let interval = try XCTUnwrap(fixture.registry.openOutputInterval(activation))
        XCTAssertNil(fixture.registry.openOutputInterval(activation))
        XCTAssertTrue(fixture.registry.complete(activation))
        let owner = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .pause, at: 1, teardown: false))
        let stopping = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let stop = try XCTUnwrap(stopping.suspend)
        let claim = try XCTUnwrap(stopping.closeClaim)
        XCTAssertEqual(claim.intervalKey, interval)
        XCTAssertTrue(fixture.registry.claimStart(stop.task))
        XCTAssertFalse(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.interval, interval)
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: claim,
            directlyConfirmedRateZero: true, preparedPreserved: true)))
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.interval)
        XCTAssertTrue(fixture.registry.finishOutputPause(owner: owner))
        XCTAssertNotNil(try fixture.coordinator.begin(contextNonce: context.contextNonce, reason: .stop, at: 2))
        XCTAssertNotEqual(fixture.registry.outputResourceContextSnapshot()?.suspend?.task, stop.task)
    }

    func testConvertedLeaseJoinsExactActivationThenDeactivatesAfterMonitor() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let activation = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, activation)
        XCTAssertTrue(fixture.registry.transferActivationDisposition(activation))
        let coordinator = OutputCleanupCoordinator(registry: fixture.registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: phase.identity.contextNonce, reason: .stop, at: 1))
        let cleanup = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertEqual(cleanup.contextNonce, phase.identity.contextNonce,
            "真实图必须保留原context，才能join准确在途activation")
        XCTAssertEqual(cleanup.disposition, .releaseAfterTeardown)
        XCTAssertThrowsError(try fixture.registry.enqueueCleanupDeactivation(cleanup.reservation))
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(fixture.registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(fixture.registry)))
        XCTAssertNil(try coordinator.advance(owner: owner))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .activation(nil)).disposition, .settled)
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner), "coordinator必须接管原record并自动安装唯一deactivate")
        XCTAssertNil(fixture.registry.phase(of: activation), "责任转移后原terminal音频record必须先退休以释放唯一slot")
        XCTAssertEqual(try graphAudioCall(fixture.registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
    }

    func testRetainedPendingAcquisitionDoesNotStopMonitorBeforeReleaseDisposition() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: fixture.registry)
        let owner = try XCTUnwrap(coordinator.begin(
            contextNonce: context.contextNonce, reason: .recovery, at: 1, teardown: false
        ))
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.disposition,
            .retainForSession(context.sessionIdentity))
        XCTAssertNil(try coordinator.advance(owner: owner),
            "保留中的pending acquisition不能因为cleanup advance而停止monitor")
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.monitorStop)
        XCTAssertFalse(fixture.registry.outputResourceContextSnapshot()?.monitorStopped == true)
    }

    func testStopRevokesOutputPermitInTheSameResourceCAS() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        fixture.registry.executor.sync {
            _ = fixture.registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) {
                $0.outputPermitPresent = true
                $0.readinessOpen = true
            }
        }
        XCTAssertNotNil(try OutputCleanupCoordinator(registry: fixture.registry).begin(
            contextNonce: fixture.reservation.contextNonce, reason: .stop, at: 10))
        XCTAssertFalse(fixture.registry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertFalse(fixture.registry.executor.safetyIngress.snapshot.readinessOpen)
    }

    func testFactoryNoObjectAfterReleaseWinsKeepsAccurateLeaseOnlyBarrier() throws {
        let fixture = try StableOutputFixture()
        let retained = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(fixture.registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let claim = try XCTUnwrap(rebase.successorClaim)
        let factory = try XCTUnwrap(fixture.registry.claimOutputSuccessor(claim))
        XCTAssertTrue(fixture.registry.claimStart(factory))
        let pending = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertEqual(pending.phase, .pendingCreation)
        let owner = try XCTUnwrap(OutputCleanupCoordinator(registry: fixture.registry).begin(
            contextNonce: pending.contextNonce, reason: .stop, at: 20))
        XCTAssertTrue(try fixture.registry.completeOutputFactory(factory, candidate: nil))
        let cleanup = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertEqual(cleanup.phase, .leaseOnlyCleanup)
        XCTAssertEqual(cleanup.disposition, .releaseAfterTeardown)
        XCTAssertEqual(cleanup.owner, owner)
        XCTAssertNotEqual(cleanup.contextNonce, pending.contextNonce)
        XCTAssertNil(try fixture.registry.claimOutputSuccessor(claim))
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
    }

    func testRealCoordinatorJoinsOneStopRetirementTeardownAndRegistersParentOwner() throws {
        let fixture = try OutputGraphFixture()
        let installed = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(installed.sourceTask)
        XCTAssertTrue(fixture.registry.claimStart(prepare))
        XCTAssertTrue(fixture.registry.completeOutputPrepare(prepare))
        XCTAssertNil(fixture.registry.phase(of: prepare), "成功prepare由typed completion消费原record")
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let backend = fixture.lifecycle.backendIdentity
        let lifecycle = fixture.lifecycle
        let coordinator = fixture.coordinator
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: installed.contextNonce, reason: .stop, at: 10))
        let stop = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertEqual(try coordinator.begin(contextNonce: installed.contextNonce, reason: .pause, at: 99), owner)
        XCTAssertNotNil(fixture.registry.phase(of: reservation.task(for: .owner)), "清理owner必须登记在父group")
        XCTAssertTrue(fixture.registry.claimStart(stop.task))
        XCTAssertFalse(fixture.registry.complete(stop.task), "普通completion不得伪造静止")
        XCTAssertTrue(coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try coordinator.advance(owner: owner), retirement)
        XCTAssertTrue(fixture.registry.claimStart(retirement))
        XCTAssertTrue(coordinator.completeRetirement(retirement, lifecycle: lifecycle))
        let teardown = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try coordinator.advance(owner: owner), teardown)
        let predecessor = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertEqual(predecessor.phase, .predecessorCleanup)
        XCTAssertNotEqual(predecessor.contextNonce, reservation.contextNonce)
        XCTAssertTrue(fixture.registry.claimStart(teardown))
        XCTAssertNotNil(coordinator.completeTeardown(teardown, backend: backend, contextNonce: predecessor.contextNonce))
        XCTAssertNil(coordinator.completeTeardown(teardown, backend: backend, contextNonce: predecessor.contextNonce))
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.phase, .leaseOnlyCleanup)
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(fixture.registry.claimStart(monitor))
        XCTAssertFalse(coordinator.completeMonitorStop(monitor, lifecycle: 99))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(fixture.registry)))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try graphAudioCall(fixture.registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertTrue(fixture.registry.complete(release))
    }

    func testBackendCannotBeReleasedBeforeAccurateTeardownConfirmation() throws {
        let fixture = try OutputGraphFixture()
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let release = try fixture.registry.enqueueReservedCleanup(reservation.ticket, stage: .leaseRelease)
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release),
            "真实backend仍未teardown，不能仅凭AudioSession inactive就释放整份资源")
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
    }

    func testLeaseCannotBeReleasedBeforeExactMonitorStops() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        let release = try fixture.registry.enqueueReservedCleanup(fixture.reservation.ticket, stage: .leaseRelease)
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release),
            "monitor尚未停止，不能提前释放lease并解析barrier")
    }

    func testCleanupMonitorCommandCannotBypassDeliveryACKUsingRawRegistryEntry() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        let delivery = try XCTUnwrap(fixture.registry.beginOutputMonitorDelivery(contextNonce: fixture.reservation.contextNonce))
        let monitor = try fixture.registry.enqueueReservedCleanup(fixture.reservation.ticket, stage: .monitorStop)
        XCTAssertFalse(fixture.registry.claimStart(monitor), "原始registry入口也必须尊重准确delivery ACK")
        XCTAssertTrue(fixture.registry.acknowledgeOutputMonitorDelivery(delivery))
    }

    func testEscapedResourceReadDoesNotRetainRealRegistrationBeyondAccurateRunner() throws {
        let clock = OutputTestClock(100)
        let registry = ControlTaskRegistry(allocator: .init(), clock: clock)
        let lifetime = ResourceLifetimeObservation(registry: registry)
        var strongBackend: ResourceLifetimeSpy? = ResourceLifetimeSpy(lifetime)
        weak var registration: PlaybackAudioSessionRegistration?
        weak var backend: ResourceLifetimeSpy?
        backend = strongBackend
        let fixture = try OutputGraphFixture(registry: registry, clock: clock, backendObject: strongBackend)
        registration = registry.audioSessionRegistration(for: fixture.stable.acquisition.acquisition)
        XCTAssertNotNil(registration)
        strongBackend = nil
        let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let prepare = try XCTUnwrap(installed.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        XCTAssertNil(registry.phase(of: prepare), "成功prepare由typed completion消费原record")
        let escaped = registry.ownedResourceSnapshot()
        let coordinator = fixture.coordinator
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: installed.contextNonce, reason: .stop, at: 1))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let teardown = try XCTUnwrap(coordinator.advance(owner: owner))
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.claimStart(teardown))
        var disposal = coordinator.completeTeardown(teardown,
            backend: fixture.lifecycle.backendIdentity, contextNonce: predecessor.contextNonce)
        XCTAssertNotNil(disposal)
        XCTAssertNotNil(backend)
        disposal = nil
        XCTAssertNil(backend, "backend准确teardown后独立锁外释放，快照不持有对象")
        let monitorStop = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitorStop))
        XCTAssertTrue(try XCTUnwrap(registration).stop(monitorStop))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try graphAudioCall(registry, lane: fixture.stable.acquisition.lane,
            deactivate, .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertNotNil(registration, "准确release runner领取前仍由资源图持有")
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        XCTAssertNotNil(registration, "claim后由准确runner承接真实handle")
        XCTAssertTrue(registry.complete(release))
        XCTAssertFalse(registry.releaseCleanupReservation(reservation.ticket), "真实父owner未终态仍必须join")
        XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertFalse(registry.executor.isIsolated)
        runner = nil
        XCTAssertNil(registration, "明确executor外释放runner后，真实handle不应再有其他所有者")
        withExtendedLifetime(escaped) {
            XCTAssertNotNil(escaped?.contextNonce)
            XCTAssertNil(registration, "只读快照不能成为另一份SDK所有者；weak不声称可独立测析构线程")
            XCTAssertNil(backend)
            XCTAssertEqual(lifetime.count, 1, "这里只由backend spy测析构线程，lease/monitor共用真实handle")
            XCTAssertFalse(lifetime.releasedOnExecutor)
        }
    }

    func testPureOwnedResourcesReleaseLeaseAndMonitorSpiesOutsideExecutor() throws {
        let fixture = try OwnedResourceFixture()
        let registry = fixture.registry
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try registry.settleOutputAcquisition(acquire))
        let escaped = registry.ownedResourceSnapshot()
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: fixture.reservation.contextNonce,
            reason: .stop, at: 100))
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        XCTAssertEqual(fixture.lifetime.count, 0)
        XCTAssertTrue(registry.complete(release))
        XCTAssertTrue(registry.complete(fixture.reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertFalse(registry.executor.isIsolated)
        runner = nil
        withExtendedLifetime(escaped) {
            XCTAssertNotNil(escaped)
            XCTAssertEqual(fixture.lifetime.count, 2, "不采样的纯资源边界保留任意lease/monitor析构spy oracle")
            XCTAssertFalse(fixture.lifetime.releasedOnExecutor)
        }
    }

    func testConsumedCleanupOwnerRejectsStopPreparationWithoutClaimingPendingAcquisitionResult() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        let owner = try fixture.registry.enqueueReservedCleanup(fixture.reservation.ticket, stage: .owner)
        XCTAssertTrue(fixture.registry.claimStart(owner))
        XCTAssertTrue(fixture.registry.complete(owner))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(owner), .retired(followUp: nil))
        let before = fixture.registry.occupancy
        let beforeReservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        setTestRouteGate(true, registry: fixture.registry)
        XCTAssertThrowsError(try OutputCleanupCoordinator(registry: fixture.registry).begin(
            contextNonce: fixture.reservation.contextNonce, reason: .stop, at: 100))
        XCTAssertTrue(testRouteGate(registry: fixture.registry))
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .rejected,
            "组合失败必须由原record继续持有结果")
        XCTAssertEqual(fixture.registry.occupancy.ordinarySlots, before.ordinarySlots)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, before.safetySlots)
        XCTAssertEqual(fixture.registry.occupancy.reservedSafetySlots, before.reservedSafetySlots)
        XCTAssertEqual(fixture.registry.occupancy.groups, before.groups)
        XCTAssertNil(fixture.registry.phase(of: owner))
        assertSameReservation(beforeReservation, try XCTUnwrap(fixture.registry.cleanupReservationSnapshot()))
    }

    func testConfigurationCommandIdentityFailurePreservesSettledResourceAndContext() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 64,
            initialNamespace: .controlTask)
        let fixture = try OwnedResourceFixture(allocator: allocator)
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        setTestRouteGate(false, registry: fixture.registry)
        while try allocator.next(in: .controlTask) != UInt64.max {}
        let before = fixture.registry.occupancy
        let beforeReservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let beforeContext = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let parent = try XCTUnwrap(beforeContext.parentDeadline)
        XCTAssertThrowsError(try fixture.registry.beginOutputAcquisitionConfiguration(
            contextNonce: beforeContext.contextNonce, parent: parent))
        XCTAssertFalse(testRouteGate(registry: fixture.registry), "命令准备失败不改shadow或重新打开gate")
        XCTAssertTrue(allocator.isExhausted)
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot(), "已正式settle的资源不能因后继命令身份失败丢失")
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.contextNonce, beforeContext.contextNonce)
        XCTAssertEqual(fixture.registry.occupancy.ordinarySlots, before.ordinarySlots)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, before.safetySlots)
        XCTAssertEqual(fixture.registry.occupancy.reservedSafetySlots, before.reservedSafetySlots)
        XCTAssertEqual(fixture.registry.occupancy.groups, before.groups)
        let failedReservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        XCTAssertEqual(failedReservation.ticket, beforeReservation.ticket)
        XCTAssertTrue(failedReservation.terminal, "checked命令身份耗尽必须在同一Authority失败关闭")
        XCTAssertTrue(fixture.registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testOwnedBackendResultCannotReplaceReservedBackendIdentity() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let pending = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let expected = try XCTUnwrap(pending.candidateBackendIdentity)
        let wrong = PlaybackBackendIdentity(sessionIdentity: pending.sessionIdentity,
            backendGeneration: expected.backendGeneration + 1)
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let observation = ResourceLifetimeObservation(registry: registry)
        let payload = OutputOwnedResourcePayload.backend(.init(identity: wrong, object: ResourceLifetimeSpy(observation), lifecycle: nil,
            lease: .init(leaseID: 1, object: ResourceLifetimeSpy(observation),
                monitor: .init(sessionIdentity: pending.sessionIdentity, lifecycle: 1, object: ResourceLifetimeSpy(observation)),
                deactivation: .invalidatedByMediaServicesReset(mediaServicesEpoch: 0))))
        XCTAssertFalse(registry.completeWithOwnedResult(factory, ownership: .init(reservation: reservation.ticket,
            contextNonce: pending.contextNonce, mediaServicesEpoch: pending.mediaServicesEpoch,
            interruptionEpoch: pending.interruptionEpoch,
            audioAdmissionFenceRevision: pending.audioAdmissionFenceRevision, payload: payload)),
            "managed factory不能接纳调用方伪造的backend identity")
        XCTAssertEqual(registry.phase(of: factory), .running)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: ResourceLifetimeSpy(observation)))
        guard case .backend(let installed, _, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
            return XCTFail("准确factory结果必须安装Authority预分配的backend")
        }
        XCTAssertEqual(installed, expected)
        XCTAssertNotEqual(installed, wrong)
        let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertEqual(registry.phase(of: prepare), .queued,
            "candidate安装与唯一prepare必须由同一factory settle CAS发布")
        XCTAssertFalse(try registry.completeOutputFactory(factory, candidate: ResourceLifetimeSpy(observation)))
        XCTAssertFalse(try registry.settleOutputFactory(factory), "已安装candidate不能重放settle或再发prepare")
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
    }

    func testFactoryCheckedIdentityFailuresTransferCandidateOnlyIntoExactTerminalCleanup() throws {
        do {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max,
                initialNamespace: .outputLifecycle)
            let fixture = try StableOutputFixture(allocator: allocator)
            let registry = fixture.registry
            let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
                stableCommit: fixture.stable, owner: nil))
            let claim = try XCTUnwrap(rebase.successorClaim)
            XCTAssertThrowsError(try registry.claimOutputSuccessor(claim),
                "outputLifecycle身份耗尽必须在claim-time失败关闭")
            XCTAssertTrue(allocator.isExhausted)
            XCTAssertNil(registry.executor.safetyIngress.snapshot.failure,
                "claim-time局部失败关闭不伪造全局Cell失败")
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
            XCTAssertTrue(registry.cleanupReservationSnapshot()?.terminal == true)
        }

        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 512,
            initialNamespace: .controlTask)
        let fixture = try StableOutputFixture(allocator: allocator)
        let registry = fixture.registry
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let pending = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let candidateIdentity = try XCTUnwrap(pending.candidateBackendIdentity)
        let lifetime = ResourceLifetimeObservation(registry: registry)
        var candidate: ResourceLifetimeSpy? = ResourceLifetimeSpy(lifetime)
        weak var weakCandidate: ResourceLifetimeSpy?
        weakCandidate = candidate
        while try allocator.next(in: .controlTask) != .max {}
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: candidate),
            "completion域身份失败也必须把SDK返回交给唯一准确终态清理责任")
        candidate = nil
        XCTAssertTrue(allocator.isExhausted)
        let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(failed.poisoned)
        XCTAssertEqual(failed.disposition, .releaseAfterTeardown)
        XCTAssertEqual(failed.phase, .predecessorCleanup)
        let owner = try XCTUnwrap(failed.owner)
        XCTAssertEqual(owner.reason, .terminal)
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.outputCleanupOwnerTask(owner), reservation.task(for: .owner))
        guard case .backend(let installed, nil, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
            return XCTFail("identity失败只能安装无lifecycle的准确candidate cleanup")
        }
        XCTAssertEqual(installed, candidateIdentity)
        XCTAssertNotNil(weakCandidate)
        XCTAssertFalse(try registry.settleOutputFactory(factory))
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
        let teardown = try XCTUnwrap(failed.teardown)
        XCTAssertTrue(registry.claimStart(teardown))
        var disposal = registry.completeOutputTeardown(teardown, backendIdentity: candidateIdentity,
            contextNonce: failed.contextNonce)
        XCTAssertNotNil(disposal)
        disposal = nil
        XCTAssertNil(weakCandidate)
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: try graphMonitorLifecycle(registry)))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(try graphAudioCall(registry, lane: fixture.lane, deactivate,
            .deactivation(.succeeded)).disposition, .settled)
        let release = try XCTUnwrap(coordinator.advance(owner: owner))
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        runner = nil
        XCTAssertTrue(registry.complete(release))
        XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertEqual(registry.occupancy.groups, 0)
        XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
    }

    func testManagedAcquisitionTransfersExactlyOnceAndBeginsOneConfigurationCommand() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let parent = try XCTUnwrap(context.parentDeadline)
        let next = try XCTUnwrap(fixture.registry.beginOutputAcquisitionConfiguration(
            contextNonce: context.contextNonce, parent: parent))
        XCTAssertEqual(fixture.registry.ownedResourceSnapshot()?.reservation, fixture.reservation.ticket)
        XCTAssertEqual(fixture.registry.phase(of: acquire), .terminal(.completed))
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
        XCTAssertEqual(fixture.registry.occupancy.ordinarySlots, 1)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, 1)
        XCTAssertEqual(fixture.registry.occupancy.groups, 2)
        XCTAssertEqual(fixture.registry.occupancy.reservedSafetySlots, 7)
        assertSameReservation(fixture.reservation, try XCTUnwrap(fixture.registry.cleanupReservationSnapshot()))
        XCTAssertFalse(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertThrowsError(try fixture.registry.beginOutputAcquisitionConfiguration(
            contextNonce: context.contextNonce, parent: parent), "在途配置不得二次发行或占用同一slot")
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        let completion = try graphAudioCall(fixture.registry, lane: fixture.lane, next, .configuration(.categorySucceeded))
        XCTAssertEqual(completion.disposition, .settled, "category仅更新真实progress，最终receipt须等multichannel")
        XCTAssertNotNil(completion.followUp)
        XCTAssertNil(fixture.registry.phase(of: next))
    }

    func testOwnedResultJoinsExistingReservedOwnerWithoutDoubleConsumption() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = fixture.acquisition
        XCTAssertTrue(fixture.registry.claimStart(acquire))
        let transition = try XCTUnwrap(OutputCleanupCoordinator(registry: fixture.registry).begin(
            contextNonce: fixture.reservation.contextNonce, reason: .stop, at: 100))
        let owner = try XCTUnwrap(fixture.registry.outputCleanupOwnerTask(transition))
        XCTAssertTrue(fixture.registry.claimStart(owner))
        let before = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        XCTAssertTrue(fixture.registry.completeWithOwnedResult(acquire, ownership: fixture.ownership(
            lease: ResourceLifetimeSpy(fixture.lifetime), monitor: ResourceLifetimeSpy(fixture.lifetime),
            acquisition: acquire)))
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(fixture.registry.phase(of: owner), .running)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, 1)
        XCTAssertEqual(fixture.registry.occupancy.reservedSafetySlots, 7)
        let after = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        XCTAssertEqual(after.ticket, before.ticket)
        XCTAssertTrue(after[.owner].consumed)
        XCTAssertFalse(try fixture.registry.settleOutputAcquisition(acquire), "迟到结果不能重复消费或再占owner")
        XCTAssertNil(fixture.registry.phase(of: acquire), "release-wins结算同CAS消费准确原acquisition record")
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .rejected)
    }

    func testCleanupParentCannotAdmitOrdinaryWorkEvenBeforeTerminal() throws {
        let registry = ControlTaskRegistry()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let reservation = try registry.reserveCleanup(resource: .session(session))
        XCTAssertThrowsError(try registry.enqueue(group: reservation.ticket.ownerGroup, slot: .factory, policy: .routeSpeculativeRateZero))
        XCTAssertThrowsError(try registry.enqueue(group: reservation.ticket.ownerGroup, slot: .activation, policy: .activationRequiresOpen))
        XCTAssertEqual(registry.occupancy.ordinarySlots, 0)
        XCTAssertNotNil(registry.terminateCleanupReservation(reservation.ticket))
        XCTAssertThrowsError(try registry.enqueue(group: reservation.ticket.ownerGroup, slot: .acquire, policy: .routeNeutral))
    }

    func testLeaseReleaseRequiresOwnedRunnerAndJoinsRunningConfiguration() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let configure = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, configure)
        let release = try fixture.registry.enqueueReservedCleanup(reservation.ticket, stage: .leaseRelease)
        XCTAssertFalse(fixture.registry.claimStart(release), "有对象的lease release只能由准确owned runner领走")
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertNotNil(fixture.registry.terminateCleanupReservation(reservation.ticket))
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .configuration(.categorySucceeded))
        XCTAssertEqual(completion.disposition, .settled)
        XCTAssertNil(completion.followUp)
        XCTAssertNil(fixture.registry.phase(of: configure))
        try stopOwnedMonitor(fixture.registry)
        XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertThrowsError(try fixture.registry.enqueue(group: reservation.ticket.workGroup,
            slot: .factory, policy: .routeSpeculativeRateZero))
    }

    func testPendingFactoryResultCannotCommitAfterRouteClosesAndSameCASPreparesExactCleanup() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let pending = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let candidateIdentity = try XCTUnwrap(pending.candidateBackendIdentity)
        let lifetime = ResourceLifetimeObservation(registry: registry)
        var candidate: ResourceLifetimeSpy? = ResourceLifetimeSpy(lifetime)
        weak var weakCandidate: ResourceLifetimeSpy?
        weakCandidate = candidate
        setTestRouteGate(false, registry: registry)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: candidate),
            "SDK返回与route关闭竞争时，结果必须在同一typed CAS转入准确清理")
        candidate = nil
        XCTAssertFalse(testRouteGate(registry: registry))
        XCTAssertEqual(registry.phase(of: factory), .terminal(.canceled))
        XCTAssertFalse(try registry.settleOutputFactory(factory), "原factory结果只能结算一次")
        let predecessor = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(predecessor.phase, .predecessorCleanup)
        XCTAssertEqual(predecessor.candidateBackendIdentity, candidateIdentity)
        let teardown = try XCTUnwrap(predecessor.teardown)
        XCTAssertTrue(registry.claimStart(teardown))
        var disposal = registry.completeOutputTeardown(teardown, backendIdentity: candidateIdentity,
            contextNonce: predecessor.contextNonce)
        XCTAssertNotNil(disposal)
        XCTAssertNotNil(weakCandidate)
        disposal = nil
        XCTAssertNil(weakCandidate)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .pendingSuccessorLease)
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
    }

    func testReservationIdentityFailureLeavesNoHalfInstalledGroupsOrCapacity() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 5)
        let registry = ControlTaskRegistry(allocator: allocator)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        XCTAssertThrowsError(try registry.reserveCleanup(resource: .session(session)))
        XCTAssertTrue(allocator.isExhausted)
        XCTAssertEqual(registry.occupancy.groups, 0)
        XCTAssertEqual(registry.occupancy.safetySlots, 0)
        XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
    }

    func testRefreshPreservesFinalSuspendAndFailureUsesExistingStickyTerminalOwner() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 64)
        let registry = ControlTaskRegistry(allocator: allocator)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let reservation = try registry.reserveCleanup(resource: .session(session))
        let pause = try registry.enqueue(group: reservation.ticket.workGroup, slot: .suspend, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(pause))
        XCTAssertTrue(registry.complete(pause))
        XCTAssertTrue(registry.retire(pause))
        XCTAssertTrue(registry.refreshCleanupReservation(reservation.ticket))
        while !allocator.isExhausted { _ = try? allocator.next(in: .activation) }
        XCTAssertFalse(registry.refreshCleanupReservation(reservation.ticket))
        let terminal = registry.cleanupReservationSnapshot()?.terminalOwner
        XCTAssertEqual(terminal, registry.terminateCleanupReservation(reservation.ticket))
        XCTAssertThrowsError(try registry.enqueue(group: reservation.ticket.workGroup, slot: .activation, policy: .activationRequiresOpen))
        let finalSuspend = try registry.enqueueReservedCleanup(reservation.ticket, stage: .suspend)
        XCTAssertNotEqual(finalSuspend, pause)
        XCTAssertEqual(finalSuspend, reservation.task(for: .suspend))
        XCTAssertTrue(registry.claimStart(finalSuspend))
    }

    func testResourceAndReservedGroupCannotDisappearUntilOriginalRunnerTerminates() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        XCTAssertTrue(fixture.registry.seal(fixture.reservation.ticket.ownerGroup))
        XCTAssertFalse(fixture.registry.releaseGroup(fixture.reservation.ticket.ownerGroup))
        XCTAssertFalse(fixture.registry.releaseCleanupReservation(fixture.reservation.ticket))
    }

    func testReservedCapacityReturnsOnlyAfterResourceRunnerAndAllOriginalRecordsAreTerminal() throws {
        let fixture = try OwnedResourceFixture()
        let acquire = try fixture.completedAcquisition()
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(acquire))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(acquire), .retired(followUp: nil))
        try stopOwnedMonitor(fixture.registry)
        let release = try fixture.registry.enqueueReservedCleanup(fixture.reservation.ticket, stage: .leaseRelease)
        let runner = try XCTUnwrap(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertEqual(runner.task, release)
        XCTAssertFalse(fixture.registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertTrue(fixture.registry.complete(release))
        XCTAssertTrue(fixture.registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertEqual(fixture.registry.occupancy.groups, 0)
        XCTAssertEqual(fixture.registry.occupancy.reservedSafetySlots, 0)
        XCTAssertEqual(fixture.registry.occupancy.safetySlots, 0)
        XCTAssertFalse(fixture.registry.releaseCleanupReservation(fixture.reservation.ticket))
        XCTAssertFalse(fixture.registry.complete(release))
    }

    func testResetDoesNotReleaseLeaseWhileOldActivationStillRunning() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let activation = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, activation)
        XCTAssertTrue(fixture.registry.transferActivationDisposition(activation))
        fixture.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        let release = try fixture.registry.enqueueReservedCleanup(reservation.ticket, stage: .leaseRelease)
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(activation), .rejected)
        XCTAssertTrue(fixture.registry.transferActivationDisposition(activation))
        XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), .invalidatedByMediaServicesReset(mediaServicesEpoch: 1))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .activation(nil)).disposition, .settled)
        XCTAssertNil(fixture.registry.phase(of: activation))
        XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), .invalidatedByMediaServicesReset(mediaServicesEpoch: 1))
        XCTAssertThrowsError(try fixture.registry.enqueueCleanupDeactivation(reservation.ticket))
        try stopOwnedMonitor(fixture.registry)
        XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
    }

    func testSuccessfulActivationCombinationTransfersPhysicalResponsibilityBeforeRetiringOriginalRecord() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let activation = fixture.ticket
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, activation)
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(activation), .rejected)
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .activation(nil)).disposition, .accepted)
        XCTAssertNil(fixture.registry.phase(of: activation))
        XCTAssertNotNil(fixture.registry.outputAcquisitionCommitSnapshot(), "成功结果已进入真实ready资源")
        guard case .requiresDeactivate = fixture.registry.ownedDeactivationDisposition() else {
            return XCTFail("真实owner必须接管成功activation的deactivate责任")
        }
    }

    func testLateActivationSuccessTransfersToTypedDeactivationAndCannotReleaseEarly() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let activation = fixture.ticket
        let activationRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, activation)
        XCTAssertTrue(fixture.registry.transferActivationDisposition(activation))
        let call = AudioSessionCallIdentity(record: activation, phaseIdentity: phase.identity)
        XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), .awaitingActivationOutcome(call))
        XCTAssertNotNil(fixture.registry.terminateCleanupReservation(reservation.ticket))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane,
            activationRequest, .activation(nil)).disposition, .settled)
        XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), .requiresDeactivate(.returnedSuccess(call)))
        XCTAssertNil(fixture.registry.phase(of: activation))
        let release = try fixture.registry.enqueueReservedCleanup(reservation.ticket, stage: .leaseRelease)
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        try stopOwnedMonitor(fixture.registry)
        let deactivate = try fixture.registry.enqueueCleanupDeactivation(reservation.ticket)
        XCTAssertEqual(try fixture.registry.enqueueCleanupDeactivation(reservation.ticket), deactivate)
        let deactivationRequest = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, deactivate)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(deactivate, lane: fixture.lane)), .rejected)
        XCTAssertFalse(fixture.registry.complete(deactivate))
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane,
            deactivationRequest, .deactivation(.succeeded)).disposition, .settled)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: deactivationRequest.permit,
            result: .deactivation(.succeeded)), lane: fixture.lane)), .rejected)
        XCTAssertNil(fixture.registry.phase(of: deactivate))
        XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
    }

    func testMediaResetCancelsQueuedDeactivationButJoinsRunningDeactivation() throws {
        for running in [false, true] {
            let fixture = try ActualAudioActivationFixture(kind: 0)
            let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
            let activation = fixture.ticket
            XCTAssertEqual(try graphAudioCall(fixture.registry, lane: fixture.lane, activation, .activation(nil)).disposition, .accepted)
            XCTAssertNil(fixture.registry.phase(of: activation))
            try stopOwnedMonitor(fixture.registry)
            let deactivate = try fixture.registry.enqueueCleanupDeactivation(reservation.ticket)
            let request = running ? try claimGraphAudioCall(fixture.registry, lane: fixture.lane, deactivate) : nil
            fixture.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            let release = try fixture.registry.enqueueReservedCleanup(reservation.ticket, stage: .leaseRelease)
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(deactivate, lane: fixture.lane)), .rejected)
            if running {
                XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
                XCTAssertEqual(try fixture.registry.retireOutputControlRecord(deactivate), .rejected)
                XCTAssertEqual(try completeGraphAudioCall(fixture.registry, lane: fixture.lane,
                    XCTUnwrap(request), .deactivation(.succeeded)).disposition, .settled)
                XCTAssertNil(fixture.registry.phase(of: deactivate))
            } else {
                XCTAssertEqual(fixture.registry.phase(of: deactivate), .terminal(.canceled))
                XCTAssertEqual(try fixture.registry.retireOutputControlRecord(deactivate), .retired(followUp: nil))
            }
            XCTAssertEqual(fixture.registry.ownedDeactivationDisposition(), .invalidatedByMediaServicesReset(mediaServicesEpoch: 1))
            XCTAssertNotNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        }
    }

    func testOwnedResultTransfersExactlyOnceAndFinalReferencesLeaveLockWithOwnedRunner() throws {
        let fixture = try OwnedResourceFixture()
        let ticket = fixture.acquisition
        XCTAssertTrue(fixture.registry.claimStart(ticket))
        weak var weakLease: ResourceLifetimeSpy?
        weak var weakMonitor: ResourceLifetimeSpy?
        do {
            let lease = ResourceLifetimeSpy(fixture.lifetime)
            let monitor = ResourceLifetimeSpy(fixture.lifetime)
            weakLease = lease
            weakMonitor = monitor
            XCTAssertTrue(fixture.registry.completeWithOwnedResult(ticket,
                ownership: fixture.ownership(lease: lease, monitor: monitor, acquisition: ticket)))
        }
        XCTAssertNotNil(weakLease)
        XCTAssertNotNil(weakMonitor)
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(ticket), .rejected,
            "结果未转移前record不可退休")
        XCTAssertFalse(try fixture.registry.settleOutputAcquisition(fixture.reservation.task(for: .owner)),
            "非准确原acquisition ticket不能领取结果")
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(ticket))
        XCTAssertFalse(try fixture.registry.settleOutputAcquisition(ticket), "准确结果只能转移一次")
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(ticket), .retired(followUp: nil))
        try stopOwnedMonitor(fixture.registry)
        let release = try fixture.registry.enqueueReservedCleanup(fixture.reservation.ticket, stage: .leaseRelease)
        var runner = try XCTUnwrap(fixture.registry.claimOwnedResourceReleaseRunner(release)) as OwnedOutputResourceRunner?
        XCTAssertEqual(runner?.task, release)
        XCTAssertNil(fixture.registry.claimOwnedResourceReleaseRunner(release))
        XCTAssertEqual(fixture.lifetime.count, 0)
        XCTAssertTrue(fixture.registry.complete(release))
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(release), .retired(followUp: nil))
        XCTAssertNotNil(weakLease)
        runner = nil
        XCTAssertNil(weakLease)
        XCTAssertNil(weakMonitor)
        XCTAssertEqual(fixture.lifetime.count, 2)
        XCTAssertFalse(fixture.lifetime.releasedOnExecutor)
    }

    func testCanceledLateManagedAcquisitionSettlesOnlyIntoExactCleanupOwnership() throws {
        let fixture = try OwnedResourceFixture()
        let ticket = fixture.acquisition
        XCTAssertTrue(fixture.registry.claimStart(ticket))
        XCTAssertNotNil(fixture.registry.terminateCleanupReservation(fixture.reservation.ticket))
        do {
            let lease = ResourceLifetimeSpy(fixture.lifetime)
            let monitor = ResourceLifetimeSpy(fixture.lifetime)
            XCTAssertTrue(fixture.registry.completeWithOwnedResult(ticket,
                ownership: fixture.ownership(lease: lease, monitor: monitor, acquisition: ticket)))
        }
        XCTAssertTrue(try fixture.registry.settleOutputAcquisition(ticket),
            "取消后的迟到lease只能由原managed record转入清理责任")
        XCTAssertFalse(try fixture.registry.settleOutputAcquisition(ticket))
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.phase, .leaseOnlyCleanup)
        XCTAssertNil(fixture.registry.phase(of: ticket), "迟到结果转入lease-only时同CAS消费准确原record")
        XCTAssertEqual(try fixture.registry.retireOutputControlRecord(ticket), .rejected)
        XCTAssertEqual(fixture.lifetime.count, 0)
    }

    func testReservationRejectsInsufficientCapacityWithoutPartialGroupOrCommand() throws {
        let registry = ControlTaskRegistry()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        for value in 0..<9 {
            let group = try registry.createGroup(resource: .context(session: session, nonce: UInt64(value)))
            _ = try registry.enqueue(group: group, slot: .sampler, policy: .safetyBypass)
        }
        XCTAssertThrowsError(try registry.reserveCleanup(resource: .session(session)))
        XCTAssertEqual(registry.occupancy.groups, 9)
        XCTAssertEqual(registry.occupancy.safetySlots, 9)
        XCTAssertEqual(registry.occupancy.reservedSafetySlots, 0)
    }

    func testReservationConsumesEightSafetyPositionsButCreatesNoExecutableRecord() throws {
        let registry = ControlTaskRegistry()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let reservation = try registry.reserveCleanup(resource: .session(session))
        XCTAssertEqual(registry.occupancy.groups, 2)
        XCTAssertEqual(registry.occupancy.safetySlots, 0)
        XCTAssertEqual(registry.occupancy.reservedSafetySlots, 8)
        for stage in ReservedCleanupStage.allCases {
            XCTAssertNil(registry.phase(of: reservation.task(for: stage)))
            XCTAssertFalse(registry.claimStart(reservation.task(for: stage)))
        }
        for value in 0..<8 {
            let group = try registry.createGroup(resource: .context(session: session, nonce: UInt64(value)))
            _ = try registry.enqueue(group: group, slot: .sampler, policy: .safetyBypass)
        }
        let extra = try registry.createGroup(resource: .context(session: session, nonce: 99))
        XCTAssertThrowsError(try registry.enqueue(group: extra, slot: .sampler, policy: .safetyBypass))
        XCTAssertEqual(registry.occupancy.reservedSafetySlots + registry.occupancy.safetySlots, 16)
        XCTAssertThrowsError(try registry.reserveCleanup(resource: .context(session: session, nonce: 100)))
    }

    func testPreissuedCleanupStillClaimsAfterGlobalAllocatorExhaustionWithoutIssuingNewIdentity() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 64)
        let registry = ControlTaskRegistry(allocator: allocator)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let reservation = try registry.reserveCleanup(resource: .session(session))
        while !allocator.isExhausted { _ = try? allocator.next(in: .activation) }
        let owner = try XCTUnwrap(registry.terminateCleanupReservation(reservation.ticket))
        XCTAssertEqual(registry.terminateCleanupReservation(reservation.ticket), owner)
        XCTAssertThrowsError(try registry.enqueue(group: reservation.ticket.workGroup, slot: .factory,
            policy: .routeSpeculativeRateZero))
        for stage: ReservedCleanupStage in [.owner, .suspend, .retirement, .teardown, .monitorStop, .leaseRelease] {
            let ticket = try registry.enqueueReservedCleanup(reservation.ticket, stage: stage)
            XCTAssertEqual(ticket, reservation.task(for: stage))
            XCTAssertEqual(try registry.enqueueReservedCleanup(reservation.ticket, stage: stage), ticket)
            XCTAssertTrue(registry.claimStart(ticket))
            XCTAssertTrue(registry.complete(ticket))
            XCTAssertTrue(registry.retire(ticket))
            XCTAssertThrowsError(try registry.enqueueReservedCleanup(reservation.ticket, stage: stage))
        }
        XCTAssertTrue(allocator.isExhausted)
    }
}

/// 测试只通过真实cell设置/读取gate，不提供生产资源决策旁路。
private func setTestRouteGate(_ open: Bool, registry: ControlTaskRegistry) {
    registry.executor.sync {
        while true {
            switch registry.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership,
                operation: { $0.routeObservationGateOpen = open }) {
            case .retry: continue
            case .performed: return
            case .rejected: XCTFail("测试gate设置被拒绝"); return
            }
        }
    }
}

private func testRouteGate(registry: ControlTaskRegistry) -> Bool {
    var open = false
    registry.executor.sync {
        while true {
            switch registry.executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership,
                operation: { $0.routeObservationGateOpen }) {
            case .retry: continue
            case .performed(let value): open = value; return
            case .rejected: XCTFail("清理只读barrier不应拒绝"); return
            }
        }
    }
    return open
}

/// fixture只驱动真实登记/完成入口；停止次序与资源是否可释放仍由生产图判断。
private func stopOwnedMonitor(_ registry: ControlTaskRegistry) throws {
    let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
    let ticket = try XCTUnwrap(registry.beginOutputMonitorStop(contextNonce: context.contextNonce))
    XCTAssertTrue(registry.claimStart(ticket))
    XCTAssertTrue(OutputCleanupCoordinator(registry: registry).completeMonitorStop(ticket,
        lifecycle: try graphMonitorLifecycle(registry)))
}

private func graphMonitorLifecycle(_ registry: ControlTaskRegistry) throws -> UInt64 {
    switch registry.ownedResourceSnapshot()?.payload {
    case .monitor(_, let lifecycle): return lifecycle
    case .lease(_, _, let lifecycle, _), .backend(_, _, _, let lifecycle, _): return try XCTUnwrap(lifecycle)
    default: throw ControlTaskRegistry.Failure.invalidGroup
    }
}

private func assertSameReservation(_ lhs: CleanupReservation, _ rhs: CleanupReservation,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.ticket, rhs.ticket, file: file, line: line)
    XCTAssertEqual(lhs.contextNonce, rhs.contextNonce, file: file, line: line)
    XCTAssertEqual(lhs.terminalOwner, rhs.terminalOwner, file: file, line: line)
    XCTAssertEqual(lhs.terminal, rhs.terminal, file: file, line: line)
    XCTAssertEqual(lhs.deactivationPhaseNonce, rhs.deactivationPhaseNonce, file: file, line: line)
    XCTAssertEqual(lhs.predecessorContextNonce, rhs.predecessorContextNonce, file: file, line: line)
    XCTAssertEqual(lhs.leaseOnlyContextNonce, rhs.leaseOnlyContextNonce, file: file, line: line)
    XCTAssertEqual(lhs.monitorOnlyContextNonce, rhs.monitorOnlyContextNonce, file: file, line: line)
    XCTAssertEqual(lhs.retainedSuccessorContextNonce, rhs.retainedSuccessorContextNonce, file: file, line: line)
    XCTAssertEqual(lhs.consumedConversions, rhs.consumedConversions, file: file, line: line)
    for stage in ReservedCleanupStage.allCases {
        XCTAssertEqual(lhs[stage].index, rhs[stage].index, file: file, line: line)
        XCTAssertEqual(lhs[stage].nonce, rhs[stage].nonce, file: file, line: line)
        XCTAssertEqual(lhs[stage].consumed, rhs[stage].consumed, file: file, line: line)
    }
}

private final class ResourceLifetimeObservation: @unchecked Sendable {
    weak var registry: ControlTaskRegistry?
    private let lock = NSLock()
    private var storedCount = 0
    private var storedOnExecutor = false
    init(registry: ControlTaskRegistry) { self.registry = registry }
    var count: Int { lock.withLock { storedCount } }
    var releasedOnExecutor: Bool { lock.withLock { storedOnExecutor } }
    func released() {
        lock.withLock {
            storedCount += 1
            storedOnExecutor = storedOnExecutor || registry?.executor.isIsolated == true
        }
    }
}

private final class ResourceLifetimeSpy: OwnedPlaybackResource {
    let observation: ResourceLifetimeObservation
    init(_ observation: ResourceLifetimeObservation) { self.observation = observation }
    deinit { observation.released() }
}

typealias OutputTestClock = ManualPlaybackClock

/// 图层SDK替代器只回送这次真实claim的完整原permit，不读取回调时的current来重造调用身份。
func claimGraphAudioCall(_ registry: ControlTaskRegistry, lane: AudioSessionBlockingCallLane, _ ticket: ControlTaskTicket,
    family: AudioSessionCallFamily = .audio) throws -> AudioSessionBlockingCallRequest {
    guard case .claimed(let request) = registry.executor.performAudioSessionCall(.claim(ticket, lane: lane, family: family)) else {
        XCTFail("准确queued AudioSession原票未能claim")
        throw ControlTaskRegistry.Failure.invalidGroup
    }
    return request
}

func completeGraphAudioCall(_ registry: ControlTaskRegistry, lane: AudioSessionBlockingCallLane, _ request: AudioSessionBlockingCallRequest,
    _ result: AudioSessionBlockingCallResult) throws -> AudioSessionBlockingCallCompletion {
    guard case .completed(let completion, _, _, _) = registry.executor.performAudioSessionCall(
        .complete(.init(permit: request.permit, result: result), lane: lane)) else {
        XCTFail("准确SDK结果未结清")
        throw ControlTaskRegistry.Failure.invalidGroup
    }
    return completion
}

func graphAudioCall(_ registry: ControlTaskRegistry, lane: AudioSessionBlockingCallLane, _ ticket: ControlTaskTicket,
    _ result: AudioSessionBlockingCallResult) throws -> AudioSessionBlockingCallCompletion {
    try completeGraphAudioCall(registry, lane: lane, claimGraphAudioCall(registry, lane: lane, ticket), result)
}

func graphOwnedDeactivation(_ registry: ControlTaskRegistry) -> AudioSessionDeactivationDisposition? {
    switch registry.ownedResourceSnapshot()?.payload {
    case .lease(_, _, _, let disposition), .backend(_, _, _, _, let disposition): return disposition
    default: return nil
    }
}

/// 图层事实替代只手工回送真实claim的结果，不执行owner链；新生命周期测试不使用此边界。
private final class GraphAudioSessionSDK: PlaybackAudioSessionSDK, Sendable {
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {}
    func setSupportsMultichannelContent() throws {}
    func activate() throws {}
    func deactivate() throws {}
    func currentRoute() -> any AudioSessionRouteSnapshot { GraphEmptyRoute() }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, base) == errSecSuccess
    }
}
private final class GraphEmptyRoute: AudioSessionRouteSnapshot, Sendable {
    var endpointCount: Int { 0 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint { preconditionFailure("空路由不存在端点") }
}
func bindGraphAudioSessionLane(_ registry: ControlTaskRegistry) throws -> AudioSessionBlockingCallLane {
    let lane = AudioSessionBlockingCallLane(sdk: GraphAudioSessionSDK())
    guard registry.bindAudioSessionLane(lane) else { throw ControlTaskRegistry.Failure.invalidGroup }
    return lane
}

/// 图层测试仍让真实lane投影产生有界端点证据；最终token由Authority签发。
struct GraphRouteCall {
    let request: AudioSessionBlockingCallRequest
    let observation: RouteObservationTicket
    let lane: AudioSessionBlockingCallLane
    // 原claim后的只读通知元数据，仅用于测试制造下一通知；不参与SDK权限或最终token发行。
    let notificationRevision: UInt64
    let observationHint: PlaybackRouteSemanticIdentity?
    var source: ControlTaskTicket { request.permit.record }
}

func claimGraphRoute(_ registry: ControlTaskRegistry, lane: AudioSessionBlockingCallLane,
    observation: RouteObservationTicket, source: ControlTaskTicket) throws -> GraphRouteCall {
    let request = try claimGraphAudioCall(registry, lane: lane, source, family: .sampler)
    XCTAssertEqual(request.permit.operation, .currentRoute)
    guard case .pending(let pending) = registry.outputRouteObservationSnapshot(), pending.ticket == observation,
          pending.sampler == source, pending.sampleInFlight else { throw ControlTaskRegistry.Failure.invalidGroup }
    return .init(request: request, observation: observation, lane: lane,
        notificationRevision: pending.latestNotificationRevision, observationHint: pending.latestObservation?.observedRoute)
}

final class GraphRouteSnapshot: AudioSessionRouteSnapshot, Sendable {
    let endpoints: [AudioSessionRouteEndpoint]
    init(_ endpoints: [AudioSessionRouteEndpoint]) { self.endpoints = endpoints }
    var endpointCount: Int { endpoints.count }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint { endpoints[index] }
    static var builtIn: GraphRouteSnapshot {
        .init([.init(uid: "图层内置输出", portType: AVAudioSession.Port.builtInSpeaker.rawValue as NSString, dataSource: .missing)])
    }
    static func ports(_ ports: PlaybackRoutePorts, endpointKey: String = "图层端点") -> GraphRouteSnapshot {
        let values: [(PlaybackRoutePorts, AVAudioSession.Port)] = [(.builtIn, .builtInSpeaker), (.hdmi, .HDMI),
            (.airPlay, .airPlay), (.bluetooth, .bluetoothA2DP), (.other, AVAudioSession.Port(rawValue: "其他"))]
        return .init(values.filter { ports.contains($0.0) }.map {
            .init(uid: "\(endpointKey)-\($0.1.rawValue)" as NSString,
                portType: $0.1.rawValue as NSString, dataSource: .missing)
        })
    }
}

func completeGraphRoute(_ registry: ControlTaskRegistry, _ call: GraphRouteCall,
    snapshot: any AudioSessionRouteSnapshot) throws -> AudioSessionBlockingCallCompletion {
    let registration = try XCTUnwrap(call.request.registration)
    let evidence = AudioSessionBlockingCallLane.project(snapshot, salt: registration.salt)
    return try completeGraphAudioCall(registry, lane: call.lane, call.request, .route(evidence))
}

struct ResetAcquiringOutputFixture {
    let clock: OutputTestClock
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let acquire: ControlTaskTicket
    let parentIdentity: PlaybackProgressBudgetTicket.Identity
    init(allocator: PlaybackIdentityAllocator = .init(),
        clock: OutputTestClock = .init(100)) throws {
        self.clock = clock
        registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        lane = try bindGraphAudioSessionLane(registry)
        let root = try capturedResetRoot(registry)
        let proof = try XCTUnwrap(registry.issueEmptyOutputResetDrainProof(root: root))
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        parentIdentity = .init(sessionIdentity: session, nonce: 1)
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: parentIdentity,
            kind: .coldStart, originInstant: 50, cap: 40_000_000_000,
            accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        acquire = try XCTUnwrap(registry.beginResetOutputAcquisition(session: session, parent: parent,
            admission: .init(proof: proof, mandatorySuffix: 30_000_000_000, inheritedRouteAvailabilityConstraint: nil)))
    }
    func acceptLease() throws {
        XCTAssertTrue(registry.claimStart(acquire))
        let salt = try XCTUnwrap(lane.makeEndpointSalt())
        XCTAssertNotNil(try registry.registerAudioSessionLease(acquire, salt: salt))
    }
    func configureAndHandoff(capability: Bool = true) throws {
        try acceptLease()
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let parent = try XCTUnwrap(context.parentDeadline)
        let category = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(contextNonce: context.contextNonce, parent: parent))
        let categoryCompletion = try graphAudioCall(registry, lane: lane, category, .configuration(.categorySucceeded))
        let multichannel = try XCTUnwrap(categoryCompletion.followUp)
        let completed = try graphAudioCall(registry, lane: lane, multichannel, .configuration(.multichannelCapability(capability)))
        XCTAssertEqual(completed.disposition, .accepted)
        XCTAssertNil(completed.followUp, "inactive配置不会偷偷启动activation")
        XCTAssertNil(registry.phase(of: category))
        XCTAssertNil(registry.phase(of: multichannel))
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try registry.commitAcquisitionRelayAndContext(token) else { return XCTFail("inactive交接失败") }
    }
    @discardableResult
    func activateResetAndCommit() throws -> ControlTaskTicket {
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce))
        let completion = try graphAudioCall(registry, lane: lane, activation, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        let sampler = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(registry.phase(of: sampler), .queued)
        XCTAssertNil(registry.phase(of: activation))
        return activation
    }
}

struct AcquiringOutputFixture {
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let clock: OutputTestClock
    let contextNonce: UInt64
    let parent: CurrentPlaybackOperationDeadlineTicket
    let acquisition: ControlTaskTicket
    init(registry suppliedRegistry: ControlTaskRegistry? = nil, sessionID: UInt64 = 1, requestID: UUID = UUID(),
        clock: OutputTestClock = .init(100), parentCap: UInt64 = 15_000_000_000,
        resetRecoveryMandatorySuffix: UInt64 = 3_000_000_000, audioLane: AudioSessionBlockingCallLane? = nil) throws {
        let registry = suppliedRegistry ?? ControlTaskRegistry(allocator: .init(), clock: clock)
        self.registry = registry
        self.lane = try audioLane ?? bindGraphAudioSessionLane(registry)
        guard registry.bindAudioSessionLane(lane) else { throw ControlTaskRegistry.Failure.invalidGroup }
        self.clock = clock
        let session = PlaybackSessionIdentity(sessionID: sessionID, requestID: requestID)
        parent = .coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1), kind: .coldStart,
            originInstant: 0, cap: parentCap, accumulatedEffectiveTime: 0, runningSince: nil, freezeGeneration: 0))
        acquisition = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent,
            resetRecoveryMandatorySuffix: resetRecoveryMandatorySuffix))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline, parent)
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        contextNonce = reservation.contextNonce
        XCTAssertTrue(registry.claimStart(acquisition))
        let salt = try XCTUnwrap(lane.makeEndpointSalt())
        XCTAssertNotNil(try registry.registerAudioSessionLease(acquisition, salt: salt))
    }

    func prepareActivation(capability: Bool = true,
        actualPolicy: AudioSessionActualPolicy = .longFormAudio) throws -> ControlTaskTicket {
        let category = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent))
        let preferredFailure = AudioSessionFixedFailure(domain: .audioSession, code: -1)
        var completion = try graphAudioCall(registry, lane: lane, category,
            .configuration(actualPolicy == .longFormAudio ? .categorySucceeded : .failed(preferredFailure)))
        XCTAssertNil(registry.phase(of: category))
        if actualPolicy == .default {
            let fallback = try XCTUnwrap(completion.followUp)
            completion = try graphAudioCall(registry, lane: lane, fallback, .configuration(.categorySucceeded))
            XCTAssertNil(registry.phase(of: fallback))
        }
        let multichannel = try XCTUnwrap(completion.followUp)
        completion = try graphAudioCall(registry, lane: lane, multichannel, .configuration(.multichannelCapability(capability)))
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertNil(registry.phase(of: multichannel))
        let activation = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(registry.phase(of: activation), .queued)
        return activation
    }

    func configureAndActivate(actualPolicy: AudioSessionActualPolicy = .longFormAudio) throws -> ControlTaskTicket {
        let activation = try prepareActivation(actualPolicy: actualPolicy)
        let completion = try graphAudioCall(registry, lane: lane, activation, .activation(nil))
        XCTAssertEqual(completion.disposition, .accepted)
        XCTAssertNil(completion.followUp)
        XCTAssertNotNil(registry.outputAcquisitionCommitSnapshot())
        XCTAssertNil(registry.phase(of: activation))
        return activation
    }
}

/// 旧4b oracle共享的真实准备链；仅选择SDK测试输入，不登记外来phase或proof。
struct ActualAudioConfigurationFixture {
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let ticket: ControlTaskTicket
    private let contextNonce: UInt64
    private let parent: CurrentPlaybackOperationDeadlineTicket
    private let resetInactive: Bool

    init(resetInactive: Bool = false, resetAcquisition: Bool = false) throws {
        self.resetInactive = resetInactive
        if resetInactive {
            let fixture = try ResetAcquiringOutputFixture()
            try fixture.configureAndHandoff()
            registry = fixture.registry
            lane = fixture.lane
            _ = try capturedResetRoot(registry)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(OutputCleanupCoordinator(registry: registry).begin(contextNonce: context.contextNonce,
                reason: .recovery, at: fixture.clock.read(), teardown: true))
            let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
            XCTAssertTrue(registry.claimStart(ownerTask))
            XCTAssertTrue(registry.complete(ownerTask))
            XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
            ticket = try XCTUnwrap(registry.beginRetainedOutputResetConfiguration(owner: owner, mandatorySuffix: 3_000_000_000))
            let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
            contextNonce = retained.contextNonce
            parent = try XCTUnwrap(retained.parentDeadline)
        } else if resetAcquisition {
            let fixture = try ResetAcquiringOutputFixture()
            try fixture.acceptLease()
            registry = fixture.registry
            lane = fixture.lane
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            contextNonce = context.contextNonce
            parent = try XCTUnwrap(context.parentDeadline)
            ticket = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent))
        } else {
            let fixture = try AcquiringOutputFixture()
            registry = fixture.registry
            lane = fixture.lane
            contextNonce = fixture.contextNonce
            parent = fixture.parent
            ticket = try XCTUnwrap(registry.beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent))
        }
    }

    func next() throws -> ControlTaskTicket? {
        if resetInactive { return try registry.beginOutputRetainedResetConfigurationStep(contextNonce: contextNonce) }
        return try registry.beginOutputAcquisitionConfiguration(contextNonce: contextNonce, parent: parent)
    }
}

struct ActualAudioActivationFixture {
    let allocator = PlaybackIdentityAllocator()
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let ticket: ControlTaskTicket
    let kind: Int

    init(kind: Int, capability: Bool = true) throws {
        self.kind = kind
        if kind == 0 {
            let clock = OutputTestClock(100)
            let fixture = try AcquiringOutputFixture(
                registry: ControlTaskRegistry(allocator: allocator, clock: clock), clock: clock)
            registry = fixture.registry
            lane = fixture.lane
            ticket = try fixture.prepareActivation(capability: capability)
        } else {
            let fixture = try ResetAcquiringOutputFixture(allocator: allocator)
            try fixture.configureAndHandoff(capability: capability)
            registry = fixture.registry
            lane = fixture.lane
            if kind == 1 {
                ticket = try XCTUnwrap(registry.beginOutputResetConfigurationActivation(
                    contextNonce: try XCTUnwrap(registry.outputResourceContextSnapshot()).contextNonce))
            } else {
                let previous = try fixture.activateResetAndCommit()
                XCTAssertNil(registry.phase(of: previous), "组合完成已退休原activation，sampler后继仍由新原票承接")
                fixture.clock.set(200)
                registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
                fixture.clock.set(300)
                registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
                ticket = try XCTUnwrap(registry.beginOutputReactivation(
                    contextNonce: try XCTUnwrap(registry.outputResourceContextSnapshot()).contextNonce,
                    mandatorySuffix: 1_000_000_000))
            }
        }
    }

}

struct ActualOrdinaryReactivationFixture {
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let ticket: ControlTaskTicket
    let proof: InterruptionDrainProof

    init(drainBeforeEnded: Bool) async throws {
        var preparedProof: InterruptionDrainProof?
        let fixture = try StableOutputFixture()
        registry = fixture.registry
        lane = fixture.acquisition.lane
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let identity = try XCTUnwrap(registry.outputResourceContextSnapshot()?.candidateBackendIdentity)
        let backend = TrackingPlaybackBackend(identity: identity, kind: .sampleBuffer, harness: nil)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: backend))
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = registry.outputResourceContextSnapshot()
        if let source = context.sourceTask { XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil)) }
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .recovery,
            at: fixture.acquisition.clock.read(), teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        let cleanup = try XCTUnwrap(registry.claimOutputBackendCleanup(stop.task, owner: owner))
        let invocation = try XCTUnwrap(cleanup.suspendInvocation)
        let suspended = await cleanup.backend.suspendOutput(invocation: invocation)
        guard case .quiescent = suspended else { throw ControlTaskRegistry.Failure.invalidGroup }
        XCTAssertTrue(registry.completeOutputSuspend(suspended, invocation: invocation, backend: cleanup.backend))
        let retirement = try XCTUnwrap(coordinator.advance(owner: owner))
        let retiring = try XCTUnwrap(registry.claimOutputBackendCleanup(retirement, owner: owner))
        let retirementResult = await retiring.backend.retireOutput(epoch: invocation.lifecycle)
        XCTAssertEqual(retirementResult, .confirmedLocalOutputStopped)
        XCTAssertTrue(coordinator.completeRetirement(retirement, lifecycle: invocation.lifecycle))
        if drainBeforeEnded {
            guard case .settled(let value, nil) = registry.settleOutputInterruptionDrain(owner: owner) else { throw ControlTaskRegistry.Failure.invalidGroup }
            preparedProof = value
        }
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let ownerTask = try XCTUnwrap(registry.outputCleanupOwnerTask(owner))
        XCTAssertTrue(registry.complete(ownerTask))
        XCTAssertEqual(try registry.retireOutputControlRecord(ownerTask), .retired(followUp: nil))
        registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        if drainBeforeEnded {
            ticket = try XCTUnwrap(registry.beginOutputReactivation(contextNonce: context.contextNonce, mandatorySuffix: 1_000_000_000))
        } else {
            guard case .settled(let value, let followUp) = registry.settleOutputInterruptionDrain(owner: owner) else { throw ControlTaskRegistry.Failure.invalidGroup }
            preparedProof = value
            ticket = try XCTUnwrap(followUp)
        }
        proof = try XCTUnwrap(preparedProof)
    }
}

private final class OutputNoopTerminalCleanupReceiver: PlaybackOwnedCleanupReceiving, @unchecked Sendable {
    func performOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
        task: ControlTaskTicket, terminalState: PlaybackState) async {}
}

struct OutputGraphFixture {
    let stable: StableOutputFixture
    let registry: ControlTaskRegistry
    let coordinator: OutputCleanupCoordinator
    let lifecycle: OutputLifecycleEpoch
    var lane: AudioSessionBlockingCallLane { stable.lane }
    init(allocator: PlaybackIdentityAllocator = .init(), registry suppliedRegistry: ControlTaskRegistry? = nil,
        clock: OutputTestClock = .init(100),
        backendObject: (any OwnedPlaybackResource)? = nil,
        audioLane: AudioSessionBlockingCallLane? = nil) throws {
        stable = try StableOutputFixture(allocator: allocator, registry: suppliedRegistry, clock: clock,
            audioLane: audioLane)
        registry = stable.registry
        coordinator = .init(registry: registry)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: stable.stable, owner: nil))
        let claim = try XCTUnwrap(rebase.successorClaim)
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(claim))
        XCTAssertTrue(registry.claimStart(factory))
        XCTAssertTrue(try registry.completeOutputFactory(factory,
            candidate: backendObject ?? ResourceLifetimeSpy(ResourceLifetimeObservation(registry: registry))))
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
        guard case .backend(_, let current, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
            throw ControlTaskRegistry.Failure.invalidGroup
        }
        lifecycle = try XCTUnwrap(current)
    }
}

func capturedResetRoot(_ registry: ControlTaskRegistry) throws -> MediaServicesResetRootIdentity {
    var ingress: PendingResetIngress?
    registry.executor.sync {
        registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        ingress = registry.executor.safetyIngress.snapshot.system.latestResetIngress
    }
    let value = try XCTUnwrap(ingress)
    return .init(resetTicket: value.rootIdentity, mediaServicesEpoch: value.mediaServicesEpoch)
}

func userControlRequest(_ registry: ControlTaskRegistry, kind: OutputUserControlKind) throws -> OutputUserControlRequest {
    let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
    let snapshot = registry.executor.safetyIngress.snapshot
    return .init(kind: kind, sessionIdentity: context.sessionIdentity, expectedOwner: context.owner,
        contextNonce: context.contextNonce, interruptionEpoch: snapshot.interruptionEpoch,
        mediaServicesEpoch: snapshot.mediaServicesEpoch, resetPreRouteBinding: context.resetPreRouteBinding)
}

private func forgedStableCommit(session: PlaybackSessionIdentity) -> StableRouteCommitIdentity {
    .init(epoch: 1, authority: .init(sessionIdentity: session, monitorLifecycle: 1,
        mediaServicesEpoch: 0, interruptionEpoch: 0, audioSessionConfigurationGeneration: 0,
        audioSessionActivationNonce: 1, audioAdmissionFenceRevision: 0, routeObservationRevision: 0,
        semanticIdentity: .init(ports: .builtIn, backend: .sampleBuffer,
            outputConfigurationIncarnation: .init(rawValue: 1), endpointTopologyToken: .init(rawValue: 1)),
        configurationTransitionIdentity: nil, postConfigurationStageIdentity: nil, systemOpenConfigurationGeneration: 0))
}

private func rawOrdinaryRouteDeadlineArm(_ registry: ControlTaskRegistry) -> RouteUnavailableDeadlineArmTicket? {
    guard let authority = Mirror(reflecting: registry).children.first(where: { $0.label == "authority" })?.value,
          let rawState = Mirror(reflecting: authority).children.first(where: { $0.label == "routeObservationState" })?.value
    else { return nil }
    let stateValue: Any
    if Mirror(reflecting: rawState).displayStyle == .optional {
        guard let value = Mirror(reflecting: rawState).children.first?.value else { return nil }
        stateValue = value
    } else {
        stateValue = rawState
    }
    guard let state = stateValue as? RouteObservationState, case .pending(let pending) = state else { return nil }
    return pending.ordinaryDeadlineState?.arm
}

struct StableOutputFixture {
    let acquisition: AcquiringOutputFixture
    let stable: StableRouteCommitIdentity
    var registry: ControlTaskRegistry { acquisition.registry }
    var lane: AudioSessionBlockingCallLane { acquisition.lane }
    init(allocator: PlaybackIdentityAllocator = .init(), registry suppliedRegistry: ControlTaskRegistry? = nil,
        clock: OutputTestClock = .init(100), audioLane: AudioSessionBlockingCallLane? = nil,
        requestID: UUID = UUID()) throws {
        let ownerRegistry = suppliedRegistry ?? ControlTaskRegistry(allocator: allocator, clock: clock)
        acquisition = try AcquiringOutputFixture(registry: ownerRegistry, requestID: requestID,
            clock: clock, audioLane: audioLane)
        let registry = acquisition.registry
        let activation = try acquisition.configureAndActivate()
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else { throw ControlTaskRegistry.Failure.invalidGroup }
        let observation = try XCTUnwrap(handoff.routeObservation)
        let sampler = try XCTUnwrap(handoff.sampler)
        let claim = try claimGraphRoute(registry, lane: acquisition.lane, observation: observation, source: sampler)
        XCTAssertEqual(try completeGraphRoute(registry, claim, snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        let timer = try XCTUnwrap(registry.armOutputRouteStability(observation: observation))
        acquisition.clock.set(timer.deadlineInstant)
        stable = try XCTUnwrap(registry.commitOutputRouteStability(timer))
        XCTAssertNil(registry.phase(of: activation), "组合activation完成已退休原票，稳定候选保留的是sampler原票")
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(registry.seal(context.reservation.workGroup))
        XCTAssertNotNil(try registry.renewOutputCycle(contextNonce: context.contextNonce))
    }
}

private struct OwnedResourceFixture {
    let registry: ControlTaskRegistry
    let lane: AudioSessionBlockingCallLane
    let reservation: CleanupReservation
    let acquisition: ControlTaskTicket
    let lifetime: ResourceLifetimeObservation
    let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
    init(allocator: PlaybackIdentityAllocator = .shared) throws {
        registry = ControlTaskRegistry(allocator: allocator, clock: ManualPlaybackClock(100))
        lane = try bindGraphAudioSessionLane(registry)
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(identity: .init(sessionIdentity: session, nonce: 1),
            kind: .coldStart, originInstant: 0, cap: 40_000_000_000, accumulatedEffectiveTime: 0,
            runningSince: nil, freezeGeneration: 0))
        acquisition = try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent,
            resetRecoveryMandatorySuffix: 30_000_000_000))
        reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        lifetime = ResourceLifetimeObservation(registry: registry)
    }
    func completedAcquisition() throws -> ControlTaskTicket {
        let acquire = acquisition
        XCTAssertTrue(registry.claimStart(acquire))
        XCTAssertTrue(registry.completeWithOwnedResult(acquire, ownership: ownership(
            lease: ResourceLifetimeSpy(lifetime), monitor: ResourceLifetimeSpy(lifetime), acquisition: acquire)))
        return acquire
    }
    func ownership(lease: any OwnedPlaybackResource, monitor: any OwnedPlaybackResource,
                   acquisition: ControlTaskTicket) -> OutputResourceOwnership {
        .init(reservation: reservation.ticket, contextNonce: reservation.contextNonce,
            mediaServicesEpoch: 0, interruptionEpoch: 0, audioAdmissionFenceRevision: 0,
            payload: .lease(.init(leaseID: 1, object: lease,
                monitor: .init(sessionIdentity: session, lifecycle: 1, object: monitor),
                deactivation: .confirmedInactive(.reservation(.init(acquisitionTicket: acquisition,
                    sessionIdentity: session, leaseID: 1, contextNonce: reservation.contextNonce, ownershipNonce: 1))))))
    }
}
