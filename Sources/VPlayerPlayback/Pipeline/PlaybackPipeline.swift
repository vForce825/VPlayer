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
    func start(url: URL)
    func setPaused(_ paused: Bool, readinessCycle: UInt64)
    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm)
    func stop() async
}

protocol PlaybackPipelineFactory: Sendable {
    func makePipeline(
        selectedAlgorithm: DeinterlaceAlgorithm,
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

protocol PlaybackVideoRendering: VideoRendering, VideoPresentationTimingResetting {}
extension MetalVideoRenderer: PlaybackVideoRendering {}

protocol PlaybackDisplayControlling: Sendable {
    func pauseSubmission()
    func resumeSubmission()
    func clearDisplayCriteria()
}

private struct PhaseTwoPlaybackDisplay: PlaybackDisplayControlling {
    func pauseSubmission() {}
    func resumeSubmission() {}
    func clearDisplayCriteria() {}
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
    private typealias StopCompletion = @Sendable () -> Void

    private struct PreparedAnchor {
        let cycleID: UInt64
        let commonPTS: CMTime
    }

    static let deferredPacketCapacity = 32
    private static let retainedAudioCapacity = 96
    private static let retainedVideoCapacity = VideoPresentationQueue.capacity

    private struct PendingPacketAdmission {
        let packet: DemuxPacket
        let acknowledgement: DispatchSemaphore
    }

    private let executor: PlaybackSerialExecutor
    private let demuxer: any MediaDemuxing
    private let assemblerBuilder: any PlaybackAssemblerBuilding
    private let renderer: any PlaybackVideoRendering
    private let audio: any AudioRenderPipelineProtocol
    private let clock: any PlaybackClock
    private let display: any PlaybackDisplayControlling
    private let eventSink: @Sendable (PlaybackPipelineEvent) -> Void
    private var videoCoordinator: VideoPipelineCoordinator!

    // Every property below is accessed exclusively from `executor`.
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
    private var normalStopPublishes = false
    private var stopCompletions: [StopCompletion] = []
    private var readyPublished = false
    private var readinessCycle: UInt64 = 0
    private var deferredPackets: [DemuxPacket] = []
    private var pendingPacketAdmission: PendingPacketAdmission?
    private var retainedAudio: [CompressedAudioSample] = []
    private var retainedVideo: [VideoPresentationFrame] = []
    private var preparedAnchor: PreparedAnchor?
    private var anchorPreparationInProgress = false

    init(
        executor: PlaybackSerialExecutor,
        demuxer: any MediaDemuxing,
        assemblerBuilder: any PlaybackAssemblerBuilding,
        decoder: any VideoDecoding,
        processor: any VideoFrameProcessing,
        yadifProcessor: any YADIFFrameProcessing,
        scanProbe: (any LumaScanProbing)? = nil,
        selectedAlgorithm: DeinterlaceAlgorithm = .appleTemporal,
        rawReadinessRequirementOverride: Int? = nil,
        renderer: any PlaybackVideoRendering,
        audio: any AudioRenderPipelineProtocol,
        clock: any PlaybackClock,
        display: any PlaybackDisplayControlling,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) {
        self.executor = executor
        self.demuxer = demuxer
        self.assemblerBuilder = assemblerBuilder
        self.renderer = renderer
        self.audio = audio
        self.clock = clock
        self.display = display
        self.eventSink = eventSink
        videoCoordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: processor,
            yadif: yadifProcessor,
            probe: scanProbe,
            initialGeneration: generationController.current,
            selectedAlgorithm: selectedAlgorithm,
            rawReadinessRequirementOverride: rawReadinessRequirementOverride,
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
            videoCoordinator.setAlgorithm(algorithm)
        }
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
        acknowledgement.wait()
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
                guard mediaAdmissionOpen, videoAdmissionOpen else { return }
                guard generationController.accepts(accessUnit.generation) else { return }
                videoCoordinator.handle(accessUnit: accessUnit)
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
                guard mediaAdmissionOpen else { return }
                guard generationController.accepts(sample.generation) else { return }
                try audio.enqueue(sample)
                retainedAudio.append(sample)
                retainedAudio.sort { CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0 }
                if retainedAudio.count > Self.retainedAudioCapacity {
                    retainedAudio.removeFirst(retainedAudio.count - Self.retainedAudioCapacity)
                }
                updateReadinessIsolated()
            }
        } catch let error as PlaybackCoreError {
            failIsolated(error)
        } catch {
            failIsolated(.audioRendererFailed("audio.pipeline"))
        }
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
                renderer.enqueue(frame)
                retainedVideo.append(frame)
            }
            retainedVideo.sort {
                let comparison = CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp)
                return comparison == 0 ? $0.sequenceNumber < $1.sequenceNumber : comparison < 0
            }
            if retainedVideo.count > Self.retainedVideoCapacity {
                retainedVideo.removeFirst(retainedVideo.count - Self.retainedVideoCapacity)
            }
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

    private func updateReadinessIsolated() {
        assertIsolated()
        guard !terminal, mediaAdmissionOpen, !paused, let readiness else { return }
        let expectedGeneration = generationController.current
        let expectedCycle = readiness.cycleID
        let wasOpen = readiness.isOpen
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
        if !wasOpen,
           readiness.isOpen,
           readiness.cycleID == expectedCycle,
           generationController.current == expectedGeneration,
           !terminal,
           !paused,
           !readyPublished {
            readyPublished = true
            display.resumeSubmission()
            eventSink(.ready(readinessCycle: readinessCycle))
        }
    }

    private func contiguousAudioInterval() -> (first: CMTime, duration: CMTime)? {
        assertIsolated()
        guard let first = retainedAudio.first,
              first.presentationTimeStamp.isNumeric,
              first.duration.isNumeric,
              CMTimeCompare(first.duration, .zero) > 0 else { return nil }
        let firstPTS = first.presentationTimeStamp
        var end = CMTimeAdd(firstPTS, first.duration)
        guard end.isNumeric else { return nil }
        for sample in retainedAudio.dropFirst() {
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

    private func prepareAnchorIsolated(commonPTS: CMTime) -> Bool {
        assertIsolated()
        let expectedGeneration = generationController.current
        guard !terminal, !paused, let readiness else { return false }
        let expectedCycle = readiness.cycleID
        retainedAudio.removeAll {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, commonPTS) <= 0
        }
        retainedVideo.removeAll {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, commonPTS) <= 0
        }

        guard hasSufficientMediaForAnchor(commonPTS: commonPTS) else { return false }

        let alreadyPrepared = preparedAnchor.map {
            $0.cycleID == expectedCycle && CMTimeCompare($0.commonPTS, commonPTS) == 0
        } ?? false
        if !alreadyPrepared {
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

    private func hasSufficientMediaForAnchor(commonPTS: CMTime) -> Bool {
        assertIsolated()
        guard audio.isReadyForPlayback,
              let interval = contiguousAudioInterval() else { return false }
        let audioEnd = CMTimeAdd(interval.first, interval.duration)
        guard audioEnd.isNumeric,
              CMTimeCompare(interval.first, commonPTS) <= 0,
              CMTimeCompare(
                  CMTimeSubtract(audioEnd, commonPTS),
                  CMTime(value: 1, timescale: 4)
              ) >= 0 else { return false }
        let overlappingVideoCount = retainedVideo.filter { frame in
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
            completion?()
            return
        }
        normalStopInProgress = true
        normalStopPublishes = publish
        if let completion { stopCompletions.append(completion) }
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
        display.pauseSubmission()
        Task { [self] in
            await audio.stopAwaitingRendererRemoval()
            executor.submit { [self] in completeNormalStopIsolated() }
        }
    }

    private func completeNormalStopIsolated() {
        assertIsolated()
        guard normalStopInProgress, !normalStopCompleted else { return }
        normalStopInProgress = false
        normalStopCompleted = true
        display.clearDisplayCriteria()
        if normalStopPublishes { eventSink(.stopped) }
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion() }
    }

    private func failIsolated(_ error: PlaybackCoreError) {
        assertIsolated()
        guard !terminal else { return }
        terminal = true
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        videoCoordinator.stop(emergency: true)
        audio.stop()
        display.pauseSubmission()
        display.clearDisplayCriteria()
        eventSink(.failed(error))
    }

    private func releasePendingAdmissionIsolated() {
        assertIsolated()
        pendingPacketAdmission?.acknowledgement.signal()
        pendingPacketAdmission = nil
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
}

struct SystemPlaybackPipelineFactory: PlaybackPipelineFactory {
    func makePipeline(
        selectedAlgorithm: DeinterlaceAlgorithm,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) throws -> any PlaybackPipelineProtocol {
        let executor = PlaybackSerialExecutor()
        let demuxExecutor = PlaybackSerialExecutor(label: "org.vplayer.playback.demux.delivery")
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let clock = RenderSynchronizerClock(synchronizer: synchronizer)
        let relay = PlaybackPipelineRelay()
        let decoder = VideoToolboxDecoder(executor: executor) { relay.decoder($0) }
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
                clock: clock
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
            failureSink: { relay.failure($0, generation: $1) }
        )
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
            renderer: renderer,
            audio: audio,
            clock: clock,
            display: PhaseTwoPlaybackDisplay(),
            eventSink: eventSink
        )
        relay.install(pipeline)
        return pipeline
    }
}
