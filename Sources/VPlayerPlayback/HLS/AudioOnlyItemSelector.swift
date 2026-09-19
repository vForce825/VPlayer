// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum AudioOnlySelectedRendition: Sendable, Hashable {
    case compressedFidelity
    case fidelityAAC
    case compatibilityStereo(reason: AudioOnlyStereoFallbackReason)

    static var compressed: AudioOnlySelectedRendition { .compressedFidelity }
}

enum AudioOnlyStereoFallbackReason: String, Sendable, Hashable {
    case probeFailed
    case probeTimedOut
    case skippedForOuterBudget
}

enum AudioOnlyCandidateKind: Sendable, Hashable {
    case compressed
    case fidelityAAC
    case compatibilityStereo
}

struct AudioOnlySelectionTransaction: Sendable, Hashable {
    let prepareTicketIdentity: UUID
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let audioAdmissionFenceRevision: UInt64
    let selectionNonce: UUID

    init(
        prepareTicketIdentity: UUID = UUID(),
        outputLifecycleEpoch: OutputLifecycleEpoch,
        audioAdmissionFenceRevision: UInt64 = 1,
        selectionNonce: UUID = UUID()
    ) {
        self.prepareTicketIdentity = prepareTicketIdentity
        self.outputLifecycleEpoch = outputLifecycleEpoch
        self.audioAdmissionFenceRevision = audioAdmissionFenceRevision
        self.selectionNonce = selectionNonce
    }
}

struct AudioOnlyCandidateTicket: Sendable, Hashable {
    let selectionTransactionIdentity: UUID
    let itemGeneration: UInt64
    let candidateOrdinal: Int
    let candidateKind: AudioOnlyCandidateKind
    let renditionIdentity: AudioRenditionIdentity

    init(
        selectionTransactionIdentity: UUID,
        itemGeneration: UInt64,
        candidateOrdinal: Int,
        candidateKind: AudioOnlyCandidateKind,
        renditionIdentity: AudioRenditionIdentity
    ) {
        self.selectionTransactionIdentity = selectionTransactionIdentity
        self.itemGeneration = itemGeneration
        self.candidateOrdinal = candidateOrdinal
        self.candidateKind = candidateKind
        self.renditionIdentity = renditionIdentity
    }
}

enum CandidateCleanupReason: Sendable, Hashable {
    case probeFailed
    case probeTimedOut
    case skippedForOuterBudget
    case loserUnselected
    case invalidation
}

struct CandidateCleanupTicket: Sendable, Hashable {
    let candidateTicket: AudioOnlyCandidateTicket
    let reason: CandidateCleanupReason
    let nonce: UUID

    init(
        candidateTicket: AudioOnlyCandidateTicket,
        reason: CandidateCleanupReason,
        nonce: UUID = UUID()
    ) {
        self.candidateTicket = candidateTicket
        self.reason = reason
        self.nonce = nonce
    }
}

enum AudioOnlySelectionFailure: Error, Sendable, Equatable {
    case noCandidates
    case insufficientOuterBudget
    case cleanupTimedOut(ordinal: Int)
    case invalidPhaseTransition
    case allCandidatesFailed
    case missingDirectMediaItem
}

struct AudioOnlySelectionResult: Sendable {
    let selectedBundle: AudioOnlyCandidateBundle
    let selectedRendition: AudioOnlySelectedRendition
    let diagnostic: String?
}

struct AudioOnlySourceProfile: Sendable, Hashable {
    let codec: AudioCodec
    let channelCount: Int
    let sampleRate: Int32
    let bitrate: Int
    let supportsCompressedFidelity: Bool

    init(
        codec: AudioCodec,
        channelCount: Int,
        sampleRate: Int32 = 48_000,
        bitrate: Int = 160_000,
        supportsCompressedFidelity: Bool = true
    ) {
        self.codec = codec
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.supportsCompressedFidelity = supportsCompressedFidelity
    }
}

/// audio-only 串行候选选择器。
/// 候选评估顺序：
/// 1. 同声道压缩（AC-3 / E-AC-3）保真候选
/// 2. 同声道 AAC-LC 保真候选
/// 3. 立体声 AAC-LC 兼容候选（源立体声时去重）
///
/// 约束：
/// - 探针超时 5 秒，清理超时 1 秒。
/// - 同一时刻最多 1 个候选进行 probe。
/// - 外层后缀判定：非末候选外层剩余须 >= 6 + mandatorySuffix，末候选须 >= 8 秒。
///   (3 候选链分别为 20s、14s、8s)。
/// - 清理超时立即升级终态，禁止后继绕过。
/// - 保真失败不能伪装成路由只支持立体声，回退时输出明确的 compatibilityStereo 诊断。
final class AudioOnlyItemSelector: @unchecked Sendable {
    static let postSelectionProgressReserveSeconds: TimeInterval = 3.0

