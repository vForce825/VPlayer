#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt fail-closed native acceptance validator. Portable controls are not playback evidence."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import time

MIB=1024**2
OLD_WRITER_HEAD='36f9f00044db05b707e25ea470b0da3cec62682c'

OLD_WRITER_TREE='5ea82c016a2557f3b8a8507e750a02dcce7ea5f3'
OLD_DEFECT_BLOBS={
    'Sources/VPlayerPlayback/HLS/SystemHLSPublicationGraph.swift':'a3ce6cbf2251bf205d45a8d401e251e9a7038111',
    'Sources/VPlayerPlayback/HLS/HLSPublicationCoordinator.swift':'88a0a938a60af69307dc13d3b0effe5e216f95b3'}
LEDGER_POLICY=dict(application_soft_bytes=981184512,application_hard_bytes=1266647040,
    store_soft_bytes=560*MIB,store_hard_bytes=688*MIB,resource_hard_bytes=128*1024,
    store_observation='body_subtotal_excludes_metadata')
ABSOLUTE_POLICY=dict(median_growth_limit_bytes=32*MIB,process_peak_limit_bytes=None,
    process_peak_limit_status='unavailable_no_predeclared_absolute_cap',ledger=LEDGER_POLICY,
    maximum_source_wall_seconds=300,maximum_continuous_stall_seconds=5)


def require(condition,message):
    if not condition:raise ValueError(message)


def number(value):
    return isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value)


def sequence_continuous(values):
    return bool(values) and all(0<value<=2**32-1 for value in values) and all(
        right==left+1 for left,right in zip(values,values[1:]))


