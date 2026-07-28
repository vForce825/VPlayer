#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$root/Scripts/promote-ffmpeg-artifact.sh"
build="$root/Scripts/build-ffmpeg.sh"
[[ -x "$helper" ]] || {
  echo "missing FFmpeg promotion helper: $helper" >&2
  exit 1
}
tmp="$(mktemp -d)"

cleanup() {
  find "$tmp" -type f -delete
  find "$tmp" -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

new_promotion_repo() {
  local name="$1" token="fixture.$1.12345"
  local repo="$tmp/promotion-$name"
  local artifacts="$repo/Vendor/FFmpeg/Artifacts"
  local lock_dir="$repo/Vendor/FFmpeg/Work/.build-lock"
  local candidate="$artifacts/.FFmpeg.candidate.$token.xcframework"
  mkdir -p "$repo/Scripts" "$candidate" "$lock_dir"
  cp "$helper" "$repo/Scripts/promote-ffmpeg-artifact.sh"
  printf 'candidate\n' > "$candidate/marker"
  printf 'plist\n' > "$candidate/Info.plist"
  printf '%s\n' "$$" > "$lock_dir/owner-pid"
  printf '%s\n' "$token" > "$lock_dir/token"
  printf '%s\n' "$candidate" > "$lock_dir/candidate"
  printf '%s\n' "$repo"
}

candidate_for_repo() {
  sed -n '1p' "$1/Vendor/FFmpeg/Work/.build-lock/candidate"
}

assert_no_candidate_or_final() {
  local repo="$1" candidate
  candidate="$(candidate_for_repo "$repo")"
  test ! -e "$candidate"
  test ! -L "$candidate"
  test ! -e "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
  test ! -L "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
}

repo="$(new_promotion_repo wrong-owner)"
candidate="$(candidate_for_repo "$repo")"
printf '999999\n' > "$repo/Vendor/FFmpeg/Work/.build-lock/owner-pid"
printf '#!/bin/bash\nexit 0\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
  echo "promotion accepted a lock owned by another process" >&2
  exit 1
fi
test -f "$candidate/marker"
test ! -e "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"

repo="$(new_promotion_repo wrong-candidate)"
candidate="$(candidate_for_repo "$repo")"
printf '%s\n' "$repo/Vendor/FFmpeg/Artifacts/not-the-build-candidate.xcframework" \
  > "$repo/Vendor/FFmpeg/Work/.build-lock/candidate"
printf '#!/bin/bash\nexit 0\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
  echo "promotion accepted a candidate that differs from the lock token" >&2
  exit 1
fi
test -f "$candidate/marker"

repo="$(new_promotion_repo audit-failure)"
printf '#!/bin/bash\nexit 23\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
  echo "promotion accepted a failed audit" >&2
  exit 1
fi
assert_no_candidate_or_final "$repo"

for signal_name in HUP INT TERM; do
  repo="$(new_promotion_repo "audit-signal-$signal_name")"
  printf '#!/bin/bash\nkill -%s "$PPID"\nexit 24\n' "$signal_name" \
    > "$repo/Scripts/audit-ffmpeg.sh"
  chmod +x "$repo/Scripts/audit-ffmpeg.sh"
  if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
    echo "promotion accepted an audit interrupted by $signal_name" >&2
    exit 1
  fi
  assert_no_candidate_or_final "$repo"
done

repo="$(new_promotion_repo audit-mutates-candidate)"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'printf "changed during audit\n" > "$1/marker"' \
  > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
  echo "promotion accepted a candidate changed during audit" >&2
  exit 1
fi
assert_no_candidate_or_final "$repo"

repo="$(new_promotion_repo stale-final)"
candidate="$(candidate_for_repo "$repo")"
mkdir -p "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
printf 'stale final\n' > "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
printf '#!/bin/bash\nexit 0\n' > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
if "$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null 2>&1; then
  echo "promotion overwrote a stale final artifact" >&2
  exit 1
fi
test ! -e "$candidate"
grep -Fqx 'stale final' "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"

repo="$(new_promotion_repo audit-success)"
candidate="$(candidate_for_repo "$repo")"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'root="$(cd "$(dirname "$0")/.." && pwd)"' \
  'test "$#" -eq 1' \
  'test "$1" = "$(sed -n "1p" "$root/Vendor/FFmpeg/Work/.build-lock/candidate")"' \
  'grep -Fqx candidate "$1/marker"' \
  'printf "called\n" > "$root/audit-called"' \
  > "$repo/Scripts/audit-ffmpeg.sh"
chmod +x "$repo/Scripts/audit-ffmpeg.sh"
"$repo/Scripts/promote-ffmpeg-artifact.sh" >/dev/null
test ! -e "$candidate"
test -f "$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
test -f "$repo/audit-called"

new_build_repo() {
  local name="$1" repo="$tmp/build-$1"
  mkdir -p "$repo/Scripts" "$repo/Vendor/FFmpeg" "$repo/test-bin"
  cp "$build" "$repo/Scripts/build-ffmpeg.sh"
  cp "$root/Vendor/FFmpeg/ffmpeg.lock.json" "$repo/Vendor/FFmpeg/"
  cp "$root/Vendor/FFmpeg/configure.flags" "$repo/Vendor/FFmpeg/"
  cp "$root/Vendor/FFmpeg/component-manifest.json" "$repo/Vendor/FFmpeg/"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'repo=""' \
    'if [[ "${1:-}" == "-C" ]]; then repo="$2"; shift 2; fi' \
    'while [[ "${1:-}" == "-c" ]]; do shift 2; done' \
    'case "${1:-}" in' \
    '  init) mkdir -p "$repo/.git" ;;' \
    '  remote)' \
    '    if [[ "${2:-}" == "get-url" ]]; then' \
    '      printf "https://git.ffmpeg.org/ffmpeg.git\n"' \
    '    fi' \
    '    ;;' \
    '  fetch)' \
    '    : "${VPLAYER_TEST_CONTROL:?}"' \
    '    : > "$VPLAYER_TEST_CONTROL/fetch-started"' \
    '    while [[ ! -f "$VPLAYER_TEST_CONTROL/release-fetch" ]]; do sleep 0.05; done' \
    '    if [[ -f "$VPLAYER_TEST_CONTROL/signal" ]]; then' \
    '      kill -"$(sed -n "1p" "$VPLAYER_TEST_CONTROL/signal")" "$PPID"' \
    '      exit 24' \
    '    fi' \
    '    exit "$(sed -n "1p" "$VPLAYER_TEST_CONTROL/fetch-exit")"' \
    '    ;;' \
    '  *) exit 91 ;;' \
    'esac' \
    > "$repo/test-bin/git"
  chmod +x "$repo/test-bin/git"
  printf '%s\n' "$repo"
}

wait_for_file() {
  local file="$1" process="$2" attempts=0
  while [[ ! -f "$file" ]]; do
    if ! kill -0 "$process" 2>/dev/null; then
      wait "$process" || true
      echo "fixture build exited before reaching the held fetch" >&2
      exit 1
    fi
    attempts=$((attempts + 1))
    [[ "$attempts" -lt 200 ]] || {
      kill -TERM "$process" 2>/dev/null || true
      echo "timed out waiting for fixture build" >&2
      exit 1
    }
    sleep 0.05
  done
}

start_held_build() {
  local repo="$1" control="$2"
  mkdir -p "$control"
  printf '23\n' > "$control/fetch-exit"
  PATH="$repo/test-bin:$PATH" VPLAYER_TEST_CONTROL="$control" \
    "$repo/Scripts/build-ffmpeg.sh" > "$control/output" 2>&1 &
  held_build_pid=$!
  wait_for_file "$control/fetch-started" "$held_build_pid"
  held_candidate="$(sed -n '1p' "$repo/Vendor/FFmpeg/Work/.build-lock/candidate")"
}

signal_held_build() {
  local signal_name="$1" process="$2" control="$3" attempts=0
  printf '%s\n' "$signal_name" > "$control/signal"
  : > "$control/release-fetch"
  while kill -0 "$process" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 200 ]]; then
      kill -TERM "$process" 2>/dev/null || true
      wait "$process" || true
      echo "fixture build did not handle $signal_name" >&2
      exit 1
    fi
    sleep 0.05
  done
  wait "$process" || true
}

