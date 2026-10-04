// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class BoundedMediaQueueTests: XCTestCase {
    func testCompressedVideoOverflowRejectsNewestWithoutLaterRandomAccess() throws {
        var subject = CompressedVideoReservoir(limits: CompressedVideoRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 1_024,
            latestTailHorizon: CMTime(value: 10, timescale: 1)
        ))
        XCTAssertTrue(subject.append(try videoUnit(id: 1, randomAccess: true)).accepted)
        XCTAssertTrue(subject.append(try videoUnit(id: 2, randomAccess: false)).accepted)

        let overflow = subject.append(try videoUnit(id: 3, randomAccess: false))

        XCTAssertFalse(overflow.accepted)
        XCTAssertEqual(subject.map(\.id), [1, 2])
    }

    func testCompressedVideoOverflowMovesAtomicallyToDecodableSuffix() throws {
        var subject = CompressedVideoReservoir(limits: CompressedVideoRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 1_024,
            latestTailHorizon: CMTime(value: 10, timescale: 1)
        ))
        _ = subject.append(try videoUnit(id: 1, randomAccess: true))
        _ = subject.append(try videoUnit(id: 2, randomAccess: false))

        let overflow = subject.append(try videoUnit(id: 3, randomAccess: true))

        XCTAssertEqual(overflow, CompressedVideoReservoirMutation(
            accepted: true,
            droppedCount: 2
        ))
        XCTAssertEqual(subject.map(\.id), [3])
    }

    func testCompressedVideoOverflowCanPreserveEarliestWindowWhileReadinessIsClosed() throws {
        var subject = CompressedVideoReservoir(limits: CompressedVideoRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 1_024,
            latestTailHorizon: CMTime(value: 10, timescale: 1)
        ))
        _ = subject.append(try videoUnit(id: 1, randomAccess: true))
        _ = subject.append(try videoUnit(id: 2, randomAccess: false))

        let overflow = subject.append(
            try videoUnit(id: 3, randomAccess: true),
            decodableSuffixMayStartAt: { _ in false }
        )

        XCTAssertFalse(overflow.accepted)
        XCTAssertEqual(subject.map(\.id), [1, 2])
    }

    func testOversizedRandomAccessDoesNotEraseExistingDecodableGOP() throws {
        let first = try videoUnit(id: 1, randomAccess: true)
        let bytes = CMSampleBufferGetTotalSampleSize(first.sampleBuffer)
            + (try XCTUnwrap(first.sourceBacking)).byteCount
        var subject = CompressedVideoReservoir(limits: CompressedVideoRetentionLimits(
            maximumCount: 4,
            maximumOwnedBytes: bytes,
            latestTailHorizon: CMTime(value: 10, timescale: 1)
        ))
        XCTAssertTrue(subject.append(first).accepted)

        let overflow = subject.append(try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: MediaGeneration(rawValue: 1),
            randomAccess: true,
            pts: CMTime(value: 2, timescale: 25),
            data: Data(repeating: 0x01, count: bytes + 1)
        ))

        XCTAssertFalse(overflow.accepted)
        XCTAssertEqual(subject.map(\.id), [1])
    }

    func testCompressedVideoBudgetIncludesIndependentSourceAndSampleBackings() throws {
        let unit = try videoUnit(id: 1, randomAccess: true)
        let sampleBytes = CMSampleBufferGetTotalSampleSize(unit.sampleBuffer)
        let sourceBytes = try XCTUnwrap(unit.sourceBacking).byteCount
        var undersized = videoReservoir(bytes: sampleBytes + sourceBytes - 1)
        XCTAssertFalse(undersized.append(unit).accepted,
            "Both the original AU evidence and the separately copied CM payload remain owned")
        XCTAssertTrue(undersized.isEmpty)
        var exact = videoReservoir(bytes: sampleBytes + sourceBytes)
        XCTAssertTrue(exact.append(unit).accepted)
    }

    func testCompressedVideoBudgetDeduplicatesSharedSourceAndCopiedSampleHeaders() throws {
        let unit = try videoUnit(id: 1, randomAccess: true)
        let source = try XCTUnwrap(unit.sourceBacking)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(unit.sampleBuffer))
        var subject = videoReservoir(bytes: source.byteCount + CMBlockBufferGetDataLength(block))
        XCTAssertTrue(subject.append(unit).accepted)
        for _ in 0..<3 {
            var copy: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
                sampleBuffer: unit.sampleBuffer, sampleBufferOut: &copy), noErr)
            let sample = try XCTUnwrap(copy)
            XCTAssertNotEqual(ObjectIdentifier(sample), ObjectIdentifier(unit.sampleBuffer))
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))),
                ObjectIdentifier(block))
            XCTAssertTrue(subject.append(try evidenceUnit(unit, sample: sample)).accepted,
                "New headers sharing the same owners must not charge the payload again")
        }
        XCTAssertEqual(subject.count, 4)
    }

    func testCompressedVideoBudgetDoesNotDeduplicateIndependentSamplesWithEqualBytes() throws {
        let first = try videoUnit(id: 1, randomAccess: true)
        let second = try videoUnit(id: 2, randomAccess: false)
        let sourceBytes = try XCTUnwrap(first.sourceBacking).byteCount
        let sampleBytes = CMSampleBufferGetTotalSampleSize(first.sampleBuffer)
        var subject = videoReservoir(bytes: sourceBytes + sampleBytes * 2 - 1)
        XCTAssertTrue(subject.append(first).accepted)
        // Use the same source owner with a genuinely independent second native allocation.
        XCTAssertFalse(subject.append(try evidenceUnit(first, sample: second.sampleBuffer)).accepted)
        XCTAssertEqual(subject.count, 1)
    }

    func testCompressedVideoBudgetCountsReboundSourceButSharesNativeBacking() throws {
        let original = try videoUnit(id: 1, randomAccess: true)
        let rebound = try original.rebindingSourceEvidence(to: MediaGeneration(rawValue: 2))
        let originalSource = try XCTUnwrap(original.sourceBacking)
        let reboundSource = try XCTUnwrap(rebound.sourceBacking)
        XCTAssertFalse(originalSource.ownerIdentity === reboundSource.ownerIdentity)
        XCTAssertEqual(original.sourceSHA256, rebound.sourceSHA256)
        XCTAssertEqual(ObjectIdentifier(original.sampleBuffer), ObjectIdentifier(rebound.sampleBuffer))
        let bytes = originalSource.byteCount + reboundSource.byteCount
            + CMSampleBufferGetTotalSampleSize(original.sampleBuffer)
        var undersized = videoReservoir(bytes: bytes - 1)
        XCTAssertTrue(undersized.append(original).accepted)
        XCTAssertFalse(undersized.append(try evidenceUnit(rebound, sample: rebound.sampleBuffer)).accepted)
        var exact = videoReservoir(bytes: bytes)
        XCTAssertTrue(exact.append(original).accepted)
        XCTAssertTrue(exact.append(rebound).accepted)
        XCTAssertEqual(exact.count, 2)
    }

    func testCompressedVideoBudgetUsesWholeBlockInsteadOfDeclaredSampleSize() throws {
        let original = try videoUnit(id: 1, randomAccess: true)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(original.sampleBuffer))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 1
        var created: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: CMSampleBufferGetFormatDescription(original.sampleBuffer),
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &created), noErr)
        let sample = try XCTUnwrap(created)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 1)
        let unit = CompressedVideoAccessUnit(id: original.id, sampleBuffer: sample,
            generation: original.generation, isRandomAccess: true,
            parserMetadata: original.parserMetadata)
        var subject = videoReservoir(bytes: CMBlockBufferGetDataLength(block) - 1)
        XCTAssertFalse(subject.append(unit).accepted)
    }

    func testCompressedVideoBudgetChargesEntireSourceOwnerForSmallEvidenceSlice() throws {
        let original = try videoUnit(id: 1, randomAccess: true)
        let source = try VideoAccessUnitBacking(identity: .init(
            generation: original.generation, accessUnitID: original.id),
            bytes: Data(repeating: 0xA5, count: 128))
        let slice = try XCTUnwrap(VideoAccessUnitByteRange(offset: 64, length: 1))
        let unit = try CompressedVideoAccessUnit(id: original.id, sampleBuffer: original.sampleBuffer,
            generation: original.generation, isRandomAccess: true,
            parserMetadata: original.parserMetadata, sourceBacking: source, sourceByteRange: slice)
        var subject = videoReservoir(bytes: CMSampleBufferGetTotalSampleSize(unit.sampleBuffer) + slice.length)
        XCTAssertFalse(subject.append(unit).accepted)
    }

    func testCompressedVideoByteOverflowMovesOnlyToFittingRandomAccessSuffix() throws {
        let first = try videoUnit(id: 1, randomAccess: true)
        let ownedBytes = CMSampleBufferGetTotalSampleSize(first.sampleBuffer)
            + (try XCTUnwrap(first.sourceBacking)).byteCount
        var subject = videoReservoir(bytes: ownedBytes * 2)
        XCTAssertTrue(subject.append(first).accepted)
        XCTAssertTrue(subject.append(try videoUnit(id: 2, randomAccess: false)).accepted)
        let mutation = subject.append(try videoUnit(id: 3, randomAccess: true))
        XCTAssertEqual(mutation, .init(accepted: true, droppedCount: 2))
        XCTAssertEqual(subject.map(\.id), [3])
    }

    func testCompressedVideoPopReleasesSourceOwnerBeforeArrayCompaction() throws {
        weak var source: VideoAccessUnitBacking?
        var subject = videoReservoir(bytes: 1_024)
        do {
            let first = try videoUnit(id: 1, randomAccess: true)
            source = first.sourceBacking
            XCTAssertTrue(subject.append(first).accepted)
        }
        XCTAssertTrue(subject.append(try videoUnit(id: 2, randomAccess: false)).accepted)
        do {
            let removed = try XCTUnwrap(subject.popFirst())
            XCTAssertNotNil(source)
            XCTAssertEqual(removed.id, 1)
        }
        XCTAssertNil(source, "A dead FIFO prefix must not retain uncharged payload owners")
        XCTAssertEqual(subject.map(\.id), [2])
    }

    func testCompressedVideoRemovePrefixReleasesEveryRemovedOwner() throws {
        weak var firstSource: VideoAccessUnitBacking?
        weak var secondSource: VideoAccessUnitBacking?
        var subject = videoReservoir(bytes: 1_024)
        do {
            let first = try videoUnit(id: 1, randomAccess: true)
            let second = try videoUnit(id: 2, randomAccess: false)
            firstSource = first.sourceBacking
            secondSource = second.sourceBacking
            XCTAssertTrue(subject.append(first).accepted)
            XCTAssertTrue(subject.append(second).accepted)
        }
        XCTAssertTrue(subject.append(try videoUnit(id: 3, randomAccess: true)).accepted)
        subject.removeFirst(2)
        XCTAssertNil(firstSource)
        XCTAssertNil(secondSource)
        XCTAssertEqual(subject.map(\.id), [3])
    }

    private func videoReservoir(bytes: Int) -> CompressedVideoReservoir {
        CompressedVideoReservoir(limits: .init(maximumCount: 8, maximumOwnedBytes: bytes,
            latestTailHorizon: CMTime(value: 10, timescale: 1)))
    }

    private func evidenceUnit(
        _ original: CompressedVideoAccessUnit, sample: CMSampleBuffer
    ) throws -> CompressedVideoAccessUnit {
        try CompressedVideoAccessUnit(id: original.id, sampleBuffer: sample,
            generation: original.generation, isRandomAccess: false,
            parserMetadata: original.parserMetadata,
            sourceBacking: XCTUnwrap(original.sourceBacking),
            sourceByteRange: XCTUnwrap(original.sourceByteRange))
    }

    func testRejectNewestNeverGrowsPastCapacity() {
        var subject = BoundedMediaQueue<Int>(capacity: 2, overflow: .rejectNewest)

        XCTAssertNil(subject.push(10))
        XCTAssertNil(subject.push(20))
        XCTAssertEqual(subject.push(30), 30)
        XCTAssertEqual(subject.count, 2)
        XCTAssertEqual(subject.elements, [10, 20])
        XCTAssertEqual(subject.popFirst(), 10)
        XCTAssertEqual(subject.popFirst(), 20)
        XCTAssertNil(subject.popFirst())
    }

    func testDropOldestPreservesFIFOOrder() {
        var subject = BoundedMediaQueue<Int>(capacity: 2, overflow: .dropOldest)

        XCTAssertNil(subject.push(10))
        XCTAssertNil(subject.push(20))
        XCTAssertEqual(subject.push(30), 10)
        XCTAssertEqual(subject.elements, [20, 30])
    }

    func testZeroAndNegativeCapacitiesRejectEveryOfferedValue() {
        for requestedCapacity in [0, -1, Int.min] {
            for overflow in [
                BoundedMediaQueue<Int>.Overflow.rejectNewest,
                BoundedMediaQueue<Int>.Overflow.dropOldest,
            ] {
                var subject = BoundedMediaQueue<Int>(
                    capacity: requestedCapacity,
                    overflow: overflow
                )

                XCTAssertEqual(subject.capacity, 0)
                XCTAssertEqual(subject.push(42), 42)
                XCTAssertEqual(subject.count, 0)
                XCTAssertEqual(subject.elements, [])
                XCTAssertNil(subject.popFirst())
            }
        }
    }

    func testCapacityOneHandlesBothOverflowPolicies() {
        var rejecting = BoundedMediaQueue<Int>(capacity: 1, overflow: .rejectNewest)
        var dropping = BoundedMediaQueue<Int>(capacity: 1, overflow: .dropOldest)

        XCTAssertNil(rejecting.push(1))
        XCTAssertEqual(rejecting.push(2), 2)
        XCTAssertEqual(rejecting.elements, [1])

        XCTAssertNil(dropping.push(1))
        XCTAssertEqual(dropping.push(2), 1)
        XCTAssertEqual(dropping.elements, [2])
    }

    func testWrapAroundAndAlternatingPushPopRemainFIFO() {
        var subject = BoundedMediaQueue<Int>(capacity: 3, overflow: .rejectNewest)

        XCTAssertNil(subject.push(1))
        XCTAssertNil(subject.push(2))
        XCTAssertNil(subject.push(3))
        XCTAssertEqual(subject.popFirst(), 1)
        XCTAssertEqual(subject.popFirst(), 2)
        XCTAssertNil(subject.push(4))
        XCTAssertNil(subject.push(5))
        XCTAssertEqual(subject.elements, [3, 4, 5])
        XCTAssertEqual(subject.popFirst(), 3)
        XCTAssertNil(subject.push(6))
        XCTAssertEqual(subject.elements, [4, 5, 6])
    }

    func testOptionalElementCanStoreRealNilWithoutLookingEmpty() {
        var subject = BoundedMediaQueue<Int?>(capacity: 2, overflow: .rejectNewest)

        guard case .none = subject.push(nil) else {
            return XCTFail("queue should accept a nil optional element")
        }
        guard case .none = subject.push(7) else {
            return XCTFail("queue should accept a non-nil optional element")
        }
        XCTAssertEqual(subject.count, 2)
        XCTAssertEqual(subject.elements.count, 2)
        XCTAssertNil(subject.elements[0])
        XCTAssertEqual(subject.elements[1], 7)

        guard case .some(.none) = subject.popFirst() else {
            return XCTFail("stored nil must be returned as an occupied queue element")
        }
        guard case let .some(.some(value)) = subject.popFirst() else {
            return XCTFail("stored non-nil optional must remain present")
        }
        XCTAssertEqual(value, 7)
        guard case .none = subject.popFirst() else {
            return XCTFail("empty optional-element queue must return outer nil")
        }
    }

    func testRemoveAllModesReleaseElementsAndQueueCanBeReused() {
        for keepingCapacity in [true, false] {
            weak var released: QueueToken?
            var subject = BoundedMediaQueue<QueueToken>(capacity: 2, overflow: .rejectNewest)
            do {
                let token = QueueToken()
                released = token
                XCTAssertNil(subject.push(token))
            }

            subject.removeAll(keepingCapacity: keepingCapacity)
            XCTAssertNil(released)
            XCTAssertEqual(subject.count, 0)
            XCTAssertEqual(subject.elements.count, 0)

            let replacement = QueueToken()
            XCTAssertNil(subject.push(replacement))
            XCTAssertTrue(subject.popFirst() === replacement)
        }
    }

    func testQueueIsConditionallySendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(BoundedMediaQueue<Int>.self)
    }

    private func videoUnit(
        id: UInt64,
        randomAccess: Bool
    ) throws -> CompressedVideoAccessUnit {
        try PlaybackFakeMedia.accessUnit(
            id: id,
            generation: MediaGeneration(rawValue: 1),
            randomAccess: randomAccess,
            pts: CMTime(value: Int64(id), timescale: 25)
        )
    }
}

private final class QueueToken: @unchecked Sendable {}
