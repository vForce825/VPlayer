#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Bound local Xcode logs and report allowlisted facts from the actual C compile.

Diagnostic evidence is advisory: unavailable/ambiguous input is explicitly
unverified, never an inferred -O0 or a reason to skip native acceptance. The
workflow's pipefail preserves the native build/test result independently.
Never execute log commands, response contents, or a compiler path from a log.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys

SOURCE = 'VPVideoProcessingCPU.c'
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_RESPONSE_FILES = 32
MAX_RESPONSE_DEPTH = 8
MAX_ARGUMENTS = 16384
OPTIMIZATION = re.compile(r'-O(?:[0-4]|s|z|g|fast)?\Z')
VERSION = re.compile(r'Apple clang version [0-9]{1,4}(?:\.[0-9]{1,4}){1,3} \(clang-[0-9A-Za-z._-]{1,80}\)\Z')
TIMESTAMP = re.compile(r'^\d{4}-\d\d-\d\dT\S+\s+')
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
LOOP_FLAGS = ('-fvectorize', '-fno-vectorize')
SLP_FLAGS = ('-fslp-vectorize', '-fno-slp-vectorize')
# These option operands can resemble flags (for example -include '-O0').
OPERAND_OPTIONS = frozenset(('-target', '-arch', '-c', '-o', '-x', '-D', '-U',
    '-I', '-F', '-isystem', '-iquote', '-iframework', '-isysroot', '-include',
    '-imacros', '-include-pch', '-resource-dir', '-serialize-diagnostics',
    '-index-store-path', '-index-unit-output-path', '-MF', '-MT', '-MQ',
    '-ivfsoverlay', '-ivfsstatcache', '-working-directory', '-fmodule-map-file',
    '-fmodule-file', '-iprefix', '-iwithprefix', '-iwithprefixbefore', '-idirafter',
    '-isystem-after', '-iframeworkwithsysroot', '-iwithsysroot', '-B', '-L', '-l',
    '-mllvm', '--config'))


class EvidenceError(Exception):
    pass


def capture(stream, log, limit=MAX_LOG_BYTES):
    """Drain stdin even on truncation/write failure, so diagnostics cannot SIGPIPE the build."""
    status = Path(str(log) + '.capture.json')
    size = 0
    digest = hashlib.sha256()
    output = None
    complete = True
    truncated = False
    try:
        status.unlink(missing_ok=True)
        output = log.open('wb')
    except OSError:
        complete = False
    try:
        while chunk := stream.read(65536):
            if len(chunk) > limit - size:
                truncated = True
            chunk = chunk[:max(0, limit - size)]
            if output and chunk:
                try:
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                except OSError:
                    complete = False
                    try:
                        output.close()
                    except OSError:
                        pass
                    output = None
    finally:
        if output:
            try:
                output.close()
            except OSError:
                complete = False
    try:
        status.write_text(json.dumps({'complete': complete, 'truncated': truncated,
            'bytes': size, 'sha256': digest.hexdigest()}) + '\n')
    except OSError:
        pass  # Missing completion status is unverified when reporting.


def expand_responses(arguments, derived, cwd):
    byte_count = 0
    file_count = 0
    expanded = []

    def expand(tokens, stack=()):
        nonlocal byte_count, file_count
        for token in tokens:
            if not token.startswith('@'):
                expanded.append(token)
                if len(expanded) > MAX_ARGUMENTS:
                    raise EvidenceError('argument_limit')
                continue
            path = Path(token[1:])
            try:
                path = (path if path.is_absolute() else cwd / path).resolve()
            except (OSError, RuntimeError):
                raise EvidenceError('response_unreadable')
            if not path.is_relative_to(derived):
                raise EvidenceError('response_outside_derived_data')
            if path in stack:
                raise EvidenceError('response_cycle')
            if len(stack) >= MAX_RESPONSE_DEPTH:
                raise EvidenceError('response_depth_limit')
            file_count += 1
            if file_count > MAX_RESPONSE_FILES:
                raise EvidenceError('response_file_limit')
            try:
                if not path.is_file():
                    raise OSError('Not a regular response file')
                with path.open('rb') as source:
                    raw = source.read(MAX_RESPONSE_BYTES - byte_count + 1)
            except OSError:
                raise EvidenceError('response_unreadable')
            byte_count += len(raw)
            if byte_count > MAX_RESPONSE_BYTES:
                raise EvidenceError('response_byte_limit')
            try:
                text = raw.decode('utf-8-sig')
                if '\0' in text:
                    raise ValueError('NUL')
                nested = shlex.split(text)
            except (UnicodeError, ValueError):
                raise EvidenceError('response_syntax')
            expand(nested, (*stack, path))

    expand(arguments)
    return expanded, file_count


def driver_options(arguments):
    index = 0
    while index < len(arguments):
        token = arguments[index]
        operand = None
        if token in OPERAND_OPTIONS or (token.startswith('-X') and '=' not in token):
            index += 1
            if index < len(arguments):
                operand = arguments[index]
        yield token, operand
        index += 1


def single_operand(arguments, option):
    values = [value for token, value in driver_options(arguments) if token == option]
    return values[0] if len(values) == 1 else None


