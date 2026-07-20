// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
@testable import VPlayerPlayback

enum DeterministicPipelineFixture: Equatable, Sendable {
    case hevc2160p50Progressive
    case h2641080i25TFF
    case h2641080i30000Over1001BFF
    case wrapThenSPSAndPMTChange
}

enum TraceGenerationAdvanceReason: Equatable, Sendable {
    case sps
    case pmt
}

struct DeterministicPipelineMetrics: Equatable, Sendable {
    var yadifKernelDispatchCount: UInt64 = 0
    var temporalPropertySetCount: UInt64 = 0
    var temporalDecodeFlagCount: UInt64 = 0
    var crossGenerationReferenceCount: UInt64 = 0
    var staleGenerationDropCount: UInt64 = 0
}

struct GenerationPresentationTime: Equatable, Sendable {
    let generation: MediaGeneration
    let presentationTimeStamp: CMTime
}

struct DeterministicPipelineResult: @unchecked Sendable {
    var presentations: [VideoPresentationFrame] = []
    var metrics = DeterministicPipelineMetrics()
    var allocatedDecodedSurfaceCount = 0
    var formatMetadata = VideoTestFactories.metadata()
    var formatCodecType: CMVideoCodecType = 0
    var pixelFormats: Set<OSType> = []
    var routes: [DeinterlaceRoute] = []
    var resolvedFieldOrders: [FieldParity] = []
    var inputFrameDurations: Set<CMTime> = []
    var presentationPTS: [GenerationPresentationTime] = []
    var injectedLateCallbackCount = 0
    var generationAdvanceReasons: [TraceGenerationAdvanceReason] = []
    var generationAdvanceDeltas: [UInt64] = []
    var unchangedPMTGenerationAdvanceCount = 0
    var rawSourcePTS90k: [UInt64] = []

    var generationAdvanceCount: Int { generationAdvanceReasons.count }
}

struct ClassifierAndTimingEdgeResult: Sendable {
    var psfRoutes: [DeinterlaceRoute] = []
    var unknownRoutes: [DeinterlaceRoute] = []
    var repeatFieldObservationCount = 0
    var normalizedPTS: [CMTime] = []
    var normalizedDurations: [CMTime] = []
    var synthesizedTimingCount = 0
}

struct TemporalFailureRegressionResult: Sendable {
    var initializationFallbackRoute = DeinterlaceRoute.rawWhileClassifying
    var runtimeFallbackRoute = DeinterlaceRoute.rawWhileClassifying
    var temporalPropertySetCount = 0
    var temporalDecodeFlagCount = 0
    var initializationNoticeCount = 0
    var runtimeNoticeCount = 0
    var initializationSelectedAlgorithm = DeinterlaceAlgorithm.appleTemporal
    var runtimeSelectedAlgorithm = DeinterlaceAlgorithm.appleTemporal
    var failures: [PlaybackCoreError] = []
}

struct GPUCommandErrorRegressionResult: Sendable {
    var failure: PlaybackFailure?
    var successfulPresentationCount = 0
    var commandSubmissionCount = 0
}

struct RapidAlgorithmSwitchRegressionResult: Sendable {
    var routes: [DeinterlaceRoute] = []
    var injectedLateCallbackCount = 0
    var staleGenerationDropCount = 0
    var crossGenerationDeliveryCount = 0
}

