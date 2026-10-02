// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class AVPlayerAsyncLogReaderTests: XCTestCase {
    func testDelayedCoalescedReadPreservesConflictBeforeMatchingTail() async throws {
        let reader = DelayedAVPlayerLogReader(
            first: ["http://127.0.0.1/conflict", "http://127.0.0.1/matching"],
            subsequent: ["http://127.0.0.1/conflict", "http://127.0.0.1/matching"])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let item = makeItem(1)
        try driver.install(url: URL(fileURLWithPath: "/tmp/VPlayer-delayed-log.m3u8"), identity: item)
        var classifications: [AccessLogURIClassification] = []
        try driver.installAccessLogURIObservation(item: item,
            classify: { $0.path == "/conflict" ? .conflicting : .matching },
            handler: { classification, _ in classifications.append(classification) })
        let started = await reader.waitForReadCount(1)
        XCTAssertTrue(started, "Initial read must start without a notification")
        for _ in 0..<10_000 {
            NotificationCenter.default.post(name: AVPlayerItem.newAccessLogEntryNotification,
                object: driver.player.currentItem)
        }
        XCTAssertEqual(reader.accessReadCount, 1)
        reader.releaseFirstRead()
        let followedUp = await reader.waitForReadCount(2)
        XCTAssertTrue(followedUp)
        let physical = try XCTUnwrap(driver.player.currentItem)
        let published = await waitUntil {
            classifications.contains(.conflicting) && driver.logSnapshotCache.snapshot(item: item,
                objectIdentity: ObjectIdentifier(physical)).accessEventCount == 2
        }
        XCTAssertTrue(published)
        XCTAssertTrue(classifications.contains(.conflicting),
            "The matching last entry must not erase an earlier conflict in the fetched batch")
        XCTAssertFalse(classifications.contains(.matching))
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
        XCTAssertEqual(driver.logSnapshotCache.snapshot(item: item,
            objectIdentity: ObjectIdentifier(physical)).accessEventCount, 2)
        driver.replaceCurrentItemWithNil(item: item)
        await drainMainQueue()
    }

    func testDelayedOldItemAndLifecycleBatchCannotPublishConflictIntoSuccessor() async throws {
        let reader = DelayedAVPlayerLogReader(
            first: ["http://127.0.0.1/conflict", "http://127.0.0.1/matching"],
            subsequent: ["http://127.0.0.1/matching"])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let old = makeItem(2), successor = makeItem(3)
        var classifications: [AccessLogURIClassification] = []
        try install(driver, item: old) { classifications.append($0) }
        let started = await reader.waitForReadCount(1)
        XCTAssertTrue(started)
        driver.replaceCurrentItemWithNil(item: old)
        try install(driver, item: successor) { classifications.append($0) }
        XCTAssertEqual(reader.accessReadCount, 1,
            "Replacement cannot admit a second fetch beside an obsolete physical read")
        reader.releaseFirstRead()
        let followedUp = await reader.waitForReadCount(2)
        XCTAssertTrue(followedUp)
        let physical = try XCTUnwrap(driver.player.currentItem)
        let published = await waitUntil {
            classifications.contains(.matching) && driver.logSnapshotCache.snapshot(item: successor,
                objectIdentity: ObjectIdentifier(physical)).accessEventCount == 1
        }
        XCTAssertTrue(published)
        XCTAssertTrue(classifications.contains(.matching))
        XCTAssertFalse(classifications.contains(.conflicting))
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
        XCTAssertEqual(driver.logSnapshotCache.snapshot(item: successor,
            objectIdentity: ObjectIdentifier(physical)).accessEventCount, 1)
        driver.replaceCurrentItemWithNil(item: successor)
        await drainMainQueue()
    }

    func testRetiredDelayedBatchCannotPublishOrRestoreMetrics() async throws {
        let reader = DelayedAVPlayerLogReader(
            first: ["http://127.0.0.1/conflict", "http://127.0.0.1/matching"], subsequent: [])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let item = makeItem(4)
        var classifications: [AccessLogURIClassification] = []
        try install(driver, item: item) { classifications.append($0) }
        let physical = try XCTUnwrap(driver.player.currentItem)
        let started = await reader.waitForReadCount(1)
        XCTAssertTrue(started)
        driver.replaceCurrentItemWithNil(item: item)
        reader.releaseFirstRead()
        await drainMainQueue()
        XCTAssertTrue(classifications.isEmpty)
        XCTAssertEqual(driver.logSnapshotCache.snapshot(item: item,
            objectIdentity: ObjectIdentifier(physical)), .empty)
        XCTAssertEqual(reader.accessReadCount, 1)
    }

    func testDelayedBatchPreservesCurrentInvalidResourceAgainstConflictAndBenignTail() async throws {
        let reader = DelayedAVPlayerLogReader(first: [
            "http://127.0.0.1/invalid", "http://127.0.0.1/conflict",
            "http://127.0.0.1/invalid", "http://127.0.0.1/matching",
            "http://127.0.0.1/unrelated"
        ], subsequent: [])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let item = makeItem(5)
        var classifications: [AccessLogURIClassification] = []
        try install(driver, item: item) { classifications.append($0) }
        defer { driver.replaceCurrentItemWithNil(item: item) }
        let started = await reader.waitForReadCount(1)
        XCTAssertTrue(started)
        reader.releaseFirstRead()
        let physical = try XCTUnwrap(driver.player.currentItem)
        let published = await waitUntil {
            !classifications.isEmpty && driver.logSnapshotCache.snapshot(item: item,
                objectIdentity: ObjectIdentifier(physical)).accessEventCount == 5
        }
        XCTAssertTrue(published)
        XCTAssertEqual(classifications, [.invalidLocalResource],
            "One bounded reduction must preserve transport failure over conflict and benign entries")
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
        driver.replaceCurrentItemWithNil(item: item)
        await drainMainQueue()
    }

    func testHubCoalescingPreservesInvalidResourceInBothConflictOrders() async throws {
        let reader = DelayedAVPlayerLogReader(first: [], subsequent: [])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let item = makeItem(6)
        var classifications: [AccessLogURIClassification] = []
        try install(driver, item: item) { classifications.append($0) }
        defer { driver.replaceCurrentItemWithNil(item: item) }
        reader.releaseFirstRead()
        await drainMainQueue()
        for events: [AccessLogURIClassification] in [
            [.invalidLocalResource, .matching, .conflicting, .unrelated],
            [.conflicting, .invalidLocalResource, .matching, .unrelated]
        ] {
            classifications.removeAll()
            for event in events { driver.eventHub.receive(event, item: item) }
            await drainMainQueue()
            XCTAssertEqual(classifications, [.invalidLocalResource],
                "A pending transport fault cannot be overwritten before its single queued delivery")
        }
        driver.replaceCurrentItemWithNil(item: item)
        await drainMainQueue()
    }

    func testDelayedOldInvalidResourceBatchCannotFaultCurrentItem() async throws {
        let reader = DelayedAVPlayerLogReader(first: ["http://127.0.0.1/invalid"],
                                              subsequent: ["http://127.0.0.1/matching"])
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), logReader: reader)
        let old = makeItem(7), successor = makeItem(8)
        var classifications: [AccessLogURIClassification] = []
        try install(driver, item: old) { classifications.append($0) }
        let started = await reader.waitForReadCount(1)
        XCTAssertTrue(started)
        driver.replaceCurrentItemWithNil(item: old)
        try install(driver, item: successor) { classifications.append($0) }
        defer { driver.replaceCurrentItemWithNil(item: successor) }
        reader.releaseFirstRead()
        let followedUp = await reader.waitForReadCount(2)
        XCTAssertTrue(followedUp)
        let published = await waitUntil { classifications.contains(.matching) }
        XCTAssertTrue(published)
        XCTAssertFalse(classifications.contains(.invalidLocalResource))
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
        driver.replaceCurrentItemWithNil(item: successor)
        await drainMainQueue()
    }

    private func install(_ driver: SystemAVPlayerDriver, item: AVPlayerItemInstanceIdentity,
                         handler: @escaping @MainActor @Sendable (AccessLogURIClassification) -> Void) throws {
        try driver.install(url: URL(fileURLWithPath: "/tmp/VPlayer-delayed-log.m3u8"), identity: item)
        try driver.installAccessLogURIObservation(item: item,
            classify: {
                switch $0.path {
                case "/invalid": .invalidLocalResource
                case "/conflict": .conflicting
                case "/unrelated": .unrelated
                default: .matching
                }
            }, handler: { classification, _ in handler(classification) })
    }

    private func makeItem(_ nonce: UInt64) -> AVPlayerItemInstanceIdentity {
        .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 27_200 + nonce),
            itemGeneration: nonce)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return condition()
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Only the SDK retrieval boundary is controlled. The production driver performs
/// ticket fencing, URI classification/reduction, coalescing, and publication.
@MainActor
private final class DelayedAVPlayerLogReader: AVPlayerLogReading {
    let first: [String]
    let subsequent: [String]
    private var gate: CheckedContinuation<Void, Never>?
    private var firstReadReleased = false
    private var activeReads = 0
    private(set) var accessReadCount = 0
    private(set) var maximumConcurrentReads = 0

    init(first: [String], subsequent: [String]) {
        self.first = first
        self.subsequent = subsequent
    }

    func readAccessLog(item: AVPlayerItem, visitURI: @MainActor (String) -> Void) async -> Int {
        accessReadCount += 1
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        let values = accessReadCount == 1 ? first : subsequent
        if accessReadCount == 1, !firstReadReleased {
            await withCheckedContinuation { gate = $0 }
        }
        for value in values { visitURI(value) }
        return values.count
    }

    func readErrorLogCount(item: AVPlayerItem) async -> Int { 0 }

    func releaseFirstRead() {
        firstReadReleased = true
        let continuation = gate
        gate = nil
        continuation?.resume()
    }

    func waitForReadCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while accessReadCount < count, ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return accessReadCount >= count
    }
}
