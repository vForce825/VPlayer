// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public protocol LibraryRepository: Sendable {
    func profiles() async throws -> [SourceProfile]
    func activeProfile() async throws -> SourceProfile?
    func createProfile(_ input: ValidatedSourceProfileInput, now: Date) async throws -> SourceProfile
    func updateProfile(id: UUID, input: ValidatedSourceProfileInput, now: Date) async throws
    func deleteProfile(id: UUID) async throws
    func setActiveProfile(id: UUID) async throws
    func channels(profileID: UUID) async throws -> [Channel]
    func epgChannels(profileID: UUID) async throws -> [EPGChannel]
    func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) async throws -> [Programme]
    func manualMapping(profileID: UUID, channelID: String) async throws -> ManualEPGMapping?
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

/// Commits a refresh snapshot and its successful resource status as one repository transaction.
public protocol RefreshSnapshotCommitting: Sendable {
    func commitPlaylistRefresh(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date,
        attemptID: UUID?
    ) async throws
    func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date,
        attemptID: UUID?
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

public extension RefreshSnapshotCommitting {
    func commitPlaylistRefresh(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date
    ) async throws {
        try await commitPlaylistRefresh(
            profileID: profileID,
            channels: channels,
            fetchedAt: fetchedAt,
            attemptID: nil
        )
    }

    func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) async throws -> XMLTVParseSummary {
        try await commitEPGRefresh(
            profileID: profileID,
            fileURL: fileURL,
            fetchedAt: fetchedAt,
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
}
