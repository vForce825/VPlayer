// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum PCMConsumerOwnerIdentity: Sendable, Hashable {
    case audioVideo(
        outputLifecycleEpoch: OutputLifecycleEpoch,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        publicationParticipantID: AudioPublicationParticipantIdentity,
        renditionIdentity: AudioRenditionIdentity
    )
    case audioOnly(
        outputLifecycleEpoch: OutputLifecycleEpoch,
        selectionTransactionIdentity: AudioSelectionTransactionIdentity,
        candidateTicket: AudioCandidateTicket,
        itemGeneration: AudioItemGenerationIdentity,
        mediaEpoch: AudioMediaEpochIdentity,
        publicationParticipantID: AudioPublicationParticipantIdentity,
        renditionIdentity: AudioRenditionIdentity
    )
}

struct PCMConsumerAdmissionIdentity: Sendable, Hashable {
    let owner: PCMConsumerOwnerIdentity
    let subscriptionGeneration: UInt64
    let admissionFenceRevision: UInt64
}

/// checked allocator签发的单个decoder输出身份；retire后对象本身永久失权。
final class DecodedPCMUnitIdentity: @unchecked Sendable, Hashable {
    let rawValue: UInt64
    let proofIdentity: AdmittedAudioServiceInputUnitProofIdentity
    var isRetired = false

    fileprivate init(rawValue: UInt64, proofIdentity: AdmittedAudioServiceInputUnitProofIdentity) {
        self.rawValue = rawValue
        self.proofIdentity = proofIdentity
    }

    static func == (lhs: DecodedPCMUnitIdentity, rhs: DecodedPCMUnitIdentity) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
struct PCMBackingIdentity: Sendable, Hashable { let rawValue: UInt64 }
struct PCMConsumerSubscriptionLeaseNonce: Sendable, Hashable { let rawValue: UInt64 }
struct PCMInputOwnerIdentity: Sendable, Hashable { let rawValue: UInt64 }

struct PCMConsumerSubscriptionLeaseIdentity: Sendable, Hashable {
    let decodedPCMUnitIdentity: DecodedPCMUnitIdentity
    let pcmConsumerAdmissionIdentity: PCMConsumerAdmissionIdentity
    let leaseNonce: PCMConsumerSubscriptionLeaseNonce
}

enum PCMConsumerDisposition: Sendable, Hashable {
    case unclaimed
    case leased(PCMConsumerSubscriptionLeaseIdentity)
    case transferred(PCMConsumerSubscriptionLeaseIdentity, PCMInputOwnerIdentity)
    case released
    case suppressed
}

struct PCMConsumerDispositionSlot: Sendable, Hashable {
    let consumerAdmissionIdentity: PCMConsumerAdmissionIdentity
    var state: PCMConsumerDisposition
    var leaseSequence: UInt64?
}

/// 三个字段是bundle内的物理内联槽，不以可增长数组代替容量合同。
struct PCMConsumerDispositionSlots: Sendable, Hashable {
    private var first: PCMConsumerDispositionSlot?
    private var second: PCMConsumerDispositionSlot?
    private var third: PCMConsumerDispositionSlot?

    static let capacity = 3
    var capacity: Int { Self.capacity }
    var storageSlotCount: Int { 3 }

    init(consumers: [(PCMConsumerAdmissionIdentity, PCMConsumerDisposition)]) {
        precondition(consumers.count <= Self.capacity)
        first = consumers.indices.contains(0)
            ? PCMConsumerDispositionSlot(
                consumerAdmissionIdentity: consumers[0].0,
                state: consumers[0].1,
                leaseSequence: nil
            )
            : nil
        second = consumers.indices.contains(1)
            ? PCMConsumerDispositionSlot(
                consumerAdmissionIdentity: consumers[1].0,
                state: consumers[1].1,
                leaseSequence: nil
            )
            : nil
        third = consumers.indices.contains(2)
            ? PCMConsumerDispositionSlot(
                consumerAdmissionIdentity: consumers[2].0,
                state: consumers[2].1,
                leaseSequence: nil
            )
            : nil
    }

    var consumerCount: Int {
        (first == nil ? 0 : 1) + (second == nil ? 0 : 1) + (third == nil ? 0 : 1)
    }

    var allTerminal: Bool {
        var terminal = true
        forEach { slot in
            if slot.state != .released && slot.state != .suppressed { terminal = false }
        }
        return terminal
    }

    func disposition(for identity: PCMConsumerAdmissionIdentity) -> PCMConsumerDisposition? {
        slot(for: identity)?.state
    }

