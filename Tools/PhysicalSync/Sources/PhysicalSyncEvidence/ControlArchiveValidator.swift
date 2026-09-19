// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public enum ControlRecordKind: UInt8, Sendable {
    case header = 0
    case frame = 1
    case control = 2
    case flow = 3
    case boundary = 4
    case footer = 5
}

public enum ControlEventKind: UInt8, Sendable {
    case calibrationStart = 0
    case calibrationCompleted = 1
    case uiNavigation = 2
    case playbackControl = 3
    case routeControl = 4
    case forbiddenSettingMutation = 5
}

public enum EvidenceSourceCode: UInt8, Sendable {
    case publicRemote = 0
    case uiClassifier = 1
}

public enum FlowPhaseCode: UInt8, Sendable {
    case start = 0
    case completed = 1
}

public enum BoundaryKindCode: UInt8, Sendable {
    case before = 0
    case target = 1
    case after = 2
}

public enum ArchiveValidationError: Error, Equatable, Sendable {
    case recordLengthOutOfRange(Int)
    case unexpectedRecordKind(UInt8)
    case duplicateHeader
    case duplicateFooter
    case duplicateFlowPhase(UInt8)
    case duplicateBoundaryKind(UInt8)
    case unexpectedEndOfStream
    case frameOrdinalMismatch(expected: UInt32, actual: UInt32)
    case controlOrdinalMismatch(expected: UInt32, actual: UInt32)
    case frameClockNonMonotonic
    case frameClockGapViolation(UInt64)
    case controlClockDecreased
    case controlCountSeenMismatch(expected: UInt32, actual: UInt32)
    case flowCompletionTimeout
    case forbiddenControlAfterCompletion
    case boundaryOrderingViolation
    case boundaryCoverageViolation
    case archiveCapExceeded(String)
    case preFooterByteCountMismatch(expected: UInt64, actual: UInt64)
    case totalCountMismatch
    case digestMismatch(field: String)
    case missingRecord(String)
    case publicRemoteTranscriptMismatch
    case unitChallengeMismatch
    case capabilityManifestDigestMismatch
    case topologicalOrderViolation
    case headerMissingOrDuplicate
    case footerNotTerminalRecord
}

public struct HeaderRecord: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let unitChallenge: ExactDigest32
    public let environmentDigest: ExactDigest32
    public let privacyMaskManifestDigest: ExactDigest32
    public let width: UInt32 = 640
    public let height: UInt32 = 360
    public let pixelFormatCode: UInt32 = 1
    public let nominalPeriodNS: UInt64 = 200000000
    public let minGapNS: UInt64 = 100000000
    public let maxGapNS: UInt64 = 300000000

    public init(
        unitChallenge: ExactDigest32,
        environmentDigest: ExactDigest32,
        privacyMaskManifestDigest: ExactDigest32
    ) {
        self.unitChallenge = unitChallenge
        self.environmentDigest = environmentDigest
        self.privacyMaskManifestDigest = privacyMaskManifestDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(0), // kind = 0
            .unsigned(UInt64(schemaVersion)),
            .byteString(unitChallenge.bytes),
            .byteString(environmentDigest.bytes),
            .byteString(privacyMaskManifestDigest.bytes),
            .unsigned(UInt64(width)),
            .unsigned(UInt64(height)),
            .unsigned(UInt64(pixelFormatCode)),
            .unsigned(nominalPeriodNS),
            .unsigned(minGapNS),
            .unsigned(maxGapNS)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }
}

public struct FrameRecord: Equatable, Sendable {
    public let frameOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let controlEventCountSeen: UInt32
    public let pageStateCode: UInt16
    public let layoutCode: UInt16
    public let safeROIProfileCode: UInt16
    public let uiClassifierEvidenceDigest: ExactDigest32
    public let redactedLumaBytes: Data // 230,400 bytes