    let transaction: AudioOnlySelectionTransaction
    let candidates: [AudioOnlyCandidateBundle]

    private let lock = NSLock()
    private var outerBudgetProvider: @Sendable () -> TimeInterval
    private var diagnosticSink: (@Sendable (String) -> Void)?

    private var maxConcurrentProbes = 0
    private var activeProbes = 0

    init(
        transaction: AudioOnlySelectionTransaction,
        candidates: [AudioOnlyCandidateBundle],
        outerBudgetProvider: @escaping @Sendable () -> TimeInterval = { 45.0 },
        diagnosticSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.transaction = transaction
        self.candidates = candidates
        self.outerBudgetProvider = outerBudgetProvider
        self.diagnosticSink = diagnosticSink
    }

    /// 生产候选列表工厂：严格按同声道压缩 -> 同声道 AAC -> 立体声兼容顺序构造，并在源为立体声时去重。
    static func buildCandidates(
        sourceProfile: AudioOnlySourceProfile,
        transaction: AudioOnlySelectionTransaction,
        baseURL: URL = URL(string: "http://127.0.0.1:19023/audio")!,
        fencesFactory: (@Sendable (AudioOnlyCandidateKind, Int) -> CandidateBranchDrainFences)? = nil,
        replacementFactory: (@Sendable (AudioOnlyCandidateKind, Int, URL) -> AVPlayerItemReplacementBundle?)? = nil,
        probeAction: (@Sendable (AudioOnlyCandidateKind, TimeInterval) async throws -> Bool)? = nil,
        cleanupAction: (@Sendable (AudioOnlyCandidateKind, CandidateCleanupReason, TimeInterval) async -> Bool)? = nil
    ) -> [AudioOnlyCandidateBundle] {
        var bundles: [AudioOnlyCandidateBundle] = []
        var ordinal = 0

        // 1. 同声道压缩保真候选（AC-3 / E-AC-3）
        if sourceProfile.supportsCompressedFidelity {
            let ticket = AudioOnlyCandidateTicket(
                selectionTransactionIdentity: transaction.selectionNonce,
                itemGeneration: 1001,
                candidateOrdinal: ordinal,
                candidateKind: .compressed,
                renditionIdentity: AudioRenditionIdentity(rawValue: 10)
            )
            let fences = fencesFactory?(ticket.candidateKind, ordinal) ?? CandidateBranchDrainFences()
            let url = baseURL.appending(path: "compressed/index.m3u8")
            let bundleProbe: (@Sendable (TimeInterval) async throws -> Bool)?
            if let probeAction {
                bundleProbe = { @Sendable timeout in try await probeAction(.compressed, timeout) }
            } else {
                bundleProbe = nil
            }
            let bundleCleanup: (@Sendable (CandidateCleanupReason, TimeInterval) async -> Bool)?
            if let cleanupAction {
                bundleCleanup = { @Sendable reason, timeout in await cleanupAction(.compressed, reason, timeout) }
            } else {
                bundleCleanup = nil
            }
            let bundleReplacement: AVPlayerItemReplacementBundle? = replacementFactory?(.compressed, ordinal, url)
            let bundle = AudioOnlyCandidateBundle(
                candidateTicket: ticket,
                renditionKind: .compressed,
                mediaPlaylistURL: url,
                fences: fences,
                semanticCoordinator: nil,
                replacement: bundleReplacement,
                probeAction: bundleProbe,
                cleanupAction: bundleCleanup
            )
            bundles.append(bundle)
            ordinal += 1
        }

        // 2. 同声道 AAC-LC 保真候选
        let fidelityTicket = AudioOnlyCandidateTicket(
            selectionTransactionIdentity: transaction.selectionNonce,
            itemGeneration: 1002,
            candidateOrdinal: ordinal,
            candidateKind: .fidelityAAC,
            renditionIdentity: AudioRenditionIdentity(rawValue: 20)
        )
        let fidelityFences = fencesFactory?(fidelityTicket.candidateKind, ordinal) ?? CandidateBranchDrainFences()
        let fidelityURL = baseURL.appending(path: "fidelity-aac/index.m3u8")
        let fidelityProbe: (@Sendable (TimeInterval) async throws -> Bool)?
        if let probeAction {
            fidelityProbe = { @Sendable timeout in try await probeAction(.fidelityAAC, timeout) }
        } else {
            fidelityProbe = nil
        }
        let fidelityCleanup: (@Sendable (CandidateCleanupReason, TimeInterval) async -> Bool)?
        if let cleanupAction {
            fidelityCleanup = { @Sendable reason, timeout in await cleanupAction(.fidelityAAC, reason, timeout) }
        } else {
            fidelityCleanup = nil
        }
        let fidelityReplacement: AVPlayerItemReplacementBundle? = replacementFactory?(.fidelityAAC, ordinal, fidelityURL)
        let fidelityBundle = AudioOnlyCandidateBundle(
            candidateTicket: fidelityTicket,
            renditionKind: .fidelityAAC,
            mediaPlaylistURL: fidelityURL,
            fences: fidelityFences,
            semanticCoordinator: nil,
            replacement: fidelityReplacement,
            probeAction: fidelityProbe,
            cleanupAction: fidelityCleanup
        )
        bundles.append(fidelityBundle)
        ordinal += 1

        // 3. 立体声 AAC-LC 兼容候选（源立体声时去重）
        if sourceProfile.channelCount != 2 {
            let stereoTicket = AudioOnlyCandidateTicket(
                selectionTransactionIdentity: transaction.selectionNonce,
                itemGeneration: 1003,
                candidateOrdinal: ordinal,
                candidateKind: .compatibilityStereo,
                renditionIdentity: AudioRenditionIdentity(rawValue: 30)
            )
            let stereoFences = fencesFactory?(stereoTicket.candidateKind, ordinal) ?? CandidateBranchDrainFences()
            let stereoURL = baseURL.appending(path: "stereo-compatibility/index.m3u8")
            let stereoProbe: (@Sendable (TimeInterval) async throws -> Bool)?
            if let probeAction {
                stereoProbe = { @Sendable timeout in try await probeAction(.compatibilityStereo, timeout) }
            } else {
                stereoProbe = nil
            }
            let stereoCleanup: (@Sendable (CandidateCleanupReason, TimeInterval) async -> Bool)?
            if let cleanupAction {
                stereoCleanup = { @Sendable reason, timeout in await cleanupAction(.compatibilityStereo, reason, timeout) }
            } else {
                stereoCleanup = nil
            }
            let stereoReplacement: AVPlayerItemReplacementBundle? = replacementFactory?(.compatibilityStereo, ordinal, stereoURL)
            let stereoBundle = AudioOnlyCandidateBundle(
                candidateTicket: stereoTicket,
                renditionKind: .compatibilityStereo,
                mediaPlaylistURL: stereoURL,
                fences: stereoFences,
                semanticCoordinator: nil,
                replacement: stereoReplacement,
                probeAction: stereoProbe,
                cleanupAction: stereoCleanup
            )
            bundles.append(stereoBundle)
            ordinal += 1
        }

        return bundles
    }

