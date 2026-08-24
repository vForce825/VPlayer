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

    func testConditionalManualMappingRejectsInactiveProfile() async throws {
        let (_, store) = try makeStore()
        _ = try await store.createProfile(input(name: "Active"), now: date(10))
        let inactive = try await store.createProfile(input(name: "Inactive"), now: date(20))
        let inactiveChannel = channel(profileID: inactive.id, name: "Inactive", path: "inactive")
        try await store.installPlaylist(
            profileID: inactive.id,
            channels: [inactiveChannel],
            fetchedAt: date(30)
        )

        let persisted = try await store.setManualMappingIfCurrentChannel(
            profileID: inactive.id,
            channelID: inactiveChannel.id,
            xmltvChannelID: "inactive-epg"
        )
        let mapping = try await store.manualMapping(
            profileID: inactive.id,
            channelID: inactiveChannel.id
        )

        XCTAssertFalse(persisted)
        XCTAssertNil(mapping)
    }

    func testConditionalManualMappingRejectsAbsentAndOldSnapshotChannels() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let oldChannel = channel(profileID: profile.id, name: "Old", path: "old")
        let currentChannel = channel(profileID: profile.id, name: "Current", path: "current")
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [oldChannel],
            fetchedAt: date(20)
        )
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [currentChannel],
            fetchedAt: date(30)
        )

        let oldPersisted = try await store.setManualMappingIfCurrentChannel(
            profileID: profile.id,
            channelID: oldChannel.id,
            xmltvChannelID: "old-epg"
        )
        let absentPersisted = try await store.setManualMappingIfCurrentChannel(
            profileID: profile.id,
            channelID: "missing-channel",
            xmltvChannelID: "missing-epg"
        )
        let oldMapping = try await store.manualMapping(
            profileID: profile.id,
            channelID: oldChannel.id
        )
        let absentMapping = try await store.manualMapping(
            profileID: profile.id,
            channelID: "missing-channel"
        )

        XCTAssertFalse(oldPersisted)
        XCTAssertFalse(absentPersisted)
        XCTAssertNil(oldMapping)
        XCTAssertNil(absentMapping)
    }

    func testConditionalManualMappingSetsAndClearsCurrentChannel() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let currentChannel = channel(profileID: profile.id, name: "Current", path: "current")
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [currentChannel],
            fetchedAt: date(20)
        )

        let setPersisted = try await store.setManualMappingIfCurrentChannel(
            profileID: profile.id,
            channelID: currentChannel.id,
            xmltvChannelID: "current-epg"
        )
        let setMapping = try await store.manualMapping(
            profileID: profile.id,
            channelID: currentChannel.id
        )
        let clearPersisted = try await store.setManualMappingIfCurrentChannel(
            profileID: profile.id,
            channelID: currentChannel.id,
            xmltvChannelID: nil
        )
        let clearedMapping = try await store.manualMapping(
            profileID: profile.id,
            channelID: currentChannel.id
        )

        XCTAssertTrue(setPersisted)
        XCTAssertEqual(setMapping?.xmltvChannelID, "current-epg")
        XCTAssertTrue(clearPersisted)
        XCTAssertNil(clearedMapping)
    }

    func testConditionalManualMappingSaveFailureRollsBackSetAndClear() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let currentChannel = channel(profileID: profile.id, name: "Current", path: "current")
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [currentChannel],
            fetchedAt: date(20)
        )
        try await initialStore.setManualMapping(
            profileID: profile.id,
            channelID: currentChannel.id,
            xmltvChannelID: "original-epg"
        )
        let failingStore = makeStore(container: container, failingSave: .manualMapping)

        let setError = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.setManualMappingIfCurrentChannel(
                profileID: profile.id,
                channelID: currentChannel.id,
                xmltvChannelID: "replacement-epg"
            )
        }
        let clearError = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.setManualMappingIfCurrentChannel(
                profileID: profile.id,
                channelID: currentChannel.id,
                xmltvChannelID: nil
            )
        }
        let verificationStore = SwiftDataLibraryStore(modelContainer: container)
        let mapping = try await verificationStore.manualMapping(
            profileID: profile.id,
            channelID: currentChannel.id
        )

        XCTAssertEqual(setError as? InjectedSaveError, .expected)
        XCTAssertEqual(clearError as? InjectedSaveError, .expected)
        XCTAssertEqual(mapping?.xmltvChannelID, "original-epg")
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

    func testEPGCoverageEndReportsLatestStopAndIsNilWithoutProgrammes() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let coverageWithoutEPG = try await store.epgCoverageEnd(profileID: profile.id)
        XCTAssertNil(coverageWithoutEPG)

        let channelOnlyURL = try temporaryXML(
            "<tv><channel id=\"news\"><display-name>News</display-name></channel></tv>"
        )
        defer { try? FileManager.default.removeItem(at: channelOnlyURL) }
        _ = try await store.installEPG(
            profileID: profile.id,
            fileURL: channelOnlyURL,
            fetchedAt: date(20)
        )
        let coverageWithoutProgrammes = try await store.epgCoverageEnd(profileID: profile.id)
        XCTAssertNil(coverageWithoutProgrammes)

        // The latest stop wins even when it belongs to a channel other than the
        // one carrying the latest start.
        let scheduleURL = try temporaryXML(
            """
            <tv>
              <channel id="news"><display-name>News</display-name></channel>
              <channel id="film"><display-name>Film</display-name></channel>
              <programme channel="news" start="20260718150000 Z" stop="20260718160000 Z">
                <title>Bulletin</title>
              </programme>
              <programme channel="film" start="20260718140000 Z" stop="20260718183000 Z">
                <title>Feature</title>
              </programme>
            </tv>
            """
        )
        defer { try? FileManager.default.removeItem(at: scheduleURL) }
        _ = try await store.installEPG(
            profileID: profile.id,
            fileURL: scheduleURL,
            fetchedAt: date(30)
        )

        let coverageEnd = try await store.epgCoverageEnd(profileID: profile.id)
        XCTAssertEqual(coverageEnd, ISO8601DateFormatter().date(from: "2026-07-18T18:30:00Z"))
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
        let initialProgrammeCount = try await store.epgProgrammeCount(profileID: profile.id)
        XCTAssertEqual(initialProgrammeCount, 1)

        _ = await XCTAssertThrowsErrorAsync {
            _ = try await store.installEPG(
                profileID: profile.id,
                fileURL: self.fixtureURL("epg/malformed.xml"),
                fetchedAt: self.date(30)
            )
        }

        let epgChannels = try await store.epgChannels(profileID: profile.id)
        let programmeCountAfterFailedReplacement = try await store.epgProgrammeCount(
            profileID: profile.id
        )
        XCTAssertEqual(programmeCountAfterFailedReplacement, 1)
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

    func testNameAndIntervalEditPreservesBothSnapshotsStatusesAndManualMapping() async throws {
        let fixture = try await seededRetargetFixture()
        let originalProfiles = try await fixture.store.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first)
        let originalPointers = try snapshotPointers(
            fixture.container,
            profileID: fixture.profile.id
        )
        let originalInventory = try snapshotInventory(fixture.container)

        try await fixture.store.updateProfile(
            id: fixture.profile.id,
            input: try editedInput(
                originalProfile,
                name: "Renamed",
                m3uRefreshInterval: .hourly,
                epgRefreshInterval: .sixHours
            ),
            now: date(50)
        )

        let updatedProfiles = try await fixture.store.profiles()
        let updated = try XCTUnwrap(updatedProfiles.first)
        let channels = try await fixture.store.channels(profileID: fixture.profile.id)
        let epgChannels = try await fixture.store.epgChannels(profileID: fixture.profile.id)
        let mapping = try await fixture.store.manualMapping(
            profileID: fixture.profile.id,
            channelID: fixture.playlistChannel.id
        )
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.m3uURL, originalProfile.m3uURL)
        XCTAssertEqual(updated.epgURL, originalProfile.epgURL)
        XCTAssertEqual(updated.m3uRefreshInterval, .hourly)
        XCTAssertEqual(updated.epgRefreshInterval, .sixHours)
        XCTAssertEqual(updated.m3uStatus, originalProfile.m3uStatus)
        XCTAssertEqual(updated.epgStatus, originalProfile.epgStatus)
        XCTAssertEqual(
            try snapshotPointers(fixture.container, profileID: fixture.profile.id).playlist,
            originalPointers.playlist
        )
        XCTAssertEqual(
            try snapshotPointers(fixture.container, profileID: fixture.profile.id).epg,
            originalPointers.epg
        )
        assertInventory(try snapshotInventory(fixture.container), equals: originalInventory)
        XCTAssertEqual(channels, [fixture.playlistChannel])
        XCTAssertEqual(epgChannels.map(\.id), ["guide"])
        XCTAssertEqual(mapping?.xmltvChannelID, "manual-guide")
    }

    func testM3UURLRetargetInvalidatesOnlyPlaylistAndCleansOldSnapshot() async throws {
        let fixture = try await seededRetargetFixture()
        let playlistAttemptID = UUID()
        try await fixture.store.recordFailure(
            profileID: fixture.profile.id,
            resource: .playlist,
            summary: "stale playlist failure",
            at: date(50),
            attemptID: playlistAttemptID
        )
        let profilesBeforeUpdate = try await fixture.store.profiles()
        let before = try XCTUnwrap(profilesBeforeUpdate.first)
        let oldPointers = try snapshotPointers(fixture.container, profileID: fixture.profile.id)
        let oldPlaylistID = try XCTUnwrap(oldPointers.playlist)
        let oldEPGID = try XCTUnwrap(oldPointers.epg)
        XCTAssertNotNil(before.m3uStatus.lastAttemptAt)
        XCTAssertNotNil(before.m3uStatus.lastSuccessAt)
        XCTAssertEqual(before.m3uStatus.state, .failed)
        XCTAssertNotNil(before.m3uStatus.errorSummary)
        XCTAssertEqual(before.m3uStatus.attemptID, playlistAttemptID)

        let replacementURL = URL(
            string: "https://User:Pass@EXAMPLE.test:443/a%2Fb?sig=A%2BB#x"
        )!
        try await fixture.store.updateProfile(
            id: fixture.profile.id,
            input: try editedInput(before, m3uURL: replacementURL),
            now: date(60)
        )

        let profilesAfterUpdate = try await fixture.store.profiles()
        let updated = try XCTUnwrap(profilesAfterUpdate.first)
        let pointers = try snapshotPointers(fixture.container, profileID: fixture.profile.id)
        let inventory = try snapshotInventory(fixture.container)
        let channels = try await fixture.store.channels(profileID: fixture.profile.id)
        let epgChannels = try await fixture.store.epgChannels(profileID: fixture.profile.id)
        let mapping = try await fixture.store.manualMapping(
            profileID: fixture.profile.id,
            channelID: fixture.playlistChannel.id
        )
        XCTAssertEqual(updated.m3uURL.absoluteString, replacementURL.absoluteString)
        XCTAssertEqual(updated.m3uStatus, ResourceRefreshStatus())
        XCTAssertEqual(updated.epgStatus, before.epgStatus)
        XCTAssertNil(pointers.playlist)
        XCTAssertEqual(pointers.epg, oldEPGID)
        XCTAssertEqual(channels, [])
        XCTAssertEqual(epgChannels.map(\.id), ["guide"])
        XCTAssertEqual(mapping?.xmltvChannelID, "manual-guide")
        XCTAssertFalse(inventory.playlistHeaderIDs.contains(oldPlaylistID))
        XCTAssertFalse(inventory.channels.contains { $0.snapshotID == oldPlaylistID })
        XCTAssertEqual(inventory.epgHeaderIDs, [oldEPGID])
        XCTAssertTrue(inventory.epgChannels.allSatisfy { $0.snapshotID == oldEPGID })
        XCTAssertTrue(inventory.programmes.allSatisfy { $0.snapshotID == oldEPGID })
    }

    func testEPGURLRetargetInvalidatesOnlyEPGAndCleansOldSnapshot() async throws {
        let fixture = try await seededRetargetFixture()
        let epgAttemptID = UUID()
        try await fixture.store.recordFailure(
            profileID: fixture.profile.id,
            resource: .epg,
            summary: "stale EPG failure",
            at: date(50),
            attemptID: epgAttemptID
        )
        let profilesBeforeUpdate = try await fixture.store.profiles()
        let before = try XCTUnwrap(profilesBeforeUpdate.first)
        let oldPointers = try snapshotPointers(fixture.container, profileID: fixture.profile.id)
        let oldPlaylistID = try XCTUnwrap(oldPointers.playlist)
        let oldEPGID = try XCTUnwrap(oldPointers.epg)
        XCTAssertNotNil(before.epgStatus.lastAttemptAt)
        XCTAssertNotNil(before.epgStatus.lastSuccessAt)
        XCTAssertEqual(before.epgStatus.state, .failed)
        XCTAssertNotNil(before.epgStatus.errorSummary)
        XCTAssertEqual(before.epgStatus.attemptID, epgAttemptID)

        let replacementURL = URL(string: "https://epg.example/replacement.xml")!
        try await fixture.store.updateProfile(
            id: fixture.profile.id,
            input: try editedInput(before, epgURL: replacementURL),
            now: date(60)
        )

        let profilesAfterUpdate = try await fixture.store.profiles()
        let updated = try XCTUnwrap(profilesAfterUpdate.first)
        let pointers = try snapshotPointers(fixture.container, profileID: fixture.profile.id)
        let inventory = try snapshotInventory(fixture.container)
        let channels = try await fixture.store.channels(profileID: fixture.profile.id)
        let epgChannels = try await fixture.store.epgChannels(profileID: fixture.profile.id)
        let epgProgrammeCount = try await fixture.store.epgProgrammeCount(
            profileID: fixture.profile.id
        )
        let mapping = try await fixture.store.manualMapping(
            profileID: fixture.profile.id,
            channelID: fixture.playlistChannel.id
        )
        XCTAssertEqual(updated.epgURL.absoluteString, replacementURL.absoluteString)
        XCTAssertEqual(updated.epgStatus, ResourceRefreshStatus())
        XCTAssertEqual(updated.m3uStatus, before.m3uStatus)
        XCTAssertEqual(pointers.playlist, oldPlaylistID)
        XCTAssertNil(pointers.epg)
        XCTAssertEqual(channels, [fixture.playlistChannel])
        XCTAssertEqual(epgChannels, [])
        XCTAssertEqual(epgProgrammeCount, 0)
        XCTAssertEqual(mapping?.xmltvChannelID, "manual-guide")
        XCTAssertEqual(inventory.playlistHeaderIDs, [oldPlaylistID])
        XCTAssertTrue(inventory.channels.allSatisfy { $0.snapshotID == oldPlaylistID })
        XCTAssertFalse(inventory.epgHeaderIDs.contains(oldEPGID))
        XCTAssertFalse(inventory.epgChannels.contains { $0.snapshotID == oldEPGID })
        XCTAssertFalse(inventory.programmes.contains { $0.snapshotID == oldEPGID })
    }

    func testPlaylistPointerSaveFailurePreservesOldPointerAndRemovesAllStagingRows() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let original = channel(profileID: profile.id, name: "Original", path: "original")
        let replacement = channel(profileID: profile.id, name: "Replacement", path: "replacement")
        let originalEPGURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "original-epg", title: "Original EPG")
        )
        defer { try? FileManager.default.removeItem(at: originalEPGURL) }
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [original],
            fetchedAt: date(20)
        )
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalEPGURL,
            fetchedAt: date(25)
        )
        try await initialStore.recordSuccess(profileID: profile.id, resource: .playlist, at: date(30))
        try await initialStore.recordFailure(
            profileID: profile.id,
            resource: .epg,
            summary: "EPG refresh failed after the valid snapshot",
            at: date(35)
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalProfiles = try await initialStore.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first)
        let originalPlaylist = try await initialStore.channels(profileID: profile.id)
        let originalEPGChannels = try await initialStore.epgChannels(profileID: profile.id)
        let originalProgrammes = try await initialStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original-epg",
            overlapping: date(0)..<date(2_000_000_000)
        )
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
        let profilesAfterFailure = try await failingStore.profiles()
        let profileAfterFailure = try XCTUnwrap(profilesAfterFailure.first)
        let playlistAfterFailure = try await failingStore.channels(profileID: profile.id)
        let epgChannelsAfterFailure = try await failingStore.epgChannels(profileID: profile.id)
        let programmesAfterFailure = try await failingStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original-epg",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(pointersAfterFailure.playlist, originalPointers.playlist)
        XCTAssertEqual(pointersAfterFailure.epg, originalPointers.epg)
        XCTAssertEqual(profileAfterFailure.m3uStatus, originalProfile.m3uStatus)
        XCTAssertEqual(profileAfterFailure.epgStatus, originalProfile.epgStatus)
        XCTAssertEqual(playlistAfterFailure, originalPlaylist)
        XCTAssertEqual(epgChannelsAfterFailure, originalEPGChannels)
        XCTAssertEqual(programmesAfterFailure, originalProgrammes)
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testEPGPointerSaveFailurePreservesOldPointerAndRemovesAllStagingRows() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalPlaylist = channel(profileID: profile.id, name: "Original playlist", path: "original")
        let originalURL = try temporaryXML(singleProgrammeXMLTV(channelID: "original", title: "Original"))
        let replacementURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "replacement", title: "Replacement")
        )
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        try await initialStore.installPlaylist(
            profileID: profile.id,
            channels: [originalPlaylist],
            fetchedAt: date(20)
        )
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(25)
        )
        try await initialStore.recordSuccess(profileID: profile.id, resource: .playlist, at: date(30))
        try await initialStore.recordFailure(
            profileID: profile.id,
            resource: .epg,
            summary: "EPG refresh failed after the valid snapshot",
            at: date(35)
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalProfiles = try await initialStore.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first)
        let originalPlaylistResults = try await initialStore.channels(profileID: profile.id)
        let originalEPGChannels = try await initialStore.epgChannels(profileID: profile.id)
        let originalProgrammes = try await initialStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
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
        let profilesAfterFailure = try await failingStore.profiles()
        let profileAfterFailure = try XCTUnwrap(profilesAfterFailure.first)
        let playlistAfterFailure = try await failingStore.channels(profileID: profile.id)
        let epgChannelsAfterFailure = try await failingStore.epgChannels(profileID: profile.id)
        let programmesAfterFailure = try await failingStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(pointersAfterFailure.playlist, originalPointers.playlist)
        XCTAssertEqual(pointersAfterFailure.epg, originalPointers.epg)
        XCTAssertEqual(profileAfterFailure.m3uStatus, originalProfile.m3uStatus)
        XCTAssertEqual(profileAfterFailure.epgStatus, originalProfile.epgStatus)
        XCTAssertEqual(playlistAfterFailure, originalPlaylistResults)
        XCTAssertEqual(epgChannelsAfterFailure, originalEPGChannels)
        XCTAssertEqual(programmesAfterFailure, originalProgrammes)
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testEPGSinkFinishPropagatesCancellationBeforeFinalFlush() throws {
        let cancellation = CancellationOccurrenceProbe(failingAt: 2)
        let batches = EPGBatchRecorder()
        let sink = EPGPersistenceSink(
            cancellationCheck: { try cancellation.check() },
            persistBatch: { batches.persist($0) }
        )
        try sink.accept(channel: EPGChannel(
            id: "guide",
            displayNames: ["Guide"],
            iconURL: nil
        ))

        XCTAssertThrowsError(try sink.finish()) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(batches.recorded.count, 0)
    }

    func testEPGSinkFinishPropagatesCancellationAfterFinalBatchPersistence() throws {
        let cancellation = CancellationOccurrenceProbe(failingAt: 3)
        let batches = EPGBatchRecorder()
        let sink = EPGPersistenceSink(
            cancellationCheck: { try cancellation.check() },
            persistBatch: { batches.persist($0) }
        )
        try sink.accept(channel: EPGChannel(
            id: "guide",
            displayNames: ["Guide"],
            iconURL: nil
        ))

        XCTAssertThrowsError(try sink.finish()) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(batches.recorded.count, 1)
        XCTAssertEqual(batches.recorded.first?.channels.map(\.id), ["guide"])
        XCTAssertEqual(batches.recorded.first?.programmes, [])
    }

    func testEPGSinkPersistsExactCombinedBatchSizesWithoutDroppingOrDuplicatingEvents() throws {
        let batches = EPGBatchRecorder()
        let sink = EPGPersistenceSink(
            cancellationCheck: {},
            persistBatch: { batches.persist($0) }
        )
        try sink.accept(channel: EPGChannel(
            id: "guide",
            displayNames: ["Guide"],
            iconURL: nil
        ))
        let expectedProgrammeIDs = (0..<1_001).map { "programme-\($0)" }
        for (index, id) in expectedProgrammeIDs.enumerated() {
            try sink.accept(programme: Programme(
                id: id,
                xmltvChannelID: "guide",
                start: date(TimeInterval(index)),
                stop: date(TimeInterval(index + 1)),
                title: "Programme \(index)",
                subtitle: nil,
                summary: nil,
                categories: []
            ))
        }

        try sink.finish()

        let recorded = batches.recorded
        XCTAssertEqual(
            recorded.map { $0.channels.count + $0.programmes.count },
            [500, 500, 2]
        )
        let channelIDs = recorded.flatMap(\.channels).map(\.id)
        let programmeIDs = recorded.flatMap(\.programmes).map(\.id)
        XCTAssertEqual(channelIDs, ["guide"])
        XCTAssertEqual(Set(channelIDs).count, 1)
        XCTAssertEqual(programmeIDs, expectedProgrammeIDs)
        XCTAssertEqual(Set(programmeIDs).count, 1_001)
    }

    func testEPGImportPersistsHeaderThreeBoundedBatchesAndFinalCounts() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "original", title: "Original")
        )
        let replacementURL = try temporaryXML(batchedXMLTV(programmeCount: 1_001))
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        let oldPointer = try XCTUnwrap(
            try snapshotPointers(container, profileID: profile.id).epg
        )
        let saveProbe = SaveOccurrenceFaultProbe()
        let contextProbe = SaveContextObservationProbe()
        let store = SwiftDataLibraryStore(
            modelContainer: container,
            saveContextObserver: { contextProbe.record($0) }
        ) { phase in
            try saveProbe.record(phase)
        }

        let summary = try await store.installEPG(
            profileID: profile.id,
            fileURL: replacementURL,
            fetchedAt: date(30)
        )

        XCTAssertEqual(summary, XMLTVParseSummary(channelCount: 1, programmeCount: 1_001))
        XCTAssertEqual(saveProbe.occurrence(of: .epgHeader), 1)
        XCTAssertEqual(saveProbe.occurrence(of: .epgBatch), 3)
        XCTAssertEqual(saveProbe.occurrence(of: .epgStaging), 1)
        XCTAssertEqual(saveProbe.occurrence(of: .epgPointer), 1)
        let pointer = try XCTUnwrap(try snapshotPointers(container, profileID: profile.id).epg)
        XCTAssertNotEqual(pointer, oldPointer)
        let context = ModelContext(container)
        let snapshotID = pointer
        let header = try XCTUnwrap(try context.fetch(FetchDescriptor<EPGSnapshotRecord>(
            predicate: #Predicate { $0.id == snapshotID }
        )).first)
        XCTAssertEqual(header.channelCount, 1)
        XCTAssertEqual(header.programmeCount, 1_001)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<EPGChannelRecord>(
                predicate: #Predicate { $0.snapshotID == snapshotID }
            )).count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ProgrammeRecord>(
                predicate: #Predicate { $0.snapshotID == snapshotID }
            )).count,
            1_001
        )
        let programmeCount = try await store.epgProgrammeCount(profileID: profile.id)
        XCTAssertEqual(programmeCount, 1_001)
        let contextObservations = contextProbe.recorded.filter {
            $0.phase == .epgHeader
                || $0.phase == .epgBatch
                || $0.phase == .epgStaging
                || $0.phase == .epgPointer
                || $0.phase == .epgCleanup
        }
        XCTAssertEqual(contextObservations.map(\.phase), [
            .epgHeader,
            .epgBatch,
            .epgBatch,
            .epgBatch,
            .epgStaging,
            .epgPointer,
            .epgCleanup
        ])
        XCTAssertEqual(Set(contextObservations.map(\.contextIdentity)).count, 7)
        let pointerContext = try XCTUnwrap(
            contextObservations.first { $0.phase == .epgPointer }?.contextIdentity
        )
        XCTAssertTrue(
            contextObservations
                .filter { $0.phase != .epgPointer }
                .allSatisfy { $0.contextIdentity != pointerContext }
        )
    }

    func testEPGCancellationBeforeFinalFlushCleansStagingWithoutReachingPointer() async throws {
        try await assertEPGStagingCancellation(
            checkpoint: .beforeFinalFlush,
            replacementProgrammeCount: 1,
            expectedBatchOccurrences: 0
        )
    }

    func testLateEPGCancellationBoundsCleanupContextPopulationIndependentlyOfStagedRowCount() async throws {
        try await assertEPGStagingCancellation(
            checkpoint: .beforeFinalFlush,
            replacementProgrammeCount: 1_001,
            expectedBatchOccurrences: 2,
            expectedReachedCheckpoints: [
                .afterBatchPersist,
                .afterBatchCancellationCheck,
                .afterBatchPersist,
                .afterBatchCancellationCheck,
                .beforeFinalFlush
            ],
            maximumCleanupDeletedModelCount: 500
        )
    }

    func testEPGCancellationAfterSavedBatchCleansStagingWithoutReachingPointer() async throws {
        try await assertEPGStagingCancellation(
            checkpoint: .afterBatchPersist,
            replacementProgrammeCount: 499,
            expectedBatchOccurrences: 1
        )
    }

    func testEPGHeaderSaveFailureCleansStagingAndPreservesLastKnownGoodState() async throws {
        try await assertEPGStagingFailure(
            phase: .epgHeader,
            occurrence: 1,
            expectedBatchOccurrences: 0,
            expectedFinalOccurrences: 0
        )
    }

    func testEPGSecondBatchSaveFailureCleansEverySavedBatchAndPreservesLastKnownGoodState() async throws {
        try await assertEPGStagingFailure(
            phase: .epgBatch,
            occurrence: 2,
            expectedBatchOccurrences: 2,
            expectedFinalOccurrences: 0
        )
    }

    func testEPGFinalHeaderUpdateFailureCleansEverySavedBatchAndPreservesLastKnownGoodState() async throws {
        try await assertEPGStagingFailure(
            phase: .epgStaging,
            occurrence: 1,
            expectedBatchOccurrences: 3,
            expectedFinalOccurrences: 1
        )
    }

    func testEPGCleanupFailureLeavesOnlyUnreferencedRowsForRestartPurge() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "original", title: "Original")
        )
        let replacementURL = try temporaryXML(batchedXMLTV(programmeCount: 1_001))
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        try await initialStore.recordSuccess(
            profileID: profile.id,
            resource: .epg,
            at: date(25)
        )
        let originalPointer = try XCTUnwrap(
            try snapshotPointers(container, profileID: profile.id).epg
        )
        let originalInventory = try snapshotInventory(container)
        let originalProfiles = try await initialStore.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first)
        let saveProbe = SaveOccurrenceFaultProbe(failures: [
            SaveOccurrenceFailure(
                phase: .epgBatch,
                occurrence: 2,
                error: .staging
            ),
            SaveOccurrenceFailure(
                phase: .epgCleanup,
                occurrence: 1,
                error: .cleanup
            )
        ])
        let failingStore = SwiftDataLibraryStore(modelContainer: container) { phase in
            try saveProbe.record(phase)
        }

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.installEPG(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(30)
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .staging)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).epg, originalPointer)
        let profilesAfterFailure = try await failingStore.profiles()
        XCTAssertEqual(profilesAfterFailure.first?.epgStatus, originalProfile.epgStatus)
        let inventoryWithResidual = try snapshotInventory(container)
        let referencedIDs = Set(
            try ModelContext(container).fetch(FetchDescriptor<SourceProfileRecord>())
                .compactMap(\.epgSnapshotID)
        )
        let residualHeaderIDs = Set(inventoryWithResidual.epgHeaderIDs)
            .subtracting(referencedIDs)
        XCTAssertEqual(referencedIDs, [originalPointer])
        XCTAssertEqual(residualHeaderIDs.count, 1)
        XCTAssertTrue(
            inventoryWithResidual.epgChannels
                .filter { !referencedIDs.contains($0.snapshotID) }
                .allSatisfy { residualHeaderIDs.contains($0.snapshotID) }
        )
        XCTAssertTrue(
            inventoryWithResidual.programmes
                .filter { !referencedIDs.contains($0.snapshotID) }
                .allSatisfy { residualHeaderIDs.contains($0.snapshotID) }
        )
        XCTAssertEqual(
            inventoryWithResidual.epgChannels.filter {
                residualHeaderIDs.contains($0.snapshotID)
            }.count,
            1
        )
        XCTAssertEqual(
            inventoryWithResidual.programmes.filter {
                residualHeaderIDs.contains($0.snapshotID)
            }.count,
            499
        )

        let restartedStore = SwiftDataLibraryStore(modelContainer: container)
        try await restartedStore.purgeUnreferencedSnapshots()

        assertInventory(try snapshotInventory(container), equals: originalInventory)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).epg, originalPointer)
        let profilesAfterPurge = try await restartedStore.profiles()
        XCTAssertEqual(profilesAfterPurge.first?.epgStatus, originalProfile.epgStatus)
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

    func testAtomicPlaylistRefreshCommitSaveFailureRollsBackPointerAndSuccessStatus() async throws {
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
        try await initialStore.recordSuccess(
            profileID: profile.id,
            resource: .playlist,
            at: date(30)
        )
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000951")!
        let refreshContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.m3uURL),
            attemptID: attemptID
        )
        try await initialStore.recordAttempt(
            profileID: profile.id,
            resource: .playlist,
            at: date(40),
            attemptID: attemptID
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let failingStore = makeStore(container: container, failingSave: .playlistPointer)

        let error = await XCTAssertThrowsErrorAsync {
            try await failingStore.commitPlaylistRefresh(
                profileID: profile.id,
                channels: [replacement],
                fetchedAt: self.date(50),
                context: refreshContext
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .expected)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).playlist, originalPointers.playlist)
        let activeChannels = try await failingStore.channels(profileID: profile.id)
        let profiles = try await failingStore.profiles()
        let currentProfile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(activeChannels, [original])
        XCTAssertEqual(currentProfile.m3uStatus.state, .refreshing)
        XCTAssertEqual(currentProfile.m3uStatus.lastAttemptAt, date(40))
        XCTAssertEqual(currentProfile.m3uStatus.lastSuccessAt, date(30))
        assertInventory(try snapshotInventory(container), equals: originalInventory)
    }

    func testAtomicEPGRefreshCommitSaveFailureRollsBackPointerAndSuccessStatus() async throws {
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
        try await initialStore.recordSuccess(
            profileID: profile.id,
            resource: .epg,
            at: date(30)
        )
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000952")!
        let refreshContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.epgURL),
            attemptID: attemptID
        )
        try await initialStore.recordAttempt(
            profileID: profile.id,
            resource: .epg,
            at: date(40),
            attemptID: attemptID
        )
        let originalPointers = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let failingStore = makeStore(container: container, failingSave: .epgPointer)

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.commitEPGRefresh(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(50),
                context: refreshContext
            )
        }

        XCTAssertEqual(error as? InjectedSaveError, .expected)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).epg, originalPointers.epg)
        let activeChannels = try await failingStore.epgChannels(profileID: profile.id)
        let profiles = try await failingStore.profiles()
        let currentProfile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(activeChannels.map(\.id), ["original"])
        XCTAssertEqual(currentProfile.epgStatus.state, .refreshing)
        XCTAssertEqual(currentProfile.epgStatus.lastAttemptAt, date(40))
        XCTAssertEqual(currentProfile.epgStatus.lastSuccessAt, date(30))
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

    func testConditionalBeginRejectsRetargetWithoutChangingStatusOrUpdatedAt() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let oldContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.m3uURL),
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!
        )

        let beganOldSource = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldSource)
        let startedProfiles = try await store.profiles()
        let started = try XCTUnwrap(startedProfiles.first)
        XCTAssertEqual(started.m3uStatus.state, .refreshing)
        XCTAssertEqual(started.m3uStatus.attemptID, oldContext.attemptID)

        let replacementURL = URL(string: "https://playlist.example/replacement.m3u")!
        try await store.updateProfile(
            id: profile.id,
            input: try editedInput(started, m3uURL: replacementURL),
            now: date(30)
        )
        let beganRetargetedSource = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            at: date(40)
        )
        XCTAssertFalse(beganRetargetedSource)

        let rejectedProfiles = try await store.profiles()
        let rejected = try XCTUnwrap(rejectedProfiles.first)
        XCTAssertEqual(rejected.m3uStatus, ResourceRefreshStatus())
        XCTAssertEqual(rejected.updatedAt, date(30))
    }

    func testConditionalFailureRequiresCurrentSourceAndStoredAttempt() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let source = SourceURLIdentity(url: profile.epgURL)
        let oldContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000921")!
        )
        let currentContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000922")!
        )
        let beganOldAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldAttempt)
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: currentContext,
            at: date(30)
        )
        XCTAssertTrue(beganCurrentAttempt)

        let persistedOldFailure = try await store.recordRefreshFailure(
            profileID: profile.id,
            resource: .epg,
            context: oldContext,
            summary: "obsolete failure",
            at: date(40)
        )
        XCTAssertFalse(persistedOldFailure)

        let afterRejectedProfiles = try await store.profiles()
        let afterRejectedFailure = try XCTUnwrap(afterRejectedProfiles.first)
        XCTAssertEqual(afterRejectedFailure.epgStatus.state, .refreshing)
        XCTAssertEqual(afterRejectedFailure.epgStatus.attemptID, currentContext.attemptID)
        XCTAssertNil(afterRejectedFailure.epgStatus.errorSummary)
        XCTAssertEqual(afterRejectedFailure.updatedAt, date(30))

        let persistedCurrentFailure = try await store.recordRefreshFailure(
            profileID: profile.id,
            resource: .epg,
            context: currentContext,
            summary: String(repeating: "x", count: 300),
            at: date(50)
        )
        XCTAssertTrue(persistedCurrentFailure)
        let failedProfiles = try await store.profiles()
        let failed = try XCTUnwrap(failedProfiles.first)
        XCTAssertEqual(failed.epgStatus.state, .failed)
        XCTAssertEqual(failed.epgStatus.attemptID, currentContext.attemptID)
        XCTAssertEqual(failed.epgStatus.errorSummary?.count, 240)
        XCTAssertEqual(failed.updatedAt, date(50))
    }

    func testOldSourceFailureWithStoredAttemptIsRejectedWithoutChangingStatus() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000923")!
        let oldContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.m3uURL),
            attemptID: attemptID
        )
        let beganOldSource = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldSource)
        let replacementURL = URL(string: "https://playlist.example/replacement.m3u")!
        try await store.updateProfile(
            id: profile.id,
            input: try editedInput(profile, m3uURL: replacementURL),
            now: date(30)
        )
        let currentContext = RefreshSourceContext(
            source: SourceURLIdentity(url: replacementURL),
            attemptID: attemptID
        )
        let beganCurrentSource = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: currentContext,
            at: date(40)
        )
        XCTAssertTrue(beganCurrentSource)

        let persistedOldSourceFailure = try await store.recordRefreshFailure(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            summary: "obsolete",
            at: date(50)
        )

        XCTAssertFalse(persistedOldSourceFailure)
        let profiles = try await store.profiles()
        let unchanged = try XCTUnwrap(profiles.first)
        XCTAssertEqual(unchanged.m3uStatus.state, .refreshing)
        XCTAssertEqual(unchanged.m3uStatus.attemptID, attemptID)
        XCTAssertNil(unchanged.m3uStatus.errorSummary)
        XCTAssertEqual(unchanged.updatedAt, date(40))
    }

    func testOldAttemptFailureForSameSourceReturnsFalseWithoutAttemptingStatusSave() async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let store = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let source = SourceURLIdentity(url: profile.m3uURL)
        let oldContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000924")!
        )
        let currentContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000925")!
        )
        let beganOldAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldAttempt)
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: currentContext,
            at: date(30)
        )
        XCTAssertTrue(beganCurrentAttempt)
        let phaseRecorder = SavePhaseRecorder(failingAt: .status)
        let failingStore = SwiftDataLibraryStore(modelContainer: container) { phase in
            try phaseRecorder.record(phase)
        }

        let persistedOldFailure = try await failingStore.recordRefreshFailure(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            summary: "obsolete",
            at: date(40)
        )

        XCTAssertFalse(persistedOldFailure)
        XCTAssertEqual(phaseRecorder.recorded, [])
        let profiles = try await failingStore.profiles()
        let unchanged = try XCTUnwrap(profiles.first)
        XCTAssertEqual(unchanged.m3uStatus.state, .refreshing)
        XCTAssertEqual(unchanged.m3uStatus.attemptID, currentContext.attemptID)
        XCTAssertNil(unchanged.m3uStatus.errorSummary)
        XCTAssertEqual(unchanged.updatedAt, date(30))
    }

    func testOldPlaylistAttemptCannotCommitAfterNewAttemptBeginsForSameSource() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let source = SourceURLIdentity(url: profile.m3uURL)
        let oldContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000926")!
        )
        let currentContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000927")!
        )
        let beganOldAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldAttempt)
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: currentContext,
            at: date(30)
        )
        XCTAssertTrue(beganCurrentAttempt)
        let current = channel(profileID: profile.id, name: "Current", path: "current")
        try await store.commitPlaylistRefresh(
            profileID: profile.id,
            channels: [current],
            fetchedAt: date(40),
            context: currentContext
        )
        let currentPointers = try snapshotPointers(container, profileID: profile.id)
        let currentInventory = try snapshotInventory(container)

        let error = await XCTAssertThrowsErrorAsync {
            try await store.commitPlaylistRefresh(
                profileID: profile.id,
                channels: [self.channel(profileID: profile.id, name: "Obsolete", path: "obsolete")],
                fetchedAt: self.date(50),
                context: oldContext
            )
        }

        XCTAssertEqual(error as? LibraryRepositoryError, .sourceConfigurationChanged)
        XCTAssertEqual(
            try snapshotPointers(container, profileID: profile.id).playlist,
            currentPointers.playlist
        )
        let activeChannels = try await store.channels(profileID: profile.id)
        XCTAssertEqual(activeChannels, [current])
        let profiles = try await store.profiles()
        let unchanged = try XCTUnwrap(profiles.first)
        XCTAssertEqual(unchanged.m3uStatus.state, .succeeded)
        XCTAssertEqual(unchanged.m3uStatus.attemptID, currentContext.attemptID)
        XCTAssertEqual(unchanged.m3uStatus.lastSuccessAt, date(40))
        XCTAssertEqual(unchanged.updatedAt, date(40))
        assertInventory(try snapshotInventory(container), equals: currentInventory)
    }

    func testOldEPGAttemptCannotCommitAfterNewAttemptBeginsForSameSource() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let source = SourceURLIdentity(url: profile.epgURL)
        let oldContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000928")!
        )
        let currentContext = RefreshSourceContext(
            source: source,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000929")!
        )
        let beganOldAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: oldContext,
            at: date(20)
        )
        XCTAssertTrue(beganOldAttempt)
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: currentContext,
            at: date(30)
        )
        XCTAssertTrue(beganCurrentAttempt)
        let currentURL = try temporaryXML(singleProgrammeXMLTV(channelID: "current", title: "Current"))
        let obsoleteURL = try temporaryXML(singleProgrammeXMLTV(channelID: "obsolete", title: "Obsolete"))
        defer {
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: obsoleteURL)
        }
        _ = try await store.commitEPGRefresh(
            profileID: profile.id,
            fileURL: currentURL,
            fetchedAt: date(40),
            context: currentContext
        )
        let currentPointers = try snapshotPointers(container, profileID: profile.id)
        let currentInventory = try snapshotInventory(container)

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await store.commitEPGRefresh(
                profileID: profile.id,
                fileURL: obsoleteURL,
                fetchedAt: self.date(50),
                context: oldContext
            )
        }

        XCTAssertEqual(error as? LibraryRepositoryError, .sourceConfigurationChanged)
        XCTAssertEqual(
            try snapshotPointers(container, profileID: profile.id).epg,
            currentPointers.epg
        )
        let activeChannels = try await store.epgChannels(profileID: profile.id)
        XCTAssertEqual(activeChannels.map(\.id), ["current"])
        let programmes = try await store.programmes(
            profileID: profile.id,
            xmltvChannelID: "current",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(programmes.map(\.title), ["Current"])
        let profiles = try await store.profiles()
        let unchanged = try XCTUnwrap(profiles.first)
        XCTAssertEqual(unchanged.epgStatus.state, .succeeded)
        XCTAssertEqual(unchanged.epgStatus.attemptID, currentContext.attemptID)
        XCTAssertEqual(unchanged.epgStatus.lastSuccessAt, date(40))
        XCTAssertEqual(unchanged.updatedAt, date(40))
        assertInventory(try snapshotInventory(container), equals: currentInventory)
    }

    func testOldSourcePlaylistCommitCleansStagingAndPreservesCurrentPointerAndStatus() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000931")!
        let staleContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.m3uURL),
            attemptID: attemptID
        )
        let beganStaleAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: staleContext,
            at: date(20)
        )
        XCTAssertTrue(beganStaleAttempt)
        let replacementURL = URL(string: "https://playlist.example/current.m3u")!
        try await store.updateProfile(
            id: profile.id,
            input: try editedInput(profile, m3uURL: replacementURL),
            now: date(30)
        )
        let currentContext = RefreshSourceContext(
            source: SourceURLIdentity(url: replacementURL),
            attemptID: attemptID
        )
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .playlist,
            context: currentContext,
            at: date(40)
        )
        XCTAssertTrue(beganCurrentAttempt)
        let current = channel(profileID: profile.id, name: "Current", path: "current")
        try await store.commitPlaylistRefresh(
            profileID: profile.id,
            channels: [current],
            fetchedAt: date(40),
            context: currentContext
        )
        let currentPointers = try snapshotPointers(container, profileID: profile.id)
        let currentInventory = try snapshotInventory(container)

        let error = await XCTAssertThrowsErrorAsync {
            try await store.commitPlaylistRefresh(
                profileID: profile.id,
                channels: [self.channel(profileID: profile.id, name: "Stale", path: "stale")],
                fetchedAt: self.date(50),
                context: staleContext
            )
        }

        XCTAssertEqual(error as? LibraryRepositoryError, .sourceConfigurationChanged)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).playlist, currentPointers.playlist)
        let activeChannels = try await store.channels(profileID: profile.id)
        XCTAssertEqual(activeChannels, [current])
        let afterProfiles = try await store.profiles()
        let after = try XCTUnwrap(afterProfiles.first)
        XCTAssertEqual(after.m3uStatus.state, .succeeded)
        XCTAssertEqual(after.m3uStatus.attemptID, currentContext.attemptID)
        assertInventory(try snapshotInventory(container), equals: currentInventory)
    }

    func testOldSourceEPGCommitCleansStagingAndPreservesCurrentPointerAndStatus() async throws {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        let staleContext = RefreshSourceContext(
            source: SourceURLIdentity(url: profile.epgURL),
            attemptID: attemptID
        )
        let beganStaleAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: staleContext,
            at: date(20)
        )
        XCTAssertTrue(beganStaleAttempt)
        let replacementURL = URL(string: "https://epg.example/current.xml")!
        try await store.updateProfile(
            id: profile.id,
            input: try editedInput(profile, epgURL: replacementURL),
            now: date(30)
        )
        let currentContext = RefreshSourceContext(
            source: SourceURLIdentity(url: replacementURL),
            attemptID: attemptID
        )
        let beganCurrentAttempt = try await store.beginRefresh(
            profileID: profile.id,
            resource: .epg,
            context: currentContext,
            at: date(40)
        )
        XCTAssertTrue(beganCurrentAttempt)
        let currentURL = try temporaryXML(singleProgrammeXMLTV(channelID: "current", title: "Current"))
        let staleURL = try temporaryXML(singleProgrammeXMLTV(channelID: "stale", title: "Stale"))
        defer {
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: staleURL)
        }
        _ = try await store.commitEPGRefresh(
            profileID: profile.id,
            fileURL: currentURL,
            fetchedAt: date(40),
            context: currentContext
        )
        let currentPointers = try snapshotPointers(container, profileID: profile.id)
        let currentInventory = try snapshotInventory(container)

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await store.commitEPGRefresh(
                profileID: profile.id,
                fileURL: staleURL,
                fetchedAt: self.date(50),
                context: staleContext
            )
        }

        XCTAssertEqual(error as? LibraryRepositoryError, .sourceConfigurationChanged)
        XCTAssertEqual(try snapshotPointers(container, profileID: profile.id).epg, currentPointers.epg)
        let activeChannels = try await store.epgChannels(profileID: profile.id)
        XCTAssertEqual(activeChannels.map(\.id), ["current"])
        let afterProfiles = try await store.profiles()
        let after = try XCTUnwrap(afterProfiles.first)
        XCTAssertEqual(after.epgStatus.state, .succeeded)
        XCTAssertEqual(after.epgStatus.attemptID, currentContext.attemptID)
        assertInventory(try snapshotInventory(container), equals: currentInventory)
    }

    func testRefreshAttemptIdentityPersistsThroughTerminalStatusAndAtomicSnapshotSuccess() async throws {
        let (_, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let failedAttemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let successfulAttemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!

        try await store.recordAttempt(
            profileID: profile.id,
            resource: .playlist,
            at: date(20),
            attemptID: failedAttemptID
        )
        try await store.recordFailure(
            profileID: profile.id,
            resource: .playlist,
            summary: "failed",
            at: date(20),
            attemptID: failedAttemptID
        )
        var profiles = try await store.profiles()
        var updated = try XCTUnwrap(profiles.first)
        XCTAssertEqual(updated.m3uStatus.state, .failed)
        XCTAssertEqual(updated.m3uStatus.attemptID, failedAttemptID)
        XCTAssertNil(updated.epgStatus.attemptID)

        try await store.recordAttempt(
            profileID: profile.id,
            resource: .playlist,
            at: date(30),
            attemptID: successfulAttemptID
        )
        try await store.commitPlaylistRefresh(
            profileID: profile.id,
            channels: [channel(profileID: profile.id, name: "Current", path: "current")],
            fetchedAt: date(30),
            context: RefreshSourceContext(
                source: SourceURLIdentity(url: profile.m3uURL),
                attemptID: successfulAttemptID
            )
        )
        profiles = try await store.profiles()
        updated = try XCTUnwrap(profiles.first)
        XCTAssertEqual(updated.m3uStatus.state, .succeeded)
        XCTAssertEqual(updated.m3uStatus.attemptID, successfulAttemptID)
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

    func testPurgedStoreRebuildsMirroredProfilesAndTheActiveSelection() async throws {
        let defaults = try mirrorDefaults()
        let (_, original) = try makeMirroringStore(defaults: defaults)
        _ = try await original.createProfile(input(name: "First"), now: date(10))
        let second = try await original.createProfile(input(name: "Second"), now: date(20))
        try await original.setActiveProfile(id: second.id)
        let mirroredProfiles = try await original.profiles()

        // A purged Caches directory leaves the next launch opening a store with
        // nothing in it, which a fresh in-memory container reproduces exactly.
        let (_, afterPurge) = try makeMirroringStore(defaults: defaults)
        let restoredCount = try await afterPurge.synchronizeProfileMirror()

        let restored = try await afterPurge.profiles()
        let active = try await afterPurge.activeProfile()
        XCTAssertEqual(restoredCount, 2)
        XCTAssertEqual(active?.id, second.id)
        XCTAssertEqual(restored.map(\.id), mirroredProfiles.map(\.id))
        XCTAssertEqual(restored.map(\.name), ["First", "Second"])
        XCTAssertEqual(restored.map(\.m3uURL), mirroredProfiles.map(\.m3uURL))
        XCTAssertEqual(restored.map(\.epgURL), mirroredProfiles.map(\.epgURL))
        XCTAssertEqual(
            restored.map(\.m3uRefreshInterval),
            mirroredProfiles.map(\.m3uRefreshInterval)
        )
        XCTAssertEqual(
            restored.map(\.epgRefreshInterval),
            mirroredProfiles.map(\.epgRefreshInterval)
        )
        XCTAssertEqual(restored.map(\.createdAt), mirroredProfiles.map(\.createdAt))
        // The playlist and EPG the profile pointed at went with the purge, so a
        // restored profile has to read as never refreshed rather than claiming
        // data it no longer has.
        XCTAssertEqual(restored.map(\.m3uStatus.state), [.never, .never])
        XCTAssertEqual(restored.map(\.epgStatus.state), [.never, .never])
        let restoredChannels = try await afterPurge.channels(profileID: second.id)
        XCTAssertEqual(restoredChannels, [])
    }

    func testIntactStoreKeepsItsProfilesAndIsNotDuplicatedByTheMirror() async throws {
        let defaults = try mirrorDefaults()
        let (container, store) = try makeMirroringStore(defaults: defaults)
        let first = try await store.createProfile(input(name: "First"), now: date(10))
        let second = try await store.createProfile(input(name: "Second"), now: date(20))
        try await store.setActiveProfile(id: second.id)
        try await store.installPlaylist(
            profileID: first.id,
            channels: [channel(profileID: first.id, name: "Live", path: "live")],
            fetchedAt: date(30)
        )

        let restoredCount = try await store.synchronizeProfileMirror()

        let profiles = try await store.profiles()
        let active = try await store.activeProfile()
        XCTAssertEqual(restoredCount, 0)
        XCTAssertEqual(profiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(active?.id, second.id)
        // Restoring on top of a live store would double every row rather than
        // report a count, so count the records instead of trusting the API.
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SourceProfileRecord>()).count,
            2
        )
        let channels = try await store.channels(profileID: first.id)
        XCTAssertEqual(channels.map(\.displayName), ["Live"])
    }

    func testMirrorFollowsProfileEditsSoAPurgeCannotResurrectDeletedProfiles() async throws {
        let defaults = try mirrorDefaults()
        let (_, original) = try makeMirroringStore(defaults: defaults)
        let kept = try await original.createProfile(input(name: "Kept"), now: date(10))
        let removed = try await original.createProfile(input(name: "Removed"), now: date(20))
        try await original.setActiveProfile(id: removed.id)
        try await original.updateProfile(id: kept.id, input: input(name: "Renamed"), now: date(30))
        try await original.deleteProfile(id: removed.id)

        let (_, afterPurge) = try makeMirroringStore(defaults: defaults)
        let restoredCount = try await afterPurge.synchronizeProfileMirror()

        let restored = try await afterPurge.profiles()
        let active = try await afterPurge.activeProfile()
        XCTAssertEqual(restoredCount, 1)
        XCTAssertEqual(restored.map(\.name), ["Renamed"])
        XCTAssertEqual(restored.map(\.m3uURL.absoluteString), [
            "https://playlist.example/Renamed.m3u",
        ])
        // Deleting the active profile hands the selection to the survivor, and
        // the mirror has to have recorded that rather than the deleted id.
        XCTAssertEqual(active?.id, kept.id)
    }

    func testStoreWrittenBeforeMirroringExistedIsBackfilledOnFirstSynchronize() async throws {
        let defaults = try mirrorDefaults()
        let container = try VPlayerModelContainer.make(inMemory: true)
        let unmirrored = SwiftDataLibraryStore(modelContainer: container)
        let first = try await unmirrored.createProfile(input(name: "First"), now: date(10))
        let second = try await unmirrored.createProfile(input(name: "Second"), now: date(20))
        try await unmirrored.setActiveProfile(id: second.id)
        XCTAssertNil(defaults.data(forKey: SourceProfileMirror.storageKey))

        let mirroring = SwiftDataLibraryStore(
            modelContainer: container,
            profileMirror: SourceProfileMirror(defaults: defaults)
        )
        let backfilledCount = try await mirroring.synchronizeProfileMirror()
        XCTAssertEqual(backfilledCount, 0)

        let (_, afterPurge) = try makeMirroringStore(defaults: defaults)
        let restoredCount = try await afterPurge.synchronizeProfileMirror()
        let restored = try await afterPurge.profiles()
        let active = try await afterPurge.activeProfile()
        XCTAssertEqual(restoredCount, 2)
        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        XCTAssertEqual(active?.id, second.id)
    }

    func testUnrestorableMirrorEntriesAreDroppedWithoutLosingTheRest() async throws {
        let defaults = try mirrorDefaults()
        let unusableID = UUID()
        let usableID = UUID()
        // Written by hand because no store mutation can produce a profile whose
        // URL never parses, while a hand-edited or truncated defaults plist can.
        defaults.set(Data("""
        {
          "profiles": [
            {
              "id": "\(unusableID.uuidString)",
              "name": "Unusable",
              "m3uURLString": "not a url",
              "epgURLString": "https://epg.example/Unusable.xml",
              "m3uRefreshIntervalRaw": 21600,
              "epgRefreshIntervalRaw": 86400,
              "createdAt": 10,
              "updatedAt": 10
            },
            {
              "id": "\(usableID.uuidString)",
              "name": "Usable",
              "m3uURLString": "https://playlist.example/Usable.m3u",
              "epgURLString": "https://epg.example/Usable.xml",
              "m3uRefreshIntervalRaw": 21600,
              "epgRefreshIntervalRaw": 86400,
              "createdAt": 20,
              "updatedAt": 20
            }
          ],
          "activeProfileID": "\(unusableID.uuidString)"
        }
        """.utf8), forKey: SourceProfileMirror.storageKey)

        let (_, store) = try makeMirroringStore(defaults: defaults)
        let restoredCount = try await store.synchronizeProfileMirror()

        let restored = try await store.profiles()
        let active = try await store.activeProfile()
        XCTAssertEqual(restoredCount, 1)
        // One unusable entry must not take `profiles()` down with it, and the
        // selection has to fall back to something that actually came back.
        XCTAssertEqual(restored.map(\.id), [usableID])
        XCTAssertEqual(restored.map(\.name), ["Usable"])
        XCTAssertEqual(active?.id, usableID)

        // The rewritten mirror no longer carries the entry that was dropped.
        let (_, reopened) = try makeMirroringStore(defaults: defaults)
        let reopenedCount = try await reopened.synchronizeProfileMirror()
        let reopenedProfiles = try await reopened.profiles()
        XCTAssertEqual(reopenedCount, 1)
        XCTAssertEqual(reopenedProfiles.map(\.id), [usableID])
    }

    func testStoreWithoutMirrorDefaultsNeverTouchesTheMirror() async throws {
        let defaults = try mirrorDefaults()
        let (_, unmirrored) = try makeStore()
        _ = try await unmirrored.createProfile(input(name: "Fixture"), now: date(10))

        let restoredCount = try await unmirrored.synchronizeProfileMirror()
        XCTAssertEqual(restoredCount, 0)
        XCTAssertNil(defaults.data(forKey: SourceProfileMirror.storageKey))
        XCTAssertNil(
            UserDefaults.standard.data(forKey: SourceProfileMirror.storageKey)
        )
    }

    private func assertEPGStagingCancellation(
        checkpoint: EPGStagingCheckpoint,
        replacementProgrammeCount: Int,
        expectedBatchOccurrences: Int,
        expectedReachedCheckpoints: [EPGStagingCheckpoint]? = nil,
        maximumCleanupDeletedModelCount: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "original", title: "Original")
        )
        let replacementURL = try temporaryXML(
            batchedXMLTV(programmeCount: replacementProgrammeCount)
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
        try await initialStore.recordSuccess(
            profileID: profile.id,
            resource: .epg,
            at: date(25)
        )
        let originalPointer = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let originalProfiles = try await initialStore.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first, file: file, line: line)
        let originalChannels = try await initialStore.epgChannels(profileID: profile.id)
        let originalProgrammes = try await initialStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        let cancellation = EPGStagingCancellationProbe(armingAt: checkpoint)
        let saveProbe = SaveOccurrenceFaultProbe()
        let contextProbe = SaveContextObservationProbe()
        let store = SwiftDataLibraryStore(
            modelContainer: container,
            epgCancellationCheck: {
                try Task.checkCancellation()
                try cancellation.check()
            },
            epgStagingCheckpoint: { cancellation.reach($0) },
            saveContextObserver: { contextProbe.record($0) }
        ) { phase in
            try saveProbe.record(phase)
        }

        let error = await XCTAssertThrowsErrorAsync({
            _ = try await store.installEPG(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(30)
            )
        }, file: file, line: line)

        XCTAssertTrue(error is CancellationError, file: file, line: line)
        XCTAssertEqual(cancellation.reachedCount, 1, file: file, line: line)
        XCTAssertEqual(
            cancellation.reachedCheckpoints,
            expectedReachedCheckpoints ?? [checkpoint],
            file: file,
            line: line
        )
        XCTAssertTrue(cancellation.didThrow, file: file, line: line)
        XCTAssertEqual(saveProbe.occurrence(of: .epgHeader), 1, file: file, line: line)
        XCTAssertEqual(
            saveProbe.occurrence(of: .epgBatch),
            expectedBatchOccurrences,
            file: file,
            line: line
        )
        XCTAssertEqual(saveProbe.occurrence(of: .epgStaging), 0, file: file, line: line)
        XCTAssertEqual(saveProbe.occurrence(of: .epgPointer), 0, file: file, line: line)
        XCTAssertEqual(saveProbe.occurrence(of: .epgCleanup), 1, file: file, line: line)
        if let maximumCleanupDeletedModelCount {
            let cleanupObservations = contextProbe.recorded.filter { $0.phase == .epgCleanup }
            XCTAssertEqual(cleanupObservations.count, 1, file: file, line: line)
            XCTAssertLessThanOrEqual(
                cleanupObservations.map(\.deletedModelCount).max() ?? 0,
                maximumCleanupDeletedModelCount,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            try snapshotPointers(container, profileID: profile.id).epg,
            originalPointer.epg,
            file: file,
            line: line
        )
        let profilesAfterFailure = try await store.profiles()
        let channelsAfterFailure = try await store.epgChannels(profileID: profile.id)
        let programmesAfterFailure = try await store.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(
            profilesAfterFailure.first?.epgStatus,
            originalProfile.epgStatus,
            file: file,
            line: line
        )
        XCTAssertEqual(channelsAfterFailure, originalChannels, file: file, line: line)
        XCTAssertEqual(programmesAfterFailure, originalProgrammes, file: file, line: line)
        assertInventory(
            try snapshotInventory(container),
            equals: originalInventory,
            file: file,
            line: line
        )
    }

    private func assertEPGStagingFailure(
        phase: LibraryStoreSavePhase,
        occurrence: Int,
        expectedBatchOccurrences: Int,
        expectedFinalOccurrences: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let container = try VPlayerModelContainer.make(inMemory: true)
        let initialStore = SwiftDataLibraryStore(modelContainer: container)
        let profile = try await initialStore.createProfile(input(name: "Home"), now: date(10))
        let originalURL = try temporaryXML(
            singleProgrammeXMLTV(channelID: "original", title: "Original")
        )
        let replacementURL = try temporaryXML(batchedXMLTV(programmeCount: 1_001))
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        _ = try await initialStore.installEPG(
            profileID: profile.id,
            fileURL: originalURL,
            fetchedAt: date(20)
        )
        try await initialStore.recordSuccess(
            profileID: profile.id,
            resource: .epg,
            at: date(25)
        )
        let originalPointer = try snapshotPointers(container, profileID: profile.id)
        let originalInventory = try snapshotInventory(container)
        let originalProfiles = try await initialStore.profiles()
        let originalProfile = try XCTUnwrap(originalProfiles.first, file: file, line: line)
        let originalChannels = try await initialStore.epgChannels(profileID: profile.id)
        let originalProgrammes = try await initialStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        let saveProbe = SaveOccurrenceFaultProbe(failures: [
            SaveOccurrenceFailure(
                phase: phase,
                occurrence: occurrence,
                error: .staging
            )
        ])
        let failingStore = SwiftDataLibraryStore(modelContainer: container) { actualPhase in
            try saveProbe.record(actualPhase)
        }

        let error = await XCTAssertThrowsErrorAsync({
            _ = try await failingStore.installEPG(
                profileID: profile.id,
                fileURL: replacementURL,
                fetchedAt: self.date(30)
            )
        }, file: file, line: line)

        XCTAssertEqual(error as? InjectedSaveError, .staging, file: file, line: line)
        XCTAssertEqual(saveProbe.occurrence(of: .epgHeader), 1, file: file, line: line)
        XCTAssertEqual(
            saveProbe.occurrence(of: .epgBatch),
            expectedBatchOccurrences,
            file: file,
            line: line
        )
        XCTAssertEqual(
            saveProbe.occurrence(of: .epgStaging),
            expectedFinalOccurrences,
            file: file,
            line: line
        )
        XCTAssertEqual(saveProbe.occurrence(of: .epgPointer), 0, file: file, line: line)
        XCTAssertEqual(saveProbe.occurrence(of: .epgCleanup), 1, file: file, line: line)
        XCTAssertEqual(
            try snapshotPointers(container, profileID: profile.id).epg,
            originalPointer.epg,
            file: file,
            line: line
        )
        let profilesAfterFailure = try await failingStore.profiles()
        XCTAssertEqual(
            profilesAfterFailure.first?.epgStatus,
            originalProfile.epgStatus,
            file: file,
            line: line
        )
        let channelsAfterFailure = try await failingStore.epgChannels(profileID: profile.id)
        let programmesAfterFailure = try await failingStore.programmes(
            profileID: profile.id,
            xmltvChannelID: "original",
            overlapping: date(0)..<date(2_000_000_000)
        )
        XCTAssertEqual(channelsAfterFailure, originalChannels, file: file, line: line)
        XCTAssertEqual(programmesAfterFailure, originalProgrammes, file: file, line: line)
        assertInventory(
            try snapshotInventory(container),
            equals: originalInventory,
            file: file,
            line: line
        )
    }

    private func makeStore() throws -> (ModelContainer, SwiftDataLibraryStore) {
        let container = try VPlayerModelContainer.make(inMemory: true)
        return (container, SwiftDataLibraryStore(modelContainer: container))
    }

    private func makeMirroringStore(
        defaults: UserDefaults
    ) throws -> (ModelContainer, SwiftDataLibraryStore) {
        let container = try VPlayerModelContainer.make(inMemory: true)
        return (
            container,
            SwiftDataLibraryStore(
                modelContainer: container,
                profileMirror: SourceProfileMirror(defaults: defaults)
            )
        )
    }

    /// A suite of its own per test, so the mirror never reads or writes the
    /// defaults the running simulator's app shares.
    private func mirrorDefaults() throws -> UserDefaults {
        let suiteName = "SwiftDataLibraryStoreTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

    private func editedInput(
        _ profile: SourceProfile,
        name: String? = nil,
        m3uURL: URL? = nil,
        epgURL: URL? = nil,
        m3uRefreshInterval: RefreshInterval? = nil,
        epgRefreshInterval: RefreshInterval? = nil
    ) throws -> ValidatedSourceProfileInput {
        try SourceProfileInput(
            name: name ?? profile.name,
            m3uURLString: (m3uURL ?? profile.m3uURL).absoluteString,
            epgURLString: (epgURL ?? profile.epgURL).absoluteString,
            m3uRefreshInterval: m3uRefreshInterval ?? profile.m3uRefreshInterval,
            epgRefreshInterval: epgRefreshInterval ?? profile.epgRefreshInterval
        ).validated()
    }

    private func seededRetargetFixture() async throws -> (
        container: ModelContainer,
        store: SwiftDataLibraryStore,
        profile: SourceProfile,
        playlistChannel: Channel
    ) {
        let (container, store) = try makeStore()
        let profile = try await store.createProfile(input(name: "Home"), now: date(10))
        let playlistChannel = channel(
            profileID: profile.id,
            name: "Stored playlist",
            path: "stored"
        )
        try await store.installPlaylist(
            profileID: profile.id,
            channels: [playlistChannel],
            fetchedAt: date(20)
        )
        let epgURL = try temporaryXML(singleProgrammeXMLTV(
            channelID: "guide",
            title: "Stored programme"
        ))
        defer { try? FileManager.default.removeItem(at: epgURL) }
        _ = try await store.installEPG(
            profileID: profile.id,
            fileURL: epgURL,
            fetchedAt: date(21)
        )
        try await store.setManualMapping(
            profileID: profile.id,
            channelID: playlistChannel.id,
            xmltvChannelID: "manual-guide"
        )
        let playlistAttemptID = UUID()
        try await store.recordAttempt(
            profileID: profile.id,
            resource: .playlist,
            at: date(30),
            attemptID: playlistAttemptID
        )
        try await store.recordSuccess(
            profileID: profile.id,
            resource: .playlist,
            at: date(31),
            attemptID: playlistAttemptID
        )
        let epgAttemptID = UUID()
        try await store.recordAttempt(
            profileID: profile.id,
            resource: .epg,
            at: date(40),
            attemptID: epgAttemptID
        )
        try await store.recordSuccess(
            profileID: profile.id,
            resource: .epg,
            at: date(41),
            attemptID: epgAttemptID
        )
        return (container, store, profile, playlistChannel)
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

private struct SaveOccurrenceFailure: Sendable {
    let phase: LibraryStoreSavePhase
    let occurrence: Int
    let error: InjectedSaveError
}

private final class SaveOccurrenceFaultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [SaveOccurrenceFailure]
    private var occurrences: [LibraryStoreSavePhase: Int] = [:]

    init(failures: [SaveOccurrenceFailure] = []) {
        self.failures = failures
    }

    func occurrence(of phase: LibraryStoreSavePhase) -> Int {
        lock.withLock { occurrences[phase, default: 0] }
    }

    func record(_ phase: LibraryStoreSavePhase) throws {
        let failure = lock.withLock { () -> SaveOccurrenceFailure? in
            occurrences[phase, default: 0] += 1
            let occurrence = occurrences[phase, default: 0]
            return failures.first {
                $0.phase == phase && $0.occurrence == occurrence
            }
        }
        if let failure {
            throw failure.error
        }
    }
}

private final class CancellationOccurrenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failingOccurrence: Int
    private var occurrence = 0

    init(failingAt occurrence: Int) {
        failingOccurrence = occurrence
    }

    func check() throws {
        let shouldFail = lock.withLock {
            occurrence += 1
            return occurrence == failingOccurrence
        }
        if shouldFail {
            throw CancellationError()
        }
    }
}

