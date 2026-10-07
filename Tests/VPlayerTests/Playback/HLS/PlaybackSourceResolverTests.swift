// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackSourceResolverTests: XCTestCase {
    func testRequestMirrorContainsOnlyIdentityAndRedactedTransport() throws {
        let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "synthetic-channel",
            streamURL: URL(string: "https://example.test/synthetic.m3u8?sig=fixture-token")!,
            title: "Synthetic title", attributes: ["Authorization": "Bearer fixture-header"])
        let children = Array(Mirror(reflecting: request).children)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.compactMap(\.label), ["id", "transport"])
        XCTAssertEqual(children.first { $0.label == "id" }?.value as? UUID, request.id)
        XCTAssertEqual(children.first { $0.label == "transport" }?.value as? String, "redacted")
        var diagnostic = ""
        dump(request, to: &diagnostic)
        for value in ["example.test", "synthetic-channel", "Synthetic title", "fixture-token", "fixture-header"] {
            XCTAssertFalse(diagnostic.contains(value))
        }
    }

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

actor SourceTestTransport: HLSResourceTransport {
    let responses: [URL: HLSResourceResponse]
    var requests: [HLSResourceRequest] = []
    let enforcesRequestLimit: Bool
    init(responses: [URL: HLSResourceResponse], enforcesRequestLimit: Bool = true) {
        self.responses = responses; self.enforcesRequestLimit = enforcesRequestLimit
    }
    func fetch(_ request: HLSResourceRequest) async throws -> HLSResourceResponse {
        requests.append(request)
        guard let response = responses[request.url] else { throw HLSSourceError.network }
        if enforcesRequestLimit {
            guard response.data.count <= (request.maximumTSContinuationBytes ?? request.maximumBytes) else { throw HLSSourceError.byteLimit }
        }
        return response
    }
}

extension PlaybackSourceResolverTests {
    func testRedirectedMasterPreservesSharedNodesAndStableContext() async throws {
        let context = try sourceContext()
        let root = URL(string: "https://example.test/cdn/master?sig=new")!
        let media = URL(string: "https://example.test/cdn/media?sig=child")!
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia?sig=child\n#EXT-X-STREAM-INF:BANDWIDTH=2\nmedia?sig=child\n"
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: root, data: Data(text.utf8)),
            media: .init(responseURL: media, data: Data("#EXTM3U\n#EXTINF:1,\npart\n".utf8))])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        guard case let .hls(graph) = source.topology else { return XCTFail("missing source graph") }
        XCTAssertEqual(source.context, context); XCTAssertEqual(source.responseURL, root)
        XCTAssertEqual(graph.documents.count, 2); XCTAssertEqual(graph.document(for: root)?.variants.count, 2)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.maximumBytes, HLSManifestGraph.maximumPlaylistBytes)
        XCTAssertEqual(requests.first?.maximumTSContinuationBytes, HLSCompatibilityProbe.maximumBytes)
        XCTAssertEqual(requests.first?.mode, .classify)
        XCTAssertNil(requests.last?.maximumTSContinuationBytes)
        await resolver.invalidate()
        XCTAssertNil(source.withCurrentResolution(owner: try XCTUnwrap(context.owner), generation: source.generation) { true })
    }
    func testRawPrefixNeverAcquiresFakeHLSAndExpiryDoesNotGuessQuery() async throws {
        let context = try sourceContext(url: URL(string: "https://example.test/raw?expires=0")!)
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL, data: Data([0x47, 0]), completeness: .prefix)])
        let source = try await URLSessionPlaybackSourceResolver(transport: transport).resolve(context, reason: .initial)
        guard case .media = source.topology else { return XCTFail("raw media became a manifest") }
        XCTAssertEqual(source.mediaCompleteness, .prefix); XCTAssertNil(source.refreshReason())
    }
}

