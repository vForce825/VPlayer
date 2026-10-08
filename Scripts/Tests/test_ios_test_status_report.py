#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable contract tests for the iOS-only selected XCTest report."""
import contextlib
import copy
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
REPORTER = ROOT / 'Scripts/report-ios-test-status.py'
NATIVE = 'VPlayeriOSTests/IOSNativePictureInPictureTests/testRealSampleBufferPiPStartsRestoresAndClosesTheRetainedSession'
BENCHMARK = 'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFBenchmarkReportsNativeHostMeasurementsWithoutDeviceQualification'


def schema():
    return {'$ref': '#/schemas/Tests', 'schemas': {
        'Tests': {'type': 'object', 'properties': {'testNodes': {'type': 'array', 'items': {'$ref': '#/schemas/TestNode'}}}},
        'TestNode': {'type': 'object', 'properties': {
            'nodeType': {'$ref': '#/schemas/NodeType'}, 'name': {'type': 'string'},
            'nodeIdentifier': {'type': 'string'}, 'result': {'$ref': '#/schemas/Result'},
            'children': {'type': 'array', 'items': {'$ref': '#/schemas/TestNode'}}}},
        'NodeType': {'type': 'string', 'enum': ['Test Plan', 'Unit test bundle', 'UI test bundle', 'Destination', 'Test Suite', 'Test Case', 'Test Case Run', 'Repetition', 'Failure Message']},
        'Result': {'type': 'string', 'enum': ['Passed', 'Failed', 'Skipped', 'Expected Failure', 'unknown']}}}


def case(identifier=NATIVE, result='Passed', children=None):
    target, short = identifier.split('/', 1)
    leaf = {'nodeType': 'Test Case', 'name': short.rsplit('/', 1)[-1] + '()', 'nodeIdentifier': short + '()', 'result': result}
    if children is not None:
        leaf['children'] = children
    return {'nodeType': 'Unit test bundle' if target in {'VPlayeriOSTests', 'VPlayeriOSBenchmarks'} else 'UI test bundle', 'name': target,
            'children': [{'nodeType': 'Destination', 'name': 'iPhone simulator', 'children': [leaf]}]}


