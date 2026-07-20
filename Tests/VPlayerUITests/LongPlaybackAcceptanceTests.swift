// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest

final class LongPlaybackAcceptanceTests: XCTestCase {
    private static let requiredEnvironmentKeys = [
        "VPLAYER_ACCEPTANCE_M3U_URL",
        "VPLAYER_ACCEPTANCE_CHANNEL",
        "VPLAYER_ACCEPTANCE_SECONDS",
        "VPLAYER_ACCEPTANCE_ALGORITHM",
    ]

    @MainActor
    func testLongRunningRealDevicePlayback() throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.environment
        app.launch()

        try importProfile(m3uURL: configuration.m3uURL, in: app)
        selectAlgorithm(configuration.algorithm, in: app)
        selectTab(named: "频道", in: app)

        let channelText = app.staticTexts[configuration.channel]
        XCTAssertTrue(
            channelText.waitForExistence(timeout: 90),
            "The refreshed live playlist did not expose the requested channel"
        )
        let channelButton = app.buttons.containing(.staticText, identifier: configuration.channel).element
        focusAndSelect(channelButton)
        XCTAssertTrue(app.otherElements["player-full-screen"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 10))

        performTwentyManualAlgorithmSwitches(
            finalAlgorithm: configuration.algorithm,
            in: app
        )