extension PlaybackSourceResolverTests {
    func testRawTSExtensionRetainsAllOriginalBytesAndPrefixProvenance() async throws {
        let context = try sourceContext()
        let data = AcquisitionTSFixture.make(byteCount: HLSManifestGraph.maximumPlaylistBytes + 256 * 1_024,
            headersAt: HLSManifestGraph.maximumPlaylistBytes + 188)
        let transport = SourceTestTransport(responses: [context.entryURL:
            .init(responseURL: context.entryURL, data: data, completeness: .prefix)])
        let source = try await URLSessionPlaybackSourceResolver(transport: transport).resolve(context, reason: .initial)
        guard case let .media(bytes) = source.topology else { return XCTFail("TS prefix became a manifest") }
        XCTAssertEqual(bytes, data)
        XCTAssertEqual(source.mediaCompleteness, .prefix)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.maximumBytes, HLSManifestGraph.maximumPlaylistBytes)
        XCTAssertEqual(requests.first?.maximumTSContinuationBytes, HLSCompatibilityProbe.maximumBytes)
        XCTAssertNil(requests.first?.range)
    }

    func testResolverIndependentlyRejectsOversizedManifestAndNonTSRootResponses() async throws {
        let context = try sourceContext()
        var manifest = Data("#EXTM3U\n".utf8)
        manifest.append(Data(repeating: 0x20, count: HLSManifestGraph.maximumPlaylistBytes))
        let bodies = [manifest, Data(repeating: 0x41, count: HLSManifestGraph.maximumPlaylistBytes + 1),
                      Data(repeating: 0x47, count: HLSCompatibilityProbe.maximumBytes + 1)]
        for body in bodies {
            let transport = SourceTestTransport(responses: [context.entryURL:
                .init(responseURL: context.entryURL, data: body)], enforcesRequestLimit: false)
            do {
                _ = try await URLSessionPlaybackSourceResolver(transport: transport).resolve(context, reason: .initial)
                XCTFail("The resolver must enforce its own manifest and raw-media bounds")
            } catch { XCTAssertEqual(error as? HLSSourceError, .byteLimit) }
        }
    }

    func testSupersedingResolutionCancelsAndJoinsTheExtendedLoadBeforeStartingAnother() async throws {
        let started = expectation(description: "First response started")
        let cancelled = expectation(description: "First response cancelled")
        let transport = JoiningSourceTestTransport(started: { started.fulfill() }, cancelled: { cancelled.fulfill() })
        let context = try sourceContext()
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let first = Task { try await resolver.resolve(context, reason: .initial) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await resolver.resolve(context, reason: .topologyChanged) }
        await fulfillment(of: [cancelled], timeout: 2)
        let beforeJoin = await transport.requests
        XCTAssertEqual(beforeJoin.count, 1, "A replacement must not overlap the previous transport workspace")
        await transport.completeFirst()
        do { _ = try await first.value; XCTFail("A superseded source escaped cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let source = try await second.value
        XCTAssertEqual(source.generation, 2)
        let current = await resolver.isCurrent(source)
        XCTAssertTrue(current)
        let afterJoin = await transport.requests
        XCTAssertEqual(afterJoin.count, 2)
        await resolver.invalidate()
        let retired = await resolver.isCurrent(source)
        XCTAssertFalse(retired)
    }
}

private actor JoiningSourceTestTransport: HLSResourceTransport {
    private let started: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    var requests: [HLSResourceRequest] = []
    init(started: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.started = started; self.cancelled = cancelled
    }
    func fetch(_ request: HLSResourceRequest) async throws -> HLSResourceResponse {
        requests.append(request)
        if requests.count == 1 {
            let cancelled = self.cancelled
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation; started()
                }
            } onCancel: { cancelled() }
        }
        // Intentionally ignore task cancellation to test the resolver's own
        // post-join cancellation fence against a late successful transport.
        return .init(responseURL: request.url, data: Data([0x47, 0]), completeness: .prefix)
    }
    func completeFirst() { continuation?.resume(); continuation = nil }
}
