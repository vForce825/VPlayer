// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

/// Task 10 的 controller/Registry 接线审查测试。
///
/// 这里仅替换 AudioSession SDK 与 backend SDK 边界；路由、资源所有权、终态和
/// presentation 发布仍走生产 Controller/Registry。测试故意在旧 backend 的退休确认处
/// 设闸，以区分“先撤 UI 所有权”与“等 teardown 完成后才顺手清 UI”。
final class Task10ControllerReviewTests: XCTestCase {
    func testFirstPlayAudioSessionFailureBeforeLateSubscriptionReplaysTerminalNilThenEOF() async throws {
        let fixture = try Task10ControllerFixture()
        fixture.sdk.activateError = NSError(
            domain: "Task10ControllerReviewTests.AudioSession",
            code: -10
        )

        await fixture.start()
        try await requireEventually("首次 AudioSession acquisition 失败未发布失败态") {
            if case .failed = await fixture.controller.currentStateForTesting { return true }
            return false
        }
        // 故意等 producer 的失败/cleanup 尾先完成，随后才建立首个 presentation
        // subscription，覆盖“终态早于订阅”的真实 VM 调用顺序。
        for _ in 0..<50 { await Task.yield() }

        let probe = try await fixture.presentationProbe()
        try await requireEventually("迟到订阅必须先重放 terminal nil") {
            probe.snapshot.replacements.contains { $0.desired == nil }
        }
        try await requireEventually("迟到订阅在 terminal nil 后必须 EOF") {
            probe.snapshot.reachedEOF
        }

        probe.cancel()
        await fixture.controller.stop()
    }

    func testAutomaticControlTerminalAndAudioSessionFailurePublishNilBeforeTeardownThenEOF() async throws {
        for trigger in Task10TerminalTrigger.allCases {
            let allocator = trigger == .controlIdentityExhaustion
                ? PlaybackIdentityAllocator(initialIssuedValue: .max, initialNamespace: .systemEvent)
                : PlaybackIdentityAllocator()
            let fixture = try Task10ControllerFixture(allocator: allocator)
            await fixture.start()
            let backend = try XCTUnwrap(fixture.factory.createdBackends.first)
            backend.setHoldStop(true)
            let probe = try await fixture.presentationProbe()
            try await requireEventually("初始 presentation 未发布") {
                probe.snapshot.replacements.last?.desired != nil
            }

            switch trigger {
            case .controlIdentityExhaustion:
                fixture.owner.monitor.emit(.interruptionBegan)
            case .audioSessionRecoveryFailure:
                fixture.owner.monitor.emit(.recoveryFailed(stage: .mediaServicesResetActivation))
            }

            try await requireEventually("原 backend 未进入退休") {
                backend.retirementSnapshot.count == 1
            }
            try await requireEventually("teardown 闸门仍关闭时必须先发布 terminal nil") {
                probe.snapshot.replacements.dropFirst().contains(where: { $0.desired == nil })
            }
            XCTAssertTrue(
                probe.snapshot.reachedEOF,
                "terminal顺序是nil后EOF，两者都必须早于backend退休确认"
            )

            backend.confirmStop()
            try await requireEventually("terminal nil 之后 presentation stream 必须 EOF") {
                probe.snapshot.reachedEOF
            }
            XCTAssertEqual(backend.retirementSnapshot.count, 1)
            probe.cancel()
        }
    }

    func testInterruptionBeganPublishesNilBeforeOwnerRetiresButKeepsStreamForVetoedSuccessor() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let first = try XCTUnwrap(fixture.factory.createdBackends.first)
        first.setHoldStop(true)
        let probe = try await fixture.presentationProbe()
        try await requireEventually("初始 presentation 未发布") {
            probe.snapshot.replacements.last?.desired != nil
        }
        let firstIdentity = try XCTUnwrap(probe.snapshot.replacements.last?.desired?.identity)

        fixture.owner.monitor.emit(.interruptionBegan)
        try await requireEventually("interruption owner 未开始退休旧 backend") {
            first.retirementSnapshot.count == 1
        }
        try await requireEventually("旧 owner 退休确认前必须发布 nil") {
            probe.snapshot.replacements.dropFirst().contains(where: { $0.desired == nil })
        }
        XCTAssertFalse(probe.snapshot.reachedEOF, "interruption 是 replacement，不是 presentation 终态")

        fixture.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        first.confirmStop()
        try await requireEventually("shouldResume=false 必须落到暂停态") {
            await fixture.controller.currentStateForTesting == .paused(fixture.request)
        }
        XCTAssertEqual(fixture.factory.createdBackends.count, 1, "veto 未解除前不得创建后继")
        XCTAssertFalse(probe.snapshot.reachedEOF)

