// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

struct VideoTexturePlaneRequest: Equatable {
    let planeIndex: Int
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
}

struct MappedVideoTextures: @unchecked Sendable {
    let luma: any MTLTexture
    let chroma: any MTLTexture
    let retainedObjects: [AnyObject]
}

protocol VideoTextureMapping: AnyObject, Sendable {
    func map(
        pixelBuffer: CVPixelBuffer,
        requests: [VideoTexturePlaneRequest]
    ) throws -> MappedVideoTextures
    func flush()
}

enum MetalCommandCompletion: Sendable, Equatable {
    case succeeded
    case failed(String)
}

struct MetalRenderJob: @unchecked Sendable {
    let luma: any MTLTexture
    let chroma: any MTLTexture
    let uniforms: MetalGPUUniforms
    let outputConfiguration: MetalOutputConfiguration
    let displayInterval: CMTime
}

protocol MetalCommandSubmitting: AnyObject, Sendable {
    func submitPresentingUntimed(
        _ job: MetalRenderJob,
        drawable: any CAMetalDrawable,
        completion: @escaping @Sendable (MetalCommandCompletion) -> Void
    ) throws
}

struct MetalYUVUniforms: Sendable, Equatable {
    let yOffset: Float
    let yScale: Float
    let chromaOffset: Float
    let chromaScale: Float
    let sampleNormalization: Float
    let yuvToRGB: simd_float3x3
    let gamut709To2020: simd_float3x3
    let transfer: VideoFormatMetadata.Transfer
    let matrixKind: VideoFormatMetadata.Matrix
    let primaries: VideoFormatMetadata.Primaries

    func referenceRGB(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        let normalizedY = max(0, (y * sampleNormalization - yOffset) * yScale)
        let normalizedCb = (cb * sampleNormalization - chromaOffset) * chromaScale
        let normalizedCr = (cr * sampleNormalization - chromaOffset) * chromaScale
        return simd_clamp(
            yuvToRGB * SIMD3<Float>(normalizedY, normalizedCb, normalizedCr),
            SIMD3<Float>(repeating: 0),
            SIMD3<Float>(repeating: 1)
        )
    }

    func referenceLinearOutput(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        var rgb = referenceRGB(y: y, cb: cb, cr: cr)
        switch transfer {
        case .linear:
            break
        case .bt709, .unknown:
            rgb = map(rgb) {
                $0 < 0.081 ? $0 / 4.5 : pow(($0 + 0.099) / 1.099, 1 / 0.45)
            }
        case .pq:
            let m1: Float = 2_610 / 16_384
            let m2: Float = 2_523 / 32
            let c1: Float = 3_424 / 4_096
            let c2: Float = 2_413 / 128
            let c3: Float = 2_392 / 128
            rgb = map(rgb) {
                let p = pow($0, 1 / m2)
                return pow(max(p - c1, 0) / max(c2 - c3 * p, 0.000_001), 1 / m1) * 100
            }
        case .hlg:
            let a: Float = 0.178_832_77
            let b: Float = 0.284_668_92
            let c: Float = 0.559_910_73
            let scene = map(rgb) {
                $0 <= 0.5 ? ($0 * $0) / 3 : (exp(($0 - c) / a) + b) / 12
            }
            let luma: Float
            if primaries == .bt709 {
                luma = simd_dot(scene, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            } else {
                luma = simd_dot(scene, SIMD3<Float>(0.2627, 0.6780, 0.0593))
            }
            rgb = scene * (pow(max(luma, 0.000_001), 0.2) * 10)
        }
        if primaries == .bt709 {
            rgb = gamut709To2020 * rgb
        }
        return rgb
    }

    private func map(
        _ value: SIMD3<Float>,
        transform: (Float) -> Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(transform(value.x), transform(value.y), transform(value.z))
    }
}

struct MetalOutputConfiguration: Sendable, Equatable {
    let cleanAperture: CGRect?
    let chromaLocation: VideoFormatMetadata.ChromaLocation
    let hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata
}

struct MetalShaderState: Sendable, Equatable {
    let uniforms: MetalYUVUniforms
    let outputConfiguration: MetalOutputConfiguration
}

struct MetalGPUUniforms: Sendable {
    var yuvColumn0: SIMD4<Float>
    var yuvColumn1: SIMD4<Float>
    var yuvColumn2: SIMD4<Float>
    var gamutColumn0: SIMD4<Float>
    var gamutColumn1: SIMD4<Float>
    var gamutColumn2: SIMD4<Float>
    var range: SIMD4<Float>
    var textureTransform: SIMD4<Float>
    var transferKind: UInt32
    var applyGamutTransform: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

private enum MetalVideoRendererError: Error {
    case textureCache(OSStatus)
    case unsupportedPixelFormat
    case textureMapping
    case commandQueue
    case shaderLibrary
    case shaderFunction
    case renderPipeline
    case sampler
    case commandBuffer
    case commandEncoder
}

final class CVMetalVideoTextureMapper: VideoTextureMapping, @unchecked Sendable {
    private let cache: CVMetalTextureCache

