#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source-level envelope ordering checks; not Apple runtime or allocation proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROXY = ROOT / 'Sources/VPlayerPlayback/HLS/Proxy'


class ProxyCallbackEnvelopeContract(unittest.TestCase):
    def test_reservation_precedes_body_admission_and_covers_both_owners(self):
        budget = (PROXY / 'HLSApplicationLifetimeCharge.swift').read_text()
        upstream = (PROXY / 'HLSProxyUpstream.swift').read_text()
        self.assertIn('static let domainBytes = 32 * 1_024 * 1_024', budget)
        self.assertIn('static let maximumTransfers = 8', budget)
        self.assertIn('static let maximumConnections = 16', budget)
        self.assertIn('try reserve(bytes: 512 * 1_024, kind: 1)', budget)
        self.assertIn('budget.reserve(bytes: 2 * maximum)', budget)
        response = upstream[upstream.index('didReceive response:'):upstream.index('didReceive data:')]
        self.assertLess(response.index('reserveBodyEnvelope('), response.index('completionHandler(.allow)'))
        body = upstream[upstream.index('didReceive data:'):upstream.index('didCompleteWithError')]
        self.assertLess(body.index('terminal == nil'), body.index('beginCallback('))
        self.assertLess(body.index('envelope.accepts(data.count)'), body.index('sendBlocking(data, retaining: envelope)'))
        self.assertNotIn('subdata(', body)
        self.assertNotIn('Task {', body)

    def test_send_retains_paid_window_through_physical_callback_tail(self):
        source = (PROXY / 'HLSProxyConnection.swift').read_text()
        send = source[source.index('func sendBlocking('):source.index('func installUpstream(')]
        self.assertIn('[nativeSends, io, envelope]', send)
        self.assertIn('withExtendedLifetime(envelope)', send)
        self.assertLess(send.index('withExtendedLifetime(envelope)'), send.index('nativeSends.leave()'))


if __name__ == '__main__':
    unittest.main()
