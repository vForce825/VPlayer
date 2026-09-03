// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo

final class VideoImageSampleBufferBuilder: @unchecked Sendable {
    private var cachedDescription: CMVideoFormatDescription?

    func make(
        frame: VideoPresentationFrame,
        presentationTimeOffset: CMTime = .zero
    ) throws -> CMSampleBuffer {
        let pixelBuffer = frame.pixelBuffer
        let presentationTimeStamp = CMTimeAdd(
            frame.presentationTimeStamp,
            presentationTimeOffset
        )
        guard frame.presentationTimeStamp.isNumeric,
              presentationTimeOffset.isNumeric,
              CMTimeCompare(presentationTimeOffset, .zero) >= 0,
              presentationTimeStamp.isNumeric,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw PlaybackCoreError.videoSampleBuffer("invalid-frame")
        }

        let description: CMVideoFormatDescription
        if let cachedDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(
            cachedDescription,
            imageBuffer: pixelBuffer
           ) {
            description = cachedDescription
        } else {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            )
            guard status == noErr, let created else {
                throw PlaybackCoreError.videoSampleBuffer("format.\(status)")
            }
            cachedDescription = created
            description = created
        }

        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PlaybackCoreError.videoSampleBuffer("sample.\(status)")
        }
        return sampleBuffer
    }

    func reset() {
        cachedDescription = nil
    }
}
