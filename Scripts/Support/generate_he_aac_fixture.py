#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Generate genuine ordinary HE-AAC from synthetic PCM using Apple's afconvert.

Only assigns the implicit-SBR fixture after LC ADTS core headers, an observed HE
profile and a real decode at an expanded sample rate agree. No header rewriting,
private input, prohibited corpus replay or fallback relabeling is supported.
Apple codec/container documentation:
https://developer.apple.com/documentation/coreaudiotypes/kaudioformatmpeg4aac_he
https://developer.apple.com/documentation/audiotoolbox/kaudiofileaac_adtstype
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import time
import wave

RATES=(96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350)
AFCONVERT=Path('/usr/bin/afconvert')
ROOT=Path(__file__).resolve().parents[2]


def require(condition,message):
    if not condition:raise ValueError(message)


def adts_core_facts(data):
    require(0<len(data)<=1024**2,'HE source must be a bounded nonempty ADTS file')
    position=0;observed=[]
    while position<len(data):
        require(position+7<=len(data) and data[position]==255 and data[position+1]&0xf6==0xf0,'invalid/truncated ADTS header')
        profile=(data[position+2]>>6)+1
        index=(data[position+2]>>2)&15
        channels=((data[position+2]&1)<<2)|(data[position+3]>>6)
        length=((data[position+3]&3)<<11)|(data[position+4]<<3)|(data[position+5]>>5)
        header=7 if data[position+1]&1 else 9
        require(profile==2 and index<len(RATES) and channels in (1,2),'LC ADTS core rate/layout required')
        require(header<length<=len(data)-position and data[position+6]&3==0,'unsupported/truncated ADTS frame')
        observed.append((RATES[index],channels));position+=length
        require(len(observed)<=1024,'ADTS frame bound exceeded')
    require(len(observed)>=2 and len(set(observed))==1,'stable multiple ADTS frames required')
    return dict(sample_rate=observed[0][0],channels=observed[0][1],frames=len(observed),core_profile='LC')


def initial_adts_window(data):
    """Keep the exact first eight complete AUs used by the production factual probe."""
    position=0
    for _ in range(8):
        require(position+7<=len(data),'missing complete initial eight-AU HE window')
        length=((data[position+3]&3)<<11)|(data[position+4]<<3)|(data[position+5]>>5)
        require(length>7 and position+length<=min(len(data),64*1024),'initial HE window exceeds complete-frame/64KiB bound')
        position+=length
    prefix=data[:position]
    require(adts_core_facts(prefix)['frames']==8,'invalid initial eight-AU HE window')
    return prefix


def verify_observations(core,stream,decoded_rate,decoded_channels,decoded_frames,minimum_frames=None):
    require(stream.get('codec_name')=='aac' and stream.get('profile') in ('HE-AAC','HE-AACv2'),
        'encoder output was not observed as genuine HE/SBR')
    require(int(stream.get('sample_rate',0))==decoded_rate and decoded_rate>core['sample_rate'],
        'real decoded sample rate did not expand beyond LC ADTS core')
    coverage=decoded_rate if minimum_frames is None else minimum_frames
    require(decoded_channels==int(stream.get('channels',0)) and decoded_channels>0 and decoded_frames>=coverage,
        'missing substantial real PCM decode coverage')
    return dict(adts_core_profile='LC',adts_core_rate=core['sample_rate'],adts_core_channels=core['channels'],
        adts_frames=core['frames'],observed_profile=stream['profile'],decoded_rate=decoded_rate,
        decoded_channels=decoded_channels,decoded_frames=decoded_frames)


