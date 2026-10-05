// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackSourceResolverTests: XCTestCase {
    func testScopedHeadersKeepExactOriginAndRedactDiagnostics() throws {
        let context = try sourceContext(attributes: ["HTTP-User-Agent": "fixture", "Authorization": "Bearer secret with spaces", "Cookie": "ignored"])
        XCTAssertEqual(context.headers.fields(for: URL(string: "https://example.test/path")!)["Authorization"], "Bearer secret with spaces")
        XCTAssertTrue(context.headers.fields(for: URL(string: "https://example.test:444/path")!).isEmpty)
        XCTAssertTrue(context.headers.fields(for: URL(string: "http://example.test/path")!).isEmpty)
        XCTAssertNil(context.headers.fields(for: context.entryURL)["Cookie"])
        XCTAssertFalse(String(reflecting: context).contains("secret"))
        XCTAssertThrowsError(try sourceContext(attributes: ["authorization": "bad\r\nHeader: value"]))
        XCTAssertThrowsError(try sourceContext(attributes: ["user-agent": "a", "http-user-agent": "b"]))
    }

    func testContextAndHeaderAliasesRetainOneConstructionCharge() throws {
        let ledger = PlaybackApplicationChargeLedger()
        var headers: PlaybackSourceHeaders?
        do {
            let context = try PlaybackSourceContext(requestID: UUID(), sourceProfileID: UUID(), channelID: "fixture",
                entryURL: URL(string: "https://example.test/entry")!, attributes: ["authorization": "fixture"], ledger: ledger)
            headers = context.headers
            XCTAssertEqual(ledger.chargedBytes, HLSPreflightMemoryLimits.contextRetention)
        }
        XCTAssertEqual(ledger.chargedBytes, HLSPreflightMemoryLimits.contextRetention)
        XCTAssertEqual(headers?.fields(for: URL(string: "https://example.test/entry")!)["Authorization"], "fixture")
        headers = nil
        XCTAssertEqual(ledger.chargedBytes, 0)
    }
}

func sourceContext(url: URL = URL(string: "https://example.test/stream?sig=secret")!, attributes: [String: String] = [:]) throws -> PlaybackSourceContext {
    let request = UUID()
    return try PlaybackSourceContext(requestID: request, sourceProfileID: UUID(), channelID: "stable-channel", entryURL: url, attributes: attributes)
        .bound(to: PlaybackSourceOwner(backendIdentity: PlaybackBackendIdentity(sessionIdentity: PlaybackSessionIdentity(sessionID: 1, requestID: request), backendGeneration: 1), prepareNonce: 1, outputLifecycleNonce: 1))
}
