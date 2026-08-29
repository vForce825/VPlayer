// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo

public struct VideoPresentationFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let generation: MediaGeneration
    public let sequenceNumber: UInt64
    public let sourceAccessUnitID: UInt64
    public let formatMetadata: VideoFormatMetadata

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        sequenceNumber: UInt64,
        sourceAccessUnitID: UInt64,
        formatMetadata: VideoFormatMetadata
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.generation = generation
        self.sequenceNumber = sequenceNumber
        self.sourceAccessUnitID = sourceAccessUnitID
        self.formatMetadata = formatMetadata
    }
}

/// A decoded 4:2:0 frame is cheap at HD and enormous at 4K P010. Duration-only
/// queue bounds therefore turn the same two-second setting from roughly 150 MB
/// into multiple gigabytes. These budgets preserve the configured duration for
/// normal HD playback while putting a hard ceiling on decoded-surface memory.
enum PlaybackVideoMemoryBudget {
    static let presentationQueueBytes = 512 * 1_024 * 1_024
    static let retainedAnchorBytes = 256 * 1_024 * 1_024
    static let decoderPoolBytes = 256 * 1_024 * 1_024
    static let minimumDecoderPoolFrames = 8
    // Leave a few surfaces for a frame arriving while the display link is
    // selecting and submitting the one that is due. Treating every byte as
    // usable runway makes the first transient allocation an overflow.
    static let presentationQueueReserveFrames = 3

    static func estimated420SurfaceBytes(
        dimensions: CMVideoDimensions,
        bitDepth: Int
    ) -> Int {
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 0, height > 0,
              let pixels = multiplied(width, height),
              let samples = multiplied(pixels, 3) else { return Int.max }
        // NV12 stores 12 bits per pixel. P010 stores each 10-bit component in a
        // 16-bit lane, so its physical footprint is 24 bits per pixel.
        let bytesPerComponent = bitDepth > 8 ? 2 : 1
        guard let bytes = multiplied(samples, bytesPerComponent) else {
            return Int.max
        }
        return max(1, bytes / 2)
    }

    static func maximumFrameCount(
        byteBudget: Int,
        estimatedFrameBytes: Int,
        minimum: Int = 1
    ) -> Int {
        guard byteBudget > 0, estimatedFrameBytes > 0,
              estimatedFrameBytes != Int.max else { return max(1, minimum) }
        return max(minimum, byteBudget / estimatedFrameBytes)
    }

    /// Duration the memory-bounded queue can safely hold for this format. The
    /// playback clock must use the same effective horizon: if it deliberately
    /// trails 4K50 by a full second while the queue can retain only ~0.4 s, the
    /// queue discards most future frames and turns a healthy 50 fps decoder into
    /// a slideshow.
    static func presentationHorizon(
        frameDuration: CMTime,
        estimatedFrameBytes: Int
    ) -> CMTime? {
        guard frameDuration.isNumeric,
              CMTimeCompare(frameDuration, .zero) > 0 else { return nil }
        let capacity = maximumFrameCount(
            byteBudget: presentationQueueBytes,
            estimatedFrameBytes: estimatedFrameBytes
        )
        let usableFrames = max(1, capacity - presentationQueueReserveFrames)
        return CMTimeMultiply(
            frameDuration,
            multiplier: Int32(clamping: usableFrames)
        )
    }

    private static func multiplied(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}

extension VideoPresentationFrame {
    var estimatedStorageBytes: Int {
        PlaybackVideoMemoryBudget.estimated420SurfaceBytes(
            dimensions: formatMetadata.dimensions,
            bitDepth: formatMetadata.bitDepth
        )
    }

    var memoryLimitedPresentationHorizon: CMTime? {
        PlaybackVideoMemoryBudget.presentationHorizon(
            frameDuration: duration,
            estimatedFrameBytes: estimatedStorageBytes
        )
    }
}
