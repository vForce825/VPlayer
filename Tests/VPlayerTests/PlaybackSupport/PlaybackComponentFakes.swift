// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import VPlayerPlayback

final class FakeControllerPipeline: PlaybackPipelineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (PlaybackPipelineEvent) -> Void)?
    private(set) var starts: [URL] = []
    private(set) var pauses: [(Bool, UInt64)] = []
    private(set) var stopCount = 0
    private(set) var completedStopCount = 0
    private(set) var tunings: [PlaybackTuning] = []
    var stopAutomaticallyCompletes = true
    private var stopContinuation: CheckedContinuation<Void, Never>?
    let presentationContext: PlaybackPresentationContext?
    let metrics: PlaybackMetrics?

    init(
        presentationContext: PlaybackPresentationContext? = nil,
        metrics: PlaybackMetrics? = nil
    ) {
        self.presentationContext = presentationContext
        self.metrics = metrics
    }

    func install(_ sink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }

    func start(url: URL) {
        lock.withLock { starts.append(url) }
    }

    func setPaused(_ paused: Bool, readinessCycle: UInt64) {
        lock.withLock { pauses.append((paused, readinessCycle)) }
    }

    func setTuning(_ tuning: PlaybackTuning) {
        lock.withLock { tunings.append(tuning) }
    }

    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        metrics?.snapshot(window: window)
    }

    func stop() async {
        let shouldWait = lock.withLock { () -> Bool in
            stopCount += 1
            return !stopAutomaticallyCompletes
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.withLock { stopContinuation = continuation }
            }
        }
        lock.withLock { completedStopCount += 1 }
    }

    func completeStop() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { stopContinuation = nil }
            return stopContinuation
        }
        continuation?.resume()
    }

    func emit(_ event: PlaybackPipelineEvent) {
        let current = lock.withLock { sink }
        current?(event)
    }

    func snapshot() -> (
        starts: [URL],
        pauses: [(Bool, UInt64)],
        tunings: [PlaybackTuning],
        stopCount: Int,
        completedStopCount: Int,
        isStopWaiting: Bool
    ) {
        lock.withLock {
            (
                starts,
                pauses,
                tunings,
                stopCount,
                completedStopCount,
                stopContinuation != nil
            )
        }
    }
}

final class FakeControllerPipelineFactory: PlaybackPipelineFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FakeControllerPipeline]
    private var makeCount = 0
    private var requestedTunings: [PlaybackTuning] = []

    init(_ pipelines: [FakeControllerPipeline]) {
        queued = pipelines
    }

    func makePipeline(
        tuning: PlaybackTuning,
        channelID _: String,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackPipelineProtocol {
        try lock.withLock {
            guard !queued.isEmpty else { throw PlaybackCoreError.demuxOpen(-99) }
            makeCount += 1
            requestedTunings.append(tuning)
            let pipeline = queued.removeFirst()
            pipeline.install(eventSink)
            return pipeline
        }
    }

    var makeCountSnapshot: Int { lock.withLock { makeCount } }
    var requestedTuningsSnapshot: [PlaybackTuning] {
        lock.withLock { requestedTunings }
    }
}

final class FakePipelineDemuxer: MediaDemuxing, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (DemuxEvent) -> Void)?
    private(set) var startedURLs: [URL] = []
    private(set) var cancelCount = 0
    var startError: PlaybackCoreError?

    func start(url: URL, sink: @escaping @Sendable (DemuxEvent) -> Void) throws {
        if let startError { throw startError }
        lock.withLock {
            startedURLs.append(url)
            self.sink = sink
        }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func emit(_ event: DemuxEvent) {
        let current = lock.withLock { sink }
        current?(event)
    }

    func snapshot() -> (startedURLs: [URL], cancelCount: Int) {
        lock.withLock { (startedURLs, cancelCount) }
    }
}

final class FakePipelineVideoProcessor: VideoFrameProcessing, @unchecked Sendable {
    private struct PendingCompletion: @unchecked Sendable {
        let accessUnitID: UInt64
        let result: Result<[VideoPresentationFrame], PlaybackFailure>
        let completion: @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    }

