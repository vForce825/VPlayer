#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
flags="$root/Vendor/FFmpeg/configure.flags"

test "$(jq -r .tag "$lock")" = "n8.1.2"
test "$(jq -r .commit "$lock")" = "38b88335f99e76ed89ff3c93f877fdefce736c13"
test "$(jq -r .sourceURL "$lock")" = "https://git.ffmpeg.org/ffmpeg.git"
test "$(jq -r .licenseMode "$lock")" = "LGPL-2.1-or-later"

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
--enable-decoder=aac,ac3,eac3,mp2
FLAGS

if grep -Eq -- '--enable-(gpl|nonfree|version3)|--enable-protocol=[^#]*(udp|rtp)' "$flags"; then
  echo "forbidden FFmpeg feature enabled" >&2
  exit 1
fi

# Darwin archive tools otherwise stamp every member with the current time,
# making equivalent rebuilds byte-different.
grep -Fx 'export ZERO_AR_DATE=1' "$root/Scripts/build-ffmpeg.sh" >/dev/null

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
