// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class AVPlayerLogSnapshotCacheTests: XCTestCase {
    func testInstallationRequestsInitialReadWithoutNotification() throws {
        let cache = AVPlayerLogSnapshotCache()
        let object = NSObject()
        let item = makeItem(1)
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        let ticket = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.isCurrent(ticket))
        XCTAssertEqual(cache.snapshot(item: item, objectIdentity: ObjectIdentifier(object)), .empty)
    }

    func testNotificationBurstCoalescesToOneInFlightAndOneFollowup() throws {
        let cache = AVPlayerLogSnapshotCache()
        let object = NSObject()
        let item = makeItem(2)
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        let first = try XCTUnwrap(cache.beginRefresh())
        for _ in 0..<10_000 {
            cache.requestRefresh(item: item, objectIdentity: ObjectIdentifier(object))
            XCTAssertNil(cache.beginRefresh())
        }
        XCTAssertTrue(cache.complete(first, snapshot: .init(accessEventCount: 4, errorEventCount: 1)))
        let followup = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.complete(followup, snapshot: .init(accessEventCount: 5, errorEventCount: 2)))
        XCTAssertNil(cache.beginRefresh())
        XCTAssertEqual(cache.snapshot(item: item, objectIdentity: ObjectIdentifier(object)),
            .init(accessEventCount: 5, errorEventCount: 2))
    }

    func testItemSwapSuppressesLateReadAndKeepsPhysicalReaderBounded() throws {
        let cache = AVPlayerLogSnapshotCache()
        let oldObject = NSObject(), newObject = NSObject()
        let oldItem = makeItem(3), newItem = makeItem(4)
        cache.activate(item: oldItem, objectIdentity: ObjectIdentifier(oldObject))
        let oldRead = try XCTUnwrap(cache.beginRefresh())
        cache.activate(item: newItem, objectIdentity: ObjectIdentifier(newObject))
        XCTAssertNil(cache.beginRefresh(), "The old physical fetch still occupies the only reader")
        XCTAssertFalse(cache.isCurrent(oldRead))
        XCTAssertFalse(cache.complete(oldRead, snapshot: .init(accessEventCount: 99, errorEventCount: 99)))
        XCTAssertEqual(cache.snapshot(item: newItem, objectIdentity: ObjectIdentifier(newObject)), .empty)
        let newRead = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.complete(newRead, snapshot: .init(accessEventCount: 1, errorEventCount: 0)))
        XCTAssertEqual(cache.snapshot(item: oldItem, objectIdentity: ObjectIdentifier(oldObject)), .empty)
    }

    func testPhysicalItemIdentityAndLifecycleBothFenceCache() throws {
        let cache = AVPlayerLogSnapshotCache()
        let object = NSObject(), alias = NSObject()
        let item = makeItem(5)
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        let read = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.complete(read, snapshot: .init(accessEventCount: 7, errorEventCount: 3)))
        XCTAssertEqual(cache.snapshot(item: item, objectIdentity: ObjectIdentifier(alias)), .empty)
        XCTAssertEqual(cache.snapshot(item: makeItem(6), objectIdentity: ObjectIdentifier(object)), .empty)
    }

    func testRetiredReadCannotResurrectEvenSameIdentityAndObject() throws {
        let cache = AVPlayerLogSnapshotCache()
        let object = NSObject()
        let item = makeItem(7)
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        let oldRead = try XCTUnwrap(cache.beginRefresh())
        cache.invalidate()
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        XCTAssertNil(cache.beginRefresh())
        XCTAssertFalse(cache.complete(oldRead, snapshot: .init(accessEventCount: 99, errorEventCount: 99)))
        XCTAssertEqual(cache.snapshot(item: item, objectIdentity: ObjectIdentifier(object)), .empty)
        XCTAssertNotNil(cache.beginRefresh())
    }

    func testNilLogResultClearsOldCountersWithoutRetainingRawLogs() throws {
        let cache = AVPlayerLogSnapshotCache()
        let object = NSObject()
        let item = makeItem(8)
        cache.activate(item: item, objectIdentity: ObjectIdentifier(object))
        let first = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.complete(first, snapshot: .init(accessEventCount: 7, errorEventCount: 3)))
        cache.requestRefresh(item: item, objectIdentity: ObjectIdentifier(object))
        let nilRead = try XCTUnwrap(cache.beginRefresh())
        XCTAssertTrue(cache.complete(nilRead, snapshot: .empty))
        XCTAssertEqual(cache.snapshot(item: item, objectIdentity: ObjectIdentifier(object)), .empty)
        XCTAssertLessThanOrEqual(MemoryLayout<AVPlayerLogScalarSnapshot>.stride, 2 * MemoryLayout<Int>.stride)
        cache.invalidate()
        XCTAssertFalse(cache.complete(nilRead, snapshot: .init(accessEventCount: 99, errorEventCount: 99)))
        XCTAssertNil(cache.beginRefresh())
    }

    private func makeItem(_ nonce: UInt64) -> AVPlayerItemInstanceIdentity {
        .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 27_000 + nonce),
            itemGeneration: nonce)
    }
}
