#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt portable controls only; synthetic reports are never native evidence."""
import copy
import importlib.util
import json
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
            accepted_inputs=100*i+20,released_inputs=100*i,segments=i,
            application_charged_bytes=200*1024**2,resource_charged_bytes=2048,
            store_body_bytes=100*1024**2,store_should_backpressure=False) for i in range(60)],
        renditions=[dict(kind='audio',writer_count=1,init_count=1,fragments=299,raw_mfhd_continuous=True,
            raw_tfdt_continuous=True,decoded_frames=298*48000,decoded_seconds=298,maximum_gap_seconds=0,
            interior_silent_windows=0,checked_interior_windows=59000),dict(kind='video',writer_count=1,
            init_count=1,fragments=299,raw_mfhd_continuous=True,raw_tfdt_continuous=True,
            decoded_frames=298*25,decoded_seconds=298,maximum_gap_seconds=0)],
        ledger_policy={'application_soft_bytes':981184512,'application_hard_bytes':1266647040,
            'store_soft_bytes':560*1024**2,'store_hard_bytes':688*1024**2,'resource_hard_bytes':128*1024,
            'store_observation':'body_subtotal_excludes_metadata'},global_maximum_charged_bytes=200*1024**2,
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

    def frozen_ineligible(self):
        evidence=json.loads((ROOT/'Scripts/Support/hls-baseline-eligibility.json').read_text())
        return self.module.freeze_ineligible(evidence,report(),1500)

    def test_candidate_only_has_explicit_unavailable_comparison_and_no_process_cap(self):
        verdict=self.module.validate_absolute(report(),self.frozen_ineligible())
        self.assertEqual(verdict['result'],'passed_candidate_only')
        self.assertEqual(verdict['relative_performance'],'unavailable_ineligible_baseline')
        self.assertIsNone(verdict['process_peak_limit_bytes'])
        self.assertEqual(verdict['observed_process_peak_bytes'],100*1024**2)
        self.assertNotIn('route_metrics',verdict)

    def test_ineligible_evidence_is_exact_and_cannot_excuse_arbitrary_failure(self):
        frozen=self.frozen_ineligible()
        for key in ['head','tree','reason_code','status']:
            changed=copy.deepcopy(frozen);changed['baseline_eligibility'][key]='unreviewed'
            with self.assertRaises(ValueError):self.module.validate_absolute(report(),changed)
        changed=copy.deepcopy(frozen);changed['baseline_eligibility']['source_blobs']={}
        with self.assertRaises(ValueError):self.module.validate_absolute(report(),changed)
        for key in ['head','tree','fixture_sha256','measurement_sha256']:
            value=report();value[key]='f'*len(value[key])
            with self.assertRaises(ValueError):self.module.validate_absolute(value,frozen)
        changed=copy.deepcopy(frozen);changed['frozen_unix']=2001
        with self.assertRaisesRegex(ValueError,'before'):self.module.validate_absolute(report(),changed)
        changed=copy.deepcopy(frozen);changed['policy']['median_growth_limit_bytes']+=1
        with self.assertRaisesRegex(ValueError,'policy'):self.module.validate_absolute(report(),changed)

    def test_candidate_only_keeps_functional_leak_and_trend_failures(self):
        changes=[lambda r:r.update(wall_seconds=298),
            lambda r:r.update(media_seconds=10),lambda r:r.update(final_callbacks=1),
            lambda r:r.update(final_live_inputs=1),lambda r:r.update(native_writer_count=3),
            lambda r:r['renditions'][0].update(raw_tfdt_continuous=False),
            lambda r:r['renditions'][0].update(interior_silent_windows=1),
            lambda r:r['ledger_after'].update(application=9999),
            lambda r:r['samples'][-1].update(producer_eof=True)]
        for change in changes:
            value=report();change(value)
            with self.assertRaises(ValueError):self.module.validate_absolute(value,self.frozen_ineligible())
        value=report()
        for sample in value['samples']:
            if sample['wall_seconds']>=240:sample['footprint_bytes']+=33*1024**2
        with self.assertRaisesRegex(ValueError,'median'):self.module.validate_absolute(value,self.frozen_ineligible())
        # A flat process footprint above688MiB is not a store-ledger violation.
        value=report()
        for sample in value['samples']:sample['footprint_bytes']=900*1024**2
        self.module.validate_absolute(value,self.frozen_ineligible())

    def test_real_ledger_hard_caps_and_store_soft_backpressure(self):
        for key,value in [('application_charged_bytes',1266647041),('resource_charged_bytes',128*1024+1),
                          ('store_body_bytes',688*1024**2+1)]:
            candidate=report();candidate['samples'][10][key]=value
            with self.assertRaisesRegex(ValueError,'ledger|store'):self.module.validate_absolute(candidate,self.frozen_ineligible())
        candidate=report();candidate['samples'][10]['store_body_bytes']=560*1024**2
        with self.assertRaisesRegex(ValueError,'backpressure'):self.module.validate_absolute(candidate,self.frozen_ineligible())
        candidate['samples'][10]['store_should_backpressure']=True
        self.module.validate_absolute(candidate,self.frozen_ineligible())
        candidate=report();candidate['global_maximum_charged_bytes']=1266647041
        with self.assertRaisesRegex(ValueError,'ledger'):self.module.validate_absolute(candidate,self.frozen_ineligible())

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

    def test_runner_refuses_ambiguous_or_non_candidate_ineligibility(self):
        for options in [['--controls-only'],['--record-baseline'],['--baseline','measured.json']]:
            result=subprocess.run([str(ROOT/'Scripts/run-persistent-hls-acceptance.sh'),
                '--ineligible-baseline','reviewed.json',*options],capture_output=True,text=True)
            self.assertEqual(result.returncode,64)
            self.assertIn('candidate-only',result.stderr)

    def test_runner_rejects_longer_configuration_before_xcode(self):
        result=subprocess.run([str(ROOT/'Scripts/run-persistent-hls-acceptance.sh'),
            '--duration-seconds','301','--head','a'*40],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('300',result.stderr)

class AcceptanceReaderSourceContract(unittest.TestCase):
    """Read-loop/ownership guards only; native controls exercise buffer semantics."""
    def test_short_and_full_readers_filter_both_streams_and_exhaust_trailing_markers(self):
        for name, start, end in [
            ('AcceptanceNativeControlTests.swift', 'private func decodeRemuxControl(',
             'private func checkVideoReaderMarkerEvidence('),
            ('PersistentHLSAcceptanceTests.swift', 'private func decodeVideo(',
             '/// Bounded completion state')]:
            source=(ROOT/'Tests/VPlayerHLSAcceptanceTests'/name).read_text().split(start,1)[1].split(end,1)[0]
            self.assertIn('AcceptanceVideoReaderCursor(kind: .decoded)',source)
            self.assertIn('AcceptanceVideoReaderCursor(kind: .original)',source)
            self.assertIn('guard try decodedCursor.consumesMedia(ready) else { continue }',source)
            self.assertEqual(source.count('while let original = try await originalProvider.next()'),2)
            self.assertIn('guard try originalCursor.consumesMedia(original) else { continue }',source)
            self.assertIn('if try originalCursor.consumesMedia(original)',source)
            self.assertIn('guard paired else',source)
            self.assertIn('reader.status == .completed, originalReader.status == .completed',source)
            self.assertIn('continuity.requireVideoCoverage(timing',source)
            self.assertIn('makeOwnedReaderFixtureSample(copying: ready)',source)
            self.assertIn('makeOwnedReaderFixtureSample(copying: original)',source)

    def test_reader_cursor_uses_only_synchronous_scalar_state(self):
        source=(ROOT/'Tests/VPlayerHLSAcceptanceTests/AcceptanceMediaSupport.swift').read_text()
        self.assertIn('struct AcceptanceVideoReaderCursor',source)
        cursor=source.split('struct AcceptanceVideoReaderCursor',1)[1].split('struct AcceptanceVideoTiming',1)[0]
        self.assertIn('maximumConsecutiveMarkers = 8',cursor)
        self.assertIn('contentType == .markerOnly',cursor)
        self.assertIn('sample.blockSize == nil',cursor)
        self.assertIn('!sample.hasImage',cursor)
        self.assertIn('CMTimeCompare(sample.duration, .zero) == 0',cursor)
        self.assertIn('let blockSize = sample.blockSize, blockSize >= sample.totalSize',cursor)
        self.assertIn('ready.withUnsafeSampleBuffer',cursor)
        self.assertNotIn('async',cursor)
        self.assertNotIn('CMSampleBuffer?',cursor)
        self.assertNotIn('[CMSampleBuffer]',cursor)

    def test_decoded_reader_accepts_raster_size_without_weakening_payload_checks(self):
        source=(ROOT/'Tests/VPlayerHLSAcceptanceTests/AcceptanceMediaSupport.swift').read_text()
        cursor=source.split('struct AcceptanceVideoReaderCursor',1)[1].split('struct AcceptanceVideoTiming',1)[0]
        decoded=cursor.split('case .decoded:',1)[1].split('case .original:',1)[0]
        self.assertIn('sample.contentType == .pixelBuffer',decoded)
        self.assertIn('sample.hasImage',decoded)
        self.assertIn('sample.blockSize == nil',decoded)
        self.assertNotIn('sample.totalSize',decoded)

class AcceptanceSamplerSourceContract(unittest.TestCase):
    """Portable capture/order guard; Apple compilation and ARC remain native checks."""
    def setUp(self):
        self.source=(ROOT/'Tests/VPlayerHLSAcceptanceTests/PersistentHLSAcceptanceTests.swift').read_text()

    def test_sampler_captures_weak_values_instead_of_mutable_optional_boxes(self):
        declaration=next(line.strip() for line in self.source.splitlines()
                         if line.strip().startswith('let sampler = Task'))
        self.assertEqual(declaration,'let sampler = Task { @MainActor [weak graph, weak authority] in')
        self.assertTrue('guard let graph, authority != nil else {' in self.source,
                        'Active sampling must reject unexpectedly missing graph owners')

    def test_sampler_is_physically_joined_before_both_root_release_paths(self):
        cleanups=self.source.split('let cleanupStart = AcceptanceClock.now')[1:]
        self.assertEqual(len(cleanups),2)
        for cleanup in cleanups:
            cancelled=cleanup.index('sampler.cancel()')
            joined=cleanup.index('await sampler.value')
            self.assertLess(cancelled,joined)
            for root in ['assembler','graph','authority']:
                self.assertLess(joined,cleanup.index(f'{root} = nil'))
        self.assertIn('let ownersReleased = retiredOwners.allReleased',self.source)
        self.assertIn('guard ownersReleased, ledgers() == ledgerBefore else {',self.source)

if __name__=='__main__':unittest.main()
