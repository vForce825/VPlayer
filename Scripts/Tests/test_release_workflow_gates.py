#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable contracts for fail-closed clean Release acceptance wiring."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def step(workflow, name):
    text = (ROOT / '.github/workflows' / workflow).read_text()
    marker = '      - name: ' + name + '\n'
    assert marker in text, 'Required native Release step missing: ' + name
    return text.split(marker, 1)[1].split('      - name:', 1)[0]


class ReleaseWorkflowGates(unittest.TestCase):
    def test_shipping_device_run_and_archive_use_fresh_real_artifacts(self):
        for workflow, platform, sdk, scheme, root in [
            ('ios-ci.yml', 'iOS', 'iphoneos', 'VPlayeriOSRelease', 'iOS'),
            ('macos-ci.yml', 'tvOS', 'appletvos', 'VPlayerRelease', 'tvOS')]:
            for action, name in [('build', 'Compile Release for a physical iPhone destination without signing' if platform == 'iOS' else 'Verify clean tvOS Release device Run'),
                                 ('archive', 'Verify clean ' + platform + ' Release Archive')]:
                with self.subTest(platform=platform, action=action):
                    body = step(workflow, name)
                    suffix = 'Device' if action == 'build' else 'Archive'
                    build_root = '$RUNNER_TEMP/' + root + '-' + suffix
                    self.assertIn('test ! -e "' + build_root + '"', body)
                    self.assertIn('xcodebuild ' + action, body)
                    self.assertIn('-scheme ' + scheme, body)
                    self.assertIn('-configuration Release', body)
                    self.assertIn("-destination 'generic/platform=" + platform + "'", body)
                    self.assertIn('-derivedDataPath "' + build_root + '"', body)
                    self.assertIn('set -o pipefail', body)
                    self.assertIn('verify-release-artifacts.py capture --log "' + build_root + '.log"', body)
                    self.assertIn('verify-release-artifacts.py verify --sdk ' + sdk, body)
                    self.assertIn('--scope app', body)
                    self.assertIn('--ffmpeg ', body)
                    self.assertNotIn('continue-on-error', body)
                    self.assertNotIn('|| true', body)
                    if action == 'archive':
                        self.assertIn('-archivePath "' + build_root + '.xcarchive"', body)
                        self.assertIn('--archive "' + build_root + '.xcarchive"', body)

    def test_release_acceptance_cannot_override_away_coverage(self):
        paths = [ROOT / '.github/workflows/ios-ci.yml', ROOT / '.github/workflows/macos-ci.yml',
                 ROOT / 'Scripts/test-release-startup.sh']
        for path in paths:
            text = path.read_text()
            self.assertNotIn('-enableCodeCoverage NO', text, path.name)
            self.assertNotRegex(text, r'(?:CLANG_ENABLE_CODE_COVERAGE|GCC_GENERATE_TEST_COVERAGE_FILES|GCC_INSTRUMENT_PROGRAM_FLOW_ARCS|SWIFT_OPTIMIZATION_LEVEL|GCC_OPTIMIZATION_LEVEL)=', path.name)

    def test_simulator_shipping_run_is_verified_before_reusing_unchanged_products_for_tests(self):
        for workflow, platform, scheme, sdk, root in [
            ('ios-ci.yml', 'iOS', 'VPlayeriOSRelease', 'iphonesimulator', 'iOS-Release'),
            ('macos-ci.yml', 'tvOS', 'VPlayerRelease', 'appletvsimulator', 'ReleaseStartup')]:
            shipping = step(workflow, 'Build and verify clean ' + platform + ' Release simulator Run')
            self.assertIn('id: release_run', shipping)
            self.assertIn('test ! -e "$RUNNER_TEMP/' + root + '"', shipping)
            if platform == 'iOS':
                self.assertIn('ios-startup-runner.py --build-shipping', shipping)
                self.assertIn('--build-log "$RUNNER_TEMP/' + root + '.log"', shipping)
            else:
                self.assertIn('xcodebuild build -project VPlayer.xcodeproj -scheme ' + scheme, shipping)
                self.assertIn('verify-release-artifacts.py capture --log "$RUNNER_TEMP/' + root + '.log"', shipping)
            self.assertIn('verify-release-artifacts.py verify --sdk ' + sdk, shipping)
            if platform == 'tvOS':
                preparation = step(workflow, 'Build and verify clean tvOS Release simulator artifacts')
                self.assertIn("steps.release_run.outcome == 'success'", preparation)
                self.assertIn('"$RUNNER_TEMP/' + root + '-Tests.log"', preparation)
                self.assertIn('--build-log "$RUNNER_TEMP/' + root + '.log"', preparation)
                self.assertIn('verify-release-artifacts.py verify --sdk ' + sdk, preparation)
                self.assertIn('--scope app', preparation)
        runtime = step('macos-ci.yml', 'Run production-configuration Release startup UI tests')
        self.assertIn('xcodebuild test-without-building', runtime)
        self.assertIn("steps.release_build.outcome == 'success'", runtime)
        cold = step('macos-ci.yml', 'Check six Release cold starts including allocator accounting')
        self.assertIn('VPLAYER_STARTUP_BUILD_LOG="$RUNNER_TEMP/ReleaseStartup.log"', cold)
        self.assertIn("steps.release_build.outcome == 'success'", cold)

    def test_explicit_test_framework_builds_are_also_verified(self):
        for workflow, name, sdk in [
            ('ios-ci.yml', 'Measure optimized CPU processing without device qualification', 'iphonesimulator'),
            ('macos-ci.yml', 'Run all optimized Release boundary tests', 'appletvsimulator')]:
            body = step(workflow, name)
            self.assertIn('ENABLE_TESTABILITY=YES', body)
            self.assertIn('verify-release-artifacts.py capture --log ', body)
            self.assertIn('verify-release-artifacts.py verify --sdk ' + sdk, body)
            self.assertIn('--scope frameworks', body)
            self.assertIn('-maximum-test-execution-time-allowance 300', body)

    def test_native_controls_share_existing_bounded_job(self):
        text = (ROOT / '.github/workflows/macos-ci.yml').read_text()
        controls = text.split('  compiler-controls:', 1)[1]
        self.assertIn('bash Scripts/run-release-artifact-controls.sh', controls)
        self.assertIn('timeout-minutes: 10', controls)
        self.assertIn('timeout-minutes: 5', controls)
        jobs = re.findall(r'^  ([a-z][a-z-]+):$', text.split('jobs:', 1)[1], re.M)
        self.assertEqual(len(jobs), 6)

    def test_tvos_boundary_gate_declares_arm64_framework_scope_and_scans_universal_ffmpeg(self):
        body = step('macos-ci.yml', 'Run all optimized Release boundary tests')
        self.assertIn('ARCHS=arm64 ONLY_ACTIVE_ARCH=YES', body)
        self.assertIn('--scope frameworks', body)
        self.assertIn('tvos-arm64_x86_64-simulator/libFFmpeg.a', body)
        self.assertNotIn('-only-testing:', body)
        self.assertNotIn('continue-on-error', body)
        self.assertNotIn('|| true', body)


if __name__ == '__main__':
    unittest.main()
