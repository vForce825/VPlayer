// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 监控 HLS 播放停滞、缓冲区饥饿与容量积压的看门狗。
/// 任何停滞、饥饿或积压触发时，严格只走统一恢复调度器（PlaybackRecoveryCoordinator）。
public actor HLSPlaybackWatchdog {
    public typealias Now = @Sendable () -> TimeInterval

    public enum TriggerReason: String, Sendable, Equatable {
        case playbackStalled = "hls.watchdog.stalled"
        case bufferStarvation = "hls.watchdog.starvation"
        case prepareBacklogExceeded = "hls.watchdog.prepare-backlog"
        case playbackBacklogExceeded = "hls.watchdog.playback-backlog"
        case hardCapacityExceeded = "hls.watchdog.hard-capacity"
    }

    public struct Configuration: Sendable {
        public var prepareBacklogTimeout: TimeInterval
        public var playbackBacklogTimeout: TimeInterval
        public var playbackStallTimeout: TimeInterval
        public var bufferStarvationTimeout: TimeInterval

        public init(
            prepareBacklogTimeout: TimeInterval = 2.0,
            playbackBacklogTimeout: TimeInterval = 3.0,
            playbackStallTimeout: TimeInterval = 3.0,
            bufferStarvationTimeout: TimeInterval = 3.0
        ) {
            self.prepareBacklogTimeout = prepareBacklogTimeout
            self.playbackBacklogTimeout = playbackBacklogTimeout
            self.playbackStallTimeout = playbackStallTimeout
            self.bufferStarvationTimeout = bufferStarvationTimeout
        }
    }

    private let recoveryCoordinator: PlaybackRecoveryCoordinator
    private let now: Now
    private let configuration: Configuration

    public private(set) var isArmed: Bool = false
    public private(set) var currentActivationEpoch: UInt64? = nil
    public private(set) var lastObservedProgressTime: TimeInterval = 0
    public private(set) var lastMediaTime: Double? = nil
    public private(set) var lastTriggerReason: TriggerReason? = nil

    private var softCapBacklogStartTime: TimeInterval? = nil
    private var starvationStartTime: TimeInterval? = nil
    private var recoveryScheduled: Bool = false

    public init(
        recoveryCoordinator: PlaybackRecoveryCoordinator,
        configuration: Configuration = Configuration(),
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.recoveryCoordinator = recoveryCoordinator
        self.configuration = configuration
        self.now = now
    }

    /// 依设计 10.2 & 11：只在当前 generation 已持有有效 activation permit 且至少观察过一次播放进展时 arm。
    public func arm(activationEpoch: UInt64, hasObservedProgress: Bool) {
        guard hasObservedProgress else { return }
        isArmed = true
        currentActivationEpoch = activationEpoch
        lastObservedProgressTime = now()
        recoveryScheduled = false
    }

    /// prepare、资源服务就绪、route debounce、handoff、用户暂停、系统中断和 permit revoke 均同步 freeze/cancel watchdog。
    public func disarm() {
        isArmed = false
        currentActivationEpoch = nil
        lastMediaTime = nil
        softCapBacklogStartTime = nil
        starvationStartTime = nil
        recoveryScheduled = false
    }

    /// 记录媒体时间进展（PTS 推进）。
    public func recordMediaProgress(mediaTimeSeconds: Double) {
        guard isArmed else { return }
        let currentTime = now()
        if let last = lastMediaTime {
            if mediaTimeSeconds > last {
                lastMediaTime = mediaTimeSeconds
                lastObservedProgressTime = currentTime
            }
        } else {
            lastMediaTime = mediaTimeSeconds
            lastObservedProgressTime = currentTime
        }
    }

    /// 记录缓冲区状态（数据生产或饥饿）。
    public func recordBufferStatus(hasData: Bool) -> Bool {
        let currentTime = now()
        if hasData {
            starvationStartTime = nil
            return false
        }
        guard isArmed else { return false }
        if starvationStartTime == nil {
            starvationStartTime = currentTime
            return false
        }
        if let start = starvationStartTime, currentTime - start >= configuration.bufferStarvationTimeout {
            triggerRecovery(reason: .bufferStarvation)
            return true
        }
        return false
    }

    /// 轮询评估播放进展。若播放中超过 stallTimeout 无进展，触发停滞恢复。
    public func pollAndEvaluate(currentTimeSeconds: Double, isPlaying: Bool) -> Bool {
        guard isArmed, isPlaying else { return false }
        let currentTime = now()
        if let last = lastMediaTime {
            if currentTimeSeconds > last {
                lastMediaTime = currentTimeSeconds
                lastObservedProgressTime = currentTime
                return false
            }
        } else {
            lastMediaTime = currentTimeSeconds
        }
        if currentTime - lastObservedProgressTime >= configuration.playbackStallTimeout {
            triggerRecovery(reason: .playbackStalled)
            return true
        }
        return false
    }

    /// 记录容量积压状态。
    /// - rate-0 prepare 期间任一 soft cap 连续 2 秒不下降，触发失败与重建；
    /// - 播放期间连续 3 秒不下降，触发 full rebuild；
    /// - 任一 hard cap 被越过时立即走相同失败/恢复入口。
    public func recordBacklogState(
        isSoftCapExceeded: Bool,
        isHardCapExceeded: Bool,
        isPreparePhase: Bool
    ) -> Bool {
        if isHardCapExceeded {
            recoveryScheduled = false
            triggerRecovery(reason: .hardCapacityExceeded)
            return true
        }
        let currentTime = now()
        if isSoftCapExceeded {
            if softCapBacklogStartTime == nil {
                softCapBacklogStartTime = currentTime
            }
            let elapsed = currentTime - (softCapBacklogStartTime ?? currentTime)
            let threshold = isPreparePhase ? configuration.prepareBacklogTimeout : configuration.playbackBacklogTimeout
            if elapsed >= threshold {
                triggerRecovery(reason: isPreparePhase ? .prepareBacklogExceeded : .playbackBacklogExceeded)
                return true
            }
        } else {
            softCapBacklogStartTime = nil
        }
        return false
    }

    public func markRecoveryCompleted() {
        recoveryScheduled = false
    }

    private func triggerRecovery(reason: TriggerReason) {
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        lastTriggerReason = reason

        // 统一规则：HLS stalled/backlog/watchdog fires ONLY route through PlaybackRecoveryCoordinator
        recoveryCoordinator.scheduleRecoveryTransaction { [weak self, reason] nonce in
            guard let self else { return }
            await self.recoveryCoordinator.handleWatchdogTrigger(reason: reason, nonce: nonce)
            await self.markRecoveryCompleted()
        }
    }
}
