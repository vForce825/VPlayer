// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

struct AudioAutomaticFlushProgressOriginTracker: Sendable {
    private var currentTicket: AudioRendererProgressTicket?

    var retainedTicketCount: Int {
        currentTicket == nil ? 0 : 1
    }

    mutating func markCurrent(_ ticket: AudioRendererProgressTicket) {
        currentTicket = ticket
    }

    mutating func consumeIfCurrent(_ ticket: AudioRendererProgressTicket) -> Bool {
        guard currentTicket == ticket else { return false }
        currentTicket = nil
        return true
    }

    mutating func clear() {
        currentTicket = nil
    }
}

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
    static let progressTicketExhaustedError =
        "audio.renderer.progress-ticket-exhausted"
    // PCM owns decoded sample memory separately from the compressed replay
    // reservoir, which is governed by CompressedAudioRetentionPolicy.
    private static let pendingPCMCapacity = 96
    private static let pcmStartupPrerollDuration = CMTime(value: 1, timescale: 4)
    private static let compressedStartupPrerollDuration = CMTime(value: 350, timescale: 1_000)
    // Switching from AVFoundation's compressed renderer to the FFmpeg PCM
    // fallback is a renderer handoff, not a media-timeline interruption. Keep
    // an externally managed video clock running while the replacement acquires
    // a short preroll, but bound the grace period so a broken replacement can
    // still close readiness and surface the stall.
    private static let fallbackReadinessGrace: DispatchTimeInterval = .seconds(1)
    private static let progressDeadlineDelay: DispatchTimeInterval = .seconds(1)
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
        var pendingSampleCount = 0
        var rendererRequestArmed = false
        var rendererBackpressureCount: UInt64 = 0
        var rendererRequestRearmCount: UInt64 = 0
        var automaticFlushNoProgressCount: UInt64 = 0
        var lastAcceptedPTSSeconds: Double?
        // Private monotonic instant used only to derive an age for the public
        // snapshot. The instant itself never leaves this state or Codable data.
        var lastRendererProgressMonotonicInstant: TimeInterval?

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
            let progressAgeSeconds: Double?
            if let lastRendererProgressMonotonicInstant,
               lastRendererProgressMonotonicInstant.isFinite,
               timestamp.isFinite {
                progressAgeSeconds = max(
                    0,
                    timestamp - lastRendererProgressMonotonicInstant
                )
            } else {
                progressAgeSeconds = nil
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
                acceptedCompressedMediaDurationSeconds: acceptedCompressedMediaDurationSeconds,
                pendingSampleCount: pendingSampleCount,
                rendererRequestArmed: rendererRequestArmed,
                rendererBackpressureCount: rendererBackpressureCount,
                rendererRequestRearmCount: rendererRequestRearmCount,
                automaticFlushNoProgressCount: automaticFlushNoProgressCount,
                lastAcceptedPTSSeconds: lastAcceptedPTSSeconds,
                lastRendererProgressAgeSeconds: progressAgeSeconds
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
        let retentionID: UInt64
        let sample: CompressedAudioSample
        let ownedPayloadBytes: Int
        let coverageStartPTS: CMTime
        var sentCompressed: Bool
        var decoded: Bool
        var acceptedCompressed: Bool
    }

    private struct ReplayRetentionPlan {
        let entries: [ReplayEntry]
        let byteBudget: OwnedByteBudget
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
    private let decodeCapabilityChecker: any SystemAudioDecodeCapabilityChecking
    private let pcmOutputValidator: any PCMOutputFormatValidating
    private let recoveryScheduler: RecoveryScheduler
    private let diagnosticsNow: DiagnosticsNow
    private let clockMode: AudioClockMode
    private let readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)?
    private let replayRetentionLimits: CompressedAudioRetentionLimits
    private let replayHardCount: Int
    private let snapshotLock = NSLock()
    private var publicSnapshot = PublicSnapshot()

    private var nextEpoch: UInt64? = 1
    private var epoch: UInt64 = 0
    private var generation = MediaGeneration(rawValue: 0)
    private var format: CMAudioFormatDescription?
    private var fingerprint: MediaFormatFingerprint?
    private var pcmOutputFormat: CMAudioFormatDescription?
    private var codec: AudioCodec?
    private var decoderExtradata = Data()
    private var renderer: (any AudioRenderer)?
    private var decoder: (any PCMAudioDecoding)?
    private var replay: [ReplayEntry] = []
    private var replayByteBudget: OwnedByteBudget
    private var recoveryFloor: CMTime?
    private var nextReplayRetentionID: UInt64? = 1
    private var pendingPCM: [CMSampleBuffer] = []
    private var activeContinuityIslandID: AudioContinuityIslandID?
    private var needsDecoderResetBeforeNextCompressedEnqueue = false
    private var pcmPrerollStart: CMTime?
    private var pcmPrerollEnd: CMTime?
    private var compressedPrerollStart: CMTime?
    private var compressedPrerollEnd: CMTime?
    private var acceptedCompressedRunStart: CMTime?
    private var acceptedCompressedRunEnd: CMTime?
    private var consecutiveInvalidPacketCount = 0
    private var rendererAttached = false
    private var rendererPumpState = AudioRendererPumpState()
    private var rendererDemandProgress = AudioRendererDemandProgressState()
    private var startupPrerollSatisfied = false
    private var replacing = false
    private var terminal = false
    private var configured = false
    private var stopped = true
    private var fallbackUsed = false
    private var progressMonitor: AudioRendererRecoveryProgressMonitor
    private var automaticFlushProgressOrigin =
        AudioAutomaticFlushProgressOriginTracker()
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
            decodeCapabilityChecker: CoreAudioDecodeCapabilityChecker(),
            pcmOutputValidator: PCMOutputFormatValidator(),
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
        decodeCapabilityChecker: any SystemAudioDecodeCapabilityChecking,
        pcmOutputValidator: any PCMOutputFormatValidating,
        recoveryScheduler: RecoveryScheduler? = nil,
        diagnosticsNow: @escaping DiagnosticsNow = { ProcessInfo.processInfo.systemUptime },
        clockMode: AudioClockMode = .standalone,
        readinessSink: (@Sendable (AudioRenderReadinessChange, MediaGeneration) -> Void)? = nil,
        replayRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.replay,
        replayHardCount: Int = CompressedAudioRetentionPolicy.replayHardCount,
        testingProgressDeadlineTicketStart: UInt64? = nil
    ) {
        self.synchronizer = synchronizer
        self.executor = executor
        self.failureSink = failureSink
        self.rendererFactory = rendererFactory
        self.decoderFactory = decoderFactory
        self.routeMonitor = routeMonitor
        self.decodeCapabilityChecker = decodeCapabilityChecker
        self.pcmOutputValidator = pcmOutputValidator
        self.recoveryScheduler = recoveryScheduler ?? { delay, operation in
            executor.submit(after: delay, operation)
        }
        self.diagnosticsNow = diagnosticsNow
        self.clockMode = clockMode
        self.readinessSink = readinessSink
        self.replayRetentionLimits = replayRetentionLimits
        self.replayHardCount = replayHardCount
        progressMonitor = testingProgressDeadlineTicketStart.map {
            AudioRendererRecoveryProgressMonitor(testingNextTicketRawValue: $0)
        } ?? AudioRendererRecoveryProgressMonitor()
        replayByteBudget = OwnedByteBudget(
            limit: replayRetentionLimits.maximumOwnedBytes
        )
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

    var currentRouteSnapshot: AudioOutputRouteSnapshot? {
        withSnapshot { _ in lastRouteSnapshot }
    }

    var anchorLeadTime: CMTime {
        if let snapshot = currentRouteSnapshot {
            return PlaybackAnchorLeadTimePolicy.compute(
                outputLatency: snapshot.outputLatency,
                ioBufferDuration: snapshot.ioBufferDuration
            )
        }
        return PlaybackAnchorLeadTimePolicy.minimumLeadTime
    }

    var outputLatency: CMTime {
        if let snapshot = currentRouteSnapshot {
            let total = max(0, snapshot.outputLatency) + max(0, snapshot.ioBufferDuration)
            return CMTime(seconds: total, preferredTimescale: 1_000)
        }
        return .zero
    }

    func configure(
        _ configuration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration
    ) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        let newEpoch = try takeEpoch()
        prepareConfiguration(
            configuration: configuration,
            generation: generation,
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
        try activateConfiguredRenderer()
    }

    func enqueue(_ sample: CompressedAudioSample) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        guard configured, !stopped, !terminal else { return }
        guard sample.generation == generation else { return }
        guard activeContinuityIslandID == sample.continuityIslandID else {
            throw PlaybackCoreError.audioRendererFailed("audio.island.mismatch")
        }
        guard sample.codec == codec else {
            throw PlaybackCoreError.audioRendererFailed("audio.codec.mismatch")
        }
        do {
            let coverageStartPTS = sample.effectiveCoverageStartPTS
            guard coverageStartPTS.isNumeric,
                  sample.presentationTimeStamp.isNumeric,
                  CMTimeCompare(coverageStartPTS, sample.presentationTimeStamp) <= 0 else {
                throw replayAccountingFailure()
            }
            try pruneExpired(at: synchronizer.currentTime())
            let ownedPayloadBytes = try SampleBufferBuilder
                .compressedAudioPayloadByteCount(sample.sampleBuffer)
            guard let retentionID = nextReplayRetentionID else {
                throw replayAccountingFailure()
            }
            let entry = ReplayEntry(
                retentionID: retentionID,
                sample: sample,
                ownedPayloadBytes: ownedPayloadBytes,
                coverageStartPTS: coverageStartPTS,
                sentCompressed: false,
                decoded: false,
                acceptedCompressed: false
            )
            var candidates = replay
            candidates.append(entry)
            let plan = try makeReplayRetentionPlan(
                candidates: candidates,
                floor: recoveryFloor
            )
            commitReplayRetentionPlan(plan)
            nextReplayRetentionID = retentionID == UInt64.max ? nil : retentionID + 1
        } catch {
            emitTerminal(replayRetentionFailure(from: error))
            return
        }
        driveRenderer()
    }

    func updateRecoveryFloor(_ floor: CMTime?) {
        guard executor.isIsolated else {
            executor.submit { [weak self] in self?.updateRecoveryFloor(floor) }
            return
        }
        let normalizedFloor = floor?.isNumeric == true ? floor : nil
        do {
            try validateReplayAccounting()
            let plan = try makeReplayRetentionPlan(
                candidates: replay,
                floor: normalizedFloor
            )
            recoveryFloor = normalizedFloor
            commitReplayRetentionPlan(plan)
        } catch {
            emitTerminal(replayRetentionFailure(from: error))
        }
    }

    var retainedReplayPayloadBytes: Int {
        precondition(executor.isIsolated)
        return replayByteBudget.used
    }

    var retainedReplaySampleIDs: [UInt64] {
        precondition(executor.isIsolated)
        return replay.map(\.sample.id)
    }

    func activateContinuityIsland(
        _ islandID: AudioContinuityIslandID,
        generation: MediaGeneration
    ) {
        guard executor.isIsolated else {
            executor.submit { [weak self] in
                self?.activateContinuityIsland(islandID, generation: generation)
            }
            return
        }
        guard configured, !stopped, !terminal,
              generation == self.generation,
              islandID != activeContinuityIslandID else { return }

        guard activeContinuityIslandID != nil else {
            activeContinuityIslandID = islandID
            updateSnapshot(route: route, ready: false)
            return
        }

        if let renderer { resetRendererQueue(renderer) }
        clearReplay(keepingCapacity: false)
        pendingPCM.removeAll(keepingCapacity: false)
        decoder?.flush()
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        consecutiveInvalidPacketCount = 0
        recoveryCoordinator.invalidate()
        invalidateProgressMonitor()
        pendingReevaluation = false
        needsAnchor = false
        needsDecoderResetBeforeNextCompressedEnqueue = false
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        resetStartupWait()
        activeContinuityIslandID = islandID
        resetRendererProgressObservation()
        updateSnapshot(route: route, ready: false)
    }

    func prepareAnchor(
        at commonPTS: CMTime,
        in islandID: AudioContinuityIslandID
    ) throws {
        guard executor.isIsolated else {
            throw PlaybackCoreError.audioRendererFailed(Self.isolationError)
        }
        guard configured, !stopped, !terminal else { return }
        guard islandID == activeContinuityIslandID else {
            throw PlaybackCoreError.audioRendererFailed("audio.island.mismatch")
        }

        try pruneExpired(at: commonPTS)
        guard replay.contains(where: { entry in
            entry.sample.continuityIslandID == islandID
                && replayEntry(entry, covers: commonPTS)
        }) else {
            throw PlaybackCoreError.audioRendererFailed(
                CompressedAudioRetentionPolicy.unretainedAnchorError
            )
        }
        if let renderer { resetRendererQueue(renderer) }
        pendingPCM.removeAll(keepingCapacity: false)
        decoder?.flush()
        resetPCMPreroll()
        consecutiveInvalidPacketCount = 0
        for index in replay.indices {
            replay[index].sentCompressed = false
            replay[index].decoded = false
        }
        needsDecoderResetBeforeNextCompressedEnqueue = true
        driveRenderer()
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
        if let renderer {
            resetRendererQueue(renderer)
        } else {
            invalidateRendererRequest(on: nil)
        }
        guard let newEpoch = takeEpochWithoutThrow() else { return }
        epoch = newEpoch
        self.generation = generation
        terminal = false
        pendingReevaluation = false
        recoveryCoordinator.invalidate()
        invalidateProgressMonitor()
        needsAnchor = false
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        resetStartupWait()
        updateSnapshot(route: route, ready: false)
        setSynchronizerRate(0, time: synchronizer.currentTime())
        clearReplay(keepingCapacity: false)
        recoveryFloor = nil
        pendingPCM.removeAll(keepingCapacity: false)
        activeContinuityIslandID = nil
        needsDecoderResetBeforeNextCompressedEnqueue = false
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        resetRendererProgressObservation()
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
        renderer?.stopObserving()
        if let renderer {
            establishRendererDemandLifetime(for: renderer)
            installCallbacks(on: renderer, epoch: newEpoch, generation: generation)
        }
        startRouteMonitor(epoch: newEpoch, generation: generation)
        driveRenderer()
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
        invalidateProgressMonitor()
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
        decoderExtradata = Data()
        pcmOutputFormat = nil
        clearReplay(keepingCapacity: false)
        recoveryFloor = nil
        pendingPCM.removeAll(keepingCapacity: false)
        activeContinuityIslandID = nil
        needsDecoderResetBeforeNextCompressedEnqueue = false
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        resetRendererProgressObservation()
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
        configuration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration,
        epoch: UInt64
    ) {
        routeMonitor.stop()
        decoder?.destroy()
        decoder = nil
        pcmOutputFormat = nil
        self.epoch = epoch
        self.generation = generation
        format = configuration.formatDescription
        fingerprint = configuration.fingerprint
        codec = configuration.codec
        decoderExtradata = configuration.decoderExtradata
        clearReplay(keepingCapacity: false)
        recoveryFloor = nil
        pendingPCM.removeAll(keepingCapacity: false)
        activeContinuityIslandID = nil
        needsDecoderResetBeforeNextCompressedEnqueue = false
        resetPCMPreroll()
        resetAcceptedCompressedMedia()
        resetRendererProgressObservation()
        consecutiveInvalidPacketCount = 0
        configured = true
        stopped = false
        fallbackUsed = false
        replacing = renderer != nil
        terminal = false
        needsAnchor = false
        pendingReevaluation = false
        recoveryCoordinator.invalidate()
        invalidateProgressMonitor()
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        sharedTimelineOpened = false
        currentOutput = .other
        lastRouteSnapshot = nil
        resetStartupWait()
        publishCompressedDiagnosticContext(
            codec: configuration.codec,
            fingerprint: configuration.fingerprint,
            generation: generation
        )
        updateSnapshot(route: .systemCompressed, ready: false)
    }

    private func activateCompressedRenderer() throws {
        let candidate = try rendererFactory.makeRenderer(mediaKind: .compressed)
        rendererAttached = false
        installCallbacks(on: candidate, epoch: epoch, generation: generation)
        do {
            try synchronizer.attach(candidate)
        } catch {
            candidate.stopObserving()
            renderer = nil
            rendererAttached = false
            invalidateRendererDemandLifetime(on: candidate)
            throw error
        }
        renderer = candidate
        rendererAttached = true
        establishRendererDemandLifetime(for: candidate)
        replacing = false
        startRouteMonitor(epoch: epoch, generation: generation)
        driveRenderer()
    }

    private func activateConfiguredRenderer() throws {
        guard let format else {
            throw PlaybackCoreError.audioRendererFailed("audio.format.missing")
        }
        let formatID = CMFormatDescriptionGetMediaSubType(format)
        if decodeCapabilityChecker.supportsDecoding(formatID: formatID) {
            try activateCompressedRenderer()
            return
        }

        recordFallback(.systemDecoderUnavailable)
        replacing = true
        try activatePCMRenderer()
        startRouteMonitor(epoch: epoch, generation: generation)
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
        generation: MediaGeneration,
        queueEpisode: UInt64,
        requestTicket: AudioRendererRequestTicket
    ) {
        guard isCurrent(epoch: epoch, rendererID: rendererID, generation: generation),
              rendererPumpState.isCurrent(requestTicket),
              renderer?.isReadyForMoreMediaData == true,
              !terminal, !replacing else { return }
        if rendererDemandProgress.readyAfterValidatedRequest(
            rendererID: rendererID,
            epoch: epoch,
            queueEpisode: queueEpisode
        ), let token = currentProgressToken,
           progressMonitor.observeProgress(token) {
            automaticFlushProgressOrigin.clear()
        }
        driveRenderer()
    }

    private func reconcileRendererRequest(hasPendingWork: Bool) {
        let mayRequest = configured && !stopped && !terminal && !replacing && rendererAttached
        switch rendererPumpState.reconcile(
            hasPendingWork: mayRequest && hasPendingWork,
            keepArmedForProgress: mayRequest
                && progressMonitor.hasActiveBaseline
                && rendererDemandProgress.needsProgressRequest
        ) {
        case .none:
            break
        case let .arm(ticket, isRearm):
            if isRearm {
                incrementDiagnostic(\.rendererRequestRearmCount)
            }
            guard let renderer,
                  rendererDemandProgress.rendererID == renderer.identity,
                  rendererDemandProgress.epoch == epoch else {
                invalidateRendererRequest(on: renderer)
                publishRendererPumpObservation()
                return
            }
            let rendererID = renderer.identity
            let requestEpoch = epoch
            let requestGeneration = generation
            let requestQueueEpisode = rendererDemandProgress.queueEpisode
            let gate = AudioReadyCallbackGate()
            renderer.requestMediaDataWhenReady { [weak self, gate] in
                guard gate.claim() else { return }
                guard let self else {
                    gate.release()
                    return
                }
                executor.submit { [weak self, gate] in
                    defer { gate.release() }
                    self?.handleReady(
                        epoch: requestEpoch,
                        rendererID: rendererID,
                        generation: requestGeneration,
                        queueEpisode: requestQueueEpisode,
                        requestTicket: ticket
                    )
                }
            }
        case .disarm:
            renderer?.stopRequestingMediaData()
        }
        publishRendererPumpObservation()
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
            do {
                try pruneExpired(at: synchronizer.currentTime())
            } catch {
                classifyAndEmitDecode(error)
                return
            }
            let actions = progressMonitor.rendererFailed(
                key: attemptKey,
                hasReplay: !replay.isEmpty
            )
            guard !actions.isEmpty else {
                emitTerminal(.audioRendererFailed(reason))
                return
            }
            processProgressActions(
                actions,
                fallbackReason: .repeatedCompressedRendererFailure
            )
        case .automaticFlush:
            if replacing { return }
            fenceRendererQueueMutation(
                rendererID: rendererID,
                epoch: epoch
            )
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
        invalidateProgressMonitor()
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

    private func processProgressActions(
        _ actions: [AudioRendererProgressAction],
        fallbackReason: AudioFallbackReason,
        preprunedRecoveryTime: CMTime? = nil,
        automaticFlushOrigin: Bool = false
    ) {
        for action in actions {
            switch action {
            case .replay:
                incrementDiagnostic(\.recoveryTransactionCount)
                if let preprunedRecoveryTime {
                    recoverPreprunedReplay(at: preprunedRecoveryTime)
                } else {
                    recoverAtCurrentPlayhead()
                }
            case let .scheduleDeadline(ticket):
                if automaticFlushOrigin {
                    automaticFlushProgressOrigin.markCurrent(ticket)
                } else {
                    automaticFlushProgressOrigin.clear()
                }
                scheduleProgressDeadline(ticket)
            case .rebuildCompressed:
                beginCompressedRetry()
            case .fallbackPCM:
                beginFallback(reason: fallbackReason)
            case .terminalTicketExhausted:
                emitTerminal(.audioRendererFailed(Self.progressTicketExhaustedError))
            }
        }
    }

    private func scheduleProgressDeadline(_ ticket: AudioRendererProgressTicket) {
        guard configured, !stopped, !terminal, !replacing,
              pendingRemoval == nil, let rendererID = renderer?.identity else {
            _ = automaticFlushProgressOrigin.consumeIfCurrent(ticket)
            return
        }
        let scheduledEpoch = epoch
        let scheduledGeneration = generation
        recoveryScheduler(Self.progressDeadlineDelay) { [weak self] in
            guard let self else { return }
            if executor.isIsolated {
                progressDeadlineFired(
                    ticket,
                    epoch: scheduledEpoch,
                    rendererID: rendererID,
                    generation: scheduledGeneration
                )
            } else {
                executor.submit { [weak self] in
                    self?.progressDeadlineFired(
                        ticket,
                        epoch: scheduledEpoch,
                        rendererID: rendererID,
                        generation: scheduledGeneration
                    )
                }
            }
        }
    }

    private func progressDeadlineFired(
        _ ticket: AudioRendererProgressTicket,
        epoch: UInt64,
        rendererID: AudioRendererIdentity,
        generation: MediaGeneration
    ) {
        let automaticFlushOrigin =
            automaticFlushProgressOrigin.consumeIfCurrent(ticket)
        guard isCurrent(epoch: epoch, rendererID: rendererID, generation: generation),
              !terminal, !replacing, pendingRemoval == nil else { return }
        let actions = progressMonitor.deadlineFired(
            ticket,
            token: currentProgressToken
        )
        if automaticFlushOrigin, !actions.isEmpty {
            incrementDiagnostic(\.automaticFlushNoProgressCount)
        }
        processProgressActions(
            actions,
            fallbackReason: .compressedRendererNoProgressAfterRebuild
        )
    }

    private func performRecovery(
        ticket _: AudioRecoveryTicket,
        causes: Set<AudioRecoveryCause>
    ) {
        guard !terminal, !replacing, pendingRemoval == nil else { return }
        if route == .systemCompressed,
           let attemptKey = currentCompressedAttemptKey {
            let recoveryTime = synchronizer.currentTime()
            do {
                try pruneExpired(at: recoveryTime)
            } catch {
                classifyAndEmitDecode(error)
                return
            }
            guard let token = currentProgressToken else { return }
            let actions = if causes.contains(.automaticFlush) {
                progressMonitor.automaticFlush(
                    key: attemptKey,
                    token: token,
                    hasReplay: !replay.isEmpty
                )
            } else {
                progressMonitor.correlatedRecovery(
                    key: attemptKey,
                    token: token,
                    hasReplay: !replay.isEmpty
                )
            }
            if actions.isEmpty {
                incrementDiagnostic(\.suppressedCorrelatedTriggerCount)
                driveRenderer()
            } else {
                processProgressActions(
                    actions,
                    fallbackReason: .compressedRendererNoProgressAfterRebuild,
                    preprunedRecoveryTime: recoveryTime,
                    automaticFlushOrigin: causes.contains(.automaticFlush)
                )
            }
            return
        }

        incrementDiagnostic(\.recoveryTransactionCount)
        if route == .ffmpegPCM,
           !causes.isDisjoint(with: [.outputConfigurationChanged, .routeChanged]),
           let pcmOutputFormat,
           !pcmOutputValidator.isValidPCMOutput(pcmOutputFormat) {
            emitTerminal(.audioRendererFailed(Self.unsupportedPCMError))
            return
        }
        recoverAtCurrentPlayhead()
    }

    private func recoverAtCurrentPlayhead() {
        let recoveryTime = synchronizer.currentTime()
        do {
            try pruneExpired(at: recoveryTime)
            recoverPreprunedReplay(at: recoveryTime)
        } catch {
            classifyAndEmitDecode(error)
        }
    }

    private func recoverPreprunedReplay(at _: CMTime) {
        guard !terminal, !replacing, let renderer else { return }
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
        resetRendererQueue(renderer)
        resetPCMPreroll()
        for index in replay.indices {
            replay[index].sentCompressed = false
            replay[index].decoded = false
        }
        needsDecoderResetBeforeNextCompressedEnqueue = true
        pendingPCM.removeAll(keepingCapacity: false)
        if route == .ffmpegPCM {
            consecutiveInvalidPacketCount = 0
            decoder?.flush()
        }
        driveRenderer()
    }

    private func beginFallback(reason: AudioFallbackReason) {
        guard !fallbackUsed, !replacing, !terminal,
              pendingRemoval == nil, let renderer,
              format != nil, codec != nil else { return }
        recoveryCoordinator.invalidate()
        pendingReevaluation = false
        recordFallback(reason)
        beginRemoval(of: renderer, continuation: .fallback)
    }

    private var currentCompressedAttemptKey: AudioCompressedAttemptKey? {
        guard let fingerprint else { return nil }
        return AudioCompressedAttemptKey(
            generation: generation,
            fingerprint: fingerprint,
            routeRevision: lastRouteSnapshot?.revision ?? 0,
            islandID: activeContinuityIslandID
        )
    }

    private var currentProgressToken: AudioRendererProgressToken? {
        guard let activeContinuityIslandID else { return nil }
        return rendererDemandProgress.token(
            generation: generation,
            islandID: activeContinuityIslandID
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
        resetRendererQueue(renderer)
        invalidateRendererDemandLifetime(on: renderer)
        renderer.stopObserving()
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
                try activateConfiguredRenderer()
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
        let replacement: any AudioRenderer
        do {
            replacement = try rendererFactory.makeRenderer(mediaKind: .compressed)
        } catch {
            beginFallbackWithoutRemoval(reason: .repeatedCompressedRendererFailure)
            return
        }

        renderer = replacement
        rendererAttached = false
        installCallbacks(on: replacement, epoch: epoch, generation: generation)
        do {
            try synchronizer.attach(replacement)
        } catch {
            replacement.stopObserving()
            renderer = nil
            rendererAttached = false
            invalidateRendererDemandLifetime(on: replacement)
            beginFallbackWithoutRemoval(reason: .repeatedCompressedRendererFailure)
            return
        }
        rendererAttached = true
        establishRendererDemandLifetime(for: replacement)

        do {
            try pruneExpired(at: synchronizer.currentTime())
        } catch {
            classifyAndEmitDecode(error)
            return
        }
        replacing = false
        compressedRetryPreservesReadiness = false
        if let attemptKey = currentCompressedAttemptKey,
           let token = currentProgressToken {
            processProgressActions(
                progressMonitor.replacementReady(
                    key: attemptKey,
                    token: token,
                    hasReplay: !replay.isEmpty
                ),
                fallbackReason: .compressedRendererNoProgressAfterRebuild
            )
        } else {
            driveRenderer()
        }
        if pendingReevaluation {
            pendingReevaluation = false
            ingestRecovery(.routeChanged)
        }
    }

    private func beginFallbackWithoutRemoval(reason: AudioFallbackReason) {
        guard !fallbackUsed, configured, !stopped, !terminal,
              pendingRemoval == nil, renderer == nil else { return }
        recoveryCoordinator.invalidate()
        invalidateProgressMonitor()
        pendingReevaluation = false
        recordFallback(reason)
        replacing = true
        compressedRetryPreservesReadiness = false
        fallbackReadinessGraceActive = false
        updateSnapshot(route: route, ready: false)
        completeFallbackAfterRemoval()
    }

    private func recordFallback(_ reason: AudioFallbackReason) {
        fallbackUsed = true
        incrementDiagnostic(\.pcmFallbackCount)
        snapshotLock.withLock {
            publicSnapshot.diagnostics.lastFallbackReason = reason
        }
    }

    private func completeFallbackAfterRemoval() {
        guard configured, !stopped, replacing, !terminal else { return }
        do {
            try activatePCMRenderer()
            if pendingReevaluation {
                pendingReevaluation = false
                ingestRecovery(.routeChanged)
            }
        } catch {
            classifyAndEmitDecode(error)
        }
    }

    private func activatePCMRenderer() throws {
        guard let codec else {
            throw PlaybackCoreError.audioRendererFailed("audio.codec.missing")
        }
        let stagedDecoder = try decoderFactory.makeDecoder(
            codec: codec,
            extradata: decoderExtradata
        )
        let replacement: any AudioRenderer
        do {
            replacement = try rendererFactory.makeRenderer(mediaKind: .linearPCM)
        } catch {
            stagedDecoder.destroy()
            decoder = nil
            renderer = nil
            rendererAttached = false
            invalidateRendererDemandLifetime(on: nil)
            throw error
        }
        consecutiveInvalidPacketCount = 0
        rendererAttached = false
        resetPCMPreroll()
        installCallbacks(on: replacement, epoch: epoch, generation: generation)
        do {
            try synchronizer.attach(replacement)
        } catch {
            replacement.stopObserving()
            renderer = nil
            rendererAttached = false
            invalidateRendererDemandLifetime(on: replacement)
            stagedDecoder.destroy()
            decoder = nil
            throw error
        }
        decoder = stagedDecoder
        renderer = replacement
        rendererAttached = true
        establishRendererDemandLifetime(for: replacement)
        updateSnapshot(route: .ffmpegPCM, ready: fallbackReadinessGraceActive)
        replacing = false
        needsAnchor = true
        try pruneExpired(at: synchronizer.currentTime())
        for index in replay.indices { replay[index].decoded = false }
        driveRenderer()
    }

    private func driveRenderer() {
        guard configured, !stopped, !terminal else { return }
        do {
            try trimReplayHistory()
            guard !replacing, rendererAttached, renderer != nil else {
                publishRendererPumpObservation()
                updateReadiness()
                return
            }
            switch route {
            case .systemCompressed:
                try enqueueCompressedUntilBackpressured()
            case .ffmpegPCM:
                try enqueuePCMUntilBackpressured()
            }
        } catch {
            classifyAndEmitDecode(error)
            return
        }
        reconcileRendererRequest(hasPendingWork: pendingRendererSampleCount > 0)
        updateReadiness()
    }

    private var pendingRendererSampleCount: Int {
        switch route {
        case .systemCompressed:
            replay.lazy.filter { !$0.sentCompressed }.count
        case .ffmpegPCM:
            pendingPCM.count + replay.lazy.filter { !$0.decoded }.count
        }
    }

    private func enqueueCompressedUntilBackpressured() throws {
        guard route == .systemCompressed,
              let renderer,
              renderer.mediaKind == .compressed,
              rendererAttached, !replacing, !terminal else { return }
        while let index = replay.firstIndex(where: { !$0.sentCompressed }) {
            let sample = replay[index].sample
            let needsDecoderReset = needsDecoderResetBeforeNextCompressedEnqueue
            let sampleBuffer = if needsDecoderReset {
                try SampleBufferBuilder
                    .copyingAudioSampleBufferWithResetDecoderBeforeDecoding(sample.sampleBuffer)
            } else {
                sample.sampleBuffer
            }
            guard try renderer.enqueue(sampleBuffer) == .accepted else {
                incrementDiagnostic(\.rendererBackpressureCount)
                recordRendererBackpressure(on: renderer)
                return
            }
            recordRendererAcceptance(on: renderer)
            recordRendererAcceptanceDiagnostic(at: sample.presentationTimeStamp)
            if needsDecoderReset {
                needsDecoderResetBeforeNextCompressedEnqueue = false
            }
            replay[index].sentCompressed = true
            if !replay[index].acceptedCompressed {
                replay[index].acceptedCompressed = true
                recordCompressedPreroll(sample)
                recordAcceptedCompressedMedia(sample)
            }
            beginStartupWaitIfNeeded()
            anchorIfNeeded(at: sample.presentationTimeStamp)
            if !renderer.isReadyForMoreMediaData {
                recordRendererBackpressure(on: renderer)
            }
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
                      pcmOutputValidator.isValidPCMOutput(outputFormat) else {
                    throw PlaybackCoreError.audioRendererFailed(Self.unsupportedPCMError)
                }
                pcmOutputFormat = outputFormat
            }
            pendingPCM.append(contentsOf: outputs)
            replay[index].decoded = true
        }
    }

    private func enqueuePCMUntilBackpressured() throws {
        guard route == .ffmpegPCM,
              let renderer,
              renderer.mediaKind == .linearPCM,
              rendererAttached, !replacing, !terminal else { return }
        while true {
            if let sample = pendingPCM.first {
                guard try renderer.enqueue(sample) == .accepted else {
                    incrementDiagnostic(\.rendererBackpressureCount)
                    recordRendererBackpressure(on: renderer)
                    return
                }
                recordRendererAcceptance(on: renderer)
                recordRendererAcceptanceDiagnostic(
                    at: CMSampleBufferGetPresentationTimeStamp(sample)
                )
                pendingPCM.removeFirst()
                recordPCMPreroll(sample)
                anchorIfNeeded(at: CMSampleBufferGetPresentationTimeStamp(sample))
                if !renderer.isReadyForMoreMediaData {
                    recordRendererBackpressure(on: renderer)
                }
                continue
            }
            guard replay.contains(where: { !$0.decoded }) else { return }
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
        try validateReplayAccounting()
        let protectorID = replayProtectorID(in: replay, floor: recoveryFloor)
        let candidates = replay.filter { entry in
            guard entry.retentionID != protectorID,
                  isCompletedReplayHistory(entry),
                  let interval = replayInterval(of: entry) else { return true }
            return CMTimeCompare(interval.end, time) > 0
        }
        let plan = try makeReplayRetentionPlan(
            candidates: candidates,
            floor: recoveryFloor
        )
        commitReplayRetentionPlan(plan)
    }

    private func trimReplayHistory() throws {
        try validateReplayAccounting()
        commitReplayRetentionPlan(try makeReplayRetentionPlan(
            candidates: replay,
            floor: recoveryFloor
        ))
    }

    private func makeReplayRetentionPlan(
        candidates: [ReplayEntry],
        floor: CMTime?
    ) throws -> ReplayRetentionPlan {
        var planned = candidates
        let protectorID = replayProtectorID(in: candidates, floor: floor)

        func isRemovable(_ entry: ReplayEntry) -> Bool {
            entry.retentionID != protectorID && isCompletedReplayHistory(entry)
        }

        while true {
            let payloadBytes = try replayPayloadBytes(of: planned)
            guard planned.count > replayHardCount
                    || payloadBytes > replayRetentionLimits.maximumOwnedBytes else { break }
            guard let index = planned.firstIndex(where: isRemovable) else {
                throw replayCapacityFailure()
            }
            planned.remove(at: index)
        }

        while let newest = planned.last {
            guard let newestInterval = replayInterval(of: newest) else {
                throw replayAccountingFailure()
            }
            guard let oldestTail = planned.first(where: {
                $0.retentionID != protectorID
            }) else { break }
            guard let oldestInterval = replayInterval(of: oldestTail) else {
                throw replayAccountingFailure()
            }
            let span = CMTimeSubtract(newestInterval.end, oldestInterval.start)
            guard span.isNumeric, CMTimeCompare(span, .zero) > 0 else {
                throw replayAccountingFailure()
            }
            guard CMTimeCompare(span, replayRetentionLimits.latestTailHorizon) > 0
            else { break }
            guard let index = planned.firstIndex(where: isRemovable) else {
                throw replayCapacityFailure()
            }
            planned.remove(at: index)
        }

        while planned.count > replayRetentionLimits.maximumCount {
            guard let index = planned.firstIndex(where: isRemovable) else { break }
            planned.remove(at: index)
        }
        guard planned.count <= replayHardCount else {
            throw replayCapacityFailure()
        }

        var byteBudget = OwnedByteBudget(
            limit: replayRetentionLimits.maximumOwnedBytes
        )
        for entry in planned {
            guard try byteBudget.reserve(entry.ownedPayloadBytes) else {
                throw replayCapacityFailure()
            }
        }
        return ReplayRetentionPlan(entries: planned, byteBudget: byteBudget)
    }

    private func replayPayloadBytes(of entries: [ReplayEntry]) throws -> Int {
        var budget = OwnedByteBudget(limit: Int.max)
        for entry in entries {
            guard try budget.reserve(entry.ownedPayloadBytes) else {
                throw replayAccountingFailure()
            }
        }
        return budget.used
    }

    private func validateReplayAccounting() throws {
        guard try replayPayloadBytes(of: replay) == replayByteBudget.used else {
            throw replayAccountingFailure()
        }
    }

    private func replayProtectorID(
        in entries: [ReplayEntry],
        floor: CMTime?
    ) -> UInt64? {
        guard let floor, floor.isNumeric else { return nil }
        return entries.first(where: { replayEntry($0, covers: floor) })?.retentionID
    }

    private func replayEntry(_ entry: ReplayEntry, covers time: CMTime) -> Bool {
        guard time.isNumeric, let interval = replayInterval(of: entry) else { return false }
        return CMTimeCompare(interval.start, time) <= 0
            && CMTimeCompare(time, interval.end) < 0
    }

    private func replayInterval(
        of entry: ReplayEntry
    ) -> (start: CMTime, end: CMTime)? {
        let start = entry.coverageStartPTS
        let sampleStart = entry.sample.presentationTimeStamp
        let duration = entry.sample.duration
        guard start.isNumeric, sampleStart.isNumeric, duration.isNumeric,
              CMTimeCompare(start, sampleStart) <= 0,
              CMTimeCompare(duration, .zero) > 0 else { return nil }
        let end = CMTimeAdd(sampleStart, duration)
        guard end.isNumeric, CMTimeCompare(end, sampleStart) > 0 else { return nil }
        return (start, end)
    }

    private func isCompletedReplayHistory(_ entry: ReplayEntry) -> Bool {
        switch route {
        case .systemCompressed: entry.sentCompressed
        case .ffmpegPCM: entry.decoded
        }
    }

    private func commitReplayRetentionPlan(_ plan: ReplayRetentionPlan) {
        replay = plan.entries
        replayByteBudget = plan.byteBudget
    }

    private func clearReplay(keepingCapacity: Bool) {
        replay.removeAll(keepingCapacity: keepingCapacity)
        replayByteBudget.reset()
    }

    private func replayCapacityFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.replayCapacityError)
    }

    private func replayAccountingFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
    }

    private func replayRetentionFailure(from error: any Error) -> PlaybackCoreError {
        guard let core = error as? PlaybackCoreError else {
            return replayAccountingFailure()
        }
        switch core {
        case .audioRendererFailed(CompressedAudioRetentionPolicy.replayCapacityError),
             .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError):
            return core
        default:
            return replayAccountingFailure()
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
            let compressedHasPreroll = route == .systemCompressed && hasMinimumCompressedPreroll
            startupPrerollSatisfied = rendererSufficient || pcmHasPreroll || compressedHasPreroll
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

    private var requiredCompressedStartupPrerollDuration: CMTime {
        guard let lastRouteSnapshot else { return Self.compressedStartupPrerollDuration }
        let latency = max(0, lastRouteSnapshot.outputLatency) + max(0, lastRouteSnapshot.ioBufferDuration)
        if latency > 0.05 {
            let dynamicPreroll = CMTime(seconds: latency + 0.25, preferredTimescale: 1_000)
            return CMTimeCompare(dynamicPreroll, Self.compressedStartupPrerollDuration) > 0
                ? dynamicPreroll
                : Self.compressedStartupPrerollDuration
        }
        return Self.compressedStartupPrerollDuration
    }

    private var hasMinimumCompressedPreroll: Bool {
        guard let start = compressedPrerollStart,
              let end = compressedPrerollEnd else { return false }
        let duration = CMTimeSubtract(end, start)
        return duration.isNumeric &&
            CMTimeCompare(duration, requiredCompressedStartupPrerollDuration) >= 0
    }

    private func recordCompressedPreroll(_ sample: CompressedAudioSample) {
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        let end = CMTimeAdd(pts, duration)
        guard pts.isNumeric,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0,
              end.isNumeric else { return }

        guard let currentStart = compressedPrerollStart,
              let currentEnd = compressedPrerollEnd else {
            compressedPrerollStart = pts
            compressedPrerollEnd = end
            return
        }
        guard CMTimeCompare(pts, currentStart) >= 0,
              CMTimeCompare(pts, currentEnd) <= 0 else {
            compressedPrerollStart = pts
            compressedPrerollEnd = end
            return
        }
        if CMTimeCompare(end, currentEnd) > 0 {
            compressedPrerollEnd = end
        }
    }

    private func resetCompressedPreroll() {
        compressedPrerollStart = nil
        compressedPrerollEnd = nil
    }

    private var requiredPCMStartupPrerollDuration: CMTime {
        guard let lastRouteSnapshot else { return Self.pcmStartupPrerollDuration }
        let latency = max(0, lastRouteSnapshot.outputLatency) + max(0, lastRouteSnapshot.ioBufferDuration)
        if latency > 0.05 {
            let dynamicPreroll = CMTime(seconds: latency + 0.25, preferredTimescale: 1_000)
            return CMTimeCompare(dynamicPreroll, Self.pcmStartupPrerollDuration) > 0
                ? dynamicPreroll
                : Self.pcmStartupPrerollDuration
        }
        return Self.pcmStartupPrerollDuration
    }

    private var hasMinimumPCMPreroll: Bool {
        guard let start = pcmPrerollStart,
              let end = pcmPrerollEnd else { return false }
        let duration = CMTimeSubtract(end, start)
        return duration.isNumeric &&
            CMTimeCompare(duration, requiredPCMStartupPrerollDuration) >= 0
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
        resetCompressedPreroll()
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
        case .bluetooth: category = .bluetooth
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
        automaticFlushProgressOrigin.clear()
        terminal = true
        replacing = false
        fallbackReadinessGraceActive = false
        compressedRetryPreservesReadiness = false
        sharedTimelineOpened = false
        reconcileRendererRequest(hasPendingWork: false)
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
            PlaybackDiagnosticSaturatingCounter.increment(
                &publicSnapshot.diagnostics[keyPath: keyPath]
            )
        }
    }

    private func publishRendererPumpObservation() {
        let pendingSampleCount = pendingRendererSampleCount
        let rendererRequestArmed = rendererPumpState.isRequestArmed
        snapshotLock.withLock {
            publicSnapshot.diagnostics.pendingSampleCount = pendingSampleCount
            publicSnapshot.diagnostics.rendererRequestArmed = rendererRequestArmed
        }
    }

    private func recordRendererAcceptanceDiagnostic(at presentationTimeStamp: CMTime) {
        guard presentationTimeStamp.isNumeric,
              presentationTimeStamp.seconds.isFinite else { return }
        let ptsSeconds = presentationTimeStamp.seconds
        let monotonicInstant = diagnosticsNow()
        snapshotLock.withLock {
            if let previous = publicSnapshot.diagnostics.lastAcceptedPTSSeconds,
               ptsSeconds <= previous {
                return
            }
            publicSnapshot.diagnostics.lastAcceptedPTSSeconds = ptsSeconds
            if monotonicInstant.isFinite {
                publicSnapshot.diagnostics.lastRendererProgressMonotonicInstant =
                    monotonicInstant
            }
        }
    }

    private func resetRendererProgressObservation() {
        snapshotLock.withLock {
            publicSnapshot.diagnostics.pendingSampleCount = 0
            publicSnapshot.diagnostics.rendererRequestArmed = false
            publicSnapshot.diagnostics.lastAcceptedPTSSeconds = nil
            publicSnapshot.diagnostics.lastRendererProgressMonotonicInstant = nil
        }
    }

    private func invalidateProgressMonitor() {
        progressMonitor.invalidate()
        automaticFlushProgressOrigin.clear()
    }

    private func recordRendererAcceptance(on renderer: any AudioRenderer) {
        rendererDemandProgress.accepted(
            rendererID: renderer.identity,
            epoch: epoch,
            queueEpisode: rendererDemandProgress.queueEpisode
        )
    }

    private func recordRendererBackpressure(on renderer: any AudioRenderer) {
        rendererDemandProgress.backpressured(
            rendererID: renderer.identity,
            epoch: epoch,
            queueEpisode: rendererDemandProgress.queueEpisode
        )
    }

    private func invalidateRendererRequest(on renderer: (any AudioRenderer)?) {
        if case .disarm = rendererPumpState.invalidateRegistration() {
            renderer?.stopRequestingMediaData()
        }
    }

    private func fenceRendererQueueMutation(
        rendererID: AudioRendererIdentity,
        epoch: UInt64
    ) {
        invalidateRendererRequest(on: renderer)
        rendererDemandProgress.queueWasReset(
            rendererID: rendererID,
            epoch: epoch
        )
        publishRendererPumpObservation()
    }

    private func resetRendererQueue(_ renderer: any AudioRenderer) {
        invalidateRendererRequest(on: renderer)
        rendererDemandProgress.queueWasReset(
            rendererID: renderer.identity,
            epoch: epoch
        )
        renderer.flush()
        publishRendererPumpObservation()
    }

    private func invalidateRendererDemandLifetime(on renderer: (any AudioRenderer)?) {
        if case .disarm = rendererPumpState.rendererDidChange() {
            renderer?.stopRequestingMediaData()
        }
        rendererDemandProgress.rendererDidChange(to: nil, epoch: epoch)
        automaticFlushProgressOrigin.clear()
        publishRendererPumpObservation()
    }

    private func establishRendererDemandLifetime(for renderer: any AudioRenderer) {
        if case .disarm = rendererPumpState.rendererDidChange() {
            renderer.stopRequestingMediaData()
        }
        rendererDemandProgress.rendererDidChange(
            to: renderer.identity,
            epoch: epoch
        )
        automaticFlushProgressOrigin.clear()
        publishRendererPumpObservation()
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
