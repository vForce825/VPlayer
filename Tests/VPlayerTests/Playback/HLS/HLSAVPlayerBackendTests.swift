// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
import Network
import VPlayerCore
@testable import VPlayerPlayback

/// Task22-F 的 production 装配边界。整图 fixture 由 root runner 在模拟器上执行；这里先
/// 固定系统 builder 不能接受第二条 source 或脱离同一 lifecycle 的 graph authority。
final class HLSAVPlayerBackendTests: XCTestCase {
    func testDormantRuntimeFirstFailureReplaysOnceOutsideRelayLock() throws {
        print("HLS 有域首错实际尺寸：eventStride=\(MemoryLayout<PlaybackPipelineEvent>.stride) " +
            "ticketStride=\(MemoryLayout<PrepareTicket>.stride) " +
            "scopeStride=\(MemoryLayout<PlaybackBackendPrepareFailureScope>.stride) " +
            "snapshotStride=\(MemoryLayout<ErrorDiagnosticSnapshot>.stride) " +
            "relayReservation=\(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total)/4096")
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total,
            PlaybackRuntimeAllocationReservations.systemAndPipelineRelayHardCap,
            "新增有域首错不得扩大固定事件槽而突破既有 4 KiB 硬上限")
        let recorded = HLSRuntimeFailureTestRecorder()
        let relay = try Self.makeRuntimeFailureRelay(in: .shared) { diagnostic, _ in
            recorded.recordAndCloseRelay(diagnostic)
        }
        print("HLS 首错元数据上界：\(relay.knownAllocationUpperBoundBytes)/2048；对象 malloc 实测，capture 为固定 ABI 保守余量")
        XCTAssertLessThanOrEqual(relay.knownAllocationUpperBoundBytes,
            HLSRuntimeFailureMetadataOwner.reservationBytes)
        recorded.installRelayForReentrantClose(relay)
        let first = ErrorDiagnosticSnapshot(NSError(domain: "HLS.Prefix.NextOffer", code: -61))
        relay.record(first)
        relay.record(ErrorDiagnosticSnapshot(NSError(domain: "HLS.Secondary", code: -62)))
        XCTAssertTrue(recorded.diagnostics.isEmpty, "prepare 完成前仅保留一个首错槽")
        relay.arm()
        XCTAssertEqual(recorded.diagnostics, [first],
            "arm 须回放 prefix 成功至 SDK prepare 完成之间已到达的首错")
        relay.arm()
        relay.record(ErrorDiagnosticSnapshot(NSError(domain: "HLS.AfterClose", code: -63)))
        XCTAssertEqual(recorded.diagnostics, [first],
            "sink 回入 close 不得锁死，重复 arm 或后继错误不得再投递")
    }

    /// 测试 local ledger/recorder 的构造是 fixture 本身；生产使用已 bootstrap 计费的 shared ledger。
    private static func makeRuntimeFailureRelay(
        in ledger: PlaybackResourceContextLedger,
        sink: @escaping @Sendable (ErrorDiagnosticSnapshot, HLSRuntimeFailureMetadataOwner) -> Void
    ) throws -> HLSRuntimeFailureRelay {
        let owner = try HLSRuntimeFailureMetadataOwner.reserve(in: ledger)
        return try HLSRuntimeFailureRelay(metadataOwner: owner, sink: sink)
    }

    func testRuntimeFailureMetadataChargeSurvivesCloseAndQueuedSnapshotUntilLastAlias() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        do {
            let ticket = try XCTUnwrap(harness.registry.outputResourceContextSnapshot()?.prepareTicket)
            let application = HLSDeliveryApplicationChargeLedger()
            var context: PlaybackResourceContextLedger? = PlaybackResourceContextLedger(applicationLedger: application)
            weak let weakContext = context
            let queued = HLSRuntimeFailureQueuedEventRecorder()
            var relay: HLSRuntimeFailureRelay? = try Self.makeRuntimeFailureRelay(in: try XCTUnwrap(context)) {
                diagnostic, owner in
                queued.record(.backendFailed(diagnostic, prepareScope: .init(ticket: ticket),
                    metadataOwner: owner))
            }
            weak let weakRelay = relay
            XCTAssertEqual(context?.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
            XCTAssertEqual(application.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
            relay?.arm()
            relay?.record(ErrorDiagnosticSnapshot(NSError(domain: "HLS.QueuedFirst", code: -91)))
            XCTAssertTrue(queued.hasEvent, "真实首错 sink 必须把同一 snapshot 与费用 owner 放入事件")
            relay?.close()
            XCTAssertEqual(context?.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes,
                "close 不能归还仍被 relay 与排队事件使用的费用")
            relay = nil
            XCTAssertNil(weakRelay)
            XCTAssertEqual(context?.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes,
                "排队事件是最后 alias，relay 析构仍不得退费")
            context = nil
            XCTAssertNotNil(weakContext, "owner 须强持既有 ledger，不能靠 reservation 的 weak ledger")
            XCTAssertEqual(application.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
            queued.clear()
            XCTAssertNil(weakContext, "最后 queued snapshot alias 消失后释放同一 ledger")
            XCTAssertEqual(application.chargedBytes, 0, "两级 reservation 最终仅归还一次")
        } catch {
            await harness.controller.stop()
            await harness.registry.joinOwnedTerminalCleanup()
            throw error
        }
        await harness.controller.stop()
        await harness.registry.joinOwnedTerminalCleanup()
    }

    func testRuntimeFailureGraphFactoryThrowReleasesEarlyMetadataCharge() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        do {
            let backend = try XCTUnwrap(harness.factory.createdBackends.first)
            let invocation = try XCTUnwrap(backend.prepareInvocationForTesting,
                "必须使用真实 Registry 调用 backend 时的 invocation，不能自行制造权限")
            let application = HLSDeliveryApplicationChargeLedger()
            let context = PlaybackResourceContextLedger(applicationLedger: application)
            let reachedFactory = HLSRuntimeFailureFactoryProbe()
            let expected = ErrorDiagnosticSnapshot(NSError(domain: "HLS.Factory.BeforePrefix", code: -92))
            let builder = try SystemHLSOutputItemBundleBuilder(
                sourceURL: URL(string: "http://localhost/fixture.ts")!, applicationLedger: application,
                resourceContextLedger: context, graphFactory: { _, _, actualApplication, _ in
                    reachedFactory.mark()
                    XCTAssertTrue(actualApplication === application)
                    XCTAssertEqual(context.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes,
                        "graph factory 首次调用前已预费，不依赖 playable prefix 后的 owner")
                    XCTAssertEqual(application.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
                    throw expected
                })
            do {
                _ = try await builder.makeBundle(invocation: invocation)
                XCTFail("真实 factory throw 不应制造 bundle")
            } catch {
                XCTAssertEqual(PlaybackErrorDiagnostics.snapshot(error), expected)
            }
            XCTAssertTrue(reachedFactory.wasReached)
            XCTAssertEqual(context.chargedBytes, 0)
            XCTAssertEqual(application.chargedBytes, 0,
                "早期 throw 必须释放 owner/两级 token，不需要虚构 producer receipt")
            let otherApplication = HLSDeliveryApplicationChargeLedger()
            XCTAssertThrowsError(try SystemHLSOutputItemBundleBuilder(
                sourceURL: URL(string: "http://localhost/fixture.ts")!, applicationLedger: otherApplication,
                resourceContextLedger: context, graphFactory: { _, _, _, _ in throw expected }),
                "显式 local fixture 必须核对同一全局账，不能出现配对错账假结论")
            XCTAssertEqual(otherApplication.chargedBytes, 0)
        } catch {
            await harness.controller.stop()
            await harness.registry.joinOwnedTerminalCleanup()
            throw error
        }
        await harness.controller.stop()
        await harness.registry.joinOwnedTerminalCleanup()
    }

    func testRetiredPrepareAttemptCannotFailNextAttemptWithRealPlayablePrefix() async throws {
        let recorded = HLSRuntimeFailureTestRecorder()
        let sharedSink: @Sendable (ErrorDiagnosticSnapshot, HLSRuntimeFailureMetadataOwner) -> Void = { diagnostic, _ in recorded.record(diagnostic) }
        // 两个 attempt 共用同一上游 sink，不能依靠 PrepareTicket 区分内部重试。
        let oldRelay = try Self.makeRuntimeFailureRelay(in: .shared, sink: sharedSink)
        let oldError = ErrorDiagnosticSnapshot(NSError(domain: "HLS.FirstAttempt", code: -64))
        oldRelay.record(oldError)
        let first = HLSOutputItemBundle(
            startProducer: { throw oldError }, retireProducer: { true }, runtimeFailure: oldRelay)
        do {
            try await first.prepareProducer()
            XCTFail("首个 attempt 必须失败")
        } catch {
            XCTAssertEqual(PlaybackErrorDiagnostics.snapshot(error), oldError)
        }
        XCTAssertEqual(first.currentLifecycle, .retired)
        XCTAssertTrue(HLSPrepareRetryPolicy.shouldRetry(completedAttemptCount: 1,
            maximumAttemptCount: 2, producerRetirementConfirmed: true,
            playerInstallationAttempted: false))

        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_102),
            publicationDeadlineNanoseconds: 10_000_000_000)
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))
        let currentRelay = try Self.makeRuntimeFailureRelay(in: .shared, sink: sharedSink)
        let second = HLSOutputItemBundle(
            startProducer: { try await assembler.startUntilPlayablePrefix() },
            retireProducer: { await assembler.retireAndAwaitReceipt() },
            runtimeFailure: currentRelay)
        do {
            try await second.prepareProducer()
            XCTAssertNotNil(authority.publicationForTesting.publisher?.visible,
                "第二个 attempt 必须凭真实 callback 取得可播前缀")
            second.armRuntimeFailure()
            first.armRuntimeFailure()
            oldRelay.record(ErrorDiagnosticSnapshot(NSError(domain: "HLS.LateOldCallback", code: -65)))
            XCTAssertTrue(recorded.diagnostics.isEmpty,
                "退休的首个 attempt 即使迟到或误 arm，也不得把共用 sink 的成功后继杀死")
            let currentError = ErrorDiagnosticSnapshot(NSError(domain: "HLS.CurrentAttempt", code: -66))
            currentRelay.record(currentError)
            XCTAssertEqual(recorded.diagnostics, [currentError])
        } catch {
            XCTFail("第二个真实前缀 attempt 未成功：\(error)")
        }
        server.stop()
        let retired = await second.retireProducerGraph()
        XCTAssertTrue(retired)
    }

    func testLateRealPublicationOfferFailureReachesAuthorityBeforeSourceEOF()
        async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file)
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_101)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 10_000_000_000)
        let publication = authority.publicationForTesting
        let gate = Task22LatePublicationReceiveGate()
        publication.installBeforeReceiveForTesting { object in gate.receive(object) }
        let assembler = HLSMediaGraphAssembler(
            sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))

        do {
            _ = try await assembler.startUntilPlayablePrefix()
            XCTAssertNotNil(publication.publisher?.visible, "必须先完成真实前缀发布")
            XCTAssertNil(authority.failureDiagnostic)
            let blocked = await Task.detached { gate.waitUntilBlocked() }.value
            XCTAssertTrue(blocked, "必须先挡住已经 sealed 的真实后继 media callback")
            XCTAssertFalse(server.hasSentSourceEOF, "错误发生前 source 不能到达 EOF")

            // 关闭同一个真实 publisher；下一真实 object 必须继续走 validate/offer。
            let publisher = try XCTUnwrap(publication.publisher)
            publisher.close()
            gate.release()

            var publicationFailure: ErrorDiagnosticSnapshot?
            let offerDeadline = ContinuousClock.now + .seconds(2)
            while publicationFailure == nil, ContinuousClock.now < offerDeadline {
                do { _ = try publication.waitForVisible(until: Date()) }
                catch { publicationFailure = PlaybackErrorDiagnostics.snapshot(error) }
                if publicationFailure == nil { try await Task.sleep(for: .milliseconds(5)) }
            }
            let first = try XCTUnwrap(publicationFailure,
                "必须命中 receive catch；不能用 worker/EOF 异常代替真实 offer 异常")
            XCTAssertTrue(first.summary.contains("closed"), first.summary)

            let propagationDeadline = ContinuousClock.now + .milliseconds(250)
            while authority.failureDiagnostic == nil,
                  ContinuousClock.now < propagationDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(server.hasSentSourceEOF)
            XCTAssertFalse(gate.didTimeout, "测试 gate 必须由测试显式放行")
            XCTAssertEqual(authority.failureDiagnostic, first,
                "起播后的 publication 首错必须立即上行；不能等待 source EOF 才发现")
        } catch {
            XCTFail("真实 late offer 回归未走到目标断言：\(error)")
        }

        gate.release()
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired, "测试必须退休真实 writer/server 图")
    }

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

private final class HLSRuntimeFailureQueuedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var event: PlaybackPipelineEvent?
    var hasEvent: Bool { lock.withLock { event != nil } }
    func record(_ value: PlaybackPipelineEvent) { lock.withLock { event = value } }
    func clear() {
        let retired = lock.withLock { () -> PlaybackPipelineEvent? in
            defer { event = nil }
            return event
        }
        withExtendedLifetime(retired) {}
    }
}

private final class HLSRuntimeFailureFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    func mark() { lock.withLock { reached = true } }
    var wasReached: Bool { lock.withLock { reached } }
}

private final class HLSRuntimeFailureTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ErrorDiagnosticSnapshot] = []
    private weak var reentrantRelay: HLSRuntimeFailureRelay?
    var diagnostics: [ErrorDiagnosticSnapshot] { lock.withLock { values } }
    func installRelayForReentrantClose(_ relay: HLSRuntimeFailureRelay) {
        lock.withLock { reentrantRelay = relay }
    }
    func record(_ diagnostic: ErrorDiagnosticSnapshot) { lock.withLock { values.append(diagnostic) } }
    func recordAndCloseRelay(_ diagnostic: ErrorDiagnosticSnapshot) {
        let relay = lock.withLock {
            values.append(diagnostic)
            return reentrantRelay
        }
        relay?.close()
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

/// 只挡住真实已 sealed 的第四段及后继 callback；不触碰媒体、report 或 receipt。
private final class Task22LatePublicationReceiveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var blocked = 0
    private var timedOut = false

    var didTimeout: Bool { condition.withLock { timedOut } }

    func receive(_ object: SealedMediaObject) {
        guard object.kind == .media, object.logicalSequence >= 3 else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !released else { return }
        blocked += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(15)
        while !released {
            if !condition.wait(until: deadline) {
                timedOut = true
                return
            }
        }
    }

    func waitUntilBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while blocked == 0, !released {
            if !condition.wait(until: deadline) { return false }
        }
        return blocked > 0
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }
}

