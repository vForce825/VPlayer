#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class IOSWorkflowTests(unittest.TestCase):
    def test_separate_workflow_preserves_exact_head_and_no_push_trigger(self):
        path=ROOT/'.github/workflows/ios-ci.yml'
        self.assertTrue(path.exists(),'iOS native validation workflow is missing')
        text=path.read_text()
        self.assertIn('pull_request:',text);self.assertIn('workflow_dispatch:',text)
        self.assertNotIn('push:',text)
        self.assertIn('github.event.pull_request.head.sha || github.sha',text)
        self.assertIn('--platform ios',text)
        self.assertIn('generic/platform=iOS',text)
        self.assertIn('Scripts/test-ios.sh',text)
        self.assertIn('needs_refresh',text)
        self.assertIn('contents: read',text)
    def test_short_generation_readback_gates_expensive_native_acceptance(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('  generated-inputs:',text)
        self.assertIn('needs: generated-inputs',text)
        self.assertIn("needs.generated-inputs.outputs.needs_refresh == 'false'",text)
        self.assertIn("if: steps.generated.outputs.needs_refresh == 'true'",text)
        self.assertLess(text.index('name: Fail closed until generated outputs are committed'),
                        text.index('  ios-tests:'))
        self.assertEqual(text.count('xcodegen generate --spec project.yml'),1)
    def test_native_configurations_are_independent_but_still_fail_the_job(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('id: prepare', text)
        self.assertIn('id: simulator', text)
        guard="if: always() && !cancelled() && steps.prepare.outcome == 'success' && steps.simulator.outcome == 'success'"
        self.assertEqual(text.count(guard), 5)
        self.assertIn("steps.release_build.outcome == 'success'", text)
        self.assertIn("--build-only", text)
        self.assertNotIn('continue-on-error', text)
    def test_shared_fixtures_and_release_measurement_are_required(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('prepare-hls-ci-fixtures.sh --verify-committed',text)
        self.assertIn("steps.fixtures.outcome == 'success'",text)
        self.assertIn('synthetic-hlg50-ac3-64s.ts',text)
        self.assertIn('-configuration Release ENABLE_TESTABILITY=YES -enableCodeCoverage NO',text)
        self.assertIn('-only-testing:VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFBenchmark',text)
        self.assertEqual(text.count('Scripts/report-ios-test-status.py'),2)
if __name__=='__main__':unittest.main()
