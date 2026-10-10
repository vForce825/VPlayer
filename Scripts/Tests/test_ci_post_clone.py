#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise the real post-clone hook without downloading or building FFmpeg."""

import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_DIRECTORIES = {"ios": "Artifacts-iOS", "tvos": "Artifacts"}


class PostCloneTests(unittest.TestCase):
    def run_hook(self, platform=None, *, cached=(), jq=True, brew=True,
                 repository_variable=True, **environment):
        with tempfile.TemporaryDirectory(prefix="vplayer post clone ") as temporary:
            root = Path(temporary).resolve()
            (root / "Scripts").mkdir()
            (root / "ci_scripts").mkdir()
            (root / "bin").mkdir()
            hook = root / "ci_scripts/ci_post_clone.sh"
            shutil.copyfile(ROOT / "ci_scripts/ci_post_clone.sh", hook)
            # An isolated PATH prevents dependency installation or network access.
            (root / "bin/dirname").symlink_to(shutil.which("dirname"))
            command_stub = f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json
                import os
                import sys
                from pathlib import Path

                command = Path(sys.argv[0]).name
                args = sys.argv[1:]
                root = Path(os.environ["FIXTURE_ROOT"])
                with (root / "calls.jsonl").open("a") as log:
                    log.write(json.dumps({"command": command, "args": args,
                        "cwd": str(Path.cwd()),
                        "no_auto_update": os.environ.get("HOMEBREW_NO_AUTO_UPDATE")}) + "\\n")
                if command == "brew":
                    sys.exit(int(os.environ.get("BREW_EXIT", "0")))
                if command == "audit-ffmpeg.sh":
                    sys.exit(int(os.environ.get("AUDIT_EXIT", "0")))
                if command == "build-ffmpeg.sh":
                    status = int(os.environ.get("BUILD_EXIT", "0"))
                    if status:
                        sys.exit(status)
                    platform = "tvos"
                    if args:
                        if len(args) != 2 or args[0] != "--platform" or args[1] not in ("ios", "tvos"):
                            sys.exit(64)
                        platform = args[1]
                    platform = os.environ.get("BUILD_OUTPUT_PLATFORM", platform)
                    directory = {"ios": "Artifacts-iOS", "tvos": "Artifacts"}[platform]
                    artifact = root / "Vendor/FFmpeg" / directory / "FFmpeg.xcframework"
                    artifact.mkdir(parents=True, exist_ok=True)
                    if os.environ.get("BUILD_OMIT_INFO") != "1":
                        (artifact / "Info.plist").write_text("fixture")
            ''')
            commands = ["Scripts/build-ffmpeg.sh", "Scripts/audit-ffmpeg.sh"]
            if jq:
                commands.append("bin/jq")
            if brew:
                commands.append("bin/brew")
            for command in commands:
                path = root / command
                path.write_text(command_stub)
                path.chmod(0o755)
            for cached_platform in cached:
                artifact = root / "Vendor/FFmpeg" / ARTIFACT_DIRECTORIES[cached_platform] / "FFmpeg.xcframework"
                artifact.mkdir(parents=True)
                (artifact / "Info.plist").write_text("fixture")
            env = {"PATH": str(root / "bin"), "FIXTURE_ROOT": str(root), **environment}
            if repository_variable:
                env["CI_PRIMARY_REPOSITORY_PATH"] = str(root)
            if platform is not None:
                env["CI_PRODUCT_PLATFORM"] = platform
            result = subprocess.run(["/bin/sh", str(hook)], cwd=root / "bin",
                                    env=env, capture_output=True, text=True, timeout=5)
            calls_path = root / "calls.jsonl"
            calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
            artifacts = [name for name, directory in ARTIFACT_DIRECTORIES.items()
                         if (root / "Vendor/FFmpeg" / directory / "FFmpeg.xcframework/Info.plist").is_file()]
            return result, calls, artifacts, root

    def test_builds_selected_platform_when_only_other_platform_is_cached(self):
        for product, selected, other in [("iOS", "ios", "tvos"), ("tvOS", "tvos", "ios")]:
            for cached in [(), (other,)]:
                with self.subTest(product=product, cached=cached):
                    result, calls, artifacts, root = self.run_hook(product, cached=cached, CI_XCODE_CLOUD="TRUE")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual([(call["command"], call["args"]) for call in calls],
                                     [("build-ffmpeg.sh", ["--platform", selected])])
                    self.assertEqual(calls[0]["cwd"], str(root))
                    self.assertIn(selected, artifacts)

    def test_audits_only_selected_platform_when_both_artifacts_exist(self):
        for product, selected in [("iOS", "ios"), ("tvOS", "tvos")]:
            with self.subTest(product=product):
                result, calls, _, root = self.run_hook(product, cached=("ios", "tvos"), CI_XCODE_CLOUD="TRUE")
                self.assertEqual(result.returncode, 0, result.stderr)
                artifact = root / "Vendor/FFmpeg" / ARTIFACT_DIRECTORIES[selected] / "FFmpeg.xcframework"
                self.assertEqual([(call["command"], call["args"]) for call in calls],
                                 [("audit-ffmpeg.sh", ["--platform", selected, str(artifact)])])
                self.assertEqual(calls[0]["cwd"], str(root))

    def test_unsupported_platform_fails_before_install_or_artifact_commands(self):
        for platform in ["macOS", "watchOS", "visionOS", "ios", "tvos", "unknown"]:
            with self.subTest(platform=platform):
                result, calls, artifacts, _ = self.run_hook(platform, jq=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CI_PRODUCT_PLATFORM", result.stderr)
                self.assertIn(platform, result.stderr)
                self.assertEqual(calls, [])
                self.assertEqual(artifacts, [])

    def test_missing_xcode_cloud_platform_fails_before_installing_dependencies(self):
        for platform in [None, ""]:
            with self.subTest(platform=platform):
                result, calls, _, _ = self.run_hook(platform, jq=False, CI_XCODE_CLOUD="TRUE")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CI_PRODUCT_PLATFORM", result.stderr)
                self.assertEqual(calls, [])

    def test_existing_github_callers_without_platform_keep_tvos_default(self):
        for platform in [None, ""]:
            with self.subTest(platform=platform):
                result, calls, artifacts, _ = self.run_hook(platform, CI="true", GITHUB_ACTIONS="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[0]["args"], ["--platform", "tvos"])
                self.assertEqual(artifacts, ["tvos"])
                self.assertIn("tvOS", result.stdout)

    def test_repository_path_can_be_resolved_from_hook_location(self):
        result, calls, artifacts, root = self.run_hook("iOS", repository_variable=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0]["cwd"], str(root))
        self.assertEqual(artifacts, ["ios"])

    def test_missing_jq_installs_once_without_homebrew_auto_update(self):
        result, calls, _, _ = self.run_hook("iOS", jq=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["command"] for call in calls], ["brew", "build-ffmpeg.sh"])
        self.assertEqual(calls[0]["args"], ["install", "jq"])
        self.assertEqual(calls[0]["no_auto_update"], "1")

    def test_missing_jq_and_homebrew_fails_before_artifact_commands(self):
        result, calls, _, _ = self.run_hook("iOS", jq=False, brew=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jq and Homebrew are unavailable", result.stderr)
        self.assertEqual(calls, [])

    def test_dependency_and_artifact_failures_propagate(self):
        cases = [({"jq": False, "BREW_EXIT": "7"}, "brew", 7),
                 ({"BUILD_EXIT": "9"}, "build-ffmpeg.sh", 9),
                 ({"cached": ("ios",), "AUDIT_EXIT": "11"}, "audit-ffmpeg.sh", 11)]
        for options, command, status in cases:
            with self.subTest(command=command):
                result, calls, _, _ = self.run_hook("iOS", **options)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual([call["command"] for call in calls], [command])

    def test_successful_build_must_produce_selected_artifact_info(self):
        for options in [{"BUILD_OMIT_INFO": "1"}, {"BUILD_OUTPUT_PLATFORM": "tvos"}]:
            with self.subTest(options=options):
                result, calls, _, _ = self.run_hook("iOS", **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call["command"] for call in calls], ["build-ffmpeg.sh"])


if __name__ == "__main__":
    unittest.main()