        let metricsElement = app.otherElements["player-acceptance-metrics"]
        XCTAssertTrue(metricsElement.waitForExistence(timeout: 30))
        var snapshots: [AcceptanceMetricsSnapshot] = []
        let startedAt = Date()
        var nextAttachmentAt: TimeInterval = 60
        while Date().timeIntervalSince(startedAt) < configuration.duration {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= nextAttachmentAt {
                snapshots.append(try attachSnapshot(from: metricsElement, elapsed: elapsed))
                nextAttachmentAt += 60
            }
            XCTAssertTrue(app.otherElements["player-full-screen"].exists)
            _ = XCTWaiter.wait(for: [expectation(description: "acceptance heartbeat")], timeout: 1)
        }
        snapshots.append(try attachSnapshot(
            from: metricsElement,
            elapsed: Date().timeIntervalSince(startedAt)
        ))
        let final = try XCTUnwrap(snapshots.last)
        assertThresholds(
            final,
            snapshots: snapshots,
            configuration: configuration
        )
    }

    private func acceptanceConfiguration() throws -> AcceptanceConfiguration {
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in Self.requiredEnvironmentKeys {
            if let value = acceptanceValue(for: key, processEnvironment: processEnvironment) {
                environment[key] = value
            }
        }
        guard environment.count == Self.requiredEnvironmentKeys.count else {
            throw XCTSkip("Long device acceptance requires all four VPLAYER_ACCEPTANCE_* variables")
        }
        let urlText = try XCTUnwrap(environment["VPLAYER_ACCEPTANCE_M3U_URL"])
        let channel = try XCTUnwrap(environment["VPLAYER_ACCEPTANCE_CHANNEL"])
        let secondsText = try XCTUnwrap(environment["VPLAYER_ACCEPTANCE_SECONDS"])
        let algorithmText = try XCTUnwrap(environment["VPLAYER_ACCEPTANCE_ALGORITHM"])
        let url = try XCTUnwrap(URL(string: urlText))
        XCTAssertTrue(["http", "https"].contains(url.scheme?.lowercased() ?? ""))
        let duration = try XCTUnwrap(TimeInterval(secondsText))
        XCTAssertGreaterThan(duration, 0)
        let algorithm = try XCTUnwrap(AcceptanceAlgorithm(rawValue: algorithmText))
        return AcceptanceConfiguration(
            environment: environment,
            m3uURL: urlText,
            channel: channel,
            duration: duration,
            algorithm: algorithm
        )
    }

    private func acceptanceValue(
        for key: String,
        processEnvironment: [String: String]
    ) -> String? {
        if let value = processEnvironment[key], !value.isEmpty {
            return value
        }
        let encodedKey = "\(key)_B64"
        guard let encoded = Bundle(for: Self.self).object(
            forInfoDictionaryKey: encodedKey
        ) as? String,
            !encoded.isEmpty,
            let data = Data(base64Encoded: encoded),
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    @MainActor
    private func importProfile(m3uURL: String, in app: XCUIApplication) throws {
        selectTab(named: "数据源", in: app)
        let add = app.buttons["source.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        focusAndSelect(add)

        let name = app.textFields["source.editor.name"]
        let m3u = app.textFields["source.editor.m3u"]
        let epg = app.textFields["source.editor.epg"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        focus(name)
        XCUIRemote.shared.press(.select)
        name.typeText("Device Acceptance")
        XCUIRemote.shared.press(.menu)
        focus(m3u)
        XCUIRemote.shared.press(.select)
        m3u.typeText(m3uURL)
        XCUIRemote.shared.press(.menu)
        focus(epg)
        XCUIRemote.shared.press(.select)
        epg.typeText("https://example.invalid/acceptance.xml")
        XCUIRemote.shared.press(.menu)
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
        finalAlgorithm: AcceptanceAlgorithm,
        in app: XCUIApplication
    ) {
        focusAndSelect(app.buttons["player-settings"])
        let apple = app.buttons[AcceptanceAlgorithm.appleTemporal.accessibilityIdentifier]
        let yadif = app.buttons[AcceptanceAlgorithm.metalYADIF2x.accessibilityIdentifier]
        XCTAssertTrue(apple.waitForExistence(timeout: 10))
        XCTAssertTrue(yadif.waitForExistence(timeout: 10))
        for iteration in 0..<20 {
            focusAndSelect(iteration.isMultiple(of: 2) ? yadif : apple)
        }
        focusAndSelect(app.buttons[finalAlgorithm.accessibilityIdentifier])
        XCTAssertTrue(app.buttons[finalAlgorithm.accessibilityIdentifier].isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player-play-pause"].hasFocus)
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
    private func attachSnapshot(
        from element: XCUIElement,
        elapsed: TimeInterval
    ) throws -> AcceptanceMetricsSnapshot {
        let elementValue = element.value
        let json = try XCTUnwrap(elementValue as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(AcceptanceMetricsSnapshot.self, from: data)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = String(format: "playback-metrics-%06.0f-seconds.json", elapsed)
        attachment.lifetime = .keepAlways
        add(attachment)
        return snapshot
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

    private func assertThresholds(
        _ snapshot: AcceptanceMetricsSnapshot,
        snapshots: [AcceptanceMetricsSnapshot],
        configuration: AcceptanceConfiguration
    ) {
        XCTAssertEqual(snapshot.selectedAlgorithm, configuration.algorithm.rawValue)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.automaticAlgorithmSwitchCount, 0)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
        XCTAssertGreaterThan(snapshot.presentedVideoFrames, 0)

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
            XCTAssertEqual(snapshot.yadifKernelDispatchCount, 0)
            XCTAssertEqual(snapshot.temporalDecodeFlagCount, 0)
        } else if ["东方卫视 HD", "五星体育 HD"].contains(configuration.channel) {
            XCTAssertEqual(snapshot.scanType, "interlaced")
        }

        if configuration.algorithm == .metalYADIF2x, snapshot.scanType == "interlaced" {
            XCTAssertLessThanOrEqual(snapshot.gpuDurationP95Milliseconds, 16)
        }
        if configuration.algorithm == .appleTemporal, snapshot.scanType == "interlaced" {
            XCTAssertLessThanOrEqual(snapshot.temporalUnavailableNoticeCount, 1)
            if snapshot.temporalUnavailableNoticeCount == 0 {
                XCTAssertGreaterThan(snapshot.decoderCallbacksPerSecond, 0)
                XCTAssertGreaterThan(snapshot.presentationsPerSecond, 0)
                XCTAssertLessThanOrEqual(
                    snapshot.presentationsPerSecond,
                    snapshot.decoderCallbacksPerSecond * 1.1 + 1
                )
            } else {
                XCTAssertEqual(snapshot.activeRoute, "rawTemporalFailure")
            }
        }

        if configuration.duration >= 7_200,
           let baseline = snapshots.first(where: { $0.elapsedSeconds >= 900 }) {
            let secondHourMaximum = snapshots
                .filter { $0.elapsedSeconds >= 3_600 }
                .map(\.residentMemoryBytes)
                .max() ?? baseline.residentMemoryBytes
            let growth = secondHourMaximum > baseline.residentMemoryBytes
                ? secondHourMaximum - baseline.residentMemoryBytes
                : 0
            XCTAssertLessThanOrEqual(growth, 32 * 1_024 * 1_024)
        }
    }
}

private struct AcceptanceConfiguration {
    let environment: [String: String]
    let m3uURL: String
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
}

private struct AcceptanceMetricsSnapshot: Decodable {
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
