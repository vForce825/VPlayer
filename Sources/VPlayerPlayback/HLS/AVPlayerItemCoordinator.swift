// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import ObjectiveC

struct AVPlayerItemInstanceIdentity: Sendable, Hashable {
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: UInt64
}

enum BackendActivationResult: Sendable, Equatable {
    case armed(ActivationEpoch)
    case alreadyArmed(ActivationEpoch)
    case rejected
}

struct AVPlayerSeekReceipt: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let playhead: PreparedPlayheadIdentity
    let actualTime: ExactMediaTime
}

struct AVPlayerPrerollReceipt: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let playhead: PreparedPlayheadIdentity
    let succeeded: Bool
}

struct AVPlayerLoadedRangeReceipt: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let playhead: PreparedPlayheadIdentity
    let requested: FMP4PresentationRange
}

struct AVPlayerDirectState: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let rate: Float
    let timeControlStatus: AVPlayer.TimeControlStatus
}

enum AVPlayerPreparationFence: String, Sendable, CaseIterable {
    case coverage, seek, loadedTimeRanges, preroll, preparedCAS, positiveRateAdmission
}

@MainActor
protocol AVPlayerDriving: AnyObject {
    var rate: Float { get }
    var timeControlStatus: AVPlayer.TimeControlStatus { get }
    var currentItemIdentity: AVPlayerItemInstanceIdentity? { get }
    var activeWaiterCount: Int { get }
    var fixedTimerCount: Int { get }
    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws
    func waitUntilReady(item: AVPlayerItemInstanceIdentity) async throws -> AVPlayerItemInstanceIdentity
    func selectAudibleMedia(item: AVPlayerItemInstanceIdentity) async throws
    func primeMediaData(item: AVPlayerItemInstanceIdentity) async throws
    func seek(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity,
              playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt
    func waitForLoadedTimeRanges(item: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: FMP4PresentationRange) async throws
        -> AVPlayerLoadedRangeReceipt
    func preroll(item: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt
    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item: AVPlayerItemInstanceIdentity) async throws
    func installTimeControlStatusRelay(
        item: AVPlayerItemInstanceIdentity,
        activation: ActivationEpoch,
        handler: @escaping @MainActor @Sendable (
            AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
        ) -> Void
    ) throws
    func installAccessLogURIObservation(
        item: AVPlayerItemInstanceIdentity,
        classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
        handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    ) throws
    func cancelPendingPrerolls(item: AVPlayerItemInstanceIdentity)
    func pause(item: AVPlayerItemInstanceIdentity)
    func waitUntilPaused(item: AVPlayerItemInstanceIdentity) async throws
    func directState(item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState
    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item: AVPlayerItemInstanceIdentity) throws
    func installNaturalEndTerminalHandler(
        item: AVPlayerItemInstanceIdentity,
        handler: @escaping @MainActor @Sendable (
            AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
        ) -> Void
    ) throws
    func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) -> AVPlayerNaturalEndTerminalResult?
    func replaceCurrentItemWithNil(item: AVPlayerItemInstanceIdentity)
    func removeObservers(item: AVPlayerItemInstanceIdentity)
    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item: AVPlayerItemInstanceIdentity)
    func retainInstallationResourceContext(_ reservation: PlaybackResourceContextReservation)
}

extension AVPlayerDriving {
    var activeWaiterCount: Int { 0 }
    var fixedTimerCount: Int { 0 }
    func selectAudibleMedia(item: AVPlayerItemInstanceIdentity) async throws {}
    func primeMediaData(item: AVPlayerItemInstanceIdentity) async throws {}
    func retainInstallationResourceContext(_ reservation: PlaybackResourceContextReservation) {}
}

struct AVPlayerCoverageDependencyEvidence: Sendable, Equatable {
    let mediaEpoch: UInt64
    let epochProofIdentity: UUID
    let segmentReceiptIdentity: UUID
    let initializationBackingIdentity: SealedMediaBackingIdentity
    let mediaBackingIdentity: SealedMediaBackingIdentity
    var initializationBodyCompleted: Bool
    var mediaBodyCompleted: Bool
}

struct AVPlayerCoverageDependencies: RandomAccessCollection, Sendable, Equatable,
    ExpressibleByArrayLiteral {
    private enum Storage: Sendable {
        case explicit([AVPlayerCoverageDependencyEvidence])
        case frozen(ServedCoverageDependencies?, ServedCoverageDependencies?)
    }
    private var storage: Storage
    init() { storage = .frozen(nil, nil) }
    init(explicit: [AVPlayerCoverageDependencyEvidence]) { storage = .explicit(explicit) }
    init(arrayLiteral elements: AVPlayerCoverageDependencyEvidence...) { storage = .explicit(elements) }
    init(served: ServedCoverageDependencies) { storage = .frozen(served, nil) }
    var startIndex: Int { 0 }
    var endIndex: Int {
        switch storage {
        case .explicit(let values): values.count
        case .frozen(let first, let second): (first?.count ?? 0) + (second?.count ?? 0)
        }
    }
    subscript(index: Int) -> AVPlayerCoverageDependencyEvidence {
        switch storage {
        case .explicit(let values): return values[index]
        case .frozen(let first, let second):
            let count = first?.count ?? 0
            let dependency = index < count ? first![index] : second![index - count]
            return .init(mediaEpoch: dependency.mediaEpoch,
                epochProofIdentity: dependency.epochProofIdentity,
                segmentReceiptIdentity: dependency.segmentReceiptIdentity,
                initializationBackingIdentity: dependency.initializationBackingIdentity,
                mediaBackingIdentity: dependency.mediaBackingIdentity,
                initializationBodyCompleted: true, mediaBodyCompleted: true)
        }
    }
    mutating func append(contentsOf other: Self) throws {
        guard count + other.count <= 128 else { throw AVPlayerItemCoordinatorFailure.capacityExceeded }
        if case .frozen(let first, let second) = storage,
           case .frozen(let incoming, nil) = other.storage, let incoming {
            guard second == nil else { throw AVPlayerItemCoordinatorFailure.capacityExceeded }
            storage = first == nil ? .frozen(incoming, nil) : .frozen(first, incoming)
        } else {
            // 显式测试provider值；生产Loopback固定投影不进入数组分支。
            var values = Array(self)
            values.append(contentsOf: other)
            storage = .explicit(values)
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}

struct AVPlayerVerifiedCoverage: Sendable, Equatable {
    let preparedPlayheadIdentity: PreparedPlayheadIdentity
    let observedRenditionSetReceiptIdentity: UUID
    let renditionIdentity: AudioRenditionIdentity
    let itemGeneration: UInt64
    let presentationRange: FMP4PresentationRange
    let dependencies: AVPlayerCoverageDependencies
}

struct AVPlayerCompletedParticipantReadiness: Sendable, Equatable {
    let participantID: UInt64
    let renditionIdentity: AudioRenditionIdentity
    let mediaType: FinalFMP4MediaType
    let mediaPlaylistSnapshotIdentity: UUID
    let initializationBodyCompleted: Bool
    let mediaBodyCompleted: Bool
}

struct AVPlayerCompletedPublicationReadiness: Sendable, Equatable {
    let itemURL: URL
    let itemGeneration: UInt64
    let publicationSequence: UInt64
    let masterPlaylistCompleted: Bool
    let participants: AVPlayerReadinessParticipants
    let audioSelectionCapability: LoopbackAudioMediaSelectionCapability?

    init(itemURL: URL, itemGeneration: UInt64, publicationSequence: UInt64,
         masterPlaylistCompleted: Bool,
         participants: [AVPlayerCompletedParticipantReadiness],
         audioSelectionCapability: LoopbackAudioMediaSelectionCapability? = nil) {
        self.itemURL = itemURL
        self.itemGeneration = itemGeneration
        self.publicationSequence = publicationSequence
        self.masterPlaylistCompleted = masterPlaylistCompleted
        self.participants = .init(explicit: participants)
        self.audioSelectionCapability = audioSelectionCapability
    }

    init(evidence: LoopbackCompletedPublicationEvidence) {
        itemURL = evidence.itemURL
        itemGeneration = evidence.itemGeneration
        publicationSequence = evidence.publicationSequence
        masterPlaylistCompleted = evidence.masterPlaylistCompleted
        participants = .init(evidence: evidence)
        audioSelectionCapability = evidence.audioSelectionCapability
    }
}

/// 生产快照直接借用冻结媒体证据的participant backing；投影本身不再map出第二份数组。
enum AVPlayerReadinessParticipants: RandomAccessCollection, Sendable, Equatable {
    case evidence(LoopbackCompletedPublicationEvidence)
    case preparationBasis(LoopbackPreparationPublicationBasis)
    case explicit([AVPlayerCompletedParticipantReadiness])
    init(explicit: [AVPlayerCompletedParticipantReadiness]) { self = .explicit(explicit) }
    init(evidence: LoopbackCompletedPublicationEvidence) { self = .evidence(evidence) }
    var startIndex: Int { 0 }
    var endIndex: Int {
        switch self {
        case .evidence(let evidence): evidence.participants.count
        case .preparationBasis(let basis): basis.participants.count
        case .explicit(let values): values.count
        }
    }
    subscript(index: Int) -> AVPlayerCompletedParticipantReadiness {
        let participant: LoopbackCompletedParticipantEvidence
        switch self {
        case .evidence(let evidence): participant = evidence.participants[index]
        case .preparationBasis(let basis): participant = basis.participants[index]
        case .explicit(let values): return values[index]
        }
        return .init(participantID: participant.participantID,
            renditionIdentity: participant.renditionIdentity, mediaType: participant.mediaType,
            mediaPlaylistSnapshotIdentity: participant.mediaPlaylistSnapshotIdentity,
            initializationBodyCompleted: participant.hasCompletedInitialization,
            mediaBodyCompleted: !participant.completedMedia.isEmpty)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}

/// coordinator 的前置绑定只约束原 selection/playlist 与当时已核的 init/media。
/// 此内部值不是完成能力，不能代替 seek 后的 coverage 准入。
private struct AVPlayerPublicationBindingReadiness {
    let itemURL: URL
    let itemGeneration: UInt64
    let publicationSequence: UInt64
    let masterPlaylistCompleted: Bool
    let participants: AVPlayerReadinessParticipants
    let audioSelectionCapability: LoopbackAudioMediaSelectionCapability?
    init(_ value: AVPlayerCompletedPublicationReadiness) {
        itemURL = value.itemURL; itemGeneration = value.itemGeneration
        publicationSequence = value.publicationSequence; masterPlaylistCompleted = value.masterPlaylistCompleted
        participants = value.participants; audioSelectionCapability = value.audioSelectionCapability
    }
    init(_ basis: LoopbackPreparationPublicationBasis) {
        itemURL = basis.itemURL; itemGeneration = basis.itemGeneration
        publicationSequence = basis.publicationSequence; masterPlaylistCompleted = basis.masterPlaylistCompleted
        participants = .preparationBasis(basis); audioSelectionCapability = basis.audioSelectionCapability
    }
}

protocol AVPlayerPreparationEvidenceProviding: AnyObject, Sendable {
    func consumeCompletedPublication(itemURL: URL,
                                     item: AVPlayerItemInstanceIdentity,
                                     publicationSequence: UInt64)
        -> AVPlayerCompletedPublicationReadiness?
    func verifiedCoverage(context: LoopbackCoverageContext,
                          requested: FMP4PresentationRange) throws -> AVPlayerVerifiedCoverage?
    func awaitCoverageReadiness(contexts: [LoopbackCoverageContext],
                                requested: FMP4PresentationRange) async throws
    func consumePlayerItemTimelineMapping(
        endpointAuthority: AACEffectiveEndpointAuthority?,
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        selection: LoopbackAudioMediaSelectionCapability?
    ) async throws -> PlayerItemTimelineMappingAuthority?
    func installCompletedPublicationEventHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void)
    func installRenditionSelectionEventHandler(
        _ handler: @escaping @Sendable (LoopbackAudioMediaSelectionCapability) -> Void)
    func currentAudioSelectionCapability(itemURL: URL,
                                         item: AVPlayerItemInstanceIdentity,
                                         publicationSequence: UInt64)
        -> LoopbackAudioMediaSelectionCapability?
    func classifyAccessLogURI(_ uri: URL,
                              itemURL: URL,
                              item: AVPlayerItemInstanceIdentity,
                              publicationSequence: UInt64,
                              selected: AudioRenditionIdentity?)
        -> AccessLogURIClassification
    func consumeLatestCompletedPublication(itemURL: URL,
                                           item: AVPlayerItemInstanceIdentity)
        -> AVPlayerCompletedPublicationReadiness?
}

extension AVPlayerPreparationEvidenceProviding {
    func awaitCoverageReadiness(contexts: [LoopbackCoverageContext],
                                requested: FMP4PresentationRange) async throws {}
}

enum AVPlayerAudioParticipantCodec: Sendable, Equatable {
    case aac
    case explicitlyNonAAC
}

struct AVPlayerAudioParticipantRequirement: @unchecked Sendable {
    let renditionIdentity: AudioRenditionIdentity
    let codec: AVPlayerAudioParticipantCodec
    let terminalBinding: AACWriterTerminalBinding?
    let renditionBinding: AACRenditionTerminalBinding?

    init(renditionIdentity: AudioRenditionIdentity,
         codec: AVPlayerAudioParticipantCodec,
         endpointAuthority: AACEffectiveEndpointAuthority? = nil,
         terminalBinding: AACWriterTerminalBinding? = nil,
         renditionBinding: AACRenditionTerminalBinding? = nil) {
        self.renditionIdentity = renditionIdentity
        self.codec = codec
        self.terminalBinding = terminalBinding ?? endpointAuthority?.terminalBinding
        self.renditionBinding = renditionBinding
    }
}

struct AVPlayerAudioRequirements: RandomAccessCollection, Sendable {
    private enum Storage: Sendable {
        case explicit([AVPlayerAudioParticipantRequirement])
        case frozen(LoopbackAVPlayerPreparationEvidenceSource)
    }
    private let storage: Storage
    init(_ values: [AVPlayerAudioParticipantRequirement]) { storage = .explicit(values) }
    init(source: LoopbackAVPlayerPreparationEvidenceSource) { storage = .frozen(source) }
    var startIndex: Int { 0 }
    var endIndex: Int {
        switch storage { case .explicit(let values): values.count; case .frozen(let source): source.audioRequirementCount }
    }
    subscript(index: Int) -> AVPlayerAudioParticipantRequirement {
        switch storage { case .explicit(let values): values[index]; case .frozen(let source): source.audioRequirement(at: index) }
    }
    var explicitValues: [AVPlayerAudioParticipantRequirement]? {
        if case .explicit(let values) = storage { return values }; return nil
    }
    var compacted: Self {
        if let values = explicitValues { return .init(values.map { $0 }) }; return self
    }
}

struct AVPlayerItemPreparationRequest: Sendable {
    let itemURL: URL
    let item: AVPlayerItemInstanceIdentity
    let publicationSequence: UInt64
    let audioParticipants: AVPlayerAudioRequirements
    let directAudioOnlyRendition: AudioRenditionIdentity?
    init(itemURL: URL, item: AVPlayerItemInstanceIdentity, publicationSequence: UInt64,
         audioParticipants: [AVPlayerAudioParticipantRequirement],
         directAudioOnlyRendition: AudioRenditionIdentity?) {
        self.init(itemURL: itemURL, item: item, publicationSequence: publicationSequence,
                  audioRequirements: .init(audioParticipants), directAudioOnlyRendition: directAudioOnlyRendition)
    }
    init(itemURL: URL, item: AVPlayerItemInstanceIdentity, publicationSequence: UInt64,
         audioRequirements: AVPlayerAudioRequirements,
         directAudioOnlyRendition: AudioRenditionIdentity?) {
        self.itemURL = itemURL; self.item = item; self.publicationSequence = publicationSequence
        audioParticipants = audioRequirements; self.directAudioOnlyRendition = directAudioOnlyRendition
    }
    init(itemURL: URL, item: AVPlayerItemInstanceIdentity, publicationSequence: UInt64,
         audioParticipants: AVPlayerAudioRequirements,
         directAudioOnlyRendition: AudioRenditionIdentity?) {
        self.init(itemURL: itemURL, item: item, publicationSequence: publicationSequence,
                  audioRequirements: audioParticipants, directAudioOnlyRendition: directAudioOnlyRendition)
    }
}

enum AccessLogURIClassification: Sendable, Equatable {
    case matching
    case conflicting
    case invalidLocalResource
    case unrelated
}

enum AccessLogURIClassifierV1 {
    static func classify(_ observed: URL,
                         request: AVPlayerItemPreparationRequest,
                         selected: AudioRenditionIdentity?) -> AccessLogURIClassification {
        // 保留旧符号只为源码兼容；没有 server 冻结 route/HMAC/store authority，
        // 绝不能从 path 数字推断 rendition。生产 coordinator 不再调用此入口。
        _ = request
        _ = selected
        return observed.host == "127.0.0.1" ? .invalidLocalResource : .unrelated
    }
}

struct PreparedAVPlayerItem: Sendable, Equatable {
    let item: AVPlayerItemInstanceIdentity
    let identity: PreparedPlayheadIdentity
    let selectedRenditions: [AudioRenditionIdentity]
    let minimumCoverageDuration: ExactMediaTime
    let coverageDependencies: AVPlayerCoverageDependencies
}

private enum RenditionSelectionSlot: Sendable {
    case unbound
    case bound(LoopbackAudioMediaSelectionCapability)
    case invalid

    var rendition: AudioRenditionIdentity? {
        guard case .bound(let capability) = self else { return nil }
        return capability.renditionIdentity
    }

    var capability: LoopbackAudioMediaSelectionCapability? {
        guard case .bound(let capability) = self else { return nil }
        return capability
    }
}

enum AVPlayerItemCoordinatorFailure: Error, Equatable {
    case itemFailed
    case noCurrentItem
    case insufficientCoverage
    case staleIdentity
    case selectionChanged
    case seekMismatch
    case loadedRangeMismatch
    case prerollFailed
    case directPauseNotConfirmed
    case invalidTimeline
    case operationInFlight
    case capacityExceeded
    case identitySpaceExhausted
    case readyTimeout
    case loadedTimeout
    case prerollTimeout
    case pausedTimeout
}

enum AVPlayerItemCoordinatorPhase: Sendable, Equatable {
    case idle, installed, preparing, prepared, authorized, playing, stopping, quiescent
}

struct AVPlayerItemCoordinatorState: Sendable {
    var phase: AVPlayerItemCoordinatorPhase = .idle
    var itemGeneration: UInt64 = 0
    var selectionRevision: UInt64 = 0
    var stopCount: UInt64 = 0
}

struct AVPlayerQuiescenceReceipt: Sendable, Equatable {
    let identity: AVPlayerQuiescenceReceiptIdentity
    let item: AVPlayerItemInstanceIdentity
    let suspendTicket: OutputSuspendTicket
    let priorActivationEpoch: ActivationEpoch?
    let stopNonce: UInt64?
    let closeClaim: PotentiallyAudibleOutputCloseClaim?
    let directlyConfirmedRateZero: Bool

    init(identity: AVPlayerQuiescenceReceiptIdentity = .init(),
         item: AVPlayerItemInstanceIdentity,
         suspendTicket: OutputSuspendTicket,
         priorActivationEpoch: ActivationEpoch?,
         stopNonce: UInt64?,
         closeClaim: PotentiallyAudibleOutputCloseClaim?,
         directlyConfirmedRateZero: Bool) {
        self.identity = identity
        self.item = item
        self.suspendTicket = suspendTicket
        self.priorActivationEpoch = priorActivationEpoch
        self.stopNonce = stopNonce
        self.closeClaim = closeClaim
        self.directlyConfirmedRateZero = directlyConfirmedRateZero
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.suspendTicket == rhs.suspendTicket
            && lhs.priorActivationEpoch == rhs.priorActivationEpoch
            && lhs.stopNonce == rhs.stopNonce && lhs.closeClaim == rhs.closeClaim
            && lhs.directlyConfirmedRateZero == rhs.directlyConfirmedRateZero
    }

    func matches(item: AVPlayerItemInstanceIdentity,
                 suspendTicket: OutputSuspendTicket,
                 priorActivationEpoch: ActivationEpoch?,
                 closeClaim: PotentiallyAudibleOutputCloseClaim) -> Bool {
        self.item == item
            && self.suspendTicket == suspendTicket
            && self.priorActivationEpoch == priorActivationEpoch
            && stopNonce == Optional(closeClaim.stopNonce)
            && self.closeClaim == Optional(closeClaim)
            && directlyConfirmedRateZero
            && closeClaim.suspendTicket == suspendTicket
            && closeClaim.intervalKey.outputLifecycle == item.outputLifecycleEpoch
            && closeClaim.intervalKey.itemGeneration == item.itemGeneration
            && closeClaim.intervalKey.activation == priorActivationEpoch
    }
}

final class AVPlayerQuiescenceReceiptIdentity: @unchecked Sendable {}

/// 只有 AVPlayer coordinator 在完成 pause KVO 与同 item direct read 后才能构造。
/// 普通 backend 只拿到最终 opaque attestation，无法用布尔值拼出 Registry 证明。
final class AVPlayerBackendQuiescenceAttestation: @unchecked Sendable {
    let invocation: ControlTaskRegistry.BackendSuspendInvocation
    let backendIdentity: PlaybackBackendIdentity
    let receipt: AVPlayerQuiescenceReceipt
    let preparedPreserved: Bool

    fileprivate init(invocation: ControlTaskRegistry.BackendSuspendInvocation,
                     backendIdentity: PlaybackBackendIdentity,
                     receipt: AVPlayerQuiescenceReceipt,
                     preparedPreserved: Bool) {
        self.invocation = invocation
        self.backendIdentity = backendIdentity
        self.receipt = receipt
        self.preparedPreserved = preparedPreserved
    }
}

/// publication 与 selection 分通道，但共享同一把锁和固定双槽；两类边沿不会
/// 相互覆盖，也不为同一个 coordinator 重复持有 relay/lock allocation。
final class AVPlayerCoordinatorEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceIdentity: UInt64 = 0
    private var pendingSequence: UInt64?
    private var pendingSelection: LoopbackAudioMediaSelectionCapability?
    private var inFlightSelection: LoopbackAudioMediaSelectionCapability?
    private var sourceIsActive = false
    private var pendingSelectionConflict = false
    private var publicationDeliveryScheduled = false
    private var selectionDeliveryScheduled = false

    func activate(_ sourceIdentity: UInt64) {
        precondition(sourceIdentity > 0)
        lock.withLock {
            self.sourceIdentity = sourceIdentity
            sourceIsActive = true
            pendingSequence = nil
            pendingSelection = nil
            pendingSelectionConflict = false
            // 原队列只是唤醒；换源不能抹去仍在队列中的物理授权。
        }
    }

    func offerPublication(_ sequence: UInt64, sourceIdentity: UInt64) -> Bool {
        lock.withLock {
            guard sourceIsActive, self.sourceIdentity == sourceIdentity else { return false }
            if let pendingSequence {
                self.pendingSequence = max(pendingSequence, sequence)
            } else {
                pendingSequence = sequence
            }
            guard !publicationDeliveryScheduled else { return false }
            publicationDeliveryScheduled = true
            return true
        }
    }

    func takePublication(resumingQueued: Bool = false)
        -> (sourceIdentity: UInt64, sequence: UInt64)? {
        lock.withLock {
            if resumingQueued {
                guard publicationDeliveryScheduled else { return nil }
                publicationDeliveryScheduled = false
            }
            guard sourceIsActive, let pendingSequence else { return nil }
            defer { self.pendingSequence = nil }
            return (sourceIdentity, pendingSequence)
        }
    }

    func offerSelection(_ capability: LoopbackAudioMediaSelectionCapability,
                        sourceIdentity: UInt64) -> Bool {
        lock.withLock {
            guard sourceIsActive, self.sourceIdentity == sourceIdentity else { return false }
            if let pendingSelection, pendingSelection !== capability {
                pendingSelectionConflict = true
            }
            pendingSelection = capability
            guard !selectionDeliveryScheduled else { return false }
            selectionDeliveryScheduled = true
            return true
        }
    }

    func takeSelection(resumingQueued: Bool = false)
        -> (sourceIdentity: UInt64, capability: LoopbackAudioMediaSelectionCapability,
            conflicted: Bool)? {
        lock.withLock {
            if resumingQueued {
                guard selectionDeliveryScheduled else { return nil }
                selectionDeliveryScheduled = false
            }
            guard sourceIsActive, inFlightSelection == nil,
                  let pendingSelection else { return nil }
            inFlightSelection = pendingSelection
            defer {
                self.pendingSelection = nil
                pendingSelectionConflict = false
            }
            return (sourceIdentity, pendingSelection, pendingSelectionConflict)
        }
    }

    func finishSelection(_ capability: LoopbackAudioMediaSelectionCapability) {
        lock.withLock {
            precondition(inFlightSelection === capability)
            inFlightSelection = nil
        }
    }

    var scheduledDeliveryCount: Int { lock.withLock {
        (publicationDeliveryScheduled ? 1 : 0) + (selectionDeliveryScheduled ? 1 : 0)
    } }
#if DEBUG
    func inspectLock(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(lock).toOpaque())
        body("context/原 relay NSLock", pointer, malloc_size(pointer))
    }
#endif
    static var retainedLockObjectBytes: Int {
        malloc_good_size(class_getInstanceSize(NSLock.self))
    }
    var retainedLockObjectIdentity: ObjectIdentifier { ObjectIdentifier(lock) }
}

