// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
import IOSurface
import Metal

public enum LumaScanProbeFailure: Error, Equatable, Sendable {
    case initializationFailed
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable
    case computePipelineCreationFailed
    case textureCacheCreationFailed(code: Int32)
    case unsupportedPixelFormat(OSType)
    case incompatiblePixelBuffers
    case nonIOSurfaceInput
    case invalidPlaneCount(current: Int, previous: Int)
    case invalidDimensions
    case textureMappingFailed(code: Int32)
    case resultBufferAllocationFailed
    case commandBufferAllocationFailed
    case commandEncoderAllocationFailed
    case asynchronousCommandFailed
}

public protocol LumaScanProbing: AnyObject, Sendable {
    func submit(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    )

    func stop(generation: MediaGeneration)
}

enum LumaScanProbeLayout {
    static let width = 64
    static let height = 36
    static let sampleCount = width * height
    static let resultStride = MemoryLayout<PackedLumaScanProbeResult>.stride
    static let resultBufferLength = sampleCount * resultStride
}

struct LumaScanPixelBufferProperties: Equatable, Sendable {
    let hasIOSurface: Bool
    let planeCount: Int
    let width: Int
    let height: Int
    let lumaWidth: Int
    let lumaHeight: Int
    let pixelFormat: OSType

    init(
        hasIOSurface: Bool,
        planeCount: Int,
        width: Int,
        height: Int,
        lumaWidth: Int,
        lumaHeight: Int,
        pixelFormat: OSType
    ) {
        self.hasIOSurface = hasIOSurface
        self.planeCount = planeCount
        self.width = width
        self.height = height
        self.lumaWidth = lumaWidth
        self.lumaHeight = lumaHeight
        self.pixelFormat = pixelFormat
    }

    init(pixelBuffer: CVPixelBuffer) {
        let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
        self.init(
            hasIOSurface: CVPixelBufferGetIOSurface(pixelBuffer) != nil,
            planeCount: planes,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            lumaWidth: planes > 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : 0,
            lumaHeight: planes > 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : 0,
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
    }
}

struct LumaScanTextureRequest: Equatable, Sendable {
    let pixelFormat: MTLPixelFormat
    let width: Int
    let height: Int
}

enum LumaScanInputValidator {
    static func validate(
        current: LumaScanPixelBufferProperties,
        previous: LumaScanPixelBufferProperties
    ) throws(LumaScanProbeFailure) -> LumaScanTextureRequest {
        guard current.hasIOSurface, previous.hasIOSurface else {
            throw .nonIOSurfaceInput
        }
        guard current.planeCount == 2, previous.planeCount == 2 else {
            throw .invalidPlaneCount(
                current: current.planeCount,
                previous: previous.planeCount
            )
        }
        guard current.width > 0,
              current.height > 0,
              previous.width > 0,
              previous.height > 0,
              current.lumaWidth > 0,
              previous.lumaWidth > 0,
              current.lumaHeight >= 3,
              previous.lumaHeight >= 3 else {
            throw .invalidDimensions
        }

        let currentTextureFormat = try textureFormat(for: current.pixelFormat)
        _ = try textureFormat(for: previous.pixelFormat)
        guard current.width == previous.width,
              current.height == previous.height,
              current.lumaWidth == previous.lumaWidth,
              current.lumaHeight == previous.lumaHeight,
              current.pixelFormat == previous.pixelFormat else {
            throw .incompatiblePixelBuffers
        }
        return LumaScanTextureRequest(
            pixelFormat: currentTextureFormat,
            width: current.lumaWidth,
            height: current.lumaHeight
        )
    }

    private static func textureFormat(
        for pixelFormat: OSType
    ) throws(LumaScanProbeFailure) -> MTLPixelFormat {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .r8Unorm
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .r16Unorm
        default:
            throw .unsupportedPixelFormat(pixelFormat)
        }
    }
}

protocol LumaScanProbeBackend: AnyObject, Sendable {
    func submit(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) throws(LumaScanProbeFailure)
}

public final class LumaScanProbe: LumaScanProbing, @unchecked Sendable {
    private struct SubmissionKey: Hashable {
        let generation: MediaGeneration
        let attempt: Int
    }

    private struct State {
        var activeGeneration: MediaGeneration?
        var stopped = false
        var attempts = 0
        var inFlight: Set<SubmissionKey> = []
    }

