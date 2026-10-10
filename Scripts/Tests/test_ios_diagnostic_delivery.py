#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Privacy, bounds, provenance and publication contracts."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
REPORT = load("report-ios-diagnostic")
PUBLISH = load("publish-ios-diagnostic")
HEAD = "a" * 40
HOST = ("HOST_AUDIO_CONTROL outcome=passed itemStatus=1 playerStatus=1 timeControl=0 "
        "progressed=true maximumTime=2.0 eos=true elapsed=2.3 syntheticDuration=2 "
        "qualification=host-control-not-ios-acceptance")

def schema():
    return {"properties": {"failedTests": {"type": "integer"},
        "passedTests": {"type": "integer"}, "result": {"type": "string"},
        "testFailures": {"items": {"properties": {"testIdentifierString": {},
            "testName": {}, "failureText": {}}}}}}
def failure():
    return {"testIdentifierString": "NativeHLSMasterSmokeTests/testNativeEOSStableOvershootKeepsOriginalItemAndAuthority()",
        "failureText": ("NATIVE_HLS_SMOKE_FAILURE phase=eos-ordering-startup route=native reason=deadline "
            "detail={original-current=0/1:0:1 original-duration=80/1:0:1 player-rate=1.0 "
            "player-control=2 original-verified=false same-physical=true error-code=0} "
            "runtime={appState=0 protected=true idleDisabled=false outputs=1 channels=2 rate=48000.0} "
            "trace={https://private.invalid/token=secret /Users/private/video.mov SECRET}") }
def report(document=None):
    return REPORT.collect(schema(), document or {"failedTests": 1, "passedTests": 4,
        "result": "Failed", "testFailures": [failure()]},
        candidate=HEAD, run_id=123, functional="failure", cpu="success", host_text=HOST)

