// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

enum PlaybackPipelineEvent: Sendable, Equatable {
    case ready(readinessCycle: UInt64)
    case stopped
    case failed(PlaybackCoreError)
}

protocol PlaybackPipelineProtocol: AnyObject, Sendable {
    var presentationContext: PlaybackPresentationContext? { get }
    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot?
    func start(url: URL)
    func setPaused(_ paused: Bool, readinessCycle: UInt64)
    func setTuning(_ tuning: PlaybackTuning)
    func stop() async
}

protocol PlaybackPipelineFactory: Sendable {
    func makePipeline(
        tuning: PlaybackTuning,
        channelID: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) throws -> any PlaybackPipelineProtocol
}

protocol VideoAccessUnitAssembling: AnyObject {
    func push(_ packet: DemuxPacket) throws
    func drain() throws
    func reset(for trackSet: DemuxTrackSet) throws
}

protocol AudioSampleAssembling: AnyObject {
    func push(_ packet: DemuxPacket) throws
    func drain() throws
    func reset(for trackSet: DemuxTrackSet) throws
}

extension CompressedVideoAssembler: VideoAccessUnitAssembling {}
extension CompressedAudioAssembler: AudioSampleAssembling {}

protocol PlaybackAssemblerBuilding: Sendable {
    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling

    func makeAudio(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any AudioSampleAssembling
}

struct SystemPlaybackAssemblerBuilder: PlaybackAssemblerBuilding {
    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling {
        try CompressedVideoAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: eventSink,
            formatState: formatState
        )
    }

