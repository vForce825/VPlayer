// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer
@testable import VPlayerCore

final class ChannelSectionsTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testGroupingKeepsPlaylistOrderWithinAndAcrossGroups() {
        let channels = [
            channel(name: "A", group: "央视", order: 0),
            channel(name: "B", group: "卫视", order: 1),
            channel(name: "C", group: "央视", order: 2),
        ]

        let sections = ChannelSectionBuilder.sections(channels: channels, grouping: .playlistGroups)

        // Groups appear in the order the playlist introduces them, not sorted.
        XCTAssertEqual(sections.map(\.title), ["央视", "卫视"])
        XCTAssertEqual(sections[0].channels.map(\.displayName), ["A", "C"])
        XCTAssertEqual(sections[1].channels.map(\.displayName), ["B"])
    }

    func testChannelsWithoutAUsableGroupTitleCollectIntoOneSectionInsteadOfDisappearing() {
        let channels = [
            channel(name: "Missing", group: nil, order: 0),
            channel(name: "Empty", group: "", order: 1),
            channel(name: "Blank", group: "   \n", order: 2),
            channel(name: "Grouped", group: "央视", order: 3),
        ]

        let sections = ChannelSectionBuilder.sections(channels: channels, grouping: .playlistGroups)

        XCTAssertEqual(sections.map(\.title), [ChannelSectionBuilder.ungroupedTitle, "央视"])
        XCTAssertEqual(
            sections[0].channels.map(\.displayName),
            ["Missing", "Empty", "Blank"]
        )
    }

    func testGroupTitlesAreTrimmedSoPaddingDoesNotSplitAGroup() {
        let channels = [
            channel(name: "A", group: "央视", order: 0),
            channel(name: "B", group: "  央视  ", order: 1),
        ]

        let sections = ChannelSectionBuilder.sections(channels: channels, grouping: .playlistGroups)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].channels.map(\.displayName), ["A", "B"])
    }

    func testPlaylistOrderProducesOneUntitledSectionThatKeepsEveryChannel() {
        let channels = [
            channel(name: "A", group: "央视", order: 0),
            channel(name: "B", group: nil, order: 1),
            channel(name: "C", group: "卫视", order: 2),
        ]

        let sections = ChannelSectionBuilder.sections(channels: channels, grouping: .playlistOrder)

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].channels.map(\.displayName), ["A", "B", "C"])
    }

    func testNoChannelsProducesNoSectionsInEitherMode() {
        for grouping in ChannelGrouping.allCases {
            XCTAssertTrue(
                ChannelSectionBuilder.sections(channels: [], grouping: grouping).isEmpty,
                "Expected no sections for \(grouping)"
            )
        }
    }

    private func channel(name: String, group: String?, order: Int) -> Channel {
        Channel(
            sourceProfileID: profileID,
            displayName: name,
            streamURL: URL(string: "https://example.test/\(order)")!,
            tvgID: nil,
            tvgName: nil,
            logoURL: nil,
            groupTitle: group,
            attributes: [:],
            order: order
        )
    }
}

final class ChannelBrowsingSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "channel-browsing-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testGroupingDefaultsToPlaylistGroups() {
        XCTAssertEqual(ChannelBrowsingSettingsStore(defaults: defaults).grouping, .playlistGroups)
    }

    @MainActor
    func testGroupingSurvivesRelaunch() {
        let store = ChannelBrowsingSettingsStore(defaults: defaults)
        store.grouping = .playlistOrder

        XCTAssertEqual(ChannelBrowsingSettingsStore(defaults: defaults).grouping, .playlistOrder)
    }

    @MainActor
    func testUnknownStoredValueFallsBackToGrouping() {
        defaults.set("sortedAlphabetically", forKey: ChannelBrowsingSettingsStore.storageKey)

        XCTAssertEqual(ChannelBrowsingSettingsStore(defaults: defaults).grouping, .playlistGroups)
    }
}
