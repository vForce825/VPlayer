// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData
import XCTest
@testable import VPlayerCore

@MainActor
final class SwiftDataLibraryStoreTests: XCTestCase {
    func testCreatingProfilesSelectsFirstAndKeepsProfileChannelsIsolated() async throws {
        let (_, store) = try makeStore()
        let first = try await store.createProfile(input(name: "First"), now: date(10))
        let second = try await store.createProfile(input(name: "Second"), now: date(20))

        let initiallyActive = try await store.activeProfile()
        XCTAssertEqual(initiallyActive?.id, first.id)

        try await store.installPlaylist(
            profileID: first.id,
            channels: [channel(profileID: first.id, name: "First channel", path: "first")],
            fetchedAt: date(30)
        )
        try await store.installPlaylist(
            profileID: second.id,
            channels: [channel(profileID: second.id, name: "Second channel", path: "second")],
            fetchedAt: date(40)
        )
        try await store.setActiveProfile(id: second.id)

        let active = try await store.activeProfile()
        let firstChannels = try await store.channels(profileID: first.id)
        let secondChannels = try await store.channels(profileID: second.id)
        XCTAssertEqual(active?.id, second.id)
        XCTAssertEqual(firstChannels.map(\.displayName), ["First channel"])
        XCTAssertEqual(secondChannels.map(\.displayName), ["Second channel"])
    }

