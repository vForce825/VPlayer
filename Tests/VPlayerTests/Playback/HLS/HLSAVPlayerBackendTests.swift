// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import AudioToolbox
import CryptoKit
import XCTest
import Network
import VPlayerCore
@testable import VPlayer
@testable import VPlayerPlayback

/// Task22-F 的 production 装配边界。整图 fixture 由 root runner 在模拟器上执行；这里先
/// 固定系统 builder 不能接受第二条 source 或脱离同一 lifecycle 的 graph authority。
final class HLSAVPlayerBackendTests: XCTestCase {
    @MainActor
    func testSourcePreparationDiagnosticPreservesTerminalClassificationWithoutRawErrorText() throws {
        let application = HLSDeliveryApplicationChargeLedger()
        let ledger = PlaybackResourceContextLedger(applicationLedger: application)
        let owner = try HLSRuntimeFailureMetadataOwner.reserve(in: ledger)
        let diagnostic = HLSPreparationDiagnostics(metadataOwner: owner)
        diagnostic.begin(.resolve)
        diagnostic.reject(.httpEncoding, status: 200)
        let frozen = diagnostic.freeze()
        diagnostic.begin(.nativePrepare)
        diagnostic.reject(.manifestFeatures)
        let projected = frozen.project(HLSSourceError.unsupportedMedia)
        let snapshot = try XCTUnwrap(projected as? ErrorDiagnosticSnapshot,
            "Direct backend callers receive the bounded terminal snapshot, not a new public error family")
        let original = HLSSourceError.unsupportedMedia as NSError
        XCTAssertEqual(snapshot.typeName, String(reflecting: HLSSourceError.self))
        XCTAssertTrue(snapshot.summary.contains("\(original.domain)(\(original.code))"))
        XCTAssertTrue(snapshot.summary.contains("phase=resolve reason=http-encoding"))
        XCTAssertFalse(snapshot.summary.contains("native"))
        let mapped = PlaybackController.failure(for: .capture(projected, stage: "backend.prepare"))
        let prior = PlaybackController.failure(for: .capture(HLSSourceError.unsupportedMedia, stage: "backend.prepare"))
        XCTAssertEqual(mapped.code, prior.code)
        XCTAssertEqual(mapped.diagnosticCode, prior.diagnosticCode)
        XCTAssertEqual(mapped.retryDisposition, prior.retryDisposition)
        XCTAssertTrue(mapped.userMessage.contains("播放器准备失败"))
        XCTAssertLessThanOrEqual(diagnostic.knownAllocationUpperBoundBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
    }

    func testPreparationDiagnosticLeavesCancellationAndMasterSelectionErrorsUntouched() throws {
        let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
        let diagnostic = HLSPreparationDiagnostics(metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
        diagnostic.begin(.planner)
        let frozen = diagnostic.freeze()
        XCTAssertTrue(frozen.project(CancellationError()) is CancellationError)
        let selection = HLSSelectedServiceRequired(variantCount: 2, audioChoiceCount: 1, subtitleChoiceCount: 0)
        let projected = try XCTUnwrap(frozen.project(selection) as? HLSSelectedServiceRequired)
        XCTAssertEqual(projected.variantCount, 2)
        XCTAssertEqual(frozen.project(HLSSourceError.staleResolution) as? HLSSourceError, .staleResolution)
        XCTAssertEqual(frozen.project(AVPlayerItemCoordinatorFailure.selectionChanged) as? AVPlayerItemCoordinatorFailure, .selectionChanged)
    }

    func testPreparationDiagnosticNewStageClearsPriorReasonAndRetainsOnlySourceCategory() throws {
        let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
        let diagnostic = HLSPreparationDiagnostics(metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
        let context = try sourceContext(url: URL(string: "https://private-fixture.invalid/private-channel?secret=plain-secret")!,
            attributes: ["Authorization": "raw-credential"])
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL,
            generation: 1, topology: .media(Data("body-secret".utf8)), mediaCompleteness: .prefix)
        diagnostic.begin(.resolve)
        diagnostic.reject(.httpEncoding, status: 200)
        diagnostic.resolved(source)
        diagnostic.begin(.probe)
        let snapshot = try XCTUnwrap(diagnostic.freeze().project(HLSSourceError.unsupportedMedia) as? ErrorDiagnosticSnapshot)
        XCTAssertTrue(snapshot.summary.contains("phase=probe reason=none source=direct"))
        XCTAssertFalse(snapshot.summary.contains("http-encoding"))
        for secret in ["private-fixture", "private-channel", "plain-secret", "raw-credential", "body-secret"] {
            XCTAssertFalse(snapshot.summary.contains(secret))
        }
    }

    func testPreparationDiagnosticScopeJoinsBeforeNativeAndReleasesItsOriginalCharge() async throws {
        let application = HLSDeliveryApplicationChargeLedger()
        let ledger = PlaybackResourceContextLedger(applicationLedger: application)
        var owner: HLSRuntimeFailureMetadataOwner? = try HLSRuntimeFailureMetadataOwner.reserve(in: ledger)
        var diagnostic: HLSPreparationDiagnostics? = HLSPreparationDiagnostics(metadataOwner: try XCTUnwrap(owner))
        let weakDiagnostic = TestWeakReference(diagnostic)
        XCTAssertNotNil(weakDiagnostic.value)
        XCTAssertNil(HLSPreparationDiagnostics.current)
        let inherited = await HLSPreparationDiagnostics.$current.withValue(diagnostic) {
            await Task { HLSPreparationDiagnostics.current != nil }.value
        }
        XCTAssertTrue(inherited)
        XCTAssertNil(HLSPreparationDiagnostics.current,
            "Native/player/producer tasks created after joined preflight must not inherit the paid record")
        let nativeInherited = await Task { HLSPreparationDiagnostics.current != nil }.value
        XCTAssertFalse(nativeInherited)
        owner = nil
        XCTAssertEqual(ledger.chargedBytes, HLSRuntimeFailureMetadataOwner.reservationBytes)
        diagnostic = nil
        XCTAssertNil(weakDiagnostic.value)
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertEqual(application.chargedBytes, 0)
    }

    func testContainerDiagnosticDistinguishesAdmissionFromNativeInspectionWithinFixedText() throws {
        for stage in [Int32(2), Int32(6)] {
            let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
            let diagnostic = HLSPreparationDiagnostics(metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
            diagnostic.begin(.probe)
            var native = VPFFSourceDiagnostic()
            native.stage = stage; native.reason = stage == 2 ? 4 : 11
            native.native_result = -22; native.container_kind = 1
            native.input_bytes = 8 * 1_024 * 1_024; native.usable_bytes = 8 * 1_024 * 1_024 - 1
            diagnostic.rejectedContainer(native)
            let snapshot = try XCTUnwrap(diagnostic.freeze().project(HLSSourceError.unsupportedMedia) as? ErrorDiagnosticSnapshot)
            XCTAssertTrue(snapshot.summary.contains("phase=probe reason=container"))
            XCTAssertTrue(snapshot.summary.contains("cstage=\(stage)"))
            XCTAssertTrue(snapshot.summary.contains("status=-22"))
            XCTAssertTrue(snapshot.summary.contains("usable=8388607"), "The final scalar must fit the original detail capacity")
            XCTAssertLessThanOrEqual(snapshot.summary.utf8.count, 384 + 3)
        }
    }

    func testManifestPreflightAnnotatesWithoutChangingTheOriginalTypedThrow() async throws {
        let context = try sourceContext()
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-PART:DURATION=0.5,URI=\"private-part\"\n#EXTINF:1,\nprivate-segment\n"
        let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: context.entryURL)
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .hls(graph))
        let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
        let diagnostic = HLSPreparationDiagnostics(metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
        diagnostic.resolved(source); diagnostic.begin(.probe)
        let transport = SourceTestTransport(responses: [:])
        do {
            _ = try await HLSPreparationDiagnostics.$current.withValue(diagnostic) {
                try await HLSCompatibilityProbe(transport: transport).inspect(source)
            }
            XCTFail("Unsupported manifest feature must retain its original rejection")
        } catch { XCTAssertEqual(error as? HLSSourceError, .unsupportedMedia) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let snapshot = try XCTUnwrap(diagnostic.freeze().project(HLSSourceError.unsupportedMedia) as? ErrorDiagnosticSnapshot)
        XCTAssertTrue(snapshot.summary.contains("phase=probe reason=manifest-features source=hls-media"))
        XCTAssertFalse(snapshot.summary.contains("private-"))
    }

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
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
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
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
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

    func testLivePublicationCommitUsesTheLoopbackMonotonicTimeDomain() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_201))
        let publication = authority.publicationForTesting
        let gate = Task22LatePublicationReceiveGate()
        publication.installBeforeReceiveForTesting { object in gate.receive(object) }
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        let before = SystemHLSLoopbackClock.nowNanoseconds()
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let after = SystemHLSLoopbackClock.nowNanoseconds()
            let committed = try XCTUnwrap(publication.publisher?.ticket.previousPublishInstant)
            XCTAssertGreaterThanOrEqual(committed, before,
                "Production publication must use the same monotonic domain as HTTP residency, not segment ordinals")
            XCTAssertLessThanOrEqual(committed, after)
            XCTAssertFalse(server.hasSentSourceEOF)
        } catch {
            XCTFail("The real writer must reach its live prefix before the clock assertion: \(error)")
        }
        gate.release()
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testLiveLongGOPPendingSegmentPublishesWithoutAnotherCallback() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "homepod-live-h264-aac-80s", withExtension: "ts", subdirectory: "Video"))
        // A bounded 60s source prefix supplies the six-segment startup plus
        // the pending segment. Holding a publication callback must not enqueue
        // the entire 80s burst behind it and exhaust the native relay.
        let server = try Task22LatePublicationFixtureServer(
            fileURL: file)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_202))
        let publication = authority.publicationForTesting
        let gate = Task22LatePublicationReceiveGate()
        publication.installBeforeReceiveForTesting { object in gate.receive(object) }
        // Keep the deliberately incomplete live HTTP body inside its read budget
        // for the whole publication observation; network timeout is a different test.
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            let initial = try XCTUnwrap(publisher.visible)
            let video = try XCTUnwrap(publication.declaration?.video?.participantID)
            XCTAssertEqual(initial.media[video]?.logicalSequences.last, 5)
            gate.releaseThrough(6)
            let nextBlocked = await Task.detached { gate.waitUntilBlocked(atLeast: 7) }.value
            XCTAssertTrue(nextBlocked, "The next callback must be held outside the real publication graph")
            let deadline = ContinuousClock.now + .seconds(7)
            while publisher.visible?.media[video]?.logicalSequences.last == 5,
                  authority.failureDiagnostic == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(authority.failureDiagnostic)
            XCTAssertEqual(publisher.visible?.media[video]?.logicalSequences.last, 6,
                "A sealed pending 5s segment must publish when its real-time gate opens, with no callback or EOF to drive it")
            XCTAssertFalse(publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
            XCTAssertFalse(server.hasSentSourceEOF)
            XCTAssertFalse(gate.didTimeout)
        } catch {
            XCTFail("The real long-GOP writer must reach the live gate assertion: \(error)")
        }
        gate.release()
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testLiveLongGOPBurstContinuesBeyondSixtyFiveSecondsWithoutEOF() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "homepod-live-h264-aac-80s", withExtension: "ts", subdirectory: "Video"))
        let server = try Task22LatePublicationFixtureServer(
            fileURL: file, sendEntireBodyWithoutEOF: true)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_203))
        let publication = authority.publicationForTesting
        // Keep the deliberately incomplete live HTTP body inside its read budget
        // for the whole publication observation; network timeout is a different test.
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            let store = try XCTUnwrap(publication.store)
            let video = try XCTUnwrap(publication.declaration?.video?.participantID)
            let (initial, initialCommit) = try store.domain.sync {
                (try XCTUnwrap(publisher.visible),
                 try XCTUnwrap(publisher.ticket.previousPublishInstant))
            }
            let initialSequence = try XCTUnwrap(initial.media[video]?.logicalSequences.last)
            XCTAssertEqual(initialSequence, 5)
            // The body arrives as a burst, but the production graph must bound its
            // producer and keep publishing on real five-second gates. No test calls
            // publisher.publish, finishes a writer, or manufactures a receipt.
            let deadline = ContinuousClock.now + .seconds(75)
            var lastCommit = initialCommit
            var lastSequence = initialSequence
            var maximumPending = 0
            while lastSequence < 13, authority.failureDiagnostic == nil,
                  ContinuousClock.now < deadline {
                // Snapshot and commit instant must describe the same transaction.
                // A delayed polling task may miss a valid five-second publication.
                let (snapshot, committed) = try store.domain.sync {
                    (try XCTUnwrap(publisher.visible),
                     try XCTUnwrap(publisher.ticket.previousPublishInstant))
                }
                let current = try XCTUnwrap(snapshot.media[video]?.logicalSequences.last)
                XCTAssertGreaterThanOrEqual(current, lastSequence)
                if current > lastSequence {
                    let elapsedGates = Int64(current - lastSequence) * 5_000_000_000
                    XCTAssertGreaterThanOrEqual(committed - lastCommit, elapsedGates,
                        "Burst input cannot bypass any production five-second monotonic gate")
                    lastCommit = committed
                }
                lastSequence = current
                maximumPending = max(maximumPending, publisher.pendingLogicalSequenceCount)
                XCTAssertFalse(snapshot.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(authority.failureDiagnostic,
                "Continuous long-GOP input must not fail at callback 12 with an eight-segment backlog")
            XCTAssertGreaterThanOrEqual(lastSequence, 13,
                "A live playlist must cover at least 70 seconds of real media without natural-end drain")
            XCTAssertLessThanOrEqual(maximumPending, 8,
                "Fixing the clock must preserve the bounded publication backlog")
            XCTAssertGreaterThanOrEqual(lastCommit - initialCommit, 40_000_000_000,
                "Eight live five-second commits must occur after the genuine six-segment prefix")
            let coverage = try XCTUnwrap(publisher.visible?.coverage.participants.first {
                $0.participantID == video
            })
            let horizon = try XCTUnwrap(coverage.ranges.last?.end)
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(horizon.cmTime) - 10, 70)
            for range in coverage.ranges {
                XCTAssertEqual(CMTimeGetSeconds(range.duration.cmTime), 5, accuracy: 0.001,
                    "This fixture must exercise genuine 5s GOP segments, not one-second callbacks")
            }
            XCTAssertFalse(server.hasSentSourceEOF)
        } catch {
            XCTFail("The production continuous-live path failed before its progress assertion: \(error)")
        }
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired, "The continuous source must retire without relying on source EOF")
    }

    func testLiveInjectedClockRetiresTheBackpressuredProducerAndRejectsLateWake() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "homepod-live-h264-aac-80s", withExtension: "ts", subdirectory: "Video"))
        let server = try Task22LatePublicationFixtureServer(
            fileURL: file, sendEntireBodyWithoutEOF: true)
        let clock = ManualPlaybackClock(90_000_000_000)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_204),
            publicationClock: clock)
        let publication = authority.publicationForTesting
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        var retiredPublisher: HLSPublicationCoordinator?
        var frozenSequence: UInt64?
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            retiredPublisher = publisher
            XCTAssertEqual(publisher.ticket.previousPublishInstant, 90_000_000_000)
            XCTAssertEqual(publication.store?.monotonicNowNanoseconds, 90_000_000_000,
                "HTTP residency and publication must sample the same injected domain")
            let deadline = ContinuousClock.now + .seconds(10)
            while !publisher.shouldBackpressureProducer, authority.failureDiagnostic == nil,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(publisher.shouldBackpressureProducer,
                "The real burst-fed worker must reach a bounded common-prefix wait")
            XCTAssertNil(authority.failureDiagnostic)
            XCTAssertLessThanOrEqual(publisher.pendingLogicalSequenceCount, 8)
            frozenSequence = publisher.visible?.publicationSequence
        } catch {
            XCTFail("The actual producer did not reach its capacity wait: \(error)")
        }
        // Retirement must interrupt the producer wait before joining that worker.
        let retired = await assembler.retireAndAwaitReceipt()
        server.stop()
        XCTAssertTrue(retired)
        clock.advance(nanoseconds: 150_000_000_000)
        clock.fireDeadlineTimerEarly()
        await Task.yield()
        XCTAssertEqual(retiredPublisher?.visible?.publicationSequence, frozenSequence)
        XCTAssertTrue(retiredPublisher?.isClosed == true)
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
        XCTAssertEqual(publication.store?.capacityWaiterCount, 0)
    }

    func testLiveInjectedClockSourceSilenceFailsAtTheOriginalPublicationDeadline() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file)
        let clock = ManualPlaybackClock(90_000_000_000)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_205),
            publicationDeadlineNanoseconds: 30_000_000_000,
            publicationClock: clock)
        let publication = authority.publicationForTesting
        let gate = Task22LatePublicationReceiveGate()
        publication.installBeforeReceiveForTesting { object in gate.receive(object) }
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            let originalTicket = publisher.ticket
            XCTAssertEqual(originalTicket.absoluteDeadline, 120_000_000_000)
            clock.set(119_999_999_999)
            clock.fireDeadlineTimerEarly()
            await Task.yield()
            XCTAssertNil(authority.failureDiagnostic)
            XCTAssertEqual(publisher.ticket, originalTicket)
            clock.advance(nanoseconds: 1)
            let deadline = ContinuousClock.now + .seconds(2)
            while authority.failureDiagnostic == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let failure = try XCTUnwrap(authority.failureDiagnostic,
                "No new callback is required to enforce the original publication deadline")
            XCTAssertTrue(failure.summary.contains("deadlineExceeded"), failure.summary)
            XCTAssertEqual(publisher.visible?.publicationSequence, 1)
            XCTAssertFalse(clock.hasScheduledDeadlineTimer)
            XCTAssertFalse(server.hasSentSourceEOF)
        } catch {
            XCTFail("The original live deadline was not observed: \(error)")
        }
        gate.release()
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testLatePublicationFixtureHasFifteenSecondEligibleTimeline() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22BundledHTTPFixtureServer(fileURL: file)
        defer { server.stop() }
        let recorder = DemuxEventRecorder()
        let demuxer = FFmpegDemuxer()
        try demuxer.start(url: server.sourceURL, sink: recorder.record)
        defer { demuxer.cancel() }
        let events = recorder.waitForTerminal(timeout: 10)
        XCTAssertTrue(events.contains { if case .endOfStream = $0 { true } else { false } })
        let videoPackets = events.compactMap { event -> DemuxPacket? in
            guard case .packet(let packet) = event, case .video = packet.codec else { return nil }
            return packet
        }
        XCTAssertEqual(videoPackets.count, 400)
        let first = try XCTUnwrap(videoPackets.first)
        let sourceStart = try ExactMediaTime(first.presentationTimeStamp)
        let idrs = videoPackets.filter { $0.isKey }
        XCTAssertEqual(idrs.count, 16)
        let expectedOrigin = try sourceStart.adding(.init(value: 1, timescale: 1))
        XCTAssertEqual(try ExactMediaTime(XCTUnwrap(idrs.dropFirst().first).presentationTimeStamp), expectedOrigin)
        // Eight progressive observations are required before origin admission.
        // The first IDR precedes that evidence (and the first AAC format), so the
        // next one-second GOP begins the eligible 15s interval, not a 16s interval.
        let timeline = HLSTimelineCoordinator()
        var origins: [MediaOriginReceipt] = []
        var terminal: [HLSTimelineTerminal] = []
        var videoCount = 0
        var normalizedEnd = ExactMediaTime(value: 0, timescale: 1)
        for event in events {
            for emission in try timeline.consume(event) {
                switch emission {
                case .originEstablished(let origin): origins.append(origin)
                case .terminal(let value): terminal.append(value)
                case .videoSample(let sample):
                    videoCount += 1
                    let end = try sample.timing.presentationTimeStamp.adding(XCTUnwrap(sample.timing.duration))
                    if try HLSChecked.compare(end, normalizedEnd) > 0 { normalizedEnd = end }
                default: break
                }
            }
        }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.sourceTime, expectedOrigin)
        XCTAssertEqual(origins.first?.effectiveStart, ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(videoCount, 375)
        XCTAssertEqual(normalizedEnd, .init(value: 25, timescale: 1))
        XCTAssertEqual(terminal, [.endOfStream])
    }

    func testSelectedLiveWakeCannotFailACompletedGenuineNaturalEOF() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file, sendEntireBodyWithoutEOF: true)
        let clock = ManualPlaybackClock(90_000_000_000)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_206),
            publicationClock: clock)
        let publication = authority.publicationForTesting
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        let wake = Task22SelectedLiveWakeGate()
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            print("EOF_WAKE_INITIAL sequence=\(publisher.visible?.publicationSequence ?? 0) media=\(String(describing: publisher.visible?.media.mapValues { $0.logicalSequences })) coverage=\(String(describing: publisher.visible?.coverage))")
            let video = try XCTUnwrap(publication.declaration?.video?.participantID)
            try assertLateFixtureCoverage(try XCTUnwrap(publisher.visible), video: video,
                logicalSequences: Array(0...5))
            // The real timeline-origin contract above proves 15 eligible seconds:
            // initial six segments, eight live commits, then one EOF commit.
            for expected in UInt64(1)..<9 {
                let pending = try await waitForLiveTestCondition { publisher.pendingLogicalSequenceCount > 0 }
                XCTAssertTrue(pending, "expected=\(expected) sequence=\(publisher.visible?.publicationSequence ?? 0) media=\(String(describing: publisher.visible?.media.mapValues { $0.logicalSequences })) failure=\(String(describing: authority.failureDiagnostic))")
                clock.advance(nanoseconds: 1_000_000_000)
                let published = try await waitForLiveTestCondition {
                    publisher.visible?.publicationSequence == expected + 1
                }
                XCTAssertTrue(published)
            }
            XCTAssertEqual(publisher.visible?.publicationSequence, 9)
            try assertLateFixtureCoverage(try XCTUnwrap(publisher.visible), video: video,
                logicalSequences: Array(8...13), publishedSequences: Array(7...13))
            XCTAssertEqual(publisher.pendingLogicalSequenceCount, 0,
                "The genuine source has 15 eligible seconds and leaves only its unsealed final segment")
            publication.installLiveWakeObserverForTesting(
                before: { wake.beforeEntry() }, after: { wake.afterEntry() })
            wake.arm()
            // Select a real live timer callback at its original deadline, but hold
            // it outside graph. The terminal segment's gate is already due.
            clock.set(UInt64(try XCTUnwrap(publisher.ticket.absoluteDeadline)))
            let selected = await Task.detached { wake.waitUntilSelected() }.value
            XCTAssertTrue(selected)
            server.finishBody() // Real demux EOF, encoder drain and terminal writer authorities.
            try await assembler.finishAtNaturalEOF()
            let final = try XCTUnwrap(publisher.visible)
            print("EOF_WAKE_FINAL sequence=\(final.publicationSequence) media=\(final.media.mapValues { $0.logicalSequences }) coverage=\(final.coverage)")
            XCTAssertTrue(final.media.values.allSatisfy { $0.isFinal && $0.text.contains("#EXT-X-ENDLIST") })
            XCTAssertEqual(final.publicationSequence, 10, "Exactly one final commit follows the nine live publications")
            try assertLateFixtureCoverage(final, video: video, logicalSequences: Array(9...14))
            XCTAssertNil(authority.failureDiagnostic)
            wake.release()
            let completed = await Task.detached { wake.waitUntilCompleted() }.value
            XCTAssertTrue(completed)
            XCTAssertFalse(wake.didTimeout)
            XCTAssertNil(authority.failureDiagnostic,
                "A live closure selected before EOF cannot turn successful ENDLIST into a closed-clock failure")
            XCTAssertEqual(publisher.visible?.publicationSequence, final.publicationSequence)
            XCTAssertFalse(clock.hasScheduledDeadlineTimer)
            XCTAssertEqual(publication.store?.capacityWaiterCount, 0)
        } catch {
            XCTFail("Selected-live/real-EOF interleaving did not complete: \(error)")
        }
        wake.release()
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testProductionCapacityReleasePublishesOnceThroughTheGraphOwnedTimer() async throws {
        try await checkProductionCapacityWake(.publish)
    }

    func testProductionCapacitySelectedWakeCannotPublishAfterRetirement() async throws {
        try await checkProductionCapacityWake(.retire)
    }

    func testProductionCapacitySelectedWakeCannotReplaceTheFirstGraphFailure() async throws {
        try await checkProductionCapacityWake(.failure)
    }

    func testProductionCapacitySelectedWakeStaysRevokedAcrossGenuineEOFHandoff() async throws {
        try await checkProductionCapacityWake(.naturalEnd)
    }

    private enum LiveCapacityWakeOutcome { case publish, retire, failure, naturalEnd }

    private func checkProductionCapacityWake(_ outcome: LiveCapacityWakeOutcome) async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let server = try Task22LatePublicationFixtureServer(fileURL: file, sendEntireBodyWithoutEOF: true)
        let clock = ManualPlaybackClock(90_000_000_000)
        let authority = try SystemHLSMediaGraphAuthority(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_207),
            publicationClock: clock)
        let publication = authority.publicationForTesting
        let callbacks = Task22LatePublicationReceiveGate()
        publication.installBeforeReceiveForTesting { callbacks.receive($0) }
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            demuxer: FFmpegDemuxer(timeoutUS: 120_000_000),
            graph: SystemHLSDeliveryGraph(authority: authority))
        let wake = Task22SelectedLiveWakeGate()
        var pinned: [HLSPlaylistResponseLease] = []
        do {
            _ = try await assembler.startUntilPlayablePrefix()
            let publisher = try XCTUnwrap(publication.publisher)
            print("CAPACITY_WAKE_INITIAL outcome=\(outcome) sequence=\(publisher.visible?.publicationSequence ?? 0) media=\(String(describing: publisher.visible?.media.mapValues { $0.logicalSequences })) coverage=\(String(describing: publisher.visible?.coverage))")
            let store = try XCTUnwrap(publication.store)
            // Logical13 is the last sealed live segment; logical14 seals only at
            // genuine EOF. Six initial segments make logical12 publication8.
            let lastBeforeCapacity: UInt64 = outcome == .naturalEnd ? 8 : 4
            callbacks.releaseThrough(lastBeforeCapacity + 5)
            for expected in UInt64(1)...lastBeforeCapacity {
                let reached = try await waitForLiveTestCondition {
                    publisher.visible?.publicationSequence == expected || authority.failureDiagnostic != nil
                }
                XCTAssertTrue(reached)
                XCTAssertNil(authority.failureDiagnostic)
                XCTAssertEqual(publisher.visible?.publicationSequence, expected)
                // Four real two-track generations plus the master exhaust the
                // store's nine-snapshot bound without changing production limits.
                if expected >= lastBeforeCapacity - 3 {
                    for participant in try XCTUnwrap(publisher.visible).media.keys.sorted() {
                        pinned.append(try XCTUnwrap(store.acquireSnapshot(
                            participantID: participant, now: Int64(clock.nowNanoseconds))))
                    }
                }
                if expected < lastBeforeCapacity { clock.advance(nanoseconds: 1_000_000_000) }
            }
            let ready = try await waitForLiveTestCondition { publisher.pendingLogicalSequenceCount > 0 }
            XCTAssertTrue(ready, "sequence=\(publisher.visible?.publicationSequence ?? 0) media=\(String(describing: publisher.visible?.media.mapValues { $0.logicalSequences })) failure=\(String(describing: authority.failureDiagnostic))")
            clock.advance(nanoseconds: 1_000_000_000)
            let blocked = try await waitForLiveTestCondition { store.capacityWaiterCount == 1 }
            XCTAssertTrue(blocked, "The actual production graph must block on a real snapshot reservation")
            XCTAssertEqual(publisher.visible?.publicationSequence, lastBeforeCapacity)
            XCTAssertEqual(store.usage.snapshotCount, 9)
            XCTAssertFalse(server.hasSentSourceEOF)
            publication.installLiveWakeObserverForTesting(
                before: { wake.beforeEntry() }, after: { wake.afterEntry() })
            wake.arm()
            for lease in pinned {
                store.release(lease, completedAt: nil, now: Int64(clock.nowNanoseconds))
            }
            pinned.removeAll()
            let selected = await Task.detached { wake.waitUntilSelected() }.value
            XCTAssertTrue(selected, "Capacity release must select the production signal → timer → graph path")
            XCTAssertEqual(publisher.visible?.publicationSequence, lastBeforeCapacity,
                "Capacity release cannot bypass the held graph lifecycle entry with an inline CAS")
            let releasedAt = Int64(clock.nowNanoseconds)
            var expectedFinal = lastBeforeCapacity
            switch outcome {
            case .publish:
                expectedFinal += 1
            case .retire:
                let retirement = Task { await assembler.retireAndAwaitReceipt() }
                let closed = try await waitForLiveTestCondition {
                    (try? publication.withActivePublication { true }) != true
                }
                XCTAssertTrue(closed)
                callbacks.release() // Writer cleanup can now drain held callbacks into the closed graph.
                let retired = await retirement.value
                XCTAssertTrue(retired)
            case .failure:
                publication.recordFailure(NSError(domain: "Live.Capacity.FirstFailure", code: -207))
            case .naturalEnd:
                // Only the already sealed penultimate segment and final writer
                // tail remain. Demux EOF is genuine; tests never sign terminal receipts.
                callbacks.release()
                server.finishBody()
                var releasedAfterHandoff = false
                for _ in 0..<4 {
                    if publisher.visible?.media.values.allSatisfy({ $0.isFinal }) == true { break }
                    let progressed = try await waitForLiveTestCondition {
                        (publisher.visible?.publicationSequence ?? 0) > expectedFinal || authority.failureDiagnostic != nil
                    }
                    XCTAssertTrue(progressed)
                    expectedFinal = try XCTUnwrap(publisher.visible?.publicationSequence)
                    if !releasedAfterHandoff {
                        // EOF has consumed the due segment under its own scope.
                        // Release the old selected live delivery before the next
                        // EOF timer gate, matching the native serial timer contract.
                        wake.release()
                        let completed = await Task.detached { wake.waitUntilCompleted() }.value
                        XCTAssertTrue(completed)
                        XCTAssertEqual(publisher.visible?.publicationSequence, expectedFinal)
                        XCTAssertNil(authority.failureDiagnostic)
                        releasedAfterHandoff = true
                    }
                    if publisher.visible?.media.values.allSatisfy({ $0.isFinal }) != true {
                        clock.advance(nanoseconds: 1_000_000_000)
                    }
                }
                try await assembler.finishAtNaturalEOF()
                print("CAPACITY_WAKE_FINAL sequence=\(publisher.visible?.publicationSequence ?? 0) media=\(String(describing: publisher.visible?.media.mapValues { $0.logicalSequences })) coverage=\(String(describing: publisher.visible?.coverage))")
                XCTAssertTrue(publisher.visible!.media.values.allSatisfy { $0.isFinal })
                expectedFinal = try XCTUnwrap(publisher.visible?.publicationSequence)
                XCTAssertTrue(publisher.visible!.media.values.allSatisfy { $0.text.contains("#EXT-X-ENDLIST") })
                XCTAssertEqual(expectedFinal, lastBeforeCapacity + 2,
                    "EOF consumes the blocked penultimate segment and exactly one final commit")
                try assertLateFixtureCoverage(try XCTUnwrap(publisher.visible),
                    video: try XCTUnwrap(publication.declaration?.video?.participantID),
                    logicalSequences: Array(9...14))
            }
            wake.release()
            let completed = await Task.detached { wake.waitUntilCompleted() }.value
            XCTAssertTrue(completed)
            XCTAssertFalse(wake.didTimeout)
            XCTAssertEqual(publisher.visible?.publicationSequence, expectedFinal)
            XCTAssertEqual(store.capacityWaiterCount, 0)
            if outcome == .publish {
                XCTAssertEqual(publisher.ticket.previousPublishInstant, releasedAt)
                XCTAssertFalse(publisher.visible!.media.values.contains { $0.isFinal })
            } else if outcome == .failure {
                XCTAssertThrowsError(try publication.waitForVisible(until: Date())) {
                    XCTAssertTrue(PlaybackErrorDiagnostics.snapshot($0).summary.contains("Live.Capacity.FirstFailure"))
                }
                XCTAssertFalse(clock.hasScheduledDeadlineTimer)
            } else {
                XCTAssertFalse(clock.hasScheduledDeadlineTimer)
            }
            if outcome != .failure { XCTAssertNil(authority.failureDiagnostic) }
            XCTAssertFalse(callbacks.didTimeout)
        } catch {
            XCTFail("Real production capacity interleaving failed: \(error)")
        }
        wake.release()
        callbacks.release()
        if let store = publication.store {
            for lease in pinned { store.release(lease, completedAt: nil, now: Int64(clock.nowNanoseconds)) }
        }
        server.stop()
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    private func assertLateFixtureCoverage(_ snapshot: HLSPublishedSnapshot, video: UInt64,
        logicalSequences: [UInt64], publishedSequences: [UInt64]? = nil,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(snapshot.media.count, 2, file: file, line: line)
        XCTAssertEqual(logicalSequences.count, 6, file: file, line: line)
        XCTAssertEqual(snapshot.coverage.logicalSequences, logicalSequences, file: file, line: line)
        XCTAssertEqual(Set(snapshot.coverage.participants.map { $0.participantID }),
            Set(snapshot.media.keys), file: file, line: line)
        // The readiness view always has exactly six common entries. AAC access
        // units can make their physical duration slightly less than three immutable
        // target durations; only that real deficit permits one published overlap.
        var needsOverlap = false
        for participant in snapshot.coverage.participants {
            let media = try XCTUnwrap(snapshot.media[participant.participantID], file: file, line: line)
            let targetLine = try XCTUnwrap(media.text.split(separator: "\n").first {
                $0.hasPrefix("#EXT-X-TARGETDURATION:")
            }, file: file, line: line)
            let target = try XCTUnwrap(Int64(targetLine.split(separator: ":")[1]), file: file, line: line)
            let sixDuration = try participant.ranges.reduce(ExactMediaTime(value: 0, timescale: 1)) {
                try $0.adding($1.duration)
            }
            XCTAssertEqual(participant.ranges.count, 6, file: file, line: line)
            let belowTargetFloor = try HLSChecked.compare(sixDuration,
                .init(value: 3 * target, timescale: 1)) < 0
            needsOverlap = needsOverlap || belowTargetFloor
            let durations = try media.text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.map {
                try XCTUnwrap(Double($0.dropFirst(8).split(separator: ",")[0]), file: file, line: line)
            }
            XCTAssertEqual(durations.count, media.logicalSequences.count, file: file, line: line)
            XCTAssertGreaterThanOrEqual(durations.reduce(0, +), Double(3 * target) - 0.000_01,
                "The actual published bytes must satisfy the immutable target-duration floor", file: file, line: line)
        }
        let first = try XCTUnwrap(logicalSequences.first, file: file, line: line)
        var expectedWindow = logicalSequences
        if needsOverlap {
            let predecessor = try XCTUnwrap(first > 0 ? first - 1 : nil, file: file, line: line)
            expectedWindow.insert(predecessor, at: 0)
        }
        if let publishedSequences {
            XCTAssertEqual(expectedWindow, publishedSequences, file: file, line: line)
        }
        XCTAssertEqual(snapshot.coverage.publishedWindow, expectedWindow, file: file, line: line)
        for media in snapshot.media.values {
            XCTAssertEqual(media.logicalSequences, expectedWindow, file: file, line: line)
        }
        let videoCoverage = try XCTUnwrap(snapshot.coverage.participants.first { $0.participantID == video },
            file: file, line: line)
        for (sequence, range) in zip(logicalSequences, videoCoverage.ranges) {
            XCTAssertEqual(range.start, .init(value: 10 + Int64(sequence), timescale: 1), file: file, line: line)
            XCTAssertEqual(range.duration, .init(value: 1, timescale: 1), file: file, line: line)
        }
    }

    private func waitForLiveTestCondition(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
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

    func testProductionFactoriesStartRealFiveByteLCMP4AtBothRatesAndStop() async throws {
        for rate in [44_100, 48_000] {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: "review-lc-\(rate)-av.mp4", withExtension: nil, subdirectory: "Video"))
            let server = try Task22BundledHTTPFixtureServer(fileURL: file)
            defer { server.stop() }
            for isAirPlay in [false, true] {
                let factory = AudioReviewProductionBackendFactory()
                let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
                let sdk = FakeAudioSessionSDK(initialPorts: isAirPlay ? .airPlay : .hdmi)
                let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
                let routes = PlaybackAudioRouteService(registry: registry, owner: owner)
                let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
                    routeService: routes, backendFactory: factory)
                await controller.play(.init(sourceProfileID: UUID(), channelID: "lc-\(rate)",
                    streamURL: server.sourceURL, title: "Five-byte LC MP4"))
                let state = await controller.currentStateForTesting
                XCTAssertEqual(registry.outputResourceContextSnapshot()?.prepared, true,
                    "\(rate) Hz, AirPlay=\(isAirPlay), real source failed: \(state)")
                await controller.stop()
                await registry.joinOwnedTerminalCleanup()
                XCTAssertNil(registry.outputResourceContextSnapshot())
            }
        }
    }

    func testRealAudioOnlyTSMissingPacketTimestampsReachTimelineWithoutLosingSamples() throws {
        for name in ["review-audio-only-stereo-8s.ts", "review-audio-only-5point1-8s.ts"] {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: nil, subdirectory: "Video"))
            let server = try Task22BundledHTTPFixtureServer(fileURL: file)
            defer { server.stop() }
            let demuxer = FFmpegDemuxer()
            defer { demuxer.cancel() }
            let recorder = DemuxEventRecorder()
            try demuxer.start(url: server.sourceURL, sink: recorder.record)
            let input = recorder.waitForTerminal(timeout: 10)
            XCTAssertEqual(input.last, .endOfStream)
            let missing = input.compactMap { event -> DemuxPacket? in
                guard case .packet(let packet) = event, !packet.presentationTimeStamp.isValid else { return nil }
                return packet
            }
            XCTAssertFalse(missing.isEmpty, "fixture must exercise actual buffered TS AUs without PTS")
            let timeline = HLSTimelineCoordinator()
            var audio: [HLSTimedAudioAccessUnit] = []
            for event in input {
                for output in try timeline.consume(event) {
                    if case .audioSample(let sample) = output { audio.append(sample) }
                }
            }
            XCTAssertEqual(audio.count, 376)
            for (index, sample) in audio.enumerated() {
                XCTAssertEqual(sample.timing.presentationTimeStamp,
                    ExactMediaTime(value: 480_000 + Int64(index * 1_024), timescale: 48_000))
                XCTAssertEqual(sample.source.frameSampleCount, 1_024)
            }
        }
    }

    func testProductionAudioOnlyGraphPublishesDirectPlaylistNaturalEOFAndPreservesChannels() async throws {
        for (name, channels, minimum) in [("review-audio-only-stereo-8s.ts", 2, 3),
                                          ("review-audio-only-5point1-8s.ts", 6, 3),
                                          ("review-audio-only-stereo-5s.ts", 2, 4)] {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: nil, subdirectory: "Video"))
            let server = try Task22BundledHTTPFixtureServer(fileURL: file)
            defer { server.stop() }
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: UInt64(23_800 + channels)),
                initialWindowMinimumSeconds: minimum)
            let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
                applicationLedger: HLSDeliveryApplicationChargeLedger(),
                graph: SystemHLSDeliveryGraph(authority: authority))
            do {
                let replacement = try await assembler.startUntilPlayablePrefix()
                let selected = try XCTUnwrap(replacement.request.directAudioOnlyRendition)
                XCTAssertEqual(replacement.request.audioParticipants.count, 1)
                let participant = try XCTUnwrap(replacement.request.audioParticipants.first)
                XCTAssertEqual(participant.renditionIdentity, selected)
                XCTAssertEqual(participant.codec, .aac)
                XCTAssertNotNil(participant.terminalBinding)
                XCTAssertNotNil(participant.renditionBinding)
                XCTAssertTrue(replacement.request.itemURL.path.contains("/audio/"))
                let finished = await authority.finishAllTracksAtNaturalEOF()
                XCTAssertTrue(finished, authority.failureDescriptionForDiagnostics ?? "EOF did not finish")
                let (playlist, response) = try await URLSession.shared.data(from: replacement.request.itemURL)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let text = String(decoding: playlist, as: UTF8.self)
                XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
                XCTAssertEqual((response as? HTTPURLResponse)?.mimeType, "application/vnd.apple.mpegurl")
                try await assertServedAudioFragmentDecodes(playlist: text,
                    itemURL: replacement.request.itemURL, channels: channels)
                // Apple documents HLS inspection via a ready AVPlayerItem, not a
                // standalone AVURLAsset. Require the real stream to advance too.
                try await Self.assertNativeAudioPlaylistPlays(replacement.request.itemURL)
            } catch {
                print("AUDIO_ONLY_GRAPH_FAILURE channels=\(channels) error=\(error) history=\(PlaybackDiagnosticTracker.shared.recentHistory)")
                let retired = await assembler.retireAndAwaitReceipt()
                XCTAssertTrue(retired)
                throw error
            }
            let retired = await assembler.retireAndAwaitReceipt()
            XCTAssertTrue(retired)
            XCTAssertEqual(assembler.currentPhase, .retired)
        }
    }

    func testProductionFactoryStartsAudioOnlyAirPlayAndStopRetiresRealOutput() async throws {
        let cases = [("review-audio-only-stereo-8s.ts", PlaybackTuning.videoBufferSecondsChoices),
                     ("review-audio-only-stereo-5s.ts", [4.0])]
        for (name, choices) in cases {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: nil, subdirectory: "Video"))
            let server = try Task22BundledHTTPFixtureServer(fileURL: file)
            defer { server.stop() }
            for seconds in choices {
                let factory = AudioReviewProductionBackendFactory()
                let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
                let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
                let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
                let routes = PlaybackAudioRouteService(registry: registry, owner: owner)
                let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
                    routeService: routes, backendFactory: factory)
                await controller.setTuning(.init(videoBufferSeconds: seconds))
                await controller.play(.init(sourceProfileID: UUID(), channelID: "radio-regression",
                    streamURL: server.sourceURL, title: "Audio-only fixture"))
                let state = await controller.currentStateForTesting
                let context = registry.outputResourceContextSnapshot()
                XCTAssertEqual(context?.prepared, true,
                    "production factory failed with buffer=\(seconds): \(state); history=\(PlaybackDiagnosticTracker.shared.recentHistory)")
                XCTAssertTrue(factory.backend?.isAudioOnly == true)
                XCTAssertNotNil(factory.backend?.outputItemGeneration)
                do {
                    if context?.prepared == true, let backend = factory.backend {
                        try await Self.assertActivatedAudioBackendAdvances(backend, configuredBuffer: seconds)
                    }
                } catch {
                    await controller.stop()
                    await registry.joinOwnedTerminalCleanup()
                    throw error
                }
                await controller.stop()
                await registry.joinOwnedTerminalCleanup()
                XCTAssertNil(registry.outputResourceContextSnapshot())
            }
        }
    }

    func testAudioOnlyFiniteSourcesBelowSelectedPublicationMinimumRemainUnprepared() async throws {
        for (name, minimum) in [("review-audio-only-stereo-2point5s.ts", 3),
                                ("review-audio-only-stereo-3point5s.ts", 4)] {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: nil, subdirectory: "Video"))
            let server = try Task22BundledHTTPFixtureServer(fileURL: file)
            defer { server.stop() }
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: UInt64(23_820 + minimum)),
                initialWindowMinimumSeconds: minimum)
            let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
                applicationLedger: HLSDeliveryApplicationChargeLedger(),
                graph: SystemHLSDeliveryGraph(authority: authority))
            do {
                _ = try await assembler.startUntilPlayablePrefix()
                XCTFail("A finite source shorter than its authentic publication minimum cannot prepare")
            } catch {
                XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .insufficientCoverage,
                    "Unexpected short-source failure: \(error); \(PlaybackDiagnosticTracker.shared.recentHistory)")
            }
            let retired = await assembler.retireAndAwaitReceipt()
            XCTAssertTrue(retired)
            XCTAssertEqual(assembler.currentPhase, .retired)
        }
    }

    private func assertServedAudioFragmentDecodes(playlist: String, itemURL: URL,
                                                channels: Int) async throws {
        let lines = playlist.split(separator: "\n").map(String.init)
        let map = try XCTUnwrap(lines.first { $0.hasPrefix("#EXT-X-MAP:URI=\"") })
        let initializationPath = try XCTUnwrap(map.split(separator: "\"").dropFirst().first)
        let mediaPath = try XCTUnwrap(lines.first { !$0.isEmpty && !$0.hasPrefix("#") })
        let initializationURL = try XCTUnwrap(URL(string: String(initializationPath), relativeTo: itemURL))
        let mediaURL = try XCTUnwrap(URL(string: mediaPath, relativeTo: itemURL))
        let (initialization, initialResponse) = try await URLSession.shared.data(from: initializationURL)
        let (media, mediaResponse) = try await URLSession.shared.data(from: mediaURL)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((mediaResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.mimeType, "audio/mp4")
        XCTAssertEqual((mediaResponse as? HTTPURLResponse)?.mimeType, "audio/iso.segment")
        XCTAssertFalse(initialization.isEmpty)
        XCTAssertFalse(media.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try (initialization + media).write(to: file)
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(description.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(description.pointee.mChannelsPerFrame, UInt32(channels))
        XCTAssertEqual(description.pointee.mSampleRate, 48_000)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        XCTAssertTrue(reader.canAdd(output), "The real served AAC must admit system LPCM decode")
        guard reader.canAdd(output) else { throw AVPlayerItemCoordinatorFailure.itemFailed }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let ready = try await provider.next() else {
            XCTFail("The real served AAC produced no decoded PCM: \(String(describing: reader.error))")
            throw AVPlayerItemCoordinatorFailure.itemFailed
        }
        let decoded = try makeOwnedReaderFixtureSample(copying: ready)
        XCTAssertGreaterThan(CMSampleBufferGetNumSamples(decoded), 0)
        let decodedFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(decoded))
        let decodedDescription = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(decodedFormat))
        XCTAssertEqual(decodedDescription.pointee.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(decodedDescription.pointee.mChannelsPerFrame,
                       UInt32(channels), "System AAC decode must preserve the served channel count")
    }

    @MainActor
    private static func assertActivatedAudioBackendAdvances(_ backend: HLSAVPlayerPlaybackBackend,
                                                           configuredBuffer: TimeInterval) async throws {
        guard case .avPlayer(let context)? = backend.presentation else {
            XCTFail("The production audio-only backend must expose its actual AVPlayer")
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        let player = context.player
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(item.preferredForwardBufferDuration, configuredBuffer)
        XCTAssertEqual(item.status, .readyToPlay)
        let start = player.currentTime()
        XCTAssertTrue(start.isNumeric)
        guard start.isNumeric else { throw AVPlayerItemCoordinatorFailure.invalidTimeline }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        // Do not call play here: only the production Registry activation can start it.
        while CMTimeCompare(player.currentTime(), CMTimeAdd(start, CMTime(value: 1, timescale: 4))) < 0,
              item.status != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let end = player.currentTime()
        XCTAssertTrue(end.isNumeric)
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        guard end.isNumeric else { throw AVPlayerItemCoordinatorFailure.invalidTimeline }
        XCTAssertGreaterThanOrEqual(CMTimeCompare(end,
            CMTimeAdd(start, CMTime(value: 1, timescale: 4))), 0,
            "Registry activation did not advance the real audio item; history=\(PlaybackDiagnosticTracker.shared.recentHistory)")
    }

    @MainActor
    private static func assertNativeAudioPlaylistPlays(_ url: URL) async throws {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while item.status == .unknown, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        guard item.status == .readyToPlay else { throw AVPlayerItemCoordinatorFailure.itemFailed }
        let start = player.currentTime()
        XCTAssertTrue(start.isNumeric)
        guard start.isNumeric else { throw AVPlayerItemCoordinatorFailure.invalidTimeline }
        player.play()
        let playbackDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while CMTimeCompare(player.currentTime(), CMTimeAdd(start, CMTime(value: 1, timescale: 4))) < 0,
              item.status != .failed, ContinuousClock.now < playbackDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let end = player.currentTime()
        XCTAssertTrue(end.isNumeric)
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        guard end.isNumeric else { throw AVPlayerItemCoordinatorFailure.invalidTimeline }
        XCTAssertGreaterThanOrEqual(CMTimeCompare(end,
            CMTimeAdd(start, CMTime(value: 1, timescale: 4))), 0, String(describing: item.error))
        XCTAssertFalse(item.loadedTimeRanges.isEmpty)
        print("AUDIO_ONLY_NATIVE_PLAYBACK ready=\(item.status.rawValue) time=\(player.currentTime())")
    }

    func testProductionAirPlayPublishesMediaInformationThroughControllerToPresentation() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        let factory = AudioReviewProductionBackendFactory()
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let owner = try PlaybackAudioSessionOwner(registry: registry,
            sdk: FakeAudioSessionSDK(initialPorts: .airPlay))
        let routes = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: routes, backendFactory: factory)
        let stream = await controller.playbackMediaInformation()
        let information = PlaybackStreamRecorder<PlaybackMediaInformation?>()
        let collector = Task {
            for await value in stream { information.append(value) }
        }
        defer { collector.cancel() }
        let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "homepod-metadata",
            streamURL: fixture.source, title: "Progressive HomePod fixture")

        await controller.play(request)
        do {
            let state = await controller.currentStateForTesting
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.prepared, true,
                "The real HLS startup must remain successful: \(state)")
            XCTAssertEqual(state, .playing(request))
            XCTAssertNotNil(factory.backend, "AirPlay must use the real HLS backend")
            XCTAssertFalse(factory.backend?.isAudioOnly ?? true)

            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !information.snapshot.contains(where: { $0 != nil }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let published = try XCTUnwrap(information.snapshot.compactMap { $0 }.last,
                "Playing HLS must supply the controller's public media stream instead of leaving the UI detecting")
            XCTAssertEqual(published.width, 1_280)
            XCTAssertEqual(published.height, 720)
            XCTAssertEqual(published.scanMode, .progressive)
            XCTAssertEqual(published.sourceFrameRate, MediaRational(num: 25, den: 1))
            XCTAssertEqual(published.outputFrameRate, 25)
            XCTAssertFalse(published.isSmoothMotionEnhanced)
            XCTAssertNil(factory.backend?.routedTransportForTesting,
                "This legacy factory supplies no original source-routing owner")
            XCTAssertEqual(published.airPlayOutputMode, .audioTranscode,
                "A valid legacy generated prefix must remain projectable without a source-routing owner")
            XCTAssertEqual(PlaybackMediaInformationPresentation(information: published).airPlayOutputText,
                "AirPlay输出方式：音频转码")
            XCTAssertEqual(PlaybackMediaInformationPresentation(information: published).visualText,
                "1280×720p · 25 fps")
        } catch {
            await controller.stop()
            await registry.joinOwnedTerminalCleanup()
            throw error
        }
        await controller.stop()
        await registry.joinOwnedTerminalCleanup()
        XCTAssertNil(registry.outputResourceContextSnapshot())
    }

    func testProductionHLSMediaInformationReplaysWhilePausedAndRejectsStoppedScope() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        try await withProductionMediaController { controller, registry, _, _ in
            let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "paused-metadata",
                streamURL: fixture.source, title: "Paused metadata")
            await controller.play(request)
            let lifecycle = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            let initial = await self.currentMediaInformation(controller)
            XCTAssertEqual(initial?.width, 1_280, "A subscriber joining after prepare must receive the snapshot")

            // Model a notification that lost the pause-owner race. A successful
            // retained pause must replay even though it does not activate again.
            await controller.invalidatePreparedMediaInformation(for: lifecycle)
            let cleared = await self.currentMediaInformation(controller)
            XCTAssertNil(cleared)
            await controller.setPaused(true)
            let state = await controller.currentStateForTesting
            XCTAssertEqual(state, .paused(request))
            let paused = await self.currentMediaInformation(controller)
            XCTAssertEqual(paused, initial)
            XCTAssertNotNil(registry.preparedHLSMediaInformation(for: lifecycle))

            await controller.stop()
            await registry.joinOwnedTerminalCleanup()
            await controller.refreshPreparedMediaInformation(for: lifecycle)
            let stopped = await self.currentMediaInformation(controller)
            XCTAssertNil(stopped)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: lifecycle))
        }
    }

    func testProductionHLSPauseJoinsAlreadyStartedSuspendBeforeReplayingMediaInformation() async throws {
        try await checkProductionHLSJoinsStartedSuspendBeforeMetadataReplay(routeLoss: false)
    }

    func testProductionHLSRouteLossJoinsAlreadyStartedSuspendBeforeMetadataRefresh() async throws {
        try await checkProductionHLSJoinsStartedSuspendBeforeMetadataReplay(routeLoss: true)
    }

    private func checkProductionHLSJoinsStartedSuspendBeforeMetadataReplay(routeLoss: Bool) async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        try await withProductionMediaController { controller, registry, _, _ in
            let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "joined-pause-metadata",
                streamURL: fixture.source, title: "Joined pause metadata")
            await controller.play(request)
            let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let lifecycle = try XCTUnwrap(context.interval?.outputLifecycle)
            let information = await self.currentMediaInformation(controller)
            let initial = try XCTUnwrap(information)
            XCTAssertEqual(initial.width, 1_280)
            XCTAssertEqual(initial.height, 720)
            XCTAssertEqual(initial.scanMode, .progressive)
            XCTAssertEqual(initial.sourceFrameRate, MediaRational(num: 25, den: 1))
            await controller.invalidatePreparedMediaInformation(for: lifecycle)

            // User-control ingress and pause-owner admission are separate Registry
            // transactions. The MainActor AVPlayer relay can start the original
            // pause runner between them while the controller's own actor runs.
            // Reproduce the resulting legitimate ownership state without a sleep
            // or a test hook in either production executor.
            if !routeLoss {
                let safety = registry.executor.safetyIngress.snapshot
                let control = OutputUserControlRequest(kind: .pause,
                    sessionIdentity: context.sessionIdentity, expectedOwner: context.owner,
                    contextNonce: context.contextNonce, interruptionEpoch: safety.interruptionEpoch,
                    mediaServicesEpoch: safety.mediaServicesEpoch,
                    resetPreRouteBinding: context.resetPreRouteBinding)
                XCTAssertEqual(registry.performOutputUserControl(control), .acceptedWaiting)
            }
            let owner = try XCTUnwrap(registry.beginOutputTransition(
                contextNonce: context.contextNonce, reason: .pause,
                anchorInstant: registry.clock.nowNanoseconds, teardown: false))
            let suspend = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
            _ = registry.startOutputSuspendOperation(suspend.task, owner: owner)
            guard case .succeeded = await registry.joinOutputBackendOperation(suspend.task) else {
                return XCTFail("The original production suspension must physically finish")
            }
            XCTAssertFalse(registry.startOutputSuspendOperation(suspend.task, owner: owner),
                "First-start must still reject an already-started exact runner")
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner, owner)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: lifecycle),
                "Physical quiescence alone cannot bypass the unsettled pause owner")

            if routeLoss { await controller.suspendActiveOutputForRouteUnavailable() }
            else { await controller.setPaused(true) }

            let diagnostic = await self.mediaControllerDiagnostic(controller, registry: registry)
            let state = await controller.currentStateForTesting
            XCTAssertEqual(state, routeLoss ? .recovering(request) : .paused(request), diagnostic)
            let retained = try XCTUnwrap(registry.outputResourceContextSnapshot(), diagnostic)
            XCTAssertNil(retained.owner, diagnostic)
            XCTAssertNil(retained.suspend, diagnostic)
            XCTAssertNil(retained.interval, diagnostic)
            XCTAssertNil(registry.phase(of: suspend.task), "Only the joined runner may be retired")
            XCTAssertEqual(retained.prepareTicket, context.prepareTicket)
            // This fixture keeps the same fake route admissible: exercise pause
            // settlement and the exact lifecycle refresh, not physical route loss.
            if routeLoss { await controller.refreshPreparedMediaInformation(for: lifecycle) }
            let paused = await self.currentMediaInformation(controller)
            XCTAssertEqual(paused, initial, diagnostic)
            XCTAssertEqual(registry.preparedHLSMediaInformation(for: lifecycle)?.information, initial, diagnostic)

            await controller.stop()
            await registry.joinOwnedTerminalCleanup()
            await controller.refreshPreparedMediaInformation(for: lifecycle)
            let stopped = await self.currentMediaInformation(controller)
            XCTAssertNil(stopped)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: lifecycle))
        }
    }

    func testProductionHLSAdmissibleRetainedPauseReplaysMediaWithoutActivation() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        try await withProductionMediaController { controller, registry, _, _ in
            let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "paused-route-metadata",
                streamURL: fixture.source, title: "Paused route recovery")
            await controller.play(request)
            let lifecycle = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            await controller.setPaused(true)
            let pausedState = await controller.currentStateForTesting
            XCTAssertEqual(pausedState, .paused(request))
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.prepared, true)
            XCTAssertNil(registry.outputResourceContextSnapshot()?.owner)
            // Keep the original route authority admissible. This exercises the
            // retained-pause helper, not physical empty-to-AirPlay restoration.
            // The physical pause already settled; do not issue a second suspend
            // against its consumed output interval merely to change UI state.
            await controller.publishRouteRecovering(request: request)
            await controller.invalidatePreparedMediaInformation(for: lifecycle)
            let cleared = await self.currentMediaInformation(controller)
            XCTAssertNil(cleared)
            await controller.resumeActiveOutputFromRouteRecovery()
            let information = await self.currentMediaInformation(controller)
            XCTAssertEqual(information?.width, 1_280,
                "Retained route recovery must replay a refresh lost to the pause owner without activating")
            let state = await controller.currentStateForTesting
            XCTAssertEqual(state, .paused(request))
            XCTAssertNil(registry.outputResourceContextSnapshot()?.interval)
        }
    }

    func testProductionHLSChannelReplacementRejectsOldRefreshAndClearThenPublishesAudioOnlyOutput() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        let audioFile = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "review-audio-only-stereo-8s.ts", withExtension: nil, subdirectory: "Video"))
        let audioServer = try Task22BundledHTTPFixtureServer(fileURL: audioFile)
        defer { audioServer.stop() }
        try await withProductionMediaController { controller, registry, factory, _ in
            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-first",
                streamURL: fixture.source, title: "First"))
            let first = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            weak var retiredBackend = try XCTUnwrap(factory.backend)
            XCTAssertNotNil(retiredBackend?.preparedMediaInformation(for: first))

            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-second",
                streamURL: fixture.source, title: "Second"))
            let secondDiagnostic = await self.mediaControllerDiagnostic(controller, registry: registry)
            let second = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle,
                secondDiagnostic)
            XCTAssertNotEqual(first, second)
            let current = await self.currentMediaInformation(controller)
            XCTAssertEqual(current?.width, 1_280)
            await controller.refreshPreparedMediaInformation(for: first)
            await controller.invalidatePreparedMediaInformation(for: first)
            let afterStaleCallbacks = await self.currentMediaInformation(controller)
            XCTAssertEqual(afterStaleCallbacks, current,
                "Equal dimensions do not make the retired graph's callbacks current")
            XCTAssertNil(retiredBackend?.preparedMediaInformation(for: first))
            XCTAssertNil(registry.preparedHLSMediaInformation(for: first))
            retiredBackend = nil

            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-radio",
                streamURL: audioServer.sourceURL, title: "Radio"))
            let audio = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            let snapshot = try XCTUnwrap(registry.preparedHLSMediaInformation(for: audio))
            XCTAssertEqual(snapshot.lifecycle, audio)
            XCTAssertTrue(snapshot.information?.isAudioOnly == true)
            XCTAssertEqual(snapshot.information?.airPlayOutputMode, .audioTranscode)
            XCTAssertNil(snapshot.information?.sourceFrameRate)
            XCTAssertNil(snapshot.information?.outputFrameRate)
            await controller.refreshPreparedMediaInformation(for: second)
            await controller.invalidatePreparedMediaInformation(for: second)
            let audioInformation = await self.currentMediaInformation(controller)
            XCTAssertEqual(audioInformation, snapshot.information)
        }
    }

    func testProductionHLSRouteHandoffClearsMediaAndRejectsOldCallbacksAfterSampleBuffer() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        try await withProductionMediaController { controller, registry, _, sdk in
            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-route",
                streamURL: fixture.source, title: "Route metadata"))
            let startupDiagnostic = await self.mediaControllerDiagnostic(controller, registry: registry)
            let old = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle,
                startupDiagnostic)
            let stream = await controller.playbackMediaInformation()
            let values = PlaybackStreamRecorder<PlaybackMediaInformation?>()
            let collector = Task { for await value in stream { values.append(value) } }
            defer { collector.cancel() }
            sdk.lock.withLock { sdk.initialPorts = .hdmi }
            await controller.requestRouteHandoff(to: .sampleBuffer)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(values.snapshot.contains(where: { $0 == nil }) && values.snapshot.last.flatMap({ $0 }) != nil),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(registry.outputResourceContextSnapshot()?.desiredBackendKind, .sampleBuffer)
            XCTAssertTrue(values.snapshot.contains(where: { $0 == nil }), "Route retirement must clear the old facts")
            let local = try XCTUnwrap(values.snapshot.last.flatMap { $0 })
            XCTAssertEqual(local.width, 1_280)
            XCTAssertNil(local.airPlayOutputMode, "The AirPlay field must clear on the HDMI/sample-buffer path")
            await controller.refreshPreparedMediaInformation(for: old)
            await controller.invalidatePreparedMediaInformation(for: old)
            let afterStaleCallbacks = await self.currentMediaInformation(controller)
            XCTAssertEqual(afterStaleCallbacks, local)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: old))
        }
    }

    func testProductionHLSFailedReplacementDoesNotRepublishRetiredMediaInformation() async throws {
        let first = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        let short = try makeProductionFixture(named: "task22-progressive-h264-aac-0.8s-short.ts")
        defer { first.server?.stop(); short.server?.stop() }
        try await withProductionMediaController { controller, registry, _, _ in
            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-good",
                streamURL: first.source, title: "Good"))
            let old = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-short",
                streamURL: short.source, title: "Short"))
            let state = await controller.currentStateForTesting
            guard case .failed = state else { return XCTFail("The real short source must fail prepare: \(state)") }
            await controller.refreshPreparedMediaInformation(for: old)
            let information = await self.currentMediaInformation(controller)
            XCTAssertNil(information)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: old))
        }
    }

    func testProductionCanceledPrefixReleasesDriverAdmissionForDifferentChannel() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "task22-progressive-h264-aac-16s.ts", withExtension: nil))
        let stalled = try Task22LatePublicationFixtureServer(fileURL: file, prefixByteLimit: 188)
        let next = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { stalled.stop(); next.server?.stop() }
        let observation = HLSPreparingGraphObservation()
        let factory = AudioReviewProductionBackendFactory(factory: SystemPlaybackBackendFactory(
            hlsGraphFactory: { source, invocation, ledger, failureSink in
                let authority = try SystemHLSMediaGraphAuthority(
                    lifecycle: invocation.outputLifecycleEpoch, failureSink: failureSink)
                if source == stalled.sourceURL { observation.record(authority) }
                return HLSMediaGraphAssembler(sourceURL: source, applicationLedger: ledger,
                    graph: SystemHLSDeliveryGraph(authority: authority))
            }))
        try await withProductionMediaController(factory: factory) { controller, registry, factory, _ in
            let play = Task { await controller.play(.init(sourceProfileID: UUID(), channelID: "cancel-stalled-prefix",
                streamURL: stalled.sourceURL, title: "Stalled prefix")) }
            let entryDeadline = ContinuousClock.now + .seconds(10)
            while !observation.waiting, ContinuousClock.now < entryDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(observation.waiting, "Hold the real graph before any playable publication")
            let original = factory.backend?.identity
            XCTAssertNotNil(original, "The production factory has allocated the real SystemAVPlayerDriver")
            XCTAssertNil(factory.backend?.outputItemGeneration, "No prefix may install an item")
            let stopped = PlaybackStreamRecorder<Bool>()
            let stop = Task { await controller.stop(); stopped.append(true) }
            let stopDeadline = ContinuousClock.now + .seconds(3)
            while stopped.snapshot.isEmpty, ContinuousClock.now < stopDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let finished = !stopped.snapshot.isEmpty
            XCTAssertTrue(finished, "Stop must cancel and join the real prefix wait without source EOF")
            XCTAssertFalse(stalled.hasSentSourceEOF)
            // Only bound a failed RED after its cancellation assertion. Do not
            // release source readiness on the passing cancellation path.
            if !finished { stalled.stop() }
            await play.value
            await stop.value
            await registry.joinOwnedTerminalCleanup()
            XCTAssertNil(registry.outputResourceContextSnapshot())
            XCTAssertNil(factory.backend, "No test-owned backend alias may keep driver admission alive")
            guard finished else { return }

            let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "different-after-prefix-cancel",
                streamURL: next.source, title: "Different channel")
            await controller.play(request)
            let state = await controller.currentStateForTesting
            XCTAssertEqual(state, .playing(request))
            XCTAssertNotNil(factory.backend)
            XCTAssertNotEqual(factory.backend?.identity, original,
                "A new production backend must pass real process-wide driver admission")
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.prepared ?? false)
        }
    }

    func testProductionHLSPrepareWhilePausedPublishesButCanceledPrepareDoesNot() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        for cancelPreparation in [false, true] {
            let gate = HLSMediaInformationPrefixGate()
            let factory = AudioReviewProductionBackendFactory(factory: SystemPlaybackBackendFactory(
                hlsGraphFactory: { source, invocation, ledger, failureSink in
                    let authority = try SystemHLSMediaGraphAuthority(
                        lifecycle: invocation.outputLifecycleEpoch, failureSink: failureSink)
                    return HLSMediaGraphAssembler(sourceURL: source, applicationLedger: ledger,
                        graph: HLSMediaInformationGatedGraph(
                            graph: SystemHLSDeliveryGraph(authority: authority), gate: gate))
                }))
            try await withProductionMediaController(factory: factory) { controller, registry, _, _ in
                let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "metadata-prepare-race",
                    streamURL: fixture.source, title: "Prepare race")
                let play = Task { await controller.play(request) }
                defer { gate.release(); play.cancel() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while !gate.isWaiting, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(gate.isWaiting, "Wait for an actual playable prefix, not a synthetic ready event")
                XCTAssertFalse(registry.outputResourceContextSnapshot()?.prepared ?? true)
                if cancelPreparation {
                    let stop = Task { await controller.stop() }
                    let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while registry.outputResourceContextSnapshot()?.owner == nil,
                          ContinuousClock.now < cancellationDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertNotNil(registry.outputResourceContextSnapshot()?.owner)
                    gate.release()
                    await play.value
                    await stop.value
                    let information = await self.currentMediaInformation(controller)
                    XCTAssertNil(information)
                } else {
                    await controller.setPaused(true)
                    gate.release()
                    await play.value
                    let state = await controller.currentStateForTesting
                    XCTAssertEqual(state, .paused(request))
                    let information = await self.currentMediaInformation(controller)
                    XCTAssertEqual(information?.width, 1_280,
                        "A paused prepare must publish without relying on activation")
                    XCTAssertNil(registry.outputResourceContextSnapshot()?.interval)
                }
            }
        }
    }

    func testProductionHLSAutomaticReplacementInvalidatesMediaBeforeRetirement() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        try await withProductionMediaController { controller, registry, factory, _ in
            await controller.play(.init(sourceProfileID: UUID(), channelID: "metadata-auto-replacement",
                streamURL: fixture.source, title: "Automatic replacement"))
            let old = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            let information = await self.currentMediaInformation(controller)
            XCTAssertEqual(information?.width, 1_280)
            let backend = try XCTUnwrap(factory.backend)
            let authority = try XCTUnwrap(backend.backendPublicationReplacementAuthoritySlot.currentAuthority())
            XCTAssertTrue(authority.requestReplacement(), "Use the actual Registry-signed replacement authority")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var observed = await self.currentMediaInformation(controller)
            while observed != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                observed = await self.currentMediaInformation(controller)
            }
            XCTAssertNil(observed,
                "The registered replacement runner must invalidate even if later retirement or handoff fails")
            XCTAssertNil(registry.preparedHLSMediaInformation(for: old))
            await controller.refreshPreparedMediaInformation(for: old)
            let afterOldRefresh = await self.currentMediaInformation(controller)
            XCTAssertNil(afterOldRefresh)
        }
    }

    func testProductionHLSStopDuringReplacementPrefixJoinsAfterUnclaimedSuspendTimeout() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        let gate = HLSMediaInformationPrefixGate(bypassingFirstWaits: 1)
        defer { gate.release() }
        let factory = AudioReviewProductionBackendFactory(factory: SystemPlaybackBackendFactory(
            hlsGraphFactory: { source, invocation, ledger, failureSink in
                let authority = try SystemHLSMediaGraphAuthority(
                    lifecycle: invocation.outputLifecycleEpoch, failureSink: failureSink)
                return HLSMediaGraphAssembler(sourceURL: source, applicationLedger: ledger,
                    graph: HLSMediaInformationGatedGraph(
                        graph: SystemHLSDeliveryGraph(authority: authority), gate: gate))
            }))
        try await withProductionMediaController(factory: factory) { controller, registry, factory, _ in
            // Release the prefix before this fixture's error path begins its own Stop.
            defer { gate.release() }
            await controller.play(.init(sourceProfileID: UUID(), channelID: "replacement-stop-deadline",
                streamURL: fixture.source, title: "Replacement stop deadline"))
            let old = try XCTUnwrap(registry.outputResourceContextSnapshot()?.interval?.outputLifecycle)
            let backend = try XCTUnwrap(factory.backend)
            let authority = try XCTUnwrap(backend.backendPublicationReplacementAuthoritySlot.currentAuthority())
            XCTAssertTrue(authority.requestReplacement())
            let prefixDeadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !gate.isWaiting, ContinuousClock.now < prefixDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(gate.isWaiting, "Hold the actual successor prefix before AVPlayer installation")
            let preparing = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let prepare = try XCTUnwrap(preparing.sourceTask)
            XCTAssertFalse(preparing.prepared)
            XCTAssertNil(preparing.interval)
            let stop = Task { await controller.stop() }
            let timeoutDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while registry.outputResourceContextSnapshot()?.suspendTimedOut != true,
                  ContinuousClock.now < timeoutDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let timedOut = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let suspend = try XCTUnwrap(timedOut.suspend)
            XCTAssertTrue(timedOut.suspendTimedOut, "Keep the real one-second suspend deadline")
            XCTAssertTrue(timedOut.suspendRequiresRetirement)
            XCTAssertFalse(timedOut.suspendConfirmed)
            XCTAssertFalse(timedOut.retirementConfirmed)
            XCTAssertEqual(registry.phase(of: suspend.task), .terminal(.canceled))
            XCTAssertEqual(registry.phase(of: prepare), .cancelRequested,
                "Timeout must retain the physically blocked successor prepare")
            XCTAssertNotEqual(suspend.lifecycle, old)
            XCTAssertNil(registry.preparedHLSMediaInformation(for: old))
            gate.release()
            await stop.value
            await registry.joinOwnedTerminalCleanup()
            XCTAssertNil(registry.outputResourceContextSnapshot(),
                "The successor's real prepare-failure retirement must finish cleanup after its physical join")
        }
    }

    func testRealHLSReplacementSnapshotsAreScopedToProducingOutputLifecycle() async throws {
        let fixture = try makeProductionFixture(named: "task22-progressive-h264-aac-16s.ts")
        defer { fixture.server?.stop() }
        let first = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_201)
        let second = OutputLifecycleEpoch(backendIdentity: first.backendIdentity, outputNonce: 22_202)
        var previous: HLSOutputItemBundle?
        for lifecycle in [first, second] {
            let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
            let assembler = HLSMediaGraphAssembler(sourceURL: fixture.source,
                applicationLedger: HLSDeliveryApplicationChargeLedger(),
                graph: SystemHLSDeliveryGraph(authority: authority))
            let bundle = HLSOutputItemBundle(
                startProducer: { try await assembler.startUntilPlayablePrefix() },
                retireProducer: { await assembler.retireAndAwaitReceipt() })
            XCTAssertNil(bundle.preparedMediaInformation(for: lifecycle))
            do {
                try await bundle.prepareProducer()
                let snapshot = try XCTUnwrap(bundle.preparedMediaInformation(for: lifecycle))
                XCTAssertEqual(snapshot.information?.width, 1_280)
                XCTAssertEqual(snapshot.information?.sourceFrameRate, MediaRational(num: 25, den: 1))
                XCTAssertEqual(snapshot.information?.airPlayOutputMode, .audioTranscode)
                XCTAssertNil(bundle.preparedMediaInformation(for: lifecycle == first ? second : first),
                    "A new graph can restart demux generation zero but cannot reuse an output lifecycle")
                XCTAssertNil(previous?.preparedMediaInformation(for: first))
            } catch {
                _ = await bundle.retireProducerGraph()
                throw error
            }
            // Production's coordinator retires the preparation history before
            // the producer graph. Keep the stale bundle alias, not its active
            // singleton history domain, while the successor creates a prefix.
            let evidence = try XCTUnwrap(bundle.replacement.evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource)
            evidence.retirePreparation()
            let retired = await bundle.retireProducerGraph()
            XCTAssertTrue(retired)
            XCTAssertNil(bundle.preparedMediaInformation(for: lifecycle))
            previous = bundle
        }
    }

    private func currentMediaInformation(_ controller: PlaybackController) async -> PlaybackMediaInformation? {
        var iterator = await controller.playbackMediaInformation().makeAsyncIterator()
        return await iterator.next() ?? nil
    }

    private func mediaControllerDiagnostic(_ controller: PlaybackController,
                                           registry: ControlTaskRegistry) async -> String {
        let state = await controller.currentStateForTesting
        return "state=\(state); context=\(String(describing: registry.outputResourceContextSnapshot())); "
            + "resourceBytes=\(PlaybackResourceContextLedger.shared.chargedBytes); "
            + "applicationBytes=\(HLSDeliveryApplicationChargeLedger.shared.chargedBytes); "
            + "callbacks=\(AVPlayerSDKCallbackLease.occupiedCount); "
            + "history=\(PlaybackDiagnosticTracker.shared.recentHistory)"
    }

    private func withProductionMediaController(
        factory: AudioReviewProductionBackendFactory = AudioReviewProductionBackendFactory(),
        _ body: (PlaybackController, ControlTaskRegistry, AudioReviewProductionBackendFactory,
                 FakeAudioSessionSDK) async throws -> Void
    ) async throws {
        let resourceBaseline = PlaybackResourceContextLedger.shared.chargedBytes
        let applicationBaseline = HLSDeliveryApplicationChargeLedger.shared.chargedBytes
        let callbackBaseline = AVPlayerSDKCallbackLease.occupiedCount
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
        // The SDK route/session is controlled by this fixture. Native AVPlayer
        // audio notifications from other fixtures must not mutate that fake
        // session's safety epochs halfway through prepare or replacement.
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress,
            notificationCenter: NotificationCenter())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk, monitor: monitor)
        let routes = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: routes, backendFactory: factory)
        var bodyError: (any Error)?
        do { try await body(controller, registry, factory, sdk) }
        catch { bodyError = error }
        await controller.stop()
        await registry.joinOwnedTerminalCleanup()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (PlaybackResourceContextLedger.shared.chargedBytes > resourceBaseline
               || HLSDeliveryApplicationChargeLedger.shared.chargedBytes > applicationBaseline
               || AVPlayerSDKCallbackLease.occupiedCount > callbackBaseline),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let diagnostic = await mediaControllerDiagnostic(controller, registry: registry)
        XCTAssertNil(registry.outputResourceContextSnapshot(), diagnostic)
        XCTAssertLessThanOrEqual(PlaybackResourceContextLedger.shared.chargedBytes, resourceBaseline, diagnostic)
        XCTAssertLessThanOrEqual(HLSDeliveryApplicationChargeLedger.shared.chargedBytes, applicationBaseline, diagnostic)
        XCTAssertLessThanOrEqual(AVPlayerSDKCallbackLease.occupiedCount, callbackBaseline, diagnostic)
        if let bodyError { throw bodyError }
    }

    func testProductionDefaultLargeH264IDRsPreserveThreeGOPsAndSourceAAC44100() async throws {
        let probe = try await exerciseProductionLargeIDRFixture(
            named: "homepod-large-idr-h264-1080p30-aac44100.mp4",
            codec: .h264, width: 1_920, height: 1_080, frameRate: 30,
            audioRate: 44_100, minimumIDRBytes: 600_000)
        try await assertLargeIDRNativeOwnersRetired(probe)
    }

    func testProductionDefaultLargeHEVCMain10HLGIDRsPreserveThreeGOPs() async throws {
        let probe = try await exerciseProductionLargeIDRFixture(
            named: "homepod-large-idr-hevc-hlg-2160p50-aac48000.mp4",
            codec: .hevc, width: 3_840, height: 2_160, frameRate: 50,
            audioRate: 48_000, minimumIDRBytes: 500_000)
        try await assertLargeIDRNativeOwnersRetired(probe)
    }

    private func exerciseProductionLargeIDRFixture(named name: String, codec: VideoCodec,
        width: Int, height: Int, frameRate: Int32, audioRate: Int32,
        minimumIDRBytes: Int) async throws -> HLSWriterAcceptanceProbe {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: nil, subdirectory: "Video"))
        // This authored aligned-source fixture has one genuine acquisition GOP
        // before its three output GOPs. Its declared AAC phase puts a complete AU
        // on the eligible IDR; it does not model every broadcast's A/V phase. The
        // MP4 is the exact admitted-AU decoding oracle, not a direct source prefix.
        let transport = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: (name as NSString).deletingPathExtension + ".ts",
            withExtension: nil, subdirectory: "Video"))
        let origin = try NativeHLSHTTPFixture(resources: [
            "/source.ts": .init(data: Data(contentsOf: transport), contentType: "video/mp2t")])
        let resolver = URLSessionPlaybackSourceResolver()
        let probe = HLSWriterAcceptanceProbe()
        var assembler: HLSMediaGraphAssembler?
        var failure: (any Error)?
        var stage = "fixture-timeline"
        do {
            try assertLargeIDRAcquisitionTimeline(sourceURL: origin.url("source.ts"),
                frameRate: frameRate, audioRate: audioRate)
            stage = "resolve"
            // Keep the original paid, inspected source owner. Real source AAC
            // must pass through at 44.1/48 kHz without compatibility calibration.
            let context = try sourceContext(url: origin.url("source.ts"))
            let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
            let source = try await resolver.resolve(context, reason: .initial)
            stage = "probe"
            let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            let facts = try await HLSCompatibilityProbe().inspect(source, retainingFacts: factsCharge)
            let videoFacts = try XCTUnwrap(facts.media.first?.video)
            print("LARGE_IDR_PREFLIGHT codec=\(codec) bytes=\(facts.inspectedBytes) scan=\(videoFacts.scan) " +
                "parameterSetsValidated=\(videoFacts.parameterSetsValidated) profile=\(videoFacts.profile)")
            XCTAssertEqual(videoFacts.codec, codec)
            XCTAssertEqual(videoFacts.width, Int32(width))
            XCTAssertEqual(videoFacts.height, Int32(height))
            if codec == .hevc {
                XCTAssertEqual(videoFacts.bitDepth, 10)
                XCTAssertEqual(videoFacts.colorTransfer, .hlg)
                XCTAssertEqual(videoFacts.colorPrimaries, .bt2020)
            }
            XCTAssertEqual(facts.media.first?.audio.first?.sampleRate, audioRate)
            stage = "plan"
            let plan = try HLSPlaybackPlanner.makePlan(source: source, facts: facts,
                capabilities: .init(videoProfiles: [codec: [codec == .h264 ? 100 : 2]],
                    compressedAudioCodecs: [.aac], supportsGenerated: true))
            XCTAssertEqual(plan.transport, .generated)
            XCTAssertEqual(plan.video, .remux)
            XCTAssertEqual(plan.audio, .passthrough(.aac))
            let owned = HLSOwnedSourcePlan(source: source, facts: facts, plan: plan,
                resolver: resolver, sourceCharge: sourceCharge, factsCharge: factsCharge)
            let owner = try XCTUnwrap(context.owner)
            let video = SyntheticAACContinuityCapture(codecPrefix: codec == .h264 ? "avc1" : "hvc1")
            let audio = SyntheticAACContinuityCapture()
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce),
                acceptanceProbe: probe,
                // Three GOPs use the supported finite-EOF publication floor.
                // Writer ownershipLimits remains nil, and the real graph's
                // maximumPassthroughInterval remains the production six seconds.
                initialWindowMinimumSeconds: 3, generatedSource: owned)
            authority.publicationForTesting.installBeforeReceiveForTesting {
                video.receive($0); audio.receive($0)
            }
            stage = "graph"
            let graph = HLSMediaGraphAssembler(sourceURL: origin.url("source.ts"),
                applicationLedger: HLSDeliveryApplicationChargeLedger(),
                graph: SystemHLSDeliveryGraph(authority: authority))
            assembler = graph
            let prefix: AVPlayerItemReplacementBundle
            do {
                prefix = try await graph.startUntilPlayablePrefix()
            } catch {
                let observation = probe.snapshot
                XCTFail("Large-IDR default writer did not append/publish: nativeConstructors=\(observation.nativeWriterCount) " +
                    "inputReservations=\(observation.acceptedInputCount) error=\(authority.failureDescriptionForDiagnostics ?? String(describing: error)). " +
                    "Constructor/start success alone does not cover the first compressed append.")
                throw error
            }
            XCTAssertEqual(prefix.mediaInformation?.outputFrameRate, Double(frameRate))
            XCTAssertEqual(prefix.mediaInformation?.airPlayOutputMode, .remux)
            let complete = await authority.finishAllTracksAtNaturalEOF()
            XCTAssertTrue(complete, authority.failureDescriptionForDiagnostics ?? "Large-IDR source did not reach EOF")
            XCTAssertEqual(authority.audioCalibrationAttemptsForTesting, 0,
                "Source AAC must not silently switch to a newly encoded 48 kHz rendition")
            let publication = try XCTUnwrap(authority.publicationForTesting.publisher?.visible)
            XCTAssertEqual(publication.sourceAACTerminalBindings.count, 1)
            XCTAssertTrue(publication.aacTerminalBindings.isEmpty)
            let sourceAAC = try XCTUnwrap(publication.sourceAACTerminalBindings.values.first)
            let seal = try XCTUnwrap(sourceAAC.finalSeal)
            let sourceStart = ExactMediaTime(value: 10, timescale: 1)
            XCTAssertEqual(sourceAAC.configuration.origin.sourceTime, .init(value: 5, timescale: 1),
                "The publishing graph itself must choose the post-validation source IDR")
            XCTAssertEqual(sourceAAC.configuration.origin.source, .videoIDR)
            XCTAssertEqual(sourceAAC.configuration.firstPresentationTime, sourceStart,
                "The real timeline must map the source's eligible 5-second IDR to the production 10-second origin")
            XCTAssertEqual(try seal.writtenStart.subtracting(seal.timelineOffset), sourceStart)
            let nativeStart = seal.writtenStart.cmTime
            let sourceAudioSamples = Int64((15 * audioRate + 1_023) / 1_024) * 1_024
            let audioDuration = CMTime(value: sourceAudioSamples, timescale: audioRate)
            let nativeAudioEnd = CMTimeAdd(nativeStart, audioDuration)
            let nativeVideoEnd = CMTimeAdd(nativeStart, CMTime(value: 15, timescale: 1))
            XCTAssertEqual(CMTimeCompare(seal.writtenEnd.cmTime, nativeAudioEnd), 0)
            XCTAssertEqual(seal.inputCount, UInt64(sourceAudioSamples / 1_024))
            XCTAssertEqual(probe.snapshot.nativeWriterCount, 2,
                "One video writer and one source-AAC writer must cover all three GOPs")
            let videoRecords = try video.snapshot()
            let audioRecords = try audio.snapshot()
            let videoMedia = try assertLargeIDRFragmentSequence(videoRecords, expectedSamples: UInt64(frameRate * 5),
                expectedStart: nativeStart, expectedEnd: nativeVideoEnd)
            let audioMedia = try assertLargeIDRFragmentSequence(audioRecords, expectedSamples: nil,
                expectedTotalSamples: UInt64(sourceAudioSamples / 1_024),
                expectedStart: nativeStart, expectedEnd: nativeAudioEnd)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            func writeOriginal(_ records: [SyntheticAACContinuityCapture.Record],
                               media: [SyntheticAACContinuityCapture.Record], name: String) throws -> URL {
                var bytes = try XCTUnwrap(records.first { $0.kind == .initialization }).bytes
                for record in media { bytes.append(record.bytes) }
                let url = directory.appendingPathComponent(name)
                try bytes.write(to: url)
                return url
            }
            // Preserve the native mfhd/tfdt/trun and sole canonical init exactly.
            let videoOutput = try writeOriginal(videoRecords, media: videoMedia, name: "original-video.mp4")
            let audioOutput = try writeOriginal(audioRecords, media: audioMedia, name: "original-audio.mp4")
            stage = "output-decode"
            try await inspectLargeIDRVideo(videoOutput, width: width, height: height,
                frameRate: frameRate, minimumIDRBytes: minimumIDRBytes,
                initialization: try XCTUnwrap(videoRecords.first { $0.kind == .initialization }).bytes,
                media: videoMedia, expectedStart: nativeStart, expectedEnd: nativeVideoEnd)
            let audioAsset = AVURLAsset(url: audioOutput)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let audioTrack = try XCTUnwrap(audioTracks.first)
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            let audioFormat = try XCTUnwrap(audioFormats.first)
            let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat))
            XCTAssertEqual(description.pointee.mSampleRate, Double(audioRate))
            let audioTimescale = try await audioTrack.load(.naturalTimeScale)
            XCTAssertEqual(audioTimescale, audioRate)
            let firstAudio = try SyntheticAACFragmentInspector.inspect(try XCTUnwrap(audioMedia.first), label: "LARGE_IDR_AUDIO_START")
            let lastAudio = try SyntheticAACFragmentInspector.inspect(try XCTUnwrap(audioMedia.last), label: "LARGE_IDR_AUDIO_END")
            XCTAssertEqual(CMTimeCompare(CMTime(value: Int64(firstAudio.decodeTime), timescale: audioTimescale), nativeStart), 0)
            XCTAssertEqual(CMTimeCompare(CMTime(value: Int64(lastAudio.decodeTime + lastAudio.sampleCount * 1_024),
                timescale: audioTimescale), nativeAudioEnd), 0)
            // The MP4 oracle has elst + roll sample groups; Apple-HLS output
            // has different container priming semantics. Compare original AUs
            // and naturally drained raw PCM, never subtract an assumed delay.
            let audioInit = try XCTUnwrap(audioRecords.first { $0.kind == .initialization }).bytes
            var rawAudio: [SyntheticRawMediaSample] = []
            let audioInspectionLedger = HLSDeliveryApplicationChargeLedger()
            for record in audioMedia {
                let inspection = try FMP4CompressedAudioInspection.sourceAACFragment(
                    initialization: audioInit, media: record.bytes, configuration: sourceAAC.configuration,
                    expectedDuration: ExactMediaTime(try XCTUnwrap(record.duration)),
                    applicationLedger: audioInspectionLedger)
                let mdat = try XCTUnwrap(SyntheticAACFragmentInspector.boxes(record.bytes).first { $0.type == "mdat" })
                var payloadEnd = mdat.payload
                for index in 0..<inspection.sampleCount {
                    let sample = try XCTUnwrap(inspection.sample(at: index))
                    let expectedPTS = try ExactMediaTime(nativeStart).adding(
                        .init(value: Int64(rawAudio.count) * 1_024, timescale: audioRate))
                    guard rawAudio.count < 1_024, Int(sample.decodeOrdinal) == index,
                          sample.presentationRange.start == expectedPTS,
                          sample.presentationRange.duration == ExactMediaTime(value: 1_024, timescale: audioRate),
                          sample.byteSpan.lowerBound == payloadEnd, !sample.byteSpan.isEmpty,
                          sample.byteSpan.upperBound <= mdat.end else { throw AACRenditionFailure.invalidInput }
                    let payload = record.bytes.subdata(in: sample.byteSpan)
                    rawAudio.append(.init(start: sample.presentationRange.start,
                        duration: sample.presentationRange.duration, size: payload.count,
                        digest: Data(SHA256.hash(data: payload))))
                    payloadEnd = sample.byteSpan.upperBound
                }
                guard payloadEnd == mdat.end else { throw AACRenditionFailure.invalidInput }
            }
            XCTAssertEqual(audioInspectionLedger.chargedBytes, 0)
            XCTAssertEqual(rawAudio.count, Int(sourceAudioSamples / 1_024))
            try printSyntheticAACInitialization(audioInit)
            let originalRaw = try await inspectSyntheticAACRawPCM(file, sampleRate: audioRate, rawSamples: rawAudio)
            let decodedRaw = try await inspectSyntheticAACRawPCM(audioOutput, sampleRate: audioRate, rawSamples: rawAudio)
            XCTAssertEqual(originalRaw.statistics.frames, Int(sourceAudioSamples))
            XCTAssertEqual(decodedRaw.statistics.frames, Int(sourceAudioSamples))
            XCTAssertEqual(decodedRaw.format, originalRaw.format,
                "Raw decoding must preserve the original AAC stream description")
            XCTAssertEqual(decodedRaw.pcmSHA256, originalRaw.pcmSHA256,
                "Every original AAC AU must produce the identical complete raw PCM sequence")
            XCTAssertEqual(decodedRaw.statistics.silentWindows, 0)
            // Standalone container decoding remains observable, but is not an
            // HLS playback or physical HomePod audible-endpoint oracle.
            let original = try await inspectSyntheticAACPCM(file, sampleRate: audioRate)
            let decoded = try await inspectSyntheticAACPCM(audioOutput, sampleRate: audioRate)
            print("LARGE_IDR_AAC_CONTAINER_DIAGNOSTIC rate=\(audioRate) " +
                "oracleFrames=\(original.frames) nativeFrames=\(decoded.frames) " +
                "oracleFirst=\(String(describing: original.firstPresentationTime)) " +
                "oracleEnd=\(String(describing: original.endPresentationTime)) " +
                "nativeFirst=\(String(describing: decoded.firstPresentationTime)) " +
                "nativeEnd=\(String(describing: decoded.endPresentationTime)) physicalAudibleEndpointVerified=false")
            XCTAssertGreaterThan(original.frames, 0)
            XCTAssertGreaterThan(decoded.frames, 0)
            XCTAssertLessThanOrEqual(decoded.maximumGapSamples, 1)
            XCTAssertEqual(decoded.silentWindows, 0)
            print("LARGE_IDR_NATIVE codec=\(codec) frameRate=\(frameRate) gops=\(videoMedia.count) " +
                "sourceAACRate=\(audioRate) originalBytes=true physicalHomePodVerified=false")
        } catch {
            print("LARGE_IDR_FAILURE codec=\(codec) phase=\(stage) error=\(error)")
            failure = error
        }
        if let assembler {
            let retired = await assembler.retireAndAwaitReceipt()
            XCTAssertTrue(retired, "Even a first-append rejection must join the real graph's cleanup")
            XCTAssertEqual(assembler.currentPhase, .retired)
        }
        await resolver.invalidate()
        await origin.close()
        if let failure { throw failure }
        return probe
    }

    private func joinedLargeIDRFixtureEvents(sourceURL: URL) throws -> [DemuxEvent] {
        let recorder = DemuxEventRecorder()
        let io = DispatchQueue(label: "org.vplayer.tests.large-idr-prepass-io")
        let callbacks = PlaybackSerialExecutor(label: "org.vplayer.tests.large-idr-prepass-callbacks")
        let demuxer = FFmpegDemuxer(executor: callbacks, timeoutUS: 5_000_000, ioQueue: io)
        var startFailure: (any Error)?
        do {
            try demuxer.start(url: sourceURL, sink: recorder.record)
            _ = recorder.waitForTerminal(timeout: 10)
        } catch { startFailure = error }
        demuxer.cancel()
        // A terminal callback precedes runReturned/handle.destroy. Join that
        // original IO tail first, then the final callback's return, on all paths.
        let ioTail = DispatchSemaphore(value: 0)
        io.async { ioTail.signal() }
        let ioJoined = ioTail.wait(timeout: .now() + 10) == .success
        let observed = recorder.waitForTerminal(timeout: startFailure == nil ? 5 : 0)
        let terminalObserved = observed.contains { event in
            switch event { case .endOfStream, .cancelled, .failure: true; default: false }
        }
        let callbackTail = DispatchSemaphore(value: 0)
        callbacks.submit { callbackTail.signal() }
        let callbacksJoined = callbackTail.wait(timeout: .now() + 5) == .success
        XCTAssertTrue(ioJoined, "Prepass native run/destroy must finish before any production graph starts")
        XCTAssertTrue(callbacksJoined, "Prepass terminal callback and queued event aliases must finish")
        guard ioJoined, callbacksJoined, startFailure != nil || terminalObserved else {
            throw HLSSourceError.deadline
        }
        if let startFailure { throw startFailure }
        return recorder.events
    }

    private func assertLargeIDRAcquisitionTimeline(sourceURL: URL,
        frameRate: Int32, audioRate: Int32) throws {
        var events = try joinedLargeIDRFixtureEvents(sourceURL: sourceURL)
        defer { events.removeAll(keepingCapacity: false) }
        XCTAssertTrue(events.contains { if case .endOfStream = $0 { true } else { false } })
        var videoPacketCount = 0
        var inputIDRs = 0
        for event in events {
            if case .packet(let packet) = event, case .video = packet.codec {
                videoPacketCount += 1
                if packet.isKey { inputIDRs += 1 }
            }
        }
        XCTAssertEqual(videoPacketCount, Int(frameRate * 20))
        XCTAssertEqual(inputIDRs, 4)
        let timeline = HLSTimelineCoordinator()
        defer { timeline.retireCompressedGeneration() }
        var origins: [MediaOriginReceipt] = []
        var terminal: [HLSTimelineTerminal] = []
        var firstAudio: (decision: HLSAudioBoundaryDecision, start: ExactMediaTime, duration: ExactMediaTime?)?
        var audioCount = 0
        var videoCount = 0
        var selectedIDRs = 0
        var videoEnd = ExactMediaTime(value: 0, timescale: 1)
        for event in events {
            for emission in try timeline.consume(event) {
                switch emission {
                case .originEstablished(let origin): origins.append(origin)
                case .terminal(let value): terminal.append(value)
                case .audioSample(let sample):
                    if firstAudio == nil {
                        firstAudio = (sample.boundaryDecision, sample.timing.presentationTimeStamp, sample.timing.duration)
                    }
                    audioCount += 1
                case .videoSample(let sample):
                    videoCount += 1
                    if sample.source.randomAccessKind == .h264IDR || sample.source.randomAccessKind == .hevcIDR {
                        selectedIDRs += 1
                    }
                    videoEnd = try sample.timing.presentationTimeStamp.adding(XCTUnwrap(sample.timing.duration))
                default: break
                }
            }
        }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.sourceTime, .init(value: 5, timescale: 1))
        XCTAssertEqual(origins.first?.effectiveStart, .init(value: 10, timescale: 1))
        XCTAssertEqual(videoCount, Int(frameRate * 15))
        XCTAssertEqual(selectedIDRs, 3)
        XCTAssertEqual(videoEnd, .init(value: 25, timescale: 1))
        XCTAssertEqual(audioCount, Int((15 * audioRate + 1_023) / 1_024))
        let first = try XCTUnwrap(firstAudio)
        XCTAssertEqual(first.decision, .unchanged,
            "A crossing AAC AU would legitimately select compatibility conversion, outside this aligned-source control")
        XCTAssertEqual(first.start, .init(value: 10, timescale: 1))
        XCTAssertEqual(first.duration, .init(value: 1_024, timescale: audioRate))
        XCTAssertEqual(terminal, [.endOfStream])
        print("LARGE_IDR_TIMELINE sourceOrigin=\(origins.first?.sourceTime.cmTime.seconds ?? -1) " +
            "effectiveOrigin=\(origins.first?.effectiveStart.cmTime.seconds ?? -1) admittedVideoFrames=\(videoCount) " +
            "admittedIDRs=\(selectedIDRs) admittedAudioAUs=\(audioCount) firstAACUntrimmed=\(first.decision == .unchanged)")
    }

    private func assertLargeIDRFragmentSequence(_ records: [SyntheticAACContinuityCapture.Record],
        expectedSamples: UInt64?, expectedTotalSamples: UInt64? = nil,
        expectedStart: CMTime, expectedEnd: CMTime) throws -> [SyntheticAACContinuityCapture.Record] {
        XCTAssertEqual(records.filter { $0.kind == .initialization }.count, 1)
        let media = records.filter { $0.kind == .media }.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(media.count, 3, "The same writer must publish three actual five-second GOP fragments")
        XCTAssertEqual(Set(records.map(\.writer)).count, 1)
        let first = try XCTUnwrap(media.first)
        let last = try XCTUnwrap(media.last)
        XCTAssertEqual(CMTimeCompare(try XCTUnwrap(first.start), expectedStart), 0,
            "Video and source AAC must share the same authenticated native start mapping")
        XCTAssertEqual(CMTimeCompare(CMTimeAdd(try XCTUnwrap(last.start), try XCTUnwrap(last.duration)), expectedEnd), 0,
            "The final compressed report must include the complete source endpoint")
        let fragments = try media.map { try SyntheticAACFragmentInspector.inspect($0, label: "LARGE_IDR_FRAGMENT") }
        if let expectedTotalSamples {
            XCTAssertEqual(fragments.reduce(UInt64(0)) { $0 + $1.sampleCount }, expectedTotalSamples,
                "The original fragment truns must account for every complete source AAC access unit")
        }
        XCTAssertEqual(fragments.map(\.sequence), [1, 2, 3], "Native sequence numbers must not be rewritten or reset")
        for (previous, current) in zip(media, media.dropFirst()) {
            XCTAssertEqual(current.sequence, previous.sequence + 1)
            let end = CMTimeAdd(try XCTUnwrap(previous.start), try XCTUnwrap(previous.duration))
            XCTAssertEqual(CMTimeSubtract(try XCTUnwrap(current.start), end).seconds, 0, accuracy: 1.0 / 44_100)
        }
        for (index, fragment) in fragments.enumerated() {
            if let expectedSamples {
                XCTAssertEqual(fragment.sampleCount, expectedSamples)
                XCTAssertEqual(try XCTUnwrap(media[index].duration).seconds, 5, accuracy: 0.0001)
            } else if index > 0 {
                let previous = fragments[index - 1]
                XCTAssertEqual(fragment.decodeTime, previous.decodeTime + previous.sampleCount * 1_024,
                    "Every original source-AAC AU must retain its native decode timestamp")
            }
        }
        return media
    }

    private func inspectLargeIDRVideo(_ url: URL, width: Int, height: Int,
        frameRate: Int32, minimumIDRBytes: Int, initialization: Data,
        media: [SyntheticAACContinuityCapture.Record], expectedStart: CMTime, expectedEnd: CMTime) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let timescale = try await track.load(.naturalTimeScale)
        XCTAssertEqual(timescale % frameRate, 0)
        let trackRange = try await track.load(.timeRange)
        let rawStart = try ExactMediaTime(expectedStart)
        let rawEnd = try ExactMediaTime(expectedEnd)
        let frameDuration = ExactMediaTime(value: 1, timescale: frameRate)
        let expectedFrames = Int(frameRate * 15)
        var rawSamples: [SyntheticRawMediaSample] = []
        for record in media {
            rawSamples += try SyntheticAACFragmentInspector.unreorderedSamples(initialization: initialization,
                media: record.bytes, timescale: timescale, maximumSamples: 1_024 - rawSamples.count)
        }
        guard rawSamples.count == expectedFrames else { throw AACRenditionFailure.invalidInput }
        for (ordinal, raw) in rawSamples.enumerated() {
            let expected = try rawStart.adding(.init(value: Int64(ordinal), timescale: frameRate))
            guard raw.start == expected, raw.duration == frameDuration else {
                throw NSError(domain: "SyntheticVideoFragment", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Native duration or PTS differs at ordinal \(ordinal): \(raw)"])
            }
        }
        let lastRaw = try XCTUnwrap(rawSamples.last)
        XCTAssertEqual(try lastRaw.start.adding(lastRaw.duration), rawEnd,
            "Native trun durations, including the final GOP, must reach the original raw endpoint")

        let compressed = try AVAssetReader(asset: asset)
        let compressedOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let compressedProvider = compressed.outputProvider(for: compressedOutput)
        try compressed.start()
        defer { if compressed.status == .reading { compressed.cancelReading() } }
        var byteTiming = SyntheticReaderByteTiming()
        var compressedFirst: ExactMediaTime?
        var compressedEnd: ExactMediaTime?
        var compressedCursor = HLSFixtureVideoReaderCursor(kind: .compressed)
        while let ready = try await compressedProvider.next() {
            guard try compressedCursor.consumesMedia(ready) else { continue }
            let sample = try makeOwnedReaderFixtureSample(copying: ready)
            let ordinal = byteTiming.frames
            guard ordinal < rawSamples.count else { throw AACRenditionFailure.invalidInput }
            let raw = rawSamples[ordinal]
            let size = CMSampleBufferGetTotalSampleSize(sample)
            guard size == raw.size else { throw AACRenditionFailure.invalidInput }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            // The cursor permits extra logical backing. Hash exactly the sample's
            // declared bytes, also supporting noncontiguous CMBlockBuffer backing.
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw AACRenditionFailure.framework(status) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            try byteTiming.observe(raw: raw, reader: .init(size: size, digest: Data(SHA256.hash(data: bytes)),
                pts: pts, duration: duration))
            if compressedFirst == nil { compressedFirst = try ExactMediaTime(pts) }
            compressedEnd = try ExactMediaTime(pts).adding(ExactMediaTime(duration))
            if ordinal % Int(frameRate * 5) == 0 {
                XCTAssertGreaterThanOrEqual(size, minimumIDRBytes,
                    "The byte-verified native output must contain genuine large IDRs")
                XCTAssertGreaterThan(size * Int(2 * 6 * frameRate + 2), 64 * 1_024 * 1_024,
                    "This fixture must still expose the rejected old max-AU-times-window projection")
            }
        }
        guard compressed.status == .completed else {
            throw compressed.error ?? AACRenditionFailure.invalidInput
        }
        XCTAssertEqual(compressedCursor.mediaSamples, expectedFrames)
        // No translation is usable until every payload/duration/PTS ordinal,
        // exact expected count and both independently parsed raw endpoints pass.
        let mapping = try byteTiming.coverage(expectedSamples: expectedFrames, rawStart: rawStart, rawEnd: rawEnd)
        let mappedStart = try mapping.presentationTime(forRawTime: rawStart)
        let mappedEnd = try mapping.presentationTime(forRawTime: rawEnd)
        XCTAssertEqual(try XCTUnwrap(compressedFirst), mappedStart)
        XCTAssertEqual(try XCTUnwrap(compressedEnd), mappedEnd)
        XCTAssertEqual(try ExactMediaTime(trackRange.start), mappedStart)
        XCTAssertEqual(try ExactMediaTime(trackRange.start).adding(ExactMediaTime(trackRange.duration)), mappedEnd)
        print("LARGE_IDR_VIDEO_BYTE_PROOF frames=\(byteTiming.frames) markers=\(compressedCursor.skippedMarkers) " +
            "rawStart=\(rawStart) rawEnd=\(rawEnd) readerStart=\(mappedStart) readerEnd=\(mappedEnd) " +
            "\(byteTiming.diagnostics)")

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        var frames = 0
        var firstPTS: ExactMediaTime?
        var previousPTS: ExactMediaTime?
        var decodedEnd: ExactMediaTime?
        var decodedCursor = HLSFixtureVideoReaderCursor(kind: .decoded)
        while let ready = try await provider.next() {
            guard try decodedCursor.consumesMedia(ready) else { continue }
            let sample = try makeOwnedReaderFixtureSample(copying: ready)
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(image), width)
            XCTAssertEqual(CVPixelBufferGetHeight(image), height)
            guard frames < rawSamples.count else { throw AACRenditionFailure.invalidInput }
            let raw = rawSamples[frames]
            let pts = try ExactMediaTime(CMSampleBufferGetPresentationTimeStamp(sample))
            try mapping.requirePresentationTime(pts, forRawTime: raw.start)
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isValid {
                XCTAssertEqual(try ExactMediaTime(duration), raw.duration,
                    "A declared decoded duration must agree with its original compressed sample")
            }
            if firstPTS == nil { firstPTS = pts }
            if let previousPTS {
                XCTAssertEqual(try pts.subtracting(previousPTS), frameDuration,
                    "Decoded frame cadence must survive GOP boundaries")
            }
            previousPTS = pts
            decodedEnd = try pts.adding(raw.duration)
            frames += 1
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(frames, expectedFrames, "Decode every original output frame, including the final GOP")
        XCTAssertEqual(decodedCursor.mediaSamples, frames)
        XCTAssertEqual(try XCTUnwrap(firstPTS), mappedStart)
        XCTAssertEqual(try XCTUnwrap(decodedEnd), mappedEnd,
            "The final decoded frame must reach the byte-verified original video endpoint")
        print("LARGE_IDR_VIDEO_DECODED frames=\(frames) markers=\(decodedCursor.skippedMarkers) " +
            "firstPTS=\(String(describing: firstPTS)) lastPTS=\(String(describing: previousPTS)) " +
            "end=\(String(describing: decodedEnd)) mappedEnd=\(mappedEnd)")
    }

    private func assertLargeIDRNativeOwnersRetired(_ probe: HLSWriterAcceptanceProbe) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.snapshot.liveInputCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let retired = probe.snapshot
        XCTAssertTrue(retired.isComplete)
        XCTAssertEqual(retired.liveInputCount, 0)
        XCTAssertEqual(retired.liveInputBytes, 0)
        XCTAssertEqual(retired.acceptedInputCount, retired.releasedInputCount)
        XCTAssertEqual(retired.evidenceCount, 0)
        XCTAssertEqual(retired.pendingCallbacks, 0)
    }

    func testSyntheticAACRawOrdinalsRejectChangedPayloadAndClockDrift() throws {
        let duration = ExactMediaTime(value: 1_024, timescale: 44_100)
        let first = SyntheticRawMediaSample(start: .init(value: 10, timescale: 1), duration: duration,
            size: 1, digest: Data(SHA256.hash(data: Data([0x21]))))
        let second = SyntheticRawMediaSample(start: try first.start.adding(duration), duration: duration,
            size: 1, digest: Data(SHA256.hash(data: Data([0x22]))))
        func reader(_ sample: SyntheticRawMediaSample, pts: ExactMediaTime) -> SyntheticReaderByteTiming.ReaderSample {
            .init(size: sample.size, digest: sample.digest, pts: pts.cmTime, duration: sample.duration.cmTime)
        }
        var exact = SyntheticReaderByteTiming()
        try exact.observe(raw: first, reader: reader(first, pts: .init(value: 0, timescale: 1)))
        try exact.observe(raw: second, reader: reader(second, pts: duration))
        XCTAssertEqual(exact.frames, 2, "The complete reader may use a different constant time origin")
        var changedPayload = SyntheticReaderByteTiming()
        XCTAssertThrowsError(try changedPayload.observe(raw: first,
            reader: reader(second, pts: .init(value: 0, timescale: 1))))
        var droppedHead = SyntheticReaderByteTiming()
        XCTAssertThrowsError(try droppedHead.observe(raw: first, reader: reader(second, pts: duration)))
        var shifted = SyntheticReaderByteTiming()
        try shifted.observe(raw: first, reader: reader(first, pts: .init(value: 0, timescale: 1)))
        XCTAssertThrowsError(try shifted.observe(raw: second, reader: reader(second,
            pts: duration.adding(.init(value: 1, timescale: 44_100)))))
        var duplicate = SyntheticReaderByteTiming()
        try duplicate.observe(raw: first, reader: reader(first, pts: .init(value: 0, timescale: 1)))
        XCTAssertThrowsError(try duplicate.observe(raw: second, reader: reader(first, pts: duration)))
        let repeatedPayload = SyntheticRawMediaSample(start: second.start, duration: duration,
            size: first.size, digest: first.digest)
        var repeatedTiming = SyntheticReaderByteTiming()
        try repeatedTiming.observe(raw: first, reader: reader(first, pts: .init(value: 0, timescale: 1)))
        XCTAssertThrowsError(try repeatedTiming.observe(raw: repeatedPayload,
            reader: reader(first, pts: .init(value: 0, timescale: 1))),
            "Identical payloads cannot select a different sample ordinal or conceal repeated PTS")
    }

    func testSyntheticVideoCoordinateProofRequiresEveryRawOrdinalAndEndpoint() throws {
        let start = ExactMediaTime(value: 10, timescale: 1)
        let duration = ExactMediaTime(value: 1, timescale: 30)
        let digest = Data(SHA256.hash(data: Data([1, 2, 3, 4])))
        let first = SyntheticRawMediaSample(start: start, duration: duration, size: 4, digest: digest)
        // Repeated genuine payloads are allowed, but never choose their own ordinal.
        let second = SyntheticRawMediaSample(start: try start.adding(duration), duration: duration,
            size: 4, digest: digest)
        let end = try second.start.adding(duration)
        func reader(_ pts: ExactMediaTime, size: Int = 4, hash: Data? = nil,
                    length: ExactMediaTime? = nil) -> SyntheticReaderByteTiming.ReaderSample {
            .init(size: size, digest: hash ?? digest, pts: pts.cmTime, duration: (length ?? duration).cmTime)
        }
        func firstObserved() throws -> SyntheticReaderByteTiming {
            var result = SyntheticReaderByteTiming()
            try result.observe(raw: first, reader: reader(.init(value: 0, timescale: 1)))
            return result
        }
        var proof = try firstObserved()
        XCTAssertThrowsError(try proof.coverage(expectedSamples: 2, rawStart: start, rawEnd: end),
            "A first-sample translation cannot authorize endpoint mapping")
        try proof.observe(raw: second, reader: reader(duration))
        let mapping = try proof.coverage(expectedSamples: 2, rawStart: start, rawEnd: end)
        XCTAssertEqual(try mapping.presentationTime(forRawTime: start), .init(value: 0, timescale: 1))
        XCTAssertEqual(try mapping.presentationTime(forRawTime: second.start), duration)
        XCTAssertEqual(try mapping.presentationTime(forRawTime: end), try duration.adding(duration))
        try mapping.requirePresentationTime(duration, forRawTime: second.start)
        XCTAssertThrowsError(try mapping.requirePresentationTime(
            duration.adding(.init(value: 1, timescale: 720_000)), forRawTime: second.start),
            "A shifted interior decoded frame must fail the completed compressed mapping")
        XCTAssertThrowsError(try mapping.requirePresentationTime(second.start, forRawTime: second.start),
            "Decoded output cannot select its own independent constant offset")
        XCTAssertThrowsError(try mapping.presentationTime(forRawTime: start.subtracting(duration)))
        XCTAssertThrowsError(try mapping.presentationTime(forRawTime: end.adding(duration)))
        XCTAssertThrowsError(try proof.coverage(expectedSamples: 1, rawStart: start, rawEnd: end))
        XCTAssertThrowsError(try proof.coverage(expectedSamples: 2, rawStart: second.start, rawEnd: end))
        XCTAssertThrowsError(try proof.coverage(expectedSamples: 2, rawStart: start, rawEnd: second.start))
        for fault in [reader(.init(value: 0, timescale: 1)),
                      reader(try duration.adding(.init(value: 1, timescale: 720_000))),
                      reader(duration, size: 3),
                      reader(duration, hash: Data(SHA256.hash(data: Data([4, 3, 2, 1])))),
                      reader(duration, length: .init(value: 1, timescale: 50))] {
            var invalid = try firstObserved()
            XCTAssertThrowsError(try invalid.observe(raw: second, reader: fault),
                "Duplicate, drifting, resized, changed or shortened samples must fail")
        }
        var rawReorder = try firstObserved()
        XCTAssertThrowsError(try rawReorder.observe(raw: first, reader: reader(duration)))
        var extra = proof
        let third = SyntheticRawMediaSample(start: end, duration: duration, size: 4, digest: digest)
        try extra.observe(raw: third, reader: reader(try duration.adding(duration)))
        XCTAssertThrowsError(try extra.coverage(expectedSamples: 2, rawStart: start, rawEnd: end))
    }

    func testSyntheticVideoFragmentSamplesRequireExactDurationsOffsetsAndPayloadCoverage() throws {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data {
            word(UInt32(payload.count + 8)) + Data(name.utf8) + payload
        }
        let tkhd = box("tkhd", word(0) + Data(count: 8) + word(1) + Data(count: 68))
        let mdhd = box("mdhd", word(0) + Data(count: 8) + word(720_000) + Data(count: 8))
        let trex = box("trex", word(0) + word(1) + word(1) + word(24_000) + word(4) + word(0))
        let initialization = box("moov", box("trak", tkhd + box("mdia", mdhd)) + box("mvex", trex))
        func fragment(duration: UInt32 = 24_000, size: UInt32 = 4, composition: UInt32 = 0,
                      offsetAdjustment: Int32 = 0, count: UInt32 = 2,
                      payload: Data = Data([1, 2, 3, 4, 5, 6, 7, 8]), useDefaults: Bool = false,
                      headerDuration: UInt32? = nil, headerSize: UInt32? = nil,
                      secondDuration: UInt32? = nil) -> Data {
            let headerFlags: UInt32 = 0x020000 | (headerDuration == nil ? 0 : 8) | (headerSize == nil ? 0 : 0x10)
            let tfhd = box("tfhd", word(headerFlags) + word(1) +
                (headerDuration.map { word($0) } ?? Data()) + (headerSize.map { word($0) } ?? Data()))
            let tfdt = box("tfdt", word(0) + word(7_200_000))
            func moof(_ offset: Int32) -> Data {
                let entries = useDefaults ? Data() :
                    word(duration) + word(size) + word(composition) + word(secondDuration ?? duration) + word(size) + word(composition)
                let trun = box("trun", word(useDefaults ? 1 : 0x000b01) + word(count) +
                    word(UInt32(bitPattern: offset)) + entries)
                return box("moof", box("mfhd", word(0) + word(1)) + box("traf", tfhd + tfdt + trun))
            }
            return moof(Int32(moof(0).count + 8) + offsetAdjustment) + box("mdat", payload)
        }
        func samples(_ bytes: Data) throws -> [SyntheticRawMediaSample] {
            try SyntheticAACFragmentInspector.unreorderedSamples(initialization: initialization, media: bytes,
                timescale: 720_000, maximumSamples: 2)
        }
        for defaults in [false, true] {
            let actual = try samples(fragment(useDefaults: defaults))
            XCTAssertEqual(actual.count, 2)
            XCTAssertEqual(actual.map(\.duration), [.init(value: 1, timescale: 30), .init(value: 1, timescale: 30)])
            XCTAssertEqual(actual[0].start, .init(value: 10, timescale: 1))
            XCTAssertEqual(actual[1].start, .init(value: 301, timescale: 30))
            XCTAssertEqual(actual.map(\.size), [4, 4])
            XCTAssertEqual(actual[0].digest, Data(SHA256.hash(data: Data([1, 2, 3, 4]))))
            XCTAssertEqual(actual[1].digest, Data(SHA256.hash(data: Data([5, 6, 7, 8]))))
        }
        let headerDefaults = try samples(fragment(useDefaults: true, headerDuration: 12_000))
        XCTAssertEqual(headerDefaults.map(\.duration), [.init(value: 1, timescale: 60), .init(value: 1, timescale: 60)])
        let runOverrides = try samples(fragment(headerDuration: 12_000, headerSize: 3))
        XCTAssertEqual(runOverrides.map(\.duration), [.init(value: 1, timescale: 30), .init(value: 1, timescale: 30)])
        XCTAssertEqual(runOverrides.map(\.size), [4, 4])
        let compensated = try samples(fragment(duration: 23_999, secondDuration: 24_001))
        XCTAssertEqual(try compensated[0].duration.adding(compensated[1].duration), .init(value: 1, timescale: 15))
        var timing = SyntheticReaderByteTiming()
        XCTAssertThrowsError(try timing.observe(raw: compensated[0], reader: .init(size: 4,
            digest: compensated[0].digest, pts: .zero, duration: CMTime(value: 1, timescale: 30))),
            "Compensating native duration changes must not hide behind the same total endpoint")
        for bytes in [fragment(duration: 0), fragment(size: 0), fragment(composition: 1),
                      fragment(composition: UInt32.max), fragment(offsetAdjustment: 1),
                      fragment(offsetAdjustment: -1), fragment(count: 3), fragment(count: 1),
                      fragment(useDefaults: true, headerDuration: 0), fragment(useDefaults: true, headerSize: 3),
                      fragment(payload: Data([1, 2, 3, 4, 5, 6, 7])),
                      fragment(payload: Data([1, 2, 3, 4, 5, 6, 7, 8, 9])), fragment() + box("mdat", Data())] {
            XCTAssertThrowsError(try samples(bytes),
                "Malformed duration, CTS, ordinal, data offset or incomplete mdat coverage must fail")
        }
    }

    func testSyntheticAACSilenceMeterDetectsOffsetTwentyOneMillisecondMute() throws {
        let frameCount = 48_000
        var samples = [Float](repeating: 0.1, count: frameCount * 2)
        func measure(_ values: [Float], leading: Int? = nil) throws -> SyntheticAACPCMStatistics {
            let bytes = values.withUnsafeBytes { Data($0) }
            let sample = try PCMSampleBufferBuilder.make(bytes: bytes, frameCount: frameCount,
                sampleRate: 48_000, channels: 2, channelOrder: .native,
                channelLayoutMask: 0x3, presentationTimeStamp: .zero)
            var statistics = SyntheticAACPCMStatistics(startupLeadingFrames: leading)
            try statistics.consume(sample)
            return statistics
        }
        XCTAssertEqual(try measure(samples).silentShortWindows, 0)
        // 266 ms is deliberately offset from both 5 ms and 100 ms bucket edges.
        for index in (12_768 * 2)..<((12_768 + 1_008) * 2) { samples[index] = 0 }
        let muted = try measure(samples)
        XCTAssertEqual(muted.silentWindows, 0, "The coarse meter alone misses this mute")
        XCTAssertGreaterThanOrEqual(muted.silentShortWindows, 3)
        var padded = [Float](repeating: 0.1, count: frameCount * 2)
        for index in ((frameCount - 1_008) * 2)..<(frameCount * 2) { padded[index] = 0 }
        XCTAssertEqual(try measure(padded).silentShortWindows, 0,
            "Padding at the actual EOF must not be classified as an interior mute")
        // A startup-only mute was invisible to the old interior meter. Use an
        // arbitrary non-bucket-aligned prime count so the meter follows raw
        // ordinals relative to the actual leading trim, not a guessed 44 ms.
        let leading = 1_057
        var startup = [Float](repeating: 0.1, count: frameCount * 2)
        for index in 0..<(leading * 2) { startup[index] = 0 }
        let intact = try measure(startup, leading: leading)
        XCTAssertEqual(intact.checkedStartupWindows, 19)
        XCTAssertEqual(intact.silentStartupWindows, 0)
        for index in (leading * 2)..<((leading + 615) * 2) { startup[index] = 0 }
        let droppedCrossing = try measure(startup, leading: leading)
        XCTAssertEqual(droppedCrossing.silentShortWindows, 0)
        XCTAssertGreaterThan(droppedCrossing.silentStartupWindows, 0,
            "A missing 12.8 ms crossing-AU remainder must fail startup coverage")
    }

    func testSyntheticHLG50AC3OriginalAACFragmentsDecodeContinuously() async throws {
        let baseline = HLSDeliveryApplicationChargeLedger.shared.chargedBytes
        let probe = HLSWriterAcceptanceProbe()
        var failure: (any Error)?
        do { try await exerciseSyntheticAC3CompatibleTransition(probe: probe) }
        catch { failure = error }
        try await assertLargeIDRNativeOwnersRetired(probe)
        let deadline = ContinuousClock.now + .seconds(2)
        while HLSDeliveryApplicationChargeLedger.shared.chargedBytes > baseline,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThanOrEqual(HLSDeliveryApplicationChargeLedger.shared.chargedBytes, baseline,
            "The production shared ledger must release the owned source and every graph tail")
        if let failure { throw failure }
    }

    private func exerciseSyntheticAC3CompatibleTransition(probe: HLSWriterAcceptanceProbe) async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "synthetic-hlg50-ac3-64s.ts", withExtension: nil, subdirectory: "Video"),
            "Generate the mandatory synthetic fixture with Scripts/generate-homepod-audio-diagnostic-fixture.py before running this regression")
        let source = try Task22BundledHTTPFixtureServer(fileURL: file)
        defer { source.stop() }
        let resolver = URLSessionPlaybackSourceResolver()
        let capture = SyntheticAACContinuityCapture()
        var assembler: HLSMediaGraphAssembler?
        var failure: (any Error)?
        do {
            let expected = try syntheticAC3SourceCoverage(sourceURL: source.sourceURL)
            let context = try sourceContext(url: source.sourceURL)
            let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
            let resolved = try await resolver.resolve(context, reason: .initial)
            let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            let facts = try await HLSCompatibilityProbe().inspect(resolved, retainingFacts: factsCharge)
            let audioFacts = try XCTUnwrap(facts.media.first?.audio.first)
            XCTAssertEqual(audioFacts.codec, .ac3)
            XCTAssertEqual(audioFacts.sampleRate, 48_000)
            XCTAssertEqual(audioFacts.channelCount, 6)
            XCTAssertTrue(audioFacts.formatValidated)
            // Supply a supported route proposal matching the inspected source. It
            // is not emitted Dolby-writer proof: the real crossing AU must select
            // compatibility before any compressed native writer is constructed.
            let candidate = HLSCompressedAudioAdmissionCandidate(codec: .ac3,
                profile: audioFacts.profile, sampleRate: audioFacts.sampleRate,
                channelCount: audioFacts.channelCount, channelMask: audioFacts.channelMask,
                decoderConfiguration: audioFacts.decoderConfiguration,
                outputRouteIdentifier: "synthetic-airplay-route", requiresAACCompatibilityRendition: false)
            XCTAssertTrue(candidate.matches(audioFacts))
            let plan = try HLSPlaybackPlanner.makePlan(source: resolved, facts: facts,
                capabilities: .init(videoProfiles: [.hevc: [2]], compressedAudioCodecs: [.ac3, .aac],
                    compressedAudioAdmissionCandidates: [candidate], supportsGenerated: true))
            XCTAssertEqual(plan.transport, .generated)
            XCTAssertEqual(plan.video, .remux)
            XCTAssertEqual(plan.audio, .passthrough(.ac3),
                "Planning AAC directly would bypass the production transition under test")
            XCTAssertEqual(plan.compressedAudioAdmissionCandidate, candidate)
            let owned = HLSOwnedSourcePlan(source: resolved, facts: facts, plan: plan,
                resolver: resolver, sourceCharge: sourceCharge, factsCharge: factsCharge)
            owned.installCompatibleAudioRecovery {
                XCTFail("The first crossing AU must transition in place, without a replacement AAC generation")
                return false
            }
            owned.installGenerationRecovery {
                XCTFail("A continuous fixture must not restart its owned source generation")
                return false
            }
            let owner = try XCTUnwrap(context.owner)
            let control = PlaybackControlExecutor(allocator: PlaybackIdentityAllocator(),
                applyIngress: { _ in .applied }, applyTerminalIngress: { _ in },
                applyOutputControl: { _, _ in .rejected })
            let authority = try SystemHLSMediaGraphAuthority(
                lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce),
                publicationDeadlineNanoseconds: 180_000_000_000, acceptanceProbe: probe,
                generatedSource: owned, sourceCopyApplicationLedger: .shared,
                sharedControlExecutor: control)
            authority.publicationForTesting.installBeforeReceiveForTesting { capture.receive($0) }
            let graph = HLSMediaGraphAssembler(sourceURL: source.sourceURL,
                applicationLedger: .shared, graph: SystemHLSDeliveryGraph(authority: authority))
            assembler = graph
            let prefix = try await graph.startUntilPlayablePrefix()
            XCTAssertEqual(prefix.mediaInformation?.width, 3_840)
            XCTAssertEqual(prefix.mediaInformation?.height, 2_160)
            XCTAssertEqual(prefix.mediaInformation?.outputFrameRate, 50)
            XCTAssertEqual(prefix.mediaInformation?.airPlayOutputMode, .audioTranscode,
                "The real AAC fallback overrides the still-passthrough plan.audio")
            try printSyntheticAACPublication(try XCTUnwrap(authority.publicationForTesting.publisher?.visible),
                phase: "prefix")
            let complete = await authority.finishAllTracksAtNaturalEOF()
            print("AC3_DIAGNOSTIC graphComplete=\(complete) error=\(authority.failureDescriptionForDiagnostics ?? "none")")
            try capture.printSummary()
            XCTAssertTrue(complete, authority.failureDescriptionForDiagnostics ?? "Synthetic graph did not finish")
            // Inspect original callback bytes before consulting final authorities,
            // so a missing downstream receipt cannot suppress native timing evidence.
            // Keep only bounded byte copies, never sealed/publication/producer owners.
            let records = try capture.snapshot()
            let media = records.filter { $0.kind == .media }.sorted { $0.sequence < $1.sequence }
            let initial = try XCTUnwrap(records.first { $0.kind == .initialization })
            try printSyntheticAACInitialization(initial.bytes, label: "AC3_AAC_NATIVE_INIT", requireUneditedAAC: true)
            let fragments = try media.map { try SyntheticAACFragmentInspector.inspect($0) }
            XCTAssertGreaterThanOrEqual(media.count, 60)
            XCTAssertEqual(Set(media.map(\.writer)).count, 1,
                "Stable AAC input must retain one persistent native writer across all fragment windows")
            XCTAssertEqual(records.filter { $0.kind == .initialization }.count, 1)
            for (previous, current) in zip(media, media.dropFirst()) {
                XCTAssertEqual(current.sequence, previous.sequence + 1)
                let previousEnd = CMTimeAdd(try XCTUnwrap(previous.start), try XCTUnwrap(previous.duration))
                XCTAssertEqual(CMTimeSubtract(try XCTUnwrap(current.start), previousEnd).seconds,
                    0, accuracy: 1.0 / 48_000,
                    "AAC report gap at sequence \(current.sequence), writer \(current.writer)")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("canonical-aac.mp4")
            var bytes = initial.bytes
            for segment in media { bytes.append(segment.bytes) }
            try bytes.write(to: output)
            XCTAssertTrue(zip(fragments, fragments.dropFirst()).allSatisfy { pair in pair.1.sequence > pair.0.sequence },
                "Native mfhd values must increase across persistent-writer fragments: \(fragments.map(\.sequence))")
            for (previous, current) in zip(fragments, fragments.dropFirst()) {
                XCTAssertEqual(current.decodeTime, previous.decodeTime + previous.sampleCount * 1_024,
                    "Original tfdt/trun must preserve every AAC access unit across fragment windows")
            }
            var rawAudio: [SyntheticRawMediaSample] = []
            for (index, record) in media.enumerated() {
                let samples = try SyntheticAACFragmentInspector.unreorderedSamples(
                    initialization: initial.bytes, media: record.bytes, timescale: 48_000,
                    maximumSamples: 320)
                let first = try XCTUnwrap(samples.first), last = try XCTUnwrap(samples.last)
                let end = try last.start.adding(last.duration)
                XCTAssertEqual(first.start, try ExactMediaTime(XCTUnwrap(record.start)),
                    "Original tfdt with zero CTO must match the native report, without reader normalization")
                XCTAssertEqual(try end.subtracting(first.start), try ExactMediaTime(XCTUnwrap(record.duration)))
                XCTAssertTrue(samples.allSatisfy { $0.duration == ExactMediaTime(value: 1_024, timescale: 48_000) })
                if let previous = rawAudio.last { XCTAssertEqual(first.start, try previous.start.adding(previous.duration)) }
                guard samples.count <= 4_096 - rawAudio.count else { throw AACRenditionFailure.capacityExceeded }
                rawAudio += samples
                if index < 4 || index == media.count - 1 {
                    print("AC3_AAC_NATIVE_TIMING sequence=\(record.sequence) reportStart=\(String(describing: record.start)) " +
                        "reportDuration=\(String(describing: record.duration)) tfdt=\(fragments[index].decodeTime) " +
                        "scale=48000 cto=0 sampleDuration=1024 samples=\(samples.count) end=\(end)")
                }
            }
            XCTAssertEqual(authority.audioCalibrationAttemptsForTesting, 1,
                "The selected Dolby source must enter exactly one compatible AAC encoder epoch")
            let fallback = authority.compressedAudioFallbackForTesting
            XCTAssertEqual(fallback.count, 1)
            let transition = try XCTUnwrap(fallback.first)
            XCTAssertEqual(transition.codec, .ac3)
            XCTAssertTrue(transition.hadDolbyProducer)
            XCTAssertTrue(transition.producerWasCurrent)
            XCTAssertEqual(transition.boundaryDecision, .trimLeading(expected.firstTrim))
            XCTAssertEqual(transition.normalizedStart, expected.origin.effectiveStart)
            XCTAssertEqual(transition.origin?.sourceTime, expected.origin.sourceTime)
            XCTAssertEqual(CMTimeCompare(transition.sourcePresentationTime, expected.firstSourcePTS), 0)
            XCTAssertEqual(CMTimeCompare(transition.sourceDuration, expected.firstSourceDuration), 0)
            print("AC3_COMPATIBLE_TRANSITION count=\(fallback.count) installedDolby=\(transition.hadDolbyProducer) " +
                "currentDolby=\(transition.producerWasCurrent) sourcePTS=\(transition.sourcePresentationTime) " +
                "normalizedStart=\(transition.normalizedStart) trim=\(expected.firstTrim)")
            XCTAssertTrue(owned.isCurrent)
            XCTAssertEqual(probe.snapshot.nativeAC3WriterCount, 0)
            XCTAssertEqual(probe.snapshot.nativeEAC3WriterCount, 0)
            let publication = try XCTUnwrap(authority.publicationForTesting.publisher?.visible)
            XCTAssertTrue(publication.sourceAACTerminalBindings.isEmpty)
            XCTAssertEqual(publication.aacTerminalBindings.count, 1)
            try printSyntheticAACPublication(publication, phase: "final")
            let participantID = try XCTUnwrap(publication.aacTerminalBindings.keys.first)
            let terminal = try XCTUnwrap(publication.aacTerminalBindings[participantID])
            let rendition = try XCTUnwrap(publication.aacRenditionBindings[participantID])
            // Natural EOF authenticates the encoder/writer final receipt. Playback
            // endpoint authority additionally requires real HTTP membership and is
            // intentionally not manufactured by this graph/byte-decoding test.
            let final = try XCTUnwrap(rendition.finalWriterReceipt)
            let mapping = try XCTUnwrap(terminal.timelineMappingReceipt)
            XCTAssertTrue(final.terminalBinding === terminal)
            XCTAssertEqual(final.binding, mapping.binding)
            XCTAssertEqual(final.systemTerminal.binding, final.binding)
            XCTAssertEqual(final.systemTerminal.terminalReason, .finished)
            XCTAssertEqual(rendition.acceptedWindowCount, 1)
            XCTAssertEqual(final.sampleRate, 48_000)
            XCTAssertEqual(final.sampleRate, mapping.sampleRate)
            XCTAssertEqual(mapping.inputEffectiveBase, expected.origin.effectiveStart)
            XCTAssertEqual(final.realSampleCount, expected.realSampleCount,
                "Every admitted source sample after the first crossing trim must reach the same AAC epoch")
            XCTAssertEqual(final.totalDecodedFrames,
                Int64(final.leadingFrames) + final.realSampleCount + final.trailingFrames)
            XCTAssertEqual(mapping.inputEffectiveBase, try mapping.inputPhysicalBase.adding(
                .init(value: Int64(final.leadingFrames), timescale: final.sampleRate)))
            XCTAssertEqual(mapping.writtenPhysicalBase, try mapping.inputPhysicalBase.adding(mapping.offset))
            XCTAssertEqual(mapping.writtenEffectiveBase, try mapping.inputEffectiveBase.adding(mapping.offset))
            XCTAssertEqual(final.lastEffectiveEnd, try mapping.writtenEffectiveBase.adding(
                .init(value: expected.realSampleCount, timescale: final.sampleRate)))
            XCTAssertEqual(final.terminalPhysicalEnd, try mapping.writtenPhysicalBase.adding(
                .init(value: final.totalDecodedFrames, timescale: final.sampleRate)))
            XCTAssertEqual(final.callbackMembership.snapshot.pendingCount, 0)
            XCTAssertEqual(final.callbackMembership.snapshot.count, UInt64(media.count))
            XCTAssertEqual(final.systemTerminal.mediaCallbackCount, media.count)
            XCTAssertEqual(final.systemTerminal.initializationCallbackCount, 1)
            let firstMedia = try XCTUnwrap(media.first), lastMedia = try XCTUnwrap(media.last)
            XCTAssertEqual(final.binding.writerIdentity.rawValue, firstMedia.writer)
            XCTAssertEqual(final.firstMedia.key.logicalSequence, firstMedia.sequence)
            XCTAssertEqual(final.terminalMedia.key.logicalSequence, lastMedia.sequence)
            XCTAssertEqual(final.firstMedia.sealedDigest, Data(SHA256.hash(data: firstMedia.bytes)))
            XCTAssertEqual(final.terminalMedia.sealedDigest, Data(SHA256.hash(data: lastMedia.bytes)))
            print("AC3_AAC_MAPPING rate=\(final.sampleRate) leading=\(final.leadingFrames) trailing=\(final.trailingFrames) " +
                "real=\(final.realSampleCount) decoded=\(final.totalDecodedFrames) " +
                "inputPhysical=\(mapping.inputPhysicalBase) inputEffective=\(mapping.inputEffectiveBase) " +
                "writtenPhysical=\(mapping.writtenPhysicalBase) writtenEffective=\(mapping.writtenEffectiveBase) offset=\(mapping.offset) " +
                "physicalEnd=\(final.terminalPhysicalEnd) effectiveEnd=\(final.lastEffectiveEnd) " +
                "writerFinal=true playbackEndpointIssued=\(rendition.endpointAuthority != nil)")
            XCTAssertEqual(try XCTUnwrap(rawAudio.first).start, mapping.writtenPhysicalBase)
            XCTAssertGreaterThan(final.leadingFrames, 0,
                "This native regression must exercise a primed first AAC segment")
            XCTAssertEqual(try mapping.writtenPhysicalBase.adding(
                .init(value: Int64(final.leadingFrames), timescale: final.sampleRate)), mapping.writtenEffectiveBase)
            let lastRaw = try XCTUnwrap(rawAudio.last)
            XCTAssertEqual(try lastRaw.start.adding(lastRaw.duration), final.terminalPhysicalEnd)
            XCTAssertEqual(Int64(rawAudio.count) * 1_024, final.totalDecodedFrames,
                "Original native bytes must contain every encoded AU, including both endpoints")
            let rawDecoded = try await inspectSyntheticAACRawPCM(output, sampleRate: 48_000,
                rawSamples: rawAudio, startupLeadingFrames: final.leadingFrames)
            XCTAssertEqual(Int64(rawDecoded.statistics.frames), final.totalDecodedFrames)
            XCTAssertEqual(rawDecoded.statistics.checkedStartupWindows, 19)
            XCTAssertEqual(rawDecoded.statistics.silentStartupWindows, 0,
                "Losing the crossing or following source AU must not hide as silence in the first 100 ms")
            print("AC3_AAC_RAW_STARTUP leading=\(final.leadingFrames) windows=\(rawDecoded.statistics.checkedStartupWindows) " +
                "silent5ms=\(rawDecoded.statistics.silentStartupWindows) minRMS=\(rawDecoded.statistics.minimumStartupRMS)")
            // Decode the actual canonical init and all original media bytes. No
            // sequence-number rewrite, box removal, or timing normalization is allowed.
            let decoded = try await inspectSyntheticAACPCM(output)
            print("AC3_ORIGINAL_OUTPUT originalBytes=true physicalHomePodVerified=false decodedFrames=\(decoded.frames) maxGapSamples=\(decoded.maximumGapSamples) " +
                "silent100msWindows=\(decoded.silentWindows) silent5msInteriorWindows=\(decoded.silentShortWindows) " +
                "minRMS=\(decoded.minimumRMS) min5msInteriorRMS=\(decoded.minimumShortRMS) " +
                "interiorBuckets=\(decoded.checkedShortWindows) silenceBucketEnds=\(decoded.silentWindowEndTimes)")
            XCTAssertGreaterThanOrEqual(decoded.frames, 63 * 48_000)
            XCTAssertLessThanOrEqual(decoded.frames, 65 * 48_000)
            XCTAssertLessThanOrEqual(decoded.maximumGapSamples, 1)
            XCTAssertEqual(decoded.silentWindows, 0,
                "Continuous source tones must remain audible across segment and writer boundaries")
            XCTAssertGreaterThanOrEqual(decoded.checkedShortWindows, 12_000)
            XCTAssertEqual(decoded.silentShortWindows, 0,
                "Interior 5 ms windows must expose repeated AAC priming mutes even when a 100 ms bucket straddles them")
        } catch {
            try? capture.printSummary()
            failure = error
        }
        if let assembler {
            let retired = await assembler.retireAndAwaitReceipt()
            XCTAssertTrue(retired, "The real graph must retire even when a continuity assertion fails")
            XCTAssertEqual(assembler.currentPhase, .retired)
        }
        await resolver.invalidate()
        if let failure { throw failure }
    }

    private func syntheticAC3SourceCoverage(sourceURL: URL) throws
        -> (origin: MediaOriginReceipt, realSampleCount: Int64, firstTrim: ExactMediaTime,
            firstSourcePTS: CMTime, firstSourceDuration: CMTime) {
        var events = try joinedLargeIDRFixtureEvents(sourceURL: sourceURL)
        defer { events.removeAll(keepingCapacity: false) }
        guard events.count <= 8_192 else { throw AACRenditionFailure.capacityExceeded }
        XCTAssertTrue(events.contains { if case .endOfStream = $0 { true } else { false } })
        let timeline = HLSTimelineCoordinator()
        defer { timeline.retireCompressedGeneration() }
        var origins: [MediaOriginReceipt] = []
        var firstAudio: HLSTimedAudioAccessUnit?
        var previousEnd: ExactMediaTime?
        var totalFrames: Int64 = 0
        var admittedAUs = 0
        var firstVideoPTS: ExactMediaTime?
        var firstAudioPTS: ExactMediaTime?
        for event in events {
            if case .packet(let packet) = event {
                switch packet.codec {
                case .video where firstVideoPTS == nil: firstVideoPTS = try ExactMediaTime(packet.presentationTimeStamp)
                case .audio where firstAudioPTS == nil: firstAudioPTS = try ExactMediaTime(packet.presentationTimeStamp)
                default: break
                }
            }
            for emission in try timeline.consume(event) {
                switch emission {
                case .originEstablished(let origin): origins.append(origin)
                case .audioSample(let sample):
                    if firstAudio == nil { firstAudio = sample }
                    else { XCTAssertEqual(sample.boundaryDecision, .unchanged) }
                    if let previousEnd { XCTAssertEqual(sample.timing.presentationTimeStamp, previousEnd) }
                    XCTAssertEqual(sample.source.frameSampleCount, 1_536)
                    totalFrames += Int64(sample.source.frameSampleCount)
                    admittedAUs += 1
                    previousEnd = try sample.timing.presentationTimeStamp.adding(XCTUnwrap(sample.timing.duration))
                default: break
                }
            }
        }
        XCTAssertEqual(origins.count, 1)
        let origin = try XCTUnwrap(origins.first)
        let first = try XCTUnwrap(firstAudio)
        guard case .trimLeading(let trim) = first.boundaryDecision else {
            XCTFail("The actual packet phase must put the first admitted AC3 AU across the selected IDR")
            throw AACRenditionFailure.invalidInput
        }
        XCTAssertGreaterThan(trim.value, 0)
        XCTAssertEqual(first.timing.presentationTimeStamp, origin.effectiveStart)
        let phase = try XCTUnwrap(firstVideoPTS).subtracting(XCTUnwrap(firstAudioPTS))
        XCTAssertEqual(phase, .init(value: 58_608, timescale: 90_000),
            "Inspect the muxed packet phase, not the generator's input itsoffset")
        XCTAssertEqual(try origin.sourceTime.subtracting(XCTUnwrap(firstVideoPTS)), .init(value: 1, timescale: 1),
            "The first complete validation GOP must lead to the immediately following source IDR")
        XCTAssertEqual(trim, .init(value: 1_728, timescale: 90_000),
            "The eligible IDR must retain this fixture's fractional 921.6-source-sample crossing")
        let trimmedFrames = CMTimeConvertScale(trim.cmTime, timescale: 48_000, method: .roundHalfAwayFromZero)
        XCTAssertTrue(trimmedFrames.isNumeric)
        XCTAssertGreaterThan(trimmedFrames.value, 0)
        XCTAssertLessThan(trimmedFrames.value, 1_536)
        let realFrames = totalFrames - trimmedFrames.value
        let sourceDuration = try XCTUnwrap(previousEnd).subtracting(origin.effectiveStart)
        XCTAssertEqual(CMTimeConvertScale(sourceDuration.cmTime, timescale: 48_000,
            method: .roundHalfAwayFromZero).value, realFrames)
        print("AC3_SOURCE_CROSSING phase=\(phase) sourceOrigin=\(origin.sourceTime) effectiveOrigin=\(origin.effectiveStart) " +
            "firstSourcePTS=\(first.source.presentationTimeStamp) firstTrim=\(trim) trimmedFrames=\(trimmedFrames.value) " +
            "admittedAUs=\(admittedAUs) realFrames=\(realFrames) sourceEnd=\(String(describing: previousEnd))")
        return (origin, realFrames, trim, first.source.presentationTimeStamp, first.source.duration)
    }

    private func printSyntheticAACPublication(_ snapshot: HLSPublishedSnapshot, phase: String) throws {
        print("AC3_AAC_PUBLICATION phase=\(phase) anchorMedia=\(snapshot.coverage.anchor.mediaOrigin) " +
            "anchorUTCms=\(snapshot.coverage.anchor.utcMilliseconds) sequences=\(snapshot.coverage.logicalSequences)")
        for participant in snapshot.coverage.participants {
            let kind = snapshot.aacTerminalBindings[participant.participantID] == nil ? "video" : "aac"
            let playlist = try XCTUnwrap(snapshot.media[participant.participantID])
            let dates = try Task19ProgramDateTimeChecks.dates(playlist)
            let offset = snapshot.aacTimelineMappings[participant.participantID]?.offset ?? HLSChecked.zero
            let anchor = snapshot.coverage.anchor
            XCTAssertEqual(snapshot.coverage.logicalSequences.count, participant.ranges.count)
            for (sequence, range) in zip(snapshot.coverage.logicalSequences, participant.ranges) {
                let start = try range.start.subtracting(offset)
                let date = try XCTUnwrap(dates[sequence])
                XCTAssertEqual(date.timeIntervalSince1970 - Double(anchor.utcMilliseconds) / 1_000,
                    CMTimeGetSeconds(start.cmTime) - CMTimeGetSeconds(anchor.mediaOrigin.cmTime), accuracy: 0.001,
                    "PDT must preserve the actual first AAC timestamp, including initial priming and later AU phase")
            }
            // Allowlist scalar timing tags. Never print loopback authentication or resource URIs.
            let tags = playlist.text.split(separator: "\n").filter {
                $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") || $0.hasPrefix("#EXTINF:")
            }
            XCTAssertLessThanOrEqual(tags.count, 14)
            print("AC3_AAC_PLAYLIST phase=\(phase) kind=\(kind) epochs=\(participant.epochs) " +
                "ranges=\(participant.ranges) tags=\(tags.joined(separator: "|"))")
        }
    }

    private func printSyntheticAACInitialization(_ bytes: Data, label: String = "LARGE_IDR_AAC_NATIVE_INIT",
        requireUneditedAAC: Bool = false) throws {
        // Diagnostic bytes only: no inferred delay or reader offset enters assertions.
        var metadata: [String: String] = [:]
        func visit(_ start: Int, _ end: Int, path: String, depth: Int) throws {
            guard depth <= 6 else { throw AACRenditionFailure.capacityExceeded }
            for box in try SyntheticAACFragmentInspector.boxes(bytes, from: start, through: end) {
                let name = path + "/" + box.type
                if ["mvhd", "mdhd", "elst", "sgpd", "sbgp"].contains(box.type) {
                    guard box.end - box.payload <= 4_096, metadata[name] == nil else {
                        throw AACRenditionFailure.invalidInput
                    }
                    metadata[name] = bytes[box.payload..<box.end].map { String(format: "%02x", $0) }.joined()
                }
                if ["moov", "trak", "mdia", "minf", "stbl", "edts"].contains(box.type) {
                    try visit(box.payload, box.end, path: name, depth: depth + 1)
                }
            }
        }
        try visit(0, bytes.count, path: "", depth: 0)
        if requireUneditedAAC {
            XCTAssertFalse(metadata.keys.contains { $0.hasSuffix("/elst") },
                "The native Apple-HLS AAC coordinate proof requires its original unedited track timeline")
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        print("\(label) \(String(decoding: data, as: UTF8.self))")
    }

    private func inspectSyntheticAACRawPCM(_ url: URL, sampleRate: Int32,
        rawSamples: [SyntheticRawMediaSample], startupLeadingFrames: Int? = nil) async throws -> SyntheticAACRawPCM {
        guard !rawSamples.isEmpty, rawSamples.count <= 4_096 else { throw AACRenditionFailure.capacityExceeded }
        let expectedFrames = rawSamples.count * 1_024
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw AACRenditionFailure.invalidInput }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        let input = SyntheticAACPacketInput(rawSamples: rawSamples, sampleRate: sampleRate)
        var decoder: AudioConverterRef?
        defer { if let decoder { AudioConverterDispose(decoder) } }
        var format: CMAudioFormatDescription?
        var statistics = SyntheticAACPCMStatistics(sampleRate: sampleRate, startupLeadingFrames: startupLeadingFrames)
        var pcmHash = SHA256()
        var decoded = [Float](repeating: 0, count: 4_096 * 2)
        var naturallyDrained = false
        defer {
            print("LARGE_IDR_AAC_RAW_DECODE file=\(url.lastPathComponent) au=\(input.timeline.frames) " +
                "frames=\(statistics.frames) naturalDrain=\(naturallyDrained) " +
                "first=\(input.firstDiagnostic) last=\(input.lastDiagnostic) timing=\(input.timeline.diagnostics)")
        }
        // Same raw decoder contract as AACSystemLoopback.decodeRaw: original
        // packets and cookie, no prime-property override, no trim or padded PCM.
        func pump() throws -> Bool {
            let converter = try XCTUnwrap(decoder)
            for _ in 0..<(rawSamples.count + 2) {
                var frames: UInt32 = 4_096
                var outputBytes: UInt32 = 0
                let status = decoded.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                        mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                    let status = AudioConverterFillComplexBuffer(converter, syntheticAACPacketInput,
                        Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
                    outputBytes = list.mBuffers.mDataByteSize
                    return status
                }
                let paused = status == SyntheticAACPacketInput.needsInputStatus
                if !paused { try AACRenditionEncoder.check(status) }
                guard frames <= 4_096, outputBytes == frames * 8,
                      statistics.frames <= expectedFrames - Int(frames) else {
                    throw AACRenditionFailure.invalidInput
                }
                if frames > 0 {
                    let bytes = decoded.withUnsafeBytes { Data($0.prefix(Int(outputBytes))) }
                    pcmHash.update(data: bytes)
                    // Zero-based raw PCM ordinals are independent of each
                    // container reader's presentation-time translation.
                    let sample = try PCMSampleBufferBuilder.make(bytes: bytes, frameCount: Int(frames),
                        sampleRate: sampleRate, channels: 2, channelOrder: .native, channelLayoutMask: 0x3,
                        presentationTimeStamp: CMTime(value: Int64(statistics.frames), timescale: sampleRate))
                    try statistics.consume(sample)
                }
                if paused { return false }
                if frames == 0 {
                    guard input.ended, input.sawEOS else { throw AACRenditionFailure.invalidInput }
                    return true
                }
            }
            throw AACRenditionFailure.capacityExceeded
        }
        var consecutiveMarkers = 0
        while let ready = try await provider.next() {
            let sample = try makeOwnedReaderFixtureSample(copying: ready)
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 {
                let duration = CMSampleBufferGetDuration(sample)
                guard consecutiveMarkers < 8, ready.contentType == .markerOnly,
                      CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
                      CMSampleBufferGetTotalSampleSize(sample) == 0,
                      CMSampleBufferGetDataBuffer(sample) == nil, CMSampleBufferGetImageBuffer(sample) == nil,
                      CMSampleBufferGetFormatDescription(sample) == nil,
                      !duration.isValid || (duration.isNumeric && duration.epoch == 0 && duration.value == 0) else {
                    throw AACRenditionFailure.invalidInput
                }
                consecutiveMarkers += 1
                print("LARGE_IDR_AAC_READER_MARKER file=\(url.lastPathComponent) \(SyntheticAACPacketInput.diagnostics(sample))")
                continue
            }
            consecutiveMarkers = 0
            guard ready.contentType == .dataBuffer, CMSampleBufferIsValid(sample),
                  CMSampleBufferGetImageBuffer(sample) == nil else { throw AACRenditionFailure.invalidInput }
            let currentFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            if let format {
                guard CMFormatDescriptionEqual(format, otherFormatDescription: currentFormat) else {
                    throw AACRenditionFailure.invalidInput
                }
            } else {
                var source = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(currentFormat)).pointee
                guard source.mFormatID == kAudioFormatMPEG4AAC,
                      source.mFramesPerPacket == 1_024, source.mSampleRate == Double(sampleRate),
                      source.mChannelsPerFrame == 2 else { throw AACRenditionFailure.invalidInput }
                var destination = AACRenditionEncoder.pcmFormat(channels: 2)
                destination.mSampleRate = Double(sampleRate)
                try AACRenditionEncoder.check(AudioConverterNew(&source, &destination, &decoder))
                let converter = try XCTUnwrap(decoder)
                var cookieSize = 0
                let cookie = try XCTUnwrap(CMAudioFormatDescriptionGetMagicCookie(currentFormat, sizeOut: &cookieSize))
                guard cookieSize > 0, cookieSize <= 65_536 else { throw AACRenditionFailure.capacityExceeded }
                try AACRenditionEncoder.check(AudioConverterSetProperty(converter,
                    kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie))
                format = currentFormat
            }
            try input.install(sample)
            guard try !pump() else { throw AACRenditionFailure.invalidInput }
        }
        guard reader.status == .completed else { throw reader.error ?? AACRenditionFailure.invalidInput }
        input.ended = true
        guard try pump(), input.timeline.frames == rawSamples.count,
              statistics.frames == expectedFrames else { throw AACRenditionFailure.invalidInput }
        naturallyDrained = true
        let source = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(format))).pointee
        return SyntheticAACRawPCM(statistics: statistics, pcmSHA256: Data(pcmHash.finalize()), format: AACASBD(source))
    }

    private func inspectSyntheticAACPCM(_ url: URL, sampleRate: Int32 = 48_000) async throws -> SyntheticAACPCMStatistics {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        print("AC3_READER file=\(url.lastPathComponent) assetDuration=\(duration.seconds)")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ])
        XCTAssertTrue(reader.canAdd(output))
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        var statistics = SyntheticAACPCMStatistics(sampleRate: sampleRate)
        while let ready = try await provider.next() {
            let sample = try makeOwnedReaderFixtureSample(copying: ready)
            try statistics.consume(sample)
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return statistics
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
        XCTAssertEqual(replacement.mediaInformation, PlaybackMediaInformation(
            width: 1_280, height: 720, scanMode: .progressive,
            sourceFrameRate: MediaRational(num: 25, den: 1), outputFrameRate: 25,
            isSmoothMotionEnhanced: false).withAirPlayOutputMode(.audioTranscode))
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
        XCTAssertEqual(replacement.mediaInformation, PlaybackMediaInformation(
            width: 1_920, height: 1_080, scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1), outputFrameRate: 50,
            isSmoothMotionEnhanced: true).withAirPlayOutputMode(.mixedTranscode))
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

