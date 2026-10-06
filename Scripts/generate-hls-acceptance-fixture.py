#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Public synthetic 5-second GOP / continuous tones; no private media input.

360 seconds is source media time, not a playback duration option. The player stops
before 300 wall seconds. Generation itself has a separate 300-second wall budget.
"""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
FFMPEG=os.environ.get('FFMPEG','ffmpeg')
FFPROBE=os.environ.get('FFPROBE','ffprobe')

def file_hash(path, deadline):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):
            if time.monotonic() >= deadline: raise ValueError('fixture generation exceeded 300-second wall limit')
            digest.update(chunk)
    return digest.hexdigest()


def validate_video_packets(packets):
    """Validate actual generated transport facts before assigning fixture provenance."""
    if len(packets)!=9000:
        raise ValueError('expected exactly360 seconds at25fps in the comparison source')
    times=[float(packet['pts_time']) for packet in packets]
    if not all(math.isfinite(value) for value in times):
        raise ValueError('nonfinite source video packet timestamp')
    if any(abs(right-left-.04)>1/90000 for left,right in zip(times,times[1:])):
        raise ValueError('source video packet timeline is not continuous25fps')
    keys=[instant for packet,instant in zip(packets,times) if 'K' in packet.get('flags','')]
    if len(keys)!=72 or keys[0]!=times[0] or any(abs(right-left-5)>1/90000 for left,right in zip(keys,keys[1:])):
        raise ValueError('comparison fixture must have real five-second keyframe intervals')
    return dict(gop_seconds=5,keyframe_count=len(keys),video_packet_count=len(times),
        observed_video_span_seconds=times[-1]-times[0]+.04)


def validate_control_probe(probe,codec):
    streams=probe.get('streams',[])
    expected_profiles={'h264':{'Constrained Baseline','Baseline','Main','High'},'hevc':{'Main'}}
    if len(streams)!=1:raise ValueError('one actual control video stream required')
    stream=streams[0]
    if (stream.get('codec_name'),stream.get('width'),stream.get('height'),stream.get('has_b_frames'),stream.get('nb_read_frames')) != (codec,1280,720,0,'1'):
        raise ValueError('native control must be exactly one1280x720 frame without reordering')
    if stream.get('profile') not in expected_profiles[codec]:raise ValueError('native control profile outside declared ordinary codec envelope')
    return stream


def generate():
    deadline=time.monotonic()+300
    def run(*args):
        return subprocess.check_output(args,stderr=subprocess.PIPE,timeout=max(.001,deadline-time.monotonic()))
    spec=importlib.util.spec_from_file_location('fixture_tools',ROOT/'Scripts/Support/hls_fixture_toolchain.py')
    tool_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(tool_module)
    tool_evidence=tool_module.verify(Path(FFMPEG),Path(FFPROBE),ROOT/'Vendor/FFmpeg/ffmpeg.lock.json')
    version=tool_evidence['raw_versions']['ffmpeg']
    output=ROOT/'Tests/Fixtures/HLSAcceptance'
    output.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='hls-synthetic-') as directory:
        video=str(Path(directory)/'five-second.mp4')
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-f','lavfi','-i',
            'testsrc2=s=1280x720:r=25:d=5','-c:v','libx264','-threads','2','-preset','ultrafast',
            '-pix_fmt','yuv420p','-g','125','-keyint_min','125','-sc_threshold','0','-an',video)
        # One genuine IDR AU from the same encoder feeds a short paired native
        # avc3/avc1 control. Repeating this independent IDR is valid short media.
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-i',video,
            '-frames:v','1','-c:v','copy','-bsf:v','h264_mp4toannexb','-f','h264',str(output/'control-avc.h264'))
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-f','lavfi','-i',
            'testsrc2=s=1280x720:r=25:d=0.04','-frames:v','1','-c:v','libx265','-preset','ultrafast',
            '-pix_fmt','yuv420p','-profile:v','main','-x265-params','pools=none:frame-threads=1:bframes=0:repeat-headers=1:open-gop=0',
            '-f','hevc',str(output/'control-hevc.h265'))
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-stream_loop','71','-i',video,
            '-f','lavfi','-i','aevalsrc=0.12*sin(2*PI*997*t)|0.12*sin(2*PI*1511*t):s=48000:d=360:c=stereo',
            '-map','0:v:0','-map','1:a:0','-c:v','copy','-c:a','ac3','-b:a','192k',
            '-t','360','-map_metadata','-1','-muxdelay','0','-muxrate','37000000','-f','mpegts',str(output/'persistent-360s.ts'))
    control_observations={}
    for codec,name in [('h264','control-avc.h264'),('hevc','control-hevc.h265')]:
        observed=json.loads(run(FFPROBE,'-v','error','-count_frames','-show_entries',
            'stream=codec_name,profile,width,height,has_b_frames,nb_read_frames','-of','json',str(output/name)))
        control_observations[name]=validate_control_probe(observed,codec)
    probe=json.loads(run(FFPROBE,'-v','error','-show_streams','-show_format','-of','json',str(output/'persistent-360s.ts')))
    assert float(probe['format']['duration']) >= 359
    video_stream=next(stream for stream in probe['streams'] if stream['codec_type']=='video')
    audio_stream=next(stream for stream in probe['streams'] if stream['codec_type']=='audio')
    assert (video_stream['codec_name'],video_stream['width'],video_stream['height'],video_stream['r_frame_rate'])==('h264',1280,720,'25/1')
    assert (audio_stream['codec_name'],audio_stream['sample_rate'],audio_stream['channels'])==('ac3','48000',2)
    packet_probe=json.loads(run(FFPROBE,'-v','error','-select_streams','v:0','-show_packets',
        '-show_entries','packet=pts_time,flags','-of','json',str(output/'persistent-360s.ts')))
    video_observation=validate_video_packets(packet_probe['packets'])
    manifest={'source':'public lavfi test pattern and two continuous tones; no private media',
        'ffmpeg_version':'8.1.2','ffmpeg_raw_version':version,'ffmpeg_source_commit':tool_evidence['source_commit'],
        'source_media_seconds':360,'gop_seconds':5,'video_observation':video_observation,
        'comparison_reason':'same five-second source is admitted by unchanged old-writer256-record maps; candidate six-second coverage is separate',
        'maximum_playback_wall_seconds':300,'ts_muxrate_bps':37000000,
        'paced_transport_bps':38000000,'transport_description':'CBR null-packet padded synthetic TS; not complex 38 Mbps video',
        'fixture_sha256':file_hash(output/'persistent-360s.ts', deadline),
        'control_avc_sha256':file_hash(output/'control-avc.h264', deadline),
        'control_hevc_sha256':file_hash(output/'control-hevc.h265', deadline),
        'native_control_observations':control_observations}
    (output/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest))

if __name__=='__main__': generate()
