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
    static let defaultSaveBatchSize = 500
    private static let historicalBackfillHorizonSeconds: TimeInterval = 30 * 86_400

    private let saveBatchSize: Int
    let minimumRetainedProgrammeStop: Date?
    private let earliestPrunableBackfillStop: Date?
    private let cancellationCheck: @Sendable () throws -> Void
    private let persistBatch: (EPGPersistenceBatch) throws -> Void
    private let batchDidPassPostPersistCancellationCheck: (() -> Void)?
    private var channelIDs: Set<String> = []
    private var programmeDigestKeys: Set<ProgrammeDigestKey> = []
    private var nonDigestProgrammeIDs: Set<String> = []
    private(set) var maxProgrammeStop: Date?
    private var channels: [EPGChannel] = []
    private var programmes: [Programme] = []

    var acceptedSummary: XMLTVParseSummary {
        XMLTVParseSummary(
            channelCount: channelIDs.count,
            programmeCount: programmeDigestKeys.count + nonDigestProgrammeIDs.count,
            coverageEnd: maxProgrammeStop
        )
    }

    init(
        batchSize: Int = EPGPersistenceSink.defaultSaveBatchSize,
        minimumRetainedProgrammeStop: Date? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        persistBatch: @escaping (EPGPersistenceBatch) throws -> Void,
        batchDidPassPostPersistCancellationCheck: (() -> Void)? = nil
    ) {
        saveBatchSize = max(1, batchSize)
        self.minimumRetainedProgrammeStop = minimumRetainedProgrammeStop
        earliestPrunableBackfillStop = minimumRetainedProgrammeStop?.addingTimeInterval(
            -Self.historicalBackfillHorizonSeconds
        )
        self.cancellationCheck = cancellationCheck
        self.persistBatch = persistBatch
        self.batchDidPassPostPersistCancellationCheck = batchDidPassPostPersistCancellationCheck
        channels.reserveCapacity(min(saveBatchSize, 1_024))
        programmes.reserveCapacity(saveBatchSize)
    }

    func shouldPruneHistoricalProgramme(stop: Date) -> Bool {
        guard let cutoff = minimumRetainedProgrammeStop,
              let horizon = earliestPrunableBackfillStop else {
            return false
        }
        return stop <= cutoff && stop >= horizon
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
        guard insertProgrammeID(programme.id) else { return }
        recordMaxStop(programme.stop)
        guard !shouldPruneHistoricalProgramme(stop: programme.stop) else { return }
        programmes.append(programme)
        try flushIfNeeded()
    }

    func accept(programme: Programme, digest: ProgrammeDigestKey) throws {
        try cancellationCheck()
        guard programmeDigestKeys.insert(digest).inserted else { return }
        recordMaxStop(programme.stop)
        guard !shouldPruneHistoricalProgramme(stop: programme.stop) else { return }
        programmes.append(programme)
        try flushIfNeeded()
    }

    func recordExpiredProgramme(digest: ProgrammeDigestKey, stop: Date) throws {
        try cancellationCheck()
        guard programmeDigestKeys.insert(digest).inserted else { return }
        recordMaxStop(stop)
    }

    private func recordMaxStop(_ stop: Date) {
        if let currentMax = maxProgrammeStop {
            if stop > currentMax {
                maxProgrammeStop = stop
            }
        } else {
            maxProgrammeStop = stop
        }
    }

    private func insertProgrammeID(_ id: String) -> Bool {
        if let digestKey = ProgrammeDigestKey(hexString: id) {
            return programmeDigestKeys.insert(digestKey).inserted
        }
        return nonDigestProgrammeIDs.insert(id).inserted
    }

    func finish() throws {
        try flush()
    }

    private func flushIfNeeded() throws {
        guard channels.count + programmes.count == saveBatchSize else { return }
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
