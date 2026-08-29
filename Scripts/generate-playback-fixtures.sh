#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Fixture provenance: Homebrew ffmpeg 8.1.2_1, reporting exactly "ffmpeg version 8.1.2".

set -euo pipefail

self_test_fail() {
  printf 'fixture generator self-test failed: %s\n' "$1" >&2
  exit 1
}

expect_verify_failure() {
  local root=$1 description=$2
  if VPLAYER_FIXTURE_GENERATOR_SELF_TEST=1 "$script" --verify-root "$root" >/dev/null 2>&1; then
    self_test_fail "$description was accepted"
  fi
}

write_test_manifest() {
  local root=$1 path
  : > "$root/SHA256SUMS"
  for path in ac3-48k-5point1.mov hls/master.m3u8 hls/segment0.ts interlaced-h264-mp2.ts progressive-h264-aac.ts; do
    (cd "$root" && shasum -a 256 "$path") >> "$root/SHA256SUMS"
  done
}

run_self_tests() {
  local temporary fixture_root case_root
  script="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-fixture-generator-test.XXXXXX")"
  trap 'rm -rf "$temporary"' RETURN
  fixture_root="$temporary/fixtures"
  mkdir -p "$fixture_root/hls"
  printf '#EXTM3U\nsegment0.ts\n#EXT-X-ENDLIST\n' > "$fixture_root/hls/master.m3u8"
  printf segment > "$fixture_root/hls/segment0.ts"
  printf interlaced > "$fixture_root/interlaced-h264-mp2.ts"
  printf progressive > "$fixture_root/progressive-h264-aac.ts"
  printf ac3 > "$fixture_root/ac3-48k-5point1.mov"
  write_test_manifest "$fixture_root"
  VPLAYER_FIXTURE_GENERATOR_SELF_TEST=1 "$script" --verify-root "$fixture_root"

  case_root="$temporary/missing"
  cp -R "$fixture_root" "$case_root"
  rm "$case_root/progressive-h264-aac.ts"
  expect_verify_failure "$case_root" 'missing fixture'

  case_root="$temporary/extra"
  cp -R "$fixture_root" "$case_root"
  printf extra > "$case_root/extra.ts"
  expect_verify_failure "$case_root" 'extra fixture'

  case_root="$temporary/mismatch"
  cp -R "$fixture_root" "$case_root"
  printf tamper >> "$case_root/interlaced-h264-mp2.ts"
  expect_verify_failure "$case_root" 'checksum mismatch'

  case_root="$temporary/unsafe"
  cp -R "$fixture_root" "$case_root"
  printf '%064d  ../escape.ts\n' 0 > "$case_root/SHA256SUMS"
  expect_verify_failure "$case_root" 'unsafe checksum path'

  case_root="$temporary/remote-hls"
  cp -R "$fixture_root" "$case_root"
  printf '#EXTM3U\nhttps://example.com/segment.ts\n' > "$case_root/hls/master.m3u8"
  write_test_manifest "$case_root"
  expect_verify_failure "$case_root" 'remote HLS URI'

  case_root="$temporary/keyed-hls"
  cp -R "$fixture_root" "$case_root"
  printf '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\nsegment0.ts\n' \
    > "$case_root/hls/master.m3u8"
  write_test_manifest "$case_root"
  expect_verify_failure "$case_root" 'HLS key dependency'

  printf 'fixture generator self-tests passed\n'
}

fail() {
  printf 'fixture generator: %s\n' "$1" >&2
  exit 1
}

