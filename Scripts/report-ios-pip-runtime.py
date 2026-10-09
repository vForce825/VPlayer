#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Relay original output and report only the native test's fixed PiP API marker.

This supplementary capability evidence is never a native PiP test verdict or a
framework skip reason. The caller must use pipefail to preserve native failures.
"""
import argparse
import json
import os
import re
import sys

PREFIX = b'IOS_PIP_RUNTIME_SUPPORTED='
CHUNK_BYTES = 16_384
MAX_LINE_BYTES = 64
TEST = ('VPlayeriOSTests/IOSNativePictureInPictureTests/'
        'testRealSampleBufferPiPStartsRestoresAndClosesTheRetainedSession')


class Capability:
    def __init__(self):
        self.pending = bytearray()
        self.oversized = False
        self.markers = 0
        self.invalid = 0
        self.values = 0

    def finish_line(self):
        if self.pending.startswith(PREFIX):
            line = bytes(self.pending).removesuffix(b'\r')
            if not self.oversized and line in (PREFIX + b'false', PREFIX + b'true'):
                self.markers = min(2, self.markers + 1)
                self.values |= 1 if line == PREFIX + b'false' else 2
            else:
                self.invalid = min(2, self.invalid + 1)
        self.pending.clear()
        self.oversized = False

    def consume(self, chunk):
        # Retain only a bounded line prefix, even for huge unterminated output.
        start = 0
        while start < len(chunk):
            end = chunk.find(b'\n', start)
            boundary = len(chunk) if end < 0 else end
            available = MAX_LINE_BYTES - len(self.pending)
            self.pending.extend(chunk[start:min(boundary, start + available)])
            if boundary - start > available:
                self.oversized = True
            if end < 0:
                break
            self.finish_line()
            start = end + 1

    def record(self, candidate):
        verified_candidate = candidate if re.fullmatch(r'[0-9a-f]{40}', candidate) else 'unavailable'
        reason = None
        if verified_candidate == 'unavailable':
            reason = 'candidate_unavailable'
        elif self.invalid:
            reason = 'malformed_marker'
        elif not self.markers:
            reason = 'missing_marker'
        elif self.markers != 1:
            reason = 'conflicting_markers' if self.values == 3 else 'duplicate_markers'
        result = {'test': TEST, 'candidate': verified_candidate,
                  'evidence': 'capability_api_only_not_native_pip_pass',
                  'qualification': 'simulator_evidence_only_physical_iphone_not_qualified',
                  'status': 'Unverified' if reason else 'Observed',
                  'supported': None if reason else self.values == 2,
                  'marker_count': self.markers, 'invalid_marker_count': self.invalid}
        if reason:
            result['reason'] = reason
        return result


def relay(source, destination):
    state = Capability()
    read = getattr(source, 'read1', source.read)
    while chunk := read(CHUNK_BYTES):
        destination.write(chunk)
        destination.flush()
        state.consume(chunk)
    state.finish_line()
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True)
    args = parser.parse_args()
    state = relay(sys.stdin.buffer, sys.stdout.buffer)
    destination = os.environ.get('GITHUB_STEP_SUMMARY')
    if not destination:
        print('IOS_PIP_RUNTIME_SUMMARY_UNAVAILABLE=destination_missing', file=sys.stderr)
        return
    # Every published value is fixed vocabulary, a boolean, a capped count, or
    # a validated SHA. Never publish ordinary output, URLs, paths or errors.
    record = json.dumps(state.record(args.candidate), sort_keys=True, separators=(',', ':'))
    try:
        with open(destination, 'a', encoding='utf-8') as output:
            output.write('\n<pre><code>\nIOS_PIP_RUNTIME_CAPABILITY=' + record + '\n</code></pre>\n')
    except (OSError, UnicodeError):
        print('IOS_PIP_RUNTIME_SUMMARY_UNAVAILABLE=write_failed', file=sys.stderr)


if __name__ == '__main__':
    main()
