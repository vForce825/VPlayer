// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

struct YADIFReferenceWindow: Sendable {
    struct Transition: @unchecked Sendable {
        let job: YADIFJob?
        let discarded: [NormalizedDecodedFrame]
    }

    private struct StoredFrame: Sendable {
        let frame: NormalizedDecodedFrame
        let order: ResolvedFieldOrder
    }

    private(set) var generation: MediaGeneration
    private var previous: StoredFrame?
    private var current: StoredFrame?
    private var lastAcceptedPTS: CMTime?
    private var acceptedDeltas: [CMTime] = []

    var bufferedCount: Int {
        (previous == nil ? 0 : 1) + (current == nil ? 0 : 1)
    }

    var unemittedCount: Int { current == nil ? 0 : 1 }

    init(generation: MediaGeneration) {
        self.generation = generation
    }

    mutating func push(
        _ frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool = false
    ) -> Transition {
        guard frame.frame.generation >= generation else {
            return Transition(job: nil, discarded: [frame])
        }

        var discarded: [NormalizedDecodedFrame] = []
        var startsFreshSegment = false
        if frame.frame.generation > generation {
            discarded.append(contentsOf: clearSegment())
            generation = frame.frame.generation
            startsFreshSegment = true
        }
        if discontinuity {
            discarded.append(contentsOf: clearSegment())
            startsFreshSegment = true
        }

        let presentationTimeStamp = frame.presentationTimeStamp
        guard presentationTimeStamp.isNumeric else {
            discarded.append(contentsOf: clearSegment())
            discarded.append(frame)
            return Transition(job: nil, discarded: discarded)
        }

        if !startsFreshSegment,
           let current,
           current.order != order {
            discarded.append(contentsOf: clearSegment())
            startsFreshSegment = true
        }

        if !startsFreshSegment, let lastAcceptedPTS {
            guard CMTimeCompare(presentationTimeStamp, lastAcceptedPTS) > 0 else {
                discarded.append(contentsOf: clearSegment())
                seed(frame, order: order)
                return Transition(job: nil, discarded: discarded)
            }

            let delta = CMTimeSubtract(presentationTimeStamp, lastAcceptedPTS)
            if isGap(delta) {
                discarded.append(contentsOf: clearSegment())
                seed(frame, order: order)
                return Transition(job: nil, discarded: discarded)
            }
            appendAcceptedDelta(delta)
        }

        if startsFreshSegment || current == nil {
            seed(frame, order: order)
            return Transition(job: nil, discarded: discarded)
        }

        let pending = current!
        let job = YADIFJob(
            previous: previous?.frame ?? pending.frame,
            current: pending.frame,
            next: frame,
            order: pending.order,
            spatialOnly: previous == nil
        )
        previous = pending
        current = StoredFrame(frame: frame, order: order)
        lastAcceptedPTS = presentationTimeStamp
        return Transition(job: job, discarded: discarded)
    }

    mutating func drain() -> Transition {
        guard let current else {
            return Transition(job: nil, discarded: [])
        }
        let job = YADIFJob(
            previous: previous?.frame ?? current.frame,
            current: current.frame,
            next: current.frame,
            order: current.order,
            spatialOnly: true
        )
        _ = clearSegment()
        return Transition(job: job, discarded: [])
    }

    mutating func reset(generation: MediaGeneration) -> [NormalizedDecodedFrame] {
        let discarded = clearSegment()
        self.generation = generation
        return discarded
    }

    private mutating func seed(
        _ frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder
    ) {
        previous = nil
        current = StoredFrame(frame: frame, order: order)
        lastAcceptedPTS = frame.presentationTimeStamp
    }

    private mutating func clearSegment() -> [NormalizedDecodedFrame] {
        let discarded = current.map { [$0.frame] } ?? []
        previous = nil
        current = nil
        lastAcceptedPTS = nil
        acceptedDeltas.removeAll(keepingCapacity: true)
        return discarded
    }

    private func isGap(_ delta: CMTime) -> Bool {
        guard !acceptedDeltas.isEmpty else { return false }
        let median = medianAcceptedDelta()
        let tripledMedian = CMTimeMultiply(median, multiplier: 3)
        guard delta.isNumeric, tripledMedian.isNumeric else { return true }
        return CMTimeCompare(delta, tripledMedian) > 0
    }

    private func medianAcceptedDelta() -> CMTime {
        let sorted = acceptedDeltas.sorted { CMTimeCompare($0, $1) < 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return CMTimeMultiplyByRatio(
                CMTimeAdd(sorted[middle - 1], sorted[middle]),
                multiplier: 1,
                divisor: 2
            )
        }
        return sorted[middle]
    }

    private mutating func appendAcceptedDelta(_ delta: CMTime) {
        guard delta.isNumeric, CMTimeCompare(delta, .zero) > 0 else { return }
        acceptedDeltas.append(delta)
        if acceptedDeltas.count > 7 {
            acceptedDeltas.removeFirst(acceptedDeltas.count - 7)
        }
    }
}
