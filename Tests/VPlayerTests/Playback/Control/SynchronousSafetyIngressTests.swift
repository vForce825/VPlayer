// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SynchronousSafetyIngressTests: XCTestCase {
    func testSystemReceiptRetainsTheExactOriginalRevisionAcrossLaterCallbacks() throws {
        let harness = SafetyIngressTestHarness()
        var firstReceipt: PlaybackSystemSafetyReceipt?
        var secondReceipt: PlaybackSystemSafetyReceipt?
        harness.executor.sync {
            firstReceipt = harness.cell.performSyncIngress(.interruptionBegan)
            secondReceipt = harness.cell.performSyncIngress(.interruptionEnded(shouldResume: false))
        }
        let first = try XCTUnwrap(firstReceipt)
        let second = try XCTUnwrap(secondReceipt)
        XCTAssertEqual(first.event, .interruptionBegan)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.interruptionEpoch, 1)
        XCTAssertEqual(first.mediaServicesEpoch, 0)
        XCTAssertEqual(first.audioAdmissionFenceRevision, 1)
        XCTAssertEqual(second.event, .interruptionEnded(shouldResume: false))
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.interruptionEpoch, 2)
        XCTAssertEqual(second.audioAdmissionFenceRevision, 2)
    }

    func testFirstBeganInstantIsCapturedAtZeroPreservedAcrossEndedAndClearedOnConsume() {
        let harness = SafetyIngressTestHarness()
        harness.executor.sync {
            harness.system(.interruptionBegan, at: 0)
            harness.system(.interruptionEnded(shouldResume: true), at: 10)
            harness.system(.interruptionBegan, at: 20)
            XCTAssertEqual(harness.cell.snapshot.system.firstInterruptionBeganIngressInstant, 0)
            XCTAssertTrue(harness.cell.snapshot.system.interruptionBeganObserved)
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
            XCTAssertEqual(harness.authority.values.last?.system.firstInterruptionBeganIngressInstant, 0)
            XCTAssertNil(harness.cell.snapshot.system.firstInterruptionBeganIngressInstant)
            XCTAssertFalse(harness.cell.snapshot.system.interruptionBeganObserved)
        }
    }

    // 若apply失败被忽略或当作普通retry，目标可能越过未成功物化的reset。
    func testFailedIngressApplicationRejectsTargetAndDeliversTerminalExactlyOnce() {
        let authority = SafetyIngressAuthority()
        let executor = PlaybackControlExecutor(allocator: PlaybackIdentityAllocator(),
            clock: ManualPlaybackClock(100),
            applyIngress: { snapshot in
                authority.apply(snapshot)
                return .failed(.clockOverflow)
            }, applyTerminalIngress: { authority.applyTerminal($0) }, applyOutputControl: { _, _ in .rejected })
        executor.sync {
            executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            let result = executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                XCTFail("失败的首reset不得执行目标")
            }
            if case .rejected = result {} else { XCTFail("apply失败必须拒绝本次目标") }
            XCTAssertEqual(executor.safetyIngress.snapshot.failure, .clockOverflow)
            XCTAssertFalse(executor.safetyIngress.snapshot.safetyIngressPending)
            XCTAssertNil(executor.safetyIngress.snapshot.system.latestResetIngress)
            XCTAssertNil(executor.safetyIngress.snapshot.system.resetPreRouteClockFold)
            XCTAssertEqual(authority.terminalValues.count, 1)
            XCTAssertEqual(authority.terminalValues.last?.failure, .clockOverflow)
            XCTAssertFalse(authority.terminalValues.last?.outputPermitPresent ?? true)
            let cleanup = executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership) { output in
                output.outputPermitPresent = true
                return 7
            }
            if case .performed(7) = cleanup {} else { XCTFail("既有清理应可继续") }
            XCTAssertFalse(executor.safetyIngress.snapshot.outputPermitPresent)
        }
        executor.sync {}
        XCTAssertEqual(authority.values.count, 1)
        XCTAssertEqual(authority.terminalValues.count, 1)
    }

    func testPendingWindowDistinguishesRepeatedBeganFromRepeatedEndedAndConsumesFlag() {
        for includesBegan in [false, true] {
            let harness = SafetyIngressTestHarness()
            harness.executor.sync {
                harness.system(.interruptionBegan, at: 100)
                _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
                harness.system(includesBegan ? .interruptionBegan : .interruptionEnded(shouldResume: true), at: 110)
                harness.system(.interruptionEnded(shouldResume: true), at: 120)
                let pending = harness.cell.snapshot
                XCTAssertEqual(pending.interruptionEpoch, 3)
                XCTAssertEqual(pending.freezeGeneration, 2)
                XCTAssertEqual(pending.system.interruptionBeganObserved, includesBegan)
                _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
                XCTAssertEqual(harness.authority.values.last?.system.interruptionBeganObserved, includesBegan)
                XCTAssertFalse(harness.cell.snapshot.system.interruptionBeganObserved)
                harness.system(.interruptionEnded(shouldResume: true), at: 130)
                harness.routeCallback()
                XCTAssertFalse(harness.cell.snapshot.system.interruptionBeganObserved)
                _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
                XCTAssertEqual(harness.authority.values.last?.system.interruptionBeganObserved, false)
            }
        }
    }

    // 删除同步撤权或改为排队撤权必须使本测试失败。
    func testCallbackRevokesBeforeBlockedExecutorCanDrain() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.routeCallback()
        XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
        XCTAssertFalse(harness.cell.snapshot.readinessOpen)
        XCTAssertFalse(harness.cell.snapshot.routeObservationGateOpen)
        XCTAssertTrue(harness.cell.snapshot.suspendRequired)
        XCTAssertEqual(harness.cell.snapshot.drainScheduled, true)
        for _ in 0..<1_000 { harness.routeCallback() }
        XCTAssertEqual(harness.cell.snapshot.drainScheduled, true)
        harness.releaseExecutor()
        XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
    }

    // 若consume后直接执行目标CAS，旧session的待应用reset会被越过。
    func testEveryOwnershipCASConsumesAndRetriesBeforeMutating() {
        let harness = SafetyIngressTestHarness()
        harness.executor.sync {
            harness.system(.mediaServicesReset, at: 100)
            var performed = false
            let first = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                performed = true
            }
            guard case .retry = first else { return XCTFail("首个所有权操作必须消费后retry") }
            XCTAssertFalse(performed)
            harness.system(.mediaServicesReset, at: 200)
            let second = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                performed = true
            }
            guard case .retry = second else { return XCTFail("后到reset必须再次retry") }
            XCTAssertFalse(performed)
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                performed = true
            }
            XCTAssertTrue(performed)
        }
    }

    // 连续reset不能覆盖首锚；中断窗口必须从同一个有效时钟扣除。
    func testResetFoldPreservesFirstAnchorAndLatestRoot() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.system(.mediaServicesReset, at: 100)
        let first = harness.cell.snapshot.system.latestResetIngress
        harness.system(.interruptionBegan, at: 120)
        harness.system(.interruptionEnded(shouldResume: true), at: 170)
        harness.system(.mediaServicesReset, at: 200)
        let state = harness.cell.snapshot
        XCTAssertEqual(state.system.firstUndrainedResetIngressInstant, 100)
        XCTAssertEqual(state.system.latestResetIngress?.ingressInstant, 200)
        XCTAssertNotEqual(first?.rootIdentity, state.system.latestResetIngress?.rootIdentity)
        XCTAssertEqual(state.system.resetPreRouteClockFold?.effectiveNanoseconds, 50)
        XCTAssertEqual(state.system.resetPreRouteClockFold?.frozen, false)
        XCTAssertEqual(state.interruptionState, .ended(shouldResume: true))
        harness.releaseExecutor()
    }

    func testEndedWithoutResumeKeepsVetoButEndsPhysicalInterruption() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.system(.interruptionBegan, at: 100)
        harness.system(.mediaServicesReset, at: 110)
        harness.system(.interruptionEnded(shouldResume: false), at: 150)
        harness.system(.mediaServicesReset, at: 200)
        XCTAssertEqual(harness.cell.snapshot.interruptionState, .ended(shouldResume: false))
        XCTAssertTrue(harness.cell.snapshot.interruptionVeto)
        XCTAssertEqual(harness.cell.snapshot.system.resetPreRouteClockFold?.effectiveNanoseconds, 50)
        harness.releaseExecutor()
    }

    func testConcurrentStormUsesOnePendingDrainAndLeavesNoCallbacks() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            switch index % 3 {
            case 0: harness.routeCallback()
            case 1: harness.cell.performSyncIngress(.interruptionBegan)
            default: harness.cell.performSyncIngress(.mediaServicesReset)
            }
        }
        XCTAssertEqual(harness.cell.snapshot.callbackDepth, 0)
        XCTAssertTrue(harness.cell.snapshot.drainScheduled)
        XCTAssertTrue(harness.cell.snapshot.safetyIngressPending)
        XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
        XCTAssertNil(harness.cell.snapshot.failure)
        harness.releaseExecutor()
        XCTAssertEqual(harness.authority.values.count, 1)
        XCTAssertNil(harness.cell.snapshot.system.firstUndrainedResetIngressInstant)
    }

    func testUnknownRouteEvidenceRemainsUnknownAndInvalidReasonsFailClosed() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        harness.cell.beginRouteObservation(PlaybackRouteIngress(
            sessionIdentity: session, monitorLifecycle: 1, notificationRevision: 1,
            reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false,
            observedRoute: nil
        ))
        XCTAssertEqual(harness.cell.snapshot.route?.sessionIdentity, session)
        XCTAssertNil(harness.cell.snapshot.route?.observedRoute)
        harness.cell.beginRouteObservation(PlaybackRouteIngress(
            sessionIdentity: session, monitorLifecycle: 1, notificationRevision: 2,
            reasonBits: 128, topologyChangeHint: false, outputConfigurationChanged: false,
            observedRoute: nil
        ))
        XCTAssertEqual(harness.cell.snapshot.failure, .invalidEvidence)
        XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
        harness.releaseExecutor()
    }

    // callback在无pending CAS持锁以后到达，只能排在CAS之后。
    func testCallbackCannotEnterBetweenFinalCheckAndOwnershipCAS() {
        let harness = SafetyIngressTestHarness()
        let attempted = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        harness.executor.sync {
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                DispatchQueue.global().async {
                    attempted.signal()
                    harness.system(.mediaServicesReset, at: 300)
                    returned.signal()
                }
                XCTAssertEqual(attempted.wait(timeout: .now() + 2), .success)
                XCTAssertEqual(returned.wait(timeout: .now() + 0.05), .timedOut)
            }
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
    }

    func testCheckedCallbackDepthNeverWrapsOrUnderflows() {
        var depth = PlaybackCallbackDepth(value: .max - 1)
        XCTAssertTrue(depth.enter())
        XCTAssertEqual(depth.value, UInt64.max)
        XCTAssertFalse(depth.enter())
        XCTAssertEqual(depth.value, UInt64.max)
        XCTAssertTrue(depth.leave())
        XCTAssertEqual(depth.value, UInt64.max - 1)
        var empty = PlaybackCallbackDepth(value: 0)
        XCTAssertFalse(empty.leave())
        XCTAssertEqual(empty.value, 0)
    }

    func testIdentityExhaustionRevokesAndRejectsSubsequentOwnership() {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
        let harness = SafetyIngressTestHarness(allocator: allocator)
        harness.executor.sync {
            harness.routeCallback()
            XCTAssertEqual(harness.cell.snapshot.throughRevision, UInt64.max)
            harness.routeCallback()
            XCTAssertEqual(harness.cell.snapshot.failure, .identitySpaceExhausted)
            XCTAssertTrue(allocator.isExhausted)
            var ran = false
            let result = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in ran = true }
            guard case .retry = result else { return XCTFail("终态必须先交付authority") }
            let rejected = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in ran = true }
            guard case .rejected = rejected else { return XCTFail("耗尽后不得提交所有权") }
            XCTAssertFalse(ran)
            XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
        }
    }

    func testOrdinaryBarrierAndScheduledRunnerApplyRevisionExactlyOnce() {
        let harness = SafetyIngressTestHarness()
        harness.executor.sync {
            harness.system(.mediaServicesReset, at: 10)
            let revision = harness.cell.snapshot.throughRevision
            let result = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                XCTFail("不能在消费同次执行CAS")
            }
            guard case .retry = result else { return XCTFail("必须retry") }
            XCTAssertEqual(harness.authority.values.count, 1)
            XCTAssertEqual(harness.authority.values.last?.throughRevision, revision)
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                XCTAssertEqual(harness.authority.values.last?.system.firstUndrainedResetIngressInstant, 10)
            }
        }
        harness.executor.sync {}
        XCTAssertEqual(harness.authority.values.count, 1)
    }

    func testOutOfOrderRouteDoesNotOverwriteLatestEvidence() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        for revision: UInt64 in [5, 3, 5] {
            harness.cell.beginRouteObservation(PlaybackRouteIngress(
                sessionIdentity: harness.session, monitorLifecycle: 1, notificationRevision: revision,
                reasonBits: revision == 3 ? 2 : 1, topologyChangeHint: false,
                outputConfigurationChanged: revision == 3, observedRoute: nil
            ))
            XCTAssertEqual(harness.cell.snapshot.route?.notificationRevision, 5)
        }
        XCTAssertEqual(harness.cell.snapshot.route?.reasonBits, 3)
        XCTAssertEqual(harness.cell.snapshot.route?.outputConfigurationChanged, true)
        harness.releaseExecutor()
    }

    func testClockIsSampledAfterAcquiringCellLock() {
        let harness = SafetyIngressTestHarness()
        let attempted = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        harness.clock.set(100)
        harness.executor.sync {
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in
                DispatchQueue.global().async {
                    attempted.signal()
                    harness.cell.performSyncIngress(.mediaServicesReset)
                    returned.signal()
                }
                XCTAssertEqual(attempted.wait(timeout: .now() + 2), .success)
                XCTAssertEqual(returned.wait(timeout: .now() + 0.05), .timedOut)
                XCTAssertEqual(harness.clock.readCount, 0)
                harness.clock.set(200)
            }
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        harness.executor.sync {
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
        XCTAssertEqual(harness.authority.values.first?.system.latestResetIngress?.ingressInstant, 200)
    }

    func testPositiveRateAdmissionCannotCrossIngressOrReopenAfterDrain() {
        let harness = SafetyIngressTestHarness()
        harness.executor.sync {
            let allowed = harness.executor.withSafetyIngressBarrier(operationDescriptor: .positiveRateAdmission) { _ in true }
            guard case .performed(true) = allowed else { return XCTFail("测试必须先建立真实授权") }
            harness.routeCallback()
            let retry = harness.executor.withSafetyIngressBarrier(operationDescriptor: .positiveRateAdmission) { _ in
                XCTFail("pending时不能取得正rate授权")
            }
            guard case .retry = retry else { return XCTFail("先应用安全快照") }
            let denied = harness.executor.withSafetyIngressBarrier(operationDescriptor: .positiveRateAdmission) { _ in
                XCTFail("drain不能恢复旧输出区间")
            }
            guard case .rejected = denied else { return XCTFail("旧授权必须仍然关闭") }
        }
    }

    func testHDMIAndBluetoothStormsRevokeEvenWithoutTopologyHints() {
        for ports: PlaybackRoutePorts in [.hdmi, .bluetooth] {
            let harness = SafetyIngressTestHarness()
            let route = PlaybackRouteSemanticIdentity(
                ports: ports, backend: .sampleBuffer,
                outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 1),
                endpointTopologyToken: EndpointTopologyToken(rawValue: 1)
            )
            harness.holdExecutor()
            DispatchQueue.concurrentPerform(iterations: 10_000) { index in
                harness.cell.beginRouteObservation(PlaybackRouteIngress(
                    sessionIdentity: harness.session, monitorLifecycle: 1,
                    notificationRevision: UInt64(index + 1), reasonBits: 1,
                    topologyChangeHint: false, outputConfigurationChanged: false, observedRoute: route
                ))
            }
            XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
            XCTAssertTrue(harness.cell.snapshot.suspendRequired)
            XCTAssertEqual(harness.cell.snapshot.route?.notificationRevision, 10_000)
            XCTAssertEqual(harness.cell.snapshot.callbackDepth, 0)
            harness.releaseExecutor()
            XCTAssertEqual(harness.authority.values.count, 1)
        }
    }

    func testInterruptionOnlyWindowStillCarriesExistingParentClockFold() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.system(.interruptionBegan, at: 100)
        harness.system(.interruptionEnded(shouldResume: false), at: 150)
        harness.system(.interruptionEnded(shouldResume: true), at: 180)
        let fold = harness.cell.snapshot.system.interruptionClockFold
        XCTAssertEqual(fold?.windowStartInstant, 100)
        XCTAssertEqual(fold?.effectiveNanoseconds, 30)
        XCTAssertEqual(fold?.lastIngressInstant, 180)
        XCTAssertEqual(fold?.frozen, false)
        XCTAssertNil(harness.cell.snapshot.system.resetPreRouteClockFold)
        harness.releaseExecutor()
        XCTAssertEqual(harness.authority.values.first?.system.interruptionClockFold, fold)
    }

    func testResetOutsideInterruptionUsesSeparateFirstResetAnchor() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.system(.interruptionEnded(shouldResume: true), at: 100)
        harness.system(.mediaServicesReset, at: 120)
        harness.system(.interruptionBegan, at: 130)
        harness.system(.interruptionEnded(shouldResume: true), at: 150)
        harness.system(.mediaServicesReset, at: 170)
        XCTAssertEqual(harness.cell.snapshot.system.interruptionClockFold?.effectiveNanoseconds, 50)
        XCTAssertEqual(harness.cell.snapshot.system.resetPreRouteClockFold?.effectiveNanoseconds, 30)
        XCTAssertEqual(harness.cell.snapshot.system.firstUndrainedResetIngressInstant, 120)
        harness.releaseExecutor()
    }

    func testControlEventFieldsUseTheirRegisteredIndependentDomains() throws {
        let allocator = PlaybackIdentityAllocator()
        for _ in 0..<10 { _ = try allocator.next(in: .safetyIngress) }
        for _ in 0..<20 { _ = try allocator.next(in: .systemEvent) }
        for _ in 0..<30 { _ = try allocator.next(in: .mediaServices) }
        for _ in 0..<40 { _ = try allocator.next(in: .interruption) }
        for _ in 0..<50 { _ = try allocator.next(in: .resetRoot) }
        for _ in 0..<60 { _ = try allocator.next(in: .freezeGeneration) }
        let harness = SafetyIngressTestHarness(allocator: allocator)
        harness.holdExecutor()
        harness.system(.mediaServicesReset, at: 100)
        harness.system(.interruptionBegan, at: 120)
        harness.system(.interruptionEnded(shouldResume: true), at: 170)
        let snapshot = harness.cell.snapshot
        XCTAssertEqual(snapshot.throughRevision, 13)
        XCTAssertEqual(snapshot.ownerSystemEventRevision, 23)
        XCTAssertEqual(snapshot.mediaServicesEpoch, 31)
        XCTAssertEqual(snapshot.interruptionEpoch, 42)
        XCTAssertEqual(snapshot.system.latestResetIngress?.rootIdentity, 51)
        XCTAssertEqual(snapshot.freezeGeneration, 62)
        XCTAssertEqual(snapshot.audioAdmissionFenceRevision, 3)
        harness.releaseExecutor()
    }

    // ended无论是否获准恢复都必须签发新epoch；重复ended也不能复用旧身份。
    func testInterruptionEndedAlwaysIssuesNewEpochWithoutRefreezingClock() {
        for shouldResume in [true, false] {
            let harness = SafetyIngressTestHarness()
            harness.holdExecutor()
            harness.system(.interruptionBegan, at: 100)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 1)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 1)
            harness.system(.interruptionEnded(shouldResume: shouldResume), at: 150)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 2)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 2)
            XCTAssertEqual(harness.cell.snapshot.interruptionVeto, !shouldResume)
            harness.system(.interruptionEnded(shouldResume: shouldResume), at: 180)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 3)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 2)
            XCTAssertEqual(harness.cell.snapshot.system.interruptionClockFold?.effectiveNanoseconds, 30)
            harness.system(.interruptionBegan, at: 200)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 4)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 3)
            harness.system(.interruptionEnded(shouldResume: shouldResume), at: 220)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 5)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 4)
            XCTAssertEqual(harness.cell.snapshot.system.interruptionClockFold?.effectiveNanoseconds, 50)
            harness.releaseExecutor()
        }
    }

    func testInterruptionEndedDomainExhaustionFailsClosedBeforePublishingState() throws {
        for shouldResume in [true, false] {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 2)
            // 只先耗完interruption；入口共同使用的revision/fence仍有容量。
            XCTAssertEqual(try allocator.next(in: .interruption), UInt64.max - 1)
            XCTAssertEqual(try allocator.next(in: .interruption), UInt64.max)
            let harness = SafetyIngressTestHarness(allocator: allocator)
            harness.holdExecutor()
            XCTAssertTrue(harness.cell.snapshot.outputPermitPresent)
            harness.system(.interruptionEnded(shouldResume: shouldResume), at: 100)
            XCTAssertTrue(allocator.isExhausted)
            XCTAssertEqual(harness.cell.snapshot.failure, .identitySpaceExhausted)
            XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
            XCTAssertFalse(harness.cell.snapshot.readinessOpen)
            XCTAssertFalse(harness.cell.snapshot.routeObservationGateOpen)
            XCTAssertEqual(harness.cell.snapshot.interruptionState, .inactive)
            XCTAssertEqual(harness.cell.snapshot.interruptionEpoch, 0)
            XCTAssertEqual(harness.cell.snapshot.freezeGeneration, 0)
            XCTAssertThrowsError(try allocator.next(in: .session))
            harness.cell.performSyncIngress(.interruptionBegan)
            XCTAssertEqual(harness.cell.snapshot.failure, .identitySpaceExhausted)
            XCTAssertEqual(harness.cell.snapshot.callbackDepth, 0)
            harness.releaseExecutor()
            XCTAssertEqual(harness.authority.values.count, 1)
            XCTAssertEqual(harness.authority.values.last?.failure, .identitySpaceExhausted)
        }
    }

    func testPendingSnapshotContainsOnlyFixedValueStorage() {
        let harness = SafetyIngressTestHarness()
        harness.holdExecutor()
        harness.routeCallback()
        harness.system(.mediaServicesReset, at: 100)
        harness.system(.interruptionBegan, at: 120)
        assertFixedValueStorage(harness.cell.snapshot)
        XCTAssertNotNil(harness.cell.snapshot.system.resetPreRouteClockFold)
        XCTAssertNotNil(harness.cell.snapshot.system.interruptionClockFold)
        print("安全shadow固定尺寸：\(MemoryLayout<PlaybackSafetySnapshot>.size)字节；步长：\(MemoryLayout<PlaybackSafetySnapshot>.stride)字节")
        harness.releaseExecutor()
    }

    func testEveryRouteDependentAdmissionRemainsClosedAfterConsume() {
        let harness = SafetyIngressTestHarness()
        harness.executor.sync {
            harness.routeCallback()
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
            let descriptors: [PlaybackControlOperationDescriptor] = [
                .factoryAdmission, .prepareAdmission, .selectionAdmission,
                .probeAdmission, .activationAdmission, .positiveRateAdmission
            ]
            for descriptor in descriptors {
                let result = harness.executor.withSafetyIngressBarrier(operationDescriptor: descriptor) { _ in
                    XCTFail("关闭gate以后不能接纳\(descriptor)")
                }
                guard case .rejected = result else { XCTFail("必须拒绝\(descriptor)"); continue }
            }
        }
    }

    func testTerminalStateStillAllowsCleanupButCannotRestoreOutput() {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
        let harness = SafetyIngressTestHarness(allocator: allocator)
        harness.executor.sync {
            harness.routeCallback()
            harness.routeCallback()
            _ = harness.executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership) { _ in
                XCTFail("清理也必须先消费安全事件")
            }
            var cleaned = false
            let result = harness.executor.withSafetyIngressBarrier(operationDescriptor: .cleanupOwnership) { output in
                cleaned = true
                output.outputPermitPresent = true
            }
            guard case .performed = result else { return XCTFail("终态必须允许既有owner清理") }
            XCTAssertTrue(cleaned)
            XCTAssertFalse(harness.cell.snapshot.outputPermitPresent)
        }
    }

    private func assertFixedValueStorage(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection, .dictionary, .set, .class:
            XCTFail("安全shadow不得持有动态集合或资源引用", file: file, line: line)
        default:
            for child in mirror.children { assertFixedValueStorage(child.value, file: file, line: line) }
        }
    }
}