verify_fixture_root() {
  local fixture_root=$1
  python3 - "$fixture_root" <<'PY'
from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import re
import sys

root = Path(sys.argv[1]).resolve(strict=True)
expected = [
    "ac3-48k-5point1.mov",
    "hls/master.m3u8",
    "hls/segment0.ts",
    "interlaced-h264-mp2.ts",
    "progressive-h264-aac.ts",
]
manifest_path = root / "SHA256SUMS"
try:
    raw_manifest = manifest_path.read_bytes()
except OSError as error:
    raise SystemExit(f"cannot read SHA256SUMS: {error}")
try:
    manifest = raw_manifest.decode("ascii", errors="strict")
except UnicodeDecodeError as error:
    raise SystemExit(f"SHA256SUMS is not ASCII: {error}")
if not manifest.endswith("\n") or "\r" in manifest:
    raise SystemExit("SHA256SUMS must use newline-terminated POSIX lines")

entries: dict[str, str] = {}
pattern = re.compile(r"([0-9a-f]{64})  ([^\n]+)")
for line in manifest.splitlines():
    match = pattern.fullmatch(line)
    if match is None:
        raise SystemExit(f"invalid SHA256SUMS line: {line!r}")
    digest, relative = match.groups()
    pure = PurePosixPath(relative)
    if (
        pure.is_absolute()
        or str(pure) != relative
        or "\\" in relative
        or any(part in ("", ".", "..") for part in relative.split("/"))
    ):
        raise SystemExit(f"unsafe SHA256SUMS path: {relative!r}")
    if relative in entries:
        raise SystemExit(f"duplicate SHA256SUMS path: {relative!r}")
    entries[relative] = digest

if list(entries) != expected:
    raise SystemExit(
        f"SHA256SUMS paths/order differ: expected {expected!r}, got {list(entries)!r}"
    )

actual: list[str] = []
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        raise SystemExit(f"symlink is forbidden in fixture root: {relative!r}")
    if path.is_file() and relative != "SHA256SUMS":
        actual.append(relative)
if sorted(actual) != expected:
    raise SystemExit(f"fixture files differ: expected {expected!r}, got {sorted(actual)!r}")

for relative in expected:
    data = (root / relative).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != entries[relative]:
        raise SystemExit(f"SHA-256 mismatch for {relative}")

playlist_path = root / "hls/master.m3u8"
try:
    playlist = playlist_path.read_text(encoding="utf-8", errors="strict")
except (OSError, UnicodeDecodeError) as error:
    raise SystemExit(f"invalid HLS playlist: {error}")
if not playlist.startswith("#EXTM3U\n") or not playlist.endswith("\n"):
    raise SystemExit("HLS playlist must be newline-terminated and start with #EXTM3U")
if "#EXT-X-KEY" in playlist:
    raise SystemExit("HLS key dependencies are forbidden")
uris = [line for line in playlist.splitlines() if line and not line.startswith("#")]
if uris != ["segment0.ts"]:
    raise SystemExit(f"HLS must contain only the in-root segment0.ts URI, got {uris!r}")
uri = uris[0]
if (
    "://" in uri
    or uri.startswith("/")
    or "\\" in uri
    or "?" in uri
    or "#" in uri
    or any(part in ("", ".", "..") for part in uri.split("/"))
):
    raise SystemExit(f"unsafe HLS URI: {uri!r}")
if not (playlist_path.parent / uri).resolve(strict=True).is_relative_to(root):
    raise SystemExit(f"HLS URI escapes fixture root: {uri!r}")
PY
}

require_generation_tools() {
  command -v "$ffmpeg_command" >/dev/null 2>&1 || fail 'ffmpeg is required to regenerate fixtures'
  command -v "$ffprobe_command" >/dev/null 2>&1 || fail 'ffprobe is required to validate regenerated fixtures'

  local version encoders filters
  version="$($ffmpeg_command -version)"
  [[ "${version%%$'\n'*}" == ffmpeg\ version\ 8.1.2\ Copyright* ]] || \
    fail 'exact ffmpeg version 8.1.2 is required'
  [[ "$version" == *'--prefix=/opt/homebrew/Cellar/ffmpeg/8.1.2_1'* ]] || \
    fail 'exact Homebrew ffmpeg 8.1.2_1 provenance is required'
  [[ "$version" == *'--enable-libx264'* ]] || fail 'ffmpeg lacks libx264 support'

  encoders="$($ffmpeg_command -hide_banner -encoders 2>/dev/null)"
  for encoder in libx264 aac ac3_fixed mp2; do
    grep -Eq "^[[:space:]][A-Z.]{6}[[:space:]]+$encoder([[:space:]]|$)" <<< "$encoders" || \
      fail "ffmpeg lacks required encoder: $encoder"
  done
  filters="$($ffmpeg_command -hide_banner -filters 2>/dev/null)"
  for filter in aevalsrc testsrc2 sine tinterlace setfield format; do
    grep -Eq "^[[:space:]][A-Z.|]{2,4}[[:space:]]+$filter([[:space:]]|$)" <<< "$filters" || \
      fail "ffmpeg lacks required filter: $filter"
  done
}

