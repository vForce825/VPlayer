// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct AudioContinuityIslandID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

struct AdmittedAudioFrame: Sendable {
    let frame: CompressedAudioFrame
    let normalizedPresentationTimeStamp: CMTime
    let effectiveCoverageStartPTS: CMTime
    let duration: CMTime
    let continuityIslandID: AudioContinuityIslandID
    let startsNewIsland: Bool
    let gapBefore: CMTime?
    let resetDecoderBeforeDecoding: Bool
    let fillDiscontinuitiesWithSilence: Bool
}

enum AudioContinuityDropReason: Int, CaseIterable, Sendable {
    case invalidTiming
    case staleGeneration
    case duplicate
    case overlap
    case ptsRegression

    static let slotCount = 5

    var slot: Int {
        switch self {
        case .invalidTiming: 0
        case .staleGeneration: 1
        case .duplicate: 2
        case .overlap: 3
        case .ptsRegression: 4
        }
    }
}

enum AudioContinuityAdmission: Sendable {
    case admitted(AdmittedAudioFrame)
    case dropped(AudioContinuityDropReason)
}

struct AudioContinuityIslandSnapshot: Sendable {
    let id: AudioContinuityIslandID
    let generation: MediaGeneration
    let firstPTS: CMTime
    let endPTS: CMTime
    let frameCount: Int
}

struct AudioContinuityRetainedInterval: Sendable {
    let islandID: AudioContinuityIslandID
    let generation: MediaGeneration
    let firstPTS: CMTime
    let endPTS: CMTime
}

struct AudioContinuityAnchorCandidate: Sendable {
    let id: AudioContinuityIslandID
    let generation: MediaGeneration
    let coverageStartPTS: CMTime
    let coverageEndPTS: CMTime
}

struct AudioContinuityBuffer {
    private struct RetentionPlan {
        let frames: [AdmittedAudioFrame]
        let byteBudget: OwnedByteBudget
    }

    private struct RetainedFrameKey: Hashable {
        let generation: MediaGeneration
        let id: UInt64
        let islandID: AudioContinuityIslandID
    }

    private let tolerance: CMTime
    private let shortGapMaximum: CMTime
    private let retentionLimits: CompressedAudioRetentionLimits

    private var generation: MediaGeneration?
    private var retainedFrames: [AdmittedAudioFrame] = []
    private var retainedByteBudget: OwnedByteBudget
    private var currentIsland: AudioContinuityIslandSnapshot?
    private var recoveryFloor: CMTime?
    private var latestAdmittedRawStart: CMTime?
    private var latestAdmittedRawEnd: CMTime?
    private var highWatermark: CMTime?
    private var pendingDecodeBreak = false
    private var nextIslandRawValue: UInt64? = 1

    init(
        tolerance: CMTime = CMTime(value: 1, timescale: 1_000),
        shortGapMaximum: CMTime = CMTime(value: 250, timescale: 1_000),
        retentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.continuity
    ) {
        let defaultTolerance = CMTime(value: 1, timescale: 1_000)
        let validTolerance = tolerance.isNumeric && CMTimeCompare(tolerance, .zero) >= 0
            ? tolerance
            : defaultTolerance
        self.tolerance = validTolerance
        self.shortGapMaximum = shortGapMaximum.isNumeric
            && CMTimeCompare(shortGapMaximum, validTolerance) >= 0
            ? shortGapMaximum
            : CMTime(value: 250, timescale: 1_000)
        self.retentionLimits = retentionLimits
        retainedByteBudget = OwnedByteBudget(limit: retentionLimits.maximumOwnedBytes)
    }

    init(
        tolerance: CMTime = CMTime(value: 1, timescale: 1_000),
        shortGapMaximum: CMTime = CMTime(value: 250, timescale: 1_000),
        capacity: Int
    ) {
        let boundedCount = min(
            max(1, capacity),
            CompressedAudioRetentionPolicy.continuity.maximumCount
        )
        self.init(
            tolerance: tolerance,
            shortGapMaximum: shortGapMaximum,
            retentionLimits: .production(
                maximumCount: boundedCount,
                maximumOwnedBytes: CompressedAudioRetentionPolicy
                    .continuity.maximumOwnedBytes
            )
        )
    }

