#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Give one fixture generator and its descendants a fixed 300-second wall budget."""
import os
import signal
import subprocess
import sys
import time
if len(sys.argv)<2: raise SystemExit('Generator command required')
start=time.monotonic()
process=subprocess.Popen(sys.argv[1:],start_new_session=True)
try:
    status=process.wait(timeout=300)
except subprocess.TimeoutExpired:
    # This group was created above solely for this fixture command.
    os.killpg(process.pid,signal.SIGKILL)
    process.wait()
    raise SystemExit('Fixture generation exceeded the fixed 300-second wall budget')
print(f'FIXTURE_GENERATION_WALL_SECONDS={time.monotonic()-start:.3f}')
raise SystemExit(status)