/// Hold only callbacks beyond the genuine six-segment startup; media and receipts stay untouched.
private final class Task22LatePublicationReceiveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var blocked = 0
    private var highestBlockedSequence: UInt64 = 0
    private var permittedThrough: UInt64 = 5
    private var timedOut = false

    var didTimeout: Bool { condition.withLock { timedOut } }

    func receive(_ object: SealedMediaObject) {
        guard object.kind == .media, object.logicalSequence >= 6 else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !released, object.logicalSequence > permittedThrough else { return }
        blocked += 1
        highestBlockedSequence = max(highestBlockedSequence, object.logicalSequence)
        condition.broadcast()
        let deadline = Date().addingTimeInterval(15)
        while !released, object.logicalSequence > permittedThrough {
            if !condition.wait(until: deadline) {
                timedOut = true
                return
            }
        }
    }

    func waitUntilBlocked(atLeast sequence: UInt64 = 6) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while (blocked == 0 || highestBlockedSequence < sequence), !released {
            if !condition.wait(until: deadline) { return false }
        }
        return blocked > 0 && highestBlockedSequence >= sequence
    }

    func releaseThrough(_ sequence: UInt64) {
        condition.withLock { permittedThrough = max(permittedThrough, sequence); condition.broadcast() }
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }
}

private final class Task22SelectedLiveWakeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var selected = false
    private var released = false
    private var completed = false
    private var timedOut = false

    var didTimeout: Bool { condition.withLock { timedOut } }
    func arm() { condition.withLock { armed = true } }

    func beforeEntry() {
        condition.lock()
        defer { condition.unlock() }
        guard armed, !selected else { return }
        selected = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(20)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; return }
        }
    }

    func afterEntry() {
        condition.withLock {
            if selected && released { completed = true; condition.broadcast() }
        }
    }

    func waitUntilSelected() -> Bool { wait(forCompletion: false) }
    func waitUntilCompleted() -> Bool { wait(forCompletion: true) }

    private func wait(forCompletion: Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !(forCompletion ? completed : selected) {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func release() { condition.withLock { released = true; condition.broadcast() } }
}

/// Send a packet-aligned 3/4 prefix (or all but one packet) and withhold real EOF.
/// The default 16s fixture then supplies the six-segment startup and sealed successors.
private final class Task22LatePublicationFixtureServer: @unchecked Sendable {
    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var active: [NWConnection] = []
        private var stopped = false
        private var sentEOF = false
        private var finishers: [@Sendable () -> Void] = []

        func registerFinisher(_ finisher: @escaping @Sendable () -> Void) {
            let finishNow = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                if sentEOF { return true }
                finishers.append(finisher)
                return false
            }
            if finishNow { finisher() }
        }

        func finishBody() {
            let pending = lock.withLock { () -> [@Sendable () -> Void] in
                guard !stopped, !sentEOF else { return [] }
                sentEOF = true
                defer { finishers.removeAll() }
                return finishers
            }
            for finish in pending { finish() }
        }

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
                finishers.removeAll()
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

    init(fileURL: URL, sendEntireBodyWithoutEOF: Bool = false, prefixByteLimit: Int? = nil) throws {
        let payload = try Data(contentsOf: fileURL)
        // Retain one whole TS packet and keep the declared response incomplete.
        // This tests live publication; no EOF can activate the separate drain.
        let normalPrefixBytes = sendEntireBodyWithoutEOF
            ? (payload.count / 188 - 1) * 188
            : (payload.count * 3 / 4) / 188 * 188
        let prefixBytes = prefixByteLimit.map { min(normalPrefixBytes, $0 / 188 * 188) } ?? normalPrefixBytes
        guard prefixBytes > 0, prefixBytes < payload.count else {
            throw NSError(domain: "Task22LatePublicationFixtureServer", code: 1)
        }
        let prefix = Data(payload.prefix(prefixBytes))
        let suffix = Data(payload.dropFirst(prefixBytes))
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
                        guard error == nil else { connection.cancel(); return }
                        ownedConnections.registerFinisher {
                            connection.send(content: suffix, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                        }
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

    func finishBody() { connections.finishBody() }
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

/// Observes the real factory result; does not replace media, AVPlayer, readiness, or retirement.
private final class AudioReviewProductionBackendFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let factory: SystemPlaybackBackendFactory
    // Observation must not extend a retired backend's one-native-driver lease.
    private weak var created: HLSAVPlayerPlaybackBackend?
    init(factory: SystemPlaybackBackendFactory = SystemPlaybackBackendFactory()) { self.factory = factory }
    var backend: HLSAVPlayerPlaybackBackend? { lock.withLock { created } }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity,
                     tuning: PlaybackTuning, channelID: String, url: URL,
                     eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        let value = try await factory.makeBackend(kind: kind, identity: identity,
            tuning: tuning, channelID: channelID, url: url, eventSink: eventSink)
        lock.withLock { created = value as? HLSAVPlayerPlaybackBackend }
        return value
    }
}

/// A weak observation cannot hold producer ownership beyond the real prepare join.
private final class HLSPreparingGraphObservation: @unchecked Sendable {
    private let lock = NSLock()
    private weak var authority: SystemHLSMediaGraphAuthority?
    func record(_ authority: SystemHLSMediaGraphAuthority) { lock.withLock { self.authority = authority } }
    var waiting: Bool { lock.withLock { authority?.prefixPreparationInFlightForTesting == true } }
}

/// Stops only the handoff of an already-proven real prefix. All source, writer,
/// server, AVPlayer, and retirement behavior remains production behavior.
private final class HLSMediaInformationPrefixGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var remainingBypasses: Int
    init(bypassingFirstWaits: Int = 0) { remainingBypasses = bypassingFirstWaits }
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                guard !released else { return true }
                if remainingBypasses > 0 {
                    remainingBypasses -= 1
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

private final class HLSMediaInformationGatedGraph: HLSMediaGraphAssembler.DeliveryGraph, @unchecked Sendable {
    private let graph: SystemHLSDeliveryGraph
    private let gate: HLSMediaInformationPrefixGate
    init(graph: SystemHLSDeliveryGraph, gate: HLSMediaInformationPrefixGate) {
        self.graph = graph
        self.gate = gate
    }
    var failureDiagnostic: ErrorDiagnosticSnapshot? { graph.failureDiagnostic }
    func accept(_ event: AdmittedDemuxEvent) { graph.accept(event) }
    func waitUntilPlayablePrefix() async -> HLSMediaGraphAssembler.HLSMediaGraphPlayablePrefix? {
        guard let prefix = await graph.waitUntilPlayablePrefix() else { return nil }
        await gate.wait()
        return prefix
    }
    func finishNaturalEOF() async -> Bool { await graph.finishNaturalEOF() }
    func retireAndAwaitReceipt() async -> Bool { await graph.retireAndAwaitReceipt() }
}

/// Bounded test-owned byte copies. Never retains native media owners or replaces delivery.
private final class SyntheticAACContinuityCapture: @unchecked Sendable {
    struct Record: Sendable {
        let kind: SealedMediaObjectKind
        let sequence: UInt64
        let writer: UInt64
        let start: CMTime?
        let duration: CMTime?
        let bytes: Data
    }
    private let lock = NSLock()
    private var records: [Record] = []
    private var copiedBytes = 0
    private var exceededCapacity = false
    private let codecPrefix: String

    init(codecPrefix: String = "mp4a.40.2") { self.codecPrefix = codecPrefix }

    func receive(_ object: SealedMediaObject) {
        guard object.publicationEvidence?.format.codec.hasPrefix(codecPrefix) == true else { return }
        lock.withLock {
            guard records.count < 256, object.bytes.count <= 8 * 1_024 * 1_024 - copiedBytes else {
                exceededCapacity = true
                return
            }
            let copy = object.bytes.withUnsafeBytes { Data($0) }
            records.append(Record(kind: object.kind, sequence: object.logicalSequence,
                writer: object.writerIdentity.rawValue, start: object.report.earliestPresentationTimeStamp,
                duration: object.report.duration, bytes: copy))
            copiedBytes += copy.count
        }
    }

    func snapshot() throws -> [Record] {
        try lock.withLock {
            guard !exceededCapacity else { throw AACRenditionFailure.capacityExceeded }
            return records
        }
    }

    func printSummary() throws {
        let values = try snapshot()
        let media = values.filter { $0.kind == .media }.sorted { $0.sequence < $1.sequence }
        print("AC3_DIAGNOSTIC segments=\(media.count) physicalWriters=\(Set(media.map(\.writer)).count) " +
            "initializations=\(values.filter { $0.kind == .initialization }.count)")
        for record in media {
            print("AC3_SEGMENT sequence=\(record.sequence) writer=\(record.writer) " +
                "start=\(record.start?.seconds ?? -1) duration=\(record.duration?.seconds ?? -1) bytes=\(record.bytes.count)")
        }
    }
}

/// Scalars hashed from each complete, contiguous native mdat payload span.
private struct SyntheticRawMediaSample {
    let start: ExactMediaTime
    let duration: ExactMediaTime
    let size: Int
    let digest: Data
}

/// Match every ordinal before deriving a constant reader-time translation.
/// Neither first-PTS coincidence nor a duration tolerance establishes coverage.
private struct SyntheticReaderByteTiming {
    struct ReaderSample {
        let size: Int
        let digest: Data
        let pts: CMTime
        let duration: CMTime
    }
    private(set) var frames = 0
    private var translation: ExactMediaTime?
    private var rawStart: ExactMediaTime?
    private var rawEnd: ExactMediaTime?
    private var readerEnd: ExactMediaTime?

    mutating func observe(raw: SyntheticRawMediaSample, reader: ReaderSample) throws {
        guard raw.size > 0, raw.size == reader.size, raw.digest.count == 32,
              raw.digest == reader.digest else {
            throw NSError(domain: "SyntheticReaderByteTiming", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Media payload identity differs at ordinal \(frames)"])
        }
        let start = try ExactMediaTime(reader.pts)
        let duration = try ExactMediaTime(reader.duration)
        let offset = try start.subtracting(raw.start)
        guard duration == raw.duration, duration.value > 0,
              translation == nil || translation == offset,
              rawEnd == nil || rawEnd == raw.start,
              readerEnd == nil || readerEnd == start else {
            throw NSError(domain: "SyntheticReaderByteTiming", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Media timing differs at ordinal \(frames): raw=\(raw.start) reader=\(start) offset=\(offset)"])
        }
        if rawStart == nil { rawStart = raw.start }
        rawEnd = try raw.start.adding(duration)
        readerEnd = try start.adding(duration)
        translation = offset
        frames += 1
    }

    struct Coverage {
        let rawStart: ExactMediaTime
        let rawEnd: ExactMediaTime
        let translation: ExactMediaTime

        func presentationTime(forRawTime time: ExactMediaTime) throws -> ExactMediaTime {
            guard try time.subtracting(rawStart).value >= 0,
                  try rawEnd.subtracting(time).value >= 0 else {
                throw NSError(domain: "SyntheticReaderByteTiming", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Endpoint lies outside complete byte-verified coverage"])
            }
            return try time.adding(translation)
        }

        func requirePresentationTime(_ time: ExactMediaTime, forRawTime rawTime: ExactMediaTime) throws {
            let expected = try presentationTime(forRawTime: rawTime)
            guard time == expected else {
                throw NSError(domain: "SyntheticReaderByteTiming", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Decoded PTS \(time) differs from byte-verified \(expected) for raw \(rawTime)"])
            }
        }
    }

    /// Mapping becomes available only after every expected ordinal and both raw
    /// endpoints have passed. A correct first sample cannot authorize a short tail.
    func coverage(expectedSamples: Int, rawStart expectedStart: ExactMediaTime,
                  rawEnd expectedEnd: ExactMediaTime) throws -> Coverage {
        guard expectedSamples > 0, frames == expectedSamples, rawStart == expectedStart,
              rawEnd == expectedEnd, let translation else {
            throw NSError(domain: "SyntheticReaderByteTiming", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete native/reader coverage: \(diagnostics)"])
        }
        return Coverage(rawStart: expectedStart, rawEnd: expectedEnd, translation: translation)
    }
    var diagnostics: String {
        "verifiedOrdinals=\(frames) translation=\(String(describing: translation)) " +
            "rawEnd=\(String(describing: rawEnd)) readerEnd=\(String(describing: readerEnd))"
    }
}

private struct SyntheticAACRawPCM {
    let statistics: SyntheticAACPCMStatistics
    let pcmSHA256: Data
    let format: AACASBD
}

/// Own exactly one compressed reader batch until the synchronous converter asks
/// for more input. Per-AU identity is checked against original native mdat bytes.
private final class SyntheticAACPacketInput {
    static let needsInputStatus: OSStatus = 0x76706E69
    let rawSamples: [SyntheticRawMediaSample]
    let sampleRate: Int32
    var timeline: SyntheticReaderByteTiming
    private var retained: CMSampleBuffer?
    private var pointer: UnsafeMutablePointer<Int8>?
    private var descriptions: UnsafePointer<AudioStreamPacketDescription>?
    private var count = 0
    private var index = 0
    private let supplied = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    var ended = false
    var sawEOS = false
    private(set) var firstDiagnostic = ""
    private(set) var lastDiagnostic = ""

    init(rawSamples: [SyntheticRawMediaSample], sampleRate: Int32) {
        self.rawSamples = rawSamples; self.sampleRate = sampleRate
        timeline = SyntheticReaderByteTiming()
        supplied.initialize(to: AudioStreamPacketDescription())
    }
    deinit { supplied.deinitialize(count: 1); supplied.deallocate() }

    static func diagnostics(_ sample: CMSampleBuffer) -> String {
        func trim(_ key: CFString) -> String {
            CMGetAttachment(sample, key: key, attachmentModeOut: nil).map { String(describing: $0) } ?? "absent"
        }
        return "count=\(CMSampleBufferGetNumSamples(sample)) " +
            "pts=\(CMSampleBufferGetPresentationTimeStamp(sample)) duration=\(CMSampleBufferGetDuration(sample)) " +
            "outputPTS=\(CMSampleBufferGetOutputPresentationTimeStamp(sample)) " +
            "outputDuration=\(CMSampleBufferGetOutputDuration(sample)) " +
            "trimStart=\(trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart)) " +
            "trimEnd=\(trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd))"
    }

    func install(_ sample: CMSampleBuffer) throws {
        guard retained == nil, !ended else { throw AACRenditionFailure.invalidInput }
        let diagnostic = Self.diagnostics(sample)
        if firstDiagnostic.isEmpty { firstDiagnostic = diagnostic }
        lastDiagnostic = diagnostic
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let packetCount = CMSampleBufferGetNumSamples(sample)
        guard packetCount > 0, packetCount <= rawSamples.count - timeline.frames else {
            throw AACRenditionFailure.capacityExceeded
        }
        var descriptionBytes = 0, contiguousBytes = 0, totalBytes = 0
        try AACRenditionEncoder.check(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample,
            packetDescriptionsPointerOut: &descriptions, sizeOut: &descriptionBytes))
        try AACRenditionEncoder.check(CMBlockBufferGetDataPointer(block, atOffset: 0,
            lengthAtOffsetOut: &contiguousBytes, totalLengthOut: &totalBytes, dataPointerOut: &pointer))
        let expectedBytes = rawSamples[timeline.frames..<(timeline.frames + packetCount)].reduce(0) { $0 + Int($1.size) }
        guard totalBytes == expectedBytes, contiguousBytes == totalBytes,
              descriptionBytes == packetCount * MemoryLayout<AudioStreamPacketDescription>.stride,
              let pointer, let descriptions,
              CMTimeCompare(CMSampleBufferGetDuration(sample),
                CMTime(value: Int64(packetCount) * 1_024, timescale: sampleRate)) == 0 else {
            throw AACRenditionFailure.invalidInput
        }
        var offset = 0
        for position in 0..<packetCount {
            let description = descriptions[position]
            let size = Int(description.mDataByteSize)
            guard description.mStartOffset == Int64(offset), size > 0, size <= totalBytes - offset,
                  description.mVariableFramesInPacket == 0 || description.mVariableFramesInPacket == 1_024 else {
                throw AACRenditionFailure.invalidInput
            }
            var hash = SHA256()
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: pointer.advanced(by: offset), count: size))
            let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample),
                CMTime(value: Int64(position) * 1_024, timescale: sampleRate))
            try timeline.observe(raw: rawSamples[timeline.frames], reader: .init(size: size,
                digest: Data(hash.finalize()), pts: pts, duration: CMTime(value: 1_024, timescale: sampleRate)))
            offset += size
        }
        guard offset == totalBytes else { throw AACRenditionFailure.invalidInput }
        retained = sample; count = packetCount; index = 0
    }

    func provide(_ packetCount: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>,
        outputDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        packetCount.pointee = 0
        data.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer())
        outputDescriptions?.pointee = nil
        if index == count {
            retained = nil; pointer = nil; descriptions = nil; count = 0; index = 0
            if ended { sawEOS = true; return noErr }
            return Self.needsInputStatus
        }
        guard let pointer, let descriptions else { return kAudio_ParamError }
        let original = descriptions[index]
        supplied.pointee = original
        supplied.pointee.mStartOffset = 0
        packetCount.pointee = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: 0, mDataByteSize: original.mDataByteSize,
            mData: UnsafeMutableRawPointer(pointer.advanced(by: Int(original.mStartOffset))))
        outputDescriptions?.pointee = supplied
        index += 1
        return noErr
    }
}

