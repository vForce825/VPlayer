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
    func testExpiredProgressDeadlineNeverRequestsNanosecondPolling() {
        var watch = HLSPlaybackProgressWatch()
        XCTAssertFalse(watch.observe(mediaTime: 0, at: 0))
        XCTAssertFalse(watch.observe(mediaTime: 1, at: 250_000_000))
        XCTAssertEqual(watch.nextPollDelay(at: 3_250_000_000), 250_000_000,
            "An unavailable observation must never produce a one-nanosecond polling loop")
    }

    func testLiveProgressWatchNeedsStrictAdvanceAndLatchesOneStall() {
        var watch = HLSPlaybackProgressWatch()
        XCTAssertFalse(watch.observe(mediaTime: Double.nan, at: 0))
        XCTAssertFalse(watch.observe(mediaTime: 10, at: 0))
        XCTAssertFalse(watch.observe(mediaTime: 10, at: 90_000_000_000),
            "A startup waiting item has not yet made real progress")
        XCTAssertFalse(watch.hasObservedProgress)
        XCTAssertFalse(watch.observe(mediaTime: 10.5, at: 90_250_000_000))
        XCTAssertTrue(watch.hasObservedProgress)
        XCTAssertFalse(watch.observe(mediaTime: 10.5, at: 93_249_999_999))
        XCTAssertTrue(watch.observe(mediaTime: 10.5, at: 93_250_000_000))
        XCTAssertFalse(watch.observe(mediaTime: 100, at: 96_250_000_000),
            "A retired observation cannot reopen itself even if a late sample advances")
    }

    func testLiveProgressWatchFreshActivationRequiresFreshProgress() {
        var watch = HLSPlaybackProgressWatch()
        XCTAssertFalse(watch.observe(mediaTime: 0, at: 0))
        for sample in 1...280 {
            XCTAssertFalse(watch.observe(mediaTime: Double(sample) / 4,
                at: UInt64(sample) * 250_000_000))
        }
        XCTAssertTrue(watch.observe(mediaTime: 70, at: 73_000_000_000))
        watch = .init()
        XCTAssertFalse(watch.observe(mediaTime: 0, at: 74_000_000_000))
        XCTAssertFalse(watch.observe(mediaTime: 0, at: 90_000_000_000))
        XCTAssertFalse(watch.hasObservedProgress)
    }

    func testHLSWatchdogCompletedRecoveryCannotLoopWithoutNewActivation() async {
        let recovery = PlaybackRecoveryCoordinator()
        let clock = TestClock()
        let calls = WatchdogRecoveryRecorder()
        recovery.setWatchdogRecoveryHandler { reason, _ in calls.record(reason) }
        let watchdog = HLSPlaybackWatchdog(recoveryCoordinator: recovery, now: { clock.now() })
        await watchdog.arm(activationEpoch: 1, hasObservedProgress: true)
        await watchdog.recordMediaProgress(mediaTimeSeconds: 10)
        clock.advance(by: 3)
        let first = await watchdog.pollAndEvaluate(currentTimeSeconds: 10, isPlaying: true)
        XCTAssertTrue(first)
        await recovery.waitForCurrentRecovery()

        // The completed transaction is not evidence that this item recovered.
        // Continue a minute of actual production polls at the same media clock.
        for _ in 0..<120 {
            clock.advance(by: 0.5)
            _ = await watchdog.pollAndEvaluate(currentTimeSeconds: 10, isPlaying: true)
            await recovery.waitForCurrentRecovery()
        }
        XCTAssertEqual(calls.reasons, [.playbackStalled],
            "A completed handler must not refill the stalled activation's recovery budget")
    }

    func testHLSWatchdogQueuedRecoveryIsRevokedByDisarmBeforeDelivery() async {
        let recovery = PlaybackRecoveryCoordinator()
        let clock = TestClock()
        let gate = WatchdogRecoveryGate()
        let calls = WatchdogRecoveryRecorder()
        recovery.setWatchdogRecoveryHandler { reason, _ in calls.record(reason) }
        // Own the scheduler's preceding transaction so the watchdog is queued,
        // then exercise the real disarm boundary before its handler can execute.
        recovery.scheduleRecoveryTransaction { _ in await gate.wait() }
        let watchdog = HLSPlaybackWatchdog(recoveryCoordinator: recovery, now: { clock.now() })
        await watchdog.arm(activationEpoch: 1, hasObservedProgress: true)
        await watchdog.recordMediaProgress(mediaTimeSeconds: 10)
        clock.advance(by: 3)
        let triggered = await watchdog.pollAndEvaluate(currentTimeSeconds: 10, isPlaying: true)
        XCTAssertTrue(triggered)
        await watchdog.disarm()
        gate.open()
        await recovery.waitForCurrentRecovery()
        XCTAssertTrue(calls.reasons.isEmpty,
            "A queued observation cannot restart output after pause, end, or replacement revoked it")
    }

    func testHLSWatchdogContinuousProgressBeyondSixtyFiveSecondsThenStall() async {
        let recovery = PlaybackRecoveryCoordinator()
        let clock = TestClock()
        let calls = WatchdogRecoveryRecorder()
        recovery.setWatchdogRecoveryHandler { reason, _ in calls.record(reason) }
        let watchdog = HLSPlaybackWatchdog(recoveryCoordinator: recovery, now: { clock.now() })
        await watchdog.arm(activationEpoch: 1, hasObservedProgress: true)
        await watchdog.recordMediaProgress(mediaTimeSeconds: 0)
        for sample in 1...140 {
            clock.advance(by: 0.5)
            let triggered = await watchdog.pollAndEvaluate(
                currentTimeSeconds: Double(sample) * 0.5, isPlaying: true)
            XCTAssertFalse(triggered, "Healthy live progress must not exhaust a duration-based budget")
        }
        clock.advance(by: 2.5)
        let early = await watchdog.pollAndEvaluate(currentTimeSeconds: 70, isPlaying: true)
        XCTAssertFalse(early)
        clock.advance(by: 0.5)
        let due = await watchdog.pollAndEvaluate(currentTimeSeconds: 70, isPlaying: true)
        XCTAssertTrue(due, "A real stall remains bounded to three seconds after prolonged live playback")
        await recovery.waitForCurrentRecovery()
        XCTAssertEqual(calls.reasons, [.playbackStalled])
    }

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

    func testReplacementDisarmRetiresOldArmsBeforeNewSessionActivation() async {
        let watchdog = HLSPlaybackWatchdog(recoveryCoordinator: PlaybackRecoveryCoordinator())
        let old = PlaybackSessionIdentity(sessionID: 10, requestID: UUID())
        let current = PlaybackSessionIdentity(sessionID: 11, requestID: UUID())
        await watchdog.arm(activationEpoch: 100, hasObservedProgress: true, session: old, controlRevision: 7)
        await watchdog.beginReplacement(generation: 2, retiring: old)
        await watchdog.arm(activationEpoch: 100, hasObservedProgress: true, session: old, controlRevision: 7)
        let stillDisarmed = await watchdog.isArmed
        XCTAssertFalse(stillDisarmed)
        await watchdog.arm(activationEpoch: 200, hasObservedProgress: true, session: current, controlRevision: 0)
        await watchdog.beginReplacement(generation: 1, retiring: old)
        let replacementArmed = await watchdog.isArmed
        let currentEpoch = await watchdog.currentActivationEpoch
        XCTAssertTrue(replacementArmed, "An older replacement transition cannot disarm the new activation")
        XCTAssertEqual(currentEpoch, 200)
    }

    func testScopedWatchdogRejectsOldSessionAndOldSameSessionControlRevision() async {
        let watchdog = HLSPlaybackWatchdog(recoveryCoordinator: PlaybackRecoveryCoordinator())
        let old = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let current = PlaybackSessionIdentity(sessionID: 2, requestID: UUID())
        await watchdog.arm(activationEpoch: 20, hasObservedProgress: true, session: current, controlRevision: 4)
        await watchdog.disarm(session: old, controlRevision: 99)
        await watchdog.disarm(session: current, controlRevision: 3)
        let preserved = await watchdog.isArmed
        XCTAssertTrue(preserved)
        await watchdog.disarm(session: current, controlRevision: 5)
        await watchdog.arm(activationEpoch: 10, hasObservedProgress: true, session: old, controlRevision: 100)
        await watchdog.arm(activationEpoch: 21, hasObservedProgress: true, session: current, controlRevision: 4)
        let stillPaused = await watchdog.isArmed
        XCTAssertFalse(stillPaused)
        await watchdog.arm(activationEpoch: 22, hasObservedProgress: true, session: current, controlRevision: 6)
        let resumed = await watchdog.isArmed
        XCTAssertTrue(resumed)
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

private final class WatchdogRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HLSPlaybackWatchdog.TriggerReason] = []
    var reasons: [HLSPlaybackWatchdog.TriggerReason] { lock.withLock { values } }
    func record(_ reason: HLSPlaybackWatchdog.TriggerReason) {
        lock.withLock { values.append(reason) }
    }
}

private final class WatchdogRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { pending in
            let resume = lock.withLock {
                if opened { return true }
                continuation = pending
                return false
            }
            if resume { pending.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