        await fixture.controller.setPaused(false)
        try await requireEventually("显式 resume 后未创建后继 backend") {
            fixture.factory.createdBackends.count == 2
        }
        try await requireEventually("同一 stream 未继续发布后继 presentation") {
            guard let desired = probe.snapshot.replacements.last?.desired else { return false }
            return desired.identity != firstIdentity
        }
        XCTAssertFalse(probe.snapshot.reachedEOF)

        await fixture.controller.stop()
        probe.cancel()
    }

    func testMediaServicesResetPublishesNilBeforeOwnerRetiresThenPublishesDelayedSuccessor() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let first = try XCTUnwrap(fixture.factory.createdBackends.first)
        first.setHoldStop(true)
        let probe = try await fixture.presentationProbe()
        try await requireEventually("初始 presentation 未发布") {
            probe.snapshot.replacements.last?.desired != nil
        }
        let firstReplacement = try XCTUnwrap(probe.snapshot.replacements.last)
        let firstIdentity = try XCTUnwrap(firstReplacement.desired?.identity)

        fixture.owner.monitor.emit(.mediaServicesWereReset)
        try await requireEventually("reset owner 未开始退休旧 backend") {
            first.retirementSnapshot.count == 1
        }
        try await requireEventually("reset owner 退休确认前必须发布 nil") {
            probe.snapshot.replacements.contains {
                $0.revision > firstReplacement.revision && $0.desired == nil
            }
        }
        XCTAssertFalse(probe.snapshot.reachedEOF, "reset recovery 必须保留原 subscription")
        XCTAssertEqual(fixture.factory.createdBackends.count, 1, "旧输出未静止前不得创建后继")

        first.confirmStop()
        try await requireEventually("旧输出确认后未创建 reset 后继") {
            fixture.factory.createdBackends.count == 2
        }
        try await requireEventually("reset 后继未在原 stream 发布") {
            guard let latest = probe.snapshot.replacements.last,
                  let desired = latest.desired else { return false }
            return latest.revision > firstReplacement.revision && desired.identity != firstIdentity
        }
        XCTAssertFalse(probe.snapshot.reachedEOF)

        await fixture.controller.stop()
        probe.cancel()
    }

    func testSubscriptionIdentityExhaustionReturnsOnlyAfterSynchronousRevocationAndSingleTerminalOwner() async throws {
        let allocator = PlaybackIdentityAllocator(
            initialIssuedValue: .max,
            initialNamespace: .subscription
        )
        let fixture = try Task10ControllerFixture(allocator: allocator)
        await fixture.start()
        let backend = try XCTUnwrap(fixture.factory.createdBackends.first)
        backend.setHoldStop(true)
        let originalReservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        XCTAssertTrue(fixture.registry.executor.safetyIngress.snapshot.outputPermitPresent)

        do {
            _ = try await fixture.controller.presentations()
            XCTFail("subscription generation 耗尽必须明确失败")
        } catch {
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .identitySpaceExhausted)
        }

        // 这些断言刻意不 poll/yield：presentations() 把错误交给 caller 时，Cell 必须已经
        // fail-closed，不能只依赖 transaction 尾部异步 signalOwnedEventDrain。
        let safety = fixture.registry.executor.safetyIngress.snapshot
        XCTAssertEqual(safety.failure, .identitySpaceExhausted)
        XCTAssertFalse(safety.outputPermitPresent)
        XCTAssertFalse(safety.readinessOpen)
        let terminalContext = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertTrue(terminalContext.poisoned)
        XCTAssertEqual(terminalContext.disposition, .releaseAfterTeardown)
        XCTAssertEqual(terminalContext.owner?.identity, originalReservation.terminalOwner)
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, originalReservation.ticket)

        do {
            _ = try await fixture.controller.presentations()
            XCTFail("terminal relay 不得重新开放 subscription")
        } catch {
            XCTAssertEqual(error as? PlaybackPresentationRelayError, .terminal)
        }
        XCTAssertEqual(
            fixture.registry.outputResourceContextSnapshot()?.owner?.identity,
            originalReservation.terminalOwner,
            "重复入口只能 join 原 automatic terminal owner"
        )
        try await requireEventually("automatic terminal owner 未启动唯一 backend 退休") {
            backend.retirementSnapshot.count == 1
        }
        XCTAssertEqual(backend.retirementSnapshot.count, 1)

        backend.confirmStop()
        try await requireEventually("耗尽后的原 terminal owner 未完成清理") {
            fixture.registry.cleanupReservationSnapshot() == nil
        }
    }

    func testSafetyIngressAndFinalPresentationFenceHaveDeterministicCommitOrder() async throws {
        // Safety 先赢：final fence 必须先消费 pending reset，再校验 installed/prepared context；
        // 旧 projection 不能被提交给独立 relay。目标 API 尚未存在时，本测试应编译 RED。
        let safetyFirst = try Task10ControllerFixture()
        await safetyFirst.start()
        let rejectedRelay = PlaybackPresentationRelay(allocator: safetyFirst.registry.allocator)
        let rejectedProbe = Task10PresentationProbe(stream: try rejectedRelay.presentations())
        safetyFirst.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)

        let committedAfterReset = try safetyFirst.registry.commitInstalledPresentation(to: rejectedRelay)

        XCTAssertEqual(committedAfterReset, .supersededBySafety)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(rejectedProbe.snapshot.replacements.contains(where: { $0.desired != nil }))
        rejectedProbe.cancel()
        await safetyFirst.controller.stop()

        // Publish 先赢：后到 reset 必须以更高 revision 发布 nil；即使旧 delivery 延迟，
        // 最终也不能让低 revision 的 nonnil 覆盖 terminal/replacement nil。
        let publishFirst = try Task10ControllerFixture()
        await publishFirst.start()
        let first = try XCTUnwrap(publishFirst.factory.createdBackends.first)
        first.setHoldStop(true)
        let acceptedProbe = try await publishFirst.presentationProbe()
        try await requireEventually("publish-first 缺初始 nonnil") {
            acceptedProbe.snapshot.replacements.last?.desired != nil
        }
        let accepted = try XCTUnwrap(acceptedProbe.snapshot.replacements.last)

        publishFirst.owner.monitor.emit(.mediaServicesWereReset)
        try await requireEventually("后到 reset 未以更高 revision 清 presentation") {
            acceptedProbe.snapshot.replacements.contains {
                $0.revision > accepted.revision && $0.desired == nil
            }
        }
        XCTAssertNil(acceptedProbe.snapshot.replacements.last?.desired)
        first.confirmStop()
        await publishFirst.controller.stop()
        acceptedProbe.cancel()
    }

    func testPrepareFinalCommitPreemptedByResetOrInterruptionHandsOffWithoutDemuxTerminal() async throws {
        for scenario in Task10PreparePreemptionScenario.allCases {
            let fixture = try Task10ControllerFixture()
            let oneShot = Task10OneShot()
            let monitor = fixture.owner.monitor
            await fixture.controller.setBeforePresentationCommitForTesting {
                guard oneShot.take() else { return }
                monitor.emit(scenario.event)
            }

            await fixture.start()
            switch await fixture.controller.currentStateForTesting {
            case let .failed(failure):
                let diagnostic = failure.diagnosticCode ?? "nil"
                XCTFail(
                    "\(scenario)合法抢占被误报终态：\(failure.code)/\(diagnostic)"
                )
            default:
                break
            }

            switch scenario {
            case .reset:
                try await requireEventually("reset recovery owner未继续创建后继backend") {
                    fixture.factory.createdBackends.count >= 2
                }
            case .interruption:
                fixture.owner.monitor.emit(.interruptionEnded(shouldResume: false))
                try await requireEventually("interruption veto未落到可恢复暂停态") {
                    await fixture.controller.currentStateForTesting == .paused(fixture.request)
                }
                await fixture.controller.setPaused(false)
                try await requireEventually("interruption recovery owner未继续创建后继backend") {
                    fixture.factory.createdBackends.count >= 2
                }
            }

            if case let .failed(failure) = await fixture.controller.currentStateForTesting {
                XCTFail("recovery后不得产生demux terminal：\(failure)")
            }
            await fixture.controller.stop()
        }
    }

    func testSharedMountNonceExhaustionSynchronouslyFailsClosedAndJoinsOneAutomaticOwner() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let backend = try XCTUnwrap(fixture.factory.createdBackends.first)
        backend.setHoldStop(true)
        let original = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let probe = try await fixture.presentationProbe()
        try await requireEventually("初始presentation未发布") {
            probe.snapshot.replacements.last?.desired != nil
        }
        let replacement = try XCTUnwrap(probe.snapshot.replacements.last)
        fixture.registry.allocator.setIssuedValueForTesting(.max, in: .nonce)

        let claim = await fixture.controller.claimPresentationMountOwnership(for: replacement)

        XCTAssertEqual(claim, .exhausted)
        let safety = fixture.registry.executor.safetyIngress.snapshot
        XCTAssertEqual(safety.failure, .identitySpaceExhausted)
        XCTAssertFalse(safety.outputPermitPresent)
        XCTAssertFalse(safety.readinessOpen)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned)
        XCTAssertEqual(context.disposition, .releaseAfterTeardown)
        XCTAssertEqual(context.owner?.identity, original.terminalOwner)
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, original.ticket)

        _ = await fixture.controller.claimPresentationMountOwnership(for: replacement)
        XCTAssertEqual(
            fixture.registry.outputResourceContextSnapshot()?.owner?.identity,
            original.terminalOwner,
            "重复mount耗尽只能join原automatic terminal owner"
        )
        try await requireEventually("mount耗尽未启动唯一backend退休") {
            backend.retirementSnapshot.count == 1
        }
        XCTAssertEqual(backend.retirementSnapshot.count, 1)
        backend.confirmStop()
        probe.cancel()
    }

    func testAutomaticTerminalDeliveryCompletesBeforeBackendRetireEntry() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let backend = try XCTUnwrap(fixture.factory.createdBackends.first)
        backend.setHoldStop(true)
        let probe = try await fixture.presentationProbe()
        try await requireEventually("初始presentation未发布") {
            probe.snapshot.replacements.last?.desired != nil
        }
        let oracle = Task10TerminalEffectOracle()
        await fixture.controller.setPresentationRelayDeliveryHooksForTesting(after: {
            _, terminal in
            if terminal { oracle.recordTerminalNilAndEOFEffect() }
        })
        backend.setRetireEntryObserver {
            oracle.recordBackendRetireEntry()
        }

        fixture.owner.monitor.emit(.recoveryFailed(stage: .mediaServicesResetActivation))

        try await requireEventually("backend未进入retire入口") {
            backend.retirementSnapshot.count == 1
        }
        XCTAssertTrue(oracle.snapshot.retireEntered)
        XCTAssertFalse(
            oracle.snapshot.retireEnteredBeforeTerminalEffect,
            "backend SDK retire入口不得早于terminal nil yield和stream finish"
        )
        backend.confirmStop()
        probe.cancel()
    }

    func testPlaybackEngineCompatibilityRequiresSeparatePresentationCapabilityWithoutNoOpSafetyDefaults() throws {
        let source = try String(contentsOf: task10SourceURL(
            "Sources/VPlayerPlayback/PlaybackContracts.swift"
        ), encoding: .utf8)
        let engineBody = try XCTUnwrap(task10ProtocolBody(named: "PlaybackEngine", in: source))
        let extensionBody = try XCTUnwrap(task10ExtensionBody(named: "PlaybackEngine", in: source))

        XCTAssertTrue(
            source.contains("protocol PlaybackPresentationControlling"),
            "presentation订阅与挂载撤权必须拆成细分capability，旧PlaybackEngine conformer才能继续工作"
        )
        XCTAssertFalse(engineBody.contains("claimPresentationMountOwnership"))
        XCTAssertFalse(engineBody.contains("failPresentationControl"))
        XCTAssertFalse(
            extensionBody.contains("claimPresentationMountOwnership") ||
                extensionBody.contains("failPresentationControl"),
            "两个安全方法不得靠PlaybackEngine默认no-op伪造源码兼容"
        )
    }

    func testMountClaimCapabilityCarriesCompleteReplacementEnvelopeIntoAuthorityFence() throws {
        let contracts = try String(contentsOf: task10SourceURL(
            "Sources/VPlayerPlayback/PlaybackContracts.swift"
        ), encoding: .utf8)
        let registry = try String(contentsOf: task10SourceURL(
            "Sources/VPlayerPlayback/Control/ControlTaskRegistry.swift"
        ), encoding: .utf8)
        let viewModel = try String(contentsOf: task10SourceURL(
            "Sources/VPlayerApp/Player/FullScreenPlayerViewModel.swift"
        ), encoding: .utf8)

        XCTAssertTrue(
            contracts.contains(
                "claimPresentationMountOwnership(for replacement: PlaybackPresentationReplacement)"
            ),
            "mount capability必须接收完整replacement envelope，而不是只签一个无上下文nonce"
        )
        XCTAssertTrue(registry.contains("claimPresentationMountOwnership(for replacement:"))
        XCTAssertTrue(viewModel.contains("claimPresentationMountOwnership(for: replacement)"))
    }

    func testProjectionReplacementBypassIsNotCallableOutsideAuthoritativeRegistryFence() throws {
        let source = try String(contentsOf: task10SourceURL(
            "Sources/VPlayerPlayback/Rendering/PlaybackPresentationRelay.swift"
        ), encoding: .utf8)
        XCTAssertFalse(
            source.contains("func replace(withProjection"),
            "projection旁路会绕过Registry最终safety fence，必须删除或封闭为不可调用实现"
        )
    }
}

