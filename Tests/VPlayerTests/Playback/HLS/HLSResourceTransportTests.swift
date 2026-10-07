// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
import VPlayerCore
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
    private func fetchCheckingDiagnosticRetirement(_ transport: URLSessionHLSResourceTransport,
                                                   _ request: HLSResourceRequest,
                                                   file: StaticString = #filePath, line: UInt = #line) async throws -> HLSResourceResponse {
        let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
        var diagnostic: HLSPreparationDiagnostics? = HLSPreparationDiagnostics(
            metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
        let observed = TestWeakReference(diagnostic)
        XCTAssertNotNil(observed.value, file: file, line: line)
        XCTAssertGreaterThan(ledger.chargedBytes, 0, file: file, line: line)
        defer {
            diagnostic = nil
            // This must hold when fetch returns or throws, before waiting for
            // the custom protocol's separate stopLoading callback.
            XCTAssertNil(observed.value, "The session delegate must release its diagnostic alias before fetch returns", file: file, line: line)
            XCTAssertEqual(ledger.chargedBytes, 0, file: file, line: line)
            XCTAssertNil(HLSPreparationDiagnostics.current, file: file, line: line)
        }
        return try await HLSPreparationDiagnostics.$current.withValue(diagnostic) {
            try await transport.fetch(request)
        }
    }
    private func assertProtocolStopped(_ fixture: AcquisitionHTTPFixture,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        // finishTasksAndInvalidate joins task/delegate callbacks. Its contract
        // does not order URLProtocol.stopLoading before session invalidation.
        // Observe the real stop callback; never manufacture fixture retirement.
        await fulfillment(of: [fixture.protocolStopped], timeout: 2)
        XCTAssertEqual(fixture.activeCount, 0, file: file, line: line)
    }
    func testContentEncodingDiagnosticCrossesDelegateBoundaryWithoutRetainingTheScope() async throws {
        let ledger = PlaybackResourceContextLedger(applicationLedger: HLSDeliveryApplicationChargeLedger())
        var diagnostic: HLSPreparationDiagnostics? = HLSPreparationDiagnostics(
            metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: ledger))
        let observed = TestWeakReference(diagnostic)
        XCTAssertNotNil(observed.value)
        diagnostic?.begin(.resolve)
        do {
            _ = try await HLSPreparationDiagnostics.$current.withValue(diagnostic) {
                try await transport().fetch(request("/encoded"))
            }
            XCTFail("The existing identity-encoding contract must still reject this response")
        } catch { XCTAssertEqual(error as? HLSSourceError, .unsupportedMedia) }
        let snapshot = try XCTUnwrap(diagnostic?.freeze().project(HLSSourceError.unsupportedMedia) as? ErrorDiagnosticSnapshot)
        XCTAssertTrue(snapshot.summary.contains("phase=resolve reason=http-encoding"))
        XCTAssertTrue(snapshot.summary.contains("http=200"))
        XCTAssertFalse(snapshot.summary.contains("private-encoding"))
        XCTAssertFalse(snapshot.summary.contains("example.test"))
        diagnostic = nil
        XCTAssertNil(observed.value, "The invalidated URLSession delegate must release its diagnostic alias before returning")
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertNil(HLSPreparationDiagnostics.current)
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
    func testDelayedHEVCHeadersContinueTheSameResponseAndStopAtTheNextMilestone() async throws {
        for initialMiB in [1, 2] {
            let body = AcquisitionTSFixture.make(byteCount: 3 * AcquisitionTSFixture.mib,
                headersAt: initialMiB * AcquisitionTSFixture.mib + 1_024)
            let fixture = AcquisitionHTTPFixture(body: body, chunkSizes: [body.count], finishes: false)
            defer { fixture.remove() }
            let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request())
            XCTAssertEqual(response.data, body.prefix(initialMiB * AcquisitionTSFixture.mib + 256 * 1_024))
            XCTAssertEqual(response.completeness, .prefix)
            XCTAssertEqual(fixture.startedRequests.count, 1)
            await assertProtocolStopped(fixture)
        }
    }

    func testDelayedPATAndHeadersSurviveSplitCallbacksWithoutLosingAnyBytes() async throws {
        let body = AcquisitionTSFixture.make(byteCount: 2 * AcquisitionTSFixture.mib,
            patAt: AcquisitionTSFixture.mib + 188, headersAt: AcquisitionTSFixture.mib + 1_880)
        let fixture = AcquisitionHTTPFixture(body: body, chunkSizes: [1, 187, 189, 32_767, 262_145], finishes: false)
        defer { fixture.remove() }
        let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request())
        XCTAssertEqual(response.data, body.prefix(AcquisitionTSFixture.mib + 256 * 1_024))
        XCTAssertEqual(response.completeness, .prefix)
        XCTAssertEqual(fixture.startedRequests.count, 1)
        await assertProtocolStopped(fixture)
    }

    func testReadyTSStopsAtInitialBoundaryWithoutWaitingForUnknownLengthEOF() async throws {
        let body = AcquisitionTSFixture.make(byteCount: AcquisitionTSFixture.mib, headersAt: 376)
        let fixture = AcquisitionHTTPFixture(body: body, finishes: false)
        defer { fixture.remove() }
        let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request())
        XCTAssertEqual(response.data, body)
        XCTAssertEqual(response.completeness, .prefix)
        await assertProtocolStopped(fixture)
    }

    func testExactLimitManifestWaitsForKnownOrUnknownLengthEOFAndRemainsComplete() async throws {
        var body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\npart\n#".utf8)
        body.append(Data(repeating: 0x78, count: AcquisitionTSFixture.mib - body.count))
        for knownLength in [false, true] {
            let fixture = AcquisitionHTTPFixture(body: body, knownLength: knownLength)
            defer { fixture.remove() }
            let response = try await fixture.transport.fetch(fixture.request())
            XCTAssertEqual(response.data, body)
            XCTAssertEqual(response.completeness, .complete)
            let context = try sourceContext(url: fixture.url)
            let source = try await URLSessionPlaybackSourceResolver(transport: fixture.transport).resolve(context, reason: .initial)
            guard case let .hls(graph) = source.topology else { return XCTFail("Exact-limit manifest lost its topology") }
            XCTAssertEqual(graph.documents.count, 1)
            XCTAssertEqual(graph.document(for: fixture.url)?.segments.count, 1)
            XCTAssertEqual(graph.document(for: fixture.url)?.rawData, body)
            XCTAssertEqual(fixture.activeCount, 0)
        }
    }

    func testNonTSOverflowInTheNextCallbackStillStopsAtTheOriginalLimit() async throws {
        let body = Data(repeating: 0x41, count: AcquisitionTSFixture.mib + 1)
        let fixture = AcquisitionHTTPFixture(body: body, chunkSizes: [AcquisitionTSFixture.mib, 1], finishes: false)
        defer { fixture.remove() }
        let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request())
        XCTAssertEqual(response.data, body.prefix(AcquisitionTSFixture.mib))
        XCTAssertEqual(response.completeness, .prefix)
        await assertProtocolStopped(fixture)
    }

    func testMissingPATStopsExactlyAtEightMiBCapEvenInOneOversizedCallback() async throws {
        let body = AcquisitionTSFixture.make(byteCount: 8 * AcquisitionTSFixture.mib + 17,
            patAt: nil, headersAt: nil)
        for maximum in [AcquisitionTSFixture.mib, 376] {
            let fixture = AcquisitionHTTPFixture(body: body, finishes: false)
            defer { fixture.remove() }
            let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request(maximum: maximum))
            XCTAssertEqual(response.data, body.prefix(8 * AcquisitionTSFixture.mib))
            XCTAssertEqual(response.completeness, .prefix)
            XCTAssertEqual(fixture.startedRequests.count, 1)
            await assertProtocolStopped(fixture)
        }
    }

    func testContinuationHonorsAnUnalignedLowerCeiling() async throws {
        let body = AcquisitionTSFixture.make(byteCount: 2 * AcquisitionTSFixture.mib, headersAt: nil)
        let fixture = AcquisitionHTTPFixture(body: body, finishes: false)
        defer { fixture.remove() }
        let ceiling = AcquisitionTSFixture.mib + 123
        let response = try await fixture.transport.fetch(fixture.request(continuation: ceiling))
        XCTAssertEqual(response.data, body.prefix(ceiling))
        XCTAssertEqual(response.completeness, .prefix)
    }

    func testEOFBeforeTheNextMilestoneRetainsCompleteProvenanceAndOriginalBytes() async throws {
        for count in [18_800, AcquisitionTSFixture.mib + 7_520] {
            for knownLength in [false, true] {
                let body = AcquisitionTSFixture.make(byteCount: count, headersAt: nil)
                let fixture = AcquisitionHTTPFixture(body: body, knownLength: knownLength)
                defer { fixture.remove() }
                let response = try await fixture.transport.fetch(fixture.request())
                XCTAssertEqual(response.data, body)
                XCTAssertEqual(response.completeness, .complete)
                XCTAssertEqual(fixture.startedRequests.count, 1)
                XCTAssertEqual(fixture.activeCount, 0)
            }
        }
    }

    func testManifestOverflowCannotUseTheTSContinuationBudget() async throws {
        var body = Data("#EXTM3U\n".utf8)
        body.append(Data(repeating: 0x20, count: AcquisitionTSFixture.mib))
        let fixture = AcquisitionHTTPFixture(body: body, finishes: false)
        defer { fixture.remove() }
        let response = try await fixture.transport.fetch(fixture.request())
        XCTAssertEqual(response.data.count, AcquisitionTSFixture.mib)
        XCTAssertEqual(response.completeness, .prefix)
        let context = try sourceContext(url: fixture.url)
        do {
            _ = try await URLSessionPlaybackSourceResolver(transport: fixture.transport).resolve(context, reason: .initial)
            XCTFail("An oversized manifest must not acquire the raw TS ceiling")
        } catch { XCTAssertEqual(error as? HLSSourceError, .incompleteEvidence) }
    }

    func testRequestsWithoutContinuationKeepFiniteAndMediaPrefixSemantics() async throws {
        for mode in [HLSResourceRequest.Mode.complete, .mediaPrefix, .classify] {
            let body = Data(0..<16)
            let fixture = AcquisitionHTTPFixture(body: body)
            defer { fixture.remove() }
            let response = try await fixture.transport.fetch(fixture.request(maximum: body.count,
                continuation: nil, mode: mode))
            XCTAssertEqual(response.data, body)
            XCTAssertEqual(response.completeness, .complete)
        }
        let body = AcquisitionTSFixture.make(byteCount: 2 * AcquisitionTSFixture.mib, headersAt: nil)
        let fixture = AcquisitionHTTPFixture(body: body)
        defer { fixture.remove() }
        let prefix = try await fixture.transport.fetch(fixture.request(continuation: nil, mode: .mediaPrefix))
        XCTAssertEqual(prefix.data, body.prefix(AcquisitionTSFixture.mib))
        XCTAssertEqual(prefix.completeness, .prefix)
    }

    func testInvalidContinuationRequestsAreRejectedBeforeStartingHTTP() async throws {
        let fixture = AcquisitionHTTPFixture(body: Data())
        defer { fixture.remove() }
        let invalid = try [
            fixture.request(continuation: 0),
            fixture.request(continuation: AcquisitionTSFixture.mib),
            fixture.request(continuation: 8 * AcquisitionTSFixture.mib + 1),
            fixture.request(mode: .complete),
            fixture.request(mode: .mediaPrefix),
            fixture.request(range: .init(offset: 0, length: 188))
        ]
        for request in invalid {
            do { _ = try await fixture.transport.fetch(request); XCTFail("Invalid continuation was admitted") }
            catch { XCTAssertEqual(error as? HLSSourceError, .byteLimit) }
        }
        XCTAssertTrue(fixture.startedRequests.isEmpty)
    }

    func testContinuationRedirectRetainsIdentityEncodingAndScopesAuthorization() async throws {
        let body = AcquisitionTSFixture.make(byteCount: 2 * AcquisitionTSFixture.mib,
            headersAt: AcquisitionTSFixture.mib + 188)
        let fixture = AcquisitionHTTPFixture(body: body, finishes: false)
        defer { fixture.remove() }
        let response = try await fetchCheckingDiagnosticRetirement(fixture.transport, fixture.request(redirect: true))
        XCTAssertEqual(response.responseURL.host, "acquisition-other.test")
        XCTAssertEqual(response.data, body.prefix(AcquisitionTSFixture.mib + 256 * 1_024))
        let requests = fixture.startedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil })
        await assertProtocolStopped(fixture)
    }

    func testCancellationWhileAwaitingContinuationJoinsTheOnlyRequest() async throws {
        let delivered = expectation(description: "First milestone delivered")
        let fixture = AcquisitionHTTPFixture(body: AcquisitionTSFixture.make(byteCount: AcquisitionTSFixture.mib,
            headersAt: nil), finishes: false, delivered: { delivered.fulfill() })
        defer { fixture.remove() }
        let request = try fixture.request()
        let transport = fixture.transport
        let task = Task { try await self.fetchCheckingDiagnosticRetirement(transport, request) }
        await fulfillment(of: [delivered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled acquisition returned a source") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.startedRequests.count, 1)
        await assertProtocolStopped(fixture)
    }

    func testDeadlineWhileAwaitingContinuationJoinsTheOnlyRequest() async throws {
        let fixture = AcquisitionHTTPFixture(body: AcquisitionTSFixture.make(byteCount: AcquisitionTSFixture.mib,
            headersAt: nil), finishes: false, timedOut: true)
        defer { fixture.remove() }
        do { _ = try await fixture.transport.fetch(fixture.request()); XCTFail("Timed-out acquisition returned a source") }
        catch { XCTAssertEqual(error as? HLSSourceError, .deadline) }
        XCTAssertEqual(fixture.startedRequests.count, 1)
        XCTAssertEqual(fixture.activeCount, 0)
    }

    func testExpiredAcquisitionDeadlineDoesNotStartHTTP() async throws {
        let fixture = AcquisitionHTTPFixture(body: Data())
        defer { fixture.remove() }
        let request = try fixture.request(deadline: HLSMonotonicClock.now)
        do { _ = try await fixture.transport.fetch(request); XCTFail("Expired request started") }
        catch { XCTAssertEqual(error as? HLSSourceError, .deadline) }
        XCTAssertTrue(fixture.startedRequests.isEmpty)
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
        case "/encoded": body = Data("fixture".utf8); status = 200; headers["Content-Encoding"] = "private-encoding"
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

// Authored TS metadata only. Tiny HEVC NALs exercise acquisition, not decoder or
// planner acceptance; those remain the full inspector's independent proof.
enum AcquisitionTSFixture {
    static let mib = 1_024 * 1_024
    static func make(byteCount: Int, patAt: Int? = 0, headersAt: Int?) -> Data {
        let nullPacket = Data([0x47, 0x1f, 0xff, 0x10] + [UInt8](repeating: 0xff, count: 184))
        var data = Data(capacity: byteCount + 188)
        while data.count < byteCount {
            var packet = nullPacket
            packet[187] = UInt8((data.count / 188) % 251)
            data.append(packet)
        }
        if let patAt {
            let offset = ((patAt + 187) / 188) * 188
            let pat = psi(pid: 0, table: 0, body: [0, 1, 0xf0, 0])
            let pmt = psi(pid: 4096, table: 2, body: [0xe1, 0, 0xf0, 0, 0x24, 0xe1, 0, 0xf0, 0])
            if offset + 376 <= data.count { data.replaceSubrange(offset..<offset + 376, with: pat + pmt) }
        }
        if let headersAt {
            let offset = ((headersAt + 187) / 188) * 188
            let elementary: [UInt8] = [0, 0, 1, 0x40, 1, 0x80, 0, 0, 1, 0x42, 1, 0x80,
                                      0, 0, 1, 0x44, 1, 0x80, 0, 0, 1, 0x46, 1, 0x80]
            let pes: [UInt8] = [0, 0, 1, 0xe0, 0, UInt8(elementary.count + 3), 0x80, 0, 0] + elementary
            let adaptation = 183 - pes.count
            let packet = Data([0x47, 0x41, 0, 0x30, UInt8(adaptation), 0] +
                [UInt8](repeating: 0xff, count: adaptation - 1) + pes)
            if offset + 188 <= data.count { data.replaceSubrange(offset..<offset + 188, with: packet) }
        }
        return Data(data.prefix(byteCount))
    }
    private static func psi(pid: Int, table: UInt8, body: [UInt8]) -> Data {
        let length = 5 + body.count + 4
        var section = [table, 0xb0 | UInt8(length >> 8), UInt8(length & 255), 0, 1, 0xc1, 0, 0] + body
        var crc: UInt32 = 0xffff_ffff
        for byte in section {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04c1_1db7) }
        }
        section += [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
        return Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 255), 0x10, 0] + section +
            [UInt8](repeating: 0xff, count: 183 - section.count))
    }
}

