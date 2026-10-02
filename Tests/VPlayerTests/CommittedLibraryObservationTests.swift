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
        let firstSnapshot = await iterator.next(isolation: MainActor.shared)
        let baseline = try XCTUnwrap(firstSnapshot)
        let signal = LibraryChangeSignal()
        let changed = expectation(description: "External committed profile observed")
        let task = Task { @MainActor in
            var iterator = iterator
            if let snapshot = await iterator.next(isolation: MainActor.shared), let change = snapshot.change(since: baseline) {
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
        let firstSnapshot = await iterator.next(isolation: MainActor.shared)
        let baseline = try XCTUnwrap(firstSnapshot)
        let signal = LibraryChangeSignal()
        let claim = signal.claimPersistedRefreshes(profileID: profile.id, resources: [.playlist])
        let changed = expectation(description: "Only committed pointer produces a change")
        let task = Task { @MainActor in
            var iterator = iterator
            if let next = await iterator.next(isolation: MainActor.shared), let change = next.change(since: baseline) {
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
        XCTAssertEqual(signal.generation, 0, "Subscription consumes its baseline before preparation starts")
        let context = ModelContext(container)
        let profile = profile()
        context.insert(profile)
        try context.save()
        for index in 0..<20 {
            profile.name = "Immediate burst \(index)"
            try context.save()
        }
        for _ in 0..<200 {
            if signal.generation > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(signal.generation, 0)
        XCTAssertEqual(signal.reloadScope(after: 0), .full)
    }

    func testProductionBridgeRebindingStartsNewBaselineAndRetainsLatestBufferedGeneration() async throws {
        let firstContainer = try VPlayerModelContainer.make(inMemory: true)
        let firstContext = ModelContext(firstContainer)
        let firstProfile = profile()
        firstContext.insert(firstProfile)
        try firstContext.save()
        let firstStore = SwiftDataLibraryStore(modelContainer: firstContainer)
        // Make the first store's revision larger than the new store's. Rebinding
        // must replace its comparison baseline, including its revision domain.
        for _ in 0..<3 {
            try await firstStore.recordSuccess(profileID: firstProfile.id, resource: .playlist,
                                               at: .now, attemptID: UUID())
            _ = try await firstStore.committedObservationBoundary()
        }
        let signal = LibraryChangeSignal()
        try await signal.observeCommittedChanges(in: firstStore)
        XCTAssertEqual(signal.generation, 0)

        let nextContainer = try VPlayerModelContainer.make(inMemory: true)
        let nextContext = ModelContext(nextContainer)
        let nextProfile = profile()
        nextContext.insert(nextProfile)
        try nextContext.save()
        let nextStore = SwiftDataLibraryStore(modelContainer: nextContainer)
        try await signal.observeCommittedChanges(in: nextStore)
        XCTAssertEqual(signal.generation, 0, "Rebinding consumes the new baseline without announcing it as a change")
        let changes = signal.changes(after: 0)

        try await firstStore.recordSuccess(profileID: firstProfile.id, resource: .epg,
                                           at: .now, attemptID: UUID())
        _ = try await firstStore.committedObservationBoundary()
        let acceptedOldFence = await signal.flushCommittedChanges(in: firstStore)
        XCTAssertFalse(acceptedOldFence, "A retired observation cannot move the new baseline")

        for resource in [RefreshResource.playlist, .epg] {
            try await nextStore.recordSuccess(profileID: nextProfile.id, resource: resource,
                                              at: .now, attemptID: UUID())
            _ = try await nextStore.committedObservationBoundary()
        }
        let expectedScope = LibraryChangeSignal.ReloadScope.refreshes([nextProfile.id: [.playlist, .epg]])
        for _ in 0..<200 {
            if signal.reloadScope(after: 0) == expectedScope { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(signal.reloadScope(after: 0), expectedScope)
        guard signal.generation > 0 else {
            XCTFail("The replacement stream must deliver its post-baseline changes")
            return
        }
        // The downstream stream stays unread across the burst, so its only
        // buffered value must be the newest generation, with both reload scopes.
        var iterator = changes.makeAsyncIterator()
        let latest = await iterator.next(isolation: MainActor.shared)
        XCTAssertEqual(latest, signal.generation)
        let generation = signal.generation
        try await signal.observeCommittedChanges(in: nextStore)
        let acceptedCurrentFence = await signal.flushCommittedChanges()
        XCTAssertTrue(acceptedCurrentFence)
        XCTAssertEqual(signal.generation, generation, "Same-store binding and revision replay remain idempotent")
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
        _ = await iterator.next(isolation: MainActor.shared)
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
            if let snapshot = await iterator.next(isolation: MainActor.shared) {
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

    func testDelayedNativeSnapshotsAfterClaimReconciliationAreDeduplicatedWithoutLosingExternalChanges() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = profile()
        context.insert(profile)
        try context.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        let stream = try await store.committedChanges()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next(isolation: MainActor.shared)
        let baseline = try XCTUnwrap(first)
        let signal = LibraryChangeSignal()
        signal.consumeCommittedSnapshot(baseline)
        let claim = signal.claimPersistedRefreshes(profileID: profile.id, resources: [.playlist, .epg])
        let attempt = UUID()
        try await store.recordSuccess(profileID: profile.id, resource: .playlist, at: .now, attemptID: attempt)
        try await store.recordSuccess(profileID: profile.id, resource: .epg, at: .now, attemptID: UUID())
        // The native stream remains unread while awaited persisted callbacks and
        // the explicit observation fence complete the claimed reconciliation.
        signal.notify(profileID: profile.id, resource: .playlist)
        signal.notify(profileID: profile.id, resource: .epg)
        let fenced = await signal.flushCommittedChanges(in: store)
        XCTAssertTrue(fenced)
        signal.stopClaimingPersistedRefreshes(claim)
        signal.releasePersistedRefreshes(claim, publishesPendingChanges: false)
        let held = await iterator.next(isolation: MainActor.shared)
        signal.consumeCommittedSnapshot(try XCTUnwrap(held))
        XCTAssertEqual(signal.generation, 0, "Delayed delivery of the same committed revision must not schedule a second reload")

        let external = ModelContext(container)
        let externalProfile = try XCTUnwrap(try external.fetch(FetchDescriptor<SourceProfileRecord>()).first)
        let changed = expectation(description: "A newer external commit remains observable")
        let task = Task { @MainActor in
            var iterator = iterator
            while let snapshot = await iterator.next(isolation: MainActor.shared) {
                signal.consumeCommittedSnapshot(snapshot)
                if signal.generation > 0 { changed.fulfill(); return }
            }
        }
        externalProfile.m3uAttemptID = UUID()
        externalProfile.epgAttemptID = UUID()
        externalProfile.m3uLastSuccessAt = .now
        externalProfile.epgLastSuccessAt = .now
        try external.save()
        await fulfillment(of: [changed], timeout: 3)
        task.cancel()
        await task.value
        // Fence also folds any second resource still coalescing on its actor.
        _ = await signal.flushCommittedChanges(in: store)
        XCTAssertEqual(signal.reloadScope(after: 0), .refreshes([profile.id: [.playlist, .epg]]))
    }

    private func profile() -> SourceProfileRecord {
        .init(id: UUID(), name: "Home", m3uURLString: "https://example.invalid/live.m3u",
              epgURLString: "https://example.invalid/guide.xml", m3uRefreshIntervalRaw: 0,
              epgRefreshIntervalRaw: 0, createdAt: .now, updatedAt: .now)
    }
}
