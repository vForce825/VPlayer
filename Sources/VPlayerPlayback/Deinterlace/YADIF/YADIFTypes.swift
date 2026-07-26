// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
import Metal

protocol YADIFCommandSubmitting: AnyObject, Sendable {
    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandCompletion) -> Void
    ) throws(YADIFFailure)
}

enum YADIFCommandResult: Sendable, Equatable {
    case completed
    case completedWithGPUInterval(MetalGPUInterval)
    case failed
}

struct YADIFOutputPlaneSets: @unchecked Sendable {
    let first: MetalPlaneSet
    let second: MetalPlaneSet
}

struct YADIFCommandCompletion: @unchecked Sendable {
    let result: YADIFCommandResult
    let outputPlanes: YADIFOutputPlaneSets?
}

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
    case commandBufferAllocationFailed
    case commandEncoderAllocationFailed
    case commandFailed
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
        textureCache: CVMetalTextureCache? = nil,
        cacheFactory: YADIFTextureCacheFactory? = nil,
        textureFactory: YADIFTextureFactory? = nil
    ) throws(YADIFFailure) {
        if let textureCache {
            cache = textureCache
            self.textureFactory = textureFactory ?? Self.makeTexture
            return
        }
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
        let planeFormats: (luma: MTLPixelFormat, chroma: MTLPixelFormat)
        switch description.pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planeFormats = (.r8Uint, .rg8Uint)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            planeFormats = (.r16Uint, .rg16Uint)
        default:
            throw .unsupportedPixelFormat(description.pixelFormat)
        }

        let luma = try mapPlane(
            pixelBuffer,
            plane: 0,
            format: planeFormats.luma,
            width: description.lumaWidth,
            height: description.lumaHeight
        )
        let chroma = try mapPlane(
            pixelBuffer,
            plane: 1,
            format: planeFormats.chroma,
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

    func makeOutputPlaneSets() -> YADIFOutputPlaneSets? {
        let presentationFormats: (luma: MTLPixelFormat, chroma: MTLPixelFormat)
        switch CVPixelBufferGetPixelFormatType(outputs.0) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            presentationFormats = (.r8Unorm, .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            presentationFormats = (.r16Unorm, .rg16Unorm)
        default:
            return nil
        }

        func planeSet(
            mapping: YADIFMappedTextures,
            pixelBuffer: CVPixelBuffer
        ) -> MetalPlaneSet? {
            guard let luma = mapping.luma.makeTextureView(
                pixelFormat: presentationFormats.luma
            ), let chroma = mapping.chroma.makeTextureView(
                pixelFormat: presentationFormats.chroma
            ) else { return nil }
            return MetalPlaneSet(
                luma: luma,
                chroma: chroma,
                retainedObjects: [
                    pixelBuffer as AnyObject,
                    textureMapper,
                    mapping.luma as AnyObject,
                    mapping.chroma as AnyObject,
                ] + mapping.wrappers.map { $0 as AnyObject }
            )
        }
        guard let first = planeSet(mapping: mappings[3], pixelBuffer: outputs.0),
              let second = planeSet(mapping: mappings[4], pixelBuffer: outputs.1) else {
            return nil
        }
        return YADIFOutputPlaneSets(first: first, second: second)
    }
}

private struct YADIFKernelUniforms {
    var outputIndex: UInt32
    var topFieldFirst: UInt32
    var spatialOnly: UInt32
}

struct YADIFThreadgroupLayout {
    static let maximumTileHeight = 8
    static let horizontalHalo = 3

    let threads: MTLSize
    let memoryLength: Int

    static func make(
        destinationWidth: Int,
        rowPairCount: Int,
        threadExecutionWidth: Int,
        maxTotalThreadsPerThreadgroup: Int,
        bytesPerCode: Int,
        maximumDynamicMemoryLength: Int
    ) -> YADIFThreadgroupLayout {
        let width = max(1, min(destinationWidth, threadExecutionWidth))
        let maximumHeightByThreads = max(1, maxTotalThreadsPerThreadgroup / width)
        let bytesPerRowPair = 2 * (width + 2 * horizontalHalo) * bytesPerCode
        let maximumHeightByMemory = max(1, maximumDynamicMemoryLength / bytesPerRowPair)
        let height = max(
            1,
            min(
                rowPairCount,
                maximumTileHeight,
                maximumHeightByThreads,
                maximumHeightByMemory
            )
        )
        let rawMemoryLength = bytesPerRowPair * height
        return YADIFThreadgroupLayout(
            threads: MTLSize(width: width, height: height, depth: 1),
            memoryLength: (rawMemoryLength + 15) & ~15
        )
    }
}

