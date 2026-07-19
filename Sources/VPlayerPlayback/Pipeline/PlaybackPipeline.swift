// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
import Metal
import VideoToolbox

enum PlaybackPipelineEvent: Sendable, Equatable {
    case ready
    case stopped
    case failed(PlaybackCoreError)
}

protocol PlaybackPipelineProtocol: AnyObject, Sendable {
    func start(url: URL)
    func setPaused(_ paused: Bool)
    func stop()
}

protocol PlaybackPipelineFactory: Sendable {
    func makePipeline(
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
}

final class PlaybackPipeline: PlaybackPipelineProtocol, @unchecked Sendable {
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
    private let decoder: any VideoDecoding
    private let processor: any VideoFrameProcessing
    private let renderer: any PlaybackVideoRendering
    private let audio: any AudioRenderPipelineProtocol
    private let clock: any PlaybackClock
    private let display: any PlaybackDisplayControlling
    private let eventSink: @Sendable (PlaybackPipelineEvent) -> Void

    // Every property below is accessed exclusively from `executor`.
    private var generationController = GenerationController()
    private var observedFingerprint: MediaFormatFingerprint?
    private var readiness: PlaybackReadinessGate?
    private var tracks: DemuxTrackSet?
    private var formatState: AssemblyFormatState?
    private var videoAssembler: (any VideoAccessUnitAssembling)?
    private var audioAssembler: (any AudioSampleAssembling)?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var audioCodec: AudioCodec?
    private var decoderConfigured = false
    private var waitingForRandomAccess = true
    private var paused = false
    private var started = false
    private var terminal = false
    private var readyPublished = false
    private var deferredPackets: [DemuxPacket] = []
    private var pendingPacketAdmission: PendingPacketAdmission?
    private var retainedAudio: [CompressedAudioSample] = []
    private var retainedVideo: [VideoPresentationFrame] = []

    init(
        executor: PlaybackSerialExecutor,
        demuxer: any MediaDemuxing,
        assemblerBuilder: any PlaybackAssemblerBuilding,
        decoder: any VideoDecoding,
        processor: any VideoFrameProcessing,
        renderer: any PlaybackVideoRendering,
        audio: any AudioRenderPipelineProtocol,
        clock: any PlaybackClock,
        display: any PlaybackDisplayControlling,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) {
        self.executor = executor
        self.demuxer = demuxer
        self.assemblerBuilder = assemblerBuilder
        self.decoder = decoder
        self.processor = processor
        self.renderer = renderer
        self.audio = audio
        self.clock = clock
        self.display = display
        self.eventSink = eventSink
    }

    func start(url: URL) {
        executor.submit { [weak self] in self?.startIsolated(url: url) }
    }

    func setPaused(_ paused: Bool) {
        executor.submit { [weak self] in self?.setPausedIsolated(paused) }
    }

