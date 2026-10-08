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
    def test_generation_drift_is_reported_after_native_diagnostics_not_before(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertNotIn('if: needs.generated-inputs.outputs.needs_refresh', text)
        self.assertGreater(text.index('name: Fail closed until generated outputs are committed'),
                           text.index('name: Run shared playback and iPhone touch tests'))
        self.assertIn("always() && steps.generated.outputs.needs_refresh == 'true'", text)
    def test_native_configurations_are_independent_but_still_fail_the_job(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('id: prepare', text)
        self.assertIn('id: simulator', text)
        guard="if: always() && !cancelled() && steps.prepare.outcome == 'success' && steps.simulator.outcome == 'success'"
        self.assertEqual(text.count(guard), 2)
        self.assertNotIn('continue-on-error', text)
if __name__=='__main__':unittest.main()