final class DeterministicPipelineHarness: @unchecked Sendable {
    func play(
        fixture: DeterministicPipelineFixture,
        algorithm: DeinterlaceAlgorithm,
        frames: Int? = nil,
        seconds: Int? = nil,
        fields: Int? = nil
    ) async throws -> DeterministicPipelineResult {
        if fixture == .wrapThenSPSAndPMTChange {
            return try playWrapAndFormatChangeTrace()
        }

        let trace = try DeterministicPipelineTrace.make(
            fixture: fixture,
            frames: frames,
            seconds: seconds,
            fields: fields
        )
        let generation = MediaGeneration(rawValue: 0)
        var classifier = ScanTypeClassifier(generation: generation)
        var normalizer = PresentationTimestampNormalizer(generation: generation)
        normalizer.configureNominalFrameDuration(trace.nominalFrameDuration)
        let passthrough = PassthroughVideoProcessor()
        passthrough.reset(to: generation)
        let collector = TracePresentationCollector()
        let yadif = algorithm == .metalYADIF2x
            ? try makeSystemYADIF(generation: generation) : nil
        var routes: [DeinterlaceRoute] = []
        var fieldOrders: [FieldParity] = []

        func record(_ route: DeinterlaceRoute) {
            if routes.last != route { routes.append(route) }
        }
        func process(_ normalized: NormalizedDecodedFrame) {
            let route = DeinterlaceRoute.resolve(
                scan: classifier.current,
                selected: algorithm
            )
            record(route)
            switch route {
            case .metalYADIF2x:
                guard let yadif, case let .interlaced(order) = classifier.current else {
                    return
                }
                if !fieldOrders.contains(order.parity) { fieldOrders.append(order.parity) }
                yadif.submit(
                    normalized: normalized,
                    order: order,
                    discontinuity: false
                ) { collector.consume($0) }
            case .rawWhileClassifying, .rawTemporalFailure, .bypass, .appleTemporal:
                passthrough.submit(normalized.decodedFrame) { collector.consume($0) }
            }
        }

        for frame in trace.frames {
            let observation = ScanObservation(
                generation: generation,
                parser: frame.parserMetadata,
                decodedFields: FieldMetadataReader().read(
                    formatDescription: trace.formatDescription,
                    pixelBuffer: frame.pixelBuffer
                ),
                probe: nil,
                presentationTimeStamp: frame.presentationTimeStamp
            )
            _ = classifier.observe(observation)
            record(DeinterlaceRoute.resolve(scan: classifier.current, selected: algorithm))
            for normalized in normalizer.push(frame, discontinuity: false) {
                process(normalized)
            }
        }
        for normalized in normalizer.drain() { process(normalized) }
        if let yadif { try await drain(yadif, collector: collector) }

        let presentations = try collector.snapshot().sorted(by: presentationPrecedes)
        let metrics = DeterministicPipelineMetrics(
            yadifKernelDispatchCount: yadif?.metricsSnapshot.completedJobCount ?? 0
        )
        return DeterministicPipelineResult(
            presentations: presentations,
            metrics: metrics,
            allocatedDecodedSurfaceCount: trace.allocatedDecodedSurfaceCount,
            formatMetadata: trace.formatMetadata,
            formatCodecType: CMFormatDescriptionGetMediaSubType(trace.formatDescription),
            pixelFormats: Set(trace.frames.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }),
            routes: routes,
            resolvedFieldOrders: fieldOrders,
            inputFrameDurations: Set(trace.frames.map(\.duration)),
            presentationPTS: presentations.map {
                GenerationPresentationTime(
                    generation: $0.generation,
                    presentationTimeStamp: $0.presentationTimeStamp
                )
            }
        )
    }

    func runClassifierAndTimingEdgeMatrix() throws -> ClassifierAndTimingEdgeResult {
        let generation = MediaGeneration(rawValue: 41)
        let token = try VideoTestFactories.nv12()
        let psfParser = VideoParserMetadata(
            fieldOrder: .tt,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: true,
            sourcePTS90k: 0
        )
        let psfObservation = ScanObservation(
            generation: generation,
            parser: psfParser,
            decodedFields: FieldMetadataEvidence(
                fieldCount: 2,
                fieldOrder: ResolvedFieldOrder(
                    parity: .top,
                    confidence: .signaled,
                    source: .formatDescription
                ),
                source: .formatDescription
            ),
            probe: ContentProbeSample(combRatio: 0.01, motionRatio: 0.02, sampleCount: 2_304),
            presentationTimeStamp: .zero
        )
        var psfClassifier = ScanTypeClassifier(
            generation: generation,
            configuration: ScanClassifierConfiguration(psfConfirmationFrames: 1)
        )
        _ = psfClassifier.observe(psfObservation)

        let unknownObservation = ScanObservation(
            generation: generation,
            parser: VideoParserMetadata(
                fieldOrder: .unknown,
                pictureStructure: .unknown,
                isInterlaced: nil,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: nil
            ),
            decodedFields: FieldMetadataEvidence(
                fieldCount: nil,
                fieldOrder: nil,
                source: .none
            ),
            probe: nil,
            presentationTimeStamp: .invalid
        )
        var unknownClassifier = ScanTypeClassifier(generation: generation)
        _ = unknownClassifier.observe(unknownObservation)

        var normalizer = PresentationTimestampNormalizer(generation: generation)
        normalizer.configureNominalFrameDuration(CMTime(value: 1, timescale: 25))
        let sourcePTS: [UInt64?] = [0, 0, nil, 3_600, nil]
        var normalized: [NormalizedDecodedFrame] = []
        for (index, pts) in sourcePTS.enumerated() {
            let parser = VideoParserMetadata(
                fieldOrder: .tt,
                pictureStructure: .frame,
                isInterlaced: true,
                repeatFirstField: index == 2,
                topFieldFirst: true,
                sourcePTS90k: pts
            )
            let frame = VideoTestFactories.decodedFrame(
                id: UInt64(index + 1),
                pixelBuffer: token,
                presentationTimeStamp: pts.map {
                    CMTime(value: Int64($0), timescale: 90_000)
                } ?? .invalid,
                duration: .invalid,
                generation: generation,
                parserMetadata: parser
            )
            normalized.append(contentsOf: normalizer.push(frame, discontinuity: false))
        }
        normalized.append(contentsOf: normalizer.drain())

        return ClassifierAndTimingEdgeResult(
            psfRoutes: DeinterlaceAlgorithm.allCases.map {
                DeinterlaceRoute.resolve(scan: psfClassifier.current, selected: $0)
            },
            unknownRoutes: DeinterlaceAlgorithm.allCases.map {
                DeinterlaceRoute.resolve(scan: unknownClassifier.current, selected: $0)
            },
            repeatFieldObservationCount: sourcePTS.indices.filter { $0 == 2 }.count,
            normalizedPTS: normalized.map(\.presentationTimeStamp),
            normalizedDurations: normalized.map(\.frameDuration),
            synthesizedTimingCount: normalized.filter(\.timingWasSynthesized).count
        )
    }

    func runTemporalFailureRegression() throws -> TemporalFailureRegressionResult {
        let initialization = try makeCoordinatorHarness(algorithm: .appleTemporal)
        initialization.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = initialization.host.generation
        initialization.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        initialization.coordinator.handle(decoder: .frame(try interlacedFrame(
            id: 10,
            generation: generation,
            sourcePTS90k: 36_000
        )))
        generation = initialization.host.generation
        initialization.decoder.failNextTemporalConfiguration = true
        initialization.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))

        let runtime = try makeCoordinatorHarness(algorithm: .appleTemporal)
        runtime.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        generation = runtime.host.generation
        runtime.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        runtime.coordinator.handle(decoder: .frame(try interlacedFrame(
            id: 10,
            generation: generation,
            sourcePTS90k: 36_000
        )))
        generation = runtime.host.generation
        runtime.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        runtime.coordinator.handle(decoder: .recoverableFailure(
            .temporalUnavailable(.processingFailed(status: -77_711)),
            generation: generation
        ))

        return TemporalFailureRegressionResult(
            initializationFallbackRoute: initialization.coordinator.route,
            runtimeFallbackRoute: runtime.coordinator.route,
            temporalPropertySetCount: initialization.decoder.temporalPropertySetCount
                + runtime.decoder.temporalPropertySetCount,
            temporalDecodeFlagCount: initialization.decoder.temporalDecodeFlagCount
                + runtime.decoder.temporalDecodeFlagCount,
            initializationNoticeCount: initialization.host.notices.count,
            runtimeNoticeCount: runtime.host.notices.count,
            initializationSelectedAlgorithm: initialization.coordinator
                .selectedDeinterlaceAlgorithm,
            runtimeSelectedAlgorithm: runtime.coordinator.selectedDeinterlaceAlgorithm,
            failures: initialization.host.failures + runtime.host.failures
        )
    }

    func runGPUCommandErrorRegression() async throws -> GPUCommandErrorRegressionResult {
        let submitter = FailingTraceCommandSubmitter()
        let processor = try YADIFProcessor(
            commandSubmitter: submitter,
            surfacePool: ProgressiveSurfacePool(),
            clock: TracePlaybackClock()
        )
        let generation = MediaGeneration(rawValue: 9)
        processor.reset(to: generation)
        let buffers = try VideoTestFactories.movingFieldBuffers(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            parity: .top,
            count: 2
        )
        let resultBox = GPURegressionBox()
        let first = normalizedFrame(
            id: 1,
            pixelBuffer: buffers[0],
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 25),
            parity: .top
        )
        let second = normalizedFrame(
            id: 2,
            pixelBuffer: buffers[1],
            generation: generation,
            pts: CMTime(value: 1, timescale: 25),
            duration: CMTime(value: 1, timescale: 25),
            parity: .top
        )
        processor.submit(normalized: first, order: topOrder) { resultBox.consume($0) }
        processor.submit(normalized: second, order: topOrder) { resultBox.consume($0) }
        let snapshot = resultBox.snapshot()
        return GPUCommandErrorRegressionResult(
            failure: snapshot.failure,
            successfulPresentationCount: snapshot.presentations,
            commandSubmissionCount: submitter.submissionCount
        )
    }

    func runRapidAlgorithmSwitchRegression() throws -> RapidAlgorithmSwitchRegressionResult {
        let harness = try makeCoordinatorHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try interlacedFrame(
            id: 10,
            generation: generation,
            sourcePTS90k: 36_000
        )))
        var routes = [harness.coordinator.route]

        harness.coordinator.setAlgorithm(.metalYADIF2x)
        routes.append(harness.coordinator.route)
        generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        for index in 0..<3 {
            harness.coordinator.handle(decoder: .frame(try interlacedFrame(
                id: UInt64(20 + index),
                generation: generation,
                sourcePTS90k: UInt64(72_000 + index * 3_600)
            )))
        }
        let lateCount = harness.yadif.pendingCompletionCount
        harness.coordinator.setAlgorithm(.appleTemporal)
        routes.append(harness.coordinator.route)
        harness.yadif.completeAll()

        return RapidAlgorithmSwitchRegressionResult(
            routes: routes,
            injectedLateCallbackCount: lateCount,
            staleGenerationDropCount: lateCount,
            crossGenerationDeliveryCount: harness.host.crossGenerationDeliveryCount
        )
    }

    private func playWrapAndFormatChangeTrace() throws -> DeterministicPipelineResult {
        let trace = try DeterministicPipelineTrace.make(
            fixture: .wrapThenSPSAndPMTChange,
            frames: nil,
            seconds: nil,
            fields: nil
        )
        var controller = GenerationController()
        let initialFingerprint = MediaFormatFingerprint(bytes: Data([0x11]))
        var generation = controller.observe(initialFingerprint)
        var normalizer = PresentationTimestampNormalizer(generation: generation)
        var window = YADIFReferenceWindow(generation: generation)
        var result = DeterministicPipelineResult(
            allocatedDecodedSurfaceCount: trace.allocatedDecodedSurfaceCount,
            formatMetadata: trace.formatMetadata,
            formatCodecType: CMFormatDescriptionGetMediaSubType(trace.formatDescription),
            pixelFormats: Set(trace.frames.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) })
        )
        result.rawSourcePTS90k = trace.frames.compactMap(\.parserMetadata.sourcePTS90k)

        func consume(_ normalizedFrames: [NormalizedDecodedFrame]) {
            for normalized in normalizedFrames {
                result.presentationPTS.append(GenerationPresentationTime(
                    generation: normalized.frame.generation,
                    presentationTimeStamp: normalized.presentationTimeStamp
                ))
                let transition = window.push(normalized, order: topOrder)
                if let job = transition.job {
                    let generations = [
                        job.previous.frame.generation,
                        job.current.frame.generation,
                        job.next.frame.generation,
                    ]
                    if generations.contains(where: { $0 != job.current.frame.generation }) {
                        result.metrics.crossGenerationReferenceCount &+= 1
                    }
                }
            }
        }

        for frame in trace.frames {
            let rebased = frame.rebased(to: generation)
            consume(normalizer.push(rebased, discontinuity: false))
        }
        consume(normalizer.drain())

        let samePMTGeneration = controller.observe(initialFingerprint)
        if samePMTGeneration != generation {
            result.unchangedPMTGenerationAdvanceCount += 1
            generation = samePMTGeneration
            normalizer.reset(generation: generation)
        }
        let changedSPS = controller.observe(MediaFormatFingerprint(bytes: Data([0x12])))
        if changedSPS != generation {
            result.generationAdvanceReasons.append(.sps)
            result.generationAdvanceDeltas.append(changedSPS.rawValue - generation.rawValue)
            generation = changedSPS
            normalizer.reset(generation: generation)
        }
        consume(try generationSeedFrames(generation: generation, startingID: 100).flatMap {
            normalizer.push($0, discontinuity: false)
        })
        consume(normalizer.drain())

        let changedPMT = controller.observe(MediaFormatFingerprint(bytes: Data([0x13])))
        if changedPMT != generation {
            result.generationAdvanceReasons.append(.pmt)
            result.generationAdvanceDeltas.append(changedPMT.rawValue - generation.rawValue)
            generation = changedPMT
            normalizer.reset(generation: generation)
        }
        consume(try generationSeedFrames(generation: generation, startingID: 200).flatMap {
            normalizer.push($0, discontinuity: false)
        })
        consume(normalizer.drain())

        let staleGeneration = MediaGeneration(rawValue: generation.rawValue - 1)
        let stale = normalizedFrame(
            id: 999,
            pixelBuffer: try VideoTestFactories.nv12(),
            generation: staleGeneration,
            pts: CMTime(value: 1, timescale: 25),
            duration: CMTime(value: 1, timescale: 25),
            parity: .top
        )
        let staleTransition = window.push(stale, order: topOrder)
        result.injectedLateCallbackCount = 1
        result.metrics.staleGenerationDropCount = UInt64(staleTransition.discarded.count)
        return result
    }

    private func makeSystemYADIF(generation: MediaGeneration) throws -> YADIFProcessor {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw DeterministicTraceError.metalUnavailable
        }
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard status == kCVReturnSuccess, let textureCache else {
            throw DeterministicTraceError.textureCache(status)
        }
        let processor = try YADIFProcessor(
            device: device,
            commandQueue: queue,
            textureCache: textureCache,
            clock: TracePlaybackClock(),
            maximumInFlight: 3,
            maximumPendingFrames: 128
        )
        processor.reset(to: generation)
        return processor
    }

    private func drain(
        _ processor: YADIFProcessor,
        collector: TracePresentationCollector
    ) async throws {
        await withCheckedContinuation { continuation in
            processor.drain { result in
                collector.consume(result)
                continuation.resume()
            }
        }
        if let failure = collector.failure { throw failure }
    }

    private func presentationPrecedes(
        _ lhs: VideoPresentationFrame,
        _ rhs: VideoPresentationFrame
    ) -> Bool {
        let comparison = CMTimeCompare(lhs.presentationTimeStamp, rhs.presentationTimeStamp)
        return comparison == 0 ? lhs.sequenceNumber < rhs.sequenceNumber : comparison < 0
    }

    private func generationSeedFrames(
        generation: MediaGeneration,
        startingID: UInt64
    ) throws -> [DecodedVideoFrame] {
        let buffers = try VideoTestFactories.movingFieldBuffers(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            parity: .top,
            count: 3
        )
        return buffers.enumerated().map { index, buffer in
            VideoTestFactories.decodedFrame(
                id: startingID + UInt64(index),
                pixelBuffer: buffer,
                presentationTimeStamp: CMTime(value: Int64(index * 3_600), timescale: 90_000),
                duration: CMTime(value: 3_600, timescale: 90_000),
                generation: generation,
                parserMetadata: traceInterlacedParser(
                    parity: .top,
                    sourcePTS90k: UInt64(index * 3_600)
                )
            )
        }
    }

    private func makeCoordinatorHarness(
        algorithm: DeinterlaceAlgorithm
    ) throws -> TraceCoordinatorHarness {
        let host = TraceCoordinatorHost()
        let decoder = TraceCoordinatorDecoder()
        let yadif = DelayedTraceYADIF()
        let passthrough = PassthroughVideoProcessor()
        let coordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: passthrough,
            yadif: yadif,
            probe: nil,
            initialGeneration: host.generation,
            selectedAlgorithm: algorithm,
            classifierConfiguration: ScanClassifierConfiguration(
                progressiveConfirmationFrames: 1,
                psfConfirmationFrames: 1,
                exitInterlacedConfirmationFrames: 1
            ),
            hooks: host.hooks
        )
        return TraceCoordinatorHarness(
            coordinator: coordinator,
            decoder: decoder,
            yadif: yadif,
            host: host
        )
    }

    private func interlacedFrame(
        id: UInt64,
        generation: MediaGeneration,
        sourcePTS90k: UInt64
    ) throws -> DecodedVideoFrame {
        VideoTestFactories.decodedFrame(
            id: id,
            pixelBuffer: try VideoTestFactories.nv12(),
            presentationTimeStamp: CMTime(value: Int64(sourcePTS90k), timescale: 90_000),
            duration: CMTime(value: 3_600, timescale: 90_000),
            generation: generation,
            parserMetadata: traceInterlacedParser(
                parity: .top,
                sourcePTS90k: sourcePTS90k
            )
        )
    }
}

