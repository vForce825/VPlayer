#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Progress is bounded diagnostic evidence, never a replacement test verdict."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tracemalloc
import unittest

ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / "Scripts/report-card-focus-progress.py"
SHA = "a" * 40
PREFIX = b"CARD_FOCUS_PROGRESS "


def record(case="flat", stage="ax", event="begin", **changes):
    value = dict(schema=1, case=case, stage=stage, event=event, direction="down",
                 cycle=1, step=12, captures=45, sample=2, sequence=600,
                 elapsed_ms=299_000, capture_ms=180_000, operation_ms=0, stage_ms=2_000)
    value.update(changes)
    return value


def line(value):
    return PREFIX + json.dumps(value, separators=(",", ":")).encode() + b"\n"


class CardFocusProgressReportTests(unittest.TestCase):
    def test_only_the_unfiltered_complete_debug_command_uses_the_relay(self):
        workflow = (ROOT / ".github/workflows/macos-ci.yml").read_text()
        complete = workflow.split("  complete-tests:\n", 1)[1].split("  release-contracts:\n", 1)[0]
        self.assertIn("set -o pipefail", complete)
        self.assertIn("./Scripts/test.sh -configuration Debug", complete)
        self.assertIn("-maximum-test-execution-time-allowance 300 2>&1 |", complete)
        self.assertIn('python3 Scripts/report-card-focus-progress.py --candidate "$CANDIDATE_SHA"', complete)
        self.assertEqual(workflow.count("Scripts/report-card-focus-progress.py"), 1)
        self.assertNotRegex(complete, r"--?(?:only|skip)-testing(?=[:=\s]|$)")

    def run_relay(self, payload, candidate=SHA, summary_is_directory=False):
        self.assertTrue(REPORTER.is_file(), "The full Debug job needs a bounded progress relay")
        with tempfile.TemporaryDirectory() as temporary:
            summary = Path(temporary) / "summary"
            if summary_is_directory:
                summary.mkdir()
            else:
                summary.write_text("Earlier job summary\n")
            result = subprocess.run(
                [sys.executable, str(REPORTER), "--candidate", candidate],
                input=payload, capture_output=True,
                env={**os.environ, "GITHUB_STEP_SUMMARY": str(summary)},
            )
            text = "" if summary_is_directory else summary.read_text()
            return result, text

    def load_reporter(self):
        self.assertTrue(REPORTER.is_file(), "The full Debug job needs a bounded progress relay")
        spec = importlib.util.spec_from_file_location("card_focus_progress", REPORTER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_timeout_keeps_last_stage_per_case_and_forwards_every_original_byte(self):
        flat = record(stage="screenshot")
        grouped = record(case="grouped", stage="terminate", event="begin")
        payload = (b"ordinary output \xff\x00\r\n" + line(record(stage="launch"))
                   + line(grouped) + line(flat)
                   + b"Test exceeded execution time allowance of 5 minutes\n")
        result, summary = self.run_relay(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)
        self.assertTrue(summary.startswith("Earlier job summary\n"))
        self.assertIn("CI_CARD_FOCUS_CANDIDATE=" + SHA, summary)
        self.assertIn("stage_only_not_test_verdict", summary)
        rows = [json.loads(row.split("=", 1)[1]) for row in summary.splitlines()
                if row.startswith("CI_CARD_FOCUS_LAST_VALID=")]
        self.assertEqual(rows, [flat, grouped])

    def test_absent_cases_are_unavailable(self):
        result, summary = self.run_relay(b"ordinary build failure\n")
        self.assertEqual(result.returncode, 0)
        self.assertIn("case=flat reason=no_valid_record", summary)
        self.assertIn("case=grouped reason=no_valid_record", summary)
        self.assertNotIn("CI_CARD_FOCUS_LAST_VALID=", summary)

    def test_cleanup_does_not_overwrite_last_error_evidence(self):
        failure = record(stage="capture", event="error", operation_ms=12_500)
        cleanup = record(stage="terminate", event="end", operation_ms=150)
        payload = (line(failure) + line(record(stage="terminate", event="begin"))
                   + line(cleanup) + b"test failed\n")
        result, summary = self.run_relay(payload)
        self.assertEqual(result.stdout, payload)
        last_error = [json.loads(row.split("=", 1)[1]) for row in summary.splitlines()
                      if row.startswith("CI_CARD_FOCUS_LAST_ERROR=")]
        last_valid = [json.loads(row.split("=", 1)[1]) for row in summary.splitlines()
                      if row.startswith("CI_CARD_FOCUS_LAST_VALID=")]
        self.assertEqual(last_error, [failure])
        self.assertEqual(last_valid, [cleanup])

    def test_malformed_unknown_and_oversized_rows_never_export_unapproved_data(self):
        private = "https://private.invalid/not-for-summary"
        bad = [line(record(url=private)), line(record(case=private)),
               line(record(stage=private)), line(record(captures=True)),
               line(record(elapsed_ms=float("nan"))), line(record(operation_ms=-1)),
               PREFIX + b'{"case":"flat","case":"grouped"}\n',
               PREFIX + b"[" * 3000 + b"\n",
               PREFIX + private.encode() + b"x" * 100_000 + b"\n"]
        payload = b"".join(bad)
        result, summary = self.run_relay(payload)
        self.assertEqual(result.stdout, payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CI_CARD_FOCUS_INVALID_RECORDS=9", summary)
        self.assertIn("reason=malformed_diagnostic_record", summary)
        self.assertNotIn(private, summary)
        self.assertNotIn("CI_CARD_FOCUS_LAST_VALID=", summary)

    def test_invalid_later_row_does_not_claim_old_valid_row_is_the_final_stage(self):
        payload = line(record()) + line(record(stage="unrecognized"))
        result, summary = self.run_relay(payload)
        self.assertEqual(result.stdout, payload)
        self.assertIn("CI_CARD_FOCUS_LAST_VALID=", summary)
        self.assertIn("reason=malformed_diagnostic_record", summary)
        self.assertIn("CI_CARD_FOCUS_INVALID_RECORDS=1", summary)

    def test_invalid_candidate_is_unavailable_and_not_copied_to_summary(self):
        result, summary = self.run_relay(line(record()), candidate="private-value")
        self.assertEqual(result.stdout, line(record()))
        self.assertEqual(result.returncode, 0)
        self.assertIn("CI_CARD_FOCUS_CANDIDATE=unavailable", summary)
        self.assertNotIn("private-value", summary)

    def test_summary_write_failure_keeps_output_and_original_producer_status_available(self):
        result, _ = self.run_relay(line(record()), summary_is_directory=True)
        self.assertEqual(result.stdout, line(record()))
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"CI_CARD_FOCUS_SUMMARY_UNAVAILABLE=", result.stderr)

    def test_failed_producer_exit_status_survives_the_real_pipefail_pipeline(self):
        self.assertTrue(REPORTER.is_file(), "The full Debug job needs a bounded progress relay")
        payload = line(record(stage="screenshot")) + b"test timed out\n"
        with tempfile.TemporaryDirectory() as temporary:
            producer = Path(temporary) / "producer.py"
            producer.write_text("import sys\nsys.stdout.buffer.write(" + repr(line(record(stage="screenshot")))
                                + ")\nsys.stdout.flush()\nsys.stderr.buffer.write(b'test timed out\\n')"
                                + "\nsys.exit(65)\n")
            summary = Path(temporary) / "summary"
            result = subprocess.run(
                ["bash", "-c", 'set -o pipefail; "$1" "$2" 2>&1 | "$1" "$3" --candidate "$4"',
                 "--", sys.executable, str(producer), str(REPORTER), SHA],
                capture_output=True, env={**os.environ, "GITHUB_STEP_SUMMARY": str(summary)},
            )
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertEqual(result.stdout, payload)
            self.assertIn('"stage":"screenshot"', summary.read_text())

    def test_huge_unterminated_ordinary_line_is_streamed_with_bounded_memory(self):
        module = self.load_reporter()
        tail = b"\n" + line(record(stage="ax")).rstrip(b"\n")

        class Sink:
            count = 0
            def __init__(self): self.digest = hashlib.sha256()
            def write(self, data):
                self.count += len(data)
                self.digest.update(data)
                return len(data)
            def flush(self): pass

        sink = Sink()
        expected = hashlib.sha256()

        class Source:
            remaining = 16 * 1024 * 1024
            position = 0
            emitted = 0
            def read(self, size):
                # Forward before asking for more, and never use unbounded reads.
                assert 0 < size <= 16_384
                assert sink.count == self.emitted
                if self.remaining:
                    value = b"x" * min(size, self.remaining)
                    self.remaining -= len(value)
                else:
                    # Split the marker and JSON across many chunk boundaries.
                    value = tail[self.position:self.position + 7]
                    self.position += len(value)
                self.emitted += len(value)
                expected.update(value)
                return value

        tracemalloc.start()
        try:
            state = module.relay(Source(), sink)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(sink.digest.digest(), expected.digest())
        self.assertEqual(state.latest["flat"], record(stage="ax"))
        self.assertEqual(state.invalid_records, 0)
        self.assertLess(peak, 512 * 1024, "The giant ordinary line must not be retained")


if __name__ == "__main__":
    unittest.main()
