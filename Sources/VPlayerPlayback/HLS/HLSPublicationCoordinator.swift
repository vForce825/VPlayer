// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct HLSInitialParticipant: @unchecked Sendable {
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let relay: SegmentReportRelay
    let candidateTicket: AudioCandidateTicket?
    let candidate: HLSAudioCandidateRegistration?
    /// Publisher 与 Loopback server 共同持有 writer 私有的固定终态槽。
    /// endpoint authority 只能在 writer terminal 后从这个槽取得，不能由调用方
    /// 把一份已拆离 publication 的 receipt/authority 填进来。
    let aacTerminalBinding: AACWriterTerminalBinding?
    let aacRenditionBinding: AACRenditionTerminalBinding?
    let aacWriterWindowAdmission: AACWriterWindowAdmission?
    let writerWindowAdmission: WriterWindowAdmission?
    init(initialization: SealedMediaObject, proof: EpochFormatProof, relay: SegmentReportRelay,
         candidateTicket: AudioCandidateTicket?, candidate: HLSAudioCandidateRegistration? = nil,
         aacTerminalBinding: AACWriterTerminalBinding? = nil,
         aacRenditionBinding: AACRenditionTerminalBinding? = nil,
         aacWriterWindowAdmission: AACWriterWindowAdmission? = nil,
         writerWindowAdmission: WriterWindowAdmission? = nil) {
        self.initialization = initialization; self.proof = proof; self.relay = relay
        self.candidateTicket = candidateTicket; self.candidate = candidate
        self.aacTerminalBinding = aacTerminalBinding
        self.aacRenditionBinding = aacRenditionBinding
        self.aacWriterWindowAdmission = aacWriterWindowAdmission
        self.writerWindowAdmission = writerWindowAdmission
    }

    var aacEndpointAuthority: AACEffectiveEndpointAuthority? {
        aacTerminalBinding?.endpointAuthority
    }
}
struct HLSParticipantVectorEntry: Sendable, Hashable {
    let participantID: UInt64
    let candidateTicket: AudioCandidateTicket?
    let binding: FMP4WriterBinding
    let proofIdentity: UUID
    let declaration: HLSItemDeclaration
    var expectedPreviousSnapshotVersion: UInt64
    var expectedLogicalSequence: UInt64
}
struct PlaylistPublishTicket: Sendable, Hashable {
    let identity: UInt64
    let backendGeneration: UInt64
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let participantGeneration: UInt64
    let publicationSequence: UInt64
    let previousPublishInstant: Int64?
    let absoluteDeadline: Int64?
    var participantVector: [HLSParticipantVectorEntry]
}
struct ParticipantReconfigurationTicket: Sendable, Hashable {
    let identity: UInt64
    let oldGeneration: UInt64
    let newGeneration: UInt64?
    let retiredParticipantIDs: [UInt64]
    let survivorParticipantIDs: [UInt64]
    let publicationSequence: UInt64
}
enum HLSPublicationResult: Sendable { case waiting, published, accepted, releasedOnly }
struct HLSPublishedSnapshot: Sendable {
    /// publisher 实例身份随每次可见快照冻结，Loopback 只能接受同一 publisher
    /// 为下一次 publication 签发的准备预约。
    let publisherIdentity: UUID
    let publicationSequence: UInt64
    let participantVector: [HLSParticipantVectorEntry]
    let master: HLSPlaylistRepresentation?
    let media: [UInt64: HLSPlaylistSnapshot]
    let coverage: PublicationCoverage
    /// 与 participant vector 同一次 publication CAS 冻结；server 只能消费这些
    /// writer terminal 槽，不能把别的 server/publisher 的 endpoint 接进来。
    let aacTerminalBindings: [UInt64: AACWriterTerminalBinding]
    /// 首个真实 writer media report 已冻结的物理/有效时间域映射。selection 与
    /// publication-ready 只读这个快照，不得提前读取 terminal endpoint 槽。
    let aacTimelineMappings: [UInt64: AACWriterTimelineMappingReceipt]
    let aacRenditionBindings: [UInt64: AACRenditionTerminalBinding]

    init(publisherIdentity: UUID,
         publicationSequence: UInt64,
         participantVector: [HLSParticipantVectorEntry],
         master: HLSPlaylistRepresentation?,
         media: [UInt64: HLSPlaylistSnapshot],
         coverage: PublicationCoverage,
         aacTerminalBindings: [UInt64: AACWriterTerminalBinding],
         aacTimelineMappings: [UInt64: AACWriterTimelineMappingReceipt],
         aacRenditionBindings: [UInt64: AACRenditionTerminalBinding] = [:]) {
        self.publisherIdentity = publisherIdentity
        self.publicationSequence = publicationSequence
        self.participantVector = participantVector
        self.master = master
        self.media = media
        self.coverage = coverage
        self.aacTerminalBindings = aacTerminalBindings
        self.aacTimelineMappings = aacTimelineMappings
        self.aacRenditionBindings = aacRenditionBindings
    }
}

/// Live writer 尚未 terminal 时，由 publisher 为“紧邻下一次 CAS”签发的一次性预约。
/// 它只允许同一 Loopback server 先安装 AVPlayer 准备请求；最终 readiness 仍必须
/// 来自该序号真实 playlist/resource send-terminal，预约本身不是完成证据。
final class HLSPendingPublicationAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let publisherIdentity: UUID
    private let itemGeneration: UInt64
    private let publicationSequence: UInt64
    private let terminalBindings: [UInt64: AACWriterTerminalBinding]
    private var consumed = false

    fileprivate init(publisherIdentity: UUID, itemGeneration: UInt64,
                     publicationSequence: UInt64,
                     terminalBindings: [UInt64: AACWriterTerminalBinding]) {
        self.publisherIdentity = publisherIdentity
        self.itemGeneration = itemGeneration
        self.publicationSequence = publicationSequence
        self.terminalBindings = terminalBindings
    }

    func consume(serverPublisherIdentity: UUID, itemGeneration: UInt64,
                 terminalBindings: [UInt64: AACWriterTerminalBinding]) -> UInt64? {
        lock.withLock {
            guard !consumed, publisherIdentity == serverPublisherIdentity,
                  self.itemGeneration == itemGeneration,
                  self.terminalBindings.count == terminalBindings.count,
                  self.terminalBindings.allSatisfy({ participantID, binding in
                      terminalBindings[participantID] === binding
                  }) else { return nil }
            consumed = true
            return publicationSequence
        }
    }
}

/// 同一锁域中的单飞 publisher；不存在独立 participant commit 或 caller 自报已验证入口。
final class HLSPublicationCoordinator: @unchecked Sendable {
    /// init batch 只接受已由 publisher 完整预检的单次换代资格；失败不激活 candidate。
    final class InitializationAuthority {
        private let publisher: HLSPublicationCoordinator
        private let inputs: [HLSInitialParticipant]
        private let previous: PlaylistPublishTicket?
        private let next: PlaylistPublishTicket
        private var consumed = false
        fileprivate init(publisher: HLSPublicationCoordinator, inputs: [HLSInitialParticipant], next: PlaylistPublishTicket) {
            self.publisher = publisher; self.inputs = inputs; self.next = next
            previous = publisher._ticket
        }
        func consume(store: SealedMediaStore, operation: ([HLSInitialParticipant], HLSPublicationOwner,
            PlaylistPublishTicket?, PlaylistPublishTicket, [UInt64: HLSItemDeclaration]) throws -> [HLSResourceKey]) throws -> [HLSResourceKey] {
            guard !consumed, publisher.store === store, !publisher._closed,
                  publisher._ticket == previous else { throw HLSPublicationFailure.staleTicket }
            if let previous { try publisher.revalidate(previous, now: nil) }
            try publisher.validateParticipants(inputs, initial: previous == nil)
            let declarations = Dictionary(uniqueKeysWithValues: inputs.map {
                ($0.proof.binding.publicationParticipantID.rawValue, $0.candidate?.declaration ?? publisher.declaration)
            })
            let keys = try operation(inputs, publisher.owner, previous, next, declarations)
            consumed = true
            return keys
        }
    }
    /// 序列化前的封闭资格与最终 commit 资格分离，caller 无法凭 store owner 自签 URI。
    final class PreparationAuthority {
        private let publisher: HLSPublicationCoordinator
        private let ticket: PlaylistPublishTicket
        fileprivate init(publisher: HLSPublicationCoordinator, ticket: PlaylistPublishTicket) {
            self.publisher = publisher; self.ticket = ticket
        }
        func validate(store: SealedMediaStore) throws {
            guard publisher.store === store else { throw HLSPublicationFailure.identityMismatch }
            try publisher.revalidate(ticket, now: nil)
        }
    }
    final class CommitAuthority {
        private let publisher: HLSPublicationCoordinator
        private let ticket: PlaylistPublishTicket
        private let reservation: HLSSnapshotBatchReservation
        private let media: [UInt64: HLSPlaylistSnapshot]
        private let master: HLSPlaylistRepresentation?
        private let records: [UInt64: [HLSValidatedSegment]]
        private let now: Int64
        private var consumed = false
        fileprivate init(publisher: HLSPublicationCoordinator, ticket: PlaylistPublishTicket,
                         reservation: HLSSnapshotBatchReservation, media: [UInt64: HLSPlaylistSnapshot],
                         master: HLSPlaylistRepresentation?, records: [UInt64: [HLSValidatedSegment]], now: Int64) {
            self.publisher = publisher
            self.ticket = ticket
            self.reservation = reservation
            self.media = media
            self.master = master
            self.records = records
            self.now = now
        }
        func consume(store: SealedMediaStore, operation: (HLSPublicationOwner, PlaylistPublishTicket, HLSSnapshotBatchReservation,
            [UInt64: HLSPlaylistSnapshot], HLSPlaylistRepresentation?, [UInt64: [HLSValidatedSegment]], Int64) throws -> Void) throws {
            guard publisher.store === store, !consumed else { throw HLSPublicationFailure.identityMismatch }
            try publisher.revalidate(ticket, now: now)
            try operation(publisher.owner, ticket, reservation, media, master, records, now)
            consumed = true
        }
    }

