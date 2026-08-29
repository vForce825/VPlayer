// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AudioRendererProgressToken: Sendable, Equatable {
    let rendererID: AudioRendererIdentity
    let epoch: UInt64
    let generation: MediaGeneration
    let islandID: AudioContinuityIslandID
    let consumptionSequence: UInt64
}

struct AudioRendererDemandProgressState: Sendable {
    private(set) var rendererID: AudioRendererIdentity?
    private(set) var epoch: UInt64 = 0
    private(set) var queueEpisode: UInt64 = 0
    private(set) var consumptionSequence: UInt64 = 0
    private var acceptedInEpisode = false
    private var waitingForReadyAfterBackpressure = false
    private var nextQueueEpisodeRawValue: UInt64?
    private var queueEpisodeExhausted = false

    init(nextQueueEpisodeRawValue: UInt64? = 1) {
        self.nextQueueEpisodeRawValue = nextQueueEpisodeRawValue
    }

    var needsProgressRequest: Bool {
        rendererID != nil && waitingForReadyAfterBackpressure
    }

    mutating func rendererDidChange(
        to rendererID: AudioRendererIdentity?,
        epoch: UInt64
    ) {
        self.rendererID = rendererID
        self.epoch = epoch
        consumptionSequence = 0
        acceptedInEpisode = false
        waitingForReadyAfterBackpressure = false
        guard mintQueueEpisode() else {
            queueEpisodeExhausted = true
            return
        }
    }

    mutating func queueWasReset(
        rendererID: AudioRendererIdentity,
        epoch: UInt64
    ) {
        guard matches(rendererID: rendererID, epoch: epoch, queueEpisode: queueEpisode)
        else { return }
        acceptedInEpisode = false
        waitingForReadyAfterBackpressure = false
        guard mintQueueEpisode() else {
            queueEpisodeExhausted = true
            return
        }
    }

    mutating func accepted(
        rendererID: AudioRendererIdentity,
        epoch: UInt64,
        queueEpisode: UInt64
    ) {
        guard matches(
            rendererID: rendererID,
            epoch: epoch,
            queueEpisode: queueEpisode
        ) else { return }
        acceptedInEpisode = true
    }

    mutating func backpressured(
        rendererID: AudioRendererIdentity,
        epoch: UInt64,
        queueEpisode: UInt64
    ) {
        guard acceptedInEpisode,
              matches(
                  rendererID: rendererID,
                  epoch: epoch,
                  queueEpisode: queueEpisode
              ) else { return }
        waitingForReadyAfterBackpressure = true
    }

    mutating func readyAfterValidatedRequest(
        rendererID: AudioRendererIdentity,
        epoch: UInt64,
        queueEpisode: UInt64
    ) -> Bool {
        guard waitingForReadyAfterBackpressure,
              matches(
                  rendererID: rendererID,
                  epoch: epoch,
                  queueEpisode: queueEpisode
              ) else { return false }
        waitingForReadyAfterBackpressure = false
        guard consumptionSequence < UInt64.max else { return false }
        consumptionSequence += 1
        return true
    }

    func token(
        generation: MediaGeneration,
        islandID: AudioContinuityIslandID
    ) -> AudioRendererProgressToken? {
        guard let rendererID else { return nil }
        return AudioRendererProgressToken(
            rendererID: rendererID,
            epoch: epoch,
            generation: generation,
            islandID: islandID,
            consumptionSequence: consumptionSequence
        )
    }

    private func matches(
        rendererID: AudioRendererIdentity,
        epoch: UInt64,
        queueEpisode: UInt64
    ) -> Bool {
        !queueEpisodeExhausted
            && self.rendererID == rendererID
            && self.epoch == epoch
            && self.queueEpisode == queueEpisode
    }

    private mutating func mintQueueEpisode() -> Bool {
        guard let rawValue = nextQueueEpisodeRawValue else { return false }
        queueEpisode = rawValue
        queueEpisodeExhausted = false
        nextQueueEpisodeRawValue = rawValue == UInt64.max ? nil : rawValue + 1
        return true
    }
}

struct AudioCompressedAttemptKey: Hashable, Sendable {
    let generation: MediaGeneration
    let fingerprint: MediaFormatFingerprint
    let routeRevision: UInt64
    let islandID: AudioContinuityIslandID?
}

struct AudioRendererProgressTicket: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64
}

enum AudioRendererProgressAction: Sendable, Equatable {
    case replay
    case scheduleDeadline(AudioRendererProgressTicket)
    case rebuildCompressed
    case fallbackPCM
    case terminalTicketExhausted
}

