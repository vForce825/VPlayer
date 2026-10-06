#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Read target ID from genuine pinned-XcodeGen output, never edit a pbxproj."""
import json
from pathlib import Path
import subprocess
project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',
    'VPlayer.xcodeproj/project.pbxproj']))
identifiers=[key for key,value in project['objects'].items() if value.get('isa')=='PBXNativeTarget'
    and value.get('name')=='VPlayerHLSAcceptanceTests']
assert len(identifiers)==1, 'Generated acceptance target is missing/ambiguous'
path=Path('VPlayerHLSAcceptance.xctestplan')
plan=json.loads(path.read_text())
assert [item['name'] for item in plan['configurations']]==['FiveMinute']
plan['testTargets'][0]['target']['identifier']=identifiers[0]
path.write_text(json.dumps(plan,indent=2)+'\n')
