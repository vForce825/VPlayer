// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

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

        await XCTAssertThrowsErrorAsync {
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

        await XCTAssertThrowsErrorAsync {
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
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
