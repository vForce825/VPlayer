#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

self_test_fail() {
  printf 'runner self-test failed: %s\n' "$1" >&2
  exit 1
}

run_self_tests() {
  local script root temporary fixture_root temp_parent fake_xcode marker seed status signal_name expected
  script="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  root="$(cd "$(dirname "$0")/.." && pwd -P)"
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-runner-self-test.XXXXXX")"
  trap 'rm -rf "$temporary"' RETURN
  fixture_root="$temporary/fixture root"
  temp_parent="$temporary/ports"
  mkdir -p "$fixture_root" "$temp_parent"
  printf 'fixture\n' > "$fixture_root/SHA256SUMS"

  fake_xcode="$temporary/fake-xcodebuild"
  marker="$temporary/xcode-ran"
  seed="$temporary/seed.xctestrun"
  python3 - "$seed" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as stream:
    plistlib.dump(
        {"VPlayerTests": {"BlueprintName": "VPlayerTests", "EnvironmentVariables": {}}},
        stream,
    )
PY
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ${1:-} == build-for-testing ]]; then' \
    '  derived=' \
    '  previous=' \
    '  for argument in "$@"; do' \
    '    if [[ "$previous" == -derivedDataPath ]]; then derived=$argument; break; fi' \
    '    previous=$argument' \
    '  done' \
    '  [[ -n "$derived" ]]' \
    '  mkdir -p "$derived/Build/Products"' \
    '  cp "${VPLAYER_RUNNER_TEST_XCTESTRUN_SEED:?}" "$derived/Build/Products/Fake.xctestrun"' \
    '  exit 0' \
    'fi' \
    '[[ ${1:-} == test-without-building ]]' \
    ': "${VPLAYER_FIXTURE_BASE_URL:?}"' \
    'curl --fail --silent --show-error --head "$VPLAYER_FIXTURE_BASE_URL/SHA256SUMS" >/dev/null' \
    ': > "${VPLAYER_RUNNER_TEST_XCODE_MARKER:?}"' \
    'exit "${VPLAYER_RUNNER_TEST_XCODE_STATUS:-0}"' > "$fake_xcode"
  chmod 700 "$fake_xcode"

  set +e
  VPLAYER_RUNNER_SELF_TEST_CHILD=1 \
  VPLAYER_RUNNER_FIXTURE_ROOT="$fixture_root" \
  VPLAYER_RUNNER_TEMP_PARENT="$temp_parent" \
  VPLAYER_RUNNER_XCODEBUILD="$fake_xcode" \
  VPLAYER_RUNNER_TEST_XCTESTRUN_SEED="$seed" \
  VPLAYER_RUNNER_TEST_XCODE_MARKER="$marker" \
  VPLAYER_RUNNER_TEST_XCODE_STATUS=42 \
    "$script"
  status=$?
  set -e
  [[ $status -eq 42 ]] || self_test_fail "xcodebuild status was not preserved (got $status)"
  [[ -f "$marker" ]] || self_test_fail 'xcodebuild failure probe did not run'
  assert_self_test_cleanup "$root" "$fixture_root" "$temp_parent"

  rm -f "$marker"
  VPLAYER_RUNNER_SELF_TEST_CHILD=1 \
  VPLAYER_RUNNER_FIXTURE_ROOT="$fixture_root" \
  VPLAYER_RUNNER_TEMP_PARENT="$temp_parent" \
  VPLAYER_RUNNER_XCODEBUILD="$fake_xcode" \
  VPLAYER_RUNNER_TEST_XCTESTRUN_SEED="$seed" \
  VPLAYER_RUNNER_TEST_XCODE_MARKER="$marker" \
  VPLAYER_RUNNER_TEST_XCODE_STATUS=0 \
    "$script"
  [[ -f "$marker" ]] || self_test_fail 'xcodebuild success probe did not run'
  assert_self_test_cleanup "$root" "$fixture_root" "$temp_parent"

  rm -f "$marker"
  set +e
  VPLAYER_RUNNER_SELF_TEST_CHILD=1 \
  VPLAYER_RUNNER_FIXTURE_ROOT="$fixture_root" \
  VPLAYER_RUNNER_TEMP_PARENT="$temp_parent" \
  VPLAYER_RUNNER_FIXTURE_SERVER=/usr/bin/false \
  VPLAYER_RUNNER_XCODEBUILD="$fake_xcode" \
  VPLAYER_RUNNER_TEST_XCTESTRUN_SEED="$seed" \
  VPLAYER_RUNNER_TEST_XCODE_MARKER="$marker" \
    "$script"
  status=$?
  set -e
  [[ $status -ne 0 ]] || self_test_fail 'readiness failure unexpectedly succeeded'
  [[ ! -e "$marker" ]] || self_test_fail 'xcodebuild ran after readiness failure'
  assert_self_test_cleanup "$root" "$fixture_root" "$temp_parent"

  for signal_name in TERM INT; do
    rm -f "$marker"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      ': > "${VPLAYER_RUNNER_TEST_XCODE_MARKER:?}"' \
      'trap "exit 0" INT TERM' \
      'while :; do sleep 1; done' > "$fake_xcode"
    chmod 700 "$fake_xcode"
    if [[ "$signal_name" == TERM ]]; then expected=143; else expected=130; fi
    VPLAYER_RUNNER_SELF_TEST_CHILD=1 \
    VPLAYER_RUNNER_FIXTURE_ROOT="$fixture_root" \
    VPLAYER_RUNNER_TEMP_PARENT="$temp_parent" \
    VPLAYER_RUNNER_XCODEBUILD="$fake_xcode" \
    VPLAYER_RUNNER_TEST_XCODE_MARKER="$marker" \
      python3 - "$script" "$marker" "$signal_name" "$expected" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, marker, signal_name, expected_text = sys.argv[1:]
