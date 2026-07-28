#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

# Keep filename inventories deterministic across Xcode Cloud images. Locale-aware
# collation can place libFFmpeg.a after the lowercase FFmpeg archives and make an
# identical inventory look different from the audited list below.
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
physical_root="$(cd -P "$(dirname "$0")/.." && pwd)"
vendor="$root/Vendor/FFmpeg"
lock="$vendor/ffmpeg.lock.json"
manifest="$vendor/component-manifest.json"
required_system_symbols="$vendor/system-symbol-allowlist.txt"
optional_system_symbols="$vendor/optional-system-symbol-allowlist.txt"
work="$vendor/Work"
source="$work/source"
virtual_checkout='/VPlayer/FFmpeg/Checkout'
virtual_source='/VPlayer/FFmpeg/Source'
virtual_install_base='/VPlayer/FFmpeg/Install'

fail() {
  echo "FFmpeg audit failed: $*" >&2
  exit 1
}

audit_manifest() {
  local candidate="$1"
  jq -e --slurpfile expected "$root/Vendor/FFmpeg/component-manifest.json" \
    '($expected[0]) as $expected | to_entries | all(. as $entry | (($expected[.key] // []) - .value | length == 0) and (.value - ($expected[.key] // []) | length == 0))' \
    "$candidate" >/dev/null
  # The plan's entry comparison does not visit a missing key. Require the
  # complete object too so omissions and unknown categories are rejected.
  jq -e --slurpfile expected "$root/Vendor/FFmpeg/component-manifest.json" \
    '. == $expected[0]' "$candidate" >/dev/null
}
if [[ "${1:-}" == "--manifest-only" ]]; then
  audit_manifest "$2"
  exit
fi