/// 只发送固定 TS 的前 3/8（188-byte packet 对齐），声明完整长度但保持响应未结束。
/// 本 fixture 静态 PTS 覆盖约 5.8 秒，足够真实 3 秒 prefix 与已 sealed 第四段。
private final class Task22LatePublicationFixtureServer: @unchecked Sendable {
    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var active: [NWConnection] = []
        private var stopped = false
        private var sentEOF = false

        var hasSentEOF: Bool { lock.withLock { sentEOF } }

        func admit(_ connection: NWConnection) -> Bool {
            lock.withLock {
                guard !stopped, active.count < 4 else { return false }
                active.append(connection)
                return true
            }
        }

        func stop() {
            let retiring = lock.withLock { () -> [NWConnection] in
                stopped = true
                defer { active.removeAll() }
                return active
            }
            for connection in retiring { connection.cancel() }
        }
    }

    private let listener: NWListener
    private let connections: Connections
    private let queue = DispatchQueue(label: "org.vplayer.tests.late-publication-http")
    let sourceURL: URL
    var hasSentSourceEOF: Bool { connections.hasSentEOF }

    init(fileURL: URL) throws {
        let payload = try Data(contentsOf: fileURL)
        let prefixBytes = (payload.count * 3 / 8) / 188 * 188
        guard prefixBytes > 0, prefixBytes < payload.count else {
            throw NSError(domain: "Task22LatePublicationFixtureServer", code: 1)
        }
        let prefix = Data(payload.prefix(prefixBytes))
        let declaredBytes = payload.count
        let ownedConnections = Connections()
        connections = ownedConnections
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            guard ownedConnections.admit(connection) else { connection.cancel(); return }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                _, _, _, _ in
                let header = Data(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
                    + "Content-Length: \(declaredBytes)\r\nConnection: close\r\n\r\n").utf8)
                connection.send(content: header, completion: .contentProcessed { error in
                    guard error == nil else { connection.cancel(); return }
                    // 不发 isComplete/EOF；未发送的后缀由测试 cleanup 取消。
                    connection.send(content: prefix, completion: .contentProcessed { error in
                        if error != nil { connection.cancel() }
                    })
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
            listener.cancel()
            ownedConnections.stop()
            throw NSError(domain: "Task22LatePublicationFixtureServer", code: 2)
        }
        sourceURL = url
    }

    func stop() { listener.cancel(); connections.stop() }
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
