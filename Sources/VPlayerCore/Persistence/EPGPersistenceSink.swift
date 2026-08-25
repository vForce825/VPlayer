// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum EPGPersistenceSinkError: Error, Equatable, Sendable {
    case duplicateChannelID
}

struct EPGPersistenceBatch: Sendable {
    let channels: [EPGChannel]
    let programmes: [Programme]
}

final class EPGPersistenceSink: XMLTVEventSink {
    private static let saveBatchSize = 500

    private let cancellationCheck: @Sendable () throws -> Void
    private let persistBatch: (EPGPersistenceBatch) throws -> Void
    private let batchDidPassPostPersistCancellationCheck: (() -> Void)?
    private var channelIDs: Set<String> = []
    private var programmeIDs: Set<String> = []
    private var channels: [EPGChannel] = []
    private var programmes: [Programme] = []

    var acceptedSummary: XMLTVParseSummary {
        XMLTVParseSummary(
            channelCount: channelIDs.count,
            programmeCount: programmeIDs.count
        )
    }

    init(
        cancellationCheck: @escaping @Sendable () throws -> Void,
        persistBatch: @escaping (EPGPersistenceBatch) throws -> Void,
        batchDidPassPostPersistCancellationCheck: (() -> Void)? = nil
    ) {
        self.cancellationCheck = cancellationCheck
        self.persistBatch = persistBatch
        self.batchDidPassPostPersistCancellationCheck = batchDidPassPostPersistCancellationCheck
    }

    func accept(channel: EPGChannel) throws {
        try cancellationCheck()
        guard channelIDs.insert(channel.id).inserted else {
            throw EPGPersistenceSinkError.duplicateChannelID
        }
        channels.append(channel)
        try flushIfNeeded()
    }

    func accept(programme: Programme) throws {
        try cancellationCheck()
        guard programmeIDs.insert(programme.id).inserted else { return }
        programmes.append(programme)
        try flushIfNeeded()
    }

    func finish() throws {
        try flush()
    }

    private func flushIfNeeded() throws {
        guard channels.count + programmes.count == Self.saveBatchSize else { return }
        try flush()
    }

    private func flush() throws {
        try cancellationCheck()
        guard !channels.isEmpty || !programmes.isEmpty else { return }
        try persistBatch(EPGPersistenceBatch(
            channels: channels,
            programmes: programmes
        ))
        try cancellationCheck()
        batchDidPassPostPersistCancellationCheck?()
        channels.removeAll(keepingCapacity: true)
        programmes.removeAll(keepingCapacity: true)
    }
}