[[ $# -eq 1 ]] || fail "usage: $0 <FFmpeg.xcframework>"
xcframework="$1"
[[ -d "$xcframework" ]] || fail "XCFramework not found: $xcframework"
[[ -f "$xcframework/Info.plist" ]] || fail "Info.plist is missing"
[[ -f "$required_system_symbols" ]] || fail "required system symbol allowlist is missing"
[[ -f "$optional_system_symbols" ]] || fail "optional system symbol allowlist is missing"

source_url="$(jq -er '.sourceURL' "$lock")"
tag="$(jq -er '.tag' "$lock")"
commit="$(jq -er '.commit' "$lock")"
license_mode="$(jq -er '.licenseMode' "$lock")"
[[ "$source_url" == "https://git.ffmpeg.org/ffmpeg.git" ]] || fail "unexpected source URL"
[[ "$tag" == "n8.1.2" ]] || fail "unexpected tag"
[[ "$commit" == "38b88335f99e76ed89ff3c93f877fdefce736c13" ]] || fail "unexpected commit"
[[ "$license_mode" == "LGPL-2.1-or-later" ]] || fail "unexpected license mode"
audit_manifest "$manifest"

[[ -d "$source/.git" ]] || fail "pinned source checkout is missing; run ./Scripts/build-ffmpeg.sh"
[[ "$(git -C "$source" remote get-url origin)" == "$source_url" ]] || fail "source checkout origin differs from lock"
[[ "$(git -C "$source" rev-parse HEAD)" == "$commit" ]] || fail "source checkout differs from lock"
[[ "$(git -C "$source" rev-parse "refs/tags/$tag^{}")" == "$commit" ]] || fail "tag does not peel to locked commit"
cmp -s "$source/COPYING.LGPLv2.1" "$vendor/LICENSE.md" || fail "LICENSE.md differs from upstream COPYING.LGPLv2.1"
cmp -s "$source/LICENSE.md" "$vendor/UPSTREAM-LICENSE.md" || fail "UPSTREAM-LICENSE.md differs from upstream LICENSE.md"
license_sha="$(shasum -a 256 "$vendor/LICENSE.md" | awk '{print $1}')"

tmp="$(mktemp -d)"
cleanup() {
  find "$tmp" -type f -delete
  find "$tmp" -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

/usr/bin/plutil -convert json -o "$tmp/info.json" "$xcframework/Info.plist"
jq -e '
  (.AvailableLibraries | length) == 2 and
  ([.AvailableLibraries[] | {
      platform: .SupportedPlatform,
      variant: (.SupportedPlatformVariant // ""),
      architectures: (.SupportedArchitectures | sort),
      library: .LibraryPath,
      headers: .HeadersPath
    }] | sort_by(.platform, .variant)) ==
  ([
    {platform:"tvos", variant:"", architectures:["arm64"], library:"libFFmpeg.a", headers:"Headers"},
    {platform:"tvos", variant:"simulator", architectures:["arm64","x86_64"], library:"libFFmpeg.a", headers:"Headers"}
  ] | sort_by(.platform, .variant))
' "$tmp/info.json" >/dev/null || fail "unexpected XCFramework platform or architecture inventory"

flags_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$vendor/configure.flags")"

require_define() {
  local file="$1" macro="$2" expected="$3" actual
  actual="$(awk -v macro="$macro" '$1 == "#define" && $2 == macro { print $3; exit }' "$file")"
  [[ "$actual" == "$expected" ]] || fail "$macro is ${actual:-missing}, expected $expected in $file"
}

assert_text_omits_checkout_roots() {
  local file="$1" description="$2" checkout_root
  for checkout_root in "$root" "$physical_root"; do
    [[ -n "$checkout_root" ]] || continue
    if grep -F "$checkout_root" "$file" >/dev/null; then
      fail "checkout root leaked into $description"
    fi
  done
}

assert_archive_omits_checkout_roots() {
  local archive="$1" description="$2" checkout_root
  for checkout_root in "$root" "$physical_root"; do
    [[ -n "$checkout_root" ]] || continue
    if strings -a "$archive" | grep -F "$checkout_root" >/dev/null; then
      fail "checkout root leaked into $description"
    fi
  done
}

audit_component_category() {
  local config="$1" suffix="$2" key="$3" actual expected
  actual="$(awk -v suffix="$suffix" '
    $1 == "#define" && $3 == "1" && index($2, "CONFIG_") == 1 &&
      substr($2, length($2) - length(suffix) + 1) == suffix {
        name = substr($2, 8, length($2) - 7 - length(suffix));
        print tolower(name)
      }
  ' "$config" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')"
  expected="$(jq -c --arg key "$key" '.[$key] | sort' "$manifest")"
  [[ "$actual" == "$expected" ]] || {
    echo "Actual $key:   $actual" >&2
    echo "Expected $key: $expected" >&2
    fail "enabled $key differ from component manifest"
  }
}

audit_empty_component_category() {
  local config="$1" suffix="$2" description="$3" actual
  actual="$(awk -v suffix="$suffix" '
    $1 == "#define" && $3 == "1" && index($2, "CONFIG_") == 1 &&
      substr($2, length($2) - length(suffix) + 1) == suffix { print $2 }
  ' "$config")"
  [[ -z "$actual" ]] || {
    echo "$actual" >&2
    fail "unexpected enabled $description"
  }
}

audit_build_record() {
  local record="$1" xc_archive="$2" platform="$3" variant="$4"
  local metadata_dir config components slice sdk arch target expected_target expected_sdk expected_platform expected_platform_id expected_variant prefix
  local load_inventory expected_load_inventory
  metadata_dir="$(dirname "$record")"
  config="$metadata_dir/config.h"
  components="$metadata_dir/config_components.h"
  [[ -f "$config" && -f "$components" ]] || fail "build configuration headers missing beside $record"
  assert_text_omits_checkout_roots "$config" "$(basename "$(dirname "$record")") config.h"
  assert_text_omits_checkout_roots "$components" "$(basename "$(dirname "$record")") config_components.h"
  assert_text_omits_checkout_roots "$record" "$(basename "$(dirname "$record")") build record"

  jq -e --arg commit "$commit" --arg license "$license_mode" --arg sha "$license_sha" \
    --arg checkout "$virtual_checkout" --arg source "$virtual_source" \
    --arg installBase "$virtual_install_base" \
    --argjson flags "$flags_json" --slurpfile manifest "$manifest" '
      .schemaVersion == 2 and
      .commit == $commit and
      .license.mode == $license and
      .license.sha256 == $sha and
      .configureFlags == $flags and
      .components == $manifest[0] and
      .pathNormalization == {
        checkoutRoot:$checkout, sourceRoot:$source,
        installPrefix:($installBase + "/" + .slice),
        compilerPrefixMaps:["file","macro","debug"]
      } and
      (keys | sort) == (["arch","archives","commit","components","configureFlags","extraConfigureFlags","license","pathNormalization","schemaVersion","sdk","slice","target"] | sort) and
      (.license | keys | sort) == (["mode","sha256"] | sort) and
      (.archives | keys | sort) == (["libFFmpeg.a","libavcodec.a","libavformat.a","libavutil.a","libswresample.a"] | sort)
    ' "$record" >/dev/null || fail "invalid build record: $record"

  slice="$(jq -er '.slice' "$record")"
  sdk="$(jq -er '.sdk' "$record")"
  arch="$(jq -er '.arch' "$record")"
  target="$(jq -er '.target' "$record")"
  case "$slice" in
    device)
      expected_target="arm64-apple-tvos18.0"
      expected_sdk="appletvos"
      expected_platform_id="3"
      expected_platform="tvos"
      expected_variant=""
      prefix="$work/install-device"
      [[ "$arch" == "arm64" ]] || fail "device record has wrong architecture"
      jq -e '.extraConfigureFlags == []' "$record" >/dev/null || fail "unexpected device-only configure flags"
      require_define "$config" ARCH_AARCH64 1
      ;;
    sim-arm64)
      expected_target="arm64-apple-tvos18.0-simulator"
      expected_sdk="appletvsimulator"
      expected_platform_id="8"
      expected_platform="tvos"
      expected_variant="simulator"
      prefix="$work/install-sim-arm64"
      [[ "$arch" == "arm64" ]] || fail "sim-arm64 record has wrong architecture"
      jq -e '.extraConfigureFlags == []' "$record" >/dev/null || fail "unexpected arm64 simulator configure flags"
      require_define "$config" ARCH_AARCH64 1
      ;;
    sim-x86_64)
      expected_target="x86_64-apple-tvos18.0-simulator"
      expected_sdk="appletvsimulator"
      expected_platform_id="8"
      expected_platform="tvos"
      expected_variant="simulator"
      prefix="$work/install-sim-x86_64"
      [[ "$arch" == "x86_64" ]] || fail "sim-x86_64 record has wrong architecture"
      jq -e '.extraConfigureFlags == ["--disable-x86asm"]' "$record" >/dev/null || fail "x86_64 NASM fallback is not pinned"
      require_define "$config" ARCH_X86_64 1
      ;;
    *) fail "unknown build slice in $record" ;;
  esac
  jq -e --arg sdk "$expected_sdk" '.sdk == $sdk' "$record" >/dev/null || fail "$slice SDK differs from build contract"
  [[ "$target" == "$expected_target" ]] || fail "$slice target triple differs from lock"
  [[ "$platform" == "$expected_platform" && "$variant" == "$expected_variant" ]] || fail "$slice is in the wrong XCFramework library"

  require_define "$config" CONFIG_GPL 0
  require_define "$config" CONFIG_NONFREE 0
  require_define "$config" CONFIG_VERSION3 0
  require_define "$config" CONFIG_AVCODEC 1
  require_define "$config" CONFIG_AVFORMAT 1
  require_define "$config" CONFIG_AVUTIL 1
  require_define "$config" CONFIG_SWRESAMPLE 1
  require_define "$config" CONFIG_AVDEVICE 0
  require_define "$config" CONFIG_AVFILTER 0
  require_define "$config" CONFIG_SWSCALE 0
  require_define "$config" CONFIG_NETWORK 1
  require_define "$config" CONFIG_SECURETRANSPORT 1
  require_define "$config" CONFIG_ZLIB 1
  require_define "$config" CONFIG_AUTODETECT 0
  require_define "$config" CONFIG_SHARED 0
  require_define "$config" CONFIG_STATIC 1
  require_define "$config" CONFIG_SMALL 1
  grep -Fqx '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$config" || fail "$slice reports a non-LGPL configure license"
  grep -Fq -- "--extra-cflags='-target $target -fapplication-extension" "$config" || fail "$slice config does not contain the audited target triple"
  grep -Fq -- "-ffile-prefix-map=$virtual_checkout=$virtual_source" "$config" || fail "$slice config lacks stable file prefix mapping"
  grep -Fq -- "-fmacro-prefix-map=$virtual_checkout=$virtual_source" "$config" || fail "$slice config lacks stable macro prefix mapping"
  grep -Fq -- "-fdebug-prefix-map=$virtual_checkout=$virtual_source" "$config" || fail "$slice config lacks stable debug prefix mapping"
  grep -Fq -- "--prefix=$virtual_install_base/$slice" "$config" || fail "$slice config lacks its stable virtual prefix"
  grep -Fqx "#define FFMPEG_DATADIR \"$virtual_install_base/$slice/share/ffmpeg\"" "$config" || fail "$slice FFMPEG_DATADIR is not normalized"
  grep -Fqx "#define AVCONV_DATADIR \"$virtual_install_base/$slice/share/ffmpeg\"" "$config" || fail "$slice AVCONV_DATADIR is not normalized"
  load_inventory="$(/usr/bin/otool -l "$prefix/lib/libFFmpeg.a" | awk '/^[[:space:]]*platform / || /^[[:space:]]*minos / {print $1, $2}' | LC_ALL=C sort -u)"
  expected_load_inventory="$(printf 'minos 18.0\nplatform %s' "$expected_platform_id")"
  [[ "$load_inventory" == "$expected_load_inventory" ]] || fail "$slice Mach-O platform or minimum OS differs from tvOS 18.0"
  if grep -q '^#define CONFIG_POSTPROC ' "$config"; then
    require_define "$config" CONFIG_POSTPROC 0
  fi

  audit_component_category "$components" _PROTOCOL protocols
  audit_component_category "$components" _DEMUXER demuxers
  audit_component_category "$components" _PARSER parsers
  audit_component_category "$components" _BSF bitstreamFilters
  audit_component_category "$components" _DECODER decoders
  audit_empty_component_category "$components" _ENCODER encoders
  audit_empty_component_category "$components" _MUXER muxers
  audit_empty_component_category "$components" _FILTER filters
  audit_empty_component_category "$components" _HWACCEL hardware-accelerators
  audit_empty_component_category "$components" _INDEV input-devices
  audit_empty_component_category "$components" _OUTDEV output-devices

  find "$prefix/lib" -maxdepth 1 -type f -name '*.a' -exec basename {} \; | sort > "$tmp/$slice-archives.txt"
  if ! diff -u - "$tmp/$slice-archives.txt" <<'ARCHIVES'
