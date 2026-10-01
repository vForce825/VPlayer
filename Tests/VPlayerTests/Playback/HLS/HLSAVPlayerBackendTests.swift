// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
import Network
import VPlayerCore
@testable import VPlayerPlayback

/// Task22-F 的 production 装配边界。整图 fixture 由 root runner 在模拟器上执行；这里先
/// 固定系统 builder 不能接受第二条 source 或脱离同一 lifecycle 的 graph authority。
final class HLSAVPlayerBackendTests: XCTestCase {
    func testNestedTranscodeFailuresKeepOriginalDiagnosticWithoutRewrapping() {
        let original = ErrorDiagnosticSnapshot(NSError(domain: "HLS.Transcode.Native", code: -93,
            userInfo: [NSLocalizedDescriptionKey: String(repeating: "原始原因", count: 80)]))
        let failures: [any Error] = [
            HLSVideoTranscodeBranchFailure.encoder(.unexpected(original)),
            HLSVideoTranscodeBranchFailure.invalidFrame(.unexpected(original)),
            HLSVideoTranscodeBranchFailure.decoder(.unexpected(original)),
            PlaybackCoreError.videoDecoderFailure(.unexpected(original))
        ]
        for failure in failures {
            XCTAssertEqual(PlaybackErrorDiagnostics.snapshot(failure), original)
        }
    }