build_repo="$(new_build_repo lifecycle)"
control="$tmp/control-first"
start_held_build "$build_repo" "$control"
first_pid="$held_build_pid"
first_candidate="$held_candidate"
lock_mode="$(/usr/bin/stat -f '%Lp' "$build_repo/Vendor/FFmpeg/Work/.build-lock")"
if [[ "$lock_mode" != "700" ]]; then
  : > "$control/release-fetch"
  wait "$first_pid" || true
  echo "active FFmpeg build lock mode is $lock_mode, expected 700" >&2
  exit 1
fi
case "$first_candidate" in
  "$build_repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate."*.xcframework) ;;
  *) echo "candidate is not a private .xcframework staging path: $first_candidate" >&2; exit 1 ;;
esac
mkdir -p "$first_candidate" "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
printf 'first candidate\n' > "$first_candidate/marker"
printf 'first final\n' > "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"

second_control="$tmp/control-second-rejected"
mkdir -p "$second_control"
printf '23\n' > "$second_control/fetch-exit"
if PATH="$build_repo/test-bin:$PATH" VPLAYER_TEST_CONTROL="$second_control" \
  "$build_repo/Scripts/build-ffmpeg.sh" > "$second_control/output" 2>&1; then
  echo "a concurrent FFmpeg build acquired the active lock" >&2
  exit 1