libFFmpeg.a
libavcodec.a
libavformat.a
libavutil.a
libswresample.a
ARCHIVES
  then
    fail "$slice installed unexpected static libraries"
  fi

  local archive_name expected_sha actual_sha extracted
  for archive_name in libFFmpeg.a libavcodec.a libavformat.a libavutil.a libswresample.a; do
    expected_sha="$(jq -er --arg name "$archive_name" '.archives[$name]' "$record")"
    actual_sha="$(shasum -a 256 "$prefix/lib/$archive_name" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] || fail "$slice $archive_name differs from recorded build output"
    assert_archive_omits_checkout_roots "$prefix/lib/$archive_name" "$slice installed $archive_name"
  done
  [[ "$(jq '.archives | length' "$record")" == "5" ]] || fail "$slice archive inventory contains extra entries"

  if [[ "$variant" == "simulator" ]]; then
    extracted="$tmp/$slice-libFFmpeg.a"
    /usr/bin/lipo "$xc_archive" -thin "$arch" -output "$extracted"
    actual_sha="$(shasum -a 256 "$extracted" | awk '{print $1}')"
    printf '%s\n' "$extracted" >> "$tmp/symbol-archives.txt"
  else
    actual_sha="$(shasum -a 256 "$xc_archive" | awk '{print $1}')"
    printf '%s\n' "$xc_archive" >> "$tmp/symbol-archives.txt"
  fi
  expected_sha="$(jq -er '.archives["libFFmpeg.a"]' "$record")"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "$slice XCFramework archive differs from recorded thin archive"
  assert_archive_omits_checkout_roots "${extracted:-$xc_archive}" "$slice final thin libFFmpeg.a"

  printf '%s\n' "$slice" >> "$tmp/seen-slices.txt"
}

