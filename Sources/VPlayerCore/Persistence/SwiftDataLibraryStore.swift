// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

enum LibraryStoreSavePhase: Equatable, Sendable {
    case profileCreate
    case profileUpdate
    case profileDelete
    case profileRestore
    case activeProfile
    case manualMapping
    case playlistStaging
    case playlistPointer
    case playlistCleanup
    case epgBatch
    case epgStaging
    case epgPointer
    case epgCleanup
    case status
    case purge
}

typealias LibraryStoreSaveFault = @Sendable (LibraryStoreSavePhase) throws -> Void

@ModelActor
public actor SwiftDataLibraryStore: LibraryRepository, RefreshSnapshotCommitting {
    private var saveFault: LibraryStoreSaveFault?
    /// Nil for every store built with `init(modelContainer:)`. Mirroring is
    /// opt-in so that in-memory fixture and test stores cannot overwrite the
    /// one copy of the real profiles with seeded data.
    private var profileMirror: SourceProfileMirror?

    /// Mirrors profile configuration into `profileMirror` on every change, so
    /// `synchronizeProfileMirror()` can rebuild the profiles after the system
    /// deletes the store. Only the production store needs this.
    public init(
        modelContainer: ModelContainer,
        profileMirror: SourceProfileMirror
    ) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.profileMirror = profileMirror
    }

    init(
        modelContainer: ModelContainer,
        saveFault: @escaping LibraryStoreSaveFault
    ) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.saveFault = saveFault
    }

    public func profiles() throws -> [SourceProfile] {
        let records = try modelContext.fetch(FetchDescriptor<SourceProfileRecord>())
            .sorted(by: Self.profileOrder)
        return try records.map(Self.profile(from:))
    }

    public func activeProfile() throws -> SourceProfile? {
        guard let activeProfileID = try stateRecord()?.activeProfileID else { return nil }
        return try Self.profile(from: profileRecord(id: activeProfileID))
    }

    public func createProfile(
        _ input: ValidatedSourceProfileInput,
        now: Date
    ) throws -> SourceProfile {
        let profileID = UUID()
        try commitProfileChange(.profileCreate) {
            let record = SourceProfileRecord(
                id: profileID,
                name: input.name,
                m3uURLString: input.m3uURL.absoluteString,
                epgURLString: input.epgURL.absoluteString,
                m3uRefreshIntervalRaw: input.m3uRefreshInterval.rawValue,
                epgRefreshIntervalRaw: input.epgRefreshInterval.rawValue,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(record)
            let state = try requiredStateRecord()
            if state.activeProfileID == nil {
                state.activeProfileID = profileID
            }
        }
        return try Self.profile(from: profileRecord(id: profileID))
    }

    public func updateProfile(
        id: UUID,
        input: ValidatedSourceProfileInput,
        now: Date
    ) throws {
        try commitProfileChange(.profileUpdate) {
            let record = try profileRecord(id: id)
            record.name = input.name
            record.m3uURLString = input.m3uURL.absoluteString
            record.epgURLString = input.epgURL.absoluteString
            record.m3uRefreshIntervalRaw = input.m3uRefreshInterval.rawValue
            record.epgRefreshIntervalRaw = input.epgRefreshInterval.rawValue
            record.updatedAt = now
        }
    }

    public func deleteProfile(id: UUID) throws {
        try commitProfileChange(.profileDelete) {
            let record = try profileRecord(id: id)
            if let snapshotID = record.playlistSnapshotID {
                try deletePlaylistSnapshot(id: snapshotID)
            }
            if let snapshotID = record.epgSnapshotID {
                try deleteEPGSnapshot(id: snapshotID)
            }
            let profileID = id
            for mapping in try modelContext.fetch(FetchDescriptor<ManualEPGMappingRecord>(
                predicate: #Predicate { $0.sourceProfileID == profileID }
            )) {
                modelContext.delete(mapping)
            }
            modelContext.delete(record)

            let state = try requiredStateRecord()
            if state.activeProfileID == id {
                let remaining = try modelContext.fetch(FetchDescriptor<SourceProfileRecord>())
                    .filter { $0.id != id }
                    .sorted(by: Self.profileOrder)
                state.activeProfileID = remaining.first?.id
            }
        }
    }

    public func setActiveProfile(id: UUID) throws {
        try commitProfileChange(.activeProfile) {
            _ = try profileRecord(id: id)
            let state = try requiredStateRecord()
            state.activeProfileID = id
        }
    }

    /// Reconciles the store with its UserDefaults mirror, returning how many
    /// profiles it had to rebuild. Call once per launch, before the library is
    /// read.
    ///
    /// The store lives in `Library/Caches`, which tvOS may delete at any time.
    /// An empty store with a populated mirror is that deletion, and the mirror
    /// is the only remaining copy of the profiles, so they are rebuilt from it.
    /// A store that still holds profiles is instead the authority and refreshes
    /// the mirror, which is also how installs predating the mirror get one.
    @discardableResult
    public func synchronizeProfileMirror() throws -> Int {
        guard let profileMirror else { return 0 }
        guard try modelContext.fetch(FetchDescriptor<SourceProfileRecord>()).isEmpty else {
            try updateProfileMirror()
            return 0
        }

        let snapshot = profileMirror.load()
        guard !snapshot.profiles.isEmpty else { return 0 }
        var restoredIDs: Set<UUID> = []
        // Committing through the profile path rewrites the mirror afterwards,
        // so entries dropped as unrestorable do not linger for the next launch.
        try commitProfileChange(.profileRestore) {
            for mirrored in snapshot.profiles {
                guard let record = mirrored.makeRecord() else { continue }
                modelContext.insert(record)
                restoredIDs.insert(record.id)
            }
            guard !restoredIDs.isEmpty else { return }
            let state = try requiredStateRecord()
            let mirroredSelection = snapshot.activeProfileID.flatMap {
                restoredIDs.contains($0) ? $0 : nil
            }
            state.activeProfileID = mirroredSelection
                ?? snapshot.profiles.first { restoredIDs.contains($0.id) }?.id
        }
        return restoredIDs.count
    }

    public func channels(profileID: UUID) throws -> [Channel] {
        guard let snapshotID = try profileRecord(id: profileID).playlistSnapshotID else { return [] }
        let records = try modelContext.fetch(FetchDescriptor<ChannelRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID }
        )).sorted {
            ($0.order, $0.stableID) < ($1.order, $1.stableID)
        }
        return try records.map(Self.channel(from:))
    }

    public func epgChannels(profileID: UUID) throws -> [EPGChannel] {
        guard let snapshotID = try profileRecord(id: profileID).epgSnapshotID else { return [] }
        return try modelContext.fetch(FetchDescriptor<EPGChannelRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID }
        )).sorted { $0.xmltvID < $1.xmltvID }
            .map(Self.epgChannel(from:))
    }

    public func epgProgrammeCount(profileID: UUID) async throws -> Int {
        guard let snapshotID = try profileRecord(id: profileID).epgSnapshotID else { return 0 }
        return try modelContext.fetch(FetchDescriptor<EPGSnapshotRecord>(
            predicate: #Predicate { $0.id == snapshotID }
        )).first?.programmeCount ?? 0
    }

    public func epgCoverageEnd(profileID: UUID) throws -> Date? {
        guard let snapshotID = try profileRecord(id: profileID).epgSnapshotID else { return nil }
        var descriptor = FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID },
            sortBy: [SortDescriptor(\.stop, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.stop
    }

    public func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) throws -> [Programme] {
        guard let snapshotID = try profileRecord(id: profileID).epgSnapshotID else { return [] }
        let lowerBound = overlapping.lowerBound
        let upperBound = overlapping.upperBound
        return try modelContext.fetch(FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate {
                $0.snapshotID == snapshotID
                    && $0.xmltvChannelID == xmltvChannelID
                    && $0.start < upperBound
                    && $0.stop > lowerBound
            }
        )).sorted {
            ($0.start, $0.stableID) < ($1.start, $1.stableID)
        }.map(Self.programme(from:))
    }

    public func manualMapping(
        profileID: UUID,
        channelID: String
    ) throws -> ManualEPGMapping? {
        _ = try profileRecord(id: profileID)
        return try mappingRecord(profileID: profileID, channelID: channelID).map {
            ManualEPGMapping(
                sourceProfileID: $0.sourceProfileID,
                channelID: $0.channelID,
                xmltvChannelID: $0.xmltvChannelID
            )
        }
    }

    public func manualMappings(profileID: UUID) throws -> [String: String] {
        _ = try profileRecord(id: profileID)
        let records = try modelContext.fetch(FetchDescriptor<ManualEPGMappingRecord>(
            predicate: #Predicate { $0.sourceProfileID == profileID }
        ))
        var result: [String: String] = [:]
        result.reserveCapacity(records.count)
        for record in records {
            result[record.channelID] = record.xmltvChannelID
        }
        return result
    }

    public func programmes(
        profileID: UUID,
        xmltvChannelIDs: Set<String>,
        overlapping: Range<Date>
    ) throws -> [String: [Programme]] {
        guard let snapshotID = try profileRecord(id: profileID).epgSnapshotID,
              !xmltvChannelIDs.isEmpty else { return [:] }
        let channelIDs = Array(xmltvChannelIDs)
        let lowerBound = overlapping.lowerBound
        let upperBound = overlapping.upperBound
        let records = try modelContext.fetch(FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate {
                $0.snapshotID == snapshotID
                    && channelIDs.contains($0.xmltvChannelID)
                    && $0.start < upperBound
                    && $0.stop > lowerBound
            }
        )).sorted {
            ($0.start, $0.stableID) < ($1.start, $1.stableID)
        }
        var result: [String: [Programme]] = [:]
        for record in records {
            result[record.xmltvChannelID, default: []].append(Self.programme(from: record))
        }
        return result
    }

    public func setManualMapping(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) throws {
        try commit(.manualMapping) {
            _ = try profileRecord(id: profileID)
            let existing = try mappingRecord(profileID: profileID, channelID: channelID)
            if let xmltvChannelID {
                if let existing {
                    existing.xmltvChannelID = xmltvChannelID
                } else {
                    modelContext.insert(ManualEPGMappingRecord(
                        sourceProfileID: profileID,
                        channelID: channelID,
                        xmltvChannelID: xmltvChannelID
                    ))
                }
            } else if let existing {
                modelContext.delete(existing)
            }
        }
    }

    public func setManualMappingIfCurrentChannel(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) throws -> Bool {
        guard try stateRecord()?.activeProfileID == profileID,
              let snapshotID = try profileRecord(id: profileID).playlistSnapshotID else {
            return false
        }
        let expectedProfileID = profileID
        let expectedChannelID = channelID
        var descriptor = FetchDescriptor<ChannelRecord>(predicate: #Predicate {
            $0.snapshotID == snapshotID
                && $0.sourceProfileID == expectedProfileID
                && $0.stableID == expectedChannelID
        })
        descriptor.fetchLimit = 1
        guard try !modelContext.fetch(descriptor).isEmpty else { return false }
        try setManualMapping(
            profileID: profileID,
            channelID: channelID,
            xmltvChannelID: xmltvChannelID
        )
        return true
    }

    public func installPlaylist(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date
    ) throws {
        try installPlaylistSnapshot(
            profileID: profileID,
            channels: channels,
            fetchedAt: fetchedAt,
            recordsSuccess: false,
            attemptID: nil
        )
    }

    public func commitPlaylistRefresh(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date,
        attemptID: UUID?
    ) throws {
        try installPlaylistSnapshot(
            profileID: profileID,
            channels: channels,
            fetchedAt: fetchedAt,
            recordsSuccess: true,
            attemptID: attemptID
        )
    }

    private func installPlaylistSnapshot(
        profileID: UUID,
        channels: [Channel],
        fetchedAt: Date,
        recordsSuccess: Bool,
        attemptID: UUID?
    ) throws {
        try Task.checkCancellation()
        _ = try profileRecord(id: profileID)
        guard channels.allSatisfy({ $0.sourceProfileID == profileID }) else {
            throw LibraryRepositoryError.invalidChannelProfile
        }
        guard Set(channels.map(\.id)).count == channels.count else {
            throw LibraryRepositoryError.duplicatePlaylistChannel
        }

        let snapshotID = UUID()
        do {
            try commit(.playlistStaging) {
                modelContext.insert(PlaylistSnapshotRecord(
                    id: snapshotID,
                    sourceProfileID: profileID,
                    fetchedAt: fetchedAt,
                    channelCount: channels.count
                ))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                for channel in channels {
                    modelContext.insert(ChannelRecord(
                        snapshotID: snapshotID,
                        sourceProfileID: profileID,
                        stableID: channel.id,
                        displayName: channel.displayName,
                        streamURLString: channel.streamURL.absoluteString,
                        tvgID: channel.tvgID,
                        tvgName: channel.tvgName,
                        logoURLString: channel.logoURL?.absoluteString,
                        groupTitle: channel.groupTitle,
                        attributesJSON: try encoder.encode(channel.attributes),
                        order: channel.order
                    ))
                }
            }
        } catch {
            let stagingError = error
            try? cleanupPlaylistSnapshot(id: snapshotID)
            throw stagingError
        }

        let oldSnapshotID: UUID?
        do {
            try Task.checkCancellation()
            var previousSnapshotID: UUID?
            try commit(.playlistPointer) {
                let profile = try profileRecord(id: profileID)
                previousSnapshotID = profile.playlistSnapshotID
                profile.playlistSnapshotID = snapshotID
                if recordsSuccess {
                    updateSuccessStatus(
                        profile,
                        resource: .playlist,
                        at: fetchedAt,
                        attemptID: attemptID
                    )
                }
            }
            oldSnapshotID = previousSnapshotID
        } catch {
            let pointerError = error
            try? cleanupPlaylistSnapshot(id: snapshotID)
            throw pointerError
        }

        if let oldSnapshotID, oldSnapshotID != snapshotID {
            try? cleanupPlaylistSnapshot(id: oldSnapshotID)
        }
    }

    public func installEPG(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date
    ) throws -> XMLTVParseSummary {
        try installEPGSnapshot(
            profileID: profileID,
            fileURL: fileURL,
            fetchedAt: fetchedAt,
            recordsSuccess: false,
            attemptID: nil
        )
    }

    public func commitEPGRefresh(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date,
        attemptID: UUID?
    ) throws -> XMLTVParseSummary {
        try installEPGSnapshot(
            profileID: profileID,
            fileURL: fileURL,
            fetchedAt: fetchedAt,
            recordsSuccess: true,
            attemptID: attemptID
        )
    }

    private func installEPGSnapshot(
        profileID: UUID,
        fileURL: URL,
        fetchedAt: Date,
        recordsSuccess: Bool,
        attemptID: UUID?
    ) throws -> XMLTVParseSummary {
        try Task.checkCancellation()
        _ = try profileRecord(id: profileID)
        let snapshotID = UUID()
        let summary: XMLTVParseSummary
        do {
            let header = EPGSnapshotRecord(
                id: snapshotID,
                sourceProfileID: profileID,
                fetchedAt: fetchedAt,
                channelCount: 0,
                programmeCount: 0
            )
            modelContext.insert(header)
            let sink = EPGPersistenceSink(
                modelContext: modelContext,
                snapshotID: snapshotID,
                saveBatch: { try self.save(.epgBatch) }
            )
            summary = try XMLTVParser().parse(fileURL: fileURL, into: sink)
            guard summary.channelCount > 0 else {
                throw LibraryRepositoryError.epgHasNoChannels
            }
            header.channelCount = summary.channelCount
            header.programmeCount = summary.programmeCount
            try save(.epgStaging)
        } catch {
            let stagingError = error
            modelContext.rollback()
            try? cleanupEPGSnapshot(id: snapshotID)
            throw stagingError
        }

        let oldSnapshotID: UUID?
        do {
            try Task.checkCancellation()
            var previousSnapshotID: UUID?
            try commit(.epgPointer) {
                let profile = try profileRecord(id: profileID)
                previousSnapshotID = profile.epgSnapshotID
                profile.epgSnapshotID = snapshotID
                if recordsSuccess {
                    updateSuccessStatus(
                        profile,
                        resource: .epg,
                        at: fetchedAt,
                        attemptID: attemptID
                    )
                }
            }
            oldSnapshotID = previousSnapshotID
        } catch {
            let pointerError = error
            try? cleanupEPGSnapshot(id: snapshotID)
            throw pointerError
        }

        if let oldSnapshotID, oldSnapshotID != snapshotID {
            try? cleanupEPGSnapshot(id: oldSnapshotID)
        }
        return summary
    }

    public func recordAttempt(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        try commit(.status) {
            let profile = try profileRecord(id: profileID)
            switch resource {
            case .playlist:
                profile.m3uLastAttemptAt = at
                profile.m3uStateRaw = RefreshState.refreshing.rawValue
                profile.m3uErrorSummary = nil
                profile.m3uAttemptID = attemptID
            case .epg:
                profile.epgLastAttemptAt = at
                profile.epgStateRaw = RefreshState.refreshing.rawValue
                profile.epgErrorSummary = nil
                profile.epgAttemptID = attemptID
            }
            profile.updatedAt = at
        }
    }

    public func recordSuccess(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        try commit(.status) {
            let profile = try profileRecord(id: profileID)
            updateSuccessStatus(
                profile,
                resource: resource,
                at: at,
                attemptID: attemptID
            )
        }
    }

    public func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date,
        attemptID: UUID?
    ) throws {
        let truncatedSummary = String(summary.prefix(240))
        try commit(.status) {
            let profile = try profileRecord(id: profileID)
            switch resource {
            case .playlist:
                profile.m3uStateRaw = RefreshState.failed.rawValue
                profile.m3uErrorSummary = truncatedSummary
                profile.m3uAttemptID = attemptID
            case .epg:
                profile.epgStateRaw = RefreshState.failed.rawValue
                profile.epgErrorSummary = truncatedSummary
                profile.epgAttemptID = attemptID
            }
            profile.updatedAt = at
        }
    }

    public func purgeUnreferencedSnapshots() throws {
        try commit(.purge) {
            let profiles = try modelContext.fetch(FetchDescriptor<SourceProfileRecord>())
            let playlistIDs = profiles.compactMap(\.playlistSnapshotID)
            let epgIDs = profiles.compactMap(\.epgSnapshotID)

            // Predicate-based batch deletes push the work to the store instead of
            // loading every unreferenced row into memory to delete one at a time.
            try modelContext.delete(
                model: ChannelRecord.self,
                where: #Predicate { !playlistIDs.contains($0.snapshotID) }
            )
            try modelContext.delete(
                model: PlaylistSnapshotRecord.self,
                where: #Predicate { !playlistIDs.contains($0.id) }
            )
            try modelContext.delete(
                model: EPGChannelRecord.self,
                where: #Predicate { !epgIDs.contains($0.snapshotID) }
            )
            try modelContext.delete(
                model: ProgrammeRecord.self,
                where: #Predicate { !epgIDs.contains($0.snapshotID) }
            )
            try modelContext.delete(
                model: EPGSnapshotRecord.self,
                where: #Predicate { !epgIDs.contains($0.id) }
            )
        }
    }

    private func stateRecord() throws -> LibraryStateRecord? {
        let singletonKey = "singleton"
        if let state = try modelContext.fetch(FetchDescriptor<LibraryStateRecord>(
            predicate: #Predicate { $0.key == singletonKey }
        )).first {
            return state
        }
        return nil
    }

    private func requiredStateRecord() throws -> LibraryStateRecord {
        if let state = try stateRecord() { return state }
        let state = LibraryStateRecord()
        modelContext.insert(state)
        return state
    }

    private func profileRecord(id: UUID) throws -> SourceProfileRecord {
        let profileID = id
        guard let profile = try modelContext.fetch(FetchDescriptor<SourceProfileRecord>(
            predicate: #Predicate { $0.id == profileID }
        )).first else {
            throw LibraryRepositoryError.profileNotFound
        }
        return profile
    }

    private func mappingRecord(
        profileID: UUID,
        channelID: String
    ) throws -> ManualEPGMappingRecord? {
        try modelContext.fetch(FetchDescriptor<ManualEPGMappingRecord>(
            predicate: #Predicate {
                $0.sourceProfileID == profileID && $0.channelID == channelID
            }
        )).first
    }

    private func updateSuccessStatus(
        _ profile: SourceProfileRecord,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) {
        switch resource {
        case .playlist:
            profile.m3uLastSuccessAt = at
            profile.m3uStateRaw = RefreshState.succeeded.rawValue
            profile.m3uErrorSummary = nil
            profile.m3uAttemptID = attemptID
        case .epg:
            profile.epgLastSuccessAt = at
            profile.epgStateRaw = RefreshState.succeeded.rawValue
            profile.epgErrorSummary = nil
            profile.epgAttemptID = attemptID
        }
        profile.updatedAt = at
    }

    private func cleanupPlaylistSnapshot(id: UUID) throws {
        try commit(.playlistCleanup) {
            try deletePlaylistSnapshot(id: id)
        }
    }

    private func cleanupEPGSnapshot(id: UUID) throws {
        try commit(.epgCleanup) {
            try deleteEPGSnapshot(id: id)
        }
    }

    /// A profile mutation, plus the mirror update that keeps the UserDefaults
    /// copy from lagging the store.
    private func commitProfileChange(
        _ phase: LibraryStoreSavePhase,
        changes: () throws -> Void
    ) throws {
        try commit(phase, changes: changes)
        // The mutation is already durable at this point. A mirror that cannot
        // be rebuilt leaves the recovery copy one edit stale, which is a far
        // smaller loss than failing an edit the user watched succeed.
        try? updateProfileMirror()
    }

    private func updateProfileMirror() throws {
        guard let profileMirror else { return }
        let records = try modelContext.fetch(FetchDescriptor<SourceProfileRecord>())
            .sorted(by: Self.profileOrder)
        profileMirror.save(SourceProfileMirrorSnapshot(
            profiles: records.map(MirroredSourceProfile.init(record:)),
            activeProfileID: try stateRecord()?.activeProfileID
        ))
    }

    private func commit(
        _ phase: LibraryStoreSavePhase,
        changes: () throws -> Void
    ) throws {
        do {
            try changes()
            try save(phase)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func save(_ phase: LibraryStoreSavePhase) throws {
        do {
            try saveFault?(phase)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func deletePlaylistSnapshot(id: UUID) throws {
        let snapshotID = id
        for row in try modelContext.fetch(FetchDescriptor<ChannelRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID }
        )) {
            modelContext.delete(row)
        }
        for header in try modelContext.fetch(FetchDescriptor<PlaylistSnapshotRecord>(
            predicate: #Predicate { $0.id == snapshotID }
        )) {
            modelContext.delete(header)
        }
    }

    private func deleteEPGSnapshot(id: UUID) throws {
        let snapshotID = id
        for row in try modelContext.fetch(FetchDescriptor<EPGChannelRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID }
        )) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate { $0.snapshotID == snapshotID }
        )) {
            modelContext.delete(row)
        }
        for header in try modelContext.fetch(FetchDescriptor<EPGSnapshotRecord>(
            predicate: #Predicate { $0.id == snapshotID }
        )) {
            modelContext.delete(header)
        }
    }

    private static func profileOrder(_ lhs: SourceProfileRecord, _ rhs: SourceProfileRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func profile(from record: SourceProfileRecord) throws -> SourceProfile {
        guard let m3uURL = URL(string: record.m3uURLString),
              let epgURL = URL(string: record.epgURLString),
              let m3uInterval = RefreshInterval(rawValue: record.m3uRefreshIntervalRaw),
              let epgInterval = RefreshInterval(rawValue: record.epgRefreshIntervalRaw),
              let m3uState = RefreshState(rawValue: record.m3uStateRaw),
              let epgState = RefreshState(rawValue: record.epgStateRaw) else {
            throw LibraryRepositoryError.corruptPersistedValue
        }
        return SourceProfile(
            id: record.id,
            name: record.name,
            m3uURL: m3uURL,
            epgURL: epgURL,
            m3uRefreshInterval: m3uInterval,
            epgRefreshInterval: epgInterval,
            m3uStatus: ResourceRefreshStatus(
                lastAttemptAt: record.m3uLastAttemptAt,
                lastSuccessAt: record.m3uLastSuccessAt,
                state: m3uState,
                errorSummary: record.m3uErrorSummary,
                attemptID: record.m3uAttemptID
            ),
            epgStatus: ResourceRefreshStatus(
                lastAttemptAt: record.epgLastAttemptAt,
                lastSuccessAt: record.epgLastSuccessAt,
                state: epgState,
                errorSummary: record.epgErrorSummary,
                attemptID: record.epgAttemptID
            ),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func channel(from record: ChannelRecord) throws -> Channel {
        guard let streamURL = URL(string: record.streamURLString) else {
            throw LibraryRepositoryError.corruptPersistedValue
        }
        let attributes: [String: String]
        do {
            attributes = try JSONDecoder().decode([String: String].self, from: record.attributesJSON)
        } catch {
            throw LibraryRepositoryError.corruptPersistedValue
        }
        return Channel(
            sourceProfileID: record.sourceProfileID,
            displayName: record.displayName,
            streamURL: streamURL,
            tvgID: record.tvgID,
            tvgName: record.tvgName,
            logoURL: record.logoURLString.flatMap(URL.init(string:)),
            groupTitle: record.groupTitle,
            attributes: attributes,
            order: record.order
        )
    }

    private static func epgChannel(from record: EPGChannelRecord) -> EPGChannel {
        EPGChannel(
            id: record.xmltvID,
            displayNames: record.displayNames,
            iconURL: record.iconURLString.flatMap(URL.init(string:))
        )
    }

    private static func programme(from record: ProgrammeRecord) -> Programme {
        Programme(
            id: record.stableID,
            xmltvChannelID: record.xmltvChannelID,
            start: record.start,
            stop: record.stop,
            title: record.title,
            subtitle: record.subtitle,
            summary: record.programmeDescription,
            categories: record.categories
        )
    }
}
