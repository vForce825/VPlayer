#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source guard only; launch argument behavior is covered by native XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/VPlayerApp/AppLaunchConfiguration.swift'


def select_debug_branch(source, *, debug):
    active = True
    stack = []
    result = []
    for line in source.splitlines():
        directive = line.strip()
        if directive.startswith('#if '):
            if directive != '#if DEBUG':
                raise AssertionError('Review new compile condition: ' + directive)
            stack.append((active, debug))
            active = active and debug
        elif directive == '#else':
            parent, condition = stack[-1]
            active = parent and not condition
        elif directive == '#endif':
            active, _ = stack.pop()
        elif active:
            result.append(line)
    if stack:
        raise AssertionError('Unclosed compile condition')
    return '\n'.join(result)


class ReleaseLaunchConfigurationTests(unittest.TestCase):
    def test_release_has_no_test_argument_scans_or_fixture_selection(self):
        release = select_debug_branch(SOURCE.read_text(), debug=False)
        initializer = release.split('    init(arguments: [String]) {', 1)[1]
        self.assertNotIn('arguments.', initializer)
        for flag in ('-ui-fixture', '-acceptance-playback', '-ui-playback-fixture',
                     '-uiTestResetPlaybackSettings'):
            self.assertNotIn(flag, initializer)
        for assignment in ('mode = .live', 'resetsPlaybackSettings = false',
                           'playbackFixture = nil'):
            self.assertIn(assignment, initializer)

    def test_debug_keeps_fixture_reset_and_acceptance_capability(self):
        debug = select_debug_branch(SOURCE.read_text(), debug=True)
        for flag in ('-ui-fixture', '-acceptance-playback', '-ui-playback-fixture',
                     '-uiTestResetPlaybackSettings'):
            self.assertIn(flag, debug)
        for statement in ('mode = .seededFixture', 'mode = .acceptance',
                          'resetsPlaybackSettings = arguments.contains(',
                          'playbackFixture = arguments[flagIndex + 1]'):
            self.assertIn(statement, debug)


if __name__ == '__main__':
    unittest.main()
