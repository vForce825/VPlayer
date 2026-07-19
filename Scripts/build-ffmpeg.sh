#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

# Make both FFmpeg's intermediate archives and the combined archive omit
# wall-clock member timestamps on Darwin.
export ZERO_AR_DATE=1

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
flags_file="$root/Vendor/FFmpeg/configure.flags"
manifest="$root/Vendor/FFmpeg/component-manifest.json"
work="$root/Vendor/FFmpeg/Work"
source="$work/source"
artifacts="$root/Vendor/FFmpeg/Artifacts"
candidate="$artifacts/.FFmpeg.candidate.xcframework"
sdk_version_floor="18.0"

fail() {
  echo "FFmpeg build failed: $*" >&2
  exit 1
}

clear_generated_directory() {
  local directory="$1"
  case "$directory" in
    "$work"/build-device|"$work"/build-sim-arm64|"$work"/build-sim-x86_64|\
    "$work"/install-device|"$work"/install-sim-arm64|"$work"/install-sim-x86_64|\
    "$work"/install-simulator|"$artifacts") ;;
    *) fail "refusing to clear unexpected path: $directory" ;;
  esac
  mkdir -p "$directory"
  find "$directory" -mindepth 1 -type f -delete
  find "$directory" -mindepth 1 -type l -delete
  find "$directory" -mindepth 1 -depth -type d -empty -delete
}

cleanup_candidate() {
  case "$candidate" in
    "$root/Vendor/FFmpeg/Artifacts/.FFmpeg.candidate.xcframework") ;;
    *) return 1 ;;
  esac
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    find "$candidate" -type f -delete
    find "$candidate" -type l -delete
    find "$candidate" -depth -type d -empty -delete
  fi
}

trap cleanup_candidate EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Remove both any old final artifact and the fixed staging path before work
# begins. Any later failure or signal leaves no candidate or stale final.
clear_generated_directory "$artifacts"

for tool in git jq make shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
for tool in /usr/bin/xcrun /usr/bin/libtool /usr/bin/lipo /usr/bin/plutil; do
  [[ -x "$tool" ]] || fail "$tool is required"
done
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"

source_url="$(jq -er '.sourceURL' "$lock")"
tag="$(jq -er '.tag' "$lock")"
commit="$(jq -er '.commit' "$lock")"
license_mode="$(jq -er '.licenseMode' "$lock")"
[[ "$source_url" == "https://git.ffmpeg.org/ffmpeg.git" ]] || fail "unexpected source URL"
[[ "$tag" == "n8.1.2" ]] || fail "unexpected tag"
[[ "$commit" == "38b88335f99e76ed89ff3c93f877fdefce736c13" ]] || fail "unexpected commit"
[[ "$license_mode" == "LGPL-2.1-or-later" ]] || fail "unexpected license mode"

mkdir -p "$work" "$artifacts"
if [[ ! -d "$source/.git" ]]; then
  mkdir -p "$source"
  git -C "$source" init
  git -C "$source" remote add origin "$source_url"
fi
[[ "$(git -C "$source" remote get-url origin)" == "$source_url" ]] || fail "existing source origin differs from lock"
# The official server does not permit fetching the unadvertised commit by SHA.
# Fetch the advertised annotated tag, then prove that it peels to the lock.
git -C "$source" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
[[ "$(git -C "$source" rev-parse "refs/tags/$tag^{}")" == "$commit" ]] || fail "$tag does not peel to the locked commit"
git -C "$source" checkout --detach "$commit"
[[ "$(git -C "$source" rev-parse HEAD)" == "$commit" ]] || fail "source checkout differs from lock"
[[ -z "$(git -C "$source" status --porcelain)" ]] || fail "source checkout contains local modifications"
cmp -s "$source/COPYING.LGPLv2.1" "$root/Vendor/FFmpeg/LICENSE.md" || fail "LICENSE.md must be a byte-for-byte upstream copy"
cmp -s "$source/LICENSE.md" "$root/Vendor/FFmpeg/UPSTREAM-LICENSE.md" || fail "UPSTREAM-LICENSE.md must be a byte-for-byte upstream copy"

common_flags=()
while IFS= read -r flag; do
  [[ -n "$flag" ]] && common_flags+=("$flag")
done < "$flags_file"
flags_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$flags_file")"
license_sha="$(shasum -a 256 "$root/Vendor/FFmpeg/LICENSE.md" | awk '{print $1}')"