process = subprocess.Popen([script], env=os.environ.copy())
try:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not Path(marker).exists():
        if process.poll() is not None:
            raise SystemExit(f"runner exited before {signal_name} probe readiness")
        time.sleep(0.02)
    if not Path(marker).exists():
        raise SystemExit(f"runner never reached xcodebuild for {signal_name} probe")
    process.send_signal(getattr(signal, f"SIG{signal_name}"))
    status = process.wait(timeout=10)
    expected = int(expected_text)
    if status != expected:
        raise SystemExit(f"{signal_name} status was {status}, expected {expected}")
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
PY
    assert_self_test_cleanup "$root" "$fixture_root" "$temp_parent"
  done

  printf 'runner self-tests passed\n'
}

wait_for_path() {
  local path=$1 timeout_seconds=$2 count=0
  while [[ ! -e "$path" && $count -lt $((timeout_seconds * 50)) ]]; do
    sleep 0.02
    count=$((count + 1))
  done
  [[ -e "$path" ]]
}

assert_self_test_cleanup() {
  local root=$1 fixture_root=$2 temp_parent=$3
  if find "$temp_parent" -mindepth 1 -print -quit | grep -q .; then
    self_test_fail 'temporary port file remained'
  fi
  if pgrep -f "$root/Scripts/Support/fixture_server.py --root $fixture_root" >/dev/null; then
    self_test_fail 'exact workspace fixture server remained'
  fi
}

fail() {
  printf 'playback integration runner: %s\n' "$1" >&2
  exit 1
}

workspace_server_pids() {
  ps -axo pid=,command= | awk -v server="$server_script" -v fixtures="$fixture_root" '
    index($0, server) && index($0, "--root " fixtures) { print $1 }
  '
}

assert_no_workspace_server() {
  local pids
  pids="$(workspace_server_pids)"
  [[ -z "$pids" ]] || fail "fixture server already associated with this workspace: $pids"
}