private func syntheticAACPacketInput(_ converter: AudioConverterRef, _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>, _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { packetCount.pointee = 0; return kAudio_ParamError }
    return Unmanaged<SyntheticAACPacketInput>.fromOpaque(context).takeUnretainedValue().provide(
        packetCount, data: data, outputDescriptions: descriptions)
}

private struct SyntheticAACPCMStatistics {
    let sampleRate: Int32
    var frames = 0
    var maximumGapSamples = 0.0
    var silentWindows = 0
    var minimumRMS = Double.infinity
    var silentShortWindows = 0
    var minimumShortRMS = Double.infinity
    private var shortWindowSamples = 0
    private var shortWindowPower = 0.0
    private var observedSamples = 0
    private var pendingShortWindows: [(end: Double, rms: Double)] = []
    var checkedShortWindows = 0
    var checkedStartupWindows = 0
    var silentStartupWindows = 0
    var minimumStartupRMS = Double.infinity
    private let startupLeadingFrames: Int?
    private var startupWindowPower = 0.0
    private var startupWindowSamples = 0
    var silentWindowEndTimes: [Double] = []
    private(set) var firstPresentationTime: CMTime?
    var endPresentationTime: CMTime? { previousEnd }
    private var previousEnd: CMTime?
    private var windowSamples = 0
    private var windowPower = 0.0

