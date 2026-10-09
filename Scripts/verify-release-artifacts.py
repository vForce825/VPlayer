#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Fail-closed Release instrumentation gate over real commands and Mach-O bytes.

Only fixed category names, counts, hashes and public target labels are emitted.
No log command is executed; no raw symbol, source path, macro or diagnostic is
published. `scan` is an artifact-local control, not production acceptance.
Coverage formats: clang.llvm.org/docs/SourceBasedCodeCoverage.html and LLVM's
InstrProfData.inc / SanitizerCoverage.cpp. Normal Swift runtime, stack protector,
unwind and debug metadata are intentionally not instrumentation signatures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import struct
import subprocess
import sys

MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
MAX_LOG_BYTES = 128 * 1024 * 1024
MAX_FILES = 10000
MAX_MEMBERS = 30000
MAX_SYMBOLS = 2000000
MAX_COMMANDS = 100000
MAX_LINE_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
SDK_PLATFORMS = {'iphoneos': 2, 'appletvos': 3, 'iphonesimulator': 7, 'appletvsimulator': 8}
CPUS = {0x0100000c: 'arm64', 0x01000007: 'x86_64'}
MAGICS = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'!<ar')
SYMBOL = re.compile(r'^(?:llvm_(?:profile|gcov|gcda)_|prof[cdnv]_|'
    r'asan_|hwasan_|tsan_|msan_|ubsan_|lsan_|dfsan_|sanitizer_|sancov_|'
    r'cyg_profile_func_|xray_|mcount$|fentry$|gcov_)')
SECTION = re.compile(r'^(?:llvm_prf|llvm_cov|sancov_|xray_)')
DEPENDENCY = re.compile(r'(?:(?:lib|-l)clang_rt\.(?:.*san|profile|xray)|(?:lib|-l)(?:asan|tsan|ubsan|msan|lsan|gcov))')
FORWARDERS = frozenset(('-Xclang', '-Xfrontend', '-Xcc', '-Xllvm', '-mllvm', '-Xlinker', '-Xpreprocessor'))
OPERANDS = frozenset(('-D', '-U', '-I', '-F', '-L', '-l', '-include', '-imacros', '-include-pch',
    '-isystem', '-iquote', '-iframework', '-isysroot', '-sdk', '-resource-dir', '-target', '-arch',
    '-o', '-x', '-MF', '-MT', '-MQ', '-ivfsoverlay', '-ivfsstatcache', '-working-directory',
    '-index-store-path', '-index-unit-output-path', '-serialize-diagnostics', '-module-name',
    '-output-file-map', '-emit-module-path', '-emit-module-doc-path', '-emit-module-source-info-path',
    '-emit-dependencies-path', '-emit-reference-dependencies-path', '-primary-file', '-filelist'))
BAD_FLAGS = re.compile(r'^(?:--coverage$|-coverage$|-f(?:profile-(?:instr-generate|generate|arcs|instrument)|cs-profile-generate|'
    'test-coverage|coverage-(?:mapping|mcdc)|sanitize(?:=|-coverage)|instrument-functions|xray-instrument)|'
    '-(?:(?:ir-|cs-)?profile-generate|profile-coverage-mapping|sanitize(?:=|-coverage)|pg$|p$|finstrument-functions)|'
    '-(?:pgo-instr-gen|instrprof|sanitizer-coverage|asan|tsan|msan|hwasan|dfsan)(?:=|-|$))')


class GuardError(Exception):
    """Only fixed, non-sensitive reason identifiers belong in these exceptions."""


def require(condition, reason):
    if not condition:
        raise GuardError(reason)


def bounded_file(path, limit=MAX_FILE_BYTES, root=None):
    path = Path(path)
    if root is not None:
        require(path.resolve().is_relative_to(root.resolve()), 'path_outside_expected_root')
    info = path.stat()
    require(stat.S_ISREG(info.st_mode), 'not_regular_file')
    require(0 < info.st_size <= limit, 'file_size_limit_or_empty')
    with path.open('rb') as source:
        data = source.read(limit + 1)
    require(len(data) == info.st_size and len(data) <= limit, 'file_changed_or_truncated')
    return data


