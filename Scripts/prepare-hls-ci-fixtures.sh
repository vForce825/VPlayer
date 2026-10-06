#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="${1:---verify-committed}"
[[ $# -le 1 ]] || { echo 'One fixture preparation mode is required.' >&2; exit 64; }
case "$mode" in --project-readback|--verify-committed|--acceptance) ;;
  *) echo 'Usage: Scripts/prepare-hls-ci-fixtures.sh --project-readback|--verify-committed|--acceptance' >&2; exit 64;;
esac
./Scripts/verify-hls-fixture-toolchain.sh
export PATH="$(dirname "$FFMPEG"):$PATH"
./Scripts/generate-playback-fixtures.sh --verify
if [[ "$mode" == --project-readback ]]; then
  # Only the reviewed preparation/readback stage generates these committed inputs.
  python3 Scripts/Support/run-bounded-generation.py ./Scripts/generate-source-planning-fixtures.sh --generate
else
  # CENC initialization vectors may vary on regeneration. Final gates must read
  # the exact committed files and manifest, never rewrite either during acceptance.
  ./Scripts/generate-source-planning-fixtures.sh --verify
  for file in Tests/Fixtures/SourcePlanning/*; do
    git ls-files --error-unmatch -- "$file" >/dev/null
  done
  git diff --exit-code HEAD -- Tests/Fixtures/SourcePlanning
fi
# Mandatory short diagnostic is always runner-local, not a committed source family.
python3 Scripts/Support/run-bounded-generation.py python3 Scripts/generate-homepod-audio-diagnostic-fixture.py --output Tests/Fixtures/Video/synthetic-hlg50-ac3-64s.ts
if [[ "$mode" == --acceptance ]]; then
  # Large public transport fixture is only needed by the dedicated acceptance job.
  python3 Scripts/Support/run-bounded-generation.py python3 Scripts/generate-hls-acceptance-fixture.py
fi
