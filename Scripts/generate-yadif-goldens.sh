#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build-yadif-reference.sh"
reference="$root/Vendor/FFmpeg/Work/yadif-reference/ffmpeg"
fixtures="$root/Tests/Fixtures/Video"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
commit="$(jq -er '.commit' "$lock")"
nv12_source='testsrc2=size=128x72:rate=50:duration=0.20,scale=64:36:flags=bilinear'
p010_source='testsrc2=size=128x72:rate=50:duration=0.20,format=yuv420p10le,scale=64:36:flags=bilinear'
trim_filter='trim=start_frame=2:end_frame=8'
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-yadif.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

[[ -x "$reference" ]] || {
  echo "Pinned YADIF reference build is missing" >&2
  exit 2
}

tff_graph="setfield=tff,separatefields,select='eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3)',weave=first_field=top"
bff_graph="setfield=tff,separatefields,select='eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2)',weave=first_field=bottom"
nv12_tff_input_graph="format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3),weave=first_field=top,format=nv12"
nv12_bff_input_graph="format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2),weave=first_field=bottom,format=nv12"
nv12_tff_output_graph="format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3),weave=first_field=top,yadif=mode=send_field:parity=tff:deint=all,trim=start_frame=2:end_frame=8,format=nv12"
nv12_bff_output_graph="format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2),weave=first_field=bottom,yadif=mode=send_field:parity=bff:deint=all,trim=start_frame=2:end_frame=8,format=nv12"
p010_tff_input_graph="setfield=tff,separatefields,select=eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3),weave=first_field=top,format=p010le"
p010_bff_input_graph="setfield=tff,separatefields,select=eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2),weave=first_field=bottom,format=p010le"
p010_tff_output_graph="setfield=tff,separatefields,select=eq(mod(n\,4)\,0)+eq(mod(n\,4)\,3),weave=first_field=top,yadif=mode=send_field:parity=tff:deint=all,trim=start_frame=2:end_frame=8,format=p010le"
p010_bff_output_graph="setfield=tff,separatefields,select=eq(mod(n\,4)\,1)+eq(mod(n\,4)\,2),weave=first_field=bottom,yadif=mode=send_field:parity=bff:deint=all,trim=start_frame=2:end_frame=8,format=p010le"

generate_order() {
  local family="$1"
  local pixel_format="$2"
  local source="$3"
  local planar_prefix="$4"
  local stem="$5"
  local field_graph="$6"
  local parity="$7"
  local bytes_per_frame="$8"
  local input="$temporary/yadif-${family}-${stem}-input.bin"
  local golden="$temporary/yadif-${family}-${stem}.bin"

  "$reference" -hide_banner -loglevel error -y \
    -f lavfi -i "$source" \
    -vf "${planar_prefix}${field_graph},format=${pixel_format}" \
    -frames:v 5 -fps_mode passthrough -pix_fmt "$pixel_format" -f rawvideo "$input"

  "$reference" -hide_banner -loglevel error -y \
    -f lavfi -i "$source" \
    -vf "${planar_prefix}${field_graph},yadif=mode=send_field:parity=${parity}:deint=all,${trim_filter},format=${pixel_format}" \
    -frames:v 6 -fps_mode passthrough -pix_fmt "$pixel_format" -f rawvideo "$golden"

  [[ "$(wc -c < "$input" | tr -d ' ')" == "$((5 * bytes_per_frame))" ]] || {
    echo "Unexpected ${family} ${stem} input size" >&2
    exit 2
  }
  [[ "$(wc -c < "$golden" | tr -d ' ')" == "$((6 * bytes_per_frame))" ]] || {
    echo "Unexpected ${family} ${stem} golden size" >&2
    exit 2
  }
}

generate_order nv12 nv12 "$nv12_source" 'format=yuv420p,' tff "$tff_graph" tff 3456
generate_order nv12 nv12 "$nv12_source" 'format=yuv420p,' bff "$bff_graph" bff 3456
generate_order p010 p010le "$p010_source" '' tff "$tff_graph" tff 6912
generate_order p010 p010le "$p010_source" '' bff "$bff_graph" bff 6912

