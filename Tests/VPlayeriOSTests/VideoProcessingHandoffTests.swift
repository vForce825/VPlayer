// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoProcessingHandoffTests: XCTestCase {
    func testBackgroundClosesGPUAdmissionAndFenceJoinsActualCompletion() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var ticket: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { ticket = $0 })
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail("GPU after background") })
        XCTAssertFalse(fence.wait(timeout: .now()))
        try XCTUnwrap(ticket).finish()
        XCTAssertTrue(fence.wait(timeout: .now()))
        ticket?.finish() // Completion is idempotent, never an over-release.
        XCTAssertTrue(fence.wait(timeout: .now()))
    }
    func testSecondBackgroundTransitionStillJoinsUnfinishedEarlierGPUWork() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var unfinished: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { unfinished = $0 })
        gate.setForeground(false)
        gate.setForeground(true)
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
        XCTAssertFalse(fence.wait(timeout: .now()))
        unfinished?.finish()
        XCTAssertTrue(fence.wait(timeout: .now()))
    }
    func testForegroundReturnsToGPUOnlyAfterPiPStops() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        gate.setPictureInPicture(true)
        XCTAssertNotNil(try gate.withGPUAdmission { _ in XCTFail("PiP must use CPU") })
        gate.setForeground(false)
        gate.setForeground(true)
        XCTAssertNotNil(try gate.withGPUAdmission { _ in XCTFail("Still in PiP") })
        gate.setPictureInPicture(false)
        XCTAssertNil(try gate.withGPUAdmission { $0.finish() })
    }
    func testRapidTransitionsDoNotStickInCPUOrBorrowLaterGPUFence() throws {
        let gate = GPUVideoProcessingGate()
        for _ in 0..<20 {
            gate.setForeground(true)
            var old: GPUVideoWorkTicket?
            XCTAssertNil(try gate.withGPUAdmission { old = $0 })
            gate.setForeground(false)
            let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
            gate.setForeground(true)
            var current: GPUVideoWorkTicket?
            XCTAssertNil(try gate.withGPUAdmission { current = $0 })
            old?.finish()
            XCTAssertTrue(fence.wait(timeout: .now()), "A retired fence cannot wait for later foreground work")
            current?.finish()
        }
    }
}

@MainActor
final class IOSPlayerTransportAuthorityTests: XCTestCase {
    func testProductionDriverUsesTheControlledPlayerBoundary() throws {
        let driver = try SystemAVPlayerDriver.make()
        XCTAssertTrue(driver.player is IOSControlledAVPlayer)
    }
    func testPublicPiPTransportEntryPointsDoNotMutateBeforeAuthority() async {
        let player = IOSControlledAVPlayer()
        var requests: [Bool] = []
        player.setTransportIntentHandler { requests.append($0) }
        player.play()
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        XCTAssertEqual(requests, [false])
        player.pause()
        await flushMainDelivery()
        XCTAssertEqual(requests, [false, true])
        player.rate = 1
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        player.playImmediately(atRate: 1)
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        player.setRate(1, time: .invalid, atHostTime: .invalid)
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        XCTAssertEqual(requests, [false, true, false, false, false])
        player.performDriverMutation { player.pause() }
        await flushMainDelivery()
        XCTAssertEqual(requests.count, 5, "Authorized driver mutations cannot loop into UI intents")
    }
    private func flushMainDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func testBurstControlsCoalesceAndLateLayerDetachPreservesNewOwner() async {
        let player = IOSControlledAVPlayer()
        let context = AVPlayerPresentationContext(player: player)
        let oldLayer = AVPlayerLayer()
        let currentLayer = AVPlayerLayer()
        context.attach(to: oldLayer)
        var oldRequests = 0
        XCTAssertTrue(context.setPictureInPictureTransportHandler({ _ in oldRequests += 1 }, for: oldLayer))
        player.pause()
        context.attach(to: currentLayer)
        var latest: [Bool] = []
        XCTAssertTrue(context.setPictureInPictureTransportHandler({ latest.append($0) }, for: currentLayer))
        XCTAssertFalse(context.setPictureInPictureTransportHandler(nil, for: oldLayer))
        context.detach(from: oldLayer)
        player.play()
        player.pause()
        player.play()
        await flushMainDelivery()
        XCTAssertEqual(latest, [false])
        XCTAssertEqual(oldRequests, 0)
        XCTAssertTrue(currentLayer.player === player)
        XCTAssertNil(oldLayer.player)
        context.detach(from: currentLayer)
    }
    func testRetiringTransportOwnerDiscardsQueuedIntents() async {
        let player = IOSControlledAVPlayer()
        var old = 0
        player.setTransportIntentHandler { _ in old += 1 }
        player.play()
        player.setTransportIntentHandler(nil)
        await flushMainDelivery()
        XCTAssertEqual(old, 0)
        XCTAssertEqual(player.rate, 0)
    }
}

private final class HandoffEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

final class GPUSubmissionReturnTests: XCTestCase {
    func testEarlyCompletionWaitsForSubmissionReturnAndIsDeliveredOnce() {
        let events = HandoffEvents()
        let latch = GPUSubmissionReturn<Int> { value in events.append("complete:\(value)") }
        latch.receive(1)
        latch.receive(99)
        XCTAssertEqual(events.snapshot, [])
        events.append("resources-released")
        latch.submissionReturned()
        latch.receive(2)
        latch.submissionReturned()
        XCTAssertEqual(events.snapshot, ["resources-released", "complete:1"])
    }
    func testDelayedGPUCompletionPublishesBeforeWaitingCPUSuccessor() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var admitted: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { admitted = $0 })
        let ticket = try XCTUnwrap(admitted)
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
        let events = HandoffEvents()
        let finished = expectation(description: "CPU joins prior GPU publication")
        let latch = GPUSubmissionReturn<Int> { _ in
            events.append("GPU")
            ticket.finish()
        }
        latch.submissionReturned()
        DispatchQueue.global().async {
            XCTAssertTrue(fence.wait(timeout: .now() + .seconds(2)))
            events.append("CPU")
            finished.fulfill()
        }
        latch.receive(1)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(events.snapshot, ["GPU", "CPU"])
    }
}