    public init(
        frameOrdinal: UInt32,
        continuousClockNS: UInt64,
        controlEventCountSeen: UInt32,
        pageStateCode: UInt16,
        layoutCode: UInt16,
        safeROIProfileCode: UInt16,
        uiClassifierEvidenceDigest: ExactDigest32,
        redactedLumaBytes: Data
    ) {
        self.frameOrdinal = frameOrdinal
        self.continuousClockNS = continuousClockNS
        self.controlEventCountSeen = controlEventCountSeen
        self.pageStateCode = pageStateCode
        self.layoutCode = layoutCode
        self.safeROIProfileCode = safeROIProfileCode
        self.uiClassifierEvidenceDigest = uiClassifierEvidenceDigest
        self.redactedLumaBytes = redactedLumaBytes
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(1), // kind = 1
            .unsigned(UInt64(frameOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(controlEventCountSeen)),
            .unsigned(UInt64(pageStateCode)),
            .unsigned(UInt64(layoutCode)),
            .unsigned(UInt64(safeROIProfileCode)),
            .byteString(uiClassifierEvidenceDigest.bytes),
            .byteString(redactedLumaBytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }
}

public struct ControlRecord: Equatable, Sendable {
    public let eventOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let eventKind: ControlEventKind
    public let evidenceSource: EvidenceSourceCode
    public let sourceOrdinal: UInt32
    public let sourceDetailCode: UInt16
    public let evidenceDigest: ExactDigest32

    public init(
        eventOrdinal: UInt32,
        continuousClockNS: UInt64,
        eventKind: ControlEventKind,
        evidenceSource: EvidenceSourceCode,
        sourceOrdinal: UInt32,
        sourceDetailCode: UInt16,
        evidenceDigest: ExactDigest32
    ) {
        self.eventOrdinal = eventOrdinal
        self.continuousClockNS = continuousClockNS
        self.eventKind = eventKind
        self.evidenceSource = evidenceSource
        self.sourceOrdinal = sourceOrdinal
        self.sourceDetailCode = sourceDetailCode
        self.evidenceDigest = evidenceDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(2), // kind = 2
            .unsigned(UInt64(eventOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(eventKind.rawValue)),
            .unsigned(UInt64(evidenceSource.rawValue)),
            .unsigned(UInt64(sourceOrdinal)),
            .unsigned(UInt64(sourceDetailCode)),
            .byteString(evidenceDigest.bytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }
}

public struct FlowRecord: Equatable, Sendable {
    public let phase: FlowPhaseCode
    public let frameOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let controlEventOrdinal: UInt32
    public let uiEvidenceDigest: ExactDigest32

    public init(
        phase: FlowPhaseCode,
        frameOrdinal: UInt32,
        continuousClockNS: UInt64,
        controlEventOrdinal: UInt32,
        uiEvidenceDigest: ExactDigest32
    ) {
        self.phase = phase
        self.frameOrdinal = frameOrdinal
        self.continuousClockNS = continuousClockNS
        self.controlEventOrdinal = controlEventOrdinal
        self.uiEvidenceDigest = uiEvidenceDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(3), // kind = 3
            .unsigned(UInt64(phase.rawValue)),
            .unsigned(UInt64(frameOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(controlEventOrdinal)),
            .byteString(uiEvidenceDigest.bytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }

    public var flowIdentity: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct BoundaryRecord: Equatable, Sendable {
    public let kind: BoundaryKindCode
    public let unitChallenge: ExactDigest32
    public let firstFrameOrdinal: UInt32
    public let lastFrameOrdinal: UInt32
    public let startClockNS: UInt64
    public let endClockNS: UInt64
    public let controlCountAtStart: UInt32
    public let controlCountAtEnd: UInt32
    public let captureFileDigest: ExactDigest32
    public let outputReceiptDigest: ExactDigest32

    public init(
        kind: BoundaryKindCode,
        unitChallenge: ExactDigest32,
        firstFrameOrdinal: UInt32,
        lastFrameOrdinal: UInt32,
        startClockNS: UInt64,
        endClockNS: UInt64,
        controlCountAtStart: UInt32,
        controlCountAtEnd: UInt32,
        captureFileDigest: ExactDigest32,
        outputReceiptDigest: ExactDigest32
    ) {
        self.kind = kind
        self.unitChallenge = unitChallenge
        self.firstFrameOrdinal = firstFrameOrdinal
        self.lastFrameOrdinal = lastFrameOrdinal
        self.startClockNS = startClockNS
        self.endClockNS = endClockNS
        self.controlCountAtStart = controlCountAtStart
        self.controlCountAtEnd = controlCountAtEnd
        self.captureFileDigest = captureFileDigest
        self.outputReceiptDigest = outputReceiptDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(4), // kind = 4
            .unsigned(UInt64(kind.rawValue)),
            .byteString(unitChallenge.bytes),
            .unsigned(UInt64(firstFrameOrdinal)),
            .unsigned(UInt64(lastFrameOrdinal)),
            .unsigned(startClockNS),
            .unsigned(endClockNS),
            .unsigned(UInt64(controlCountAtStart)),
            .unsigned(UInt64(controlCountAtEnd)),
            .byteString(captureFileDigest.bytes),
            .byteString(outputReceiptDigest.bytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }

    public var boundaryIdentity: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct FooterRecord: Equatable, Sendable {
    public let frameCount: UInt32
    public let controlEventCount: UInt32
    public let recordCountIncludingHeaderAndFooter: UInt32
    public let preFooterByteCount: UInt64

    public init(
        frameCount: UInt32,
        controlEventCount: UInt32,
        recordCountIncludingHeaderAndFooter: UInt32,
        preFooterByteCount: UInt64
    ) {
        self.frameCount = frameCount
        self.controlEventCount = controlEventCount
        self.recordCountIncludingHeaderAndFooter = recordCountIncludingHeaderAndFooter
        self.preFooterByteCount = preFooterByteCount
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(5), // kind = 5
            .unsigned(UInt64(frameCount)),
            .unsigned(UInt64(controlEventCount)),
            .unsigned(UInt64(recordCountIncludingHeaderAndFooter)),
            .unsigned(preFooterByteCount)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }
}

public struct PublicRemoteEventReceiptV1: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let unitChallenge: ExactDigest32
    public let publicRemoteEventOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let commandCode: UInt16
    public let commandPhaseCode: UInt8

    public init(
        unitChallenge: ExactDigest32,
        publicRemoteEventOrdinal: UInt32,
        continuousClockNS: UInt64,
        commandCode: UInt16,
        commandPhaseCode: UInt8
    ) {
        self.unitChallenge = unitChallenge
        self.publicRemoteEventOrdinal = publicRemoteEventOrdinal
        self.continuousClockNS = continuousClockNS
        self.commandCode = commandCode
        self.commandPhaseCode = commandPhaseCode
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .byteString(unitChallenge.bytes),
            .unsigned(UInt64(publicRemoteEventOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(commandCode)),
            .unsigned(UInt64(commandPhaseCode))
        ]
        let encoded = try! CanonicalCBOR.encode(.array(items))
        assert(encoded.count <= 64)
        return encoded
    }

    public var receiptDigest: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct ControlEventEvidenceV1: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let unitChallenge: ExactDigest32
    public let capabilityManifestDigest: ExactDigest32
    public let privacyMaskManifestDigest: ExactDigest32
    public let eventOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let eventKindCode: UInt8
    public let evidenceSourceCode: UInt8
    public let sourceOrdinal: UInt32
    public let sourceDetailCode: UInt16
    public let sourceEvidenceDigest: ExactDigest32

    public init(
        unitChallenge: ExactDigest32,
        capabilityManifestDigest: ExactDigest32,
        privacyMaskManifestDigest: ExactDigest32,
        eventOrdinal: UInt32,
        continuousClockNS: UInt64,
        eventKindCode: UInt8,
        evidenceSourceCode: UInt8,
        sourceOrdinal: UInt32,
        sourceDetailCode: UInt16,
        sourceEvidenceDigest: ExactDigest32
    ) {
        self.unitChallenge = unitChallenge
        self.capabilityManifestDigest = capabilityManifestDigest
        self.privacyMaskManifestDigest = privacyMaskManifestDigest
        self.eventOrdinal = eventOrdinal
        self.continuousClockNS = continuousClockNS
        self.eventKindCode = eventKindCode
        self.evidenceSourceCode = evidenceSourceCode
        self.sourceOrdinal = sourceOrdinal
        self.sourceDetailCode = sourceDetailCode
        self.sourceEvidenceDigest = sourceEvidenceDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .byteString(unitChallenge.bytes),
            .byteString(capabilityManifestDigest.bytes),
            .byteString(privacyMaskManifestDigest.bytes),
            .unsigned(UInt64(eventOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(eventKindCode)),
            .unsigned(UInt64(evidenceSourceCode)),
            .unsigned(UInt64(sourceOrdinal)),
            .unsigned(UInt64(sourceDetailCode)),
            .byteString(sourceEvidenceDigest.bytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }

    public var evidenceDigest: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct PhysicalSyncUnitEvidenceEnvelopeV1: Equatable, Sendable {
    public let transactionIdentityDigest: ExactDigest32
    public let beforeOutputReceiptIdentity: ExactDigest32
    public let targetOutputReceiptIdentity: ExactDigest32
    public let afterOutputReceiptIdentity: ExactDigest32

    public init(
        transactionIdentityDigest: ExactDigest32,
        beforeOutputReceiptIdentity: ExactDigest32,
        targetOutputReceiptIdentity: ExactDigest32,
        afterOutputReceiptIdentity: ExactDigest32
    ) {
        self.transactionIdentityDigest = transactionIdentityDigest
        self.beforeOutputReceiptIdentity = beforeOutputReceiptIdentity
        self.targetOutputReceiptIdentity = targetOutputReceiptIdentity
        self.afterOutputReceiptIdentity = afterOutputReceiptIdentity
    }
}

public final class ControlArchiveWriter {
    private var buffer = Data()
    private var hasHeader = false
    private var hasFooter = false
    private var framesCount: UInt32 = 0
    private var controlsCount: UInt32 = 0
    private var recordsCount: UInt32 = 0
    private var lastFrameOrdinal: UInt32?
    private var lastFrameClockNS: UInt64?
    private var firstFrameClockNS: UInt64?
    private var lastControlOrdinal: UInt32?
    private var lastControlClockNS: UInt64?

    public init() {}

    private func appendRecordBytes(_ recordBytes: Data) throws {
        guard recordBytes.count >= 1 && recordBytes.count <= 230512 else {
            throw ArchiveValidationError.recordLengthOutOfRange(recordBytes.count)
        }
        guard recordsCount + 1 <= 13104 else {
            throw ArchiveValidationError.archiveCapExceeded("Record count exceeds 13104")
        }
        guard UInt64(buffer.count) + 4 + UInt64(recordBytes.count) <= 2100000000 else {
            throw ArchiveValidationError.archiveCapExceeded("Byte count exceeds 2,100,000,000")
        }

        var lenBE = UInt32(recordBytes.count).bigEndian
        buffer.append(Data(bytes: &lenBE, count: 4))
        buffer.append(recordBytes)
        recordsCount += 1
    }

    public func writeHeader(_ header: HeaderRecord) throws {
        guard !hasHeader else { throw ArchiveValidationError.duplicateHeader }
        let cbor = header.toCanonicalCBOR()
        try appendRecordBytes(cbor)
        hasHeader = true
    }

    public func writeFrame(_ frame: FrameRecord) throws {
        guard hasHeader && !hasFooter else { throw ArchiveValidationError.boundaryOrderingViolation }
        guard framesCount + 1 <= 9001 else {
            throw ArchiveValidationError.archiveCapExceeded("Frame count exceeds 9001")
        }

        let expectedOrdinal = framesCount
        guard frame.frameOrdinal == expectedOrdinal else {
            throw ArchiveValidationError.frameOrdinalMismatch(expected: expectedOrdinal, actual: frame.frameOrdinal)
        }

        if let lastClock = lastFrameClockNS {
            guard frame.continuousClockNS > lastClock else {
                throw ArchiveValidationError.frameClockNonMonotonic
            }
            let gap = frame.continuousClockNS - lastClock
            guard gap >= 100_000_000 && gap <= 300_000_000 else {
                throw ArchiveValidationError.frameClockGapViolation(gap)
            }
        } else {
            firstFrameClockNS = frame.continuousClockNS
        }

        if let firstClock = firstFrameClockNS {
            guard frame.continuousClockNS - firstClock <= 1_800_000_000_000 else {
                throw ArchiveValidationError.archiveCapExceeded("Duration exceeds 1,800,000,000,000 ns")
            }
        }

        let expectedControlsSeen = controlsCount
        guard frame.controlEventCountSeen == expectedControlsSeen else {
            throw ArchiveValidationError.controlCountSeenMismatch(expected: expectedControlsSeen, actual: frame.controlEventCountSeen)
        }

        let cbor = frame.toCanonicalCBOR()
        try appendRecordBytes(cbor)
        framesCount += 1
        lastFrameOrdinal = frame.frameOrdinal
        lastFrameClockNS = frame.continuousClockNS
    }

    public func writeControl(_ control: ControlRecord) throws {
        guard hasHeader && !hasFooter else { throw ArchiveValidationError.boundaryOrderingViolation }
        guard controlsCount + 1 <= 4096 else {
            throw ArchiveValidationError.archiveCapExceeded("Control count exceeds 4096")
        }

        let expectedOrdinal = controlsCount
        guard control.eventOrdinal == expectedOrdinal else {
            throw ArchiveValidationError.controlOrdinalMismatch(expected: expectedOrdinal, actual: control.eventOrdinal)
        }

        if let lastClock = lastControlClockNS {
            guard control.continuousClockNS >= lastClock else {
                throw ArchiveValidationError.controlClockDecreased
            }
        }

        let cbor = control.toCanonicalCBOR()
        try appendRecordBytes(cbor)
        controlsCount += 1
        lastControlOrdinal = control.eventOrdinal
        lastControlClockNS = control.continuousClockNS
    }

    public func writeFlow(_ flow: FlowRecord) throws {
        guard hasHeader && !hasFooter else { throw ArchiveValidationError.boundaryOrderingViolation }
        let cbor = flow.toCanonicalCBOR()
        try appendRecordBytes(cbor)
    }

    public func writeBoundary(_ boundary: BoundaryRecord) throws {
        guard hasHeader && !hasFooter else { throw ArchiveValidationError.boundaryOrderingViolation }
        let cbor = boundary.toCanonicalCBOR()
        try appendRecordBytes(cbor)
    }

    public func writeFooter(_ footer: FooterRecord) throws -> Data {
        guard hasHeader && !hasFooter else { throw ArchiveValidationError.duplicateFooter }
        let preFooterByteCount = UInt64(buffer.count)

        let accurateFooter = FooterRecord(
            frameCount: framesCount,
            controlEventCount: controlsCount,
            recordCountIncludingHeaderAndFooter: recordsCount + 1,
            preFooterByteCount: preFooterByteCount
        )

        let cbor = accurateFooter.toCanonicalCBOR()
        try appendRecordBytes(cbor)
        hasFooter = true
        return buffer
    }
}

public enum ControlArchiveValidator {
    public static func validate(
        archiveStream: Data,
        expectedChallenge: ExactDigest32,
        expectedEnvironmentDigest: ExactDigest32,
        expectedCapabilityDigest: ExactDigest32,
        expectedPrivacyMaskManifestDigest: ExactDigest32,
        publicRemoteTranscript: [PublicRemoteEventReceiptV1],
        beforeReceipt: HomePodOutputConfigurationReceiptV2,
        targetReceipt: HomePodOutputConfigurationReceiptV2,
        afterReceipt: HomePodOutputConfigurationReceiptV2
    ) throws -> PhysicalSyncUnitEvidenceEnvelopeV1 {
        guard archiveStream.count <= 2100000000 else {
            throw ArchiveValidationError.archiveCapExceeded("Stream exceeds 2.1GB")
        }

        guard !archiveStream.isEmpty else {
            throw ArchiveValidationError.headerMissingOrDuplicate
        }

        // Parse records
        var offset = 0
        var recordCBORList: [Data] = []
        var preFooterOffset: UInt64 = 0
        var footerSeen = false

        while offset < archiveStream.count {
            if footerSeen {
                throw ArchiveValidationError.footerNotTerminalRecord
            }

            guard offset + 4 <= archiveStream.count else {
                throw ArchiveValidationError.unexpectedEndOfStream
            }
            let b0 = UInt32(archiveStream[offset])
            let b1 = UInt32(archiveStream[offset + 1])
            let b2 = UInt32(archiveStream[offset + 2])
            let b3 = UInt32(archiveStream[offset + 3])
            let len = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4

            guard len >= 1 && len <= 230512 else {
                throw ArchiveValidationError.recordLengthOutOfRange(len)
            }
            guard offset + len <= archiveStream.count else {
                throw ArchiveValidationError.unexpectedEndOfStream
            }
            let recordData = archiveStream.subdata(in: offset..<(offset + len))
            offset += len

            // Check if this record is footer
            let decoded = try CanonicalCBOR.decode(recordData)
            guard case .array(let items) = decoded, let first = items.first, case .unsigned(let kind) = first else {
                throw ArchiveValidationError.unexpectedRecordKind(255)
            }

            if recordCBORList.isEmpty {
                guard kind == 0 else {
                    throw ArchiveValidationError.headerMissingOrDuplicate
                }
            } else if kind == 0 {
                throw ArchiveValidationError.headerMissingOrDuplicate
            }

            if kind == 5 { // Footer
                preFooterOffset = UInt64(offset - len - 4)
                footerSeen = true
                if offset < archiveStream.count {
                    throw ArchiveValidationError.footerNotTerminalRecord
                }
            }
            recordCBORList.append(recordData)
        }

        guard footerSeen else {
            throw ArchiveValidationError.missingRecord("Footer")
        }

        guard recordCBORList.count >= 8 && recordCBORList.count <= 13104 else {
            throw ArchiveValidationError.totalCountMismatch
        }

        // Decode each record
        var headerRecord: HeaderRecord?
        var frames: [FrameRecord] = []
        var controls: [ControlRecord] = []
        var flowStart: FlowRecord?
        var flowCompleted: FlowRecord?
        var boundaryBefore: BoundaryRecord?
        var boundaryTarget: BoundaryRecord?
        var boundaryAfter: BoundaryRecord?
        var footerRecord: FooterRecord?

        var boundaryBeforeIdentity: ExactDigest32?
        var boundaryTargetIdentity: ExactDigest32?
        var boundaryAfterIdentity: ExactDigest32?
        var flowStartDigest: ExactDigest32?
        var flowCompletedDigest: ExactDigest32?

        for recordBytes in recordCBORList {
            let decoded = try CanonicalCBOR.decode(recordBytes)
            guard case .array(let items) = decoded, let first = items.first, case .unsigned(let kind) = first else {
                throw ArchiveValidationError.unexpectedRecordKind(255)
            }

            switch kind {
            case 0:
                guard headerRecord == nil else { throw ArchiveValidationError.headerMissingOrDuplicate }
                guard items.count == 11,
                      case .byteString(let ch) = items[2],
                      case .byteString(let env) = items[3],
                      case .byteString(let priv) = items[4] else {
                    throw ArchiveValidationError.unexpectedRecordKind(0)
                }
                let challenge = try ExactDigest32(ch)
                let envDigest = try ExactDigest32(env)
                let privDigest = try ExactDigest32(priv)
                headerRecord = HeaderRecord(unitChallenge: challenge, environmentDigest: envDigest, privacyMaskManifestDigest: privDigest)

            case 1:
                guard items.count == 9,
                      case .unsigned(let ord) = items[1],
                      case .unsigned(let clock) = items[2],
                      case .unsigned(let seen) = items[3],
                      case .unsigned(let pState) = items[4],
                      case .unsigned(let lCode) = items[5],
                      case .unsigned(let roiProf) = items[6],
                      case .byteString(let uiDig) = items[7],
                      case .byteString(let luma) = items[8] else {
                    throw ArchiveValidationError.unexpectedRecordKind(1)
                }
                let frame = FrameRecord(
                    frameOrdinal: UInt32(ord),
                    continuousClockNS: clock,
                    controlEventCountSeen: UInt32(seen),
                    pageStateCode: UInt16(pState),
                    layoutCode: UInt16(lCode),
                    safeROIProfileCode: UInt16(roiProf),
                    uiClassifierEvidenceDigest: try ExactDigest32(uiDig),
                    redactedLumaBytes: luma
                )
                frames.append(frame)

            case 2:
                guard items.count == 8,
                      case .unsigned(let ord) = items[1],
                      case .unsigned(let clock) = items[2],
                      case .unsigned(let k) = items[3],
                      case .unsigned(let src) = items[4],
                      case .unsigned(let sOrd) = items[5],
                      case .unsigned(let sDet) = items[6],
                      case .byteString(let dig) = items[7] else {
                    throw ArchiveValidationError.unexpectedRecordKind(2)
                }
                guard let eventKind = ControlEventKind(rawValue: UInt8(k)),
                      let source = EvidenceSourceCode(rawValue: UInt8(src)) else {
                    throw ArchiveValidationError.unexpectedRecordKind(2)
                }
                let control = ControlRecord(
                    eventOrdinal: UInt32(ord),
                    continuousClockNS: clock,
                    eventKind: eventKind,
                    evidenceSource: source,
                    sourceOrdinal: UInt32(sOrd),
                    sourceDetailCode: UInt16(sDet),
                    evidenceDigest: try ExactDigest32(dig)
                )
                controls.append(control)

            case 3:
                guard items.count == 6,
                      case .unsigned(let phase) = items[1],
                      case .unsigned(let fOrd) = items[2],
                      case .unsigned(let clock) = items[3],
                      case .unsigned(let cOrd) = items[4],
                      case .byteString(let uiDig) = items[5] else {
                    throw ArchiveValidationError.unexpectedRecordKind(3)
                }
                guard let flowPhase = FlowPhaseCode(rawValue: UInt8(phase)) else {
                    throw ArchiveValidationError.unexpectedRecordKind(3)
                }
                let flow = FlowRecord(
                    phase: flowPhase,
                    frameOrdinal: UInt32(fOrd),
                    continuousClockNS: clock,
                    controlEventOrdinal: UInt32(cOrd),
                    uiEvidenceDigest: try ExactDigest32(uiDig)
                )
                if flowPhase == .start {
                    guard flowStart == nil else { throw ArchiveValidationError.duplicateFlowPhase(0) }
                    flowStart = flow
                    flowStartDigest = ExactDigest32.sha256(of: recordBytes)
                } else {
                    guard flowCompleted == nil else { throw ArchiveValidationError.duplicateFlowPhase(1) }
                    flowCompleted = flow
                    flowCompletedDigest = ExactDigest32.sha256(of: recordBytes)
                }

            case 4:
                guard items.count == 11,
                      case .unsigned(let k) = items[1],
                      case .byteString(let ch) = items[2],
                      case .unsigned(let firstOrd) = items[3],
                      case .unsigned(let lastOrd) = items[4],
                      case .unsigned(let sClock) = items[5],
                      case .unsigned(let eClock) = items[6],
                      case .unsigned(let cStart) = items[7],
                      case .unsigned(let cEnd) = items[8],
                      case .byteString(let capDig) = items[9],
                      case .byteString(let outDig) = items[10] else {
                    throw ArchiveValidationError.unexpectedRecordKind(4)
                }
                guard let bKind = BoundaryKindCode(rawValue: UInt8(k)) else {
                    throw ArchiveValidationError.unexpectedRecordKind(4)
                }
                let boundary = BoundaryRecord(
                    kind: bKind,
                    unitChallenge: try ExactDigest32(ch),
                    firstFrameOrdinal: UInt32(firstOrd),
                    lastFrameOrdinal: UInt32(lastOrd),
                    startClockNS: sClock,
                    endClockNS: eClock,
                    controlCountAtStart: UInt32(cStart),
                    controlCountAtEnd: UInt32(cEnd),
                    captureFileDigest: try ExactDigest32(capDig),
                    outputReceiptDigest: try ExactDigest32(outDig)
                )
                let bIdentity = ExactDigest32.sha256(of: recordBytes)
                switch bKind {
                case .before:
                    guard boundaryBefore == nil else { throw ArchiveValidationError.duplicateBoundaryKind(0) }
                    boundaryBefore = boundary
                    boundaryBeforeIdentity = bIdentity
                case .target:
                    guard boundaryTarget == nil else { throw ArchiveValidationError.duplicateBoundaryKind(1) }
                    boundaryTarget = boundary
                    boundaryTargetIdentity = bIdentity
                case .after:
                    guard boundaryAfter == nil else { throw ArchiveValidationError.duplicateBoundaryKind(2) }
                    boundaryAfter = boundary
                    boundaryAfterIdentity = bIdentity
                }

            case 5:
                guard footerRecord == nil else { throw ArchiveValidationError.footerNotTerminalRecord }
                guard items.count == 5,
                      case .unsigned(let fCount) = items[1],
                      case .unsigned(let cCount) = items[2],
                      case .unsigned(let rCount) = items[3],
                      case .unsigned(let preBytes) = items[4] else {
                    throw ArchiveValidationError.unexpectedRecordKind(5)
                }
                footerRecord = FooterRecord(
                    frameCount: UInt32(fCount),
                    controlEventCount: UInt32(cCount),
                    recordCountIncludingHeaderAndFooter: UInt32(rCount),
                    preFooterByteCount: preBytes
                )

            default:
                throw ArchiveValidationError.unexpectedRecordKind(UInt8(kind))
            }
        }

        guard let header = headerRecord else { throw ArchiveValidationError.missingRecord("Header") }
        guard let footer = footerRecord else { throw ArchiveValidationError.missingRecord("Footer") }
        guard let startFlow = flowStart, let compFlow = flowCompleted else { throw ArchiveValidationError.missingRecord("Flow") }
        guard let bBefore = boundaryBefore, let bTarget = boundaryTarget, let bAfter = boundaryAfter else {
            throw ArchiveValidationError.missingRecord("Boundary")
        }

        // Verify challenge & digests
        guard header.unitChallenge == expectedChallenge else { throw ArchiveValidationError.unitChallengeMismatch }
        guard header.environmentDigest == expectedEnvironmentDigest else {
            throw ArchiveValidationError.digestMismatch(field: "environmentDigest")
        }
        guard header.privacyMaskManifestDigest == expectedPrivacyMaskManifestDigest else {
            throw ArchiveValidationError.digestMismatch(field: "privacyMaskManifestDigest")
        }

        // Verify counts
        guard footer.frameCount == UInt32(frames.count) else { throw ArchiveValidationError.totalCountMismatch }
        guard footer.controlEventCount == UInt32(controls.count) else { throw ArchiveValidationError.totalCountMismatch }
        guard footer.recordCountIncludingHeaderAndFooter == UInt32(recordCBORList.count) else { throw ArchiveValidationError.totalCountMismatch }
        guard footer.preFooterByteCount == preFooterOffset else {
            throw ArchiveValidationError.preFooterByteCountMismatch(expected: preFooterOffset, actual: footer.preFooterByteCount)
        }

        // Verify frame ordinals and gaps
        for (idx, frame) in frames.enumerated() {
            guard frame.frameOrdinal == UInt32(idx) else {
                throw ArchiveValidationError.frameOrdinalMismatch(expected: UInt32(idx), actual: frame.frameOrdinal)
            }
            if idx > 0 {
                let prev = frames[idx - 1]
                guard frame.continuousClockNS > prev.continuousClockNS else {
                    throw ArchiveValidationError.frameClockNonMonotonic
                }
                let gap = frame.continuousClockNS - prev.continuousClockNS
                guard gap >= 100_000_000 && gap <= 300_000_000 else {
                    throw ArchiveValidationError.frameClockGapViolation(gap)
                }
            }
        }

        // Verify public remote transcript 1:1 correspondence
        let publicRemoteControls = controls.filter { $0.evidenceSource == .publicRemote }
        guard publicRemoteTranscript.count == publicRemoteControls.count else {
            throw ArchiveValidationError.publicRemoteTranscriptMismatch
        }

        for (idx, (receipt, control)) in zip(publicRemoteTranscript, publicRemoteControls).enumerated() {
            guard receipt.publicRemoteEventOrdinal == UInt32(idx),
                  receipt.publicRemoteEventOrdinal == control.sourceOrdinal,
                  receipt.unitChallenge == expectedChallenge,
                  receipt.continuousClockNS == control.continuousClockNS,
                  receipt.commandCode == control.sourceDetailCode else {
                throw ArchiveValidationError.publicRemoteTranscriptMismatch
            }
            let expectedEventEvidenceDigest = ControlEventEvidenceV1(
                unitChallenge: expectedChallenge,
                capabilityManifestDigest: expectedCapabilityDigest,
                privacyMaskManifestDigest: expectedPrivacyMaskManifestDigest,
                eventOrdinal: control.eventOrdinal,
                continuousClockNS: control.continuousClockNS,
                eventKindCode: control.eventKind.rawValue,
                evidenceSourceCode: control.evidenceSource.rawValue,
                sourceOrdinal: control.sourceOrdinal,
                sourceDetailCode: control.sourceDetailCode,
                sourceEvidenceDigest: receipt.receiptDigest
            ).evidenceDigest
            guard control.evidenceDigest == receipt.receiptDigest || control.evidenceDigest == expectedEventEvidenceDigest else {
                throw ArchiveValidationError.publicRemoteTranscriptMismatch
            }
        }

        // Verify boundary and output receipts
        guard bBefore.outputReceiptDigest == beforeReceipt.receiptIdentity else {
            throw ArchiveValidationError.digestMismatch(field: "beforeReceiptIdentity")
        }
        guard bTarget.outputReceiptDigest == targetReceipt.receiptIdentity else {
            throw ArchiveValidationError.digestMismatch(field: "targetReceiptIdentity")
        }
        guard bAfter.outputReceiptDigest == afterReceipt.receiptIdentity else {
            throw ArchiveValidationError.digestMismatch(field: "afterReceiptIdentity")
        }

        guard let firstFrame = frames.first, let lastFrame = frames.last else {
            throw ArchiveValidationError.missingRecord("Frame")
        }

        // Strict spec topological inequality:
        // - archive.frames.first.frameOrdinal < startFlow.frameOrdinal
        // - startFlow.frameOrdinal < compFlow.frameOrdinal
        // - compFlow.frameOrdinal < bBefore.firstFrameOrdinal
        // - bBefore.firstFrameOrdinal <= bBefore.lastFrameOrdinal
        // - bBefore.lastFrameOrdinal < bTarget.firstFrameOrdinal
        // - bTarget.firstFrameOrdinal <= bTarget.lastFrameOrdinal
        // - bTarget.lastFrameOrdinal < bAfter.firstFrameOrdinal
        // - bAfter.firstFrameOrdinal <= bAfter.lastFrameOrdinal
        // - bAfter.lastFrameOrdinal < archive.frames.last.frameOrdinal
        guard firstFrame.frameOrdinal < startFlow.frameOrdinal &&
              startFlow.frameOrdinal < compFlow.frameOrdinal &&
              compFlow.frameOrdinal < bBefore.firstFrameOrdinal &&
              bBefore.firstFrameOrdinal <= bBefore.lastFrameOrdinal &&
              bBefore.lastFrameOrdinal < bTarget.firstFrameOrdinal &&
              bTarget.firstFrameOrdinal <= bTarget.lastFrameOrdinal &&
              bTarget.lastFrameOrdinal < bAfter.firstFrameOrdinal &&
              bAfter.firstFrameOrdinal <= bAfter.lastFrameOrdinal &&
              bAfter.lastFrameOrdinal < lastFrame.frameOrdinal else {
            throw ArchiveValidationError.topologicalOrderViolation
        }

        // Continuous clock ordering across flows, boundaries, and frames:
        // startFlow.continuousClockNS < compFlow.continuousClockNS <= bBefore.startClockNS <= bBefore.endClockNS < bTarget.startClockNS <= bTarget.endClockNS < bAfter.startClockNS <= bAfter.endClockNS
        guard startFlow.continuousClockNS < compFlow.continuousClockNS &&
              compFlow.continuousClockNS <= bBefore.startClockNS &&
              bBefore.startClockNS <= bBefore.endClockNS &&
              bBefore.endClockNS < bTarget.startClockNS &&
              bTarget.startClockNS <= bTarget.endClockNS &&
              bTarget.endClockNS < bAfter.startClockNS &&
              bAfter.startClockNS <= bAfter.endClockNS else {
            throw ArchiveValidationError.topologicalOrderViolation
        }

        // Flow completion deadline <= 300s
        guard compFlow.continuousClockNS >= startFlow.continuousClockNS &&
              compFlow.continuousClockNS - startFlow.continuousClockNS <= 300_000_000_000 else {
            throw ArchiveValidationError.flowCompletionTimeout
        }

        // Compute continuousControlArchiveDigest over full stream
        let continuousControlArchiveDigest = ExactDigest32.sha256(of: archiveStream)

        // Reconstruct transaction preimage
        let txItems: [CBORValue] = [
            .unsigned(1), // schemaVersion = 1
            .byteString(expectedChallenge.bytes),
            .byteString(expectedCapabilityDigest.bytes),
            .byteString(expectedEnvironmentDigest.bytes),
            .byteString(boundaryBeforeIdentity!.bytes),
            .byteString(boundaryTargetIdentity!.bytes),
            .byteString(boundaryAfterIdentity!.bytes),
            .byteString(flowStartDigest!.bytes),
            .byteString(flowCompletedDigest!.bytes),
            .byteString(continuousControlArchiveDigest.bytes),
            .unsigned(UInt64(frames.count)),
            .unsigned(UInt64(controls.count))
        ]

        let txPreimageBytes = try CanonicalCBOR.encode(.array(txItems))
        let txIdentity = ExactDigest32.sha256(of: txPreimageBytes)

        return PhysicalSyncUnitEvidenceEnvelopeV1(
            transactionIdentityDigest: txIdentity,
            beforeOutputReceiptIdentity: beforeReceipt.receiptIdentity,
            targetOutputReceiptIdentity: targetReceipt.receiptIdentity,
            afterOutputReceiptIdentity: afterReceipt.receiptIdentity
        )
    }
}
