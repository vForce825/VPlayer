// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CryptoKit
import Foundation
#if DEBUG
import Darwin.Mach
#endif

public protocol PlaybackMetricsProviding: Actor {
    func playbackMetricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot?
}

// Where a discarded video frame was lost. A single total cannot distinguish a
// pipeline that is merely shedding late frames from one whose decode or
// deinterlace stage has stopped delivering entirely.
public enum VideoDropSource: Int, Sendable, CaseIterable {
    case decoderSubmission
    case decoderRecoverable
    case deinterlaceQueueFull
    case deinterlaceFailure
    case presentationOverflow
    case presentationExpired
    case presentationSuperseded
    /// Access units skipped because decode had fallen far enough behind that
    /// queueing more would only grow. Distinct from every other source: it is
    /// the pipeline choosing frames over a stall, not a fault.
    case decodeSubmissionBacklog
}

public struct PlaybackMetricsSnapshot: Codable, Sendable, Equatable {
    public let scanType: String
    public let activeRoute: String
    public let decoderCallbacksPerSecond: Double
    public let presentationsPerSecond: Double
    public let yadifKernelDispatchCount: UInt64
    public let staleGenerationDropCount: UInt64
    public let droppedVideoFrames: UInt64
    // Indexed by `VideoDropSource.rawValue`.
    public let videoDropCountsBySource: [UInt64]
    // Sanitized classification and status of the most recent decode failure,
    // e.g. "badData:-12909". A drop total cannot say which fault is repeating.
    public let lastVideoDecodeFailure: String?
    public let maximumPresentationQueueDepth: Int
    public let maximumYADIFInFlightCount: Int
    public let maximumYADIFInputDepth: Int
    public let gpuDurationP95Milliseconds: Double
    public let avDriftP95Milliseconds: Double
    public let residentMemoryBytes: UInt64
    public let elapsedSeconds: Double
    public let windowDurationSeconds: Double
    public let presentedVideoFrames: UInt64
    public let maximumAbsoluteAVDriftMilliseconds: Double
    public let crossGenerationPresentationCount: UInt64
    public let audioRoute: String
    public let audioReady: Bool
    public let readinessOpen: Bool
    public let retainedAudioCount: Int
    public let retainedVideoCount: Int
    public let audioFirstPTSSeconds: Double?
    public let audioDurationSeconds: Double
    public let videoFirstPTSSeconds: Double?
    // Newest processed video PTS *before* the retained window is bounded, so a
    // starved window can be told apart from video that legitimately trails audio.
    public let videoLatestPTSSeconds: Double?
    public let audioRelativeVideoPruneCount: UInt64
    // The gate bumps its cycle on every close, so a large value over a short run
    // means readiness is flapping rather than staying shut once.
    public let readinessCycleID: UInt64
    // Indexed by `PlaybackReadinessCloseReason.rawValue`: flush, buffering,
    // pause, discontinuity, audioReplacement, displayModeSwitch.
    public let readinessCloseReasonCounts: [UInt64]
    // How many times display submission has been resumed for an open gate. If
    // this stops advancing while frames keep arriving, the submission side is
    // stranded rather than the decode side.
    public let displayResumeCount: UInt64
    // Media time the playback clock currently reports. Compared against
    // `videoLatestPTSSeconds` this separates "the clock is not running" from
    // "frames are not reaching the presentation queue".
    public let clockTimeSeconds: Double?
    // Times the pipeline re-anchored because the clock had outrun the decoder.
    public let videoResyncCount: UInt64
    // Audio renderer recoveries (flush + full replay re-enqueue). Each one is
    // expensive on the playback executor, so a high rate starves ingest.
    public let audioRecoveryCount: UInt64
    // Display-link callbacks that reached the renderer. Divided by elapsed time
    // this is the *actual* tick rate, which is what separates "the display link
    // is missing ticks" from "the renderer refused ticks it was offered".
    public let renderTickCount: UInt64
    // Ticks the renderer declined because every in-flight slot was still held by
    // an incomplete GPU submission. A declined tick presents nothing, so the
    // frame that was due lands on the next tick as a superseded drop.
    public let renderSkippedInFlightCount: UInt64
    // Where the read path loses time. `queueFullWait` rising means the app is not
    // draining fast enough to keep reading; both near zero means the source
    // simply is not delivering realtime, and nothing in the app will fix it.
    public let demuxQueueFullWaitSeconds: Double
    public let demuxAdmitWaitSeconds: Double
    // Wall time the playback executor spent running work. Near the elapsed time
    // means it is saturated and the answer is less work on it; well below means
    // callers are merely queued behind it and the answer is less coupling.
    public let playbackExecutorBusySeconds: Double
    public let demuxPacketCount: UInt64
    public let videoAccessUnitCount: UInt64
    public let audioSampleCount: UInt64
    public let videoDecodeSubmissionCount: UInt64
    public let maximumVideoDecodeSubmissionMilliseconds: Double
    // Against `playbackExecutorBusySeconds` this says how much of the executor
    // decode submission is actually occupying — a maximum alone cannot separate
    // "one slow frame" from "every frame is slow".
    public let totalVideoDecodeSubmissionMilliseconds: Double
    // High-water mark of decode outputs waiting for the playback executor. Each
    // retains a decoder output buffer, so a mark that climbs and stays is the
    // decoder starving itself: submission blocks for a buffer that only the
    // executor can free, while the executor is blocked inside submission.
    public let maximumOutstandingDecoderOutputs: Int
    // High-water mark of access units queued for submission. Submission runs
    // off the playback executor, so this is where a slow decoder now shows up:
    // a mark parked at the configured depth means it is not keeping up, and the
    // `decodeSubmissionBacklog` drop count says what that cost.
    public let maximumDecodeSubmissionDepth: Int
    // What VideoToolbox itself reports it is still working on. Submission time
    // that climbs while this stays low is decode compute; submission time that
    // climbs with this pinned high is the decoder waiting for buffers back.
    public let maximumFramesBeingDecoded: Int
    // What the decode session actually reported for field mode and hardware
    // acceleration. Both are tolerated when unsupported, so without this a
    // session that silently fell back looks exactly like a healthy one.
    public let decoderSessionSummary: String?
}

