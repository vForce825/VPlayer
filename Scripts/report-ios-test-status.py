#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Report selected iOS XCTest results, never logs, activities or attachments.

Default: functional unit/UI coverage. --benchmark: only the separate CPU benchmark.
For those modes, exit 0 means evidence was read completely, not that every test
passed. --preflight returns 0 only when both fixed regression tests are Passed.
Missing or unverified evidence exits 1. Skips and expected failures are never
counted as passes.
"""
import argparse
import html
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit

MAX_JSON = 8 * 1024 * 1024
MAX_OUTPUT = 16 * 1024
MAX_NODES = 25000
MAX_DEPTH = 64
MAX_SKIP_DETAILS = 4
MAX_DETAILS_JSON = 256 * 1024
KNOWN_RESULTS = frozenset({'Passed', 'Failed', 'Skipped', 'Expected Failure'})

# Immutable, explicit identities: missing tests remain visible in the report.
_FUNCTIONAL_SUITES = (
    ('VPlayeriOSTests', 'IOSVideoProcessingLifecycleTests', (
        'testApplicationNotificationsSynchronouslyCloseAndRestoreActualGPUAdmission',
        'testForegroundNotificationCannotOverrideAnActivePiPLease',)),
    ('VPlayeriOSTests', 'IOSPlayerControlsVisibilityTests', (
        'testCurrentIdleTimeoutHidesControlsAndLeavesNoTimer',
        'testBackgroundTapHidesAndRestoresControls',
        'testControlInteractionRefreshesTimeoutWithoutTogglingVisibility',
        'testPinningRevealsControlsAndRejectsTimeoutAcrossResume',
        'testRepeatedPlaybackUpdateDoesNotPostponeTimeout',
        'testDisappearanceInvalidatesTimeoutBeforeReappearance',
        'testOnlyUnobstructedActivePlaybackAllowsAutoHide',)),
    ('VPlayeriOSTests', 'IOSNativePictureInPictureTests', (
        'testRealSampleBufferPiPStartsRestoresAndClosesTheRetainedSession',)),
    ('VPlayeriOSTests', 'IOSPictureInPictureCoordinatorTests', (
        'testRetirementBeforeQueuedNativeStopCannotLeaveForegroundOnCPU',
        'testActiveAndStartingRetirementWaitForStopBeforeCreatingSuccessor',
        'testFactoryFailureClearsPresentationAndProcessingActivity',
        'testNativeFactoryCannotBypassActualRuntimeCapability',
        'testPlaybackInvalidationOnlyTargetsSampleBufferContent',
        'testRestoreIntentIsConsumedBeforeTheNextAutomaticPiPCycle',
        'testCallbackReferencePinsIdentityUntilTheActorHopFinishes',
        'testUnavailablePiPDoesNotStopThePlaybackTarget',
        'testUnownedControllerCannotPauseOrRestoreAnotherSession',
        'testCloseIsIdempotentAndLateDelegateStopDoesNotReopenSession',)),
    ('VPlayeriOSTests', 'IOSPlaybackSessionTests', (
        'testMinimizingAndRestoringKeepsSameModelAndRemoteStopRetiresSession',)),
    ('VPlayeriOSTests', 'VPlayerAppStartupTests', (
        'testSeededFixtureLaunchFlagIsHonoredOnlyInDebugBuilds',)),
    ('VPlayeriOSTests', 'PlaybackMetricsTests', (
        'testInactiveSignpostsDoNotCreateIntervalsOrAsyncLifetimes',
        'testSignpostFactoryOnlyEnablesDiagnosticBuilds',
        'testSignpostLifetimeFinishesExactlyOnceAcrossConcurrentCallbacks',)),
    ('VPlayeriOSTests', 'AdaptiveYADIFDiagnosticsTests', (
        'testOneSecondWindowAndModeChangeFlushHaveExactCountsAndWallTimes',
        'testManyCompletionsCollapseIntoOneWindowAndExplicitFlushResetsIt',
        'testCPUPhaseCallbackRunsOnceWithSeparateNonnegativeWallTimes',
        'testWorkerSummarySeparatesCPUServiceFromHeterogeneousWallTimesAndRequestedQoS',
        'testMissingWorkerCPUClockAndMissingSlotStayUnverifiedInsteadOfZeroService',
        'testWorkerWindowCountersExtremaAndContextResetAtOneSecondBoundary',
        'testWorkerWindowMarksMixedSurfaceContextsAndDoesNotInventMissingTelemetry',
        'testNativeThreadCPUClockProvidesValidNonnegativeElapsedService',)),
    ('VPlayeriOSTests', 'AdaptiveYADIFHandoffTests', (
        'testCPUProcessingTimingCallbackFollowsBuildConfiguration',
        'testDelayedGPUThenCPUThenForegroundGPUPreservesCompletionOrderAndPixels',
        'testCancellationDuringGPUFenceRetiresEachJobOnceAndRestoresAllThreeSlots',)),
    ('VPlayeriOSTests', 'VideoProcessingHandoffTests', (
        'testBackgroundClosesGPUAdmissionAndFenceJoinsActualCompletion',
        'testSecondBackgroundTransitionStillJoinsUnfinishedEarlierGPUWork',
        'testForegroundReturnsToGPUOnlyAfterPiPStops',
        'testRapidTransitionsDoNotStickInCPUOrBorrowLaterGPUFence',)),
    ('VPlayeriOSTests', 'IOSPlayerTransportAuthorityTests', (
        'testProductionDriverUsesTheControlledPlayerBoundary',
        'testPublicPiPTransportEntryPointsDoNotMutateBeforeAuthority',
        'testBurstControlsCoalesceAndLateLayerDetachPreservesNewOwner',
        'testRetiringTransportOwnerDiscardsQueuedIntents',)),
    ('VPlayeriOSTests', 'GPUSubmissionReturnTests', (
        'testEarlyCompletionWaitsForSubmissionReturnAndIsDeliveredOnce',
        'testDelayedGPUCompletionPublishesBeforeWaitingCPUSuccessor',)),
    ('VPlayeriOSTests', 'YADIFGoldenPixelTests', (
        'testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly',
        'testPlaybackDiagnosticPolicyExcludesSignpostsFromShippingRelease',
        'testCPUBenchmarkPeriodicFillMatchesOriginalFormulaAndPreservesPadding',
        'testNV12TFFMatchesPinnedOracleAndExactFieldRules',
        'testNV12BFFMatchesPinnedOracleAndExactFieldRules',
        'testP010TFFMatchesPinnedOracleAndExactStorageRules',
        'testP010BFFMatchesPinnedOracleAndExactStorageRules',)),
    ('VPlayeriOSTests', 'LumaScanProbeTests', (
        'testCPUScanMatchesActualMetalForBothDepthsRangesAndMotionPatterns',)),
    ('VPlayeriOSTests', 'LoopbackHTTPServerTests', (
        'testPausedCoverageWorkspaceReservesBeforeCompletionAndReleasesExactCharge',
        'testPausedResumeDecodePinsExcludeUnfetchedNoncontributingVideoHold',
        'testPausedCoverageWorkspaceRejectsExpandedPinsAndInvalidCapacities',
        'testPausedCoverageWorkspaceRejectsReentryWithoutInvalidatingOuterScope',
        'testPausedCoverageWorkspaceHardCapacityFailureDoesNotAllocateOrLosePins',
        'testPausedCoverageWorkspaceFrozenMissingInitializationCannotGainLaterCompletion',
        'testPausedWorkspaceMallocBuffersRespectAlignmentAndPhysicalPrechargeBoundaries',
        'testPausedWorkspacePartialAllocationFailureFreesEveryRawOwnerAndReservation',
        'testPausedWorkspaceRollbackKeepsExactChargeWhenAnUnrelated16KiBOwnerRetires',
        'testPausedWorkspaceChargeSurvivesUntilTheFinalWorkspaceAliasIsReleased',)),
    ('VPlayeriOSTests', 'HLSAVPlayerBackendTests', (
        'testSyntheticHLG50AC3OriginalAACFragmentsDecodeContinuously',
        'testHandoffMediaObservationWaitsThroughProbeAndClearForCurrentOutput',
        'testHandoffMediaObservationRejectsMissingOutputFailureAndChangedIdentity',
        'testProductionHLSRouteHandoffClearsMediaAndRejectsOldCallbacksAfterSampleBuffer',)),
    ('VPlayeriOSTests', 'NativeHLSAdapterLifecycleTests', (
        'testNativeFinalQuantumAcceptsObservedClocksAndRejectsPrematureOrMissingEvidence',
        'testNativeFinalQuantumPreservesAtOrAfterEndpointClocks',
        'testNativeFinalQuantumRejectsMalformedPeriodsAtAndAfterEndpoint',)),
    ('VPlayeriOSTests', 'NativeHLSMasterSmokeTests', (
        'testRealNativeAndManagedHLSReachVerifiedUntrimmedEOF',
        'testNativeEOSStableOvershootKeepsOriginalItemAndAuthority',
        'testNativeEOSOvershootCannotBypassTransportOrAuthorityFailures',
        'testNativeEOSOriginalDeadlineRejectsUnsettledTransportAndInvalidEvidence',)),
    ('VPlayeriOSUITests', 'IOSLibraryFlowTests', (
        'testTouchChannelSelectionCloseAndReopen',
        'testSourceEditorCancelAndReopen',
        'testPlaylistEditOpensExistingSourceWithoutDeletingIt',
        'testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation',
        'testDeletionCancellationGeometryUsesOnlyObservedExteriorSpace',
        'testRotationAndPlaybackSettingsKeepPlayerSession',
        'testPlaybackControlsBackgroundTapAndIdleTimeoutPreserveSession',
        'testPlaybackControlTapsAndSettingsDoNotToggleBackgroundOrStopSession',
        'testHiddenPlaybackControlsCanBeRevealedAfterRotation',
        'testForegroundReturnRevealsControlsAndStartsFreshIdleTimeout',
        'testPlaybackFailureKeepsControlsAndExitVisible',)),
)
DEFAULT_TESTS = tuple(f'{target}/{suite}/{method}'
                      for target, suite, methods in _FUNCTIONAL_SUITES for method in methods)
BENCHMARK_TESTS = (
    'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFBenchmarkReportsNativeHostMeasurementsWithoutDeviceQualification',
    'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly',
    'VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testPlaybackDiagnosticPolicyExcludesSignpostsFromShippingRelease',
)
PREFLIGHT_TESTS = (
    'VPlayeriOSTests/IOSPictureInPictureCoordinatorTests/testRetirementBeforeQueuedNativeStopCannotLeaveForegroundOnCPU',
    'VPlayeriOSUITests/IOSLibraryFlowTests/testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation',
)


def run_bounded(command, timeout=30, limit=MAX_JSON):
    """Bound both pipes while reading; do not buffer arbitrary stderr or raw logs."""
    deadline = time.monotonic() + timeout
    chunks = {0: bytearray(), 1: bytearray()}
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as reader:
            reader.register(process.stdout, selectors.EVENT_READ, 0)
            reader.register(process.stderr, selectors.EVENT_READ, 1)
            while reader.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('xcresulttool_timeout')
                for key, _ in reader.select(min(remaining, 0.1)):
                    index = key.data
                    maximum = limit if index == 0 else 65536
                    chunk = os.read(key.fileobj.fileno(), min(65536, maximum - len(chunks[index]) + 1))
                    if not chunk:
                        reader.unregister(key.fileobj)
                        continue
                    if len(chunks[index]) + len(chunk) > maximum:
                        raise RuntimeError('xcresulttool_output_limit')
                    chunks[index].extend(chunk)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('xcresulttool_timeout')
            if process.wait(timeout=remaining) != 0:
                raise RuntimeError('xcresulttool_nonzero_exit')
        return chunks[0].decode('utf-8')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def resolve(document, declaration):
    seen = set()
    while isinstance(declaration, dict) and '$ref' in declaration:
        reference = declaration['$ref']
        if not isinstance(reference, str) or not reference.startswith('#/') or reference in seen:
            raise ValueError('unsupported_schema_reference')
        seen.add(reference)
        if len(seen) > MAX_DEPTH:
            raise ValueError('schema_reference_limit')
        declaration = document
        for component in reference[2:].split('/'):
            component = component.replace('~1', '/').replace('~0', '~')
            if not isinstance(declaration, dict) or component not in declaration:
                raise ValueError('missing_schema_reference')
            declaration = declaration[component]
    if not isinstance(declaration, dict):
        raise ValueError('invalid_schema_declaration')
    return declaration


def schema_properties(document, root_name):
    if not isinstance(document, dict):
        raise ValueError('invalid_schema')
    root = document
    if '$ref' not in root and 'properties' not in root:
        candidates = []
        for namespace in ('schemas', '$defs', 'definitions'):
            if namespace not in document:
                continue
            definitions = document[namespace]
            if not isinstance(definitions, dict):
                raise ValueError('invalid_schema_definitions')
            if root_name in definitions:
                candidates.append(definitions[root_name])
        if root_name in document:
            candidates.append(document[root_name])
        if len(candidates) != 1:
            raise ValueError('missing_or_ambiguous_tests_schema')
        root = candidates[0]
    root = resolve(document, root)
    if root.get('type') != 'object':
        raise ValueError('unsupported_tests_schema')
    root_properties = root.get('properties')
    if not isinstance(root_properties, dict):
        raise ValueError('invalid_schema_properties')
    return root_properties


def verified_schema(document, root_name='Tests', nodes_field='testNodes'):
    root_properties = schema_properties(document, root_name)
    array = resolve(document, root_properties.get(nodes_field))
    if array.get('type') != 'array':
        raise ValueError('unsupported_test_nodes_schema')
    node = resolve(document, array.get('items'))
    if node.get('type') != 'object':
        raise ValueError('unsupported_test_node_schema')
    properties = node.get('properties')
    if not isinstance(properties, dict):
        raise ValueError('invalid_schema_properties')
    fields = {key: resolve(document, properties.get(key))
              for key in ('nodeType', 'name', 'nodeIdentifier', 'result', 'children')}
    if any(fields[key].get('type') != 'string'
           for key in ('nodeType', 'name', 'nodeIdentifier', 'result')):
        raise ValueError('unsupported_scalar_schema')
    child = fields['children']
    if child.get('type') != 'array' or resolve(document, child.get('items')) != node:
        raise ValueError('unsupported_children_schema')
    def optional_enum(field):
        if 'enum' not in field:
            return None
        values = field['enum']
        if not isinstance(values, list) or not all(isinstance(x, str) for x in values):
            raise ValueError('unsupported_status_schema')
        return frozenset(values)
    return optional_enum(fields['nodeType']), optional_enum(fields['result'])


def short_text(value, limit=512):
    return ''.join(c if c >= ' ' else ' ' for c in value).encode('utf-8')[:limit].decode('utf-8', 'ignore')


def matches_test_identifier_url(value, identifier):
    if not isinstance(value, str) or len(value) > 2048 or any(c < ' ' or c == '\x7f' for c in value):
        return False
    try:
        parts = urlsplit(value)
        path = unquote(parts.path, errors='strict').removesuffix('()')
        return (parts.scheme == 'test' and parts.netloc == 'com.apple.xcode'
                and not parts.query and not parts.fragment and path.endswith('/' + identifier))
    except ValueError:
        return False


def branch_facts(node):
    reasons, attempts = [], []
    stack = [(child, node.get('result')) for child in node.get('children', [])]
    while stack:
        child, inherited = stack.pop()
        if child['nodeType'] == 'Test Case':
            continue
        state = child.get('result', inherited)
        if 'result' in child or child['nodeType'] in {'Repetition', 'Test Case Run', 'Arguments'}:
            attempts.append(child.get('result'))
        if child['nodeType'] == 'Failure Message' and state == 'Skipped':
            message = short_text(child['name'])
            if message and message not in reasons:
                reasons.append(message)
        stack.extend((item, state) for item in child.get('children', []))
    return reasons, attempts


def analyze(schema, data, manifest=DEFAULT_TESTS, detail_ids=None):
    node_types, results = verified_schema(schema)
    identifier_supported = False
    if detail_ids is not None:
        properties = schema_properties(schema, 'Tests')
        array = resolve(schema, properties['testNodes'])
        node = resolve(schema, array['items'])
        declaration = node['properties'].get('nodeIdentifierURL')
        if declaration is not None:
            try:
                identifier_supported = resolve(schema, declaration).get('type') == 'string'
            except ValueError:
                pass
    if not isinstance(data, dict) or not isinstance(data.get('testNodes'), list):
        raise ValueError('invalid_test_tree')
    found = {identifier: [] for identifier in manifest}
    stack = [(node, None, 0) for node in data['testNodes']]
    count = 0
    while stack:
        node, target, depth = stack.pop()
        count += 1
        if count > MAX_NODES or depth > MAX_DEPTH:
            raise ValueError('test_tree_limit')
        if (not isinstance(node, dict) or not isinstance(node.get('nodeType'), str)
                or (node_types is not None and node['nodeType'] not in node_types)
                or not isinstance(node.get('name'), str)):
            raise ValueError('invalid_test_node')
        children = node.get('children', [])
        if not isinstance(children, list):
            raise ValueError('invalid_test_children')
        if node['nodeType'] in {'Unit test bundle', 'UI test bundle'}:
            target = node['name']
        if node['nodeType'] == 'Test Case':
            identifier = node.get('nodeIdentifier')
            if target is not None and isinstance(identifier, str) and len(identifier) <= 2048:
                identifier = identifier.removesuffix('()')
                full = identifier if identifier.startswith(target + '/') else target + '/' + identifier
                if full in found:
                    found[full].append(node)
        stack.extend((child, target, depth + 1) for child in children)
    rows = []
    for identifier in manifest:
        row = {'test': identifier, 'status': 'Unverified'}
        candidates = found[identifier]
        if not candidates:
            row['reason'] = 'missing'
        elif len(candidates) != 1:
            row['reason'] = 'duplicate_identity'
        else:
            node = candidates[0]
            state = node.get('result')
            if (not isinstance(state, str) or (results is not None and state not in results)
                    or state not in KNOWN_RESULTS):
                row['reason'] = 'unknown_or_missing_result'
            else:
                reasons, attempts = branch_facts(node)
                if state == 'Passed' and any(attempt != 'Passed' for attempt in attempts):
                    row['reason'] = 'non_passing_or_unknown_attempt'
                else:
                    row['status'] = state
                    if state == 'Skipped':
                        row['reason'] = short_text('; '.join(reasons)) if reasons else 'reason_unavailable'
                        detail_id = node.get('nodeIdentifierURL')
                        if identifier_supported and matches_test_identifier_url(detail_id, identifier):
                            detail_ids[identifier] = detail_id
        rows.append(row)
    return rows


def verified_details_schema(schema):
    fields = schema_properties(schema, 'TestDetails')
    for name in ('testIdentifier', 'testIdentifierURL', 'testResult'):
        declaration = resolve(schema, fields.get(name))
        if declaration.get('type') != 'string':
            raise ValueError('unsupported_details_scalar_schema')
        if name == 'testResult' and 'enum' in declaration:
            values = declaration['enum']
            if (not isinstance(values, list) or not all(isinstance(value, str) for value in values)
                    or 'Skipped' not in values):
                raise ValueError('unsupported_details_result_schema')
    return verified_schema(schema, 'TestDetails', 'testRuns')


def details_skip_reason(schema, data, identifier, detail_id):
    node_types, results = verified_details_schema(schema)
    if (not matches_test_identifier_url(detail_id, identifier)
            or not isinstance(data, dict) or data.get('testIdentifierURL') != detail_id
            or data.get('testResult') != 'Skipped'
            or not isinstance(data.get('testIdentifier'), str)
            or data['testIdentifier'].removesuffix('()') not in {identifier, identifier.split('/', 1)[1]}):
        raise ValueError('details_identity_or_status_mismatch')
    if not isinstance(data.get('testRuns'), list):
        raise ValueError('details_payload_unavailable')
    reasons, count = [], 0
    stack = [(node, True, 0) for node in data['testRuns']]
    while stack:
        node, skipped_branch, depth = stack.pop()
        count += 1
        if (count > MAX_NODES or depth > MAX_DEPTH or not isinstance(node, dict)
                or not isinstance(node.get('nodeType'), str) or not isinstance(node.get('name'), str)
                or (node_types is not None and node['nodeType'] not in node_types)
                or not isinstance(node.get('children', []), list)):
            raise ValueError('details_payload_unavailable')
        if 'result' in node:
            state = node['result']
            if (not isinstance(state, str) or state not in KNOWN_RESULTS
                    or (results is not None and state not in results)):
                raise ValueError('details_payload_unavailable')
            skipped_branch = skipped_branch and state == 'Skipped'
        # A nested test belongs to a different identity, even if its result is Skipped.
        skipped_branch = skipped_branch and node['nodeType'] != 'Test Case'
        if skipped_branch and node['nodeType'] == 'Failure Message':
            message = short_text(node['name']).strip()
            if message and message not in reasons:
                reasons.append(message)
        stack.extend((child, skipped_branch, depth + 1) for child in node.get('children', []))
    return short_text('; '.join(reasons)) if reasons else None


def enrich_skip_reasons(bundle, rows, detail_ids):
    """Query only public metadata in this local bundle; never open logs or URLs."""
    candidates = []
    for row in rows:
        if row['status'] != 'Skipped':
            continue
        if row.get('reason') != 'reason_unavailable':
            row['reason_source'] = 'tests_failure_message'
            continue
        row['reason_source'] = 'unavailable'
        if row['test'] not in detail_ids:
            row['reason_detail'] = 'details_identifier_unavailable'
        elif len(candidates) >= MAX_SKIP_DETAILS:
            row['reason_detail'] = 'details_limit'
        else:
            candidates.append(row)
    if not candidates:
        return
    failures = (ValueError, RuntimeError, OSError, RecursionError, subprocess.TimeoutExpired)
    command = ['xcrun', 'xcresulttool', 'get', 'test-results', 'test-details']
    diagnostic = 'details_help_unavailable'
    try:
        help_text = run_bounded(['xcrun', 'xcresulttool', 'help', 'get', 'test-results', 'test-details'],
                                timeout=10, limit=MAX_DETAILS_JSON)
        if any(option not in help_text for option in ('--path', '--schema', '--test-id')):
            raise ValueError('unsupported_details_options')
        diagnostic = 'details_schema_unavailable'
        schema = json.loads(run_bounded(command + ['--schema'], timeout=10, limit=MAX_DETAILS_JSON))
        verified_details_schema(schema)
    except failures:
        for row in candidates:
            row['reason_detail'] = diagnostic
        return
    for row in candidates:
        detail_id = detail_ids[row['test']]
        try:
            data = json.loads(run_bounded(command + ['--path', str(bundle), '--test-id', detail_id],
                                           timeout=10, limit=MAX_DETAILS_JSON))
        except failures:
            row['reason_detail'] = 'details_read_unavailable'
            continue
        try:
            reason = details_skip_reason(schema, data, row['test'], detail_id)
        except failures as error:
            row['reason_detail'] = ('details_identity_or_status_mismatch'
                                    if str(error) == 'details_identity_or_status_mismatch'
                                    else 'details_payload_unavailable')
            continue
        if reason:
            row['reason'] = reason
            row['reason_source'] = 'test_details_failure_message'
        else:
            row['reason_detail'] = 'details_reason_unavailable'


def report_lines(rows, mode, shape=None):
    counts = {status: sum(row['status'] == status for row in rows)
              for status in ('Passed', 'Failed', 'Skipped', 'Expected Failure', 'Unverified')}
    lines = ['IOS_SELECTED_TEST_SCOPE=' + mode,
             'IOS_SELECTED_TEST_COUNTS=' + json.dumps(counts, sort_keys=True, separators=(',', ':')),
             'IOS_SELECTED_TEST_QUALIFICATION=simulator_evidence_only;physical_iphone_not_qualified']
    if shape is not None:
        lines.append('IOS_SELECTED_TEST_SCHEMA_SHAPE=' + json.dumps(shape, ensure_ascii=True, sort_keys=True, separators=(',', ':')))
    size = sum(len(line.encode('utf-8')) + 1 for line in lines)
    for index, row in enumerate(rows):
        clean = {key: short_text(value, 2048 if key == 'test' else 512) for key, value in row.items()}
        line = 'IOS_SELECTED_TEST ' + json.dumps(clean, ensure_ascii=True, sort_keys=True, separators=(',', ':'))
        length = len(line.encode('utf-8')) + 1
        if size + length + 128 > MAX_OUTPUT:
            lines.append('IOS_SELECTED_TEST_OUTPUT_TRUNCATED=' + str(len(rows) - index))
            break
        lines.append(line)
        size += length
    return lines


def job_summary(lines):
    prefix, suffix = '\n<pre><code>\n', '</code></pre>\n'
    parts = [prefix]
    size = len((prefix + suffix).encode())
    for line in lines:
        escaped = html.escape(line, quote=False) + '\n'
        if size + len(escaped.encode()) + 128 > MAX_OUTPUT:
            parts.append('IOS_SELECTED_TEST_SUMMARY_TRUNCATED=1\n')
            break
        parts.append(escaped)
        size += len(escaped.encode())
    return ''.join(parts) + suffix


def emit(rows, mode, shape=None):
    lines = report_lines(rows, mode, shape)
    print('\n'.join(lines), flush=True)
    destination = os.environ.get('GITHUB_STEP_SUMMARY')
    if destination:
        try:
            with open(destination, 'a', encoding='utf-8') as output:
                output.write(job_summary(lines))
        except OSError:
            print('IOS_SELECTED_TEST_SUMMARY_UNAVAILABLE=write_failed', file=sys.stderr)


def schema_shape(document):
    """Bounded names/types only, never schema values or result contents."""
    def kind(value):
        if isinstance(value, dict): return 'object'
        if isinstance(value, list): return 'array'
        if isinstance(value, str): return 'string'
        if value is None: return 'null'
        if isinstance(value, bool): return 'boolean'
        if isinstance(value, (int, float)): return 'number'
        return 'unknown'
    result = {'root_type': kind(document), 'root_fields': {}}
    if isinstance(document, dict):
        for name in sorted(document)[:16]:
            field = short_text(name, 40)
            result['root_fields'][field] = kind(document[name])
            if len(json.dumps(result, ensure_ascii=True).encode()) > 1000:
                del result['root_fields'][field]
                break
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument('--benchmark', action='store_true', help='Report only the separate Release CPU benchmark')
    scope.add_argument('--preflight', action='store_true', help='Require both fixed regression preflight tests to pass')
    args = parser.parse_args(argv)
    manifest = BENCHMARK_TESTS if args.benchmark else DEFAULT_TESTS
    mode = 'cpu_benchmark' if args.benchmark else 'functional_unit_and_ui'
    if args.preflight:
        manifest, mode = PREFLIGHT_TESTS, 'regression_preflight'
    schema, shape = None, None
    try:
        if args.bundle.suffix != '.xcresult' or not args.bundle.is_dir():
            raise ValueError('bundle_missing')
        help_text = run_bounded(['xcrun', 'xcresulttool', 'help', 'get', 'test-results', 'tests'])
        if '--path' not in help_text or '--schema' not in help_text:
            raise ValueError('installed_tests_schema_unavailable')
        schema = json.loads(run_bounded(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--schema']))
        try:
            verified_schema(schema)
        except (ValueError, RecursionError):
            shape = schema_shape(schema)
            raise
        data = json.loads(run_bounded(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(args.bundle)]))
        detail_ids = {}
        rows = analyze(schema, data, manifest, detail_ids=detail_ids)
        enrich_skip_reasons(args.bundle, rows, detail_ids)
    except (ValueError, RuntimeError, OSError, RecursionError, subprocess.TimeoutExpired) as error:
        # Do not publish stderr, payloads, paths, environment or arbitrary exceptions.
        reason = str(error) if isinstance(error, (ValueError, RuntimeError)) and re_safe(str(error)) else type(error).__name__
        rows = [{'test': identifier, 'status': 'Unverified', 'reason': reason} for identifier in manifest]
    emit(rows, mode, shape)
    if args.preflight:
        return int(any(row['status'] != 'Passed' for row in rows))
    return int(any(row['status'] == 'Unverified' for row in rows))


def re_safe(value):
    return bool(value) and len(value) <= 64 and all(c in 'abcdefghijklmnopqrstuvwxyz_' for c in value)


if __name__ == '__main__':
    raise SystemExit(main())