class DiagnosticTests(unittest.TestCase):
    def test_xcode27_named_summary_schema_preserves_declared_count_types(self):
        x = REPORT.collect({'schemas': {'Summary': schema()}},
            {'failedTests': 2, 'passedTests': 3, 'testFailures': []},
            candidate=HEAD, run_id=123, functional='failure', cpu='success', host_text=HOST)
        self.assertEqual(x['counts'], {'failedTests': 2, 'passedTests': 3})

    def test_real_nested_original_failure_keeps_outer_clock_without_trace(self):
        f = failure()
        f['failureText'] = f['failureText'].replace('detail={', 'detail={original-failure={PRIVATE} ')
        x = report({'testFailures': [f]})
        self.assertEqual(x['failures'][0]['evidence']['original-current'], '0/1:0:1')
        self.assertNotIn('PRIVATE', PUBLISH.comment_body(x))

    def test_workflow_delivery_gates_preserve_readonly_native_and_failure_path(self):
        text = (ROOT.parent / '.github/workflows/ios-ci.yml').read_text()
        native = text.split('  ios-tests:', 1)[1].split('  diagnostic-publish:', 1)[0]
        probe = text.split('  diagnostic-probe:', 1)[1].split('  ios-tests:', 1)[0]
        publish = text.split('  diagnostic-publish:', 1)[1]
        self.assertIn('needs: [generated-inputs, diagnostic-probe]', native)
        self.assertNotIn('pull-requests: write', native)
        self.assertNotIn('GITHUB_TOKEN:', native)
        self.assertNotIn('continue-on-error', text)
        self.assertIn('cmp "$RUNNER_TEMP/diagnostic-probe/diagnostic.json"', probe)
        for job in (probe, publish):
            self.assertIn('pull-requests: write', job)
            self.assertIn('github.event.pull_request.head.repo.full_name == github.repository', job)
            self.assertIn('persist-credentials: false', job)
            self.assertIn('publish-ios-diagnostic.py', job)
        self.assertIn("if: always() && !cancelled() && needs.ios-tests.result != 'skipped'", publish)
        self.assertIn('--functional "$FUNCTIONAL_OUTCOME" --cpu "$CPU_OUTCOME"', native)
        self.assertIn('if-no-files-found: error', native)
        self.assertNotIn('.xcresult\n', native.split('      - uses: actions/upload-artifact@', 1)[1])

    def test_actual_identifier_runtime_and_clock_survive_without_free_text(self):
        x = report()
        f = x["failures"][0]
        self.assertEqual(f["case"], failure()["testIdentifierString"][:-2])
        self.assertEqual(f["phase"], "eos-ordering-startup")
        self.assertEqual(f["runtime"]["appState"], 0)
        self.assertEqual(f["runtime"]["rate"], 48000.0)
        self.assertEqual(f["evidence"]["original-current"], "0/1:0:1")
        self.assertEqual(f["evidence"]["player-control"], 2)
        self.assertIs(f["evidence"]["original-verified"], False)
        self.assertEqual(x["host"]["outcome"], "passed")
        text = json.dumps(x)
        for secret in ("private.invalid", "/Users/private", "SECRET", "token=", "video.mov"):
            self.assertNotIn(secret, text)
    def test_unrecognized_case_and_scalar_values_cannot_leak(self):
        f = failure()
        f["testIdentifierString"] = "https://private.invalid/secret"
        f["failureText"] = ("NATIVE_HLS_SMOKE_FAILURE phase=PRIVATE route=PRIVATE reason=PRIVATE "
            "runtime={appState=secret protected=secret outputs=999999 channels=-10 rate=nan} "
            "detail={original-current=secret player-rate=nan error-domain=PRIVATE}")
        x = report({"testFailures": [f]})
        self.assertIsNone(x["failures"][0]["case"])
        self.assertEqual(x["failures"][0]["runtime"], {})
        self.assertEqual(x["failures"][0]["evidence"], {})
        self.assertNotIn("PRIVATE", json.dumps(x))
    def test_empty_native_failures_and_unavailable_runtime_are_explicit(self):
        x = report({"testFailures": []})
        self.assertEqual(x["failure_records"], 0)
        self.assertEqual(x["failures"], [])
        f = failure(); f["failureText"] = "XCTAssertTrue failed"
        x = report({"testFailures": [f]})
        self.assertEqual(x["failures"][0]["runtime_status"], "unavailable")
        self.assertEqual(x["failures"][0]["assertion"], "assertion")
    def test_schema_mismatch_fails_closed_and_no_count_subtraction(self):
        with self.assertRaises(ValueError):
            REPORT.collect({}, {}, candidate=HEAD, run_id=123, functional="failure",
                cpu="success", host_text=HOST)
        x = report({"testFailures": [], "passedTests": 20, "failedTests": "wrong"})
        self.assertNotIn("failedTests", x["counts"])
        self.assertNotIn("totalTestCount", x["counts"])
    def test_record_and_serialized_bounds_expose_truncation(self):
        x = report({"testFailures": [failure()] * 1000})
        self.assertEqual(x["failure_records"], 1000)
        self.assertTrue(x["truncated"])
        self.assertLessEqual(len(x["failures"]), 64)
        self.assertLessEqual(len(REPORT.encode(x)), REPORT.MAX_BYTES)
    def test_host_pass_requires_real_eos_and_finite_progress(self):
        for text in (HOST.replace("eos=true", "eos=false"),
                     HOST.replace("maximumTime=2.0", "maximumTime=nan"),
                     "PRIVATE " + HOST + " PRIVATE", "SECRET"):
            self.assertNotEqual(REPORT.host_control(text)["outcome"], "passed")
        self.assertEqual(REPORT.host_control(HOST)["outcome"], "passed")
    def test_publisher_rejects_unvalidated_or_private_payload(self):
        x = report(); x["private"] = "SECRET"
        with self.assertRaises(ValueError): PUBLISH.comment_body(x)
        x = report(); x["failures"][0]["runtime"]["name"] = "SECRET"
        with self.assertRaises(ValueError): PUBLISH.comment_body(x)
        x = report(); x["candidate"] = "SECRET"
        with self.assertRaises(ValueError): PUBLISH.comment_body(x)
    def test_bounded_comment_labels_probe_and_never_claims_acceptance(self):
        probe = REPORT.probe(candidate=HEAD, run_id=123)
        body = PUBLISH.comment_body(probe)
        self.assertIn("delivery-probe", body)
        self.assertIn(HEAD, body)
        self.assertNotIn("native-results", body)
        body = PUBLISH.comment_body(report())
        self.assertLessEqual(len(body.encode()), PUBLISH.MAX_COMMENT_BYTES)
        self.assertNotIn("SECRET", body)
    def test_publish_verifies_the_exact_new_comment_and_uses_only_official_route(self):
        calls = []
        def transport(method, path, value):
            calls.append((method, path, value))
            if method == "POST":
                return {"id": 17}
            return {"id": 17, "body": PUBLISH.comment_body(report())}
        receipt = PUBLISH.publish(report(), "vForce825/VPlayer", 12, transport)
        self.assertEqual(receipt["comment_id"], 17)
        self.assertEqual([c[:2] for c in calls], [
            ("POST", "/repos/vForce825/VPlayer/issues/12/comments"),
            ("GET", "/repos/vForce825/VPlayer/issues/comments/17")])
        for repository in ("https://private.invalid", "../private", "owner/repo?token=secret"):
            with self.assertRaises(ValueError):
                PUBLISH.publish(report(), repository, 12, transport)
    def test_readback_mismatch_is_delivery_failure(self):
        def transport(method, path, value):
            return {"id": 17} if method == "POST" else {"id": 17, "body": "different"}
        with self.assertRaises(ValueError):
            PUBLISH.publish(report(), "vForce825/VPlayer", 12, transport)

if __name__ == "__main__":
    unittest.main()