struct PlaybackDiagnosticsChannelID: Sendable, Equatable {
    let value: String

    init(rawValue: String) {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        value = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

struct PlaybackDiagnosticsCorrelationID: Sendable, Equatable {
    let value: String

    init(channelIdentifier: PlaybackDiagnosticsChannelID, rawValue: UInt64) {
        let input = "\(channelIdentifier.value):\(rawValue)"
        let digest = SHA256.hash(data: Data(input.utf8))
        value = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

struct MetalGPUInterval: Sendable, Equatable {
    let gpuStartTime: TimeInterval
    let gpuEndTime: TimeInterval

    var durationMilliseconds: Double? {
        guard gpuStartTime.isFinite,
              gpuEndTime.isFinite,
              gpuStartTime >= 0,
              gpuEndTime >= gpuStartTime else { return nil }
        return (gpuEndTime - gpuStartTime) * 1_000
    }
}

final class PlaybackMetrics: @unchecked Sendable {
    typealias Now = @Sendable () -> TimeInterval
    typealias ResidentMemoryProvider = @Sendable () -> UInt64

    private struct TimedValue: Sendable {
        let timestamp: TimeInterval
        let value: Double
    }

    private struct State: Sendable {
        var scanType = "unknown"
        var activeRoute = "rawWhileClassifying"
        var decoderCallbackTimes: [TimeInterval] = []
        var presentationTimes: [TimeInterval] = []
        var gpuDurations: [TimedValue] = []
        var avDrifts: [TimedValue] = []
        var yadifKernelDispatchCount: UInt64 = 0
        var staleGenerationDropCount: UInt64 = 0
        var droppedVideoFrames: UInt64 = 0
        var videoDropCountsBySource = [UInt64](
            repeating: 0, count: VideoDropSource.allCases.count
        )
        var lastVideoDecodeFailure: String?
        var maximumPresentationQueueDepth = 0
        var maximumYADIFInFlightCount = 0
        var maximumYADIFInputDepth = 0
        var presentedVideoFrames: UInt64 = 0
        var maximumAbsoluteAVDriftMilliseconds = 0.0
        var crossGenerationPresentationCount: UInt64 = 0
        var audioRoute = "systemCompressed"
        var audioReady = false
        var readinessOpen = false
        var retainedAudioCount = 0
        var retainedVideoCount = 0
        var audioFirstPTSSeconds: Double?
        var audioDurationSeconds = 0.0
        var videoFirstPTSSeconds: Double?
        var videoLatestPTSSeconds: Double?
        var audioRelativeVideoPruneCount: UInt64 = 0
        var readinessCycleID: UInt64 = 0
        var readinessCloseReasonCounts = [UInt64](repeating: 0, count: 6)
        var displayResumeCount: UInt64 = 0
        var clockTimeSeconds: Double?
        var videoResyncCount: UInt64 = 0
        var audioRecoveryCount: UInt64 = 0
        var renderTickCount: UInt64 = 0
        var renderSkippedInFlightCount: UInt64 = 0
        var demuxQueueFullWaitNanoseconds: UInt64 = 0
        var demuxAdmitWaitNanoseconds: UInt64 = 0
        var playbackExecutorBusyNanoseconds: UInt64 = 0
        var demuxPacketCount: UInt64 = 0
        var videoAccessUnitCount: UInt64 = 0
        var audioSampleCount: UInt64 = 0
        var videoDecodeSubmissionCount: UInt64 = 0
        var maximumVideoDecodeSubmissionMilliseconds = 0.0
        var totalVideoDecodeSubmissionMilliseconds = 0.0
        var maximumOutstandingDecoderOutputs = 0
        var maximumDecodeSubmissionDepth = 0
        var maximumFramesBeingDecoded = 0
        var decoderSessionSummary: String?
        var avDriftGraceUntil: TimeInterval = 0
        var lastPrunedAt: TimeInterval

        init(startedAt: TimeInterval) {
            lastPrunedAt = startedAt
        }
    }

    private static let retainedWindowSeconds: TimeInterval = 120
    private let lock = NSLock()
    private let now: Now
    private let residentMemoryProvider: ResidentMemoryProvider
    let channelIdentifier: PlaybackDiagnosticsChannelID
    private let startedAt: TimeInterval
    private var state: State

    init(
        channelID: String,
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
        residentMemoryProvider: @escaping ResidentMemoryProvider = PlaybackMetrics.readResidentMemory
    ) {
        self.now = now
        self.residentMemoryProvider = residentMemoryProvider
        channelIdentifier = PlaybackDiagnosticsChannelID(rawValue: channelID)
        let startedAt = now()
        self.startedAt = startedAt
        state = State(startedAt: startedAt)
    }

    func update(scanType: ScanType) {
        lock.withLock { state.scanType = Self.name(for: scanType) }
    }

    func update(activeRoute: DeinterlaceRoute) {
        lock.withLock { state.activeRoute = Self.name(for: activeRoute) }
    }

    func updateReadinessDiagnostics(
        audioRoute: AudioRoute,
        audioReady: Bool,
        readinessOpen: Bool,
        retainedAudioCount: Int,
        retainedVideoCount: Int,
        audioFirstPTS: CMTime?,
        audioDuration: CMTime?,
        videoFirstPTS: CMTime?,
        readinessCycleID: UInt64 = 0,
        readinessCloseReasonCounts: [UInt64] = [],
        clockTime: CMTime? = nil,
        audioRecoveryCount: UInt64 = 0
    ) {
        lock.withLock {
            state.audioRoute = audioRoute == .systemCompressed
                ? "systemCompressed"
                : "ffmpegPCM"
            state.audioReady = audioReady
            state.readinessOpen = readinessOpen
            state.retainedAudioCount = max(0, retainedAudioCount)
            state.retainedVideoCount = max(0, retainedVideoCount)
            state.audioFirstPTSSeconds = Self.numericSeconds(audioFirstPTS)
            state.audioDurationSeconds = Self.numericSeconds(audioDuration) ?? 0
            state.videoFirstPTSSeconds = Self.numericSeconds(videoFirstPTS)
            state.readinessCycleID = readinessCycleID
            if !readinessCloseReasonCounts.isEmpty {
                state.readinessCloseReasonCounts = readinessCloseReasonCounts
            }
            state.clockTimeSeconds = Self.numericSeconds(clockTime)
            state.audioRecoveryCount = audioRecoveryCount
        }
    }

    func recordVideoResync() {
        lock.withLock { state.videoResyncCount &+= 1 }
    }

    func update(
        demuxQueueFullWaitNanoseconds: UInt64,
        demuxAdmitWaitNanoseconds: UInt64,
        playbackExecutorBusyNanoseconds: UInt64
    ) {
        lock.withLock {
            state.demuxQueueFullWaitNanoseconds = demuxQueueFullWaitNanoseconds
            state.demuxAdmitWaitNanoseconds = demuxAdmitWaitNanoseconds
            state.playbackExecutorBusyNanoseconds = playbackExecutorBusyNanoseconds
        }
    }

    func recordRenderTick(skippedInFlight: Bool) {
        lock.withLock {
            state.renderTickCount &+= 1
            if skippedInFlight { state.renderSkippedInFlightCount &+= 1 }
        }
    }

    func recordDisplaySubmissionResume() {
        lock.withLock { state.displayResumeCount &+= 1 }
    }

    func recordProcessedVideo(latestPTS: CMTime?) {
        guard let seconds = Self.numericSeconds(latestPTS) else { return }
        lock.withLock {
            state.videoLatestPTSSeconds = max(state.videoLatestPTSSeconds ?? seconds, seconds)
        }
    }

    func recordAudioRelativeVideoPrune(count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            state.audioRelativeVideoPruneCount &+= UInt64(count)
        }
    }

    func recordDecoderCallback() {
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.decoderCallbackTimes.append(timestamp)
        }
    }

    func recordDemuxPacket() {
        lock.withLock { state.demuxPacketCount &+= 1 }
    }

    func recordVideoAccessUnit() {
        lock.withLock { state.videoAccessUnitCount &+= 1 }
    }

    func recordAudioSample() {
        lock.withLock { state.audioSampleCount &+= 1 }
    }

    func recordDecoderSession(summary: String) {
        lock.withLock { state.decoderSessionSummary = summary }
    }

    func recordDecoderOutputQueued(outstanding: Int) {
        lock.withLock {
            state.maximumOutstandingDecoderOutputs = max(
                state.maximumOutstandingDecoderOutputs,
                outstanding
            )
        }
    }

    func recordDecodeSubmissionDepth(_ depth: Int) {
        lock.withLock {
            state.maximumDecodeSubmissionDepth = max(
                state.maximumDecodeSubmissionDepth,
                max(0, depth)
            )
        }
    }

    func recordFramesBeingDecoded(_ count: Int) {
        lock.withLock {
            state.maximumFramesBeingDecoded = max(
                state.maximumFramesBeingDecoded,
                max(0, count)
            )
        }
    }

    func recordVideoDecodeSubmission(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.withLock {
            state.videoDecodeSubmissionCount &+= 1
            state.totalVideoDecodeSubmissionMilliseconds += milliseconds
            state.maximumVideoDecodeSubmissionMilliseconds = max(
                state.maximumVideoDecodeSubmissionMilliseconds,
                milliseconds
            )
        }
    }

    func recordPresentationCompletion(
        generation: MediaGeneration,
        activeGeneration: MediaGeneration,
        isUniquePresentation: Bool,
        presentationTimeStamp: CMTime,
        targetMediaTime: CMTime
    ) {
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            guard generation == activeGeneration else {
                state.crossGenerationPresentationCount &+= 1
                return
            }
            guard isUniquePresentation else { return }
            state.presentationTimes.append(timestamp)
            state.presentedVideoFrames &+= 1
            guard timestamp >= state.avDriftGraceUntil,
                  presentationTimeStamp.isNumeric,
                  targetMediaTime.isNumeric else { return }
            let drift = abs(CMTimeSubtract(presentationTimeStamp, targetMediaTime).seconds * 1_000)
            guard drift.isFinite else { return }
            state.avDrifts.append(TimedValue(timestamp: timestamp, value: drift))
            state.maximumAbsoluteAVDriftMilliseconds = max(
                state.maximumAbsoluteAVDriftMilliseconds,
                drift
            )
        }
    }

    func recordYADIFKernelDispatch(inFlightCount: Int, inputDepth: Int) {
        lock.withLock {
            state.yadifKernelDispatchCount &+= 1
            recordYADIFDepthsLocked(inFlightCount: inFlightCount, inputDepth: inputDepth)
        }
    }

    func recordYADIFDepths(inFlightCount: Int, inputDepth: Int) {
        lock.withLock {
            recordYADIFDepthsLocked(inFlightCount: inFlightCount, inputDepth: inputDepth)
        }
    }

    func recordPresentationQueueDepth(_ depth: Int) {
        lock.withLock {
            state.maximumPresentationQueueDepth = max(
                state.maximumPresentationQueueDepth,
                max(0, depth)
            )
        }
    }

    func recordStaleGenerationDrop() {
        lock.withLock { state.staleGenerationDropCount &+= 1 }
    }

    func recordVideoDecodeFailure(kind: String, status: Int32) {
        lock.withLock { state.lastVideoDecodeFailure = "\(kind):\(status)" }
    }

    func recordVideoDrop(count: Int = 1, source: VideoDropSource) {
        let amount = UInt64(max(0, count))
        lock.withLock {
            state.droppedVideoFrames &+= amount
            state.videoDropCountsBySource[source.rawValue] &+= amount
        }
    }

    func beginAVDriftGracePeriod(seconds: TimeInterval) {
        let graceUntil = now() + max(0, seconds)
        lock.withLock { state.avDriftGraceUntil = max(state.avDriftGraceUntil, graceUntil) }
    }

    func recordGPUDuration(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.gpuDurations.append(TimedValue(timestamp: timestamp, value: milliseconds))
        }
    }