    private let lock = NSLock()
    let requiredInputFrameCount: Int
    private(set) var resetGenerations: [MediaGeneration] = []
    private(set) var submittedMetadata: [VideoParserMetadata] = []
    private var automaticallyCompletes = true
    private var pendingCompletions: [PendingCompletion] = []

    init(requiredInputFrameCount: Int = 1) {
        self.requiredInputFrameCount = requiredInputFrameCount
    }

    func reset(to generation: MediaGeneration) {
        lock.withLock { resetGenerations.append(generation) }
    }

    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    ) {
        let result = Result<[VideoPresentationFrame], PlaybackFailure>.success([
            VideoPresentationFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                generation: frame.generation,
                sequenceNumber: frame.accessUnitID,
                sourceAccessUnitID: frame.accessUnitID,
                formatMetadata: frame.formatMetadata
            ),
        ])
        let shouldComplete = lock.withLock { () -> Bool in
            submittedMetadata.append(frame.parserMetadata)
            if !automaticallyCompletes {
                pendingCompletions.append(PendingCompletion(
                    accessUnitID: frame.accessUnitID,
                    result: result,
                    completion: completion
                ))
            }
            return automaticallyCompletes
        }
        if shouldComplete { completion(result) }
    }

    func setAutomaticallyCompletes(_ value: Bool) {
        lock.withLock { automaticallyCompletes = value }
    }

    func completePending() {
        let completions = lock.withLock { () -> [PendingCompletion] in
            defer { pendingCompletions.removeAll(keepingCapacity: false) }
            return pendingCompletions
        }
        for pending in completions { pending.completion(pending.result) }
    }

    func completePending(accessUnitIDs: Set<UInt64>) {
        let completions = lock.withLock { () -> [PendingCompletion] in
            var selected: [PendingCompletion] = []
            var retained: [PendingCompletion] = []
            for pending in pendingCompletions {
                if accessUnitIDs.contains(pending.accessUnitID) {
                    selected.append(pending)
                } else {
                    retained.append(pending)
                }
            }
            pendingCompletions = retained
            return selected
        }
        for pending in completions { pending.completion(pending.result) }
    }

    func completePending(
        accessUnitID: UInt64,
        with result: Result<[VideoPresentationFrame], PlaybackFailure>
    ) {
        let completion = lock.withLock { () -> PendingCompletion? in
            guard let index = pendingCompletions.firstIndex(where: {
                $0.accessUnitID == accessUnitID
            }) else { return nil }
            return pendingCompletions.remove(at: index)
        }
        completion?.completion(result)
    }

    var pendingAccessUnitIDs: [UInt64] {
        lock.withLock { pendingCompletions.map(\.accessUnitID) }
    }

    func snapshot() -> (resets: [MediaGeneration], metadata: [VideoParserMetadata]) {
        lock.withLock { (resetGenerations, submittedMetadata) }
    }
}

final class FakePipelineYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var resetGenerations: [MediaGeneration] = []
    private(set) var submittedOrders: [ResolvedFieldOrder] = []

    func reset(to generation: MediaGeneration) {
        lock.withLock { resetGenerations.append(generation) }
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        lock.withLock { submittedOrders.append(order) }
        completion(.success([
            VideoPresentationFrame(
                pixelBuffer: frame.frame.pixelBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.fieldDuration,
                generation: frame.frame.generation,
                sequenceNumber: frame.frame.accessUnitID,
                sourceAccessUnitID: frame.frame.accessUnitID,
                formatMetadata: frame.frame.formatMetadata
            ),
        ]))
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        completion(.success([]))
    }
}

final class FakePipelineVideoRenderer: PlaybackVideoRendering, @unchecked Sendable {
    private struct PendingReset {
        let request: VideoRendererResetRequest
        let completion: SystemVideoOutput.Acceptance
        var trailingFrames: [VideoPresentationFrame]
    }

