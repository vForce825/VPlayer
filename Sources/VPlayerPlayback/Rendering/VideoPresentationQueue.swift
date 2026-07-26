// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct VideoPresentationSelection {
    let action: VideoRenderDecision.Action
    let frame: VideoPresentationFrame?
    let droppedFrameCount: Int
    // The three ways a frame is lost here answer different questions: overflow
    // means the producer ran further ahead than the queue spans, expiry means the
    // clock passed the frame before the display link asked for it, and superseded
    // means several frames came due on one tick.
    let overflowDropCount: Int
    let expiredDropCount: Int
    let supersededDropCount: Int
}

public final class VideoPresentationQueue: @unchecked Sendable {
    // This queue is a jitter buffer between the decoder and the display link, so
    // its size is a *duration*, not a frame count. Sizing it in frames made it
    // depend on the output frame rate: the field-rate deinterlace routes emit two
    // frames per input frame, which halved the buffer to less than the pipeline's
    // production lead. Every arrival then overflowed while the clock never got
    // close enough to select anything — 1080i live playback ran at a few frames
    // per second.
    public static let defaultHorizon = PlaybackTuning.default.videoBufferHorizon
    // Guard against pathological timestamps only. Normal operation is bounded by
    // the horizon; this stops a stream whose frames all carry one PTS from
    // growing the queue without limit.
    public static let frameCeiling = PlaybackTuning.default.videoBufferFrameCeiling

    private let lock = NSLock()
    private var horizon: CMTime
    private var frameCeiling: Int
    private let byteBudget: Int
    private var frames: [VideoPresentationFrame] = []
    private var displayedFrame: VideoPresentationFrame?
    private var overflowSinceSelection = 0
    private var epochDroppedFrames = 0
    private var activeGeneration: MediaGeneration

    public init(
        generation: MediaGeneration,
        horizon: CMTime = VideoPresentationQueue.defaultHorizon,
        frameCeiling: Int = VideoPresentationQueue.frameCeiling
    ) {
        activeGeneration = generation
        self.horizon = Self.validHorizon(horizon)
        self.frameCeiling = Self.validFrameCeiling(frameCeiling)
        byteBudget = PlaybackVideoMemoryBudget.presentationQueueBytes
    }

    init(
        generation: MediaGeneration,
        horizon: CMTime,
        frameCeiling: Int,
        byteBudget: Int
    ) {
        activeGeneration = generation
        self.horizon = Self.validHorizon(horizon)
        self.frameCeiling = Self.validFrameCeiling(frameCeiling)
        self.byteBudget = byteBudget > 0
            ? byteBudget
            : PlaybackVideoMemoryBudget.presentationQueueBytes
    }

    public var horizonSeconds: Double { lock.withLock { CMTimeGetSeconds(horizon) } }

    /// Applied while playing, so a viewer changing the buffer length in settings
    /// sees the effect on the stream they are watching. Growing the buffer keeps
    /// what is queued; shrinking it trims immediately.
    public func setBuffer(horizon newHorizon: CMTime, frameCeiling newCeiling: Int) {
        lock.withLock {
            horizon = Self.validHorizon(newHorizon)
            frameCeiling = Self.validFrameCeiling(newCeiling)
            trimToHorizonLocked()
        }
    }

    private static func validHorizon(_ candidate: CMTime) -> CMTime {
        candidate.isNumeric && CMTimeCompare(candidate, .zero) > 0
            ? candidate
            : VideoPresentationQueue.defaultHorizon
    }

    private static func validFrameCeiling(_ candidate: Int) -> Int {
        candidate > 1 ? candidate : VideoPresentationQueue.frameCeiling
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
            trimToHorizonLocked()
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
                return .init(
                    action: .waiting,
                    frame: nil,
                    droppedFrameCount: 0,
                    overflowDropCount: 0,
                    expiredDropCount: 0,
                    supersededDropCount: 0
                )
            }

            let overflowDrops = overflowSinceSelection
            var dropped = overflowSinceSelection
            overflowSinceSelection = 0
            var expiredDrops = 0
            var supersededDrops = 0

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
                    expiredDrops += 1
                    epochDroppedFrames += 1
                } else {
                    retained.append(frame)
                }
            }
            frames = retained

            let halfInterval = CMTimeMultiplyByRatio(displayInterval, multiplier: 1, divisor: 2)
            let qualificationLimit = CMTimeAdd(targetMediaTime, halfInterval)
            guard halfInterval.isNumeric, qualificationLimit.isNumeric else {
                return .init(
                    action: .waiting,
                    frame: nil,
                    droppedFrameCount: dropped,
                    overflowDropCount: overflowDrops,
                    expiredDropCount: expiredDrops,
                    supersededDropCount: supersededDrops
                )
            }

            let qualifyingCount = frames.prefix {
                CMTimeCompare($0.presentationTimeStamp, qualificationLimit) <= 0
            }.count
            if qualifyingCount > 0 {
                let selected = frames[qualifyingCount - 1]
                if qualifyingCount > 1 {
                    let superseded = qualifyingCount - 1
                    dropped += superseded
                    supersededDrops += superseded
                    epochDroppedFrames += superseded
                }
                frames.removeFirst(qualifyingCount)
                displayedFrame = selected
                return .init(
                    action: .presented,
                    frame: selected,
                    droppedFrameCount: dropped,
                    overflowDropCount: overflowDrops,
                    expiredDropCount: expiredDrops,
                    supersededDropCount: supersededDrops
                )
            }

            if let displayedFrame {
                return .init(
                    action: .repeated,
                    frame: displayedFrame,
                    droppedFrameCount: dropped,
                    overflowDropCount: overflowDrops,
                    expiredDropCount: expiredDrops,
                    supersededDropCount: supersededDrops
                )
            }
            return .init(
                action: .waiting,
                frame: nil,
                droppedFrameCount: dropped,
                overflowDropCount: overflowDrops,
                expiredDropCount: expiredDrops,
                supersededDropCount: supersededDrops
            )
        }
    }

    private func trimToHorizonLocked() {
        var estimatedBytes = frames.reduce(into: 0) { total, frame in
            total = Self.addingClamped(total, frame.estimatedStorageBytes)
        }
        while frames.count > 1 {
            let span = CMTimeSubtract(
                frames[frames.count - 1].presentationTimeStamp,
                frames[0].presentationTimeStamp
            )
            let overHorizon = span.isNumeric && CMTimeCompare(span, horizon) > 0
            let overMemoryBudget = estimatedBytes > byteBudget
            guard overHorizon || overMemoryBudget || frames.count > frameCeiling else {
                return
            }
            // Evict the frame furthest from being due. `select` already discards
            // frames whose expiry has passed, so reaching here means the producer
            // is ahead of the clock — dropping the oldest would delete the very
            // frame that is about to be displayed and guarantee that nothing is
            // ever presented.
            let removed = frames.removeLast()
            estimatedBytes = max(0, estimatedBytes - removed.estimatedStorageBytes)
            overflowSinceSelection += 1
            epochDroppedFrames += 1
        }
    }

    private static func addingClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
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
