#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
pbxproj="$repo/VPlayer.xcodeproj/project.pbxproj"

before=$(shasum -a 256 "$pbxproj")
status_before=$(git -C "$repo" status --porcelain=v1)
"$repo/Scripts/bootstrap.sh" --check
after=$(shasum -a 256 "$pbxproj")
status_after=$(git -C "$repo" status --porcelain=v1)
test "$before" = "$after"
test "$status_before" = "$status_after"

expect_exit_64() {
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" -ne 64 ]]; then
    echo "expected exit 64, got $status: $*" >&2
    exit 1
  fi
}

expect_exit_64 "$repo/Scripts/bootstrap.sh" --unknown
expect_exit_64 "$repo/Scripts/bootstrap.sh" --check extra
expect_exit_64 "$repo/Scripts/bootstrap.sh" --generate extra
expect_exit_64 "$repo/Scripts/bootstrap.sh" --check --check

temporary_root=$(mktemp -d)
worktree="$temporary_root/repo"
cleanup() {
  git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rmdir "$temporary_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null
cp "$repo/Scripts/bootstrap.sh" "$worktree/Scripts/bootstrap.sh"
chmod +x "$worktree/Scripts/bootstrap.sh"
cp "$pbxproj" "$worktree/VPlayer.xcodeproj/project.pbxproj"

ffmpeg_link="$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
test -d "$ffmpeg_link"
ffmpeg_source=$(cd "$ffmpeg_link" && pwd -P)
test -f "$ffmpeg_source/Info.plist"
plutil -lint "$ffmpeg_source/Info.plist" >/dev/null

mkdir -p "$worktree/Vendor/FFmpeg/Artifacts"
ffmpeg_target="$worktree/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
test ! -e "$ffmpeg_target"
test ! -L "$ffmpeg_target"
ln -s "$ffmpeg_source" "$ffmpeg_target"

rg -q 'SWIFT_VERSION: "6\.0"' "$worktree/project.yml"
perl -0pi -e 's/SWIFT_VERSION: "6\.0"/SWIFT_VERSION: "5.9"/' \
  "$worktree/project.yml"
! rg -q 'SWIFT_VERSION: "6\.0"' "$worktree/project.yml"
test "$(rg -c 'SWIFT_VERSION: "5\.9"' "$worktree/project.yml")" -eq 1

stale_before=$(shasum -a 256 "$worktree/VPlayer.xcodeproj/project.pbxproj")
stale_status_before=$(git -C "$worktree" status --porcelain=v1)
if "$worktree/Scripts/bootstrap.sh" --check; then
  echo 'expected stale generated project check to fail' >&2
  exit 1
fi
stale_after=$(shasum -a 256 "$worktree/VPlayer.xcodeproj/project.pbxproj")
stale_status_after=$(git -C "$worktree" status --porcelain=v1)
test "$stale_before" = "$stale_after"
test "$stale_status_before" = "$stale_status_after"

"$worktree/Scripts/bootstrap.sh" --generate
"$worktree/Scripts/bootstrap.sh" --check
