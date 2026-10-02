// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum CommittedLibraryChange: Equatable, Sendable {
    case full
    case refreshes([UUID: Set<RefreshResource>])
}

/// A small, immutable value boundary for observing the library. Snapshot payload
/// rows are immutable after publication, so only their committed profile pointers
/// need observation. Never retain every channel or programme merely to invalidate
/// a query. Comparing complete metadata values makes bufferingNewest(1) lossless
/// for the consumer's eventual reload, including overlapping refresh resources.
public struct CommittedLibrarySnapshot: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        let name: String
        let playlistURL: String
        let epgURL: String
        let playlistInterval: Int
        let epgInterval: Int
        let createdAt: Date
    }

    struct Resource: Equatable, Sendable {
        let snapshotID: UUID?
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
        let state: String
        let errorSummary: String?
        let attemptID: UUID?
    }

    struct Profile: Equatable, Sendable {
        let configuration: Configuration
        let playlist: Resource
        let epg: Resource
        let updatedAt: Date

        init(_ record: SourceProfileRecord) {
            configuration = Configuration(
                name: record.name,
                playlistURL: record.m3uURLString,
                epgURL: record.epgURLString,
                playlistInterval: record.m3uRefreshIntervalRaw,
                epgInterval: record.epgRefreshIntervalRaw,
                createdAt: record.createdAt
            )
            playlist = Resource(
                snapshotID: record.playlistSnapshotID,
                lastAttemptAt: record.m3uLastAttemptAt,
                lastSuccessAt: record.m3uLastSuccessAt,
                state: record.m3uStateRaw,
                errorSummary: record.m3uErrorSummary,
                attemptID: record.m3uAttemptID
            )
            epg = Resource(
                snapshotID: record.epgSnapshotID,
                lastAttemptAt: record.epgLastAttemptAt,
                lastSuccessAt: record.epgLastSuccessAt,
                state: record.epgStateRaw,
                errorSummary: record.epgErrorSummary,
                attemptID: record.epgAttemptID
            )
            updatedAt = record.updatedAt
        }
    }

    struct State: Equatable, Sendable {
        let activeProfileID: UUID?
    }

    struct MappingKey: Hashable, Sendable {
        let profileID: UUID
        let channelID: String
    }

    let profiles: [UUID: Profile]
    let states: [String: State]
    let mappings: [MappingKey: String]

    public func change(since previous: Self) -> CommittedLibraryChange? {
        guard states == previous.states,
              mappings == previous.mappings,
              Set(profiles.keys) == Set(previous.profiles.keys) else { return .full }
        var resources: [UUID: Set<RefreshResource>] = [:]
        for (id, profile) in profiles {
            guard let old = previous.profiles[id],
                  profile.configuration == old.configuration else { return .full }
            var changed: Set<RefreshResource> = []
            if profile.playlist != old.playlist { changed.insert(.playlist) }
            if profile.epg != old.epg { changed.insert(.epg) }
            // Refresh status writes also update updatedAt. Treating that timestamp
            // as a configuration edit would bypass in-flight refresh claims.
            if changed.isEmpty, profile.updatedAt != old.updatedAt {
                changed = [.playlist, .epg]
            }
            if !changed.isEmpty { resources[id] = changed }
        }
        return resources.isEmpty ? nil : .refreshes(resources)
    }
}
