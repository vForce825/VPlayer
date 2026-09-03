// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import XCTest
@testable import VPlayerPlayback

final class VideoSampleBufferBuilderTests: XCTestCase {
    func testBuildPreservesImageIdentityAndExactTimingWithoutDisplayOverrides() throws {
        let pixelBuffer = try VideoTestFactories.nv12()
        let frame = makeFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 1_001, timescale: 30_000),
            duration: CMTime(value: 1_001, timescale: 30_000)
        )

        let sample = try VideoImageSampleBufferBuilder().make(frame: frame)

        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === pixelBuffer)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), frame.presentationTimeStamp),
            0
        )
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetDuration(sample), frame.duration), 0)
        XCTAssertFalse(CMSampleBufferGetDecodeTimeStamp(sample).isValid)
        XCTAssertNil(CMGetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            attachmentModeOut: nil
        ))
        XCTAssertNil(CMGetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DoNotDisplay,
            attachmentModeOut: nil
        ))
    }

    func testBuildAddsPresentationOffsetWithoutMutatingSourceFrameTiming() throws {
        let frame = makeFrame(
            pixelBuffer: try VideoTestFactories.nv12(),
            presentationTimeStamp: CMTime(value: 2_000, timescale: 1_000)
        )
        let offset = CMTime(value: 450, timescale: 1_000)

        let sample = try VideoImageSampleBufferBuilder().make(
            frame: frame,
            presentationTimeOffset: offset
        )

        XCTAssertEqual(
            CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMTime(value: 2_450, timescale: 1_000)
            ),
            0
        )
        XCTAssertEqual(frame.presentationTimeStamp, CMTime(value: 2_000, timescale: 1_000))
        XCTAssertEqual(CMSampleBufferGetDuration(sample), frame.duration)
    }

    func testBuilderRebuildsDescriptionWhenPixelFormatChangesAndResetDropsCache() throws {
        let builder = VideoImageSampleBufferBuilder()
        let nv12 = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let p010 = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )

        let first = try builder.make(frame: makeFrame(pixelBuffer: nv12))
        let second = try builder.make(frame: makeFrame(pixelBuffer: p010))
        let firstDescription = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
        let secondDescription = try XCTUnwrap(CMSampleBufferGetFormatDescription(second))

        XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(
            firstDescription,
            imageBuffer: nv12
        ))
        XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(
            secondDescription,
            imageBuffer: p010
        ))
        XCTAssertFalse(firstDescription === secondDescription)

        builder.reset()
        let afterReset = try builder.make(frame: makeFrame(pixelBuffer: nv12))
        XCTAssertFalse(firstDescription === CMSampleBufferGetFormatDescription(afterReset))
    }

    func testBuilderRejectsInvalidTimingAndNonIOSurfaceStorage() throws {
        let builder = VideoImageSampleBufferBuilder()
        XCTAssertThrowsError(try builder.make(frame: makeFrame(
            pixelBuffer: try VideoTestFactories.nv12(),
            presentationTimeStamp: .invalid
        )))
        XCTAssertThrowsError(try builder.make(frame: makeFrame(
            pixelBuffer: try VideoTestFactories.nv12(),
            duration: .zero
        )))

        var plainBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            36,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &plainBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let unbacked = try XCTUnwrap(plainBuffer)
        XCTAssertNil(CVPixelBufferGetIOSurface(unbacked))
        XCTAssertThrowsError(try builder.make(frame: makeFrame(pixelBuffer: unbacked)))
    }

    private func makeFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime = .zero,
        duration: CMTime = CMTime(value: 1, timescale: 25)
    ) -> VideoPresentationFrame {
        VideoPresentationFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            generation: MediaGeneration(rawValue: 1),
            sequenceNumber: 1,
            sourceAccessUnitID: 1,
            formatMetadata: VideoTestFactories.metadata(
                bitDepth: CVPixelBufferGetPixelFormatType(pixelBuffer)
                    == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 10 : 8
            )
        )
    }
}
