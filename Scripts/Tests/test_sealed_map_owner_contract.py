#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source guard for sealed map owner storage; Apple fixtures verify runtime use.

The existing ASan fixtures caught NSLock's separately allocated storage exceeding
its class-size estimate. This guard prevents reintroducing that extra allocation;
it does not substitute for the real owner malloc_size check or Apple execution.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Sources/VPlayerPlayback/HLS/CompletedMediaEvidence.swift").read_text()
OWNER = SOURCE.split("fileprivate final class SealedDecodeMapPrepayment:", 1)[1].split(
    "struct SealedDecodeMapArray<", 1)[0]


class SealedMapOwnerContractTests(unittest.TestCase):
    def test_claim_state_is_inline_in_the_measured_owner(self):
        self.assertIn("import Synchronization", SOURCE.splitlines()[:12])
        self.assertIn("private let claimed = Mutex(false)", OWNER)
        self.assertNotIn("NSLock", OWNER,
                         "a separately allocated lock is not covered by the owner measurement")
        allocation = OWNER.split("static var allocationBytes: Int {", 1)[1].split("}", 1)[0]
        self.assertIn("malloc_good_size(class_getInstanceSize(Self.self))", allocation)
        self.assertNotIn("+", allocation,
                         "inline synchronization must not be billed as another heap allocation")

    def test_owner_is_paid_before_allocation_and_actual_size_is_checked(self):
        reserve = OWNER.split("static func reserve(bytes:", 1)[1].split("func claim()", 1)[0]
        self.assertLess(reserve.index("HLSDeliveryApplicationChargeLedger.shared.reserve("),
                        reserve.index("SealedDecodeMapPrepayment(bytes:"))
        self.assertIn("malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque()))", reserve)
        self.assertIn("guard actual <= allocationBytes else", reserve)
        self.assertIn("throw CompletedMediaEvidenceError.capacityExceeded", reserve)

    def test_claim_is_one_time_and_release_stays_with_the_owner(self):
        claim = OWNER.split("func claim()", 1)[1].split("deinit", 1)[0]
        self.assertIn("try claimed.withLock { claimed in", claim)
        self.assertIn("guard !claimed else { throw CompletedMediaEvidenceError.identityMismatch }", claim)
        self.assertLess(claim.index("claimed = true"), claim.index("return owned"))
        self.assertNotIn("release(", claim)
        self.assertIn("deinit { HLSDeliveryApplicationChargeLedger.shared.release(owned) }", OWNER)


if __name__ == "__main__":
    unittest.main()