private final class AcquisitionHTTPFixture: @unchecked Sendable {
    let protocolStopped = XCTestExpectation(description: "Active request received URLProtocol.stopLoading")
    let body: Data
    let chunkSizes: [Int]
    let knownLength: Bool
    let finishes: Bool
    let timedOut: Bool
    let delivered: (@Sendable () -> Void)?
    let url: URL
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var active: Set<UUID> = []
    init(body: Data, chunkSizes: [Int] = [], knownLength: Bool = false, finishes: Bool = true,
         timedOut: Bool = false, delivered: (@Sendable () -> Void)? = nil) {
        self.body = body; self.chunkSizes = chunkSizes; self.knownLength = knownLength
        self.finishes = finishes; self.timedOut = timedOut; self.delivered = delivered
        url = URL(string: "https://acquisition.test/body/\(UUID().uuidString)")!
        AcquisitionHTTPProtocol.registry.insert(self)
    }
    var transport: URLSessionHLSResourceTransport {
        URLSessionHLSResourceTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AcquisitionHTTPProtocol.self]
            return configuration
        }
    }
    func request(maximum: Int = AcquisitionTSFixture.mib, continuation: Int? = 8 * AcquisitionTSFixture.mib,
                 mode: HLSResourceRequest.Mode = .classify, range: HLSByteRange? = nil,
                 redirect: Bool = false, deadline: UInt64? = nil) throws -> HLSResourceRequest {
        let context = try sourceContext(url: url, attributes: ["authorization": "Bearer fixture"])
        let target = redirect ? URL(string: "https://acquisition.test/redirect/\(url.lastPathComponent)")! : url
        return HLSResourceRequest(url: target, headers: context.headers, range: range, maximumBytes: maximum,
            deadline: deadline ?? HLSMonotonicClock.deadline(seconds: 10), mode: mode, maximumTSContinuationBytes: continuation)
    }
    var startedRequests: [URLRequest] { lock.withLock { requests } }
    var activeCount: Int { lock.withLock { active.count } }
    func start(_ request: URLRequest, id: UUID) { lock.withLock { requests.append(request); _ = active.insert(id) } }
    func stop(_ id: UUID) { _ = lock.withLock { active.remove(id) } }
    func didStopLoading(_ id: UUID) {
        let wasActive = lock.withLock { active.remove(id) != nil }
        // A redirected protocol may stop after the next request starts. Only
        // stopping a still-active ID proves retirement of the held-open body.
        if wasActive { protocolStopped.fulfill() }
    }
    func remove() { AcquisitionHTTPProtocol.registry.remove(url.lastPathComponent) }
}

