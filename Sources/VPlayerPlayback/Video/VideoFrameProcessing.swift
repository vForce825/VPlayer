// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Metal

public protocol VideoFrameProcessing: AnyObject {
    var requiredInputFrameCount: Int { get }
    func reset(to generation: MediaGeneration)
    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    )
}

public enum VideoFrameStorage: @unchecked Sendable {
    case pixelBuffer(CVPixelBuffer)
    case metalPlanes(MetalPlaneSet)
}

public struct MetalPlaneSet: @unchecked Sendable {
    public let luma: any MTLTexture
    public let chroma: any MTLTexture
    public let retainedObjects: [AnyObject]

    public init(
        luma: any MTLTexture,
        chroma: any MTLTexture,
        retainedObjects: [AnyObject]
    ) {
        self.luma = luma
        self.chroma = chroma
        self.retainedObjects = retainedObjects
    }
}

public struct VideoPresentationFrame: @unchecked Sendable {
    public let storage: VideoFrameStorage
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let generation: MediaGeneration
    public let sequenceNumber: UInt64
    public let sourceAccessUnitID: UInt64
    public let formatMetadata: VideoFormatMetadata

    public init(
        storage: VideoFrameStorage,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        sequenceNumber: UInt64,
        sourceAccessUnitID: UInt64,
        formatMetadata: VideoFormatMetadata
    ) {
        self.storage = storage
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.generation = generation
        self.sequenceNumber = sequenceNumber
        self.sourceAccessUnitID = sourceAccessUnitID
        self.formatMetadata = formatMetadata
    }
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
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    ) {
        guard frame.generation == generation else {
            completion(.success([]))
            return
        }
        sequence &+= 1
        completion(.success([VideoPresentationFrame(
            storage: .pixelBuffer(frame.pixelBuffer),
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            generation: frame.generation,
            sequenceNumber: sequence,
            sourceAccessUnitID: frame.accessUnitID,
            formatMetadata: frame.formatMetadata
        )]))
    }
}
