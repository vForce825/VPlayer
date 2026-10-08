// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeHLSMasterSmokeTests: XCTestCase {
    func testRealPublicMIMEPlanningPlaysNativeAndManagedMediaWithoutGeneration() async throws {
        executionTimeAllowance = 120
        let deadline = ContinuousClock.now + .seconds(90)
        for managed in [false, true] {
            let origin = try makeOrigin(bytes: fixtureBytes(), managed: managed)
            var failure: (any Error)?
            do {
                try await withController(deadline: deadline, publicMIMEQueries: true) { [self] controller, registry, factory in
                    await controller.play(.init(sourceProfileID: UUID(), channelID: "public-mime-media-\(managed)",
                        streamURL: origin.url("media.m3u8"), title: "Public MIME media",
                        attributes: managed ? ["Authorization": "ordinary fixture"] : [:]))
                    try await until(registry: registry, factory: factory, phase: "public-mime-media-startup", managed: managed,
                        deadline: min(deadline, .now + .seconds(20))) {
                        guard case .playing = registry.playbackStateSnapshot(),
                              let backend = factory.backend, let coordinator = backend.nativeCoordinatorForTesting,
                              coordinator.isPrepared, coordinator.currentActivation != nil,
                              let player = backend.presentation?.avPlayerForNativeSmoke else { return false }
                        return player.currentTime().seconds > 0.5
                    }
                    let backend = try XCTUnwrap(factory.backend)
                    let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                    XCTAssertEqual(coordinator.owned.plan.transport, managed ? .proxy : .native)
                    XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
                    print("NATIVE_HLS_PUBLIC_MIME_PLAYBACK sdk-runtime=true managed=\(managed) progressed=true generated=0")
                }
            } catch { failure = error }
            await origin.close()
            if let failure { throw failure }
        }
    }

    func testNativeSDKEndBoundaryControlsKeepSameSource() async throws {
        let bytes = try fixtureBytes()
        // These sequential SDK controls isolate endpoint ordering. They do not
        // supply Registry authority or count as native-adapter acceptance.
        for boundary in NativeEndpointControl.allCases {
            let result = try await runEndpointControl(boundary, bytes: bytes)
            if boundary == .defaultEnd {
                XCTAssertTrue(result.progressed, "The unmodified full source must actually progress")
                XCTAssertNil(result.errorDomain)
            } else {
                // Exact tvOS 27 reproduction for this unchanged TS/master, not
                // a blanket claim that HLS trimming is unsupported by AVPlayer.
                XCTAssertFalse(result.progressed)
                XCTAssertEqual(result.errorDomain, "CoreMediaErrorDomain")
                XCTAssertEqual(result.errorCode, -12865)
            }
        }
    }

    func testRealNativeAndManagedHLSReachVerifiedUntrimmedEOF() async throws {
        executionTimeAllowance = 240
        let deadline = ContinuousClock.now + .seconds(210)
        for managed in [false, true] { try await verifyNaturalEOF(managed: managed, deadline: deadline) }
    }

    func testNativeEOSFirstReadPrecedesRateAndControlSettlement() async throws {
        for rate in [Float(1), Float(0)] {
            try await verifyNativeEOSSettlement(firstRate: rate, outcome: .settled)
        }
    }

    func testNativeEOSOriginalDeadlineRejectsUnsettledTransportAndInvalidEvidence() async throws {
        for outcome in [NativeEOSSettlementOutcome.positiveRate, .playingControl, .changedClock,
                        .earlyClock, .staleRevision, .supersededInstall] {
            try await verifyNativeEOSSettlement(firstRate: 1, outcome: outcome)
        }
    }

    func testNativeEOSOwnedStopCancelsOriginalDeadlineAndRejectsLateDelivery() async throws {
        try await verifyNativeEOSSettlement(firstRate: 1, outcome: .cancelled)
    }

    func testNativeEOSErrorCancelsOriginalDeadlineAndRejectsLateDelivery() async throws {
        try await verifyNativeEOSSettlement(firstRate: 1, outcome: .failedToEnd)
    }

    func testNativeEOSProgressPollPreservesOriginalFirstReadAndDeadline() async throws {
        try await verifyNativeEOSSettlement(firstRate: 1, outcome: .progressPoll)
    }

    func testNativeRefreshRetriesSupersededReturnedSnapshotWithinOriginalEOFWindow() async throws {
        try await verifyNativeRefreshReturnEdge(.once)
        try await verifyNativeRefreshReturnEdge(.mixed)
    }

    func testNativeRefreshBoundsSupersessionAndRejectsBindingChangeAndRevocation() async throws {
        for mode in [NativeRefreshReturnMode.exhausted, .bindingChanged, .revoked] {
            try await verifyNativeRefreshReturnEdge(mode)
        }
    }

    func testNativeQuantumOwnsSelectedSDKReferencesAndChargeThroughRetirement() async throws {
        let baseline = HLSDeliveryApplicationChargeLedger.shared.chargedBytes
        let origin = try makeOrigin(bytes: fixtureBytes(), managed: false)
        let held = NativeQuantumReceiptHold()
        var failure: (any Error)?
        do {
            try await withController { [self] controller, registry, factory in
                await controller.play(.init(sourceProfileID: UUID(), channelID: "quantum-owner-original",
                    streamURL: origin.url("master.m3u8"), title: "Quantum owner original"))
                try await until(registry: registry, factory: factory, phase: "quantum-owner-original", managed: false) {
                    guard let current = factory.backend?.nativeCoordinatorForTesting, current.isPrepared,
                          current.currentActivation != nil,
                          let player = factory.backend?.presentation?.avPlayerForNativeSmoke else { return false }
                    return player.currentTime().seconds > 0.25
                }
                try await captureQuantumReceipt(held, backend: XCTUnwrap(factory.backend))
                // All strong snapshot/item/track/asset locals live only in the
                // capture helper. The external receipt aliases now own our holds.
                await controller.play(.init(sourceProfileID: UUID(), channelID: "quantum-owner-successor",
                    streamURL: origin.url("master.m3u8"), title: "Quantum owner successor"))
                try await until(registry: registry, factory: factory, phase: "quantum-owner-successor", managed: false) {
                    guard let current = factory.backend?.nativeCoordinatorForTesting,
                          current.isPrepared, current.currentActivation != nil,
                          let player = factory.backend?.presentation?.avPlayerForNativeSmoke else { return false }
                    return current.item != held.item && player.currentTime().seconds > 0.25
                }
                try await checkSuccessorRejectsHeldQuantum(held, backend: XCTUnwrap(factory.backend))
            }
            // withController has joined real native retirement and callbacks.
            await nativeEOSMainQueueTurn()
            XCTAssertNotNil(held.track)
            XCTAssertNotNil(held.asset)
            XCTAssertNotNil(held.weakReceipt)
            let retainedBytes = HLSDeliveryApplicationChargeLedger.shared.chargedBytes
            XCTAssertGreaterThanOrEqual(retainedBytes, 8 * 1_024)
            held.receipt = nil
            XCTAssertNotNil(held.weakReceipt, "A second external receipt alias must keep its original ownership")
            XCTAssertEqual(HLSDeliveryApplicationChargeLedger.shared.chargedBytes, retainedBytes,
                "Dropping one alias must not return the live receipt's credit")
            held.alias = nil
            let deadline = ContinuousClock.now + .seconds(2)
            while (held.weakReceipt != nil || HLSDeliveryApplicationChargeLedger.shared.chargedBytes > baseline),
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(held.weakReceipt)
            XCTAssertLessThanOrEqual(HLSDeliveryApplicationChargeLedger.shared.chargedBytes, baseline)
            // SDK caches may independently retain these wrappers. Receipt death
            // releases our references; their final framework deallocation is not
            // an AVFoundation guarantee and is deliberately not asserted here.
        } catch { failure = error }
        held.receipt = nil; held.alias = nil
        await origin.close()
        if let failure { throw failure }
    }

    private func captureQuantumReceipt(_ held: NativeQuantumReceiptHold, backend: HLSAVPlayerPlaybackBackend) async throws {
        let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
        let driver = try XCTUnwrap(backend.nativeSystemDriverForTesting)
        let physical = try XCTUnwrap(driver.nativeCurrentItem(coordinator.item))
        let snapshot = try await SystemNativeHLSAssetInspector(driver: driver).snapshot(item: coordinator.item, source: coordinator.owned)
        let quantum = try XCTUnwrap(snapshot.finalPresentationQuantum)
        XCTAssertEqual(quantum.visualSelection, .absent,
            "The real inspector must positively establish visual absence for this fixture")
        let track = try XCTUnwrap(physical.tracks.first { $0.isEnabled && $0.assetTrack?.mediaType == .video })
        let asset = try XCTUnwrap(track.assetTrack)
        XCTAssertTrue(quantum.hasCurrentIdentity(item: coordinator.item, physical: physical))
        let same = NativeHLSFinalPresentationQuantum.compareBindings(prior: quantum, current: quantum)
        XCTAssertEqual(same, .init(presence: 3, equalFields: NativeHLSQuantumBindingComparison.allFields,
            visualSelections: quantum.visualSelection.rawValue | (quantum.visualSelection.rawValue << 2)))
        XCTAssertTrue(same.matches)
        let appeared = NativeHLSFinalPresentationQuantum.compareBindings(prior: nil, current: quantum)
        let disappeared = NativeHLSFinalPresentationQuantum.compareBindings(prior: quantum, current: nil)
        XCTAssertEqual(appeared, .init(presence: 2, equalFields: 0, visualSelections: quantum.visualSelection.rawValue << 2))
        XCTAssertEqual(disappeared, .init(presence: 1, equalFields: 0, visualSelections: quantum.visualSelection.rawValue))
        XCTAssertFalse(appeared.matches); XCTAssertFalse(disappeared.matches)
        held.track = track; held.asset = asset; held.item = coordinator.item
        held.receipt = quantum; held.alias = quantum; held.weakReceipt = quantum
    }

    private func checkSuccessorRejectsHeldQuantum(_ held: NativeQuantumReceiptHold, backend: HLSAVPlayerPlaybackBackend) async throws {
        let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
        let driver = try XCTUnwrap(backend.nativeSystemDriverForTesting)
        let physical = try XCTUnwrap(driver.nativeCurrentItem(coordinator.item))
        let snapshot = try await SystemNativeHLSAssetInspector(driver: driver).snapshot(item: coordinator.item, source: coordinator.owned)
        let prior = try XCTUnwrap(held.receipt), current = try XCTUnwrap(snapshot.finalPresentationQuantum)
        let comparison = NativeHLSFinalPresentationQuantum.compareBindings(prior: prior, current: current)
        XCTAssertEqual(comparison.presence, 3)
        XCTAssertEqual(comparison.equalFields & 1, 0, "A successor cannot reuse the original logical item")
        XCTAssertFalse(comparison.matches)
        XCTAssertFalse(prior.hasCurrentIdentity(item: coordinator.item, physical: physical))
        XCTAssertThrowsError(try driver.updateNaturalPlaybackEndQuantum(prior, item: coordinator.item))
        XCTAssertNotNil(held.track); XCTAssertNotNil(held.asset)
    }

    private func verifyNativeRefreshReturnEdge(_ mode: NativeRefreshReturnMode) async throws {
        let origin = try makeOrigin(bytes: fixtureBytes(), managed: false)
        let player = NativeEOSObservationPlayer()
        let deadlines = NativeEOSManualDeadlineScheduler()
        let driver = try SystemAVPlayerDriver.make(player: player, deadlineScheduler: deadlines)
        var failure: (any Error)?
        do {
            try await withController(driver: driver) { [self] controller, registry, factory in
                defer { factory.trace.snapshotReturn = nil; player.observation = nil }
                await controller.play(.init(sourceProfileID: UUID(), channelID: "native-refresh-return",
                    streamURL: origin.url("master.m3u8"), title: "Native refresh return edge"))
                try await until(registry: registry, factory: factory, phase: "refresh-return-startup", managed: false) {
                    factory.backend?.nativeCoordinatorForTesting?.currentActivation != nil && player.currentTime().seconds > 0.25
                }
                let backend = try XCTUnwrap(factory.backend)
                let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                let physical = try XCTUnwrap(player.currentItem)
                let activation = try XCTUnwrap(coordinator.currentActivation)
                let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
                let endpoint = try ExactMediaTime(physical.duration)
                player.observation = .init(time: try endpoint.subtracting(.init(value: 1, timescale: 60)).cmTime,
                    rate: 0, control: .paused)
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: physical)
                try await until(registry: registry, factory: factory, phase: "refresh-return-first-read", managed: false) {
                    driver.naturalEndObservation != nil && factory.trace.selectedRevision == driver.nativeSelectionRevision.current
                }
                await nativeEOSMainQueueTurn()
                let first = try XCTUnwrap(driver.naturalEndObservation)
                let originalDeadline = try XCTUnwrap(deadlines.nextIdentity)
                let control = NativeRefreshReturnControl()
                factory.trace.snapshotReturn = { snapshot, source, currentDriver in
                    guard NativeRefreshReturnScope.identity == control.identity,
                          snapshot.item == coordinator.item else { return snapshot }
                    control.calls += 1
                    // The real inspector has already validated/returned this
                    // receipt. Model a callback invalidating it at that edge.
                    if mode == .mixed, control.calls == 1 { throw AVPlayerItemCoordinatorFailure.selectionChanged }
                    if mode == .exhausted || mode == .bindingChanged || mode == .revoked ||
                        (mode == .once && control.calls == 1) || (mode == .mixed && control.calls == 2) {
                        currentDriver.nativeSelectionRevision.invalidate(reason: .accessLog)
                    }
                    if mode == .revoked {
                        let safety = registry.executor.safetyIngress.snapshot
                        let request = OutputUserControlRequest(kind: .pause, sessionIdentity: context.sessionIdentity,
                            expectedOwner: context.owner, contextNonce: context.contextNonce,
                            interruptionEpoch: safety.interruptionEpoch, mediaServicesEpoch: safety.mediaServicesEpoch,
                            resetPreRouteBinding: context.resetPreRouteBinding)
                        XCTAssertEqual(registry.performOutputUserControl(request), .acceptedWaiting)
                    }
                    if mode == .bindingChanged {
                        // Omit timing evidence; do not fabricate another quantum.
                        // A pending window's present-to-nil binding remains terminal
                        // even though the same callback also superseded revision.
                        return try .init(item: snapshot.item, physicalItem: snapshot.physicalItem,
                            audioSelection: snapshot.audioSelection, video: snapshot.video, audio: snapshot.audio,
                            audioConfigurationDigest: snapshot.audioConfigurationDigest, observedFrameRate: snapshot.observedFrameRate,
                            sourceOwner: source, retention: HLSApplicationLifetimeCharge(bytes: 8 * 1_024),
                            duration: snapshot.duration, finalPresentationQuantum: nil)
                    }
                    return snapshot
                }
                await NativeRefreshReturnScope.$identity.withValue(control.identity) {
                    await coordinator.observeSelectedFormatChangeForTesting()
                }
                factory.trace.snapshotReturn = nil
                if mode == .once || mode == .mixed {
                    XCTAssertEqual(control.calls, mode == .once ? 2 : 3,
                        "Inspector retry and post-return install retry share exactly three total attempts")
                    XCTAssertNil(coordinator.firstFailureDiagnosticForTesting)
                    XCTAssertTrue(backend.nativeCoordinatorForTesting === coordinator)
                    XCTAssertTrue(player.currentItem === physical)
                    XCTAssertEqual(registry.outputResourceContextSnapshot()?.activation, activation)
                    XCTAssertEqual(deadlines.nextIdentity, originalDeadline)
                    XCTAssertEqual(deadlines.nextDelay, 0.1)
                    XCTAssertEqual(driver.naturalEndObservation?.firstCurrentTime, first.firstCurrentTime)
                    XCTAssertTrue(deadlines.fireNext())
                    await nativeEOSMainQueueTurn()
                    XCTAssertTrue(coordinator.naturalEndVerifiedForTesting)
                } else if mode == .revoked {
                    XCTAssertEqual(control.calls, 1)
                    XCTAssertFalse(coordinator.naturalEndVerifiedForTesting)
                    await controller.setPaused(true)
                } else {
                    XCTAssertEqual(control.calls, mode == .exhausted ? 3 : 1)
                    XCTAssertFalse(coordinator.naturalEndVerifiedForTesting)
                    let detail = try XCTUnwrap(coordinator.firstFailureDiagnosticForTesting)
                    XCTAssertTrue(detail.contains("step=quantum-install"), detail)
                    XCTAssertTrue(detail.contains(mode == .exhausted ? "predicate=refresh.quantum.revision" : "predicate=refresh.pendingBinding"), detail)
                    if mode == .bindingChanged { XCTAssertTrue(detail.contains(" b=1/0"), detail) }
                }
                player.observation = nil
            }
            XCTAssertEqual(deadlines.count, 0)
        } catch { failure = error }
        player.observation = nil
        await origin.close()
        if let failure { throw failure }
    }

    /// Deterministic SDK-observation ordering controls, not real media-end
    /// acceptance. The unmodified 80-second test above supplies that evidence.
    private func verifyNativeEOSSettlement(firstRate: Float, outcome: NativeEOSSettlementOutcome) async throws {
        let origin = try makeOrigin(bytes: fixtureBytes(), managed: false)
        let player = NativeEOSObservationPlayer()
        let deadlines = NativeEOSManualDeadlineScheduler()
        let driver = try SystemAVPlayerDriver.make(player: player, deadlineScheduler: deadlines)
        var failure: (any Error)?
        do {
            try await withController(driver: driver) { [self] controller, registry, factory in
                defer { player.observation = nil }
                await controller.play(.init(sourceProfileID: UUID(), channelID: "native-eos-settlement",
                    streamURL: origin.url("master.m3u8"), title: "Native EOS ordering control"))
                try await until(registry: registry, factory: factory, phase: "eos-ordering-startup", managed: false) {
                    factory.backend?.nativeCoordinatorForTesting?.isPrepared == true &&
                        factory.backend?.nativeCoordinatorForTesting?.currentActivation != nil &&
                        player.currentTime().seconds > 0.25
                }
                let backend = try XCTUnwrap(factory.backend)
                let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                let activation = try XCTUnwrap(coordinator.currentActivation)
                let physical = try XCTUnwrap(player.currentItem)
                let endpoint = try ExactMediaTime(physical.duration)
                XCTAssertFalse(physical.forwardPlaybackEndTime.isValid,
                    "This regression must exercise the native untrimmed path, not constrained AAC")
                XCTAssertEqual(deadlines.count, 0)
                let foreign = AVPlayerItem(url: origin.url("master.m3u8"))
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: foreign)
                await nativeEOSMainQueueTurn()
                XCTAssertNil(driver.naturalEndObservation, "A foreign physical item's notification cannot start the window")
                XCTAssertEqual(deadlines.count, 0)
                let clock: CMTime
                if outcome == .earlyClock { clock = .zero }
                else { clock = try endpoint.subtracting(ExactMediaTime(value: 1, timescale: 60)).cmTime }
                player.observation = .init(time: clock, rate: firstRate, control: .playing)
                // Deliver through the installed private observer, which owns
                // the original EOS token and post-EOS selection invalidation.
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: physical)
                try await until(registry: registry, factory: factory, phase: "eos-ordering-first-read", managed: false) {
                    driver.naturalEndObservation != nil || driver.naturalEndTerminalResult != nil
                }
                let first = try XCTUnwrap(driver.naturalEndObservation)
                XCTAssertEqual(first.firstCurrentTime, try ExactMediaTime(clock))
                XCTAssertNil(first.stableCurrentTime)
                XCTAssertNil(driver.naturalEndTerminalResult)
                let original = try XCTUnwrap(deadlines.nextIdentity)
                XCTAssertEqual(deadlines.nextDelay, 0.1)
                XCTAssertEqual(deadlines.count, 1)
                XCTAssertFalse(driver.hasPendingNaturalEndVerification(item: coordinator.item, activation: activation),
                    "The pause exemption remains unavailable until direct transport reads are paused")
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: physical)
                await nativeEOSMainQueueTurn()
                XCTAssertEqual(driver.naturalEndObservation?.firstCurrentTime, first.firstCurrentTime)
                XCTAssertEqual(deadlines.nextIdentity, original, "A repeated notification cannot renew the window")
                XCTAssertEqual(deadlines.count, 1)
                // Observe the original private-EOS refresh's real inspector
                // receipt. Do not start another refresh or fabricate a receipt.
                try await until(registry: registry, factory: factory, phase: "eos-ordering-refresh", managed: false) {
                    guard let refreshed = factory.trace.selectedRevision,
                          let current = driver.nativeSelectionRevision.current else { return false }
                    return refreshed == current
                }
                await nativeEOSMainQueueTurn()
                if outcome == .progressPoll {
                    let reads = player.observationReadCount
                    // The real Registry progress timer remains active while the
                    // test scheduler holds only the EOS delivery. No direct clock
                    // reads are made by this predicate.
                    try await until(registry: registry, factory: factory, phase: "eos-ordering-progress", managed: false) {
                        player.observationReadCount > reads
                    }
                    XCTAssertEqual(driver.naturalEndObservation?.firstCurrentTime, first.firstCurrentTime)
                    XCTAssertEqual(deadlines.nextIdentity, original)
                }
                player.observation = .init(time: outcome == .changedClock ? CMTimeSubtract(clock, CMTime(value: 1, timescale: 60)) : clock,
                    rate: outcome == .positiveRate ? 1 : 0,
                    control: outcome == .playingControl ? .playing : .paused)
                if outcome == .staleRevision { driver.nativeSelectionRevision.invalidate() }
                if outcome == .supersededInstall {
                    let snapshot = try await SystemNativeHLSAssetInspector(driver: driver).snapshot(item: coordinator.item, source: coordinator.owned)
                    driver.nativeSelectionRevision.invalidate(reason: .accessLog)
                    do {
                        try driver.updateNaturalPlaybackEndQuantum(snapshot.finalPresentationQuantum, item: coordinator.item)
                        XCTFail("The returned snapshot must be superseded before installation")
                    } catch { XCTAssertTrue(error is NativeHLSQuantumRevisionSuperseded) }
                    XCTAssertEqual(driver.naturalEndQuantumUpdateFailureDiagnosticForTesting?.predicate, .refreshQuantum)
                    XCTAssertNil(driver.naturalEndFailureDiagnosticForTesting,
                        "An install rejection must leave the original EOF diagnostic slot available")
                }
                if outcome != .positiveRate && outcome != .playingControl {
                    driver.eventHub.receive(.paused, item: coordinator.item, activation: activation)
                    await nativeEOSMainQueueTurn()
                    XCTAssertTrue(backend.nativeCoordinatorForTesting === coordinator)
                    XCTAssertTrue(driver.hasPendingNaturalEndVerification(item: coordinator.item, activation: activation))
                }
                XCTAssertEqual(driver.naturalEndObservation?.firstCurrentTime, first.firstCurrentTime)
                XCTAssertEqual(deadlines.nextIdentity, original, "A later pause must not renew the original deadline")
                XCTAssertNil(driver.naturalEndTerminalResult)
                let copiedDelivery = try XCTUnwrap(deadlines.nextCallback)
                if outcome == .cancelled || outcome == .failedToEnd {
                    if outcome == .failedToEnd {
                        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: physical)
                        try await until(registry: registry, factory: factory, phase: "eos-ordering-error", managed: false) {
                            coordinator.firstFailureDiagnosticForTesting != nil
                        }
                        XCTAssertTrue(coordinator.firstFailureDiagnosticForTesting?.contains("stage=observation.failed") == true)
                        XCTAssertFalse(coordinator.naturalEndVerifiedForTesting)
                    }
                    // Clear the observation override before real ownership joins.
                    player.observation = nil
                    await controller.stop(); await registry.joinOwnedTerminalCleanup()
                    XCTAssertEqual(deadlines.count, 0)
                    copiedDelivery(); await nativeEOSMainQueueTurn()
                    XCTAssertNil(driver.naturalEndTerminalResult)
                    XCTAssertNil(driver.currentItemIdentity)
                    XCTAssertNil(registry.outputResourceContextSnapshot())
                } else {
                    XCTAssertTrue(deadlines.fireNext())
                    // A rejected terminal can initiate recovery, so inspect the
                    // bounded failure retained by the original coordinator.
                    await nativeEOSMainQueueTurn()
                    if outcome == .settled || outcome == .progressPoll {
                        XCTAssertTrue(coordinator.naturalEndVerifiedForTesting)
                        let terminal = try XCTUnwrap(driver.naturalEndObservation)
                        XCTAssertEqual(terminal.firstCurrentTime, terminal.stableCurrentTime)
                        XCTAssertTrue(player.currentItem === physical)
                    } else {
                        XCTAssertFalse(coordinator.naturalEndVerifiedForTesting)
                        let expected = outcome == .changedClock ? "unstableDirectRead" : "endpointMismatch"
                        XCTAssertTrue(coordinator.firstFailureDiagnosticForTesting?.contains("endpoint-reason=\(expected)") == true)
                        let predicate: String?
                        switch outcome {
                        case .changedClock: predicate = "confirm.stableClock"
                        case .positiveRate: predicate = "confirm.rate"
                        case .playingControl: predicate = "confirm.control"
                        case .earlyClock: predicate = "confirm.finalClock"
                        case .staleRevision, .supersededInstall: predicate = "confirm.quantum.revision"
                        default: predicate = nil
                        }
                        if let predicate {
                            let originalFailure = try XCTUnwrap(coordinator.firstFailureDiagnosticForTesting)
                            XCTAssertTrue(originalFailure.contains("predicate=\(predicate)"), originalFailure)
                            if outcome == .staleRevision {
                                XCTAssertTrue(originalFailure.contains(" r="))
                                XCTAssertTrue(originalFailure.contains(" why="))
                            }
                            XCTAssertTrue(originalFailure.contains(" f=\(first.firstCurrentTime.value)/\(first.firstCurrentTime.timescale)"))
                            if outcome == .changedClock {
                                let stable = try ExactMediaTime(CMTimeSubtract(clock, CMTime(value: 1, timescale: 60)))
                                XCTAssertTrue(originalFailure.contains(" s=\(stable.value)/\(stable.timescale)"), originalFailure)
                            }
                            XCTAssertLessThanOrEqual(originalFailure.utf8.count, 384)
                            player.observation = nil
                            await controller.stop(); await registry.joinOwnedTerminalCleanup()
                            XCTAssertEqual(coordinator.firstFailureDiagnosticForTesting, originalFailure,
                                "Retirement must not replace the original read's predicate with successor state")
                        }
                    }
                    XCTAssertNotEqual(deadlines.nextIdentity, original)
                    player.observation = nil
                }
                XCTAssertEqual(driver.fixedTimerCount, 0)
                XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
            }
            XCTAssertEqual(deadlines.count, 0, "The real controller cleanup must join every outstanding deadline")
        } catch { failure = error }
        player.observation = nil
        await origin.close()
        if let failure { throw failure }
    }

    func testQuantumWrapperRenewalRequiresExactAssetAndPositiveVisualAbsence() {
        for evidence in NativeHLSVisualSelectionEvidence.allCases {
            for fields in UInt8(0)...3 {
                let comparison = NativeHLSQuantumSDKIdentityComparison(equalFields: fields, visualSelection: evidence)
                XCTAssertEqual(comparison.failure(allowingWrapperRenewal: false) == nil, fields == 3)
                XCTAssertEqual(comparison.failure(allowingWrapperRenewal: true) == nil,
                    fields == 3 || (fields == 2 && evidence == .absent))
                for ready in [false, true] {
                    for errorFree in [false, true] {
                        XCTAssertEqual(comparison.permitsPendingPause(isReady: ready, errorFree: errorFree),
                            fields == 3 || (fields == 2 && evidence == .absent && ready && errorFree))
                    }
                }
                if fields == 0 {
                    XCTAssertEqual(comparison.failure(allowingWrapperRenewal: true), .videoTrack)
                    XCTAssertEqual(comparison.equalFields & 2, 0, "Asset inequality survives the first wrapper rejection")
                }
                if fields == 1 { XCTAssertEqual(comparison.failure(allowingWrapperRenewal: true), .videoAssetIdentity) }
            }
        }
    }

    func testPendingQuantumRenewalMayChangeOnlyPresentationWrapper() {
        for presence in UInt8(0)...3 {
            for prior in NativeHLSVisualSelectionEvidence.allCases {
                for current in NativeHLSVisualSelectionEvidence.allCases {
                    let visual = prior.rawValue | (current.rawValue << 2)
                    let wrapperOnly = NativeHLSQuantumBindingComparison(presence: presence, equalFields: 0x1FB, visualSelections: visual)
                    XCTAssertEqual(wrapperOnly.matchesPendingWindow,
                        presence == 0 || (presence == 3 && prior == .absent && current == .absent))
                }
            }
        }
        for bit in 0..<9 where bit != 2 {
            let fields = NativeHLSQuantumBindingComparison.allFields ^ (UInt16(1) << bit)
            for additionalWrapperChange in [UInt16(0), UInt16(1 << 2)] {
                let changed = NativeHLSQuantumBindingComparison(presence: 3,
                    equalFields: fields ^ additionalWrapperChange, visualSelections: 5)
                XCTAssertFalse(changed.matchesPendingWindow, "Actual media/item/source/format/timing changes remain terminal")
            }
        }
    }

    func testWrapperWindowRestrictionSurvivesOriginalWrapperReturnAndMissingEvidence() {
        var window = NativeHLSQuantumWindow()
        XCTAssertTrue(window.permits(nil), "Unchanged exact-endpoint-only behavior before any wrapper exception")
        window.recordWrapperRenewal(false)
        XCTAssertFalse(window.requiresVisualAbsence)
        window.recordWrapperRenewal(true)
        window.recordWrapperRenewal(false) // Original wrapper returns, or a retry has exact identity.
        XCTAssertTrue(window.requiresVisualAbsence)
        XCTAssertTrue(window.permits(.absent))
        XCTAssertFalse(window.permits(nil))
        for evidence in NativeHLSVisualSelectionEvidence.allCases where evidence != .absent {
            XCTAssertFalse(window.permits(evidence))
        }
        window.reset()
        XCTAssertFalse(window.requiresVisualAbsence)
        XCTAssertTrue(window.permits(nil))
    }

    func testVisualAbsenceRequiresSuccessfulSDKLoadAndNoSourceAlternates() throws {
        XCTAssertEqual(NativeHLSVisualSelectionEvidence.classify(sourceHasNoAlternates: true,
            groupLoaded: true, groupPresent: false), .absent)
        XCTAssertEqual(NativeHLSVisualSelectionEvidence.classify(sourceHasNoAlternates: true,
            groupLoaded: false, groupPresent: false), .unknown)
        XCTAssertEqual(NativeHLSVisualSelectionEvidence.classify(sourceHasNoAlternates: true,
            groupLoaded: true, groupPresent: true), .present)
        XCTAssertEqual(NativeHLSVisualSelectionEvidence.classify(sourceHasNoAlternates: false,
            groupLoaded: true, groupPresent: false), .sourceAlternates)
        let url = URL(string: "https://fixture.invalid/master.m3u8")!
        XCTAssertFalse(NativeHLSVisualSelectionEvidence.sourceHasNoAlternates(in:
            HLSManifestGraph(rootURL: url, documents: [:], aliases: [:])))
        for alternate in ["#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"angles\",NAME=\"main\",URI=\"angle.m3u8\"\n",
                          "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"angles\",NAME=\"main\"\n"] {
            let graph = try HLSManifestGraph.parse(data: Data(("#EXTM3U\n" + alternate +
                "#EXT-X-STREAM-INF:BANDWIDTH=100000\nmedia.m3u8\n").utf8), responseURL: url)
            XCTAssertFalse(NativeHLSVisualSelectionEvidence.sourceHasNoAlternates(in: graph))
        }
        for reference in ["", ",VIDEO=\"angles\""] {
            let graph = try HLSManifestGraph.parse(data: Data(("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000" +
                reference + "\nmedia.m3u8\n").utf8), responseURL: url)
            XCTAssertEqual(NativeHLSVisualSelectionEvidence.sourceHasNoAlternates(in: graph), reference.isEmpty)
            let iframe = try HLSManifestGraph.parse(data: Data(("#EXTM3U\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"iframe.m3u8\"" +
                reference + "\n").utf8), responseURL: url)
            XCTAssertEqual(NativeHLSVisualSelectionEvidence.sourceHasNoAlternates(in: iframe), reference.isEmpty)
        }
    }

    func testNativeSmokeFailureReportSurvivesXCResultFieldLimit() {
        let oversized = String(repeating: "x", count: 8_192)
        for managed in [false, true] {
            let message = NativeSmokeFailureReport.message(phase: "full-eof-completion", managed: managed,
                reason: "deadline", context: "replacement-recovery " + oversized,
                detail: "original-output=1 " + oversized, trace: oversized + "latest-inspection")
            let reported = String(("failed - " + message).prefix(4_096))
            XCTAssertEqual(reported, "failed - " + message, "CI must retain the entire bounded failure record")
            XCTAssertTrue(reported.contains("phase=full-eof-completion route=\(managed ? "managed" : "native")"))
            XCTAssertTrue(reported.contains("context={replacement-recovery"))
            XCTAssertTrue(reported.contains("detail={original-output=1"))
            XCTAssertTrue(reported.hasSuffix("latest-inspection}"))
        }
    }

    func testNativeEOFPredicateDiagnosticFitsOriginalFailureAndUIBounds() {
        XCTAssertLessThanOrEqual(MemoryLayout<AVPlayerNaturalEndFailureDiagnostic?>.stride, 256)
        let widest = ExactMediaTime(value: .min, timescale: .max)
        let diagnostic = AVPlayerNaturalEndFailureDiagnostic(predicate: .confirmQuantum, quantumFailure: .videoAssetIdentity,
            sdkIdentity: .init(equalFields: 0, visualSelection: .sourceAlternates),
            first: widest, stable: widest, expected: widest, effective: widest, quantum: widest)
        let summary = diagnostic.summary
        XCTAssertLessThanOrEqual(summary.utf8.count, 288)
        XCTAssertTrue(summary.hasSuffix(" q=\(widest.value)/\(widest.timescale)"), "Every clock scalar must fit without truncation")
        XCTAssertTrue(summary.contains(" i=0/3"), "The original failed wrapper read must retain actual asset inequality too")
        let retained = "stage=naturalEnd.rejected reason=network detail={endpoint-reason=endpointMismatch \(summary)}"
        XCTAssertLessThanOrEqual(retained.utf8.count, 384)
        let message = "original-output=\(UInt64.max) original-activation=\(UInt64.max) original-failure={\(retained)} " + String(repeating: "x", count: 2_048)
        XCTAssertTrue(String(message.prefix(1_024)).contains(retained))
        let sdkReport = NativeSmokeFailureReport.message(phase: "full-eof-completion", managed: true, reason: "deadline",
            context: String(repeating: "c", count: 512), detail: message, trace: "")
        let sdkVisible = String(("failed - " + sdkReport).prefix(1_024))
        XCTAssertTrue(sdkVisible.contains("predicate=confirm.quantum.videoAssetIdentity i=0/3"))
        let stale = AVPlayerNaturalEndFailureDiagnostic(predicate: .confirmQuantum, quantumFailure: .revision,
            revision: .init(expected: .max, current: .max, exhausted: true, reason: .privateEOSRefresh),
            binding: .init(presence: 3, equalFields: 511, visualSelections: 15),
            first: widest, stable: widest, expected: widest, effective: widest, quantum: widest)
        XCTAssertTrue(stale.summary.contains("predicate=confirm.quantum.revision"))
        XCTAssertTrue(stale.summary.contains(" r=\(UInt64.max)/\(UInt64.max) why=privateEOSRefresh x=1"))
        XCTAssertTrue(stale.summary.hasSuffix(" q=\(widest.value)/\(widest.timescale)"))
        let staleRetained = "stage=naturalEnd.rejected reason=network detail={endpoint-reason=endpointMismatch \(stale.summary)}"
        XCTAssertLessThanOrEqual(staleRetained.utf8.count, 384)
        let staleMessage = "original-output=\(UInt64.max) original-activation=\(UInt64.max) original-failure={\(staleRetained)} " + String(repeating: "x", count: 2_048)
        XCTAssertTrue(String(staleMessage.prefix(1_024)).contains(staleRetained))
        let report = NativeSmokeFailureReport.message(phase: "full-eof-completion", managed: false, reason: "deadline",
            context: String(repeating: "c", count: 512), detail: staleMessage, trace: String(repeating: "t", count: 1_536))
        let visible = String(("failed - " + report).prefix(1_024))
        XCTAssertTrue(visible.contains("predicate=confirm.quantum.revision"))
        XCTAssertTrue(visible.contains(" r=\(UInt64.max)/\(UInt64.max) why=privateEOSRefresh x=1"))
        XCTAssertTrue(visible.contains(" b=3/511/15"))
        let install = AVPlayerNaturalEndFailureDiagnostic(predicate: .refreshQuantum, quantumFailure: .revision,
            revision: .init(expected: .max, current: .max, exhausted: false, reason: .privateEOSRefresh),
            first: widest, stable: nil, expected: widest, effective: widest, quantum: widest)
        let installRetained = "stage=selection.refresh reason=unsupportedMedia detail={step=quantum-install attempts=3 error=revisionSuperseded \(install.summary)}"
        XCTAssertLessThanOrEqual(installRetained.utf8.count, 384)
        XCTAssertTrue(installRetained.hasSuffix(" q=\(widest.value)/\(widest.timescale)}"))
        let installReport = NativeSmokeFailureReport.message(phase: "full-eof-completion", managed: true, reason: "deadline",
            context: String(repeating: "c", count: 512),
            detail: "original-output=\(UInt64.max) original-activation=\(UInt64.max) original-failure={\(installRetained)}", trace: "")
        let installVisible = String(("failed - " + installReport).prefix(1_024))
        XCTAssertTrue(installVisible.contains("step=quantum-install attempts=3 error=revisionSuperseded"))
        XCTAssertTrue(installVisible.contains("predicate=refresh.quantum.revision r=\(UInt64.max)/\(UInt64.max) why=privateEOSRefresh"))
        let absent = AVPlayerNaturalEndFailureDiagnostic(predicate: .confirmFinalClock, quantumFailure: nil)
        XCTAssertTrue(absent.summary.hasSuffix(" q=none"))
    }

    func testNativeInterruptedResponseDoesNotCompleteDuringBoundedObservation() async throws {
        let bytes = try fixtureBytes()
        let result = try await runEndpointControl(.defaultEnd, bytes: bytes, disconnectAfterBodyBytes: min(32 * 188, bytes.count / 2))
        XCTAssertGreaterThan(result.interruptedBodies, 0, "The origin must actually send a prefix and close its connection")
        XCTAssertFalse(result.endedNormally, "An interrupted response must not become normal EOF during this observation")
        if result.errorDomain == "control.deadline" {
            // tvOS can keep retrying without reaching ready or an SDK error.
            // This is bounded pre-ready non-completion, not a transport-failure
            // or native-driver terminal proof. The paused early-EOF test below
            // separately checks authority-backed premature-end rejection.
            XCTAssertFalse(result.sdkFailed)
            XCTAssertEqual(result.stageBeforeCleanup, "ready")
            XCTAssertEqual(result.statusBeforeCleanup, AVPlayerItem.Status.unknown.rawValue)
            XCTAssertFalse(result.progressed)
        } else {
            XCTAssertTrue(result.sdkFailed, "An earlier terminal result must be an independently observed SDK failure")
        }
    }

    func testNativeTruncationControlKeepsFirstFailureOwnership() {
        let timeoutFirst = NativeEndpointControlSignal()
        timeoutFirst.fail(domain: "control.deadline", code: 0)
        timeoutFirst.fail(domain: "AVFoundationErrorDomain", code: -11800, sdk: true)
        XCTAssertFalse(timeoutFirst.sdkFailed)
        XCTAssertEqual(timeoutFirst.snapshot?.0, "control.deadline")
        let sdkFirst = NativeEndpointControlSignal()
        sdkFirst.fail(domain: "CoreMediaErrorDomain", code: -12865, sdk: true)
        sdkFirst.fail(domain: "control.deadline", code: 0)
        XCTAssertTrue(sdkFirst.sdkFailed)
        XCTAssertEqual(sdkFirst.snapshot?.0, "CoreMediaErrorDomain")
    }

    func testEndpointControlSnapshotKeepsPreCleanupStageAndCounters() {
        let state = NativeEndpointControlState(initialStatus: AVPlayerItem.Status.unknown.rawValue)
        state.stage = "preroll-1"
        state.captureBeforeCleanup(status: AVPlayerItem.Status.readyToPlay.rawValue, interruptedBodies: 2)
        state.stage = "play"
        XCTAssertEqual(state.beforeCleanup.stage, "preroll-1")
        XCTAssertEqual(state.beforeCleanup.status, AVPlayerItem.Status.readyToPlay.rawValue)
        XCTAssertEqual(state.beforeCleanup.interruptedBodies, 2)
    }

    func testNativeEOFDeadlineRejectsExpiredAdmissionAndJoinsHeldBody() async throws {
        var expiredBodyEntered = false
        do {
            try await withController(deadline: .now - .seconds(1)) { _, _, _ in expiredBodyEntered = true }
            XCTFail("An expired shared deadline must reject body admission")
        } catch HLSSourceError.deadline {} catch is CancellationError {}
        XCTAssertFalse(expiredBodyEntered)

        var entered = false, joined = false, admittedAfterExpiry = false
        do {
            try await withController(deadline: .now + .seconds(1)) { controller, registry, factory in
                entered = true
                defer { joined = true }
                // Model a held pre-admission await which returns on cancellation
                // and deliberately continues to the real controller entry.
                do { try await Task.sleep(for: .seconds(10)) } catch is CancellationError {}
                XCTAssertTrue(Task.isCancelled)
                await controller.play(.init(sourceProfileID: UUID(), channelID: "expired-native-control",
                    streamURL: URL(string: "http://127.0.0.1:1/expired.m3u8")!, title: "Expired admission control"))
                admittedAfterExpiry = factory.backend != nil || registry.outputResourceContextSnapshot() != nil
            }
            XCTFail("A canceled body cannot turn an expired source window into success")
        } catch is CancellationError {} catch HLSSourceError.deadline {}
        XCTAssertTrue(entered)
        XCTAssertTrue(joined, "The helper must join the original body before returning")
        XCTAssertFalse(admittedAfterExpiry)
    }

    func testNativeEarlyEndNotificationCannotVerifyFullSourceCompletion() async throws {
        let origin = try makeOrigin(bytes: fixtureBytes(), managed: false)
        var failure: (any Error)?
        do {
            try await withController { [self] controller, registry, factory in
                await controller.play(.init(sourceProfileID: UUID(), channelID: "native-early-eof",
                    streamURL: origin.url("master.m3u8"), title: "Native early end control"))
                try await until(registry: registry, factory: factory, phase: "early-eof-startup", managed: false) {
                    guard case .playing = registry.playbackStateSnapshot(),
                          let coordinator = factory.backend?.nativeCoordinatorForTesting,
                          coordinator.isPrepared, let activation = coordinator.currentActivation else { return false }
                    return activation == registry.outputResourceContextSnapshot()?.activation
                }
                let backend = try XCTUnwrap(factory.backend)
                let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                let player = try XCTUnwrap(backend.presentation?.avPlayerForNativeSmoke)
                let physical = try XCTUnwrap(player.currentItem)
                let driver = try XCTUnwrap(backend.nativeSystemDriverForTesting)
                let snapshot = try await SystemNativeHLSAssetInspector(driver: driver).snapshot(item: coordinator.item, source: coordinator.owned)
                XCTAssertTrue(coordinator.owned.facts.media.compactMap(\.video).allSatisfy {
                    $0.explicitSequenceFrameRate == MediaRational(num: 30, den: 1)
                })
                let quantum = try XCTUnwrap(snapshot.finalPresentationQuantum)
                XCTAssertTrue(quantum.isCurrent(item: coordinator.item, physical: physical))
                let videoTrack = try XCTUnwrap(physical.tracks.first { $0.isEnabled && $0.assetTrack?.mediaType == .video })
                videoTrack.isEnabled = false
                XCTAssertFalse(quantum.isCurrent(item: coordinator.item, physical: physical))
                videoTrack.isEnabled = true
                XCTAssertTrue(quantum.hasCurrentIdentity(item: coordinator.item, physical: physical))
                driver.nativeSelectionRevision.invalidate()
                XCTAssertFalse(quantum.isCurrent(item: coordinator.item, physical: physical),
                    "A revision change revokes timing even when every SDK object is unchanged")
                XCTAssertFalse(coordinator.naturalEndVerifiedForTesting)
                player.pause()
                XCTAssertEqual(player.rate, 0)
                XCTAssertEqual(player.timeControlStatus, .paused)
                let early = try ExactMediaTime(player.currentTime())
                let finalQuantumStart = try quantum.duration.subtracting(quantum.period)
                XCTAssertLessThan(CMTimeCompare(early.cmTime, finalQuantumStart.cmTime), 0)
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: physical)
                try await until(registry: registry, factory: factory, phase: "early-eof-recovery", managed: false) {
                    guard case .playing = registry.playbackStateSnapshot() else { return false }
                    return backend.nativeCoordinatorForTesting !== coordinator &&
                        backend.nativeCoordinatorForTesting?.isPrepared == true &&
                        backend.nativeCoordinatorForTesting?.currentActivation != nil
                }
                XCTAssertFalse(coordinator.naturalEndVerifiedForTesting,
                    "An early notification cannot replace exact endpoint and stable paused-clock proof")
                XCTAssertNil(backend.nativeSystemDriverForTesting?.naturalEndObservation?.stableCurrentTime)
                let successor = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                let successorItem = try XCTUnwrap(player.currentItem)
                XCTAssertFalse(quantum.isCurrent(item: successor.item, physical: successorItem))
                XCTAssertThrowsError(try driver.updateNaturalPlaybackEndQuantum(quantum, item: successor.item),
                    "Old physical item/track evidence must never authorize a successor endpoint")
                XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
            }
        } catch { failure = error }
        await origin.close()
        if let failure { throw failure }
    }

    private func verifyNaturalEOF(managed: Bool, deadline: ContinuousClock.Instant) async throws {
        guard ContinuousClock.now < deadline else { throw HLSSourceError.deadline }
        let origin = try makeOrigin(bytes: fixtureBytes(), managed: managed)
        var failure: (any Error)?
        do {
            try await withController(deadline: deadline) { [self] controller, registry, factory in
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw HLSSourceError.deadline }
                await controller.play(.init(sourceProfileID: UUID(), channelID: "native-natural-eof-\(managed)",
                    streamURL: origin.url("master.m3u8"), title: "Native full-source EOF",
                    attributes: managed ? ["Authorization": "ordinary fixture"] : [:]))
                try await until(registry: registry, factory: factory, phase: "full-eof-startup", managed: managed,
                    deadline: min(deadline, .now + .seconds(20))) {
                    guard case .playing = registry.playbackStateSnapshot(),
                          let coordinator = factory.backend?.nativeCoordinatorForTesting,
                          coordinator.isPrepared, let activation = coordinator.currentActivation else { return false }
                    return activation == registry.outputResourceContextSnapshot()?.activation
                }
                let backend = try XCTUnwrap(factory.backend)
                let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                let driver = try XCTUnwrap(backend.nativeSystemDriverForTesting)
                let player = try XCTUnwrap(backend.presentation?.avPlayerForNativeSmoke)
                let physical = try XCTUnwrap(player.currentItem)
                let activation = try XCTUnwrap(coordinator.currentActivation)
                let endpoint = try ExactMediaTime(physical.duration)
                let snapshot = try await SystemNativeHLSAssetInspector(driver: driver).snapshot(item: coordinator.item, source: coordinator.owned)
                XCTAssertTrue(coordinator.owned.facts.media.compactMap(\.video).allSatisfy {
                    $0.explicitSequenceFrameRate == MediaRational(num: 30, den: 1)
                })
                let quantum = try XCTUnwrap(snapshot.finalPresentationQuantum)
                XCTAssertEqual(quantum.period, ExactMediaTime(value: 1, timescale: 30))
                XCTAssertEqual(endpoint, ExactMediaTime(value: 80, timescale: 1))
                XCTAssertFalse(physical.forwardPlaybackEndTime.isValid)
                XCTAssertNil(driver.naturalEndObservation)
                // One shared source/player deadline includes both startups and
                // both real 80-second EOFs, without seeking or changing rate.
                try await until(registry: registry, factory: factory, phase: "full-eof-completion", managed: managed,
                    deadline: deadline, detail: {
                        self.naturalEOFEvidence(coordinator: coordinator, activation: activation, backend: backend,
                            driver: driver, player: player, physical: physical)
                    }) {
                    coordinator.naturalEndVerifiedForTesting && driver.naturalEndObservation?.stableCurrentTime != nil
                }
                let observation = try XCTUnwrap(driver.naturalEndObservation)
                let stable = try XCTUnwrap(observation.stableCurrentTime)
                XCTAssertEqual(observation.item, coordinator.item)
                XCTAssertEqual(observation.expectedEndpoint, endpoint)
                XCTAssertEqual(observation.constrainedEndpoint, endpoint)
                XCTAssertEqual(observation.firstCurrentTime, stable)
                let lower = try endpoint.subtracting(quantum.period)
                XCTAssertGreaterThan(CMTimeCompare(stable.cmTime, lower.cmTime), 0)
                XCTAssertLessThanOrEqual(CMTimeCompare(stable.cmTime, endpoint.cmTime), 0)
                XCTAssertTrue(player.currentItem === physical)
                XCTAssertEqual(player.rate, 0)
                XCTAssertEqual(player.timeControlStatus, .paused)
                XCTAssertFalse(physical.forwardPlaybackEndTime.isValid)
                XCTAssertTrue(coordinator.isPrepared)
                XCTAssertEqual(coordinator.currentActivation, activation)
                XCTAssertEqual(registry.outputResourceContextSnapshot()?.activation, activation)
                XCTAssertEqual(backend.routedTransportForTesting, managed ? .proxy : .native)
                XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
                XCTAssertEqual(origin.deniedCount, 0)
                // EOF does not mint physical quiescence: withController still
                // performs the original owned stop/disconnect/retirement below.
                XCTAssertFalse(driver.disconnectedFromSystemAudio)
                print("NATIVE_HLS_FULL_SOURCE_EOF managed=\(managed) verified=true end=\(stable.value)/\(stable.timescale)")
            }
        } catch { failure = error }
        await origin.close()
        if let failure { throw failure }
    }

    func testRealAVPlayerNativeAndManagedHLSPrepareSelectedTracksAndProgressWithoutGeneratedGraph() async throws {
        // Native admission requires explicit source color. The task22 fixture
        // intentionally omits it; this committed lavfi fixture signals BT.709.
        let bytes = try fixtureBytes()
        for managed in [false, true] {
            let origin = try makeOrigin(bytes: bytes, managed: managed)
            var failure: (any Error)?
            do {
                try await withController { [self] controller, registry, factory in
                    let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "native-real-\(managed)",
                        streamURL: origin.url("master.m3u8"), title: "Native real fixture",
                        attributes: managed ? ["Authorization": "ordinary fixture"] : [:])
                    await controller.play(request)
                    try await until(registry: registry, factory: factory, phase: "selected-format-startup", managed: managed) {
                        guard case .playing = registry.playbackStateSnapshot(),
                              registry.outputResourceContextSnapshot()?.prepared == true,
                              registry.outputResourceContextSnapshot()?.interval != nil,
                              let backend = factory.backend, let player = backend.presentation?.avPlayerForNativeSmoke,
                              let coordinator = backend.nativeCoordinatorForTesting, coordinator.isPrepared,
                              let activation = coordinator.currentActivation,
                              activation == registry.outputResourceContextSnapshot()?.activation else { return false }
                        return player.currentItem?.status == .readyToPlay && player.rate > 0
                    }
                    let backend = try XCTUnwrap(factory.backend)
                    XCTAssertEqual(backend.routedTransportForTesting, managed ? .proxy : .native)
                    XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
                    let player = try XCTUnwrap(backend.presentation?.avPlayerForNativeSmoke)
                    let physical = try XCTUnwrap(player.currentItem)
                    XCTAssertFalse(physical.forwardPlaybackEndTime.isValid)
                    let started = player.currentTime().seconds
                    guard started.isFinite else { throw HLSSourceError.incompleteEvidence }
                    let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                    factory.trace.record("prepared-checkpoint prepared=\(coordinator.isPrepared) " +
                        "activation=\(String(describing: coordinator.currentActivation))")
                    XCTAssertTrue(coordinator.isPrepared)
                    XCTAssertEqual(coordinator.currentActivation, registry.outputResourceContextSnapshot()?.activation)
                    let source = coordinator.owned
                    XCTAssertTrue(source.facts.complete)
                    XCTAssertEqual(source.facts.media.first?.video?.frameRate, MediaRational(num: 30, den: 1))
                    XCTAssertEqual(source.facts.media.first?.video?.colorTransfer, .bt709)
                    let selected = try await SystemNativeHLSAssetInspector(driver: XCTUnwrap(playerDriver(backend))).snapshot(item: coordinator.item, source: source)
                    XCTAssertNotNil(selected.video)
                    XCTAssertEqual(selected.audio?.codec, .aac)
                    try await until(registry: registry, factory: factory, phase: "selected-format-progress", managed: managed) {
                        player.currentItem === physical && player.currentTime().seconds > started + 0.25
                    }
                    guard player.currentItem === physical, player.currentTime().seconds > started + 0.25,
                          coordinator.isPrepared, coordinator.currentActivation != nil,
                          coordinator.currentActivation == registry.outputResourceContextSnapshot()?.activation,
                          backend.generatedBundleCallsForTesting == 0,
                          backend.routedTransportForTesting == (managed ? .proxy : .native),
                          selected.video != nil, selected.audio?.codec == .aac, selected.audio?.channelCount == 2,
                          source.facts.complete, source.facts.media.first?.video?.frameRate == MediaRational(num: 30, den: 1),
                          source.facts.media.first?.video?.colorTransfer == .bt709, origin.deniedCount == 0 else { throw HLSSourceError.incompleteEvidence }
                    XCTAssertEqual(origin.deniedCount, 0)
                    print("NATIVE_HLS_REAL_SELECTED_FORMAT managed=\(managed) video=\(selected.video?.width ?? 0)x\(selected.video?.height ?? 0) audio=AAC progressed=true")
                }
            } catch { failure = error }
            await origin.close()
            if let failure { throw failure }
        }
    }

    private func fixtureBytes() throws -> Data {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "homepod-live-h264-aac-80s", withExtension: "ts", subdirectory: "Video"))
        return try Data(contentsOf: file)
    }
    private func makeOrigin(bytes: Data, managed: Bool, disconnectAfterBodyBytes: Int? = nil) throws -> NativeHLSHTTPFixture {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nmedia.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\nmedia.m3u8\n"
        let media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:80\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:80,\npart.ts\n#EXT-X-ENDLIST\n"
        return try NativeHLSHTTPFixture(resources: [
            "/master.m3u8": .init(data: Data(master.utf8), contentType: "application/vnd.apple.mpegurl"),
            "/media.m3u8": .init(data: Data(media.utf8), contentType: "application/vnd.apple.mpegurl"),
            "/part.ts": .init(data: bytes, contentType: "video/mp2t", disconnectAfterBodyBytes: disconnectAfterBodyBytes)], credential: managed ? "ordinary fixture" : nil)
    }
    private func runEndpointControl(_ boundary: NativeEndpointControl, bytes: Data, disconnectAfterBodyBytes: Int? = nil) async throws
        -> (progressed: Bool, errorDomain: String?, errorCode: Int?, endedNormally: Bool, sdkFailed: Bool,
            interruptedBodies: Int, statusBeforeCleanup: Int, stageBeforeCleanup: String) {
        let origin = try makeOrigin(bytes: bytes, managed: false, disconnectAfterBodyBytes: disconnectAfterBodyBytes)
        let player = AVPlayer()
        let item = AVPlayerItem(url: origin.url("master.m3u8"))
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.automaticallyWaitsToMinimizeStalling = true
        let signal = NativeEndpointControlSignal()
        let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: nil) { notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                signal.fail(domain: error?.domain ?? "none", code: error?.code ?? 0, sdk: true)
            }
        let endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: nil) { _ in signal.didEnd() }
        let state = NativeEndpointControlState(initialStatus: item.status.rawValue)
        var progressed = false
        let timeout = Task { @MainActor [weak player] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            state.captureBeforeCleanup(status: item.status.rawValue, interruptedBodies: origin.completedInterruptedBodies)
            signal.fail(domain: "control.deadline", code: 0)
            player?.cancelPendingPrerolls()
            player?.currentItem?.asset.cancelLoading()
        }
        do {
            player.replaceCurrentItem(with: item)
            while item.status != .readyToPlay {
                if item.status == .failed || signal.hasFailure { throw HLSSourceError.incompleteEvidence }
                try await Task.sleep(for: .milliseconds(10))
            }
            let loadedDuration = try await item.asset.load(.duration)
            try Task.checkCancellation()
            guard !signal.hasFailure else { throw HLSSourceError.deadline }
            let duration = try ExactMediaTime(loadedDuration)
            guard duration.value > 0 else { throw HLSSourceError.incompleteEvidence }
            for index in 0..<2 {
                try Task.checkCancellation()
                guard !signal.hasFailure else { throw HLSSourceError.deadline }
                // Keep both prerolls from the real adapter. Only the placement
                // of the same observed endpoint differs between controls.
                if index == 1, boundary == .beforePreroll { item.forwardPlaybackEndTime = duration.cmTime }
                state.stage = "preroll-\(index)"
                let primed = await withCheckedContinuation { continuation in
                    player.preroll(atRate: 1) { continuation.resume(returning: $0) }
                }
                guard primed, !signal.hasFailure else { throw HLSSourceError.incompleteEvidence }
            }
            try Task.checkCancellation()
            guard !signal.hasFailure else { throw HLSSourceError.deadline }
            state.stage = "endpoint"
            if boundary == .afterPreroll { item.forwardPlaybackEndTime = duration.cmTime }
            state.stage = "play"
            let started = player.currentTime()
            guard started.isNumeric, started.seconds.isFinite else { throw HLSSourceError.incompleteEvidence }
            player.play()
            while !signal.hasFailure {
                if item.status == .failed {
                    let error = item.error as NSError?
                    signal.fail(domain: error?.domain ?? "AVPlayerItem.failed", code: error?.code ?? 0, sdk: true)
                    break
                }
                let current = player.currentTime()
                if current.isNumeric, current.seconds.isFinite, current.seconds > started.seconds + 0.25 {
                    progressed = true
                    if disconnectAfterBodyBytes == nil { break }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if !signal.hasFailure {
                if let sdkError = item.error as NSError? { signal.fail(domain: sdkError.domain, code: sdkError.code, sdk: true) }
                else { signal.fail(domain: String(reflecting: type(of: error)), code: (error as NSError).code) }
            }
        }
        let failure = signal.snapshot
        if failure?.0 != "control.deadline" {
            state.captureBeforeCleanup(status: item.status.rawValue, interruptedBodies: origin.completedInterruptedBodies)
        }
        // Only the first recorded signal owns classification. A deadline first
        // cancels SDK work, whose resulting item.error is not transport evidence.
        let sdkFailed = signal.sdkFailed
        let current = item.currentTime(), end = item.forwardPlaybackEndTime
        print("NATIVE_HLS_ENDPOINT_CONTROL diagnostic-only=true boundary=\(boundary.rawValue) stage=\(state.stage) progressed=\(progressed) " +
            "failure-domain=\(failure?.0 ?? "none") failure-code=\(failure?.1 ?? 0) status=\(item.status.rawValue) " +
            "current=\(current.value)/\(current.timescale):\(current.flags.rawValue) end=\(end.value)/\(end.timescale):\(end.flags.rawValue) " +
            "interrupted-bodies=\(state.beforeCleanup.interruptedBodies) status-before-cleanup=\(state.beforeCleanup.status) stage-before-cleanup=\(state.beforeCleanup.stage)")
        timeout.cancel(); await timeout.value
        player.cancelPendingPrerolls(); player.pause()
        await withCheckedContinuation { continuation in player.setDisconnectedFromSystemAudio(true) { continuation.resume() } }
        player.replaceCurrentItem(with: nil)
        NotificationCenter.default.removeObserver(observer)
        NotificationCenter.default.removeObserver(endObserver)
        let endedNormally = signal.endedNormally
        signal.close()
        await origin.close()
        return (progressed, failure?.0, failure?.1, endedNormally, sdkFailed,
            state.beforeCleanup.interruptedBodies, state.beforeCleanup.status, state.beforeCleanup.stage)
    }

    private func playerDriver(_ backend: HLSAVPlayerPlaybackBackend) -> SystemAVPlayerDriver? { backend.nativeSystemDriverForTesting }
    private func naturalEOFEvidence(coordinator: NativeHLSItemCoordinator, activation: ActivationEpoch,
        backend: HLSAVPlayerPlaybackBackend, driver: SystemAVPlayerDriver, player: AVPlayer, physical: AVPlayerItem) -> String {
        func time(_ value: CMTime) -> String { "\(value.value)/\(value.timescale):\(value.epoch):\(value.flags.rawValue)" }
        let error = physical.error as NSError?
        let terminal: String
        switch driver.naturalEndTerminalResult {
        case .success?: terminal = "success"
        case let .failure(reason)?: terminal = "failure-\(reason)"
        case nil: terminal = "none"
        }
        return "original-output=\(coordinator.item.outputLifecycleEpoch.outputNonce) original-activation=\(activation.activationNonce) " +
            "original-failure={\(coordinator.firstFailureDiagnosticForTesting ?? "none")} " +
            "same-coordinator=\(backend.nativeCoordinatorForTesting === coordinator) same-physical=\(player.currentItem === physical) " +
            "original-prepared=\(coordinator.isPrepared) original-verified=\(coordinator.naturalEndVerifiedForTesting) " +
            "original-current=\(time(physical.currentTime())) original-duration=\(time(physical.duration)) " +
            "original-status=\(physical.status.rawValue) error-domain=\(String((error?.domain ?? "none").prefix(96))) error-code=\(error?.code ?? 0) " +
            "player-rate=\(player.rate) player-control=\(player.timeControlStatus.rawValue) " +
            "driver-output=\(driver.currentItemIdentity?.outputLifecycleEpoch.outputNonce ?? 0) driver-terminal=\(terminal) " +
            "driver-first=\(driver.naturalEndObservation.map { time($0.firstCurrentTime.cmTime) } ?? "none") " +
            "driver-stable=\(driver.naturalEndObservation?.stableCurrentTime.map { time($0.cmTime) } ?? "none")"
    }
    private func until(registry: ControlTaskRegistry, factory: NativeSmokeFactory, phase: StaticString, managed: Bool,
        deadline: ContinuousClock.Instant = .now + .seconds(20), detail: @MainActor () -> String = { "none" },
        file: StaticString = #filePath, line: UInt = #line, _ predicate: @MainActor () -> Bool) async throws {
        func report(_ reason: String) {
            // The xcresult reporter caps failureText at 4096 characters. Keep
            // the route/phase and original-item evidence ahead of bounded trace
            // text; reflecting the entire Registry context hides these fields.
            let context: String
            if let value = registry.outputResourceContextSnapshot() {
                let origin: String
                switch value.claimOrigin {
                case .initial: origin = "initial"
                case let .replacement(ticket): origin = "replacement-\(ticket.reason)"
                }
                context = "phase=\(value.phase) origin=\(origin) prepared=\(value.prepared) poisoned=\(value.poisoned) " +
                    "backend=\(String(describing: value.desiredBackendKind)) object=\(value.backendObjectNonce) " +
                    "output=\(value.activation?.outputLifecycleEpoch.outputNonce ?? 0) activation=\(value.activation?.activationNonce ?? 0)"
            } else { context = "none" }
            XCTFail(NativeSmokeFailureReport.message(phase: String(describing: phase), managed: managed,
                reason: reason, context: context, detail: detail(), trace: factory.trace.summary), file: file, line: line)
        }
        while !predicate(), ContinuousClock.now < deadline {
            if case let .failed(failure) = registry.playbackStateSnapshot() {
                report("terminal-\(failure.code)")
                throw failure
            }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch is CancellationError {
                report("cancelled deadline-expired=\(ContinuousClock.now >= deadline)")
                throw CancellationError()
            }
        }
        guard predicate(), ContinuousClock.now < deadline else {
            report("deadline")
            throw HLSSourceError.deadline
        }
    }
    private func withController(deadline: ContinuousClock.Instant? = nil, driver: SystemAVPlayerDriver? = nil, publicMIMEQueries: Bool = false,
        _ body: @escaping @MainActor (PlaybackController, ControlTaskRegistry, NativeSmokeFactory) async throws -> Void) async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress, notificationCenter: NotificationCenter())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk, monitor: monitor)
        let trace = NativeSmokeTrace()
        let factory = NativeSmokeFactory(trace: trace, driver: driver, publicMIMEQueries: publicMIMEQueries)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: PlaybackAudioRouteService(registry: registry, owner: owner), backendFactory: factory)
        let bodyTask = Task { @MainActor in
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw HLSSourceError.deadline }
            try await body(controller, registry, factory)
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw HLSSourceError.deadline }
        }
        let expiry: Task<Void, Never>?
        if let deadline {
            expiry = Task {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                // Cancel the original task even when play has not yet published
                // a request/reservation and stop would therefore be a no-op.
                bodyTask.cancel()
                await controller.stop()
                _ = await bodyTask.result
            }
        } else { expiry = nil }
        var failure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: { bodyTask.cancel() }
        } catch {
            print("NATIVE_HLS_SMOKE_TRACE error=\(error)\n\(trace.summary)")
            failure = error
        }
        expiry?.cancel(); await expiry?.value
        await controller.stop(); await registry.joinOwnedTerminalCleanup()
        XCTAssertNil(registry.outputResourceContextSnapshot())
        if let failure { throw failure }
    }
}