def inspect_bytes(data, sdk, depth=0):
    require(sdk in SDK_PLATFORMS, 'unknown_sdk')
    require(0 < len(data) <= MAX_FILE_BYTES and depth <= 3, 'artifact_size_or_depth')
    result = {'slices': 0, 'members': 0, 'symbols': 0, 'sections': 0, 'arches': [], 'kinds': []}

    def merge(child):
        for key in ('slices', 'members', 'symbols', 'sections'):
            result[key] += child[key]
        result['arches'] = sorted(set(result['arches']) | set(child['arches']))
        result['kinds'] = sorted(set(result['kinds']) | set(child['kinds']))
        require(result['slices'] <= MAX_MEMBERS and result['symbols'] <= MAX_SYMBOLS,
                'aggregate_inventory_limit')

    if data.startswith(b'!<arch>\n'):
        cursor = 8
        members = 0
        while cursor < len(data):
            require(cursor + 60 <= len(data), 'archive_header_truncated')
            header = data[cursor:cursor + 60]
            require(header[58:] == b'`\n', 'archive_header_invalid')
            try:
                size = int(header[48:58])
                name = header[:16].decode('ascii').strip()
            except (ValueError, UnicodeError):
                raise GuardError('archive_header_invalid')
            cursor += 60
            require(size >= 0 and cursor + size <= len(data), 'archive_member_truncated')
            body = data[cursor:cursor + size]
            if name.startswith('#1/'):
                try:
                    name_size = int(name[3:])
                except ValueError:
                    raise GuardError('archive_name_invalid')
                require(0 < name_size <= min(4096, len(body)), 'archive_name_invalid')
                name = body[:name_size].rstrip(b'\0').decode('utf-8', errors='strict')
                body = body[name_size:]
            # BSD and GNU archive indexes are metadata; every other member is scanned.
            if name in ('__.SYMDEF', '__.SYMDEF SORTED', '__.SYMDEF_64', '__.SYMDEF_64 SORTED'):
                width = 8 if '_64' in name else 4
                format_ = '<Q' if width == 8 else '<I'
                require(len(body) >= width * 2, 'archive_index_truncated')
                ranbytes = struct.unpack_from(format_, body)[0]
                require(ranbytes % (width * 2) == 0 and ranbytes + width * 2 <= len(body), 'archive_index_invalid')
                strings = struct.unpack_from(format_, body, width + ranbytes)[0]
                require(ranbytes + width * 2 + strings <= len(body)
                        and len(body) - ranbytes - width * 2 - strings <= 7, 'archive_index_invalid')
            elif name in ('/', '/SYM64/'):
                width = 8 if name == '/SYM64/' else 4
                require(len(body) >= width, 'archive_index_truncated')
                count = struct.unpack_from('>Q' if width == 8 else '>I', body)[0]
                require(count <= MAX_SYMBOLS and (count + 1) * width <= len(body), 'archive_index_invalid')
                require(body[(count + 1) * width:].count(b'\0') >= count, 'archive_index_strings_invalid')
            elif name == '//':
                require(body.endswith((b'\n', b'\0')), 'archive_name_table_invalid')
            else:
                merge(inspect_bytes(body, sdk, depth + 1))
                members += 1
                require(members <= MAX_MEMBERS, 'archive_member_limit')
            cursor += size + size % 2
        require(cursor == len(data) and members > 0, 'archive_empty_or_truncated')
        result['members'] += members
        return result
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        require(len(data) >= 8, 'fat_header_truncated')
        count = struct.unpack_from('>I', data, 4)[0]
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        width = 32 if wide else 20
        require(1 <= count <= 4 and 8 + count * width <= len(data), 'fat_inventory_invalid')
        ranges = []
        cpus = set()
        for index in range(count):
            fields = struct.unpack_from('>IIQQII' if wide else '>IIIII', data, 8 + width * index)
            cpu, _, offset, size, alignment = fields[:5]
            require(cpu in CPUS and cpu not in cpus, 'fat_arch_duplicate_or_unknown')
            require(offset >= 8 + count * width and size > 0 and offset + size <= len(data), 'fat_slice_truncated')
            require(alignment <= 30 and offset % (1 << alignment) == 0, 'fat_alignment_invalid')
            require(all(offset + size <= a or offset >= b for a, b in ranges), 'fat_slices_overlap')
            child = inspect_bytes(data[offset:offset + size], sdk, depth + 1)
            require(child['arches'] == [CPUS[cpu]], 'fat_arch_mismatch')
            merge(child)
            ranges.append((offset, offset + size)); cpus.add(cpu)
        return result
    require(len(data) >= 32 and data[:4] == b'\xcf\xfa\xed\xfe', 'unsupported_or_truncated_macho')
    _, cpu, _, kind, ncmds, cmdbytes, _, _ = struct.unpack_from('<8I', data)
    require(cpu in CPUS and (sdk.endswith('simulator') or CPUS[cpu] == 'arm64'), 'macho_arch_mismatch')
    require(kind in (1, 2, 6, 8), 'macho_kind_unsupported')
    require(0 < ncmds <= 4096 and 8 * ncmds <= cmdbytes <= len(data) - 32, 'load_commands_truncated')
    cursor = 32
    end = cursor + cmdbytes
    symtab = None
    platform = None
    for _ in range(ncmds):
        require(cursor + 8 <= end, 'load_command_truncated')
        command, size = struct.unpack_from('<II', data, cursor)
        require(size >= 8 and size % 4 == 0 and cursor + size <= end, 'load_command_invalid')
        if command == 0x32:
            require(size >= 24 and platform is None, 'build_version_invalid')
            platform, minimum, sdk_version, tools = struct.unpack_from('<4I', data, cursor + 8)
            require(platform == SDK_PLATFORMS[sdk] and minimum == 27 << 16, 'macho_platform_or_deployment_mismatch')
            require(sdk_version == 27 << 16 or (kind == 1 and sdk_version == 0), 'macho_sdk_mismatch')
            require(size == 24 + 8 * tools, 'build_version_invalid')
        elif command == 2:
            require(size == 24 and symtab is None, 'symbol_table_invalid')
            symtab = struct.unpack_from('<4I', data, cursor + 8)
        elif command == 0x19:
            require(size >= 72, 'segment_truncated')
            nsects = struct.unpack_from('<I', data, cursor + 64)[0]
            require(nsects <= 4096 and size == 72 + 80 * nsects, 'section_inventory_invalid')
            for index in range(nsects):
                offset = cursor + 72 + index * 80
                name = data[offset:offset + 16].split(b'\0')[0].decode('ascii', errors='strict')
                require(not SECTION.match(name.lstrip('_')), 'instrumentation_section')
                count, fileoff = struct.unpack_from('<QI', data, offset + 40)
                section_flags = struct.unpack_from('<I', data, offset + 64)[0]
                if section_flags & 0xff not in (1, 0xc, 0x12):
                    require(fileoff + count <= len(data), 'section_data_truncated')
                result['sections'] += 1
        elif command in (0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023):
            require(size >= 24, 'dependency_command_truncated')
            nameoff = struct.unpack_from('<I', data, cursor + 8)[0]
            require(24 <= nameoff < size, 'dependency_name_invalid')
            terminator = data.find(b'\0', cursor + nameoff, cursor + size)
            require(terminator >= 0, 'dependency_name_unterminated')
            name = data[cursor + nameoff:terminator].decode('utf-8', errors='strict')
            require(not DEPENDENCY.search(Path(name).name), 'instrumentation_dependency')
        cursor += size
    require(cursor == end and platform is not None and symtab is not None, 'macho_identity_incomplete')
    symoff, nsyms, stroff, strsize = symtab
    require(nsyms <= MAX_SYMBOLS and symoff + nsyms * 16 <= len(data)
            and stroff + strsize <= len(data) and strsize > 0, 'symbol_table_truncated_or_limit')
    for index in range(nsyms):
        strx, typ = struct.unpack_from('<IB', data, symoff + 16 * index)
        require(strx < strsize, 'symbol_string_outside_table')
        terminator = data.find(b'\0', stroff + strx, min(stroff + strsize, stroff + strx + 65536))
        require(terminator >= 0, 'symbol_string_unterminated_or_limit')
        if typ & 0xe0:  # STABS debug strings are not linked symbols.
            continue
        name = data[stroff + strx:terminator].decode('utf-8', errors='strict')
        require(not SYMBOL.match(name.lstrip('_')), 'instrumentation_symbol')
    result.update(slices=1, symbols=nsyms, arches=[CPUS[cpu]], kinds=[kind])
    return result