class IOSSelectedStatusTests(unittest.TestCase):
    def module(self):
        self.assertTrue(REPORTER.exists(), 'iOS selected-test reporter is missing')
        spec = importlib.util.spec_from_file_location('ios_test_status', REPORTER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def analyze(self, tree, manifest=(NATIVE,), schema_value=None):
        return self.module().analyze(schema_value or schema(), {'testNodes': tree}, manifest)

    def test_nested_actual_test_case_status_is_reported(self):
        rows = self.analyze([case()])
        self.assertEqual(rows, [{'test': NATIVE, 'status': 'Passed'}])

    def test_missing_case_is_unverified_even_if_suite_passed(self):
        self.assertEqual(self.analyze([])[0]['status'], 'Unverified')
        self.assertEqual(self.analyze([])[0]['reason'], 'missing')

    def test_skipped_branch_message_does_not_need_its_own_result(self):
        children = [{'nodeType': 'Repetition', 'name': 'First run', 'result': 'Skipped', 'children': [
            {'nodeType': 'Failure Message', 'name': 'PiP unsupported on this runtime'}]}]
        row = self.analyze([case(result='Skipped', children=children)])[0]
        self.assertEqual(row['status'], 'Skipped')
        self.assertEqual(row['reason'], 'PiP unsupported on this runtime')

    def test_failed_branch_text_is_not_a_skip_reason(self):
        children = [{'nodeType': 'Repetition', 'name': 'First run', 'result': 'Failed', 'children': [
            {'nodeType': 'Failure Message', 'name': 'Private irrelevant failure'}]}]
        row = self.analyze([case(result='Skipped', children=children)])[0]
        self.assertEqual(row['reason'], 'reason_unavailable')
        self.assertNotIn('Private', json.dumps(row))

    def test_passed_retry_cannot_hide_previous_failure(self):
        children = [{'nodeType': 'Test Case Run', 'name': 'one', 'result': 'Failed'},
                    {'nodeType': 'Test Case Run', 'name': 'two', 'result': 'Passed'}]
        row = self.analyze([case(children=children)])[0]
        self.assertEqual(row['status'], 'Unverified')
        self.assertEqual(row['reason'], 'non_passing_or_unknown_attempt')

    def test_duplicate_identity_is_unverified(self):
        self.assertEqual(self.analyze([case(), case(result='Skipped')])[0]['reason'], 'duplicate_identity')

    def test_unknown_and_missing_result_never_pass(self):
        for value in ['unknown', 'Success', None, 1, True]:
            with self.subTest(value=value):
                self.assertEqual(self.analyze([case(result=value)])[0]['status'], 'Unverified')

    def test_wrong_target_does_not_satisfy_manifest(self):
        wrong = case(identifier=NATIVE.replace('VPlayeriOSTests/', 'VPlayerTests/'))
        self.assertEqual(self.analyze([wrong])[0]['reason'], 'missing')

    def test_wrapper_and_direct_schemas_are_supported(self):
        wrapped = schema(); del wrapped['$ref']
        self.assertEqual(self.analyze([case()], schema_value=wrapped)[0]['status'], 'Passed')
        direct = copy.deepcopy(schema()['schemas']['Tests']); direct['schemas'] = schema()['schemas']
        self.assertEqual(self.analyze([case()], schema_value=direct)[0]['status'], 'Passed')

    def test_typed_schema_without_enums_accepts_only_known_status_literals(self):
        value = schema()
        del value['schemas']['NodeType']['enum']; del value['schemas']['Result']['enum']
        self.assertEqual(self.analyze([case()], schema_value=value)[0]['status'], 'Passed')
        self.assertEqual(self.analyze([case(result='Success')], schema_value=value)[0]['status'], 'Unverified')
        value['schemas']['Result']['enum'] = ['Skipped']
        self.assertEqual(self.analyze([case()], schema_value=value)[0]['status'], 'Unverified')

    def test_named_root_supports_unambiguous_standard_wrappers(self):
        for name in ['schemas', '$defs', 'definitions']:
            value = schema()
            value.pop('$ref')
            value[name] = value.pop('schemas')
            value = json.loads(json.dumps(value).replace('#/schemas/', '#/' + name + '/'))
            self.assertEqual(self.analyze([case()], schema_value=value)[0]['status'], 'Passed')
        direct = schema()['schemas']
        direct = json.loads(json.dumps(direct).replace('#/schemas/', '#/'))
        self.assertEqual(self.analyze([case()], schema_value=direct)[0]['status'], 'Passed')
        ambiguous = schema(); ambiguous.pop('$ref'); ambiguous['Tests'] = ambiguous['schemas']['Tests']
        with self.assertRaises(ValueError):
            self.analyze([case()], schema_value=ambiguous)

    def test_schema_field_in_unrelated_object_is_not_authorization(self):
        bad = schema(); del bad['schemas']['TestNode']['properties']['result']
        bad['schemas']['Decoy'] = {'properties': {'result': {'type': 'string'}}}
        with self.assertRaises(ValueError):
            self.analyze([case()], schema_value=bad)

    def test_external_and_cyclic_schema_refs_fail(self):
        for ref in ['https://untrusted.example/schema', '#/schemas/NodeType']:
            bad = schema(); bad['schemas']['NodeType'] = {'$ref': ref}
            with self.assertRaises(ValueError):
                self.analyze([case()], schema_value=bad)

    def test_malformed_or_too_deep_tree_fails_closed(self):
        for tree in [{'testNodes': 'bad'}, {'testNodes': [{'nodeType': 'Destination', 'name': 'x', 'children': {}}]}]:
            with self.assertRaises(ValueError):
                self.module().analyze(schema(), tree, (NATIVE,))
        node = case()
        for _ in range(70):
            node = {'nodeType': 'Destination', 'name': 'x', 'children': [node]}
        with self.assertRaises(ValueError):
            self.analyze([node])

    def test_passed_case_with_failed_descendant_is_unverified(self):
        row = self.analyze([case(children=[{'nodeType': 'Failure Message', 'name': 'failure', 'result': 'Failed'}])])[0]
        self.assertEqual(row['status'], 'Unverified')

    def test_malformed_schema_shapes_raise_value_error(self):
        for value in [{'schemas': []}, {'type': 'object', 'properties': None}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module().verified_schema(value)
        bad = schema(); bad['schemas']['TestNode']['properties'] = []
        with self.assertRaises(ValueError):
            self.module().verified_schema(bad)

    def test_node_budget_is_enforced(self):
        m = self.module()
        with patch.object(m, 'MAX_NODES', 1), self.assertRaises(ValueError):
            m.analyze(schema(), {'testNodes': [case()]}, (NATIVE,))

    def test_stderr_output_is_bounded_and_not_exposed(self):
        m = self.module()
        with self.assertRaisesRegex(RuntimeError, '^xcresulttool_output_limit$'):
            m.run_bounded([sys.executable, '-c', "import sys; sys.stderr.write('private'*20000)"])
        with self.assertRaisesRegex(RuntimeError, '^xcresulttool_nonzero_exit$'):
            m.run_bounded([sys.executable, '-c', "import sys; sys.stderr.write('private'); sys.exit(5)"])

    def test_reporting_counts_keep_skips_and_expected_failures_separate(self):
        m = self.module()
        rows = [{'test': 'id', 'status': result} for result in ['Passed', 'Failed', 'Skipped', 'Expected Failure', 'Unverified']]
        line = next(x for x in m.report_lines(rows, 'functional') if x.startswith('IOS_SELECTED_TEST_COUNTS='))
        self.assertEqual(json.loads(line.split('=', 1)[1]), {result: 1 for result in ['Passed', 'Failed', 'Skipped', 'Expected Failure', 'Unverified']})

    def test_default_allowlist_excludes_benchmark_and_contains_ui_and_session(self):
        m = self.module()
        self.assertIsInstance(m.DEFAULT_TESTS, tuple)
        self.assertNotIn(BENCHMARK, m.DEFAULT_TESTS)
        self.assertEqual(m.BENCHMARK_TESTS, (BENCHMARK,))
        self.assertTrue(any('/IOSPlaybackSessionTests/' in x for x in m.DEFAULT_TESTS))
        self.assertEqual(sum('/IOSLibraryFlowTests/' in x for x in m.DEFAULT_TESTS), 3)
        self.assertEqual(len(m.DEFAULT_TESTS), len(set(m.DEFAULT_TESTS)))

    def test_manifest_includes_all_budget_fixture_and_fill_regressions(self):
        m = self.module()
        expected = {
            'VPlayeriOSTests/YADIFGoldenPixelTests/testCPUBenchmarkPeriodicFillMatchesOriginalFormulaAndPreservesPadding',
            'VPlayeriOSTests/HLSAVPlayerBackendTests/testSyntheticHLG50AC3OriginalAACFragmentsDecodeContinuously',
        }
        for method in (
            'testPausedCoverageWorkspaceReservesBeforeCompletionAndReleasesExactCharge',
            'testPausedResumeDecodePinsExcludeUnfetchedNoncontributingVideoHold',
            'testPausedCoverageWorkspaceRejectsExpandedPinsAndInvalidCapacities',
            'testPausedCoverageWorkspaceRejectsReentryWithoutInvalidatingOuterScope',
            'testPausedCoverageWorkspaceHardCapacityFailureDoesNotAllocateOrLosePins',
            'testPausedCoverageWorkspaceFrozenMissingInitializationCannotGainLaterCompletion',
            'testPausedWorkspaceMallocBuffersRespectAlignmentAndPhysicalPrechargeBoundaries',
            'testPausedWorkspacePartialAllocationFailureFreesEveryRawOwnerAndReservation',
            'testPausedWorkspaceChargeSurvivesUntilTheFinalWorkspaceAliasIsReleased',
        ):
            expected.add('VPlayeriOSTests/LoopbackHTTPServerTests/' + method)
        self.assertEqual(len(m.DEFAULT_TESTS), 37)
        self.assertTrue(expected.issubset(m.DEFAULT_TESTS))

    def test_full_default_manifest_fits_output_and_summary_without_omitting_cases(self):
        m = self.module()
        rows = m.analyze(schema(), {'testNodes': [case(test) for test in m.DEFAULT_TESTS]})
        self.assertEqual(len(rows), 37)
        self.assertTrue(all(row['status'] == 'Passed' for row in rows))
        lines = m.report_lines(rows, 'functional_unit_and_ui')
        summary = m.job_summary(lines)
        self.assertEqual(sum(line.startswith('IOS_SELECTED_TEST ') for line in lines), 37)
        self.assertNotIn('TRUNCATED', '\n'.join(lines) + summary)
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode()), m.MAX_OUTPUT)
        self.assertLessEqual(len(summary.encode()), m.MAX_OUTPUT)

    def test_allowlist_methods_exist_under_exact_source_classes(self):
        import re
        m = self.module(); methods = set()
        for base, target in [('Tests/VPlayeriOSTests', 'VPlayeriOSTests'), ('Tests/VPlayeriOSUITests', 'VPlayeriOSUITests'), ('Tests/VPlayerTests', 'VPlayeriOSTests')]:
            for path in (ROOT / base).rglob('*.swift'):
                current = None
                for line in path.read_text().splitlines():
                    match = re.match(r'(?:final )?class (\w+)\s*:', line)
                    if match: current = match[1]
                    match = re.match(r'\s+func (test\w+)\(', line)
                    if match and current: methods.add(f'{target}/{current}/{match[1]}')
        methods.update(identifier.replace('VPlayeriOSTests/', 'VPlayeriOSBenchmarks/', 1) for identifier in tuple(methods) if identifier.startswith('VPlayeriOSTests/YADIFGoldenPixelTests/'))
        self.assertFalse(set(m.DEFAULT_TESTS + m.BENCHMARK_TESTS) - methods)

    def test_output_and_escaped_summary_are_bounded(self):
        m = self.module()
        rows = [{'test': NATIVE, 'status': 'Skipped', 'reason': '</code><script>boom</script>' * 1000}] * 100
        lines = m.report_lines(rows, 'functional')
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode()), m.MAX_OUTPUT)
        summary = m.job_summary(lines)
        self.assertLessEqual(len(summary.encode()), m.MAX_OUTPUT)
        self.assertNotIn('<script>', summary)
        self.assertIn('TRUNCATED', summary)

    def test_subprocess_timeout_and_size_limits(self):
        m = self.module()
        with self.assertRaises(RuntimeError):
            m.run_bounded([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=0.05)
        with self.assertRaises(RuntimeError):
            m.run_bounded([sys.executable, '-c', "print('x'*10000)"], limit=100)
        self.assertEqual(m.run_bounded([sys.executable, '-c', "print('ok')"]).strip(), 'ok')

    def test_runtime_discovers_schema_and_reads_only_tests_json(self):
        m = self.module()
        replies = ['--schema --path', json.dumps(schema()), json.dumps({'testNodes': [case(BENCHMARK)]})]
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / 'bench.xcresult'; bundle.mkdir()
            with patch.object(m, 'run_bounded', side_effect=replies) as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(m.main([str(bundle), '--benchmark']), 0)
            self.assertEqual(run.call_args_list[0].args[0], ['xcrun', 'xcresulttool', 'help', 'get', 'test-results', 'tests'])
            self.assertEqual(run.call_args_list[1].args[0][-1], '--schema')
            self.assertEqual(run.call_args_list[2].args[0][-2:], ['--path', str(bundle)])
            self.assertEqual(run.call_count, 3)

    def test_unsupported_native_schema_emits_bounded_shape_without_values(self):
        m = self.module()
        unsupported = {'schemas': [], 'unexpectedPayload': 'DO_NOT_LEAK_SCHEMA_VALUE'}
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / 'tests.xcresult'; bundle.mkdir()
            out = io.StringIO()
            with patch.object(m, 'run_bounded', side_effect=['--schema --path', json.dumps(unsupported)]) as run, contextlib.redirect_stdout(out):
                self.assertEqual(m.main([str(bundle), '--benchmark']), 1)
            shape_line = next(line for line in out.getvalue().splitlines() if line.startswith('IOS_SELECTED_TEST_SCHEMA_SHAPE='))
            shape = json.loads(shape_line.split('=', 1)[1])
            self.assertEqual(shape['root_type'], 'object')
            self.assertEqual(shape['root_fields']['schemas'], 'array')
            self.assertLessEqual(len(shape_line.encode()), 1100)
            self.assertNotIn('DO_NOT_LEAK_SCHEMA_VALUE', out.getvalue())
            self.assertEqual(run.call_count, 2)

    def test_missing_bundle_emits_all_unverified_and_appends_summary(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as temp:
            summary = Path(temp) / 'summary'; summary.write_text('previous\n')
            out = io.StringIO()
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}), contextlib.redirect_stdout(out):
                self.assertEqual(m.main([str(Path(temp) / 'missing.xcresult'), '--benchmark']), 1)
            self.assertIn('Unverified', out.getvalue())
            self.assertTrue(summary.read_text().startswith('previous\n'))


if __name__ == '__main__':
    unittest.main()
