// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia

public final class RenderSynchronizerClock: PlaybackClock, @unchecked Sendable {
    public let synchronizer: AVSampleBufferRenderSynchronizer

    private let currentTimeProvider: () -> CMTime
    private let pauseAction: () -> Void
    private let anchorAction: (CMTime, CMTime, Float) -> Void

    public convenience init(synchronizer: AVSampleBufferRenderSynchronizer) {
        self.init(
            synchronizer: synchronizer,
            currentTime: { synchronizer.currentTime() },
            pause: { synchronizer.rate = 0 },
            anchor: { synchronizer.setRate($2, time: $0, atHostTime: $1) }
        )
    }

    init(
        synchronizer: AVSampleBufferRenderSynchronizer,
        currentTime: @escaping () -> CMTime,
        pause: @escaping () -> Void,
        anchor: @escaping (CMTime, CMTime, Float) -> Void
    ) {
        self.synchronizer = synchronizer
        currentTimeProvider = currentTime
        pauseAction = pause
        anchorAction = anchor
    }

    public var currentTime: CMTime { currentTimeProvider() }

    public func pause() {
        pauseAction()
    }

    public func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        anchorAction(mediaTime, hostTime, rate)
    }
}
