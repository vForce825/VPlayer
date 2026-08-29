// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import XCTest
@testable import VPlayer

@MainActor
final class SystemAudioSessionConfiguratorTests: XCTestCase {
    func testConfigureOnceUsesLongFormAudioThenEnablesMultichannel() {
        let session = RecordingAudioSession()
        let configurator = SystemAudioSessionConfigurator(session: session)

        configurator.configureOnce()

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .multichannel(true),
        ])
    }

    func testLongFormFailureFallsBackToDefaultThenEnablesMultichannel() {
        let session = RecordingAudioSession(
            categoryErrors: [TestFailure.category, nil]
        )
        let configurator = SystemAudioSessionConfigurator(session: session)

        configurator.configureOnce()

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .category(.default),
            .multichannel(true),
        ])
    }

    func testFailureReportsOnlyBoundedDomainCodeAndStage() throws {
        let sensitiveMarker = "sensitive-marker"
        let error = NSError(
            domain: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567 é?/TRUNCATED",
            code: Int.max,
            userInfo: [NSLocalizedDescriptionKey: sensitiveMarker]
        )
        let session = RecordingAudioSession(categoryErrors: [error, nil])
        var diagnostics: [AudioSessionConfigurationDiagnostic] = []
        let configurator = SystemAudioSessionConfigurator(
            session: session,
            reportFailure: { diagnostics.append($0) }
        )

        configurator.configureOnce()

        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.stage, .longFormAudioCategory)
        XCTAssertEqual(
            diagnostic.errorDomain,
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567____"
        )
        XCTAssertEqual(diagnostic.errorCode, 2_147_483_647)
        XCTAssertEqual(diagnostic.errorDomain.utf8.count, 64)
        XCTAssertFalse(String(describing: diagnostic).contains(sensitiveMarker))
    }

    func testConfigurationIsIdempotentAfterSuccess() {
        let session = RecordingAudioSession()
        let configurator = SystemAudioSessionConfigurator(session: session)

        configurator.configureOnce()
        configurator.configureOnce()

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .multichannel(true),
        ])
    }

    func testConfigurationIsIdempotentAfterFailure() {
        let session = RecordingAudioSession(
            categoryErrors: [TestFailure.category, TestFailure.category]
        )
        var diagnostics: [AudioSessionConfigurationDiagnostic] = []
        var configurator: SystemAudioSessionConfigurator?
        configurator = SystemAudioSessionConfigurator(
            session: session,
            reportFailure: {
                diagnostics.append($0)
                configurator?.configureOnce()
            }
        )

        configurator?.configureOnce()
        configurator?.configureOnce()
        configurator?.configureOnce()

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .category(.default),
        ])
        XCTAssertEqual(
            diagnostics.map(\.stage),
            [.longFormAudioCategory, .defaultCategory]
        )
    }
}

@MainActor
private final class RecordingAudioSession: AudioSessionApplying {
    enum Event: Equatable {
        case category(AVAudioSession.RouteSharingPolicy)
        case multichannel(Bool)
    }

    private var categoryErrors: [Error?]
    private let multichannelError: Error?
    private(set) var events: [Event] = []

    init(categoryErrors: [Error?] = [], multichannelError: Error? = nil) {
        self.categoryErrors = categoryErrors
        self.multichannelError = multichannelError
    }

    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws {
        events.append(.category(policy))
        if !categoryErrors.isEmpty, let error = categoryErrors.removeFirst() {
            throw error
        }
    }

    func setSupportsMultichannelContent(_ enabled: Bool) throws {
        events.append(.multichannel(enabled))
        if let multichannelError {
            throw multichannelError
        }
    }
}

private enum TestFailure: Error {
    case category
    case multichannel
}
