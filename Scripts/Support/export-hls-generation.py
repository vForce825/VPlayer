#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Bounded, explicitly allowlisted public fixture/project readback; no publication."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess

# Reviewed source family plus four explicitly approved large-AU fixtures. Never export arbitrary added files.
SOURCE_FILES = frozenset({
    'audio-alternate.m3u8','audio.m3u8','audio.ts','fmp4.m3u8','interlaced-h264-aac.ts',
    'hevc-sdr.mp4','hevc-hlg.mp4','encrypted-aac.mp4','encrypted-av.mp4','aac-lc.adts',
    'aac-implicit-sbr-signaling.adts','master.m3u8','progressive-0.m4s','progressive-1.m4s',
    'progressive-init.mp4','provenance.json','subtitles.m3u8','subtitles.vtt',
    'video-high.m3u8','video-high.ts','video-low.m3u8','video-low.ts',
    'large-au.ts','large-au.mp4','large-au-limit.mp4','large-au-over-limit.mp4','SHA256SUMS'})
SCHEMES = frozenset({'VPlayer.xcscheme','VPlayerReleaseBoundaryTests.xcscheme',
    'VPlayerReleaseStartupTests.xcscheme','VPlayerHLSAcceptance.xcscheme'})


def collect_files(root):
    sources=root/'Tests/Fixtures/SourcePlanning'
    schemes=root/'VPlayer.xcodeproj/xcshareddata/xcschemes'
    if sources.is_symlink() or schemes.is_symlink():
        raise ValueError('Readback directories cannot be symlinks')
    if {path.name for path in sources.iterdir()} != SOURCE_FILES:
        raise ValueError('SourcePlanning inventory differs from the reviewed public generator')
    if {path.name for path in schemes.iterdir()} != SCHEMES:
        raise ValueError('Shared scheme inventory differs from the reviewed targets')
    files=[root/'VPlayer.xcodeproj/project.pbxproj',root/'VPlayerHLSAcceptance.xctestplan']
    files += [schemes/name for name in sorted(SCHEMES)]
    files += [sources/name for name in sorted(SOURCE_FILES)]
    if any(not path.is_file() or path.is_symlink() for path in files):
        raise ValueError('Readback accepts only regular allowlisted files')
    if sum(path.stat().st_size for path in files)>16*1024**2:
        raise ValueError('Readback exceeds 16 MiB bound')
    return files


def main():
    root=Path.cwd()
    files=collect_files(root)
    # The committed generator owns the exact hash manifest and pinned provenance.
    subprocess.run(['./Scripts/generate-source-planning-fixtures.sh','--verify'],check=True)
    print('GENERATION_SOURCE='+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    print('GENERATION_SOURCE_TREE='+subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip())
    for path in files:
        name=str(path.relative_to(root))
        data=path.read_bytes(); encoded=base64.b64encode(data).decode()
        print('GENERATED_FILE='+json.dumps({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}))
        for index in range(0,len(encoded),4096):
            print('GENERATED_CHUNK='+json.dumps({'path':name,'offset':index,'base64':encoded[index:index+4096]}))
        print('GENERATED_END='+name)
    print('PREPARATION_ONLY_NOT_ACCEPTANCE=true')

if __name__=='__main__': main()
