// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSOwnedProxyTransportTests: XCTestCase {
    func testGeneratedManagedEndpointUsesOnlyTheAdmittedSelectedMediaRole() async throws {
        try await OwnedProxyFixture.withFixture(generated: true) { fixture in
            let media = try await fixture.document(fixture.proxy.itemURL)
            XCTAssertEqual(media.kind, .media)
            XCTAssertTrue(media.variants.isEmpty)
            XCTAssertEqual(media.segments.first?.resource.url.pathExtension, "ts")
            let calls = await fixture.transport.masterCalls
            XCTAssertEqual(calls, 1, "Generated preparation must not ask FFmpeg to choose the master service again")
        }
    }

    func testRealOwnedMasterReusesInitialDocumentAndRenewsOneHundredSignedRoleWindows() async throws {
        try await OwnedProxyFixture.withFixture { fixture in
            let initialCalls = await fixture.transport.masterCalls
            let initial = try await fixture.document(fixture.proxy.itemURL)
            let callsAfterInitial = await fixture.transport.masterCalls
            XCTAssertEqual(callsAfterInitial, initialCalls, "Initial admitted master must not be refetched")
            XCTAssertEqual(initial.variants.count, 1)
            XCTAssertEqual(initial.renditions.count, 2)
            let firstVariant = try XCTUnwrap(initial.variants.first?.url)
            let old = try await fixture.document(firstVariant)
            let oldSegment = try XCTUnwrap(old.segments.first?.resource.url)
            var held: HLSProxyResourceRegistry.Resource? = try fixture.proxy.resourceLeaseForTesting(path: oldSegment.path)
            let oldUpstream = try XCTUnwrap(held?.url)
            for _ in 0..<100 {
                let master = try await fixture.document(fixture.proxy.itemURL)
                let video = try await fixture.document(XCTUnwrap(master.variants.first?.url))
                XCTAssertEqual(video.segments.first?.resource.url.pathExtension, "ts")
                for rendition in master.renditions {
                    let child = try await fixture.document(XCTUnwrap(rendition.url))
                    XCTAssertEqual(child.segments.first?.resource.url.pathExtension,
                        rendition.attributes["TYPE"] == "SUBTITLES" ? "vtt" : "ts")
                }
                XCTAssertLessThanOrEqual(fixture.proxy.resourceCount, 32, "Three windows per original role, no signed URL history")
                XCTAssertLessThanOrEqual(fixture.proxy.admissionUsage.bytes, HLSProxyBudget.domainBytes)
            }
            XCTAssertEqual(held?.url, oldUpstream, "A held transfer cannot be retargeted by a new signature")
            let retainedBytes = fixture.proxy.admissionUsage.bytes
            held = nil
            XCTAssertLessThan(fixture.proxy.admissionUsage.bytes, retainedBytes)
            let headers = await fixture.transport.observedHeaderOrigins
            XCTAssertTrue(headers.contains { $0.0 == "signed-fixture.invalid" && $0.1 == "fixture credential" })
            XCTAssertTrue(headers.contains { $0.0 == "other-fixture.invalid" && $0.1 == nil })
        }
    }

    func testServedAESKeyBindsValidatedBytesAcrossSameURLRenewalsAndLastTransferAlias() async throws {
        try await OwnedProxyFixture.withFixture { fixture in
            let master = try await fixture.document(fixture.proxy.itemURL)
            let mediaURL = try XCTUnwrap(master.variants.first?.url)
            let initial = try await fixture.document(mediaURL)
            let oldKeyURL = try XCTUnwrap(initial.references.first { $0.kind == .key }?.url)
            var oldLease: HLSProxyResourceRegistry.Resource? = try fixture.proxy.resourceLeaseForTesting(path: oldKeyURL.path)
            let firstBytes = try XCTUnwrap(oldLease?.protectedBody?.data)
            await fixture.transport.setKey(0x42)
            let beforeRead = await fixture.transport.keyCalls
            let oldRead = try await fixture.read(oldKeyURL)
            XCTAssertEqual(oldRead.0, firstBytes, "The serving path must use the admitted response, not refetch a mutable key URL")
            let callsAfterRead = await fixture.transport.keyCalls
            XCTAssertEqual(callsAfterRead, beforeRead)
            let renewed = try await fixture.document(mediaURL)
            let newKeyURL = try XCTUnwrap(renewed.references.first { $0.kind == .key }?.url)
            XCTAssertNotEqual(newKeyURL, oldKeyURL, "Same upstream key locator has a fresh immutable response identity")
            await fixture.transport.setKey(0x63)
            let newRead = try await fixture.read(newKeyURL)
            XCTAssertEqual(newRead.0, Data(repeating: 0x42, count: 16))
            let oldReadAgain = try await fixture.read(oldKeyURL)
            XCTAssertEqual(oldReadAgain.0, firstBytes)
            let head = try await fixture.read(newKeyURL, method: "HEAD")
            XCTAssertTrue(head.0.isEmpty)
            XCTAssertEqual(head.1.value(forHTTPHeaderField: "Content-Length"), "16")
            let ranged = try await fixture.read(newKeyURL, range: "bytes=4-7")
            XCTAssertEqual(ranged.1.statusCode, 206)
            XCTAssertEqual(ranged.0, Data(repeating: 0x42, count: 4))
            for index in 0..<4 {
                await fixture.transport.setKey(UInt8(0x70 + index))
                _ = try await fixture.document(mediaURL)
            }
            XCTAssertEqual(oldLease?.protectedBody?.data, firstBytes)
            let heldCharge = fixture.proxy.admissionUsage.bytes
            oldLease = nil
            XCTAssertLessThan(fixture.proxy.admissionUsage.bytes, heldCharge, "Old response bytes release only after the last held transfer alias")
        }
    }

    func testHeldProtectedHTTPTransferKeepsOldBytesWhileNewWindowsPublishAndCancellationJoins() async throws {
        try await OwnedProxyFixture.withFixture { fixture in
            let master = try await fixture.document(fixture.proxy.itemURL)
            let media = try XCTUnwrap(master.variants.first?.url)
            let document = try await fixture.document(media)
            let key = try XCTUnwrap(document.references.first { $0.kind == .key }?.url)
            let gate = OwnedProxyGate(); fixture.gates.append(gate)
            fixture.proxy.holdProtectedTransferForTesting { path in if path == key.path { await gate.wait() } }
            let read = fixture.spawnRead(key)
            try await fixture.until { gate.entered }
            for index in 0..<4 {
                await fixture.transport.setKey(UInt8(0x30 + index))
                _ = try await fixture.document(media)
            }
            gate.release()
            let result = try await read.value
            XCTAssertEqual(result.0, Data(repeating: 0x11, count: 16))
            let secondGate = OwnedProxyGate(); fixture.gates.append(secondGate)
            let current = try await fixture.document(media)
            let currentKey = try XCTUnwrap(current.references.first { $0.kind == .key }?.url)
            fixture.proxy.holdProtectedTransferForTesting { _ in await secondGate.wait() }
            let heldRead = fixture.spawnRead(currentKey)
            try await fixture.until { secondGate.entered }
            heldRead.cancel()
            secondGate.release()
            _ = await heldRead.result
        }
    }

    func testHeldSignedRefreshCannotPublishAfterOriginalSourceInvalidation() async throws {
        try await OwnedProxyFixture.withFixture { fixture in
            _ = try await fixture.document(fixture.proxy.itemURL)
            let count = fixture.proxy.resourceCount
            let gate = OwnedProxyGate(); fixture.gates.append(gate)
            await fixture.transport.holdNextMaster(gate)
            let request = fixture.spawnRead(fixture.proxy.itemURL)
            try await fixture.until { gate.entered }
            await fixture.resolver.invalidate()
            gate.release()
            let response = try await request.value
            XCTAssertEqual(response.1.statusCode, 502)
            XCTAssertEqual(fixture.proxy.resourceCount, count, "A canceled original owner must not publish a refreshed window")
        }
    }
}

