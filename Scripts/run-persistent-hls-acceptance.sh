#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
head='' duration=300 role=candidate baseline='' ineligible='' output='' overlay='' controls=false
while (($#)); do
  case "$1" in
    --head) head="${2:?}"; shift 2;;
    --duration-seconds) duration="${2:?}"; shift 2;;
    --baseline) baseline="${2:?}"; shift 2;;
    --ineligible-baseline) ineligible="${2:?}"; shift 2;;
    --output) output="${2:?}"; shift 2;;
    --record-baseline) role=baseline; shift;;
    --controls-only) controls=true; shift;;
    --overlay-sha256) overlay="${2:?}"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 64;;
  esac
done
[[ -z "$ineligible" || ( "$role" == candidate && "$controls" == false && -z "$baseline" ) ]] || {
  echo 'Reviewed ineligibility is candidate-only and mutually exclusive with a measured baseline or controls.' >&2; exit 64; }
# A shorter diagnostic is not silently relabelled five-minute acceptance.
[[ "$duration" == 300 ]] || { echo 'FiveMinute requires 300 seconds; playback may never exceed 300.' >&2; exit 64; }
[[ "$head" =~ ^[0-9a-f]{40}$ && "$(git rev-parse HEAD)" == "$head" ]] || { echo 'Exact checked-out --head SHA required.' >&2; exit 1; }
[[ -n "$output" && ! -e "$output" ]] || { echo 'An unused --output report path is required.' >&2; exit 64; }
if [[ "$role" == candidate ]]; then
  git diff --exit-code HEAD -- Sources Tests project.yml VPlayer.xcodeproj VPlayerHLSAcceptance.xctestplan Scripts
  if [[ "$controls" == false ]]; then
    if [[ -n "$ineligible" ]]; then
      [[ -z "$baseline" && -s "$ineligible" ]] || { echo 'Exactly one frozen reference decision required.' >&2; exit 1; }
      baseline_hash="$(shasum -a 256 "$ineligible" | awk '{print $1}')"
    else
      [[ -s "$baseline" ]] || { echo 'A valid frozen baseline or exact reviewed ineligibility is required.' >&2; exit 1; }
      baseline_hash="$(shasum -a 256 "$baseline" | awk '{print $1}')"
    fi
  fi
