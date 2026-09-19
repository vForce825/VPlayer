// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import AVFoundation
import CommonCrypto
import Darwin
import Foundation
import ObjectiveC
import Security
import XCTest
@testable import VPlayerPlayback

final class AudioSessionLifecycleTests: XCTestCase {
    func testFrozenPayloadUsesSmallerRealCommandBackingWithoutBorrowingErrorReserve() throws {
        let registry = ControlTaskRegistry()
        var observation: Result<(UInt, UInt, Int), Error>?
        registry.executor.sync {
            observation = Result {
                let authority = try XCTUnwrap(Mirror(reflecting: registry).children.first { $0.label == "authority" }?.value)
                let commands = try XCTUnwrap(Mirror(reflecting: authority).children.first { $0.label == "commands" }?.value
                    as? [OwnedPostIngressControlCommand?])
                XCTAssertEqual(commands.count, 32)
                XCTAssertEqual(MemoryLayout.size(ofValue: commands), MemoryLayout<UInt>.size)
                // 当前原生 Array 单字 storage 引用；直接读原对象基址，不由 element 地址减 header 猜测。
                return withUnsafeBytes(of: commands) { representation in
                    let base = representation.load(as: UInt.self)
                    let bytes = malloc_size(UnsafeRawPointer(bitPattern: base))
                    return commands.withUnsafeBufferPointer { buffer in
                        let elements = UInt(bitPattern: buffer.baseAddress)
                        XCTAssertGreaterThan(elements, base)
                        XCTAssertLessThanOrEqual(elements + UInt(buffer.count * MemoryLayout<OwnedPostIngressControlCommand?>.stride),
                            base + UInt(bytes), "原 element 区间必须落在同一实测 malloc allocation 内")
                        return (base, elements, bytes)
                    }
                }
            }
        }
        let (base, elements, bytes) = try XCTUnwrap(observation).get()
        let allocation = ControlTaskRegistry.ownedControlAllocationReservation
        XCTAssertEqual(bytes, allocation.commandBacking)
        XCTAssertLessThan(bytes, 19_968, "必须在已完成 payload 基线上再次真实下降 allocator 档位")
        XCTAssertEqual(allocation.fixedErrorReservation, 5_440)
        XCTAssertEqual(ControlTaskRegistry.commandBackingCapacity, 32)
        let text = """
        commandStride=\(MemoryLayout<OwnedPostIngressControlCommand?>.stride)
        commandOriginalAllocationBase=\(base)
        commandOriginalElementBase=\(elements)
        commandActualBacking=\(bytes)
        payloadStride=\(MemoryLayout<OwnedControlCommandPayload>.stride)
        resourceStride=\(MemoryLayout<FrozenCommandOwnedResource>.stride)
        audioStride=\(MemoryLayout<(FrozenCommandAudioPhase, FrozenCommandAudioPolicy, OwnedAudioSessionActivationResult?)>.stride)
        audioPolicyStride=\(MemoryLayout<FrozenCommandAudioPolicy>.stride)
        activationPurposeStride=\(MemoryLayout<FrozenCommandActivationPurpose>.stride)
        deactivationStride=\(MemoryLayout<(FrozenCommandDeactivation, AudioSessionDeactivationResult?)>.stride)
        callStride=\(MemoryLayout<FrozenCommandAudioCall>.stride)
        dispositionStride=\(MemoryLayout<FrozenCommandDeactivationDisposition>.stride)
        inactiveProofStride=\(MemoryLayout<FrozenCommandInactiveProof>.stride)
        interruptionProofStride=\(MemoryLayout<FrozenCommandInterruptionProof>.stride)
        acquisitionProofStride=\(MemoryLayout<FrozenCommandAcquisitionProof>.stride)
        backendLeaseStride=\(MemoryLayout<FrozenCommandBackendLease>.stride)
        ownedExistingAllocationTotal=\(allocation.total)
        fixedErrorReservation=\(allocation.fixedErrorReservation)
        """
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(text)
    }

    func testControlAllocationReservationAccountsForBackingsCapturesAndFixedScratch() {
        let allocation = ControlTaskRegistry.controlAllocationReservation
        XCTAssertEqual(allocation.commandBacking, malloc_good_size(32 + 32 * MemoryLayout<OwnedPostIngressControlCommand?>.stride))
        XCTAssertEqual(allocation.groupBacking, malloc_good_size(32 + ControlTaskRegistry.groupValueBytes))
        XCTAssertEqual(allocation.fixedScratch, malloc_good_size(1024) + malloc_good_size(256))
        XCTAssertEqual(allocation.inFlightDeliveries, 2 * (malloc_good_size(class_getInstanceSize(AudioSessionCallDelivery.self)) + 32 + 48))
        XCTAssertEqual(allocation.externalSyncReservation, 34 * (32 + 48))
        XCTAssertEqual(allocation.weakSideTables, 5 * 32)
        XCTAssertGreaterThan(allocation.fixedObjects, 0)
        XCTAssertGreaterThan(allocation.transientArrays, 0)
        XCTAssertGreaterThan(allocation.fixedErrorReservation, 0)
        XCTAssertLessThanOrEqual(allocation.total, 65_536)
        let attachment = XCTAttachment(string: "\(allocation)")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRealOwnerAndIndexedControlMutationsKeepTheOriginalNativeBackings() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
        // 仅短借用底层地址作相等观察；返回只含整数，完整Mirror/Array临时先销毁再执行生产mutation。
        func backingIdentities() throws -> [UInt] {
            var result: Result<[UInt], Error>?
            harness.registry.executor.sync {
                result = Result {
                    let authority = try XCTUnwrap(Mirror(reflecting: harness.registry).children.first { $0.label == "authority" }?.value)
                    func identity(_ name: String, _ object: Any) throws -> UInt {
                        let array = try XCTUnwrap(Mirror(reflecting: object).children.first { $0.label == name }?.value
                            as? any NativeArrayAllocationObservation)
                        return array.observedStorageIdentity
                    }
                    return try [identity("commands", authority), identity("groups", authority), identity("issued", harness.allocator)]
                }
            }
            return try XCTUnwrap(result).get()
        }
        let original = try backingIdentities()
        let handoff = try await harness.acquire()
        XCTAssertEqual(try backingIdentities(), original)
        let sampler = try XCTUnwrap(handoff.sampler)
        XCTAssertEqual(harness.owner.sample(sampler, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if harness.receiver.history.contains(where: { $0.0.record == sampler }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(harness.receiver.history.contains(where: { $0.0.record == sampler }))
        XCTAssertEqual(try backingIdentities(), original)
        _ = harness.registry.occupancy
        try await harness.release(handoff)
        XCTAssertEqual(try backingIdentities(), original, "真实acquire/configure/sample/cleanup后不保留第二个COW backing")
    }
    @MainActor
    func testRealOwnerPreservesFixedFailureDomainAndClampedCodeWithoutRetainingRawDomain() async throws {
        let cases: [(String, Int, AudioSessionFixedFailure)] = [
            (NSOSStatusErrorDomain, Int(Int32.min), .init(domain: .osStatus, code: .min)),
            (NSOSStatusErrorDomain, Int(Int32.max), .init(domain: .osStatus, code: .max)),
            (NSOSStatusErrorDomain, Int.min, .init(domain: .osStatus, code: .min)),
            (NSOSStatusErrorDomain, Int.max, .init(domain: .osStatus, code: .max)),
            (String(repeating: "陌", count: 16_384), -42, .init(domain: .unknown, code: -42)),
            (NSOSStatusErrorDomain + "x", 17, .init(domain: .unknown, code: 17))
        ]
        for (domain, code, expected) in cases {
            let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success],
                categoryFailure: NSError(domain: domain, code: code))
            let handoff = try await harness.acquire()
            XCTAssertEqual(harness.registry.processAudioSessionReceiptSnapshot()?.preferredFailureReason, expected)
            XCTAssertEqual(harness.sdk.events, [.category(.longFormAudio), .category(.default), .multichannel, .activate])
            XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
            try await harness.release(handoff)
        }
    }

    @MainActor
    func testSDKConfigurationReentryRevalidatesInactiveStepsAndWaitsForNewActivationAfterBegan() async throws {
        let stages: [(AudioSessionSDKSpy.Event, [AudioSessionSDKSpy.Result], [AudioSessionSDKSpy.Event])] = [
            (.category(.longFormAudio), [.failure], [.category(.longFormAudio)]),
            (.category(.default), [.failure, .success], [.category(.longFormAudio), .category(.default)]),
            (.multichannel, [.success], [.category(.longFormAudio), .multichannel])
        ]
        for (stage, outcomes, expectedEvents) in stages {
            for action in AudioSessionSDKSpy.ReentrantAction.allCases {
                let harness = try AudioSessionLifecycleTestHarness(categoryResults: outcomes, blockedEvent: stage)
                let acquisition = try harness.prepareAcquisition()
                let originalContext = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
                harness.sdk.armReentrancy(stage: stage, action: action, registry: harness.registry,
                    contextNonce: originalContext.contextNonce, instant: harness.clock.nowNanoseconds)
                let before = harness.registry.executor.safetyIngress.snapshot
                XCTAssertTrue(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
                let sdk = harness.sdk
                let entered = await Task.detached { sdk.waitForBlockedCall() }.value
                XCTAssertTrue(entered, "回调必须在对应SDK调用内同步完成，然后才阻塞其返回")
                defer { sdk.releaseBlockedCall() }
                XCTAssertTrue(sdk.reentrantCallCompleted)
                XCTAssertFalse(sdk.usedMainThread)
                XCTAssertFalse(sdk.usedControlExecutor)
                XCTAssertEqual(sdk.events, expectedEvents)
                let heartbeat = await Task { @MainActor in 42 }.value
                XCTAssertEqual(heartbeat, 42)
                if action == .stop {
                    XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.owner?.reason, .stop)
                    XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.disposition, .releaseAfterTeardown)
                } else {
                    let after = harness.registry.executor.safetyIngress.snapshot
                    XCTAssertGreaterThan(after.throughRevision, before.throughRevision)
                    if action == .began { XCTAssertTrue(after.interruptionVeto) }
                    else { XCTAssertGreaterThan(after.mediaServicesEpoch, before.mediaServicesEpoch) }
                }
                XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
                XCTAssertNil(harness.registry.outputAcquisitionCommitSnapshot())
                XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
                XCTAssertEqual(sdk.randomInvocationCount, 1)
                sdk.releaseBlockedCall()
                let expectedAfterReturn: [AudioSessionSDKSpy.Event]
                if action == .began {
                    expectedAfterReturn = stage == .multichannel ? [.category(.longFormAudio), .multichannel] :
                        [.category(.longFormAudio), .category(.default), .multichannel]
                } else { expectedAfterReturn = expectedEvents }
                for _ in 0..<500 {
                    if harness.receiver.deliveryCount == expectedAfterReturn.count { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let history = harness.receiver.history
                XCTAssertEqual(history.count, expectedAfterReturn.count)
                guard history.count >= expectedEvents.count else { return XCTFail("原在途步骤没有准确completion") }
                let originalReturned = history[expectedEvents.count - 1]
                XCTAssertEqual(originalReturned.0.record.group, originalContext.reservation.workGroup)
                if action != .began {
                    XCTAssertNil(originalReturned.1.followUp, "reset/stop后的迟到配置结果不能安装普通后继")
                }
                XCTAssertEqual(harness.receiver.deliveryCount, expectedAfterReturn.count)
                XCTAssertEqual(sdk.events, expectedAfterReturn)
                XCTAssertEqual(sdk.maximumConcurrentCalls, 1)
                XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
                XCTAssertNil(harness.registry.outputAcquisitionCommitSnapshot())
                XCTAssertEqual(harness.owner.invoke(originalReturned.0.record, receiver: harness.receiver), .rejected,
                    "准确原SDK结果已结清，不能重放此票或补current步骤")
                if action == .began {
                    XCTAssertNil(harness.receiver.last?.1.followUp, "inactive可继续，但veto清除前不安装activation")
                    XCTAssertNil(harness.registry.registeredOutputDrainProof(), "未交接acquisition不能制造普通interruption proof")
                    harness.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
                    let activation = try XCTUnwrap(harness.registry.beginOutputAcquisitionActivation(
                        contextNonce: originalContext.contextNonce))
                    XCTAssertFalse(history.contains(where: { $0.0.record == activation }))
                    XCTAssertEqual(harness.owner.invoke(activation, receiver: harness.receiver), .started)
                    for _ in 0..<500 {
                        if harness.registry.outputAcquisitionCommitSnapshot() != nil { break }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    XCTAssertNotNil(harness.registry.outputAcquisitionCommitSnapshot())
                    XCTAssertEqual(sdk.events, expectedAfterReturn + [.activate])
                    XCTAssertEqual(sdk.maximumConcurrentCalls, 1)
                }
            }
        }
    }

    @MainActor
    func testCanceledOriginalAcquisitionNeverRegistersOrCallsSDK() throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let acquisition = try harness.prepareAcquisition()
        XCTAssertTrue(harness.registry.requestCancel(acquisition))
        XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        XCTAssertEqual(harness.registry.phase(of: acquisition), .terminal(.canceled))
        XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.acquisitionNoLeaseReceipt?.acquisitionTicket, acquisition)
        XCTAssertEqual(harness.sdk.randomInvocationCount, 0)
        XCTAssertTrue(harness.sdk.events.isEmpty)
        XCTAssertNil(harness.registry.ownedResourceSnapshot())
    }

    func testRawProjectionAllocationClassesAreMeasuredOnTheSameTarget() {
        func allocatedBytes(_ requested: Int) -> Int {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: requested,
                alignment: MemoryLayout<SessionEndpointFingerprint>.alignment)
            defer { storage.deallocate() }
            return malloc_size(storage)
        }
        let attachment = XCTAttachment(string: """
        raw1024Good=\(malloc_good_size(1024)) actual=\(allocatedBytes(1024))
        raw256Good=\(malloc_good_size(256)) actual=\(allocatedBytes(256))
        raw1280Good=\(malloc_good_size(1280)) actual=\(allocatedBytes(1280))
        salt=\(MemoryLayout<AudioSessionEndpointSalt>.stride)
        dataSource=\(MemoryLayout<AudioSessionDataSourceEvidence>.stride)
        hashArguments=\(MemoryLayout<(NSString, UInt8, Int, UnsafeMutablePointer<CC_SHA256_CTX>, UnsafeMutableBufferPointer<UInt8>)>.stride)
        shaUpdateArguments=\(MemoryLayout<(UnsafeMutablePointer<CC_SHA256_CTX>?, UnsafeRawPointer?, CC_LONG)>.stride)
        shaFinalArguments=\(MemoryLayout<(UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<CC_SHA256_CTX>?)>.stride)
        cfNumberArguments=\(MemoryLayout<(CFNumber, CFNumberType, UnsafeMutableRawPointer)>.stride)
        selector=\(MemoryLayout<Selector>.stride)
        byteIterator=\(MemoryLayout<UnsafeRawBufferPointer.Iterator>.stride)
        closure=\(MemoryLayout<() -> Void>.stride)
        """)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(malloc_good_size(1280), 1280)
    }

