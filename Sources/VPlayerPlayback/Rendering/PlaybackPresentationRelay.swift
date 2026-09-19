// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import ObjectiveC
import Synchronization

enum PlaybackPresentationRelayError: Error, Equatable {
    case subscriberAlreadyActive
    case identitySpaceExhausted
    case terminal
}

final class PlaybackPresentationRelay: @unchecked Sendable {
    fileprivate struct ActiveSubscription {
        let generation: UInt64
        var continuation: AsyncStream<PlaybackPresentationReplacement>.Continuation?
    }

    fileprivate struct DeliveryEffect: @unchecked Sendable {
        enum Kind { case replacement, terminal }
        let kind: Kind
        let replacement: PlaybackPresentationReplacement
        let continuation: AsyncStream<PlaybackPresentationReplacement>.Continuation
    }

    struct PreparedDelivery: @unchecked Sendable {
        fileprivate let drainerReservationRevision: UInt64?
        fileprivate let retiredDesired: IdentifiedPlaybackPresentation?
        fileprivate let retiredSubscription: ActiveSubscription?
    }

    enum PreparedReplacementOutcome: @unchecked Sendable {
        case prepared(PreparedDelivery)
        case identitySpaceExhausted(PreparedDelivery)
        case terminal(PreparedDelivery)
    }

    private let allocator: PlaybackIdentityAllocator
    private let lock = Mutex(())
    private var revision: UInt64
    private var desired: IdentifiedPlaybackPresentation?
    private var activeSubscription: ActiveSubscription?
    // 实例中只保留“需投递当前态”标志；effect快照在drainer栈上构造。
    private var replacementPending = false
    private var terminalPending = false
    private var drainerRunning = false
    private var drainerReservationRevision: UInt64?
    private var terminalDeliveryInFlight = false
    private var terminalClaimValid = false
    private var terminalClaimGeneration: UInt64 = 0
    private var terminalClaimRevision: UInt64 = 0
    private var terminal = false

    #if DEBUG
    private struct DeliveryHooksForTesting: @unchecked Sendable {
        let before: (@Sendable (UInt64, Bool) -> Void)?
        let after: (@Sendable (UInt64, Bool) -> Void)?
    }
    private static let deliveryHookLockForTesting = NSLock()
    nonisolated(unsafe) private static var deliveryHooksForTesting: [
        ObjectIdentifier: DeliveryHooksForTesting
    ] = [:]
    #endif

    static var allocationReservation: PlaybackPresentationAllocationReservation {
        func object(_ type: AnyClass) -> Int {
            malloc_good_size(class_getInstanceSize(type))
        }
        return .init(
            relayObject: object(PlaybackPresentationRelay.self),
            // 实例锁内联在relay对象中，不能重复记作独立heap allocation。
            relayLock: 0,
            // AsyncStream/Continuation的框架存储没有稳定公开allocation identity，沿用Task9的256B保守slab。
            asyncStreamOpaqueStorage: 256,
            newestBufferBacking: malloc_good_size(
                32 + MemoryLayout<PlaybackPresentationReplacement>.stride
            ),
            // onTermination是escaping closure；沿用Task9的32B context＋48B Block保守slab。
            terminationClosureContext: 80,
            // closure弱借用Relay；与Task9相同，每个唯一weak target只计一次32B side-table。
            relayWeakSideTable: 32,
            // Swift Task同样无法稳定取得完整heap链，沿用Task9单Task 512B保守slab。
            consumerTaskSlab: 512,
            // worker唯一escaping capture沿用Task9的80B；intent属于VM内联/async栈状态，
            // replacement本体由consumerInFlightEnvelope另计，不能在这里重复收费。
            consumerCaptureCompletionAndPendingIntent: 80,
            // MainActor worker只强持有这个弱owner，不强持有VM；对象与weak side-table分账。
            consumerOwnerObject: 32,
            consumerOwnerWeakSideTable: 32,
            // App层对象不能被Playback反向引用；这些值由同一tvOS目标的真实对象与
            // MemoryLayout校准，并由Task10容量测试逐项复核。
            mountObject: 192,
            hostOwnershipState: 136,
            hostWeakSideTable: 32,
            // SwiftUI coordinator直接复用mount，无额外包装allocation。
            coordinatorObject: 0,
            consumerInFlightEnvelope: MemoryLayout<PlaybackPresentationReplacement>.stride
        )
    }

