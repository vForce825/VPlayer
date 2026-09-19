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

    var isAudioOnly: Bool { audioOnlySelector != nil }

    var presentation: PlaybackPresentation? { presentationContext.map(PlaybackPresentation.avPlayer) }

    var outputItemGeneration: UInt64? { lock.withLock { bundle?.itemGeneration } }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        let maximumAttemptCount = audioOnlySelector == nil ? 2 : 1
        var completedAttemptCount = 0
        while completedAttemptCount < maximumAttemptCount {
            do {
                try await prepareSingleAttempt(invocation: invocation)
                return
            } catch let failure as HLSPrepareAttemptFailure {
                completedAttemptCount += 1
                if HLSPrepareRetryPolicy.shouldRetry(
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
        var playerInstallationAttempted = false
        do {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("hls_prepareProducer")
            #endif
            try await next.prepareProducer()
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
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_coordInstall")
            #endif
            // 从这一刻起即使 install 抛错，也不能再用 producer-only 凭据证明
            // AVPlayer 已清理；后续必须走 coordinator 的物理停止路径。
            playerInstallationAttempted = true
            do {
                try await MainActor.run {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("hls_c_inst_pre")
                    #endif
                    try createdCoordinator.install(next.replacement.request)
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("hls_c_inst_ok")
                    #endif
                    try createdCoordinator.bindPrepareInvocation(invocation)
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
            lock.withLock {
                precondition(preparingBundle === next, "preparing bundle owner 不匹配")
                coordinator = createdCoordinator
                bundle = next
                preparingBundle = nil
                latestReceipt = nil
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_prepCurrentItem")
            #endif
            do {
                _ = try await createdCoordinator.prepareCurrentItem(invocation: invocation)
            } catch {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("hls_prep_err_\(error)")
                #endif
                throw error
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_backendPrepared")
            #endif
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("hls_catch_\(error)")
            #endif
            let producerRetirementConfirmed = await next.retireProducerGraph()
            lock.withLock {
                if bundle === next { bundle = nil }
                if preparingBundle === next { preparingBundle = nil }
                latestReceipt = nil
            }
            throw HLSPrepareAttemptFailure(
                underlying: error,
                producerRetirementConfirmed: producerRetirementConfirmed,
                playerInstallationAttempted: playerInstallationAttempted)
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
            return try await bundleBuilder.makeBundle(invocation: invocation)
        }
    }

    /// publication replacement 已退休旧 source/item，但保留同一 coordinator 与
    /// presentation。新 lifecycle 必须真正重开上游、安装新 generation 并完成 rate-0
    /// prepare；只重新绑定 invocation 会把已结束的旧 item 永久留在最后一帧。
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
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
            try await next.prepareProducer()
            guard next.replacement.request.item.outputLifecycleEpoch
                    == invocation.outputLifecycleEpoch,
                  invocation.outputLifecycleEpoch.backendIdentity == identity else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            try await MainActor.run {
                try coordinator.installReplacement(
                    next.replacement,
                    invocation: invocation
                )
            }
            lock.withLock {
                precondition(preparingBundle === next, "replacement bundle owner 不匹配")
                bundle = next
                preparingBundle = nil
                latestReceipt = nil
            }
            _ = try await coordinator.prepareCurrentItem(invocation: invocation)
        } catch {
            _ = await next.retireProducerGraph()
            lock.withLock {
                if bundle === next { bundle = nil }
                if preparingBundle === next { preparingBundle = nil }
                latestReceipt = nil
            }
            throw error
        }
    }

    func activateOutput(
        invocation: ControlTaskRegistry.BackendPositiveRateInvocation
    ) async throws {
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
            if !preservesCoordinator { self.activationTime = nil }
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.append("cap_hls_retire_confirmed")
        #endif
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
            let itemGeneration = lock.withLock { bundle?.itemGeneration ?? 0 }
            let summary = String(
                format: "avplayer:gen=%llu,tc=%@,item=%@,rate=%.3f,buffer=%.3f,empty=%d,keepUp=%d,access=%d,errorLog=%d,error=%@",
                itemGeneration,
                timeControlStatus,
                itemStatus,
                player.rate,
                bufferedAhead,
                item?.isPlaybackBufferEmpty == true ? 1 : 0,
                item?.isPlaybackLikelyToKeepUp == true ? 1 : 0,
                item?.accessLog()?.events.count ?? 0,
                item?.errorLog()?.events.count ?? 0,
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
                retainedAudioCount: item?.accessLog()?.events.count ?? 0,
                retainedVideoCount: item?.errorLog()?.events.count ?? 0,
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
