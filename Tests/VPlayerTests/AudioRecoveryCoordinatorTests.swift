// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class AudioRecoveryCoordinatorTests: XCTestCase {
    func testRouteChangeThenOutputConfigurationChangeRecoversWithBothCauses() throws {
        var subject = AudioRecoveryCoordinator()

        let collection = subject.ingest(.routeChanged)
        let ticket = try XCTUnwrap(collection.collectionTicket)
        XCTAssertEqual(collection, [.scheduleCollection(ticket)])
        XCTAssertEqual(subject.ingest(.outputConfigurationChanged), [])

        XCTAssertEqual(
            subject.collectionDeadlineFired(for: ticket),
            [
                .recover(ticket, causes: [.routeChanged, .outputConfigurationChanged]),
                .scheduleSettleExpiry(ticket)
            ]
        )
    }

    func testOutputConfigurationChangeThenRouteChangeRecoversWithBothCauses() throws {
        var subject = AudioRecoveryCoordinator()

        let collection = subject.ingest(.outputConfigurationChanged)
        let ticket = try XCTUnwrap(collection.collectionTicket)
        XCTAssertEqual(collection, [.scheduleCollection(ticket)])
        XCTAssertEqual(subject.ingest(.routeChanged), [])

        XCTAssertEqual(
            subject.collectionDeadlineFired(for: ticket),
            [
                .recover(ticket, causes: [.routeChanged, .outputConfigurationChanged]),
                .scheduleSettleExpiry(ticket)
            ]
        )
    }

    func testAutomaticFlushRecoversImmediatelyAndStartsSettleWindow() throws {
        var subject = AudioRecoveryCoordinator()

        let actions = subject.ingest(.automaticFlush)
        let ticket = try XCTUnwrap(actions.recoveryTicket)

        XCTAssertEqual(
            actions,
            [
                .recover(ticket, causes: [.automaticFlush]),
                .scheduleSettleExpiry(ticket)
            ]
        )
        XCTAssertEqual(AudioRecoveryCoordinator.collectionDelay, .milliseconds(120))
        XCTAssertEqual(AudioRecoveryCoordinator.settleDelay, .milliseconds(300))
    }

    func testAutomaticFlushDuringCollectionRecoversPendingCausesWithSameTicket() throws {
        var subject = AudioRecoveryCoordinator()
        let ticket = try XCTUnwrap(subject.ingest(.routeChanged).collectionTicket)
        XCTAssertEqual(subject.ingest(.outputConfigurationChanged), [])

        XCTAssertEqual(
            subject.ingest(.automaticFlush),
            [
                .recover(ticket, causes: [.routeChanged, .outputConfigurationChanged, .automaticFlush]),
                .scheduleSettleExpiry(ticket)
            ]
        )
        XCTAssertEqual(subject.collectionDeadlineFired(for: ticket), [])
    }

    func testSignalsDuringSettleAreSuppressedAndCorrelatedToCurrentTicket() throws {
        var subject = AudioRecoveryCoordinator()
        let ticket = try XCTUnwrap(subject.ingest(.automaticFlush).recoveryTicket)

        XCTAssertEqual(
            subject.ingest(.routeChanged),
            [.suppressed(ticket, cause: .routeChanged)]
        )
        XCTAssertEqual(
            subject.ingest(.outputConfigurationChanged),
            [.suppressed(ticket, cause: .outputConfigurationChanged)]
        )
    }

    func testSecondAutomaticFlushDuringSettleStartsNewRecoveryTicket() throws {
        var subject = AudioRecoveryCoordinator()
        let firstTicket = try XCTUnwrap(subject.ingest(.automaticFlush).recoveryTicket)

        let actions = subject.ingest(.automaticFlush)
        let secondTicket = try XCTUnwrap(actions.recoveryTicket)

        XCTAssertNotEqual(secondTicket, firstTicket)
        XCTAssertEqual(secondTicket.rawValue, firstTicket.rawValue + 1)
        XCTAssertEqual(
            actions,
            [
                .recover(secondTicket, causes: [.automaticFlush]),
                .scheduleSettleExpiry(secondTicket)
            ]
        )
    }

    func testStaleCollectionAndSettleDeadlinesAreNoOps() throws {
        var subject = AudioRecoveryCoordinator()
        let firstTicket = try XCTUnwrap(subject.ingest(.routeChanged).collectionTicket)
        let collectingFlush = subject.ingest(.automaticFlush)
        XCTAssertEqual(collectingFlush.recoveryTicket, firstTicket)

        let secondTicket = try XCTUnwrap(subject.ingest(.automaticFlush).recoveryTicket)
        XCTAssertEqual(subject.collectionDeadlineFired(for: firstTicket), [])
        XCTAssertEqual(subject.settleDeadlineFired(for: firstTicket), [])
        XCTAssertEqual(
            subject.ingest(.routeChanged),
            [.suppressed(secondTicket, cause: .routeChanged)]
        )
    }

    func testInvalidateMakesOutstandingCallbacksNoOpsWithoutResettingTickets() throws {
        var subject = AudioRecoveryCoordinator()
        let collectionTicket = try XCTUnwrap(subject.ingest(.routeChanged).collectionTicket)

        subject.invalidate()
        XCTAssertEqual(subject.collectionDeadlineFired(for: collectionTicket), [])

        let settleTicket = try XCTUnwrap(subject.ingest(.automaticFlush).recoveryTicket)
        subject.invalidate()
        XCTAssertEqual(subject.settleDeadlineFired(for: settleTicket), [])

        let nextTicket = try XCTUnwrap(subject.ingest(.routeChanged).collectionTicket)
        XCTAssertEqual(nextTicket.rawValue, settleTicket.rawValue + 1)
    }

    func testActiveSettleExpiryAllowsLaterRouteSignalToStartFreshCollection() throws {
        var subject = AudioRecoveryCoordinator()
        let settledTicket = try XCTUnwrap(subject.ingest(.automaticFlush).recoveryTicket)

        XCTAssertEqual(subject.settleDeadlineFired(for: settledTicket), [])

        let actions = subject.ingest(.routeChanged)
        let nextTicket = try XCTUnwrap(actions.collectionTicket)
        XCTAssertEqual(nextTicket.rawValue, settledTicket.rawValue + 1)
        XCTAssertEqual(actions, [.scheduleCollection(nextTicket)])
    }
}

private extension Array where Element == AudioRecoveryAction {
    var collectionTicket: AudioRecoveryTicket? {
        compactMap { action -> AudioRecoveryTicket? in
            guard case let .scheduleCollection(ticket) = action else { return nil }
            return ticket
        }.first
    }

    var recoveryTicket: AudioRecoveryTicket? {
        compactMap { action -> AudioRecoveryTicket? in
            guard case let .recover(ticket, causes: _) = action else { return nil }
            return ticket
        }.first
    }
}
