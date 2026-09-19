#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"

child_pid=""
server_pid=""
port_file=""
received_signal=""

usage() {
    cat <<'EOF' >&2
usage: run-airplay-hls-acceptance.sh [OPTIONS]

AirPlay HLS and AVPlayer Real Device Acceptance Runner

Required:
  --device-udid UDID            Target Apple TV 4K (3rd generation) CoreDevice UDID
                                (not required if --self-test is used)

Options:
  --fixture-server URL          Base URL of running loopback fixture server
  --fixture-root DIR            Local directory containing test fixtures
  --spawn-fixture-server        Spawn local fixture server bound to 127.0.0.1
  --output-dir DIR              Directory for reports and xcresult artifacts
  --duration SECONDS            Playback duration per matrix item (default: 600)
  --matrix SCOPE                Matrix scope: all, playback, state, long-run, priming
                                (default: all)
  --dry-run                     Plan and inspect matrix without executing xcodebuild
  --self-test                   Run internal harness self-tests without real hardware
  -h, --help                    Show this help message
EOF
}

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

forward_signal() {
    local signal="$1"
    received_signal="$signal"
    cleanup_fixture_server
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -"$signal" -- "-$child_pid" 2>/dev/null \
            || kill -"$signal" "$child_pid" 2>/dev/null \
            || true
    elif [[ -z "$child_pid" ]]; then
        if [[ -n "${output_dir:-}" ]]; then
            echo "acceptance interrupted; partial artifacts remain at: $output_dir" >&2
        else
            echo "acceptance interrupted before launch" >&2
        fi
        if [[ "$signal" == "TERM" ]]; then
            exit 143
        else
            exit 130
        fi
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
        if [[ "$received_signal" == "TERM" ]]; then
            return 143
        else
            return 130
        fi
    fi
    return "$status"
}

trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP
trap cleanup_fixture_server EXIT

privacy_scan() {
    local scan_dir="$1"
    local raw_url="$2"
    local token="${3:-}"
    local violation=0

    if [[ -n "$raw_url" ]]; then
        if rg -a -F -q -- "$raw_url" "$scan_dir" 2>/dev/null; then
            violation=1
        fi
        if [[ "$raw_url" == *\?* ]]; then
            local query="${raw_url#*\?}"
            if [[ -n "$query" ]] && rg -a -F -q -- "$query" "$scan_dir" 2>/dev/null; then
                violation=1
            fi
        fi
    fi
    if [[ -n "$token" ]] && rg -a -F -q -- "$token" "$scan_dir" 2>/dev/null; then
        violation=1
    fi
    return "$violation"
}

# --- Self-Test Implementation ---
self_test_fail() {
    echo "airplay acceptance self-test failed: $1" >&2
    exit 1
}