    // Package-internal seam for exercising allocator exhaustion without
    // changing the fixed production initializer.
    init(testingIslandIDAllocatorStartingAt rawValue: UInt64) {
        self.init()
        nextIslandRawValue = rawValue
    }

    mutating func reset(to generation: MediaGeneration) {
        self.generation = generation
        retainedFrames.removeAll(keepingCapacity: true)
        retainedByteBudget.reset()
        currentIsland = nil
        recoveryFloor = nil
        latestAdmittedRawStart = nil
        latestAdmittedRawEnd = nil
        highWatermark = nil
        pendingDecodeBreak = false
    }

    mutating func markDecodeBreak() {
        pendingDecodeBreak = true
    }

    mutating func admit(
        _ frame: CompressedAudioFrame
    ) throws -> AudioContinuityAdmission {
        guard let rawEnd = validEnd(of: frame) else {
            return .dropped(.invalidTiming)
        }
        if let generation, frame.generation != generation {
            return .dropped(.staleGeneration)
        }
        let matchesLatestAdmittedInterval: Bool
        if let latestAdmittedRawStart, let latestAdmittedRawEnd {
            matchesLatestAdmittedInterval = timesEqual(
                latestAdmittedRawStart,
                frame.presentationTimeStamp
            ) && timesEqual(latestAdmittedRawEnd, rawEnd)
        } else {
            matchesLatestAdmittedInterval = false
        }
        if matchesLatestAdmittedInterval || retainedFrames.contains(where: { retained in
            retained.frame.generation == frame.generation
                && timesEqual(retained.frame.presentationTimeStamp, frame.presentationTimeStamp)
                && timesEqual(
                    CMTimeAdd(retained.frame.presentationTimeStamp, retained.frame.duration),
                    rawEnd
                )
        }) {
            return .dropped(.duplicate)
        }

        if let latestAdmittedRawStart,
           CMTimeCompare(frame.presentationTimeStamp, latestAdmittedRawStart) <= 0 {
            return .dropped(.ptsRegression)
        }

        let normalizedPTS: CMTime
        let startsNewIsland: Bool
        let gapBefore: CMTime?
        let resetForTiming: Bool
        let fillDiscontinuitiesWithSilence: Bool
        let islandID: AudioContinuityIslandID
        var plannedNextIslandRawValue = nextIslandRawValue

        if let highWatermark, let currentIsland {
            let residue = CMTimeSubtract(frame.presentationTimeStamp, highWatermark)
            guard residue.isNumeric else { return .dropped(.invalidTiming) }
            let negativeTolerance = CMTimeSubtract(.zero, tolerance)

            if CMTimeCompare(residue, negativeTolerance) >= 0,
               CMTimeCompare(residue, tolerance) <= 0 {
                normalizedPTS = highWatermark
                startsNewIsland = false
                gapBefore = nil
                resetForTiming = false
                fillDiscontinuitiesWithSilence = false
                islandID = currentIsland.id
            } else if CMTimeCompare(residue, negativeTolerance) < 0 {
                return .dropped(.overlap)
            } else if CMTimeCompare(residue, shortGapMaximum) <= 0 {
                normalizedPTS = frame.presentationTimeStamp
                startsNewIsland = false
                gapBefore = residue
                resetForTiming = true
                fillDiscontinuitiesWithSilence = true
                islandID = currentIsland.id
            } else {
                guard let rawValue = plannedNextIslandRawValue else {
                    return .dropped(.invalidTiming)
                }
                islandID = AudioContinuityIslandID(rawValue: rawValue)
                plannedNextIslandRawValue = rawValue == UInt64.max ? nil : rawValue + 1
                normalizedPTS = frame.presentationTimeStamp
                startsNewIsland = true
                gapBefore = residue
                resetForTiming = true
                fillDiscontinuitiesWithSilence = false
            }
        } else {
            guard let rawValue = plannedNextIslandRawValue else {
                return .dropped(.invalidTiming)
            }
            islandID = AudioContinuityIslandID(rawValue: rawValue)
            plannedNextIslandRawValue = rawValue == UInt64.max ? nil : rawValue + 1
            normalizedPTS = frame.presentationTimeStamp
            startsNewIsland = true
            gapBefore = nil
            resetForTiming = true
            fillDiscontinuitiesWithSilence = false
        }

        let normalizedEnd = CMTimeAdd(normalizedPTS, frame.duration)
        guard normalizedEnd.isNumeric else { return .dropped(.invalidTiming) }
        let effectiveCoverageStartPTS: CMTime
        if fillDiscontinuitiesWithSilence, let gapBefore {
            effectiveCoverageStartPTS = CMTimeSubtract(normalizedPTS, gapBefore)
        } else {
            effectiveCoverageStartPTS = normalizedPTS
        }
        guard effectiveCoverageStartPTS.isNumeric,
              CMTimeCompare(effectiveCoverageStartPTS, normalizedPTS) <= 0 else {
            return .dropped(.invalidTiming)
        }
        let admitted = AdmittedAudioFrame(
            frame: frame,
            normalizedPresentationTimeStamp: normalizedPTS,
            effectiveCoverageStartPTS: effectiveCoverageStartPTS,
            duration: frame.duration,
            continuityIslandID: islandID,
            startsNewIsland: startsNewIsland,
            gapBefore: gapBefore,
            resetDecoderBeforeDecoding: pendingDecodeBreak || resetForTiming,
            fillDiscontinuitiesWithSilence: fillDiscontinuitiesWithSilence
        )

        var candidates = startsNewIsland
            ? []
            : retainedFrames.filter { $0.continuityIslandID == islandID }
        candidates.append(admitted)
        let plan = try makeRetentionPlan(
            candidates: candidates,
            floor: recoveryFloor,
            mandatoryNewest: true
        )

        if generation == nil {
            generation = frame.generation
        }
        nextIslandRawValue = plannedNextIslandRawValue
        updateIsland(with: admitted, endPTS: normalizedEnd)
        latestAdmittedRawStart = frame.presentationTimeStamp
        latestAdmittedRawEnd = rawEnd
        highWatermark = normalizedEnd
        pendingDecodeBreak = false
        retainedFrames = plan.frames
        retainedByteBudget = plan.byteBudget
        return .admitted(admitted)
    }

