#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""核对各平台、测试宿主及生成工程采用同一发布版本。"""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseMarketingVersionTests(unittest.TestCase):
    def test_all_project_configurations_use_patch_version(self):
        spec = re.findall(r'MARKETING_VERSION: "([^"]+)"', (ROOT / 'project.yml').read_text())
        generated = re.findall(r'MARKETING_VERSION = ([^;]+);',
                               (ROOT / 'VPlayer.xcodeproj/project.pbxproj').read_text())
        self.assertEqual(len(spec), 9)
        self.assertEqual(len(generated), 18)
        self.assertEqual(set(spec), {'2.1.1'})
        self.assertEqual(set(generated), set(spec))

    def test_application_plists_resolve_build_version(self):
        for app in ['VPlayerApp', 'VPlayeriOSApp', 'VPlayerMacOSApp']:
            with self.subTest(app=app):
                info = plistlib.loads((ROOT / 'Sources' / app / 'Resources/Info.plist').read_bytes())
                self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')


if __name__ == '__main__':
    unittest.main()
