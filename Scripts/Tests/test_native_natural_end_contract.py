#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable route/proof wiring checks; actual EOF requires the Apple smoke test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeNaturalEndContract(unittest.TestCase):
    def test_snapshot_and_quantum_install_share_one_stage_specific_retry_budget(self):
        native = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSItemCoordinator.swift').read_text()
        loop = native.split('private func selectionSnapshot(', 1)[1].split('#if DEBUG', 1)[0]
        self.assertEqual(loop.count('for attempt in 0..<3'), 1)
        self.assertEqual(loop.count('guard attempt < 2 else { throw error }'), 2)
        inspector_catch = loop.index('catch let error as AVPlayerItemCoordinatorFailure where error == .selectionChanged')
        commit = loop.index('do { try commit(value) }')
        self.assertLess(inspector_catch, commit)
        self.assertIn('catch let error as NativeHLSQuantumRevisionSuperseded', loop[commit:])
        self.assertNotIn('catch let error as AVPlayerItemCoordinatorFailure', loop[commit:])
        self.assertIn('try validate()\n                guard attempt < 2', loop[commit:])
        driver = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        install = driver.split('func updateNaturalPlaybackEndQuantum(', 1)[1].split('private func installEndpointObservation(', 1)[0]
        ordered = ['case .natural = endpointBoundary', 'currentItemIdentity == identity',
                   'requiresFreshness: false', 'observedDuration == quantum.duration',
                   'quantum.hasSameBinding(as: prior)', 'quantum?.revisionMismatch()',
                   'guard !mismatch.exhausted', 'nativeEndQuantum = quantum']
        self.assertEqual([install.index(value) for value in ordered], sorted(install.index(value) for value in ordered))
        self.assertIn('naturalEndQuantumUpdateFailureDiagnosticForTesting', install)
        self.assertNotIn('naturalEndFailureDiagnosticForTesting =', install)
        smoke = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        self.assertIn('NativeRefreshReturnScope.identity == control.identity', smoke)
        self.assertIn('NativeRefreshReturnScope.$identity.withValue(control.identity)', smoke)
        self.assertIn('XCTAssertEqual(deadlines.nextIdentity, originalDeadline)', smoke)

    def test_only_native_route_preserves_the_untrimmed_sdk_endpoint(self):
        native = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSItemCoordinator.swift').read_text()
        generated = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerItemCoordinator.swift').read_text()
        driver = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        self.assertIn('try driver.observeNaturalPlaybackEnd(expected: endpoint,', native)
        self.assertNotIn('driver.constrainPlaybackEnd(', native)
        self.assertIn('try driver.constrainPlaybackEnd(to: itemEnd, item:', generated)
        self.assertIn('func observeNaturalPlaybackEnd(', driver)
        native_method = driver.split('func observeNaturalPlaybackEnd(', 1)[1].split('private func installEndpointObservation(', 1)[0]
        self.assertNotIn('forwardPlaybackEndTime =', native_method)
        self.assertIn('boundary: .natural', native_method)

    def test_same_endpoint_policy_is_checked_on_both_reads_and_pending_eof(self):
        source = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        self.assertGreaterEqual(source.count('endpointBoundary.observedEndpoint('), 3)
        self.assertIn('prior.firstCurrentTime == stable', source)
        self.assertIn('constraint == prior.expectedEndpoint', source)
        self.assertIn('endpointBoundary.containsFinalClock(stable, expected: prior.expectedEndpoint', source)
        self.assertIn('naturalEndAuthority?.revalidateCurrentAuthority() == true', source)
        self.assertIn('endpointBoundary = .constrained', source)

    def test_native_eos_waits_for_transport_settlement_only_in_original_deadline(self):
        source = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        ingress = source.split('eventHub.installEndpoint(endpoint: time, token: observationIdentity)', 1)[1].split('let hub = eventHub', 1)[0]
        self.assertNotIn('self.player.rate == 0', ingress)
        self.assertNotIn('self.player.timeControlStatus == .paused', ingress)
        for predicate in ['item.status == .readyToPlay', 'item.error == nil',
                          'checkNaturalEndQuantum(item: observedIdentity, physical: item, requiresFreshness: false)']:
            self.assertIn(predicate, ingress)
        self.assertIn('firstCurrentTime: first', ingress)
        self.assertIn('scheduler.schedule(after: 0.1', ingress)
        self.assertIn('guard self.endpointStabilityDeadline == nil else { return }', ingress)
        final_read = source.split('private func completeNaturalEndRead(', 1)[1].split('private func cancelNaturalEndDeadline(', 1)[0]
        predicates = ['item.status == .readyToPlay', 'item.error == nil',
                          'player.rate == 0', 'player.timeControlStatus == .paused',
                          'checkNaturalEndQuantum(item: currentItemIdentity, physical: item, requiresFreshness: true)', 'prior.firstCurrentTime == stable',
                          'constraint == prior.expectedEndpoint',
                          'endpointBoundary.containsFinalClock(',
                          'naturalEndAuthority?.revalidateCurrentAuthority() == true']
        for predicate in predicates:
            self.assertIn(predicate, final_read)
        self.assertEqual([final_read.index(value) for value in predicates[:-1]],
                         sorted(final_read.index(value) for value in predicates[:-1]))
        self.assertNotIn('schedule(', final_read)
        pending = source.split('func hasPendingNaturalEndVerification(item identity:', 1)[1].split('private func completeNaturalEndRead(', 1)[0]
        self.assertIn('player.rate == 0, player.timeControlStatus == .paused', pending)

    def test_smoke_covers_actual_natural_eof_and_retains_active_authority(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        self.assertIn('naturalEndObservation?.stableCurrentTime != nil', source)
        self.assertIn('executionTimeAllowance = 240', source)
        self.assertIn('let deadline = ContinuousClock.now + .seconds(210)', source)
        self.assertIn('verifyNaturalEOF(managed: managed, deadline: deadline)', source)
        completion_wait = source.split('phase: "full-eof-completion", managed: managed,', 1)[1].split('let observation =', 1)[0]
        self.assertIn('deadline: deadline, detail:', completion_wait)
        self.assertIn('coordinator.naturalEndVerifiedForTesting && driver.naturalEndObservation?.stableCurrentTime != nil', completion_wait)
        self.assertIn('guard predicate(), ContinuousClock.now < deadline', source)
        self.assertIn('withController(deadline: deadline)', source)
        self.assertIn('ContinuousClock().sleep(until: deadline)', source)
        self.assertIn('expiry?.cancel(); await expiry?.value', source)
        self.assertIn('XCTAssertFalse(physical.forwardPlaybackEndTime.isValid)', source)
        self.assertIn('activation == registry.outputResourceContextSnapshot()?.activation', source)
        self.assertIn('testNativeEarlyEndNotificationCannotVerifyFullSourceCompletion', source)

    def test_deadline_cancels_and_joins_the_original_body_before_cleanup(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        helper = source.split('private func withController(', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('let bodyTask = Task { @MainActor in', helper)
        expiry = helper.split('expiry = Task {', 1)[1].split('} else { expiry = nil }', 1)[0]
        self.assertLess(expiry.index('bodyTask.cancel()'), expiry.index('await controller.stop()'))
        self.assertIn('await bodyTask.result', expiry)
        admission = source.split('private func verifyNaturalEOF(', 1)[1].split('await controller.play(', 1)[0]
        self.assertGreaterEqual(admission.count('ContinuousClock.now < deadline'), 2)
        self.assertIn('testNativeEOFDeadlineRejectsExpiredAdmissionAndJoinsHeldBody', source)

    def test_escaping_controller_bodies_capture_instance_helpers_explicitly(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        self.assertEqual(source.count('withController { [self] controller, registry, factory in'), 2)
        self.assertIn('withController(deadline: deadline) { [self] controller, registry, factory in', source)

    def test_native_quantum_is_selected_sdk_evidence_not_a_global_epsilon(self):
        inspector = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSAssetInspector.swift').read_text()
        driver = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        self.assertIn('asset.load(.minFrameDuration)', inspector)
        self.assertIn('final class NativeHLSFinalPresentationQuantum', inspector)
        self.assertIn('fileprivate init(', inspector)
        self.assertIn('ObjectIdentifier(physical) == physicalItem', inspector)
        self.assertIn('ObjectIdentifier(track) == videoTrack', inspector)
        self.assertIn('ObjectIdentifier(asset) == videoAsset', inspector)
        self.assertIn('minimum == period', inspector)
        self.assertIn('video.frameRate == rate', inspector)
        self.assertIn('endpointBoundary.containsFinalClock(', driver)
        self.assertIn('nativeEndQuantum?.validationFailure', driver)
        self.assertIn('quantum.hasSameBinding(as: prior)', driver)
        self.assertIn('driver.nativeSelectionRevision.matches(revision)', inspector)
        observer = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSObservation.swift').read_text()
        self.assertLess(observer.index('selectionRevision.invalidate(reason: reason)'), observer.index('pending = true;'))
        second_read = driver.split('private func completeNaturalEndRead(', 1)[1].split('private func cancelNaturalEndDeadline(', 1)[0]
        self.assertIn('checkNaturalEndQuantum(item: currentItemIdentity, physical: item, requiresFreshness: true)', second_read)
        self.assertIn('selectionRevision.installEndRefresh(owner: ObjectIdentifier(self))', observer)
        self.assertIn('selectionRevision.clearEndRefresh(owner: ObjectIdentifier(self))', observer)
        ingress = driver.split('let nativeRevision: NativeHLSSelectionRevision?', 1)[1].split('callbackLease.inspectRegistration()', 1)[0]
        self.assertLess(ingress.index('nativeRevision?.receiveNativeEnd(token: observationIdentity)'), ingress.index('hub?.receiveEndpoint('))
        self.assertIn('guard endpointToken == token else { return nil }', inspector)
        native = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSItemCoordinator.swift').read_text()
        armed_commit = native.split('selectionSnapshot(commit:', 1)[1].split('selected = snapshot', 1)[0]
        self.assertIn('guard alreadyArmed else { return }', armed_commit)
        self.assertIn('updateNaturalPlaybackEndQuantum(snapshot.finalPresentationQuantum', armed_commit)
        smoke = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        self.assertIn('return (progressed, failure?.0', smoke)
        self.assertIn('let sdkFailed = signal.sdkFailed\n', smoke)
        self.assertNotIn('signal.sdkFailed || item.error', smoke)
        self.assertIn('testNativeInterruptedResponseDoesNotCompleteDuringBoundedObservation', smoke)
        self.assertIn('XCTAssertGreaterThan(result.interruptedBodies, 0,', smoke)
        self.assertIn('testNativeTruncationControlKeepsFirstFailureOwnership', smoke)
        self.assertIn('XCTAssertLessThan(CMTimeCompare(early.cmTime, finalQuantumStart.cmTime), 0)', smoke)

    def test_unknown_sdk_timing_needs_selected_fixed_bitstream_evidence(self):
        source = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSAssetInspector.swift').read_text()
        self.assertIn('selectedFixedFrameRate(parameterSets: sets, codec: codec)', source)
        self.assertIn('VideoSequenceParameterSetInspector.sourceFormat', source)
        self.assertIn('guard codec == .h264', source)
        self.assertIn('selectedFixedFrameRate == rate', source)
        self.assertIn('explicitSequenceFrameRate == rate', source)
        self.assertNotIn('configurationFingerprint == video.configurationFingerprint', source)
        facts = (ROOT / 'Sources/VPlayerPlayback/HLS/Source/HLSPlaybackPlan.swift').read_text()
        self.assertIn('explicitSequenceFrameRate: MediaRational? = nil', facts)
        self.assertIn('String(describing: video.explicitSequenceFrameRate)', facts)
        self.assertIn('sdk-minimum-contradiction', source)
        self.assertIn('NATIVE_HLS_QUANTUM', source)
        self.assertIn('minimumFrameDuration?.isValid != true', source)
        self.assertNotIn('minimumFrameDuration?.isNumeric != true', source)

    def test_interrupted_control_requires_observed_delivery_without_inventing_sdk_failure(self):
        smoke = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        fixture = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSHTTPFixture.swift').read_text()
        self.assertIn('XCTAssertGreaterThan(result.interruptedBodies, 0,', smoke)
        self.assertIn('XCTAssertFalse(result.endedNormally', smoke)
        self.assertIn('if result.errorDomain == "control.deadline"', smoke)
        self.assertIn('XCTAssertFalse(result.sdkFailed)', smoke)
        self.assertIn('completedInterruptedBodiesValue', fixture)
        self.assertIn('didCompleteInterruptedBody', fixture)
        timeout = smoke.split('let timeout = Task', 1)[1].split('player?.cancelPendingPrerolls()', 1)[0]
        self.assertIn('state.captureBeforeCleanup(status: item.status.rawValue, interruptedBodies: origin.completedInterruptedBodies)', timeout)

    def test_endpoint_timeout_shares_only_main_actor_reference_state(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        helper = source.split('private func runEndpointControl(', 1)[1].split('private func playerDriver(', 1)[0]
        self.assertIn('let state = NativeEndpointControlState(initialStatus: item.status.rawValue)', helper)
        self.assertNotIn('var stage =', helper)
        self.assertNotIn('var statusBeforeCleanup =', helper)
        self.assertNotIn('var interruptedBodies =', helper)
        self.assertIn('@MainActor\nprivate final class NativeEndpointControlState', source)
        timeout = helper.split('let timeout = Task', 1)[1].split('player?.cancelPendingPrerolls()', 1)[0]
        self.assertIn('@MainActor [weak player]', timeout)
        self.assertIn('Task.sleep(for: .seconds(20))', timeout)
        self.assertLess(timeout.index('state.captureBeforeCleanup('), timeout.index('signal.fail(domain: "control.deadline"'))
        self.assertIn('timeout.cancel(); await timeout.value', helper)
        self.assertIn('testEndpointControlSnapshotKeepsPreCleanupStageAndCounters', source)


if __name__ == '__main__':
    unittest.main()
