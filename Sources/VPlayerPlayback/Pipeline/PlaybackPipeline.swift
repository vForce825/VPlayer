// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

enum PlaybackPipelinePhase: Sendable, Equatable {
    case buffering
    case recovering
}

enum PlaybackPipelineEvent: Sendable, Equatable {
    case ready(readinessCycle: UInt64)
    case phase(PlaybackPipelinePhase, readinessCycle: UInt64)
    // The generation defaults to nil for lightweight test/integration fakes;
    // real pipelines always provide it so a late format result can never
    // replace a newer media snapshot in the controller.
    case mediaInformation(PlaybackMediaInformation?, generation: MediaGeneration? = nil)
    case stopped
    case failed(PlaybackCoreError)
}

protocol PlaybackPipelineProtocol: AnyObject, Sendable {
    var presentationContext: PlaybackPresentationContext? { get }
    var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)? { get }
    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot?
    func start(url: URL, readinessCycle: UInt64, initiallyPaused: Bool)
    func setPaused(_ paused: Bool, readinessCycle: UInt64)
    func recoverFromAudioSessionReset(readinessCycle: UInt64)
    func setTuning(_ tuning: PlaybackTuning)
    func stop() async
}

extension PlaybackPipelineProtocol {
    func start(url: URL) {
        start(url: url, readinessCycle: 0, initiallyPaused: false)
    }
}

protocol PlaybackPipelineFactory: Sendable {
    func makePipeline(
        tuning: PlaybackTuning,
        channelID: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackPipelineProtocol
}

protocol VideoAccessUnitAssembling: AnyObject {
    func push(_ packet: DemuxPacket) throws
    func drain() throws
}

protocol AudioSampleAssembling: AnyObject {
    func push(_ packet: DemuxPacket) throws
    func drain() throws
}

extension CompressedVideoAssembler: VideoAccessUnitAssembling {}
extension CompressedAudioAssembler: AudioSampleAssembling {}

protocol PlaybackAssemblerBuilding: Sendable {
    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding
    ) throws -> any VideoAccessUnitAssembling

    func makeAudio(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding
    ) throws -> any AudioSampleAssembling
}

struct SystemPlaybackAssemblerBuilder: PlaybackAssemblerBuilding {
    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding
    ) throws -> any VideoAccessUnitAssembling {
        try CompressedVideoAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: eventSink,
            formatState: formatState,
            binding: binding
        )
    }

    func makeAudio(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding
    ) throws -> any AudioSampleAssembling {
        try CompressedAudioAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: eventSink,
            formatState: formatState,
            binding: binding
        )
    }
}

/// Components whose buffering bounds the viewer can change while a stream is
/// playing. The default no-op keeps the fakes in the tests, which have no
/// buffers to size, free of ceremony.
protocol PlaybackTunable: AnyObject {
    func apply(_ tuning: PlaybackTuning)
}

extension PlaybackTunable {
    func apply(_ tuning: PlaybackTuning) {}
}

protocol PlaybackVideoRendering: AnyObject, Sendable, PlaybackTunable {
    func enqueue(_ frame: VideoPresentationFrame)
    func flush(to generation: MediaGeneration)
    func reset(_ request: VideoRendererResetRequest, completion: @escaping SystemVideoOutput.Acceptance)
    func resetPresentationTiming()
    func refreshPerformanceMetrics()
    func stopAwaitingRendererRemoval() async
}

extension PlaybackVideoRendering {
    func reset(_ request: VideoRendererResetRequest, completion: @escaping SystemVideoOutput.Acceptance) {
        flush(to: request.generation)
        for frame in request.seedFrames { enqueue(frame) }
        completion(.success(VideoEnqueueReceipt(
            generation: request.generation,
            sequenceNumbers: Set(request.seedFrames.map(\.sequenceNumber))
        )))
    }

    func refreshPerformanceMetrics() {}

    func stopAwaitingRendererRemoval() async {}
}

extension SystemVideoOutput: PlaybackVideoRendering, PlaybackTunable {}

protocol PlaybackDisplayControlling: Sendable {
    func pauseSubmission()
    func resumeSubmission()
    func resetPresentationTiming()
    func updateDisplayCriteria(
        formatDescription: CMFormatDescription,
        outputFrameRate: Float
    )
    func clearDisplayCriteria() async
}

struct PlaybackPipelineSnapshot: Sendable {
    let generation: MediaGeneration
    let hasTracks: Bool
    let isPaused: Bool
    let deferredPacketCount: Int
    let isTerminal: Bool
    let requiredVideoFrameCount: Int
    let mediaAdmissionOpen: Bool
    let videoAdmissionOpen: Bool
    let pendingVideoDecodeCount: Int
    let outstandingVideoDecodeCount: Int
    let audioGapVideoEvidenceRecordCount: Int
}

final class PlaybackPipeline: PlaybackPipelineProtocol, @unchecked Sendable {
    typealias VideoDecodeStallScheduler = @Sendable (
        DispatchTimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void
    let presentationContext: PlaybackPresentationContext?
    private typealias StopCompletion = @Sendable () -> Void

    private struct DisplayCriteriaKey: Equatable {
        let formatIdentity: ObjectIdentifier
        let route: DeinterlaceRoute
        let outputFrameRate: Float
    }

    private struct PreparedAnchor {
        let cycleID: UInt64
        let commonPTS: CMTime
        let routeRevision: UInt64?
    }

    private struct AnchorPreparationTransaction {
        let cycleID: UInt64
        let generation: MediaGeneration
        let islandID: AudioContinuityIslandID
        let commonPTS: CMTime
        let routeRevision: UInt64?
    }

    private struct AudioGapReanchorTransaction {
        enum Phase: Equatable {
            case waitingForOutstandingVideo
            case waitingForRandomAccess
            case videoPreroll
            case preparingAnchor
        }

        let islandID: AudioContinuityIslandID
        let audioFirstPTS: CMTime
        let generation: MediaGeneration
        var phase: Phase
        // Assembler IDs are monotonic within a generation. Processor delivery
        // may trail decoder submission completion, so one closed interval keeps
        // valid delayed evidence without retaining one key per video frame.
        var submittedAccessUnitIDRange: ClosedRange<UInt64>?

        mutating func recordSubmission(accessUnitID: UInt64) {
            guard let submittedAccessUnitIDRange else {
                self.submittedAccessUnitIDRange = accessUnitID...accessUnitID
                return
            }
            self.submittedAccessUnitIDRange = min(
                submittedAccessUnitIDRange.lowerBound,
                accessUnitID
            )...max(submittedAccessUnitIDRange.upperBound, accessUnitID)
        }

        func containsSubmission(accessUnitID: UInt64, generation: MediaGeneration) -> Bool {
            self.generation == generation
                && submittedAccessUnitIDRange?.contains(accessUnitID) == true
        }

        var evidenceRecordCount: Int {
            submittedAccessUnitIDRange == nil ? 0 : 1
        }
    }

    static let deferredPacketCapacity = 32
    static let pendingTrackMediaCapacity = 96
    // Compressed access units are tiny beside decoded 4K P010 surfaces. This
    // reservoir absorbs a conventional HLS segment while decoded video stays
    // close to the playback clock. Five seconds at 50/60 fps already exceeds
    // the previous 240-unit bound and made a live segment lose its tail.
    static let pendingVideoDecodeCapacity = 512
    private static let pendingTrackVideoRetentionLimits = CompressedVideoRetentionLimits(
        maximumCount: pendingTrackMediaCapacity,
        maximumOwnedBytes: 8 * 1_024 * 1_024,
        latestTailHorizon: CMTime(value: 4, timescale: 1)
    )
    private static let pendingDecodeVideoRetentionLimits = CompressedVideoRetentionLimits(
        maximumCount: pendingVideoDecodeCapacity,
        maximumOwnedBytes: 24 * 1_024 * 1_024,
        latestTailHorizon: CMTime(value: 24, timescale: 1)
    )
    // Must stay well inside `retainedVideoHorizon` so a closed-readiness startup
    // window cannot claim the whole presentation queue and starve the decoder
    // pool. Anchoring needs at most `requiredVideoFrameCount` (2 for field-rate
    // YADIF) frames, so a small window is sufficient here.
    static let startupRetainedVideoCapacity = 4
    // A real decoder stall pauses the shared clock so a decoder that can only
    // sustain source rate still has a chance to catch up. The readiness gate's
    // recovery floor guarantees that this pause can never rewind or replay the
    // retained second that preceded it.
    static let videoResyncThreshold = CMTime(value: 1, timescale: 1)
    // Compressed samples retained for startup/re-anchor. While readiness is
    // closed this window must keep the earliest samples, matching the startup
    // video window: HLS can deliver many seconds of AAC before VideoToolbox
    // returns its first decoded frames. Sliding audio forward in that phase
    // leaves the two windows permanently non-overlapping.
    // A live HLS segment is commonly 5-10 seconds. AAC at 44.1 kHz contributes
    // about 216 packets per five-second segment, so a 128-packet history could
    // slide entirely beyond the video decoder during one segment burst. This is
    // only a hard safety bound; normal pruning follows the playback/video
    // recovery watermark below rather than a packet count.
    private static let pendingVideoDrainInterval: DispatchTimeInterval = .milliseconds(10)
    // This matches VideoToolboxDecoder's in-flight window. Keeping the credit at
    // the pipeline boundary means an HLS burst remains compressed until a real
    // decoder completion arrives instead of filling the decoder's private
    // submission queue and forcing a skip to the next random-access picture.
    private static let maximumOutstandingVideoDecodeSubmissions = 8

    private struct DecoderSubmissionKey: Hashable {
        let accessUnitID: UInt64
        let identity: VideoDecoderEventIdentity
    }

    private struct DecoderAdmissionReservation: Hashable {
        let accessUnitID: UInt64
        let generation: MediaGeneration
    }

    private struct VideoTimestampInterval {
        let first: CMTime
        let end: CMTime
    }

    private enum VideoFormatCommitMode: Equatable {
        case currentEpoch
        case freshTrackEpoch
    }

    private struct PendingVideoFormatCommit {
        let revision: UInt64
        let mode: VideoFormatCommitMode
        var generation: MediaGeneration?
        var invalidationTicket: VideoDecoderInvalidationTicket?
    }

    private struct PendingPacketAdmission {
        let packet: DemuxPacket
        let acknowledgement: DispatchSemaphore
    }

    private struct AssemblyTransaction {
        let id: AssemblyEpochID
        let binding: AssemblyEpochBinding
        let tracks: DemuxTrackSet
        let formatState: AssemblyFormatState
        let video: (any VideoAccessUnitAssembling)?
        let audio: any AudioSampleAssembling
    }

    /// Written from the demux delivery thread, read from whichever thread asks
    /// for a metrics snapshot, so it cannot live with the executor-isolated state.
    private final class AtomicNanoseconds: @unchecked Sendable {
        private let lock = NSLock()
        private var total: UInt64 = 0

        func add(_ nanoseconds: UInt64) {
            lock.withLock { total &+= nanoseconds }
        }

        var value: UInt64 { lock.withLock { total } }
    }

    private let admitWaitNanoseconds = AtomicNanoseconds()

    private let executor: PlaybackSerialExecutor
    private let demuxer: any MediaDemuxing
    private let assemblerBuilder: any PlaybackAssemblerBuilding
    private let renderer: any PlaybackVideoRendering
    private let videoSurfaceLedger: VideoSurfaceBudgetLedger?
    private let audio: any AudioRenderPipelineProtocol
    private let clock: any PlaybackClock
    private let display: any PlaybackDisplayControlling
    private let eventSink: @Sendable (PlaybackPipelineEvent) -> Void
    private let metrics: PlaybackMetrics?
    private let signposts: PlaybackSignposts?
    private let videoDecodeStallTimeout: DispatchTimeInterval
    private let videoDecodeStallScheduler: VideoDecodeStallScheduler
    private let pendingTrackAudioRetentionLimits: CompressedAudioRetentionLimits
    private var videoCoordinator: VideoPipelineCoordinator!

    // Every property below is accessed exclusively from `executor`.
    private var tuning: PlaybackTuning
    private var generationController = GenerationController()
    private var consumedFingerprint: MediaFormatFingerprint?
    private var awaitingFreshTrackEpoch = false
    private var freshVideoFormatArrived = false
    private var freshAudioFormatArrived = false
    private var mediaAdmissionOpen = false
    private var trackEpochAlreadyAdvanced = false
    private var readiness: PlaybackReadinessGate?
    private var assembly: AssemblyTransaction?
    private var nextTimelineEpochRawValue: UInt64 = 0
    private var nextAssemblyInstanceToken: UInt64 = 0
    private var tracks: DemuxTrackSet? { assembly?.tracks }
    private var formatState: AssemblyFormatState? { assembly?.formatState }
    private var videoAssembler: (any VideoAccessUnitAssembling)? { assembly?.video }
    private var audioAssembler: (any AudioSampleAssembling)? { assembly?.audio }
    private var videoFormat: CMVideoFormatDescription?
    private var audioConfiguration: CompressedAudioRenderConfiguration?
    private var audioResourcesConfigured = false
    private var pendingAudioSessionReset = false
    private var videoFormatCommitRevision: UInt64 = 0
    private var pendingVideoFormatCommit: PendingVideoFormatCommit?
    private var activeDecoderInvalidationTicket: VideoDecoderInvalidationTicket?
    private var audioContinuity: AudioContinuityBuffer
    private var audioContinuityDropCountsByReason = [UInt64](
        repeating: 0,
        count: AudioContinuityDropReason.slotCount
    )
    private var audioShortGapCount: UInt64 = 0
    private var audioLargeGapCount: UInt64 = 0
    private var audioContinuityIslandSwitchCount: UInt64 = 0
    private var videoAdmissionOpen = false
    private var mediaInformation: PlaybackMediaInformation?
    private var mediaInformationGeneration: MediaGeneration?
    private var outputCadenceDurations: [CMTime] = []
    private var paused = false
    private var started = false
    private var terminal = false
    private var normalStopInProgress = false
    private var normalStopCompleted = false
    private var displayClearInProgress = false
    private var terminalEventPublished = false
    private var normalStopPublishes = false
    private var stopCompletions: [StopCompletion] = []
    private var readyPublished = false
    private var hasPublishedReadyInRun = false
    private var activePhaseWindow: PlaybackPipelinePhase?
    private var publishedPhase: PlaybackPipelinePhase?
    private var publishedPhaseReadinessCycle: UInt64?
    // Readiness cycle that display submission was last resumed for; `nil` until
    // the first resume. Paired with `readyPublished` so both an external close
    // (which clears `readyPublished`) and a gate-internal close (which only bumps
    // the cycle) let the next open resume submission again.
    private var displayResumedCycle: UInt64?
    private var hasOpenedReadinessForCurrentMedia = false
    private var readinessCycle: UInt64 = 0
    private var deferredPackets: [DemuxPacket] = []
    private var pendingPacketAdmission: PendingPacketAdmission?
    private var pendingTrackVideo = CompressedVideoReservoir(
        limits: PlaybackPipeline.pendingTrackVideoRetentionLimits
    )
    private var pendingTrackAudio: [CompressedAudioFrame] = []
    private var pendingTrackAudioByteBudget: OwnedByteBudget
    private var pendingVideoDecode = CompressedVideoReservoir(
        limits: PlaybackPipeline.pendingDecodeVideoRetentionLimits
    )
    private var pendingVideoDrainScheduled = false
    private var pendingVideoDrainToken: UInt64 = 0
    private var pendingVideoRecoveryAnchor: CMTime?
    private var outstandingVideoDecodeSubmissions: Set<DecoderSubmissionKey> = []
    private var failedVideoDecodeSubmissions: Set<DecoderSubmissionKey> = []
    private var reservedVideoDecodeSubmissions: Set<DecoderAdmissionReservation> = []
    private var outstandingVideoIntervalsBySubmission: [
        DecoderSubmissionKey: VideoTimestampInterval
    ] = [:]
    private var videoDecodeStallWatchdogScheduled = false
    private var videoDecodeStallWatchdogToken: UInt64 = 0
    private var videoDecodeBufferHorizon: CMTime?
    private var retainedVideo: [VideoPresentationFrame] = []
    private var preparedAnchor: PreparedAnchor?
    private var anchorPreparationTransaction: AnchorPreparationTransaction?
    private var supersededAnchorPreparationTransaction: AnchorPreparationTransaction?
    private var audioGapReanchorTransaction: AudioGapReanchorTransaction?
    private var pendingAnchorTimingRecoveryRevision: UInt64?
    private var lastHandledAnchorTimingRevision: UInt64?
    private var pendingDisplayTimingReset = false
    private var lastDisplayCriteriaKey: DisplayCriteriaKey?
    private var modeSwitchSignpost: PlaybackSignpostToken?

    init(
        executor: PlaybackSerialExecutor,
        demuxer: any MediaDemuxing,
        assemblerBuilder: any PlaybackAssemblerBuilding,
        decoder: any VideoDecoding,
        processor: any VideoFrameProcessing,
        yadifProcessor: any YADIFFrameProcessing,
        scanProbe: (any LumaScanProbing)? = nil,
        classifierConfiguration: ScanClassifierConfiguration = .init(),
        tuning: PlaybackTuning = .default,
        videoDecodeStallTimeout: DispatchTimeInterval = .seconds(1),
        videoDecodeStallScheduler: VideoDecodeStallScheduler? = nil,
        rawReadinessRequirementOverride: Int? = nil,
        pendingTrackAudioRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.pending,
        audioContinuityRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.continuity,
        renderer: any PlaybackVideoRendering,
        videoSurfaceLedger: VideoSurfaceBudgetLedger? = nil,
        audio: any AudioRenderPipelineProtocol,
        clock: any PlaybackClock,
        display: any PlaybackDisplayControlling,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void,
        presentationContext: PlaybackPresentationContext? = nil,
        metrics: PlaybackMetrics? = nil,
        signposts: PlaybackSignposts? = nil
    ) {
        self.executor = executor
        self.tuning = tuning
        self.videoDecodeStallTimeout = videoDecodeStallTimeout
        if let videoDecodeStallScheduler {
            self.videoDecodeStallScheduler = { delay, operation in
                videoDecodeStallScheduler(delay) {
                    executor.submit(operation)
                }
            }
        } else {
            self.videoDecodeStallScheduler = { delay, operation in
                executor.submit(after: delay, operation)
            }
        }
        self.pendingTrackAudioRetentionLimits = pendingTrackAudioRetentionLimits
        pendingTrackAudioByteBudget = OwnedByteBudget(
            limit: pendingTrackAudioRetentionLimits.maximumOwnedBytes
        )
        audioContinuity = AudioContinuityBuffer(
            retentionLimits: audioContinuityRetentionLimits
        )
        self.demuxer = demuxer
        self.assemblerBuilder = assemblerBuilder
        self.renderer = renderer
        self.videoSurfaceLedger = videoSurfaceLedger
        self.audio = audio
        self.clock = clock
        self.display = display
        self.eventSink = eventSink
        self.presentationContext = presentationContext
        self.metrics = metrics
        self.signposts = signposts
        videoCoordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: processor,
            yadif: yadifProcessor,
            probe: scanProbe,
            initialGeneration: generationController.current,
            classifierConfiguration: classifierConfiguration,
            rawReadinessRequirementOverride: rawReadinessRequirementOverride,
            metrics: metrics,
            signposts: signposts,
            hooks: VideoPipelineCoordinatorHooks(
                closeAdmission: { [weak self] in self?.closeCoordinatorAdmissionIsolated() },
                advanceGeneration: { [weak self] in
                    self?.advanceCoordinatorGenerationIsolated()
                        ?? MediaGeneration(rawValue: 0)
                },
                resetPlayback: { [weak self] generation, requiredCount, scope in
                    self?.resetCoordinatorPlaybackIsolated(
                        to: generation,
                        requiredVideoFrameCount: requiredCount,
                        resetScope: scope
                    )
                },
                submissionRejected: { [weak self] accessUnitID, identity in
                    self?.rejectCoordinatorSubmissionIsolated(
                        accessUnitID: accessUnitID,
                        identity: identity
                    )
                },
                decoderInvalidationBegan: { [weak self] ticket in
                    self?.decoderInvalidationBeganIsolated(ticket)
                },
                decoderInvalidationFinished: { [weak self] ticket, outcome in
                    self?.decoderInvalidationFinishedIsolated(ticket, outcome: outcome)
                },
                reopenAdmission: { [weak self] in self?.reopenCoordinatorAdmissionIsolated() },
                routeDidChange: { [weak self] requiredCount in
                    self?.coordinatorRouteDidChangeIsolated(
                        requiredVideoFrameCount: requiredCount
                    )
                },
                deliver: { [weak self] frames, generation in
                    self?.handleProcessedFrames(frames, generation: generation)
                },
                fail: { [weak self] failure, generation in
                    guard let self,
                          generationController.accepts(generation) else { return }
                    failIsolated(failure)
                },
                schedule: { [weak self] operation in self?.executor.submit(operation) }
            )
        )
    }

