// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

/// audio-only 的每个候选是专门化的 bundle，拥有 direct media-playlist item 和对应 audio data plane。
/// 拥有独立的所有权单元，不等待视频 IDR，不建立 video/Metal/VT/master 资源。
/// loser cleanup 仅关闭自己的 compressed/PCM 订阅，不碰共享 decoder。
final class AudioOnlyCandidateBundle: @unchecked Sendable {

    enum Phase: Sendable, Equatable {
        case materializing
        case standby
        case probing
        case committed
        case cleaning(CandidateCleanupTicket)
        case retired
    }

    let candidateTicket: AudioOnlyCandidateTicket
    let renditionKind: AudioOnlyCandidateKind
    let mediaPlaylistURL: URL
    let fences: CandidateBranchDrainFences
    let replacement: AVPlayerItemReplacementBundle?

    private let lock = NSLock()
    private weak var semanticCoordinator: AudioServiceSemanticCoordinator?
    private var phase: Phase = .materializing
    private var prefixReady: Bool = true
    private var probed = false
    private var probeFailureInjected = false
    private var probeTimeoutInjected = false
    private var cleanupTimeoutInjected = false
    private let probeAction: (@Sendable (TimeInterval) async throws -> Bool)?
    private let cleanupAction: (@Sendable (CandidateCleanupReason, TimeInterval) async -> Bool)?

    init(
        candidateTicket: AudioOnlyCandidateTicket,
        renditionKind: AudioOnlyCandidateKind,
        mediaPlaylistURL: URL,
        fences: CandidateBranchDrainFences = CandidateBranchDrainFences(),
        semanticCoordinator: AudioServiceSemanticCoordinator? = nil,
        replacement: AVPlayerItemReplacementBundle? = nil,
        probeAction: (@Sendable (TimeInterval) async throws -> Bool)? = nil,
        cleanupAction: (@Sendable (CandidateCleanupReason, TimeInterval) async -> Bool)? = nil
    ) {
        self.candidateTicket = candidateTicket
        self.renditionKind = renditionKind
        self.mediaPlaylistURL = mediaPlaylistURL
        self.fences = fences
        self.semanticCoordinator = semanticCoordinator
        self.replacement = replacement
        self.probeAction = probeAction
        self.cleanupAction = cleanupAction
    }

    func attachSemanticCoordinator(_ coordinator: AudioServiceSemanticCoordinator) {
        lock.withLock {
            semanticCoordinator = coordinator
        }
    }

    var currentPhase: Phase {
        lock.withLock { phase }
    }

    /// 音频候选绝不创建视频相关资源。
    var videoResourceCount: Int { 0 }

    /// audio-only 直接输出单 rendition media playlist，绝不创建 master playlist。
    var masterPlaylistCount: Int { 0 }

    var isPlayablePrefixReady: Bool {
        get { lock.withLock { prefixReady } }
        set { lock.withLock { prefixReady = newValue } }
    }

    var wasProbed: Bool {
        lock.withLock { probed }
    }

    func injectProbeFailure() {
        lock.withLock { probeFailureInjected = true }
    }

    func injectProbeTimeout() {
        lock.withLock { probeTimeoutInjected = true }
    }

    func injectCleanupTimeout() {
        lock.withLock { cleanupTimeoutInjected = true }
    }

    /// 标记物化就绪，进入 standby 状态。
    func markStandbyIfPrefixReady() -> Bool {
        lock.withLock {
            guard phase == .materializing, prefixReady else { return false }
            phase = .standby
            return true
        }
    }

    /// 串行探测。限时 5.0 秒，验证 readyToPlay、init/segment 请求及 3 秒缓冲。
    func probe(timeout: TimeInterval = 5.0) async throws -> Bool {
        let shouldProbe = lock.withLock { () -> Bool in
            guard phase == .standby || phase == .materializing else { return false }
            phase = .probing
            probed = true
            return true
        }
        guard shouldProbe else { return false }

        if let probeAction {
            let result = try await probeAction(timeout)
            if !result {
                return false
            }
        }

        let (failed, timedOut) = lock.withLock {
            (probeFailureInjected, probeTimeoutInjected)
        }

        if timedOut {
            throw AudioOnlyProbeError.timedOut
        }
        if failed {
            return false
        }
        return true
    }

    /// 提交获胜候选。
    func commit() throws {
        try lock.withLock {
            guard phase == .probing else {
                throw AudioOnlySelectionFailure.invalidPhaseTransition
            }
            phase = .committed
        }
    }

    /// 清理候选。限时 1.0 秒。
    /// loser cleanup 仅关闭自己的 compressed/PCM 订阅，排空 fence；
    /// committed 胜出候选在后端退役/失效时也正常清理并退役。
    func cleanup(reason: CandidateCleanupReason, timeout: TimeInterval = 1.0) async -> Bool {
        let ticket = lock.withLock { () -> CandidateCleanupTicket? in
            guard phase != .retired else { return nil }
            if case .cleaning = phase { return nil }
            let ticket = CandidateCleanupTicket(
                candidateTicket: candidateTicket,
                reason: reason,
                nonce: UUID()
            )
            phase = .cleaning(ticket)
            return ticket
        }
        guard ticket != nil else {
            return lock.withLock { phase == .retired }
        }

        let isCleanupTimeout = lock.withLock { cleanupTimeoutInjected }
        if isCleanupTimeout {
            // 清理超时，旧 generation 无法安全退休
            return false
        }

        if let cleanupAction {
            let ok = await cleanupAction(reason, timeout)
            if !ok { return false }
        }

        // Retire underlying drain fences
        let coordinator = lock.withLock { semanticCoordinator }
        _ = fences.retire(semantic: coordinator)

        lock.withLock {
            phase = .retired
        }
        return true
    }
}

enum AudioOnlyProbeError: Error, Sendable, Equatable {
    case timedOut
    case failed
}
