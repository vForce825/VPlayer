// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class SystemAudioSessionConfiguratorTests: XCTestCase {
    func testTypedInactiveAndLegacyBeganShareTheCurrentSafetyEpoch() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        let before = registry.executor.safetyIngress.snapshot
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionEpoch, before.interruptionEpoch)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.throughRevision, before.throughRevision)
    }

    func testTypedRecommendationRecoversWhenLegacyEndedNeverArrives() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        let safety = registry.executor.safetyIngress.snapshot
        XCTAssertEqual(safety.interruptionState, .ended(shouldResume: true))
        XCTAssertFalse(safety.interruptionVeto)
        XCTAssertFalse(safety.outputPermitPresent, "The recommendation is not an activation receipt")
        XCTAssertFalse(safety.readinessOpen)
        let revision = safety.throughRevision
        monitor.emit(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.throughRevision, revision,
            "A matching delayed legacy end must not invalidate the current typed recovery attempt")
    }

    func testTypedShouldNotResumeCannotBeUpgradedByLegacyResume() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: false))
        monitor.emit(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionState, .ended(shouldResume: false))
    }

    func testTypedShouldResumeCannotUpgradeLegacyManualResumeDecision() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emit(.interruptionEnded(shouldResume: false))
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
    }

    func testLateTypedInactiveCannotRestartLegacyManualResumeEpisode() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        monitor.emit(.interruptionEnded(shouldResume: false))
        let manual = registry.executor.safetyIngress.snapshot

        XCTAssertNil(monitor.emitLifecycle(.becameInactive(systemInitiated: true)),
            "A delayed advisory inactive must not manufacture a new interruption")
        XCTAssertNil(monitor.emitLifecycle(.resumptionRecommended(shouldResume: true)),
            "The same episode must not emit a positive automatic-recovery event")

        let after = registry.executor.safetyIngress.snapshot
        XCTAssertEqual(after.interruptionState, .ended(shouldResume: false))
        XCTAssertTrue(after.interruptionVeto)
        XCTAssertEqual(after.interruptionEpoch, manual.interruptionEpoch)
        XCTAssertEqual(after.throughRevision, manual.throughRevision)
        XCTAssertFalse(after.outputPermitPresent)
    }

    func testManualResumeVetoSurvivesEveryTypedLegacyInterleaving() {
        for order in InterruptionDeliveryStep.orderPreservingInterleavings {
            let registry = ControlTaskRegistry()
            let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
            var manualRevision: UInt64?
            for step in order {
                let event = step.deliver(to: monitor)?.event
                if step == .legacyEnded { manualRevision = registry.executor.safetyIngress.snapshot.throughRevision }
                if let manualRevision {
                    XCTAssertNotEqual(event, .interruptionEnded(shouldResume: true), "Order: \(order)")
                    let safety = registry.executor.safetyIngress.snapshot
                    XCTAssertEqual(safety.interruptionState, .ended(shouldResume: false), "Order: \(order)")
                    XCTAssertTrue(safety.interruptionVeto, "Order: \(order)")
                    XCTAssertEqual(safety.throughRevision, manualRevision, "Order: \(order)")
                }
            }
        }
    }

    func testResetVetoSurvivesEveryTypedLegacyInterleaving() {
        for order in InterruptionDeliveryStep.orderPreservingInterleavings {
            let registry = ControlTaskRegistry()
            let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
            var resetEpoch: UInt64?
            for step in order {
                let event = step.deliver(to: monitor)?.event
                if step == .legacyEnded {
                    monitor.emit(.mediaServicesWereReset)
                    resetEpoch = registry.executor.safetyIngress.snapshot.mediaServicesEpoch
                }
                if let resetEpoch {
                    XCTAssertNotEqual(event, .interruptionEnded(shouldResume: true), "Order: \(order)")
                    let safety = registry.executor.safetyIngress.snapshot
                    XCTAssertEqual(safety.mediaServicesEpoch, resetEpoch, "Order: \(order)")
                    XCTAssertTrue(safety.mediaServicesResumeRequired, "Order: \(order)")
                    XCTAssertTrue(safety.interruptionVeto, "Order: \(order)")
                    XCTAssertFalse(safety.outputPermitPresent, "Order: \(order)")
                }
            }
        }
    }

    func testUserPauseSurvivesEveryTypedLegacyInterleaving() async throws {
        for order in InterruptionDeliveryStep.orderPreservingInterleavings {
            let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
            let handoff = try await harness.acquire()
            let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
            let before = harness.registry.executor.safetyIngress.snapshot
            let result = harness.registry.performOutputUserControl(.init(kind: .pause,
                sessionIdentity: context.sessionIdentity, expectedOwner: context.owner, contextNonce: context.contextNonce,
                interruptionEpoch: before.interruptionEpoch, mediaServicesEpoch: before.mediaServicesEpoch,
                resetPreRouteBinding: context.resetPreRouteBinding))
            XCTAssertNotEqual(result, .rejected)
            for step in order {
                step.deliver(to: harness.owner.monitor)
                XCTAssertTrue(harness.registry.executor.safetyIngress.snapshot.userPaused, "Order: \(order)")
                XCTAssertFalse(harness.registry.executor.safetyIngress.snapshot.outputPermitPresent, "Order: \(order)")
                XCTAssertFalse(harness.registry.executor.safetyIngress.snapshot.readinessOpen, "Order: \(order)")
            }
            XCTAssertEqual(harness.registry.executor.safetyIngress.snapshot.interruptionState,
                .ended(shouldResume: false), "Order: \(order)")
            XCTAssertTrue(harness.registry.executor.safetyIngress.snapshot.interruptionVeto, "Order: \(order)")
            try await harness.release(handoff)
        }
    }

    func testTypedOnlyInterruptionStillRecommendsResume() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        XCTAssertEqual(monitor.emitLifecycle(.becameInactive(systemInitiated: true))?.event, .interruptionBegan)
        XCTAssertEqual(monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))?.event,
            .interruptionEnded(shouldResume: true))
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.outputPermitPresent)
    }

    func testNewLegacyBeganPermitsTypedRecoveryAfterManualResumeVeto() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        monitor.emit(.interruptionEnded(shouldResume: false))
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        monitor.emit(.interruptionBegan)
        let newEpisode = registry.executor.safetyIngress.snapshot.interruptionEpoch
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionEpoch, newEpisode)
        XCTAssertEqual(monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))?.event,
            .interruptionEnded(shouldResume: true))
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.interruptionVeto)
    }

    func testStoppedTypedObserverCannotDeliverIntoRestartedMonitor() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress,
            notificationCenter: NotificationCenter())
        monitor.start()
        monitor.emitLifecycle(.becameInactive(systemInitiated: true), observationGeneration: 1)
        monitor.stop()
        monitor.start()
        defer { monitor.stop() }
        let before = registry.executor.safetyIngress.snapshot
        XCTAssertNil(monitor.emitLifecycle(.becameInactive(systemInitiated: true), observationGeneration: 1))
        XCTAssertNil(monitor.emitLifecycle(.resumptionRecommended(shouldResume: true), observationGeneration: 1))
        XCTAssertNil(monitor.emitLifecycle(.becameActive, observationGeneration: 1))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.throughRevision, before.throughRevision)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
    }

    func testNewLegacyInterruptionInvalidatesOlderTypedRecommendation() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emit(.interruptionBegan)
        let epoch = registry.executor.safetyIngress.snapshot.interruptionEpoch
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionEpoch, epoch)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionState, .began)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
    }

    func testTypedActiveAndAppInactiveNeverManufacturePhysicalCompletions() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emit(.interruptionBegan)
        let before = registry.executor.safetyIngress.snapshot
        monitor.emitLifecycle(.becameActive)
        monitor.emitLifecycle(.becameInactive(systemInitiated: false))
        let after = registry.executor.safetyIngress.snapshot
        XCTAssertEqual(after.interruptionEpoch, before.interruptionEpoch)
        XCTAssertEqual(after.throughRevision, before.throughRevision)
        XCTAssertEqual(after.interruptionVeto, before.interruptionVeto)
        XCTAssertFalse(after.outputPermitPresent)
        XCTAssertFalse(after.readinessOpen)
    }

    func testMediaResetRejectsLateTypedRecommendationAndActiveMessage() {
        let registry = ControlTaskRegistry()
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        monitor.emit(.mediaServicesWereReset)
        let before = registry.executor.safetyIngress.snapshot
        monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        monitor.emitLifecycle(.becameActive)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.mediaServicesEpoch, before.mediaServicesEpoch)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.interruptionEpoch, before.interruptionEpoch)
        XCTAssertTrue(registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertFalse(registry.executor.safetyIngress.snapshot.outputPermitPresent)
    }

    func testLifecycleEpochCASRejectsResetBetweenProjectionAndIngress() {
        let registry = ControlTaskRegistry()
        let ingress = registry.executor.safetyIngress
        ingress.performSyncIngress(.interruptionBegan)
        let old = AudioSessionLifecycleEpoch(ingress.snapshot)
        ingress.performSyncIngress(.mediaServicesReset)
        let before = ingress.snapshot
        XCTAssertNil(ingress.performSyncIngress(.interruptionEnded(shouldResume: true), matching: old))
        XCTAssertEqual(ingress.snapshot.throughRevision, before.throughRevision)
        XCTAssertEqual(ingress.snapshot.mediaServicesEpoch, before.mediaServicesEpoch)
        XCTAssertTrue(ingress.snapshot.interruptionVeto)
    }

    func testNewUserPlaybackRequestMayClearResetGateButNeverANewerInterruption() throws {
        let registry = ControlTaskRegistry()
        let ingress = registry.executor.safetyIngress
        ingress.performSyncIngress(.mediaServicesReset)
        _ = try registry.admitPlaybackRequest(requestID: UUID())
        XCTAssertFalse(ingress.snapshot.mediaServicesResumeRequired)
        XCTAssertFalse(ingress.snapshot.interruptionVeto)
        ingress.performSyncIngress(.mediaServicesReset)
        ingress.performSyncIngress(.interruptionBegan)
        _ = try registry.admitPlaybackRequest(requestID: UUID())
        XCTAssertFalse(ingress.snapshot.mediaServicesResumeRequired)
        XCTAssertTrue(ingress.snapshot.interruptionVeto)
        XCTAssertEqual(ingress.snapshot.interruptionState, .began)
    }

    func testUserPauseSurvivesTypedResumption() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let before = harness.registry.executor.safetyIngress.snapshot
        let result = harness.registry.performOutputUserControl(.init(kind: .pause,
            sessionIdentity: context.sessionIdentity, expectedOwner: context.owner, contextNonce: context.contextNonce,
            interruptionEpoch: before.interruptionEpoch, mediaServicesEpoch: before.mediaServicesEpoch,
            resetPreRouteBinding: context.resetPreRouteBinding))
        XCTAssertNotEqual(result, .rejected)
        harness.owner.monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        harness.owner.monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        XCTAssertTrue(harness.registry.executor.safetyIngress.snapshot.userPaused)
        XCTAssertFalse(harness.registry.executor.safetyIngress.snapshot.outputPermitPresent)
        XCTAssertFalse(harness.registry.executor.safetyIngress.snapshot.readinessOpen)
        try await harness.release(handoff)
    }

    func testFirstAcquisitionConfiguresLongFormMultichannelThenActivates() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testLongFormFailureFallsBackToDefaultBeforeActivation() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .category(.default),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testSequentialAcquisitionsReuseProcessAndMultichannelState() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let first = try await harness.acquire()
        try await harness.release(first)
        let second = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
        try await harness.release(second)
    }

    func testMultichannelFailureDoesNotPreventActivation() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], multichannelFails: true)
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testAcquisitionActivationFailureDoesNotProduceReadyReceipt() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], activationFailures: 1)
        let ticket = try harness.prepareAcquisition()
        XCTAssertTrue(try harness.owner.startAcquisition(ticket, receiver: harness.receiver))
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(harness.registry.outputAcquisitionCommitSnapshot())
    }

    func testFailureDiagnosticsPreserveFixedDomainAndClampedCode() async throws {
        let harness = try AudioSessionLifecycleTestHarness(
            categoryResults: [.failure, .success],
            categoryFailure: NSError(domain: NSOSStatusErrorDomain, code: 42)
        )
        let handoff = try await harness.acquire()
        let reason = try XCTUnwrap(harness.registry.processAudioSessionReceiptSnapshot()?.preferredFailureReason)
        XCTAssertEqual(reason.domain, .osStatus)
        XCTAssertEqual(reason.code, 42)
        XCTAssertTrue(reason.diagnostic?.summary.contains("NSOSStatusErrorDomain(42)") == true)
        try await harness.release(handoff)
    }

    func testMediaServicesResetInvalidatesProcess() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success, .success])
        let first = try await harness.acquire()
        try await harness.release(first)
        harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
        let second = try await harness.acquire(reset: true)
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(prepareGraphResetActivationAfterUserResume(harness.registry, contextNonce: context.contextNonce))
        XCTAssertEqual(harness.owner.invoke(activation, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if harness.sdk.events.filter({ $0 == .activate }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
        try await harness.release(second)
    }

    func testInterruptionBeganIncrementsSafetyIngressRevision() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let before = harness.registry.executor.safetyIngress.snapshot.throughRevision
        harness.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertGreaterThan(harness.registry.executor.safetyIngress.snapshot.throughRevision, before)
        try await harness.release(handoff)
    }
}