    private let store: SealedMediaStore
    private let publisherIdentity = UUID()
    private let owner: HLSPublicationOwner
    private let declaration: HLSItemDeclaration
    private let anchor: HLSProgramDateAnchor
    private let publicationDeadlineNanoseconds: Int64
    private let initialWindowMinimumSeconds: Int
    private var participants: [UInt64: HLSInitialParticipant] = [:]
    private var initializationKeys: [UInt64: HLSResourceKey] = [:]
    private var records: [UInt64: [HLSValidatedSegment]] = [:]
    private struct WriterSlot {
        let source: SegmentedFMP4CallbackContext
        let relay: SegmentReportRelay
        let candidateTicket: AudioCandidateTicket?
        var retiring = false
        var drained = false
    }
    private var retiredParticipantIDs: Set<UInt64> = []
    // 代际拓扑固定为 current + 一个未 drain predecessor；整体退休后最多两个 retiring。
    private var writerSlots: [UInt64: [WriterSlot]] = [:]
    private var retirements: [UInt64: ParticipantReconfigurationTicket] = [:]
    private var _ticket: PlaylistPublishTicket!
    private var _visible: HLSPublishedSnapshot?
    private var _closed = false
    private var ended = false
    private var eofLastSequence: UInt64?
    private var sequence: UInt64 = 0
    private var nextLogicalSequence: UInt64 = 0
    private var previousInstant: Int64?
    private var participantGeneration: UInt64
    private var discontinuityAt: UInt64?
    private var discontinuitySequences: [UInt64: UInt64] = [:]
    private var aacPublicationMembership: [UInt64: AACMediaMembershipAccumulator] = [:]
    private let aacPublicationIssuer = UUID()
    private var terminalAACPublicationLeaves: [UInt64: AACMediaMembershipLeaf] = [:]
    private var _serializationCount = 0
    private var _masterCreationCount = 0

    init(store: SealedMediaStore, participants: [HLSInitialParticipant], declaration: HLSItemDeclaration,
         anchor: HLSProgramDateAnchor,
         publicationDeadlineNanoseconds: Int64 = 3_000_000_000,
         initialWindowMinimumSeconds: Int = 6) throws {
        guard publicationDeadlineNanoseconds > 0,
              [3, 6].contains(initialWindowMinimumSeconds) else {
            throw HLSPublicationFailure.invalidDuration
        }
        self.store = store
        self.declaration = declaration
        self.anchor = anchor
        self.publicationDeadlineNanoseconds = publicationDeadlineNanoseconds
        self.initialWindowMinimumSeconds = initialWindowMinimumSeconds
        participantGeneration = try PlaybackIdentityAllocator.shared.next(in: .admissionFence)
        owner = try store.claimPublicationOwner()
        do { try store.domain.sync {
            try HLSPlaylistSerializer.validate(declaration)
            try validateParticipants(participants, initial: true)
            try install(participants, generation: participantGeneration)
        } } catch { store.abandonPublicationOwner(owner); throw error }
    }
    var visible: HLSPublishedSnapshot? { store.domain.sync { _visible } }
    var ticket: PlaylistPublishTicket { store.domain.sync { _ticket } }
    var isClosed: Bool { store.domain.sync { _closed } }
    var invalidPublicationCount: Int { 0 }
    var serializationCount: Int { store.domain.sync { _serializationCount } }
    var masterCreationCount: Int { store.domain.sync { _masterCreationCount } }
    var retainedReadinessCount: Int { store.domain.sync { records.values.reduce(0) { $0 + $1.count } } }
    var aacPublicationMembershipSnapshots: [UInt64: AACMediaMembershipSnapshot] {
        store.domain.sync { aacPublicationMembership.mapValues(\.snapshot) }
    }
    var pendingLogicalSequenceCount: Int { store.domain.sync { pendingCount } }
    var shouldBackpressure: Bool { store.domain.sync {
        sequence > 0 && pendingCount >= 4 || store.usage.shouldBackpressure
            || writerSlots.values.contains { $0.contains { $0.retiring } }
    } }
    private var pendingCount: Int { Set(records.values.flatMap { $0.filter { $0.receipt.logicalSequence >= nextLogicalSequence }.map { $0.receipt.logicalSequence } }).count }

    /// 只预约紧邻下一次 publication。若中间发生别的 CAS，真实 completed-response
    /// 无法匹配该序号，准备会自然失败闭合，不能把预约重绑定到后来版本。
    func reserveNextPublicationForPreparation() throws -> HLSPendingPublicationAuthority {
        try store.domain.sync {
            guard !_closed, !ended, _visible != nil else {
                throw HLSPublicationFailure.closed
            }
            let next = sequence.addingReportingOverflow(1)
            guard !next.overflow else { throw HLSPublicationFailure.invalidSequence }
            let bindings = Dictionary(uniqueKeysWithValues:
                participants.compactMap { participantID, participant in
                    participant.aacTerminalBinding.map { (participantID, $0) }
                })
            guard !bindings.isEmpty, bindings.count <= 4 else {
                throw HLSPublicationFailure.identityMismatch
            }
            return HLSPendingPublicationAuthority(
                publisherIdentity: publisherIdentity,
                itemGeneration: declaration.itemGeneration,
                publicationSequence: next.partialValue,
                terminalBindings: bindings)
        }
    }

