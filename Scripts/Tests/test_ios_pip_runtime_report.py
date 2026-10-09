#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable tests for capability-only native PiP evidence, never a test verdict."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / 'Scripts/report-ios-pip-runtime.py'
CANDIDATE = 'a' * 40
FALSE = b'IOS_PIP_RUNTIME_SUPPORTED=false\n'
TRUE = b'IOS_PIP_RUNTIME_SUPPORTED=true\n'


class IOSPiPRuntimeTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''})
        environment.start()
        self.addCleanup(environment.stop)

    def module(self):
        self.assertTrue(REPORTER.exists(), 'native PiP capability reporter is missing')
        spec = importlib.util.spec_from_file_location('ios_pip_runtime', REPORTER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def record(self, payload, candidate=CANDIDATE):
        module = self.module()
        destination = io.BytesIO()
        state = module.relay(io.BytesIO(payload), destination)
        self.assertEqual(destination.getvalue(), payload)
        return state.record(candidate)

    def test_false_is_observed_capability_without_a_pass_or_inferred_skip_reason(self):
        record = self.record(FALSE)
        self.assertEqual(record['status'], 'Observed')
        self.assertIs(record['supported'], False)
        self.assertEqual(record['candidate'], CANDIDATE)
        self.assertEqual(record['marker_count'], 1)
        self.assertEqual(record['evidence'], 'capability_api_only_not_native_pip_pass')
        self.assertNotIn('Passed', json.dumps(record))
        self.assertNotIn('skip_reason', record)

    def test_true_only_reports_support_and_cannot_claim_native_pip_pass(self):
        record = self.record(TRUE)
        self.assertEqual(record['status'], 'Observed')
        self.assertIs(record['supported'], True)
        self.assertEqual(record['qualification'], 'simulator_evidence_only_physical_iphone_not_qualified')
        self.assertNotIn('Passed', json.dumps(record))

    def test_absent_duplicate_conflicting_and_malformed_markers_are_unverified(self):
        for payload, reason in [(b'ordinary output\n', 'missing_marker'),
                                (FALSE * 2, 'duplicate_markers'),
                                (FALSE + TRUE, 'conflicting_markers'),
                                (b'IOS_PIP_RUNTIME_SUPPORTED=maybe\n', 'malformed_marker'),
                                (FALSE + b'IOS_PIP_RUNTIME_SUPPORTED=false private\n', 'malformed_marker')]:
            with self.subTest(reason=reason):
                record = self.record(payload)
                self.assertEqual(record['status'], 'Unverified')
                self.assertIsNone(record['supported'])
                self.assertEqual(record['reason'], reason)
                self.assertNotIn('private', json.dumps(record))

    def test_only_exact_lines_are_accepted_including_crlf_and_final_line(self):
        for payload in [FALSE.replace(b'\n', b'\r\n'), FALSE.rstrip(b'\n')]:
            self.assertIs(self.record(payload)['supported'], False)
        for payload in [b'prefix ' + FALSE, FALSE.rstrip(b'\n') + b' suffix\n',
                        b'IOS_PIP_RUNTIME_SUPPORTED=fals\n', b'IOS_PIP_RUNTIME_SUPPORTED=FALSE\n']:
            self.assertEqual(self.record(payload)['status'], 'Unverified')

    def test_chunk_boundaries_and_large_non_utf8_output_are_forwarded_unchanged(self):
        module = self.module()
        payload = b'\xff\x00\xfe' * 700_000 + b'\n' + FALSE
        self.assertIs(self.record(payload)['supported'], False)
        state = module.Capability()
        for byte in FALSE:
            state.consume(bytes([byte]))
            self.assertLessEqual(len(state.pending), 64)
        self.assertIs(state.record(CANDIDATE)['supported'], False)

    def test_oversized_marker_never_becomes_valid_and_memory_counters_are_capped(self):
        module = self.module()
        state = module.Capability()
        state.consume(FALSE.rstrip(b'\n'))
        for _ in range(1024):
            state.consume(b'x' * 16_384)
            self.assertLessEqual(len(state.pending), 64)
        state.consume(b'\n' + FALSE * 1000)
        record = state.record(CANDIDATE)
        self.assertEqual(record['status'], 'Unverified')
        self.assertEqual(record['reason'], 'malformed_marker')
        self.assertEqual(record['marker_count'], 2)
        self.assertEqual(record['invalid_marker_count'], 1)
        self.assertLess(len(json.dumps(record)), 1024)

    def test_candidate_is_validated_without_copying_unknown_input(self):
        record = self.record(FALSE, 'PRIVATE_CANDIDATE_VALUE')
        self.assertEqual(record['status'], 'Unverified')
        self.assertEqual(record['reason'], 'candidate_unavailable')
        self.assertNotIn('PRIVATE_CANDIDATE_VALUE', json.dumps(record))

    def test_pipeline_preserves_native_exit_and_only_appends_capability_json(self):
        self.module()
        command = 'set -o pipefail\n"$1" -c "$4" 2>&1 | "$1" "$2" --candidate "$3"'
        for exit_code in [0, 17]:
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as temp:
                summary = Path(temp) / 'summary'; summary.write_text('existing test results\n')
                payload = b'private original output\xff\n' + TRUE
                producer = f'import sys; sys.stdout.buffer.write({payload!r}); sys.exit({exit_code})'
                result = subprocess.run(['bash', '-c', command, 'pip-relay-test', sys.executable,
                                         str(REPORTER), CANDIDATE, producer],
                                        env=dict(os.environ, GITHUB_STEP_SUMMARY=str(summary)),
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(result.stdout, payload)
                text = summary.read_text()
                self.assertTrue(text.startswith('existing test results\n'))
                records = [line.removeprefix('IOS_PIP_RUNTIME_CAPABILITY=') for line in text.splitlines()
                           if line.startswith('IOS_PIP_RUNTIME_CAPABILITY=')]
                self.assertEqual(len(records), 1)
                record = json.loads(records[0])
                self.assertEqual(record['status'], 'Observed')
                self.assertIs(record['supported'], True)
                self.assertNotIn('private', text)
                self.assertNotIn('Passed', text)

    def test_summary_write_failure_is_optional_and_does_not_leak_path(self):
        self.module()
        with tempfile.TemporaryDirectory(prefix='private-summary-') as temp:
            result = subprocess.run([sys.executable, str(REPORTER), '--candidate', CANDIDATE],
                                    input=FALSE, env=dict(os.environ, GITHUB_STEP_SUMMARY=temp),
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, FALSE)
            self.assertEqual(result.stderr, b'IOS_PIP_RUNTIME_SUMMARY_UNAVAILABLE=write_failed\n')
            self.assertNotIn(temp.encode(), result.stderr)

    def test_native_marker_uses_the_same_single_api_read_as_the_skip_guard(self):
        text = (ROOT / 'Tests/VPlayeriOSTests/IOSPictureInPictureCoordinatorTests.swift').read_text()
        method = text.split('func testRealSampleBufferPiPStartsRestoresAndClosesTheRetainedSession()', 1)[1]
        method = method.split('let scene =', 1)[0]
        self.assertEqual(method.count('AVPictureInPictureController.isPictureInPictureSupported()'), 1)
        self.assertIn('let runtimeSupportsPiP = AVPictureInPictureController.isPictureInPictureSupported()', method)
        self.assertIn('"IOS_PIP_RUNTIME_SUPPORTED=true\\n"', method)
        self.assertIn('"IOS_PIP_RUNTIME_SUPPORTED=false\\n"', method)
        self.assertLess(method.index('FileHandle.standardOutput.write'), method.index('guard runtimeSupportsPiP else'))
        self.assertIn('throw XCTSkip("AVKit reports Picture in Picture unsupported on this runtime")', method)
        self.assertNotIn('await', method)


class IOSPiPRuntimeIsolationTests(unittest.TestCase):
    def test_contract_suite_cannot_append_to_an_inherited_ci_summary(self):
        with tempfile.TemporaryDirectory() as temp:
            summary = Path(temp) / 'ci-summary'; summary.write_text('real CI evidence\n')
            result = subprocess.run([sys.executable, '-m', 'unittest',
                                     'Scripts.Tests.test_ios_pip_runtime_report.IOSPiPRuntimeTests'],
                                    cwd=ROOT, env=dict(os.environ, GITHUB_STEP_SUMMARY=str(summary)),
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(summary.read_text(), 'real CI evidence\n')


if __name__ == '__main__':
    unittest.main()