def source_snapshot():
    root = Path(__file__).resolve().parents[1]
    values = {}
    for key, revision in [('head', 'HEAD'), ('tree', 'HEAD^{tree}')]:
        call = subprocess.run(['git', 'rev-parse', '--verify', revision], cwd=root,
                              capture_output=True, timeout=10, check=False)
        require(call.returncode == 0 and len(call.stdout) < 100 and not call.stderr, 'source_query_failed')
        value = call.stdout.decode().strip()
        require(re.fullmatch('[0-9a-f]{40,64}', value) is not None, 'source_identity_invalid')
        values[key] = value
    call = subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=root,
                          capture_output=True, timeout=10, check=False)
    require(call.returncode == 0 and not call.stdout and not call.stderr, 'source_tree_dirty')
    call = subprocess.run(['git', 'ls-files', '--others', '--exclude-standard', '--', 'Sources',
                           'project.yml', 'VPlayer.xcodeproj', '*.xctestplan'], cwd=root,
                          capture_output=True, timeout=10, check=False)
    require(call.returncode == 0 and not call.stdout and not call.stderr, 'untracked_production_input')
    expected = os.environ.get('CANDIDATE_SHA')
    require(not expected or values['head'] == expected, 'candidate_source_mismatch')
    return values


def capture(stream, path, limit=MAX_LOG_BYTES):
    count = 0
    digest = hashlib.sha256()
    complete = True
    truncated = False
    output = None
    metadata = Path(str(path) + '.capture.json')
    try:
        metadata.unlink(missing_ok=True)
    except OSError:
        complete = False
    try:
        source = source_snapshot()
    except (GuardError, OSError, subprocess.SubprocessError):
        source = None
    try:
        output = path.open('wb')
    except OSError:
        complete = False
    try:
        read = getattr(stream, 'read1', stream.read)
        while chunk := read(65536):
            truncated |= len(chunk) > limit - count
            chunk = chunk[:max(0, limit - count)]
            if output:
                try:
                    output.write(chunk); output.flush(); digest.update(chunk); count += len(chunk)
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
        try:
            source_after = source_snapshot()
        except (GuardError, OSError, subprocess.SubprocessError):
            source_after = None
        metadata.write_text(json.dumps(dict(
            complete=complete, truncated=truncated, bytes=count, sha256=digest.hexdigest(),
            source=source if source and source == source_after else None)) + '\n')
    except OSError:
        complete = False  # Drain above, then make pipeline capture failure authoritative.
    return complete and not truncated


