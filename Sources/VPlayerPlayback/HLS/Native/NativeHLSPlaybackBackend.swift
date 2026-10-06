// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Darwin
import VPlayerCore

/// One paid scalar record for joined source preflight only. It never stores an
/// error, source address, header, media byte, or growing diagnostic history.
final class HLSPreparationDiagnostics: @unchecked Sendable {
    @TaskLocal static var current: HLSPreparationDiagnostics?
    enum Stage: String, Sendable { case admission, resolve, probe, capabilities, planner, proxy, generated, nativePrepare = "native-prepare" }
    enum Reason: String, Sendable {
        case none, httpEncoding = "http-encoding", manifestFeatures = "manifest-features"
        case encryptedRange = "encrypted-range", keyLength = "key-length", aesCiphertext = "aes-ciphertext", aesDecrypt = "aes-decrypt"
        case containerInspection = "container", noTracks = "no-tracks"
    }
    fileprivate enum Source: String, Sendable { case unknown, direct, media = "hls-media", master = "hls-master" }
    fileprivate struct State: Sendable {
        var stage = Stage.admission
        var reason = Reason.none
        var source = Source.unknown
        var status: Int32 = 0, cStage: Int32 = 0, cReason: Int32 = 0, container: Int32 = 0
        var inputBytes: Int32 = 0, usableBytes: Int32 = 0
        var mediaCount: UInt16 = 0, audioCount: UInt8 = 0, videoCodec: UInt8 = 0
        var scan = HLSScanEvidence.unknown
        var parameterSets = false
        mutating func begin(_ next: Stage) {
            stage = next; reason = .none; status = 0
            cStage = 0; cReason = 0; container = 0; inputBytes = 0; usableBytes = 0
        }
    }
    struct Frozen: Sendable {
        fileprivate let state: State
        static var admission: Self { .init(state: State()) }
        func entering(_ stage: Stage) -> Self {
            var next = state; next.begin(stage); return .init(state: next)
        }
        /// Inner typed catches have already run. Only this known source enum is
        /// projected; cancellation, selected-service, and recovery errors survive.
        func project(_ error: any Error) -> any Error {
            guard error as? HLSSourceError == .unsupportedMedia else { return error }
            let original = HLSSourceError.unsupportedMedia as NSError
            var detail = "unsupportedMedia phase=\(state.stage.rawValue) reason=\(state.reason.rawValue) source=\(state.source.rawValue)"
            if state.reason == .httpEncoding { detail += " http=\(state.status)" }
            if state.reason == .containerInspection {
                detail += " cstage=\(state.cStage) creason=\(state.cReason) status=\(state.status) container=\(state.container) bytes=\(state.inputBytes) usable=\(state.usableBytes)"
            }
            if state.stage == .planner {
                detail += " media=\(state.mediaCount) audio=\(state.audioCount) video=\(state.videoCodec) scan=\(state.scan.rawValue) ps=\(state.parameterSets ? 1 : 0)"
            }
            return ErrorDiagnosticSnapshot(typeName: String(reflecting: HLSSourceError.self),
                code: "\(original.domain)(\(original.code))", message: detail)
        }
    }
    private let lock = NSLock()
    private let metadataOwner: HLSRuntimeFailureMetadataOwner
    private var state = State()
    private var frozen = false
    init(metadataOwner: HLSRuntimeFailureMetadataOwner) { self.metadataOwner = metadataOwner }
    func begin(_ stage: Stage) { lock.withLock {
        guard !frozen else { return }
        state.begin(stage)
    } }
    func reject(_ reason: Reason, status: Int32 = 0) { lock.withLock {
        guard !frozen else { return }; state.reason = reason; state.status = status
    } }
    func resolved(_ source: ResolvedPlaybackSource) { lock.withLock {
        guard !frozen else { return }
        switch source.topology {
        case .media: state.source = .direct
        case let .hls(graph): state.source = graph.document(for: graph.rootURL)?.kind == .master ? .master : .media
        }
    } }
    func planning(_ facts: HLSCompatibilityFacts) { lock.withLock {
        guard !frozen else { return }
        state.mediaCount = UInt16(clamping: facts.media.count)
        guard facts.media.count == 1, let media = facts.media.first else { return }
        state.audioCount = UInt8(clamping: media.audio.count)
        state.videoCodec = media.video?.codec?.rawValue ?? 0
        state.scan = media.video?.scan ?? .unknown; state.parameterSets = media.video?.parameterSetsValidated == true
    } }
    func rejectedContainer(_ diagnostic: VPFFSourceDiagnostic) { lock.withLock {
        guard !frozen else { return }
        state.reason = .containerInspection; state.status = diagnostic.native_result
        state.cStage = (0...8).contains(diagnostic.stage) ? diagnostic.stage : 0
        state.cReason = (0...13).contains(diagnostic.reason) ? diagnostic.reason : 0
        state.container = (0...3).contains(diagnostic.container_kind) ? diagnostic.container_kind : 0
        state.inputBytes = min(8 * 1_024 * 1_024 + 1, max(0, diagnostic.input_bytes))
        state.usableBytes = min(8 * 1_024 * 1_024, max(0, diagnostic.usable_bytes))
    } }
    func freeze() -> Frozen { lock.withLock { frozen = true; return Frozen(state: state) } }

