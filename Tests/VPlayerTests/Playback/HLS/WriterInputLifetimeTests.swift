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
        XCTAssertEqual(ledger.chargedBytes, WriterInputAdmission.metadataBytes
            + 63 * WriterInputAdmission.additionalSampleMetadataBytes)
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
            let clock = WriterInputObservationClock()
            let probe = HLSWriterAcceptanceProbe(now: { clock.now })
            let inputs = WriterInputAdmission(capacity: 1, maximumBytes: bytes + 64,
                applicationLedger: ledger, observation: try observation(probe, rendition: 1, maximumBytes: bytes + 64))
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
            clock.advance(by: .milliseconds(1_250))
            XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 0)
            XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 0)
            XCTAssertNotNil(alias)
            alias = nil
            XCTAssertEqual(inputs.usage.count, 0)
            XCTAssertEqual(blocks.usage.count, 0)
            XCTAssertEqual(inputs.allocationCount, 1)
            XCTAssertEqual(inputs.releaseCount, 1)
            XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, inputs.releaseCount)
            XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 1.25, accuracy: 0.000_001)
            XCTAssertEqual(clock.readCount, 2, "Only successful admission and actual release read the diagnostic clock")
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
            let clock = WriterInputObservationClock()
            let probe = HLSWriterAcceptanceProbe(now: { clock.now })
            let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8_256,
                applicationLedger: ledger, observation: try observation(probe, rendition: 1, maximumBytes: 8_256))
            let lifetime = try admission.admit(bytes: 8_256)
            clock.advance(by: .milliseconds(375))
            XCTAssertThrowsError(try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(length: 8_192,
                lifetime: lifetime, constructionMode: mode))
            XCTAssertEqual(admission.usage.count, 0)
            XCTAssertEqual(admission.releaseCount, 1)
            XCTAssertEqual(ledger.chargedBytes, 0)
            XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 1)
            XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 0.375, accuracy: 0.000_001)
            clock.advance(by: .seconds(10))
            lifetime.releaseBacking()
            XCTAssertEqual(admission.releaseCount, 1)
            XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 1)
            XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 0.375, accuracy: 0.000_001)
            XCTAssertEqual(clock.readCount, 2, "Repeated release cannot add a residence observation")
        }
    }

    func testResidenceIncludesLateOldAliasAndSeparatesRenditions() throws {
        let clock = WriterInputObservationClock()
        let probe = HLSWriterAcceptanceProbe(now: { clock.now })
        let oldInputs = WriterInputAdmission(capacity: 1, maximumBytes: 8,
            observation: try observation(probe, rendition: 1, writer: 1))
        var old: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: oldInputs.admit(bytes: 4))
        clock.advance(by: .seconds(10))
        let successorInputs = WriterInputAdmission(capacity: 1, maximumBytes: 8,
            observation: try observation(probe, rendition: 1, writer: 2))
        var successor: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: successorInputs.admit(bytes: 4))
        let otherInputs = WriterInputAdmission(capacity: 1, maximumBytes: 8,
            observation: try observation(probe, rendition: 2))
        var other: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: otherInputs.admit(bytes: 4))
        XCTAssertNotNil(old); XCTAssertNotNil(successor); XCTAssertNotNil(other)
        clock.advance(by: .seconds(2))
        successor = nil
        clock.advance(by: .seconds(1))
        other = nil
        let beforeLastRelease = probe.snapshot
        XCTAssertEqual(beforeLastRelease.liveInputCount, 1)
        XCTAssertEqual(beforeLastRelease.releasedInputResidenceCount, 2)
        XCTAssertEqual(beforeLastRelease.maximumReleasedInputResidenceSeconds, 3)
        oldInputs.cancel()
        XCTAssertEqual(probe.snapshot, beforeLastRelease, "Cancellation is not a backing release")
        clock.advance(by: .seconds(300))
        old = nil
        let final = probe.snapshot
        XCTAssertEqual(final.liveInputCount, 0)
        XCTAssertEqual(final.acceptedInputCount, 3)
        XCTAssertEqual(final.releasedInputResidenceCount, 3)
        XCTAssertEqual(final.releasedInputResidenceCount, final.releasedInputCount)
        XCTAssertEqual(final.maximumReleasedInputResidenceSeconds, 313)
        let renditions = probe.renditions.sorted { $0.renditionIdentity.rawValue < $1.renditionIdentity.rawValue }
        XCTAssertEqual(renditions.count, 2)
        XCTAssertEqual(renditions[0].latestWriterIdentity.rawValue, 2)
        XCTAssertEqual(renditions[0].usage.releasedInputResidenceCount, 2)
        XCTAssertEqual(renditions[0].usage.maximumReleasedInputResidenceSeconds, 313)
        XCTAssertEqual(renditions[1].usage.releasedInputResidenceCount, 1)
        XCTAssertEqual(renditions[1].usage.maximumReleasedInputResidenceSeconds, 3)
        XCTAssertEqual(clock.readCount, 6)
    }

    func testResidenceStopsAtReleaseBodyEntryBeforeDownstreamReleaseWork() throws {
        let clock = WriterInputObservationClock()
        let probe = HLSWriterAcceptanceProbe(now: { clock.now })
        let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8,
            observation: try observation(probe, rendition: 1))
        let lifetime = try admission.admit(bytes: 4, release: { clock.advance(by: .seconds(10)) })
        clock.advance(by: .milliseconds(250))
        lifetime.releaseBacking()
        XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 1)
        XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 0.25)
        XCTAssertEqual(clock.readCount, 2)
    }

    func testUnadoptedLifetimeDeinitObservesRollbackAndFitsMetadataEnvelope() throws {
        let clock = WriterInputObservationClock()
        let probe = HLSWriterAcceptanceProbe(now: { clock.now })
        let admission = WriterInputAdmission(capacity: 1, maximumBytes: 8,
            observation: try observation(probe, rendition: 1))
        var lifetime: WriterInputLifetime? = try admission.admit(bytes: 4)
        XCTAssertNotNil(lifetime)
        clock.advance(by: .milliseconds(500))
        lifetime = nil
        XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 1)
        XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, admission.releaseCount)
        XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 0.5)
        XCTAssertEqual(clock.readCount, 2)
        // The only new per-input capture is an optional value, not an owner/map.
        // Its ABI-sized storage fits within the existing conservative 8 KiB charge.
        XCTAssertLessThanOrEqual(MemoryLayout<ContinuousClock.Instant?>.stride, 32)
        XCTAssertEqual(WriterInputAdmission.metadataBytes, 8_192)
    }

    func testFreeCallbackCannotRetainWriter() throws {
        let clock = WriterInputObservationClock()
        let probe = HLSWriterAcceptanceProbe(now: { clock.now })
        var owner: WriterInputTestOwner? = WriterInputTestOwner(observation: try observation(probe, rendition: 1))
        let weakOwner = TestWeakReference(owner)
        let admission = try XCTUnwrap(owner).admission
        var block: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: admission.admit(bytes: 4))
        owner = nil
        XCTAssertNil(weakOwner.value)
        XCTAssertEqual(admission.usage.count, 1)
        XCTAssertNotNil(block)
        clock.advance(by: .seconds(2))
        block = nil
        XCTAssertEqual(admission.usage.count, 0)
        XCTAssertEqual(admission.releaseCount, 1)
        XCTAssertEqual(probe.snapshot.releasedInputResidenceCount, 1)
        XCTAssertEqual(probe.snapshot.maximumReleasedInputResidenceSeconds, 2)
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

    private func observation(_ probe: HLSWriterAcceptanceProbe, rendition: UInt64,
                             writer: UInt64 = 1, maximumBytes: Int = 8) throws -> HLSWriterAcceptanceProbe.Rendition {
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let binding = FMP4WriterBinding(outputLifecycleEpoch: .init(backendIdentity:
            .init(sessionIdentity: session, backendGeneration: 1), outputNonce: 1),
            itemGeneration: .init(rawValue: 1), mediaEpoch: .init(rawValue: 1),
            publicationParticipantID: .init(rawValue: 1), renditionIdentity: .init(rawValue: rendition),
            writerIdentity: .init(rawValue: writer))
        return try XCTUnwrap(probe.register(binding: binding, hardInputCount: 1,
            hardInputBytes: maximumBytes, hardEvidenceCount: 1, hardCallbackCount: 1))
    }
}

private final class WriterInputObservationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var reads = 0
    var now: ContinuousClock.Instant { lock.withLock { reads += 1; return instant } }
    var readCount: Int { lock.withLock { reads } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private final class WriterInputTestOwner {
    let admission: WriterInputAdmission
    init(observation: HLSWriterAcceptanceProbe.Rendition) {
        admission = WriterInputAdmission(capacity: 1, maximumBytes: 8, observation: observation)
    }
}