    func makeAudio(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any AudioSampleAssembling {
        try CompressedAudioAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: eventSink,
            formatState: formatState
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

protocol PlaybackVideoRendering: VideoRendering, VideoPresentationTimingResetting, PlaybackTunable {}
extension MetalVideoRenderer: PlaybackVideoRendering {
    func apply(_ tuning: PlaybackTuning) { setTuning(tuning) }
}

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
}

final class PlaybackPipeline: PlaybackPipelineProtocol, @unchecked Sendable {
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
    }

    static let deferredPacketCapacity = 32
    static let pendingTrackMediaCapacity = 96
    // Compressed access units are tiny beside decoded 4K P010 surfaces. This
    // reservoir absorbs a conventional HLS segment while decoded video stays
    // close to the playback clock. Five seconds at 50/60 fps already exceeds
    // the previous 240-unit bound and made a live segment lose its tail.
    static let pendingVideoDecodeCapacity = 512
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
    // Audio packet duration is expressed in the codec sample clock while PTS
    // can be rounded onto a container clock (90 kHz for MPEG-TS). Treat
    // sub-millisecond rounding residue as continuous without masking a real
    // missing audio packet.
    private static let audioContinuityTolerance = CMTime(value: 1, timescale: 1_000)
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
    static let retainedAudioCapacity = 512
    // Keep decoded surfaces close to presentation and leave the multi-second
    // reservoir compressed. This mirrors the bounded-frame strategy used by
    // mature live players and keeps HLS segment bursts out of VideoToolbox's
    // asynchronous submission backlog.
    static let maximumDecodedVideoLead = CMTime(value: 1, timescale: 4)
    private static let pendingVideoDrainInterval: DispatchTimeInterval = .milliseconds(10)
    // This matches VideoToolboxDecoder's in-flight window. Keeping the credit at
    // the pipeline boundary means an HLS burst remains compressed until a real
    // decoder completion arrives instead of filling the decoder's private
    // submission queue and forcing a skip to the next random-access picture.
    private static let maximumOutstandingVideoDecodeSubmissions = 8
    private static let recoveryAudioRunway = CMTime(value: 1, timescale: 4)

    private struct DecoderSubmissionKey: Hashable {
        let accessUnitID: UInt64
        let generation: MediaGeneration
    }

    private struct PendingPacketAdmission {
        let packet: DemuxPacket
        let acknowledgement: DispatchSemaphore
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
    private let audio: any AudioRenderPipelineProtocol
    private let clock: any PlaybackClock
    private let display: any PlaybackDisplayControlling
    private let eventSink: @Sendable (PlaybackPipelineEvent) -> Void
    private let metrics: PlaybackMetrics?
    private let signposts: PlaybackSignposts?
    private let videoDecodeStallTimeout: DispatchTimeInterval
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
    private var tracks: DemuxTrackSet?
    private var formatState: AssemblyFormatState?
    private var videoAssembler: (any VideoAccessUnitAssembling)?
    private var audioAssembler: (any AudioSampleAssembling)?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var audioCodec: AudioCodec?
    private var videoAdmissionOpen = false
    private var paused = false
    private var started = false
    private var terminal = false
    private var normalStopInProgress = false
    private var normalStopCompleted = false
    private var displayClearInProgress = false
    private var normalStopPublishes = false
    private var stopCompletions: [StopCompletion] = []
    private var readyPublished = false
    // Readiness cycle that display submission was last resumed for; `nil` until
    // the first resume. Paired with `readyPublished` so both an external close
    // (which clears `readyPublished`) and a gate-internal close (which only bumps
    // the cycle) let the next open resume submission again.
    private var displayResumedCycle: UInt64?
    private var hasOpenedReadinessForCurrentMedia = false
    private var readinessCycle: UInt64 = 0
    private var deferredPackets: [DemuxPacket] = []
    private var pendingPacketAdmission: PendingPacketAdmission?
    private var pendingTrackVideo: [CompressedVideoAccessUnit] = []
    private var pendingTrackAudio: [CompressedAudioSample] = []
    private var pendingVideoDecode: [CompressedVideoAccessUnit] = []
    private var pendingVideoDrainScheduled = false
    private var pendingVideoDrainToken: UInt64 = 0
    private var pendingVideoRecoveryAnchor: CMTime?
    private var outstandingVideoDecodeSubmissions: Set<DecoderSubmissionKey> = []
    private var videoDecodeStallWatchdogScheduled = false
    private var videoDecodeStallWatchdogToken: UInt64 = 0
    private var videoDecodeBufferHorizon: CMTime?
    private var retainedAudio: [CompressedAudioSample] = []
    private var retainedVideo: [VideoPresentationFrame] = []
    private var preparedAnchor: PreparedAnchor?
    private var anchorPreparationInProgress = false
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
        tuning: PlaybackTuning = .default,
        videoDecodeStallTimeout: DispatchTimeInterval = .seconds(1),
        rawReadinessRequirementOverride: Int? = nil,
        renderer: any PlaybackVideoRendering,
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
        self.demuxer = demuxer
        self.assemblerBuilder = assemblerBuilder
        self.renderer = renderer
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
                reopenAdmission: { [weak self] in self?.reopenCoordinatorAdmissionIsolated() },
                routeDidChange: { [weak self] requiredCount in
                    self?.coordinatorRouteDidChangeIsolated(
                        requiredVideoFrameCount: requiredCount
                    )
                },
                deliver: { [weak self] frames, generation in
                    self?.handleProcessedFrames(.success(frames), generation: generation)
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

    func start(url: URL) {
        executor.submit { [weak self] in self?.startIsolated(url: url) }
    }

    func setPaused(_ paused: Bool, readinessCycle: UInt64) {
        executor.submit { [weak self] in
            self?.setPausedIsolated(paused, readinessCycle: readinessCycle)
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
        metrics?.update(
            demuxQueueFullWaitNanoseconds: demuxer.queueFullWaitNanoseconds,
            demuxAdmitWaitNanoseconds: admitWaitNanoseconds.value,
            playbackExecutorBusyNanoseconds: executor.busyNanoseconds
        )
        return metrics?.snapshot(window: window)
    }

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

    func receive(decoder event: VideoDecoderEvent) {
        submitOrRun { [weak self] in self?.handle(decoder: event) }
    }

    func receive(failure: PlaybackCoreError, generation: MediaGeneration) {
        submitOrRun { [weak self] in
            guard let self, generationController.accepts(generation) else { return }
            failIsolated(failure)
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
                guard !anchorPreparationInProgress else { return }
                preparedAnchor = nil
                readiness?.close(.audioReplacement)
                readyPublished = false
                display.pauseSubmission()
                renderer.resetPresentationTiming()
            case .available:
                updateReadinessIsolated()
            }
        }
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
                        pendingVideoDecodeCount: 0
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
                    pendingVideoDecodeCount: pendingVideoDecode.count
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

    private func startIsolated(url: URL) {
        assertIsolated()
        guard !started, !terminal else { return }
        started = true
        readiness = PlaybackReadinessGate(clock: clock, prepareAnchorVeto: { [weak self] commonPTS in
            self?.prepareAnchorIsolated(commonPTS: commonPTS) == true
        })
        readiness?.setMaximumAnchorLag(tuning.maximumAnchorLag)
        readiness?.configure(requiredVideoFrameCount: videoCoordinator.requiredVideoFrameCount)
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
                try installTracksIsolated(newTracks, discontinuity: false)
            case let .packet(packet):
                metrics?.recordDemuxPacket()
                try routePacketIsolated(packet)
            case let .discontinuity(newTracks):
                try installTracksIsolated(newTracks, discontinuity: true)
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
        discontinuity: Bool
    ) throws {
        assertIsolated()
        guard newTracks.video != nil else { throw PlaybackCoreError.unsupportedVideoCodec }
        guard newTracks.audio != nil else { throw PlaybackCoreError.unsupportedAudioCodec }
        if let tracks, tracks == newTracks, !discontinuity { return }

        if tracks == nil {
            beginTrackEpochIsolated()
            let sharedState = AssemblyFormatState(trackSet: newTracks)
            formatState = sharedState
            videoAssembler = try assemblerBuilder.makeVideo(
                trackSet: newTracks,
                generationProvider: { [weak self] in
                    guard let self else { return MediaGeneration(rawValue: 0) }
                    self.assertIsolated()
                    return self.generationController.current
                },
                eventSink: { [weak self] event in self?.receive(video: event) },
                formatState: sharedState
            )
            audioAssembler = try assemblerBuilder.makeAudio(
                trackSet: newTracks,
                generationProvider: { [weak self] in
                    guard let self else { return MediaGeneration(rawValue: 0) }
                    self.assertIsolated()
                    return self.generationController.current
                },
                eventSink: { [weak self] event in self?.receive(audio: event) },
                formatState: sharedState
            )
            tracks = newTracks
            return
        }

        tracks = newTracks
        beginTrackEpochIsolated()
        if discontinuity {
            try forceAdvanceGenerationIsolated()
            guard !terminal else { return }
            trackEpochAlreadyAdvanced = true
        }
        try videoAssembler?.reset(for: newTracks)
        try audioAssembler?.reset(for: newTracks)
    }

    private func routePacketIsolated(_ packet: DemuxPacket) throws {
        assertIsolated()
        guard !packet.isCorrupt else { return }
        guard let tracks else { return }
        if packet.streamIndex == tracks.video?.streamIndex,
           packet.codec == tracks.video.map({ .video($0.codec) }) {
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
                guard mediaAdmissionOpen, videoAdmissionOpen else {
                    if awaitingFreshTrackEpoch {
                        bufferTrackVideoIsolated(accessUnit)
                    }
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
            case let .format(format, codec, fingerprint):
                audioFormat = format
                audioCodec = codec
                freshAudioFormatArrived = true
                try consumeCanonicalFingerprintIsolated(latestEventFingerprint: fingerprint)
            case let .sample(sample):
                metrics?.recordAudioSample()
                guard mediaAdmissionOpen else {
                    if awaitingFreshTrackEpoch {
                        bufferTrackAudioIsolated(sample)
                    }
                    return
                }
                try admitAudioSampleIsolated(sample)
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
        // Once a newer random-access point arrives, older undecodable GOP data is
        // no longer useful for starting the fresh track epoch.
        if accessUnit.isRandomAccess {
            pendingTrackVideo.removeAll(keepingCapacity: true)
        }
        pendingTrackVideo.append(accessUnit)
        if pendingTrackVideo.count > Self.pendingTrackMediaCapacity {
            pendingTrackVideo.removeFirst(
                pendingTrackVideo.count - Self.pendingTrackMediaCapacity
            )
        }
    }

    private func bufferTrackAudioIsolated(_ sample: CompressedAudioSample) {
        assertIsolated()
        guard generationController.accepts(sample.generation) else { return }
        pendingTrackAudio.append(sample)
        if pendingTrackAudio.count > Self.pendingTrackMediaCapacity {
            pendingTrackAudio.removeFirst(
                pendingTrackAudio.count - Self.pendingTrackMediaCapacity
            )
        }
    }

    private func replayPendingTrackMediaIsolated() throws {
        assertIsolated()
        let generation = generationController.current
        let video = pendingTrackVideo
        let audioSamples = pendingTrackAudio
        pendingTrackVideo.removeAll(keepingCapacity: true)
        pendingTrackAudio.removeAll(keepingCapacity: true)

        for accessUnit in video where !terminal {
            admitVideoAccessUnitIsolated(CompressedVideoAccessUnit(
                id: accessUnit.id,
                sampleBuffer: accessUnit.sampleBuffer,
                generation: generation,
                isRandomAccess: accessUnit.isRandomAccess,
                parserMetadata: accessUnit.parserMetadata
            ))
        }
        for sample in audioSamples where !terminal {
            try admitAudioSampleIsolated(CompressedAudioSample(
                id: sample.id,
                sampleBuffer: sample.sampleBuffer,
                codec: sample.codec,
                generation: generation,
                presentationTimeStamp: sample.presentationTimeStamp,
                duration: sample.duration
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
        let capacity = max(
            Self.pendingVideoDecodeCapacity,
            tuning.videoBufferFrameCeiling
        )
        if pendingVideoDecode.count < capacity {
            pendingVideoDecode.append(accessUnit)
        } else if accessUnit.isRandomAccess,
                  hasOpenedReadinessForCurrentMedia,
                  !pendingVideoDecode.contains(where: \.isRandomAccess) {
            metrics?.recordVideoDrop(
                count: pendingVideoDecode.count,
                source: .decodeSubmissionBacklog
            )
            pendingVideoDecode.removeAll(keepingCapacity: true)
            pendingVideoRecoveryAnchor = nil
            pendingVideoDecode.append(accessUnit)
        } else {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
        }
        // Every running-path access unit goes through the same credit-bound FIFO.
        // A temporarily empty queue must not create a direct-admission bypass for
        // the remainder of the same HLS segment burst.
        drainPendingVideoDecodeIsolated()
    }

    private func admitAudioSampleIsolated(_ sample: CompressedAudioSample) throws {
        assertIsolated()
        guard generationController.accepts(sample.generation) else { return }
        try audio.enqueue(sample)
        retainedAudio.append(sample)
        retainedAudio.sort {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        boundRetainedAudioIsolated()
        drainPendingVideoDecodeIsolated()
        boundRetainedVideoIsolated()
        updateReadinessIsolated()
    }

    private func shouldDeferVideoDecodeIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) -> Bool {
        assertIsolated()
        let bufferHorizon = videoDecodeBufferHorizon ?? tuning.videoBufferHorizon
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
        guard videoPTS.isNumeric,
              bufferHorizon.isNumeric else { return false }
        // HLS delivers a whole segment as a burst. `audioEnd` can therefore be
        // five or ten seconds ahead even though the viewer's clock has barely
        // advanced. Keep that reservoir compressed and decode only a small
        // window around the clock (or around the first audio PTS at startup).
        // Otherwise VideoToolbox receives the whole burst, its submission queue
        // sheds the tail, and playback repeats the first few decoded frames of
        // every segment.
        let decodedLead = CMTimeCompare(
            bufferHorizon,
            Self.maximumDecodedVideoLead
        ) < 0 ? bufferHorizon : Self.maximumDecodedVideoLead

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
            let audioInterval = contiguousAudioInterval()
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

        guard let audioInterval = contiguousAudioInterval() else { return false }
        let decodeLimit = CMTimeAdd(audioInterval.first, decodedLead)
        guard decodeLimit.isNumeric else { return false }
        return CMTimeCompare(videoPTS, decodeLimit) > 0
    }

    // Decode order and presentation order differ for B-frame streams. A future
    // reference picture can sit at the FIFO head while a following B picture is
    // inside the recovery window; deferring or discarding that head prevents the
    // eligible picture from ever decoding.
    private func pendingDecodeOrderNeedsHeadIsolated(
        _ head: CompressedVideoAccessUnit,
        toReachPresentationPTSAtOrBefore limit: CMTime
    ) -> Bool {
        assertIsolated()
        guard !head.isRandomAccess,
              let first = pendingVideoDecode.first,
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
        alignPendingVideoRecoveryAcrossGapIsolated()
        while !terminal,
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

    private func submitVideoAccessUnitIsolated(
        _ accessUnit: CompressedVideoAccessUnit
    ) {
        assertIsolated()
        let key = DecoderSubmissionKey(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation
        )
        guard outstandingVideoDecodeSubmissions.insert(key).inserted else {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
            return
        }
        if !videoCoordinator.handle(accessUnit: accessUnit) {
            outstandingVideoDecodeSubmissions.remove(key)
            return
        }
        scheduleVideoDecodeStallWatchdogIfNeededIsolated()
    }

    private func scheduleVideoDecodeStallWatchdogIfNeededIsolated() {
        assertIsolated()
        guard !terminal,
              !paused,
              outstandingVideoDecodeSubmissions.count
                  >= Self.maximumOutstandingVideoDecodeSubmissions,
              !videoDecodeStallWatchdogScheduled else { return }
        videoDecodeStallWatchdogScheduled = true
        let token = videoDecodeStallWatchdogToken
        let expectedGeneration = generationController.current
        executor.submit(after: videoDecodeStallTimeout) { [weak self] in
            guard let self,
                  videoDecodeStallWatchdogToken == token else { return }
            videoDecodeStallWatchdogScheduled = false
            guard !terminal,
                  !paused,
                  generationController.current == expectedGeneration,
                  outstandingVideoDecodeSubmissions.count
                      >= Self.maximumOutstandingVideoDecodeSubmissions else { return }
            // No completion freed a single slot for the whole timeout. Treat
            // this as the same decoder hang that its internal ninth-submission
            // wait used to detect before upstream credit prevented that probe.
            handle(decoder: .submissionFailure(
                .backpressureTimeout,
                generation: expectedGeneration
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
        if let audioFirst = contiguousAudioInterval()?.first,
           CMTimeCompare(audioFirst, anchor) > 0 {
            anchor = audioFirst
        }
        pendingVideoRecoveryAnchor = anchor

        let bufferHorizon = videoDecodeBufferHorizon ?? tuning.videoBufferHorizon
        let decodedLead = CMTimeCompare(bufferHorizon, Self.maximumDecodedVideoLead) < 0
            ? bufferHorizon
            : Self.maximumDecodedVideoLead
        let recoveryLimit = CMTimeAdd(anchor, decodedLead)
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
    }

    private func handle(decoder event: VideoDecoderEvent) {
        assertIsolated()
        guard !terminal else { return }
        videoCoordinator.handle(decoder: event)
        if case let .submissionCompleted(accessUnitID, generation) = event {
            let key = DecoderSubmissionKey(
                accessUnitID: accessUnitID,
                generation: generation
            )
            guard outstandingVideoDecodeSubmissions.remove(key) != nil else { return }
            invalidateVideoDecodeStallWatchdogIsolated()
        }
        drainPendingVideoDecodeIsolated()
    }

    private func handleProcessedFrames(
        _ result: Result<[VideoPresentationFrame], PlaybackFailure>,
        generation: MediaGeneration
    ) {
        assertIsolated()
        guard !terminal,
              mediaAdmissionOpen,
              generationController.accepts(generation) else { return }
        switch result {
        case let .success(frames):
            for frame in frames where generationController.accepts(frame.generation) {
                videoDecodeBufferHorizon = effectiveVideoBufferHorizon(for: frame)
                updateMaximumAnchorLagIsolated(for: frame)
                if readiness?.isOpen == true {
                    renderer.enqueue(frame)
                }
                retainedVideo.append(frame)
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
            updateReadinessIsolated()
        case let .failure(failure):
            failIsolated(.metalCommand(failure.code))
        }
    }

    private func consumeCanonicalFingerprintIsolated(
        latestEventFingerprint fingerprint: MediaFormatFingerprint
    ) throws {
        assertIsolated()
        if awaitingFreshTrackEpoch {
            guard freshVideoFormatArrived,
                  freshAudioFormatArrived,
                  videoFormat != nil,
                  audioFormat != nil,
                  audioCodec != nil else { return }
            consumedFingerprint = fingerprint
            if trackEpochAlreadyAdvanced {
                try configureCurrentGenerationIsolated()
            } else {
                try rebuildForCurrentFormatsIsolated()
            }
            guard !terminal else { return }
            awaitingFreshTrackEpoch = false
            trackEpochAlreadyAdvanced = false
            mediaAdmissionOpen = true
            videoAdmissionOpen = true
            try replayPendingTrackMediaIsolated()
            return
        }
        guard consumedFingerprint != fingerprint else { return }
        consumedFingerprint = fingerprint
        try rebuildForCurrentFormatsIsolated()
        guard !terminal else { return }
    }

    private func beginTrackEpochIsolated() {
        assertIsolated()
        awaitingFreshTrackEpoch = true
        freshVideoFormatArrived = false
        freshAudioFormatArrived = false
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
        videoFormat = nil
        audioFormat = nil
        audioCodec = nil
        trackEpochAlreadyAdvanced = false
        hasOpenedReadinessForCurrentMedia = false
        cancelPendingVideoDrainIsolated()
        pendingTrackVideo.removeAll(keepingCapacity: true)
        pendingTrackAudio.removeAll(keepingCapacity: true)
        pendingVideoDecode.removeAll(keepingCapacity: true)
        videoDecodeBufferHorizon = nil
        readyPublished = false
        readiness?.closeForTimelineReset(.discontinuity)
        metrics?.resetPresentationTimeline()
        display.pauseSubmission()
    }

    private func configureCurrentGenerationIsolated() throws {
        assertIsolated()
        guard let videoFormat, let audioFormat, let audioCodec else { return }
        let generation = generationController.current
        videoCoordinator.installFormatForCurrentGeneration(videoFormat)
        try audio.configure(format: audioFormat, codec: audioCodec, generation: generation)
        mediaAdmissionOpen = true
        videoAdmissionOpen = true
    }

    private func forceAdvanceGenerationIsolated() throws {
        assertIsolated()
        videoCoordinator.beginDiscontinuity()
        guard !terminal else { return }
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
    }

    private func rebuildForCurrentFormatsIsolated() throws {
        assertIsolated()
        guard let videoFormat, let audioFormat, let audioCodec else { return }
        videoCoordinator.replaceFormat(videoFormat)
        guard !terminal else { return }
        let generation = generationController.current
        try audio.configure(format: audioFormat, codec: audioCodec, generation: generation)
        guard !terminal else { return }
        mediaAdmissionOpen = true
        videoAdmissionOpen = true
    }

    private func closeCoordinatorAdmissionIsolated() {
        assertIsolated()
        mediaAdmissionOpen = false
        videoAdmissionOpen = false
    }

    private func advanceCoordinatorGenerationIsolated() -> MediaGeneration {
        assertIsolated()
        return generationController.forceAdvance()
    }

    private func resetCoordinatorPlaybackIsolated(
        to generation: MediaGeneration,
        requiredVideoFrameCount: Int,
        resetScope: VideoPipelineCoordinatorHooks.PlaybackResetScope
    ) {
        assertIsolated()
        clock.pause()
        switch resetScope {
        case .timeline:
            readiness?.closeForTimelineReset(.discontinuity)
            hasOpenedReadinessForCurrentMedia = false
            metrics?.resetPresentationTimeline()
        case .decoderSession:
            // A decoder rebuild changes ownership/lifetime generations, not
            // media time. Keep the paused-clock floor so buffered access units
            // from before the stall cannot anchor the shared clock backwards.
            readiness?.close(.buffering)
        }
        readiness?.configure(requiredVideoFrameCount: requiredVideoFrameCount)
        readyPublished = false
        cancelPendingVideoDrainIsolated()
        releasePendingAdmissionIsolated()
        preparedAnchor = nil
        anchorPreparationInProgress = false
        retainedAudio.removeAll(keepingCapacity: true)
        retainedVideo.removeAll(keepingCapacity: true)
        deferredPackets.removeAll(keepingCapacity: true)
        pendingVideoDecode.removeAll(keepingCapacity: true)
        videoDecodeBufferHorizon = nil
        renderer.flush(to: generation)
        audio.flush(to: generation)
        display.pauseSubmission()
        metrics?.beginAVDriftGracePeriod(seconds: 5)
    }

    private func reopenCoordinatorAdmissionIsolated() {
        assertIsolated()
        mediaAdmissionOpen = true
        videoAdmissionOpen = true
    }

    private func coordinatorRouteDidChangeIsolated(requiredVideoFrameCount: Int) {
        assertIsolated()
        readiness?.close(.buffering)
        readiness?.configure(requiredVideoFrameCount: requiredVideoFrameCount)
        readyPublished = false
        preparedAnchor = nil
        retainedVideo.removeAll(keepingCapacity: true)
        renderer.flush(to: generationController.current)
        display.pauseSubmission()
        metrics?.beginAVDriftGracePeriod(seconds: 5)
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
        retainedVideo.removeAll {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, pausedAudioTime) <= 0
        }
        renderer.flush(to: generationController.current)
        for frame in retainedVideo { renderer.enqueue(frame) }
        readiness?.close(.buffering)

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
        scheduleVideoDecodeStallWatchdogIfNeededIsolated()
        updateReadinessIsolated()
    }

    private func updateReadinessIsolated() {
        assertIsolated()
        guard !terminal, mediaAdmissionOpen, !paused, let readiness else { return }
        resyncIfVideoTrailsClockIsolated()
        pruneRetainedAudioBeforeRecoveryFloorIsolated()
        pruneRetainedVideoBeforeRecoveryFloorIsolated()
        let expectedGeneration = generationController.current
        let audioInterval = contiguousAudioInterval()
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
        metrics?.updateReadinessDiagnostics(
            audioRoute: audio.route,
            audioReady: audio.isReadyForPlayback,
            readinessOpen: readiness.isOpen,
            retainedAudioCount: retainedAudio.count,
            retainedVideoCount: retainedVideo.count,
            audioFirstPTS: audioInterval?.first,
            audioDuration: audioInterval?.duration,
            videoFirstPTS: retainedVideo.first?.presentationTimeStamp,
            readinessCycleID: readiness.cycleID,
            readinessCloseReasonCounts: readiness.closeReasonCounts,
            clockTime: clock.currentTime,
            audioRecoveryCount: audio.recoveryCount
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
        metrics?.beginAVDriftGracePeriod(seconds: 5)
    }

    private func displayModeSwitchEndedIsolated() {
        assertIsolated()
        finishModeSwitchSignpostIsolated()
        guard !terminal, !paused, let readiness else { return }
        _ = readiness.reopenAfterDisplayModeSwitch()
        if readiness.isOpen {
            displayResumedCycle = readiness.cycleID
            resumeDisplayForOpenReadinessGateIsolated()
        } else {
            updateReadinessIsolated()
        }
    }

    private func resumeDisplayForOpenReadinessGateIsolated() {
        assertIsolated()
        hasOpenedReadinessForCurrentMedia = true
        pendingVideoRecoveryAnchor = nil
        drainPendingVideoDecodeIsolated()
        if pendingDisplayTimingReset {
            pendingDisplayTimingReset = false
            renderer.resetPresentationTiming()
            display.resetPresentationTiming()
        }
        display.resumeSubmission()
        metrics?.recordDisplaySubmissionResume()
        metrics?.beginAVDriftGracePeriod(seconds: 5)
        if !readyPublished {
            readyPublished = true
            eventSink(.ready(readinessCycle: readinessCycle))
        }
    }

    private func presentationRoute(for route: DeinterlaceRoute) -> PlaybackPresentationRoute {
        switch route {
        case .bypass, .rawWhileClassifying:
            .progressive
        case .metalYADIF2x:
            .metalYADIF2x
        }
    }

    private func contiguousAudioInterval(
        in samples: [CompressedAudioSample]? = nil
    ) -> (first: CMTime, duration: CMTime)? {
        assertIsolated()
        let samples = samples ?? retainedAudio
        guard let run = firstContiguousAudioRun(in: samples) else { return nil }
        return (run.first, run.duration)
    }

    private func firstContiguousAudioRun(
        in samples: [CompressedAudioSample]
    ) -> (count: Int, first: CMTime, duration: CMTime)? {
        assertIsolated()
        guard let first = samples.first,
              first.presentationTimeStamp.isNumeric,
              first.duration.isNumeric,
              CMTimeCompare(first.duration, .zero) > 0 else { return nil }
        let firstPTS = first.presentationTimeStamp
        var end = CMTimeAdd(firstPTS, first.duration)
        var count = 1
        guard end.isNumeric else { return nil }
        for sample in samples.dropFirst() {
            guard sample.presentationTimeStamp.isNumeric,
                  sample.duration.isNumeric,
                  CMTimeCompare(sample.duration, .zero) > 0 else { break }
            let toleratedEnd = CMTimeAdd(end, Self.audioContinuityTolerance)
            guard toleratedEnd.isNumeric else { break }
            let comparison = CMTimeCompare(sample.presentationTimeStamp, toleratedEnd)
            guard comparison <= 0 else { break }
            let sampleEnd = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
            guard sampleEnd.isNumeric else { break }
            if CMTimeCompare(sampleEnd, end) > 0 { end = sampleEnd }
            count += 1
        }
        let duration = CMTimeSubtract(end, firstPTS)
        guard duration.isNumeric else { return nil }
        return (count, firstPTS, duration)
    }

    private func boundRetainedVideoIsolated() {
        assertIsolated()
        pruneRetainedVideoBeforeRecoveryFloorIsolated()
        if let audioFirstPTS = contiguousAudioInterval()?.first {
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
                retainedVideo.removeAll { frame in
                    let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
                    return end.isNumeric && CMTimeCompare(end, audioFirstPTS) <= 0
                }
                metrics?.recordAudioRelativeVideoPrune(count: before - retainedVideo.count)
            }
        }

        // The two playback phases need opposite overflow victims, so the bound
        // cannot be unified. While readiness is closed the anchor is still being
        // built at the audio's leading edge, so the *earliest* frames are the ones
        // that must survive until lagging audio reaches them. Once readiness is
        // open the retained window only exists to reseed the renderer on a
        // re-anchor, so keeping the earliest frames there replays seconds-old
        // video and drags the clock backwards. Drop the oldest instead, matching
        // how `retainedAudio` slides forward.
        if !paused, readiness?.isOpen != true {
            guard retainedVideo.count > Self.startupRetainedVideoCapacity else { return }
            retainedVideo.removeLast(
                retainedVideo.count - Self.startupRetainedVideoCapacity
            )
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
            estimatedBytes = max(0, estimatedBytes - removed.estimatedStorageBytes)
        }
    }

    private func boundRetainedAudioIsolated() {
        assertIsolated()
        pruneRetainedAudioBeforeRecoveryFloorIsolated()
        let recoveryFloor = audioRecoveryFloorIsolated()
        if let recoveryFloor {
            retainedAudio.removeAll { sample in
                let end = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
                return end.isNumeric && CMTimeCompare(end, recoveryFloor) <= 0
            }
        }

        // The count is an abnormal-input memory fuse, not the normal eviction
        // policy. Never sacrifice the samples covering the paused/live clock to
        // make room for the far end of a segment burst. At first startup there
        // is no trustworthy clock yet, so the same rule keeps the earliest data.
        while retainedAudio.count > Self.retainedAudioCapacity {
            guard let recoveryFloor,
                  let first = retainedAudio.first else {
                retainedAudio.removeLast()
                continue
            }
            let firstEnd = CMTimeAdd(first.presentationTimeStamp, first.duration)
            if firstEnd.isNumeric, CMTimeCompare(firstEnd, recoveryFloor) <= 0 {
                retainedAudio.removeFirst()
            } else {
                retainedAudio.removeLast()
            }
        }
    }

    private func pruneRetainedAudioBeforeRecoveryFloorIsolated() {
        assertIsolated()
        guard let floor = readiness?.minimumRecoveryAnchorPTS,
              floor.isNumeric else { return }
        retainedAudio.removeAll { sample in
            let end = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
            return end.isNumeric && CMTimeCompare(end, floor) <= 0
        }

        // A packet at the recovery floor can form a tiny island before a gap.
        // Once a later island proves that gap is closed, the short prefix can
        // never grow enough to satisfy readiness; leaving it first makes the
        // useful later island invisible forever. Keep the newest run while it
        // can still grow, but discard every sealed run with less than the
        // quarter-second recovery runway.
        while let run = firstContiguousAudioRun(in: retainedAudio) {
            let runEnd = CMTimeAdd(run.first, run.duration)
            let runwayStart = CMTimeCompare(run.first, floor) > 0 ? run.first : floor
            let runway = CMTimeSubtract(runEnd, runwayStart)
            guard runway.isNumeric,
                  CMTimeCompare(runway, Self.recoveryAudioRunway) < 0,
                  run.count < retainedAudio.count else { return }
            retainedAudio.removeFirst(run.count)
        }
    }

    private func pruneRetainedVideoBeforeRecoveryFloorIsolated() {
        assertIsolated()
        guard let floor = readiness?.minimumRecoveryAnchorPTS,
              floor.isNumeric else { return }
        retainedVideo.removeAll { frame in
            frame.presentationTimeStamp.isNumeric
                && CMTimeCompare(frame.presentationTimeStamp, floor) < 0
        }
    }

    private func audioRecoveryFloorIsolated() -> CMTime? {
        assertIsolated()
        guard hasOpenedReadinessForCurrentMedia else { return nil }
        var candidates: [CMTime] = []
        let clockTime = clock.currentTime
        if clockTime.isNumeric { candidates.append(clockTime) }
        if let videoPTS = retainedVideo.first?.presentationTimeStamp,
           videoPTS.isNumeric {
            candidates.append(videoPTS)
        }
        if let pending = pendingVideoDecode.first {
            let pendingPTS = CMSampleBufferGetPresentationTimeStamp(pending.sampleBuffer)
            if pendingPTS.isNumeric { candidates.append(pendingPTS) }
        }
        return candidates.min { CMTimeCompare($0, $1) < 0 }
    }

    private func prepareAnchorIsolated(commonPTS: CMTime) -> Bool {
        assertIsolated()
        let expectedGeneration = generationController.current
        guard !terminal, !paused, let readiness else { return false }
        if let floor = readiness.minimumRecoveryAnchorPTS,
           CMTimeCompare(commonPTS, floor) < 0 {
            return false
        }
        let expectedCycle = readiness.cycleID
        let candidateAudio = retainedAudio.filter {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return !end.isNumeric || CMTimeCompare(end, commonPTS) > 0
        }
        let candidateVideo = retainedVideo.filter {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return !end.isNumeric || CMTimeCompare(end, commonPTS) > 0
        }

        // Readiness is updated in two phases (audio, then video), so its first
        // attempt can legitimately carry the previous video snapshot. Treat the
        // trim as a transaction: a rejected candidate must not permanently move
        // the retained-media window forward and make audio chase video forever.
        guard hasSufficientMediaForAnchor(
            commonPTS: commonPTS,
            audioSamples: candidateAudio,
            videoFrames: candidateVideo
        ) else { return false }
        retainedAudio = candidateAudio
        retainedVideo = candidateVideo

        let alreadyPrepared = preparedAnchor.map {
            $0.cycleID == expectedCycle && CMTimeCompare($0.commonPTS, commonPTS) == 0
        } ?? false
        if !alreadyPrepared {
            let reanchorSignpost = signposts?.begin(
                .reanchor,
                correlation: generationController.current.rawValue
            )
            defer {
                if let reanchorSignpost { signposts?.end(reanchorSignpost) }
            }
            preparedAnchor = PreparedAnchor(cycleID: expectedCycle, commonPTS: commonPTS)
            anchorPreparationInProgress = true
            defer { anchorPreparationInProgress = false }
            audio.flush(to: generationController.current)
            for sample in retainedAudio {
                do {
                    try audio.enqueue(sample)
                } catch let error as PlaybackCoreError {
                    failIsolated(error)
                    return false
                } catch {
                    failIsolated(.audioRendererFailed("audio.anchor"))
                    return false
                }
            }
            renderer.flush(to: generationController.current)
            for frame in retainedVideo { renderer.enqueue(frame) }
        }
        guard !terminal,
              !paused,
              generationController.current == expectedGeneration,
              readiness.cycleID == expectedCycle,
              hasSufficientMediaForAnchor(commonPTS: commonPTS) else { return false }
        renderer.resetPresentationTiming()
        return true
    }

    private func hasSufficientMediaForAnchor(
        commonPTS: CMTime,
        audioSamples: [CompressedAudioSample]? = nil,
        videoFrames: [VideoPresentationFrame]? = nil
    ) -> Bool {
        assertIsolated()
        let audioSamples = audioSamples ?? retainedAudio
        let videoFrames = videoFrames ?? retainedVideo
        guard audio.isReadyForPlayback,
              let interval = contiguousAudioInterval(in: audioSamples) else { return false }
        let audioEnd = CMTimeAdd(interval.first, interval.duration)
        guard audioEnd.isNumeric,
              CMTimeCompare(interval.first, commonPTS) <= 0,
              CMTimeCompare(
                  CMTimeSubtract(audioEnd, commonPTS),
                  CMTime(value: 1, timescale: 4)
              ) >= 0 else { return false }
        let overlappingVideoCount = videoFrames.filter { frame in
            let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return end.isNumeric
                && CMTimeCompare(end, commonPTS) > 0
                && CMTimeCompare(frame.presentationTimeStamp, audioEnd) < 0
        }.count
        return overlappingVideoCount >= videoCoordinator.requiredVideoFrameCount
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
            if displayClearInProgress, let completion {
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
        retainedAudio.removeAll(keepingCapacity: false)
        retainedVideo.removeAll(keepingCapacity: false)
        deferredPackets.removeAll(keepingCapacity: false)
        pendingTrackVideo.removeAll(keepingCapacity: false)
        pendingTrackAudio.removeAll(keepingCapacity: false)
        pendingVideoDecode.removeAll(keepingCapacity: false)
        videoDecodeBufferHorizon = nil
        display.pauseSubmission()
        Task { [self] in
            await audio.stopAwaitingRendererRemoval()
            executor.submit { [self] in completeNormalStopIsolated() }
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
        finishModeSwitchSignpostIsolated()
        terminal = true
        cancelPendingVideoDrainIsolated()
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        pendingTrackVideo.removeAll(keepingCapacity: false)
        pendingTrackAudio.removeAll(keepingCapacity: false)
        pendingVideoDecode.removeAll(keepingCapacity: false)
        videoDecodeBufferHorizon = nil
        videoCoordinator.stop(emergency: true)
        audio.stop()
        display.pauseSubmission()
        displayClearInProgress = true
        Task { [self] in
            await display.clearDisplayCriteria()
            executor.submit { [self] in
                displayClearInProgress = false
                eventSink(.failed(error))
                let completions = stopCompletions
                stopCompletions.removeAll(keepingCapacity: false)
                for completion in completions { completion() }
            }
        }
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

struct SystemPlaybackPipelineFactory: PlaybackPipelineFactory {
    func makePipeline(
        tuning: PlaybackTuning,
        channelID: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) throws -> any PlaybackPipelineProtocol {
        let metrics = PlaybackMetrics(
            channelID: channelID
        )
        let signposts = PlaybackSignposts(channelIdentifier: metrics.channelIdentifier)
        let executor = PlaybackSerialExecutor()
        let demuxExecutor = PlaybackSerialExecutor(label: "org.vplayer.playback.demux.delivery")
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let clock = RenderSynchronizerClock(synchronizer: synchronizer)
        let relay = PlaybackPipelineRelay()
        let decoder = RoutingVideoDecoder(
            videoToolbox: VideoToolboxDecoder(
                executor: executor,
                tuning: tuning,
                diagnostics: (metrics: metrics, signposts: signposts)
            ) { relay.decoder($0) },
            ffmpeg: FFmpegVideoDecoder(
                executor: executor,
                eventSink: { relay.decoder($0) },
                metrics: metrics
            )
        )
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
        let yadif: YADIFProcessor
        do {
            yadif = try YADIFProcessor(
                device: device,
                commandQueue: commandQueue,
                textureCache: textureCache,
                clock: clock,
                diagnostics: (metrics: metrics, signposts: signposts),
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
        let renderer = try MetalVideoRenderer(
            device: device,
            generation: MediaGeneration(rawValue: 0),
            tuning: tuning,
            metrics: metrics,
            signposts: signposts,
            failureSink: { relay.failure($0, generation: $1) }
        )
        let presentationContext = PlaybackPresentationContext(
            renderer: renderer,
            clock: clock,
            device: device,
            switchStarted: { relay.displayModeSwitchStarted() },
            switchEnded: { relay.displayModeSwitchEnded() }
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
