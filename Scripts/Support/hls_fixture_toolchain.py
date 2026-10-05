#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Provenance verification for the isolated, fixture-only pinned host FFmpeg CLI.

Official release/archive builds print 8.1.2; exact-tag Git builds may print n8.1.2.
Only these two spellings normalize to 8.1.2, and neither is trusted without the
locked source commit and verified executable hashes. Raw output is preserved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

COMMIT='38b88335f99e76ed89ff3c93f877fdefce736c13'
TAG='n8.1.2'
URLS=['https://git.ffmpeg.org/ffmpeg.git','https://github.com/FFmpeg/FFmpeg.git']


def require(value, message):
    if not value: raise ValueError(message)


def read_lock(path):
    lock=json.loads(path.read_text())
    require(lock.get('sourceURL')==URLS[0] and lock.get('mirrorURLs')==URLS[1:] and
        lock.get('tag')==TAG and lock.get('commit')==COMMIT and lock.get('licenseMode')=='LGPL-2.1-or-later',
        'App source lock differs from the reviewed exact FFmpeg fixture source')
    return lock


def normalized_version(line, tool):
    match=re.match(r'^'+re.escape(tool)+r' version (8\.1\.2|n8\.1\.2)(?:\s|$)',line)
    require(match is not None,f'Expected exact {tool} release 8.1.2 or tag n8.1.2; actual: {line}')
    return '8.1.2'


def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''): value.update(chunk)
    return value.hexdigest()


def verify(ffmpeg, ffprobe, lock_path):
    read_lock(lock_path)
    require(ffmpeg.is_absolute() and ffprobe.is_absolute(), 'Fixture CLI paths must be absolute')
    require(ffmpeg.name=='ffmpeg' and ffprobe.name=='ffprobe' and ffmpeg.parent==ffprobe.parent and
        ffmpeg.parent.name=='bin','Both tools must be from one isolated installation')
    prefix=ffmpeg.parent.parent
    manifest=prefix/'fixture-toolchain.json'
    value=json.loads(manifest.read_text())
    require(value.get('kind')=='fixture-only-host-cli' and value.get('source_commit')==COMMIT and
        value.get('source_tag')==TAG and value.get('source_url') in URLS, 'Missing exact-source fixture tool provenance')
    require(re.fullmatch('[0-9a-f]{40}',value.get('source_tree','')), 'Missing source tree provenance')
    require(isinstance(value.get('dependencies'),dict) and value['dependencies'], 'Missing host dependency versions')
    raw={}
    for tool,path in [('ffmpeg',ffmpeg),('ffprobe',ffprobe)]:
        require(path.is_file() and not path.is_symlink(),f'Missing regular built tool: {path}')
        require(value.get('binary_sha256',{}).get(tool)==digest(path),f'{tool} binary differs from recorded build')
        line=subprocess.check_output([str(path),'-version'],text=True,stderr=subprocess.STDOUT,timeout=15).splitlines()[0]
        normalized_version(line,tool)
        require(value.get('raw_versions',{}).get(tool)==line,f'{tool} raw version differs from recorded build')
        raw[tool]=line
    return {'version':'8.1.2','source_commit':COMMIT,'source_tree':value['source_tree'],
        'raw_versions':raw,'manifest':str(manifest),'ffmpeg':str(ffmpeg),'ffprobe':str(ffprobe)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock',type=Path,required=True)
    parser.add_argument('--ffmpeg',type=Path)
    parser.add_argument('--ffprobe',type=Path)
    parser.add_argument('--check-lock',action='store_true')
    args=parser.parse_args()
    if args.check_lock: print(json.dumps(read_lock(args.lock),sort_keys=True)); return
    require(args.ffmpeg is not None and args.ffprobe is not None,'Verified FFMPEG and FFPROBE paths required')
    print('PINNED_FIXTURE_TOOLS='+json.dumps(verify(args.ffmpeg,args.ffprobe,args.lock),sort_keys=True))

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as error:
        raise SystemExit(f'Fixture toolchain verification failed: {error}')
