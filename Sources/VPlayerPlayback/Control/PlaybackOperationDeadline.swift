// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct PlaybackProgressBudgetTicket: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let sessionIdentity: PlaybackSessionIdentity
        let nonce: UInt64
    }
    enum Kind: Sendable, Equatable { case coldStart, outputRecovery }
    let identity: Identity
    let kind: Kind
    let originInstant: UInt64
    let cap: UInt64
    var accumulatedEffectiveTime: UInt64
    var runningSince: UInt64?
    var freezeGeneration: UInt64

    static func coldStart(sessionIdentity: PlaybackSessionIdentity, originInstant: UInt64,
        nonce: UInt64, freezeGeneration: UInt64) -> Self {
        .init(identity: .init(sessionIdentity: sessionIdentity, nonce: nonce), kind: .coldStart,
            originInstant: originInstant, cap: 60_000_000_000, accumulatedEffectiveTime: 0,
            runningSince: nil, freezeGeneration: freezeGeneration)
    }

    static func outputRecovery(sessionIdentity: PlaybackSessionIdentity, originInstant: UInt64,
        nonce: UInt64, freezeGeneration: UInt64) -> Self {
        .init(identity: .init(sessionIdentity: sessionIdentity, nonce: nonce), kind: .outputRecovery,
            originInstant: originInstant, cap: 45_000_000_000, accumulatedEffectiveTime: 0,
            runningSince: nil, freezeGeneration: freezeGeneration)
    }

    func effectiveElapsed(at instant: UInt64) throws -> UInt64 {
        guard let runningSince else { return accumulatedEffectiveTime }
        guard instant >= runningSince else { throw PlaybackSafetyFailure.clockOverflow }
        let (elapsed, overflow) = accumulatedEffectiveTime.addingReportingOverflow(instant - runningSince)
        guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
        return elapsed
    }

    func remainingNanoseconds(at instant: UInt64) throws -> UInt64 {
        let elapsed = try effectiveElapsed(at: instant)
        return elapsed < cap ? cap - elapsed : 0
    }

    func isExpired(at instant: UInt64) throws -> Bool {
        try effectiveElapsed(at: instant) >= cap
    }

    mutating func freeze(at instant: UInt64, freezeGeneration: UInt64) throws {
        accumulatedEffectiveTime = try effectiveElapsed(at: instant)
        runningSince = nil
        self.freezeGeneration = freezeGeneration
    }

    mutating func resume(at instant: UInt64, freezeGeneration: UInt64) {
        guard runningSince == nil else { return }
        runningSince = instant
        self.freezeGeneration = freezeGeneration
    }
}
enum CurrentPlaybackOperationDeadlineTicket: Sendable, Equatable {
    case coldStart(PlaybackProgressBudgetTicket)
    case outputRecovery(PlaybackProgressBudgetTicket)
}
struct PlaybackOperationDeadlineArmTicket: Sendable, Equatable {
    let parentOperationTicketIdentity: PlaybackProgressBudgetTicket.Identity
    let freezeGeneration: UInt64
}

struct PlaybackDeadlineRearm<Arm: Sendable & Equatable>: Sendable, Equatable {
    let arm: Arm
    let remainingNanoseconds: UInt64
    /// Authority在同一Cell锁内以本次单调时钟样本checked得到的最晚投递时刻。
    let notAfterInstant: UInt64
}
struct AudioSessionAcquisitionDeadline: Sendable, Equatable {
    let acquisitionTicket: ControlTaskTicket
    let anchorInstant: UInt64
    let deadlineInstant: UInt64

    init(acquisitionTicket: ControlTaskTicket, anchorInstant: UInt64) throws {
        let (deadline, overflow) = anchorInstant.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
        self.acquisitionTicket = acquisitionTicket
        self.anchorInstant = anchorInstant
        deadlineInstant = deadline
    }

    func remainingNanoseconds(at instant: UInt64) -> UInt64 {
        instant < deadlineInstant ? deadlineInstant - max(anchorInstant, instant) : 0
    }
    func isExpired(at instant: UInt64) -> Bool { instant >= deadlineInstant }
}
struct CleanupBudgetTicket: Sendable, Equatable {
    let predecessorIdentity: ControlResourceIdentity
    let anchorInstant: UInt64
    let nonce: UInt64
    let deadlineInstant: UInt64
    init(predecessorIdentity: ControlResourceIdentity, anchorInstant: UInt64,
         nonce: UInt64) throws {
        let (deadline, overflow) = anchorInstant.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
        self.predecessorIdentity = predecessorIdentity
        self.anchorInstant = anchorInstant
        self.nonce = nonce
        deadlineInstant = deadline
    }

    func remainingNanoseconds(at instant: UInt64) -> UInt64 {
        instant < deadlineInstant ? deadlineInstant - max(anchorInstant, instant) : 0
    }
    func isExpired(at instant: UInt64) -> Bool { instant >= deadlineInstant }
}

enum PlaybackDeadlineBudget {
    static func audioOnlyCandidateAdmission(laterCandidateCount: UInt64) throws -> UInt64 {
        guard laterCandidateCount > 0 else { return 8_000_000_000 }
        let (probeAndCleanup, multiplyOverflow) = laterCandidateCount.multipliedReportingOverflow(by: 6_000_000_000)
        guard !multiplyOverflow else { throw PlaybackSafetyFailure.clockOverflow }
        let (total, addOverflow) = probeAndCleanup.addingReportingOverflow(8_000_000_000)
        guard !addOverflow else { throw PlaybackSafetyFailure.clockOverflow }
        return total
    }

    static func admits(remainingNanoseconds: UInt64, requiredNanoseconds: UInt64) -> Bool {
        remainingNanoseconds >= requiredNanoseconds
    }
}
