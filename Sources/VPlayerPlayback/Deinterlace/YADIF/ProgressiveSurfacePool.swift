// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation

public final class ProgressiveSurfacePool: @unchecked Sendable {
    private enum RangeIdentity: Hashable {
        case video
        case full
    }

    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let range: RangeIdentity
    }

    private let lock = NSLock()
    private let recommendedAttributes: CVPixelBufferAttributes
    private var pools: [PoolKey: CVPixelBufferPool] = [:]

    public init(
        recommendedAttributes: CVPixelBufferAttributes = .init(rawAttributes: [:])
    ) {
        self.recommendedAttributes = recommendedAttributes
    }

    public func allocatePair(
        matching source: CVPixelBuffer
    ) throws(YADIFFailure) -> (first: CVPixelBuffer, second: CVPixelBuffer) {
        let description = YADIFSurfaceDescription(pixelBuffer: source)
        try YADIFSurfaceValidator.validate(description)
        let key = PoolKey(
            width: description.width,
            height: description.height,
            pixelFormat: description.pixelFormat,
            range: Self.rangeIdentity(for: description.pixelFormat)
        )
        let pool = try pool(for: key)
        let first = try allocate(from: pool)
        let second = try allocate(from: pool)
        try prepare(first, matching: source, expected: description)
        try prepare(second, matching: source, expected: description)
        return (first, second)
    }

    /// A single surface of a named geometry, for producers that have no source
    /// buffer to match — a software decoder writing its own output rather than
    /// the deinterlacer transforming one.
    public func allocate(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws(YADIFFailure) -> CVPixelBuffer {
        let key = PoolKey(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            range: Self.rangeIdentity(for: pixelFormat)
        )
        let output = try allocate(from: try pool(for: key))
        guard CVPixelBufferGetIOSurface(output) != nil else { throw .nonIOSurfaceOutput }
        try YADIFSurfaceValidator.validate(YADIFSurfaceDescription(pixelBuffer: output))
        return output
    }

    private func pool(for key: PoolKey) throws(YADIFFailure) -> CVPixelBufferPool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = pools[key] { return existing }

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 2,
        ]
        var mandatory = CVPixelBufferAttributes(
            pixelFormatTypes: [CVPixelFormatType(rawValue: key.pixelFormat)],
            size: CVImageSize(width: key.width, height: key.height),
            compatibility: [.metalTexture]
        )
        mandatory.backing = .ioSurfaceWithProperties([:])
        guard let resolved = CVPixelBufferAttributes(merging: [
            recommendedAttributes,
            mandatory,
        ]) else {
            throw YADIFFailure.incompatibleRendererAttributes
        }
        let pixelAttributes = resolved.rawAttributes.reduce(
            into: [CFString: Any]()
        ) { result, item in
            result[item.key as CFString] = item.value
        }
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else {
            throw .poolCreationFailed(status == kCVReturnSuccess ? kCVReturnError : status)
        }
        pools[key] = created
        return created
    }

    private func allocate(from pool: CVPixelBufferPool) throws(YADIFFailure) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw .poolAllocationFailed(status == kCVReturnSuccess ? kCVReturnError : status)
        }
        return pixelBuffer
    }

    private func prepare(
        _ output: CVPixelBuffer,
        matching source: CVPixelBuffer,
        expected: YADIFSurfaceDescription
    ) throws(YADIFFailure) {
        guard CVPixelBufferGetIOSurface(output) != nil else {
            throw .nonIOSurfaceOutput
        }
        let actual = YADIFSurfaceDescription(pixelBuffer: output)
        try YADIFSurfaceValidator.validate(actual)
        guard actual == expected else { throw .invalidPlaneLayout }

        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)
        CVBufferRemoveAttachment(output, kCVImageBufferFieldCountKey)
        CVBufferRemoveAttachment(output, kCVImageBufferFieldDetailKey)
        CVBufferSetAttachment(
            output,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 1),
            .shouldPropagate
        )
    }

    private static func rangeIdentity(for pixelFormat: OSType) -> RangeIdentity {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .full
        default:
            return .video
        }
    }
}
