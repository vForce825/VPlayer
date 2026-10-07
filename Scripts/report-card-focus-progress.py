#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Relay original test output; append only bounded, allowlisted focus progress."""
import argparse
import json
import os
import re
import sys

PREFIX = b"CARD_FOCUS_PROGRESS "
CHUNK_BYTES = 16_384
MAX_LINE_BYTES = 4_096
CASES = ("flat", "grouped")
ENUMS = {
    "case": CASES,
    "stage": ("launch", "entry", "navigation", "focus_wait", "capture", "ax",
              "screenshot", "raster", "viewport", "attachment", "terminate"),
    "event": ("begin", "end", "error"),
    "direction": ("none", "up", "down", "left", "right", "select"),
}
BOUNDS = {
    "schema": (1, 1), "cycle": (-1, 1), "step": (-1, 29),
    "captures": (0, 124), "sample": (0, 10_000), "sequence": (1, 1_000_000),
    "elapsed_ms": (0, 86_400_000), "capture_ms": (0, 86_400_000),
    "operation_ms": (0, 86_400_000), "stage_ms": (0, 86_400_000),
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def parse_record(data):
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != set(ENUMS) | set(BOUNDS):
        raise ValueError("unrecognized fields")
    for key, allowed in ENUMS.items():
        if not isinstance(value[key], str) or value[key] not in allowed:
            raise ValueError("unrecognized enum")
    for key, (lower, upper) in BOUNDS.items():
        if type(value[key]) is not int or not lower <= value[key] <= upper:
            raise ValueError("invalid scalar")
    return value


class Progress:
    def __init__(self):
        self.latest = {}
        self.latest_error = {}
        self.invalid_records = 0
        self.pending = bytearray()
        self.oversized = False

    def finish_line(self):
        if self.pending.startswith(PREFIX):
            try:
                if self.oversized:
                    raise ValueError("oversized record")
                value = parse_record(self.pending[len(PREFIX):])
                self.latest[value["case"]] = value
                if value["event"] == "error":
                    self.latest_error[value["case"]] = value
            except (ValueError, UnicodeError, RecursionError):
                self.invalid_records = min(1_000_000, self.invalid_records + 1)
        self.pending.clear()
        self.oversized = False

    def consume(self, chunk):
        # Keep at most a single bounded line prefix. Even a multi-gigabyte
        # compiler line without a newline is forwarded without being retained.
        start = 0
        while start < len(chunk):
            end = chunk.find(b"\n", start)
            boundary = len(chunk) if end < 0 else end
            available = MAX_LINE_BYTES - len(self.pending)
            self.pending.extend(chunk[start:min(boundary, start + available)])
            if boundary - start > available:
                self.oversized = True
            if end < 0:
                break
            self.finish_line()
            start = end + 1

    def summary(self, candidate):
        verified_sha = candidate if re.fullmatch(r"[0-9a-f]{40}", candidate) else "unavailable"
        rows = ["CI_CARD_FOCUS_CANDIDATE=" + verified_sha,
                "CI_CARD_FOCUS_PROGRESS_EVIDENCE=stage_only_not_test_verdict",
                "CI_CARD_FOCUS_INVALID_RECORDS=" + str(self.invalid_records)]
        if self.invalid_records:
            rows.append("CI_CARD_FOCUS_PROGRESS_UNAVAILABLE=latest_stage reason=malformed_diagnostic_record")
        for case in CASES:
            if case in self.latest:
                rows.append("CI_CARD_FOCUS_LAST_VALID=" + json.dumps(
                    self.latest[case], sort_keys=True, separators=(",", ":")))
            else:
                rows.append("CI_CARD_FOCUS_PROGRESS_UNAVAILABLE=case=" + case + " reason=no_valid_record")
            if case in self.latest_error:
                rows.append("CI_CARD_FOCUS_LAST_ERROR=" + json.dumps(
                    self.latest_error[case], sort_keys=True, separators=(",", ":")))
        # Every string above is fixed vocabulary or a validated scalar. No
        # ordinary output, hierarchy labels, URLs, attachments or raw errors.
        return "\n<pre><code>\n" + "\n".join(rows) + "\n</code></pre>\n"


def relay(source, destination):
    state = Progress()
    read = getattr(source, "read1", source.read)
    while chunk := read(CHUNK_BYTES):
        destination.write(chunk)
        destination.flush()
        state.consume(chunk)
    state.finish_line()
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args()
    state = relay(sys.stdin.buffer, sys.stdout.buffer)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        print("CI_CARD_FOCUS_SUMMARY_UNAVAILABLE=destination_missing", file=sys.stderr)
        return
    try:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(state.summary(args.candidate))
    except (OSError, UnicodeError) as error:
        # Optional evidence must not replace xcodebuild's exit status. The
        # caller's pipefail still propagates the original failing test command.
        print("CI_CARD_FOCUS_SUMMARY_UNAVAILABLE=" + type(error).__name__, file=sys.stderr)


if __name__ == "__main__":
    main()
