// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import VPlayerPlayback

@MainActor
final class MetalVideoRendererTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 4)

    func testNV12VideoFullAndP010VideoFullUseExactPlaneFormatsAndReportedDimensions() throws {
        let formats: [(OSType, MTLPixelFormat, MTLPixelFormat)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .r8Unorm, .rg8Unorm),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .r8Unorm, .rg8Unorm),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .r16Unorm, .rg16Unorm),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, .r16Unorm, .rg16Unorm),
        ]
        for (pixelFormat, lumaFormat, chromaFormat) in formats {
            let harness = try makeHarness()
            let buffer = try makeBiPlanarPixelBuffer(pixelFormat: pixelFormat, width: 18, height: 10)
            harness.renderer.enqueue(frame(id: 1, pts: .zero, storage: .pixelBuffer(buffer)))

            let decision = harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable)

            XCTAssertEqual(decision.action, .presented)
            XCTAssertEqual(harness.mapper.requests.count, 1)
            XCTAssertEqual(harness.mapper.requests[0], [
                .init(
                    planeIndex: 0,
                    width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                    height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                    pixelFormat: lumaFormat
                ),
                .init(
                    planeIndex: 1,
                    width: CVPixelBufferGetWidthOfPlane(buffer, 1),
                    height: CVPixelBufferGetHeightOfPlane(buffer, 1),
                    pixelFormat: chromaFormat
                ),
            ])
        }
    }

    func testTextureCacheFactoryRunsExactlyOnceForMultiplePixelBuffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mapper = try FakeTextureMapper(device: device)
        let submitter = FakeCommandSubmitter()
        var factoryCount = 0
        let renderer = try MetalVideoRenderer(
            device: device,
            generation: generation,
            textureMapperFactory: { _ in
                factoryCount += 1
                return mapper
            },
            commandSubmitter: submitter,
            failureSink: { _, _ in }
        )
        let drawable = try FakeDrawable(device: device)
        for id in 1...2 {
            renderer.enqueue(frame(
                id: UInt64(id),
                pts: CMTime(value: Int64(id), timescale: 1),
                storage: .pixelBuffer(try makeBiPlanarPixelBuffer(
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    width: 4,
                    height: 4
                ))
            ))
            _ = renderer.draw(
                targetMediaTime: CMTime(value: Int64(id), timescale: 1),
                drawable: drawable
            )
            submitter.completeFirst(.succeeded)
        }
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(mapper.requests.count, 2)
    }

    func testTotalAndPartialTextureMappingFailureEmitOneErrorAndNeverSubmit() throws {
        for failurePoint in [0, 1] {
            let harness = try makeHarness()
            harness.mapper.failurePoint = failurePoint
            let buffer = try makeBiPlanarPixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: 4,
                height: 4
            )
            harness.renderer.enqueue(frame(id: 1, pts: .zero, storage: .pixelBuffer(buffer)))

            let decision = harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable)

            XCTAssertEqual(decision.action, .renderFailed)
            XCTAssertEqual(harness.submitter.submitCount, 0)
            XCTAssertEqual(harness.mapper.processedPlaneCounts, [failurePoint])
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [.renderTextureMapping])
            XCTAssertEqual(harness.failures.snapshot.map(\.generation), [generation])
        }
    }

    func testMetalPlaneRetainedObjectsLiveThroughCompletionAfterGenerationFlush() throws {
        let harness = try makeHarness()
        var probe: LifetimeProbe? = LifetimeProbe()
        weak let weakProbe = probe
        var source: VideoPresentationFrame? = frame(
            id: 1,
            pts: .zero,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: [try XCTUnwrap(probe)]
            ))
        )
        harness.renderer.enqueue(try XCTUnwrap(source))
        XCTAssertEqual(
            harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable).action,
            .presented
        )
        source = nil
        probe = nil
        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let renderer = harness.renderer
        DispatchQueue.global().async {
            flushStarted.signal()
            renderer.flush(to: MediaGeneration(rawValue: 5))
            flushFinished.signal()
        }
        XCTAssertEqual(flushStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertNotNil(weakProbe)

        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(weakProbe)
    }

    func testInFlightCapacityIsExactlyThreeAndFourthSkipsWithoutQueueAdvance() throws {
        let harness = try makeHarness()
        for id in 1...4 {
            harness.renderer.enqueue(frame(
                id: UInt64(id),
                pts: CMTime(value: Int64(id), timescale: 25),
                storage: .metalPlanes(.init(
                    luma: harness.mapper.texture,
                    chroma: harness.mapper.texture,
                    retainedObjects: []
                ))
            ))
        }
        for id in 1...3 {
            let decision = harness.renderer.draw(
                targetMediaTime: CMTime(value: Int64(id), timescale: 25),
                drawable: harness.drawable
            )
            XCTAssertEqual(decision.action, .presented)
            XCTAssertEqual(decision.sourceAccessUnitID, UInt64(id))
        }

        let skipped = harness.renderer.draw(
            targetMediaTime: CMTime(value: 4, timescale: 25),
            drawable: harness.drawable
        )
        XCTAssertEqual(skipped.action, .skippedInFlight)
        XCTAssertEqual(harness.submitter.submitCount, 3)

        harness.submitter.completeFirst(.succeeded)
        let fourth = harness.renderer.draw(
            targetMediaTime: CMTime(value: 4, timescale: 25),
            drawable: harness.drawable
        )
        XCTAssertEqual(fourth.action, .presented)
        XCTAssertEqual(fourth.sourceAccessUnitID, 4)
    }

    func testSkippedInFlightTickStillKeepsConsecutiveTargetCadence() throws {
        let harness = try makeHarness()
        for id in 1...4 {
            harness.renderer.enqueue(frame(
                id: UInt64(id),
                pts: CMTime(value: Int64(id - 1) * 20, timescale: 1_000),
                storage: .metalPlanes(.init(
                    luma: harness.mapper.texture,
                    chroma: harness.mapper.texture,
                    retainedObjects: []
                ))
            ))
        }
        for tick in 0...2 {
            _ = harness.renderer.draw(
                targetMediaTime: CMTime(value: Int64(tick) * 20, timescale: 1_000),
                drawable: harness.drawable
            )
        }
        XCTAssertEqual(
            harness.renderer.draw(
                targetMediaTime: CMTime(value: 60, timescale: 1_000),
                drawable: harness.drawable
            ).action,
            .skippedInFlight
        )

        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(
            harness.renderer.draw(
                targetMediaTime: CMTime(value: 80, timescale: 1_000),
                drawable: harness.drawable
            ).action,
            .presented
        )
        XCTAssertEqual(
            try XCTUnwrap(harness.submitter.jobs.last?.displayInterval.seconds),
            0.02,
            accuracy: 0.000_000_001
        )
    }

    func testAsyncCommandFailureIsSanitizedBoundedOnceAndGenerationGated() throws {
        let harness = try makeHarness()
        harness.renderer.enqueue(frame(
            id: 1,
            pts: .zero,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        _ = harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable)
        harness.submitter.completeFirst(.failed(String(repeating: "secret\n", count: 100)))

        let errors = harness.failures.snapshot
        XCTAssertEqual(errors.count, 1)
        guard case let .metalCommand(message) = errors[0].error else {
            return XCTFail("expected metal command failure")
        }
        XCTAssertLessThanOrEqual(message.count, MetalVideoRenderer.maximumCommandErrorLength)
        XCTAssertFalse(message.contains("\n"))

        harness.renderer.enqueue(frame(
            id: 2,
            pts: CMTime(value: 1, timescale: 1),
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        _ = harness.renderer.draw(targetMediaTime: CMTime(value: 1, timescale: 1), drawable: harness.drawable)
        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let renderer = harness.renderer
        DispatchQueue.global().async {
            flushStarted.signal()
            renderer.flush(to: MediaGeneration(rawValue: 5))
            flushFinished.signal()
        }
        XCTAssertEqual(flushStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.1), .timedOut)
        harness.submitter.completeFirst(.failed("stale failure"))
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(harness.failures.snapshot.count, 1)
    }

    func testAcceptanceMetricsCountOnlySuccessfulNewFrameCompletions() throws {
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 1 }
        )
        let harness = try makeHarness(metrics: metrics)
        harness.renderer.enqueue(frame(
            id: 1,
            pts: .zero,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))

        XCTAssertEqual(
            harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable).action,
            .presented
        )
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).presentedVideoFrames, 0)
        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).presentedVideoFrames, 1)

        XCTAssertEqual(
            harness.renderer.draw(
                targetMediaTime: CMTime(value: 1, timescale: 60),
                drawable: harness.drawable
            ).action,
            .repeated
        )
        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).presentedVideoFrames, 1)

        harness.renderer.enqueue(frame(
            id: 2,
            pts: CMTime(value: 2, timescale: 60),
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        XCTAssertEqual(
            harness.renderer.draw(
                targetMediaTime: CMTime(value: 2, timescale: 60),
                drawable: harness.drawable
            ).action,
            .presented
        )
        harness.submitter.completeFirst(.failed("asynchronous failure"))
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).presentedVideoFrames, 1)
    }

    func testFlushDrainsSuccessfulPresentationBeforeAdvancingGeneration() throws {
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 1 }
        )
        let harness = try makeHarness(metrics: metrics)
        harness.renderer.enqueue(frame(
            id: 1,
            pts: .zero,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        _ = harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable)

        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let renderer = harness.renderer
        DispatchQueue.global().async {
            flushStarted.signal()
            renderer.flush(to: MediaGeneration(rawValue: 5))
            flushFinished.signal()
        }
        XCTAssertEqual(flushStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.1), .timedOut)
        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 2), .success)

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.presentedVideoFrames, 1)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
    }

    func testSelectionDropsAreCountedExactlyOnceEvenWhenSubmissionFails() throws {
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 1 }
        )
        let harness = try makeHarness(metrics: metrics)
        for id in 1...3 {
            harness.renderer.enqueue(frame(
                id: UInt64(id),
                pts: CMTime(value: Int64(id), timescale: 100),
                storage: .metalPlanes(.init(
                    luma: harness.mapper.texture,
                    chroma: harness.mapper.texture,
                    retainedObjects: []
                ))
            ))
        }

        let decision = harness.renderer.draw(
            targetMediaTime: CMTime(value: 3, timescale: 100),
            drawable: harness.drawable
        )
        XCTAssertEqual(decision.droppedFrameCount, 2)
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).droppedVideoFrames, 2)
        harness.submitter.completeFirst(.failed("asynchronous failure"))
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).droppedVideoFrames, 2)
    }

    func testFlushLinearizesSelectionMappingAndSubmissionAcrossGenerations() throws {
        let harness = try makeHarness()
        let mappingStarted = DispatchSemaphore(value: 0)
        let allowMappingToFinish = DispatchSemaphore(value: 0)
        let drawFinished = DispatchSemaphore(value: 0)
        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let decision = DecisionRecorder()
        harness.mapper.beforeReturn = {
            mappingStarted.signal()
            _ = allowMappingToFinish.wait(timeout: .now() + 2)
        }
        harness.renderer.enqueue(frame(
            id: 1,
            pts: .zero,
            storage: .pixelBuffer(try makeBiPlanarPixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: 4,
                height: 4
            ))
        ))
        let renderer = harness.renderer
        let drawable = harness.drawable
        DispatchQueue.global().async {
            decision.set(renderer.draw(targetMediaTime: .zero, drawable: drawable))
            drawFinished.signal()
        }
        XCTAssertEqual(mappingStarted.wait(timeout: .now() + 2), .success)

        let nextGeneration = MediaGeneration(rawValue: 5)
        DispatchQueue.global().async {
            flushStarted.signal()
            renderer.flush(to: nextGeneration)
            flushFinished.signal()
        }
        XCTAssertEqual(flushStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.1), .timedOut)

        allowMappingToFinish.signal()
        XCTAssertEqual(drawFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.1), .timedOut)
        harness.submitter.completeFirst(.succeeded)
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(decision.value?.action, .presented)
        XCTAssertEqual(harness.submitter.submitCount, 1)
    }

    func testSubmissionIsUntimedAndIntervalUsesFirstSixtiethThenTargetMediaDeltaAndFlushReset() throws {
        let harness = try makeHarness()
        for (id, pts) in [(1, 1.0), (2, 1.02)] {
            harness.renderer.enqueue(frame(
                id: UInt64(id),
                pts: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
                storage: .metalPlanes(.init(
                    luma: harness.mapper.texture,
                    chroma: harness.mapper.texture,
                    retainedObjects: []
                ))
            ))
            _ = harness.renderer.draw(
                targetMediaTime: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
                drawable: harness.drawable
            )
            harness.submitter.completeFirst(.succeeded)
        }
        XCTAssertEqual(harness.submitter.jobs[0].displayInterval.seconds, 1.0 / 60.0, accuracy: 0.000_000_001)
        XCTAssertEqual(harness.submitter.jobs[1].displayInterval.seconds, 0.02, accuracy: 0.000_000_001)
        XCTAssertTrue(harness.submitter.usedOnlyUntimedPresentation)

        harness.renderer.resetPresentationTiming()
        harness.renderer.enqueue(frame(
            id: 3,
            pts: CMTime(value: 2, timescale: 1),
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        _ = harness.renderer.draw(
            targetMediaTime: CMTime(value: 2, timescale: 1),
            drawable: harness.drawable
        )
        XCTAssertEqual(
            try XCTUnwrap(harness.submitter.jobs.last?.displayInterval.seconds),
            1.0 / 60.0,
            accuracy: 0.000_000_001
        )
        harness.submitter.completeFirst(.succeeded)

        let nextGeneration = MediaGeneration(rawValue: 5)
        harness.renderer.flush(to: nextGeneration)
        harness.renderer.enqueue(frame(
            id: 4,
            pts: CMTime(value: 10, timescale: 1),
            generation: nextGeneration,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            ))
        ))
        _ = harness.renderer.draw(targetMediaTime: CMTime(value: 10, timescale: 1), drawable: harness.drawable)
        XCTAssertEqual(
            try XCTUnwrap(harness.submitter.jobs.last?.displayInterval.seconds),
            1.0 / 60.0,
            accuracy: 0.000_000_001
        )
    }

    func testGeneratedUniformsCoverRangeMatrixTransferPrimariesAndMetadata() throws {
        let metadata = makeMetadata(
            bitDepth: 10,
            range: .video,
            matrix: .bt2020,
            transfer: .pq,
            primaries: .bt709,
            cleanAperture: CGRect(x: 4, y: 2, width: 1_912, height: 1_076),
            chromaLocation: .init(topField: "left", bottomField: "center"),
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: Data([1, 2, 3]),
                contentLightLevelInfo: Data([4, 5])
            )
        )
        let state = MetalVideoRenderer.makeShaderState(metadata: metadata, pixelFormatIsTenBit: true)
        XCTAssertEqual(state.uniforms.yOffset, Float(64) / 1_023, accuracy: 0.000_001)
        XCTAssertEqual(state.uniforms.yScale, Float(1_023) / 876, accuracy: 0.000_001)
        XCTAssertEqual(state.uniforms.chromaOffset, Float(512) / 1_023, accuracy: 0.000_001)
        XCTAssertEqual(state.uniforms.chromaScale, Float(1_023) / 896, accuracy: 0.000_001)
        XCTAssertEqual(state.uniforms.sampleNormalization, Float(65_535) / 65_472, accuracy: 0.000_001)
        XCTAssertEqual(state.uniforms.yuvToRGB.columns.2.x, 1.4746, accuracy: 0.000_1)
        XCTAssertEqual(state.uniforms.transfer, .pq)
        XCTAssertEqual(state.uniforms.gamut709To2020.columns.0.x, 0.627404, accuracy: 0.000_1)
        XCTAssertEqual(state.outputConfiguration.cleanAperture, metadata.cleanAperture)
        XCTAssertEqual(state.outputConfiguration.chromaLocation, metadata.chromaLocation)
        XCTAssertEqual(state.outputConfiguration.hdrStaticMetadata, metadata.hdrStaticMetadata)

        for matrix: VideoFormatMetadata.Matrix in [.bt601, .bt709, .bt2020, .identity] {
            let candidate = MetalVideoRenderer.makeShaderState(
                metadata: makeMetadata(matrix: matrix),
                pixelFormatIsTenBit: false
            )
            XCTAssertEqual(candidate.uniforms.matrixKind, matrix)
        }
        for transfer: VideoFormatMetadata.Transfer in [.bt709, .pq, .hlg, .linear] {
            let candidate = MetalVideoRenderer.makeShaderState(
                metadata: makeMetadata(transfer: transfer),
                pixelFormatIsTenBit: false
            )
            XCTAssertEqual(candidate.uniforms.transfer, transfer)
        }
    }

    func testGPUUniformABIIncludesP010NormalizationAndCleanApertureTransform() {
        let metadata = makeMetadata(
            bitDepth: 10,
            cleanAperture: CGRect(x: 4, y: 2, width: 1_912, height: 1_076)
        )
        let shaderState = MetalVideoRenderer.makeShaderState(
            metadata: metadata,
            pixelFormatIsTenBit: true
        )

        let uniforms = MetalVideoRenderer.makeGPUUniforms(
            shaderState: shaderState,
            metadata: metadata
        )

        XCTAssertEqual(MemoryLayout<MetalGPUUniforms>.stride, 144)
        XCTAssertEqual(MemoryLayout<MetalGPUUniforms>.offset(of: \.range), 96)
        XCTAssertEqual(MemoryLayout<MetalGPUUniforms>.offset(of: \.textureTransform), 112)
        XCTAssertEqual(MemoryLayout<MetalGPUUniforms>.offset(of: \.transferKind), 128)
        XCTAssertEqual(MemoryLayout<MetalGPUUniforms>.offset(of: \.applyGamutTransform), 132)
        XCTAssertEqual(uniforms.yuvColumn0.w, Float(65_535) / 65_472, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.textureTransform.x, 4.0 / 1_920, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.textureTransform.y, 2.0 / 1_080, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.textureTransform.z, 1_912.0 / 1_920, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.textureTransform.w, 1_076.0 / 1_080, accuracy: 0.000_001)
    }

    func testRenderJobCarriesColorAndHDRConfigurationToSubmission() throws {
        let metadata = makeMetadata(
            bitDepth: 10,
            range: .unknown,
            matrix: .unknown,
            transfer: .hlg,
            primaries: .unknown,
            cleanAperture: CGRect(x: 2, y: 1, width: 1_916, height: 1_078),
            chromaLocation: .init(topField: "left", bottomField: "center"),
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: Data([9, 8, 7]),
                contentLightLevelInfo: Data([6, 5])
            )
        )
        let harness = try makeHarness()
        harness.renderer.enqueue(frame(
            id: 1,
            pts: .zero,
            storage: .metalPlanes(.init(
                luma: harness.mapper.texture,
                chroma: harness.mapper.texture,
                retainedObjects: []
            )),
            metadata: metadata
        ))

        XCTAssertEqual(
            harness.renderer.draw(targetMediaTime: .zero, drawable: harness.drawable).action,
            .presented
        )
        XCTAssertEqual(harness.submitter.jobs.first?.outputConfiguration, .init(
            cleanAperture: metadata.cleanAperture,
            chromaLocation: metadata.chromaLocation,
            hdrStaticMetadata: metadata.hdrStaticMetadata
        ))
        XCTAssertEqual(harness.submitter.jobs.first?.uniforms.transferKind, 3)
        XCTAssertEqual(harness.submitter.jobs.first?.uniforms.applyGamutTransform, 0)
    }

    func testProductionShaderBundleIsPlaybackFrameworkInsteadOfHostApplication() {
        let shaderBundle = SystemMetalCommandSubmitter.shaderBundle

        XCTAssertNotEqual(shaderBundle.bundleURL, Bundle.main.bundleURL)
        XCTAssertEqual(shaderBundle.bundleURL.pathExtension, "framework")
        XCTAssertEqual(shaderBundle.bundleURL.deletingPathExtension().lastPathComponent, "VPlayerPlayback")
    }

    func testProductionSubmitterLoadsFrameworkShaderLibraryWhenToolchainIsAvailable() throws {
#if TASK8_NO_METAL_TOOLCHAIN
        XCTAssertEqual(SystemMetalCommandSubmitter.shaderBundle.bundleURL.pathExtension, "framework")
#else
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        _ = try SystemMetalCommandSubmitter(device: device)
#endif
    }

    func testCPUReferenceProducesVideoRangeBlackWhiteAndNeutral() {
        let state = MetalVideoRenderer.makeShaderState(
            metadata: makeMetadata(range: .video, matrix: .bt709, transfer: .linear),
            pixelFormatIsTenBit: false
        )
        let black = state.uniforms.referenceRGB(y: 16.0 / 255, cb: 128.0 / 255, cr: 128.0 / 255)
        let white = state.uniforms.referenceRGB(y: 235.0 / 255, cb: 128.0 / 255, cr: 128.0 / 255)
        let neutral = state.uniforms.referenceRGB(y: 126.0 / 255, cb: 128.0 / 255, cr: 128.0 / 255)
        for value in [black.x, black.y, black.z] { XCTAssertEqual(value, 0, accuracy: 0.000_1) }
        for value in [white.x, white.y, white.z] { XCTAssertEqual(value, 1, accuracy: 0.000_1) }
        XCTAssertEqual(neutral.x, neutral.y, accuracy: 0.000_1)
        XCTAssertEqual(neutral.y, neutral.z, accuracy: 0.000_1)
    }

    func testIdentityMatrixUsesGBRComponentMappingWithoutChromaCentering() {
        let state = MetalVideoRenderer.makeShaderState(
            metadata: makeMetadata(
                range: .full,
                matrix: .identity,
                transfer: .linear,
                primaries: .bt2020
            ),
            pixelFormatIsTenBit: false
        )

        let rgb = state.uniforms.referenceLinearOutput(y: 0.25, cb: 0.75, cr: 0.5)

        XCTAssertEqual(state.uniforms.chromaOffset, 0, accuracy: 0.000_001)
        XCTAssertEqual(rgb.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(rgb.y, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(rgb.z, 0.75, accuracy: 0.000_001)
    }

    func testVideoRangeIdentityNormalizesEveryGBRComponentAsLumaBeforeReordering() {
        let state = MetalVideoRenderer.makeShaderState(
            metadata: makeMetadata(
                range: .video,
                matrix: .identity,
                transfer: .linear,
                primaries: .bt2020
            ),
            pixelFormatIsTenBit: false
        )

        let rgb = state.uniforms.referenceLinearOutput(
            y: 16.0 / 255,
            cb: 235.0 / 255,
            cr: 16.0 / 255
        )

        XCTAssertEqual(rgb.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(rgb.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(rgb.z, 1, accuracy: 0.000_001)
    }

    func testHLGReferenceAppliesInverseOETFAndDisplayOOTFAtNominalPeak() {
        let state = MetalVideoRenderer.makeShaderState(
            metadata: makeMetadata(
                range: .full,
                matrix: .identity,
                transfer: .hlg,
                primaries: .bt2020
            ),
            pixelFormatIsTenBit: false
        )

        let output = state.uniforms.referenceLinearOutput(y: 0.75, cb: 0.75, cr: 0.75)

        for component in [output.x, output.y, output.z] {
            XCTAssertEqual(component, 2.031_521_6, accuracy: 0.000_01)
        }
    }

    func testVideoRenderDecisionHasFrozenPublicInitializerAndValues() {
        let decision = VideoRenderDecision(
            action: .presented,
            sourceAccessUnitID: 7,
            sequenceNumber: 8,
            droppedFrameCount: 9
        )
        XCTAssertEqual(decision.action, .presented)
        XCTAssertEqual(decision.sourceAccessUnitID, 7)
        XCTAssertEqual(decision.sequenceNumber, 8)
        XCTAssertEqual(decision.droppedFrameCount, 9)
    }

    func testMetalVideoViewConfiguresLayerAndUsesTargetPresentationTimestampAtNanosecondScale() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let clock = ViewClock()
        let renderer = ViewRenderer()
        let drawable = try FakeDrawable(device: device)
        var factoryCount = 0
        let view = MetalVideoView(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            clock: clock,
            renderer: renderer,
            device: device,
            displayLinkFactory: {
                factoryCount += 1
                return CAMetalDisplayLink(metalLayer: $0)
            }
        )
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertTrue(layer.framebufferOnly)
        XCTAssertEqual(layer.toneMapMode, .automatic)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.extendedLinearITUR_2020)

        view.render(targetPresentationTimestamp: 123.456_789_123, drawable: drawable)
        let expectedHost = CMTime(seconds: 123.456_789_123, preferredTimescale: 1_000_000_000)
        XCTAssertEqual(clock.convertedHostTimes, [expectedHost])
        XCTAssertEqual(renderer.targetTimes, [CMTime(value: 7, timescale: 1)])
    }

    func testMetalVideoViewDisplayLinkLifecycleIsIdempotentAndTeardownIsTerminal() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let clock = ViewClock()
        let renderer = ViewRenderer()
        let recorder = DisplayLinkLifecycleRecorder()
        var view: MetalVideoView? = MetalVideoView(
            frame: .zero,
            clock: clock,
            renderer: renderer,
            device: device,
            lifecycle: .init(
                add: { recorder.operations.append("add:\($2.rawValue)") },
                remove: { recorder.operations.append("remove:\($2.rawValue)") },
                invalidate: { _ in recorder.operations.append("invalidate") }
            )
        )
        XCTAssertEqual(recorder.operations, ["add:kCFRunLoopCommonModes"])
        view?.pauseDisplayLink()
        view?.pauseDisplayLink()
        XCTAssertTrue(view?.displayLink.isPaused == true)
        view?.resumeDisplayLink()
        view?.resumeDisplayLink()
        XCTAssertTrue(view?.displayLink.isPaused == false)

        view?.teardown()
        view?.teardown()
        view?.resumeDisplayLink()
        XCTAssertTrue(view?.displayLink.isPaused == true)
        view = nil
        XCTAssertEqual(recorder.operations, [
            "add:kCFRunLoopCommonModes",
            "remove:kCFRunLoopCommonModes",
            "invalidate",
        ])
    }

    private func makeHarness(metrics: PlaybackMetrics? = nil) throws -> RendererHarness {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mapper = try FakeTextureMapper(device: device)
        let submitter = FakeCommandSubmitter()
        let failures = FailureRecorder()
        let renderer = try MetalVideoRenderer(
            device: device,
            generation: generation,
            textureMapperFactory: { _ in mapper },
            commandSubmitter: submitter,
            metrics: metrics,
            failureSink: { failures.append(error: $0, generation: $1) }
        )
        return RendererHarness(
            renderer: renderer,
            mapper: mapper,
            submitter: submitter,
            failures: failures,
            drawable: try FakeDrawable(device: device)
        )
    }

    private func makeBiPlanarPixelBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func frame(
        id: UInt64,
        pts: CMTime,
        generation: MediaGeneration? = nil,
        storage: VideoFrameStorage,
        metadata: VideoFormatMetadata? = nil
    ) -> VideoPresentationFrame {
        VideoPresentationFrame(
            storage: storage,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 25),
            generation: generation ?? self.generation,
            sequenceNumber: id,
            sourceAccessUnitID: id,
            formatMetadata: metadata ?? makeMetadata()
        )
    }

    private func makeMetadata(
        bitDepth: Int = 8,
        range: VideoFormatMetadata.Range = .video,
        matrix: VideoFormatMetadata.Matrix = .bt709,
        transfer: VideoFormatMetadata.Transfer = .bt709,
        primaries: VideoFormatMetadata.Primaries = .bt709,
        cleanAperture: CGRect? = nil,
        chromaLocation: VideoFormatMetadata.ChromaLocation = .init(topField: nil, bottomField: nil),
        hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata = .init(
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil
        )
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: 1_920, height: 1_080),
            bitDepth: bitDepth,
            range: range,
            matrix: matrix,
            transfer: transfer,
            primaries: primaries,
            cleanAperture: cleanAperture,
            chromaLocation: chromaLocation,
            hdrStaticMetadata: hdrStaticMetadata
        )
    }
}

