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
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            bitDepth = 10
            range = .full
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
                masteringDisplayColorVolume: try dataAttachment(
                    kCVImageBufferMasteringDisplayColorVolumeKey,
                    expectedLength: 24,
                    pixelBuffer: pixelBuffer
                ),
                contentLightLevelInfo: try dataAttachment(
                    kCVImageBufferContentLightLevelInfoKey,
                    expectedLength: 4,
                    pixelBuffer: pixelBuffer
                )
            ),
            sampleAspectRatio: try sampleAspectRatio(from: pixelBuffer)
        )
    }

    private static func sampleAspectRatio(
        from pixelBuffer: CVPixelBuffer
    ) throws -> MediaRational? {
        guard let copied = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) else {
            return nil
        }
        guard CFGetTypeID(copied) == CFDictionaryGetTypeID(),
              let dictionary = copied as? [String: Any] else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
        }
        let horizontal = try positiveSpacing(
            dictionary[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String]
        )
        let vertical = try positiveSpacing(
            dictionary[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String]
        )
        guard let ratio = MediaRational(num: horizontal, den: vertical) else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
        }
        return ratio
    }

    /// CoreVideo 把像素宽高比声明为整数 CFNumber。先按值验证精确 Int64，
    /// 再收窄到协议使用的 Int32，避免浮点截断或溢出被静默接纳。
    private static func positiveSpacing(_ rawValue: Any?) throws -> Int32 {
        guard let rawValue else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
        }
        let object = rawValue as AnyObject
        guard CFGetTypeID(object) == CFNumberGetTypeID(),
              let number = object as? NSNumber else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
        }
        let signedValue = number.int64Value
        guard number.compare(NSNumber(value: signedValue)) == .orderedSame,
              signedValue > 0,
              let spacing = Int32(exactly: signedValue) else {
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
        }
        return spacing
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
    ) throws -> Data? {
        guard let copied = CVBufferCopyAttachment(pixelBuffer, key, nil) else {
            return nil
        }
        guard CFGetTypeID(copied) == CFDataGetTypeID(),
              let data = copied as? Data,
              data.count == expectedLength else {
            // 显式存在但形状错误不能与“没有该附件”混为一谈，否则 HDR 会静默丢失。
            throw VideoDecoderFailure.malfunction(kCVReturnInvalidArgument)
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
