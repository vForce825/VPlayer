// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct AudioRendererRequestTicket: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64
}

struct AudioRendererPumpState: Sendable {
    enum RequestAction: Sendable, Equatable {
        case none
        case arm(ticket: AudioRendererRequestTicket, isRearm: Bool)
        case disarm(ticket: AudioRendererRequestTicket)
    }

    private var activeTicket: AudioRendererRequestTicket?
    private var hasRegisteredRequest = false
    private var nextTicketRawValue: UInt64?

    init(nextTicketRawValue: UInt64? = 1) {
        self.nextTicketRawValue = nextTicketRawValue
    }

    var isRequestArmed: Bool { activeTicket != nil }

    mutating func reconcile(
        hasPendingWork: Bool,
        keepArmedForProgress: Bool
    ) -> RequestAction {
        if hasPendingWork || keepArmedForProgress {
            guard activeTicket == nil,
                  let rawValue = nextTicketRawValue else { return .none }
            let ticket = AudioRendererRequestTicket(rawValue: rawValue)
            nextTicketRawValue = rawValue == UInt64.max ? nil : rawValue + 1
            let action = RequestAction.arm(
                ticket: ticket,
                isRearm: hasRegisteredRequest
            )
            activeTicket = ticket
            hasRegisteredRequest = true
            return action
        }

        return invalidateRegistration()
    }

    func isCurrent(_ ticket: AudioRendererRequestTicket) -> Bool {
        activeTicket == ticket
    }

    mutating func invalidateRegistration() -> RequestAction {
        guard let activeTicket else { return .none }
        self.activeTicket = nil
        return .disarm(ticket: activeTicket)
    }

    mutating func rendererDidChange() -> RequestAction {
        let action = invalidateRegistration()
        hasRegisteredRequest = false
        return action
    }
}