struct AudioRendererRecoveryProgressMonitor: Sendable {
    private enum Phase: Sendable {
        case original
        case replacement
    }

    private struct Baseline: Sendable {
        let key: AudioCompressedAttemptKey
        let token: AudioRendererProgressToken
        let ticket: AudioRendererProgressTicket
        let phase: Phase
    }

    private var attemptKey: AudioCompressedAttemptKey?
    private var rebuildConsumed = false
    private var baseline: Baseline?
    private var nextTicketRawValue: UInt64? = 1

    init() {}

    init(testingNextTicketRawValue: UInt64) {
        nextTicketRawValue = testingNextTicketRawValue
    }

    var hasActiveBaseline: Bool { baseline != nil }

    mutating func automaticFlush(
        key: AudioCompressedAttemptKey,
        token: AudioRendererProgressToken,
        hasReplay: Bool
    ) -> [AudioRendererProgressAction] {
        startAttemptIfNeeded(key)
        observeProgress(token)
        guard hasReplay, baseline == nil else { return [] }
        return beginBaseline(
            key: key,
            token: token,
            phase: rebuildConsumed ? .replacement : .original
        )
    }

    mutating func correlatedRecovery(
        key: AudioCompressedAttemptKey,
        token: AudioRendererProgressToken,
        hasReplay _: Bool
    ) -> [AudioRendererProgressAction] {
        startAttemptIfNeeded(key)
        observeProgress(token)
        guard baseline == nil else { return [] }
        return [.replay]
    }

    mutating func replacementReady(
        key: AudioCompressedAttemptKey,
        token: AudioRendererProgressToken,
        hasReplay: Bool
    ) -> [AudioRendererProgressAction] {
        let continuesConsumedAttempt = attemptKey == key && rebuildConsumed
        startAttemptIfNeeded(key)
        baseline = nil
        guard hasReplay else { return [] }
        return beginBaseline(
            key: key,
            token: token,
            phase: continuesConsumedAttempt ? .replacement : .original
        )
    }

    mutating func rendererFailed(
        key: AudioCompressedAttemptKey,
        hasReplay: Bool
    ) -> [AudioRendererProgressAction] {
        startAttemptIfNeeded(key)
        baseline = nil
        guard hasReplay else { return [] }
        if rebuildConsumed {
            return [.fallbackPCM]
        }
        rebuildConsumed = true
        return [.rebuildCompressed]
    }

    @discardableResult
    mutating func observeProgress(_ token: AudioRendererProgressToken) -> Bool {
        guard let baseline,
              baseline.key == attemptKey,
              Self.hasProgress(from: baseline.token, to: token) else { return false }
        self.baseline = nil
        return true
    }

    mutating func deadlineFired(
        _ ticket: AudioRendererProgressTicket,
        token: AudioRendererProgressToken?
    ) -> [AudioRendererProgressAction] {
        guard let baseline,
              baseline.ticket == ticket,
              baseline.key == attemptKey else { return [] }
        self.baseline = nil
        if let token,
           Self.hasProgress(from: baseline.token, to: token) {
            return []
        }

        switch baseline.phase {
        case .original:
            if rebuildConsumed { return [.fallbackPCM] }
            rebuildConsumed = true
            return [.rebuildCompressed]
        case .replacement:
            return [.fallbackPCM]
        }
    }

    mutating func invalidate() {
        attemptKey = nil
        rebuildConsumed = false
        baseline = nil
    }

    private mutating func startAttemptIfNeeded(_ key: AudioCompressedAttemptKey) {
        guard key != attemptKey else { return }
        attemptKey = key
        rebuildConsumed = false
        baseline = nil
    }

    private mutating func beginBaseline(
        key: AudioCompressedAttemptKey,
        token: AudioRendererProgressToken,
        phase: Phase
    ) -> [AudioRendererProgressAction] {
        guard let rawValue = nextTicketRawValue else {
            baseline = nil
            return [.terminalTicketExhausted]
        }
        nextTicketRawValue = rawValue == UInt64.max ? nil : rawValue + 1
        let ticket = AudioRendererProgressTicket(rawValue: rawValue)
        baseline = Baseline(key: key, token: token, ticket: ticket, phase: phase)
        return [.replay, .scheduleDeadline(ticket)]
    }

    private static func hasProgress(
        from baseline: AudioRendererProgressToken,
        to current: AudioRendererProgressToken
    ) -> Bool {
        guard current.rendererID == baseline.rendererID,
              current.epoch == baseline.epoch,
              current.generation == baseline.generation,
              current.islandID == baseline.islandID else { return false }
        return current.consumptionSequence > baseline.consumptionSequence
    }
}
