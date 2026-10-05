// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

/// One canonical driver/presentation for one Registry-owned HomePod session.
/// Internal native/proxy/generated adapters share this lease; none create players.
@MainActor
final class HomePodAVPlayerSession {
    let identity: PlaybackSessionIdentity
    private let driver: any AVPlayerDriving
    private let presentation: AVPlayerPresentationContext?
    private let retention: HLSApplicationLifetimeCharge
    private var claimed: PlaybackBackendIdentity?

    init(identity: PlaybackSessionIdentity, preferredForwardBufferDuration: TimeInterval) throws {
        retention = try HLSApplicationLifetimeCharge(bytes: 4 * 1_024)
        self.identity = identity
        let system = try SystemAVPlayerDriver.make(preferredForwardBufferDuration: preferredForwardBufferDuration)
        driver = system
        presentation = AVPlayerPresentationContext(player: system.player)
    }
    /// Explicit driver injection exercises the same session/adapter ownership.
    /// Only the production initializer constructs a physical AVPlayer.
    init(identity: PlaybackSessionIdentity, driver: any AVPlayerDriving, presentation: AVPlayerPresentationContext? = nil) throws {
        retention = try HLSApplicationLifetimeCharge(bytes: 4 * 1_024)
        self.identity = identity; self.driver = driver; self.presentation = presentation
    }
    func claim(backend: PlaybackBackendIdentity) throws -> Lease {
        guard claimed == nil, backend.sessionIdentity == identity else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        claimed = backend
        return Lease(owner: self, backend: backend)
    }
    final class Lease: @unchecked Sendable {
        private let owner: HomePodAVPlayerSession
        let backend: PlaybackBackendIdentity
        fileprivate init(owner: HomePodAVPlayerSession, backend: PlaybackBackendIdentity) { self.owner = owner; self.backend = backend }
        @MainActor var driver: any AVPlayerDriving { owner.driver }
        @MainActor var presentation: AVPlayerPresentationContext? { owner.presentation }
    }
}
