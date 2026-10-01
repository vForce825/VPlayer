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
    private let hostTimeProvider: () -> CMTime
    // pause、anchor、setRate 由同一个播放执行器串行调用。
    private var pendingStartAnchor: (media: CMTime, host: CMTime, lead: CMTime)?

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
        anchor: @escaping (CMTime, CMTime, Float) -> Void,
        hostTime: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) {
        self.synchronizer = synchronizer
        currentTimeProvider = currentTime
        pauseAction = pause
        anchorAction = anchor
        hostTimeProvider = hostTime
    }

    public var currentTime: CMTime { currentTimeProvider() }

    public func pause() {
        pendingStartAnchor = nil
        pauseAction()
    }

    public func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        if rate == 0 {
            let now = hostTimeProvider()
            let lead = hostTime.isNumeric && now.isNumeric
                ? CMTimeMaximum(.zero, CMTimeSubtract(hostTime, now))
                : .zero
            pendingStartAnchor = (mediaTime, hostTime, lead)
        } else {
            pendingStartAnchor = nil
        }
        anchorAction(mediaTime, hostTime, rate)
    }

    public func setRate(_ rate: Float) {
        guard rate > 0, let pending = pendingStartAnchor else {
            if rate <= 0 { pendingStartAnchor = nil }
            synchronizer.rate = rate
            return
        }
        pendingStartAnchor = nil
        let now = hostTimeProvider()
        // 零速率锚点之后只改 rate 会丢掉未来启动时刻，必须连同时间映射一起启用。
        // 若授权已经迟到，重新预留起播时间，避免把等待授权当作已播放时间。
        let hostTime = now.isNumeric && pending.host.isNumeric
            && CMTimeCompare(now, pending.host) >= 0
            ? CMTimeAdd(now, pending.lead)
            : pending.host
        anchorAction(pending.media, hostTime, rate)
    }
}
