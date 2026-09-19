// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class HLSCapacityTestHarness: @unchecked Sendable {
    let ledger: PlaybackApplicationChargeLedger

    struct TestSealedObject: Sendable {
        let identity: UUID
        let bytes: Int
        let reservation: PlaybackApplicationChargeReservation
    }

    struct TestRangeLease: Sendable {
        let objectIdentity: UUID
        let range: Range<Int>
        let reservation: PlaybackApplicationChargeReservation
    }

    private var activeObjects: [UUID: TestSealedObject] = [:]
    private var activeLeases: [UUID: TestRangeLease] = [:]

    init(ledger: PlaybackApplicationChargeLedger = PlaybackApplicationChargeLedger()) {
        self.ledger = ledger
    }

    var chargedSealedBytes: Int {
        ledger.chargedBytes - ledger.fixedBookkeepingChargeBytes
    }

    func reserveSealedObject(bytes: Int) throws -> TestSealedObject {
        let id = UUID()
        let res = try ledger.reserve(allocationIdentity: .stable(id), bytes: bytes)
        let obj = TestSealedObject(identity: id, bytes: bytes, reservation: res)
        activeObjects[id] = obj
        return obj
    }

    func pinRange(_ object: TestSealedObject, lower: Int, upper: Int) throws -> TestRangeLease {
        let leaseRes = try ledger.reserve(allocationIdentity: .stable(object.identity), bytes: object.bytes)
        let lease = TestRangeLease(objectIdentity: object.identity, range: lower..<upper, reservation: leaseRes)
        activeLeases[leaseRes.reservationIdentity] = lease
        return lease
    }

    func retireObject(_ object: TestSealedObject) {
        activeObjects.removeValue(forKey: object.identity)
        ledger.release(object.reservation)
    }

    func release(_ rangeLease: TestRangeLease) {
        activeLeases.removeValue(forKey: rangeLease.reservation.reservationIdentity)
        ledger.release(rangeLease.reservation)
    }
}

final class HLSCapacityTests: XCTestCase {
    func testHarnessSealedObjectAndRangeLeaseLifecycle() throws {
        let harness = HLSCapacityTestHarness()
        let object = try harness.reserveSealedObject(bytes: 1_048_576)
        let rangeLease = try harness.pinRange(object, lower: 0, upper: 1)
        XCTAssertEqual(harness.chargedSealedBytes, 1_048_576)
        harness.retireObject(object)
        XCTAssertEqual(harness.chargedSealedBytes, 1_048_576)
        harness.release(rangeLease)
        XCTAssertEqual(harness.chargedSealedBytes, 0)
    }

    func testGlobalLedgerRejectsHardPlusOneBeforeTokenOrIndexAllocation() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let hard = PlaybackApplicationChargeLedger.documentedApplicationHardBytes

