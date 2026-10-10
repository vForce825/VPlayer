#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Export only validated scalar diagnostics, never assertion text or attachments."""
import argparse
import importlib.util
import json
import math
import re
from pathlib import Path

MAX_BYTES = 40 * 1024
OUTCOMES = {'success', 'failure', 'skipped', 'cancelled', 'unavailable'}
PHASES = set('early-eof-recovery early-eof-startup eos-ordering-error eos-ordering-first-read eos-ordering-progress eos-ordering-refresh eos-ordering-startup full-eof-completion full-eof-startup public-mime-media-startup quantum-owner-original quantum-owner-successor refresh-return-first-read refresh-return-startup selected-format-progress selected-format-startup'.split())
SOURCE_AAC_PHASES = set('diagnostic-truncated fixture-begin fixture-return calibration-begin calibration-return calibration-pass-1-encoded calibration-pass-2-encoded calibration-pass-1-complete calibration-pass-2-complete calibration-tracks-loaded calibration-reader-create calibration-native-init calibration-dispose input-encode-begin input-encode-return input-copy-complete source-append-begin source-append-145-complete source-append-290-complete source-finish-begin source-finish-return source-publication-complete source-error-before-cleanup server-begin server-return http-request-begin http-request-return http-complete owner-error-before-retire watchdog-error-before-cleanup retire-begin retire-http-error retire-writer-join-begin retire-writer-join-return retire-return'.split())
SOURCE_AAC_CATEGORIES = {'none', 'aac-framework', 'avfoundation', 'osstatus', 'cancelled', 'other'}

def source_aac_stages(lines):
    result = {'events': [], 'truncated': False, 'errors': []}
    attempts = {1: [], 2: []}
    first_errors, last_errors = {}, {}
    pattern = (r'SOURCE_AAC_FIXTURE_STAGE attempt=([12]) stage=([a-z0-9-]{1,48}) index=(\d{1,2}) '
               r'elapsed-ms=(\d{1,7}) category=([a-z-]{1,16}) code=(-?\d{1,10})')
    for line in lines:
        if not isinstance(line, str) or len(line) > 256:
            continue
        match = re.fullmatch(pattern, line.rstrip('\r\n'))
        if not match:
            continue
        attempt, stage, index, elapsed, category, code = match.groups()
        if (stage not in SOURCE_AAC_PHASES or category not in SOURCE_AAC_CATEGORIES
                or not 0 <= int(index) <= 32 or not 0 <= int(elapsed) <= 3_600_000
                or not -2_147_483_648 <= int(code) <= 2_147_483_647):
            continue
        event = {'attempt': int(attempt), 'stage': stage, 'index': int(index),
            'elapsed_ms': int(elapsed), 'category': category, 'code': int(code)}
        if stage == 'diagnostic-truncated':
            result['truncated'] = True
            continue
        if category != 'none':
            first_errors.setdefault(int(attempt), event)
            last_errors[int(attempt)] = event
        retained = attempts[int(attempt)]
        if event in retained:
            continue
        if len(retained) == 64:
            retained.pop(0)
            result['truncated'] = True
        retained.append(event)
    for attempt in (1, 2):
        result['events'].extend(attempts[attempt])
        for error in (first_errors.get(attempt), last_errors.get(attempt)):
            if error is not None and error not in result['errors']:
                result['errors'].append(error)
    return result

RUNTIME = {'appState': (0, 2), 'protected': 'bool', 'idleDisabled': 'bool',
           'outputs': (0, 32), 'channels': (0, 64), 'rate': (0, 384000)}
EVIDENCE = {**{k: 'bool' for k in ('same-coordinator', 'same-physical', 'original-prepared', 'original-verified')},
            **{k: 'time' for k in ('original-current', 'original-duration', 'driver-first', 'driver-stable')},
            'original-status': (0, 2), 'player-rate': (-16, 16), 'player-control': (0, 2), 'error-code': (-2147483648, 2147483647)}

