// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioRendererRecoveryProgressTests: XCTestCase {
    func testFirstFlushWithReplaySchedulesOneProgressDeadline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()

        let actions = monitor.automaticFlush(
            key: key(),
            token: token(),
            hasReplay: true
        )

        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.first, .replay)
        XCTAssertEqual(try deadlineTicket(actions).rawValue, 1)
    }

    func testCorrelatedFlushBeforeDeadlineDoesNotReplayAgain() {
        var monitor = AudioRendererRecoveryProgressMonitor()
        _ = monitor.automaticFlush(key: key(), token: token(), hasReplay: true)

        XCTAssertEqual(
            monitor.automaticFlush(key: key(), token: token(), hasReplay: true),
            []
        )
    }

    func testSharedPlayheadAdvanceDoesNotClearOriginalBaseline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let baseline = token(consumptionSequence: 4)
        let ticket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: baseline, hasReplay: true)
        )

        XCTAssertFalse(monitor.observeProgress(baseline))
        XCTAssertEqual(
            monitor.deadlineFired(ticket, token: baseline),
            [.rebuildCompressed]
        )
    }

    func testHigherAcceptedInputIDDoesNotClearOriginalBaseline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let rendererConsumptionUnchanged = token(consumptionSequence: 9)
        let ticket = try deadlineTicket(monitor.automaticFlush(
            key: key(),
            token: rendererConsumptionUnchanged,
            hasReplay: true
        ))

        XCTAssertFalse(monitor.observeProgress(rendererConsumptionUnchanged))
        XCTAssertEqual(
            monitor.deadlineFired(ticket, token: rendererConsumptionUnchanged),
            [.rebuildCompressed]
        )
    }

    func testSharedClockAndAcceptedInputDoNotClearReplacementBaseline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let original = token(rendererID: 1, consumptionSequence: 2)
        let originalTicket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: original, hasReplay: true)
        )
        XCTAssertEqual(
            monitor.deadlineFired(originalTicket, token: original),
            [.rebuildCompressed]
        )

        let replacement = token(rendererID: 2, consumptionSequence: 0)
        let replacementTicket = try deadlineTicket(monitor.replacementReady(
            key: key(),
            token: replacement,
            hasReplay: true
        ))

        XCTAssertFalse(monitor.observeProgress(replacement))
        XCTAssertEqual(
            monitor.deadlineFired(replacementTicket, token: replacement),
            [.fallbackPCM]
        )
    }

    func testConsumptionSequenceAdvanceOnSameRendererLifetimeClearsBaseline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let baseline = token(consumptionSequence: 7)
        let ticket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: baseline, hasReplay: true)
        )

        XCTAssertTrue(monitor.observeProgress(token(consumptionSequence: 8)))
        XCTAssertEqual(
            monitor.deadlineFired(ticket, token: token(consumptionSequence: 8)),
            []
        )
    }

    func testUnchangedOriginalDeadlineRequestsOneCompressedRebuild() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let current = token(consumptionSequence: 9)
        let ticket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: current, hasReplay: true)
        )

        XCTAssertEqual(monitor.deadlineFired(ticket, token: current), [.rebuildCompressed])
        XCTAssertEqual(monitor.deadlineFired(ticket, token: current), [])
    }

    func testUnchangedReplacementDeadlineRequestsPCM() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let original = token(rendererID: 1, consumptionSequence: 9)
        let originalTicket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: original, hasReplay: true)
        )
        XCTAssertEqual(
            monitor.deadlineFired(originalTicket, token: original),
            [.rebuildCompressed]
        )

        let replacement = token(rendererID: 2)
        let replacementTicket = try deadlineTicket(
            monitor.replacementReady(key: key(), token: replacement, hasReplay: true)
        )

        XCTAssertEqual(
            monitor.deadlineFired(replacementTicket, token: replacement),
            [.fallbackPCM]
        )
    }

    func testGenerationFormatRouteOrIslandChangeStartsNewAttempt() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let keys = [
            key(generation: 1, fingerprint: 1, route: 1, island: 1),
            key(generation: 2, fingerprint: 1, route: 1, island: 1),
            key(generation: 2, fingerprint: 2, route: 1, island: 1),
            key(generation: 2, fingerprint: 2, route: 2, island: 1),
            key(generation: 2, fingerprint: 2, route: 2, island: 2),
        ]

        for (index, attemptKey) in keys.enumerated() {
            let current = token(
                generation: attemptKey.generation.rawValue,
                island: UInt64(index + 1)
            )
            let ticket = try deadlineTicket(monitor.automaticFlush(
                key: attemptKey,
                token: current,
                hasReplay: true
            ))
            XCTAssertEqual(
                monitor.deadlineFired(ticket, token: current),
                [.rebuildCompressed],
                "changed attempt key must restore the one-rebuild budget"
            )
        }
    }

    func testNoReplayNeverConsumesRebuildBudget() {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let attemptKey = key()

        XCTAssertEqual(
            monitor.automaticFlush(key: attemptKey, token: token(), hasReplay: false),
            []
        )
        XCTAssertEqual(monitor.rendererFailed(key: attemptKey, hasReplay: false), [])
        XCTAssertEqual(
            monitor.rendererFailed(key: attemptKey, hasReplay: true),
            [.rebuildCompressed]
        )
    }

    func testStaleDeadlineTicketIsIgnored() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let first = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: token(), hasReplay: true)
        )
        XCTAssertTrue(monitor.observeProgress(token(consumptionSequence: 1)))
        let second = try deadlineTicket(monitor.automaticFlush(
            key: key(),
            token: token(consumptionSequence: 1),
            hasReplay: true
        ))

        XCTAssertEqual(
            monitor.deadlineFired(first, token: token(consumptionSequence: 1)),
            []
        )
        XCTAssertEqual(
            monitor.deadlineFired(second, token: token(consumptionSequence: 1)),
            [.rebuildCompressed]
        )
    }

    func testRendererIdentityEpochGenerationAndIslandMustAllMatchForProgress() throws {
        let mismatches = [
            token(rendererID: 2, consumptionSequence: 2),
            token(epoch: 2, consumptionSequence: 2),
            token(generation: 2, consumptionSequence: 2),
            token(island: 2, consumptionSequence: 2),
        ]
        for mismatch in mismatches {
            var monitor = AudioRendererRecoveryProgressMonitor()
            let baseline = token(consumptionSequence: 1)
            let ticket = try deadlineTicket(
                monitor.automaticFlush(key: key(), token: baseline, hasReplay: true)
            )

            XCTAssertFalse(monitor.observeProgress(mismatch))
            XCTAssertEqual(
                monitor.deadlineFired(ticket, token: mismatch),
                [.rebuildCompressed]
            )
        }
    }

    func testMissingCurrentTokenIsNoProgressNotSilentSuccess() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let ticket = try deadlineTicket(
            monitor.automaticFlush(key: key(), token: token(), hasReplay: true)
        )

        XCTAssertEqual(
            monitor.deadlineFired(ticket, token: nil),
            [.rebuildCompressed]
        )
    }

    func testAttemptChangeDuringRebuildStillGivesReplacementReplayAndFreshDeadline() throws {
        var monitor = AudioRendererRecoveryProgressMonitor()
        let original = token(rendererID: 1, generation: 1, island: 1)
        let originalTicket = try deadlineTicket(monitor.automaticFlush(
            key: key(generation: 1, fingerprint: 1, route: 1, island: 1),
            token: original,
            hasReplay: true
        ))
        XCTAssertEqual(
            monitor.deadlineFired(originalTicket, token: original),
            [.rebuildCompressed]
        )

        let replacement = token(rendererID: 2, generation: 1, island: 2)
        let actions = monitor.replacementReady(
            key: key(generation: 1, fingerprint: 1, route: 1, island: 2),
            token: replacement,
            hasReplay: true
        )

        XCTAssertEqual(actions.first, .replay)
        let replacementTicket = try deadlineTicket(actions)
        XCTAssertEqual(
            monitor.deadlineFired(replacementTicket, token: replacement),
            [.rebuildCompressed],
            "the changed attempt owns a fresh rebuild budget"
        )
    }

    func testMaximumDeadlineTicketIsIssuedOnceThenExhaustionFailsClosed() throws {
        var monitor = AudioRendererRecoveryProgressMonitor(
            testingNextTicketRawValue: UInt64.max
        )
        let attempt = key()
        let original = token(rendererID: 1)
        let maximumTicket = try deadlineTicket(monitor.automaticFlush(
            key: attempt,
            token: original,
            hasReplay: true
        ))

        XCTAssertEqual(maximumTicket.rawValue, UInt64.max)
        XCTAssertEqual(
            monitor.deadlineFired(maximumTicket, token: original),
            [.rebuildCompressed]
        )

        let replacement = token(rendererID: 2)
        XCTAssertEqual(
            monitor.replacementReady(
                key: attempt,
                token: replacement,
                hasReplay: true
            ),
            [.terminalTicketExhausted]
        )
        XCTAssertFalse(monitor.hasActiveBaseline)
        XCTAssertEqual(
            monitor.replacementReady(
                key: attempt,
                token: replacement,
                hasReplay: true
            ),
            [.terminalTicketExhausted],
            "exhaustion must not wrap or reuse the maximum ticket"
        )
        XCTAssertEqual(
            monitor.rendererFailed(key: attempt, hasReplay: true),
            [.fallbackPCM],
            "the fail-closed result must not restore the consumed rebuild budget"
        )
    }

    private func key(
        generation: UInt64 = 1,
        fingerprint: UInt8 = 1,
        route: UInt64 = 1,
        island: UInt64 = 1
    ) -> AudioCompressedAttemptKey {
        AudioCompressedAttemptKey(
            generation: MediaGeneration(rawValue: generation),
            fingerprint: MediaFormatFingerprint(bytes: Data([fingerprint])),
            routeRevision: route,
            islandID: AudioContinuityIslandID(rawValue: island)
        )
    }

    private func token(
        rendererID: UInt64 = 1,
        epoch: UInt64 = 1,
        generation: UInt64 = 1,
        island: UInt64 = 1,
        consumptionSequence: UInt64 = 0
    ) -> AudioRendererProgressToken {
        AudioRendererProgressToken(
            rendererID: AudioRendererIdentity(rawValue: rendererID),
            epoch: epoch,
            generation: MediaGeneration(rawValue: generation),
            islandID: AudioContinuityIslandID(rawValue: island),
            consumptionSequence: consumptionSequence
        )
    }

    private func deadlineTicket(
        _ actions: [AudioRendererProgressAction],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AudioRendererProgressTicket {
        for action in actions {
            if case let .scheduleDeadline(ticket) = action { return ticket }
        }
        XCTFail("missing progress deadline", file: file, line: line)
        throw MissingProgressTicket()
    }
}

