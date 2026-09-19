// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(_ initial: TimeInterval = 100.0) {
        self.current = initial
    }

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(by delta: TimeInterval) {
        lock.withLock { current += delta }
    }
}

final class BackendDiagnosticsTests: XCTestCase {

    func testBackendMetricsAreTypedAndDoNotSynthesizeFakeSampleBufferCounters() throws {
        // HLS Metrics Snapshot
        let hlsMetrics = HLSBackendMetrics(
            accessUnitCount: 150,
            decodedVideoCount: 150,
            yadifDispatchCount: 0,
            encodedSegmentCount: 10,
            publishedSegmentCount: 9,
            encoderCodec: "h264",
            encoderProfile: "high",
            videoDimensions: "1920x1080",
            bitDepth: 8,
            colorTransfer: "sdr",
            isHardwareAccelerated: true,
            pendingFrameCount: 2,
            writerStatus: "active",
            segmentDurationSeconds: 2.0,
            playlistWindowSegmentCount: 7,
            storeBytes: 15 * 1_048_576,
            discontinuityCount: 0,
            httpRequestCount: 42,
            rangeRequestCount: 38,
            httpCancelCount: 0,
            httpExpiredCount: 1,
            httpRejectedCount: 0,
            httpErrorCount: 0,
            avPlayerCurrentTimeSeconds: 18.0,
            avPlayerTimeControlStatus: "playing",
            avPlayerReasonForWaiting: nil,
            accessLogStallCount: 0,
            avPlayerDroppedFrameCount: 0,
            selectedAudioRendition: "aac-stereo",
            audioChannelCount: 2,
            audioSelectionMethod: "score"
        )

        let backendSnapshot = BackendPlaybackMetrics(
            state: "playing",
            backendKind: "airPlayHLS",
            trackMode: "audioVideo",
            sessionGeneration: 1,
            backendGeneration: 1,
            routeCategory: "airPlayVideo",
            isAirPlay: true,
            mediaTimeSeconds: 18.0,
            physFootprintBytes: 45 * 1_048_576,
            osProcAvailableMemoryBytes: 500 * 1_048_576,
            sampleBufferMetrics: nil,
            hlsMetrics: hlsMetrics
        )

        XCTAssertEqual(backendSnapshot.backendKind, "airPlayHLS")
        XCTAssertNil(backendSnapshot.sampleBufferMetrics, "HLS backend must NOT synthesize fake SampleBuffer metrics")
        XCTAssertNotNil(backendSnapshot.hlsMetrics)
        XCTAssertEqual(backendSnapshot.hlsMetrics?.encodedSegmentCount, 10)

        // Codable round-trip
        let encoder = JSONEncoder()
        let data = try encoder.encode(backendSnapshot)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BackendPlaybackMetrics.self, from: data)