def generate(output):
    require(platform.system()=='Darwin','genuine HE-AAC preparation requires the authorized Apple runner')
    require(AFCONVERT.is_file(),'Apple afconvert is unavailable; do not substitute LC bytes')
    spec=importlib.util.spec_from_file_location('fixture_tools',ROOT/'Scripts/Support/hls_fixture_toolchain.py')
    tools=importlib.util.module_from_spec(spec);spec.loader.exec_module(tools)
    ffmpeg=Path(os.environ.get('FFMPEG',''))
    ffprobe=Path(os.environ.get('FFPROBE',''))
    toolchain=tools.verify(ffmpeg,ffprobe,ROOT/'Vendor/FFmpeg/ffmpeg.lock.json')
    deadline=time.monotonic()+290
    def run(command,cwd=None,check=True):
        remaining=deadline-time.monotonic();require(remaining>0,'HE generation wall budget exhausted')
        result=subprocess.run(command,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
            timeout=min(60,remaining),check=False)
        if check and result.returncode:
            raise ValueError('Apple HE-AAC preparation command failed: '+repr(command)+': '+result.stdout.decode(errors='replace')[:4096])
        return result
    help_result=run([str(AFCONVERT),'-h'],check=False)
    formats=run([str(AFCONVERT),'-hf'],check=False)
    command=[str(AFCONVERT),'-f','adts','-d','aach@48000','-b','64000','-q','127','synthetic.wav','encoded.adts']
    with tempfile.TemporaryDirectory(prefix='vplayer-public-he-') as temporary:
        directory=Path(temporary)
        with wave.open(str(directory/'synthetic.wav'),'wb') as stream:
            stream.setnchannels(2);stream.setsampwidth(2);stream.setframerate(48000)
            pcm=bytearray()
            for index in range(96000):
                for frequency in (997,1511):pcm.extend(struct.pack('<h',round(0.12*32767*math.sin(2*math.pi*frequency*index/48000))))
            stream.writeframes(pcm)
        # Actual tool execution proves whether this runner supports the requested
        # codec/container. A missing codec or LC-only output is a blocker.
        run(command,cwd=directory)
        encoded=(directory/'encoded.adts').read_bytes()
        core=adts_core_facts(encoded)
        def observe(name,core,minimum_frames=None):
            probe_command=[str(ffprobe),'-v','error','-show_streams','-of','json',name+'.adts']
            probe=json.loads(run(probe_command,cwd=directory).stdout)
            streams=[value for value in probe.get('streams',[]) if value.get('codec_type')=='audio']
            require(len(streams)==1,'one HE audio stream required')
            decode_command=[str(ffmpeg),'-hide_banner','-loglevel','error','-nostdin','-y','-i',name+'.adts',
                '-map','0:a:0','-c:a','pcm_s16le','-f','wav',name+'.wav']
            run(decode_command,cwd=directory)
            with wave.open(str(directory/(name+'.wav')),'rb') as decoded:
                facts=verify_observations(core,streams[0],decoded.getframerate(),decoded.getnchannels(),
                    decoded.getnframes(),minimum_frames=minimum_frames)
            return facts,probe_command,decode_command
        # Full-file HE alone is insufficient: the source inspector deliberately
        # observes at most8 AUs/64KiB. Never widen that bound to suit a fixture.
        initial=initial_adts_window(encoded)
        (directory/'initial.adts').write_bytes(initial)
        initial_facts,initial_probe,initial_decode=observe('initial',adts_core_facts(initial),minimum_frames=1024)
        initial_facts.update(access_units=8,bytes=len(initial),sha256=hashlib.sha256(initial).hexdigest(),
            probe_command=initial_probe,decode_command=initial_decode)
        facts,probe_command,decode_command=observe('encoded',core)
        evidence=dict(encoder='Apple Core Audio afconvert',codec='aach',container='adts',
            source='two seconds of generated stereo PCM tones; no private media',command=command,
            probe_command=probe_command,decode_command=decode_command,initial_window=initial_facts,
            working_directory='ephemeral fixture-only directory',
            afconvert_binary_sha256=tools.digest(AFCONVERT),
            afconvert_help_sha256=hashlib.sha256(help_result.stdout).hexdigest(),afconvert_help_status=help_result.returncode,
            afconvert_version_banner=help_result.stdout.decode(errors='replace').splitlines()[:2],
            afconvert_format_listing_sha256=hashlib.sha256(formats.stdout).hexdigest(),afconvert_format_listing_status=formats.returncode,
            macos_version=run(['/usr/bin/sw_vers','-productVersion']).stdout.decode().strip(),
            macos_build=run(['/usr/bin/sw_vers','-buildVersion']).stdout.decode().strip(),
            ffmpeg_source_commit=toolchain['source_commit'],encoded_sha256=hashlib.sha256(encoded).hexdigest(),**facts)
        output.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(directory/'encoded.adts',output)
        return evidence


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();print(json.dumps(generate(args.output),sort_keys=True))

if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError,wave.Error,subprocess.SubprocessError) as error:
        raise SystemExit(f'Genuine HE-AAC fixture is unavailable: {error}. Do not relabel LC or replay old corpus bytes.')
