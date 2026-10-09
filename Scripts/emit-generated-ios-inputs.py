#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Transfer only allowlisted public generated inputs through read-only CI logs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('mode',choices=['capture','emit'])
parser.add_argument('--baseline',required=True,type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
paths=['VPlayer.xcodeproj/project.pbxproj']
paths += [f'VPlayer.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme' for name in
          ['VPlayer','VPlayerReleaseBoundaryTests','VPlayerReleaseStartupTests','VPlayerHLSAcceptance','VPlayeriOS','VPlayeriOSReleaseStartup','VPlayeriOSBenchmarks']]
paths += [f'Sources/VPlayerPlayback/Resources/{name}.metallib' for name in
          ['VPlayerPlayback-ios','VPlayerPlayback-iphonesimulator']]
def read(name):
    path=root/name
    if not path.exists():return None
    if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink():
        raise SystemExit('Generated input escapes checkout')
    data=path.read_bytes()
    if len(data)>2*1024*1024:raise SystemExit('Generated input exceeds transfer limit')
    return data
current={name:(hashlib.sha256(data).hexdigest() if (data:=read(name)) is not None else None) for name in paths}
if args.mode=='capture':
    args.baseline.write_text(json.dumps(current,sort_keys=True))
else:
    if any(value is None for value in current.values()):raise SystemExit('Generator omitted a required input')
    old=json.loads(args.baseline.read_text())
    changed=current!=old
    output=os.environ.get('GITHUB_OUTPUT')
    if output:
        with open(output,'a') as stream:stream.write('needs_refresh='+str(changed).lower()+'\n')
    print('GENERATED_INPUTS_NEED_REFRESH='+str(changed).lower())
    if changed:
        for name in paths:
            data=read(name)
            print('VPLAYER_GENERATED_BEGIN '+json.dumps({'path':name,'bytes':len(data),'sha256':current[name]},sort_keys=True))
            encoded=base64.b64encode(data).decode('ascii')
            for start in range(0,len(encoded),12000):print('VPLAYER_GENERATED_DATA '+encoded[start:start+12000])
            print('VPLAYER_GENERATED_END')
