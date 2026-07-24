#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-acceptance-development-team.sh
source "$script_dir/resolve-acceptance-development-team.sh"

child_pid=""
received_signal=""

abort_if_signaled() {
    [[ -z "$received_signal" ]] && return
    if [[ -n "${run_directory:-}" ]]; then
        echo "acceptance interrupted; partial artifacts remain at: $run_directory" >&2
    else
        echo "acceptance interrupted before launch" >&2
    fi
    exit 130
}

forward_signal() {
    local signal="$1"
    received_signal="$signal"
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -"$signal" -- "-$child_pid" 2>/dev/null \
            || kill -"$signal" "$child_pid" 2>/dev/null \
            || true
    elif [[ -z "$child_pid" ]]; then
        abort_if_signaled
    fi
}

wait_for_child() {
    local status=0
    set +e
    while true; do
        wait "$child_pid"
        status=$?
        if [[ -n "$received_signal" ]] && kill -0 "$child_pid" 2>/dev/null; then
            continue
        fi
        break
    done
    set -e
    if [[ -n "$received_signal" ]]; then
        return 130
    fi
    return "$status"
}

trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP

if [[ "${VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_MODE:-0}" == "1" ]]; then
    preflight_ready_file="${VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_READY_FILE:?preflight ready file required}"
    preflight_launch_file="${VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_LAUNCH_FILE:?preflight launch file required}"
    printf 'ready\n' >"$preflight_ready_file"
    while [[ -z "$received_signal" ]]; do
        sleep 0.05 || true
    done
    abort_if_signaled
    printf 'launched\n' >"$preflight_launch_file"
    exit 1
fi

if [[ "${VPLAYER_ACCEPTANCE_SIGNAL_TEST_MODE:-0}" == "1" ]]; then
    signal_pid_file="${VPLAYER_ACCEPTANCE_SIGNAL_TEST_PID_FILE:?signal-test PID file required}"
    set -m
    bash -c 'trap "exit 0" INT TERM HUP; while true; do sleep 1; done' &
    child_pid=$!
    printf '%s\n' "$child_pid" >"$signal_pid_file"
    set +e
    wait_for_child
    test_status=$?
    set -e
    exit "$test_status"
fi

usage() {
    echo "usage: $0 DEVICE_UDID {appleTemporal|metalYADIF2x} CHANNEL POSITIVE_SECONDS [M3U_URL] [EPG_URL]" >&2
}

if (( $# < 4 || $# > 6 )); then
    usage
    exit 64
fi

device_udid="$1"
algorithm="$2"
channel="$3"
duration="$4"
m3u_url="${5:-https://example.invalid/playlist.m3u}"
epg_url="${6:-https://example.invalid/epg.xml}"

case "$algorithm" in
    appleTemporal|metalYADIF2x) ;;
    *)
        echo "algorithm must be appleTemporal or metalYADIF2x" >&2
        exit 64
        ;;
esac

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    echo "duration must be a positive integer number of seconds" >&2
    exit 64
fi

if [[ ! "$m3u_url" =~ ^https?:// ]]; then
    echo "M3U source must use HTTP or HTTPS" >&2
    exit 64
fi
if [[ ! "$epg_url" =~ ^https?:// ]]; then
    echo "EPG source must use HTTP or HTTPS" >&2
    exit 64
fi

device_details="$(xcrun devicectl device info details --device "$device_udid" 2>&1)" || {
    echo "device UDID is not available to CoreDevice" >&2
    exit 69
}
if ! rg -q 'productType: AppleTV14,1' <<<"$device_details"; then
    echo "device must resolve to AppleTV14,1 (Apple TV 4K 3rd generation)" >&2
    exit 69
fi
destination_udid="$(
    sed -nE 's/^[[:space:]]*• udid: ([A-Fa-f0-9-]+)$/\1/p' \
        <<<"$device_details" | sed -n '1p'
)"
if [[ -z "$destination_udid" ]]; then
    echo "device does not expose an xcodebuild destination UDID" >&2
    exit 69
fi

development_team="${VPLAYER_DEVELOPMENT_TEAM:-}"
if [[ -z "$development_team" ]]; then
    signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    signing_certificates="$(
        security find-certificate -a -Z -p -c "Apple Development:" 2>/dev/null \
            || true
    )"
    development_team="$(
        resolve_acceptance_development_team \
            "$signing_identities" \
            "$signing_certificates" \
            || true
    )"
fi
if [[ ! "$development_team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "a valid Apple Development team is required for device signing" >&2
    exit 69
fi

repository_root="$(cd "$script_dir/.." && pwd)"
artifact_root="${VPLAYER_ACCEPTANCE_ARTIFACT_ROOT:-$repository_root/.superpowers/acceptance}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-${algorithm}-$$"
run_directory="$artifact_root/$run_id"
derived_data="$run_directory/DerivedData"
result_bundle="$run_directory/acceptance.xcresult"
console_log="$run_directory/xcodebuild.log"
acceptance_xcconfig="$run_directory/acceptance.xcconfig"
umask 077
mkdir -p "$run_directory"

encode_build_setting() {
    printf '%s' "$1" | base64 | tr -d '\n'
}
{
    printf 'VPLAYER_ACCEPTANCE_M3U_URL_B64 = %s\n' "$(encode_build_setting "$m3u_url")"
    printf 'VPLAYER_ACCEPTANCE_EPG_URL_B64 = %s\n' "$(encode_build_setting "$epg_url")"
    printf 'VPLAYER_ACCEPTANCE_CHANNEL_B64 = %s\n' "$(encode_build_setting "$channel")"
    printf 'VPLAYER_ACCEPTANCE_SECONDS_B64 = %s\n' "$(encode_build_setting "$duration")"
    printf 'VPLAYER_ACCEPTANCE_ALGORITHM_B64 = %s\n' "$(encode_build_setting "$algorithm")"
} >"$acceptance_xcconfig"

echo "running device acceptance on verified AppleTV14,1; artifacts: $run_directory"
abort_if_signaled
set -m
xcodebuild test \
    -project "$repository_root/VPlayer.xcodeproj" \
    -scheme VPlayer \
    -configuration Debug \
    -xcconfig "$acceptance_xcconfig" \
    -destination "platform=tvOS,id=$destination_udid" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -parallel-testing-enabled NO \
    -allowProvisioningUpdates \
    -only-testing:VPlayerUITests/LongPlaybackAcceptanceTests/testLongRunningRealDevicePlayback \
    DEVELOPMENT_TEAM="$development_team" >"$console_log" 2>&1 &
child_pid=$!
set +e
wait_for_child
status=$?
set -e

privacy_violation=0
if rg -a -F -q -- "$m3u_url" "$console_log"; then
    privacy_violation=1
elif [[ -e "$result_bundle" ]] && rg -a -F -q -- "$m3u_url" "$result_bundle"; then
    privacy_violation=1
elif rg -a -F -q -- "$epg_url" "$console_log"; then
    privacy_violation=1
elif [[ -e "$result_bundle" ]] && rg -a -F -q -- "$epg_url" "$result_bundle"; then
    privacy_violation=1
fi
if (( privacy_violation != 0 )); then
    echo "acceptance privacy scan failed; protected artifacts retained without console replay" >&2
    exit 78
fi

sed -n '1,$p' "$console_log"
if [[ -n "$received_signal" ]]; then
    echo "acceptance interrupted; partial artifacts remain at: $run_directory" >&2
    exit 130
fi
if (( status != 0 )); then
    echo "acceptance failed; artifacts retained at: $run_directory" >&2
    exit "$status"
fi

echo "acceptance succeeded; result bundle: $result_bundle"
