#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/FFmpeg/ffmpeg.lock.json"
commit="$(jq -er '.commit' "$lock")"
source_url="$(jq -er '.sourceURL' "$lock")"
source_tree="$root/Vendor/FFmpeg/Work/source"
build="$root/Vendor/FFmpeg/Work/yadif-reference"

configure_args=(
  --disable-autodetect
  --disable-everything
  --disable-doc
  --disable-debug
  --disable-network
  --disable-gpl
  --disable-nonfree
  --disable-version3
  --disable-ffprobe
  --disable-ffplay
  --enable-ffmpeg
  --enable-avcodec
  --enable-avdevice
  --enable-avfilter
  --enable-avformat
  --enable-avutil
  --enable-swscale
  --enable-decoder=wrapped_avframe
  --enable-indev=lavfi
  --enable-muxer=rawvideo
  --enable-encoder=rawvideo
  --enable-protocol=file
  --enable-filter=testsrc2,format,scale,setfield,separatefields,select,weave,yadif,trim
)

verify_source() {
  [[ "$(git -C "$source_tree" rev-parse HEAD)" == "$commit" ]] || {
    echo "FFmpeg source is not at locked commit $commit" >&2
    exit 2
  }
  [[ -z "$(git -C "$source_tree" status --porcelain)" ]] || {
    echo "FFmpeg source worktree is not clean" >&2
    exit 2
  }
}

if [[ ! -d "$source_tree/.git" ]]; then
  git clone --filter=blob:none "$source_url" "$source_tree"
else
  [[ -z "$(git -C "$source_tree" status --porcelain)" ]] || {
    echo "Refusing to change a dirty FFmpeg source worktree" >&2
    exit 2
  }
fi

if [[ "$(git -C "$source_tree" rev-parse HEAD)" != "$commit" ]]; then
  git -C "$source_tree" fetch --depth 1 origin "$commit"
  git -C "$source_tree" checkout --detach "$commit"
fi
verify_source

mkdir -p "$build"
config_sha="$(printf '%s\n' "${configure_args[@]}" | shasum -a 256 | awk '{print $1}')"
commit_stamp="$build/.vplayer-commit"
config_stamp="$build/.vplayer-config-sha256"

if [[ -f "$commit_stamp" && "$(<"$commit_stamp")" != "$commit" ]]; then
  echo "Stale YADIF reference commit stamp; remove $build and retry" >&2
  exit 2
fi
if [[ -f "$config_stamp" && "$(<"$config_stamp")" != "$config_sha" ]]; then
  echo "Stale YADIF reference configuration stamp; remove $build and retry" >&2
  exit 2
fi

if [[ -x "$build/ffmpeg" ]]; then
  [[ -f "$commit_stamp" && -f "$config_stamp" ]] || {
    echo "Unstamped YADIF reference binary; remove $build and retry" >&2
    exit 2
  }
else
  if find "$build" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "Partial YADIF reference build; remove $build and retry" >&2
    exit 2
  fi
  (
    cd "$build"
    "$source_tree/configure" "${configure_args[@]}"
    make -j"$(sysctl -n hw.logicalcpu)" ffmpeg
  )
  printf '%s\n' "$commit" > "$commit_stamp"
  printf '%s\n' "$config_sha" > "$config_stamp"
fi

[[ -x "$build/ffmpeg" ]] || {
  echo "Pinned YADIF reference build is missing" >&2
  exit 2
}
grep -q '^#define CONFIG_GPL 0$' "$build/config.h"
for filter in SCALE SETFIELD SEPARATEFIELDS SELECT WEAVE YADIF TRIM; do
  grep -q "^#define CONFIG_${filter}_FILTER 1$" "$build/config_components.h"
done
verify_source
