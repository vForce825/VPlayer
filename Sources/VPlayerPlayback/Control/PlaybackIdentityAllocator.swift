// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Darwin
import ObjectiveC

enum PlaybackIdentityNamespace: Int, CaseIterable, Sendable {
    case session, backend, outputLifecycle, prepare, activation
    case admissionFence, routeCommit, presentation, outputItem, mediaEpoch
    case resource, controlTask, lease, deadline, sequence, subscription, nonce
    case safetyIngress, systemEvent, mediaServices, interruption, resetRoot, freezeGeneration, intent
    case audioSessionActivationInvocation
    case audioSessionConfigurationGeneration
}

// 仅标识allocator来源；进程内不可复用，不保存播放状态或资源引用。
private final class PlaybackIdentityIssuerSequence: @unchecked Sendable {
    static let shared = PlaybackIdentityIssuerSequence()
    private let lock = NSLock()
    private var lastIssuer: UInt64 = 0

    func issue() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let (next, overflow) = lastIssuer.addingReportingOverflow(1)
        guard !overflow else { return nil }
        lastIssuer = next
        return next
    }
}

enum PlaybackIdentityAllocationError: Error, Equatable {
    case identitySpaceExhausted
}

final class PlaybackIdentityAllocator: @unchecked Sendable {
    static let shared = PlaybackIdentityAllocator()

    private let lock = NSLock()
    private var issued: [UInt64]
    private var exhausted = false
    let issuerIdentity: UInt64?
    // 本allocator的issuer、进程issuer序列与新增调用域counter均纳入控制容量。
    static var activationProvenanceValueBytes: Int { MemoryLayout<UInt64?>.stride + 2 * MemoryLayout<UInt64>.stride }
    // 独立配置generation域counter，不能隐含在上面的调用来源计费中。
    static var configurationProvenanceValueBytes: Int { MemoryLayout<UInt64>.stride }

    /// 单一allocator和进程issuer的真实对象本体；counter backing另外计，不重复收内联字段。
    static var fixedObjectAllocationBytes: Int {
        malloc_good_size(class_getInstanceSize(PlaybackIdentityAllocator.self)) +
            malloc_good_size(class_getInstanceSize(PlaybackIdentityIssuerSequence.self)) +
            2 * malloc_good_size(class_getInstanceSize(NSLock.self))
    }

    /// 同目标native Array的32-byte tail offset；固定26域，无扩容或数组逃逸。
    static var counterBackingAllocationBytes: Int {
        malloc_good_size(32 + PlaybackIdentityNamespace.allCases.count * MemoryLayout<UInt64>.stride)
    }

    init(initialIssuedValue: UInt64 = 0, initialNamespace: PlaybackIdentityNamespace? = nil) {
        issuerIdentity = PlaybackIdentityIssuerSequence.shared.issue()
        exhausted = issuerIdentity == nil
        issued = Array(repeating: initialNamespace == nil ? initialIssuedValue : 0,
            count: PlaybackIdentityNamespace.allCases.count)
        if let initialNamespace { issued[initialNamespace.rawValue] = initialIssuedValue }
    }

    func next(in namespace: PlaybackIdentityNamespace) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard !exhausted else { throw PlaybackIdentityAllocationError.identitySpaceExhausted }
        let index = namespace.rawValue
        let (next, overflow) = issued[index].addingReportingOverflow(1)
        guard !overflow else {
            exhausted = true
            throw PlaybackIdentityAllocationError.identitySpaceExhausted
        }
        issued[index] = next
        return next
    }

    var isExhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exhausted
    }

    /// Release亦可用的只读诊断：只在原allocator锁内同步借用原issued元素区间。
    /// 回调只取得整数地址/范围，不取得或保存Array/MutableBufferPointer。
    func inspectOriginalIssuedBackingAllocation(
        _ body: (String, VPMallocAllocationRange, UInt, Int) -> Void
    ) {
        lock.withLock {
            issued.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let borrowedBytes = buffer.count * MemoryLayout<UInt64>.stride
                let address = UInt(bitPattern: base)
                body("owned/identity allocator issued backing",
                     VPInspectMallocAllocationContainingRange(base, borrowedBytes),
                     address, borrowedBytes)
            }
        }
    }

    #if DEBUG
    /// 在成功建立真实播放上下文后，把单一命名空间推进到边界，避免伪造第二计数器。
    func setIssuedValueForTesting(
        _ value: UInt64,
        in namespace: PlaybackIdentityNamespace
    ) {
        lock.withLock { issued[namespace.rawValue] = value }
    }
    #endif

    /// 其他固定控制状态的checked计数器耗尽时，把共享身份发行器同步封口。
    /// 后续Registry barrier会据此撤销permit并折叠到原automatic terminal owner。
    func markIdentitySpaceExhausted() {
        lock.lock()
        exhausted = true
        lock.unlock()
    }
}