    init(sampleRate: Int32 = 48_000, startupLeadingFrames: Int? = nil) {
        self.sampleRate = sampleRate
        self.startupLeadingFrames = startupLeadingFrames
    }

    mutating func consume(_ sample: CMSampleBuffer) throws {
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        XCTAssertEqual(asbd.mSampleRate, Double(sampleRate))
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBitsPerChannel, 32)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
        let count = CMSampleBufferGetNumSamples(sample)
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        XCTAssertTrue(start.isNumeric)
        if firstPresentationTime == nil { firstPresentationTime = start }
        if let previousEnd {
            maximumGapSamples = max(maximumGapSamples, abs(CMTimeSubtract(start, previousEnd).seconds * Double(sampleRate)))
        }
        previousEnd = CMTimeAdd(start, CMTime(value: Int64(count), timescale: sampleRate))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        XCTAssertEqual(length, count * 2 * MemoryLayout<Float>.stride)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw AACRenditionFailure.framework(status) }
        var nonfiniteSamples = 0
        data.withUnsafeBytes { bytes in
            for index in 0..<(length / MemoryLayout<Float>.stride) {
                let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
                if !value.isFinite { nonfiniteSamples += 1 }
                let power = Double(value) * Double(value)
                windowPower += power
                windowSamples += 1
                shortWindowPower += power
                shortWindowSamples += 1
                if let leading = startupLeadingFrames {
                    let frame = observedSamples / 2 - leading
                    let windowFrames = Int(sampleRate / 200)
                    // Raw decoder ordinals are byte-verified. Exclude only the
                    // actual encoder leading trim and the first 5 ms of codec onset.
                    if frame >= windowFrames, frame < Int(sampleRate / 10) {
                        startupWindowPower += power
                        startupWindowSamples += 1
                        if startupWindowSamples == windowFrames * 2 {
                            let rms = sqrt(startupWindowPower / Double(startupWindowSamples))
                            checkedStartupWindows += 1
                            minimumStartupRMS = min(minimumStartupRMS, rms)
                            if rms < 0.001 { silentStartupWindows += 1 }
                            startupWindowPower = 0
                            startupWindowSamples = 0
                        }
                    }
                }
                observedSamples += 1
                if shortWindowSamples == Int((Double(sampleRate) / 200).rounded()) * 2 {
                    let seconds = Double(observedSamples) / (2 * Double(sampleRate))
                    if seconds >= 0.255 {
                        let rms = sqrt(shortWindowPower / Double(shortWindowSamples))
                        pendingShortWindows.append((seconds, rms))
                        // Hold the actual last 250 ms until EOF. AC3 source padding
                        // and final AAC padding are not recurring interior mutes.
                        if pendingShortWindows.count > 50 {
                            let interior = pendingShortWindows.removeFirst()
                            checkedShortWindows += 1
                            minimumShortRMS = min(minimumShortRMS, interior.rms)
                            if interior.rms < 0.001 {
                                silentShortWindows += 1
                                if silentWindowEndTimes.count < 128 { silentWindowEndTimes.append(interior.end) }
                            }
                        }
                    }
                    shortWindowSamples = 0
                    shortWindowPower = 0
                }
                if windowSamples == Int(sampleRate / 10) * 2 {
                    let rms = sqrt(windowPower / Double(windowSamples))
                    minimumRMS = min(minimumRMS, rms)
                    if rms < 0.001 { silentWindows += 1 }
                    windowSamples = 0
                    windowPower = 0
                }
            }
        }
        XCTAssertEqual(nonfiniteSamples, 0)
        frames += count
    }
}

