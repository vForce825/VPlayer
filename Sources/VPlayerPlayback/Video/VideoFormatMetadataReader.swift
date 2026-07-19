// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

typealias PixelBufferCompatibilityCheck = @Sendable (CVPixelBuffer, CFDictionary) -> Bool

enum VideoFormatMetadataReader {
    static let systemCompatibilityCheck: PixelBufferCompatibilityCheck = { pixelBuffer, attributes in
        CVPixelBufferIsCompatibleWithAttributes(pixelBuffer, attributes)
    }

    static func read(
        from pixelBuffer: CVPixelBuffer,
        compatibilityCheck: PixelBufferCompatibilityCheck = systemCompatibilityCheck
    ) throws -> VideoFormatMetadata {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bitDepth: Int
        let range: VideoFormatMetadata.Range
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            bitDepth = 8
            range = .video
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            bitDepth = 8
            range = .full
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            bitDepth = 10
            range = .video
        default:
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidPixelFormat)
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidPixelFormat)
        }
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw VideoDecoderFailure.malfunction(kCVReturnPixelBufferNotMetalCompatible)
        }
        let compatibilityAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard compatibilityCheck(
            pixelBuffer,
            compatibilityAttributes as CFDictionary
        ) else {
            throw VideoDecoderFailure.malfunction(kCVReturnPixelBufferNotMetalCompatible)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0,
              height > 0,
              let width32 = Int32(exactly: width),
              let height32 = Int32(exactly: height) else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidSize)
        }

        return VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: width32, height: height32),
            bitDepth: bitDepth,
            range: range,
            matrix: matrix(from: stringAttachment(
                kCVImageBufferYCbCrMatrixKey,
                pixelBuffer: pixelBuffer
            )),
            transfer: transfer(from: stringAttachment(
                kCVImageBufferTransferFunctionKey,
                pixelBuffer: pixelBuffer
            )),
            primaries: primaries(from: stringAttachment(
                kCVImageBufferColorPrimariesKey,
                pixelBuffer: pixelBuffer
            )),
            cleanAperture: cleanAperture(from: pixelBuffer),
            chromaLocation: VideoFormatMetadata.ChromaLocation(
                topField: stringAttachment(
                    kCVImageBufferChromaLocationTopFieldKey,
                    pixelBuffer: pixelBuffer
                ),
                bottomField: stringAttachment(
                    kCVImageBufferChromaLocationBottomFieldKey,
                    pixelBuffer: pixelBuffer
                )
            ),
            hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata(
                masteringDisplayColorVolume: dataAttachment(
                    kCVImageBufferMasteringDisplayColorVolumeKey,
                    expectedLength: 24,
                    pixelBuffer: pixelBuffer
                ),
                contentLightLevelInfo: dataAttachment(
                    kCVImageBufferContentLightLevelInfoKey,
                    expectedLength: 4,
                    pixelBuffer: pixelBuffer
                )
            )
        )
    }

    private static func stringAttachment(
        _ key: CFString,
        pixelBuffer: CVPixelBuffer
    ) -> String? {
        guard let copied = CVBufferCopyAttachment(pixelBuffer, key, nil),
              CFGetTypeID(copied) == CFStringGetTypeID(),
              let string = copied as? String else {
            return nil
        }
        return String(string)
    }

    private static func dataAttachment(
        _ key: CFString,
        expectedLength: Int,
        pixelBuffer: CVPixelBuffer
    ) -> Data? {
        guard let copied = CVBufferCopyAttachment(pixelBuffer, key, nil),
              CFGetTypeID(copied) == CFDataGetTypeID(),
              let data = copied as? Data,
              data.count == expectedLength else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            Data(bytes)
        }
    }

    private static func cleanAperture(from pixelBuffer: CVPixelBuffer) -> CGRect? {
        guard let copied = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferCleanApertureKey,
            nil
        ), CFGetTypeID(copied) == CFDictionaryGetTypeID() else {
            return nil
        }
        return CVImageBufferGetCleanRect(pixelBuffer)
    }

    private static func primaries(from value: String?) -> VideoFormatMetadata.Primaries {
        if value == kCVImageBufferColorPrimaries_ITU_R_709_2 as String {
            return .bt709
        }
        if value == kCVImageBufferColorPrimaries_ITU_R_2020 as String {
            return .bt2020
        }
        return .unknown
    }

    private static func matrix(from value: String?) -> VideoFormatMetadata.Matrix {
        if value == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            return .bt601
        }
        if value == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            return .bt709
        }
        if value == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            return .bt2020
        }
        if value == "Identity" {
            return .identity
        }
        return .unknown
    }

    private static func transfer(from value: String?) -> VideoFormatMetadata.Transfer {
        if value == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            || value == kCVImageBufferTransferFunction_ITU_R_2020 as String {
            return .bt709
        }
        if value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return .pq
        }
        if value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return .hlg
        }
        if value == kCVImageBufferTransferFunction_Linear as String {
            return .linear
        }
        return .unknown
    }
}
