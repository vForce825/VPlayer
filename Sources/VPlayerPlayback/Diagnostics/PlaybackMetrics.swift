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
    public let yadifKernelDispatchCount: UInt64
    public let staleGenerationDropCount: UInt64
    public let droppedVideoFrames: UInt64
    // Indexed by `VideoDropSource.rawValue`.
    public let videoDropCountsBySource: [UInt64]
    // Sanitized classification and status of the most recent decode failure,
    // e.g. "badData:-12909". A drop total cannot say which fault is repeating.
    public let lastVideoDecodeFailure: String?
    public let maximumYADIFInFlightCount: Int
    public let maximumYADIFInputDepth: Int
    public let gpuDurationP95Milliseconds: Double
    public let yadifCPUEncodeP95Milliseconds: Double
    public let residentMemoryBytes: UInt64
    public let elapsedSeconds: Double
    public let windowDurationSeconds: Double
    public let audioRoute: String
    public let audioReady: Bool
    public let readinessOpen: Bool
    public let retainedAudioCount: Int
    public let retainedVideoCount: Int
    // Indexed by `AudioContinuityDropReason.slot` with an exact, bounded
    // entry for every reason in the enum domain.
    public internal(set) var audioContinuityDropCountsByReason: [UInt64]
    public let audioShortGapCount: UInt64
    public let audioLargeGapCount: UInt64
    public let audioContinuityIslandSwitchCount: UInt64
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
    // pause, discontinuity, audioReplacement, displayModeSwitch, audioGap.
    public let readinessCloseReasonCounts: [UInt64]
    // How many times display submission has been resumed for an open gate. If
    // this stops advancing while frames keep arriving, the submission side is
    // stranded rather than the decode side.
    public let displayResumeCount: UInt64
    // Native counters sampled from the exact AVSampleBufferVideoRenderer that
    // is attached to the visible display layer.
    public let videoRendererMetricsSampleCount: UInt64
    public let videoRendererMetricsEpochCount: UInt64
    public let videoRendererTotalFrameCount: UInt64
    public let videoRendererDroppedFrameCount: UInt64
    public let videoRendererCorruptedFrameCount: UInt64
    public let videoRendererOptimizedFrameCount: UInt64
    public let videoRendererAccumulatedFrameDelayMilliseconds: Double
    // Media time the playback clock currently reports. Compared against
    // `videoLatestPTSSeconds` this separates "the clock is not running" from
    // "frames are not reaching the presentation queue".
    public let clockTimeSeconds: Double?
    // Times the pipeline re-anchored because the clock had outrun the decoder.
    public let videoResyncCount: UInt64
    // Audio renderer recoveries (flush + full replay re-enqueue). Each one is
    // expensive on the playback executor, so a high rate starves ingest.
    public let audioRecoveryCount: UInt64
    public let audioAutomaticFlushTriggerCount: UInt64
    public let audioOutputConfigurationTriggerCount: UInt64
    public let audioRouteChangeTriggerCount: UInt64
    public let audioRecoveryTransactionCount: UInt64
    public let audioSuppressedCorrelatedTriggerCount: UInt64
    public let audioCompressedRendererRetryCount: UInt64
    public let audioPCMFallbackCount: UInt64
    public let audioLastFallbackReason: AudioFallbackReason?
    public let audioStartupWaitingSeconds: Double
    public let audioRendererReady: Bool
    public let audioRendererSufficient: Bool
    public let audioActiveCodec: AudioCodec?
    public let audioFormatFingerprint: AudioFormatFingerprintDiagnostic?
    public let audioOutputCategory: AudioDiagnosticOutputCategory
    public let audioRouteRevision: UInt64
    public let audioMediaGeneration: MediaGeneration?
    public let audioLastCompressedRendererFailure: AudioRendererFailureDiagnostic?
    public let audioAcceptedCompressedMediaDurationSeconds: Double
    public let audioPendingSampleCount: Int
    public let audioRendererRequestArmed: Bool
    public let audioRendererBackpressureCount: UInt64
    public let audioRendererRequestRearmCount: UInt64
    public let audioAutomaticFlushNoProgressCount: UInt64
    public let audioLastAcceptedPTSSeconds: Double?
    public let audioLastRendererProgressAgeSeconds: Double?
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
    // Submission start to the decoder's output callback for the same frame.
    // Read against the submission's own duration: equal means the decode ran
    // inside the call and the wall time is compute, much longer means the call
    // blocked on something else and the decode followed.
    public let decodeCallbackLatencyP95Milliseconds: Double
    // Same distribution point as the latency above, so the two are comparable.
    public let videoDecodeSubmissionP95Milliseconds: Double
}

private struct PlaybackMetricsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

enum PlaybackMetricsBoundedReasonCounts {
    static func decode(
        declaredCount: Int?,
        expectedCount: Int,
        next: () throws -> UInt64
    ) throws -> [UInt64] {
        let zeros = [UInt64](repeating: 0, count: max(0, expectedCount))
        guard expectedCount >= 0, declaredCount == expectedCount else {
            return zeros
        }
        var result: [UInt64] = []
        result.reserveCapacity(expectedCount)
        do {
            for _ in 0..<expectedCount {
                result.append(try next())
            }
        } catch {
            return zeros
        }
        return result
    }
}