private final class OwnedProxyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false, enteredValue = false
    private var continuation: CheckedContinuation<Void, Never>?
    var entered: Bool { lock.withLock { enteredValue } }
    func wait() async {
        await withCheckedContinuation { pending in
            let immediate = lock.withLock { () -> Bool in
                enteredValue = true
                if open { return true }
                precondition(continuation == nil); continuation = pending; return false
            }
            if immediate { pending.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { open = true; defer { continuation = nil }; return continuation }
        pending?.resume()
    }
}

private final class OwnedProxyFixture: @unchecked Sendable {
    let transport: RotatingOwnedProxyTransport
    let resolver: URLSessionPlaybackSourceResolver
    let proxy: HLSProxySession
    private let client: URLSession
    private let owned: HLSOwnedSourcePlan
    var gates: [OwnedProxyGate] = []
    var reads: [Task<(Data, HTTPURLResponse), any Error>] = []
    private init(transport: RotatingOwnedProxyTransport, resolver: URLSessionPlaybackSourceResolver,
                 proxy: HLSProxySession, owned: HLSOwnedSourcePlan) {
        self.transport = transport; self.resolver = resolver; self.proxy = proxy; self.owned = owned
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        client = URLSession(configuration: configuration)
    }
    static func withFixture(generated: Bool = false, _ body: (OwnedProxyFixture) async throws -> Void) async throws {
        let transport = RotatingOwnedProxyTransport()
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let context = try sourceContext(url: RotatingOwnedProxyTransport.root, attributes: ["Authorization": "fixture credential"])
        let source = try await resolver.resolve(context, reason: .initial)
        let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
        let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        guard case let .hls(graph) = source.topology else { throw HLSSourceError.unsupportedMedia }
        let facts = HLSCompatibilityFacts(source: source, media: graph.orderedDocuments.filter { $0.kind == .media }.map {
            HLSMediaFacts(url: $0.responseURL, container: $0.responseURL.path == "/subtitle" ? .webVTT : .mpegTS,
                video: nil, audio: [], hasUnsupportedTracks: false)
        }, complete: true, inspectedBytes: 0)
        let owner = try XCTUnwrap(context.owner)
        let plan = HLSPlaybackPlan(owner: owner, resolutionGeneration: source.generation, transport: generated ? .generated : .proxy,
            video: generated ? .remux : .source, audio: .source,
            selectedServiceURL: generated ? graph.document(for: graph.rootURL)?.variants.first?.url : nil, formatFingerprint: facts.formatFingerprint)
        let owned = HLSOwnedSourcePlan(source: source, facts: facts, plan: plan, resolver: resolver,
            sourceCharge: sourceCharge, factsCharge: factsCharge)
        let lifecycle = OutputLifecycleEpoch(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce)
        let proxy = try await HLSByteProxy.start(source: source, lifecycle: lifecycle, resolver: resolver,
            sourceRetention: sourceCharge, manifestAuthority: owned.makeProxyManifestAuthority(), useGeneratedSelectedService: generated, manifestTransport: transport)
        let fixture = OwnedProxyFixture(transport: transport, resolver: resolver, proxy: proxy, owned: owned)
        var failure: (any Error)?
        do { try await body(fixture) } catch { failure = error }
        fixture.gates.forEach { $0.release() }
        fixture.reads.forEach { $0.cancel() }
        for read in fixture.reads { _ = await read.result }
        await resolver.invalidate()
        let joined = await proxy.retire()
        fixture.client.invalidateAndCancel()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        if let failure { throw failure }
    }
    func read(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let result = try await client.data(for: request)
        return (result.0, try XCTUnwrap(result.1 as? HTTPURLResponse))
    }
    func document(_ url: URL) async throws -> HLSManifestGraph.Document {
        let result = try await read(url)
        guard result.1.statusCode == 200 else { throw HLSSourceError.httpStatus(result.1.statusCode) }
        return try XCTUnwrap(HLSManifestGraph.parse(data: result.0, responseURL: url).document(for: url))
    }
    func spawnRead(_ url: URL) -> Task<(Data, HTTPURLResponse), any Error> {
        let task = Task { try await self.read(url) }; reads.append(task); return task
    }
    func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else { throw HLSSourceError.deadline }
    }
}

