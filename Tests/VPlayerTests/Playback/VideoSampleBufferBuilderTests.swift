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

    func testSameSizeTenBitSDRHDRSwitchReplacesColorDescriptionAndClearsHDRMetadata() throws {
        let builder = VideoImageSampleBufferBuilder()
        // 保持尺寸和像素格式相同，确保缓存依据色彩附件失效，而不是碰巧由分辨率变化触发。
        let pixel = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        var previous: CMFormatDescription?
        for transfer in [kCVImageBufferTransferFunction_ITU_R_709_2,
                         kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                         kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                         kCVImageBufferTransferFunction_ITU_R_709_2] {
            let hdr = transfer != kCVImageBufferTransferFunction_ITU_R_709_2
            let primaries = hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
            let matrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            CVBufferRemoveAllAttachments(pixel)
            CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            if hdr {
                CVBufferSetAttachment(pixel, kCVImageBufferContentLightLevelInfoKey,
                    Data([0x03, 0xE8, 0x00, 0xC8]) as CFData, .shouldPropagate)
            }
            let sample = try builder.make(frame: makeFrame(pixelBuffer: pixel))
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === pixel)
            XCTAssertFalse(format === previous)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String, transfer as String)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String, primaries as String)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String, matrix as String)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) != nil, hdr)
            XCTAssertTrue(CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool != true)
            previous = format
        }
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