    func testPlaylistReplacementReturnsOnlyNewSnapshotAndPreservesManualMapping() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let firstChannel = channel(profileID: profile.id, name: "Old name", path: "stable")
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [firstChannel, channel(profileID: profile.id, name: "Removed", path: "removed")],
            fetchedAt: date(20)
        )
        try await store.setManualMapping(
            profileID: profile.id,
            channelID: firstChannel.id,
            xmltvChannelID: "xmltv-stable"
        )

        let replacement = channel(profileID: profile.id, name: "New name", path: "stable")
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [replacement],
            fetchedAt: date(30)
        )

        let installedChannels = try await store.channels(profileID: profile.id)
        let mapping = try await store.manualMapping(profileID: profile.id, channelID: replacement.id)
        XCTAssertEqual(installedChannels, [replacement])
        XCTAssertEqual(
            mapping,
            ManualEPGMapping(
                sourceProfileID: profile.id,
                channelID: replacement.id,
                xmltvChannelID: "xmltv-stable"
            )
        )
    }

    func testFailedPlaylistStagingLeavesPreviousSnapshotQueryable() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let original = channel(profileID: profile.id, name: "Original", path: "original")
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [original],
            fetchedAt: date(20)
        )
        let duplicate = channel(profileID: profile.id, name: "Duplicate", path: "duplicate")

        _ = await XCTAssertThrowsErrorAsync {
            try await store.installPlaylist(
                profileID: profile.id,
                channels: [duplicate, duplicate],
                fetchedAt: self.date(30)
            )
        }

        let installedChannels = try await store.channels(profileID: profile.id)
        XCTAssertEqual(installedChannels, [original])
    }

    func testMalformedEPGReplacementThrowsAndLeavesPreviousSnapshotQueryable() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let validURL = try temporaryXML(
            """
            <tv>
              <channel id="news"><display-name>News</display-name></channel>
              <programme channel="news" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Bulletin</title>
              </programme>
            </tv>
            """
        )
        defer { try? FileManager.default.removeItem(at: validURL) }
        let summary = try await store.installEPG(
            profileID: profile.id,
            fileURL: validURL,
            fetchedAt: date(20)
        )
        XCTAssertEqual(summary, XMLTVParseSummary(channelCount: 1, programmeCount: 1))

        _ = await XCTAssertThrowsErrorAsync {
            _ = try await store.installEPG(
                profileID: profile.id,
                fileURL: self.fixtureURL("epg/malformed.xml"),
                fetchedAt: self.date(30)
            )
        }

        let epgChannels = try await store.epgChannels(profileID: profile.id)
        let programmes = try await store.programmes(
            profileID: profile.id,
            xmltvChannelID: "news",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(epgChannels.map(\.id), ["news"])
        XCTAssertEqual(programmes.map(\.title), ["Bulletin"])
    }

    func testDuplicateXMLTVChannelIDsRejectReplacementAndCleanStaging() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            "<tv><channel id=\"original\"><display-name>Original</display-name></channel></tv>"
        )
        let duplicateURL = try temporaryXML(
            """
            <tv>
              <channel id="duplicate"><display-name>First</display-name></channel>
              <channel id="duplicate"><display-name>Second</display-name></channel>
            </tv>
            """
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: duplicateURL)
        }
        _ = try await store.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        try await store.recordSuccess(profileID: profile.id, resource: .epg, at: date(25))

        _ = await XCTAssertThrowsErrorAsync {
            _ = try await store.installEPG(
                profileID: profile.id,
                fileURL: duplicateURL,
                fetchedAt: self.date(30)
            )
        }

        let activeChannels = try await store.epgChannels(profileID: profile.id)
        let profiles = try await store.profiles()
        let currentProfile = try XCTUnwrap(profiles.first)
        let snapshotHeaders = try ModelContext(container).fetch(FetchDescriptor<EPGSnapshotRecord>())
        let inventory = try snapshotInventory(container)
        XCTAssertEqual(activeChannels.map(\.id), ["original"])
        XCTAssertEqual(currentProfile.epgStatus.state, .succeeded)
        XCTAssertEqual(currentProfile.epgStatus.lastSuccessAt, date(25))
        XCTAssertEqual(snapshotHeaders.count, 1)
        XCTAssertEqual(snapshotHeaders.first?.channelCount, 1)
        XCTAssertEqual(inventory.playlistHeaderIDs, [])
        XCTAssertEqual(inventory.channels, [])
        XCTAssertEqual(inventory.epgHeaderIDs, snapshotHeaders.map(\.id))
        XCTAssertEqual(inventory.epgChannels.map(\.valueID), ["original"])
        XCTAssertEqual(inventory.programmes, [])
    }

    func testDuplicateXMLTVProgrammeStableIDsRejectReplacementAndCleanStaging() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            """
            <tv>
              <channel id="original"><display-name>Original</display-name></channel>
              <programme channel="original" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Original Show</title>
              </programme>
            </tv>
            """
        )
        let duplicateURL = try temporaryXML(
            """
            <tv>
              <channel id="replacement"><display-name>Replacement</display-name></channel>
              <programme channel="replacement" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Duplicated Show</title>
              </programme>
              <programme channel="replacement" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Duplicated Show</title>
              </programme>
            </tv>
            """
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: duplicateURL)
        }
        _ = try await store.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        try await store.recordSuccess(profileID: profile.id, resource: .epg, at: date(25))

        _ = await XCTAssertThrowsErrorAsync {
            _ = try await store.installEPG(
                profileID: profile.id,
                fileURL: duplicateURL,
                fetchedAt: self.date(30)
            )
        }

        let activeChannels = try await store.epgChannels(profileID: profile.id)
        let activeProgrammes = try await store.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        let profiles = try await store.profiles()
        let currentProfile = try XCTUnwrap(profiles.first)
        let snapshotHeaders = try ModelContext(container).fetch(FetchDescriptor<EPGSnapshotRecord>())
        let inventory = try snapshotInventory(container)
        XCTAssertEqual(activeChannels.map(\.id), ["original"])
        XCTAssertEqual(activeProgrammes.map(\.title), ["Original Show"])
        XCTAssertEqual(currentProfile.epgStatus.state, .succeeded)
        XCTAssertEqual(currentProfile.epgStatus.lastSuccessAt, date(25))
        XCTAssertEqual(snapshotHeaders.count, 1)
        XCTAssertEqual(snapshotHeaders.first?.programmeCount, 1)
        XCTAssertEqual(inventory.playlistHeaderIDs, [])
        XCTAssertEqual(inventory.channels, [])
        XCTAssertEqual(inventory.epgHeaderIDs, snapshotHeaders.map(\.id))
        XCTAssertEqual(inventory.epgChannels.map(\.valueID), ["original"])
        XCTAssertEqual(inventory.programmes.map(\.valueID), [activeProgrammes[0].id])
    }

    func testFailedProfileUpdateRollsBackBeforeUnrelatedSave() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let first = try await initialStore.createProfile(input(name: "First"), now: date(10))
        let second = try await initialStore.createProfile(input(name: "Second"), now: date(20))
        let failingStore = makeStore(container: container, failingSave: .profileUpdate)

        let error = await XCTAssertThrowsErrorAsync {
            try await failingStore.updateProfile(
                id: first.id,
                input: self.input(name: "Leaked update"),
                now: self.date(30)
            )
        }
        XCTAssertEqual(error as? InjectedSaveError, .expected)

        let afterFailure = try await failingStore.profiles()
        XCTAssertEqual(afterFailure.map(\.name), ["First", "Second"])

        try await failingStore.recordAttempt(profileID: second.id, resource: .epg, at: date(40))
        let verificationStore = SwiftDataLibraryStore(modelContainer: container)
        let afterUnrelatedSave = try await verificationStore.profiles()
        XCTAssertEqual(afterUnrelatedSave.map(\.name), ["First", "Second"])
        XCTAssertEqual(afterUnrelatedSave[1].epgStatus.state, .refreshing)
    }

    func testPlaylistPointerSaveFailurePreservesOldPointerAndRemovesAllStagingRows() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let original = channel(profileID: profile.id, name: "Original", path: "original")
        let replacement = channel(profileID: profile.id, name: "Replacement", path: "replacement")
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [original],
            fetchedAt: date(20)
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let failingStore = makeStore(container: container, failingSave: .playlistPointer)

        let error = await XCTAssertThrowsErrorAsync {
            try await failingStore.installPlaylist(
                profileID: profile.id,
                channels: [replacement],
                fetchedAt: self.date(30)
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .expected)
        let pointersAfterFailure = try snapshotPointers(container, profileID: profile.id)
        let channelsAfterFailure = try await failingStore.channels(profileID: profile.id)
        XCTAssertEqual(pointersAfterFailure.playlist, originalPointers.playlist)
        XCTAssertEqual(channelsAfterFailure, [original])
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testEPGPointerSaveFailurePreservesOldPointerAndRemovesAllStagingRows() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(singleProgrammeXMLTV(channelID: "original", title: "Original"))
        let replacementURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "replacement", title: "Replacement")
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let failingStore = makeStore(container: container, failingSave: .epgPointer)

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.installEPG(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(30)
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .expected)
        let pointersAfterFailure = try snapshotPointers(container, profileID: profile.id)
        let channelsAfterFailure = try await failingStore.epgChannels(profileID: profile.id)
        XCTAssertEqual(pointersAfterFailure.epg, originalPointers.epg)
        XCTAssertEqual(channelsAfterFailure.map(\.id), ["original"])
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testEPGBatchSaveFailureAbortsInstallAndPreservesLastKnownGoodState() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(singleProgrammeXMLTV(channelID: "original", title: "Original"))
        let replacementURL = try temporaryXML(batchedXMLTV(programmeCount: 499))
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        let playlist = channel(profileID: profile.id, name: "Live", path: "live")
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [playlist],
            fetchedAt: date(20)
        )
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(30)
        )
        try await initialStore.recordSuccess(profileID: profile.id, resource: .playlist, at: date(35))
        try await initialStore.recordSuccess(profileID: profile.id, resource: .epg, at: date(40))
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let failingStore = makeStore(container: container, failingSave: .epgBatch)

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.installEPG(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(50)
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .expected)
        let pointersAfterFailure = try snapshotPointers(container, profileID: profile.id)
        let playlistAfterFailure = try await failingStore.channels(profileID: profile.id)
        let epgAfterFailure = try await failingStore.epgChannels(profileID: profile.id)
        let profilesAfterFailure = try await failingStore.profiles()
        let currentProfile = try XCTUnwrap(profilesAfterFailure.first)
        XCTAssertEqual(pointersAfterFailure.playlist, originalPointers.playlist)
        XCTAssertEqual(pointersAfterFailure.epg, originalPointers.epg)
        XCTAssertEqual(playlistAfterFailure, [playlist])
        XCTAssertEqual(epgAfterFailure.map(\.id), ["original"])
        XCTAssertEqual(currentProfile.m3uStatus.state, .succeeded)
        XCTAssertEqual(currentProfile.m3uStatus.lastSuccessAt, date(35))
        XCTAssertEqual(currentProfile.epgStatus.state, .succeeded)
        XCTAssertEqual(currentProfile.epgStatus.lastSuccessAt, date(40))
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testPlaylistCleanupSaveFailureStillReportsInstallSuccessAndDefersPurge() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let original = channel(profileID: profile.id, name: "Original", path: "original")
        let replacement = channel(profileID: profile.id, name: "Replacement", path: "replacement")
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [original],
            fetchedAt: date(20)
        )
        try await initialStore.recordSuccess(profileID: profile.id, resource: .playlist, at: date(25))
        let failingStore = makeStore(container: container, failingSave: .playlistCleanup)

        try await failingStore.installPlaylist(
            profileID: profile.id,
            channels: [replacement],
            fetchedAt: date(30)
        )

        let installedChannels = try await failingStore.channels(profileID: profile.id)
        let profiles = try await failingStore.profiles()
        XCTAssertEqual(installedChannels, [replacement])
        XCTAssertEqual(profiles.first?.m3uStatus.state, .succeeded)
        try await failingStore.setManualMapping(
            profileID: profile.id,
            channelID: replacement.id,
            xmltvChannelID: "unrelated-save"
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<PlaylistSnapshotRecord>()).count,
            2
        )

        try await failingStore.purgeUnreferencedSnapshots()

        let remainingHeaders = try ModelContext(container).fetch(FetchDescriptor<PlaylistSnapshotRecord>())
        let channelsAfterPurge = try await failingStore.channels(profileID: profile.id)
        XCTAssertEqual(remainingHeaders.count, 1)
        XCTAssertEqual(remainingHeaders.first?.channelCount, 1)
        XCTAssertEqual(channelsAfterPurge, [replacement])
    }

    func testEPGCleanupSaveFailureStillReportsInstallSuccessAndDefersPurge() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            "<tv><channel id=\"original\"><display-name>Original</display-name></channel></tv>"
        )
        let replacementURL = try temporaryXML(
            "<tv><channel id=\"replacement\"><display-name>Replacement</display-name></channel></tv>"
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        let failingStore = makeStore(container: container, failingSave: .epgCleanup)

        let summary = try await failingStore.installEPG(
            profileID: profile.id,
            fileURL: replacementURL,
            fetchedAt: date(30)
        )

        let installedChannels = try await failingStore.epgChannels(profileID: profile.id)
        XCTAssertEqual(summary, XMLTVParseSummary(channelCount: 1, programmeCount: 0))
        XCTAssertEqual(installedChannels.map(\.id), ["replacement"])
        try await failingStore.setManualMapping(
            profileID: profile.id,
            channelID: "unrelated-channel",
            xmltvChannelID: "replacement"
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<EPGSnapshotRecord>()).count,
            2
        )

        try await failingStore.purgeUnreferencedSnapshots()

        let remainingHeaders = try ModelContext(container).fetch(FetchDescriptor<EPGSnapshotRecord>())
        let channelsAfterPurge = try await failingStore.epgChannels(profileID: profile.id)
        XCTAssertEqual(remainingHeaders.count, 1)
        XCTAssertEqual(remainingHeaders.first?.channelCount, 1)
        XCTAssertEqual(channelsAfterPurge.map(\.id), ["replacement"])
    }

    func testEPGFinalSaveFailureAfterBatchStagingCleansStagingAndPreservesResources() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalEPGURL = try temporaryXML(
            """
            <tv>
              <channel id="original"><display-name>Original</display-name></channel>
              <programme channel="original" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Original Show</title>
              </programme>
            </tv>
            """
        )
        let replacementEPGURL = try temporaryXML(batchedXMLTV(programmeCount: 499))
        defer {
            try? FileManager.default.removeItem(at: originalEPGURL)
            try? FileManager.default.removeItem(at: replacementEPGURL)
        }
        let playlist = channel(profileID: profile.id, name: "Live", path: "live")
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [playlist],
            fetchedAt: date(20)
        )
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalEPGURL,
            fetchedAt: date(30)
        )
        try await initialStore.recordSuccess(profileID: profile.id, resource: .playlist, at: date(35))
        try await initialStore.recordSuccess(profileID: profile.id, resource: .epg, at: date(40))
        let phaseRecorder = SavePhaseRecorder(failingAt: .epgStaging)
        let failingStore = SwiftDataLibraryStore(modelContainer: container) { phase in
            try phaseRecorder.record(phase)
        }

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.installEPG(
                profileID: profile.id,
                fileURL: replacementEPGURL,
                fetchedAt: self.date(50)
            )
        }
        XCTAssertEqual(error as? InjectedSaveError, .expected)
        XCTAssertEqual(
            phaseRecorder.recorded.filter { $0 == .epgBatch || $0 == .epgStaging },
            [.epgBatch, .epgStaging]
        )

        let activeEPGChannels = try await failingStore.epgChannels(profileID: profile.id)
        let activeProgrammes = try await failingStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        let profiles = try await failingStore.profiles()
        let activePlaylist = try await failingStore.channels(profileID: profile.id)
        XCTAssertEqual(activeEPGChannels.map(\.id), ["original"])
        XCTAssertEqual(activeProgrammes.map(\.title), ["Original Show"])
        XCTAssertEqual(activePlaylist, [playlist])
        XCTAssertEqual(profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(profiles.first?.m3uStatus.lastSuccessAt, date(35))
        XCTAssertEqual(profiles.first?.epgStatus.state, .succeeded)
        XCTAssertEqual(profiles.first?.epgStatus.lastSuccessAt, date(40))
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<EPGSnapshotRecord>()).count,
            1
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<ProgrammeRecord>()).count,
            1
        )
        let pointers = try snapshotPointers(container, profileID: profile.id)
        let inventory = try snapshotInventory(container)
        XCTAssertEqual(inventory.playlistHeaderIDs, [try XCTUnwrap(pointers.playlist)])
        XCTAssertEqual(inventory.channels.map(\.valueID), [playlist.id])
        XCTAssertEqual(inventory.epgHeaderIDs, [try XCTUnwrap(pointers.epg)])
        XCTAssertEqual(inventory.epgChannels.map(\.valueID), ["original"])
        XCTAssertEqual(inventory.programmes.map(\.valueID), [activeProgrammes[0].id])
    }

    func testStatusUpdatesAffectOnlyRequestedResourceAndTruncateFailureSummary() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))

        try await store.recordAttempt(profileID: profile.id, resource: .epg, at: date(20))
        try await store.recordSuccess(profileID: profile.id, resource: .epg, at: date(30))
        try await store.recordAttempt(profileID: profile.id, resource: .playlist, at: date(40))
        try await store.recordFailure(
            profileID: profile.id,
            resource: .playlist,
            summary: String(repeating: "x", count: 300),
            at: date(50)
        )

        let profiles = try await store.profiles()
        let updated = try XCTUnwrap(profiles.first)
        XCTAssertEqual(updated.m3uStatus.lastAttemptAt, date(40))
        XCTAssertNil(updated.m3uStatus.lastSuccessAt)
        XCTAssertEqual(updated.m3uStatus.state, .failed)
        XCTAssertEqual(updated.m3uStatus.errorSummary?.count, 240)
        XCTAssertEqual(updated.epgStatus.lastAttemptAt, date(20))
        XCTAssertEqual(updated.epgStatus.lastSuccessAt, date(30))
        XCTAssertEqual(updated.epgStatus.state, .succeeded)
        XCTAssertNil(updated.epgStatus.errorSummary)
    }

    func testDeletingActiveProfileSelectsOldestRemainingThenNil() async throws {
        let (_, store) = try makeStore()
        let first = try await store.createProfile(input(name: "First"), now: date(10))
        let oldestRemaining = try await store.createProfile(input(name: "Second"), now: date(20))
        let newest = try await store.createProfile(input(name: "Third"), now: date(30))
        try await store.setActiveProfile(id: newest.id)

        try await store.deleteProfile(id: newest.id)
        let activeAfterNewestDeletion = try await store.activeProfile()
        XCTAssertEqual(activeAfterNewestDeletion?.id, first.id)
        try await store.deleteProfile(id: first.id)
        let activeAfterFirstDeletion = try await store.activeProfile()
        XCTAssertEqual(activeAfterFirstDeletion?.id, oldestRemaining.id)
        try await store.deleteProfile(id: oldestRemaining.id)
        let activeAfterAllDeleted = try await store.activeProfile()
        XCTAssertNil(activeAfterAllDeleted)
    }

    func testStartupMaintenancePurgesOnlyUnreferencedSnapshots() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [channel(profileID: profile.id, name: "Live", path: "live")],
            fetchedAt: date(20)
        )
        let validURL = try temporaryXML(
            "<tv><channel id=\"news\"><display-name>News</display-name></channel></tv>"
        )
        defer { try? FileManager.default.removeItem(at: validURL) }
        _ = try await store.installEPG(profileID: profile.id, fileURL: validURL, fetchedAt: date(30))

        let context = ModelContext(container)
        let profileID = profile.id
        let profileRecord = try XCTUnwrap(try context.fetch(FetchDescriptor<SourceProfileRecord>(
            predicate: #Predicate { $0.id == profileID }
        )).first)
        let referencedPlaylistID = try XCTUnwrap(profileRecord.playlistSnapshotID)
        let referencedEPGID = try XCTUnwrap(profileRecord.epgSnapshotID)
        let abandonedPlaylistID = UUID()
        let abandonedEPGID = UUID()
        context.insert(PlaylistSnapshotRecord(
            id: abandonedPlaylistID,
            sourceProfileID: profile.id,
            fetchedAt: date(40),
            channelCount: 1
        ))
        context.insert(ChannelRecord(
            snapshotID: abandonedPlaylistID,
            sourceProfileID: profile.id,
            stableID: "abandoned-channel",
            displayName: "Abandoned",
            streamURLString: "https://stream.example/abandoned",
            tvgID: nil,
            tvgName: nil,
            logoURLString: nil,
            groupTitle: nil,
            attributesJSON: Data("{}".utf8),
            order: 0
        ))
        context.insert(EPGSnapshotRecord(
            id: abandonedEPGID,
            sourceProfileID: profile.id,
            fetchedAt: date(40),
            channelCount: 1,
            programmeCount: 0
        ))
        context.insert(EPGChannelRecord(
            snapshotID: abandonedEPGID,
            xmltvID: "abandoned-epg",
            displayNames: ["Abandoned"],
            iconURLString: nil
        ))
        try context.save()

        try await store.purgeUnreferencedSnapshots()

        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            Set(try verificationContext.fetch(FetchDescriptor<PlaylistSnapshotRecord>()).map(\.id)),
            [referencedPlaylistID]
        )
        XCTAssertEqual(
            Set(try verificationContext.fetch(FetchDescriptor<EPGSnapshotRecord>()).map(\.id)),
            [referencedEPGID]
        )
        let channels = try await store.channels(profileID: profile.id)
        let epgChannels = try await store.epgChannels(profileID: profile.id)
        XCTAssertEqual(channels.map(\.displayName), ["Live"])
        XCTAssertEqual(epgChannels.map(\.id), ["news"])
    }

    private func makeStore() throws -> (ModelContainer, SwiftDataLibraryStore) {
        let container = try VPlayerModelContainer.make(inMemory: true)
        return (container, SwiftDataLibraryStore(modelContainer: container))
    }

    private func makeStore(
        container: ModelContainer,
        failingSave phase: LibraryStoreSavePhase
    ) -> SwiftDataLibraryStore {
        SwiftDataLibraryStore(modelContainer: container) { actualPhase in
            guard actualPhase == phase else { return }
            throw InjectedSaveError.expected
        }
    }

    private func snapshotPointers(
        _ container: ModelContainer,
        profileID: UUID
    ) throws -> (playlist: UUID?, epg: UUID?) {
        let id = profileID
        let record = try XCTUnwrap(try ModelContext(container).fetch(
            FetchDescriptor<SourceProfileRecord>(predicate: #Predicate { $0.id == id })
        ).first)
        return (record.playlistSnapshotID, record.epgSnapshotID)
    }

    private func snapshotInventory(_ container: ModelContainer) throws -> SnapshotInventory {
        let context = ModelContext(container)
        return SnapshotInventory(
            playlistHeaderIDs: try context.fetch(FetchDescriptor<PlaylistSnapshotRecord>())
                .map(\.id).sorted(by: uuidOrder),
            channels: try context.fetch(FetchDescriptor<ChannelRecord>())
                .map { SnapshotChildIdentity(snapshotID: $0.snapshotID, valueID: $0.stableID) }
                .sorted(),
            epgHeaderIDs: try context.fetch(FetchDescriptor<EPGSnapshotRecord>())
                .map(\.id).sorted(by: uuidOrder),
            epgChannels: try context.fetch(FetchDescriptor<EPGChannelRecord>())
                .map { SnapshotChildIdentity(snapshotID: $0.snapshotID, valueID: $0.xmltvID) }
                .sorted(),
            programmes: try context.fetch(FetchDescriptor<ProgrammeRecord>())
                .map { SnapshotChildIdentity(snapshotID: $0.snapshotID, valueID: $0.stableID) }
                .sorted()
        )
    }

    private func assertInventory(
        _ actual: SnapshotInventory,
        equals expected: SnapshotInventory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.playlistHeaderIDs, expected.playlistHeaderIDs, file: file, line: line)
        XCTAssertEqual(actual.channels, expected.channels, file: file, line: line)
        XCTAssertEqual(actual.epgHeaderIDs, expected.epgHeaderIDs, file: file, line: line)
        XCTAssertEqual(actual.epgChannels, expected.epgChannels, file: file, line: line)
        XCTAssertEqual(actual.programmes, expected.programmes, file: file, line: line)
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private func input(name: String) throws -> ValidatedSourceProfileInput {
        try SourceProfileInput(
            name: name,
            m3uURLString: "https://playlist.example/\(name).m3u",
            epgURLString: "https://epg.example/\(name).xml",
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily
        ).validated()
    }

    private func channel(profileID: UUID, name: String, path: String) -> Channel {
        Channel(
            sourceProfileID: profileID,
            displayName: name,
            streamURL: URL(string: "https://stream.example/\(path)")!,
            tvgID: "tvg-\(path)",
            tvgName: name,
            logoURL: URL(string: "https://images.example/\(path).png"),
            groupTitle: "Group",
            attributes: ["unknown": "preserved", "tvg-id": "tvg-\(path)"],
            order: 0
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        let parts = relativePath.split(separator: "/").map(String.init)
        return Bundle(for: Self.self).url(
            forResource: parts.last!,
            withExtension: nil,
            subdirectory: parts.dropLast().joined(separator: "/")
        )!
    }

    private func temporaryXML(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDataLibraryStoreTests-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    private func batchedXMLTV(programmeCount: Int) -> String {
        let programmes = (0..<programmeCount).map { index in
            """
            <programme channel="replacement" start="20260718150000 Z" stop="20260718160000 Z">
              <title>Show \(index)</title>
            </programme>
            """
        }.joined()
        return """
        <tv>
          <channel id="replacement"><display-name>Replacement</display-name></channel>
          \(programmes)
        </tv>
        """
    }

    private func singleProgrammeXMLTV(channelID: String, title: String) -> String {
        """
        <tv>
          <channel id="\(channelID)"><display-name>\(channelID)</display-name></channel>
          <programme channel="\(channelID)" start="20260718150000 Z" stop="20260718160000 Z">
            <title>\(title)</title>
          </programme>
        </tv>
        """
    }
}

private struct SnapshotInventory: Equatable {
    let playlistHeaderIDs: [UUID]
    let channels: [SnapshotChildIdentity]
    let epgHeaderIDs: [UUID]
    let epgChannels: [SnapshotChildIdentity]
    let programmes: [SnapshotChildIdentity]
}

private struct SnapshotChildIdentity: Comparable {
    let snapshotID: UUID
    let valueID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.snapshotID.uuidString, lhs.valueID) < (rhs.snapshotID.uuidString, rhs.valueID)
    }
}

private final class SavePhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failingPhase: LibraryStoreSavePhase
    private var phases: [LibraryStoreSavePhase] = []

    init(failingAt phase: LibraryStoreSavePhase) {
        failingPhase = phase
    }

    var recorded: [LibraryStoreSavePhase] {
        lock.withLock { phases }
    }

    func record(_ phase: LibraryStoreSavePhase) throws {
        try lock.withLock {
            phases.append(phase)
            if phase == failingPhase {
                throw InjectedSaveError.expected
            }
        }
    }
}

private enum InjectedSaveError: Error, Equatable {
    case expected
}

private enum AsyncThrowAssertionError: Error {
    case didNotThrow
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> any Error {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
        return AsyncThrowAssertionError.didNotThrow
    } catch {
        return error
    }
}
