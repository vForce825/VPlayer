#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise actual log/response parsing, bounded capture, and public output."""
import importlib.util
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Scripts/report-ios-clang-evidence.py'
VERSION = 'Apple clang version 18.0.0 (clang-1800.0.1)'


class ClangEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), 'Bounded Clang evidence collector is missing')
        spec = importlib.util.spec_from_file_location('clang_evidence', SCRIPT)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.derived = self.root / 'Derived Data'
        self.derived.mkdir()
        self.compiler = self.root / 'Xcode 27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
        self.log = self.root / 'build.log'

    def command(self, *flags, sdk='iphoneos', compiler=None, output=None):
        output = output or self.derived / ('Build/Intermediates.noindex/VPlayer.build/'
            f'Release-{sdk}/VPlayerPlaybackiOS.build/Objects-normal/arm64/VPVideoProcessingCPU.o')
        target = 'arm64-apple-ios27.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
        return shlex.join([str(compiler or self.compiler), '-target', target, *flags,
            '-c', str(self.root / 'Private Source/VPVideoProcessingCPU.c'), '-o', str(output)])

    def collect(self, text, sdk='iphoneos', version=VERSION):
        self.helper.capture(io.BytesIO(text.encode()), self.log)
        return self.helper.collect(self.log, self.derived, self.root, sdk, self.compiler, version)

    def assert_unverified(self, result, reason):
        self.assertEqual(result['status'], 'unverified')
        self.assertEqual(result['reason'], reason)
        self.assertNotIn('last_optimization_flag', result)
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_quoted_paths_ordered_flags_and_public_allowlist(self):
        result = self.collect(self.command('-O0', '-Os', '-O3', '-fno-vectorize',
            '-fvectorize', '-fslp-vectorize', '-fno-slp-vectorize', '-DPRIVATE=must-not-publish'))
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(result['optimization_flags'], ['-O0', '-Os', '-O3'])
        self.assertEqual(result['last_optimization_flag'], '-O3')
        self.assertEqual(result['last_loop_vectorize_flag'], '-fvectorize')
        self.assertEqual(result['last_slp_vectorize_flag'], '-fno-slp-vectorize')
        self.assertEqual(result['target'], 'arm64-apple-ios27.0')
        self.assertEqual(result['arch'], 'arm64')
        self.assertEqual(result['compiler'], VERSION)
        self.assertEqual(result['source'], 'VPVideoProcessingCPU.c')
        for private in ('must-not-publish', 'Private Source', str(self.root), 'logged_argv'):
            self.assertNotIn(private, json.dumps(result))

    def test_nested_responses_preserve_order_and_relative_paths_use_compile_cwd(self):
        inner = self.derived / 'inner args.resp'; inner.write_text('-O2 -fvectorize')
        outer = self.derived / 'outer.resp'
        outer.write_text(shlex.join(['-O0', '@' + str(inner.relative_to(self.root)), '-Os']))
        result = self.collect(self.command('@' + str(outer), '-O3'), sdk='iphoneos')
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(result['optimization_flags'], ['-O0', '-O2', '-Os', '-O3'])
        self.assertEqual(result['response_files'], 2)

    def test_simulator_scope_is_distinct_from_device(self):
        text = self.command('-O2', sdk='iphonesimulator')
        result = self.collect(text, sdk='iphonesimulator')
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(result['target'], 'arm64-apple-ios27.0-simulator')
        self.assert_unverified(self.collect(text), 'no_matching_compile')

    def test_scan_titles_wrappers_and_preprocessor_are_not_compile_evidence(self):
        command = self.command('-Os')
        for text in ('CompileC ' + command, 'builtin-ScanDependencies -- ' + command,
                     command.replace(' -c ', ' -E '), command + ' -fsyntax-only', command + ' -cc1depscan'):
            with self.subTest(text=text[:40]):
                self.assert_unverified(self.collect(text), 'no_matching_compile')
        self.assertEqual(self.collect('builtin-ScanDependencies -- ' + command + '\n' + command)['status'], 'verified')

    def test_multiple_compile_commands_are_ambiguous_even_with_equal_flags(self):
        text = self.command('-Os')
        self.assert_unverified(self.collect(text + '\n' + text), 'ambiguous_compile')

    def test_missing_response_is_not_an_optimization_default(self):
        self.assert_unverified(self.collect(self.command('@' + str(self.derived / 'gone.resp'), '-Os')),
            'response_unreadable')

    def test_response_path_escape_and_symlink_escape_are_rejected(self):
        private = self.root / 'private.resp'; private.write_text('-O0 -DSECRET=must-not-publish')
        link = self.derived / 'link.resp'; link.symlink_to(private)
        for response in (private, link, self.derived / '../private.resp'):
            self.assert_unverified(self.collect(self.command('@' + str(response))), 'response_outside_derived_data')

    def test_response_cycles_depth_size_and_argument_count_are_bounded(self):
        response = self.derived / 'self.resp'; response.write_text(shlex.join(['@' + str(response)]))
        self.assert_unverified(self.collect(self.command('@' + str(response))), 'response_cycle')
        paths = [self.derived / f'level{i}.resp' for i in range(10)]
        for index, path in enumerate(paths):
            path.write_text(shlex.join(['@' + str(paths[index + 1])]) if index + 1 < len(paths) else '-Os')
        self.assert_unverified(self.collect(self.command('@' + str(paths[0]))), 'response_depth_limit')
        response.write_text('x' * (self.helper.MAX_RESPONSE_BYTES + 1))
        self.assert_unverified(self.collect(self.command('@' + str(response))), 'response_byte_limit')
        response.write_text('-Os ' * (self.helper.MAX_ARGUMENTS + 1))
        self.assert_unverified(self.collect(self.command('@' + str(response))), 'argument_limit')

    def test_response_file_count_is_bounded(self):
        paths = [self.derived / f'file{i}.resp' for i in range(self.helper.MAX_RESPONSE_FILES + 1)]
        for path in paths:
            path.write_text('-Os')
        self.assert_unverified(self.collect(self.command(*['@' + str(path) for path in paths])), 'response_file_limit')

    def test_no_flags_means_absent_not_O0_or_vectorization_disabled(self):
        result = self.collect(self.command())
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(result['optimization_flags'], [])
        self.assertIsNone(result['last_optimization_flag'])
        self.assertIsNone(result['last_loop_vectorize_flag'])
        self.assertIsNone(result['last_slp_vectorize_flag'])

    def test_compiler_identity_must_match_selected_xcode(self):
        self.assert_unverified(self.collect(self.command('-Os', compiler=self.root / 'other/clang')), 'compiler_mismatch')
        self.assert_unverified(self.collect(self.command('-Os'), version='private unrecognized version'), 'compiler_version_unverified')

    def test_public_compiler_and_target_values_have_hard_size_limits(self):
        version = 'Apple clang version 18.0.0 (clang-' + '1' * 10000 + ')'
        self.assert_unverified(self.collect(self.command('-Os'), version=version), 'compiler_version_unverified')
        command = self.command('-Os').replace('arm64-apple-ios27.0', 'arm64-apple-ios' + '2' * 10000)
        self.assert_unverified(self.collect(command), 'target_unverified')

    def test_object_path_must_be_inside_exact_derived_data(self):
        output = self.root / 'elsewhere/Release-iphoneos/VPlayerPlaybackiOS.build/Objects-normal/arm64/VPVideoProcessingCPU.o'
        self.assert_unverified(self.collect(self.command('-Os', output=output)), 'no_matching_compile')

    def test_malformed_response_or_command_is_explicitly_unverified(self):
        response = self.derived / 'broken.resp'; response.write_text("-Os 'unfinished")
        self.assert_unverified(self.collect(self.command('@' + str(response))), 'response_syntax')
        self.assert_unverified(self.collect(self.command('-Os') + " 'unfinished"), 'command_syntax')

    def test_driver_forwarding_cannot_silently_override_reported_optimization(self):
        for option in ('-Xclang', '-Xassembler', '-Xpreprocessor', '-Xlinker', '-Xarch_arm64'):
            result = self.collect(self.command('-Os', option, '-O0'))
            self.assert_unverified(result, 'unsupported_forwarded_flags')
            self.assertEqual(result['observed_optimization_flags'], ['-Os'])
            self.assertTrue(result['forwarded_flags_present'])
        separated = self.collect(self.command('-Os') + ' -- -O0')
        self.assert_unverified(separated, 'unsupported_driver_separator')
        self.assertNotIn('observed_optimization_flags', separated)

    def test_xcode_forwarded_infrastructure_preserves_only_observed_driver_facts(self):
        result = self.collect(self.command('-Os', '-fvectorize', '-Xclang', '-ivfsstatcache',
            '-Xclang', '/private/must-not-publish/cache', '-fno-slp-vectorize'))
        self.assert_unverified(result, 'unsupported_forwarded_flags')
        self.assertEqual(result['compiler'], VERSION)
        self.assertEqual(result['observed_optimization_flags'], ['-Os'])
        self.assertEqual(result['observed_loop_vectorize_flags'], ['-fvectorize'])
        self.assertEqual(result['observed_slp_vectorize_flags'], ['-fno-slp-vectorize'])
        self.assertNotIn('must-not-publish', json.dumps(result))

    def test_option_operands_are_not_optimization_or_vectorization_flags(self):
        for option in ('-D', '-include', '-iprefix', '-iwithprefix', '-iwithprefixbefore', '-idirafter'):
            result = self.collect(self.command('-Os', option, '-O0', '-include', '-fno-vectorize'))
            self.assertEqual(result['optimization_flags'], ['-Os'])
            self.assertIsNone(result['last_loop_vectorize_flag'])

    def test_response_special_files_are_rejected_without_blocking(self):
        import os
        response = self.derived / 'pipe.resp'
        os.mkfifo(response)
        command = [sys.executable, str(SCRIPT), 'report', '--log', str(self.log),
            '--derived-data', str(self.derived), '--cwd', str(self.root), '--sdk', 'iphoneos',
            '--compiler', str(self.compiler), '--compiler-version', VERSION]
        self.helper.capture(io.BytesIO(self.command('@' + str(response)).encode()), self.log)
        run = subprocess.run(command, capture_output=True, text=True, timeout=1)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout.split('=', 1)[1])['reason'], 'response_unreadable')

    def test_capture_is_bounded_and_drains_input_without_failing_native_pipeline(self):
        stream = io.BytesIO(b'x' * 1000)
        self.helper.capture(stream, self.log, limit=100)
        self.assertEqual(stream.tell(), 1000)
        self.assertLessEqual(self.log.stat().st_size, 100)
        result = self.helper.collect(self.log, self.derived, self.root, 'iphoneos', self.compiler, VERSION)
        self.assert_unverified(result, 'log_truncated')
        self.helper.capture(io.BytesIO(b'hello'), self.root / 'missing/log')

    def test_capture_write_and_close_failures_still_drain_the_entire_pipe(self):
        class BrokenOutput:
            def write(self, chunk):
                raise OSError('disk write failed')
            def close(self):
                raise OSError('flush also failed')
        class LogDestination:
            def __str__(inner):
                return str(self.log)
            def open(inner, mode):
                return BrokenOutput()
        stream = io.BytesIO(b'x' * 131072)
        self.helper.capture(stream, LogDestination())
        self.assertEqual(stream.tell(), 131072)
        state = json.loads(Path(str(self.log) + '.capture.json').read_text())
        self.assertFalse(state['complete'])

    def test_missing_log_or_capture_status_never_claims_evidence(self):
        result = self.helper.collect(self.log, self.derived, self.root, 'iphoneos', self.compiler, VERSION)
        self.assert_unverified(result, 'capture_unverified')
        self.log.write_text(self.command('-Os'))
        result = self.helper.collect(self.log, self.derived, self.root, 'iphoneos', self.compiler, VERSION)
        self.assert_unverified(result, 'capture_unverified')

    def test_cli_report_is_small_allowlisted_json_and_advisory(self):
        self.collect(self.command('-O2', '-DPRIVATE=must-not-publish'))
        command = [sys.executable, str(SCRIPT), 'report', '--log', str(self.log),
            '--derived-data', str(self.derived), '--cwd', str(self.root), '--sdk', 'iphoneos',
            '--compiler', str(self.compiler), '--compiler-version', VERSION]
        run = subprocess.run(command, capture_output=True, text=True, timeout=3)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, '')
        self.assertLess(len(run.stdout), 2048)
        self.assertEqual(json.loads(run.stdout.split('=', 1)[1])['status'], 'verified')
        self.assertNotIn('must-not-publish', run.stdout)
        self.log.unlink()
        run = subprocess.run(command, capture_output=True, text=True, timeout=3)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(json.loads(run.stdout.split('=', 1)[1])['status'], 'unverified')


if __name__ == '__main__':
    unittest.main()
