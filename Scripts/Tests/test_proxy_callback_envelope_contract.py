#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source ownership/wiring guards; not Apple runtime or SDK allocation proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROXY = ROOT / 'Sources/VPlayerPlayback/HLS/Proxy'


class ProxyReadWindowContract(unittest.TestCase):
    def test_fixed_window_is_paid_before_async_bytes_without_data_callback_queue(self):
        budget = (PROXY / 'HLSApplicationLifetimeCharge.swift').read_text()
        source = (PROXY / 'HLSProxyUpstream.swift').read_text()
        self.assertIn('static let domainBytes = 32 * 1_024 * 1_024', budget)
        self.assertIn('static let maximumTransfers = 8', budget)
        self.assertIn('static let maximumConnections = 16', budget)
        self.assertIn('try reserve(bytes: 512 * 1_024, kind: 1)', budget)
        self.assertIn('budget.reserve(bytes: 2 * maximum)', budget)
        self.assertLess(source.index('reserveBodyEnvelope()'), source.index('session.bytes(for:'))
        self.assertNotIn('didReceive data:', source)
        self.assertNotIn('URLSessionDataDelegate', source)
        self.assertNotIn('AsyncStream', source)
        self.assertNotIn('append(byte)', source)
        self.assertIn('pipe.publish(byte, at: position)', source)
        self.assertIn('written.store(position + 1, ordering: .sequentiallyConsistent)', budget)
        self.assertIn('readerWaiting.store(true, ordering: .sequentiallyConsistent)', budget)

    def test_reuse_waits_for_actual_backing_release_and_send_tail(self):
        budget = (PROXY / 'HLSApplicationLifetimeCharge.swift').read_text()
        source = (PROXY / 'HLSProxyConnection.swift').read_text()
        self.assertIn('Data(bytesNoCopy:', budget)
        self.assertIn('deallocator: .custom', budget)
        self.assertIn('await borrow.waitForRelease()', budget)
        send = source[source.index('func sendBytes('):source.index('private func claimResponse()')]
        self.assertIn('withExtendedLifetime(envelope)', send)
        self.assertIn('queue.async', send)

    def test_cancellation_joins_consumer_and_graceful_session_invalidation(self):
        source = (PROXY / 'HLSProxyUpstream.swift').read_text()
        self.assertIn('try await consumer.value', source)
        self.assertIn('finishTasksAndInvalidate()', source)
        self.assertIn('await waitForInvalidation()', source)
        self.assertNotIn('invalidateAndCancel()', source)
        self.assertIn('pending.0?.cancel()', source)
        self.assertIn('pending.1?.cancel()', source)
        self.assertIn('await reader.value', source)
        self.assertIn('pipe.abort(error); reader.cancel(); upstream.cancel()', source)


if __name__ == '__main__':
    unittest.main()