    @MainActor
    func testActualControlObjectsAndNativeArrayCapacityAreMeasuredBeforeAllocationModel() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let registration = try XCTUnwrap(harness.owner.registration(for: handoff.committed.relayIdentity.acquisitionTicket))
        let scheduler = PlaybackDeadlineScheduler(registry: harness.registry)
        func objectField(_ name: String, of object: AnyObject) throws -> AnyObject {
            let field = try XCTUnwrap(Mirror(reflecting: object).children.first { $0.label == name })
            XCTAssertEqual(Mirror(reflecting: field.value).displayStyle, .class)
            return field.value as AnyObject
        }
        let authority = try objectField("authority", of: harness.registry)
        let lane = try objectField("lane", of: harness.owner)
        let systemSDK = SystemPlaybackAudioSessionSDK(session: AVAudioSession.sharedInstance())
        let clock = DispatchPlaybackMonotonicClock()
        let timer = clock.makeDeadlineTimer(deliveryQueue: DispatchQueue(label: "org.vplayer.test.allocation-probe"))
        timer.activate()
        defer { timer.cancel() }
        let objects: [(String, AnyObject)] = [
            ("registry", harness.registry), ("authority", authority), ("executor", harness.registry.executor),
            ("cell", harness.registry.executor.safetyIngress), ("allocator", harness.allocator),
            ("owner", harness.owner), ("lane", lane), ("systemSDK", systemSDK),
            ("scheduler", scheduler), ("clock", clock), ("timerWrapper", timer),
            ("cellLock", try objectField("lock", of: harness.registry.executor.safetyIngress)),
            ("schedulerLock", try objectField("lock", of: scheduler)),
            ("allocatorLock", try objectField("lock", of: harness.allocator)),
            ("registration", registration),
            ("routeWrapper", SystemAudioSessionRouteSnapshot(route: ObjectiveCRouteDouble(outputs: NSArray()))),
            ("executorQueue", try objectField("queue", of: harness.registry.executor)),
            ("executorSource", try objectField("source", of: harness.registry.executor)),
            ("executorKey", try objectField("key", of: harness.registry.executor)),
            ("laneQueue", try objectField("queue", of: lane)),
            ("timerSource", try objectField("source", of: timer))
        ]
        var rows: [String] = []
        for (name, object) in objects {
            let instance = class_getInstanceSize(type(of: object))
            // 只传真实对象base；从不对Array元素地址malloc_size或猜减header。
            let allocation = malloc_size(Unmanaged.passUnretained(object).toOpaque())
            XCTAssertGreaterThanOrEqual(allocation, instance, name)
            rows.append("\(name): instance=\(instance) allocation=\(allocation)")
        }
        let commands = try XCTUnwrap(Mirror(reflecting: authority).children.first { $0.label == "commands" }?.value
            as? [OwnedPostIngressControlCommand?])
        rows.append("commands: count=\(commands.count) capacity=\(commands.capacity) stride=\(MemoryLayout<OwnedPostIngressControlCommand?>.stride)")
        let groups = try XCTUnwrap(Mirror(reflecting: authority).children.first { $0.label == "groups" }?.value
            as? any NativeArrayAllocationObservation)
        rows.append("groups: count=\(groups.observedCount) capacity=\(groups.observedCapacity) stride=\(groups.observedElementStride)")
        let counters = try XCTUnwrap(Mirror(reflecting: harness.allocator).children.first { $0.label == "issued" }?.value as? [UInt64])
        rows.append("counters: count=\(counters.count) capacity=\(counters.capacity) stride=\(MemoryLayout<UInt64>.stride)")
        let occupancyScratch = (16..<32).filter { _ in true }
        rows.append("occupancyScratch: count=\(occupancyScratch.count) capacity=\(occupancyScratch.capacity)")
        let stages = ReservedCleanupStage.allCases
        let namespaces = PlaybackIdentityNamespace.allCases
        rows.append("stages: capacity=\(stages.capacity) stride=\(MemoryLayout<ReservedCleanupStage>.stride)")
        rows.append("namespaces: capacity=\(namespaces.capacity) stride=\(MemoryLayout<PlaybackIdentityNamespace>.stride)")
        for requested in [32, 40, 48, 64, 192, 208, 224, 240, 5920, 27680] {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: requested, alignment: 8)
            rows.append("allocationClass \(requested): good=\(malloc_good_size(requested)) actual=\(malloc_size(storage))")
            storage.deallocate()
        }
        // 与同tvOS runtime的weak side-table相同公开typed-malloc入口，不读取私有弱表地址。
        let weakAllocation = try XCTUnwrap(malloc_type_malloc(32, 0xff87031d))
        rows.append("weakTypedMalloc32: actual=\(malloc_size(weakAllocation))")
        XCTAssertEqual(malloc_size(weakAllocation), 32)
        free(weakAllocation)
        let errors: [any Error] = [ControlTaskRegistry.Failure.capacity,
            PlaybackIdentityAllocationError.identitySpaceExhausted, PlaybackSafetyFailure.invalidEvidence]
        for error in errors {
            let wrapped = error as NSError
            rows.append("fixedError: instance=\(class_getInstanceSize(type(of: wrapped))) allocation=\(malloc_size(Unmanaged.passUnretained(wrapped).toOpaque()))")
            XCTAssertLessThanOrEqual(malloc_size(Unmanaged.passUnretained(wrapped).toOpaque()), 80)
        }
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
        try await harness.release(handoff)
    }

    func testFingerprintOrderingMatchesIndependentByteLexicographicOracleAtEveryPosition() {
        func fingerprint(_ bytes: [UInt8]) -> SessionEndpointFingerprint {
            var value = SessionEndpointFingerprint()
            withUnsafeMutableBytes(of: &value) { target in
                target.copyBytes(from: bytes)
            }
            return value
        }
        // 捕获字段次序、端序及有符号比较错误；期望仅来自测试侧原32字节序列。
        let boundaries: [(UInt8, UInt8)] = [(0, 0x7f), (0x7f, 0x80), (0x80, 0xff), (0xff, 0xff)]
        for position in 0..<32 {
            for (lower, upper) in boundaries {
                var lhs = [UInt8](repeating: 0x80, count: 32)
                var rhs = lhs
                lhs[position] = lower
                rhs[position] = upper
                XCTAssertEqual(fingerprint(lhs).precedes(fingerprint(rhs)), lhs.lexicographicallyPrecedes(rhs),
                    "字节位置\(position)，边界\(lower)/\(upper)")
                XCTAssertEqual(fingerprint(rhs).precedes(fingerprint(lhs)), rhs.lexicographicallyPrecedes(lhs))
                XCTAssertFalse(fingerprint(lhs).precedes(fingerprint(lhs)))
                if position < 31 && lower < upper {
                    lhs[position + 1] = 0xff
                    rhs[position + 1] = 0
                    XCTAssertTrue(fingerprint(lhs).precedes(fingerprint(rhs)), "首异字节必须优先于后续字节")
                }
            }
        }
    }

    @MainActor
    func testCompletionReceiverCanReenterWithOnlyItsExactQueuedReplacement() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let first = try XCTUnwrap(handoff.sampler)
        let receiver = AudioSessionCompletionObservation(registry: harness.registry, reenterOwner: harness.owner)
        XCTAssertEqual(harness.owner.sample(first, receiver: receiver), .started)
        for _ in 0..<500 {
            if receiver.deliveryCount == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(receiver.deliveryCount, 2)
        XCTAssertEqual(receiver.reentryResult, .started)
        let second = try XCTUnwrap(receiver.reentryTicket)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(receiver.last?.0.record, second)
        XCTAssertEqual(harness.sdk.events.filter { $0 == .route }.count, 2)
        XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
        XCTAssertNil(harness.registry.phase(of: first))
        XCTAssertNil(harness.registry.phase(of: second))
        XCTAssertEqual(harness.registry.phase(of: try XCTUnwrap(receiver.last?.1.followUp)), .queued)
        XCTAssertEqual(harness.owner.sample(first, receiver: receiver), .rejected)
    }

    @MainActor
    func testClosedReceiverStaysOwnedUntilLateRouteSettlesThenReleasesWithoutBlockingCleanup() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], blockedEvent: .route)
        let handoff = try await harness.acquire()
        let source = try XCTUnwrap(handoff.sampler)
        var receiver: AudioSessionCompletionObservation? = .init(registry: harness.registry)
        weak var reference: AudioSessionCompletionObservation?
        reference = receiver
        XCTAssertEqual(harness.owner.sample(source, receiver: try XCTUnwrap(receiver)), .started)
        let sdk = harness.sdk
        let reached = await Task.detached { sdk.waitForBlockedCall() }.value
        XCTAssertTrue(reached)
        defer { sdk.releaseBlockedCall() }
        let coordinator = OutputCleanupCoordinator(registry: harness.registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: handoff.successorContextNonce, reason: .stop, at: 100))
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(harness.registry.claimStart(monitor))
        let handle = try XCTUnwrap(harness.owner.registration(for: handoff.committed.relayIdentity.acquisitionTicket))
        XCTAssertFalse(handle.stop(monitor), "monitor关闭必须join真实在途sampler")
        receiver?.close()
        receiver = nil
        XCTAssertNotNil(reference, "原request必须保留其唯一接收者直到已返回completion交付")
        sdk.releaseBlockedCall()
        for _ in 0..<500 {
            if reference == nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(reference)
        XCTAssertEqual(harness.registry.phase(of: source), .terminal(.canceled))
        XCTAssertTrue(handle.stop(monitor))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(harness.owner.invoke(deactivate, receiver: harness.receiver), .started,
            "接收者关闭不能阻止原permit归还和唯一deactivate清理")
    }

    @MainActor
    func testRealRouteDeliversOriginalPermitAndExactReplacementOutsideCellOnSharedExecutor() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let source = try XCTUnwrap(handoff.sampler)
        let receiver = AudioSessionCompletionObservation(registry: harness.registry)
        XCTAssertEqual(harness.owner.sample(source, receiver: receiver), .started)
        for _ in 0..<500 {
            if receiver.last != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let delivered = try XCTUnwrap(receiver.last, "准确route completion不能被Bool入口吞掉")
        XCTAssertEqual(delivered.0.record, source)
        XCTAssertEqual(delivered.0.operation, .currentRoute)
        XCTAssertEqual(delivered.1.disposition, .accepted)
        let next = try XCTUnwrap(delivered.1.followUp)
        XCTAssertNotEqual(next, source)
        XCTAssertNil(harness.registry.phase(of: source), "none的原责任已结清并退休")
        XCTAssertEqual(harness.registry.phase(of: next), .queued)
        XCTAssertTrue(receiver.deliveredOnExecutor)
        XCTAssertTrue(receiver.cellWasReadable, "接收者可同步读Cell，证明不是锁内回调")
        XCTAssertEqual(harness.owner.sample(source, receiver: receiver), .rejected)
        XCTAssertEqual(harness.sdk.events.filter { $0 == .route }.count, 1)
    }

    func testAudioAndSamplerCannotClaimOutsideCombinedLane() throws {
        let configuration = try ActualAudioConfigurationFixture()
        XCTAssertFalse(configuration.registry.claimStart(configuration.ticket))
        XCTAssertEqual(configuration.registry.phase(of: configuration.ticket), .queued)
        for kind in 0..<3 {
            let activation = try ActualAudioActivationFixture(kind: kind)
            XCTAssertFalse(activation.registry.claimStart(activation.ticket))
            XCTAssertEqual(activation.registry.phase(of: activation.ticket), .queued)
        }
        let acquisition = try AcquiringOutputFixture()
        _ = try acquisition.configureAndActivate()
        let registry = acquisition.registry
        guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(
            try XCTUnwrap(registry.outputAcquisitionCommitSnapshot())) else { return XCTFail("真实handoff缺失") }
        let source = try XCTUnwrap(handoff.sampler)
        XCTAssertFalse(registry.claimStart(source))
        XCTAssertEqual(registry.phase(of: source), .queued)
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: handoff.successorContextNonce, reason: .stop, at: 100))
        let monitor = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(registry.claimStart(monitor))
        let registration = try XCTUnwrap(registry.audioSessionRegistration(for: acquisition.acquisition))
        XCTAssertTrue(coordinator.completeMonitorStop(monitor, lifecycle: registration.identity.monitorLifecycle))
        let deactivate = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertFalse(registry.claimStart(deactivate))
        XCTAssertEqual(registry.phase(of: deactivate), .queued)
    }

    func testBorrowedRouteRetainsExactObjectsUntilProjectionAndAcceptsOnlyExactDataSourceIntegers() throws {
        let sdk = AudioSessionSDKSpy(categoryResults: [], multichannelFails: false,
            executor: ControlTaskRegistry().executor)
        let salt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        for (index, entry) in [(NSNumber(value: Int64.max), true), (NSNumber(value: Int64.min), true),
            (NSNumber(value: UInt64.max), false), (NSNumber(value: 1.5), false), (NSNumber(value: Double.nan), false),
            (NSNumber(value: Double.infinity), false), (NSNumber(value: -Double.infinity), false),
            (NSNumber(value: true), true), (NSNumber(value: false), true),
            (NSNumber(value: UInt64(Int64.max)), true), (NSNumber(value: UInt64(Int64.max) + 1), false)].enumerated() {
            let (number, valid) = entry
            weak var routeReference: ObjectiveCRouteDouble?
            weak var portReference: ObjectiveCPortDouble?
            try autoreleasepool {
                var snapshot: SystemAudioSessionRouteSnapshot?
                do {
                let port = ObjectiveCPortDouble(uid: "端点" as NSString, port: "port" as NSString,
                    source: ObjectiveCDataSourceDouble(number))
                let route = ObjectiveCRouteDouble(outputs: NSArray(object: port))
                portReference = port
                routeReference = route
                    snapshot = SystemAudioSessionRouteSnapshot(route: route)
                }
                XCTAssertNotNil(routeReference)
                XCTAssertNotNil(portReference)
                let evidence = AudioSessionBlockingCallLane.project(try XCTUnwrap(snapshot), salt: salt)
                if valid { guard case .available = evidence else { return XCTFail("精确Int64边界必须有效") } }
                else { XCTAssertEqual(evidence, .invalid, "dataSource边界用例\(index)") }
                snapshot = nil
            }
            XCTAssertNil(routeReference, "+0 ObjC借用可进入autorelease池，但池退出后投影不能强持或泄漏原route")
            XCTAssertNil(portReference)
        }
    }

    func testThirtyTwoEndpointsAreOrderIndependentKeepDuplicatesAndUseSessionSalt() throws {
        let sdk = AudioSessionSDKSpy(categoryResults: [], multichannelFails: false,
            executor: ControlTaskRegistry().executor)
        let salt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        let otherSalt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        let endpoints: [AudioSessionRouteEndpoint] = (0..<32).map {
            .init(uid: "有界端点-\($0)" as NSString, portType: AVAudioSession.Port.airPlay.rawValue as NSString, dataSource: .missing)
        }
        let value = AudioSessionBlockingCallLane.project(GraphRouteSnapshot(endpoints), salt: salt)
        guard case .available(let ports, _) = value else { return XCTFail("32端点边界必须有效") }
        XCTAssertEqual(ports, .airPlay)
        XCTAssertEqual(AudioSessionBlockingCallLane.project(GraphRouteSnapshot(Array(endpoints.reversed())), salt: salt), value)
        XCTAssertNotEqual(AudioSessionBlockingCallLane.project(GraphRouteSnapshot(endpoints), salt: otherSalt), value)
        XCTAssertNotEqual(AudioSessionBlockingCallLane.project(GraphRouteSnapshot([endpoints[0]]), salt: salt),
            AudioSessionBlockingCallLane.project(GraphRouteSnapshot([endpoints[0], endpoints[0]]), salt: salt), "不能把多成员当集合去重")
        XCTAssertEqual(AudioSessionBlockingCallLane.project(GraphRouteSnapshot(endpoints + [endpoints[0]]), salt: salt), .invalid)
        XCTAssertEqual(String(describing: salt), "<redacted>")
        XCTAssertTrue(Mirror(reflecting: salt).children.isEmpty)
    }

    @MainActor
    func testSamplerClaimClockOverflowImmediatelyFailsCellAndPreservesOriginalCleanup() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let sampler = try XCTUnwrap(handoff.sampler)
        let original = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let reservation = try XCTUnwrap(harness.registry.cleanupReservationSnapshot())
        let deactivation = graphOwnedDeactivation(harness.registry)
        let deliveries = harness.receiver.deliveryCount
        XCTAssertNil(original.budget)
        XCTAssertNil(original.suspend)
        XCTAssertEqual(harness.registry.phase(of: sampler), .queued)
        XCTAssertFalse(harness.sdk.events.contains(.route))
        harness.clock.set(UInt64.max)
        XCTAssertEqual(harness.owner.sample(sampler, receiver: harness.receiver), .rejected)
        // 首个观察必须直读Cell，不能先让Registry getter/barrier补做reconcile掩盖吞错。
        let immediate = harness.registry.executor.safetyIngress.snapshot
        XCTAssertEqual(immediate.failure, .clockOverflow)
        XCTAssertFalse(immediate.output.outputPermitPresent)
        XCTAssertFalse(immediate.output.readinessOpen)
        XCTAssertFalse(immediate.output.routeObservationGateOpen)
        XCTAssertFalse(harness.sdk.events.contains(.route))
        XCTAssertEqual(harness.receiver.deliveryCount, deliveries, "未调用SDK不得伪造completion")
        let authority = try XCTUnwrap(Mirror(reflecting: harness.registry).children.first { $0.label == "authority" }?.value)
        let permit = try XCTUnwrap(Mirror(reflecting: authority).children.first { $0.label == "audioSessionPermit" }?.value)
        XCTAssertTrue(Mirror(reflecting: permit).children.isEmpty, "checked失败不能留下在途permit")
        XCTAssertEqual(harness.registry.phase(of: sampler), .terminal(.canceled))
        let cleanup = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        XCTAssertEqual(cleanup.reservation, reservation.ticket)
        XCTAssertEqual(cleanup.committedRelay, original.committedRelay)
        XCTAssertTrue(cleanup.poisoned)
        XCTAssertEqual(cleanup.disposition, .releaseAfterTeardown)
        XCTAssertTrue(cleanup.relayClosing)
        XCTAssertTrue(harness.registry.cleanupReservationSnapshot()?.terminal == true)
        XCTAssertEqual(graphOwnedDeactivation(harness.registry), deactivation,
            "预算无法表示也不能丢掉真实active lease的原deactivate责任")
    }

    @MainActor
    func testSamplerClaimAtExactDeadlineClosesOutputWithoutInventingSDKCompletion() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let sampler = try XCTUnwrap(handoff.sampler)
        let deadline = try XCTUnwrap(handoff.routeDeadline)
        let deliveries = harness.receiver.deliveryCount
        XCTAssertEqual(harness.registry.phase(of: sampler), .queued)
        XCTAssertNil(harness.registry.outputResourceContextSnapshot()?.budget)
        harness.clock.set(deadline.deadlineInstant)
        XCTAssertEqual(harness.owner.sample(sampler, receiver: harness.receiver), .rejected)
        let immediate = harness.registry.executor.safetyIngress.snapshot
        XCTAssertNil(immediate.failure)
        XCTAssertFalse(immediate.output.outputPermitPresent)
        XCTAssertFalse(immediate.output.readinessOpen)
        XCTAssertFalse(immediate.output.routeObservationGateOpen)
        XCTAssertFalse(harness.sdk.events.contains(.route))
        XCTAssertEqual(harness.receiver.deliveryCount, deliveries, "未调用SDK不得伪造completion")
        XCTAssertEqual(harness.registry.phase(of: sampler), .terminal(.canceled))
        let cleanup = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        XCTAssertEqual(cleanup.owner?.reason, .terminal)
        XCTAssertEqual(cleanup.budget?.anchorInstant, deadline.deadlineInstant)
        XCTAssertEqual(cleanup.disposition, .releaseAfterTeardown)
        XCTAssertTrue(cleanup.poisoned)
    }

    @MainActor
    func testBlockedRealRouteParksQueuedActivationAndCancellationRemainsNotInvoked() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], blockedEvent: .route)
        let handoff = try await harness.acquire(reset: true)
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(harness.registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce))
        XCTAssertEqual(harness.owner.invoke(activation, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if harness.receiver.last?.0.record == activation { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let activationReturned = try XCTUnwrap(harness.receiver.last)
        XCTAssertEqual(activationReturned.0.record, activation)
        let originalSampler = try XCTUnwrap(activationReturned.1.followUp)
        XCTAssertEqual(harness.owner.invoke(originalSampler, receiver: harness.receiver), .rejected,
            "audio入口不能吞掉sampler，必须交付准确原票给路由接收方")
        XCTAssertEqual(harness.owner.sample(originalSampler, receiver: harness.receiver), .started)
        let sdk = harness.sdk
        let reached = await Task.detached { sdk.waitForBlockedCall() }.value
        XCTAssertTrue(reached)
        defer { sdk.releaseBlockedCall() }
        guard case .pending(let pending) = harness.registry.outputRouteObservationSnapshot() else { return XCTFail("reset必须交付真实初次sampler") }
        XCTAssertEqual(pending.sampler, originalSampler)
        harness.clock.set(200)
        harness.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertFalse(harness.registry.complete(originalSampler), "撤权不能让通用complete代替阻塞route的物理返回")
        XCTAssertEqual(harness.registry.phase(of: originalSampler), .cancelRequested)
        XCTAssertEqual(try harness.registry.retireOutputControlRecord(originalSampler), .rejected)
        harness.clock.set(300)
        harness.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
        let next = try XCTUnwrap(harness.registry.beginOutputReactivation(contextNonce: context.contextNonce,
            mandatorySuffix: 1_000_000_000))
        let phase = try XCTUnwrap(harness.registry.registeredAudioSessionPhase())
        XCTAssertEqual(harness.owner.invoke(next, receiver: harness.receiver), .parked, "真实getter仍占permit时，后继原位queued")
        XCTAssertEqual(harness.registry.phase(of: next), .queued)
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
        XCTAssertTrue(harness.registry.requestCancel(next))
        let proof = AudioSessionCanceledBeforeClaimProof(callIdentity: .init(record: next, phaseIdentity: phase.identity))
        XCTAssertEqual(harness.registry.activationOutcome(of: next), .notInvoked(proof))
        XCTAssertEqual(harness.owner.invoke(next, receiver: harness.receiver), .rejected)
        let heartbeat = await Task { @MainActor in 42 }.value
        XCTAssertEqual(heartbeat, 42)
        XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
        sdk.releaseBlockedCall()
        for _ in 0..<500 {
            if harness.registry.phase(of: originalSampler) == .terminal(.canceled) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.registry.phase(of: originalSampler), .terminal(.canceled))
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
        XCTAssertEqual(harness.owner.registration(for: handoff.committed.relayIdentity.acquisitionTicket)?.identity.leaseID,
            phase.identity.leaseID, "阻塞和queued取消期间始终是同一真实lease")
    }

    @MainActor
    func testReceiverReentersExactParkedActivationBeforeAtAfterDeadlineAndEarlierParent() async throws {
        for (parentCap, suffix, instant, shouldStart, lateReturn) in [
            (UInt64(40_000_000_000), UInt64(3_000_000_000), UInt64(3_000_000_199), true, false),
            (40_000_000_000, 3_000_000_000, 3_000_000_200, false, false),
            (40_000_000_000, 3_000_000_000, 3_000_000_201, false, false),
            (2_000_000_000, 100_000_000, 2_000_000_200, false, false),
            (40_000_000_000, 3_000_000_000, 3_000_000_199, true, true)
        ] {
            let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], blockedEvent: .route)
            _ = try await harness.acquire(reset: true, parentCap: parentCap, mandatorySuffix: suffix)
            let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
            let first = try XCTUnwrap(harness.registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce))
            XCTAssertEqual(harness.owner.invoke(first, receiver: harness.receiver), .started)
            for _ in 0..<500 {
                if harness.receiver.last?.0.record == first { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let firstCompletion = try XCTUnwrap(harness.receiver.last)
            XCTAssertEqual(firstCompletion.0.record, first)
            let sampler = try XCTUnwrap(firstCompletion.1.followUp)
            let receiver = ParkedActivationDeadlineReceiver(owner: harness.owner, registry: harness.registry,
                clock: harness.clock, source: sampler)
            XCTAssertEqual(harness.owner.sample(sampler, receiver: receiver), .started)
            let sdk = harness.sdk
            let entered = await Task.detached { sdk.waitForBlockedCall() }.value
            XCTAssertTrue(entered)
            defer { sdk.releaseBlockedCall() }
            harness.clock.set(200)
            harness.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
            harness.clock.set(300)
            harness.registry.executor.safetyIngress.performSyncIngress(.interruptionEnded(shouldResume: true))
            let activation = try XCTUnwrap(harness.registry.beginOutputReactivation(contextNonce: context.contextNonce,
                mandatorySuffix: 1_000_000_000))
            let phase = try XCTUnwrap(harness.registry.registeredAudioSessionPhase())
            let cutoff = try XCTUnwrap(phase.reactivationState?.cutoffArmTicket)
            XCTAssertEqual(harness.owner.invoke(activation, receiver: receiver), .parked)
            XCTAssertEqual(harness.registry.phase(of: activation), .queued)
            XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
            receiver.arm(activation: activation, instant: instant)
            if lateReturn { sdk.armBlocking(.activate) }
            sdk.releaseBlockedCall()
            for _ in 0..<500 {
                if receiver.reentryResult != nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertEqual(receiver.sourcePermit?.record, sampler)
            XCTAssertEqual(receiver.sourcePermit?.operation, .currentRoute)
            XCTAssertEqual(receiver.sourceCompletion?.disposition, .settled)
            XCTAssertEqual(receiver.sourceRetirement, .retired(followUp: nil))
            XCTAssertTrue(receiver.sourceRemovedBeforeReentry)
            XCTAssertTrue(receiver.activationWasQueuedBeforeReentry)
            XCTAssertEqual(receiver.reentryResult, shouldStart ? .started : .rejected, "时刻\(instant)")
            XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
            if shouldStart {
                if lateReturn {
                    let activated = await Task.detached { sdk.waitForBlockedCall() }.value
                    XCTAssertTrue(activated)
                    harness.clock.set(3_000_000_200)
                    XCTAssertNil(try harness.registry.evaluateOutputReactivationCutoffArm(cutoff))
                    XCTAssertEqual(harness.registry.phase(of: activation), .cancelRequested)
                    sdk.releaseBlockedCall()
                }
                for _ in 0..<500 {
                    if receiver.activationPermit != nil { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertEqual(receiver.activationPermit?.record, activation)
                XCTAssertEqual(receiver.activationPermit?.operation, .activate)
                XCTAssertEqual(receiver.activationCompletion?.disposition, lateReturn ? .settled : .accepted)
                XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
                if lateReturn {
                    XCTAssertEqual(graphOwnedDeactivation(harness.registry), .requiresDeactivate(.returnedSuccess(
                        .init(record: activation, phaseIdentity: phase.identity))))
                    let cleanupContext = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
                    let cleanupOwner = try XCTUnwrap(cleanupContext.owner)
                    let coordinator = OutputCleanupCoordinator(registry: harness.registry)
                    let stop = try XCTUnwrap(coordinator.advance(owner: cleanupOwner))
                    XCTAssertTrue(harness.registry.claimStart(stop))
                    let registration = try XCTUnwrap(harness.owner.registration(for: context.committedRelay!.relayIdentity.acquisitionTicket))
                    XCTAssertTrue(registration.stop(stop))
                    let deactivate = try XCTUnwrap(coordinator.advance(owner: cleanupOwner))
                    XCTAssertEqual(harness.owner.invoke(deactivate, receiver: harness.receiver), .started)
                    for _ in 0..<500 {
                        if case .deactivationSettled = graphOwnedDeactivation(harness.registry) { break }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard case .deactivationSettled = graphOwnedDeactivation(harness.registry) else {
                        return XCTFail("迟到原success的清理必须实际完成")
                    }
                    XCTAssertEqual(harness.sdk.events.filter { $0 == .deactivate }.count, 1)
                    XCTAssertEqual(harness.owner.invoke(activation, receiver: receiver), .rejected)
                } else { XCTAssertFalse(harness.registry.outputResourceContextSnapshot()?.poisoned == true) }
            } else {
                XCTAssertNil(receiver.activationPermit)
                XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
                XCTAssertEqual(harness.registry.activationOutcome(of: activation), .notInvoked(.init(
                    callIdentity: .init(record: activation, phaseIdentity: phase.identity))))
                XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.disposition, .releaseAfterTeardown)
                XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.owner?.reason, .terminal)
                XCTAssertTrue(harness.registry.outputResourceContextSnapshot()?.poisoned == true)
                XCTAssertNil(try harness.registry.evaluateOutputReactivationCutoffArm(cutoff))
            }
            XCTAssertEqual(receiver.sourceDeliveryCount, 1, "原SDK返回只能交付一次")
        }
    }

    @MainActor
    func testRealOwnerReusesProcessAcrossLeasesAndResetInvalidatesIt() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
        let first = try await harness.acquire()
        let process = try XCTUnwrap(harness.registry.processAudioSessionReceiptSnapshot())
        let closed = try XCTUnwrap(harness.owner.registration(for: first.committed.relayIdentity.acquisitionTicket))
        try await harness.release(first)
        XCTAssertEqual(harness.registry.processAudioSessionReceiptSnapshot(), process)
        let second = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events.filter { if case .category = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(harness.sdk.events.filter { $0 == .multichannel }.count, 1)
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
        XCTAssertEqual(harness.registry.processAudioSessionReceiptSnapshot(), process)
        let before = harness.registry.executor.safetyIngress.snapshot
        closed.receiveRoute(.init(sessionIdentity: closed.identity.sessionIdentity,
            monitorLifecycle: closed.identity.monitorLifecycle, notificationRevision: 5,
            reasonBits: 1, topologyChangeHint: true, outputConfigurationChanged: true, observedRoute: nil))
        XCTAssertEqual(harness.registry.executor.safetyIngress.snapshot.throughRevision, before.throughRevision)
        harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
        try await harness.release(second)
        XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
        XCTAssertEqual(harness.sdk.events.filter { $0 == .deactivate }.count, 1,
            "reset失效的第二lease不能补调旧epoch deactivate")
    }

    func testSystemRouteBorrowingRejectsWrongTypesAndBoundsBeforeEndpointAccess() throws {
        let sdk = AudioSessionSDKSpy(categoryResults: [], multichannelFails: false,
            executor: ControlTaskRegistry().executor)
        let salt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        for object in [NSNumber(value: 3), NSArray(array: Array(repeating: NSNumber(value: 1), count: 33))] {
            let route = ObjectiveCRouteDouble(outputs: object)
            let snapshot = SystemAudioSessionRouteSnapshot(route: route)
            XCTAssertEqual(AudioSessionBlockingCallLane.project(snapshot, salt: salt), .invalid)
            XCTAssertEqual(route.outputReads, 1, "只借一次原NSArray，不重复桥接outputs")
        }
        let wrongEndpoint = ObjectiveCRouteDouble(outputs: NSArray(object: NSNumber(value: 2)))
        XCTAssertEqual(AudioSessionBlockingCallLane.project(SystemAudioSessionRouteSnapshot(route: wrongEndpoint), salt: salt), .invalid)
        for wrong in [true, false] {
            let port = ObjectiveCPortDouble(uid: wrong ? NSNumber(value: 1) : "真实端点" as NSString,
                port: wrong ? AVAudioSession.Port.builtInSpeaker.rawValue as NSString : NSNumber(value: 2))
            let route = ObjectiveCRouteDouble(outputs: NSArray(object: port))
            XCTAssertEqual(AudioSessionBlockingCallLane.project(SystemAudioSessionRouteSnapshot(route: route), salt: salt), .invalid)
        }
    }

    func testSystemRouteBorrowingHasExactUnicodeByteBoundsAndRejectsMalformedUTF16() throws {
        let sdk = AudioSessionSDKSpy(categoryResults: [], multichannelFails: false,
            executor: ControlTaskRegistry().executor)
        let salt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        var surrogate: unichar = 0xD800
        let invalidUTF16 = NSString(characters: &surrogate, length: 1)
        for (uid, port, valid) in [
            (String(repeating: "😀", count: 64) as NSString, String(repeating: "é", count: 32) as NSString, true),
            (String(repeating: "😀", count: 64).appending("a") as NSString, "port" as NSString, false),
            ("uid" as NSString, String(repeating: "é", count: 32).appending("a") as NSString, false),
            (invalidUTF16, "port" as NSString, false),
            ("" as NSString, "port" as NSString, false)
        ] {
            let route = ObjectiveCRouteDouble(outputs: NSArray(object: ObjectiveCPortDouble(uid: uid, port: port)))
            let evidence = AudioSessionBlockingCallLane.project(SystemAudioSessionRouteSnapshot(route: route), salt: salt)
            if valid {
                guard case .available(let ports, _) = evidence else { XCTFail("精确字节边界必须有效"); continue }
                XCTAssertEqual(ports, .other)
            } else { XCTAssertEqual(evidence, .invalid, "部分转换/超限不能截断成有效或none") }
        }
    }

    @MainActor
    func testRegisteredIngressRejectsWrongSessionWithoutChangingCurrentRevisionOrGate() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let handle = try XCTUnwrap(harness.owner.registration(for: handoff.committed.relayIdentity.acquisitionTicket))
        let before = harness.registry.executor.safetyIngress.snapshot
        let wrong = PlaybackSessionIdentity(sessionID: try harness.allocator.next(in: .session), requestID: UUID())
        handle.receiveRoute(.init(sessionIdentity: wrong, monitorLifecycle: handle.identity.monitorLifecycle,
            notificationRevision: 1, reasonBits: 0, topologyChangeHint: true,
            outputConfigurationChanged: true, observedRoute: nil))
        let after = harness.registry.executor.safetyIngress.snapshot
        XCTAssertEqual(after.throughRevision, before.throughRevision)
        XCTAssertEqual(after.output, before.output)
        XCTAssertNil(after.failure)
    }
    func testWrongBindingCannotCompleteOrReturnAnotherLanesPermit() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
        let wrong = AudioSessionBlockingCallLane(sdk: AudioSessionSDKSpy(categoryResults: [.success],
            multichannelFails: false, executor: fixture.registry.executor))
        let returned = AudioSessionBlockingCallReturned(permit: request.permit, result: .configuration(.categorySucceeded))
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(returned, lane: wrong)), .rejected)
        XCTAssertEqual(fixture.registry.phase(of: fixture.ticket), .running)
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request, .configuration(.categorySucceeded))
        let next = try XCTUnwrap(completion.followUp)
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.claim(next, lane: wrong)), .rejected)
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
    }

    func testWrongFullTicketWithSameNonceOperationAndReplayCannotSettleOriginalPermit() throws {
        let fixture = try ActualAudioConfigurationFixture()
        let request = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, fixture.ticket)
        let original = request.permit.record
        let foreign = try fixture.registry.createGroup(resource: original.group.resourceIdentity)
        let wrongTicket = ControlTaskTicket(group: foreign, nonce: original.nonce)
        for permit in [AudioSessionBlockingCallPermit(record: wrongTicket, operation: request.permit.operation),
            AudioSessionBlockingCallPermit(record: original, operation: .defaultCategory)] {
            XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: permit,
                result: .configuration(.categorySucceeded)), lane: fixture.lane)), .rejected)
            XCTAssertEqual(fixture.registry.phase(of: original), .running)
            XCTAssertFalse(fixture.registry.complete(original))
        }
        let completion = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, request,
            .configuration(.categorySucceeded))
        let next = try XCTUnwrap(completion.followUp)
        XCTAssertNil(fixture.registry.phase(of: original))
        XCTAssertEqual(fixture.registry.phase(of: next), .queued)
        let followUp = try claimGraphAudioCall(fixture.registry, lane: fixture.lane, next)
        XCTAssertEqual(fixture.registry.executor.performAudioSessionCall(.complete(.init(permit: request.permit,
            result: .configuration(.categorySucceeded)), lane: fixture.lane)), .rejected)
        XCTAssertEqual(fixture.registry.phase(of: next), .running, "重放不得结清新版真实在途permit")
        _ = try completeGraphAudioCall(fixture.registry, lane: fixture.lane, followUp, .configuration(.multichannelCapability(true)))
    }

    func testBoundLaneDoesNotPermanentlyRetainOwnerRegistryOrSDK() throws {
        weak var registryReference: ControlTaskRegistry?
        weak var ownerReference: PlaybackAudioSessionOwner?
        weak var sdkReference: AudioSessionSDKSpy?
        do {
            let registry = ControlTaskRegistry(allocator: .init(), clock: ManualPlaybackClock(100))
            let sdk = AudioSessionSDKSpy(categoryResults: [.success], multichannelFails: false, executor: registry.executor)
            let owner = try makeLifecycleOwner(registry: registry, sdk: sdk)
            registryReference = registry
            ownerReference = owner
            sdkReference = sdk
            withExtendedLifetime(owner) {}
        }
        XCTAssertNil(ownerReference)
        XCTAssertNil(registryReference)
        XCTAssertNil(sdkReference)
    }
    @MainActor
    func testSingleCurrentRouteKeepsItsAcceptedSourceForTheExactStabilitySuccessor() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], route: BuiltInSDKRouteSnapshot())
        let handoff = try await harness.acquire()
        let sampler = try XCTUnwrap(handoff.sampler)
        XCTAssertEqual(harness.owner.sample(sampler, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if harness.sdk.events.contains(.route), harness.registry.phase(of: sampler) != .running { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.sdk.events.filter { $0 == .route }.count, 1)
        XCTAssertEqual(harness.registry.phase(of: sampler), .terminal(.completed))
        let observation = try XCTUnwrap(handoff.routeObservation)
        let stability = try XCTUnwrap(harness.registry.armOutputRouteStability(observation: observation))
        XCTAssertEqual(stability.source, sampler)
        XCTAssertEqual(stability.authority.semanticIdentity?.ports, .builtIn)
        XCTAssertEqual(stability.authority.semanticIdentity?.backend, .sampleBuffer)
    }
    func testSameRegistryRejectsSecondSDKOwnerBeforeAnySDKWork() throws {
        let registry = ControlTaskRegistry(allocator: .init(), clock: ManualPlaybackClock(100))
        let firstSDK = AudioSessionSDKSpy(categoryResults: [.success], multichannelFails: false, executor: registry.executor)
        let first = try makeLifecycleOwner(registry: registry, sdk: firstSDK)
        let secondSDK = AudioSessionSDKSpy(categoryResults: [.success], multichannelFails: false, executor: registry.executor)
        XCTAssertThrowsError(try makeLifecycleOwner(registry: registry, sdk: secondSDK))
        XCTAssertTrue(firstSDK.events.isEmpty)
        XCTAssertTrue(secondSDK.events.isEmpty)
        XCTAssertEqual(secondSDK.randomInvocationCount, 0)
        withExtendedLifetime(first) {}
    }
    @MainActor
    func testBlockedActivationKeepsMainAndIngressAliveThenLateSuccessDeactivatesOnce() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], blockedEvent: .activate)
        let acquisition = try harness.prepareAcquisition()
        XCTAssertTrue(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        let sdk = harness.sdk
        let reached = await Task.detached { sdk.waitForBlockedCall() }.value
        XCTAssertTrue(reached)
        defer { harness.sdk.releaseBlockedCall() }
        let heartbeat = await Task { @MainActor in 42 }.value
        XCTAssertEqual(heartbeat, 42)
        let registration = try XCTUnwrap(harness.owner.registration(for: acquisition))
        let before = harness.registry.executor.safetyIngress.snapshot.throughRevision
        harness.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertGreaterThan(harness.registry.executor.safetyIngress.snapshot.throughRevision, before)
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: harness.registry)
        let owner = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce, reason: .stop,
            at: harness.clock.nowNanoseconds, teardown: true))
        let stop = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertTrue(harness.registry.claimStart(stop))
        XCTAssertTrue(registration.stop(stop))
        XCTAssertNil(try coordinator.advance(owner: owner), "SDK未返回之前不能创建deactivate或释放lease")
        XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
        harness.sdk.releaseBlockedCall()
        for _ in 0..<500 {
            if case .lease(_, _, _, .requiresDeactivate) = harness.registry.ownedResourceSnapshot()?.payload { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard case .lease(_, _, _, .requiresDeactivate(.returnedSuccess(let original))) = harness.registry.ownedResourceSnapshot()?.payload
        else { return XCTFail("迟到success必须保留原调用的deactivate责任") }
        XCTAssertEqual(original.phaseIdentity.leaseID, registration.identity.leaseID)
        let deactivation = try XCTUnwrap(coordinator.advance(owner: owner))
        XCTAssertEqual(harness.owner.invoke(deactivation, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if case .lease(_, _, _, .deactivationSettled) = harness.registry.ownedResourceSnapshot()?.payload { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.sdk.events.filter { $0 == .deactivate }.count, 1)
        XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
        XCTAssertFalse(harness.sdk.usedMainThread)
        XCTAssertFalse(harness.sdk.usedControlExecutor)
        let secondSDK = AudioSessionSDKSpy(categoryResults: [.success], multichannelFails: false, executor: harness.registry.executor)
        XCTAssertThrowsError(try makeLifecycleOwner(registry: harness.registry, sdk: secondSDK))
        harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertThrowsError(try makeLifecycleOwner(registry: harness.registry, sdk: secondSDK))
        XCTAssertEqual(secondSDK.randomInvocationCount, 0)
    }
    @MainActor
    func testLeaseIdentityExhaustionCompletesOriginalAcquireWithoutPartialRegistration() throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success],
            allocator: .init(initialIssuedValue: .max, initialNamespace: .lease))
        let acquisition = try harness.prepareAcquisition()
        XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        XCTAssertEqual(harness.sdk.randomInvocationCount, 1)
        XCTAssertTrue(harness.sdk.events.isEmpty)
        XCTAssertNil(harness.owner.registration(for: acquisition))
        XCTAssertNil(harness.registry.ownedResourceSnapshot())
        XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.acquisitionNoLeaseReceipt?.acquisitionTicket, acquisition)
        XCTAssertEqual(harness.registry.phase(of: acquisition), .terminal(.canceled), "耗尽先撤权，但必须准确记录实际no-lease返回")
        XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        XCTAssertEqual(harness.sdk.randomInvocationCount, 1, "准确原acquire已结清，重放不得再次随机或发行lease")
    }

    @MainActor
    func testRandomFailureCompletesTheOriginalAcquisitionWithoutLease() throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], randomFails: true)
        let acquisition = try harness.prepareAcquisition()
        XCTAssertFalse(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        XCTAssertTrue(harness.sdk.events.isEmpty)
        XCTAssertNil(harness.registry.ownedResourceSnapshot())
        XCTAssertNotNil(harness.registry.outputResourceContextSnapshot()?.acquisitionNoLeaseReceipt)
        XCTAssertEqual(harness.registry.phase(of: acquisition), .terminal(.completed))
    }

    @MainActor
    func testAcquisitionActivationFailureDoesNotRetryOrProduceReadyReceipt() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], activationFailures: 1)
        let acquisition = try harness.prepareAcquisition()
        XCTAssertTrue(harness.owner.startAcquisition(acquisition, receiver: harness.receiver))
        for _ in 0..<500 {
            if harness.registry.outputAcquisitionCommitSnapshot() != nil ||
                harness.registry.outputResourceContextSnapshot()?.disposition == .releaseAfterTeardown { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 1)
        XCTAssertNil(harness.registry.outputAcquisitionCommitSnapshot())
        XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.disposition, .releaseAfterTeardown)
    }
    func testActualLaneABIIncludesOriginalRequestAndRegisteredResourceLifetime() {
        let base = ControlTaskRegistry.fixedValueStorageBytes + PlaybackDeadlineScheduler.fixedValueStorageBytes +
            ControlTaskRegistry.boundedResourceTransitionPreparationValueBytes +
            PlaybackDeadlineScheduler.boundedDeliveryPreparationValueBytes +
            ControlTaskRegistry.groupTicketProjectionPreparationValueBytes + MemoryLayout<OutputResourceOwnershipSnapshot>.stride
        // handle:identity/salt/weakRegistry；owner:Registry/lane；lane:queue/SDK；systemSDK:session。
        // Authority绑定已在fixedValueStorageBytes内；单次system route的route/NSArray引用属于瞬时投影，不重复当常驻。
        let runtime = MemoryLayout<PlaybackAudioSessionRegistrationIdentity>.stride + MemoryLayout<AudioSessionEndpointSalt>.stride +
            5 * MemoryLayout<UnsafeRawPointer>.stride + MemoryLayout<any PlaybackAudioSessionSDK>.stride
        let runtimeTypes: [AnyClass] = [PlaybackAudioSessionRegistration.self, PlaybackAudioSessionOwner.self,
            AudioSessionBlockingCallLane.self, SystemPlaybackAudioSessionSDK.self]
        let value = XCTAttachment(string: """
        actualOldPathPeakWithAuthority=\(base)
        additionalRuntimeFields=\(runtime)
        permitOptional=\(MemoryLayout<AudioSessionBlockingCallPermit?>.stride)
        privatePermitOptional=\(ControlTaskRegistry.audioSessionInFlightPermitValueBytes)
        registrationIdentity=\(MemoryLayout<PlaybackAudioSessionRegistrationIdentity>.stride)
        fingerprintOptional=\(MemoryLayout<SessionEndpointFingerprint?>.stride)
        incarnationOptional=\(MemoryLayout<OutputConfigurationIncarnation?>.stride)
        request=\(MemoryLayout<AudioSessionBlockingCallRequest>.stride)
        returned=\(MemoryLayout<AudioSessionBlockingCallReturned>.stride)
        action=\(MemoryLayout<AudioSessionBlockingCallAction>.stride)
        result=\(MemoryLayout<AudioSessionBlockingCallResult>.stride)
        application=\(MemoryLayout<AudioSessionBlockingCallApplication>.stride)
        completion=\(MemoryLayout<AudioSessionBlockingCallCompletion>.stride)
        privateRequest=\(MemoryLayout<OutputControlRequest>.stride)
        privateApplication=\(MemoryLayout<OutputControlApplication>.stride)
        snapshot=\(MemoryLayout<PlaybackSafetySnapshot>.stride)
        output=\(MemoryLayout<PlaybackOutputSafetyState>.stride)
        operations=\(ControlTaskRegistry.audioSessionLockedOperationsValueBytes)
        hashContext=\(MemoryLayout<CC_SHA256_CTX>.stride)
        endpoint=\(MemoryLayout<AudioSessionRouteEndpoint>.stride)
        routeExistential=\(MemoryLayout<any AudioSessionRouteSnapshot>.stride)
        fixedHashScratch=\(32 * MemoryLayout<SessionEndpointFingerprint>.stride + 256)
        fullActivationOutcome=\(MemoryLayout<AudioSessionActivationTerminalOutcome?>.stride)
        fullCall=\(MemoryLayout<AudioSessionCallIdentity>.stride)
        phaseIdentity=\(MemoryLayout<AudioSessionPhaseIdentity>.stride)
        phasePolicy=\(MemoryLayout<AudioSessionPhasePolicy>.stride)
        compactOutcome=\(MemoryLayout<OwnedAudioSessionActivationResult?>.stride)
        ownerInvocationTicket=\(MemoryLayout<ControlTaskTicket>.stride)
        sdkLeafOperationAndRegistration=\(MemoryLayout<(AudioSessionBlockingCallOperation, PlaybackAudioSessionRegistration?)>.stride)
        range=\(MemoryLayout<Range<Int>>.stride)
        rangeIterator=\(MemoryLayout<Range<Int>.Iterator>.stride)
        nsStringReference=\(MemoryLayout<NSString>.stride)
        cfRange=\(MemoryLayout<CFRange>.stride)
        receiver=\(MemoryLayout<any PlaybackAudioSessionCompletionReceiving>.stride)
        family=\(MemoryLayout<AudioSessionCallFamily>.stride)
        callStart=\(MemoryLayout<AudioSessionCallStart>.stride)
        deliveryFields=\(MemoryLayout<(AudioSessionBlockingCallRequest, PlaybackAudioSessionOwner, any PlaybackAudioSessionCompletionReceiving)>.stride)
        deliveryInstance=\(class_getInstanceSize(AudioSessionCallDelivery.self))
        deliveryAllocation=\(malloc_good_size(class_getInstanceSize(AudioSessionCallDelivery.self)))
        preparedDelivery=\(MemoryLayout<AudioSessionPreparedDelivery>.stride)
        ownedRuntimeAllocation=\(runtimeTypes.reduce(0) { $0 + malloc_good_size(class_getInstanceSize($1)) })
        reactivation=\(ControlTaskRegistry.boundedReactivationPreparationValueBytes)
        user=\(ControlTaskRegistry.boundedUserControlPreparationValueBytes)
        route=\(ControlTaskRegistry.boundedRouteSamplePreparationValueBytes)
        budget=\(ControlTaskRegistry.boundedPlaybackBudgetPreparationValueBytes)
        resetCommit=\(ControlTaskRegistry.boundedAudioSessionResetCommitPreparationValueBytes)
        resourceContext=\(MemoryLayout<OutputResourceContext>.stride)
        phase=\(MemoryLayout<RegisteredAudioSessionPhase>.stride)
        routeClaim=\(MemoryLayout<OutputRouteSampleClaim>.stride)
        routeEvidence=\(MemoryLayout<AudioSessionRouteSampleEvidence>.stride)
        systemSnapshotAllocation=\(malloc_good_size(class_getInstanceSize(SystemAudioSessionRouteSnapshot.self)))
        safetyBarrierApplication=\(MemoryLayout<PlaybackSafetyBarrierResult<AudioSessionBlockingCallApplication>>.stride)
        privateBarrierApplication=\(MemoryLayout<PlaybackSafetyBarrierResult<OutputControlApplication>>.stride)
        cfArguments=\(MemoryLayout<(CFString, CFRange, CFStringEncoding, UInt8, Bool, UnsafeMutablePointer<UInt8>?, CFIndex, UnsafeMutablePointer<CFIndex>)>.stride)
        configuredAcquisition=\(MemoryLayout<OutputConfiguredAcquisition>.stride)
        acquiredLease=\(MemoryLayout<OutputAcquiredLease>.stride)
        acquisitionCommit=\(MemoryLayout<OutputAcquisitionCommitToken>.stride)
        receipts=\(MemoryLayout<OutputSessionReceipts>.stride)
        pendingObservation=\(MemoryLayout<PendingRouteObservation>.stride)
        reactivationState=\(MemoryLayout<AudioSessionReactivationBudgetState>.stride)
        reactivationBudget=\(MemoryLayout<AudioSessionReactivationBudgetTicket>.stride)
        reactivationAttempt=\(MemoryLayout<AudioSessionReactivationAttemptTicket>.stride)
        activationPurpose=\(MemoryLayout<AudioSessionActivationPurpose>.stride)
        reactivationProof=\(MemoryLayout<AudioSessionReactivationProof>.stride)
        parentDeadline=\(MemoryLayout<CurrentPlaybackOperationDeadlineTicket>.stride)
        parentBudget=\(MemoryLayout<PlaybackProgressBudgetTicket>.stride)
        configurationAttempt=\(MemoryLayout<AudioSessionConfigurationAttempt>.stride)
        cleanupReservation=\(MemoryLayout<CleanupReservation>.stride)
        preparedCommand=\(ControlTaskRegistry.boundedCommandPreparationValueBytes)
        command=\(MemoryLayout<OwnedPostIngressControlCommand>.stride)
        outputRouteResult=\(MemoryLayout<OutputRouteSampleResult>.stride)
        routeReplacement=\(ControlTaskRegistry.boundedRouteSamplerReplacementPreparationValueBytes)
        outputTransition=\(ControlTaskRegistry.boundedOutputTransitionPreparationValueBytes)
        completionFollowUp=\(ControlTaskRegistry.audioSessionCompletionFollowUpValueBytes)
        claimPreparation=\(ControlTaskRegistry.audioSessionClaimPreparationValueBytes)
        rawScratchAllocation=\(malloc_good_size(1024) + malloc_good_size(256))
        observationTicket=\(MemoryLayout<RouteObservationTicket>.stride)
        routeAuthority=\(MemoryLayout<PlaybackRouteAuthorityIdentity>.stride)
        routeBoundary=\(MemoryLayout<OutputRouteAvailabilityBoundary>.stride)
        leaseResources=\(MemoryLayout<OwnedAudioSessionLeaseResources>.stride)
        postRouteState=\(MemoryLayout<PostConfigurationRouteState>.stride)
        resetState=\(MemoryLayout<ResetPreRouteRecoveryDeadlineState>.stride)
        resetBinding=\(MemoryLayout<SystemRecoveryLeaseBinding>.stride)
        inactiveReceipt=\(MemoryLayout<InactiveAudioSessionConfigurationReceipt>.stride)
        cleanupBudget=\(MemoryLayout<CleanupBudgetTicket>.stride)
        reservedSlot=\(MemoryLayout<ReservedCleanupSlot>.stride)
        groupTicket=\(MemoryLayout<ControlTaskGroupTicket>.stride)
        transitionOwner=\(MemoryLayout<OutputTransitionOwnerTicket>.stride)
        backendResources=\(MemoryLayout<OwnedBackendResources>.stride)
        lifecycle=\(MemoryLayout<OutputLifecycleEpoch>.stride)
        suspendOptional=\(MemoryLayout<OutputSuspendTicket?>.stride)
        suspend=\(MemoryLayout<OutputSuspendTicket>.stride)
        intervalKey=\(MemoryLayout<PotentiallyAudibleOutputIntervalKey>.stride)
        closeClaim=\(MemoryLayout<PotentiallyAudibleOutputCloseClaim>.stride)
        carriedPostStage=\(MemoryLayout<InheritedRouteAvailabilityConstraint.CarriedPostConfigurationStage?>.stride)
        processReceipt=\(MemoryLayout<ProcessAudioSessionConfigurationReceipt>.stride)
        configuredReceipt=\(MemoryLayout<ConfiguredSessionReceipt>.stride)
        activeReceipt=\(MemoryLayout<ActiveSessionReceipt>.stride)
        transitionIdentity=\(MemoryLayout<ConfigurationTransitionIdentity>.stride)
        postRouteBudget=\(MemoryLayout<PostConfigurationRouteBudget>.stride)
        resetPostProof=\(MemoryLayout<ResetPostConfigurationProof>.stride)
        resetValidatedTuple=\(MemoryLayout<(index: Int, identity: AudioSessionPhaseIdentity)>.stride)
        resetValidatedTupleOptional=\(MemoryLayout<(index: Int, identity: AudioSessionPhaseIdentity)?>.stride)
        """)
        value.lifetime = .keepAlways
        add(value)
        // 仅ABI事实探针；allocation由唯一reservation验证，真实栈另做同源Debug/Release有限验证。
        XCTAssertEqual(MemoryLayout<CC_SHA256_CTX>.stride, 104)
    }

    // 原逐SIL临时式69993等仅留历史诊断；64KiB统一由真实allocation门槛验证。

    func testAudioRecordRejectsTerminalCallForAnotherOriginalTicket() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        var record = try OwnedPostIngressControlCommand(controlTaskTicket: fixture.ticket,
            slot: .audioSessionRecovery, safetySnapshot: .cleanupOwnership, gatePolicy: .audioSession,
            audioPhaseIdentity: phase.identity, audioPolicy: phase.policy)
        let wrongTicket = ControlTaskTicket(group: fixture.ticket.group, nonce: fixture.ticket.nonce + 1)
        record.activationOutcome = .returnedSuccess(.init(record: wrongTicket, phaseIdentity: phase.identity))
        XCTAssertNil(record.activationOutcome, "压缩不能把另一原票的success改写成此record的物理结果")
        let valid = AudioSessionActivationTerminalOutcome.returnedSuccess(.init(record: fixture.ticket,
            phaseIdentity: phase.identity))
        record.activationOutcome = valid
        XCTAssertEqual(record.activationOutcome, valid)
        record.activationOutcome = .returnedFailure(.init(record: wrongTicket, phaseIdentity: phase.identity),
            .init(domain: .audioSession, code: -1))
        XCTAssertEqual(record.activationOutcome, valid, "错票必须保留已登记的完整结果")
    }

    func testDeactivationRepresentationRejectsCallFromAnotherOwnerGroup() throws {
        let fixture = try ActualAudioActivationFixture(kind: 0)
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        let reservation = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot()).ticket
        let wrongCall = AudioSessionCallIdentity(record: fixture.ticket, phaseIdentity: phase.identity)
        let request = AudioSessionCleanupDeactivationRequest(reservation: reservation,
            contextNonce: phase.identity.contextNonce, leaseID: phase.identity.leaseID,
            source: .returnedSuccess(wrongCall), call: wrongCall)
        XCTAssertNil(request, "原call group不是reservation ownerGroup时不能丢字段后静默归一化")
    }

    @MainActor
    func testActualFallbackIsDrivenBySeparateSDKResultsBeforeActivation() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
        try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [.category(.longFormAudio), .category(.default), .multichannel, .activate])
        XCTAssertEqual(harness.registry.processAudioSessionReceiptSnapshot()?.actualPolicy, .default)
        XCTAssertFalse(harness.sdk.usedMainThread)
        XCTAssertFalse(harness.sdk.usedControlExecutor)
        XCTAssertEqual(harness.sdk.maximumConcurrentCalls, 1)
    }

    @MainActor
    func testLongFormSuccessDoesNotInvokeDefaultAndMultichannelFailureIsCapabilityFalse() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], multichannelFails: true)
        try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [.category(.longFormAudio), .multichannel, .activate])
        let process = try XCTUnwrap(harness.registry.processAudioSessionReceiptSnapshot())
        XCTAssertEqual(process.actualPolicy, .longFormAudio)
        XCTAssertFalse(process.multichannelCapability)
        XCTAssertNil(process.preferredFailureReason)
    }

}

