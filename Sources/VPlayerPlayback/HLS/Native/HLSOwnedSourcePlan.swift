// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One immutable original source/facts/plan owner shared by the adapter, proxy and
/// generated graph. Retiring a generated attempt never invalidates its AAC successor.
final class HLSOwnedSourcePlan: HLSGeneratedSourceContext, @unchecked Sendable {
    let source: ResolvedPlaybackSource
    let facts: HLSCompatibilityFacts
    let plan: HLSPlaybackPlan
    let resolver: any PlaybackSourceResolving
    let sourceCharge: HLSApplicationLifetimeCharge
    private let factsCharge: HLSApplicationLifetimeCharge
    private let lock = NSLock()
    private var attemptRetired = false
    private var generationRecovery: (@Sendable () -> Bool)?
    private var compatibleAudioRecovery: (@Sendable () -> Bool)?

    init(source: ResolvedPlaybackSource, facts: HLSCompatibilityFacts, plan: HLSPlaybackPlan,
         resolver: any PlaybackSourceResolving, sourceCharge: HLSApplicationLifetimeCharge,
         factsCharge: HLSApplicationLifetimeCharge) {
        self.source = source; self.facts = facts; self.plan = plan; self.resolver = resolver
        self.sourceCharge = sourceCharge; self.factsCharge = factsCharge
    }
    var sourceIsCurrent: Bool {
        source.withCurrentResolution(owner: plan.owner, generation: source.generation) { true } == true
    }
    var isCurrent: Bool { !lock.withLock { attemptRetired } && sourceIsCurrent }
    func retireGeneratedAttempt() { lock.withLock { attemptRetired = true } }
    func installGenerationRecovery(_ callback: @escaping @Sendable () -> Bool) {
        lock.withLock { precondition(generationRecovery == nil); generationRecovery = callback }
    }
    func installCompatibleAudioRecovery(_ callback: @escaping @Sendable () -> Bool) {
        lock.withLock { precondition(compatibleAudioRecovery == nil); compatibleAudioRecovery = callback }
    }
    func requestNewGeneration() -> Bool {
        guard isCurrent else { return false }
        return lock.withLock { generationRecovery }?() ?? false
    }
    func requestCompatibleAudioGeneration() -> Bool {
        guard isCurrent else { return false }
        return lock.withLock { compatibleAudioRecovery }?() ?? false
    }
    func usingCompatibleAudio() -> HLSOwnedSourcePlan {
        let compatible = HLSPlaybackPlan(owner: plan.owner, resolutionGeneration: plan.resolutionGeneration,
            transport: plan.transport, video: plan.video, audio: .compatibleAAC,
            selectedServiceURL: plan.selectedServiceURL, formatFingerprint: plan.formatFingerprint)
        return .init(source: source, facts: facts, plan: compatible, resolver: resolver,
            sourceCharge: sourceCharge, factsCharge: factsCharge)
    }
    func selectedMediaFacts() throws -> HLSMediaFacts {
        guard isCurrent, facts.complete, facts.owner == plan.owner,
              facts.resolutionGeneration == source.generation, plan.resolutionGeneration == source.generation,
              facts.formatFingerprint == plan.formatFingerprint, let selected = plan.selectedServiceURL else {
            throw HLSSourceError.incompleteEvidence
        }
        let canonical: URL
        switch source.topology {
        case let .hls(graph):
            guard let document = graph.document(for: selected), document.kind == .media else { throw HLSSourceError.incompleteEvidence }
            canonical = document.responseURL
        case .media:
            guard selected == source.responseURL || selected == source.context.entryURL else { throw HLSSourceError.incompleteEvidence }
            canonical = source.responseURL
        }
        let matching = facts.media.filter { $0.url == canonical }
        guard matching.count == 1 else { throw HLSSourceError.incompleteEvidence }
        return matching[0]
    }
    fileprivate var audioForCompatibilityRejection: HLSSourceAudioFacts? {
        guard plan.transport == .generated, case let .passthrough(codec) = plan.audio,
              let media = try? selectedMediaFacts(), media.audio.count == 1, let audio = media.audio.first,
              audio.codec == codec, audio.formatValidated else { return nil }
        if codec == .aac { return audio }
        guard codec == .ac3 || codec == .eac3,
              plan.compressedAudioAdmissionCandidate?.matches(audio) == true || plan.compressedAudioConfiguration?.matches(audio) == true else { return nil }
        return audio
    }
    func audioRejectionRecord() -> HLSGeneratedAudioRejection? {
        guard let audio = audioForCompatibilityRejection else { return nil }
        return .init(backend: plan.owner.backendIdentity, audio: audio, retention: factsCharge)
    }
    func makeProxyManifestAuthority() throws -> HLSOwnedProxyManifestAuthority { try .init(owned: self) }