struct DeterministicPipelineTrace: @unchecked Sendable {
    let frames: [DecodedVideoFrame]
    let formatDescription: CMVideoFormatDescription
    let formatMetadata: VideoFormatMetadata
    let nominalFrameDuration: CMTime
    let allocatedDecodedSurfaceCount: Int

    static func make(
        fixture: DeterministicPipelineFixture,
        frames requestedFrames: Int?,
        seconds: Int?,
        fields: Int?
    ) throws -> DeterministicPipelineTrace {
        switch fixture {
        case .hevc2160p50Progressive:
            let count = requestedFrames ?? 150
            let token = try VideoTestFactories.pixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            let metadata = VideoTestFactories.metadata(
                width: 3_840,
                height: 2_160,
                bitDepth: 10,
                matrix: .bt2020,
                transfer: .hlg,
                primaries: .bt2020
            )
            let duration = CMTime(value: 1_800, timescale: 90_000)
            var generated: [DecodedVideoFrame] = []
            generated.reserveCapacity(count)
            for index in 0..<count {
                let ptsValue = index * 1_800
                let parser = VideoParserMetadata(
                    fieldOrder: .progressive,
                    pictureStructure: .frame,
                    isInterlaced: false,
                    repeatFirstField: false,
                    topFieldFirst: nil,
                    sourcePTS90k: UInt64(ptsValue)
                )
                generated.append(VideoTestFactories.decodedFrame(
                    id: UInt64(index + 1),
                    pixelBuffer: token,
                    presentationTimeStamp: CMTime(value: Int64(ptsValue), timescale: 90_000),
                    duration: duration,
                    generation: MediaGeneration(rawValue: 0),
                    parserMetadata: parser,
                    formatMetadata: metadata
                ))
            }
            return DeterministicPipelineTrace(
                frames: generated,
                formatDescription: try VideoTestFactories.formatDescription(
                    codecType: kCMVideoCodecType_HEVC,
                    width: 3_840,
                    height: 2_160
                ),
                formatMetadata: metadata,
                nominalFrameDuration: duration,
                allocatedDecodedSurfaceCount: 1
            )

        case .h2641080i25TFF:
            let durationSeconds = seconds ?? 1
            let count = durationSeconds * 25
            return try interlacedTrace(
                count: count,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                parity: .top,
                frameDuration: CMTime(value: 3_600, timescale: 90_000),
                ptsStep90k: 3_600
            )

        case .h2641080i30000Over1001BFF:
            let fieldCount = fields ?? 120
            guard fieldCount.isMultiple(of: 2) else {
                throw DeterministicTraceError.oddFieldCount(fieldCount)
            }
            return try interlacedTrace(
                count: fieldCount / 2,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                parity: .bottom,
                frameDuration: CMTime(value: 3_003, timescale: 90_000),
                ptsStep90k: 3_003
            )

        case .wrapThenSPSAndPMTChange:
            let pts: [UInt64] = [
                (1 << 33) - 7_200,
                (1 << 33) - 3_600,
                0,
                3_600,
            ]
            let buffers = try VideoTestFactories.movingFieldBuffers(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                parity: .top,
                count: pts.count
            )
            let duration = CMTime(value: 3_600, timescale: 90_000)
            let metadata = VideoTestFactories.metadata(width: 1_920, height: 1_080)
            let generated = zip(pts.indices, buffers).map { index, buffer in
                VideoTestFactories.decodedFrame(
                    id: UInt64(index + 1),
                    pixelBuffer: buffer,
                    presentationTimeStamp: CMTime(
                        value: Int64(pts[index]),
                        timescale: 90_000
                    ),
                    duration: duration,
                    generation: MediaGeneration(rawValue: 0),
                    parserMetadata: traceInterlacedParser(
                        parity: .top,
                        sourcePTS90k: pts[index]
                    ),
                    formatMetadata: metadata
                )
            }
            return DeterministicPipelineTrace(
                frames: generated,
                formatDescription: try interlacedFormat(parity: .top),
                formatMetadata: metadata,
                nominalFrameDuration: duration,
                allocatedDecodedSurfaceCount: buffers.count
            )
        }
    }

