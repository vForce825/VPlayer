// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class WriterInputLifetimeTests: XCTestCase {
    func testMultiSampleMetadataStillUsesOnePhysicalInputSlot() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = WriterInputAdmission(capacity: 1, maximumBytes: 128, applicationLedger: ledger)
        let lifetime = try admission.admit(bytes: 128, sampleCount: 64)
        defer { lifetime.releaseBacking() }
        XCTAssertEqual(admission.usage.count, 1)
        XCTAssertEqual(admission.usage.bytes, 128)
        XCTAssertEqual(ledger.chargedBytes, WriterInputAdmission.metadataBytes + 63 * 256)
        XCTAssertThrowsError(try admission.admit(bytes: 1))
        lifetime.releaseBacking()
        XCTAssertEqual(admission.usage.count, 0)
        XCTAssertEqual(admission.usage.bytes, 0)
        XCTAssertEqual(admission.releaseCount, 1)
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testLastNativeAliasReleasesInputBudgetExactlyOnce() throws {
        for bytes in [4, 4_033, 8_192, 262_144] {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let inputs = WriterInputAdmission(capacity: 1, maximumBytes: bytes + 64, applicationLedger: ledger)
            let blocks = HLSOwnedBlockAdmission(maximumPayloadBytes: bytes, applicationLedger: ledger)
            var original: CMBlockBuffer? = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                copying: Data(repeating: 0x5a, count: bytes), admission: blocks)
            let charge = ledger.chargedBytes
            var source: CMSampleBuffer? = try sample(block: XCTUnwrap(original), bytes: bytes)
            var wrapped: CMSampleBuffer? = try SampleBufferBuilder.makeWriterInputSample(
                XCTUnwrap(source), lifetime: inputs.admit(bytes: bytes + 64))
            var alias: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithBufferReference(allocator: kCFAllocatorDefault,
                referenceBuffer: try XCTUnwrap(CMSampleBufferGetDataBuffer(try XCTUnwrap(wrapped))), offsetToData: 0,
                dataLength: bytes, flags: 0, blockBufferOut: &alias), noErr)
            XCTAssertEqual(ledger.chargedBytes, charge + WriterInputAdmission.metadataBytes)
            XCTAssertThrowsError(try inputs.admit(bytes: 1))
            original = nil; source = nil; wrapped = nil
            XCTAssertEqual(inputs.usage.count, 1)
            XCTAssertEqual(blocks.usage.count, 1)
            XCTAssertNotNil(alias)
            alias = nil
            XCTAssertEqual(inputs.usage.count, 0)
            XCTAssertEqual(blocks.usage.count, 0)
            XCTAssertEqual(inputs.allocationCount, 1)
            XCTAssertEqual(inputs.releaseCount, 1)
            XCTAssertEqual(ledger.chargedBytes, 0)
            XCTAssertThrowsError(try inputs.admit(bytes: bytes + 65))
        }
    }

    func testSegmentCallbackDoesNotReleaseLiveBacking() throws {
        let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8)
        var block: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: admission.admit(bytes: 4))
        let evidence = WriterSegmentEvidence(sampleCapacity: 1)
        let identity = SegmentBoundarySampleIdentity.aac(sample: ObjectIdentifier(try XCTUnwrap(block)),
            presentationStart: try ExactMediaTime(.zero), format: ObjectIdentifier(try XCTUnwrap(block)), digest: Data([1]))
        try evidence.record(sequence: 0, sample: identity, pts: ExactMediaTime(.zero), dts: nil,
            duration: ExactMediaTime(CMTime(value: 1, timescale: 50)), projectedBytes: 4)
        try evidence.retireVerified(sequence: 0)
        XCTAssertEqual(evidence.sampleCount, 0)
        XCTAssertEqual(admission.usage.count, 1)
        block = nil
        XCTAssertEqual(admission.releaseCount, 1)
    }

    func testRejectedAppendAndConstructionFailureReleaseExactlyOnce() throws {
        for mode in HLSOwnedBlockAdmission.ConstructionMode.allCases where mode != .normal {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let inputs = WriterInputAdmission(capacity: 1, maximumBytes: 8_256, applicationLedger: ledger)
            let blocks = HLSOwnedBlockAdmission(maximumPayloadBytes: 8_192,
                applicationLedger: ledger, constructionMode: mode)
            let lifetime = try inputs.admit(bytes: 8_256)
            XCTAssertThrowsError(try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                copying: Data(repeating: 0x5a, count: 8_192), admission: blocks, inputLifetime: lifetime))
            lifetime.releaseBacking()
            XCTAssertEqual(inputs.releaseCount, 1)
            XCTAssertEqual(inputs.usage.count, 0)
            XCTAssertEqual(blocks.usage.count, 0)
            XCTAssertEqual(ledger.chargedBytes, 0)
        }
    }

    func testPrepaidConstructionFailureReturnsInputBudgetExactlyOnce() throws {
        for mode in HLSOwnedBlockAdmission.ConstructionMode.allCases where mode != .normal {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8_256, applicationLedger: ledger)
            let lifetime = try admission.admit(bytes: 8_256)
            XCTAssertThrowsError(try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(length: 8_192,
                lifetime: lifetime, constructionMode: mode))
            XCTAssertEqual(admission.usage.count, 0)
            XCTAssertEqual(admission.releaseCount, 1)
            XCTAssertEqual(ledger.chargedBytes, 0)
            lifetime.releaseBacking()
            XCTAssertEqual(admission.releaseCount, 1)
        }
    }

    func testFreeCallbackCannotRetainWriter() throws {
        var owner: WriterInputTestOwner? = WriterInputTestOwner()
        let weakOwner = TestWeakReference(owner)
        let admission = try XCTUnwrap(owner).admission
        var block: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: admission.admit(bytes: 4))
        owner = nil
        XCTAssertNil(weakOwner.value)
        XCTAssertEqual(admission.usage.count, 1)
        XCTAssertNotNil(block)
        block = nil
        XCTAssertEqual(admission.usage.count, 0)
        XCTAssertEqual(admission.releaseCount, 1)
    }

    func testEvidence320PlusOneAndPrepaidRollback() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let evidence = WriterSegmentEvidence(sampleCapacity: 320, applicationLedger: ledger)
        let object = NSObject()
        let identity = SegmentBoundarySampleIdentity.aac(sample: ObjectIdentifier(object),
            presentationStart: try ExactMediaTime(.zero), format: ObjectIdentifier(object), digest: Data([1]))
        for _ in 0..<320 {
            try evidence.record(sequence: 0, sample: identity, pts: ExactMediaTime(.zero), dts: nil,
                duration: ExactMediaTime(CMTime(value: 1, timescale: 50)), projectedBytes: 4)
        }
        XCTAssertEqual(ledger.chargedBytes, 320 * 1_024)
        XCTAssertThrowsError(try evidence.record(sequence: 0, sample: identity, pts: ExactMediaTime(.zero),
            dts: nil, duration: ExactMediaTime(CMTime(value: 1, timescale: 50)), projectedBytes: 4))
        try evidence.retireVerified(sequence: 0)
        var pending: WriterSegmentEvidence.Reservation? = try evidence.reserve(sequence: 1,
            sample: identity, pts: ExactMediaTime(.zero), dts: nil,
            duration: ExactMediaTime(CMTime(value: 1, timescale: 50)), projectedBytes: 4)
        XCTAssertNotNil(pending)
        XCTAssertEqual(evidence.sampleCount, 0)
        XCTAssertEqual(ledger.chargedBytes, 1_024)
        pending = nil
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    private func sample(block: CMBlockBuffer, bytes: Int) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 50),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = bytes
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

private final class WriterInputTestOwner {
    let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8)
}
