#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
flags="$root/Vendor/FFmpeg/configure.flags"
upstream_license="$root/Vendor/FFmpeg/UPSTREAM-LICENSE.md"
ijg_changes="$root/Vendor/FFmpeg/IJG-CHANGES.md"
optional_system_symbols="$root/Vendor/FFmpeg/optional-system-symbol-allowlist.txt"

test "$(jq -r .tag "$lock")" = "n8.1.2"
test "$(jq -r .commit "$lock")" = "38b88335f99e76ed89ff3c93f877fdefce736c13"
test "$(jq -r .sourceURL "$lock")" = "https://git.ffmpeg.org/ffmpeg.git"
test "$(jq -r .licenseMode "$lock")" = "LGPL-2.1-or-later"
test -f "$upstream_license"
test -f "$ijg_changes"

grep -F 'FFmpeg-adapted derivatives of IJG originals, not verbatim copies' "$ijg_changes" >/dev/null
for source_name in jfdctfst.c jfdctint_template.c jrevdct.c; do
  grep -F "libavcodec/$source_name" "$ijg_changes" >/dev/null
done
grep -F 'ff_fdct_ifast' "$ijg_changes" >/dev/null
grep -F 'FUNC(ff_jpeg_fdct_islow)' "$ijg_changes" >/dev/null
grep -F 'ff_j_rev_dct4' "$ijg_changes" >/dev/null
grep -F 'ff_jref_idct_put' "$ijg_changes" >/dev/null

pinned_source="$root/Vendor/FFmpeg/Work/source/libavcodec"
grep -F '#include "libavutil/attributes.h"' "$pinned_source/jfdctfst.c" >/dev/null
grep -F 'ff_fdct_ifast (int16_t * data)' "$pinned_source/jfdctfst.c" >/dev/null
grep -F '#include "bit_depth_template.c"' "$pinned_source/jfdctint_template.c" >/dev/null
grep -F 'FUNC(ff_jpeg_fdct_islow)(int16_t *data)' "$pinned_source/jfdctint_template.c" >/dev/null
grep -F '#include "libavutil/intreadwrite.h"' "$pinned_source/jrevdct.c" >/dev/null
grep -F 'void ff_j_rev_dct4(DCTBLOCK data)' "$pinned_source/jrevdct.c" >/dev/null
grep -F 'void ff_jref_idct_put' "$pinned_source/jrevdct.c" >/dev/null

for slice in device sim-arm64 sim-x86_64; do
  archive="$root/Vendor/FFmpeg/Work/install-$slice/lib/libFFmpeg.a"
  for object_name in jfdctfst.o jfdctint.o jrevdct.o; do
    /usr/bin/ar -t "$archive" | grep -Fqx "$object_name"
  done
done

for documentation in "$root/THIRD_PARTY_NOTICES" "$root/Vendor/FFmpeg/README.md"; do
  grep -F 'this software is based in part on the work of the Independent JPEG Group' "$documentation" >/dev/null
  grep -F 'No further additions, deletions, or changes are made by VPlayer relative to the pinned FFmpeg source' "$documentation" >/dev/null
  grep -F 'Vendor/FFmpeg/IJG-CHANGES.md' "$documentation" >/dev/null
  grep -F 'Vendor/FFmpeg/UPSTREAM-LICENSE.md' "$documentation" >/dev/null
  grep -F 'permit customers to modify the application for their own use' "$documentation" >/dev/null
  grep -F 'permit reverse engineering for debugging those modifications' "$documentation" >/dev/null
  grep -F 'Source, object material, and relinking instructions alone are not sufficient' "$documentation" >/dev/null
  grep -F 'App Store release/legal gate' "$documentation" >/dev/null
done

diff -u - "$flags" <<'FLAGS'
--disable-autodetect
--disable-programs
--disable-doc
--disable-debug
--disable-avdevice
--disable-avfilter
--disable-swscale
--disable-network
--disable-everything
--disable-gpl
--disable-nonfree
--disable-version3
--disable-shared
--enable-static
--enable-pic
--enable-small
--enable-network
--enable-avcodec
--enable-avformat
--enable-avutil
--enable-swresample
--enable-securetransport
--enable-zlib
--enable-protocol=http,https,tcp,tls,crypto,data
--enable-demuxer=mpegts,hls,mov
--enable-parser=h264,hevc,aac,aac_latm,ac3,mpegaudio
--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb
--enable-decoder=aac,ac3,eac3,h264,mp2
FLAGS

if grep -Eq -- '--enable-(gpl|nonfree|version3)|--enable-protocol=[^#]*(udp|rtp)' "$flags"; then
  echo "forbidden FFmpeg feature enabled" >&2
  exit 1
fi

# Darwin archive tools otherwise stamp every member with the current time,
# making equivalent rebuilds byte-different.
grep -Fx 'export ZERO_AR_DATE=1' "$root/Scripts/build-ffmpeg.sh" >/dev/null

# Xcode Cloud's UTF-8 locale sorts libFFmpeg.a differently from the POSIX
# locale. The artifact audit must normalize collation before comparing names.
grep -Fx 'export LC_ALL=C' "$root/Scripts/audit-ffmpeg.sh" >/dev/null

grep -Ev '^[[:space:]]*(#|$)' "$optional_system_symbols" | LC_ALL=C sort -u | diff -u - <(printf '_wcslen\n')

artifact_cleanup_line="$(grep -nF 'clear_generated_directory "$artifacts"' "$root/Scripts/build-ffmpeg.sh" | head -1 | cut -d: -f1)"
first_slice_line="$(grep -nF 'build_slice device appletvos arm64' "$root/Scripts/build-ffmpeg.sh" | cut -d: -f1)"
test "$artifact_cleanup_line" -lt "$first_slice_line"

for audit_gate in \
  'require_define "$config" CONFIG_AUTODETECT 0' \
  'require_define "$config" CONFIG_SHARED 0' \
  'require_define "$config" CONFIG_STATIC 1' \
  'require_define "$config" CONFIG_SMALL 1' \
  '.sdk == $sdk'; do
  grep -F "$audit_gate" "$root/Scripts/audit-ffmpeg.sh" >/dev/null
done

echo "FFmpeg lock OK"
