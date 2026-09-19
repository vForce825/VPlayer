// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import XCTest
@testable import VPlayerPlayback

@MainActor
final class AllocationReleaseTests: XCTestCase {
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
        var driver: SystemAVPlayerDriver? = try .make(player: AVPlayer())
        var coordinator: AVPlayerItemCoordinator? = try .init(
            driver: try XCTUnwrap(driver), evidenceSource: try XCTUnwrap(fixture).source,
            allocator: allocator)
        try coordinator?.install(try XCTUnwrap(fixture).request)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 22 * 1_024,
                       "driver/coordinator加安装时真实access-log SDK lease")

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
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 24 * 1_024)
        driver?.eventHub.receive(try XCTUnwrap(fixture).request.itemURL,
                                 item: try XCTUnwrap(fixture).request.item)
        let installedItem = try XCTUnwrap(fixture).request.item
        coordinator = nil
        driver?.replaceCurrentItemWithNil(item: installedItem)
        driver?.removeObservers(item: installedItem)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 22 * 1_024,
                       "SDK lease与已排队hub同时保留原12KiB安装票")
        sdkTail = nil
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 20 * 1_024,
                       "SDK尾释放后仍由原queued delivery保留安装票")
        let deliveryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while PlaybackResourceContextLedger.shared.chargedBytes
                != resourceBaseline + 8 * 1_024,
              ContinuousClock.now < deliveryDeadline {
            await Task.yield()
        }
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 8 * 1_024,
                       "有界让出MainActor等待原queued delivery退出后只剩driver core")
        driver = nil
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline)

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
