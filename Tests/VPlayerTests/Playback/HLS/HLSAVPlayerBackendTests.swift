// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
import Network
@testable import VPlayerPlayback

/// Task22-F 的 production 装配边界。整图 fixture 由 root runner 在模拟器上执行；这里先
/// 固定系统 builder 不能接受第二条 source 或脱离同一 lifecycle 的 graph authority。
final class HLSAVPlayerBackendTests: XCTestCase {
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
        let rawBase = ProcessInfo.processInfo.environment[
            "VPLAYER_TASK22_FIXTURE_BASE_URL"
        ] ?? "http://127.0.0.1:19022"
        let base = try XCTUnwrap(URL(string: rawBase))
        let source = base.appending(path: "task22-progressive-h264-aac-16s.ts")
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
        try await assertProductionFixtureSucceeds(
            named: "task22-progressive-h264-aac-15.4s-eof.ts",
            outputNonce: 22_002)
    }

    func testProductionShortFixtureRejectsPrefixAndRetiresWithoutItem() async throws {
        let source = fixtureURL(named: "task22-progressive-h264-aac-0.8s-short.ts")
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
            XCTAssertEqual(
                error as? AVPlayerItemCoordinatorFailure,
                .insufficientCoverage)
        }
        XCTAssertEqual(assembler.currentPhase, .retired)
    }

    func testProductionInterlacedGraphUsesYADIF2xAndFailsClosedWithoutHardwareEncoder()
        async throws {
        #if targetEnvironment(simulator)
        let source = fixtureURL(named: "task22-interlaced-h264-mp2-16s.ts")
        #else
        let bundledSource = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "task22-interlaced-h264-mp2-16s",
                withExtension: "ts"),
            "真机测试包缺少 16 秒隔行媒体 fixture")
        let fixtureServer = try Task22BundledHTTPFixtureServer(fileURL: bundledSource)
        defer { fixtureServer.stop() }
        let source = fixtureServer.sourceURL
        #endif
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
            XCTAssertEqual(
                error as? AVPlayerItemCoordinatorFailure,
                .insufficientCoverage)
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
        named name: String, outputNonce: UInt64
    ) async throws {
        let source = fixtureURL(named: name)
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

    private func fixtureURL(named name: String) -> URL {
        let rawBase = ProcessInfo.processInfo.environment[
            "VPLAYER_TASK22_FIXTURE_BASE_URL"
        ] ?? "http://127.0.0.1:19022"
        return URL(string: rawBase)!.appending(path: name)
    }
}

#if !targetEnvironment(simulator)
/// 真机上的 source 仍必须走生产 HTTP 输入合同；测试服务只把测试包内的固定 TS 暴露到
/// 本机 loopback，避免把 Mac 局域网、IPv6 路由或设备休眠状态混入 Metal/VT 验收。
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
                userInfo: [NSLocalizedDescriptionKey: "真机 loopback fixture 服务启动失败"])
        }
        sourceURL = url
    }

    func stop() { listener.cancel() }
}
#endif
