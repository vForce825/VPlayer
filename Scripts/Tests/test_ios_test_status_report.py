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
NATIVE_URL = 'test://com.apple.xcode/VPlayer/' + NATIVE + '()'
BENCHMARK = 'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFBenchmarkReportsNativeHostMeasurementsWithoutDeviceQualification'
RELEASE_GOLDEN = 'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly'
PREFLIGHT = (
    'VPlayeriOSTests/IOSPictureInPictureCoordinatorTests/testRetirementBeforeQueuedNativeStopCannotLeaveForegroundOnCPU',
    'VPlayeriOSUITests/IOSLibraryFlowTests/testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation',
)


def schema():
    return {'$ref': '#/schemas/Tests', 'schemas': {
        'Tests': {'type': 'object', 'properties': {'testNodes': {'type': 'array', 'items': {'$ref': '#/schemas/TestNode'}}}},
        'TestNode': {'type': 'object', 'properties': {
            'nodeType': {'$ref': '#/schemas/NodeType'}, 'name': {'type': 'string'},
            'nodeIdentifier': {'type': 'string'}, 'nodeIdentifierURL': {'type': 'string'},
            'result': {'$ref': '#/schemas/Result'},
            'children': {'type': 'array', 'items': {'$ref': '#/schemas/TestNode'}}}},
        'NodeType': {'type': 'string', 'enum': ['Test Plan', 'Unit test bundle', 'UI test bundle', 'Destination', 'Test Suite', 'Test Case', 'Test Case Run', 'Repetition', 'Failure Message']},
        'Result': {'type': 'string', 'enum': ['Passed', 'Failed', 'Skipped', 'Expected Failure', 'unknown']}}}


def case(identifier=NATIVE, result='Passed', children=None):
    target, short = identifier.split('/', 1)
    leaf = {'nodeType': 'Test Case', 'name': short.rsplit('/', 1)[-1] + '()',
            'nodeIdentifier': short + '()', 'nodeIdentifierURL': 'test://com.apple.xcode/VPlayer/' + identifier + '()', 'result': result}
    if children is not None:
        leaf['children'] = children
    return {'nodeType': 'Unit test bundle' if target in {'VPlayeriOSTests', 'VPlayeriOSBenchmarks'} else 'UI test bundle', 'name': target,
            'children': [{'nodeType': 'Destination', 'name': 'iPhone simulator', 'children': [leaf]}]}


def details_schema():
    value = schema()
    value['$ref'] = '#/schemas/TestDetails'
    value['schemas']['TestDetails'] = {'type': 'object', 'properties': {
        'testIdentifier': {'type': 'string'}, 'testIdentifierURL': {'type': 'string'},
        'testResult': {'$ref': '#/schemas/Result'},
        'testRuns': {'type': 'array', 'items': {'$ref': '#/schemas/TestNode'}}}}
    return value


def skipped_details():
    return {'testIdentifier': NATIVE.split('/', 1)[1] + '()',
            'testIdentifierURL': NATIVE_URL, 'testResult': 'Skipped',
            'testRuns': [{'nodeType': 'Test Case Run', 'name': 'Run 1', 'result': 'Skipped',
                          'children': [{'nodeType': 'Failure Message', 'name': 'Observed runtime skip reason'}]}]}


