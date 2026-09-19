// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit
import Darwin
import ObjectiveC
import UIKit
import XCTest
@testable import VPlayer
@testable import VPlayerPlayback

/// Task10 的 review RED：宿主替换必须同步完成，presentation 运行时只允许一本 2KiB 账。
@MainActor
final class Task10PresentationHostCapacityTests: XCTestCase {
    func testProductionHostRemovesOldWrapperBeforeConstructingReplacementAndDoesNotDeduplicateDifferentContext() {
        let firstController = AVPlayerViewController()
        let secondController = AVPlayerViewController()
        let thirdController = AVPlayerViewController()
        let sampleContext = PlaybackPresentationContext()
        let sampleView = sampleContext.makeVideoView()
        var factoryCallCount = 0

        let host = PlaybackPresentationHostController(avPlayerControllerFactory: {
            switch factoryCallCount {
            case 0:
                factoryCallCount = 1
                return firstController
            case 1:
                XCTAssertNil(firstController.player, "构造B前必须先解除A的player")
                XCTAssertNil(firstController.parent, "构造B前必须先移除A的child关系")
                XCTAssertNil(firstController.view.superview, "构造B前必须先移除A的view")
                factoryCallCount = 2
                return secondController
            case 2:
                XCTAssertNil(sampleView.superview, "构造AVPlayer wrapper前必须先移除SampleBuffer view")
                factoryCallCount = 3
                return thirdController
            default:
                XCTFail("每次有效替换只能构造一个AVPlayerViewController")
                return AVPlayerViewController()
            }
        })
        host.loadViewIfNeeded()
        let first = identifiedAVPlayer(nonce: 1)
        let second = identifiedAVPlayer(nonce: 2)

        host.replace(with: first)
        XCTAssertTrue(firstController.parent === host)
        XCTAssertTrue(firstController.view.isDescendant(of: host.view))

        host.replace(with: second)
        XCTAssertEqual(factoryCallCount, 2)
        XCTAssertTrue(secondController.parent === host)
        XCTAssertTrue(secondController.view.isDescendant(of: host.view))

        let sharedIdentity = presentationIdentity(nonce: 3)
        host.replace(with: IdentifiedPlaybackPresentation(
            identity: sharedIdentity,
            presentation: .sampleBuffer(sampleContext)
        ))
        XCTAssertNil(secondController.parent)
        XCTAssertTrue(sampleView.isDescendant(of: host.view))

        let replacementContext = AVPlayerPresentationContext(player: AVPlayer())
        host.replace(with: IdentifiedPlaybackPresentation(
            identity: sharedIdentity,
            presentation: .avPlayer(replacementContext)
        ))

        XCTAssertEqual(factoryCallCount, 3, "相同identity但不同context仍必须更换wrapper")
        XCTAssertFalse(sampleView.isDescendant(of: host.view))
        XCTAssertTrue(thirdController.parent === host)
        XCTAssertTrue(thirdController.player === replacementContext.player)
        XCTAssertEqual(host.mountedIdentity, sharedIdentity)
    }

    func testLateAVPlayerDismantleOnlyDetachesItsExpectedController() {
        let context = AVPlayerPresentationContext(player: AVPlayer())
        let oldController = AVPlayerViewController()
        let currentController = AVPlayerViewController()
        let oldCoordinator = AVPlayerPlayerView.Coordinator(context: context)

        context.attach(to: oldController)
        context.attach(to: currentController)
        XCTAssertNil(oldController.player)
        XCTAssertTrue(currentController.player === context.player)

        AVPlayerPlayerView.dismantleUIViewController(
            oldController,
            coordinator: oldCoordinator
        )

        XCTAssertTrue(
            currentController.player === context.player,
            "迟到的A dismantle不得清除当前B"
        )
    }