    var maximumConcurrentProbes: Int {
        lock.withLock { maxConcurrentProbes }
    }

    func setOuterBudgetProvider(_ provider: @escaping @Sendable () -> TimeInterval) {
        lock.withLock { outerBudgetProvider = provider }
    }

    func select() async throws -> AudioOnlySelectionResult {
        guard !candidates.isEmpty else {
            throw AudioOnlySelectionFailure.noCandidates
        }

        var fidelityFailureReason: AudioOnlyStereoFallbackReason? = nil

        for (index, candidate) in candidates.enumerated() {
            let m = candidates.count - 1 - index
            let currentBudget = lock.withLock { outerBudgetProvider() }

            // 外层预算后缀判定：复用 PlaybackDeadlineBudget 计算所需纳秒并转换为秒
            let requiredNanoseconds: UInt64
            do {
                requiredNanoseconds = try PlaybackDeadlineBudget.audioOnlyCandidateAdmission(
                    laterCandidateCount: UInt64(m)
                )
            } catch {
                throw AudioOnlySelectionFailure.insufficientOuterBudget
            }
            let requiredBudget = Double(requiredNanoseconds) / 1_000_000_000.0

            if m == 0 {
                // 末候选：至少需要 8 秒 (5s probe + 3s progress reserve)
                if currentBudget < requiredBudget {
                    if candidate.renditionKind == .compatibilityStereo, fidelityFailureReason == nil {
                        fidelityFailureReason = .skippedForOuterBudget
                    }
                    throw AudioOnlySelectionFailure.insufficientOuterBudget
                }
            } else {
                // 非末候选：至少需要 requiredBudget (6*m + 8 秒)
                if currentBudget < requiredBudget {
                    if candidate.renditionKind == .fidelityAAC {
                        fidelityFailureReason = .skippedForOuterBudget
                    }
                    let cleanupOk = await candidate.cleanup(reason: .skippedForOuterBudget, timeout: 1.0)
                    if !cleanupOk {
                        throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: candidate.candidateTicket.candidateOrdinal)
                    }
                    continue
                }
            }

            // 检查 6/7 段门槛
            guard candidate.isPlayablePrefixReady else {
                if candidate.renditionKind == .fidelityAAC {
                    fidelityFailureReason = .probeFailed
                }
                let cleanupOk = await candidate.cleanup(reason: .probeFailed, timeout: 1.0)
                if !cleanupOk {
                    throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: candidate.candidateTicket.candidateOrdinal)
                }
                continue
            }

