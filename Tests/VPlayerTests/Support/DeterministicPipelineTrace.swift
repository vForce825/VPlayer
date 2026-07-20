// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Metal
import QuartzCore
import VideoToolbox
@testable import VPlayerPlayback

enum DeterministicPipelineFixture: Equatable, Sendable {
    case hevc2160p50Progressive
    case h2641080PsF25
    case h2641080i25TFF
    case h2641080i30000Over1001BFF
    case wrapThenSPSAndPMTChange
}

enum TraceGenerationAdvanceReason: Equatable, Sendable {
    case sps
    case pmt
    case discontinuity
}

struct DeterministicPipelineMetrics: Equatable, Sendable {
    var yadifKernelDispatchCount: UInt64 = 0
    var bothFieldsConfigurationCount: UInt64 = 0
    var decodedAccessUnitCount: UInt64 = 0
    var temporalConfigurationCount: UInt64 = 0
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
    var generationAdvanceReasons: [TraceGenerationAdvanceReason] = []
    var generationAdvanceDeltas: [UInt64] = []
    var unchangedPMTGenerationAdvanceCount = 0
    var rawSourcePTS90k: [UInt64] = []
    var pipelineDemuxEventCount = 0
    var discontinuityResetCount = 0
    var lateDecoderCallbackDeliveryCount = 0

    var generationAdvanceCount: Int { generationAdvanceReasons.count }
}

