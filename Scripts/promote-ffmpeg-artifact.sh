#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/Vendor/FFmpeg/Work"
artifacts="$root/Vendor/FFmpeg/Artifacts"
lock_dir="$work/.build-lock"
final="$artifacts/FFmpeg.xcframework"
candidate=""
lock_token=""

fail() {
  echo "FFmpeg promotion failed: $*" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail "this helper accepts no path overrides"
[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || fail "the current build lock is missing or unsafe"
for state_file in owner-pid token candidate; do
  [[ -f "$lock_dir/$state_file" && ! -L "$lock_dir/$state_file" ]] || \
    fail "the current build lock has missing or unsafe state"
done

owner_pid="$(sed -n '1p' "$lock_dir/owner-pid")"
lock_token="$(sed -n '1p' "$lock_dir/token")"
candidate="$(sed -n '1p' "$lock_dir/candidate")"
[[ "$owner_pid" == "$PPID" ]] || fail "the lock is not owned by this helper's build process"
case "$lock_token" in
  *[!A-Za-z0-9._-]*|'') fail "the build lock token is unsafe" ;;
esac
[[ "$candidate" == "$artifacts/.FFmpeg.candidate.$lock_token.xcframework" ]] || \
  fail "the candidate does not match the current build lock token"

lock_is_current() {
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  for state_file in owner-pid token candidate; do
    [[ -f "$lock_dir/$state_file" && ! -L "$lock_dir/$state_file" ]] || return 1
  done
  [[ "$(sed -n '1p' "$lock_dir/owner-pid")" == "$owner_pid" ]] || return 1
  [[ "$(sed -n '1p' "$lock_dir/token")" == "$lock_token" ]] || return 1
  [[ "$(sed -n '1p' "$lock_dir/candidate")" == "$candidate" ]] || return 1
  [[ "$owner_pid" == "$PPID" ]]
}

cleanup_candidate() {
  lock_is_current || return 1
  [[ "$candidate" == "$artifacts/.FFmpeg.candidate.$lock_token.xcframework" ]] || return 1
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    find "$candidate" -type f -delete
    find "$candidate" -type l -delete
    find "$candidate" -depth -type d -empty -delete
  fi
}

cleanup_final() {
  lock_is_current || return 1
  [[ "$final" == "$artifacts/FFmpeg.xcframework" ]] || return 1
  if [[ -e "$final" || -L "$final" ]]; then
    find "$final" -type f -delete
    find "$final" -type l -delete
    find "$final" -depth -type d -empty -delete
  fi
}

cleanup_on_exit() {
  local exit_status=$?
  cleanup_candidate || true
  return "$exit_status"
}

tree_fingerprint() {
  local tree="$1"
  (
    export LC_ALL=C
    find "$tree" -mindepth 1 -print0 | sort -z | \
      while IFS= read -r -d '' entry; do
        relative="${entry#"$tree"/}"
        if [[ -L "$entry" ]]; then
          target="$(readlink "$entry")"
          printf 'L\0%s\0%s\0' "$relative" "$target"
        elif [[ -f "$entry" ]]; then
          digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
          printf 'F\0%s\0%s\0' "$relative" "$digest"
        elif [[ -d "$entry" ]]; then
          printf 'D\0%s\0' "$relative"
        else
          echo "unsupported candidate tree entry: $relative" >&2
          exit 1
        fi
      done
  ) | shasum -a 256 | awk '{print $1}'
}

trap cleanup_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

lock_is_current || fail "the current build lock changed before audit"
[[ -d "$candidate" && ! -L "$candidate" && -f "$candidate/Info.plist" ]] || \
  fail "private staging XCFramework is missing or unsafe"
[[ ! -e "$final" && ! -L "$final" ]] || fail "final XCFramework already exists"

identity_before="$(/usr/bin/stat -f '%d:%i' "$candidate")"
fingerprint_before="$(tree_fingerprint "$candidate")"
"$root/Scripts/audit-ffmpeg.sh" "$candidate"
lock_is_current || fail "the current build lock changed during audit"
[[ -d "$candidate" && ! -L "$candidate" ]] || fail "candidate identity changed during audit"
identity_after="$(/usr/bin/stat -f '%d:%i' "$candidate")"
fingerprint_after="$(tree_fingerprint "$candidate")"
[[ "$identity_after" == "$identity_before" ]] || fail "candidate identity changed during audit"
[[ "$fingerprint_after" == "$fingerprint_before" ]] || fail "candidate tree changed during audit"
[[ "$(/usr/bin/stat -f '%d' "$candidate")" == "$(/usr/bin/stat -f '%d' "$artifacts")" ]] || \
  fail "candidate and final parent are not on the same filesystem"
[[ ! -e "$final" && ! -L "$final" ]] || fail "final XCFramework appeared during audit"

mv "$candidate" "$final"
[[ -d "$final" && ! -e "$candidate" ]] || fail "atomic promotion did not complete"
identity_final="$(/usr/bin/stat -f '%d:%i' "$final")"
fingerprint_final="$(tree_fingerprint "$final")"
if [[ "$identity_final" != "$identity_before" || "$fingerprint_final" != "$fingerprint_before" ]]; then
  cleanup_final || true
  fail "promoted final differs from the audited candidate"
fi

trap - EXIT HUP INT TERM
echo "FFmpeg artifact promoted after stable audit: $final"
