#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts="$root/Vendor/FFmpeg/Artifacts"
candidate="$artifacts/.FFmpeg.candidate.xcframework"
final="$artifacts/FFmpeg.xcframework"

fail() {
  echo "FFmpeg promotion failed: $*" >&2
  exit 1
}

cleanup_candidate() {
  case "$candidate" in
    "$root/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework") ;;
    *) return 1 ;;
  esac
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    find "$candidate" -type f -delete
    find "$candidate" -type l -delete
    find "$candidate" -depth -type d -empty -delete
  fi
}

trap cleanup_candidate EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $# -eq 0 ]] || fail "this helper accepts no path overrides"
[[ -d "$candidate" && -f "$candidate/Info.plist" ]] || fail "fixed staging XCFramework is missing"
[[ ! -e "$final" && ! -L "$final" ]] || fail "final XCFramework already exists"

"$root/Scripts/audit-ffmpeg.sh" "$candidate"
mv "$candidate" "$final"

trap - EXIT HUP INT TERM
echo "FFmpeg artifact promoted after audit: $final"