    @discardableResult
    func offer(_ object: SealedMediaObject, receipt: SegmentValidationReceipt, relay: SegmentReportRelay,
               ticket: PlaylistPublishTicket, now: Int64,
               naturalEndTail: Bool = false) throws -> HLSPublicationResult {
        try store.domain.sync {
            let id = object.binding.publicationParticipantID.rawValue
            if let slot = writerSlots[id]?.first(where: { $0.retiring && $0.source.binding == object.binding }) {
                guard let evidence = object.publicationEvidence, evidence.matches(object),
                      evidence.writerSource === slot.source, relay === slot.relay,
                      let entry = ticket.participantVector.first(where: { $0.participantID == id }),
                      entry.binding == object.binding,
                      entry.candidateTicket == slot.candidateTicket else { throw HLSPublicationFailure.identityMismatch }
                guard relay.releaseForControl(object) else { throw HLSPublicationFailure.identityMismatch }
                return .releasedOnly
            }
            try revalidate(ticket, now: nil)
            guard eofLastSequence == nil else { throw HLSPublicationFailure.closed }
            guard let participant = participants[id], participant.proof.binding == object.binding,
                  receipt.matches(media: object, proof: participant.proof) else { throw HLSPublicationFailure.identityMismatch }
            if let admission = participant.aacWriterWindowAdmission {
                guard let mapping = participant.aacTerminalBinding?.timelineMappingReceipt,
                      admission.accepts(mapping,
                          renditionBinding: participant.aacRenditionBinding) else {
                    throw HLSPublicationFailure.identityMismatch
                }
            }
            guard let evidence = object.publicationEvidence, evidence.matches(object),
                  let initializationEvidence = participant.initialization.publicationEvidence,
                  evidence.writerSource === initializationEvidence.writerSource, relay === participant.relay,
                  evidence.session === initializationEvidence.session, evidence.format == initializationEvidence.format,
                  let boundary = evidence.boundary, boundary.binding == object.binding,
                  boundary.logicalSequence == object.logicalSequence else { throw HLSPublicationFailure.identityMismatch }
            try validateFormat(evidence, participantID: id, declaration: declarationFor(id), requireFrameRate: true)
            let boundaryStart: ExactMediaTime
            if let mapping = participant.aacTerminalBinding?.timelineMappingReceipt,
               mapping.reportIdentity == object.report.identity,
               mapping.writtenPhysicalBase == receipt.presentationRange.start {
                // 只有首个真实 report 的起点包含 encoder leading；其物理尾与后续
                // buffer 已在有效时间域收敛，不能把首帧差值平移整条流。
                boundaryStart = mapping.writtenEffectiveBase
            } else {
                boundaryStart = receipt.presentationRange.start
            }
            let isVideoWithEvidence = participant.proof.mediaType == .video && object.publicationEvidence != nil
            try validateBoundary(boundaryStart, common: boundary.commonStart,
                unit: boundary.accessUnitDuration, first: boundary.commonStart == boundary.epochStart,
                isVideoWithEvidence: isVideoWithEvidence)
            let existing = records[id] ?? []
            let expected = try existing.last.map { try HLSChecked.increment($0.receipt.logicalSequence) } ?? nextLogicalSequence
            guard object.logicalSequence == expected else { throw HLSPublicationFailure.invalidSequence }
            if let last = existing.last,
               discontinuityAt != object.logicalSequence,
               !HLSSegmentContinuity.accepts(
                   previousEnd: last.receipt.presentationRange.end,
                   nextStart: receipt.presentationRange.start,
                   mediaType: participant.proof.mediaType,
                   accessUnitDuration: boundary.accessUnitDuration,
                   hasPublicationEvidence: object.publicationEvidence != nil
               ) {
                throw HLSPublicationFailure.invalidSequence
            }
            guard object.logicalSequence >= nextLogicalSequence else { throw HLSPublicationFailure.invalidSequence }
            let backlog = object.logicalSequence - nextLogicalSequence
            if sequence == 0 {
                // 冷启动 TS 包序允许视频在音频之前成批到达。绝对序号最多保留
                // 16 段，但真正需要拒绝的是任一轨相对最慢轨达到八段，而不是
                // 视频单独走到第八/九段；首发仍只冻结共同的六/七段。
                let projected = backlog.addingReportingOverflow(1)
                guard !projected.overflow else {
                    throw HLSPublicationFailure.invalidSequence
                }
                let projectedCount = projected.partialValue
                let slowestCount = participants.keys.map { participantID -> UInt64 in
                    if participantID == id { return projectedCount }
                    guard let last = records[participantID]?.last?.receipt.logicalSequence,
                          last >= nextLogicalSequence else { return 0 }
                    let count = (last - nextLogicalSequence).addingReportingOverflow(1)
                    return count.overflow ? UInt64.max : count.partialValue
                }.min() ?? 0
                guard backlog < 16,
                      projectedCount >= slowestCount,
                      projectedCount - slowestCount < 8 else {
                    PlaybackDiagnosticTracker.shared.set(
                        "pub_err_initial_backlog\(backlog)_skew\(projectedCount - slowestCount)")
                    throw HLSPublicationFailure.initialWindowInvariant
                }
            } else if backlog >= 8 {
                PlaybackDiagnosticTracker.shared.set(
                    "pub_err_backlog\(backlog)_s\(object.logicalSequence)_next\(nextLogicalSequence)")
                throw HLSPublicationFailure.capacityExceeded
            }
            let duration = receipt.presentationRange.duration
            guard duration.value > 0,
                  try HLSChecked.compare(duration, .init(value: 7, timescale: 1)) <= 0 else {
                PlaybackDiagnosticTracker.shared.set("pub_err_offer_dur_\(id)_\(duration.value)/\(duration.timescale)")
                throw HLSPublicationFailure.invalidDuration
            }
            if participant.proof.mediaType == .video {
                guard try HLSChecked.compare(duration, .init(value: 6, timescale: 1)) <= 0 else {
                    PlaybackDiagnosticTracker.shared.set("pub_err_offer_vid_dur_\(id)_\(duration.value)/\(duration.timescale)")
                    throw HLSPublicationFailure.invalidDuration
                }
            }
            let ownBandwidth = try HLSBandwidth.measure(Array(existing.suffix(6)).map {
                .init(bodyBytes: UInt64($0.bodyBytes), duration: $0.receipt.presentationRange.duration)
            } + [.init(bodyBytes: UInt64(object.bytes.count), duration: duration)])
            let envelope = peakEnvelope(for: id)
            guard ownBandwidth.peak <= envelope, ownBandwidth.average <= envelope else {
                PlaybackDiagnosticTracker.shared.set("pub_err_offer_bw_\(id)_p\(ownBandwidth.peak)_env\(envelope)")
                throw HLSPublicationFailure.invalidDuration
            }
            let commonStart = boundary.commonStart
            let reservation = try store.reserveMedia(binding: object.binding, kind: .media, bodyBytes: object.backing.bytes.count)
            let key: HLSResourceKey
            do { key = try store.admit(object, proof: participant.proof, receipt: receipt, relay: relay, reservation: reservation) }
            catch { store.cancel(reservation); throw error }
            if let leaf = object.aacMediaMembershipLeaf {
                let accumulator = aacPublicationMembership[id]
                    ?? AACMediaMembershipAccumulator()
                guard accumulator.accept(leaf) == .accepted else {
                    throw HLSPublicationFailure.identityMismatch
                }
                aacPublicationMembership[id] = accumulator
                terminalAACPublicationLeaves[id] = leaf
                let admission = AACPublicationLeafAdmission(
                    leaf: leaf, issuer: aacPublicationIssuer)
                guard participant.aacRenditionBinding?.acceptPublicationAdmission(
                    admission, issuer: aacPublicationIssuer) ?? true else {
                    throw HLSPublicationFailure.capacityExceeded
                }
                try store.attachAACPublicationAdmission(admission, to: key)
            }
            records[id, default: []].append(HLSValidatedSegment(key: key, initializationKey: initializationKeys[id]!,
                proof: participant.proof, receipt: receipt,
                objectIdentity: try FMP4ObjectIdentity(object), bodyBytes: object.bytes.count, commonStart: commonStart,
                commonDuration: participant.proof.mediaType == .video ? duration : HLSChecked.one,
                discontinuity: discontinuityAt == object.logicalSequence, boundary: boundary))
            if sequence == 0 { return try publish(ticket: ticket, now: now) }
            return .accepted
        }
    }

