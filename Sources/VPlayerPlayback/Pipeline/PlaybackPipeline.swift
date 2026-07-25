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
    case notice(PlaybackNotice)
    case stopped
    case failed(PlaybackCoreError)
}

protocol PlaybackPipelineProtocol: AnyObject, Sendable {
    var presentationContext: PlaybackPresentationContext? { get }
    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot?
    func start(url: URL)
    func setPaused(_ paused: Bool, readinessCycle: UInt64)
    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm)
    func setTuning(_ tuning: PlaybackTuning)
    func stop() async
}

protocol PlaybackPipelineFactory: Sendable {
    func makePipeline(
        selectedAlgorithm: DeinterlaceAlgorithm,
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
    // Must stay well inside `retainedVideoHorizon` so a closed-readiness startup
    // window cannot claim the whole presentation queue and starve the decoder
    // pool. Anchoring needs at most `requiredVideoFrameCount` (2 for field-rate
    // YADIF) frames, so a small window is sufficient here.
    static let startupRetainedVideoCapacity = 4
    // How far the running clock may outrun the *newest* decoded frame before the
    // pipeline re-anchors. Once even the newest frame is past due there is
    // nothing left that can be presented — every earlier frame is older still —
    // so this is a genuine stall rather than jitter, and the margin only needs to
    // absorb a single late frame. A larger margin is actively harmful: playback
    // settles just underneath it, showing nothing and never recovering.
    static let videoResyncThreshold = CMTime(value: 1, timescale: 25)
    private static let retainedAudioCapacity = 96

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
    private var readinessCycle: UInt64 = 0
    private var deferredPackets: [DemuxPacket] = []
    private var pendingPacketAdmission: PendingPacketAdmission?
    private var pendingTrackVideo: [CompressedVideoAccessUnit] = []
    private var pendingTrackAudio: [CompressedAudioSample] = []
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
        selectedAlgorithm: DeinterlaceAlgorithm = .appleTemporal,
        tuning: PlaybackTuning = .default,
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
            selectedAlgorithm: selectedAlgorithm,
            rawReadinessRequirementOverride: rawReadinessRequirementOverride,
            metrics: metrics,
            signposts: signposts,
            hooks: VideoPipelineCoordinatorHooks(
                closeAdmission: { [weak self] in self?.closeCoordinatorAdmissionIsolated() },
                advanceGeneration: { [weak self] in
                    self?.advanceCoordinatorGenerationIsolated()
                        ?? MediaGeneration(rawValue: 0)
                },
                resetPlayback: { [weak self] generation, requiredCount in
                    self?.resetCoordinatorPlaybackIsolated(
                        to: generation,
                        requiredVideoFrameCount: requiredCount
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
                notice: { [weak self] notice, generation in
                    guard let self,
                          generationController.accepts(generation),
                          !terminal else { return }
                    eventSink(.notice(notice))
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

    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) {
        executor.submit { [weak self] in
            guard let self, !terminal else { return }
            metrics?.update(selectedAlgorithm: algorithm)
            videoCoordinator.setAlgorithm(algorithm)
        }
    }

    func setTuning(_ tuning: PlaybackTuning) {
        executor.submit { [weak self] in
            guard let self, !terminal, self.tuning != tuning else { return }
            self.tuning = tuning
            renderer.apply(tuning)
            videoCoordinator.applyTuning(tuning)
            readiness?.setMaximumAnchorLag(tuning.maximumAnchorLag)
            boundRetainedVideoIsolated()
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
                        videoAdmissionOpen: false
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
                    videoAdmissionOpen: videoAdmissionOpen
                ))
            }
        }
    }

    static func coreError(for failure: VideoDecoderFailure) -> PlaybackCoreError {
        switch failure {
        case .unsupportedConfiguration:
            .videoDecode(kVTVideoDecoderUnsupportedDataFormatErr)
        case let .sessionCreate(status):
            .videoDecode(status)
        case .softwareDecoder:
            .hardwareDecoderUnavailable
        case let .badData(status), let .malfunction(status):
            .videoDecode(status)
        case .backpressureTimeout:
            .videoDecode(kVTVideoDecoderNotAvailableNowErr)
        case let .temporalUnavailable(failure):
            switch failure {
            case .unsupportedProperty:
                .videoDecode(kVTPropertyNotSupportedErr)
            case let .propertySetFailed(_, status),
                 let .initializationFailed(status),
                 let .processingFailed(status):
                .videoDecode(status)
            }
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
        videoCoordinator.handle(accessUnit: accessUnit)
    }

    private func admitAudioSampleIsolated(_ sample: CompressedAudioSample) throws {
        assertIsolated()
        guard generationController.accepts(sample.generation) else { return }
        try audio.enqueue(sample)
        retainedAudio.append(sample)
        retainedAudio.sort {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        if retainedAudio.count > Self.retainedAudioCapacity {
            retainedAudio.removeFirst(retainedAudio.count - Self.retainedAudioCapacity)
        }
        boundRetainedVideoIsolated()
        updateReadinessIsolated()
    }

    private func handle(decoder event: VideoDecoderEvent) {
        assertIsolated()
        guard !terminal else { return }
        videoCoordinator.handle(decoder: event)
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
        pendingTrackVideo.removeAll(keepingCapacity: true)
        pendingTrackAudio.removeAll(keepingCapacity: true)
        readyPublished = false
        readiness?.close(.discontinuity)
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
        requiredVideoFrameCount: Int
    ) {
        assertIsolated()
        clock.pause()
        readiness?.close(.discontinuity)
        readiness?.configure(requiredVideoFrameCount: requiredVideoFrameCount)
        readyPublished = false
        releasePendingAdmissionIsolated()
        preparedAnchor = nil
        anchorPreparationInProgress = false
        retainedAudio.removeAll(keepingCapacity: true)
        retainedVideo.removeAll(keepingCapacity: true)
        deferredPackets.removeAll(keepingCapacity: true)
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
        updateReadinessIsolated()
    }

    // Closing the gate here is the recovery, not a failure report: the following
    // readiness update reopens it and `prepareAnchorIsolated` re-anchors both
    // renderers on the media the pipeline actually holds. Without this, a single
    // hiccup that lets the clock overtake the decoder strands playback for good —
    // the gate stays open, so nothing ever re-anchors, while every arriving frame
    // expires on contact with the presentation queue.
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

    private func updateReadinessIsolated() {
        assertIsolated()
        guard !terminal, mediaAdmissionOpen, !paused, let readiness else { return }
        resyncIfVideoTrailsClockIsolated()
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
        case .appleTemporal:
            .appleTemporal
        case .metalYADIF2x:
            .metalYADIF2x
        case .rawTemporalFailure:
            .rawInterlacedAfterTemporalFailure
        }
    }

    private func contiguousAudioInterval(
        in samples: [CompressedAudioSample]? = nil
    ) -> (first: CMTime, duration: CMTime)? {
        assertIsolated()
        let samples = samples ?? retainedAudio
        guard let first = samples.first,
              first.presentationTimeStamp.isNumeric,
              first.duration.isNumeric,
              CMTimeCompare(first.duration, .zero) > 0 else { return nil }
        let firstPTS = first.presentationTimeStamp
        var end = CMTimeAdd(firstPTS, first.duration)
        guard end.isNumeric else { return nil }
        for sample in samples.dropFirst() {
            guard sample.presentationTimeStamp.isNumeric,
                  sample.duration.isNumeric,
                  CMTimeCompare(sample.duration, .zero) > 0 else { break }
            let comparison = CMTimeCompare(sample.presentationTimeStamp, end)
            guard comparison <= 0 else { break }
            let sampleEnd = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
            guard sampleEnd.isNumeric else { break }
            if CMTimeCompare(sampleEnd, end) > 0 { end = sampleEnd }
        }
        let duration = CMTimeSubtract(end, firstPTS)
        guard duration.isNumeric else { return nil }
        return (firstPTS, duration)
    }

    private func boundRetainedVideoIsolated() {
        assertIsolated()
        if let audioFirstPTS = contiguousAudioInterval()?.first {
            let before = retainedVideo.count
            retainedVideo.removeAll { frame in
                let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
                return end.isNumeric && CMTimeCompare(end, audioFirstPTS) <= 0
            }
            metrics?.recordAudioRelativeVideoPrune(count: before - retainedVideo.count)
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
            guard overHorizon || retainedVideo.count > tuning.videoBufferFrameCeiling else {
                return
            }
            retainedVideo.removeFirst()
        }
    }

    private func prepareAnchorIsolated(commonPTS: CMTime) -> Bool {
        assertIsolated()
        let expectedGeneration = generationController.current
        guard !terminal, !paused, let readiness else { return false }
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
        readiness?.close(.flush)
        retainedAudio.removeAll(keepingCapacity: false)
        retainedVideo.removeAll(keepingCapacity: false)
        deferredPackets.removeAll(keepingCapacity: false)
        pendingTrackVideo.removeAll(keepingCapacity: false)
        pendingTrackAudio.removeAll(keepingCapacity: false)
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
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        pendingTrackVideo.removeAll(keepingCapacity: false)
        pendingTrackAudio.removeAll(keepingCapacity: false)
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
        selectedAlgorithm: DeinterlaceAlgorithm,
        tuning: PlaybackTuning,
        channelID: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) throws -> any PlaybackPipelineProtocol {
        let metrics = PlaybackMetrics(
            selectedAlgorithm: selectedAlgorithm,
            channelID: channelID
        )
        let signposts = PlaybackSignposts(channelIdentifier: metrics.channelIdentifier)
        let executor = PlaybackSerialExecutor()
        let demuxExecutor = PlaybackSerialExecutor(label: "org.vplayer.playback.demux.delivery")
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let clock = RenderSynchronizerClock(synchronizer: synchronizer)
        let relay = PlaybackPipelineRelay()
        let decoder = VideoToolboxDecoder(
            executor: executor,
            diagnostics: (metrics: metrics, signposts: signposts)
        ) { relay.decoder($0) }
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
            selectedAlgorithm: selectedAlgorithm,
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