    func start(url: URL, readinessCycle: UInt64, initiallyPaused: Bool) {
        executor.submit { [weak self] in
            self?.startIsolated(
                url: url,
                readinessCycle: readinessCycle,
                initiallyPaused: initiallyPaused
            )
        }
    }

    func setPaused(_ paused: Bool, readinessCycle: UInt64) {
        executor.submit { [weak self] in
            self?.setPausedIsolated(paused, readinessCycle: readinessCycle)
        }
    }

    func recoverFromAudioSessionReset(readinessCycle: UInt64) {
        executor.submit { [weak self] in
            self?.recoverFromAudioSessionResetIsolated(readinessCycle: readinessCycle)
        }
    }

    func setTuning(_ tuning: PlaybackTuning) {
        executor.submit { [weak self] in
            guard let self, !terminal, self.tuning != tuning else { return }
            self.tuning = tuning
            renderer.apply(tuning)
            videoCoordinator.applyTuning(tuning)
            boundRetainedVideoIsolated()
            if let frame = retainedVideo.last {
                videoDecodeBufferHorizon = effectiveVideoBufferHorizon(for: frame)
            }
            updateMaximumAnchorLagIsolated(for: retainedVideo.last)
            drainPendingVideoDecodeIsolated()
        }
    }

    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        refreshExternalMetricsDiagnostics()
        renderer.refreshPerformanceMetrics()
        return metrics?.snapshot(window: window)
    }

    private func refreshExternalMetricsDiagnostics() {
        metrics?.update(audioDiagnostics: audio.diagnostics)
        metrics?.update(
            demuxQueueFullWaitNanoseconds: demuxer.queueFullWaitNanoseconds,
            demuxAdmitWaitNanoseconds: admitWaitNanoseconds.value,
            playbackExecutorBusyNanoseconds: executor.busyNanoseconds
        )
    }

    var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)? { metrics }

    func stop() async {
        await withCheckedContinuation { continuation in
            executor.submit { [self] in
                stopIsolated(publish: true) {
                    continuation.resume()
                }
            }
        }
    }

    func receive(video event: VideoAssemblerEvent) {
        submitOrRun { [weak self] in self?.handle(video: event) }
    }

    func receive(audio event: AudioAssemblerEvent) {
        submitOrRun { [weak self] in self?.handle(audio: event) }
    }

    private func receive(video event: VideoAssemblerEvent, from id: AssemblyEpochID) {
        submitOrRun { [weak self] in
            guard let self, assembly?.id == id else { return }
            handle(video: event)
        }
    }

    private func receive(audio event: AudioAssemblerEvent, from id: AssemblyEpochID) {
        submitOrRun { [weak self] in
            guard let self, assembly?.id == id else { return }
            handle(audio: event)
        }
    }

    func receive(decoder event: VideoDecoderEvent) {
        submitOrRun { [weak self] in self?.handle(decoder: event) }
    }

    func receive(failure: PlaybackCoreError, generation: MediaGeneration) {
        submitOrRun { [weak self] in
            guard let self, generationController.accepts(generation) else { return }
            failIsolated(failure)
        }
    }

    func receive(videoRendererRecovery generation: MediaGeneration) {
        submitOrRun { [weak self] in
            guard let self,
                  !terminal,
                  generationController.accepts(generation),
                  let readiness else { return }
            preparedAnchor = nil
            anchorPreparationTransaction = nil
            readyPublished = false
            if !pendingDisplayTimingReset {
                readiness.close(.buffering)
                beginControlledRecoveryPhaseWindowIsolated()
            }
            setSharedTimelineOpenedIsolated(false)
            display.pauseSubmission()
            updateReadinessIsolated()
        }
    }

    func receive(
        audioReadiness change: AudioRenderReadinessChange,
        generation: MediaGeneration
    ) {
        submitOrRun { [weak self] in
            guard let self,
                  !terminal,
                  generationController.accepts(generation) else { return }
            switch change {
            case .invalidated:
                if pendingAnchorTimingRecoveryRevision != nil { return }
                guard anchorPreparationTransaction == nil else { return }
                preparedAnchor = nil
                readiness?.close(.audioReplacement)
                readyPublished = false
                display.pauseSubmission()
                renderer.resetPresentationTiming()
            case .available:
                pendingAnchorTimingRecoveryRevision = nil
                updateReadinessIsolated()
            case .outputRouteAvailable:
                pendingAnchorTimingRecoveryRevision = nil
                updateReadinessIsolated()
            case .outputRouteUnavailable:
                beginAudioRouteRecoveryIsolated(timingRevision: nil)
            case let .anchorTimingChanged(routeRevision):
                guard audio.currentRouteSnapshot?.revision == routeRevision,
                      lastHandledAnchorTimingRevision != routeRevision else { return }
                lastHandledAnchorTimingRevision = routeRevision
                pendingAnchorTimingRecoveryRevision = routeRevision
                beginAudioRouteRecoveryIsolated(timingRevision: routeRevision)
            }
        }
    }

    private func beginAudioRouteRecoveryIsolated(timingRevision _: UInt64?) {
        assertIsolated()
        preparedAnchor = nil
        if let anchorPreparationTransaction {
            supersededAnchorPreparationTransaction = anchorPreparationTransaction
        }
        anchorPreparationTransaction = nil
        readyPublished = false
        readiness?.close(.audioReplacement)
        setSharedTimelineOpenedIsolated(false)
        display.pauseSubmission()
        renderer.resetPresentationTiming()
        beginControlledRecoveryPhaseWindowIsolated()
    }

    private func recoverFromAudioSessionResetIsolated(readinessCycle: UInt64) {
        assertIsolated()
        guard started, !terminal else { return }
        self.readinessCycle = readinessCycle
        beginAudioRouteRecoveryIsolated(timingRevision: nil)
        guard audioResourcesConfigured else {
            pendingAudioSessionReset = true
            return
        }
        pendingAudioSessionReset = false
        audio.recoverFromAudioSessionReset()
    }

    func refreshReadiness() {
        executor.submit { [weak self] in self?.updateReadinessIsolated() }
    }

    func displayModeSwitchStarted() {
        executor.submit { [weak self] in self?.displayModeSwitchStartedIsolated() }
    }

    func displayModeSwitchEnded() {
        executor.submit { [weak self] in self?.displayModeSwitchEndedIsolated() }
    }

    func debugSnapshot() async -> PlaybackPipelineSnapshot {
        await withCheckedContinuation { continuation in
            executor.submit { [weak self] in
                guard let self else {
                    continuation.resume(returning: PlaybackPipelineSnapshot(
                        generation: MediaGeneration(rawValue: 0),
                        hasTracks: false,
                        isPaused: false,
                        deferredPacketCount: 0,
                        isTerminal: true,
                        requiredVideoFrameCount: 1,
                        mediaAdmissionOpen: false,
                        videoAdmissionOpen: false,
                        pendingVideoDecodeCount: 0,
                        outstandingVideoDecodeCount: 0,
                        audioGapVideoEvidenceRecordCount: 0
                    ))
                    return
                }
                assertIsolated()
                continuation.resume(returning: PlaybackPipelineSnapshot(
                    generation: generationController.current,
                    hasTracks: tracks != nil,
                    isPaused: paused,
                    deferredPacketCount: deferredPackets.count,
                    isTerminal: terminal,
                    requiredVideoFrameCount: videoCoordinator.requiredVideoFrameCount,
                    mediaAdmissionOpen: mediaAdmissionOpen,
                    videoAdmissionOpen: videoAdmissionOpen,
                    pendingVideoDecodeCount: pendingVideoDecode.count,
                    outstandingVideoDecodeCount:
                        outstandingVideoDecodeSubmissions.count,
                    audioGapVideoEvidenceRecordCount:
                        audioGapReanchorTransaction?.evidenceRecordCount ?? 0
                ))
            }
        }
    }

    static func coreError(for failure: VideoDecoderFailure) -> PlaybackCoreError {
        switch failure {
        case let .sessionCreate(status):
            .videoDecode(status)
        case .softwareDecoder:
            .hardwareDecoderUnavailable
        case let .badData(status), let .malfunction(status):
            .videoDecode(status)
        case .backpressureTimeout:
            .videoDecode(kVTVideoDecoderNotAvailableNowErr)
        }
    }

    private func submitOrRun(_ operation: @escaping @Sendable () -> Void) {
        if executor.isIsolated {
            operation()
        } else {
            executor.submit(operation)
        }
    }

    private func assertIsolated() {
        precondition(executor.isIsolated, "playback pipeline state escaped its executor")
    }

    private func startIsolated(
        url: URL,
        readinessCycle: UInt64,
        initiallyPaused: Bool
    ) {
        assertIsolated()
        guard !started, !terminal else { return }
        started = true
        setSharedTimelineOpenedIsolated(false)
        readiness = PlaybackReadinessGate(clock: clock, prepareAnchorVeto: { [weak self] commonPTS in
            guard let self else { return false }
            return prepareAnchorIsolated(commonPTS: commonPTS)
        })
        readiness?.setMaximumAnchorLag(tuning.maximumAnchorLag)
        readiness?.configure(requiredVideoFrameCount: videoCoordinator.requiredVideoFrameCount)
        readiness?.setAnchorLeadTime(audio.anchorLeadTime)
        self.readinessCycle = readinessCycle
        if initiallyPaused {
            paused = true
            clock.pause()
            readiness?.close(.pause)
            display.pauseSubmission()
        }
        beginInitialBufferingPhaseWindowIsolated()
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            failIsolated(.unsupportedProtocol(scheme))
            return
        }
        do {
            try demuxer.start(url: url) { [weak self] event in
                self?.admit(event)
            }
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.demuxOpen(-1))
        }
    }

    private func admit(_ event: DemuxEvent) {
        let acknowledgement = DispatchSemaphore(value: 0)
        if executor.isIsolated {
            handleDemux(event, acknowledgement: acknowledgement)
            return
        }
        executor.submit { [weak self] in
            guard let self else {
                acknowledgement.signal()
                return
            }
            handleDemux(event, acknowledgement: acknowledgement)
        }
        // Delivery is a blocking round trip per packet, so this is the playback
        // executor's backlog measured from the demux side. Compared against the
        // demuxer's own queue-full wait it says which side of the handshake is
        // holding the read path back.
        let waitStart = DispatchTime.now().uptimeNanoseconds
        acknowledgement.wait()
        admitWaitNanoseconds.add(DispatchTime.now().uptimeNanoseconds &- waitStart)
    }

    private func handleDemux(_ event: DemuxEvent, acknowledgement: DispatchSemaphore) {
        assertIsolated()
        guard !terminal else {
            acknowledgement.signal()
            return
        }
        if case let .packet(packet) = event, paused {
            if deferredPackets.count < Self.deferredPacketCapacity {
                deferredPackets.append(packet)
                acknowledgement.signal()
            } else {
                pendingPacketAdmission = PendingPacketAdmission(
                    packet: packet,
                    acknowledgement: acknowledgement
                )
            }
            return
        }
        handleDemuxIsolated(event)
        acknowledgement.signal()
    }

    private func handleDemuxIsolated(_ event: DemuxEvent) {
        assertIsolated()
        guard !terminal else { return }
        do {
            switch event {
            case let .tracks(newTracks):
                try installTracksIsolated(newTracks, timelineReset: false)
            case let .packet(packet):
                metrics?.recordDemuxPacket()
                try routePacketIsolated(packet)
            case let .discontinuity(newTracks, reason):
                try installTracksIsolated(
                    newTracks,
                    timelineReset: reason == .timelineReset
                )
            case .endOfStream:
                stopIsolated(publish: true, completion: nil)
            case .cancelled:
                failIsolated(.cancelled)
            case let .failure(error):
                failIsolated(error)
            }
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch let error as VideoDecoderFailure {
            failIsolated(Self.coreError(for: error))
        } catch {
            failIsolated(.demuxRead(-1))
        }
    }

    private func installTracksIsolated(
        _ newTracks: DemuxTrackSet,
        timelineReset: Bool
    ) throws {
        assertIsolated()
        guard newTracks.audio != nil else { throw PlaybackCoreError.unsupportedAudioCodec }
        if let tracks, tracks == newTracks, !timelineReset { return }

        let replacesExistingAssembly = assembly != nil
        beginTrackEpochIsolated()
        if replacesExistingAssembly {
            try forceAdvanceGenerationIsolated()
            guard !terminal else { return }
            trackEpochAlreadyAdvanced = true
        }

        nextTimelineEpochRawValue &+= 1
        nextAssemblyInstanceToken &+= 1
        let id = AssemblyEpochID(
            timelineEpoch: TimelineEpochID(rawValue: nextTimelineEpochRawValue),
            instanceToken: nextAssemblyInstanceToken
        )
        let binding = AssemblyEpochBinding(epochID: id)
        let sharedState = AssemblyFormatState(trackSet: newTracks)
        do {
            let video: (any VideoAccessUnitAssembling)?
            if newTracks.video != nil {
                video = try assemblerBuilder.makeVideo(
                    trackSet: newTracks,
                    generationProvider: { [weak self] in
                        guard let self else { return MediaGeneration(rawValue: 0) }
                        self.assertIsolated()
                        return self.generationController.current
                    },
                    eventSink: { [weak self] event in
                        self?.receive(video: event, from: id)
                    },
                    formatState: sharedState,
                    binding: binding
                )
            } else {
                video = nil
            }
            let audio = try assemblerBuilder.makeAudio(
                trackSet: newTracks,
                generationProvider: { [weak self] in
                    guard let self else { return MediaGeneration(rawValue: 0) }
                    self.assertIsolated()
                    return self.generationController.current
                },
                eventSink: { [weak self] event in
                    self?.receive(audio: event, from: id)
                },
                formatState: sharedState,
                binding: binding
            )
            let candidate = AssemblyTransaction(
                id: id,
                binding: binding,
                tracks: newTracks,
                formatState: sharedState,
                video: video,
                audio: audio
            )
            assembly?.binding.invalidate()
            assembly = candidate
        } catch {
            binding.invalidate()
            assembly?.binding.invalidate()
            throw error
        }
    }

    private func routePacketIsolated(_ packet: DemuxPacket) throws {
        assertIsolated()
        guard let tracks else { return }
        if packet.streamIndex == tracks.video?.streamIndex,
           packet.codec == tracks.video.map({ .video($0.codec) }) {
            guard !packet.isCorrupt else { return }
            try videoAssembler?.push(packet)
        } else if packet.streamIndex == tracks.audio?.streamIndex,
                  packet.codec == tracks.audio.map({ .audio($0.codec) }) {
            try audioAssembler?.push(packet)
        }
    }

    private func handle(video event: VideoAssemblerEvent) {
        assertIsolated()
        guard !terminal else { return }
        do {
            switch event {
            case let .format(format, fingerprint):
                videoFormat = format
                freshVideoFormatArrived = true
                try consumeCanonicalFingerprintIsolated(latestEventFingerprint: fingerprint)
            case let .accessUnit(accessUnit):
                metrics?.recordVideoAccessUnit()
                guard mediaAdmissionOpen else {
                    if awaitingFreshTrackEpoch || pendingVideoFormatCommit != nil {
                        bufferTrackVideoIsolated(accessUnit)
                    }
                    return
                }
                guard videoAdmissionOpen else {
                    admitVideoAccessUnitIsolated(accessUnit)
                    return
                }
                admitVideoAccessUnitIsolated(accessUnit)
            }
        } catch let error as VideoDecoderFailure {
            failIsolated(Self.coreError(for: error))
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.videoDecode(-1))
        }
    }

    private func handle(audio event: AudioAssemblerEvent) {
        assertIsolated()
        guard !terminal else { return }
        do {
            switch event {
            case let .format(configuration):
                audioConfiguration = configuration
                freshAudioFormatArrived = true
                try consumeCanonicalFingerprintIsolated(
                    latestEventFingerprint: configuration.fingerprint
                )
            case .decodeBreak:
                audioContinuity.markDecodeBreak()
            case let .frame(frame):
                metrics?.recordAudioSample()
                videoCoordinator.observeAudioTimelineOrigin(frame.presentationTimeStamp)
                guard mediaAdmissionOpen else {
                    if awaitingFreshTrackEpoch || pendingVideoFormatCommit != nil {
                        try bufferTrackAudioIsolated(frame)
                    }
                    return
                }
                try admitAudioFrameIsolated(frame)
            }
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.audioRendererFailed("audio.pipeline"))
        }
    }

    private func bufferTrackVideoIsolated(_ accessUnit: CompressedVideoAccessUnit) {
        assertIsolated()
        guard generationController.accepts(accessUnit.generation) else { return }
        let mutation = pendingTrackVideo.append(accessUnit)
        if mutation.droppedCount > 0 {
            metrics?.recordVideoDrop(
                count: mutation.droppedCount,
                source: .decodeSubmissionBacklog
            )
        } else if !mutation.accepted {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
        }
    }

    private func bufferTrackAudioIsolated(_ frame: CompressedAudioFrame) throws {
        assertIsolated()
        guard generationController.accepts(frame.generation) else { return }
        guard try pendingTrackAudioPayloadBytes(of: pendingTrackAudio)
                == pendingTrackAudioByteBudget.used else {
            throw pendingTrackAudioAccountingFailure()
        }
        var plannedFrames = pendingTrackAudio
        plannedFrames.append(frame)

        while plannedFrames.count > pendingTrackAudioRetentionLimits.maximumCount {
            plannedFrames.removeFirst()
        }

        while try pendingTrackAudioPayloadBytes(of: plannedFrames)
                > pendingTrackAudioRetentionLimits.maximumOwnedBytes {
            guard plannedFrames.count > 1 else {
                throw pendingTrackAudioCapacityFailure()
            }
            plannedFrames.removeFirst()
        }

        while try pendingTrackAudioTailSpan(of: plannedFrames).map({ span in
            CMTimeCompare(span, pendingTrackAudioRetentionLimits.latestTailHorizon) > 0
        }) == true {
            guard plannedFrames.count > 1 else {
                throw pendingTrackAudioCapacityFailure()
            }
            plannedFrames.removeFirst()
        }

        var plannedBudget = OwnedByteBudget(
            limit: pendingTrackAudioRetentionLimits.maximumOwnedBytes
        )
        for retained in plannedFrames {
            guard try plannedBudget.reserve(retained.payload.count) else {
                throw pendingTrackAudioCapacityFailure()
            }
        }
        pendingTrackAudio = plannedFrames
        pendingTrackAudioByteBudget = plannedBudget
    }

    private func pendingTrackAudioPayloadBytes(
        of frames: [CompressedAudioFrame]
    ) throws -> Int {
        var budget = OwnedByteBudget(limit: Int.max)
        for frame in frames {
            guard try budget.reserve(frame.payload.count) else {
                throw pendingTrackAudioAccountingFailure()
            }
        }
        return budget.used
    }

    private func pendingTrackAudioTailSpan(
        of frames: [CompressedAudioFrame]
    ) throws -> CMTime? {
        guard let oldest = frames.first, let newest = frames.last else { return nil }
        guard oldest.presentationTimeStamp.isNumeric,
              newest.presentationTimeStamp.isNumeric,
              newest.duration.isNumeric,
              CMTimeCompare(newest.duration, .zero) > 0 else {
            throw pendingTrackAudioAccountingFailure()
        }
        let newestEnd = CMTimeAdd(newest.presentationTimeStamp, newest.duration)
        let span = CMTimeSubtract(newestEnd, oldest.presentationTimeStamp)
        guard newestEnd.isNumeric, span.isNumeric,
              CMTimeCompare(span, .zero) > 0 else {
            throw pendingTrackAudioAccountingFailure()
        }
        return span
    }

    private func clearPendingTrackAudioIsolated(keepingCapacity: Bool) {
        pendingTrackAudio.removeAll(keepingCapacity: keepingCapacity)
        pendingTrackAudioByteBudget.reset()
    }

    private func pendingTrackAudioCapacityFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.pendingCapacityError)
    }

    private func pendingTrackAudioAccountingFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
    }

    private func replayPendingTrackMediaIsolated() throws {
        assertIsolated()
        let generation = generationController.current
        let video = pendingTrackVideo.elements
        let audioFrames = pendingTrackAudio
        pendingTrackVideo.removeAll(keepingCapacity: true)
        clearPendingTrackAudioIsolated(keepingCapacity: true)

        if let firstAudioFrame = audioFrames.first {
            videoCoordinator.observeAudioTimelineOrigin(
                firstAudioFrame.presentationTimeStamp
            )
        }

        for accessUnit in video where !terminal {
            admitVideoAccessUnitIsolated(CompressedVideoAccessUnit(
                id: accessUnit.id,
                sampleBuffer: accessUnit.sampleBuffer,
                generation: generation,
                isRandomAccess: accessUnit.isRandomAccess,
                parserMetadata: accessUnit.parserMetadata
            ))
        }
        for frame in audioFrames where !terminal {
            try admitAudioFrameIsolated(CompressedAudioFrame(
                id: frame.id,
                payload: frame.payload,
                codec: frame.codec,
                generation: generation,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                frameSampleCount: frame.frameSampleCount
            ))
        }
    }

    private func admitVideoAccessUnitIsolated(_ accessUnit: CompressedVideoAccessUnit) {
        assertIsolated()
        guard generationController.accepts(accessUnit.generation) else { return }
        pendingVideoDecode.removeAll {
            !generationController.accepts($0.generation)
        }
        drainPendingVideoDecodeIsolated()
        let preserveAudioGapRandomAccess = shouldPreserveAudioGapRandomAccessIsolated(
            accessUnit
        )
        let audioGapFloor = preserveAudioGapRandomAccess
            ? audioGapReanchorTransaction?.audioFirstPTS
            : nil
        let mayAdvanceForOpenReadiness = readiness?.isOpen == true
        let mutation = pendingVideoDecode.append(
            accessUnit,
            decodableSuffixMayStartAt: { candidate in
                if let audioGapFloor {
                    let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(
                        candidate.sampleBuffer
                    )
                    return presentationTimeStamp.isNumeric
                        && CMTimeCompare(presentationTimeStamp, audioGapFloor) >= 0
                }
                return mayAdvanceForOpenReadiness
            }
        )
        if mutation.droppedCount > 0 {
            metrics?.recordVideoDrop(
                count: mutation.droppedCount,
                source: .decodeSubmissionBacklog
            )
            pendingVideoRecoveryAnchor = nil
        } else if !mutation.accepted {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
        }
        // Every running-path access unit goes through the same credit-bound FIFO.
        // A temporarily empty queue must not create a direct-admission bypass for
        // the remainder of the same HLS segment burst.
        drainPendingVideoDecodeIsolated()
    }

    private func shouldPreserveAudioGapRandomAccessIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) -> Bool {
        assertIsolated()
        guard accessUnit.isRandomAccess,
              let transaction = audioGapReanchorTransaction,
              transaction.phase == .waitingForOutstandingVideo
                || transaction.phase == .waitingForRandomAccess else { return false }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(
            accessUnit.sampleBuffer
        )
        guard presentationTimeStamp.isNumeric,
              CMTimeCompare(presentationTimeStamp, transaction.audioFirstPTS) >= 0 else {
            return false
        }
        return !pendingVideoDecode.contains { pending in
            guard pending.isRandomAccess else { return false }
            let pendingPTS = CMSampleBufferGetPresentationTimeStamp(pending.sampleBuffer)
            return pendingPTS.isNumeric
                && CMTimeCompare(pendingPTS, transaction.audioFirstPTS) >= 0
        }
    }

    private func admitAudioFrameIsolated(_ frame: CompressedAudioFrame) throws {
        assertIsolated()
        guard generationController.accepts(frame.generation) else {
            recordAudioContinuityDrop(.staleGeneration)
            return
        }
        guard let audioConfiguration else { return }
        let admitted: AdmittedAudioFrame
        switch try audioContinuity.admit(frame) {
        case let .dropped(reason):
            recordAudioContinuityDrop(reason)
            return
        case let .admitted(value):
            admitted = value
        }
        if admitted.gapBefore != nil {
            if admitted.startsNewIsland {
                PlaybackDiagnosticSaturatingCounter.increment(&audioLargeGapCount)
                PlaybackDiagnosticSaturatingCounter.increment(
                    &audioContinuityIslandSwitchCount
                )
            } else {
                PlaybackDiagnosticSaturatingCounter.increment(&audioShortGapCount)
            }
            publishAudioContinuityDiagnostics()
        }
        if admitted.startsNewIsland {
            if admitted.gapBefore != nil {
                try beginAudioGapReanchorIsolated(for: admitted)
                guard !terminal else { return }
            }
            audio.activateContinuityIsland(
                admitted.continuityIslandID,
                generation: frame.generation
            )
        }
        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: admitted,
            formatDescription: audioConfiguration.formatDescription,
            forceResetDecoderBeforeDecoding: false
        )
        let sample = CompressedAudioSample(
            id: frame.id,
            sampleBuffer: sampleBuffer,
            codec: frame.codec,
            generation: frame.generation,
            presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
            duration: admitted.duration,
            continuityIslandID: admitted.continuityIslandID,
            effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
        )
        try audio.enqueue(sample)
        drainPendingVideoDecodeIsolated()
        boundRetainedVideoIsolated()
        updateReadinessIsolated()
    }

    private func beginAudioGapReanchorIsolated(
        for admitted: AdmittedAudioFrame
    ) throws {
        assertIsolated()
        guard admitted.startsNewIsland,
              admitted.gapBefore != nil,
              generationController.accepts(admitted.frame.generation),
              let readiness else { return }
        readiness.close(.audioGap)
        guard synchronizeAudioRecoveryFloorIsolated(
            readiness.minimumRecoveryAnchorPTS
        ) else { return }
        setSharedTimelineOpenedIsolated(false)
        readyPublished = false
        preparedAnchor = nil
        anchorPreparationTransaction = nil
        pendingVideoRecoveryAnchor = admitted.normalizedPresentationTimeStamp
        display.pauseSubmission()
        beginControlledRecoveryPhaseWindowIsolated()

        let requiresVideo = tracks?.video != nil
        let phase: AudioGapReanchorTransaction.Phase
        if !requiresVideo {
            phase = .preparingAnchor
        } else if outstandingVideoDecodeSubmissions.isEmpty {
            clearRetainedVideoIsolated(keepingCapacity: true)
            renderer.flush(to: admitted.frame.generation)
            phase = .waitingForRandomAccess
        } else {
            phase = .waitingForOutstandingVideo
        }
        audioGapReanchorTransaction = AudioGapReanchorTransaction(
            islandID: admitted.continuityIslandID,
            audioFirstPTS: admitted.normalizedPresentationTimeStamp,
            generation: admitted.frame.generation,
            phase: phase,
            submittedAccessUnitIDRange: nil
        )
    }

    private func shouldDeferVideoDecodeIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) -> Bool {
        assertIsolated()
        // There is no authoritative clock before the first readiness open. Drive
        // bootstrap from actual media state instead of guessing an acceptable
        // A/V timestamp skew: decode until enough video overlaps retained audio,
        // continue when video is behind, and wait for audio when video is ahead.
        if !hasOpenedReadinessForCurrentMedia {
            return shouldDeferStartupVideoDecodeIsolated(accessUnit)
        }

        let bufferHorizon = videoDecodeBufferHorizon ?? tuning.videoBufferHorizon
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
        guard videoPTS.isNumeric,
              bufferHorizon.isNumeric else { return false }
        // HLS can deliver several seconds in one burst. Keep the excess as
        // compressed access units, but let the decoded window use the capacity
        // the presentation path can actually retain. That capacity is derived
        // from the active format's surface size and the configured buffer, so a
        // frame-threaded HD decoder gets enough input to produce continuously
        // while 4K P010 cannot claim the same number of decoded surfaces.
        let decodedLead = bufferHorizon

        // Once playback is open, the synchronizer clock is authoritative. The
        // retained audio array is recovery history, not the renderer's actual
        // queue; a bounded history can contain a gap after an HLS startup burst
        // even while the renderer continues normally. Letting that historical
        // gap cap video decode creates a closed loop where video can never reach
        // the next keyframe. This is the steady-state equivalent of a small
        // decoded frame queue backed by a larger compressed packet queue.
        if hasOpenedReadinessForCurrentMedia, readiness?.isOpen == true {
            let decodeLimit = CMTimeAdd(clock.currentTime, decodedLead)
            guard decodeLimit.isNumeric else { return false }
            return CMTimeCompare(videoPTS, decodeLimit) > 0
        }

        if hasOpenedReadinessForCurrentMedia {
            // Recovery is paced around a monotonic target, even while audio has
            // not yet rebuilt a contiguous island. Returning "not deferred"
            // here used to empty a whole HLS segment into the decoder while the
            // shared clock was paused.
            var recoveryTime = pendingVideoRecoveryAnchor ?? videoPTS
            if let floor = readiness?.minimumRecoveryAnchorPTS,
               floor.isNumeric,
               CMTimeCompare(floor, recoveryTime) > 0 {
                recoveryTime = floor
            }
            let currentTime = clock.currentTime
            if currentTime.isNumeric, CMTimeCompare(currentTime, recoveryTime) > 0 {
                recoveryTime = currentTime
            }
            let audioInterval = activeAudioIntervalIsolated()
            if let audioFirst = audioInterval?.first,
               CMTimeCompare(audioFirst, recoveryTime) > 0 {
                recoveryTime = audioFirst
            }
            pendingVideoRecoveryAnchor = recoveryTime

            let recoveryLimit = CMTimeAdd(recoveryTime, decodedLead)
            guard recoveryLimit.isNumeric else { return false }
            var decodeLimit = recoveryLimit
            if let audioInterval {
                let audioEnd = CMTimeAdd(audioInterval.first, audioInterval.duration)
                let audioLeadLimit = CMTimeAdd(audioEnd, decodedLead)
                if audioLeadLimit.isNumeric,
                   CMTimeCompare(audioLeadLimit, decodeLimit) < 0 {
                    decodeLimit = audioLeadLimit
                }
            }
            if CMTimeCompare(videoPTS, decodeLimit) > 0,
               pendingDecodeOrderNeedsHeadIsolated(
                   accessUnit,
                   toReachPresentationPTSAtOrBefore: decodeLimit
               ) {
                return false
            }
            return CMTimeCompare(videoPTS, decodeLimit) > 0
        }

        return false
    }

    private func shouldDeferStartupVideoDecodeIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) -> Bool {
        assertIsolated()
        guard !retainedVideo.isEmpty else { return false }
        // A provisional raw frame cannot satisfy video readiness while scan
        // classification is unresolved. Keep feeding the bounded decoder/probe
        // path until the coordinator selects the actual presentation route.
        guard videoCoordinator.isClassificationResolved else { return false }
        let requiredFrameCount = videoCoordinator.requiredVideoFrameCount
        guard let audioInterval = activeAudioIntervalIsolated() else {
            return retainedVideo.count >= requiredFrameCount
        }
        let audioEnd = CMTimeAdd(audioInterval.first, audioInterval.duration)
        guard audioEnd.isNumeric else { return false }

        // Readiness requires the audio interval to cover each selected frame's
        // end. Apply that same condition to decode admission: merely touching
        // the next frame must not pause decode in a state the gate cannot open.
        let audioCoveredFrameCount = retainedVideo.filter { frame in
            let frameEnd = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return frameEnd.isNumeric
                && CMTimeCompare(frameEnd, audioInterval.first) > 0
                && CMTimeCompare(frameEnd, audioEnd) <= 0
        }.count
        if audioCoveredFrameCount >= requiredFrameCount {
            return true
        }

        guard let firstVideoPTS = retainedVideo.first?.presentationTimeStamp,
              let lastVideo = retainedVideo.last else { return false }
        let lastVideoEnd = CMTimeAdd(lastVideo.presentationTimeStamp, lastVideo.duration)
        guard firstVideoPTS.isNumeric, lastVideoEnd.isNumeric else { return false }
        if CMTimeCompare(lastVideoEnd, audioInterval.first) <= 0 {
            // Decoded video is still wholly behind audio; keep walking the GOP.
            return false
        }
        if CMTimeCompare(firstVideoPTS, audioEnd) >= 0 {
            // Video is wholly ahead. Wait for audio unless the FIFO head (or a
            // following B picture that depends on it) is already inside audio's
            // observed interval.
            let videoPTS = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
            if videoPTS.isNumeric, CMTimeCompare(videoPTS, audioEnd) < 0 {
                return false
            }
            if pendingDecodeOrderNeedsHeadIsolated(
                accessUnit,
                toReachPresentationPTSAtOrBefore: audioEnd
            ) {
                return false
            }
            return true
        }

        // The intervals overlap but the selected route still needs more frames
        // (for example the two field-rate outputs required by YADIF).
        return false
    }

    // Decode order and presentation order differ for B-frame streams. A future
    // reference picture can sit at the FIFO head while a following B picture is
    // already needed by startup or recovery; HEVC CRA can likewise precede a
    // leading RASL picture with an earlier PTS. Deferring either safe decode-order
    // head prevents the eligible picture from ever decoding.
    private func pendingDecodeOrderNeedsHeadIsolated(
        _ head: CompressedVideoAccessUnit,
        toReachPresentationPTSAtOrBefore limit: CMTime
    ) -> Bool {
        assertIsolated()
        guard let first = pendingVideoDecode.first,
              first.id == head.id,
              first.generation == head.generation else { return false }
        let followingStart = pendingVideoDecode.index(after: pendingVideoDecode.startIndex)
        let nextRandomAccess = pendingVideoDecode.dropFirst().firstIndex(where: \.isRandomAccess)
            ?? pendingVideoDecode.endIndex
        return pendingVideoDecode[followingStart..<nextRandomAccess].contains { accessUnit in
                let pts = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
                return pts.isNumeric && CMTimeCompare(pts, limit) <= 0
            }
    }

    private func drainPendingVideoDecodeIsolated() {
        assertIsolated()
        pendingVideoDecode.removeAll {
            !generationController.accepts($0.generation)
        }
        guard canDrainVideoDecodeIsolated else { return }
        if drainAudioGapVideoReanchorIsolated() {
            scheduleVideoDecodeStallWatchdogIfNeededIsolated()
            schedulePendingVideoDrainIsolated()
            return
        }
        alignPendingVideoRecoveryAcrossGapIsolated()
        while canDrainVideoDecodeIsolated,
              outstandingVideoDecodeSubmissions.count
                  < Self.maximumOutstandingVideoDecodeSubmissions,
              let accessUnit = pendingVideoDecode.first,
              !shouldDeferVideoDecodeIsolated(accessUnit) {
            pendingVideoDecode.removeFirst()
            submitVideoAccessUnitIsolated(accessUnit)
        }
        scheduleVideoDecodeStallWatchdogIfNeededIsolated()
        schedulePendingVideoDrainIsolated()
    }

    /// Returns true while an audio-gap transaction exclusively owns video
    /// decode admission.
    private func drainAudioGapVideoReanchorIsolated() -> Bool {
        assertIsolated()
        guard var transaction = audioGapReanchorTransaction else { return false }
        guard generationController.accepts(transaction.generation) else {
            audioGapReanchorTransaction = nil
            return false
        }

        if transaction.phase == .waitingForOutstandingVideo {
            guard outstandingVideoDecodeSubmissions.isEmpty else { return true }
            clearRetainedVideoIsolated(keepingCapacity: true)
            renderer.flush(to: transaction.generation)
            transaction.phase = .waitingForRandomAccess
            audioGapReanchorTransaction = transaction
        }

        if transaction.phase == .waitingForRandomAccess {
            guard let randomAccessIndex = pendingVideoDecode.firstIndex(where: { accessUnit in
                guard accessUnit.isRandomAccess else { return false }
                let pts = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
                return pts.isNumeric
                    && CMTimeCompare(pts, transaction.audioFirstPTS) >= 0
            }) else {
                pendingVideoDecode.removeAll(keepingCapacity: true)
                return true
            }
            if randomAccessIndex > pendingVideoDecode.startIndex {
                metrics?.recordVideoDrop(
                    count: pendingVideoDecode.distance(
                        from: pendingVideoDecode.startIndex,
                        to: randomAccessIndex
                    ),
                    source: .decodeSubmissionBacklog
                )
                pendingVideoDecode.removeFirst(randomAccessIndex)
            }
            guard let firstRecoveryAccessUnit = pendingVideoDecode.first else {
                return true
            }
            videoCoordinator.installProcessingAdmissionFloor(
                generation: transaction.generation,
                minimumAccessUnitID: firstRecoveryAccessUnit.id,
                minimumOutputPTS: transaction.audioFirstPTS
            )
            transaction.phase = .videoPreroll
            audioGapReanchorTransaction = transaction
        }

        guard transaction.phase == .videoPreroll else { return true }
        while canDrainVideoDecodeIsolated,
              outstandingVideoDecodeSubmissions.count
                  < Self.maximumOutstandingVideoDecodeSubmissions,
              let accessUnit = pendingVideoDecode.first {
            pendingVideoDecode.removeFirst()
            guard var currentTransaction = audioGapReanchorTransaction,
                  currentTransaction.phase == .videoPreroll else { return true }
            currentTransaction.recordSubmission(accessUnitID: accessUnit.id)
            audioGapReanchorTransaction = currentTransaction
            submitVideoAccessUnitIsolated(accessUnit)
        }
        return true
    }

    private var canDrainVideoDecodeIsolated: Bool {
        assertIsolated()
        return !terminal
            && mediaAdmissionOpen
            && videoAdmissionOpen
            && !videoCoordinator.isDecoderTransitionPending
    }

    private func submitVideoAccessUnitIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) {
        assertIsolated()
        let reservation = DecoderAdmissionReservation(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation
        )
        guard reservedVideoDecodeSubmissions.insert(reservation).inserted else {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
            return
        }
        guard videoCoordinator.handle(accessUnit: accessUnit),
              let identity = videoCoordinator.currentDecoderIdentity,
              identity.generation == accessUnit.generation else {
            reservedVideoDecodeSubmissions.remove(reservation)
            return
        }
        let key = DecoderSubmissionKey(
            accessUnitID: accessUnit.id,
            identity: identity
        )
        guard outstandingVideoDecodeSubmissions.insert(key).inserted else {
            reservedVideoDecodeSubmissions.remove(reservation)
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
            return
        }
        if let interval = videoTimestampInterval(for: accessUnit) {
            outstandingVideoIntervalsBySubmission[key] = interval
        }
        scheduleVideoDecodeStallWatchdogIfNeededIsolated()
    }

    private func rejectCoordinatorSubmissionIsolated(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity
    ) {
        assertIsolated()
        let key = DecoderSubmissionKey(
            accessUnitID: accessUnitID,
            identity: identity
        )
        guard outstandingVideoDecodeSubmissions.remove(key) != nil else { return }
        reservedVideoDecodeSubmissions.remove(DecoderAdmissionReservation(
            accessUnitID: accessUnitID,
            generation: identity.generation
        ))
        failedVideoDecodeSubmissions.remove(key)
        outstandingVideoIntervalsBySubmission.removeValue(forKey: key)
        invalidateVideoDecodeStallWatchdogIsolated()
    }

    private func videoTimestampInterval(
        for accessUnit: CompressedVideoAccessUnit
    ) -> VideoTimestampInterval? {
        assertIsolated()
        let first = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
        guard first.isNumeric else { return nil }
        let duration = CMSampleBufferGetDuration(accessUnit.sampleBuffer)
        let end = duration.isNumeric && CMTimeCompare(duration, .zero) > 0
            ? CMTimeAdd(first, duration)
            : first
        guard end.isNumeric else { return nil }
        return VideoTimestampInterval(first: first, end: end)
    }

    private func scheduleVideoDecodeStallWatchdogIfNeededIsolated() {
        assertIsolated()
        guard !terminal,
              !paused,
              !videoCoordinator.isDecoderTransitionPending,
              videoCoordinator.currentDecoderIdentity != nil,
              outstandingVideoDecodeSubmissions.count
                  >= Self.maximumOutstandingVideoDecodeSubmissions,
              !videoDecodeStallWatchdogScheduled else { return }
        videoDecodeStallWatchdogScheduled = true
        let token = videoDecodeStallWatchdogToken
        let expectedGeneration = generationController.current
        videoDecodeStallScheduler(videoDecodeStallTimeout) { [weak self] in
            guard let self,
                  videoDecodeStallWatchdogToken == token else { return }
            videoDecodeStallWatchdogScheduled = false
            guard !terminal,
                  !paused,
                  !videoCoordinator.isDecoderTransitionPending,
                  generationController.current == expectedGeneration,
                  outstandingVideoDecodeSubmissions.count
                      >= Self.maximumOutstandingVideoDecodeSubmissions else { return }
            // No completion freed a single slot for the whole timeout. Treat
            // this as the same decoder hang that its internal ninth-submission
            // wait used to detect before upstream credit prevented that probe.
            guard let identity = videoCoordinator.currentDecoderIdentity,
                  let stalled = outstandingVideoDecodeSubmissions.first(where: {
                      $0.identity == identity
                  }) else { return }
            handle(decoder: .submissionFailure(
                accessUnitID: stalled.accessUnitID,
                failure: .backpressureTimeout,
                identity: identity
            ))
        }
    }

    private func invalidateVideoDecodeStallWatchdogIsolated() {
        assertIsolated()
        videoDecodeStallWatchdogToken &+= 1
        videoDecodeStallWatchdogScheduled = false
    }

    // Keep the current GOP when it reaches the paused clock normally. If a real
    // timestamp hole leaves the next picture outside the bounded recovery
    // window, resume only at an independently decodable picture; otherwise the
    // closed gate can wait forever on a PTS it has deliberately deferred.
    private func alignPendingVideoRecoveryAcrossGapIsolated() {
        assertIsolated()
        guard hasOpenedReadinessForCurrentMedia,
              readiness?.isOpen != true,
              let recoveryFloor = readiness?.minimumRecoveryAnchorPTS,
              recoveryFloor.isNumeric,
              outstandingVideoDecodeSubmissions.isEmpty,
              let head = pendingVideoDecode.first else { return }
        let hasRetainedCoverageAtFloor = retainedVideo.contains { frame in
            let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return end.isNumeric && CMTimeCompare(end, recoveryFloor) > 0
        }
        guard !hasRetainedCoverageAtFloor else { return }
        let headPTS = CMSampleBufferGetPresentationTimeStamp(head.sampleBuffer)
        guard headPTS.isNumeric else { return }

        var anchor = pendingVideoRecoveryAnchor ?? headPTS
        if CMTimeCompare(recoveryFloor, anchor) > 0 {
            anchor = recoveryFloor
        }
        let currentTime = clock.currentTime
        if currentTime.isNumeric, CMTimeCompare(currentTime, anchor) > 0 {
            anchor = currentTime
        }
        if let audioFirst = activeAudioIntervalIsolated()?.first,
           CMTimeCompare(audioFirst, anchor) > 0 {
            anchor = audioFirst
        }
        pendingVideoRecoveryAnchor = anchor

        let decodedCapacity = videoDecodeBufferHorizon ?? tuning.videoBufferHorizon
        let recoveryLimit = CMTimeAdd(anchor, decodedCapacity)
        guard recoveryLimit.isNumeric,
              CMTimeCompare(headPTS, recoveryLimit) > 0,
              let recoveryIndex = pendingVideoDecode.firstIndex(where: { accessUnit in
                  guard accessUnit.isRandomAccess else { return false }
                  let pts = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
                  return pts.isNumeric && CMTimeCompare(pts, anchor) >= 0
              }) else { return }
        let prefixContainsRecoverablePresentationPTS = pendingVideoDecode[
            pendingVideoDecode.startIndex..<recoveryIndex
        ].contains { accessUnit in
            let pts = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
            return pts.isNumeric && CMTimeCompare(pts, recoveryLimit) <= 0
        }
        guard !prefixContainsRecoverablePresentationPTS else { return }
        let recoveryPTS = CMSampleBufferGetPresentationTimeStamp(
            pendingVideoDecode[recoveryIndex].sampleBuffer
        )
        guard recoveryPTS.isNumeric else { return }
        let discardedCount = pendingVideoDecode.distance(
            from: pendingVideoDecode.startIndex,
            to: recoveryIndex
        )
        if discardedCount > 0 {
            pendingVideoDecode.removeFirst(discardedCount)
            metrics?.recordVideoDrop(
                count: discardedCount,
                source: .decodeSubmissionBacklog
            )
        }
        if CMTimeCompare(recoveryPTS, anchor) > 0 {
            pendingVideoRecoveryAnchor = recoveryPTS
        }
    }

    private func schedulePendingVideoDrainIsolated() {
        assertIsolated()
        guard !terminal,
              !paused,
              readiness?.isOpen == true,
              !pendingVideoDecode.isEmpty,
              outstandingVideoDecodeSubmissions.count
                  < Self.maximumOutstandingVideoDecodeSubmissions,
              !pendingVideoDrainScheduled else { return }
        pendingVideoDrainScheduled = true
        let token = pendingVideoDrainToken
        let expectedGeneration = generationController.current
        executor.submit(after: Self.pendingVideoDrainInterval) { [weak self] in
            guard let self,
                  pendingVideoDrainToken == token else { return }
            pendingVideoDrainScheduled = false
            guard !terminal,
                  !paused,
                  generationController.current == expectedGeneration else { return }
            drainPendingVideoDecodeIsolated()
        }
    }

    private func cancelPendingVideoDrainIsolated() {
        assertIsolated()
        pendingVideoDrainToken &+= 1
        pendingVideoDrainScheduled = false
        pendingVideoRecoveryAnchor = nil
        invalidateVideoDecodeStallWatchdogIsolated()
        outstandingVideoDecodeSubmissions.removeAll(keepingCapacity: true)
        failedVideoDecodeSubmissions.removeAll(keepingCapacity: true)
        reservedVideoDecodeSubmissions.removeAll(keepingCapacity: true)
        outstandingVideoIntervalsBySubmission.removeAll(keepingCapacity: true)
    }

    private func handle(decoder event: VideoDecoderEvent) {
        assertIsolated()
        guard !terminal else { return }
        let admittedEvent: VideoDecoderEvent
        switch event {
        case let .submissionFailure(accessUnitID, failure, identity):
            let key = DecoderSubmissionKey(
                accessUnitID: accessUnitID,
                identity: identity
            )
            guard outstandingVideoDecodeSubmissions.contains(key),
                  failedVideoDecodeSubmissions.insert(key).inserted else { return }
            admittedEvent = .submissionFailure(
                accessUnitID: accessUnitID,
                failure: failure,
                identity: identity
            )
        case let .submissionCompleted(accessUnitID, identity, disposition):
            let key = DecoderSubmissionKey(
                accessUnitID: accessUnitID,
                identity: identity
            )
            guard outstandingVideoDecodeSubmissions.remove(key) != nil else { return }
            reservedVideoDecodeSubmissions.remove(DecoderAdmissionReservation(
                accessUnitID: accessUnitID,
                generation: identity.generation
            ))
            outstandingVideoIntervalsBySubmission.removeValue(forKey: key)
            invalidateVideoDecodeStallWatchdogIsolated()
            let hadFailure = failedVideoDecodeSubmissions.remove(key) != nil
            admittedEvent = .submissionCompleted(
                accessUnitID: accessUnitID,
                identity: identity,
                disposition: hadFailure ? .cancelled : disposition
            )
        default:
            admittedEvent = event
        }
        videoCoordinator.handle(decoder: admittedEvent)
        drainPendingVideoDecodeIsolated()
    }

    private func handleProcessedFrames(
        _ frames: [VideoPresentationFrame],
        generation: MediaGeneration
    ) {
        assertIsolated()
        guard !terminal,
              mediaAdmissionOpen,
              generationController.accepts(generation) else { return }
        let admittedFrames: [VideoPresentationFrame]
        if let transaction = audioGapReanchorTransaction {
            switch transaction.phase {
            case .waitingForOutstandingVideo, .waitingForRandomAccess:
                admittedFrames = []
            case .videoPreroll, .preparingAnchor:
                admittedFrames = frames.filter { frame in
                    return transaction.containsSubmission(
                        accessUnitID: frame.sourceAccessUnitID,
                        generation: frame.generation
                    )
                        && frame.presentationTimeStamp.isNumeric
                        && CMTimeCompare(
                            frame.presentationTimeStamp,
                            transaction.audioFirstPTS
                        ) >= 0
                }
            }
        } else {
            admittedFrames = frames
        }
        for frame in admittedFrames where generationController.accepts(frame.generation) {
            videoDecodeBufferHorizon = effectiveVideoBufferHorizon(for: frame)
            updateMaximumAnchorLagIsolated(for: frame)
            if frame.duration.isNumeric,
               CMTimeCompare(frame.duration, .zero) > 0 {
                outputCadenceDurations.append(frame.duration)
                if outputCadenceDurations.count > 7 {
                    outputCadenceDurations.removeFirst(
                        outputCadenceDurations.count - 7
                    )
                }
            }
            if readiness?.isOpen == true || anchorPreparationTransaction != nil {
                // Frames decoded while the renderer's physical reset is in
                // flight must queue behind that barrier. Otherwise the seed
                // snapshot is accepted, readiness opens, and every frame
                // produced between those two moments is lost forever.
                renderer.enqueue(frame)
            }
            appendRetainedVideoIsolated(frame)
            let route = videoCoordinator.route
            if let videoFormat,
               let rate = PlaybackPresentationCadencePolicy.outputFrameRate(
                for: frame,
                route: presentationRoute(for: route)
               ) {
                let criteriaKey = DisplayCriteriaKey(
                    formatIdentity: ObjectIdentifier(videoFormat as AnyObject),
                    route: route,
                    outputFrameRate: rate
                )
                if criteriaKey != lastDisplayCriteriaKey {
                    lastDisplayCriteriaKey = criteriaKey
                    display.updateDisplayCriteria(
                        formatDescription: videoFormat,
                        outputFrameRate: rate
                    )
                }
            }
        }
        retainedVideo.sort {
            let comparison = CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp)
            return comparison == 0 ? $0.sequenceNumber < $1.sequenceNumber : comparison < 0
        }
        metrics?.recordProcessedVideo(latestPTS: retainedVideo.last?.presentationTimeStamp)
        boundRetainedVideoIsolated()
        publishMediaInformationIfReadyIsolated()
        updateReadinessIsolated()
    }

    private func consumeCanonicalFingerprintIsolated(
        latestEventFingerprint fingerprint: MediaFormatFingerprint
    ) throws {
        assertIsolated()
        if let configuration = audioConfiguration,
           configuration.fingerprint != fingerprint {
            audioConfiguration = CompressedAudioRenderConfiguration(
                formatDescription: configuration.formatDescription,
                codec: configuration.codec,
                decoderExtradata: configuration.decoderExtradata,
                fingerprint: fingerprint
            )
        }
        let hasVideo = tracks?.video != nil
        if awaitingFreshTrackEpoch {
            guard freshAudioFormatArrived,
                  audioConfiguration != nil else { return }
            if hasVideo {
                guard freshVideoFormatArrived, videoFormat != nil else { return }
            }
            consumedFingerprint = fingerprint
            if trackEpochAlreadyAdvanced {
                try configureCurrentGenerationIsolated(mode: .freshTrackEpoch)
            } else {
                try rebuildForCurrentFormatsIsolated(mode: .freshTrackEpoch)
            }
            return
        }
        guard consumedFingerprint != fingerprint else { return }
        consumedFingerprint = fingerprint
        try rebuildForCurrentFormatsIsolated(mode: .currentEpoch)
    }

    private func beginTrackEpochIsolated() {
        assertIsolated()
        cancelPendingVideoFormatCommitIsolated()
        awaitingFreshTrackEpoch = true
        freshVideoFormatArrived = false
        freshAudioFormatArrived = false
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
        videoFormat = nil
        audioConfiguration = nil
        audioResourcesConfigured = false
        trackEpochAlreadyAdvanced = false
        setSharedTimelineOpenedIsolated(false)
        clearMediaInformationIsolated(publish: true)
        outputCadenceDurations.removeAll(keepingCapacity: true)
        cancelPendingVideoDrainIsolated()
        pendingTrackVideo.removeAll(keepingCapacity: true)
        clearPendingTrackAudioIsolated(keepingCapacity: true)
        pendingVideoDecode.removeAll(keepingCapacity: true)
        videoDecodeBufferHorizon = nil
        readyPublished = false
        readiness?.closeForTimelineReset(.discontinuity)
        display.pauseSubmission()
    }

    private func configureCurrentGenerationIsolated(
        mode: VideoFormatCommitMode
    ) throws {
        assertIsolated()
        guard let audioConfiguration else { return }
        let generation = generationController.current
        if let videoFormat {
            armVideoFormatCommitIsolated(mode: mode, generation: generation)
            videoCoordinator.installFormatForCurrentGeneration(videoFormat)
            if let activeDecoderInvalidationTicket,
               activeDecoderInvalidationTicket.generation == generation {
                bindPendingVideoFormatCommitIsolated(to: activeDecoderInvalidationTicket)
            }
            if !videoCoordinator.isDecoderTransitionPending {
                try completePendingVideoFormatCommitIsolated()
            }
            return
        }
        try commitAudioConfigurationIsolated(
            audioConfiguration,
            generation: generation,
            mode: mode
        )
    }

    private func commitAudioConfigurationIsolated(
        _ audioConfiguration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration,
        mode: VideoFormatCommitMode
    ) throws {
        assertIsolated()
        setSharedTimelineOpenedIsolated(false)
        audioContinuity.reset(to: generation)
        try audio.configure(audioConfiguration, generation: generation)
        audioResourcesConfigured = true
        pendingAudioSessionReset = false
        mediaAdmissionOpen = true
        videoAdmissionOpen = videoFormat != nil
            && !paused
            && !videoCoordinator.isDecoderTransitionPending
        if mode == .freshTrackEpoch {
            awaitingFreshTrackEpoch = false
            trackEpochAlreadyAdvanced = false
        }
        try replayPendingTrackMediaIsolated()
    }

    private func forceAdvanceGenerationIsolated() throws {
        assertIsolated()
        if tracks?.video != nil {
            videoCoordinator.beginDiscontinuity()
        } else {
            let generation = advanceGenerationAndRebindAssemblyIsolated()
            resetCoordinatorPlaybackIsolated(
                to: generation,
                requiredVideoFrameCount: 0,
                resetScope: .timeline
            )
        }
        guard !terminal else { return }
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
    }

    private func rebuildForCurrentFormatsIsolated(
        mode: VideoFormatCommitMode
    ) throws {
        assertIsolated()
        guard let audioConfiguration else { return }
        clearMediaInformationIsolated(publish: true)
        outputCadenceDurations.removeAll(keepingCapacity: true)
        if let videoFormat {
            armVideoFormatCommitIsolated(mode: mode, generation: nil)
            videoCoordinator.replaceFormat(videoFormat)
            if var pending = pendingVideoFormatCommit,
               pending.generation == nil {
                pending.generation = generationController.current
                pendingVideoFormatCommit = pending
            }
            return
        } else {
            _ = advanceGenerationAndRebindAssemblyIsolated()
            readiness?.closeForTimelineReset(.discontinuity)
            setSharedTimelineOpenedIsolated(false)
            mediaInformation = nil
            mediaInformationGeneration = nil
            outputCadenceDurations.removeAll(keepingCapacity: true)
            audioContinuity.reset(to: generationController.current)
            clearRetainedVideoIsolated(keepingCapacity: true)
            readyPublished = false
        }
        let generation = generationController.current
        try commitAudioConfigurationIsolated(
            audioConfiguration,
            generation: generation,
            mode: mode
        )
    }

    private func armVideoFormatCommitIsolated(
        mode: VideoFormatCommitMode,
        generation: MediaGeneration?
    ) {
        assertIsolated()
        if pendingVideoFormatCommit != nil {
            pendingTrackVideo.removeAll(keepingCapacity: true)
            clearPendingTrackAudioIsolated(keepingCapacity: true)
        }
        videoFormatCommitRevision &+= 1
        var pending = PendingVideoFormatCommit(
            revision: videoFormatCommitRevision,
            mode: mode,
            generation: generation,
            invalidationTicket: nil
        )
        if let activeDecoderInvalidationTicket,
           generation == activeDecoderInvalidationTicket.generation {
            pending.invalidationTicket = activeDecoderInvalidationTicket
        }
        pendingVideoFormatCommit = pending
        audioResourcesConfigured = false
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
    }

    private func bindPendingVideoFormatCommitIsolated(
        to ticket: VideoDecoderInvalidationTicket
    ) {
        assertIsolated()
        guard var pending = pendingVideoFormatCommit,
              pending.revision == videoFormatCommitRevision,
              pending.generation == nil || pending.generation == ticket.generation else { return }
        pending.generation = ticket.generation
        pending.invalidationTicket = ticket
        pendingVideoFormatCommit = pending
    }

    private func decoderInvalidationBeganIsolated(
        _ ticket: VideoDecoderInvalidationTicket
    ) {
        assertIsolated()
        activeDecoderInvalidationTicket = ticket
        bindPendingVideoFormatCommitIsolated(to: ticket)
    }

    private func decoderInvalidationFinishedIsolated(
        _ ticket: VideoDecoderInvalidationTicket,
        outcome: VideoDecoderInvalidationResolution
    ) {
        assertIsolated()
        if activeDecoderInvalidationTicket == ticket {
            activeDecoderInvalidationTicket = nil
        }
        guard outcome == .commit,
              let pending = pendingVideoFormatCommit,
              pending.revision == videoFormatCommitRevision,
              pending.generation == ticket.generation,
              pending.invalidationTicket == ticket else { return }
        do {
            try completePendingVideoFormatCommitIsolated()
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.audioRendererFailed("audio.pipeline"))
        }
    }

    private func completePendingVideoFormatCommitIsolated() throws {
        assertIsolated()
        guard let pending = pendingVideoFormatCommit,
              pending.revision == videoFormatCommitRevision,
              let generation = pending.generation,
              generationController.accepts(generation),
              !terminal,
              let audioConfiguration else { return }
        pendingVideoFormatCommit = nil
        try commitAudioConfigurationIsolated(
            audioConfiguration,
            generation: generation,
            mode: pending.mode
        )
    }

    private func cancelPendingVideoFormatCommitIsolated() {
        assertIsolated()
        videoFormatCommitRevision &+= 1
        pendingVideoFormatCommit = nil
        activeDecoderInvalidationTicket = nil
    }

    private func closeCoordinatorAdmissionIsolated() {
        assertIsolated()
        invalidateVideoDecodeStallWatchdogIsolated()
        videoAdmissionOpen = false
    }

    private func advanceCoordinatorGenerationIsolated() -> MediaGeneration {
        assertIsolated()
        return advanceGenerationAndRebindAssemblyIsolated()
    }

    private func advanceGenerationAndRebindAssemblyIsolated() -> MediaGeneration {
        assertIsolated()
        let generation = generationController.forceAdvance()
        _ = assembly?.binding.rebind()
        return generation
    }

    private func resetCoordinatorPlaybackIsolated(
        to generation: MediaGeneration,
        requiredVideoFrameCount: Int,
        resetScope: VideoPipelineCoordinatorHooks.PlaybackResetScope
    ) {
        assertIsolated()
        if var pending = pendingVideoFormatCommit,
           pending.generation == nil {
            pending.generation = generation
            pendingVideoFormatCommit = pending
        }
        clock.pause()
        clearMediaInformationIsolated(publish: true)
        outputCadenceDurations.removeAll(keepingCapacity: true)
        switch resetScope {
        case .timeline:
            readiness?.closeForTimelineReset(.discontinuity)
            setSharedTimelineOpenedIsolated(false)
        case .decoderSession:
            // A decoder rebuild changes ownership/lifetime generations, not
            // media time. Keep the paused-clock floor so buffered access units
            // from before the stall cannot anchor the shared clock backwards.
            readiness?.close(.buffering)
            beginControlledRecoveryPhaseWindowIsolated()
        }
        readiness?.configure(requiredVideoFrameCount: requiredVideoFrameCount)
        readyPublished = false
        cancelPendingVideoDrainIsolated()
        releasePendingAdmissionIsolated()
        preparedAnchor = nil
        anchorPreparationTransaction = nil
        supersededAnchorPreparationTransaction = nil
        audioGapReanchorTransaction = nil
        pendingAnchorTimingRecoveryRevision = nil
        lastHandledAnchorTimingRevision = nil
        audioContinuity.reset(to: generation)
        clearRetainedVideoIsolated(keepingCapacity: true)
        deferredPackets.removeAll(keepingCapacity: true)
        pendingVideoDecode.removeAll(keepingCapacity: true)
        videoDecodeBufferHorizon = nil
        renderer.flush(to: generation)
        audio.flush(to: generation)
        display.pauseSubmission()
    }

    private func reopenCoordinatorAdmissionIsolated() {
        assertIsolated()
        videoAdmissionOpen = !terminal
            && mediaAdmissionOpen
            && !awaitingFreshTrackEpoch
            && !paused
            && videoFormat != nil
            && !videoCoordinator.isDecoderTransitionPending
        if videoAdmissionOpen {
            drainPendingVideoDecodeIsolated()
        }
    }

    private func coordinatorRouteDidChangeIsolated(requiredVideoFrameCount: Int) {
        assertIsolated()
        readiness?.close(.buffering)
        readiness?.configure(requiredVideoFrameCount: requiredVideoFrameCount)
        readyPublished = false
        clearMediaInformationIsolated(publish: true)
        outputCadenceDurations.removeAll(keepingCapacity: true)
        preparedAnchor = nil
        clearRetainedVideoIsolated(keepingCapacity: true)
        renderer.flush(to: generationController.current)
        display.pauseSubmission()
    }

    private func setPausedIsolated(_ shouldPause: Bool, readinessCycle: UInt64) {
        assertIsolated()
        guard started, !terminal, paused != shouldPause else { return }
        self.readinessCycle = readinessCycle
        paused = shouldPause
        if shouldPause {
            invalidateVideoDecodeStallWatchdogIsolated()
            clock.pause()
            readiness?.close(.pause)
            readyPublished = false
            display.pauseSubmission()
            return
        }

        let pausedAudioTime = clock.currentTime
        removeRetainedVideoIsolated {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, pausedAudioTime) <= 0
        }
        readiness?.close(.buffering)
        publishActivePhaseWindowIsolated()

        let queued = deferredPackets
        deferredPackets.removeAll(keepingCapacity: true)
        for packet in queued where !terminal {
            do {
                try routePacketIsolated(packet)
            } catch let error as PlaybackCoreError {
                failIsolated(error)
            } catch {
                failIsolated(.demuxRead(-1))
            }
        }
        if let pendingPacketAdmission {
            self.pendingPacketAdmission = nil
            if !terminal {
                do {
                    try routePacketIsolated(pendingPacketAdmission.packet)
                } catch let error as PlaybackCoreError {
                    failIsolated(error)
                } catch {
                    failIsolated(.demuxRead(-1))
                }
            }
            pendingPacketAdmission.acknowledgement.signal()
        }
        reopenCoordinatorAdmissionIsolated()
        scheduleVideoDecodeStallWatchdogIfNeededIsolated()
        updateReadinessIsolated()
    }

    private func activeAudioIntervalIsolated() -> (first: CMTime, duration: CMTime)? {
        assertIsolated()
        guard let interval = audioContinuity.activeRetainedInterval else { return nil }
        let duration = CMTimeSubtract(interval.endPTS, interval.firstPTS)
        guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else { return nil }
        return (interval.firstPTS, duration)
    }

    @discardableResult
    private func synchronizeAudioRecoveryFloorIsolated(_ floor: CMTime?) -> Bool {
        assertIsolated()
        do {
            try audioContinuity.updateRecoveryFloor(floor)
            audio.updateRecoveryFloor(floor)
            return true
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.audioRendererFailed(
                CompressedAudioRetentionPolicy.accountingError
            ))
        }
        return false
    }

    private func updateReadinessIsolated() {
        assertIsolated()
        guard !terminal, mediaAdmissionOpen, !paused, let readiness else { return }
        readiness.setAnchorLeadTime(audio.anchorLeadTime)
        guard audio.isOutputRouteReadyForSharedAnchor else {
            updateReadinessDiagnosticsIsolated(readiness)
            return
        }
        if tracks?.video == nil {
            updateAudioOnlyReadinessIsolated()
            updateReadinessDiagnosticsIsolated(readiness)
            return
        }
        guard videoCoordinator.isClassificationResolved,
              mediaInformation != nil,
              mediaInformationGeneration == generationController.current else {
            // Classification and media metadata are admission prerequisites for
            // video readiness, but diagnostics still need to expose the
            // retained startup window while that gate is closed.
            updateReadinessDiagnosticsIsolated(readiness)
            return
        }
        resyncIfVideoTrailsClockIsolated()
        guard synchronizeAudioRecoveryFloorIsolated(
            readiness.minimumRecoveryAnchorPTS
        ) else { return }
        pruneRetainedVideoBeforeRecoveryFloorIsolated()
        let expectedGeneration = generationController.current
        let audioInterval = activeAudioIntervalIsolated()
        if audio.isReadyForPlayback, let audioInterval {
            readiness.updateAudio(
                firstPTS: audioInterval.first,
                contiguousDuration: audioInterval.duration,
                isContiguous: true
            )
        } else {
            readiness.updateAudio(firstPTS: .invalid, contiguousDuration: .zero, isContiguous: false)
        }
        readiness.updateVideo(frames: retainedVideo.map {
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: $0.presentationTimeStamp,
                duration: $0.duration
            )
        })
        guard synchronizeAudioRecoveryFloorIsolated(
            readiness.minimumRecoveryAnchorPTS
        ) else { return }
        // Resuming display submission has to follow the gate's *state*, not an
        // open edge observed inside this call. `updateAudio` can close the gate
        // and `updateVideo` reopen it before we reach here: the cycle then no
        // longer matches the one captured on entry, which skipped the resume,
        // and on the next call the gate was already open so the edge never came
        // back. Display submission then stayed paused for the rest of playback
        // while the presentation queue overflowed. Keying on the cycle resumes
        // exactly once per open period, whichever update opened it.
        if readiness.isOpen,
           generationController.current == expectedGeneration,
           !terminal,
           !paused,
           !readyPublished || displayResumedCycle != readiness.cycleID {
            displayResumedCycle = readiness.cycleID
            resumeDisplayForOpenReadinessGateIsolated()
        }
        updateReadinessDiagnosticsIsolated(readiness, audioInterval: audioInterval)
    }

    private func updateReadinessDiagnosticsIsolated(
        _ readiness: PlaybackReadinessGate,
        audioInterval: (first: CMTime, duration: CMTime)? = nil
    ) {
        assertIsolated()
        let audioInterval = audioInterval ?? activeAudioIntervalIsolated()
        metrics?.updateReadinessDiagnostics(
            audioRoute: audio.route,
            audioReady: audio.isReadyForPlayback,
            readinessOpen: readiness.isOpen,
            retainedAudioCount: audioContinuity.retainedFrameCount,
            retainedVideoCount: retainedVideo.count,
            audioFirstPTS: audioInterval?.first,
            audioDuration: audioInterval?.duration,
            videoFirstPTS: retainedVideo.first?.presentationTimeStamp,
            readinessCycleID: readiness.cycleID,
            readinessCloseReasonCounts: readiness.closeReasonCounts,
            clockTime: clock.currentTime,
            audioRecoveryCount: audio.recoveryCount,
            audioDiagnostics: audio.diagnostics,
            audioContinuityDropCountsByReason: audioContinuityDropCountsByReason,
            audioShortGapCount: audioShortGapCount,
            audioLargeGapCount: audioLargeGapCount,
            audioContinuityIslandSwitchCount: audioContinuityIslandSwitchCount
        )
    }

    private func recordAudioContinuityDrop(_ reason: AudioContinuityDropReason) {
        assertIsolated()
        let index = reason.slot
        guard audioContinuityDropCountsByReason.indices.contains(index) else { return }
        PlaybackDiagnosticSaturatingCounter.increment(
            &audioContinuityDropCountsByReason[index]
        )
        publishAudioContinuityDiagnostics()
    }

    private func publishAudioContinuityDiagnostics() {
        assertIsolated()
        metrics?.updateAudioContinuityDiagnostics(
            retainedAudioCount: audioContinuity.retainedFrameCount,
            dropCountsByReason: audioContinuityDropCountsByReason,
            shortGapCount: audioShortGapCount,
            largeGapCount: audioLargeGapCount,
            islandSwitchCount: audioContinuityIslandSwitchCount
        )
    }

    // A decoder that recovers at only source rate cannot catch a clock that is
    // still advancing. Pause after a genuine stall, but let the gate's recovery
    // floor reject every old anchor and retained frame before that paused time.
    private func resyncIfVideoTrailsClockIsolated() {
        assertIsolated()
        guard let readiness, readiness.isOpen, !paused, !terminal,
              let newest = retainedVideo.last else { return }
        let newestEnd = CMTimeAdd(newest.presentationTimeStamp, newest.duration)
        let now = clock.currentTime
        guard newestEnd.isNumeric, now.isNumeric else { return }
        let behind = CMTimeSubtract(now, newestEnd)
        guard behind.isNumeric,
              CMTimeCompare(behind, Self.videoResyncThreshold) > 0 else { return }
        readiness.close(.buffering)
        readyPublished = false
        display.pauseSubmission()
        beginControlledRecoveryPhaseWindowIsolated()
        metrics?.recordVideoResync()
    }

    private func updateMaximumAnchorLagIsolated(for frame: VideoPresentationFrame?) {
        let horizon = effectiveVideoBufferHorizon(for: frame)
        let lag = CMTimeMultiplyByRatio(horizon, multiplier: 1, divisor: 2)
        readiness?.setMaximumAnchorLag(lag)
    }

    private func effectiveVideoBufferHorizon(
        for frame: VideoPresentationFrame?
    ) -> CMTime {
        guard let memoryHorizon = frame?.memoryLimitedPresentationHorizon,
              memoryHorizon.isNumeric,
              CMTimeCompare(memoryHorizon, .zero) > 0,
              CMTimeCompare(memoryHorizon, tuning.videoBufferHorizon) < 0 else {
            return tuning.videoBufferHorizon
        }
        return memoryHorizon
    }

    private func displayModeSwitchStartedIsolated() {
        assertIsolated()
        guard !terminal, !paused else { return }
        preparedAnchor = nil
        readyPublished = false
        pendingDisplayTimingReset = true
        clock.pause()
        readiness?.close(.displayModeSwitch)
        display.pauseSubmission()
        if modeSwitchSignpost == nil {
            modeSwitchSignpost = signposts?.begin(
                .modeSwitch,
                correlation: generationController.current.rawValue
            )
        }
    }

    private func displayModeSwitchEndedIsolated() {
        assertIsolated()
        finishModeSwitchSignpostIsolated()
        guard !terminal, !paused, let readiness else { return }
        _ = readiness.reopenAfterDisplayModeSwitch()
        if readiness.isOpen,
           tracks?.video == nil
                || (videoCoordinator.isClassificationResolved
                    && mediaInformation != nil
                    && mediaInformationGeneration == generationController.current) {
            displayResumedCycle = readiness.cycleID
            resumeDisplayForOpenReadinessGateIsolated()
        } else {
            updateReadinessIsolated()
        }
    }

    private func resumeDisplayForOpenReadinessGateIsolated() {
        assertIsolated()
        guard tracks?.video == nil
                || (videoCoordinator.isClassificationResolved
                    && mediaInformation != nil
                    && mediaInformationGeneration == generationController.current) else { return }
        setSharedTimelineOpenedIsolated(true)
        pendingVideoRecoveryAnchor = nil
        drainPendingVideoDecodeIsolated()
        if pendingDisplayTimingReset {
            pendingDisplayTimingReset = false
            renderer.resetPresentationTiming()
            display.resetPresentationTiming()
        }
        display.resumeSubmission()
        metrics?.recordDisplaySubmissionResume()
        if !readyPublished {
            publishReadyIsolated()
        }
    }

    private func beginInitialBufferingPhaseWindowIsolated() {
        assertIsolated()
        guard activePhaseWindow == nil else { return }
        activePhaseWindow = .buffering
        publishActivePhaseWindowIsolated()
    }

    private func beginControlledRecoveryPhaseWindowIsolated() {
        assertIsolated()
        if activePhaseWindow == nil {
            activePhaseWindow = hasPublishedReadyInRun ? .recovering : .buffering
        }
        publishActivePhaseWindowIsolated()
    }

    private func publishActivePhaseWindowIsolated() {
        assertIsolated()
        guard started,
              !paused,
              !terminal,
              let phase = activePhaseWindow else { return }
        guard publishedPhase != phase
                || publishedPhaseReadinessCycle != readinessCycle else { return }
        publishedPhase = phase
        publishedPhaseReadinessCycle = readinessCycle
        eventSink(.phase(phase, readinessCycle: readinessCycle))
    }

    private func publishReadyIsolated() {
        assertIsolated()
        readyPublished = true
        hasPublishedReadyInRun = true
        endPublishedPhaseWindowIsolated()
        eventSink(.ready(readinessCycle: readinessCycle))
    }

    private func endPublishedPhaseWindowIsolated() {
        assertIsolated()
        publishedPhase = nil
        publishedPhaseReadinessCycle = nil
        activePhaseWindow = nil
    }

    private func presentationRoute(for route: DeinterlaceRoute) -> PlaybackPresentationRoute {
        switch route {
        case .bypass, .rawWhileClassifying:
            .progressive
        case .metalYADIF2x:
            .metalYADIF2x
        }
    }

    private func updateAudioOnlyReadinessIsolated() {
        assertIsolated()
        guard let readiness,
              audio.isReadyForPlayback,
              let audioInterval = activeAudioIntervalIsolated() else { return }
        readiness.updateAudio(
            firstPTS: audioInterval.first,
            contiguousDuration: audioInterval.duration,
            isContiguous: true
        )
        guard readiness.openAudioOnly(firstPTS: audioInterval.first) else { return }
        guard synchronizeAudioRecoveryFloorIsolated(
            readiness.minimumRecoveryAnchorPTS
        ) else { return }
        setSharedTimelineOpenedIsolated(true)
        guard !readyPublished, !paused, !terminal else { return }
        publishReadyIsolated()
    }

    private func clearMediaInformationIsolated(publish: Bool) {
        assertIsolated()
        let hadInformation = mediaInformation != nil
        mediaInformation = nil
        mediaInformationGeneration = nil
        guard publish, hadInformation else { return }
        eventSink(.mediaInformation(nil, generation: generationController.current))
    }

    private func publishMediaInformationIfReadyIsolated() {
        assertIsolated()
        guard !terminal,
              tracks?.video != nil,
              videoFormat != nil,
              videoCoordinator.isClassificationResolved else { return }
        let generation = generationController.current
        let information = makeMediaInformationIsolated()
        mediaInformation = information
        mediaInformationGeneration = generation
        eventSink(.mediaInformation(information, generation: generation))
    }

    private func makeMediaInformationIsolated() -> PlaybackMediaInformation {
        let dimensions = videoFormat.map(CMVideoFormatDescriptionGetDimensions)
            ?? CMVideoDimensions(
                width: tracks?.video?.width ?? 0,
                height: tracks?.video?.height ?? 0
            )
        let source = validatedFrameRate(tracks?.video?.frameRate)
        let route = videoCoordinator.route
        let output: Double?
        switch route {
        case .bypass:
            output = sourceRate(source)
        case .metalYADIF2x:
            let expected = sourceRate(source).map { $0 * 2 }
            let measured = measuredOutputFrameRateIsolated()
            if let expected, expected.isFinite, expected > 0, expected <= 120 {
                let tolerance = max(0.5, expected * 0.02)
                output = measured.map { abs($0 - expected) <= tolerance ? $0 : expected }
                    ?? expected
            } else {
                output = measured
            }
        case .rawWhileClassifying:
            output = nil
        }
        return PlaybackMediaInformation(
            width: dimensions.width,
            height: dimensions.height,
            scanMode: route == .metalYADIF2x ? .interlaced : .progressive,
            sourceFrameRate: source,
            outputFrameRate: output,
            isSmoothMotionEnhanced: route == .metalYADIF2x
        )
    }

    private func validatedFrameRate(_ rate: MediaRational?) -> MediaRational? {
        guard let rate else { return nil }
        let value = Double(rate.num) / Double(rate.den)
        guard value.isFinite, value > 0, value <= 120 else { return nil }
        return rate
    }

    private func sourceRate(_ rate: MediaRational?) -> Double? {
        rate.map { Double($0.num) / Double($0.den) }
    }

    private func measuredOutputFrameRateIsolated() -> Double? {
        let durations = outputCadenceDurations.compactMap { duration -> Double? in
            guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else {
                return nil
            }
            let seconds = Double(duration.value) / Double(duration.timescale)
            guard seconds.isFinite, seconds > 0 else { return nil }
            let rate = 1 / seconds
            guard rate.isFinite, rate > 0, rate <= 120 else { return nil }
            return rate
        }.sorted()
        guard !durations.isEmpty else { return nil }
        return durations[durations.count / 2]
    }

    private func boundRetainedVideoIsolated() {
        assertIsolated()
        pruneRetainedVideoBeforeRecoveryFloorIsolated()
        let retentionAudioInterval = activeAudioIntervalIsolated()
        if let audioFirstPTS = retentionAudioInterval?.first {
            // If an HLS audio burst somehow moves wholly beyond decoded video,
            // deleting every video frame destroys the only recovery watermark
            // and makes the two windows chase each other forever. Preserve the
            // evidence until audio retention is pulled back to the clock/video
            // floor; normal overlapping windows still discard expired frames.
            let videoNewestEnd = retainedVideo.last.map {
                CMTimeAdd($0.presentationTimeStamp, $0.duration)
            }
            if hasOpenedReadinessForCurrentMedia,
               videoNewestEnd?.isNumeric == true,
               CMTimeCompare(audioFirstPTS, videoNewestEnd ?? .invalid) > 0 {
                // Preserve the recovery watermark while an already-running
                // stream absorbs a segment burst.
            } else {
                let before = retainedVideo.count
                removeRetainedVideoIsolated { frame in
                    let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
                    return end.isNumeric && CMTimeCompare(end, audioFirstPTS) <= 0
                }
                metrics?.recordAudioRelativeVideoPrune(count: before - retainedVideo.count)
            }
        }

        // The two playback phases need opposite overflow victims, so the bound
        // cannot be unified. While readiness is closed the anchor is still being
        // built at the selected audio island's leading edge, so the earliest
        // frames that have not expired against that island are the ones that
        // must survive until lagging audio reaches them. Once readiness is
        // open the retained window only exists to reseed the renderer on a
        // re-anchor, so keeping the earliest frames there replays seconds-old
        // video and drags the clock backwards. Drop the oldest instead.
        if !paused, readiness?.isOpen != true {
            guard retainedVideo.count > Self.startupRetainedVideoCapacity else { return }
            trimRetainedVideoToPrefixIsolated(Self.startupRetainedVideoCapacity)
            return
        }

        var estimatedBytes = retainedVideo.reduce(into: 0) { total, frame in
            let addition = total.addingReportingOverflow(frame.estimatedStorageBytes)
            total = addition.overflow ? Int.max : addition.partialValue
        }
        while retainedVideo.count > 1 {
            let span = CMTimeSubtract(
                retainedVideo[retainedVideo.count - 1].presentationTimeStamp,
                retainedVideo[0].presentationTimeStamp
            )
            // The retained window only exists to reseed the renderer on a
            // re-anchor, so it is bounded by the same duration as the
            // presentation queue rather than by a frame count that would shrink
            // whenever the output frame rate doubles.
            let overHorizon = span.isNumeric
                && CMTimeCompare(span, tuning.videoBufferHorizon) > 0
            let overMemoryBudget = estimatedBytes
                > PlaybackVideoMemoryBudget.retainedAnchorBytes
            guard overHorizon
                    || overMemoryBudget
                    || retainedVideo.count > tuning.videoBufferFrameCeiling else {
                return
            }
            let removed = retainedVideo.removeFirst()
            videoSurfaceLedger?.release(removed)
            estimatedBytes = max(0, estimatedBytes - removed.estimatedStorageBytes)
        }
    }

    private func appendRetainedVideoIsolated(_ frame: VideoPresentationFrame) {
        guard videoSurfaceLedger?.retain(frame) ?? true else { return }
        retainedVideo.append(frame)
    }

    private func clearRetainedVideoIsolated(keepingCapacity: Bool) {
        for frame in retainedVideo { videoSurfaceLedger?.release(frame) }
        retainedVideo.removeAll(keepingCapacity: keepingCapacity)
    }

    private func removeRetainedVideoIsolated(
        where shouldRemove: (VideoPresentationFrame) -> Bool
    ) {
        var kept: [VideoPresentationFrame] = []
        kept.reserveCapacity(retainedVideo.count)
        for frame in retainedVideo {
            if shouldRemove(frame) {
                videoSurfaceLedger?.release(frame)
            } else {
                kept.append(frame)
            }
        }
        retainedVideo = kept
    }

    private func trimRetainedVideoToPrefixIsolated(_ count: Int) {
        let retainedCount = max(0, min(count, retainedVideo.count))
        guard retainedCount < retainedVideo.count else { return }
        for frame in retainedVideo[retainedCount...] {
            videoSurfaceLedger?.release(frame)
        }
        retainedVideo.removeLast(retainedVideo.count - retainedCount)
    }

    private func pruneRetainedVideoBeforeRecoveryFloorIsolated() {
        assertIsolated()
        guard let floor = readiness?.minimumRecoveryAnchorPTS,
              floor.isNumeric else { return }
        removeRetainedVideoIsolated { frame in
            frame.presentationTimeStamp.isNumeric
                && CMTimeCompare(frame.presentationTimeStamp, floor) < 0
        }
    }

    private func prepareAnchorIsolated(commonPTS: CMTime) -> Bool {
        assertIsolated()
        let expectedGeneration = generationController.current
        guard !terminal,
              !paused,
              anchorPreparationTransaction == nil,
              supersededAnchorPreparationTransaction == nil,
              audio.isOutputRouteReadyForSharedAnchor,
              let readiness else { return false }
        if let floor = readiness.minimumRecoveryAnchorPTS,
           CMTimeCompare(commonPTS, floor) < 0 {
            return false
        }
        let expectedCycle = readiness.cycleID
        let expectedRouteRevision = audio.currentRouteSnapshot?.revision
        let requiresVideo = tracks?.video != nil
        guard synchronizeAudioRecoveryFloorIsolated(
            readiness.minimumRecoveryAnchorPTS
        ) else { return false }
        guard let audioCandidate = audioContinuity.anchorCandidate(at: commonPTS) else {
            return false
        }
        let candidateVideo = retainedVideo.filter {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return !end.isNumeric || CMTimeCompare(end, commonPTS) > 0
        }
        guard hasSufficientMediaForAnchor(
            commonPTS: commonPTS,
            audioIsland: audioCandidate,
            videoFrames: candidateVideo,
            requireVideo: requiresVideo
        ) else { return false }

        if var gapTransaction = audioGapReanchorTransaction {
            guard gapTransaction.generation == expectedGeneration,
                  gapTransaction.islandID == audioCandidate.id,
                  gapTransaction.phase == .videoPreroll
                    || (!requiresVideo && gapTransaction.phase == .preparingAnchor) else {
                return false
            }
            gapTransaction.phase = .preparingAnchor
            audioGapReanchorTransaction = gapTransaction
        }

        let alreadyPrepared = preparedAnchor.map {
            $0.cycleID == expectedCycle
                && $0.routeRevision == expectedRouteRevision
                && CMTimeCompare($0.commonPTS, commonPTS) == 0
        } ?? false
        if !alreadyPrepared {
            let reanchorSignpost = signposts?.begin(
                .reanchor,
                correlation: generationController.current.rawValue
            )
            defer {
                if let reanchorSignpost { signposts?.end(reanchorSignpost) }
            }
            let preparation = AnchorPreparationTransaction(
                cycleID: expectedCycle,
                generation: expectedGeneration,
                islandID: audioCandidate.id,
                commonPTS: commonPTS,
                routeRevision: expectedRouteRevision
            )
            anchorPreparationTransaction = preparation
            do {
                try audio.prepareAnchor(at: commonPTS, in: audioCandidate.id)
            } catch let error as PlaybackCoreError {
                anchorPreparationTransaction = nil
                failIsolated(error)
                return false
            } catch {
                anchorPreparationTransaction = nil
                failIsolated(.audioRendererFailed("audio.anchor"))
                return false
            }
            guard outputRouteRevisionMatchesIsolated(preparation.routeRevision) else {
                anchorPreparationTransaction = nil
                updateReadinessIsolated()
                return false
            }
            let resetReason: VideoRendererResetRequest.Reason =
                audioGapReanchorTransaction == nil ? .timelineDiscontinuity : .audioGap
            renderer.reset(VideoRendererResetRequest(
                generation: expectedGeneration,
                reason: resetReason,
                removeDisplayedImage: true,
                seedFrames: candidateVideo
            )) { [weak self] result in
                guard let self else { return }
                executor.submit { [self] in
                    completeAnchorPreparationIsolated(
                        preparation,
                        audioCandidate: audioCandidate,
                        candidateVideo: candidateVideo,
                        result: result
                    )
                }
            }
            // Readiness must stay closed until the physical renderer flush has
            // completed and every seed sample has crossed the backend boundary.
            return false
        }
        guard !terminal,
              !paused,
              generationController.current == expectedGeneration,
              readiness.cycleID == expectedCycle,
              outputRouteRevisionMatchesIsolated(expectedRouteRevision),
              hasSufficientMediaForAnchor(
                  commonPTS: commonPTS,
                  audioIsland: audioCandidate,
                  requireVideo: requiresVideo
              ) else { return false }
        return true
    }

    private func completeAnchorPreparationIsolated(
        _ preparation: AnchorPreparationTransaction,
        audioCandidate: AudioContinuityAnchorCandidate,
        candidateVideo: [VideoPresentationFrame],
        result: Result<VideoEnqueueReceipt, PlaybackCoreError>
    ) {
        assertIsolated()
        let isInstalledTransaction = anchorPreparationTransaction.map { transaction in
            transaction.cycleID == preparation.cycleID
                && transaction.generation == preparation.generation
                && transaction.islandID == preparation.islandID
                && transaction.routeRevision == preparation.routeRevision
                && CMTimeCompare(transaction.commonPTS, preparation.commonPTS) == 0
        } == true
        guard isInstalledTransaction else {
            let isSupersededTransaction = supersededAnchorPreparationTransaction.map {
                transaction in
                transaction.cycleID == preparation.cycleID
                    && transaction.generation == preparation.generation
                    && transaction.islandID == preparation.islandID
                    && transaction.routeRevision == preparation.routeRevision
                    && CMTimeCompare(transaction.commonPTS, preparation.commonPTS) == 0
            } == true
            if isSupersededTransaction {
                supersededAnchorPreparationTransaction = nil
                updateReadinessIsolated()
            }
            return
        }
        guard !terminal,
              !paused,
              generationController.current == preparation.generation,
              readiness?.cycleID == preparation.cycleID,
              outputRouteRevisionMatchesIsolated(preparation.routeRevision) else {
            // Pause and display-mode changes can invalidate the readiness cycle
            // while AVFoundation is still completing its asynchronous flush.
            // Retaining this transaction would veto every future re-anchor.
            anchorPreparationTransaction = nil
            updateReadinessIsolated()
            return
        }
        switch result {
        case let .failure(error):
            anchorPreparationTransaction = nil
            failIsolated(error)
            return
        case let .success(receipt):
            let expectedSequences = Set(candidateVideo.map(\.sequenceNumber))
            guard receipt.generation == preparation.generation,
                  receipt.sequenceNumbers == expectedSequences,
                  audioContinuity.anchorCandidate(at: preparation.commonPTS)?.id
                    == audioCandidate.id else {
                anchorPreparationTransaction = nil
                updateReadinessIsolated()
                return
            }
        }
        // A successful physical reset completes the destructive preparation,
        // even when its freshly replayed audio queue is still prerolling. Commit
        // it once and remember the prepared cycle; the later audio-available
        // callback can then open the gate without flushing both renderers again.
        // Keep frames that arrived while the physical reset was in flight. The
        // reset seeds already cover `candidateVideo`; later frames were queued
        // behind the same output barrier and must remain available for recovery.
        removeRetainedVideoIsolated { frame in
            let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return end.isNumeric && CMTimeCompare(end, preparation.commonPTS) <= 0
        }
        do {
            try audioContinuity.commitAnchor(
                at: preparation.commonPTS,
                in: audioCandidate.id
            )
        } catch let error as PlaybackCoreError {
            anchorPreparationTransaction = nil
            failIsolated(error)
            return
        } catch {
            anchorPreparationTransaction = nil
            failIsolated(.audioRendererFailed(
                CompressedAudioRetentionPolicy.accountingError
            ))
            return
        }
        preparedAnchor = PreparedAnchor(
            cycleID: preparation.cycleID,
            commonPTS: preparation.commonPTS,
            routeRevision: preparation.routeRevision
        )
        renderer.resetPresentationTiming()
        anchorPreparationTransaction = nil
        if let gapTransaction = audioGapReanchorTransaction,
           gapTransaction.islandID == audioCandidate.id,
           gapTransaction.generation == preparation.generation {
            audioGapReanchorTransaction = nil
        }
        updateReadinessIsolated()
    }

    private func outputRouteRevisionMatchesIsolated(_ expectedRevision: UInt64?) -> Bool {
        assertIsolated()
        guard let expectedRevision else { return true }
        return audio.currentRouteSnapshot?.revision == expectedRevision
    }

    private func hasSufficientMediaForAnchor(
        commonPTS: CMTime,
        audioIsland: AudioContinuityAnchorCandidate? = nil,
        videoFrames: [VideoPresentationFrame]? = nil,
        requireVideo: Bool = true
    ) -> Bool {
        assertIsolated()
        let audioIsland = audioIsland ?? audioContinuity.anchorCandidate(at: commonPTS)
        let videoFrames = videoFrames ?? retainedVideo
        guard audio.isReadyForPlayback,
              let audioIsland else { return false }
        let audioEnd = audioIsland.coverageEndPTS
        guard audioEnd.isNumeric,
              CMTimeCompare(audioIsland.coverageStartPTS, commonPTS) <= 0,
              CMTimeCompare(commonPTS, audioEnd) < 0 else { return false }
        guard requireVideo else { return true }
        let coveredVideoCount = videoFrames.filter { frame in
            let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return end.isNumeric
                && CMTimeCompare(end, commonPTS) > 0
                && CMTimeCompare(end, audioEnd) <= 0
        }.count
        return coveredVideoCount >= videoCoordinator.requiredVideoFrameCount
    }

    private func stopIsolated(
        publish: Bool,
        completion: StopCompletion?
    ) {
        assertIsolated()
        if normalStopCompleted {
            completion?()
            return
        }
        if normalStopInProgress {
            normalStopPublishes = normalStopPublishes || publish
            if let completion { stopCompletions.append(completion) }
            return
        }
        guard !terminal else {
            if !terminalEventPublished, let completion {
                stopCompletions.append(completion)
            } else {
                completion?()
            }
            return
        }
        normalStopInProgress = true
        normalStopPublishes = publish
        if let completion { stopCompletions.append(completion) }
        finishModeSwitchSignpostIsolated()
        terminal = true
        cancelPendingVideoFormatCommitIsolated()
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
        setSharedTimelineOpenedIsolated(false)
        cancelPendingVideoDrainIsolated()
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        clock.pause()
        // Normal teardown owns each deterministic stage independently. A malformed
        // tail in one component must not skip later waits or invalidation.
        do { try videoAssembler?.drain() } catch {}
        do { try audioAssembler?.drain() } catch {}
        videoCoordinator.stop(emergency: false)
        let generation = generationController.current
        renderer.flush(to: generation)
        audio.flush(to: generation)
        readiness?.closeForTimelineReset(.flush)
        clearRetainedVideoIsolated(keepingCapacity: false)
        deferredPackets.removeAll(keepingCapacity: false)
        pendingTrackVideo.removeAll(keepingCapacity: false)
        clearPendingTrackAudioIsolated(keepingCapacity: false)
        pendingVideoDecode.removeAll(keepingCapacity: false)
        videoDecodeBufferHorizon = nil
        display.pauseSubmission()
        Task { [self] in
            async let videoStop: Void = renderer.stopAwaitingRendererRemoval()
            async let audioStop: Void = audio.stopAwaitingRendererRemoval()
            _ = await (videoStop, audioStop)
            executor.submit { [self] in completeNormalStopIsolated() }
        }
        executor.submit(after: .seconds(2)) { [weak self] in
            self?.completeNormalStopIsolated()
        }
    }

    private func completeNormalStopIsolated() {
        assertIsolated()
        guard normalStopInProgress,
              !normalStopCompleted,
              !displayClearInProgress else { return }
        displayClearInProgress = true
        Task { [self] in
            await display.clearDisplayCriteria()
            executor.submit { [self] in
                finishNormalStopAfterDisplayClearIsolated()
            }
        }
        executor.submit(after: .milliseconds(500)) { [weak self] in
            self?.finishNormalStopAfterDisplayClearIsolated()
        }
    }

    private func finishNormalStopAfterDisplayClearIsolated() {
        assertIsolated()
        guard normalStopInProgress, !normalStopCompleted else { return }
        displayClearInProgress = false
        normalStopInProgress = false
        normalStopCompleted = true
        if normalStopPublishes { eventSink(.stopped) }
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion() }
    }

    private func failIsolated(_ error: PlaybackCoreError) {
        assertIsolated()
        guard !terminal else { return }
        refreshExternalMetricsDiagnostics()
        finishModeSwitchSignpostIsolated()
        terminal = true
        cancelPendingVideoFormatCommitIsolated()
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
        setSharedTimelineOpenedIsolated(false)
        cancelPendingVideoDrainIsolated()
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        pendingTrackVideo.removeAll(keepingCapacity: false)
        clearPendingTrackAudioIsolated(keepingCapacity: false)
        pendingVideoDecode.removeAll(keepingCapacity: false)
        videoDecodeBufferHorizon = nil
        videoCoordinator.stop(emergency: true)
        display.pauseSubmission()
        Task { [self] in
            async let videoStop: Void = renderer.stopAwaitingRendererRemoval()
            async let audioStop: Void = audio.stopAwaitingRendererRemoval()
            _ = await (videoStop, audioStop)
            executor.submit { [self] in
                beginFailureDisplayClearIsolated(error)
            }
        }
        executor.submit(after: .seconds(2)) { [weak self] in
            self?.beginFailureDisplayClearIsolated(error)
        }
    }

    private func beginFailureDisplayClearIsolated(_ error: PlaybackCoreError) {
        assertIsolated()
        guard terminal,
              !terminalEventPublished,
              !displayClearInProgress else { return }
        displayClearInProgress = true
        Task { [self] in
            await display.clearDisplayCriteria()
            executor.submit { [self] in
                finishFailureAfterDisplayClearIsolated(error)
            }
        }
        executor.submit(after: .milliseconds(500)) { [weak self] in
            self?.finishFailureAfterDisplayClearIsolated(error)
        }
    }

    private func finishFailureAfterDisplayClearIsolated(_ error: PlaybackCoreError) {
        assertIsolated()
        guard terminal, !terminalEventPublished else { return }
        displayClearInProgress = false
        terminalEventPublished = true
        eventSink(.failed(error))
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion() }
    }

    private func setSharedTimelineOpenedIsolated(_ opened: Bool) {
        assertIsolated()
        hasOpenedReadinessForCurrentMedia = opened
        audio.setSharedTimelineOpened(opened)
    }

    private func releasePendingAdmissionIsolated() {
        assertIsolated()
        pendingPacketAdmission?.acknowledgement.signal()
        pendingPacketAdmission = nil
    }

    private func finishModeSwitchSignpostIsolated() {
        assertIsolated()
        guard let modeSwitchSignpost else { return }
        signposts?.end(modeSwitchSignpost)
        self.modeSwitchSignpost = nil
    }
}

