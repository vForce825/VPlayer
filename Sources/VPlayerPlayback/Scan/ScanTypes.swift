// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public enum FieldParity: UInt8, Equatable, Sendable {
    case top
    case bottom
}

public enum FieldOrderConfidence: UInt8, Equatable, Sendable {
    case assumed
    case detected
    case signaled
}

public enum FieldEvidenceSource: UInt8, Equatable, Sendable {
    case none
    case parser
    case picture
    case formatDescription
    case pixelBuffer
    case contentProbe
}

public struct ResolvedFieldOrder: Equatable, Sendable {
    public let parity: FieldParity
    public let confidence: FieldOrderConfidence
    public let source: FieldEvidenceSource

    public init(
        parity: FieldParity,
        confidence: FieldOrderConfidence,
        source: FieldEvidenceSource
    ) {
        self.parity = parity
        self.confidence = confidence
        self.source = source
    }

    public init(coded: CodedFieldOrder) {
        switch coded {
        case .tt, .bt:
            self.init(parity: .top, confidence: .signaled, source: .parser)
        case .bb, .tb:
            self.init(parity: .bottom, confidence: .signaled, source: .parser)
        case .unknown, .progressive:
            self.init(parity: .top, confidence: .assumed, source: .none)
        }
    }
}

public enum ScanType: Equatable, Sendable {
    case unknown
    case progressive
    case interlaced(ResolvedFieldOrder)
    case progressiveSegmentedFrame(ResolvedFieldOrder?)
}

public struct FieldMetadataEvidence: Equatable, Sendable {
    public let fieldCount: Int?
    public let fieldOrder: ResolvedFieldOrder?
    public let source: FieldEvidenceSource

    public init(
        fieldCount: Int?,
        fieldOrder: ResolvedFieldOrder?,
        source: FieldEvidenceSource
    ) {
        self.fieldCount = fieldCount
        self.fieldOrder = fieldOrder
        self.source = source
    }
}

public struct ContentProbeSample: Equatable, Sendable {
    public let combRatio: Float
    public let motionRatio: Float
    public let sampleCount: Int

    public init(combRatio: Float, motionRatio: Float, sampleCount: Int) {
        self.combRatio = combRatio
        self.motionRatio = motionRatio
        self.sampleCount = sampleCount
    }
}

public struct ScanObservation: Equatable, Sendable {
    public let generation: MediaGeneration
    public let parser: VideoParserMetadata
    public let decodedFields: FieldMetadataEvidence
    public let probe: ContentProbeSample?
    public let presentationTimeStamp: CMTime

    public init(
        generation: MediaGeneration,
        parser: VideoParserMetadata,
        decodedFields: FieldMetadataEvidence,
        probe: ContentProbeSample?,
        presentationTimeStamp: CMTime
    ) {
        self.generation = generation
        self.parser = parser
        self.decodedFields = decodedFields
        self.probe = probe
        self.presentationTimeStamp = presentationTimeStamp
    }
}

public enum PresentationOrigin: Equatable, Sendable {
    case raw
    case appleTemporal
    case metalYADIF(field: FieldParity)
}
