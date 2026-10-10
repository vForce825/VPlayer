#!/bin/sh
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -eu

product_platform="${CI_PRODUCT_PLATFORM:-}"
if [ -z "$product_platform" ]; then
  # GitHub Actions and local tvOS callers also use this hook. Xcode Cloud
  # always provides CI_PRODUCT_PLATFORM, so a missing value there is an error.
  if [ "${CI_XCODE_CLOUD:-}" = "TRUE" ]; then
    echo "Xcode Cloud preparation failed: CI_PRODUCT_PLATFORM is missing" >&2
    exit 64
  fi
  echo "CI_PRODUCT_PLATFORM is unset outside Xcode Cloud; using the legacy tvOS default"
  product_platform=tvOS
fi

# Values are case-sensitive Apple platform names, not SDK names.
# https://developer.apple.com/documentation/xcode/environment-variable-reference
case "$product_platform" in
  iOS) platform=ios; artifact_directory=Artifacts-iOS ;;
  tvOS) platform=tvos; artifact_directory=Artifacts ;;
  *)
    echo "Xcode Cloud preparation failed: unsupported CI_PRODUCT_PLATFORM: $product_platform" >&2
    exit 64
    ;;
esac

repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
artifact="$repository_root/Vendor/FFmpeg/$artifact_directory/FFmpeg.xcframework"

cd "$repository_root"

if ! command -v jq >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || {
    echo "Xcode Cloud preparation failed: jq and Homebrew are unavailable" >&2
    exit 1
  }
  HOMEBREW_NO_AUTO_UPDATE=1 brew install jq
fi

if [ -f "$artifact/Info.plist" ]; then
  echo "Auditing the existing $product_platform FFmpeg XCFramework"
  ./Scripts/audit-ffmpeg.sh --platform "$platform" "$artifact"
else
  echo "Building the pinned $product_platform FFmpeg XCFramework for Xcode Cloud"
  ./Scripts/build-ffmpeg.sh --platform "$platform"
fi

test -f "$artifact/Info.plist"
