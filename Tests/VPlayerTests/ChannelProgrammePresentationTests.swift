// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer
@testable import VPlayerCore

@MainActor
final class ChannelProgrammePresentationTests: XCTestCase {
    func testSelectsCurrentNextAndProgressAtProgrammeBoundary() {
        let first = programme(title: "新闻", start: 0, stop: 1_800)
        let second = programme(title: "天气", start: 1_800, stop: 3_600)

        let during = ChannelProgrammePresentation.resolve(
            programmes: [first, second],
            at: date(900)
        )
        XCTAssertEqual(during.current?.title, "新闻")
        XCTAssertEqual(during.next?.title, "天气")
        XCTAssertEqual(during.progress ?? -1, 0.5, accuracy: 0.0001)

        let boundary = ChannelProgrammePresentation.resolve(
            programmes: [first, second],
            at: date(1_800)
        )
        XCTAssertEqual(boundary.current?.title, "天气")
        XCTAssertNil(boundary.next)
        XCTAssertEqual(boundary.progress ?? -1, 0, accuracy: 0.0001)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func programme(title: String, start: TimeInterval, stop: TimeInterval) -> Programme {
        Programme(
            id: title,
            xmltvChannelID: "channel",
            start: date(start),
            stop: date(stop),
            title: title,
            subtitle: nil,
            summary: nil,
            categories: []
        )
    }
}
