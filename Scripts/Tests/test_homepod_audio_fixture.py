#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Controls for observed packet timing; these dictionaries are not encoded media."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "homepod_audio_fixture", ROOT / "Scripts/generate-homepod-audio-diagnostic-fixture.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HomePodAudioFixtureTests(unittest.TestCase):
    @staticmethod
    def observations():
        base = 6_677_100_000
        return {"streams": [
            {"index": 0, "codec_type": "video", "time_base": "1/90000"},
            {"index": 1, "codec_type": "audio", "time_base": "1/90000"}],
            "packets": [
                {"stream_index": 0, "pts": base + 58_608 + n * 1_800,
                 "duration": 1_800, "flags": "K_" if n % 50 == 0 else "__"}
                for n in range(3_200)] + [
                {"stream_index": 1, "pts": base + n * 2_880,
                 "duration": 2_880, "flags": "K_"}
                for n in range(2_021)]}

    def validate(self, observed):
        self.assertTrue(hasattr(MODULE, "validate_packet_timing"),
                        "The encoded output's phase must be checked, not inferred from -itsoffset")
        return MODULE.validate_packet_timing(observed)

    def test_observed_broadcast_phase_is_fractional_at_every_origin(self):
        result = self.validate(self.observations())
        self.assertEqual(result["first_video_audio_offset_ticks"], 58_608)
        self.assertEqual(result["origin_crossing_ticks"], [288, 1_008, 1_728, 2_448])
        self.assertEqual(result["keyframe_count"], 64)

    def test_old_uncompensated_encoder_delay_is_rejected(self):
        observed = self.observations()
        for packet in observed["packets"]:
            if packet["stream_index"] == 0:
                packet["pts"] += 477
        with self.assertRaises(ValueError):
            self.validate(observed)

    def test_missing_audio_or_video_and_changed_cadence_are_rejected(self):
        original = self.observations()
        for index in (50, 3_220, -1):
            observed = copy.deepcopy(original)
            del observed["packets"][index]
            with self.assertRaises(ValueError):
                self.validate(observed)
        observed = copy.deepcopy(original)
        observed["packets"][3_250]["pts"] += 1
        with self.assertRaises(ValueError):
            self.validate(observed)

    def test_wrong_timebase_and_non_one_second_gop_are_rejected(self):
        observed = self.observations()
        observed["streams"][1]["time_base"] = "1/48000"
        with self.assertRaises(ValueError):
            self.validate(observed)
        observed = self.observations()
        observed["packets"][50]["flags"] = "__"
        with self.assertRaises(ValueError):
            self.validate(observed)


if __name__ == "__main__":
    unittest.main()
