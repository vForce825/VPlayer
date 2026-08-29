// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class AudioRendererPumpTests: XCTestCase {
    func testPendingWorkArmsUniqueTicketAndLaterArmIsRearm() throws {
        var pump = AudioRendererPumpState()

        let first = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)
        XCTAssertTrue(pump.isCurrent(first))
        XCTAssertEqual(
            pump.reconcile(hasPendingWork: false, keepArmedForProgress: false),
            .disarm(ticket: first)
        )
        XCTAssertFalse(pump.isCurrent(first))

        let second = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: true)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(pump.isCurrent(second))
    }

    func testProgressOnlyDemandKeepsRequestArmedAfterLastReplaySample() throws {
        var pump = AudioRendererPumpState()
        let ticket = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)

        XCTAssertEqual(
            pump.reconcile(hasPendingWork: false, keepArmedForProgress: true),
            .none
        )
        XCTAssertTrue(pump.isCurrent(ticket))
        XCTAssertEqual(
            pump.reconcile(hasPendingWork: false, keepArmedForProgress: false),
            .disarm(ticket: ticket)
        )
    }

    func testRepeatedReconcileDoesNotReregisterAnArmedRequest() throws {
        var pump = AudioRendererPumpState()
        let ticket = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)

        XCTAssertEqual(
            pump.reconcile(hasPendingWork: true, keepArmedForProgress: false),
            .none
        )
        XCTAssertEqual(
            pump.reconcile(hasPendingWork: false, keepArmedForProgress: true),
            .none
        )
        XCTAssertTrue(pump.isCurrent(ticket))
    }

    func testInvalidateRegistrationFencesStaleTicketBeforeRearm() throws {
        var pump = AudioRendererPumpState()
        let stale = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)

        XCTAssertEqual(pump.invalidateRegistration(), .disarm(ticket: stale))
        XCTAssertFalse(pump.isCurrent(stale))
        let current = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: true)
        XCTAssertNotEqual(stale, current)
        XCTAssertFalse(pump.isCurrent(stale))
        XCTAssertTrue(pump.isCurrent(current))
    }

    func testRendererReplacementResetsRegistrationHistoryAndFencesTicket() throws {
        var pump = AudioRendererPumpState()
        let stale = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)

        XCTAssertEqual(pump.rendererDidChange(), .disarm(ticket: stale))
        XCTAssertFalse(pump.isCurrent(stale))
        _ = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)
    }

    func testRequestTicketExhaustionNeverWrapsOrReusesTicket() throws {
        var pump = AudioRendererPumpState(nextTicketRawValue: UInt64.max)
        let last = try armTicket(pump.reconcile(
            hasPendingWork: true,
            keepArmedForProgress: false
        ), expectedRearm: false)
        XCTAssertEqual(last.rawValue, UInt64.max)
        XCTAssertEqual(pump.invalidateRegistration(), .disarm(ticket: last))

        XCTAssertEqual(
            pump.reconcile(hasPendingWork: true, keepArmedForProgress: false),
            .none
        )
        XCTAssertFalse(pump.isRequestArmed)
        XCTAssertFalse(pump.isCurrent(last))
    }

    private func armTicket(
        _ action: AudioRendererPumpState.RequestAction,
        expectedRearm: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AudioRendererRequestTicket {
        guard case let .arm(ticket, isRearm) = action else {
            XCTFail("expected arm action", file: file, line: line)
            throw MissingAudioRequestTicket()
        }
        XCTAssertEqual(isRearm, expectedRearm, file: file, line: line)
        return ticket
    }
}

private struct MissingAudioRequestTicket: Error {}
