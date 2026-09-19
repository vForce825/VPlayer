// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackDeadlineTests: XCTestCase {
    func testCleanupBudgetUsesOneAbsoluteFiveSecondBoundary() throws {
        let clock = ManualPlaybackClock(nowNanoseconds: 0)
        let allocator = PlaybackIdentityAllocator()
        let session = PlaybackSessionIdentity(
            sessionID: try allocator.next(in: .session), requestID: UUID()
        )
        let budget = try CleanupBudgetTicket(
            predecessorIdentity: .session(session), anchorInstant: clock.nowNanoseconds,
            nonce: try allocator.next(in: .deadline)
        )

        clock.advance(nanoseconds: 4_000_000_000)
        XCTAssertEqual(budget.remainingNanoseconds(at: clock.nowNanoseconds), 1_000_000_000)
        XCTAssertFalse(budget.isExpired(at: clock.nowNanoseconds))
        clock.advance(nanoseconds: 1_000_000_000)
        XCTAssertEqual(budget.remainingNanoseconds(at: clock.nowNanoseconds), 0)
        XCTAssertTrue(budget.isExpired(at: clock.nowNanoseconds))
        clock.advance(nanoseconds: 1)
        XCTAssertTrue(budget.isExpired(at: clock.nowNanoseconds))
    }

    func testAcquisitionDeadlineHasStrictFiveSecondSuccessWindowAndCheckedAnchor() throws {
        let fixture = try DeadlineIdentityFixture()
        let deadline = try AudioSessionAcquisitionDeadline(
            acquisitionTicket: fixture.controlTask, anchorInstant: 10
        )

        XCTAssertEqual(deadline.remainingNanoseconds(at: 4_999_999_999 + 10), 1)
        XCTAssertFalse(deadline.isExpired(at: 4_999_999_999 + 10))
        XCTAssertEqual(deadline.remainingNanoseconds(at: 5_000_000_000 + 10), 0)
        XCTAssertTrue(deadline.isExpired(at: 5_000_000_000 + 10))
        XCTAssertThrowsError(try AudioSessionAcquisitionDeadline(
            acquisitionTicket: fixture.controlTask, anchorInstant: UInt64.max - 4_999_999_999
        )) { XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow) }
    }

    func testProgressBudgetAccumulatesOnlyRunningWindowsWithoutChangingAnchorOrCap() throws {
        let fixture = try DeadlineIdentityFixture()
        var budget = PlaybackProgressBudgetTicket(
            identity: .init(sessionIdentity: fixture.session, nonce: 7), kind: .coldStart,
            originInstant: 100, cap: 40_000_000_000,
            accumulatedEffectiveTime: 4_000_000_000, runningSince: 1_000,
            freezeGeneration: 3
        )

        XCTAssertEqual(try budget.effectiveElapsed(at: 2_000), 4_000_001_000)
        XCTAssertEqual(try budget.remainingNanoseconds(at: 2_000), 35_999_999_000)
        try budget.freeze(at: 2_000, freezeGeneration: 4)
        XCTAssertEqual(budget.accumulatedEffectiveTime, 4_000_001_000)
        XCTAssertNil(budget.runningSince)
        XCTAssertEqual(try budget.effectiveElapsed(at: UInt64.max), 4_000_001_000)
        budget.resume(at: 9_000, freezeGeneration: 5)
        XCTAssertEqual(budget.runningSince, 9_000)
        XCTAssertEqual(budget.originInstant, 100)
        XCTAssertEqual(budget.cap, 40_000_000_000)
    }

    func testProgressBudgetRejectsBackwardClockAndElapsedOverflow() throws {
        let fixture = try DeadlineIdentityFixture()
        let backward = PlaybackProgressBudgetTicket(
            identity: .init(sessionIdentity: fixture.session, nonce: 8), kind: .coldStart,
            originInstant: 0, cap: 40_000_000_000,
            accumulatedEffectiveTime: 0, runningSince: 10, freezeGeneration: 0
        )
        XCTAssertThrowsError(try backward.effectiveElapsed(at: 9)) {
            XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow)
        }
        let overflow = PlaybackProgressBudgetTicket(
            identity: .init(sessionIdentity: fixture.session, nonce: 9), kind: .outputRecovery,
            originInstant: 0, cap: 45_000_000_000,
            accumulatedEffectiveTime: UInt64.max, runningSince: 1, freezeGeneration: 0
        )
        XCTAssertThrowsError(try overflow.effectiveElapsed(at: 2)) {
            XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow)
        }
    }

    func testColdStartAndRecoveryUseStrictSixtyAndFortyFiveSecondCaps() throws {
        let fixture = try DeadlineIdentityFixture()
        let cold = PlaybackProgressBudgetTicket.coldStart(
            sessionIdentity: fixture.session, originInstant: 0, nonce: 10, freezeGeneration: 0
        )
        var runningCold = cold
        runningCold.resume(at: 0, freezeGeneration: 1)
        XCTAssertFalse(try runningCold.isExpired(at: 59_999_999_999))
        XCTAssertTrue(try runningCold.isExpired(at: 60_000_000_000))

        let recovery = PlaybackProgressBudgetTicket.outputRecovery(
            sessionIdentity: fixture.session, originInstant: 100, nonce: 11, freezeGeneration: 2
        )
        var runningRecovery = recovery
        runningRecovery.resume(at: 100, freezeGeneration: 3)
        XCTAssertFalse(try runningRecovery.isExpired(at: 45_000_000_099))
        XCTAssertTrue(try runningRecovery.isExpired(at: 45_000_000_100))
    }

    func testAudioOnlySuffixAdmissionUsesExactIntegerNanosecondsAndFailsOnOverflow() throws {
        XCTAssertEqual(try PlaybackDeadlineBudget.audioOnlyCandidateAdmission(
            laterCandidateCount: 2
        ), 20_000_000_000)
        XCTAssertEqual(try PlaybackDeadlineBudget.audioOnlyCandidateAdmission(
            laterCandidateCount: 1
        ), 14_000_000_000)
        XCTAssertEqual(try PlaybackDeadlineBudget.audioOnlyCandidateAdmission(
            laterCandidateCount: 0
        ), 8_000_000_000)
        XCTAssertThrowsError(try PlaybackDeadlineBudget.audioOnlyCandidateAdmission(
            laterCandidateCount: UInt64.max
        )) { XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow) }
        XCTAssertTrue(PlaybackDeadlineBudget.admits(
            remainingNanoseconds: 20_000_000_000, requiredNanoseconds: 20_000_000_000
        ))
        XCTAssertFalse(PlaybackDeadlineBudget.admits(
            remainingNanoseconds: 19_999_999_999, requiredNanoseconds: 20_000_000_000
        ))
    }

    func testResetAndPostStageEffectiveClocksRejectBackwardTimeAndFreezeExactly() throws {
        let fixture = try DeadlineIdentityFixture()
        let parent = PlaybackProgressBudgetTicket.Identity(sessionIdentity: fixture.session, nonce: 20)
        let resetIdentity = ResetPreRouteRecoveryDeadlineTicket.Identity(
            lineageIdentity: 21, sessionIdentity: fixture.session,
            parentOperationTicketIdentity: parent, nonce: 22
        )
        let reset = ResetPreRouteRecoveryDeadlineState(
            ticketIdentity: resetIdentity, mandatorySuffix: 10, boundaryEffectiveElapsed: 30,
            accumulatedEffectiveTime: 7, runningSince: 100, freezeGeneration: 1, deadlineArm: nil
        )
        XCTAssertEqual(try reset.checkedEffectiveElapsed(at: 105), 12)
        XCTAssertThrowsError(try reset.checkedEffectiveElapsed(at: 99)) {
            XCTAssertEqual($0 as? PlaybackSafetyFailure, .clockOverflow)
        }

        let budget = PostConfigurationRouteBudget(
            configurationTransitionIdentity: .reset(fixture.resetIncarnation), stageIdentity: 30,
            carriedStageLineageIdentity: nil, configurationGeneration: 1,
            parentOperationDeadline: parent, inheritedRouteAvailabilityConstraint: nil,
            maximumEffectiveDuration: 3_000_000_000, accumulatedEffectiveTime: 500,
            attemptNonce: 31
        )
        let frozen = PostConfigurationRouteState(
            budget: budget, runningSince: nil, freezeGeneration: 2
        )
        XCTAssertEqual(try frozen.checkedEffectiveElapsed(at: UInt64.max), 500)
    }

    func testReactivationFreezeCausesKeepRouteOutOfActivationBlockers() {
        XCTAssertFalse(AudioSessionReactivationFreezeCauses.routeUnavailable.activationBlocked)
        XCTAssertTrue(AudioSessionReactivationFreezeCauses.systemInterruption.activationBlocked)
        XCTAssertTrue(AudioSessionReactivationFreezeCauses.userPause.activationBlocked)
        XCTAssertTrue(AudioSessionReactivationFreezeCauses([
            .systemInterruption, .routeUnavailable, .userPause
        ]).activationBlocked)
    }

    func testInjectedClockFeedsOneRegistryAndParentArmSurvivesContextTransferUntilExactBoundary() throws {
        let clock = ManualPlaybackClock(nowNanoseconds: 100)
        let registry = ControlTaskRegistry(allocator: .init(), clock: clock)
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.coldStart(
            sessionIdentity: session, originInstant: clock.nowNanoseconds, nonce: 1,
            freezeGeneration: 0
        ))
        let acquisition = try XCTUnwrap(registry.beginOutputAcquisition(
            session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000
        ))
        XCTAssertTrue(registry.claimStart(acquisition))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.acquisitionDeadline?.anchorInstant, 100,
            "Registry与Cell必须读取同一个具名时钟实例")

        let transferred = try StableOutputFixture()
        let transferredRegistry = transferred.registry
        let originalArm = try XCTUnwrap(transferredRegistry.playbackOperationDeadlineArmSnapshot())
        let context = try XCTUnwrap(transferredRegistry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(transferredRegistry.rebaseRetainedOutput(
            contextNonce: context.contextNonce, stableCommit: transferred.stable, owner: nil
        ))
        XCTAssertNotEqual(rebase.contextNonce, context.contextNonce)
        let early = try XCTUnwrap(transferredRegistry.rearmOutputPlaybackOperationDeadline(originalArm))
        XCTAssertEqual(early.arm, originalArm, "context移交不得使同一parent watchdog失权")

        let transferredParent = try XCTUnwrap(transferredRegistry.outputResourceContextSnapshot()?.parentDeadline?.value)
        let runningSince = try XCTUnwrap(transferredParent.runningSince)
        let boundary = runningSince + transferredParent.cap - transferredParent.accumulatedEffectiveTime
        transferred.acquisition.clock.set(boundary - 1)
        XCTAssertEqual(transferredRegistry.rearmOutputPlaybackOperationDeadline(originalArm)?.remainingNanoseconds, 1)
        transferred.acquisition.clock.set(boundary)
        XCTAssertNil(transferredRegistry.rearmOutputPlaybackOperationDeadline(originalArm))
        XCTAssertTrue(transferredRegistry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testMediaProgressRequiresExactInstalledIntervalAndCompletesOnlyItsParentLineage() throws {
        let active = try ActiveDeadlineFixture()
        let registry = active.fixture.registry
        let forged = PlaybackMediaProgressReceipt(
            intervalKey: active.interval, sessionIdentity: active.context.sessionIdentity,
            contextNonce: active.context.contextNonce + 1,
            mediaServicesEpoch: active.snapshot.mediaServicesEpoch,
            interruptionEpoch: active.snapshot.interruptionEpoch,
            audioAdmissionFenceRevision: active.snapshot.audioAdmissionFenceRevision,
            stableRouteCommit: active.fixture.stable.stable
        )
        XCTAssertFalse(registry.completePlaybackMediaProgress(forged))
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.parentDeadline)
        XCTAssertTrue(registry.completePlaybackMediaProgress(active.receipt))
        XCTAssertNil(registry.outputResourceContextSnapshot()?.parentDeadline)
        XCTAssertFalse(registry.completePlaybackMediaProgress(active.receipt), "重复progress不得创建新45秒parent")
    }

    func testFirstProgressThenResetCreatesRunningRecoveryParentInIngressCAS() throws {
        let active = try ActiveDeadlineFixture()
        XCTAssertTrue(active.fixture.registry.completePlaybackMediaProgress(active.receipt))
        let resetInstant = active.clock.read() + 10
        active.clock.set(resetInstant)
        _ = try capturedResetRoot(active.fixture.registry)
        guard case .outputRecovery(let parent) = active.fixture.registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("首progress后的真实reset必须在消费ingress时创建recovery parent")
        }
        XCTAssertEqual(parent.originInstant, resetInstant)
        XCTAssertEqual(parent.cap, 45_000_000_000)
        XCTAssertEqual(parent.runningSince, resetInstant, "reset pre-route不依赖route/active恢复时钟")
        XCTAssertNotNil(active.fixture.registry.resetPreRouteDeadlineSnapshot())
    }

    func testFirstProgressThenOpenRouteCreatesRunningRecoveryParentWithoutSyntheticNone() throws {
        let active = try ActiveDeadlineFixture()
        let registry = active.fixture.registry
        XCTAssertTrue(registry.completePlaybackMediaProgress(active.receipt))
        guard case .open(let open) = registry.outputRouteObservationSnapshot() else {
            return XCTFail("fixture应处于open route")
        }
        let notificationInstant = active.clock.read() + 10
        active.clock.set(notificationInstant)
        registry.executor.safetyIngress.beginRouteObservation(.init(
            sessionIdentity: open.sessionIdentity, monitorLifecycle: open.monitorLifecycle,
            notificationRevision: open.routeObservationRevision + 1, reasonBits: 1,
            topologyChangeHint: false, outputConfigurationChanged: false,
            observedRoute: open.semanticIdentity
        ))
        _ = registry.outputResourceContextSnapshot()
        guard case .outputRecovery(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("首progress后的真实route接纳必须创建recovery parent")
        }
        XCTAssertEqual(parent.runningSince, notificationInstant,
            "同semantic available不能等待虚构none→available才开始计时")
        XCTAssertNotNil(registry.ordinaryRouteDeadlineArmSnapshot())
    }

    func testFirstProgressThenPauseResumeCreatesRunningRecoveryParentInResumeCAS() throws {
        let active = try ActiveDeadlineFixture()
        let registry = active.fixture.registry
        XCTAssertTrue(registry.completePlaybackMediaProgress(active.receipt))
        XCTAssertTrue(registry.complete(try XCTUnwrap(active.context.sourceTask)),
            "真实pause drain前activation command应先完成，避免fixture遗留在途producer")
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(
            contextNonce: active.context.contextNonce, reason: .pause, at: active.clock.read(),
            teardown: false, sourceActivation: active.context.activation
        ))
        let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        let close = try XCTUnwrap(registry.outputResourceContextSnapshot()?.closeClaim)
        XCTAssertTrue(registry.claimStart(suspend.task))
        XCTAssertTrue(coordinator.completeSuspend(.init(
            suspendTicket: suspend, closeClaim: close, directlyConfirmedRateZero: true,
            preparedPreserved: true
        )))
        XCTAssertTrue(registry.finishOutputPause(owner: owner))
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .pause)), .acceptedWaiting)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.parentDeadline)
        let resumeInstant = active.clock.read() + 10
        active.clock.set(resumeInstant)
        XCTAssertEqual(registry.performOutputUserControl(try userControlRequest(registry, kind: .resume)), .acceptedWaiting)
        guard case .outputRecovery(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("typed resume必须在同一CAS补建恢复parent")
        }
        XCTAssertEqual(parent.runningSince, resumeInstant)
    }

    func testFirstProgressThenRecoveryTransitionStartsSameSemanticRecoveryImmediately() throws {
        let active = try ActiveDeadlineFixture()
        let registry = active.fixture.registry
        XCTAssertTrue(registry.completePlaybackMediaProgress(active.receipt))
        let transitionInstant = active.clock.read() + 10
        active.clock.set(transitionInstant)
        XCTAssertNotNil(try registry.beginOutputTransition(
            contextNonce: active.context.contextNonce, reason: .recovery,
            anchorInstant: 0, teardown: false, sourceActivation: active.context.activation
        ))
        guard case .outputRecovery(let parent) = registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("真实recovery transition必须补建parent")
        }
        XCTAssertEqual(parent.originInstant, transitionInstant, "caller anchor不能授权parent计时")
        XCTAssertEqual(parent.runningSince, transitionInstant)
    }

    func testColdParentWaitsForTypedAvailableAndUserResumeCannotStartUnknownRouteClock() throws {
        let fixture = try AcquiringOutputFixture(parentCap: UInt64.max)
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("普通active acquisition应完成交接")
        }
        guard case .coldStart(let initiallyFrozen) = fixture.registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("cold parent缺失")
        }
        XCTAssertNil(initiallyFrozen.runningSince, "active receipt不能把unknown route当作available")

        XCTAssertEqual(fixture.registry.performOutputUserControl(
            try userControlRequest(fixture.registry, kind: .pause)), .acceptedWaiting)
        fixture.clock.set(200)
        XCTAssertEqual(fixture.registry.performOutputUserControl(
            try userControlRequest(fixture.registry, kind: .resume)), .acceptedWaiting)
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.parentDeadline?.value.runningSince,
            "普通user resume仍须等待typed available事实")

        fixture.clock.set(300)
        let observation = try XCTUnwrap(handoff.routeObservation)
        let sampler = try XCTUnwrap(handoff.sampler)
        let claim = try claimGraphRoute(fixture.registry, lane: fixture.lane, observation: observation, source: sampler)
        XCTAssertEqual(try completeGraphRoute(fixture.registry, claim,
            snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        guard case .coldStart(let running) = fixture.registry.outputResourceContextSnapshot()?.parentDeadline else {
            return XCTFail("cold parent丢失")
        }
        XCTAssertEqual(running.runningSince, 300, "首个typed available无需先出现none即可启动40秒有效时钟")
    }

    func testResetAndPostTimersUseStrictBoundaryAndInvalidateFrozenArm() throws {
        let reset = try ResetAcquiringOutputFixture()
        let registry = reset.registry
        let initial = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        let resetArm = try XCTUnwrap(initial.deadlineArm)
        reset.clock.set(try XCTUnwrap(initial.runningSince) + initial.boundaryEffectiveElapsed - initial.accumulatedEffectiveTime - 1)
        XCTAssertEqual(registry.rearmOutputResetPreRouteDeadline(resetArm)?.remainingNanoseconds, 1)
        reset.clock.set(reset.clock.read() + 1)
        XCTAssertNil(registry.rearmOutputResetPreRouteDeadline(resetArm))
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)

        let post = try ResetAcquiringOutputFixture()
        try post.configureAndHandoff()
        _ = try post.activateResetAndCommit()
        let postArm = try XCTUnwrap(post.registry.postConfigurationRouteDeadlineArmSnapshot())
        let state = try XCTUnwrap(post.registry.postConfigurationRouteDeadlineSnapshot())
        post.clock.set(try XCTUnwrap(state.runningSince) + state.budget.maximumEffectiveDuration - state.budget.accumulatedEffectiveTime - 1)
        XCTAssertEqual(post.registry.rearmOutputPostConfigurationRouteDeadline(postArm)?.remainingNanoseconds, 1)
        guard case .pending(let pending) = post.registry.outputRouteObservationSnapshot() else {
            return XCTFail("post getter缺失")
        }
        let claim = try claimGraphRoute(post.registry, lane: post.lane,
            observation: try XCTUnwrap(pending.ticket), source: try XCTUnwrap(pending.sampler))
        XCTAssertEqual(try completeGraphRoute(post.registry, claim, snapshot: GraphRouteSnapshot([])).disposition, .accepted)
        XCTAssertEqual(post.registry.rearmOutputPostConfigurationRouteDeadline(postArm)?.remainingNanoseconds, 1,
            "route-none只冻结parent，不能冻结post stage timer")
        post.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = post.registry.outputResourceContextSnapshot()
        XCTAssertNil(post.registry.rearmOutputPostConfigurationRouteDeadline(postArm),
            "冻结必须使旧post computed arm失权")

        let postExact = try ResetAcquiringOutputFixture()
        try postExact.configureAndHandoff()
        _ = try postExact.activateResetAndCommit()
        let exactArm = try XCTUnwrap(postExact.registry.postConfigurationRouteDeadlineArmSnapshot())
        let exactState = try XCTUnwrap(postExact.registry.postConfigurationRouteDeadlineSnapshot())
        postExact.clock.set(try XCTUnwrap(exactState.runningSince) +
            exactState.budget.maximumEffectiveDuration - exactState.budget.accumulatedEffectiveTime)
        XCTAssertNil(postExact.registry.rearmOutputPostConfigurationRouteDeadline(exactArm))
        XCTAssertTrue(postExact.registry.outputResourceContextSnapshot()?.poisoned == true,
            "post timer恰到有效边界必须terminal")
    }

    func testResetInheritedOrdinaryTimerKeepsAbsoluteWatchdogWhileParentFrozen() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("必须建立ordinary D")
        }
        let oldArm = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot())
        fixture.clock.set(fixture.clock.read() + 10)
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = try capturedResetRoot(registry)
        let inherited = try XCTUnwrap(registry.outputResourceContextSnapshot()?
            .resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute)
        fixture.clock.set(inherited.deadlineInstant - 1)
        let rearmed = try XCTUnwrap(registry.rearmOutputOrdinaryRouteDeadline(oldArm))
        XCTAssertEqual(rearmed.remainingNanoseconds, 1)
        XCTAssertNotEqual(rearmed.arm, oldArm, "ordinary提前唤醒必须换checked arm")
        fixture.clock.set(inherited.deadlineInstant)
        XCTAssertNil(try registry.rearmOutputOrdinaryRouteDeadline(rearmed.arm))
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true,
            "parent冻结也不能冻结inherited ordinary绝对D")
        XCTAssertEqual(handoff.routeDeadline?.identity, inherited.ticketIdentity)
    }

    func testResetTimerBackwardClockFailsClosedInSameCellCall() throws {
        let fixture = try ResetAcquiringOutputFixture()
        let state = try XCTUnwrap(fixture.registry.resetPreRouteDeadlineSnapshot())
        let arm = try XCTUnwrap(state.deadlineArm)
        fixture.clock.set(try XCTUnwrap(state.runningSince) - 1)
        XCTAssertNil(fixture.registry.rearmOutputResetPreRouteDeadline(arm))
        XCTAssertEqual(fixture.registry.executor.safetyIngress.snapshot.failure, .clockOverflow)
        XCTAssertTrue(fixture.registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testParentRearmNotAfterOverflowFailsClosedInsideAuthorityCAS() throws {
        let fixture = try AcquiringOutputFixture(parentCap: 40_000_000_000)
        _ = try fixture.configureAndActivate()
        let token = try XCTUnwrap(fixture.registry.outputAcquisitionCommitSnapshot())
        guard case .committed(let handoff) = try fixture.registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("必须安装cold parent")
        }
        let observation = try XCTUnwrap(handoff.routeObservation)
        let claim = try claimGraphRoute(fixture.registry, lane: fixture.lane,
            observation: observation, source: try XCTUnwrap(handoff.sampler))
        XCTAssertEqual(try completeGraphRoute(fixture.registry, claim,
            snapshot: GraphRouteSnapshot.builtIn).disposition, .accepted)
        fixture.clock.set(UInt64.max - 100)
        let arm = try XCTUnwrap(fixture.registry.playbackOperationDeadlineArmSnapshot())
        XCTAssertNil(fixture.registry.rearmOutputPlaybackOperationDeadline(arm))
        XCTAssertEqual(fixture.registry.executor.safetyIngress.snapshot.failure, .clockOverflow)
        XCTAssertTrue(fixture.registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testSchedulerMapsAllEightNamedDeadlineKindsAndUsesExactTickets() throws {
        let realNow = DispatchTime.now().uptimeNanoseconds

        let ordinaryFixture = try AcquiringOutputFixture(clock: .init(realNow))
        let acquisition = try XCTUnwrap(
            ordinaryFixture.registry.outputResourceContextSnapshot()?.acquisitionDeadline)
        let ordinaryScheduler = PlaybackDeadlineScheduler(registry: ordinaryFixture.registry)
        ordinaryScheduler.armAcquisition(acquisition)
        XCTAssertEqual(ordinaryScheduler.acquisitionDeadlineSnapshot(), acquisition)
        _ = try ordinaryFixture.configureAndActivate()
        let token = try XCTUnwrap(ordinaryFixture.registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try ordinaryFixture.registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("必须建立orderinary D")
        }
        let ordinary = try XCTUnwrap(ordinaryFixture.registry.ordinaryRouteDeadlineArmSnapshot())
        ordinaryScheduler.armOrdinaryRoute(ordinary)
        let checkedOrdinary = try XCTUnwrap(ordinaryScheduler.ordinaryRouteArmSnapshot())
        XCTAssertEqual(checkedOrdinary.ticketIdentity, ordinary.ticketIdentity)
        XCTAssertNotEqual(checkedOrdinary, ordinary, "ordinary投递必须安装新checked arm")

        let reset = try ResetAcquiringOutputFixture()
        let resetArm = try XCTUnwrap(reset.registry.resetPreRouteDeadlineSnapshot()?.deadlineArm)
        let resetScheduler = PlaybackDeadlineScheduler(registry: reset.registry)
        resetScheduler.armResetPreRoute(resetArm)
        XCTAssertEqual(resetScheduler.resetPreRouteArmSnapshot(), resetArm)

        let post = try ResetAcquiringOutputFixture()
        try post.configureAndHandoff()
        let previous = try post.activateResetAndCommit()
        XCTAssertNil(post.registry.phase(of: previous), "组合完成已退休原activation，不影响八种准确deadline映射")
        let postArm = try XCTUnwrap(post.registry.postConfigurationRouteDeadlineArmSnapshot())
        let postScheduler = PlaybackDeadlineScheduler(registry: post.registry)
        postScheduler.armPostConfiguration(postArm)
        XCTAssertEqual(postScheduler.postConfigurationArmSnapshot(), postArm)
        let parentArm = try XCTUnwrap(post.registry.playbackOperationDeadlineArmSnapshot())
        postScheduler.armPlaybackOperation(parentArm)
        XCTAssertEqual(postScheduler.playbackOperationArmSnapshot(), parentArm)

        post.clock.set(post.clock.read() + 1)
        post.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        post.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let context = try XCTUnwrap(post.registry.outputResourceContextSnapshot())
        _ = try XCTUnwrap(post.registry.beginOutputReactivation(
            contextNonce: context.contextNonce, mandatorySuffix: 1_000_000_000))
        let reactivationArm = try XCTUnwrap(
            post.registry.registeredAudioSessionPhase()?.reactivationState?.cutoffArmTicket)
        postScheduler.armReactivation(reactivationArm)
        XCTAssertEqual(postScheduler.reactivationArmSnapshot(), reactivationArm)

        let cleanupFixture = try OutputGraphFixture(clock: .init(realNow))
        let installed = try XCTUnwrap(cleanupFixture.registry.outputResourceContextSnapshot())
        _ = try XCTUnwrap(cleanupFixture.coordinator.begin(
            contextNonce: installed.contextNonce, reason: .stop, at: realNow,
            teardown: true, sourceActivation: installed.activation))
        let closing = try XCTUnwrap(cleanupFixture.registry.outputResourceContextSnapshot())
        let cleanup = try XCTUnwrap(closing.budget)
        let suspend = try XCTUnwrap(closing.suspend)
        let cleanupScheduler = PlaybackDeadlineScheduler(registry: cleanupFixture.registry)
        cleanupScheduler.armCleanup(cleanup)
        cleanupScheduler.armSuspend(suspend)
        XCTAssertEqual(cleanupScheduler.cleanupDeadlineSnapshot(), cleanup)
        XCTAssertEqual(cleanupScheduler.suspendTicketSnapshot(), suspend)
    }

    func testBoundedSchedulerReallyDeliversRearmsCancelsAndExpiresParentTicket() throws {
        let dispatchNow = DispatchTime.now().uptimeNanoseconds
        let active = try ActiveDeadlineFixture(clock: .init(dispatchNow - 39_900_000_000))
        let registry = active.fixture.registry
        let arm = try XCTUnwrap(registry.playbackOperationDeadlineArmSnapshot())
        let queue = DispatchQueue(label: "com.vplayer.tests.playback-deadline-scheduler-clock")
        let scheduler = PlaybackDeadlineScheduler(registry: registry)

        scheduler.armPlaybackOperation(arm)
        XCTAssertEqual(scheduler.playbackOperationArmSnapshot(), arm)
        let stale = PlaybackOperationDeadlineArmTicket(
            parentOperationTicketIdentity: arm.parentOperationTicketIdentity,
            freezeGeneration: arm.freezeGeneration + 1)
        scheduler.cancelPlaybackOperation(stale)
        XCTAssertEqual(scheduler.playbackOperationArmSnapshot(), arm,
            "旧票的kind-only cancel不得取消新arm")

        scheduler.cancelPlaybackOperation(arm)
        XCTAssertNil(scheduler.playbackOperationArmSnapshot())
        let parent = try XCTUnwrap(registry.outputResourceContextSnapshot()?.parentDeadline?.value)
        let running = try XCTUnwrap(parent.runningSince)
        active.clock.set(running + parent.cap - parent.accumulatedEffectiveTime - 20_000_000)
        scheduler.armPlaybackOperation(arm)
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
            active.clock.set(running + parent.cap - parent.accumulatedEffectiveTime)
        }
        let expired = expectation(description: "scheduler投递严格到界")
        queue.asyncAfter(deadline: .now() + .milliseconds(180)) { expired.fulfill() }
        wait(for: [expired], timeout: 1)
        XCTAssertNil(scheduler.playbackOperationArmSnapshot())
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testManualClockOriginsStayIdleUntilAdvanceAndDeliverOneExactBoundary() throws {
        for origin: UInt64 in [0, 100] {
            let clock = ManualPlaybackClock(nowNanoseconds: origin)
            let fixture = try ResetAcquiringOutputFixture(clock: clock)
            let registry = fixture.registry
            let state = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
            let arm = try XCTUnwrap(state.deadlineArm)
            let runningSince = try XCTUnwrap(state.runningSince)
            let exactBoundary = runningSince + state.boundaryEffectiveElapsed - state.accumulatedEffectiveTime
            let scheduler = PlaybackDeadlineScheduler(registry: registry)

            scheduler.armResetPreRoute(arm)
            registry.executor.sync {}
            Thread.sleep(forTimeInterval: 0.02)
            registry.executor.sync {}
            XCTAssertEqual(clock.deadlineTimerDeliveryCount, 0,
                "静止的注入时钟不能因原点落在Dispatch uptime过去而重复投递")
            XCTAssertEqual(scheduler.resetPreRouteNotAfterInstantSnapshot(), exactBoundary)

            clock.set(nowNanoseconds: exactBoundary - 1)
            registry.executor.sync {}
            XCTAssertFalse(registry.outputResourceContextSnapshot()?.poisoned == true)
            XCTAssertEqual(clock.deadlineTimerDeliveryCount, 0)
            clock.advance(nanoseconds: 1)
            registry.executor.sync {}
            XCTAssertEqual(clock.deadlineTimerDeliveryCount, 1)
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
            XCTAssertNil(scheduler.resetPreRouteArmSnapshot())
        }
    }

    func testManualEarlyWakeRearmsSameResetTicketWithoutRenewingAbsoluteBoundary() throws {
        let clock = ManualPlaybackClock(nowNanoseconds: 100)
        let fixture = try ResetAcquiringOutputFixture(clock: clock)
        let registry = fixture.registry
        let state = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        let arm = try XCTUnwrap(state.deadlineArm)
        let exactBoundary = try XCTUnwrap(state.runningSince) +
            state.boundaryEffectiveElapsed - state.accumulatedEffectiveTime
        let scheduler = PlaybackDeadlineScheduler(registry: registry)
        scheduler.armResetPreRoute(arm)

        clock.advance(nanoseconds: 10)
        clock.fireDeadlineTimerEarly()
        registry.executor.sync {}
        XCTAssertEqual(clock.deadlineTimerDeliveryCount, 1)
        XCTAssertEqual(scheduler.resetPreRouteArmSnapshot(), arm)
        XCTAssertEqual(scheduler.resetPreRouteNotAfterInstantSnapshot(), exactBoundary,
            "early wake只能重排原票，不能从唤醒时刻续杯")
        XCTAssertFalse(registry.outputResourceContextSnapshot()?.poisoned == true)

        clock.set(nowNanoseconds: exactBoundary)
        registry.executor.sync {}
        XCTAssertEqual(clock.deadlineTimerDeliveryCount, 2)
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testDelayedOldSuspendCannotReplaceCurrentTicketAndEarlyWakeKeepsCurrentSchedule() throws {
        let clock = ManualPlaybackClock(nowNanoseconds: 100)
        let fixture = try OutputGraphFixture(clock: clock)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(context.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        _ = try XCTUnwrap(fixture.coordinator.begin(
            contextNonce: context.contextNonce, reason: .pause, at: clock.nowNanoseconds))
        let old = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(old.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(
            suspendTicket: old, closeClaim: nil, directlyConfirmedRateZero: true,
            preparedPreserved: true)))

        clock.advance(nanoseconds: 10)
        _ = try XCTUnwrap(fixture.coordinator.begin(
            contextNonce: context.contextNonce, reason: .stop, at: clock.nowNanoseconds))
        let current = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertNotEqual(current, old)
        let scheduler = PlaybackDeadlineScheduler(registry: registry)
        scheduler.armSuspend(current)
        let originalBoundary = current.anchorInstant + 1_000_000_000
        XCTAssertEqual(scheduler.suspendTicketSnapshot(), current)
        XCTAssertEqual(scheduler.suspendNotAfterInstantSnapshot(), originalBoundary)

        scheduler.armSuspend(old)
        XCTAssertEqual(scheduler.suspendTicketSnapshot(), current,
            "迟到旧票准入失败不能覆盖当前唯一suspend watchdog")
        clock.fireDeadlineTimerEarly()
        registry.executor.sync {}
        XCTAssertEqual(scheduler.suspendTicketSnapshot(), current)
        XCTAssertEqual(scheduler.suspendNotAfterInstantSnapshot(), originalBoundary)
        XCTAssertFalse(registry.outputResourceContextSnapshot()?.suspendTimedOut == true)
    }

    func testSuspendSchedulerUsesEarlierExistingCleanupBoundary() throws {
        let clock = ManualPlaybackClock(nowNanoseconds: 100)
        let fixture = try OutputGraphFixture(clock: clock)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(context.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let pause = try XCTUnwrap(fixture.coordinator.begin(
            contextNonce: context.contextNonce, reason: .pause,
            at: clock.nowNanoseconds, teardown: true))
        let first = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(first.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(
            suspendTicket: first, closeClaim: nil, directlyConfirmedRateZero: true,
            preparedPreserved: true)))
        XCTAssertTrue(registry.finishOutputPause(owner: pause))
        let cleanup = try XCTUnwrap(registry.outputResourceContextSnapshot()?.budget)

        clock.set(nowNanoseconds: cleanup.deadlineInstant - 100)
        let currentContext = try XCTUnwrap(registry.outputResourceContextSnapshot())
        _ = try XCTUnwrap(fixture.coordinator.begin(
            contextNonce: currentContext.contextNonce, reason: .stop,
            at: clock.nowNanoseconds))
        let current = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertGreaterThan(current.anchorInstant + 1_000_000_000, cleanup.deadlineInstant)
        let scheduler = PlaybackDeadlineScheduler(registry: registry)
        scheduler.armSuspend(current)
        XCTAssertEqual(scheduler.suspendNotAfterInstantSnapshot(), cleanup.deadlineInstant)

        clock.advance(nanoseconds: 99)
        registry.executor.sync {}
        XCTAssertFalse(registry.outputResourceContextSnapshot()?.suspendTimedOut == true)
        clock.advance(nanoseconds: 1)
        registry.executor.sync {}
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.suspendTimedOut == true)
        XCTAssertNil(scheduler.suspendTicketSnapshot())
    }

    func testResetTerminalPreparationFailureDoesNotPartiallyInstallSettledClock() throws {
        let origin = UInt64.max - 30_000_000_000
        let clock = ManualPlaybackClock(nowNanoseconds: origin)
        let fixture = try ResetAcquiringOutputFixture(clock: clock)
        let registry = fixture.registry
        let beforeState = try XCTUnwrap(registry.resetPreRouteDeadlineSnapshot())
        let beforeContext = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let arm = try XCTUnwrap(beforeState.deadlineArm)

        clock.set(nowNanoseconds: .max)
        XCTAssertNil(registry.executor.performPlaybackBudget(.resetPreRouteTimer(arm)),
            "terminal cleanup budget发生checked overflow时，Cell必须fail-closed")
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .clockOverflow)
        XCTAssertEqual(registry.resetPreRouteDeadlineSnapshot(), beforeState,
            "全部可失败终态准备完成前，不得先安装running=nil/deadlineArm=nil的reset候选")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.parentDeadline,
            beforeContext.parentDeadline, "失败终态不得先结算并安装parent候选")
    }

    func testCapacityUsesTheSameAllocationReservationAndPreservesBudgetABIDiagnostics() {
        XCTAssertGreaterThan(
            ControlTaskRegistry.boundedPlaybackBudgetResetTerminalPreparationValueBytes,
            ControlTaskRegistry.boundedPlaybackBudgetTerminalPreparationValueBytes,
            "reset到界还保留待统一安装的state/context，必须单独计其终态峰"
        )
        let budgetPreparation = max(
            ControlTaskRegistry.boundedPlaybackBudgetDecisionPreparationValueBytes,
            ControlTaskRegistry.boundedPlaybackBudgetTerminalPreparationValueBytes,
            ControlTaskRegistry.boundedPlaybackBudgetResetTerminalPreparationValueBytes
        )
        XCTAssertEqual(ControlTaskRegistry.boundedPlaybackBudgetPreparationValueBytes,
            budgetPreparation)
        let fixed = ControlTaskRegistry.fixedValueStorageBytes +
            PlaybackDeadlineScheduler.fixedValueStorageBytes
        let peak = fixed + max(
            ControlTaskRegistry.boundedResourceTransitionPreparationValueBytes +
                PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
                ControlTaskRegistry.groupTicketProjectionPreparationValueBytes,
            budgetPreparation + PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
                ControlTaskRegistry.groupTicketProjectionPreparationValueBytes,
            ControlTaskRegistry.boundedSuspendControlPreparationValueBytes +
                PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
                ControlTaskRegistry.groupTicketProjectionPreparationValueBytes
        ) + MemoryLayout<OutputResourceOwnershipSnapshot>.stride
        let capacityDescription = """
        唯一实际allocation预留=\(ControlTaskRegistry.controlAllocationReservation)
        以下为历史非cap的源码stride诊断，不是实际线程栈上界。
        Registry固定值=\(ControlTaskRegistry.fixedValueStorageBytes)
        scheduler固定值=\(PlaybackDeadlineScheduler.fixedValueStorageBytes)
        clock existential=\(MemoryLayout<any PlaybackMonotonicClock>.stride)
        timer existential=\(MemoryLayout<any PlaybackDeadlineTimer>.stride)
        Dispatch timer adapter=\(DispatchPlaybackMonotonicClock.deadlineTimerAdapterFixedValueBytes)
        decision准备=\(ControlTaskRegistry.boundedPlaybackBudgetDecisionPreparationValueBytes)
        decision enum=\(ControlTaskRegistry.playbackBudgetEvaluationDecisionValueBytes)
        resource context=\(MemoryLayout<OutputResourceContext>.stride)
        reset state=\(MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride)
        settled parent=\(MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride)
        普通terminal准备=\(ControlTaskRegistry.boundedPlaybackBudgetTerminalPreparationValueBytes)
        reset terminal准备=\(ControlTaskRegistry.boundedPlaybackBudgetResetTerminalPreparationValueBytes)
        resource准备=\(ControlTaskRegistry.boundedResourceTransitionPreparationValueBytes)
        delivery准备=\(PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes)
        delivery值=\(PlaybackDeadlineScheduler.deliveryValueBytes)
        scheduled optional=\(PlaybackDeadlineScheduler.scheduledOptionalValueBytes)
        Output application optional=\(MemoryLayout<OutputControlApplication?>.stride)
        Suspend result=\(MemoryLayout<OutputSuspendControlResult>.stride)
        Group投影=\(ControlTaskRegistry.groupTicketProjectionPreparationValueBytes)
        snapshot=\(MemoryLayout<OutputResourceOwnershipSnapshot>.stride)
        保守峰=\(peak)
        """
        let attachment = XCTAttachment(string: capacityDescription)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(ControlTaskRegistry.controlAllocationReservation.total, 64 * 1_024, capacityDescription)
    }
}

