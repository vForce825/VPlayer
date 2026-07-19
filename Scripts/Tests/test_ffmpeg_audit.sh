#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'find "$tmp" -type f -delete; find "$tmp" -depth -type d -empty -delete' EXIT

cp "$root/Vendor/FFmpeg/component-manifest.json" "$tmp/manifest.json"

assert_rejected() {
  local candidate="$1" description="$2"
  if "$root/Scripts/audit-ffmpeg.sh" --manifest-only "$candidate"; then
    echo "audit accepted $description" >&2
    exit 1
  fi
}

jq '.protocols += ["udp"]' "$tmp/manifest.json" > "$tmp/extra-protocol.json"
assert_rejected "$tmp/extra-protocol.json" "udp"

jq 'del(.decoders)' "$tmp/manifest.json" > "$tmp/missing-key.json"
assert_rejected "$tmp/missing-key.json" "a missing manifest key"

jq '.libraries += ["avfilter"]' "$tmp/manifest.json" > "$tmp/extra-library.json"
assert_rejected "$tmp/extra-library.json" "avfilter"

"$root/Scripts/audit-ffmpeg.sh" --manifest-only "$tmp/manifest.json"
"$root/Scripts/Tests/test_ffmpeg_artifact_audit.sh"
"$root/Scripts/Tests/test_ffmpeg_promotion.sh"
echo "FFmpeg audit tamper test OK"
