// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackMetricsTests: XCTestCase {
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
        let generation = MediaGeneration(rawValue: 7)
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
                let presentationTime = CMTime(seconds: TimeInterval(second), preferredTimescale: 1_000)
                metrics.recordPresentationCompletion(
                    generation: generation,
                    activeGeneration: generation,
                    isUniquePresentation: true,
                    presentationTimeStamp: presentationTime,
                    targetMediaTime: CMTimeAdd(
                        presentationTime,
                        CMTime(value: Int64(second % 20 + 1), timescale: 1_000)
                    )
                )
                metrics.recordVideoDrop(count: second == 60 ? 2 : 0, source: .presentationExpired)
                metrics.recordPresentationQueueDepth(min(12, second))
            }
        }
        for duration in 1...20 {
            metrics.recordYADIFKernelDispatch(inFlightCount: min(3, duration), inputDepth: min(4, duration))
            metrics.recordGPUDuration(milliseconds: Double(duration))
            metrics.recordYADIFCPUEncode(milliseconds: Double(duration) / 10)
            metrics.recordRenderCPUPreparation(milliseconds: Double(duration) / 20)
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
        XCTAssertEqual(snapshot.presentationsPerSecond, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 30)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 20)
        XCTAssertEqual(snapshot.staleGenerationDropCount, 1)
        XCTAssertEqual(snapshot.droppedVideoFrames, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 19, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 1.9, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.renderCPUPreparationP95Milliseconds, 0.95, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(snapshot.avDriftP95Milliseconds, 20)
        XCTAssertLessThanOrEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 20)
        XCTAssertEqual(snapshot.residentMemoryBytes, 123_456)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
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

    // A 50 Hz panel presenting every frame and a 60 Hz panel losing one tick in
    // six produce the same callback rate, and only the native period tells them
    // apart.
    func testDisplayLinkCadenceReportsTheNativePeriodAndCountsOnlyWholeMissedVSyncs() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let period = 1.0 / 60
        var timestamp = 100.0
        for step in [1, 1, 2, 1, 3, 1] {
            metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
            timestamp += period * Double(step)
        }
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        // A stall is not a cadence: folding it in would bury the single-vsync
        // gaps this counter exists to find.
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp + 5)

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.displayLinkCallbackCount, 8)
        XCTAssertEqual(snapshot.nativeDisplayIntervalMilliseconds, period * 1_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.missedDisplayLinkVSyncCount, 3)
    }

    // The shortest gap ever seen reads short of the true period, so one outlier
    // would rescale every later gap into a miss. The screen's own rate does not.
    func testReportedRefreshRateRatherThanTheShortestGapDecidesWhatCountsAsAMiss() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        metrics.recordDisplayRefreshRate(framesPerSecond: 60)
        var timestamp = 100.0
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        // An early outlier three quarters of a period long.
        timestamp += 0.75 / 60
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        for _ in 0..<4 {
            timestamp += 1.0 / 60
            metrics.recordDisplayLinkCallback(targetPresentationTimestamp: timestamp)
        }

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.displayRefreshHz, 60)
        XCTAssertLessThan(snapshot.nativeDisplayIntervalMilliseconds, 1_000 / 60)
        XCTAssertEqual(snapshot.missedDisplayLinkVSyncCount, 0)
    }

    func testCadenceChangeAndSubmissionResumeStartFreshMeasurementEpochs() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        metrics.recordDisplayRefreshRate(framesPerSecond: 60)
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 100)
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 100 + 1.0 / 60)

        metrics.recordDisplayRefreshRate(framesPerSecond: 50)
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 101)
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 101 + 1.0 / 50)
        metrics.recordDisplaySubmissionResume()
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 102)
        metrics.recordDisplayLinkCallback(targetPresentationTimestamp: 102 + 1.0 / 50)

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.displayRefreshHz, 50)
        XCTAssertEqual(snapshot.nativeDisplayIntervalMilliseconds, 20, accuracy: 0.001)
        XCTAssertEqual(snapshot.missedDisplayLinkVSyncCount, 0)
        XCTAssertEqual(snapshot.displayResumeCount, 1)
    }

    func testWindowedRatesAndPercentilesExcludeOldSamplesWithoutResettingSessionTotals() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 99)
        metrics.recordYADIFCPUEncode(milliseconds: 88)
        metrics.recordRenderCPUPreparation(milliseconds: 77)
        clock.value = 120
        metrics.recordDecoderCallback()
        metrics.recordGPUDuration(milliseconds: 4)
        metrics.recordYADIFCPUEncode(milliseconds: 3)
        metrics.recordRenderCPUPreparation(milliseconds: 2)
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: MediaGeneration(rawValue: 2),
            isUniquePresentation: true,
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 9, timescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.windowDurationSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.decoderCallbacksPerSecond, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentationsPerSecond, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.gpuDurationP95Milliseconds, 4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.yadifCPUEncodeP95Milliseconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.renderCPUPreparationP95Milliseconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 0)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 1)
    }

    func testFiveSecondReanchorGraceExcludesTransientDrift() {
        let clock = MetricsTestClock()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { clock.value },
            residentMemoryProvider: { 0 }
        )
        let generation = MediaGeneration(rawValue: 1)
        clock.value = 10
        metrics.beginAVDriftGracePeriod(seconds: 5)
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: generation,
            isUniquePresentation: true,
            presentationTimeStamp: .zero,
            targetMediaTime: CMTime(value: 900, timescale: 1_000)
        )
        clock.value = 15
        metrics.recordPresentationCompletion(
            generation: generation,
            activeGeneration: generation,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(value: 15_000, timescale: 1_000),
            targetMediaTime: CMTime(value: 15_025, timescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.avDriftP95Milliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.presentedVideoFrames, 2)
    }

    func testUniquePresentationPTSRegressionIsCountedWithinOneGeneration() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let generation = MediaGeneration(rawValue: 1)

        for pts in [10.0, 10.04, 9.0] {
            let time = CMTime(seconds: pts, preferredTimescale: 1_000)
            metrics.recordPresentationCompletion(
                generation: generation,
                activeGeneration: generation,
                isUniquePresentation: true,
                presentationTimeStamp: time,
                targetMediaTime: time
            )
        }

        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).presentationPTSRegressionCount,
            1
        )
    }

    func testUniquePresentationPTSRegressionSurvivesDecoderGenerationChange() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)

        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 10, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 9, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 9, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: secondGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 1, preferredTimescale: 1_000)
        )

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.presentationPTSRegressionCount, 1)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 1)
    }

    func testExplicitTimelineResetAllowsAnEarlierPTSWithoutErasingEvidence() {
        let metrics = PlaybackMetrics(channelID: "channel", now: { 0 })
        let firstGeneration = MediaGeneration(rawValue: 1)
        let secondGeneration = MediaGeneration(rawValue: 2)

        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 10, preferredTimescale: 1_000)
        )
        metrics.recordPresentationCompletion(
            generation: firstGeneration,
            activeGeneration: firstGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 9, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 9, preferredTimescale: 1_000)
        )
        metrics.resetPresentationTimeline()
        metrics.recordPresentationCompletion(
            generation: secondGeneration,
            activeGeneration: secondGeneration,
            isUniquePresentation: true,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 1_000),
            targetMediaTime: CMTime(seconds: 1, preferredTimescale: 1_000)
        )

        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).presentationPTSRegressionCount,
            1
        )
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
        let generation = MediaGeneration(rawValue: 4)

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            metrics.recordDecoderCallback()
            metrics.recordYADIFKernelDispatch(
                inFlightCount: index % 4,
                inputDepth: index % 5
            )
            metrics.recordPresentationCompletion(
                generation: generation,
                activeGeneration: generation,
                isUniquePresentation: true,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 1_000),
                targetMediaTime: CMTime(value: Int64(index + 1), timescale: 1_000)
            )
            metrics.recordPresentationQueueDepth(index % 13)
        }

        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.presentedVideoFrames, 1_000)
        XCTAssertEqual(snapshot.yadifKernelDispatchCount, 1_000)
        XCTAssertEqual(snapshot.maximumPresentationQueueDepth, 12)
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