    private let backend: any LumaScanProbeBackend
    private let maximumFrames: Int
    private let stateLock = NSLock()
    private var state = State()

    public convenience init(
        commandQueue: any MTLCommandQueue,
        maximumFrames: Int = 12
    ) throws {
        try self.init(maximumFrames: maximumFrames) {
            try SystemLumaScanProbeBackend(commandQueue: commandQueue)
        }
    }

    init(backend: any LumaScanProbeBackend, maximumFrames: Int = 12) {
        self.backend = backend
        self.maximumFrames = min(max(maximumFrames, 0), 12)
    }

    convenience init(
        maximumFrames: Int,
        makeBackend: () throws -> any LumaScanProbeBackend
    ) throws {
        self.init(backend: try makeBackend(), maximumFrames: maximumFrames)
    }

    public func submit(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        let submission = stateLock.withLock { () -> SubmissionKey? in
            if let active = state.activeGeneration {
                if generation < active {
                    return nil
                }
                if generation > active {
                    adopt(generation: generation, stopped: false)
                }
            } else {
                adopt(generation: generation, stopped: false)
            }

            guard !state.stopped, state.attempts < maximumFrames else {
                return nil
            }
            state.attempts += 1
            let key = SubmissionKey(generation: generation, attempt: state.attempts)
            state.inFlight.insert(key)
            return key
        }
        guard let submission else {
            return
        }

        let backendCompletion: @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void = { [weak self] result in
            self?.finish(submission, result: result, completion: completion)
        }
        do {
            try backend.submit(
                current: current,
                previous: previous,
                generation: generation,
                completion: backendCompletion
            )
        } catch {
            finish(submission, result: .failure(error), completion: completion)
        }
    }

    public func stop(generation: MediaGeneration) {
        stateLock.withLock {
            guard let active = state.activeGeneration else {
                adopt(generation: generation, stopped: true)
                return
            }
            guard generation >= active else {
                return
            }
            if generation > active {
                adopt(generation: generation, stopped: true)
            } else {
                state.stopped = true
            }
        }
    }

    private func finish(
        _ submission: SubmissionKey,
        result: Result<ContentProbeSample, LumaScanProbeFailure>,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        let deliver = stateLock.withLock {
            guard state.inFlight.remove(submission) != nil else {
                return false
            }
            return state.activeGeneration == submission.generation && !state.stopped
        }
        if deliver {
            completion(result)
        }
    }

    private func adopt(generation: MediaGeneration, stopped: Bool) {
        state.activeGeneration = generation
        state.stopped = stopped
        state.attempts = 0
        state.inFlight.removeAll(keepingCapacity: true)
    }
}

private struct PackedLumaScanProbeResult {
    let comb: UInt16
    let motion: UInt16
}

private struct MappedLumaTexture {
    let wrapper: CVMetalTexture
    let texture: any MTLTexture
}

protocol LumaScanCompletionResourceReleasing: AnyObject, Sendable {
    func releaseBeforeCompletion()
}

enum LumaScanCompletionDelivery {
    static func deliver(
        result: Result<ContentProbeSample, LumaScanProbeFailure>,
        resources: any LumaScanCompletionResourceReleasing,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        resources.releaseBeforeCompletion()
        completion(result)
    }
}

private final class LumaScanTextureCacheOwner: @unchecked Sendable {
    let cache: CVMetalTextureCache

    init(cache: CVMetalTextureCache) {
        self.cache = cache
    }
}

private final class LumaScanInFlightResources:
    LumaScanCompletionResourceReleasing,
    @unchecked Sendable
{
    private var current: CVPixelBuffer?
    private var previous: CVPixelBuffer?
    private var resultBuffer: (any MTLBuffer)?
    private var currentMapping: MappedLumaTexture?
    private var previousMapping: MappedLumaTexture?

    init(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        currentMapping: MappedLumaTexture,
        previousMapping: MappedLumaTexture,
        resultBuffer: any MTLBuffer
    ) {
        self.current = current
        self.previous = previous
        self.currentMapping = currentMapping
        self.previousMapping = previousMapping
        self.resultBuffer = resultBuffer
    }

    func retainedResultBuffer() -> (any MTLBuffer)? {
        resultBuffer
    }

    func releaseBeforeCompletion() {
        currentMapping = nil
        previousMapping = nil
        current = nil
        previous = nil
        resultBuffer = nil
    }
}

