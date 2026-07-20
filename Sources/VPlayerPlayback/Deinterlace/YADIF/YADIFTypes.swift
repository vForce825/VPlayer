// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
import Metal

public struct YADIFJob: @unchecked Sendable {
    public let previous: NormalizedDecodedFrame
    public let current: NormalizedDecodedFrame
    public let next: NormalizedDecodedFrame
    public let order: ResolvedFieldOrder
    public let spatialOnly: Bool

    public init(
        previous: NormalizedDecodedFrame,
        current: NormalizedDecodedFrame,
        next: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        spatialOnly: Bool
    ) {
        self.previous = previous
        self.current = current
        self.next = next
        self.order = order
        self.spatialOnly = spatialOnly
    }
}

public enum YADIFFailure: Error, Equatable, Sendable {
    case invalidDimensions
    case unsupportedPixelFormat(OSType)
    case poolCreationFailed(CVReturn)
    case poolAllocationFailed(CVReturn)
    case nonIOSurfaceOutput
    case invalidPlaneLayout
    case metalTextureCacheCreationFailed(CVReturn)
    case metalTextureMappingFailed(plane: Int, status: CVReturn)
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed
    case commandEncoderAllocationFailed
}

struct YADIFSurfaceDescription: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let planeCount: Int
    let lumaWidth: Int
    let lumaHeight: Int
    let chromaWidth: Int
    let chromaHeight: Int

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        planeCount: Int,
        lumaWidth: Int,
        lumaHeight: Int,
        chromaWidth: Int,
        chromaHeight: Int
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.planeCount = planeCount
        self.lumaWidth = lumaWidth
        self.lumaHeight = lumaHeight
        self.chromaWidth = chromaWidth
        self.chromaHeight = chromaHeight
    }

    init(pixelBuffer: CVPixelBuffer) {
        self.init(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            planeCount: CVPixelBufferGetPlaneCount(pixelBuffer),
            lumaWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            lumaHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            chromaWidth: CVPixelBufferGetPlaneCount(pixelBuffer) > 1
                ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) : 0,
            chromaHeight: CVPixelBufferGetPlaneCount(pixelBuffer) > 1
                ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) : 0
        )
    }
}

enum YADIFSurfaceValidator {
    static let supportedPixelFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    static func validate(
        _ description: YADIFSurfaceDescription
    ) throws(YADIFFailure) {
        guard supportedPixelFormats.contains(description.pixelFormat) else {
            throw .unsupportedPixelFormat(description.pixelFormat)
        }
        guard description.width >= 2,
              description.height >= 4,
              description.width.isMultiple(of: 2),
              description.height.isMultiple(of: 2) else {
            throw .invalidDimensions
        }
        guard description.planeCount == 2,
              description.lumaWidth == description.width,
              description.lumaHeight == description.height,
              description.chromaWidth == description.width / 2,
              description.chromaHeight == description.height / 2 else {
            throw .invalidPlaneLayout
        }
    }
}

struct YADIFMappedTextures: @unchecked Sendable {
    let luma: any MTLTexture
    let chroma: any MTLTexture
    let wrappers: [CVMetalTexture]
}

typealias YADIFTextureCacheFactory = (
    _ device: any MTLDevice
) -> (status: CVReturn, cache: CVMetalTextureCache?)

typealias YADIFTextureFactory = (
    _ cache: CVMetalTextureCache,
    _ pixelBuffer: CVPixelBuffer,
    _ pixelFormat: MTLPixelFormat,
    _ width: Int,
    _ height: Int,
    _ plane: Int
) -> (status: CVReturn, texture: CVMetalTexture?)

final class YADIFTextureMapper: @unchecked Sendable {
    private let cache: CVMetalTextureCache
    private let textureFactory: YADIFTextureFactory