    private let lock = NSLock()
    private(set) var frames: [VideoPresentationFrame] = []
    private(set) var flushes: [MediaGeneration] = []
    private(set) var resetCount = 0
    private var automaticallyCompletesResets = true
    private var pendingReset: PendingReset?

    func enqueue(_ frame: VideoPresentationFrame) {
        lock.withLock {
            if var pendingReset {
                pendingReset.trailingFrames.append(frame)
                self.pendingReset = pendingReset
            } else {
                frames.append(frame)
            }
        }
    }

    func flush(to generation: MediaGeneration) {
        lock.withLock {
            flushes.append(generation)
            frames.removeAll(keepingCapacity: true)
        }
    }

    func resetPresentationTiming() {
        lock.withLock { resetCount += 1 }
    }

    func reset(
        _ request: VideoRendererResetRequest,
        completion: @escaping SystemVideoOutput.Acceptance
    ) {
        let result: Result<VideoEnqueueReceipt, PlaybackCoreError>? = lock.withLock {
            if automaticallyCompletesResets {
                flushes.append(request.generation)
                frames.removeAll(keepingCapacity: true)
                frames.append(contentsOf: request.seedFrames)
                return .success(VideoEnqueueReceipt(
                    generation: request.generation,
                    sequenceNumbers: Set(request.seedFrames.map(\.sequenceNumber))
                ))
            }
            precondition(pendingReset == nil, "测试渲染器只允许一个未完成的重置")
            pendingReset = PendingReset(
                request: request,
                completion: completion,
                trailingFrames: []
            )
            return nil
        }
        if let result { completion(result) }
    }

    func setAutomaticallyCompletesResets(_ value: Bool) {
        lock.withLock { automaticallyCompletesResets = value }
    }

    var pendingResetRequest: VideoRendererResetRequest? {
        lock.withLock { pendingReset?.request }
    }

    func completePendingReset() {
        let pending: PendingReset? = lock.withLock {
            guard let pendingReset else { return nil }
            self.pendingReset = nil
            flushes.append(pendingReset.request.generation)
            frames.removeAll(keepingCapacity: true)
            frames.append(contentsOf: pendingReset.request.seedFrames)
            frames.append(contentsOf: pendingReset.trailingFrames)
            return pendingReset
        }
        guard let pending else { return }
        pending.completion(.success(VideoEnqueueReceipt(
            generation: pending.request.generation,
            sequenceNumbers: Set(pending.request.seedFrames.map(\.sequenceNumber))
        )))
    }

    func snapshot() -> (frames: [VideoPresentationFrame], flushes: [MediaGeneration], resets: Int) {
        lock.withLock { (frames, flushes, resetCount) }
    }
}

