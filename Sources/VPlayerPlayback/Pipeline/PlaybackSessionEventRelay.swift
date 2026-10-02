// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import ObjectiveC
import Synchronization
import VPlayerCore

struct PlaybackRunIdentity: Equatable, Sendable {
    let sessionID: UInt64
    let requestID: UUID
}


/// Fixed native payload storage. Tags describe exactly which value is initialized
/// in a slot; no typed pointer survives a move/deinitialize followed by rebinding.
/// PlaybackFailure's flattened fields are guarded by a schema regression test.
enum PlaybackPipelineEventStorage {
    static let payloadStride = 48
    static let payloadAlignment = 8
    static let emptyTag: UInt16 = 0

    typealias PresentedPayload = (String, String, String?)
    typealias MediaPayload = (PlaybackMediaInformation?, MediaGeneration)
    typealias UnexpectedPayload = (String, ErrorDiagnosticSnapshot)
    typealias BackendPayload = (ErrorDiagnosticSnapshot, PlaybackBackendPrepareFailureScope,
        HLSRuntimeFailureMetadataOwner)
    typealias FFmpegPayload = (FFmpegFailureKind, FFmpegFailureStage, Int32)

    private enum Tag: UInt16 {
        case empty, stopped, ready, buffering, recovering, mediaWithoutGeneration, mediaWithGeneration
        case unsupportedProtocol, demuxOpen, demuxRead, ffmpegFailure, networkTimeout
        case unsupportedVideoCodec, unsupportedAudioCodec, videoFormatDescription
        case hardwareDecoderUnavailable, videoDecoderTransitionTimeout, videoDecode, videoDecoderFailure
        case videoSampleBuffer, videoRendererFailed, audioFormatDescription, audioFallbackDecode
        case audioRendererFailed, renderTextureMapping, metalCommand, cancelled
        case controlEventCapacityExceeded, outputActivationRejected, backendPublicationReplacementRejected
        case presentedRetry, presentedChooseChannel, presentedDoNotRetry, unexpected, backendFailed
    }

    /// Executed before allocation/binding in Release too. A changed SDK payload
    /// fails closed instead of overwriting the next fixed slot.
    static func validateLayout() {
        validate(PresentedPayload.self)
        validate(MediaPayload.self)
        validate(PlaybackMediaInformation?.self)
        validate(UnexpectedPayload.self)
        validate(BackendPayload.self)
        validate(FFmpegPayload.self)
        validate(VideoDecoderFailure.self)
        validate(String.self)
        validate(Int32.self)
        validate(UInt64.self)
        precondition(MemoryLayout<UInt16>.stride == 2 && Tag.empty.rawValue == emptyTag)
    }

    private static func validate<T>(_ type: T.Type) {
        precondition(MemoryLayout<T>.stride <= payloadStride &&
            MemoryLayout<T>.alignment <= payloadAlignment &&
            payloadStride.isMultiple(of: MemoryLayout<T>.alignment),
            "pipeline event payload no longer fits its fixed slot; review storage schema")
    }

    private static func kind(_ tag: UnsafeMutablePointer<UInt16>) -> Tag {
        guard let value = Tag(rawValue: tag.pointee) else {
            preconditionFailure("invalid pipeline event payload tag")
        }
        return value
    }

    private static func put<T>(_ value: T, kind: Tag, at slot: UnsafeMutableRawPointer,
        tag: UnsafeMutablePointer<UInt16>) {
        validate(T.self)
        precondition(UInt(bitPattern: slot).isMultiple(of: UInt(MemoryLayout<T>.alignment)))
        // The caller proved this slot empty, so any prior binding is uninitialized.
        slot.bindMemory(to: T.self, capacity: 1).initialize(to: value)
        tag.pointee = kind.rawValue
    }

    private static func take<T>(_ type: T.Type, at slot: UnsafeMutableRawPointer,
        tag: UnsafeMutablePointer<UInt16>) -> T {
        let value = slot.assumingMemoryBound(to: T.self).move()
        tag.pointee = emptyTag
        return value
    }