    @discardableResult
    func publish(ticket: PlaylistPublishTicket, now: Int64, naturalEnd: Bool = false) throws -> HLSPublicationResult {
        try store.domain.sync {
            try revalidate(ticket, now: now)
            guard !ended else { throw HLSPublicationFailure.closed }
            if naturalEnd, eofLastSequence == nil {
                let tails = Set(participants.keys.compactMap { records[$0]?.last?.receipt.logicalSequence })
                guard tails.count == 1, let tail = tails.first else { throw HLSPublicationFailure.invalidSequence }
                try validateNaturalEndAACAuthorities()
                try sealAACPublicationMemberships()
                eofLastSequence = tail
            }
            let finishing = eofLastSequence != nil
            let chosen: [UInt64: [HLSValidatedSegment]]
            let lastSequence: UInt64
            if sequence == 0 {
                if initialWindowMinimumSeconds == 6 {
                    guard participants.keys.allSatisfy({
                        (records[$0]?.count ?? 0) >= 6
                    }) else { return .waiting }
                    let six = records.mapValues { Array($0.prefix(6)) }
                    if try allAtLeastSix(six) {
                        chosen = six
                        lastSequence = 5
                    } else {
                        guard participants.keys.allSatisfy({
                            (records[$0]?.count ?? 0) >= 7
                        }) else { return .waiting }
                        let seven = records.mapValues { Array($0.prefix(7)) }
                        guard try allAtLeastSix(seven) else {
                            throw HLSPublicationFailure.initialWindowInvariant
                        }
                        chosen = seven
                        lastSequence = 6
                    }
                } else {
                    let availableCount = participants.keys.map {
                        records[$0]?.count ?? 0
                    }.min() ?? 0
                    guard availableCount >= 3 else { return .waiting }
                    var initial: [UInt64: [HLSValidatedSegment]]?
                    for count in 3...min(availableCount, 7) {
                        let candidate = records.mapValues { Array($0.prefix(count)) }
                        if try allAtLeastThree(candidate) {
                            initial = candidate
                            break
                        }
                    }
                    guard let initial else {
                        if availableCount >= 7 {
                            throw HLSPublicationFailure.initialWindowInvariant
                        }
                        return .waiting
                    }
                    chosen = initial
                    guard let initialLastSequence = initial.values.first?.last?
                        .receipt.logicalSequence else {
                        throw HLSPublicationFailure.initialWindowInvariant
                    }
                    lastSequence = initialLastSequence
                }
            } else {
                let ready = participants.keys.allSatisfy { records[$0]?.contains(where: { $0.receipt.logicalSequence == nextLogicalSequence }) == true }
                if !ready && !finishing {
                    if ticket.absoluteDeadline.map({ now >= $0 }) == true { _closed = true; throw HLSPublicationFailure.deadlineExceeded }
                    return .waiting
                }
                if finishing && !ready && pendingCount != 0 { throw HLSPublicationFailure.invalidSequence }
                // natural-end 是同一 writer terminal 的一次 publication CAS；把已验收的
                // 连续尾段整体冻结，不能让调用方预猜要经过几个中间版本才能见到 ENDLIST。
                lastSequence = finishing ? eofLastSequence!
                    : (ready ? nextLogicalSequence : nextLogicalSequence - 1)
                let available = records.mapValues { $0.filter { $0.receipt.logicalSequence <= lastSequence } }
                if initialWindowMinimumSeconds == 6 {
                    let six = available.mapValues { Array($0.suffix(6)) }
                    if try allAtLeastSix(six) {
                        chosen = six
                    } else {
                        let seven = available.mapValues { Array($0.suffix(7)) }
                        guard seven.values.allSatisfy({ $0.count == 7 }),
                              try allAtLeastSix(seven) else {
                            throw HLSPublicationFailure.initialWindowInvariant
                        }
                        chosen = seven
                    }
                } else {
                    let availableCount = available.values.map(\.count).min() ?? 0
                    guard availableCount >= 3 else { return .waiting }
                    let preferredCount = min(availableCount, 6)
                    let preferred = available.mapValues {
                        Array($0.suffix(preferredCount))
                    }
                    if try allAtLeastThree(preferred) {
                        chosen = preferred
                    } else {
                        let seven = available.mapValues { Array($0.suffix(7)) }
                        guard seven.values.allSatisfy({ $0.count == 7 }),
                              try allAtLeastThree(seven) else {
                            if finishing {
                                throw HLSPublicationFailure.initialWindowInvariant
                            }
                            return .waiting
                        }
                        chosen = seven
                    }
                }
                let span = declaration.video.flatMap { chosen[$0.participantID]?.last?.commonDuration } ?? HLSChecked.one
                let interval = max(Int64(1_000_000_000), try HLSChecked.nanoseconds(span))
                guard now >= (try HLSChecked.add(previousInstant!, interval)) else { return .waiting }
            }
            // Task17 的真实 AAC 尾段可因 trailing trim 短于共同一秒边界。
            // 在 lifecycle 尚未声明 natural end 前，它不能被发布为普通中段；保留
            // 已验收入 store 的 segment，等待同一 publisher 的 natural-end CAS 后
            // 再作为 terminal tail 进入冻结 snapshot。
            if eofLastSequence == nil,
               try hasUnfinalizedShortAudioTail(chosen) {
                return .waiting
            }
            let normalized = try validateCommonTimeline(
                chosen,
                terminalSequence: eofLastSequence
            )
            let coverage = try PublicationCoverage(records: normalized, anchor: anchor)
            try validateBandwidth(normalized)
            let newSequence = try HLSChecked.increment(sequence)
            let nextSequence = try HLSChecked.increment(lastSequence)
            let nextDeadline = try HLSChecked.add(now, publicationDeadlineNanoseconds)
            let ticketNonce = try PlaybackIdentityAllocator.shared.next(in: .nonce)
            guard let reservation = try store.reserveSnapshotBatch(mediaCount: participants.count, includeMaster: sequence == 0 && declaration.video != nil) else {
                if ticket.absoluteDeadline.map({ now >= $0 }) == true { _closed = true; throw HLSPublicationFailure.deadlineExceeded }
                try store.waitForSnapshotCapacity(owner: owner, ticket: ticket) { [weak self] instant in
                    guard let self else { return }
                    do { _ = try self.publish(ticket: ticket, now: instant) }
                    catch { self.store.cancelCapacityWait(owner: self.owner, ticket: ticket) }
                }
                return .waiting
            }
            do {
                let preparation = PreparationAuthority(publisher: self, ticket: ticket)
                let normalized = try normalized.mapValues { segments in try segments.map { segment in
                    HLSValidatedSegment(key: try store.authenticatedKey(segment.key, authority: preparation),
                        initializationKey: try store.authenticatedKey(segment.initializationKey, authority: preparation),
                        proof: segment.proof, receipt: segment.receipt,
                        objectIdentity: segment.objectIdentity, bodyBytes: segment.bodyBytes,
                        commonStart: segment.commonStart, commonDuration: segment.commonDuration,
                        discontinuity: segment.discontinuity, boundary: segment.boundary)
                } }
                let writesEndList = eofLastSequence == lastSequence
                let effectivePlaybackHorizons = try frozenEffectivePlaybackHorizons(
                    normalized, writesEndList: writesEndList)
                var media: [UInt64: HLSPlaylistSnapshot] = [:]
                var newDiscontinuities = discontinuitySequences
                for id in participants.keys.sorted() {
                    let segments = normalized[id]!
                    let first = segments.first!.receipt.logicalSequence
                    let removedDiscontinuities = (records[id] ?? []).filter { $0.discontinuity && $0.receipt.logicalSequence < first }.count
                    let discontinuitySequence = try HLSChecked.add(discontinuitySequences[id] ?? 0, UInt64(removedDiscontinuities))
                    newDiscontinuities[id] = discontinuitySequence
                    let representation = try HLSPlaylistSerializer.media(segments: segments, declaration: declarationFor(id),
                        discontinuitySequence: discontinuitySequence, anchor: anchor, endList: writesEndList)
                    _serializationCount += 1
                    media[id] = HLSPlaylistSnapshot(identity: UUID(), version: newSequence, representation: representation,
                        logicalSequences: segments.map { $0.receipt.logicalSequence }, resources: segments.map(\.key),
                        initializationResources: Array(Set(segments.map(\.initializationKey))),
                        bandwidth: try HLSBandwidth.measure(samples(segments)),
                        effectivePlaybackHorizon: effectivePlaybackHorizons[id]!)
                }
                let master = sequence == 0 ? try HLSPlaylistSerializer.master(declaration) : nil
                let authority = CommitAuthority(publisher: self, ticket: ticket, reservation: reservation,
                    media: media, master: master, records: normalized, now: now)
                try store.commit(authority)
                sequence = newSequence
                nextLogicalSequence = nextSequence
                previousInstant = now
                ended = writesEndList
                discontinuitySequences = newDiscontinuities
                for id in participants.keys {
                    let minimum = normalized[id]!.first!.receipt.logicalSequence
                    records[id] = records[id]!.filter { $0.receipt.logicalSequence >= minimum }
                }
                if master != nil { _masterCreationCount += 1 }
                let frozenMaster = master ?? _visible?.master
                _ticket = makeTicket(identity: ticketNonce, deadline: nextDeadline)
                try bindStoreTicket()
                let aacTerminalBindings = Dictionary(uniqueKeysWithValues:
                    participants.compactMap { participantID, participant in
                        participant.aacTerminalBinding.map { (participantID, $0) }
                    })
                let aacTimelineMappings = Dictionary(uniqueKeysWithValues:
                    participants.compactMap { participantID, participant in
                        participant.aacTerminalBinding?.timelineMappingReceipt.map {
                            (participantID, $0)
                        }
                    })
                let aacRenditionBindings = Dictionary(uniqueKeysWithValues:
                    participants.compactMap { participantID, participant in
                        participant.aacRenditionBinding.map { (participantID, $0) }
                    })
                guard aacTimelineMappings.count == aacTerminalBindings.count,
                      aacTimelineMappings.allSatisfy({ participantID, mapping in
                          aacTerminalBindings[participantID]?.binding == mapping.binding
                }) else {
                    throw HLSPublicationFailure.identityMismatch
                }
                _visible = HLSPublishedSnapshot(
                    publisherIdentity: publisherIdentity,
                    publicationSequence: sequence,
                    participantVector: _ticket.participantVector,
                    master: frozenMaster,
                    media: media,
                    coverage: coverage,
                    aacTerminalBindings: aacTerminalBindings,
                    aacTimelineMappings: aacTimelineMappings,
                    aacRenditionBindings: aacRenditionBindings)
                return .published
            } catch {
                store.cancel(reservation)
                throw error
            }
        }
    }

