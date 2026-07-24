// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public enum TimingProvenance: UInt8, Equatable, Sendable {
    case trustedPresentationCadence
    case decodedCallbackDuration
    case configuredNominalDuration
    case assumed25i
}

public struct NormalizedDecodedFrame: @unchecked Sendable {
    public let frame: DecodedVideoFrame
    public let presentationTimeStamp: CMTime
    public let frameDuration: CMTime
    public let fieldDuration: CMTime
    public let timingWasSynthesized: Bool
    public let provenance: TimingProvenance

    public init(
        frame: DecodedVideoFrame,
        presentationTimeStamp: CMTime,
        frameDuration: CMTime,
        fieldDuration: CMTime,
        timingWasSynthesized: Bool,
        provenance: TimingProvenance
    ) {
        self.frame = frame
        self.presentationTimeStamp = presentationTimeStamp
        self.frameDuration = frameDuration
        self.fieldDuration = fieldDuration
        self.timingWasSynthesized = timingWasSynthesized
        self.provenance = provenance
    }
}

public struct PresentationTimestampNormalizer: Sendable {
    private struct PendingFrame: Sendable {
        let frame: DecodedVideoFrame
        let trustedPTS90k: Int64?
        var stableOrder: Int
        var missingPushAge: Int
    }

    private static let fallback25iDuration = CMTime(value: 1, timescale: 25)
    private static let transportTimescale: CMTimeScale = 90_000
    private static let minimumReorderDepth = 2
    private static let maximumReorderDepth = 8

    private var generation: MediaGeneration
    private var unwrapper = Timestamp33Unwrapper()
    private var cadenceEstimator = FrameCadenceEstimator()
    private var pending: [PendingFrame] = []
    private var lastTrustedPresentationPTS: CMTime?
    private var lastOutputPTS: CMTime?
    private var lastExactOutputPTS: CMTime?
    private var lastAccessUnitID: UInt64?
    private var nominalFrameDuration: CMTime?
    private var maximumReorderDepth = 2

    public init(generation: MediaGeneration) {
        self.generation = generation
    }

    public mutating func push(
        _ frame: DecodedVideoFrame,
        discontinuity: Bool
    ) -> [NormalizedDecodedFrame] {
        guard frame.generation >= generation else { return [] }

        if discontinuity || frame.generation > generation {
            resetTimingHistory(generation: frame.generation)
        }

        agePendingMissingFramesForNewPush()
        let trustedPTS90k = frame.parserMetadata.sourcePTS90k.map { rawPTS in
            unwrapper.unwrap(raw: rawPTS)
        }
        pending.append(
            PendingFrame(
                frame: frame,
                trustedPTS90k: trustedPTS90k,
                stableOrder: pending.count,
                missingPushAge: 0
            )
        )
        pending.sort(by: pendingFramePrecedes)

        var output: [NormalizedDecodedFrame] = []
        while pending.count > maximumReorderDepth {
            let removalIndex = expiredMissingFrameIndex() ?? pending.startIndex
            let first = pending.remove(at: removalIndex)
            output.append(normalize(first, next: pending.first))
        }
        return output
    }

    /// Nominal format configuration survives timing resets and discontinuities.
    /// Invalid, nonnumeric, and nonpositive durations are stored as absent.
    public mutating func configureNominalFrameDuration(_ duration: CMTime?) {
        nominalFrameDuration = duration.flatMap { candidate in
            positiveNumericDuration(candidate) ? candidate : nil
        }
    }

    /// Reorder-depth configuration survives timing resets and is clamped to 2...8.
    public mutating func configureMaximumReorderDepth(_ depth: Int) {
        maximumReorderDepth = min(
            max(depth, Self.minimumReorderDepth),
            Self.maximumReorderDepth
        )
    }

    public mutating func drain() -> [NormalizedDecodedFrame] {
        var output: [NormalizedDecodedFrame] = []
        output.reserveCapacity(pending.count)
        while !pending.isEmpty {
            let first = pending.removeFirst()
            output.append(normalize(first, next: pending.first))
        }
        return output
    }

    /// Clears queued frames and learned timing while retaining nominal/depth configuration.
    public mutating func reset(generation: MediaGeneration) {
        resetTimingHistory(generation: generation)
    }

    private mutating func resetTimingHistory(generation: MediaGeneration) {
        self.generation = generation
        unwrapper.reset()
        cadenceEstimator.reset()
        pending.removeAll(keepingCapacity: true)
        lastTrustedPresentationPTS = nil
        lastOutputPTS = nil
        lastExactOutputPTS = nil
        lastAccessUnitID = nil
    }