private enum Task10TerminalTrigger: CaseIterable {
    case controlIdentityExhaustion
    case audioSessionRecoveryFailure
}

final class Task10ControllerFixture: @unchecked Sendable {
    let registry: ControlTaskRegistry
    let sdk: FakeAudioSessionSDK
    let owner: PlaybackAudioSessionOwner
    let factory: HarnessBackendFactory
    let controller: PlaybackController
    let request: PlaybackRequest

    init(allocator: PlaybackIdentityAllocator = PlaybackIdentityAllocator()) throws {
        registry = ControlTaskRegistry(allocator: allocator)
        sdk = FakeAudioSessionSDK(initialPorts: [.hdmi])
        owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        factory = HarnessBackendFactory()
        let routeService = PlaybackAudioRouteService(registry: registry, owner: owner)
        controller = PlaybackController(
            registry: registry,
            audioSessionOwner: owner,
            routeService: routeService,
            backendFactory: factory
        )
        request = PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "task10-controller-review",
            streamURL: URL(string: "http://localhost/task10-review.ts")!,
            title: "Task 10 Controller Review"
        )
    }

    func start() async {
        await controller.play(request)
    }

    fileprivate func presentationProbe() async throws -> Task10PresentationProbe {
        let stream = try await controller.presentations()
        return Task10PresentationProbe(stream: stream)
    }
}