private final class AcquisitionHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: AcquisitionHTTPFixture] = [:]
    func insert(_ fixture: AcquisitionHTTPFixture) { lock.withLock { fixtures[fixture.url.lastPathComponent] = fixture } }
    func get(_ key: String) -> AcquisitionHTTPFixture? { lock.withLock { fixtures[key] } }
    func remove(_ key: String) { _ = lock.withLock { fixtures.removeValue(forKey: key) } }
}

private final class AcquisitionHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = AcquisitionHTTPRegistry()
    private let id = UUID()
    override class func canInit(with request: URLRequest) -> Bool {
        ["acquisition.test", "acquisition-other.test"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.registry.get(url.lastPathComponent) else { return }
        fixture.start(request, id: id)
        if url.path.hasPrefix("/redirect/") {
            let destination = URL(string: "https://acquisition-other.test/body/\(url.lastPathComponent)")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            fixture.stop(id)
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            return
        }
        let headers = fixture.knownLength ? ["Content-Length": String(fixture.body.count)] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0, chunk = 0
        while offset < fixture.body.count {
            let amount = fixture.chunkSizes.isEmpty ? fixture.body.count : fixture.chunkSizes[chunk % fixture.chunkSizes.count]
            let end = min(fixture.body.count, offset + amount)
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<end))
            offset = end; chunk += 1
        }
        fixture.delivered?()
        if fixture.timedOut {
            fixture.stop(id)
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        } else if fixture.finishes {
            fixture.stop(id)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        if let url = request.url { Self.registry.get(url.lastPathComponent)?.didStopLoading(id) }
    }
}
