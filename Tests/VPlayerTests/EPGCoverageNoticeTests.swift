// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer

final class EPGCoverageNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testCoverageEndingBeforeNowIsReported() {
        let coverageEnd = now.addingTimeInterval(-3 * 24 * 3_600)
        XCTAssertEqual(
            EPGCoverageNotice.staleCoverageEnd(
                coverageEnd: coverageEnd,
                programmeCount: 17_255,
                now: now
            ),
            coverageEnd
        )
    }

    func testCoverageReachingBeyondNowIsSilent() {
        XCTAssertNil(
            EPGCoverageNotice.staleCoverageEnd(
                coverageEnd: now.addingTimeInterval(1),
                programmeCount: 1,
                now: now
            )
        )
    }

    func testCoverageEndingExactlyAtNowIsReportedBecauseNothingIsOnAir() {
        XCTAssertEqual(
            EPGCoverageNotice.staleCoverageEnd(
                coverageEnd: now,
                programmeCount: 1,
                now: now
            ),
            now
        )
    }

    func testMissingOrEmptyEPGIsSilentBecauseTheRefreshStatusAlreadySaysSo() {
        XCTAssertNil(
            EPGCoverageNotice.staleCoverageEnd(
                coverageEnd: nil,
                programmeCount: 0,
                now: now
            )
        )
        XCTAssertNil(
            EPGCoverageNotice.staleCoverageEnd(
                coverageEnd: now.addingTimeInterval(-3_600),
                programmeCount: 0,
                now: now
            )
        )
    }

    func testTextNamesTheCoverageEndAndTheActionToTake() {
        let coverageEnd = now.addingTimeInterval(-3 * 24 * 3_600)
        let text = EPGCoverageNotice.text(staleCoverageEnd: coverageEnd)
        XCTAssertTrue(text.contains("节目单数据已过期"))
        XCTAssertTrue(text.contains(coverageEnd.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(text.contains("EPG 地址"))
    }
}

import UIKit

final class ZZFontProbeTests: XCTestCase {
    @MainActor
    func testPrintPreferredFontSizes() {
        var styles: [(String, UIFont.TextStyle)] = [
            ("title1", .title1), ("title2", .title2),
            ("title3", .title3), ("headline", .headline), ("subheadline", .subheadline),
            ("body", .body), ("callout", .callout), ("footnote", .footnote),
            ("caption1", .caption1), ("caption2", .caption2)
        ]
        #if !os(tvOS)
        styles.insert(("largeTitle", .largeTitle), at: 0)
        #endif
        for (name, style) in styles {
            let font = UIFont.preferredFont(forTextStyle: style)
            print("FONTPROBE \(name) size=\(font.pointSize) name=\(font.fontName)")
        }
        let field = UITextField()
        field.placeholder = "EPG 地址"
        field.text = "https://example.com"
        print("FONTPROBE UITextField default font=\(String(describing: field.font))")
    }
}