private enum NativeSmokeFailureReport {
    static func message(phase: String, managed: Bool, reason: String, context: String, detail: String, trace: String) -> String {
        "NATIVE_HLS_SMOKE_FAILURE phase=\(phase.prefix(48)) route=\(managed ? "managed" : "native") reason=\(reason.prefix(128)) " +
            "context={\(context.prefix(512))} detail={\(detail.prefix(1_024))} trace={\(trace.suffix(1_536))}"
    }
}

private enum NativeEndpointControl: String, CaseIterable {
    case defaultEnd, beforePreroll, afterPreroll
}

private enum NativeEOSSettlementOutcome: Equatable {
    case settled, positiveRate, playingControl, changedClock, earlyClock, staleRevision, supersededInstall, cancelled, failedToEnd, progressPoll
}

private enum NativeRefreshReturnMode: Equatable { case once, mixed, exhausted, bindingChanged, revoked }
@MainActor private final class NativeQuantumReceiptHold {
    var receipt: NativeHLSFinalPresentationQuantum?
    var alias: NativeHLSFinalPresentationQuantum?
    weak var weakReceipt: NativeHLSFinalPresentationQuantum?
    weak var track: AVPlayerItemTrack?
    weak var asset: AVAssetTrack?
    var item: AVPlayerItemInstanceIdentity?
}
private enum NativeRefreshReturnScope { @TaskLocal static var identity: UUID? = nil }
@MainActor private final class NativeRefreshReturnControl {
    let identity = UUID()
    var calls = 0
}

