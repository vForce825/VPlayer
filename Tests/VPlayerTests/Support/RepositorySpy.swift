// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
@testable import VPlayerCore

actor RepositorySpy: LibraryRepository, RefreshSnapshotCommitting {
    enum InjectedError: Error, Sendable {
        case setActiveProfile
        case deleteProfile
        case refreshCommit
        case recordAttempt
        case recordFailure
        case read
    }

    enum Event: Equatable, Sendable {
        case installPlaylist(UUID)
        case installEPG(UUID)
        case attempt(UUID, RefreshResource)
        case success(UUID, RefreshResource)
        case failure(UUID, RefreshResource, String)
    }

    enum OperationEvent: Equatable, Sendable {
        case channelReadReleased
        case activationStarted(UUID)
        case deletionStarted(UUID)
    }

    struct Snapshot: Sendable {
        struct ProgrammeRequest: Equatable, Sendable {
            let profileID: UUID
            let xmltvChannelID: String
            let overlapping: Range<Date>
        }

        struct ProgrammeBatchRequest: Equatable, Sendable {
            let profileID: UUID
            let xmltvChannelIDs: [String]
            let overlapping: Range<Date>
        }

        let profiles: [SourceProfile]
        let activeProfileID: UUID?
        let channels: [UUID: [Channel]]
        let epgChannels: [UUID: [EPGChannel]]
        let programmes: [UUID: [Programme]]
        let manualMappings: [UUID: [String: String]]
        let programmeRequests: [ProgrammeRequest]
        let programmeBatchRequests: [ProgrammeBatchRequest]
        let events: [Event]
        let profileLookupCount: Int
        let playlistInstallCount: Int
        let epgInstallCount: Int
        let profileCreateCount: Int
        let profileUpdateCount: Int
        let profileReadPlaylistStates: [RefreshState]
        let operationEvents: [OperationEvent]
    }

    private var storedProfiles: [SourceProfile]
    private var storedActiveProfileID: UUID?
    private var storedChannels: [UUID: [Channel]]
    private var storedEPGChannels: [UUID: [EPGChannel]]
    private var storedProgrammes: [UUID: [Programme]]
    private var storedManualMappings: [UUID: [String: String]]
    private var programmeRequests: [Snapshot.ProgrammeRequest] = []
    private var programmeBatchRequests: [Snapshot.ProgrammeBatchRequest] = []
    private var recordedEvents: [Event] = []
    private var profileLookupCount = 0
    private var playlistInstallCount = 0
    private var epgInstallCount = 0
    private var profileCreateCount = 0
    private var profileUpdateCount = 0
    private var profileReadPlaylistStates: [RefreshState] = []
    private var operationEvents: [OperationEvent] = []
    private var failsReads = false
    private var shouldGateNextChannelRead = false
    private var blockedChannelReadContinuation: CheckedContinuation<Void, Never>?
    private var channelReadReleaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldGateNextActivation = false
    private var shouldFailNextActivation = false
    private var blockedActivationContinuation: CheckedContinuation<Void, Never>?
    private var activationReleaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldFailNextDeletion = false
    private var shouldGateNextDeletion = false
    private var blockedDeletionContinuation: CheckedContinuation<Void, Never>?
    private var deletionReleaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldGateNextProfileRead = false
    private var blockedProfileReadContinuation: CheckedContinuation<Void, Never>?
    private var profileReadReleaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldGateNextCreate = false
    private var blockedCreateContinuation: CheckedContinuation<Void, Never>?
    private var createReleaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldGateNextMappingWrite = false
    private var blockedMappingWriteContinuation: CheckedContinuation<Void, Never>?
    private var mappingWriteReleaseContinuation: CheckedContinuation<Void, Never>?
    private let failedRefreshCommits: Set<RefreshResource>
    private var failsRecordAttempt: Bool
    private var failsRecordFailure: Bool

    init(
        profiles: [SourceProfile],
        activeProfileID: UUID? = nil,
        channels: [UUID: [Channel]] = [:],
        epgChannels: [UUID: [EPGChannel]] = [:],
        programmes: [UUID: [Programme]] = [:],
        manualMappings: [UUID: [String: String]] = [:],
        failedRefreshCommits: Set<RefreshResource> = [],
        failsRecordAttempt: Bool = false,
        failsRecordFailure: Bool = false
    ) {
        storedProfiles = profiles
        storedActiveProfileID = activeProfileID ?? profiles.first?.id
        storedChannels = channels
        storedEPGChannels = epgChannels
        storedProgrammes = programmes
        storedManualMappings = manualMappings
        self.failedRefreshCommits = failedRefreshCommits
        self.failsRecordAttempt = failsRecordAttempt
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
            programmeBatchRequests: programmeBatchRequests,
            events: recordedEvents,
            profileLookupCount: profileLookupCount,
            playlistInstallCount: playlistInstallCount,
            epgInstallCount: epgInstallCount,
            profileCreateCount: profileCreateCount,
            profileUpdateCount: profileUpdateCount,
            profileReadPlaylistStates: profileReadPlaylistStates,
            operationEvents: operationEvents
        )
    }

    func setReadFailure(_ enabled: Bool) {
        failsReads = enabled
    }

    func setRefreshPersistenceFaults(
        recordAttempt: Bool,
        recordFailure: Bool
    ) {
        failsRecordAttempt = recordAttempt
        failsRecordFailure = recordFailure
    }

    func replaceChannels(profileID: UUID, channels: [Channel]) {
        storedChannels[profileID] = channels
    }

    func replaceProgrammes(_ programmes: [Programme], profileID: UUID) {
        storedProgrammes[profileID] = programmes
    }

    func replaceProfiles(_ profiles: [SourceProfile], activeProfileID: UUID?) {
        storedProfiles = profiles
        storedActiveProfileID = activeProfileID
    }

    func gateNextChannelRead() {
        shouldGateNextChannelRead = true
    }

    func gateNextProfileRead() {
        shouldGateNextProfileRead = true
    }

    func waitUntilProfileReadIsBlocked() async {
        if profileReadReleaseContinuation != nil { return }
        guard shouldGateNextProfileRead else { return }
        await withCheckedContinuation { continuation in
            blockedProfileReadContinuation = continuation
        }
    }

    func releaseProfileRead() {
        profileReadReleaseContinuation?.resume()
        profileReadReleaseContinuation = nil
    }

    func gateNextCreate() {
        shouldGateNextCreate = true
    }

    func waitUntilCreateIsBlocked() async {
        if createReleaseContinuation != nil { return }
        guard shouldGateNextCreate else { return }
        await withCheckedContinuation { continuation in
            blockedCreateContinuation = continuation
        }
    }

    func releaseCreate() {
        createReleaseContinuation?.resume()
        createReleaseContinuation = nil
    }

    func gateNextMappingWrite() {
        shouldGateNextMappingWrite = true
    }

    func waitUntilMappingWriteIsBlocked() async {
        if mappingWriteReleaseContinuation != nil { return }
        guard shouldGateNextMappingWrite else { return }
        await withCheckedContinuation { continuation in
            blockedMappingWriteContinuation = continuation
        }
    }

    func releaseMappingWrite() {
        mappingWriteReleaseContinuation?.resume()
        mappingWriteReleaseContinuation = nil
    }

    func waitUntilChannelReadIsBlocked() async {
        if channelReadReleaseContinuation != nil { return }
        guard shouldGateNextChannelRead else { return }
        await withCheckedContinuation { continuation in
            blockedChannelReadContinuation = continuation
        }
    }

    func releaseChannelRead() {
        operationEvents.append(.channelReadReleased)
        channelReadReleaseContinuation?.resume()
        channelReadReleaseContinuation = nil
    }

    func gateNextActivation() {
        shouldGateNextActivation = true
    }

    func failNextActivation() {
        shouldFailNextActivation = true
    }

    func failNextDeletion() {
        shouldFailNextDeletion = true
    }

    func gateNextDeletion() {
        shouldGateNextDeletion = true
    }

    func waitUntilDeletionIsBlocked() async {
        if deletionReleaseContinuation != nil { return }
        guard shouldGateNextDeletion else { return }
        await withCheckedContinuation { continuation in
            blockedDeletionContinuation = continuation
        }
    }

    func releaseDeletion() {
        deletionReleaseContinuation?.resume()
        deletionReleaseContinuation = nil
    }

    func waitUntilActivationIsBlocked() async {
        if activationReleaseContinuation != nil { return }
        guard shouldGateNextActivation else { return }
        await withCheckedContinuation { continuation in
            blockedActivationContinuation = continuation
        }
    }

    func releaseActivation() {
        activationReleaseContinuation?.resume()
        activationReleaseContinuation = nil
    }

    func profiles() async throws -> [SourceProfile] {
        if failsReads { throw InjectedError.read }
        profileLookupCount += 1
        profileReadPlaylistStates.append(contentsOf: storedProfiles.map(\.m3uStatus.state))
        if shouldGateNextProfileRead {
            shouldGateNextProfileRead = false
            blockedProfileReadContinuation?.resume()
            blockedProfileReadContinuation = nil
            await withCheckedContinuation { continuation in
                profileReadReleaseContinuation = continuation
            }
        }
        return storedProfiles
    }

    func activeProfile() throws -> SourceProfile? {
        if failsReads { throw InjectedError.read }
        guard let storedActiveProfileID else { return nil }
        return storedProfiles.first { $0.id == storedActiveProfileID }
    }

    func createProfile(_ input: ValidatedSourceProfileInput, now: Date) async throws -> SourceProfile {
        if shouldGateNextCreate {
            shouldGateNextCreate = false
            blockedCreateContinuation?.resume()
            blockedCreateContinuation = nil
            await withCheckedContinuation { continuation in
                createReleaseContinuation = continuation
            }
        }
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
        profileCreateCount += 1
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
        profileUpdateCount += 1
    }

    func deleteProfile(id: UUID) async throws {
        operationEvents.append(.deletionStarted(id))
        if shouldGateNextDeletion {
            shouldGateNextDeletion = false
            blockedDeletionContinuation?.resume()
            blockedDeletionContinuation = nil
            await withCheckedContinuation { continuation in
                deletionReleaseContinuation = continuation
            }
        }
        if shouldFailNextDeletion {
            shouldFailNextDeletion = false
            throw InjectedError.deleteProfile
        }
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

    func setActiveProfile(id: UUID) async throws {
        _ = try profileIndex(id)
        operationEvents.append(.activationStarted(id))
        let shouldFail = shouldFailNextActivation
        shouldFailNextActivation = false
        if shouldGateNextActivation {
            shouldGateNextActivation = false
            blockedActivationContinuation?.resume()
            blockedActivationContinuation = nil
            await withCheckedContinuation { continuation in
                activationReleaseContinuation = continuation
            }
        }
        if shouldFail {
            throw InjectedError.setActiveProfile
        }
        storedActiveProfileID = id
    }

    func channels(profileID: UUID) async throws -> [Channel] {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        let result = storedChannels[profileID, default: []]
        if shouldGateNextChannelRead {
            shouldGateNextChannelRead = false
            blockedChannelReadContinuation?.resume()
            blockedChannelReadContinuation = nil
            await withCheckedContinuation { continuation in
                channelReadReleaseContinuation = continuation
            }
        }
        return result
    }

    func epgChannels(profileID: UUID) throws -> [EPGChannel] {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        return storedEPGChannels[profileID, default: []]
    }

    func epgProgrammeCount(profileID: UUID) async throws -> Int {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        return storedProgrammes[profileID, default: []].count
    }

    func epgCoverageEnd(profileID: UUID) async throws -> Date? {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        return storedProgrammes[profileID, default: []].map(\.stop).max()
    }

    func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) throws -> [Programme] {
        if failsReads { throw InjectedError.read }
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
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        return storedManualMappings[profileID]?[channelID].map {
            ManualEPGMapping(
                sourceProfileID: profileID,
                channelID: channelID,
                xmltvChannelID: $0
            )
        }
    }

    func manualMappings(profileID: UUID) throws -> [String: String] {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        return storedManualMappings[profileID, default: [:]]
    }

    func programmes(
        profileID: UUID,
        xmltvChannelIDs: Set<String>,
        overlapping: Range<Date>
    ) throws -> [String: [Programme]] {
        if failsReads { throw InjectedError.read }
        _ = try profileIndex(profileID)
        programmeBatchRequests.append(Snapshot.ProgrammeBatchRequest(
            profileID: profileID,
            xmltvChannelIDs: xmltvChannelIDs.sorted(),
            overlapping: overlapping
        ))
        guard !xmltvChannelIDs.isEmpty else { return [:] }
        var result: [String: [Programme]] = [:]
        for programme in storedProgrammes[profileID, default: []]
        where xmltvChannelIDs.contains(programme.xmltvChannelID)
            && programme.start < overlapping.upperBound
            && programme.stop > overlapping.lowerBound {
            result[programme.xmltvChannelID, default: []].append(programme)
        }
        return result
    }

    func setManualMapping(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) async throws {
        await waitAtMappingWriteGateIfNeeded()
        _ = try profileIndex(profileID)
        storedManualMappings[profileID, default: [:]][channelID] = xmltvChannelID
    }

    func setManualMappingIfCurrentChannel(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) async throws -> Bool {
        await waitAtMappingWriteGateIfNeeded()
        _ = try profileIndex(profileID)
        guard storedActiveProfileID == profileID,
              storedChannels[profileID, default: []].contains(where: {
                  $0.id == channelID && $0.sourceProfileID == profileID
              }) else {
            return false
        }
        storedManualMappings[profileID, default: [:]][channelID] = xmltvChannelID
        return true
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
        fetchedAt: Date,
        attemptID: UUID?
    ) throws {
        guard !failedRefreshCommits.contains(.playlist) else {
            throw InjectedError.refreshCommit
        }
        try installPlaylist(profileID: profileID, channels: channels, fetchedAt: fetchedAt)
        try recordSuccess(
            profileID: profileID,
            resource: .playlist,
            at: fetchedAt,
            attemptID: attemptID
        )
    }

    func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date,
        attemptID: UUID?
    ) throws -> XMLTVParseSummary {
        guard !failedRefreshCommits.contains(.epg) else {
            throw InjectedError.refreshCommit
        }
        let summary = try installEPG(
            profileID: profileID,
            fileURL: fileURL,
            fetchedAt: fetchedAt
        )
        try recordSuccess(
            profileID: profileID,
            resource: .epg,
            at: fetchedAt,
            attemptID: attemptID
        )
        return summary
    }

    func recordAttempt(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        guard !failsRecordAttempt else { throw InjectedError.recordAttempt }
        let index = try profileIndex(profileID)
        updateStatus(index: index, resource: resource) { status in
            status.lastAttemptAt = at
            status.state = .refreshing
            status.errorSummary = nil
            status.attemptID = attemptID
        }
        recordedEvents.append(.attempt(profileID, resource))
    }

    func recordSuccess(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        guard !failedRefreshCommits.contains(resource) else {
            throw InjectedError.refreshCommit
        }
        let index = try profileIndex(profileID)
        updateStatus(index: index, resource: resource) { status in
            status.lastSuccessAt = at
            status.state = .succeeded
            status.errorSummary = nil
            status.attemptID = attemptID
        }
        recordedEvents.append(.success(profileID, resource))
    }

    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date,
        attemptID: UUID?
    ) throws {
        guard !failsRecordFailure else { throw InjectedError.recordFailure }
        let index = try profileIndex(profileID)
        let sanitized = String(summary.prefix(240))
        updateStatus(index: index, resource: resource) { status in
            status.state = .failed
            status.errorSummary = sanitized
            status.attemptID = attemptID
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

    private func waitAtMappingWriteGateIfNeeded() async {
        guard shouldGateNextMappingWrite else { return }
        shouldGateNextMappingWrite = false
        blockedMappingWriteContinuation?.resume()
        blockedMappingWriteContinuation = nil
        await withCheckedContinuation { continuation in
            mappingWriteReleaseContinuation = continuation
        }
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
