#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise trusted platform selection without Apple build tools or filesystem mutation."""
from pathlib import Path
import shutil
import tempfile
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / 'Scripts/Support/ffmpeg-platform-profile.sh'

class ArtifactProfileTests(unittest.TestCase):
    def run_profile(self, value):
        self.assertTrue(PROFILE.is_file(), 'explicit FFmpeg platform profiles are not implemented')
        return subprocess.run(['bash', '-c', '''set -eu
source "$1"
ffmpeg_select_platform "$2"
printf '%s\\n' "$ffmpeg_platform" "$ffmpeg_artifact_directory" "$ffmpeg_work_suffix" "$ffmpeg_device_sdk" "$ffmpeg_simulator_sdk" "$ffmpeg_simulator_architectures" "$ffmpeg_device_platform_id" "$ffmpeg_simulator_platform_id"
''', 'profile-test', str(PROFILE), value], capture_output=True, text=True)

    def test_tv_profile_preserves_exact_inventory(self):
        result = self.run_profile('tvos')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['tvos', 'Artifacts', '', 'appletvos', 'appletvsimulator', 'arm64,x86_64', '3', '8'])

    def test_ios_profile_uses_independent_outputs_and_arm64_slices(self):
        result = self.run_profile('ios')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['ios', 'Artifacts-iOS', '/ios', 'iphoneos', 'iphonesimulator', 'arm64', '2', '7'])

    def test_only_tv_fat_simulator_archive_requires_thinning(self):
        self.assertTrue(PROFILE.is_file())
        for platform, variant, expected in [('tvos', 'simulator', 0), ('tvos', '', 1), ('ios', 'simulator', 1), ('ios', '', 1)]:
            result = subprocess.run(['bash', '-c', 'source "$1"; ffmpeg_select_platform "$2"; ffmpeg_archive_needs_thinning "$3"', 'thin-test', str(PROFILE), platform, variant], capture_output=True)
            self.assertEqual(result.returncode, expected, (platform, variant, result.stderr))

    def test_untrusted_profile_cannot_select_a_path(self):
        for value in ['', 'macos', '../Artifacts', 'ios/../../Work', 'IOS', 'ios; echo injected']:
            with self.subTest(value=value):
                result = self.run_profile(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_explicit_profile_is_used_by_build_audit_and_promotion(self):
        for name in ['build-ffmpeg.sh', 'audit-ffmpeg.sh', 'promote-ffmpeg-artifact.sh']:
            source = (ROOT / 'Scripts' / name).read_text()
            self.assertIn('ffmpeg_select_platform', source, name)
            self.assertIn('--platform', source, name)
        build = (ROOT / 'Scripts/build-ffmpeg.sh').read_text()
        self.assertIn('lock_dir="$work/.build-lock"', build)
        self.assertIn('build_work="$work$ffmpeg_work_suffix"', build)

    def test_profiles_share_lock_before_either_output_can_be_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts/Support').mkdir(parents=True)
            shutil.copy(PROFILE, root / 'Scripts/Support')
            shutil.copy(ROOT / 'Scripts/build-ffmpeg.sh', root / 'Scripts')
            (root / 'Vendor/FFmpeg/Work/.build-lock').mkdir(parents=True)
            sentinels = []
            for name in ['Artifacts', 'Artifacts-iOS']:
                marker = root / 'Vendor/FFmpeg' / name / 'existing'
                marker.parent.mkdir()
                marker.write_text(name)
                sentinels.append(marker)
            for platform in ['tvos', 'ios']:
                result = subprocess.run(['bash', str(root / 'Scripts/build-ffmpeg.sh'), '--platform', platform], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FFmpeg build lock already exists', result.stderr)
                for marker in sentinels: self.assertEqual(marker.read_text(), marker.parent.name)

    def test_promotion_rejects_cross_profile_candidate_before_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts/Support').mkdir(parents=True)
            shutil.copy(PROFILE, root / 'Scripts/Support')
            shutil.copy(ROOT / 'Scripts/promote-ffmpeg-artifact.sh', root / 'Scripts')
            lock = root / 'Vendor/FFmpeg/Work/.build-lock'
            lock.mkdir(parents=True)
            candidate = root / 'Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.test.xcframework'
            candidate.mkdir(parents=True)
            (candidate / 'marker').write_text('preserve')
            script = 'printf "%s\\n" "$$" > "$1/owner-pid"; printf "test\\n" > "$1/token"; printf "%s\\n" "$2" > "$1/candidate"; bash "$3" --platform ios; result=$?; exit "$result"'
            result = subprocess.run(['bash', '-c', script, 'promotion-test', str(lock), str(candidate), str(root / 'Scripts/promote-ffmpeg-artifact.sh')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('candidate does not match', result.stderr)
            self.assertEqual((candidate / 'marker').read_text(), 'preserve')

    def test_metal_default_preserves_tv_and_ios_is_opt_in(self):
        source = (ROOT / 'Scripts/build-metal-libraries.sh').read_text()
        self.assertIn('--platform', source)
        self.assertIn('air64-apple-ios27.0', source)
        self.assertIn('VPlayerPlayback-ios.metallib', source)
        self.assertIn('VPlayerPlayback-iphonesimulator.metallib', source)
        self.assertIn('air64-apple-tvos27.0', source)

if __name__ == '__main__': unittest.main()