    /// Original graph roles grant relationship authority. Initialization equivalence
    /// comes only from a paid plaintext receipt verified by the transport owner.
    func validateManifest(_ document: HLSManifestGraph.Document, original: HLSManifestGraph.Document,
                          initializationRenewals: Set<HLSProxyInitializationRenewal> = []) throws {
        guard sourceIsCurrent, document.unsupportedFeatures.isEmpty, document.kind == original.kind else { throw HLSSourceError.staleResolution }
        if document.kind == .master {
            guard try HLSManifestRewriter.masterTransportSkeleton(document) == HLSManifestRewriter.masterTransportSkeleton(original) else {
                throw HLSSourceError.unsupportedMedia
            }
            return
        }
        guard let first = document.segments.first, let originalFirst = original.segments.first,
              first.mediaSequence >= originalFirst.mediaSequence,
              try HLSManifestRewriter.protectionContracts(document).isSubset(of: HLSManifestRewriter.protectionContracts(original)) else {
            throw HLSSourceError.incompleteEvidence
        }
        func sameProtection(_ old: HLSManifestGraph.Encryption, _ new: HLSManifestGraph.Encryption) -> Bool {
            switch (old, new) { case (.none, .none), (.aes128, .aes128): return true; default: return false }
        }
        func sameInitialization(_ old: HLSManifestGraph.Segment, _ new: HLSManifestGraph.Segment) -> Bool {
            if old.initialization == new.initialization && old.initializationEncryption == new.initializationEncryption { return true }
            guard let previous = old.initialization, let replacement = new.initialization else { return false }
            return initializationRenewals.contains { $0.original == previous && $0.originalEncryption == old.initializationEncryption &&
                $0.replacement == replacement && $0.replacementEncryption == new.initializationEncryption }
        }
        let maximumDiscontinuity = original.segments.map(\.discontinuity).max() ?? 0
        for segment in document.segments {
            guard segment.discontinuity >= originalFirst.discontinuity, segment.discontinuity <= maximumDiscontinuity,
                  original.segments.contains(where: { sameInitialization($0, segment) }),
                  original.segments.contains(where: { sameProtection($0.encryption, segment.encryption) }) else { throw HLSSourceError.unsupportedMedia }
            if let previous = original.segments.first(where: { $0.mediaSequence == segment.mediaSequence }) {
                guard previous.range == segment.range, sameInitialization(previous, segment),
                      previous.discontinuity == segment.discontinuity, sameProtection(previous.encryption, segment.encryption) else {
                    throw HLSSourceError.unsupportedMedia
                }
            }
        }
    }
}

/// One request/backend-scoped rejection. Exact audio format/layout/trim facts are
/// compared; changing URL signatures or per-prepare route identifiers cannot retry
/// the same rejected format. The final alias retains the original facts reservation.
final class HLSGeneratedAudioRejection: @unchecked Sendable {
    let backend: PlaybackBackendIdentity
    let audio: HLSSourceAudioFacts
    private let retention: HLSApplicationLifetimeCharge
    fileprivate init(backend: PlaybackBackendIdentity, audio: HLSSourceAudioFacts, retention: HLSApplicationLifetimeCharge) {
        self.backend = backend; self.audio = audio; self.retention = retention
    }
    func matches(_ source: HLSOwnedSourcePlan) -> Bool {
        backend == source.plan.owner.backendIdentity && audio == source.audioForCompatibilityRejection
    }
}