def collect(log, derived, cwd, sdk, compiler, version):
    base = {'scope': f'VPlayerPlaybackiOS-Release-{sdk}-arm64', 'source': SOURCE}

    def unverified(reason):
        return dict(base, status='unverified', reason=reason)

    try:
        metadata = Path(str(log) + '.capture.json')
        if metadata.stat().st_size > 1024:
            return unverified('capture_unverified')
        state = json.loads(metadata.read_text())
        if not isinstance(state, dict) or state.get('complete') is not True:
            return unverified('capture_unverified')
        if state.get('truncated') is not False:
            return unverified('log_truncated')
        with log.open('rb') as source:
            raw = source.read(MAX_LOG_BYTES + 1)
        if len(raw) > MAX_LOG_BYTES:
            return unverified('log_byte_limit')
        if state.get('bytes') != len(raw) or state.get('sha256') != hashlib.sha256(raw).hexdigest():
            return unverified('capture_unverified')
        derived, cwd, compiler = derived.resolve(), cwd.resolve(), compiler.resolve()
    except (OSError, ValueError, RuntimeError):
        return unverified('capture_unverified')

    candidates = []
    errors = []
    for raw_line in raw.splitlines():
        if len(raw_line) > MAX_LINE_BYTES:
            return unverified('log_line_limit')
        line = TIMESTAMP.sub('', ANSI.sub('', raw_line.decode('utf-8', errors='replace'))).strip()
        try:
            command = shlex.split(line)
        except ValueError:
            if SOURCE in line and 'clang' in line:
                errors.append('command_syntax')
            continue
        # In particular, builtin-ScanDependencies -- clang is not a compile.
        if not command or Path(command[0]).name != 'clang':
            continue
        try:
            arguments, response_count = expand_responses(command[1:], derived, cwd)
        except EvidenceError as error:
            if SOURCE in line:
                errors.append(str(error))
            continue
        source = single_operand(arguments, '-c')
        if not source or Path(source).name != SOURCE:
            continue
        if any(token in arguments for token in ('-E', '-S', '-fsyntax-only', '-M', '-MM', '-###', '-cc1depscan')):
            continue
        output = single_operand(arguments, '-o')
        if not output:
            continue
        try:
            object_path = (Path(output) if Path(output).is_absolute() else cwd / output).resolve()
            object_parts = object_path.relative_to(derived).parts
        except (ValueError, OSError, RuntimeError):
            continue
        suffix = (f'Release-{sdk}', 'VPlayerPlaybackiOS.build', 'Objects-normal', 'arm64', 'VPVideoProcessingCPU.o')
        if object_parts[-len(suffix):] != suffix:
            continue
        candidates.append((command[0], arguments, response_count))
    if errors:
        return unverified(errors[0])
    if not candidates:
        return unverified('no_matching_compile')
    if len(candidates) != 1:
        return unverified('ambiguous_compile')
    actual_compiler, arguments, response_count = candidates[0]
    try:
        if not Path(actual_compiler).is_absolute() or Path(actual_compiler).resolve() != compiler:
            return unverified('compiler_mismatch')
    except (OSError, RuntimeError):
        return unverified('compiler_mismatch')
    if not VERSION.fullmatch(version):
        return unverified('compiler_version_unverified')
    flags = [token for token, _ in driver_options(arguments)]
    if '--' in flags:
        return unverified('unsupported_driver_separator')
    target = single_operand(arguments, '-target')
    suffix = '-simulator' if sdk == 'iphonesimulator' else ''
    if not target or not re.fullmatch(r'arm64-apple-ios[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}' + suffix, target):
        return unverified('target_unverified')
    if '-arch' in arguments and single_operand(arguments, '-arch') != 'arm64':
        return unverified('arch_unverified')
    optimization = [token for token in flags if OPTIMIZATION.fullmatch(token)]
    loop = [token for token in flags if token in LOOP_FLAGS]
    slp = [token for token in flags if token in SLP_FLAGS]
    if len(optimization) + len(loop) + len(slp) > 32:
        return unverified('selected_flag_limit')
    if any(token.startswith(('-X', '-mllvm', '--config')) for token in flags):
        # Xcode can forward infrastructure options. Preserve useful direct-driver
        # observations, but never label the last flag effective through unknown
        # backend/config overrides. No forwarded operands are published.
        return dict(unverified('unsupported_forwarded_flags'), compiler=version,
            target=target, arch='arm64', response_files=response_count,
            forwarded_flags_present=True, observed_optimization_flags=optimization,
            observed_loop_vectorize_flags=loop, observed_slp_vectorize_flags=slp)
    return dict(base, status='verified', compiler=version, target=target, arch='arm64',
        response_files=response_count, optimization_flags=optimization,
        last_optimization_flag=optimization[-1] if optimization else None,
        loop_vectorize_flags=loop, last_loop_vectorize_flag=loop[-1] if loop else None,
        slp_vectorize_flags=slp, last_slp_vectorize_flag=slp[-1] if slp else None,
        interpretation='ordered_driver_flags_only; absent_flags_do_not_establish_defaults')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    capture_parser = commands.add_parser('capture')
    capture_parser.add_argument('--log', type=Path, required=True)
    report = commands.add_parser('report')
    report.add_argument('--log', type=Path, required=True)
    report.add_argument('--derived-data', type=Path, required=True)
    report.add_argument('--cwd', type=Path, required=True)
    report.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), required=True)
    report.add_argument('--compiler', type=Path, required=True)
    report.add_argument('--compiler-version', required=True)
    args = parser.parse_args()
    if args.command == 'capture':
        capture(sys.stdin.buffer, args.log)
    else:
        result = collect(args.log, args.derived_data, args.cwd, args.sdk, args.compiler, args.compiler_version)
        print('IOS_CPU_CLANG_EVIDENCE=' + json.dumps(result, sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
