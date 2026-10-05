#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt trigger, exact-head, cap and preserved-gate contracts; no native evidence."""
from pathlib import Path
import fnmatch
import json
import os
import re
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class WorkflowContracts(unittest.TestCase):
    def test_acceptance_listener_is_configured_before_start_and_smoke_is_selected(self):
        support=(ROOT/'Tests/VPlayerHLSAcceptanceTests/AcceptanceMediaSupport.swift').read_text()
        server=support.split('final class AcceptanceHTTPServer:',1)[1].split('private final class AcceptanceSourceFeed:',1)[0]
        self.assertLess(server.index('listener.newConnectionHandler ='),server.index('listener.start(queue:'))
        controls=(ROOT/'Tests/VPlayerHLSAcceptanceTests/AcceptanceNativeControlTests.swift').read_text()
        selected=controls.split('func testNativeObservationControlsRejectFiveFaults()',1)[1]
        self.assertIn('try await checkSourceServerFirstRequest()',selected)

    def test_canonical_native_decode_control_precedes_five_fault_controls(self):
        native=(ROOT/'Tests/VPlayerHLSAcceptanceTests/AcceptanceNativeControlTests.swift').read_text()
        selected=native.split('func testNativeObservationControlsRejectFiveFaults()',1)[1]
        self.assertIn('try await checkCanonicalVideoDecode()',selected)
        self.assertLess(selected.index('checkCanonicalVideoDecode()'),selected.index('positive:'))
        self.assertIn('if entry == canonical { throw error }',native)
        self.assertIn('guard count > 0, count == timed.count',native)
        self.assertNotIn('XCTAssertEqual(count, timed.count',native)
        self.assertNotIn('XCTUnwrap(capture.finish().first)',native)
        self.assertNotIn('XCTUnwrap(tracks.first)',native)
        self.assertNotIn('XCTAssertEqual(captured.inits',native)
        generator=(ROOT/'Scripts/generate-hls-acceptance-fixture.py').read_text()
        for fixture in ['control-avc.h264','control-hevc.h265']:
            self.assertIn(fixture,native);self.assertIn(fixture,generator)

    def test_xcode_version_checks_drain_output_and_preserve_producer_failure(self):
        paths=list((ROOT/'.github/workflows').glob('*.yml'))
        paths.append(ROOT/'Scripts/run-persistent-hls-acceptance.sh')
        checks=[]
        for path in paths:
            text=path.read_text()
            if 'xcodebuild -version' not in text: continue
            self.assertNotRegex(text,r'xcodebuild -version\s*\|\s*head',path.name)
            pairs=re.findall(r'(?m)^\s*(xcode_version="\$\(xcodebuild -version\)")\n\s*(test [^\n]+)',text)
            self.assertTrue(pairs,path.name)
            checks.extend('\n'.join(pair) for pair in pairs)
        with tempfile.TemporaryDirectory() as temporary:
            tool=Path(temporary)/'xcodebuild'
            tool.write_text('#!/bin/sh\nprintf "Xcode %s\\nBuild version 27A123\\n" "${MOCK_XCODE_VERSION:-27.0}"\nexit "${MOCK_XCODE_STATUS:-0}"\n')
            tool.chmod(0o755)
            env={**os.environ,'PATH':temporary+os.pathsep+os.environ['PATH']}
            for check in checks:
                for extra,expected in [({},0),({'MOCK_XCODE_STATUS':'7'},7),({'MOCK_XCODE_VERSION':'26.0'},1)]:
                    result=subprocess.run(['bash','-e','-o','pipefail','-c',check],env={**env,**extra},capture_output=True,text=True)
                    self.assertEqual(result.returncode,expected,result.stderr)

    def test_six_full_gates_remain_independent_and_check_true_candidate(self):
        text=(ROOT/'.github/workflows/macos-ci.yml').read_text()
        jobs=re.findall(r'^  ([a-z][a-z-]+):$',text.split('jobs:',1)[1],re.M)
        self.assertEqual(set(jobs),{'complete-tests','release-contracts','sanitizer-validation',
            'artifact-validation','fixture-validation','compiler-controls'})
        self.assertEqual(text.count('ref: ${{ github.event.pull_request.head.sha || github.sha }}'),6)
        self.assertEqual(text.count('echo "ACCEPTANCE_TREE='),6)
        self.assertNotRegex(text,re.compile(r'^    (?:if|needs):',re.M))
        self.assertNotIn('migration/tvos27',text)
        normal=text.split('  complete-tests:',1)[1].split('  release-contracts:',1)[0]
        self.assertIn('./Scripts/test.sh -configuration Debug',normal)
        self.assertNotIn('-only-testing:',normal)

    def test_checkpoints_do_not_run_tests_and_preparation_requires_explicit_workflow_edit(self):
        for path in (ROOT/'.github/workflows').glob('*.yml'):
            text=path.read_text()
            if '  push:' in text:
                block=text.split('  push:',1)[1].split('\n\n',1)[0]
                self.assertEqual(path.name,'hls-project-generation.yml')
                self.assertIn('branches: [work/homepod-hls-rebuild]',block,path.name)
                self.assertIn('    paths:\n      - .github/workflows/hls-project-generation.yml',block,path.name)
                self.assertNotIn('branches-ignore',block,path.name)
                self.assertNotIn('test.sh',text,path.name)
            else:
                self.assertNotIn('work/homepod-hls-rebuild',text,path.name)

    def test_exact_old_writer_is_fetched_independently_of_deleted_branches(self):
        text=(ROOT/'Scripts/run-hls-baseline-and-candidate.sh').read_text()
        self.assertIn('old=36f9f00044db05b707e25ea470b0da3cec62682c',text)
        self.assertIn('git fetch --no-write-fetch-head origin "$old"',text)
        self.assertLess(text.index('git fetch --no-write-fetch-head origin "$old"'),text.index('freeze-ineligible'))
        self.assertNotIn('git worktree add',text)
        self.assertNotIn('--record-baseline',text)
        self.assertIn('git rev-parse --verify "$old^{commit}"',text)

    def test_ineligible_policy_is_frozen_and_checked_before_candidate_execution(self):
        script=(ROOT/'Scripts/run-hls-baseline-and-candidate.sh').read_text()
        self.assertLess(script.index('freeze-ineligible'),script.index('chmod a-w'))
        self.assertLess(script.index('chmod a-w'),script.index('--ineligible-baseline'))
        self.assertNotIn('set +e',script)
        runner=(ROOT/'Scripts/run-persistent-hls-acceptance.sh').read_text()
        self.assertLess(runner.index('check-ineligible'),runner.index('xcodebuild build-for-testing'))
        self.assertIn('Frozen ineligibility/policy changed during candidate.',runner)
        self.assertIn('validate-absolute',runner)
        self.assertIn('validate "$output" --baseline "$baseline"',runner)

    def test_acceptance_path_filters_and_manual_final_dispatch(self):
        text=(ROOT/'.github/workflows/hls-acceptance.yml').read_text()
        patterns=re.findall(r"^      - '([^']+)'$",text,re.M)
        matches=lambda path:any(fnmatch.fnmatch(path,pattern) for pattern in patterns)
        for path in ['README.md','LICENSE','docs/local.md']:self.assertFalse(matches(path),path)
        for path in ['Sources/VPlayerPlayback/HLS/SegmentedFMP4Writer.swift','Sources/VPlayerApp/AppDependencies.swift',
            'project.yml','Tests/Fixtures/SourcePlanning/master.m3u8','Mintfile','.github/workflows/hls-acceptance.yml']:
            self.assertTrue(matches(path),path)
        self.assertIn('  workflow_dispatch:',text);self.assertNotIn('needs:',text)

    def test_five_minute_is_only_plan_and_not_normal_discovery(self):
        plan=json.loads((ROOT/'VPlayerHLSAcceptance.xctestplan').read_text())
        self.assertEqual([config['name'] for config in plan['configurations']],['FiveMinute'])
        normal=(ROOT/'project.yml').read_text().split('schemes:',1)[1].split('  VPlayerReleaseBoundaryTests:',1)[0]
        self.assertNotIn('HLSAcceptance',normal)
        runner=(ROOT/'Scripts/run-persistent-hls-acceptance.sh').read_text()
        self.assertIn('[[ "$duration" == 300 ]]',runner)
        self.assertNotIn('3600',runner);self.assertNotIn('OneHour',runner)

    def test_short_native_controls_run_before_baseline(self):
        script=(ROOT/'Scripts/run-hls-baseline-and-candidate.sh').read_text()
        self.assertLess(script.index('--controls-only'),script.index('freeze-ineligible'))
        self.assertLess(script.index('freeze-ineligible'),script.index('--ineligible-baseline'))
        runner=(ROOT/'Scripts/run-persistent-hls-acceptance.sh').read_text()
        self.assertIn('AcceptanceNativeControlTests/testNativeObservationControlsRejectFiveFaults',runner)
        self.assertIn('persistent_hls_acceptance.py controls "$work/native.log"',runner)
        self.assertIn('-xctestrun "$xctestrun"',runner)
        self.assertNotIn('-xctestrun "$work/acceptance.xctestrun"',runner)

    def test_verified_host_tools_precede_app_build(self):
        for name in ['macos-ci.yml','hls-acceptance.yml','hls-project-generation.yml']:
            if name=='hls-project-generation.yml' and not (ROOT/'.github/workflows'/name).exists():
                continue # Temporary preparation workflow is removed after genuine readback.
            text=(ROOT/'.github/workflows'/name).read_text()
            blocks=text.split('          brew install mint jq ripgrep pkgconf x264 x265 nasm\n')[1:]
            self.assertTrue(blocks,name)
            for block in blocks:
                self.assertLess(block.index('./Scripts/provision-hls-fixture-toolchain.sh'),block.index('./Scripts/verify-hls-fixture-toolchain.sh'))
                self.assertLess(block.index('./Scripts/verify-hls-fixture-toolchain.sh'),block.index('./ci_scripts/ci_post_clone.sh'))
            self.assertNotIn('/opt/homebrew/Cellar/ffmpeg',text)

    def test_final_inputs_are_verified_without_regenerating_cenc(self):
        full=(ROOT/'.github/workflows/macos-ci.yml').read_text()
        self.assertEqual(full.count('./Scripts/prepare-hls-ci-fixtures.sh --verify-committed\n          ./Scripts/bootstrap.sh --check'),5)
        self.assertNotIn('--project-readback',full)
        self.assertIn('./Scripts/prepare-hls-ci-fixtures.sh --acceptance',(ROOT/'.github/workflows/hls-acceptance.yml').read_text())
        generation=ROOT/'.github/workflows/hls-project-generation.yml'
        if generation.exists():
            self.assertIn('./Scripts/prepare-hls-ci-fixtures.sh --project-readback',generation.read_text())
        prep=(ROOT/'Scripts/prepare-hls-ci-fixtures.sh').read_text()
        self.assertIn('git diff --exit-code HEAD -- Tests/Fixtures/SourcePlanning',prep)
        self.assertIn('if [[ "$mode" == --acceptance ]]',prep)
        self.assertIn('yonaskolb/XcodeGen@2.44.1',(ROOT/'Scripts/bootstrap.sh').read_text())

if __name__=='__main__':unittest.main()
