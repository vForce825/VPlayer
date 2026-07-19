// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

private enum MediaQueueSlot<Element> {
    case empty
    case occupied(Element)
}

extension MediaQueueSlot: Sendable where Element: Sendable {}

public struct BoundedMediaQueue<Element> {
    public enum Overflow: Sendable {
        case rejectNewest
        case dropOldest
    }

    public let capacity: Int
    public let overflow: Overflow
    private var storage: [MediaQueueSlot<Element>]
    private var head = 0
    public private(set) var count = 0

    public var elements: [Element] {
        guard count > 0, storage.count == capacity else { return [] }
        var snapshot: [Element] = []
        snapshot.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % capacity
            if case let .occupied(value) = storage[index] {
                snapshot.append(value)
            }
        }
        return snapshot
    }

    public init(capacity: Int, overflow: Overflow) {
        self.capacity = max(0, capacity)
        self.overflow = overflow
        storage = capacity > 0 ? Array(repeating: .empty, count: capacity) : []
    }

    @discardableResult
    public mutating func push(_ value: Element) -> Element? {
        guard capacity > 0 else { return value }
        restoreBackingStorageIfNeeded()

        guard count == capacity else {
            let tail = (head + count) % capacity
            storage[tail] = .occupied(value)
            count += 1
            return nil
        }

        switch overflow {
        case .rejectNewest:
            return value
        case .dropOldest:
            let previous = storage[head]
            storage[head] = .occupied(value)
            head = (head + 1) % capacity
            if case let .occupied(dropped) = previous {
                return dropped
            }
            return nil
        }
    }

    public mutating func popFirst() -> Element? {
        guard count > 0, storage.count == capacity else { return nil }
        let previous = storage[head]
        storage[head] = .empty
        head = (head + 1) % capacity
        count -= 1
        if case let .occupied(value) = previous {
            return value
        }
        return nil
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            for index in storage.indices {
                storage[index] = .empty
            }
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        count = 0
    }

    private mutating func restoreBackingStorageIfNeeded() {
        guard storage.count != capacity else { return }
        storage = Array(repeating: .empty, count: capacity)
        head = 0
    }
}

extension BoundedMediaQueue: Sendable where Element: Sendable {}
