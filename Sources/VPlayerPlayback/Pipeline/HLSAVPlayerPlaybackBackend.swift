// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

enum HLSPrepareRetryPolicy {
    static func shouldRetry(
        completedAttemptCount: Int,
        maximumAttemptCount: Int,
        producerRetirementConfirmed: Bool,
        playerInstallationAttempted: Bool
    ) -> Bool {
        completedAttemptCount < maximumAttemptCount
            && producerRetirementConfirmed
            && !playerInstallationAttempted
    }
}

private struct HLSPrepareAttemptFailure: Error {
    let underlying: any Error
    let producerRetirementConfirmed: Bool
    let playerInstallationAttempted: Bool
}

/// prepare 在 AVPlayer item 安装前失败时，producer graph 自己签出的退役证明。
/// 该证明与 lifecycle 精确绑定、只能消费一次，不能替代已经安装 item 的
/// `AVPlayerQuiescenceReceipt`。
final class HLSPrepareFailureRetirementProof: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycle: OutputLifecycleEpoch?

    func record(
        lifecycle: OutputLifecycleEpoch,
        producerRetirementConfirmed: Bool,
        playerInstallationAttempted: Bool
    ) {
        guard producerRetirementConfirmed, !playerInstallationAttempted else { return }
        lock.withLock { self.lifecycle = lifecycle }
    }

    func consume(ifMatching lifecycle: OutputLifecycleEpoch) -> Bool {
        lock.withLock {
            guard self.lifecycle == lifecycle else { return false }
            self.lifecycle = nil
            return true
        }
    }
}

