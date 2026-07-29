// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation

private final class AudioReadyCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func claim() -> Bool {
        lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
    }

    func release() {
        lock.withLock { pending = false }
    }
}

final class AudioRenderPipeline: AudioRenderPipelineProtocol, @unchecked Sendable {
    private typealias StopCompletion = @Sendable () -> Void

    static let removalFailedError = "audio.renderer.remove"
    static let unsupportedPCMError = "audio.pcm.unsupported"
    static let isolationError = "audio.executor.isolation"
    private static let capacity = 96
    private static let compressedStartupFallbackDuration = CMTime(value: 3, timescale: 4)
    private static let pcmStartupPrerollDuration = CMTime(value: 1, timescale: 4)
    // Packet duration follows the codec clock while its PTS may be rounded to
    // the container clock. A tiny tolerance joins that representation residue,
    // but remains far below one AAC/AC-3 packet and cannot conceal a real gap.
    private static let audioContinuityTolerance = CMTime(value: 1, timescale: 1_000)
    private static let maximumConsecutiveInvalidPackets = 8

    private struct PublicSnapshot {
        var isReadyForPlayback = false
        var route = AudioRoute.systemCompressed
        var recoveryCount: UInt64 = 0
    }

    private struct ReplayEntry {
        let sample: CompressedAudioSample
        var sentCompressed: Bool
        var decoded: Bool
    }

    private struct PendingRecovery {
        var time: CMTime
        var requiresSupportCheck: Bool
        var output: AudioOutputCategory
    }

    private enum RemovalContinuation: Sendable {
        case configure
        case fallback
        case stop
    }

    private struct PendingRemoval: Sendable {
        let rendererID: AudioRendererIdentity
        let originEpoch: UInt64
        let originGeneration: MediaGeneration
        var targetEpoch: UInt64
        var targetGeneration: MediaGeneration
        var continuation: RemovalContinuation
    }

