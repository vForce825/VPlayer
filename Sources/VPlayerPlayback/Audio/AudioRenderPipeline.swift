// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
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
    typealias RecoveryScheduler = @Sendable (
        DispatchTimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void
    typealias DiagnosticsNow = @Sendable () -> TimeInterval

    static let removalFailedError = "audio.renderer.remove"
    static let unsupportedPCMError = "audio.pcm.unsupported"
    static let isolationError = "audio.executor.isolation"
    // Compressed replay is recovery history. It must span a conventional live
    // HLS segment; bounding it to 96 AAC packets retained barely two seconds and
    // made an automatic renderer flush unrecoverable in the middle of a five-
    // second segment. PCM remains separately bounded because it owns decoded
    // sample memory rather than tiny compressed access units.
    private static let replayCapacity = 512
    private static let replayHardCapacity = 1_024
    private static let pendingPCMCapacity = 96
    private static let pcmStartupPrerollDuration = CMTime(value: 1, timescale: 4)
    // Switching from AVFoundation's compressed renderer to the FFmpeg PCM
    // fallback is a renderer handoff, not a media-timeline interruption. Keep
    // an externally managed video clock running while the replacement acquires
    // a short preroll, but bound the grace period so a broken replacement can
    // still close readiness and surface the stall.
    private static let fallbackReadinessGrace: DispatchTimeInterval = .seconds(1)
    private static let maximumConsecutiveInvalidPackets = 8

    private struct DiagnosticsState {
        var automaticFlushTriggerCount: UInt64 = 0
        var outputConfigurationTriggerCount: UInt64 = 0
        var routeChangeTriggerCount: UInt64 = 0
        var recoveryTransactionCount: UInt64 = 0
        var suppressedCorrelatedTriggerCount: UInt64 = 0
        var compressedRendererRetryCount: UInt64 = 0
        var pcmFallbackCount: UInt64 = 0
        var lastFallbackReason: AudioFallbackReason?
        var startupWaitStartedAt: TimeInterval?
        var startupWaitingSeconds: Double?
        var rendererReady = false
        var rendererSufficient = false
        var activeCodec: AudioCodec?
        var formatFingerprint: AudioFormatFingerprintDiagnostic?
        var outputCategory = AudioDiagnosticOutputCategory.other
        var routeRevision: UInt64 = 0
        var mediaGeneration: MediaGeneration?
        var lastCompressedRendererFailure: AudioRendererFailureDiagnostic?
        var acceptedCompressedMediaDurationSeconds: Double = 0

        func snapshot(at timestamp: TimeInterval) -> AudioRenderDiagnostics {
            let waitingSeconds: Double
            if let startupWaitingSeconds {
                waitingSeconds = startupWaitingSeconds
            } else if let startupWaitStartedAt,
                      startupWaitStartedAt.isFinite,
                      timestamp.isFinite {
                waitingSeconds = max(0, timestamp - startupWaitStartedAt)
            } else {
                waitingSeconds = 0
            }
            return AudioRenderDiagnostics(
                automaticFlushTriggerCount: automaticFlushTriggerCount,
                outputConfigurationTriggerCount: outputConfigurationTriggerCount,
                routeChangeTriggerCount: routeChangeTriggerCount,
                recoveryTransactionCount: recoveryTransactionCount,
                suppressedCorrelatedTriggerCount: suppressedCorrelatedTriggerCount,
                compressedRendererRetryCount: compressedRendererRetryCount,
                pcmFallbackCount: pcmFallbackCount,
                lastFallbackReason: lastFallbackReason,
                startupWaitingSeconds: waitingSeconds,
                rendererReady: rendererReady,
                rendererSufficient: rendererSufficient,
                activeCodec: activeCodec,
                formatFingerprint: formatFingerprint,
                outputCategory: outputCategory,
                routeRevision: routeRevision,
                mediaGeneration: mediaGeneration,
                lastCompressedRendererFailure: lastCompressedRendererFailure,
                acceptedCompressedMediaDurationSeconds: acceptedCompressedMediaDurationSeconds
            )
        }
    }

    private struct PublicSnapshot {
        var isReadyForPlayback = false
        var route = AudioRoute.systemCompressed
        var recoveryCount: UInt64 = 0
        var diagnostics = DiagnosticsState()
    }

    private struct ReplayEntry {
        let sample: CompressedAudioSample
        var sentCompressed: Bool
        var decoded: Bool
        var acceptedCompressed: Bool
    }

    private struct CompressedAttemptKey: Hashable, Sendable {
        let generation: MediaGeneration
        let fingerprint: MediaFormatFingerprint
        let routeRevision: UInt64
    }

    private enum RemovalContinuation: Sendable {
        case configure
        case compressedRetry
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

    private enum RecoveryDeadline: Sendable {
        case collection
        case settleExpiry
    }

    private let executor: PlaybackSerialExecutor
    private let synchronizer: any AudioRenderSynchronizing
    private let failureSink: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    private let rendererFactory: any AudioRendererFactory
    private let decoderFactory: any PCMAudioDecoderFactory
    private let routeMonitor: any AudioRouteMonitoring
    private let supportChecker: any AudioFormatSupportChecking
    private let recoveryScheduler: RecoveryScheduler
    private let diagnosticsNow: DiagnosticsNow
    private let clockMode: AudioClockMode
    private let readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)?
    private let snapshotLock = NSLock()
    private let readyCallbackGate = AudioReadyCallbackGate()
    private var publicSnapshot = PublicSnapshot()

    private var nextEpoch: UInt64? = 1
    private var epoch: UInt64 = 0
    private var generation = MediaGeneration(rawValue: 0)
    private var format: CMAudioFormatDescription?
    private var fingerprint: MediaFormatFingerprint?
    private var pcmOutputFormat: CMAudioFormatDescription?
    private var codec: AudioCodec?
    private var renderer: (any AudioRenderer)?
    private var decoder: (any PCMAudioDecoding)?
    private var replay: [ReplayEntry] = []
    private var pendingPCM: [CMSampleBuffer] = []
    private var pcmPrerollStart: CMTime?
    private var pcmPrerollEnd: CMTime?
    private var acceptedCompressedRunStart: CMTime?
    private var acceptedCompressedRunEnd: CMTime?
    private var consecutiveInvalidPacketCount = 0
    private var rendererAttached = false
    private var rendererRequesting = false
    private var startupPrerollSatisfied = false
    private var replacing = false
    private var terminal = false
    private var configured = false
    private var stopped = true
    private var fallbackUsed = false
    private var retriedCompressedAttemptKey: CompressedAttemptKey?
    private var needsAnchor = false
    private var pendingReevaluation = false
    private var recoveryCoordinator = AudioRecoveryCoordinator()
    private var pendingRemoval: PendingRemoval?
    private var fallbackReadinessGraceActive = false
    private var compressedRetryPreservesReadiness = false
    private var sharedTimelineOpened = false
    private var stopCompletions: [StopCompletion] = []
    private var currentOutput = AudioOutputRouteCategory.other
    private var lastRouteSnapshot: AudioOutputRouteSnapshot?

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
        recoveryScheduler: RecoveryScheduler? = nil,
        diagnosticsNow: @escaping DiagnosticsNow = { ProcessInfo.processInfo.systemUptime },
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
        self.recoveryScheduler = recoveryScheduler ?? { delay, operation in
            executor.submit(after: delay, operation)
        }
        self.diagnosticsNow = diagnosticsNow
        self.clockMode = clockMode
        self.readinessSink = readinessSink
    }

    var isReadyForPlayback: Bool {
        withSnapshot { $0.isReadyForPlayback }
    }

    var recoveryCount: UInt64 {
        withSnapshot { $0.recoveryCount }
    }

    var diagnostics: AudioRenderDiagnostics {
        let timestamp = diagnosticsNow()
        return withSnapshot { $0.diagnostics.snapshot(at: timestamp) }
    }

    var route: AudioRoute {
        withSnapshot { $0.route }
    }

    func configure(
        format: CMAudioFormatDescription,
        codec: AudioCodec,
        generation: MediaGeneration,
        fingerprint: MediaFormatFingerprint
    ) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        let newEpoch = try takeEpoch()
        prepareConfiguration(
            format: format,
            codec: codec,
            generation: generation,
            fingerprint: fingerprint,
            epoch: newEpoch
        )

        if var pendingRemoval {
            pendingRemoval.targetEpoch = newEpoch
            pendingRemoval.targetGeneration = generation
            pendingRemoval.continuation = .configure
            self.pendingRemoval = pendingRemoval
            compressedRetryPreservesReadiness = false
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
        replay.append(ReplayEntry(
            sample: sample,
            sentCompressed: false,
            decoded: false,
            acceptedCompressed: false
        ))
        do {
            if !replacing, rendererAttached, let renderer {
                startRequests(on: renderer, epoch: epoch, generation: generation)
            }
            if route == .systemCompressed {
                try drainCompressed()
            } else {
                try decodeAvailable()
                try drainPCM()
            }
            try trimReplayHistory()
        } catch {
            classifyAndEmitDecode(error)
        }
        refreshMediaRequestState()
        updateReadiness()
    }

    func setSharedTimelineOpened(_ opened: Bool) {
        guard executor.isIsolated else {
            executor.submit { [weak self] in self?.setSharedTimelineOpened(opened) }
            return
        }
        sharedTimelineOpened = opened
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
        recoveryCoordinator.invalidate()
        needsAnchor = false
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        resetStartupWait()
        updateSnapshot(route: route, ready: false)
        setSynchronizerRate(0, time: synchronizer.currentTime())
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        resetCompressedDiagnosticContextForTimeline(generation: generation)
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
            case .compressedRetry, .fallback:
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
        recoveryCoordinator.invalidate()
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        sharedTimelineOpened = false
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
        resetAcceptedCompressedMedia()
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
        fingerprint: MediaFormatFingerprint,
        epoch: UInt64
    ) {
        routeMonitor.stop()
        decoder?.destroy()
        decoder = nil
        pcmOutputFormat = nil
        self.epoch = epoch
        self.generation = generation
        self.format = format
        self.fingerprint = fingerprint
        self.codec = codec
        replay.removeAll(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        consecutiveInvalidPacketCount = 0
        configured = true
        stopped = false
        fallbackUsed = false
        replacing = renderer != nil
        terminal = false
        needsAnchor = false
        pendingReevaluation = false
        recoveryCoordinator.invalidate()
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        sharedTimelineOpened = false
        currentOutput = .other
        lastRouteSnapshot = nil
        resetStartupWait()
        publishCompressedDiagnosticContext(
            codec: codec,
            fingerprint: fingerprint,
            generation: generation
        )
        updateSnapshot(route: .systemCompressed, ready: false)
    }

    private func activateCompressedRenderer() throws {
        let candidate = try rendererFactory.makeRenderer(mediaKind: .compressed)
        renderer = candidate
        rendererAttached = false
        installCallbacks(on: candidate, epoch: epoch, generation: generation)
        try synchronizer.attach(candidate)
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
        lastRouteSnapshot = nil
        routeMonitor.start { [weak self] snapshot in
            guard let self else { return }
            if executor.isIsolated {
                handleRoute(snapshot, epoch: epoch, generation: generation)
            } else {
                executor.submit { [weak self] in
                    self?.handleRoute(snapshot, epoch: epoch, generation: generation)
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
                try drainCompressed()
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
            guard route == .systemCompressed,
                  renderer?.mediaKind == .compressed,
                  let attemptKey = currentCompressedAttemptKey else {
                emitTerminal(.audioRendererFailed(reason))
                return
            }
            recordCompressedRendererFailure(reason)
            if retriedCompressedAttemptKey == attemptKey {
                beginFallback()
            } else {
                retriedCompressedAttemptKey = attemptKey
                beginCompressedRetry()
            }
        case .automaticFlush:
            if replacing {
                return
            }
            ingestRecovery(.automaticFlush)
        case .outputConfigurationChanged:
            if replacing { return }
            ingestRecovery(.outputConfigurationChanged)
        }
    }

    private func handleRoute(
        _ snapshot: AudioOutputRouteSnapshot,
        epoch: UInt64,
        generation: MediaGeneration
    ) {
        guard self.epoch == epoch, self.generation == generation,
              configured, !stopped, !terminal else { return }
        if let lastRouteSnapshot {
            guard snapshot.revision > lastRouteSnapshot.revision else { return }
        }
        lastRouteSnapshot = snapshot
        currentOutput = snapshot.category
        publishRouteDiagnosticContext(snapshot)
        guard snapshot.reason != .initial else { return }
        if replacing {
            pendingReevaluation = true
            return
        }
        ingestRecovery(.routeChanged)
    }

    private func ingestRecovery(_ cause: AudioRecoveryCause) {
        guard !terminal, !replacing, pendingRemoval == nil else { return }
        switch cause {
        case .automaticFlush:
            incrementDiagnostic(\.automaticFlushTriggerCount)
        case .outputConfigurationChanged:
            incrementDiagnostic(\.outputConfigurationTriggerCount)
        case .routeChanged:
            incrementDiagnostic(\.routeChangeTriggerCount)
        }
        processRecoveryActions(recoveryCoordinator.ingest(cause))
    }

    private func processRecoveryActions(_ actions: [AudioRecoveryAction]) {
        for action in actions {
            switch action {
            case let .scheduleCollection(ticket):
                scheduleRecoveryDeadline(
                    .collection,
                    ticket: ticket,
                    after: AudioRecoveryCoordinator.collectionDelay
                )
            case let .recover(ticket, causes):
                scheduleRecoveryTransaction(ticket: ticket, causes: causes)
            case let .scheduleSettleExpiry(ticket):
                scheduleRecoveryDeadline(
                    .settleExpiry,
                    ticket: ticket,
                    after: AudioRecoveryCoordinator.settleDelay
                )
            case .suppressed:
                incrementDiagnostic(\.suppressedCorrelatedTriggerCount)
            }
        }
    }

    private func scheduleRecoveryTransaction(
        ticket: AudioRecoveryTicket,
        causes: Set<AudioRecoveryCause>
    ) {
        guard configured, !stopped, !terminal, !replacing,
              pendingRemoval == nil, let rendererID = renderer?.identity else { return }
        let scheduledEpoch = epoch
        let scheduledGeneration = generation
        executor.submit { [weak self] in
            guard let self,
                  isCurrent(
                      epoch: scheduledEpoch,
                      rendererID: rendererID,
                      generation: scheduledGeneration
                  ),
                  !terminal, !replacing, pendingRemoval == nil,
                  recoveryCoordinator.isActive(ticket) else { return }
            performRecovery(ticket: ticket, causes: causes)
        }
    }

    private func scheduleRecoveryDeadline(
        _ deadline: RecoveryDeadline,
        ticket: AudioRecoveryTicket,
        after delay: DispatchTimeInterval
    ) {
        guard configured, !stopped, !terminal, !replacing,
              pendingRemoval == nil, let rendererID = renderer?.identity else { return }
        let scheduledEpoch = epoch
        let scheduledGeneration = generation
        recoveryScheduler(delay) { [weak self] in
            guard let self else { return }
            if executor.isIsolated {
                recoveryDeadlineFired(
                    deadline,
                    ticket: ticket,
                    epoch: scheduledEpoch,
                    rendererID: rendererID,
                    generation: scheduledGeneration
                )
            } else {
                executor.submit { [weak self] in
                    self?.recoveryDeadlineFired(
                        deadline,
                        ticket: ticket,
                        epoch: scheduledEpoch,
                        rendererID: rendererID,
                        generation: scheduledGeneration
                    )
                }
            }
        }
    }

    private func recoveryDeadlineFired(
        _ deadline: RecoveryDeadline,
        ticket: AudioRecoveryTicket,
        epoch: UInt64,
        rendererID: AudioRendererIdentity,
        generation: MediaGeneration
    ) {
        guard isCurrent(epoch: epoch, rendererID: rendererID, generation: generation),
              !terminal, !replacing, pendingRemoval == nil else { return }
        let actions: [AudioRecoveryAction]
        switch deadline {
        case .collection:
            actions = recoveryCoordinator.collectionDeadlineFired(for: ticket)
        case .settleExpiry:
            actions = recoveryCoordinator.settleDeadlineFired(for: ticket)
        }
        processRecoveryActions(actions)
    }

    private func performRecovery(
        ticket _: AudioRecoveryTicket,
        causes: Set<AudioRecoveryCause>
    ) {
        guard !terminal, !replacing, pendingRemoval == nil else { return }
        incrementDiagnostic(\.recoveryTransactionCount)
        if route == .ffmpegPCM,
           !causes.isDisjoint(with: [.outputConfigurationChanged, .routeChanged]),
           let pcmOutputFormat,
           !supportChecker.supports(
               format: pcmOutputFormat,
               route: .ffmpegPCM,
               output: currentOutput
           ) {
            emitTerminal(.audioRendererFailed(Self.unsupportedPCMError))
            return
        }
        recoverAtCurrentPlayhead()
    }

    private func recoverAtCurrentPlayhead() {
        guard !terminal, !replacing, let renderer else { return }
        let recoveryTime = synchronizer.currentTime()
        snapshotLock.lock()
        if publicSnapshot.recoveryCount < UInt64.max {
            publicSnapshot.recoveryCount += 1
        }
        snapshotLock.unlock()
        // Deliberately no `ready: false` here. Recovery keeps the *same* renderer
        // and refills it from `replay` before this method returns, all on the one
        // playback executor, so no observer can see the empty window. Publishing
        // an invalidation for it made a routine renderer automatic flush tear
        // down the video anchor and stop display submission.
        renderer.flush()
        resetPCMPreroll()
        do {
            try pruneExpired(at: recoveryTime)
            for index in replay.indices {
                replay[index].sentCompressed = false
                replay[index].decoded = false
            }
            pendingPCM.removeAll(keepingCapacity: false)
            if route == .ffmpegPCM {
                consecutiveInvalidPacketCount = 0
                decoder?.flush()
            }
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
        recoveryCoordinator.invalidate()
        pendingReevaluation = false
        fallbackUsed = true
        incrementDiagnostic(\.pcmFallbackCount)
        snapshotLock.withLock {
            publicSnapshot.diagnostics.lastFallbackReason =
                .repeatedCompressedRendererFailure
        }
        beginRemoval(of: renderer, continuation: .fallback)
    }

    private var currentCompressedAttemptKey: CompressedAttemptKey? {
        guard let fingerprint else { return nil }
        return CompressedAttemptKey(
            generation: generation,
            fingerprint: fingerprint,
            routeRevision: lastRouteSnapshot?.revision ?? 0
        )
    }

    private func beginCompressedRetry() {
        guard !replacing, !terminal, pendingRemoval == nil,
              let renderer, renderer.mediaKind == .compressed else { return }
        recoveryCoordinator.invalidate()
        pendingReevaluation = false
        incrementDiagnostic(\.compressedRendererRetryCount)
        beginRemoval(of: renderer, continuation: .compressedRetry)
    }

    private func beginRemoval(
        of renderer: any AudioRenderer,
        continuation: RemovalContinuation
    ) {
        guard pendingRemoval == nil else { return }
        let preservesReadiness: Bool
        switch continuation {
        case .compressedRetry:
            preservesReadiness = sharedTimelineOpened && isReadyForPlayback
            compressedRetryPreservesReadiness = preservesReadiness
            fallbackReadinessGraceActive = false
        case .fallback:
            preservesReadiness = clockMode == .externallyManaged && isReadyForPlayback
            compressedRetryPreservesReadiness = false
            fallbackReadinessGraceActive = preservesReadiness
        case .configure, .stop:
            preservesReadiness = false
            compressedRetryPreservesReadiness = false
            fallbackReadinessGraceActive = false
        }
        replacing = true
        if case .fallback = continuation, preservesReadiness {
            // The replacement must earn its own PCM preroll; only the public
            // readiness signal is bridged across this short handoff.
            startupPrerollSatisfied = false
            let scheduledEpoch = epoch
            let scheduledGeneration = generation
            executor.submit(after: Self.fallbackReadinessGrace) { [weak self] in
                self?.expireFallbackReadinessGrace(
                    epoch: scheduledEpoch,
                    generation: scheduledGeneration
                )
            }
        }
        updateSnapshot(route: route, ready: preservesReadiness)
        let keepsClockRunning: Bool
        if case .compressedRetry = continuation {
            keepsClockRunning = preservesReadiness
        } else {
            keepsClockRunning = false
        }
        if !keepsClockRunning {
            setSynchronizerRate(0, time: synchronizer.currentTime())
        }
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
        case .configure, .compressedRetry, .fallback:
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
        case .compressedRetry:
            completeCompressedRetryAfterRemoval()
        case .fallback:
            completeFallbackAfterRemoval()
        case .stop:
            replacing = false
            updateReadiness()
        }
    }

    private func completeCompressedRetryAfterRemoval() {
        guard configured, !stopped, replacing, !terminal else { return }
        do {
            let replacement = try rendererFactory.makeRenderer(mediaKind: .compressed)
            renderer = replacement
            rendererAttached = false
            installCallbacks(on: replacement, epoch: epoch, generation: generation)
            try synchronizer.attach(replacement)
            rendererAttached = true
            try pruneExpired(at: synchronizer.currentTime())
            for index in replay.indices {
                replay[index].sentCompressed = false
            }
            replacing = false
            compressedRetryPreservesReadiness = false
            startRequests(on: replacement, epoch: epoch, generation: generation)
            try drainCompressed()
            refreshMediaRequestState()
            updateReadiness()
            if pendingReevaluation {
                pendingReevaluation = false
                ingestRecovery(.routeChanged)
            }
        } catch {
            classifyAndEmitDecode(error)
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
            try synchronizer.attach(replacement)
            rendererAttached = true
            updateSnapshot(route: .ffmpegPCM, ready: fallbackReadinessGraceActive)
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
                ingestRecovery(.routeChanged)
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
            if !replay[index].acceptedCompressed {
                replay[index].acceptedCompressed = true
                recordAcceptedCompressedMedia(sample)
            }
            beginStartupWaitIfNeeded()
            anchorIfNeeded(at: sample.presentationTimeStamp)
        }
    }

    private func decodeAvailable() throws {
        guard route == .ffmpegPCM, let decoder, !terminal, !replacing else { return }
        for index in replay.indices where !replay[index].decoded {
            guard pendingPCM.count < Self.pendingPCMCapacity else { break }
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
            guard outputs.count <= Self.pendingPCMCapacity - pendingPCM.count else {
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

    private func trimReplayHistory() throws {
        while replay.count > Self.replayCapacity {
            // An entry that has not reached the active renderer/decoder is work,
            // not history, and may never be silently overwritten. Prefer the
            // farthest-future completed entry so the bounded recovery window
            // continues to cover the current clock during a segment burst.
            let removable = replay.indices.reversed().first { index in
                switch route {
                case .systemCompressed:
                    replay[index].sentCompressed
                case .ffmpegPCM:
                    replay[index].decoded
                }
            }
            guard let removable else { break }
            replay.remove(at: removable)
        }
        guard replay.count <= Self.replayHardCapacity else {
            throw PlaybackCoreError.audioRendererFailed("audio.replay.backpressure")
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
            // Compressed packets continue arriving while AVFoundation removes
            // the failed renderer. They belong in replay, but must not let the
            // enqueue-side readiness refresh puncture the bounded handoff grace.
            updateSnapshot(
                route: route,
                ready: fallbackReadinessGraceActive || compressedRetryPreservesReadiness
            )
            return
        }
        let rendererReady = renderer?.isReadyForMoreMediaData == true
        let rendererSufficient =
            renderer?.hasSufficientMediaDataForReliablePlaybackStart == true
        if !startupPrerollSatisfied {
            let pcmHasPreroll = route == .ffmpegPCM && hasMinimumPCMPreroll
            startupPrerollSatisfied = rendererSufficient || pcmHasPreroll
        }
        if startupPrerollSatisfied {
            fallbackReadinessGraceActive = false
            freezeStartupWaitIfNeeded()
        }
        updateSnapshot(
            route: route,
            ready: startupPrerollSatisfied || fallbackReadinessGraceActive,
            rendererReady: rendererReady,
            rendererSufficient: rendererSufficient
        )
    }

    private func expireFallbackReadinessGrace(
        epoch: UInt64,
        generation: MediaGeneration
    ) {
        guard fallbackReadinessGraceActive,
              self.epoch == epoch,
              self.generation == generation else { return }
        fallbackReadinessGraceActive = false
        updateReadiness()
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

    private func recordAcceptedCompressedMedia(_ sample: CompressedAudioSample) {
        let start = sample.presentationTimeStamp
        let duration = sample.duration
        let end = CMTimeAdd(start, duration)
        guard start.isNumeric,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0,
              end.isNumeric else { return }

        if let currentStart = acceptedCompressedRunStart,
           let currentEnd = acceptedCompressedRunEnd,
           CMTimeCompare(start, currentEnd) <= 0,
           CMTimeCompare(end, currentStart) >= 0 {
            if CMTimeCompare(start, currentStart) < 0 {
                acceptedCompressedRunStart = start
            }
            if CMTimeCompare(end, currentEnd) > 0 {
                acceptedCompressedRunEnd = end
            }
        } else {
            acceptedCompressedRunStart = start
            acceptedCompressedRunEnd = end
        }

        guard let runStart = acceptedCompressedRunStart,
              let runEnd = acceptedCompressedRunEnd else { return }
        let seconds = CMTimeSubtract(runEnd, runStart).seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        snapshotLock.withLock {
            publicSnapshot.diagnostics.acceptedCompressedMediaDurationSeconds = seconds
        }
    }

    private func resetAcceptedCompressedMedia() {
        acceptedCompressedRunStart = nil
        acceptedCompressedRunEnd = nil
        snapshotLock.withLock {
            publicSnapshot.diagnostics.acceptedCompressedMediaDurationSeconds = 0
        }
    }

    private func publishCompressedDiagnosticContext(
        codec: AudioCodec,
        fingerprint: MediaFormatFingerprint,
        generation: MediaGeneration
    ) {
        let digest = SHA256.hash(data: fingerprint.bytes)
        let value = digest.map { String(format: "%02x", $0) }.joined()
        let boundedFingerprint = AudioFormatFingerprintDiagnostic(value: value)
        snapshotLock.withLock {
            publicSnapshot.diagnostics.activeCodec = codec
            publicSnapshot.diagnostics.formatFingerprint = boundedFingerprint
            publicSnapshot.diagnostics.outputCategory = .other
            publicSnapshot.diagnostics.routeRevision = 0
            publicSnapshot.diagnostics.mediaGeneration = generation
            publicSnapshot.diagnostics.lastCompressedRendererFailure = nil
        }
    }

    private func resetCompressedDiagnosticContextForTimeline(generation: MediaGeneration) {
        snapshotLock.withLock {
            publicSnapshot.diagnostics.outputCategory = .other
            publicSnapshot.diagnostics.routeRevision = 0
            publicSnapshot.diagnostics.mediaGeneration = generation
            publicSnapshot.diagnostics.lastCompressedRendererFailure = nil
        }
    }

    private func publishRouteDiagnosticContext(_ snapshot: AudioOutputRouteSnapshot) {
        let category: AudioDiagnosticOutputCategory
        switch snapshot.category {
        case .hdmi: category = .hdmi
        case .airPlay: category = .airPlay
        case .other: category = .other
        case .none: category = .none
        }
        snapshotLock.withLock {
            publicSnapshot.diagnostics.outputCategory = category
            publicSnapshot.diagnostics.routeRevision = snapshot.revision
        }
    }

    private func recordCompressedRendererFailure(_ reason: String) {
        guard let failure = AudioRendererFailureDiagnostic(
            sanitizedRepresentation: reason
        ) else { return }
        snapshotLock.withLock {
            publicSnapshot.diagnostics.lastCompressedRendererFailure = failure
        }
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
        recoveryCoordinator.invalidate()
        terminal = true
        replacing = false
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        sharedTimelineOpened = false
        if let renderer { stopRequests(on: renderer) }
        renderer?.stopObserving()
        updateSnapshot(route: route, ready: false)
        failureSink(error, generation)
    }

    private func updateSnapshot(
        route: AudioRoute,
        ready: Bool,
        rendererReady: Bool = false,
        rendererSufficient: Bool = false
    ) {
        // Publishing "not ready" always clears the preroll latch, so a renderer
        // replacement or flush cannot carry the previous renderer's satisfied
        // preroll onto a fresh, empty one. Every caller runs on the playback
        // executor, which owns this flag.
        if !ready { startupPrerollSatisfied = false }
        snapshotLock.lock()
        let readinessChanged = publicSnapshot.isReadyForPlayback != ready
        publicSnapshot.route = route
        publicSnapshot.isReadyForPlayback = ready
        publicSnapshot.diagnostics.rendererReady = rendererReady
        publicSnapshot.diagnostics.rendererSufficient = rendererSufficient
        snapshotLock.unlock()
        if clockMode == .externallyManaged, readinessChanged {
            readinessSink?(ready ? .available : .invalidated, generation)
        }
    }

    private func setSynchronizerRate(_ rate: Float, time: CMTime) {
        guard clockMode == .standalone else { return }
        synchronizer.setRate(rate, time: time)
    }

    private func incrementDiagnostic(
        _ keyPath: WritableKeyPath<DiagnosticsState, UInt64>
    ) {
        snapshotLock.withLock {
            let value = publicSnapshot.diagnostics[keyPath: keyPath]
            if value < UInt64.max {
                publicSnapshot.diagnostics[keyPath: keyPath] = value + 1
            }
        }
    }

    private func beginStartupWaitIfNeeded() {
        guard !startupPrerollSatisfied else { return }
        let timestamp = diagnosticsNow()
        guard timestamp.isFinite else { return }
        snapshotLock.withLock {
            guard publicSnapshot.diagnostics.startupWaitStartedAt == nil,
                  publicSnapshot.diagnostics.startupWaitingSeconds == nil else { return }
            publicSnapshot.diagnostics.startupWaitStartedAt = timestamp
        }
    }

    private func freezeStartupWaitIfNeeded() {
        let timestamp = diagnosticsNow()
        snapshotLock.withLock {
            guard publicSnapshot.diagnostics.startupWaitingSeconds == nil,
                  let startedAt = publicSnapshot.diagnostics.startupWaitStartedAt,
                  startedAt.isFinite,
                  timestamp.isFinite else { return }
            publicSnapshot.diagnostics.startupWaitingSeconds = max(0, timestamp - startedAt)
        }
    }

    private func resetStartupWait() {
        snapshotLock.withLock {
            publicSnapshot.diagnostics.startupWaitStartedAt = nil
            publicSnapshot.diagnostics.startupWaitingSeconds = nil
        }
    }

    private func withSnapshot<Result>(_ body: (PublicSnapshot) -> Result) -> Result {
        snapshotLock.lock()
        let copied = publicSnapshot
        snapshotLock.unlock()
        return body(copied)
    }
}