    static func initialize(_ event: PlaybackPipelineEvent, at slot: UnsafeMutableRawPointer,
        tag: UnsafeMutablePointer<UInt16>) {
        precondition(kind(tag) == .empty, "pipeline payload initialized twice")
        switch event {
        case .stopped: tag.pointee = Tag.stopped.rawValue
        case .ready(let cycle): put(cycle, kind: .ready, at: slot, tag: tag)
        case .phase(let phase, let cycle):
            switch phase {
            case .buffering: put(cycle, kind: .buffering, at: slot, tag: tag)
            case .recovering: put(cycle, kind: .recovering, at: slot, tag: tag)
            }
        case .mediaInformation(let info, let generation):
            if let generation {
                put((info, generation), kind: .mediaWithGeneration, at: slot, tag: tag)
            } else {
                put(info, kind: .mediaWithoutGeneration, at: slot, tag: tag)
            }
        case .backendFailed(let diagnostic, let scope, let owner):
            put((diagnostic, scope, owner), kind: .backendFailed, at: slot, tag: tag)
        case .failed(let error):
            switch error {
            case .unsupportedProtocol(let value): put(value, kind: .unsupportedProtocol, at: slot, tag: tag)
            case .demuxOpen(let value): put(value, kind: .demuxOpen, at: slot, tag: tag)
            case .demuxRead(let value): put(value, kind: .demuxRead, at: slot, tag: tag)
            case .ffmpegFailure(let failureKind, let stage, let status):
                put((failureKind, stage, status), kind: .ffmpegFailure, at: slot, tag: tag)
            case .networkTimeout: tag.pointee = Tag.networkTimeout.rawValue
            case .unsupportedVideoCodec: tag.pointee = Tag.unsupportedVideoCodec.rawValue
            case .unsupportedAudioCodec: tag.pointee = Tag.unsupportedAudioCodec.rawValue
            case .videoFormatDescription(let value): put(value, kind: .videoFormatDescription, at: slot, tag: tag)
            case .hardwareDecoderUnavailable: tag.pointee = Tag.hardwareDecoderUnavailable.rawValue
            case .videoDecoderTransitionTimeout: tag.pointee = Tag.videoDecoderTransitionTimeout.rawValue
            case .videoDecode(let value): put(value, kind: .videoDecode, at: slot, tag: tag)
            case .videoDecoderFailure(let value): put(value, kind: .videoDecoderFailure, at: slot, tag: tag)
            case .videoSampleBuffer(let value): put(value, kind: .videoSampleBuffer, at: slot, tag: tag)
            case .videoRendererFailed(let value): put(value, kind: .videoRendererFailed, at: slot, tag: tag)
            case .audioFormatDescription(let value): put(value, kind: .audioFormatDescription, at: slot, tag: tag)
            case .audioFallbackDecode(let value): put(value, kind: .audioFallbackDecode, at: slot, tag: tag)
            case .audioRendererFailed(let value): put(value, kind: .audioRendererFailed, at: slot, tag: tag)
            case .renderTextureMapping: tag.pointee = Tag.renderTextureMapping.rawValue
            case .metalCommand(let value): put(value, kind: .metalCommand, at: slot, tag: tag)
            case .cancelled: tag.pointee = Tag.cancelled.rawValue
            case .controlEventCapacityExceeded: tag.pointee = Tag.controlEventCapacityExceeded.rawValue
            case .outputActivationRejected: tag.pointee = Tag.outputActivationRejected.rawValue
            case .backendPublicationReplacementRejected: tag.pointee = Tag.backendPublicationReplacementRejected.rawValue
            case .presented(let failure):
                let payload = (failure.code, failure.userMessage, failure.diagnosticCode)
                switch failure.retryDisposition {
                case .retrySameRequest: put(payload, kind: .presentedRetry, at: slot, tag: tag)
                case .chooseAnotherChannel: put(payload, kind: .presentedChooseChannel, at: slot, tag: tag)
                case .doNotRetry: put(payload, kind: .presentedDoNotRetry, at: slot, tag: tag)
                }
            case .unexpected(let stage, let diagnostic):
                put((stage, diagnostic), kind: .unexpected, at: slot, tag: tag)
            }
        }
    }

