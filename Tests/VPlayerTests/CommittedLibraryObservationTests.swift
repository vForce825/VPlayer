// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData
import XCTest
@testable import VPlayerCore
@testable import VPlayer

@MainActor
final class CommittedLibraryObservationTests: XCTestCase {
    func testExternalProfileChangesReachExistingCoalescedSignal() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = profile()
        context.insert(profile)
        try context.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        let initialProfiles = try await store.profiles()
        XCTAssertEqual(initialProfiles.first?.name, "Home")
        let stream = try await store.committedChanges()
        var iterator = stream.makeAsyncIterator()
        let firstSnapshot = await iterator.next()
        let baseline = try XCTUnwrap(firstSnapshot)
        let signal = LibraryChangeSignal()
        let changed = expectation(description: "External committed profile observed")
        let task = Task { @MainActor in
            var iterator = iterator
            if let snapshot = await iterator.next(), let change = snapshot.change(since: baseline) {
                signal.notify(change)
                changed.fulfill()
            }
        }
        profile.name = "External edit"
        try context.save()
        await fulfillment(of: [changed], timeout: 3)
        task.cancel()
        await task.value
        XCTAssertEqual(signal.reloadScope(after: 0), .full)
        let refreshedProfiles = try await store.profiles()
        XCTAssertEqual(refreshedProfiles.first?.name, "External edit", "The observer must refresh the repository's cached context too")
    }

    func testStagingRowsDoNotPublishAndPointerCommitRetainsRefreshClaim() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = profile()
        context.insert(profile)
        try context.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        let stream = try await store.committedChanges()
        var iterator = stream.makeAsyncIterator()
        let firstSnapshot = await iterator.next()
        let baseline = try XCTUnwrap(firstSnapshot)
        let signal = LibraryChangeSignal()
        let claim = signal.claimPersistedRefreshes(profileID: profile.id, resources: [.playlist])
        let changed = expectation(description: "Only committed pointer produces a change")
        let task = Task { @MainActor in
            var iterator = iterator
            if let next = await iterator.next(), let change = next.change(since: baseline) {
                XCTAssertEqual(change, .refreshes([profile.id: [.playlist]]))
                signal.notify(change)
                changed.fulfill()
            }
        }
        let snapshotID = UUID()
        context.insert(PlaylistSnapshotRecord(id: snapshotID, sourceProfileID: profile.id,
                                             fetchedAt: .now, channelCount: 0))
        try context.save()
        await Task.yield()
        XCTAssertEqual(signal.generation, 0)
        profile.playlistSnapshotID = snapshotID
        profile.m3uLastSuccessAt = .now
        profile.updatedAt = .now
        try context.save()
        await fulfillment(of: [changed], timeout: 3)
        task.cancel()
        await task.value
        XCTAssertEqual(signal.generation, 0, "Observer must not bypass an existing refresh claim")
        signal.releasePersistedRefreshes(claim, publishesPendingChanges: true)
        XCTAssertEqual(signal.reloadScope(after: 0), .refreshes([profile.id: [.playlist]]))
    }

    func testProductionBridgeRegistersBaselineBeforeReturningAndCoalesces() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let store = SwiftDataLibraryStore(modelContainer: container)
        let signal = LibraryChangeSignal()
        try await signal.observeCommittedChanges(in: store)
        let context = ModelContext(container)
        context.insert(profile())
        try context.save()
        for _ in 0..<200 {
            if signal.generation > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(signal.generation, 0)
        XCTAssertEqual(signal.reloadScope(after: 0), .full)
    }

    func testFailedLocalSaveDoesNotPublishRolledBackMetadata() async throws {
        struct RejectedSave: Error {}
        let container = try VPlayerModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = profile()
        context.insert(profile)
        try context.save()
        let store = SwiftDataLibraryStore(modelContainer: container, saveFault: { phase in
            if phase == .profileUpdate { throw RejectedSave() }
        })
        let stream = try await store.committedChanges()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let updated = try SourceProfileInput(
            name: "Must roll back", m3uURLString: profile.m3uURLString,
            epgURLString: profile.epgURLString, m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        ).validated()
        do {
            try await store.updateProfile(id: profile.id, input: updated, now: .now)
            XCTFail("Injected profile save should fail")
        } catch is RejectedSave {}
        let changed = expectation(description: "External commit after rollback")
        let profileID = profile.id
        let task = Task { @MainActor in
            var iterator = iterator
            if let snapshot = await iterator.next() {
                XCTAssertEqual(snapshot.profiles[profileID]?.configuration.name, "Committed externally")
                changed.fulfill()
            }
        }
        profile.name = "Committed externally"
        try context.save()
        await fulfillment(of: [changed], timeout: 3)
        task.cancel()
        await task.value
    }

    private func profile() -> SourceProfileRecord {
        .init(id: UUID(), name: "Home", m3uURLString: "https://example.invalid/live.m3u",
              epgURLString: "https://example.invalid/guide.xml", m3uRefreshIntervalRaw: 0,
              epgRefreshIntervalRaw: 0, createdAt: .now, updatedAt: .now)
    }
}