    mutating func setDisposition(
        _ state: PCMConsumerDisposition,
        leaseSequence: UInt64? = nil,
        for identity: PCMConsumerAdmissionIdentity
    ) -> Bool {
        if first?.consumerAdmissionIdentity == identity {
            first?.state = state
            if let leaseSequence { first?.leaseSequence = leaseSequence }
            return true
        }
        if second?.consumerAdmissionIdentity == identity {
            second?.state = state
            if let leaseSequence { second?.leaseSequence = leaseSequence }
            return true
        }
        if third?.consumerAdmissionIdentity == identity {
            third?.state = state
            if let leaseSequence { third?.leaseSequence = leaseSequence }
            return true
        }
        return false
    }

    func forEach(_ body: (PCMConsumerDispositionSlot) -> Void) {
        if let first { body(first) }
        if let second { body(second) }
        if let third { body(third) }
    }

    private func slot(for identity: PCMConsumerAdmissionIdentity) -> PCMConsumerDispositionSlot? {
        if first?.consumerAdmissionIdentity == identity { return first }
        if second?.consumerAdmissionIdentity == identity { return second }
        if third?.consumerAdmissionIdentity == identity { return third }
        return nil
    }
}

final class DecodedPCMUnitBundle: @unchecked Sendable {
    let proofIdentity: AdmittedAudioServiceInputUnitProofIdentity
    let sharedDecoderAdmissionIdentity: SharedDecoderAdmissionIdentity
    let decoderLeaseIdentity: AudioServiceBranchLeaseIdentity
    let decoderInputOwner: DecoderInputOwnerIdentity
    let identity: DecodedPCMUnitIdentity
    let backingIdentity: PCMBackingIdentity
    var consumerDispositionSlots: PCMConsumerDispositionSlots

    var consumerCount: Int { consumerDispositionSlots.consumerCount }

    init(
        proofIdentity: AdmittedAudioServiceInputUnitProofIdentity,
        sharedDecoderAdmissionIdentity: SharedDecoderAdmissionIdentity,
        decoderLeaseIdentity: AudioServiceBranchLeaseIdentity,
        decoderInputOwner: DecoderInputOwnerIdentity,
        identity: DecodedPCMUnitIdentity,
        backingIdentity: PCMBackingIdentity,
        consumerDispositionSlots: PCMConsumerDispositionSlots
    ) {
        self.proofIdentity = proofIdentity
        self.sharedDecoderAdmissionIdentity = sharedDecoderAdmissionIdentity
        self.decoderLeaseIdentity = decoderLeaseIdentity
        self.decoderInputOwner = decoderInputOwner
        self.identity = identity
        self.backingIdentity = backingIdentity
        self.consumerDispositionSlots = consumerDispositionSlots
    }
}

enum PCMConsumerSubscriptionLeaseState: Sendable, Hashable {
    case available
    case transferred(PCMInputOwnerIdentity)
    case released
}

struct PCMConsumerSubscriptionLease: Sendable, Hashable {
    let identity: PCMConsumerSubscriptionLeaseIdentity
    let state: PCMConsumerSubscriptionLeaseState
}

struct PCMConsumerDrainFence: Sendable, Hashable {
    let consumerAdmissionIdentity: PCMConsumerAdmissionIdentity
    let lastIssuedLeaseSequence: UInt64
    let expectedOutstandingCount: Int
}

enum PCMConsumerSubscriptionFailure: Error, Sendable, Equatable {
    case duplicateConsumer
    case consumerCapacityExceeded
    case staleProof
    case decoderLineageMismatch
    case registryCapacityExceeded
}

final class PCMConsumerGateRecord: @unchecked Sendable {
    let identity: PCMConsumerAdmissionIdentity
    var isOpen = true
    var lastIssuedSequence: UInt64 = 0
    var outstandingCount = 0
    var closeFence: PCMConsumerDrainFence?

    init(identity: PCMConsumerAdmissionIdentity) {
        self.identity = identity
    }
}

final class PCMConsumerLeaseState: @unchecked Sendable {
    var gates = AudioServiceFixedReferenceSlots<PCMConsumerGateRecord>()
    var bundles = AudioServiceFixedReferenceSlots<DecodedPCMUnitBundle>()
    var visiblePCMUnitCount = 0
}

extension AudioServiceSemanticCoordinator {
    var visiblePCMUnitCount: Int {
        withAudioServiceCAS { audioServiceLeaseState.pcm.visiblePCMUnitCount }
    }

    func openPCMSubscription(_ identity: PCMConsumerAdmissionIdentity) -> Bool {
        withAudioServiceCAS {
            guard hasCurrentAudioServiceGenerationAuthority() else { return false }
            if let existing = pcmGate(identity) { return existing.isOpen }
            guard audioServiceLeaseState.pcm.gates.hasSpace else { return false }
            return audioServiceLeaseState.pcm.gates.insert(PCMConsumerGateRecord(identity: identity))
        }
    }