struct ClassifierAndTimingEdgeResult: Sendable {
    var unknownRoutes: [DeinterlaceRoute] = []
    var normalizedPTS: [CMTime] = []
    var normalizedDurations: [CMTime] = []
    var synthesizedTimingCount = 0
    var callbackSourcePTS90k: [UInt64?] = []
    var deliveredSourceAccessUnitIDs: [UInt64] = []
    var repeatFieldNormalizedDurations: [CMTime] = []
    var repeatFieldRoute = DeinterlaceRoute.rawWhileClassifying
    var repeatFieldMetadataReachedProcessor = false
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
    var crossGenerationDeliveryCount = 0
    var lateYADIFCompletionCount = 0
    var productionSinkDeliveryCountBeforeLateCompletion = 0
    var productionSinkDeliveryCountAfterLateCompletion = 0
    var generationAdvanceDuringFinalSwitch: UInt64 = 0
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
            return try await playWrapAndFormatChangeTrace()
        }

        let trace = try DeterministicPipelineTrace.make(
            fixture: fixture,
            frames: frames,
            seconds: seconds,
            fields: fields
        )
        let gate = TraceSerialGate(label: "org.vplayer.tests.deinterlace.trace")
        let host = TraceCoordinatorHost(gate: gate)
        let decoder = TraceCoordinatorDecoder()
        let systemYADIF = try makeSystemYADIF(generation: host.generation)
        let yadif = ObservingTraceYADIF(processor: systemYADIF)
        let coordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: PassthroughVideoProcessor(),
            yadif: yadif,
            probe: fixture == .h2641080PsF25 ? ImmediatePsFTraceProbe() : nil,
            initialGeneration: host.generation,
            selectedAlgorithm: algorithm,
            classifierConfiguration: ScanClassifierConfiguration(
                progressiveConfirmationFrames: 1,
                psfConfirmationFrames: 1,
                exitInterlacedConfirmationFrames: 1
            ),
            hooks: host.hooks
        )
        var routes: [DeinterlaceRoute] = []
        func perform(_ operation: () -> Void) {
            gate.perform {
                operation()
                if routes.last != coordinator.route { routes.append(coordinator.route) }
            }
        }

        perform { coordinator.replaceFormat(trace.formatDescription) }
        let generation = host.snapshot().generation
        let initialAccessUnit = try makeAccessUnit(
            id: 0,
            generation: generation,
            format: trace.formatDescription,
            duration: trace.nominalFrameDuration,
            parser: trace.frames[0].parserMetadata
        )
        perform { coordinator.handle(accessUnit: initialAccessUnit) }

        let flushFrames = makeFlushFrames(for: trace, generation: generation)
        for source in trace.frames + flushFrames {
            let frame = source.rebased(to: generation)
            let accessUnit = try makeAccessUnit(
                id: frame.accessUnitID,
                generation: generation,
                format: trace.formatDescription,
                duration: frame.duration,
                parser: frame.parserMetadata
            )
            perform { coordinator.handle(accessUnit: accessUnit) }
            perform { coordinator.handle(decoder: .frame(frame)) }
        }
        try await drain(yadif)
        gate.barrier()

        let targetIDs = Set(trace.frames.map(\.accessUnitID))
        let hostSnapshot = host.snapshot()
        let presentations = hostSnapshot.deliveredFrames
            .filter { targetIDs.contains($0.sourceAccessUnitID) }
            .sorted(by: presentationPrecedes)
        let decoderSnapshot = decoder.snapshot()
        let metrics = DeterministicPipelineMetrics(
            yadifKernelDispatchCount: systemYADIF.metricsSnapshot.completedJobCount,
            bothFieldsConfigurationCount: UInt64(decoderSnapshot.bothFieldsConfigurationCount),
            decodedAccessUnitCount: UInt64(decoderSnapshot.decodedAccessUnitCount),
            temporalConfigurationCount: UInt64(decoderSnapshot.temporalConfigurationCount),
            temporalPropertySetCount: UInt64(decoderSnapshot.temporalPropertySetCount),
            temporalDecodeFlagCount: UInt64(decoderSnapshot.temporalDecodeFlagCount),
            crossGenerationReferenceCount: UInt64(hostSnapshot.crossGenerationDeliveryCount),
            staleGenerationDropCount: systemYADIF.metricsSnapshot.staleGenerationDropCount
        )
        return DeterministicPipelineResult(
            presentations: presentations,
            metrics: metrics,
            allocatedDecodedSurfaceCount: trace.allocatedDecodedSurfaceCount,
            formatMetadata: trace.formatMetadata,
            formatCodecType: CMFormatDescriptionGetMediaSubType(trace.formatDescription),
            pixelFormats: Set(trace.frames.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }),
            routes: routes,
            resolvedFieldOrders: yadif.snapshotOrders().map(\.parity).reduce(into: []) {
                if !$0.contains($1) { $0.append($1) }
            },
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
        let token = try VideoTestFactories.nv12()
        let format = try VideoTestFactories.formatDescription()
        let host = TraceCoordinatorHost()
        let decoder = TraceCoordinatorDecoder()
        let yadif = ImmediateRecordingTraceYADIF()
        let coordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: PassthroughVideoProcessor(),
            yadif: yadif,
            probe: nil,
            initialGeneration: host.generation,
            selectedAlgorithm: .metalYADIF2x,
            classifierConfiguration: ScanClassifierConfiguration(
                progressiveConfirmationFrames: 1,
                psfConfirmationFrames: 1,
                exitInterlacedConfirmationFrames: 1
            ),
            hooks: host.hooks
        )
        coordinator.replaceFormat(format)
        let generation = host.generation
        let progressiveParser = VideoParserMetadata(
            fieldOrder: .progressive,
            pictureStructure: .frame,
            isInterlaced: false,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: 0
        )
        coordinator.handle(accessUnit: try makeAccessUnit(
            id: 0,
            generation: generation,
            format: format,
            duration: CMTime(value: 1, timescale: 25),
            parser: progressiveParser
        ))

        let callbackPTS: [UInt64?] = [0, 7_200, 3_600, 10_800, 14_400, 14_400, nil]
        let flushPTS: [UInt64] = [18_000, 21_600]
        for (index, rawPTS) in (callbackPTS + flushPTS.map(Optional.some)).enumerated() {
            let parser = VideoParserMetadata(
                fieldOrder: .progressive,
                pictureStructure: .frame,
                isInterlaced: false,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: rawPTS
            )
            let frame = VideoTestFactories.decodedFrame(
                id: UInt64(index + 1),
                pixelBuffer: token,
                presentationTimeStamp: rawPTS.map {
                    CMTime(value: Int64($0), timescale: 90_000)
                } ?? .invalid,
                duration: index >= 4 ? .invalid : CMTime(value: 1, timescale: 25),
                generation: generation,
                parserMetadata: parser
            )
            coordinator.handle(accessUnit: try makeAccessUnit(
                id: frame.accessUnitID,
                generation: generation,
                format: format,
                duration: CMTime(value: 1, timescale: 25),
                parser: parser
            ))
            coordinator.handle(decoder: .frame(frame))
        }
        let targetIDs = Set(UInt64(1)...UInt64(callbackPTS.count))
        let delivered = host.deliveredFrames.filter {
            targetIDs.contains($0.sourceAccessUnitID)
        }
        let synthesizedCount = delivered.filter { presentation in
            guard let raw = callbackPTS[Int(presentation.sourceAccessUnitID - 1)] else {
                return true
            }
            return CMTimeCompare(
                presentation.presentationTimeStamp,
                CMTime(value: Int64(raw), timescale: 90_000)
            ) != 0
        }.count

        let unknownRoutes = try DeinterlaceAlgorithm.allCases.map { algorithm in
            let unknownHost = TraceCoordinatorHost()
            let unknownCoordinator = VideoPipelineCoordinator(
                decoder: TraceCoordinatorDecoder(),
                passthrough: PassthroughVideoProcessor(),
                yadif: ImmediateRecordingTraceYADIF(),
                probe: nil,
                initialGeneration: unknownHost.generation,
                selectedAlgorithm: algorithm,
                classifierConfiguration: ScanClassifierConfiguration(
                    progressiveConfirmationFrames: 1,
                    psfConfirmationFrames: 1,
                    exitInterlacedConfirmationFrames: 1
                ),
                hooks: unknownHost.hooks
            )
            unknownCoordinator.replaceFormat(format)
            let unknownGeneration = unknownHost.generation
            let parser = VideoParserMetadata(
                fieldOrder: .unknown,
                pictureStructure: .unknown,
                isInterlaced: nil,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: nil
            )
            unknownCoordinator.handle(accessUnit: try makeAccessUnit(
                id: 100,
                generation: unknownGeneration,
                format: format,
                duration: CMTime(value: 1, timescale: 25),
                parser: parser
            ))
            unknownCoordinator.handle(decoder: .frame(VideoTestFactories.decodedFrame(
                id: 100,
                pixelBuffer: token,
                presentationTimeStamp: .invalid,
                duration: .invalid,
                generation: unknownGeneration,
                parserMetadata: parser
            )))
            return unknownCoordinator.route
        }

        let repeatHost = TraceCoordinatorHost()
        let repeatYADIF = ImmediateRecordingTraceYADIF()
        let repeatCoordinator = VideoPipelineCoordinator(
            decoder: TraceCoordinatorDecoder(),
            passthrough: PassthroughVideoProcessor(),
            yadif: repeatYADIF,
            probe: nil,
            initialGeneration: repeatHost.generation,
            selectedAlgorithm: .metalYADIF2x,
            classifierConfiguration: ScanClassifierConfiguration(
                progressiveConfirmationFrames: 1,
                psfConfirmationFrames: 1,
                exitInterlacedConfirmationFrames: 1
            ),
            hooks: repeatHost.hooks
        )
        let repeatFormat = try VideoTestFactories.formatDescription(
            fieldCount: NSNumber(value: 2),
            detail: kCVImageBufferFieldDetailTemporalTopFirst
        )
        repeatCoordinator.replaceFormat(repeatFormat)
        let repeatGeneration = repeatHost.generation
        for index in 0..<3 {
            let parser = VideoParserMetadata(
                fieldOrder: .tt,
                pictureStructure: .topField,
                isInterlaced: true,
                repeatFirstField: index == 0,
                topFieldFirst: true,
                sourcePTS90k: UInt64(index * 3_600)
            )
            if index == 0 {
                repeatCoordinator.handle(accessUnit: try makeAccessUnit(
                    id: 200,
                    generation: repeatGeneration,
                    format: repeatFormat,
                    duration: CMTime(value: 1, timescale: 25),
                    parser: parser
                ))
            }
            repeatCoordinator.handle(decoder: .frame(VideoTestFactories.decodedFrame(
                id: UInt64(200 + index),
                pixelBuffer: token,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 25),
                duration: index == 0 ? .invalid : CMTime(value: 1, timescale: 25),
                generation: repeatGeneration,
                parserMetadata: parser
            )))
        }

        return ClassifierAndTimingEdgeResult(
            unknownRoutes: unknownRoutes,
            normalizedPTS: delivered.map(\.presentationTimeStamp),
            normalizedDurations: delivered.map(\.duration),
            synthesizedTimingCount: synthesizedCount,
            callbackSourcePTS90k: callbackPTS,
            deliveredSourceAccessUnitIDs: delivered.map(\.sourceAccessUnitID),
            repeatFieldNormalizedDurations: repeatYADIF.snapshot().map(\.frameDuration),
            repeatFieldRoute: repeatCoordinator.route,
            repeatFieldMetadataReachedProcessor: repeatYADIF.snapshot().first?
                .frame.parserMetadata.repeatFirstField == true
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
        let generationBeforeFinalSwitch = harness.host.generation
        let deliveriesBeforeLateCompletion = harness.host.deliveredFrames.count
        harness.coordinator.setAlgorithm(.appleTemporal)
        routes.append(harness.coordinator.route)
        harness.yadif.completeAll()
        let deliveriesAfterLateCompletion = harness.host.deliveredFrames.count

        return RapidAlgorithmSwitchRegressionResult(
            routes: routes,
            injectedLateCallbackCount: lateCount,
            crossGenerationDeliveryCount: harness.host.crossGenerationDeliveryCount,
            lateYADIFCompletionCount: harness.yadif.completedCallbackCount,
            productionSinkDeliveryCountBeforeLateCompletion: deliveriesBeforeLateCompletion,
            productionSinkDeliveryCountAfterLateCompletion: deliveriesAfterLateCompletion,
            generationAdvanceDuringFinalSwitch: harness.host.generation.rawValue
                - generationBeforeFinalSwitch.rawValue
        )
    }

    private func playWrapAndFormatChangeTrace() async throws -> DeterministicPipelineResult {
        let trace = try DeterministicPipelineTrace.make(
            fixture: .wrapThenSPSAndPMTChange,
            frames: nil,
            seconds: nil,
            fields: nil
        )
        let demuxer = CountingTraceDemuxer()
        let decoder = TraceCoordinatorDecoder()
        let systemYADIF = try makeSystemYADIF(generation: MediaGeneration(rawValue: 0))
        let yadif = ObservingTraceYADIF(processor: systemYADIF)
        let renderer = AuditTraceRenderer()
        let events = TracePipelineEvents()
        let pipeline = PlaybackPipeline(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.wrap.pipeline"),
            demuxer: demuxer,
            assemblerBuilder: FakePlaybackAssemblerBuilder(),
            decoder: decoder,
            processor: PassthroughVideoProcessor(),
            yadifProcessor: yadif,
            selectedAlgorithm: .metalYADIF2x,
            renderer: renderer,
            audio: FakePipelineAudio(),
            clock: FakePipelineClock(),
            display: FakePlaybackDisplay(),
            eventSink: { events.append($0) }
        )
        pipeline.start(url: URL(string: "https://example.test/wrap.ts")!)
        try await waitUntil { demuxer.hasStarted }

        let initialSPS = Data([0x67, 0x64, 0x00, 0x1F])
        let pps = Data([0x68, 0xEE, 0x3C, 0x80])
        let initialCookie = Data([0x12, 0x10])
        let initialTracks = PlaybackFakeMedia.tracks(
            videoExtradata: initialSPS,
            audioExtradata: initialCookie
        )
        let initialFingerprint = try MediaFormatFingerprint(
            trackSet: initialTracks,
            videoParameterSets: [initialSPS, pps],
            audioCookie: initialCookie
        )
        demuxer.emit(.tracks(initialTracks))
        pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            initialFingerprint
        ))
        pipeline.receive(video: .format(trace.formatDescription, initialFingerprint))
        try await waitUntil {
            await pipeline.debugSnapshot().generation == MediaGeneration(rawValue: 1)
        }
        let initialGeneration = await pipeline.debugSnapshot().generation

        let initialAccessUnit = try makeAccessUnit(
            id: 0,
            generation: initialGeneration,
            format: trace.formatDescription,
            duration: trace.nominalFrameDuration,
            parser: trace.frames[0].parserMetadata
        )
        pipeline.receive(video: .accessUnit(initialAccessUnit))
        let wrapFlushFrames = makeFlushFrames(for: trace, generation: initialGeneration)
        for source in trace.frames + wrapFlushFrames {
            let frame = source.rebased(to: initialGeneration)
            pipeline.receive(video: .accessUnit(try makeAccessUnit(
                id: frame.accessUnitID,
                generation: initialGeneration,
                format: trace.formatDescription,
                duration: frame.duration,
                parser: frame.parserMetadata
            )))
            pipeline.receive(decoder: .frame(frame))
        }
        _ = await pipeline.debugSnapshot()
        try await drain(yadif)
        let wrapIDs = Set(trace.frames.map(\.accessUnitID))
        try await waitUntil {
            renderer.snapshot().allFrames.filter {
                wrapIDs.contains($0.sourceAccessUnitID)
            }.count == trace.frames.count * 2
        }
        let wrapPresentations = renderer.snapshot().allFrames
            .filter { wrapIDs.contains($0.sourceAccessUnitID) }
            .sorted(by: presentationPrecedes)

        let beforeSamePMT = await pipeline.debugSnapshot().generation
        demuxer.emit(.tracks(initialTracks))
        let afterSamePMT = await pipeline.debugSnapshot().generation
        let unchangedPMTAdvanceCount = beforeSamePMT == afterSamePMT ? 0 : 1

        var changedSPS = initialSPS
        changedSPS[3] = 0x20
        let changedSPSFingerprint = try MediaFormatFingerprint(
            trackSet: initialTracks,
            videoParameterSets: [changedSPS, pps],
            audioCookie: initialCookie
        )
        pipeline.receive(video: .format(trace.formatDescription, changedSPSFingerprint))
        try await waitUntil {
            await pipeline.debugSnapshot().generation.rawValue
                == afterSamePMT.rawValue + 1
        }
        let spsGeneration = await pipeline.debugSnapshot().generation

        let changedCookie = Data([0x13, 0x10])
        let changedTracks = PlaybackFakeMedia.tracks(
            videoExtradata: Data([0x00, 0x00, 0x01, 0x67]),
            audioExtradata: changedCookie
        )
        let changedPMTFingerprint = try MediaFormatFingerprint(
            trackSet: changedTracks,
            videoParameterSets: [changedSPS, pps],
            audioCookie: changedCookie
        )
        demuxer.emit(.tracks(changedTracks))
        pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            changedPMTFingerprint
        ))
        pipeline.receive(video: .format(trace.formatDescription, changedPMTFingerprint))
        try await waitUntil {
            await pipeline.debugSnapshot().generation.rawValue
                == spsGeneration.rawValue + 1
        }
        let pmtGeneration = await pipeline.debugSnapshot().generation

        demuxer.emit(.discontinuity(changedTracks))
        try await waitUntil {
            await pipeline.debugSnapshot().generation.rawValue
                == pmtGeneration.rawValue + 1
        }
        let discontinuityGeneration = await pipeline.debugSnapshot().generation
        pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            changedPMTFingerprint
        ))
        pipeline.receive(video: .format(trace.formatDescription, changedPMTFingerprint))
        _ = await pipeline.debugSnapshot()

        let staleFrame = VideoTestFactories.decodedFrame(
            id: 999,
            pixelBuffer: trace.frames[0].pixelBuffer,
            presentationTimeStamp: CMTime(value: 7_200, timescale: 90_000),
            duration: trace.nominalFrameDuration,
            generation: pmtGeneration,
            parserMetadata: traceInterlacedParser(parity: .top, sourcePTS90k: 7_200),
            formatMetadata: trace.formatMetadata
        )
        pipeline.receive(decoder: .frame(staleFrame))
        _ = await pipeline.debugSnapshot()
        let rendererSnapshot = renderer.snapshot()
        let lateDeliveryCount = rendererSnapshot.allFrames.filter {
            $0.sourceAccessUnitID == 999
        }.count
        let generationAudit = yadif.generationAudit()
        let resetSet = Set(generationAudit.resets)
        let resetMismatchCount = generationAudit.submissions.filter {
            !resetSet.contains($0)
        }.count
        let failureEvents = events.snapshot().filter {
            if case .failed = $0 { return true }
            return false
        }
        if !failureEvents.isEmpty { throw DeterministicTraceError.pipelineFailure }

        return DeterministicPipelineResult(
            presentations: wrapPresentations,
            metrics: DeterministicPipelineMetrics(
                yadifKernelDispatchCount: systemYADIF.metricsSnapshot.completedJobCount,
                bothFieldsConfigurationCount: UInt64(
                    decoder.snapshot().bothFieldsConfigurationCount
                ),
                decodedAccessUnitCount: UInt64(decoder.snapshot().decodedAccessUnitCount),
                temporalConfigurationCount: UInt64(
                    decoder.snapshot().temporalConfigurationCount
                ),
                temporalPropertySetCount: UInt64(decoder.snapshot().temporalPropertySetCount),
                temporalDecodeFlagCount: UInt64(decoder.snapshot().temporalDecodeFlagCount),
                crossGenerationReferenceCount: UInt64(
                    rendererSnapshot.crossGenerationDeliveryCount + resetMismatchCount
                ),
                staleGenerationDropCount: systemYADIF.metricsSnapshot.staleGenerationDropCount
            ),
            allocatedDecodedSurfaceCount: trace.allocatedDecodedSurfaceCount,
            formatMetadata: trace.formatMetadata,
            formatCodecType: CMFormatDescriptionGetMediaSubType(trace.formatDescription),
            pixelFormats: Set(trace.frames.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }),
            presentationPTS: wrapPresentations.map {
                GenerationPresentationTime(
                    generation: $0.generation,
                    presentationTimeStamp: $0.presentationTimeStamp
                )
            },
            generationAdvanceReasons: [.sps, .pmt, .discontinuity],
            generationAdvanceDeltas: [
                spsGeneration.rawValue - afterSamePMT.rawValue,
                pmtGeneration.rawValue - spsGeneration.rawValue,
                discontinuityGeneration.rawValue - pmtGeneration.rawValue,
            ],
            unchangedPMTGenerationAdvanceCount: unchangedPMTAdvanceCount,
            rawSourcePTS90k: trace.frames.compactMap(\.parserMetadata.sourcePTS90k),
            pipelineDemuxEventCount: demuxer.emissionCount,
            discontinuityResetCount: rendererSnapshot.flushes.filter {
                $0 == discontinuityGeneration
            }.count,
            lateDecoderCallbackDeliveryCount: lateDeliveryCount
        )
    }

    private func makeAccessUnit(
        id: UInt64,
        generation: MediaGeneration,
        format: CMVideoFormatDescription,
        duration: CMTime,
        parser: VideoParserMetadata
    ) throws -> CompressedVideoAccessUnit {
        let pts = parser.sourcePTS90k.map {
            CMTime(value: Int64($0), timescale: 90_000)
        } ?? CMTime(value: Int64(id), timescale: 25)
        let sampleBuffer = try SampleBufferBuilder.makeVideo(
            data: Data([0, 0, 0, 1]),
            formatDescription: format,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid,
            duration: duration,
            isRandomAccess: true
        )
        return CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: true,
            parserMetadata: parser
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DeterministicTraceError.timeout
    }

    private func makeFlushFrames(
        for trace: DeterministicPipelineTrace,
        generation: MediaGeneration
    ) -> [DecodedVideoFrame] {
        guard let last = trace.frames.last else { return [] }
        let convertedDuration = CMTimeConvertScale(
            trace.nominalFrameDuration,
            timescale: 90_000,
            method: .default
        )
        let lastRawPTS = last.parserMetadata.sourcePTS90k ?? 0
        return (1...2).map { offset in
            let rawPTS = lastRawPTS &+ UInt64(convertedDuration.value * Int64(offset))
            let parser = VideoParserMetadata(
                fieldOrder: last.parserMetadata.fieldOrder,
                pictureStructure: last.parserMetadata.pictureStructure,
                isInterlaced: last.parserMetadata.isInterlaced,
                repeatFirstField: false,
                topFieldFirst: last.parserMetadata.topFieldFirst,
                sourcePTS90k: rawPTS
            )
            return VideoTestFactories.decodedFrame(
                id: UInt64(trace.frames.count + offset),
                pixelBuffer: trace.frames[(offset - 1) % trace.frames.count].pixelBuffer,
                presentationTimeStamp: CMTime(value: Int64(rawPTS), timescale: 90_000),
                duration: trace.nominalFrameDuration,
                generation: generation,
                parserMetadata: parser,
                formatMetadata: trace.formatMetadata
            )
        }
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

    private func drain(_ processor: ObservingTraceYADIF) async throws {
        await withCheckedContinuation { continuation in
            processor.drain { result in
                processor.consumeDrainResult(result)
                continuation.resume()
            }
        }
        if let failure = processor.drainFailure { throw failure }
    }

    private func presentationPrecedes(
        _ lhs: VideoPresentationFrame,
        _ rhs: VideoPresentationFrame
    ) -> Bool {
        let comparison = CMTimeCompare(lhs.presentationTimeStamp, rhs.presentationTimeStamp)
        return comparison == 0 ? lhs.sequenceNumber < rhs.sequenceNumber : comparison < 0
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

        case .h2641080PsF25:
            let count = requestedFrames ?? 16
            let token = try VideoTestFactories.pixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let metadata = VideoTestFactories.metadata(width: 1_920, height: 1_080)
            let duration = CMTime(value: 3_600, timescale: 90_000)
            var generated: [DecodedVideoFrame] = []
            generated.reserveCapacity(count)
            for index in 0..<count {
                let parser = VideoParserMetadata(
                    fieldOrder: .tt,
                    pictureStructure: .frame,
                    isInterlaced: true,
                    repeatFirstField: false,
                    topFieldFirst: true,
                    sourcePTS90k: UInt64(index * 3_600)
                )
                let frame = VideoTestFactories.decodedFrame(
                    id: UInt64(index + 1),
                    pixelBuffer: token,
                    presentationTimeStamp: CMTime(
                        value: Int64(index * 3_600),
                        timescale: 90_000
                    ),
                    duration: duration,
                    generation: MediaGeneration(rawValue: 0),
                    parserMetadata: parser,
                    formatMetadata: metadata
                )
                generated.append(frame)
            }
            return DeterministicPipelineTrace(
                frames: generated,
                formatDescription: try interlacedFormat(parity: .top),
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

private final class CountingTraceDemuxer: MediaDemuxing, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (DemuxEvent) -> Void)?
    private var started = false
    private var emissions = 0

    var hasStarted: Bool { lock.withLock { started } }
    var emissionCount: Int { lock.withLock { emissions } }

    func start(
        url _: URL,
        sink: @escaping @Sendable (DemuxEvent) -> Void
    ) throws {
        lock.withLock {
            self.sink = sink
            started = true
        }
    }

    func cancel() {}

    func emit(_ event: DemuxEvent) {
        let current = lock.withLock { () -> (@Sendable (DemuxEvent) -> Void)? in
            emissions += 1
            return sink
        }
        current?(event)
    }
}

private final class TracePipelineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackPipelineEvent] = []
    func append(_ event: PlaybackPipelineEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [PlaybackPipelineEvent] { lock.withLock { events } }
}

