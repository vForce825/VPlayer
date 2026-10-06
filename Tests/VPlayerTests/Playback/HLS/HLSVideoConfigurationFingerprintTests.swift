// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSVideoConfigurationFingerprintTests: XCTestCase {
    func testCanonicalHeaderOrderAndDuplicatesDoNotChangeIdentity() throws {
        let sps = Data([0x67, 0x64, 0, 0x29]), pps = Data([0x68, 0xEE, 0x3C])
        let first = try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: [sps, pps])
        XCTAssertEqual(first, try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: [pps, sps, sps]))
        XCTAssertNotEqual(first, try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: [sps, Data([0x68, 0xEE, 0x3D])]))
        XCTAssertEqual(first.count, 32)
    }
    func testMissingHeaderAndBoundedCountRemainExplicit() {
        XCTAssertThrowsError(try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: [Data([0x67, 1])]))
        XCTAssertThrowsError(try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: Array(repeating: Data([0x67, 1]), count: 65)))
        XCTAssertThrowsError(try HLSVideoConfigurationFingerprint.make(codec: .hevc, parameterSets: [Data([0x40, 1]), Data([0x42, 1])]))
    }
}