    func testKnownTranscodeFailureWrappersRemainDistinct() {
        let encoder = PlaybackErrorDiagnostics.snapshot(HLSVideoTranscodeBranchFailure.encoder(.arithmeticOverflow))
        let frame = PlaybackErrorDiagnostics.snapshot(HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow))
        XCTAssertNotEqual(encoder, frame)
        XCTAssertTrue(encoder.summary.contains("encoder("), encoder.summary)
        XCTAssertTrue(frame.summary.contains("invalidFrame("), frame.summary)
    }

    func testPublicationFirstFailureRetainsDiagnosticsWithoutRetainingOriginalError() throws {
        let publication = try SystemHLSPublicationGraph(itemGeneration: 99)
        weak var originalReference: NSError?
        autoreleasepool {
            let original = NSError(domain: "HLS.Publication.Native", code: -12,
                userInfo: [NSLocalizedDescriptionKey: "首个发布异常"])
            originalReference = original
            publication.recordFailure(original)
        }
        XCTAssertNil(originalReference, "发布持久终态只能保存固定容量快照")
        publication.recordFailure(NSError(domain: "HLS.Secondary", code: -13,
            userInfo: [NSLocalizedDescriptionKey: "清理期间后继异常"]))
        XCTAssertThrowsError(try publication.waitForVisible(until: Date())) { error in
            let description = String(reflecting: error)
            XCTAssertTrue(description.contains("HLS.Publication.Native"), description)
            XCTAssertTrue(description.contains("-12"), description)
            XCTAssertTrue(description.contains("首个发布异常"), description)
            XCTAssertFalse(description.contains("HLS.Secondary"), description)
        }
    }

    func testPrefixFailurePreservesOriginalGraphErrorAfterRetirement() async throws {
        let authority = ErrorReportingHLSGraphAuthority()
        let assembler = HLSMediaGraphAssembler(
            sourceURL: URL(string: "http://example.test/source.ts")!,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(bridge: EmptyHLSFailureDemuxBridge()),
            graph: SystemHLSDeliveryGraph(authority: authority))
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            XCTFail("媒体图失败不能签发可播前缀")
        } catch {
            let description = String(reflecting: error)
            XCTAssertTrue(description.contains("HLS.AudioCalibration"), description)
            XCTAssertTrue(description.contains("-50"), description)
            XCTAssertTrue(description.contains("AAC 校准首错"), description)
        }
        XCTAssertEqual(assembler.currentPhase, .retired)
    }

    func testSystemLoopbackClockPreservesMonotonicNanoseconds() {
        XCTAssertEqual(
            SystemHLSLoopbackClock.nanoseconds(uptimeNanoseconds: 1_234_567_890),
            1_234_567_890
        )
        XCTAssertEqual(
            SystemHLSLoopbackClock.nanoseconds(uptimeNanoseconds: UInt64.max),
            Int64.max,
            "超出 Int64 的单调时钟只能饱和，不能回绕到负数"
        )
    }

    func testPrepareRetryRequiresFirstRetiredProducerAndNoPlayerInstallation() {
        XCTAssertTrue(HLSPrepareRetryPolicy.shouldRetry(
            completedAttemptCount: 1,
            maximumAttemptCount: 2,
            producerRetirementConfirmed: true,
            playerInstallationAttempted: false))
        XCTAssertFalse(HLSPrepareRetryPolicy.shouldRetry(
            completedAttemptCount: 2,
            maximumAttemptCount: 2,
            producerRetirementConfirmed: true,
            playerInstallationAttempted: false))
        XCTAssertFalse(HLSPrepareRetryPolicy.shouldRetry(
            completedAttemptCount: 1,
            maximumAttemptCount: 2,
            producerRetirementConfirmed: false,
            playerInstallationAttempted: false))
        XCTAssertFalse(HLSPrepareRetryPolicy.shouldRetry(
            completedAttemptCount: 1,
            maximumAttemptCount: 2,
            producerRetirementConfirmed: true,
            playerInstallationAttempted: true))
    }

    func testProgressiveGraphDrainsPendingAudioBeforeAdvancingVideoBoundary() throws {
        let previousVideoPTS = CMTime(value: 12, timescale: 1)

        XCTAssertEqual(
            HLSMediaGraphAudioDrainPolicy.drainBeforeVideo(
                pendingAudioCount: 24,
                hasAudioBranch: true,
                hasInterlacedVideoBranch: false,
                previousVideoPTS: previousVideoPTS),
            previousVideoPTS)
        XCTAssertNil(HLSMediaGraphAudioDrainPolicy.drainBeforeVideo(
            pendingAudioCount: 0,
            hasAudioBranch: true,
            hasInterlacedVideoBranch: false,
            previousVideoPTS: previousVideoPTS))
        XCTAssertNil(HLSMediaGraphAudioDrainPolicy.drainBeforeVideo(
            pendingAudioCount: 24,
            hasAudioBranch: true,
            hasInterlacedVideoBranch: true,
            previousVideoPTS: previousVideoPTS),
            "隔行分支必须继续由 writtenThrough 证明安全音频终点")
    }

    func testInterlacedGraphDrainsAudioAtEveryWrittenOutputSafePoint() throws {
        let writtenThrough = CMTime(value: 12, timescale: 1)

        XCTAssertNil(
            HLSMediaGraphAudioDrainPolicy.interlacedMaximumCount,
            "视频 writer 已协作暂停时，音频必须一次追到安全终点，不能再限 8 个输入块"
        )

        XCTAssertEqual(
            HLSMediaGraphAudioDrainPolicy.drainBehindInterlacedVideo(
                pendingAudioCount: 24,
                writtenThrough: writtenThrough,
                trigger: .videoSampleSubmitted),
            CMTime(value: 11, timescale: 1),
            "输出队列进入 rollover 后仍必须以已写视频时刻驱动音频追平"
        )
        XCTAssertEqual(
            HLSMediaGraphAudioDrainPolicy.drainBehindInterlacedVideo(
                pendingAudioCount: 24,
                writtenThrough: writtenThrough,
                trigger: .audioSampleQueued),
            CMTime(value: 11, timescale: 1),
            "TS 音频晚于视频到达时，也必须立即复用现有视频安全点追平"
        )
        XCTAssertNil(HLSMediaGraphAudioDrainPolicy.drainBehindInterlacedVideo(
            pendingAudioCount: 0,
            writtenThrough: writtenThrough,
            trigger: .audioSampleQueued))
        XCTAssertNil(HLSMediaGraphAudioDrainPolicy.drainBehindInterlacedVideo(
            pendingAudioCount: 24,
            writtenThrough: nil,
            trigger: .videoSampleSubmitted))
    }

    func testInterlacedVideoStopsBeforePublicationReachesEightSegmentBacklog() {
        XCTAssertTrue(HLSInterlacedVideoLeadPolicy.canAdvance(
            videoOffset: 23,
            audioNextBoundaryOffsets: [18]
        ), "视频领先已提交音频 6 段时仍可推进")
        XCTAssertFalse(HLSInterlacedVideoLeadPolicy.canAdvance(
            videoOffset: 24,
            audioNextBoundaryOffsets: [18]
        ), "当前领先 7 段时必须暂停，不能让下一视频段触发 backlog=8")
        XCTAssertFalse(HLSInterlacedVideoLeadPolicy.canAdvance(
            videoOffset: 24,
            audioNextBoundaryOffsets: [20, 18]
        ), "多音轨必须以最慢音轨为准")
        XCTAssertTrue(HLSInterlacedVideoLeadPolicy.canAdvance(
            videoOffset: 24,
            audioNextBoundaryOffsets: []
        ), "音轨注册前不得阻塞视频冷启动")
    }

    func testInterlacedDeferredInputQueuePreservesRoomToReachInterleavedAudio() {
        XCTAssertEqual(
            HLSInterlacedDeferredInputPolicy.action(
                currentCount: 255,
                requiresAudioBoundaryProgress: false),
            .enqueue
        )
        XCTAssertEqual(
            HLSInterlacedDeferredInputPolicy.action(
                currentCount: 256,
                requiresAudioBoundaryProgress: false),
            .waitForCapacity,
            "50p 转码追不上输入突发时必须等待真实容量，不能把有界队列写满解释为播放失败"
        )
        XCTAssertEqual(
            HLSInterlacedDeferredInputPolicy.action(
                currentCount: 256,
                requiresAudioBoundaryProgress: true),
            .enqueueToReachAudioBoundary,
            "writer 在等音频边界时必须继续读取 TS 交错包，否则会与同一 media worker 循环等待"
        )
        XCTAssertEqual(
            HLSInterlacedDeferredInputPolicy.action(
                currentCount: 319,
                requiresAudioBoundaryProgress: true),
            .enqueueToReachAudioBoundary
        )
        XCTAssertEqual(
            HLSInterlacedDeferredInputPolicy.action(
                currentCount: 320,
                requiresAudioBoundaryProgress: true),
            .rejectAudioBoundaryStall,
            "跨过音频边界的保留窗口也必须有上限"
        )
    }

    func testInterlacedYADIFUsesThreeBoundedInFlightCommands() {
        XCTAssertEqual(HLSInterlacedYADIFPolicy.maximumInFlight, 3)
    }

    func testPrepareFailureRetirementProofRequiresProducerReceiptBeforePlayerInstallation()
        throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 21_980)
        let proof = HLSPrepareFailureRetirementProof()

        proof.record(
            lifecycle: lifecycle,
            producerRetirementConfirmed: false,
            playerInstallationAttempted: false)
        XCTAssertFalse(proof.consume(ifMatching: lifecycle))

        proof.record(
            lifecycle: lifecycle,
            producerRetirementConfirmed: true,
            playerInstallationAttempted: true)
        XCTAssertFalse(proof.consume(ifMatching: lifecycle))

        proof.record(
            lifecycle: lifecycle,
            producerRetirementConfirmed: true,
            playerInstallationAttempted: false)
        let stale = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 21_981)
        XCTAssertFalse(proof.consume(ifMatching: stale), "错误 epoch 不能消费退役证明")
        XCTAssertTrue(proof.consume(ifMatching: lifecycle))
        XCTAssertFalse(proof.consume(ifMatching: lifecycle), "退役证明只能消费一次")
    }

    func testSystemGraphSharesOnePublicationBudgetAcrossPrefixAndTerminalWaits()
        async throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_000)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 7_000_000_000)

        XCTAssertEqual(authority.publicationDeadlineNanosecondsForDiagnostics,
                       7_000_000_000)
        XCTAssertEqual(authority.playablePrefixWaitIntervalForDiagnostics, 7)
        XCTAssertEqual(authority.terminalWaitIntervalForDiagnostics, 7)
        let retired = await authority.retireAllResourcesAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testProductionProgressiveGraphPublishesSixSecondLoopbackPrefixAndRetires()
        async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        let source = fixture.source
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_001)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
        let assembler = HLSMediaGraphAssembler(
            sourceURL: source,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))

        let replacement: AVPlayerItemReplacementBundle
        do {
            replacement = try await assembler.startUntilPlayablePrefix()
        } catch {
            XCTFail("生产媒体图未形成前缀：\(authority.failureDescriptionForDiagnostics ?? String(reflecting: error))")
            return
        }
        XCTAssertEqual(replacement.request.itemURL.host, "127.0.0.1")
        XCTAssertNotEqual(replacement.request.itemURL, source)
        XCTAssertEqual(replacement.request.item.outputLifecycleEpoch, lifecycle)
        let reachedNaturalEOF = await authority.finishAllTracksAtNaturalEOF()
        XCTAssertTrue(
            reachedNaturalEOF,
            "自然 EOF 未闭合：\(authority.failureDescriptionForDiagnostics ?? "无错误描述")")
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
        XCTAssertEqual(assembler.currentPhase, .retired)
    }

    func testProductionProgressiveGraphPublishesFifteenSecondEOFAndRetires()
        async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-15.4s-eof.ts")
        defer { fixture.server?.stop() }
        try await assertProductionFixtureSucceeds(
            source: fixture.source,
            outputNonce: 22_002)
    }

    func testProductionShortFixtureRejectsPrefixAndRetiresWithoutItem() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-0.8s-short.ts")
        defer { fixture.server?.stop() }
        let source = fixture.source
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_003)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
        let assembler = HLSMediaGraphAssembler(
            sourceURL: source,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))

        do {
            _ = try await assembler.startUntilPlayablePrefix()
            XCTFail("不足三秒的媒体不应签发 replacement item")
        } catch {
            let diagnostic = try XCTUnwrap(error as? ErrorDiagnosticSnapshot, String(reflecting: error))
            XCTAssertTrue(diagnostic.summary.contains("videoSampleBuffer"), diagnostic.summary)
            XCTAssertTrue(diagnostic.summary.contains("noEligibleOrigin"), diagnostic.summary)
        }
        XCTAssertEqual(assembler.currentPhase, .retired)
    }

    func testProductionInterlacedGraphUsesYADIF2xAndFailsClosedWithoutHardwareEncoder()
        async throws {
        let fixture = try makeProductionFixture(named: "task22-interlaced-h264-mp2-16s.ts")
        defer { fixture.server?.stop() }
        let source = fixture.source
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_004)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
        let assembler = HLSMediaGraphAssembler(
            sourceURL: source,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))

        #if targetEnvironment(simulator)
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            XCTFail("模拟器不能签发真实 VT 硬件编码证明")
        } catch {
            let diagnostic = try XCTUnwrap(error as? ErrorDiagnosticSnapshot, String(reflecting: error))
            XCTAssertTrue(diagnostic.summary.contains("VTVideoEncoderFailure"), diagnostic.summary)
            XCTAssertEqual(diagnostic, authority.failureDiagnostic)
        }
        XCTAssertNotNil(authority.failureDescriptionForDiagnostics)
        XCTAssertEqual(assembler.currentPhase, .retired)
        #else
        let replacement: AVPlayerItemReplacementBundle
        do {
            replacement = try await assembler.startUntilPlayablePrefix()
        } catch {
            XCTFail("真机隔行生产图失败：\(authority.failureDescriptionForDiagnostics ?? String(reflecting: error))")
            return
        }
        XCTAssertNotEqual(replacement.request.itemURL, source)
        let finished = await authority.finishAllTracksAtNaturalEOF()
        XCTAssertTrue(
            finished,
            "真机隔行自然 EOF 未闭合：\(authority.failureDescriptionForDiagnostics ?? "无错误描述")")
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
        #endif
    }

    func testSystemBuilderBindsOneSourceAndOneLifecycleAuthority() throws {
        let source = try XCTUnwrap(URL(string: "https://example.invalid/live.m3u8"))
        let builder = try SystemHLSOutputItemBundleBuilder(sourceURL: source)

        XCTAssertEqual(builder.sourceURLForDiagnostics, source)
        XCTAssertEqual(builder.demuxerCardinality, 1)
        XCTAssertEqual(builder.playablePrefixMinimumSeconds, 6)
    }

    func testSystemBuilderRejectsNonHTTPSourceBeforeGraphSideEffects() throws {
        let source = try XCTUnwrap(URL(string: "file:///tmp/local.ts"))
        XCTAssertThrowsError(try SystemHLSOutputItemBundleBuilder(validating: source)) { error in
            XCTAssertEqual(error as? PlaybackCoreError, .unsupportedProtocol("file"))
        }
    }

    private func assertProductionFixtureSucceeds(
        source: URL, outputNonce: UInt64
    ) async throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: outputNonce)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
        let assembler = HLSMediaGraphAssembler(
            sourceURL: source,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))

        do {
            let replacement = try await assembler.startUntilPlayablePrefix()
            XCTAssertNotEqual(replacement.request.itemURL, source)
            XCTAssertEqual(replacement.request.item.outputLifecycleEpoch, lifecycle)
        } catch {
            XCTFail("生产媒体图未形成前缀：\(authority.failureDescriptionForDiagnostics ?? String(reflecting: error))")
            return
        }
        let finished = await authority.finishAllTracksAtNaturalEOF()
        XCTAssertTrue(
            finished,
            "自然 EOF 未闭合：\(authority.failureDescriptionForDiagnostics ?? "无错误描述")")
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
        XCTAssertEqual(assembler.currentPhase, .retired)
    }

    private func makeProductionFixture(
        named name: String
    ) throws -> (source: URL, server: Task22BundledHTTPFixtureServer?) {
        if let rawBase = ProcessInfo.processInfo.environment[
            "VPLAYER_TASK22_FIXTURE_BASE_URL"
        ] {
            let base = try XCTUnwrap(URL(string: rawBase), "Task22 fixture 基础 URL 无效")
            return (base.appending(path: name), nil)
        }
        let bundledSource = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: nil),
            "测试包缺少生产媒体图 fixture：\(name)")
        let server = try Task22BundledHTTPFixtureServer(fileURL: bundledSource)
        return (server.sourceURL, server)
    }
}

