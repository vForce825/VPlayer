// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct RefreshSourceContext: Hashable, Sendable {
    public let source: SourceURLIdentity
    public let attemptID: UUID

    public init(source: SourceURLIdentity, attemptID: UUID) {
        self.source = source
        self.attemptID = attemptID
    }
}

public protocol LibraryRepository: Sendable {
    func profiles() async throws -> [SourceProfile]
    func activeProfile() async throws -> SourceProfile?
    func createProfile(_ input: ValidatedSourceProfileInput, now: Date) async throws -> SourceProfile
    func updateProfile(id: UUID, input: ValidatedSourceProfileInput, now: Date) async throws
    func deleteProfile(id: UUID) async throws
    func setActiveProfile(id: UUID) async throws
    func channels(profileID: UUID) async throws -> [Channel]
    func epgChannels(profileID: UUID) async throws -> [EPGChannel]
    func epgProgrammeCount(profileID: UUID) async throws -> Int
    /// Latest `stop` across the profile's stored EPG, or nil when it holds no
    /// programmes. Lets callers tell an EPG that imported cleanly but only
    /// covers days that already passed from one that was never fetched.
    func epgCoverageEnd(profileID: UUID) async throws -> Date?
    func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) async throws -> [Programme]
    func manualMapping(profileID: UUID, channelID: String) async throws -> ManualEPGMapping?
    /// All manual channel→XMLTV overrides for a profile, keyed by channel id.
    /// Batched so a library reload issues one query instead of one per channel.
    func manualMappings(profileID: UUID) async throws -> [String: String]
    /// Programmes overlapping `overlapping` for the given XMLTV channel ids,
    /// grouped by XMLTV channel id. Batched to avoid a per-channel query fan-out.
    func programmes(
        profileID: UUID,
        xmltvChannelIDs: Set<String>,
        overlapping: Range<Date>
    ) async throws -> [String: [Programme]]
    func setManualMapping(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) async throws
    /// Persists only when the profile is active and the channel belongs to its current playlist snapshot.
    func setManualMappingIfCurrentChannel(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) async throws -> Bool
    func installPlaylist(profileID: UUID, channels: [Channel], fetchedAt: Date) async throws
    func installEPG(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) async throws -> XMLTVParseSummary
    func recordAttempt(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) async throws
    func recordSuccess(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) async throws
    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date,
        attemptID: UUID?
    ) async throws
    func purgeUnreferencedSnapshots() async throws
}

public protocol ConditionalRefreshStatusWriting: Sendable {
    func beginRefresh(
        profileID: UUID,
        resource: RefreshResource,
        context: RefreshSourceContext,
        at: Date
    ) async throws -> Bool

    func recordRefreshFailure(
        profileID: UUID,
        resource: RefreshResource,
        context: RefreshSourceContext,
        summary: String,
        at: Date
    ) async throws -> Bool
}

/// Commits a refresh snapshot and its successful resource status as one repository transaction.
public protocol RefreshSnapshotCommitting: Sendable {
    func commitPlaylistRefresh(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date,
        context: RefreshSourceContext
    ) async throws
    func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date,
        context: RefreshSourceContext
    ) async throws -> XMLTVParseSummary
}

public extension LibraryRepository {
    func recordAttempt(
        profileID: UUID,
        resource: RefreshResource,
        at: Date
    ) async throws {
        try await recordAttempt(
            profileID: profileID,
            resource: resource,
            at: at,
            attemptID: nil
        )
    }

    func recordSuccess(
        profileID: UUID,
        resource: RefreshResource,
        at: Date
    ) async throws {
        try await recordSuccess(
            profileID: profileID,
            resource: resource,
            at: at,
            attemptID: nil
        )
    }

    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date
    ) async throws {
        try await recordFailure(
            profileID: profileID,
            resource: resource,
            summary: summary,
            at: at,
            attemptID: nil
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable, Sendable {
    case profileNotFound
    case invalidChannelProfile
    case duplicatePlaylistChannel
    case epgHasNoChannels
    case corruptPersistedValue
    case sourceConfigurationChanged
}
