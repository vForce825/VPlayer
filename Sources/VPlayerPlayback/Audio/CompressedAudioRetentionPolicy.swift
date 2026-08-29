// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

struct CompressedAudioRetentionLimits: Sendable, Equatable {
    let maximumCount: Int
    let maximumOwnedBytes: Int
    let latestTailHorizon: CMTime

    init(
        maximumCount: Int,
        maximumOwnedBytes: Int,
        latestTailHorizon: CMTime
    ) throws {
        guard maximumCount > 0,
              maximumOwnedBytes > 0,
              latestTailHorizon.isNumeric,
              CMTimeCompare(latestTailHorizon, .zero) > 0 else {
            throw PlaybackCoreError.audioRendererFailed(
                CompressedAudioRetentionPolicy.accountingError
            )
        }
        self.maximumCount = maximumCount
        self.maximumOwnedBytes = maximumOwnedBytes
        self.latestTailHorizon = latestTailHorizon
    }

    private init(
        validatedMaximumCount: Int,
        validatedMaximumOwnedBytes: Int,
        validatedLatestTailHorizon: CMTime
    ) {
        maximumCount = validatedMaximumCount
        maximumOwnedBytes = validatedMaximumOwnedBytes
        latestTailHorizon = validatedLatestTailHorizon
    }

    static func production(
        maximumCount: Int,
        maximumOwnedBytes: Int
    ) -> Self {
        Self(
            validatedMaximumCount: maximumCount,
            validatedMaximumOwnedBytes: maximumOwnedBytes,
            validatedLatestTailHorizon: CMTime(value: 12, timescale: 1)
        )
    }
}

enum CompressedAudioRetentionPolicy {
    static let rawAACMaximumAccessUnitBytes = 1 * 1_024 * 1_024
    static let pending = CompressedAudioRetentionLimits.production(
        maximumCount: 96,
        maximumOwnedBytes: 4 * 1_024 * 1_024
    )
    static let continuity = CompressedAudioRetentionLimits.production(
        maximumCount: 512,
        maximumOwnedBytes: 8 * 1_024 * 1_024
    )
    static let replay = CompressedAudioRetentionLimits.production(
        maximumCount: 512,
        maximumOwnedBytes: 8 * 1_024 * 1_024
    )
    static let replaySoftCount = replay.maximumCount
    static let replayHardCount = 1_024

    static let pendingCapacityError = "audio.pending.capacity"
    static let continuityCapacityError = "audio.continuity.capacity"
    static let replayCapacityError = "audio.replay.capacity"
    static let accountingError = "audio.retention.accounting"
    static let unretainedAnchorError = "audio.anchor.unretained"
}

struct OwnedByteBudget: Sendable {
    let limit: Int
    private(set) var used: Int

    init(limit: Int, used: Int = 0) {
        precondition(limit >= 0 && used >= 0 && used <= limit)
        self.limit = limit
        self.used = used
    }

    mutating func reserve(_ bytes: Int) throws -> Bool {
        guard bytes >= 0 else { throw Self.accountingFailure() }
        let (newUsed, overflow) = used.addingReportingOverflow(bytes)
        guard !overflow else { throw Self.accountingFailure() }
        guard newUsed <= limit else { return false }
        used = newUsed
        return true
    }

    mutating func release(_ bytes: Int) throws {
        guard bytes >= 0 else { throw Self.accountingFailure() }
        let (newUsed, overflow) = used.subtractingReportingOverflow(bytes)
        guard !overflow, newUsed >= 0 else { throw Self.accountingFailure() }
        used = newUsed
    }

    mutating func reset() {
        used = 0
    }

    private static func accountingFailure() -> PlaybackCoreError {
        .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
    }
}