private func nativeEOSMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Test-only raw SDK reads; no production endpoint/authority injection.
private final class NativeEOSObservationState: @unchecked Sendable {
    struct Observation: Sendable {
        let time: CMTime
        let rate: Float
        let control: AVPlayer.TimeControlStatus
    }
    private let lock = NSLock()
    private var value: Observation?
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func readTime() -> CMTime? { lock.withLock { reads += 1; return value?.time } }
    var observation: Observation? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class NativeEOSObservationPlayer: AVPlayer, @unchecked Sendable {
    nonisolated private let observations = NativeEOSObservationState()
    var observation: NativeEOSObservationState.Observation? {
        get { observations.observation }
        set { observations.observation = newValue }
    }
    var observationReadCount: Int { observations.readCount }
    override var rate: Float {
        get { observations.observation?.rate ?? super.rate }
        set { super.rate = newValue }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus {
        observations.observation?.control ?? super.timeControlStatus
    }
    nonisolated override func currentTime() -> CMTime {
        observations.readTime() ?? super.currentTime()
    }
    override func pause() { observations.observation = nil; super.pause() }
}

/// Models the existing bounded scheduler's delivery, not an additional timer.
private final class NativeEOSManualDeadlineScheduler: AVPlayerWaitDeadlineScheduling, @unchecked Sendable {
    private struct Entry {
        let identity: UUID
        let delay: TimeInterval
        let callback: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var count: Int { lock.withLock { entries.count } }
    var nextIdentity: UUID? { lock.withLock { entries.first?.identity } }
    var nextDelay: TimeInterval? { lock.withLock { entries.first?.delay } }
    var nextCallback: (@Sendable () -> Void)? { lock.withLock { entries.first?.callback } }
    func schedule(after seconds: TimeInterval, handler: @escaping @Sendable () -> Void) -> UUID? {
        lock.withLock {
            guard entries.count < 4 else { return nil }
            let identity = UUID()
            entries.append(.init(identity: identity, delay: seconds, callback: handler))
            return identity
        }
    }
    func cancel(_ identity: UUID) { lock.withLock { entries.removeAll { $0.identity == identity } } }
    func fireNext() -> Bool {
        let callback = lock.withLock { entries.isEmpty ? nil : entries.removeFirst().callback }
        callback?()
        return callback != nil
    }
}

/// One bounded MainActor owner shared by the helper and its timeout Task.
/// Capturing this immutable reference avoids sharing mutable local capture boxes.
@MainActor
private final class NativeEndpointControlState {
    var stage = "ready"
    private(set) var beforeCleanup: (status: Int, stage: String, interruptedBodies: Int)
    init(initialStatus: Int) { beforeCleanup = (initialStatus, "ready", 0) }
    func captureBeforeCleanup(status: Int, interruptedBodies: Int) {
        beforeCleanup = (status, stage, interruptedBodies)
    }
}

private final class NativeEndpointControlSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (String, Int)?
    private var closed = false
    private var endObserved = false
    private var failureFromSDK = false
    func didEnd() { lock.withLock { if !closed { endObserved = true } } }
    var endedNormally: Bool { lock.withLock { endObserved } }
    func fail(domain: String, code: Int, sdk: Bool = false) {
        lock.withLock { if !closed, failure == nil { failure = (String(domain.prefix(96)), code); failureFromSDK = sdk } }
    }
    var sdkFailed: Bool { lock.withLock { failureFromSDK } }
    var hasFailure: Bool { lock.withLock { failure != nil } }
    var snapshot: (String, Int)? { lock.withLock { failure } }
    func close() { lock.withLock { closed = true } }
}

private extension PlaybackPresentation {
    var avPlayerForNativeSmoke: AVPlayer? {
        if case let .avPlayer(context) = self { return context.player }
        return nil
    }
}

private final class NativeSmokeFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let lock = NSLock()
    private weak var result: HLSAVPlayerPlaybackBackend?
    let trace: NativeSmokeTrace
    var backend: HLSAVPlayerPlaybackBackend? { lock.withLock { result } }
    // Explicit test envelope permits the public committed 320×180/30 fixture on a
    // simulator. It supplies no source facts and changes no production policy.
    private let factory: SystemPlaybackBackendFactory
    private let sourceDependencies: @Sendable (PlaybackSourceContext) -> HLSNativeSourceDependencies
    private let driver: SystemAVPlayerDriver?
    init(trace: NativeSmokeTrace, driver: SystemAVPlayerDriver? = nil, publicMIMEQueries: Bool = false) {
        self.trace = trace
        self.driver = driver
        let dependencies: @Sendable (PlaybackSourceContext) -> HLSNativeSourceDependencies = { context in
            var dependencies = HLSNativeSourceDependencies(context: context)
            dependencies.makeInspector = { driver in
                guard let system = driver as? SystemAVPlayerDriver else { throw HLSSourceError.incompleteEvidence }
                return NativeSmokeTracingInspector(driver: system, trace: trace)
            }
            dependencies.capabilities = { facts, route in
                if publicMIMEQueries {
                    // The simulator's hardware identity is deliberately outside
                    // production admission. Inject only that envelope; use the
                    // production capability builder and actual SDK MIME answers.
                    return NativeHLSCapabilities.make(facts: facts, route: route,
                        evidence: .init(model: "AppleTV14,1", hardwareH264: true, hardwareHEVC: true,
                            hdrEligible: true, playable: { AVURLAsset.isPlayableExtendedMIMEType($0) }))
                }
                return .init(videoFormats: [.init(codec: .h264, profiles: [66, 77, 100], maximumLevel: 52,
                    maximumWidth: 1_920, maximumHeight: 1_080, maximumFrameRate: MediaRational(num: 60, den: 1)!,
                    bitDepths: [8], chromaFormats: [1], tiers: [.main], videoRanges: [.sdr])], nativeAudioCodecs: [.aac],
                    supportsWebVTT: true, supportsGenerated: false, supportsInBandClosedCaptions: true)
            }
            return dependencies
        }
        sourceDependencies = dependencies
        factory = SystemPlaybackBackendFactory(sourceDependencies: dependencies)
    }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        throw HLSSourceError.unboundOwner
    }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        let value: any PlaybackBackend
        if let driver {
            let context = try XCTUnwrap(sourceContext)
            let lease = try await MainActor.run {
                try HomePodAVPlayerSession(identity: identity.sessionIdentity, driver: driver,
                    presentation: AVPlayerPresentationContext(player: driver.player)).claim(backend: identity)
            }
            let backend = HLSAVPlayerPlaybackBackend(identity: identity,
                bundleBuilder: try SystemHLSOutputItemBundleBuilder(validating: url),
                presentationContext: await lease.presentation,
                coordinatorFactory: { _ in throw HLSSourceError.unsupportedMedia },
                replacementSlot: ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot())
            backend.configureSourceRouting(dependencies: sourceDependencies(context), sessionLease: lease,
                builderFactory: { _, _ in throw HLSSourceError.unsupportedMedia }, eventSink: eventSink)
            value = backend
        } else {
            value = try await factory.makeBackend(kind: kind, identity: identity, tuning: tuning, channelID: channelID,
                url: url, sourceContext: sourceContext, eventSink: eventSink)
        }
        lock.withLock { result = value as? HLSAVPlayerPlaybackBackend }
        return value
    }
}

