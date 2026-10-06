#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Inject verified provenance into the sole generated FiveMinute test configuration."""
import plistlib
import hashlib
from pathlib import Path
import sys

root,head,tree,fixture,role,overlay=sys.argv[1:]
measurement_hash=hashlib.sha256(b''.join(path.read_bytes() for path in sorted(Path('Tests/VPlayerHLSAcceptanceTests').glob('*.swift')))).hexdigest()
files=list((Path(root)/'Build/Products').glob('*.xctestrun'))
assert len(files)==1, 'Expected one generated xctestrun'
with files[0].open('rb') as stream: document=plistlib.load(stream)
configs=document.get('TestConfigurations',[])
assert len(configs)==1 and configs[0].get('Name')=='FiveMinute', 'Only FiveMinute is allowed'
targets=configs[0].get('TestTargets',[])
assert len(targets)==1 and targets[0].get('BlueprintName')=='VPlayerHLSAcceptanceTests'
targets[0].setdefault('EnvironmentVariables',{}).update({
    'HLS_ACCEPTANCE_HEAD':head,'HLS_ACCEPTANCE_TREE':tree,'HLS_ACCEPTANCE_FIXTURE_SHA256':fixture,
    'HLS_ACCEPTANCE_ROLE':role,'HLS_ACCEPTANCE_OVERLAY_SHA256':overlay,
    'HLS_ACCEPTANCE_MEASUREMENT_SHA256':measurement_hash})
# __TESTROOT__ and DYLD paths are relative to this exact Products directory.
with files[0].open('wb') as stream:
    plistlib.dump(document,stream,fmt=plistlib.FMT_BINARY,sort_keys=False)
print(files[0])