    init(device: any MTLDevice) throws {
        var created: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &created)
        guard status == kCVReturnSuccess, let created else {
            throw MetalVideoRendererError.textureCache(status)
        }
        cache = created
    }

    func map(
        pixelBuffer: CVPixelBuffer,
        requests: [VideoTexturePlaneRequest]
    ) throws -> MappedVideoTextures {
        guard requests.count == 2 else { throw MetalVideoRendererError.textureMapping }
        var wrappers: [CVMetalTexture] = []
        var textures: [any MTLTexture] = []
        wrappers.reserveCapacity(2)
        textures.reserveCapacity(2)

        for request in requests {
            var wrapper: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                cache,
                pixelBuffer,
                nil,
                request.pixelFormat,
                request.width,
                request.height,
                request.planeIndex,
                &wrapper
            )
            guard status == kCVReturnSuccess,
                  let wrapper,
                  let texture = CVMetalTextureGetTexture(wrapper) else {
                throw MetalVideoRendererError.textureMapping
            }
            wrappers.append(wrapper)
            textures.append(texture)
        }

        return MappedVideoTextures(
            luma: textures[0],
            chroma: textures[1],
            retainedObjects: wrappers.map { $0 as AnyObject }
        )
    }

    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }
}

final class SystemMetalCommandSubmitter: MetalCommandSubmitting, @unchecked Sendable {
    private final class ShaderBundleToken {}

    static let shaderBundle = Bundle(for: ShaderBundleToken.self)

    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    init(device: any MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw MetalVideoRendererError.commandQueue
        }
        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Self.shaderBundle)
        } catch {
            throw MetalVideoRendererError.shaderLibrary
        }
        guard let vertex = library.makeFunction(name: "fullScreenVertex"),
              let fragment = library.makeFunction(name: "yuvFragment") else {
            throw MetalVideoRendererError.shaderFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalVideoRendererError.renderPipeline
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalVideoRendererError.sampler
        }
        self.queue = queue
        self.sampler = sampler
    }

    func submitPresentingUntimed(
        _ job: MetalRenderJob,
        drawable: any CAMetalDrawable,
        completion: @escaping @Sendable (MetalCommandCompletion) -> Void
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalVideoRendererError.commandBuffer
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalVideoRendererError.commandEncoder
        }
        encoder.setRenderPipelineState(pipeline)
        var uniforms = job.uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalGPUUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalGPUUniforms>.stride, index: 0)
        encoder.setFragmentTexture(job.luma, index: 0)
        encoder.setFragmentTexture(job.chroma, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status == .completed {
                completion(.succeeded)
            } else {
                completion(.failed(buffer.error?.localizedDescription ?? "Metal command failed"))
            }
        }
        commandBuffer.commit()
    }
}

public final class MetalVideoRenderer: VideoRendering, VideoPresentationTimingResetting, @unchecked Sendable {
    public static let maximumCommandErrorLength = 256
    private static let maximumInFlightCount = 3
    private static let initialDisplayInterval = CMTime(value: 1, timescale: 60)

    private final class CompletionLifetime: @unchecked Sendable {
        let frame: VideoPresentationFrame
        let retainedObjects: [AnyObject]

        init(frame: VideoPresentationFrame, retainedObjects: [AnyObject]) {
            self.frame = frame
            self.retainedObjects = retainedObjects
        }
    }

    private let stateLock = NSLock()
    private let presentationLock = NSRecursiveLock()
    private let queue: VideoPresentationQueue
    private let textureMapper: any VideoTextureMapping
    private let commandSubmitter: any MetalCommandSubmitting
    private let failureSink: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    private var activeGeneration: MediaGeneration
    private var inFlightCount = 0
    private var completedSinceCacheFlush = 0
    private var previousTargetMediaTime: CMTime?

