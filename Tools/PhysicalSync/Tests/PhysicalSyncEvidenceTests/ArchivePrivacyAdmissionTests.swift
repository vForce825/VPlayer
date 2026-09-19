// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class ArchivePrivacyAdmissionTests: XCTestCase {
    func testRGB8ToLumaNormalization() throws {
        // 1920x1080 source image with uniform pure white (255, 255, 255)
        let count = 1920 * 1080 * 3
        let whiteRGB = Data(repeating: 255, count: count)
        let luma = try ArchiveLumaNormalizerV1.normalizeRGB8ToLuma(sourceRGB: whiteRGB, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(luma.count, 230400) // 640 x 360

        // White luma: Y = clamp8((13933*255 + 46871*255 + 4732*255 + 32768) >> 16)
        // (65536 * 255 + 32768) >> 16 = (16711680 + 32768) >> 16 = 16744448 >> 16 = 255
        XCTAssertEqual(luma[0], 255)
        XCTAssertEqual(luma[230399], 255)

        // Pure black
        let blackRGB = Data(repeating: 0, count: count)
        let blackLuma = try ArchiveLumaNormalizerV1.normalizeRGB8ToLuma(sourceRGB: blackRGB, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(blackLuma[0], 0)
    }

    func testMaskingPreservesAllowedROIsAndZeroesOutside() {
        // Create 640x360 buffer of all 0xFF
        var scratch = Data(repeating: 0xFF, count: 230400)
        let rois = [SafeROI(x: 10, y: 10, width: 20, height: 20)]
        let masked = ArchivePrivacyMaskV1.applyMask(scratchLuma: &scratch, allowedROIs: rois)

        // Scratch must be zeroed out
        XCTAssertEqual(scratch, Data(repeating: 0, count: 230400))

        // In masked, pixel (10, 10) must be 255
        let indexInROI = 10 * 640 + 10
        XCTAssertEqual(masked[indexInROI], 0xFF)

        // Pixel (0, 0) outside ROI must be 0
        XCTAssertEqual(masked[0], 0x00)
    }

    func testPixelInjectionOutsideAllowedROIsDoesNotAffectMaskedBytesOrDigest() {
        let rois = [SafeROI(x: 50, y: 50, width: 30, height: 30)]

        // Frame 1: scratch with text/noise outside ROI
        var scratch1 = Data(repeating: 0, count: 230400)
        // Inside ROI: set to 0xAA
        for y in 50..<80 {
            for x in 50..<80 {
                scratch1[y * 640 + x] = 0xAA
            }
        }
        // Outside ROI: sensitive words / random pixels
        scratch1[0] = 0x12
        scratch1[100] = 0x99

        // Frame 2: identical inside ROI, but different text/noise outside ROI
        var scratch2 = Data(repeating: 0, count: 230400)
        for y in 50..<80 {
            for x in 50..<80 {
                scratch2[y * 640 + x] = 0xAA
            }
        }
        scratch2[0] = 0x88
        scratch2[100] = 0x44

        let masked1 = ArchivePrivacyMaskV1.applyMask(scratchLuma: &scratch1, allowedROIs: rois)
        let masked2 = ArchivePrivacyMaskV1.applyMask(scratchLuma: &scratch2, allowedROIs: rois)

        // The sealed masked bytes must be bit-for-bit identical!
        XCTAssertEqual(masked1, masked2)
        XCTAssertEqual(ExactDigest32.sha256(of: masked1), ExactDigest32.sha256(of: masked2))
    }

    func testUIClassifierEvidencePreimageSizeConstraint() throws {
        let digests = [TestFixtures.zeroDigest32, TestFixtures.sampleChallenge]
        let evidence = UIClassifierEvidenceV1(
            unitChallenge: TestFixtures.sampleChallenge,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest,
            privacyMaskManifestDigest: TestFixtures.samplePrivacyMaskManifestDigest,
            frameOrdinal: 1,
            continuousClockNS: 1000000000,
            pageStateCode: 1,
            layoutCode: 1,
            safeROIProfileCode: 1,
            orderedAllowedROIDigests: digests,
            redactedLumaDigest: TestFixtures.zeroDigest32
        )
        let cbor = try evidence.toCanonicalCBOR()
        XCTAssertLessThanOrEqual(cbor.count, 768)
    }

    func testAdmissionRejectsOverlayAndFreeText() {
        var scratchLuma = Data(repeating: 0, count: 230400)
        var rawScratch = Data(repeating: 0, count: 1920 * 1080 * 3)
        let manifest = TestFixtures.makeTestPrivacyManifest()

        // overlayStateCode != 0 must be rejected
        XCTAssertThrowsError(try PerFrameArchivePrivacyAdmissionV1.admitFrame(
            scratchLuma: &scratchLuma,
            rawRGBScratch: &rawScratch,
            frameOrdinal: 0,
            continuousClockNS: 100000000,
            controlEventCountSeen: 0,
            pageStateCode: 1,
            layoutCode: 1,
            overlayStateCode: 1, // Invalid overlay!
            safeROIProfileCode: 1,
            unitChallenge: TestFixtures.sampleChallenge,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest,
            manifest: manifest
        )) { error in
            XCTAssertEqual(error as? PrivacyAdmissionError, .forbiddenOverlayState(1))
        }

        // On admission failure, scratch buffers must be wiped clean
        XCTAssertEqual(scratchLuma, Data(repeating: 0, count: 230400))
        XCTAssertEqual(rawScratch, Data(repeating: 0, count: 1920 * 1080 * 3))
    }

    func testDegenerateAndInvertedROIBounds() {
        let luma = Data(repeating: 0x7F, count: 230400)
        let degenerateROIs = [
            SafeROI(x: 100, y: 100, width: -10, height: 20), // Negative width
            SafeROI(x: 100, y: 100, width: 20, height: -10), // Negative height
            SafeROI(x: 700, y: 100, width: 20, height: 20),  // Out of bounds right
            SafeROI(x: 100, y: 400, width: 20, height: 20),  // Out of bounds bottom
            SafeROI(x: 100, y: 100, width: 0, height: 20),   // Zero width
            SafeROI(x: 100, y: 100, width: 20, height: 0),   // Zero height
        ]

        // computeROIDigests must not crash with negative capacity trap, and should return sha256(empty Data)
        let emptyDigest = ExactDigest32.sha256(of: Data())
        let digests = ArchivePrivacyMaskV1.computeROIDigests(redactedLuma: luma, allowedROIs: degenerateROIs)
        XCTAssertEqual(digests.count, degenerateROIs.count)
        for digest in digests {
            XCTAssertEqual(digest, emptyDigest)
        }

        // applyMask with degenerate ROIs must also safely ignore them without crashing
        var scratch = luma
        let masked = ArchivePrivacyMaskV1.applyMask(scratchLuma: &scratch, allowedROIs: degenerateROIs)
        XCTAssertEqual(masked, Data(repeating: 0, count: 230400))
    }
}