    func testLateOuterHostDisconnectOnlyUninstallsItsExpectedHost() {
        let mount = PlaybackPresentationHostMount()
        let controllerA = AVPlayerViewController()
        let controllerB = AVPlayerViewController()
        let hostA = PlaybackPresentationHostController(
            avPlayerControllerFactory: { controllerA }
        )
        let hostB = PlaybackPresentationHostController(
            avPlayerControllerFactory: { controllerB }
        )
        hostA.loadViewIfNeeded()
        hostB.loadViewIfNeeded()
        let presentation = identifiedAVPlayer(nonce: 10)

        mount.connect(to: hostA)
        mount.attach(presentation)
        XCTAssertTrue(controllerA.parent === hostA)

        mount.connect(to: hostB)
        XCTAssertNil(controllerA.parent)
        XCTAssertTrue(controllerB.parent === hostB)
        XCTAssertTrue(controllerB.player === avPlayerContext(in: presentation)?.player)

        mount.disconnect(from: hostA)

        XCTAssertEqual(hostB.mountedIdentity, presentation.identity)
        XCTAssertTrue(controllerB.parent === hostB)
        XCTAssertTrue(
            controllerB.player === avPlayerContext(in: presentation)?.player,
            "迟到的外层A uninstall不得拆除当前B"
        )
    }

    func testOuterHostCoordinatorIsMountAndLateDismantleStillProtectsNewHost() {
        let mount = PlaybackPresentationHostMount()
        let coordinator = PlaybackPresentationHostView(mount: mount).makeCoordinator()
        XCTAssertTrue(coordinator === mount,
                      "SwiftUI coordinator必须直接复用既有mount，不得再分配包装对象")
        let hostA = PlaybackPresentationHostController()
        let hostB = PlaybackPresentationHostController()
        hostA.loadViewIfNeeded()
        hostB.loadViewIfNeeded()
        let presentation = identifiedAVPlayer(nonce: 11)
        mount.connect(to: hostA)
        mount.attach(presentation)
        mount.connect(to: hostB)

        PlaybackPresentationHostView.dismantleUIViewController(
            hostA, coordinator: coordinator)

        XCTAssertEqual(hostB.mountedIdentity, presentation.identity,
                       "迟到dismantle仍须按expected host保护新host")
    }

    func testPresentationReservationChargesProductionObjectsAndSingleActiveStreamGeneration() async throws {
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let mount = PlaybackPresentationHostMount()
        let host = PlaybackPresentationHostController()

        let stream = try relay.presentations()
        let generation = try XCTUnwrap(relay.activeSubscriptionGeneration)
        let iterator = stream.makeAsyncIterator()
        let reservation = PlaybackRuntimeAllocationReservations.presentation

        withExtendedLifetime((stream, iterator)) {
            XCTAssertEqual(
                reservation.relayObject,
                productionObjectAllocation(relay),
                "relay对象必须按本目标真实allocation class收费"
            )
            XCTAssertEqual(reservation.relayLock, 0, "Mutex内联在relay对象中，不得重复收费")
            XCTAssertGreaterThanOrEqual(reservation.mountObject, productionObjectAllocation(mount))
            XCTAssertGreaterThanOrEqual(
                reservation.hostOwnershipState,
                PlaybackPresentationHostController.fixedOwnershipStateBytes
            )
            withExtendedLifetime(host) {}
            XCTAssertGreaterThan(reservation.asyncStreamOpaqueStorage, 0)
            XCTAssertGreaterThan(reservation.newestBufferBacking, 0)
            XCTAssertGreaterThanOrEqual(reservation.terminationClosureContext, 80)
            XCTAssertGreaterThan(reservation.relayWeakSideTable, 0)
            XCTAssertGreaterThan(reservation.consumerTaskSlab, 0)
            XCTAssertGreaterThan(reservation.consumerCaptureCompletionAndPendingIntent, 0)
            XCTAssertGreaterThan(reservation.consumerInFlightEnvelope, 0)
            XCTAssertEqual(reservation.coordinatorObject, 0,
                           "coordinator直接复用mount，不得重复计费")

            let namedCharges = Mirror(reflecting: reservation).children.compactMap {
                $0.value as? Int
            }.reduce(0, +)
            XCTAssertEqual(
                reservation.total,
                namedCharges,
                "relay、lock、单stream、单consumer、host ownership与in-flight envelope必须唯一收费"
            )
        }

        relay.terminateSubscription(generation)
    }