        XCTAssertEqual(decoded, backendSnapshot)
        XCTAssertNil(decoded.sampleBufferMetrics)
        XCTAssertEqual(decoded.hlsMetrics?.accessUnitCount, 150)
    }

    func testDiagnosticsRedactURLsAndTokensAndDeviceNames() {
        let sensitiveURL = "https://user:password@stream.internal.net:8080/live/master.m3u8?token=SECRET_TOKEN_XYZ&auth=ABC"
        let sensitiveDevice = "Living Room Apple TV 4K (2nd Gen)"

        // Error sanitization
        let sanitizedError1 = BackendDiagnosticsSanitizer.sanitize(
            errorMessage: "Failed to connect to \(sensitiveURL) on device \(sensitiveDevice)"
        )

        XCTAssertFalse(sanitizedError1.contains("stream.internal.net"))
        XCTAssertFalse(sanitizedError1.contains("SECRET_TOKEN_XYZ"))
        XCTAssertFalse(sanitizedError1.contains("Living Room Apple TV"))
        XCTAssertTrue(sanitizedError1.contains("<redacted-url>"))
        XCTAssertTrue(sanitizedError1.contains("<redacted-device>"))

        let fileURLString = "Local path file:///Users/john_doe/Movies/secret.mp4 failed to decode"
        let sanitizedFileError = BackendDiagnosticsSanitizer.sanitize(errorMessage: fileURLString)
        XCTAssertFalse(sanitizedFileError.contains("john_doe"))
        XCTAssertTrue(sanitizedFileError.contains("<redacted-url>"))

        // Diagnostic error mapping: only whitelisted stable codes
        let mappedCode = BackendDiagnosticsSanitizer.whitelistedDiagnosticCode(
            fromRawError: sensitiveURL,
            domain: .hlsResource
        )
        XCTAssertEqual(mappedCode, "hls.resource.error")
        XCTAssertFalse(mappedCode.contains("http"))
        XCTAssertFalse(mappedCode.contains("SECRET_TOKEN"))
    }

    func testStableErrorCodesClassification() {
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsResourceCapacityExceeded.rawValue, "hls.resource.capacity-exceeded")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsResourceNotFound.rawValue, "hls.resource.not-found")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsResourceGone.rawValue, "hls.resource.gone")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsWriterFailed.rawValue, "hls.writer.failed")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsEncoderFailed.rawValue, "hls.encoder.failed")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsFormatUnsupported.rawValue, "hls.format.unsupported")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsChannelLayoutUnsupported.rawValue, "hls.channel-layout.unsupported")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsAVPlayerItemFailed.rawValue, "hls.avplayer.item-failed")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsOutputTeardownFailed.rawValue, "hls.output.teardown-failed")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsStartupTimeout.rawValue, "hls.startup.timeout")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsWatchdogStalled.rawValue, "hls.watchdog.stalled")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsWatchdogStarvation.rawValue, "hls.watchdog.starvation")
        XCTAssertEqual(BackendDiagnosticErrorCode.hlsWatchdogBacklog.rawValue, "hls.watchdog.backlog")
    }

    func testHLSPlaybackWatchdogStallTriggersUnifiedRecovery() async {
        let recoveryCoordinator = PlaybackRecoveryCoordinator()
        let clock = TestClock(100.0)
        let watchdog = HLSPlaybackWatchdog(
            recoveryCoordinator: recoveryCoordinator,
            now: { clock.now() }
        )

        await watchdog.arm(activationEpoch: 1, hasObservedProgress: true)

        // Advance time by 3.5s without progress (timeout is 3.0s)
        clock.advance(by: 3.5)
        let triggered = await watchdog.pollAndEvaluate(currentTimeSeconds: 10.0, isPlaying: true)

        XCTAssertTrue(triggered, "Watchdog should trigger on playback stall")
        let reason = await watchdog.lastTriggerReason
        XCTAssertEqual(reason, .playbackStalled)

        // Wait for the recovery transaction scheduled by watchdog
        await recoveryCoordinator.waitForCurrentRecovery()
    }

    func testHLSPlaybackWatchdogBacklogTriggersUnifiedRecovery() async {
        let recoveryCoordinator = PlaybackRecoveryCoordinator()
        let clock = TestClock(100.0)
        let watchdog = HLSPlaybackWatchdog(
            recoveryCoordinator: recoveryCoordinator,
            now: { clock.now() }
        )

        // In prepare phase: soft cap backlog for 2.0s triggers recovery
        clock.advance(by: 0.5)
        _ = await watchdog.recordBacklogState(isSoftCapExceeded: true, isHardCapExceeded: false, isPreparePhase: true)
        clock.advance(by: 2.1)
        let prepareTriggered = await watchdog.recordBacklogState(isSoftCapExceeded: true, isHardCapExceeded: false, isPreparePhase: true)
        XCTAssertTrue(prepareTriggered, "Backlog during prepare exceeding 2.0s must trigger recovery")
        let prepareReason = await watchdog.lastTriggerReason
        XCTAssertEqual(prepareReason, .prepareBacklogExceeded)

        await recoveryCoordinator.waitForCurrentRecovery()

        // Hard cap exceeded immediately triggers recovery
        let hardTriggered = await watchdog.recordBacklogState(isSoftCapExceeded: true, isHardCapExceeded: true, isPreparePhase: false)
        XCTAssertTrue(hardTriggered, "Hard cap exceeded must immediately trigger recovery")
        let hardReason = await watchdog.lastTriggerReason
        XCTAssertEqual(hardReason, .hardCapacityExceeded)

        await recoveryCoordinator.waitForCurrentRecovery()
    }

    func testHLSPlaybackWatchdogDisarmsOnPauseOrPermitRevocation() async {
        let recoveryCoordinator = PlaybackRecoveryCoordinator()
        let clock = TestClock(100.0)
        let watchdog = HLSPlaybackWatchdog(
            recoveryCoordinator: recoveryCoordinator,
            now: { clock.now() }
        )

        await watchdog.arm(activationEpoch: 1, hasObservedProgress: true)
        let armedBefore = await watchdog.isArmed
        XCTAssertTrue(armedBefore)

        // Disarm (e.g. pause or permit revoked)
        await watchdog.disarm()
        let armedAfter = await watchdog.isArmed
        XCTAssertFalse(armedAfter)

        // Advancing time should not trigger anything when disarmed
        clock.advance(by: 10.0)
        let triggered = await watchdog.pollAndEvaluate(currentTimeSeconds: 10.0, isPlaying: true)
        XCTAssertFalse(triggered)
        let reason = await watchdog.lastTriggerReason
        XCTAssertNil(reason)
    }
}
