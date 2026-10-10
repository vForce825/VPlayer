#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable source contracts only; Darwin clock and aggregation need native XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CPU_SOURCE = ROOT / 'Sources/VPlayerPlayback/ProcessingCPU/CPUVideoProcessing.swift'
ADAPTIVE_SOURCE = ROOT / 'Sources/VPlayerPlayback/ProcessingCPU/AdaptiveVideoProcessing.swift'


def ios_compiled_source(source, *, debug=False, diagnostics=False):
    """Select known Swift conditions; this is a source guard, not a compiler."""
    conditions = {
        'os(iOS)': True,
        'DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS': debug or diagnostics,
    }
    active = True
    stack = []
    lines = []
    for line in source.splitlines():
        directive = line.strip()
        if directive.startswith('#if '):
            condition = conditions[directive[4:]]
            stack.append((active, condition))
            active = active and condition
        elif directive == '#else':
            parent, condition = stack[-1]
            active = parent and not condition
        elif directive == '#endif':
            active, _ = stack.pop()
        elif active:
            lines.append(line)
    if stack:
        raise AssertionError('Unclosed Swift compilation condition')
    return '\n'.join(lines)


class CPUWorkerServiceContracts(unittest.TestCase):
    def test_shipping_release_excludes_cpu_measurement_and_window_logging(self):
        cpu = ios_compiled_source(CPU_SOURCE.read_text())
        adaptive = ios_compiled_source(ADAPTIVE_SOURCE.read_text())
        for source in (cpu, adaptive):
            for diagnostic in ('systemUptime', 'CPUYADIFThreadClock', 'qos_class_self()',
                               'CPUYADIFWorkerSlots', 'AdaptiveYADIFDiagnostics',
                               'IOS_VIDEO_CPU', 'IOS_VIDEO_HANDOFF', 'import OSLog',
                               'thermalState', 'isLowPowerModeEnabled'):
                self.assertNotIn(diagnostic, source)
        self.assertNotIn('var timings = CPUYADIFProcessingTimings()', cpu)
        self.assertNotIn('timing?(timings)', cpu)

    def test_debug_and_explicit_diagnostic_release_retain_measurements(self):
        for configuration in ({'debug': True}, {'diagnostics': True}):
            with self.subTest(configuration=configuration):
                cpu = ios_compiled_source(CPU_SOURCE.read_text(), **configuration)
                adaptive = ios_compiled_source(ADAPTIVE_SOURCE.read_text(), **configuration)
                self.assertIn('clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0', cpu)
                self.assertIn('qos_class_self()', cpu)
                self.assertIn('CPUYADIFWorkerSlots(count: workers)', cpu)
                self.assertIn('timing?(timings)', cpu)
                self.assertIn('private let diagnostics = AdaptiveYADIFDiagnostics()', adaptive)
                self.assertIn('diagnostics.completeCPU(', adaptive)
                self.assertIn('IOS_VIDEO_CPU', adaptive)

    def test_every_configuration_preserves_cpu_kernel_and_handoff_safety(self):
        for configuration in ({}, {'debug': True}, {'diagnostics': True}):
            with self.subTest(configuration=configuration):
                cpu = ios_compiled_source(CPU_SOURCE.read_text(), **configuration)
                adaptive = ios_compiled_source(ADAPTIVE_SOURCE.read_text(), **configuration)
                for required in ('YADIFSurfaceValidator.validate(expected)',
                                 'CVPixelBufferLockBaseAddress(buffer, .readOnly)',
                                 'CVPixelBufferUnlockBaseAddress(entry.buffer, entry.flags)',
                                 'max(1, min(4, activeProcessors))',
                                 'DispatchQueue.concurrentPerform(iterations: workers)',
                                 'operation.run(worker: worker, workers: workers)',
                                 'guard result.succeeded else { throw .commandFailed }'):
                    self.assertIn(required, cpu)
                for required in ('fence.wait(timeout: .now() + .seconds(5))',
                                 'limiter.isCurrent(revision)', 'limiter.retire()',
                                 'work.clear()', 'ticket.finish()',
                                 'gpuCompletion.submissionReturned()',
                                 'observer?(.completed(', 'observer?(.fenceWaitBegan('):
                    self.assertIn(required, adaptive)

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
