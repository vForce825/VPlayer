// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSResourceStoreTests: XCTestCase {
    func testReviewI3OneShotWaiterPublishesOnlyAfterEverySnapshotLeaseTerminal() async throws {
        let h = try await Task19Harness(audioCount: 3)
        try await h.initial()
        let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
        let duplicate = try XCTUnwrap(h.store.acquireSnapshot(participantID: 1, now: 0))
        try await h.offerBoth(count: 1)
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        try await h.offerBoth(count: 1, now: Task19.second)
        let ticket = h.publisher.ticket
        let serializations = h.publisher.serializationCount
        XCTAssertEqual(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second), .waiting)
        XCTAssertEqual(h.store.capacityWaiterCount, 1)
        for lease in old {
            h.store.release(lease, completedAt: nil, now: 2 * Task19.second)
            XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
            XCTAssertEqual(h.publisher.serializationCount, serializations)
        }
        h.store.release(duplicate, completedAt: nil, now: 2 * Task19.second)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3, "最后 terminal 必须真实一次性唤醒，不准外部重试 publish")
        XCTAssertEqual(h.publisher.serializationCount, serializations + 4)
        XCTAssertEqual(h.store.capacityWaiterCount, 0)
        h.store.release(duplicate, completedAt: nil, now: 2 * Task19.second)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3)
        XCTAssertThrowsError(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second))
    }

    func testReviewI3StaleCancelCloseDeadlineAndReconfigureOnlyDiscardWaiter() async throws {
        for terminal in 0..<5 {
            let h = try await Task19Harness(audioCount: 3)
            try await h.initial()
            let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
            try await h.offerBoth(count: 1)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
            try await h.offerBoth(count: 1, now: Task19.second)
            let ticket = h.publisher.ticket
            XCTAssertEqual(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second), .waiting)
            switch terminal {
            case 0: h.publisher.cancelCapacityWait(ticket: ticket)
            case 1: h.publisher.close()
            case 2: XCTAssertThrowsError(try h.publisher.deadline(ticket: ticket, now: 4 * Task19.second))
            case 3: _ = try h.publisher.reconfigure(retiring: [4], ticket: ticket)
            default: break
            }
            let instant = terminal == 4 ? 4 * Task19.second + 1 : 2 * Task19.second
            for lease in old { h.store.release(lease, completedAt: nil, now: instant) }
            XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
            XCTAssertEqual(h.store.capacityWaiterCount, 0)
            XCTAssertEqual(h.store.usage.reservedSnapshotCount, 0)
        }
    }

    func testReviewI7MasterAndMediaBorrowRaceReleaseCloseAndDoubleTerminalAreSafe() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let master = try XCTUnwrap(h.store.acquireMasterSnapshot(now: 0))
        let media = try XCTUnwrap(h.store.acquireSnapshot(participantID: 1, now: 0))
        XCTAssertEqual(master.withSnapshot { $0.raw }, h.publisher.visible?.master?.raw)
        h.publisher.close()
        XCTAssertNil(try h.store.acquireMasterSnapshot(now: 0))
        XCTAssertGreaterThan(h.store.usage.snapshotBytes, 0)
        for lease in [master, media] {
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                if index % 2 == 0 { _ = lease.withSnapshot { $0.raw.count + $0.gzip.count } }
                else { h.store.release(lease, completedAt: nil, now: 0) }
            }
            XCTAssertNil(lease.withSnapshot { $0.identity })
            h.store.release(lease, completedAt: nil, now: 0)
        }
        XCTAssertEqual(h.store.usage.snapshotCount, 0)
        XCTAssertEqual(h.store.usage.snapshotBytes, 0)
    }

    func testReviewI9PublishedURIIdentitiesRemainGoneBeyond192WithFixedState() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let old = h.publisher.visible!.media[1]!.resources[0]
        let uri = try h.store.resourceURI(old, declaration: Task19.declaration())
        for index in 1...112 {
            if index == 40 || index == 80 { try await h.beginEpoch(UInt64(index)) }
            try await h.offerBoth(count: 1, now: Int64(index - 1) * Task19.second)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Int64(index) * Task19.second)
            h.store.sweep(now: Int64(index) * Task19.second)
            XCTAssertLessThanOrEqual(h.store.usage.tombstoneCount, 192)
        }
        XCTAssertEqual(h.store.lookupURI(uri, now: 112 * Task19.second), .gone)
        XCTAssertEqual(h.store.lookup(old, token: Task19.token, now: 112 * Task19.second), .gone)
        for forged in [uri.replacingOccurrences(of: "/19/", with: "/20/"),
                       uri.replacingOccurrences(of: "/1/video/", with: "/999/video/"),
                       uri.replacingOccurrences(of: Task19.token, with: String(repeating: "f", count: 32)),
                       uri.replacingOccurrences(of: "/0.m4s", with: "/999999.m4s")] {
            XCTAssertNotEqual(forged, uri)
            XCTAssertEqual(h.store.lookupURI(forged, now: 112 * Task19.second), .notFound)
        }
        h.publisher.close()
        XCTAssertEqual(h.store.lookupURI(uri, now: 200 * Task19.second), .gone)
        XCTAssertLessThanOrEqual(h.store.usage.tombstoneCount, 192)
    }

    func testRenditionSoftHardCapBoundariesReserveBeforeBackingAllocation() throws {
        for count in [41, 42, 43, 47, 48, 49] {
            let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
            var reservations: [SealedMediaReservation] = []
            for index in 0..<count {
                if index == 48 {
                    XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: 1))
                } else {
                    reservations.append(try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: 1))
                }
            }
            XCTAssertEqual(store.usage.reservedSegmentCount, min(count, 48))
            XCTAssertEqual(store.usage.shouldBackpressure, count >= 42)
            XCTAssertEqual(store.usage.residentBytes, 0)
            XCTAssertEqual(store.usage.resourceCount, 0)
            for reservation in reservations { store.cancel(reservation) }
            XCTAssertEqual(store.usage.reservedBytes, 0)
        }
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        for participant in 1...4 {
            _ = try store.reserveMedia(binding: Task19.binding(id: UInt64(participant)), kind: .media, bodyBytes: 0)
        }
        XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(id: 5), kind: .media, bodyBytes: 0),
                             "零 bytes 不能绕过固定 participant 上限")
    }

    func testGlobal560688MiBAndInitialization64KiBBoundariesAreAtomic() throws {
        // The application budget includes the media reservation's bounded paid map
        // evidence precharge, not just its payload. Keep the exact total-byte edges.
        let mediaEvidenceBytes = LoopbackStorageLayout.current.mediaMapReservationBytes
        XCTAssertFalse(HLSDeliveryApplicationChargeLedger.shared.shouldBackpressure,
            "Global application backpressure must be inactive for this store-local threshold check")
        for totalBytes in [560 * 1024 * 1024 - 1, 560 * 1024 * 1024, 560 * 1024 * 1024 + 1,
                           688 * 1024 * 1024 - 1, 688 * 1024 * 1024, 688 * 1024 * 1024 + 1] {
            let bytes = totalBytes - mediaEvidenceBytes
            let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
            if totalBytes > 688 * 1024 * 1024 {
                XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: bytes))
                XCTAssertEqual(store.usage.reservedBytes, 0)
            } else {
                let reservation = try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: bytes)
                XCTAssertEqual(store.usage.reservedBytes, bytes)
                XCTAssertEqual(store.usage.shouldBackpressure, totalBytes >= 560 * 1024 * 1024)
                store.cancel(reservation)
            }
            XCTAssertEqual(store.usage.resourceCount, 0)
            XCTAssertEqual(store.usage.residentBytes, 0)
        }
        let initializationEvidenceBytes = 16 * 1_024
        XCTAssertEqual(LoopbackStorageLayout.current.initEvidenceAllocationBytes,
                       initializationEvidenceBytes)
        XCTAssertEqual(LoopbackStorageLayout.current.initMaximumBodyBytes
                       + initializationEvidenceBytes, 64 * 1_024)
        for totalBytes in [65_535, 65_536, 65_537] {
            let bytes = totalBytes - initializationEvidenceBytes
            let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
            if totalBytes == 65_537 {
                XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .initialization, bodyBytes: bytes))
            } else {
                let reservation = try store.reserveMedia(binding: Task19.binding(), kind: .initialization, bodyBytes: bytes)
                store.cancel(reservation)
                store.cancel(reservation)
            }
            XCTAssertEqual(store.usage.reservedBytes, 0)
        }
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .media,
            bodyBytes: 688 * 1_024 * 1_024),
            "Payload alone at the hard limit must still charge its evidence and reject atomically")
        XCTAssertEqual(store.usage.reservedBytes, 0)
        XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .initialization,
            bodyBytes: 64 * 1_024), "The64KiB initialization cap includes its16KiB evidence")
        XCTAssertEqual(store.usage.reservedBytes, 0)
        XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: .max))
        XCTAssertThrowsError(try store.reserveMedia(binding: Task19.binding(), kind: .media, bodyBytes: -1))
    }

    func testStoreAdmissionRechecksProofReceiptBackingAndTransfersOnlyOnSuccess() async throws {
        let track = try await Task19Track(id: 1, mediaType: .video)
        let packet = try await track.next()
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        let reservation = try store.reserveMedia(binding: track.binding, kind: .media, bodyBytes: packet.object.bytes.count)
        XCTAssertThrowsError(try store.admit(Task19.copy(packet.object), proof: track.proof,
            receipt: packet.receipt, relay: track.relay, reservation: reservation))
        XCTAssertEqual(track.relay.usage.unpublishedLogicalSegmentCount, 1)
        XCTAssertEqual(store.usage.resourceCount, 0)
        XCTAssertEqual(store.usage.reservedBytes, packet.object.bytes.count)
        let key = try store.admit(packet.object, proof: track.proof, receipt: packet.receipt,
            relay: track.relay, reservation: reservation)
        XCTAssertEqual(store.usage.residentBytes, packet.object.bytes.count)
        XCTAssertEqual(store.usage.reservedBytes, 0)
        XCTAssertEqual(track.relay.usage.unpublishedLogicalSegmentCount, 0)
        XCTAssertEqual(store.lookup(key, token: Task19.token, now: 0), .notFound)
        XCTAssertThrowsError(try store.admit(packet.object, proof: track.proof, receipt: packet.receipt,
            relay: track.relay, reservation: reservation))
        XCTAssertEqual(store.usage.resourceCount, 1)
    }

    func testFullBackingOneByteViewsAndDistinctIdenticalContentsAreChargedOncePerBacking() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let key = h.publisher.visible!.media[1]!.resources[0]
        let first = try XCTUnwrap(h.store.acquireResponse(key, token: Task19.token, now: 0, range: 0..<1))
        let second = try XCTUnwrap(h.store.acquireResponse(key, token: Task19.token, now: 0, range: 1..<2))
        XCTAssertEqual(first.backingIdentity, second.backingIdentity)
        XCTAssertEqual(first.byteCount, 1)
        XCTAssertEqual(h.store.usage.distinctResponseBackings, 1)
        XCTAssertEqual(h.store.usage.responseBackingBytes, h.tracks[1]!.lastMediaByteCount)
        XCTAssertGreaterThan(first.residentByteCount, first.byteCount)
        first.withUnsafeBytes { slice in
            second.withUnsafeBytes { other in
                XCTAssertEqual(Int(bitPattern: other.baseAddress!) - Int(bitPattern: slice.baseAddress!), 1)
            }
        }
        h.store.release(first, now: 0)
        h.store.release(first, now: 0)
        XCTAssertEqual(h.store.usage.distinctResponseBackings, 1)
        h.store.release(second, now: 0)
        XCTAssertEqual(h.store.usage.responseBackingBytes, 0)
        let a = try await Task19Track(id: 1, mediaType: .video)
        let b = try await Task19Track(id: 2, mediaType: .video)
        let pa = try await a.next(), pb = try await b.next()
        XCTAssertEqual(pa.object.bytes, pb.object.bytes)
        XCTAssertNotEqual(pa.object.backing.identity, pb.object.backing.identity)
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        for (track, packet) in [(a, pa), (b, pb)] {
            let reservation = try store.reserveMedia(binding: track.binding, kind: .media, bodyBytes: packet.object.bytes.count)
            _ = try store.admit(packet.object, proof: track.proof, receipt: packet.receipt, relay: track.relay, reservation: reservation)
        }
        XCTAssertEqual(store.usage.residentBytes, pa.object.bytes.count + pb.object.bytes.count)
    }

    func testAvailabilityHorizonBeforeAtAfterAndForgedIdentities() async throws {
        for instant: Int64 in [7_999_999_999, 8_000_000_000, 8_000_000_001] {
            let h = try await Task19Harness()
            try await h.initial()
            let key = h.publisher.visible!.media[1]!.resources[0]
            try await h.offerBoth(count: 1)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
            XCTAssertEqual(h.store.lookup(key, token: Task19.token, now: instant), instant < 8_000_000_000 ? .available : .gone)
            var forged = key
            forged.itemGeneration = 20
            XCTAssertEqual(h.store.lookup(forged, token: Task19.token, now: instant), .notFound)
            forged = key
            forged.mediaEpoch = 999
            XCTAssertEqual(h.store.lookup(forged, token: Task19.token, now: instant), .notFound)
            XCTAssertEqual(h.store.lookup(key, token: String(repeating: "f", count: 32), now: instant), .notFound)
        }
    }

    func testResponseAcquiredBeforeHorizonSurvivesAndNewAcquireIsGone() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let key = h.publisher.visible!.media[1]!.resources[0]
        try await h.offerBoth(count: 1)
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        let lease = try XCTUnwrap(h.store.acquireResponse(key, token: Task19.token, now: 7_999_999_999, range: 0..<1))
        h.store.sweep(now: 8_000_000_000)
        XCTAssertNil(try h.store.acquireResponse(key, token: Task19.token, now: 8_000_000_000))
        XCTAssertEqual(h.store.usage.responseTailCount, 1)
        XCTAssertEqual(lease.withUnsafeBytes { $0.count }, 1)
        h.store.release(lease, now: 8_000_000_001)
        XCTAssertEqual(h.store.usage.responseTailCount, 0)
        XCTAssertEqual(h.store.lookup(key, token: Task19.token, now: 8_000_000_001), .gone)
        let epoch = try await Task19Harness()
        try await epoch.initial()
        let oldInit = epoch.publisher.visible!.media[1]!.initializationResources[0]
        try await epoch.beginEpoch(2)
        for index in 1...6 {
            try await epoch.offerBoth(count: 1, now: Int64(index - 1) * Task19.second)
            _ = try epoch.publisher.publish(ticket: epoch.publisher.ticket, now: Int64(index) * Task19.second)
        }
        let initLease = try XCTUnwrap(epoch.store.acquireResponse(oldInit, token: Task19.token, now: 13 * Task19.second - 1))
        epoch.store.sweep(now: 13 * Task19.second)
        XCTAssertNil(try epoch.store.acquireResponse(oldInit, token: Task19.token, now: 13 * Task19.second),
                     "旧 init 的最后 media 已过 horizon，旧 response 不能授权新 acquire")
        XCTAssertGreaterThan(initLease.withUnsafeBytes { $0.count }, 0)
        epoch.store.release(initLease, now: 13 * Task19.second)
    }

    func testVisibleUnpublishedHorizonSnapshotAndResponseProtections() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let snapshot = try XCTUnwrap(h.store.acquireSnapshot(participantID: 1, now: 0))
        let key = try XCTUnwrap(snapshot.snapshot).resources[0]
        try await h.offerBoth(count: 1)
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        h.store.sweep(now: 8 * Task19.second)
        XCTAssertEqual(h.store.lookup(key, token: Task19.token, now: 8 * Task19.second), .available)
        h.store.release(snapshot, completedAt: 2 * Task19.second, now: 8 * Task19.second)
        XCTAssertEqual(h.store.lookup(key, token: Task19.token, now: 9 * Task19.second - 1), .available)
        XCTAssertEqual(h.store.lookup(key, token: Task19.token, now: 9 * Task19.second), .gone)
        let visibleKey = h.publisher.visible!.media[1]!.resources.last!
        h.store.sweep(now: 100 * Task19.second)
        XCTAssertEqual(h.store.lookup(visibleKey, token: Task19.token, now: 100 * Task19.second), .available)
        let before = h.store.usage.resourceCount
        try await h.offerBoth(count: 1, now: 100 * Task19.second)
        h.store.sweep(now: 200 * Task19.second)
        XCTAssertEqual(h.store.usage.resourceCount, before + 2)
    }

    func testDistinctResponseTailSixEightLimitsAndSameBackingDoesNotMultiply() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        var leases: [HLSMediaResponseLease] = []
        for index in 0..<8 {
            let participant: UInt64 = index % 2 == 0 ? 1 : 2
            let key = h.publisher.visible!.media[participant]!.resources[index / 2]
            leases.append(try XCTUnwrap(h.store.acquireResponse(key, token: Task19.token, now: 0, range: 0..<1)))
            XCTAssertEqual(h.store.usage.shouldBackpressureResponses, index >= 5)
        }
        let ninth = h.publisher.visible!.media[1]!.resources[4]
        XCTAssertThrowsError(try h.store.acquireResponse(ninth, token: Task19.token, now: 0))
        let same = try XCTUnwrap(h.store.acquireResponse(h.publisher.visible!.media[1]!.resources[0], token: Task19.token, now: 0))
        XCTAssertEqual(h.store.usage.distinctResponseBackings, 8)
        h.store.release(same, now: 0)
        for index in 1...12 {
            try await h.offerBoth(count: 1, now: Int64(index - 1) * Task19.second)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Int64(index) * Task19.second)
        }
        h.store.sweep(now: 20 * Task19.second)
        XCTAssertEqual(h.store.usage.responseTailCount, 8)
        for lease in leases { h.store.release(lease, now: 20 * Task19.second) }
        XCTAssertEqual(h.store.usage.responseTailCount, 0)
    }

    func testAcquireRetireReleaseCloseRacesNeverUnderflowOrResurrect() async throws {
        for _ in 0..<12 {
            let h = try await Task19Harness()
            try await h.initial()
            let key = h.publisher.visible!.media[1]!.resources[0]
            let leases = Task19LeaseBox()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index % 2 == 0 {
                    if let lease = try? h.store.acquireResponse(key, token: Task19.token, now: 0) { leases.append(lease) }
                } else { h.publisher.close() }
            }
            for lease in leases.values { h.store.release(lease, now: 0); h.store.release(lease, now: 0) }
            h.store.close()
            h.store.close()
            XCTAssertNil(try h.store.acquireResponse(key, token: Task19.token, now: 0))
            XCTAssertEqual(h.store.usage.responseBackingBytes, 0)
            XCTAssertEqual(h.store.usage.distinctResponseBackings, 0)
        }
    }

    func testSnapshotNineTenCountAndFiveSixMiBProjectionBoundaries() throws {
        for (count, soft, hard) in [(8, false, false), (9, true, false), (10, true, false), (11, true, true)] {
            let projection = try SnapshotResidencyLedger.project(count: count, bytes: 1)
            XCTAssertEqual(projection.shouldBackpressure, soft)
            XCTAssertEqual(projection.exceedsHardLimit, hard)
        }
        for bytes in [5 * 1024 * 1024 - 1, 5 * 1024 * 1024, 5 * 1024 * 1024 + 1,
                      6 * 1024 * 1024 - 1, 6 * 1024 * 1024, 6 * 1024 * 1024 + 1] {
            let projection = try SnapshotResidencyLedger.project(count: 1, bytes: bytes)
            XCTAssertEqual(projection.shouldBackpressure, bytes >= 5 * 1024 * 1024)
            XCTAssertEqual(projection.exceedsHardLimit, bytes > 6 * 1024 * 1024)
        }
        XCTAssertThrowsError(try SnapshotResidencyLedger.project(count: -1, bytes: 0))
    }

    func testRawGzipRepresentationCapsAtMinusOneEqualPlusOne() throws {
        for kind in [HLSPlaylistKind.media, .master] {
            let rawCap = kind == .media ? 262_144 : 65_536
            let combinedCap = kind == .media ? 532_480 : 135_168
            for raw in [rawCap - 1, rawCap, rawCap + 1] {
                if raw <= rawCap {
                    XCTAssertNoThrow(try HLSPlaylistSerializer.validateRepresentationSizes(kind: kind, raw: raw, gzip: 1))
                } else {
                    XCTAssertThrowsError(try HLSPlaylistSerializer.validateRepresentationSizes(kind: kind, raw: raw, gzip: 1))
                }
            }
            for combined in [combinedCap - 1, combinedCap, combinedCap + 1] {
                if combined <= combinedCap {
                    XCTAssertNoThrow(try HLSPlaylistSerializer.validateRepresentationSizes(kind: kind, raw: rawCap, gzip: combined - rawCap))
                } else {
                    XCTAssertThrowsError(try HLSPlaylistSerializer.validateRepresentationSizes(kind: kind, raw: rawCap, gzip: combined - rawCap))
                }
            }
            let representation = try HLSPlaylistSerializer.representation(raw: Data(repeating: 65, count: rawCap), kind: kind)
            XCTAssertEqual(try Task19.inflate(representation.gzip), representation.raw)
            XCTAssertThrowsError(try HLSPlaylistSerializer.representation(raw: Data(repeating: 65, count: rawCap + 1), kind: kind))
        }
    }

    func testWholeSnapshotBatchWaitsForAllFourOldTerminalReleases() async throws {
        let h = try await Task19Harness(audioCount: 3)
        try await h.initial()
        let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
        try await h.offerBoth(count: 1)
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        XCTAssertEqual(h.store.usage.snapshotCount, 9)
        try await h.offerBoth(count: 1, now: Task19.second)
        let ticket = h.publisher.ticket
        let serialized = h.publisher.serializationCount
        XCTAssertEqual(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second), .waiting)
        for index in 0..<4 {
            XCTAssertEqual(h.publisher.serializationCount, serialized)
            XCTAssertEqual(h.store.usage.reservedSnapshotCount, 0)
            h.store.release(old[index], completedAt: nil, now: 2 * Task19.second)
        }
        XCTAssertEqual(h.publisher.ticket.absoluteDeadline, 5 * Task19.second)
        XCTAssertEqual(h.publisher.serializationCount, serialized + 4)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3)
    }

    func testSnapshotReservationRollbackOnSerializerCASCancelAndDeadline() async throws {
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        for _ in 0..<16 {
            let reservation = try XCTUnwrap(store.reserveSnapshotBatch(mediaCount: 4, includeMaster: true))
            XCTAssertEqual(store.usage.reservedSnapshotCount, 5)
            XCTAssertEqual(store.usage.reservedSnapshotBytes, 2_265_088)
            XCTAssertNil(try store.reserveSnapshotBatch(mediaCount: 1, includeMaster: false))
            XCTAssertThrowsError(try HLSPlaylistSerializer.representation(raw: Data(count: 262_145), kind: .media))
            store.cancel(reservation)
            store.cancel(reservation)
            XCTAssertEqual(store.usage.reservedSnapshotCount, 0)
            XCTAssertEqual(store.usage.reservedSnapshotBytes, 0)
        }
        let h = try await Task19Harness(audioCount: 3)
        try await h.initial()
        let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
        try await h.offerBoth(count: 1)
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        try await h.offerBoth(count: 1, now: Task19.second)
        let ticket = h.publisher.ticket
        XCTAssertEqual(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second), .waiting)
        XCTAssertThrowsError(try h.publisher.deadline(ticket: ticket, now: 4 * Task19.second))
        for lease in old { h.store.release(lease, completedAt: nil, now: 4 * Task19.second) }
        XCTAssertThrowsError(try h.publisher.publish(ticket: ticket, now: 4 * Task19.second))
        XCTAssertEqual(h.store.usage.reservedSnapshotCount, 0)
    }

    func testCapacityDerivationUsesCartesianParticipantExtremaAndNoDuplicateCharges() throws {
        let soft = try HLSCapacityDerivation.calculate(hard: false)
        let hard = try HLSCapacityDerivation.calculate(hard: true)
        XCTAssertEqual(soft.requiredSegmentsPerRendition, 39)
        XCTAssertEqual(hard.requiredSegmentsPerRendition, 45)
        XCTAssertEqual(soft.videoCoverageSeconds, 41)
        XCTAssertEqual(hard.videoCoverageSeconds, 49)
        XCTAssertEqual(soft.participantBitrates, [81_600_000, 6_208_000, 704_000, 264_000])
        XCTAssertEqual(hard.participantBitrates, soft.participantBitrates)
        XCTAssertEqual(soft.initializationBytes, 9 * 1024 * 1024)
        XCTAssertEqual(hard.initializationBytes, 10 * 1024 * 1024)
        XCTAssertEqual(soft.mapEvidenceBytes, 6_881_280)
        XCTAssertEqual(hard.mapEvidenceBytes, 7_864_320)
        XCTAssertEqual(Double(soft.totalBytes) / 1_048_576, 545.607, accuracy: 0.001)
        XCTAssertEqual(Double(hard.totalBytes) / 1_048_576, 664.208, accuracy: 0.001)
        XCTAssertLessThan(soft.totalBytes, 560 * 1024 * 1024)
        XCTAssertLessThan(hard.totalBytes, 688 * 1024 * 1024)
    }
}