    func closePCMSubscription(_ identity: PCMConsumerAdmissionIdentity) -> PCMConsumerDrainFence? {
        withAudioServiceCAS {
            guard let gate = pcmGate(identity) else { return nil }
            if let fence = gate.closeFence { return fence }
            let fence = PCMConsumerDrainFence(
                consumerAdmissionIdentity: identity,
                lastIssuedLeaseSequence: gate.lastIssuedSequence,
                expectedOutstandingCount: gate.outstandingCount
            )
            gate.isOpen = false
            gate.closeFence = fence
            audioServiceLeaseState.pcm.bundles.forEach { bundle in
                switch bundle.consumerDispositionSlots.disposition(for: identity) {
                case .unclaimed?:
                    _ = bundle.consumerDispositionSlots.setDisposition(.suppressed, for: identity)
                case .leased?:
                    _ = bundle.consumerDispositionSlots.setDisposition(.released, for: identity)
                    precondition(gate.outstandingCount > 0)
                    gate.outstandingCount -= 1
                case .transferred?, .released?, .suppressed?, nil:
                    break
                }
            }
            return fence
        }
    }

    func makeDecodedPCMUnitBundle(
        proof: AdmittedAudioServiceInputUnitProof,
        sharedDecoderAdmissionIdentity: SharedDecoderAdmissionIdentity,
        decoderLeaseIdentity: AudioServiceBranchLeaseIdentity,
        decoderInputOwner: DecoderInputOwnerIdentity,
        backingIdentity: PCMBackingIdentity,
        consumers: [PCMConsumerAdmissionIdentity]
    ) throws -> DecodedPCMUnitBundle {
        try withAudioServiceCAS {
            guard isCurrentAdmittedProof(proof), audioServiceLeaseState.isRegistered(proof) else {
                throw PCMConsumerSubscriptionFailure.staleProof
            }
            guard decoderLineageMatches(
                proof: proof,
                admission: sharedDecoderAdmissionIdentity,
                leaseIdentity: decoderLeaseIdentity,
                owner: decoderInputOwner
            ) else {
                throw PCMConsumerSubscriptionFailure.decoderLineageMismatch
            }
            guard consumers.count <= PCMConsumerDispositionSlots.capacity else {
                throw PCMConsumerSubscriptionFailure.consumerCapacityExceeded
            }
            guard Set(consumers).count == consumers.count else {
                throw PCMConsumerSubscriptionFailure.duplicateConsumer
            }
            guard audioServiceLeaseState.pcm.bundles.hasSpace,
                  proof.branchState.decodedPCMUnits.hasSpace else {
                throw PCMConsumerSubscriptionFailure.registryCapacityExceeded
            }

            let frozen = consumers.map { identity -> (PCMConsumerAdmissionIdentity, PCMConsumerDisposition) in
                (identity, pcmGate(identity)?.isOpen == true ? .unclaimed : .suppressed)
            }
            let bundle = DecodedPCMUnitBundle(
                proofIdentity: proof.identity,
                sharedDecoderAdmissionIdentity: sharedDecoderAdmissionIdentity,
                decoderLeaseIdentity: decoderLeaseIdentity,
                decoderInputOwner: decoderInputOwner,
                identity: DecodedPCMUnitIdentity(
                    rawValue: try nextIdentity(in: .nonce),
                    proofIdentity: proof.identity
                ),
                backingIdentity: backingIdentity,
                consumerDispositionSlots: PCMConsumerDispositionSlots(consumers: frozen)
            )
            precondition(audioServiceLeaseState.pcm.bundles.insert(bundle))
            precondition(proof.branchState.decodedPCMUnits.insert(bundle.identity))
            audioServiceLeaseState.pcm.visiblePCMUnitCount += 1
            return bundle
        }
    }

    func issuePCMConsumerLease(
        from bundle: DecodedPCMUnitBundle,
        consumerAdmissionIdentity: PCMConsumerAdmissionIdentity
    ) throws -> PCMConsumerSubscriptionLease? {
        try withAudioServiceCAS {
            guard pcmBundle(bundle.identity) === bundle,
                  !bundle.identity.isRetired,
                  let proof = audioServiceLeaseState.admittedProof(identity: bundle.proofIdentity),
                  isCurrentAdmittedProof(proof),
                  let gate = pcmGate(consumerAdmissionIdentity), gate.isOpen,
                  bundle.consumerDispositionSlots.disposition(for: consumerAdmissionIdentity) == .unclaimed
            else { return nil }

            let nonce = PCMConsumerSubscriptionLeaseNonce(rawValue: try nextIdentity(in: .lease))
            let sequence = try nextIdentity(in: .sequence)
            let identity = PCMConsumerSubscriptionLeaseIdentity(
                decodedPCMUnitIdentity: bundle.identity,
                pcmConsumerAdmissionIdentity: consumerAdmissionIdentity,
                leaseNonce: nonce
            )
            guard bundle.consumerDispositionSlots.setDisposition(
                .leased(identity),
                leaseSequence: sequence,
                for: consumerAdmissionIdentity
            ) else { return nil }
            gate.lastIssuedSequence = sequence
            gate.outstandingCount += 1
            return PCMConsumerSubscriptionLease(identity: identity, state: .available)
        }
    }