def read_capture(path):
    state = json.loads(bounded_file(Path(str(path) + '.capture.json'), 1024))
    require(isinstance(state, dict), 'capture_schema_invalid')
    raw = bounded_file(path, MAX_LOG_BYTES)
    require(state.get('complete') is True and state.get('truncated') is False
            and state.get('bytes') == len(raw) and state.get('sha256') == hashlib.sha256(raw).hexdigest(),
            'log_capture_unverified')
    return raw


def expand_responses(arguments, derived, cwd, evidence=None):
    expanded = []
    count = 0
    size = 0
    def visit(tokens, stack=()):
        nonlocal count, size
        for token in tokens:
            if token.startswith('@'):
                path = Path(token[1:]); path = (path if path.is_absolute() else cwd / path).resolve()
                previous = expanded[-1:] if expanded[-1:] != ['-Xlinker'] else expanded[-2:-1]
                if (previous and previous[0] in ('-install_name', '-rpath')
                        and token.startswith(('@rpath/', '@loader_path/', '@executable_path/'))):
                    # Mach-O loader names are literal linker operands, not
                    # response files. Reject a real file collision as ambiguous.
                    require(not path.exists(), 'loader_response_collision')
                    expanded.append(token)
                    require(len(expanded) <= 65536, 'argument_limit')
                    continue
                require(path.is_relative_to(derived.resolve()), 'response_outside_derived_data')
                require(path not in stack and len(stack) < 8, 'response_cycle_or_depth')
                count += 1
                require(count <= 128, 'response_file_limit')
                try:
                    raw = bounded_file(path, MAX_RESPONSE_BYTES)
                except OSError:
                    raise GuardError('response_unreadable')
                size += len(raw)
                require(size <= MAX_RESPONSE_BYTES and b'\0' not in raw, 'response_size_or_syntax')
                if evidence is not None:
                    evidence.append(dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest()))
                visit(shlex.split(raw.decode('utf-8-sig')), (*stack, path))
            else:
                expanded.append(token)
                require(len(expanded) <= 65536, 'argument_limit')
    visit(arguments)
    return expanded


def options(arguments):
    index = 0
    while index < len(arguments):
        token = arguments[index]
        operand = None
        key, separator, joined = token.partition('=')
        if separator and key in FORWARDERS:
            require(joined, 'missing_option_operand')
            yield key, joined
            index += 1
            continue
        if token in OPERANDS or token in FORWARDERS:
            index += 1
            require(index < len(arguments), 'missing_option_operand')
            operand = arguments[index]
        yield token, operand
        index += 1


def operand(arguments, name):
    matches = ([arguments[index + 1] for index, token in enumerate(arguments[:-1]) if token == '-c']
               if name == '-c' else [value for token, value in options(arguments) if token == name])
    require(len(matches) <= 1, 'ambiguous_command_operand')
    return matches[0] if matches else None


def check_flags(arguments, compiler, scope='app', depth=0):
    require(depth <= 8, 'forwarding_depth_limit')
    linker = []
    forwarded = {name: [] for name in FORWARDERS if name != '-Xlinker'}
    def runtime(token):
        return bool(DEPENDENCY.search(token if token.startswith('-l') else Path(token).name))
    def instruments(token):
        if token == '-fprofile-instrument=none' or re.fullmatch(r'-fprofile-instrument-use(?:-path)?=.+', token):
            return False  # Existing profile consumption does not insert counters.
        return bool(BAD_FLAGS.match(token))
    for token, value in options(arguments):
        require(token != '--' and not token.startswith('--config'), 'unsupported_compiler_config')
        require(not instruments(token), 'instrumentation_compile_flag')
        if token.startswith('-l') or not token.startswith('-'):
            require(not runtime(token), 'instrumentation_link_flag')
        require(scope != 'app' or token != '-enable-testing', 'shipping_testability_enabled')
        if token == '-l':
            require(not DEPENDENCY.search('-l' + value), 'instrumentation_link_flag')
        if token in FORWARDERS:
            require(not instruments(value), 'instrumentation_forwarded_flag')
            require(scope != 'app' or value != '-enable-testing', 'shipping_testability_enabled')
            if token == '-Xlinker':
                linker.append(value)
            else:
                forwarded[token].append(value)
        if token.startswith('-Wl,'):
            linker.extend(token[4:].split(','))
        if token.startswith('-Wp,'):
            forwarded['-Xpreprocessor'].extend(token[4:].split(','))
    for index, token in enumerate(linker):
        require(not runtime(token) and not SYMBOL.match(token.lstrip('_')), 'instrumentation_link_flag')
        if token == '-l':
            require(index + 1 < len(linker), 'missing_linker_library_operand')
            require(not runtime('-l' + linker[index + 1]), 'instrumentation_link_flag')
    for tokens in forwarded.values():
        if tokens:
            check_flags(tokens, compiler, scope, depth + 1)


