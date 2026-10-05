#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""An absent, skipped, duplicate or failed diagnostic is never passing evidence."""
import importlib.util
from pathlib import Path
import re
import unittest

PATH = Path(__file__).resolve().parents[1] / "verify-diagnostic-test-log.py"
SPEC = importlib.util.spec_from_file_location("diagnostic_log", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiagnosticLogTests(unittest.TestCase):
    def transcript(self, group):
        return "\n".join(
            f"Test Case '-[VPlayerTests.{cls} {case}]' passed (0.001 seconds)."
            for cls, cases in MODULE.CASES[group].items() for case in cases
        )

    def test_focus_requires_all_ten_visual_and_raster_cases(self):
        self.assertIn("testInvalidRasterStorageAndNonfiniteBoundsAreUnavailable",
                      MODULE.CASES["focus"]["ChannelCardFocusRasterTests"])
        self.assertEqual(MODULE.verify(self.transcript("focus"), "focus"), 10)

    def test_audio_requires_all_six_original_cases(self):
        self.assertEqual(MODULE.verify(self.transcript("audio"), "audio"), 6)

    def test_required_names_exist_in_the_independent_swift_test_sources(self):
        root = PATH.parents[1] / "Tests"
        source_cases = set()
        for path in root.rglob("*.swift"):
            text = path.read_text()
            classes = list(re.finditer(r"\b(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", text))
            for index, declaration in enumerate(classes):
                cls = declaration.group(1)
                start = declaration.end()
                end = classes[index + 1].start() if index + 1 < len(classes) else len(text)
                for case in re.findall(r"\bfunc\s+(test\w+)\s*\(", text[start:end]):
                    source_cases.add((cls, case))
        for group, classes in MODULE.CASES.items():
            for cls, cases in classes.items():
                for case in cases:
                    with self.subTest(group=group, cls=cls, case=case):
                        self.assertTrue((cls, case) in source_cases,
                                        f"Required diagnostic {cls}/{case} has no Swift test declaration")

    def test_missing_case_is_not_pass(self):
        with self.assertRaises(ValueError):
            MODULE.verify("\n".join(self.transcript("focus").splitlines()[1:]), "focus")

    def test_skipped_case_is_not_pass(self):
        with self.assertRaises(ValueError):
            MODULE.verify(self.transcript("focus").replace("passed", "skipped", 1), "focus")

    def test_failed_case_is_not_pass(self):
        with self.assertRaises(ValueError):
            MODULE.verify(self.transcript("focus").replace("passed", "failed", 1), "focus")

    def test_duplicate_pass_is_not_single_verified_execution(self):
        text = self.transcript("focus")
        with self.assertRaises(ValueError):
            MODULE.verify(text + "\n" + text.splitlines()[0], "focus")

    def test_failure_followed_by_pass_cannot_be_hidden(self):
        text = self.transcript("focus")
        with self.assertRaises(ValueError):
            MODULE.verify(text.splitlines()[0].replace("passed", "failed") + "\n" + text, "focus")


if __name__ == "__main__":
    unittest.main()