private func makeLifecycleOwner(registry: ControlTaskRegistry, sdk: any PlaybackAudioSessionSDK) throws -> PlaybackAudioSessionOwner {
    try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
}

/// 仅探针读取公开Array capacity；不从元素地址推测或读取heap header。
private protocol NativeArrayAllocationObservation {
    var observedCount: Int { get }
    var observedCapacity: Int { get }
    var observedElementStride: Int { get }
    var observedStorageIdentity: UInt { get }
}
extension Array: NativeArrayAllocationObservation {
    fileprivate var observedCount: Int { count }
    fileprivate var observedCapacity: Int { capacity }
    fileprivate var observedElementStride: Int { MemoryLayout<Element>.stride }
    fileprivate var observedStorageIdentity: UInt { withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } }
}

/// 保存测试已由真实Registry发行的准确queued票；回调不读current、不构造phase或权限。
private final class ParkedActivationDeadlineReceiver: PlaybackAudioSessionCompletionReceiving, @unchecked Sendable {
    private let owner: PlaybackAudioSessionOwner
    private let registry: ControlTaskRegistry
    private let clock: ManualPlaybackClock
    private let source: ControlTaskTicket
    private let lock = NSLock()
    private var target: (ControlTaskTicket, UInt64)?
    private var activation: ControlTaskTicket?
    private var sourceValue: (AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)?
    private var activationValue: (AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)?
    private var result: AudioSessionCallStart?
    private var sourceCount = 0
    private var retired: OutputControlRecordRetirement?
    private var sourceRemoved = false
    private var targetQueued = false
    init(owner: PlaybackAudioSessionOwner, registry: ControlTaskRegistry, clock: ManualPlaybackClock, source: ControlTaskTicket) {
        self.owner = owner; self.registry = registry; self.clock = clock; self.source = source
    }
    func arm(activation: ControlTaskTicket, instant: UInt64) {
        lock.withLock { target = (activation, instant); self.activation = activation }
    }
    var reentryResult: AudioSessionCallStart? { lock.withLock { result } }
    var sourcePermit: AudioSessionBlockingCallPermit? { lock.withLock { sourceValue?.0 } }
    var sourceCompletion: AudioSessionBlockingCallCompletion? { lock.withLock { sourceValue?.1 } }
    var activationPermit: AudioSessionBlockingCallPermit? { lock.withLock { activationValue?.0 } }
    var activationCompletion: AudioSessionBlockingCallCompletion? { lock.withLock { activationValue?.1 } }
    var sourceDeliveryCount: Int { lock.withLock { sourceCount } }
    var sourceRetirement: OutputControlRecordRetirement? { lock.withLock { retired } }
    var sourceRemovedBeforeReentry: Bool { lock.withLock { sourceRemoved } }
    var activationWasQueuedBeforeReentry: Bool { lock.withLock { targetQueued } }
    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit, completion: AudioSessionBlockingCallCompletion) {
        if permit.record != source {
            let original = lock.withLock { () -> Bool in
                guard permit.record == activation, activationValue == nil else { return false }
                activationValue = (permit, completion)
                return true
            }
            // 失败诊断也经真实ingress结束链，不能在测试退出后留下自动重试。
            if original && completion.disposition != .accepted && registry.outputResourceContextSnapshot()?.poisoned != true {
                registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            }
            return
        }
        let queued: (ControlTaskTicket, UInt64)? = lock.withLock {
            sourceCount += 1
            sourceValue = (permit, completion)
            defer { target = nil }
            return target
        }
        guard let (ticket, instant) = queued else { return }
        // 物理terminal不等于consumer退休；使用本次原permit，不读current寻找替代票。
        let retirement = try? registry.retireOutputControlRecord(permit.record)
        let removed = registry.phase(of: permit.record) == nil
        let isQueued = registry.phase(of: ticket) == .queued
        lock.withLock { retired = retirement; sourceRemoved = removed; targetQueued = isQueued }
        clock.set(instant)
        let start = owner.invoke(ticket, receiver: self)
        lock.withLock { result = start }
    }
}