    /// Same 2 KiB metadata reservation; no second charge. The mutable record is
    /// released before proxy/player/producer work can use its runtime error slot.
    /// Source/probe scopes are sequential. 256B covers the task-local cell and
    /// reabstraction; 128B covers delegate/GCD reference allocation rounding.
    var knownAllocationUpperBoundBytes: Int {
        func actual(_ object: AnyObject) -> Int { malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())) }
        let resolveCapture = malloc_good_size(32 + MemoryLayout<PlaybackSourceContext>.stride +
            MemoryLayout<any PlaybackSourceResolving>.stride + MemoryLayout<SourceResolutionReason>.stride)
        let probeCapture = malloc_good_size(32 + MemoryLayout<ResolvedPlaybackSource>.stride +
            MemoryLayout<any HLSCompatibilityProbing>.stride + MemoryLayout<HLSApplicationLifetimeCharge>.stride)
        return actual(self) + actual(lock) + metadataOwner.knownAllocationBytes +
            ErrorDiagnosticSnapshot.maximumStorageAllocationBytes + max(resolveCapture, probeCapture) +
            2 * malloc_good_size(MemoryLayout<Frozen>.stride) + 256 + 128
    }
}

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
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation, diagnostics: HLSPreparationDiagnostics? = nil) async throws -> HLSOwnedSourcePlan {
        try validate(invocation)
        let owner = try PlaybackSourceOwner(ticket: invocation.ticket, lifecycle: invocation.outputLifecycleEpoch)
        let requiresManagedTransport = !context.headers.isEmpty || context.explicitExpiry != nil
        let expired = context.explicitExpiry.map { $0 <= Date() } == true
        let bound = try context.consumingExpiry(at: Date()).bound(to: owner)
        let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
        let resolver = makeResolver()
        do {
            diagnostics?.begin(.resolve)
            let source = try await resolve(bound, resolver: resolver, reason: expired ? .expired : .initial, diagnostics: diagnostics)
            diagnostics?.resolved(source)
            try validate(invocation)
            guard await resolver.isCurrent(source) else { throw HLSSourceError.staleResolution }
            try validate(invocation)
            let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            diagnostics?.begin(.probe)
            let facts = try await inspect(source, retainingFacts: factsCharge, diagnostics: diagnostics)
            try validate(invocation)
            diagnostics?.begin(.capabilities)
            let capabilities = await capabilities(facts, invocation.currentPreparationRoute())
            try validate(invocation)
            diagnostics?.begin(.planner)
            diagnostics?.planning(facts)
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
    private func resolve(_ context: PlaybackSourceContext, resolver: any PlaybackSourceResolving, reason: SourceResolutionReason,
                         diagnostics: HLSPreparationDiagnostics?) async throws -> ResolvedPlaybackSource {
        let temporary = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.resolverTemporary)
        defer { withExtendedLifetime(temporary) {} }
        return try await HLSPreparationDiagnostics.$current.withValue(diagnostics) {
            try await resolver.resolve(context, reason: reason)
        }
    }
    private func inspect(_ source: ResolvedPlaybackSource, retainingFacts charge: HLSApplicationLifetimeCharge,
                         diagnostics: HLSPreparationDiagnostics?) async throws -> HLSCompatibilityFacts {
        let temporary = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.probeTemporary)
        defer { withExtendedLifetime(temporary) {} }
        let probe = self.probe
        return try await HLSPreparationDiagnostics.$current.withValue(diagnostics) {
            if let paid = probe as? any HLSPaidCompatibilityProbing { return try await paid.inspect(source, retainingFacts: charge) }
            return try await probe.inspect(source)
        }
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
