// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct HLSSelectedServiceRequired: Error, Sendable, CustomStringConvertible {
    let variantCount: Int
    let audioChoiceCount: Int
    let subtitleChoiceCount: Int
    var description: String {
        "This master requires a selected service for conversion (\(variantCount) video choices, \(audioChoiceCount) audio choices, \(subtitleChoiceCount) subtitle choices). Source subtitles are preserved on native/proxy routes."
    }
}

struct HLSNativeSourceDependencies: Sendable {
    let context: PlaybackSourceContext
    var makeResolver: @Sendable () -> any PlaybackSourceResolving = { URLSessionPlaybackSourceResolver() }
    var probe: any HLSCompatibilityProbing = HLSCompatibilityProbe()
    var makeInspector: @MainActor @Sendable (any AVPlayerDriving) throws -> any NativeHLSAssetInspecting = { driver in
        guard let system = driver as? SystemAVPlayerDriver else { throw HLSSourceError.incompleteEvidence }
        return SystemNativeHLSAssetInspector(driver: system)
    }
    var capabilities: @Sendable (HLSCompatibilityFacts, PlaybackRouteSemanticIdentity?) async -> HLSOutputCapabilities = {
        await NativeHLSCapabilities.current(facts: $0, route: $1)
    }
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws -> HLSOwnedSourcePlan {
        try validate(invocation)
        let owner = try PlaybackSourceOwner(ticket: invocation.ticket, lifecycle: invocation.outputLifecycleEpoch)
        let requiresManagedTransport = !context.headers.isEmpty || context.explicitExpiry != nil
        let expired = context.explicitExpiry.map { $0 <= Date() } == true
        let bound = try context.consumingExpiry(at: Date()).bound(to: owner)
        let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
        let resolver = makeResolver()
        do {
            let source = try await resolve(bound, resolver: resolver, reason: expired ? .expired : .initial)
            try validate(invocation)
            guard await resolver.isCurrent(source) else { throw HLSSourceError.staleResolution }
            try validate(invocation)
            let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            let facts = try await inspect(source, retainingFacts: factsCharge)
            try validate(invocation)
            let capabilities = await capabilities(facts, invocation.currentPreparationRoute())
            try validate(invocation)
            var plan: HLSPlaybackPlan
            do { plan = try HLSPlaybackPlanner.makePlan(source: source, facts: facts, capabilities: capabilities) }
            catch HLSSourceError.unsupportedMedia {
                if case let .hls(graph) = source.topology, let root = graph.document(for: graph.rootURL), root.kind == .master {
                    throw HLSSelectedServiceRequired(variantCount: root.variants.count,
                        audioChoiceCount: root.renditions.filter { $0.attributes["TYPE"] == "AUDIO" }.count,
                        subtitleChoiceCount: root.renditions.filter { $0.attributes["TYPE"] == "SUBTITLES" }.count)
                }
                throw HLSSourceError.unsupportedMedia
            }
            if requiresManagedTransport, plan.transport == .native {
                plan = .init(owner: plan.owner, resolutionGeneration: plan.resolutionGeneration, transport: .proxy,
                    video: plan.video, audio: plan.audio, selectedServiceURL: plan.selectedServiceURL,
                    formatFingerprint: plan.formatFingerprint, compressedAudioConfiguration: plan.compressedAudioConfiguration,
                    compressedAudioAdmissionCandidate: plan.compressedAudioAdmissionCandidate)
            }
            try validate(invocation)
            guard source.withCurrentResolution(owner: owner, generation: source.generation, operation: { true }) == true else { throw HLSSourceError.staleResolution }
            return .init(source: source, facts: facts, plan: plan, resolver: resolver, sourceCharge: sourceCharge, factsCharge: factsCharge)
        } catch { await resolver.invalidate(); throw error }
    }
    private func validate(_ invocation: ControlTaskRegistry.BackendPrepareInvocation) throws {
        try Task.checkCancellation()
        guard invocation.revalidateCurrentPreparation() else { throw CancellationError() }
    }
    private func resolve(_ context: PlaybackSourceContext, resolver: any PlaybackSourceResolving, reason: SourceResolutionReason) async throws -> ResolvedPlaybackSource {
        let temporary = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.resolverTemporary)
        defer { withExtendedLifetime(temporary) {} }
        return try await resolver.resolve(context, reason: reason)
    }
    private func inspect(_ source: ResolvedPlaybackSource, retainingFacts charge: HLSApplicationLifetimeCharge) async throws -> HLSCompatibilityFacts {
        let temporary = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.probeTemporary)
        defer { withExtendedLifetime(temporary) {} }
        if let paid = probe as? any HLSPaidCompatibilityProbing { return try await paid.inspect(source, retainingFacts: charge) }
        return try await probe.inspect(source)
    }
}

/// Internal adapter only. HLSAVPlayerPlaybackBackend remains the sole object
/// installed in the Registry and retains the original replacement/recovery slot.
final class NativeHLSPlaybackBackend: @unchecked Sendable {
    let owned: HLSOwnedSourcePlan
    let coordinator: NativeHLSItemCoordinator
    let itemGeneration: UInt64
    let metadata: NativeHLSMetadataStore
    private let proxy: HLSProxySession?
    init(owned: HLSOwnedSourcePlan, coordinator: NativeHLSItemCoordinator, proxy: HLSProxySession?, lifecycle: OutputLifecycleEpoch) {
        self.owned = owned; self.coordinator = coordinator; self.proxy = proxy
        itemGeneration = lifecycle.outputNonce; metadata = coordinator.metadata
    }
    func prepare() async throws {
        let url: URL
        switch owned.plan.transport {
        case .native: url = owned.source.context.entryURL
        case .proxy: guard let proxy else { throw HLSSourceError.invalidURL }; url = proxy.itemURL
        case .generated: throw HLSSourceError.unsupportedMedia
        }
        try await coordinator.prepare(url: url)
    }
    func retire() async -> Bool {
        await owned.resolver.invalidate()
        guard await coordinator.retire() else { return false }
        return await proxy?.retire() ?? true
    }
}