    static func move(at slot: UnsafeMutableRawPointer,
        tag: UnsafeMutablePointer<UInt16>) -> PlaybackPipelineEvent {
        let storedKind = kind(tag)
        switch storedKind {
        case .empty: preconditionFailure("read from empty pipeline event slot")
        case .stopped: tag.pointee = emptyTag; return .stopped
        case .ready: return .ready(readinessCycle: take(UInt64.self, at: slot, tag: tag))
        case .buffering: return .phase(.buffering, readinessCycle: take(UInt64.self, at: slot, tag: tag))
        case .recovering: return .phase(.recovering, readinessCycle: take(UInt64.self, at: slot, tag: tag))
        case .mediaWithoutGeneration:
            return .mediaInformation(take(PlaybackMediaInformation?.self, at: slot, tag: tag), generation: nil)
        case .mediaWithGeneration:
            let payload = take(MediaPayload.self, at: slot, tag: tag)
            return .mediaInformation(payload.0, generation: payload.1)
        case .backendFailed:
            let payload = take(BackendPayload.self, at: slot, tag: tag)
            return .backendFailed(payload.0, prepareScope: payload.1, metadataOwner: payload.2)
        case .unsupportedProtocol: return .failed(.unsupportedProtocol(take(String.self, at: slot, tag: tag)))
        case .demuxOpen: return .failed(.demuxOpen(take(Int32.self, at: slot, tag: tag)))
        case .demuxRead: return .failed(.demuxRead(take(Int32.self, at: slot, tag: tag)))
        case .ffmpegFailure:
            let payload = take(FFmpegPayload.self, at: slot, tag: tag)
            return .failed(.ffmpegFailure(kind: payload.0, stage: payload.1, status: payload.2))
        case .videoFormatDescription: return .failed(.videoFormatDescription(take(Int32.self, at: slot, tag: tag)))
        case .videoDecode: return .failed(.videoDecode(take(Int32.self, at: slot, tag: tag)))
        case .videoDecoderFailure: return .failed(.videoDecoderFailure(take(VideoDecoderFailure.self, at: slot, tag: tag)))
        case .videoSampleBuffer: return .failed(.videoSampleBuffer(take(String.self, at: slot, tag: tag)))
        case .videoRendererFailed: return .failed(.videoRendererFailed(take(String.self, at: slot, tag: tag)))
        case .audioFormatDescription: return .failed(.audioFormatDescription(take(Int32.self, at: slot, tag: tag)))
        case .audioFallbackDecode: return .failed(.audioFallbackDecode(take(Int32.self, at: slot, tag: tag)))
        case .audioRendererFailed: return .failed(.audioRendererFailed(take(String.self, at: slot, tag: tag)))
        case .metalCommand: return .failed(.metalCommand(take(String.self, at: slot, tag: tag)))
        case .presentedRetry, .presentedChooseChannel, .presentedDoNotRetry:
            let payload = take(PresentedPayload.self, at: slot, tag: tag)
            let retry: PlaybackRetryDisposition
            switch storedKind {
            case .presentedRetry: retry = .retrySameRequest
            case .presentedChooseChannel: retry = .chooseAnotherChannel
            case .presentedDoNotRetry: retry = .doNotRetry
            default: preconditionFailure("invalid presented failure tag")
            }
            return .failed(.presented(.init(code: payload.0, userMessage: payload.1,
                diagnosticCode: payload.2, retryDisposition: retry)))
        case .unexpected:
            let payload = take(UnexpectedPayload.self, at: slot, tag: tag)
            return .failed(.unexpected(stage: payload.0, diagnostic: payload.1))
        case .networkTimeout: tag.pointee = emptyTag; return .failed(.networkTimeout)
        case .unsupportedVideoCodec: tag.pointee = emptyTag; return .failed(.unsupportedVideoCodec)
        case .unsupportedAudioCodec: tag.pointee = emptyTag; return .failed(.unsupportedAudioCodec)
        case .hardwareDecoderUnavailable: tag.pointee = emptyTag; return .failed(.hardwareDecoderUnavailable)
        case .videoDecoderTransitionTimeout: tag.pointee = emptyTag; return .failed(.videoDecoderTransitionTimeout)
        case .renderTextureMapping: tag.pointee = emptyTag; return .failed(.renderTextureMapping)
        case .cancelled: tag.pointee = emptyTag; return .failed(.cancelled)
        case .controlEventCapacityExceeded: tag.pointee = emptyTag; return .failed(.controlEventCapacityExceeded)
        case .outputActivationRejected: tag.pointee = emptyTag; return .failed(.outputActivationRejected)
        case .backendPublicationReplacementRejected: tag.pointee = emptyTag; return .failed(.backendPublicationReplacementRejected)
        }
    }

    static func destroy(at slot: UnsafeMutableRawPointer, tag: UnsafeMutablePointer<UInt16>) {
        switch kind(tag) {
        case .empty, .stopped, .networkTimeout, .unsupportedVideoCodec, .unsupportedAudioCodec,
             .hardwareDecoderUnavailable, .videoDecoderTransitionTimeout, .renderTextureMapping,
             .cancelled, .controlEventCapacityExceeded, .outputActivationRejected,
             .backendPublicationReplacementRejected: break
        case .ready, .buffering, .recovering: slot.assumingMemoryBound(to: UInt64.self).deinitialize(count: 1)
        case .mediaWithoutGeneration: slot.assumingMemoryBound(to: PlaybackMediaInformation?.self).deinitialize(count: 1)
        case .mediaWithGeneration: slot.assumingMemoryBound(to: MediaPayload.self).deinitialize(count: 1)
        case .backendFailed: slot.assumingMemoryBound(to: BackendPayload.self).deinitialize(count: 1)
        case .unsupportedProtocol, .videoSampleBuffer, .videoRendererFailed, .audioRendererFailed, .metalCommand:
            slot.assumingMemoryBound(to: String.self).deinitialize(count: 1)
        case .demuxOpen, .demuxRead, .videoFormatDescription, .videoDecode, .audioFormatDescription, .audioFallbackDecode:
            slot.assumingMemoryBound(to: Int32.self).deinitialize(count: 1)
        case .ffmpegFailure: slot.assumingMemoryBound(to: FFmpegPayload.self).deinitialize(count: 1)
        case .videoDecoderFailure: slot.assumingMemoryBound(to: VideoDecoderFailure.self).deinitialize(count: 1)
        case .presentedRetry, .presentedChooseChannel, .presentedDoNotRetry:
            slot.assumingMemoryBound(to: PresentedPayload.self).deinitialize(count: 1)
        case .unexpected: slot.assumingMemoryBound(to: UnexpectedPayload.self).deinitialize(count: 1)
        }
        tag.pointee = emptyTag
    }
}

