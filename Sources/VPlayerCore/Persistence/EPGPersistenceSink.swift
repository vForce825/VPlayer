// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

final class EPGPersistenceSink: XMLTVEventSink {
    private static let saveBatchSize = 500

    private let modelContext: ModelContext
    private let snapshotID: UUID
    private var pendingEventCount = 0

    init(modelContext: ModelContext, snapshotID: UUID) {
        self.modelContext = modelContext
        self.snapshotID = snapshotID
    }

    func accept(channel: EPGChannel) throws {
        modelContext.insert(EPGChannelRecord(
            snapshotID: snapshotID,
            xmltvID: channel.id,
            displayNames: channel.displayNames,
            iconURLString: channel.iconURL?.absoluteString
        ))
        try saveBatchIfNeeded()
    }

    func accept(programme: Programme) throws {
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
        try modelContext.save()
        pendingEventCount = 0
    }
}