fi
grep -F 'FFmpeg build lock already exists' "$second_control/output" >/dev/null
grep -F 'confirming no FFmpeg build is running' "$second_control/output" >/dev/null
grep -Fqx 'first candidate' "$first_candidate/marker"
grep -Fqx 'first final' "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
signal_held_build TERM "$first_pid" "$control"
test ! -e "$first_candidate"
test ! -e "$build_repo/Vendor/FFmpeg/Work/.build-lock"

control="$tmp/control-unique"
start_held_build "$build_repo" "$control"
second_pid="$held_build_pid"
second_candidate="$held_candidate"
test "$second_candidate" != "$first_candidate"
case "$second_candidate" in
  "$build_repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate."*.xcframework) ;;
  *) echo "second candidate is not a private .xcframework staging path" >&2; exit 1 ;;
esac
mkdir -p "$second_candidate"
printf 'candidate on failure\n' > "$second_candidate/marker"
: > "$control/release-fetch"
wait "$second_pid" || true
test ! -e "$second_candidate"
test ! -e "$build_repo/Vendor/FFmpeg/Work/.build-lock"
test ! -e "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"

for signal_name in HUP INT TERM; do
  control="$tmp/control-build-$signal_name"
  start_held_build "$build_repo" "$control"
  signal_pid="$held_build_pid"
  signal_candidate="$held_candidate"
  mkdir -p "$signal_candidate"
  printf 'candidate before signal\n' > "$signal_candidate/marker"
  signal_held_build "$signal_name" "$signal_pid" "$control"
  test ! -e "$signal_candidate"
  test ! -e "$build_repo/Vendor/FFmpeg/Work/.build-lock"
done

stale_lock="$build_repo/Vendor/FFmpeg/Work/.build-lock"
stale_token='stale.fixture.12345'
stale_candidate="$build_repo/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.$stale_token.xcframework"
mkdir -p "$stale_lock" "$stale_candidate" "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
printf '999999\n' > "$stale_lock/owner-pid"
printf '%s\n' "$stale_token" > "$stale_lock/token"
printf '%s\n' "$stale_candidate" > "$stale_lock/candidate"
printf 'stale candidate\n' > "$stale_candidate/marker"
printf 'stale final\n' > "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
stale_control="$tmp/control-stale"
mkdir -p "$stale_control"
printf '23\n' > "$stale_control/fetch-exit"
if PATH="$build_repo/test-bin:$PATH" VPLAYER_TEST_CONTROL="$stale_control" \
  "$build_repo/Scripts/build-ffmpeg.sh" > "$stale_control/output" 2>&1; then
  echo "build automatically stole a stale-looking lock" >&2
  exit 1
fi
test -d "$stale_lock"
grep -Fqx 'stale candidate' "$stale_candidate/marker"
grep -Fqx 'stale final' "$build_repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/marker"
grep -F 'remove only the three state files' "$stale_control/output" >/dev/null

acquire_line="$(grep -nF 'acquire_build_lock' "$build" | tail -1 | cut -d: -f1)"
cleanup_line="$(grep -nF 'clear_generated_directory "$artifacts"' "$build" | head -1 | cut -d: -f1)"
fetch_line="$(grep -nF 'fetch --force --no-tags --depth 1 "$fetch_url"' "$build" | head -1 | cut -d: -f1)"
test "$acquire_line" -lt "$cleanup_line"
test "$acquire_line" -lt "$fetch_line"
grep -F 'candidate="$artifacts/.FFmpeg.candidate.$lock_token.xcframework"' "$build" >/dev/null
grep -F -- '-output "$candidate"' "$build" >/dev/null
grep -F '"$root/Scripts/promote-ffmpeg-artifact.sh"' "$build" >/dev/null
if grep -F '.FFmpeg.candidate.xcframework' "$build" >/dev/null; then
  echo "build still uses a global fixed candidate path" >&2
  exit 1
fi

echo "FFmpeg promotion and lifecycle lock gate OK"
