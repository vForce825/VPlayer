// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct VideoFormatMetadata: Sendable, Equatable {
    public enum Range: Sendable, Equatable { case video, full, unknown }
    public enum Matrix: Sendable, Equatable { case bt601, bt709, bt2020, identity, unknown }
    public enum Transfer: Sendable, Equatable { case bt709, pq, hlg, linear, unknown }
    public enum Primaries: Sendable, Equatable { case bt709, bt2020, unknown }

    public struct ChromaLocation: Sendable, Equatable {
        public let topField: String?
        public let bottomField: String?

        public init(topField: String?, bottomField: String?) {
            self.topField = topField
            self.bottomField = bottomField
        }
    }

    public struct HDRStaticMetadata: Sendable, Equatable {
        public let masteringDisplayColorVolume: Data?
        public let contentLightLevelInfo: Data?

        public init(masteringDisplayColorVolume: Data?, contentLightLevelInfo: Data?) {
            self.masteringDisplayColorVolume = masteringDisplayColorVolume
            self.contentLightLevelInfo = contentLightLevelInfo
        }
    }

    public let dimensions: CMVideoDimensions
    public let bitDepth: Int
    public let range: Range
    public let matrix: Matrix
    public let transfer: Transfer
    public let primaries: Primaries
    public let cleanAperture: CGRect?
    public let chromaLocation: ChromaLocation
    public let hdrStaticMetadata: HDRStaticMetadata

    public init(
        dimensions: CMVideoDimensions,
        bitDepth: Int,
        range: Range,
        matrix: Matrix,
        transfer: Transfer,
        primaries: Primaries,
        cleanAperture: CGRect?,
        chromaLocation: ChromaLocation,
        hdrStaticMetadata: HDRStaticMetadata
    ) {
        self.dimensions = dimensions
        self.bitDepth = bitDepth
        self.range = range
        self.matrix = matrix
        self.transfer = transfer
        self.primaries = primaries
        self.cleanAperture = cleanAperture
        self.chromaLocation = chromaLocation
        self.hdrStaticMetadata = hdrStaticMetadata
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dimensions.width == rhs.dimensions.width
            && lhs.dimensions.height == rhs.dimensions.height
            && lhs.bitDepth == rhs.bitDepth
            && lhs.range == rhs.range
            && lhs.matrix == rhs.matrix
            && lhs.transfer == rhs.transfer
            && lhs.primaries == rhs.primaries
            && lhs.cleanAperture == rhs.cleanAperture
            && lhs.chromaLocation == rhs.chromaLocation
            && lhs.hdrStaticMetadata == rhs.hdrStaticMetadata
    }
}

public struct DecodedVideoFrame: @unchecked Sendable {
    public let accessUnitID: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let generation: MediaGeneration
    public let parserMetadata: VideoParserMetadata
    public let formatMetadata: VideoFormatMetadata

    public init(
        accessUnitID: UInt64,
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        parserMetadata: VideoParserMetadata,
        formatMetadata: VideoFormatMetadata
    ) {
        self.accessUnitID = accessUnitID
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.generation = generation
        self.parserMetadata = parserMetadata
        self.formatMetadata = formatMetadata
    }
}

public enum VideoDecoderFailure: Error, Sendable, Equatable {
    case sessionCreate(OSStatus)
    case softwareDecoder
    case badData(OSStatus)
    case malfunction(OSStatus)
    case backpressureTimeout
}

/// Identifies one decoder transition and, after a successful configure, the
/// decoder session established by that transition.
///
/// Tokens are deliberately opaque and freshly generated. Media generation is
/// not enough to fence a same-generation session replacement or route switch.
public struct VideoDecoderTransitionToken: Sendable, Hashable {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

public enum VideoDecoderTransitionOutcome: Sendable, Equatable {
    case completed
    case failed(VideoDecoderFailure)
}

public enum VideoDecoderTransition: @unchecked Sendable {
    case configure(
        token: VideoDecoderTransitionToken,
        format: CMVideoFormatDescription,
        generation: MediaGeneration
    )
    case drainAndInvalidate(token: VideoDecoderTransitionToken)
    case invalidate(token: VideoDecoderTransitionToken)
}

public struct VideoDecoderEventIdentity: Sendable, Hashable {
    public let generation: MediaGeneration
    public let transitionToken: VideoDecoderTransitionToken

    public init(
        generation: MediaGeneration,
        transitionToken: VideoDecoderTransitionToken
    ) {
        self.generation = generation
        self.transitionToken = transitionToken
    }
}

public enum VideoDecoderSubmissionDisposition: Sendable, Equatable {
    case produced
    case noFrame
    case cancelled
}

public enum VideoDecoderTransitionRequirement: Sendable, Equatable {
    /// The current media format remains valid, but the decoder implementation
    /// or native session must change before this access unit is submitted.
    case reconfigure
}

public enum VideoDecoderEvent: @unchecked Sendable {
    case frame(DecodedVideoFrame, identity: VideoDecoderEventIdentity)
    case recoverableFailure(VideoDecoderFailure, identity: VideoDecoderEventIdentity)
    case fatalFailure(VideoDecoderFailure, identity: VideoDecoderEventIdentity)
    /// A submission that could not be handed to the decode session at all.
    ///
    /// Submission does not happen on the caller's thread, so the failure cannot
    /// come back as a `throw` from `decode`. It carries the same failures the
    /// synchronous path used to raise and is classified identically.
    case submissionFailure(
        accessUnitID: UInt64,
        failure: VideoDecoderFailure,
        identity: VideoDecoderEventIdentity
    )
    /// The decoder has finished with one submitted access unit, whether it
    /// produced a frame, dropped it, or rejected it asynchronously.
    ///
    /// This is deliberately separate from `frame`: reordered decoders can
    /// produce zero or multiple frames for a submission, while admission needs
    /// exactly one release signal for every accepted access unit.
    case submissionCompleted(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity,
        disposition: VideoDecoderSubmissionDisposition
    )
    /// Native transition work has finished. The token lets the coordinator
    /// reject a superseded configure without reopening admission.
    case transitionCompleted(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    )
}

public protocol VideoDecoding: AnyObject {
    func transition(_ transition: VideoDecoderTransition)
    func transitionRequirement(
        for accessUnit: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement?
    /// Hands an access unit to the decoder. Submission is asynchronous, so a
    /// failure to submit arrives as `VideoDecoderEvent.submissionFailure`
    /// rather than as a `throw`; the signature stays throwing for decoders that
    /// can reject a unit outright. Every call that returns normally must later
    /// emit exactly one matching `submissionCompleted`; a call that throws was
    /// rejected synchronously and emits no completion.
    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws
    func setTuning(_ tuning: PlaybackTuning)
}

public extension VideoDecoding {
    func transitionRequirement(
        for _: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement? { nil }

    func setTuning(_ tuning: PlaybackTuning) {}
}
