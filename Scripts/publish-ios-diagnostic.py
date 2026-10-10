#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Publish bounded diagnostics with the job token and verify exact readback."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import urllib.request
import urllib.error

MAX_COMMENT_BYTES = 48 * 1024
spec = importlib.util.spec_from_file_location('ios_diagnostic', Path(__file__).with_name('report-ios-diagnostic.py'))
REPORT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REPORT)

def comment_body(payload):
    if not isinstance(payload, dict):
        raise ValueError('invalid payload')
    expected = REPORT.base(payload.get('candidate', ''), payload.get('run_id'), payload.get('kind'),
        payload.get('functional'), payload.get('cpu'))
    if set(payload) != set(expected) or payload['version'] != 1 or payload['kind'] not in ('delivery-probe', 'native-results'):
        raise ValueError('invalid payload fields')
    if payload['availability'] not in ('unavailable', 'verified-summary') or type(payload['truncated']) is not bool:
        raise ValueError('invalid availability')
    if type(payload['failure_records']) is not int or not 0 <= payload['failure_records'] <= 2**63 - 1:
        raise ValueError('invalid record count')
    counts = payload['counts']
    if not isinstance(counts, dict):
        raise ValueError('invalid counts')
    for key, value in counts.items():
        if key == 'result' and value in ('Passed', 'Failed', 'Skipped', 'Unknown'):
            continue
        if key not in REPORT.helper().SUMMARY_FIELD_TYPES or key == 'result' or type(value) is not int or not 0 <= value <= 2**63 - 1:
            raise ValueError('invalid count')
    failures = payload['failures']
    if not isinstance(failures, list) or len(failures) > 64 or len(failures) > payload['failure_records']:
        raise ValueError('invalid failures')
    for failure in failures:
        if not isinstance(failure, dict) or set(failure) != {'case', 'assertion', 'phase', 'route', 'runtime_status', 'runtime', 'evidence'}:
            raise ValueError('invalid failure fields')
        if failure['case'] is not None and not (isinstance(failure['case'], str) and re.fullmatch(r'(?:[A-Za-z][A-Za-z0-9_]{0,95}/){1,2}test[A-Za-z0-9_]{1,200}', failure['case'])):
            raise ValueError('invalid case')
        if failure['assertion'] not in ('assertion', 'native-hls') or failure['phase'] not in REPORT.PHASES | {None} or failure['route'] not in (None, 'native', 'managed') or failure['runtime_status'] not in ('observed', 'unavailable'):
            raise ValueError('invalid failure values')
        for field, rules in (('runtime', REPORT.RUNTIME), ('evidence', REPORT.EVIDENCE)):
            values = failure[field]
            if not isinstance(values, dict):
                raise ValueError('invalid scalars')
            text = ' '.join(k + '=' + (str(v).lower() if type(v) is bool else str(v)) for k, v in values.items())
            if REPORT.scalars(text, rules) != values:
                raise ValueError('invalid scalars')
    fixture = payload['source_aac_fixture']
    if (not isinstance(fixture, dict) or set(fixture) != {'events', 'truncated', 'errors'}
            or type(fixture['truncated']) is not bool or not isinstance(fixture['events'], list)
            or len(fixture['events']) > 128 or not isinstance(fixture['errors'], list)
            or len(fixture['errors']) > 4):
        raise ValueError('invalid source AAC fixture records')
    for event in fixture['events'] + fixture['errors']:
        if (not isinstance(event, dict) or set(event) != {'attempt', 'stage', 'index', 'elapsed_ms', 'category', 'code'}
                or any(type(event[k]) is not int for k in ('attempt', 'index', 'elapsed_ms', 'code'))
                or not isinstance(event['stage'], str) or not isinstance(event['category'], str)):
            raise ValueError('invalid source AAC fixture event')
        line = ('SOURCE_AAC_FIXTURE_STAGE attempt={attempt} stage={stage} index={index} '
                'elapsed-ms={elapsed_ms} category={category} code={code}').format(**event)
        if REPORT.source_aac_stages([line])['events'] != [event]:
            raise ValueError('invalid source AAC fixture scalars')
    if any(event['category'] == 'none' for event in fixture['errors']):
        raise ValueError('invalid source AAC fixture error')
    host = payload['host']
    if host == REPORT.host_control(''):
        pass
    elif isinstance(host, dict) and set(host) == {'outcome', 'itemStatus', 'playerStatus', 'timeControl', 'progressed', 'maximumTime', 'eos', 'elapsed', 'syntheticDuration', 'qualification'}:
        text = 'HOST_AUDIO_CONTROL ' + ' '.join(k + '=' + (str(host[k]).lower() if type(host[k]) is bool else str(host[k]))
            for k in ('outcome', 'itemStatus', 'playerStatus', 'timeControl', 'progressed', 'maximumTime', 'eos', 'elapsed', 'syntheticDuration', 'qualification'))
        # Unverified data is not promoted to a passing host control.
        original = host['outcome']
        if original == 'unverified':
            text = text.replace('outcome=unverified', 'outcome=passed')
        if REPORT.host_control(text) != host:
            raise ValueError('invalid host')
    else:
        raise ValueError('invalid host fields')
    encoded = REPORT.encode(payload)
    if len(encoded) > REPORT.MAX_BYTES:
        raise ValueError('payload too large')
    body = ('<!-- VPLAYER_IOS_DIAGNOSTIC_V1 -->\n'
        'iOS diagnostic delivery: **' + payload['kind'] + '**. Root cause remains unconfirmed; host control is not iOS acceptance.\n\n'
        '```json\n' + encoded.decode() + '\n```')
    if len(body.encode()) > MAX_COMMENT_BYTES:
        raise ValueError('comment too large')
    return body

def publish(payload, repository, pr_number, transport):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or '..' in repository or type(pr_number) is not int or pr_number <= 0:
        raise ValueError('invalid destination')
    body = comment_body(payload)
    created = transport('POST', '/repos/' + repository + '/issues/' + str(pr_number) + '/comments', {'body': body})
    identifier = created.get('id')
    if type(identifier) is not int or identifier <= 0:
        raise ValueError('missing comment receipt')
    readback = transport('GET', '/repos/' + repository + '/issues/comments/' + str(identifier), None)
    if readback.get('id') != identifier or readback.get('body') != body:
        raise ValueError('comment readback mismatch')
    return {'comment_id': identifier, 'sha256': hashlib.sha256(body.encode()).hexdigest()}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--pr', type=int, required=True)
    args = parser.parse_args()
    if args.input.stat().st_size > REPORT.MAX_BYTES:
        raise ValueError('payload too large')
    token = os.environ['GITHUB_TOKEN']
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, response, code, message, headers, destination):
            # Keep the ephemeral job token on the exact official API origin.
            raise ValueError('official API redirect rejected')
    opener = urllib.request.build_opener(NoRedirect())
    def transport(method, path, value):
        request = urllib.request.Request('https://api.github.com' + path,
            data=json.dumps(value).encode() if value is not None else None, method=method,
            headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28'})
        try:
            with opener.open(request, timeout=30) as response:
                data = response.read(128 * 1024 + 1)
                if len(data) > 128 * 1024:
                    raise ValueError('response too large')
                return json.loads(data)
        except urllib.error.HTTPError as error:
            raise ValueError('official API HTTP status=' + str(error.code)) from None
        except urllib.error.URLError:
            raise ValueError('official API unavailable') from None
    receipt = publish(json.loads(args.input.read_bytes()), args.repository, args.pr, transport)
    print('IOS_DIAGNOSTIC_DELIVERY_VERIFIED=' + json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    main()