private struct RendererHarness {
    let renderer: MetalVideoRenderer
    let mapper: FakeTextureMapper
    let submitter: FakeCommandSubmitter
    let failures: FailureRecorder
    let drawable: FakeDrawable
}

private enum FakeMetalError: Error {
    case failed
}

private final class FakeTextureMapper: VideoTextureMapping, @unchecked Sendable {
    let texture: any MTLTexture
    var failurePoint: Int?
    var beforeReturn: (() -> Void)?
    private(set) var requests: [[VideoTexturePlaneRequest]] = []
    private(set) var processedPlaneCounts: [Int] = []
    private(set) var flushCount = 0

    init(device: any MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func map(
        pixelBuffer: CVPixelBuffer,
        requests: [VideoTexturePlaneRequest]
    ) throws -> MappedVideoTextures {
        self.requests.append(requests)
        var processedPlaneCount = 0
        for index in requests.indices {
            if failurePoint == index {
                processedPlaneCounts.append(processedPlaneCount)
                throw FakeMetalError.failed
            }
            processedPlaneCount += 1
        }
        processedPlaneCounts.append(processedPlaneCount)
        beforeReturn?()
        return MappedVideoTextures(luma: texture, chroma: texture, retainedObjects: [])
    }

    func flush() {
        flushCount += 1
    }
}

private final class FakeCommandSubmitter: MetalCommandSubmitting, @unchecked Sendable {
    private var completions: [@Sendable (MetalCommandCompletion) -> Void] = []
    private(set) var jobs: [MetalRenderJob] = []
    private(set) var usedOnlyUntimedPresentation = true
    var submitCount: Int { jobs.count }

