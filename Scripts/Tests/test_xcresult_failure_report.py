#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable allowlist and byte-bound tests; no Apple SDK or result export required."""
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import html
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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
        lines = REPORT.report(schema(), {"testFailures": []})
        self.assertEqual(lines[:3], ["CI_TEST_FAILURE_SCHEMA_VERIFIED=1",
                                     "CI_TEST_FAILURE_COUNT=0", "CI_TEST_FAILURE_COUNT_KIND=records"])
        self.assertIn("CI_TEST_SUMMARY_SCALARS={}", lines)
        self.assertIn('"passedTests"', lines[4])
        self.assertEqual(lines[5], "CI_TEST_SUMMARY_UNKNOWN_FIELDS=[]")

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


class XCResultSummaryReportTests(unittest.TestCase):
    """Synthetic schemas verify fail-closed behavior, not native availability."""
    def summary(self, description, document):
        lines = REPORT.report(description, {"testFailures": [], **document})
        result = {}
        for key in ("SCALARS", "UNAVAILABLE_FIELDS", "UNKNOWN_FIELDS"):
            prefix = "CI_TEST_SUMMARY_" + key + "="
            matches = [line[len(prefix):] for line in lines if line.startswith(prefix)]
            self.assertEqual(len(matches), 1, f"one explicit {key} record is required")
            result[key] = json.loads(matches[0])
        return result

    def advertised_schema(self):
        result = schema()
        result["properties"].update({
            "result": {"type": "string"},
            "totalTestCount": {"type": "integer"},
            "passedTests": {"type": "integer"},
            "failedTests": {"type": "integer"},
            "skippedTests": {"type": "integer"},
            "expectedFailures": {"type": "integer"},
            "notRunTests": {"type": "integer"},
        })
        return result

    def test_actual_advertised_scalars_are_verbatim_and_failure_records_are_distinct(self):
        values = {"result": "Failed", "totalTestCount": 19, "passedTests": 8,
                  "failedTests": 4, "skippedTests": 3, "expectedFailures": 1,
                  "notRunTests": 3}
        result = self.summary(self.advertised_schema(), values)
        self.assertEqual(result["SCALARS"], values)
        self.assertEqual(result["UNAVAILABLE_FIELDS"], [])
        self.assertEqual(result["UNKNOWN_FIELDS"], [])
        lines = REPORT.report(self.advertised_schema(), {**values, "testFailures": [
            {"failureText": "one record is not the failed test count"}]})
        self.assertIn("CI_TEST_FAILURE_COUNT=1", lines)
        self.assertIn("CI_TEST_FAILURE_COUNT_KIND=records", lines)
        self.assertIn('"failedTests": 4', "\n".join(lines))

    def test_missing_summary_or_schema_fields_stay_unavailable_without_inferred_zero(self):
        result = self.summary(self.advertised_schema(), {"totalTestCount": 10, "passedTests": 10})
        self.assertEqual(result["SCALARS"], {"totalTestCount": 10, "passedTests": 10})
        for key in ("failedTests", "skippedTests", "notRunTests", "result"):
            self.assertIn(key, result["UNAVAILABLE_FIELDS"])
        self.assertEqual(result["UNKNOWN_FIELDS"], [])
        result = self.summary(schema(), {"passedTests": 10})
        self.assertEqual(result["SCALARS"], {})
        self.assertIn("passedTests", result["UNAVAILABLE_FIELDS"])

    def test_nested_properties_cannot_authorize_a_root_summary_scalar(self):
        description = schema()
        description["properties"]["testFailures"]["items"]["properties"]["passedTests"] = {"type": "integer"}
        result = self.summary(description, {"passedTests": 7})
        self.assertEqual(result["SCALARS"], {})
        self.assertIn("passedTests", result["UNAVAILABLE_FIELDS"])

    def test_wrong_scalar_types_negative_counts_and_bools_are_unknown_not_coerced(self):
        for value in (True, False, -1, 3.5, "7", None, [], {}, 2**80):
            with self.subTest(value=value):
                result = self.summary(self.advertised_schema(), {"passedTests": value})
                self.assertEqual(result["SCALARS"], {})
                self.assertIn("passedTests", result["UNKNOWN_FIELDS"])
                self.assertNotIn("passedTests", result["UNAVAILABLE_FIELDS"])

    def test_unadvertised_types_and_private_or_oversized_fields_are_not_emitted(self):
        description = self.advertised_schema()
        description["properties"]["passedTests"] = {"type": "string"}
        description["properties"]["privateData"] = {"type": "string"}
        result = self.summary(description, {"passedTests": 7, "privateData": "SECRET",
                                            "result": "x" * 1000})
        self.assertEqual(result["SCALARS"], {})
        self.assertIn("passedTests", result["UNAVAILABLE_FIELDS"])
        self.assertIn("result", result["UNKNOWN_FIELDS"])
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("x" * 100, json.dumps(result))

    def test_missing_counts_never_change_failure_status_or_output_budget(self):
        failures = [{"testName": "Suite.test", "failureText": "界" * 5000}] * 30
        lines = REPORT.report(self.advertised_schema(), {
            "result": "Failed", "failedTests": 30, "testFailures": failures})
        self.assertIn('"result": "Failed"', "\n".join(lines))
        self.assertIn("CI_TEST_FAILURE_COUNT=30", lines)
        self.assertEqual(lines[-1], "CI_TEST_FAILURE_OUTPUT_TRUNCATED=1")
        self.assertLessEqual(len(("\n".join(lines) + "\n").encode("utf-8")), REPORT.MAX_OUTPUT)


