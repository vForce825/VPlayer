// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerCore

final class XMLTVParserTests: XCTestCase {
    func testStreamsTimezoneAndCrossDayProgramme() throws {
        let sink = CollectingXMLTVSink()
        let summary = try XMLTVParser().parse(fileURL: fixtureURL("epg/timezones.xml"), into: sink)

        XCTAssertEqual(summary, XMLTVParseSummary(channelCount: 1, programmeCount: 1))
        XCTAssertEqual(sink.channels[0].displayNames, ["五星体育频道"])
        XCTAssertEqual(sink.channels[0].iconURL?.absoluteString, "https://img.example/1287.png")
        XCTAssertEqual(sink.programmes[0].stop.timeIntervalSince(sink.programmes[0].start), 5_400)
        XCTAssertEqual(
            sink.programmes[0].id,
            "d331014f794c89938a836f29d49d52efaa0dc191ec5b945d52b385ca02d3e9b8"
        )
        XCTAssertEqual(sink.programmes[0].subtitle, "直播")
        XCTAssertEqual(sink.programmes[0].summary, "跨日节目")
        XCTAssertEqual(sink.programmes[0].categories, ["体育"])
    }

    func testMalformedXMLDoesNotEmitACompletedProgramme() throws {
        let sink = CollectingXMLTVSink()

        XCTAssertThrowsError(try XMLTVParser().parse(fileURL: fixtureURL("epg/malformed.xml"), into: sink))
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testParsesUTCAndPositiveOffsetAsTheSameInstant() throws {
        XCTAssertEqual(
            try XMLTVTimeParser().parse("20260718150000 Z"),
            try XMLTVTimeParser().parse("20260718230000 +0800")
        )
    }

    func testPreservesCDATAInTitleAndDescription() throws {
        let sink = CollectingXMLTVSink()

        XCTAssertEqual(
            try XMLTVParser().parse(fileURL: fixtureURL("epg/cdata.xml"), into: sink),
            XMLTVParseSummary(channelCount: 0, programmeCount: 1)
        )
        XCTAssertEqual(sink.programmes[0].title, "News & Weather")
        XCTAssertEqual(sink.programmes[0].summary, "Clouds < rain & wind")
    }

    func testRejectsEntityDeclarationBeforeAcceptingEvents() throws {
        let sink = CollectingXMLTVSink()

        XCTAssertThrowsError(try XMLTVParser().parse(fileURL: fixtureURL("epg/entity.xml"), into: sink)) {
            XCTAssertEqual($0 as? XMLTVParserError, .entityDeclarationForbidden)
        }
        XCTAssertTrue(sink.channels.isEmpty)
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testDefaultsMissingTimezoneToUTCAndRejectsInvalidZone() throws {
        let parser = XMLTVTimeParser()

        XCTAssertEqual(
            try parser.parse("20260718150000"),
            try parser.parse("20260718150000 Z")
        )
        XCTAssertThrowsError(try parser.parse("20260718150000 UTC")) {
            XCTAssertEqual($0 as? XMLTVTimeError, .invalid("20260718150000 UTC"))
        }
    }

    func testRejectsNestingDeeperThanThirtyTwoElements() throws {
        let nestedElements = String(repeating: "<node>", count: 32)
            + String(repeating: "</node>", count: 32)
        let sink = CollectingXMLTVSink()

        try withTemporaryXML("<tv>\(nestedElements)</tv>") { fileURL in
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: fileURL, into: sink)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveDepth)
            }
        }
        XCTAssertTrue(sink.channels.isEmpty)
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testRejectsSupportedTextLargerThanOneMiB() throws {
        let oversizedName = String(repeating: "a", count: 1_048_577)
        let sink = CollectingXMLTVSink()

        try withTemporaryXML("<tv><channel id=\"large\"><display-name>\(oversizedName)</display-name></channel></tv>") {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveText)
            }
        }
        XCTAssertTrue(sink.channels.isEmpty)
    }

    func testRejectsProgrammeWhoseStopDoesNotFollowStart() throws {
        let xml = """
            <tv><programme channel="one" start="20260718150000 Z" stop="20260718150000 Z">
              <title>Zero duration</title>
            </programme></tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink)) {
                XCTAssertEqual($0 as? XMLTVParserError, .invalidProgramme)
            }
        }
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testPreservesBuiltInEntityTextWithoutTreatingItAsADeclaration() throws {
        let xml = """
            <tv><programme channel="one" start="20260718150000 Z" stop="20260718160000 Z">
              <title>News &amp; Weather</title>
            </programme></tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertNoThrow(try XMLTVParser().parse(fileURL: $0, into: sink))
        }
        XCTAssertEqual(sink.programmes.map(\.title), ["News & Weather"])
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        let parts = relativePath.split(separator: "/").map(String.init)
        let filename = parts.last!
        let directory = parts.dropLast().joined(separator: "/")
        return Bundle(for: Self.self).url(
            forResource: filename,
            withExtension: nil,
            subdirectory: directory
        )!
    }

    private func withTemporaryXML(_ xml: String, perform: (URL) throws -> Void) throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLTVParserTests-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try perform(fileURL)
    }
}

private final class CollectingXMLTVSink: XMLTVEventSink {
    private(set) var channels: [EPGChannel] = []
    private(set) var programmes: [Programme] = []

    func accept(channel: EPGChannel) throws {
        channels.append(channel)
    }

    func accept(programme: Programme) throws {
        programmes.append(programme)
    }
}
