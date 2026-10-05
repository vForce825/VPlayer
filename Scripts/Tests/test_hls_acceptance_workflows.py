#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt trigger, exact-head, cap and preserved-gate contracts; no native evidence."""
from pathlib import Path
import fnmatch
import json
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]

class WorkflowContracts(unittest.TestCase):
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

    def test_durability_branch_push_never_triggers_ci(self):
        for path in (ROOT/'.github/workflows').glob('*.yml'):
            text=path.read_text()
            self.assertNotIn('work/homepod-hls-rebuild',text,path.name)
            if '  push:' in text:
                block=text.split('  push:',1)[1].split('\n\n',1)[0]
                self.assertIn('branches: [feat/homepod-hls-evolution]',block,path.name)
                self.assertNotIn('branches-ignore',block,path.name)

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
        self.assertLess(script.index('--controls-only'),script.index('git worktree add'))
        self.assertLess(script.index('--controls-only'),script.index('--record-baseline'))
        runner=(ROOT/'Scripts/run-persistent-hls-acceptance.sh').read_text()
        self.assertIn('AcceptanceNativeControlTests/testNativeObservationControlsRejectFiveFaults',runner)
        self.assertIn('persistent_hls_acceptance.py controls "$work/native.log"',runner)
        self.assertIn('-xctestrun "$xctestrun"',runner)
        self.assertNotIn('-xctestrun "$work/acceptance.xctestrun"',runner)

    def test_verified_host_tools_precede_app_build(self):
        for name in ['macos-ci.yml','hls-acceptance.yml','hls-project-generation.yml']:
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
        self.assertIn('./Scripts/prepare-hls-ci-fixtures.sh --project-readback',(ROOT/'.github/workflows/hls-project-generation.yml').read_text())
        prep=(ROOT/'Scripts/prepare-hls-ci-fixtures.sh').read_text()
        self.assertIn('git diff --exit-code HEAD -- Tests/Fixtures/SourcePlanning',prep)
        self.assertIn('if [[ "$mode" == --acceptance ]]',prep)
        self.assertIn('yonaskolb/XcodeGen@2.44.1',(ROOT/'Scripts/bootstrap.sh').read_text())

if __name__=='__main__':unittest.main()
