// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerCore

final class M3UParserTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    private let sourceURL = URL(string: "https://example.test/lists/custom.m3u")!

    func testAttributesUnknownKeysRelativeURLAndOrder() throws {
        let channels = try M3UParser().parse(
            data: FixtureLoader.data("playlists/attributes.m3u"),
            sourceURL: sourceURL,
            profileID: profileID
        )
        XCTAssertEqual(channels.map(\.displayName), ["五星体育 HD", "东方卫视 4K"])
        XCTAssertEqual(channels[0].tvgID, "五星体育频道")
        XCTAssertEqual(channels[0].attributes["catchup"], "default")
        XCTAssertEqual(channels[1].streamURL.absoluteString, "https://example.test/lists/relative/dongfang4k.ts")
        XCTAssertEqual(channels.map(\.order), [0, 1])
    }

    func testDuplicateNormalizedURLKeepsFirstAndUnsupportedSchemesStayVisible() throws {
        let channels = try M3UParser().parse(
            data: FixtureLoader.data("playlists/duplicates-and-schemes.m3u"),
            sourceURL: sourceURL,
            profileID: profileID
        )
        XCTAssertEqual(channels.map(\.displayName), ["First spelling", "UDP visible", "RTP visible"])
        XCTAssertEqual(channels.map { $0.streamURL.scheme!.lowercased() }, ["http", "udp", "rtp"])
        XCTAssertEqual(StreamProtocolPolicy.evaluate(channels[0].streamURL), .allowed)
        XCTAssertEqual(StreamProtocolPolicy.evaluate(channels[1].streamURL), .rejected(.multicastUnsupported))
        XCTAssertEqual(StreamProtocolPolicy.evaluate(channels[2].streamURL), .rejected(.multicastUnsupported))
    }

    func testUTF16BOMAndInvalidDocument() throws {
        var data = Data([0xFF, 0xFE])
        data.append("#EXTM3U\n#EXTINF:-1,测试\nhttps://example.test/live\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try M3UParser().parse(data: data, sourceURL: sourceURL, profileID: profileID).first?.displayName, "测试")
        XCTAssertThrowsError(try M3UParser().parse(
            data: Data("<html>error</html>".utf8), sourceURL: sourceURL, profileID: profileID
        )) { XCTAssertEqual($0 as? M3UParserError, .missingHeader) }
    }

    func testWhitespaceQuotedCommaAndMalformedMetadata() throws {
        let playlist = """

              #EXTM3U
            #EXTINF:-1 TVG-ID = "quoted id" group-title="News, Local" catchup-source=http://catchup.test,  Channel, One
              https://example.test/one
            #EXTINF:-1 malformed-token,
            https://example.test/two
            """

        let channels = try M3UParser().parse(
            data: Data(playlist.utf8), sourceURL: sourceURL, profileID: profileID
        )

        XCTAssertEqual(channels.map(\.displayName), ["Channel, One", "Unnamed channel"])
        XCTAssertEqual(channels[0].tvgID, "quoted id")
        XCTAssertEqual(channels[0].groupTitle, "News, Local")
        XCTAssertEqual(channels[0].attributes["catchup-source"], "http://catchup.test")
        XCTAssertTrue(channels[1].attributes.isEmpty)
    }

    func testHeaderWithoutValidEntriesThrowsNoChannels() {
        let playlist = """
            #EXTM3U
            #EXTINF:-1,Missing URL
            # comment instead of a URL
            """

        XCTAssertThrowsError(try M3UParser().parse(
            data: Data(playlist.utf8), sourceURL: sourceURL, profileID: profileID
        )) { XCTAssertEqual($0 as? M3UParserError, .noChannels) }
    }

    func testPlaylistTextDecoderRecognizesSupportedEncodings() throws {
        let decoder = PlaylistTextDecoder()
        XCTAssertEqual(try decoder.decode(Data([0xEF, 0xBB, 0xBF]) + Data("UTF-8".utf8)), "UTF-8")

        var utf16BigEndian = Data([0xFE, 0xFF])
        utf16BigEndian.append("测试".data(using: .utf16BigEndian)!)
        XCTAssertEqual(try decoder.decode(utf16BigEndian), "测试")

        XCTAssertEqual(try decoder.decode(Data([0xD6, 0xD0, 0xCE, 0xC4])), "中文")
        XCTAssertEqual(try decoder.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }
}