private struct AuditTraceRendererSnapshot: Sendable {
    let allFrames: [VideoPresentationFrame]
    let flushes: [MediaGeneration]
    let crossGenerationDeliveryCount: Int
}

private final class AuditTraceRenderer: PlaybackVideoRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var allFrames: [VideoPresentationFrame] = []
    private var flushes: [MediaGeneration] = []
    private var currentGeneration = MediaGeneration(rawValue: 0)
    private var crossGenerationDeliveryCount = 0

    func enqueue(_ frame: VideoPresentationFrame) {
        lock.withLock {
            if frame.generation != currentGeneration {
                crossGenerationDeliveryCount += 1
            }
            allFrames.append(frame)
        }
    }

    func flush(to generation: MediaGeneration) {
        lock.withLock {
            currentGeneration = generation
            flushes.append(generation)
        }
    }

    func draw(
        targetMediaTime _: CMTime,
        drawable _: any CAMetalDrawable
    ) -> VideoRenderDecision {
        VideoRenderDecision(
            action: .waiting,
            sourceAccessUnitID: nil,
            sequenceNumber: nil,
            droppedFrameCount: 0
        )
    }

    func resetPresentationTiming() {}

    func snapshot() -> AuditTraceRendererSnapshot {
        lock.withLock {
            AuditTraceRendererSnapshot(
                allFrames: allFrames,
                flushes: flushes,
                crossGenerationDeliveryCount: crossGenerationDeliveryCount
            )
        }
    }
}

