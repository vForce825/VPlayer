#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source guard for FIFO owner accounting; CoreMedia behavior runs on Apple CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Sources/VPlayerPlayback/Media/BoundedMediaQueue.swift").read_text()
RESERVOIR = SOURCE.split("struct CompressedVideoReservoir:", 1)[1]


class CompressedVideoRetentionContractTests(unittest.TestCase):
    def test_byte_limit_accounts_for_distinct_retained_owners(self):
        fits = RESERVOIR.split("private func fits(", 1)[1]
        self.assertIn("sourceBacking", fits,
                      "sample size alone omits the original AU owner retained for evidence")
        self.assertIn("source.ownerIdentity", fits)
        self.assertIn("source.byteCount", fits)
        self.assertIn("CMBlockBufferGetDataLength(block)", fits)
        self.assertIn("ObjectIdentifier(block)", fits)
        self.assertIn("addingReportingOverflow", fits)
        self.assertNotIn("sourceByteRange.length", fits)

    def test_pop_releases_owned_slot_before_advancing_head(self):
        pop = RESERVOIR.split("mutating func popFirst()", 1)[1].split(
            "mutating func removeFirst()", 1)[0]
        self.assertIn("storage[head] = nil", pop,
                      "consumed payload must not stay retained in the uncompacted array prefix")
        self.assertLess(pop.index("storage[head] = nil"), pop.index("head += 1"))

    def test_remove_prefix_releases_all_slots(self):
        remove = RESERVOIR.split("mutating func removeFirst(_ count:", 1)[1].split(
            "mutating func removeAll(", 1)[0]
        self.assertIn("storage[index] = nil", remove)


if __name__ == "__main__":
    unittest.main()