def check_release_compile(arguments, compiler, scope):
    """Require an observed optimized compile; do not guess an absent default.

    Driver flag order is preserved. A forwarded optimization spelling is only
    accepted when it agrees with the final driver mode, so no undocumented
    forwarding precedence is inferred. Diagnostic definitions are checked in
    each preprocessing/frontend channel; a different channel cannot silently
    undefine a Swift condition or prove a Clang macro override.
    """
    swift = compiler in ('swiftc', 'swift-frontend')
    allowed = {'-O', '-Osize', '-Ounchecked', '-Onone'} if swift else {
        '-O', '-O0', '-O1', '-O2', '-O3', '-O4', '-Os', '-Oz', '-Og', '-Ofast'}
    direct = []
    channels = {name: [] for name in FORWARDERS if name != '-Xlinker'}
    normal = []
    for token, value in options(arguments):
        if token in channels:
            channels[token].append(value)
        elif token.startswith('-Wp,'):
            channels['-Xpreprocessor'].extend(token[4:].split(','))
        else:
            normal.append(token)
            if value is not None:
                normal.append(value)
            if token.startswith('-O'):
                require(token in allowed, 'optimization_spelling_unverified')
                direct.append(token)
    require(direct, 'optimization_flag_missing')
    final = direct[-1]
    require(final not in ('-O0', '-Onone'), 'unoptimized_release_compile')
    for channel in ('-Xfrontend' if swift else '-Xclang', '-Xllvm', '-mllvm'):
        forwarded = [token for token, _ in options(channels[channel]) if token.startswith('-O')]
        if forwarded:
            require(channel not in ('-Xllvm', '-mllvm') and forwarded[-1] == final,
                    'optimization_forwarding_unverified')
    diagnostic_names = {'DEBUG', 'VPLAYER_PERFORMANCE_DIAGNOSTICS'}
    def definitions_and_disables(tokens, depth=0, channel=None):
        require(depth <= 8, 'forwarding_depth_limit')
        modes = [token for token, _ in options(tokens) if token.startswith('-O')]
        if channel is not None and modes:
            require(channel == ('-Xfrontend' if swift else '-Xclang') and modes[-1] == final,
                    'optimization_forwarding_unverified')
        definitions = set()
        nested = {name: [] for name in channels}
        for token, value in options(tokens):
            require(token not in ('-disable-llvm-passes', '-disable-llvm-optzns', '-disable-sil-perf-optzns'),
                    'release_optimizer_disabled')
            if token in nested:
                nested[token].append(value)
                continue
            if token.startswith('-Wp,'):
                nested['-Xpreprocessor'].extend(token[4:].split(','))
                continue
            if token in ('-D', '-U'):
                operation, definition = token, value
            elif token.startswith(('-D', '-U')) and len(token) > 2:
                operation, definition = token[:2], token[2:]
            else:
                continue
            identifier = re.match(r'\s*([\w$]+)', definition)
            name = identifier[1] if identifier else ''
            if name in diagnostic_names:
                if operation == '-D':
                    definitions.add(name)
                else:
                    definitions.discard(name)
        require(not definitions, 'shipping_diagnostic_definition')
        for name, values in nested.items():
            if values:
                definitions_and_disables(values, depth + 1, name)
    definitions_and_disables(normal)
    for name, tokens in channels.items():
        definitions_and_disables(tokens, channel=name)
    return final


