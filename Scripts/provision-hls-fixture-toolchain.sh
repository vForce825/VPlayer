#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Fixture-only host executables. Never edits app configure.flags, Work or Artifacts.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd -P)"
lock="$repository/Vendor/FFmpeg/ffmpeg.lock.json"
[[ $# == 0 ]] || { echo 'Usage: Scripts/provision-hls-fixture-toolchain.sh' >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Fixture host CLI provisioning requires macOS/Xcode.' >&2; exit 1; }
for tool in brew git python3 make tar xcrun; do
  command -v "$tool" >/dev/null || { echo "Missing trusted host build tool: $tool" >&2; exit 1; }
done
python3 "$repository/Scripts/Support/hls_fixture_toolchain.py" --lock "$lock" --check-lock >&2
temporary_base="$(cd "${RUNNER_TEMP:-${TMPDIR:-/tmp}}" && pwd -P)"
case "$temporary_base/" in "$repository/"*)
  echo 'Fixture-only build root must be outside the application repository and its build ownership.' >&2
  exit 1;;
esac
root="$(mktemp -d "$temporary_base/vplayer-fixture-cli.XXXXXX")"
checkout="$root/checkout"
source="$root/source"
build="$root/build"
prefix="$root/install"
mkdir "$checkout" "$source" "$build" "$prefix"
echo "FIXTURE_ONLY_BUILD_ROOT=$root" >&2
commit=38b88335f99e76ed89ff3c93f877fdefce736c13
tag=n8.1.2
urls=(https://git.ffmpeg.org/ffmpeg.git https://github.com/FFmpeg/FFmpeg.git)
git -C "$checkout" init -q
fetched=''
for url in "${urls[@]}"; do
  # Public official endpoints only, no credentials or alternate untrusted mirrors.
  if GIT_TERMINAL_PROMPT=0 python3 - "$checkout" "$url" "$tag" <<'PYFETCH'
import os,signal,subprocess,sys
checkout,url,tag=sys.argv[1:]
process=subprocess.Popen(['git','-C',checkout,'-c','http.lowSpeedLimit=1024','-c','http.lowSpeedTime=30',
     'fetch','--no-tags','--depth','1',url,f'refs/tags/{tag}:refs/tags/{tag}'],start_new_session=True)
try: raise SystemExit(process.wait(timeout=180))
except subprocess.TimeoutExpired:
 os.killpg(process.pid,signal.SIGKILL);process.wait()
 raise SystemExit('Official FFmpeg tag fetch exceeded 180 seconds')
PYFETCH
  then fetched="$url"; break; fi
done
[[ -n "$fetched" ]] || { echo 'Cannot fetch the locked official FFmpeg source; no fallback binary is allowed.' >&2; exit 1; }
actual="$(git -C "$checkout" rev-parse "refs/tags/$tag^{}")"
[[ "$actual" == "$commit" ]] || { echo "Fixture source mismatch: expected $commit, actual $actual" >&2; exit 1; }
source_tree="$(git -C "$checkout" rev-parse "$commit^{tree}")"
# Export immutable source into a host-only tree; app source checkout/locks are untouched.
git -C "$checkout" archive "$commit" | tar -x -C "$source"
export SOURCE_DATE_EPOCH="$(git -C "$checkout" show -s --format=%ct "$commit")"
export ZERO_AR_DATE=1
x264_prefix="$(brew --prefix x264)"
x265_prefix="$(brew --prefix x265)"
export PKG_CONFIG_PATH="$x264_prefix/lib/pkgconfig:$x265_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cc="$(xcrun --sdk macosx --find clang)"
sysroot="$(xcrun --sdk macosx --show-sdk-path)"
flags=(--prefix="$prefix" --cc="$cc" --sysroot="$sysroot" --disable-autodetect \
  --disable-network --disable-shared --enable-static --enable-gpl --enable-libx264 --enable-libx265 \
  --enable-ffmpeg --enable-ffprobe --disable-ffplay --disable-doc --disable-debug --pkg-config-flags=--static)
printf '%s\n' "${flags[@]}" > "$root/configure-arguments.txt"
brew list --versions pkgconf x264 x265 nasm > "$root/homebrew-versions.txt"
"$cc" --version > "$root/compiler-version.txt"
make --version > "$root/make-version.txt"
(
  cd "$build"
  "$source/configure" "${flags[@]}"
  make -j "$(sysctl -n hw.ncpu)"
  make install
) >&2
python3 - "$repository" "$root" "$commit" "$source_tree" "$fetched" <<'PYMANIFEST'
import hashlib,importlib.util,json,pathlib,subprocess,sys
repository,root=map(pathlib.Path,sys.argv[1:3]); commit,tree,url=sys.argv[3:]
spec=importlib.util.spec_from_file_location('tools',repository/'Scripts/Support/hls_fixture_toolchain.py')
tools=importlib.util.module_from_spec(spec);spec.loader.exec_module(tools)
prefix=root/'install'; raw={}; hashes={}
for tool in ('ffmpeg','ffprobe'):
 path=prefix/'bin'/tool
 raw[tool]=subprocess.check_output([str(path),'-version'],text=True).splitlines()[0]
 tools.normalized_version(raw[tool],tool)
 hashes[tool]=tools.digest(path)
manifest={'kind':'fixture-only-host-cli','source_commit':commit,'source_tree':tree,'source_tag':'n8.1.2',
 'source_url':url,'raw_versions':raw,'normalized_version':'8.1.2','binary_sha256':hashes,
 'configure_args':(root/'configure-arguments.txt').read_text().splitlines(),
 'dependencies':{'homebrew':(root/'homebrew-versions.txt').read_text().splitlines(),
 'compiler':(root/'compiler-version.txt').read_text().splitlines(),'make':(root/'make-version.txt').read_text().splitlines()},
 'build_recipe_sha256':tools.digest(repository/'Scripts/provision-hls-fixture-toolchain.sh'),
 'license_note':'GPL-enabled fixture-only host CLI; never packaged into the application XCFramework'}
(prefix/'fixture-toolchain.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
print('FIXTURE_TOOLCHAIN_PROVENANCE='+json.dumps(manifest,sort_keys=True),file=sys.stderr)
PYMANIFEST
export FFMPEG="$prefix/bin/ffmpeg" FFPROBE="$prefix/bin/ffprobe"
export HLS_FIXTURE_TOOLCHAIN_MANIFEST="$prefix/fixture-toolchain.json"
"$repository/Scripts/verify-hls-fixture-toolchain.sh" >&2
{
  printf 'export FFMPEG=%q\nexport FFPROBE=%q\nexport HLS_FIXTURE_TOOLCHAIN_MANIFEST=%q\n' \
    "$FFMPEG" "$FFPROBE" "$HLS_FIXTURE_TOOLCHAIN_MANIFEST"
  printf 'export PATH=%q:"$PATH"\n' "$prefix/bin"
} > "$root/tools.env"
# Same-job later steps use the same verified tools. No global install or persistent cache.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'FFMPEG=%s\nFFPROBE=%s\nHLS_FIXTURE_TOOLCHAIN_MANIFEST=%s\n' \
    "$FFMPEG" "$FFPROBE" "$HLS_FIXTURE_TOOLCHAIN_MANIFEST" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then printf '%s\n' "$prefix/bin" >> "$GITHUB_PATH"; fi
printf '%s\n' "$root/tools.env"