verify_unique_luma_frames() {
  local family="$1"
  local stem="$2"
  local bytes_per_frame="$3"
  local luma_bytes="$4"
  local input="$temporary/yadif-${family}-${stem}-input.bin"
  local unique_count
  unique_count="$({
    for frame in 0 1 2 3 4; do
      dd if="$input" bs=1 skip="$((frame * bytes_per_frame))" count="$luma_bytes" 2>/dev/null \
        | shasum -a 256 | awk '{print $1}'
    done
  } | sort -u | wc -l | tr -d ' ')"
  [[ "$unique_count" == "5" ]] || {
    echo "${family} ${stem} input does not contain five unique luma frames" >&2
    exit 2
  }
}

verify_unique_luma_frames nv12 tff 3456 2304
verify_unique_luma_frames nv12 bff 3456 2304
verify_unique_luma_frames p010 tff 6912 4608
verify_unique_luma_frames p010 bff 6912 4608

for family in nv12 p010; do
  if cmp -s \
    "$temporary/yadif-${family}-tff-input.bin" \
    "$temporary/yadif-${family}-bff-input.bin"; then
    echo "TFF and BFF inputs are unexpectedly identical for ${family}" >&2
    exit 2
  fi
done

generate_progressive() {
  local family="$1"
  local pixel_format="$2"
  local source="$3"
  local planar_prefix="$4"
  local expected_size="$5"
  local progressive="$temporary/${family}-progressive.bin"
  "$reference" -hide_banner -loglevel error -y \
    -f lavfi -i "$source" \
    -vf "${planar_prefix}format=${pixel_format}" \
    -frames:v 10 -fps_mode passthrough -pix_fmt "$pixel_format" -f rawvideo "$progressive"
  [[ "$(wc -c < "$progressive" | tr -d ' ')" == "$expected_size" ]] || {
    echo "Unexpected ${family} progressive provenance size" >&2
    exit 2
  }
}

generate_progressive nv12 nv12 "$nv12_source" 'format=yuv420p,' 34560
generate_progressive p010 p010le "$p010_source" '' 69120

verify_luma_row_provenance() {
  local family="$1"
  local stem="$2"
  local bytes_per_frame="$3"
  local row_bytes="$4"
  local input="$temporary/yadif-${family}-${stem}-input.bin"
  local progressive="$temporary/${family}-progressive.bin"
  for frame in 0 1 2 3 4; do
    for row in {0..35}; do
      local source_frame
      if [[ "$stem" == "tff" ]]; then
        source_frame=$((2 * frame + row % 2))
      else
        source_frame=$((2 * frame + 1 - row % 2))
      fi
      local output_offset=$((frame * bytes_per_frame + row * row_bytes))
      local source_offset=$((source_frame * bytes_per_frame + row * row_bytes))
      dd if="$input" bs=1 skip="$output_offset" count="$row_bytes" 2>/dev/null \
        | cmp -s - <(dd if="$progressive" bs=1 skip="$source_offset" count="$row_bytes" 2>/dev/null) || {
        echo "${family} ${stem} row provenance mismatch at frame ${frame}, row ${row}" >&2
        exit 2
      }
    done
  done
}

verify_luma_row_provenance nv12 tff 3456 64
verify_luma_row_provenance nv12 bff 3456 64
verify_luma_row_provenance p010 tff 6912 128
verify_luma_row_provenance p010 bff 6912 128

verify_p010_low_bits() {
  local file="$1"
  od -An -tu2 -v "$file" | awk '
    { for (column = 1; column <= NF; column += 1) if ($column % 64 != 0) exit 1 }
  ' || {
    echo "P010 low-six-bit violation in $(basename "$file")" >&2
    exit 2
  }
}

for file in \
  "$temporary/yadif-p010-tff-input.bin" \
  "$temporary/yadif-p010-bff-input.bin" \
  "$temporary/yadif-p010-tff.bin" \
  "$temporary/yadif-p010-bff.bin"; do
  verify_p010_low_bits "$file"
done

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

