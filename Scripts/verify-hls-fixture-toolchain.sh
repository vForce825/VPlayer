#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ -z "${FFMPEG:-}" || -z "${FFPROBE:-}" ]]; then
  actual='not installed'
  if command -v ffmpeg >/dev/null 2>&1; then actual="$(ffmpeg -version 2>&1 | sed -n '1p')"; fi
  echo "Verified fixture-only CLI paths are missing; run Scripts/provision-hls-fixture-toolchain.sh. PATH actual: $actual" >&2
  exit 1
fi
python3 "$repository/Scripts/Support/hls_fixture_toolchain.py" \
  --lock "$repository/Vendor/FFmpeg/ffmpeg.lock.json" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE"
