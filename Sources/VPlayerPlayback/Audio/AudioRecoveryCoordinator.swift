// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch

enum AudioRecoveryCause: UInt8, Sendable, Hashable, CaseIterable {
    case automaticFlush
    case outputConfigurationChanged
    case routeChanged
}

struct AudioRecoveryTicket: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum AudioRecoveryAction: Sendable, Equatable {
    case scheduleCollection(AudioRecoveryTicket)
    case recover(AudioRecoveryTicket, causes: Set<AudioRecoveryCause>)
    case scheduleSettleExpiry(AudioRecoveryTicket)
    case suppressed(AudioRecoveryTicket, cause: AudioRecoveryCause)
}

struct AudioRecoveryCoordinator: Sendable {
    static let collectionDelay: DispatchTimeInterval = .milliseconds(120)
    static let settleDelay: DispatchTimeInterval = .milliseconds(300)

    private enum State: Sendable {
        case idle
        case collecting(AudioRecoveryTicket, causes: Set<AudioRecoveryCause>)
        case settling(AudioRecoveryTicket)
    }

    private var state: State = .idle
    private var nextTicketRawValue: UInt64? = 1

    mutating func ingest(_ cause: AudioRecoveryCause) -> [AudioRecoveryAction] {
        switch state {
        case .idle:
            switch cause {
            case .automaticFlush:
                return beginRecovery(ticket: nextTicket(), causes: [cause])
            case .outputConfigurationChanged, .routeChanged:
                let ticket = nextTicket()
                state = .collecting(ticket, causes: [cause])
                return [.scheduleCollection(ticket)]
            }

        case let .collecting(ticket, causes):
            switch cause {
            case .automaticFlush:
                return beginRecovery(ticket: ticket, causes: causes.union([cause]))
            case .outputConfigurationChanged, .routeChanged:
                state = .collecting(ticket, causes: causes.union([cause]))
                return []
            }

        case let .settling(ticket):
            switch cause {
            case .automaticFlush:
                return beginRecovery(ticket: nextTicket(), causes: [cause])
            case .outputConfigurationChanged, .routeChanged:
                return [.suppressed(ticket, cause: cause)]
            }
        }
    }

    mutating func collectionDeadlineFired(for ticket: AudioRecoveryTicket) -> [AudioRecoveryAction] {
        guard case let .collecting(activeTicket, causes) = state,
              activeTicket == ticket else {
            return []
        }
        return beginRecovery(ticket: ticket, causes: causes)
    }

    mutating func settleDeadlineFired(for ticket: AudioRecoveryTicket) -> [AudioRecoveryAction] {
        guard case let .settling(activeTicket) = state,
              activeTicket == ticket else {
            return []
        }
        state = .idle
        return []
    }

    mutating func invalidate() {
        state = .idle
    }

    func isActive(_ ticket: AudioRecoveryTicket) -> Bool {
        switch state {
        case .idle:
            return false
        case let .collecting(activeTicket, _), let .settling(activeTicket):
            return activeTicket == ticket
        }
    }

    private mutating func beginRecovery(
        ticket: AudioRecoveryTicket,
        causes: Set<AudioRecoveryCause>
    ) -> [AudioRecoveryAction] {
        state = .settling(ticket)
        return [
            .recover(ticket, causes: causes),
            .scheduleSettleExpiry(ticket)
        ]
    }

    private mutating func nextTicket() -> AudioRecoveryTicket {
        guard let rawValue = nextTicketRawValue else {
            preconditionFailure("Audio recovery ticket sequence exhausted")
        }
        nextTicketRawValue = rawValue == UInt64.max ? nil : rawValue + 1
        return AudioRecoveryTicket(rawValue: rawValue)
    }
}
