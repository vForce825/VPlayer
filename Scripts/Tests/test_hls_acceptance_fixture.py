#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Packet-observation controls only; these artificial facts are not encoded media."""
import importlib.util
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('fixture',ROOT/'Scripts/generate-hls-acceptance-fixture.py')
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

class AcceptanceFixtureTests(unittest.TestCase):
    @staticmethod
    def packets(gop=125):
        return [dict(pts_time=str(index/25),flags='K_' if index%gop==0 else '__') for index in range(9000)]

    def test_observed_five_second_gop_covers_the_360_second_source(self):
        self.assertTrue(hasattr(MODULE,'validate_video_packets'),'actual GOP observations are required')
        facts=MODULE.validate_video_packets(self.packets())
        self.assertEqual(facts['gop_seconds'],5)
        self.assertEqual(facts['keyframe_count'],72)
        self.assertEqual(facts['video_packet_count'],9000)

    def test_six_second_or_missing_keyframes_cannot_masquerade_as_old_writer_fixture(self):
        self.assertTrue(hasattr(MODULE,'validate_video_packets'),'actual GOP observations are required')
        for packets in [self.packets(150),self.packets()[1:],self.packets()[:-26]]:
            with self.assertRaises(ValueError):MODULE.validate_video_packets(packets)

    def test_interior_timestamp_gap_or_nonfinite_value_is_rejected(self):
        self.assertTrue(hasattr(MODULE,'validate_video_packets'),'actual GOP observations are required')
        for value in ['nan','inf','12.5']:
            packets=self.packets();packets[350]['pts_time']=value
            with self.assertRaises(ValueError):MODULE.validate_video_packets(packets)

if __name__=='__main__':unittest.main()