private final class TraceSerialGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: key, value: 1)
    }

    func perform<Value>(_ operation: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: key) == 1 { return operation() }
        return queue.sync(execute: operation)
    }

    func submit(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    func barrier() { perform {} }
}

private final class ObservingTraceYADIF: YADIFFrameProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private let processor: YADIFProcessor
    private var orders: [ResolvedFieldOrder] = []
    private var resetGenerations: [MediaGeneration] = []
    private var submissionGenerations: [MediaGeneration] = []
    private var storedDrainFailure: PlaybackFailure?

    init(processor: YADIFProcessor) {
        self.processor = processor
    }

    var drainFailure: PlaybackFailure? { lock.withLock { storedDrainFailure } }

    func reset(to generation: MediaGeneration) {
        lock.withLock { resetGenerations.append(generation) }
        processor.reset(to: generation)
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        lock.withLock {
            orders.append(order)
            submissionGenerations.append(frame.frame.generation)
        }
        processor.submit(
            normalized: frame,
            order: order,
            discontinuity: discontinuity,
            completion: completion
        )
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        processor.drain(completion: completion)
    }

    func consumeDrainResult(
        _ result: Result<[VideoPresentationFrame], PlaybackFailure>
    ) {
        if case let .failure(failure) = result {
            lock.withLock { storedDrainFailure = failure }
        }
    }

    func snapshotOrders() -> [ResolvedFieldOrder] { lock.withLock { orders } }

    func generationAudit() -> (resets: [MediaGeneration], submissions: [MediaGeneration]) {
        lock.withLock { (resetGenerations, submissionGenerations) }
    }
}

