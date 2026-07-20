// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest

final class LongPlaybackAcceptanceTests: XCTestCase {
    private static let requiredConfigurationKeys = [
        "VPLAYER_ACCEPTANCE_M3U_URL",
        "VPLAYER_ACCEPTANCE_CHANNEL",
        "VPLAYER_ACCEPTANCE_SECONDS",
        "VPLAYER_ACCEPTANCE_ALGORITHM",
    ]

    func testSnapshotDeltaRejectsBadCurrentMinuteAfterGoodLongPrefix() {
        let previousPresented: UInt64 = 150_000
        let previousDropped: UInt64 = 100
        let currentPresented: UInt64 = 150_049
        let currentDropped: UInt64 = 102

        XCTAssertLessThan(
            Double(currentDropped) / Double(currentPresented + currentDropped),
            0.01,
            "The cumulative session ratio intentionally remains good"
        )
        XCTAssertThrowsError(try AcceptanceSnapshotValidator.validateCounterDelta(
            previousPresented: previousPresented,
            previousDropped: previousDropped,
            currentPresented: currentPresented,
            currentDropped: currentDropped
        )) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .dropRatioExceeded)
        }
    }

    func testAppleCadenceRejectsMismatchedTwentyFiveAndFiftyBands() {
        XCTAssertThrowsError(try AcceptanceSnapshotValidator.validateMatchingAppleCadence(
            decoderCallbacksPerSecond: 25,
            presentationsPerSecond: 50
        )) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .cadenceBandMismatch)
        }
    }

    @MainActor
    func testLongRunningRealDevicePlayback() async throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.encodedEnvironment
        app.launch()

        try importPrefilledProfile(in: app)
        selectAlgorithm(configuration.algorithm, in: app)
        selectTab(named: "频道", in: app)

        let channelText = app.staticTexts[configuration.channel]
        XCTAssertTrue(
            channelText.waitForExistence(timeout: 90),
            "The refreshed live playlist did not expose the requested channel"
        )
        let channelButton = app.buttons.containing(
            .staticText,
            identifier: configuration.channel
        ).element
        focusAndSelect(channelButton)
        XCTAssertTrue(app.otherElements["player-full-screen"].waitForExistence(timeout: 30))

        let metricsElement = app.otherElements["player-acceptance-metrics"]
        XCTAssertTrue(metricsElement.waitForExistence(timeout: 30))
        let bannerTracker = CapabilityBannerTracker(app: app)
        _ = try await awaitStableRoute(
            algorithm: configuration.algorithm,
            from: metricsElement,
            tracker: bannerTracker,
            timeout: .seconds(90)
        )
        try await performTwentyManualAlgorithmSwitches(
            initialAlgorithm: configuration.algorithm,
            metricsElement: metricsElement,
            tracker: bannerTracker,
            in: app
        )

        let runBaseline = try await activeHeartbeat(
            after: -Double.infinity,
            metricsElement: metricsElement,
            tracker: bannerTracker,
            in: app
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let requestedDuration = Duration.milliseconds(Int64(configuration.duration * 1_000))
        let end = startedAt.advanced(by: requestedDuration)
        var nextMinute = startedAt.advanced(by: .seconds(60))
        var lastObservedElapsed = runBaseline.elapsedSeconds
        var previousSteadySnapshot = runBaseline
        var snapshots: [AcceptanceMetricsSnapshot] = []

        while clock.now < end {
            let heartbeat = try await activeHeartbeat(
                after: lastObservedElapsed,
                metricsElement: metricsElement,
                tracker: bannerTracker,
                in: app
            )
            lastObservedElapsed = heartbeat.elapsedSeconds
            if clock.now >= nextMinute {
                if let prior = snapshots.last {
                    XCTAssertGreaterThan(heartbeat.elapsedSeconds, prior.elapsedSeconds)
                }
                assertSteadyStateCounterDelta(
                    from: previousSteadySnapshot,
                    to: heartbeat
                )
                try attach(heartbeat, elapsed: elapsedSeconds(from: startedAt, clock: clock))
                assertSteadyStateThresholds(heartbeat, configuration: configuration)
                snapshots.append(heartbeat)
                previousSteadySnapshot = heartbeat
                repeat {
                    nextMinute = nextMinute.advanced(by: .seconds(60))
                } while nextMinute <= clock.now
            }
            try await clock.sleep(for: .seconds(1))
        }

        let final = try await activeHeartbeat(
            after: lastObservedElapsed,
            metricsElement: metricsElement,
            tracker: bannerTracker,
            in: app
        )
        if let prior = snapshots.last {
            XCTAssertGreaterThan(final.elapsedSeconds, prior.elapsedSeconds)
        }
        assertSteadyStateCounterDelta(from: previousSteadySnapshot, to: final)
        try attach(final, elapsed: elapsedSeconds(from: startedAt, clock: clock))
        assertSteadyStateThresholds(final, configuration: configuration)
        snapshots.append(final)

        XCTAssertGreaterThanOrEqual(final.elapsedSeconds, configuration.duration)
        XCTAssertGreaterThanOrEqual(
            final.elapsedSeconds - runBaseline.elapsedSeconds,
            configuration.duration
        )
        try assertLongRunMemoryEvidence(snapshots, configuration: configuration)
        assertTemporalCapabilityOutcome(
            final,
            configuration: configuration,
            tracker: bannerTracker
        )
    }

    private func acceptanceConfiguration() throws -> AcceptanceConfiguration {
        var decoded: [String: String] = [:]
        var encodedEnvironment: [String: String] = [:]
        for key in Self.requiredConfigurationKeys {
            let encodedKey = "\(key)_B64"
            guard let encoded = Bundle(for: Self.self).object(
                forInfoDictionaryKey: encodedKey
            ) as? String,
                !encoded.isEmpty,
                let data = Data(base64Encoded: encoded),
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty else {
                throw XCTSkip("Long device acceptance requires protected bundle configuration")
            }
            decoded[key] = value
            encodedEnvironment[encodedKey] = encoded
        }

        let sourceText = try XCTUnwrap(decoded["VPLAYER_ACCEPTANCE_M3U_URL"])
        let sourceURL = try XCTUnwrap(URL(string: sourceText))
        XCTAssertTrue(["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""))
        let channel = try XCTUnwrap(decoded["VPLAYER_ACCEPTANCE_CHANNEL"])
        let duration = try XCTUnwrap(TimeInterval(decoded["VPLAYER_ACCEPTANCE_SECONDS"] ?? ""))
        XCTAssertGreaterThan(duration, 0)
        let algorithm = try XCTUnwrap(AcceptanceAlgorithm(
            rawValue: decoded["VPLAYER_ACCEPTANCE_ALGORITHM"] ?? ""
        ))
        return AcceptanceConfiguration(
            encodedEnvironment: encodedEnvironment,
            channel: channel,
            duration: duration,
            algorithm: algorithm
        )
    }

    @MainActor
    private func importPrefilledProfile(in app: XCUIApplication) throws {
        selectTab(named: "数据源", in: app)
        let add = app.buttons["source.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        focusAndSelect(add)

        let name = app.textFields["source.editor.name"]
        let m3u = app.textFields["source.editor.m3u"]
        let epg = app.textFields["source.editor.epg"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(m3u.exists)
        XCTAssertTrue(epg.exists)
        XCTAssertFalse((name.value as? String)?.isEmpty ?? true)
        XCTAssertEqual(m3u.value as? String, "Protected URL configured")
        XCTAssertFalse((epg.value as? String)?.isEmpty ?? true)
        focusAndSelect(app.buttons["source.editor.save"])

        let refresh = app.buttons["source.refresh.playlist"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        focusAndSelect(refresh)
        XCTAssertTrue(app.staticTexts["刷新成功"].waitForExistence(timeout: 90))
    }

    @MainActor
    private func selectAlgorithm(_ algorithm: AcceptanceAlgorithm, in app: XCUIApplication) {
        selectTab(named: "设置", in: app)
        let button = app.buttons[algorithm.accessibilityIdentifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        focusAndSelect(button)
        XCTAssertTrue(button.isSelected)
    }

    @MainActor
    private func performTwentyManualAlgorithmSwitches(
        initialAlgorithm: AcceptanceAlgorithm,
        metricsElement: XCUIElement,
        tracker: CapabilityBannerTracker,
        in app: XCUIApplication
    ) async throws {
        focusAndSelect(app.buttons["player-settings"])
        let apple = app.buttons[AcceptanceAlgorithm.appleTemporal.accessibilityIdentifier]
        let yadif = app.buttons[AcceptanceAlgorithm.metalYADIF2x.accessibilityIdentifier]
        XCTAssertTrue(apple.waitForExistence(timeout: 10))
        XCTAssertTrue(yadif.waitForExistence(timeout: 10))
        XCTAssertTrue(apple.hasFocus || yadif.hasFocus, "Settings must establish focus")

        var selected = initialAlgorithm
        for _ in 0..<20 {
            let target = selected.opposite
            let targetButton = app.buttons[target.accessibilityIdentifier]
            let otherButton = app.buttons[selected.accessibilityIdentifier]
            if !targetButton.hasFocus {
                XCTAssertTrue(otherButton.hasFocus, "Focus was lost between algorithm switches")
                XCUIRemote.shared.press(target == .appleTemporal ? .up : .down)
            }
            XCTAssertTrue(targetButton.hasFocus, "A single deterministic move must reach the target")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(targetButton.hasFocus, "Selecting an algorithm must preserve settings focus")
            _ = try await awaitStableRoute(
                algorithm: target,
                from: metricsElement,
                tracker: tracker,
                timeout: .seconds(20)
            )
            selected = target
        }

        XCTAssertEqual(selected, initialAlgorithm)
        XCTAssertTrue(app.buttons[initialAlgorithm.accessibilityIdentifier].isSelected)
        XCUIRemote.shared.press(.menu)
        assertActiveControls(in: app)
    }

    @MainActor
    private func awaitStableRoute(
        algorithm: AcceptanceAlgorithm,
        from element: XCUIElement,
        tracker: CapabilityBannerTracker,
        timeout: Duration
    ) async throws -> AcceptanceMetricsSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            tracker.observe()
            if let snapshot = try? snapshot(from: element),
               snapshot.selectedAlgorithm == algorithm.rawValue,
               snapshot.scanType != "unknown",
               snapshot.activeRoute != "rawWhileClassifying",
               routeMatches(snapshot, algorithm: algorithm) {
                if snapshot.temporalUnavailableNoticeCount == 1 {
                    tracker.observeExpectedNotice()
                }
                return snapshot
            }
            try await clock.sleep(for: .milliseconds(250))
        }
        throw AcceptanceFailure.stableRouteTimedOut
    }

    @MainActor
    private func activeHeartbeat(
        after previousElapsed: Double,
        metricsElement: XCUIElement,
        tracker: CapabilityBannerTracker,
        in app: XCUIApplication
    ) async throws -> AcceptanceMetricsSnapshot {
        assertActiveControls(in: app)
        tracker.observe()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while clock.now < deadline {
            if let candidate = try? snapshot(from: metricsElement),
               candidate.elapsedSeconds > previousElapsed {
                XCTAssertGreaterThan(candidate.decoderCallbacksPerSecond, 0)
                XCTAssertGreaterThan(candidate.presentationsPerSecond, 0)
                XCTAssertGreaterThan(candidate.residentMemoryBytes, 0)
                return candidate
            }
            try await clock.sleep(for: .milliseconds(250))
        }
        throw AcceptanceFailure.metricsDidNotAdvance
    }

    @MainActor
    private func assertActiveControls(in app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["player-full-screen"].exists)
        XCTAssertTrue(app.buttons["player-play-pause"].exists)
        XCTAssertTrue(app.buttons["player-settings"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "player-retry").count, 0)
    }

    @MainActor
    private func selectTab(named name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        for _ in 0..<8 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        for _ in 0..<4 where !tab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func snapshot(from element: XCUIElement) throws -> AcceptanceMetricsSnapshot {
        guard let json = element.value as? String,
              !json.isEmpty,
              json != "unavailable",
              let data = json.data(using: .utf8) else {
            throw AcceptanceFailure.metricsUnavailable
        }
        return try JSONDecoder().decode(AcceptanceMetricsSnapshot.self, from: data)
    }

    private func attach(_ snapshot: AcceptanceMetricsSnapshot, elapsed: Double) throws {
        let data = try JSONEncoder().encode(snapshot)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = String(format: "playback-metrics-%06.0f-seconds.json", elapsed)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func focusAndSelect(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        focus(element)
        XCTAssertTrue(element.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func focus(_ element: XCUIElement) {
        guard !element.hasFocus else { return }
        let directions: [XCUIRemote.Button] = [.down, .right, .up, .left]
        for _ in 0..<12 {
            for direction in directions {
                XCUIRemote.shared.press(direction)
                if element.hasFocus { return }
            }
        }
    }

    private func routeMatches(
        _ snapshot: AcceptanceMetricsSnapshot,
        algorithm: AcceptanceAlgorithm
    ) -> Bool {
        if ["progressive", "progressiveSegmentedFrame"].contains(snapshot.scanType) {
            return snapshot.activeRoute == "bypass"
        }
        guard snapshot.scanType == "interlaced" else { return false }
        switch algorithm {
        case .appleTemporal:
            return snapshot.activeRoute == "appleTemporal"
                || snapshot.activeRoute == "rawTemporalFailure"
        case .metalYADIF2x:
            return snapshot.activeRoute == "metalYADIF2x"
        }
    }

    private func assertSteadyStateThresholds(
        _ snapshot: AcceptanceMetricsSnapshot,
        configuration: AcceptanceConfiguration
    ) {
        XCTAssertEqual(snapshot.selectedAlgorithm, configuration.algorithm.rawValue)
        XCTAssertGreaterThan(snapshot.decoderCallbacksPerSecond, 0)
        XCTAssertGreaterThan(snapshot.presentationsPerSecond, 0)
        XCTAssertGreaterThan(snapshot.residentMemoryBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.automaticAlgorithmSwitchCount, 0)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
        XCTAssertGreaterThan(snapshot.presentedVideoFrames, 0)
        if snapshot.elapsedSeconds >= 60 {
            XCTAssertGreaterThanOrEqual(snapshot.windowDurationSeconds, 55)
            XCTAssertLessThanOrEqual(snapshot.windowDurationSeconds, 60.5)
        }

        let denominator = snapshot.presentedVideoFrames + snapshot.droppedVideoFrames
        XCTAssertGreaterThan(denominator, 0)
        XCTAssertLessThanOrEqual(
            Double(snapshot.droppedVideoFrames) / Double(denominator),
            0.01
        )
        XCTAssertLessThanOrEqual(snapshot.avDriftP95Milliseconds, 40)
        XCTAssertLessThanOrEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 100)

        if configuration.channel == "东方卫视 4K" {
            XCTAssertEqual(snapshot.scanType, "progressive")
            XCTAssertEqual(snapshot.activeRoute, "bypass")
            XCTAssertEqual(snapshot.yadifKernelDispatchCount, 0)
            XCTAssertEqual(snapshot.temporalDecodeFlagCount, 0)
            return
        }
        if ["东方卫视 HD", "五星体育 HD"].contains(configuration.channel) {
            XCTAssertEqual(snapshot.scanType, "interlaced")
        }
        guard snapshot.scanType == "interlaced" else { return }

        switch configuration.algorithm {
        case .metalYADIF2x:
            XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
            XCTAssertTrue((22...28).contains(snapshot.decoderCallbacksPerSecond))
            XCTAssertTrue((45...55).contains(snapshot.presentationsPerSecond))
            XCTAssertGreaterThan(snapshot.yadifKernelDispatchCount, 0)
            XCTAssertGreaterThan(snapshot.gpuDurationP95Milliseconds, 0)
            XCTAssertLessThanOrEqual(snapshot.gpuDurationP95Milliseconds, 16)
        case .appleTemporal where snapshot.temporalUnavailableNoticeCount == 0:
            XCTAssertEqual(snapshot.activeRoute, "appleTemporal")
            XCTAssertGreaterThan(snapshot.temporalPropertySetCount, 0)
            XCTAssertGreaterThan(snapshot.temporalDecodeFlagCount, 0)
            XCTAssertNoThrow(try AcceptanceSnapshotValidator.validateMatchingAppleCadence(
                decoderCallbacksPerSecond: snapshot.decoderCallbacksPerSecond,
                presentationsPerSecond: snapshot.presentationsPerSecond
            ))
        case .appleTemporal:
            XCTAssertEqual(snapshot.temporalUnavailableNoticeCount, 1)
            XCTAssertEqual(snapshot.activeRoute, "rawTemporalFailure")
        }
    }

    private func assertSteadyStateCounterDelta(
        from previous: AcceptanceMetricsSnapshot,
        to current: AcceptanceMetricsSnapshot
    ) {
        XCTAssertNoThrow(try AcceptanceSnapshotValidator.validateCounterDelta(
            previousPresented: previous.presentedVideoFrames,
            previousDropped: previous.droppedVideoFrames,
            currentPresented: current.presentedVideoFrames,
            currentDropped: current.droppedVideoFrames
        ))
    }

    private func assertLongRunMemoryEvidence(
        _ snapshots: [AcceptanceMetricsSnapshot],
        configuration: AcceptanceConfiguration
    ) throws {
        guard configuration.duration >= 7_200 else { return }
        let baseline = try XCTUnwrap(snapshots.first { $0.elapsedSeconds >= 900 })
        XCTAssertGreaterThan(baseline.residentMemoryBytes, 0)
        let secondHour = snapshots.filter { $0.elapsedSeconds >= 3_600 }
        XCTAssertFalse(secondHour.isEmpty)
        XCTAssertTrue(secondHour.allSatisfy { $0.residentMemoryBytes > 0 })
        let secondHourMaximum = try XCTUnwrap(secondHour.map(\.residentMemoryBytes).max())
        let growth = secondHourMaximum > baseline.residentMemoryBytes
            ? secondHourMaximum - baseline.residentMemoryBytes
            : 0
        XCTAssertLessThanOrEqual(growth, 32 * 1_024 * 1_024)
    }

    @MainActor
    private func assertTemporalCapabilityOutcome(
        _ snapshot: AcceptanceMetricsSnapshot,
        configuration: AcceptanceConfiguration,
        tracker: CapabilityBannerTracker
    ) {
        guard configuration.algorithm == .appleTemporal,
              snapshot.scanType == "interlaced" else { return }
        if snapshot.temporalUnavailableNoticeCount == 1 {
            XCTAssertEqual(snapshot.activeRoute, "rawTemporalFailure")
            XCTAssertEqual(tracker.appearanceCount, 1)
        } else {
            XCTAssertEqual(snapshot.temporalUnavailableNoticeCount, 0)
            XCTAssertEqual(snapshot.activeRoute, "appleTemporal")
            XCTAssertEqual(tracker.appearanceCount, 0)
        }
    }

    private func elapsedSeconds(
        from start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private enum AcceptanceValidationError: Error, Equatable {
    case counterRegressed
    case emptyCounterDelta
    case dropRatioExceeded
    case cadenceOutsideBroadcastBands
    case cadenceBandMismatch
}

private enum AcceptanceSnapshotValidator {
    private enum CadenceBand: Equatable {
        case broadcast25
        case broadcast50
    }

    static func validateCounterDelta(
        previousPresented: UInt64,
        previousDropped: UInt64,
        currentPresented: UInt64,
        currentDropped: UInt64
    ) throws {
        guard currentPresented >= previousPresented,
              currentDropped >= previousDropped else {
            throw AcceptanceValidationError.counterRegressed
        }
        let presentedDelta = currentPresented - previousPresented
        let droppedDelta = currentDropped - previousDropped
        let denominator = Double(presentedDelta) + Double(droppedDelta)
        guard denominator > 0 else {
            throw AcceptanceValidationError.emptyCounterDelta
        }
        guard Double(droppedDelta) / denominator <= 0.01 else {
            throw AcceptanceValidationError.dropRatioExceeded
        }
    }

    static func validateMatchingAppleCadence(
        decoderCallbacksPerSecond: Double,
        presentationsPerSecond: Double
    ) throws {
        let decoderBand = try cadenceBand(for: decoderCallbacksPerSecond)
        let presentationBand = try cadenceBand(for: presentationsPerSecond)
        guard decoderBand == presentationBand else {
            throw AcceptanceValidationError.cadenceBandMismatch
        }
    }

    private static func cadenceBand(for rate: Double) throws -> CadenceBand {
        if (22...28).contains(rate) { return .broadcast25 }
        if (45...55).contains(rate) { return .broadcast50 }
        throw AcceptanceValidationError.cadenceOutsideBroadcastBands
    }
}

@MainActor
private final class CapabilityBannerTracker {
    private let banners: XCUIElementQuery
    private let banner: XCUIElement
    private var wasVisible = false
    private(set) var appearanceCount = 0

    init(app: XCUIApplication) {
        banners = app.staticTexts.matching(identifier: "player-capability-notice")
        banner = banners.element
    }

    func observe() {
        let isVisible = banner.exists
        XCTAssertLessThanOrEqual(banners.count, 1)
        if isVisible, !wasVisible {
            appearanceCount += 1
        }
        wasVisible = isVisible
    }

    func observeExpectedNotice() {
        if appearanceCount == 0 {
            XCTAssertTrue(banner.waitForExistence(timeout: 3))
        }
        observe()
    }
}

private enum AcceptanceFailure: Error {
    case metricsUnavailable
    case metricsDidNotAdvance
    case stableRouteTimedOut
}

private struct AcceptanceConfiguration {
    let encodedEnvironment: [String: String]
    let channel: String
    let duration: TimeInterval
    let algorithm: AcceptanceAlgorithm
}

private enum AcceptanceAlgorithm: String {
    case appleTemporal
    case metalYADIF2x

    var accessibilityIdentifier: String {
        switch self {
        case .appleTemporal: "settings.deinterlace.apple"
        case .metalYADIF2x: "settings.deinterlace.yadif"
        }
    }

    var opposite: Self {
        switch self {
        case .appleTemporal: .metalYADIF2x
        case .metalYADIF2x: .appleTemporal
        }
    }
}

private struct AcceptanceMetricsSnapshot: Codable {
    let scanType: String
    let selectedAlgorithm: String
    let activeRoute: String
    let decoderCallbacksPerSecond: Double
    let presentationsPerSecond: Double
    let yadifKernelDispatchCount: UInt64
    let temporalPropertySetCount: UInt64
    let temporalDecodeFlagCount: UInt64
    let staleGenerationDropCount: UInt64
    let droppedVideoFrames: UInt64
    let maximumPresentationQueueDepth: Int
    let maximumYADIFInFlightCount: Int
    let maximumYADIFInputDepth: Int
    let gpuDurationP95Milliseconds: Double
    let avDriftP95Milliseconds: Double
    let residentMemoryBytes: UInt64
    let automaticAlgorithmSwitchCount: UInt64
    let elapsedSeconds: Double
    let windowDurationSeconds: Double
    let presentedVideoFrames: UInt64
    let maximumAbsoluteAVDriftMilliseconds: Double
    let temporalUnavailableNoticeCount: UInt64
    let crossGenerationPresentationCount: UInt64
}