private final class Task19LeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HLSMediaResponseLease] = []
    var values: [HLSMediaResponseLease] { lock.withLock { storage } }
    func append(_ value: HLSMediaResponseLease) { lock.withLock { storage.append(value) } }
}

final class PausedWindowCoverageLeaseTests: XCTestCase {
    func testResumeLeaseSharesTheExistingTwoSlotAdmission() throws {
        let baseline = PlaybackResourceContextLedger.shared.chargedBytes
        var original: FrozenPreparationOwner? = try .reserve()
        let originalSlot = try XCTUnwrap(original).slot
        let withOriginal = PlaybackResourceContextLedger.shared.chargedBytes
        var resumed: PausedWindowCoverageLease? = try .reserve()
        XCTAssertNotEqual(try XCTUnwrap(resumed).slot, originalSlot)
        XCTAssertThrowsError(try PausedWindowCoverageLease.reserve()) {
            XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .capacityExceeded)
        }
        XCTAssertThrowsError(try FrozenPreparationOwner.reserve()) {
            XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .capacityExceeded)
        }
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
            withOriginal + PausedWindowCoverageLease.reservationBytes)
        resumed = nil
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, withOriginal)
        XCTAssertEqual(try XCTUnwrap(original).slot, originalSlot)
        original = nil
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline)
    }

    func testResumeLeaseDerivesItsOwnedAllocationCharge() throws {
        let baseline = PlaybackResourceContextLedger.shared.chargedBytes
        try withLease { lease in
            XCTAssertEqual(lease.indexCapacity, 128)
            XCTAssertGreaterThan(lease.knownAllocationBytes, 128 * MemoryLayout<UInt16>.stride)
            XCTAssertLessThanOrEqual(lease.knownAllocationBytes,
                PausedWindowCoverageLease.reservationBytes)
            let actual = try XCTUnwrap(lease.actualAllocationBytes)
            let limits = PausedWindowCoverageLease.allocationLimits
            XCTAssertLessThanOrEqual(actual.root, limits.root)
            XCTAssertLessThanOrEqual(actual.indices, limits.indices)
            XCTAssertLessThanOrEqual(actual.context, limits.context)
            XCTAssertLessThanOrEqual(actual.application, limits.application)
            XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                baseline + PausedWindowCoverageLease.reservationBytes)
            XCTAssertNil(lease.metadataStore)
            XCTAssertFalse(lease.completionIsFrozen)
            XCTAssertNil(lease.coverage(at: 0))
            XCTAssertNil(lease.coverage(at: 1))
            print("PAUSED_WINDOW_ALLOCATION actual=\(lease.knownAllocationBytes) "
                + "reserved=\(PausedWindowCoverageLease.reservationBytes) "
                + "root=\(actual.root) indices=\(actual.indices) "
                + "contextToken=\(actual.context) applicationToken=\(actual.application) "
                + "indexCapacity=\(lease.indexCapacity)")
        }
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline)
    }

    func testRepeatedResumeLeaseRetirementReturnsExactBaseline() throws {
        let original = try FrozenPreparationOwner.reserve()
        let baseline = PlaybackResourceContextLedger.shared.chargedBytes
        for _ in 0..<32 {
            try withLease { lease in
                XCTAssertNotEqual(lease.slot, original.slot)
                XCTAssertLessThanOrEqual(lease.knownAllocationBytes,
                    PausedWindowCoverageLease.reservationBytes)
            }
            XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline)
        }
        withExtendedLifetime(original) {}
    }

    func testResumeMetadataPinsCannotChangeTheOriginalOwner() async throws {
        let harness = try await Task19Harness()
        try await harness.initial()
        defer { harness.publisher.close() }
        let key = try XCTUnwrap(harness.publisher.visible?.media[1]?.resources.first)
        let original = try FrozenPreparationOwner.reserve()
        _ = try original.retainMetadata(in: harness.store, key: key)
        let originalPins = harness.store.preparationLeaseChargeSnapshot(ownerSlot: original.slot)
        var resumed: PausedWindowCoverageLease? = try .reserve()
        let resumedSlot = try XCTUnwrap(resumed).slot
        let metadataSlot = try XCTUnwrap(resumed).retainMetadata(in: harness.store, key: key)
        XCTAssertFalse(try XCTUnwrap(resumed).containsCompletedResource(metadataSlot))
        let otherStore = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        XCTAssertThrowsError(try XCTUnwrap(resumed).retainMetadata(in: otherStore, key: key)) {
            XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .staleIdentity)
        }
        let beforeFreeze = try ServedCoverageDependencies.frozen(
            owner: XCTUnwrap(resumed), rendition: .init(rawValue: 1),
            requested: FMP4PresentationRange(start: Task19.time(0), duration: Task19.time(1)))
        XCTAssertNil(beforeFreeze, "An unfrozen or partly failed attempt cannot issue dependencies")
        try XCTUnwrap(resumed).freezeCompletedResources()
        XCTAssertTrue(try XCTUnwrap(resumed).completionIsFrozen)
        XCTAssertFalse(try XCTUnwrap(resumed).containsCompletedResource(metadataSlot),
            "Metadata presence cannot manufacture completed HTTP evidence")
        XCTAssertThrowsError(try XCTUnwrap(resumed).retainMetadata(in: harness.store, key: key))
        XCTAssertThrowsError(try XCTUnwrap(resumed).freezeCompletedResources())
        XCTAssertFalse(harness.store.preparationLeaseChargeSnapshot(ownerSlot: resumedSlot).identities.isEmpty)
        resumed = nil
        XCTAssertTrue(harness.store.preparationLeaseChargeSnapshot(ownerSlot: resumedSlot).identities.isEmpty)
        let after = harness.store.preparationLeaseChargeSnapshot(ownerSlot: original.slot)
        XCTAssertEqual(Set(after.identities), Set(originalPins.identities))
        XCTAssertEqual(after.charge, originalPins.charge)
        XCTAssertTrue(after.charge.allReservationsRegistered)
        withExtendedLifetime(original) {}
    }

    func testRetainedCoverageOwnerAliasKeepsItsAdmissionAndPins() async throws {
        let harness = try await Task19Harness()
        try await harness.initial()
        defer { harness.publisher.close() }
        let key = try XCTUnwrap(harness.publisher.visible?.media[1]?.resources.first)
        let baseline = PlaybackResourceContextLedger.shared.chargedBytes
        let slot = try retainCoverageAlias(in: harness.store, key: key)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline)
        XCTAssertTrue(harness.store.preparationLeaseChargeSnapshot(ownerSlot: slot).identities.isEmpty)
    }

    @inline(never)
    private func retainCoverageAlias(in store: SealedMediaStore, key: HLSResourceKey) throws -> UInt8 {
        var lease: PausedWindowCoverageLease? = try .reserve()
        _ = try XCTUnwrap(lease).retainMetadata(in: store, key: key)
        let alias = FrozenCompletedCoverageOwner.paused(try XCTUnwrap(lease))
        let charged = PlaybackResourceContextLedger.shared.chargedBytes
        lease = nil
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, charged)
        XCTAssertFalse(store.preparationLeaseChargeSnapshot(ownerSlot: alias.slot).identities.isEmpty)
        withExtendedLifetime(alias) {}
        return alias.slot
    }

    @inline(never)
    private func withLease(_ body: (PausedWindowCoverageLease) throws -> Void) throws {
        let lease = try PausedWindowCoverageLease.reserve()
        try body(lease)
    }
}
