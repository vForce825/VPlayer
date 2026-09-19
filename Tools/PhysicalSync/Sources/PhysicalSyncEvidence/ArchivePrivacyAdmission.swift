// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public struct SafeROI: Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(x)),
            .unsigned(UInt64(y)),
            .unsigned(UInt64(width)),
            .unsigned(UInt64(height))
        ])
    }
}

public enum PrivacyAdmissionError: Error, Equatable, Sendable {
    case invalidSourceDimensions
    case invalidSourceDataLength
    case forbiddenOverlayState(UInt16)
    case unknownPageState(UInt16)
    case unknownLayout(UInt16)
    case invalidSafeROIProfile(UInt16)
    case unadmittedPixelContent(String)
    case evidencePreimageTooLarge(Int)
}

public enum ArchiveLumaNormalizerV1 {
    public static let targetWidth = 640
    public static let targetHeight = 360
    public static let targetByteCount = 640 * 360 // 230,400

    public static func normalizeRGB8ToLuma(sourceRGB: Data, sourceWidth: Int, sourceHeight: Int) throws -> Data {
        guard sourceWidth > 0 && sourceHeight > 0 else {
            throw PrivacyAdmissionError.invalidSourceDimensions
        }
        let expectedBytes = sourceWidth * sourceHeight * 3
        guard sourceRGB.count == expectedBytes else {
            throw PrivacyAdmissionError.invalidSourceDataLength
        }

        var luma = Data(count: targetByteCount)
        luma.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) in
            let dst = dstPtr.bindMemory(to: UInt8.self)
            sourceRGB.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
                let src = srcPtr.bindMemory(to: UInt8.self)

                for yd in 0..<targetHeight {
                    let ys = ((2 * yd + 1) * sourceHeight) / (2 * targetHeight)
                    let srcRowOffset = ys * sourceWidth * 3
                    let dstRowOffset = yd * targetWidth

                    for xd in 0..<targetWidth {
                        let xs = ((2 * xd + 1) * sourceWidth) / (2 * targetWidth)
                        let srcPixel = srcRowOffset + xs * 3
                        let r = Int32(src[srcPixel])
                        let g = Int32(src[srcPixel + 1])
                        let b = Int32(src[srcPixel + 2])

                        let yRaw = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
                        let yClamped = UInt8(max(0, min(255, yRaw)))
                        dst[dstRowOffset + xd] = yClamped
                    }
                }
            }
        }
        return luma
    }
}

