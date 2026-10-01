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
    struct HostMapping {
        let media: CMTime
        let host: CMTime
    }
    private let rateMappingProvider: () -> HostMapping?
    // pause、anchor、setRate 由同一个播放执行器串行调用。
    private var pendingStartAnchor: (media: CMTime, host: CMTime, lead: CMTime)?
    private var lastRequestedRate: Float = 0

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
        hostTime: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
        rateMapping: (() -> HostMapping?)? = nil
    ) {
        self.synchronizer = synchronizer
        currentTimeProvider = currentTime
        pauseAction = pause
        anchorAction = anchor
        hostTimeProvider = hostTime
        rateMappingProvider = rateMapping ?? { Self.currentHostMapping(for: synchronizer) }
    }

    public var currentTime: CMTime { currentTimeProvider() }

    public func pause() {
        pendingStartAnchor = nil
        lastRequestedRate = 0
        pauseAction()
    }

    public func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        lastRequestedRate = rate
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
        defer { lastRequestedRate = rate }
        guard rate > 0, let pending = pendingStartAnchor else {
            if rate <= 0 { pendingStartAnchor = nil }
            if rate != lastRequestedRate,
               (Float(0.998)...Float(1.002)).contains(rate),
               (Float(0.998)...Float(1.002)).contains(lastRequestedRate) {
                // 从系统的一致映射投影到当前 host，避免独立读取两个时间造成相位跳变。
                if let mapping = rateMappingProvider() {
                    anchorAction(mapping.media, mapping.host, rate)
                    return
                }
            }
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

    private static func currentHostMapping(for synchronizer: AVSampleBufferRenderSynchronizer) -> HostMapping? {
        let hostClock = CMClockGetHostTimeClock()
        var relativeRate = Double.nan
        var mediaAnchor = CMTime.invalid
        var hostAnchor = CMTime.invalid
        guard CMSyncGetRelativeRateAndAnchorTime(
            synchronizer.timebase, relativeTo: hostClock,
            relativeRateOut: &relativeRate, anchorTimeOut: &mediaAnchor,
            relativeToAnchorTimeOut: &hostAnchor
        ) == noErr else { return nil }
        return hostMapping(
            relativeRate: relativeRate, mediaAnchor: mediaAnchor, hostAnchor: hostAnchor,
            currentHost: CMClockGetTime(hostClock)
        )
    }

    static func hostMapping(
        relativeRate: Double, mediaAnchor: CMTime, hostAnchor: CMTime, currentHost: CMTime
    ) -> HostMapping? {
        func valid(_ time: CMTime) -> Bool { time.isNumeric && time.seconds.isFinite }
        guard relativeRate.isFinite, relativeRate > 0,
              valid(mediaAnchor), valid(hostAnchor), valid(currentHost),
              CMTimeCompare(currentHost, .zero) >= 0 else { return nil }
        let elapsed = CMTimeSubtract(currentHost, hostAnchor)
        guard valid(elapsed) else { return nil }
        let advance = CMTimeMultiplyByFloat64(elapsed, multiplier: relativeRate)
        guard valid(advance) else { return nil }
        let media = CMTimeAdd(mediaAnchor, advance)
        guard valid(media), CMTimeCompare(media, .zero) >= 0 else { return nil }
        return HostMapping(media: media, host: currentHost)
    }
}
