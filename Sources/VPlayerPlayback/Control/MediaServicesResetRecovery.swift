// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 媒体服务重置恢复调度器：负责固定配置重跑、Parent 预算继承与连续重置 (R2/R3) 边界收敛。
public final class MediaServicesResetRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private var parentAnchorInstant: UInt64?
    private var lastMandatorySuffix: UInt64 = 0
    private var resetCount: Int = 0

    public init() {}

    /// 连续 reset 记录与预算继承：首个 reset 记录 parentAnchorInstant，连续 reset (R2/R3) 继承原有 anchor 并确保 mandatory suffix 单调不减收敛。
    public func recordReset(at instant: UInt64, isHLS: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        resetCount += 1
        let candidateSuffix: UInt64 = isHLS ? 3_000_000_000 : 2_000_000_000
        if parentAnchorInstant == nil {
            parentAnchorInstant = instant
            lastMandatorySuffix = candidateSuffix
        } else {
            lastMandatorySuffix = max(lastMandatorySuffix, candidateSuffix)
        }
        return lastMandatorySuffix
    }

    /// 重置完成或被终止时清空状态。
    public func resetFinished() {
        lock.lock()
        defer { lock.unlock() }
        parentAnchorInstant = nil
        lastMandatorySuffix = 0
        resetCount = 0
    }

    public var currentAnchor: UInt64? {
        lock.withLock { parentAnchorInstant }
    }

    public var currentResetCount: Int {
        lock.withLock { resetCount }
    }
}