private enum InterruptionDeliveryStep: Sendable, Equatable {
    case legacyBegan, legacyEnded, typedInactive, typedResume

    // Every merge of [legacyBegan, legacyEnded] and [typedInactive, typedResume].
    static let orderPreservingInterleavings: [[Self]] = [
        [.legacyBegan, .legacyEnded, .typedInactive, .typedResume],
        [.legacyBegan, .typedInactive, .legacyEnded, .typedResume],
        [.legacyBegan, .typedInactive, .typedResume, .legacyEnded],
        [.typedInactive, .legacyBegan, .legacyEnded, .typedResume],
        [.typedInactive, .legacyBegan, .typedResume, .legacyEnded],
        [.typedInactive, .typedResume, .legacyBegan, .legacyEnded],
    ]

    @discardableResult
    func deliver(to monitor: SystemAudioEventMonitor) -> PlaybackAudioSessionEventEnvelope? {
        switch self {
        case .legacyBegan: monitor.emit(.interruptionBegan)
        case .legacyEnded: monitor.emit(.interruptionEnded(shouldResume: false))
        case .typedInactive: monitor.emitLifecycle(.becameInactive(systemInitiated: true))
        case .typedResume: monitor.emitLifecycle(.resumptionRecommended(shouldResume: true))
        }
    }
}