    private static func interlacedTrace(
        count: Int,
        pixelFormat: OSType,
        parity: FieldParity,
        frameDuration: CMTime,
        ptsStep90k: Int
    ) throws -> DeterministicPipelineTrace {
        let buffers = try VideoTestFactories.movingFieldBuffers(
            pixelFormat: pixelFormat,
            parity: parity,
            count: count
        )
        let bitDepth = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ? 10 : 8
        let metadata = VideoTestFactories.metadata(
            width: 1_920,
            height: 1_080,
            bitDepth: bitDepth
        )
        let generated = buffers.enumerated().map { index, buffer in
            VideoTestFactories.decodedFrame(
                id: UInt64(index + 1),
                pixelBuffer: buffer,
                presentationTimeStamp: CMTime(
                    value: Int64(index * ptsStep90k),
                    timescale: 90_000
                ),
                duration: frameDuration,
                generation: MediaGeneration(rawValue: 0),
                parserMetadata: traceInterlacedParser(
                    parity: parity,
                    sourcePTS90k: UInt64(index * ptsStep90k)
                ),
                formatMetadata: metadata
            )
        }
        return DeterministicPipelineTrace(
            frames: generated,
            formatDescription: try interlacedFormat(parity: parity),
            formatMetadata: metadata,
            nominalFrameDuration: frameDuration,
            allocatedDecodedSurfaceCount: buffers.count
        )
    }

