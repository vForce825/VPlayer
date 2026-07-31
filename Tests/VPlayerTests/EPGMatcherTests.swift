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

    func testMatchesAUniqueSingleSubstitutionCandidate() {
        XCTAssertEqual(
            match(tvgID: nil, tvgName: "Sports HD", names: [("sports-hd", ["Spurts HD"])]),
            .matched(xmltvChannelID: "sports-hd", method: .fuzzy)
        )
    }

    func testMatchesCandidateWithOneCharacterDeletedFromPlaylistName() {
        XCTAssertEqual(
            match(tvgID: nil, tvgName: "Sports HD", names: [("sport-hd", ["Sport HD"])]),
            .matched(xmltvChannelID: "sport-hd", method: .fuzzy)
        )
    }

    func testDoesNotTreatAdjacentTranspositionAsOneEdit() {
        XCTAssertEqual(
            match(tvgID: nil, tvgName: "Sports HD", names: [("sports-hd", ["Sprots HD"])]),
            .unmatched
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

    func testBatchMatcherPreservesManualExactNameFuzzyAndUnmatchedSemantics() {
        let manual = makeChannel(
            tvgID: "automatic-id",
            tvgName: nil,
            path: "manual"
        )
        let exactID = makeChannel(
            tvgID: "exact-id",
            tvgName: nil,
            path: "exact-id"
        )
        let exactName = makeChannel(
            tvgID: nil,
            tvgName: "Five Star Sports",
            path: "exact-name"
        )
        let fuzzy = makeChannel(
            tvgID: nil,
            tvgName: "Sport HD",
            path: "fuzzy"
        )
        let unmatched = makeChannel(
            tvgID: nil,
            tvgName: "No Match",
            path: "unmatched"
        )
        let results = EPGMatcher.matches(
            channels: [manual, exactID, exactName, fuzzy, unmatched],
            epgChannels: [
                EPGChannel(id: "manual-id", displayNames: ["Manual"], iconURL: nil),
                EPGChannel(id: "exact-id", displayNames: ["Other"], iconURL: nil),
                EPGChannel(id: "sports", displayNames: ["Five-Star Sports"], iconURL: nil),
                EPGChannel(id: "sports-hd", displayNames: ["Sports HD"], iconURL: nil),
            ],
            manualMappingsByChannelID: [manual.id: "manual-id"]
        )

        XCTAssertEqual(
            results[manual.id],
            .matched(xmltvChannelID: "manual-id", method: .manual)
        )
        XCTAssertEqual(
            results[exactID.id],
            .matched(xmltvChannelID: "exact-id", method: .exactID)
        )
        XCTAssertEqual(
            results[exactName.id],
            .matched(xmltvChannelID: "sports", method: .exactName)
        )
        XCTAssertEqual(
            results[fuzzy.id],
            .matched(xmltvChannelID: "sports-hd", method: .fuzzy)
        )
        XCTAssertEqual(results[unmatched.id], .unmatched)
    }

    func testBatchMatcherHandlesLargeExactIDCorpus() {
        let count = 10_000
        let channels = (0..<count).map { index in
            makeChannel(
                tvgID: "epg-\(index)",
                tvgName: nil,
                path: "large/\(index)"
            )
        }
        let epgChannels = (0..<count).map { index in
            EPGChannel(
                id: "epg-\(index)",
                displayNames: ["Channel \(index)"],
                iconURL: nil
            )
        }

        let results = EPGMatcher.matches(
            channels: channels,
            epgChannels: epgChannels,
            manualMappingsByChannelID: [:]
        )

        XCTAssertEqual(results.count, count)
        XCTAssertEqual(
            results[channels[0].id],
            .matched(xmltvChannelID: "epg-0", method: .exactID)
        )
        XCTAssertEqual(
            results[channels[count - 1].id],
            .matched(xmltvChannelID: "epg-\(count - 1)", method: .exactID)
        )
    }

    func testBatchMatcherHandlesLargeUnmatchedCorpusWithoutCandidateScanning() {
        let count = 2_000
        let channels = (0..<count).map { index in
            makeChannel(
                tvgID: nil,
                tvgName: "Playlist Alpha \(index)",
                displayName: "Playlist Backup \(index)",
                path: "unmatched/\(index)"
            )
        }
        let epgChannels = (0..<count).map { index in
            EPGChannel(
                id: "guide-\(index)",
                displayNames: ["Schedule Omega \(index)"],
                iconURL: nil
            )
        }

        let results = EPGMatcher.matches(
            channels: channels,
            epgChannels: epgChannels,
            manualMappingsByChannelID: [:]
        )

        XCTAssertEqual(results.count, count)
        XCTAssertTrue(results.values.allSatisfy { $0 == .unmatched })
    }

    func testCancellationAwareBatchMatcherChecksDuringPlaylistTraversal() {
        enum ExpectedCancellation: Error {
            case cancelled
        }
        let channels = (0..<100).map { index in
            makeChannel(
                tvgID: nil,
                tvgName: "Playlist Alpha \(index)",
                path: "cancel/\(index)"
            )
        }
        var cancellationCheckCount = 0

        XCTAssertThrowsError(try EPGMatcher.matches(
            channels: channels,
            epgChannels: [],
            manualMappingsByChannelID: [:],
            cancellationCheck: {
                cancellationCheckCount += 1
                if cancellationCheckCount == 3 {
                    throw ExpectedCancellation.cancelled
                }
            }
        )) { error in
            XCTAssertTrue(error is ExpectedCancellation)
        }
        XCTAssertEqual(cancellationCheckCount, 3)
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

    private func makeChannel(
        tvgID: String?,
        tvgName: String?,
        displayName: String = "Default Channel",
        path: String = "live"
    ) -> Channel {
        Channel(
            sourceProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: displayName,
            streamURL: URL(string: "https://example.test/\(path)")!,
            tvgID: tvgID,
            tvgName: tvgName,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
    }
}
