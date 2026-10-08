#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="$root/Sources/VPlayerPlayback/Resources"

platform=tvos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-directory)
      [[ $# -ge 2 ]] || { echo 'Missing output directory' >&2; exit 64; }
      output_directory="$2"; shift 2 ;;
    --platform)
      [[ $# -ge 2 ]] || { echo 'Missing platform' >&2; exit 64; }
      platform="$2"; shift 2 ;;
    *) echo 'Usage: Scripts/build-metal-libraries.sh [--platform tvos|ios] [--output-directory PATH]' >&2; exit 64 ;;
  esac
done
case "$platform" in tvos|ios) ;; *) echo 'Metal platform must be tvos or ios' >&2; exit 64 ;; esac

temporary="$(mktemp -d)"
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

compile_library() {
  local sdk_name="$1"
  local target="$2"
  local output_name="$3"
  local sdk_path metal

  sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  metal="$(xcrun --sdk "$sdk_name" --find metal)"

  "$metal" \
    -c \
    -target "$target" \
    -isysroot "$sdk_path" \
    -fmetal-math-mode=fast \
    -fmetal-math-fp32-functions=fast \
    -o "$temporary/ScanProbe-$sdk_name.air" \
    "$root/Sources/VPlayerPlayback/Scan/ScanProbe.metal"
  "$metal" \
    -c \
    -target "$target" \
    -isysroot "$sdk_path" \
    -fmetal-math-mode=fast \
    -fmetal-math-fp32-functions=fast \
    -o "$temporary/YADIF-$sdk_name.air" \
    "$root/Sources/VPlayerPlayback/Deinterlace/YADIF/YADIF.metal"
  "$metal" \
    -target "$target" \
    -o "$temporary/$output_name" \
    "$temporary/ScanProbe-$sdk_name.air" \
    "$temporary/YADIF-$sdk_name.air"
}

if [[ "$platform" == "tvos" ]]; then
  compile_library appletvos air64-apple-tvos27.0 VPlayerPlayback-tvos.metallib
  compile_library appletvsimulator air64-apple-tvos27.0-simulator VPlayerPlayback-tvsimulator.metallib
  libraries=(VPlayerPlayback-tvos.metallib VPlayerPlayback-tvsimulator.metallib)
else
  compile_library iphoneos air64-apple-ios27.0 VPlayerPlayback-ios.metallib
  compile_library iphonesimulator air64-apple-ios27.0-simulator VPlayerPlayback-iphonesimulator.metallib
  libraries=(VPlayerPlayback-ios.metallib VPlayerPlayback-iphonesimulator.metallib)
fi
mkdir -p "$output_directory"
for library in "${libraries[@]}"; do
  install -m 0644 "$temporary/$library" "$output_directory/$library"
done