    private func sealAACPublicationMemberships() throws {
        for declaration in declaration.audio where declaration.codec == .aac {
            guard let participant = participants[declaration.participantID],
                  let binding = participant.aacRenditionBinding else { continue }
            guard let accumulator = aacPublicationMembership[declaration.participantID],
                  let terminal = terminalAACPublicationLeaves[declaration.participantID],
                  accumulator.snapshot.pendingCount == 0 else {
                throw HLSPublicationFailure.identityMismatch
            }
            let receipt = AACPublicationMembershipReceipt(
                snapshot: accumulator.snapshot,
                terminalLeaf: terminal,
                issuer: aacPublicationIssuer)
            do { try binding.acceptPublication(receipt, issuer: aacPublicationIssuer) }
            catch { throw HLSPublicationFailure.identityMismatch }
        }
    }

    private func validateNaturalEndAACAuthorities() throws {
        for declaration in declaration.audio where declaration.codec == .aac {
            if let rendition = participants[declaration.participantID]?.aacRenditionBinding {
                guard let participant = participants[declaration.participantID],
                      let final = rendition.finalWriterReceipt,
                      final.binding == participant.proof.binding,
                      final.systemTerminal.binding == participant.proof.binding,
                      final.systemTerminal.terminalReason == .finished,
                      final.inputCount > 0,
                      let last = records[declaration.participantID]?.last,
                      final.terminalMedia.key == last.key,
                      final.terminalMedia.backingIdentity
                        == last.objectIdentity.backingIdentity,
                      final.terminalMedia.sealedDigest == last.objectIdentity.digest.bytes,
                      final.terminalMedia.byteCount == last.objectIdentity.byteRange.length,
                      final.terminalMedia.reportIdentity == last.objectIdentity.reportIdentity,
                      final.callbackMembership.terminalLeaf.logicalSequence
                        == last.receipt.logicalSequence,
                      final.terminalPhysicalEnd == last.receipt.presentationRange.end,
                      last.receipt.matches(mediaIdentity: last.objectIdentity,
                                           proof: participant.proof) else {
                    throw HLSPublicationFailure.identityMismatch
                }
                continue
            }
            guard let participant = participants[declaration.participantID],
                  participant.proof.mediaType == .audio,
                  let authority = participant.aacEndpointAuthority,
                  authority.receipt.binding == participant.proof.binding,
                  authority.terminal.binding == participant.proof.binding,
                  authority.terminal.terminalReason == .finished,
                  authority.terminal.identity == authority.receipt.writerReceiptIdentity,
                  authority.terminal.inputCount == authority.receipt.inputEvidenceCount,
                  authority.terminal.callbackEvidenceCount
                    == authority.receipt.callbackEvidenceCount,
                  authority.terminal.callbackEvidenceDigest
                    == authority.receipt.callbackEvidenceDigest,
                  authority.receipt.realSampleCount > 0,
                  let last = records[declaration.participantID]?.last,
                  let terminalObject = authority.media.last,
                  terminalObject.key == last.key,
                  terminalObject.backingIdentity == last.objectIdentity.backingIdentity,
                  terminalObject.sealedDigest == last.objectIdentity.digest.bytes,
                  terminalObject.byteCount == last.objectIdentity.byteRange.length,
                  terminalObject.reportIdentity == last.objectIdentity.reportIdentity,
                  terminalObject == authority.receipt.terminalMedia,
                  authority.media.first == authority.receipt.firstMedia,
                  authority.receipt.mappingReportIdentity
                    == authority.receipt.firstMedia.reportIdentity,
                  authority.terminal.lastLogicalSequence == last.receipt.logicalSequence,
                  authority.receipt.terminalLogicalSequence == last.receipt.logicalSequence,
                  authority.terminal.lastCallbackReportIdentity == terminalObject.reportIdentity,
                  last.receipt.matches(mediaIdentity: last.objectIdentity,
                                       proof: participant.proof) else {
                throw HLSPublicationFailure.identityMismatch
            }
            guard try HLSChecked.compare(last.receipt.presentationRange.end,
                                         authority.receipt.terminalPhysicalEnd) == 0 else {
                throw HLSPublicationFailure.identityMismatch
            }
            try validateAACEndpointTimeline(authority.receipt)
        }
    }

    private func validateAACEndpointTimeline(
        _ receipt: AACEffectiveEndpointReceipt
    ) throws {
        guard receipt.sampleRate > 0, receipt.leadingFrames >= 0,
              receipt.realSampleCount > 0, receipt.trailingFrames >= 0 else {
            throw HLSPublicationFailure.identityMismatch
        }
        let leadingAndReal = try HLSChecked.add(receipt.leadingFrames,
                                               receipt.realSampleCount)
        let physicalFrames = try HLSChecked.add(leadingAndReal,
                                                receipt.trailingFrames)
        guard physicalFrames == receipt.totalDecodedFrames else {
            throw HLSPublicationFailure.identityMismatch
        }
        let leadingDuration = ExactMediaTime(value: receipt.leadingFrames,
                                             timescale: receipt.sampleRate)
        let realDuration = ExactMediaTime(value: receipt.realSampleCount,
                                          timescale: receipt.sampleRate)
        let trailingDuration = ExactMediaTime(value: receipt.trailingFrames,
                                              timescale: receipt.sampleRate)
        let physicalDuration = ExactMediaTime(value: receipt.totalDecodedFrames,
                                              timescale: receipt.sampleRate)
        let inputEffectiveBase = try receipt.inputPhysicalBase.adding(leadingDuration)
        let offset = try receipt.writtenPhysicalBase.subtracting(
            receipt.inputPhysicalBase)
        let writtenEffectiveBase = try receipt.inputEffectiveBase.adding(offset)
        let effectiveEnd = try receipt.writtenEffectiveBase.adding(realDuration)
        let physicalEnd = try receipt.writtenPhysicalBase.adding(physicalDuration)
        let physicalEndFromTrim = try receipt.lastEffectiveEnd.adding(trailingDuration)
        guard receipt.inputEffectiveBase == inputEffectiveBase,
              receipt.timelineOffset == offset,
              receipt.writtenEffectiveBase == writtenEffectiveBase,
              receipt.lastEffectiveEnd == effectiveEnd,
              receipt.terminalPhysicalEnd == physicalEnd,
              receipt.terminalPhysicalEnd == physicalEndFromTrim else {
            throw HLSPublicationFailure.identityMismatch
        }
    }

    /// 每个 playlist 都携带同一次 publication CAS 冻结的有效播放终点。
    /// A/V 以 video 的共同播放终点为准；audio-only natural end 使用 writer
    /// 私有签发的 AAC 有效终点 N，绝不能把含 trailing trim 的物理尾 Q 外泄。
    private func frozenEffectivePlaybackHorizons(
        _ normalized: [UInt64: [HLSValidatedSegment]],
        writesEndList: Bool
    ) throws -> [UInt64: ExactMediaTime] {
        let commonHorizon: ExactMediaTime?
        if let videoID = declaration.video?.participantID,
           let tail = normalized[videoID]?.last {
            commonHorizon = try tail.commonStart.adding(tail.commonDuration)
        } else {
            commonHorizon = nil
        }
        var result: [UInt64: ExactMediaTime] = [:]
        result.reserveCapacity(normalized.count)
        for (id, segments) in normalized {
            guard let tail = segments.last else {
                throw HLSPublicationFailure.invalidSequence
            }
            if let commonHorizon {
                result[id] = commonHorizon
            } else if writesEndList,
                      let final = participants[id]?.aacRenditionBinding?.finalWriterReceipt {
                result[id] = final.lastEffectiveEnd
            } else if writesEndList,
                      let authority = participants[id]?.aacTerminalBinding?.endpointAuthority {
                result[id] = authority.receipt.lastEffectiveEnd
            } else {
                result[id] = try tail.commonStart.adding(tail.commonDuration)
            }
        }
        return result
    }

    @discardableResult
    func deadline(ticket: PlaylistPublishTicket, now: Int64) throws -> HLSPublicationResult { try store.domain.sync {
        try revalidate(ticket, now: nil)
        guard let deadline = ticket.absoluteDeadline, now >= deadline else { return .waiting }
        _closed = true
        store.cancelCapacityWait(owner: owner)
        throw HLSPublicationFailure.deadlineExceeded
    } }