    func stop() {
        executor.submit { [weak self] in self?.stopIsolated(publish: true) }
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
                        isTerminal: true
                    ))
                    return
                }
                assertIsolated()
                continuation.resume(returning: PlaybackPipelineSnapshot(
                    generation: generationController.current,
                    hasTracks: tracks != nil,
                    isPaused: paused,
                    deferredPacketCount: deferredPackets.count,
                    isTerminal: terminal
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
        readiness = PlaybackReadinessGate(clock: clock) { [weak self] commonPTS in
            self?.prepareAnchorIsolated(commonPTS: commonPTS)
        }
        readiness?.configure(requiredVideoFrameCount: processor.requiredInputFrameCount)
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
                stopIsolated(publish: true)
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
        if discontinuity {
            try forceAdvanceGenerationIsolated()
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
                try observeFingerprintIsolated(fingerprint)
            case let .accessUnit(accessUnit):
                guard generationController.accepts(accessUnit.generation) else { return }
                if waitingForRandomAccess {
                    guard accessUnit.isRandomAccess else { return }
                    waitingForRandomAccess = false
                }
                try decoder.decode(accessUnit, flags: [])
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
                try observeFingerprintIsolated(fingerprint)
            case let .sample(sample):
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
        switch event {
        case let .frame(frame):
            guard generationController.accepts(frame.generation) else { return }
            processor.submit(frame) { [weak self] result in
                self?.submitOrRun { [weak self] in
                    self?.handleProcessedFrames(result, generation: frame.generation)
                }
            }
        case let .recoverableFailure(failure, generation),
             let .fatalFailure(failure, generation):
            guard generationController.accepts(generation) else { return }
            failIsolated(Self.coreError(for: failure))
        }
    }

    private func handleProcessedFrames(
        _ result: Result<[VideoPresentationFrame], PlaybackFailure>,
        generation: MediaGeneration
    ) {
        assertIsolated()
        guard !terminal, generationController.accepts(generation) else { return }
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

    private func observeFingerprintIsolated(_ fingerprint: MediaFormatFingerprint) throws {
        assertIsolated()
        guard observedFingerprint != fingerprint else { return }
        observedFingerprint = fingerprint
        let next = generationController.forceAdvance()
        try rebuildForGenerationIsolated(next)
    }

    private func forceAdvanceGenerationIsolated() throws {
        assertIsolated()
        let next = generationController.forceAdvance()
        try rebuildForGenerationIsolated(next)
    }

    private func rebuildForGenerationIsolated(_ generation: MediaGeneration) throws {
        assertIsolated()
        clock.pause()
        readiness?.close(.discontinuity)
        readyPublished = false
        waitingForRandomAccess = true

        if decoderConfigured {
            try decoder.finishDelayedFrames()
            try decoder.waitForAsynchronousFrames()
        }

        retainedAudio.removeAll(keepingCapacity: true)
        retainedVideo.removeAll(keepingCapacity: true)
        deferredPackets.removeAll(keepingCapacity: true)
        processor.reset(to: generation)
        renderer.flush(to: generation)
        audio.flush(to: generation)
        decoder.invalidate()
        decoderConfigured = false

        if let videoFormat {
            try decoder.configure(
                format: videoFormat,
                generation: generation,
                configuration: .bothFields
            )
            decoderConfigured = true
        }
        if let audioFormat, let audioCodec {
            try audio.configure(format: audioFormat, codec: audioCodec, generation: generation)
        }
    }

    private func setPausedIsolated(_ shouldPause: Bool) {
        assertIsolated()
        guard started, !terminal, paused != shouldPause else { return }
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
        guard !terminal, !paused, let readiness else { return }
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
        if let first = retainedVideo.first {
            readiness.updateVideo(
                firstPTS: first.presentationTimeStamp,
                readyFrameCount: retainedVideo.count
            )
        } else {
            readiness.updateVideo(firstPTS: .invalid, readyFrameCount: 0)
        }
        if !wasOpen, readiness.isOpen, !readyPublished {
            readyPublished = true
            display.resumeSubmission()
            eventSink(.ready)
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

    private func prepareAnchorIsolated(commonPTS: CMTime) {
        assertIsolated()
        guard !terminal else { return }
        retainedAudio.removeAll {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, commonPTS) <= 0
        }
        retainedVideo.removeAll {
            let end = CMTimeAdd($0.presentationTimeStamp, $0.duration)
            return end.isNumeric && CMTimeCompare(end, commonPTS) <= 0
        }

        audio.flush(to: generationController.current)
        for sample in retainedAudio {
            do {
                try audio.enqueue(sample)
            } catch let error as PlaybackCoreError {
                failIsolated(error)
                return
            } catch {
                failIsolated(.audioRendererFailed("audio.anchor"))
                return
            }
        }
        renderer.flush(to: generationController.current)
        for frame in retainedVideo { renderer.enqueue(frame) }
        renderer.resetPresentationTiming()
    }

    private func stopIsolated(publish: Bool) {
        assertIsolated()
        guard !terminal else { return }
        terminal = true
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        clock.pause()
        do {
            try videoAssembler?.drain()
            try audioAssembler?.drain()
            try decoder.finishDelayedFrames()
            try decoder.waitForAsynchronousFrames()
        } catch {
            // A user/EOS stop remains a stop even when draining malformed tail data fails.
        }
        decoder.invalidate()
        let generation = generationController.current
        processor.reset(to: generation)
        renderer.flush(to: generation)
        audio.flush(to: generation)
        audio.stop()
        readiness?.close(.flush)
        retainedAudio.removeAll(keepingCapacity: false)
        retainedVideo.removeAll(keepingCapacity: false)
        deferredPackets.removeAll(keepingCapacity: false)
        display.pauseSubmission()
        display.clearDisplayCriteria()
        if publish { eventSink(.stopped) }
    }

    private func failIsolated(_ error: PlaybackCoreError) {
        assertIsolated()
        guard !terminal else { return }
        terminal = true
        let generation = generationController.forceAdvance()
        demuxer.cancel()
        releasePendingAdmissionIsolated()
        deferredPackets.removeAll(keepingCapacity: false)
        retainedAudio.removeAll(keepingCapacity: false)
        retainedVideo.removeAll(keepingCapacity: false)
        clock.pause()
        readiness?.close(.flush)
        processor.reset(to: generation)
        renderer.flush(to: generation)
        audio.flush(to: generation)
        audio.stop()
        decoder.invalidate()
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
}

struct SystemPlaybackPipelineFactory: PlaybackPipelineFactory {
    func makePipeline(
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
        let renderer = try MetalVideoRenderer(
            device: device,
            generation: MediaGeneration(rawValue: 0),
            failureSink: { relay.failure($0, generation: $1) }
        )
        let audio = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { relay.failure($0, generation: $1) }
        )
        let pipeline = PlaybackPipeline(
            executor: executor,
            demuxer: FFmpegDemuxer(executor: demuxExecutor),
            assemblerBuilder: SystemPlaybackAssemblerBuilder(),
            decoder: decoder,
            processor: PassthroughVideoProcessor(),
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