final class FakePipelineAudio: AudioRenderPipelineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var ready = false
    var selectedRoute = VPlayerPlayback.AudioRoute.systemCompressed
    private(set) var configured: [(
        VPlayerPlayback.AudioCodec,
        MediaGeneration,
        MediaFormatFingerprint,
        Data
    )] = []
    private(set) var samples: [CompressedAudioSample] = []
    private(set) var flushes: [MediaGeneration] = []
    private(set) var continuityIslandActivations: [(AudioContinuityIslandID, MediaGeneration)] = []
    private(set) var recoveryFloors: [CMTime?] = []
    private(set) var anchorPreparations: [(CMTime, AudioContinuityIslandID)] = []
    private(set) var stopCount = 0
    var stopAutomaticallyCompletes = true
    var enqueueError: PlaybackCoreError?
    var prepareAnchorError: PlaybackCoreError?
    private var flushHandler: (@Sendable (MediaGeneration) -> Void)?
    private var synchronousReadinessHandler: (@Sendable (MediaGeneration) -> Void)?
    private var synchronousReadinessOnFlush = false
    private var synchronousReadinessOnEnqueue = false
    private var synchronousReadinessOnPrepare = false
    private var synchronousReadinessMaximumCallbackCount = 0
    private var synchronousReadinessCallbackCount = 0
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    var isReadyForPlayback: Bool { lock.withLock { ready } }
    var route: VPlayerPlayback.AudioRoute { lock.withLock { selectedRoute } }

    func configure(
        _ configuration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration
    ) throws {
        lock.withLock {
            configured.append((
                configuration.codec,
                generation,
                configuration.fingerprint,
                configuration.decoderExtradata
            ))
        }
    }

    func enqueue(_ sample: CompressedAudioSample) throws {
        if let enqueueError { throw enqueueError }
        let readinessHandler = lock.withLock { () -> (@Sendable (MediaGeneration) -> Void)? in
            samples.append(sample)
            guard synchronousReadinessOnEnqueue,
                  synchronousReadinessCallbackCount
                      < synchronousReadinessMaximumCallbackCount,
                  let synchronousReadinessHandler else { return nil }
            synchronousReadinessCallbackCount += 1
            return synchronousReadinessHandler
        }
        readinessHandler?(sample.generation)
    }

    func activateContinuityIsland(
        _ islandID: AudioContinuityIslandID,
        generation: MediaGeneration
    ) {
        lock.withLock {
            continuityIslandActivations.append((islandID, generation))
            samples.removeAll(keepingCapacity: true)
        }
    }

    func updateRecoveryFloor(_ floor: CMTime?) {
        lock.withLock { recoveryFloors.append(floor) }
    }

    func prepareAnchor(
        at commonPTS: CMTime,
        in islandID: AudioContinuityIslandID
    ) throws {
        let result = lock.withLock { () -> (
            PlaybackCoreError?,
            (@Sendable (MediaGeneration) -> Void)?,
            MediaGeneration?
        ) in
            anchorPreparations.append((commonPTS, islandID))
            let readinessHandler: (@Sendable (MediaGeneration) -> Void)?
            if synchronousReadinessOnPrepare,
               synchronousReadinessCallbackCount
                    < synchronousReadinessMaximumCallbackCount,
               let synchronousReadinessHandler {
                synchronousReadinessCallbackCount += 1
                readinessHandler = synchronousReadinessHandler
            } else {
                readinessHandler = nil
            }
            return (prepareAnchorError, readinessHandler, configured.last?.1)
        }
        if let generation = result.2 { result.1?(generation) }
        if let error = result.0 { throw error }
    }

    func flush(to generation: MediaGeneration) {
        let handlers = lock.withLock {
            flushes.append(generation)
            samples.removeAll(keepingCapacity: true)
            let readinessHandler: (@Sendable (MediaGeneration) -> Void)?
            if synchronousReadinessOnFlush,
               synchronousReadinessCallbackCount
                   < synchronousReadinessMaximumCallbackCount,
               let synchronousReadinessHandler {
                synchronousReadinessCallbackCount += 1
                readinessHandler = synchronousReadinessHandler
            } else {
                readinessHandler = nil
            }
            return (flushHandler, readinessHandler)
        }
        handlers.0?(generation)
        handlers.1?(generation)
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }

    func stopAwaitingRendererRemoval() async {
        let shouldWait = lock.withLock { () -> Bool in
            stopCount += 1
            return !stopAutomaticallyCompletes
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.withLock { stopContinuations.append(continuation) }
            }
        }
    }

    func completeStop() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { stopContinuations.removeAll(keepingCapacity: false) }
            return stopContinuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func setReady(_ value: Bool) { lock.withLock { ready = value } }

    func setFlushHandler(_ handler: (@Sendable (MediaGeneration) -> Void)?) {
        lock.withLock { flushHandler = handler }
    }

    func setSynchronousReadinessCallback(
        onFlush: Bool = false,
        onEnqueue: Bool = false,
        onPrepare: Bool = false,
        maxCallbacks: Int = 1,
        _ handler: (@Sendable (MediaGeneration) -> Void)?
    ) {
        lock.withLock {
            synchronousReadinessOnFlush = onFlush
            synchronousReadinessOnEnqueue = onEnqueue
            synchronousReadinessOnPrepare = onPrepare
            synchronousReadinessMaximumCallbackCount = max(0, maxCallbacks)
            synchronousReadinessHandler = handler
            synchronousReadinessCallbackCount = 0
        }
    }

    var synchronousReadinessCallbackCountSnapshot: Int {
        lock.withLock { synchronousReadinessCallbackCount }
    }

    func snapshot() -> (
        configured: [(
            VPlayerPlayback.AudioCodec,
            MediaGeneration,
            MediaFormatFingerprint,
            Data
        )],
        samples: [CompressedAudioSample],
        flushes: [MediaGeneration],
        continuityIslandActivations: [(AudioContinuityIslandID, MediaGeneration)],
        recoveryFloors: [CMTime?],
        anchorPreparations: [(CMTime, AudioContinuityIslandID)],
        stops: Int,
        isStopWaiting: Bool
    ) {
        lock.withLock {
            (
                configured,
                samples,
                flushes,
                continuityIslandActivations,
                recoveryFloors,
                anchorPreparations,
                stopCount,
                !stopContinuations.isEmpty
            )
        }
    }
}