public struct PrivacyMaskManifestV1: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let sourceCropWidth: Int
    public let sourceCropHeight: Int
    public let targetWidth: Int = 640
    public let targetHeight: Int = 360
    public let allowedProfiles: [UInt16: [SafeROI]]

    public init(sourceCropWidth: Int, sourceCropHeight: Int, allowedProfiles: [UInt16: [SafeROI]]) {
        self.sourceCropWidth = sourceCropWidth
        self.sourceCropHeight = sourceCropHeight
        self.allowedProfiles = allowedProfiles
    }

    public func toCanonicalCBOR() -> Data {
        // Sorted profiles for canonical determinism
        let sortedProfiles = allowedProfiles.keys.sorted().map { code -> CBORValue in
            let rois = allowedProfiles[code] ?? []
            return .array([
                .unsigned(UInt64(code)),
                .array(rois.map { $0.toCBOR() })
            ])
        }

        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .unsigned(UInt64(sourceCropWidth)),
            .unsigned(UInt64(sourceCropHeight)),
            .unsigned(UInt64(targetWidth)),
            .unsigned(UInt64(targetHeight)),
            .array(sortedProfiles)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }

    public var privacyMaskManifestDigest: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct UIClassifierEvidenceV1: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let unitChallenge: ExactDigest32
    public let capabilityManifestDigest: ExactDigest32
    public let privacyMaskManifestDigest: ExactDigest32
    public let frameOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let pageStateCode: UInt16
    public let layoutCode: UInt16
    public let overlayStateCode: UInt16 = 0
    public let safeROIProfileCode: UInt16
    public let orderedAllowedROIDigests: [ExactDigest32]
    public let redactedLumaDigest: ExactDigest32

    public init(
        unitChallenge: ExactDigest32,
        capabilityManifestDigest: ExactDigest32,
        privacyMaskManifestDigest: ExactDigest32,
        frameOrdinal: UInt32,
        continuousClockNS: UInt64,
        pageStateCode: UInt16,
        layoutCode: UInt16,
        safeROIProfileCode: UInt16,
        orderedAllowedROIDigests: [ExactDigest32],
        redactedLumaDigest: ExactDigest32
    ) {
        self.unitChallenge = unitChallenge
        self.capabilityManifestDigest = capabilityManifestDigest
        self.privacyMaskManifestDigest = privacyMaskManifestDigest
        self.frameOrdinal = frameOrdinal
        self.continuousClockNS = continuousClockNS
        self.pageStateCode = pageStateCode
        self.layoutCode = layoutCode
        self.safeROIProfileCode = safeROIProfileCode
        self.orderedAllowedROIDigests = orderedAllowedROIDigests
        self.redactedLumaDigest = redactedLumaDigest
    }

    public func toCanonicalCBOR() throws -> Data {
        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .byteString(unitChallenge.bytes),
            .byteString(capabilityManifestDigest.bytes),
            .byteString(privacyMaskManifestDigest.bytes),
            .unsigned(UInt64(frameOrdinal)),
            .unsigned(continuousClockNS),
            .unsigned(UInt64(pageStateCode)),
            .unsigned(UInt64(layoutCode)),
            .unsigned(UInt64(overlayStateCode)),
            .unsigned(UInt64(safeROIProfileCode)),
            .array(orderedAllowedROIDigests.map { .byteString($0.bytes) }),
            .byteString(redactedLumaDigest.bytes)
        ]
        let encoded = try CanonicalCBOR.encode(.array(items))
        guard encoded.count <= 768 else {
            throw PrivacyAdmissionError.evidencePreimageTooLarge(encoded.count)
        }
        return encoded
    }

    public func computeDigest() throws -> ExactDigest32 {
        ExactDigest32.sha256(of: try toCanonicalCBOR())
    }
}

public struct AdmittedRedactedArchiveFrameV1: Equatable, Sendable {
    public let frameOrdinal: UInt32
    public let continuousClockNS: UInt64
    public let controlEventCountSeen: UInt32
    public let pageStateCode: UInt16
    public let layoutCode: UInt16
    public let safeROIProfileCode: UInt16
    public let uiClassifierEvidence: UIClassifierEvidenceV1
    public let redactedLumaBytes: Data // 230,400 bytes

    public init(
        frameOrdinal: UInt32,
        continuousClockNS: UInt64,
        controlEventCountSeen: UInt32,
        pageStateCode: UInt16,
        layoutCode: UInt16,
        safeROIProfileCode: UInt16,
        uiClassifierEvidence: UIClassifierEvidenceV1,
        redactedLumaBytes: Data
    ) {
        self.frameOrdinal = frameOrdinal
        self.continuousClockNS = continuousClockNS
        self.controlEventCountSeen = controlEventCountSeen
        self.pageStateCode = pageStateCode
        self.layoutCode = layoutCode
        self.safeROIProfileCode = safeROIProfileCode
        self.uiClassifierEvidence = uiClassifierEvidence
        self.redactedLumaBytes = redactedLumaBytes
    }
}

public enum ArchivePrivacyMaskV1 {
    public static func applyMask(scratchLuma: inout Data, allowedROIs: [SafeROI]) -> Data {
        var masked = Data(repeating: 0, count: ArchiveLumaNormalizerV1.targetByteCount)
        let w = ArchiveLumaNormalizerV1.targetWidth
        let h = ArchiveLumaNormalizerV1.targetHeight

        masked.withUnsafeMutableBytes { dstPtr in
            let dst = dstPtr.bindMemory(to: UInt8.self)
            scratchLuma.withUnsafeBytes { srcPtr in
                let src = srcPtr.bindMemory(to: UInt8.self)

                for roi in allowedROIs {
                    let startX = max(0, roi.x)
                    let endX = min(w, roi.x + roi.width)
                    let startY = max(0, roi.y)
                    let endY = min(h, roi.y + roi.height)

                    guard startX < endX && startY < endY else { continue }

                    for y in startY..<endY {
                        let rowOffset = y * w
                        for x in startX..<endX {
                            dst[rowOffset + x] = src[rowOffset + x]
                        }
                    }
                }
            }
        }

        // Explicit zeroing of scratchLuma
        scratchLuma.resetBytes(in: 0..<scratchLuma.count)
        return masked
    }