def inspect_commands(raw, *, derived, cwd, sdk, compilers, objects, modules, scope='app',
                     require_links=False, linked_roots=(), expected_sdk=None):
    require(len(raw) <= MAX_LOG_BYTES, 'log_byte_limit')
    matched = set()
    observed_modules = set()
    linked_modules = set()
    evidence = []
    counts = {'c_commands': 0, 'swift_commands': 0, 'link_commands': 0}
    optimization = {'c': set(), 'swift': set()}
    platform = 'ios' if sdk.startswith('iphone') else 'tvos'
    suffix = '-simulator' if sdk.endswith('simulator') else ''
    expected_target = re.compile(r'(arm64|x86_64)-apple-' + platform + r'27(?:\.0){0,2}' + suffix + r'\Z')
    for line in raw.splitlines():
        require(len(line) <= MAX_LINE_BYTES, 'log_line_limit')
        text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line.decode('utf-8', errors='strict')).strip()
        try:
            argv = shlex.split(text)
        except ValueError:
            require(not any(name in text for name in ('/clang ', '/swiftc ', '/swift-frontend ')), 'command_syntax')
            continue
        if argv and Path(argv[0]).name in ('builtin-SwiftDriver', 'builtin-Swift-Compilation') and '--' in argv:
            argv = argv[argv.index('--') + 1:]
        if not argv or Path(argv[0]).name not in ('clang', 'clang++', 'swiftc', 'swift-frontend'):
            continue
        command_inputs = []
        args = expand_responses(argv[1:], derived, cwd, command_inputs)
        name = Path(argv[0]).name
        output = operand(args, '-o')
        output_path = (Path(output) if Path(output).is_absolute() else cwd / output).resolve() if output else None
        module = operand(args, '-module-name')
        linked_module = None
        if output_path and name.startswith('clang') and output_path not in objects:
            for candidate in modules:
                product = 'VPlayer.app' if candidate == 'VPlayer' else candidate + '.framework'
                if (output_path.parts[-2:] == (product, candidate)
                        and any(output_path.is_relative_to(root.resolve()) for root in (derived, *linked_roots))):
                    linked_module = candidate
        relevant = (output_path in objects or linked_module is not None) if name.startswith('clang') else module in modules
        if not relevant:
            continue
        require(name in compilers and Path(argv[0]).is_absolute()
                and Path(argv[0]).resolve() == compilers[name].resolve(), 'compiler_identity_mismatch')
        require(expected_target.fullmatch(operand(args, '-target') or '') is not None, 'command_target_mismatch')
        if expected_sdk is not None:
            selected_sdk = operand(args, '-isysroot' if name.startswith('clang') else '-sdk')
            require(selected_sdk is not None and Path(selected_sdk).is_absolute()
                    and Path(selected_sdk).resolve() == expected_sdk.resolve(), 'command_sdk_mismatch')
        check_flags(args, name, scope=scope)
        if linked_module:
            require('-c' not in args and not set(args) & {'-E', '-S', '-fsyntax-only', '-###'}, 'not_link_command')
            linked_modules.add(linked_module); counts['link_commands'] += 1
        elif name.startswith('clang'):
            require(operand(args, '-c') is not None and not set(args) & {'-E', '-S', '-fsyntax-only', '-###'},
                    'not_object_compile')
            optimization['c'].add(check_release_compile(args, name, scope))
            matched.add(output_path); counts['c_commands'] += 1
        else:
            emitted = set()
            mapping = operand(args, '-output-file-map')
            if mapping:
                path = Path(mapping); path = path if path.is_absolute() else cwd / path
                mapping_bytes = bounded_file(path, MAX_RESPONSE_BYTES, derived)
                command_inputs.append(dict(path=str(path.resolve()), sha256=hashlib.sha256(mapping_bytes).hexdigest()))
                rows = json.loads(mapping_bytes)
                require(isinstance(rows, dict), 'swift_output_map_invalid')
                for row in rows.values():
                    require(isinstance(row, dict), 'swift_output_map_invalid')
                    if 'object' in row:
                        require(isinstance(row['object'], str), 'swift_output_map_invalid')
                        item = Path(row['object']); emitted.add((item if item.is_absolute() else cwd / item).resolve())
            if output_path in objects:
                emitted.add(output_path)
            if emitted & objects:
                require('-c' in args or '-emit-object' in args, 'not_swift_object_compile')
                optimization['swift'].add(check_release_compile(args, name, scope))
                matched |= emitted & objects
                observed_modules.add(module); counts['swift_commands'] += 1
        evidence.append(dict(compiler=name, arguments=args, inputs=command_inputs))
        require(sum(counts.values()) <= MAX_COMMANDS, 'compile_command_limit')
    require(matched == objects and observed_modules == modules and counts['c_commands'] > 0,
            'compile_evidence_incomplete')
    require(not require_links or linked_modules == modules, 'link_evidence_incomplete')
    counts['command_evidence_sha256'] = hashlib.sha256(json.dumps(evidence, sort_keys=True).encode()).hexdigest()
    counts.update({kind + '_optimization_flags': sorted(flags) for kind, flags in optimization.items()})
    return counts