generate_progressive() {
  local output=$1
  "$ffmpeg_command" -hide_banner -loglevel error -nostdin -y \
    -filter_threads 1 -filter_complex_threads 1 \
    -f lavfi -i 'testsrc2=size=1280x720:rate=25:duration=2' \
    -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=2' \
    -map 0:v:0 -map 1:a:0 -t 2 -map_metadata -1 -map_chapters -1 \
    -metadata creation_time='1970-01-01T00:00:00Z' \
    -metadata service_provider='VPlayer' -metadata service_name='progressive-h264-aac' \
    -metadata:s:v:0 language=und -metadata:s:a:0 language=und \
    -c:v libx264 -preset veryfast -profile:v high -level:v 4.1 -pix_fmt yuv420p \
    -r:v 25 -fps_mode:v cfr -enc_time_base:v 1:25 \
    -g:v 25 -keyint_min:v 25 -bf:v 2 -sc_threshold:v 0 \
    -x264-params 'threads=1:lookahead_threads=1:sliced_threads=0:sync-lookahead=0:keyint=25:min-keyint=25:scenecut=0:bframes=2:b-adapt=0:rc-lookahead=25:force-cfr=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off' \
    -threads:v 1 -crf:v 23 \
    -color_range:v tv -colorspace:v bt709 -color_primaries:v bt709 -color_trc:v bt709 \
    -c:a aac -aac_coder twoloop -b:a 128k -ar:a 48000 -ac:a 2 \
    -enc_time_base:a 1:48000 -threads:a 1 \
    -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
    -mpegts_transport_stream_id 1 -mpegts_original_network_id 1 \
    -mpegts_service_id 1 -mpegts_pmt_start_pid 4096 -mpegts_start_pid 256 \
    -muxdelay 0 -muxpreload 0 -f mpegts "$output"
}

generate_interlaced() {
  local output=$1
  "$ffmpeg_command" -hide_banner -loglevel error -nostdin -y \
    -filter_threads 1 -filter_complex_threads 1 \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=50:duration=2' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
    -map 0:v:0 -map 1:a:0 -t 2 -map_metadata -1 -map_chapters -1 \
    -metadata creation_time='1970-01-01T00:00:00Z' \
    -metadata service_provider='VPlayer' -metadata service_name='interlaced-h264-mp2' \
    -metadata:s:v:0 language=und -metadata:s:a:0 language=und \
    -vf 'tinterlace=mode=interleave_top,setfield=tff,format=yuv420p' \
    -c:v libx264 -preset veryfast -profile:v high -level:v 4.1 -pix_fmt yuv420p \
    -r:v 25 -fps_mode:v cfr -enc_time_base:v 1:25 -field_order:v tt -top:v 1 \
    -flags:v +ilme+ildct+bitexact \
    -g:v 25 -keyint_min:v 25 -bf:v 2 -sc_threshold:v 0 \
    -x264-params 'threads=1:lookahead_threads=1:sliced_threads=0:sync-lookahead=0:keyint=25:min-keyint=25:scenecut=0:bframes=2:b-adapt=0:rc-lookahead=25:force-cfr=1:interlaced=1:tff=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off' \
    -threads:v 1 -crf:v 23 \
    -color_range:v tv -colorspace:v bt709 -color_primaries:v bt709 -color_trc:v bt709 \
    -c:a mp2 -b:a 192k -ar:a 48000 -ac:a 2 -enc_time_base:a 1:48000 -threads:a 1 \
    -fflags +bitexact -flags:a +bitexact \
    -mpegts_transport_stream_id 1 -mpegts_original_network_id 1 \
    -mpegts_service_id 1 -mpegts_pmt_start_pid 4096 -mpegts_start_pid 256 \
    -muxdelay 0 -muxpreload 0 -f mpegts "$output"
}

