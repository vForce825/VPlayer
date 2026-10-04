// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import XCTest
@testable import VPlayerPlayback

@MainActor
final class AllocationReleaseTests: XCTestCase {
    func testReleaseAACCorrelationRetainsOneUnitWinnerAndRejectsTie() throws {
        var source = [Float](repeating: 1, count: 2_048)
        source[0] = Float(1) / 32_767
        var decoded = [Float](repeating: 1, count: 2_049)
        decoded[0] = Float(32_766) / 32_767
        XCTAssertEqual(try AACPrimingCalibrator.leadingOffset(
            source: source, decoded: decoded, channels: 1, maximumOffset: 1), 1)
        decoded[0] = 1
        XCTAssertThrowsError(try AACPrimingCalibrator.leadingOffset(
            source: source, decoded: decoded, channels: 1, maximumOffset: 1)) {
            XCTAssertEqual($0 as? AACRenditionFailure, .calibrationMismatch)
        }
    }

    func testReleaseAACCorrelationOnlyRecordsPairedFullSearchTimings() throws {
        var state: UInt32 = 0x71a2b3c4
        let source: [Float] = (0..<16_384).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state) >> 17) / 32_768
        }
        let decoded = [Float](repeating: 0, count: 8_192) + source
        let clock = ContinuousClock()
        // Fixed paired samples, without XCTest performance baselines or variance
        // gates. These are correlation-only timings on the executing simulator
        // or device, not measurements of encoder/writer/decoder or startup time.
        for iteration in 0..<3 {
            let scalarStart = clock.now
            let expected = Self.scalarAACLeadingOffset(source: source, decoded: decoded)
            let scalarDuration = scalarStart.duration(to: clock.now)
            let vectorStart = clock.now
            let actual = try AACPrimingCalibrator.leadingOffset(
                source: source, decoded: decoded, channels: 1, maximumOffset: 8_192)
            let vectorDuration = vectorStart.duration(to: clock.now)
            XCTAssertEqual(expected, 8_192)
            XCTAssertEqual(actual, expected)
            print("AAC_CORRELATION_ONLY iteration=\(iteration) scalar=\(scalarDuration) vector=\(vectorDuration)")
        }
    }

    @inline(never)
    private static func scalarAACLeadingOffset(source: [Float], decoded: [Float]) -> Int? {
        // The old Int64 kernel, including validation and quantization, for this
        // fixed full-width mono fixture. Never used by production calibration.
        guard source.count == 16_384, decoded.count <= 32_768,
              source.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              decoded.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { return nil }
        let start = 1_024, width = 2_048
        let upper = min(8_192, decoded.count - start - width)
        guard upper >= 0 else { return nil }
        let a = (0..<width).map { Int64((Double(source[start + $0]) * 32_767).rounded()) }
        let b = decoded.map { Int64((Double($0) * 32_767).rounded()) }
        var best = Int64.min, second = Int64.min, offset = 0
        for candidate in 0...upper {
            var sum: Int64 = 0
            for index in 0..<width { sum += a[index] * b[start + candidate + index] }
            if sum > best { second = best; best = sum; offset = candidate } else { second = max(second, sum) }
        }
        return best > 0 && best > second ? offset : nil
    }

    func testReleaseAACPublicationUsesEffectivePrimingBoundary() async throws {
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: .init())
        let fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle)
        defer { try? fixture.teardown() }
        let seed = fixture.publication.seed
        let first = try XCTUnwrap(seed.packets.first)
        let boundary = try XCTUnwrap(first.object.publicationEvidence?.boundary)
        let mapping = try XCTUnwrap(
            fixture.endpointAuthority.terminalBinding.timelineMappingReceipt)
        let endpoint = fixture.endpointAuthority.receipt

        XCTAssertGreaterThan(endpoint.leadingFrames, 0,
            "The real AAC fixture must exercise the physical/effective origin difference")
        XCTAssertEqual(first.receipt.presentationRange.start, mapping.writtenPhysicalBase)
        XCTAssertEqual(boundary.epochStart, mapping.writtenEffectiveBase)
        XCTAssertEqual(boundary.commonStart, mapping.writtenEffectiveBase)
        XCTAssertEqual(try mapping.writtenEffectiveBase.subtracting(mapping.writtenPhysicalBase),
            ExactMediaTime(value: endpoint.leadingFrames, timescale: endpoint.sampleRate))
        XCTAssertEqual(seed.packets.last?.receipt.logicalSequence, endpoint.terminalLogicalSequence,
            "Correcting the origin must retain the real terminal tail")
        XCTAssertTrue(try XCTUnwrap(fixture.publication.publisher.visible)
            .media.values.allSatisfy { $0.text.hasSuffix("#EXT-X-ENDLIST\n") })
        try fixture.teardown()
    }

    func testOriginalBackingsLongestURLAndApplicationAliasTails() async throws {
        struct Observation {
            let role: String
            let status: UInt32
            let allocation: UInt
            let bytes: Int
            let borrowedAddress: UInt
            let borrowedBytes: Int
        }
        var observations: [Observation] = []
        func record(_ role: String, _ range: VPMallocAllocationRange,
                    _ borrowedAddress: UInt, _ borrowedBytes: Int) {
            observations.append(.init(
                role: role, status: range.status,
                allocation: range.allocation, bytes: range.bytes,
                borrowedAddress: borrowedAddress, borrowedBytes: borrowedBytes))
        }

        let allocator = PlaybackIdentityAllocator()
        let registry = ControlTaskRegistry(allocator: allocator)
        registry.inspectOriginalControlBackingAllocations(record)
        allocator.inspectOriginalIssuedBackingAllocation(record)
        XCTAssertEqual(Set(observations.map(\.role)), [
            "owned/registry commands backing",
            "owned/registry groups backing",
            "owned/identity allocator issued backing",
        ])
        for observation in observations {
            XCTAssertEqual(observation.status, 0, observation.role)
            XCTAssertGreaterThan(observation.allocation, 0, observation.role)
            XCTAssertGreaterThanOrEqual(observation.bytes, observation.borrowedBytes,
                                        observation.role)
            XCTAssertGreaterThanOrEqual(observation.borrowedAddress,
                                        observation.allocation, observation.role)
            XCTAssertLessThanOrEqual(
                observation.borrowedAddress + UInt(observation.borrowedBytes),
                observation.allocation + UInt(observation.bytes), observation.role)
        }

        let maximumRenditionID = String(repeating: "a", count: 128)
        let maximumDeclaration = try ReleaseFixtureValues.declaration(
            itemGeneration: .max, renditionID: maximumRenditionID)
        try HLSPlaylistSerializer.validate(maximumDeclaration)
        let maximumPath = try maximumDeclaration.playlistURI(participantID: 2)
        let maximumBuilderURL = try XCTUnwrap(URL(
            string: maximumPath,
            relativeTo: try XCTUnwrap(URL(string: "http://127.0.0.1:65535")))?.absoluteURL)
        XCTAssertEqual(maximumBuilderURL.absoluteString.utf8.count, 225)

        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        var fixture: ReleaseAACPublicationFixture? = try await .make(
            lifecycle: lifecycle, itemGeneration: .max,
            renditionID: maximumRenditionID)
        defer { try? fixture?.teardown() }
        let actualURLBytes = try XCTUnwrap(fixture).request.itemURL.absoluteString.utf8.count
        let actualPortDigits = String(try XCTUnwrap(fixture).server.port).utf8.count
        XCTAssertEqual(actualURLBytes, 220 + actualPortDigits)
        XCTAssertTrue((1...5).contains(actualPortDigits))

        let resourceBaseline = PlaybackResourceContextLedger.shared.chargedBytes
        let driverCoreBytes = 12 * 1_024
        let installationBytes = 12 * 1_024
        let observerLeaseBytes = 2 * 1_024
        let readyLeaseBytes = 2 * 1_024
        var driver: SystemAVPlayerDriver? = try .make(player: AVPlayer())
        var coordinator: AVPlayerItemCoordinator? = try .init(
            driver: try XCTUnwrap(driver), evidenceSource: try XCTUnwrap(fixture).source,
            allocator: allocator)
        func assertResourceDelta(_ expectedDelta: Int, phase: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
            let actual = PlaybackResourceContextLedger.shared.chargedBytes
            if actual != resourceBaseline + expectedDelta {
                print("TASK21_RELEASE_RESOURCE phase=\(phase) baseline=\(resourceBaseline) "
                    + "actual=\(actual) expectedDelta=\(expectedDelta) "
                    + "driverCore=\(driverCoreBytes) installation=\(installationBytes) "
                    + "observerLease=\(observerLeaseBytes) readyLease=\(readyLeaseBytes) "
                    + "soft=\(PlaybackResourceContextLedger.softBytes) "
                    + "hard=\(PlaybackResourceContextLedger.hardBytes)")
            }
            XCTAssertEqual(actual, resourceBaseline + expectedDelta, phase,
                           file: file, line: line)
        }
        try coordinator?.install(try XCTUnwrap(fixture).request)
        // There is no await from installation through observer removal. The log
        // cache wake is queued on MainActor; its separate 4 KiB physical-reader
        // lease cannot start until this synchronous phase yields below.
        assertResourceDelta(driverCoreBytes + installationBytes + 2 * observerLeaseBytes,
                            phase: "installed_with_access_and_error_observers")

        weak var retainedURLOwner: NSURL?
        var urlAllocationIdentities = Set<UInt>()
        var firstBridgeIdentity: ObjectIdentifier?
        var secondBridgeIdentity: ObjectIdentifier?
        autoreleasepool {
            coordinator?.inspectRetainedPreparationURLAllocations {
                role, owner, range, borrowedAddress, borrowedBytes in
                if role == "resource-context/installed NSURL" {
                    retainedURLOwner = owner as? NSURL
                    firstBridgeIdentity = ObjectIdentifier(owner)
                }
                record(role, range, borrowedAddress, borrowedBytes)
                if range.status == 0 { urlAllocationIdentities.insert(range.allocation) }
            }
            coordinator?.inspectRetainedPreparationURLAllocations {
                role, owner, _, _, _ in
                if role == "resource-context/installed NSURL" {
                    secondBridgeIdentity = ObjectIdentifier(owner)
                }
            }
        }
        let urlObservations = observations.filter {
            $0.role.hasPrefix("resource-context/installed URL")
                || $0.role == "resource-context/installed NSURL"
        }
        XCTAssertFalse(urlObservations.isEmpty)
        XCTAssertTrue(urlObservations.allSatisfy { $0.status == 0 })
        XCTAssertNotNil(retainedURLOwner,
                        "探针autoreleasepool退出后必须仍由真实安装图持有")
        XCTAssertEqual(firstBridgeIdentity, secondBridgeIdentity,
                       "同一request连续桥接必须借到稳定Foundation owner；否则保持unknown")
        XCTAssertFalse(urlAllocationIdentities.isEmpty)

        var sdkTail: AVPlayerSDKCallbackLease? = try driver?.reserveSDKCallbackLease(.ready)
        assertResourceDelta(driverCoreBytes + installationBytes
                            + 2 * observerLeaseBytes + readyLeaseBytes,
                            phase: "ready_alias_retained")
        driver?.eventHub.receive(try XCTUnwrap(fixture).request.itemURL,
                                 item: try XCTUnwrap(fixture).request.item)
        let installedItem = try XCTUnwrap(fixture).request.item
        coordinator = nil
        driver?.replaceCurrentItemWithNil(item: installedItem)
        driver?.removeObservers(item: installedItem)
        assertResourceDelta(driverCoreBytes + installationBytes + readyLeaseBytes,
                            phase: "observers_removed_ready_and_queued_hub_retain_installation")
        sdkTail = nil
        assertResourceDelta(driverCoreBytes + installationBytes,
                            phase: "ready_alias_released_queued_hub_retains_installation")
        let deliveryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while PlaybackResourceContextLedger.shared.chargedBytes
                != resourceBaseline + driverCoreBytes,
              ContinuousClock.now < deliveryDeadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        // Exact equality also excludes a retained 4 KiB async log-reader lease;
        // cancellation alone cannot count as completion of that physical work.
        assertResourceDelta(driverCoreBytes, phase: "queued_and_native_tails_settled")
        driver = nil
        assertResourceDelta(0, phase: "driver_released")

        try fixture?.teardown()
        fixture = nil
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while retainedURLOwner != nil, ContinuousClock.now < releaseDeadline {
            await Task.yield()
        }
        let postReleaseFoundationURLOwnerAlive = retainedURLOwner != nil

        let measured = observations.map {
            "\($0.role): status=\($0.status), allocation=\($0.allocation), "
                + "bytes=\($0.bytes), borrowed=\($0.borrowedAddress)+\($0.borrowedBytes)"
        }.joined(separator: "\n")
        let text = "maxBuilderURLBytes=225\nactualBoundURLBytes=\(actualURLBytes)\n"
            + "actualBoundPortDigits=\(actualPortDigits)\n"
            + "resourceEscrowHard=\(PlaybackResourceContextLedger.hardBytes)\n"
            + "postReleaseFoundationURLOwnerAliveAfter2s="
            + "\(postReleaseFoundationURLOwnerAlive)\n"
            + measured + "\n"
            + "应用安装票最后alias已回到账本baseline；Foundation URL owner尾因"
            + "autorelease/SDK缓存归属不可判定保持unknown，不记0；"
            + "应用原capture/Block/async slab沿用已冻结Debug原分配证据；"
            + "Release Swift runtime frame、SDK opaque、物理栈与RSS保持unknown，不记0"
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        withExtendedLifetime(sdkTail) {}
    }

    func testFixtureTeardownReportsFailureAndDoesNotRepeat() async throws {
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        let fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle)
        let ticket = fixture.server.closeAdmission()
        XCTAssertTrue(releaseWaitUntil(timeout: 2) {
            fixture.server.usage.connections == 0
                && fixture.server.usage.activeResponses == 0
        })
        try fixture.server.drain(cleanupTicket: ticket)

        for _ in 0..<2 {
            XCTAssertThrowsError(try fixture.teardown()) { error in
                XCTAssertEqual(error as? ReleaseFixtureTeardownError, .drainFailed)
            }
        }
        XCTAssertEqual(fixture.teardownAttemptCount, 1)
    }

    func testReleaseObjectsAndApprovedBudgetBoundaries() async throws {
        XCTAssertEqual(PlaybackResourceContextLedger.softBytes, 96 * 1_024)
        XCTAssertEqual(PlaybackResourceContextLedger.hardBytes, 128 * 1_024)
        XCTAssertEqual(HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes,
                       981_184_512)
        XCTAssertEqual(HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
                       1_266_647_040)
        XCTAssertEqual(AVPlayerRetainedGraphCapacityLedger.maximumBytes, 2 * 1_024)
        XCTAssertLessThanOrEqual(
            ControlTaskRegistry.ownedControlAllocationReservation.total, 64 * 1_024)
        XCTAssertEqual(
            ControlTaskRegistry.ownedControlAllocationReservation.fixedErrorReservation,
            5_440)
        XCTAssertEqual(
            AVPlayerItemCoordinator.retainedGraphFutureReservationSnapshot
                .installedMaximumBranchBytes,
            160)

        let allocator = PlaybackIdentityAllocator()
        let registry = ControlTaskRegistry(allocator: allocator)
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        let fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle)
        defer { try? fixture.teardown() }
        let packet = try XCTUnwrap(fixture.publication.seed.packets.first)

        var identities = Set<ObjectIdentifier>()
        func measure(_ label: String, _ object: AnyObject) -> String {
            let identity = ObjectIdentifier(object)
            let isFirst = identities.insert(identity).inserted
            return "\(label)Identity=\(identity), \(label)Malloc="
                + "\(malloc_size(Unmanaged.passUnretained(object).toOpaque())), "
                + "\(label)FirstIdentity=\(isFirst)"
        }

        let text = [
            measure("allocator", allocator),
            measure("registry", registry),
            measure("executor", registry.executor),
            measure("progressSignal", registry.progressSignal),
            measure("store", fixture.publication.store),
            measure("publisher", fixture.publication.publisher),
            measure("relay", fixture.publication.seed.relay),
            measure("endpoint", fixture.endpointAuthority),
            measure("sealedBacking", packet.object.backing),
            measure("segmentReport", packet.object.report),
            "sealedLogicalBytes=\(packet.object.bytes.count)",
            "说明=malloc_size仅为上述真实对象或backing allocation；Data私有尾、完整可达图、栈、SDK私有内存和RSS均未由此证明",
        ].joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        try fixture.teardown()
    }
}