    func snapshot(window requestedWindow: Duration) -> PlaybackMetricsSnapshot {
        let timestamp = now()
        let requestedSeconds = max(0, Self.seconds(requestedWindow))
        let elapsed = max(0, timestamp - startedAt)
        let retainedRequestedSeconds = min(requestedSeconds, Self.retainedWindowSeconds)
        let windowSeconds = min(retainedRequestedSeconds, elapsed)
        let cutoff = timestamp - retainedRequestedSeconds
        let captured = lock.withLock { () -> State in
            pruneIfNeeded(at: timestamp)
            return state
        }
        let decoderCount = captured.decoderCallbackTimes.lazy.filter { $0 >= cutoff }.count
        let presentationCount = captured.presentationTimes.lazy.filter { $0 >= cutoff }.count
        let gpu = captured.gpuDurations.lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let drift = captured.avDrifts.lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let rateDivisor = windowSeconds > 0 ? windowSeconds : 1
        return PlaybackMetricsSnapshot(
            scanType: captured.scanType,
            activeRoute: captured.activeRoute,
            decoderCallbacksPerSecond: Double(decoderCount) / rateDivisor,
            presentationsPerSecond: Double(presentationCount) / rateDivisor,
            yadifKernelDispatchCount: captured.yadifKernelDispatchCount,
            staleGenerationDropCount: captured.staleGenerationDropCount,
            droppedVideoFrames: captured.droppedVideoFrames,
            videoDropCountsBySource: captured.videoDropCountsBySource,
            lastVideoDecodeFailure: captured.lastVideoDecodeFailure,
            maximumPresentationQueueDepth: captured.maximumPresentationQueueDepth,
            maximumYADIFInFlightCount: captured.maximumYADIFInFlightCount,
            maximumYADIFInputDepth: captured.maximumYADIFInputDepth,
            gpuDurationP95Milliseconds: Self.percentile95(Array(gpu)),
            avDriftP95Milliseconds: Self.percentile95(Array(drift)),
            residentMemoryBytes: residentMemoryProvider(),
            elapsedSeconds: elapsed,
            windowDurationSeconds: windowSeconds,
            presentedVideoFrames: captured.presentedVideoFrames,
            maximumAbsoluteAVDriftMilliseconds: captured.maximumAbsoluteAVDriftMilliseconds,
            crossGenerationPresentationCount: captured.crossGenerationPresentationCount,
            audioRoute: captured.audioRoute,
            audioReady: captured.audioReady,
            readinessOpen: captured.readinessOpen,
            retainedAudioCount: captured.retainedAudioCount,
            retainedVideoCount: captured.retainedVideoCount,
            audioFirstPTSSeconds: captured.audioFirstPTSSeconds,
            audioDurationSeconds: captured.audioDurationSeconds,
            videoFirstPTSSeconds: captured.videoFirstPTSSeconds,
            videoLatestPTSSeconds: captured.videoLatestPTSSeconds,
            audioRelativeVideoPruneCount: captured.audioRelativeVideoPruneCount,
            readinessCycleID: captured.readinessCycleID,
            readinessCloseReasonCounts: captured.readinessCloseReasonCounts,
            displayResumeCount: captured.displayResumeCount,
            clockTimeSeconds: captured.clockTimeSeconds,
            videoResyncCount: captured.videoResyncCount,
            audioRecoveryCount: captured.audioRecoveryCount,
            renderTickCount: captured.renderTickCount,
            renderSkippedInFlightCount: captured.renderSkippedInFlightCount,
            demuxQueueFullWaitSeconds: Double(captured.demuxQueueFullWaitNanoseconds) / 1_000_000_000,
            demuxAdmitWaitSeconds: Double(captured.demuxAdmitWaitNanoseconds) / 1_000_000_000,
            playbackExecutorBusySeconds:
                Double(captured.playbackExecutorBusyNanoseconds) / 1_000_000_000,
            demuxPacketCount: captured.demuxPacketCount,
            videoAccessUnitCount: captured.videoAccessUnitCount,
            audioSampleCount: captured.audioSampleCount,
            videoDecodeSubmissionCount: captured.videoDecodeSubmissionCount,
            maximumVideoDecodeSubmissionMilliseconds:
                captured.maximumVideoDecodeSubmissionMilliseconds,
            totalVideoDecodeSubmissionMilliseconds:
                captured.totalVideoDecodeSubmissionMilliseconds,
            maximumOutstandingDecoderOutputs: captured.maximumOutstandingDecoderOutputs,
            maximumDecodeSubmissionDepth: captured.maximumDecodeSubmissionDepth,
            maximumFramesBeingDecoded: captured.maximumFramesBeingDecoded,
            decoderSessionSummary: captured.decoderSessionSummary
        )
    }

