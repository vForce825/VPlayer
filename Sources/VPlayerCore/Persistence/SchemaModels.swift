// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

@Model final class LibraryStateRecord {
    @Attribute(.unique) var key: String
    var activeProfileID: UUID?

    init(key: String = "singleton", activeProfileID: UUID? = nil) {
        self.key = key
        self.activeProfileID = activeProfileID
    }
}

@Model final class SourceProfileRecord {
    #Index<SourceProfileRecord>([\.createdAt], [\.updatedAt])
    @Attribute(.unique) var id: UUID
    var name: String
    var m3uURLString: String
    var epgURLString: String
    var m3uRefreshIntervalRaw: Int
    var epgRefreshIntervalRaw: Int
    var playlistSnapshotID: UUID?
    var epgSnapshotID: UUID?
    var m3uLastAttemptAt: Date?
    var m3uLastSuccessAt: Date?
    var m3uStateRaw: String
    var m3uErrorSummary: String?
    var epgLastAttemptAt: Date?
    var epgLastSuccessAt: Date?
    var epgStateRaw: String
    var epgErrorSummary: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        m3uURLString: String,
        epgURLString: String,
        m3uRefreshIntervalRaw: Int,
        epgRefreshIntervalRaw: Int,
        playlistSnapshotID: UUID? = nil,
        epgSnapshotID: UUID? = nil,
        m3uLastAttemptAt: Date? = nil,
        m3uLastSuccessAt: Date? = nil,
        m3uStateRaw: String = RefreshState.never.rawValue,
        m3uErrorSummary: String? = nil,
        epgLastAttemptAt: Date? = nil,
        epgLastSuccessAt: Date? = nil,
        epgStateRaw: String = RefreshState.never.rawValue,
        epgErrorSummary: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.m3uURLString = m3uURLString
        self.epgURLString = epgURLString
        self.m3uRefreshIntervalRaw = m3uRefreshIntervalRaw
        self.epgRefreshIntervalRaw = epgRefreshIntervalRaw
        self.playlistSnapshotID = playlistSnapshotID
        self.epgSnapshotID = epgSnapshotID
        self.m3uLastAttemptAt = m3uLastAttemptAt
        self.m3uLastSuccessAt = m3uLastSuccessAt
        self.m3uStateRaw = m3uStateRaw
        self.m3uErrorSummary = m3uErrorSummary
        self.epgLastAttemptAt = epgLastAttemptAt
        self.epgLastSuccessAt = epgLastSuccessAt
        self.epgStateRaw = epgStateRaw
        self.epgErrorSummary = epgErrorSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class PlaylistSnapshotRecord {
    #Index<PlaylistSnapshotRecord>([\.sourceProfileID], [\.fetchedAt])
    @Attribute(.unique) var id: UUID
    var sourceProfileID: UUID
    var fetchedAt: Date
    var channelCount: Int

    init(id: UUID, sourceProfileID: UUID, fetchedAt: Date, channelCount: Int) {
        self.id = id
        self.sourceProfileID = sourceProfileID
        self.fetchedAt = fetchedAt
        self.channelCount = channelCount
    }
}

@Model final class ChannelRecord {
    #Unique<ChannelRecord>([\.snapshotID, \.stableID])
    #Index<ChannelRecord>([\.snapshotID, \.order], [\.sourceProfileID, \.stableID])
    var snapshotID: UUID
    var sourceProfileID: UUID
    var stableID: String
    var displayName: String
    var streamURLString: String
    var tvgID: String?
    var tvgName: String?
    var logoURLString: String?
    var groupTitle: String?
    var attributesJSON: Data
    var order: Int

    init(
        snapshotID: UUID,
        sourceProfileID: UUID,
        stableID: String,
        displayName: String,
        streamURLString: String,
        tvgID: String?,
        tvgName: String?,
        logoURLString: String?,
        groupTitle: String?,
        attributesJSON: Data,
        order: Int
    ) {
        self.snapshotID = snapshotID
        self.sourceProfileID = sourceProfileID
        self.stableID = stableID
        self.displayName = displayName
        self.streamURLString = streamURLString
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.logoURLString = logoURLString
        self.groupTitle = groupTitle
        self.attributesJSON = attributesJSON
        self.order = order
    }
}

@Model final class EPGSnapshotRecord {
    #Index<EPGSnapshotRecord>([\.sourceProfileID], [\.fetchedAt])
    @Attribute(.unique) var id: UUID
    var sourceProfileID: UUID
    var fetchedAt: Date
    var channelCount: Int
    var programmeCount: Int

    init(
        id: UUID,
        sourceProfileID: UUID,
        fetchedAt: Date,
        channelCount: Int,
        programmeCount: Int
    ) {
        self.id = id
        self.sourceProfileID = sourceProfileID
        self.fetchedAt = fetchedAt
        self.channelCount = channelCount
        self.programmeCount = programmeCount
    }
}

@Model final class EPGChannelRecord {
    #Unique<EPGChannelRecord>([\.snapshotID, \.xmltvID])
    #Index<EPGChannelRecord>([\.snapshotID, \.xmltvID])
    var snapshotID: UUID
    var xmltvID: String
    var displayNames: [String]
    var iconURLString: String?

    init(snapshotID: UUID, xmltvID: String, displayNames: [String], iconURLString: String?) {
        self.snapshotID = snapshotID
        self.xmltvID = xmltvID
        self.displayNames = displayNames
        self.iconURLString = iconURLString
    }
}

@Model final class ProgrammeRecord {
    #Unique<ProgrammeRecord>([\.snapshotID, \.stableID])
    #Index<ProgrammeRecord>([\.snapshotID, \.xmltvChannelID, \.start])
    var snapshotID: UUID
    var stableID: String
    var xmltvChannelID: String
    var start: Date
    var stop: Date
    var title: String
    var subtitle: String?
    var programmeDescription: String?
    var categories: [String]

    init(
        snapshotID: UUID,
        stableID: String,
        xmltvChannelID: String,
        start: Date,
        stop: Date,
        title: String,
        subtitle: String?,
        programmeDescription: String?,
        categories: [String]
    ) {
        self.snapshotID = snapshotID
        self.stableID = stableID
        self.xmltvChannelID = xmltvChannelID
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.programmeDescription = programmeDescription
        self.categories = categories
    }
}

@Model final class ManualEPGMappingRecord {
    #Unique<ManualEPGMappingRecord>([\.sourceProfileID, \.channelID])
    #Index<ManualEPGMappingRecord>([\.sourceProfileID, \.channelID])
    var sourceProfileID: UUID
    var channelID: String
    var xmltvChannelID: String

    init(sourceProfileID: UUID, channelID: String, xmltvChannelID: String) {
        self.sourceProfileID = sourceProfileID
        self.channelID = channelID
        self.xmltvChannelID = xmltvChannelID
    }
}
