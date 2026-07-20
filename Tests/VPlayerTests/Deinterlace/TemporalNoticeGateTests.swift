// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class TemporalNoticeGateTests: XCTestCase {
    private let suite = "TemporalNoticeGateTests"

    override func setUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testPublicSessionGateAndNoticeContractsAreExactAndSendable() {
        requireNoticeSendable(PlaybackSessionID.self)
        requireNoticeSendable(TemporalNoticeGate.self)

        let rawValue = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(PlaybackSessionID(rawValue: rawValue).rawValue, rawValue)
        XCTAssertEqual(PlaybackSessionID(rawValue: rawValue), PlaybackSessionID(rawValue: rawValue))

        XCTAssertEqual(PlaybackNotice.appleTemporalUnavailable, PlaybackNotice(
            id: "apple-temporal-unavailable",
            message: "Apple 反交错不可用，可在设置中切换到 Metal YADIF 2x。",
            duration: .seconds(3),
            isFocusStealing: false
        ))
    }

    func testConsumeReturnsTrueExactlyOnceForInterleavedDistinctSessions() {
        var gate = TemporalNoticeGate()
        let first = PlaybackSessionID(rawValue: UUID())
        let second = PlaybackSessionID(rawValue: UUID())
        let third = PlaybackSessionID(rawValue: UUID())

        XCTAssertTrue(gate.consume(sessionID: first))
        XCTAssertTrue(gate.consume(sessionID: second))
        XCTAssertFalse(gate.consume(sessionID: first))
        XCTAssertTrue(gate.consume(sessionID: third))
        XCTAssertFalse(gate.consume(sessionID: second))
        XCTAssertFalse(gate.consume(sessionID: third))
    }

    func testNoticeConsumptionDoesNotMutateSelectedDeinterlaceSetting() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(DeinterlaceAlgorithm.metalYADIF2x.rawValue, forKey: PlaybackSettingsStore.storageKey)
        let store = PlaybackSettingsStore(defaults: defaults)
        var gate = TemporalNoticeGate()

        XCTAssertTrue(gate.consume(sessionID: PlaybackSessionID(rawValue: UUID())))

        XCTAssertEqual(store.deinterlaceAlgorithm, .metalYADIF2x)
        XCTAssertEqual(
            defaults.string(forKey: PlaybackSettingsStore.storageKey),
            DeinterlaceAlgorithm.metalYADIF2x.rawValue
        )
    }
}

private func requireNoticeSendable<T: Sendable>(_: T.Type) {}
