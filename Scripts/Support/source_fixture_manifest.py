#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Freeze or verify the exact public SourcePlanning family; verification is offline."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('readback_inventory',HERE/'export-hls-generation.py')
inventory=importlib.util.module_from_spec(spec);spec.loader.exec_module(inventory)
EXPECTED=inventory.SOURCE_FILES
COMMIT='38b88335f99e76ed89ff3c93f877fdefce736c13'


def require(condition,message):
    if not condition:raise ValueError(message)


def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()


def verify(root):
    require(root.is_dir() and not root.is_symlink(),'missing regular SourcePlanning directory')
    require({path.name for path in root.iterdir()}==EXPECTED,'SourcePlanning inventory mismatch')
    require(all(path.is_file() and not path.is_symlink() for path in root.iterdir()),'regular public fixture files required')
    require(sum(path.stat().st_size for path in root.iterdir())<=16*1024**2,'source fixture readback exceeds16MiB')
    hashes={}
    for line in (root/'SHA256SUMS').read_text().splitlines():
        value,name=line.split('  ',1)
        require(name in EXPECTED-{'SHA256SUMS'} and name not in hashes and re.fullmatch('[0-9a-f]{64}',value),
            'invalid/duplicate source hash entry')
        require(digest(root/name)==value,f'committed source hash mismatch: {name}')
        hashes[name]=value
    require(set(hashes)==EXPECTED-{'SHA256SUMS'},'source hash inventory incomplete')
    facts=json.loads((root/'provenance.json').read_text())
    require(facts.get('ffmpeg_version')=='8.1.2' and facts.get('ffmpeg_source_commit')==COMMIT,'source tool pin mismatch')
    require(re.fullmatch('[0-9a-f]{40}',facts.get('ffmpeg_source_tree','')),'missing source tree provenance')
    for tool in ('ffmpeg','ffprobe'):
        require(re.match(r'^'+tool+r' version (8\.1\.2|n8\.1\.2)(?:\s|$)',facts.get(tool+'_cli_version','')),
            f'invalid raw {tool} release spelling')
    he=facts.get('he_aac_observation',{})
    require(he.get('encoder')=='Apple Core Audio afconvert' and he.get('codec')=='aach' and he.get('container')=='adts',
        'genuine ordinary Apple HE-AAC provenance required')
    require(he.get('observed_profile') in ('HE-AAC','HE-AACv2') and
        he.get('decoded_rate',0)>he.get('adts_core_rate',0)>0 and he.get('decoded_frames',0)>=he['decoded_rate'],
        'missing verified HE/SBR expanded-rate observation')
    require(he.get('encoded_sha256')==hashes['aac-implicit-sbr-signaling.adts'],'HE observation belongs to different bytes')
    require(re.fullmatch('[0-9a-f]{64}',he.get('afconvert_binary_sha256','')) and he.get('macos_version') and he.get('macos_build'),
        'missing actual Apple encoder/OS provenance')
    require(he.get('command',[])[:5]==['/usr/bin/afconvert','-f','adts','-d','aach@48000'],'unexpected HE encoder command')
    initial=he.get('initial_window',{})
    require(initial.get('access_units')==8 and 0<initial.get('bytes',0)<=64*1024 and
        initial.get('observed_profile') in ('HE-AAC','HE-AACv2') and
        initial.get('decoded_rate',0)>initial.get('adts_core_rate',0)>0 and initial.get('decoded_frames',0)>=1024,
        'missing bounded initial eight-AU HE observation window')
    return facts


def finalize(root,tool_record,he_record):
    require(tool_record.startswith('PINNED_FIXTURE_TOOLS='),'verified tool record is required')
    tools=json.loads(tool_record.split('=',1)[1]);he=json.loads(he_record)
    facts={'ffmpeg_version':'8.1.2','ffmpeg_source_commit':tools['source_commit'],'ffmpeg_source_tree':tools['source_tree'],
        'ffmpeg_cli_version':tools['raw_versions']['ffmpeg'],'ffprobe_cli_version':tools['raw_versions']['ffprobe'],
        'generator':'Scripts/generate-source-planning-fixtures.sh',
        'source':'public synthetic base fixtures, generated video patterns and Core Audio PCM tones; no private media',
        'alternate_audio':'same synthetic audio under two language labels exercises selection topology, not speech language',
        'he_aac_observation':he}
    (root/'provenance.json').write_text(json.dumps(facts,indent=2,sort_keys=True)+'\n')
    require({path.name for path in root.iterdir()}==EXPECTED-{'SHA256SUMS'},'generated fixture inventory differs from reviewed family')
    (root/'SHA256SUMS').write_text(''.join(digest(root/name)+'  '+name+'\n' for name in sorted(EXPECTED-{'SHA256SUMS'})))
    verify(root)


def main():
    if len(sys.argv)==3 and sys.argv[1]=='verify':verify(Path(sys.argv[2]))
    elif len(sys.argv)==5 and sys.argv[1]=='finalize':finalize(Path(sys.argv[2]),sys.argv[3],sys.argv[4])
    else:raise ValueError('Usage: source_fixture_manifest.py verify root | finalize root tool_record he_record')
    print('SourcePlanning pinned inventory/hash provenance verified offline; no native decode performed by verification')

if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError) as error:raise SystemExit(f'SourcePlanning verification failed: {error}')