private final class SafetyIngressTestHarness: @unchecked Sendable {
    let executor: PlaybackControlExecutor
    let authority: SafetyIngressAuthority
    let clock = SafetyIngressClock()
    let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
    var cell: SynchronousSafetyIngressCell { executor.safetyIngress }
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(allocator: PlaybackIdentityAllocator = PlaybackIdentityAllocator()) {
        let authority = SafetyIngressAuthority()
        self.authority = authority
        let clock = self.clock
        executor = PlaybackControlExecutor(allocator: allocator, clock: clock,
            applyIngress: { snapshot in authority.apply(snapshot); return .applied },
            applyTerminalIngress: { authority.apply($0) }, applyOutputControl: { _, _ in .rejected })
        executor.sync {
            _ = executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { output in
                output.outputPermitPresent = true
                output.readinessOpen = true
                output.routeObservationGateOpen = true
            }
        }
    }

    func holdExecutor() {
        executor.submit { [self] in
            entered.signal()
            release.wait()
        }
        entered.wait()
    }

    func releaseExecutor() {
        release.signal()
        executor.sync {
            _ = executor.withSafetyIngressBarrier(operationDescriptor: .resourceOwnership) { _ in }
        }
    }

    func routeCallback() {
        cell.beginRouteObservation(PlaybackRouteIngress(
            sessionIdentity: session, monitorLifecycle: 1, notificationRevision: 1,
            reasonBits: 1, topologyChangeHint: false, outputConfigurationChanged: false, observedRoute: nil
        ))
    }