enum PlaybackDiagnosticSaturatingCounter {
    static func increment(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }

    static func add(_ amount: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        value = overflow ? UInt64.max : sum
    }
}

public extension PlaybackMetricsSnapshot {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PlaybackMetricsCodingKey.self)
        scanType = try container.decode(String.self, forKey: .init("scanType"))
        activeRoute = try container.decode(String.self, forKey: .init("activeRoute"))
        decoderCallbacksPerSecond = try container.decode(Double.self, forKey: .init("decoderCallbacksPerSecond"))
        yadifKernelDispatchCount = try container.decode(UInt64.self, forKey: .init("yadifKernelDispatchCount"))
        staleGenerationDropCount = try container.decode(UInt64.self, forKey: .init("staleGenerationDropCount"))
        droppedVideoFrames = try container.decode(UInt64.self, forKey: .init("droppedVideoFrames"))
        videoDropCountsBySource = try container.decode([UInt64].self, forKey: .init("videoDropCountsBySource"))
        lastVideoDecodeFailure = try container.decodeIfPresent(String.self, forKey: .init("lastVideoDecodeFailure"))
        maximumYADIFInFlightCount = try container.decode(Int.self, forKey: .init("maximumYADIFInFlightCount"))
        maximumYADIFInputDepth = try container.decode(Int.self, forKey: .init("maximumYADIFInputDepth"))
        gpuDurationP95Milliseconds = try container.decode(Double.self, forKey: .init("gpuDurationP95Milliseconds"))
        yadifCPUEncodeP95Milliseconds = try container.decode(Double.self, forKey: .init("yadifCPUEncodeP95Milliseconds"))
        residentMemoryBytes = try container.decode(UInt64.self, forKey: .init("residentMemoryBytes"))
        elapsedSeconds = try container.decode(Double.self, forKey: .init("elapsedSeconds"))
        windowDurationSeconds = try container.decode(Double.self, forKey: .init("windowDurationSeconds"))
        audioRoute = try container.decode(String.self, forKey: .init("audioRoute"))
        audioReady = try container.decode(Bool.self, forKey: .init("audioReady"))
        readinessOpen = try container.decode(Bool.self, forKey: .init("readinessOpen"))
        retainedAudioCount = try container.decode(Int.self, forKey: .init("retainedAudioCount"))
        retainedVideoCount = try container.decode(Int.self, forKey: .init("retainedVideoCount"))

        let reasonCount = AudioContinuityDropReason.slotCount
        let reasonKey = PlaybackMetricsCodingKey(
            "audioContinuityDropCountsByReason"
        )
        if container.contains(reasonKey),
           var nested = try? container.nestedUnkeyedContainer(forKey: reasonKey) {
            audioContinuityDropCountsByReason = try PlaybackMetricsBoundedReasonCounts.decode(
                declaredCount: nested.count,
                expectedCount: reasonCount,
                next: { try nested.decode(UInt64.self) }
            )
        } else {
            audioContinuityDropCountsByReason = [UInt64](
                repeating: 0,
                count: reasonCount
            )
        }
        audioShortGapCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioShortGapCount")
        ) ?? 0
        audioLargeGapCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioLargeGapCount")
        ) ?? 0
        audioContinuityIslandSwitchCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioContinuityIslandSwitchCount")
        ) ?? 0

        audioFirstPTSSeconds = try container.decodeIfPresent(Double.self, forKey: .init("audioFirstPTSSeconds"))
        audioDurationSeconds = try container.decode(Double.self, forKey: .init("audioDurationSeconds"))
        videoFirstPTSSeconds = try container.decodeIfPresent(Double.self, forKey: .init("videoFirstPTSSeconds"))
        videoLatestPTSSeconds = try container.decodeIfPresent(Double.self, forKey: .init("videoLatestPTSSeconds"))
        audioRelativeVideoPruneCount = try container.decode(UInt64.self, forKey: .init("audioRelativeVideoPruneCount"))
        readinessCycleID = try container.decode(UInt64.self, forKey: .init("readinessCycleID"))
        readinessCloseReasonCounts = try container.decode([UInt64].self, forKey: .init("readinessCloseReasonCounts"))
        displayResumeCount = try container.decode(UInt64.self, forKey: .init("displayResumeCount"))
        videoRendererMetricsSampleCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererMetricsSampleCount")
        ) ?? 0
        videoRendererMetricsEpochCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererMetricsEpochCount")
        ) ?? 0
        videoRendererTotalFrameCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererTotalFrameCount")
        ) ?? 0
        videoRendererDroppedFrameCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererDroppedFrameCount")
        ) ?? 0
        videoRendererCorruptedFrameCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererCorruptedFrameCount")
        ) ?? 0
        videoRendererOptimizedFrameCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("videoRendererOptimizedFrameCount")
        ) ?? 0
        videoRendererAccumulatedFrameDelayMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .init("videoRendererAccumulatedFrameDelayMilliseconds")
        ) ?? 0
        clockTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .init("clockTimeSeconds"))
        videoResyncCount = try container.decode(UInt64.self, forKey: .init("videoResyncCount"))
        audioRecoveryCount = try container.decode(UInt64.self, forKey: .init("audioRecoveryCount"))
        audioAutomaticFlushTriggerCount = try container.decode(UInt64.self, forKey: .init("audioAutomaticFlushTriggerCount"))
        audioOutputConfigurationTriggerCount = try container.decode(UInt64.self, forKey: .init("audioOutputConfigurationTriggerCount"))
        audioRouteChangeTriggerCount = try container.decode(UInt64.self, forKey: .init("audioRouteChangeTriggerCount"))
        audioRecoveryTransactionCount = try container.decode(UInt64.self, forKey: .init("audioRecoveryTransactionCount"))
        audioSuppressedCorrelatedTriggerCount = try container.decode(UInt64.self, forKey: .init("audioSuppressedCorrelatedTriggerCount"))
        audioCompressedRendererRetryCount = try container.decode(UInt64.self, forKey: .init("audioCompressedRendererRetryCount"))
        audioPCMFallbackCount = try container.decode(UInt64.self, forKey: .init("audioPCMFallbackCount"))
        audioLastFallbackReason = try container.decodeIfPresent(AudioFallbackReason.self, forKey: .init("audioLastFallbackReason"))
        audioStartupWaitingSeconds = try container.decode(Double.self, forKey: .init("audioStartupWaitingSeconds"))
        audioRendererReady = try container.decode(Bool.self, forKey: .init("audioRendererReady"))
        audioRendererSufficient = try container.decode(Bool.self, forKey: .init("audioRendererSufficient"))
        audioActiveCodec = try container.decodeIfPresent(AudioCodec.self, forKey: .init("audioActiveCodec"))
        audioFormatFingerprint = try container.decodeIfPresent(AudioFormatFingerprintDiagnostic.self, forKey: .init("audioFormatFingerprint"))
        audioOutputCategory = try container.decode(AudioDiagnosticOutputCategory.self, forKey: .init("audioOutputCategory"))
        audioRouteRevision = try container.decode(UInt64.self, forKey: .init("audioRouteRevision"))
        audioMediaGeneration = try container.decodeIfPresent(MediaGeneration.self, forKey: .init("audioMediaGeneration"))
        audioLastCompressedRendererFailure = try container.decodeIfPresent(AudioRendererFailureDiagnostic.self, forKey: .init("audioLastCompressedRendererFailure"))
        audioAcceptedCompressedMediaDurationSeconds = try container.decode(Double.self, forKey: .init("audioAcceptedCompressedMediaDurationSeconds"))

        audioPendingSampleCount = max(0, try container.decodeIfPresent(
            Int.self,
            forKey: .init("audioPendingSampleCount")
        ) ?? 0)
        audioRendererRequestArmed = try container.decodeIfPresent(
            Bool.self,
            forKey: .init("audioRendererRequestArmed")
        ) ?? false
        audioRendererBackpressureCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioRendererBackpressureCount")
        ) ?? 0
        audioRendererRequestRearmCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioRendererRequestRearmCount")
        ) ?? 0
        audioAutomaticFlushNoProgressCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .init("audioAutomaticFlushNoProgressCount")
        ) ?? 0
        audioLastAcceptedPTSSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .init("audioLastAcceptedPTSSeconds")
        )
        audioLastRendererProgressAgeSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .init("audioLastRendererProgressAgeSeconds")
        )

        demuxQueueFullWaitSeconds = try container.decode(Double.self, forKey: .init("demuxQueueFullWaitSeconds"))
        demuxAdmitWaitSeconds = try container.decode(Double.self, forKey: .init("demuxAdmitWaitSeconds"))
        playbackExecutorBusySeconds = try container.decode(Double.self, forKey: .init("playbackExecutorBusySeconds"))
        demuxPacketCount = try container.decode(UInt64.self, forKey: .init("demuxPacketCount"))
        videoAccessUnitCount = try container.decode(UInt64.self, forKey: .init("videoAccessUnitCount"))
        audioSampleCount = try container.decode(UInt64.self, forKey: .init("audioSampleCount"))
        videoDecodeSubmissionCount = try container.decode(UInt64.self, forKey: .init("videoDecodeSubmissionCount"))
        maximumVideoDecodeSubmissionMilliseconds = try container.decode(Double.self, forKey: .init("maximumVideoDecodeSubmissionMilliseconds"))
        totalVideoDecodeSubmissionMilliseconds = try container.decode(Double.self, forKey: .init("totalVideoDecodeSubmissionMilliseconds"))
        maximumOutstandingDecoderOutputs = try container.decode(Int.self, forKey: .init("maximumOutstandingDecoderOutputs"))
        maximumDecodeSubmissionDepth = try container.decode(Int.self, forKey: .init("maximumDecodeSubmissionDepth"))
        maximumFramesBeingDecoded = try container.decode(Int.self, forKey: .init("maximumFramesBeingDecoded"))
        decoderSessionSummary = try container.decodeIfPresent(String.self, forKey: .init("decoderSessionSummary"))
        decodeCallbackLatencyP95Milliseconds = try container.decode(Double.self, forKey: .init("decodeCallbackLatencyP95Milliseconds"))
        videoDecodeSubmissionP95Milliseconds = try container.decode(Double.self, forKey: .init("videoDecodeSubmissionP95Milliseconds"))
    }

    func encode(to encoder: any Encoder) throws {
        let reasonCount = AudioContinuityDropReason.slotCount
        guard audioContinuityDropCountsByReason.count == reasonCount else {
            throw EncodingError.invalidValue(
                audioContinuityDropCountsByReason,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "invalid bounded audio continuity reason domain"
                )
            )
        }
        var container = encoder.container(keyedBy: PlaybackMetricsCodingKey.self)
        try container.encode(scanType, forKey: .init("scanType"))
        try container.encode(activeRoute, forKey: .init("activeRoute"))
        try container.encode(decoderCallbacksPerSecond, forKey: .init("decoderCallbacksPerSecond"))
        try container.encode(yadifKernelDispatchCount, forKey: .init("yadifKernelDispatchCount"))
        try container.encode(staleGenerationDropCount, forKey: .init("staleGenerationDropCount"))
        try container.encode(droppedVideoFrames, forKey: .init("droppedVideoFrames"))
        try container.encode(videoDropCountsBySource, forKey: .init("videoDropCountsBySource"))
        try container.encodeIfPresent(lastVideoDecodeFailure, forKey: .init("lastVideoDecodeFailure"))
        try container.encode(maximumYADIFInFlightCount, forKey: .init("maximumYADIFInFlightCount"))
        try container.encode(maximumYADIFInputDepth, forKey: .init("maximumYADIFInputDepth"))
        try container.encode(gpuDurationP95Milliseconds, forKey: .init("gpuDurationP95Milliseconds"))
        try container.encode(yadifCPUEncodeP95Milliseconds, forKey: .init("yadifCPUEncodeP95Milliseconds"))
        try container.encode(residentMemoryBytes, forKey: .init("residentMemoryBytes"))
        try container.encode(elapsedSeconds, forKey: .init("elapsedSeconds"))
        try container.encode(windowDurationSeconds, forKey: .init("windowDurationSeconds"))
        try container.encode(audioRoute, forKey: .init("audioRoute"))
        try container.encode(audioReady, forKey: .init("audioReady"))
        try container.encode(readinessOpen, forKey: .init("readinessOpen"))
        try container.encode(retainedAudioCount, forKey: .init("retainedAudioCount"))
        try container.encode(retainedVideoCount, forKey: .init("retainedVideoCount"))
        try container.encode(audioContinuityDropCountsByReason, forKey: .init("audioContinuityDropCountsByReason"))
        try container.encode(audioShortGapCount, forKey: .init("audioShortGapCount"))
        try container.encode(audioLargeGapCount, forKey: .init("audioLargeGapCount"))
        try container.encode(audioContinuityIslandSwitchCount, forKey: .init("audioContinuityIslandSwitchCount"))
        try container.encodeIfPresent(audioFirstPTSSeconds, forKey: .init("audioFirstPTSSeconds"))
        try container.encode(audioDurationSeconds, forKey: .init("audioDurationSeconds"))
        try container.encodeIfPresent(videoFirstPTSSeconds, forKey: .init("videoFirstPTSSeconds"))
        try container.encodeIfPresent(videoLatestPTSSeconds, forKey: .init("videoLatestPTSSeconds"))
        try container.encode(audioRelativeVideoPruneCount, forKey: .init("audioRelativeVideoPruneCount"))
        try container.encode(readinessCycleID, forKey: .init("readinessCycleID"))
        try container.encode(readinessCloseReasonCounts, forKey: .init("readinessCloseReasonCounts"))
        try container.encode(displayResumeCount, forKey: .init("displayResumeCount"))
        try container.encode(
            videoRendererMetricsSampleCount,
            forKey: .init("videoRendererMetricsSampleCount")
        )
        try container.encode(
            videoRendererMetricsEpochCount,
            forKey: .init("videoRendererMetricsEpochCount")
        )
        try container.encode(
            videoRendererTotalFrameCount,
            forKey: .init("videoRendererTotalFrameCount")
        )
        try container.encode(
            videoRendererDroppedFrameCount,
            forKey: .init("videoRendererDroppedFrameCount")
        )
        try container.encode(
            videoRendererCorruptedFrameCount,
            forKey: .init("videoRendererCorruptedFrameCount")
        )
        try container.encode(
            videoRendererOptimizedFrameCount,
            forKey: .init("videoRendererOptimizedFrameCount")
        )
        try container.encode(
            videoRendererAccumulatedFrameDelayMilliseconds,
            forKey: .init("videoRendererAccumulatedFrameDelayMilliseconds")
        )
        try container.encodeIfPresent(clockTimeSeconds, forKey: .init("clockTimeSeconds"))
        try container.encode(videoResyncCount, forKey: .init("videoResyncCount"))
        try container.encode(audioRecoveryCount, forKey: .init("audioRecoveryCount"))
        try container.encode(audioAutomaticFlushTriggerCount, forKey: .init("audioAutomaticFlushTriggerCount"))
        try container.encode(audioOutputConfigurationTriggerCount, forKey: .init("audioOutputConfigurationTriggerCount"))
        try container.encode(audioRouteChangeTriggerCount, forKey: .init("audioRouteChangeTriggerCount"))
        try container.encode(audioRecoveryTransactionCount, forKey: .init("audioRecoveryTransactionCount"))
        try container.encode(audioSuppressedCorrelatedTriggerCount, forKey: .init("audioSuppressedCorrelatedTriggerCount"))
        try container.encode(audioCompressedRendererRetryCount, forKey: .init("audioCompressedRendererRetryCount"))
        try container.encode(audioPCMFallbackCount, forKey: .init("audioPCMFallbackCount"))
        try container.encodeIfPresent(audioLastFallbackReason, forKey: .init("audioLastFallbackReason"))
        try container.encode(audioStartupWaitingSeconds, forKey: .init("audioStartupWaitingSeconds"))
        try container.encode(audioRendererReady, forKey: .init("audioRendererReady"))
        try container.encode(audioRendererSufficient, forKey: .init("audioRendererSufficient"))
        try container.encodeIfPresent(audioActiveCodec, forKey: .init("audioActiveCodec"))
        try container.encodeIfPresent(audioFormatFingerprint, forKey: .init("audioFormatFingerprint"))
        try container.encode(audioOutputCategory, forKey: .init("audioOutputCategory"))
        try container.encode(audioRouteRevision, forKey: .init("audioRouteRevision"))
        try container.encodeIfPresent(audioMediaGeneration, forKey: .init("audioMediaGeneration"))
        try container.encodeIfPresent(audioLastCompressedRendererFailure, forKey: .init("audioLastCompressedRendererFailure"))
        try container.encode(audioAcceptedCompressedMediaDurationSeconds, forKey: .init("audioAcceptedCompressedMediaDurationSeconds"))
        try container.encode(audioPendingSampleCount, forKey: .init("audioPendingSampleCount"))
        try container.encode(audioRendererRequestArmed, forKey: .init("audioRendererRequestArmed"))
        try container.encode(audioRendererBackpressureCount, forKey: .init("audioRendererBackpressureCount"))
        try container.encode(audioRendererRequestRearmCount, forKey: .init("audioRendererRequestRearmCount"))
        try container.encode(audioAutomaticFlushNoProgressCount, forKey: .init("audioAutomaticFlushNoProgressCount"))
        try container.encodeIfPresent(audioLastAcceptedPTSSeconds, forKey: .init("audioLastAcceptedPTSSeconds"))
        try container.encodeIfPresent(audioLastRendererProgressAgeSeconds, forKey: .init("audioLastRendererProgressAgeSeconds"))
        try container.encode(demuxQueueFullWaitSeconds, forKey: .init("demuxQueueFullWaitSeconds"))
        try container.encode(demuxAdmitWaitSeconds, forKey: .init("demuxAdmitWaitSeconds"))
        try container.encode(playbackExecutorBusySeconds, forKey: .init("playbackExecutorBusySeconds"))
        try container.encode(demuxPacketCount, forKey: .init("demuxPacketCount"))
        try container.encode(videoAccessUnitCount, forKey: .init("videoAccessUnitCount"))
        try container.encode(audioSampleCount, forKey: .init("audioSampleCount"))
        try container.encode(videoDecodeSubmissionCount, forKey: .init("videoDecodeSubmissionCount"))
        try container.encode(maximumVideoDecodeSubmissionMilliseconds, forKey: .init("maximumVideoDecodeSubmissionMilliseconds"))
        try container.encode(totalVideoDecodeSubmissionMilliseconds, forKey: .init("totalVideoDecodeSubmissionMilliseconds"))
        try container.encode(maximumOutstandingDecoderOutputs, forKey: .init("maximumOutstandingDecoderOutputs"))
        try container.encode(maximumDecodeSubmissionDepth, forKey: .init("maximumDecodeSubmissionDepth"))
        try container.encode(maximumFramesBeingDecoded, forKey: .init("maximumFramesBeingDecoded"))
        try container.encodeIfPresent(decoderSessionSummary, forKey: .init("decoderSessionSummary"))
        try container.encode(decodeCallbackLatencyP95Milliseconds, forKey: .init("decodeCallbackLatencyP95Milliseconds"))
        try container.encode(videoDecodeSubmissionP95Milliseconds, forKey: .init("videoDecodeSubmissionP95Milliseconds"))
    }

    internal func uncheckedReplacingAudioContinuityDropCountsByReason(
        _ counts: [UInt64]
    ) -> Self {
        var copy = self
        copy.audioContinuityDropCountsByReason = counts
        return copy
    }
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
        var gpuDurations: [TimedValue] = []
        var yadifCPUEncodeDurations: [TimedValue] = []
        var decodeCallbackLatencies: [TimedValue] = []
        var decodeSubmissions: [TimedValue] = []
        var yadifKernelDispatchCount: UInt64 = 0
        var staleGenerationDropCount: UInt64 = 0
        var droppedVideoFrames: UInt64 = 0
        var videoDropCountsBySource = [UInt64](
            repeating: 0, count: VideoDropSource.allCases.count
        )
        var lastVideoDecodeFailure: String?
        var maximumYADIFInFlightCount = 0
        var maximumYADIFInputDepth = 0
        var audioRoute = "systemCompressed"
        var audioReady = false
        var readinessOpen = false
        var retainedAudioCount = 0
        var retainedVideoCount = 0
        var audioContinuityDropCountsByReason = [UInt64](
            repeating: 0,
            count: AudioContinuityDropReason.slotCount
        )
        var audioShortGapCount: UInt64 = 0
        var audioLargeGapCount: UInt64 = 0
        var audioContinuityIslandSwitchCount: UInt64 = 0
        var audioFirstPTSSeconds: Double?
        var audioDurationSeconds = 0.0
        var videoFirstPTSSeconds: Double?
        var videoLatestPTSSeconds: Double?
        var audioRelativeVideoPruneCount: UInt64 = 0
        var readinessCycleID: UInt64 = 0
        var readinessCloseReasonCounts = [UInt64](
            repeating: 0,
            count: PlaybackReadinessCloseReason.allCases.count
        )
        var displayResumeCount: UInt64 = 0
        var videoRendererPerformanceBaseline: VideoRendererPerformanceSnapshot?
        var videoRendererMetricsSampleCount: UInt64 = 0
        var videoRendererMetricsEpochCount: UInt64 = 0
        var videoRendererTotalFrameCount: UInt64 = 0
        var videoRendererDroppedFrameCount: UInt64 = 0
        var videoRendererCorruptedFrameCount: UInt64 = 0
        var videoRendererOptimizedFrameCount: UInt64 = 0
        var videoRendererAccumulatedFrameDelaySeconds = 0.0
        var clockTimeSeconds: Double?
        var videoResyncCount: UInt64 = 0
        var audioRecoveryCount: UInt64 = 0
        var audioDiagnostics = AudioRenderDiagnostics.zero
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
        var lastPrunedAt: TimeInterval

        init(startedAt: TimeInterval) {
            lastPrunedAt = startedAt
        }
    }

    private static let retainedWindowSeconds: TimeInterval = 120
    private static let maximumAccumulatedFrameDelaySeconds =
        Double.greatestFiniteMagnitude / 1_000
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
        audioRecoveryCount: UInt64 = 0,
        audioDiagnostics: AudioRenderDiagnostics = .zero,
        audioContinuityDropCountsByReason: [UInt64] = [],
        audioShortGapCount: UInt64 = 0,
        audioLargeGapCount: UInt64 = 0,
        audioContinuityIslandSwitchCount: UInt64 = 0
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
            state.audioDiagnostics = audioDiagnostics
            let reasonCount = AudioContinuityDropReason.slotCount
            if audioContinuityDropCountsByReason.isEmpty {
                // Callers compiled before continuity diagnostics keep the
                // collector's current bounded counters.
            } else if audioContinuityDropCountsByReason.count == reasonCount {
                state.audioContinuityDropCountsByReason =
                    audioContinuityDropCountsByReason
            } else {
                state.audioContinuityDropCountsByReason = [UInt64](
                    repeating: 0,
                    count: reasonCount
                )
            }
            state.audioShortGapCount = audioShortGapCount
            state.audioLargeGapCount = audioLargeGapCount
            state.audioContinuityIslandSwitchCount =
                audioContinuityIslandSwitchCount
        }
    }

    func updateAudioContinuityDiagnostics(
        retainedAudioCount: Int,
        dropCountsByReason: [UInt64],
        shortGapCount: UInt64,
        largeGapCount: UInt64,
        islandSwitchCount: UInt64
    ) {
        lock.withLock {
            let reasonCount = AudioContinuityDropReason.slotCount
            state.audioContinuityDropCountsByReason =
                dropCountsByReason.count == reasonCount
                ? dropCountsByReason
                : [UInt64](repeating: 0, count: reasonCount)
            state.audioShortGapCount = shortGapCount
            state.audioLargeGapCount = largeGapCount
            state.audioContinuityIslandSwitchCount = islandSwitchCount
            state.retainedAudioCount = max(0, retainedAudioCount)
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

    func update(audioDiagnostics: AudioRenderDiagnostics) {
        lock.withLock { state.audioDiagnostics = audioDiagnostics }
    }

    func recordDisplaySubmissionResume() {
        lock.withLock { state.displayResumeCount &+= 1 }
    }

    func recordVideoRendererPerformance(_ snapshot: VideoRendererPerformanceSnapshot) {
        guard snapshot.accumulatedFrameDelaySeconds.isFinite,
              snapshot.accumulatedFrameDelaySeconds >= 0 else { return }
        lock.withLock {
            PlaybackDiagnosticSaturatingCounter.increment(
                &state.videoRendererMetricsSampleCount
            )
            guard let baseline = state.videoRendererPerformanceBaseline else {
                state.videoRendererPerformanceBaseline = snapshot
                PlaybackDiagnosticSaturatingCounter.increment(
                    &state.videoRendererMetricsEpochCount
                )
                state.videoRendererTotalFrameCount = snapshot.totalFrameCount
                state.videoRendererDroppedFrameCount = snapshot.droppedFrameCount
                state.videoRendererCorruptedFrameCount = snapshot.corruptedFrameCount
                state.videoRendererOptimizedFrameCount = snapshot.optimizedFrameCount
                state.videoRendererAccumulatedFrameDelaySeconds =
                    min(
                        snapshot.accumulatedFrameDelaySeconds,
                        Self.maximumAccumulatedFrameDelaySeconds
                    )
                return
            }

            let rolledBack = snapshot.totalFrameCount < baseline.totalFrameCount
                || snapshot.droppedFrameCount < baseline.droppedFrameCount
                || snapshot.corruptedFrameCount < baseline.corruptedFrameCount
                || snapshot.optimizedFrameCount < baseline.optimizedFrameCount
                || snapshot.accumulatedFrameDelaySeconds
                    < baseline.accumulatedFrameDelaySeconds
            state.videoRendererPerformanceBaseline = snapshot
            guard !rolledBack else {
                PlaybackDiagnosticSaturatingCounter.increment(
                    &state.videoRendererMetricsEpochCount
                )
                return
            }
            PlaybackDiagnosticSaturatingCounter.add(
                snapshot.totalFrameCount - baseline.totalFrameCount,
                to: &state.videoRendererTotalFrameCount
            )
            PlaybackDiagnosticSaturatingCounter.add(
                snapshot.droppedFrameCount - baseline.droppedFrameCount,
                to: &state.videoRendererDroppedFrameCount
            )
            PlaybackDiagnosticSaturatingCounter.add(
                snapshot.corruptedFrameCount - baseline.corruptedFrameCount,
                to: &state.videoRendererCorruptedFrameCount
            )
            PlaybackDiagnosticSaturatingCounter.add(
                snapshot.optimizedFrameCount - baseline.optimizedFrameCount,
                to: &state.videoRendererOptimizedFrameCount
            )
            let accumulatedDelay = state.videoRendererAccumulatedFrameDelaySeconds
                + snapshot.accumulatedFrameDelaySeconds
                - baseline.accumulatedFrameDelaySeconds
            state.videoRendererAccumulatedFrameDelaySeconds = accumulatedDelay.isFinite
                ? min(accumulatedDelay, Self.maximumAccumulatedFrameDelaySeconds)
                : Self.maximumAccumulatedFrameDelaySeconds
        }
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
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.decodeSubmissions.append(
                TimedValue(timestamp: timestamp, value: milliseconds)
            )
            state.videoDecodeSubmissionCount &+= 1
            state.totalVideoDecodeSubmissionMilliseconds += milliseconds
            state.maximumVideoDecodeSubmissionMilliseconds = max(
                state.maximumVideoDecodeSubmissionMilliseconds,
                milliseconds
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

    func recordDecodeCallbackLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.decodeCallbackLatencies.append(
                TimedValue(timestamp: timestamp, value: milliseconds)
            )
        }
    }

    func recordGPUDuration(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.gpuDurations.append(TimedValue(timestamp: timestamp, value: milliseconds))
        }
    }

    func recordYADIFCPUEncode(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let timestamp = now()
        lock.withLock {
            pruneIfNeeded(at: timestamp)
            state.yadifCPUEncodeDurations.append(
                TimedValue(timestamp: timestamp, value: milliseconds)
            )
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
        let gpu = captured.gpuDurations.lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let yadifCPUEncode = captured.yadifCPUEncodeDurations
            .lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let decodeLatency = captured.decodeCallbackLatencies
            .lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let decodeSubmission = captured.decodeSubmissions
            .lazy.filter { $0.timestamp >= cutoff }.map(\.value)
        let rateDivisor = windowSeconds > 0 ? windowSeconds : 1
        return PlaybackMetricsSnapshot(
            scanType: captured.scanType,
            activeRoute: captured.activeRoute,
            decoderCallbacksPerSecond: Double(decoderCount) / rateDivisor,
            yadifKernelDispatchCount: captured.yadifKernelDispatchCount,
            staleGenerationDropCount: captured.staleGenerationDropCount,
            droppedVideoFrames: captured.droppedVideoFrames,
            videoDropCountsBySource: captured.videoDropCountsBySource,
            lastVideoDecodeFailure: captured.lastVideoDecodeFailure,
            maximumYADIFInFlightCount: captured.maximumYADIFInFlightCount,
            maximumYADIFInputDepth: captured.maximumYADIFInputDepth,
            gpuDurationP95Milliseconds: Self.percentile95(Array(gpu)),
            yadifCPUEncodeP95Milliseconds: Self.percentile95(Array(yadifCPUEncode)),
            residentMemoryBytes: residentMemoryProvider(),
            elapsedSeconds: elapsed,
            windowDurationSeconds: windowSeconds,
            audioRoute: captured.audioRoute,
            audioReady: captured.audioReady,
            readinessOpen: captured.readinessOpen,
            retainedAudioCount: captured.retainedAudioCount,
            retainedVideoCount: captured.retainedVideoCount,
            audioContinuityDropCountsByReason:
                captured.audioContinuityDropCountsByReason,
            audioShortGapCount: captured.audioShortGapCount,
            audioLargeGapCount: captured.audioLargeGapCount,
            audioContinuityIslandSwitchCount:
                captured.audioContinuityIslandSwitchCount,
            audioFirstPTSSeconds: captured.audioFirstPTSSeconds,
            audioDurationSeconds: captured.audioDurationSeconds,
            videoFirstPTSSeconds: captured.videoFirstPTSSeconds,
            videoLatestPTSSeconds: captured.videoLatestPTSSeconds,
            audioRelativeVideoPruneCount: captured.audioRelativeVideoPruneCount,
            readinessCycleID: captured.readinessCycleID,
            readinessCloseReasonCounts: captured.readinessCloseReasonCounts,
            displayResumeCount: captured.displayResumeCount,
            videoRendererMetricsSampleCount:
                captured.videoRendererMetricsSampleCount,
            videoRendererMetricsEpochCount:
                captured.videoRendererMetricsEpochCount,
            videoRendererTotalFrameCount:
                captured.videoRendererTotalFrameCount,
            videoRendererDroppedFrameCount:
                captured.videoRendererDroppedFrameCount,
            videoRendererCorruptedFrameCount:
                captured.videoRendererCorruptedFrameCount,
            videoRendererOptimizedFrameCount:
                captured.videoRendererOptimizedFrameCount,
            videoRendererAccumulatedFrameDelayMilliseconds:
                captured.videoRendererAccumulatedFrameDelaySeconds * 1_000,
            clockTimeSeconds: captured.clockTimeSeconds,
            videoResyncCount: captured.videoResyncCount,
            audioRecoveryCount: captured.audioRecoveryCount,
            audioAutomaticFlushTriggerCount:
                captured.audioDiagnostics.automaticFlushTriggerCount,
            audioOutputConfigurationTriggerCount:
                captured.audioDiagnostics.outputConfigurationTriggerCount,
            audioRouteChangeTriggerCount: captured.audioDiagnostics.routeChangeTriggerCount,
            audioRecoveryTransactionCount:
                captured.audioDiagnostics.recoveryTransactionCount,
            audioSuppressedCorrelatedTriggerCount:
                captured.audioDiagnostics.suppressedCorrelatedTriggerCount,
            audioCompressedRendererRetryCount:
                captured.audioDiagnostics.compressedRendererRetryCount,
            audioPCMFallbackCount: captured.audioDiagnostics.pcmFallbackCount,
            audioLastFallbackReason: captured.audioDiagnostics.lastFallbackReason,
            audioStartupWaitingSeconds: captured.audioDiagnostics.startupWaitingSeconds,
            audioRendererReady: captured.audioDiagnostics.rendererReady,
            audioRendererSufficient: captured.audioDiagnostics.rendererSufficient,
            audioActiveCodec: captured.audioDiagnostics.activeCodec,
            audioFormatFingerprint: captured.audioDiagnostics.formatFingerprint,
            audioOutputCategory: captured.audioDiagnostics.outputCategory,
            audioRouteRevision: captured.audioDiagnostics.routeRevision,
            audioMediaGeneration: captured.audioDiagnostics.mediaGeneration,
            audioLastCompressedRendererFailure:
                captured.audioDiagnostics.lastCompressedRendererFailure,
            audioAcceptedCompressedMediaDurationSeconds:
                captured.audioDiagnostics.acceptedCompressedMediaDurationSeconds,
            audioPendingSampleCount: captured.audioDiagnostics.pendingSampleCount,
            audioRendererRequestArmed: captured.audioDiagnostics.rendererRequestArmed,
            audioRendererBackpressureCount:
                captured.audioDiagnostics.rendererBackpressureCount,
            audioRendererRequestRearmCount:
                captured.audioDiagnostics.rendererRequestRearmCount,
            audioAutomaticFlushNoProgressCount:
                captured.audioDiagnostics.automaticFlushNoProgressCount,
            audioLastAcceptedPTSSeconds:
                captured.audioDiagnostics.lastAcceptedPTSSeconds,
            audioLastRendererProgressAgeSeconds:
                captured.audioDiagnostics.lastRendererProgressAgeSeconds,
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
            decoderSessionSummary: captured.decoderSessionSummary,
            decodeCallbackLatencyP95Milliseconds: Self.percentile95(Array(decodeLatency)),
            videoDecodeSubmissionP95Milliseconds: Self.percentile95(Array(decodeSubmission))
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
        state.gpuDurations.removeAll { $0.timestamp < cutoff }
        state.yadifCPUEncodeDurations.removeAll { $0.timestamp < cutoff }
        state.decodeCallbackLatencies.removeAll { $0.timestamp < cutoff }
        state.decodeSubmissions.removeAll { $0.timestamp < cutoff }
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
