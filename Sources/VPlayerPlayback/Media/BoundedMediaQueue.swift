// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

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

struct CompressedVideoRetentionLimits: Sendable, Equatable {
    let maximumCount: Int
    let maximumOwnedBytes: Int
    let latestTailHorizon: CMTime
}

struct CompressedVideoReservoirMutation: Sendable, Equatable {
    let accepted: Bool
    let droppedCount: Int
}

/// FIFO storage for compressed video that owns its count, byte and timestamp
/// limits. Overflow may advance only to a later random-access unit, so it never
/// leaves an undecodable GOP suffix behind.
struct CompressedVideoReservoir: RandomAccessCollection {
    typealias Index = Int
    typealias Element = CompressedVideoAccessUnit

    let limits: CompressedVideoRetentionLimits
    private var storage: [CompressedVideoAccessUnit] = []
    private var head = 0

    var startIndex: Int { 0 }
    var endIndex: Int { count }
    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var elements: [CompressedVideoAccessUnit] { Array(self) }

    subscript(position: Int) -> CompressedVideoAccessUnit {
        precondition(indices.contains(position))
        return storage[head + position]
    }

    init(limits: CompressedVideoRetentionLimits) {
        precondition(limits.maximumCount > 0)
        precondition(limits.maximumOwnedBytes > 0)
        precondition(
            limits.latestTailHorizon.isNumeric
                && CMTimeCompare(limits.latestTailHorizon, .zero) > 0
        )
        self.limits = limits
    }

    @discardableResult
    mutating func append(
        _ accessUnit: CompressedVideoAccessUnit,
        decodableSuffixMayStartAt canStartSuffix: (
            CompressedVideoAccessUnit
        ) -> Bool = { _ in true }
    ) -> CompressedVideoReservoirMutation {
        var candidate = elements
        candidate.append(accessUnit)
        if fits(candidate) {
            storage.append(accessUnit)
            return CompressedVideoReservoirMutation(accepted: true, droppedCount: 0)
        }

        guard candidate.count > 1 else {
            return CompressedVideoReservoirMutation(accepted: false, droppedCount: 0)
        }
        for index in 1..<candidate.count
            where candidate[index].isRandomAccess && canStartSuffix(candidate[index]) {
            let suffix = Array(candidate[index...])
            guard fits(suffix) else { continue }
            let droppedCount = index
            storage = suffix
            head = 0
            return CompressedVideoReservoirMutation(
                accepted: true,
                droppedCount: droppedCount
            )
        }
        return CompressedVideoReservoirMutation(accepted: false, droppedCount: 0)
    }

    @discardableResult
    mutating func popFirst() -> CompressedVideoAccessUnit? {
        guard !isEmpty else { return nil }
        let value = storage[head]
        head += 1
        compactIfNeeded()
        return value
    }

    mutating func removeFirst() {
        precondition(popFirst() != nil)
    }

    mutating func removeFirst(_ count: Int) {
        precondition(count >= 0 && count <= self.count)
        head += count
        compactIfNeeded()
    }

    mutating func removeAll(
        keepingCapacity: Bool = true
    ) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    mutating func removeAll(
        where shouldRemove: (CompressedVideoAccessUnit) throws -> Bool
    ) rethrows {
        storage = try elements.filter { try !shouldRemove($0) }
        head = 0
    }

    private func fits(_ values: [CompressedVideoAccessUnit]) -> Bool {
        guard values.count <= limits.maximumCount else { return false }
        var bytes = 0
        var earliest: CMTime?
        var latestEnd: CMTime?
        for value in values {
            let sampleBytes = CMSampleBufferGetTotalSampleSize(value.sampleBuffer)
            let (sum, overflow) = bytes.addingReportingOverflow(sampleBytes)
            guard !overflow, sum <= limits.maximumOwnedBytes else { return false }
            bytes = sum

            let pts = CMSampleBufferGetPresentationTimeStamp(value.sampleBuffer)
            guard pts.isNumeric, CMTimeCompare(pts, .zero) >= 0 else { continue }
            let duration = CMSampleBufferGetDuration(value.sampleBuffer)
            let end = duration.isNumeric && CMTimeCompare(duration, .zero) > 0
                ? CMTimeAdd(pts, duration)
                : pts
            guard end.isNumeric else { continue }
            if earliest.map({ CMTimeCompare(pts, $0) < 0 }) ?? true { earliest = pts }
            if latestEnd.map({ CMTimeCompare(end, $0) > 0 }) ?? true { latestEnd = end }
        }
        guard let earliest, let latestEnd else { return true }
        let horizon = CMTimeSubtract(latestEnd, earliest)
        return horizon.isNumeric
            && CMTimeCompare(horizon, limits.latestTailHorizon) <= 0
    }

    private mutating func compactIfNeeded() {
        guard head > 0 else { return }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

extension CompressedVideoReservoir: Sendable {}