private actor RotatingOwnedProxyTransport: HLSResourceTransport {
    static let root = URL(string: "https://signed-fixture.invalid/master")!
    private(set) var masterCalls = 0, keyCalls = 0
    private var childCalls = 0
    private var keyByte: UInt8 = 0x11
    private var masterGate: OwnedProxyGate?
    private(set) var observedHeaderOrigins: [(String, String?)] = []
    func setKey(_ byte: UInt8) { keyByte = byte }
    func holdNextMaster(_ gate: OwnedProxyGate) { masterGate = gate }
    func fetch(_ request: HLSResourceRequest) async throws -> HLSResourceResponse {
        if observedHeaderOrigins.count < 16 {
            observedHeaderOrigins.append((request.url.host ?? "", request.headers.fields(for: request.url)["Authorization"]))
        }
        if request.url.path == "/key" {
            keyCalls += 1
            return .init(responseURL: request.url, data: Data(repeating: keyByte, count: 16))
        }
        let text: String
        if request.url.path == "/master" {
            masterCalls += 1
            let signature = masterCalls
            let gate = masterGate; masterGate = nil
            await gate?.wait()
            text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Main\",DEFAULT=YES,URI=\"https://other-fixture.invalid/audio?signature=\(signature)\"\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"text\",NAME=\"English\",LANGUAGE=\"en\",URI=\"subtitle?signature=\(signature)\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO=\"audio\",SUBTITLES=\"text\"\nvideo?signature=\(signature)\n"
        } else {
            childCalls += 1
            let key = request.url.path == "/subtitle" ? "" : "#EXT-X-KEY:METHOD=AES-128,URI=\"https://signed-fixture.invalid/key\",IV=0x00000000000000000000000000000001\n"
            text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n\(key)#EXTINF:2,\npart?signature=\(childCalls)\n"
        }
        guard text.utf8.count <= request.maximumBytes else { throw HLSSourceError.byteLimit }
        return .init(responseURL: request.url, data: Data(text.utf8))
    }
}
