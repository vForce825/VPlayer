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
if __name__=='__main__':unittest.main()