generate_ac3_mov() {
  local output=$1
  "$ffmpeg_command" -hide_banner -loglevel error -nostdin -y \
    -filter_threads 1 -filter_complex_threads 1 \
    -f lavfi -i 'aevalsrc=0|0|0.0625*sin(2*PI*440*t)|0|0|0:s=48000:d=2:c=5.1' \
    -map 0:a:0 -t 2 -map_metadata -1 -map_chapters -1 \
    -metadata creation_time='1970-01-01T00:00:00Z' \
    -metadata:s:a:0 language=und \
    -c:a ac3_fixed -b:a 448k -ar:a 48000 -ac:a 6 -channel_layout:a:0 5.1 \
    -enc_time_base:a 1:48000 -threads:a 1 \
    -fflags +bitexact -flags:a +bitexact \
    -movflags +faststart+disable_chpl -f mov "$output"
}

write_hls_playlist() {
  local output=$1
  printf '%s\n' \
    '#EXTM3U' \
    '#EXT-X-VERSION:3' \
    '#EXT-X-TARGETDURATION:2' \
    '#EXT-X-MEDIA-SEQUENCE:0' \
    '#EXT-X-PLAYLIST-TYPE:VOD' \
    '#EXT-X-INDEPENDENT-SEGMENTS' \
    '#EXTINF:2.000000,' \
    'segment0.ts' \
    '#EXT-X-ENDLIST' > "$output"
}

write_manifest() {
  local fixture_root=$1 path
  : > "$fixture_root/SHA256SUMS"
  for path in ac3-48k-5point1.mov hls/master.m3u8 hls/segment0.ts interlaced-h264-mp2.ts progressive-h264-aac.ts; do
    (cd "$fixture_root" && shasum -a 256 "$path") >> "$fixture_root/SHA256SUMS"
  done
}

