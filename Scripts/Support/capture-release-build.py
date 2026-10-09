#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Run a compiler only after bounded capture has recorded starting source provenance.

The wrapper and its native child remain in the caller's process group. The iOS
supervisor therefore retains ownership of both across its existing time limit.
Successful capture is evidence collection; artifact verification is still required.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys

_spec = importlib.util.spec_from_file_location('release_artifact_guard',
    Path(__file__).resolve().parents[1] / 'verify-release-artifacts.py')
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


def capture_command(command, log, tee=False):
    class NativeStream:
        process = None
        tee_failed = False

        def read(self, size):
            if self.process is None:
                # capture() takes its initial source snapshot before first read.
                self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            chunk = self.process.stdout.read1(size)
            if chunk and tee and not self.tee_failed:
                try:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except OSError:
                    self.tee_failed = True  # Keep draining; never strand a compiler on its output pipe.
            if not chunk:
                # A native process may close stdout before exiting. The ending
                # source snapshot must follow actual termination, not pipe EOF.
                self.process.wait()
            return chunk

    stream = NativeStream()
    try:
        complete = guard.capture(stream, log)
    finally:
        if stream.process is not None:
            stream.process.stdout.close()
    code = stream.process.returncode
    return code if code else int(not complete or stream.tee_failed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--tee', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a native build command is required')
    try:
        code = capture_command(command, args.log, args.tee)
        return code if code >= 0 else 128 - code
    except (OSError, subprocess.SubprocessError):
        print('RELEASE_BUILD_CAPTURE=failed', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