private enum Task10PreparePreemptionScenario: CaseIterable, CustomStringConvertible {
    case reset
    case interruption

    var event: PlaybackAudioSessionEvent {
        switch self {
        case .reset: .mediaServicesWereReset
        case .interruption: .interruptionBegan
        }
    }

    var description: String {
        switch self {
        case .reset: "reset"
        case .interruption: "interruption"
        }
    }
}

private final class Task10OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.withLock {
            guard available else { return false }
            available = false
            return true
        }
    }
}

private final class Task10TerminalEffectOracle: @unchecked Sendable {
    struct Snapshot {
        let retireEntered: Bool
        let retireEnteredBeforeTerminalEffect: Bool
    }

    private let lock = NSLock()
    private var terminalEffectCompleted = false
    private var retireEntered = false
    private var retireEnteredBeforeTerminalEffect = false

    func recordTerminalNilAndEOFEffect() {
        lock.withLock { terminalEffectCompleted = true }
    }

    func recordBackendRetireEntry() {
        lock.withLock {
            retireEntered = true
            if !terminalEffectCompleted { retireEnteredBeforeTerminalEffect = true }
        }
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                retireEntered: retireEntered,
                retireEnteredBeforeTerminalEffect: retireEnteredBeforeTerminalEffect
            )
        }
    }
}

