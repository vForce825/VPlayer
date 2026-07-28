#!/bin/sh
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -eu

repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
artifact="$repository_root/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework"

cd "$repository_root"

if ! command -v jq >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || {
    echo "Xcode Cloud preparation failed: jq and Homebrew are unavailable" >&2
    exit 1
  }
  HOMEBREW_NO_AUTO_UPDATE=1 brew install jq
fi

if [ -f "$artifact/Info.plist" ]; then
  echo "Auditing the existing FFmpeg XCFramework"
  ./Scripts/audit-ffmpeg.sh "$artifact"
else
  echo "Building the pinned FFmpeg XCFramework for Xcode Cloud"
  ./Scripts/build-ffmpeg.sh
fi

test -f "$artifact/Info.plist"
