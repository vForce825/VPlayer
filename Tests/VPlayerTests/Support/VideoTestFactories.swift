// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import VPlayerPlayback

private let legacyTestVideoDecoderTransitionToken = VideoDecoderTransitionToken()

enum VideoTestFactories {
    static let width = 64
    static let height = 36

    static func metadata(
        width: Int32 = 64,
        height: Int32 = 36,
        bitDepth: Int = 8,
        range: VideoFormatMetadata.Range = .video,
        matrix: VideoFormatMetadata.Matrix = .bt709,
        transfer: VideoFormatMetadata.Transfer = .bt709,
        primaries: VideoFormatMetadata.Primaries = .bt709
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: .init(width: width, height: height),
            bitDepth: bitDepth,
            range: range,
            matrix: matrix,
            transfer: transfer,
            primaries: primaries,
            cleanAperture: nil,
            chromaLocation: .init(topField: nil, bottomField: nil),
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: nil
            )
        )
    }

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

    static func pixelBuffer(
        pixelFormat: OSType,
        width: Int = VideoTestFactories.width,
        height: Int = VideoTestFactories.height,
        packedBytes: Data? = nil,
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
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FactoryError.pixelBuffer(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let packedBytes {
            try writePacked(packedBytes, to: pixelBuffer)
        } else {
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

    static func movingFieldBuffers(
        pixelFormat: OSType,
        parity: FieldParity,
        count: Int
    ) throws -> [CVPixelBuffer] {
        let stem = parity == .top ? "tff" : "bff"
        let format = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ? "p010" : "nv12"
        let fixture = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/Video/yadif-\(format)-\(stem)-input.bin"
        ))
        let storedComponentBytes = format == "p010" ? 2 : 1
        let bytesPerFrame = width * height * 3 / 2 * storedComponentBytes
        guard fixture.count == bytesPerFrame * 5 else {
            throw FactoryError.invalidFixtureByteCount(fixture.count)
        }

        return try (0..<count).map { frameIndex in
            let fixtureIndex = frameIndex % 5
            let start = fixtureIndex * bytesPerFrame
            var bytes = fixture.subdata(in: start..<(start + bytesPerFrame))
            applyDeterministicCycleMarker(
                to: &bytes,
                cycle: frameIndex / 5,
                storedComponentBytes: storedComponentBytes
            )
            return try pixelBuffer(pixelFormat: pixelFormat, packedBytes: bytes)
        }
    }

    static func decodedFrame(
        id: UInt64,
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        parserMetadata: VideoParserMetadata,
        formatMetadata: VideoFormatMetadata? = nil
    ) -> DecodedVideoFrame {
        DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            generation: generation,
            parserMetadata: parserMetadata,
            formatMetadata: formatMetadata ?? metadata(
                width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                height: Int32(CVPixelBufferGetHeight(pixelBuffer)),
                bitDepth: CVPixelBufferGetPixelFormatType(pixelBuffer)
                    == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 10 : 8
            )
        )
    }

    static func formatDescription(
        codecType: CMVideoCodecType = kCMVideoCodecType_H264,
        width: Int32 = 64,
        height: Int32 = 36,
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
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw FactoryError.formatDescription(status)
        }
        return formatDescription
    }

    private static func writePacked(
        _ bytes: Data,
        to pixelBuffer: CVPixelBuffer
    ) throws {
        let componentBytes = CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
        let expectedCount = CVPixelBufferGetWidth(pixelBuffer)
            * CVPixelBufferGetHeight(pixelBuffer) * 3 / 2 * componentBytes
        guard bytes.count == expectedCount else {
            throw FactoryError.invalidFixtureByteCount(bytes.count)
        }
        try bytes.withUnsafeBytes { rawBytes in
            guard let source = rawBytes.baseAddress else {
                throw FactoryError.invalidFixtureByteCount(0)
            }
            var sourceOffset = 0
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    throw FactoryError.missingPlane(plane)
                }
                let componentCount = plane == 0 ? 1 : 2
                let rowByteCount = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                    * componentCount * componentBytes
                let rowCount = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                for row in 0..<rowCount {
                    memcpy(
                        destination.advanced(by: row * destinationStride),
                        source.advanced(by: sourceOffset + row * rowByteCount),
                        rowByteCount
                    )
                }
                sourceOffset += rowByteCount * rowCount
            }
        }
    }

    private static func applyDeterministicCycleMarker(
        to bytes: inout Data,
        cycle: Int,
        storedComponentBytes: Int
    ) {
        guard cycle > 0 else { return }
        let lumaByteCount = width * height * storedComponentBytes
        if storedComponentBytes == 1 {
            for index in 0..<lumaByteCount {
                bytes[index] = UInt8(16 + (Int(bytes[index]) - 16 + cycle * 17) % 220)
            }
            return
        }
        for index in stride(from: 0, to: lumaByteCount, by: 2) {
            let stored = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let code = Int(stored >> 6)
            let marked = UInt16(64 + (code - 64 + cycle * 67) % 876) << 6
            bytes[index] = UInt8(truncatingIfNeeded: marked)
            bytes[index + 1] = UInt8(truncatingIfNeeded: marked >> 8)
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum FactoryError: Error {
    case pixelBuffer(CVReturn)
    case missingPlane(Int)
    case formatDescription(OSStatus)
    case invalidFixtureByteCount(Int)
}

// Convenience for tests whose behavior predates decoder-session fencing. New
// transition/routing tests pass a stable identity explicitly.
extension VideoDecoderEvent {
    static func frame(_ frame: DecodedVideoFrame) -> Self {
        .frame(frame, identity: testIdentity(generation: frame.generation))
    }

    static func recoverableFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) -> Self {
        .recoverableFailure(failure, identity: testIdentity(generation: generation))
    }

    static func fatalFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) -> Self {
        .fatalFailure(failure, identity: testIdentity(generation: generation))
    }

    static func submissionFailure(
        _ failure: VideoDecoderFailure,
        accessUnitID: UInt64 = 0,
        generation: MediaGeneration
    ) -> Self {
        .submissionFailure(
            accessUnitID: accessUnitID,
            failure: failure,
            identity: testIdentity(generation: generation)
        )
    }

    static func submissionCompleted(
        accessUnitID: UInt64,
        generation: MediaGeneration
    ) -> Self {
        .submissionCompleted(
            accessUnitID: accessUnitID,
            identity: testIdentity(generation: generation),
            disposition: .cancelled
        )
    }

    private static func testIdentity(
        generation: MediaGeneration
    ) -> VideoDecoderEventIdentity {
        VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: legacyTestVideoDecoderTransitionToken
        )
    }
}
