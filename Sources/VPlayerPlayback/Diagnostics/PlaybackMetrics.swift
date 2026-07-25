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

public struct PlaybackMetricsSnapshot: Codable, Sendable, Equatable {
    public let scanType: String
    public let selectedAlgorithm: DeinterlaceAlgorithm
    public let activeRoute: String
    public let decoderCallbacksPerSecond: Double
    public let presentationsPerSecond: Double
    public let yadifKernelDispatchCount: UInt64
    public let temporalPropertySetCount: UInt64
    public let temporalDecodeFlagCount: UInt64
    public let staleGenerationDropCount: UInt64
    public let droppedVideoFrames: UInt64
    public let maximumPresentationQueueDepth: Int
    public let maximumYADIFInFlightCount: Int
    public let maximumYADIFInputDepth: Int
    public let gpuDurationP95Milliseconds: Double
    public let avDriftP95Milliseconds: Double
    public let residentMemoryBytes: UInt64
    public let automaticAlgorithmSwitchCount: UInt64
    public let elapsedSeconds: Double
    public let windowDurationSeconds: Double
    public let presentedVideoFrames: UInt64
    public let maximumAbsoluteAVDriftMilliseconds: Double
    public let temporalUnavailableNoticeCount: UInt64
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
    public let demuxPacketCount: UInt64
    public let videoAccessUnitCount: UInt64
    public let audioSampleCount: UInt64
    public let videoDecodeSubmissionCount: UInt64
    public let maximumVideoDecodeSubmissionMilliseconds: Double
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
        var selectedAlgorithm: DeinterlaceAlgorithm
        var activeRoute = "rawWhileClassifying"
        var decoderCallbackTimes: [TimeInterval] = []
        var presentationTimes: [TimeInterval] = []
        var gpuDurations: [TimedValue] = []
        var avDrifts: [TimedValue] = []
        var yadifKernelDispatchCount: UInt64 = 0
        var temporalPropertySetCount: UInt64 = 0
        var temporalDecodeFlagCount: UInt64 = 0
        var staleGenerationDropCount: UInt64 = 0
        var droppedVideoFrames: UInt64 = 0
        var maximumPresentationQueueDepth = 0
        var maximumYADIFInFlightCount = 0
        var maximumYADIFInputDepth = 0
        var presentedVideoFrames: UInt64 = 0
        var maximumAbsoluteAVDriftMilliseconds = 0.0
        var temporalUnavailableNoticeCount: UInt64 = 0
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
        var demuxPacketCount: UInt64 = 0
        var videoAccessUnitCount: UInt64 = 0
        var audioSampleCount: UInt64 = 0
        var videoDecodeSubmissionCount: UInt64 = 0
        var maximumVideoDecodeSubmissionMilliseconds = 0.0
        var avDriftGraceUntil: TimeInterval = 0
        var lastPrunedAt: TimeInterval

        init(selectedAlgorithm: DeinterlaceAlgorithm, startedAt: TimeInterval) {
            self.selectedAlgorithm = selectedAlgorithm
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
        selectedAlgorithm: DeinterlaceAlgorithm,
        channelID: String,
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
        residentMemoryProvider: @escaping ResidentMemoryProvider = PlaybackMetrics.readResidentMemory
    ) {
        self.now = now
        self.residentMemoryProvider = residentMemoryProvider
        channelIdentifier = PlaybackDiagnosticsChannelID(rawValue: channelID)
        let startedAt = now()
        self.startedAt = startedAt
        state = State(selectedAlgorithm: selectedAlgorithm, startedAt: startedAt)
    }

    func update(scanType: ScanType) {
        lock.withLock { state.scanType = Self.name(for: scanType) }
    }

    func update(selectedAlgorithm: DeinterlaceAlgorithm) {
        lock.withLock { state.selectedAlgorithm = selectedAlgorithm }
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

    func recordVideoDecodeSubmission(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.withLock {
            state.videoDecodeSubmissionCount &+= 1
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

    func recordTemporalPropertySet(count: Int = 1) {
        lock.withLock { state.temporalPropertySetCount &+= UInt64(max(0, count)) }
    }

    func recordTemporalDecodeFlag() {
        lock.withLock { state.temporalDecodeFlagCount &+= 1 }
    }

    func recordStaleGenerationDrop() {
        lock.withLock { state.staleGenerationDropCount &+= 1 }
    }

    func recordVideoDrop(count: Int = 1) {
        lock.withLock { state.droppedVideoFrames &+= UInt64(max(0, count)) }
    }

    func recordTemporalUnavailableNotice() {
        lock.withLock { state.temporalUnavailableNoticeCount &+= 1 }
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
            selectedAlgorithm: captured.selectedAlgorithm,
            activeRoute: captured.activeRoute,
            decoderCallbacksPerSecond: Double(decoderCount) / rateDivisor,
            presentationsPerSecond: Double(presentationCount) / rateDivisor,
            yadifKernelDispatchCount: captured.yadifKernelDispatchCount,
            temporalPropertySetCount: captured.temporalPropertySetCount,
            temporalDecodeFlagCount: captured.temporalDecodeFlagCount,
            staleGenerationDropCount: captured.staleGenerationDropCount,
            droppedVideoFrames: captured.droppedVideoFrames,
            maximumPresentationQueueDepth: captured.maximumPresentationQueueDepth,
            maximumYADIFInFlightCount: captured.maximumYADIFInFlightCount,
            maximumYADIFInputDepth: captured.maximumYADIFInputDepth,
            gpuDurationP95Milliseconds: Self.percentile95(Array(gpu)),
            avDriftP95Milliseconds: Self.percentile95(Array(drift)),
            residentMemoryBytes: residentMemoryProvider(),
            automaticAlgorithmSwitchCount: 0,
            elapsedSeconds: elapsed,
            windowDurationSeconds: windowSeconds,
            presentedVideoFrames: captured.presentedVideoFrames,
            maximumAbsoluteAVDriftMilliseconds: captured.maximumAbsoluteAVDriftMilliseconds,
            temporalUnavailableNoticeCount: captured.temporalUnavailableNoticeCount,
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
            demuxPacketCount: captured.demuxPacketCount,
            videoAccessUnitCount: captured.videoAccessUnitCount,
            audioSampleCount: captured.audioSampleCount,
            videoDecodeSubmissionCount: captured.videoDecodeSubmissionCount,
            maximumVideoDecodeSubmissionMilliseconds:
                captured.maximumVideoDecodeSubmissionMilliseconds
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
        case .rawTemporalFailure: "rawTemporalFailure"
        case .bypass: "bypass"
        case .appleTemporal: "appleTemporal"
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
