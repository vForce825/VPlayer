// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
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

/// Borrowed credits never start media operations in this isolated suite. A
/// retained closure represents the SDK tail; only the explicit empty-player
/// fixture uses a real disconnect callback to establish native gate readback.
@MainActor
final class AVPlayerSDKCallbackCreditPoolTests: XCTestCase {
    private var context: PlaybackResourceContextLedger { .shared }
    private var application: PlaybackApplicationChargeLedger { .shared }

    func testTwoCreditsRejectWithOnlyOneFreeSDKSlotWithoutLeakingPartialAdmission() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        var tails: [AVPlayerSDKCallbackLease] = []
        for _ in 0..<7 { tails.append(try driver.reserveSDKCallbackLease(.ready)) }
        let bytes = context.chargedBytes
        let globalBytes = application.chargedBytes
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 7)
        XCTAssertThrowsError(try driver.reserveSDKCallbackCredits())
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 7)
        XCTAssertEqual(context.chargedBytes, bytes)
        XCTAssertEqual(application.chargedBytes, globalBytes)
        tails.removeAll()
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        pool?.close()
        pool = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testPartialContextReservationFailureReturnsSlotsAndBothLedgersToBaseline() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let root = try AVPlayerSDKCallbackCreditPool.allocationBreakdown().totalBytes
        let filler = try context.reserve(allocationIdentity: .stable(UUID()),
            bytes: PlaybackResourceContextLedger.softBytes - context.chargedBytes - root - 2 * 1_024)
        defer { context.release(filler) }
        let bytes = context.chargedBytes
        let globalBytes = application.chargedBytes
        XCTAssertThrowsError(try driver.reserveSDKCallbackCredits())
        XCTAssertEqual(context.chargedBytes, bytes)
        XCTAssertEqual(application.chargedBytes, globalBytes)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        XCTAssertFalse(context.shouldBackpressure)
    }

    func testBorrowTransfersPrechargedCreditWithoutRefillingBudget() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let root = try AVPlayerSDKCallbackCreditPool.allocationBreakdown().totalBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        let admitted = baseline + root + 4 * 1_024
        XCTAssertEqual(context.chargedBytes, admitted)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        var lease: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool!)
        lease?.assertRegistered()
        XCTAssertEqual(context.chargedBytes, admitted)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        lease = nil
        XCTAssertEqual(context.chargedBytes, admitted, "An open pool still owns the returned credit")
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool!)
        cleanup?.assertRegistered()
        pool?.close()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        cleanup = nil
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        pool = nil
        XCTAssertEqual(context.chargedBytes, baseline)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testPrepaidBorrowSucceedsAtSoftBackpressureWithoutNewReservation() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let globalBaseline = application.chargedBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        let filler = try context.reserve(allocationIdentity: .stable(UUID()),
            bytes: PlaybackResourceContextLedger.softBytes - context.chargedBytes)
        defer { context.release(filler) }
        XCTAssertTrue(context.shouldBackpressure)
        let globalBytes = application.chargedBytes
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool!)
        operation?.assertRegistered()
        XCTAssertEqual(context.chargedBytes, PlaybackResourceContextLedger.softBytes)
        XCTAssertEqual(application.chargedBytes, globalBytes)
        operation = nil
        operation = try driver.borrowSDKOperationCredit(.loaded, from: pool!)
        operation?.assertRegistered()
        XCTAssertEqual(context.chargedBytes, PlaybackResourceContextLedger.softBytes)
        operation = nil
        pool?.close()
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        pool = nil
        context.release(filler)
        XCTAssertEqual(context.chargedBytes, baseline)
        XCTAssertEqual(application.chargedBytes, globalBaseline)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testOptionalObserverNeedsThirdOriginalBitmapSlotAndRollsBackOnFailure() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        var tails: [AVPlayerSDKCallbackLease] = []
        for _ in 0..<6 { tails.append(try driver.reserveSDKCallbackLease(.ready)) }
        let bytes = context.chargedBytes
        let globalBytes = application.chargedBytes
        XCTAssertThrowsError(try driver.reserveSDKCallbackCredits(includingObserver: true))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 6)
        XCTAssertEqual(context.chargedBytes, bytes)
        XCTAssertEqual(application.chargedBytes, globalBytes)
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 8)
        pool?.close()
        pool = nil
        tails.removeAll()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testLegacyLogFetchStillCostsFourKiBAndSharesTheSameEightSlots() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        let baseline = context.chargedBytes
        var log: AVPlayerSDKCallbackLease? = try driver.reserveSDKCallbackLease(.logFetch)
        log?.assertRegistered()
        XCTAssertEqual(context.chargedBytes, baseline + 4 * 1_024)
        var ordinary: [AVPlayerSDKCallbackLease] = []
        for _ in 0..<5 { ordinary.append(try driver.reserveSDKCallbackLease(.accessLog)) }
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 8)
        XCTAssertThrowsError(try driver.reserveSDKCallbackLease(.ready))
        ordinary.removeAll()
        log = nil
        pool?.close()
        pool = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testCloseBeforeAnyBorrowReleasesAllCreditsAndIsIdempotent() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let root = try AVPlayerSDKCallbackCreditPool.allocationBreakdown().totalBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits(includingObserver: true)
        pool?.close()
        pool?.close()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        XCTAssertEqual(context.chargedBytes, baseline + root)
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.ready, from: pool!))
        XCTAssertThrowsError(try driver.borrowSDKObserverCredit(from: pool!))
        XCTAssertThrowsError(try driver.borrowSDKRollbackCredit(from: pool!))
        pool = nil
        XCTAssertEqual(context.chargedBytes, baseline)
    }

    func testCancellationBeforeBorrowRejectsOperationsAndCanAbortNeverStartedPool() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits(includingObserver: true)
        pool?.cancel()
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.ready, from: pool!))
        XCTAssertThrowsError(try driver.borrowSDKObserverCredit(from: pool!))
        pool?.close()
        pool = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        XCTAssertEqual(context.chargedBytes, baseline)
    }

    func testContinuationDeliveryAndAliasReleaseCannotReturnPhysicalCredit() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        var lease: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool)
        var sdkTail: (() -> Void)? = { [held = try XCTUnwrap(lease)] in held.assertRegistered() }
        lease = nil
        sdkTail?() // Logical success does not destroy the retained callback.
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.loaded, from: pool))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        sdkTail = nil
        var next: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.loaded, from: pool)
        next?.assertRegistered()
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.preroll, from: pool))
        next = nil
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool)
        cleanup?.assertRegistered()
        pool.close()
        cleanup = nil
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        pool.close() // A repeated close cannot return a credit twice.
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testCloseAfterCancellationProtectsCleanupWhileOriginalCallbackTailSurvives() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let root = try AVPlayerSDKCallbackCreditPool.allocationBreakdown().totalBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.preroll, from: pool!)
        var sdkTail: (() -> Void)? = { [held = try XCTUnwrap(operation)] in held.assertRegistered() }
        operation = nil
        pool?.cancel()
        pool?.close()
        pool?.close()
        XCTAssertEqual(context.chargedBytes, baseline + root + 4 * 1_024)
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.ready, from: pool!))
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool!)
        XCTAssertThrowsError(try driver.borrowSDKRollbackCredit(from: pool!))
        sdkTail?()
        cleanup?.assertRegistered()
        cleanup = nil
        XCTAssertEqual(context.chargedBytes, baseline + root + 4 * 1_024,
            "Merely dropping a rollback borrower cannot prove cleanup was registered")
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        sdkTail = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!), "No double resolution")
        pool = nil
        XCTAssertEqual(context.chargedBytes, baseline)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testReturnedOperationStillCannotDiscardUnusedProtectedRollbackOnClose() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.systemAudio, from: pool!)
        operation?.assertRegistered()
        pool?.cancel()
        pool?.close()
        operation = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1,
            "Physical operation retirement alone does not confirm disconnection")
        pool?.close()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool!)
        cleanup?.assertRegistered()
        cleanup = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        pool = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testFailedDriverCleanupResolutionKeepsRollbackProtected() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.systemAudio, from: pool)
        pool.cancel()
        pool.close()
        let bytes = context.chargedBytes
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool),
            "An admitted physical operation cannot be skipped by a cleanup readback")
        XCTAssertEqual(context.chargedBytes, bytes)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        operation?.assertRegistered()
        operation = nil
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool)
        cleanup?.assertRegistered()
        cleanup = nil
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testLateObserverRetainsOnlyItsCreditAndPoolAfterOtherPhysicalTailsRetire() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let root = try AVPlayerSDKCallbackCreditPool.allocationBreakdown().totalBytes
        var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits(includingObserver: true)
        var observer: AVPlayerSDKCallbackLease? = try driver.borrowSDKObserverCredit(from: pool!)
        XCTAssertThrowsError(try driver.borrowSDKObserverCredit(from: pool!))
        var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool!)
        pool?.close()
        cleanup?.assertRegistered()
        cleanup = nil
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        pool = nil
        observer?.assertRegistered()
        XCTAssertEqual(context.chargedBytes, baseline + root + 2 * 1_024)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        observer = nil
        XCTAssertEqual(context.chargedBytes, baseline)
    }

    func testOldObserverTailBlocksSuccessorAndOldClosedPoolCannotBorrowFromSuccessor() async throws {
        let baseline = context.chargedBytes
        var driver: SystemAVPlayerDriver? = try await makeDisconnectedEmptyDriver()
        var pool: AVPlayerSDKCallbackCreditPool? = try driver!.reserveSDKCallbackCredits(includingObserver: true)
        var observer: AVPlayerSDKCallbackLease? = try driver!.borrowSDKObserverCredit(from: pool!)
        pool?.close()
        XCTAssertTrue(driver!.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        driver = nil
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(), "The physical observer owns original admission")
        observer?.assertRegistered()
        observer = nil
        var successor: SystemAVPlayerDriver? = try await makeDisconnectedEmptyDriver()
        let bytes = context.chargedBytes
        XCTAssertThrowsError(try successor!.borrowSDKOperationCredit(.seek, from: pool!))
        XCTAssertThrowsError(try successor!.borrowSDKRollbackCredit(from: pool!))
        XCTAssertFalse(successor!.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
        XCTAssertEqual(context.chargedBytes, bytes)
        pool = nil
        successor = nil
        XCTAssertEqual(context.chargedBytes, baseline)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testSameDriverSuccessorItemCannotBorrowOldOperationObserverOrRollbackCredits() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_701)
        let first = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle, itemGeneration: 1)
        let second = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle, itemGeneration: 2)
        try driver.install(url: URL(string: "http://127.0.0.1:1/credit-item-one.m3u8")!, identity: first)
        let pool = try driver.reserveSDKCallbackCredits(includingObserver: true)
        try driver.install(url: URL(string: "http://127.0.0.1:1/credit-item-two.m3u8")!, identity: second)
        defer { driver.replaceCurrentItemWithNil(item: second) }
        let bytes = context.chargedBytes
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.seek, from: pool))
        XCTAssertThrowsError(try driver.borrowSDKObserverCredit(from: pool))
        XCTAssertThrowsError(try driver.borrowSDKRollbackCredit(from: pool))
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertEqual(context.chargedBytes, bytes)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 3)
        pool.close() // No borrower was admitted and no native effect used this pool.
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testCloseThenRollbackBorrowRetainsOriginalInstallationAliasUntilResolution() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        var installation: PlaybackResourceContextReservation? = try context.reserve(
            allocationIdentity: .stable(UUID()), bytes: 4 * 1_024)
        let originalInstallation = CallbackCreditWeakInstallation(installation)
        driver.retainInstallationResourceContext(try XCTUnwrap(installation))
        let pool = try driver.reserveSDKCallbackCredits()
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.ready, from: pool)
        operation?.assertRegistered()
        operation = nil
        pool.cancel()
        pool.close()
        // Change only the driver's alias; the original pool/item stays identical.
        let replacement = try context.reserve(allocationIdentity: .stable(UUID()), bytes: 1_024)
        driver.retainInstallationResourceContext(replacement)
        installation = nil
        XCTAssertNotNil(originalInstallation.value, "Protected rollback still needs the original installation owner")
        var rollback: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool)
        rollback?.assertRegistered()
        XCTAssertNotNil(originalInstallation.value)
        rollback = nil
        XCTAssertNotNil(originalInstallation.value, "Dropping the physical borrower does not settle cleanup")
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertNil(originalInstallation.value)
    }

    func testChangedInstalledItemRejectsResolutionOfPoolCapturedWhileEmpty() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.ready, from: pool)
        operation?.assertRegistered()
        operation = nil
        pool.close()
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        driver.player.replaceCurrentItem(with: replacement)
        XCTAssertTrue(driver.player.currentItem === replacement)
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
        driver.player.replaceCurrentItem(with: nil)
        // Empty-player direct readback only; no installed-item cleanup is claimed.
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testOrdinaryCreditCannotBecomeLogFetchOrObserverAndObserverMustBePrepaid() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        let bytes = context.chargedBytes
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.logFetch, from: pool))
        XCTAssertThrowsError(try driver.borrowSDKOperationCredit(.timeControl, from: pool))
        XCTAssertThrowsError(try driver.borrowSDKObserverCredit(from: pool))
        XCTAssertEqual(context.chargedBytes, bytes)
        pool.close()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testPoolAllocationIsDerivedAndActualRootsFitWithoutCaptureOrTaskStorage() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits(includingObserver: true)
        let layout = try AVPlayerSDKCallbackCreditPool.allocationBreakdown()
        XCTAssertGreaterThan(layout.poolBytes, 0)
        XCTAssertGreaterThan(layout.contextReservationBytes, 0)
        XCTAssertGreaterThan(layout.applicationReservationBytes, 0)
        XCTAssertEqual(layout.totalBytes,
            layout.poolBytes + layout.contextReservationBytes + layout.applicationReservationBytes)
        let actual = try XCTUnwrap(pool.allocationUsage())
        XCTAssertGreaterThan(actual.pool, 0)
        XCTAssertGreaterThan(actual.context, 0)
        XCTAssertGreaterThan(actual.application, 0)
        XCTAssertLessThanOrEqual(actual.pool, layout.poolBytes)
        XCTAssertLessThanOrEqual(actual.context, layout.contextReservationBytes)
        XCTAssertLessThanOrEqual(actual.application, layout.applicationReservationBytes)
        print("CALLBACK_CREDIT_ROOT actual=\(actual.pool) admitted=\(layout.poolBytes) "
            + "contextTokenActual=\(actual.context) contextTokenAdmitted=\(layout.contextReservationBytes) "
            + "applicationTokenActual=\(actual.application) applicationTokenAdmitted=\(layout.applicationReservationBytes)")
        pool.inspectAllocations { role, pointer, actual, admitted in
            print("CALLBACK_CREDIT_ALLOCATION \(role) identity=\(UInt(bitPattern: pointer)) actual=\(actual) admitted=\(admitted)")
            XCTAssertGreaterThan(actual, 0)
            XCTAssertLessThanOrEqual(actual, admitted)
        }
        pool.close()
    }

    func testRepeatedBorrowCancelCloseCyclesReturnExactlyToBothLedgerBaselines() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let globalBaseline = application.chargedBytes
        for cycle in 0..<64 {
            var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits(includingObserver: true)
            var operation: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool!)
            operation?.assertRegistered()
            operation = nil
            operation = try driver.borrowSDKOperationCredit(.loaded, from: pool!)
            var observer: AVPlayerSDKCallbackLease? = try driver.borrowSDKObserverCredit(from: pool!)
            pool?.cancel()
            pool?.close()
            var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: pool!)
            operation?.assertRegistered()
            observer?.assertRegistered()
            cleanup?.assertRegistered()
            operation = nil
            cleanup = nil
            XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool!))
            pool = nil
            observer = nil
            XCTAssertEqual(context.chargedBytes, baseline, "cycle \(cycle)")
            XCTAssertEqual(application.chargedBytes, globalBaseline, "cycle \(cycle)")
            XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0, "cycle \(cycle)")
        }
    }

    func testConcurrentCloseAndLastPhysicalAliasReleaseNeverRefillOrDoubleRelease() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let baseline = context.chargedBytes
        let globalBaseline = application.chargedBytes
        for _ in 0..<64 {
            var pool: AVPlayerSDKCallbackCreditPool? = try driver.reserveSDKCallbackCredits()
            let retainedPool = try XCTUnwrap(pool)
            let tail = CallbackCreditTailBox(try driver.borrowSDKOperationCredit(.seek, from: retainedPool))
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0: retainedPool.cancel()
                case 1: retainedPool.close()
                default: tail.release()
                }
            }
            XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1)
            var cleanup: AVPlayerSDKCallbackLease? = try driver.borrowSDKRollbackCredit(from: retainedPool)
            cleanup?.assertRegistered()
            cleanup = nil
            XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(retainedPool))
            pool = nil
            withExtendedLifetime(retainedPool) {}
        }
        XCTAssertEqual(context.chargedBytes, baseline)
        XCTAssertEqual(application.chargedBytes, globalBaseline)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testOperationReturnWaitCloseWakesWithoutReturningPhysicalCredit() async throws {
        try await assertOperationReturnWaitWake(closing: true)
    }

    func testOperationReturnWaitCancelWakesWithoutReturningPhysicalCredit() async throws {
        try await assertOperationReturnWaitWake(closing: false)
    }

    private func assertOperationReturnWaitWake(closing: Bool) async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        var physical: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool)
        let charged = context.chargedBytes
        var finished = false
        let waiting = Task { @MainActor in
            defer { finished = true }
            try await pool.waitForOperationReturn()
        }
        defer { waiting.cancel() }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !pool.hasOperationReturnWaiter, ContinuousClock.now < startedDeadline { await Task.yield() }
        guard pool.hasOperationReturnWaiter else {
            waiting.cancel()
            _ = try? await waiting.value
            physical = nil
            pool.close()
            _ = driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool)
            XCTFail("The first physical-credit waiter did not register within its fixture bound")
            return
        }
        if closing { pool.close() } else { pool.cancel() }
        let wakeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished, ContinuousClock.now < wakeDeadline { await Task.yield() }
        let wokeBeforeRelease = finished
        if !finished { waiting.cancel() }
        do { try await waiting.value; XCTFail("Closed/canceled admission must reject its waiter") }
        catch { XCTAssertTrue(error is CancellationError || error is AVPlayerItemCoordinatorFailure) }
        XCTAssertTrue(wokeBeforeRelease, "Close/cancel must wake without waiting for the native alias to die")
        XCTAssertFalse(pool.hasOperationReturnWaiter)
        physical?.assertRegistered()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        XCTAssertEqual(context.chargedBytes, charged)
        XCTAssertFalse(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool),
            "The still-borrowed physical operation prevents releasing rollback")
        physical = nil
        pool.close()
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testOperationReturnWaitRejectsSecondWaiterAndCancellationAllowsReplacement() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        let pool = try driver.reserveSDKCallbackCredits()
        var physical: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.seek, from: pool)
        let first = Task { try await pool.waitForOperationReturn() }
        defer { first.cancel() }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !pool.hasOperationReturnWaiter, ContinuousClock.now < firstDeadline { await Task.yield() }
        guard pool.hasOperationReturnWaiter else {
            first.cancel()
            _ = try? await first.value
            physical = nil
            pool.close()
            _ = driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool)
            XCTFail("The first physical-credit waiter did not register within its fixture bound")
            return
        }
        do { try await pool.waitForOperationReturn(); XCTFail("A second waiter must not replace the first") }
        catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .operationInFlight) }
        XCTAssertTrue(pool.hasOperationReturnWaiter)
        first.cancel()
        do { try await first.value; XCTFail("Original waiter must observe cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(pool.hasOperationReturnWaiter)
        physical?.assertRegistered()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
        let replacement = Task { try await pool.waitForOperationReturn() }
        defer { replacement.cancel() }
        let replacementDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !pool.hasOperationReturnWaiter, ContinuousClock.now < replacementDeadline { await Task.yield() }
        guard pool.hasOperationReturnWaiter else {
            replacement.cancel()
            _ = try? await replacement.value
            physical = nil
            pool.close()
            _ = driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool)
            XCTFail("The first physical-credit waiter did not register within its fixture bound")
            return
        }
        physical = nil
        try await replacement.value
        XCTAssertFalse(pool.hasOperationReturnWaiter)
        var next: AVPlayerSDKCallbackLease? = try driver.borrowSDKOperationCredit(.loaded, from: pool)
        next?.assertRegistered()
        next = nil
        pool.close()
        XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
    }

    func testOperationReturnPhysicalDeinitRacingCancellationResolvesOnce() async throws {
        let driver = try await makeDisconnectedEmptyDriver()
        for _ in 0..<32 {
            let pool = try driver.reserveSDKCallbackCredits()
            let tail = CallbackCreditTailBox(try driver.borrowSDKOperationCredit(.seek, from: pool))
            let waiter = Task { try await pool.waitForOperationReturn() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !pool.hasOperationReturnWaiter, ContinuousClock.now < deadline { await Task.yield() }
            guard pool.hasOperationReturnWaiter else {
                waiter.cancel()
                _ = try? await waiter.value
                tail.release()
                pool.close()
                _ = driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool)
                XCTFail("The first physical-credit waiter did not register within its fixture bound")
                return
            }
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { waiter.cancel() } else { tail.release() }
            }
            do { try await waiter.value } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(pool.hasOperationReturnWaiter)
            XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 2)
            pool.close()
            XCTAssertTrue(driver.releaseUnusedSDKRollbackCreditIfDisconnected(pool))
        }
    }

    /// Actual empty-player native readback fixture only. It does not activate an
    /// audio session, install an item, play, or assert installed-item quiescence.
    private func makeDisconnectedEmptyDriver() async throws -> SystemAVPlayerDriver {
        let player = AVPlayer()
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.setDisconnectedFromSystemAudio(true) { continuation.resume() }
        }
        XCTAssertTrue(player.disconnectedFromSystemAudio)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertNil(player.currentItem)
        return try SystemAVPlayerDriver.make(player: player)
    }

}

private final class CallbackCreditTailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: AVPlayerSDKCallbackLease?
    init(_ lease: AVPlayerSDKCallbackLease) { self.lease = lease }
    func release() { lock.withLock { lease = nil } }
}

private final class CallbackCreditWeakInstallation {
    weak var value: PlaybackResourceContextReservation?

    init(_ value: PlaybackResourceContextReservation?) { self.value = value }
}
