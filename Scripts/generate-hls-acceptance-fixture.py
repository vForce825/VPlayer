#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Public synthetic 6-second GOP / continuous tones; no private media input.

360 seconds is source media time, not a playback duration option. The player stops
before 300 wall seconds. Generation itself has a separate 300-second wall budget.
"""
import hashlib
import importlib.util
import json
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
        video=str(Path(directory)/'six-second.mp4')
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-f','lavfi','-i',
            'testsrc2=s=1280x720:r=25:d=6','-c:v','libx264','-threads','2','-preset','ultrafast',
            '-pix_fmt','yuv420p','-g','150','-keyint_min','150','-sc_threshold','0','-an',video)
        run(FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y','-stream_loop','59','-i',video,
            '-f','lavfi','-i','aevalsrc=0.12*sin(2*PI*997*t)|0.12*sin(2*PI*1511*t):s=48000:d=360:c=stereo',
            '-map','0:v:0','-map','1:a:0','-c:v','copy','-c:a','ac3','-b:a','192k',
            '-t','360','-map_metadata','-1','-muxdelay','0','-muxrate','37000000','-f','mpegts',str(output/'persistent-360s.ts'))
    probe=json.loads(run(FFPROBE,'-v','error','-show_streams','-show_format','-of','json',str(output/'persistent-360s.ts')))
    assert float(probe['format']['duration']) >= 359
    video_stream=next(stream for stream in probe['streams'] if stream['codec_type']=='video')
    audio_stream=next(stream for stream in probe['streams'] if stream['codec_type']=='audio')
    assert (video_stream['codec_name'],video_stream['width'],video_stream['height'],video_stream['r_frame_rate'])==('h264',1280,720,'25/1')
    assert (audio_stream['codec_name'],audio_stream['sample_rate'],audio_stream['channels'])==('ac3','48000',2)
    manifest={'source':'public lavfi test pattern and two continuous tones; no private media',
        'ffmpeg_version':'8.1.2','ffmpeg_raw_version':version,'ffmpeg_source_commit':tool_evidence['source_commit'],
        'source_media_seconds':360,'maximum_playback_wall_seconds':300,'ts_muxrate_bps':37000000,
        'paced_transport_bps':38000000,'transport_description':'CBR null-packet padded synthetic TS; not complex 38 Mbps video',
        'fixture_sha256':file_hash(output/'persistent-360s.ts', deadline)}
    (output/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest))

if __name__=='__main__': generate()
