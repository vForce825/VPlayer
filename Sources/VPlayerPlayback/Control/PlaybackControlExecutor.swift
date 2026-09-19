// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch

enum PlaybackSafetyIngressApplication: Sendable, Equatable {
    case applied
    case failed(PlaybackSafetyFailure)
}

final class PlaybackControlExecutor: @unchecked Sendable {
    // 三个初始化hook及各自捕获；唯一保存在Cell，不在Executor重复保存。
    static var ingressHookValueBytes: Int {
        MemoryLayout<@Sendable (PlaybackSafetySnapshot) -> PlaybackSafetyIngressApplication>.stride +
        MemoryLayout<@Sendable (PlaybackSafetySnapshot) -> Void>.stride +
        MemoryLayout<@Sendable (OutputControlRequest, PlaybackSafetySnapshot) -> OutputControlApplication>.stride +
        5 * MemoryLayout<UnsafeRawPointer>.stride + 2 * MemoryLayout<any PlaybackMonotonicClock>.stride
    }
    let safetyIngress: SynchronousSafetyIngressCell
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()
    private let source: any DispatchSourceUserDataOr
    private weak var eventDrainRegistry: ControlTaskRegistry?

    /// applyIngress只注册一次，而且必须有真实权威状态接收者。
    /// 它在executor及cell锁内同步运行，禁止重入、SDK调用、await及资源析构；
    /// 旧引用必须转移到预留owned record，由锁外runner释放。
    /// clock也只注册一次：它必须是有界、不重入的单调时钟纯读取，实际采样在cell锁内。
    init(
        allocator: PlaybackIdentityAllocator = .shared,
        clock: any PlaybackMonotonicClock = DispatchPlaybackMonotonicClock(),
        applyIngress: @escaping @Sendable (PlaybackSafetySnapshot) -> PlaybackSafetyIngressApplication,
        applyTerminalIngress: @escaping @Sendable (PlaybackSafetySnapshot) -> Void,
        applyOutputControl: @escaping @Sendable (OutputControlRequest, PlaybackSafetySnapshot) -> OutputControlApplication
    ) {
        queue = DispatchQueue(label: "org.vplayer.playback.control", qos: .userInitiated)
        source = DispatchSource.makeUserDataOrSource(queue: queue)
        safetyIngress = SynchronousSafetyIngressCell(allocator: allocator, wakeSource: source, clock: clock,
            applyIngress: applyIngress, applyTerminalIngress: applyTerminalIngress, applyOutputControl: applyOutputControl)
        queue.setSpecific(key: key, value: 1)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            _ = self.withSafetyIngressBarrier(operationDescriptor: .drain) { _ in }
            self.eventDrainRegistry?.notifyPlaybackProgress()
            self.eventDrainRegistry?.drainOwnedEventRelays()
        }
        source.activate()
    }

    deinit { source.cancel() }

    var isIsolated: Bool { DispatchQueue.getSpecific(key: key) == 1 }

    /// 复用唯一预登记source；没有逐事件closure或第二队列。
    func bindEventDrainRegistry(_ registry: ControlTaskRegistry) {
        precondition(eventDrainRegistry == nil)
        eventDrainRegistry = registry
    }

    func signalOwnedEventDrain() { source.or(data: 1) }

    /// deadline source与资源准备共用唯一串行executor，投递栈不会在等待CAS时与另一准备峰重叠。
    func makePlaybackDeadlineTimer(clock: any PlaybackMonotonicClock) -> any PlaybackDeadlineTimer {
        clock.makeDeadlineTimer(deliveryQueue: queue)
    }

    /// 普通控制工作允许排队；framework安全callback只使用预登记source。
    func submit(_ operation: @escaping @Sendable () -> Void) { queue.async(execute: operation) }
    func sync(_ operation: () -> Void) {
        if isIsolated { operation() } else { queue.sync(execute: operation) }
    }

    /// 允许需要返回值或抛错的控制面状态机复用同一串行executor。
    func sync<Result>(_ operation: () throws -> Result) rethrows -> Result {
        if isIsolated { return try operation() }
        return try queue.sync(execute: operation)
    }
    func withSafetyIngressBarrier<Value>(
        operationDescriptor: PlaybackControlOperationDescriptor,
        operation: (inout PlaybackOutputSafetyState) -> Value
    ) -> PlaybackSafetyBarrierResult<Value> {
        precondition(isIsolated, "安全barrier必须持有共享控制executor串行权")
        return safetyIngress.withSafetyIngressBarrier(
            operationDescriptor: operationDescriptor, operation: operation
        )
    }

    func performUserControl(_ request: OutputUserControlRequest) -> OutputUserControlResult {
        defer { eventDrainRegistry?.notifyPlaybackProgress() }
        var result = OutputUserControlResult.rejected
        sync {
            while true {
                switch safetyIngress.performUserControl(request) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }

    func performAudioSessionCall(_ action: AudioSessionBlockingCallAction) -> AudioSessionBlockingCallApplication {
        defer { eventDrainRegistry?.notifyPlaybackProgress() }
        var result = AudioSessionBlockingCallApplication.rejected
        sync {
            while true {
                switch safetyIngress.performAudioSessionCall(action) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }

    func retireOutputControlRecord(_ ticket: ControlTaskTicket) -> OutputControlRecordRetirement {
        var result = OutputControlRecordRetirement.rejected
        sync {
            while true {
                switch safetyIngress.retireOutputControlRecord(ticket) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }

    func performOutputSuspend(_ action: OutputSuspendControlAction) -> OutputSuspendControlResult? {
        var result: OutputSuspendControlResult?
        sync {
            while true {
                switch safetyIngress.performOutputSuspend(action) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }

    func performPlaybackBudget(_ action: PlaybackBudgetControlAction) -> OutputControlApplication? {
        var result: OutputControlApplication?
        sync {
            while true {
                switch safetyIngress.performPlaybackBudget(action) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }

    func settleOutputInterruptionDrain(owner: OutputTransitionOwnerTicket) -> OutputInterruptionDrainSettlement {
        defer { eventDrainRegistry?.notifyPlaybackProgress() }
        var result = OutputInterruptionDrainSettlement.rejected
        sync {
            while true {
                switch safetyIngress.settleOutputInterruptionDrain(owner: owner) {
                case .retry: continue
                case .rejected: return
                case .performed(let value): result = value; return
                }
            }
        }
        return result
    }
}
