// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import os

enum PlaybackSignpostSpan: Sendable {
    case videoToolboxDecode
    case scanProbe
    case yadifCommandBuffer
    case renderDraw
    case modeSwitch
    case reanchor
}

struct PlaybackSignpostToken: @unchecked Sendable {
    let span: PlaybackSignpostSpan
    let state: OSSignpostIntervalState
}

final class PlaybackSignpostLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let signposts: PlaybackSignposts?
    private var token: PlaybackSignpostToken?

    init(signposts: PlaybackSignposts?, token: PlaybackSignpostToken?) {
        self.signposts = signposts
        self.token = token
    }

    func finish() {
        let token = lock.withLock { () -> PlaybackSignpostToken? in
            defer { self.token = nil }
            return self.token
        }
        if let token { signposts?.end(token) }
    }
}

final class PlaybackSignposts: @unchecked Sendable {
    private let signposter = OSSignposter(
        subsystem: "org.vplayer.playback",
        category: "Playback"
    )
    private let channelIdentifier: PlaybackDiagnosticsChannelID

    init(channelIdentifier: PlaybackDiagnosticsChannelID) {
        self.channelIdentifier = channelIdentifier
    }

    func begin(_ span: PlaybackSignpostSpan, correlation: UInt64) -> PlaybackSignpostToken {
        let identifier = signposter.makeSignpostID()
        let channel = channelIdentifier.value
        let state: OSSignpostIntervalState
        switch span {
        case .videoToolboxDecode:
            state = signposter.beginInterval(
                "VT decode",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        case .scanProbe:
            state = signposter.beginInterval(
                "Scan probe",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        case .yadifCommandBuffer:
            state = signposter.beginInterval(
                "YADIF command buffer",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        case .renderDraw:
            state = signposter.beginInterval(
                "Render draw",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        case .modeSwitch:
            state = signposter.beginInterval(
                "Mode switch",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        case .reanchor:
            state = signposter.beginInterval(
                "Reanchor",
                id: identifier,
                "channel=\(channel, privacy: .public) correlation=\(correlation)"
            )
        }
        return PlaybackSignpostToken(span: span, state: state)
    }

    func end(_ token: PlaybackSignpostToken) {
        switch token.span {
        case .videoToolboxDecode:
            signposter.endInterval("VT decode", token.state)
        case .scanProbe:
            signposter.endInterval("Scan probe", token.state)
        case .yadifCommandBuffer:
            signposter.endInterval("YADIF command buffer", token.state)
        case .renderDraw:
            signposter.endInterval("Render draw", token.state)
        case .modeSwitch:
            signposter.endInterval("Mode switch", token.state)
        case .reanchor:
            signposter.endInterval("Reanchor", token.state)
        }
    }
}
