// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct VideoProcessingFrameBatch: @unchecked Sendable {
    public let first: VideoPresentationFrame
    public let remaining: [VideoPresentationFrame]

    public init(
        first: VideoPresentationFrame,
        remaining: [VideoPresentationFrame] = []
    ) {
        self.first = first
        self.remaining = remaining
    }

    public var frames: [VideoPresentationFrame] {
        [first] + remaining
    }
}

public enum VideoProcessingTransientDropReason: Sendable, Equatable {
    case queuePressure
    case resourcePressure
    case invalidTiming
}

public enum VideoProcessingStructuralFailure: Sendable, Equatable {
    case invalidSurface
    case surfacePool
    case rendererAttributes
    case textureMapping
    case shaderPipeline
    case commandExecution
}

public enum VideoProcessingCancellationReason: Sendable, Equatable {
    case staleGeneration
    case reset
    case draining
    case referenceWindowDiscard
}

public enum VideoProcessingResult: @unchecked Sendable {
    case produced(VideoProcessingFrameBatch)
    case transientDrop(VideoProcessingTransientDropReason)
    case structuralFailure(VideoProcessingStructuralFailure)
    case cancelled(VideoProcessingCancellationReason)
}

public protocol VideoFrameProcessing: AnyObject {
    var requiredInputFrameCount: Int { get }
    func reset(to generation: MediaGeneration)
    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    )
}

public final class PassthroughVideoProcessor: VideoFrameProcessing, @unchecked Sendable {
    public let requiredInputFrameCount = 1
    private var generation = MediaGeneration(rawValue: 0)
    private var sequence: UInt64 = 0

    public init() {}

    public func reset(to generation: MediaGeneration) {
        self.generation = generation
        sequence = 0
    }

    public func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    ) {
        guard frame.generation == generation else {
            completion(.cancelled(.staleGeneration))
            return
        }
        sequence &+= 1
        completion(.produced(VideoProcessingFrameBatch(
            first: VideoPresentationFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                generation: frame.generation,
                sequenceNumber: sequence,
                sourceAccessUnitID: frame.accessUnitID,
                formatMetadata: frame.formatMetadata
            )
        )))
    }
}