/// A bounded test trace only. The forwarding inspector performs the unchanged
/// production inspection, without additional asynchronous reads or minted facts.
private final class NativeSmokeTrace: @unchecked Sendable {
    typealias SnapshotReturnHook = @MainActor (NativeHLSSelectionSnapshot, HLSOwnedSourcePlan, SystemAVPlayerDriver) throws -> NativeHLSSelectionSnapshot
    // Ordinary nil storage keeps this shared trace's synthesized init nonisolated.
    // The hook is only accessed and invoked on MainActor.
    private var snapshotReturnStorage: SnapshotReturnHook?
    @MainActor var snapshotReturn: SnapshotReturnHook? {
        get { snapshotReturnStorage }
        set { snapshotReturnStorage = newValue }
    }
    private let lock = NSLock()
    private var lines: [String] = []
    private var revision: UInt64?
    var selectedRevision: UInt64? { lock.withLock { revision } }
    func recordSelectedRevision(_ value: UInt64?) { lock.withLock { revision = value } }
    func record(_ value: String) {
        lock.withLock {
            if lines.count == 16 { lines.removeFirst() }
            lines.append(String(value.prefix(512)))
        }
    }
    var summary: String { lock.withLock { lines.joined(separator: "\n") } }
}

@MainActor
private final class NativeSmokeTracingInspector: NativeHLSAssetInspecting {
    private let driver: SystemAVPlayerDriver
    private let base: SystemNativeHLSAssetInspector
    private let trace: NativeSmokeTrace
    init(driver: SystemAVPlayerDriver, trace: NativeSmokeTrace) {
        self.driver = driver; base = SystemNativeHLSAssetInspector(driver: driver); self.trace = trace
    }
    func snapshot(item: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot {
        record("inspect-start", item: item)
        do {
            let result = try await base.snapshot(item: item, source: source)
            if let physical = driver.nativeCurrentItem(item),
               result.finalPresentationQuantum?.isCurrent(item: item, physical: physical) == true {
                trace.recordSelectedRevision(driver.nativeSelectionRevision.current)
            }
            let duration = result.duration.map { "\($0.value)/\($0.timescale)" } ?? "none"
            record("inspect-success video=\(result.video != nil) audio=\(result.audio != nil) selected-duration=\(duration)", item: item)
            return try trace.snapshotReturn?(result, source, driver) ?? result
        } catch {
            record("inspect-failure \(error)", item: item)
            throw error
        }
    }
    private func record(_ stage: String, item: AVPlayerItemInstanceIdentity) {
        guard let physical = driver.nativeCurrentItem(item) else { trace.record("\(stage) physical-item=nil"); return }
        let enabled = physical.tracks.filter(\.isEnabled)
        let error = physical.error.map { ($0 as NSError).domain + ":" + String(($0 as NSError).code) } ?? "none"
        func time(_ value: CMTime) -> String { "\(value.value)/\(value.timescale) epoch=\(value.epoch) flags=\(value.flags.rawValue)" }
        trace.record("\(stage) output=\(item.outputLifecycleEpoch.outputNonce) item=\(item.itemGeneration) status=\(physical.status.rawValue) error=\(error) " +
            "tracks=\(enabled.count) missing-assets=\(enabled.filter { $0.assetTrack == nil }.count) " +
            "size=\(physical.presentationSize) current=\(time(physical.currentTime())) " +
            "duration=\(time(physical.duration)) end=\(time(physical.forwardPlaybackEndTime))")
    }
}
