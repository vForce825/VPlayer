#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Keep every independently built product on the supported tvOS SDK floor."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class TVOS27DeploymentTests(unittest.TestCase):
    def test_all_project_and_target_floors(self):
        spec = (ROOT / 'project.yml').read_text()
        floors = re.findall(r'(?:tvOS|deploymentTarget): "([0-9.]+)"', spec)
        self.assertEqual(len(floors), 7)
        self.assertEqual(set(floors), {'27.0'})
        project = (ROOT / 'VPlayer.xcodeproj/project.pbxproj').read_text()
        generated = re.findall(r'TVOS_DEPLOYMENT_TARGET = ([0-9.]+);', project)
        self.assertTrue(generated)
        self.assertEqual(set(generated), {'27.0'})

    def test_standalone_builds_use_same_floor(self):
        for name in ('Scripts/build-metal-libraries.sh', 'Scripts/test-release-startup.sh'):
            source = (ROOT / name).read_text()
            self.assertNotIn('tvos26.', source)
            self.assertIn('tvos27.0', source)
        self.assertIn('sdk_version_floor="27.0"', (ROOT / 'Scripts/build-ffmpeg.sh').read_text())
        audit = (ROOT / 'Scripts/audit-ffmpeg.sh').read_text()
        self.assertNotIn('tvos18.0', audit)
        self.assertIn('minos 27.0', audit)

    def test_public_deployment_contract(self):
        self.assertIn('"tvOS 27.0"', (ROOT / 'Sources/VPlayerCore/VPlayerCore.swift').read_text())

if __name__ == '__main__':
    unittest.main()