private final class PlaybackPipelineRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: PlaybackPipeline?

    func install(_ target: PlaybackPipeline) {
        lock.withLock { self.target = target }
    }

    func decoder(_ event: VideoDecoderEvent) {
        lock.withLock { target }?.receive(decoder: event)
    }

    func failure(_ error: PlaybackCoreError, generation: MediaGeneration) {
        lock.withLock { target }?.receive(failure: error, generation: generation)
    }

    func videoRendererRecovery(_ generation: MediaGeneration) {
        lock.withLock { target }?.receive(videoRendererRecovery: generation)
    }

    func audioReadiness(
        _ change: AudioRenderReadinessChange,
        generation: MediaGeneration
    ) {
        lock.withLock { target }?.receive(audioReadiness: change, generation: generation)
    }

    func displayModeSwitchStarted() {
        lock.withLock { target }?.displayModeSwitchStarted()
    }

    func displayModeSwitchEnded() {
        lock.withLock { target }?.displayModeSwitchEnded()
    }
}

private final class VisibleVideoRendererReference: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer

    init(_ renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }
}

struct SystemPlaybackPipelineFactory: PlaybackPipelineFactory {
    static func makeSynchronizer() -> AVSampleBufferRenderSynchronizer {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        return synchronizer
    }

    func makePipeline(
        tuning: PlaybackTuning,
        channelID: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackPipelineProtocol {
        let metrics = PlaybackMetrics(
            channelID: channelID
        )
        let signposts = PlaybackSignposts(channelIdentifier: metrics.channelIdentifier)
        let executor = PlaybackSerialExecutor()
        let demuxExecutor = PlaybackSerialExecutor(label: "org.vplayer.playback.demux.delivery")
        let synchronizer = Self.makeSynchronizer()
        let clock = RenderSynchronizerClock(synchronizer: synchronizer)
        let relay = PlaybackPipelineRelay()
        let decoderRelay = RoutingVideoDecoderChildRelay()
        let decoder = RoutingVideoDecoder(
            videoToolbox: VideoToolboxDecoder(
                executor: executor,
                tuning: tuning,
                diagnostics: (metrics: metrics, signposts: signposts)
            ) { decoderRelay.receive($0, from: .videoToolbox) },
            ffmpeg: FFmpegVideoDecoder(
                executor: executor,
                eventSink: { decoderRelay.receive($0, from: .ffmpeg) },
                metrics: metrics
            ),
            eventSink: { relay.decoder($0) }
        )
        decoderRelay.install(decoder)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PlaybackCoreError.metalCommand("device.unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw PlaybackCoreError.metalCommand("command-queue.unavailable")
        }
        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            nil,
            nil,
            device,
            nil,
            &textureCache
        )
        guard cacheStatus == kCVReturnSuccess, let textureCache else {
            throw PlaybackCoreError.metalCommand("texture-cache.\(cacheStatus)")
        }
        let presentationContext = PlaybackPresentationContext(
            switchStarted: { relay.displayModeSwitchStarted() },
            switchEnded: { relay.displayModeSwitchEnded() }
        )
        let videoRendererReference = await MainActor.run {
            VisibleVideoRendererReference(presentationContext.videoRenderer)
        }
        let videoRenderer = videoRendererReference.renderer
        // This exact object belongs to the visible AVSampleBufferDisplayLayer.
        // Attach it before the output adapter exists, so no video sample can be
        // enqueued outside the audio renderer's shared system timebase.
        synchronizer.addRenderer(videoRenderer)
        let recommendedPixelBufferAttributes = videoRenderer
            .recommendedPixelBufferAttributes
        let yadif: YADIFProcessor
        do {
            yadif = try YADIFProcessor(
                device: device,
                commandQueue: commandQueue,
                textureCache: textureCache,
                clock: clock,
                diagnostics: (metrics: metrics, signposts: signposts),
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                maximumPendingFrames: tuning.deinterlaceBufferFrames
            )
        } catch {
            throw PlaybackCoreError.metalCommand("yadif.setup")
        }
        let probe: LumaScanProbe
        do {
            probe = try LumaScanProbe(commandQueue: commandQueue, maximumFrames: 12)
        } catch {
            throw PlaybackCoreError.metalCommand("scan-probe.setup")
        }
        let surfaceLedger = VideoSurfaceBudgetLedger()
        let renderer = SystemVideoOutput(
            renderer: videoRenderer,
            synchronizer: synchronizer,
            ledger: surfaceLedger,
            metrics: metrics,
            recoverySink: { relay.videoRendererRecovery($0) },
            failureSink: { relay.failure($0, generation: $1) }
        )
        let display = PlaybackPresentationDisplayBridge(context: presentationContext)
        let audio = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { relay.failure($0, generation: $1) },
            clockMode: .externallyManaged,
            readinessSink: { relay.audioReadiness($0, generation: $1) }
        )
        let pipeline = PlaybackPipeline(
            executor: executor,
            demuxer: FFmpegDemuxer(executor: demuxExecutor),
            assemblerBuilder: SystemPlaybackAssemblerBuilder(),
            decoder: decoder,
            processor: PassthroughVideoProcessor(),
            yadifProcessor: yadif,
            scanProbe: probe,
            tuning: tuning,
            renderer: renderer,
            videoSurfaceLedger: surfaceLedger,
            audio: audio,
            clock: clock,
            display: display,
            eventSink: eventSink,
            presentationContext: presentationContext,
            metrics: metrics,
            signposts: signposts
        )
        relay.install(pipeline)
        return pipeline
    }
}