build_slice() {
  local name="$1" sdk="$2" arch="$3" triple="$4"
  local build="$work/build-$name" prefix="$work/install-$name"
  local configure_flags=("${common_flags[@]}")
  if [[ "$name" == "sim-x86_64" ]]; then
    # Xcode 26 does not ship NASM/YASM. Assembly is retained on arm64, while
    # the simulator-only x86_64 compatibility slice uses the C fallback.
    configure_flags+=("--disable-x86asm")
  fi

  clear_generated_directory "$build"
  clear_generated_directory "$prefix"
  pushd "$build" >/dev/null
  "$source/configure" \
    "${configure_flags[@]}" \
    --target-os=darwin \
    --enable-cross-compile \
    --arch="$arch" \
    --cc="$(/usr/bin/xcrun --sdk "$sdk" --find clang)" \
    --ar="$(/usr/bin/xcrun --sdk "$sdk" --find ar)" \
    --ranlib="$(/usr/bin/xcrun --sdk "$sdk" --find ranlib)" \
    --sysroot="$(/usr/bin/xcrun --sdk "$sdk" --show-sdk-path)" \
    --extra-cflags="-target $triple -fapplication-extension" \
    --extra-ldflags="-target $triple" \
    --prefix="$prefix"
  make -j"$(sysctl -n hw.logicalcpu)"
  make install

  /usr/bin/libtool -static -o "$prefix/lib/libFFmpeg.a" \
    "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" \
    "$prefix/lib/libswresample.a" "$prefix/lib/libavutil.a"

  local metadata="$prefix/include/ffmpeg-build/$name"
  mkdir -p "$metadata"
  cp "$build/config.h" "$build/config_components.h" "$metadata/"

  local archives_json extra_flags_json
  archives_json="$(jq -n \
    --arg combined "$(shasum -a 256 "$prefix/lib/libFFmpeg.a" | awk '{print $1}')" \
    --arg avcodec "$(shasum -a 256 "$prefix/lib/libavcodec.a" | awk '{print $1}')" \
    --arg avformat "$(shasum -a 256 "$prefix/lib/libavformat.a" | awk '{print $1}')" \
    --arg avutil "$(shasum -a 256 "$prefix/lib/libavutil.a" | awk '{print $1}')" \
    --arg swresample "$(shasum -a 256 "$prefix/lib/libswresample.a" | awk '{print $1}')" \
    '{"libFFmpeg.a":$combined,"libavcodec.a":$avcodec,"libavformat.a":$avformat,"libavutil.a":$avutil,"libswresample.a":$swresample}')"
  if [[ "$name" == "sim-x86_64" ]]; then
    extra_flags_json='["--disable-x86asm"]'
  else
    extra_flags_json='[]'
  fi
  jq -n \
    --arg commit "$commit" \
    --arg slice "$name" \
    --arg sdk "$sdk" \
    --arg arch "$arch" \
    --arg target "$triple" \
    --arg license "$license_mode" \
    --arg licenseSHA "$license_sha" \
    --argjson flags "$flags_json" \
    --argjson extraFlags "$extra_flags_json" \
    --argjson archives "$archives_json" \
    --argjson components "$(cat "$manifest")" \
    '{schemaVersion:1, commit:$commit, slice:$slice, sdk:$sdk, arch:$arch, target:$target,
      license:{mode:$license, sha256:$licenseSHA}, configureFlags:$flags,
      extraConfigureFlags:$extraFlags, archives:$archives, components:$components}' \
    > "$metadata/ffmpeg-build.json"
  popd >/dev/null
}

build_slice device appletvos arm64 "arm64-apple-tvos${sdk_version_floor}"
build_slice sim-arm64 appletvsimulator arm64 "arm64-apple-tvos${sdk_version_floor}-simulator"
build_slice sim-x86_64 appletvsimulator x86_64 "x86_64-apple-tvos${sdk_version_floor}-simulator"

sim="$work/install-simulator"
clear_generated_directory "$sim"
mkdir -p "$sim/lib" "$sim/include"
/usr/bin/lipo -create \
  "$work/install-sim-arm64/lib/libFFmpeg.a" \
  "$work/install-sim-x86_64/lib/libFFmpeg.a" \
  -output "$sim/lib/libFFmpeg.a"
cp -R "$work/install-sim-arm64/include/." "$sim/include/"
cp -R "$work/install-sim-x86_64/include/ffmpeg-build/sim-x86_64" "$sim/include/ffmpeg-build/"
diff -qr -x ffmpeg-build "$work/install-sim-arm64/include" "$work/install-sim-x86_64/include" >/dev/null || \
  fail "public simulator headers differ by architecture"

xcodebuild -create-xcframework \
  -library "$work/install-device/lib/libFFmpeg.a" -headers "$work/install-device/include" \
  -library "$sim/lib/libFFmpeg.a" -headers "$sim/include" \
  -output "$candidate"
"$root/Scripts/promote-ffmpeg-artifact.sh"