/// Registry 与真实 HLS item graph 的窄适配层。媒体生产归 `HLSOutputItemBundle`，
/// AVPlayer 状态归 coordinator；这里不另建 player、不缓存正 rate permit，也不把
/// suspend 失败伪装成可清理的 receipt。
final class HLSAVPlayerPlaybackBackend: PlaybackBackend,
    BackendPublicationReplacementAuthorityInstalling, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    let backendPublicationReplacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot

    typealias CoordinatorFactory = (AVPlayerItemReplacementBundle) async throws
        -> AVPlayerItemCoordinator

    typealias SourceBundleBuilderFactory = @Sendable (URL, HLSOwnedSourcePlan?) throws -> any HLSOutputItemBundleBuilding
    private var sourceDependencies: HLSNativeSourceDependencies?
    private var sessionLease: HomePodAVPlayerSession.Lease?
    private var sourceBuilderFactory: SourceBundleBuilderFactory?
    private var sourceEventSink: @Sendable (PlaybackPipelineEvent) -> Void = { _ in }
    private var sourceScope: OutputLifecycleEpoch?
    private var ownedSource: HLSOwnedSourcePlan?
    private var sourceProxy: HLSProxySession?
    private var nativeAdapter: NativeHLSPlaybackBackend?
    private var sourceBuilder: (any HLSOutputItemBundleBuilding)?
    private var sourceActivation: ActivationEpoch?
    private var sourceFailureDelivered: OutputLifecycleEpoch?
    private var sourceFailureMetadata: HLSRuntimeFailureMetadataOwner?
    private var sourceFailureTask: Task<Void, Never>?
    private var pendingCompatibleOwner: HLSOwnedSourcePlan?
    private var audioRejection: HLSGeneratedAudioRejection?
    private var sourceBundleCalls = 0

    func configureSourceRouting(dependencies: HLSNativeSourceDependencies, sessionLease: HomePodAVPlayerSession.Lease,
                                builderFactory: @escaping SourceBundleBuilderFactory,
                                eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) {
        lock.withLock {
            precondition(sourceDependencies == nil && bundle == nil && preparingBundle == nil)
            precondition(sessionLease.backend == identity)
            sourceDependencies = dependencies; self.sessionLease = sessionLease
            sourceBuilderFactory = builderFactory; sourceEventSink = eventSink
        }
    }
    var routedTransportForTesting: HLSPlaybackPlan.Transport? { lock.withLock { ownedSource?.plan.transport } }
    var generatedBundleCallsForTesting: Int { lock.withLock { sourceBundleCalls } }
    #if DEBUG
    var nativeCoordinatorForTesting: NativeHLSItemCoordinator? { lock.withLock { nativeAdapter?.coordinator } }
    @MainActor var nativeSystemDriverForTesting: SystemAVPlayerDriver? {
        let lease = lock.withLock { sessionLease }
        return lease?.driver as? SystemAVPlayerDriver
    }
    #endif

    /// legacy 注入路径在 construction 时已有 coordinator；系统路径则必须等同一 bundle
    /// 的 prefix/server/evidence 就绪后才创建，避免用第二台 server 的 evidence 安装 item。
    private var coordinator: AVPlayerItemCoordinator?
    private let coordinatorFactory: CoordinatorFactory
    private let bundleBuilder: any HLSOutputItemBundleBuilding
    /// 由实际 driver 创建者注入的同一 AVPlayer alias；backend 不在这里再造 player。
    private let presentationContext: AVPlayerPresentationContext?
    private let lock = NSLock()
    /// makeBundle 后、producer 启动前即由 backend 强持。这样 prepare 任意 await
    /// 边界都不会让唯一 source/server/writer 图失去 owner。
    private var preparingBundle: HLSOutputItemBundle?
    private var bundle: HLSOutputItemBundle?
    private var latestReceipt: AVPlayerQuiescenceReceipt?
    private let prepareFailureRetirementProof = HLSPrepareFailureRetirementProof()
    private let audioOnlySelector: AudioOnlyItemSelector?
    private let metrics: PlaybackMetrics?
    private let channelID: String?
    private var activationTime: ContinuousClock.Instant?
    private var logSnapshotCache: AVPlayerLogSnapshotCache?

    init(
        identity: PlaybackBackendIdentity,
        coordinator: AVPlayerItemCoordinator,
        bundleBuilder: any HLSOutputItemBundleBuilding,
        presentationContext: AVPlayerPresentationContext? = nil,
        replacementSlot: ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot = .init(),
        audioOnlySelector: AudioOnlyItemSelector? = nil,
        metrics: PlaybackMetrics? = nil,
        channelID: String? = nil
    ) {
        self.identity = identity
        self.coordinator = coordinator
        coordinatorFactory = { _ in coordinator }
        self.bundleBuilder = bundleBuilder
        self.presentationContext = presentationContext
        backendPublicationReplacementAuthoritySlot = replacementSlot
        self.audioOnlySelector = audioOnlySelector
        self.metrics = metrics
        self.channelID = channelID
    }

    init(
        identity: PlaybackBackendIdentity,
        bundleBuilder: any HLSOutputItemBundleBuilding,
        presentationContext: AVPlayerPresentationContext? = nil,
        audioOnlySelector: AudioOnlyItemSelector? = nil,
        metrics: PlaybackMetrics? = nil,
        channelID: String? = nil,
        coordinatorFactory: @escaping CoordinatorFactory,
        replacementSlot: ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot = .init()
    ) {
        self.identity = identity
        self.coordinator = nil
        self.coordinatorFactory = coordinatorFactory
        self.bundleBuilder = bundleBuilder
        self.presentationContext = presentationContext
        backendPublicationReplacementAuthoritySlot = replacementSlot
        self.audioOnlySelector = audioOnlySelector
        self.metrics = metrics
        self.channelID = channelID
    }

    convenience init(
        identity: PlaybackBackendIdentity,
        bundleBuilder: any HLSOutputItemBundleBuilding,
        presentationContext: AVPlayerPresentationContext,
        metrics: PlaybackMetrics? = nil,
        channelID: String? = nil,
        coordinatorFactory: @escaping CoordinatorFactory,
        replacementSlot: ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot = .init()
    ) {
        self.init(
            identity: identity,
            bundleBuilder: bundleBuilder,
            presentationContext: presentationContext,
            audioOnlySelector: nil,
            metrics: metrics,
            channelID: channelID,
            coordinatorFactory: coordinatorFactory,
            replacementSlot: replacementSlot
        )
    }

    var isAudioOnly: Bool {
        audioOnlySelector != nil || lock.withLock {
            if nativeAdapter != nil, let ownedSource { return ownedSource.facts.media.allSatisfy { $0.video == nil } }
            return bundle?.isAudioOnly ?? preparingBundle?.isAudioOnly ?? false
        }
    }

    var presentation: PlaybackPresentation? { presentationContext.map(PlaybackPresentation.avPlayer) }

    var outputItemGeneration: UInt64? { lock.withLock { nativeAdapter?.itemGeneration ?? bundle?.itemGeneration } }

    func preparedMediaInformation(for lifecycle: OutputLifecycleEpoch) -> PlaybackPreparedMediaInformation? {
        lock.withLock { nativeAdapter?.metadata.snapshot(for: lifecycle) ?? bundle?.preparedMediaInformation(for: lifecycle) }
    }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        if sourceDependencies != nil { try await prepareRouted(invocation: invocation); return }
        let maximumAttemptCount = audioOnlySelector == nil ? 2 : 1
        var completedAttemptCount = 0
        while completedAttemptCount < maximumAttemptCount {
            do {
                try await prepareSingleAttempt(invocation: invocation)
                return
            } catch let failure as HLSPrepareAttemptFailure {
                completedAttemptCount += 1
                if !Task.isCancelled, invocation.revalidateCurrentPreparation(),
                   !(failure.underlying is CancellationError),
                   HLSPrepareRetryPolicy.shouldRetry(
                    completedAttemptCount: completedAttemptCount,
                    maximumAttemptCount: maximumAttemptCount,
                    producerRetirementConfirmed: failure.producerRetirementConfirmed,
                    playerInstallationAttempted: failure.playerInstallationAttempted
                ) {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append(
                        "hls_prepare_retry_\(completedAttemptCount)")
                    #endif
                    continue
                }
                prepareFailureRetirementProof.record(
                    lifecycle: invocation.outputLifecycleEpoch,
                    producerRetirementConfirmed: failure.producerRetirementConfirmed,
                    playerInstallationAttempted: failure.playerInstallationAttempted)
                throw failure.underlying
            }
        }
        preconditionFailure("HLS prepare 尝试次数必须由成功或错误终结")
    }

    private func prepareSingleAttempt(
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) async throws {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("hls_backend_prepare_start")
        #endif
        let next = try await makeNextBundle(invocation: invocation)
        let installedPreparing = lock.withLock { () -> Bool in
            guard preparingBundle == nil, bundle == nil else { return false }
            preparingBundle = next
            return true
        }
        guard installedPreparing else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        do {
            try validatePreparation(invocation)
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("hls_prepareProducer")
            #endif
            try await next.prepareProducer()
            try validatePreparation(invocation)
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("hls_producerPrepared")
            #endif
            guard next.replacement.request.item.outputLifecycleEpoch == invocation.outputLifecycleEpoch,
                  next.replacement.request.item.outputLifecycleEpoch.backendIdentity == identity else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("hls_coordFactory")
            #endif
            let createdCoordinator = try await coordinatorFactory(next.replacement)
            try validatePreparation(invocation)
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_coordInstall")
            #endif
            // 从这一刻起即使 install 抛错，也不能再用 producer-only 凭据证明
            // AVPlayer 已清理；后续必须走 coordinator 的物理停止路径。
            let cache = await createdCoordinator.logSnapshotCache
            try validatePreparation(invocation)
            do {
                try await MainActor.run {
                    try self.validatePreparation(invocation)
                    // This same synchronous stack commits ownership immediately
                    // before installation; a canceled actor hop owns only producer cleanup.
                    self.lock.withLock {
                        precondition(self.preparingBundle === next, "preparing bundle owner 不匹配")
                        self.coordinator = createdCoordinator
                        self.bundle = next
                        self.preparingBundle = nil
                        self.latestReceipt = nil
                        self.logSnapshotCache = cache
                    }
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("hls_c_inst_pre")
                    #endif
                    if let owned = self.lock.withLock({ self.ownedSource }) {
                        createdCoordinator.setInstallationMutation { operation in
                            try invocation.performCurrentPreparationMutation {
                                guard owned.source.withCurrentResolution(owner: owned.plan.owner, generation: owned.source.generation, operation: {
                                    operation(); return true
                                }) == true else { throw HLSSourceError.staleResolution }
                            }
                        }
                    }
                    try createdCoordinator.install(next.replacement.request)
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("hls_c_inst_ok")
                    #endif
                    try createdCoordinator.bindPrepareInvocation(invocation)
                    try createdCoordinator.bindRuntimeFailureRelay(next.runtimeFailureRelay,
                        invocation: invocation)
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("hls_c_bind_ok")
                    #endif
                }
            } catch {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("hls_c_inst_err_\(error)")
                #endif
                throw error
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_coordInstalled")
            #endif
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_prepCurrentItem")
            #endif
            do {
                try validatePreparation(invocation)
                _ = try await createdCoordinator.prepareCurrentItem(invocation: invocation)
                try validatePreparation(invocation)
            } catch {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("hls_prep_err_\(error)")
                #endif
                throw error
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_backendPrepared")
            #endif
            next.armRuntimeFailure()
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_catch_\(error)")
            #endif
            let producerRetirementConfirmed = await next.retireProducerGraph()
            let playerInstallationAttempted = lock.withLock { bundle === next }
            lock.withLock {
                // After installation begins, only the signed suspend receipt and
                // physical coordinator cleanup may release these owners.
                if !playerInstallationAttempted, producerRetirementConfirmed,
                   preparingBundle === next { preparingBundle = nil }
                latestReceipt = nil
            }
            throw HLSPrepareAttemptFailure(
                underlying: next.preservingFirstPreparationFailure(error),
                producerRetirementConfirmed: producerRetirementConfirmed,
                playerInstallationAttempted: playerInstallationAttempted)
        }
    }

    private func validatePreparation(_ invocation: ControlTaskRegistry.BackendPrepareInvocation) throws {
        try Task.checkCancellation()
        guard invocation.outputLifecycleEpoch.backendIdentity == identity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        guard invocation.revalidateCurrentPreparation() else { throw CancellationError() }
        let scope = lock.withLock { (sourceScope, ownedSource, sourceFailureDelivered) }
        if scope.0 == invocation.outputLifecycleEpoch {
            guard scope.2 != invocation.outputLifecycleEpoch else { throw HLSSourceError.staleResolution }
            if let owned = scope.1, !owned.isCurrent { throw HLSSourceError.staleResolution }
        }
    }

    private func makeNextBundle(
        invocation: ControlTaskRegistry.BackendPrepareInvocation
    ) async throws -> HLSOutputItemBundle {
        if let selector = audioOnlySelector {
            // Audio-only AirPlay flow:
            // 1. 串行选择胜出候选（不建 video/Metal/VT/master 资源，不等待 IDR）
            let selectionResult = try await selector.select()
            let winner = selectionResult.selectedBundle

            // 2. 提取直接单 rendition media item replacement
            guard let replacement = winner.replacement else {
                throw AudioOnlySelectionFailure.missingDirectMediaItem
            }

            return HLSOutputItemBundle(
                replacement: replacement,
                startProducer: { replacement },
                retireProducer: {
                    await winner.cleanup(reason: .invalidation, timeout: 1.0)
                }
            )
        } else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("hls_makeBundle")
            #endif
            let builder = lock.withLock { () -> any HLSOutputItemBundleBuilding in
                if sourceDependencies != nil { sourceBundleCalls += 1 }
                return sourceBuilder ?? bundleBuilder
            }
            return try await builder.makeBundle(invocation: invocation)
        }
    }

    /// publication replacement 已退休旧 source/item，但保留同一 coordinator 与
    /// presentation。新 lifecycle 必须真正重开上游、安装新 generation 并完成 rate-0
    /// prepare；只重新绑定 invocation 会把已结束的旧 item 永久留在最后一帧。
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        if sourceDependencies != nil { try await prepareRouted(invocation: invocation); return }
        guard let coordinator = lock.withLock({ self.coordinator }),
              lock.withLock({ bundle == nil && preparingBundle == nil }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let next = try await makeNextBundle(invocation: invocation)
        guard lock.withLock({ () -> Bool in
            guard bundle == nil, preparingBundle == nil else { return false }
            preparingBundle = next
            return true
        }) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        do {
            try validatePreparation(invocation)
            try await next.prepareProducer()
            try validatePreparation(invocation)
            guard next.replacement.request.item.outputLifecycleEpoch
                    == invocation.outputLifecycleEpoch,
                  invocation.outputLifecycleEpoch.backendIdentity == identity else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            try await MainActor.run {
                try self.validatePreparation(invocation)
                self.lock.withLock {
                    precondition(self.preparingBundle === next, "replacement bundle owner 不匹配")
                    self.bundle = next
                    self.preparingBundle = nil
                    self.latestReceipt = nil
                }
                try coordinator.installReplacement(
                    next.replacement,
                    invocation: invocation
                )
                try coordinator.bindRuntimeFailureRelay(next.runtimeFailureRelay,
                    invocation: invocation)
            }
            try validatePreparation(invocation)
            _ = try await coordinator.prepareCurrentItem(invocation: invocation)
            try validatePreparation(invocation)
            next.armRuntimeFailure()
        } catch {
            let producerRetirementConfirmed = await next.retireProducerGraph()
            let playerInstallationAttempted = lock.withLock { bundle === next }
            lock.withLock {
                if !playerInstallationAttempted, producerRetirementConfirmed,
                   preparingBundle === next { preparingBundle = nil }
                latestReceipt = nil
            }
            prepareFailureRetirementProof.record(
                lifecycle: invocation.outputLifecycleEpoch,
                producerRetirementConfirmed: producerRetirementConfirmed,
                playerInstallationAttempted: playerInstallationAttempted)
            throw next.preservingFirstPreparationFailure(error)
        }
    }

    func requestWatchdogRecovery(activation: ActivationEpoch) async -> Bool {
        if let native = lock.withLock({ nativeAdapter }) {
            guard await native.coordinator.currentActivation == activation else { return false }
            return backendPublicationReplacementAuthoritySlot.requestWatchdogRecovery(activation: activation)
        }
        guard let coordinator = lock.withLock({ self.coordinator }) else { return false }
        return await coordinator.requestWatchdogRecovery(activation: activation)
    }

    func activateOutput(
        invocation: ControlTaskRegistry.BackendPositiveRateInvocation
    ) async throws {
        if sourceDependencies != nil { lock.withLock { sourceActivation = invocation.activation } }
        if let native = lock.withLock({ nativeAdapter }) {
            try await native.coordinator.activate(invocation)
            lock.withLock { if activationTime == nil { activationTime = .now } }
            return
        }
        guard let coordinator = lock.withLock({ self.coordinator }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        switch try await coordinator.activate(invocation) {
        case .armed, .alreadyArmed:
            lock.withLock {
                if self.activationTime == nil {
                    self.activationTime = .now
                }
            }
            return
        case .rejected:
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func suspendOutput(
        invocation: ControlTaskRegistry.BackendSuspendInvocation
    ) async -> BackendSuspendResult {
        lock.withLock { sourceActivation = nil }
        if let native = lock.withLock({ nativeAdapter }) {
            do {
                let receipt = try await native.coordinator.stop(invocation)
                let attestation = try await MainActor.run {
                    try AVPlayerBackendQuiescenceAttestation.native(receipt, invocation: invocation, coordinator: native.coordinator)
                }
                lock.withLock { latestReceipt = receipt }
                return .quiescent(.avPlayer(attestation))
            } catch { return .requiresRetirement }
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.append("cap_hls_suspend_begin")
        #endif
        do {
            guard let coordinator = lock.withLock({ self.coordinator }) else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("cap_hls_suspend_err_missing_coordinator")
                #endif
                return .requiresRetirement
            }
            let receipt = try await coordinator.stop(invocation)
            let attestation = try await MainActor.run {
                try coordinator.attestQuiescence(
                    receipt, invocation: invocation, backendIdentity: identity)
            }
            lock.withLock { latestReceipt = receipt }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_suspend_receipt")
            #endif
            return .quiescent(.avPlayer(attestation))
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_suspend_err_\(error)")
            #endif
            // 没有 receipt 就绝不向 Registry 声明可以 completeLifecycleCleanup。
            return .requiresRetirement
        }
    }

    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        if sourceDependencies != nil { return await retireRouted(epoch: epoch) }
        return await retireGeneratedOutput(epoch: epoch)
    }

    private func retireGeneratedOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.append("cap_hls_retire_begin")
        #endif
        guard epoch.backendIdentity == identity else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_stale_epoch")
            #endif
            return .unconfirmed
        }
        if prepareFailureRetirementProof.consume(ifMatching: epoch) {
            lock.withLock {
                preparingBundle = nil
                bundle = nil
                latestReceipt = nil
                activationTime = nil
                logSnapshotCache = nil
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_confirmed_prepare_failure")
            #endif
            return .confirmedLocalOutputStopped
        }
        guard let retiring = lock.withLock({ bundle }),
              let coordinator = lock.withLock({ self.coordinator }) else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_missing_owner")
            #endif
            return .unconfirmed
        }
        guard retiring.replacement.request.item.outputLifecycleEpoch == epoch else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_stale_epoch")
            #endif
            return .unconfirmed
        }
        guard let receipt = lock.withLock({ latestReceipt }),
              await MainActor.run(body: { coordinator.accept(receipt) }) else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_missing_receipt")
            #endif
            // 失败 suspend 的图必须由独立真实停止路径确认；当前不能把它误变为已退休。
            return .unconfirmed
        }
        let preservesCoordinator = await MainActor.run {
            coordinator.requiresReplacementRetirement(epoch)
        }
        do {
            if preservesCoordinator {
                try await coordinator.retireForReplacement(epoch)
            } else {
                try await MainActor.run {
                    try coordinator.completeLifecycleCleanup(receipt)
                }
            }
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_cleanup_\(error)")
            #endif
            return .unconfirmed
        }
        guard await retiring.retireProducerGraph() else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("cap_hls_retire_err_producer")
            #endif
            return .unconfirmed
        }
        lock.withLock {
            if bundle === retiring { bundle = nil }
            if !preservesCoordinator { self.coordinator = nil }
            latestReceipt = nil
            if !preservesCoordinator {
                self.activationTime = nil
                self.logSnapshotCache = nil
            }
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.append("cap_hls_retire_confirmed")
        #endif
        return .confirmedLocalOutputStopped
    }

    private func prepareRouted(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        try validatePreparation(invocation)
        guard let dependencies = sourceDependencies, let lease = sessionLease else { throw HLSSourceError.unboundOwner }
        let failureMetadata = try HLSRuntimeFailureMetadataOwner.reserve(in: .shared)
        guard try invocation.performCurrentPreparationMutation({
            try lock.withLock {
                guard ownedSource == nil, nativeAdapter == nil, sourceProxy == nil, sourceBuilder == nil,
                      bundle == nil, preparingBundle == nil, sourceFailureTask == nil else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
                sourceScope = invocation.outputLifecycleEpoch; sourceFailureDelivered = nil
                sourceFailureMetadata = failureMetadata; sourceActivation = nil; pendingCompatibleOwner = nil
            }
        }) else { throw CancellationError() }
        do {
            var owned = try await dependencies.prepare(invocation: invocation)
            try validatePreparation(invocation)
            if lock.withLock({ audioRejection?.matches(owned) == true }) {
                let compatible = owned.usingCompatibleAudio(); owned.retireGeneratedAttempt(); owned = compatible
            }
            try installSource(owned, invocation: invocation)
            let managed = !dependencies.context.headers.isEmpty || dependencies.context.explicitExpiry != nil
            if owned.plan.transport == .proxy || (owned.plan.transport == .generated && managed) {
                let original = owned
                let proxy = try await HLSByteProxy.start(source: owned.source, lifecycle: invocation.outputLifecycleEpoch,
                    resolver: owned.resolver, sourceRetention: owned.sourceCharge, manifestAuthority: owned.makeProxyManifestAuthority(),
                    useGeneratedSelectedService: owned.plan.transport == .generated,
                    failure: { [weak self] error in self?.sourceTransportFailed(error, source: original, invocation: invocation) })
                do {
                    try validatePreparation(invocation)
                    guard try invocation.performCurrentPreparationMutation({ self.lock.withLock { self.sourceProxy = proxy } }) else { throw CancellationError() }
                } catch { _ = await proxy.retire(); throw error }
            }
            if owned.plan.transport == .generated {
                try await prepareGeneratedSource(owned, invocation: invocation)
            } else {
                let original = owned
                let coordinator = try await MainActor.run {
                    try NativeHLSItemCoordinator(driver: lease.driver, inspector: dependencies.makeInspector(lease.driver),
                        owned: original, invocation: invocation,
                        metadataChanged: { activation in await invocation.deliverNativeMediaInformation(activation: activation, invalidated: activation == nil) },
                        failure: { [weak self] error, _ in self?.sourceTransportFailed(error, source: original, invocation: invocation) })
                }
                let native = NativeHLSPlaybackBackend(owned: owned, coordinator: coordinator,
                    proxy: lock.withLock { sourceProxy }, lifecycle: invocation.outputLifecycleEpoch)
                guard try invocation.performCurrentPreparationMutation({ self.lock.withLock { self.nativeAdapter = native } }) else { throw CancellationError() }
                try await native.prepare()
                try validatePreparation(invocation)
            }
        } catch {
            let native = lock.withLock { nativeAdapter }
            let installed = await native?.coordinator.hasInstalledItem ?? false
            let noGraph = lock.withLock { bundle == nil && preparingBundle == nil }
            if !installed && noGraph {
                let nativeJoined = await native?.coordinator.retire() ?? true
                let owned = lock.withLock { ownedSource }
                await owned?.resolver.invalidate()
                let proxy = lock.withLock { sourceProxy }
                let proxyJoined = await proxy?.retire() ?? true
                if nativeJoined && proxyJoined {
                    await clearSourceOwnership()
                    prepareFailureRetirementProof.record(lifecycle: invocation.outputLifecycleEpoch,
                        producerRetirementConfirmed: true, playerInstallationAttempted: false)
                }
            }
            throw error
        }
    }

    private func installSource(_ owned: HLSOwnedSourcePlan, invocation: ControlTaskRegistry.BackendPrepareInvocation) throws {
        owned.installGenerationRecovery { [weak self, weak owned] in
            guard let self, let owned else { return false }
            return self.requestSourceGeneration(owned, invocation: invocation)
        }
        owned.installCompatibleAudioRecovery { [weak self, weak owned] in
            guard let self, let owned else { return false }
            return self.requestCompatibleAudio(owned, invocation: invocation)
        }
        guard try invocation.performCurrentPreparationMutation({
            guard owned.source.withCurrentResolution(owner: owned.plan.owner, generation: owned.source.generation, operation: {
                self.lock.withLock { self.ownedSource = owned; self.pendingCompatibleOwner = nil }
                return true
            }) == true else { throw HLSSourceError.staleResolution }
        }) else { throw CancellationError() }
    }
    private func installSourceBuilder(_ owned: HLSOwnedSourcePlan) throws {
        guard let sourceBuilderFactory else { throw HLSSourceError.unboundOwner }
        let input = lock.withLock { sourceProxy?.itemURL } ?? owned.plan.selectedServiceURL ?? owned.source.context.entryURL
        let builder = try sourceBuilderFactory(input, owned)
        lock.withLock { sourceBuilder = builder }
    }
    private func prepareGeneratedSource(_ initial: HLSOwnedSourcePlan, invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        var owned = initial
        try installSourceBuilder(owned)
        do { try await prepareSingleAttempt(invocation: invocation); return }
        catch let failure as HLSPrepareAttemptFailure {
            let accepted = lock.withLock { pendingCompatibleOwner === owned }
            guard accepted, failure.producerRetirementConfirmed, !failure.playerInstallationAttempted,
                  !Task.isCancelled, invocation.revalidateCurrentPreparation() else {
                prepareFailureRetirementProof.record(lifecycle: invocation.outputLifecycleEpoch,
                    producerRetirementConfirmed: failure.producerRetirementConfirmed, playerInstallationAttempted: failure.playerInstallationAttempted)
                throw failure.underlying
            }
            // Exactly one compatible attempt, after the rejected graph physically
            // joined. Same source/proxy/facts/deadline; no resolve or nested loop.
            let compatible = owned.usingCompatibleAudio()
            owned.retireGeneratedAttempt(); owned = compatible
            try installSource(owned, invocation: invocation)
            try installSourceBuilder(owned)
        }
        do { try await prepareSingleAttempt(invocation: invocation) }
        catch let failure as HLSPrepareAttemptFailure {
            prepareFailureRetirementProof.record(lifecycle: invocation.outputLifecycleEpoch,
                producerRetirementConfirmed: failure.producerRetirementConfirmed, playerInstallationAttempted: failure.playerInstallationAttempted)
            throw failure.underlying
        }
    }
    private func requestSourceGeneration(_ owned: HLSOwnedSourcePlan, invocation: ControlTaskRegistry.BackendPrepareInvocation) -> Bool {
        guard owned.isCurrent, let executor = invocation.sharedControlExecutor else { return false }
        return executor.sync {
            guard let activation = lock.withLock({ ownedSource === owned ? sourceActivation : nil }),
                  backendPublicationReplacementAuthoritySlot.currentAuthority() === invocation.replacementAuthority else { return false }
            return invocation.replacementAuthority.requestWatchdogRecovery(activation: activation)
        }
    }
    private func requestCompatibleAudio(_ owned: HLSOwnedSourcePlan, invocation: ControlTaskRegistry.BackendPrepareInvocation) -> Bool {
        guard let rejection = owned.audioRejectionRecord(), let executor = invocation.sharedControlExecutor else { return false }
        return executor.sync {
            var previous: HLSGeneratedAudioRejection?
            let prepared = (try? invocation.performCurrentPreparationMutation {
                guard try owned.source.withCurrentResolution(owner: owned.plan.owner, generation: owned.source.generation, operation: {
                    try self.lock.withLock {
                        guard self.ownedSource === owned, self.preparingBundle != nil, self.bundle == nil,
                              self.pendingCompatibleOwner == nil else { throw HLSSourceError.staleResolution }
                        previous = self.audioRejection; self.audioRejection = rejection; self.pendingCompatibleOwner = owned
                        return true
                    }
                }) == true else { throw HLSSourceError.staleResolution }
            }) == true
            if prepared { withExtendedLifetime(previous) {}; return true }
            guard owned.isCurrent, let activation = lock.withLock({ ownedSource === owned ? sourceActivation : nil }),
                  backendPublicationReplacementAuthoritySlot.currentAuthority() === invocation.replacementAuthority,
                  invocation.replacementAuthority.requestWatchdogRecovery(activation: activation) else { return false }
            // This original executor serializes acceptance and the latch before
            // any successor can pass its Registry preparation admission.
            lock.withLock { previous = audioRejection; audioRejection = rejection }
            withExtendedLifetime(previous) {}
            return true
        }
    }
    private func sourceTransportFailed(_ error: HLSSourceError, source: HLSOwnedSourcePlan,
                                       invocation: ControlTaskRegistry.BackendPrepareInvocation) {
        // Proxy ownership survives an AAC attempt replacement; transport scope is
        // the original source owner/generation, not the retired graph object.
        let admitted = lock.withLock { () -> (ActivationEpoch?, HLSRuntimeFailureMetadataOwner)? in
            guard sourceScope == invocation.outputLifecycleEpoch, let current = ownedSource,
                  current.plan.owner == source.plan.owner, current.source.generation == source.source.generation,
                  sourceFailureDelivered != invocation.outputLifecycleEpoch, let metadata = sourceFailureMetadata else { return nil }
            sourceFailureDelivered = invocation.outputLifecycleEpoch
            return (sourceActivation, metadata)
        }
        guard let admitted else { return }
        if let activation = admitted.0, invocation.replacementAuthority.requestWatchdogRecovery(activation: activation) { return }
        lock.withLock {
            // Creation and publication share the ownership lock. Retirement can
            // never miss a task that has already begun a receiver actor hop.
            guard sourceScope == invocation.outputLifecycleEpoch, sourceFailureTask == nil else { return }
            sourceFailureTask = Task { [weak self] in
                await invocation.deliverNativeMediaInformation(activation: admitted.0, invalidated: true)
                guard let self, !Task.isCancelled,
                      self.lock.withLock({ self.sourceScope == invocation.outputLifecycleEpoch }) else { return }
                self.sourceEventSink(.backendFailed(PlaybackErrorDiagnostics.snapshot(error),
                    prepareScope: .init(ticket: invocation.ticket), metadataOwner: admitted.1))
            }
        }
    }
    private func clearSourceOwnership() async {
        // Close callback admission and detach every alias atomically; releases and
        // callback joins happen outside the ownership lock.
        let retired = lock.withLock {
            let result = (sourceFailureTask, ownedSource, nativeAdapter, sourceProxy, sourceBuilder,
                          sourceFailureMetadata, pendingCompatibleOwner)
            sourceScope = nil; sourceActivation = nil
            sourceFailureTask = nil; sourceFailureDelivered = nil; pendingCompatibleOwner = nil
            ownedSource = nil; nativeAdapter = nil; sourceProxy = nil; sourceBuilder = nil; sourceFailureMetadata = nil
            return result
        }
        retired.0?.cancel(); await retired.0?.value
        retired.1?.retireGeneratedAttempt()
        withExtendedLifetime(retired) {}
    }
    private func retireRouted(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        guard epoch.backendIdentity == identity else { return .unconfirmed }
        let native = lock.withLock { nativeAdapter }
        if let native {
            guard native.itemGeneration == epoch.outputNonce, await native.retire() else { return .unconfirmed }
        } else {
            guard case .confirmedLocalOutputStopped = await retireGeneratedOutput(epoch: epoch) else { return .unconfirmed }
            let source = lock.withLock { ownedSource }
            await source?.resolver.invalidate()
            let proxy = lock.withLock { sourceProxy }
            guard await proxy?.retire() ?? true else { return .unconfirmed }
        }
        await clearSourceOwnership()
        lock.withLock { latestReceipt = nil; activationTime = nil; logSnapshotCache = nil }
        return .confirmedLocalOutputStopped
    }

    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        guard let activationTime = lock.withLock({ self.activationTime }) else {
            return nil
        }
        let duration = ContinuousClock.now - activationTime
        let elapsed = max(0, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        let isInterlaced = !(channelID?.contains("4K") == true || channelID?.contains("progressive") == true || channelID?.contains("2160") == true || channelID?.contains("UHD") == true || isAudioOnly)
        metrics?.updateHLSPlaybackCounters(elapsedSeconds: elapsed, isInterlaced: isInterlaced)
        if let player = presentationContext?.player {
            let item = player.currentItem
            let currentTime = player.currentTime()
            let currentSeconds = currentTime.isNumeric && currentTime.seconds.isFinite
                ? currentTime.seconds : nil
            let loadedEnd = item?.loadedTimeRanges.compactMap { value -> Double? in
                let range = value.timeRangeValue
                guard range.start.isNumeric, range.duration.isNumeric else { return nil }
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                return end.isFinite ? end : nil
            }.max()
            let bufferedAhead = currentSeconds.flatMap { current in
                loadedEnd.map { max(0, $0 - current) }
            } ?? 0
            let timeControlStatus: String
            switch player.timeControlStatus {
            case .paused: timeControlStatus = "paused"
            case .waitingToPlayAtSpecifiedRate: timeControlStatus = "waiting"
            case .playing: timeControlStatus = "playing"
            @unknown default: timeControlStatus = "unknown"
            }
            let itemStatus: String
            switch item?.status {
            case .unknown: itemStatus = "unknown"
            case .readyToPlay: itemStatus = "ready"
            case .failed: itemStatus = "failed"
            case nil: itemStatus = "missing"
            @unknown default: itemStatus = "unknown"
            }
            let errorCode = item?.error.map {
                "\(($0 as NSError).domain):\(($0 as NSError).code)"
            } ?? "none"
            let logContext = lock.withLock { (bundle?.replacement.request.item, logSnapshotCache) }
            let itemGeneration = logContext.0?.itemGeneration ?? 0
            let logSnapshot: AVPlayerLogScalarSnapshot
            if let item, let identity = logContext.0, let cache = logContext.1 {
                let objectIdentity = ObjectIdentifier(item)
                logSnapshot = cache.snapshot(item: identity, objectIdentity: objectIdentity)
                cache.requestRefresh(item: identity, objectIdentity: objectIdentity)
            } else {
                logSnapshot = .empty
            }
            let summary = String(
                format: "avplayer:gen=%llu,tc=%@,item=%@,rate=%.3f,buffer=%.3f,empty=%d,keepUp=%d,access=%ld,errorLog=%ld,error=%@",
                itemGeneration,
                timeControlStatus,
                itemStatus,
                player.rate,
                bufferedAhead,
                item?.isPlaybackBufferEmpty == true ? 1 : 0,
                item?.isPlaybackLikelyToKeepUp == true ? 1 : 0,
                logSnapshot.accessEventCount,
                logSnapshot.errorEventCount,
                errorCode
            )
            metrics?.update(scanType: isInterlaced
                ? .interlaced(.init(
                    parity: .top,
                    confidence: .assumed,
                    source: .none
                ))
                : .progressive)
            metrics?.update(activeRoute: isInterlaced ? .metalYADIF2x : .bypass)
            metrics?.updateReadinessDiagnostics(
                audioRoute: .systemCompressed,
                audioReady: item?.status == .readyToPlay && item?.isPlaybackBufferEmpty != true,
                readinessOpen: player.timeControlStatus == .playing && player.rate > 0,
                retainedAudioCount: logSnapshot.accessEventCount,
                retainedVideoCount: logSnapshot.errorEventCount,
                audioFirstPTS: nil,
                audioDuration: CMTime(seconds: bufferedAhead, preferredTimescale: 1_000),
                videoFirstPTS: nil,
                clockTime: currentSeconds.map {
                    CMTime(seconds: $0, preferredTimescale: 1_000)
                }
            )
            metrics?.recordDecoderSession(summary: summary)
        }
        return metrics?.snapshot(window: window)
    }
}
