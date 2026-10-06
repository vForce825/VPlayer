#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Synthetic lavfi source; no captured broadcaster content or network URLs.
# Provenance: Debian FFmpeg 7.1.5-0+deb13u1, libx264, single encoder thread.
set -euo pipefail
repo=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
out="$repo/Tests/Fixtures/Video/homepod-live-h264-aac-80s.ts"
ffmpeg -hide_banner -v warning -y \
  -f lavfi -i 'color=c=black:size=320x180:rate=30' \
  -f lavfi -i 'anullsrc=sample_rate=44100:channel_layout=stereo' \
  -t 80 -c:v libx264 -preset veryfast -crf 30 -profile:v high -level:v 4.0 \
  -pix_fmt yuv420p -g 150 -keyint_min 150 -bf 0 -sc_threshold 0 -threads 1 \
  -x264-params 'keyint=150:min-keyint=150:scenecut=0:bframes=0:force-cfr=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off' \
  -c:a aac -b:a 96k -ar 44100 -ac 2 -f mpegts "$out"
