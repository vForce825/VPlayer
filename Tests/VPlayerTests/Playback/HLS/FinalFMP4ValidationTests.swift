// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import VPlayerPlayback

final class FinalFMP4ValidationTests: XCTestCase {
    func testSyntheticLegalReportCannotSignReceiptAndRealReportRetriesSameSequence() async throws {
        let collector = Task18ObjectCollector()
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: .zero, videoMode: .passthrough))
        let fixture = try Task18Fixtures.realH264Sample()
        let relay = SegmentReportRelay(binding: Task18Fixtures.binding, limits: .video, capacity: 8, objectSink: collector.append)
        let writer = try SegmentedFMP4Writer(binding: Task18Fixtures.binding, trackKind: .video,
            sourceFormatHint: fixture.format, boundarySession: boundary.session, compressedFormatConfiguration: nil,
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        let output = Task18Fixtures.videoOutput(fixture.sample)
        try writer.start(at: .zero)
        try writer.appendVideo(output, ticket: boundary.issueVideoAppend(for: output, writerBinding: writer.binding))
        _ = try await writer.finish()
        let initialization = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let real = try XCTUnwrap(collector.objects.first { $0.kind == .media })
        let actualReport = try XCTUnwrap(real.report.systemReport)
        let track = try XCTUnwrap(actualReport.trackReports.first)
        let syntheticReport = Task18Fixtures.report(tracks: [.init(
            start: track.earliestPresentationTimeStamp, duration: track.duration)])
        XCTAssertNil(syntheticReport.systemReport)
        XCTAssertEqual(syntheticReport.earliestPresentationTimeStamp, real.report.earliestPresentationTimeStamp)
        XCTAssertEqual(syntheticReport.duration, real.report.duration)
        let extracted = try FMP4PresentationRange.inspect(report: syntheticReport, mediaType: .video)
        XCTAssertEqual(extracted.duration, ExactMediaTime(value: 1, timescale: 24))
        let synthetic = Task18Fixtures.object(bytes: real.bytes, report: syntheticReport)
        let proof = try FinalFMP4Validator(binding: writer.binding, mediaType: .video).validateInitialization(initialization)
        let timeline = SegmentTimelineValidator(proof: proof)
        let before = timeline.state
        XCTAssertThrowsError(try timeline.validate(synthetic, using: proof), "合法 synthetic 时间不能成为系统来源")
        XCTAssertEqual(timeline.state, before, "失败不能推进序号或上一结束时间")
        XCTAssertNoThrow(try timeline.validate(real, using: proof), "同一期望序号仍可由真实 report 成功提交")
        XCTAssertEqual(timeline.state.nextLogicalSequence, 1)
        XCTAssertEqual(timeline.state.previousEnd, ExactMediaTime(value: 1, timescale: 24))
        let provenance = try XCTUnwrap(real.report.systemProvenance)
        XCTAssertTrue(provenance.accepts(reference: real.report, mediaType: .video))
        XCTAssertFalse(provenance.accepts(reference: real.report, mediaType: .audio))
        let rawRealEvidence = SegmentedFMP4SystemReportEvidence.from(systemReport: actualReport, mediaType: .video)
        let substitutedReports = [
            SegmentReportReference(evidence: rawRealEvidence),
            SegmentReportReference(evidence: .init(attesting: rawRealEvidence, provenance: provenance)),
            SegmentReportReference(evidence: .init(attesting: .reading(Task18FakeReport(tracks: [.init(
                start: .zero, duration: CMTime(value: 1, timescale: 1))]), mediaType: .video), provenance: provenance)),
            SegmentReportReference(evidence: .init(attesting: .from(systemReport: actualReport, mediaType: .audio), provenance: provenance)),
        ]
        for report in substitutedReports {
            XCTAssertNil(report.systemProvenance)
            XCTAssertFalse(provenance.accepts(reference: report, mediaType: .video))
            let fresh = SegmentTimelineValidator(proof: proof)
            let before = fresh.state
            XCTAssertThrowsError(try fresh.validate(Task18Fixtures.object(bytes: real.bytes, report: report), using: proof))
            XCTAssertEqual(fresh.state, before)
            XCTAssertNoThrow(try fresh.validate(real, using: proof))
        }
        let wrongTypeProof = try FinalFMP4Validator(binding: writer.binding, mediaType: .audio).validateInitialization(initialization)
        let wrongTypeTimeline = SegmentTimelineValidator(proof: wrongTypeProof)
        XCTAssertThrowsError(try wrongTypeTimeline.validate(real, using: wrongTypeProof))
        XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(try XCTUnwrap(real.publicationLease)))
    }

    // 删除完整扫描、误拒未知顶级 box 或复制 backing 都会破坏本例。
    func testInitializationAcceptsCompleteUnknownExtendedAndFinalZeroSizedBoxes() throws {
        let fixtures = [
            Task18Fixtures.initialization,
            Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65]) + Task18Fixtures.initialization,
            Data([0, 0, 0, 1, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0, 0, 0, 0, 16,
                  0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x76]),
            Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0, 0x6d, 0x6f, 0x6f, 0x76]),
            Task18Fixtures.initialization + Task18Fixtures.initialization,
        ]
        for bytes in fixtures {
            let object = Task18Fixtures.object(kind: .initialization, bytes: bytes)
            let validator = FinalFMP4Validator(binding: object.binding, mediaType: .video)
            let proof = try validator.validateInitialization(object)
            XCTAssertTrue(proof.matches(initialization: object))
            XCTAssertEqual(proof.initializationIdentity.backingIdentity, object.backing.identity)
            XCTAssertEqual(proof.initializationIdentity.byteRange, object.byteRange)
            XCTAssertEqual(proof.initializationIdentity.digest.bytes, object.digest)
            XCTAssertEqual(proof.initializationIdentity.reportIdentity, object.report.identity)
            XCTAssertThrowsError(try validator.validateInitialization(object))
        }
    }

    func testMediaAcceptsMinimalExtendedAndFinalZeroSizedBoxesWithExactRange() throws {
        let fixtures = [
            Task18Fixtures.media,
            Data([0, 0, 0, 1, 0x6d, 0x6f, 0x6f, 0x66, 0, 0, 0, 0, 0, 0, 0, 16,
                  0, 0, 0, 8, 0x6d, 0x64, 0x61, 0x74]),
            Data([0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x66, 0, 0, 0, 0, 0x6d, 0x64, 0x61, 0x74, 7]),
            Task18Fixtures.media + Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65]),
        ]
        for bytes in fixtures {
            let harness = try FinalFMP4ValidationTestHarness()
            let object = Task18Fixtures.object(bytes: bytes, start: CMTime(value: 10, timescale: 3),
                                               duration: CMTime(value: 2, timescale: 3))
            let receipt = try harness.timeline.validate(object, using: harness.proof)
            XCTAssertEqual(receipt.presentationRange.start, ExactMediaTime(value: 10, timescale: 3))
            XCTAssertEqual(receipt.presentationRange.duration, ExactMediaTime(value: 2, timescale: 3))
            XCTAssertEqual(receipt.presentationRange.end, ExactMediaTime(value: 4, timescale: 1))
            XCTAssertTrue(receipt.matches(media: object, proof: harness.proof))
        }
    }

    // 字面值只破坏顶级边界，不解释 moov/moof 内部字段。
    func testTopLevelBoxFailureTableRejectsTruncationOverflowMissingKindsAndHiddenHeaders() throws {
        let common: [(String, Data)] = [
            ("空", Data()),
            ("七字节标头", Data([0, 0, 0, 8, 0x66, 0x72, 0x65])),
            ("小于标头", Data([0, 0, 0, 7, 0x66, 0x72, 0x65, 0x65])),
            ("超过剩余", Data([0, 0, 0, 9, 0x66, 0x72, 0x65, 0x65])),
            ("扩展标头截断", Data([0, 0, 0, 1, 0x66, 0x72, 0x65, 0x65, 0, 0, 0, 0, 0, 0, 0])),
            ("扩展长度过小", Data([0, 0, 0, 1, 0x66, 0x72, 0x65, 0x65, 0, 0, 0, 0, 0, 0, 0, 15])),
            ("扩展长度溢出", Data([0, 0, 0, 1, 0x66, 0x72, 0x65, 0x65, 255, 255, 255, 255, 255, 255, 255, 255])),
            ("扩展长度超过剩余", Data([0, 0, 0, 1, 0x66, 0x72, 0x65, 0x65, 0, 0, 0, 0, 0, 0, 0, 17])),
        ]
        for kind in [SealedMediaObjectKind.initialization, .media] {
            let valid = kind == .initialization ? Task18Fixtures.initialization : Task18Fixtures.media
            let wrong = kind == .initialization ? Task18Fixtures.media : Task18Fixtures.initialization
            let cases = common + [
                ("少一字节", Data(valid.dropLast())),
                ("完整后尾部垃圾", valid + Data([0xff])),
                ("关键box缺失", Data(valid.prefix(8))),
                ("对象种类互换", wrong),
                ("完整后坏标头", valid + Data([0, 0, 0, 7, 0x66, 0x72, 0x65, 0x65])),
                // size 0 吞掉其后的字节；其中伪装的关键标头不能被当成另一顶级 box。
                ("非末尾size0隐藏关键box", Data([0, 0, 0, 0, 0x66, 0x72, 0x65, 0x65]) + valid),
            ]
            for (name, bytes) in cases {
                let harness = try FinalFMP4ValidationTestHarness()
                let object = Task18Fixtures.object(kind: kind, bytes: bytes)
                let before = harness.timeline.state
                if kind == .initialization {
                    let validator = FinalFMP4Validator(binding: object.binding, mediaType: .video)
                    XCTAssertThrowsError(try validator.validateInitialization(object), name)
                    XCTAssertNoThrow(try validator.validateInitialization(harness.initialization), name)
                } else {
                    XCTAssertThrowsError(try harness.timeline.validate(object, using: harness.proof), name)
                    XCTAssertEqual(harness.timeline.state, before, name)
                    XCTAssertNoThrow(try harness.timeline.validate(Task18Fixtures.object(), using: harness.proof), name)
                }
            }
        }
    }

    func testProofAndReceiptRejectEveryIdentityReplacementAndSameBytesNewBacking() throws {
        let harness = try FinalFMP4ValidationTestHarness()
        let media = Task18Fixtures.object()
        let receipt = try harness.timeline.validate(media, using: harness.proof)
        for (name, identity) in try Task18Fixtures.identityMutations(harness.initialization) {
            XCTAssertFalse(harness.proof.matches(initializationIdentity: identity), name)
        }
        for (name, identity) in try Task18Fixtures.identityMutations(media) {
            XCTAssertFalse(receipt.matches(mediaIdentity: identity, proof: harness.proof), name)
        }
        let copiedInit = Task18Fixtures.object(kind: .initialization, report: harness.initialization.report)
        let copiedMedia = Task18Fixtures.object(report: media.report)
        XCTAssertEqual(copiedInit.digest, harness.initialization.digest)
        XCTAssertEqual(copiedMedia.digest, media.digest)
        XCTAssertFalse(harness.proof.matches(initialization: copiedInit))
        XCTAssertFalse(receipt.matches(media: copiedMedia, proof: harness.proof))
        let otherIssuer = FinalFMP4Validator(binding: harness.initialization.binding, mediaType: .video)
        let otherProof = try otherIssuer.validateInitialization(harness.initialization)
        XCTAssertNotEqual(harness.proof.identity, otherProof.identity)
        XCTAssertFalse(receipt.matches(media: media, proof: otherProof))
        let next = Task18Fixtures.object(sequence: 1, start: CMTime(value: 1, timescale: 1))
        let before = harness.timeline.state
        XCTAssertThrowsError(try harness.timeline.validate(next, using: otherProof))
        XCTAssertEqual(harness.timeline.state, before)
        XCTAssertNoThrow(try harness.timeline.validate(next, using: harness.proof))
    }

    func testObjectBindingKindAndWriterFailuresNeverAdvanceInitializationOrTimeline() throws {
        for binding in Task18Fixtures.bindingMutations() {
            let harness = try FinalFMP4ValidationTestHarness()
            let validator = FinalFMP4Validator(binding: Task18Fixtures.binding, mediaType: .video)
            XCTAssertThrowsError(try validator.validateInitialization(Task18Fixtures.object(kind: .initialization, binding: binding)))
            XCTAssertNoThrow(try validator.validateInitialization(harness.initialization))
            let before = harness.timeline.state
            XCTAssertThrowsError(try harness.timeline.validate(Task18Fixtures.object(binding: binding), using: harness.proof))
            XCTAssertEqual(harness.timeline.state, before)
            XCTAssertNoThrow(try harness.timeline.validate(Task18Fixtures.object(), using: harness.proof))
        }
        for kind in [SealedMediaObjectKind.initialization, .media] {
            let harness = try FinalFMP4ValidationTestHarness()
            let wrongWriter = Task18Fixtures.object(kind: kind, writer: .init(rawValue: 999))
            if kind == .initialization {
                let validator = FinalFMP4Validator(binding: Task18Fixtures.binding, mediaType: .video)
                XCTAssertThrowsError(try validator.validateInitialization(wrongWriter))
                XCTAssertThrowsError(try validator.validateInitialization(Task18Fixtures.object()))
            } else {
                XCTAssertThrowsError(try harness.timeline.validate(wrongWriter, using: harness.proof))
                XCTAssertThrowsError(try harness.timeline.validate(harness.initialization, using: harness.proof))
            }
        }
    }

    func testMissingAmbiguousAndInvalidReportTimeTableFailsClosedWithoutStateMutation() throws {
        let good = Task18FakeTrack(start: .zero, duration: CMTime(value: 1, timescale: 1))
        let reports: [(String, SegmentReportReference)] = [
            ("无report", Task18Fixtures.report(tracks: nil)),
            ("空report", Task18Fixtures.report(tracks: [])),
            ("无匹配轨道", Task18Fixtures.report(tracks: [.init(mediaType: .audio, start: .zero, duration: CMTime(value: 1, timescale: 1))])),
            ("重复匹配轨道", Task18Fixtures.report(tracks: [good, good])),
            ("单轨writer收到多轨report", Task18Fixtures.report(tracks: [good, .init(mediaType: .audio, start: .zero, duration: CMTime(value: 1, timescale: 1))])),
            ("调用者只自报earliest", SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: .zero))),
        ]
        let badTimes: [(String, CMTime, CMTime)] = [
            ("start invalid", .invalid, CMTime(value: 1, timescale: 1)),
            ("start indefinite", .indefinite, CMTime(value: 1, timescale: 1)),
            ("start infinity", .positiveInfinity, CMTime(value: 1, timescale: 1)),
            ("start negative", CMTime(value: -1, timescale: 1), CMTime(value: 1, timescale: 1)),
            ("start epoch", CMTime(value: 0, timescale: 1, flags: .valid, epoch: 1), CMTime(value: 1, timescale: 1)),
            ("duration invalid", .zero, .invalid),
            ("duration indefinite", .zero, .indefinite),
            ("duration infinity", .zero, .positiveInfinity),
            ("duration zero", .zero, .zero),
            ("duration negative", .zero, CMTime(value: -1, timescale: 1)),
            ("duration epoch", .zero, CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)),
            ("end overflow", CMTime(value: Int64.max, timescale: 1), CMTime(value: 1, timescale: 1)),
            ("timescale overflow", CMTime(value: 1, timescale: Int32.max), CMTime(value: 1, timescale: Int32.max - 1)),
        ]
        let all = reports + badTimes.map { ($0.0, Task18Fixtures.report(tracks: [.init(start: $0.1, duration: $0.2)])) }
        for (name, report) in all {
            let harness = try FinalFMP4ValidationTestHarness()
            let before = harness.timeline.state
            // 保留事实解析自身的坏时间/溢出分支覆盖，不能仅因来源资格缺失而提前返回。
            XCTAssertThrowsError(try FMP4PresentationRange.inspect(report: report, mediaType: .video), name)
            XCTAssertThrowsError(try harness.timeline.validate(Task18Fixtures.object(report: report), using: harness.proof), name)
            XCTAssertEqual(harness.timeline.state, before, name)
            XCTAssertNoThrow(try harness.timeline.validate(Task18Fixtures.object(), using: harness.proof), name)
        }
    }

    func testExactContinuityRejectsDuplicateGapOverlapAndAllowsCorrectedSequenceRetry() throws {
        let harness = try FinalFMP4ValidationTestHarness()
        let first = Task18Fixtures.object(start: CMTime(value: 10, timescale: 3), duration: CMTime(value: 2, timescale: 3))
        _ = try harness.timeline.validate(first, using: harness.proof)
        let failures = [
            first,
            Task18Fixtures.object(sequence: 2, start: CMTime(value: 4, timescale: 1)),
            Task18Fixtures.object(sequence: 1, start: CMTime(value: 2_399, timescale: 600)),
            Task18Fixtures.object(sequence: 1, start: CMTime(value: 2_401, timescale: 600)),
            Task18Fixtures.object(sequence: 1, start: CMTime(value: 4, timescale: 1), duration: .zero),
        ]
        let before = harness.timeline.state
        for object in failures {
            XCTAssertThrowsError(try harness.timeline.validate(object, using: harness.proof))
            XCTAssertEqual(harness.timeline.state, before)
        }
        let second = Task18Fixtures.object(sequence: 1, start: CMTime(value: 192_000, timescale: 48_000), duration: CMTime(value: 1, timescale: 3))
        let secondReceipt = try harness.timeline.validate(second, using: harness.proof)
        XCTAssertEqual(secondReceipt.presentationRange.end, ExactMediaTime(value: 13, timescale: 3))
        let third = Task18Fixtures.object(sequence: 2, start: CMTime(value: 13, timescale: 3), duration: CMTime(value: 2, timescale: 3))
        let thirdReceipt = try harness.timeline.validate(third, using: harness.proof)
        XCTAssertEqual(thirdReceipt.logicalSequence, 2)
        XCTAssertEqual(harness.timeline.state.nextLogicalSequence, 3)
        XCTAssertEqual(harness.timeline.state.previousEnd, ExactMediaTime(value: 5, timescale: 1))
        let exhausted = SegmentTimelineValidator(proof: harness.proof, firstLogicalSequence: UInt64.max)
        let exhaustedBefore = exhausted.state
        XCTAssertThrowsError(try exhausted.validate(Task18Fixtures.object(sequence: UInt64.max), using: harness.proof))
        XCTAssertEqual(exhausted.state, exhaustedBefore)
    }

    func testConcurrentSameSequenceSignsExactlyOneReceipt() throws {
        let harness = try FinalFMP4ValidationTestHarness()
        let object = Task18Fixtures.object()
        let receipts = Task18ReceiptCollector()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let receipt = try? harness.timeline.validate(object, using: harness.proof) { receipts.append(receipt) }
        }
        XCTAssertEqual(receipts.values.count, 1)
        XCTAssertEqual(harness.timeline.state.nextLogicalSequence, 1)
        XCTAssertEqual(harness.timeline.state.previousEnd, ExactMediaTime(value: 1, timescale: 1))
        XCTAssertTrue(try XCTUnwrap(receipts.values.first).matches(media: object, proof: harness.proof))
    }

    func testCloseIsIdempotentAndRacingOrLateValidationCannotReopenAdmission() throws {
        let initialization = Task18Fixtures.object(kind: .initialization)
        let closed = FinalFMP4Validator(binding: initialization.binding, mediaType: .video)
        closed.close()
        closed.close()
        XCTAssertThrowsError(try closed.validateInitialization(initialization))
        for _ in 0..<32 {
            let harness = try FinalFMP4ValidationTestHarness()
            let object = Task18Fixtures.object()
            let receipts = Task18ReceiptCollector()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index.isMultiple(of: 2) { harness.timeline.close() }
                else if let receipt = try? harness.timeline.validate(object, using: harness.proof) { receipts.append(receipt) }
            }
            XCTAssertLessThanOrEqual(receipts.values.count, 1)
            XCTAssertTrue(harness.timeline.state.isClosed)
            XCTAssertEqual(harness.timeline.state.nextLogicalSequence, UInt64(receipts.values.count))
            let after = harness.timeline.state
            harness.timeline.close()
            XCTAssertEqual(harness.timeline.state, after)
            XCTAssertThrowsError(try harness.timeline.validate(object, using: harness.proof))
            XCTAssertThrowsError(try harness.timeline.validate(Task18Fixtures.object(sequence: 1), using: harness.proof))
            if let receipt = receipts.values.first { XCTAssertTrue(receipt.matches(media: object, proof: harness.proof)) }
        }
    }

    func testLongTimelineKeepsFixedStateAndCredentialsDoNotRetainBackingOrReport() throws {
        let harness = try FinalFMP4ValidationTestHarness()
        weak var lastBacking: SealedMediaBacking?
        weak var lastReport: SegmentReportReference?
        var lastReceipt: SegmentValidationReceipt?
        let stateSize = MemoryLayout.size(ofValue: harness.timeline.state)
        for sequence in UInt64(0)..<2_048 {
            try autoreleasepool {
                let object = Task18Fixtures.object(sequence: sequence, start: CMTime(value: Int64(sequence), timescale: 1))
                lastBacking = object.backing
                lastReport = object.report
                lastReceipt = try harness.timeline.validate(object, using: harness.proof)
                XCTAssertThrowsError(try harness.timeline.validate(object, using: harness.proof))
            }
        }
        XCTAssertNil(lastBacking)
        XCTAssertNil(lastReport)
        XCTAssertNotNil(lastReceipt)
        XCTAssertEqual(harness.timeline.state.nextLogicalSequence, 2_048)
        XCTAssertEqual(harness.timeline.state.previousEnd, ExactMediaTime(value: 2_048, timescale: 1))
        XCTAssertEqual(MemoryLayout.size(ofValue: harness.timeline.state), stateSize)
        XCTAssertLessThanOrEqual(MemoryLayout<EpochFormatProof>.stride, 512)
        XCTAssertLessThanOrEqual(MemoryLayout<SegmentValidationReceipt>.stride, 128)
        print("Task18 凭据布局：proof=\(MemoryLayout<EpochFormatProof>.size)/\(MemoryLayout<EpochFormatProof>.stride)，receipt=\(MemoryLayout<SegmentValidationReceipt>.size)/\(MemoryLayout<SegmentValidationReceipt>.stride)，state=\(stateSize)")
        weak var weakInitBacking: SealedMediaBacking?
        weak var weakInitReport: SegmentReportReference?
        weak var weakValidator: FinalFMP4Validator?
        weak var weakTimeline: SegmentTimelineValidator?
        var heldProof: EpochFormatProof?
        try autoreleasepool {
            let object = Task18Fixtures.object(kind: .initialization)
            weakInitBacking = object.backing
            weakInitReport = object.report
            let validator = FinalFMP4Validator(binding: object.binding, mediaType: .video)
            heldProof = try validator.validateInitialization(object)
            let timeline = SegmentTimelineValidator(proof: try XCTUnwrap(heldProof))
            weakValidator = validator
            weakTimeline = timeline
        }
        XCTAssertNotNil(heldProof)
        XCTAssertNil(weakInitBacking)
        XCTAssertNil(weakInitReport)
        XCTAssertNil(weakValidator)
        XCTAssertNil(weakTimeline)
    }

    func testValidationDoesNotConsumePublicationLeaseOnSuccessOrFailure() throws {
        let harness = try FinalFMP4ValidationTestHarness()
        let collector = Task18ObjectCollector()
        let relay = SegmentReportRelay(binding: Task18Fixtures.binding, limits: .video, capacity: 8, objectSink: collector.append)
        for sequence in UInt64(0)...1 {
            let bytes = sequence == 0 ? Task18Fixtures.media : Data([1])
            let ticket = try relay.reserve(kind: .media, logicalSequence: sequence, projectedByteCount: bytes.count)
            let result = relay.receive(SegmentCallbackDelivery(binding: Task18Fixtures.binding,
                writerIdentity: Task18Fixtures.binding.writerIdentity, ticket: ticket, logicalSequence: sequence,
                kind: .media, bytes: bytes as NSData, report: Task18Fixtures.qualifiedReport(start: .zero, duration: CMTime(value: 1, timescale: 1))))
            guard case let .accepted(acceptance) = result else { return XCTFail("relay 未接纳 fixture") }
            XCTAssertTrue(relay.consumePublication(acceptance) { $0() })
        }
        let before = relay.usage
        let objects = collector.objects
        _ = try harness.timeline.validate(objects[0], using: harness.proof)
        XCTAssertThrowsError(try harness.timeline.validate(objects[1], using: harness.proof))
        harness.timeline.close()
        XCTAssertEqual(relay.usage, before)
        XCTAssertEqual(collector.objects.count, 2)
        for object in objects { XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(try XCTUnwrap(object.publicationLease))) }
        XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 0)
        XCTAssertEqual(relay.usage.mediaSealedObjectByteCount, 0)
    }

    func testRealTask17H264WriterCallbacksValidateSameBackingAndSystemReportRange() async throws {
        let collector = Task18ObjectCollector()
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: .zero, videoMode: .passthrough))
        let fixture = try Task18Fixtures.realH264Sample()
        let relay = SegmentReportRelay(binding: Task18Fixtures.binding, limits: .video, capacity: 8, objectSink: collector.append)
        let writer = try SegmentedFMP4Writer(binding: Task18Fixtures.binding, trackKind: .video,
            sourceFormatHint: fixture.format, boundarySession: boundary.session, compressedFormatConfiguration: nil,
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        let output = Task18Fixtures.videoOutput(fixture.sample)
        try writer.start(at: .zero)
        try writer.appendVideo(output, ticket: boundary.issueVideoAppend(for: output, writerBinding: writer.binding))
        let terminal = try await writer.finish()
        let initialization = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = try XCTUnwrap(collector.objects.first { $0.kind == .media })
        let report = try XCTUnwrap(media.report.systemReport)
        let track = try XCTUnwrap(report.trackReports.first)
        XCTAssertEqual(report.trackReports.count, 1)
        XCTAssertEqual(track.mediaType, .video)
        let validator = FinalFMP4Validator(binding: writer.binding, mediaType: .video)
        let proof = try validator.validateInitialization(initialization)
        let timeline = SegmentTimelineValidator(proof: proof)
        let usage = relay.usage
        let receipt = try timeline.validate(media, using: proof)
        XCTAssertTrue(proof.matches(initialization: initialization))
        XCTAssertTrue(receipt.matches(media: media, proof: proof))
        XCTAssertEqual(proof.initializationIdentity.backingIdentity, initialization.backing.identity)
        XCTAssertEqual(proof.initializationIdentity.byteRange, initialization.byteRange)
        XCTAssertEqual(proof.initializationIdentity.digest.bytes, initialization.digest)
        XCTAssertEqual(receipt.presentationRange.start, try ExactMediaTime(track.earliestPresentationTimeStamp))
        XCTAssertEqual(receipt.presentationRange.duration, try ExactMediaTime(track.duration))
        XCTAssertEqual(receipt.presentationRange.start, ExactMediaTime(value: 0, timescale: 1))
        XCTAssertEqual(receipt.presentationRange.duration, ExactMediaTime(value: 1, timescale: 24))
        XCTAssertEqual(media.report.identity, terminal.lastCallbackReportIdentity)
        XCTAssertEqual(relay.usage, usage)
        print("Task18 真实 H.264：init=\(initialization.bytes.count)，media=\(media.bytes.count)，start=\(track.earliestPresentationTimeStamp)，duration=\(track.duration)")
        XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(try XCTUnwrap(media.publicationLease)))
    }
}