private final class ImmediateRecordingTraceYADIF: YADIFFrameProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [NormalizedDecodedFrame] = []

    func reset(to _: MediaGeneration) {}

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order _: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        lock.withLock { submissions.append(frame) }
        completion(.success([]))
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        completion(.success([]))
    }

    func snapshot() -> [NormalizedDecodedFrame] { lock.withLock { submissions } }
}

private final class ImmediatePsFTraceProbe: LumaScanProbing, @unchecked Sendable {
    func submit(
        current _: CVPixelBuffer,
        previous _: CVPixelBuffer,
        generation _: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        completion(.success(ContentProbeSample(
            combRatio: 0.01,
            motionRatio: 0.02,
            sampleCount: VideoTestFactories.width * VideoTestFactories.height
        )))
    }

    func stop(generation _: MediaGeneration) {}
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

private struct TraceCoordinatorHostSnapshot: Sendable {
    let generation: MediaGeneration
    let deliveredFrames: [VideoPresentationFrame]
    let crossGenerationDeliveryCount: Int
}

private final class TraceCoordinatorHost: @unchecked Sendable {
    private let gate: TraceSerialGate?
    private(set) var generation = MediaGeneration(rawValue: 0)
    private(set) var deliveredFrames: [VideoPresentationFrame] = []
    private(set) var notices: [PlaybackNotice] = []
    private(set) var failures: [PlaybackCoreError] = []
    private(set) var crossGenerationDeliveryCount = 0

