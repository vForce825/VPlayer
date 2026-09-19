// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 生产 delivery authority 的窄端口。实现者必须由同一 writer/publisher/store/server
/// 图签发 prefix 与 retirement receipt；此协议不提供 Bool readiness 或伪造 endpoint 的
/// 默认实现，防止新的系统 builder 悄悄降级为测试图。
protocol SystemHLSDeliveryGraphAuthority: AnyObject, Sendable {
    func append(_ event: AdmittedDemuxEvent)
    func awaitAllTrackPlayablePrefix(minimumSeconds: Int) async -> AVPlayerItemReplacementBundle?
    func finishAllTracksAtNaturalEOF() async -> Bool
    func retireAllResourcesAndAwaitReceipt() async -> Bool
}

/// 把唯一 demux 的 admitted event 串到真实 delivery authority。它不拥有第二个队列、
/// source 或 player，因此 progressive remux 与 interlaced YADIF2x→VT、compressed/PCM→AAC
/// 分支只能在同一 authority 内汇入同一 SegmentedFMP4Writer/publisher/store/server。
final class SystemHLSDeliveryGraph: HLSMediaGraphAssembler.DeliveryGraph, @unchecked Sendable {
    private let authority: any SystemHLSDeliveryGraphAuthority

    init(authority: any SystemHLSDeliveryGraphAuthority) { self.authority = authority }

    func accept(_ event: AdmittedDemuxEvent) { authority.append(event) }

    func waitUntilPlayablePrefix() async -> HLSMediaGraphAssembler.HLSMediaGraphPlayablePrefix? {
        guard let replacement = await authority.awaitAllTrackPlayablePrefix(minimumSeconds: 3) else {
            return nil
        }
        return .init(replacement: replacement)
    }

    func finishNaturalEOF() async -> Bool {
        await authority.finishAllTracksAtNaturalEOF()
    }

    func retireAndAwaitReceipt() async -> Bool {
        await authority.retireAllResourcesAndAwaitReceipt()
    }
}

/// 单一 source 到 HLS delivery 图的受限生产编排器。它只拥有一个 `FFmpegDemuxer`；
/// packet 的真实 materialization 由已绑定的 writer/publisher/store/server graph 处理，不能由
/// AVPlayer 或第二个 source 重新读取节目 URL。
final class HLSMediaGraphAssembler: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case configured
        case reading
        case playable
        case finishing
        case retired
        case failed
    }

    /// graph endpoint 只接受带 admission tail 的 demux event。实现者必须把 video/audio
    /// packet 交给既有 progressive remux、YADIF2x→VT、compressed 或 PCM→AAC writer 路径，
    /// 并只在全部 selected track 的真实 publication 覆盖达到三秒时签发 prefix receipt。
    protocol DeliveryGraph: AnyObject, Sendable {
        func accept(_ event: AdmittedDemuxEvent)
        func waitUntilPlayablePrefix() async -> HLSMediaGraphPlayablePrefix?
        func finishNaturalEOF() async -> Bool
        func retireAndAwaitReceipt() async -> Bool
    }

    /// 不可由外部构造的 prefix capability；它绑定同一个 server/evidence replacement，禁止
    /// 以 Bool、空 playlist 或另一个 server 代替真实 all-track playable prefix。
    final class HLSMediaGraphPlayablePrefix: @unchecked Sendable {
        let replacement: AVPlayerItemReplacementBundle
        init(replacement: AVPlayerItemReplacementBundle) {
            self.replacement = replacement
        }
    }

    private let sourceURL: URL
    private let demuxer: FFmpegDemuxer
    private let admission: HLSDataPlaneAdmission
    private let graph: any DeliveryGraph
    private let condition = NSCondition()
    private var phase: Phase = .configured
    private var prefix: HLSMediaGraphPlayablePrefix?
    private var retirement: Task<Bool, Never>?

    init(sourceURL: URL,
         applicationLedger: HLSDeliveryApplicationChargeLedger,
         demuxer: FFmpegDemuxer = FFmpegDemuxer(),
         graph: any DeliveryGraph) {
        self.sourceURL = sourceURL
        self.demuxer = demuxer
        admission = HLSDataPlaneAdmission(capacity: 256, maximumBytes: 64 * 1_024 * 1_024,
                                           applicationLedger: applicationLedger)
        self.graph = graph
    }

    var currentPhase: Phase { condition.withLock { phase } }

    /// 启动唯一 demux source 并等待真实 graph 签发 all-track prefix；没有 receipt 就不暴露
    /// replacement，故 server/item install 不能越过三秒真实覆盖 readiness。
    func startUntilPlayablePrefix() async throws -> AVPlayerItemReplacementBundle {
        let mayStart = condition.withLock { () -> Bool in
            guard phase == .configured else { return false }
            phase = .reading
            return true
        }
        guard mayStart else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        do {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("assembler_demux_start")
            #endif
            try demuxer.start(url: sourceURL, admission: admission) { [weak self] event in
                self?.route(event)
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("assembler_demux_started")
            #endif
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("assembler_demux_fail")
            #endif
            condition.withLock { phase = .failed }
            _ = await retireAndAwaitReceipt()
            throw error
        }
        // graph 的 prefix 必须来自 writer/publisher/store/server 的完成证据；此 await 没有
        // 以计时器或 packet 计数替代真实 publication receipt。
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("assembler_wait_prefix")
        #endif
        guard let prefix = await graph.waitUntilPlayablePrefix() else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("assembler_prefix_nil")
            #endif
            condition.withLock { phase = .failed }
            _ = await retireAndAwaitReceipt()
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("assembler_prefix_ready")
        #endif
        condition.withLock {
            self.prefix = prefix
            phase = .playable
        }
        return prefix.replacement
    }

    /// 自然 EOF 已由 route 交给同一 graph；该入口只允许 graph 完成 video/audio drain、writer
    /// finish 与 ENDLIST 后返回，与取消 retirement 分离。
    func finishAtNaturalEOF() async throws {
        let mayFinish = condition.withLock { () -> Bool in
            guard phase == .reading || phase == .playable else { return false }
            phase = .finishing
            return true
        }
        guard mayFinish else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        guard await graph.finishNaturalEOF() else {
            condition.withLock { phase = .failed }
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        condition.withLock { phase = .playable }
    }

    func retireAndAwaitReceipt() async -> Bool {
        let task = condition.withLock { () -> Task<Bool, Never> in
            if let retirement { return retirement }
            admission.cancel()
            demuxer.cancel()
            let graph = self.graph
            let task = Task { await graph.retireAndAwaitReceipt() }
            retirement = task
            return task
        }
        let confirmed = await task.value
        condition.withLock { phase = confirmed ? .retired : .failed }
        return confirmed
    }

    private func route(_ event: AdmittedDemuxEvent) {
        // DeliveryGraph 持有实际 writer/publisher/store/server authority；event 的 admission
        // tail 由它随下游 alias 移交，不能在这个同步回调后把裸 packet 存进第二个队列。
        graph.accept(event)
    }
}