final class PlaybackSessionEventRelay: @unchecked Sendable {
    typealias Receiver = @Sendable (PlaybackRunIdentity, PlaybackPipelineEvent) async -> Void
    static let maximumCapacity = 32
    /// Exactly 32 logical slots; both original allocations are charged after rounding.
    static let fixedBackingCapacity = maximumCapacity

    struct SystemAndPipelineRelayAllocationReservation {
        let monitorObject: Int
        let monitorLock: Int
        let observerTokens: Int
        let observerCaptures: Int
        let pipelineRelayObject: Int
        let pipelineRelayLock: Int
        let pipelineBacking: Int
        let receiverCapture: Int
        let drainRunnerObject: Int
        let relayTaskSlabs: Int
        let drainTaskCaptures: Int
        let weakTargetAllocationCharges: Int

        /// previous/next各512B已包含旧尾同时存活；此别名不重复进入total。
        var relayOldTailOverlap: Int { relayTaskSlabs / 2 }
        var fixedObjectAllocationCharges: Int {
            monitorObject + monitorLock + pipelineRelayObject + pipelineRelayLock + drainRunnerObject
        }
        var fixedBackingAllocationCharges: Int { pipelineBacking }
        var total: Int {
            monitorObject + monitorLock + observerTokens + observerCaptures + pipelineRelayObject +
                pipelineRelayLock + pipelineBacking + receiverCapture + drainRunnerObject +
                relayTaskSlabs + drainTaskCaptures + weakTargetAllocationCharges
        }
    }

    static var systemAndPipelineRelayAllocationReservation: SystemAndPipelineRelayAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return .init(
            monitorObject: object(SystemAudioEventMonitor.self),
            // Both synchronization primitives are inline in their charged owner objects.
            monitorLock: 0,
            // 私有token当前目标实测32B/个；跨tvOS runtime按64B/个保守，framework其余opaque内部仍是盲区。
            observerTokens: 5 * 64,
            observerCaptures: 5 * (32 + 48),
            pipelineRelayObject: object(PlaybackSessionEventRelay.self),
            pipelineRelayLock: 0,
            pipelineBacking: malloc_good_size(maximumCapacity * PlaybackPipelineEventStorage.payloadStride) +
                malloc_good_size(maximumCapacity * MemoryLayout<UInt16>.stride),
            receiverCapture: 32 + 48,
            drainRunnerObject: object(OwnedPlaybackEventDrain.self),
            // Swift Task无稳定公开allocation identity；原/新drain各保守512B。
            relayTaskSlabs: 2 * 512,
            drainTaskCaptures: 2 * (32 + 48),
            weakTargetAllocationCharges: 32)
    }

    private let identity: PlaybackRunIdentity
    private let receiver: Receiver
    // Payload values retain their native Swift ownership. Only the separate tags
    // describe their initialized types; both original allocations belong here.
    private let pending: UnsafeMutableRawPointer
    private let pendingTags: UnsafeMutablePointer<UInt16>
    // Executor由Registry持有；relay只能弱借用，避免Authority→relay→Cell→Authority环。
    private weak var ownedExecutor: PlaybackControlExecutor?
    private var pendingIndex = 0
    private var pendingCount = 0
    private var isDraining = false
    private var isActive = true
    private var overflowed = false
    private var ownedDrainRequested = false
    // Keep the inline lock after byte-sized flags, avoiding pointer-alignment padding.
    private let lock = Mutex(())

    init(identity: PlaybackRunIdentity, receiver: @escaping Receiver) {
        self.identity = identity
        self.receiver = receiver
        PlaybackPipelineEventStorage.validateLayout()
        let payloadBytes = Self.maximumCapacity * PlaybackPipelineEventStorage.payloadStride
        pending = UnsafeMutableRawPointer.allocate(byteCount: payloadBytes,
            alignment: PlaybackPipelineEventStorage.payloadAlignment)
        pendingTags = UnsafeMutablePointer<UInt16>.allocate(capacity: Self.maximumCapacity)
        pendingTags.initialize(repeating: PlaybackPipelineEventStorage.emptyTag, count: Self.maximumCapacity)
        precondition(malloc_size(pending) >= payloadBytes &&
            malloc_size(UnsafeRawPointer(pendingTags)) >= Self.maximumCapacity * MemoryLayout<UInt16>.stride,
            "pipeline relay固定背板逻辑槽数不一致")
        PlaybackRuntimeAllocationReservations.validateSystemAndPipelineAndGlobalCaps()
    }

    deinit {
        clearPending()
        pendingTags.deinitialize(count: Self.maximumCapacity)
        pending.deallocate()
        pendingTags.deallocate()
    }

    /// Mutating access requires the relay mutex, except exclusive initialization
    /// and deinit after the owned drain's physical join.
    private func pendingSlot(at index: Int) -> UnsafeMutableRawPointer {
        precondition((0..<Self.maximumCapacity).contains(index))
        return pending.advanced(by: index * PlaybackPipelineEventStorage.payloadStride)
    }

    private func store(_ event: PlaybackPipelineEvent, at index: Int) {
        PlaybackPipelineEventStorage.initialize(event, at: pendingSlot(at: index),
            tag: pendingTags.advanced(by: index))
    }

    private func clearPending() {
        for index in 0..<Self.maximumCapacity {
            PlaybackPipelineEventStorage.destroy(at: pendingSlot(at: index),
                tag: pendingTags.advanced(by: index))
        }
    }

    func bindOwnedExecutor(_ executor: PlaybackControlExecutor) -> Bool {
        lock.withLock { _ in
            guard ownedExecutor == nil, !isDraining, pendingCount == 0 else { return false }
            ownedExecutor = executor
            return true
        }
    }

    func claimOwnedDrainRequest() -> Bool {
        lock.withLock { _ in
            guard ownedDrainRequested else { return false }
            ownedDrainRequested = false
            return true
        }
    }

    func send(_ event: PlaybackPipelineEvent) {
        let executor = lock.withLock { _ -> PlaybackControlExecutor? in
            guard let ownedExecutor, isActive, !overflowed else { return nil }
            if pendingCount >= Self.maximumCapacity - (isDraining ? 1 : 0) {
                // 不可折叠溢出成为一次终态；用原槽保存，不另排队或继续接纳。
                overflowed = true
                clearPending()
                pendingIndex = 0
                store(.failed(.controlEventCapacityExceeded), at: 0)
                pendingCount = 1
                return nil
            }
            store(event, at: (pendingIndex + pendingCount) % Self.maximumCapacity)
            pendingCount += 1
            guard !isDraining else { return nil }
            isDraining = true
            ownedDrainRequested = true
            return ownedExecutor
        }
        executor?.signalOwnedEventDrain()
    }

    func deactivate() {
        lock.withLock { _ in
            guard isActive else { return }
            isActive = false
            clearPending()
            pendingIndex = 0
            pendingCount = 0
        }
    }

    func drainOwned(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
        while let event = nextEvent() {
            guard registry.claimEventDrainDelivery(ticket) else { deactivate(); return }
            await receiver(identity, event)
        }
    }

    private func nextEvent() -> PlaybackPipelineEvent? {
        lock.withLock { _ in
            guard isActive else {
                clearPending()
                pendingIndex = 0
                pendingCount = 0
                isDraining = false
                return nil
            }
            guard pendingCount > 0 else {
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = PlaybackPipelineEventStorage.move(at: pendingSlot(at: pendingIndex),
                tag: pendingTags.advanced(by: pendingIndex))
            pendingIndex = (pendingIndex + 1) % Self.maximumCapacity
            pendingCount -= 1
            return event
        }
    }
}

