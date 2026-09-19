#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
generator="$root/Scripts/build-metal-libraries.sh"
artifact_directory="$root/Sources/VPlayerPlayback/Resources"
temporary="$(mktemp -d)"

cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

test -x "$generator"
test -s "$artifact_directory/VPlayerPlayback-tvos.metallib"
test -s "$artifact_directory/VPlayerPlayback-tvsimulator.metallib"

"$generator" --output-directory "$temporary"
cmp "$artifact_directory/VPlayerPlayback-tvos.metallib" \
  "$temporary/VPlayerPlayback-tvos.metallib"
cmp "$artifact_directory/VPlayerPlayback-tvsimulator.metallib" \
  "$temporary/VPlayerPlayback-tvsimulator.metallib"

strings "$artifact_directory/VPlayerPlayback-tvos.metallib" \
  | grep -Fq 'apple-tvos26.0.0'
strings "$artifact_directory/VPlayerPlayback-tvsimulator.metallib" \
  | grep -Fq 'apple-tvos26.0.0-simulator'

if grep -Fq 'YADIF.metal in Sources' "$root/VPlayer.xcodeproj/project.pbxproj" \
  || grep -Fq 'ScanProbe.metal in Sources' "$root/VPlayer.xcodeproj/project.pbxproj"; then
  echo "Xcode Cloud 不能在归档时重新编译 Metal 源码" >&2
  exit 1
fi

grep -Fq 'VPlayerPlayback-tvos.metallib in Resources' \
  "$root/VPlayer.xcodeproj/project.pbxproj"
grep -Fq 'VPlayerPlayback-tvsimulator.metallib in Resources' \
  "$root/VPlayer.xcodeproj/project.pbxproj"

echo "Precompiled Metal library OK"