    init(
        device: any MTLDevice,
        cacheFactory: YADIFTextureCacheFactory? = nil,
        textureFactory: YADIFTextureFactory? = nil
    ) throws(YADIFFailure) {
        let cacheResult: (status: CVReturn, cache: CVMetalTextureCache?)
        if let cacheFactory {
            cacheResult = cacheFactory(device)
        } else {
            var created: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &created)
            cacheResult = (status, created)
        }
        guard cacheResult.status == kCVReturnSuccess, let cache = cacheResult.cache else {
            throw .metalTextureCacheCreationFailed(
                cacheResult.status == kCVReturnSuccess ? kCVReturnError : cacheResult.status
            )
        }
        self.cache = cache
        self.textureFactory = textureFactory ?? Self.makeTexture
    }

    func map(_ pixelBuffer: CVPixelBuffer) throws(YADIFFailure) -> YADIFMappedTextures {
        let description = YADIFSurfaceDescription(pixelBuffer: pixelBuffer)
        try YADIFSurfaceValidator.validate(description)
        guard description.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || description.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw .unsupportedPixelFormat(description.pixelFormat)
        }

        let luma = try mapPlane(
            pixelBuffer,
            plane: 0,
            format: .r8Unorm,
            width: description.lumaWidth,
            height: description.lumaHeight
        )
        let chroma = try mapPlane(
            pixelBuffer,
            plane: 1,
            format: .rg8Unorm,
            width: description.chromaWidth,
            height: description.chromaHeight
        )
        return YADIFMappedTextures(
            luma: luma.texture,
            chroma: chroma.texture,
            wrappers: [luma.wrapper, chroma.wrapper]
        )
    }

    private func mapPlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws(YADIFFailure) -> (wrapper: CVMetalTexture, texture: any MTLTexture) {
        let result = textureFactory(cache, pixelBuffer, format, width, height, plane)
        guard result.status == kCVReturnSuccess,
              let wrapper = result.texture,
              let texture = CVMetalTextureGetTexture(wrapper) else {
            throw .metalTextureMappingFailed(
                plane: plane,
                status: result.status == kCVReturnSuccess ? kCVReturnError : result.status
            )
        }
        return (wrapper, texture)
    }

    private static func makeTexture(
        cache: CVMetalTextureCache,
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int
    ) -> (status: CVReturn, texture: CVMetalTexture?) {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, pixelFormat, width, height, plane, &texture
        )
        return (status, texture)
    }
}

typealias YADIFLibraryFactory = (
    _ device: any MTLDevice,
    _ bundle: Bundle
) throws -> (any MTLLibrary)?

typealias YADIFPipelineFactory = (
    _ device: any MTLDevice,
    _ function: any MTLFunction
) throws -> any MTLComputePipelineState

typealias YADIFEncoderFactory = (
    _ commandBuffer: any MTLCommandBuffer
) -> (any MTLComputeCommandEncoder)?

final class YADIFEncodedResources: @unchecked Sendable {
    private let textureMapper: YADIFTextureMapper
    private let job: YADIFJob
    private let outputs: (CVPixelBuffer, CVPixelBuffer)
    private let mappings: [YADIFMappedTextures]

    init(
        textureMapper: YADIFTextureMapper,
        job: YADIFJob,
        outputs: (CVPixelBuffer, CVPixelBuffer),
        mappings: [YADIFMappedTextures]
    ) {
        self.textureMapper = textureMapper
        self.job = job
        self.outputs = outputs
        self.mappings = mappings
    }
}

private struct YADIFKernelUniforms {
    var outputIndex: UInt32
    var topFieldFirst: UInt32
    var spatialOnly: UInt32
    var componentCount: UInt32
}

final class YADIFNV12Kernel: @unchecked Sendable {
    private final class ShaderBundleToken {}
    private static let shaderBundle = Bundle(for: ShaderBundleToken.self)

    private let mapper: YADIFTextureMapper
    private let pipeline: any MTLComputePipelineState
    private let encoderFactory: YADIFEncoderFactory