final class FakePipelineClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTime = CMTime.zero
    private(set) var pauses = 0
    private(set) var anchors: [(CMTime, CMTime, Float)] = []

    var currentTime: CMTime { lock.withLock { storedTime } }
    func pause() { lock.withLock { pauses += 1 } }
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        lock.withLock {
            storedTime = mediaTime
            anchors.append((mediaTime, hostTime, rate))
        }
    }
    func setTime(_ time: CMTime) { lock.withLock { storedTime = time } }
    func snapshot() -> (pauses: Int, anchors: [(CMTime, CMTime, Float)]) {
        lock.withLock { (pauses, anchors) }
    }
}

final class FakePlaybackDisplay: PlaybackDisplayControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var operations: [String] = []
    private var clearAutoCompletes = true
    private var clearContinuations: [CheckedContinuation<Void, Never>] = []
    var clearAutomaticallyCompletes: Bool {
        get { lock.withLock { clearAutoCompletes } }
        set { lock.withLock { clearAutoCompletes = newValue } }
    }
    var isClearWaiting: Bool { lock.withLock { !clearContinuations.isEmpty } }
    func pauseSubmission() { lock.withLock { operations.append("pause") } }
    func resumeSubmission() { lock.withLock { operations.append("resume") } }
    func resetPresentationTiming() { lock.withLock { operations.append("reset") } }
    func updateDisplayCriteria(
        formatDescription _: CMFormatDescription,
        outputFrameRate: Float
    ) { lock.withLock { operations.append("criteria:\(outputFrameRate)") } }
    func clearDisplayCriteria() async {
        let shouldWait = lock.withLock {
            operations.append("clear")
            return !clearAutoCompletes
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !clearAutoCompletes else { return true }
                clearContinuations.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func completeClear() {
        let continuations = lock.withLock {
            clearAutoCompletes = true
            let pending = clearContinuations
            clearContinuations.removeAll()
            return pending
        }
        for continuation in continuations { continuation.resume() }
    }
    func snapshot() -> [String] { lock.withLock { operations } }
}

final class FakePlaybackAssemblerBuilder: PlaybackAssemblerBuilding, @unchecked Sendable {
    final class Video: VideoAccessUnitAssembling {
        private(set) var packets: [DemuxPacket] = []
        private(set) var resetTracks: [DemuxTrackSet] = []
        var pushError: PlaybackCoreError?
        var drainError: PlaybackCoreError?
        private(set) var drainCount = 0
        func push(_ packet: DemuxPacket) throws {
            if let pushError { throw pushError }
            packets.append(packet)
        }
        func drain() throws {
            drainCount += 1
            if let drainError { throw drainError }
        }
        func reset(for trackSet: DemuxTrackSet) throws { resetTracks.append(trackSet) }
    }

    final class Audio: AudioSampleAssembling {
        private(set) var packets: [DemuxPacket] = []
        private(set) var resetTracks: [DemuxTrackSet] = []
        var pushError: PlaybackCoreError?
        var drainError: PlaybackCoreError?
        private(set) var drainCount = 0
        func push(_ packet: DemuxPacket) throws {
            if let pushError { throw pushError }
            packets.append(packet)
        }
        func drain() throws {
            drainCount += 1
            if let drainError { throw drainError }
        }
        func reset(for trackSet: DemuxTrackSet) throws { resetTracks.append(trackSet) }
    }

    let video = Video()
    let audio = Audio()

    func makeVideo(
        trackSet _: DemuxTrackSet,
        generationProvider _: @escaping @Sendable () -> MediaGeneration,
        eventSink _: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState _: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling { video }

    func makeAudio(
        trackSet _: DemuxTrackSet,
        generationProvider _: @escaping @Sendable () -> MediaGeneration,
        eventSink _: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState _: AssemblyFormatState
    ) throws -> any AudioSampleAssembling { audio }
}

final class AssemblerBackedPlaybackBuilder: PlaybackAssemblerBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var formatFingerprints: [MediaFormatFingerprint] = []

    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling {
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            var sps = AssemblerTestFixtures.h264SPS
            if bytes.first == 2 { sps[3] = 0x20 }
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: AssemblerTestFixtures.h264AccessUnit(sps: sps),
                pts: pts,
                dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                keyFrame: true
            ))
        }
        return try CompressedVideoAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: { [weak self] event in
                if case let .format(_, fingerprint) = event {
                    self?.lock.withLock { self?.formatFingerprints.append(fingerprint) }
                }
                eventSink(event)
            },
            parserFactory: parserFactory,
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
            eventSink: { [weak self] event in
                if case let .format(configuration) = event {
                    self?.lock.withLock {
                        self?.formatFingerprints.append(configuration.fingerprint)
                    }
                }
                eventSink(event)
            },
            formatState: formatState
        )
    }

    var formatFingerprintsSnapshot: [MediaFormatFingerprint] {
        lock.withLock { formatFingerprints }
    }
}