    func cancelCapacityWait(ticket: PlaylistPublishTicket) { store.domain.sync {
        store.cancelCapacityWait(owner: owner, ticket: ticket)
    } }

    /// 同一 media epoch 内只替换物理 writer owner。旧 playlist/media 记录继续
    /// 属于稳定 rendition；新 init/source/mapping 必须来自后继 writer 的私签 admission。
    func advanceAACWriterWindow(
        _ next: HLSInitialParticipant,
        admission: AACWriterWindowAdmission,
        ticket: PlaylistPublishTicket
    ) throws -> PlaylistPublishTicket {
        try store.domain.sync {
            try revalidate(ticket, now: nil)
            let id = next.proof.binding.publicationParticipantID.rawValue
            guard let previous = participants[id],
                  previous.proof.mediaType == .audio,
                  previous.aacRenditionBinding === next.aacRenditionBinding,
                  admission === next.aacWriterWindowAdmission,
                  admission.binding == next.proof.binding,
                  previous.proof.binding.outputLifecycleEpoch
                    == next.proof.binding.outputLifecycleEpoch,
                  previous.proof.binding.itemGeneration
                    == next.proof.binding.itemGeneration,
                  previous.proof.binding.mediaEpoch == next.proof.binding.mediaEpoch,
                  previous.proof.binding.publicationParticipantID
                    == next.proof.binding.publicationParticipantID,
                  previous.proof.binding.renditionIdentity
                    == next.proof.binding.renditionIdentity,
                  previous.proof.binding.writerIdentity
                    != next.proof.binding.writerIdentity,
                  previous.candidateTicket == next.candidateTicket,
                  writerSlots[id]?.contains(where: { $0.retiring }) != true,
                  (writerSlots[id]?.count ?? 0) < 2,
                  let oldEvidence = previous.initialization.publicationEvidence,
                  let newEvidence = next.initialization.publicationEvidence,
                  oldEvidence.session === newEvidence.session,
                  oldEvidence.format.hasSameItemSelection(as: newEvidence.format),
                  let canonicalKey = initializationKeys[id],
                  next.relay.releaseForControl(next.initialization) else {
                throw HLSPublicationFailure.identityMismatch
            }
            guard store.advanceAACWriterWindowInitialization(
                canonicalKey: canonicalKey,
                predecessorInitialization: previous.initialization,
                predecessorProof: previous.proof,
                successorInitialization: next.initialization,
                successorProof: next.proof,
                admission: admission, relay: next.relay,
                terminalBinding: next.aacTerminalBinding,
                renditionBinding: next.aacRenditionBinding) else {
                throw HLSPublicationFailure.identityMismatch
            }
            _ticket = nil
            store.cancelCapacityWait(owner: owner)
            installRetirementFence(previous.proof.binding)
            let source = newEvidence.writerSource
            writerSlots[id, default: []].append(.init(
                source: source, relay: next.relay,
                candidateTicket: next.candidateTicket))
            participants[id] = next
            participantGeneration = try PlaybackIdentityAllocator.shared.next(
                in: .admissionFence)
            _ticket = try makeTicket()
            try bindStoreTicket()
            _ = next.relay.observePublicationDrain(source: source) { [weak self] receipt in
                self?.receiveWriterDrain(receipt)
            }
            return _ticket
        }
    }

    /// Type-neutral physical writer handoff. It preserves the participant,
    /// canonical initialization key, playlist history, URI, and media epoch.
    func advanceWriterWindow(
        _ next: HLSInitialParticipant,
        admission: WriterWindowAdmission,
        ticket: PlaylistPublishTicket
    ) throws -> PlaylistPublishTicket {
        try store.domain.sync {
            try revalidate(ticket, now: nil)
            let id = next.proof.binding.publicationParticipantID.rawValue
            guard let previous = participants[id],
                  previous.proof.mediaType == next.proof.mediaType,
                  admission === next.writerWindowAdmission,
                  admission.binding == next.proof.binding,
                  previous.proof.binding.outputLifecycleEpoch
                    == next.proof.binding.outputLifecycleEpoch,
                  previous.proof.binding.itemGeneration
                    == next.proof.binding.itemGeneration,
                  previous.proof.binding.mediaEpoch == next.proof.binding.mediaEpoch,
                  previous.proof.binding.publicationParticipantID
                    == next.proof.binding.publicationParticipantID,
                  previous.proof.binding.renditionIdentity
                    == next.proof.binding.renditionIdentity,
                  previous.proof.binding.writerIdentity
                    != next.proof.binding.writerIdentity,
                  previous.candidateTicket == next.candidateTicket,
                  writerSlots[id]?.contains(where: { $0.retiring }) != true,
                  (writerSlots[id]?.count ?? 0) < 2,
                  let oldEvidence = previous.initialization.publicationEvidence,
                  let newEvidence = next.initialization.publicationEvidence,
                  oldEvidence.session === newEvidence.session,
                  oldEvidence.format == newEvidence.format,
                  let canonicalKey = initializationKeys[id],
                  next.relay.releaseForControl(next.initialization) else {
                throw HLSPublicationFailure.identityMismatch
            }
            guard store.advanceWriterWindowInitialization(
                canonicalKey: canonicalKey,
                predecessorInitialization: previous.initialization,
                predecessorProof: previous.proof,
                successorInitialization: next.initialization,
                successorProof: next.proof,
                admission: admission,
                relay: next.relay) else {
                throw HLSPublicationFailure.identityMismatch
            }
            _ticket = nil
            store.cancelCapacityWait(owner: owner)
            installRetirementFence(previous.proof.binding)
            let source = newEvidence.writerSource
            writerSlots[id, default: []].append(.init(
                source: source, relay: next.relay,
                candidateTicket: next.candidateTicket))
            participants[id] = next
            participantGeneration = try PlaybackIdentityAllocator.shared.next(
                in: .admissionFence)
            _ticket = try makeTicket()
            try bindStoreTicket()
            _ = next.relay.observePublicationDrain(source: source) { [weak self] receipt in
                self?.receiveWriterDrain(receipt)
            }
            return _ticket
        }
    }

    func reconfigure(retiring ids: Set<UInt64>, ticket: PlaylistPublishTicket) throws -> ParticipantReconfigurationTicket {
        try store.domain.sync {
            try revalidate(ticket, now: nil)
            guard !ids.isEmpty, ids.isSubset(of: Set(participants.keys)) else { throw HLSPublicationFailure.identityMismatch }
            let ids = declaration.video == nil ? ids : Set(participants.keys)
            let nonce = try PlaybackIdentityAllocator.shared.next(in: .nonce)
            let generation = try PlaybackIdentityAllocator.shared.next(in: .admissionFence)
            let oldGeneration = participantGeneration
            // 先撤销旧 ticket，再安装 release-only fence，最后递增 participant generation。
            _ticket = nil
            store.cancelCapacityWait(owner: owner)
            for id in ids {
                installRetirementFence(participants[id]!.proof.binding)
                retiredParticipantIDs.insert(id)
                participants.removeValue(forKey: id)
                records.removeValue(forKey: id)
                initializationKeys.removeValue(forKey: id)
                aacPublicationMembership.removeValue(forKey: id)
                terminalAACPublicationLeaves.removeValue(forKey: id)
            }
            store.retireParticipants(ids)
            participantGeneration = generation
            let reconfiguration = ParticipantReconfigurationTicket(identity: nonce, oldGeneration: oldGeneration,
                newGeneration: participants.isEmpty ? nil : generation, retiredParticipantIDs: ids.sorted(),
                survivorParticipantIDs: participants.keys.sorted(), publicationSequence: sequence)
            retirements[nonce] = reconfiguration
            if participants.isEmpty { _closed = true; store.close(); _ticket = ticket }
            else { _ticket = try makeTicket(); try bindStoreTicket() }
            return reconfiguration
        }
    }
    func isRetirementFenced(participantID: UInt64) -> Bool { store.domain.sync { retiredParticipantIDs.contains(participantID) } }
    func confirmRetirement(_ ticket: ParticipantReconfigurationTicket, stop: () -> Void) {
        store.domain.sync {
            guard retirements.removeValue(forKey: ticket.identity) == ticket else { return }
            stop()
        }
    }
    func beginEpoch(_ next: [HLSInitialParticipant], ticket: PlaylistPublishTicket) throws { try store.domain.sync {
        try revalidate(ticket, now: nil)
        guard sequence > 0, pendingCount == 0 else { throw HLSPublicationFailure.invalidSequence }
        try validateParticipants(next, initial: false)
        let generation = try PlaybackIdentityAllocator.shared.next(in: .admissionFence)
        try install(next, generation: generation)
        // 成员归约以 media epoch 为身份域。跨 discontinuity 的新 writer 可以从
        // 下一逻辑序号继续，但 leaf 的 mediaEpoch 已变化，不能与旧 epoch 共用
        // accumulator；同 epoch 的物理 writer rollover 则继续走 advance 路径。
        for input in next where input.proof.mediaType == .audio {
            let id = input.proof.binding.publicationParticipantID.rawValue
            aacPublicationMembership.removeValue(forKey: id)
            terminalAACPublicationLeaves.removeValue(forKey: id)
        }
        discontinuityAt = nextLogicalSequence
    } }
    func close() { store.domain.sync {
        _closed = true
        for (id, participant) in participants {
            installRetirementFence(participant.proof.binding); retiredParticipantIDs.insert(id)
        }
        records.removeAll(keepingCapacity: true)
        store.close()
    } }