else
  [[ -z "$ineligible" ]] || { echo 'Baseline recording cannot use candidate-only eligibility.' >&2; exit 64; }
  [[ "$controls" == false ]] || { echo "Short controls require candidate production diagnostics." >&2; exit 64; }
  [[ "$head" == 36f9f00044db05b707e25ea470b0da3cec62682c && "$overlay" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'Baseline requires approved exact old-writer head and allowlisted test overlay hash.' >&2; exit 1; }
  git diff --exit-code HEAD -- Sources Vendor ci_scripts
fi
[[ "$(uname -s)" == Darwin ]] || { echo 'Native acceptance requires Apple; portable controls do not replace it.' >&2; exit 1; }
xcode_version="$(xcodebuild -version)"
test "${xcode_version%%$'\n'*}" = 'Xcode 27.0'
test "$(xcrun --sdk appletvsimulator --show-sdk-version)" = '27.0'
./Scripts/bootstrap.sh --check
fixture=Tests/Fixtures/HLSAcceptance/persistent-360s.ts
test -s "$fixture"
fixture_hash="$(shasum -a 256 "$fixture" | awk '{print $1}')"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hls-acceptance.XXXXXX")"
# Keep bounded local diagnostic outputs on failure; no automatic artifact upload.
echo "HLS_ACCEPTANCE_DIAGNOSTICS=$work"
if [[ -n "$ineligible" ]]; then
  python3 Scripts/Support/persistent_hls_acceptance.py check-ineligible "$ineligible" \
    --head "$head" --fixture "$fixture" --output "$work/ineligible-preflight.json"
fi
derived="${VPLAYER_HLS_ACCEPTANCE_DERIVED_DATA:-$work/DerivedData}"
selector=VPlayerHLSAcceptanceTests/PersistentHLSAcceptanceTests/testFiveMinuteOriginalNativePlaybackAndRetirement
allowance=480
if [[ "$controls" == true ]]; then
  selector=VPlayerHLSAcceptanceTests/AcceptanceNativeControlTests/testNativeObservationControlsRejectFiveFaults
  allowance=120
fi
flags='$(inherited) DEBUG'
[[ "$role" != baseline ]] || flags="$flags HLS_ACCEPTANCE_BASELINE"
xcodebuild build-for-testing -project VPlayer.xcodeproj -scheme VPlayerHLSAcceptance \
  -testPlan VPlayerHLSAcceptance -only-test-configuration FiveMinute -configuration Debug \
  -destination "${TVOS_TEST_DESTINATION:?Exact simulator/device destination required}" \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$flags"
xctestrun="$(python3 Scripts/Support/configure-hls-acceptance.py "$derived" \
  "$head" "$(git rev-parse HEAD^{tree})" "$fixture_hash" "$role" "$overlay")"
# XCTest allowance includes preparation, decode and retirement. The native monotonic
# watchdog stops source + AVPlayer at 299.5 s INCLUDING prebuffer. Actual player
# wall duration and media clock advance are separately measured, never inflated.
set +e
xcodebuild test-without-building -xctestrun "$xctestrun" \
  -only-test-configuration FiveMinute -only-testing:"$selector" -destination "$TVOS_TEST_DESTINATION" \
  -resultBundlePath "$work/Acceptance.xcresult" -parallel-testing-enabled NO \
  -collect-test-diagnostics never -test-timeouts-enabled YES \
  -default-test-execution-time-allowance "$allowance" -maximum-test-execution-time-allowance "$allowance" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$work/native.log"
status=${PIPESTATUS[0]}
set -e
python3 Scripts/report-xcresult-failures.py "$work/Acceptance.xcresult"
((status == 0)) || exit "$status"
if [[ "$controls" == true ]]; then
  python3 Scripts/Support/persistent_hls_acceptance.py controls "$work/native.log" --output "$output"
  [[ "$(git rev-parse HEAD)" == "$head" ]]
  git diff --exit-code HEAD -- Sources Tests Scripts project.yml VPlayer.xcodeproj VPlayerHLSAcceptance.xctestplan
  exit 0
fi
python3 Scripts/Support/persistent_hls_acceptance.py extract "$work/native.log" --output "$output"
python3 - "$output" "$head" "$(git rev-parse HEAD^{tree})" "$fixture_hash" "$role" <<'PYVERIFY'
import json,sys
path,head,tree,fixture,role=sys.argv[1:]
report=json.load(open(path))
assert (report['head'],report['tree'],report['fixture_sha256'],report['role'])==(head,tree,fixture,role), 'Native provenance does not match checkout'
PYVERIFY
[[ "$(git rev-parse HEAD)" == "$head" ]]
git diff --exit-code HEAD -- Sources Vendor ci_scripts
if [[ "$role" == candidate ]]; then
  git diff --exit-code HEAD -- Tests project.yml VPlayer.xcodeproj VPlayerHLSAcceptance.xctestplan Scripts
  if [[ -n "$ineligible" ]]; then
    [[ "$(shasum -a 256 "$ineligible" | awk '{print $1}')" == "$baseline_hash" ]] || { echo 'Frozen ineligibility/policy changed during candidate.' >&2; exit 1; }
    python3 Scripts/Support/persistent_hls_acceptance.py validate-absolute "$output" \
      --baseline "$ineligible" --output "$output.verdict.json"
  else
    [[ "$(shasum -a 256 "$baseline" | awk '{print $1}')" == "$baseline_hash" ]] || { echo 'Frozen baseline changed during candidate.' >&2; exit 1; }
    python3 Scripts/Support/persistent_hls_acceptance.py validate "$output" --baseline "$baseline" --output "$output.verdict.json"
  fi
fi
