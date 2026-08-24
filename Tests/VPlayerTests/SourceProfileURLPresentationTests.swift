// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore

final class SourceProfileURLPresentationTests: XCTestCase {
    private let rawURL = "https://user:pass@example.test/list.m3u?token=secret#fragment"

    func testPassiveM3UURLRemovesCredentialsQueryAndFragment() {
        let profile = makeProfile(m3uURL: URL(string: rawURL)!)

        XCTAssertEqual(
            SourceProfileURLPresentation.m3uURL(
                profile: profile,
                protectsAcceptanceValue: false
            ),
            "https://example.test/list.m3u"
        )
    }

    func testAcceptancePassiveM3UURLUsesProtectedCopy() {
        let profile = makeProfile(m3uURL: URL(string: rawURL)!)

        XCTAssertEqual(
            SourceProfileURLPresentation.m3uURL(
                profile: profile,
                protectsAcceptanceValue: true
            ),
            "Protected URL configured"
        )
    }

    func testNormalEditorPresentationKeepsRawM3UURL() {
        let presentation = SourceProfileEditorM3UFieldPresentation(
            rawValue: rawURL,
            protectsValue: false
        )

        XCTAssertFalse(presentation.isProtected)
        XCTAssertEqual(presentation.displayedValue, rawURL)
    }

    func testProfileHeaderRoutesURLTextThroughRedactedPresentation() throws {
        let source = try repositorySource("Sources/VPlayerApp/Views/SourceProfilesView.swift")
        let profileHeader = try profileHeaderMethod(in: source)

        XCTAssertTrue(
            profileHeader.contains("SourceProfileURLPresentation.m3uURL("),
            "profileHeader must route passive URL text through SourceProfileURLPresentation"
        )
        XCTAssertFalse(
            profileHeader.filter { !$0.isWhitespace }.contains("profile.m3uURL"),
            "profileHeader must not read the raw M3U URL directly; editor raw access is outside this method"
        )
    }

    private func makeProfile(m3uURL: URL) -> SourceProfile {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        return SourceProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Source",
            m3uURL: m3uURL,
            epgURL: URL(string: "https://example.test/epg.xml")!,
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(relativePath)
        return String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
    }

    private func profileHeaderMethod(in source: String) throws -> String {
        let signature = "    private func profileHeader(_ profile: SourceProfile) -> some View {"
        let start = try XCTUnwrap(
            source.range(of: signature),
            "Could not locate SourceProfilesView.profileHeader(_:)"
        )
        var braceDepth = 0
        for index in source.indices[start.lowerBound...] {
            switch source[index] {
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth == 0 {
                    let end = source.index(after: index)
                    return String(source[start.lowerBound..<end])
                }
            default:
                continue
            }
        }
        XCTFail("Could not determine the end of SourceProfilesView.profileHeader(_:)")
        return ""
    }
}
