#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# One-time public generation/readback only. Final CI calls --verify, never --generate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
destination=Tests/Fixtures/SourcePlanning
[[ $# == 1 ]] || { echo 'Usage: Scripts/generate-source-planning-fixtures.sh --generate|--verify' >&2; exit 64; }
if [[ "$1" == --verify ]]; then
  python3 Scripts/Support/source_fixture_manifest.py verify "$destination"
  exit
fi
[[ "$1" == --generate ]] || { echo 'Only --generate or --verify is supported.' >&2; exit 64; }
toolchain_record="$(./Scripts/verify-hls-fixture-toolchain.sh)"
./Scripts/generate-playback-fixtures.sh --verify
ffmpeg_command="${FFMPEG:?Verified host FFmpeg path required}"
# Generate into a new staging directory, so a failed Apple HE encoder cannot leave
# newly mislabeled or partially rewritten committed fixtures behind.
temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vplayer-public-source.XXXXXX")"
root="$temporary/SourcePlanning"
mkdir "$root"
echo "SOURCE_FIXTURE_STAGING=$root" >&2
common=(-hide_banner -loglevel error -nostdin -y)
input=Tests/VPlayerTests/Fixtures/Media
"$ffmpeg_command" "${common[@]}" -i "$input/interlaced-h264-mp2.ts" -i "$input/progressive-h264-aac.ts" -map 0:v:0 -map 1:a:0 -c copy -map_metadata -1 -t 2 -f mpegts "$root/interlaced-h264-aac.ts"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:v:0 -map 0:a:0 -c copy -bsf:a aac_adtstoasc -map_metadata -1 -t 2 -f hls -hls_segment_type fmp4 -hls_time 1 -hls_playlist_type vod -hls_fmp4_init_filename progressive-init.mp4 -hls_segment_filename "$root/progressive-%d.m4s" "$root/fmp4.m3u8"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:a:0 -c copy -map_metadata -1 -t 2 -f mpegts "$root/audio.ts"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:v:0 -an -vf scale=640:360 -c:v libx264 -threads 1 -preset veryfast -profile:v high -level:v 3.0 -g 25 -keyint_min 25 -sc_threshold 0 -map_metadata -1 -t 2 -f mpegts "$root/video-low.ts"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:v:0 -an -c copy -map_metadata -1 -t 2 -f mpegts "$root/video-high.ts"
"$ffmpeg_command" "${common[@]}" -f lavfi -i testsrc2=size=3840x2160:rate=25 -frames:v 3 -an -c:v libx264 -threads 1 -preset ultrafast -profile:v baseline -qp 1 -g 25 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -f mpegts "$root/large-au.ts"
"$ffmpeg_command" "${common[@]}" -i "$root/large-au.ts" -map 0:v -c copy -movflags +empty_moov+frag_keyframe+default_base_moof+skip_trailer "$root/large-au.mp4"
python3 Scripts/Support/pad_source_fixture_au.py "$root/large-au.mp4" "$root/large-au-limit.mp4" 1048576
python3 Scripts/Support/pad_source_fixture_au.py "$root/large-au.mp4" "$root/large-au-over-limit.mp4" 1048577
for transfer in sdr hlg; do
  if [[ "$transfer" == sdr ]]; then
    primaries=bt709;curve=bt709;matrix=bt709;pixel=yuv420p;vui='colorprim=1:transfer=1:colormatrix=1'
  else
    primaries=bt2020;curve=arib-std-b67;matrix=bt2020nc;pixel=yuv420p10le;vui='colorprim=9:transfer=18:colormatrix=9'
  fi
  "$ffmpeg_command" "${common[@]}" -f lavfi -i testsrc2=size=640x360:rate=25 -t 1 -an -c:v libx265 -preset ultrafast -threads 1 -pix_fmt "$pixel" -color_primaries "$primaries" -color_trc "$curve" -colorspace "$matrix" -x265-params "pools=none:frame-threads=1:repeat-headers=1:$vui" -tag:v hvc1 -movflags +empty_moov+frag_keyframe+default_base_moof+skip_trailer "$root/hevc-$transfer.mp4"
done
# Ordinary CENC output uses public synthetic keys. Its IV bytes are generated ONCE
# at preparation and frozen in committed hashes; final acceptance never rewrites it.
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:a:0 -c copy -bsf:a aac_adtstoasc -t 1 -encryption_scheme cenc-aes-ctr -encryption_key 000102030405060708090a0b0c0d0e0f -encryption_kid 101112131415161718191a1b1c1d1e1f "$root/encrypted-aac.mp4"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:v:0 -map 0:a:0 -c copy -bsf:a aac_adtstoasc -t 1 -encryption_scheme cenc-aes-ctr -encryption_key 000102030405060708090a0b0c0d0e0f -encryption_kid 101112131415161718191a1b1c1d1e1f "$root/encrypted-av.mp4"
"$ffmpeg_command" "${common[@]}" -i "$input/progressive-h264-aac.ts" -map 0:a:0 -c copy -frames:a 8 -f adts "$root/aac-lc.adts"
he_record="$(python3 Scripts/Support/generate_he_aac_fixture.py --output "$root/aac-implicit-sbr-signaling.adts")"
python3 - "$root" <<'PYPLAYLISTS'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.joinpath('master.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,URI="audio-alternate.m3u8"\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="subtitles.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"\nvideo-low.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720,CODECS="avc1.640029,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"\nvideo-high.m3u8\n')
for name,segment in [('video-low','video-low.ts'),('video-high','video-high.ts'),('audio','audio.ts'),('audio-alternate','audio.ts'),('subtitles','subtitles.vtt')]:
 p.joinpath(name+'.m3u8').write_text('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2.0,\n'+segment+'\n#EXT-X-ENDLIST\n')
p.joinpath('subtitles.vtt').write_text('WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:126000\n\n00:00.000 --> 00:01.500\nSynthetic VPlayer subtitle\n')
PYPLAYLISTS
python3 Scripts/Support/source_fixture_manifest.py finalize "$root" "$toolchain_record" "$he_record"
# Promote only the verified allowlist; refuse unexpected preexisting contents.
python3 - "$root" "$destination" <<'PYPROMOTE'
import importlib.util,pathlib,shutil,sys
source,destination=map(pathlib.Path,sys.argv[1:])
spec=importlib.util.spec_from_file_location('inventory','Scripts/Support/export-hls-generation.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
if destination.exists():
 assert destination.is_dir() and not destination.is_symlink()
 assert {path.name for path in destination.iterdir()} <= module.SOURCE_FILES
else: destination.mkdir(parents=True)
for name in sorted(module.SOURCE_FILES):
 target=destination/name
 assert not target.is_symlink()
 shutil.copyfile(source/name,target)
PYPROMOTE
python3 Scripts/Support/source_fixture_manifest.py verify "$destination"
