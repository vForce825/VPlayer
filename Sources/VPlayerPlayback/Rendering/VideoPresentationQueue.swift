// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct VideoPresentationSelection {
    let action: VideoRenderDecision.Action
    let frame: VideoPresentationFrame?
    let droppedFrameCount: Int
}

public final class VideoPresentationQueue: @unchecked Sendable {
    public static let capacity = 12

    private let lock = NSLock()
    private var frames: [VideoPresentationFrame] = []
    private var displayedFrame: VideoPresentationFrame?
    private var overflowSinceSelection = 0
    private var epochDroppedFrames = 0
    private var activeGeneration: MediaGeneration

    public init(generation: MediaGeneration) {
        activeGeneration = generation
    }

    public var generation: MediaGeneration {
        lock.withLock { activeGeneration }
    }

    public var unpresentedCount: Int {
        lock.withLock { frames.count }
    }

    public var currentFrame: VideoPresentationFrame? {
        lock.withLock { displayedFrame }
    }

    public var metricsEpochDroppedFrameCount: Int {
        lock.withLock { epochDroppedFrames }
    }

    @discardableResult
    public func enqueue(_ frame: VideoPresentationFrame) -> Bool {
        lock.withLock {
            guard frame.generation == activeGeneration,
                  frame.presentationTimeStamp.isNumeric else {
                return false
            }
            let insertionIndex = frames.partitioningIndex {
                Self.isOrderedBefore(frame, $0)
            }
            frames.insert(frame, at: insertionIndex)
            if frames.count > Self.capacity {
                frames.removeFirst()
                overflowSinceSelection += 1
                epochDroppedFrames += 1
            }
            return true
        }
    }

    public func flush(to generation: MediaGeneration) {
        lock.withLock {
            activeGeneration = generation
            frames.removeAll(keepingCapacity: true)
            displayedFrame = nil
            overflowSinceSelection = 0
            epochDroppedFrames = 0
        }
    }

    func select(targetMediaTime: CMTime, displayInterval: CMTime) -> VideoPresentationSelection {
        lock.withLock {
            guard targetMediaTime.isNumeric,
                  displayInterval.isNumeric,
                  CMTimeCompare(displayInterval, .zero) > 0 else {
                return .init(action: .waiting, frame: nil, droppedFrameCount: 0)
            }

            var dropped = overflowSinceSelection
            overflowSinceSelection = 0

            var retained: [VideoPresentationFrame] = []
            retained.reserveCapacity(frames.count)
            for frame in frames {
                let validDuration = frame.duration.isNumeric && CMTimeCompare(frame.duration, .zero) > 0
                    ? frame.duration
                    : displayInterval
                let expiryDuration = CMTimeCompare(validDuration, displayInterval) >= 0
                    ? validDuration
                    : displayInterval
                let expiry = CMTimeAdd(frame.presentationTimeStamp, expiryDuration)
                if expiry.isNumeric, CMTimeCompare(expiry, targetMediaTime) < 0 {
                    dropped += 1
                    epochDroppedFrames += 1
                } else {
                    retained.append(frame)
                }
            }
            frames = retained

            let halfInterval = CMTimeMultiplyByRatio(displayInterval, multiplier: 1, divisor: 2)
            let qualificationLimit = CMTimeAdd(targetMediaTime, halfInterval)
            guard halfInterval.isNumeric, qualificationLimit.isNumeric else {
                return .init(action: .waiting, frame: nil, droppedFrameCount: dropped)
            }

            let qualifyingCount = frames.prefix {
                CMTimeCompare($0.presentationTimeStamp, qualificationLimit) <= 0
            }.count
            if qualifyingCount > 0 {
                let selected = frames[qualifyingCount - 1]
                if qualifyingCount > 1 {
                    let superseded = qualifyingCount - 1
                    dropped += superseded
                    epochDroppedFrames += superseded
                }
                frames.removeFirst(qualifyingCount)
                displayedFrame = selected
                return .init(action: .presented, frame: selected, droppedFrameCount: dropped)
            }

            if let displayedFrame {
                return .init(action: .repeated, frame: displayedFrame, droppedFrameCount: dropped)
            }
            return .init(action: .waiting, frame: nil, droppedFrameCount: dropped)
        }
    }

    private static func isOrderedBefore(
        _ lhs: VideoPresentationFrame,
        _ rhs: VideoPresentationFrame
    ) -> Bool {
        let comparison = CMTimeCompare(lhs.presentationTimeStamp, rhs.presentationTimeStamp)
        if comparison != 0 { return comparison < 0 }
        if lhs.sourceAccessUnitID != rhs.sourceAccessUnitID {
            return lhs.sourceAccessUnitID < rhs.sourceAccessUnitID
        }
        return lhs.sequenceNumber < rhs.sequenceNumber
    }
}

private extension Array {
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if belongsInSecondPartition(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
