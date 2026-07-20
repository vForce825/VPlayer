// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

public struct ScanClassifierConfiguration: Equatable, Sendable {
    public var progressiveConfirmationFrames: Int
    public var psfConfirmationFrames: Int
    public var exitInterlacedConfirmationFrames: Int
    public var combThreshold: Float
    public var psfMaximumCombRatio: Float
    public var motionThreshold: Float

    public init(
        progressiveConfirmationFrames: Int = 8,
        psfConfirmationFrames: Int = 12,
        exitInterlacedConfirmationFrames: Int = 12,
        combThreshold: Float = 0.08,
        psfMaximumCombRatio: Float = 0.02,
        motionThreshold: Float = 0.015
    ) {
        self.progressiveConfirmationFrames = progressiveConfirmationFrames
        self.psfConfirmationFrames = psfConfirmationFrames
        self.exitInterlacedConfirmationFrames = exitInterlacedConfirmationFrames
        self.combThreshold = combThreshold
        self.psfMaximumCombRatio = psfMaximumCombRatio
        self.motionThreshold = motionThreshold
    }
}

public struct ScanClassificationChange: Equatable, Sendable {
    public let previous: ScanType
    public let current: ScanType
    public let generation: MediaGeneration

    public init(previous: ScanType, current: ScanType, generation: MediaGeneration) {
        self.previous = previous
        self.current = current
        self.generation = generation
    }
}

public struct ScanTypeClassifier: Sendable {
    public private(set) var current: ScanType

    private var generation: MediaGeneration
    private let configuration: ScanClassifierConfiguration
    private var progressiveStreak = 0
    private var psfStreak = 0

    public init(
        generation: MediaGeneration,
        configuration: ScanClassifierConfiguration = .init()
    ) {
        self.generation = generation
        self.configuration = configuration
        current = .unknown
    }

    public mutating func observe(
        _ observation: ScanObservation
    ) -> ScanClassificationChange? {
        guard observation.generation == generation else {
            return nil
        }

        let orderEvidence = explicitOrder(in: observation)
        let probe = validProbe(observation.probe)

        if isSeparatedPicture(observation.parser.pictureStructure) {
            clearStreaks()
            return transition(to: .interlaced(interlaceOrder(from: orderEvidence)))
        }

        if let probe,
           probe.combRatio >= configuration.combThreshold,
           probe.motionRatio >= configuration.motionThreshold {
            clearStreaks()
            return transition(to: .interlaced(interlaceOrder(from: orderEvidence)))
        }

        let fieldSignalled = hasFieldSignalling(observation)
        let refinementOrder: ResolvedFieldOrder?
        if case let .interlaced(existingOrder) = current,
           existingOrder.confidence == .assumed,
           case let .agree(explicitOrder) = orderEvidence,
           explicitOrder.confidence != .assumed {
            refinementOrder = explicitOrder
        } else {
            refinementOrder = nil
        }

        if fieldSignalled,
           let probe,
           probe.motionRatio >= configuration.motionThreshold,
           probe.combRatio <= configuration.psfMaximumCombRatio {
            progressiveStreak = 0
            psfStreak = increment(psfStreak, toward: psfThreshold)

            if psfStreak == psfThreshold,
               !isConfirmedInterlaced,
               !isConfirmedPsF {
                let order: ResolvedFieldOrder?
                if case let .agree(explicitOrder) = orderEvidence {
                    order = explicitOrder
                } else {
                    order = nil
                }
                return transition(to: .progressiveSegmentedFrame(order))
            }
            return applyRefinement(refinementOrder)
        }

        psfStreak = 0

        if isTrustedParserProgressive(observation) {
            let threshold = usesExitHysteresis
                ? exitInterlacedThreshold
                : progressiveThreshold
            progressiveStreak = increment(progressiveStreak, toward: threshold)

            if progressiveStreak == threshold, current != .progressive {
                return transition(to: .progressive)
            }
            return applyRefinement(refinementOrder)
        }

        progressiveStreak = 0
        return applyRefinement(refinementOrder)
    }

    public mutating func reset(generation: MediaGeneration) {
        self.generation = generation
        current = .unknown
        clearStreaks()
    }

    private var progressiveThreshold: Int {
        max(1, configuration.progressiveConfirmationFrames)
    }

