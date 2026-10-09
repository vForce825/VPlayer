#!/usr/bin/env python3
"""Portable binary/control regressions; these do not claim a native Xcode build."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import struct
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-release-artifacts.py'


def macho(*, sections=(), symbols=(), libraries=(), platform=7, cpu=0x0100000c, kind=1, sdk=27 << 16):
    commands = []
    for section in sections:
        commands.append(struct.pack('<II16sQQQQiiII', 0x19, 152, b'__DATA', 0, 0, 0, 0, 0, 0, 1, 0)
                        + struct.pack('<16s16sQQIIIIIIII', section.encode(), b'__DATA',
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    commands.append(struct.pack('<IIIIII', 0x32, 24, platform, 27 << 16, sdk, 0))
    for library in libraries:
        name = library.encode() + b'\0'
        size = (24 + len(name) + 7) // 8 * 8
        commands.append(struct.pack('<6I', 0xc, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name)))
    string_table = b'\0'
    entries = b''
    for name, symbol_type in symbols:
        entries += struct.pack('<IBBHQ', len(string_table), symbol_type, 0, 0, 0)
        string_table += name.encode() + b'\0'
    command_bytes = sum(map(len, commands)) + 24
    symoff = 32 + command_bytes
    commands.append(struct.pack('<6I', 2, 24, symoff, len(symbols), symoff + len(entries), len(string_table)))
    return (struct.pack('<8I', 0xfeedfacf, cpu, 0, kind, len(commands), command_bytes, 0, 0)
            + b''.join(commands) + entries + string_table)


def archive(members):
    data = b'!<arch>\n'
    for name, body in members:
        name = name.encode()
        payload = name + body
        header = (('#1/' + str(len(name))).ljust(16) + '0'.ljust(12) + '0'.ljust(6)
                  + '0'.ljust(6) + '100644'.ljust(8) + str(len(payload)).ljust(10) + '`\n').encode()
        data += header + payload + (b'\n' if len(payload) % 2 else b'')
    return data


def fat(slices):
    entries = b''
    payload = b''
    offset = 8 + 20 * len(slices)
    for cpu, body in slices:
        entries += struct.pack('>IIIII', cpu, 0, offset, len(body), 0)
        payload += body
        offset += len(body)
    return struct.pack('>II', 0xcafebabe, len(slices)) + entries + payload


class ReleaseArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if SCRIPT.exists():
            spec = importlib.util.spec_from_file_location('release_artifacts', SCRIPT)
            cls.guard = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.guard)
        else:
            cls.guard = None

    def setUp(self):
        self.assertIsNotNone(self.guard, 'The release artifact guard has not been implemented')
        sdk_patch = patch.object(self.guard, 'sdk_path', return_value=Path('/selected-sdk'), create=True)
        sdk_patch.start()
        self.addCleanup(sdk_patch.stop)

    def inspect(self, data, sdk='iphonesimulator'):
        return self.guard.inspect_bytes(data, sdk)

    def reject(self, data, reason=None):
        with self.assertRaises(self.guard.GuardError) as caught:
            self.inspect(data)
        if reason:
            self.assertIn(reason, str(caught.exception))

    def test_clean_runtime_symbols_and_normal_metadata_are_allowed(self):
        result = self.inspect(macho(sections=['__text', '__unwind_info', '__debug_info'], symbols=[
            ('_swift_task_alloc', 1), ('_swift_beginAccess', 1), ('___stack_chk_fail', 1),
            ('_objc_retain', 1), ('_VPLoadedRangeCoverage', 0xf), ('_profile_user_preferences', 0xf)]))
        self.assertEqual(result['slices'], 1)
        self.assertEqual(result['arches'], ['arm64'])

    def test_defined_undefined_and_local_instrumentation_symbols_fail(self):
        for symbol in ['___llvm_profile_runtime', '___profc_work', '___profd_work',
                       '___llvm_gcov_writeout', '_llvm_gcda_start_file', '___asan_load8',
                       '___tsan_read8', '___ubsan_handle_add_overflow', '___sanitizer_cov_trace_pc_guard',
                       '___cyg_profile_func_enter', '_mcount', '___xray_FunctionEntry']:
            for kind in [1, 0xe, 0xf]:
                with self.subTest(symbol=symbol, kind=kind):
                    self.reject(macho(symbols=[(symbol, kind)]), 'instrumentation_symbol')

    def test_sections_detect_stripped_coverage_and_inline_sancov(self):
        for name in ['__llvm_prf_cnts', '__llvm_prf_data', '__llvm_covmap', '__llvm_covfun',
                     '__llvm_covinit', '__sancov_cntrs', '__sancov_guards', 'xray_instr_map']:
            with self.subTest(name=name):
                self.reject(macho(sections=[name]), 'instrumentation_section')

    def test_sdk_identity_rejects_other_sdk_but_allows_unspecified_object_sdk(self):
        self.inspect(macho(sdk=0))
        self.reject(macho(kind=2, sdk=0), 'macho_sdk_mismatch')
        self.reject(macho(sdk=28 << 16), 'macho_sdk_mismatch')

    def test_linked_sanitizer_dependency_fails_without_symbols(self):
        self.reject(macho(libraries=['@rpath/libclang_rt.asan_iossim_dynamic.dylib']), 'instrumentation_dependency')
        self.inspect(macho(libraries=['/usr/lib/libSystem.B.dylib', '@rpath/libswiftCore.dylib']))

    def test_archive_checks_every_member_including_dead_unlinked_code(self):
        clean = macho(symbols=[('_normal', 0xf)])
        self.assertEqual(self.inspect(archive([('first.o', clean), ('second.o', clean)]))['members'], 2)
        self.reject(archive([('first.o', clean), ('unused.o', macho(sections=['__llvm_prf_cnts']))]))

    def test_every_fat_architecture_and_nested_archive_is_checked(self):
        arm = macho()
        intel = macho(cpu=0x01000007)
        self.assertEqual(self.inspect(fat([(0x0100000c, arm), (0x01000007, intel)]))['arches'], ['arm64', 'x86_64'])
        self.reject(fat([(0x0100000c, arm), (0x01000007, macho(cpu=0x01000007, sections=['__llvm_covmap']))]))
        self.reject(fat([(0x0100000c, arm), (0x0100000c, arm)]))
        self.assertEqual(self.inspect(fat([(0x0100000c, archive([('c.o', arm)])),
                                         (0x01000007, archive([('c.o', intel)]))]))['members'], 2)

    def test_empty_unknown_truncated_and_wrong_platform_fail_closed(self):
        for data in [b'', b'not Mach-O', macho()[:-1], macho(platform=2),
                     archive([])]:
            with self.subTest(data=data[:12]):
                self.reject(data)
        broken = bytearray(macho())
        struct.pack_into('<I', broken, 20, 0xffffffff)
        self.reject(bytes(broken))

    def test_archive_duplicate_basenames_are_scanned_individually(self):
        # libtool-combined FFmpeg archives can legitimately repeat basenames.
        self.assertEqual(self.inspect(archive([('utils.o', macho()), ('utils.o', macho())]))['members'], 2)
        self.reject(archive([('utils.o', macho()), ('utils.o', macho(symbols=[('___asan_load8', 1)]))]))

    def test_archive_index_prefix_cannot_hide_an_instrumented_object(self):
        self.reject(archive([('clean.o', macho()), ('__.SYMDEF-hidden.o', macho(symbols=[('___asan_load8', 1)]))]))
        self.reject(archive([('__.SYMDEF', macho()), ('clean.o', macho())]))

    def test_symbol_and_section_counts_and_offsets_are_bounded(self):
        broken = bytearray(macho())
        struct.pack_into('<I', broken, 32 + 24 + 12, 0xffffffff)
        self.reject(bytes(broken))
        with patch.object(self.guard, 'MAX_FILE_BYTES', 10):
            self.reject(macho())

    def test_compile_flags_respect_operands_but_reject_forwarded_instrumentation(self):
        good = ['-O3', '-g', '-fstack-protector-strong', '-D', '-fprofile-instr-generate',
                '-DLOCAL_PATH=/private/libasan-not-a-library', '-I/private/libasan/include',
                '-fprofile-instr-use=/private/pgo.profdata', '-fno-profile-instr-generate',
                '-fprofile-instrument-use-path=/private/pgo.profdata', '-fprofile-instrument-use=clang',
                '-fprofile-instrument=none', '-Xclang', '-fprofile-instrument-use=llvm']
        self.guard.check_flags(good, 'clang')
        for flags in [['-fprofile-instr-generate'], ['--coverage'], ['-fprofile-arcs'],
                      ['-fsanitize=address'], ['-fsanitize-coverage=inline-8bit-counters'],
                      ['-Xclang', '-fprofile-instrument=clang'], ['-mllvm', '-pgo-instr-gen'],
                      ['-finstrument-functions'], ['-fxray-instrument'], ['-pg'],
                      ['-profile-generate'], ['-profile-coverage-mapping'],
                      ['-Xfrontend', '-sanitize=thread'], ['-ir-profile-generate'],
                      ['-cs-profile-generate=/private/profile'], ['-Xfrontend', '-ir-profile-generate'],
                      ['-Xfrontend', '-cs-profile-generate'], ['-fprofile-instrument=csllvm']]:
            with self.subTest(flags=flags), self.assertRaises(self.guard.GuardError):
                self.guard.check_flags(flags, 'swiftc' if 'profile-generate' in ' '.join(flags) else 'clang')

    def test_linker_sanitizer_runtime_and_profile_counter_injection_fail(self):
        for flags in [['-Wl,-u,___llvm_profile_runtime'], ['-Wl,-lclang_rt.asan_iossim_dynamic'],
                      ['-lclang_rt.profile_ios'], ['-Xlinker', '-lclang_rt.asan_iossim_dynamic'],
                      ['-l', 'clang_rt.asan_iossim_dynamic'], ['-Xlinker', '___llvm_profile_runtime']]:
            with self.subTest(flags=flags), self.assertRaises(self.guard.GuardError):
                self.guard.check_flags(flags, 'clang')
        for flags in [['-Xlinker', '-l', '-Xlinker', 'clang_rt.asan_iossim_dynamic'],
                      ['-Wl,-l,clang_rt.profile_ios']]:
            with self.subTest(flags=flags), self.assertRaises(self.guard.GuardError):
                self.guard.check_flags(flags, 'clang')

    def test_testability_is_only_allowed_for_explicit_framework_test_scope(self):
        for flags in [['-enable-testing'], ['-Xfrontend', '-enable-testing']]:
            with self.subTest(flags=flags), self.assertRaises(self.guard.GuardError):
                self.guard.check_flags(flags, 'swiftc', scope='app')
            self.guard.check_flags(flags, 'swiftc', scope='frameworks')

    def test_release_compile_uses_observed_final_optimization_not_defaults(self):
        self.assertTrue(hasattr(self.guard, 'check_release_compile'))
        for compiler, arguments, expected in [
            ('clang', ['-O0', '-O2'], '-O2'), ('clang', ['-Os'], '-Os'),
            ('clang', ['-Oz'], '-Oz'), ('clang', ['-O3', '-D', '-O0'], '-O3'),
            ('swiftc', ['-Onone', '-O'], '-O'), ('swiftc', ['-Osize'], '-Osize')]:
            with self.subTest(compiler=compiler, arguments=arguments):
                self.assertEqual(self.guard.check_release_compile(arguments, compiler, 'app'), expected)
        for compiler, arguments in [('clang', []), ('clang', ['-O3', '-O0']),
                                    ('swiftc', []), ('swiftc', ['-O', '-Onone']),
                                    ('clang', ['-O3', '-Xclang', '-O0']),
                                    ('clang', ['-O2', '-Xclang=-O0']),
                                    ('swiftc', ['-O', '-Xfrontend', '-Onone']),
                                    ('clang', ['-O3', '-mllvm', '-O0']),
                                    ('clang', ['-O2', '-Xclang', '-disable-llvm-passes']),
                                    ('swiftc', ['-O', '-Xfrontend', '-disable-llvm-optzns']),
                                    ('swiftc', ['-O', '-disable-sil-perf-optzns']),
                                    ('clang', ['-O2', '-Xclang', '-mllvm', '-Xclang', '-O0']),
                                    ('swiftc', ['-O', '-Xfrontend', '-Xllvm', '-Xfrontend', '-O0']),
                                    ('clang', ['-O2', '-Wp,-O0']),
                                    ('clang', ['-O2', '-Xpreprocessor', '-O0'])]:
            with self.subTest(compiler=compiler, arguments=arguments), self.assertRaises(self.guard.GuardError):
                self.guard.check_release_compile(arguments, compiler, 'app')

    def test_shipping_diagnostic_definitions_respect_D_U_and_forwarding(self):
        self.assertTrue(hasattr(self.guard, 'check_release_compile'))
        for flags in [['-DDEBUG'], ['-D', 'DEBUG=1'], ['-DVPLAYER_PERFORMANCE_DIAGNOSTICS'],
                      ['-DDEBUG =1'], ['-D DEBUG=1'], ['-D\tDEBUG\t=1'],
                      ['-DDEBUG/**/=1'],
                      ['-UDEBUG', '-DDEBUG=0'], ['-Xclang', '-DDEBUG'],
                      ['-Xclang=-DDEBUG'], ['-Wp,-DDEBUG'], ['-Wp,-D,DEBUG'],
                      ['-Xpreprocessor', '-D', '-Xpreprocessor', 'DEBUG'],
                      ['-Xcc', '-Wp,-DDEBUG'], ['-Xcc', '-Xpreprocessor', '-Xcc', '-DDEBUG'],
                      ['-Xcc', '-D', '-Xcc', 'DEBUG'], ['-Xfrontend', '-D', '-Xfrontend', 'DEBUG']]:
            with self.subTest(flags=flags), self.assertRaisesRegex(self.guard.GuardError, 'shipping_diagnostic_definition'):
                self.guard.check_release_compile(['-O'] + flags, 'swiftc', 'app')
        for flags in [['-DDEBUG', '-UDEBUG'], ['-D', 'DEBUG=1', '-U', 'DEBUG'],
                      ['-D DEBUG =1', '-U DEBUG '],
                      ['-DDEBUG_OTHER'], ['-DDEBUG$OTHER'], ['-DUSER_LABEL=DEBUG'], ['-D', 'USER_LABEL=VPLAYER_PERFORMANCE_DIAGNOSTICS']]:
            with self.subTest(flags=flags):
                self.guard.check_release_compile(['-O2'] + flags, 'clang', 'app')
        self.guard.check_release_compile(['-O', '-enable-testing'], 'swiftc', 'frameworks')
        with self.assertRaisesRegex(self.guard.GuardError, 'shipping_diagnostic_definition'):
            self.guard.check_release_compile(['-O', '-DDEBUG'], 'swiftc', 'frameworks')

    def test_joined_and_nested_forwarded_instrumentation_is_rejected(self):
        for arguments in [['-Xclang=-fprofile-instrument=clang'],
                          ['-Xcc', '-Xclang=-fprofile-instrument=clang'],
                          ['-Wp,-fprofile-instrument=clang']]:
            with self.subTest(arguments=arguments), self.assertRaises(self.guard.GuardError):
                self.guard.check_flags(arguments, 'clang')

    def test_real_commands_must_cover_all_objects_and_swift_modules(self):
        with tempfile.TemporaryDirectory() as tmp:
            # macOS aliases /var to /private/var; production object discovery
            # supplies resolved paths, so the fixture must do the same.
            root = Path(tmp).resolve()
            cobject = root / 'VPlayerPlaybackiOS.build/VPVideoProcessingCPU.o'
            swiftobject = root / 'VPlayerPlaybackiOS.build/Playback.o'
            mapping = root / 'output.json'
            mapping.write_text(json.dumps({'/private/source.swift': {'object': str(swiftobject)}}))
            commands = (f'/tool/clang -target arm64-apple-ios27.0-simulator -O3 -c /private/VPVideoProcessingCPU.c -o {cobject}\n'
                        f'/tool/swiftc -module-name VPlayerPlayback -target arm64-apple-ios27.0-simulator -O -emit-object -output-file-map {mapping}\n')
            arguments = dict(derived=root, cwd=root, sdk='iphonesimulator',
                             compilers={'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')},
                             objects={cobject, swiftobject}, modules={'VPlayerPlayback'})
            result = self.guard.inspect_commands(commands.encode(), **arguments)
            self.assertEqual(result['c_commands'], 1)
            self.assertEqual(result['swift_commands'], 1)
            with self.assertRaisesRegex(self.guard.GuardError, 'command_sdk_mismatch'):
                self.guard.inspect_commands(commands.encode(), expected_sdk=Path('/selected-sdk'), **arguments)
            # Swift -c is a flag, unlike Clang's following input path.
            swift_c = commands.replace('-O -emit-object', '-O -c').replace(
                '-c -output-file-map', '-c -target arm64-apple-ios27.0-simulator -output-file-map').replace(
                '-module-name VPlayerPlayback -target arm64-apple-ios27.0-simulator', '-module-name VPlayerPlayback')
            self.assertEqual(self.guard.inspect_commands(swift_c.encode(), **arguments)['swift_commands'], 1)
            for change in [commands.splitlines()[0], commands.replace('-O3', '-O3 -fprofile-instr-generate'),
                           commands.replace('/tool/clang', '/other/clang'), '']:
                with self.subTest(change=change[:60]), self.assertRaises(self.guard.GuardError):
                    self.guard.inspect_commands(change.encode(), **arguments)

    def test_response_cycles_missing_files_and_escapes_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            response = root / 'args.rsp'
            response.write_text('@' + str(response))
            for tokens in [['@' + str(response)], ['@' + str(root / 'missing')], ['@/outside/private.rsp']]:
                with self.subTest(tokens=tokens), self.assertRaises(self.guard.GuardError):
                    self.guard.expand_responses(tokens, root, root)

    def test_loader_paths_are_literals_only_in_linker_operand_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for option in ('-install_name', '-rpath'):
                for loader in ('@rpath/Frameworks', '@executable_path/Frameworks', '@loader_path/Frameworks'):
                    for tokens in ([option, loader], ['-Xlinker', option, '-Xlinker', loader]):
                        with self.subTest(tokens=tokens):
                            self.assertEqual(self.guard.expand_responses(tokens, root, root), tokens)
                    for tokens in ([loader], ['-I', loader], [option, '-O2', loader]):
                        with self.subTest(tokens=tokens), self.assertRaises(self.guard.GuardError):
                            self.guard.expand_responses(tokens, root, root)
            # An actual response keeps its boundary checks even as a linker operand.
            with self.assertRaisesRegex(self.guard.GuardError, 'response_outside_derived_data'):
                self.guard.expand_responses(['-rpath', '@/outside/args.rsp'], root, root)
            for tokens in (['-I', '-rpath', '@rpath/Frameworks'],
                           ['-Xclang', '-install_name', '@loader_path/Frameworks'],
                           ['-install_name', '-Xlinker', '@executable_path/Frameworks'],
                           ['-Xlinker', '-L', '-Xlinker', '-rpath', '-Xlinker', '@rpath/Frameworks'],
                           ['-framework', '-rpath', '@rpath/Frameworks'],
                           ['-Xlinker', '-framework', '-Xlinker', '-rpath', '-Xlinker', '@rpath/Frameworks'],
                           ['-Wl,-framework', '-Xlinker', '-rpath', '-Xlinker', '@rpath/Frameworks'],
                           ['-Xlinker=-framework', '-Xlinker', '-rpath', '-Xlinker', '@rpath/Frameworks'],
                           ['-sectcreate', 'SEG', 'SEC', '-rpath', '@rpath/Frameworks'],
                           ['-Xlinker', '-sectcreate', '-Xlinker', 'SEG', '-Xlinker', 'SEC',
                            '-Xlinker', '-rpath', '-Xlinker', '@rpath/Frameworks']):
                with self.subTest(tokens=tokens), self.assertRaises(self.guard.GuardError):
                    self.guard.expand_responses(tokens, root, root)
            response = root / 'link.rsp'
            response.write_text('-install_name @rpath/Frameworks')
            evidence = []
            self.assertEqual(self.guard.expand_responses(['@' + str(response)], root, root, evidence),
                             ['-install_name', '@rpath/Frameworks'])
            self.assertEqual(len(evidence), 1)
            (root / 'rpath').mkdir()
            (root / 'rpath/Frameworks').write_text('-fprofile-instr-generate')
            with self.assertRaises(self.guard.GuardError):
                self.guard.expand_responses(['-install_name', '@rpath/Frameworks'], root, root)

    def test_rejected_cli_never_prints_private_symbol_path_or_raw_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / 'private-user-original-video-secret.o'
            artifact.write_bytes(macho(symbols=[('___llvm_profile_private_secret', 1)]))
            result = subprocess.run(['python3', '-B', str(SCRIPT), 'scan', '--sdk', 'iphonesimulator',
                                     '--artifact', str(artifact)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, '')
            self.assertNotIn('private', result.stdout)
            self.assertNotIn(tmp, result.stdout)
            self.assertIn('instrumentation_symbol', result.stdout)

    def test_capture_drains_input_after_write_and_close_errors(self):
        class BrokenOutput:
            def write(self, value):
                raise OSError('private write path')
            def close(self):
                raise OSError('private close path')
        stream = io.BytesIO(b'x' * 100000)
        original = Path.open
        def replacement(path, *args, **kwargs):
            return BrokenOutput() if path.name == 'build.log' else original(path, *args, **kwargs)
        with tempfile.TemporaryDirectory() as tmp, patch.object(Path, 'open', replacement):
            # read/stream capture must not SIGPIPE the independent build on failure.
            self.guard.capture(stream, Path(tmp) / 'build.log')
        self.assertEqual(stream.tell(), 100000)

    def test_capture_flushes_short_progress_before_requesting_more_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'build.log'
            class LiveStream:
                calls = 0
                def read(inner, size):
                    inner.calls += 1
                    if inner.calls == 1:
                        return b'compiler progress\n'
                    self.assertEqual(log.read_bytes(), b'compiler progress\n')
                    return b''
            self.assertTrue(self.guard.capture(LiveStream(), log))

    def test_cli_capture_exposes_short_real_pipe_progress_before_EOF(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'build.log'
            process = subprocess.Popen(['python3', '-B', str(SCRIPT), 'capture', '--log', str(log)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                process.stdin.write(b'compiler progress\n')
                process.stdin.flush()
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if log.exists() and log.read_bytes() == b'compiler progress\n':
                        break
                    time.sleep(0.01)
                self.assertIsNone(process.poll())
                self.assertEqual(log.read_bytes(), b'compiler progress\n')
            finally:
                process.stdin.close()
                process.stdin = None
                stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, b'')

    def test_log_capture_integrity_must_be_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'build.log'
            self.guard.capture(io.BytesIO(b'hello\n'), log)
            self.assertEqual(self.guard.read_capture(log), b'hello\n')
            log.write_bytes(b'changed\n')
            with self.assertRaises(self.guard.GuardError):
                self.guard.read_capture(log)

    def test_malformed_capture_and_plist_roots_fail_without_tracebacks(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'source_snapshot',
                return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, app = self.fixture(Path(tmp))
            sidecar = Path(str(args.build_log) + '.capture.json')
            original = sidecar.read_bytes()
            sidecar.write_text('[]')
            with self.assertRaises(self.guard.GuardError):
                self.guard.read_capture(args.build_log)
            with self.assertRaises(self.guard.GuardError):
                self.guard.verify(args)
            sidecar.write_bytes(original)
            (app / 'Info.plist').write_bytes(plistlib.dumps(['unexpected root']))
            with self.assertRaises(self.guard.GuardError):
                self.guard.verify(args)

    def test_symlink_loop_cli_uses_only_a_fixed_failure_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'private-symlink-loop.o'
            path.symlink_to(path)
            result = subprocess.run(['python3', '-B', str(SCRIPT), 'scan', '--sdk', 'iphonesimulator',
                                     '--artifact', str(path)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, '')
            self.assertNotIn('private', result.stdout)
            self.assertNotIn(tmp, result.stdout)

    def test_log_truncation_returns_failure_after_draining_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'build.log'
            stream = io.BytesIO(b'long input')
            self.assertFalse(self.guard.capture(stream, log, limit=4))
            self.assertEqual(stream.tell(), len(b'long input'))
            with self.assertRaises(self.guard.GuardError):
                self.guard.read_capture(log)

    def fixture(self, root):
        derived = root / 'DerivedData'
        build = derived / 'Build/Intermediates.noindex/VPlayer.build/Release-iphonesimulator'
        app = derived / 'Build/Products/Release-iphonesimulator/VPlayer.app'
        commands = []
        for target, module, bundle, identifier in [
            ('VPlayeriOS', 'VPlayer', app, 'com.vforce.vplayer'),
            ('VPlayerCoreiOS', 'VPlayerCore', app / 'Frameworks/VPlayerCore.framework', 'com.vplayer.core.ios'),
            ('VPlayerPlaybackiOS', 'VPlayerPlayback', app / 'Frameworks/VPlayerPlayback.framework', 'com.vplayer.playback.ios')]:
            bundle.mkdir(parents=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleExecutable': module}))
            (bundle / module).write_bytes(macho(kind=2 if module == 'VPlayer' else 6))
            commands.append(f'/tool/clang -target arm64-apple-ios27.0-simulator -isysroot /selected-sdk -o {bundle / module}')
            object_root = build / (target + '.build/Objects-normal/arm64')
            object_root.mkdir(parents=True)
            output = object_root / (module + '.o')
            output.write_bytes(macho())
            commands.append(f'/tool/swiftc -module-name {module} -target arm64-apple-ios27.0-simulator -sdk /selected-sdk -O -emit-object -o {output}')
            if module == 'VPlayerPlayback':
                for source in (SCRIPT.parents[1] / 'Sources/VPlayerPlayback').rglob('*'):
                    if source.suffix in ('.c', '.m', '.mm'):
                        output = object_root / (source.stem + '.o')
                        output.write_bytes(macho())
                        commands.append(f'/tool/clang -target arm64-apple-ios27.0-simulator -isysroot /selected-sdk -O3 -c {source} -o {output}')
        log = root / 'build.log'
        self.guard.capture(io.BytesIO(('\n'.join(commands) + '\n').encode()), log)
        ffmpeg = root / 'FFmpeg/libFFmpeg.a'
        ffmpeg.parent.mkdir()
        ffmpeg.write_bytes(archive([('clean.o', macho())]))
        return SimpleNamespace(derived_data=derived, sdk='iphonesimulator', scope='app',
                               archive=None, ffmpeg=[ffmpeg], build_log=log), app

    def test_production_bundle_objects_and_reuse_receipt_are_bound(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'compiler_paths', return_value={
                'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
             patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, app = self.fixture(Path(tmp))
            result = self.guard.verify(args)
            self.assertEqual(result['status'], 'passed')
            self.assertEqual(self.guard.verify(args), result)
            (app / 'VPlayer').write_bytes(macho(kind=2, symbols=[('_changed_but_clean', 0xf)]))
            with self.assertRaisesRegex(self.guard.GuardError, 'artifact_receipt_mismatch'):
                self.guard.verify(args)

    def test_missing_framework_object_and_wrong_bundle_identity_fail(self):
        for damage in ['framework', 'c_object', 'bundle', 'symlink']:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as tmp, \
                 patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
                args, app = self.fixture(Path(tmp))
                if damage == 'framework':
                    (app / 'Frameworks/VPlayerCore.framework/VPlayerCore').unlink()
                elif damage == 'c_object':
                    next(args.derived_data.rglob('VPVideoProcessingCPU.o')).unlink()
                elif damage == 'bundle':
                    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'wrong'}))
                else:
                    outside = Path(tmp) / 'outside'
                    outside.write_bytes(macho())
                    (app / 'outside.dylib').symlink_to(outside)
                with self.assertRaises((self.guard.GuardError, OSError)):
                    self.guard.verify(args)

    def test_source_change_invalidates_capture(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'source_snapshot',
                return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, _ = self.fixture(Path(tmp))
            with patch.object(self.guard, 'source_snapshot', return_value={'head': 'c' * 40, 'tree': 'd' * 40}):
                with self.assertRaisesRegex(self.guard.GuardError, 'source_identity_mismatch'):
                    self.guard.verify(args)

    def test_production_verification_requires_static_archive(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'compiler_paths', return_value={
                'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
             patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, _ = self.fixture(Path(tmp))
            args.ffmpeg = None
            with self.assertRaisesRegex(self.guard.GuardError, 'ffmpeg_archive_required'):
                self.guard.verify(args)

    def test_response_file_edit_invalidates_previously_verified_receipt(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'compiler_paths', return_value={
                'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
             patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, _ = self.fixture(Path(tmp))
            response = args.derived_data / 'flags.rsp'
            response.write_text('-O3')
            raw = args.build_log.read_bytes().replace(b'-O3', ('@' + str(response)).encode())
            self.guard.capture(io.BytesIO(raw), args.build_log)
            self.guard.verify(args)
            response.write_text('-O2')
            with self.assertRaisesRegex(self.guard.GuardError, 'artifact_receipt_mismatch'):
                self.guard.verify(args)

    def test_link_command_instrumentation_cannot_hide_behind_clean_compile(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(self.guard, 'compiler_paths', return_value={
                'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
             patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
            args, _ = self.fixture(Path(tmp))
            raw = args.build_log.read_bytes().replace(b'-o ', b'-Wl,-u,___llvm_profile_runtime -o ', 1)
            self.guard.capture(io.BytesIO(raw), args.build_log)
            with self.assertRaisesRegex(self.guard.GuardError, 'instrumentation_link_flag'):
                self.guard.verify(args)

    def test_actual_object_commands_enforce_optimization_and_diagnostic_policy(self):
        for before, after, reason in [
            (b'-O3 -c', b'-O3 -O0 -c', 'unoptimized_release_compile'),
            (b'-O -emit-object', b'-O -Onone -emit-object', 'unoptimized_release_compile'),
            (b'-O3 -c', b'-c', 'optimization_flag_missing'),
            (b'-O -emit-object', b'-O -DDEBUG -emit-object', 'shipping_diagnostic_definition'),
            (b'-O3 -c', b'-O3 -D VPLAYER_PERFORMANCE_DIAGNOSTICS -c', 'shipping_diagnostic_definition')]:
            with self.subTest(after=after), tempfile.TemporaryDirectory() as tmp, \
                 patch.object(self.guard, 'compiler_paths', return_value={'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
                 patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
                args, _ = self.fixture(Path(tmp))
                raw = args.build_log.read_bytes().replace(before, after, 1)
                self.guard.capture(io.BytesIO(raw), args.build_log)
                with self.assertRaisesRegex(self.guard.GuardError, reason):
                    self.guard.verify(args)

    def test_app_must_be_executable_and_objects_must_be_object_files(self):
        for damaged in ['app', 'object']:
            with self.subTest(damaged=damaged), tempfile.TemporaryDirectory() as tmp, \
                 patch.object(self.guard, 'compiler_paths', return_value={'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
                 patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
                args, app = self.fixture(Path(tmp))
                path = app / 'VPlayer' if damaged == 'app' else next(args.derived_data.rglob('VPVideoProcessingCPU.o'))
                path.write_bytes(macho(kind=1 if damaged == 'app' else 6))
                with self.assertRaisesRegex(self.guard.GuardError, 'artifact_kind_mismatch'):
                    self.guard.verify(args)

    def test_framework_scope_and_archive_paths_use_the_exact_products(self):
        import shutil
        for archive_mode in [False, True]:
            with self.subTest(archive=archive_mode), tempfile.TemporaryDirectory() as tmp, \
                 patch.object(self.guard, 'compiler_paths', return_value={'clang': Path('/tool/clang'), 'swiftc': Path('/tool/swiftc')}), \
                 patch.object(self.guard, 'source_snapshot', return_value={'head': 'a' * 40, 'tree': 'b' * 40}):
                root = Path(tmp)
                args, app = self.fixture(root)
                raw = args.build_log.read_text()
                if archive_mode:
                    old = args.derived_data / 'Build/Intermediates.noindex/VPlayer.build/Release-iphonesimulator'
                    new = args.derived_data / 'Build/Intermediates.noindex/ArchiveIntermediates/VPlayeriOSRelease/IntermediateBuildFilesPath/VPlayer.build/Release-iphoneos'
                    new.parent.mkdir(parents=True)
                    shutil.move(old, new)
                    args.archive = root / 'VPlayer.xcarchive'
                    destination = args.archive / 'Products/Applications/VPlayer.app'
                    destination.parent.mkdir(parents=True)
                    shutil.move(app, destination)
                    for path in list(new.rglob('*.o')) + [destination / 'VPlayer'] + list(destination.glob('Frameworks/*.framework/VPlayer*')):
                        kind = 1 if path.suffix == '.o' else 2 if path.name == 'VPlayer' else 6
                        path.write_bytes(macho(platform=2, kind=kind))
                    raw = raw.replace(str(old), str(new)).replace('27.0-simulator', '27.0')
                    raw = raw.replace(str(app), str(destination))
                    args.sdk = 'iphoneos'
                    args.ffmpeg[0].write_bytes(archive([('clean.o', macho(platform=2))]))
                else:
                    product = app.parent
                    for path in (app / 'Frameworks').iterdir():
                        shutil.move(path, product / path.name)
                    args.scope = 'frameworks'
                    raw = '\n'.join(line for line in raw.splitlines() if '-module-name VPlayer ' not in line)
                    raw = raw.replace(str(app / 'Frameworks'), str(product))
                self.guard.capture(io.BytesIO(raw.encode()), args.build_log)
                self.assertEqual(self.guard.verify(args)['status'], 'passed')


if __name__ == '__main__':
    unittest.main()