/// Read-only facts from actual Apple fragments; this helper never rewrites bytes.
private enum SyntheticAACFragmentInspector {
    struct Facts {
        let sequence: UInt32
        let decodeTime: UInt64
        let sampleCount: UInt64
    }
    struct Box {
        let type: String
        let start: Int
        let payload: Int
        let end: Int
    }

    static func boxes(_ bytes: Data, from start: Int = 0, through end: Int? = nil) throws -> [Box] {
        let end = end ?? bytes.count
        var offset = start
        var result: [Box] = []
        while offset < end {
            guard offset + 8 <= end, result.count < 128 else { throw AACRenditionFailure.invalidInput }
            let size32 = read32(bytes, offset)
            let header = size32 == 1 ? 16 : 8
            guard offset + header <= end else { throw AACRenditionFailure.invalidInput }
            let size64 = size32 == 1 ? read64(bytes, offset + 8) : UInt64(size32 == 0 ? end - offset : Int(size32))
            guard let size = Int(exactly: size64), size >= header, size <= end - offset else {
                throw AACRenditionFailure.invalidInput
            }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Box(type: type, start: offset, payload: offset + header, end: offset + size))
            offset += size
        }
        return result
    }

    static func inspect(_ record: SyntheticAACContinuityCapture.Record, label: String = "AC3_FRAGMENT") throws -> Facts {
        let top = try boxes(record.bytes)
        guard top.filter({ $0.type == "moof" }).count == 1,
              top.filter({ $0.type == "mdat" }).count == 1 else {
            throw AACRenditionFailure.invalidInput
        }
        let moof = try XCTUnwrap(top.first { $0.type == "moof" })
        let children = try boxes(record.bytes, from: moof.payload, through: moof.end)
        guard children.filter({ $0.type == "traf" }).count == 1 else {
            throw AACRenditionFailure.invalidInput
        }
        let mfhd = try XCTUnwrap(children.first { $0.type == "mfhd" })
        let traf = try XCTUnwrap(children.first { $0.type == "traf" })
        let track = try boxes(record.bytes, from: traf.payload, through: traf.end)
        let tfdt = try XCTUnwrap(track.first { $0.type == "tfdt" })
        guard mfhd.payload + 8 <= mfhd.end, tfdt.payload + 8 <= tfdt.end,
              record.bytes[tfdt.payload] <= 1 else { throw AACRenditionFailure.invalidInput }
        let decodeTime: UInt64
        if record.bytes[tfdt.payload] == 1 {
            guard tfdt.payload + 12 <= tfdt.end else { throw AACRenditionFailure.invalidInput }
            decodeTime = read64(record.bytes, tfdt.payload + 4)
        } else { decodeTime = UInt64(read32(record.bytes, tfdt.payload + 4)) }
        let runs = track.filter { $0.type == "trun" }
        guard !runs.isEmpty else { throw AACRenditionFailure.invalidInput }
        var count: UInt64 = 0
        for run in runs {
            guard run.payload + 8 <= run.end else { throw AACRenditionFailure.invalidInput }
            count += UInt64(read32(record.bytes, run.payload + 4))
        }
        let sequence = read32(record.bytes, mfhd.payload + 4)
        print("\(label) sequence=\(record.sequence) top=\(top.map(\.type).joined(separator: ",")) " +
            "mfhd=\(sequence) tfdt=\(decodeTime) samples=\(count)")
        return Facts(sequence: sequence, decodeTime: decodeTime, sampleCount: count)
    }

    /// These fixtures have one track and no reordered pictures or AAC composition offsets.
    /// Read actual native durations/sizes and zero CTS before treating tfdt as PTS.
    /// Every mdat byte belongs to exactly one ordinal; no FPS-derived duration or
    /// first-reader timestamp participates in this independent raw evidence.
    static func unreorderedSamples(initialization: Data, media: Data, timescale: Int32,
                             maximumSamples: Int) throws -> [SyntheticRawMediaSample] {
        func invalid(_ reason: String) -> NSError {
            NSError(domain: "SyntheticSingleTrackFragment", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
        func one(_ type: String, _ children: [Box]) throws -> Box {
            let matches = children.filter { $0.type == type }
            guard matches.count == 1 else { throw invalid("Missing or duplicate \(type)") }
            return matches[0]
        }
        guard timescale > 0, maximumSamples > 0, maximumSamples <= 1_024,
              initialization.count <= 8 * 1_024 * 1_024, media.count <= 8 * 1_024 * 1_024 else {
            throw invalid("Single-track inspection exceeds its fixture bounds")
        }
        let moov = try one("moov", boxes(initialization))
        let movie = try boxes(initialization, from: moov.payload, through: moov.end)
        let trak = try one("trak", movie)
        let track = try boxes(initialization, from: trak.payload, through: trak.end)
        let tkhd = try one("tkhd", track)
        let mdia = try one("mdia", track)
        let mdhd = try one("mdhd", boxes(initialization, from: mdia.payload, through: mdia.end))
        let mvex = try one("mvex", movie)
        let trex = try one("trex", boxes(initialization, from: mvex.payload, through: mvex.end))
        guard tkhd.payload + 4 <= tkhd.end, mdhd.payload + 4 <= mdhd.end,
              initialization[tkhd.payload] <= 1, initialization[mdhd.payload] <= 1,
              tkhd.end - tkhd.payload == (initialization[tkhd.payload] == 0 ? 84 : 96),
              mdhd.end - mdhd.payload == (initialization[mdhd.payload] == 0 ? 24 : 36),
              trex.end - trex.payload == 24, read32(initialization, trex.payload) == 0 else {
            throw invalid("Unsupported single-track initialization headers")
        }
        let trackID = read32(initialization, tkhd.payload + (initialization[tkhd.payload] == 0 ? 12 : 20))
        let scale = read32(initialization, mdhd.payload + (initialization[mdhd.payload] == 0 ? 12 : 20))
        guard trackID > 0, trackID == read32(initialization, trex.payload + 4),
              read32(initialization, trex.payload + 8) == 1, scale == UInt32(timescale) else {
            throw invalid("Single-track track identity or timescale differs from initialization")
        }
        var defaultDuration = read32(initialization, trex.payload + 12)
        var defaultSize = read32(initialization, trex.payload + 16)
        let top = try boxes(media)
        let moof = try one("moof", top)
        let mdat = try one("mdat", top)
        guard moof.end <= mdat.start else { throw invalid("Single-track mdat precedes its moof") }
        let children = try boxes(media, from: moof.payload, through: moof.end)
        let mfhd = try one("mfhd", children)
        let traf = try one("traf", children)
        let fragmentTrack = try boxes(media, from: traf.payload, through: traf.end)
        let tfhd = try one("tfhd", fragmentTrack)
        let tfdt = try one("tfdt", fragmentTrack)
        guard mfhd.end - mfhd.payload == 8, read32(media, mfhd.payload) == 0,
              read32(media, mfhd.payload + 4) > 0, tfhd.end - tfhd.payload >= 8,
              media[tfhd.payload] == 0, read32(media, tfhd.payload + 4) == trackID,
              tfdt.end - tfdt.payload >= 8, media[tfdt.payload] <= 1,
              read32(media, tfdt.payload) & 0x00ff_ffff == 0,
              tfdt.end - tfdt.payload == (media[tfdt.payload] == 0 ? 8 : 12) else {
            throw invalid("Unsupported single-track fragment headers")
        }
        let tfhdFlags = read32(media, tfhd.payload) & 0x00ff_ffff
        // One traf uses its moof as the implicit or explicit default base.
        // Absolute bases and duration-is-empty are outside these finite fixtures.
        guard tfhdFlags & ~UInt32(0x02003a) == 0 else { throw invalid("Unsupported single-track tfhd flags") }
        var headerPosition = tfhd.payload + 8
        func headerField() throws -> UInt32 {
            guard headerPosition + 4 <= tfhd.end else { throw invalid("Truncated single-track tfhd field") }
            defer { headerPosition += 4 }
            return read32(media, headerPosition)
        }
        if tfhdFlags & 2 != 0, try headerField() != 1 { throw invalid("Unexpected single-track sample description") }
        if tfhdFlags & 8 != 0 { defaultDuration = try headerField() }
        if tfhdFlags & 0x10 != 0 { defaultSize = try headerField() }
        if tfhdFlags & 0x20 != 0 { _ = try headerField() }
        guard headerPosition == tfhd.end else { throw invalid("Trailing single-track tfhd fields") }
        let baseTime = media[tfdt.payload] == 0 ? UInt64(read32(media, tfdt.payload + 4)) : read64(media, tfdt.payload + 4)
        guard var decodeTime = Int64(exactly: baseTime) else { throw invalid("Single-track tfdt exceeds exact time bounds") }
        let runs = fragmentTrack.filter { $0.type == "trun" }
        guard !runs.isEmpty else { throw invalid("Missing single-track sample run") }
        var result: [SyntheticRawMediaSample] = []
        var payloadPosition = mdat.payload
        var runDataPosition: Int?
        for run in runs {
            guard run.end - run.payload >= 8, media[run.payload] <= 1 else { throw invalid("Unsupported single-track trun") }
            let flags = read32(media, run.payload) & 0x00ff_ffff
            let count = Int(read32(media, run.payload + 4))
            guard flags & ~UInt32(0x000f05) == 0, flags & 4 == 0 || flags & 0x400 == 0,
                  count > 0, count <= maximumSamples - result.count else {
                throw invalid("Single-track trun flags or count exceed bounds")
            }
            var position = run.payload + 8
            if flags & 1 != 0 {
                guard position + 4 <= run.end else { throw invalid("Truncated single-track data offset") }
                let offset = Int(Int32(bitPattern: read32(media, position)))
                let sum = moof.start.addingReportingOverflow(offset)
                guard !sum.overflow else { throw invalid("Single-track data offset overflow") }
                runDataPosition = sum.partialValue
                position += 4
            }
            if flags & 4 != 0 { position += 4 }
            let fields = (flags & 0x100 != 0 ? 1 : 0) + (flags & 0x200 != 0 ? 1 : 0) +
                (flags & 0x400 != 0 ? 1 : 0) + (flags & 0x800 != 0 ? 1 : 0)
            guard position <= run.end, count * fields * 4 == run.end - position,
                  runDataPosition == payloadPosition else { throw invalid("Single-track trun fields or mdat span are incomplete") }
            for _ in 0..<count {
                let duration = flags & 0x100 == 0 ? defaultDuration : read32(media, position)
                if flags & 0x100 != 0 { position += 4 }
                let size = flags & 0x200 == 0 ? defaultSize : read32(media, position)
                if flags & 0x200 != 0 { position += 4 }
                if flags & 0x400 != 0 { position += 4 }
                if flags & 0x800 != 0 {
                    guard read32(media, position) == 0 else { throw invalid("Single-track fixture has reordered presentation timestamps") }
                    position += 4
                }
                guard duration > 0, size > 0, payloadPosition <= mdat.end,
                      Int(size) <= mdat.end - payloadPosition else { throw invalid("Invalid single-track sample duration or size") }
                let payloadEnd = payloadPosition + Int(size)
                let end = decodeTime.addingReportingOverflow(Int64(duration))
                guard !end.overflow else { throw invalid("Single-track sample timestamp overflow") }
                let digest = media.withUnsafeBytes { bytes in
                    Data(SHA256.hash(data: UnsafeRawBufferPointer(rebasing: bytes[payloadPosition..<payloadEnd])))
                }
                result.append(.init(start: .init(value: decodeTime, timescale: timescale),
                    duration: .init(value: Int64(duration), timescale: timescale), size: Int(size), digest: digest))
                decodeTime = end.partialValue
                payloadPosition = payloadEnd
                runDataPosition = payloadEnd
            }
        }
        guard payloadPosition == mdat.end else { throw invalid("Unaccounted single-track mdat bytes") }
        return result
    }

    private static func read32(_ bytes: Data, _ offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }
    private static func read64(_ bytes: Data, _ offset: Int) -> UInt64 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
    }
}
