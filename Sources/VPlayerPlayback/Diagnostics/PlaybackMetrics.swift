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
}

struct PlaybackDiagnosticsChannelID: Sendable, Equatable {
    let value: String

    init(rawValue: String) {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        value = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
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

    func recordDecoderCallback() {
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.decoderCallbackTimes.append(timestamp)
        }
    }

    func recordPresentation(
        generation: MediaGeneration,
        activeGeneration: MediaGeneration,
        presentationTimeStamp: CMTime,
        targetMediaTime: CMTime,
        droppedFrames: Int,
        presentationQueueDepth: Int
    ) {
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.presentationTimes.append(timestamp)
            state.presentedVideoFrames &+= 1
            state.droppedVideoFrames &+= UInt64(max(0, droppedFrames))
            state.maximumPresentationQueueDepth = max(
                state.maximumPresentationQueueDepth,
                max(0, presentationQueueDepth)
            )
            if generation != activeGeneration {
                state.crossGenerationPresentationCount &+= 1
            }
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

    func beginGPUOperation() -> TimeInterval {
        now()
    }

    func recordGPUDuration(startedAt: TimeInterval) {
        recordGPUDuration(milliseconds: max(0, now() - startedAt) * 1_000)
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
            crossGenerationPresentationCount: captured.crossGenerationPresentationCount
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