private func task10SourceURL(_ relativePath: String) -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let source = candidate.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: source.path) { return source }
        candidate.deleteLastPathComponent()
    }
    return candidate.appendingPathComponent(relativePath)
}

private func task10ProtocolBody(named name: String, in source: String) -> String? {
    task10DeclarationBody(prefix: "public protocol \(name)", in: source)
}

private func task10ExtensionBody(named name: String, in source: String) -> String? {
    task10DeclarationBody(prefix: "public extension \(name)", in: source)
}

private func task10DeclarationBody(prefix: String, in source: String) -> String? {
    guard let declaration = source.range(of: prefix),
          let opening = source[declaration.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source.indices[opening...] {
        switch source[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return String(source[opening...index]) }
        default: break
        }
    }
    return nil
}

fileprivate final class Task10PresentationProbe: @unchecked Sendable {
    struct Snapshot {
        let replacements: [PlaybackPresentationReplacement]
        let reachedEOF: Bool
    }

    private let lock = NSLock()
    private var replacements: [PlaybackPresentationReplacement] = []
    private var reachedEOF = false
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<PlaybackPresentationReplacement>) {
        task = Task { [weak self] in
            for await replacement in stream {
                self?.lock.withLock { self?.replacements.append(replacement) }
            }
            self?.lock.withLock { self?.reachedEOF = true }
        }
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(replacements: replacements, reachedEOF: reachedEOF) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

private func requireEventually(
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<250 {
        if await predicate() { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail(message(), file: file, line: line)
}