private final class EPGStagingCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let armingCheckpoint: EPGStagingCheckpoint
    private var armed = false
    private var checkpointOccurrences = 0
    private var checkpoints: [EPGStagingCheckpoint] = []
    private var threw = false

    init(armingAt checkpoint: EPGStagingCheckpoint) {
        armingCheckpoint = checkpoint
    }

    var reachedCount: Int {
        lock.withLock { checkpointOccurrences }
    }

    var didThrow: Bool {
        lock.withLock { threw }
    }

    var reachedCheckpoints: [EPGStagingCheckpoint] {
        lock.withLock { checkpoints }
    }

    func reach(_ checkpoint: EPGStagingCheckpoint) {
        lock.withLock {
            checkpoints.append(checkpoint)
            guard checkpoint == armingCheckpoint else { return }
            checkpointOccurrences += 1
            armed = true
        }
    }

    func check() throws {
        let shouldThrow = lock.withLock {
            guard armed else { return false }
            threw = true
            return true
        }
        if shouldThrow {
            throw CancellationError()
        }
    }
}

private final class SaveContextObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [LibraryStoreSaveContextObservation] = []

    var recorded: [LibraryStoreSaveContextObservation] {
        lock.withLock { observations }
    }

    func record(_ observation: LibraryStoreSaveContextObservation) {
        lock.withLock { observations.append(observation) }
    }
}

private final class EPGBatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [EPGPersistenceBatch] = []

    var recorded: [EPGPersistenceBatch] {
        lock.withLock { batches }
    }

    func persist(_ batch: EPGPersistenceBatch) {
        lock.withLock { batches.append(batch) }
    }
}

private enum InjectedSaveError: Error, Equatable, Sendable {
    case expected
    case staging
    case cleanup
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