enum AVPlayerRetainedGraphAllocationIdentity: Sendable, Hashable {
    case object(ObjectIdentifier)
    case ownedBacking(owner: ObjectIdentifier, ordinal: UInt8)
    case nativeBacking(UInt)
}

struct AVPlayerRetainedGraphCapacityLedger: Sendable {
    static let maximumBytes = 2_048
    static let maximumAllocationIdentities = 16
    private(set) var applicationChargeableBytes = 0
    private var allocations: [AVPlayerRetainedGraphAllocationIdentity: Int] = [:]

    mutating func reserve(
        allocationIdentity: AVPlayerRetainedGraphAllocationIdentity,
        allocatorRoundedBytes bytes: Int
    ) throws {
        if let existing = allocations[allocationIdentity] {
            guard existing == bytes else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            return
        }
        let next = applicationChargeableBytes.addingReportingOverflow(bytes)
        guard bytes >= 0, !next.overflow,
              allocations.count < Self.maximumAllocationIdentities,
              next.partialValue <= Self.maximumBytes else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        allocations[allocationIdentity] = bytes
        applicationChargeableBytes = next.partialValue
    }

    func reservedBytes(for identity: AVPlayerRetainedGraphAllocationIdentity) -> Int? {
        allocations[identity]
    }

    var allocationIdentityCount: Int { allocations.count }
}

struct AVPlayerRetainedGraphReservationSnapshot: Sendable, Equatable {
    let applicationChargeableBytes: Int
    let coordinatorObjectIdentity: ObjectIdentifier?
    let coordinatorObjectBytes: Int
    let coordinatorReservationCount: Int
    let allocationIdentityCount: Int
}

struct AVPlayerRetainedGraphFutureReservationSnapshot: Sendable, Equatable {
    let positiveRateCapabilityBytes: Int
    let stopTaskBytes: Int
    let receiptIdentityBytes: Int
    let retiredFenceBytes: Int

    /// activation 转 stop 时 stop task 与旧 capability 短暂交叠；进入
    /// quiescent replacement 后则是 stop task + receipt + fence。两条尾部
    /// 不同时存活，install 只预留它们的真实最大分支。
    var installedMaximumBranchBytes: Int {
        stopTaskBytes + max(
            positiveRateCapabilityBytes,
            receiptIdentityBytes + retiredFenceBytes)
    }

    var quiescentBytes: Int {
        stopTaskBytes + receiptIdentityBytes + retiredFenceBytes
    }
}

struct AVPlayerRetainedGraphAllocationBreakdown: Sendable, Equatable {
    let coordinatorObjectBytes: Int
    let driverObjectBytes: Int
    let evidenceSourceObjectBytes: Int
    let eventRelayObjectBytes: Int
    let replacementSlotObjectBytes: Int
    let eventRelayLockBytes: Int
    let evidenceHandlerBackingBytes: Int
    let urlObjectBytes: Int
    let urlBackingBytes: Int
    let participantBackingBytes: Int
    let stopTaskBytes: Int
    let maximumTerminalTailBytes: Int

    var installedBytes: Int {
        coordinatorObjectBytes + driverObjectBytes + evidenceSourceObjectBytes
            + eventRelayObjectBytes + replacementSlotObjectBytes
            + eventRelayLockBytes + 2 * evidenceHandlerBackingBytes
            + urlObjectBytes + urlBackingBytes + participantBackingBytes
            + stopTaskBytes + maximumTerminalTailBytes
    }
}

private struct AVPlayerRetainedGraphReservation: @unchecked Sendable {
    static let empty = Self(applicationChargeableBytes: 0,
                            allocationIdentityCount: 0,
                            urlAllocationOwner: nil)
    let applicationChargeableBytes: Int
    let allocationIdentityCount: UInt8
    /// 与 request.itemURL 共同持有同一 Foundation URL owner，保证上面的
    /// allocation/backing identity 在整个 item lifecycle 内有效。
    let urlAllocationOwner: NSURL?

    func forQuiescentReplacement(request: AVPlayerItemPreparationRequest) -> Self {
        _ = request
        // quiescent tail 仍强持 request/selection/readiness/driver relay；不能只留下
        // stop receipt 三项而把真实长期 owner 从 2KiB admission 中提前退费。
        return self
    }

    var admitsReservedStopBranch: Bool {
        applicationChargeableBytes > 0
            && applicationChargeableBytes <= AVPlayerRetainedGraphCapacityLedger.maximumBytes
            && allocationIdentityCount > 0
            && allocationIdentityCount <= AVPlayerRetainedGraphCapacityLedger
                .maximumAllocationIdentities
    }

