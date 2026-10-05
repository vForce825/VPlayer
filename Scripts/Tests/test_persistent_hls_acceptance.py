#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt portable controls only; synthetic reports are never native evidence."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'Scripts/Support/persistent_hls_acceptance.py'
OLD='36f9f00044db05b707e25ea470b0da3cec62682c'


def report(role='candidate'):
    return dict(schema=1,role=role,native_evidence=True,head='a'*40 if role=='candidate' else OLD,
        tree='c'*40,overlay_sha256='f'*64,original_fragment_bytes=True,fixture_sha256='d'*64,
        measurement_sha256='e'*64,os='tvOS27 build fixture',device='simulator:fixture-id',
        started_unix=2000 if role=='candidate' else 1000,completed_unix=2305 if role=='candidate' else 1305,
        cleanup_seconds=2.5,decode_seconds=1.5,whole_test_seconds=303.8,wall_seconds=299.8,
        playback_wall_seconds=299,prebuffer_seconds=.8,media_seconds=298,warmup_seconds=60,sample_interval_seconds=5,
        samples=[dict(wall_seconds=i*5,footprint_bytes=100*1024**2,producer_eof=False,
            producer_packets=i*100,producer_packet_age_seconds=0,live_inputs=20,live_bytes=10000,evidence=40,
            callbacks=1,hard_inputs=640,hard_bytes=640000,hard_evidence=320,hard_callbacks=3,
            accepted_inputs=100*i+20,released_inputs=100*i,segments=i) for i in range(60)],
        renditions=[dict(kind='audio',writer_count=1,init_count=1,fragments=299,raw_mfhd_continuous=True,
            raw_tfdt_continuous=True,decoded_frames=298*48000,decoded_seconds=298,maximum_gap_seconds=0,
            interior_silent_windows=0,checked_interior_windows=59000),dict(kind='video',writer_count=1,
            init_count=1,fragments=299,raw_mfhd_continuous=True,raw_tfdt_continuous=True,
            decoded_frames=298*25,decoded_seconds=298,maximum_gap_seconds=0)],
        native_writer_count=2,ledger_before={'application':2048,'resource':0},
        ledger_after={'application':2048,'resource':0},final_live_inputs=0,final_live_bytes=0,
        final_evidence=0,final_callbacks=0,allocated_inputs=30000,released_inputs=30000,
        physical_homepod_verified=False)