    init(
        device: any MTLDevice,
        textureMapper: YADIFTextureMapper? = nil,
        functionName: String = "yadifPlane8",
        libraryFactory: YADIFLibraryFactory? = nil,
        pipelineFactory: YADIFPipelineFactory? = nil,
        encoderFactory: YADIFEncoderFactory? = nil
    ) throws(YADIFFailure) {
        if let textureMapper {
            mapper = textureMapper
        } else {
            mapper = try YADIFTextureMapper(device: device)
        }

        let library: (any MTLLibrary)?
        do {
            if let libraryFactory {
                library = try libraryFactory(device, Self.shaderBundle)
            } else {
                library = try device.makeDefaultLibrary(bundle: Self.shaderBundle)
            }
        } catch {
            throw .shaderLibraryUnavailable
        }
        guard let library else { throw .shaderLibraryUnavailable }
        guard let function = library.makeFunction(name: functionName) else {
            throw .shaderFunctionUnavailable(functionName)
        }
        do {
            if let pipelineFactory {
                pipeline = try pipelineFactory(device, function)
            } else {
                pipeline = try device.makeComputePipelineState(function: function)
            }
        } catch {
            throw .pipelineCreationFailed
        }
        self.encoderFactory = encoderFactory ?? { $0.makeComputeCommandEncoder() }
    }

    func encode(
        _ job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        into commandBuffer: any MTLCommandBuffer
    ) throws(YADIFFailure) -> YADIFEncodedResources {
        let buffers = [
            job.previous.frame.pixelBuffer,
            job.current.frame.pixelBuffer,
            job.next.frame.pixelBuffer,
            outputs.first,
            outputs.second,
        ]
        let descriptions = buffers.map(YADIFSurfaceDescription.init(pixelBuffer:))
        for description in descriptions { try YADIFSurfaceValidator.validate(description) }
        guard descriptions.dropFirst().allSatisfy({ $0 == descriptions[0] }) else {
            throw .invalidDimensions
        }
        var mappings: [YADIFMappedTextures] = []
        mappings.reserveCapacity(buffers.count)
        for buffer in buffers {
            mappings.append(try mapper.map(buffer))
        }
        guard let encoder = encoderFactory(commandBuffer) else {
            throw .commandEncoderAllocationFailed
        }
        encoder.setComputePipelineState(pipeline)

        for outputIndex in 0..<2 {
            let output = mappings[3 + outputIndex]
            for plane in 0..<2 {
                let previous = plane == 0 ? mappings[0].luma : mappings[0].chroma
                let current = plane == 0 ? mappings[1].luma : mappings[1].chroma
                let next = plane == 0 ? mappings[2].luma : mappings[2].chroma
                let destination = plane == 0 ? output.luma : output.chroma
                encoder.setTexture(previous, index: 0)
                encoder.setTexture(current, index: 1)
                encoder.setTexture(next, index: 2)
                encoder.setTexture(destination, index: 3)
                var uniforms = YADIFKernelUniforms(
                    outputIndex: UInt32(outputIndex),
                    topFieldFirst: job.order.parity == .top ? 1 : 0,
                    spatialOnly: job.spatialOnly ? 1 : 0,
                    componentCount: plane == 0 ? 1 : 2
                )
                encoder.setBytes(
                    &uniforms,
                    length: MemoryLayout<YADIFKernelUniforms>.stride,
                    index: 0
                )
                let threadWidth = max(1, min(destination.width, pipeline.threadExecutionWidth))
                let threadHeight = max(
                    1,
                    min(destination.height, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
                )
                encoder.dispatchThreads(
                    MTLSize(width: destination.width, height: destination.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: threadWidth,
                        height: threadHeight,
                        depth: 1
                    )
                )
            }
        }
        encoder.endEncoding()
        return YADIFEncodedResources(
            textureMapper: mapper,
            job: job,
            outputs: (outputs.first, outputs.second),
            mappings: mappings
        )
    }
}