private final class SystemLumaScanProbeBackend: LumaScanProbeBackend, @unchecked Sendable {
    private final class ShaderBundleToken {}

    private static let shaderBundle = Bundle(for: ShaderBundleToken.self)

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let textureCacheOwner: LumaScanTextureCacheOwner

    init(commandQueue: any MTLCommandQueue) throws(LumaScanProbeFailure) {
        self.commandQueue = commandQueue
        let device = commandQueue.device

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw .textureCacheCreationFailed(code: cacheStatus)
        }
        textureCacheOwner = LumaScanTextureCacheOwner(cache: cache)

        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Self.shaderBundle)
        } catch {
            throw .shaderLibraryUnavailable
        }
        guard let function = library.makeFunction(name: "scanProbe") else {
            throw .shaderFunctionUnavailable
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw .computePipelineCreationFailed
        }
    }

    func submit(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) throws(LumaScanProbeFailure) {
        let request = try LumaScanInputValidator.validate(
            current: LumaScanPixelBufferProperties(pixelBuffer: current),
            previous: LumaScanPixelBufferProperties(pixelBuffer: previous)
        )
        let previousMapping = try map(previous, request: request)
        let currentMapping = try map(current, request: request)
        guard let resultBuffer = commandQueue.device.makeBuffer(
            length: LumaScanProbeLayout.resultBufferLength,
            options: .storageModeShared
        ) else {
            throw .resultBufferAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw .commandBufferAllocationFailed
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw .commandEncoderAllocationFailed
        }

        let resources = LumaScanInFlightResources(
            current: current,
            previous: previous,
            currentMapping: currentMapping,
            previousMapping: previousMapping,
            resultBuffer: resultBuffer
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(previousMapping.texture, index: 0)
        encoder.setTexture(currentMapping.texture, index: 1)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        let threadWidth = max(1, min(LumaScanProbeLayout.width, pipeline.threadExecutionWidth))
        let threadHeight = max(
            1,
            min(
                LumaScanProbeLayout.height,
                pipeline.maxTotalThreadsPerThreadgroup / threadWidth
            )
        )
        encoder.dispatchThreads(
            MTLSize(
                width: LumaScanProbeLayout.width,
                height: LumaScanProbeLayout.height,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [self, resources] buffer in
            withExtendedLifetime(self) {
                let result: Result<ContentProbeSample, LumaScanProbeFailure>
                if buffer.status == .completed,
                   let resultBuffer = resources.retainedResultBuffer() {
                    result = .success(Self.sample(from: resultBuffer))
                } else {
                    result = .failure(.asynchronousCommandFailed)
                }
                LumaScanCompletionDelivery.deliver(
                    result: result,
                    resources: resources,
                    completion: completion
                )
            }
        }
        commandBuffer.commit()
    }

    private func map(
        _ pixelBuffer: CVPixelBuffer,
        request: LumaScanTextureRequest
    ) throws(LumaScanProbeFailure) -> MappedLumaTexture {
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCacheOwner.cache,
            pixelBuffer,
            nil,
            request.pixelFormat,
            request.width,
            request.height,
            0,
            &wrapper
        )
        guard status == kCVReturnSuccess,
              let wrapper,
              let texture = CVMetalTextureGetTexture(wrapper) else {
            throw .textureMappingFailed(
                code: status == kCVReturnSuccess ? kCVReturnError : status
            )
        }
        return MappedLumaTexture(wrapper: wrapper, texture: texture)
    }

    private static func sample(from buffer: any MTLBuffer) -> ContentProbeSample {
        let results = buffer.contents().bindMemory(
            to: PackedLumaScanProbeResult.self,
            capacity: LumaScanProbeLayout.sampleCount
        )
        var combTotal: UInt64 = 0
        var motionTotal: UInt64 = 0
        for index in 0..<LumaScanProbeLayout.sampleCount {
            combTotal += UInt64(results[index].comb)
            motionTotal += UInt64(results[index].motion)
        }
        let divisor = Float(UInt64(UInt16.max) * UInt64(LumaScanProbeLayout.sampleCount))
        return ContentProbeSample(
            combRatio: Float(combTotal) / divisor,
            motionRatio: Float(motionTotal) / divisor,
            sampleCount: LumaScanProbeLayout.sampleCount
        )
    }
}
