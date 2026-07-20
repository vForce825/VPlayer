#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-acceptance-signal.XXXXXX")"
pid_file="$test_directory/child.pid"
term_ready_file="$test_directory/prechild-term.ready"
term_launch_file="$test_directory/prechild-term.launched"
hup_ready_file="$test_directory/prechild-hup.ready"
hup_launch_file="$test_directory/prechild-hup.launched"
runner_pid=""

cleanup() {
    if [[ -n "$runner_pid" ]] && kill -0 "$runner_pid" 2>/dev/null; then
        kill -TERM "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
    fi
    rm -f \
        "$pid_file" \
        "$term_ready_file" \
        "$term_launch_file" \
        "$hup_ready_file" \
        "$hup_launch_file" \
        "$test_directory/prechild-TERM.log" \
        "$test_directory/prechild-HUP.log" \
        "$test_directory/output.log"
    rmdir "$test_directory" 2>/dev/null || true
}
trap cleanup EXIT

run_prechild_signal_test() {
    local signal="$1"
    local ready_file="$2"
    local launch_file="$3"
    local output_file="$test_directory/prechild-$signal.log"
    local test_status

    VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_MODE=1 \
    VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_READY_FILE="$ready_file" \
    VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_LAUNCH_FILE="$launch_file" \
        "$script_dir/run-device-acceptance.sh" >"$output_file" 2>&1 &
    runner_pid=$!

    for _ in $(seq 1 100); do
        [[ -s "$ready_file" ]] && break
        sleep 0.05
    done
    if [[ ! -s "$ready_file" ]]; then
        echo "$signal pre-child signal seam did not become ready" >&2
        return 1
    fi

    kill -"$signal" "$runner_pid"
    set +e
    wait "$runner_pid"
    test_status=$?
    set -e
    runner_pid=""

    [[ "$test_status" == "130" ]]
    [[ ! -e "$launch_file" ]]
}

run_prechild_signal_test TERM "$term_ready_file" "$term_launch_file"
run_prechild_signal_test HUP "$hup_ready_file" "$hup_launch_file"

VPLAYER_ACCEPTANCE_SIGNAL_TEST_MODE=1 \
VPLAYER_ACCEPTANCE_SIGNAL_TEST_PID_FILE="$pid_file" \
    "$script_dir/run-device-acceptance.sh" >"$test_directory/output.log" 2>&1 &
runner_pid=$!

for _ in $(seq 1 100); do
    [[ -s "$pid_file" ]] && break
    sleep 0.05
done
[[ -s "$pid_file" ]]
child_pid="$(sed -n '1p' "$pid_file")"
[[ "$child_pid" =~ ^[1-9][0-9]*$ ]]

kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
status=$?
set -e
runner_pid=""

[[ "$status" == "130" ]]
if kill -0 "$child_pid" 2>/dev/null; then
    echo "signal test child was not reaped" >&2
    exit 1
fi
