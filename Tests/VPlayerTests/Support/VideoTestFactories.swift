// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation

enum VideoTestFactories {
    static func nv12(
        width: Int = 64,
        height: Int = 36,
        fieldCount: CFTypeRef? = nil,
        detail: CFTypeRef? = nil
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FactoryError.pixelBuffer(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw FactoryError.missingPlane(plane)
            }
            memset(
                baseAddress,
                0,
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                    * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            )
        }

        if let fieldCount {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferFieldCountKey,
                fieldCount,
                .shouldPropagate
            )
        }
        if let detail {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferFieldDetailKey,
                detail,
                .shouldPropagate
            )
        }
        return pixelBuffer
    }

    static func formatDescription(
        fieldCount: CFTypeRef? = nil,
        detail: CFTypeRef? = nil
    ) throws -> CMVideoFormatDescription {
        var extensions: [String: Any] = [:]
        if let fieldCount {
            extensions[kCVImageBufferFieldCountKey as String] = fieldCount
        }
        if let detail {
            extensions[kCVImageBufferFieldDetailKey as String] = detail
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 64,
            height: 36,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw FactoryError.formatDescription(status)
        }
        return formatDescription
    }
}

private enum FactoryError: Error {
    case pixelBuffer(CVReturn)
    case missingPlane(Int)
    case formatDescription(OSStatus)
}