    func testPresentationCapacityBoundariesOverflowAndGlobalLedgerIncludePresentationExactlyOnce() {
        XCTAssertEqual(
            PlaybackPresentationAllocationCapacity.evaluate(baseBytes: 0, additionalBytes: 2_047),
            .admitted(totalBytes: 2_047)
        )
        XCTAssertEqual(
            PlaybackPresentationAllocationCapacity.evaluate(baseBytes: 0, additionalBytes: 2_048),
            .admitted(totalBytes: 2_048)
        )
        XCTAssertEqual(
            PlaybackPresentationAllocationCapacity.evaluate(baseBytes: 0, additionalBytes: 2_049),
            .capacityExceeded
        )
        XCTAssertEqual(
            PlaybackPresentationAllocationCapacity.evaluate(baseBytes: Int.max, additionalBytes: 1),
            .integerOverflow
        )

        let legacyLedgers = PlaybackRuntimeAllocationReservations.ownedControl.total
            + PlaybackRuntimeAllocationReservations.audioRelay.total
            + PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total
            + PlaybackRuntimeAllocationReservations.route.total
        let presentation = PlaybackRuntimeAllocationReservations.presentation.total
        XCTAssertEqual(
            PlaybackRuntimeAllocationReservations.globalReachablePeak,
            legacyLedgers + presentation,
            "globalReachablePeak必须恰好包含一次presentation ledger"
        )
        XCTAssertLessThanOrEqual(presentation, 2 * 1_024)
        XCTAssertLessThanOrEqual(
            PlaybackRuntimeAllocationReservations.globalReachablePeak,
            PlaybackRuntimeAllocationReservations.globalHardCap
        )
    }