jq -n -S \
  --arg commit "$commit" \
  --arg nv12_source "$nv12_source" \
  --arg p010_source "$p010_source" \
  --arg trim "$trim_filter" \
  --arg nv12_tff_input_graph "$nv12_tff_input_graph" \
  --arg nv12_bff_input_graph "$nv12_bff_input_graph" \
  --arg nv12_tff_output_graph "$nv12_tff_output_graph" \
  --arg nv12_bff_output_graph "$nv12_bff_output_graph" \
  --arg p010_tff_input_graph "$p010_tff_input_graph" \
  --arg p010_bff_input_graph "$p010_bff_input_graph" \
  --arg p010_tff_output_graph "$p010_tff_output_graph" \
  --arg p010_bff_output_graph "$p010_bff_output_graph" \
  --arg nv12_tff_input_sha "$(sha "$temporary/yadif-nv12-tff-input.bin")" \
  --arg nv12_bff_input_sha "$(sha "$temporary/yadif-nv12-bff-input.bin")" \
  --arg nv12_tff_sha "$(sha "$temporary/yadif-nv12-tff.bin")" \
  --arg nv12_bff_sha "$(sha "$temporary/yadif-nv12-bff.bin")" \
  --arg p010_tff_input_sha "$(sha "$temporary/yadif-p010-tff-input.bin")" \
  --arg p010_bff_input_sha "$(sha "$temporary/yadif-p010-bff-input.bin")" \
  --arg p010_tff_sha "$(sha "$temporary/yadif-p010-tff.bin")" \
  --arg p010_bff_sha "$(sha "$temporary/yadif-p010-bff.bin")" \
  '{
    schemaVersion: 2,
    ffmpegCommit: $commit,
    width: 64,
    height: 36,
    formats: {
      nv12: {
        source: $nv12_source,
        pixelFormat: "nv12",
        layout: "bi-planar-420-8-bit",
        inputFrameCount: 5,
        outputFrameCount: 6,
        bytesPerFrame: 3456,
        graphs: {
          tffInput: $nv12_tff_input_graph,
          bffInput: $nv12_bff_input_graph,
          tffOutput: $nv12_tff_output_graph,
          bffOutput: $nv12_bff_output_graph
        }
      },
      p010le: {
        source: $p010_source,
        pixelFormat: "p010le",
        layout: "bi-planar-420-10-bit-msb16",
        inputFrameCount: 5,
        outputFrameCount: 6,
        bytesPerFrame: 6912,
        graphs: {
          tffInput: $p010_tff_input_graph,
          bffInput: $p010_bff_input_graph,
          tffOutput: $p010_tff_output_graph,
          bffOutput: $p010_bff_output_graph
        }
      }
    },
    generatorArguments: {trim: $trim},
    files: {
      "yadif-nv12-tff-input.bin": {byteCount: 17280, sha256: $nv12_tff_input_sha},
      "yadif-nv12-bff-input.bin": {byteCount: 17280, sha256: $nv12_bff_input_sha},
      "yadif-nv12-tff.bin": {byteCount: 20736, sha256: $nv12_tff_sha},
      "yadif-nv12-bff.bin": {byteCount: 20736, sha256: $nv12_bff_sha},
      "yadif-p010-tff-input.bin": {byteCount: 34560, sha256: $p010_tff_input_sha},
      "yadif-p010-bff-input.bin": {byteCount: 34560, sha256: $p010_bff_input_sha},
      "yadif-p010-tff.bin": {byteCount: 41472, sha256: $p010_tff_sha},
      "yadif-p010-bff.bin": {byteCount: 41472, sha256: $p010_bff_sha}
    }
  }' > "$temporary/yadif-golden-manifest.json"

mkdir -p "$fixtures"
for name in \
  yadif-nv12-tff-input.bin yadif-nv12-bff-input.bin \
  yadif-nv12-tff.bin yadif-nv12-bff.bin \
  yadif-p010-tff-input.bin yadif-p010-bff-input.bin \
  yadif-p010-tff.bin yadif-p010-bff.bin \
  yadif-golden-manifest.json; do
  mv "$temporary/$name" "$fixtures/$name"
done