    convenience init(
        device: any MTLDevice,
        generation: MediaGeneration,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) throws {
        try self.init(
            device: device,
            generation: generation,
            textureMapperFactory: { try CVMetalVideoTextureMapper(device: $0) },
            commandSubmitter: try SystemMetalCommandSubmitter(device: device),
            failureSink: failureSink
        )
    }

    init(
        device: any MTLDevice,
        generation: MediaGeneration,
        textureMapperFactory: (any MTLDevice) throws -> any VideoTextureMapping,
        commandSubmitter: any MetalCommandSubmitting,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) throws {
        activeGeneration = generation
        queue = VideoPresentationQueue(generation: generation)
        textureMapper = try textureMapperFactory(device)
        self.commandSubmitter = commandSubmitter
        self.failureSink = failureSink
    }

    public func enqueue(_ frame: VideoPresentationFrame) {
        _ = queue.enqueue(frame)
    }

    public func flush(to generation: MediaGeneration) {
        presentationLock.withLock {
            stateLock.withLock {
                activeGeneration = generation
                previousTargetMediaTime = nil
            }
            queue.flush(to: generation)
        }
    }

    func resetPresentationTiming() {
        presentationLock.withLock {
            stateLock.withLock {
                previousTargetMediaTime = nil
            }
        }
    }

    public func draw(
        targetMediaTime: CMTime,
        drawable: any CAMetalDrawable
    ) -> VideoRenderDecision {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        guard reserveInFlightSlot() else {
            _ = nextDisplayInterval(for: targetMediaTime)
            return decision(action: .skippedInFlight, frame: nil, dropped: 0)
        }

        let displayInterval = nextDisplayInterval(for: targetMediaTime)
        let selection = queue.select(
            targetMediaTime: targetMediaTime,
            displayInterval: displayInterval
        )
        guard let frame = selection.frame else {
            releaseInFlightSlot(flushCacheIfNeeded: false)
            return decision(
                action: selection.action,
                frame: nil,
                dropped: selection.droppedFrameCount
            )
        }

        let textures: MappedVideoTextures
        let isTenBit: Bool
        do {
            (textures, isTenBit) = try mappedTextures(for: frame)
        } catch {
            releaseInFlightSlot(flushCacheIfNeeded: false)
            emit(.renderTextureMapping, generation: frame.generation)
            return decision(
                action: .renderFailed,
                frame: frame,
                dropped: selection.droppedFrameCount
            )
        }

        let presentationConfiguration = HDRPresentationPolicy.systemManaged.configuration(
            for: frame.formatMetadata
        )
        let shaderState = Self.makeShaderState(
            configuration: presentationConfiguration,
            pixelFormatIsTenBit: isTenBit
        )
        let job = MetalRenderJob(
            luma: textures.luma,
            chroma: textures.chroma,
            uniforms: Self.makeGPUUniforms(
                shaderState: shaderState,
                configuration: presentationConfiguration
            ),
            outputConfiguration: shaderState.outputConfiguration,
            displayInterval: displayInterval
        )
        let lifetime = CompletionLifetime(
            frame: frame,
            retainedObjects: textures.retainedObjects
        )
        do {
            try commandSubmitter.submitPresentingUntimed(job, drawable: drawable) { [weak self] result in
                _ = lifetime
                self?.complete(result, submittedGeneration: frame.generation)
            }
        } catch {
            releaseInFlightSlot(flushCacheIfNeeded: false)
            emit(.metalCommand(Self.sanitizedCommandMessage(String(describing: error))), generation: frame.generation)
            return decision(
                action: .renderFailed,
                frame: frame,
                dropped: selection.droppedFrameCount
            )
        }

        return decision(
            action: selection.action,
            frame: frame,
            dropped: selection.droppedFrameCount
        )
    }

    static func makeShaderState(
        metadata: VideoFormatMetadata,
        pixelFormatIsTenBit: Bool
    ) -> MetalShaderState {
        makeShaderState(
            configuration: HDRPresentationPolicy.systemManaged.configuration(for: metadata),
            pixelFormatIsTenBit: pixelFormatIsTenBit
        )
    }