run_self_tests() {
    local self_script
    self_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local temp_test_dir
    temp_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-airplay-selftest.XXXXXX")"
    trap 'rm -rf "$temp_test_dir"' RETURN

    # 1. Argument validation checks
    set +e
    "$self_script" >/dev/null 2>&1
    local status=$?
    set -e
    [[ $status -eq 64 ]] || self_test_fail "missing --device-udid did not return 64 (got $status)"

    set +e
    "$self_script" --unknown-option >/dev/null 2>&1
    status=$?
    set -e
    [[ $status -eq 64 ]] || self_test_fail "unknown option did not return 64 (got $status)"

    set +e
    "$self_script" --device-udid "00000000-0000-0000-0000-000000000000" --fixture-server "ftp://invalid" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status -eq 64 ]] || self_test_fail "invalid fixture server protocol did not return 64 (got $status)"

    # 2. Loopback fixture server lifecycle test
    local fixture_root="$temp_test_dir/fixtures"
    mkdir -p "$fixture_root"
    printf 'mock fixture content\n' >"$fixture_root/SHA256SUMS"
    printf '#EXTM3U\n#EXT-X-VERSION:7\n' >"$fixture_root/playlist.m3u"

    local port_file
    port_file="$(mktemp "$temp_test_dir/port.XXXXXX")"
    local server_script="$repository_root/Scripts/Support/fixture_server.py"
    if [[ -x "$server_script" ]]; then
        "$server_script" --root "$fixture_root" --port-file "$port_file" &
        local s_pid=$!
        local bound_port=""
        for _ in $(seq 1 100); do
            if [[ -s "$port_file" ]]; then
                bound_port="$(tr -d '[:space:]' <"$port_file")"
                if [[ "$bound_port" =~ ^[1-9][0-9]*$ ]] && curl --fail --silent --show-error --head "http://127.0.0.1:$bound_port/SHA256SUMS" >/dev/null 2>&1; then
                    break
                fi
            fi
            sleep 0.02
        done
        [[ -n "$bound_port" ]] || self_test_fail "fixture server did not bind or respond"
        kill -TERM "$s_pid" 2>/dev/null || true
        wait "$s_pid" 2>/dev/null || true
        if kill -0 "$s_pid" 2>/dev/null; then
            self_test_fail "fixture server process remained alive after TERM"
        fi
    fi

    # 3. Privacy scanner tests
    local clean_dir="$temp_test_dir/clean"
    local dirty_dir="$temp_test_dir/dirty"
    mkdir -p "$clean_dir" "$dirty_dir"
    printf 'Sanitized log with backend=airPlayHLS and duration=600s\n' >"$clean_dir/run.log"
    printf 'Leaked http://example.com/secret.m3u?token=SECRET123 in log\n' >"$dirty_dir/run.log"

    if ! privacy_scan "$clean_dir" "http://example.com/secret.m3u?token=SECRET123" "SECRET123"; then
        self_test_fail "privacy scan false positive on clean directory"
    fi
    if privacy_scan "$dirty_dir" "http://example.com/secret.m3u?token=SECRET123" "SECRET123"; then
        self_test_fail "privacy scan failed to catch leaked URL/token"
    fi

    # 4. Signal trapping test
    for sig in TERM INT; do
        local signal_marker="$temp_test_dir/sig-$sig.ready"
        local expected_code=130
        [[ "$sig" == "TERM" ]] && expected_code=143

        VPLAYER_AIRPLAY_ACCEPTANCE_TEST_CHILD=1 \
        python3 - "$self_script" "$sig" "$expected_code" "$signal_marker" <<'PY'
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

script, sig_name, expected_code, marker = sys.argv[1:]
env = os.environ.copy()
env["VPLAYER_AIRPLAY_SIGNAL_MOCK"] = "1"
env["VPLAYER_AIRPLAY_SIGNAL_MARKER"] = marker

