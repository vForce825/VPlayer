#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Print bounded test-failure text only; never export result bundles or attachments."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

MAX_JSON = 8 * 1024 * 1024
MAX_OUTPUT = 64 * 1024
ALLOWED = {"testName", "testCaseName", "testIdentifier", "testIdentifierString", "testIdentifierURL", "failureText", "message",
           "filePath", "fileName", "lineNumber", "line", "columnNumber"}


def run(args):
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(["xcrun", "xcresulttool", *args], stdout=output,
                                stderr=subprocess.PIPE, timeout=30)
        if result.returncode:
            raise RuntimeError("xcresulttool command failed: " + " ".join(args[:4]) +
                               " exit=" + str(result.returncode))
        if output.tell() > MAX_JSON:
            raise RuntimeError("xcresulttool output exceeds bounded parser capacity")
        output.seek(0)
        return output.read().decode("utf-8")


def schema_keys(node):
    result = set()
    if isinstance(node, dict):
        result.update(node.get("properties", {}))
        for value in node.values():
            result.update(schema_keys(value))
    elif isinstance(node, list):
        for value in node:
            result.update(schema_keys(value))
    return result


def failure_fields(node, approved):
    fields = {}
    if not isinstance(node, dict):
        raise ValueError("failure record must be an object")
    for key, value in node.items():
        if key in approved and isinstance(value, (str, int)) and not isinstance(value, bool):
            fields[key] = value[:4096] if isinstance(value, str) else value
        elif key in {"sourceCodeContext", "location", "sourceLocation"} and isinstance(value, dict):
            fields.update(failure_fields(value, approved))
    return fields


def report(schema, summary):
    approved = schema_keys(schema)
    if "testFailures" not in approved or "testFailures" not in summary:
        raise ValueError("verified summary schema/result lacks testFailures")
    failures = summary["testFailures"]
    if not isinstance(failures, list):
        raise ValueError("testFailures must be an array")
    approved &= ALLOWED
    if not approved.intersection({"failureText", "message"}):
        raise ValueError("verified schema lacks supported failure-message field")
    lines = ["CI_TEST_FAILURE_SCHEMA_VERIFIED=1", "CI_TEST_FAILURE_COUNT=" + str(len(failures))]
    total = sum(len(line.encode("utf-8")) + 1 for line in lines)
    marker = "CI_TEST_FAILURE_OUTPUT_TRUNCATED=1"
    marker_bytes = len(marker.encode("utf-8")) + 1
    for failure in failures:
        fields = failure_fields(failure, approved)
        if not fields or not any(key in fields for key in ("failureText", "message")):
            raise ValueError("failure record lacks approved assertion text")
        line = "CI_TEST_FAILURE " + json.dumps(fields, ensure_ascii=True, sort_keys=True)
        line_bytes = len(line.encode("utf-8")) + 1
        if total + line_bytes + marker_bytes > MAX_OUTPUT:
            lines.append(marker)
            break
        lines.append(line)
        total += line_bytes
    return lines


def main():
    if len(sys.argv) != 2:
        raise ValueError("expected one scoped xcresult bundle path")
    bundle = Path(sys.argv[1])
    if bundle.suffix != ".xcresult" or not bundle.is_dir():
        print("CI_TEST_FAILURE_REPORT_UNAVAILABLE=bundle_missing")
        return
    help_text = run(["help", "get", "test-results", "summary"])
    if "--path" not in help_text or "--schema" not in help_text:
        raise RuntimeError("installed xcresulttool does not advertise required summary options")
    schema = json.loads(run(["get", "test-results", "summary", "--schema"]))
    summary = json.loads(run(["get", "test-results", "summary", "--path", str(bundle)]))
    for line in report(schema, summary):
        print(line)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print("CI_TEST_FAILURE_REPORT_ERROR=" + type(error).__name__ + ": " + str(error)[:512])
        raise SystemExit(1)