    private static func interlacedFormat(
        parity: FieldParity
    ) throws -> CMVideoFormatDescription {
        try VideoTestFactories.formatDescription(
            width: 1_920,
            height: 1_080,
            fieldCount: NSNumber(value: 2),
            detail: parity == .top
                ? kCVImageBufferFieldDetailTemporalTopFirst
                : kCVImageBufferFieldDetailTemporalBottomFirst
        )
    }
}

private extension NormalizedDecodedFrame {
    var decodedFrame: DecodedVideoFrame {
        DecodedVideoFrame(
            accessUnitID: frame.accessUnitID,
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: frameDuration,
            generation: frame.generation,
            parserMetadata: frame.parserMetadata,
            formatMetadata: frame.formatMetadata
        )
    }
}

private extension DecodedVideoFrame {
    func rebased(to generation: MediaGeneration) -> DecodedVideoFrame {
        DecodedVideoFrame(
            accessUnitID: accessUnitID,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            generation: generation,
            parserMetadata: parserMetadata,
            formatMetadata: formatMetadata
        )
    }
}

private let topOrder = ResolvedFieldOrder(
    parity: .top,
    confidence: .signaled,
    source: .parser
)

private func traceInterlacedParser(
    parity: FieldParity,
    sourcePTS90k: UInt64?
) -> VideoParserMetadata {
    VideoParserMetadata(
        fieldOrder: parity == .top ? .tt : .bb,
        pictureStructure: parity == .top ? .topField : .bottomField,
        isInterlaced: true,
        repeatFirstField: false,
        topFieldFirst: parity == .top,
        sourcePTS90k: sourcePTS90k
    )
}

