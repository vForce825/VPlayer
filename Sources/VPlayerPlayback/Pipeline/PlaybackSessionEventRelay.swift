// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct PlaybackRunIdentity: Equatable, Sendable {
    let sessionID: UInt64
    let requestID: UUID
}

final class PlaybackSessionEventRelay: @unchecked Sendable {
    typealias Receiver = @Sendable (PlaybackRunIdentity, PlaybackPipelineEvent) async -> Void

    private let identity: PlaybackRunIdentity
    private let receiver: Receiver
    private let lock = NSLock()
    private var pending: [PlaybackPipelineEvent] = []
    private var pendingIndex = 0
    private var isDraining = false
    private var isActive = true

    init(identity: PlaybackRunIdentity, receiver: @escaping Receiver) {
        self.identity = identity
        self.receiver = receiver
    }

    func send(_ event: PlaybackPipelineEvent) {
        let shouldStartDrain = lock.withLock { () -> Bool in
            guard isActive else { return false }
            pending.append(event)
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
        guard shouldStartDrain else { return }
        Task { [self] in await drain() }
    }

    func deactivate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            pending.removeAll(keepingCapacity: false)
            pendingIndex = 0
        }
    }

    private func drain() async {
        while let event = nextEvent() {
            await receiver(identity, event)
        }
    }

    private func nextEvent() -> PlaybackPipelineEvent? {
        lock.withLock {
            guard isActive else {
                pending.removeAll(keepingCapacity: false)
                pendingIndex = 0
                isDraining = false
                return nil
            }
            guard pendingIndex < pending.count else {
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = pending[pendingIndex]
            pendingIndex += 1
            return event
        }
    }
}

final class PlaybackAudioSessionEventRelay: @unchecked Sendable {
    typealias Receiver = @Sendable (
        PlaybackRunIdentity,
        PlaybackAudioSessionLease,
        PlaybackAudioSessionEvent
    ) async -> Void

    private struct PendingEvent {
        let lease: PlaybackAudioSessionLease
        let event: PlaybackAudioSessionEvent
    }

    private let identity: PlaybackRunIdentity
    private let receiver: Receiver
    private let lock = NSLock()
    private var pending: [PendingEvent] = []
    private var pendingIndex = 0
    private var isDraining = false
    private var isActive = true

    init(identity: PlaybackRunIdentity, receiver: @escaping Receiver) {
        self.identity = identity
        self.receiver = receiver
    }

    func send(lease: PlaybackAudioSessionLease, event: PlaybackAudioSessionEvent) {
        let shouldStartDrain = lock.withLock { () -> Bool in
            guard isActive else { return false }
            pending.append(PendingEvent(lease: lease, event: event))
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
        guard shouldStartDrain else { return }
        Task { [self] in await drain() }
    }

    func deactivate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            pending.removeAll(keepingCapacity: false)
            pendingIndex = 0
        }
    }

    private func drain() async {
        while let pendingEvent = nextEvent() {
            await receiver(identity, pendingEvent.lease, pendingEvent.event)
        }
    }

    private func nextEvent() -> PendingEvent? {
        lock.withLock {
            guard isActive else {
                pending.removeAll(keepingCapacity: false)
                pendingIndex = 0
                isDraining = false
                return nil
            }
            guard pendingIndex < pending.count else {
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = pending[pendingIndex]
            pendingIndex += 1
            return event
        }
    }
}
