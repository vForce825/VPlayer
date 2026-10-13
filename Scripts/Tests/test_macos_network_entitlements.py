#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""检查 macOS 网络权限配置；发布前仍需核对实际签名产物。"""

from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS = "Sources/VPlayerMacOSApp/Resources/VPlayer.entitlements"


class MacOSNetworkEntitlementsTests(unittest.TestCase):
    def test_source_entitlements_keep_client_without_server(self):
        entitlements = plistlib.loads((ROOT / ENTITLEMENTS).read_bytes())
        self.assertIs(entitlements["com.apple.security.app-sandbox"], True)
        self.assertIs(entitlements["com.apple.security.network.client"], True)
        self.assertNotIn("com.apple.security.network.server", entitlements)
        self.assertIs(entitlements["com.apple.security.files.user-selected.read-only"], True)

    def test_project_spec_disables_incoming_and_keeps_outgoing_connections(self):
        spec = (ROOT / "project.yml").read_text()
        targets = spec.split("targets:", 1)[1].split("schemes:", 1)[0]
        target = re.search(r"^  VPlayerMacOS:\n(.*?)(?=^  \w|\Z)", targets, re.M | re.S)
        self.assertIsNotNone(target)
        for setting, expected in {
            "CODE_SIGN_ENTITLEMENTS": ENTITLEMENTS,
            "ENABLE_APP_SANDBOX": "true",
            "ENABLE_HARDENED_RUNTIME": "true",
            "ENABLE_INCOMING_NETWORK_CONNECTIONS": "false",
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "true",
        }.items():
            with self.subTest(setting=setting):
                values = re.findall(r"^\s+" + setting + r": (\S+)$", target.group(1), re.M)
                self.assertEqual(values, [expected])

    def test_every_generated_mac_app_configuration_matches_source(self):
        project = (ROOT / "VPlayer.xcodeproj/project.pbxproj").read_text()
        target = re.search(
            r"/\* VPlayerMacOS \*/ = \{\n\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
            project, re.S,
        )
        self.assertIsNotNone(target)
        configuration_list = re.search(r"buildConfigurationList = ([A-F0-9]{24})", target.group(1))
        self.assertIsNotNone(configuration_list)
        configurations = re.search(
            configuration_list.group(1) + r" /\*[^\n]+\*/ = \{\n"
            r"\s*isa = XCConfigurationList;\n\s*buildConfigurations = \((.*?)\);",
            project, re.S,
        )
        self.assertIsNotNone(configurations)
        entries = re.findall(r"([A-F0-9]{24}) /\* (\w+) \*/", configurations.group(1))
        self.assertCountEqual([name for _, name in entries], ["Debug", "Release"])
        for identifier, name in entries:
            with self.subTest(configuration=name):
                configuration = re.search(
                    identifier + r" /\* " + name + r" \*/ = \{\n"
                    r"\s*isa = XCBuildConfiguration;\n\s*buildSettings = \{(.*?)\n\t\t\t\};",
                    project, re.S,
                )
                self.assertIsNotNone(configuration)
                for setting, expected in {
                    "CODE_SIGN_ENTITLEMENTS": ENTITLEMENTS,
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                }.items():
                    values = re.findall(r"^\s+" + setting + r" = ([^;]+);$", configuration.group(1), re.M)
                    self.assertEqual(values, [expected], setting)


if __name__ == "__main__":
    unittest.main()
