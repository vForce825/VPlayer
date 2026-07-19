#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
vendor="$root/Vendor/FFmpeg"
artifact="$vendor/Artifacts/FFmpeg.xcframework"
source="$vendor/Work/source"

missing_artifact() {
  echo "FFmpeg artifact or audited build inputs are missing. Run ./Scripts/build-ffmpeg.sh" >&2
  exit 1
}

[[ -d "$artifact" && -f "$artifact/Info.plist" && -d "$source/.git" ]] || missing_artifact
for install in install-device install-sim-arm64 install-sim-x86_64; do
  [[ -d "$vendor/Work/$install" ]] || missing_artifact
done

tmp="$(mktemp -d)"
cleanup() {
  find "$tmp" -type f -delete
  find "$tmp" -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

base="$tmp/base"
mkdir -p "$base/Scripts" "$base/Vendor/FFmpeg/Artifacts" "$base/Vendor/FFmpeg/Work"
cp "$root/Scripts/audit-ffmpeg.sh" "$base/Scripts/"
for metadata in \
  LICENSE.md \
  UPSTREAM-LICENSE.md \
  component-manifest.json \
  configure.flags \
  ffmpeg.lock.json \
  system-symbol-allowlist.txt; do
  cp "$vendor/$metadata" "$base/Vendor/FFmpeg/"
done
cp -R "$artifact" "$base/Vendor/FFmpeg/Artifacts/"
ln -s "$source" "$base/Vendor/FFmpeg/Work/source"
for install in install-device install-sim-arm64 install-sim-x86_64; do
  ln -s "$vendor/Work/$install" "$base/Vendor/FFmpeg/Work/$install"
done

/usr/bin/plutil -convert json -o "$tmp/base-info.json" "$artifact/Info.plist"
device_index="$(jq -er '.AvailableLibraries | to_entries[] | select((.value.SupportedPlatformVariant // "") == "") | .key' "$tmp/base-info.json")"
device_identifier="$(jq -er '.AvailableLibraries[] | select((.SupportedPlatformVariant // "") == "") | .LibraryIdentifier' "$tmp/base-info.json")"

new_case() {
  local name="$1"
  local case_root="$tmp/$name"
  mkdir -p "$case_root"
  cp -R "$base/." "$case_root"
  printf '%s\n' "$case_root"
}

device_record() {
  printf '%s/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/%s/Headers/ffmpeg-build/device/ffmpeg-build.json\n' "$1" "$device_identifier"
}

device_config() {
  printf '%s/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/%s/Headers/ffmpeg-build/device/config.h\n' "$1" "$device_identifier"
}

device_components() {
  printf '%s/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/%s/Headers/ffmpeg-build/device/config_components.h\n' "$1" "$device_identifier"
}

materialize_device_install() {
  local case_root="$1" destination="$1/Vendor/FFmpeg/Work/install-device"
  find "$destination" -maxdepth 0 -type l -delete
  cp -R "$vendor/Work/install-device" "$destination"
}

replace_define() {
  local file="$1" macro="$2" value="$3"
  awk -v macro="$macro" -v value="$value" '
    $1 == "#define" && $2 == macro { $3 = value }
    { print }
  ' "$file" > "$file.new"
  mv "$file.new" "$file"
}

replace_json() {
  local file="$1" filter="$2"
  jq "$filter" "$file" > "$file.new"
  mv "$file.new" "$file"
}

assert_rejected() {
  local case_root="$1" expected="$2" description="$3"
  local output="$case_root/audit-output.txt"
  if "$case_root/Scripts/audit-ffmpeg.sh" \
    "$case_root/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework" > "$output" 2>&1; then
    echo "artifact audit accepted $description" >&2
    exit 1
  fi
  if ! grep -F "$expected" "$output" >/dev/null; then
    echo "artifact audit rejected $description at the wrong gate; expected: $expected" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
  fi
  echo "Artifact audit rejected $description"
}

"$base/Scripts/audit-ffmpeg.sh" "$base/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework" >/dev/null

case_root="$(new_case info-platform)"
/usr/bin/plutil -replace "AvailableLibraries.$device_index.SupportedPlatform" -string ios \
  "$case_root/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/Info.plist"
assert_rejected "$case_root" "unexpected XCFramework platform or architecture inventory" "a tampered Info.plist platform"

case_root="$(new_case info-architecture)"
/usr/bin/plutil -replace "AvailableLibraries.$device_index.SupportedArchitectures" -json '["x86_64"]' \
  "$case_root/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/Info.plist"
assert_rejected "$case_root" "unexpected XCFramework platform or architecture inventory" "a tampered Info.plist architecture"

case_root="$(new_case gpl-config)"
replace_define "$(device_config "$case_root")" CONFIG_GPL 1
assert_rejected "$case_root" "CONFIG_GPL is 1, expected 0" "CONFIG_GPL=1"

case_root="$(new_case component-config)"
printf '#define CONFIG_UDP_PROTOCOL 1\n' >> "$(device_components "$case_root")"
assert_rejected "$case_root" "enabled protocols differ from component manifest" "an unexpected config_components protocol"

case_root="$(new_case host-path-config)"
replace_define "$(device_config "$case_root")" FFMPEG_DATADIR "\"$case_root/private-host-path\""
assert_rejected "$case_root" "checkout root leaked into device config.h" "a reintroduced host checkout path"

case_root="$(new_case record-schema)"
replace_json "$(device_record "$case_root")" '.schemaVersion = 3'
assert_rejected "$case_root" "invalid build record" "a tampered record schema"

case_root="$(new_case record-commit)"
replace_json "$(device_record "$case_root")" '.commit = "0000000000000000000000000000000000000000"'
assert_rejected "$case_root" "invalid build record" "a tampered record commit"

case_root="$(new_case archive-hash)"
materialize_device_install "$case_root"
printf 'tamper' >> "$case_root/Vendor/FFmpeg/Work/install-device/lib/libavcodec.a"
assert_rejected "$case_root" "device libavcodec.a differs from recorded build output" "a tampered input archive hash"

case_root="$(new_case lgpl-license)"
printf '\nTampered.\n' >> "$case_root/Vendor/FFmpeg/LICENSE.md"
assert_rejected "$case_root" "LICENSE.md differs from upstream COPYING.LGPLv2.1" "a tampered LGPL license"

case_root="$(new_case upstream-license-map)"
printf '\nTampered.\n' >> "$case_root/Vendor/FFmpeg/UPSTREAM-LICENSE.md"
assert_rejected "$case_root" "UPSTREAM-LICENSE.md differs from upstream LICENSE.md" "a tampered upstream license map"

cc="$(/usr/bin/xcrun --sdk appletvos --find clang)"

case_root="$(new_case minimum-os)"
materialize_device_install "$case_root"
printf 'void vplayer_audit_tvos17_object(void) {}\n' | \
  "$cc" -target arm64-apple-tvos17.0 -fapplication-extension -x c -c -o "$case_root/tvos17.o" -
/usr/bin/xcrun --sdk appletvos ar -r \
  "$case_root/Vendor/FFmpeg/Work/install-device/lib/libFFmpeg.a" "$case_root/tvos17.o"
/usr/bin/xcrun --sdk appletvos ranlib "$case_root/Vendor/FFmpeg/Work/install-device/lib/libFFmpeg.a"
assert_rejected "$case_root" "Mach-O platform or minimum OS differs from tvOS 18.0" "a real tvOS 17 Mach-O member"

case_root="$(new_case unexpected-symbol)"
materialize_device_install "$case_root"
printf 'extern void vplayer_audit_unexpected_symbol(void); void vplayer_audit_symbol_probe(void) { vplayer_audit_unexpected_symbol(); }\n' | \
  "$cc" -target arm64-apple-tvos18.0 -fapplication-extension -x c -c -o "$case_root/unexpected.o" -
device_install_archive="$case_root/Vendor/FFmpeg/Work/install-device/lib/libFFmpeg.a"
/usr/bin/xcrun --sdk appletvos ar -r "$device_install_archive" "$case_root/unexpected.o"
/usr/bin/xcrun --sdk appletvos ranlib "$device_install_archive"
cp "$device_install_archive" \
  "$case_root/Vendor/FFmpeg/Artifacts/FFmpeg.xcframework/$device_identifier/libFFmpeg.a"
combined_sha="$(shasum -a 256 "$device_install_archive" | awk '{print $1}')"
record="$(device_record "$case_root")"
jq --arg sha "$combined_sha" '.archives["libFFmpeg.a"] = $sha' "$record" > "$record.new"
mv "$record.new" "$record"
assert_rejected "$case_root" "_vplayer_audit_unexpected_symbol" "an unexpected unresolved symbol"

case_root="$(new_case stale-symbol)"
printf '_vplayer_audit_stale_symbol\n' >> "$case_root/Vendor/FFmpeg/system-symbol-allowlist.txt"
assert_rejected "$case_root" "_vplayer_audit_stale_symbol" "a stale unresolved-symbol allowlist entry"

echo "FFmpeg artifact audit tamper test OK"
