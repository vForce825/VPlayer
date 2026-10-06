#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Observation checks only; ordinary artificial headers are not encoded HE-AAC proof."""
import importlib.util
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'Scripts/Support/generate_he_aac_fixture.py'

def frame(rate_index=6,profile=1):
    length=15
    return bytes([255,241,(profile<<6)|(rate_index<<2),128|(length>>11),
        (length>>3)&255,((length&7)<<5)|31,252])+bytes(8)

class HEAACObservationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(),'HE-AAC observation helper must exist')
        spec=importlib.util.spec_from_file_location('he',SOURCE)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)

    def test_expanded_he_decode_is_required_before_sbr_label(self):
        core=self.module.adts_core_facts(frame()*2)
        self.assertEqual(core['sample_rate'],24000)
        result=self.module.verify_observations(core,dict(codec_name='aac',profile='HE-AAC',sample_rate='48000',channels=2),
            decoded_rate=48000,decoded_channels=2,decoded_frames=96000)
        self.assertEqual(result['adts_core_rate'],24000)
        self.assertEqual(result['decoded_rate'],48000)

    def test_lc_or_unexpanded_or_undecoded_input_cannot_be_labeled_sbr(self):
        core=self.module.adts_core_facts(frame()*2)
        for profile,rate,frames in [('LC',48000,96000),('HE-AAC',24000,48000),('HE-AAC',48000,0)]:
            with self.assertRaises(ValueError):
                self.module.verify_observations(core,dict(codec_name='aac',profile=profile,sample_rate=str(rate),channels=2),
                    decoded_rate=rate,decoded_channels=2,decoded_frames=frames)

    def test_not_lc_truncation_and_rate_change_fail_closed(self):
        for data in [frame(profile=0),frame()[:-1],frame()+frame(rate_index=3)]:
            with self.assertRaises(ValueError):self.module.adts_core_facts(data)

    def test_initial_observation_uses_only_eight_complete_access_units(self):
        self.assertTrue(hasattr(self.module,'initial_adts_window'),'bounded initial HE observation is required')
        prefix=self.module.initial_adts_window(frame()*20)
        self.assertEqual(prefix,frame()*8)
        self.assertEqual(self.module.adts_core_facts(prefix)['frames'],8)
        with self.assertRaises(ValueError):self.module.initial_adts_window(frame()*7)

if __name__=='__main__':unittest.main()