final class AudioSessionCompletionObservation: PlaybackAudioSessionCompletionReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private weak var registry: ControlTaskRegistry?
    private var value: (AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)?
    private var observations: [(AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)] = []
    private var onExecutor = false
    private var cellReadable = false
    private weak var reenterOwner: PlaybackAudioSessionOwner?
    private var shouldReenter: Bool
    private var closed = false
    private var deliveries = 0
    private var reentry: AudioSessionCallStart?
    private var nextTicket: ControlTaskTicket?
    init(registry: ControlTaskRegistry, reenterOwner: PlaybackAudioSessionOwner? = nil) {
        self.registry = registry
        self.reenterOwner = reenterOwner
        shouldReenter = reenterOwner != nil
    }
    var last: (AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)? { lock.withLock { value } }
    var history: [(AudioSessionBlockingCallPermit, AudioSessionBlockingCallCompletion)] { lock.withLock { observations } }
    var deliveredOnExecutor: Bool { lock.withLock { onExecutor } }
    var cellWasReadable: Bool { lock.withLock { cellReadable } }
    var deliveryCount: Int { lock.withLock { deliveries } }
    var reentryResult: AudioSessionCallStart? { lock.withLock { reentry } }
    var reentryTicket: ControlTaskTicket? { lock.withLock { nextTicket } }
    func close() { lock.withLock { closed = true } }
    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit, completion: AudioSessionBlockingCallCompletion) {
        let isolated = registry?.executor.isIsolated == true
        let read = registry?.executor.safetyIngress.snapshot != nil
        let next: ControlTaskTicket? = lock.withLock {
            deliveries += 1
            guard !closed else { return nil }
            value = (permit, completion); onExecutor = isolated; cellReadable = read
            observations.append((permit, completion))
            guard shouldReenter, permit.operation == .currentRoute else { return nil }
            shouldReenter = false
            nextTicket = completion.followUp
            return completion.followUp
        }
        if let next, let reenterOwner {
            let result = reenterOwner.sample(next, receiver: self)
            lock.withLock { reentry = result }
        }
    }
}