    mutating func updateRecoveryFloor(_ floor: CMTime?) throws {
        let newFloor = floor?.isNumeric == true ? floor : nil
        guard !retainedFrames.isEmpty else {
            recoveryFloor = newFloor
            return
        }
        let plan = try makeRetentionPlan(
            candidates: retainedFrames,
            floor: newFloor,
            mandatoryNewest: true
        )
        recoveryFloor = newFloor
        retainedFrames = plan.frames
        retainedByteBudget = plan.byteBudget
    }

    func anchorCandidate(at commonPTS: CMTime) -> AudioContinuityAnchorCandidate? {
        guard commonPTS.isNumeric else { return nil }
        if let recoveryFloor, CMTimeCompare(commonPTS, recoveryFloor) < 0 {
            return nil
        }
        guard let index = retainedFrames.firstIndex(where: {
            coverage(of: $0, contains: commonPTS)
        }) else { return nil }
        let range = componentRange(containing: index, in: retainedFrames)
        guard let first = retainedFrames[safe: range.lowerBound],
              let last = retainedFrames[safe: range.upperBound - 1] else { return nil }
        return AudioContinuityAnchorCandidate(
            id: first.continuityIslandID,
            generation: first.frame.generation,
            coverageStartPTS: coverageBounds(of: first).start,
            coverageEndPTS: coverageBounds(of: last).end
        )
    }

