#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# Task22 真实前缀/EOF fixture；生成后必须以 ffprobe 和 SHA256SUMS 复核再入库。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$root/Tests/VPlayerTests/Fixtures/Media"
ffmpeg="${FFMPEG:-ffmpeg}"
make_progressive() { local name=$1 duration=$2; "$ffmpeg" -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=$duration" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=$duration" -map 0:v -map 1:a -t "$duration" \
  -c:v libx264 -pix_fmt yuv420p -g 25 -keyint_min 25 -bf 2 -sc_threshold 0 -c:a aac -ar 48000 -ac 2 -f mpegts "$output/$name"; }
make_interlaced() { "$ffmpeg" -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i 'testsrc2=size=1920x1080:rate=50:duration=16' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=16' \
  -map 0:v -map 1:a -t 16 -vf 'tinterlace=mode=interleave_top,setfield=tff,format=yuv420p' -c:v libx264 -pix_fmt yuv420p -r 25 -flags:v +ilme+ildct -c:a mp2 -ar 48000 -ac 2 -f mpegts "$output/task22-interlaced-h264-mp2-16s.ts"; }
mkdir -p "$output"
make_progressive task22-progressive-h264-aac-16s.ts 16
make_interlaced
make_progressive task22-progressive-h264-aac-15.4s-eof.ts 15.4
make_progressive task22-progressive-h264-aac-0.8s-short.ts 0.8
(cd "$output" && shasum -a 256 task22-*.ts) > "$output/TASK22-SHA256SUMS"
