// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation

final class AudioRenderPipeline: AudioRenderPipelineProtocol, @unchecked Sendable {
    static let replayCapacityError = "audio.replay.capacity"
    static let removalFailedError = "audio.renderer.remove"
    static let unsupportedPCMError = "audio.pcm.unsupported"
    static let isolationError = "audio.executor.isolation"
    private static let capacity = 96

    private struct PublicSnapshot {
        var isReadyForPlayback = false
        var route = AudioRoute.systemCompressed
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
    private let snapshotLock = NSLock()
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
    private var rendererAttached = false
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
    private var currentOutput = AudioOutputCategory.other

    convenience init(
        synchronizer: AVSampleBufferRenderSynchronizer,
        executor: PlaybackSerialExecutor,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    ) {
        self.init(
            synchronizer: SystemAudioSynchronizer(synchronizer),
            executor: executor,
            failureSink: failureSink,
            rendererFactory: SystemAudioRendererFactory(),
            decoderFactory: LivePCMAudioDecoderFactory(),
            routeMonitor: AudioOutputRouteMonitor(executor: executor),
            supportChecker: SystemAudioFormatSupportChecker()
        )
    }

    init(
        synchronizer: any AudioRenderSynchronizing,
        executor: PlaybackSerialExecutor,
        failureSink: @escaping @Sendable (PlaybackCoreError, MediaGeneration) -> Void,
        rendererFactory: any AudioRendererFactory,
        decoderFactory: any PCMAudioDecoderFactory,
        routeMonitor: any AudioRouteMonitoring,
        supportChecker: any AudioFormatSupportChecking
    ) {
        self.synchronizer = synchronizer
        self.executor = executor
        self.failureSink = failureSink
        self.rendererFactory = rendererFactory
        self.decoderFactory = decoderFactory
        self.routeMonitor = routeMonitor
        self.supportChecker = supportChecker
    }

    var isReadyForPlayback: Bool {
        withSnapshot { $0.isReadyForPlayback }
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
        guard replay.count < Self.capacity else {
            throw PlaybackCoreError.audioRendererFailed(Self.replayCapacityError)
        }
        replay.append(ReplayEntry(sample: sample, sentCompressed: false, decoded: false))
        do {
            if route == .systemCompressed {
                try drainCompressed()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
        } catch {
            classifyAndEmitDecode(error)
        }
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
        synchronizer.setRate(0, time: synchronizer.currentTime())
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
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
        renderer?.stopRequestingMediaData()
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
        guard executor.isIsolated else {
            executor.submit { [weak self] in self?.stop() }
            return
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
        synchronizer.setRate(0, time: now)
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
        }
        decoder?.destroy()
        decoder = nil
        pcmOutputFormat = nil
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        updateSnapshot(route: route, ready: false)
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
        let rendererID = renderer.identity
        renderer.requestMediaDataWhenReady { [weak self] in
            guard let self else { return }
            executor.submit { [weak self] in
                self?.handleReady(
                    epoch: epoch,
                    rendererID: rendererID,
                    generation: generation
                )
            }
        }
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
              !terminal, !replacing else { return }
        do {
            if route == .systemCompressed {
                try drainCompressed()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
            updateReadiness()
        } catch {
            classifyAndEmitDecode(error)
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
        synchronizer.setRate(0, time: time)
        renderer.flush()
        do {
            try pruneExpired(at: time)
            for index in replay.indices {
                replay[index].sentCompressed = false
                replay[index].decoded = false
            }
            pendingPCM.removeAll(keepingCapacity: false)
            if route == .ffmpegPCM { decoder?.flush() }
            needsAnchor = true
            if route == .systemCompressed {
                try drainCompressed()
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
        synchronizer.setRate(0, time: synchronizer.currentTime())
        renderer.stopRequestingMediaData()
        renderer.stopObserving()
        renderer.flush()
        let transition = PendingRemoval(
            rendererID: renderer.identity,
            originEpoch: epoch,
            originGeneration: generation,
            targetEpoch: epoch,
            targetGeneration: generation,
            continuation: continuation
        )
        pendingRemoval = transition
        synchronizer.remove(renderer, at: .invalid) { [weak self] didRemove in
            guard let self else { return }
            executor.submit { [weak self] in
                self?.completeRemoval(
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
            renderer = replacement
            rendererAttached = false
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

    private func decodeAvailable() throws {
        guard route == .ffmpegPCM, let decoder, !terminal, !replacing else { return }
        for index in replay.indices where !replay[index].decoded {
            guard pendingPCM.count < Self.capacity else { break }
            let outputs = try decoder.push(replay[index].sample)
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
        synchronizer.setRate(1, time: time)
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

    private func updateReadiness() {
        let ready = configured && !stopped && !terminal && !replacing &&
            rendererAttached &&
            renderer?.hasSufficientMediaDataForReliablePlaybackStart == true
        updateSnapshot(route: route, ready: ready)
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
        renderer?.stopRequestingMediaData()
        renderer?.stopObserving()
        updateSnapshot(route: route, ready: false)
        failureSink(error, generation)
    }

    private func updateSnapshot(route: AudioRoute, ready: Bool) {
        snapshotLock.lock()
        publicSnapshot.route = route
        publicSnapshot.isReadyForPlayback = ready
        snapshotLock.unlock()
    }

    private func withSnapshot<Result>(_ body: (PublicSnapshot) -> Result) -> Result {
        snapshotLock.lock()
        let copied = publicSnapshot
        snapshotLock.unlock()
        return body(copied)
    }
}
