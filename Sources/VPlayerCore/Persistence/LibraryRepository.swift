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
    func installPlaylist(profileID: UUID, channels: [Channel], fetchedAt: Date) async throws
    func installEPG(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) async throws -> XMLTVParseSummary
    func recordAttempt(profileID: UUID, resource: RefreshResource, at: Date) async throws
    func recordSuccess(profileID: UUID, resource: RefreshResource, at: Date) async throws
    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date
    ) async throws
    func purgeUnreferencedSnapshots() async throws
}

public enum LibraryRepositoryError: Error, Equatable, Sendable {
    case profileNotFound
    case invalidChannelProfile
    case duplicatePlaylistChannel
    case epgHasNoChannels
    case corruptPersistedValue
}