final class YADIFNV12Kernel: @unchecked Sendable {
    private final class ShaderBundleToken {}
    private static let shaderBundle = Bundle(for: ShaderBundleToken.self)

    private let mapper: YADIFTextureMapper
    private let lumaPipeline8: any MTLComputePipelineState
    private let lumaPipeline16: any MTLComputePipelineState
    private let chromaPipeline8: any MTLComputePipelineState
    private let chromaPipeline16: any MTLComputePipelineState
    private let encoderFactory: YADIFEncoderFactory
    private let maximumThreadgroupMemoryLength: Int

    init(
        device: any MTLDevice,
        textureMapper: YADIFTextureMapper? = nil,
        functionName: String = "yadifPlane8",
        p010FunctionName: String = "yadifPlane16",
        chromaFunctionName: String = "yadifChroma8",
        p010ChromaFunctionName: String = "yadifChroma16",
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
        func makePipeline(
            named name: String
        ) throws(YADIFFailure) -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw .shaderFunctionUnavailable(name)
            }
            do {
                if let pipelineFactory {
                    return try pipelineFactory(device, function)
                }
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw .pipelineCreationFailed
            }
        }
        lumaPipeline8 = try makePipeline(named: functionName)
        lumaPipeline16 = try makePipeline(named: p010FunctionName)
        chromaPipeline8 = try makePipeline(named: chromaFunctionName)
        chromaPipeline16 = try makePipeline(named: p010ChromaFunctionName)
        maximumThreadgroupMemoryLength = device.maxThreadgroupMemoryLength
        // The four dispatches write four disjoint planes and share only
        // read-only inputs, so serialising them buys nothing and costs a drain
        // to one thread at the tail of each.
        self.encoderFactory = encoderFactory ?? {
            $0.makeComputeCommandEncoder(dispatchType: .concurrent)
        }
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
        let planePipelines: (
            luma: any MTLComputePipelineState,
            chroma: any MTLComputePipelineState
        )
        switch descriptions[0].pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planePipelines = (lumaPipeline8, chromaPipeline8)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            planePipelines = (lumaPipeline16, chromaPipeline16)
        default:
            throw .unsupportedPixelFormat(descriptions[0].pixelFormat)
        }
        var mappings: [YADIFMappedTextures] = []
        mappings.reserveCapacity(buffers.count)
        for buffer in buffers {
            mappings.append(try mapper.map(buffer))
        }
        guard let encoder = encoderFactory(commandBuffer) else {
            throw .commandEncoderAllocationFailed
        }

        for outputIndex in 0..<2 {
            let output = mappings[3 + outputIndex]
            for plane in 0..<2 {
                let pipeline = plane == 0 ? planePipelines.luma : planePipelines.chroma
                let previous = plane == 0 ? mappings[0].luma : mappings[0].chroma
                let current = plane == 0 ? mappings[1].luma : mappings[1].chroma
                let next = plane == 0 ? mappings[2].luma : mappings[2].chroma
                let destination = plane == 0 ? output.luma : output.chroma
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(previous, index: 0)
                encoder.setTexture(current, index: 1)
                encoder.setTexture(next, index: 2)
                encoder.setTexture(destination, index: 3)
                // One thread per row pair. An odd plane height leaves a single
                // trailing row, which the last pair covers and the kernel bounds.
                let rowPairCount = (destination.height + 1) / 2
                let layout = YADIFThreadgroupLayout.make(
                    destinationWidth: destination.width,
                    rowPairCount: rowPairCount,
                    threadExecutionWidth: pipeline.threadExecutionWidth,
                    maxTotalThreadsPerThreadgroup: pipeline.maxTotalThreadsPerThreadgroup,
                    bytesPerCode: plane == 0
                        ? MemoryLayout<Int32>.stride
                        : MemoryLayout<SIMD2<Int32>>.stride,
                    maximumDynamicMemoryLength: max(
                        0,
                        maximumThreadgroupMemoryLength - pipeline.staticThreadgroupMemoryLength
                    )
                )
                var uniforms = YADIFKernelUniforms(
                    outputIndex: UInt32(outputIndex),
                    topFieldFirst: job.order.parity == .top ? 1 : 0,
                    spatialOnly: job.spatialOnly ? 1 : 0
                )
                encoder.setBytes(
                    &uniforms,
                    length: MemoryLayout<YADIFKernelUniforms>.stride,
                    index: 0
                )
                encoder.setThreadgroupMemoryLength(layout.memoryLength, index: 0)
                encoder.dispatchThreadgroups(
                    MTLSize(
                        width: (destination.width + layout.threads.width - 1)
                            / layout.threads.width,
                        height: (rowPairCount + layout.threads.height - 1)
                            / layout.threads.height,
                        depth: 1
                    ),
                    threadsPerThreadgroup: layout.threads
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