    mutating func commitAnchor(
        at commonPTS: CMTime,
        in islandID: AudioContinuityIslandID
    ) throws {
        guard anchorCandidate(at: commonPTS)?.id == islandID else { return }
        let candidates = retainedFrames.filter { retained in
            let end = coverageBounds(of: retained).end
            return !end.isNumeric || CMTimeCompare(end, commonPTS) > 0
        }
        let plan = try makeRetentionPlan(
            candidates: candidates,
            floor: commonPTS,
            mandatoryNewest: true
        )
        recoveryFloor = commonPTS
        retainedFrames = plan.frames
        retainedByteBudget = plan.byteBudget
    }

    var activeIsland: AudioContinuityIslandSnapshot? {
        currentIsland
    }

    var activeRetainedInterval: AudioContinuityRetainedInterval? {
        guard let newestIndex = retainedFrames.indices.last else { return nil }
        let range = componentRange(containing: newestIndex, in: retainedFrames)
        guard let first = retainedFrames[safe: range.lowerBound],
              let last = retainedFrames[safe: range.upperBound - 1] else { return nil }
        return AudioContinuityRetainedInterval(
            islandID: first.continuityIslandID,
            generation: first.frame.generation,
            firstPTS: coverageBounds(of: first).start,
            endPTS: coverageBounds(of: last).end
        )
    }

    var retainedFrameCount: Int {
        retainedFrames.count
    }

    var retainedPayloadBytes: Int {
        retainedByteBudget.used
    }

    private func validEnd(of frame: CompressedAudioFrame) -> CMTime? {
        guard frame.presentationTimeStamp.isNumeric,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0,
              frame.frameSampleCount > 0 else { return nil }
        let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
        return end.isNumeric ? end : nil
    }

    private func timesEqual(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        lhs.isNumeric && rhs.isNumeric && CMTimeCompare(lhs, rhs) == 0
    }

    private mutating func updateIsland(
        with frame: AdmittedAudioFrame,
        endPTS: CMTime
    ) {
        if frame.startsNewIsland {
            currentIsland = AudioContinuityIslandSnapshot(
                id: frame.continuityIslandID,
                generation: frame.frame.generation,
                firstPTS: frame.normalizedPresentationTimeStamp,
                endPTS: endPTS,
                frameCount: 1
            )
            return
        }
        let frameCount = currentIsland?.frameCount ?? 0
        currentIsland = AudioContinuityIslandSnapshot(
            id: frame.continuityIslandID,
            generation: frame.frame.generation,
            firstPTS: currentIsland?.firstPTS ?? frame.normalizedPresentationTimeStamp,
            endPTS: endPTS,
            frameCount: frameCount < Int.max ? frameCount + 1 : Int.max
        )
    }