final class PlaybackDeadlineReconciliationTests: XCTestCase {
    func testResetInheritedOrdinaryArmRemainsInAuthoritativeScheduleWhileInterrupted() throws {
        let fixture = try AcquiringOutputFixture()
        _ = try fixture.configureAndActivate()
        let registry = fixture.registry
        let token = try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())
        guard case .committed = try registry.commitAcquisitionRelayAndContext(token) else {
            return XCTFail("须先建立真实ordinary watchdog")
        }
        let original = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot())
        registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        _ = try capturedResetRoot(registry)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.parentDeadline?.value.runningSince)
        let inherited = try XCTUnwrap(registry.outputResourceContextSnapshot()?.resetInheritedRouteAvailabilityConstraint?.ordinaryAbsolute)
        XCTAssertEqual(inherited.ticketIdentity, original.ticketIdentity)
        let scheduled = try XCTUnwrap(registry.ordinaryRouteDeadlineArmSnapshot(),
            "八槽snapshot不能遗漏reset继承的绝对watchdog")
        XCTAssertEqual(scheduled.ticketIdentity, inherited.ticketIdentity)
        let scheduler = PlaybackDeadlineScheduler(registry: registry)
        scheduler.armOrdinaryRoute(scheduled)
        let exact = registry.playbackDeadlineScheduleSnapshot()
        scheduler.reconcile(exact)
        scheduler.reconcile(exact)
        XCTAssertEqual(scheduler.ordinaryRouteArmSnapshot(), exact.ordinaryRoute,
            "相同准确snapshot不能重签ordinary arm或续绝对边界")
        fixture.clock.set(inherited.deadlineInstant - 1)
        fixture.clock.fireDeadlineTimerEarly()
        registry.executor.sync {}
        XCTAssertFalse(registry.outputResourceContextSnapshot()?.poisoned == true)
        fixture.clock.set(inherited.deadlineInstant)
        registry.executor.sync {}
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
    }

    func testFrozenPostConfigurationIsAbsentInsteadOfReconstructingAFalseArm() throws {
        let fixture = try ResetAcquiringOutputFixture()
        try fixture.configureAndHandoff()
        _ = try fixture.activateResetAndCommit()
        XCTAssertNotNil(fixture.registry.postConfigurationRouteDeadlineArmSnapshot())
        fixture.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertNil(fixture.registry.postConfigurationRouteDeadlineSnapshot()?.runningSince)
        XCTAssertNil(fixture.registry.postConfigurationRouteDeadlineArmSnapshot(), "冻结态没有可arm的post-config票")
    }

    func testAnyTerminalBudgetClearsAllRemainingSlotsWithoutRenewingCleanup() throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try OutputGraphFixture(clock: clock)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(context.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        _ = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .stop, at: clock.read(), teardown: true))
        let closing = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let budget = try XCTUnwrap(closing.budget)
        let suspend = try XCTUnwrap(closing.suspend)
        let scheduler = PlaybackDeadlineScheduler(registry: registry)
        scheduler.armCleanup(budget)
        scheduler.armSuspend(suspend)
        clock.set(suspend.anchorInstant + 1_000_000_000 - 1)
        registry.executor.sync {}
        XCTAssertNotNil(scheduler.cleanupDeadlineSnapshot())
        clock.advance(nanoseconds: 1)
        registry.executor.sync {}
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.suspendTimedOut == true)
        XCTAssertNil(scheduler.suspendTicketSnapshot())
        XCTAssertNil(scheduler.cleanupDeadlineSnapshot(), "任一终态须清所有剩余budget槽，不能再产生第二清理")
        XCTAssertEqual(registry.playbackDeadlineScheduleSnapshot(), .init(), "poisoned必须一次投影全8槽nil")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.budget, budget)
    }
}

