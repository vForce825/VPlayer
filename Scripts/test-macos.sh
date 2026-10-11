#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
scheme=VPlayerMacOS
if [[ "${1:-}" == "--headless" ]]; then scheme=VPlayerMacOSHeadless; shift; fi
selected_tests=""
if [[ "$scheme" == VPlayerMacOSHeadless && "${1:-}" == "--tests" ]]; then
  selected_tests="${2:?--tests 需要测试类或测试方法名称}"
  shift 2
fi
if [[ ! -f Vendor/FFmpeg/Artifacts-macOS/FFmpeg.xcframework/Info.plist ]]; then
  Scripts/build-ffmpeg.sh --platform macos
else
  Scripts/audit-ffmpeg.sh --platform macos Vendor/FFmpeg/Artifacts-macOS/FFmpeg.xcframework
fi
Scripts/build-metal-libraries.sh --platform macos
mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate --spec project.yml
# 延长已入库夹具的连续时间戳，避免直播暂停验收撞上 16 秒文件的自然 EOF。
command -v ffmpeg >/dev/null || { echo '播放验收需要 ffmpeg：brew install ffmpeg' >&2; exit 1; }
mkdir -p build/macos-test-fixtures
for kind in progressive-h264-aac interlaced-h264-mp2; do
  input="Tests/VPlayerTests/Fixtures/Media/task22-$kind-16s.ts"
  output="build/macos-test-fixtures/macos-$kind-live.ts"
  if [[ ! -f "$output" || "$input" -nt "$output" ]]; then
    ffmpeg -hide_banner -loglevel error -nostdin -y -stream_loop 3 -i "$input" \
      -map 0:v:0 -map 0:a:0 -c copy -t 60 -f mpegts "$output"
  fi
done
# 仅终止本脚本启动的夹具服务器；已有进程占用端口时直接失败。
python3 Scripts/Support/macos-fixture-server.py > build/macos-fixture-server.log 2>&1 &
fixture_pid=$!
cleanup() { kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
kill -0 "$fixture_pid" || { cat build/macos-fixture-server.log; exit 1; }
if [[ "$scheme" == VPlayerMacOSHeadless ]]; then
  xcodebuild -project VPlayer.xcodeproj -scheme "$scheme" \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedDataMacOS CODE_SIGN_IDENTITY=- build-for-testing "$@"
  test_bundle="$root/build/DerivedDataMacOS/Build/Products/Debug/VPlayerMacOSHeadlessTests.xctest"
  test -d "$test_bundle"
  # 直接运行测试包，避免锁屏时 Xcode 的启动诊断依赖图形自动化。
  if [[ -n "$selected_tests" ]]; then
    DYLD_FRAMEWORK_PATH="$root/build/DerivedDataMacOS/Build/Products/Debug" \
      xcrun xctest -XCTest "$selected_tests" "$test_bundle"
  else
    DYLD_FRAMEWORK_PATH="$root/build/DerivedDataMacOS/Build/Products/Debug" \
      xcrun xctest "$test_bundle"
  fi
else
  xcodebuild -project VPlayer.xcodeproj -scheme "$scheme" \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedDataMacOS CODE_SIGN_IDENTITY=- test "$@"
fi
