#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$root/Scripts/promote-ffmpeg-artifact.sh"
build="$root/Scripts/build-ffmpeg.sh"
[[ -x "$helper" ]] || {
  echo "missing fixed-path FFmpeg promotion helper: $helper" >&2
  exit 1
}
tmp="$(mktemp -d)"

cleanup() {
  find "$tmp" -type f -delete
  find "$tmp" -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

new_repo() {
  local name="$1"
  local repo="$tmp/$name"
  mkdir -p "$repo/Scripts" "$repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework"
  cp "$helper" "$repo/Scripts/promote-ffmpeg-artifact.sh"
  printf 'candidate\n' > "$repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework/marker"
  printf 'plist\n' > "$repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework/Info.plist"
  printf '%s\n' "$repo"
}

assert_no_candidate_or_final() {
  local repo="$1"
  test ! -e "$repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework"
  test ! -e "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
}

repo="$(new_repo audit-failure)"
printf '#!/bin/bash\nexit 23\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh"; then
  echo "promotion accepted a failed audit" >&2
  exit 1
fi
assert_no_candidate_or_final "$repo"

repo="$(new_repo audit-signal)"
printf '#!/bin/bash\nkill -TERM "$PPID"\nexit 24\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh"; then
  echo "promotion accepted an interrupted audit" >&2
  exit 1
fi
assert_no_candidate_or_final "$repo"

repo="$(new_repo audit-success)"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'root="$(cd "$(dirname "$0")/.." && pwd)"' \
  'test "$#" -eq 1' \
  'test "$1" = "$root/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework"' \
  'test -f "$1/marker"' \
  'printf "called\\n" > "$root/audit-called"' \
  > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
"$repo/Scripts/promote-ffmpeg-artifact.sh"
test ! -e "$repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework"
test -f "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
test -f "$repo/audit-called"

grep -F 'candidate="$artifacts/.FFmpeg.candidate.xcframework"' "$build" >/dev/null
grep -F -- '-output "$candidate"' "$build" >/dev/null
grep -F '"$root/Scripts/promote-ffmpeg-artifact.sh"' "$build" >/dev/null
cleanup_line="$(grep -nF 'clear_generated_directory "$artifacts"' "$build" | head -1 | cut -d: -f1)"
fetch_line="$(grep -nF 'git -C "$source" fetch' "$build" | head -1 | cut -d: -f1)"
test "$cleanup_line" -lt "$fetch_line"
if grep -F -- '-output "$xcframework"' "$build" >/dev/null; then
  echo "build still writes the final XCFramework before audit" >&2
  exit 1
fi

echo "FFmpeg promotion gate OK"
