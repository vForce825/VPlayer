// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import XCTest
@testable import VPlayerPlayback

final class PresentationRelayTests: XCTestCase {
    func testSecondSubscriberIsRejectedBeforeItCanReceiveAContinuation() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let first = try relay.presentations()

        XCTAssertThrowsError(try relay.presentations()) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .subscriberAlreadyActive)
        }
        var iterator = first.makeAsyncIterator()
        let firstValue = await iterator.next()
        XCTAssertNotNil(firstValue)
    }

    func testBufferingNewestDropsIntermediateNilButKeepsLatestReplacement() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let sample = identifiedSampleBuffer(nonce: 11)
        let player = identifiedAVPlayer(nonce: 12)

        try relay.replace(with: sample)
        try relay.replace(with: nil)
        try relay.replace(with: player)

        let nextReplacement = await iterator.next()
        let replacement = try XCTUnwrap(nextReplacement)
        XCTAssertEqual(replacement.desired?.identity, player.identity)
        XCTAssertEqual(replacement.revision, 3)
    }

    func testDroppedBufferedEnvelopeReleasesItsPresentationContext() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        weak var droppedContext: PlaybackPresentationContext?

        do {
            let context = PlaybackPresentationContext()
            droppedContext = context
            try relay.replace(with: identifiedSampleBuffer(nonce: 21, context: context))
        }
        try relay.replace(with: identifiedAVPlayer(nonce: 22))

        XCTAssertNil(droppedContext)
    }

    func testTerminationPublishesNilBeforeFinishingStream() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        try relay.replace(with: identifiedSampleBuffer(nonce: 31))
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNotNil(initial?.desired)

        relay.finish()

        let nextTerminal = await iterator.next()
        let terminal = try XCTUnwrap(nextTerminal)
        XCTAssertNil(terminal.desired)
        let afterTerminal = await iterator.next()
        XCTAssertNil(afterTerminal)
    }

    func testOldSubscriptionTerminationCannotClearReplacementSubscription() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let first = try relay.presentations()
        var firstIterator = first.makeAsyncIterator()
        let firstReplacement = await firstIterator.next()
        let firstGeneration = try XCTUnwrap(firstReplacement?.subscriptionGeneration)
        let canceledConsumer = Task {
            for await _ in first {}
        }
        canceledConsumer.cancel()
        await canceledConsumer.value
        try await eventually { relay.activeSubscriptionGeneration == nil }

        let second = try relay.presentations()
        var secondIterator = second.makeAsyncIterator()
        let secondReplacement = await secondIterator.next()
        let secondGeneration = try XCTUnwrap(secondReplacement?.subscriptionGeneration)
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        relay.terminateSubscription(firstGeneration)
        try relay.replace(with: identifiedAVPlayer(nonce: 42))

        let nextReplacement = await secondIterator.next()
        let replacement = try XCTUnwrap(nextReplacement)
        XCTAssertEqual(replacement.subscriptionGeneration, secondGeneration)
        XCTAssertEqual(replacement.desired?.identity.presentationNonce, 42)
    }

    func testRevisionAndSubscriptionGenerationOverflowFinishRelay() async throws {
        let generationAllocator = PlaybackIdentityAllocator(
            initialIssuedValue: UInt64.max,
            initialNamespace: .subscription
        )
        let generationRelay = PlaybackPresentationRelay(allocator: generationAllocator)
        XCTAssertThrowsError(try generationRelay.presentations()) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .identitySpaceExhausted)
        }

        let revisionRelay = PlaybackPresentationRelay(
            allocator: PlaybackIdentityAllocator(),
            initialRevision: UInt64.max - 2
        )
        let stream = try revisionRelay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        var context: PlaybackPresentationContext? = PlaybackPresentationContext()
        weak var releasedContext: PlaybackPresentationContext?
        releasedContext = context
        try revisionRelay.replace(with: identifiedSampleBuffer(
            nonce: 51,
            context: try XCTUnwrap(context)
        ))
        var retained = await iterator.next()
        XCTAssertNotNil(retained?.desired)
        let retainedRevision = try XCTUnwrap(retained?.revision)
        retained = nil
        context = nil
        XCTAssertNotNil(releasedContext)
        XCTAssertThrowsError(try revisionRelay.replace(with: identifiedAVPlayer(nonce: 52))) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .identitySpaceExhausted)
        }
        let terminal = await iterator.next()
        XCTAssertNil(terminal?.desired)
        XCTAssertGreaterThan(terminal?.revision ?? 0, retainedRevision)
        let afterTerminal = await iterator.next()
        XCTAssertNil(afterTerminal)
        XCTAssertNil(releasedContext)
        XCTAssertThrowsError(try revisionRelay.presentations()) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .terminal)
        }
    }

    func testNormalFinishAllowsNewSubscriptionWithMonotonicGenerationAndRevision() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let first = try relay.presentations()
        var firstIterator = first.makeAsyncIterator()
        let nextFirstInitial = await firstIterator.next()
        let firstInitial = try XCTUnwrap(nextFirstInitial)

        relay.finish()

        let nextFirstTerminal = await firstIterator.next()
        let firstTerminal = try XCTUnwrap(nextFirstTerminal)
        XCTAssertNil(firstTerminal.desired)
        let afterFirstTerminal = await firstIterator.next()
        XCTAssertNil(afterFirstTerminal)

        let second = try relay.presentations()
        var secondIterator = second.makeAsyncIterator()
        let nextSecondInitial = await secondIterator.next()
        let secondInitial = try XCTUnwrap(nextSecondInitial)
        XCTAssertGreaterThan(
            secondInitial.subscriptionGeneration,
            firstInitial.subscriptionGeneration
        )
        XCTAssertGreaterThan(secondInitial.revision, firstInitial.revision)
    }

    func testSubscriptionGenerationOverflowPermanentlyReleasesDesiredPresentation() throws {
        let allocator = PlaybackIdentityAllocator(
            initialIssuedValue: UInt64.max,
            initialNamespace: .subscription
        )
        let relay = PlaybackPresentationRelay(allocator: allocator)
        weak var releasedContext: PlaybackPresentationContext?
        do {
            let context = PlaybackPresentationContext()
            releasedContext = context
            try relay.replace(with: identifiedSampleBuffer(nonce: 61, context: context))
        }

        XCTAssertThrowsError(try relay.presentations()) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .identitySpaceExhausted)
        }
        XCTAssertNil(releasedContext)
        XCTAssertThrowsError(try relay.presentations()) { error in
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .terminal)
        }
    }

    func testDelayedNonNilDeliveryCannotOvertakeNewerTerminalNil() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let delayed = try prepare(identifiedSampleBuffer(nonce: 71), on: relay)

        relay.finish()
        relay.deliver(delayed)

        let terminal = await iterator.next()
        XCTAssertNil(terminal?.desired)
        let afterTerminal = await iterator.next()
        XCTAssertNil(afterTerminal)
    }

    func testDelayedDeliveryFromFinishedGenerationCannotEnterReplacementGeneration() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let firstStream = try relay.presentations()
        var firstIterator = firstStream.makeAsyncIterator()
        let nextFirstInitial = await firstIterator.next()
        let firstInitial = try XCTUnwrap(nextFirstInitial)
        let delayed = try prepare(identifiedSampleBuffer(nonce: 72), on: relay)

        relay.finish()
        _ = await firstIterator.next()
        let afterFirstTerminal = await firstIterator.next()
        XCTAssertNil(afterFirstTerminal)
        let secondStream = try relay.presentations()
        var secondIterator = secondStream.makeAsyncIterator()
        let nextSecondInitial = await secondIterator.next()
        let secondInitial = try XCTUnwrap(nextSecondInitial)
        XCTAssertGreaterThan(
            secondInitial.subscriptionGeneration,
            firstInitial.subscriptionGeneration
        )

        relay.deliver(delayed)
        try relay.replace(with: identifiedAVPlayer(nonce: 73))

        let nextReplacement = await secondIterator.next()
        let replacement = try XCTUnwrap(nextReplacement)
        XCTAssertEqual(replacement.desired?.identity.presentationNonce, 73)
        XCTAssertEqual(replacement.subscriptionGeneration, secondInitial.subscriptionGeneration)
    }

    func testConcurrentReplacementCannotYieldOlderEnvelopeAfterNewerRevisionCommitted() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let first = identifiedSampleBuffer(nonce: 81)
        let second = identifiedAVPlayer(nonce: 82)
        let firstReachedYieldGate = expectation(description: "G1已通过Relay最终校验")
        let firstDeliveryFinished = expectation(description: "G1 delivery结束")
        let secondDeliveryFinished = expectation(description: "G2未被Relay锁阻塞")
        let releaseFirst = DispatchSemaphore(value: 0)
        let errors = RelayConcurrentErrorBox()

        relay.setDeliveryHooksForTesting(before: { revision, terminal in
            guard revision == 1, !terminal else { return }
            firstReachedYieldGate.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 2)
        })

        DispatchQueue.global().async {
            do { try relay.replace(with: first) }
            catch { errors.append(error) }
            firstDeliveryFinished.fulfill()
        }
        await fulfillment(of: [firstReachedYieldGate], timeout: 1)

        DispatchQueue.global().async {
            do { try relay.replace(with: second) }
            catch { errors.append(error) }
            secondDeliveryFinished.fulfill()
        }
        await fulfillment(of: [secondDeliveryFinished], timeout: 1)
        releaseFirst.signal()
        await fulfillment(of: [firstDeliveryFinished], timeout: 1)

        XCTAssertTrue(errors.values.isEmpty)
        let newest = await iterator.next()
        XCTAssertEqual(
            newest?.desired?.identity,
            second.identity,
            "G2提交后，迟到的G1真实yield不得覆盖bufferingNewest中的高revision"
        )
        XCTAssertEqual(newest?.revision, 2)
    }

    func testPrepareReplacementIdentityExhaustionStillDeliversTerminalNilThenEOF() async throws {
        let relay = PlaybackPresentationRelay(
            allocator: PlaybackIdentityAllocator(),
            initialRevision: UInt64.max - 2
        )
        let stream = try relay.presentations()
        let terminalNil = expectation(description: "prepare耗尽仍交付terminal nil")
        let eof = expectation(description: "prepare耗尽仍结束stream")
        let collector = Task {
            for await replacement in stream {
                if replacement.desired == nil, replacement.revision == UInt64.max {
                    terminalNil.fulfill()
                }
            }
            eof.fulfill()
        }

        let first = try prepare(identifiedSampleBuffer(nonce: 91), on: relay)
        relay.deliver(first)
        switch relay.prepareAuthoritativeReplacement(with: identifiedAVPlayer(nonce: 92)) {
        case .identitySpaceExhausted(let terminalDelivery):
            relay.deliver(terminalDelivery)
        case .prepared, .terminal:
            XCTFail("revision耗尽必须返回带terminal effect的明确结果")
        }

        await fulfillment(of: [terminalNil, eof], timeout: 0.5, enforceOrder: true)
        collector.cancel()
        await collector.value
    }

    func testTenThousandReplacementStormKeepsOnlyNewestEnvelope() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let stream = try relay.presentations()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let sharedContext = AVPlayerPresentationContext(player: AVPlayer())

        for nonce in 1...10_000 {
            try relay.replace(with: IdentifiedPlaybackPresentation(
                identity: identity(nonce: UInt64(nonce)),
                presentation: .avPlayer(sharedContext)
            ))
        }

        let latest = await iterator.next()
        XCTAssertEqual(latest?.desired?.identity.presentationNonce, 10_000)
        XCTAssertEqual(latest?.revision, 10_000)
    }

    private func identifiedSampleBuffer(
        nonce: UInt64,
        context: PlaybackPresentationContext = PlaybackPresentationContext()
    ) -> IdentifiedPlaybackPresentation {
        IdentifiedPlaybackPresentation(
            identity: identity(nonce: nonce),
            presentation: .sampleBuffer(context)
        )
    }

    private func identifiedAVPlayer(nonce: UInt64) -> IdentifiedPlaybackPresentation {
        IdentifiedPlaybackPresentation(
            identity: identity(nonce: nonce),
            presentation: .avPlayer(AVPlayerPresentationContext(player: AVPlayer()))
        )
    }

    private func prepare(
        _ presentation: IdentifiedPlaybackPresentation?,
        on relay: PlaybackPresentationRelay
    ) throws -> PlaybackPresentationRelay.PreparedDelivery {
        switch relay.prepareAuthoritativeReplacement(with: presentation) {
        case .prepared(let delivery):
            return delivery
        case .identitySpaceExhausted(let delivery):
            relay.deliver(delivery)
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        case .terminal(let delivery):
            relay.deliver(delivery)
            throw PlaybackPresentationRelayError.terminal
        }
    }

    private func identity(nonce: UInt64) -> PresentationIdentity {
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: nonce)
        return PresentationIdentity(
            sessionIdentity: session,
            backendIdentity: backend,
            outputLifecycleEpoch: OutputLifecycleEpoch(
                backendIdentity: backend,
                outputNonce: nonce
            ),
            itemGeneration: nil,
            presentationNonce: nonce
        )
    }

    private func eventually(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("条件未在期限内满足")
    }
}

private final class RelayConcurrentErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ error: Error) { lock.withLock { stored.append(String(describing: error)) } }
}