    func transferPCMConsumerLease(
        _ identity: PCMConsumerSubscriptionLeaseIdentity,
        to owner: PCMInputOwnerIdentity
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard let bundle = pcmBundle(identity.decodedPCMUnitIdentity) else { return .identityMismatch }
            switch bundle.consumerDispositionSlots.disposition(for: identity.pcmConsumerAdmissionIdentity) {
            case .leased(identity)? where audioServiceLeaseState.admittedProof(identity: bundle.proofIdentity)
                .map(isCurrentAdmittedProof) == true:
                _ = bundle.consumerDispositionSlots.setDisposition(
                    .transferred(identity, owner),
                    for: identity.pcmConsumerAdmissionIdentity
                )
                return .transferred
            case .transferred?, .released?:
                return .alreadyDisposed
            case .unclaimed?, .suppressed?, .leased?, nil:
                return .identityMismatch
            }
        }
    }

    func releasePCMConsumerLease(
        _ identity: PCMConsumerSubscriptionLeaseIdentity,
        expectedOwner: PCMInputOwnerIdentity? = nil
    ) -> AudioServiceLeaseMutationResult {
        withAudioServiceCAS {
            guard let bundle = pcmBundle(identity.decodedPCMUnitIdentity) else { return .identityMismatch }
            switch bundle.consumerDispositionSlots.disposition(for: identity.pcmConsumerAdmissionIdentity) {
            case .leased(identity)?:
                guard expectedOwner == nil else { return .identityMismatch }
            case let .transferred(actualIdentity, owner)?:
                guard actualIdentity == identity, expectedOwner == owner else { return .identityMismatch }
            case .released?:
                return .alreadyDisposed
            case .unclaimed?, .suppressed?, .leased?, nil:
                return .identityMismatch
            }
            guard let gate = pcmGate(identity.pcmConsumerAdmissionIdentity) else { return .identityMismatch }
            _ = bundle.consumerDispositionSlots.setDisposition(.released, for: identity.pcmConsumerAdmissionIdentity)
            precondition(gate.outstandingCount > 0)
            gate.outstandingCount -= 1
            return .released
        }
    }

    func pcmDisposition(
        in bundle: DecodedPCMUnitBundle,
        consumer identity: PCMConsumerAdmissionIdentity
    ) -> PCMConsumerDisposition? {
        withAudioServiceCAS {
            guard pcmBundle(bundle.identity) === bundle else { return nil }
            return bundle.consumerDispositionSlots.disposition(for: identity)
        }
    }

    func isDrained(_ fence: PCMConsumerDrainFence) -> Bool {
        withAudioServiceCAS {
            guard let gate = pcmGate(fence.consumerAdmissionIdentity), gate.closeFence == fence else {
                return false
            }
            return gate.outstandingCount == 0
        }
    }

    func retirePCMSubscription(_ fence: PCMConsumerDrainFence) -> Bool {
        withAudioServiceCAS {
            guard let gate = pcmGate(fence.consumerAdmissionIdentity),
                  gate.closeFence == fence, !gate.isOpen, gate.outstandingCount == 0 else {
                return false
            }
            return audioServiceLeaseState.pcm.gates.remove { $0 === gate } != nil
        }
    }

    func retireDecodedPCMUnitBundle(_ bundle: DecodedPCMUnitBundle) -> Bool {
        withAudioServiceCAS {
            guard pcmBundle(bundle.identity) === bundle,
                  bundle.consumerDispositionSlots.allTerminal else { return false }
            bundle.identity.isRetired = true
            if let proof = audioServiceLeaseState.admittedProof(identity: bundle.proofIdentity) {
                _ = proof.branchState.decodedPCMUnits.remove { $0 === bundle.identity }
            }
            guard audioServiceLeaseState.pcm.bundles.remove(where: { $0 === bundle }) != nil else {
                return false
            }
            precondition(audioServiceLeaseState.pcm.visiblePCMUnitCount > 0)
            audioServiceLeaseState.pcm.visiblePCMUnitCount -= 1
            return true
        }
    }

    private func pcmGate(_ identity: PCMConsumerAdmissionIdentity) -> PCMConsumerGateRecord? {
        audioServiceLeaseState.pcm.gates.first { $0.identity == identity }
    }

    private func pcmBundle(_ identity: DecodedPCMUnitIdentity) -> DecodedPCMUnitBundle? {
        audioServiceLeaseState.pcm.bundles.first { $0.identity === identity }
    }
}
