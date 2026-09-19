#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=resolve-acceptance-development-team.sh
source "$script_dir/resolve-acceptance-development-team.sh"

child_pid=""
server_pid=""
port_file=""
received_signal=""

cleanup_fixture_server() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
    if [[ -n "$port_file" && -e "$port_file" ]]; then
        rm -f "$port_file"
        port_file=""
    fi
}

abort_if_signaled() {
    [[ -z "$received_signal" ]] && return
    cleanup_fixture_server
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
    cleanup_fixture_server
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
trap cleanup_fixture_server EXIT

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
    echo "usage: $0 [--airplay] [--long-playback] [--spawn-fixture-server] [--fixture-server URL] [--fixture-root DIR] [--output-dir DIR] DEVICE_UDID CHANNEL [POSITIVE_SECONDS] [M3U_URL] [EPG_URL]" >&2
}

airplay_mode=0
long_playback_mode=0
spawn_fixture_server=0
fixture_server_url=""
fixture_root=""
output_dir=""
positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --airplay)
            airplay_mode=1
            shift
            ;;
        --long-playback)
            long_playback_mode=1
            shift
            ;;
        --spawn-fixture-server)
            spawn_fixture_server=1
            shift
            ;;
        --fixture-server)
            [[ $# -ge 2 ]] || { echo "option $1 requires an argument" >&2; exit 64; }
            fixture_server_url="$2"
            shift 2
            ;;
        --fixture-root)
            [[ $# -ge 2 ]] || { echo "option $1 requires an argument" >&2; exit 64; }
            fixture_root="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "option $1 requires an argument" >&2; exit 64; }
            output_dir="$2"
            shift 2
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                positional+=("$1")
                shift
            done
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            exit 64
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if (( long_playback_mode != 0 )); then
    if (( ${#positional[@]} < 2 || ${#positional[@]} > 5 )); then
        usage
        exit 64
    fi
    device_udid="${positional[0]}"
    channel="${positional[1]}"
    duration="${positional[2]:-7200}"
    m3u_url="${positional[3]:-${fixture_server_url:-https://example.invalid/playlist.m3u}}"
    epg_url="${positional[4]:-https://example.invalid/epg.xml}"
else
    if (( ${#positional[@]} < 3 || ${#positional[@]} > 5 )); then
        usage
        exit 64
    fi
    device_udid="${positional[0]}"
    channel="${positional[1]}"
    duration="${positional[2]}"
    m3u_url="${positional[3]:-${fixture_server_url:-https://example.invalid/playlist.m3u}}"
    epg_url="${positional[4]:-https://example.invalid/epg.xml}"
fi

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    echo "duration must be a positive integer number of seconds" >&2
    exit 64
fi

if (( spawn_fixture_server != 0 )); then
    fixture_root="${fixture_root:-$repository_root/Tests/VPlayerTests/Fixtures/Media}"
    server_script="$repository_root/Scripts/Support/fixture_server.py"
    if [[ ! -x "$server_script" ]]; then
        echo "fixture server script not found or not executable: $server_script" >&2
        exit 69
    fi
    if [[ ! -d "$fixture_root" ]]; then
        echo "fixture root directory not found: $fixture_root" >&2
        exit 69
    fi
    port_file="$(mktemp "${TMPDIR:-/tmp}/vplayer-fixture-port.XXXXXX")"
    "$server_script" --root "$fixture_root" --port-file "$port_file" &
    server_pid=$!

    port=""
    for _ in $(seq 1 250); do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "fixture server terminated unexpectedly" >&2
            exit 69
        fi
        if [[ -s "$port_file" ]]; then
            candidate="$(tr -d '[:space:]' <"$port_file")"
            if [[ "$candidate" =~ ^[1-9][0-9]*$ ]] && curl --fail --silent --show-error --head "http://127.0.0.1:$candidate/SHA256SUMS" >/dev/null 2>&1; then
                port="$candidate"
                break
            fi
        fi
        sleep 0.02
    done
    if [[ -z "$port" ]]; then
        echo "fixture server failed to bind or verify readiness on loopback" >&2
        cleanup_fixture_server
        exit 69
    fi
    if [[ "$m3u_url" == "https://example.invalid/playlist.m3u" || -z "$m3u_url" ]]; then
        m3u_url="http://127.0.0.1:$port/playlist.m3u"
    fi
    if [[ "$epg_url" == "https://example.invalid/epg.xml" || -z "$epg_url" ]]; then
        epg_url="http://127.0.0.1:$port/epg.xml"
    fi
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
    sed -nE 's/^[[:space:]]*[^[:alnum:]]*[[:space:]]*udid:[[:space:]]*([A-Fa-f0-9-]+)$/\1/p' \
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
artifact_root="${output_dir:-${VPLAYER_ACCEPTANCE_ARTIFACT_ROOT:-$repository_root/.superpowers/acceptance}}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
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
    if (( airplay_mode != 0 )); then
        printf 'VPLAYER_ACCEPTANCE_AIRPLAY_B64 = %s\n' "$(encode_build_setting "1")"
    fi
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
(
    while kill -0 "$child_pid" 2>/dev/null; do
        pkill -f "devicectl diagnose" 2>/dev/null || true
        sleep 1
    done
) &
diagnose_watchdog_pid=$!
set +e
wait_for_child
status=$?
set -e
kill "$diagnose_watchdog_pid" 2>/dev/null || true
wait "$diagnose_watchdog_pid" 2>/dev/null || true

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

for target_url in "$m3u_url" "$epg_url"; do
    if [[ "$target_url" == *\?* ]]; then
        query_part="${target_url#*\?}"
        if [[ -n "$query_part" ]]; then
            if rg -a -F -q -- "$query_part" "$console_log" || { [[ -e "$result_bundle" ]] && rg -a -F -q -- "$query_part" "$result_bundle"; }; then
                privacy_violation=1
            fi
        fi
    fi
done

if (( privacy_violation != 0 )); then
    cleanup_fixture_server
    echo "acceptance privacy scan failed; protected artifacts retained without console replay" >&2
    exit 78
fi

sed -n '1,$p' "$console_log"
if [[ -n "$received_signal" ]]; then
    cleanup_fixture_server
    echo "acceptance interrupted; partial artifacts remain at: $run_directory" >&2
    exit 130
fi
if (( status != 0 )); then
    cleanup_fixture_server
    echo "acceptance failed; artifacts retained at: $run_directory" >&2
    exit "$status"
fi

cleanup_fixture_server
echo "acceptance succeeded; result bundle: $result_bundle"
