// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class ControlArchiveValidatorTests: XCTestCase {
    private static func encodePrefixedRecord(_ cbor: Data) -> Data {
        var lenBE = UInt32(cbor.count).bigEndian
        var data = Data(bytes: &lenBE, count: 4)
        data.append(cbor)
        return data
    }

    struct BaselineFixture {
        let challenge: ExactDigest32
        let envDigest: ExactDigest32
        let privDigest: ExactDigest32
        let capDigest: ExactDigest32
        let receipt: HomePodOutputConfigurationReceiptV2
        let remoteReceipt0: PublicRemoteEventReceiptV1
        let remoteReceipt1: PublicRemoteEventReceiptV1
        let header: HeaderRecord
        let frames: [FrameRecord]
        let controls: [ControlRecord]
        let flowStart: FlowRecord
        let flowCompleted: FlowRecord
        let boundaryBefore: BoundaryRecord
        let boundaryTarget: BoundaryRecord
        let boundaryAfter: BoundaryRecord

        init() {
            challenge = TestFixtures.sampleChallenge
            envDigest = TestFixtures.zeroDigest32
            privDigest = TestFixtures.samplePrivacyMaskManifestDigest
            capDigest = TestFixtures.sampleCapabilityDigest
            receipt = TestFixtures.makeTestReceipt()

            let luma = Data(repeating: 0, count: 230400)
            let lumaDigest = ExactDigest32.sha256(of: luma)

            remoteReceipt0 = PublicRemoteEventReceiptV1(
                unitChallenge: challenge,
                publicRemoteEventOrdinal: 0,
                continuousClockNS: 300_000_000,
                commandCode: 100,
                commandPhaseCode: 1
            )
            remoteReceipt1 = PublicRemoteEventReceiptV1(
                unitChallenge: challenge,
                publicRemoteEventOrdinal: 1,
                continuousClockNS: 500_000_000,
                commandCode: 101,
                commandPhaseCode: 1
            )

            header = HeaderRecord(unitChallenge: challenge, environmentDigest: envDigest, privacyMaskManifestDigest: privDigest)

            // Strict topological order:
            // Frame 0: clock 100ms, seen 0
            // Control 0: clock 300ms, ord 0
            // FlowStart: frame 1, clock 300ms, control 0
            // Frame 1: clock 300ms, seen 1
            // Control 1: clock 500ms, ord 1
            // FlowCompleted: frame 2, clock 500ms, control 1
            // Frame 2: clock 500ms, seen 2
            // Frame 3: clock 700ms, seen 2
            // BoundaryBefore: [3..3], clock 700ms..700ms
            // Frame 4: clock 900ms, seen 2
            // BoundaryTarget: [4..4], clock 900ms..900ms
            // Frame 5: clock 1100ms, seen 2
            // BoundaryAfter: [5..5], clock 1100ms..1100ms
            // Frame 6: clock 1300ms, seen 2
            var f: [FrameRecord] = []
            f.append(FrameRecord(frameOrdinal: 0, continuousClockNS: 100_000_000, controlEventCountSeen: 0, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 1, continuousClockNS: 300_000_000, controlEventCountSeen: 1, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 2, continuousClockNS: 500_000_000, controlEventCountSeen: 2, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 3, continuousClockNS: 700_000_000, controlEventCountSeen: 2, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 4, continuousClockNS: 900_000_000, controlEventCountSeen: 2, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 5, continuousClockNS: 1_100_000_000, controlEventCountSeen: 2, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            f.append(FrameRecord(frameOrdinal: 6, continuousClockNS: 1_300_000_000, controlEventCountSeen: 2, pageStateCode: 1, layoutCode: 1, safeROIProfileCode: 1, uiClassifierEvidenceDigest: lumaDigest, redactedLumaBytes: luma))
            frames = f

            controls = [
                ControlRecord(
                    eventOrdinal: 0,
                    continuousClockNS: 300_000_000,
                    eventKind: .calibrationStart,
                    evidenceSource: .publicRemote,
                    sourceOrdinal: 0,
                    sourceDetailCode: 100,
                    evidenceDigest: remoteReceipt0.receiptDigest
                ),
                ControlRecord(
                    eventOrdinal: 1,
                    continuousClockNS: 500_000_000,
                    eventKind: .calibrationCompleted,
                    evidenceSource: .publicRemote,
                    sourceOrdinal: 1,
                    sourceDetailCode: 101,
                    evidenceDigest: remoteReceipt1.receiptDigest
                )
            ]

            flowStart = FlowRecord(
                phase: .start,
                frameOrdinal: 1,
                continuousClockNS: 300_000_000,
                controlEventOrdinal: 0,
                uiEvidenceDigest: lumaDigest
            )

            flowCompleted = FlowRecord(
                phase: .completed,
                frameOrdinal: 2,
                continuousClockNS: 500_000_000,
                controlEventOrdinal: 1,
                uiEvidenceDigest: lumaDigest
            )

            boundaryBefore = BoundaryRecord(
                kind: .before,
                unitChallenge: challenge,
                firstFrameOrdinal: 3,
                lastFrameOrdinal: 3,
                startClockNS: 700_000_000,
                endClockNS: 700_000_000,
                controlCountAtStart: 2,
                controlCountAtEnd: 2,
                captureFileDigest: TestFixtures.zeroDigest32,
                outputReceiptDigest: receipt.receiptIdentity
            )

            boundaryTarget = BoundaryRecord(
                kind: .target,
                unitChallenge: challenge,
                firstFrameOrdinal: 4,
                lastFrameOrdinal: 4,
                startClockNS: 900_000_000,
                endClockNS: 900_000_000,
                controlCountAtStart: 2,
                controlCountAtEnd: 2,
                captureFileDigest: TestFixtures.zeroDigest32,
                outputReceiptDigest: receipt.receiptIdentity
            )

            boundaryAfter = BoundaryRecord(
                kind: .after,
                unitChallenge: challenge,
                firstFrameOrdinal: 5,
                lastFrameOrdinal: 5,
                startClockNS: 1_100_000_000,
                endClockNS: 1_100_000_000,
                controlCountAtStart: 2,
                controlCountAtEnd: 2,
                captureFileDigest: TestFixtures.zeroDigest32,
                outputReceiptDigest: receipt.receiptIdentity
            )
        }

        func buildStream(
            overrideHeader: HeaderRecord? = nil,
            overrideFrames: [FrameRecord]? = nil,
            overrideControls: [ControlRecord]? = nil,
            overrideFlowStart: FlowRecord? = nil,
            overrideFlowCompleted: FlowRecord? = nil,
            overrideBoundaryBefore: BoundaryRecord? = nil,
            overrideBoundaryTarget: BoundaryRecord? = nil,
            overrideBoundaryAfter: BoundaryRecord? = nil,
            overrideFooter: FooterRecord? = nil
        ) -> Data {
            let h = overrideHeader ?? header
            let f = overrideFrames ?? frames
            let c = overrideControls ?? controls
            let fs = overrideFlowStart ?? flowStart
            let fc = overrideFlowCompleted ?? flowCompleted
            let bb = overrideBoundaryBefore ?? boundaryBefore
            let bt = overrideBoundaryTarget ?? boundaryTarget
            let ba = overrideBoundaryAfter ?? boundaryAfter

            var data = Data()
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(h.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[0].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(c[0].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(fs.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[1].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(c[1].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(fc.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[2].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[3].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(bb.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[4].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(bt.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[5].toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(ba.toCanonicalCBOR()))
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(f[6].toCanonicalCBOR()))

            let preFooterByteCount = UInt64(data.count)
            let actualFooter = overrideFooter ?? FooterRecord(
                frameCount: UInt32(f.count),
                controlEventCount: UInt32(c.count),
                recordCountIncludingHeaderAndFooter: 16,
                preFooterByteCount: preFooterByteCount
            )
            data.append(ControlArchiveValidatorTests.encodePrefixedRecord(actualFooter.toCanonicalCBOR()))
            return data
        }
    }

    func testArchiveRecordStreamWritingAndValidation() throws {
        let fixture = BaselineFixture()
        let writer = ControlArchiveWriter()

        try writer.writeHeader(fixture.header)
        try writer.writeFrame(fixture.frames[0])
        try writer.writeControl(fixture.controls[0])
        try writer.writeFlow(fixture.flowStart)
        try writer.writeFrame(fixture.frames[1])
        try writer.writeControl(fixture.controls[1])
        try writer.writeFlow(fixture.flowCompleted)
        try writer.writeFrame(fixture.frames[2])
        try writer.writeFrame(fixture.frames[3])
        try writer.writeBoundary(fixture.boundaryBefore)
        try writer.writeFrame(fixture.frames[4])
        try writer.writeBoundary(fixture.boundaryTarget)
        try writer.writeFrame(fixture.frames[5])
        try writer.writeBoundary(fixture.boundaryAfter)
        try writer.writeFrame(fixture.frames[6])

        let footer = FooterRecord(
            frameCount: 7,
            controlEventCount: 2,
            recordCountIncludingHeaderAndFooter: 16,
            preFooterByteCount: 0
        )
        let stream = try writer.writeFooter(footer)

        let envelope = try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )

        XCTAssertFalse(envelope.transactionIdentityDigest.bytes.isEmpty)
        XCTAssertEqual(envelope.beforeOutputReceiptIdentity, fixture.receipt.receiptIdentity)
        XCTAssertEqual(envelope.targetOutputReceiptIdentity, fixture.receipt.receiptIdentity)
        XCTAssertEqual(envelope.afterOutputReceiptIdentity, fixture.receipt.receiptIdentity)
    }

    func testSequenceViolationsRejectStream() throws {
        let challenge = TestFixtures.sampleChallenge
        let writer = ControlArchiveWriter()
        let header = HeaderRecord(unitChallenge: challenge, environmentDigest: TestFixtures.zeroDigest32, privacyMaskManifestDigest: TestFixtures.zeroDigest32)
        try writer.writeHeader(header)

        // Gap violation: nominal 200ms, min 100ms, max 300ms. If gap is 50ms (50_000_000ns < minGapNS)
        let luma = Data(repeating: 0, count: 230400)
        let digest = ExactDigest32.sha256(of: luma)
        let frame0 = FrameRecord(
            frameOrdinal: 0,
            continuousClockNS: 100_000_000,
            controlEventCountSeen: 0,
            pageStateCode: 1,
            layoutCode: 1,
            safeROIProfileCode: 1,
            uiClassifierEvidenceDigest: digest,
            redactedLumaBytes: luma
        )
        try writer.writeFrame(frame0)

        let frame1BadGap = FrameRecord(
            frameOrdinal: 1,
            continuousClockNS: 150_000_000, // gap 50ms < 100ms!
            controlEventCountSeen: 0,
            pageStateCode: 1,
            layoutCode: 1,
            safeROIProfileCode: 1,
            uiClassifierEvidenceDigest: digest,
            redactedLumaBytes: luma
        )
        XCTAssertThrowsError(try writer.writeFrame(frame1BadGap))
    }

    func testHeaderNotFirstRejection() throws {
        let fixture = BaselineFixture()

        // 1. Empty stream must throw headerMissingOrDuplicate
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: Data(),
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .headerMissingOrDuplicate)
        }

        // 2. Stream starting with a frame record instead of header
        var nonHeaderFirst = Data()
        nonHeaderFirst.append(Self.encodePrefixedRecord(fixture.frames[0].toCanonicalCBOR()))
        nonHeaderFirst.append(Self.encodePrefixedRecord(fixture.header.toCanonicalCBOR()))
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: nonHeaderFirst,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .headerMissingOrDuplicate)
        }

        // 3. Duplicate header in stream
        let stream = fixture.buildStream()
        var duplicateHeaderStream = stream
        // Insert an extra header after frame 0
        duplicateHeaderStream.append(Self.encodePrefixedRecord(fixture.header.toCanonicalCBOR()))
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: duplicateHeaderStream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            // Footer was already seen so either footerNotTerminalRecord or headerMissingOrDuplicate
            XCTAssertTrue(error as? ArchiveValidationError == .footerNotTerminalRecord || error as? ArchiveValidationError == .headerMissingOrDuplicate)
        }
    }

    func testRecordFollowingFooterRejection() throws {
        let fixture = BaselineFixture()
        let validStream = fixture.buildStream()

        // 1. Extra record following footer must throw footerNotTerminalRecord
        var trailingRecordStream = validStream
        trailingRecordStream.append(Self.encodePrefixedRecord(fixture.frames[0].toCanonicalCBOR()))

        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: trailingRecordStream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .footerNotTerminalRecord)
        }

        // 2. Trailing raw bytes following footer must throw footerNotTerminalRecord
        var trailingBytesStream = validStream
        trailingBytesStream.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: trailingBytesStream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .footerNotTerminalRecord)
        }
    }

    func testPublicRemoteTranscriptMismatch() throws {
        let fixture = BaselineFixture()
        let stream = fixture.buildStream()

        // 1. Count mismatch: transcript has only 1 receipt, but 2 control records exist
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 2. Count mismatch: transcript has 3 receipts
        let extraReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: fixture.challenge,
            publicRemoteEventOrdinal: 2,
            continuousClockNS: 600_000_000,
            commandCode: 102,
            commandPhaseCode: 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1, extraReceipt],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 3. Ordinal mismatch: receipt has ordinal 1 instead of 0
        let badOrdinalReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: fixture.challenge,
            publicRemoteEventOrdinal: 1, // should be 0
            continuousClockNS: 300_000_000,
            commandCode: 100,
            commandPhaseCode: 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [badOrdinalReceipt, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 4. Challenge mismatch: receipt has tampered challenge
        let tamperedChallenge = try ExactDigest32(Data(repeating: 0xFF, count: 32))
        let badChallengeReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: tamperedChallenge,
            publicRemoteEventOrdinal: 0,
            continuousClockNS: 300_000_000,
            commandCode: 100,
            commandPhaseCode: 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [badChallengeReceipt, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 5. Clock mismatch: receipt clock 300_000_001 != control clock 300_000_000
        let badClockReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: fixture.challenge,
            publicRemoteEventOrdinal: 0,
            continuousClockNS: 300_000_001,
            commandCode: 100,
            commandPhaseCode: 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [badClockReceipt, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 6. Command mismatch: receipt command 999 != control command 100
        let badCommandReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: fixture.challenge,
            publicRemoteEventOrdinal: 0,
            continuousClockNS: 300_000_000,
            commandCode: 999,
            commandPhaseCode: 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [badCommandReceipt, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }

        // 7. Phase mismatch: receipt phase 0 instead of 1 (causes receiptDigest mismatch)
        let badPhaseReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: fixture.challenge,
            publicRemoteEventOrdinal: 0,
            continuousClockNS: 300_000_000,
            commandCode: 100,
            commandPhaseCode: 0 // Was 1
        )
        XCTAssertThrowsError(try ControlArchiveValidator.validate(
            archiveStream: stream,
            expectedChallenge: fixture.challenge,
            expectedEnvironmentDigest: fixture.envDigest,
            expectedCapabilityDigest: fixture.capDigest,
            expectedPrivacyMaskManifestDigest: fixture.privDigest,
            publicRemoteTranscript: [badPhaseReceipt, fixture.remoteReceipt1],
            beforeReceipt: fixture.receipt,
            targetReceipt: fixture.receipt,
            afterReceipt: fixture.receipt
        )) { error in
            XCTAssertEqual(error as? ArchiveValidationError, .publicRemoteTranscriptMismatch)
        }
    }

    func testTopologicalOrderViolations() throws {
        let fixture = BaselineFixture()

        // Helper to validate stream and expect topologicalOrderViolation
        func assertTopologicalViolation(stream: Data) {
            XCTAssertThrowsError(try ControlArchiveValidator.validate(
                archiveStream: stream,
                expectedChallenge: fixture.challenge,
                expectedEnvironmentDigest: fixture.envDigest,
                expectedCapabilityDigest: fixture.capDigest,
                expectedPrivacyMaskManifestDigest: fixture.privDigest,
                publicRemoteTranscript: [fixture.remoteReceipt0, fixture.remoteReceipt1],
                beforeReceipt: fixture.receipt,
                targetReceipt: fixture.receipt,
                afterReceipt: fixture.receipt
            )) { error in
                XCTAssertEqual(error as? ArchiveValidationError, .topologicalOrderViolation)
            }
        }

        // 1. Violation: archive.frames.first.frameOrdinal >= startFlow.frameOrdinal (0 >= 0)
        let badFlowStart0 = FlowRecord(
            phase: .start,
            frameOrdinal: 0, // Frame 0 ordinal is 0, so 0 < 0 violated!
            continuousClockNS: 300_000_000,
            controlEventOrdinal: 0,
            uiEvidenceDigest: fixture.flowStart.uiEvidenceDigest
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideFlowStart: badFlowStart0))

        // 2. Violation: startFlow.frameOrdinal >= compFlow.frameOrdinal (2 >= 2)
        let badFlowStart2 = FlowRecord(
            phase: .start,
            frameOrdinal: 2, // compFlow is 2, so 2 < 2 violated!
            continuousClockNS: 300_000_000,
            controlEventOrdinal: 0,
            uiEvidenceDigest: fixture.flowStart.uiEvidenceDigest
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideFlowStart: badFlowStart2))

        // 3. Violation: compFlow.frameOrdinal >= bBefore.firstFrameOrdinal (3 >= 3)
        let badFlowComp3 = FlowRecord(
            phase: .completed,
            frameOrdinal: 3, // bBefore firstFrameOrdinal is 3, so 3 < 3 violated!
            continuousClockNS: 500_000_000,
            controlEventOrdinal: 1,
            uiEvidenceDigest: fixture.flowCompleted.uiEvidenceDigest
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideFlowCompleted: badFlowComp3))

        // 4. Violation: bBefore.firstFrameOrdinal > bBefore.lastFrameOrdinal (4 > 3)
        let badBeforeInverted = BoundaryRecord(
            kind: .before,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 4, // 4 > 3 violated!
            lastFrameOrdinal: 3,
            startClockNS: 700_000_000,
            endClockNS: 700_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryBefore: badBeforeInverted))

        // 5. Violation: bBefore.lastFrameOrdinal >= bTarget.firstFrameOrdinal (4 >= 4)
        let badBeforeLast4 = BoundaryRecord(
            kind: .before,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 3,
            lastFrameOrdinal: 4, // bTarget first is 4, so 4 < 4 violated!
            startClockNS: 700_000_000,
            endClockNS: 700_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryBefore: badBeforeLast4))

        // 6. Violation: bTarget.firstFrameOrdinal > bTarget.lastFrameOrdinal (5 > 4)
        let badTargetInverted = BoundaryRecord(
            kind: .target,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 5, // 5 > 4 violated!
            lastFrameOrdinal: 4,
            startClockNS: 900_000_000,
            endClockNS: 900_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryTarget: badTargetInverted))

        // 7. Violation: bTarget.lastFrameOrdinal >= bAfter.firstFrameOrdinal (5 >= 5)
        let badTargetLast5 = BoundaryRecord(
            kind: .target,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 4,
            lastFrameOrdinal: 5, // bAfter first is 5, so 5 < 5 violated!
            startClockNS: 900_000_000,
            endClockNS: 900_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryTarget: badTargetLast5))

        // 8. Violation: bAfter.firstFrameOrdinal > bAfter.lastFrameOrdinal (6 > 5)
        let badAfterInverted = BoundaryRecord(
            kind: .after,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 6, // 6 > 5 violated!
            lastFrameOrdinal: 5,
            startClockNS: 1_100_000_000,
            endClockNS: 1_100_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryAfter: badAfterInverted))

        // 9. Violation: bAfter.lastFrameOrdinal >= archive.frames.last.frameOrdinal (6 >= 6)
        let badAfterLast6 = BoundaryRecord(
            kind: .after,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 5,
            lastFrameOrdinal: 6, // frames.last is 6, so 6 < 6 violated!
            startClockNS: 1_100_000_000,
            endClockNS: 1_100_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryAfter: badAfterLast6))

        // 10. Clock violation: startFlow.continuousClockNS >= compFlow.continuousClockNS (500ms >= 500ms)
        let badClockFlowStart = FlowRecord(
            phase: .start,
            frameOrdinal: 1,
            continuousClockNS: 500_000_000, // compFlow is 500ms, so 500ms < 500ms violated!
            controlEventOrdinal: 0,
            uiEvidenceDigest: fixture.flowStart.uiEvidenceDigest
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideFlowStart: badClockFlowStart))

        // 11. Clock violation: compFlow.continuousClockNS > bBefore.startClockNS (700_000_001 > 700_000_000)
        let badClockFlowComp = FlowRecord(
            phase: .completed,
            frameOrdinal: 2,
            continuousClockNS: 700_000_001, // bBefore.start is 700ms, so <= 700ms violated!
            controlEventOrdinal: 1,
            uiEvidenceDigest: fixture.flowCompleted.uiEvidenceDigest
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideFlowCompleted: badClockFlowComp))

        // 12. Clock violation: bBefore.startClockNS > bBefore.endClockNS (700_000_001 > 700_000_000)
        let badClockBeforeInverted = BoundaryRecord(
            kind: .before,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 3,
            lastFrameOrdinal: 3,
            startClockNS: 700_000_001, // > endClockNS violated!
            endClockNS: 700_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryBefore: badClockBeforeInverted))

        // 13. Clock violation: bBefore.endClockNS >= bTarget.startClockNS (900ms >= 900ms)
        let badClockBeforeEnd900 = BoundaryRecord(
            kind: .before,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 3,
            lastFrameOrdinal: 3,
            startClockNS: 700_000_000,
            endClockNS: 900_000_000, // bTarget start is 900ms, so < 900ms violated!
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryBefore: badClockBeforeEnd900))

        // 14. Clock violation: bTarget.startClockNS > bTarget.endClockNS
        let badClockTargetInverted = BoundaryRecord(
            kind: .target,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 4,
            lastFrameOrdinal: 4,
            startClockNS: 900_000_001, // > endClockNS violated!
            endClockNS: 900_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryTarget: badClockTargetInverted))

        // 15. Clock violation: bTarget.endClockNS >= bAfter.startClockNS (1100ms >= 1100ms)
        let badClockTargetEnd1100 = BoundaryRecord(
            kind: .target,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 4,
            lastFrameOrdinal: 4,
            startClockNS: 900_000_000,
            endClockNS: 1_100_000_000, // bAfter start is 1100ms, so < 1100ms violated!
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryTarget: badClockTargetEnd1100))

        // 16. Clock violation: bAfter.startClockNS > bAfter.endClockNS
        let badClockAfterInverted = BoundaryRecord(
            kind: .after,
            unitChallenge: fixture.challenge,
            firstFrameOrdinal: 5,
            lastFrameOrdinal: 5,
            startClockNS: 1_100_000_001, // > endClockNS violated!
            endClockNS: 1_100_000_000,
            controlCountAtStart: 2,
            controlCountAtEnd: 2,
            captureFileDigest: TestFixtures.zeroDigest32,
            outputReceiptDigest: fixture.receipt.receiptIdentity
        )
        assertTopologicalViolation(stream: fixture.buildStream(overrideBoundaryAfter: badClockAfterInverted))
    }
}