    private func makeRetentionPlan(
        candidates: [AdmittedAudioFrame],
        floor: CMTime?,
        mandatoryNewest: Bool
    ) throws -> RetentionPlan {
        guard !candidates.isEmpty else {
            return RetentionPlan(
                frames: [],
                byteBudget: OwnedByteBudget(limit: retentionLimits.maximumOwnedBytes)
            )
        }
        var planned = candidates
        let newestKey = mandatoryNewest ? key(for: candidates[candidates.count - 1]) : nil
        let protectorKey = floor.flatMap { floor in
            candidates.first(where: { coverage(of: $0, contains: floor) }).map(key(for:))
        }

        func isMandatory(_ frame: AdmittedAudioFrame) -> Bool {
            let frameKey = key(for: frame)
            return frameKey == newestKey || frameKey == protectorKey
        }

        while true {
            let plannedBytes = try payloadBytes(of: planned)
            guard planned.count > retentionLimits.maximumCount
                    || plannedBytes > retentionLimits.maximumOwnedBytes else { break }
            guard let index = planned.firstIndex(where: { !isMandatory($0) }) else {
                throw capacityFailure()
            }
            planned.remove(at: index)
        }

        removeDetachedHistory(
            from: &planned,
            protectorKey: protectorKey,
            newestKey: newestKey
        )

        while let newestIndex = planned.indices.last {
            let component = componentRange(containing: newestIndex, in: planned)
            guard let first = planned[safe: component.lowerBound],
                  let last = planned[safe: component.upperBound - 1] else {
                throw accountingFailure()
            }
            let span = CMTimeSubtract(
                coverageBounds(of: last).end,
                coverageBounds(of: first).start
            )
            guard span.isNumeric else { throw accountingFailure() }
            if CMTimeCompare(span, retentionLimits.latestTailHorizon) <= 0 {
                break
            }
            guard let removalIndex = component.first(where: { !isMandatory(planned[$0]) })
            else { throw capacityFailure() }
            planned.remove(at: removalIndex)
            removeDetachedHistory(
                from: &planned,
                protectorKey: protectorKey,
                newestKey: newestKey
            )
        }

        var byteBudget = OwnedByteBudget(limit: retentionLimits.maximumOwnedBytes)
        for frame in planned {
            guard try byteBudget.reserve(frame.frame.payload.count) else {
                throw capacityFailure()
            }
        }
        return RetentionPlan(frames: planned, byteBudget: byteBudget)
    }

    private func removeDetachedHistory(
        from frames: inout [AdmittedAudioFrame],
        protectorKey: RetainedFrameKey?,
        newestKey: RetainedFrameKey?
    ) {
        guard let newestKey,
              let newestIndex = frames.firstIndex(where: { key(for: $0) == newestKey }) else {
            return
        }
        let latestComponent = componentRange(containing: newestIndex, in: frames)
        let keepIndices = Set(latestComponent)
        frames = frames.enumerated().compactMap { index, frame in
            if keepIndices.contains(index) || key(for: frame) == protectorKey {
                return frame
            }
            return nil
        }
    }

    private func payloadBytes(of frames: [AdmittedAudioFrame]) throws -> Int {
        var budget = OwnedByteBudget(limit: Int.max)
        for frame in frames {
            guard try budget.reserve(frame.frame.payload.count) else {
                throw accountingFailure()
            }
        }
        return budget.used
    }

    private func key(for frame: AdmittedAudioFrame) -> RetainedFrameKey {
        RetainedFrameKey(
            generation: frame.frame.generation,
            id: frame.frame.id,
            islandID: frame.continuityIslandID
        )
    }

    private func coverageBounds(
        of frame: AdmittedAudioFrame
    ) -> (start: CMTime, end: CMTime) {
        (
            frame.effectiveCoverageStartPTS,
            CMTimeAdd(frame.normalizedPresentationTimeStamp, frame.duration)
        )
    }

    private func coverage(of frame: AdmittedAudioFrame, contains time: CMTime) -> Bool {
        let bounds = coverageBounds(of: frame)
        return bounds.start.isNumeric && bounds.end.isNumeric
            && CMTimeCompare(bounds.start, time) <= 0
            && CMTimeCompare(time, bounds.end) < 0
    }

    private func componentRange(
        containing index: Int,
        in frames: [AdmittedAudioFrame]
    ) -> Range<Int> {
        var lower = index
        var upper = index + 1
        while lower > frames.startIndex {
            let previous = coverageBounds(of: frames[lower - 1])
            let current = coverageBounds(of: frames[lower])
            guard previous.end.isNumeric, current.start.isNumeric,
                  CMTimeCompare(previous.end, current.start) >= 0 else { break }
            lower -= 1
        }
        while upper < frames.endIndex {
            let previous = coverageBounds(of: frames[upper - 1])
            let current = coverageBounds(of: frames[upper])
            guard previous.end.isNumeric, current.start.isNumeric,
                  CMTimeCompare(previous.end, current.start) >= 0 else { break }
            upper += 1
        }
        return lower..<upper
    }

    private func capacityFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.continuityCapacityError)
    }

    private func accountingFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