def silent_windows(pcm,sample_rate):
    width=sample_rate//200
    return sum(math.sqrt(sum(x*x for x in pcm[offset:offset+width])/width)<.001
        for offset in range(sample_rate//4,len(pcm)-sample_rate//4-width+1,width))


def validate_measurement(report):
    require(report.get('schema')==1 and report.get('native_evidence') is True,'missing native evidence')
    for key in ('head','tree'):
        require(re.fullmatch('[0-9a-f]{40}',report.get(key,'')),f'invalid exact {key}')
    for key in ('fixture_sha256','measurement_sha256'):
        require(re.fullmatch('[0-9a-f]{64}',report.get(key,'')),f'missing/invalid {key}')
    for key in ('os','device'):
        require(isinstance(report.get(key),str) and report[key] and 'missing-' not in report[key],f'missing {key}')
    wall=report.get('wall_seconds')
    require(number(wall) and 299<=wall<=300,'native source observation wall must be299..300 seconds; maximum300')
    for key in ('cleanup_seconds','decode_seconds','whole_test_seconds'):
        require(number(report.get(key)) and report[key]>=0,f'missing/invalid {key}')
    require(report['whole_test_seconds']>=wall+report['cleanup_seconds']+report['decode_seconds'],
        'whole_test_seconds omits observation, cleanup or decode')
    require(report.get('warmup_seconds')==60 and report.get('sample_interval_seconds')==5,'invalid sample windows')
    playing=report.get('playback_wall_seconds');prebuffer=report.get('prebuffer_seconds')
    require(number(playing) and number(prebuffer) and 0<=prebuffer<=60 and 0<playing<=wall and
        abs(playing+prebuffer-wall)<=.1,'player wall/prebuffer must share the capped source window')
    media=report.get('media_seconds')
    require(number(media) and playing-5<=media<=playing+1,'media time did not continuously track actual player wall time')
    samples=report.get('samples',[])
    require(60<=len(samples)<=61,'missing or excessive five-second native footprint samples')
    previous=-5
    for sample in samples:
        instant=sample.get('wall_seconds');footprint=sample.get('footprint_bytes')
        require(number(instant) and 4<=instant-previous<=6 and 0<=instant<=300,'invalid native sample interval')
        require(number(footprint) and footprint>0,'missing native footprint')
        require(sample.get('producer_eof') is False,'source EOF masked active producer evidence')
        if instant>=60:
            require(number(sample.get('producer_packet_age_seconds')) and sample['producer_packet_age_seconds']<10
                and sample.get('producer_packets',0)>0,'producer was not active during observation')
        previous=instant
    require(samples[0]['wall_seconds']<=1 and samples[-1]['wall_seconds']>=295,'incomplete sample window')
    require(number(report.get('started_unix')) and number(report.get('completed_unix')) and
        report['completed_unix']>=report['started_unix']+wall,'invalid measurement time provenance')
    return samples


def freeze_baseline(report):
    require(report.get('role')=='baseline','requires separately recorded old-writer baseline')
    samples=validate_measurement(report)
    require(report['head']==OLD_WRITER_HEAD,'requires approved exact old-writer baseline')
    require(re.fullmatch('[0-9a-f]{64}',report.get('overlay_sha256','')),'missing old-writer test overlay identity')
    validate_media(report,stable=False)
    peak=max(sample['footprint_bytes'] for sample in samples)
    return dict(schema=1,baseline=report,peak_limit_bytes=peak+max(32*MIB,math.ceil(peak*.1)),
        median_growth_limit_bytes=32*MIB,frozen_before_candidate=True)


def validate_candidate(report,frozen):
    samples=validate_measurement(report);baseline=frozen['baseline']
    require(report.get('role')=='candidate' and baseline.get('role')=='baseline' and baseline['head']!=report['head'],
        'candidate cannot be its own old-writer baseline')
    require(frozen==freeze_baseline(baseline),'frozen baseline thresholds changed')
    require(baseline['completed_unix']<report['started_unix'],'baseline must complete before candidate')
    for key in ('fixture_sha256','os','device','measurement_sha256'):
        require(report[key]==baseline[key],f'baseline {key} mismatch')
    validate_footprint(samples,frozen['peak_limit_bytes'])
    validate_candidate_invariants(report,samples)
    return dict(result='passed',head=report['head'],tree=report['tree'],wall_seconds=report['wall_seconds'],
        playback_wall_seconds=report['playback_wall_seconds'],prebuffer_seconds=report['prebuffer_seconds'],
        media_seconds=report['media_seconds'],cleanup_seconds=report['cleanup_seconds'],decode_seconds=report['decode_seconds'],
        whole_test_seconds=report['whole_test_seconds'],baseline_head=baseline['head'],peak_limit_bytes=frozen['peak_limit_bytes'],
        route_metrics={key:{'old_writer':baseline.get(key),'candidate':report.get(key)} for key in
            ('playback_cpu_seconds','startup_seconds','dropped_video_frames','access_log_stalls')},
        physical_homepod_verified=False,scope='Measured capped native observation only; no hourly stability claim')


def validate_candidate_invariants(report,samples):
    for sample in samples:
        for value,cap in [('live_inputs','hard_inputs'),('live_bytes','hard_bytes'),
                          ('evidence','hard_evidence'),('callbacks','hard_callbacks')]:
            require(number(sample.get(value)) and number(sample.get(cap)) and
                0<=sample[value]<=sample[cap] and (sample[cap]>0 or sample['wall_seconds']<60),
                f'{value} hard cap or missing diagnostics')
        require(sample.get('accepted_inputs',-1)>=sample.get('released_inputs',0),'invalid allocation totals')
    for key in ('live_inputs','live_bytes','evidence'):
        first=[sample[key] for sample in samples if 60<=sample['wall_seconds']<120]
        last=[sample[key] for sample in samples if 240<=sample['wall_seconds']<300]
        require(statistics.median(last)<=max(first),f'{key} grows with total segments')
    require(report.get('ledger_before')==report.get('ledger_after') and isinstance(report.get('ledger_before'),dict)
        and report['ledger_before'],'final ledger did not return exactly')
    validate_input_return(report);validate_callback_return(report)
    require(report.get('final_evidence')==0,'retained segment evidence')
    validate_media(report,stable=True)
    require(report.get('ledger_policy')==LEDGER_POLICY,'ledger cap policy mismatch')
    require(number(report.get('global_maximum_charged_bytes')) and
        0<=report['global_maximum_charged_bytes']<=LEDGER_POLICY['application_hard_bytes'],'global ledger maximum exceeded')
    for sample in samples:
        require(number(sample.get('application_charged_bytes')) and
            sample['application_charged_bytes']<=report['global_maximum_charged_bytes'],'global ledger maximum below observed charge')
        for key,limit in [('application_charged_bytes','application_hard_bytes'),
                          ('resource_charged_bytes','resource_hard_bytes'),('store_body_bytes','store_hard_bytes')]:
            require(number(sample.get(key)) and 0<=sample[key]<=LEDGER_POLICY[limit],f'{key} ledger/store hard cap')
        require(type(sample.get('store_should_backpressure')) is bool,'missing store backpressure observation')
        if sample['store_body_bytes']>=LEDGER_POLICY['store_soft_bytes']:
            require(sample['store_should_backpressure'],'store soft threshold without backpressure')


def validate_ineligibility(evidence):
    require(evidence.get('schema')==1 and evidence.get('status')=='ineligible' and
        evidence.get('head')==OLD_WRITER_HEAD and evidence.get('tree')==OLD_WRITER_TREE and
        evidence.get('reason_code')=='sequence_clock_is_not_media_clock' and
        evidence.get('source_blobs')==OLD_DEFECT_BLOBS,'unreviewed baseline ineligibility evidence')


def verify_ineligible_source(evidence,repository):
    validate_ineligibility(evidence)
    refs={OLD_WRITER_HEAD+'^{tree}':OLD_WRITER_TREE,
        **{OLD_WRITER_HEAD+':'+path:blob for path,blob in OLD_DEFECT_BLOBS.items()}}
    for ref,expected in refs.items():
        actual=subprocess.check_output(['git','-C',str(repository),'rev-parse','--verify',ref],text=True).strip()
        require(actual==expected,'old-writer source/tree does not match reviewed defect')


def freeze_ineligible(evidence,candidate,frozen_unix):
    validate_ineligibility(evidence)
    require(number(frozen_unix) and frozen_unix>=0,'invalid frozen time')
    binding={key:candidate[key] for key in ('head','tree','fixture_sha256','measurement_sha256')}
    for key,value in binding.items():
        require(re.fullmatch('[0-9a-f]{'+str(40 if key in ('head','tree') else 64)+'}',value),f'invalid frozen {key}')
    require(binding['head']!=OLD_WRITER_HEAD,'old writer cannot be the candidate')
    return dict(schema=1,status='ineligible',baseline_eligibility=evidence,policy=ABSOLUTE_POLICY,
        candidate=binding,frozen_unix=frozen_unix)


def validate_frozen_ineligible(frozen,candidate,before):
    validate_ineligibility(frozen['baseline_eligibility'])
    require(frozen.get('policy')==ABSOLUTE_POLICY,'predeclared candidate policy changed')
    require(frozen==freeze_ineligible(frozen['baseline_eligibility'],candidate,frozen['frozen_unix']),
        'frozen candidate provenance changed')
    require(number(before) and frozen['frozen_unix']<before,'candidate policy must freeze before observation')


def current_candidate_binding(head,fixture):
    actual_head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    require(head==actual_head,'exact candidate head required')
    require(fixture is not None,'actual fixture required')
    digest=hashlib.sha256()
    with fixture.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
    paths=sorted(Path('Tests/VPlayerHLSAcceptanceTests').glob('*.swift'))
    require(len(paths)==3,'expected exact acceptance measurement source inventory')
    measurement=hashlib.sha256(b''.join(path.read_bytes() for path in paths)).hexdigest()
    return dict(head=actual_head,tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),
        fixture_sha256=digest.hexdigest(),measurement_sha256=measurement)


def validate_absolute(report,frozen):
    samples=validate_measurement(report)
    require(report.get('role')=='candidate','candidate-only mode requires the candidate')
    validate_frozen_ineligible(frozen,report,report['started_unix'])
    validate_footprint_trend(samples)
    validate_candidate_invariants(report,samples)
    return dict(result='passed_candidate_only',head=report['head'],tree=report['tree'],
        wall_seconds=report['wall_seconds'],playback_wall_seconds=report['playback_wall_seconds'],
        prebuffer_seconds=report['prebuffer_seconds'],media_seconds=report['media_seconds'],
        cleanup_seconds=report['cleanup_seconds'],decode_seconds=report['decode_seconds'],
        baseline_status='ineligible',baseline_head=OLD_WRITER_HEAD,
        baseline_reason_code=frozen['baseline_eligibility']['reason_code'],
        relative_performance='unavailable_ineligible_baseline',performance_improvement_claim=False,
        observed_process_peak_bytes=max(sample['footprint_bytes'] for sample in samples),
        process_peak_limit_bytes=None,process_peak_limit_status=ABSOLUTE_POLICY['process_peak_limit_status'],
        median_growth_limit_bytes=32*MIB,ledger_policy=LEDGER_POLICY,
        observed_global_maximum_charged_bytes=report['global_maximum_charged_bytes'],
        physical_homepod_verified=False,
        scope='Capped native candidate functionality, existing ledger limits, release and footprint trend only; no relative performance or absolute process-peak verdict')


def validate_media(report,stable):
    require(report.get('original_fragment_bytes') is True,'missing original fragment byte evidence')
    renditions=report.get('renditions',[])
    require(len(renditions)==2 and {value.get('kind') for value in renditions}=={'audio','video'},
        'missing decoded audio/video coverage')
    if stable:require(report.get('native_writer_count')==len(renditions),'native writer count differs from stable renditions')
    for value in renditions:
        if stable:require(value.get('writer_count')==1 and value.get('init_count')==1,'stable writer/init count')
        require(value.get('fragments',0)>=40,'insufficient original fragments')
        validate_fragment_continuity(value)
        require(number(value.get('decoded_seconds')) and value['decoded_seconds']>=report['media_seconds']-1,
            'incomplete real decode coverage')
        require(value.get('decoded_frames',0)>0 and number(value.get('maximum_gap_seconds')) and
            value['maximum_gap_seconds']<=(1/48000 if value['kind']=='audio' else 1/90000),'decoded timestamp gap')
        if value['kind']=='video':
            require(value['decoded_frames']>=math.floor(value['decoded_seconds']*25)-1,'missing decoded video frames')
        else:
            validate_silence(value)
            require(value.get('checked_interior_windows',0)>=50000,'missing PCM window coverage')


def validate_fragment_continuity(value):
    require(value.get('raw_mfhd_continuous') is True,'raw mfhd discontinuity/wrap')
    require(value.get('raw_tfdt_continuous') is True,'raw tfdt discontinuity')


def validate_silence(value):
    require(value.get('interior_silent_windows')==0 and value.get('checked_interior_windows',0)>0,
        'interior silence or missing PCM window coverage')


def validate_input_return(value):
    require(value.get('final_live_inputs')==0 and value.get('final_live_bytes')==0 and value.get('allocated_inputs',0)>0
        and value['allocated_inputs']==value.get('released_inputs'),'retained native input backing or missing allocation totals')


def validate_callback_return(value):
    require(value.get('final_callbacks')==0,'lost callback or pending callback at retirement')


def validate_footprint(samples,peak_limit):
    require(max(sample['footprint_bytes'] for sample in samples)<=peak_limit,'native footprint peak regression')
    validate_footprint_trend(samples)


def validate_footprint_trend(samples):
    first=[sample['footprint_bytes'] for sample in samples if 60<=sample['wall_seconds']<120]
    last=[sample['footprint_bytes'] for sample in samples if 240<=sample['wall_seconds']<300]
    require(len(first)>=12 and len(last)>=12,'missing post-warmup/final60 sample window')
    require(statistics.median(last)<=statistics.median(first)+32*MIB,'native footprint median growth')


def validate_controls(value):
    require(value.get('schema')==1 and value.get('kind')=='native_component_fault_controls','missing short native controls')
    checks={'mute':validate_silence,'wrap':validate_fragment_continuity,'retained_input':validate_input_return,
        'lost_callback':validate_callback_return,'footprint_growth':lambda item:validate_footprint(item['samples'],132*MIB)}
    require(set(value.get('positive',{}))==set(checks) and set(value.get('negative',{}))==set(checks),'all five native controls required')
    for name,check in checks.items():
        check(value['positive'][name])
        try:check(value['negative'][name])
        except ValueError:pass
        else:raise ValueError(f'native {name} fault was not observed and rejected')
    return dict(result='passed',scope='short native component fault controls only',detected=list(checks),native_playback_acceptance=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['freeze','validate','extract','controls','freeze-ineligible','check-ineligible','validate-absolute'])
    parser.add_argument('input',type=Path);parser.add_argument('--baseline',type=Path)
    parser.add_argument('--head');parser.add_argument('--fixture',type=Path)
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    if args.command in ('extract','controls'):
        marker='HLS_ACCEPTANCE_CONTROLS=' if args.command=='controls' else 'HLS_ACCEPTANCE_REPORT='
        lines=[line.split(marker,1)[1].strip() for line in args.input.read_text().splitlines() if marker in line]
        require(len(lines)==1,'expected exactly one native observation; absent evidence is not a pass')
        value=json.loads(lines[0])
        if args.command=='controls':value=validate_controls(value)
        else:validate_measurement(value)
    else:
        value=json.loads(args.input.read_text())
        if args.command=='freeze':value=freeze_baseline(value)
        elif args.command in ('freeze-ineligible','check-ineligible'):
            evidence=value if args.command=='freeze-ineligible' else value['baseline_eligibility']
            verify_ineligible_source(evidence,Path.cwd())
            binding=current_candidate_binding(args.head,args.fixture)
            if args.command=='freeze-ineligible':value=freeze_ineligible(evidence,binding,time.time())
            else:validate_frozen_ineligible(value,binding,time.time())
        else:
            require(args.baseline is not None,'frozen baseline required')
            frozen=json.loads(args.baseline.read_text())
            value=validate_absolute(value,frozen) if args.command=='validate-absolute' else validate_candidate(value,frozen)
    with args.output.open('x') as stream:json.dump(value,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(value if args.command in ('validate','validate-absolute') else dict(output=str(args.output),
        sha256=hashlib.sha256(args.output.read_bytes()).hexdigest()),sort_keys=True))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError,subprocess.CalledProcessError) as error:raise SystemExit(f'acceptance failed: {error}')
