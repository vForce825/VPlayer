// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class PhysicalSyncEnvironmentTests: XCTestCase {
    func testReceipt38SampleStrictness() throws {
        // 38 identical samples of 0.5f
        let validSamples = Array(repeating: Float(0.5), count: 38)
        let receipt = try HomePodOutputConfigurationReceiptV2(
            volumeSamples: validSamples,
            soundCheck: .disabled,
            reduceBass: .disabled,
            spatialAudio: .disabled,
            reduceLoudSounds: .disabled,
            enhanceDialogue: .disabled,
            wirelessAudioSync: .notCalibrated,
            settingsEvidenceDigest: TestFixtures.zeroDigest32,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest
        )
        XCTAssertEqual(receipt.volumeScalarBitPattern, Float(0.5).bitPattern)
        XCTAssertEqual(receipt.volumeSampleCount, 38)

        // Reject 37 samples
        XCTAssertThrowsError(try HomePodOutputConfigurationReceiptV2(
            volumeSamples: Array(repeating: Float(0.5), count: 37),
            soundCheck: .disabled,
            reduceBass: .disabled,
            spatialAudio: .disabled,
            reduceLoudSounds: .disabled,
            enhanceDialogue: .disabled,
            wirelessAudioSync: .notCalibrated,
            settingsEvidenceDigest: TestFixtures.zeroDigest32,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest
        ))

        // Reject non-identical sample at index 20
        var nonIdentical = validSamples
        nonIdentical[20] = 0.51
        XCTAssertThrowsError(try HomePodOutputConfigurationReceiptV2(
            volumeSamples: nonIdentical,
            soundCheck: .disabled,
            reduceBass: .disabled,
            spatialAudio: .disabled,
            reduceLoudSounds: .disabled,
            enhanceDialogue: .disabled,
            wirelessAudioSync: .notCalibrated,
            settingsEvidenceDigest: TestFixtures.zeroDigest32,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest
        ))

        // Reject NaN or Inf or out of range
        XCTAssertThrowsError(try HomePodOutputConfigurationReceiptV2(
            volumeSamples: Array(repeating: Float.nan, count: 38),
            soundCheck: .disabled,
            reduceBass: .disabled,
            spatialAudio: .disabled,
            reduceLoudSounds: .disabled,
            enhanceDialogue: .disabled,
            wirelessAudioSync: .notCalibrated,
            settingsEvidenceDigest: TestFixtures.zeroDigest32,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest
        ))

        XCTAssertThrowsError(try HomePodOutputConfigurationReceiptV2(
            volumeSamples: Array(repeating: Float(1.5), count: 38),
            soundCheck: .disabled,
            reduceBass: .disabled,
            spatialAudio: .disabled,
            reduceLoudSounds: .disabled,
            enhanceDialogue: .disabled,
            wirelessAudioSync: .notCalibrated,
            settingsEvidenceDigest: TestFixtures.zeroDigest32,
            capabilityManifestDigest: TestFixtures.sampleCapabilityDigest
        ))
    }

    func testClosedSettingEnumsDifferentiation() {
        let r1 = TestFixtures.makeTestReceipt(soundCheck: .disabled)
        let r2 = TestFixtures.makeTestReceipt(soundCheck: .enabled)
        let r3 = TestFixtures.makeTestReceipt(soundCheck: .unsupported)
        XCTAssertNotEqual(r1, r2)
        XCTAssertNotEqual(r1, r3)
        XCTAssertNotEqual(r2, r3)
    }

    func testEnvironmentIdentity14Items() throws {
        let env = TestFixtures.makeTestEnvironmentIdentity()
        let cbor = env.toCanonicalCBOR()
        let decoded = try CanonicalCBOR.decode(cbor)
        guard case .array(let items) = decoded else {
            XCTFail("Environment identity must decode to CBOR array")
            return
        }
        XCTAssertEqual(items.count, 14)
        XCTAssertEqual(items[0], .unsigned(1)) // schemaVersion = 1
    }
}
