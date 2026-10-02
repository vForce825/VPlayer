#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable allowlist and byte-bound tests; no Apple SDK or result export required."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "report-xcresult-failures.py"
SPEC = importlib.util.spec_from_file_location("xcresult_failure_report", HELPER)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


def schema():
    return {"properties": {"testFailures": {"items": {"properties": {
        "testName": {}, "testIdentifierString": {}, "testCaseName": {}, "failureText": {},
        "attachments": {}, "sourceCodeContext": {"properties": {"location": {
            "properties": {"filePath": {}, "lineNumber": {}}}}}}}}}}


class XCResultFailureReportTests(unittest.TestCase):
    def test_empty_failures_are_explicit(self):
        self.assertEqual(REPORT.report(schema(), {"testFailures": []}),
                         ["CI_TEST_FAILURE_SCHEMA_VERIFIED=1", "CI_TEST_FAILURE_COUNT=0"])

    def test_only_schema_approved_failure_fields_and_source_location_are_emitted(self):
        failure = {"testName": "Suite.test", "testIdentifierString": "Suite/test()",
                   "testCaseName": "test", "failureText": "expected1got0",
                   "attachments": [{"failureText": "ATTACHMENT MUST NOT LEAK"}],
                   "unknown": "PRIVATE", "message": "NOT IN SCHEMA",
                   "sourceCodeContext": {"location": {"filePath": "Tests/A.swift", "lineNumber": 3}}}
        result = "\n".join(REPORT.report(schema(), {"testFailures": [failure]}))
        for value in ("Suite.test", "Suite/test()", "expected1got0", "Tests/A.swift", '"lineNumber": 3'):
            self.assertIn(value, result)
        for value in ("ATTACHMENT", "PRIVATE", "NOT IN SCHEMA", "attachments"):
            self.assertNotIn(value, result)

    def test_schema_or_result_shape_mismatch_is_rejected(self):
        for description, value in (({}, {}), (schema(), {}), (schema(), {"testFailures": {}})):
            with self.subTest(value=value), self.assertRaises(ValueError):
                REPORT.report(description, value)

    def test_missing_failure_text_is_rejected(self):
        with self.assertRaises(ValueError):
            REPORT.report(schema(), {"testFailures": [{"testName": "Suite.test"}]})

    def test_failure_field_is_truncated_at_4096_characters(self):
        result = "\n".join(REPORT.report(schema(), {"testFailures": [{"failureText": "x" * 5000}]}))
        self.assertIn("x" * 4096, result)
        self.assertNotIn("x" * 4097, result)

    def test_total_utf8_output_cap_includes_marker_and_every_newline(self):
        failures = [{"testName": "Suite.test", "failureText": "界" * 5000}] * 30
        lines = REPORT.report(schema(), {"testFailures": failures})
        self.assertEqual(lines[-1], "CI_TEST_FAILURE_OUTPUT_TRUNCATED=1")
        self.assertLessEqual(len(("\n".join(lines) + "\n").encode("utf-8")), REPORT.MAX_OUTPUT)
        self.assertIn("CI_TEST_FAILURE_COUNT=30", lines)


if __name__ == "__main__":
    unittest.main()
