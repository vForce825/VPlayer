#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ffmpeg_xcframework='Vendor/FFmpeg/Artifacts/FFmpeg.xcframework'
if [[ ! -f "$ffmpeg_xcframework/Info.plist" ]]; then
  echo 'Audited FFmpeg XCFramework is missing. Run ./Scripts/build-ffmpeg.sh' >&2
  exit 1
fi

command -v mint >/dev/null 2>&1 || {
  echo 'Mint is required. Run: brew bundle' >&2
  exit 1
}

mint bootstrap
mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate --spec project.yml
test -f VPlayer.xcodeproj/project.pbxproj