private struct ActiveDeadlineFixture {
    let fixture: OutputGraphFixture
    let context: OutputResourceContext
    let interval: PotentiallyAudibleOutputIntervalKey
    let snapshot: PlaybackSafetySnapshot
    var clock: OutputTestClock { fixture.stable.acquisition.clock }

    init(clock: OutputTestClock = .init(100)) throws {
        fixture = try OutputGraphFixture(clock: clock)
        let registry = fixture.registry
        let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let prepare = try XCTUnwrap(installed.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let activation = try XCTUnwrap(registry.beginOutputActivation(contextNonce: installed.contextNonce))
        XCTAssertTrue(registry.claimStart(activation))
        interval = try XCTUnwrap(registry.openOutputInterval(activation, itemGeneration: 1))
        context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        snapshot = registry.executor.safetyIngress.snapshot
    }

    var receipt: PlaybackMediaProgressReceipt {
        .init(intervalKey: interval, sessionIdentity: context.sessionIdentity,
            contextNonce: context.contextNonce, mediaServicesEpoch: snapshot.mediaServicesEpoch,
            interruptionEpoch: snapshot.interruptionEpoch,
            audioAdmissionFenceRevision: snapshot.audioAdmissionFenceRevision,
            stableRouteCommit: fixture.stable.stable)
    }
}

private extension CurrentPlaybackOperationDeadlineTicket {
    var value: PlaybackProgressBudgetTicket {
        switch self {
        case .coldStart(let value), .outputRecovery(let value): value
        }
    }
}

private struct DeadlineIdentityFixture {
    let session: PlaybackSessionIdentity
    let controlTask: ControlTaskTicket
    let resetIncarnation: SystemRecoveryIncarnation.Identity

    init() throws {
        let allocator = PlaybackIdentityAllocator()
        session = PlaybackSessionIdentity(
            sessionID: try allocator.next(in: .session), requestID: UUID()
        )
        let owner = ControlTaskOwnerTicket(
            resourceIdentity: .session(session), nonce: try allocator.next(in: .nonce)
        )
        let group = ControlTaskGroupTicket(
            resourceIdentity: .session(session), ownerTicket: owner,
            nonce: try allocator.next(in: .controlTask)
        )
        controlTask = ControlTaskTicket(
            group: group, nonce: try allocator.next(in: .controlTask)
        )
        let root = MediaServicesResetRootIdentity(
            resetTicket: try allocator.next(in: .resetRoot),
            mediaServicesEpoch: try allocator.next(in: .mediaServices)
        )
        resetIncarnation = .init(
            root: root, incarnationNonce: try allocator.next(in: .nonce), sessionIdentity: session
        )
    }
}
