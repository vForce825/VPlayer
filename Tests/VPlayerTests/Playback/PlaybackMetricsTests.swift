// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackMetricsTests: XCTestCase {
    func testNativeRendererMetricsAccumulateDeltasAndRebaseWholeEpochOnRollback() {
        let metrics = PlaybackMetrics(channelID: "native-renderer", now: { 1 })

        metrics.recordVideoRendererPerformance(.init(
            totalFrameCount: 10,
            droppedFrameCount: 2,
            corruptedFrameCount: 1,
            optimizedFrameCount: 5,
            accumulatedFrameDelaySeconds: 0.1
        ))
        metrics.recordVideoRendererPerformance(.init(
            totalFrameCount: 15,
            droppedFrameCount: 3,
            corruptedFrameCount: 1,
            optimizedFrameCount: 7,
            accumulatedFrameDelaySeconds: 0.15
        ))
        metrics.recordVideoRendererPerformance(.init(
            totalFrameCount: 1,
            droppedFrameCount: 0,
            corruptedFrameCount: 0,
            optimizedFrameCount: 1,
            accumulatedFrameDelaySeconds: 0.01
        ))
        metrics.recordVideoRendererPerformance(.init(
            totalFrameCount: 4,
            droppedFrameCount: 1,
            corruptedFrameCount: 0,
            optimizedFrameCount: 2,
            accumulatedFrameDelaySeconds: 0.04
        ))

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.videoRendererMetricsSampleCount, 4)
        XCTAssertEqual(snapshot.videoRendererMetricsEpochCount, 2)
        XCTAssertEqual(snapshot.videoRendererTotalFrameCount, 18)
        XCTAssertEqual(snapshot.videoRendererDroppedFrameCount, 4)
        XCTAssertEqual(snapshot.videoRendererCorruptedFrameCount, 1)
        XCTAssertEqual(snapshot.videoRendererOptimizedFrameCount, 8)
        XCTAssertEqual(
            snapshot.videoRendererAccumulatedFrameDelayMilliseconds,
            180,
            accuracy: 0.000_001
        )
    }

    func testNativeRendererAccumulatedDelayRemainsFiniteAtNumericLimit() {
        let metrics = PlaybackMetrics(channelID: "native-renderer-limit", now: { 1 })

        metrics.recordVideoRendererPerformance(.init(
            totalFrameCount: 1,
            droppedFrameCount: 0,
            corruptedFrameCount: 0,
            optimizedFrameCount: 1,
            accumulatedFrameDelaySeconds: .greatestFiniteMagnitude
        ))

        let milliseconds = metrics.snapshot(window: .seconds(60))
            .videoRendererAccumulatedFrameDelayMilliseconds
        XCTAssertTrue(milliseconds.isFinite)
        XCTAssertGreaterThan(milliseconds, 0)
    }

    func testMetricsEncodingUsesExplicitAllowlistWithoutReflection() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/VPlayerPlayback/Diagnostics/PlaybackMetrics.swift"
            ),
            encoding: .utf8
        )
        let encodeStart = try XCTUnwrap(source.range(of: "func encode(to encoder:"))
        let encodeEnd = try XCTUnwrap(
            source.range(
                of: "internal func uncheckedReplacingAudioContinuityDropCountsByReason",
                range: encodeStart.lowerBound..<source.endIndex
            )
        )
        let encodingSource = source[encodeStart.lowerBound..<encodeEnd.lowerBound]

        XCTAssertFalse(encodingSource.contains("Mirror("))
        XCTAssertTrue(encodingSource.contains("container.encode(scanType"))
        XCTAssertTrue(encodingSource.contains("container.encodeIfPresent(decoderSessionSummary"))
    }

    func testPublicAudioDiagnosticsNormalizeInvalidPTSAndProgressAge() {
        for invalidPTS in [Double.nan, .infinity, -.infinity] {
            let diagnostics = makeAudioDiagnostics(
                lastAcceptedPTSSeconds: invalidPTS,
                lastRendererProgressAgeSeconds: 1
            )
            XCTAssertNil(diagnostics.lastAcceptedPTSSeconds)
            XCTAssertEqual(diagnostics.lastRendererProgressAgeSeconds, 1)
        }
        for invalidAge in [-1.0, .nan, .infinity, -.infinity] {
            let diagnostics = makeAudioDiagnostics(
                lastAcceptedPTSSeconds: 2,
                lastRendererProgressAgeSeconds: invalidAge
            )
            XCTAssertEqual(diagnostics.lastAcceptedPTSSeconds, 2)
            XCTAssertNil(diagnostics.lastRendererProgressAgeSeconds)
        }
    }

    func testAudioContinuityReasonUsesExplicitDenseSlots() {
        XCTAssertEqual(AudioContinuityDropReason.slotCount, 5)
        XCTAssertEqual(AudioContinuityDropReason.allCases.map(\.slot), Array(0..<5))
    }

    func testFreshReadinessCountsMatchFixedSevenSlotDomain() {
        let reasons = PlaybackReadinessCloseReason.allCases
        XCTAssertEqual(reasons.map(\.rawValue), Array(0...6))
        XCTAssertEqual(reasons[Int(PlaybackReadinessCloseReason.audioGap.rawValue)], .audioGap)

        let fresh = PlaybackMetrics(channelID: "fresh-readiness", now: { 1 })
            .snapshot(window: .seconds(60))
        XCTAssertEqual(fresh.readinessCloseReasonCounts.count, reasons.count)
        XCTAssertEqual(fresh.readinessCloseReasonCounts, Array(repeating: 0, count: 7))
    }

    func testBoundedReasonDecodeRequestsElementsOnlyForExactDomainCount() throws {
        var oversizedRequests = 0
        let oversized = try PlaybackMetricsBoundedReasonCounts.decode(
            declaredCount: 10_000,
            expectedCount: 5
        ) {
            oversizedRequests += 1
            return 99
        }
        XCTAssertEqual(oversized, [0, 0, 0, 0, 0])
        XCTAssertEqual(oversizedRequests, 0)

        var shortRequests = 0
        let short = try PlaybackMetricsBoundedReasonCounts.decode(
            declaredCount: 4,
            expectedCount: 5
        ) {
            shortRequests += 1
            return 99
        }
        XCTAssertEqual(short, [0, 0, 0, 0, 0])
        XCTAssertEqual(shortRequests, 0)

        var uncountableRequests = 0
        let uncountable = try PlaybackMetricsBoundedReasonCounts.decode(
            declaredCount: nil,
            expectedCount: 5
        ) {
            uncountableRequests += 1
            return 99
        }
        XCTAssertEqual(uncountable, [0, 0, 0, 0, 0])
        XCTAssertEqual(uncountableRequests, 0)

        let source: [UInt64] = [11, 22, 33, 44, 55]
        var exactRequests = 0
        let exact = try PlaybackMetricsBoundedReasonCounts.decode(
            declaredCount: 5,
            expectedCount: 5
        ) {
            defer { exactRequests += 1 }
            return source[exactRequests]
        }
        XCTAssertEqual(exact, [11, 22, 33, 44, 55])
        XCTAssertEqual(exactRequests, 5)
    }

    func testDiagnosticCounterSaturatesAtUInt64Maximum() {
        var value = UInt64.max - 1
        PlaybackDiagnosticSaturatingCounter.increment(&value)
        XCTAssertEqual(value, UInt64.max)

        PlaybackDiagnosticSaturatingCounter.increment(&value)
        XCTAssertEqual(value, UInt64.max)
    }

    func testEncodingRejectsWrongContinuityReasonDomainLength() throws {
        let valid = PlaybackMetrics(channelID: "encoding-length-sentinel", now: { 1 })
            .snapshot(window: .seconds(60))

        for invalidCount in [4, 6] {
            let invalid = valid.uncheckedReplacingAudioContinuityDropCountsByReason(
                Array(repeating: 1, count: invalidCount)
            )
            XCTAssertThrowsError(try JSONEncoder().encode(invalid)) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("unexpected encoding error: \(error)")
                }
            }
        }
    }

    func testAudioPumpDiagnosticsRoundTripWithoutSensitiveContext() throws {
        let metrics = PlaybackMetrics(
            channelID: "SENSITIVE_SENTINEL_source_channel_cookie_private",
            now: { 1 }
        )
        let diagnostics = AudioRenderDiagnostics(
            automaticFlushTriggerCount: 1,
            outputConfigurationTriggerCount: 2,
            routeChangeTriggerCount: 3,
            recoveryTransactionCount: 4,
            suppressedCorrelatedTriggerCount: 5,
            compressedRendererRetryCount: 6,
            pcmFallbackCount: 7,
            lastFallbackReason: nil,
            startupWaitingSeconds: 8,
            rendererReady: true,
            rendererSufficient: false,
            pendingSampleCount: 9,
            rendererRequestArmed: true,
            rendererBackpressureCount: 10,
            rendererRequestRearmCount: 11,
            automaticFlushNoProgressCount: 12,
            lastAcceptedPTSSeconds: 13.25,
            lastRendererProgressAgeSeconds: 14.5
        )
        metrics.updateReadinessDiagnostics(
            audioRoute: .systemCompressed,
            audioReady: true,
            readinessOpen: false,
            retainedAudioCount: 9,
            retainedVideoCount: 0,
            audioFirstPTS: .zero,
            audioDuration: .zero,
            videoFirstPTS: nil,
            audioDiagnostics: diagnostics
        )

        let data = try JSONEncoder().encode(metrics.snapshot(window: .seconds(60)))
        let decoded = try JSONDecoder().decode(PlaybackMetricsSnapshot.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded.audioPendingSampleCount, 9)
        XCTAssertTrue(decoded.audioRendererRequestArmed)
        XCTAssertEqual(decoded.audioRendererBackpressureCount, 10)
        XCTAssertEqual(decoded.audioRendererRequestRearmCount, 11)
        XCTAssertEqual(decoded.audioAutomaticFlushNoProgressCount, 12)
        XCTAssertEqual(decoded.audioLastAcceptedPTSSeconds, 13.25)
        XCTAssertEqual(decoded.audioLastRendererProgressAgeSeconds, 14.5)
        for forbiddenValue in [
            "SENSITIVE_SENTINEL", "token", "private", "route-uid", "device-name",
            "payload", "extradata", "cookie",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbiddenValue))
        }
    }

    func testContinuityDiagnosticsRoundTripByBoundedReasonIndex() throws {
        let metrics = PlaybackMetrics(channelID: "bounded-continuity", now: { 1 })
        metrics.updateReadinessDiagnostics(
            audioRoute: .systemCompressed,
            audioReady: false,
            readinessOpen: false,
            retainedAudioCount: 3,
            retainedVideoCount: 0,
            audioFirstPTS: nil,
            audioDuration: nil,
            videoFirstPTS: nil,
            audioContinuityDropCountsByReason: [11, 12, 13, 14, 15],
            audioShortGapCount: 16,
            audioLargeGapCount: 17,
            audioContinuityIslandSwitchCount: 18
        )

        let original = metrics.snapshot(window: .seconds(60))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackMetricsSnapshot.self, from: data)

        XCTAssertEqual(AudioContinuityDropReason.allCases.count, 5)
        XCTAssertEqual(decoded.audioContinuityDropCountsByReason, [11, 12, 13, 14, 15])
        for reason in AudioContinuityDropReason.allCases {
            XCTAssertEqual(
                decoded.audioContinuityDropCountsByReason[reason.slot],
                UInt64(11 + reason.slot)
            )
        }
        XCTAssertEqual(decoded.audioShortGapCount, 16)
        XCTAssertEqual(decoded.audioLargeGapCount, 17)
        XCTAssertEqual(decoded.audioContinuityIslandSwitchCount, 18)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["audioContinuityDropCountsByReason"] = Array(repeating: 99, count: 10_000)
        let oversizedData = try JSONSerialization.data(withJSONObject: object)
        let oversized = try JSONDecoder().decode(
            PlaybackMetricsSnapshot.self,
            from: oversizedData
        )
        XCTAssertEqual(
            oversized.audioContinuityDropCountsByReason,
            Array(repeating: 0, count: AudioContinuityDropReason.allCases.count)
        )
    }

    func testOlderSnapshotDecodesWithZeroNewAudioFields() throws {
        let data = try JSONEncoder().encode(
            PlaybackMetrics(channelID: "older-snapshot", now: { 1 })
                .snapshot(window: .seconds(60))
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "audioPendingSampleCount",
            "audioRendererRequestArmed",
            "audioRendererBackpressureCount",
            "audioRendererRequestRearmCount",
            "audioAutomaticFlushNoProgressCount",
            "audioLastAcceptedPTSSeconds",
            "audioLastRendererProgressAgeSeconds",
            "audioContinuityDropCountsByReason",
            "audioShortGapCount",
            "audioLargeGapCount",
            "audioContinuityIslandSwitchCount",
        ] {
            object.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(
            PlaybackMetricsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.audioPendingSampleCount, 0)
        XCTAssertFalse(decoded.audioRendererRequestArmed)
        XCTAssertEqual(decoded.audioRendererBackpressureCount, 0)
        XCTAssertEqual(decoded.audioRendererRequestRearmCount, 0)
        XCTAssertEqual(decoded.audioAutomaticFlushNoProgressCount, 0)
        XCTAssertNil(decoded.audioLastAcceptedPTSSeconds)
        XCTAssertNil(decoded.audioLastRendererProgressAgeSeconds)
        XCTAssertEqual(decoded.audioContinuityDropCountsByReason, [0, 0, 0, 0, 0])
        XCTAssertEqual(decoded.audioShortGapCount, 0)
        XCTAssertEqual(decoded.audioLargeGapCount, 0)
        XCTAssertEqual(decoded.audioContinuityIslandSwitchCount, 0)
    }

    func testDiagnosticEncodingContainsNoRouteUIDDeviceNameURLPayloadExtradataOrCookieFields() throws {
        let metrics = PlaybackMetrics(
            channelID: "SENSITIVE_SENTINEL_secret_channel_cookie_private",
            now: { 1 }
        )
        let fingerprint = try XCTUnwrap(AudioFormatFingerprintDiagnostic(
            value: String(repeating: "b", count: 64)
        ))
        let failure = try XCTUnwrap(AudioRendererFailureDiagnostic(
            domain: "SyntheticErrorDomain",
            code: -1
        ))
        metrics.updateReadinessDiagnostics(
            audioRoute: .systemCompressed,
            audioReady: true,
            readinessOpen: true,
            retainedAudioCount: 1,
            retainedVideoCount: 1,
            audioFirstPTS: .zero,
            audioDuration: .zero,
            videoFirstPTS: .zero,
            audioRecoveryCount: 1,
            audioDiagnostics: AudioRenderDiagnostics(
                automaticFlushTriggerCount: 0,
                outputConfigurationTriggerCount: 0,
                routeChangeTriggerCount: 0,
                recoveryTransactionCount: 0,
                suppressedCorrelatedTriggerCount: 0,
                compressedRendererRetryCount: 0,
                pcmFallbackCount: 0,
                lastFallbackReason: .systemDecoderUnavailable,
                startupWaitingSeconds: 0,
                rendererReady: true,
                rendererSufficient: true,
                activeCodec: .aac,
                formatFingerprint: fingerprint,
                mediaGeneration: MediaGeneration(rawValue: 7),
                lastCompressedRendererFailure: failure,
                pendingSampleCount: 1,
                rendererRequestArmed: true,
                rendererBackpressureCount: 2,
                rendererRequestRearmCount: 3,
                automaticFlushNoProgressCount: 4,
                lastAcceptedPTSSeconds: 5,
                lastRendererProgressAgeSeconds: 6
            )
        )
        let data = try JSONEncoder().encode(metrics.snapshot(window: .seconds(60)))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let audioKeys = Set(object.keys.filter { $0.hasPrefix("audio") })
        XCTAssertEqual(audioKeys, [
            "audioAcceptedCompressedMediaDurationSeconds",
            "audioActiveCodec",
            "audioAutomaticFlushNoProgressCount",
            "audioAutomaticFlushTriggerCount",
            "audioCompressedRendererRetryCount",
            "audioContinuityDropCountsByReason",
            "audioContinuityIslandSwitchCount",
            "audioDurationSeconds",
            "audioFirstPTSSeconds",
            "audioFormatFingerprint",
            "audioLargeGapCount",
            "audioLastAcceptedPTSSeconds",
            "audioLastCompressedRendererFailure",
            "audioLastFallbackReason",
            "audioLastRendererProgressAgeSeconds",
            "audioMediaGeneration",
            "audioOutputCategory",
            "audioOutputConfigurationTriggerCount",
            "audioPCMFallbackCount",
            "audioPendingSampleCount",
            "audioReady",
            "audioRecoveryCount",
            "audioRecoveryTransactionCount",
            "audioRelativeVideoPruneCount",
            "audioRendererBackpressureCount",
            "audioRendererReady",
            "audioRendererRequestArmed",
            "audioRendererRequestRearmCount",
            "audioRendererSufficient",
            "audioRoute",
            "audioRouteChangeTriggerCount",
            "audioRouteRevision",
            "audioSampleCount",
            "audioShortGapCount",
            "audioStartupWaitingSeconds",
            "audioSuppressedCorrelatedTriggerCount",
        ])
        let lowercasedKeys = audioKeys.map { $0.lowercased() }
        for forbiddenFragment in [
            "routename", "device", "uid", "url", "source", "channel",
            "payload", "extradata", "cookie", "hosttime", "timestamp",
        ] {
            XCTAssertFalse(lowercasedKeys.contains { $0.contains(forbiddenFragment) })
        }
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("SENSITIVE_SENTINEL"))
        XCTAssertFalse(json.contains("secret_channel"))
        XCTAssertFalse(json.contains("private"))
    }

    func testAudioDiagnosticsRoundTripThroughMetricsJSON() throws {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 1 })
        let fingerprint = try XCTUnwrap(AudioFormatFingerprintDiagnostic(
            value: String(repeating: "a", count: 64)
        ))
        let failure = try XCTUnwrap(AudioRendererFailureDiagnostic(
            domain: "AVFoundationErrorDomain",
            code: -11819
        ))
        let diagnostics = AudioRenderDiagnostics(
            automaticFlushTriggerCount: 11,
            outputConfigurationTriggerCount: 12,
            routeChangeTriggerCount: 13,
            recoveryTransactionCount: 14,
            suppressedCorrelatedTriggerCount: 15,
            compressedRendererRetryCount: 16,
            pcmFallbackCount: 17,
            lastFallbackReason: .repeatedCompressedRendererFailure,
            startupWaitingSeconds: 18.5,
            rendererReady: true,
            rendererSufficient: false,
            activeCodec: .eac3,
            formatFingerprint: fingerprint,
            outputCategory: .airPlay,
            routeRevision: 20,
            mediaGeneration: MediaGeneration(rawValue: 21),
            lastCompressedRendererFailure: failure,
            acceptedCompressedMediaDurationSeconds: 22.5
        )
        metrics.updateReadinessDiagnostics(
            audioRoute: .ffmpegPCM,
            audioReady: true,
            readinessOpen: true,
            retainedAudioCount: 1,
            retainedVideoCount: 1,
            audioFirstPTS: .zero,
            audioDuration: .zero,
            videoFirstPTS: .zero,
            audioRecoveryCount: 19,
            audioDiagnostics: diagnostics
        )

        let original = metrics.snapshot(window: .seconds(60))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackMetricsSnapshot.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.audioAutomaticFlushTriggerCount, 11)
        XCTAssertEqual(decoded.audioOutputConfigurationTriggerCount, 12)
        XCTAssertEqual(decoded.audioRouteChangeTriggerCount, 13)
        XCTAssertEqual(decoded.audioRecoveryTransactionCount, 14)
        XCTAssertEqual(decoded.audioSuppressedCorrelatedTriggerCount, 15)
        XCTAssertEqual(decoded.audioCompressedRendererRetryCount, 16)
        XCTAssertEqual(decoded.audioPCMFallbackCount, 17)
        XCTAssertEqual(decoded.audioLastFallbackReason, .repeatedCompressedRendererFailure)
        XCTAssertEqual(decoded.audioStartupWaitingSeconds, 18.5)
        XCTAssertTrue(decoded.audioRendererReady)
        XCTAssertFalse(decoded.audioRendererSufficient)
        XCTAssertEqual(decoded.audioRecoveryCount, 19)
        XCTAssertEqual(decoded.audioActiveCodec, .eac3)
        XCTAssertEqual(decoded.audioFormatFingerprint, fingerprint)
        XCTAssertEqual(decoded.audioOutputCategory, .airPlay)
        XCTAssertEqual(decoded.audioRouteRevision, 20)
        XCTAssertEqual(decoded.audioMediaGeneration, MediaGeneration(rawValue: 21))
        XCTAssertEqual(decoded.audioLastCompressedRendererFailure, failure)
        XCTAssertEqual(decoded.audioAcceptedCompressedMediaDurationSeconds, 22.5)
    }

    func testMetricsSnapshotTracksBoundedQueuesRatesAndRequiredCounters() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "https://secret.example/live?token=do-not-export",
            now: { clock.value },
            residentMemoryProvider: { 123_456 }
        )
        let top = ResolvedFieldOrder(
            parity: .top,
            confidence: .signaled,
            source: .parser
        )
        metrics.update(scanType: .interlaced(top))
        metrics.update(activeRoute: .metalYADIF2x)
        metrics.updateReadinessDiagnostics(
            audioRoute: .ffmpegPCM,
            audioReady: true,
            readinessOpen: false,
            retainedAudioCount: 48,
            retainedVideoCount: 2,
            audioFirstPTS: CMTime(value: 100, timescale: 10),
            audioDuration: CMTime(value: 15, timescale: 10),
            videoFirstPTS: CMTime(value: 103, timescale: 10)
        )

        for second in 1...60 {
            clock.value = TimeInterval(second)
            metrics.recordDecoderCallback()
            if second.isMultiple(of: 2) {
                metrics.recordVideoDrop(count: second == 60 ? 2 : 0, source: .presentationExpired)
            }
        }
        for duration in 1...20 {
            metrics.recordYADIFKernelDispatch(inFlightCount: min(3, duration), inputDepth: min(4, duration))
            metrics.recordGPUDuration(milliseconds: Double(duration))
            metrics.recordYADIFCPUEncode(milliseconds: Double(duration) / 10)
        }
        metrics.recordStaleGenerationDrop()
        metrics.recordVideoDrop(count: 1, source: .deinterlaceQueueFull)
        metrics.recordDemuxPacket()
        metrics.recordDemuxPacket()
        metrics.recordVideoAccessUnit()
        metrics.recordAudioSample()
        metrics.recordAudioSample()
        metrics.recordAudioSample()
        metrics.recordVideoDecodeSubmission(milliseconds: 2.5)
        metrics.recordVideoDecodeSubmission(milliseconds: 7.5)

        clock.value = 60
        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.scanType, "interlaced")
        XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
        XCTAssertEqual(snapshot.elapsedSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 20)
        XCTAssertEqual(snapshot.staleGenerationDropCount, 1)
        XCTAssertEqual(snapshot.droppedVideoFrames, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 19, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 1.9, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.residentMemoryBytes, 123_456)
        XCTAssertEqual(snapshot.audioRoute, "ffmpegPCM")
        XCTAssertTrue(snapshot.audioReady)
        XCTAssertFalse(snapshot.readinessOpen)
        XCTAssertEqual(snapshot.retainedAudioCount, 48)
        XCTAssertEqual(snapshot.retainedVideoCount, 2)
        XCTAssertEqual(snapshot.audioFirstPTSSeconds, 10)
        XCTAssertEqual(snapshot.audioDurationSeconds, 1.5)
        XCTAssertEqual(snapshot.videoFirstPTSSeconds, 10.3)
        XCTAssertEqual(snapshot.demuxPacketCount, 2)
        XCTAssertEqual(snapshot.videoAccessUnitCount, 1)
        XCTAssertEqual(snapshot.audioSampleCount, 3)
        XCTAssertEqual(snapshot.videoDecodeSubmissionCount, 2)
        XCTAssertEqual(snapshot.maximumVideoDecodeSubmissionMilliseconds, 7.5)
    }

    func testWindowedRatesAndPercentilesExcludeOldSamplesWithoutResettingSessionTotals() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 99)
        metrics.recordYADIFCPUEncode(milliseconds: 88)
        clock.value = 120
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 4)
        metrics.recordYADIFCPUEncode(milliseconds: 3)

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 3, accuracy: 0.000_001)
    }

    func testSnapshotNeverClaimsAWindowLongerThanItsRetainedHistory() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        clock.value = 300

        let snapshot = metrics.snapshot(window: .seconds(300))

        XCTAssertEqual(snapshot.windowDurationSeconds, 120, accuracy: 0.000_001)
    }

    func testCollectorIsThreadSafeAcrossRealCallbackLanes() {
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 0 }
        )
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            metrics.recordDecoderCallback()
            metrics.recordYADIFKernelDispatch(
                inFlightCount: index % 4,
                inputDepth: index % 5
            )
        }

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1_000)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 1_000)
        XCTAssertEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertEqual(snapshot.maximumYADIFInputDepth, 4)
    }

    func testSnapshotJSONAndSignpostChannelIdentifierAreIrreversiblyRedacted() throws {
        let secret = "五星体育 HD https://iptv.router/live?token=secret"
        let metrics = PlaybackMetrics(
            channelID: secret,
            now: { 1 },
            residentMemoryProvider: { 42 }
        )
        let encoded = try JSONEncoder().encode(metrics.snapshot(window: .seconds(60)))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let identifier = PlaybackDiagnosticsChannelID(rawValue: secret)

        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("iptv.router"))
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(identifier.value.contains("五星体育"))
        XCTAssertFalse(identifier.value.contains("iptv.router"))
        XCTAssertEqual(identifier.value.count, 12)
        XCTAssertTrue(identifier.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testSignpostLifetimeFinishesExactlyOnceIncludingDeinitFallback() {
        let recorder = SignpostFinishRecorder()
        var lifetime: PlaybackSignpostLifetime? = PlaybackSignpostLifetime {
            recorder.record()
        }
        lifetime?.finish()
        lifetime?.finish()
        lifetime = nil
        XCTAssertEqual(recorder.count, 1)

        var fallback: PlaybackSignpostLifetime? = PlaybackSignpostLifetime {
            recorder.record()
        }
        XCTAssertNotNil(fallback)
        fallback = nil
        XCTAssertEqual(recorder.count, 2)
    }

    func testSignpostCorrelationIsHashedAndBounded() {
        let identifier = PlaybackDiagnosticsChannelID(rawValue: "channel")
        let correlation = PlaybackDiagnosticsCorrelationID(
            channelIdentifier: identifier,
            rawValue: 12_345_678_901_234_567_890
        )

        XCTAssertEqual(correlation.value.count, 12)
        XCTAssertFalse(correlation.value.contains("12345678901234567890"))
        XCTAssertTrue(correlation.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    private func makeAudioDiagnostics(
        lastAcceptedPTSSeconds: Double?,
        lastRendererProgressAgeSeconds: Double?
    ) -> AudioRenderDiagnostics {
        AudioRenderDiagnostics(
            automaticFlushTriggerCount: 0,
            outputConfigurationTriggerCount: 0,
            routeChangeTriggerCount: 0,
            recoveryTransactionCount: 0,
            suppressedCorrelatedTriggerCount: 0,
            compressedRendererRetryCount: 0,
            pcmFallbackCount: 0,
            lastFallbackReason: nil,
            startupWaitingSeconds: 0,
            rendererReady: false,
            rendererSufficient: false,
            lastAcceptedPTSSeconds: lastAcceptedPTSSeconds,
            lastRendererProgressAgeSeconds: lastRendererProgressAgeSeconds
        )
    }
}

private final class MetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class SignpostFinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.withLock { storage } }
    func record() { lock.withLock { storage += 1 } }
}