    private func recordYADIFDepthsLocked(inFlightCount: Int, inputDepth: Int) {
        state.maximumYADIFInFlightCount = max(
            state.maximumYADIFInFlightCount,
            max(0, inFlightCount)
        )
        state.maximumYADIFInputDepth = max(state.maximumYADIFInputDepth, max(0, inputDepth))
    }

    private func pruneIfNeeded(at timestamp: TimeInterval) {
        guard timestamp - state.lastPrunedAt >= 1 else { return }
        let cutoff = timestamp - Self.retainedWindowSeconds
        state.decoderCallbackTimes.removeAll { $0 < cutoff }
        state.presentationTimes.removeAll { $0 < cutoff }
        state.gpuDurations.removeAll { $0.timestamp < cutoff }
        state.avDrifts.removeAll { $0.timestamp < cutoff }
        state.lastPrunedAt = timestamp
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private static func numericSeconds(_ time: CMTime?) -> Double? {
        guard let time, time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : nil
    }

    private static func name(for scanType: ScanType) -> String {
        switch scanType {
        case .unknown: "unknown"
        case .progressive: "progressive"
        case .interlaced: "interlaced"
        case .progressiveSegmentedFrame: "progressiveSegmentedFrame"
        }
    }

    private static func name(for route: DeinterlaceRoute) -> String {
        switch route {
        case .rawWhileClassifying: "rawWhileClassifying"
        case .bypass: "bypass"
        case .metalYADIF2x: "metalYADIF2x"
        }
    }

    private static func readResidentMemory() -> UInt64 {
        #if DEBUG
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
        #else
        return 0
        #endif
    }
}