    private func validateParticipants(_ inputs: [HLSInitialParticipant], initial: Bool) throws {
        guard (1...4).contains(inputs.count), let first = inputs.first else { throw HLSPublicationFailure.capacityExceeded }
        let expected = initial ? Set(declaration.audio.map(\.participantID) + (declaration.video.map { [$0.participantID] } ?? [])) : Set(participants.keys)
        let ids = inputs.map { $0.proof.binding.publicationParticipantID.rawValue }
        guard Set(ids) == expected, Set(ids).count == ids.count else { throw HLSPublicationFailure.identityMismatch }
        for input in inputs {
            let binding = input.proof.binding
            guard let evidence = input.initialization.publicationEvidence, evidence.matches(input.initialization),
                  evidence.writerSource.binding == binding, evidence.writerSource.belongs(to: input.relay),
                  input.relay.canObservePublicationDrain(source: evidence.writerSource),
                  let firstEvidence = first.initialization.publicationEvidence,
                  evidence.session === firstEvidence.session else { throw HLSPublicationFailure.identityMismatch }
            try validateFormat(evidence, participantID: binding.publicationParticipantID.rawValue,
                declaration: input.candidate?.declaration ?? declaration, requireFrameRate: false)
            guard input.proof.matches(initialization: input.initialization),
                  binding.outputLifecycleEpoch == first.proof.binding.outputLifecycleEpoch,
                  binding.mediaEpoch == first.proof.binding.mediaEpoch,
                  (input.proof.mediaType == .video) == (declaration.video?.participantID == binding.publicationParticipantID.rawValue) else {
                throw HLSPublicationFailure.identityMismatch
            }
            if let terminalBinding = input.aacTerminalBinding {
                guard input.proof.mediaType == .audio,
                      terminalBinding.binding == binding,
                      (input.candidate?.declaration ?? declaration).audio
                        .contains(where: {
                            $0.participantID == binding.publicationParticipantID.rawValue
                                && $0.codec == .aac
                        }) else {
                    throw HLSPublicationFailure.identityMismatch
                }
            }
            if let renditionBinding = input.aacRenditionBinding {
                guard input.proof.mediaType == .audio,
                      renditionBinding.outputLifecycleEpoch == binding.outputLifecycleEpoch,
                      renditionBinding.itemGeneration == binding.itemGeneration,
                      renditionBinding.mediaEpoch == binding.mediaEpoch,
                      renditionBinding.publicationParticipantID
                        == binding.publicationParticipantID,
                      renditionBinding.renditionIdentity == binding.renditionIdentity else {
                    throw HLSPublicationFailure.identityMismatch
                }
            }
            if declaration.video == nil {
                guard let candidate = input.candidate, candidate.ticket == input.candidateTicket,
                      store.acceptsCandidate(candidate, proof: input.proof) else { throw HLSPublicationFailure.identityMismatch }
            } else {
                guard input.candidate == nil, input.candidateTicket == nil,
                      binding.itemGeneration.rawValue == declaration.itemGeneration,
                      binding.itemGeneration.rawValue == store.itemGeneration else { throw HLSPublicationFailure.identityMismatch }
            }
            if !initial {
                guard let previous = participants[binding.publicationParticipantID.rawValue],
                      previous.proof.binding.mediaEpoch.rawValue < binding.mediaEpoch.rawValue,
                      previous.proof.binding.outputLifecycleEpoch == binding.outputLifecycleEpoch,
                      previous.proof.binding.itemGeneration == binding.itemGeneration,
                      previous.proof.binding.writerIdentity != binding.writerIdentity,
                      previous.proof.binding.renditionIdentity == binding.renditionIdentity,
                      previous.candidateTicket == input.candidateTicket,
                      let priorEvidence = previous.initialization.publicationEvidence,
                      priorEvidence.writerSource !== evidence.writerSource,
                      priorEvidence.format.hasSameItemSelection(as: evidence.format) else {
                    throw HLSPublicationFailure.identityMismatch
                }
                guard writerSlots[binding.publicationParticipantID.rawValue]?.contains(where: { $0.retiring }) != true else {
                    throw HLSPublicationFailure.capacityExceeded
                }
            }
        }
    }
    private func install(_ inputs: [HLSInitialParticipant], generation: UInt64) throws {
        // 所有可能失败的 identity/deadline 计算都在一次性 lease 接管前完成。
        let next = makeTicket(identity: try PlaybackIdentityAllocator.shared.next(in: .nonce),
            deadline: try previousInstant.map {
                try HLSChecked.add($0, publicationDeadlineNanoseconds)
            },
            inputs: Dictionary(uniqueKeysWithValues: inputs.map { ($0.proof.binding.publicationParticipantID.rawValue, $0) }),
            generation: generation)
        var reservations: [SealedMediaReservation] = []
        do {
            for input in inputs {
                reservations.append(try store.reserveMedia(binding: input.proof.binding, kind: .initialization,
                    bodyBytes: input.initialization.bytes.count, candidate: input.candidate))
            }
            let authority = InitializationAuthority(publisher: self, inputs: inputs, next: next)
            let keys = try store.admitInitializations(authority, reservations: reservations)
            for (input, key) in zip(inputs, keys) {
                let id = input.proof.binding.publicationParticipantID.rawValue
                if let previous = participants[id] { installRetirementFence(previous.proof.binding) }
                let source = input.initialization.publicationEvidence!.writerSource
                writerSlots[id, default: []].append(.init(source: source, relay: input.relay, candidateTicket: input.candidateTicket))
                participants[id] = input
                initializationKeys[id] = key
                if records[id] == nil { records[id] = [] }
            }
            participantGeneration = generation
            _ticket = next
            for input in inputs {
                let source = input.initialization.publicationEvidence!.writerSource
                // observer 只持有弱 publisher；准确 source/relay receipt 的一次性 CAS 不依赖 caller terminal 值。
                _ = input.relay.observePublicationDrain(source: source) { [weak self] receipt in
                    self?.receiveWriterDrain(receipt)
                }
            }
        } catch { for reservation in reservations { store.cancel(reservation) }; throw error }
    }
    private func revalidate(_ ticket: PlaylistPublishTicket, now: Int64?) throws {
        guard !_closed else { throw HLSPublicationFailure.closed }
        guard _ticket == ticket else { throw HLSPublicationFailure.staleTicket }
        try store.validatePublication(ticket, owner: owner)
        if let now, let deadline = ticket.absoluteDeadline, now > deadline {
            _closed = true
            store.cancelCapacityWait(owner: owner)
            throw HLSPublicationFailure.deadlineExceeded
        }
    }
    private func bindStoreTicket() throws {
        try store.bindPublication(_ticket, owner: owner,
            declarations: Dictionary(uniqueKeysWithValues: participants.keys.map { ($0, declarationFor($0)) }))
    }
    private func declarationFor(_ id: UInt64) -> HLSItemDeclaration { participants[id]?.candidate?.declaration ?? declaration }
    private func peakEnvelope(for id: UInt64) -> UInt64 {
        let frozen = declarationFor(id)
        return frozen.video?.participantID == id ? frozen.video!.peakEnvelope
            : frozen.audio.first(where: { $0.participantID == id })!.peakEnvelope
    }
    private func installRetirementFence(_ binding: FMP4WriterBinding) {
        let id = binding.publicationParticipantID.rawValue
        guard let index = writerSlots[id]?.firstIndex(where: { $0.source.binding == binding }) else { return }
        if writerSlots[id]![index].drained { writerSlots[id]!.remove(at: index) }
        else { writerSlots[id]![index].retiring = true }
    }
    private func receiveWriterDrain(_ receipt: WriterPublicationDrainReceipt) { store.domain.sync {
        let id = receipt.source.binding.publicationParticipantID.rawValue
        guard let index = writerSlots[id]?.firstIndex(where: { $0.source === receipt.source }),
              writerSlots[id]![index].relay.accepts(receipt, source: receipt.source),
              !writerSlots[id]![index].drained else { return }
        if writerSlots[id]![index].retiring { writerSlots[id]!.remove(at: index) }
        else { writerSlots[id]![index].drained = true }
    } }
    private func makeTicket() throws -> PlaylistPublishTicket {
        try makeTicket(identity: PlaybackIdentityAllocator.shared.next(in: .nonce),
            deadline: previousInstant.map {
                try HLSChecked.add($0, publicationDeadlineNanoseconds)
            })
    }
    private func makeTicket(identity: UInt64, deadline: Int64?, inputs: [UInt64: HLSInitialParticipant]? = nil,
                            generation: UInt64? = nil) -> PlaylistPublishTicket {
        let participants = inputs ?? self.participants
        let vector = participants.keys.sorted().map { id in
            HLSParticipantVectorEntry(participantID: id, candidateTicket: participants[id]!.candidateTicket,
                binding: participants[id]!.proof.binding, proofIdentity: participants[id]!.proof.identity,
                declaration: participants[id]!.candidate?.declaration ?? declaration,
                expectedPreviousSnapshotVersion: sequence, expectedLogicalSequence: nextLogicalSequence)
        }
        let lifecycle = vector[0].binding.outputLifecycleEpoch
        return PlaylistPublishTicket(identity: identity, backendGeneration: lifecycle.backendIdentity.backendGeneration,
            outputLifecycleEpoch: lifecycle, participantGeneration: generation ?? participantGeneration, publicationSequence: sequence,
            previousPublishInstant: previousInstant, absoluteDeadline: deadline, participantVector: vector)
    }
    private func allAtLeastThree(_ chosen: [UInt64: [HLSValidatedSegment]]) throws -> Bool {
        try chosen.values.allSatisfy { segments in
            guard segments.count >= 3 else { return false }
            let duration = try segments.reduce(HLSChecked.zero) { try $0.adding($1.receipt.presentationRange.duration) }
            return try HLSChecked.compare(duration, HLSChecked.three) >= 0
        }
    }
    private func allAtLeastSix(_ chosen: [UInt64: [HLSValidatedSegment]]) throws -> Bool {
        try chosen.values.allSatisfy { segments in
            guard segments.count >= 6 else { return false }
            let duration = try segments.reduce(HLSChecked.zero) {
                try $0.adding($1.receipt.presentationRange.duration)
            }
            return try HLSChecked.compare(duration, HLSChecked.six) >= 0
        }
    }
    private func samples(_ segments: [HLSValidatedSegment]) -> [HLSBandwidthSample] {
        segments.map { .init(bodyBytes: UInt64($0.bodyBytes), duration: $0.receipt.presentationRange.duration) }
    }
    private func validateBandwidth(_ chosen: [UInt64: [HLSValidatedSegment]]) throws {
        for (id, segments) in chosen {
            let measured = try HLSBandwidth.measure(samples(segments))
            let envelope = peakEnvelope(for: id)
            guard measured.peak <= envelope, measured.average <= envelope else {
                PlaybackDiagnosticTracker.shared.set("pub_err_val_bw_env_\(id)_p\(measured.peak)_env\(envelope)")
                throw HLSPublicationFailure.invalidDuration
            }
        }
        if let video = declaration.video, let videoSegments = chosen[video.participantID] {
            for audio in declaration.audio where chosen[audio.participantID] != nil {
                let measured = try HLSBandwidth.variant(video: samples(videoSegments), audioGroup: [samples(chosen[audio.participantID]!)])
                let declared = try HLSChecked.add(video.peakEnvelope, audio.peakEnvelope)
                guard measured.peak <= declared, measured.average <= declared else {
                    PlaybackDiagnosticTracker.shared.set("pub_err_val_bw_decl_p\(measured.peak)_decl\(declared)")
                    throw HLSPublicationFailure.invalidDuration
                }
            }
        }
    }
    private func validateCommonTimeline(
        _ chosen: [UInt64: [HLSValidatedSegment]],
        terminalSequence: UInt64?
    ) throws -> [UInt64: [HLSValidatedSegment]] {
        let video = declaration.video.flatMap { chosen[$0.participantID] }
        guard let reference = video ?? chosen.values.first else { throw HLSPublicationFailure.invalidSequence }
        for segments in chosen.values {
            guard segments.count == reference.count else { throw HLSPublicationFailure.invalidSequence }
            for (segment, common) in zip(segments, reference) {
                guard segment.boundary.session === common.boundary.session,
                      segment.receipt.logicalSequence == common.receipt.logicalSequence,
                      segment.commonStart == common.commonStart else { throw HLSPublicationFailure.identityMismatch }
                let end = try common.commonStart.adding(video == nil ? HLSChecked.one : common.receipt.presentationRange.duration)
                let terminalDurationComparison = try HLSChecked.compare(
                    segment.receipt.presentationRange.end,
                    segment.receipt.presentationRange.start
                )
                // Task18 的 fMP4 presentation range 记录 writer 的物理尾端 Q；
                // terminal AAC 的有效尾端由 Task17 authority 另行封存，并在 Task21
                // 与 completed HTTP backing 一起消费。这里只允许 publisher 已 CAS
                // 确认的唯一 natural-end logical sequence 保留其正长度物理尾段，
                // 不能把 Q 当成有效 N，也不放宽任何普通中段。
                let terminalAudioTail = segment.proof.mediaType == .audio
                    && segment.receipt.logicalSequence == terminalSequence
                    && terminalDurationComparison > 0
                if !terminalAudioTail {
                    let isVideo = segment.proof.mediaType == .video
                    try validateBoundary(segment.receipt.presentationRange.end, common: end,
                        unit: segment.boundary.accessUnitDuration, first: false,
                        isVideoWithEvidence: isVideo)
                }
            }
        }
        return chosen
    }
    private func hasUnfinalizedShortAudioTail(
        _ chosen: [UInt64: [HLSValidatedSegment]]
    ) throws -> Bool {
        for segments in chosen.values {
            guard let tail = segments.last, tail.proof.mediaType == .audio else {
                continue
            }
            let commonEnd = try tail.commonStart.adding(
                declaration.video == nil ? HLSChecked.one : tail.commonDuration
            )
            if try HLSChecked.compare(tail.receipt.presentationRange.end, commonEnd) < 0 {
                return true
            }
        }
        return false
    }
    private func validateBoundary(_ actual: ExactMediaTime, common: ExactMediaTime,
                                  unit: ExactMediaTime?, first: Bool,
                                  isVideoWithEvidence: Bool = false) throws {
        if isVideoWithEvidence {
            let delta = abs(actual.cmTime.seconds - common.cmTime.seconds)
            guard delta <= 0.10 else {
                PlaybackDiagnosticTracker.shared.set("pub_err_vb_v_delta_\(delta)")
                throw HLSPublicationFailure.invalidDuration
            }
            return
        }
        if first || unit == nil {
            guard actual == common else {
                PlaybackDiagnosticTracker.shared.set("pub_err_vb_exact_act_\(actual.value)/\(actual.timescale)_com_\(common.value)/\(common.timescale)")
                throw HLSPublicationFailure.invalidDuration
            }
            return
        }
        let delta = abs(actual.cmTime.seconds - common.cmTime.seconds)
        let tolerance = max((unit?.cmTime.seconds ?? 0.035) * 2.0, 0.10)
        guard delta <= tolerance else {
            PlaybackDiagnosticTracker.shared.set("pub_err_vb_off_d\(delta)_tol\(tolerance)")
            throw HLSPublicationFailure.invalidDuration
        }
    }
    private func validateFormat(_ evidence: SegmentedFMP4PublicationEvidence, participantID: UInt64,
                                declaration: HLSItemDeclaration, requireFrameRate: Bool) throws {
        let format = evidence.format
        if let video = declaration.video, video.participantID == participantID {
            guard video.codec == format.codec, video.width == format.width, video.height == format.height,
                  video.videoRange == format.videoRange else { throw HLSPublicationFailure.identityMismatch }
            if requireFrameRate {
                guard let duration = evidence.frameDuration, duration.value > 0,
                      try HLSChecked.multiply(UInt64(duration.timescale), 1_000) / UInt64(duration.value)
                        == video.frameRateMilli else { throw HLSPublicationFailure.identityMismatch }
            }
        } else {
            guard let audio = declaration.audio.first(where: { $0.participantID == participantID }),
                  audio.codec.codecs == format.codec, audio.channels == format.channels else { throw HLSPublicationFailure.identityMismatch }
        }
    }
}