    static func allocationBreakdown(request: AVPlayerItemPreparationRequest,
                                    urlAllocationOwner: NSURL,
                                    eventRelayLockBytes: Int)
        -> AVPlayerRetainedGraphAllocationBreakdown {
        func objectBytes(_ type: AnyClass) -> Int {
            malloc_good_size(class_getInstanceSize(type))
        }
        let future = AVPlayerItemCoordinator.retainedGraphFutureReservationSnapshot
        return .init(
            coordinatorObjectBytes: objectBytes(AVPlayerItemCoordinator.self),
            driverObjectBytes: objectBytes(SystemAVPlayerDriver.self),
            evidenceSourceObjectBytes:
                objectBytes(LoopbackAVPlayerPreparationEvidenceSource.self),
            eventRelayObjectBytes: objectBytes(AVPlayerCoordinatorEventRelay.self),
            replacementSlotObjectBytes: objectBytes(
                ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot.self),
            eventRelayLockBytes: eventRelayLockBytes,
            evidenceHandlerBackingBytes:
                malloc_good_size(32) + malloc_good_size(48),
            urlObjectBytes: objectBytes(type(of: urlAllocationOwner)),
            urlBackingBytes: malloc_good_size(
                request.itemURL.absoluteString.utf8.count + 1),
            participantBackingBytes: (request.audioParticipants.explicitValues?.isEmpty ?? true) ? 0
                : malloc_good_size(32 + request.audioParticipants.count
                    * MemoryLayout<AVPlayerAudioParticipantRequirement>.stride),
            stopTaskBytes: future.stopTaskBytes,
            maximumTerminalTailBytes: max(future.positiveRateCapabilityBytes,
                future.receiptIdentityBytes + future.retiredFenceBytes))
    }

    @MainActor
    static func make(request: AVPlayerItemPreparationRequest,
                     coordinator: AVPlayerItemCoordinator,
                     driver: any AVPlayerDriving,
                     evidenceSource: any AVPlayerPreparationEvidenceProviding,
                     eventRelay: AVPlayerCoordinatorEventRelay,
                     replacementSlot:
                        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot,
                     urlAllocationOwner: NSURL)
        throws -> Self {
        let coordinatorIdentity = ObjectIdentifier(coordinator)
        func reserveFutureObject(
            _ ledger: inout AVPlayerRetainedGraphCapacityLedger,
            ordinal: UInt8,
            bytes: Int
        ) throws {
            try ledger.reserve(allocationIdentity: .ownedBacking(
                owner: coordinatorIdentity, ordinal: ordinal),
                allocatorRoundedBytes: bytes)
        }
        let breakdown = allocationBreakdown(request: request, urlAllocationOwner: urlAllocationOwner,
                                             eventRelayLockBytes: AVPlayerCoordinatorEventRelay.retainedLockObjectBytes)
        // coordinator、driver、evidence、URL、selection 与 observer/deadline backing
        // 已由同 lifecycle 的 PlaybackResourceContextReservation 独占计费。2 KiB
        // HLS state 只保留 stop 与互斥终态尾，不能把资源根在两本账里重复预留。
        let reservations = [
            breakdown.stopTaskBytes, breakdown.maximumTerminalTailBytes,
        ]
        var installedLedger = AVPlayerRetainedGraphCapacityLedger()
        for (ordinal, bytes) in reservations.enumerated() where bytes > 0 {
            try reserveFutureObject(&installedLedger, ordinal: UInt8(ordinal), bytes: bytes)
        }
        return .init(applicationChargeableBytes: installedLedger.applicationChargeableBytes,
            allocationIdentityCount: UInt8(installedLedger.allocationIdentityCount),
            urlAllocationOwner: nil)
    }
}

private final class AVPlayerRetiredReplacementFence: @unchecked Sendable {
    let item: AVPlayerItemInstanceIdentity

    init(item: AVPlayerItemInstanceIdentity) { self.item = item }
}

/// Task22/上层 publication bundle 的最小生产接缝。Coordinator 不自增 generation，
/// 也不把旧 server capability 搬到新 item；request 与 evidence source 必须成套替换。
struct AVPlayerItemReplacementBundle: Sendable {
    let request: AVPlayerItemPreparationRequest
    let evidenceSource: any AVPlayerPreparationEvidenceProviding
}

/// request 与 evidence source 由同一 server 一次生成；调用方无法把一台 server 的
/// URL/publication 与另一台 server 的 completed-response authority 拼接。
struct LoopbackAVPlayerPreparationBundle: Sendable {
    let request: AVPlayerItemPreparationRequest
    let evidenceSource: LoopbackAVPlayerPreparationEvidenceSource

    init(server: LoopbackHTTPServer,
         item: AVPlayerItemInstanceIdentity,
         publicationSequence: UInt64? = nil) throws {
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        try self.init(evidenceSource: source, item: item,
                      publicationSequence: publicationSequence)
    }

    init(server: LoopbackHTTPServer,
         item: AVPlayerItemInstanceIdentity,
         pendingPublication: HLSPendingPublicationAuthority) throws {
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        try self.init(evidenceSource: source, item: item,
                      pendingPublication: pendingPublication)
    }

    /// lifecycle graph 需要先构造 coordinator 时，可把已安装到同一 server 单槽的
    /// source 交回 bundle；request 仍只能由该 source 私有持有的 server 生成。
    init(evidenceSource: LoopbackAVPlayerPreparationEvidenceSource,
         item: AVPlayerItemInstanceIdentity,
         publicationSequence: UInt64? = nil) throws {
        self.evidenceSource = evidenceSource
        request = try evidenceSource.makePreparationRequest(
            item: item, publicationSequence: publicationSequence)
    }

    init(evidenceSource: LoopbackAVPlayerPreparationEvidenceSource,
         item: AVPlayerItemInstanceIdentity,
         pendingPublication: HLSPendingPublicationAuthority) throws {
        self.evidenceSource = evidenceSource
        request = try evidenceSource.makePreparationRequest(
            item: item, pendingPublication: pendingPublication)
    }

    var replacementBundle: AVPlayerItemReplacementBundle {
        .init(request: request, evidenceSource: evidenceSource)
    }
}

@MainActor
final class AVPlayerItemCoordinator {
    static let boundaryCapacity = 128
    static let renditionCapacity = 8
    static let dependencyCapacity = 128

    nonisolated static var retainedGraphFutureReservationSnapshot:
        AVPlayerRetainedGraphFutureReservationSnapshot {
        func objectBytes(_ type: AnyClass) -> Int {
            malloc_good_size(class_getInstanceSize(type))
        }
        return .init(
            positiveRateCapabilityBytes: ControlTaskRegistry
                .BackendPositiveRateInvocation.retainedCapabilityAllocationBytes,
            stopTaskBytes: objectBytes(OutputPlayerStopTask.self),
            receiptIdentityBytes: objectBytes(AVPlayerQuiescenceReceiptIdentity.self),
            retiredFenceBytes: objectBytes(AVPlayerRetiredReplacementFence.self))
    }

    private let driver: any AVPlayerDriving
    private var evidenceSource: any AVPlayerPreparationEvidenceProviding
    private var evidenceSourceIdentity: UInt64
    private let allocator: PlaybackIdentityAllocator
    private let eventRelay: AVPlayerCoordinatorEventRelay
    /// core8KiB + async4KiB + 每谱系持久/临时URL8KiB；保守包络，不冒充逐对象实测。
    private let resourceContextReservation: PlaybackResourceContextReservation
    let backendPublicationReplacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot
    private var retainedGraphReservation = AVPlayerRetainedGraphReservation.empty
    private var retiredReplacementFence: AVPlayerRetiredReplacementFence?
    private var request: AVPlayerItemPreparationRequest?
    private var authorization: ControlTaskRegistry.BackendPositiveRateInvocation?
    private var authorizationArmed = false
    private var activationInFlight = false
    private var stopTask: OutputPlayerStopTask?
    private var invalidated = false
    private var automaticStopRequested = false
    private var preparationTicket: UInt64?
    /// 完整身份在bind时对应不可变request验真，保留业务证据而不再次复制request身份。
    private struct FrozenPublicationReadiness {
        let participants: AVPlayerReadinessParticipants
        let audioSelectionCapability: LoopbackAudioMediaSelectionCapability?
        let masterPlaylistCompleted: Bool
    }
    private var publicationReadiness: FrozenPublicationReadiness?
    private var renditionSelectionSlot: RenditionSelectionSlot = .unbound
    private(set) var state = AVPlayerItemCoordinatorState()
    var selectedRenditions: [AudioRenditionIdentity] {
        renditionSelectionSlot.rendition.map { [$0] } ?? []
    }
    private var requiredCoverageRenditions: [AudioRenditionIdentity] {
        guard let selected = renditionSelectionSlot.rendition else { return [] }
        return (publicationReadiness?.participants.compactMap {
            $0.mediaType == .video ? $0.renditionIdentity : nil
        } ?? []) + [selected]
    }
    private(set) var invalidationCount = 0
    private(set) var authorizationCount = 0
    private(set) var stopTaskCount = 0
    private(set) var publishedPlayingCount = 0
    private(set) var lastPublishedTimeControlStatus: AVPlayer.TimeControlStatus?
    private(set) var lastQuiescenceReceipt: AVPlayerQuiescenceReceiptIdentity?

    var phase: AVPlayerItemCoordinatorPhase {
        consumePendingPublicationAuthorityEvent()
        consumePendingRenditionSelectionEvent()
        return state.phase
    }
    var selectionRevision: UInt64 { state.selectionRevision }
    var currentItemIdentity: AVPlayerItemInstanceIdentity? { request?.item }
    var additionalTaskCount: Int {
        eventRelay.scheduledDeliveryCount
    }
    var additionalTimerCount: Int { driver.fixedTimerCount }
    var additionalWaiterCount: Int { driver.activeWaiterCount }

    /// 从当前真正持有URL的request同步借用Foundation owner及其Get API字符串。
    /// 诊断不保存owner/buffer，结果不参与安装、授权或清理控制流程。
    func inspectRetainedPreparationURLAllocations(
        _ body: (String, AnyObject, VPMallocAllocationRange, UInt, Int) -> Void
    ) {
        guard let request else { return }
        let urlOwner = request.itemURL as NSURL
        func record(_ role: String, owner: AnyObject, address: UnsafeRawPointer,
                    borrowedBytes: Int) {
            body(role, owner,
                 VPInspectMallocAllocationContainingRange(address, borrowedBytes),
                 UInt(bitPattern: address), borrowedBytes)
        }
        let urlPointer = UnsafeRawPointer(Unmanaged.passUnretained(urlOwner).toOpaque())
        record("resource-context/installed NSURL", owner: urlOwner,
               address: urlPointer, borrowedBytes: 1)
        let cfURL = unsafeBitCast(urlOwner, to: CFURL.self)
        guard let string = CFURLGetString(cfURL) else { return }
        let stringOwner = unsafeBitCast(string, to: AnyObject.self)
        let stringPointer = UnsafeRawPointer(Unmanaged.passUnretained(stringOwner).toOpaque())
        record("resource-context/installed URL CFString", owner: stringOwner,
               address: stringPointer, borrowedBytes: 1)
        let length = CFStringGetLength(string)
        if let utf8 = CFStringGetCStringPtr(
            string, CFStringBuiltInEncodings.UTF8.rawValue) {
            record("resource-context/installed URL UTF8 backing", owner: stringOwner,
                   address: UnsafeRawPointer(utf8), borrowedBytes: length + 1)
        } else if let characters = CFStringGetCharactersPtr(string) {
            record("resource-context/installed URL UTF16 backing", owner: stringOwner,
                   address: UnsafeRawPointer(characters),
                   borrowedBytes: length * MemoryLayout<UniChar>.stride)
        }
        withExtendedLifetime(request) {}
        withExtendedLifetime(urlOwner) {}
    }
#if DEBUG
    func inspectRetainedPreparationRoots(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        eventRelay.inspectLock(body)
        func record(_ role: String, _ object: AnyObject) {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
            guard malloc_zone_from_ptr(pointer) != nil, malloc_size(pointer) > 0 else {
                print("TASK21_OWNER_STORAGE 未验证原对象 \(role)")
                return
            }
            body(role, pointer, malloc_size(pointer))
        }
        record("HLS/原 coordinator 壳", self)
        record("HLS/原 coordinator relay", eventRelay)
        record("HLS/原 replacement authority slot", backendPublicationReplacementAuthoritySlot)
        guard let request else { return }
        for participant in request.audioParticipants {
            participant.terminalBinding?.inspectPreparationBindingAllocations(body)
        }
        // Array是原已持有值；只借其单字storage及原element范围交叉验证，
        // 不建同型数组，不把element减header当作基址。
        if let participants = request.audioParticipants.explicitValues, !participants.isEmpty,
           MemoryLayout.size(ofValue: participants) == MemoryLayout<UInt>.size {
            let address = withUnsafeBytes(of: participants) { $0.load(as: UInt.self) }
            if let base = UnsafeRawPointer(bitPattern: address),
               malloc_zone_from_ptr(base) != nil {
                let bytes = malloc_size(base)
                let valid = participants.withUnsafeBufferPointer { elements in
                    guard let start = elements.baseAddress else { return false }
                    let first = UInt(bitPattern: start)
                    return first >= address && first - address <= UInt(bytes)
                        && elements.count * MemoryLayout<AVPlayerAudioParticipantRequirement>.stride
                            <= bytes - Int(first - address)
                }
                if valid { body("HLS/原 request audioParticipants backing", base, bytes) }
                else { print("TASK21_OWNER_STORAGE 未验证原 request participants backing") }
            }
        }
        guard let url = retainedGraphReservation.urlAllocationOwner else { return }
        record("HLS/原 retained NSURL", url)
        // NSURL/CFURL公开toll-free桥接；Get API借原CFString，不调用Copy或生成absoluteString。
        let cfURL = unsafeBitCast(url, to: CFURL.self)
        if let base = CFURLGetBaseURL(cfURL) { record("HLS/原 NSURL baseURL", base) }
        if let string = CFURLGetString(cfURL) {
            record("HLS/原 NSURL CFString", string)
            let objectBase = UInt(bitPattern: Unmanaged.passUnretained(string).toOpaque())
            let stringPointer = UnsafeRawPointer(Unmanaged.passUnretained(string).toOpaque())
            let objectBytes = malloc_zone_from_ptr(stringPointer) == nil ? 0 : malloc_size(stringPointer)
            let characters = CFStringGetCStringPtr(string, CFStringBuiltInEncodings.UTF8.rawValue)
                .map { UnsafeRawPointer($0) }
                ?? CFStringGetCharactersPtr(string).map { UnsafeRawPointer($0) }
            if let characters {
                let address = UInt(bitPattern: characters)
                if address >= objectBase, address - objectBase < UInt(objectBytes) {
                    print("TASK21_OWNER_STORAGE NSURL 字符原内联于已计CFString")
                } else if malloc_zone_from_ptr(characters) != nil, malloc_size(characters) > 0 {
                    body("HLS/原 NSURL CFString 字符backing", characters, malloc_size(characters))
                } else { print("TASK21_OWNER_STORAGE 未验证 NSURL 字符原backing基址") }
            } else { print("TASK21_OWNER_STORAGE 未验证 NSURL 字符原存储") }
        }
        withExtendedLifetime(request) {}
        withExtendedLifetime(url) {}
    }
#endif
    var retainedGraphCapacitySnapshot: AVPlayerRetainedGraphReservationSnapshot {
        let bytes = retainedGraphReservation.applicationChargeableBytes
        return .init(
            applicationChargeableBytes: bytes,
            coordinatorObjectIdentity: nil,
            coordinatorObjectBytes: 0,
            coordinatorReservationCount: 0,
            allocationIdentityCount: Int(retainedGraphReservation.allocationIdentityCount))
    }

