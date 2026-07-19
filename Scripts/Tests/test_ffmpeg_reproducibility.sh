#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
physical_root="$(cd -P "$(dirname "$0")/../.." && pwd)"
vendor="$root/Vendor/FFmpeg"
artifact="$vendor/Artifacts/FFmpeg.xcframework"
virtual_checkout='/VPlayer/FFmpeg/Checkout'
virtual_source='/VPlayer/FFmpeg/Source'
virtual_install_base='/VPlayer/FFmpeg/Install'
tmp="$(mktemp -d)"

cleanup() {
  find "$tmp" -type f -delete
  find "$tmp" -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

grep -F 'FFMPEG_CONFIGURATION, FFMPEG_DATADIR, and AVCONV_DATADIR' \
  "$vendor/README.md" >/dev/null
grep -F 'stable virtual roots' "$vendor/README.md" >/dev/null
grep -F 'audit-before-and-after tree fingerprint' "$vendor/README.md" >/dev/null

checkout_roots() {
  printf '%s\n' "$root"
  if [[ "$physical_root" != "$root" ]]; then
    printf '%s\n' "$physical_root"
  fi
}

assert_archive_omits_root() {
  local archive="$1" description="$2"
  local checkout_root
  while IFS= read -r checkout_root; do
    if strings -a "$archive" | grep -F "$checkout_root" >/dev/null; then
      echo "$description contains the checkout root: $checkout_root" >&2
      exit 1
    fi
  done < <(checkout_roots)
}

assert_text_omits_root() {
  local file="$1" description="$2"
  local checkout_root
  while IFS= read -r checkout_root; do
    if grep -F "$checkout_root" "$file" >/dev/null; then
      echo "$description contains the checkout root: $checkout_root" >&2
      exit 1
    fi
  done < <(checkout_roots)
}

assert_normalized_config() {
  local config="$1" slice="$2" target="$3"
  grep -F -- "-ffile-prefix-map=$virtual_checkout=$virtual_source" "$config" >/dev/null
  grep -F -- "-fmacro-prefix-map=$virtual_checkout=$virtual_source" "$config" >/dev/null
  grep -F -- "-fdebug-prefix-map=$virtual_checkout=$virtual_source" "$config" >/dev/null
  grep -F -- "--prefix=$virtual_install_base/$slice" "$config" >/dev/null
  grep -Fqx "#define FFMPEG_DATADIR \"$virtual_install_base/$slice/share/ffmpeg\"" "$config"
  grep -Fqx "#define AVCONV_DATADIR \"$virtual_install_base/$slice/share/ffmpeg\"" "$config"
  grep -F -- "-target $target -fapplication-extension" "$config" >/dev/null
  grep -Fqx '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$config"
}

for slice in device sim-arm64 sim-x86_64; do
  assert_archive_omits_root "$vendor/Work/install-$slice/lib/libFFmpeg.a" \
    "$slice thin libFFmpeg.a"
  assert_text_omits_root "$vendor/Work/build-$slice/config.h" \
    "$slice generated config.h"
  assert_text_omits_root "$vendor/Work/install-$slice/include/ffmpeg-build/$slice/config.h" \
    "$slice installed config.h"
  assert_text_omits_root "$vendor/Work/install-$slice/include/ffmpeg-build/$slice/config_components.h" \
    "$slice installed config_components.h"
  record="$vendor/Work/install-$slice/include/ffmpeg-build/$slice/ffmpeg-build.json"
  assert_text_omits_root "$record" "$slice build record"
  jq -e \
    --arg checkout "$virtual_checkout" \
    --arg source "$virtual_source" \
    --arg install "$virtual_install_base/$slice" \
    '.schemaVersion == 2 and .pathNormalization == {
      checkoutRoot:$checkout, sourceRoot:$source, installPrefix:$install,
      compilerPrefixMaps:["file","macro","debug"]
    }' "$record" >/dev/null

  case "$slice" in
    device) target='arm64-apple-tvos18.0' ;;
    sim-arm64) target='arm64-apple-tvos18.0-simulator' ;;
    sim-x86_64) target='x86_64-apple-tvos18.0-simulator' ;;
  esac
  assert_normalized_config "$vendor/Work/build-$slice/config.h" "$slice" "$target"
done

[[ -f "$artifact/Info.plist" ]] || {
  echo "FFmpeg artifact is missing. Run ./Scripts/build-ffmpeg.sh" >&2
  exit 1
}
/usr/bin/plutil -convert json -o "$tmp/info.json" "$artifact/Info.plist"
device_identifier="$(jq -er '.AvailableLibraries[] | select((.SupportedPlatformVariant // "") == "") | .LibraryIdentifier' "$tmp/info.json")"
sim_identifier="$(jq -er '.AvailableLibraries[] | select(.SupportedPlatformVariant == "simulator") | .LibraryIdentifier' "$tmp/info.json")"
device_archive="$artifact/$device_identifier/libFFmpeg.a"
sim_archive="$artifact/$sim_identifier/libFFmpeg.a"
assert_archive_omits_root "$device_archive" "final device thin libFFmpeg.a"
for arch in arm64 x86_64; do
  thin="$tmp/final-simulator-$arch.a"
  /usr/bin/lipo "$sim_archive" -thin "$arch" -output "$thin"
  assert_archive_omits_root "$thin" "final simulator $arch thin libFFmpeg.a"
done

while IFS= read -r header; do
  assert_text_omits_root "$header" "final FFmpeg metadata header"
done < <(find "$artifact" -path '*/Headers/ffmpeg-build/*/config*.h' -type f | LC_ALL=C sort)

echo "FFmpeg checkout-root privacy gate OK"