: > "$tmp/seen-slices.txt"
: > "$tmp/xc-archives.txt"
: > "$tmp/symbol-archives.txt"
while IFS=$'\t' read -r identifier platform variant; do
  [[ "$identifier" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe XCFramework library identifier"
  library_dir="$xcframework/$identifier"
  archive="$library_dir/libFFmpeg.a"
  headers="$library_dir/Headers"
  [[ -f "$archive" && -d "$headers/ffmpeg-build" ]] || fail "library or build headers missing for $identifier"
  printf '%s\n' "$archive" >> "$tmp/xc-archives.txt"

  if [[ "$variant" == "simulator" ]]; then
    [[ "$(/usr/bin/lipo -archs "$archive" | tr ' ' '\n' | sort | paste -sd, -)" == "arm64,x86_64" ]] || fail "simulator archive is not arm64/x86_64"
  else
    [[ "$(/usr/bin/lipo -archs "$archive")" == "arm64" ]] || fail "device archive is not arm64"
  fi

  find "$headers/ffmpeg-build" -name ffmpeg-build.json -type f | sort > "$tmp/$identifier-records.txt"
  [[ -s "$tmp/$identifier-records.txt" ]] || fail "no build records for $identifier"
  while IFS= read -r record; do
    audit_build_record "$record" "$archive" "$platform" "$variant"
  done < "$tmp/$identifier-records.txt"
done < <(jq -r '.AvailableLibraries[] | [.LibraryIdentifier, .SupportedPlatform, (.SupportedPlatformVariant // "")] | @tsv' "$tmp/info.json")

sort "$tmp/seen-slices.txt" > "$tmp/seen-slices-sorted.txt"
diff -u - "$tmp/seen-slices-sorted.txt" <<'SLICES' >/dev/null || fail "expected exactly three architecture build records"
device
sim-arm64
sim-x86_64
SLICES

: > "$tmp/all-unresolved.txt"
archive_index=0
while IFS= read -r archive; do
  archive_index=$((archive_index + 1))
  /usr/bin/nm -g -U -j "$archive" 2>/dev/null | awk '/^_/' | LC_ALL=C sort -u > "$tmp/defined-$archive_index.txt"
  /usr/bin/nm -g -u -j "$archive" 2>/dev/null | awk '/^_/' | LC_ALL=C sort -u > "$tmp/undefined-$archive_index.txt"
  LC_ALL=C comm -23 "$tmp/undefined-$archive_index.txt" "$tmp/defined-$archive_index.txt" >> "$tmp/all-unresolved.txt"
done < "$tmp/symbol-archives.txt"
LC_ALL=C sort -u "$tmp/all-unresolved.txt" > "$tmp/unresolved.txt"
grep -Ev '^[[:space:]]*(#|$)' "$required_system_symbols" | LC_ALL=C sort -u > "$tmp/required.txt" || true
grep -Ev '^[[:space:]]*(#|$)' "$optional_system_symbols" | LC_ALL=C sort -u > "$tmp/optional.txt" || true
LC_ALL=C comm -12 "$tmp/required.txt" "$tmp/optional.txt" > "$tmp/overlap.txt"
if [[ -s "$tmp/overlap.txt" ]]; then
  echo "Symbols listed as both required and optional:" >&2
  cat "$tmp/overlap.txt" >&2
  fail "system symbol allowlists overlap"
fi
LC_ALL=C sort -u "$tmp/required.txt" "$tmp/optional.txt" > "$tmp/allowed.txt"

LC_ALL=C comm -23 "$tmp/unresolved.txt" "$tmp/allowed.txt" > "$tmp/unexpected.txt"
LC_ALL=C comm -13 "$tmp/unresolved.txt" "$tmp/required.txt" > "$tmp/stale.txt"
if [[ -s "$tmp/unexpected.txt" || -s "$tmp/stale.txt" ]]; then
  if [[ -s "$tmp/unexpected.txt" ]]; then
    echo "Unexpected unresolved symbols:" >&2
    cat "$tmp/unexpected.txt" >&2
  fi
  if [[ -s "$tmp/stale.txt" ]]; then
    echo "Stale symbol allowlist entries:" >&2
    cat "$tmp/stale.txt" >&2
  fi
  fail "external symbol allowlist differs from actual archives"
fi

echo "FFmpeg audit OK: $commit"