class AcceptanceControls(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(),'acceptance validator must exist')
        spec=importlib.util.spec_from_file_location('acceptance',SOURCE)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)

    def rejected(self,change,pattern):
        value=report();change(value)
        with self.assertRaisesRegex(ValueError,pattern):
            self.module.validate_candidate(value,self.module.freeze_baseline(report('baseline')))

    def test_valid_report_shape_and_fixed_thresholds(self):
        frozen=self.module.freeze_baseline(report('baseline'))
        self.assertEqual(frozen['peak_limit_bytes'],132*1024**2)
        self.module.validate_candidate(report(),frozen)

    def test_twenty_one_ms_mute_control(self):
        pcm=[.1]*48000
        self.assertEqual(self.module.silent_windows(pcm,48000),0)
        pcm[12768:13776]=[0.0]*1008
        count=self.module.silent_windows(pcm,48000)
        self.assertGreaterEqual(count,3)
        self.rejected(lambda r:r['renditions'][0].update(interior_silent_windows=count),'silence')

    def test_wrap_control(self):
        self.assertFalse(self.module.sequence_continuous([4294967294,4294967295,1]))
        self.rejected(lambda r:r['renditions'][0].update(raw_mfhd_continuous=False),'mfhd')

    def test_retained_input_control(self):
        self.rejected(lambda r:r.update(final_live_inputs=1,released_inputs=29999),'retained')

    def test_lost_callback_control(self):
        self.rejected(lambda r:r.update(final_callbacks=1),'callback')

    def test_monotonic_footprint_control(self):
        def grow(r):
            for index,sample in enumerate(r['samples']):sample['footprint_bytes']+=index*1024**2
        self.rejected(grow,'footprint')

    def test_median_threshold_is_independent(self):
        baseline=report('baseline')
        for sample in baseline['samples']:sample['footprint_bytes']=300*1024**2
        value=report()
        for sample in value['samples']:
            if sample['wall_seconds']>=240:sample['footprint_bytes']+=33*1024**2
        with self.assertRaisesRegex(ValueError,'median'):
            self.module.validate_candidate(value,self.module.freeze_baseline(baseline))

    def test_missing_native_evidence_or_candidate_baseline_fails(self):
        with self.assertRaisesRegex(ValueError,'old.writer'):self.module.freeze_baseline(report())
        self.rejected(lambda r:r.update(native_evidence=False),'native')

    def test_baseline_identity_mismatches_fail(self):
        for key in ['device','os','fixture_sha256','measurement_sha256']:
            value='0'*64 if key.endswith('sha256') else 'mismatch'
            self.rejected(lambda r:r.update({key:value}),key)

    def test_cap_and_accelerated_media_cannot_fake_observation(self):
        self.rejected(lambda r:r.update(wall_seconds=300.001),'300')
        self.rejected(lambda r:r.update(wall_seconds=20,media_seconds=300),'wall')

    def test_samples_and_baseline_order_are_mandatory(self):
        self.rejected(lambda r:r.update(samples=r['samples'][::2]),'sample')
        self.rejected(lambda r:r.update(started_unix=1200),'before')

    def test_ledger_leak_and_unpublished_writer_fail(self):
        self.rejected(lambda r:r['ledger_after'].update(application=2049),'ledger')
        self.rejected(lambda r:r.update(native_writer_count=3),'writer')

    def test_prebuffer_is_inside_cap(self):
        value=report();value.update(prebuffer_seconds=36,playback_wall_seconds=263.8,media_seconds=263)
        self.module.validate_candidate(value,self.module.freeze_baseline(report('baseline')))
        self.rejected(lambda r:r.update(prebuffer_seconds=36),'prebuffer')

    def test_eof_and_inactive_producer_fail(self):
        self.rejected(lambda r:r['samples'][-1].update(producer_eof=True),'EOF')
        self.rejected(lambda r:r['samples'][-1].update(producer_packet_age_seconds=11),'active')

    def test_video_frame_loss_is_not_hidden_by_duration(self):
        self.rejected(lambda r:r['renditions'][1].update(decoded_frames=100),'video frames')

    def test_cleanup_and_decode_are_finite_and_separate(self):
        for key in ['cleanup_seconds','decode_seconds','whole_test_seconds']:
            for value in [-1,float('nan'),float('inf')]:self.rejected(lambda r:r.update({key:value}),key)
            self.rejected(lambda r:r.pop(key),key)

    def test_native_observer_controls_fail_if_fault_is_suppressed(self):
        value=report()
        positive={'mute':value['renditions'][0],'wrap':value['renditions'][0],
            'retained_input':value,'lost_callback':value,'footprint_growth':{'samples':value['samples']}}
        negative=copy.deepcopy(positive)
        negative['mute']['interior_silent_windows']=3
        negative['wrap']['raw_mfhd_continuous']=False
        negative['retained_input']['final_live_inputs']=1
        negative['lost_callback']['final_callbacks']=1
        for index,sample in enumerate(negative['footprint_growth']['samples']):sample['footprint_bytes']+=index*1024**2
        controls={'schema':1,'kind':'native_component_fault_controls','positive':positive,'negative':negative}
        self.assertFalse(self.module.validate_controls(controls)['native_playback_acceptance'])
        for name in positive:
            suppressed=copy.deepcopy(controls);suppressed['negative'][name]=copy.deepcopy(positive[name])
            with self.assertRaisesRegex(ValueError,'not observed'):self.module.validate_controls(suppressed)
        del controls['negative']['wrap']
        with self.assertRaisesRegex(ValueError,'all five'):self.module.validate_controls(controls)

    def test_runner_rejects_longer_configuration_before_xcode(self):
        result=subprocess.run([str(ROOT/'Scripts/run-persistent-hls-acceptance.sh'),
            '--duration-seconds','301','--head','a'*40],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('300',result.stderr)

if __name__=='__main__':unittest.main()