private final class FinalFMP4ValidationTestHarness: @unchecked Sendable {
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let timeline: SegmentTimelineValidator

    init() throws {
        initialization = Task18Fixtures.object(kind: .initialization)
        proof = try FinalFMP4Validator(binding: initialization.binding, mediaType: .video).validateInitialization(initialization)
        timeline = SegmentTimelineValidator(proof: proof)
    }
}

private final class Task18ReceiptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SegmentValidationReceipt] = []
    var values: [SegmentValidationReceipt] { lock.withLock { storage } }
    func append(_ value: SegmentValidationReceipt) { lock.withLock { storage.append(value) } }
}

private final class Task18ObjectCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SealedMediaObject] = []
    var objects: [SealedMediaObject] { lock.withLock { storage } }
    func append(_ object: SealedMediaObject) { lock.withLock { storage.append(object) } }
}

private final class Task18ReportResult: @unchecked Sendable {
    let completed = XCTestExpectation(description: "真实 report producer 已结束")
    private let lock = NSLock()
    private var stored: Result<SegmentReportReference, Error>?
    func take() -> Result<SegmentReportReference, Error>? {
        lock.withLock {
            defer { stored = nil }
            return stored
        }
    }
    func store(_ result: Result<SegmentReportReference, Error>) {
        lock.withLock { stored = result }
    }
}

