// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSProxyResourceRegistryTests: XCTestCase {
    func testSignedLocatorWindowsStayBoundedByOriginalRoleAndPreserveOldLease() throws {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data([0x47])))
        let budget = try HLSProxyBudget()
        let registry = try HLSProxyResourceRegistry(source: source, budget: budget)
        let role = HLSProxyManifestRole(index: 0)
        try registry.beginManifestUpdate(role: role)
        let old = try registry.register(url: URL(string: "https://example.test/old?signature=original")!, kind: .segment, mediaType: .transportStream)
        registry.finishManifestUpdate()
        var held: HLSProxyResourceRegistry.Resource? = try registry.lease(path: old)
        for index in 0..<100 {
            try registry.beginManifestUpdate(documentURL: URL(string: "https://example.test/playlist?signature=\(index)")!, role: role)
            _ = try registry.register(url: URL(string: "https://example.test/part?signature=\(index)")!, kind: .segment, mediaType: .transportStream)
            registry.finishManifestUpdate()
            XCTAssertLessThanOrEqual(registry.entryCount, 3)
            XCTAssertLessThanOrEqual(budget.usage.bytes, HLSProxyBudget.domainBytes)
        }
        XCTAssertEqual(held?.url.query, "signature=original")
        XCTAssertThrowsError(try registry.lease(path: old))
        let retained = budget.usage.bytes
        held = nil
        XCTAssertLessThan(budget.usage.bytes, retained)
        registry.retire()
        XCTAssertEqual(budget.usage.bytes, 128 * 1_024)
    }

    func testIndependentAudioRoleSurvivesVideoReloads() throws {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data([0x47])))
        let registry = try HLSProxyResourceRegistry(source: source, budget: HLSProxyBudget())
        try registry.beginManifestUpdate(role: .init(index: 1))
        let audio = try registry.register(url: URL(string: "https://example.test/audio")!, kind: .segment, mediaType: .aac)
        registry.finishManifestUpdate()
        for index in 0..<100 {
            try registry.beginManifestUpdate(role: .init(index: 0))
            _ = try registry.register(url: URL(string: "https://example.test/video/\(index)")!, kind: .segment, mediaType: .transportStream)
            registry.finishManifestUpdate()
        }
        XCTAssertEqual(try registry.lease(path: audio).url.path, "/audio")
        XCTAssertLessThanOrEqual(registry.entryCount, 4)
    }

    func testMapDoesNotGuessMP4AndOriginalRangesRemainUnchanged() throws {
        let context = try sourceContext()
        let text = "#EXTM3U\n#EXT-X-MAP:URI=\"bytes?signature=original\",BYTERANGE=\"188@0\"\n#EXT-X-BYTERANGE:376@188\n#EXTINF:1,\nbytes?signature=original\n"
        let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: context.entryURL)
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .hls(graph))
        let registry = try HLSProxyResourceRegistry(source: source, budget: HLSProxyBudget())
        let bytes = try HLSManifestRewriter.rewrite(XCTUnwrap(graph.document(for: graph.rootURL)), registry: registry, mediaType: .transportStream)
        let rewritten = try HLSManifestGraph.parse(data: bytes, responseURL: context.entryURL)
        let segment = try XCTUnwrap(rewritten.document(for: rewritten.rootURL)?.segments.first)
        XCTAssertEqual(segment.initialization?.url.pathExtension, "ts")
        XCTAssertEqual(segment.range, HLSByteRange(offset: 188, length: 376))
        XCTAssertEqual(segment.initialization?.range, HLSByteRange(offset: 0, length: 188))
        XCTAssertEqual(try registry.lease(path: segment.resource.url.path).url.query, "signature=original")
        let request = try LoopbackRequestParser.parseComplete(Data("GET \(segment.resource.url.path) HTTP/1.1\r\nHost: 127.0.0.1:8888\r\n\r\n".utf8))
        XCTAssertNoThrow(try HLSProxyHTTP.authorize(request, port: 8888, prefix: registry.prefix))
    }

    func testTransportComparisonKeepsUnknownQuotedAttributesWhileAESLocatorsRenew() throws {
        let url = URL(string: "https://example.test/master")!
        func master(_ version: Int, note: String) throws -> HLSManifestGraph.Document {
            let text = "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key?version=\(version)\",IV=0x\(version),X-NOTE=\"\(note)\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nchild?version=\(version)\n"
            return try XCTUnwrap(HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url).document(for: url))
        }
        let original = try master(1, note: "same,IV=retained")
        XCTAssertEqual(try HLSManifestRewriter.masterTransportSkeleton(original), try HLSManifestRewriter.masterTransportSkeleton(master(2, note: "same,IV=retained")))
        XCTAssertNotEqual(try HLSManifestRewriter.masterTransportSkeleton(original), try HLSManifestRewriter.masterTransportSkeleton(master(3, note: "same,IV=changed")))
    }
}