/// 同一record持续持有relay及最后一份Task；空队列不等于record terminal。
/// task与joining只在Registry的唯一executor访问；join后的最后引用在锁外释放。
final class OwnedPlaybackEventDrain: @unchecked Sendable {
    enum Relay: Sendable {
        case pipeline(PlaybackSessionEventRelay)
        case audio(PlaybackAudioSessionEventRelay)

        func bind(to executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
            switch self {
            case .pipeline(let relay): relay.bindOwnedExecutor(executor)
            case .audio(let relay): relay.bindOwnedExecutor(executor, recordNonce: recordNonce)
            }
        }

        func claimDrainRequest() -> Bool {
            switch self {
            case .pipeline(let relay): relay.claimOwnedDrainRequest()
            case .audio(let relay): relay.claimOwnedDrainRequest()
            }
        }

        func deactivate() {
            switch self {
            case .pipeline(let relay): relay.deactivate()
            case .audio(let relay): relay.deactivate()
            }
        }

        func drain(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
            switch self {
            case .pipeline(let relay): await relay.drainOwned(registry: registry, ticket: ticket)
            case .audio(let relay): await relay.drainOwned(registry: registry, ticket: ticket)
            }
        }
    }
    let relay: Relay
    var task: Task<Void, Never>?
    var joining = false
    var consumedSystemRevision: UInt64 = 0

    init(relay: Relay) { self.relay = relay }
}

final class PlaybackAudioSessionEventRelay: Equatable, @unchecked Sendable {
    static func == (lhs: PlaybackAudioSessionEventRelay, rhs: PlaybackAudioSessionEventRelay) -> Bool { lhs === rhs }
    weak var terminalReceiver: (any PlaybackOwnedCleanupReceiving)?
    typealias Receiver = @Sendable (
        PlaybackRunIdentity,
        PlaybackAudioSessionLease,
        PlaybackAudioSessionEventKey,
        ControlTaskTicket
    ) async -> Void
    static let maximumCapacity = 32
    static let fixedBackingCapacity = maximumCapacity

    struct AudioRelayAllocationReservation {
        let relayObject: Int
        let relayLock: Int
        let fixedBacking: Int
        let receiverCapture: Int
        let drainRunnerObject: Int
        let relayTaskSlabs: Int
        let drainTaskCaptures: Int

