#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Diagnostic wiring only; native lifecycle behavior still requires Apple tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSItemCoordinator.swift'
OBSERVATION = ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSObservation.swift'
SMOKE = ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift'
BACKEND = ROOT / 'Sources/VPlayerPlayback/Pipeline/HLSAVPlayerPlaybackBackend.swift'


class NativeHLSLifecycleDiagnosticsTests(unittest.TestCase):
    def test_endpoint_mismatch_retains_exact_predicate_before_original_recovery(self):
        driver = (ROOT / 'Sources/VPlayerPlayback/HLS/AVPlayerDriver.swift').read_text()
        self.assertTrue('private(set) var naturalEndFailureDiagnosticForTesting:' in driver)
        for code in ['ingress.endpoint', 'ingress.notReady', 'ingress.itemError', 'ingress.quantum',
                     'confirm.notReady', 'confirm.itemError', 'confirm.rate', 'confirm.control',
                     'confirm.quantum', 'confirm.firstEndpoint', 'confirm.effectiveEndpoint', 'confirm.finalClock']:
            self.assertIn('"' + code + '"', driver)
        self.assertIn('first: first, stable: nil, expected: endpoint, effective: constrained', driver)
        self.assertIn('first: prior.firstCurrentTime, stable: stable,', driver)
        self.assertIn('expected: prior.expectedEndpoint, effective: constraint', driver)
        self.assertIn('String(value.prefix(288))', driver)
        coordinator = COORDINATOR.read_text()
        self.assertIn('detail: naturalEndFailureDetail(reason)', coordinator)
        self.assertIn('naturalEndFailureDiagnosticForTesting', coordinator)
        smoke = SMOKE.read_text()
        self.assertIn('testNativeEOFPredicateDiagnosticFitsOriginalFailureAndUIBounds', smoke)
        self.assertIn('predicate=confirm.quantum.revision', smoke)
        self.assertIn('String(message.prefix(1_024))', smoke)

    def test_quantum_failure_classification_preserves_validation_order_without_rereads(self):
        source = (ROOT / 'Sources/VPlayerPlayback/HLS/Native/NativeHLSAssetInspector.swift').read_text()
        self.assertTrue('func validationFailure(' in source)
        helper = source.split('func validationFailure(', 1)[1].split('func hasSameBinding(', 1)[0]
        ordered = ['selectionRevision.mismatch(revision)', 'identity == item',
                   'ObjectIdentifier(physical) == physicalItem', 'source.sourceIsCurrent',
                   'physical.tracks.filter', 'enabled.count <= 16', 'videos.count == 1',
                   'track.assetTrack', 'track === videoTrack',
                   'asset === videoAsset']
        self.assertEqual([helper.index(value) for value in ordered], sorted(helper.index(value) for value in ordered))
        self.assertEqual(helper.count('selectionRevision.mismatch(revision)'), 1)
        self.assertNotIn('await ', helper)
        self.assertNotIn('Task {', helper)
        mismatch = source.split('func mismatch(', 1)[1].split('\n}\n', 1)[0]
        self.assertEqual(mismatch.count('lock.withLock'), 1)
        self.assertIn('guard exhausted || value != revision else { return nil }', mismatch)
        self.assertIn('expected: revision, current: value, exhausted: exhausted, reason: lastInvalidationReason', mismatch)
        observation = OBSERVATION.read_text()
        for reason in ['presentationSize', 'tracks', 'status', 'mediaSelection', 'accessLog', 'errorLog', 'failedToEnd', 'hdrEligibility', 'privateEOSRefresh']:
            self.assertIn('.' + reason, observation)
        self.assertIn('selectionRevision.invalidate(reason: reason)', observation)

    def test_smoke_wait_failures_identify_the_route_and_actual_wait_phase(self):
        source = SMOKE.read_text()
        self.assertEqual(set(re.findall(r'phase: "([a-z-]+)"', source)), {
            'early-eof-startup', 'early-eof-recovery', 'full-eof-startup',
            'full-eof-completion', 'selected-format-startup', 'selected-format-progress',
            'eos-ordering-startup', 'eos-ordering-first-read', 'eos-ordering-refresh',
            'eos-ordering-error', 'eos-ordering-progress',
            'refresh-return-startup', 'refresh-return-first-read',
            'quantum-owner-original', 'quantum-owner-successor', 'public-mime-media-startup',
        })
        helper = source.split('private func until(', 1)[1].split('private func withController(', 1)[0]
        self.assertIn('file: StaticString = #filePath, line: UInt = #line', helper)
        self.assertNotIn('String(describing: registry.outputResourceContextSnapshot())', helper)
        self.assertIn('catch is CancellationError', helper)
        self.assertIn('NativeSmokeFailureReport.message(', helper)
        self.assertIn('testNativeSmokeFailureReportSurvivesXCResultFieldLimit', source)

    def test_full_eof_failure_preserves_original_and_successor_identity_without_new_loads(self):
        source = SMOKE.read_text()
        self.assertIn('private func naturalEOFEvidence(', source)
        helper = source.split('private func naturalEOFEvidence(', 1)[1].split('private func ', 1)[0]
        for field in ['original-output=', 'original-activation=', 'same-coordinator=',
                      'same-physical=', 'original-current=', 'driver-terminal=']:
            self.assertIn(field, helper)
        self.assertNotIn('await ', helper)
        self.assertNotIn('revalidateCurrentAuthority', helper)
        self.assertNotIn('Task {', helper)
        self.assertNotIn('addObserver', helper)

    def test_original_failure_cause_is_captured_before_recovery_and_survives_retirement(self):
        source = COORDINATOR.read_text()
        self.assertTrue('private(set) var firstFailureDiagnosticForTesting: String?' in source)
        helper = source.split('private func fail(', 1)[1].split('private func observe(', 1)[0]
        self.assertLess(helper.index('guard !retired, !failureDelivered'), helper.index('firstFailureDiagnosticForTesting ='))
        self.assertLess(helper.index('firstFailureDiagnosticForTesting ='), helper.index('failureDelivered = true'))
        self.assertIn('.utf8.prefix(384)', helper)
        self.assertIn('32...126', helper)
        self.assertEqual(source.count('firstFailureDiagnosticForTesting ='), 1)
        self.assertIn('original-failure={', SMOKE.read_text())
        lifecycle = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSAdapterLifecycleTests.swift').read_text()
        self.assertIn('testFirstFailureDiagnosticSurvivesRecoveryAndLateOldEvents', lifecycle)

    def test_each_recovery_origin_is_identified_without_changing_failure_reason(self):
        source = COORDINATOR.read_text()
        for reason, stage in [
            ('network', 'observation.failed'), ('network', 'source.expired'),
            ('unsupportedMedia', 'selection.refresh'), ('network', 'playback.paused'),
            ('network', 'naturalEnd.rejected'), ('network', 'progress.expired'),
            ('network', 'progress.stalled'),
        ]:
            self.assertIn(f'fail(.{reason}, stage: "{stage}"', source)
        # Every failure call must carry its actual boundary, rather than a
        # generic label or a changed error/retry path.
        self.assertEqual(len(re.findall(r'\bfail\(\.', source)), 7)
        helper = source.split('private func fail(', 1)[1].split('\n    private func observe(', 1)[0]
        self.assertLess(helper.index('guard !retired, !failureDelivered'), helper.index('diagnose('))
        self.assertLess(helper.index('diagnose('), helper.index('failureDelivered = true'))
        self.assertIn('failure(reason, authorization?.activation)', helper)

    def test_diagnostics_are_debug_only_and_keep_direct_item_time_semantics(self):
        source = COORDINATOR.read_text()
        self.assertIn('private func diagnose(', source)
        helper = source.split('private func diagnose(', 1)[1].split('\n    private func ', 1)[0]
        self.assertIn('@autoclosure () -> String', helper)
        self.assertIn('#if DEBUG', helper)
        self.assertIn('NATIVE_HLS_LIFECYCLE', helper)
        self.assertIn('outputLifecycleEpoch.outputNonce', helper)
        self.assertIn('activationNonce', helper)
        for value in ['currentTime()', 'duration', 'forwardPlaybackEndTime']:
            self.assertIn(value, helper)
        self.assertNotIn('await ', helper)
        self.assertNotIn('currentTime().seconds', helper)
        self.assertNotIn('source.context', helper)
        self.assertNotIn('player.play()', helper)
        self.assertNotIn('revalidateCurrentAuthority()', helper,
                         'Diagnostic reads must not add a safety-ingress transaction')
        self.assertIn('authority-validated=', helper)
        self.assertIn('diagnose("activate.endpoint"', source)
        self.assertIn('diagnose("activate.played"', source)
        self.assertIn('diagnose("observe.control"', source)
        self.assertIn('event-control=', source)
        self.assertIn('event-activation-match=', source)
        self.assertIn('diagnose("refresh.event"', source)
        self.assertIn('NATIVE_HLS_RECOVERY entry=watchdog', BACKEND.read_text())
        self.assertIn('NATIVE_HLS_RECOVERY entry=source-failure', BACKEND.read_text())

    def test_sdk_failure_and_snapshot_duration_are_observable_without_extra_loads(self):
        observation = OBSERVATION.read_text()
        self.assertIn('NATIVE_HLS_SDK_FAILURE signal=status', observation)
        self.assertIn('NATIVE_HLS_SDK_FAILURE signal=failed-to-end', observation)
        self.assertIn('AVPlayerItemFailedToPlayToEndTimeErrorKey', observation)
        smoke = SMOKE.read_text()
        inspector = smoke.split('private final class NativeSmokeTracingInspector:', 1)[1]
        self.assertIn('selected-duration=', inspector)
        self.assertIn('result.duration', inspector)
        self.assertIn('outputLifecycleEpoch.outputNonce', inspector)
        self.assertEqual(inspector.count('await base.snapshot('), 1)
        self.assertNotIn('await physical.', inspector)
        self.assertIn('if lines.count == 16', smoke)


if __name__ == '__main__':
    unittest.main()
