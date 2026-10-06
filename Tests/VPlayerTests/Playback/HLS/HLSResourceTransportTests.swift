// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class HLSResourceTransportTests: XCTestCase {
    private func transport() -> URLSessionHLSResourceTransport {
        URLSessionHLSResourceTransport { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [SourceHTTPProtocol.self]; return c }
    }
    private func request(_ path: String, range: HLSByteRange? = nil, maximumBytes: Int = 1024,
                         mode: HLSResourceRequest.Mode = .complete) throws -> HLSResourceRequest {
        let context = try sourceContext(attributes: ["authorization": "Bearer fixture"])
        return .init(url: URL(string: "https://example.test\(path)")!, headers: context.headers,
            range: range, maximumBytes: maximumBytes, deadline: HLSMonotonicClock.deadline(seconds: 10), mode: mode)
    }
    func testPartial206CannotClaimACompleteManifestAtTCPCompletion() async throws {
        let response = try await transport().fetch(request("/prefix-manifest"))
        XCTAssertEqual(response.completeness, .prefix)
        XCTAssertGreaterThan(try XCTUnwrap(response.contentRange?.total), Int64(response.data.count))
        let context = try sourceContext(url: response.responseURL)
        let resolver = URLSessionPlaybackSourceResolver(transport: transport())
        do { _ = try await resolver.resolve(context, reason: .initial); XCTFail("partial manifest was accepted") }
        catch { XCTAssertEqual(error as? HLSSourceError, .incompleteEvidence) }
    }
    func testWhole206AndRequestedRangeHaveDistinctProvenance() async throws {
        let complete = try await transport().fetch(request("/whole-manifest"))
        XCTAssertEqual(complete.completeness, .complete)
        let range = try await transport().fetch(request("/range", range: .init(offset: 4, length: 4)))
        XCTAssertEqual(range.completeness, .byteRange)
        XCTAssertEqual(range.data, Data([4, 5, 6, 7]))
        do { _ = try await transport().fetch(request("/range", range: .init(offset: 3, length: 4))); XCTFail("wrong range admitted") }
        catch { XCTAssertEqual(error as? HLSSourceError, .incompleteEvidence) }
    }
    func testClassifyStopsAtBoundButFiniteCompleteModeRejectsOverflow() async throws {
        let response = try await transport().fetch(request("/bytes", maximumBytes: 8, mode: .classify))
        XCTAssertEqual(response.data.count, 8); XCTAssertEqual(response.completeness, .prefix)
        do { _ = try await transport().fetch(request("/bytes", maximumBytes: 8)); XCTFail("overflow admitted") }
        catch { XCTAssertEqual(error as? HLSSourceError, .byteLimit) }
    }
    func testCrossOriginRedirectDoesNotForwardAuthorization() async throws {
        let response = try await transport().fetch(request("/redirect"))
        XCTAssertEqual(response.responseURL.host, "other.test")
        XCTAssertEqual(response.data, Data("clean".utf8))
    }
    func testContentRangeSyntaxAndBounds() {
        XCTAssertEqual(HLSHTTPContentRange("bytes 4-7/10")?.length, 4)
        XCTAssertNil(HLSHTTPContentRange("bytes 4-7/7"))
        XCTAssertNil(HLSHTTPContentRange("bytes 7-4/10"))
        XCTAssertNil(HLSHTTPContentRange("bytes 0-9223372036854775807/*"))
    }
}

private final class SourceHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { ["example.test", "other.test"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/redirect" {
            let destination = URL(string: "https://other.test/final")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            return
        }
        let body: Data
        let status: Int
        var headers: [String: String] = [:]
        switch url.path {
        case "/prefix-manifest", "/whole-manifest":
            body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\npart\n".utf8)
            status = 206
            let total = url.path == "/prefix-manifest" ? body.count + 100 : body.count
            headers["Content-Range"] = "bytes 0-\(body.count-1)/\(total)"
        case "/range": body = Data([4, 5, 6, 7]); status = 206; headers["Content-Range"] = "bytes 4-7/10"
        case "/final": body = Data("clean".utf8); status = request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 400
        default: body = Data(0..<16); status = 200
        }
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