    private static func makeShaderState(
        configuration: HDRPresentationConfiguration,
        pixelFormatIsTenBit: Bool
    ) -> MetalShaderState {
        let isIdentity = configuration.matrix == .identity
        let fullRange = configuration.range == .full
        let maximumCode: Float = pixelFormatIsTenBit ? 1_023 : 255
        let yOffsetCode: Float = fullRange ? 0 : (pixelFormatIsTenBit ? 64 : 16)
        let yRangeCode: Float = fullRange ? maximumCode : (pixelFormatIsTenBit ? 876 : 219)
        let chromaCenterCode: Float = isIdentity
            ? yOffsetCode
            : (pixelFormatIsTenBit ? 512 : 128)
        let chromaRangeCode: Float = isIdentity
            ? yRangeCode
            : (fullRange ? maximumCode : (pixelFormatIsTenBit ? 896 : 224))
        let normalization: Float = pixelFormatIsTenBit ? 65_535 / 65_472 : 1

        let matrix = yuvMatrix(for: configuration.matrix)
        let gamut = simd_float3x3(columns: (
            SIMD3<Float>(0.627404, 0.069097, 0.016392),
            SIMD3<Float>(0.329283, 0.919540, 0.088013),
            SIMD3<Float>(0.043313, 0.011362, 0.895595)
        ))
        return MetalShaderState(
            uniforms: MetalYUVUniforms(
                yOffset: yOffsetCode / maximumCode,
                yScale: maximumCode / yRangeCode,
                chromaOffset: chromaCenterCode / maximumCode,
                chromaScale: maximumCode / chromaRangeCode,
                sampleNormalization: normalization,
                yuvToRGB: matrix,
                gamut709To2020: gamut,
                transfer: configuration.transfer,
                matrixKind: configuration.matrix,
                primaries: configuration.primaries
            ),
            outputConfiguration: configuration.outputConfiguration
        )
    }

