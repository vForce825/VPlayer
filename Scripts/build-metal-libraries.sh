#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="$root/Sources/VPlayerPlayback/Resources"

if [[ "$#" -gt 0 ]]; then
  if [[ "$#" -ne 2 || "$1" != "--output-directory" ]]; then
    echo "Usage: Scripts/build-metal-libraries.sh [--output-directory PATH]" >&2
    exit 64
  fi
  output_directory="$2"
fi

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

compile_library \
  appletvos \
  air64-apple-tvos26.0 \
  VPlayerPlayback-tvos.metallib
compile_library \
  appletvsimulator \
  air64-apple-tvos26.0-simulator \
  VPlayerPlayback-tvsimulator.metallib

mkdir -p "$output_directory"
install -m 0644 \
  "$temporary/VPlayerPlayback-tvos.metallib" \
  "$output_directory/VPlayerPlayback-tvos.metallib"
install -m 0644 \
  "$temporary/VPlayerPlayback-tvsimulator.metallib" \
  "$output_directory/VPlayerPlayback-tvsimulator.metallib"