    func system(_ event: PlaybackSystemSafetyEvent, at instant: UInt64) {
        clock.set(instant)
        cell.performSyncIngress(event)
    }
}

private final class SafetyIngressClock: PlaybackMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private let base = ManualPlaybackClock(0)
    private var reads = 0
    func set(_ instant: UInt64) { base.set(instant) }
    func read() -> UInt64 { nowNanoseconds }
    var nowNanoseconds: UInt64 {
        lock.withLock { reads += 1 }
        return base.nowNanoseconds
    }
    func makeDeadlineTimer(deliveryQueue: DispatchQueue) -> any PlaybackDeadlineTimer {
        base.makeDeadlineTimer(deliveryQueue: deliveryQueue)
    }
    var readCount: Int { lock.withLock { reads } }
}

private final class SafetyIngressAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var state = AppliedSafetyIngress()
    private var terminalState = AppliedSafetyIngress()
    func applyTerminal(_ snapshot: PlaybackSafetySnapshot) {
        lock.withLock {
            terminalState.last = snapshot
            terminalState.count += 1
        }
    }
    var terminalValues: AppliedSafetyIngress { lock.withLock { terminalState } }
    func apply(_ snapshot: PlaybackSafetySnapshot) {
        lock.withLock {
            if state.first == nil { state.first = snapshot }
            state.last = snapshot
            state.count += 1
        }
    }
    var values: AppliedSafetyIngress { lock.withLock { state } }
}

private struct AppliedSafetyIngress {
    var first: PlaybackSafetySnapshot?
    var last: PlaybackSafetySnapshot?
    var count = 0
}
