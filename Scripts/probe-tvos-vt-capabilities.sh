#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
sdk="$(xcrun --sdk appletvsimulator --show-sdk-path)"
work="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-vt-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Include the selected SDK's exact capability contract alongside the runtime data.
python3 - "$sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTCompressionProperties.h" <<'PY'
import pathlib,sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for symbol in ('kVTCompressionPropertyKey_AllowOpenGOP', 'kVTCompressionPropertyKey_OutputBitDepth', 'kVTCompressionPropertyKey_FieldCount'):
    for i,line in enumerate(lines):
        if symbol in line and ('VT_EXPORT' in line or 'extern' in line):
            start = i
            while start > 0 and '/*!' not in lines[start] and '/**' not in lines[start]:
                start -= 1
                if i-start > 45:
                    start = max(0,i-25)
                    break
            print('VT_PROBE_SDK_HEADER ' + symbol)
            print('\n'.join(lines[start:i+3]))
            break
PY

xcrun --sdk appletvsimulator clang -Wall -Wextra \
  -target arm64-apple-tvos27.0-simulator -isysroot "$sdk" \
  Scripts/Support/tvos_vt_capability_probe.c \
  -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  -o "$work/vt-capability-probe"
python3 - "$work/vt-capability-probe" <<'PY'
import json,subprocess,sys
r=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
devices=r['devices']['com.apple.CoreSimulator.SimRuntime.tvOS-27-0']
d=next(x for x in devices if x['name']=='Apple TV 4K (3rd generation)')
if d['state']!='Booted':
    subprocess.run(['xcrun','simctl','boot',d['udid']],check=True,timeout=60)
subprocess.run(['xcrun','simctl','bootstatus',d['udid'],'-b'],check=True,timeout=180)
subprocess.run(['xcrun','simctl','spawn',d['udid'],sys.argv[1]],check=True,timeout=120)
PY