/// 只替代公开ObjC getter的底层对象，不参与registration、许可或路由Authority决策。
private final class ObjectiveCRouteDouble: NSObject {
    private let outputObject: NSObject
    private(set) var outputReads = 0
    init(outputs: NSObject) { outputObject = outputs }
    @objc var outputs: NSObject { outputReads += 1; return outputObject }
}
private final class ObjectiveCPortDouble: NSObject {
    private let uidObject: NSObject
    private let portObject: NSObject
    private let sourceObject: NSObject?
    init(uid: NSObject, port: NSObject, source: NSObject? = nil) { uidObject = uid; portObject = port; sourceObject = source }
    @objc var UID: NSObject { uidObject }
    @objc var portType: NSObject { portObject }
    @objc var selectedDataSource: NSObject? { sourceObject }
}
private final class ObjectiveCDataSourceDouble: NSObject {
    @objc let dataSourceID: NSObject
    init(_ value: NSObject) { dataSourceID = value }
}

@MainActor
final class AudioSessionLifecycleTestHarness {
    let allocator: PlaybackIdentityAllocator
    let clock = ManualPlaybackClock(100)
    let registry: ControlTaskRegistry
    let sdk: AudioSessionSDKSpy
    let owner: PlaybackAudioSessionOwner
    let receiver: AudioSessionCompletionObservation

