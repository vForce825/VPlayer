#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-acceptance-signal.XXXXXX")"
pid_file="$test_directory/child.pid"
runner_pid=""

cleanup() {
    if [[ -n "$runner_pid" ]] && kill -0 "$runner_pid" 2>/dev/null; then
        kill -TERM "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file" "$test_directory/output.log"
    rmdir "$test_directory" 2>/dev/null || true
}
trap cleanup EXIT

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