class XCResultJobSummaryTests(unittest.TestCase):
    def environment(self, summary_path):
        environment = dict(os.environ)
        environment.pop("GITHUB_STEP_SUMMARY", None)
        if summary_path is not None:
            environment["GITHUB_STEP_SUMMARY"] = str(summary_path)
        return environment

    def invoke_main(self, summary_path=None, document=None, missing=False):
        document = document if document is not None else {"testFailures": [
            {"testName": "Suite.test", "failureText": "expected 1, got 0"}]}
        stdout, stderr = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Scoped.xcresult"
            if not missing:
                bundle.mkdir()
            with patch.dict(os.environ, self.environment(summary_path), clear=True), \
                    patch.object(sys, "argv", [str(HELPER), str(bundle)]), \
                    patch.object(REPORT, "run", side_effect=[
                        "--path --schema", json.dumps(schema()), json.dumps(document)]), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                result = REPORT.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def code_text(self, content):
        self.assertTrue(content.startswith("\n<pre><code>\n"))
        self.assertTrue(content.endswith("</code></pre>\n"))
        encoded = content[len("\n<pre><code>\n"):-len("</code></pre>\n")]
        self.assertNotIn("<", encoded)
        self.assertNotIn(">", encoded)
        return html.unescape(encoded)

    def read_summary(self, path):
        self.assertTrue(path.is_file(), "the report should create the optional job summary")
        return path.read_text(encoding="utf-8")

    def test_missing_summary_environment_preserves_stdout(self):
        document = {"testFailures": [{"failureText": "expected 1, got 0"}]}
        result, stdout, stderr = self.invoke_main(document=document)
        self.assertIsNone(result)
        self.assertEqual(stdout, "\n".join(REPORT.report(schema(), document)) + "\n")
        self.assertEqual(stderr, "")

    def test_summary_appends_the_same_report_without_replacing_existing_content(self):
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            existing = "Earlier step detail\n"
            summary_path.write_text(existing, encoding="utf-8")
            result, stdout, stderr = self.invoke_main(summary_path)
            content = self.read_summary(summary_path)
        self.assertIsNone(result)
        self.assertEqual(stderr, "")
        self.assertTrue(content.startswith(existing))
        self.assertEqual(self.code_text(content[len(existing):]), stdout)

    def test_unavailable_bundle_is_also_published_without_changing_exit_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            result, stdout, stderr = self.invoke_main(summary_path, missing=True)
            content = self.read_summary(summary_path)
        self.assertIsNone(result)
        self.assertEqual(stdout, "CI_TEST_FAILURE_REPORT_UNAVAILABLE=bundle_missing\n")
        self.assertEqual(stderr, "")
        self.assertEqual(self.code_text(content), stdout)

    def test_error_record_keeps_exit_one_with_summary_present_absent_or_unwritable(self):
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            for destination in (None, summary_path, Path(directory)):
                with self.subTest(destination=destination):
                    result = subprocess.run([sys.executable, str(HELPER)],
                                            env=self.environment(destination),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "CI_TEST_FAILURE_REPORT_ERROR=ValueError: "
                                     "expected one scoped xcresult bundle path\n")
                    if destination == summary_path:
                        self.assertEqual(self.code_text(self.read_summary(summary_path)),
                                         result.stdout)

    def test_summary_io_failure_does_not_change_primary_success_or_unavailable_report(self):
        baseline = self.invoke_main()[1]
        with tempfile.TemporaryDirectory() as directory:
            for missing in (False, True):
                with self.subTest(missing=missing):
                    result, stdout, stderr = self.invoke_main(Path(directory), missing=missing)
                    self.assertIsNone(result)
                    self.assertEqual(stdout, "CI_TEST_FAILURE_REPORT_UNAVAILABLE=bundle_missing\n"
                                     if missing else baseline)
                    self.assertIn("CI_TEST_FAILURE_SUMMARY_UNAVAILABLE=", stderr)

    def test_assertion_markup_is_preserved_as_plain_code_text(self):
        document = {"testFailures": [{"failureText":
            'expected <value> & "actual"\n```\n[diagnostic](https://example.test)\n</code></pre>'}]}
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            _, stdout, _ = self.invoke_main(summary_path, document)
            content = self.read_summary(summary_path)
        self.assertEqual(self.code_text(content), stdout)
        self.assertIn("&lt;value&gt; &amp;", content)

    def test_summary_byte_cap_includes_escaped_text_wrappers_and_truncation_marker(self):
        document = {"testFailures": [{"testName": "Suite.test", "failureText": "<&界" * 2000}] * 30}
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            _, stdout, _ = self.invoke_main(summary_path, document)
            content = self.read_summary(summary_path)
        self.assertLessEqual(len(content.encode("utf-8")), REPORT.MAX_OUTPUT)
        decoded = self.code_text(content)
        marker = "CI_TEST_FAILURE_SUMMARY_TRUNCATED=1\n"
        self.assertTrue(decoded.endswith(marker))
        self.assertTrue(stdout.startswith(decoded[:-len(marker)]))
        self.assertIn("CI_TEST_FAILURE_COUNT=30\n", decoded)
        self.assertIn("CI_TEST_FAILURE ", decoded)
        self.assertNotIn("CI_TEST_FAILURE_SUMMARY_TRUNCATED", stdout)

    def test_zero_failure_records_do_not_create_a_pass_result_or_missing_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.md"
            _, stdout, _ = self.invoke_main(summary_path, {"testFailures": []})
            content = self.read_summary(summary_path)
        self.assertEqual(self.code_text(content), stdout)
        self.assertIn("CI_TEST_FAILURE_COUNT=0\nCI_TEST_FAILURE_COUNT_KIND=records\n", stdout)
        self.assertIn("CI_TEST_SUMMARY_SCALARS={}\n", stdout)
        self.assertIn('"passedTests"', stdout)


if __name__ == "__main__":
    unittest.main()
