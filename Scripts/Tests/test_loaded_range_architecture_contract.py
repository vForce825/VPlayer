#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""检查调试辅助函数的架构条件；不替代 Apple SDK 编译。"""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('cpp'), '需要 C 预处理器')
class LoadedRangeArchitectureContractTests(unittest.TestCase):
    def preprocess(self, arm64, debug):
        source = (ROOT / 'Sources/VPlayerPlayback/HLS/VPLoadedRangeCoverage.m').read_text()
        # 云端没有 Apple 头文件；只验证本文件真实条件编译，不模拟 ABI。
        source = re.sub(r'^\s*#(?:include|import)[^\n]*', '', source, flags=re.M)
        flags = ['-D__LP64__=1', f'-DDEBUG={int(debug)}']
        if arm64:
            flags.append('-D__arm64__=1')
        return subprocess.run(['cpp', '-P', '-undef', *flags, '-'], input=source,
                              text=True, capture_output=True, check=True).stdout

    def test_debug_callbacks_exist_only_with_arm64_call_site(self):
        for arm64 in [False, True]:
            with self.subTest(arm64=arm64):
                source = self.preprocess(arm64, True)
                for name in ['VPAllocationLookup', 'VPReadLocalAllocation',
                             'VPRecordLocalAllocation']:
                    self.assertEqual(name in source, arm64)
                self.assertIn('VPInspectPreparationWeakSideTable', source)

    def test_release_has_no_debug_inspection(self):
        for arm64 in [False, True]:
            source = self.preprocess(arm64, False)
            self.assertNotIn('VPReadLocalAllocation', source)
            self.assertNotIn('VPInspectPreparationWeakSideTable', source)


if __name__ == '__main__':
    unittest.main()