    private func pendingFramePrecedes(_ lhs: PendingFrame, _ rhs: PendingFrame) -> Bool {
        switch (lhs.trustedPTS90k, rhs.trustedPTS90k) {
        case let (lhsPTS?, rhsPTS?):
            if lhsPTS != rhsPTS { return lhsPTS < rhsPTS }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        if lhs.frame.accessUnitID != rhs.frame.accessUnitID {
            return lhs.frame.accessUnitID < rhs.frame.accessUnitID
        }
        return lhs.stableOrder < rhs.stableOrder
    }

    private mutating func agePendingMissingFramesForNewPush() {
        for index in pending.indices {
            pending[index].stableOrder = index
            if pending[index].trustedPTS90k == nil {
                pending[index].missingPushAge = min(
                    pending[index].missingPushAge + 1,
                    Self.maximumReorderDepth
                )
            }
        }
    }

    private func expiredMissingFrameIndex() -> Int? {
        pending.indices
            .filter {
                pending[$0].trustedPTS90k == nil
                    && pending[$0].missingPushAge >= maximumReorderDepth
            }
            .min { lhs, rhs in
                let left = pending[lhs]
                let right = pending[rhs]
                if left.missingPushAge != right.missingPushAge {
                    return left.missingPushAge > right.missingPushAge
                }
                if left.frame.accessUnitID != right.frame.accessUnitID {
                    return left.frame.accessUnitID < right.frame.accessUnitID
                }
                return left.stableOrder < right.stableOrder
            }
    }

    private mutating func normalize(
        _ pendingFrame: PendingFrame,
        next: PendingFrame?
    ) -> NormalizedDecodedFrame {
        let isSameAccessUnitAsPrevious = lastAccessUnitID != nil && lastAccessUnitID == pendingFrame.frame.accessUnitID
        let isSameAccessUnitAsNext = next?.frame.accessUnitID == pendingFrame.frame.accessUnitID
        lastAccessUnitID = pendingFrame.frame.accessUnitID

        let trustedPTS = pendingFrame.trustedPTS90k.map {
            CMTime(value: $0, timescale: Self.transportTimescale)
        }
        if let trustedPTS {
            if let previous = lastTrustedPresentationPTS {
                cadenceEstimator.appendTrustedDelta(CMTimeSubtract(trustedPTS, previous))
            }
            if lastTrustedPresentationPTS.map({ CMTimeCompare(trustedPTS, $0) > 0 }) ?? true {
                lastTrustedPresentationPTS = trustedPTS
            }
        }

        let adjacentTrustedDelta = trustedPTS.flatMap { currentPTS in
            next?.trustedPTS90k.map {
                CMTimeSubtract(
                    CMTime(value: $0, timescale: Self.transportTimescale),
                    currentPTS
                )
            }
        }
        let durationSelection = selectedDuration(
            for: pendingFrame.frame,
            adjacentTrustedDelta: adjacentTrustedDelta
        )

        let fieldStepDuration = CMTimeMultiplyByRatio(
            durationSelection.duration,
            multiplier: 1,
            divisor: 2
        )
        let isMultiFieldFrame = isSameAccessUnitAsPrevious || isSameAccessUnitAsNext
        let effectiveDuration = isMultiFieldFrame ? fieldStepDuration : durationSelection.duration

        let outputPTS: CMTime
        let timingWasSynthesized: Bool
        if isSameAccessUnitAsPrevious, let lastOutputPTS {
            let exactOutputPTS = CMTimeAdd(
                lastExactOutputPTS ?? lastOutputPTS,
                fieldStepDuration
            )
            outputPTS = strictlyIncreasingTransportPTS(
                from: exactOutputPTS,
                after: lastOutputPTS
            )
            lastExactOutputPTS = exactOutputPTS
            timingWasSynthesized = true
        } else if let trustedPTS,
           lastOutputPTS.map({ CMTimeCompare(trustedPTS, $0) > 0 }) ?? true {
            outputPTS = trustedPTS
            lastExactOutputPTS = trustedPTS
            timingWasSynthesized = false
        } else if let lastOutputPTS {
            let exactOutputPTS = CMTimeAdd(
                lastExactOutputPTS ?? lastOutputPTS,
                effectiveDuration
            )
            outputPTS = strictlyIncreasingTransportPTS(
                from: exactOutputPTS,
                after: lastOutputPTS
            )
            lastExactOutputPTS = exactOutputPTS
            timingWasSynthesized = true
        } else {
            outputPTS = CMTime(value: 0, timescale: Self.transportTimescale)
            lastExactOutputPTS = outputPTS
            timingWasSynthesized = true
        }
        lastOutputPTS = outputPTS

        return NormalizedDecodedFrame(
            frame: pendingFrame.frame,
            presentationTimeStamp: outputPTS,
            frameDuration: effectiveDuration,
            fieldDuration: fieldStepDuration,
            timingWasSynthesized: timingWasSynthesized,
            provenance: durationSelection.provenance
        )
    }

    private func selectedDuration(
        for frame: DecodedVideoFrame,
        adjacentTrustedDelta: CMTime?
    ) -> (duration: CMTime, provenance: TimingProvenance) {
        if let cadence = cadenceEstimator.medianFrameDuration {
            return (cadence, .trustedPresentationCadence)
        }
        if let adjacentTrustedDelta,
           FrameCadenceEstimator.isEligible(adjacentTrustedDelta) {
            return (adjacentTrustedDelta, .trustedPresentationCadence)
        }
        if positiveNumericDuration(frame.duration) {
            return (frame.duration, .decodedCallbackDuration)
        }
        if let nominalFrameDuration {
            return (nominalFrameDuration, .configuredNominalDuration)
        }
        return (Self.fallback25iDuration, .assumed25i)
    }

    private func positiveNumericDuration(_ duration: CMTime) -> Bool {
        duration.isNumeric && CMTimeCompare(duration, .zero) > 0
    }

    private func strictlyIncreasingTransportPTS(
        from exactTimestamp: CMTime,
        after previous: CMTime
    ) -> CMTime {
        let rounded = CMTimeConvertScale(
            exactTimestamp,
            timescale: Self.transportTimescale,
            method: .roundHalfAwayFromZero
        )
        if rounded.isNumeric, CMTimeCompare(rounded, previous) > 0 {
            return rounded
        }
        let (nextValue, overflowed) = previous.value.addingReportingOverflow(1)
        if !overflowed {
            return CMTime(value: nextValue, timescale: Self.transportTimescale)
        }
        return rounded
    }
}