    init(gate: TraceSerialGate? = nil) {
        self.gate = gate
    }

    func snapshot() -> TraceCoordinatorHostSnapshot {
        let capture = {
            TraceCoordinatorHostSnapshot(
                generation: self.generation,
                deliveredFrames: self.deliveredFrames,
                crossGenerationDeliveryCount: self.crossGenerationDeliveryCount
            )
        }
        return gate?.perform(capture) ?? capture()
    }

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
                deliveredFrames.append(contentsOf: frames)
                crossGenerationDeliveryCount += frames.filter {
                    $0.generation != generation || generation != self.generation
                }.count
            },
            notice: { [weak self] notice, _ in self?.notices.append(notice) },
            fail: { [weak self] failure, _ in self?.failures.append(failure) },
            schedule: { [weak self] operation in
                if let gate = self?.gate {
                    gate.submit(operation)
                } else {
                    operation()
                }
            }
        )
    }
}

private struct TraceCoordinatorDecoderSnapshot: Sendable {
    let bothFieldsConfigurationCount: Int
    let decodedAccessUnitCount: Int
    let temporalConfigurationCount: Int
    let temporalPropertySetCount: Int
    let temporalDecodeFlagCount: Int
}

private final class TraceCoordinatorDecoder: VideoDecoding, @unchecked Sendable {
    private let lock = NSLock()
    var failNextTemporalConfiguration = false
    private(set) var temporalPropertySetCount = 0
    private(set) var temporalConfigurationCount = 0
    private(set) var temporalDecodeFlagCount = 0
    private(set) var bothFieldsConfigurationCount = 0
    private(set) var decodedAccessUnitCount = 0
    private var activeConfiguration: VideoDecodeConfiguration?