validate_generated_media() {
  local fixture_root=$1
  python3 - "$ffprobe_command" "$fixture_root" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

ffprobe, root_text = sys.argv[1:]
root = Path(root_text)
if (root / "hls/segment0.ts").read_bytes() != (root / "progressive-h264-aac.ts").read_bytes():
    raise SystemExit("HLS segment must be byte-identical to the validated progressive TS")
cases = [
    ("progressive-h264-aac.ts", 1280, 720, "progressive", 2, "aac", 50, 40),
    ("interlaced-h264-mp2.ts", 1920, 1080, "tt", 2, "mp2", 25, 40),
    ("hls/master.m3u8", 1280, 720, None, 2, "aac", 50, 40),
]
for relative, width, height, field_order, b_frames, audio_codec, video_count, audio_count in cases:
    command = [
        ffprobe,
        "-v", "error",
        "-count_packets",
        "-show_streams",
        "-show_format",
        "-of", "json",
        str(root / relative),
    ]
    document = json.loads(subprocess.check_output(command, text=True))
    video = next(stream for stream in document["streams"] if stream["codec_type"] == "video")
    audio = next(stream for stream in document["streams"] if stream["codec_type"] == "audio")
    checks = {
        "video codec": video.get("codec_name") == "h264",
        "dimensions": (video.get("width"), video.get("height")) == (width, height),
        "frame rate": video.get("avg_frame_rate") == "25/1",
        "time base": video.get("time_base") == "1/90000",
        "pixel format": video.get("pix_fmt") == "yuv420p",
        "field order": field_order is None or video.get("field_order") == field_order,
        "B frames": int(video.get("has_b_frames", 0)) == b_frames,
        "color range": video.get("color_range") == "tv",
        "color space": video.get("color_space") == "bt709",
        "color transfer": video.get("color_transfer") == "bt709",
        "color primaries": video.get("color_primaries") == "bt709",
        "video packets": int(video.get("nb_read_packets", 0)) >= video_count,
        "audio codec": audio.get("codec_name") == audio_codec,
        "audio rate": audio.get("sample_rate") == "48000",
        "audio channels": int(audio.get("channels", 0)) == 2,
        "audio packets": int(audio.get("nb_read_packets", 0)) >= audio_count,
        "duration": 1.95 <= float(document["format"]["duration"]) <= 2.10,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise SystemExit(f"{relative} failed media validation: {failed}; {document}")

command = [
    ffprobe,
    "-v", "error",
    "-count_packets",
    "-show_streams",
    "-show_format",
    "-of", "json",
    str(root / "ac3-48k-5point1.mov"),
]
document = json.loads(subprocess.check_output(command, text=True))
audio_streams = [stream for stream in document["streams"] if stream["codec_type"] == "audio"]
checks = {
    "one audio stream": len(audio_streams) == 1,
    "no video stream": not any(
        stream["codec_type"] == "video" for stream in document["streams"]
    ),
}
if len(audio_streams) == 1:
    audio = audio_streams[0]
    checks.update({
        "audio codec": audio.get("codec_name") == "ac3",
        "audio rate": audio.get("sample_rate") == "48000",
        "audio channels": int(audio.get("channels", 0)) == 6,
        "audio layout": audio.get("channel_layout") == "5.1(side)",
        "audio packets": int(audio.get("nb_read_packets", 0)) >= 62,
        "duration": 1.95 <= float(document["format"]["duration"]) <= 2.10,
    })
failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit(
        f"ac3-48k-5point1.mov failed media validation: {failed}; {document}"
    )
PY
}

regenerate() {
  require_generation_tools
  local generated
  generated="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-playback-fixtures.XXXXXX")"
  trap 'rm -rf "$generated"' EXIT
  mkdir -p "$generated/hls"

  generate_progressive "$generated/progressive-h264-aac.ts"
  generate_interlaced "$generated/interlaced-h264-mp2.ts"
  generate_ac3_mov "$generated/ac3-48k-5point1.mov"
  cp "$generated/progressive-h264-aac.ts" "$generated/hls/segment0.ts"
  write_hls_playlist "$generated/hls/master.m3u8"
  write_manifest "$generated"
  verify_fixture_root "$generated"
  validate_generated_media "$generated"

  mkdir -p "$fixture_root/hls"
  install -m 0644 "$generated/ac3-48k-5point1.mov" "$fixture_root/ac3-48k-5point1.mov"
  install -m 0644 "$generated/progressive-h264-aac.ts" "$fixture_root/progressive-h264-aac.ts"
  install -m 0644 "$generated/interlaced-h264-mp2.ts" "$fixture_root/interlaced-h264-mp2.ts"
  install -m 0644 "$generated/hls/master.m3u8" "$fixture_root/hls/master.m3u8"
  install -m 0644 "$generated/hls/segment0.ts" "$fixture_root/hls/segment0.ts"
  install -m 0644 "$generated/SHA256SUMS" "$fixture_root/SHA256SUMS"
  verify_fixture_root "$fixture_root"
  trap - EXIT
  rm -rf "$generated"
}

if [[ ${1:-} == --self-test ]]; then
  run_self_tests
  exit 0
fi

root="$(cd "$(dirname "$0")/.." && pwd -P)"
fixture_root="$root/Tests/VPlayerTests/Fixtures/Media"
ffmpeg_command="${FFMPEG:-ffmpeg}"
ffprobe_command="${FFPROBE:-ffprobe}"

case ${1:-} in
  --verify)
    [[ $# -eq 1 ]] || fail 'unexpected arguments after --verify'
    verify_fixture_root "$fixture_root"
    ;;
  --verify-root)
    [[ ${VPLAYER_FIXTURE_GENERATOR_SELF_TEST:-0} == 1 ]] || \
      fail '--verify-root is reserved for the generator self-test'
    [[ $# -eq 2 ]] || fail '--verify-root requires exactly one path'
    verify_fixture_root "$2"
    ;;
  '')
    regenerate
    ;;
  *)
    fail "unexpected argument: $1"
    ;;
esac