    init(categoryResults: [AudioSessionSDKSpy.Result], multichannelFails: Bool = false,
        randomFails: Bool = false, activationFailures: Int = 0, blockedEvent: AudioSessionSDKSpy.Event? = nil,
        route: any AudioSessionRouteSnapshot = EmptySDKRouteSnapshot(), allocator: PlaybackIdentityAllocator = .init(),
        categoryFailure: NSError? = nil) throws {
        self.allocator = allocator
        registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        sdk = AudioSessionSDKSpy(categoryResults: categoryResults, multichannelFails: multichannelFails,
            executor: registry.executor, randomFails: randomFails, activationFailures: activationFailures,
            blockedEvent: blockedEvent, route: route, categoryFailure: categoryFailure)
        receiver = AudioSessionCompletionObservation(registry: registry)
        owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
    }

    func prepareAcquisition(reset: Bool = false, parentCap: UInt64 = 40_000_000_000,
        mandatorySuffix: UInt64 = 3_000_000_000) throws -> ControlTaskTicket {
        let session = PlaybackSessionIdentity(sessionID: try allocator.next(in: .session), requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
            identity: .init(sessionIdentity: session, nonce: try allocator.next(in: .deadline)), kind: .coldStart,
            originInstant: clock.nowNanoseconds, cap: parentCap, accumulatedEffectiveTime: 0,
            runningSince: nil, freezeGeneration: 0))
        if reset {
            let root = try capturedResetRoot(registry)
            let proof = try XCTUnwrap(registry.issueEmptyOutputResetDrainProof(root: root))
            return try XCTUnwrap(registry.beginResetOutputAcquisition(session: session, parent: parent,
                admission: .init(proof: proof, mandatorySuffix: mandatorySuffix, inheritedRouteAvailabilityConstraint: nil)))
        }
        return try XCTUnwrap(registry.beginOutputAcquisition(session: session, parent: parent,
            resetRecoveryMandatorySuffix: mandatorySuffix))
    }

    @discardableResult
    func acquire(reset: Bool = false, parentCap: UInt64 = 40_000_000_000,
        mandatorySuffix: UInt64 = 3_000_000_000) async throws -> OutputAcquisitionHandoff {
        let acquisition = try prepareAcquisition(reset: reset, parentCap: parentCap, mandatorySuffix: mandatorySuffix)
        XCTAssertTrue(owner.startAcquisition(acquisition, receiver: receiver))
        // 只观察真实ready-to-commit结果，不制造配置phase、receipt或reservation proof。
        for _ in 0..<500 {
            if let token = registry.outputAcquisitionCommitSnapshot() {
                guard case .committed(let handoff) = try registry.commitAcquisitionRelayAndContext(token) else {
                    throw HarnessFailure.handoff
                }
                return handoff
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HarnessFailure.didNotBecomeReady
    }
    func release(_ handoff: OutputAcquisitionHandoff) async throws {
        let handle = try XCTUnwrap(owner.registration(for: handoff.committed.relayIdentity.acquisitionTicket))
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let coordinator = OutputCleanupCoordinator(registry: registry)
        let cleanup = try XCTUnwrap(coordinator.begin(contextNonce: context.contextNonce,
            reason: .stop, at: clock.nowNanoseconds))
        let reservation = try XCTUnwrap(registry.cleanupReservationSnapshot())
        let monitor = try XCTUnwrap(coordinator.advance(owner: cleanup))
        XCTAssertTrue(registry.claimStart(monitor))
        XCTAssertTrue(handle.stop(monitor))
        if case .requiresDeactivate = graphOwnedDeactivation(registry) {
            let deactivate = try XCTUnwrap(coordinator.advance(owner: cleanup))
            XCTAssertEqual(owner.invoke(deactivate, receiver: receiver), .started)
            for _ in 0..<500 {
                if case .deactivationSettled = graphOwnedDeactivation(registry) { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard case .deactivationSettled = graphOwnedDeactivation(registry) else { throw HarnessFailure.didNotBecomeReady }
        }
        let release = try XCTUnwrap(coordinator.advance(owner: cleanup))
        var runner = registry.claimOwnedResourceReleaseRunner(release)
        XCTAssertNotNil(runner)
        XCTAssertTrue(registry.complete(release))
        runner = nil
        XCTAssertTrue(registry.complete(reservation.task(for: .owner)))
        XCTAssertTrue(registry.releaseCleanupReservation(reservation.ticket))
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.outputRouteObservationSnapshot())
    }
    enum HarnessFailure: Error { case handoff, didNotBecomeReady }
}

final class AudioSessionSDKSpy: PlaybackAudioSessionSDK, @unchecked Sendable {
    enum Result { case success, failure }
    enum Event: Equatable {
        case category(AudioSessionActualPolicy), multichannel, activate, deactivate, route
    }
    enum Failure: Error { case sdk }
    enum ReentrantAction: CaseIterable { case began, reset, stop }
    private let lock = NSLock()
    private weak var executor: PlaybackControlExecutor?
    private var categoryResults: [Result]
    private let categoryFailure: NSError?
    private let multichannelFails: Bool
    private let randomFails: Bool
    private var activationFailures: Int
    private var blockedEvent: Event?
    private let route: any AudioSessionRouteSnapshot
    private let enteredBlocked = DispatchSemaphore(value: 0)
    private let unblock = DispatchSemaphore(value: 0)
    private var recorded: [Event] = []
    private var mainThread = false
    private var controlExecutor = false
    private var concurrent = 0
    private var maximum = 0
    private var randomInvocations = 0
    private weak var reentrantRegistry: ControlTaskRegistry?
    private var reentrantStage: Event?
    private var reentrantAction: ReentrantAction?
    private var reentrantContextNonce: UInt64 = 0
    private var reentrantInstant: UInt64 = 0
    private var reentrantCompleted = false

    init(categoryResults: [Result], multichannelFails: Bool, executor: PlaybackControlExecutor,
        randomFails: Bool = false, activationFailures: Int = 0, blockedEvent: Event? = nil,
        route: any AudioSessionRouteSnapshot = EmptySDKRouteSnapshot(), categoryFailure: NSError? = nil) {
        self.categoryResults = categoryResults
        self.categoryFailure = categoryFailure
        self.multichannelFails = multichannelFails
        self.executor = executor
        self.randomFails = randomFails
        self.activationFailures = activationFailures
        self.blockedEvent = blockedEvent
        self.route = route
    }
    var events: [Event] { lock.withLock { recorded } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    var usedControlExecutor: Bool { lock.withLock { controlExecutor } }
    var maximumConcurrentCalls: Int { lock.withLock { maximum } }
    var randomInvocationCount: Int { lock.withLock { randomInvocations } }
    var reentrantCallCompleted: Bool { lock.withLock { reentrantCompleted } }
    func armReentrancy(stage: Event, action: ReentrantAction, registry: ControlTaskRegistry,
        contextNonce: UInt64, instant: UInt64) {
        lock.withLock {
            reentrantStage = stage; reentrantAction = action; reentrantRegistry = registry
            reentrantContextNonce = contextNonce; reentrantInstant = instant
        }
    }
    func waitForBlockedCall() -> Bool { enteredBlocked.wait(timeout: .now() + 2) == .success }
    func releaseBlockedCall() { unblock.signal() }
    func armBlocking(_ event: Event) { lock.withLock { blockedEvent = event } }

    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {
        enter(.category(policy))
        defer { leave() }
        let result = lock.withLock { categoryResults.isEmpty ? .success : categoryResults.removeFirst() }
        if result == .failure {
            if let categoryFailure { throw categoryFailure }
            throw Failure.sdk
        }
    }
    func setSupportsMultichannelContent() throws {
        enter(.multichannel)
        defer { leave() }
        if multichannelFails { throw Failure.sdk }
    }
    func activate() throws {
        enter(.activate)
        defer { leave() }
        let failed = lock.withLock {
            guard activationFailures > 0 else { return false }
            activationFailures -= 1
            return true
        }
        if failed { throw Failure.sdk }
    }
    func deactivate() throws { enter(.deactivate); leave() }
    func currentRoute() -> any AudioSessionRouteSnapshot {
        enter(.route)
        defer { leave() }
        return route
    }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        lock.withLock { randomInvocations += 1 }
        guard !randomFails else { return false }
        guard let base = bytes.baseAddress else { return false }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, base) == errSecSuccess
    }

    private func enter(_ event: Event) {
        lock.withLock {
            recorded.append(event)
            mainThread = mainThread || Thread.isMainThread
            controlExecutor = controlExecutor || executor?.isIsolated == true
            concurrent += 1
            maximum = max(maximum, concurrent)
        }
        // 只模拟底层framework在SDK调用线程同步回调；事件仍走真实Cell/资源入口。
        let reentry = lock.withLock { () -> (ReentrantAction, ControlTaskRegistry, UInt64, UInt64)? in
            guard event == reentrantStage, let action = reentrantAction, let registry = reentrantRegistry else { return nil }
            reentrantAction = nil
            return (action, registry, reentrantContextNonce, reentrantInstant)
        }
        if let (action, registry, contextNonce, instant) = reentry {
            let completed: Bool
            switch action {
            case .began:
                registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
                completed = true
            case .reset:
                registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
                completed = true
            case .stop:
                completed = (try? registry.beginOutputTransition(contextNonce: contextNonce, reason: .stop,
                    anchorInstant: instant, teardown: true)) != nil
            }
            lock.withLock { reentrantCompleted = completed }
        }
        if lock.withLock({ event == blockedEvent }) {
            enteredBlocked.signal()
            unblock.wait()
        }
    }
    private func leave() { lock.withLock { concurrent -= 1 } }
}

final class EmptySDKRouteSnapshot: AudioSessionRouteSnapshot, Sendable {
    var endpointCount: Int { 0 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint { preconditionFailure("空SDK路由没有端点") }
}

final class BuiltInSDKRouteSnapshot: AudioSessionRouteSnapshot, Sendable {
    var endpointCount: Int { 1 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint {
        .init(uid: "sdk-speaker", portType: AVAudioSession.Port.builtInSpeaker.rawValue as NSString, dataSource: .missing)
    }
}
