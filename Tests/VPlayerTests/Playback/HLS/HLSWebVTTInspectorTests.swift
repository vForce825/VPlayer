// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSWebVTTInspectorTests: XCTestCase {
    func testOrdinaryCueFreeSubtitleSegmentsRemainEligible() {
        for text in [
            "WEBVTT\n\n",
            "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:126000\n\n",
            "WEBVTT synthetic segment\n\nNOTE No dialogue in this interval\n\n",
            "WEBVTT\r\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\r\n\r\n"
        ] {
            XCTAssertTrue(HLSWebVTTInspector.accepts(Data(text.utf8)), text)
        }
    }

    func testCueFreeSegmentsDoNotBypassTimestampMapValidation() {
        for text in [
            "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000\n\n",
            "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:8589934592\n\n",
            "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:61:00.000,MPEGTS:126000\n\n"
        ] {
            XCTAssertFalse(HLSWebVTTInspector.accepts(Data(text.utf8)), text)
        }
    }

    func testCueTimingAndContainerSignatureRemainRequiredWhenPresent() {
        XCTAssertTrue(HLSWebVTTInspector.accepts(Data("WEBVTT\n\n00:00.000 --> 00:01.500\nSynthetic caption\n".utf8)))
        XCTAssertFalse(HLSWebVTTInspector.accepts(Data("WEBVTT\n\n00:01.500 --> 00:00.000\nInvalid timing\n".utf8)))
        XCTAssertFalse(HLSWebVTTInspector.accepts(Data("Not a WebVTT segment\n".utf8)))
        XCTAssertFalse(HLSWebVTTInspector.accepts(Data([0xFF, 0xFE])))
    }
}