    private func mappedTextures(
        for frame: VideoPresentationFrame
    ) throws -> (MappedVideoTextures, Bool) {
        switch frame.storage {
        case let .metalPlanes(planes):
            return (
                MappedVideoTextures(
                    luma: planes.luma,
                    chroma: planes.chroma,
                    retainedObjects: planes.retainedObjects
                ),
                frame.formatMetadata.bitDepth > 8
            )
        case let .pixelBuffer(pixelBuffer):
            guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
                throw MetalVideoRendererError.unsupportedPixelFormat
            }
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let formats: (MTLPixelFormat, MTLPixelFormat, Bool)
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                formats = (.r8Unorm, .rg8Unorm, false)
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                formats = (.r16Unorm, .rg16Unorm, true)
            default:
                throw MetalVideoRendererError.unsupportedPixelFormat
            }
            let requests = [
                VideoTexturePlaneRequest(
                    planeIndex: 0,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                    pixelFormat: formats.0
                ),
                VideoTexturePlaneRequest(
                    planeIndex: 1,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                    pixelFormat: formats.1
                ),
            ]
            let mapped = try textureMapper.map(pixelBuffer: pixelBuffer, requests: requests)
            return (
                MappedVideoTextures(
                    luma: mapped.luma,
                    chroma: mapped.chroma,
                    retainedObjects: [pixelBuffer as AnyObject] + mapped.retainedObjects
                ),
                formats.2
            )
        }
    }

    private func reserveInFlightSlot() -> Bool {
        stateLock.withLock {
            guard inFlightCount < Self.maximumInFlightCount else { return false }
            inFlightCount += 1
            return true
        }
    }

    private func releaseInFlightSlot(flushCacheIfNeeded: Bool) {
        let shouldFlush = stateLock.withLock {
            inFlightCount = max(0, inFlightCount - 1)
            guard flushCacheIfNeeded else { return false }
            completedSinceCacheFlush += 1
            if completedSinceCacheFlush >= 32, inFlightCount == 0 {
                completedSinceCacheFlush = 0
                return true
            }
            return false
        }
        if shouldFlush { textureMapper.flush() }
    }

    private func nextDisplayInterval(for target: CMTime) -> CMTime {
        stateLock.withLock {
            defer {
                if target.isNumeric { previousTargetMediaTime = target }
            }
            guard target.isNumeric,
                  let previousTargetMediaTime,
                  previousTargetMediaTime.isNumeric else {
                return Self.initialDisplayInterval
            }
            let delta = CMTimeSubtract(target, previousTargetMediaTime)
            guard delta.isNumeric, CMTimeCompare(delta, .zero) > 0 else {
                return Self.initialDisplayInterval
            }
            return delta
        }
    }

    private func complete(
        _ result: MetalCommandCompletion,
        submittedGeneration: MediaGeneration
    ) {
        releaseInFlightSlot(flushCacheIfNeeded: true)
        guard case let .failed(message) = result else { return }
        let isCurrent = stateLock.withLock { activeGeneration == submittedGeneration }
        guard isCurrent else { return }
        emit(
            .metalCommand(Self.sanitizedCommandMessage(message)),
            generation: submittedGeneration
        )
    }

    private func emit(_ error: PlaybackCoreError, generation: MediaGeneration) {
        let isCurrent = stateLock.withLock { activeGeneration == generation }
        if isCurrent { failureSink(error, generation) }
    }

    private func decision(
        action: VideoRenderDecision.Action,
        frame: VideoPresentationFrame?,
        dropped: Int
    ) -> VideoRenderDecision {
        VideoRenderDecision(
            action: action,
            sourceAccessUnitID: frame?.sourceAccessUnitID,
            sequenceNumber: frame?.sequenceNumber,
            droppedFrameCount: dropped
        )
    }

    private static func sanitizedCommandMessage(_ message: String) -> String {
        let singleLine = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(maximumCommandErrorLength))
    }

    private static func yuvMatrix(
        for kind: VideoFormatMetadata.Matrix
    ) -> simd_float3x3 {
        switch kind {
        case .bt601:
            return simd_float3x3(columns: (
                SIMD3<Float>(1, 1, 1),
                SIMD3<Float>(0, -0.344136, 1.772),
                SIMD3<Float>(1.402, -0.714136, 0)
            ))
        case .bt2020:
            return simd_float3x3(columns: (
                SIMD3<Float>(1, 1, 1),
                SIMD3<Float>(0, -0.164553, 1.8814),
                SIMD3<Float>(1.4746, -0.571353, 0)
            ))
        case .identity:
            return simd_float3x3(columns: (
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(1, 0, 0)
            ))
        case .bt709, .unknown:
            return simd_float3x3(columns: (
                SIMD3<Float>(1, 1, 1),
                SIMD3<Float>(0, -0.187324, 1.8556),
                SIMD3<Float>(1.5748, -0.468124, 0)
            ))
        }
    }

    static func makeGPUUniforms(
        shaderState: MetalShaderState,
        metadata: VideoFormatMetadata
    ) -> MetalGPUUniforms {
        makeGPUUniforms(
            shaderState: shaderState,
            configuration: HDRPresentationPolicy.systemManaged.configuration(for: metadata)
        )
    }

    private static func makeGPUUniforms(
        shaderState: MetalShaderState,
        configuration: HDRPresentationConfiguration
    ) -> MetalGPUUniforms {
        let uniforms = shaderState.uniforms
        let aperture = configuration.cleanAperture
        let width = max(Float(configuration.dimensions.width), 1)
        let height = max(Float(configuration.dimensions.height), 1)
        let transform: SIMD4<Float>
        if let aperture {
            transform = SIMD4<Float>(
                Float(aperture.origin.x) / width,
                Float(aperture.origin.y) / height,
                Float(aperture.width) / width,
                Float(aperture.height) / height
            )
        } else {
            transform = SIMD4<Float>(0, 0, 1, 1)
        }
        let transferKind: UInt32
        switch uniforms.transfer {
        case .linear: transferKind = 0
        case .bt709, .unknown: transferKind = 1
        case .pq: transferKind = 2
        case .hlg: transferKind = 3
        }
        return MetalGPUUniforms(
            yuvColumn0: SIMD4<Float>(
                uniforms.yuvToRGB.columns.0,
                uniforms.sampleNormalization
            ),
            yuvColumn1: SIMD4<Float>(uniforms.yuvToRGB.columns.1, 0),
            yuvColumn2: SIMD4<Float>(uniforms.yuvToRGB.columns.2, 0),
            gamutColumn0: SIMD4<Float>(uniforms.gamut709To2020.columns.0, 0),
            gamutColumn1: SIMD4<Float>(uniforms.gamut709To2020.columns.1, 0),
            gamutColumn2: SIMD4<Float>(uniforms.gamut709To2020.columns.2, 0),
            range: SIMD4<Float>(
                uniforms.yOffset,
                uniforms.yScale,
                uniforms.chromaOffset,
                uniforms.chromaScale
            ),
            textureTransform: transform,
            transferKind: transferKind,
            applyGamutTransform: configuration.primaries == .bt709 ? 1 : 0
        )
    }
}
