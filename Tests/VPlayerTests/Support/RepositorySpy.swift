// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
@testable import VPlayerCore

actor RepositorySpy: LibraryRepository, RefreshSnapshotCommitting {
    enum InjectedError: Error, Sendable {
        case refreshCommit
        case recordFailure
    }

    enum Event: Equatable, Sendable {
        case installPlaylist(UUID)
        case installEPG(UUID)
        case attempt(UUID, RefreshResource)
        case success(UUID, RefreshResource)
        case failure(UUID, RefreshResource, String)
    }

    struct Snapshot: Sendable {
        struct ProgrammeRequest: Equatable, Sendable {
            let profileID: UUID
            let xmltvChannelID: String
            let overlapping: Range<Date>
        }

        let profiles: [SourceProfile]
        let activeProfileID: UUID?
        let channels: [UUID: [Channel]]
        let epgChannels: [UUID: [EPGChannel]]
        let programmes: [UUID: [Programme]]
        let manualMappings: [UUID: [String: String]]
        let programmeRequests: [ProgrammeRequest]
        let events: [Event]
        let profileLookupCount: Int
        let playlistInstallCount: Int
        let epgInstallCount: Int
    }

    private var storedProfiles: [SourceProfile]
    private var storedActiveProfileID: UUID?
    private var storedChannels: [UUID: [Channel]]
    private var storedEPGChannels: [UUID: [EPGChannel]]
    private var storedProgrammes: [UUID: [Programme]]
    private var storedManualMappings: [UUID: [String: String]]
    private var programmeRequests: [Snapshot.ProgrammeRequest] = []
    private var recordedEvents: [Event] = []
    private var profileLookupCount = 0
    private var playlistInstallCount = 0
    private var epgInstallCount = 0
    private let failedRefreshCommits: Set<RefreshResource>
    private let failsRecordFailure: Bool

    init(
        profiles: [SourceProfile],
        activeProfileID: UUID? = nil,
        channels: [UUID: [Channel]] = [:],
        epgChannels: [UUID: [EPGChannel]] = [:],
        programmes: [UUID: [Programme]] = [:],
        manualMappings: [UUID: [String: String]] = [:],
        failedRefreshCommits: Set<RefreshResource> = [],
        failsRecordFailure: Bool = false
    ) {
        storedProfiles = profiles
        storedActiveProfileID = activeProfileID ?? profiles.first?.id
        storedChannels = channels
        storedEPGChannels = epgChannels
        storedProgrammes = programmes
        storedManualMappings = manualMappings
        self.failedRefreshCommits = failedRefreshCommits
        self.failsRecordFailure = failsRecordFailure
    }

    func snapshot() -> Snapshot {
        Snapshot(
            profiles: storedProfiles,
            activeProfileID: storedActiveProfileID,
            channels: storedChannels,
            epgChannels: storedEPGChannels,
            programmes: storedProgrammes,
            manualMappings: storedManualMappings,
            programmeRequests: programmeRequests,
            events: recordedEvents,
            profileLookupCount: profileLookupCount,
            playlistInstallCount: playlistInstallCount,
            epgInstallCount: epgInstallCount
        )
    }

    func profiles() throws -> [SourceProfile] {
        profileLookupCount += 1
        return storedProfiles
    }

    func activeProfile() throws -> SourceProfile? {
        guard let storedActiveProfileID else { return nil }
        return storedProfiles.first { $0.id == storedActiveProfileID }
    }

    func createProfile(_ input: ValidatedSourceProfileInput, now: Date) throws -> SourceProfile {
        let profile = SourceProfile(
            id: UUID(),
            name: input.name,
            m3uURL: input.m3uURL,
            epgURL: input.epgURL,
            m3uRefreshInterval: input.m3uRefreshInterval,
            epgRefreshInterval: input.epgRefreshInterval,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
        storedProfiles.append(profile)
        if storedActiveProfileID == nil {
            storedActiveProfileID = profile.id
        }
        return profile
    }

    func updateProfile(id: UUID, input: ValidatedSourceProfileInput, now: Date) throws {
        let index = try profileIndex(id)
        storedProfiles[index].name = input.name
        storedProfiles[index].m3uURL = input.m3uURL
        storedProfiles[index].epgURL = input.epgURL
        storedProfiles[index].m3uRefreshInterval = input.m3uRefreshInterval
        storedProfiles[index].epgRefreshInterval = input.epgRefreshInterval
        storedProfiles[index].updatedAt = now
    }

    func deleteProfile(id: UUID) throws {
        _ = try profileIndex(id)
        storedProfiles.removeAll { $0.id == id }
        storedChannels[id] = nil
        storedEPGChannels[id] = nil
        storedProgrammes[id] = nil
        storedManualMappings[id] = nil
        if storedActiveProfileID == id {
            storedActiveProfileID = storedProfiles.first?.id
        }
    }

    func setActiveProfile(id: UUID) throws {
        _ = try profileIndex(id)
        storedActiveProfileID = id
    }

    func channels(profileID: UUID) throws -> [Channel] {
        _ = try profileIndex(profileID)
        return storedChannels[profileID, default: []]
    }

    func epgChannels(profileID: UUID) throws -> [EPGChannel] {
        _ = try profileIndex(profileID)
        return storedEPGChannels[profileID, default: []]
    }

    func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) throws -> [Programme] {
        _ = try profileIndex(profileID)
        programmeRequests.append(Snapshot.ProgrammeRequest(
            profileID: profileID,
            xmltvChannelID: xmltvChannelID,
            overlapping: overlapping
        ))
        return storedProgrammes[profileID, default: []].filter {
            $0.xmltvChannelID == xmltvChannelID
                && $0.start < overlapping.upperBound
                && $0.stop > overlapping.lowerBound
        }
    }

    func manualMapping(profileID: UUID, channelID: String) throws -> ManualEPGMapping? {
        _ = try profileIndex(profileID)
        return storedManualMappings[profileID]?[channelID].map {
            ManualEPGMapping(
                sourceProfileID: profileID,
                channelID: channelID,
                xmltvChannelID: $0
            )
        }
    }

    func setManualMapping(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) throws {
        _ = try profileIndex(profileID)
        storedManualMappings[profileID, default: [:]][channelID] = xmltvChannelID
    }

    func installPlaylist(profileID: UUID, channels: [Channel], fetchedAt: Date) throws {
        _ = try profileIndex(profileID)
        guard channels.allSatisfy({ $0.sourceProfileID == profileID }) else {
            throw LibraryRepositoryError.invalidChannelProfile
        }
        storedChannels[profileID] = channels
        playlistInstallCount += 1
        recordedEvents.append(.installPlaylist(profileID))
    }

    func installEPG(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) throws -> XMLTVParseSummary {
        _ = try profileIndex(profileID)
        let sink = InMemoryXMLTVSink()
        let summary = try XMLTVParser().parse(fileURL: fileURL, into: sink)
        guard !sink.channels.isEmpty else { throw LibraryRepositoryError.epgHasNoChannels }
        storedEPGChannels[profileID] = sink.channels
        storedProgrammes[profileID] = sink.programmes
        epgInstallCount += 1
        recordedEvents.append(.installEPG(profileID))
        return summary
    }

    func commitPlaylistRefresh(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date
    ) throws {
        guard !failedRefreshCommits.contains(.playlist) else {
            throw InjectedError.refreshCommit
        }
        try installPlaylist(profileID: profileID, channels: channels, fetchedAt: fetchedAt)
        try recordSuccess(profileID: profileID, resource: .playlist, at: fetchedAt)
    }

    func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) throws -> XMLTVParseSummary {
        guard !failedRefreshCommits.contains(.epg) else {
            throw InjectedError.refreshCommit
        }
        let summary = try installEPG(
            profileID: profileID,
            fileURL: fileURL,
            fetchedAt: fetchedAt
        )
        try recordSuccess(profileID: profileID, resource: .epg, at: fetchedAt)
        return summary
    }

    func recordAttempt(profileID: UUID, resource: RefreshResource, at: Date) throws {
        let index = try profileIndex(profileID)
        updateStatus(index: index, resource: resource) { status in
            status.lastAttemptAt = at
            status.state = .refreshing
            status.errorSummary = nil
        }
        recordedEvents.append(.attempt(profileID, resource))
    }

    func recordSuccess(profileID: UUID, resource: RefreshResource, at: Date) throws {
        guard !failedRefreshCommits.contains(resource) else {
            throw InjectedError.refreshCommit
        }
        let index = try profileIndex(profileID)
        updateStatus(index: index, resource: resource) { status in
            status.lastSuccessAt = at
            status.state = .succeeded
            status.errorSummary = nil
        }
        recordedEvents.append(.success(profileID, resource))
    }

    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date
    ) throws {
        guard !failsRecordFailure else { throw InjectedError.recordFailure }
        let index = try profileIndex(profileID)
        let sanitized = String(summary.prefix(240))
        updateStatus(index: index, resource: resource) { status in
            status.state = .failed
            status.errorSummary = sanitized
        }
        recordedEvents.append(.failure(profileID, resource, sanitized))
    }

    func purgeUnreferencedSnapshots() throws {}

    private func profileIndex(_ id: UUID) throws -> Int {
        guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
            throw LibraryRepositoryError.profileNotFound
        }
        return index
    }

    private func updateStatus(
        index: Int,
        resource: RefreshResource,
        update: (inout ResourceRefreshStatus) -> Void
    ) {
        switch resource {
        case .playlist:
            update(&storedProfiles[index].m3uStatus)
        case .epg:
            update(&storedProfiles[index].epgStatus)
        }
    }
}

private final class InMemoryXMLTVSink: XMLTVEventSink {
    private(set) var channels: [EPGChannel] = []
    private(set) var programmes: [Programme] = []

    func accept(channel: EPGChannel) throws {
        channels.append(channel)
    }

    func accept(programme: Programme) throws {
        programmes.append(programme)
    }
}
