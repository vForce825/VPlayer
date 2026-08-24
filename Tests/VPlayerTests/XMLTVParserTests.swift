// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
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
            "c1d86e3a130aaca42c323a5121442ba3b69deebdd4f2a35496427435f8830e5d"
        )
        XCTAssertEqual(sink.programmes[0].subtitle, "直播")
        XCTAssertEqual(sink.programmes[0].summary, "跨日节目")
        XCTAssertEqual(sink.programmes[0].categories, ["体育"])
    }

    func testFormerlyCollidingProgrammeFieldsProduceUniqueIDs() throws {
        let xml = """
            <tv>
              <programme channel="a|1784037600" start="20260714150000 Z" stop="20260714160000 Z">
                <title>x</title>
              </programme>
              <programme channel="a" start="20260714140000 Z" stop="20260714150000 Z">
                <title>1784044800|x</title>
              </programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertEqual(
                try XMLTVParser().parse(fileURL: $0, into: sink),
                XMLTVParseSummary(channelCount: 0, programmeCount: 2)
            )
        }

        XCTAssertEqual(sink.programmes.count, 2)
        XCTAssertEqual(Set(sink.programmes.map(\.id)).count, 2)
    }

    func testProgrammeStableIDSeparatesDelimiterCollisionPair() {
        let first = ProgrammeStableID.make(
            channelID: "a|1784037600",
            startEpochSeconds: 1_784_041_200,
            stopEpochSeconds: 1_784_044_800,
            title: "x"
        )
        let second = ProgrammeStableID.make(
            channelID: "a",
            startEpochSeconds: 1_784_037_600,
            stopEpochSeconds: 1_784_041_200,
            title: "1784044800|x"
        )

        XCTAssertNotEqual(first, second)
    }

    func testProgrammeStableIDMatchesVersionOneGoldenVector() {
        XCTAssertEqual(
            ProgrammeStableID.make(
                channelID: "channel|one",
                startEpochSeconds: 1_784_037_600,
                stopEpochSeconds: 1_784_041_200,
                title: "News|Live"
            ),
            "bd5a2fbb334a7ac577e05802e0a12eefb40cc443cd25c57e9151648b8e277d3f"
        )
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

    func testStrictTimeParserRejectsInvalidCalendarValuesZonesAndTrailingFields() throws {
        let parser = XMLTVTimeParser()
        let invalidValues = [
            "20260230000000 +0000",
            "20260229000000 +0000",
            "20261301000000 +0000",
            "20260101240000 +0000",
            "20260101235960 +0000",
            "20260101000000 +2460",
            "20260101000000 +0000 trailing",
        ]

        for raw in invalidValues {
            XCTAssertThrowsError(try parser.parse(raw), raw) {
                XCTAssertEqual($0 as? XMLTVTimeError, .invalid(raw))
            }
        }
    }

    func testStrictTimeParserAcceptsLeapDayOffsetsAndMissingZoneUTC() throws {
        let parser = XMLTVTimeParser()
        let leapDayUTC = try parser.parse("20240229010203 Z")

        XCTAssertEqual(leapDayUTC, try parser.parse("20240229090203 +0800"))
        XCTAssertEqual(leapDayUTC, try parser.parse("20240229010203"))
    }

    func testStrictTimeParserHandlesNegativeOffsetsAndFixedOffsetBoundaries() throws {
        let parser = XMLTVTimeParser()
        let leapDayUTC = try parser.parse("20240229010203 Z")

        XCTAssertEqual(leapDayUTC, try parser.parse("20240228170203 -0800"))
        XCTAssertEqual(leapDayUTC, try parser.parse("20240229010203 -0000"))
        XCTAssertEqual(leapDayUTC, try parser.parse("20240229190203 +1800"))
        XCTAssertEqual(leapDayUTC, try parser.parse("20240228070203 -1800"))
    }

    func testStrictTimeParserRejectsInvalidZoneMinutesAndOutOfRangeFixedOffsets() throws {
        let parser = XMLTVTimeParser()
        let invalidValues = [
            "20240229010203 +0060",
            "20240229010203 -0060",
            "20240229010203 +1801",
            "20240229010203 -1801",
        ]

        for raw in invalidValues {
            XCTAssertThrowsError(try parser.parse(raw), raw) {
                XCTAssertEqual($0 as? XMLTVTimeError, .invalid(raw))
            }
        }
    }

    func testStrictTimeParserRejectsNonASCIIDigits() throws {
        let raw = "２０２４０２２９０１０２０３ Z"

        XCTAssertThrowsError(try XMLTVTimeParser().parse(raw)) {
            XCTAssertEqual($0 as? XMLTVTimeError, .invalid(raw))
        }
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

    func testSkipsProgrammeWhoseStopDoesNotFollowStart() throws {
        let xml = """
            <tv><programme channel="one" start="20260718150000 Z" stop="20260718150000 Z">
              <title>Zero duration</title>
            </programme></tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertEqual(
                try XMLTVParser().parse(fileURL: $0, into: sink),
                XMLTVParseSummary(channelCount: 0, programmeCount: 0)
            )
        }
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testInvalidProgrammeDoesNotDiscardFollowingValidProgramme() throws {
        let xml = """
            <tv>
              <programme channel="one" start="20260718150000 +0800" stop="20260718150000 +0800">
                <title>结束</title>
              </programme>
              <programme channel="one" start="20260718150000 +0800" stop="20260718160000 +0800">
                <title>Valid programme</title>
              </programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertEqual(
                try XMLTVParser().parse(fileURL: $0, into: sink),
                XMLTVParseSummary(channelCount: 0, programmeCount: 1)
            )
        }
        XCTAssertEqual(sink.programmes.map(\.title), ["Valid programme"])
    }

    func testInvalidDateProgrammeDoesNotDiscardFollowingValidProgramme() throws {
        let xml = """
            <tv>
              <programme channel="one" start="20260229000000 +0000" stop="20260229010000 +0000">
                <title>Invalid date</title>
              </programme>
              <programme channel="one" start="20260301000000 +0000" stop="20260301010000 +0000">
                <title>Following valid programme</title>
              </programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertEqual(
                try XMLTVParser().parse(fileURL: $0, into: sink),
                XMLTVParseSummary(channelCount: 0, programmeCount: 1)
            )
        }
        XCTAssertEqual(sink.programmes.map(\.title), ["Following valid programme"])
    }

    func testPreservesProgrammeSinkError() throws {
        let xml = """
            <tv><programme channel="one" start="20260718150000 Z" stop="20260718160000 Z">
              <title>Sink failure</title>
            </programme></tv>
            """
        let sink = ProgrammeFailingXMLTVSink()

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink)) {
                XCTAssertEqual($0 as? XMLTVTimeError, .invalid("programme sink failure"))
            }
        }
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

    func testAllowsRawEventCountsAtExactLimits() throws {
        let xml = """
            <tv>
              <channel id="one"><display-name>One</display-name></channel>
              <channel id="two"><display-name>Two</display-name></channel>
              <programme channel="one" start="20260718150000 Z" stop="20260718160000 Z"><title>First</title></programme>
              <programme channel="one" start="20260718160000 Z" stop="20260718170000 Z"><title>Second</title></programme>
              <programme channel="two" start="20260718170000 Z" stop="20260718180000 Z"><title>Third</title></programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()
        let limits = XMLTVParseLimits(
            maximumChannels: 2,
            maximumProgrammes: 3,
            maximumEvents: 5,
            maximumDepth: 32,
            maximumTextBytes: 1_048_576
        )

        try withTemporaryXML(xml) {
            XCTAssertEqual(
                try XMLTVParser().parse(fileURL: $0, into: sink, limits: limits),
                XMLTVParseSummary(channelCount: 2, programmeCount: 3)
            )
        }
        XCTAssertEqual(sink.channels.map(\.id), ["one", "two"])
        XCTAssertEqual(sink.programmes.map(\.title), ["First", "Second", "Third"])
    }

    func testRejectsThirdRawChannelWithoutHittingCombinedLimit() throws {
        let xml = """
            <tv>
              <channel id="one"><display-name>One</display-name></channel>
              <channel id="two"><display-name>Two</display-name></channel>
              <channel id="three"><display-name>Three</display-name></channel>
            </tv>
            """
        let sink = CollectingXMLTVSink()
        let limits = XMLTVParseLimits(
            maximumChannels: 2,
            maximumProgrammes: 5,
            maximumEvents: 10,
            maximumDepth: 32,
            maximumTextBytes: 1_048_576
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink, limits: limits)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveChannels)
            }
        }
        XCTAssertEqual(sink.channels.map(\.id), ["one", "two"])
    }

    func testRejectsFourthRawProgrammeWithoutHittingCombinedLimit() throws {
        let xml = """
            <tv>
              <programme channel="one" start="20260718150000 Z" stop="20260718160000 Z"><title>First</title></programme>
              <programme channel="one" start="20260718160000 Z" stop="20260718170000 Z"><title>Second</title></programme>
              <programme channel="one" start="20260718170000 Z" stop="20260718180000 Z"><title>Third</title></programme>
              <programme channel="one" start="20260718180000 Z" stop="20260718190000 Z"><title>Fourth</title></programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()
        let limits = XMLTVParseLimits(
            maximumChannels: 5,
            maximumProgrammes: 3,
            maximumEvents: 10,
            maximumDepth: 32,
            maximumTextBytes: 1_048_576
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink, limits: limits)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveProgrammes)
            }
        }
        XCTAssertEqual(sink.programmes.map(\.title), ["First", "Second", "Third"])
    }

    func testRejectsSixthMixedRawEventWithoutHittingPerTypeLimits() throws {
        let xml = """
            <tv>
              <channel id="one"><display-name>One</display-name></channel>
              <channel id="two"><display-name>Two</display-name></channel>
              <channel id="three"><display-name>Three</display-name></channel>
              <programme channel="one" start="20260718150000 Z" stop="20260718160000 Z"><title>First</title></programme>
              <programme channel="two" start="20260718160000 Z" stop="20260718170000 Z"><title>Second</title></programme>
              <programme channel="three" start="20260718170000 Z" stop="20260718180000 Z"><title>Third</title></programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()
        let limits = XMLTVParseLimits(
            maximumChannels: 5,
            maximumProgrammes: 5,
            maximumEvents: 5,
            maximumDepth: 32,
            maximumTextBytes: 1_048_576
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink, limits: limits)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveEvents)
            }
        }
        XCTAssertEqual(sink.channels.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(sink.programmes.map(\.title), ["First", "Second"])
    }

    func testInvalidProgrammesStillConsumeRawProgrammeQuota() throws {
        let xml = """
            <tv>
              <programme channel="one" start="invalid" stop="invalid"><title>Invalid one</title></programme>
              <programme channel="one" start="invalid" stop="invalid"><title>Invalid two</title></programme>
              <programme channel="one" start="invalid" stop="invalid"><title>Invalid three</title></programme>
              <programme channel="one" start="invalid" stop="invalid"><title>Invalid four</title></programme>
            </tv>
            """
        let sink = CollectingXMLTVSink()
        let limits = XMLTVParseLimits(
            maximumChannels: 5,
            maximumProgrammes: 3,
            maximumEvents: 10,
            maximumDepth: 32,
            maximumTextBytes: 1_048_576
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(try XMLTVParser().parse(fileURL: $0, into: sink, limits: limits)) {
                XCTAssertEqual($0 as? XMLTVParserError, .excessiveProgrammes)
            }
        }
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationAtUnknownEmptyElementStart() throws {
        let xml = "<tv><x/></tv>"
        let sink = CollectingXMLTVSink()
        let cancellationProbe = CancellationProbe(cancellationCall: 2)

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.callCount, 2)
        XCTAssertTrue(sink.channels.isEmpty)
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationAtChannelStartBeforeParserStateMutation() throws {
        let xml = "<tv><channel id=\"sentinel\"><display-name><![CDATA[Sentinel]]></display-name></channel><channel id=\"target\"/></tv>"
        let cancellationProbe = ArmedCancellationProbe()
        let sink = ArmingXMLTVSink(
            cancellationProbe: cancellationProbe,
            ignoringNextChecksAfterSentinel: 0
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.checksAfterArming, 1)
        XCTAssertTrue(cancellationProbe.didThrow)
        XCTAssertEqual(sink.channelIDs, ["sentinel"])
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationAtProgrammeStartBeforeParserStateMutation() throws {
        let xml = "<tv><channel id=\"sentinel\"><display-name><![CDATA[Sentinel]]></display-name></channel><programme/></tv>"
        let cancellationProbe = ArmedCancellationProbe()
        let sink = ArmingXMLTVSink(
            cancellationProbe: cancellationProbe,
            ignoringNextChecksAfterSentinel: 0
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.checksAfterArming, 1)
        XCTAssertTrue(cancellationProbe.didThrow)
        XCTAssertEqual(sink.channelIDs, ["sentinel"])
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationImmediatelyBeforeChannelSinkAccept() throws {
        let xml = "<tv><channel id=\"sentinel\"><display-name><![CDATA[Sentinel]]></display-name></channel><channel id=\"target\"><display-name><![CDATA[Target]]></display-name></channel></tv>"
        let cancellationProbe = ArmedCancellationProbe()
        let sink = ArmingXMLTVSink(
            cancellationProbe: cancellationProbe,
            ignoringNextChecksAfterSentinel: 3
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.checksAfterArming, 4)
        XCTAssertTrue(cancellationProbe.didThrow)
        XCTAssertEqual(sink.channelIDs, ["sentinel"])
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationImmediatelyBeforeProgrammeSinkAccept() throws {
        let xml = "<tv><channel id=\"sentinel\"><display-name><![CDATA[Sentinel]]></display-name></channel><programme channel=\"sentinel\" start=\"20260718150000 Z\" stop=\"20260718160000 Z\"><title><![CDATA[Target]]></title></programme></tv>"
        let cancellationProbe = ArmedCancellationProbe()
        let sink = ArmingXMLTVSink(
            cancellationProbe: cancellationProbe,
            ignoringNextChecksAfterSentinel: 3
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.checksAfterArming, 4)
        XCTAssertTrue(cancellationProbe.didThrow)
        XCTAssertEqual(sink.channelIDs, ["sentinel"])
        XCTAssertTrue(sink.programmes.isEmpty)
    }

    func testChecksCancellationDuringPlainTextWithoutDependingOnCallbackPartition() throws {
        let xml = "<tv><channel id=\"one\"><display-name>One</display-name></channel><channel id=\"\"><display-name>Two</display-name></channel><channel id=\"three\"><display-name>Three</display-name></channel></tv>"
        let cancellationProbe = ArmedCancellationProbe()
        let sink = ArmingXMLTVSink(
            cancellationProbe: cancellationProbe,
            ignoringNextChecksAfterSentinel: 2
        )

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(sink.channelIDs, ["one"])
        XCTAssertLessThan(sink.channelIDs.count, 3)
    }

    func testChecksCancellationAtStartOfCDATAAndStopsBeforeLaterEvents() throws {
        let xml = "<tv><channel id=\"one\"><display-name><![CDATA[One]]></display-name></channel><channel id=\"two\"><display-name><![CDATA[Two]]></display-name></channel><channel id=\"three\"><display-name><![CDATA[Three]]></display-name></channel></tv>"
        let sink = CollectingXMLTVSink()
        let cancellationProbe = CancellationProbe(cancellationCall: 8)

        try withTemporaryXML(xml) {
            XCTAssertThrowsError(
                try XMLTVParser().parse(
                    fileURL: $0,
                    into: sink,
                    cancellationCheck: { try cancellationProbe.check() }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        XCTAssertEqual(cancellationProbe.callCount, 8)
        XCTAssertEqual(sink.channels.map(\.id), ["one"])
        XCTAssertLessThan(sink.channels.count, 3)
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

private final class ArmedCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checksToIgnoreAfterArming: Int?
    private var storedChecksAfterArming = 0
    private var storedDidThrow = false

    var checksAfterArming: Int {
        lock.withLock { storedChecksAfterArming }
    }

    var didThrow: Bool {
        lock.withLock { storedDidThrow }
    }

    func arm(ignoringNextChecks count: Int) {
        precondition(count >= 0)
        lock.withLock {
            guard checksToIgnoreAfterArming == nil else { return }
            checksToIgnoreAfterArming = count
        }
    }

    func check() throws {
        let shouldCancel = lock.withLock {
            guard let remainingChecks = checksToIgnoreAfterArming else {
                return false
            }
            storedChecksAfterArming += 1
            guard remainingChecks == 0 else {
                checksToIgnoreAfterArming = remainingChecks - 1
                return false
            }
            storedDidThrow = true
            return true
        }
        if shouldCancel {
            throw CancellationError()
        }
    }
}

private final class ArmingXMLTVSink: XMLTVEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationProbe: ArmedCancellationProbe
    private let checksToIgnoreAfterSentinel: Int
    private var storedChannelIDs: [String] = []
    private var storedProgrammes: [Programme] = []

    init(
        cancellationProbe: ArmedCancellationProbe,
        ignoringNextChecksAfterSentinel: Int = 1
    ) {
        self.cancellationProbe = cancellationProbe
        checksToIgnoreAfterSentinel = ignoringNextChecksAfterSentinel
    }

    var channelIDs: [String] {
        lock.withLock { storedChannelIDs }
    }

    var programmes: [Programme] {
        lock.withLock { storedProgrammes }
    }

    func accept(channel: EPGChannel) throws {
        let shouldArm = lock.withLock {
            storedChannelIDs.append(channel.id)
            return storedChannelIDs.count == 1
        }
        if shouldArm {
            cancellationProbe.arm(ignoringNextChecks: checksToIgnoreAfterSentinel)
        }
    }

    func accept(programme: Programme) throws {
        lock.withLock {
            storedProgrammes.append(programme)
        }
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCall: Int
    private var storedCallCount = 0

    init(cancellationCall: Int) {
        precondition(cancellationCall > 0)
        self.cancellationCall = cancellationCall
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func check() throws {
        let currentCallCount = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        if currentCallCount == cancellationCall {
            throw CancellationError()
        }
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

private final class ProgrammeFailingXMLTVSink: XMLTVEventSink {
    func accept(channel: EPGChannel) throws {}

    func accept(programme: Programme) throws {
        throw XMLTVTimeError.invalid("programme sink failure")
    }
}
