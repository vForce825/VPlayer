// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import XCTest
@testable import VPlayer
@testable import VPlayerCore
@testable import VPlayerPlayback

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

/// These measure the production SwiftUI views in a tvOS UIKit host. The
/// two/three-line probes distinguish actual allocated line height from an
/// accessibility label that can still contain text truncated on screen.
@MainActor
final class ChannelProgrammeLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 1_920, height: 1_080)
    private lazy var programmeReferenceDate = Date()
    private let twoLines = "甲\n乙"
    private let threeLines = "甲\n乙\n丙"

    func testChannelCardAllocatesThirdTitleLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .subheadline.weight(.semibold)) { title in
            ChannelCard(channel: channel(title: title), programmes: programmes())
        }
    }

    func testChannelCardAllocatesThirdCurrentProgrammeLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .caption2) { title in
            ChannelCard(channel: channel(), programmes: programmes(current: title))
        }
    }

    func testChannelCardAllocatesThirdNextProgrammeLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .caption2) { title in
            ChannelCard(channel: channel(), programmes: programmes(next: title))
        }
    }

    func testInfoCardAllocatesThirdTitleLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .subheadline.weight(.semibold)) { title in
            infoCard(title: title)
        }
    }

    func testInfoCardAllocatesThirdCurrentProgrammeLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .caption2.weight(.semibold)) { title in
            infoCard(current: title)
        }
    }

    func testInfoCardAllocatesThirdNextProgrammeLineOnlyAtAccessibilitySize() throws {
        try assertThirdLineAllocation(font: .caption2.weight(.semibold)) { title in
            infoCard(next: title)
        }
    }

    func testInfoCardGrowsWithinThe1080pPlayerCanvasAtLargestAccessibilitySize() throws {
        // Wide content exercises the scaled width cap, while explicit newlines
        // exercise the full supported three lines without a font-dependent wrap.
        let title = "电视新闻与纪录片\n国际文化与自然\n专题节目"
        let current = "今日新闻与专题报道\n文化生活\n世界观察"
        let next = "自然地理与科学探索\n历史文化\n精彩预告"
        let card = infoCard(title: title, current: current, next: next)
        // FullScreenPlayerView reserves 56 points trailing and 36 above the card.
        let available = CGSize(width: canvas.width - 56, height: canvas.height - 36)
        let standard = try measure(card, typeSize: .large, proposal: available)
        let accessible = try measure(card, typeSize: .accessibility5, proposal: available)

        XCTAssertGreaterThan(accessible.width, standard.width)
        XCTAssertGreaterThan(accessible.height, standard.height)
        XCTAssertLessThanOrEqual(accessible.width, 900)
        XCTAssertLessThanOrEqual(accessible.height, available.height,
            "The complete three-line info card must remain inside the player canvas")
    }

    private func assertThirdLineAllocation<Content: View>(
        font: Font,
        file: StaticString = #filePath,
        line: UInt = #line,
        content: (String) -> Content
    ) throws {
        // Keep the proposed width fixed so width growth cannot masquerade as
        // extra text height. It also leaves room for the next-programme prefix.
        let proposal = CGSize(width: 780, height: canvas.height)
        let standardTwo = try measure(content(twoLines), typeSize: .large, proposal: proposal)
        let standardThree = try measure(content(threeLines), typeSize: .large, proposal: proposal)
        let accessibleTwo = try measure(content(twoLines), typeSize: .accessibility5, proposal: proposal)
        let accessibleThree = try measure(content(threeLines), typeSize: .accessibility5, proposal: proposal)
        let referenceTwo = try measure(
            Text(twoLines).font(font).fixedSize(horizontal: false, vertical: true),
            typeSize: .accessibility5,
            proposal: proposal
        )
        let referenceThree = try measure(
            Text(threeLines).font(font).fixedSize(horizontal: false, vertical: true),
            typeSize: .accessibility5,
            proposal: proposal
        )
        let standardReference = try measure(
            Text(threeLines).font(font).fixedSize(horizontal: false, vertical: true),
            typeSize: .large,
            proposal: proposal
        )
        let extraLineHeight = referenceThree.height - referenceTwo.height

        XCTAssertGreaterThan(referenceThree.height, standardReference.height,
            "The host must actually apply accessibility font scaling", file: file, line: line)
        XCTAssertGreaterThan(extraLineHeight, 0, file: file, line: line)
        XCTAssertEqual(standardThree.height, standardTwo.height, accuracy: 2,
            "Standard type retains the compact two-line layout", file: file, line: line)
        XCTAssertEqual(accessibleThree.height - accessibleTwo.height, extraLineHeight, accuracy: 2,
            "Accessibility type must allocate the full third rendered line, not truncate it",
            file: file, line: line)
        XCTAssertLessThanOrEqual(accessibleThree.height, proposal.height,
            "The expanded content must fit the supplied height", file: file, line: line)
    }

    private func measure<Content: View>(
        _ content: Content,
        typeSize: DynamicTypeSize,
        proposal: CGSize
    ) throws -> CGSize {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let host = UIHostingController(rootView: content
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: canvas)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let result = host.sizeThatFits(in: proposal)
        XCTAssertTrue(result.width.isFinite && result.height.isFinite)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        return result
    }

    private func channel(title: String = "频道") -> Channel {
        Channel(
            sourceProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: title,
            streamURL: URL(string: "https://layout.fixture.invalid/channel.ts")!,
            tvgID: nil, tvgName: nil, logoURL: nil, groupTitle: nil,
            attributes: [:], order: 0
        )
    }

    private func programmes(current: String = "当前", next: String = "接续") -> [Programme] {
        // A wide window avoids a timeline boundary during a CI run. Logo and
        // playback URLs are never loaded by these passive production views.
        let now = programmeReferenceDate
        return [
            Programme(id: "current", xmltvChannelID: "channel",
                start: now.addingTimeInterval(-3_600), stop: now.addingTimeInterval(3_600),
                title: current, subtitle: nil, summary: nil, categories: []),
            Programme(id: "next", xmltvChannelID: "channel",
                start: now.addingTimeInterval(3_600), stop: now.addingTimeInterval(7_200),
                title: next, subtitle: nil, summary: nil, categories: [])
        ]
    }

    private func infoCard(
        title: String = "频道",
        current: String = "当前",
        next: String = "接续"
    ) -> PlayerChannelInfoOverlay {
        PlayerChannelInfoOverlay(
            presentation: PlayerChannelPresentation(
                request: PlaybackRequest(channel: channel(title: title)),
                logoURL: nil,
                programmes: programmes(current: current, next: next)
            ),
            mediaInformation: nil
        )
    }
}
