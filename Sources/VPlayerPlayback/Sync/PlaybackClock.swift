// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

public protocol PlaybackClock: AnyObject {
    var currentTime: CMTime { get }
    func pause()
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float)
    func setRate(_ rate: Float)
}

/// 共享时间线的音频提前量调节策略；决策本身不具备输出授权。
struct PlaybackAudioSupplyClockPolicy {
    private static let observationWindow: TimeInterval = 30
    private static let responseTime: TimeInterval = 120
    private static let maximumCorrection = 0.002
    private static let minimumRateChange: Float = 0.0001
    private var windowStartedAt: TimeInterval?
    private var minimumObservedLead = Double.infinity
    private var lastMonotonicTime: TimeInterval?
    private var lastClockTime: Double?
    private var lastAcceptedEnd: Double?
    private var multiplier: Float = 1

    mutating func observe(
        acceptedEnd: CMTime,
        clockTime: CMTime,
        monotonicTime: TimeInterval,
        targetLead: CMTime
    ) -> Float? {
        let end = acceptedEnd.seconds
        let clock = clockTime.seconds
        let target = targetLead.seconds
        guard acceptedEnd.isNumeric, clockTime.isNumeric, targetLead.isNumeric,
              end.isFinite, clock.isFinite, target.isFinite, target > 0,
              monotonicTime.isFinite else {
            reset(keepingMultiplier: multiplier)
            return nil
        }
        if lastMonotonicTime.map({ monotonicTime < $0 }) == true
            || lastClockTime.map({ clock < $0 - 0.001 }) == true
            || lastAcceptedEnd.map({ end < $0 - 0.001 }) == true {
            reset(keepingMultiplier: multiplier)
        }
        lastMonotonicTime = monotonicTime
        lastClockTime = clock
        lastAcceptedEnd = end
        if windowStartedAt == nil { windowStartedAt = monotonicTime }
        minimumObservedLead = min(minimumObservedLead, end - clock)
        guard let start = windowStartedAt,
              monotonicTime - start >= Self.observationWindow else { return nil }

        // 使用有界窗口的低水位，过滤成批交付和短暂抖动；不追逐每个访问单元。
        let leadError = minimumObservedLead - target
        windowStartedAt = monotonicTime
        minimumObservedLead = end - clock
        let correction = max(-Self.maximumCorrection,
                             min(Self.maximumCorrection, leadError / Self.responseTime))
        let nextMultiplier = Float(1 + correction)
        guard abs(nextMultiplier - multiplier) >= Self.minimumRateChange else { return nil }
        multiplier = nextMultiplier
        return multiplier
    }

    mutating func reset(keepingMultiplier currentMultiplier: Float = 1) {
        windowStartedAt = nil
        minimumObservedLead = .infinity
        lastMonotonicTime = nil
        lastClockTime = nil
        lastAcceptedEnd = nil
        multiplier = currentMultiplier.isFinite
            ? max(0.998, min(1.002, currentMultiplier)) : 1
    }
}