// 系统对象不允许直接构造；故障仅注入 report 读取适配边界。
private struct Task18FakeTrack: SegmentedFMP4TrackReportReading {
    let mediaType: AVMediaType
    let earliestPresentationTimeStamp: CMTime
    let duration: CMTime
    init(mediaType: AVMediaType = .video, start: CMTime, duration: CMTime) {
        self.mediaType = mediaType
        earliestPresentationTimeStamp = start
        self.duration = duration
    }
}

private struct Task18FakeReport: SegmentedFMP4ReportReading {
    let tracks: [Task18FakeTrack]
    var trackCount: Int { tracks.count }
    func track(at index: Int) -> any SegmentedFMP4TrackReportReading { tracks[index] }
}

private enum Task18Fixtures {
    static let initialization = Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x76])
    static let media = Data([0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x66, 0, 0, 0, 8, 0x6d, 0x64, 0x61, 0x74])
    static let binding = FMP4WriterBinding(
        outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 18),
        itemGeneration: .init(rawValue: 20), mediaEpoch: .init(rawValue: 21),
        publicationParticipantID: .init(rawValue: 22), renditionIdentity: .init(rawValue: 23),
        writerIdentity: .init(rawValue: 24))

    static func report(tracks: [Task18FakeTrack]? = [.init(start: .zero, duration: CMTime(value: 1, timescale: 1))]) -> SegmentReportReference {
        SegmentReportReference(evidence: .reading(tracks.map { Task18FakeReport(tracks: $0) }, mediaType: .video))
    }

    static func object(kind: SealedMediaObjectKind = .media, binding: FMP4WriterBinding = binding,
                       writer: FMP4WriterIdentity? = nil, sequence: UInt64 = 0, bytes: Data? = nil,
                       start: CMTime = .zero, duration: CMTime = CMTime(value: 1, timescale: 1),
                       report: SegmentReportReference? = nil) -> SealedMediaObject {
        let resolvedReport: SegmentReportReference
        if let report {
            resolvedReport = report
        } else if kind == .media, start.isNumeric, duration.isNumeric,
                  start.epoch == 0, duration.epoch == 0, start.value >= 0, duration.value > 0 {
            resolvedReport = qualifiedReport(start: start, duration: duration)
        } else {
            resolvedReport = Self.report(tracks: [.init(start: start, duration: duration)])
        }
        return SealedMediaObject(binding: binding, writerIdentity: writer ?? binding.writerIdentity,
            callbackTicket: .init(rawValue: 40), logicalSequence: sequence, kind: kind,
            sourceBytes: (bytes ?? (kind == .initialization ? initialization : media)) as NSData,
            report: resolvedReport, publicationLease: nil)
    }

    /// 每个正式正例都使用 production delegate 取得新的真实 report/reference，不制造测试资格。
    static func qualifiedReport(start: CMTime, duration: CMTime) -> SegmentReportReference {
        let result = Task18ReportResult()
        let producer = Task.detached {
            do {
                let collector = Task18ObjectCollector()
                let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: start, videoMode: .passthrough))
                let fixture = try realH264Sample(start: start, duration: duration)
                let relay = SegmentReportRelay(binding: binding, limits: .video, capacity: 8, objectSink: collector.append)
                let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .video,
                    sourceFormatHint: fixture.format, boundarySession: boundary.session, compressedFormatConfiguration: nil,
                    relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
                let output = videoOutput(fixture.sample)
                try writer.start(at: start)
                try writer.appendVideo(output, ticket: boundary.issueVideoAppend(for: output, writerBinding: binding))
                _ = try await writer.finish()
                let media = try XCTUnwrap(collector.objects.first { $0.kind == .media })
                XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(try XCTUnwrap(media.publicationLease)))
                result.store(.success(media.report))
            } catch {
                result.store(.failure(error))
            }
        }
        Task.detached {
            await producer.value
            result.completed.fulfill()
        }
        guard XCTWaiter.wait(for: [result.completed], timeout: 10) == .completed,
              let value = result.take() else {
            XCTFail("真实 report fixture 未在限时内结束")
            return report(tracks: nil)
        }
        do { return try value.get() }
        catch {
            XCTFail("真实 report fixture 失败：\(error)")
            return report(tracks: nil)
        }
    }

    static func bindingMutations() -> [FMP4WriterBinding] {
        (0..<6).map { index in
            FMP4WriterBinding(outputLifecycleEpoch: index == 0 ? AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 19) : binding.outputLifecycleEpoch,
                itemGeneration: index == 1 ? .init(rawValue: 99) : binding.itemGeneration,
                mediaEpoch: index == 2 ? .init(rawValue: 99) : binding.mediaEpoch,
                publicationParticipantID: index == 3 ? .init(rawValue: 99) : binding.publicationParticipantID,
                renditionIdentity: index == 4 ? .init(rawValue: 99) : binding.renditionIdentity,
                writerIdentity: index == 5 ? .init(rawValue: 99) : binding.writerIdentity)
        }
    }

    static func identityMutations(_ object: SealedMediaObject) throws -> [(String, FMP4ObjectIdentity)] {
        let original = try FMP4ObjectIdentity(object)
        var result: [(String, FMP4ObjectIdentity)] = []
        for binding in bindingMutations() {
            var changed = original
            changed.binding = binding
            result.append(("binding", changed))
        }
        var changed = original
        changed.writerIdentity = .init(rawValue: 99)
        result.append(("writer", changed))
        changed = original
        changed.kind = original.kind == .initialization ? .media : .initialization
        result.append(("kind", changed))
        changed = original
        changed.callbackTicket = .init(rawValue: 99)
        result.append(("callback", changed))
        changed = original
        changed.logicalSequence = 99
        result.append(("sequence", changed))
        changed = original
        changed.backingIdentity = .init(rawValue: UUID())
        result.append(("backing", changed))
        changed = original
        changed.byteRange = try XCTUnwrap(AudioServiceByteRange(offset: 1, length: object.bytes.count - 1))
        result.append(("range offset", changed))
        changed = original
        changed.byteRange = try XCTUnwrap(AudioServiceByteRange(offset: 0, length: object.bytes.count - 1))
        result.append(("range length", changed))
        changed = original
        changed.digest = try FMP4Digest(rawDigest: Data(repeating: 0, count: 32))
        result.append(("digest", changed))
        changed = original
        changed.reportIdentity = UUID()
        result.append(("report", changed))
        return result
    }

    // 复用 Task 17 的短 H.264 参数集、压缩 sample 与生产 writer callback 路径。
    static func realH264Sample(start: CMTime = .zero, duration: CMTime = CMTime(value: 1, timescale: 24)) throws -> (format: CMFormatDescription, sample: CMSampleBuffer) {
        let sps = AssemblerTestFixtures.h264SPS
        let pps = AssemblerTestFixtures.h264PPS
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        XCTAssertEqual(status, noErr)
        let resolved = try XCTUnwrap(format)
        let payload = Data([0, 0, 0, 2, 0x65, 0x80])
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: payload.count)
        }, noErr)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: resolved, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return (resolved, try XCTUnwrap(sample))
    }

    static func videoOutput(_ sample: CMSampleBuffer) -> HLSVideoEncodedOutput {
        let identity = VideoEncodingFrameIdentity(generation: .init(rawValue: 1), accessUnitID: 1, sequenceNumber: 1)
        return HLSVideoEncodedOutput(sourceIdentity: identity, sampleBuffer: sample, presentationOrigin: .raw,
            inputFormatSignature: VideoEncodingInputFormatSignature(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: 16, height: 16, bitDepth: 8, range: .video, primaries: .bt709, transfer: .bt709, matrix: .bt709,
                cleanAperture: nil, sampleAspectRatio: MediaRational(num: 1, den: 1),
                chromaLocation: .init(topField: "Left", bottomField: "Left"), masteringDisplayColorVolume: nil, contentLightLevelInfo: nil),
            hardwareProof: VTHardwareEncoderProof(sessionID: .init(rawValue: 1_001), generation: identity.generation,
                firstOutputIdentity: identity, profile: .h264High))
    }
}
