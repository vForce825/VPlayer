// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

enum EPGPersistenceSinkError: Error, Equatable, Sendable {
    case duplicateChannelID
    case duplicateProgrammeID
}

final class EPGPersistenceSink: XMLTVEventSink {
    private static let saveBatchSize = 500

    private let modelContext: ModelContext
    private let snapshotID: UUID
    private let saveBatch: () throws -> Void
    private var pendingEventCount = 0
    private var channelIDs: Set<String> = []
    private var programmeIDs: Set<String> = []

    init(
        modelContext: ModelContext,
        snapshotID: UUID,
        saveBatch: @escaping () throws -> Void
    ) {
        self.modelContext = modelContext
        self.snapshotID = snapshotID
        self.saveBatch = saveBatch
    }

    func accept(channel: EPGChannel) throws {
        guard channelIDs.insert(channel.id).inserted else {
            throw EPGPersistenceSinkError.duplicateChannelID
        }
        modelContext.insert(EPGChannelRecord(
            snapshotID: snapshotID,
            xmltvID: channel.id,
            displayNames: channel.displayNames,
            iconURLString: channel.iconURL?.absoluteString
        ))
        try saveBatchIfNeeded()
    }

    func accept(programme: Programme) throws {
        guard programmeIDs.insert(programme.id).inserted else {
            throw EPGPersistenceSinkError.duplicateProgrammeID
        }
        modelContext.insert(ProgrammeRecord(
            snapshotID: snapshotID,
            stableID: programme.id,
            xmltvChannelID: programme.xmltvChannelID,
            start: programme.start,
            stop: programme.stop,
            title: programme.title,
            subtitle: programme.subtitle,
            programmeDescription: programme.summary,
            categories: programme.categories
        ))
        try saveBatchIfNeeded()
    }

    private func saveBatchIfNeeded() throws {
        pendingEventCount += 1
        guard pendingEventCount == Self.saveBatchSize else { return }
        try saveBatch()
        pendingEventCount = 0
    }
}
