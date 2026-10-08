#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source guards only; native tests verify physical allocator sizes/ownership."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class PausedWorkspaceMallocTests(unittest.TestCase):
    def test_precharge_and_owner_use_same_allocator_with_checked_alignment(self):
        text=(ROOT/'Sources/VPlayerPlayback/HLS/SealedMediaStore.swift').read_text()
        helper=text.split('struct PausedWorkspaceBuffer<Element>',1)[1].split('final class PausedCoverageWorkspace',1)[0]
        for token in ['HLSChecked.multiply', 'HLSChecked.add', 'malloc_good_size(requested)',
                      'allocator(requested)', 'malloc_size(owner)', 'deallocator(owner)', 'bindMemory(to: Element.self']:
            self.assertIn(token,helper)
        workspace=text.split('final class PausedCoverageWorkspace',1)[1].split('/// 只有 store',1)[0]
        self.assertNotIn('.allocate(capacity:',workspace)
        self.assertNotIn('.deallocate()',workspace)
        self.assertLess(workspace.index('PlaybackResourceContextLedger.shared.reserve('),workspace.index('let workspace = try Self('))
        for component in ['ordinals','cursors','heap']:
            self.assertIn(f'actual.{component} <= limits.{component}',workspace)
    def test_native_tests_cover_small_buckets_partial_failure_and_last_alias(self):
        text=(ROOT/'Tests/VPlayerTests/Playback/HLS/LoopbackHTTPServerTests.swift').read_text()
        for token in ['[1, 16, 17, 24, 31, 32, 384]', 'SIMD8<UInt64>', 'for failureAt in 1...3',
                      'XCTAssertEqual(allocationAttempts, 0', 'testPausedWorkspaceChargeSurvivesUntilTheFinalWorkspaceAliasIsReleased']:
            self.assertIn(token,text)
    def test_alignment_padding_bound_for_all_offsets(self):
        for alignment in [1,2,4,8,16,32,64,128]:
            for remainder in range(alignment):
                offset=0 if remainder==0 else alignment-remainder
                self.assertLessEqual(offset,alignment-1)
                self.assertEqual((remainder+offset)%alignment,0)
if __name__=='__main__':unittest.main()