    private var psfThreshold: Int {
        max(1, configuration.psfConfirmationFrames)
    }

    private var exitInterlacedThreshold: Int {
        max(1, configuration.exitInterlacedConfirmationFrames)
    }

    private var isConfirmedInterlaced: Bool {
        if case .interlaced = current { return true }
        return false
    }

    private var isConfirmedPsF: Bool {
        if case .progressiveSegmentedFrame = current { return true }
        return false
    }

    private var usesExitHysteresis: Bool {
        isConfirmedInterlaced || isConfirmedPsF
    }

    private mutating func clearStreaks() {
        progressiveStreak = 0
        psfStreak = 0
    }

    private func increment(_ value: Int, toward threshold: Int) -> Int {
        guard value < threshold else {
            return threshold
        }
        return value + 1
    }

    private mutating func transition(to next: ScanType) -> ScanClassificationChange? {
        guard current != next else {
            return nil
        }
        let previous = current
        current = next
        return ScanClassificationChange(
            previous: previous,
            current: next,
            generation: generation
        )
    }

    private mutating func applyRefinement(
        _ order: ResolvedFieldOrder?
    ) -> ScanClassificationChange? {
        guard let order else {
            return nil
        }
        return transition(to: .interlaced(order))
    }

    private func interlaceOrder(from evidence: ExplicitOrderEvidence) -> ResolvedFieldOrder {
        if case let .interlaced(existing) = current {
            switch evidence {
            case .none, .conflict:
                return existing
            case let .agree(candidate):
                if existing.confidence == .assumed,
                   candidate.confidence != .assumed {
                    return candidate
                }
                return existing
            }
        }

        if case let .agree(order) = evidence {
            return order
        }
        return ResolvedFieldOrder(
            parity: .top,
            confidence: .assumed,
            source: .contentProbe
        )
    }

    private func explicitOrder(in observation: ScanObservation) -> ExplicitOrderEvidence {
        var candidates: [ResolvedFieldOrder] = []

        if let decoded = observation.decodedFields.fieldOrder {
            candidates.append(decoded)
        }
        if let coded = observation.parser.fieldOrder,
           [.tt, .bb, .tb, .bt].contains(coded) {
            candidates.append(ResolvedFieldOrder(coded: coded))
        }
        if let topFieldFirst = observation.parser.topFieldFirst {
            candidates.append(ResolvedFieldOrder(
                parity: topFieldFirst ? .top : .bottom,
                confidence: .signaled,
                source: .parser
            ))
        }

        guard let best = candidates.first else {
            return .none
        }
        guard candidates.dropFirst().allSatisfy({ $0.parity == best.parity }) else {
            return .conflict
        }
        let bestExplicit = candidates.first { $0.confidence != .assumed }
        return .agree(bestExplicit ?? best)
    }

    private func validProbe(_ sample: ContentProbeSample?) -> ContentProbeSample? {
        guard let sample,
              sample.combRatio.isFinite,
              sample.motionRatio.isFinite,
              (0...1).contains(sample.combRatio),
              (0...1).contains(sample.motionRatio),
              sample.sampleCount > 0 else {
            return nil
        }
        return sample
    }

    private func isSeparatedPicture(_ picture: PictureStructure?) -> Bool {
        picture == .topField || picture == .bottomField
    }

    private func hasFieldSignalling(_ observation: ScanObservation) -> Bool {
        if observation.parser.isInterlaced == true {
            return true
        }
        if let coded = observation.parser.fieldOrder,
           [.tt, .bb, .tb, .bt].contains(coded) {
            return true
        }
        return observation.decodedFields.fieldCount == 2
            || observation.decodedFields.fieldOrder != nil
    }

    private func isTrustedParserProgressive(_ observation: ScanObservation) -> Bool {
        guard !isSeparatedPicture(observation.parser.pictureStructure),
              observation.decodedFields.fieldCount != 2,
              observation.decodedFields.fieldOrder == nil else {
            return false
        }

        let parser = observation.parser
        return (parser.isInterlaced == false
                    && (parser.fieldOrder == nil || parser.fieldOrder == .progressive))
            || (parser.fieldOrder == .progressive && parser.isInterlaced != true)
    }
}

private enum ExplicitOrderEvidence: Sendable {
    case none
    case agree(ResolvedFieldOrder)
    case conflict
}