class IOSSelectedStatusTests(unittest.TestCase):
    def setUp(self):
        # Fixture results must never become evidence in the enclosing CI job.
        environment = patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''})
        environment.start()
        self.addCleanup(environment.stop)

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
        self.assertEqual(m.BENCHMARK_TESTS[:2], (BENCHMARK, RELEASE_GOLDEN))
        self.assertEqual(len(m.BENCHMARK_TESTS), 9)
        self.assertTrue(any('/IOSPlaybackSessionTests/' in x for x in m.DEFAULT_TESTS))
        self.assertEqual(sum('/IOSLibraryFlowTests/' in x for x in m.DEFAULT_TESTS), 11)
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
            'testPausedWorkspaceRollbackKeepsExactChargeWhenAnUnrelated16KiBOwnerRetires',
            'testPausedWorkspaceChargeSurvivesUntilTheFinalWorkspaceAliasIsReleased',
        ):
            expected.add('VPlayeriOSTests/LoopbackHTTPServerTests/' + method)
        self.assertEqual(len(m.DEFAULT_TESTS), 86)
        self.assertTrue(expected.issubset(m.DEFAULT_TESTS))

    def test_manifest_includes_native_factory_and_observation_regressions(self):
        m = self.module()
        expected = {
            'VPlayeriOSTests/IOSPictureInPictureCoordinatorTests/' + method for method in (
                'testActiveAndStartingRetirementWaitForStopBeforeCreatingSuccessor',
                'testFactoryFailureClearsPresentationAndProcessingActivity',
                'testNativeFactoryCannotBypassActualRuntimeCapability',
                'testPlaybackInvalidationOnlyTargetsSampleBufferContent',
            )
        }
        expected.update('VPlayeriOSTests/HLSAVPlayerBackendTests/' + method for method in (
            'testHandoffMediaObservationWaitsThroughProbeAndClearForCurrentOutput',
            'testHandoffMediaObservationRejectsMissingOutputFailureAndChangedIdentity',
            'testProductionHLSRouteHandoffClearsMediaAndRejectsOldCallbacksAfterSampleBuffer',
        ))
        expected.add('VPlayeriOSUITests/IOSLibraryFlowTests/testDeletionCancellationGeometryUsesOnlyObservedExteriorSpace')
        self.assertTrue(expected.issubset(m.DEFAULT_TESTS))

    def test_manifest_includes_controls_visibility_policy_and_native_ui_regressions(self):
        m = self.module()
        expected = {
            'VPlayeriOSTests/IOSPlayerControlsVisibilityTests/' + method for method in (
                'testCurrentIdleTimeoutHidesControlsAndLeavesNoTimer',
                'testBackgroundTapHidesAndRestoresControls',
                'testControlInteractionRefreshesTimeoutWithoutTogglingVisibility',
                'testPinningRevealsControlsAndRejectsTimeoutAcrossResume',
                'testRepeatedPlaybackUpdateDoesNotPostponeTimeout',
                'testDisappearanceInvalidatesTimeoutBeforeReappearance',
                'testOnlyUnobstructedActivePlaybackAllowsAutoHide',
            )
        }
        expected.update('VPlayeriOSUITests/IOSLibraryFlowTests/' + method for method in (
            'testPlaybackControlsBackgroundTapAndIdleTimeoutPreserveSession',
            'testPlaybackControlTapsAndSettingsDoNotToggleBackgroundOrStopSession',
            'testHiddenPlaybackControlsCanBeRevealedAfterRotation',
            'testForegroundReturnRevealsControlsAndStartsFreshIdleTimeout',
            'testPlaybackFailureKeepsControlsAndExitVisible',
        ))
        self.assertTrue(expected.issubset(m.DEFAULT_TESTS))

    def test_manifest_includes_exact_neon_and_worker_service_evidence(self):
        m = self.module()
        parity = (
            'testCPUNativeBackendsMatchEveryPinnedNV12AndP010FieldExactly',
            'testCPUNEONMatchesScalarAcrossStridesParitiesAndPatterns',
            'testCPUNEONMatchesScalarForInputAliasesAndRandomRowPartitions',
            'testCPURequiredNEONRejectsNoVectorWorkAndOutputOverlapWithoutWrites',
            'testCPUNEONGuardPagesPreserveBounds',
            'testCPUNEONPreservesStrictTiesAndNearGatedFarCandidatesInEveryLane',
        )
        self.assertTrue({f'VPlayeriOSTests/YADIFGoldenPixelTests/{method}' for method in parity}.issubset(m.DEFAULT_TESTS))
        self.assertTrue({f'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/{method}' for method in parity}.issubset(m.BENCHMARK_TESTS))
        self.assertIn('VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFScalarVersusNEONBenchmarkReportsPairedPatternMeasurements', m.BENCHMARK_TESTS)
        workers = (
            'testWorkerSummarySeparatesCPUServiceFromHeterogeneousWallTimesAndRequestedQoS',
            'testMissingWorkerCPUClockAndMissingSlotStayUnverifiedInsteadOfZeroService',
            'testWorkerWindowCountersExtremaAndContextResetAtOneSecondBoundary',
            'testWorkerWindowMarksMixedSurfaceContextsAndDoesNotInventMissingTelemetry',
            'testNativeThreadCPUClockProvidesValidNonnegativeElapsedService',
        )
        self.assertTrue({f'VPlayeriOSTests/AdaptiveYADIFDiagnosticsTests/{method}' for method in workers}.issubset(m.DEFAULT_TESTS))

    def test_manifest_includes_native_eof_boundary_regressions(self):
        m = self.module()
        expected = {
            'VPlayeriOSTests/NativeHLSAdapterLifecycleTests/' + method for method in (
                'testNativeFinalQuantumAcceptsObservedClocksAndRejectsPrematureOrMissingEvidence',
                'testNativeFinalQuantumPreservesAtOrAfterEndpointClocks',
                'testNativeFinalQuantumRejectsMalformedPeriodsAtAndAfterEndpoint',
            )
        }
        expected.update('VPlayeriOSTests/NativeHLSMasterSmokeTests/' + method for method in (
            'testRealNativeAndManagedHLSReachVerifiedUntrimmedEOF',
            'testNativeEOSStableOvershootKeepsOriginalItemAndAuthority',
            'testNativeEOSOvershootCannotBypassTransportOrAuthorityFailures',
            'testNativeEOSOriginalDeadlineRejectsUnsettledTransportAndInvalidEvidence',
        ))
        self.assertTrue(expected.issubset(m.DEFAULT_TESTS))

    def test_full_default_manifest_fits_output_and_summary_without_omitting_cases(self):
        m = self.module()
        rows = m.analyze(schema(), {'testNodes': [case(test) for test in m.DEFAULT_TESTS]})
        self.assertEqual(len(rows), 86)
        self.assertTrue(all(row['status'] == 'Passed' for row in rows))
        lines = m.report_lines(rows, 'functional_unit_and_ui')
        summary = m.job_summary(lines)
        self.assertEqual(sum(line.startswith('IOS_SELECTED_TEST ') for line in lines), 86)
        self.assertNotIn('TRUNCATED', '\n'.join(lines) + summary)
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode()), m.MAX_OUTPUT)
        self.assertLessEqual(len(summary.encode()), m.MAX_OUTPUT)

    def test_preflight_manifest_is_exact_and_remains_required_in_full_suite(self):
        m = self.module()
        self.assertEqual(getattr(m, 'PREFLIGHT_TESTS', None), PREFLIGHT)
        self.assertTrue(set(PREFLIGHT).issubset(m.DEFAULT_TESTS))
        self.assertEqual(len(m.DEFAULT_TESTS), 86)

    def test_preflight_requires_both_passed_and_never_accepts_skipped_or_missing_tests(self):
        m = self.module()
        self.assertTrue(hasattr(m, 'PREFLIGHT_TESTS'), 'A separate preflight manifest is required')
        for result, missing in [('Passed', False), ('Failed', False), ('Skipped', False),
                                ('Expected Failure', False), ('Passed', True)]:
            with self.subTest(result=result, missing=missing), tempfile.TemporaryDirectory() as temp:
                bundle = Path(temp) / 'preflight.xcresult'; bundle.mkdir()
                tree = [case(PREFLIGHT[0])]
                if not missing:
                    tree.append(case(PREFLIGHT[1], result=result))
                replies = ['--schema --path', json.dumps(schema()), json.dumps({'testNodes': tree})]
                output = io.StringIO()
                with patch.object(m, 'run_bounded', side_effect=replies), \
                        patch.object(m, 'enrich_skip_reasons'), contextlib.redirect_stdout(output):
                    status = m.main([str(bundle), '--preflight'])
                self.assertEqual(status, int(result != 'Passed' or missing))
                self.assertIn('IOS_SELECTED_TEST_SCOPE=regression_preflight', output.getvalue())
                self.assertEqual(sum(line.startswith('IOS_SELECTED_TEST ') for line in output.getvalue().splitlines()), 2)

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
        replies = ['--schema --path', json.dumps(schema()), json.dumps({'testNodes': [case(identifier) for identifier in m.BENCHMARK_TESTS]})]
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / 'bench.xcresult'; bundle.mkdir()
            with patch.object(m, 'run_bounded', side_effect=replies) as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(m.main([str(bundle), '--benchmark']), 0)
            self.assertEqual(run.call_args_list[0].args[0], ['xcrun', 'xcresulttool', 'help', 'get', 'test-results', 'tests'])
            self.assertEqual(run.call_args_list[1].args[0][-1], '--schema')
            self.assertEqual(run.call_args_list[2].args[0][-2:], ['--path', str(bundle)])
            self.assertEqual(run.call_count, 3)

    def runtime_report(self, detail_replies, tree=None):
        m = self.module()
        replies = ['--schema --path', json.dumps(schema()),
                   json.dumps({'testNodes': tree or [case(result='Skipped')]}), *detail_replies]
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / 'tests.xcresult'; bundle.mkdir()
            out = io.StringIO()
            with patch.object(m, 'DEFAULT_TESTS', (NATIVE,)), \
                    patch.object(m, 'run_bounded', side_effect=replies) as run, \
                    contextlib.redirect_stdout(out):
                code = m.main([str(bundle)])
            row = json.loads(next(line.removeprefix('IOS_SELECTED_TEST ') for line in out.getvalue().splitlines()
                                  if line.startswith('IOS_SELECTED_TEST ')))
            return code, row, run.call_args_list, out.getvalue()

    def test_skipped_selected_case_reads_schema_verified_public_details(self):
        code, row, calls, output = self.runtime_report([
            '--path --schema --test-id', json.dumps(details_schema()), json.dumps(skipped_details())])
        self.assertEqual(code, 0)
        self.assertEqual(row, {'test': NATIVE, 'status': 'Skipped',
                              'reason': 'Observed runtime skip reason', 'reason_source': 'test_details_failure_message'})
        self.assertEqual(calls[3].args[0], ['xcrun', 'xcresulttool', 'help', 'get', 'test-results', 'test-details'])
        self.assertEqual(calls[4].args[0], ['xcrun', 'xcresulttool', 'get', 'test-results', 'test-details', '--schema'])
        command = calls[5].args[0]
        self.assertEqual(command[:5], ['xcrun', 'xcresulttool', 'get', 'test-results', 'test-details'])
        self.assertEqual(command[-2:], ['--test-id', NATIVE_URL])
        self.assertEqual(command[-4], '--path')
        self.assertTrue(command[-3].endswith('/tests.xcresult'))
        self.assertEqual(len(calls), 6)
        self.assertNotIn('test://', output)
        self.assertNotIn('Run 1', output)

    def test_details_wrong_identity_or_result_cannot_replace_skip_evidence(self):
        for field, value in [('testIdentifier', 'AnotherSuite/testOther()'),
                             ('testIdentifierURL', NATIVE_URL.replace('VPlayeriOSTests/', 'OtherTests/')),
                             ('testResult', 'Passed'), ('testResult', 'Failed')]:
            with self.subTest(field=field, value=value):
                details = skipped_details(); details[field] = value
                code, row, _, output = self.runtime_report([
                    '--path --schema --test-id', json.dumps(details_schema()), json.dumps(details)])
                self.assertEqual(code, 0)
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason'], 'reason_unavailable')
                self.assertEqual(row['reason_source'], 'unavailable')
                self.assertEqual(row['reason_detail'], 'details_identity_or_status_mismatch')
                self.assertNotIn('Observed runtime skip reason', output)

    def test_details_schema_and_help_must_verify_before_bundle_read(self):
        unsupported = details_schema()
        del unsupported['schemas']['TestDetails']['properties']['testIdentifierURL']
        decoy = details_schema()
        decoy['schemas']['TestNode']['properties']['name'] = {'type': 'integer'}
        for replies in [
            ['--path --schema'],
            ['--path --schema --test-id', json.dumps({'schemas': []})],
            ['--path --schema --test-id', json.dumps(unsupported)],
            ['--path --schema --test-id', json.dumps(decoy)],
            ['--path --schema --test-id', '{invalid'],
        ]:
            with self.subTest(replies=replies):
                code, row, calls, _ = self.runtime_report(replies)
                self.assertEqual(code, 0)
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason'], 'reason_unavailable')
                self.assertEqual(row['reason_source'], 'unavailable')
                self.assertIn(row['reason_detail'], {'details_help_unavailable', 'details_schema_unavailable'})
                self.assertLessEqual(len(calls), 5)

    def test_details_malformed_result_enums_preserve_skipped_status(self):
        for values in [None, 5, 'Skipped', [], ['Skipped', 5], ['Passed']]:
            with self.subTest(values=values):
                value = details_schema()
                value['schemas']['TestDetails']['properties']['testResult'] = {'type': 'string', 'enum': values}
                code, row, calls, _ = self.runtime_report([
                    '--path --schema --test-id', json.dumps(value)])
                self.assertEqual(code, 0)
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason_detail'], 'details_schema_unavailable')
                self.assertEqual(len(calls), 5)

    def test_details_failure_timeout_or_size_limit_preserves_selected_skip(self):
        for error in [RuntimeError('xcresulttool_timeout'), RuntimeError('xcresulttool_output_limit'),
                      RuntimeError('xcresulttool_nonzero_exit'), OSError('PRIVATE_EXECUTION_DATA')]:
            with self.subTest(error=type(error).__name__):
                code, row, calls, output = self.runtime_report([
                    '--path --schema --test-id', json.dumps(details_schema()), error])
                self.assertEqual(code, 0)
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason'], 'reason_unavailable')
                self.assertEqual(row['reason_detail'], 'details_read_unavailable')
                self.assertLessEqual(calls[-1].kwargs['limit'], 256 * 1024)
                self.assertLessEqual(calls[-1].kwargs['timeout'], 10)
                self.assertNotIn('PRIVATE_EXECUTION_DATA', output)

    def test_details_malformed_tree_cannot_publish_partial_reason(self):
        for malformed in [None, {}, [{'nodeType': 'Failure Message', 'name': 5}],
                          [{'nodeType': 'Failure Message', 'name': 'private', 'children': {}}]]:
            with self.subTest(malformed=malformed):
                details = skipped_details(); details['testRuns'] = malformed
                code, row, _, output = self.runtime_report([
                    '--path --schema --test-id', json.dumps(details_schema()), json.dumps(details)])
                self.assertEqual(code, 0)
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason'], 'reason_unavailable')
                self.assertEqual(row['reason_detail'], 'details_payload_unavailable')
                self.assertNotIn('private', output)

    def test_details_only_accepts_deduplicated_failure_messages_on_skipped_branches(self):
        details = skipped_details()
        details['testRuns'].append(copy.deepcopy(details['testRuns'][0]))
        details['testRuns'].append({'nodeType': 'Test Case Run', 'name': 'Private failed run', 'result': 'Failed',
                                   'children': [{'nodeType': 'Failure Message', 'name': 'Private failed detail'}]})
        details['testRuns'].append({'nodeType': 'Test Case', 'name': 'Private nested test', 'result': 'Skipped',
                                   'children': [{'nodeType': 'Failure Message', 'name': 'Private nested detail'}]})
        code, row, _, output = self.runtime_report([
            '--path --schema --test-id', json.dumps(details_schema()), json.dumps(details)])
        self.assertEqual(code, 0)
        self.assertEqual(row['reason'], 'Observed runtime skip reason')
        self.assertNotIn('Private', output)

    def test_details_do_not_treat_run_names_or_other_fields_as_skip_reasons(self):
        details = skipped_details()
        details['testRuns'][0]['children'] = []
        details['testRuns'][0]['name'] = 'PRIVATE_RUN_NAME'
        details['testRuns'][0]['details'] = 'PRIVATE_DETAILS_VALUE'
        details['testDescription'] = 'PRIVATE_DESCRIPTION'
        code, row, _, output = self.runtime_report([
            '--path --schema --test-id', json.dumps(details_schema()), json.dumps(details)])
        self.assertEqual(code, 0)
        self.assertEqual(row['reason'], 'reason_unavailable')
        self.assertEqual(row['reason_detail'], 'details_reason_unavailable')
        self.assertNotIn('PRIVATE_', output)

    def test_details_node_depth_and_text_budgets_are_enforced(self):
        m = self.module()
        details = skipped_details()
        with patch.object(m, 'MAX_NODES', 1), self.assertRaisesRegex(ValueError, '^details_payload_unavailable$'):
            m.details_skip_reason(details_schema(), details, NATIVE, NATIVE_URL)
        for _ in range(70):
            details['testRuns'] = [{'nodeType': 'Test Case Run', 'name': 'wrapper', 'children': details['testRuns']}]
        with self.assertRaisesRegex(ValueError, '^details_payload_unavailable$'):
            m.details_skip_reason(details_schema(), details, NATIVE, NATIVE_URL)
        details = skipped_details()
        details['testRuns'][0]['children'][0]['name'] = '界\n' * 1000
        reason = m.details_skip_reason(details_schema(), details, NATIVE, NATIVE_URL)
        self.assertLessEqual(len(reason.encode()), 512)
        self.assertNotIn('\n', reason)

    def test_details_never_query_passed_failed_or_already_explained_skips(self):
        for status in ['Passed', 'Failed', 'Expected Failure']:
            with self.subTest(status=status):
                _, row, calls, _ = self.runtime_report([], tree=[case(result=status)])
                self.assertEqual(row, {'test': NATIVE, 'status': status})
                self.assertEqual(len(calls), 3)
        _, row, calls, _ = self.runtime_report([], tree=[case(result='Skipped', children=[
            {'nodeType': 'Failure Message', 'name': 'Tree skip reason'}])])
        self.assertEqual(row['reason'], 'Tree skip reason')
        self.assertEqual(row['reason_source'], 'tests_failure_message')
        self.assertEqual(len(calls), 3)

    def test_details_identifier_requires_the_selected_nodes_schema_field(self):
        m = self.module()
        for value in [None, 7, 'https://unrelated.example/private', 'test://com.apple.xcode/' + 'x' * 3000]:
            with self.subTest(value=value):
                tree = case(result='Skipped')
                tree['children'][0]['children'][0]['nodeIdentifierURL'] = value
                _, row, calls, output = self.runtime_report([], tree=[tree])
                self.assertEqual(row['status'], 'Skipped')
                self.assertEqual(row['reason_detail'], 'details_identifier_unavailable')
                self.assertEqual(len(calls), 3)
                self.assertNotIn('unrelated.example', output)
        bad_schema = schema(); del bad_schema['schemas']['TestNode']['properties']['nodeIdentifierURL']
        detail_ids = {}
        rows = m.analyze(bad_schema, {'testNodes': [case(result='Skipped')]}, (NATIVE,), detail_ids=detail_ids)
        self.assertEqual(rows[0]['status'], 'Skipped')
        self.assertEqual(detail_ids, {})

    def test_details_reject_cross_target_url_with_colliding_short_identifier(self):
        m = self.module()
        other_url = NATIVE_URL.replace('/VPlayeriOSTests/', '/OtherTests/')
        tree = case(result='Skipped')
        tree['children'][0]['children'][0]['nodeIdentifierURL'] = other_url
        details = skipped_details(); details['testIdentifierURL'] = other_url
        _, row, calls, output = self.runtime_report([
            '--path --schema --test-id', json.dumps(details_schema()), json.dumps(details)], tree=[tree])
        self.assertEqual(row['status'], 'Skipped')
        self.assertEqual(row['reason'], 'reason_unavailable')
        self.assertEqual(row['reason_detail'], 'details_identifier_unavailable')
        self.assertEqual(len(calls), 3)
        self.assertNotIn('OtherTests', output)
        with self.assertRaisesRegex(ValueError, '^details_identity_or_status_mismatch$'):
            m.details_skip_reason(details_schema(), details, NATIVE, other_url)

    def test_details_identifier_url_requires_exact_test_path_and_no_query_or_fragment(self):
        m = self.module()
        for value in [NATIVE_URL + '?extra=private', NATIVE_URL + '#private',
                      NATIVE_URL.replace('/IOSNativePictureInPictureTests/', '/OtherSuite/'),
                      NATIVE_URL.replace('RetainedSession()', 'OtherSession()')]:
            with self.subTest(value=value):
                tree = case(result='Skipped')
                tree['children'][0]['children'][0]['nodeIdentifierURL'] = value
                _, row, calls, _ = self.runtime_report([], tree=[tree])
                self.assertEqual(row['reason_detail'], 'details_identifier_unavailable')
                self.assertEqual(len(calls), 3)
        self.assertTrue(m.matches_test_identifier_url(NATIVE_URL.replace('()', '%28%29'), NATIVE))

    def test_details_queries_are_capped_at_four_selected_skips(self):
        m = self.module()
        identifiers = tuple('VPlayeriOSTests/FixtureTests/testCase' + str(i) for i in range(6))
        rows = [{'test': identifier, 'status': 'Skipped', 'reason': 'reason_unavailable'} for identifier in identifiers]
        ids = {identifier: 'test://com.apple.xcode/VPlayer/' + identifier for identifier in identifiers}
        with patch.object(m, 'run_bounded', side_effect=[
            '--path --schema --test-id', json.dumps(details_schema()),
            *[RuntimeError('xcresulttool_timeout') for _ in range(4)]]) as run:
            m.enrich_skip_reasons(Path('/local/tests.xcresult'), rows, ids)
        self.assertEqual(run.call_count, 6)
        self.assertTrue(all(row['status'] == 'Skipped' for row in rows))
        self.assertEqual([row['reason_detail'] for row in rows[-2:]], ['details_limit', 'details_limit'])

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
            self.assertEqual(summary.read_text().count('IOS_SELECTED_TEST_SCOPE='), 1)


class IOSSelectedStatusIsolationTests(unittest.TestCase):
    def test_contract_suite_cannot_append_to_an_inherited_ci_summary(self):
        with tempfile.TemporaryDirectory() as temp:
            summary = Path(temp) / 'ci-summary'
            summary.write_text('existing real CI evidence\n')
            environment = dict(os.environ, GITHUB_STEP_SUMMARY=str(summary))
            result = subprocess.run(
                [sys.executable, '-m', 'unittest',
                 'Scripts.Tests.test_ios_test_status_report.IOSSelectedStatusTests'],
                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(summary.read_text(), 'existing real CI evidence\n')


if __name__ == '__main__':
    unittest.main()