assert_no_web_output() {
  local found
  found="$(find "$root" \
    \( -path "$root/.git" -o -path "$root/Vendor/FFmpeg/Work" -o -path "$root/Vendor/FFmpeg/Artifacts" \) -prune -o \
    \( -type f \( -iname '*.html' -o -iname '*.htm' \) -o \
       -type d \( -iname web -o -iname www -o -iname htdocs \) \) \
    -print -quit)"
  [[ -z "$found" ]] || fail "unauthorized web output exists: $found"
}

stop_exact_pid() {
  local pid=${1:-}
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$? cleanup_failed=0 remaining
  trap - EXIT INT TERM
  stop_exact_pid "$test_pid"
  stop_exact_pid "$server_pid"
  if [[ -n "$port_file" ]]; then
    rm -f -- "$port_file"
  fi
  if [[ -n "$test_artifacts" && -d "$test_artifacts" ]]; then
    rm -rf -- "$test_artifacts"
  fi
  remaining="$(workspace_server_pids)"
  if [[ -n "$remaining" ]]; then
    printf 'playback integration runner: fixture server remained after cleanup: %s\n' "$remaining" >&2
    cleanup_failed=1
  fi
  if ! assert_no_web_output; then
    cleanup_failed=1
  fi
  if [[ $status -eq 0 && $cleanup_failed -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}

handle_signal() {
  local status=$1
  stop_exact_pid "$test_pid"
  test_pid=''
  exit "$status"
}

read_valid_port() {
  local line_count byte_count candidate
  [[ -s "$port_file" ]] || return 1
  line_count="$(LC_ALL=C wc -l < "$port_file" | tr -d ' ')"
  candidate="$(LC_ALL=C tr -d '\n' < "$port_file")"
  byte_count="$(LC_ALL=C wc -c < "$port_file" | tr -d ' ')"
  [[ "$line_count" == 1 ]] || return 1
  [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$byte_count" -eq $((${#candidate} + 1)) ]] || return 1
  (( candidate >= 1 && candidate <= 65535 )) || return 1
  port=$candidate
}

wait_for_server() {
  local attempts=0
  while (( attempts < 250 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      return 1
    fi
    if read_valid_port && curl --fail --silent --show-error --head \
      "http://127.0.0.1:$port/SHA256SUMS" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

if [[ ${1:-} == --self-test ]]; then
  run_self_tests
  exit 0
fi

[[ $# -eq 0 ]] || fail "unexpected argument: $1"

root="$(cd "$(dirname "$0")/.." && pwd -P)"
server_script="$root/Scripts/Support/fixture_server.py"
fixture_root="$root/Tests/VPlayerTests/Fixtures/Media"
temp_parent="${TMPDIR:-/tmp}"
xcodebuild_command=xcodebuild

if [[ ${VPLAYER_RUNNER_SELF_TEST_CHILD:-0} == 1 ]]; then
  fixture_root="${VPLAYER_RUNNER_FIXTURE_ROOT:?self-test fixture root is required}"
  temp_parent="${VPLAYER_RUNNER_TEMP_PARENT:?self-test temp parent is required}"
  server_script="${VPLAYER_RUNNER_FIXTURE_SERVER:-$server_script}"
  xcodebuild_command="${VPLAYER_RUNNER_XCODEBUILD:?self-test xcodebuild is required}"
else
  [[ -z ${VPLAYER_RUNNER_FIXTURE_ROOT+x} ]] || fail 'fixture root override is test-only'
  [[ -z ${VPLAYER_RUNNER_TEMP_PARENT+x} ]] || fail 'temporary parent override is test-only'
  [[ -z ${VPLAYER_RUNNER_FIXTURE_SERVER+x} ]] || fail 'fixture server override is test-only'
  [[ -z ${VPLAYER_RUNNER_XCODEBUILD+x} ]] || fail 'xcodebuild override is test-only'
  "$root/Scripts/generate-playback-fixtures.sh" --verify
fi

[[ -d "$fixture_root" ]] || fail "fixture root is missing: $fixture_root"
[[ -f "$fixture_root/SHA256SUMS" ]] || fail 'fixture checksum manifest is missing'
[[ -x "$server_script" ]] || fail "fixture server is not executable: $server_script"
[[ -d "$temp_parent" && -w "$temp_parent" ]] || fail "temporary parent is not writable: $temp_parent"
command -v "$xcodebuild_command" >/dev/null 2>&1 || fail "xcodebuild command is unavailable: $xcodebuild_command"
command -v curl >/dev/null 2>&1 || fail 'curl is required'

assert_no_web_output
assert_no_workspace_server

port_file=''
server_pid=''
test_pid=''
port=''
test_artifacts=''
trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

port_file="$(mktemp "$temp_parent/vplayer-fixture-port.XXXXXX")"
"$server_script" --root "$fixture_root" --port-file "$port_file" &
server_pid=$!
[[ "$server_pid" =~ ^[1-9][0-9]*$ ]] || fail 'invalid fixture server PID'

wait_for_server || fail 'fixture server failed readiness or wrote an invalid port file'

destination="${TVOS_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
code_signing_allowed=NO
if [[ "$destination" == platform=tvOS,id=* ]]; then
  code_signing_allowed=YES
fi
test_artifacts="$(mktemp -d "$temp_parent/vplayer-integration-derived.XXXXXX")"

"$xcodebuild_command" build-for-testing \
    -project "$root/VPlayer.xcodeproj" \
    -scheme VPlayer \
    -destination "$destination" \
    -derivedDataPath "$test_artifacts" \
    CODE_SIGNING_ALLOWED="$code_signing_allowed" &
test_pid=$!

set +e
wait "$test_pid"
build_status=$?
set -e
test_pid=''
[[ $build_status -eq 0 ]] || exit "$build_status"

xctestrun_files=()
while IFS= read -r -d '' xctestrun_file; do
  xctestrun_files+=("$xctestrun_file")
done < <(find "$test_artifacts/Build/Products" -name '*.xctestrun' -type f -print0)
[[ ${#xctestrun_files[@]} -eq 1 ]] || \
  fail "expected one xctestrun file, found ${#xctestrun_files[@]}"
xctestrun_file="${xctestrun_files[0]}"

python3 - "$xctestrun_file" "http://127.0.0.1:$port" <<'PY'
import plistlib
import sys

path, base_url = sys.argv[1:]
with open(path, "rb") as stream:
    document = plistlib.load(stream)
targets = [
    value
    for key, value in document.items()
    if key != "__xctestrun_metadata__"
    and isinstance(value, dict)
    and value.get("BlueprintName") == "VPlayerTests"
]
if len(targets) != 1:
    raise SystemExit(f"expected one VPlayerTests xctestrun target, found {len(targets)}")
environment = targets[0].setdefault("EnvironmentVariables", {})
environment["VPLAYER_FIXTURE_BASE_URL"] = base_url
with open(path, "wb") as stream:
    plistlib.dump(document, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
PY

VPLAYER_FIXTURE_BASE_URL="http://127.0.0.1:$port" \
  "$xcodebuild_command" test-without-building \
    -xctestrun "$xctestrun_file" \
    -destination "$destination" \
    -resultBundlePath "$test_artifacts/PlaybackIntegration.xcresult" \
    -only-testing:VPlayerTests/PlaybackFixtureIntegrationTests &
test_pid=$!

set +e
wait "$test_pid"
test_status=$?
set -e
test_pid=''
if [[ $test_status -ne 0 && -d "$test_artifacts/PlaybackIntegration.xcresult" ]] && \
   command -v xcrun >/dev/null 2>&1; then
  xcrun xcresulttool get test-results summary \
    --path "$test_artifacts/PlaybackIntegration.xcresult" \
    --format json || true
fi
exit "$test_status"
