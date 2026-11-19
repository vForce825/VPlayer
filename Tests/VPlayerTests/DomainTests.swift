// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerCore

final class DomainTests: XCTestCase {
    func testSourceURLIdentityPreservesAbsoluteStringBytes() {
        let url = URL(
            string: "https://User:Pass@EXAMPLE.test:443/a%2Fb?sig=A%2BB#x"
        )!
        let differentlySpelledURL = URL(
            string: "https://User:Pass@example.test/a%2Fb?sig=A%2BB#x"
        )!

        XCTAssertEqual(SourceURLIdentity(url: url).rawValue, url.absoluteString)
        XCTAssertNotEqual(
            SourceURLIdentity(url: url),
            SourceURLIdentity(url: differentlySpelledURL)
        )
    }

    func testSourceProfileReturnsURLForRequestedResource() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let playlistURL = URL(string: "https://playlist.example/source.m3u")!
        let epgURL = URL(string: "https://epg.example/source.xml")!
        let profile = SourceProfile(
            id: UUID(),
            name: "Source",
            m3uURL: playlistURL,
            epgURL: epgURL,
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )

        XCTAssertEqual(profile.sourceURL(for: .playlist), playlistURL)
        XCTAssertEqual(profile.sourceURL(for: .epg), epgURL)
    }

    func testSourceInputRequiresRemoteHTTPURLs() throws {
        let valid = try SourceProfileInput(
            name: "  上海 IPTV  ",
            m3uURLString: "http://iptv.router/custom.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily
        ).validated()
        XCTAssertEqual(valid.name, "上海 IPTV")
        XCTAssertEqual(valid.m3uURL.scheme, "http")
        XCTAssertThrowsError(try SourceProfileInput(
            name: "Local",
            m3uURLString: "file:///tmp/list.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        ).validated()) { error in
            XCTAssertEqual(error as? SourceProfileValidationError, .unsupportedURL(field: .m3u))
        }
        XCTAssertThrowsError(try SourceProfileInput(
            name: "Relative",
            m3uURLString: "example.test/list.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        ).validated()) { error in
            XCTAssertEqual(error as? SourceProfileValidationError, .invalidURL(field: .m3u))
        }
    }

    func testRefreshDueCalculationTreatsNeverSucceededAsDue() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(RefreshInterval.hourly.isDue(lastSuccessAt: nil, now: now))
        XCTAssertFalse(RefreshInterval.manual.isDue(lastSuccessAt: nil, now: now))
        XCTAssertFalse(RefreshInterval.hourly.isDue(lastSuccessAt: now.addingTimeInterval(-3_599), now: now))
        XCTAssertTrue(RefreshInterval.hourly.isDue(lastSuccessAt: now.addingTimeInterval(-3_600), now: now))
    }

    func testChannelIdentityNormalizesSchemeHostAndDefaultPort() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = ChannelIdentity.make(
            profileID: profileID,
            streamURL: URL(string: "HTTP://Example.COM:80/live?a=1")!
        )
        let second = ChannelIdentity.make(
            profileID: profileID,
            streamURL: URL(string: "http://example.com/live?a=1")!
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        XCTAssertNotEqual(first, ChannelIdentity.make(
            profileID: profileID,
            streamURL: URL(string: "http://example.com/live?a=2")!
        ))
    }

    func testChannelPrecomputedIDInitializerPreservesProvidedID() {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let url = URL(string: "https://example.test/live.m3u8")!
        let computed = Channel(
            sourceProfileID: profileID,
            displayName: "Live",
            streamURL: url,
            tvgID: "live",
            tvgName: nil,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
        let precomputed = Channel(
            id: computed.id,
            sourceProfileID: profileID,
            displayName: "Live",
            streamURL: url,
            tvgID: "live",
            tvgName: nil,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
        XCTAssertEqual(precomputed, computed)
    }

    func testStreamPolicyAcceptsHTTPRelayAndRejectsMulticastSchemes() {
        XCTAssertEqual(
            StreamProtocolPolicy.evaluate(URL(string: "http://iptv.router/rtp/233.18.204.58:5140")!),
            .allowed
        )
        XCTAssertEqual(
            StreamProtocolPolicy.evaluate(URL(string: "udp://233.18.204.58:5140")!),
            .rejected(.multicastUnsupported)
        )
        XCTAssertEqual(
            StreamProtocolPolicy.evaluate(URL(string: "rtp://233.18.204.58:5140")!),
            .rejected(.multicastUnsupported)
        )
        XCTAssertEqual(
            ProtocolRejection.multicastUnsupported.userMessage,
            "首版暂不支持组播地址"
        )
    }

    func testBoundedDownloaderPurgeOrphanedDownloadsPreservesActiveLaunchDirectory() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("VPlayerCoreOrphanTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let activeDir = tempRoot.appendingPathComponent("current-launch", isDirectory: true)
        let staleDir = tempRoot.appendingPathComponent("previous-launch", isDirectory: true)
        let looseFile = tempRoot.appendingPathComponent("loose-orphan.tmp")
        let activeFile = activeDir.appendingPathComponent("active.tmp")
        try fm.createDirectory(at: activeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: activeFile)
        try Data("drop".utf8).write(to: staleDir.appendingPathComponent("old.tmp"))
        try Data("drop".utf8).write(to: looseFile)

        let defaultDir = URLSessionBoundedDownloader.defaultDownloadsDirectory()
        XCTAssertEqual(defaultDir.lastPathComponent, URLSessionBoundedDownloader.launchDirectoryName)
        XCTAssertEqual(defaultDir.deletingLastPathComponent().lastPathComponent, "VPlayerDownloads")

        URLSessionBoundedDownloader.purgeOrphanedDownloads(
            in: tempRoot,
            keepingDirectoryNamed: "current-launch",
            fileManager: fm
        )

        XCTAssertTrue(fm.fileExists(atPath: activeFile.path))
        XCTAssertFalse(fm.fileExists(atPath: staleDir.path))
        XCTAssertFalse(fm.fileExists(atPath: looseFile.path))
    }
}