    init(allocator: PlaybackIdentityAllocator = .shared, initialRevision: UInt64 = 0) {
        self.allocator = allocator
        revision = initialRevision
        PlaybackRuntimeAllocationReservations.validatePresentationAndGlobalCaps()
    }

    deinit {
        #if DEBUG
        let retired = Self.deliveryHookLockForTesting.withLock {
            Self.deliveryHooksForTesting.removeValue(forKey: ObjectIdentifier(self))
        }
        withExtendedLifetime(retired) {}
        #endif
    }

    var activeSubscriptionGeneration: UInt64? {
        lock.withLock { _ in activeSubscription?.generation }
    }

    #if DEBUG
    /// 仅供并发顺序测试使用；回调与continuation副作用都在Relay锁外。
    func setDeliveryHooksForTesting(
        before: (@Sendable (UInt64, Bool) -> Void)? = nil,
        after: (@Sendable (UInt64, Bool) -> Void)? = nil
    ) {
        let retired = Self.deliveryHookLockForTesting.withLock {
            let key = ObjectIdentifier(self)
            let retired = Self.deliveryHooksForTesting[key]
            if before == nil, after == nil {
                Self.deliveryHooksForTesting[key] = nil
            } else {
                Self.deliveryHooksForTesting[key] = .init(before: before, after: after)
            }
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    private func deliveryHooksSnapshotForTesting() -> DeliveryHooksForTesting? {
        Self.deliveryHookLockForTesting.withLock {
            Self.deliveryHooksForTesting[ObjectIdentifier(self)]
        }
    }
    #endif

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        let generation: UInt64
        do {
            generation = try lock.withLock { _ in
                guard !terminal else { throw PlaybackPresentationRelayError.terminal }
                guard activeSubscription == nil,
                      !terminalDeliveryInFlight else {
                    throw PlaybackPresentationRelayError.subscriberAlreadyActive
                }
                do {
                    let generation = try allocator.next(in: .subscription)
                    terminalClaimValid = false
                    activeSubscription = .init(generation: generation, continuation: nil)
                    return generation
                } catch {
                    throw PlaybackPresentationRelayError.identitySpaceExhausted
                }
            }
        } catch PlaybackPresentationRelayError.identitySpaceExhausted {
            deliver(finishAfterIdentityExhaustion())
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        }

        let pair = AsyncStream.makeStream(
            of: PlaybackPresentationReplacement.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            self?.terminateSubscription(generation)
        }
        let prepared = lock.withLock { _ -> PreparedDelivery? in
            guard !terminal, activeSubscription?.generation == generation else { return nil }
            activeSubscription?.continuation = pair.continuation
            // normal finish留下的tombstone由这个迟到订阅消费；否则先发当前目标。
            replacementPending = !terminalPending
            return .init(
                drainerReservationRevision: reserveDrainerLocked(),
                retiredDesired: nil,
                retiredSubscription: nil
            )
        }
        guard let prepared else {
            pair.continuation.finish()
            throw PlaybackPresentationRelayError.terminal
        }
        deliver(prepared)
        return pair.stream
    }

    func replace(with next: IdentifiedPlaybackPresentation?) throws {
        switch prepareAuthoritativeReplacement(with: next) {
        case .prepared(let prepared):
            deliver(prepared)
        case .identitySpaceExhausted(let terminalDelivery):
            deliver(terminalDelivery)
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        case .terminal(let empty):
            deliver(empty)
            throw PlaybackPresentationRelayError.terminal
        }
    }

    /// Registry在最终safety fence内只提交固定状态；实际continuation副作用由事务外单drainer执行。
    func prepareAuthoritativeReplacement(
        with next: IdentifiedPlaybackPresentation?
    ) -> PreparedReplacementOutcome {
        lock.withLock { _ in
            guard !terminal, !terminalDeliveryInFlight else {
                return .terminal(emptyDeliveryLocked())
            }
            if terminalPending {
                // normal finish只在尚未安装continuation时可被新的非nil目标重开。
                guard next != nil, activeSubscription?.continuation == nil else {
                    return .terminal(emptyDeliveryLocked())
                }
                terminalPending = false
            }
            guard !Self.samePresentation(desired, next) else {
                return .prepared(emptyDeliveryLocked())
            }
            let (nextRevision, overflow) = revision.addingReportingOverflow(1)
            // 最大值留给身份耗尽时的最终nil envelope。
            guard !overflow, nextRevision != UInt64.max else {
                return .identitySpaceExhausted(finishAfterIdentityExhaustionLocked())
            }
            revision = nextRevision
            let retiredDesired = desired
            desired = next
            guard activeSubscription?.continuation != nil else {
                return .prepared(.init(
                    drainerReservationRevision: nil,
                    retiredDesired: retiredDesired,
                    retiredSubscription: nil
                ))
            }
            replacementPending = true
            return .prepared(.init(
                drainerReservationRevision: reserveDrainerLocked(),
                retiredDesired: retiredDesired,
                retiredSubscription: nil
            ))
        }
    }

    /// Registry的mount claim在同一Cell事务内调用，必须验证完整envelope仍是当前值。
    func isExactCurrentReplacement(_ replacement: PlaybackPresentationReplacement) -> Bool {
        lock.withLock { _ in
            if terminalClaimValid,
               replacement.desired == nil,
               replacement.subscriptionGeneration == terminalClaimGeneration,
               replacement.revision == terminalClaimRevision {
                return true
            }
            guard !terminal,
                  activeSubscription?.generation == replacement.subscriptionGeneration,
                  revision == replacement.revision else { return false }
            return Self.samePresentation(desired, replacement.desired)
        }
    }

    func deliver(_ prepared: PreparedDelivery) {
        defer {
            withExtendedLifetime(prepared.retiredDesired) {}
            withExtendedLifetime(prepared.retiredSubscription) {}
        }
        guard let reservation = prepared.drainerReservationRevision else { return }
        let admitted = lock.withLock { _ in
            guard !drainerRunning,
                  drainerReservationRevision == reservation else { return false }
            drainerReservationRevision = nil
            drainerRunning = true
            return true
        }
        guard admitted else { return }
        while let effect = takeNextEffect() {
            deliver(effect)
        }
    }

    func finish() {
        let prepared = lock.withLock { _ -> PreparedDelivery in
            guard !terminal, !terminalPending, !terminalDeliveryInFlight else {
                return emptyDeliveryLocked()
            }
            let (nextRevision, overflow) = revision.addingReportingOverflow(1)
            if overflow {
                return finishAfterIdentityExhaustionLocked()
            }
            revision = nextRevision
            let retiredDesired = desired
            desired = nil
            replacementPending = false
            guard activeSubscription?.continuation != nil else {
                // 保留可重开terminal tombstone：若后续先提交非nil目标则覆盖，
                // 否则由当前尚未安装continuation或下一个订阅交付nil→EOF。
                terminalPending = true
                return .init(
                    drainerReservationRevision: nil,
                    retiredDesired: retiredDesired,
                    retiredSubscription: nil
                )
            }
            terminalPending = true
            return .init(
                drainerReservationRevision: reserveDrainerLocked(),
                retiredDesired: retiredDesired,
                retiredSubscription: nil
            )
        }
        deliver(prepared)
    }

    func terminateSubscription(_ generation: UInt64) {
        let retired = lock.withLock { _ -> ActiveSubscription? in
            guard activeSubscription?.generation == generation else { return nil }
            let retired = activeSubscription
            activeSubscription = nil
            replacementPending = false
            terminalPending = false
            drainerReservationRevision = nil
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    private func reserveDrainerLocked() -> UInt64? {
        guard !drainerRunning,
              replacementPending || terminalPending else { return nil }
        // 还未启动的旧reservation可被更高revision同步接管；旧deliver会CAS失败。
        drainerReservationRevision = revision
        return revision
    }

    private func takeNextEffect() -> DeliveryEffect? {
        lock.withLock { _ in
            guard let subscription = activeSubscription,
                  let continuation = subscription.continuation else {
                replacementPending = false
                terminalPending = false
                drainerRunning = false
                drainerReservationRevision = nil
                return nil
            }
            if terminalPending {
                terminalPending = false
                replacementPending = false
                terminalDeliveryInFlight = true
                return .init(
                    kind: .terminal,
                    replacement: .init(
                        subscriptionGeneration: subscription.generation,
                        revision: revision,
                        desired: nil
                    ),
                    continuation: continuation
                )
            }
            if replacementPending {
                replacementPending = false
                return .init(
                    kind: .replacement,
                    replacement: .init(
                        subscriptionGeneration: subscription.generation,
                        revision: revision,
                        desired: desired
                    ),
                    continuation: continuation
                )
            }
            drainerRunning = false
            drainerReservationRevision = nil
            return nil
        }
    }

    private func deliver(_ effect: DeliveryEffect) {
        let isTerminal = effect.kind == .terminal
        #if DEBUG
        let hooks = deliveryHooksSnapshotForTesting()
        hooks?.before?(effect.replacement.revision, isTerminal)
        #endif
        switch effect.kind {
        case .replacement:
            let remainsCurrent = lock.withLock { _ in
                !terminal && revision == effect.replacement.revision &&
                    activeSubscription?.generation == effect.replacement.subscriptionGeneration &&
                    Self.samePresentation(desired, effect.replacement.desired)
            }
            if remainsCurrent {
                consumeYieldResult(
                    effect.continuation.yield(effect.replacement),
                    generation: effect.replacement.subscriptionGeneration
                )
            }
        case .terminal:
            _ = effect.continuation.yield(effect.replacement)
            effect.continuation.finish()
            let retired = lock.withLock { _ -> ActiveSubscription? in
                terminalDeliveryInFlight = false
                terminalClaimValid = true
                terminalClaimGeneration = effect.replacement.subscriptionGeneration
                terminalClaimRevision = effect.replacement.revision
                guard activeSubscription?.generation == effect.replacement.subscriptionGeneration else {
                    return nil
                }
                let retired = activeSubscription
                activeSubscription = nil
                return retired
            }
            withExtendedLifetime(retired) {}
        }
        #if DEBUG
        hooks?.after?(effect.replacement.revision, isTerminal)
        #endif
    }

    private func consumeYieldResult(
        _ result: AsyncStream<PlaybackPresentationReplacement>.Continuation.YieldResult,
        generation: UInt64
    ) {
        switch result {
        case .enqueued:
            break
        case let .dropped(replacement):
            withExtendedLifetime(replacement) {}
        case .terminated:
            terminateSubscription(generation)
        @unknown default:
            terminateSubscription(generation)
        }
    }

    private func finishAfterIdentityExhaustion() -> PreparedDelivery {
        lock.withLock { _ in finishAfterIdentityExhaustionLocked() }
    }

    private func finishAfterIdentityExhaustionLocked() -> PreparedDelivery {
        guard !terminal else { return emptyDeliveryLocked() }
        terminal = true
        let retiredDesired = desired
        desired = nil
        let (terminalRevision, overflow) = revision.addingReportingOverflow(1)
        if !overflow { revision = terminalRevision }
        replacementPending = false
        terminalPending = false
        guard activeSubscription?.continuation != nil else {
            let retiredSubscription = activeSubscription
            activeSubscription = nil
            return .init(
                drainerReservationRevision: nil,
                retiredDesired: retiredDesired,
                retiredSubscription: retiredSubscription
            )
        }
        terminalPending = true
        return .init(
            drainerReservationRevision: reserveDrainerLocked(),
            retiredDesired: retiredDesired,
            retiredSubscription: nil
        )
    }

    private func emptyDeliveryLocked() -> PreparedDelivery {
        .init(
            drainerReservationRevision: nil,
            retiredDesired: nil,
            retiredSubscription: nil
        )
    }

    private static func samePresentation(
        _ lhs: IdentifiedPlaybackPresentation?,
        _ rhs: IdentifiedPlaybackPresentation?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard lhs.identity == rhs.identity else { return false }
            switch (lhs.presentation, rhs.presentation) {
            case let (.sampleBuffer(left), .sampleBuffer(right)):
                return left === right
            case let (.avPlayer(left), .avPlayer(right)):
                return left === right
            default:
                return false
            }
        default:
            return false
        }
    }
}