    private let executor: PlaybackSerialExecutor
    private let synchronizer: any AudioRenderSynchronizing
    private let failureSink: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    private let rendererFactory: any AudioRendererFactory
    private let decoderFactory: any PCMAudioDecoderFactory
    private let routeMonitor: any AudioRouteMonitoring
    private let supportChecker: any AudioFormatSupportChecking
    private let clockMode: AudioClockMode
    private let readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)?
    private let snapshotLock = NSLock()
    private let readyCallbackGate = AudioReadyCallbackGate()
    private var publicSnapshot = PublicSnapshot()

    private var nextEpoch: UInt64? = 1
    private var epoch: UInt64 = 0
    private var generation = MediaGeneration(rawValue: 0)
    private var format: CMAudioFormatDescription?
    private var pcmOutputFormat: CMAudioFormatDescription?
    private var codec: AudioCodec?
    private var renderer: (any AudioRenderer)?
    private var decoder: (any PCMAudioDecoding)?
    private var replay: [ReplayEntry] = []
    private var pendingPCM: [CMSampleBuffer] = []
    private var pcmPrerollStart: CMTime?
    private var pcmPrerollEnd: CMTime?
    private var consecutiveInvalidPacketCount = 0
    private var rendererAttached = false
    private var rendererRequesting = false
    private var startupPrerollSatisfied = false
    private var replacing = false
    private var terminal = false
    private var configured = false
    private var stopped = true
    private var fallbackUsed = false
    private var needsAnchor = false
    private var pendingReevaluation = false
    private var recoveryScheduled = false
    private var pendingRecovery: PendingRecovery?
    private var pendingRemoval: PendingRemoval?
    private var stopCompletions: [StopCompletion] = []
    private var currentOutput = AudioOutputCategory.other

    convenience init(
        synchronizer: AVSampleBufferRenderSynchronizer,
        executor: PlaybackSerialExecutor,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void,
        clockMode: AudioClockMode = .standalone,
        readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)? = nil
    ) {
        self.init(
            synchronizer: SystemAudioSynchronizer(synchronizer),
            executor: executor,
            failureSink: failureSink,
            rendererFactory: SystemAudioRendererFactory(),
            decoderFactory: LivePCMAudioDecoderFactory(),
            routeMonitor: AudioOutputRouteMonitor(executor: executor),
            supportChecker: SystemAudioFormatSupportChecker(),
            clockMode: clockMode,
            readinessSink: readinessSink
        )
    }

    init(
        synchronizer: any AudioRenderSynchronizing,
        executor: PlaybackSerialExecutor,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void,
        rendererFactory: any AudioRendererFactory,
        decoderFactory: any PCMAudioDecoderFactory,
        routeMonitor: any AudioRouteMonitoring,
        supportChecker: any AudioFormatSupportChecking,
        clockMode: AudioClockMode = .standalone,
        readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)? = nil
    ) {
        self.synchronizer = synchronizer
        self.executor = executor
        self.failureSink = failureSink
        self.rendererFactory = rendererFactory
        self.decoderFactory = decoderFactory
        self.routeMonitor = routeMonitor
        self.supportChecker = supportChecker
        self.clockMode = clockMode
        self.readinessSink = readinessSink
    }

    var isReadyForPlayback: Bool {
        withSnapshot { $0.isReadyForPlayback }
    }

    var recoveryCount: UInt64 {
        withSnapshot { $0.recoveryCount }
    }

    var route: AudioRoute {
        withSnapshot { $0.route }
    }

    func configure(
        format: CMAudioFormatDescription,
        codec: AudioCodec,
        generation: MediaGeneration
    ) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        let newEpoch = try takeEpoch()
        prepareConfiguration(
            format: format,
            codec: codec,
            generation: generation,
            epoch: newEpoch
        )

        if var pendingRemoval {
            pendingRemoval.targetEpoch = newEpoch
            pendingRemoval.targetGeneration = generation
            pendingRemoval.continuation = .configure
            self.pendingRemoval = pendingRemoval
            return
        }
        if let renderer {
            beginRemoval(of: renderer, continuation: .configure)
            return
        }
        try activateCompressedRenderer()
    }

    func enqueue(_ sample: CompressedAudioSample) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        guard configured, !stopped, !terminal else { return }
        guard sample.generation == generation else { return }
        guard sample.codec == codec else {
            throw PlaybackCoreError.audioRendererFailed("audio.codec.mismatch")
        }
        try pruneExpired(at: synchronizer.currentTime())
        if replay.count >= Self.capacity {
            replay.removeFirst(replay.count - Self.capacity + 1)
        }
        replay.append(ReplayEntry(sample: sample, sentCompressed: false, decoded: false))
        do {
            if !replacing, rendererAttached, let renderer {
                startRequests(on: renderer, epoch: epoch, generation: generation)
            }
            if route == .systemCompressed {
                try drainCompressedAndEvaluateStartup()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
        } catch {
            classifyAndEmitDecode(error)
        }
        refreshMediaRequestState()
        updateReadiness()
    }

    func flush(to generation: MediaGeneration) {
        guard executor.isIsolated else {
            executor.submit { [weak self] in self?.flush(to: generation) }
            return
        }
        guard configured, !stopped else { return }
        guard let newEpoch = takeEpochWithoutThrow() else { return }
        epoch = newEpoch
        self.generation = generation
        terminal = false
        pendingReevaluation = false
        recoveryScheduled = false
        pendingRecovery = nil
        needsAnchor = false
        updateSnapshot(route: route, ready: false)
        setSynchronizerRate(0, time: synchronizer.currentTime())
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        resetPCMPreroll()
        consecutiveInvalidPacketCount = 0
        decoder?.flush()

        if var pendingRemoval {
            pendingRemoval.targetEpoch = newEpoch
            pendingRemoval.targetGeneration = generation
            self.pendingRemoval = pendingRemoval
            replacing = true
            switch pendingRemoval.continuation {
            case .configure, .stop:
                routeMonitor.stop()
            case .fallback:
                startRouteMonitor(epoch: newEpoch, generation: generation)
            }
            updateReadiness()
            return
        }

        replacing = false
        if let renderer { stopRequests(on: renderer) }
        renderer?.stopObserving()
        renderer?.flush()
        if let renderer {
            installCallbacks(on: renderer, epoch: newEpoch, generation: generation)
            startRequests(on: renderer, epoch: newEpoch, generation: generation)
        }
        startRouteMonitor(epoch: newEpoch, generation: generation)
        updateReadiness()
    }

    func stop() {
        requestStop(completion: nil)
    }

    func stopAwaitingRendererRemoval() async {
        await withCheckedContinuation { continuation in
            requestStop {
                continuation.resume()
            }
        }
    }

    private func requestStop(completion: StopCompletion?) {
        guard executor.isIsolated else {
            executor.submit { [self] in stopIsolated(completion: completion) }
            return
        }
        stopIsolated(completion: completion)
    }

    private func stopIsolated(completion: StopCompletion?) {
        if let completion {
            if stopped, pendingRemoval == nil {
                completion()
                return
            }
            stopCompletions.append(completion)
        }
        guard !stopped else { return }
        if let newEpoch = takeEpochWithoutThrow() { epoch = newEpoch }
        stopped = true
        configured = false
        replacing = false
        terminal = false
        pendingReevaluation = false
        recoveryScheduled = false
        pendingRecovery = nil
        routeMonitor.stop()
        let now = synchronizer.currentTime()
        setSynchronizerRate(0, time: now)
        if var pendingRemoval {
            pendingRemoval.targetEpoch = epoch
            pendingRemoval.targetGeneration = generation
            pendingRemoval.continuation = .stop
            self.pendingRemoval = pendingRemoval
            replacing = true
        } else if let renderer {
            beginRemoval(of: renderer, continuation: .stop)
        } else {
            replacing = false
            completeStopCompletions()
        }
        decoder?.destroy()
        decoder = nil
        pcmOutputFormat = nil
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        resetPCMPreroll()
        consecutiveInvalidPacketCount = 0
        updateSnapshot(route: route, ready: false)
    }

    private func completeStopCompletions() {
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion() }
    }

    private func takeEpoch() throws -> UInt64 {
        guard let value = takeEpochWithoutThrow() else {
            throw PlaybackCoreError.audioRendererFailed("audio.epoch.exhausted")
        }
        return value
    }

    private func takeEpochWithoutThrow() -> UInt64? {
        guard let value = nextEpoch else {
            emitTerminal(.audioRendererFailed("audio.epoch.exhausted"))
            return nil
        }
        nextEpoch = value == UInt64.max ? nil : value + 1
        return value
    }

    private func prepareConfiguration(
        format: CMAudioFormatDescription,
        codec: AudioCodec,
        generation: MediaGeneration,
        epoch: UInt64
    ) {
        routeMonitor.stop()
        decoder?.destroy()
        decoder = nil
        pcmOutputFormat = nil
        self.epoch = epoch
        self.generation = generation
        self.format = format
        self.codec = codec
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        resetPCMPreroll()
        consecutiveInvalidPacketCount = 0
        configured = true
        stopped = false
        fallbackUsed = false
        replacing = renderer != nil
        terminal = false
        needsAnchor = false
        pendingReevaluation = false
        recoveryScheduled = false
        pendingRecovery = nil
        currentOutput = .other
        updateSnapshot(route: .systemCompressed, ready: false)
    }

    private func activateCompressedRenderer() throws {
        let candidate = try rendererFactory.makeRenderer(mediaKind: .compressed)
        renderer = candidate
        rendererAttached = false
        installCallbacks(on: candidate, epoch: epoch, generation: generation)
        synchronizer.attach(candidate)
        rendererAttached = true
        replacing = false
        startRequests(on: candidate, epoch: epoch, generation: generation)
        startRouteMonitor(epoch: epoch, generation: generation)
        updateReadiness()
    }

    private func installCallbacks(
        on renderer: any AudioRenderer,
        epoch: UInt64,
        generation: MediaGeneration
    ) {
        let rendererID = renderer.identity
        renderer.startObserving { [weak self] event in
            guard let self else { return }
            executor.submit { [weak self] in
                self?.handle(
                    event: event,
                    epoch: epoch,
                    rendererID: rendererID,
                    generation: generation
                )
            }
        }
    }

    private func startRequests(
        on renderer: any AudioRenderer,
        epoch: UInt64,
        generation: MediaGeneration
    ) {
        guard !rendererRequesting else { return }
        rendererRequesting = true
        let rendererID = renderer.identity
        let gate = readyCallbackGate
        renderer.requestMediaDataWhenReady { [weak self, gate] in
            guard gate.claim() else { return }
            guard let self else {
                gate.release()
                return
            }
            executor.submit { [weak self, gate] in
                defer { gate.release() }
                self?.handleReady(
                    epoch: epoch,
                    rendererID: rendererID,
                    generation: generation
                )
            }
        }
    }

    private func stopRequests(on renderer: any AudioRenderer) {
        guard rendererRequesting else { return }
        rendererRequesting = false
        renderer.stopRequestingMediaData()
    }

    private func startRouteMonitor(epoch: UInt64, generation: MediaGeneration) {
        routeMonitor.stop()
        routeMonitor.start { [weak self] output in
            guard let self else { return }
            if executor.isIsolated {
                handleRoute(output, epoch: epoch, generation: generation)
            } else {
                executor.submit { [weak self] in
                    self?.handleRoute(output, epoch: epoch, generation: generation)
                }
            }
        }
    }

    private func handleReady(
        epoch: UInt64,
        rendererID: AudioRendererIdentity,
        generation: MediaGeneration
    ) {
        guard isCurrent(epoch: epoch, rendererID: rendererID, generation: generation),
              rendererRequesting, !terminal, !replacing else { return }
        do {
            if route == .systemCompressed {
                try drainCompressedAndEvaluateStartup()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
            updateReadiness()
        } catch {
            classifyAndEmitDecode(error)
        }
        refreshMediaRequestState()
    }

    private func refreshMediaRequestState() {
        guard configured, !stopped, !terminal, !replacing,
              rendererAttached, let renderer else { return }
        let hasPendingWork: Bool
        switch route {
        case .systemCompressed:
            hasPendingWork = replay.contains { !$0.sentCompressed }
        case .ffmpegPCM:
            hasPendingWork = !pendingPCM.isEmpty || replay.contains { !$0.decoded }
        }
        if hasPendingWork {
            startRequests(on: renderer, epoch: epoch, generation: generation)
        } else {
            stopRequests(on: renderer)
        }
    }

    private func handle(
        event: AudioRendererEvent,
        epoch: UInt64,
        rendererID: AudioRendererIdentity,
        generation: MediaGeneration
    ) {
        guard isCurrent(epoch: epoch, rendererID: rendererID, generation: generation),
              !terminal else { return }
        switch event {
        case let .failed(reason):
            if replacing { return }
            if route == .systemCompressed && !fallbackUsed {
                beginFallback()
            } else {
                emitTerminal(.audioRendererFailed(reason))
            }
        case let .automaticFlush(copiedTime):
            if replacing {
                pendingReevaluation = true
                return
            }
            let recoveryTime = copiedTime?.isNumeric == true
                ? copiedTime ?? synchronizer.currentTime()
                : synchronizer.currentTime()
            scheduleRecovery(
                at: recoveryTime,
                requiresSupportCheck: false,
                output: currentOutput
            )
        case .outputConfigurationChanged:
            scheduleRecovery(
                at: synchronizer.currentTime(),
                requiresSupportCheck: true,
                output: currentOutput
            )
        }
    }

    private func handleRoute(
        _ output: AudioOutputCategory,
        epoch: UInt64,
        generation: MediaGeneration
    ) {
        guard self.epoch == epoch, self.generation == generation,
              configured, !stopped, !terminal else { return }
        currentOutput = output
        scheduleRecovery(
            at: synchronizer.currentTime(),
            requiresSupportCheck: true,
            output: output
        )
    }

    private func scheduleRecovery(
        at time: CMTime,
        requiresSupportCheck: Bool,
        output: AudioOutputCategory
    ) {
        guard !terminal else { return }
        if replacing {
            pendingReevaluation = true
            return
        }
        if var pendingRecovery {
            if requiresSupportCheck {
                pendingRecovery.time = time
                pendingRecovery.output = output
            }
            pendingRecovery.requiresSupportCheck =
                pendingRecovery.requiresSupportCheck || requiresSupportCheck
            self.pendingRecovery = pendingRecovery
        } else {
            pendingRecovery = PendingRecovery(
                time: time,
                requiresSupportCheck: requiresSupportCheck,
                output: output
            )
        }
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        let scheduledEpoch = epoch
        let scheduledGeneration = generation
        executor.submit { [weak self] in
            self?.performScheduledRecovery(
                epoch: scheduledEpoch,
                generation: scheduledGeneration
            )
        }
    }

    private func performScheduledRecovery(epoch: UInt64, generation: MediaGeneration) {
        guard self.epoch == epoch, self.generation == generation,
              configured, !stopped, !terminal else {
            recoveryScheduled = false
            pendingRecovery = nil
            return
        }
        recoveryScheduled = false
        guard let recovery = pendingRecovery else { return }
        pendingRecovery = nil
        guard !replacing, pendingRemoval == nil else {
            pendingReevaluation = true
            return
        }
        if !recovery.requiresSupportCheck {
            recover(at: recovery.time)
            return
        }
        let supportFormat: CMAudioFormatDescription?
        switch route {
        case .systemCompressed:
            supportFormat = format
        case .ffmpegPCM:
            supportFormat = pcmOutputFormat
        }
        guard let supportFormat else {
            recover(at: recovery.time)
            return
        }
        if !supportChecker.supports(
            format: supportFormat,
            route: route,
            output: recovery.output
        ) {
            if route == .systemCompressed && !fallbackUsed {
                beginFallback()
            } else {
                emitTerminal(.audioRendererFailed(Self.unsupportedPCMError))
            }
            return
        }
        recover(at: recovery.time)
    }

    private func recover(at time: CMTime) {
        guard !terminal, !replacing, let renderer else { return }
        snapshotLock.lock()
        publicSnapshot.recoveryCount &+= 1
        snapshotLock.unlock()
        // Deliberately no `ready: false` here. Recovery keeps the *same* renderer
        // and refills it from `replay` before this method returns, all on the one
        // playback executor, so no observer can see the empty window. Publishing
        // an invalidation for it made a routine renderer automatic flush tear
        // down the video anchor and stop display submission.
        setSynchronizerRate(0, time: time)
        renderer.flush()
        resetPCMPreroll()
        do {
            try pruneExpired(at: time)
            for index in replay.indices {
                replay[index].sentCompressed = false
                replay[index].decoded = false
            }
            pendingPCM.removeAll(keepingCapacity: false)
            if route == .ffmpegPCM {
                consecutiveInvalidPacketCount = 0
                decoder?.flush()
            }
            needsAnchor = true
            if route == .systemCompressed {
                try drainCompressedAndEvaluateStartup()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
            updateReadiness()
        } catch {
            classifyAndEmitDecode(error)
        }
    }

    private func beginFallback() {
        guard !fallbackUsed, !replacing, !terminal,
              pendingRemoval == nil, let renderer,
              format != nil, codec != nil else { return }
        fallbackUsed = true
        beginRemoval(of: renderer, continuation: .fallback)
    }

    private func beginRemoval(
        of renderer: any AudioRenderer,
        continuation: RemovalContinuation
    ) {
        guard pendingRemoval == nil else { return }
        replacing = true
        updateSnapshot(route: route, ready: false)
        setSynchronizerRate(0, time: synchronizer.currentTime())
        stopRequests(on: renderer)
        renderer.stopObserving()
        renderer.flush()
        resetPCMPreroll()
        let transition = PendingRemoval(
            rendererID: renderer.identity,
            originEpoch: epoch,
            originGeneration: generation,
            targetEpoch: epoch,
            targetGeneration: generation,
            continuation: continuation
        )
        pendingRemoval = transition
        synchronizer.remove(renderer, at: .invalid) { [self] didRemove in
            executor.submit { [self] in
                completeRemoval(
                    didRemove: didRemove,
                    rendererID: transition.rendererID,
                    originEpoch: transition.originEpoch,
                    originGeneration: transition.originGeneration
                )
            }
        }
    }

    private func completeRemoval(
        didRemove: Bool,
        rendererID: AudioRendererIdentity,
        originEpoch: UInt64,
        originGeneration: MediaGeneration
    ) {
        guard let transition = pendingRemoval,
              transition.rendererID == rendererID,
              transition.originEpoch == originEpoch,
              transition.originGeneration == originGeneration,
              transition.targetEpoch == epoch,
              transition.targetGeneration == generation,
              renderer?.identity == rendererID,
              replacing, !terminal else { return }
        switch transition.continuation {
        case .configure, .fallback:
            guard configured, !stopped else { return }
        case .stop:
            guard stopped, !configured else { return }
        }
        pendingRemoval = nil
        completeStopCompletions()
        guard didRemove else {
            if transition.continuation == .stop {
                replacing = false
                updateReadiness()
            } else {
                emitTerminal(.audioRendererFailed(Self.removalFailedError))
            }
            return
        }
        renderer = nil
        rendererAttached = false
        switch transition.continuation {
        case .configure:
            do {
                try activateCompressedRenderer()
            } catch {
                classifyAndEmitDecode(error)
            }
        case .fallback:
            completeFallbackAfterRemoval()
        case .stop:
            replacing = false
            updateReadiness()
        }
    }

    private func completeFallbackAfterRemoval() {
        guard configured, !stopped, replacing, !terminal,
              let format, let codec else { return }
        do {
            let decoder = try decoderFactory.makeDecoder(codec: codec, format: format)
            let replacement = try rendererFactory.makeRenderer(mediaKind: .linearPCM)
            self.decoder = decoder
            consecutiveInvalidPacketCount = 0
            renderer = replacement
            rendererAttached = false
            resetPCMPreroll()
            installCallbacks(on: replacement, epoch: epoch, generation: generation)
            synchronizer.attach(replacement)
            rendererAttached = true
            updateSnapshot(route: .ffmpegPCM, ready: false)
            replacing = false
            needsAnchor = true
            startRequests(on: replacement, epoch: epoch, generation: generation)
            try pruneExpired(at: synchronizer.currentTime())
            for index in replay.indices { replay[index].decoded = false }
            try decodeAvailable()
            try drainPCM()
            refreshMediaRequestState()
            updateReadiness()
            if pendingReevaluation {
                pendingReevaluation = false
                scheduleRecovery(
                    at: synchronizer.currentTime(),
                    requiresSupportCheck: true,
                    output: currentOutput
                )
            }
        } catch {
            classifyAndEmitDecode(error)
        }
    }

    private func drainCompressed() throws {
        guard route == .systemCompressed,
              let renderer,
              renderer.mediaKind == .compressed,
              rendererAttached, !replacing, !terminal else { return }
        while renderer.isReadyForMoreMediaData,
              let index = replay.firstIndex(where: { !$0.sentCompressed }) {
            let sample = replay[index].sample
            try renderer.enqueue(sample.sampleBuffer)
            replay[index].sentCompressed = true
            anchorIfNeeded(at: sample.presentationTimeStamp)
        }
    }

    private func drainCompressedAndEvaluateStartup() throws {
        try drainCompressed()
        guard route == .systemCompressed,
              !fallbackUsed,
              !replacing,
              !terminal,
              let renderer,
              !renderer.hasSufficientMediaDataForReliablePlaybackStart,
              let duration = contiguousSentCompressedDuration(),
              CMTimeCompare(duration, Self.compressedStartupFallbackDuration) >= 0 else {
            return
        }
        beginFallback()
    }

    private func contiguousSentCompressedDuration() -> CMTime? {
        guard let first = replay.first,
              first.sentCompressed,
              first.sample.presentationTimeStamp.isNumeric,
              first.sample.duration.isNumeric,
              CMTimeCompare(first.sample.duration, .zero) > 0 else { return nil }
        let firstPTS = first.sample.presentationTimeStamp
        var end = CMTimeAdd(firstPTS, first.sample.duration)
        guard end.isNumeric else { return nil }
        for entry in replay.dropFirst() {
            guard entry.sentCompressed,
                  entry.sample.presentationTimeStamp.isNumeric,
                  entry.sample.duration.isNumeric,
                  CMTimeCompare(entry.sample.duration, .zero) > 0 else { break }
            let toleratedEnd = CMTimeAdd(end, Self.audioContinuityTolerance)
            guard toleratedEnd.isNumeric,
                  CMTimeCompare(entry.sample.presentationTimeStamp, toleratedEnd) <= 0 else { break }
            let sampleEnd = CMTimeAdd(
                entry.sample.presentationTimeStamp,
                entry.sample.duration
            )
            guard sampleEnd.isNumeric else { break }
            if CMTimeCompare(sampleEnd, end) > 0 { end = sampleEnd }
        }
        let duration = CMTimeSubtract(end, firstPTS)
        return duration.isNumeric ? duration : nil
    }

    private func decodeAvailable() throws {
        guard route == .ffmpegPCM, let decoder, !terminal, !replacing else { return }
        for index in replay.indices where !replay[index].decoded {
            guard pendingPCM.count < Self.capacity else { break }
            let outputs: [CMSampleBuffer]
            do {
                outputs = try decoder.push(replay[index].sample)
                consecutiveInvalidPacketCount = 0
            } catch let error as PlaybackCoreError {
                guard case let .audioFallbackDecode(status) = error,
                      status == FFmpegPCMAudioDecoder.invalidPacketErrorCode,
                      consecutiveInvalidPacketCount < Self.maximumConsecutiveInvalidPackets else {
                    throw error
                }
                consecutiveInvalidPacketCount += 1
                replay[index].decoded = true
                decoder.flush()
                continue
            }
            guard outputs.count <= Self.capacity - pendingPCM.count else {
                throw PlaybackCoreError.audioFallbackDecode(
                    FFmpegPCMAudioDecoder.tokenCapacityErrorCode
                )
            }
            for output in outputs {
                guard let outputFormat = CMSampleBufferGetFormatDescription(output),
                      CMFormatDescriptionGetMediaSubType(outputFormat) == kAudioFormatLinearPCM else {
                    throw PlaybackCoreError.audioFallbackDecode(
                        FFmpegPCMAudioDecoder.invalidCallbackErrorCode
                    )
                }
                pcmOutputFormat = outputFormat
            }
            pendingPCM.append(contentsOf: outputs)
            replay[index].decoded = true
        }
    }

    private func drainPCM() throws {
        guard route == .ffmpegPCM,
              let renderer,
              renderer.mediaKind == .linearPCM,
              rendererAttached, !replacing, !terminal else { return }
        while renderer.isReadyForMoreMediaData {
            while renderer.isReadyForMoreMediaData, !pendingPCM.isEmpty {
                let sample = pendingPCM.removeFirst()
                try renderer.enqueue(sample)
                recordPCMPreroll(sample)
                anchorIfNeeded(at: CMSampleBufferGetPresentationTimeStamp(sample))
            }
            guard renderer.isReadyForMoreMediaData,
                  replay.contains(where: { !$0.decoded }) else { return }
            try decodeAvailable()
            guard !pendingPCM.isEmpty else { return }
        }
    }

    private func anchorIfNeeded(at time: CMTime) {
        guard needsAnchor else { return }
        needsAnchor = false
        setSynchronizerRate(1, time: time)
    }

    private func pruneExpired(at time: CMTime) throws {
        guard time.isNumeric else { return }
        replay.removeAll { entry in
            let duration = entry.sample.duration
            guard duration.isNumeric, duration >= .zero else { return false }
            let end = CMTimeAdd(entry.sample.presentationTimeStamp, duration)
            return end.isNumeric && CMTimeCompare(end, time) <= 0
        }
    }

    private func isCurrent(
        epoch: UInt64,
        rendererID: AudioRendererIdentity,
        generation: MediaGeneration
    ) -> Bool {
        self.epoch == epoch && self.generation == generation &&
            renderer?.identity == rendererID && configured && !stopped
    }

    // `hasSufficientMediaDataForReliablePlaybackStart` and the PCM preroll window
    // both answer a *startup* question — "is enough audio buffered to begin
    // playing" — and a healthy running renderer drops them back to false as it
    // consumes what it holds. This method is called from the media-data-request
    // callback, so re-deriving readiness from them toggled readiness several
    // times a second. Every drop reached the readiness observer as `.invalidated`,
    // which closed the playback readiness gate as an audio replacement, paused
    // the clock and stopped display submission — on a live stream that alone cut
    // playback to a few frames per second. Latch the preroll once satisfied; the
    // lifecycle flags still revoke readiness for the events that really do
    // invalidate it (replacement, flush, stop, teardown).
    private func updateReadiness() {
        let attached = configured && !stopped && !terminal && !replacing && rendererAttached
        guard attached else {
            updateSnapshot(route: route, ready: false)
            return
        }
        if !startupPrerollSatisfied {
            let rendererHasPreroll = renderer?.hasSufficientMediaDataForReliablePlaybackStart == true
            let pcmHasPreroll = route == .ffmpegPCM && hasMinimumPCMPreroll
            startupPrerollSatisfied = rendererHasPreroll || pcmHasPreroll
        }
        updateSnapshot(route: route, ready: startupPrerollSatisfied)
    }

    private var hasMinimumPCMPreroll: Bool {
        guard let start = pcmPrerollStart,
              let end = pcmPrerollEnd else { return false }
        let duration = CMTimeSubtract(end, start)
        return duration.isNumeric &&
            CMTimeCompare(duration, Self.pcmStartupPrerollDuration) >= 0
    }

    private func recordPCMPreroll(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard pts.isNumeric,
              sampleCount > 0,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0 else { return }
        let duration = CMTime(
            seconds: Double(sampleCount) / asbd.mSampleRate,
            preferredTimescale: 600_000
        )
        let end = CMTimeAdd(pts, duration)
        guard duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0,
              end.isNumeric else { return }

        guard let currentStart = pcmPrerollStart,
              let currentEnd = pcmPrerollEnd else {
            pcmPrerollStart = pts
            pcmPrerollEnd = end
            return
        }
        guard CMTimeCompare(pts, currentStart) >= 0,
              CMTimeCompare(pts, currentEnd) <= 0 else {
            pcmPrerollStart = pts
            pcmPrerollEnd = end
            return
        }
        if CMTimeCompare(end, currentEnd) > 0 {
            pcmPrerollEnd = end
        }
    }

    private func resetPCMPreroll() {
        pcmPrerollStart = nil
        pcmPrerollEnd = nil
    }

    private func classifyAndEmitDecode(_ error: any Error) {
        if let error = error as? PlaybackCoreError {
            switch error {
            case .audioFallbackDecode:
                emitTerminal(error)
            case let .audioRendererFailed(reason):
                if route == .ffmpegPCM {
                    emitTerminal(.audioRendererFailed(reason))
                } else {
                    emitTerminal(error)
                }
            default:
                emitTerminal(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode))
            }
        } else {
            emitTerminal(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode))
        }
    }

    private func emitTerminal(_ error: PlaybackCoreError) {
        guard !terminal else { return }
        terminal = true
        replacing = false
        if let renderer { stopRequests(on: renderer) }
        renderer?.stopObserving()
        updateSnapshot(route: route, ready: false)
        failureSink(error, generation)
    }

    private func updateSnapshot(route: AudioRoute, ready: Bool) {
        // Publishing "not ready" always clears the preroll latch, so a renderer
        // replacement or flush cannot carry the previous renderer's satisfied
        // preroll onto a fresh, empty one. Every caller runs on the playback
        // executor, which owns this flag.
        if !ready { startupPrerollSatisfied = false }
        snapshotLock.lock()
        let readinessChanged = publicSnapshot.isReadyForPlayback != ready
        publicSnapshot.route = route
        publicSnapshot.isReadyForPlayback = ready
        snapshotLock.unlock()
        if clockMode == .externallyManaged, readinessChanged {
            readinessSink?(ready ? .available : .invalidated, generation)
        }
    }

    private func setSynchronizerRate(_ rate: Float, time: CMTime) {
        guard clockMode == .standalone else { return }
        synchronizer.setRate(rate, time: time)
    }

    private func withSnapshot<Result>(_ body: (PublicSnapshot) -> Result) -> Result {
        snapshotLock.lock()
        let copied = publicSnapshot
        snapshotLock.unlock()
        return body(copied)
    }
}
