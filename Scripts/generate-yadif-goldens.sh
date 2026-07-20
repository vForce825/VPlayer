#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build-yadif-reference.sh"
reference="$root/Vendor/FFmpeg/Work/yadif-reference/ffmpeg"
fixtures="$root/Tests/Fixtures/Video"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
commit="$(jq -er '.commit' "$lock")"
source_filter='testsrc2=size=64x36:rate=50:duration=0.20'
trim_filter='trim=start_frame=2:end_frame=8'
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-yadif.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

[[ -x "$reference" ]] || {
  echo "Pinned YADIF reference build is missing" >&2
  exit 2
}

generate_order() {
  local stem="$1"
  local field_graph="$2"
  local parity="$3"
  local input="$temporary/yadif-nv12-${stem}-input.bin"
  local golden="$temporary/yadif-nv12-${stem}.bin"

  "$reference" -hide_banner -loglevel error -y \
    -f lavfi -i "$source_filter" \
    -vf "${field_graph},format=nv12" \
    -frames:v 5 -fps_mode passthrough -pix_fmt nv12 -f rawvideo "$input"

  "$reference" -hide_banner -loglevel error -y \
    -f lavfi -i "$source_filter" \
    -vf "${field_graph},yadif=mode=send_field:parity=${parity}:deint=all,${trim_filter},format=nv12" \
    -frames:v 6 -fps_mode passthrough -pix_fmt nv12 -f rawvideo "$golden"

  [[ "$(wc -c < "$input" | tr -d ' ')" == "17280" ]] || {
    echo "Unexpected ${stem} input size" >&2
    exit 2
  }
  [[ "$(wc -c < "$golden" | tr -d ' ')" == "20736" ]] || {
    echo "Unexpected ${stem} golden size" >&2
    exit 2
  }
}

tff_graph="format=yuv420p,setfield=tff,separatefields,select='eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3)',weave=first_field=top"
bff_graph="format=yuv420p,setfield=tff,separatefields,select='eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2)',weave=first_field=bottom"
generate_order tff "$tff_graph" tff
generate_order bff "$bff_graph" bff

progressive="$temporary/progressive.bin"
"$reference" -hide_banner -loglevel error -y \
  -f lavfi -i "$source_filter" \
  -vf 'format=yuv420p,format=nv12' \
  -frames:v 10 -fps_mode passthrough -pix_fmt nv12 -f rawvideo "$progressive"
[[ "$(wc -c < "$progressive" | tr -d ' ')" == "34560" ]] || {
  echo "Unexpected progressive provenance size" >&2
  exit 2
}

verify_luma_row_provenance() {
  local stem="$1"
  local input="$temporary/yadif-nv12-${stem}-input.bin"
  for frame in 0 1 2 3 4; do
    for row in {0..35}; do
      local source_frame
      if [[ "$stem" == "tff" ]]; then
        source_frame=$((2 * frame + row % 2))
      else
        source_frame=$((2 * frame + 1 - row % 2))
      fi
      local output_offset=$((frame * 3456 + row * 64))
      local source_offset=$((source_frame * 3456 + row * 64))
      dd if="$input" bs=1 skip="$output_offset" count=64 2>/dev/null \
        | cmp -s - <(dd if="$progressive" bs=1 skip="$source_offset" count=64 2>/dev/null) || {
        echo "${stem} row provenance mismatch at frame ${frame}, row ${row}" >&2
        exit 2
      }
    done
  done
}

verify_luma_row_provenance tff
verify_luma_row_provenance bff

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

jq -n -S \
  --arg commit "$commit" \
  --arg source "$source_filter" \
  --arg trim "$trim_filter" \
  --arg tff_input_sha "$(sha "$temporary/yadif-nv12-tff-input.bin")" \
  --arg bff_input_sha "$(sha "$temporary/yadif-nv12-bff-input.bin")" \
  --arg tff_sha "$(sha "$temporary/yadif-nv12-tff.bin")" \
  --arg bff_sha "$(sha "$temporary/yadif-nv12-bff.bin")" \
  '{
    schemaVersion: 1,
    ffmpegCommit: $commit,
    width: 64,
    height: 36,
    pixelFormat: "nv12",
    inputFrameCount: 5,
    outputFrameCount: 6,
    generatorArguments: {
      source: $source,
      trim: $trim,
      tff: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3),weave=first_field=top,yadif=mode=send_field:parity=tff:deint=all,trim=start_frame=2:end_frame=8,format=nv12",
      bff: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2),weave=first_field=bottom,yadif=mode=send_field:parity=bff:deint=all,trim=start_frame=2:end_frame=8,format=nv12"
    },
    files: {
      "yadif-nv12-tff-input.bin": {byteCount: 17280, sha256: $tff_input_sha},
      "yadif-nv12-bff-input.bin": {byteCount: 17280, sha256: $bff_input_sha},
      "yadif-nv12-tff.bin": {byteCount: 20736, sha256: $tff_sha},
      "yadif-nv12-bff.bin": {byteCount: 20736, sha256: $bff_sha}
    }
  }' > "$temporary/yadif-golden-manifest.json"

mkdir -p "$fixtures"
for name in \
  yadif-nv12-tff-input.bin yadif-nv12-bff-input.bin \
  yadif-nv12-tff.bin yadif-nv12-bff.bin yadif-golden-manifest.json; do
  mv "$temporary/$name" "$fixtures/$name"
done