        // Hard cap + 1 allocation should fail immediately
        XCTAssertThrowsError(try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: hard + 1)) { error in
            XCTAssertEqual(error as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes, "Failure must not leak any charge")

        // Fill up to hard cap
        let available = hard - ledger.fixedBookkeepingChargeBytes
        let filler = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: available)
        XCTAssertEqual(ledger.chargedBytes, hard)

        // One more byte must fail
        XCTAssertThrowsError(try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: 1)) { error in
            XCTAssertEqual(error as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }
        XCTAssertEqual(ledger.chargedBytes, hard)

        ledger.release(filler)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes)
    }

    func testGlobalLedgerSameIdentityAliasesDeduplicateAndCapPlusOneIsSideEffectFree() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let sharedIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let bytes = 64 * 1_024

        let first = try ledger.reserve(allocationIdentity: sharedIdentity, bytes: bytes)
        let alias1 = try ledger.reserve(allocationIdentity: sharedIdentity, bytes: bytes)
        let alias2 = try ledger.reserve(allocationIdentity: sharedIdentity, bytes: bytes)

        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + bytes, "Aliases must deduplicate bytes")

        ledger.release(alias1)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + bytes, "First alias release must not free bytes")
        ledger.release(first)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + bytes, "Prior release must keep bytes while alias2 is alive")
        ledger.release(alias2)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes, "Last alias release must return charge to baseline")
    }

    func testGlobalLedgerLastOwnerReleaseRetiresLogicalChargeWithoutClaimingBackingFreed() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let identity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let bytes = 128 * 1_024

        let owner = try ledger.reserve(allocationIdentity: identity, bytes: bytes)
        let alias = try ledger.reserve(allocationIdentity: identity, bytes: bytes)

        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + bytes)

        ledger.release(owner)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + bytes, "Alias keeps charge")

        ledger.release(alias)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes, "Logical charge returns to baseline")
    }

    func testGlobalLedgerRebindSplitChecksCapAndRollsBackAtHardPlusOne() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let hard = PlaybackApplicationChargeLedger.documentedApplicationHardBytes

        let sharedIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let targetIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let chunkSize = 50 * 1_024 * 1_024

        let original = try ledger.reserve(allocationIdentity: sharedIdentity, bytes: chunkSize)
        let alias = try ledger.reserve(allocationIdentity: sharedIdentity, bytes: chunkSize)

        // Rebind when old has references > 1 and target is new should check capacity
        // Now fill ledger up to hard cap minus chunkSize + 1
        let remainingToFill = hard - ledger.chargedBytes - (chunkSize - 1)
        let filler = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: remainingToFill)

        // Attempting to rebind alias to a new identity would require additional chunkSize, exceeding hard cap
        XCTAssertThrowsError(try ledger.rebind(alias, to: targetIdentity)) { error in
            XCTAssertEqual(error as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }

        // Must rollback: original and alias still bound to sharedIdentity
        XCTAssertEqual(alias.allocationIdentity, sharedIdentity)
        XCTAssertEqual(ledger.chargedBytes, hard - chunkSize + 1 + ledger.fixedBookkeepingChargeBytes)

        ledger.release(filler)
        ledger.release(original)
        ledger.release(alias)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes)
    }

    func testGlobalLedgerOldGenerationTailAndSuccessorShareIdentityUntilFinalRelease() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let mediaIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let segmentBytes = 2 * 1_024 * 1_024

        // Generation 1 acquires segment
        let gen1Media = try ledger.reserve(allocationIdentity: mediaIdentity, bytes: segmentBytes)
        // Generation 1 HTTP response acquires range lease on segment
        let gen1HTTPLease = try ledger.reserve(allocationIdentity: mediaIdentity, bytes: segmentBytes)

        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + segmentBytes)

        // Generation 2 prepares and shares the same sealed segment
        let gen2Media = try ledger.reserve(allocationIdentity: mediaIdentity, bytes: segmentBytes)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + segmentBytes, "G2 sharing G1 segment must not double charge")

        // Generation 1 retires its media reference
        ledger.release(gen1Media)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + segmentBytes, "HTTP lease and G2 keep segment charged")

        // Generation 1 HTTP lease finishes
        ledger.release(gen1HTTPLease)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes + segmentBytes, "G2 keeps segment charged")

        // Generation 2 retires
        ledger.release(gen2Media)
        XCTAssertEqual(ledger.chargedBytes, ledger.fixedBookkeepingChargeBytes, "All references released, returns to baseline")
    }

    func testCapacityConfigurationCartesianEnvelopeMatchesDocumentedCaps() {
        let envelope = PlaybackCapacityEnvelope.current

        // Verify the exact Cartesian sum of all design section 11 elements
        XCTAssertEqual(envelope.softCapBytes, PlaybackApplicationChargeLedger.documentedApplicationSoftBytes)
        XCTAssertEqual(envelope.hardCapBytes, PlaybackApplicationChargeLedger.documentedApplicationHardBytes)
        XCTAssertEqual(envelope.softCapBytes, 981_184_512)
        XCTAssertEqual(envelope.hardCapBytes, 1_266_647_040)
        XCTAssertEqual(envelope.fixedBookkeepingBytes, 2_048)

        // Component verifications
        XCTAssertEqual(envelope.demuxQueueLimit.softBytes, 48 * 1_048_576)
        XCTAssertEqual(envelope.demuxQueueLimit.hardBytes, 64 * 1_048_576)
        XCTAssertEqual(envelope.demuxQueueLimit.softItems, 192)
        XCTAssertEqual(envelope.demuxQueueLimit.hardItems, 256)

        XCTAssertEqual(envelope.videoAssemblerQueueLimit.softBytes, 48 * 1_048_576)
        XCTAssertEqual(envelope.videoAssemblerQueueLimit.hardBytes, 64 * 1_048_576)
        XCTAssertEqual(envelope.videoAssemblerQueueLimit.softItems, 90)
        XCTAssertEqual(envelope.videoAssemblerQueueLimit.hardItems, 120)

        XCTAssertEqual(envelope.pixelSurfacePoolLimit.softBytes, 192 * 1_048_576)
        XCTAssertEqual(envelope.pixelSurfacePoolLimit.hardBytes, 256 * 1_048_576)
        XCTAssertEqual(envelope.pixelSurfacePoolLimit.softSurfaces, 6)
        XCTAssertEqual(envelope.pixelSurfacePoolLimit.hardSurfaces, 8)

        XCTAssertEqual(envelope.audioPCMQueueLimit.softBytes, 4 * 1_048_576)
        XCTAssertEqual(envelope.audioPCMQueueLimit.hardBytes, 8 * 1_048_576)
        XCTAssertEqual(envelope.audioPCMQueueLimit.softFrames, 48_000)
        XCTAssertEqual(envelope.audioPCMQueueLimit.hardFrames, 96_000)

        XCTAssertEqual(envelope.audioAUQueueLimit.softBytes, 2 * 1_048_576)
        XCTAssertEqual(envelope.audioAUQueueLimit.hardBytes, 4 * 1_048_576)

        XCTAssertEqual(envelope.calibrationWorkspaceLimit.softBytes, 3 * 1_048_576)
        XCTAssertEqual(envelope.calibrationWorkspaceLimit.hardBytes, 4 * 1_048_576)

        XCTAssertEqual(envelope.liveAACArtifactLimit.softBytes, 1_048_576)
        XCTAssertEqual(envelope.liveAACArtifactLimit.hardBytes, 1_048_576)

        XCTAssertEqual(envelope.sealedMediaStoreLimit.softBytes, 560 * 1_048_576)
        XCTAssertEqual(envelope.sealedMediaStoreLimit.hardBytes, 688 * 1_048_576)

        XCTAssertEqual(envelope.playlistSnapshotLimit.softBytes, 5 * 1_048_576)
        XCTAssertEqual(envelope.playlistSnapshotLimit.hardBytes, 6 * 1_048_576)

        XCTAssertEqual(envelope.httpStagingLimit.softBytes, 576 * 1_024)
        XCTAssertEqual(envelope.httpStagingLimit.hardBytes, 768 * 1_024)

        XCTAssertEqual(envelope.controlLayerLimit.softBytes, 76 * 1_024)
        XCTAssertEqual(envelope.controlLayerLimit.hardBytes, 96 * 1_024)

        XCTAssertEqual(envelope.resourceContextLimit.softBytes, 96 * 1_024)
        XCTAssertEqual(envelope.resourceContextLimit.hardBytes, 128 * 1_024)
    }

    func testGlobalLedgerBackpressureAtSoftCap() throws {
        let ledger = PlaybackApplicationChargeLedger()
        let soft = PlaybackApplicationChargeLedger.documentedApplicationSoftBytes
        let available = soft - ledger.fixedBookkeepingChargeBytes

        let filler = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: available)
        XCTAssertTrue(ledger.shouldBackpressure)

        // Next new reservation should throw backpressure
        XCTAssertThrowsError(try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: 1_024)) { error in
            XCTAssertEqual(error as? LoopbackHTTPReservationError, .backpressure)
        }

        ledger.release(filler)
        XCTAssertFalse(ledger.shouldBackpressure)
    }
}
