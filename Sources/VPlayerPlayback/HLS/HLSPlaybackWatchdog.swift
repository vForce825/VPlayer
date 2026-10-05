// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Inline state for the Registry-owned AVPlayer observation deadline. Neither
/// rate admission nor a single clock sample establishes playback progress.
struct HLSPlaybackProgressWatch {
    private(set) var lastMediaTime: Double?
    private(set) var lastProgressInstant: UInt64?
    private(set) var hasObservedProgress = false
    private(set) var triggered = false
    static let timeoutNanoseconds: UInt64 = 3_000_000_000

    func nextPollDelay(at instant: UInt64) -> UInt64 {
        guard hasObservedProgress, let lastProgressInstant, instant >= lastProgressInstant else {
            return 250_000_000
        }
        let elapsed = instant - lastProgressInstant
        guard elapsed < Self.timeoutNanoseconds else { return 250_000_000 }
        return min(250_000_000, Self.timeoutNanoseconds - elapsed)
    }

    mutating func observe(mediaTime: Double?, at instant: UInt64) -> Bool {
        guard !triggered else { return false }
        if let mediaTime, mediaTime.isFinite {
            guard let previous = lastMediaTime else {
                lastMediaTime = mediaTime
                return false
            }
            if mediaTime > previous {
                lastMediaTime = mediaTime
                lastProgressInstant = instant
                hasObservedProgress = true
                return false
            }
        }
        // Invalid time on the same verified physical item is absence of
        // progress. It never seeds/arms startup, but cannot postpone an already
        // established stall or turn an expired deadline into a polling spin.
        guard hasObservedProgress, let lastProgressInstant,
              instant >= lastProgressInstant,
              instant - lastProgressInstant >= Self.timeoutNanoseconds else { return false }
        triggered = true
        return true
    }
}

/// Compatibility entry point for asynchronous stall/backlog callers. Native
/// AVPlayer progress uses HLSPlaybackProgressWatch on the Registry-owned timer;
/// both recovery entries converge on the same scoped Registry owner and budget.
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
    private var scopedSession: PlaybackSessionIdentity?
    private var scopedControlRevision: UInt64 = 0
    private var replacementGeneration: UInt64 = 0
    private var retiredThroughSessionID: UInt64?
    private var observationGeneration = UUID()

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
        guard currentActivationEpoch != activationEpoch || !isArmed else { return }
        observationGeneration = UUID()
        isArmed = true
        currentActivationEpoch = activationEpoch
        lastObservedProgressTime = now()
        recoveryScheduled = false
    }

    /// Session IDs come from the controller's monotonic identity allocator.
    /// Retain the latest identity across disarm so an old queued arm is rejected.
    func arm(activationEpoch: UInt64, hasObservedProgress: Bool,
             session: PlaybackSessionIdentity, controlRevision: UInt64) {
        guard accepts(session: session, controlRevision: controlRevision) else { return }
        arm(activationEpoch: activationEpoch, hasObservedProgress: hasObservedProgress)
    }

    func disarm(session: PlaybackSessionIdentity, controlRevision: UInt64) {
        guard accepts(session: session, controlRevision: controlRevision) else { return }
        disarm()
    }

    /// Fence replacement before its next session can arm. A delayed arm from
    /// any already-admitted predecessor remains retired even if its revision
    /// matches the last scoped arm; a delayed older replacement cannot disarm B.
    func beginReplacement(generation: UInt64, retiring session: PlaybackSessionIdentity?) {
        guard generation > replacementGeneration else { return }
        replacementGeneration = generation
        if let sessionID = session?.sessionID ?? scopedSession?.sessionID {
            retiredThroughSessionID = max(retiredThroughSessionID ?? sessionID, sessionID)
        }
        disarm()
    }

    private func accepts(session: PlaybackSessionIdentity, controlRevision: UInt64) -> Bool {
        if let retiredThroughSessionID, session.sessionID <= retiredThroughSessionID { return false }
        if let scopedSession {
            if session == scopedSession {
                guard controlRevision >= scopedControlRevision else { return false }
            } else {
                guard session.sessionID > scopedSession.sessionID else { return false }
            }
        }
        scopedSession = session
        scopedControlRevision = controlRevision
        return true
    }

    /// prepare、资源服务就绪、route debounce、handoff、用户暂停、系统中断和 permit revoke 均同步 freeze/cancel watchdog。
    public func disarm() {
        observationGeneration = UUID()
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
        guard isArmed, isPlaying, !recoveryScheduled else { return false }
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
        // Completion is not evidence of progress or a new activation. Keep the
        // one-shot latch closed until a newly scoped arm supplies that evidence.
    }

    private func triggerRecovery(reason: TriggerReason) {
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        lastTriggerReason = reason
        let generation = observationGeneration

        // Preserve the existing asynchronous entry, with revocation fencing.
        recoveryCoordinator.scheduleRecoveryTransaction { [weak self, reason] nonce in
            guard let self else { return }
            guard await self.acceptsRecovery(generation: generation),
                  !Task.isCancelled else { return }
            await self.recoveryCoordinator.handleWatchdogTrigger(reason: reason, nonce: nonce)
        }
    }

    private func acceptsRecovery(generation: UUID) -> Bool {
        generation == observationGeneration && recoveryScheduled
    }
}
