// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFAudio
import Foundation

public final class DefaultAudioRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {
    public init() {}
    public func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void) {
        handler(AudioOutputRouteSnapshot(ports: [.other], category: .other, reason: .initial, revision: 0))
    }
    public func stop() {}
    public func resample(reason: AudioRouteChangeReason) {}
}

public final class AudioOutputRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {
    private let service: PlaybackAudioRouteService

    public init(service: PlaybackAudioRouteService) {
        self.service = service
    }

    public func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void) {
        service.addSubscriber(handler)
    }

    public func stop() {
        service.removeSubscriber()
    }

    public func resample(reason: AudioRouteChangeReason) {
        service.resample(reason: reason)
    }
}