    func configure(
        format _: CMVideoFormatDescription,
        generation _: MediaGeneration,
        configuration: VideoDecodeConfiguration
    ) throws {
        try lock.withLock {
            if configuration == .appleTemporal {
                temporalConfigurationCount += 1
                temporalPropertySetCount += 2
                if failNextTemporalConfiguration {
                    failNextTemporalConfiguration = false
                    throw VideoDecoderFailure.temporalUnavailable(
                        .initializationFailed(status: -77_710)
                    )
                }
            } else {
                bothFieldsConfigurationCount += 1
            }
            activeConfiguration = configuration
        }
    }

    func decode(
        _ accessUnit: CompressedVideoAccessUnit,
        flags: VTDecodeFrameFlags
    ) throws {
        lock.withLock {
            decodedAccessUnitCount += 1
            if activeConfiguration == .appleTemporal,
               flags.contains(._EnableAsynchronousDecompression) {
                temporalDecodeFlagCount += 1
            }
        }
        _ = accessUnit
    }

    func finishDelayedFrames() throws {}
    func waitForAsynchronousFrames() throws {}
    func invalidate() { lock.withLock { activeConfiguration = nil } }

    func snapshot() -> TraceCoordinatorDecoderSnapshot {
        lock.withLock {
            TraceCoordinatorDecoderSnapshot(
                bothFieldsConfigurationCount: bothFieldsConfigurationCount,
                decodedAccessUnitCount: decodedAccessUnitCount,
                temporalConfigurationCount: temporalConfigurationCount,
                temporalPropertySetCount: temporalPropertySetCount,
                temporalDecodeFlagCount: temporalDecodeFlagCount
            )
        }
    }
}

private final class DelayedTraceYADIF: YADIFFrameProcessing, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let frames: [VideoPresentationFrame]
        let completion: @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    }

    private var pending: [Pending] = []
    private var sequence: UInt64 = 0
    private(set) var completedCallbackCount = 0
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
        for item in completions {
            completedCallbackCount += 1
            item.completion(.success(item.frames))
        }
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
    case pipelineFailure
    case timeout
}