        var relayOldTailOverlap: Int { relayTaskSlabs / 2 }
        var fixedObjectAllocationCharges: Int { relayObject + relayLock + drainRunnerObject }
        var fixedBackingAllocationCharges: Int { fixedBacking }
        var total: Int {
            relayObject + relayLock + fixedBacking + receiverCapture + drainRunnerObject +
                relayTaskSlabs + drainTaskCaptures
        }
    }

    static var audioRelayAllocationReservation: AudioRelayAllocationReservation {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return .init(
            relayObject: object(PlaybackAudioSessionEventRelay.self),
            relayLock: object(NSLock.self),
            fixedBacking: malloc_good_size(32 + fixedBackingCapacity * MemoryLayout<PlaybackAudioSessionEventKey?>.stride),
            receiverCapture: 32 + 48,
            drainRunnerObject: object(OwnedPlaybackEventDrain.self),
            relayTaskSlabs: 2 * 512,
            drainTaskCaptures: 2 * (32 + 48))
    }

    private let identity: PlaybackRunIdentity
    let lease: PlaybackAudioSessionLease
    private let receiver: Receiver
    private let lock = NSLock()
    private var pending: [PlaybackAudioSessionEventKey?] = Array(repeating: nil, count: maximumCapacity)
    private var pendingIndex = 0
    private var pendingCount = 0
    private var isDraining = false
    private var deliveryInFlight = false
    private var isActive = true
    private var overflowed = false
    private weak var ownedExecutor: PlaybackControlExecutor?
    private var ownedRecordNonce: UInt64?
    private var ownedDrainRequested = false
    private var ownedDrainEnabled = false

    init(identity: PlaybackRunIdentity, lease: PlaybackAudioSessionLease, receiver: @escaping Receiver) {
        self.identity = identity
        self.lease = lease
        self.receiver = receiver
        precondition(pending.count == Self.maximumCapacity, "audio relay固定背板逻辑槽数不一致")
        PlaybackRuntimeAllocationReservations.validateAudioAndGlobalCaps()
    }

    func prepareOwnedExecutor(_ executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
        lock.withLock {
            guard ownedExecutor == nil, !isDraining, isActive, !overflowed else { return false }
            ownedExecutor = executor
            ownedRecordNonce = recordNonce
            return true
        }
    }

    func bindOwnedExecutor(_ executor: PlaybackControlExecutor, recordNonce: UInt64) -> Bool {
        lock.withLock {
            guard ownedExecutor === executor, ownedRecordNonce == recordNonce,
                  !ownedDrainEnabled, !isDraining, isActive else { return false }
            ownedDrainEnabled = true
            if pendingCount > 0 { isDraining = true; ownedDrainRequested = true }
            return true
        }
    }

    /// 原record已持有relay；最终bind只开放其单票。并发source已领取时无需重复唤醒。
    func signalAfterOwnedBinding() {
        let executor = lock.withLock { () -> PlaybackControlExecutor? in
            guard ownedDrainEnabled, ownedDrainRequested else { return nil }
            return ownedExecutor
        }
        executor?.signalOwnedEventDrain()
    }

    func claimOwnedDrainRequest() -> Bool {
        lock.withLock {
            guard ownedDrainEnabled, ownedDrainRequested else { return false }
            ownedDrainRequested = false
            return true
        }
    }

    func send(lease: PlaybackAudioSessionLease, event: PlaybackAudioSessionEventEnvelope) {
        guard lease == self.lease, let key = PlaybackAudioSessionEventKey(envelope: event) else { return }
        var overflowRecord: UInt64?
        let executor = lock.withLock { () -> PlaybackControlExecutor? in
            guard isActive, !overflowed else { return nil }
            if pendingCount >= Self.maximumCapacity - (deliveryInFlight ? 1 : 0) {
                overflowed = true
                for index in pending.indices { pending[index] = nil }
                pendingIndex = 0
                pending[0] = PlaybackAudioSessionEventKey(envelope:
                    .init(event: .recoveryFailed(stage: .eventRelayCapacity), systemReceipt: nil))
                pendingCount = 1
                overflowRecord = ownedRecordNonce
                return ownedExecutor
            }
            pending[(pendingIndex + pendingCount) % Self.maximumCapacity] = key
            pendingCount += 1
            guard let ownedExecutor, ownedDrainEnabled else { return nil }
            guard !isDraining else { return nil }
            isDraining = true
            ownedDrainRequested = true
            return ownedExecutor
        }
        if let overflowRecord {
            executor?.safetyIngress.receiveAudioRelayOverflow(recordNonce: overflowRecord)
        } else {
            executor?.signalOwnedEventDrain()
        }
    }

