#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/ci_scripts/ci_pre_xcodebuild.sh"
temporary="$(mktemp -d)"

cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

mkdir -p "$temporary/bin"
invocations="$temporary/xcodebuild-invocations.log"

cat > "$temporary/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$XCODEBUILD_INVOCATIONS"
if [ "${FAIL_METAL_DOWNLOAD:-0}" = 1 ] && [ "${1:-}" = "-downloadComponent" ]; then
  exit 23
fi
if [ "${1:-}" = "-showComponent" ]; then
  printf '%s\n' 'Status: installed'
fi
FAKE_XCODEBUILD
chmod +x "$temporary/bin/xcodebuild"

PATH="$temporary/bin:$PATH" XCODEBUILD_INVOCATIONS="$invocations" "$script"

diff -u - "$invocations" <<'EXPECTED'
-downloadComponent MetalToolchain
-showComponent MetalToolchain
EXPECTED

: > "$invocations"
if PATH="$temporary/bin:$PATH" \
  XCODEBUILD_INVOCATIONS="$invocations" \
  FAIL_METAL_DOWNLOAD=1 \
  "$script"; then
  echo "Metal Toolchain 下载失败时 CI 准备脚本必须失败" >&2
  exit 1
fi

diff -u - "$invocations" <<'EXPECTED'
-downloadComponent MetalToolchain
EXPECTED

echo "Xcode Cloud Metal Toolchain preparation OK"
