// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia

public final class RenderSynchronizerClock: PlaybackClock, @unchecked Sendable {
    public let synchronizer: AVSampleBufferRenderSynchronizer

    private let currentTimeProvider: () -> CMTime
    private let hostTimeConverter: (CMTime) -> CMTime
    private let pauseAction: () -> Void
    private let anchorAction: (CMTime, CMTime, Float) -> Void
    private let latencyLock = NSLock()
    private var outputLatency: CMTime = .zero

    public convenience init(synchronizer: AVSampleBufferRenderSynchronizer) {
        self.init(
            synchronizer: synchronizer,
            currentTime: { synchronizer.currentTime() },
            convertHostTime: {
                CMSyncConvertTime(
                    $0,
                    from: CMClockGetHostTimeClock(),
                    to: synchronizer.timebase
                )
            },
            pause: { synchronizer.rate = 0 },
            anchor: { synchronizer.setRate($2, time: $0, atHostTime: $1) }
        )
    }

    init(
        synchronizer: AVSampleBufferRenderSynchronizer,
        currentTime: @escaping () -> CMTime,
        convertHostTime: @escaping (CMTime) -> CMTime,
        pause: @escaping () -> Void,
        anchor: @escaping (CMTime, CMTime, Float) -> Void
    ) {
        self.synchronizer = synchronizer
        currentTimeProvider = currentTime
        hostTimeConverter = convertHostTime
        pauseAction = pause
        anchorAction = anchor
    }

    public var currentTime: CMTime { currentTimeProvider() }

    public func mediaTime(forHostTime hostTime: CMTime) -> CMTime {
        let latency = latencyLock.withLock { outputLatency }
        let effectiveHostTime = CMTimeSubtract(hostTime, latency)
        guard effectiveHostTime.isNumeric else {
            return hostTimeConverter(hostTime)
        }
        return hostTimeConverter(effectiveHostTime)
    }

    public func pause() {
        pauseAction()
    }

    public func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        anchorAction(mediaTime, hostTime, rate)
    }

    public func setAudioOutputLatency(_ latency: CMTime) {
        latencyLock.withLock {
            if latency.isNumeric, CMTimeCompare(latency, .zero) >= 0 {
                outputLatency = latency
            } else {
                outputLatency = .zero
            }
        }
    }
}
