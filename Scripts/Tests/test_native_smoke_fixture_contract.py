#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Ordinary smoke-fixture metadata checks, never manufactured source facts."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeSmokeFixtureContract(unittest.TestCase):
    def test_endpoint_controls_keep_the_original_source_and_join_one_player(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        self.assertIn('func testNativeSDKEndBoundaryControlsKeepSameSource()', source)
        self.assertIn('case defaultEnd, beforePreroll, afterPreroll', source)
        control = source.split('private func runEndpointControl(', 1)[1].split('private func playerDriver(', 1)[0]
        self.assertEqual(control.count('AVPlayer()'), 1)
        self.assertIn('player.replaceCurrentItem(with: nil)', control)
        self.assertIn('await timeout.value', control)
        self.assertIn('await origin.close()', control)
        self.assertIn('NATIVE_HLS_ENDPOINT_CONTROL', control)
        self.assertIn('diagnostic-only=true', control)
        after_load = control.split('let loadedDuration = try await item.asset.load(.duration)', 1)[1]
        before_preroll = after_load.split('player.preroll(atRate: 1)', 1)[0]
        self.assertIn('try Task.checkCancellation()', before_preroll)
        self.assertIn('guard !signal.hasFailure', before_preroll)
        self.assertIn('current.seconds > started.seconds + 0.25', control)
        self.assertIn('case .playing = registry.playbackStateSnapshot()', source)
        self.assertIn('activation == registry.outputResourceContextSnapshot()?.activation', source)

    def test_native_master_uses_explicit_color_media_and_matching_declared_duration(self):
        source = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeHLSMasterSmokeTests.swift').read_text()
        resource = re.search(r'forResource: "([^"]+)"', source).group(1)
        matches = list((ROOT / 'Tests').rglob(resource + '.ts'))
        self.assertEqual(len(matches), 1)
        output = subprocess.check_output([
            'ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'stream=width,height,r_frame_rate,color_space,color_transfer,color_primaries:format=duration',
            '-of', 'json', str(matches[0])], text=True)
        actual = json.loads(output)
        video = actual['streams'][0]
        self.assertEqual(video.get('color_space'), 'bt709')
        self.assertEqual(video.get('color_transfer'), 'bt709')
        self.assertEqual(video.get('color_primaries'), 'bt709')
        rate = video['r_frame_rate'].split('/')
        self.assertIn(f'MediaRational(num: {rate[0]}, den: {rate[1]})', source)
        declared = float(re.search(r'#EXTINF:([0-9.]+),', source).group(1))
        self.assertAlmostEqual(declared, float(actual['format']['duration']), delta=0.1)


if __name__ == '__main__':
    unittest.main()