    init(driver: any AVPlayerDriving,
         evidenceSource: any AVPlayerPreparationEvidenceProviding,
         allocator: PlaybackIdentityAllocator = .shared,
         backendPublicationReplacementAuthoritySlot:
            ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot = .init()) throws {
        // 使用进程共享 nonce 域，不受注入 allocator 来源冲突影响；失败前无 hook 副作用。
        let evidenceSourceIdentity = try PlaybackIdentityAllocator.shared.next(in: .nonce)
        let resourceContextReservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 12 * 1_024)
        let eventRelay = AVPlayerCoordinatorEventRelay()
        self.driver = driver
        self.evidenceSource = evidenceSource
        self.evidenceSourceIdentity = evidenceSourceIdentity
        self.allocator = allocator
        self.resourceContextReservation = resourceContextReservation
        self.backendPublicationReplacementAuthoritySlot =
            backendPublicationReplacementAuthoritySlot
        self.eventRelay = eventRelay
        do {
            try PlaybackResourceContextLedger.shared.rebind(
                resourceContextReservation, to: .object(ObjectIdentifier(self)))
        } catch {
            PlaybackResourceContextLedger.shared.release(resourceContextReservation)
            throw error
        }
        eventRelay.activate(evidenceSourceIdentity)
        evidenceSource.installCompletedPublicationEventHandler { [weak self] sequence in
            guard let self, eventRelay.offerPublication(
                sequence, sourceIdentity: evidenceSourceIdentity) else { return }
            DispatchQueue.main.async { [self] in
                consumePendingPublicationAuthorityEvent(resumingQueued: true)
            }
        }
        evidenceSource.installRenditionSelectionEventHandler { [weak self] capability in
            guard let self, eventRelay.offerSelection(
                capability, sourceIdentity: evidenceSourceIdentity) else { return }
            DispatchQueue.main.async { [self] in
                consumePendingRenditionSelectionEvent(resumingQueued: true)
            }
        }
    }

    func install(_ request: AVPlayerItemPreparationRequest) throws {
        if let systemDriver = driver as? SystemAVPlayerDriver,
           let loopbackEvidence = evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource {
            try loopbackEvidence.bindPrepareWaitSlot(systemDriver.prepareWait)
        }
        guard self.request == nil, retiredReplacementFence == nil,
              state.phase != .preparing, state.phase != .stopping,
              request.item.itemGeneration > 0,
              request.audioParticipants.count <= Self.renditionCapacity,
              Set(request.audioParticipants.map(\.renditionIdentity)).count
                == request.audioParticipants.count else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        guard request.itemURL.scheme == "http",
              request.itemURL.host == "127.0.0.1" else {
            throw AVPlayerItemCoordinatorFailure.invalidTimeline
        }
        let urlAllocationOwner = request.itemURL as NSURL
        // 最多八项，先规范化为本 owner 的精确 backing；不继承调用方可能过量
        // reserveCapacity 的隐藏容量，也不在 lifecycle 内再次复制该数组。
        let compactParticipants = request.audioParticipants.compacted
        let compactRequest = AVPlayerItemPreparationRequest(
            itemURL: urlAllocationOwner as URL, item: request.item,
            publicationSequence: request.publicationSequence,
            audioRequirements: compactParticipants,
            directAudioOnlyRendition: request.directAudioOnlyRendition)
        let retainedGraphReservation = try AVPlayerRetainedGraphReservation.make(
            request: compactRequest, coordinator: self, driver: driver,
            evidenceSource: evidenceSource,
            eventRelay: eventRelay,
            replacementSlot: backendPublicationReplacementAuthoritySlot,
            urlAllocationOwner: urlAllocationOwner)
        let initialSelection = evidenceSource.currentAudioSelectionCapability(
            itemURL: compactRequest.itemURL, item: compactRequest.item,
            publicationSequence: compactRequest.publicationSequence)
        self.request = compactRequest
        self.retainedGraphReservation = retainedGraphReservation
        authorization = nil
        authorizationArmed = false
        stopTask = nil
        preparationTicket = nil
        lastQuiescenceReceipt = nil
        publicationReadiness = nil
        invalidated = false
        automaticStopRequested = false
        renditionSelectionSlot = initialSelection.map(RenditionSelectionSlot.bound)
            ?? .unbound
        state.phase = .installed
        state.itemGeneration = request.item.itemGeneration
        state.selectionRevision = 0
        try driver.install(url: request.itemURL, identity: request.item)
        driver.retainInstallationResourceContext(resourceContextReservation)
        let itemURL = request.itemURL
        let itemIdentity = request.item
        let sequence = request.publicationSequence
        try driver.installAccessLogURIObservation(item: request.item,
            classify: { [weak evidenceSource] uri in
                guard let evidenceSource else { return .invalidLocalResource }
                let selection = evidenceSource.currentAudioSelectionCapability(itemURL: itemURL,
                    item: itemIdentity, publicationSequence: sequence)
                return evidenceSource.classifyAccessLogURI(uri, itemURL: itemURL,
                    item: itemIdentity, publicationSequence: sequence, selected: selection?.renditionIdentity)
            }, handler: { [weak self] classification, item in
                guard let self, self.request?.item == item else { return }
                if classification == .conflicting { self.invalidateCurrentPublication() }
            })
        try driver.installNaturalEndTerminalHandler(item: request.item) { [weak self] capability, item in
            self?.consumeNaturalEndTerminal(capability, item: item)
        }
    }

    func bindPrepareInvocation(
        _ invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) throws {
        guard let item = request?.item,
              invocation.outputLifecycleEpoch == item.outputLifecycleEpoch,
              backendPublicationReplacementAuthoritySlot.currentAuthority()
                === invocation.replacementAuthority,
              invocation.replacementAuthority.matches(
                lifecycle: item.outputLifecycleEpoch,
                ticket: invocation.ticket) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func prepareCurrentItem(
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) async throws -> PreparedAVPlayerItem {
        try bindPrepareInvocation(invocation)
        return try await prepareCurrentItem()
    }

    /// Registry retirement 调用者必须先让旧 item 真实静止并卸载；这里只签下一次
    /// replacement install 的前置 fence，不生成未来 Task22 的 publication/request。
    func retireForReplacement(_ epoch: OutputLifecycleEpoch) async throws {
        guard invalidated, state.phase == .stopping,
              let installedRequest = request,
              installedRequest.item.outputLifecycleEpoch == epoch else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let item = installedRequest.item
        driver.cancelPendingPrerolls(item: item)
        driver.pause(item: item)
        let direct = try await driver.directState(item: item)
        guard direct.item == item, direct.rate == 0,
              direct.timeControlStatus == .paused else {
            throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
        }
        driver.replaceCurrentItemWithNil(item: item)
        driver.removeObservers(item: item)
        (evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource)?.retirePreparation()
        let quiescentReservation = retainedGraphReservation
            .forQuiescentReplacement(request: installedRequest)
        request = nil
        authorization = nil
        authorizationArmed = false
        publicationReadiness = nil
        renditionSelectionSlot = .invalid
        retiredReplacementFence = .init(item: item)
        state.phase = .quiescent
        retainedGraphReservation = quiescentReservation
    }

    /// Registry 的普通停止与 publication replacement 共用同一个 suspend/retire
    /// 接口；backend 必须在卸载前区分两者，避免把仍需复用的 coordinator 一并销毁。
    func requiresReplacementRetirement(_ epoch: OutputLifecycleEpoch) -> Bool {
        invalidated && state.phase == .stopping
            && request?.item.outputLifecycleEpoch == epoch
    }

    /// 新 request 只能由 Task22 bundle 提供；旧 generation/URL 从不在 coordinator
    /// 内自增或猜测。新 invocation 必须正是 Registry 更新到固定槽的同一对象。
    func installReplacement(
        _ bundle: AVPlayerItemReplacementBundle,
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) throws {
        let replacement = bundle.request
        guard let retired = retiredReplacementFence,
              request == nil, state.phase == .quiescent,
              replacement.item.itemGeneration > retired.item.itemGeneration,
              replacement.item.outputLifecycleEpoch.backendIdentity
                == retired.item.outputLifecycleEpoch.backendIdentity,
              invocation.ticket.backendIdentity
                == replacement.item.outputLifecycleEpoch.backendIdentity,
              backendPublicationReplacementAuthoritySlot.currentAuthority()
                === invocation.replacementAuthority,
              invocation.replacementAuthority.matches(
                lifecycle: replacement.item.outputLifecycleEpoch,
                ticket: invocation.ticket) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let priorEvidenceSource = evidenceSource
        let priorSourceIdentity = evidenceSourceIdentity
        let nextSourceIdentity = try PlaybackIdentityAllocator.shared.next(in: .nonce)
        retiredReplacementFence = nil
        do {
            bindEvidenceSource(bundle.evidenceSource, identity: nextSourceIdentity)
            try install(replacement)
            try bindPrepareInvocation(invocation)
        } catch {
            bindEvidenceSource(priorEvidenceSource, identity: priorSourceIdentity)
            retiredReplacementFence = retired
            throw error
        }
    }

    func observeAccessLogURI(_ uri: URL, item: AVPlayerItemInstanceIdentity) {
        guard request?.item == item, let request else { return }
        switch evidenceSource.classifyAccessLogURI(
            uri, itemURL: request.itemURL, item: item,
            publicationSequence: request.publicationSequence,
            selected: renditionSelectionSlot.rendition) {
        case .matching, .unrelated, .invalidLocalResource:
            return
        case .conflicting:
            invalidateCurrentPublication()
        }
    }

    func prepareCurrentItem() async throws -> PreparedAVPlayerItem {
        guard let request else { throw AVPlayerItemCoordinatorFailure.noCurrentItem }
        let operationTicket = try beginPreparation(request)
        defer {
            if preparationTicket == operationTicket { preparationTicket = nil }
        }
        PlaybackDiagnosticTracker.shared.append("avprep_wait_ready")
        guard try await driver.waitUntilReady(item: request.item) == request.item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        PlaybackDiagnosticTracker.shared.append("avprep_ready")
        try await driver.selectAudibleMedia(item: request.item)
        PlaybackDiagnosticTracker.shared.append("avprep_audio_selected")
        try await driver.primeMediaData(item: request.item)
        PlaybackDiagnosticTracker.shared.append("avprep_media_primed")
        try await awaitCompletedPublicationBinding(for: request)
        PlaybackDiagnosticTracker.shared.append("avprep_publication_bound")
        let selectedBinding = try selectedPreparationTerminalBinding(for: request)
        PlaybackDiagnosticTracker.shared.append("avprep_selection_bound")
        let endpointAuthority: AACEffectiveEndpointAuthority?
        if let rendition = selectedBinding.rendition {
            // 已存在 final 时立即走正式终点验真；尚未自然结束则只消费 prefix，
            // prepare 不等待未来 EOS，也不改写已经冻结的 prepared identity。
            endpointAuthority = rendition.endpointAuthority
        } else if let terminalBinding = selectedBinding.terminal {
            endpointAuthority = try await terminalBinding.awaitEndpointAuthority()
        } else {
            endpointAuthority = nil
        }
        guard self.request?.item == request.item,
              preparationTicket == operationTicket, !invalidated else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        PlaybackDiagnosticTracker.shared.append("avprep_timeline_begin")
        let timeline = try await evidenceSource.consumePlayerItemTimelineMapping(
            endpointAuthority: endpointAuthority, itemURL: request.itemURL,
            item: request.item, publicationSequence: request.publicationSequence,
            selection: renditionSelectionSlot.capability)
        PlaybackDiagnosticTracker.shared.append("avprep_timeline_ready_\(timeline != nil)")
        let context = try makePreparationSeekContext(
            request: request,
            timeline: timeline,
            endpointAuthority: endpointAuthority,
            requiresAAC: selectedBinding.terminal != nil
                || selectedBinding.rendition != nil)
        PlaybackDiagnosticTracker.shared.append("avprep_context_ready")
        try pass(.seek, request.item, preparationTicket: operationTicket)
        try validatePreparationSeek(
            try await driver.seek(to: context.playhead.playerItemTime,
                item: request.item, playhead: context.playhead),
            request: request, context: context)
        PlaybackDiagnosticTracker.shared.append("avprep_seek_ready")
        try pass(.loadedTimeRanges, request.item, preparationTicket: operationTicket)
        try validatePreparationLoaded(
            try await driver.waitForLoadedTimeRanges(item: request.item,
                playhead: context.playhead, covering: context.playerItemRequested),
            request: request, context: context)
        PlaybackDiagnosticTracker.shared.append("avprep_loaded_ready")
        try pass(.loadedTimeRanges, request.item, preparationTicket: operationTicket)
        try await evidenceSource.awaitCoverageReadiness(
            contexts: preparationCoverageContexts(context),
            requested: context.requested
        )
        let dependencies = try verifyPreparationCoverage(request: request, context: context)
        PlaybackDiagnosticTracker.shared.append("avprep_coverage_ready")
        try pass(.coverage, request.item, preparationTicket: operationTicket)
        try validatePreparationPreroll(
            try await driver.preroll(item: request.item, playhead: context.playhead),
            request: request, context: context)
        PlaybackDiagnosticTracker.shared.append("avprep_preroll_ready")
        try pass(.preroll, request.item, preparationTicket: operationTicket)
        try validatePreparationDirect(try await driver.directState(item: request.item),
                                      item: request.item)
        try pass(.preparedCAS, request.item, preparationTicket: operationTicket)
        try pass(.positiveRateAdmission, request.item, preparationTicket: operationTicket)
        return finishPreparation(request: request, context: context, dependencies: dependencies)
    }

    // 仅同步调用栈内的值，不新增持久字段或heap owner；将规范扫描与临时receipt
    // 留在各同步阶段，避免跨await保留无用局部。每个await后的原fencing顺序不变。
    private struct PreparationSeekContext {
        let playhead: PreparedPlayheadIdentity
        let requested: FMP4PresentationRange
        let playerItemRequested: FMP4PresentationRange
        let selection: ObservedRenditionSetReceipt
    }

    private func beginPreparation(_ request: AVPlayerItemPreparationRequest) throws -> UInt64 {
        guard request.audioParticipants.allSatisfy({ participant in
            participant.codec == .explicitlyNonAAC
                || participant.terminalBinding?.binding.renditionIdentity
                    == participant.renditionIdentity
        }) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        guard state.phase != .prepared else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard preparationTicket == nil else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        let operationTicket: UInt64
        do { operationTicket = try allocator.next(in: .prepare) }
        catch { throw AVPlayerItemCoordinatorFailure.identitySpaceExhausted }
        preparationTicket = operationTicket
        state.phase = .preparing
        return operationTicket
    }

    private func selectedPreparationTerminalBinding(for request: AVPlayerItemPreparationRequest)
        throws -> (terminal: AACWriterTerminalBinding?,
                   rendition: AACRenditionTerminalBinding?) {
        // direct audio-only 可以在 writer pending 时先停在 terminal 单槽；A/V 则先由
        // 真实 completed-response selection 确定所选音轨，不能从 audio.first 猜测。
        if request.directAudioOnlyRendition == nil,
           publicationReadiness == nil {
            try bindCompletedPublication(for: request)
        }
        let preliminaryRendition = selectedRenditions.first
            ?? request.directAudioOnlyRendition
        guard let preliminaryRendition,
              let selectedAudio = request.audioParticipants.first(where: {
                  $0.renditionIdentity == preliminaryRendition
              }) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        switch selectedAudio.codec {
        case .aac:
            guard selectedAudio.terminalBinding != nil
                    || selectedAudio.renditionBinding != nil else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
            // 稳定 rendition 的 prefix 映射以当前 publication 的实际 HTTP
            // selection 为输入；direct audio-only 也必须先采用这份正式 capability，
            // 不能因为无需等待 final endpoint 就把 nil selection 送进 server。
            if selectedAudio.renditionBinding != nil,
               publicationReadiness == nil {
                try bindCompletedPublication(for: request)
            }
            return (selectedAudio.terminalBinding, selectedAudio.renditionBinding)
        case .explicitlyNonAAC:
            return (nil, nil)
        }
    }

    private func makePreparationSeekContext(
        request: AVPlayerItemPreparationRequest, timeline: PlayerItemTimelineMappingAuthority?,
        endpointAuthority: AACEffectiveEndpointAuthority?, requiresAAC: Bool
    ) throws -> PreparationSeekContext {
        guard let timeline else { throw AVPlayerItemCoordinatorFailure.insufficientCoverage }
        if publicationReadiness == nil {
            try bindCompletedPublication(for: request)
        }
        let selectionCapability = renditionSelectionSlot.capability
        guard timeline.matches(
            itemURL: request.itemURL,
            item: request.item,
            publicationSequence: request.publicationSequence,
            selection: selectionCapability),
              timeline.commonSampleBoundaries.count <= Self.boundaryCapacity,
              timeline.commonSampleBoundaries.allSatisfy({
                  $0.value >= 0
                    && Self.compare($0, timeline.effectivePlaybackHorizon) <= 0
              }),
              timeline.renditionIdentity == nil
                || timeline.renditionIdentity == selectedRenditions.first else {
            throw AVPlayerItemCoordinatorFailure.invalidTimeline
        }
        let lead = ExactMediaTime(value: 3, timescale: 1)
        let limit = try timeline.effectivePlaybackHorizon.subtracting(lead)
        guard let boundary = timeline.commonSampleBoundaries.lazy
            .filter({ Self.compare($0, limit) <= 0 })
            .max(by: { Self.compare($0, $1) < 0 }) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let requested = try FMP4PresentationRange(start: boundary, duration: lead)
        guard let selectionCapability,
              selectionCapability === publicationReadiness?.audioSelectionCapability,
              Self.covers(selectionCapability.selectionWindow, requested) else {
            throw AVPlayerItemCoordinatorFailure.selectionChanged
        }
        let playhead = PreparedPlayheadIdentity(
            outputLifecycleEpoch: request.item.outputLifecycleEpoch,
            itemGeneration: request.item.itemGeneration,
            publicationSequence: request.publicationSequence,
            mediaTime: boundary,
            playerItemTime: try timeline.playerItemTime(for: boundary),
            seekNonce: try issueNonce(),
            renditionSelectionSlotNonce: try issueNonce(),
            audioSelectionCapability: selectionCapability,
            timelineMappingAuthority: timeline)
        let playerItemRequested = try FMP4PresentationRange(
            start: playhead.playerItemTime,
            duration: lead
        )
        let selection = ObservedRenditionSetReceipt(
            preparedPlayheadIdentity: playhead,
            selectionFenceRevision: state.selectionRevision,
            orderedRenditionIdentities: requiredCoverageRenditions)
        guard renditionSelectionSlot.rendition == selectedRenditions.first else {
            throw AVPlayerItemCoordinatorFailure.selectionChanged
        }
        if requiresAAC {
            guard timeline.aacPrefixReceipt != nil
                    || (timeline.aacEndpointReceipt.map({
                        endpointAuthority?.receipt == $0
                    }) == true) else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
            if let endpoint = timeline.aacEndpointReceipt {
                let itemEnd = try timeline.playerItemTime(for: endpoint.lastEffectiveEnd)
                guard itemEnd.value > 0 else {
                    throw AVPlayerItemCoordinatorFailure.invalidTimeline
                }
                try driver.constrainPlaybackEnd(to: itemEnd, item: request.item)
            }
        } else if timeline.aacEndpointReceipt != nil {
            throw AVPlayerItemCoordinatorFailure.invalidTimeline
        }
        return .init(playhead: playhead, requested: requested,
                     playerItemRequested: playerItemRequested, selection: selection)
    }

    private func validatePreparationSeek(_ seek: AVPlayerSeekReceipt,
        request: AVPlayerItemPreparationRequest, context: PreparationSeekContext) throws {
        guard seek.item == request.item, seek.playhead == context.playhead,
              seek.actualTime == context.playhead.playerItemTime else {
            throw AVPlayerItemCoordinatorFailure.seekMismatch
        }
    }

    private func validatePreparationLoaded(_ loaded: AVPlayerLoadedRangeReceipt,
        request: AVPlayerItemPreparationRequest, context: PreparationSeekContext) throws {
        guard loaded.item == request.item, loaded.playhead == context.playhead,
              loaded.requested == context.playerItemRequested else {
            throw AVPlayerItemCoordinatorFailure.loadedRangeMismatch
        }
    }

    private func verifyPreparationCoverage(request: AVPlayerItemPreparationRequest,
        context: PreparationSeekContext) throws -> AVPlayerCoverageDependencies {
        let playhead = context.playhead
        let timeline = playhead.timelineMappingAuthority
        let selection = context.selection
        let requested = context.requested
        var dependencies = AVPlayerCoverageDependencies()
        for rendition in requiredCoverageRenditions {
            let context = LoopbackCoverageContext(preparedPlayheadIdentity: playhead,
                observedRenditionSetReceipt: selection, renditionIdentity: rendition)
            guard let coverage = try evidenceSource.verifiedCoverage(context: context,
                requested: requested),
                coverage.preparedPlayheadIdentity == playhead,
                coverage.observedRenditionSetReceiptIdentity == selection.identity,
                coverage.renditionIdentity == rendition,
                coverage.itemGeneration == request.item.itemGeneration,
                Self.covers(coverage.presentationRange, requested),
                coverage.dependencies.allSatisfy({ $0.initializationBodyCompleted
                    && $0.mediaBodyCompleted }),
                timeline.matchesCoverageDependencies(coverage.dependencies, rendition: rendition) else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
            guard coverage.dependencies.count <= Self.dependencyCapacity - dependencies.count else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            try dependencies.append(contentsOf: coverage.dependencies)
        }
        guard dependencies.count <= Self.dependencyCapacity else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        return dependencies
    }

    private func preparationCoverageContexts(
        _ context: PreparationSeekContext
    ) -> [LoopbackCoverageContext] {
        requiredCoverageRenditions.map { rendition in
            LoopbackCoverageContext(
                preparedPlayheadIdentity: context.playhead,
                observedRenditionSetReceipt: context.selection,
                renditionIdentity: rendition
            )
        }
    }

    private func validatePreparationPreroll(_ preroll: AVPlayerPrerollReceipt,
        request: AVPlayerItemPreparationRequest, context: PreparationSeekContext) throws {
        guard preroll.item == request.item, preroll.playhead == context.playhead,
              preroll.succeeded else {
            throw AVPlayerItemCoordinatorFailure.prerollFailed
        }
    }

    private func validatePreparationDirect(_ direct: AVPlayerDirectState,
                                           item: AVPlayerItemInstanceIdentity) throws {
        guard direct.item == item, direct.rate == 0,
              direct.timeControlStatus != .playing else {
            throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
        }
    }

    private func finishPreparation(request: AVPlayerItemPreparationRequest,
        context: PreparationSeekContext, dependencies: AVPlayerCoverageDependencies)
        -> PreparedAVPlayerItem {
        let value = PreparedAVPlayerItem(item: request.item, identity: context.playhead,
            selectedRenditions: selectedRenditions, minimumCoverageDuration: context.requested.duration,
            coverageDependencies: dependencies)
        state.phase = .prepared
        return value
    }

    /// Task4/8/9 Registry 签发并已开放 interval 的唯一生产正 rate 入口。
    /// Coordinator 不生成第二份 permit；返回后 Registry 还会在原 command 上做最终 CAS。
    func activate(_ invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws
        -> BackendActivationResult {
        guard let item = request?.item,
              let invocationSnapshot = invocation.currentSnapshot,
              state.phase == .prepared || authorization == invocation || state.phase == .stopping,
              invocationSnapshot.interval.outputLifecycle == item.outputLifecycleEpoch,
              invocationSnapshot.interval.itemGeneration == item.itemGeneration,
              !invalidated, state.phase != .quiescent else {
            return .rejected
        }
        guard let request else { return .rejected }
        try revalidateCompletedPublication(for: request)
        if authorizationArmed, authorization == invocation {
            return .alreadyArmed(invocation.activation)
        }
        if state.phase == .stopping {
            // Registry 只能在 finishOutputPause 已退休原 suspend/activation record 后
            // 签发新的 invocation。此处仅消费旧 coordinator 静止终态：不 prepare、
            // seek 或重装 item；旧 receipt identity 随即失去 cleanup 签名能力。
            guard authorization == nil, !activationInFlight,
                  lastQuiescenceReceipt != nil, stopTask != nil else {
                return .rejected
            }
            authorizationArmed = false
            lastQuiescenceReceipt = nil
            stopTask = nil
            state.phase = .prepared
        }
        authorization = invocation
        authorizationCount = try Self.checkedIncrement(authorizationCount, allocator: allocator)
        state.phase = .authorized
        try driver.installTimeControlStatusRelay(
            item: item,
            activation: invocation.activation
        ) { [weak self] status, observedItem, activation in
            self?.observeTimeControlStatus(status, item: observedItem,
                                           activation: activation)
        }
        activationInFlight = true
        defer {
            activationInFlight = false
        }
        try await driver.play(invocation: invocation, item: item)
        guard self.request?.item == item, authorization == invocation, !invalidated,
              state.phase != .stopping, state.phase != .quiescent,
              invocation.revalidateCurrentAuthority() else { return .rejected }
        try revalidateCompletedPublication(for: request)
        authorizationArmed = true
        return .armed(invocation.activation)
    }

    func observeTimeControlStatus(_ status: AVPlayer.TimeControlStatus,
                                  item: AVPlayerItemInstanceIdentity,
                                  activation: ActivationEpoch) {
        guard request?.item == item, authorization?.activation == activation,
              state.phase != .stopping, state.phase != .quiescent else { return }
        guard authorization?.revalidateCurrentAuthority() == true else {
            invalidateCurrentPublication()
            return
        }
        lastPublishedTimeControlStatus = status
        if status == .playing {
            guard let next = try? Self.checkedIncrement(publishedPlayingCount,
                                                        allocator: allocator) else {
                invalidateCurrentPublication()
                return
            }
            publishedPlayingCount = next
            state.phase = .playing
        } else if status == .paused, authorizationArmed {
            // Registry 发起的暂停会先撤销 authorization，再调用 driver.pause；能走到
            // 这里的 paused 因而不是用户暂停。直播上游在 prepare 之后才 EOF 时，
            // AVPlayer 不一定有预先约束的终点能力，但会可靠地从 playing 转为
            // paused。必须复用 publication replacement，不能让 UI 继续宣称播放中。
            invalidateCurrentPublication()
        }
    }

    func stop(_ invocation: ControlTaskRegistry.BackendSuspendInvocation) async throws
        -> AVPlayerQuiescenceReceipt {
        try await stopRegistered(invocation)
    }

    func attestQuiescence(
        _ receipt: AVPlayerQuiescenceReceipt,
        invocation: ControlTaskRegistry.BackendSuspendInvocation,
        backendIdentity: PlaybackBackendIdentity
    ) throws -> AVPlayerBackendQuiescenceAttestation {
        guard accept(receipt), receipt.suspendTicket == invocation.suspendTicket,
              receipt.closeClaim == invocation.closeClaim,
              receipt.item.outputLifecycleEpoch.backendIdentity == backendIdentity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return .init(invocation: invocation, backendIdentity: backendIdentity,
                     receipt: receipt, preparedPreserved: true)
    }

    private func stopRegistered(_ invocation: ControlTaskRegistry.BackendSuspendInvocation) async throws
        -> AVPlayerQuiescenceReceipt {
        let registryIssuerIdentity = invocation.registryIssuerIdentity
        let suspendTicket = invocation.suspendTicket
        let closeClaim = invocation.closeClaim
        if let stopTask {
            guard stopTask.matches(suspendTicket: suspendTicket,
                                   closeClaim: closeClaim) else {
                throw AVPlayerItemCoordinatorFailure.operationInFlight
            }
            // 执行叶不可重入；正式重复 stop 在 Registry join 原 runner，终态在此重放。
            return try await stopTask.value(
                registryIssuerIdentity: registryIssuerIdentity,
                suspendTicket: suspendTicket, closeClaim: closeClaim)
        }
        guard let item = request?.item else { throw AVPlayerItemCoordinatorFailure.noCurrentItem }
        // authorized 阶段已经持有 Registry activation invocation，即使正 rate
        // 调用尚未 armed/playing，它仍是 suspendTicket 与 closeClaim 必须复验的
        // prior。不能用 activationInFlight 把这份正式权威错误折叠成 nil。
        let prior = authorization?.activation
        // Registry 原 suspend runner 在进入此叶之前已 join 全部正向 backend operation。
        // 绕过该串行入口的调用失败闭合，不安装第二个 activation drain continuation。
        guard !activationInFlight else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        guard suspendTicket.lifecycle == item.outputLifecycleEpoch,
              suspendTicket.priorActivation == prior else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if let closeClaim {
            guard prior != nil,
                  closeClaim.suspendTicket == suspendTicket,
                  closeClaim.intervalKey.outputLifecycle == item.outputLifecycleEpoch,
                  closeClaim.intervalKey.itemGeneration == item.itemGeneration,
                  closeClaim.intervalKey.activation == prior else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
        } else if prior != nil {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        state.phase = .stopping
        if automaticStopRequested {
            automaticStopRequested = false
        } else {
            stopTaskCount = try Self.checkedIncrement(stopTaskCount, allocator: allocator)
        }
        state.stopCount = try Self.checkedIncrement(state.stopCount, allocator: allocator)
        let task = OutputPlayerStopTask(item: item,
                                        registryIssuerIdentity: registryIssuerIdentity,
                                        suspendTicket: suspendTicket,
                                        closeClaim: closeClaim)
        stopTask = task
        // 只有同一 suspend/close claim 已通过双向身份校验并安装唯一 stop task 后，
        // 才撤销旧 authorization；失败准入不能留下无权威且无 stop owner 的裂缝。
        authorization = nil
        do throws(AVPlayerItemCoordinatorFailure) {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append(
                "cap_av_stop_pre_r\(driver.rate)_s\(driver.timeControlStatus.rawValue)"
            )
            #endif
            driver.cancelPendingPrerolls(item: item)
            driver.pause(item: item)
            let direct = try await driver.directState(item: item)
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append(
                "cap_av_stop_post_r\(direct.rate)_s\(direct.timeControlStatus.rawValue)"
            )
            #endif
            guard direct.item == item, direct.rate == 0,
                  direct.timeControlStatus == .paused else {
                throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
            }
            let receipt = AVPlayerQuiescenceReceipt(item: item,
                suspendTicket: suspendTicket, priorActivationEpoch: prior,
                stopNonce: closeClaim?.stopNonce, closeClaim: closeClaim,
                directlyConfirmedRateZero: true)
            guard request?.item == item, stopTask === task else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            lastQuiescenceReceipt = receipt.identity
            // Registry 的 replacement retirement 仍需消费同一停止终态；真正卸载
            // 完成前保持 stopping，避免把“已静止”和“已退休”混成一个阶段。
            state.phase = .stopping
            task.complete(.success(receipt))
            return receipt
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_av_stop_err_\(error)")
            #endif
            task.complete(.failure(error))
            throw error
        }
    }

    /// 静止子任务不拥有 lifecycle 卸载；cleanup owner 验收 receipt 后调用此入口。
    func completeLifecycleCleanup(_ receipt: AVPlayerQuiescenceReceipt) throws {
        guard accept(receipt), request?.item == receipt.item,
              state.phase == .stopping || state.phase == .quiescent else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        driver.replaceCurrentItemWithNil(item: receipt.item)
        driver.removeObservers(item: receipt.item)
        (evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource)?.retirePreparation()
        request = nil
        authorizationArmed = false
        retainedGraphReservation = .empty
        state.phase = .quiescent
    }

    func cancel(item: AVPlayerItemInstanceIdentity) {
        guard request?.item == item else { return }
        driver.cancelPendingPrerolls(item: item)
    }

    func timeoutCurrentStop() {
        // Deadline 属于外层控制任务；这里保留唯一 OutputPlayerStopTask 继续完成静止确认。
    }

    func accept(_ receipt: AVPlayerQuiescenceReceipt) -> Bool {
        guard lastQuiescenceReceipt === receipt.identity else { return false }
        if let close = receipt.closeClaim {
            return receipt.matches(item: receipt.item,
                                   suspendTicket: receipt.suspendTicket,
                                   priorActivationEpoch: receipt.priorActivationEpoch,
                                   closeClaim: close)
        }
        return receipt.priorActivationEpoch == nil
            && receipt.stopNonce == nil
            && receipt.suspendTicket.priorActivation == nil
            && receipt.suspendTicket.lifecycle == receipt.item.outputLifecycleEpoch
            && receipt.directlyConfirmedRateZero
    }

    private func issueNonce() throws -> UInt64 {
        do { return try allocator.next(in: .nonce) }
        catch {
            invalidated = true
            throw AVPlayerItemCoordinatorFailure.identitySpaceExhausted
        }
    }

    private func pass(_ fence: AVPlayerPreparationFence,
                                            _ item: AVPlayerItemInstanceIdentity,
                      preparationTicket: UInt64? = nil) throws {
        driver.preparationFenceReached(fence, item: item)
        guard request?.item == item else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        if let preparationTicket, self.preparationTicket != preparationTicket {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if let request { try revalidateCompletedPublication(for: request) }
        guard !invalidated else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
    }

    private func bindCompletedPublication(for request: AVPlayerItemPreparationRequest) throws {
        guard publicationReadiness == nil,
              let readiness = publicationBindingReadiness(for: request),
              readiness.itemURL == request.itemURL,
              readiness.itemGeneration == request.item.itemGeneration,
              readiness.publicationSequence == request.publicationSequence,
              !readiness.participants.isEmpty,
              readiness.participants.count <= 4,
              Set(readiness.participants.map(\.participantID)).count
                == readiness.participants.count,
              readiness.participants.allSatisfy({
                  $0.initializationBodyCompleted && $0.mediaBodyCompleted
              }) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let audio = readiness.participants.filter { $0.mediaType == .audio }
        let video = readiness.participants.filter { $0.mediaType == .video }
        if let direct = request.directAudioOnlyRendition {
            guard !readiness.masterPlaylistCompleted, video.isEmpty,
                  audio.count == 1, audio[0].renditionIdentity == direct else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        } else {
            guard readiness.masterPlaylistCompleted, !audio.isEmpty,
                  video.count == 1 else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        if let capability = readiness.audioSelectionCapability {
            guard capability.itemGeneration == request.item.itemGeneration,
                  capability.publicationSequence == request.publicationSequence,
                  let participant = audio.first(where: {
                    $0.participantID == capability.participantID
                        && $0.renditionIdentity == capability.renditionIdentity
                  }), request.audioParticipants.contains(where: {
                    $0.renditionIdentity == capability.renditionIdentity
                  }) else { throw AVPlayerItemCoordinatorFailure.insufficientCoverage }
            if let current = renditionSelectionSlot.capability, current !== capability {
                invalidateCurrentPublication()
                throw AVPlayerItemCoordinatorFailure.selectionChanged
            }
            renditionSelectionSlot = .bound(capability)
            _ = participant
        } else { throw AVPlayerItemCoordinatorFailure.insufficientCoverage }
        publicationReadiness = .init(participants: readiness.participants,
            audioSelectionCapability: readiness.audioSelectionCapability,
            masterPlaylistCompleted: readiness.masterPlaylistCompleted)
        state.selectionRevision = try Self.checkedIncrement(state.selectionRevision,
                                                             allocator: allocator)
    }

    /// `AVPlayerItem.status == readyToPlay` 只证明 AVFoundation 已读到可播放前缀；
    /// 音轨选择和最后一个 init/media HTTP completion 可能在紧随其后的回调中到达。
    /// 真实 loopback 源因此在同一 prepare 事务内做有界等待，不能把这个事件竞态
    /// 误判为永久 coverage 失败。可控 fake 仍保持同步失败语义。
    private func awaitCompletedPublicationBinding(
        for request: AVPlayerItemPreparationRequest
    ) async throws {
        guard publicationReadiness == nil else { return }
        guard evidenceSource is LoopbackAVPlayerPreparationEvidenceSource else {
            try bindCompletedPublication(for: request)
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            consumePendingPublicationAuthorityEvent()
            consumePendingRenditionSelectionEvent()
            do {
                try bindCompletedPublication(for: request)
                return
            } catch AVPlayerItemCoordinatorFailure.insufficientCoverage {
                guard ContinuousClock.now < deadline else {
                    throw AVPlayerItemCoordinatorFailure.insufficientCoverage
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func revalidateCompletedPublication(
        for request: AVPlayerItemPreparationRequest
    ) throws {
        guard let frozen = publicationReadiness,
              let current = publicationBindingReadiness(for: request, latest: true),
              current.itemURL == request.itemURL,
              current.itemGeneration == request.item.itemGeneration,
              current.publicationSequence == request.publicationSequence,
              current.masterPlaylistCompleted == frozen.masterPlaylistCompleted,
              current.audioSelectionCapability === frozen.audioSelectionCapability,
              current.participants == frozen.participants else {
            invalidateCurrentPublication()
            throw AVPlayerItemCoordinatorFailure.selectionChanged
        }
    }

    private func publicationBindingReadiness(for request: AVPlayerItemPreparationRequest,
                                             latest: Bool = false) -> AVPlayerPublicationBindingReadiness? {
        if let source = evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource {
            return source.preparationPublicationBasis(itemURL: request.itemURL, item: request.item,
                publicationSequence: request.publicationSequence).map(AVPlayerPublicationBindingReadiness.init)
        }
        let value = latest ? evidenceSource.consumeLatestCompletedPublication(
            itemURL: request.itemURL, item: request.item) : nil
        return (value ?? evidenceSource.consumeCompletedPublication(itemURL: request.itemURL,
            item: request.item, publicationSequence: request.publicationSequence))
            .map(AVPlayerPublicationBindingReadiness.init)
    }

    private func completedPublicationDidAdvance(sequence: UInt64) {
        guard let request, publicationReadiness != nil else { return }
        if evidenceSource is LoopbackAVPlayerPreparationEvidenceSource,
           sequence != request.publicationSequence {
            // 普通滚动只推进活动历史，冻结owner仍投影原publication。
            return
        }
        guard sequence == request.publicationSequence else {
            invalidateCurrentPublication()
            return
        }
        do { try revalidateCompletedPublication(for: request) }
        catch { /* revalidate 已失败闭合并投递共享 stop/reprepare 入口。 */ }
    }

    private func consumePendingPublicationAuthorityEvent(resumingQueued: Bool = false) {
        guard let delivery = eventRelay.takePublication(resumingQueued: resumingQueued),
              delivery.sourceIdentity == evidenceSourceIdentity else { return }
        completedPublicationDidAdvance(sequence: delivery.sequence)
    }

    private func consumePendingRenditionSelectionEvent(resumingQueued: Bool = false) {
        guard let delivery = eventRelay.takeSelection(resumingQueued: resumingQueued) else { return }
        let capability = delivery.capability
        defer { eventRelay.finishSelection(capability) }
        guard delivery.sourceIdentity == evidenceSourceIdentity, let request,
              capability.itemGeneration == request.item.itemGeneration,
              capability.publicationSequence == request.publicationSequence else { return }
        guard !delivery.conflicted else {
            invalidateCurrentPublication()
            return
        }
        switch renditionSelectionSlot {
        case .unbound:
            renditionSelectionSlot = .bound(capability)
        case .bound(let current):
            guard current === capability else {
                invalidateCurrentPublication()
                return
            }
        case .invalid:
            return
        }
    }

    private func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) {
        guard request?.item == item,
              let result = driver.consumeNaturalEndTerminal(capability, item: item) else {
            invalidateCurrentPublication()
            return
        }
        if case .failure = result {
            invalidateCurrentPublication()
        }
    }

    private func invalidateCurrentPublication() {
        guard !invalidated else { return }
        invalidated = true
        renditionSelectionSlot = .invalid
        if let next = try? Self.checkedIncrement(invalidationCount, allocator: allocator) {
            invalidationCount = next
        }
        state.phase = .stopping
        if let next = try? Self.checkedIncrement(stopTaskCount, allocator: allocator) {
            stopTaskCount = next
            automaticStopRequested = true
        }
        guard backendPublicationReplacementAuthoritySlot.requestReplacement() else {
            // authority 缺失、过期或已消费属于 lifecycle 不变量破坏。此时不能
            // 继续保留正速播放：同步撤销 preroll 并请求 AVPlayer 归零；phase
            // 保持 stopping，明确表示 Registry 尚未完成接管/retirement。
            automaticStopRequested = false
            if let item = request?.item {
                driver.cancelPendingPrerolls(item: item)
                driver.pause(item: item)
            }
            return
        }
    }

    private func bindEvidenceSource(
        _ source: any AVPlayerPreparationEvidenceProviding, identity sourceIdentity: UInt64
    ) {
        evidenceSource = source
        evidenceSourceIdentity = sourceIdentity
        eventRelay.activate(sourceIdentity)
        source.installCompletedPublicationEventHandler { [weak self] sequence in
            guard let self, self.eventRelay.offerPublication(
                sequence, sourceIdentity: sourceIdentity) == true else { return }
            DispatchQueue.main.async { [self] in
                consumePendingPublicationAuthorityEvent(resumingQueued: true)
            }
        }
        source.installRenditionSelectionEventHandler { [weak self] capability in
            guard let self, self.eventRelay.offerSelection(
                capability, sourceIdentity: sourceIdentity) == true else { return }
            DispatchQueue.main.async { [self] in
                consumePendingRenditionSelectionEvent(resumingQueued: true)
            }
        }
    }

    private static func compare(_ lhs: ExactMediaTime, _ rhs: ExactMediaTime) -> Int32 {
        CMTimeCompare(lhs.cmTime, rhs.cmTime)
    }

    private static func covers(_ actual: FMP4PresentationRange,
                               _ requested: FMP4PresentationRange) -> Bool {
        compare(actual.start, requested.start) <= 0 && compare(actual.end, requested.end) >= 0
    }

    private static func normalized(_ ranges: [FMP4PresentationRange]) throws
        -> [FMP4PresentationRange] {
        guard ranges.count <= boundaryCapacity else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        let sorted = ranges.sorted { compare($0.start, $1.start) < 0 }
        var result: [FMP4PresentationRange] = []
        result.reserveCapacity(boundaryCapacity)
        for range in sorted {
            if let last = result.last, compare(range.start, last.end) <= 0 {
                let end = compare(last.end, range.end) >= 0 ? last.end : range.end
                result[result.count - 1] = try FMP4PresentationRange(
                    start: last.start,
                    duration: end.subtracting(last.start)
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func checkedIncrement(_ value: UInt64,
                                         allocator: PlaybackIdentityAllocator) throws -> UInt64 {
        let next = value.addingReportingOverflow(1)
        guard !next.overflow else {
            allocator.markIdentitySpaceExhausted()
            throw AVPlayerItemCoordinatorFailure.identitySpaceExhausted
        }
        return next.partialValue
    }

    private static func checkedIncrement(_ value: Int,
                                         allocator: PlaybackIdentityAllocator) throws -> Int {
        let next = value.addingReportingOverflow(1)
        guard !next.overflow else {
            allocator.markIdentitySpaceExhausted()
            throw AVPlayerItemCoordinatorFailure.identitySpaceExhausted
        }
        return next.partialValue
    }
}

// 由证据源原有锁保护；两位状态不持有额外任务或引用。
struct TimelineMappingRetryState {
    private var inFlight = false
    private var requested = false
    // 01 是已排队、尚未出队的唯一授权，也必须阻止历史域交接。
    var isInFlight: Bool { inFlight || requested }

    mutating func begin() -> Bool {
        guard !inFlight else {
            requested = true
            return false
        }
        guard !requested else { return false }
        inFlight = true
        return true
    }

    mutating func beginQueued(hasPending: Bool) -> Bool {
        guard !inFlight, requested else { return false }
        requested = false
        guard hasPending else { return false }
        inFlight = true
        return true
    }

    mutating func cancelPending() {
        if inFlight { requested = false }
    }

    mutating func finish(hasPending: Bool, matchesAttempt: Bool, waiting: Bool) -> Bool {
        // 旧尝试已退休时，requested 属于锁内已安装的后继，不能吞掉其唯一唤醒。
        // 后继取消或 terminal 会清 pending/requested；本次匹配且完成则不重跑。
        let rerun = hasPending && (!matchesAttempt || waiting) && requested
        inFlight = false
        requested = rerun
        return rerun
    }
}

/// 两个不同准备事务共享进程准入；cleanup不能提前归还外部冻结视图仍持有的槽。
final class FrozenPreparationOwner: @unchecked Sendable {
    private static let admissionLock = PreparationStorageLock()
    nonisolated(unsafe) private static var admissionReferences: (UInt16, UInt16) = (0, 0)
    nonisolated(unsafe) private static var historyDomain: UUID?
    nonisolated(unsafe) private static var historyServer: LoopbackHTTPServer?
    static var activeHistoryServer: LoopbackHTTPServer? {
        admissionLock.withLock { historyServer }
    }
    let slot: UInt8
    private let resourceContextReservation: PlaybackResourceContextReservation
    private var videoRetirementRoleClaimed = false

    /// 视频图只能取得这个不可伪造的角色引用，不能接触或复制 reservation。
    /// role 的生命周期跟随异步视频尾；它强持原 owner，故 19KiB 仍只记一次。
    func claimVideoRetirementRole() -> FrozenPreparationVideoRetirementRole? {
        Self.admissionLock.withLock {
            guard !videoRetirementRoleClaimed else { return nil }
            videoRetirementRoleClaimed = true
            return FrozenPreparationVideoRetirementRole(preparationOwner: self)
        }
    }

    fileprivate func releaseVideoRetirementRoleClaim() {
        Self.admissionLock.withLock { videoRetirementRoleClaimed = false }
    }
    private var historyState: UInt8 = 0
    var isHistoryActive: Bool { Self.admissionLock.withLock { historyState == 1 } }
    var isRetired: Bool { Self.admissionLock.withLock { historyState == 2 } }
    private(set) var metadataStore: SealedMediaStore?
    var frozenPublication: LoopbackFrozenPublicationStorage?
    var timelineStorage: FrozenTimelineMappingStorage?
    weak var timelineAuthority: PlayerItemTimelineMappingAuthority?
    private(set) var completionIsFrozen = false
    private var firstCoverage: FrozenCoverageStorage?
    private var secondCoverage: FrozenCoverageStorage?
    private let coverageIndices: UnsafeMutablePointer<UInt16>
    func coverage(at index: UInt8) -> FrozenCoverageStorage? {
        index == 0 ? firstCoverage : secondCoverage
    }
    func coverageResource(at ordinal: Int, coverage index: UInt8) -> UInt16 {
        let descriptor = coverage(at: index)!
        precondition(ordinal >= 0 && ordinal < descriptor.count)
        return coverageIndices[Int(descriptor.offset) + ordinal]
    }
    func setCoverage(_ value: FrozenCoverageStorage, indices: FrozenCoverageIndices, at index: UInt8) {
        precondition(Int(value.offset) + Int(value.count) <= 128)
        for ordinal in 0..<Int(value.count) {
            coverageIndices[Int(value.offset) + ordinal] = indices[ordinal]
        }
        if index == 0 { precondition(firstCoverage == nil); firstCoverage = value }
        else { precondition(secondCoverage == nil); secondCoverage = value }
    }
    private var completedResources: (UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0)

    func retainCompletedResource(in store: SealedMediaStore, key: HLSResourceKey) throws {
        guard !completionIsFrozen, metadataStore == nil || metadataStore === store else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let index = try store.retainPreparationResource(key, ownerSlot: slot)
        metadataStore = store
        withUnsafeMutableBytes(of: &completedResources) { bytes in
            let words = bytes.bindMemory(to: UInt64.self)
            words[index / 64] |= UInt64(1) << (index % 64)
        }
    }

    @discardableResult
    func retainMetadata(in store: SealedMediaStore, key: HLSResourceKey) throws -> Int {
        guard !completionIsFrozen, metadataStore == nil || metadataStore === store else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let index = try store.retainPreparationResource(key, ownerSlot: slot, requiresCompleted: false)
        metadataStore = store
        return index
    }

    func freezeCompletedResources() throws {
        guard !completionIsFrozen, let store = metadataStore else { return }
        for index in 0..<300 {
            guard let resource = store.preparationResource(slot: index, ownerSlot: slot),
                  store.preparationResourceIsComplete(slot: index, ownerSlot: slot) else { continue }
            try retainCompletedResource(in: store, key: resource.key)
        }
        completionIsFrozen = true
    }

    func rollbackUnpublishedMetadata() {
        precondition(frozenPublication == nil && !completionIsFrozen)
        metadataStore?.releasePreparationMetadata(ownerSlot: slot)
        metadataStore = nil
    }

    func containsCompletedResource(_ index: Int) -> Bool {
        guard (0..<300).contains(index) else { return false }
        return withUnsafeBytes(of: completedResources) { bytes in
            bytes.bindMemory(to: UInt64.self)[index / 64] & (UInt64(1) << (index % 64)) != 0
        }
    }

    static func claimHistoryDomain(_ identity: UUID, server: LoopbackHTTPServer) -> Bool {
        admissionLock.withLock {
            guard historyDomain == nil || historyDomain == identity else { return false }
            historyDomain = identity
            historyServer = server
            return true
        }
    }

    static func releaseHistoryDomain(_ identity: UUID) {
        admissionLock.withLock {
            if historyDomain == identity { historyDomain = nil; historyServer = nil }
        }
    }

    func setHistoryActive(_ active: Bool) {
        Self.admissionLock.withLock { historyState = active ? 1 : 2 }
    }

    static func reserve() throws -> FrozenPreparationOwner {
        let reservation = try PlaybackResourceContextLedger.shared.reserve(
            allocationIdentity: .stable(UUID()), bytes: 19 * 1_024)
        do {
            let owner = try admissionLock.withLock { () throws -> FrozenPreparationOwner in
                let slot: UInt8
                if admissionReferences.0 == 0 { slot = 1; admissionReferences.0 = 1 }
                else if admissionReferences.1 == 0 { slot = 2; admissionReferences.1 = 1 }
                else { throw AVPlayerItemCoordinatorFailure.capacityExceeded }
                return FrozenPreparationOwner(slot: slot,
                    resourceContextReservation: reservation)
            }
            try PlaybackResourceContextLedger.shared.rebind(
                reservation, to: .object(ObjectIdentifier(owner)))
            return owner
        } catch {
            PlaybackResourceContextLedger.shared.release(reservation)
            throw error
        }
    }

    static func retainAdmission(slot: UInt8) -> Bool {
        admissionLock.withLock {
            guard slot == 1 || slot == 2 else { return false }
            let value = slot == 1 ? admissionReferences.0 : admissionReferences.1
            let next = value.addingReportingOverflow(1)
            guard value > 0, !next.overflow else { return false }
            if slot == 1 { admissionReferences.0 = next.partialValue }
            else { admissionReferences.1 = next.partialValue }
            return true
        }
    }

    static func releaseAdmission(slot: UInt8) {
        admissionLock.withLock {
            precondition(slot == 1 || slot == 2)
            let value = slot == 1 ? admissionReferences.0 : admissionReferences.1
            let next = value.subtractingReportingOverflow(1)
            precondition(!next.overflow, "准备准入引用不可下溢")
            if slot == 1 { admissionReferences.0 = next.partialValue }
            else { admissionReferences.1 = next.partialValue }
        }
    }

    private init(slot: UInt8,
                 resourceContextReservation: PlaybackResourceContextReservation) {
        self.slot = slot
        self.resourceContextReservation = resourceContextReservation
        coverageIndices = .allocate(capacity: 128)
        coverageIndices.initialize(repeating: 0, count: 128)
    }

#if DEBUG
    func inspectAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        body("owned/准备 owner", pointer, malloc_size(pointer))
        inspectNativePreparationWeakSideTable("准备owner", self, body)
        body("owned/128 coverage 索引原 backing", UnsafeRawPointer(coverageIndices), malloc_size(coverageIndices))
        Self.admissionLock.inspect("owned/进程准入锁", body)
        if let timelineAuthority {
            let authorityPointer = UnsafeRawPointer(Unmanaged.passUnretained(timelineAuthority).toOpaque())
            body("owned/原 timeline authority wrapper", authorityPointer, malloc_size(authorityPointer))
            inspectNativePreparationWeakSideTable("timeline authority", timelineAuthority, body)
        }
    }
#endif

    deinit {
        coverageIndices.deinitialize(count: 128)
        coverageIndices.deallocate()
        metadataStore?.releasePreparationMetadata(ownerSlot: slot)
        metadataStore = nil
        frozenPublication = nil
        timelineStorage = nil
        Self.releaseAdmission(slot: slot)
        PlaybackResourceContextLedger.shared.release(resourceContextReservation)
    }
}

/// 固定图构造前的最小视频角色传递。role 强持 preparationOwner，因而间接保留
/// publication/metadata 与其唯一 19KiB reservation；当前视频图、raw backing tail
/// 和退休 context 都不被 preparationOwner 反向持有，故这条有限尾链没有回边。
final class FrozenPreparationVideoRetirementRole: @unchecked Sendable {
    let preparationOwner: FrozenPreparationOwner
    fileprivate init(preparationOwner: FrozenPreparationOwner) {
        self.preparationOwner = preparationOwner
    }
    deinit { preparationOwner.releaseVideoRetirementRoleClaim() }
}

final class LoopbackAVPlayerPreparationEvidenceSource: AVPlayerPreparationEvidenceProviding,
    @unchecked Sendable {
    private struct PendingTimelineMapping {
        let identity: UInt64
        let endpointAuthority: AACEffectiveEndpointAuthority?
        let publicationSequence: UInt64
        var selection: LoopbackAudioMediaSelectionCapability?
        let route: UInt8
        var waitToken: AVPlayerPrepareWaitSlot.Token { .init(generation: identity, phase: .mapping) }
    }

    private enum TimelineMappingAttempt {
        case waiting
        case completed(PlayerItemTimelineMappingAuthority)
        case failed(AVPlayerFixedPreparationFailure)
    }

    private let server: LoopbackHTTPServer
    let preparationOwner: FrozenPreparationOwner
    private let lock = PreparationStorageLock()
    private var consumedEvidence: LoopbackCompletedPublicationEvidence? {
        get {
            guard !preparationOwner.isRetired, preparationOwner.completionIsFrozen else { return nil }
            return .init(preparationOwner: preparationOwner)
        }
        set {
            if let newValue { precondition(newValue.preparationOwner === preparationOwner) }
        }
    }
    private var completedSequence: UInt64 = 0
    private var latestCompletedSequence: UInt64? {
        get { completedSequence == 0 ? nil : completedSequence }
        set { precondition(newValue == nil || newValue! > 0); completedSequence = newValue ?? 0 }
    }
    private var publicationEventHandler: (@Sendable (UInt64) -> Void)?
    private var renditionSelectionEventHandler:
        (@Sendable (LoopbackAudioMediaSelectionCapability) -> Void)?
    private var latestRenditionSelection: LoopbackAudioMediaSelectionCapability?
    private enum MappingStorage {
        case idle
        case pending(PendingTimelineMapping)
        case completed(PlayerItemTimelineMappingAuthority, generation: UInt64)
    }
    private var mappingStorage = MappingStorage.idle
    private var pendingTimelineMapping: PendingTimelineMapping? {
        get { if case .pending(let value) = mappingStorage { return value }; return nil }
        set {
            if let newValue { mappingStorage = .pending(newValue) }
            else if case .pending = mappingStorage { mappingStorage = .idle }
        }
    }
    private var timelineTerminalFailed = false
    private var timelineRetry = TimelineMappingRetryState()
    private var prepareWait: AVPlayerPrepareWaitSlot?
    private var completedMapping: PlayerItemTimelineMappingAuthority? {
        get { if case .completed(let value, _) = mappingStorage { return value }; return nil }
        set {
            if let newValue { mappingStorage = .completed(newValue, generation: pendingTimelineMapping?.identity ?? 0) }
            else if case .completed = mappingStorage { mappingStorage = .idle }
        }
    }

    func bindPrepareWaitSlot(_ slot: AVPlayerPrepareWaitSlot) throws {
        try lock.withLock {
            guard pendingTimelineMapping == nil,
                  prepareWait == nil || prepareWait === slot || prepareWait?.isActive == false else {
                throw AVPlayerItemCoordinatorFailure.operationInFlight
            }
            prepareWait = slot
        }
    }

    static func make(server: LoopbackHTTPServer) throws
        -> LoopbackAVPlayerPreparationEvidenceSource {
        let owner = try FrozenPreparationOwner.reserve()
        return .init(server: server, preparationOwner: owner)
    }

    private init(server: LoopbackHTTPServer, preparationOwner: FrozenPreparationOwner) {
        self.preparationOwner = preparationOwner
        self.server = server
        // 第二个owner可提前预留；旧source未退役时新source保持休眠，不覆盖handler。
        _ = activateHistoryIfAvailable()
    }

#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        lock.withLock {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body("HLS/原 evidence source 壳", pointer, malloc_size(pointer))
            inspectNativePreparationWeakSideTable("source", self, body)
            lock.inspect("owned/source 原锁", body)
            preparationOwner.inspectAllocations(body)
        }
    }
#endif

    private func activateHistoryIfAvailable() -> Bool {
        guard !preparationOwner.isRetired else { return false }
        if preparationOwner.isHistoryActive { return true }
        guard server.activatePreparationHistory(owner: preparationOwner) else { return false }
        preparationOwner.setHistoryActive(true)
        installServerHooks()
        return true
    }

    private func installServerHooks() {
        server.installCompletedPublicationEventHandler { [weak self, owner = preparationOwner] sequence in
            defer { withExtendedLifetime(owner) {} }
            guard self?.preparationOwner.isHistoryActive == true else { return }
            let event = self?.lock.withLock {
                () -> (UInt64, (@Sendable (UInt64) -> Void))? in
                let advanced: UInt64
                if let current = self?.latestCompletedSequence {
                    guard sequence > current else { return nil }
                    advanced = sequence
                } else {
                    advanced = sequence
                }
                self?.latestCompletedSequence = advanced
                guard let handler = self?.publicationEventHandler else { return nil }
                return (advanced, handler)
            }
            if let (advanced, handler) = event { handler(advanced) }
            self?.retryPendingTimelineMapping()
        }
        server.installCompletedResourceEventHandler { [weak self, owner = preparationOwner] in
            defer { withExtendedLifetime(owner) {} }
            guard self?.preparationOwner.isHistoryActive == true else { return }
            self?.retryPendingTimelineMapping()
        }
        server.installRenditionSelectionEventHandler { [weak self, owner = preparationOwner] capability in
            defer { withExtendedLifetime(owner) {} }
            guard self?.preparationOwner.isHistoryActive == true else { return }
            let handler = self?.lock.withLock {
                self?.latestRenditionSelection = capability
                if self?.pendingTimelineMapping?.publicationSequence
                        == capability.publicationSequence,
                   self?.pendingTimelineMapping?.selection == nil {
                    // selection terminal 与 pending waiter 在同一锁域绑定；后续 retry
                    // 只能携带这一个 opaque capability，nil 不再是 server 通配符。
                    self?.pendingTimelineMapping?.selection = capability
                }
                return self?.renditionSelectionEventHandler
            }
            handler?(capability)
            // timeline mapping 可能先看到 completed publication、后看到真正覆盖
            // E-3...E 的 audio media terminal。selection 边沿既要通知 coordinator，
            // 也必须唤醒同一 evidence source 的固定单槽 waiter。
            self?.retryPendingTimelineMapping()
        }
        server.installTimelineFailureEventHandler { [weak self, owner = preparationOwner] event in
            defer { withExtendedLifetime(owner) {} }
            guard self?.preparationOwner.isHistoryActive == true else { return }
            self?.receiveTimelineFailure(event)
        }
    }

    deinit { server.retirePreparationHistory(ownerSlot: preparationOwner.slot) }

    func retirePreparation() {
        preparationOwner.setHistoryActive(false)
        let retirement = lock.withLock { () -> (PendingTimelineMapping?, Bool, AVPlayerPrepareWaitSlot?) in
            let pending = pendingTimelineMapping
            pendingTimelineMapping = nil
            timelineRetry.cancelPending()
            publicationEventHandler = nil
            renditionSelectionEventHandler = nil
            latestRenditionSelection = nil
            consumedEvidence = nil
            completedMapping = nil
            return (pending, !timelineRetry.isInFlight, prepareWait)
        }
        // 锁外 mapping 的原 selection/owner 根尚未退役时，不能开放下一历史制造域。
        if retirement.1 { server.retirePreparationHistory(ownerSlot: preparationOwner.slot) }
        if let pending = retirement.0 {
            retirement.2!.resolve(.failure(AVPlayerItemCoordinatorFailure.staleIdentity),
                token: pending.waitToken)
        }
    }

    fileprivate func makePreparationRequest(
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64?
    ) throws -> AVPlayerItemPreparationRequest {
        guard activateHistoryIfAvailable() else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        return try server.makeAVPlayerPreparationRequest(
            item: item, publicationSequence: publicationSequence, source: self)
    }

    fileprivate func makePreparationRequest(
        item: AVPlayerItemInstanceIdentity,
        pendingPublication: HLSPendingPublicationAuthority
    ) throws -> AVPlayerItemPreparationRequest {
        guard activateHistoryIfAvailable() else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        return try server.makeAVPlayerPreparationRequest(
            item: item, pendingPublication: pendingPublication, source: self)
    }

    var audioRequirementCount: Int { server.preparationAudioRequirementCount }
    func belongs(to originalServer: LoopbackHTTPServer) -> Bool { server === originalServer }
    func audioRequirement(at index: Int) -> AVPlayerAudioParticipantRequirement {
        server.preparationAudioRequirement(at: index)
    }

    func installCompletedPublicationEventHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        lock.withLock { publicationEventHandler = handler }
    }

    func installRenditionSelectionEventHandler(
        _ handler: @escaping @Sendable (LoopbackAudioMediaSelectionCapability) -> Void
    ) {
        lock.withLock { renditionSelectionEventHandler = handler }
    }

    func currentAudioSelectionCapability(itemURL: URL,
                                         item: AVPlayerItemInstanceIdentity,
                                         publicationSequence: UInt64)
        -> LoopbackAudioMediaSelectionCapability? {
        guard itemURL.scheme == "http", itemURL.host == server.localHost,
              itemURL.port == Int(server.port) else { return nil }
        guard let capability = server.currentAudioSelectionCapability(
            itemGeneration: item.itemGeneration,
            publicationSequence: publicationSequence),
              capability.outputLifecycleEpoch == item.outputLifecycleEpoch else {
            return nil
        }
        return capability
    }

    func classifyAccessLogURI(_ uri: URL,
                              itemURL: URL,
                              item: AVPlayerItemInstanceIdentity,
                              publicationSequence: UInt64,
                              selected: AudioRenditionIdentity?)
        -> AccessLogURIClassification {
        guard itemURL.scheme == "http", itemURL.host == server.localHost,
              itemURL.port == Int(server.port) else { return .invalidLocalResource }
        return server.classifyAccessLogURI(uri,
            itemGeneration: item.itemGeneration,
            publicationSequence: publicationSequence,
            selected: selected)
    }

    func consumeLatestCompletedPublication(itemURL: URL,
                                           item: AVPlayerItemInstanceIdentity)
        -> AVPlayerCompletedPublicationReadiness? {
        if let evidence = lock.withLock({ consumedEvidence }),
           evidence.itemURL == itemURL, evidence.itemGeneration == item.itemGeneration {
            return .init(evidence: evidence)
        }
        guard let sequence = lock.withLock({ latestCompletedSequence }) else { return nil }
        return consumeCompletedPublication(itemURL: itemURL, item: item,
                                           publicationSequence: sequence)
    }

    func retainedCompletedPublicationEvidence() -> LoopbackCompletedPublicationEvidence? {
        lock.withLock { consumedEvidence }
    }

    func consumeCompletedPublication(itemURL: URL,
                                     item: AVPlayerItemInstanceIdentity,
                                     publicationSequence: UInt64)
        -> AVPlayerCompletedPublicationReadiness? {
        guard let evidence = frozenCompletedPublication(itemURL: itemURL, item: item,
            publicationSequence: publicationSequence) else { return nil }
        return .init(evidence: evidence)
    }

    private func frozenCompletedPublication(itemURL: URL,
                                            item: AVPlayerItemInstanceIdentity,
                                            publicationSequence: UInt64)
        -> LoopbackCompletedPublicationEvidence? {
        guard activateHistoryIfAvailable() else { return nil }
        return lock.withLock {
            if let evidence = consumedEvidence {
                guard evidence.itemURL == itemURL,
                      evidence.itemGeneration == item.itemGeneration,
                      evidence.publicationSequence == publicationSequence else { return nil }
                return evidence
            }
            guard let evidence = server.frozenCompletedPublication(
                itemURL: itemURL, itemGeneration: item.itemGeneration,
                publicationSequence: publicationSequence, preparationOwner: preparationOwner) else {
                return nil
            }
            consumedEvidence = evidence
            return evidence
        }
    }

    func preparationPublicationBasis(itemURL: URL, item: AVPlayerItemInstanceIdentity,
                                     publicationSequence: UInt64) -> LoopbackPreparationPublicationBasis? {
        guard activateHistoryIfAvailable() else { return nil }
        return server.preparationPublicationBasis(itemURL: itemURL,
            itemGeneration: item.itemGeneration, publicationSequence: publicationSequence,
            preparationOwner: preparationOwner)
    }

    func verifiedCoverage(context: LoopbackCoverageContext,
                          requested: FMP4PresentationRange) throws -> AVPlayerVerifiedCoverage? {
        // 此入口位于原 seek/loaded 验真后；内部准备依据在此前未发出 completed 视图。
        guard let evidence = server.freezePreparationCompletedEvidence(owner: preparationOwner),
              let verified = try server.verifiedAVPlayerCoverage(
                using: evidence, context: context, requested: requested) else {
            return nil
        }
        let receipt = verified.physicalReceipt
        return AVPlayerVerifiedCoverage(
            preparedPlayheadIdentity: receipt.preparedPlayheadIdentity,
            observedRenditionSetReceiptIdentity: receipt.observedRenditionSetReceiptIdentity,
            renditionIdentity: receipt.renditionIdentity,
            itemGeneration: receipt.itemGeneration,
            presentationRange: verified.effectivePresentationRange,
            dependencies: .init(served: receipt.dependencies))
    }

    func awaitCoverageReadiness(
        contexts: [LoopbackCoverageContext],
        requested: FMP4PresentationRange
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            var ready = true
            for context in contexts where try !server.preparationCoverageCanFreeze(
                owner: preparationOwner,
                context: context,
                requested: requested
            ) {
                ready = false
                break
            }
            if ready { return }
            guard ContinuousClock.now < deadline else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func consumePlayerItemTimelineMapping(
        endpointAuthority: AACEffectiveEndpointAuthority?,
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        selection: LoopbackAudioMediaSelectionCapability?
    ) async throws -> PlayerItemTimelineMappingAuthority? {
        guard publicationSequence > 0,
              let route = server.preparationRoute(itemURL: itemURL, item: item) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if lock.withLock({ timelineTerminalFailed }) {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let adoptedSelection: LoopbackAudioMediaSelectionCapability? = lock.withLock {
            () -> LoopbackAudioMediaSelectionCapability? in
            if let selection { return selection }
            guard latestRenditionSelection?.itemGeneration == item.itemGeneration,
                  latestRenditionSelection?.publicationSequence == publicationSequence else {
                return nil
            }
            return latestRenditionSelection
        }
        switch attemptTimelineMapping(endpointAuthority: endpointAuthority,
                                      itemURL: itemURL, item: item,
                                      publicationSequence: publicationSequence,
                                      selection: adoptedSelection) {
        case .completed(let mapping):
            return mapping
        case .failed(let error):
            throw error.boundaryError
        case .waiting:
            break
        }

        let gate = lock.withLock { () -> AVPlayerPrepareWaitSlot in
            if let prepareWait { return prepareWait }
            let slot = AVPlayerPrepareWaitSlot()
            prepareWait = slot
            return slot
        }
        let token = try gate.begin(.mapping)
        let identity = token.generation
        defer {
            // driver/coordinator取消共享槽不会取消Swift Task；所有退出都按原身份
            // 退休pending，随后才能归还槽，迟到retry不得写入后继阶段。
            cancelPendingTimelineMapping(identity: identity, gate: gate)
            lock.withLock {
                if prepareWait === gate, case .completed(_, let generation) = mappingStorage,
                   generation == identity { completedMapping = nil }
            }
            gate.retire(token)
        }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, any Error>) in
                gate.install(continuation, token: token)
                let installation = lock.withLock { () -> (Bool, Bool) in
                    guard pendingTimelineMapping == nil, !Task.isCancelled,
                          !timelineTerminalFailed else {
                        return (false, timelineTerminalFailed)
                    }
                    pendingTimelineMapping = .init(identity: identity,
                        endpointAuthority: endpointAuthority,
                        publicationSequence: publicationSequence,
                        selection: adoptedSelection,
                        route: route)
                    return (true, false)
                }
                guard installation.0 else {
                    let error: AVPlayerFixedPreparationFailure
                    if installation.1 {
                        error = .coordinator(.insufficientCoverage)
                    } else if Task.isCancelled {
                        error = .cancelled
                    } else {
                        error = .coordinator(.operationInFlight)
                    }
                    gate.resolveFixed(.failure(error), token: token)
                    return
                }
                // selection 可能恰好落在首次查询与 waiter 安装之间。只从同一
                // server 的冻结 authority 读取精确 capability，并在同一锁域填入
                // 固定槽；绝不把 nil 重新解释为 server 侧通配符。
                if let current = currentAudioSelectionCapability(
                    itemURL: itemURL,
                    item: item,
                    publicationSequence: publicationSequence
                ) {
                    lock.withLock {
                        guard prepareWait === gate, pendingTimelineMapping?.identity == identity,
                              pendingTimelineMapping?.selection == nil else { return }
                        latestRenditionSelection = current
                        pendingTimelineMapping?.selection = current
                    }
                }
                // 关闭“首次查询失败”和 waiter 安装之间的 terminal 边沿窗口。
                retryPendingTimelineMapping()
            }
        } onCancel: { [weak self] in
            self?.cancelPendingTimelineMapping(identity: identity, gate: gate)
            gate.resolve(.failure(CancellationError()), token: token)
        }
        return lock.withLock { completedMapping }
    }

    private func attemptTimelineMapping(
        endpointAuthority: AACEffectiveEndpointAuthority?,
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        selection: LoopbackAudioMediaSelectionCapability?
    ) -> TimelineMappingAttempt {
        // evidence source 尚未采用精确 selection 时只能等待；直接把 nil 送进
        // server 会在 selection 已存在时正确返回 invalid，并提前清掉可恢复 waiter。
        guard selection != nil else { return .waiting }
        guard let evidence = preparationPublicationBasis(itemURL: itemURL, item: item,
            publicationSequence: publicationSequence) else {
            return .waiting
        }
        do {
            switch try server.makePlayerItemTimelineMappingAuthority(
                endpointAuthority: endpointAuthority,
                completedPublication: evidence,
                itemURL: itemURL,
                item: item,
                publicationSequence: publicationSequence,
                expectedSelection: selection) {
            case .waitingForSelection:
                return .waiting
            case .invalid:
                return .failed(.coordinator(.insufficientCoverage))
            case .ready(let mapping):
                return .completed(mapping)
            }
        } catch AVPlayerAACEndpointValidationFailure.incompleteHTTPBody {
            return .waiting
        } catch {
            return .failed(.init(error))
        }
    }

    private func retryPendingTimelineMapping(resumingQueued: Bool = false) {
        // helper 返回前释放原 pending/attempt 强引用，再把唯一授权排队，避免
        // 下一次计算开始时旧调用栈仍持有另一组 selection/mapping 尾。
        let rerun = performTimelineMappingRetry(resumingQueued: resumingQueued)
        if preparationOwner.isRetired, lock.withLock({ !timelineRetry.isInFlight }) {
            server.retirePreparationHistory(ownerSlot: preparationOwner.slot)
        }
        if rerun {
            // 队列是外部根，强持原source直到原01授权被消费并退出；否则
            // source析构会在物理尾尚在时归还owner。长期server hooks仍weak。
            server.enqueuePreparationRetry { [self] in
                retryPendingTimelineMapping(resumingQueued: true)
            }
        }
    }

    private func performTimelineMappingRetry(resumingQueued: Bool) -> Bool {
        let delivery = lock.withLock { () -> (PendingTimelineMapping, AVPlayerPrepareWaitSlot)? in
            if resumingQueued {
                guard timelineRetry.beginQueued(hasPending: pendingTimelineMapping != nil) else { return nil }
            } else {
                guard pendingTimelineMapping != nil, timelineRetry.begin() else { return nil }
            }
            guard let pendingTimelineMapping, let prepareWait else { return nil }
            return (pendingTimelineMapping, prepareWait)
        }
        guard let (pending, gate) = delivery else { return false }
        let (itemURL, item) = server.preparationRouteValues(pending.route)
        let attempt = attemptTimelineMapping(endpointAuthority: pending.endpointAuthority,
            itemURL: itemURL, item: item,
            publicationSequence: pending.publicationSequence,
            selection: pending.selection)
        var completion: Result<Bool, AVPlayerFixedPreparationFailure>?
        let rerun = lock.withLock { () -> Bool in
            guard prepareWait === gate, pendingTimelineMapping?.identity == pending.identity else {
                return timelineRetry.finish(hasPending: pendingTimelineMapping != nil,
                    matchesAttempt: false, waiting: false)
            }
            switch attempt {
            case .waiting:
                return timelineRetry.finish(hasPending: true, matchesAttempt: true, waiting: true)
            case .completed(let mapping):
                completedMapping = mapping
                pendingTimelineMapping = nil
                _ = timelineRetry.finish(hasPending: false, matchesAttempt: true, waiting: false)
                completion = .success(true)
                return false
            case .failed(let error):
                pendingTimelineMapping = nil
                _ = timelineRetry.finish(hasPending: false, matchesAttempt: true, waiting: false)
                completion = .failure(error)
                return false
            }
        }
        if let completion { gate.resolveFixed(completion, token: pending.waitToken) }
        return rerun
    }

    private func cancelPendingTimelineMapping(identity: UInt64, gate originalGate: AVPlayerPrepareWaitSlot) {
        let delivery = lock.withLock { () -> (PendingTimelineMapping, AVPlayerPrepareWaitSlot)? in
            guard prepareWait === originalGate, pendingTimelineMapping?.identity == identity else { return nil }
            let pending = pendingTimelineMapping!
            let gate = prepareWait!
            pendingTimelineMapping = nil
            timelineRetry.cancelPending()
            return (pending, gate)
        }
        if let (pending, gate) = delivery { gate.resolve(.failure(CancellationError()), token: pending.waitToken) }
    }

    private func receiveTimelineFailure(_ event: LoopbackTimelineFailureEvent) {
        let delivery = lock.withLock { () -> (PendingTimelineMapping, AVPlayerPrepareWaitSlot)? in
            guard !timelineTerminalFailed else { return nil }
            timelineTerminalFailed = true
            guard let pending = pendingTimelineMapping, let gate = prepareWait else { return nil }
            pendingTimelineMapping = nil
            timelineRetry.cancelPending()
            return (pending, gate)
        }
        if let (pending, gate) = delivery {
            gate.resolve(.failure(AVPlayerItemCoordinatorFailure.insufficientCoverage),
                token: pending.waitToken)
        }
    }
}