            // 串行探测门禁
            lock.withLock {
                activeProbes += 1
                maxConcurrentProbes = max(maxConcurrentProbes, activeProbes)
            }

            var probeResult: Result<Bool, Error>
            do {
                let success = try await candidate.probe(timeout: 5.0)
                probeResult = .success(success)
            } catch {
                probeResult = .failure(error)
            }

            lock.withLock {
                activeProbes -= 1
            }

            switch probeResult {
            case .success(true):
                // 验证 post-selection progress reserve budget >= 3.0s (Spec 7.5)
                let remainingBudget = lock.withLock { outerBudgetProvider() }
                guard remainingBudget >= Self.postSelectionProgressReserveSeconds else {
                    let cleanupOk = await candidate.cleanup(reason: .skippedForOuterBudget, timeout: 1.0)
                    if !cleanupOk {
                        throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: candidate.candidateTicket.candidateOrdinal)
                    }
                    throw AudioOnlySelectionFailure.insufficientOuterBudget
                }

                // 探测成功且预留预算充足，选定胜者
                try candidate.commit()

                // 确定选定格式及诊断
                let selectedRendition: AudioOnlySelectedRendition
                var diagnosticMessage: String? = nil

                switch candidate.renditionKind {
                case .compressed:
                    selectedRendition = .compressedFidelity
                case .fidelityAAC:
                    selectedRendition = .fidelityAAC
                case .compatibilityStereo:
                    let reason = fidelityFailureReason ?? .probeFailed
                    selectedRendition = .compatibilityStereo(reason: reason)
                    let msg = "compatibilityStereo: fallback from fidelity due to \(reason.rawValue)"
                    diagnosticMessage = msg
                    diagnosticSink?(msg)
                }

                // 并发清理全部失败者 / 未选中候选
                var loserCleanupTimedOutOrdinal: Int? = nil
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for other in candidates where other !== candidate {
                        group.addTask {
                            let ok = await other.cleanup(reason: .loserUnselected, timeout: 1.0)
                            return (other.candidateTicket.candidateOrdinal, ok)
                        }
                    }
                    for await (ordinal, ok) in group {
                        if !ok && loserCleanupTimedOutOrdinal == nil {
                            loserCleanupTimedOutOrdinal = ordinal
                        }
                    }
                }
                if let loserOrdinal = loserCleanupTimedOutOrdinal {
                    throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: loserOrdinal)
                }

                return AudioOnlySelectionResult(
                    selectedBundle: candidate,
                    selectedRendition: selectedRendition,
                    diagnostic: diagnosticMessage
                )

            case .success(false):
                // 探测失败
                if candidate.renditionKind == .fidelityAAC {
                    fidelityFailureReason = .probeFailed
                }
                let cleanupOk = await candidate.cleanup(reason: .probeFailed, timeout: 1.0)
                if !cleanupOk {
                    throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: candidate.candidateTicket.candidateOrdinal)
                }

            case .failure(let error):
                let reason: AudioOnlyStereoFallbackReason
                if let probeError = error as? AudioOnlyProbeError, probeError == .timedOut {
                    reason = .probeTimedOut
                } else {
                    reason = .probeFailed
                }
                if candidate.renditionKind == .fidelityAAC {
                    fidelityFailureReason = reason
                }
                let cleanupOk = await candidate.cleanup(reason: reason == .probeTimedOut ? .probeTimedOut : .probeFailed, timeout: 1.0)
                if !cleanupOk {
                    throw AudioOnlySelectionFailure.cleanupTimedOut(ordinal: candidate.candidateTicket.candidateOrdinal)
                }
            }
        }

        throw AudioOnlySelectionFailure.allCandidatesFailed
    }
}