    public static func computeROIDigests(redactedLuma: Data, allowedROIs: [SafeROI]) -> [ExactDigest32] {
        let w = ArchiveLumaNormalizerV1.targetWidth
        let h = ArchiveLumaNormalizerV1.targetHeight

        return allowedROIs.map { roi in
            let startX = max(0, roi.x)
            let endX = min(w, roi.x + roi.width)
            let startY = max(0, roi.y)
            let endY = min(h, roi.y + roi.height)

            guard startX < endX && startY < endY else {
                return ExactDigest32.sha256(of: Data())
            }

            var roiBytes = Data()
            roiBytes.reserveCapacity((endX - startX) * (endY - startY))

            redactedLuma.withUnsafeBytes { ptr in
                let bytes = ptr.bindMemory(to: UInt8.self)
                for y in startY..<endY {
                    let rowOffset = y * w
                    roiBytes.append(contentsOf: bytes[rowOffset + startX ..< rowOffset + endX])
                }
            }
            return ExactDigest32.sha256(of: roiBytes)
        }
    }
}

public enum PerFrameArchivePrivacyAdmissionV1 {
    public static func admitFrame(
        scratchLuma: inout Data,
        rawRGBScratch: inout Data,
        frameOrdinal: UInt32,
        continuousClockNS: UInt64,
        controlEventCountSeen: UInt32,
        pageStateCode: UInt16,
        layoutCode: UInt16,
        overlayStateCode: UInt16,
        safeROIProfileCode: UInt16,
        unitChallenge: ExactDigest32,
        capabilityManifestDigest: ExactDigest32,
        manifest: PrivacyMaskManifestV1
    ) throws -> AdmittedRedactedArchiveFrameV1 {
        func failAdmission(_ error: PrivacyAdmissionError) throws -> Never {
            // Immediately zero scratch buffers
            scratchLuma.resetBytes(in: 0..<scratchLuma.count)
            rawRGBScratch.resetBytes(in: 0..<rawRGBScratch.count)
            throw error
        }

        guard overlayStateCode == 0 else {
            try failAdmission(.forbiddenOverlayState(overlayStateCode))
        }

        guard let allowedROIs = manifest.allowedProfiles[safeROIProfileCode],
              !allowedROIs.isEmpty && allowedROIs.count <= 16 else {
            try failAdmission(.invalidSafeROIProfile(safeROIProfileCode))
        }

        guard pageStateCode > 0 else {
            try failAdmission(.unknownPageState(pageStateCode))
        }

        guard layoutCode > 0 else {
            try failAdmission(.unknownLayout(layoutCode))
        }

        // Apply mask and zero scratchLuma
        let masked = ArchivePrivacyMaskV1.applyMask(scratchLuma: &scratchLuma, allowedROIs: allowedROIs)
        rawRGBScratch.resetBytes(in: 0..<rawRGBScratch.count)

        // Compute digests
        let roiDigests = ArchivePrivacyMaskV1.computeROIDigests(redactedLuma: masked, allowedROIs: allowedROIs)
        let lumaDigest = ExactDigest32.sha256(of: masked)

        let evidence = UIClassifierEvidenceV1(
            unitChallenge: unitChallenge,
            capabilityManifestDigest: capabilityManifestDigest,
            privacyMaskManifestDigest: manifest.privacyMaskManifestDigest,
            frameOrdinal: frameOrdinal,
            continuousClockNS: continuousClockNS,
            pageStateCode: pageStateCode,
            layoutCode: layoutCode,
            safeROIProfileCode: safeROIProfileCode,
            orderedAllowedROIDigests: roiDigests,
            redactedLumaDigest: lumaDigest
        )

        return AdmittedRedactedArchiveFrameV1(
            frameOrdinal: frameOrdinal,
            continuousClockNS: continuousClockNS,
            controlEventCountSeen: controlEventCountSeen,
            pageStateCode: pageStateCode,
            layoutCode: layoutCode,
            safeROIProfileCode: safeROIProfileCode,
            uiClassifierEvidence: evidence,
            redactedLumaBytes: masked
        )
    }
}