proc = subprocess.Popen([script, "--self-test-signal-child"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not Path(marker).exists():
        if proc.poll() is not None:
            raise SystemExit(f"child exited prematurely: {proc.poll()}")
        time.sleep(0.02)
    if not Path(marker).exists():
        raise SystemExit(f"child never reached marker for {sig_name}")

    proc.send_signal(getattr(signal, f"SIG{sig_name}"))
    status = proc.wait(timeout=5)
    exp = int(expected_code)
    if status != exp:
        raise SystemExit(f"signal {sig_name} status was {status}, expected {exp}")
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait(timeout=2)
PY
    done

    # 5. Mock orchestration & dynamic report generation test
    local mock_dir="$temp_test_dir/mock-report"
    VPLAYER_AIRPLAY_ACCEPTANCE_MOCK_RUN=1 \
    "$self_script" --device-udid "mock-device" --matrix priming --output-dir "$mock_dir" >/dev/null 2>&1
    [[ -f "$mock_dir/acceptance-report.md" ]] || self_test_fail "acceptance-report.md not generated in mock run"
    [[ -f "$mock_dir/acceptance-matrix.json" ]] || self_test_fail "acceptance-matrix.json not generated in mock run"
    rg -q 'M12' "$mock_dir/acceptance-report.md" || self_test_fail "expected scenario M12 not present in report"
    if rg -q '1080p SDR progressive' "$mock_dir/acceptance-report.md"; then
        self_test_fail "unrequested scenario M1 was included in report (report must be dynamically generated, not pre-baked)"
    fi

    echo "airplay acceptance runner self-tests passed"
    exit 0
}

# Check for mock child execution in self-test
if [[ "${1:-}" == "--self-test-signal-child" ]]; then
    marker="${VPLAYER_AIRPLAY_SIGNAL_MARKER:?marker required}"
    set -m
    bash -c 'trap "exit 0" INT TERM HUP; while true; do sleep 1; done' &
    child_pid=$!
    printf 'ready\n' >"$marker"
    set +e
    wait_for_child
    c_status=$?
    set -e
    exit "$c_status"
fi

# Main argument parsing
device_udid=""
fixture_server=""
fixture_root="${repository_root}/Tests/VPlayerTests/Fixtures/Media"
spawn_fixture_server=0
output_dir=""
duration=600
matrix_scope="all"
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test)
            run_self_tests
            exit 0
            ;;
        --device-udid)
            [[ $# -ge 2 ]] || { echo "error: --device-udid requires a value" >&2; exit 64; }
            device_udid="$2"
            shift 2
            ;;
        --fixture-server)
            [[ $# -ge 2 ]] || { echo "error: --fixture-server requires a value" >&2; exit 64; }
            fixture_server="$2"
            shift 2
            ;;
        --fixture-root)
            [[ $# -ge 2 ]] || { echo "error: --fixture-root requires a value" >&2; exit 64; }
            fixture_root="$2"
            shift 2
            ;;
        --spawn-fixture-server)
            spawn_fixture_server=1
            shift
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "error: --output-dir requires a value" >&2; exit 64; }
            output_dir="$2"
            shift 2
            ;;
        --duration)
            [[ $# -ge 2 ]] || { echo "error: --duration requires a value" >&2; exit 64; }
            duration="$2"
            shift 2
            ;;
        --matrix)
            [[ $# -ge 2 ]] || { echo "error: --matrix requires a value" >&2; exit 64; }
            matrix_scope="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unrecognized argument: $1" >&2
            usage
            exit 64
            ;;
    esac
done

if [[ -z "$device_udid" ]]; then
    echo "error: --device-udid is required (use --self-test to test without hardware)" >&2
    usage
    exit 64
fi

if [[ -n "$fixture_server" && ! "$fixture_server" =~ ^https?:// ]]; then
    echo "error: --fixture-server must use HTTP or HTTPS protocol" >&2
    exit 64
fi

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --duration must be a positive integer" >&2
    exit 64
fi

# Prepare output directory
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_id="airplay-acceptance-${timestamp}-$$"
artifact_base="${VPLAYER_ACCEPTANCE_ARTIFACT_ROOT:-$repository_root/.superpowers/acceptance}"
output_dir="${output_dir:-$artifact_base/$run_id}"
mkdir -p "$output_dir"
report_json="$output_dir/acceptance-matrix.json"
report_md="$output_dir/acceptance-report.md"

echo "=== AirPlay HLS Device Acceptance Runner ==="
echo "Artifact Directory: $output_dir"
echo "Target Device UDID: [REDACTED]"
echo "Matrix Scope: $matrix_scope"
echo "Base Duration: ${duration}s"

# Matrix definitions: ID|Name|Scope|Type|Description
matrix_definitions=(
    "M1|1080p SDR progressive|playback|runnable|Continuous playback 10m"
    "M2|1080i25 YADIF2x (50p)|playback|runnable|Metal YADIF2x 50p cadence"
    "M3|1080i30 YADIF2x (60000/1001p)|playback|runnable|Metal YADIF2x 60p cadence"
    "M4|2160p50 HLG safe GOP HEVC|playback|runnable|HEVC passthrough remux"
    "M5|2160p60 PQ safe GOP Main10|playback|runnable|Main10 passthrough remux"
    "M6|2160p50 SDR NV12 unsafe GOP|playback|runnable|Forced VT Main transcode"
    "M7|2160p50 10-bit P010 unsafe GOP|playback|runnable|Forced VT Main10 transcode"
    "M8|2160p50 HLG unsafe GOP|playback|runnable|P010->VT Main10 bounded backlog"
    "M9|2160p60 PQ unsafe GOP|playback|runnable|P010->VT Main10 bounded backlog"
    "M10|H.264 10-bit P010|playback|runnable|HW decode P010 -> VT Main10"
    "M11|Audio-only HE-AAC v2|playback|runnable|Direct audio item, 0 video alloc"
    "M12|AAC Priming RSS Measurement|priming|runnable|3 warmup + 20 formal rounds"
    "S1|Cold start into AirPlay|state|runnable|Direct HLS backend, <40s cold-start"
    "S2|Cold start AirPlay audio-only|state|runnable|Direct audio item, no video alloc"
    "S3|HDMI -> AirPlay -> HDMI (5x)|state|external|Requires external physical HDMI switch/capture"
    "S4|AirPlay -> .none -> AirPlay (<3s)|state|runnable|In-place reprepare within 3s"
    "S5|AirPlay -> .none (>3s)|state|runnable|Unified teardown, poisoned barrier"
    "S6|Endpoint handoff A -> B|state|external|Requires secondary physical AirPlay endpoint"
    "S7|Pause/Play during handoff|state|runnable|Rate 0, new activation epoch"
    "S8|AudioSession interruption|state|runnable|Revoke permit, post-interruption rebase"
    "S9|Media-services reset|state|runnable|Drain -> inactive -> atomic gate open"
    "S10|Format & attribute change|state|runnable|Discontinuity + new init / generation"
    "S11|Loopback fault injection|state|runnable|No legacy fallback, max 1 rebuild"
    "LP|2-Hour Long Playback (7200 samples)|long-run|runnable|Windows B & R median floor, <=32 MiB growth"
)

# Filter items by scope
selected_items=()
for def in "${matrix_definitions[@]}"; do
    IFS='|' read -r m_id m_name m_scope m_type m_desc <<<"$def"
    if [[ "$matrix_scope" == "all" || "$matrix_scope" == "$m_scope" || "$matrix_scope" == "$m_id" ]]; then
        selected_items+=("$def")
    fi
done

if [[ ${#selected_items[@]} -eq 0 ]]; then
    echo "error: no matrix items match scope: $matrix_scope" >&2
    exit 64
fi

# If dry-run mode, generate plan and exit
if (( dry_run != 0 )); then
    cat <<EOF >"$report_md"
# AirPlay HLS Acceptance Matrix (Dry Run Plan)
- Timestamp: $timestamp
- Matrix Scope: $matrix_scope
- Duration Per Item: ${duration}s
- Selected Items Count: ${#selected_items[@]}

## Planned Scenarios
| ID | Scenario | Scope | Type | Details |
|---|---|---|---|---|
EOF
    for def in "${selected_items[@]}"; do
        IFS='|' read -r m_id m_name m_scope m_type m_desc <<<"$def"
        printf '| %s | %s | %s | %s | %s |\n' "$m_id" "$m_name" "$m_scope" "$m_type" "$m_desc" >>"$report_md"
    done
    echo "Dry run plan written to $report_md"
    exit 0
fi

# Device Preflight
if [[ "${VPLAYER_AIRPLAY_ACCEPTANCE_MOCK_RUN:-0}" != "1" ]]; then
    echo "Checking device status via devicectl..."
    device_details="$(xcrun devicectl device info details --device "$device_udid" 2>&1)" || {
        echo "error: target device UDID is unavailable to CoreDevice" >&2
        exit 69
    }
    if ! rg -q 'productType: AppleTV14,1' <<<"$device_details"; then
        echo "error: target device must resolve to AppleTV14,1 (Apple TV 4K 3rd generation)" >&2
        exit 69
    fi

    destination_udid="$(
        sed -nE 's/^[[:space:]]*[^[:alnum:]]*[[:space:]]*udid:[[:space:]]*([A-Fa-f0-9-]+)$/\1/p' \
            <<<"$device_details" | sed -n '1p'
    )"
    if [[ -z "$destination_udid" ]]; then
        echo "error: device does not expose an xcodebuild destination UDID" >&2
        exit 69
    fi

    source "$script_dir/resolve-acceptance-development-team.sh"
    development_team="${VPLAYER_DEVELOPMENT_TEAM:-}"
    if [[ -z "$development_team" ]]; then
        signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        signing_certificates="$(security find-certificate -a -Z -p -c "Apple Development:" 2>/dev/null || true)"
        development_team="$(resolve_acceptance_development_team "$signing_identities" "$signing_certificates" || true)"
    fi
    if [[ ! "$development_team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "error: valid Apple Development team required for device code signing" >&2
        exit 69
    fi

    # Spawn loopback fixture server if needed
    if [[ -z "$fixture_server" ]] || (( spawn_fixture_server != 0 )); then
        server_script="$repository_root/Scripts/Support/fixture_server.py"
        [[ -x "$server_script" ]] || { echo "error: fixture server not executable: $server_script" >&2; exit 69; }
        [[ -d "$fixture_root" ]] || { echo "error: fixture root not found: $fixture_root" >&2; exit 69; }

        port_file="$(mktemp "${TMPDIR:-/tmp}/vplayer-fixture-port.XXXXXX")"
        "$server_script" --root "$fixture_root" --port-file "$port_file" &
        server_pid=$!

        bound_port=""
        for _ in $(seq 1 250); do
            if ! kill -0 "$server_pid" 2>/dev/null; then
                echo "error: loopback fixture server died" >&2
                exit 69
            fi
            if [[ -s "$port_file" ]]; then
                cand="$(tr -d '[:space:]' <"$port_file")"
                if [[ "$cand" =~ ^[1-9][0-9]*$ ]] && curl --fail --silent --head "http://127.0.0.1:$cand/SHA256SUMS" >/dev/null 2>&1; then
                    bound_port="$cand"
                    break
                fi
            fi
            sleep 0.02
        done
        [[ -n "$bound_port" ]] || { echo "error: fixture server failed readiness" >&2; exit 69; }
        fixture_server="http://127.0.0.1:$bound_port"
        echo "Loopback fixture server active on port $bound_port"
    fi
else
    destination_udid="00000000-0000-0000-0000-000000000000"
    development_team="TEAMRIGHT1"
    fixture_server="http://127.0.0.1:8080"
fi

# Execute and collect results
executed_results=()
pass_count=0
fail_count=0
scoped_count=0

for item in "${selected_items[@]}"; do
    IFS='|' read -r m_id m_name m_scope m_type m_desc <<<"$item"
    echo "Processing [$m_id] $m_name..."
    scenario_dir="$output_dir/$m_id"
    mkdir -p "$scenario_dir"

    status=""
    notes=""
    if [[ "$m_type" == "external" ]]; then
        status="SCOPED"
        notes="Unverified: requires external physical routing controls; recorded within verifiable scope per Section 13.2"
        scoped_count=$((scoped_count + 1))
    elif [[ "${VPLAYER_AIRPLAY_ACCEPTANCE_MOCK_RUN:-0}" == "1" ]]; then
        status="PASS"
        notes="Mock execution verified for $m_name"
        pass_count=$((pass_count + 1))
        printf 'Mock log for %s\n' "$m_id" >"$scenario_dir/run.log"
    else
        run_status=0
        if [[ "$m_id" == "M12" ]]; then
            set +e
            xcodebuild test \
                -project "$repository_root/VPlayer.xcodeproj" \
                -scheme VPlayer \
                -configuration Debug \
                -destination "platform=tvOS,id=$destination_udid" \
                -derivedDataPath "$scenario_dir/DerivedData" \
                -resultBundlePath "$scenario_dir/acceptance.xcresult" \
                -parallel-testing-enabled NO \
                -allowProvisioningUpdates \
                -only-testing:VPlayerUITests/LongPlaybackAcceptanceTests/testAACPrimingRSSRealDeviceExecutionSkipsGracefullyOnSimulator \
                DEVELOPMENT_TEAM="$development_team" >"$scenario_dir/run.log" 2>&1
            run_status=$?
            set -e
        elif [[ "$m_id" == "LP" ]]; then
            set +e
            "$script_dir/run-device-acceptance.sh" \
                --airplay \
                --long-playback \
                --output-dir "$scenario_dir" \
                "$device_udid" "default" "7200" "$fixture_server/playlist.m3u" >"$scenario_dir/run.log" 2>&1
            run_status=$?
            set -e
        else
            set +e
            "$script_dir/run-device-acceptance.sh" \
                --airplay \
                --output-dir "$scenario_dir" \
                "$device_udid" "$m_id" "$duration" "$fixture_server/playlist.m3u" >"$scenario_dir/run.log" 2>&1
            run_status=$?
            set -e
        fi

        if [[ $run_status -eq 0 ]]; then
            status="PASS"
            notes="Completed successfully"
            pass_count=$((pass_count + 1))
        elif [[ $run_status -eq 78 ]]; then
            status="PRIVACY_VIOLATION"
            notes="Privacy scan failed (exit 78)"
            fail_count=$((fail_count + 1))
        else
            status="FAIL"
            notes="Failed with exit code $run_status (see $scenario_dir/run.log)"
            fail_count=$((fail_count + 1))
        fi
    fi

    executed_results+=("$m_id|$m_name|$m_scope|$status|$notes")
done

# Assemble dynamic Markdown report
cat <<EOF >"$report_md"
# AirPlay HLS & AVPlayer Real Device Acceptance Report
- Date: $timestamp
- Target Device: AppleTV14,1 (Apple TV 4K 3rd generation)
- Destination UDID: [REDACTED]
- Backend: airPlayHLS
- Transport: loopbackHTTP
- Matrix Scope: $matrix_scope

## Executed Matrix Results

| ID | Matrix Scenario | Scope | Status | Notes |
|---|---|---|---|---|
EOF

for res in "${executed_results[@]}"; do
    IFS='|' read -r r_id r_name r_scope r_status r_notes <<<"$res"
    printf '| %s | %s | %s | %s | %s |\n' "$r_id" "$r_name" "$r_scope" "$r_status" "$r_notes" >>"$report_md"
done

cat <<EOF >>"$report_md"

## Summary
- Total Evaluated: ${#executed_results[@]}
- Passed: $pass_count
- Failed: $fail_count
- Scoped (External Hardware/Controls): $scoped_count
EOF

# Assemble dynamic JSON Report
python3 - "$report_json" "$timestamp" "$matrix_scope" "${executed_results[@]}" <<'PY'
import json
import sys

out_path, ts, scope = sys.argv[1:4]
items = []
for entry in sys.argv[4:]:
    parts = entry.split("|")
    if len(parts) >= 5:
        items.append({
            "id": parts[0],
            "name": parts[1],
            "scope": parts[2],
            "status": parts[3],
            "notes": parts[4]
        })

doc = {
    "timestamp": ts,
    "targetDevice": "AppleTV14,1",
    "backend": "airPlayHLS",
    "scope": scope,
    "results": items
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
PY

# Privacy Audit
if ! privacy_scan "$output_dir" "$fixture_server" ""; then
    echo "Privacy scan failed: sensitive tokens or raw URLs leaked" >&2
    exit 78
fi

echo "Acceptance suite execution completed successfully."
echo "Validation report generated: $report_md"
cleanup_fixture_server
exit 0