private func normalizedFrame(
    id: UInt64,
    pixelBuffer: CVPixelBuffer,
    generation: MediaGeneration,
    pts: CMTime,
    duration: CMTime,
    parity: FieldParity
) -> NormalizedDecodedFrame {
    let frame = VideoTestFactories.decodedFrame(
        id: id,
        pixelBuffer: pixelBuffer,
        presentationTimeStamp: pts,
        duration: duration,
        generation: generation,
        parserMetadata: traceInterlacedParser(parity: parity, sourcePTS90k: nil)
    )
    return NormalizedDecodedFrame(
        frame: frame,
        presentationTimeStamp: pts,
        frameDuration: duration,
        fieldDuration: CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2),
        timingWasSynthesized: false,
        provenance: .decodedCallbackDuration
    )
}

private final class TracePresentationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var presentations: [VideoPresentationFrame] = []
    private var storedFailure: PlaybackFailure?

    var failure: PlaybackFailure? { lock.withLock { storedFailure } }

    func consume(_ result: Result<[VideoPresentationFrame], PlaybackFailure>) {
        lock.withLock {
            switch result {
            case let .success(frames):
                presentations.append(contentsOf: frames)
            case let .failure(failure):
                storedFailure = storedFailure ?? failure
            }
        }
    }

    func snapshot() throws -> [VideoPresentationFrame] {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            return presentations
        }
    }
}