    func testTwoKiBLedgerNamesConservativeSlabsAtRealViewModelG1ToG2Peak() async throws {
        let allocator = PlaybackIdentityAllocator()
        let relay = PlaybackPresentationRelay(allocator: allocator)
        let first = IdentifiedPlaybackPresentation(
            identity: presentationIdentity(nonce: 21),
            presentation: .sampleBuffer(PlaybackPresentationContext())
        )
        let second = identifiedAVPlayer(nonce: 22)
        try relay.replace(with: first)
        let engine = Task10CapacityPlaybackEngine(relay: relay, successor: second)
        let mount = PlaybackPresentationHostMount()
        let host = PlaybackPresentationHostController()
        host.loadViewIfNeeded()
        mount.connect(to: host)
        let coordinator = PlaybackPresentationHostView(mount: mount).makeCoordinator()
        let model = FullScreenPlayerViewModel(
            request: PlaybackRequest(
                sourceProfileID: UUID(),
                channelID: "task10-capacity",
                streamURL: URL(string: "http://localhost/task10-capacity.ts")!,
                title: "Task 10 Capacity"
            ),
            engine: engine,
            presentationStreamProvider: { try await engine.presentations() },
            presentationMount: mount,
            settings: capacitySettings()
        )

        model.start()
        try await capacityEventually("G1未通过真实VM挂到生产host") {
            host.mountedIdentity == first.identity
        }
        let firstOwner = try XCTUnwrap(model.presentationMountOwnership)
        await engine.emit(.failed(PlaybackFailure(
            code: "task10.retry",
            userMessage: "重试",
            retryDisposition: .retrySameRequest
        )))
        try await capacityEventually("VM未进入可重试失败态") {
            if case .failed = model.state { return true }
            return false
        }
        model.retry()
        try await capacityEventually("G2未在真实VM/host完成接管") {
            host.mountedIdentity == second.identity &&
                model.presentationMountOwnership?.subscriptionGeneration !=
                    firstOwner.subscriptionGeneration
        }
        let retiredBeforePublish = await engine.predecessorSubscriptionRetiredBeforeSuccessorPublish
        let retiredBeforeSubscribe = await engine.predecessorSubscriptionRetiredBeforeSuccessorSubscription
        XCTAssertTrue(retiredBeforePublish, "G1 active subscription必须先退休，才允许发布G2目标")
        XCTAssertTrue(retiredBeforeSubscribe, "G1 continuation/buffer authority必须先退出，才允许取得G2 stream")

        let reservation = PlaybackRuntimeAllocationReservations.presentation
        let charges = Dictionary(uniqueKeysWithValues: Mirror(reflecting: reservation).children.compactMap {
            child -> (String, Int)? in
            guard let label = child.label, let value = child.value as? Int else { return nil }
            return (label, value)
        })
        print("TASK22_PRESENTATION_RESERVATION total=\(reservation.total) charges=\(charges.sorted { $0.key < $1.key })")
        func requireCharge(_ name: String, atLeast lowerBound: Int) {
            guard let value = charges[name] else {
                XCTFail("2KiB账本缺少具名slab：\(name)")
                return
            }
            XCTAssertGreaterThanOrEqual(value, lowerBound, "\(name)低于保守可达下界")
        }

        let consumerTask = try XCTUnwrap(model.presentationConsumerTaskForTesting)
        requireCharge("relayObject", atLeast: productionObjectAllocation(relay))
        XCTAssertEqual(charges["relayLock"], 0, "Mutex内联在relay对象中，不得重复收费")
        requireCharge(
            "asyncStreamOpaqueStorage",
            atLeast: malloc_good_size(
                MemoryLayout<AsyncStream<PlaybackPresentationReplacement>>.stride +
                    MemoryLayout<AsyncStream<PlaybackPresentationReplacement>.Continuation>.stride
            )
        )
        requireCharge(
            "newestBufferBacking",
            atLeast: malloc_good_size(32 + MemoryLayout<PlaybackPresentationReplacement>.stride)
        )
        requireCharge("relayWeakSideTable", atLeast: malloc_good_size(4 * MemoryLayout<UInt>.stride))
        requireCharge(
            "terminationClosureContext",
            atLeast: 80
        )
        requireCharge(
            "consumerTaskSlab",
            atLeast: heapAllocationReferencedByValue(consumerTask)
        )
        requireCharge(
            "consumerCaptureCompletionAndPendingIntent",
            atLeast: 80
        )
        requireCharge(
            "consumerOwnerObject",
            atLeast: FullScreenPlayerViewModel.presentationConsumerOwnerObjectAllocationForTesting
        )
        requireCharge("consumerOwnerWeakSideTable", atLeast: 32)
        requireCharge("mountObject", atLeast: productionObjectAllocation(mount))
        requireCharge(
            "hostOwnershipState",
            atLeast: PlaybackPresentationHostController.fixedOwnershipStateBytes
        )
        requireCharge("hostWeakSideTable", atLeast: malloc_good_size(4 * MemoryLayout<UInt>.stride))
        XCTAssertEqual(charges["coordinatorObject"], 0,
                       "coordinator直接复用mount，不得保留包装对象费用")
        requireCharge(
            "consumerInFlightEnvelope",
            atLeast: MemoryLayout<PlaybackPresentationReplacement>.stride
        )
        XCTAssertEqual(
            reservation.total,
            charges.values.reduce(0, +),
            "每个具名slab必须在presentation总账恰好计费一次"
        )
        XCTAssertLessThanOrEqual(reservation.total, 2 * 1_024, "2KiB固定上限不得抬高")

        let separatelyAuditedCharges = [
            "relayWeakSideTable",
            "terminationClosureContext",
            "consumerOwnerObject",
            "consumerOwnerWeakSideTable",
            "mountObject",
            "hostOwnershipState",
            "hostWeakSideTable",
        ]
        let missingAuditableCharges = separatelyAuditedCharges.filter { charges[$0] == nil }
        XCTAssertTrue(
            missingAuditableCharges.isEmpty,
            "opaque/weak对象必须单独具名并能映射真实allocator证据，缺少：\(missingAuditableCharges)"
        )

        // AVPlayer/controller/context由UI或backend bundle持有，不在2KiB控制层重复收费。
        withExtendedLifetime((relay, host, coordinator)) {}
        await model.stop()
    }