    func submitPresentingUntimed(
        _ job: MetalRenderJob,
        drawable: any CAMetalDrawable,
        completion: @escaping @Sendable (MetalCommandCompletion) -> Void
    ) throws {
        jobs.append(job)
        completions.append(completion)
    }

    func completeFirst(_ result: MetalCommandCompletion) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(result)
    }
}

private final class FailureRecorder: @unchecked Sendable {
    struct Entry {
        let error: PlaybackCoreError
        let generation: MediaGeneration
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var snapshot: [Entry] { lock.withLock { entries } }
    func append(error: PlaybackCoreError, generation: MediaGeneration) {
        lock.withLock { entries.append(.init(error: error, generation: generation)) }
    }
}

private final class LifetimeProbe {}

private final class FakeDrawable: NSObject, CAMetalDrawable, @unchecked Sendable {
    let texture: any MTLTexture
    let layer: CAMetalLayer
    let presentedTime: CFTimeInterval = 0
    let drawableID: Int = 1

    init(device: any MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 2,
            height: 2,
            mipmapped: false
        )
        texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        layer = CAMetalLayer()
        super.init()
    }

    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}

private final class ViewClock: PlaybackClock {
    var currentTime: CMTime = .zero
    private(set) var convertedHostTimes: [CMTime] = []
    func mediaTime(forHostTime hostTime: CMTime) -> CMTime {
        convertedHostTimes.append(hostTime)
        return CMTime(value: 7, timescale: 1)
    }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {}
}

private final class ViewRenderer: VideoRendering {
    private(set) var targetTimes: [CMTime] = []
    func enqueue(_ frame: VideoPresentationFrame) {}
    func flush(to generation: MediaGeneration) {}
    func draw(targetMediaTime: CMTime, drawable: any CAMetalDrawable) -> VideoRenderDecision {
        targetTimes.append(targetMediaTime)
        return .init(action: .noFrame, sourceAccessUnitID: nil, sequenceNumber: nil, droppedFrameCount: 0)
    }
}

private final class DisplayLinkLifecycleRecorder {
    var operations: [String] = []
}

private final class DecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VideoRenderDecision?

    var value: VideoRenderDecision? { lock.withLock { stored } }

    func set(_ value: VideoRenderDecision) {
        lock.withLock { stored = value }
    }
}
