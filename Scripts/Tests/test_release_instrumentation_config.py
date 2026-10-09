#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Guard shipping defaults separately from intentionally instrumented Debug tests.

These portable checks validate the XcodeGen source. Native acceptance must also
regenerate the project and inspect the compiler commands and product binaries.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
DISABLED_RELEASE_SETTINGS = (
    'ENABLE_CODE_COVERAGE',
    'CLANG_ENABLE_CODE_COVERAGE',
    'CLANG_COVERAGE_MAPPING',
    'CLANG_COVERAGE_MAPPING_LINKER_ARGS',
    'CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING',
    'GCC_INSTRUMENT_PROGRAM_FLOW_ARCS',
    'GCC_GENERATE_TEST_COVERAGE_FILES',
    'GENERATE_PROFILING_CODE',
    'ENABLE_TESTABILITY',
    'ENABLE_ADDRESS_SANITIZER',
    'ENABLE_THREAD_SANITIZER',
    'ENABLE_UNDEFINED_BEHAVIOR_SANITIZER',
)


def block(text, key, indent):
    match = re.search(r'^' + ' ' * indent + re.escape(key) + r':\n'
                      r'(.*?)(?=^\S|^ {1,' + str(max(indent, 1)) + r'}\S|\Z)',
                      text, re.M | re.S)
    return match.group(1) if match else ''


class ReleaseInstrumentationConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.spec = (ROOT / 'project.yml').read_text()
        self.schemes = block(self.spec, 'schemes', 0)

    def scheme(self, name):
        result = block(self.schemes, name, 2)
        self.assertTrue(result, name + ' scheme is missing')
        return result

    def test_release_disables_compiler_instrumentation_for_all_inherited_targets(self):
        settings = block(self.spec, 'settings', 0)
        release = block(block(settings, 'configs', 2), 'Release', 4)
        self.assertTrue(release, 'Release needs explicit project-wide shipping defaults')
        for setting in DISABLED_RELEASE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertRegex(release, r'(?m)^      ' + setting + r': (?:false|NO)\s*$',
                                 'Missing Release default: ' + setting)

    def test_debug_leaves_coverage_selection_to_the_explicit_test_schemes(self):
        settings = block(self.spec, 'settings', 0)
        for scope in (block(settings, 'base', 2),
                      block(block(settings, 'configs', 2), 'Debug', 4)):
            for setting in ('ENABLE_CODE_COVERAGE', 'CLANG_ENABLE_CODE_COVERAGE',
                            'CLANG_COVERAGE_MAPPING', 'CLANG_COVERAGE_MAPPING_LINKER_ARGS'):
                # Xcode's normal support defaults remain available; the dedicated
                # test schemes request instrumentation. No global Debug forcing.
                self.assertNotRegex(scope, r'(?m)^\s+' + setting + r':')

    def test_main_schemes_cannot_implicitly_instrument_release_builds(self):
        for name in ('VPlayer', 'VPlayeriOS'):
            with self.subTest(scheme=name):
                scheme = self.scheme(name)
                self.assertIn('      gatherCoverageData: false\n', block(scheme, 'test', 4))
                self.assertIn('      config: Debug\n', block(scheme, 'run', 4))
                for action in ('profile', 'archive'):
                    self.assertIn('      config: Release\n', block(scheme, action, 4))

    def test_only_explicit_debug_test_schemes_collect_coverage(self):
        enabled = []
        for name in re.findall(r'^  (\w+):$', self.schemes, re.M):
            scheme = self.scheme(name)
            test = block(scheme, 'test', 4)
            if 'gatherCoverageData: true' in test:
                enabled.append(name)
                self.assertIn('      config: Debug\n', test)
                targets = block(block(scheme, 'build', 4), 'targets', 6)
                self.assertTrue(targets)
                for target in targets.splitlines():
                    if target.strip():
                        self.assertRegex(target, r'^        \w+: \[test\]$')
        self.assertCountEqual(enabled, ['VPlayerCoverage', 'VPlayeriOSCoverage'])

    def test_coverage_schemes_keep_the_existing_functional_test_selection(self):
        for main in ('VPlayer', 'VPlayeriOS'):
            normal = block(block(self.scheme(main), 'test', 4), 'targets', 6)
            coverage = block(block(self.scheme(main + 'Coverage'), 'test', 4), 'targets', 6)
            self.assertTrue(normal)
            self.assertEqual(normal, coverage)

    def test_production_schemes_build_only_shipping_targets(self):
        for suffix in ('', 'iOS'):
            name = 'VPlayer' + suffix + 'Release'
            scheme = self.scheme(name)
            targets = block(block(scheme, 'build', 4), 'targets', 6)
            names = re.findall(r'^        (\w+):', targets, re.M)
            self.assertCountEqual(names, ['VPlayerCore' + suffix,
                                         'VPlayerPlayback' + suffix, 'VPlayer' + suffix])
            for action in ('run', 'test', 'profile', 'analyze', 'archive'):
                self.assertIn('      config: Release\n', block(scheme, action, 4))
            test = block(scheme, 'test', 4)
            self.assertIn('      gatherCoverageData: false\n', test)
            self.assertNotIn('targets:', test)

    def test_production_run_has_no_debugger_or_runtime_validation_injection(self):
        for name in ('VPlayerRelease', 'VPlayeriOSRelease'):
            run = block(self.scheme(name), 'run', 4)
            for option, value in (('debugEnabled', 'false'),
                                  ('enableGPUFrameCaptureMode', 'disabled'),
                                  ('enableGPUValidationMode', 'false'),
                                  ('disableMainThreadChecker', 'true'),
                                  ('disableThreadPerformanceChecker', 'true')):
                self.assertIn('      ' + option + ': ' + value + '\n', run)


if __name__ == '__main__':
    unittest.main()
