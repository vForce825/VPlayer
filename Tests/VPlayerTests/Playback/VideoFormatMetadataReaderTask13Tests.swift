// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoFormatMetadataReaderTask13Tests: XCTestCase {
    func testNV12AndP010VideoAndFullRangeMatrixRemainsExactAndUnknownMetadataStaysUnknown() throws {
        let cases: [(OSType, Int, VideoFormatMetadata.Range)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, .video),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 8, .full),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 10, .video),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 10, .full),
        ]

        for (pixelFormat, expectedBitDepth, expectedRange) in cases {
            let pixelBuffer = try makePixelBuffer(pixelFormat: pixelFormat)
            let metadata = try read(pixelBuffer)

            XCTAssertEqual(metadata.dimensions.width, 64)
            XCTAssertEqual(metadata.dimensions.height, 32)
            XCTAssertEqual(metadata.bitDepth, expectedBitDepth)
            XCTAssertEqual(metadata.range, expectedRange)
            XCTAssertEqual(metadata.primaries, .unknown)
            XCTAssertEqual(metadata.transfer, .unknown)
            XCTAssertEqual(metadata.matrix, .unknown)
            XCTAssertNil(metadata.sampleAspectRatio)
        }
    }

    func testPixelAspectRatioIsReducedDeepCopiedAndParticipatesInMetadataEquality() throws {
        let pixelBuffer = try makePixelBuffer()
        let aspect = NSMutableDictionary(dictionary: [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: NSNumber(value: 8),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: NSNumber(value: 6),
        ])
        setAttachment(pixelBuffer, key: kCVImageBufferPixelAspectRatioKey, value: aspect)

        let metadata = try read(pixelBuffer)
        aspect.removeAllObjects()
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey)

        XCTAssertEqual(metadata.sampleAspectRatio, MediaRational(num: 4, den: 3))
        XCTAssertNotEqual(metadata, replacingAspectRatio(in: metadata, with: nil))
        XCTAssertEqual(
            replacingAspectRatio(in: metadata, with: MediaRational(num: 4, den: 3)),
            metadata
        )
    }

    func testMalformedPixelAspectRatioMatrixFailsClosedWithTypedDecoderFailure() throws {
        let validHorizontal = NSNumber(value: 4)
        let validVertical = NSNumber(value: 3)
        let malformed: [CFTypeRef] = [
            "not-a-dictionary" as CFString,
            [
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: validVertical,
            ] as CFDictionary,
            [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: validHorizontal,
            ] as CFDictionary,
            aspectDictionary(horizontal: NSNumber(value: 0), vertical: validVertical),
            aspectDictionary(horizontal: NSNumber(value: -1), vertical: validVertical),
            aspectDictionary(horizontal: NSNumber(value: 1.5), vertical: validVertical),
            aspectDictionary(
                horizontal: NSNumber(value: Int64(Int32.max) + 1),
                vertical: validVertical
            ),
            aspectDictionary(horizontal: "4" as CFString, vertical: validVertical),
            aspectDictionary(horizontal: validHorizontal, vertical: kCFBooleanTrue),
        ]

        for attachment in malformed {
            let pixelBuffer = try makePixelBuffer()
            setAttachment(
                pixelBuffer,
                key: kCVImageBufferPixelAspectRatioKey,
                value: attachment
            )

            XCTAssertThrowsError(try read(pixelBuffer)) { error in
                XCTAssertEqual(
                    error as? VideoDecoderFailure,
                    .malfunction(kCVReturnInvalidArgument)
                )
            }
        }
    }

    func testExistingAttachmentsAreCopiedIndependentlyWithoutInventingBT709() throws {
        try assertColorStringIsCopied(
            key: kCVImageBufferColorPrimariesKey,
            original: kCVImageBufferColorPrimaries_ITU_R_2020,
            assertion: { XCTAssertEqual($0.primaries, .bt2020) }
        )
        try assertColorStringIsCopied(
            key: kCVImageBufferTransferFunctionKey,
            original: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            assertion: { XCTAssertEqual($0.transfer, .hlg) }
        )
        try assertColorStringIsCopied(
            key: kCVImageBufferYCbCrMatrixKey,
            original: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            assertion: { XCTAssertEqual($0.matrix, .bt2020) }
        )

        let apertureBuffer = try makePixelBuffer()
        let aperture = NSMutableDictionary(dictionary: [
            kCVImageBufferCleanApertureWidthKey as String: NSNumber(value: 60),
            kCVImageBufferCleanApertureHeightKey as String: NSNumber(value: 28),
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: NSNumber(value: 1),
            kCVImageBufferCleanApertureVerticalOffsetKey as String: NSNumber(value: -1),
        ])
        setAttachment(apertureBuffer, key: kCVImageBufferCleanApertureKey, value: aperture)
        let apertureMetadata = try read(apertureBuffer)
        aperture.removeAllObjects()
        XCTAssertEqual(apertureMetadata.cleanAperture, CGRect(x: 3, y: 3, width: 60, height: 28))

        let chromaBuffer = try makePixelBuffer()
        let top = try XCTUnwrap(CFStringCreateMutableCopy(
            kCFAllocatorDefault,
            0,
            "TopLeft" as CFString
        ))
        let bottom = try XCTUnwrap(CFStringCreateMutableCopy(
            kCFAllocatorDefault,
            0,
            "BottomLeft" as CFString
        ))
        setAttachment(chromaBuffer, key: kCVImageBufferChromaLocationTopFieldKey, value: top)
        setAttachment(chromaBuffer, key: kCVImageBufferChromaLocationBottomFieldKey, value: bottom)
        let chromaMetadata = try read(chromaBuffer)
        CFStringReplaceAll(top, "changed" as CFString)
        CFStringReplaceAll(bottom, "changed" as CFString)
        XCTAssertEqual(
            chromaMetadata.chromaLocation,
            .init(topField: "TopLeft", bottomField: "BottomLeft")
        )

        let masteringBuffer = try makePixelBuffer()
        let masteringBytes = Array(UInt8(0)..<UInt8(24))
        let mastering = try mutableData(masteringBytes)
        setAttachment(
            masteringBuffer,
            key: kCVImageBufferMasteringDisplayColorVolumeKey,
            value: mastering
        )
        let masteringMetadata = try read(masteringBuffer)
        CFDataDeleteBytes(mastering, CFRange(location: 0, length: masteringBytes.count))
        XCTAssertEqual(
            masteringMetadata.hdrStaticMetadata.masteringDisplayColorVolume,
            Data(masteringBytes)
        )

        let lightBuffer = try makePixelBuffer()
        let lightBytes: [UInt8] = [1, 2, 3, 4]
        let light = try mutableData(lightBytes)
        setAttachment(lightBuffer, key: kCVImageBufferContentLightLevelInfoKey, value: light)
        let lightMetadata = try read(lightBuffer)
        CFDataDeleteBytes(light, CFRange(location: 0, length: lightBytes.count))
        XCTAssertEqual(
            lightMetadata.hdrStaticMetadata.contentLightLevelInfo,
            Data(lightBytes)
        )

        let unknownBuffer = try makePixelBuffer()
        setAttachment(unknownBuffer, key: kCVImageBufferColorPrimariesKey, value: "unknown" as CFString)
        setAttachment(unknownBuffer, key: kCVImageBufferTransferFunctionKey, value: "unknown" as CFString)
        setAttachment(unknownBuffer, key: kCVImageBufferYCbCrMatrixKey, value: "unknown" as CFString)
        let unknown = try read(unknownBuffer)
        XCTAssertEqual(unknown.primaries, .unknown)
        XCTAssertEqual(unknown.transfer, .unknown)
        XCTAssertEqual(unknown.matrix, .unknown)
    }

    func testPresentMalformedHDRStaticMetadataFailsClosed() throws {
        let malformedValues: [(CFString, CFTypeRef)] = [
            (kCVImageBufferMasteringDisplayColorVolumeKey, "not-data" as CFString),
            (kCVImageBufferMasteringDisplayColorVolumeKey, Data(repeating: 1, count: 23) as CFData),
            (kCVImageBufferContentLightLevelInfoKey, "not-data" as CFString),
            (kCVImageBufferContentLightLevelInfoKey, Data(repeating: 2, count: 5) as CFData),
        ]

        for (key, value) in malformedValues {
            let pixelBuffer = try makePixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            setAttachment(pixelBuffer, key: key, value: value)

            XCTAssertThrowsError(try VideoFormatMetadataReader.read(
                from: pixelBuffer,
                compatibilityCheck: { _, _ in true }
            )) { error in
                XCTAssertEqual(
                    error as? VideoDecoderFailure,
                    .malfunction(kCVReturnInvalidArgument),
                    "key: \(key), value: \(value)"
                )
            }
        }
    }

    private func read(_ pixelBuffer: CVPixelBuffer) throws -> VideoFormatMetadata {
        try VideoFormatMetadataReader.read(
            from: pixelBuffer,
            compatibilityCheck: { _, _ in true }
        )
    }

    private func makePixelBuffer(
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> CVPixelBuffer {
        try VideoTestFactories.pixelBuffer(
            pixelFormat: pixelFormat,
            width: 64,
            height: 32
        )
    }

    private func aspectDictionary(horizontal: CFTypeRef, vertical: CFTypeRef) -> CFDictionary {
        [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: horizontal,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: vertical,
        ] as CFDictionary
    }

    private func assertColorStringIsCopied(
        key: CFString,
        original: CFString,
        assertion: (VideoFormatMetadata) -> Void
    ) throws {
        let pixelBuffer = try makePixelBuffer()
        let mutable = try XCTUnwrap(CFStringCreateMutableCopy(kCFAllocatorDefault, 0, original))
        setAttachment(pixelBuffer, key: key, value: mutable)
        let metadata = try read(pixelBuffer)
        CFStringReplaceAll(mutable, "changed" as CFString)
        assertion(metadata)
    }

    private func replacingAspectRatio(
        in metadata: VideoFormatMetadata,
        with sampleAspectRatio: MediaRational?
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: metadata.dimensions,
            bitDepth: metadata.bitDepth,
            range: metadata.range,
            matrix: metadata.matrix,
            transfer: metadata.transfer,
            primaries: metadata.primaries,
            cleanAperture: metadata.cleanAperture,
            chromaLocation: metadata.chromaLocation,
            hdrStaticMetadata: metadata.hdrStaticMetadata,
            sampleAspectRatio: sampleAspectRatio
        )
    }

    private func mutableData(_ bytes: [UInt8]) throws -> CFMutableData {
        let data = try XCTUnwrap(CFDataCreateMutable(kCFAllocatorDefault, bytes.count))
        bytes.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                CFDataAppendBytes(data, baseAddress, bytes.count)
            }
        }
        return data
    }

    private func setAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        value: CFTypeRef
    ) {
        CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
    }
}
