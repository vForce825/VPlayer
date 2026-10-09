#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable source contracts only; Darwin clock and aggregation need native XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CPUWorkerServiceContracts(unittest.TestCase):
    def test_thread_clock_is_checked_and_requested_qos_is_not_effective_qos(self):
        source = (ROOT / 'Sources/VPlayerPlayback/ProcessingCPU/CPUVideoProcessing.swift').read_text()
        self.assertIn('clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0', source)
        self.assertIn('qos_class_self()', source)
        self.assertNotIn('effectiveQoS', source)
        self.assertIn('guard let start, let end', source)

    def test_optional_telemetry_uses_disjoint_bounded_storage_and_joins_before_reading(self):
        source = (ROOT / 'Sources/VPlayerPlayback/ProcessingCPU/CPUVideoProcessing.swift').read_text()
        self.assertIn('precondition((1...4).contains(count))', source)
        self.assertIn('timing == nil ? nil : CPUYADIFWorkerSlots(count: workers)', source)
        self.assertIn('storage.advanced(by: worker).pointee = observation', source)
        self.assertIn('max(1, min(4, activeProcessors))', source)
        start = source.index('DispatchQueue.concurrentPerform(iterations: workers)')
        self.assertGreater(source.index('observations?.summary(', start), start)

    def test_cpu_window_labels_partial_measurement_and_keeps_old_contract(self):
        source = (ROOT / 'Sources/VPlayerPlayback/ProcessingCPU/AdaptiveVideoProcessing.swift').read_text()
        for field in ['pair_budget_ms_25i=40', 'parallel_wall=', 'worker_cpu_clock=',
                      'worker_cpu_ms=', 'worker_samples=', 'worker_wall_ms=',
                      'worker_start_spread=', 'worker_join_tail=', 'requested_qos_start=',
                      'requested_qos_end=', 'thermal_at_log=', 'low_power_at_log=',
                      'surface=', 'depth=', 'workers=', 'active_processors=']:
            self.assertIn(field, source)
        self.assertIn('>= 1 else { return nil }', source)
        self.assertIn('"unverified"', source)


if __name__ == '__main__':
    unittest.main()