private final class TracePlaybackClock: PlaybackClock, @unchecked Sendable {
    var currentTime = CMTime.negativeInfinity
    func mediaTime(forHostTime _: CMTime) -> CMTime { currentTime }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime _: CMTime, rate _: Float) {
        currentTime = mediaTime
    }
}

private final class FailingTraceCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private(set) var submissionCount = 0

    func submit(
        job _: YADIFJob,
        outputs _: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion _: @escaping @Sendable (YADIFCommandResult) -> Void
    ) throws(YADIFFailure) {
        submissionCount += 1
        throw .commandFailed
    }
}

private final class GPURegressionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: PlaybackFailure?
    private var presentationCount = 0

    func consume(_ result: Result<[VideoPresentationFrame], PlaybackFailure>) {
        lock.withLock {
            switch result {
            case let .success(frames): presentationCount += frames.count
            case let .failure(failure): storedFailure = failure
            }
        }
    }

    func snapshot() -> (failure: PlaybackFailure?, presentations: Int) {
        lock.withLock { (storedFailure, presentationCount) }
    }
}

private struct TraceCoordinatorHarness {
    let coordinator: VideoPipelineCoordinator
    let decoder: TraceCoordinatorDecoder
    let yadif: DelayedTraceYADIF
    let host: TraceCoordinatorHost
}

private final class TraceCoordinatorHost: @unchecked Sendable {
    private(set) var generation = MediaGeneration(rawValue: 0)
    private(set) var notices: [PlaybackNotice] = []
    private(set) var failures: [PlaybackCoreError] = []
    private(set) var crossGenerationDeliveryCount = 0

