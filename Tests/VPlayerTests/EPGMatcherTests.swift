// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerCore

final class EPGMatcherTests: XCTestCase {
    func testMatchesExactXMLTVID() {
        XCTAssertEqual(
            match(tvgID: "1287", tvgName: nil, names: [("1287", ["其他"])]).xmltvChannelID,
            "1287"
        )
    }

    func testMatchesNormalizedName() {
        XCTAssertEqual(
            match(tvgID: "五星体育频道", tvgName: nil, names: [("1287", ["五星 体育频道"])]).xmltvChannelID,
            "1287"
        )
    }

    func testManualOverrideWinsWhenItsTargetExists() {
        let channel = makeChannel(tvgID: "1287", tvgName: nil)
        let manualOverrideResult = EPGMatcher.match(
            channel: channel,
            epgChannels: [
                EPGChannel(id: "1287", displayNames: ["其他"], iconURL: nil),
                EPGChannel(id: "manual-id", displayNames: ["手动频道"], iconURL: nil),
            ],
            manualMapping: ManualEPGMapping(
                sourceProfileID: channel.sourceProfileID,
                channelID: channel.id,
                xmltvChannelID: "manual-id"
            )
        )

        XCTAssertEqual(manualOverrideResult.xmltvChannelID, "manual-id")
    }

    func testReturnsAmbiguousNormalizedNamesInSortedIDOrder() {
        let ambiguousNormalizedNames = match(
            tvgID: "五星体育频道",
            tvgName: nil,
            names: [("b", ["五星 体育频道"]), ("a", ["五星体育频道"])]
        )

        XCTAssertEqual(ambiguousNormalizedNames, .ambiguous(["a", "b"]))
    }

    func testMatchesAUniqueOneEditFuzzyCandidate() {
        XCTAssertEqual(
            match(tvgID: nil, tvgName: "Sport HD", names: [("sports-hd", ["Sports HD"])]).xmltvChannelID,
            "sports-hd"
        )
    }

    func testStaleManualMappingContinuesToAutomaticMatching() {
        let channel = makeChannel(tvgID: "1287", tvgName: nil)
        let result = EPGMatcher.match(
            channel: channel,
            epgChannels: [EPGChannel(id: "1287", displayNames: ["其他"], iconURL: nil)],
            manualMapping: ManualEPGMapping(
                sourceProfileID: channel.sourceProfileID,
                channelID: channel.id,
                xmltvChannelID: "removed-id"
            )
        )

        XCTAssertEqual(result, .matched(xmltvChannelID: "1287", method: .exactID))
    }

    func testStopsAtAmbiguousFuzzyCandidates() {
        let result = match(
            tvgID: nil,
            tvgName: "Sport HD",
            names: [("b", ["Sports HD"]), ("a", ["Sportz HD"])]
        )

        XCTAssertEqual(result, .ambiguous(["a", "b"]))
    }

    func testNormalizerPrecomposesAndRemovesNonAlphanumericCharacters() {
        XCTAssertEqual(EPGNameNormalizer.normalize("五星 体育-HD"), "五星体育hd")
    }

    func testFuzzyMatchingRequiresAtLeastFiveNormalizedCharacters() {
        XCTAssertFalse(EPGNameNormalizer.isConservativeFuzzyMatch("ABCD", "ABC"))
    }

    private func match(
        tvgID: String?,
        tvgName: String?,
        names: [(String, [String])]
    ) -> EPGMatchResult {
        EPGMatcher.match(
            channel: makeChannel(tvgID: tvgID, tvgName: tvgName),
            epgChannels: names.map { EPGChannel(id: $0.0, displayNames: $0.1, iconURL: nil) },
            manualMapping: nil
        )
    }

    private func makeChannel(tvgID: String?, tvgName: String?) -> Channel {
        Channel(
            sourceProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Default Channel",
            streamURL: URL(string: "https://example.test/live")!,
            tvgID: tvgID,
            tvgName: tvgName,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
    }
}