final class AudioRendererDemandProgressStateTests: XCTestCase {
    private let renderer1 = AudioRendererIdentity(rawValue: 1)
    private let renderer2 = AudioRendererIdentity(rawValue: 2)

    func testReadyCallbackWithoutPostResetAcceptanceAndBackpressureIsNotConsumption() {
        var state = AudioRendererDemandProgressState()
        state.rendererDidChange(to: renderer1, epoch: 1)
        let episode = state.queueEpisode

        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: episode
        ))
        state.backpressured(rendererID: renderer1, epoch: 1, queueEpisode: episode)
        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: episode
        ))
        XCTAssertEqual(state.consumptionSequence, 0)
    }

    func testAcceptanceAloneIsNotConsumption() {
        var state = AudioRendererDemandProgressState()
        state.rendererDidChange(to: renderer1, epoch: 1)
        let episode = state.queueEpisode

        state.accepted(rendererID: renderer1, epoch: 1, queueEpisode: episode)

        XCTAssertEqual(state.consumptionSequence, 0)
        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: episode
        ))
    }

    func testAcceptedThenBackpressuredThenCurrentReadyAdvancesExactlyOnce() {
        var state = AudioRendererDemandProgressState()
        state.rendererDidChange(to: renderer1, epoch: 1)
        let episode = state.queueEpisode
        state.accepted(rendererID: renderer1, epoch: 1, queueEpisode: episode)
        state.backpressured(rendererID: renderer1, epoch: 1, queueEpisode: episode)

        XCTAssertTrue(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: episode
        ))
        XCTAssertEqual(state.consumptionSequence, 1)
        for _ in 0..<100 {
            XCTAssertFalse(state.readyAfterValidatedRequest(
                rendererID: renderer1,
                epoch: 1,
                queueEpisode: episode
            ))
        }
        XCTAssertEqual(state.consumptionSequence, 1)
    }

    func testStaleQueueEpisodeRendererAndEpochCannotAdvanceConsumption() {
        var state = AudioRendererDemandProgressState()
        state.rendererDidChange(to: renderer1, epoch: 1)
        let staleEpisode = state.queueEpisode
        state.accepted(rendererID: renderer1, epoch: 1, queueEpisode: staleEpisode)
        state.backpressured(rendererID: renderer1, epoch: 1, queueEpisode: staleEpisode)
        state.queueWasReset(rendererID: renderer1, epoch: 1)

        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: staleEpisode
        ))

        let currentEpisode = state.queueEpisode
        state.accepted(rendererID: renderer1, epoch: 1, queueEpisode: currentEpisode)
        state.backpressured(rendererID: renderer1, epoch: 1, queueEpisode: currentEpisode)
        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer2,
            epoch: 1,
            queueEpisode: currentEpisode
        ))
        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 2,
            queueEpisode: currentEpisode
        ))
        XCTAssertEqual(state.consumptionSequence, 0)
    }

    func testRendererChangeStartsFreshLifetimeAndNilCannotProduceToken() {
        var state = AudioRendererDemandProgressState()
        state.rendererDidChange(to: renderer1, epoch: 1)
        let firstEpisode = state.queueEpisode
        state.accepted(rendererID: renderer1, epoch: 1, queueEpisode: firstEpisode)
        state.backpressured(rendererID: renderer1, epoch: 1, queueEpisode: firstEpisode)
        XCTAssertTrue(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: firstEpisode
        ))

        state.rendererDidChange(to: renderer2, epoch: 1)
        XCTAssertEqual(state.consumptionSequence, 0)
        XCTAssertNotEqual(state.queueEpisode, firstEpisode)
        XCTAssertEqual(
            state.token(
                generation: MediaGeneration(rawValue: 1),
                islandID: AudioContinuityIslandID(rawValue: 1)
            )?.rendererID,
            renderer2
        )

        state.rendererDidChange(to: nil, epoch: 2)
        XCTAssertNil(state.token(
            generation: MediaGeneration(rawValue: 2),
            islandID: AudioContinuityIslandID(rawValue: 1)
        ))
    }

    func testQueueEpisodeExhaustionKeepsTokenButWithholdsConsumptionProgress() {
        var state = AudioRendererDemandProgressState(
            nextQueueEpisodeRawValue: UInt64.max
        )
        state.rendererDidChange(to: renderer1, epoch: 1)
        XCTAssertEqual(state.queueEpisode, UInt64.max)
        state.queueWasReset(rendererID: renderer1, epoch: 1)

        state.accepted(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: UInt64.max
        )
        state.backpressured(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: UInt64.max
        )
        XCTAssertFalse(state.readyAfterValidatedRequest(
            rendererID: renderer1,
            epoch: 1,
            queueEpisode: UInt64.max
        ))
        XCTAssertEqual(state.consumptionSequence, 0)
        XCTAssertNotNil(state.token(
            generation: MediaGeneration(rawValue: 1),
            islandID: AudioContinuityIslandID(rawValue: 1)
        ))
    }
}

private struct MissingProgressTicket: Error {}