enum PlaybackFakeMedia {
    static func tracks(
        videoExtradata: Data = Data(),
        audioExtradata: Data = Data([0x12, 0x10]),
        videoFrameRate: MediaRational? = nil
    ) -> DemuxTrackSet {
        DemuxTrackSet(
            selectedProgramID: 1,
            video: VideoTrackDescriptor(
                streamIndex: 100,
                codec: .h264,
                timeBase: MediaRational(num: 1, den: 90_000)!,
                width: 1_920,
                height: 1_080,
                videoDelay: 0,
                extradata: videoExtradata,
                frameRate: videoFrameRate
            ),
            audio: AudioTrackDescriptor(
                streamIndex: 101,
                codec: .aac,
                timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000,
                channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                extradata: audioExtradata
            )
        )
    }

    static func audioOnlyTracks(
        audioExtradata: Data = Data([0x12, 0x10])
    ) -> DemuxTrackSet {
        DemuxTrackSet(
            selectedProgramID: 1,
            video: nil,
            audio: AudioTrackDescriptor(
                streamIndex: 101,
                codec: .aac,
                timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000,
                channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                extradata: audioExtradata
            )
        )
    }

    static func videoFormat() throws -> CMVideoFormatDescription {
        var value: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.videoFormatDescription(status) }
        return value
    }

    static func audioFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var value: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.audioFormatDescription(status) }
        return value
    }

    static func audioConfiguration(
        fingerprint: MediaFormatFingerprint,
        decoderExtradata: Data = Data([0x12, 0x10])
    ) throws -> CompressedAudioRenderConfiguration {
        CompressedAudioRenderConfiguration(
            formatDescription: try audioFormat(),
            codec: .aac,
            decoderExtradata: decoderExtradata,
            fingerprint: fingerprint
        )
    }

    static func audioSystemFingerprintComponent(
        magicCookie: Data? = Data()
    ) -> AudioSystemFormatFingerprintComponent {
        AudioSystemFormatFingerprintComponent(
            profileID: .aacLC,
            formatID: kAudioFormatMPEG4AAC,
            sampleRate: 48_000,
            channelCount: 2,
            framesPerPacket: 1_024,
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: magicCookie
        )
    }

    static func audioFrame(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        duration: CMTime
    ) -> CompressedAudioFrame {
        return CompressedAudioFrame(
            id: id,
            payload: Data([UInt8(truncatingIfNeeded: id), 0xA5]),
            codec: .aac,
            generation: generation,
            presentationTimeStamp: pts,
            duration: duration,
            frameSampleCount: 1_024
        )
    }

    static func videoPacket(
        marker: UInt8,
        pts: Int64 = 90_000,
        isCorrupt: Bool = false
    ) -> DemuxPacket {
        DemuxPacket(
            streamIndex: 100,
            codec: .video(.h264),
            data: Data([marker]),
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            decodeTimeStamp: CMTime(value: pts - 3_000, timescale: 90_000),
            duration: CMTime(value: 3_000, timescale: 90_000),
            isKey: true,
            isCorrupt: isCorrupt
        )
    }

    static func audioPacket(id: UInt8, isCorrupt: Bool = false) -> DemuxPacket {
        let payload = Data([id, 0xAA])
        let frameLength = 7 + payload.count
        var data = Data([
            0xFF, 0xF1, 0x4C,
            UInt8(0x80 | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
        data.append(payload)
        return DemuxPacket(
            streamIndex: 101,
            codec: .audio(.aac),
            data: data,
            presentationTimeStamp: CMTime(value: Int64(id) * 1_920, timescale: 90_000),
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: isCorrupt
        )
    }

    static func accessUnit(
        id: UInt64,
        generation: MediaGeneration,
        randomAccess: Bool,
        pts: CMTime? = nil,
        duration: CMTime? = nil
    ) throws -> CompressedVideoAccessUnit {
        let format = try videoFormat()
        let buffer = try SampleBufferBuilder.makeVideo(
            data: Data([0x00, 0x00, 0x00, 0x01]),
            formatDescription: format,
            presentationTimeStamp: pts ?? CMTime(value: Int64(id), timescale: 25),
            decodeTimeStamp: .invalid,
            duration: duration ?? CMTime(value: 1, timescale: 25),
            isRandomAccess: randomAccess
        )
        return CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: buffer,
            generation: generation,
            isRandomAccess: randomAccess,
            parserMetadata: parserMetadata(interlaced: false)
        )
    }

    static func decodedFrame(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        interlaced: Bool,
        duration: CMTime = CMTime(value: 1, timescale: 25),
        pictureStructure: PictureStructure = .frame,
        dimensions: CMVideoDimensions = CMVideoDimensions(width: 16, height: 16),
        bitDepth: Int = 8
    ) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PlaybackCoreError.videoDecode(status)
        }
        let sourcePTS90k = pts.isNumeric
            ? UInt64(max(
                0,
                CMTimeConvertScale(pts, timescale: 90_000, method: .default).value
            ))
            : nil
        return DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            generation: generation,
            parserMetadata: VideoParserMetadata(
                fieldOrder: interlaced ? .tb : .progressive,
                pictureStructure: pictureStructure,
                isInterlaced: interlaced,
                repeatFirstField: false,
                topFieldFirst: interlaced,
                sourcePTS90k: sourcePTS90k
            ),
            formatMetadata: VideoFormatMetadata(
                dimensions: dimensions,
                bitDepth: bitDepth,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(masteringDisplayColorVolume: nil, contentLightLevelInfo: nil)
            )
        )
    }

    static func parserMetadata(interlaced: Bool) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: interlaced ? .tb : .progressive,
            pictureStructure: .frame,
            isInterlaced: interlaced,
            repeatFirstField: false,
            topFieldFirst: interlaced,
            sourcePTS90k: nil
        )
    }
}
