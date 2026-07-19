// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class BoundedMediaQueueTests: XCTestCase {
    func testRejectNewestNeverGrowsPastCapacity() {
        var subject = BoundedMediaQueue<Int>(capacity: 2, overflow: .rejectNewest)

        XCTAssertNil(subject.push(10))
        XCTAssertNil(subject.push(20))
        XCTAssertEqual(subject.push(30), 30)
        XCTAssertEqual(subject.count, 2)
        XCTAssertEqual(subject.elements, [10, 20])
        XCTAssertEqual(subject.popFirst(), 10)
        XCTAssertEqual(subject.popFirst(), 20)
        XCTAssertNil(subject.popFirst())
    }

    func testDropOldestPreservesFIFOOrder() {
        var subject = BoundedMediaQueue<Int>(capacity: 2, overflow: .dropOldest)

        XCTAssertNil(subject.push(10))
        XCTAssertNil(subject.push(20))
        XCTAssertEqual(subject.push(30), 10)
        XCTAssertEqual(subject.elements, [20, 30])
    }

    func testZeroAndNegativeCapacitiesRejectEveryOfferedValue() {
        for requestedCapacity in [0, -1, Int.min] {
            for overflow in [
                BoundedMediaQueue<Int>.Overflow.rejectNewest,
                BoundedMediaQueue<Int>.Overflow.dropOldest,
            ] {
                var subject = BoundedMediaQueue<Int>(
                    capacity: requestedCapacity,
                    overflow: overflow
                )

                XCTAssertEqual(subject.capacity, 0)
                XCTAssertEqual(subject.push(42), 42)
                XCTAssertEqual(subject.count, 0)
                XCTAssertEqual(subject.elements, [])
                XCTAssertNil(subject.popFirst())
            }
        }
    }

    func testCapacityOneHandlesBothOverflowPolicies() {
        var rejecting = BoundedMediaQueue<Int>(capacity: 1, overflow: .rejectNewest)
        var dropping = BoundedMediaQueue<Int>(capacity: 1, overflow: .dropOldest)

        XCTAssertNil(rejecting.push(1))
        XCTAssertEqual(rejecting.push(2), 2)
        XCTAssertEqual(rejecting.elements, [1])

        XCTAssertNil(dropping.push(1))
        XCTAssertEqual(dropping.push(2), 1)
        XCTAssertEqual(dropping.elements, [2])
    }

    func testWrapAroundAndAlternatingPushPopRemainFIFO() {
        var subject = BoundedMediaQueue<Int>(capacity: 3, overflow: .rejectNewest)

        XCTAssertNil(subject.push(1))
        XCTAssertNil(subject.push(2))
        XCTAssertNil(subject.push(3))
        XCTAssertEqual(subject.popFirst(), 1)
        XCTAssertEqual(subject.popFirst(), 2)
        XCTAssertNil(subject.push(4))
        XCTAssertNil(subject.push(5))
        XCTAssertEqual(subject.elements, [3, 4, 5])
        XCTAssertEqual(subject.popFirst(), 3)
        XCTAssertNil(subject.push(6))
        XCTAssertEqual(subject.elements, [4, 5, 6])
    }

    func testOptionalElementCanStoreRealNilWithoutLookingEmpty() {
        var subject = BoundedMediaQueue<Int?>(capacity: 2, overflow: .rejectNewest)

        guard case .none = subject.push(nil) else {
            return XCTFail("queue should accept a nil optional element")
        }
        guard case .none = subject.push(7) else {
            return XCTFail("queue should accept a non-nil optional element")
        }
        XCTAssertEqual(subject.count, 2)
        XCTAssertEqual(subject.elements.count, 2)
        XCTAssertNil(subject.elements[0])
        XCTAssertEqual(subject.elements[1], 7)

        guard case .some(.none) = subject.popFirst() else {
            return XCTFail("stored nil must be returned as an occupied queue element")
        }
        guard case let .some(.some(value)) = subject.popFirst() else {
            return XCTFail("stored non-nil optional must remain present")
        }
        XCTAssertEqual(value, 7)
        guard case .none = subject.popFirst() else {
            return XCTFail("empty optional-element queue must return outer nil")
        }
    }

    func testRemoveAllModesReleaseElementsAndQueueCanBeReused() {
        for keepingCapacity in [true, false] {
            weak var released: QueueToken?
            var subject = BoundedMediaQueue<QueueToken>(capacity: 2, overflow: .rejectNewest)
            do {
                let token = QueueToken()
                released = token
                XCTAssertNil(subject.push(token))
            }

            subject.removeAll(keepingCapacity: keepingCapacity)
            XCTAssertNil(released)
            XCTAssertEqual(subject.count, 0)
            XCTAssertEqual(subject.elements.count, 0)

            let replacement = QueueToken()
            XCTAssertNil(subject.push(replacement))
            XCTAssertTrue(subject.popFirst() === replacement)
        }
    }

    func testQueueIsConditionallySendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(BoundedMediaQueue<Int>.self)
    }
}

private final class QueueToken: @unchecked Sendable {}
