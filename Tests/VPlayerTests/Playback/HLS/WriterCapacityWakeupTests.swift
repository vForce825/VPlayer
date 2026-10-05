// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class WriterCapacityWakeupTests: XCTestCase {
    func testReleaseBeforeWaiterInstallationIsNotLostAndRollbackDoesNotWake() async throws {
        let clock = ManualPlaybackClock(0)
        let wakeup = try WriterCapacityWakeup.make(clock: clock)
        let original = wakeup.currentRevision
        var rollback: WriterInputLifetime? = WriterInputLifetime(capacityWakeup: wakeup)
        XCTAssertNotNil(rollback)
        rollback = nil
        XCTAssertEqual(wakeup.currentRevision, original)
        var native: WriterInputLifetime? = WriterInputLifetime(capacityWakeup: wakeup)
        native?.markNativeAdopted(); native = nil
        let ready = try await wakeup.wait(after: original, until: wakeup.makeDeadline())
        XCTAssertTrue(ready)
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
        XCTAssertEqual(clock.deadlineTimerHandlerInstallationCount, 1)
    }

    func testMonotonicDeadlineEndsTheOnlyWaitWithoutPolling() async throws {
        let clock = ManualPlaybackClock(0)
        let wakeup = try WriterCapacityWakeup.make(clock: clock)
        let revision = wakeup.currentRevision
        let deadline = try wakeup.makeDeadline()
        let task = Task { try await wakeup.wait(after: revision, until: deadline) }
        let limit = Date().addingTimeInterval(1)
        while !clock.hasScheduledDeadlineTimer && Date() < limit { await Task.yield() }
        XCTAssertTrue(clock.hasScheduledDeadlineTimer)
        clock.set(deadline)
        let result = try await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(clock.deadlineTimerDeliveryCount, 1)
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
    }

    func testCancellationWakesTheExactPendingWaiter() async throws {
        let clock = ManualPlaybackClock(0)
        let wakeup = try WriterCapacityWakeup.make(clock: clock)
        let revision = wakeup.currentRevision
        let deadline = try wakeup.makeDeadline()
        let task = Task { try await wakeup.wait(after: revision, until: deadline) }
        let limit = Date().addingTimeInterval(1)
        while !clock.hasScheduledDeadlineTimer && Date() < limit { await Task.yield() }
        wakeup.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
    }
}