def helper():
    spec = importlib.util.spec_from_file_location('xcresult_failure', Path(__file__).with_name('report-xcresult-failures.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def scalars(text, rules):
    result = {}
    for key, value in re.findall(r'([A-Za-z][A-Za-z0-9-]*)=([^\s{}]+)', text):
        rule = rules.get(key)
        if rule == 'bool' and value in ('true', 'false'):
            result[key] = value == 'true'
        elif rule == 'time' and re.fullmatch(r'-?\d{1,19}/\d{1,10}:-?\d{1,19}:\d{1,10}', value):
            result[key] = value
        elif isinstance(rule, tuple) and re.fullmatch(r'-?\d{1,12}(?:\.\d{1,12})?', value):
            number = float(value) if '.' in value else int(value)
            if math.isfinite(number) and rule[0] <= number <= rule[1]:
                result[key] = number
    return result

def host_control(text):
    line = text.strip()
    pattern = (r'HOST_AUDIO_CONTROL outcome=(passed|failed) itemStatus=([0-2]) playerStatus=([0-2]) '
        r'timeControl=([0-2]) progressed=(true|false) maximumTime=(\d{1,8}(?:\.\d{1,20})?) '
        r'eos=(true|false) elapsed=(\d{1,8}(?:\.\d{1,20})?) syntheticDuration=2 '
        r'qualification=host-control-not-ios-acceptance')
    match = re.fullmatch(pattern, line)
    if not match:
        return {'outcome': 'unavailable', 'qualification': 'host-control-not-ios-acceptance'}
    values = match.groups()
    result = {'outcome': values[0], 'itemStatus': int(values[1]), 'playerStatus': int(values[2]),
        'timeControl': int(values[3]), 'progressed': values[4] == 'true', 'maximumTime': float(values[5]),
        'eos': values[6] == 'true', 'elapsed': float(values[7]), 'syntheticDuration': 2,
        'qualification': 'host-control-not-ios-acceptance'}
    if result['outcome'] == 'passed' and not (result['eos'] and result['progressed'] and result['maximumTime'] >= 1.9):
        result['outcome'] = 'unverified'
    return result

def base(candidate, run_id, kind, functional='unavailable', cpu='unavailable'):
    if not re.fullmatch(r'[0-9a-f]{40}', candidate) or type(run_id) is not int or run_id <= 0:
        raise ValueError('invalid provenance')
    if functional not in OUTCOMES or cpu not in OUTCOMES:
        raise ValueError('invalid step outcome')
    return {'version': 1, 'kind': kind, 'candidate': candidate, 'run_id': run_id,
        'functional': functional, 'cpu': cpu, 'availability': 'unavailable', 'counts': {},
        'failure_records': 0, 'failures': [], 'truncated': False, 'host': host_control(''),
        'source_aac_fixture': source_aac_stages(())}

def probe(*, candidate, run_id):
    return base(candidate, run_id, 'delivery-probe')

def encode(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=True, allow_nan=False).encode()

def section(text, name, limit):
    """Read a bounded balanced diagnostic field, excluding later trace text."""
    marker = name + '={'
    start = text.find(marker)
    if start < 0:
        return None
    start += len(marker)
    depth = 1
    for index in range(start, min(len(text), start + limit + 1)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index]
    return None

def collect(schema, summary, *, candidate, run_id, functional, cpu, host_text):
    module = helper()
    approved = module.schema_keys(schema)
    if 'testFailures' not in approved or not isinstance(summary.get('testFailures'), list):
        raise ValueError('unsupported summary schema')
    if not approved.intersection({'failureText', 'message'}):
        raise ValueError('unsupported assertion schema')
    result = base(candidate, run_id, 'native-results', functional, cpu)
    result['availability'] = 'verified-summary'
    result['host'] = host_control(host_text)
    # Xcode 27 wraps its root declaration in schemas.Summary. Do not search
    # arbitrary nested types for a count field with the same name.
    count_schema = schema.get('schemas', {}).get('Summary', schema)
    counts = json.loads(module.summary_lines(count_schema, summary)[0].split('=', 1)[1])
    # Result is free-form in the tool schema; publish only its known vocabulary.
    result['counts'] = {k: v for k, v in counts.items() if type(v) is int or v in ('Passed', 'Failed', 'Skipped', 'Unknown')}
    failures = summary['testFailures']
    result['failure_records'] = len(failures)
    for record in failures[:64]:
        if not isinstance(record, dict):
            raise ValueError('invalid failure record')
        identifier = record.get('testIdentifierString', '')
        identifier = identifier[:-2] if isinstance(identifier, str) and identifier.endswith('()') else identifier
        case = identifier if isinstance(identifier, str) and re.fullmatch(r'(?:[A-Za-z][A-Za-z0-9_]{0,95}/){1,2}test[A-Za-z0-9_]{1,200}', identifier) else None
        raw = record.get('failureText', record.get('message', ''))
        raw = raw[:4096] if isinstance(raw, str) else ''
        runtime = section(raw, 'runtime', 128)
        detail = section(raw, 'detail', 1024)
        phase = re.search(r'\bphase=([^\s]+)', raw)
        route = re.search(r'\broute=(native|managed)(?=\s|$)', raw)
        result['failures'].append({'case': case, 'assertion': 'native-hls' if 'NATIVE_HLS_SMOKE_FAILURE' in raw else 'assertion',
            'phase': phase[1] if phase and phase[1] in PHASES else None,
            'route': route[1] if route else None, 'runtime_status': 'observed' if runtime is not None else 'unavailable',
            'runtime': scalars(runtime, RUNTIME) if runtime is not None else {},
            'evidence': scalars(detail, EVIDENCE) if detail is not None else {}})
    result['truncated'] = len(failures) > len(result['failures'])
    while len(encode(result)) > MAX_BYTES and result['failures']:
        result['failures'].pop()
        result['truncated'] = True
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('probe', 'collect'))
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--host', type=Path)
    parser.add_argument('--fixture-log', type=Path)
    parser.add_argument('--functional', default='unavailable')
    parser.add_argument('--cpu', default='unavailable')
    args = parser.parse_args()
    result = probe(candidate=args.candidate, run_id=args.run_id)
    if args.mode == 'collect':
        result = base(args.candidate, args.run_id, 'native-results', args.functional, args.cpu)
        host = args.host.read_text() if args.host and args.host.exists() and args.host.stat().st_size <= 8192 else ''
        result['host'] = host_control(host)
        if args.bundle and args.bundle.is_dir() and args.bundle.suffix == '.xcresult':
            module = helper()
            schema = json.loads(module.run(['get', 'test-results', 'summary', '--schema']))
            summary = json.loads(module.run(['get', 'test-results', 'summary', '--path', str(args.bundle)]))
            result = collect(schema, summary, candidate=args.candidate, run_id=args.run_id,
                functional=args.functional, cpu=args.cpu, host_text=host)
    if args.mode == 'collect' and args.fixture_log and args.fixture_log.is_file():
        # Keep raw output local. Bounded reads and strict fixed vocabulary prevent
        # URLs, assertion text, UUIDs and arbitrary error domains reaching JSON.
        with args.fixture_log.open(encoding='utf-8', errors='replace') as log:
            result['source_aac_fixture'] = source_aac_stages(iter(lambda: log.readline(1025), ''))
        while len(encode(result)) > MAX_BYTES and result['failures']:
            result['failures'].pop()
            result['truncated'] = True
        while len(encode(result)) > MAX_BYTES and result['source_aac_fixture']['events']:
            result['source_aac_fixture']['events'].pop(0)
            result['source_aac_fixture']['truncated'] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encode(result))
    print('IOS_DIAGNOSTIC_JSON=written bytes=' + str(len(encode(result))))

if __name__ == '__main__':
    main()