    func deactivate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            for index in pending.indices { pending[index] = nil }
            pendingIndex = 0
            pendingCount = 0
        }
    }

    func drainOwned(registry: ControlTaskRegistry, ticket: ControlTaskTicket) async {
        while let event = nextEvent() {
            guard registry.claimEventDrainDelivery(ticket) else { deactivate(); return }
            await receiver(identity, lease, event, ticket)
        }
    }

    private func nextEvent() -> PlaybackAudioSessionEventKey? {
        lock.withLock {
            // 只有receiver真正返回后才释放其in-flight份额；排期本身不占事件槽。
            deliveryInFlight = false
            guard isActive else {
                for index in pending.indices { pending[index] = nil }
                pendingIndex = 0
                pendingCount = 0
                isDraining = false
                return nil
            }
            guard pendingCount > 0 else {
                pendingIndex = 0
                isDraining = false
                return nil
            }
            let event = pending[pendingIndex]
            pending[pendingIndex] = nil
            pendingIndex = (pendingIndex + 1) % Self.maximumCapacity
            pendingCount -= 1
            deliveryInFlight = true
            return event
        }
    }
}

/// 五本静态reservation只描述同一运行时可达峰；没有可变计数器、第二Authority或运行时allocation。
enum PlaybackRuntimeAllocationReservations {
    static let ownedControlHardCap = 64 * 1_024
    static let audioRelayHardCap = 16 * 1_024
    static let systemAndPipelineRelayHardCap = 4 * 1_024
    static let routeHardCap = 4 * 1_024
    static let presentationHardCap = 2 * 1_024
    static let globalHardCap = 96 * 1_024

    static var ownedControl: ControlTaskRegistry.ControlAllocationReservation {
        ControlTaskRegistry.ownedControlAllocationReservation
    }
    static var audioRelay: PlaybackAudioSessionEventRelay.AudioRelayAllocationReservation {
        PlaybackAudioSessionEventRelay.audioRelayAllocationReservation
    }
    static var systemAndPipelineRelay: PlaybackSessionEventRelay.SystemAndPipelineRelayAllocationReservation {
        PlaybackSessionEventRelay.systemAndPipelineRelayAllocationReservation
    }
    static var route: PlaybackAudioRouteService.RouteAllocationReservation {
        PlaybackAudioRouteService.routeAllocationReservation
    }
    static var presentation: PlaybackPresentationAllocationReservation {
        PlaybackPresentationRelay.allocationReservation
    }
    static var globalReachablePeak: Int {
        var total = 0
        guard checkedAccumulate(ownedControl.total, into: &total),
              checkedAccumulate(audioRelay.total, into: &total),
              checkedAccumulate(systemAndPipelineRelay.total, into: &total),
              checkedAccumulate(route.total, into: &total),
              checkedAccumulate(presentation.total, into: &total) else { return Int.max }
        return total
    }

