#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(git -C "$script_dir/.." rev-parse --show-toplevel)

case "$#" in
  0)
    mode='generate'
    ;;
  1)
    case "$1" in
      --generate)
        mode='generate'
        ;;
      --check)
        mode='check'
        ;;
      *)
        echo 'Usage: Scripts/bootstrap.sh [--generate|--check]' >&2
        exit 64
        ;;
    esac
    ;;
  *)
    echo 'Usage: Scripts/bootstrap.sh [--generate|--check]' >&2
    exit 64
    ;;
esac

cd "$repo"

ffmpeg_xcframework="$repo/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"
if [[ ! -f "$ffmpeg_xcframework/Info.plist" ]]; then
  echo 'Audited FFmpeg XCFramework is missing. Run ./Scripts/build-ffmpeg.sh' >&2
  exit 1
fi

command -v mint >/dev/null 2>&1 || {
  echo 'Mint is required. Run: brew bundle' >&2
  exit 1
}

mint bootstrap

if [[ "$mode" = 'generate' ]]; then
  mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate \
    --spec "$repo/project.yml" \
    --project "$repo" \
    --project-root "$repo"
  test -f "$repo/VPlayer.xcodeproj/project.pbxproj"
  exit 0
fi

temporary=$(mktemp -d)
cleanup_generated_check() {
  test ! -e "$temporary/VPlayer.xcodeproj/project.pbxproj" || \
    unlink "$temporary/VPlayer.xcodeproj/project.pbxproj"
  test ! -e "$temporary/VPlayer.xcodeproj/project.xcworkspace/contents.xcworkspacedata" || \
    unlink "$temporary/VPlayer.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
  test ! -e "$temporary/VPlayer.xcodeproj/xcshareddata/xcschemes/VPlayer.xcscheme" || \
    unlink "$temporary/VPlayer.xcodeproj/xcshareddata/xcschemes/VPlayer.xcscheme"
  rmdir "$temporary/VPlayer.xcodeproj/project.xcworkspace" 2>/dev/null || true
  rmdir "$temporary/VPlayer.xcodeproj/xcshareddata/xcschemes" 2>/dev/null || true
  rmdir "$temporary/VPlayer.xcodeproj/xcshareddata" 2>/dev/null || true
  rmdir "$temporary/VPlayer.xcodeproj" 2>/dev/null || true
  test ! -L "$temporary/Sources" || unlink "$temporary/Sources"
  test ! -L "$temporary/Tests" || unlink "$temporary/Tests"
  test ! -L "$temporary/Vendor" || unlink "$temporary/Vendor"
  rmdir "$temporary" 2>/dev/null || true
}
trap cleanup_generated_check EXIT

ln -s "$repo/Sources" "$temporary/Sources"
ln -s "$repo/Tests" "$temporary/Tests"
ln -s "$repo/Vendor" "$temporary/Vendor"

mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate --quiet \
  --spec "$repo/project.yml" \
  --project "$temporary" \
  --project-root "$temporary"

if ! cmp "$repo/VPlayer.xcodeproj/project.pbxproj" \
  "$temporary/VPlayer.xcodeproj/project.pbxproj"; then
  echo 'Run Scripts/bootstrap.sh --generate and commit VPlayer.xcodeproj/project.pbxproj.' >&2
  exit 1
fi