def compiler_paths():
    result = {}
    for name in ('clang', 'clang++', 'swiftc', 'swift-frontend'):
        call = subprocess.run(['/usr/bin/xcrun', '--find', name], capture_output=True, timeout=15, check=False)
        require(call.returncode == 0 and len(call.stdout) <= 4096 and not call.stderr, 'toolchain_query_failed')
        path = Path(call.stdout.decode().strip())
        require(path.is_absolute() and path.is_file(), 'toolchain_identity_invalid')
        result[name] = path.resolve()
    return result


def sdk_path(sdk):
    values = []
    for option in ('--show-sdk-path', '--show-sdk-version'):
        call = subprocess.run(['/usr/bin/xcrun', '--sdk', sdk, option], capture_output=True, timeout=15, check=False)
        require(call.returncode == 0 and len(call.stdout) <= 4096 and not call.stderr, 'sdk_query_failed')
        values.append(call.stdout.decode().strip())
    path = Path(values[0])
    require(values[1] == '27.0' and path.is_absolute() and path.is_dir(), 'sdk_identity_mismatch')
    return path.resolve()


def verify(args):
    require(args.ffmpeg, 'ffmpeg_archive_required')
    source = source_snapshot()
    log_state = json.loads(bounded_file(Path(str(args.build_log) + '.capture.json'), 1024))
    require(isinstance(log_state, dict), 'capture_schema_invalid')
    require(log_state.get('source') == source, 'source_identity_mismatch')
    derived = args.derived_data.resolve()
    require(derived.is_dir(), 'derived_data_missing')
    ios = args.sdk.startswith('iphone')
    suffix = 'iOS' if ios else ''
    targets = ['VPlayerCore' + suffix, 'VPlayerPlayback' + suffix]
    modules = {'VPlayerCore', 'VPlayerPlayback'}
    if args.scope == 'app':
        targets.append('VPlayeriOS' if ios else 'VPlayer'); modules.add('VPlayer')
    build = derived / 'Build/Intermediates.noindex'
    if args.archive:
        require(args.scope == 'app' and not args.sdk.endswith('simulator'), 'archive_scope_invalid')
        candidates = list(build.glob('ArchiveIntermediates/*/IntermediateBuildFilesPath/VPlayer.build/Release-' + args.sdk))
        app = args.archive.resolve() / 'Products/Applications/VPlayer.app'
    else:
        candidates = [build / ('VPlayer.build/Release-' + args.sdk)]
        app = derived / ('Build/Products/Release-' + args.sdk + '/VPlayer.app')
    require(len(candidates) == 1 and candidates[0].is_dir(), 'object_build_root_missing_or_ambiguous')
    files = []
    objects = set()
    object_arches = {}
    c_names = {p.stem + '.o' for p in (Path(__file__).resolve().parents[1] / 'Sources/VPlayerPlayback').rglob('*')
               if p.suffix in ('.c', '.m', '.mm')}
    for target in targets:
        root = candidates[0] / (target + '.build/Objects-normal')
        require(root.is_dir(), 'production_object_target_missing')
        found = sorted(root.glob('*/*.o'))
        require(0 < len(found) <= MAX_FILES, 'production_object_inventory_missing_or_limit')
        arches = {p.parent.name for p in found}
        require(arches <= set(CPUS.values()), 'object_arch_unknown')
        if target.startswith('VPlayerPlayback'):
            for arch in arches:
                require(c_names <= {p.name for p in found if p.parent.name == arch}, 'production_c_object_missing')
        object_arches[target] = arches
        for path in found:
            require(path.resolve().is_relative_to(derived), 'object_path_escape')
            objects.add(path.resolve()); files.append((target + '/object', path, derived))
    require(len({tuple(sorted(x)) for x in object_arches.values()}) == 1, 'production_arch_inventory_mismatch')
    expected_arches = sorted(next(iter(object_arches.values())))

    def bundle(path, identifier, executable, label, root):
        info = plistlib.loads(bounded_file(path / 'Info.plist', 1024 * 1024, root))
        require(isinstance(info, dict), 'bundle_schema_invalid')
        require(info.get('CFBundleIdentifier') == identifier and info.get('CFBundleExecutable') == executable,
                'bundle_identity_mismatch')
        files.append((label, path / executable, root))

    if args.scope == 'app':
        product_root = args.archive.resolve() if args.archive else derived
        bundle(app, 'com.vforce.vplayer', 'VPlayer', 'VPlayer/app', product_root)
        framework_root = app / 'Frameworks'
    else:
        product_root = derived
        framework_root = derived / ('Build/Products/Release-' + args.sdk)
    for name, identifier in [('VPlayerCore', 'com.vplayer.core'), ('VPlayerPlayback', 'com.vplayer.playback')]:
        bundle(framework_root / (name + '.framework'), identifier + ('.ios' if ios else ''), name,
               name + '/framework', product_root)
    if args.scope == 'app':
        known = {p.resolve() for _, p, _ in files}
        for index, path in enumerate(sorted(app.rglob('*'))):
            require(index < MAX_FILES, 'app_inventory_limit')
            require(path.resolve().is_relative_to(product_root), 'app_path_escape')
            if path.is_file() and path.resolve() not in known:
                with path.open('rb') as binary:
                    prefix = binary.read(4)
                if prefix in MAGICS or path.suffix in ('.dylib', '.a'):
                    files.append(('VPlayer/embedded-binary', path, product_root))
    if args.ffmpeg:
        for path in args.ffmpeg:
            require(path.name == 'libFFmpeg.a', 'ffmpeg_artifact_identity')
            files.append(('FFmpeg/archive', path, path.parent.resolve()))
    require(len(files) <= MAX_FILES, 'artifact_file_limit')
    rows = []
    total = 0
    for label, path, root in files:
        data = bounded_file(path, root=root)
        total += len(data)
        require(total <= MAX_TOTAL_BYTES, 'artifact_total_limit')
        facts = inspect_bytes(data, args.sdk)
        if '/object' in label:
            require(facts['kinds'] == [1], 'artifact_kind_mismatch')
            require(facts['arches'] == [path.parent.name], 'object_directory_arch_mismatch')
        elif label == 'FFmpeg/archive':
            require(data.startswith((b'!<arch>\n', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'))
                    and facts['kinds'] == [1], 'artifact_kind_mismatch')
            require(set(expected_arches) <= set(facts['arches']), 'ffmpeg_arch_mismatch')
        else:
            require(facts['kinds'] == ([2] if label == 'VPlayer/app' else [6]), 'artifact_kind_mismatch')
            require(facts['arches'] == expected_arches, 'binary_object_arch_mismatch')
        rows.append(dict(role=label, identity=str(path.resolve().relative_to(root.resolve())),
                         sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), **facts))
    commands = inspect_commands(read_capture(args.build_log), derived=derived, cwd=Path.cwd(), sdk=args.sdk,
                                compilers=compiler_paths(), objects=objects, modules=modules, scope=args.scope,
                                require_links=True, linked_roots=(args.archive.resolve(),) if args.archive else (),
                                expected_sdk=sdk_path(args.sdk))
    # Hash the ordered complete inventory instead of publishing thousands of symbols/paths.
    digest = hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()
    receipt = dict(source=source, inventory=digest, log_sha256=log_state['sha256'],
                   command_evidence_sha256=commands['command_evidence_sha256'],
                   sdk=args.sdk, scope=args.scope, archive=bool(args.archive))
    receipt_path = Path(str(args.build_log) + '.release-guard.json')
    if receipt_path.exists():
        require(json.loads(bounded_file(receipt_path, 4096)) == receipt, 'artifact_receipt_mismatch')
    else:
        with receipt_path.open('x') as output:
            json.dump(receipt, output, sort_keys=True)
            output.write('\n')
    require(source_snapshot() == source, 'source_changed_during_inspection')
    return dict(status='passed', sdk=args.sdk, scope=args.scope, archive=bool(args.archive),
                files=len(files), objects=len(objects), bytes=total, arches=expected_arches,
                artifact_inventory_sha256=digest, source_head=source['head'], source_tree=source['tree'], **commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    capture_parser = subs.add_parser('capture')
    capture_parser.add_argument('--log', type=Path, required=True)
    scan_parser = subs.add_parser('scan')
    scan_parser.add_argument('--sdk', choices=SDK_PLATFORMS, required=True)
    scan_parser.add_argument('--artifact', type=Path, required=True)
    verify_parser = subs.add_parser('verify')
    verify_parser.add_argument('--sdk', choices=SDK_PLATFORMS, required=True)
    verify_parser.add_argument('--derived-data', type=Path, required=True)
    verify_parser.add_argument('--build-log', type=Path, required=True)
    verify_parser.add_argument('--scope', choices=('app', 'frameworks'), required=True)
    verify_parser.add_argument('--archive', type=Path)
    verify_parser.add_argument('--ffmpeg', type=Path, action='append', required=True)
    args = parser.parse_args()
    if args.command == 'capture':
        return 0 if capture(sys.stdin.buffer, args.log) else 1
    try:
        if args.command == 'scan':
            raw = bounded_file(args.artifact)
            result = dict(status='passed', scope='artifact-control', sdk=args.sdk,
                          sha256=hashlib.sha256(raw).hexdigest(), **inspect_bytes(raw, args.sdk))
        else:
            result = verify(args)
    except GuardError as error:
        result = dict(status='failed', reason=str(error))
    except (OSError, UnicodeError, ValueError, TypeError, KeyError, RuntimeError, struct.error, subprocess.SubprocessError):
        result = dict(status='failed', reason='unreadable_or_malformed_evidence')
    print('RELEASE_ARTIFACT_GUARD=' + json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