    static func validateOwnedAndGlobalCaps() {
        precondition(ownedControl.total <= ownedControlHardCap, "owned-control allocation超出64KiB")
        validateGlobalCap()
    }
    static func validateAudioAndGlobalCaps() {
        precondition(audioRelay.total <= audioRelayHardCap, "audio relay allocation超出16KiB")
        validateGlobalCap()
    }
    static func validateSystemAndPipelineAndGlobalCaps() {
        let reservation = systemAndPipelineRelay
        if reservation.total > systemAndPipelineRelayHardCap {
            // Release may strip precondition message evaluation. Emit only the
            // already-fatal path's fixed scalar evidence before the unchanged cap.
            let diagnostic = """
                system/pipeline relay allocation超出4KiB: total=\(reservation.total), cap=\(systemAndPipelineRelayHardCap), \
                monitor=\(reservation.monitorObject), monitorLock=\(reservation.monitorLock), \
                tokens=\(reservation.observerTokens), observerCaptures=\(reservation.observerCaptures), \
                pipeline=\(reservation.pipelineRelayObject), pipelineLock=\(reservation.pipelineRelayLock), \
                backing=\(reservation.pipelineBacking), receiver=\(reservation.receiverCapture), \
                drain=\(reservation.drainRunnerObject), tasks=\(reservation.relayTaskSlabs), \
                taskCaptures=\(reservation.drainTaskCaptures), weak=\(reservation.weakTargetAllocationCharges), \
                monitorInstance=\(class_getInstanceSize(SystemAudioEventMonitor.self)), \
                pipelineInstance=\(class_getInstanceSize(PlaybackSessionEventRelay.self)), \
                drainInstance=\(class_getInstanceSize(OwnedPlaybackEventDrain.self)), \
                lockInstance=\(class_getInstanceSize(NSLock.self)), \
                pipelineStride=\(MemoryLayout<PlaybackPipelineEvent>.stride), \
                coreErrorStride=\(MemoryLayout<PlaybackCoreError>.stride), \
                mediaStride=\(MemoryLayout<PlaybackMediaInformation?>.stride), \
                generationStride=\(MemoryLayout<MediaGeneration?>.stride), \
                tokenStride=\(MemoryLayout<NotificationCenter.ObservationToken?>.stride), \
                presentedPayloadStride=\(MemoryLayout<(String, String, String?)>.stride), \
                presentedPayloadAlignment=\(MemoryLayout<(String, String, String?)>.alignment), \
                mediaPayloadStride=\(MemoryLayout<(PlaybackMediaInformation?, MediaGeneration)>.stride), \
                mediaPayloadAlignment=\(MemoryLayout<(PlaybackMediaInformation?, MediaGeneration)>.alignment), \
                videoFailurePayloadStride=\(MemoryLayout<VideoDecoderFailure>.stride), \
                videoFailurePayloadAlignment=\(MemoryLayout<VideoDecoderFailure>.alignment), \
                unexpectedPayloadStride=\(MemoryLayout<(String, ErrorDiagnosticSnapshot)>.stride), \
                unexpectedPayloadAlignment=\(MemoryLayout<(String, ErrorDiagnosticSnapshot)>.alignment), \
                backendPayloadStride=\(MemoryLayout<(ErrorDiagnosticSnapshot, PlaybackBackendPrepareFailureScope, HLSRuntimeFailureMetadataOwner)>.stride), \
                backendPayloadAlignment=\(MemoryLayout<(ErrorDiagnosticSnapshot, PlaybackBackendPrepareFailureScope, HLSRuntimeFailureMetadataOwner)>.alignment), \
                ffmpegPayloadStride=\(MemoryLayout<(FFmpegFailureKind, FFmpegFailureStage, Int32)>.stride), \
                ffmpegPayloadAlignment=\(MemoryLayout<(FFmpegFailureKind, FFmpegFailureStage, Int32)>.alignment), \
                scalarPayloadStride=\(MemoryLayout<UInt64>.stride), \
                scalarPayloadAlignment=\(MemoryLayout<UInt64>.alignment), \
                payloadRequestClass=\(malloc_good_size(PlaybackSessionEventRelay.maximumCapacity * PlaybackPipelineEventStorage.payloadStride)), \
                tagRequestClass=\(malloc_good_size(PlaybackSessionEventRelay.maximumCapacity * MemoryLayout<UInt16>.stride)), \
                typedRequestClass=\(malloc_good_size(32 * MemoryLayout<PlaybackPipelineEvent>.stride)), \
                arrayRequestClass=\(malloc_good_size(32 + 32 * MemoryLayout<PlaybackPipelineEvent>.stride))
                """ + "\n"
            diagnostic.withCString { message in
                _ = Darwin.write(STDERR_FILENO, message, Darwin.strlen(message))
            }
        }
        precondition(reservation.total <= systemAndPipelineRelayHardCap,
            "system/pipeline relay allocation超出4KiB")
        validateGlobalCap()
    }
    static func validateRouteAndGlobalCaps() {
        precondition(route.total <= routeHardCap, "route allocation超出4KiB")
        validateGlobalCap()
    }
    static func validatePresentationAndGlobalCaps() {
        precondition(
            presentation.total <= presentationHardCap,
            "presentation allocation超出2KiB：\(presentation.total)B"
        )
        validateGlobalCap()
    }
    static func checkedAccumulate(_ value: Int, into total: inout Int) -> Bool {
        guard value >= 0 else { return false }
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = next
        return true
    }
    private static func validateGlobalCap() {
        precondition(globalReachablePeak <= globalHardCap, "控制运行时全局allocation超出96KiB")
    }
}

struct PlaybackPresentationAllocationReservation {
    let relayObject: Int
    let relayLock: Int
    let asyncStreamOpaqueStorage: Int
    let newestBufferBacking: Int
    let terminationClosureContext: Int
    let relayWeakSideTable: Int
    let consumerTaskSlab: Int
    let consumerCaptureCompletionAndPendingIntent: Int
    let consumerOwnerObject: Int
    let consumerOwnerWeakSideTable: Int
    let mountObject: Int
    let hostOwnershipState: Int
    let hostWeakSideTable: Int
    let coordinatorObject: Int
    let consumerInFlightEnvelope: Int
    var total: Int {
        var total = 0
        guard PlaybackRuntimeAllocationReservations.checkedAccumulate(relayObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(relayLock, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                asyncStreamOpaqueStorage, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                newestBufferBacking, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                terminationClosureContext, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                relayWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerTaskSlab, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerCaptureCompletionAndPendingIntent, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerOwnerObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerOwnerWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                mountObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                hostOwnershipState, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                hostWeakSideTable, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                coordinatorObject, into: &total),
              PlaybackRuntimeAllocationReservations.checkedAccumulate(
                consumerInFlightEnvelope, into: &total) else { return Int.max }
        return total
    }
}

enum PlaybackPresentationAllocationCapacityResult: Equatable {
    case admitted(totalBytes: Int)
    case capacityExceeded
    case integerOverflow
}

enum PlaybackPresentationAllocationCapacity {
    static func evaluate(
        baseBytes: Int,
        additionalBytes: Int
    ) -> PlaybackPresentationAllocationCapacityResult {
        guard baseBytes >= 0, additionalBytes >= 0 else { return .capacityExceeded }
        let (total, overflow) = baseBytes.addingReportingOverflow(additionalBytes)
        guard !overflow else { return .integerOverflow }
        guard total <= PlaybackRuntimeAllocationReservations.presentationHardCap else {
            return .capacityExceeded
        }
        return .admitted(totalBytes: total)
    }
}