    private func identifiedAVPlayer(nonce: UInt64) -> IdentifiedPlaybackPresentation {
        IdentifiedPlaybackPresentation(
            identity: presentationIdentity(nonce: nonce),
            presentation: .avPlayer(AVPlayerPresentationContext(player: AVPlayer()))
        )
    }

    private func presentationIdentity(nonce: UInt64) -> PresentationIdentity {
        let session = PlaybackSessionIdentity(
            sessionID: 1,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: nonce
        )
        return PresentationIdentity(
            sessionIdentity: session,
            backendIdentity: backend,
            outputLifecycleEpoch: OutputLifecycleEpoch(
                backendIdentity: backend,
                outputNonce: nonce
            ),
            itemGeneration: OutputItemGeneration(rawValue: nonce),
            presentationNonce: nonce
        )
    }

    private func avPlayerContext(
        in presentation: IdentifiedPlaybackPresentation
    ) -> AVPlayerPresentationContext? {
        guard case let .avPlayer(context) = presentation.presentation else { return nil }
        return context
    }

    private func objectField<T: AnyObject>(
        _ name: String,
        of object: Any,
        as _: T.Type
    ) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
    }

    private func productionObjectAllocation(_ object: AnyObject) -> Int {
        let instanceSize = class_getInstanceSize(type(of: object))
        let expectedClass = malloc_good_size(instanceSize)
        let actual = malloc_size(Unmanaged.passUnretained(object).toOpaque())
        XCTAssertEqual(actual, expectedClass, "生产对象必须使用当前目标allocator rounding")
        return actual
    }

    private func heapAllocationReferencedByValue<T>(_ value: T) -> Int {
        withUnsafeBytes(of: value) { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<UInt>.stride).reduce(0) {
                largest, offset in
                guard offset + MemoryLayout<UInt>.stride <= bytes.count else { return largest }
                let address = bytes.loadUnaligned(fromByteOffset: offset, as: UInt.self)
                guard let pointer = UnsafeRawPointer(bitPattern: address),
                      malloc_zone_from_ptr(pointer) != nil else { return largest }
                return max(largest, malloc_size(pointer))
            }
        }
    }

    private func capacitySettings() -> PlaybackSettingsStore {
        let suite = "Task10PresentationHostCapacityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return PlaybackSettingsStore(defaults: defaults)
    }

    private func capacityEventually(
        _ message: @autoclosure () -> String,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message())
    }
}

private actor Task10CapacityPlaybackEngine: PlaybackEngine, PlaybackPresentationControlling {
    private var continuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var mountNonce: UInt64 = 0
    private let relay: PlaybackPresentationRelay
    private let successor: IdentifiedPlaybackPresentation
    private var playCount = 0
    private(set) var predecessorSubscriptionRetiredBeforeSuccessorPublish = false
    private(set) var predecessorSubscriptionRetiredBeforeSuccessorSubscription = false

    init(relay: PlaybackPresentationRelay, successor: IdentifiedPlaybackPresentation) {
        self.relay = relay
        self.successor = successor
    }

    func events() -> AsyncStream<PlaybackState> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PlaybackState.self)
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return pair.stream
    }

    func play(_: PlaybackRequest) async {
        playCount += 1
        guard playCount == 2 else { return }
        relay.finish()
        predecessorSubscriptionRetiredBeforeSuccessorPublish =
            relay.activeSubscriptionGeneration == nil
        try? relay.replace(with: successor)
    }
    func setPaused(_: Bool) async {}
    func stop() async {}
    func setTuning(_: PlaybackTuning) async {}

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        if playCount >= 2 {
            predecessorSubscriptionRetiredBeforeSuccessorSubscription =
                relay.activeSubscriptionGeneration == nil
        }
        return try relay.presentations()
    }

    func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        mountNonce += 1
        return .claimed(.init(
            subscriptionGeneration: replacement.subscriptionGeneration,
            presentationIdentity: replacement.desired?.identity,
            mountNonce: mountNonce
        ))
    }

    func failPresentationControl() {}

    func emit(_ state: PlaybackState) {
        for continuation in continuations.values { continuation.yield(state) }
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }
}