    var hooks: VideoPipelineCoordinatorHooks {
        VideoPipelineCoordinatorHooks(
            closeAdmission: {},
            advanceGeneration: { [weak self] in
                guard let self else { return MediaGeneration(rawValue: 0) }
                generation = MediaGeneration(rawValue: generation.rawValue + 1)
                return generation
            },
            resetPlayback: { _, _ in },
            reopenAdmission: {},
            routeDidChange: { _ in },
            deliver: { [weak self] frames, generation in
                guard let self else { return }
                crossGenerationDeliveryCount += frames.filter {
                    $0.generation != generation || generation != self.generation
                }.count
            },
            notice: { [weak self] notice, _ in self?.notices.append(notice) },
            fail: { [weak self] failure, _ in self?.failures.append(failure) },
            schedule: { operation in operation() }
        )
    }
}

private final class TraceCoordinatorDecoder: VideoDecoding, @unchecked Sendable {
    var failNextTemporalConfiguration = false
    private(set) var temporalPropertySetCount = 0
    private(set) var temporalDecodeFlagCount = 0
    private var activeConfiguration: VideoDecodeConfiguration?

    func configure(
        format _: CMVideoFormatDescription,
        generation _: MediaGeneration,
        configuration: VideoDecodeConfiguration
    ) throws {
        if configuration == .appleTemporal {
            temporalPropertySetCount += 2
            if failNextTemporalConfiguration {
                failNextTemporalConfiguration = false
                throw VideoDecoderFailure.temporalUnavailable(
                    .initializationFailed(status: -77_710)
                )
            }
        }
        activeConfiguration = configuration
    }

    func decode(
        _ accessUnit: CompressedVideoAccessUnit,
        flags: VTDecodeFrameFlags
    ) throws {
        if activeConfiguration == .appleTemporal,
           flags.contains(._EnableAsynchronousDecompression) {
            temporalDecodeFlagCount += 1
        }
        _ = accessUnit
    }

    func finishDelayedFrames() throws {}
    func waitForAsynchronousFrames() throws {}
    func invalidate() { activeConfiguration = nil }
}

private final class DelayedTraceYADIF: YADIFFrameProcessing, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let frames: [VideoPresentationFrame]
        let completion: @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    }

    private var pending: [Pending] = []
    private var sequence: UInt64 = 0
    var pendingCompletionCount: Int { pending.count }

    func reset(to _: MediaGeneration) {}

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order _: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        let fields = [0, 1].map { index in
            sequence &+= 1
            return VideoPresentationFrame(
                storage: .pixelBuffer(frame.frame.pixelBuffer),
                presentationTimeStamp: index == 0
                    ? frame.presentationTimeStamp
                    : CMTimeAdd(frame.presentationTimeStamp, frame.fieldDuration),
                duration: frame.fieldDuration,
                generation: frame.frame.generation,
                sequenceNumber: sequence,
                sourceAccessUnitID: frame.frame.accessUnitID,
                formatMetadata: frame.frame.formatMetadata
            )
        }
        pending.append(Pending(frames: fields, completion: completion))
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        completion(.success([]))
    }

    func completeAll() {
        let completions = pending
        pending.removeAll()
        for item in completions { item.completion(.success(item.frames)) }
    }
}

func lumaDigest(_ presentation: VideoPresentationFrame) throws -> UInt64 {
    guard case let .pixelBuffer(pixelBuffer) = presentation.storage else {
        throw DeterministicTraceError.expectedPixelBuffer
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
        throw DeterministicTraceError.missingPlane
    }
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let componentBytes = CVPixelBufferGetPixelFormatType(pixelBuffer)
        == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
    var digest: UInt64 = 0xcbf29ce484222325
    for row in 0..<height {
        let bytes = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * componentBytes) {
            digest = (digest ^ UInt64(bytes[index])) &* 0x100000001b3
        }
    }
    return digest
}

extension Array where Element == GenerationPresentationTime {
    var isStrictlyIncreasingWithinEachGeneration: Bool {
        Dictionary(grouping: self, by: \.generation).values.allSatisfy { values in
            values.map(\.presentationTimeStamp).isStrictlyIncreasing
        }
    }
}

extension Array where Element == CMTime {
    var isStrictlyIncreasing: Bool {
        zip(self, dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 }
    }
}

enum DeterministicTraceError: Error {
    case expectedPixelBuffer
    case missingPlane
    case metalUnavailable
    case textureCache(CVReturn)
    case oddFieldCount(Int)
}