private final class ErrorReportingHLSGraphAuthority: SystemHLSDeliveryGraphAuthority, @unchecked Sendable {
    var originalError: NSError? = NSError(domain: "HLS.AudioCalibration", code: -50,
        userInfo: [NSLocalizedDescriptionKey: "AAC 校准首错"])
    var failureDiagnostic: ErrorDiagnosticSnapshot? { originalError.map(ErrorDiagnosticSnapshot.init) }
    func append(_ event: AdmittedDemuxEvent) {}
    func awaitAllTrackPlayablePrefix(minimumSeconds: Int) async -> AVPlayerItemReplacementBundle? { nil }
    func finishAllTracksAtNaturalEOF() async -> Bool { false }
    func retireAllResourcesAndAwaitReceipt() async -> Bool {
        originalError = nil
        return true
    }
}

private struct EmptyHLSFailureDemuxBridge: FFmpegDemuxBridging {
    func create(urlBytes: Data, timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiver) -> FFmpegDemuxCreateResult {
        .success(EmptyHLSFailureDemuxHandle())
    }
}

private final class EmptyHLSFailureDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    func run() -> Int32 { 0 }
    func cancel() {}
    func destroy() {}
}

/// 生产媒体图测试走生产 HTTP 输入合同；测试服务只把测试包内的固定 TS 暴露到
/// 本机随机 loopback 端口，保证模拟器和真机都具备相同的输入服务前提。
private final class Task22BundledHTTPFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vplayer.tests.task22-fixture-http")
    private let payload: Data
    let sourceURL: URL

    init(fileURL: URL) throws {
        payload = try Data(contentsOf: fileURL)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .any)
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        let bytes = payload
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                _, _, _, _ in
                let header = Data((
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n" +
                    "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                ).utf8)
                connection.send(content: header, completion: .contentProcessed { error in
                    guard error == nil else {
                        connection.cancel()
                        return
                    }
                    connection.send(content: bytes, isComplete: true, completion: .contentProcessed {
                        _ in connection.cancel()
                    })
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
            listener.cancel()
            throw NSError(
                domain: "Task22BundledHTTPFixtureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "loopback fixture 服务启动失败"])
        }
        sourceURL = url
    }

    func stop() { listener.cancel() }
}
