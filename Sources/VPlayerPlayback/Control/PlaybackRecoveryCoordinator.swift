// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 协调全路由热切换、中断、重置与格式恢复的单槽恢复事务调度器。
public final class PlaybackRecoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let allocator: PlaybackIdentityAllocator
    private var activeRecoveryTask: Task<Void, Never>?
    private var activeRecoveryTaskId: UInt64 = 0
    private var currentRecoveryNonce: UInt64 = 0
    private var routeUnavailableTask: Task<Void, Never>?
    private var currentRouteUnavailableNonce: UInt64 = 0

    public typealias WatchdogRecoveryHandler = @Sendable (HLSPlaybackWatchdog.TriggerReason, UInt64) async -> Void
    private var watchdogRecoveryHandler: WatchdogRecoveryHandler?

    public let resetRecovery: MediaServicesResetRecovery

    public init(resetRecovery: MediaServicesResetRecovery = MediaServicesResetRecovery()) {
        self.resetRecovery = resetRecovery
        self.allocator = .shared
    }

    init(
        resetRecovery: MediaServicesResetRecovery = MediaServicesResetRecovery(),
        allocator: PlaybackIdentityAllocator
    ) {
        self.resetRecovery = resetRecovery
        self.allocator = allocator
    }

    public func setWatchdogRecoveryHandler(_ handler: @escaping WatchdogRecoveryHandler) {
        lock.withLock { watchdogRecoveryHandler = handler }
    }

    public func handleWatchdogTrigger(reason: HLSPlaybackWatchdog.TriggerReason, nonce: UInt64) async {
        let handler = lock.withLock { watchdogRecoveryHandler }
        if let handler {
            await handler(reason, nonce)
        }
    }

    /// 取消当前正在执行的恢复任务（例如在 stop、newPlay 或终端失败时）。
    public func cancelCurrentRecovery() {
        let (task, noneTask): (Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            let t = activeRecoveryTask
            activeRecoveryTask = nil
            if let nextTaskId = try? allocator.next(in: .controlTask) {
                activeRecoveryTaskId = nextTaskId
            }
            let nt = routeUnavailableTask
            routeUnavailableTask = nil
            if let nextRecoveryNonce = try? allocator.next(in: .nonce) {
                currentRecoveryNonce = nextRecoveryNonce
            }
            if let nextRouteNonce = try? allocator.next(in: .nonce) {
                currentRouteUnavailableNonce = nextRouteNonce
            }
            return (t, nt)
        }
        task?.cancel()
        noneTask?.cancel()
        resetRecovery.resetFinished()
    }

    /// 启动唯一的单槽恢复任务，任何并发的新恢复均合并或排队于单槽中。
    public func scheduleRecoveryTransaction(
        operation: @escaping @Sendable (UInt64) async -> Void
    ) {
        lock.withLock {
            guard let nonce = try? allocator.next(in: .nonce),
                  let taskId = try? allocator.next(in: .controlTask) else { return }
            currentRecoveryNonce = nonce
            activeRecoveryTaskId = taskId
            let previous = activeRecoveryTask

            let newTask = Task {
                if let previous {
                    _ = await previous.result
                }
                guard !Task.isCancelled else { return }
                await operation(nonce)
                self.lock.withLock {
                    if self.activeRecoveryTaskId == taskId {
                        self.activeRecoveryTask = nil
                    }
                }
            }
            activeRecoveryTask = newTask
        }
    }

    /// 等待当前单槽恢复事务全部结清。
    public func waitForCurrentRecovery() async {
        while true {
            let (task, taskId): (Task<Void, Never>?, UInt64) = lock.withLock {
                (activeRecoveryTask, activeRecoveryTaskId)
            }
            guard let task else { break }
            _ = await task.result
            lock.withLock {
                if self.activeRecoveryTaskId == taskId {
                    self.activeRecoveryTask = nil
                }
            }
        }
    }

    /// 处理路由不可用 (.none) 状态：挂起输出并等待至多 3.0 秒的路由恢复窗口。
    func handleRouteUnavailable(
        controller: PlaybackController,
        runIdentity: PlaybackRunIdentity,
        request: PlaybackRequest
    ) {
        let (_, oldTask): (Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            let old = routeUnavailableTask
            guard let nonce = try? allocator.next(in: .nonce) else {
                return (nil, old)
            }
            currentRouteUnavailableNonce = nonce

            let t = Task {
                // 3.0 秒等待窗口（若在此期间收到新的有效 route commit，本任务会被 cancel）
                try? await Task.sleep(nanoseconds: 3_000_000_000)

                guard !Task.isCancelled else { return }
                guard self.isCurrentRouteUnavailableNonce(nonce) else { return }

                // 3.0 秒超时未恢复，进入终态失败并收敛会话清理
                await controller.handleRouteUnavailableTimeout()
            }
            routeUnavailableTask = t
            return (t, old)
        }
        oldTask?.cancel()
    }

    /// 当收到有效路由时取消 .none 路由超时。
    public func cancelRouteUnavailableTimeout() {
        let task = lock.withLock {
            if let nextNonce = try? allocator.next(in: .nonce) {
                currentRouteUnavailableNonce = nextNonce
            }
            let t = routeUnavailableTask
            routeUnavailableTask = nil
            return t
        }
        task?.cancel()
    }

    public func isCurrentNonce(_ nonce: UInt64) -> Bool {
        lock.withLock { currentRecoveryNonce == nonce }
    }

    public func isCurrentRouteUnavailableNonce(_ nonce: UInt64) -> Bool {
        lock.withLock { currentRouteUnavailableNonce == nonce }
    }
}
