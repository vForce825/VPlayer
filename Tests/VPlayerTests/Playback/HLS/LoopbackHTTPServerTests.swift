// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

final class LoopbackHTTPServerTests: XCTestCase {
    func testSessionTokenIsSystemSignedPerSessionAndHasCanonicalLowercaseHex() async throws {
        let first = try await Task20HTTPFixture.start()
        let second = try await Task20HTTPFixture.start()
        defer { first.shutdown(); second.shutdown() }
        for token in [first.token, second.token] {
            XCTAssertEqual(token.utf8.count, 32)
            XCTAssertTrue(token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertNotEqual(first.server.sessionCapabilityIdentity,
                          second.server.sessionCapabilityIdentity)
    }

    func testProductionFactoryRejectsRawTokenStoreEvenWhenEveryVisibleTokenMatches() async throws {
        do {
            _ = try await LoopbackHTTPSessionFactory().start(
                itemGeneration: 19, now: { 0 }, logger: { _ in }, responseFailure: { _, _ in }
            ) { capability in
                let harness = try Task19Harness(token: capability.value)
                try harness.initial()
                var declaration = try Task19.declaration()
                declaration.token = capability.value
                return LoopbackPreparedPublication(store: harness.store, declaration: declaration,
                    snapshot: try XCTUnwrap(harness.publisher.visible))
            }
            XCTFail("相同裸 token 不能伪造系统签发的 session capability")
        } catch {
            XCTAssertEqual(error as? LoopbackHTTPServerError, .invalidConfiguration)
        }
    }

    func testSystemCSPRNGFailureShortReadAndProbeCancellationFailBeforeVisibility() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            for fault in [LoopbackHTTPTestingConfiguration.EntropyFault.failure,
                          .shortRead] {
                let prepared = LockedInts()
                let configuration = LoopbackHTTPTestingConfiguration(
                    capability: capability, entropyFault: fault)
                do {
                    _ = try await LoopbackHTTPSessionFactory(testing: configuration).start(
                        itemGeneration: 19, now: { 0 }, logger: { _ in },
                        responseFailure: { _, _ in }
                    ) { token in
                        prepared.append(1)
                        let harness = try Task19Harness(loopbackSession: token)
                        try harness.initial()
                        var declaration = try Task19.declaration()
                        declaration.token = token.value
                        return LoopbackPreparedPublication(store: harness.store,
                            declaration: declaration,
                            snapshot: try XCTUnwrap(harness.publisher.visible))
                    }
                    XCTFail("系统随机失败或短读不能进入 prepare")
                } catch {
                    XCTAssertEqual(error as? LoopbackHTTPServerError, .randomnessUnavailable)
                }
                XCTAssertTrue(prepared.values.isEmpty)
            }

            let storeBox = LockedHarness()
            let configuration = LoopbackHTTPTestingConfiguration(
                capability: capability, cancelAfterStartupProbeAccepted: true)
            do {
                _ = try await LoopbackHTTPSessionFactory(testing: configuration).start(
                    itemGeneration: 19, now: { 0 }, logger: { _ in },
                    responseFailure: { _, _ in }
                ) { token in
                    let harness = try Task19Harness(loopbackSession: token)
                    try harness.initial()
                    storeBox.value = harness
                    var declaration = try Task19.declaration()
                    declaration.token = token.value
                    return LoopbackPreparedPublication(store: harness.store,
                        declaration: declaration,
                        snapshot: try XCTUnwrap(harness.publisher.visible))
                }
                XCTFail("probe accepted 与 connectionReady 之间的取消必须结束 continuation")
            } catch {
                XCTAssertTrue(error is CancellationError
                    || error as? LoopbackHTTPServerError == .transportUnavailable)
            }
            XCTAssertTrue(try XCTUnwrap(storeBox.value).store.isClosed)
        }
    }

    func testPublicationCommitAtomicallyRefreshesRoutesHEADMetadataNewEpochAndOldHorizon() async throws {
        let clock = LockedClock(0)
        let fixture = try await Task20HTTPFixture.start(now: { clock.value })
        defer { fixture.shutdown() }
        let initial = try XCTUnwrap(fixture.task19.publisher.visible)
        let playlistPath = try XCTUnwrap(initial.participantVector.first { $0.participantID == 1 })
            .declaration.playlistURI(participantID: 1)
        let initialHEAD = try rawRequest(port: fixture.server.port, method: "HEAD", target: playlistPath)

        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
            now: Task19.second), .published)
        let refreshed = try XCTUnwrap(fixture.task19.publisher.visible)
        let refreshedPlaylist = try XCTUnwrap(refreshed.media[1])
        let currentHEAD = try rawRequest(port: fixture.server.port, method: "HEAD", target: playlistPath)
        XCTAssertEqual(currentHEAD.status, 200)
        XCTAssertEqual(currentHEAD.headers["content-length"], String(refreshedPlaylist.raw.count))
        XCTAssertEqual(currentHEAD.headers["etag"], Self.etag(refreshedPlaylist.raw))
        XCTAssertNotEqual(currentHEAD.headers["etag"], initialHEAD.headers["etag"])
        let newlyAdvertised = try XCTUnwrap(refreshedPlaylist.resources.last)
        let newPath = try fixture.task19.store.resourceURI(newlyAdvertised,
            declaration: try XCTUnwrap(refreshed.participantVector.first { $0.participantID == 1 }).declaration)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: newPath).status, 200)

        let oldKey = try XCTUnwrap(initial.media[1]?.resources.first)
        let oldPath = try fixture.task19.store.resourceURI(oldKey,
            declaration: try XCTUnwrap(initial.participantVector.first { $0.participantID == 1 }).declaration)
        try fixture.task19.beginEpoch(2)
        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
            now: Task19.second * 2), .published)
        let epochTwo = try XCTUnwrap(fixture.task19.publisher.visible)
        let epochTwoPlaylist = try XCTUnwrap(epochTwo.media[1])
        for key in [try XCTUnwrap(epochTwoPlaylist.initializationResources.last),
                    try XCTUnwrap(epochTwoPlaylist.resources.last)] {
            let path = try fixture.task19.store.resourceURI(key,
                declaration: try XCTUnwrap(epochTwo.participantVector.first { $0.participantID == 1 }).declaration)
            XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path).status, 200)
        }
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: oldPath).status, 200)
        clock.value = Task19.second * 60
        fixture.task19.store.sweep(now: clock.value)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: oldPath).status, 410)
    }

    func testIncrementalParserEnforcesLineHeaderFieldAndPipeliningBounds() throws {
        var parser = LoopbackRequestParser()
        XCTAssertNil(try parser.append(Data("GET /v1/a/1/video/index.m3u8 HTTP/1.1\r\nHo".utf8)))
        let request = try XCTUnwrap(parser.append(Data("st: 127.0.0.1:1234\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.target, "/v1/a/1/video/index.m3u8")
        XCTAssertEqual(request.values(forHeader: "host"), ["127.0.0.1:1234"])

        let tooLongLine = "GET /" + String(repeating: "a", count: 4_096) + " HTTP/1.1\r\nHost: x\r\n\r\n"
        XCTAssertThrowsError(try LoopbackRequestParser.parseComplete(Data(tooLongLine.utf8))) {
            XCTAssertEqual($0 as? LoopbackRequestError, .requestLineTooLarge)
        }
        let tooMany = "GET / HTTP/1.1\r\n" + (0..<33).map { "X-\($0): y\r\n" }.joined() + "\r\n"
        XCTAssertThrowsError(try LoopbackRequestParser.parseComplete(Data(tooMany.utf8))) {
            XCTAssertEqual($0 as? LoopbackRequestError, .tooManyHeaderFields)
        }
        XCTAssertThrowsError(try LoopbackRequestParser.parseComplete(
            Data(repeating: 65, count: 16_385)
        )) { XCTAssertEqual($0 as? LoopbackRequestError, .headerTooLarge) }
        XCTAssertThrowsError(try LoopbackRequestParser.parseComplete(
            Data("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        )) { XCTAssertEqual($0 as? LoopbackRequestError, .pipelinedBytes) }
    }

    func testParserRejectsEveryRequestBodyAndSmugglingShapeBeforeAuthorization() {
        let badHeaders = [
            "Transfer-Encoding: chunked",
            "transfer-encoding: identity",
            "Content-Length: 1",
            "Content-Length: -1",
            "Content-Length: +0",
            "Content-Length: 00",
            "Content-Length: 0x0",
            "Content-Length: 18446744073709551616",
            "Content-Length: 0\r\nContent-Length: 0",
            "Content-Length: 0, 0",
            "Transfer-Encoding: chunked\r\nContent-Length: 0",
            "X-A: one\r\n two",
            "X-A: one\r\n\ttwo",
        ]
        for fields in badHeaders {
            let bytes = Data("GET /never-authorized HTTP/1.1\r\nHost: x\r\n\(fields)\r\n\r\n".utf8)
            XCTAssertThrowsError(try LoopbackRequestParser.parseComplete(bytes), fields) { error in
                guard let actual = error as? LoopbackRequestError else { return XCTFail("错误类型不符：\(error)") }
                XCTAssertTrue([.invalidSyntax, .requestBodyForbidden, .transferEncodingForbidden,
                               .duplicateContentLength, .obsoleteLineFolding].contains(actual))
            }
        }
    }

    func testOversizedHeaderReturns431ClosesAndNeverAcquiresAResourceLease() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.task19.publisher.visible?.media[1])
        let key = try XCTUnwrap(snapshot.resources.first)
        let path = try fixture.server.path(for: key)
        let before = fixture.task19.store.usage
        let oversized = "X-Oversized: " + String(repeating: "a", count: 16_385)
        let reply = try rawRequest(port: fixture.server.port, target: path,
                                   rawAdditionalHeaders: oversized)
        XCTAssertEqual(reply.status, 431)
        XCTAssertEqual(reply.headers["connection"], "close")
        XCTAssertEqual(fixture.task19.store.usage.responseBackingBytes, before.responseBackingBytes)
        XCTAssertEqual(fixture.task19.store.usage.distinctResponseBackings, before.distinctResponseBackings)
    }

    func testGzipQValuesMergeAcrossFieldsAndHEADMatchesGETRepresentation() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let raw = try rawRequest(port: fixture.server.port, target: fixture.server.masterPath,
            rawAdditionalHeaders: "Accept-Encoding: gzip;q=0\r\nAccept-Encoding: br;q=1")
        XCTAssertEqual(raw.status, 200)
        XCTAssertNil(raw.headers["content-encoding"])
        let gzip = try rawRequest(port: fixture.server.port, target: fixture.server.masterPath,
            rawAdditionalHeaders: "Accept-Encoding: br;q=1\r\nAccept-Encoding: gzip;q=0.25")
        XCTAssertEqual(gzip.headers["content-encoding"], "gzip")
        let head = try rawRequest(port: fixture.server.port, method: "HEAD", target: fixture.server.masterPath,
            rawAdditionalHeaders: "Accept-Encoding: gzip;q=0")
        XCTAssertEqual(head.status, raw.status)
        XCTAssertEqual(head.headers["content-length"], raw.headers["content-length"])
        XCTAssertEqual(head.headers["etag"], raw.headers["etag"])
        XCTAssertNil(head.headers["content-encoding"])
        XCTAssertTrue(head.body.isEmpty)

        let malformed = try rawRequest(port: fixture.server.port, target: fixture.server.masterPath,
            headers: ["Accept-Encoding": "gzip;q=wat"])
        XCTAssertNil(malformed.headers["content-encoding"], "畸形 qvalue 必须安全回退 raw")
        for invalid in ["gzip;q=.5", "gzip;q=1.0000", "gzip;q=0;q=1",
                        "gzip;q=0, gzip;q=1", "gzip;q=0.1234"] {
            let reply = try rawRequest(port: fixture.server.port, target: fixture.server.masterPath,
                headers: ["Accept-Encoding": invalid])
            XCTAssertNil(reply.headers["content-encoding"], "非法或重复 qvalue 必须整体安全回退 raw：\(invalid)")
            let head = try rawRequest(port: fixture.server.port, method: "HEAD",
                target: fixture.server.masterPath, headers: ["Accept-Encoding": invalid])
            XCTAssertEqual(head.headers["etag"], reply.headers["etag"])
            XCTAssertEqual(head.headers["content-length"], reply.headers["content-length"])
            XCTAssertNil(head.headers["content-encoding"])
        }
    }

    func testEndpointValidatorRequiresIPv4LoopbackListenerLocalAndPeer() {
        let port = NWEndpoint.Port(rawValue: 9_999)!
        let loopback: NWEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: port)
        let any: NWEndpoint = .hostPort(host: .ipv4(IPv4Address("0.0.0.0")!), port: port)
        let lan: NWEndpoint = .hostPort(host: .ipv4(IPv4Address("192.0.2.1")!), port: port)
        XCTAssertTrue(LoopbackEndpointValidator.accepts(listener: loopback, local: loopback,
                                                         remote: loopback, expectedPort: port.rawValue))
        XCTAssertFalse(LoopbackEndpointValidator.accepts(listener: any, local: loopback,
                                                          remote: loopback, expectedPort: port.rawValue))
        XCTAssertFalse(LoopbackEndpointValidator.accepts(listener: loopback, local: any,
                                                          remote: loopback, expectedPort: port.rawValue))
        XCTAssertFalse(LoopbackEndpointValidator.accepts(listener: loopback, local: loopback,
                                                          remote: lan, expectedPort: port.rawValue))
        XCTAssertFalse(LoopbackEndpointValidator.accepts(listener: loopback, local: loopback,
                                                          remote: loopback, expectedPort: 10_000))
    }

    func testPresentationRangeInitializerThrowsOnOverflowAndInvalidDuration() throws {
        XCTAssertThrowsError(try FMP4PresentationRange(start: .init(value: .max, timescale: 1),
                                                        duration: Task19.time(1)))
        XCTAssertThrowsError(try FMP4PresentationRange(start: Task19.time(0),
                                                        duration: Task19.time(0)))
        let range = try FMP4PresentationRange(start: Task19.time(3), duration: Task19.time(2))
        XCTAssertEqual(range.end, Task19.time(5))
    }

    func testDecodeCoverageMapRejectsEntryAndAllocationBoundariesBeforeVisibility() throws {
        let layout = LoopbackStorageLayout.current
        XCTAssertEqual(LoopbackRequestParser.fixedStorageBytes, 16 * 1_024)
        XCTAssertEqual(layout.parserAllocationBytes, 16 * 1_024)
        XCTAssertLessThanOrEqual(layout.coverageAccumulatorDependencyCapacity, 16)
        XCTAssertLessThanOrEqual(layout.coverageAccumulatorRangeCapacity, 64)
        XCTAssertEqual(layout.decodeSampleStride, MemoryLayout<SealedDecodeSampleEntry>.stride)
        XCTAssertLessThanOrEqual(try layout.decodeMapAllocation(sampleCount: 256,
                                                                commonSpanCount: 48),
                                 32 * 1_024)
        XCTAssertThrowsError(try layout.decodeMapAllocation(sampleCount: 256,
                                                            commonSpanCount: 49)) {
            XCTAssertEqual($0 as? CompletedMediaEvidenceError, .capacityExceeded)
        }
        XCTAssertThrowsError(try layout.decodeMapAllocation(sampleCount: 257,
                                                            commonSpanCount: 0)) {
            XCTAssertEqual($0 as? CompletedMediaEvidenceError, .capacityExceeded)
        }
    }

    func testServersShareProcessApplicationLedgerAndRealResponsesDeduplicateBacking() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                pauseBeforeBodySend: true)
            let first = try await Task20HTTPFixture.start(testing: configuration)
            let second = try await Task20HTTPFixture.start()
            defer { first.shutdown(); second.shutdown() }
            XCTAssertEqual(first.server.usage.applicationLedgerIdentity,
                           second.server.usage.applicationLedgerIdentity,
                           "全部 session/generation 必须共用唯一进程账本")

            let key = try XCTUnwrap(first.task19.publisher.visible?.media[1]?.resources.first)
            let path = try first.server.path(for: key)
            var clients: [ConnectedSocket] = []
            for _ in 0..<8 {
                let client = try ConnectedSocket(port: first.server.port)
                try client.sendOnly("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(first.server.port)\r\nConnection: close\r\n\r\n")
                clients.append(client)
            }
            XCTAssertTrue(waitUntil { first.server.usage.maximumActiveResponses >= 6 })
            let usage = first.server.usage
            XCTAssertEqual(usage.maximumActiveResponses, 6,
                           "soft 六响应必须真实可达，后继在副作用前背压")
            XCTAssertEqual(usage.maximumDistinctBackingCount, 1,
                           "同一 sealed backing 的并发 GET 必须按 identity 去重")
            XCTAssertLessThanOrEqual(usage.maximumDistinctBackingBytes,
                                     128 * 1_048_576)
            XCTAssertLessThanOrEqual(usage.maximumParserAndStagingBytes,
                                     LoopbackStorageLayout.current.httpHardTemporaryBytes)
            XCTAssertGreaterThan(usage.applicationChargedBytes, 0)
            first.server.resumePausedBodySends(testing: capability)
            clients.forEach { $0.reset() }
            clients.removeAll()
            XCTAssertTrue(waitUntil { first.server.usage.activeResponses == 0 })
        }
    }

    func testStoreCompletionAuthorityAndCoverageReceiptOnlyAdvanceAfterRealSocketTerminal() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        defer { fixture.shutdown() }
        let playlist = try XCTUnwrap(fixture.publication.publisher.visible?.media[2])
        let mediaKey = try XCTUnwrap(playlist.resources.dropLast().last)
        let initKey = try XCTUnwrap(playlist.initializationResources.first)
        let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: mediaKey))
        let requested = try XCTUnwrap(map.samples.first).presentationRange
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)

        XCTAssertEqual(fixture.server.completedEvidence(for: mediaKey)?.evidence,
                       CompletedBodyEvidence.none)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, method: "HEAD",
            target: fixture.server.path(for: initKey)).status, 200)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, method: "HEAD",
            target: fixture.server.path(for: mediaKey)).status, 200)

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: mediaKey)).status, 200)
        XCTAssertEqual(fixture.server.completedEvidence(for: mediaKey)?.uniqueResponseCount, 1)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: initKey)).status, 200)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, lifecycle: lifecycle)
        let context = Self.makeCoverageContext(rendition: 2, nonce: 101,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        let receipt = try XCTUnwrap(fixture.server.coverageReceipt(for: context, adding: requested))
        let dependency = try XCTUnwrap(receipt.dependencies.first)
        XCTAssertEqual(receipt.dependencies.count, 1)
        XCTAssertEqual(dependency.epochProofIdentity, map.epochProofIdentity)
        XCTAssertEqual(dependency.segmentReceiptIdentity, map.segmentReceiptIdentity)
        XCTAssertEqual(dependency.mediaBackingIdentity,
                       fixture.server.completedEvidence(for: mediaKey)?.resourceIdentity)
        XCTAssertEqual(dependency.initializationBackingIdentity,
                       fixture.server.completedEvidence(for: initKey)?.resourceIdentity)

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: mediaKey)).status, 200)
        XCTAssertEqual(fixture.server.completedEvidence(for: mediaKey)?.uniqueResponseCount, 1,
                       "重复完整 GET 必须消费不同 lease，但合并为同一个数学 response identity")
        XCTAssertEqual(try fixture.server.coverageReceipt(for: context, adding: requested), receipt)
    }

    func testDirectLeaseCannotCompleteAndControlledNthChunkFailureReleasesAuthority() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                bodyChunkBytes: 16, failAfterSuccessfulBodyChunks: 1)
            let fixture = try await Task20HTTPFixture.start(testing: configuration)
            defer { fixture.shutdown() }
            let mediaKey = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)

            let direct = try XCTUnwrap(fixture.task19.store.acquireResponse(mediaKey,
                token: fixture.token, now: 0))
            XCTAssertGreaterThan(direct.withUnsafeBytes { $0.count }, 16)
            fixture.task19.store.release(direct, now: 0)
            XCTAssertEqual(fixture.server.completedEvidence(for: mediaKey)?.evidence,
                           CompletedBodyEvidence.none,
                           "直接 acquire/release 不得产生 send-terminal capability")

            let reply = try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: mediaKey))
            XCTAssertEqual(reply.status, 200)
            XCTAssertLessThan(reply.body.count, direct.residentByteCount)
            XCTAssertTrue(waitUntil {
                fixture.task19.store.usage.responseBackingBytes == 0
                    && fixture.server.usage.activeResponses == 0
            })
            XCTAssertEqual(fixture.server.completedEvidence(for: mediaKey)?.evidence,
                           CompletedBodyEvidence.none,
                           "第 N 块真实 send 失败不能签发完成终态")
        }
    }

    func testRequestedCoverageRejectsTailAndCanonicalizesDecompositionNestingAndOrder() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, lifecycle: lifecycle)
        let playlist = try XCTUnwrap(snapshot.media[2])
        let mediaKey = try XCTUnwrap(playlist.resources.first)
        let initKey = try XCTUnwrap(playlist.initializationResources.first)
        let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: mediaKey))
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: initKey)).status, 200)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: mediaKey)).status, 200)

        let first = try XCTUnwrap(map.samples.first).presentationRange
        let last = try XCTUnwrap(map.samples.last).presentationRange
        let whole = try FMP4PresentationRange(start: first.start,
            duration: last.end.subtracting(first.start))
        let outsideEnd = try last.end.adding(.init(value: 1, timescale: last.end.timescale))
        let outside = try FMP4PresentationRange(start: first.start,
            duration: outsideEnd.subtracting(first.start))
        XCTAssertNil(try fixture.server.coverageReceipt(
            for: Self.makeCoverageContext(rendition: 2, nonce: 102,
                timeline: timeline.authority, selectionCapability: timeline.selection),
            adding: outside))

        let middle = map.samples[map.samples.count / 2].presentationRange.start
        let leading = try FMP4PresentationRange(start: first.start,
            duration: middle.subtracting(first.start))
        let trailing = try FMP4PresentationRange(start: middle,
            duration: last.end.subtracting(middle))
        let fullContext = Self.makeCoverageContext(rendition: 2, nonce: 103,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        let splitContext = Self.makeCoverageContext(rendition: 2, nonce: 104,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        let reverseContext = Self.makeCoverageContext(rendition: 2, nonce: 105,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        let fullReceipt = try XCTUnwrap(fixture.server.coverageReceipt(for: fullContext, adding: whole))
        _ = try fixture.server.coverageReceipt(for: splitContext, adding: leading)
        let splitReceipt = try XCTUnwrap(fixture.server.coverageReceipt(for: splitContext, adding: trailing))
        _ = try fixture.server.coverageReceipt(for: reverseContext, adding: trailing)
        let reverseReceipt = try XCTUnwrap(fixture.server.coverageReceipt(for: reverseContext, adding: leading))
        XCTAssertEqual(fullReceipt.canonicalCoverageDigest, splitReceipt.canonicalCoverageDigest)
        XCTAssertEqual(fullReceipt.canonicalCoverageDigest, reverseReceipt.canonicalCoverageDigest)
        XCTAssertEqual(fullReceipt.presentationRange, whole)

        let nestedContext = Self.makeCoverageContext(rendition: 2, nonce: 106,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        var nestedReceipt: ServedRenditionCoverageReceipt?
        for ticks in 1...129 {
            let range = try FMP4PresentationRange(start: first.start,
                duration: .init(value: Int64(ticks), timescale: first.duration.timescale))
            nestedReceipt = try fixture.server.coverageReceipt(for: nestedContext, adding: range)
        }
        XCTAssertNotNil(nestedReceipt, "嵌套请求必须先做数学 union，不能耗尽固定 dependency vector")
    }

    func testCoverageRejectsMissingMiddleSegmentUntilRealSocketCompletesGap() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, lifecycle: lifecycle)
        let playlist = try XCTUnwrap(snapshot.media[2])
        XCTAssertGreaterThanOrEqual(playlist.resources.count, 3)
        let initKey = try XCTUnwrap(playlist.initializationResources.first)
        let firstKey = playlist.resources[0]
        let middleKey = playlist.resources[1]
        let lastKey = playlist.resources[2]
        let firstMap = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: firstKey))
        let lastMap = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: lastKey))
        let start = try XCTUnwrap(firstMap.samples.first).presentationRange.start
        let end = try XCTUnwrap(lastMap.samples.last).presentationRange.end
        let requested = try FMP4PresentationRange(start: start, duration: end.subtracting(start))
        let context = Self.makeCoverageContext(rendition: 2, nonce: 107,
            timeline: timeline.authority, selectionCapability: timeline.selection)

        for key in [initKey, firstKey, lastKey] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        XCTAssertNil(try fixture.server.coverageReceipt(for: context, adding: requested))
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: middleKey)).status, 200)
        XCTAssertEqual(try XCTUnwrap(fixture.server.coverageReceipt(for: context, adding: requested))
            .presentationRange, requested)
    }

    func testVideoCoverageHoldsDecodedFrameAcrossBoundedTimestampGap()
        async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let key = try XCTUnwrap(
            fixture.task19.publisher.visible?.media[1]?.resources.first
        )
        XCTAssertEqual(try rawRequest(
            port: fixture.server.port,
            target: fixture.server.path(for: key)
        ).status, 200)
        let evidence = try XCTUnwrap(fixture.server.completedEvidence(for: key))
        XCTAssertGreaterThanOrEqual(evidence.sealedBodyLength, 40)

        func sample(_ ordinal: UInt16, _ start: Int64, _ span: Range<Int>,
                    randomAccess: Bool = false) throws -> SealedDecodeSampleEntry {
            .init(
                decodeOrdinal: ordinal,
                presentationRange: try FMP4PresentationRange(
                    start: .init(value: start, timescale: 100),
                    duration: .init(value: 2, timescale: 100)
                ),
                byteSpan: span,
                nearestRandomAccessOrdinal: 0,
                isRandomAccess: randomAccess,
                containsInBandConfiguration: false
            )
        }
        let first = try SealedDecodeCoverageMap(
            mediaType: .video,
            sealedBodyLength: evidence.sealedBodyLength,
            commonByteSpans: [0..<8],
            samples: [
                sample(0, 0, 8..<16, randomAccess: true),
            ]
        )
        let second = try SealedDecodeCoverageMap(
            mediaType: .video,
            sealedBodyLength: evidence.sealedBodyLength,
            commonByteSpans: [0..<8],
            samples: [sample(0, 8, 16..<24, randomAccess: true)]
        )
        let excessiveGap = try SealedDecodeCoverageMap(
            mediaType: .video,
            sealedBodyLength: evidence.sealedBodyLength,
            commonByteSpans: [0..<8],
            samples: [
                sample(0, 0, 24..<32, randomAccess: true),
                sample(1, 9, 32..<40),
            ]
        )
        let requested = try FMP4PresentationRange(
            start: .init(value: 0, timescale: 100),
            duration: .init(value: 10, timescale: 100)
        )

        XCTAssertFalse(try first.isCovered(by: evidence, requested: requested))
        XCTAssertEqual(try first.coveredFragments(by: evidence, intersecting: requested), [
            try FMP4PresentationRange(start: .init(value: 0, timescale: 100),
                                      duration: .init(value: 8, timescale: 100)),
        ])
        XCTAssertEqual(try second.coveredFragments(by: evidence, intersecting: requested), [
            try FMP4PresentationRange(start: .init(value: 8, timescale: 100),
                                      duration: .init(value: 2, timescale: 100)),
        ])
        XCTAssertEqual(try excessiveGap.coveredFragments(by: evidence,
                                                          intersecting: requested), [
            try FMP4PresentationRange(start: .init(value: 0, timescale: 100),
                                      duration: .init(value: 8, timescale: 100)),
            try FMP4PresentationRange(start: .init(value: 9, timescale: 100),
                                      duration: .init(value: 1, timescale: 100)),
        ])
    }

    func testCoverageRequiresRealMdatHeaderCompletionBeforeReceipt() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, lifecycle: lifecycle)
        let playlist = try XCTUnwrap(snapshot.media[2])
        let initKey = try XCTUnwrap(playlist.initializationResources.first)
        let mediaKey = try XCTUnwrap(playlist.resources.first)
        let bytes = try fixture.resourceBytes(mediaKey)
        let marker = Data("mdat".utf8)
        let markerRange = try XCTUnwrap(bytes.range(of: marker))
        let header = (markerRange.lowerBound - 4)..<markerRange.upperBound
        XCTAssertGreaterThan(header.lowerBound, 0)
        XCTAssertLessThan(header.upperBound, bytes.count)
        let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: mediaKey))
        let start = try XCTUnwrap(map.samples.first).presentationRange.start
        let end = try XCTUnwrap(map.samples.last).presentationRange.end
        let requested = try FMP4PresentationRange(start: start, duration: end.subtracting(start))
        let context = Self.makeCoverageContext(rendition: 2, nonce: 108,
            timeline: timeline.authority, selectionCapability: timeline.selection)

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: initKey)).status, 200)
        for range in [0..<header.lowerBound, header.upperBound..<bytes.count] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: mediaKey),
                headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"]).status, 206)
        }
        XCTAssertNil(try fixture.server.coverageReceipt(for: context, adding: requested),
                     "完整 samples 之外仍必须覆盖 mdat header")
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: mediaKey),
            headers: ["Range": "bytes=\(header.lowerBound)-\(header.upperBound - 1)"]).status, 206)
        XCTAssertNotNil(try fixture.server.coverageReceipt(for: context, adding: requested))
    }

    func testCoverageReceiptIsOpaqueAndRetiredDependencyCannotJoinSuccessorEpoch() async throws {
        let clock = LockedClock(0)
        let fixture = try await Task20HTTPFixture.start(now: { clock.value })
        defer { fixture.shutdown() }
        let firstSnapshot = try XCTUnwrap(fixture.task19.publisher.visible?.media[1])
        let oldInit = try XCTUnwrap(firstSnapshot.initializationResources.first)
        let oldMedia = try XCTUnwrap(firstSnapshot.resources.first)
        let oldMap = try XCTUnwrap(fixture.task19.store.decodeCoverageMap(for: oldMedia))
        let oldRange = try XCTUnwrap(oldMap.samples.first).presentationRange
        let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, authorityParticipantID: 2)
        let context = Self.makeCoverageContext(rendition: 1, nonce: 301,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        for key in [oldInit, oldMedia] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let oldReceipt = try XCTUnwrap(fixture.server.coverageReceipt(
            for: context, adding: oldRange))
        XCTAssertEqual(Mirror(reflecting: oldReceipt).displayStyle, .class,
                       "coverage receipt 必须是无 memberwise initializer 的 opaque capability")

        try fixture.task19.beginEpoch(2)
        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
            now: Task19.second), .published)
        let successor = try XCTUnwrap(fixture.task19.publisher.visible?.media[1])
        let newInit = try XCTUnwrap(successor.initializationResources.last)
        let newMedia = try XCTUnwrap(successor.resources.last)
        clock.value = Task19.second * 60
        fixture.task19.store.sweep(now: clock.value)
        XCTAssertNil(fixture.server.completedEvidence(for: oldMedia),
                     "旧 media 跨过 horizon 后必须从 store 信任域退休")
        for key in [newInit, newMedia] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let newMap = try XCTUnwrap(fixture.task19.store.decodeCoverageMap(for: newMedia))
        let newEnd = try XCTUnwrap(newMap.samples.last).presentationRange.end
        let spanning = try FMP4PresentationRange(start: oldRange.start,
            duration: newEnd.subtracting(oldRange.start))
        XCTAssertNil(try fixture.server.coverageReceipt(for: context, adding: spanning),
                     "每次签发必须在 store 域复验全部既有 dependency，不能携带退休旧代")
    }

    func testLifecycleRequiresMatchingTicketDrainAndLoggerMayReenterWithoutDeadlock() async throws {
        let serverBox = LockedOptionalServer()
        let callbacks = LockedInts()
        let fixture = try await Task20HTTPFixture.start(logger: { _ in
            callbacks.append(1)
            _ = serverBox.value?.lifecyclePhase
        })
        serverBox.value = fixture.server
        let other = try await Task20HTTPFixture.start()
        defer { other.shutdown() }
        let wrongTicket = other.server.closeAdmission()
        XCTAssertThrowsError(try fixture.server.drain(cleanupTicket: wrongTicket))
        XCTAssertThrowsError(try fixture.server.retire(cleanupTicket: wrongTicket))

        let ticket = fixture.server.closeAdmission()
        XCTAssertEqual(fixture.server.lifecyclePhase, .closed)
        try fixture.server.drain(cleanupTicket: ticket)
        XCTAssertEqual(fixture.server.lifecyclePhase, .drained)
        try fixture.server.retire(cleanupTicket: ticket)
        XCTAssertEqual(fixture.server.lifecyclePhase, .retired)
        XCTAssertFalse(callbacks.values.isEmpty)
    }

    func testFinalAACParticipantsRequireExactTerminalAndTimelineSetsBeforeServerVisibility()
        async throws {
        enum Mutation: CaseIterable {
            case missing
            case extra
            case crossedLifecycle
        }

        let crossedSeed = try await Task21RealAACSeed.make(
            itemGeneration: 20,
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 51_099))
        for (index, mutation) in Mutation.allCases.enumerated() {
            let seed = try await Task21RealAACSeed.make(
                itemGeneration: 20,
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                    outputNonce: UInt64(51_100 + index)))
            let publicationBox = FinalReplacementLockedHarness()
            var unexpectedlyVisible: LoopbackHTTPServer?
            do {
                unexpectedlyVisible = try await LoopbackHTTPSessionFactory().start(
                    itemGeneration: 20, now: { 0 }, logger: { _ in },
                    responseFailure: { _, _ in }
                ) { token in
                    let publication = try FinalReplacementPublicationHarness(
                        loopbackSession: token, seed: seed)
                    publicationBox.value = publication
                    let visible = try XCTUnwrap(publication.publisher.visible)
                    var terminalBindings = visible.aacTerminalBindings
                    var timelineMappings = visible.aacTimelineMappings
                    switch mutation {
                    case .missing:
                        terminalBindings.removeAll()
                        timelineMappings.removeAll()
                    case .extra:
                        terminalBindings[99] = try XCTUnwrap(
                            visible.aacTerminalBindings[2])
                        timelineMappings[99] = try XCTUnwrap(
                            visible.aacTimelineMappings[2])
                    case .crossedLifecycle:
                        terminalBindings[2] = crossedSeed.endpointAuthority.terminalBinding
                        timelineMappings[2] = try XCTUnwrap(
                            crossedSeed.endpointAuthority.terminalBinding.timelineMappingReceipt)
                    }
                    let invalid = HLSPublishedSnapshot(
                        publisherIdentity: visible.publisherIdentity,
                        publicationSequence: visible.publicationSequence,
                        participantVector: visible.participantVector,
                        master: visible.master,
                        media: visible.media,
                        coverage: visible.coverage,
                        aacTerminalBindings: terminalBindings,
                        aacTimelineMappings: timelineMappings)
                    return LoopbackPreparedPublication(
                        store: publication.store,
                        declaration: publication.declaration,
                        snapshot: invalid)
                }
                XCTFail("\(mutation)：AAC participant 的 binding/mapping 集合不精确时不得暴露 server")
            } catch {
                XCTAssertEqual(error as? LoopbackHTTPServerError,
                               .invalidConfiguration)
            }
            if let server = unexpectedlyVisible {
                let ticket = server.closeAdmission()
                try? server.drain(cleanupTicket: ticket)
                try? server.retire(cleanupTicket: ticket)
            }
            XCTAssertTrue(try XCTUnwrap(publicationBox.value).store.isClosed)
        }
    }

    func testFinalAC3AuthorityRejectsSameGenerationAcrossOutputLifecycle() async throws {
        try await assertCompressedAuthorityRejectsCrossedLifecycle(codec: .ac3,
                                                                   nonce: 51_150)
    }

    func testFinalEAC3AuthorityRejectsSameGenerationAcrossOutputLifecycle() async throws {
        try await assertCompressedAuthorityRejectsCrossedLifecycle(codec: .eac3,
                                                                   nonce: 51_160)
    }

    func testFinalTimelineFailureIngressTerminatesOnceForCloseRetireAndPublicationFailure()
        async throws {
        let closeLifecycle = AudioServiceLeaseTestHarness.makeLifecycle(
            outputNonce: 51_200)
        let closeFixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: closeLifecycle)
        let closeTicket = closeFixture.server.closeAdmission()
        try closeFixture.server.drain(cleanupTicket: closeTicket)
        try closeFixture.server.retire(cleanupTicket: closeTicket)
        do {
            _ = try await closeFixture.evidenceSource.consumePlayerItemTimelineMapping(
                endpointAuthority: nil,
                itemURL: closeFixture.itemURL,
                item: .init(outputLifecycleEpoch: closeLifecycle, itemGeneration: 20),
                publicationSequence: closeFixture.publicationSequence,
                selection: nil)
            XCTFail("close→retire 必须结束 evidence source 的固定 timeline 槽")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .insufficientCoverage)
        }

        let responseFailures = LockedEvidenceFailures()
        let failureLifecycle = AudioServiceLeaseTestHarness.makeLifecycle(
            outputNonce: 51_201)
        let failureFixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: failureLifecycle,
            responseFailure: { key, error in
                responseFailures.append((key, error))
            })
        defer { failureFixture.shutdown() }
        let snapshot = try XCTUnwrap(failureFixture.publication.publisher.visible)
        let mediaPlaylistPath = try failureFixture.publication.declaration
            .playlistURI(participantID: 2)
        XCTAssertEqual(try rawRequest(port: failureFixture.server.port,
            target: mediaPlaylistPath).status, 200)
        let key = try XCTUnwrap(snapshot.media[2]?.resources.first)
        let path = try failureFixture.server.path(for: key)
        async let pendingTimeline = failureFixture.evidenceSource
            .consumePlayerItemTimelineMapping(
                endpointAuthority: nil,
                itemURL: failureFixture.itemURL,
                item: .init(outputLifecycleEpoch: failureLifecycle, itemGeneration: 20),
                publicationSequence: failureFixture.publicationSequence,
                selection: nil)
        let sizingLease = try XCTUnwrap(
            failureFixture.publication.store.acquireResponse(
                key, token: failureFixture.server.sessionToken, now: 0))
        let residentByteCount = sizingLease.withUnsafeBytes { $0.count }
        failureFixture.publication.store.release(sizingLease, now: 0)
        XCTAssertGreaterThanOrEqual(residentByteCount, 65)
        for offset in 0..<64 {
            XCTAssertEqual(try rawRequest(port: failureFixture.server.port,
                target: path,
                headers: ["Range": "bytes=\(offset)-\(offset)"]).status, 206)
        }
        XCTAssertEqual(try rawRequest(port: failureFixture.server.port,
            target: path).status, 200)
        XCTAssertTrue(waitUntil { !responseFailures.values.isEmpty })
        do {
            _ = try await pendingTimeline
            XCTFail("publication send terminal 失败必须结束 pending timeline")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .insufficientCoverage)
        }
        XCTAssertEqual(try rawRequest(port: failureFixture.server.port,
            target: path).status, 200)
        do {
            _ = try await failureFixture.evidenceSource.consumePlayerItemTimelineMapping(
                endpointAuthority: nil,
                itemURL: failureFixture.itemURL,
                item: .init(outputLifecycleEpoch: failureLifecycle, itemGeneration: 20),
                publicationSequence: snapshot.publicationSequence,
                selection: nil)
            XCTFail("首个 publication failure 必须保持为单一粘性终态")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .insufficientCoverage)
        }
    }

    func testFinalRetireReleasesCoverageAndEveryServerOwnedLedgerReservation() async throws {
        let shared = HLSDeliveryApplicationChargeLedger.shared
        let baseline = shared.chargedBytes
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 51_300))
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)
        let playlist = try XCTUnwrap(snapshot.media[2])
        let declaration = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: declaration.playlistURI(participantID: 2)).status, 200)
        for key in playlist.initializationResources + playlist.resources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let mediaKey = try XCTUnwrap(playlist.resources.first)
        let map = try XCTUnwrap(
            fixture.publication.store.decodeCoverageMap(for: mediaKey))
        let requested = try XCTUnwrap(map.samples.first).presentationRange
        let capability = try XCTUnwrap(fixture.server.completedPublicationCapability(
            itemURL: fixture.itemURL, itemGeneration: 20,
            publicationSequence: snapshot.publicationSequence))
        let publicationEvidence = try XCTUnwrap(
            fixture.server.consumeCompletedPublicationCapability(capability))
        let selection = try XCTUnwrap(publicationEvidence.audioSelectionCapability)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 51_300),
            itemGeneration: 20)
        let timeline: PlayerItemTimelineMappingAuthority
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: fixture.publication.endpointAuthority,
            completedPublication: publicationEvidence,
            itemURL: fixture.itemURL,
            item: item,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: selection) {
        case .ready(let value):
            timeline = value
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let prepared = PreparedPlayheadIdentity(
            outputLifecycleEpoch: item.outputLifecycleEpoch,
            itemGeneration: 20,
            publicationSequence: snapshot.publicationSequence,
            mediaTime: timeline.effectiveSourceOrigin,
            playerItemTime: try timeline.playerItemTime(
                for: timeline.effectiveSourceOrigin),
            seekNonce: 51_301,
            renditionSelectionSlotNonce: 51_302,
            audioSelectionCapability: selection,
            timelineMappingAuthority: timeline)
        let observed = ObservedRenditionSetReceipt(
            preparedPlayheadIdentity: prepared,
            selectionFenceRevision: 51_303,
            orderedRenditionIdentities: [.init(rawValue: 2)])
        let context = LoopbackCoverageContext(
            preparedPlayheadIdentity: prepared,
            observedRenditionSetReceipt: observed,
            renditionIdentity: .init(rawValue: 2))
        _ = try fixture.server.coverageReceipt(for: context, adding: requested)
        XCTAssertEqual(fixture.publication.store.coverageContextCount, 1)
        XCTAssertEqual(
            fixture.publication.store.coverageApplicationChargeSnapshot.chargedBytes,
            LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes)

        let ticket = fixture.server.closeAdmission()
        XCTAssertTrue(waitUntil {
            fixture.server.usage.connections == 0
                && fixture.server.usage.activeResponses == 0
        })
        try fixture.server.drain(cleanupTicket: ticket)
        try fixture.server.retire(cleanupTicket: ticket)

        let usage = fixture.server.usage
        XCTAssertEqual(usage.connections, 0)
        XCTAssertEqual(usage.activeResponses, 0)
        XCTAssertEqual(usage.distinctBackingBytes, 0)
        XCTAssertEqual(usage.parserAndStagingBytes, 0,
                       "retire 必须在 server queue 清掉 coverageContext 的 64 KiB 统计")
        XCTAssertEqual(fixture.publication.store.coverageContextCount, 0)
        XCTAssertEqual(
            fixture.publication.store.coverageApplicationChargeSnapshot.chargedBytes, 0)
        XCTAssertEqual(fixture.publication.store.usage.responseBackingBytes, 0)
        XCTAssertEqual(fixture.publication.store.usage.residentBytes, 0)
        XCTAssertEqual(fixture.publication.store.usage.reservedBytes, 0)
        XCTAssertEqual(shared.chargedBytes, baseline)
    }

    func testStartupCancellationClosesPreparedStoreAndCloseRejectsNewAccepts() async throws {
        let entered = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let harnessBox = LockedHarness()
        let task = Task {
            try await LoopbackHTTPSessionFactory().start(itemGeneration: 19, now: { 0 },
                logger: { _ in }, responseFailure: { _, _ in }) { capability in
                let harness = try Task19Harness(loopbackSession: capability)
                try harness.initial()
                harnessBox.value = harness
                entered.signal()
                _ = released.wait(timeout: .now() + 2)
                var declaration = try Task19.declaration()
                declaration.token = capability.value
                return LoopbackPreparedPublication(store: harness.store, declaration: declaration,
                    snapshot: try XCTUnwrap(harness.publisher.visible))
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        released.signal()
        do {
            _ = try await task.value
            XCTFail("prepare 后取消必须由统一 startup owner 封闭失败")
        } catch is CancellationError {}
        XCTAssertTrue(try XCTUnwrap(harnessBox.value).store.isClosed)

        let fixture = try await Task20HTTPFixture.start()
        let key = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)
        let path = try fixture.server.path(for: key)
        let ticket = fixture.server.closeAdmission()
        var sockets: [ConnectedSocket] = []
        for _ in 0..<8 { if let socket = try? ConnectedSocket(port: fixture.server.port) { sockets.append(socket) } }
        defer { sockets.removeAll(); try? fixture.server.drain(cleanupTicket: ticket); try? fixture.server.retire(cleanupTicket: ticket) }
        XCTAssertTrue(waitUntil { fixture.server.usage.connections == 0 })
        XCTAssertLessThanOrEqual(fixture.server.usage.maximumConnections, 16,
                                 "closed accept 仍须共用生产 hard gate")
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: path.replacingOccurrences(of: path.split(separator: "/").last.map(String.init) ?? "",
                                               with: "999999.m4s")).status, 404)
    }

    func testKernelSocketEvidenceIsIPv4LoopbackAndMatchesEveryAcceptedPeer() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let binding = fixture.server.socketBindingEvidence
        XCTAssertEqual(binding.family, Int32(AF_INET))
        XCTAssertEqual(binding.address, "127.0.0.1")
        XCTAssertEqual(binding.port, fixture.server.port)
        XCTAssertTrue(binding.requiredEndpointWasAudited)
        XCTAssertTrue(binding.ipv6LoopbackWasRejected)
        XCTAssertGreaterThan(binding.rejectedNonLoopbackIPv4Count, 0)
        for address in Self.nonLoopbackIPv4Addresses() {
            XCTAssertFalse(Self.canConnectIPv4(address, port: fixture.server.port),
                           "实际 listener 不得在 LAN 地址 \(address) 接受连接")
        }
        XCTAssertFalse(Self.canConnectIPv6(port: fixture.server.port),
                       "实际 listener 不得在 ::1 接受连接")
        let socket = try ConnectedSocket(port: fixture.server.port)
        let endpoints = try socket.kernelEndpoints()
        XCTAssertEqual(endpoints.peerFamily, Int32(AF_INET))
        XCTAssertEqual(endpoints.peerAddress, "127.0.0.1")
        XCTAssertEqual(endpoints.peerPort, fixture.server.port)
        XCTAssertEqual(endpoints.localFamily, Int32(AF_INET))
        XCTAssertEqual(endpoints.localAddress, "127.0.0.1")
    }

    func testUnexpectedListenerCancellationDrainsLateConnectionsAndRetiresStore() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                holdAcceptedConnectionsUntilRuntimeFailure: true)
            let fixture = try await Task20HTTPFixture.start(testing: configuration)
            var sockets: [ConnectedSocket] = []
            for _ in 0..<4 { sockets.append(try ConnectedSocket(port: fixture.server.port)) }
            XCTAssertTrue(waitUntil { fixture.server.usage.connections >= 4 })
            fixture.server.cancelListenerForTesting(capability)
            sockets.removeAll()
            XCTAssertTrue(waitUntil { fixture.server.lifecyclePhase == .retired })
            XCTAssertTrue(fixture.task19.store.isClosed)
            XCTAssertEqual(fixture.server.usage.connections, 0)
            XCTAssertEqual(fixture.server.usage.activeResponses, 0)
        }
    }

    func testAudioInitAndMediaUseAudioMIMEForGETAndHEAD() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let playlist = try XCTUnwrap(fixture.task19.publisher.visible?.media[2])
        let initPath = try fixture.server.path(for: XCTUnwrap(playlist.initializationResources.first))
        let mediaPath = try fixture.server.path(for: XCTUnwrap(playlist.resources.first))
        for method in ["GET", "HEAD"] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port, method: method,
                target: initPath).headers["content-type"], "audio/mp4")
            XCTAssertEqual(try rawRequest(port: fixture.server.port, method: method,
                target: mediaPath).headers["content-type"], "audio/iso.segment")
        }
    }

    func testMediaBeforeInitIsRetrofittedAtomicallyAndInitCapIncludesEvidenceAllocation() throws {
        let track = try Task19Track(id: 1, mediaType: .video)
        let packet = try track.next()
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        let mediaReservation = try store.reserveMedia(binding: packet.object.binding,
            kind: .media, bodyBytes: packet.object.bytes.count)
        let mediaKey = try store.admit(packet.object, proof: track.proof,
            receipt: packet.receipt, relay: packet.relay, reservation: mediaReservation)
        XCTAssertNil(store.decodeCoverageMap(for: mediaKey),
                     "init 到达前不能暴露未绑定的 coverage map")
        let initReservation = try store.reserveMedia(binding: track.binding,
            kind: .initialization, bodyBytes: track.initialization.bytes.count)
        let initKey = try store.admit(track.initialization, proof: track.proof,
            receipt: nil, relay: track.relay, reservation: initReservation)
        XCTAssertNotNil(store.decodeCoverageMap(for: mediaKey),
                        "init 接管必须在 store 同域内原子补签早到媒体")
        XCTAssertEqual(store.usage.resourceCount, 2)
        XCTAssertEqual(initKey.kind, .initialization)

        let layout = LoopbackStorageLayout.current
        XCTAssertEqual(layout.decodeSampleStride, MemoryLayout<SealedDecodeSampleEntry>.stride)
        XCTAssertEqual(layout.initMaximumBodyBytes + layout.initEvidenceAllocationBytes, 64 * 1_024)
        XCTAssertEqual(layout.stagingPayloadBytes, 64 * 1_024)
        XCTAssertGreaterThanOrEqual(layout.stagingAllocationBytes, layout.stagingPayloadBytes)
        XCTAssertThrowsError(try store.reserveMedia(binding: track.binding,
            kind: .initialization, bodyBytes: 64 * 1_024)) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }
        let legal = try store.reserveMedia(binding: track.binding, kind: .initialization,
            bodyBytes: layout.initMaximumBodyBytes)
        store.cancel(legal)
    }

    func testFormalInitializationBatchRetrofitsEveryPendingMediaInOneTransaction() throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
            epochStart: .zero, videoMode: .passthrough))
        let video = try Task19Track(id: 1, mediaType: .video, boundary: boundary)
        let audio = try Task19Track(id: 2, mediaType: .audio, boundary: boundary)
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        var mediaKeys: [HLSResourceKey] = []
        for track in [video, audio] {
            let packet = try track.next()
            let reservation = try store.reserveMedia(binding: packet.object.binding,
                kind: .media, bodyBytes: packet.object.bytes.count)
            mediaKeys.append(try store.admit(packet.object, proof: track.proof,
                receipt: packet.receipt, relay: packet.relay, reservation: reservation))
        }
        XCTAssertTrue(mediaKeys.allSatisfy { store.decodeCoverageMap(for: $0) == nil })
        let inputs = [video, audio].map {
            HLSInitialParticipant(initialization: $0.initialization, proof: $0.proof,
                relay: $0.relay, candidateTicket: nil)
        }
        let videoFormat = try XCTUnwrap(video.initialization.publicationEvidence).format
        var declaration = try Task19.declaration()
        declaration.video!.width = videoFormat.width
        declaration.video!.height = videoFormat.height
        declaration.video!.codec = videoFormat.codec
        declaration.video!.frameRateMilli = 24_000
        _ = try HLSPublicationCoordinator(store: store, participants: inputs,
            declaration: declaration,
            anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0))
        XCTAssertTrue(mediaKeys.allSatisfy { store.decodeCoverageMap(for: $0) != nil },
                      "正式 init batch 必须与单对象入口共用原子 retrofit")
        XCTAssertEqual(store.usage.resourceCount, 4)
        store.close()
    }

    func testSixtyFifthNetworkCompletionPropagatesCapacityFailureToPrepareOwner() async throws {
        let failures = LockedEvidenceFailures()
        let fixture = try await Task20HTTPFixture.start(responseFailure: { key, error in
            failures.append((key, error))
        })
        defer { fixture.shutdown() }
        let key = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)
        let path = try fixture.server.path(for: key)
        let byteCount = try fixture.resourceBytes(key).count
        XCTAssertGreaterThanOrEqual(byteCount, 65)
        for offset in 0..<64 {
            XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path,
                headers: ["Range": "bytes=\(offset)-\(offset)"]).status, 206)
        }
        XCTAssertEqual(fixture.server.completedEvidence(for: key)?.uniqueResponseCount, 64)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path).status, 200)
        XCTAssertTrue(waitUntil { !failures.values.isEmpty })
        XCTAssertEqual(failures.values.first?.0, key)
        XCTAssertEqual(failures.values.first?.1, .capacityExceeded)
        XCTAssertEqual(fixture.server.completedEvidence(for: key)?.evidence, .capacityExceeded)
        XCTAssertEqual(fixture.task19.store.usage.responseBackingBytes, 0)
    }

    func testRealSocketReservationsNeverCrossHardLimitsAndApplySoftBackpressure() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        var sockets: [ConnectedSocket] = []
        defer { sockets.removeAll() }
        for _ in 0..<20 { if let socket = try? ConnectedSocket(port: fixture.server.port) { sockets.append(socket) } }
        XCTAssertTrue(waitUntil { fixture.server.usage.maximumConnections >= 12 })
        let usage = fixture.server.usage
        XCTAssertLessThanOrEqual(usage.maximumConnections, 16)
        XCTAssertLessThanOrEqual(usage.maximumActiveResponses, 8)
        XCTAssertLessThanOrEqual(usage.maximumDistinctBackingBytes, 128 * 1_048_576)
        XCTAssertLessThanOrEqual(usage.maximumParserAndStagingBytes,
                                 LoopbackStorageLayout.current.httpHardTemporaryBytes)
        XCTAssertGreaterThanOrEqual(usage.softBackpressureCount, 1)
        XCTAssertEqual(fixture.task19.store.usage.responseBackingBytes, 0,
                       "仅建立 socket 不能先取得媒体 lease")

        sockets.removeAll()
        XCTAssertTrue(waitUntil { fixture.server.usage.connections == 0 })
        let key = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: key)).status, 200)
        let afterSend = fixture.server.usage
        XCTAssertGreaterThanOrEqual(afterSend.maximumOwnedStagingAllocationBytes,
                                    LoopbackStorageLayout.current.stagingAllocationBytes)
        XCTAssertEqual(afterSend.borrowedAsynchronousSendCount, 0,
                       "异步 send 不得保留跨 withUnsafeBytes 的借用地址")
        XCTAssertLessThanOrEqual(afterSend.maximumReservedApplicationBytes,
                                 LoopbackStorageLayout.current.serverHardApplicationBytes)
    }

    func testRealReservationLedgerDeduplicatesBackingAndRejectsSoftHardBeforeAllocation() throws {
        let ledger = LoopbackHTTPReservationLedger()
        let belowSoft = SealedMediaBacking(copying: try XCTUnwrap(
            NSMutableData(length: 96 * 1_048_576 - 1)))
        let first = try XCTUnwrap(ledger.reserve(backing: belowSoft))
        let shared = try XCTUnwrap(ledger.reserve(backing: belowSoft))
        XCTAssertEqual(ledger.usage.distinctBackingBytes, belowSoft.bytes.count)
        XCTAssertEqual(ledger.usage.distinctBackingCount, 1)
        XCTAssertEqual(ledger.usage.backingReferenceCount, 2)

        let oneByte = SealedMediaBacking(copying: NSData(data: Data([1])))
        XCTAssertNil(try ledger.reserve(backing: oneByte), "达到 96 MiB 必须在取得 backing 副作用前背压")
        XCTAssertEqual(ledger.usage.distinctBackingBytes, belowSoft.bytes.count)
        ledger.release(shared)
        ledger.release(first)
        XCTAssertEqual(ledger.usage.distinctBackingBytes, 0)

        let aboveHard = SealedMediaBacking(copying: try XCTUnwrap(
            NSMutableData(length: 128 * 1_048_576 + 1)))
        XCTAssertThrowsError(try ledger.reserve(backing: aboveHard)) {
            XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }
        XCTAssertEqual(ledger.usage.distinctBackingBytes, 0)
        XCTAssertEqual(ledger.usage.backingReferenceCount, 0)
    }

    func testResetDuringBodySendDoesNotCommitEvidenceAndReleasesLease() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let key = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)
        let socket = try ConnectedSocket(port: fixture.server.port)
        try socket.sendAndReset("GET \(fixture.server.path(for: key)) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.server.port)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(waitUntil { fixture.task19.store.usage.responseBackingBytes == 0 })
        XCTAssertEqual(fixture.server.completedEvidence(for: key)?.evidence,
                       CompletedBodyEvidence.none)
    }

    func testCapacityProjectionCoversEverySoftHardBoundaryWithoutOvercommit() {
        let limits = LoopbackHTTPLimits.standard
        let layout = LoopbackStorageLayout.current
        let cases: [(LoopbackHTTPUsage, LoopbackCapacityState)] = [
            (.init(connections: 11, activeResponses: 5, distinctBackingBytes: 96 * 1_048_576 - 1,
                   parserAndStagingBytes: layout.httpSoftTemporaryBytes - 1), .normal),
            (.init(connections: 12, activeResponses: 6, distinctBackingBytes: 96 * 1_048_576,
                   parserAndStagingBytes: layout.httpSoftTemporaryBytes), .backpressure),
            (.init(connections: 16, activeResponses: 8, distinctBackingBytes: 128 * 1_048_576,
                   parserAndStagingBytes: layout.httpHardTemporaryBytes), .backpressure),
            (.init(connections: 17, activeResponses: 8, distinctBackingBytes: 128 * 1_048_576,
                   parserAndStagingBytes: layout.httpHardTemporaryBytes), .hardExceeded),
            (.init(connections: 16, activeResponses: 9, distinctBackingBytes: 128 * 1_048_576,
                   parserAndStagingBytes: layout.httpHardTemporaryBytes), .hardExceeded),
            (.init(connections: 16, activeResponses: 8, distinctBackingBytes: 128 * 1_048_576 + 1,
                   parserAndStagingBytes: layout.httpHardTemporaryBytes), .hardExceeded),
            (.init(connections: 16, activeResponses: 8, distinctBackingBytes: 128 * 1_048_576,
                   parserAndStagingBytes: layout.httpHardTemporaryBytes + 1), .hardExceeded),
        ]
        for (usage, expected) in cases { XCTAssertEqual(limits.classify(usage), expected) }
    }

    func testRealLoopbackSocketServesTask19LeasesAndClosesAuthorizationRangeAndEvidenceContracts() async throws {
        let logs = LockedStrings()
        let fixture = try await Task20HTTPFixture.start(logger: { logs.append($0) })
        let task19 = fixture.task19
        let visible = try XCTUnwrap(task19.publisher.visible)
        let server = fixture.server
        defer { fixture.shutdown() }
        XCTAssertEqual(server.localHost, "127.0.0.1")
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertEqual(server.baseURL.host, "127.0.0.1")
        XCTAssertEqual(server.baseURL.port, Int(server.port))

        let master = try rawRequest(port: server.port, target: server.masterPath,
            headers: ["Accept-Encoding": "gzip"])
        XCTAssertEqual(master.status, 200)
        XCTAssertEqual(master.headers["content-type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(master.headers["cache-control"], "no-store")
        XCTAssertEqual(master.headers["vary"], "Accept-Encoding")
        XCTAssertEqual(master.headers["content-encoding"], "gzip")
        XCTAssertNotNil(master.headers["date"])
        XCTAssertEqual(try Task19.inflate(master.body), visible.master?.raw)

        let mediaSnapshot = try XCTUnwrap(visible.media[1])
        let key = try XCTUnwrap(mediaSnapshot.resources.first)
        let resourcePath = try server.path(for: key)
        let range = try rawRequest(port: server.port, target: resourcePath, headers: ["Range": "bytes=0-3"])
        XCTAssertEqual(range.status, 206)
        XCTAssertEqual(range.body.count, 4)
        XCTAssertEqual(range.headers["accept-ranges"], "bytes")
        XCTAssertTrue(range.headers["content-range"]?.hasPrefix("bytes 0-3/") == true)
        XCTAssertFalse(server.completedEvidence(for: key)?.isComplete == true)

        let head = try rawRequest(port: server.port, method: "HEAD", target: resourcePath,
            headers: ["Range": "bytes=0-0"])
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertNil(head.headers["content-range"])
        XCTAssertFalse(server.completedEvidence(for: key)?.isComplete == true)

        let full = try rawRequest(port: server.port, target: resourcePath)
        XCTAssertEqual(full.status, 200)
        XCTAssertEqual(Int(full.headers["content-length"] ?? "-1"), full.body.count)
        XCTAssertNotNil(full.headers["etag"])
        XCTAssertTrue(server.completedEvidence(for: key)?.isComplete == true)
        XCTAssertEqual(task19.store.usage.responseBackingBytes, 0)

        let multiple = try rawRequest(port: server.port, target: resourcePath,
            headers: ["Range": "bytes=0-0,999999-"])
        XCTAssertEqual(multiple.status, 200)
        let unsatisfied = try rawRequest(port: server.port, target: resourcePath,
            headers: ["Range": "bytes=999999-"])
        XCTAssertEqual(unsatisfied.status, 416)
        XCTAssertTrue(unsatisfied.headers["content-range"]?.hasPrefix("bytes */") == true)
        XCTAssertEqual(try rawRequest(port: server.port, target: resourcePath,
            headers: ["Range": "bytes=3-2"]).status, 400)

        let persistent = try PersistentHTTPClient(port: server.port)
        XCTAssertEqual(try persistent.request(target: server.masterPath).status, 200)
        XCTAssertEqual(try persistent.request(target: resourcePath).status, 200)

        let wrongToken = resourcePath.replacingOccurrences(of: fixture.token,
            with: "ffffffffffffffffffffffffffffffff")
        XCTAssertEqual(try rawRequest(port: server.port, target: wrongToken).status, 404)
        XCTAssertEqual(try rawRequest(port: server.port,
            target: "/v1/\(fixture.token)/19/999/video/999.m4s?p=1&a=00").status, 404)
        XCTAssertEqual(try rawRequest(port: server.port, method: "POST", target: server.masterPath).status, 405)
        XCTAssertEqual(try rawRequest(port: server.port, target: "http://127.0.0.1:\(server.port)\(server.masterPath)").status, 400)
        XCTAssertEqual(try rawRequest(port: server.port, target: server.masterPath,
            headers: ["Host": "localhost:\(server.port)"]).status, 400)
        for target in [server.masterPath + "?x=1", server.masterPath.replacingOccurrences(of: "/master", with: "/../master"),
                       server.masterPath.replacingOccurrences(of: "master", with: "%6daster")] {
            XCTAssertEqual(try rawRequest(port: server.port, target: target).status, 400)
        }
        for smuggling in ["Transfer-Encoding: chunked", "Content-Length: 1",
                           "Content-Length: 0\r\nContent-Length: 0", "X-A: one\r\n two"] {
            XCTAssertEqual(try rawRequest(port: server.port, target: server.masterPath,
                rawAdditionalHeaders: smuggling).status, 400)
        }

        let raceResults = LockedInts()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let status = try? Self.rawRequest(port: server.port, target: resourcePath).status {
                    raceResults.append(status)
                }
            }
            group.addTask { _ = server.closeAdmission() }
        }
        let afterClose = try rawRequest(port: server.port, target: resourcePath)
        XCTAssertEqual(afterClose.status, 410)
        XCTAssertTrue(raceResults.values.allSatisfy { $0 == 200 || $0 == 410 })
        XCTAssertEqual(task19.store.usage.responseBackingBytes, 0)
        XCTAssertFalse(logs.values.contains { $0.contains(fixture.token) || $0.contains(resourcePath) })
    }

    func testReview4FixedParserClosedAcceptAndStoreCoverageCaps() async throws {
        let fields = (0..<31).map { "X-Fixed-\($0): value-\($0)\r\n" }.joined()
        let bytes = Data(("GET /v1/a/1/video/index.m3u8 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:1234\r\n" + fields + "\r\n").utf8)
        var parser = LoopbackRequestParser()
        let request = try XCTUnwrap(parser.append(bytes))
        XCTAssertEqual(request.target, "/v1/a/1/video/index.m3u8")
        XCTAssertEqual(request.values(forHeader: "host"), ["127.0.0.1:1234"])
        XCTAssertEqual(LoopbackRequestParser.fixedHeaderFieldCapacity, 32)

        let layout = LoopbackStorageLayout.current
        XCTAssertEqual(layout.parserWireStorageBytes, 16 * 1_024)
        XCTAssertEqual(layout.parserAllocationBytes, 16 * 1_024)
        XCTAssertEqual(layout.httpSoftTemporaryBytes, 576 * 1_024)
        XCTAssertEqual(layout.httpHardTemporaryBytes, 768 * 1_024)

        let fixture = try await Task20HTTPFixture.start()
        let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
        let timeline = try makeRealTimelineEvidence(
            fixture: fixture, snapshot: snapshot, authorityParticipantID: 2)
        let requested = try FMP4PresentationRange(start: Task19.time(0),
                                                   duration: Task19.time(1))
        for index in 0..<8 {
            let context = Self.makeCoverageContext(rendition: 1,
                nonce: UInt64(20_000 + index * 10),
                timeline: timeline.authority, selectionCapability: timeline.selection)
            _ = try fixture.task19.store.coverageReceipt(for: context, adding: requested)
        }
        XCTAssertEqual(fixture.task19.store.coverageContextCount, 8)
        let coverageCharge = fixture.task19.store.coverageApplicationChargeSnapshot
        XCTAssertTrue(coverageCharge.allReservationsRegistered)
        XCTAssertEqual(coverageCharge.reservationCount, 8)
        XCTAssertEqual(coverageCharge.distinctAllocationCount, 8)
        XCTAssertEqual(coverageCharge.chargedBytes,
                       8 * layout.coverageAccumulatorAllocationBytes)
        let ninth = Self.makeCoverageContext(rendition: 1, nonce: 21_000,
            timeline: timeline.authority, selectionCapability: timeline.selection)
        let chargeAtCoverageCap = fixture.task19.store.coverageApplicationChargeSnapshot
        XCTAssertThrowsError(try fixture.task19.store.coverageReceipt(for: ninth,
                                                                       adding: requested)) {
            XCTAssertEqual($0 as? CompletedMediaEvidenceError, .capacityExceeded)
        }
        XCTAssertEqual(fixture.task19.store.coverageContextCount, 8)
        XCTAssertEqual(fixture.task19.store.coverageApplicationChargeSnapshot,
                       chargeAtCoverageCap,
                       "store 域的第九个 context 必须在预留前拒绝")

        let ticket = fixture.server.closeAdmission()
        var sockets: [ConnectedSocket] = []
        for _ in 0..<24 {
            if let socket = try? ConnectedSocket(port: fixture.server.port) { sockets.append(socket) }
        }
        XCTAssertTrue(waitUntil { fixture.server.usage.maximumConnections >= 16 })
        XCTAssertEqual(fixture.server.usage.maximumConnections, 16,
                       "closed accept 仍须经过相同的 16-connection hard gate")
        XCTAssertLessThanOrEqual(fixture.server.usage.connections, 16)
        XCTAssertLessThanOrEqual(fixture.server.usage.maximumParserAndStagingBytes,
                                 layout.httpHardTemporaryBytes)
        sockets.forEach { $0.reset() }
        sockets.removeAll()
        XCTAssertTrue(waitUntil { fixture.server.usage.connections == 0 })
        try fixture.server.drain(cleanupTicket: ticket)
        try fixture.server.retire(cleanupTicket: ticket)
    }

    func testReview4BatchRetrofitRechecksEveryObjectAndStoreHardDeltaAtomically() throws {
        let layout = LoopbackStorageLayout.current
        let evidenceBytes = SealedMediaStoreCapacityProjection.mediaEvidenceBytes
        let maximumMapBytes = 32 * 1_024 - evidenceBytes
        XCTAssertNoThrow(try SealedMediaStoreCapacityProjection.project(
            currentChargeableBytes: 688 * 1_048_576 - maximumMapBytes,
            reservedChargeableBytes: 0,
            retrofits: [.init(existingMapBytes: 0,
                              replacementMapBytes: maximumMapBytes)]))
        XCTAssertThrowsError(try SealedMediaStoreCapacityProjection.project(
            currentChargeableBytes: 0,
            reservedChargeableBytes: 0,
            retrofits: [.init(existingMapBytes: 0,
                              replacementMapBytes: maximumMapBytes + 1)])) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }
        XCTAssertThrowsError(try SealedMediaStoreCapacityProjection.project(
            currentChargeableBytes: 688 * 1_048_576 - maximumMapBytes + 1,
            reservedChargeableBytes: 0,
            retrofits: [.init(existingMapBytes: 0,
                              replacementMapBytes: maximumMapBytes)])) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }

        func measuredRealMapDelta() throws -> Int {
            let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
                epochStart: .zero, videoMode: .passthrough))
            let tracks = [
                try Task19Track(id: 1, mediaType: .video, boundary: boundary),
                try Task19Track(id: 2, mediaType: .audio, boundary: boundary),
            ]
            let packets = try tracks.map { try $0.next() }
            let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
            var mediaKeys: [HLSResourceKey] = []
            for (track, packet) in zip(tracks, packets) {
                let reservation = try store.reserveMedia(binding: packet.object.binding,
                    kind: .media, bodyBytes: packet.object.bytes.count)
                mediaKeys.append(try store.admit(packet.object, proof: track.proof,
                    receipt: packet.receipt, relay: packet.relay, reservation: reservation))
            }
            var declaration = try Task19.declaration()
            let videoFormat = try XCTUnwrap(tracks[0].initialization.publicationEvidence).format
            declaration.video!.width = videoFormat.width
            declaration.video!.height = videoFormat.height
            declaration.video!.codec = videoFormat.codec
            declaration.video!.frameRateMilli = 24_000
            _ = try HLSPublicationCoordinator(store: store,
                participants: tracks.map {
                    HLSInitialParticipant(initialization: $0.initialization, proof: $0.proof,
                        relay: $0.relay, candidateTicket: nil)
                }, declaration: declaration,
                anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0))
            let result = try mediaKeys.reduce(0) { partial, key in
                try HLSChecked.add(partial,
                    try XCTUnwrap(store.decodeCoverageMap(for: key)).applicationChargeableBytes)
            }
            store.close()
            return result
        }
        let realMapDelta = try measuredRealMapDelta()

        func runBatch(remainingAfterRetrofit: Int, shouldSucceed: Bool) throws {
            let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
                epochStart: .zero, videoMode: .passthrough))
            let video = try Task19Track(id: 1, mediaType: .video, boundary: boundary)
            let audio = try Task19Track(id: 2, mediaType: .audio, boundary: boundary)
            let tracks = [video, audio]
            let packets = try tracks.map { try $0.next() }
            let preRetrofitCharge = zip(tracks, packets).reduce(0) {
                $0 + $1.1.object.bytes.count + evidenceBytes
                    + $1.0.initialization.bytes.count
                    + layout.initEvidenceAllocationBytes
            }
            let hardLimit = preRetrofitCharge + realMapDelta + remainingAfterRetrofit
            let store = SealedMediaStore(token: Task19.token, itemGeneration: 19,
                capacityLimits: .init(hardApplicationBytes: hardLimit))
            var mediaKeys: [HLSResourceKey] = []
            for (track, packet) in zip(tracks, packets) {
                let reservation = try store.reserveMedia(binding: packet.object.binding,
                    kind: .media, bodyBytes: packet.object.bytes.count)
                mediaKeys.append(try store.admit(packet.object, proof: track.proof,
                    receipt: packet.receipt, relay: packet.relay, reservation: reservation))
            }
            let reservedBefore = store.usage.reservedBytes
            let ownershipBefore = tracks.map(\.relay.usage)
            let inputs = tracks.map {
                HLSInitialParticipant(initialization: $0.initialization, proof: $0.proof,
                    relay: $0.relay, candidateTicket: nil)
            }
            let videoFormat = try XCTUnwrap(video.initialization.publicationEvidence).format
            var declaration = try Task19.declaration()
            declaration.video!.width = videoFormat.width
            declaration.video!.height = videoFormat.height
            declaration.video!.codec = videoFormat.codec
            declaration.video!.frameRateMilli = 24_000

            if shouldSucceed {
                _ = try HLSPublicationCoordinator(store: store, participants: inputs,
                    declaration: declaration,
                    anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0))
                XCTAssertTrue(mediaKeys.allSatisfy { store.decodeCoverageMap(for: $0) != nil })
                XCTAssertEqual(store.usage.reservedBytes, 0)
            } else {
                XCTAssertThrowsError(try HLSPublicationCoordinator(store: store,
                    participants: inputs, declaration: declaration,
                    anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0))) {
                    XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
                }
                XCTAssertTrue(mediaKeys.allSatisfy { store.decodeCoverageMap(for: $0) == nil })
                XCTAssertEqual(store.usage.resourceCount, mediaKeys.count)
                XCTAssertEqual(store.usage.reservedBytes, reservedBefore)
                XCTAssertEqual(tracks.map(\.relay.usage), ownershipBefore,
                               "失败 batch 不得转移 init、media 或 reservation ownership")
            }
            store.close()
        }

        try runBatch(remainingAfterRetrofit: -1, shouldSucceed: false)
        try runBatch(remainingAfterRetrofit: 0, shouldSucceed: true)
    }

    func testReview5ParserUsesOne16KiBResidentAllocationAndAbsoluteTemporaryCaps() throws {
        let fields = (0..<31).map { "X-Review5-\($0): value-\($0)\r\n" }.joined()
        let bytes = Data(("GET /v1/token/19/video/index.m3u8 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:1234\r\n" + fields + "\r\n").utf8)
        var parser = LoopbackRequestParser()
        let split = bytes.count / 2
        XCTAssertNil(try parser.append(Data(bytes[..<split])))
        let request = try XCTUnwrap(parser.append(Data(bytes[split...])))
        XCTAssertEqual(request.target, "/v1/token/19/video/index.m3u8")
        XCTAssertEqual(request.values(forHeader: "host"), ["127.0.0.1:1234"])
        XCTAssertEqual(request.values(forHeader: "x-review5-30"), ["value-30"])

        let layout = LoopbackStorageLayout.current
        XCTAssertEqual(LoopbackRequestParser.fixedStorageBytes, 16_384)
        XCTAssertEqual(layout.parserWireStorageBytes, 16_384)
        XCTAssertEqual(layout.parserAllocationBytes, 16_384,
                       "wire 与 header 索引必须共用唯一 16 KiB resident allocation")
        XCTAssertEqual(layout.httpSoftTemporaryBytes, 589_824,
                       "HTTP temporary soft cap 是绝对 576 KiB 合同")
        XCTAssertEqual(layout.httpHardTemporaryBytes, 786_432,
                       "HTTP temporary hard cap 是绝对 768 KiB 合同")
    }

    func testReview5StoreHardLimitIsNeverRaisedAbove688MiB() throws {
        let standard = 688 * 1_048_576
        let widened = SealedMediaStoreCapacityLimits(hardApplicationBytes: .max)
        XCTAssertEqual(widened.hardApplicationBytes, standard,
                       "任何生产可达配置都不能把 store hard cap 放大到 688 MiB 以上")
        XCTAssertThrowsError(try SealedMediaStoreCapacityProjection.project(
            currentChargeableBytes: standard + 1,
            reservedChargeableBytes: 0,
            retrofits: [], hardApplicationBytes: .max)) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }

        let widenedStore = SealedMediaStore(token: Task19.token, itemGeneration: 19,
                                            capacityLimits: widened)
        defer { widenedStore.close() }
        XCTAssertThrowsError(try widenedStore.reserveMedia(binding: Task19.binding(),
            kind: .media, bodyBytes: standard - 32 * 1_024 + 1)) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }

        let narrowedBytes = 64 * 1_024
        let narrowed = SealedMediaStoreCapacityLimits(hardApplicationBytes: narrowedBytes)
        XCTAssertEqual(narrowed.hardApplicationBytes, narrowedBytes)
        let narrowedStore = SealedMediaStore(token: Task19.token, itemGeneration: 19,
                                             capacityLimits: narrowed)
        defer { narrowedStore.close() }
        let exact = try narrowedStore.reserveMedia(binding: Task19.binding(), kind: .media,
                                                    bodyBytes: narrowedBytes - 32 * 1_024)
        narrowedStore.cancel(exact)
        XCTAssertThrowsError(try narrowedStore.reserveMedia(binding: Task19.binding(),
            kind: .media, bodyBytes: narrowedBytes - 32 * 1_024 + 1)) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .capacityExceeded)
        }
    }

    func testReview5DeliverySoftAdmissionAggregatesAcrossStoresAndServers() async throws {
        let soft = HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes
        let directLedger = HLSDeliveryApplicationChargeLedger()
        let directIdentity = UUID()
        let direct = try directLedger.reserve(allocationIdentity: directIdentity, bytes: soft)
        let alias = try directLedger.reserve(allocationIdentity: directIdentity, bytes: soft)
        XCTAssertThrowsError(try directLedger.reserve(allocationIdentity: UUID(), bytes: 1)) {
            XCTAssertEqual(String(describing: $0), "backpressure",
                           "soft 达到后新 distinct allocation 必须返回明确背压 disposition")
        }
        directLedger.release(alias)
        directLedger.release(direct)
        let reopened = try directLedger.reserve(allocationIdentity: UUID(), bytes: 1)
        directLedger.release(reopened)

        let shared = HLSDeliveryApplicationChargeLedger.shared
        let firstTrack = try Task19Track(id: 1, mediaType: .audio)
        let secondTrack = try Task19Track(id: 1, mediaType: .audio)
        let firstPacket = try firstTrack.next()
        let secondPacket = try secondTrack.next()
        let firstCharge = firstPacket.object.bytes.count
            + SealedMediaStoreCapacityProjection.mediaEvidenceBytes
        let storeBaseline = shared.chargedBytes
        XCTAssertLessThan(storeBaseline + firstCharge, soft)
        let storeFiller = try shared.reserve(allocationIdentity: UUID(),
                                             bytes: soft - storeBaseline - firstCharge)
        let firstStore = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        let secondStore = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        defer {
            firstStore.close()
            secondStore.close()
            shared.release(storeFiller)
        }
        let firstReservation = try firstStore.reserveMedia(binding: firstPacket.object.binding,
            kind: .media, bodyBytes: firstPacket.object.bytes.count)
        _ = try firstStore.admit(firstPacket.object, proof: firstTrack.proof,
            receipt: firstPacket.receipt, relay: firstPacket.relay,
            reservation: firstReservation)
        XCTAssertTrue(firstStore.usage.shouldBackpressure)
        let backingAlias = try shared.reserve(
            allocationIdentity: firstPacket.object.backing.identity.rawValue,
            bytes: firstPacket.object.bytes.count)
        shared.release(backingAlias)

        let secondReservation = try secondStore.reserveMedia(binding: secondPacket.object.binding,
            kind: .media, bodyBytes: secondPacket.object.bytes.count)
        let secondOwnership = secondPacket.relay.usage
        do {
            _ = try secondStore.admit(secondPacket.object, proof: secondTrack.proof,
                receipt: secondPacket.receipt, relay: secondPacket.relay,
                reservation: secondReservation)
            XCTFail("两个 store 聚合达到 delivery soft 后不得接纳新 distinct allocation")
            return
        } catch {
            XCTAssertEqual(error as? HLSPublicationFailure, .capacityExceeded)
        }
        XCTAssertEqual(secondStore.usage.resourceCount, 0)
        XCTAssertEqual(secondStore.usage.reservedSegmentCount, 1)
        XCTAssertEqual(secondPacket.relay.usage, secondOwnership)
        firstStore.close()
        _ = try secondStore.admit(secondPacket.object, proof: secondTrack.proof,
            receipt: secondPacket.receipt, relay: secondPacket.relay,
            reservation: secondReservation)
        secondStore.close()
        shared.release(storeFiller)
        XCTAssertEqual(shared.chargedBytes, storeBaseline)

        let firstFixture = try await Task20HTTPFixture.start()
        let secondFixture = try await Task20HTTPFixture.start()
        defer {
            firstFixture.shutdown()
            secondFixture.shutdown()
        }
        XCTAssertTrue(waitUntil {
            firstFixture.server.usage.connections == 0
                && secondFixture.server.usage.connections == 0
        })
        let held = try ConnectedSocket(port: firstFixture.server.port)
        defer { held.reset() }
        XCTAssertTrue(waitUntil { firstFixture.server.usage.connections == 1 })
        let serverBaseline = shared.chargedBytes
        let parserBytes = LoopbackStorageLayout.current.parserAllocationBytes
        XCTAssertLessThan(serverBaseline + parserBytes, soft)
        let serverFiller = try shared.reserve(allocationIdentity: UUID(),
            bytes: soft - serverBaseline - parserBytes)
        defer { shared.release(serverFiller) }
        let blocked = try rawRequest(port: secondFixture.server.port,
                                     target: secondFixture.server.masterPath)
        XCTAssertEqual(blocked.status, 503,
                       "第二个 server 的新 staging allocation 必须传播为正常 HTTP 背压")
        XCTAssertTrue(waitUntil { secondFixture.server.usage.softBackpressureCount >= 1 })
        shared.release(serverFiller)
        XCTAssertEqual(try rawRequest(port: secondFixture.server.port,
                                      target: secondFixture.server.masterPath).status, 200)
    }

    func testResourceContextLedgerSharesGlobalIdentityKeepsOldTailAndRollsBackFailures() throws {
        let global = HLSDeliveryApplicationChargeLedger()
        let context = PlaybackResourceContextLedger(applicationLedger: global)
        XCTAssertEqual(PlaybackResourceContextLedger.softBytes, 96 * 1_024)
        XCTAssertEqual(PlaybackResourceContextLedger.hardBytes, 128 * 1_024)
        XCTAssertEqual(HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes,
                       981_184_512)
        XCTAssertEqual(HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
                       1_266_647_040)
        XCTAssertEqual(HLSDeliveryApplicationChargeLedger.sharedBookkeepingBytes, 2 * 1_024)
        XCTAssertEqual(PlaybackResourceContextLedger.maximumAllocationCount, 30)
        XCTAssertEqual(PlaybackResourceContextLedger.maximumReservationCount, 64)
        XCTAssertLessThanOrEqual(PlaybackResourceContextLedger.shared.bootstrapActualBytes,
                                 PlaybackResourceContextLedger.bootstrapBytes,
                                 "resource ledger/锁/固定allocation表/bootstrap token必须落在先取的2KiB escrow")

        let sharedIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let first = try context.reserve(allocationIdentity: sharedIdentity, bytes: 16 * 1_024)
        let alias = try context.reserve(allocationIdentity: sharedIdentity, bytes: 16 * 1_024)
        XCTAssertEqual(context.chargedBytes, 16 * 1_024)
        XCTAssertEqual(global.chargedBytes, 16 * 1_024)
        context.release(first)
        XCTAssertEqual(context.chargedBytes, 16 * 1_024,
                       "旧callback/owner仍持alias时不得提前归还局部或全局费用")
        context.release(alias)
        XCTAssertEqual(context.chargedBytes, 0)
        XCTAssertEqual(global.chargedBytes, 0)

        let boundedIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        var boundedAliases: [PlaybackResourceContextReservation] = []
        for _ in 0..<64 {
            boundedAliases.append(try context.reserve(
                allocationIdentity: boundedIdentity, bytes: 1))
        }
        XCTAssertThrowsError(try context.reserve(allocationIdentity: boundedIdentity, bytes: 1)) {
            XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded,
                           "第65个alias必须在新增token或Dictionary entry前失败")
        }
        context.release(boundedAliases.removeLast())
        let reusedAlias = try context.reserve(allocationIdentity: boundedIdentity, bytes: 1)
        boundedAliases.forEach(context.release)
        context.release(reusedAlias)
        XCTAssertEqual(context.chargedBytes, 0, "释放的固定token槽必须可复用且不残留费用")

        let softIdentity = PlaybackApplicationAllocationIdentity.stable(UUID())
        let atSoft = try context.reserve(
            allocationIdentity: softIdentity, bytes: PlaybackResourceContextLedger.softBytes)
        let cleanupAlias = try context.reserve(
            allocationIdentity: softIdentity, bytes: PlaybackResourceContextLedger.softBytes)
        XCTAssertEqual(context.chargedBytes, PlaybackResourceContextLedger.softBytes,
                       "soft后的同identity cleanup alias不增长底层bytes，仍须可取得固定token")
        context.release(atSoft)
        XCTAssertEqual(context.chargedBytes, PlaybackResourceContextLedger.softBytes)
        context.release(cleanupAlias)
        XCTAssertEqual(context.chargedBytes, 0)

        let atHard = try context.reserve(
            allocationIdentity: .stable(UUID()), bytes: PlaybackResourceContextLedger.hardBytes)
        XCTAssertThrowsError(try context.reserve(allocationIdentity: .stable(UUID()), bytes: 1)) {
            XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }
        XCTAssertEqual(context.chargedBytes, PlaybackResourceContextLedger.hardBytes,
                       "局部hard失败必须原子rollback")
        context.release(atHard)

        let globalFiller = try global.reserve(allocationIdentity: .stable(UUID()),
            bytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes)
        XCTAssertThrowsError(try context.reserve(allocationIdentity: .stable(UUID()), bytes: 1)) {
            XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded)
        }
        XCTAssertEqual(context.chargedBytes, 0,
                       "全局hard失败不得在resource ledger留下局部reservation")
        global.release(globalFiller)
    }

    func testOriginalServerHookAliasKeepsExactOwnerAfterSourceDeinit() async throws {
        let fixture = try await Task21CompressedLifecycleHTTPFixture.start(
            codec: .ac3, outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch)
        defer { fixture.shutdown() }
        func copyOriginalHook(_ label: String) throws -> Any {
            let child = try XCTUnwrap(Mirror(reflecting: fixture.server)
                .children.first(where: { $0.label == label }))
            return child.value
        }
        for label in ["publicationEventHandler", "completedResourceEventHandler",
                      "renditionSelectionEventHandler", "timelineFailureEventHandler"] {
            var source: LoopbackAVPlayerPreparationEvidenceSource? =
                try .make(server: fixture.server)
            weak let originalSource = source
            weak let originalOwner = source?.preparationOwner
            // 只复制生产中已安装的原handler别名；不制造替代handler，不作为字节诊断。
            var originalHook: Any? = try copyOriginalHook(label)
            source = nil
            XCTAssertNil(originalSource, "原handler不得反持source形成环：\(label)")
            XCTAssertNotNil(originalOwner, "排队/在途原handler别名仍占准确owner：\(label)")
            let successor = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
            XCTAssertThrowsError(try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server),
                                 "两个谱系尚存时第三source在hook副作用前拒绝：\(label)")
            withExtendedLifetime(originalHook) {}
            originalHook = nil
            XCTAssertNil(originalOwner, "最后原handler别名释放后归还旧准入：\(label)")
            let next = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
            withExtendedLifetime((successor, next)) {}
        }
    }

    func testFrozenPreparationRejectsThirdOwnerWhileTwoSourcesRetainTheirOwners() async throws {
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch, itemGeneration: 19)
        defer { fixture.shutdown() }
        // 直接调用真实 throwing 工厂，第三次不能安装任何 source hook。
        func makeSource() throws -> LoopbackAVPlayerPreparationEvidenceSource {
            try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        }
        let first = fixture.evidenceSource
        let second = try makeSource()
        var allocations: [UInt: Int] = [:]
        func record(_ role: String, _ pointer: UnsafeRawPointer, _ bytes: Int) {
            XCTAssertGreaterThan(bytes, 0)
            allocations[UInt(bitPattern: pointer)] = bytes
            print("TASK21_OWNER_STORAGE \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
        }
        first.inspectPreparationAllocations(record)
        second.inspectPreparationAllocations(record)
        fixture.server.inspectPreparationHistoryAllocations(record)
        print("TASK21_OWNER_STORAGE 实际初始分配=\(allocations.sorted { $0.key < $1.key }) 合计=\(allocations.values.reduce(0, +))")
        try withExtendedLifetime((first, second)) {
            XCTAssertThrowsError(try makeSource()) { error in
                XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .capacityExceeded)
            }
        }
        try await fixture.serveInitialSelection()
        allocations.removeAll()
        first.inspectPreparationAllocations(record)
        second.inspectPreparationAllocations(record)
        fixture.server.inspectPreparationHistoryAllocations(record)
        print("TASK21_OWNER_STORAGE 冻结态去重合计=\(allocations.values.reduce(0, +))")
    }

    @MainActor
    func testPreparationBasisAllowsSeekBeforeRemainingGETAndFreezesOnlyAfterLoaded() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await Task21CompressedLifecycleHTTPFixture.start(
            codec: .ac3, outputLifecycleEpoch: lifecycle)
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        defer { source.retirePreparation(); fixture.shutdown() }
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle, itemGeneration: 20)
        let bundle = try LoopbackAVPlayerPreparationBundle(evidenceSource: source, item: item,
            publicationSequence: fixture.publicationSequence)
        let driver = Review2LoopbackDriver()
        let coordinator = try AVPlayerItemCoordinator(driver: driver, evidenceSource: source)
        try coordinator.install(bundle.request)
        let playlist = try XCTUnwrap(fixture.publication.publisher.visible?.media[2])
        XCTAssertGreaterThan(playlist.resources.count, 1)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: fixture.itemURL.path).status, 200)
        for key in playlist.initializationResources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let initial = try XCTUnwrap(playlist.resources.dropLast().last)
        let terminal = try XCTUnwrap(playlist.resources.last)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: initial)).status, 200)
        XCTAssertTrue(waitUntil {
            fixture.server.currentAudioSelectionCapability(itemGeneration: 20,
                publicationSequence: fixture.publicationSequence) != nil
        })
        XCTAssertFalse(source.preparationOwner.completionIsFrozen)
        var reachedSeek = false
        driver.seekAction = {
            reachedSeek = true
            XCTAssertFalse(source.preparationOwner.completionIsFrozen,
                           "尚未 loaded 时不能发布可增长 completed 视图")
            XCTAssertFalse(fixture.server.completedEvidence(for: terminal)?.isComplete ?? false)
            for key in playlist.resources where key != initial {
                XCTAssertEqual(try self.rawRequest(port: fixture.server.port,
                    target: fixture.server.path(for: key)).status, 200)
            }
        }
        let prepared = try await coordinator.prepareCurrentItem()
        XCTAssertTrue(reachedSeek, "不足三秒 GET 时必须先推进到合法 seek，而不是等待未来 GET")
        XCTAssertEqual(prepared.item, item)
        XCTAssertTrue(source.preparationOwner.completionIsFrozen)
        XCTAssertFalse(prepared.coverageDependencies.isEmpty)
        source.inspectPreparationAllocations { role, pointer, bytes in
            print("TASK21_OWNER_STORAGE prepared \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
        }
        fixture.server.inspectPreparationHistoryAllocations { role, pointer, bytes in
            print("TASK21_OWNER_STORAGE prepared \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
        }
        let basis = try XCTUnwrap(source.preparationPublicationBasis(itemURL: fixture.itemURL,
            item: item, publicationSequence: fixture.publicationSequence))
        for _ in 0..<64 {
            switch try fixture.server.makePlayerItemTimelineMappingAuthority(endpointAuthority: nil,
                completedPublication: basis, itemURL: fixture.itemURL, item: item,
                publicationSequence: fixture.publicationSequence,
                expectedSelection: basis.audioSelectionCapability) {
            case .ready(let mapping): XCTAssertTrue(mapping === prepared.identity.timelineMappingAuthority)
            default: XCTFail("同 owner 重复 timeline 查询必须复用原 authority，不重复制造/消费")
            }
        }
        driver.seekAction = nil
    }

    func testPublishedPartialViewNeverGrowsAndSuccessorOwnerRequiresHistoryHandoff() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await Task21CompressedLifecycleHTTPFixture.start(
            codec: .ac3, outputLifecycleEpoch: lifecycle)
        let first = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        defer { first.retirePreparation(); fixture.shutdown() }
        let playlist = try XCTUnwrap(fixture.publication.publisher.visible?.media[2])
        let initial = try XCTUnwrap(playlist.resources.dropLast().last)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: fixture.itemURL.path).status, 200)
        for key in playlist.initializationResources + [initial] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let old = try XCTUnwrap(fixture.server.frozenCompletedPublication(itemURL: fixture.itemURL,
            itemGeneration: 20, publicationSequence: fixture.publicationSequence,
            preparationOwner: first.preparationOwner))
        let oldKeys = old.participants[0].completedMedia.map(\.key)
        XCTAssertEqual(oldKeys, [initial])
        try await fixture.serveCompletedPublication()
        XCTAssertEqual(old.participants[0].completedMedia.map(\.key), oldKeys)
        let second = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        defer { second.retirePreparation() }
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle, itemGeneration: 20)
        XCTAssertThrowsError(try LoopbackAVPlayerPreparationBundle(evidenceSource: second,
            item: item, publicationSequence: fixture.publicationSequence))
        first.retirePreparation()
        _ = try LoopbackAVPlayerPreparationBundle(evidenceSource: second, item: item,
            publicationSequence: fixture.publicationSequence)
        try await fixture.serveCompletedPublication()
        let successor = try XCTUnwrap(fixture.server.frozenCompletedPublication(itemURL: fixture.itemURL,
            itemGeneration: 20, publicationSequence: fixture.publicationSequence,
            preparationOwner: second.preparationOwner))
        XCTAssertGreaterThan(successor.participants[0].completedMedia.count, oldKeys.count)
        XCTAssertEqual(old.participants[0].completedMedia.map(\.key), oldKeys,
                       "历史退域/交接不能撤销旧 owner 原租约或倒灌完成事实")
    }

    func testOldPlaylistSendSuccessCannotWriteSuccessorHistoryDomain() async throws {
        try await assertOldSendSuccessCannotWriteSuccessorHistoryDomain(.playlist)
    }

    func testOldResourceSendSuccessCannotWriteSuccessorHistoryDomain() async throws {
        try await assertOldSendSuccessCannotWriteSuccessorHistoryDomain(.resource)
    }

    private enum CrossHistoryDelayedResponse {
        case playlist
        case resource
    }

    private func assertOldSendSuccessCannotWriteSuccessorHistoryDomain(
        _ response: CrossHistoryDelayedResponse
    ) async throws {
        try await LoopbackHTTPTestingCapability.withCapability { testingCapability in
            let configuration = LoopbackHTTPTestingConfiguration(
                capability: testingCapability, pauseBeforeBodySend: true)
            let fixture = try await Task20HTTPFixture.start(testing: configuration)
            var first: LoopbackAVPlayerPreparationEvidenceSource? = try .make(
                server: fixture.server)
            let firstSlot = try XCTUnwrap(first).preparationOwner.slot
            var successor: LoopbackAVPlayerPreparationEvidenceSource?
            defer {
                first?.retirePreparation()
                successor?.retirePreparation()
                fixture.shutdown()
            }
            let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
            let fenceCost = fixture.server.preparationHistoryFenceStorageCost
            XCTAssertEqual(fenceCost.generationValueBytes, 8)
            XCTAssertEqual(fenceCost.responseTokenValueBytes, 24)
            let fenceCostAttachment = XCTAttachment(string:
                "historyFence server=\(fenceCost.serverAllocationBytes), incrementalServer="
                    + "\(fenceCost.incrementalServerAllocationBytes), generation="
                    + "\(fenceCost.generationValueBytes), responseToken="
                    + "\(fenceCost.responseTokenValueBytes)")
            fenceCostAttachment.lifetime = .keepAlways
            add(fenceCostAttachment)
            let audio = try XCTUnwrap(snapshot.media[2])
            let declaration = try XCTUnwrap(snapshot.participantVector.first {
                $0.participantID == 2
            }?.declaration)

            func completePaused(_ path: String) throws {
                let client = try ConnectedSocket(port: fixture.server.port)
                try client.sendOnly(
                    "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.server.port)\r\n"
                        + "Connection: close\r\n\r\n")
                XCTAssertTrue(waitUntil { fixture.server.usage.activeResponses == 1 })
                fixture.server.resumePausedBodySends(testing: testingCapability)
                XCTAssertEqual(try client.receiveReply().status, 200)
                XCTAssertTrue(waitUntil { fixture.server.usage.activeResponses == 0 })
            }

            let delayedPath: String
            switch response {
            case .playlist:
                delayedPath = try declaration.playlistURI(participantID: 2)
            case .resource:
                try completePaused(declaration.playlistURI(participantID: 2))
                delayedPath = try fixture.server.path(for:
                    XCTUnwrap(audio.resources.last))
            }

            let oldClient = try ConnectedSocket(port: fixture.server.port)
            try oldClient.sendOnly(
                "GET \(delayedPath) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.server.port)\r\n"
                    + "Connection: close\r\n\r\n")
            XCTAssertTrue(waitUntil { fixture.server.usage.activeResponses == 1 },
                          "旧响应必须已完成admission并停在body send之前")

            first?.retirePreparation()
            first = nil
            successor = try .make(server: fixture.server)
            XCTAssertEqual(try XCTUnwrap(successor).preparationOwner.slot, firstSlot,
                           "回归必须覆盖owner slot复用，slot本身不能防ABA")
            let item = AVPlayerItemInstanceIdentity(
                outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch,
                itemGeneration: 19)
            _ = try LoopbackAVPlayerPreparationBundle(
                evidenceSource: try XCTUnwrap(successor), item: item,
                publicationSequence: snapshot.publicationSequence)
            let successorBaseline = fixture.server.preparationHistoryFactCounts
            XCTAssertEqual(successorBaseline.playlists, 0)
            XCTAssertEqual(successorBaseline.resources, 0)
            XCTAssertEqual(successorBaseline.selections, 0)

            fixture.server.resumePausedBodySends(testing: testingCapability)
            XCTAssertEqual(try oldClient.receiveReply().status, 200,
                           "history退役不改变已经admit的通用HTTP成功与lease释放")
            XCTAssertTrue(waitUntil { fixture.server.usage.activeResponses == 0 })
            let after = fixture.server.preparationHistoryFactCounts
            XCTAssertEqual(after.authorities, successorBaseline.authorities,
                           "旧playlist完成不可扩充同server后继authority history")
            XCTAssertEqual(after.participants, successorBaseline.participants,
                           "旧playlist完成不可改写同server后继participant history")
            XCTAssertEqual(after.playlists, 0,
                           "旧playlist完成不可写入同server后继history")
            XCTAssertEqual(after.resources, 0,
                           "旧resource完成不可写入同server后继history")
            XCTAssertEqual(after.selections, 0,
                           "旧audio resource完成不可为后继history签selection")
        }
    }

    func testLastFrozenMetadataLeaseKeepsOriginalStoreChargesUntilFinalAliasRelease() async throws {
        var fixture: FinalReplacementHTTPFixture? = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch, itemGeneration: 19)
        let store = try XCTUnwrap(fixture).publication.store
        try await fixture!.serveInitialSelection()
        var evidence = fixture!.server.frozenCompletedPublication(itemURL: fixture!.itemURL,
            itemGeneration: 19, publicationSequence: fixture!.publicationSequence,
            preparationOwner: fixture!.evidenceSource.preparationOwner)
        XCTAssertNotNil(evidence)
        let ownerSlot = try XCTUnwrap(evidence).preparationOwner.slot
        let before = store.preparationLeaseChargeSnapshot(ownerSlot: ownerSlot)
        XCTAssertGreaterThan(before.residentBytes, 0)
        XCTAssertTrue(before.charge.allReservationsRegistered)
        fixture!.shutdown()
        fixture = nil
        let after = store.preparationLeaseChargeSnapshot(ownerSlot: ownerSlot)
        XCTAssertEqual(store.usage.residentBytes, before.residentBytes,
                       "原 store 关闭后，外部 owner 别名必须继续保留同批 body/evidence/map 原费用")
        XCTAssertEqual(Set(after.identities), Set(before.identities))
        XCTAssertEqual(after.charge, before.charge,
                       "检查准确原 reservation 仍登记，不把无关未发布资源的正常退休当作 lease 失效")
        XCTAssertFalse(try XCTUnwrap(evidence).participants[0].completedMedia.isEmpty)
        evidence = nil
        XCTAssertEqual(store.usage.resourceCount, 0,
                       "最后冻结别名释放后才可退原租约、释放 charge 并复用 metadata 槽")
        XCTAssertEqual(store.usage.residentBytes, 0)
    }

    func testOldSelectionAliasesRetainTwoAdmissionLineagesWithoutRetainingOwnerObjects() async throws {
        func detachedSelection() async throws -> LoopbackAudioMediaSelectionCapability {
            var fixture: FinalReplacementHTTPFixture? = try await FinalReplacementHTTPFixture.start(
                outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch, itemGeneration: 19)
            try await fixture!.serveInitialSelection()
            let selection = try XCTUnwrap(fixture!.server.currentAudioSelectionCapability(
                itemGeneration: 19, publicationSequence: fixture!.publicationSequence))
            weak var owner = fixture!.evidenceSource.preparationOwner
            fixture!.shutdown()
            fixture = nil
            XCTAssertNil(owner, "selection 只持原准入slot引用，不得反持owner制造强循环")
            owner = nil
            return selection
        }
        var first: LoopbackAudioMediaSelectionCapability? = try await detachedSelection()
        var second: LoopbackAudioMediaSelectionCapability? = try await detachedSelection()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        XCTAssertThrowsError(try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)) { error in
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .capacityExceeded)
        }
        first = nil
        var successor: LoopbackAVPlayerPreparationEvidenceSource? =
            try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        XCTAssertNotNil(successor)
        successor?.retirePreparation()
        successor = nil
        second = nil
        let next = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        next.retirePreparation()
    }

    func testTwoHistoryRotationsKeepOriginalArenaAndFrozenOwnerMetadataStable() async throws {
        let fixture = try await Task20HTTPFixture.start()
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        defer { source.retirePreparation(); fixture.shutdown() }
        let initial = try XCTUnwrap(fixture.task19.publisher.visible)
        let deferred = try XCTUnwrap(initial.media[2]?.resources.last)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.masterPath).status, 200)
        for entry in initial.participantVector {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: entry.declaration.playlistURI(participantID: entry.participantID)).status, 200)
            let playlist = try XCTUnwrap(initial.media[entry.participantID])
            for key in playlist.initializationResources + playlist.resources where key != deferred {
                XCTAssertEqual(try rawRequest(port: fixture.server.port,
                    target: fixture.server.path(for: key)).status, 200)
            }
        }
        let itemURL = try XCTUnwrap(URL(string: fixture.server.masterPath,
            relativeTo: fixture.server.baseURL)?.absoluteURL)
        let basis = try XCTUnwrap(fixture.server.preparationPublicationBasis(itemURL: itemURL,
            itemGeneration: 19, publicationSequence: initial.publicationSequence,
            preparationOwner: source.preparationOwner))
        XCTAssertFalse(basis.participants.flatMap { $0.completedMedia.map(\.key) }.contains(deferred))
        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
            now: Task19.second), .published)
        let rolled = try XCTUnwrap(fixture.task19.publisher.visible)
        XCTAssertNotEqual(rolled.publicationSequence, initial.publicationSequence)
        XCTAssertTrue(try XCTUnwrap(rolled.media[2]).resources.contains(deferred))
        let audioDeclaration = try XCTUnwrap(rolled.participantVector.first { $0.participantID == 2 }).declaration
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: audioDeclaration.playlistURI(participantID: 2)).status, 200)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: deferred)).status, 200)
        XCTAssertTrue(basis.participants.flatMap { $0.completedMedia.map(\.key) }.contains(deferred),
                      "冻结前同 sealed resource/原 membership 的跨版本 GET 可以合法幂等汇合")
        let frozen = try XCTUnwrap(fixture.server.frozenCompletedPublication(itemURL: itemURL,
            itemGeneration: 19, publicationSequence: initial.publicationSequence,
            preparationOwner: source.preparationOwner))
        let keys = frozen.participants.flatMap { $0.completedMedia.map(\.key) }
        XCTAssertTrue(keys.contains(deferred))
        func arenaIdentities() -> Set<UInt> {
            var result: Set<UInt> = []
            fixture.server.inspectPreparationHistoryAllocations { role, pointer, _ in
                if role.contains("wrapper或原槽") { result.insert(UInt(bitPattern: pointer)) }
            }
            return result
        }
        let identities = arenaIdentities()
        for iteration in 2...20 {
            try fixture.task19.offerBoth(count: 1)
            XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
                now: Int64(iteration) * Task19.second), .published)
            let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
            let playlist = try XCTUnwrap(snapshot.media[2])
            let declaration = try XCTUnwrap(snapshot.participantVector.first { $0.participantID == 2 })
                .declaration
            for path in [fixture.server.masterPath, try declaration.playlistURI(participantID: 2),
                         try fixture.server.path(for: XCTUnwrap(playlist.resources.last))] {
                XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path).status, 200)
            }
            XCTAssertNotNil(fixture.server.currentAudioSelectionCapability(itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence))
            XCTAssertEqual(arenaIdentities(), identities,
                           "九槽滚动必须复用原 allocator identity，不能制造 COW 历史 backing")
            XCTAssertEqual(frozen.participants.flatMap { $0.completedMedia.map(\.key) }, keys)
        }
    }

    func testFourteenthRealSelectionFitsAndFifteenthFailsBeforeRecordAllocation() async throws {
        let failures = LockedEvidenceFailures()
        let fixture = try await Task20HTTPFixture.start(responseFailure: { failures.append(($0, $1)) })
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        defer { source.retirePreparation(); fixture.shutdown() }
        var selections: [LoopbackAudioMediaSelectionCapability] = []
        for iteration in 0..<15 {
            if iteration > 0 {
                try fixture.task19.offerBoth(count: 1)
                XCTAssertEqual(try fixture.task19.publisher.publish(ticket: fixture.task19.publisher.ticket,
                    now: Int64(iteration) * Task19.second), .published)
            }
            let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
            let playlist = try XCTUnwrap(snapshot.media[2])
            let declaration = try XCTUnwrap(snapshot.participantVector.first { $0.participantID == 2 })
                .declaration
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: declaration.playlistURI(participantID: 2)).status, 200)
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: XCTUnwrap(playlist.resources.last))).status, 200)
            let selection = fixture.server.currentAudioSelectionCapability(itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence)
            if iteration < 14 { selections.append(try XCTUnwrap(selection)) }
            else { XCTAssertNil(selection) }
        }
        XCTAssertEqual(Set(selections.map(ObjectIdentifier.init)).count, 14)
        XCTAssertEqual(failures.values.last?.1, .capacityExceeded)
        for selection in selections {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(selection).toOpaque())
            print("TASK21_OWNER_STORAGE owned/真实14 selection identity=\(UInt(bitPattern: pointer)) actual=\(malloc_size(pointer))")
        }
    }

    @MainActor
    func testTwoFourParticipantLineagesAndFourteenSelectionsKeepExactStorageRoots() async throws {
        let first = try await Task20HTTPFixture.start(audioCount: 3)
        let active = try LoopbackAVPlayerPreparationEvidenceSource.make(server: first.server)
        let second = try await Task20HTTPFixture.start(audioCount: 3)
        let dormant = try LoopbackAVPlayerPreparationEvidenceSource.make(server: second.server)
        defer { active.retirePreparation(); dormant.retirePreparation(); first.shutdown(); second.shutdown() }
        XCTAssertTrue(active.preparationOwner.isHistoryActive)
        XCTAssertFalse(dormant.preparationOwner.isHistoryActive)
        XCTAssertThrowsError(try LoopbackAVPlayerPreparationEvidenceSource.make(server: second.server))
        let initial = try XCTUnwrap(first.task19.publisher.visible)
        try serveFullPublication(initial, fixture: first, includeMaster: true)
        let itemURL = try XCTUnwrap(URL(string: first.server.masterPath,
            relativeTo: first.server.baseURL)?.absoluteURL)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch,
            itemGeneration: 19)
        let maximumLegalRequest = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: active, item: item,
            publicationSequence: initial.publicationSequence).request
        XCTAssertEqual(maximumLegalRequest.audioParticipants.count, 3,
                       "既有边界域合法最大值是三 audio，加 video 共四 participant")
        XCTAssertNil(maximumLegalRequest.audioParticipants.explicitValues,
                     "生产最大 audio 请求必须借冻结 source view，不得重建数组 backing")
        XCTAssertEqual(maximumLegalRequest.itemURL, itemURL)
        let maximumLegalCoordinator = try AVPlayerItemCoordinator(
            driver: Review2LoopbackDriver(), evidenceSource: active)
        XCTAssertNoThrow(try maximumLegalCoordinator.install(maximumLegalRequest),
                         "合法最大三 audio 与生产生成 URL 必须通过 HLS 准入")
        XCTAssertLessThanOrEqual(
            maximumLegalCoordinator.retainedGraphCapacitySnapshot.applicationChargeableBytes,
            AVPlayerRetainedGraphCapacityLedger.maximumBytes)
        XCTAssertLessThanOrEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                                 PlaybackResourceContextLedger.hardBytes,
                                 "最大合法三audio必须同时留在统一resource-context hard内")
        let frozen = try XCTUnwrap(first.server.frozenCompletedPublication(itemURL: itemURL,
            itemGeneration: 19, publicationSequence: initial.publicationSequence,
            preparationOwner: active.preparationOwner))
        let original = frozen.participants.flatMap { $0.completedMedia.map(\.key) }
        var selections = [try XCTUnwrap(frozen.audioSelectionCapability)]
        let participantID = selections[0].participantID
        for iteration in 1...13 {
            try first.task19.offerBoth(count: 1)
            XCTAssertEqual(try first.task19.publisher.publish(ticket: first.task19.publisher.ticket,
                now: Int64(iteration) * Task19.second), .published)
            let snapshot = try XCTUnwrap(first.task19.publisher.visible)
            let declaration = try XCTUnwrap(snapshot.participantVector.first {
                $0.participantID == participantID
            }).declaration
            let media = try XCTUnwrap(snapshot.media[participantID]?.resources.last)
            for path in [try declaration.playlistURI(participantID: participantID),
                         try first.server.path(for: media)] {
                XCTAssertEqual(try rawRequest(port: first.server.port, target: path).status, 200)
            }
            selections.append(try XCTUnwrap(first.server.currentAudioSelectionCapability(
                itemGeneration: 19, publicationSequence: snapshot.publicationSequence)))
        }
        XCTAssertEqual(Set(selections.map(ObjectIdentifier.init)).count, 14)
        XCTAssertEqual(frozen.participants.flatMap { $0.completedMedia.map(\.key) }, original)
        var allocations: [UInt: Int] = [:]
        func record(_ role: String, _ pointer: UnsafeRawPointer, _ bytes: Int) {
            let identity = UInt(bitPattern: pointer)
            if let old = allocations[identity] { XCTAssertEqual(old, bytes) }
            allocations[identity] = bytes
            print("TASK21_OWNER_STORAGE 两谱系14选择 \(role) identity=\(identity) actual=\(bytes)")
        }
        maximumLegalCoordinator.inspectRetainedPreparationRoots(record)
        active.inspectPreparationAllocations(record)
        dormant.inspectPreparationAllocations(record)
        first.server.inspectPreparationHistoryAllocations(record)
        second.server.inspectPreparationHistoryAllocations(record)
        for selection in selections {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(selection).toOpaque())
            record("owned/外部原 selection", pointer, malloc_size(pointer))
        }
        print("TASK21_OWNER_STORAGE 两谱系14选择部分根总计=\(allocations.values.reduce(0, +))")
    }

    func testReview1CompletedPublicationAuthorityProjectsFullSocketFactsAndConsumesOnce() async throws {
        let lifecycle = Task19.binding().outputLifecycleEpoch
        let fixture = try await FinalReplacementHTTPFixture.start(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.publication.publisher.visible)
        let participantID: UInt64 = 2
        let playlist = try XCTUnwrap(snapshot.media[participantID])
        let declaration = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == participantID
        }?.declaration)
        let mediaPlaylistPath = try declaration.playlistURI(participantID: participantID)
        let initializationKey = try XCTUnwrap(playlist.initializationResources.first)
        let mediaKey = try XCTUnwrap(playlist.resources.dropLast().last)
        let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: mediaKey))
        let requested = try XCTUnwrap(map.samples.first).presentationRange
        let itemURL = fixture.itemURL

        XCTAssertNil(fixture.server.completedPublicationCapability(
            itemURL: itemURL, itemGeneration: 19,
            publicationSequence: snapshot.publicationSequence))
        for path in [mediaPlaylistPath,
                     try fixture.server.path(for: initializationKey),
                     try fixture.server.path(for: mediaKey),
                     try fixture.server.path(for: mediaKey)] {
            XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path).status, 200)
        }

        let capability = try XCTUnwrap(fixture.server.completedPublicationCapability(
            itemURL: itemURL, itemGeneration: 19,
            publicationSequence: snapshot.publicationSequence))
        let evidence = try XCTUnwrap(
            fixture.server.consumeCompletedPublicationCapability(capability))
        XCTAssertEqual(evidence.itemURL, itemURL)
        XCTAssertEqual(evidence.itemGeneration, 19)
        XCTAssertEqual(evidence.publicationSequence, snapshot.publicationSequence)
        XCTAssertFalse(evidence.masterPlaylistCompleted,
                       "direct audio-only publication 不需要伪造 master GET")
        XCTAssertEqual(evidence.participants.filter { $0.mediaType == .audio }.map(\.renditionIdentity),
                       [.init(rawValue: participantID)])
        let participant = try XCTUnwrap(evidence.participants.first {
            $0.participantID == participantID
        })
        XCTAssertEqual(participant.renditionIdentity, .init(rawValue: participantID))
        guard case .audio = participant.mediaType else {
            return XCTFail("participant 必须保留冻结的 audio media type")
        }
        XCTAssertEqual(participant.mediaPlaylistSnapshotIdentity, playlist.identity)
        XCTAssertEqual(participant.mediaPlaylistVersion, playlist.version)
        XCTAssertTrue(participant.containsInitializationBacking(
            try XCTUnwrap(fixture.server.completedEvidence(for: initializationKey)?.resourceIdentity)))
        XCTAssertEqual(Set(participant.completedMedia.map(\.key)), [mediaKey],
                       "重复完整 GET 的 lease facts 必须归属同一 sealed resource")
        XCTAssertEqual(Set(participant.completedMedia.map(\.backingIdentity)).count, 1,
                       "重复响应不能伪造第二份 backing")
        XCTAssertEqual(participant.completedMedia.first?.key, mediaKey)
        XCTAssertEqual(participant.completedMedia.first?.backingIdentity,
                       fixture.server.completedEvidence(for: mediaKey)?.resourceIdentity)

        // endpoint authority 还要求同一 frozen playlist 的 terminal media 完整发送；
        // 第二份 completed publication 投影只增加该真实 socket fact。
        let terminalKey = try XCTUnwrap(playlist.resources.last)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: fixture.server.path(for: terminalKey)).status, 200)
        let timelineCapability = try XCTUnwrap(
            fixture.server.completedPublicationCapability(
                itemURL: itemURL, itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence))
        let timelinePublication = try XCTUnwrap(
            fixture.server.consumeCompletedPublicationCapability(timelineCapability))
        let timelineSelection = try XCTUnwrap(
            timelinePublication.audioSelectionCapability)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        let timelineAuthority: PlayerItemTimelineMappingAuthority
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: fixture.publication.endpointAuthority,
            completedPublication: timelinePublication,
            itemURL: itemURL,
            item: item,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: timelineSelection) {
        case .ready(let value): timelineAuthority = value
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let context = Self.makeCoverageContext(rendition: participantID, nonce: 31_000,
            timeline: timelineAuthority, selectionCapability: timelineSelection)
        let effectiveOffset = try timelineAuthority.writtenEffectiveBase.subtracting(
            timelineAuthority.writtenPhysicalBase)
        let effectiveRequested = try FMP4PresentationRange(
            start: requested.start.adding(effectiveOffset),
            duration: requested.duration)
        let coverage = try XCTUnwrap(fixture.server.verifiedCoverage(
            using: timelinePublication, context: context,
            requested: effectiveRequested))
        XCTAssertEqual(coverage.renditionIdentity, .init(rawValue: participantID))
        XCTAssertEqual(coverage.itemGeneration, 19)
        XCTAssertNil(fixture.server.consumeCompletedPublicationCapability(capability),
                     "opaque publication capability 必须只能消费一次")
    }

    func testReview1CompletedPublicationAuthorityRejectsPrecountHeadPartialFailureOldAndCrossServer()
        async throws {
        try await LoopbackHTTPTestingCapability.withCapability { testingCapability in
            for mutation in Task21LoopbackCompletionMutation.allCases {
                let configuration: LoopbackHTTPTestingConfiguration?
                switch mutation {
                case .acceptedBeforeTerminal:
                    configuration = LoopbackHTTPTestingConfiguration(
                        capability: testingCapability, pauseBeforeBodySend: true)
                case .failedSend:
                    configuration = LoopbackHTTPTestingConfiguration(
                        capability: testingCapability, bodyChunkBytes: 16,
                        failAfterSuccessfulBodyChunks: 1)
                case .head, .partialRange:
                    configuration = nil
                }
                let fixture = try await Task20HTTPFixture.start(testing: configuration)
                let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
                let participantID: UInt64 = 2
                let playlist = try XCTUnwrap(snapshot.media[participantID])
                let declaration = try XCTUnwrap(snapshot.participantVector.first {
                    $0.participantID == participantID
                }?.declaration)
                let itemURL = try XCTUnwrap(URL(string: fixture.server.masterPath,
                    relativeTo: fixture.server.baseURL)?.absoluteURL)
                let mediaPath = try fixture.server.path(for: XCTUnwrap(playlist.resources.first))

                XCTAssertEqual(try rawRequest(port: fixture.server.port,
                    target: fixture.server.masterPath).status, 200, "\(mutation)")
                XCTAssertEqual(try rawRequest(port: fixture.server.port,
                    target: declaration.playlistURI(participantID: participantID)).status,
                    200, "\(mutation)")
                if mutation != .acceptedBeforeTerminal {
                    XCTAssertEqual(try rawRequest(port: fixture.server.port,
                        target: fixture.server.path(for:
                            XCTUnwrap(playlist.initializationResources.first))).status,
                        200, "\(mutation)")
                }
                switch mutation {
                case .acceptedBeforeTerminal:
                    let client = try ConnectedSocket(port: fixture.server.port)
                    try client.sendOnly("GET \(mediaPath) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.server.port)\r\nConnection: close\r\n\r\n")
                    XCTAssertTrue(waitUntil {
                        fixture.server.acceptedGETSnapshot().mediaCount == 1
                    })
                    XCTAssertNil(fixture.server.completedPublicationCapability(
                        itemURL: itemURL, itemGeneration: 19,
                        publicationSequence: snapshot.publicationSequence), "\(mutation)")
                    client.reset()
                case .head:
                    XCTAssertEqual(try rawRequest(port: fixture.server.port, method: "HEAD",
                        target: mediaPath).status, 200)
                case .partialRange:
                    XCTAssertEqual(try rawRequest(port: fixture.server.port, target: mediaPath,
                        headers: ["Range": "bytes=0-0"]).status, 206)
                case .failedSend:
                    XCTAssertEqual(try rawRequest(port: fixture.server.port,
                        target: mediaPath).status, 200)
                }
                XCTAssertNil(fixture.server.completedPublicationCapability(
                    itemURL: itemURL, itemGeneration: 19,
                    publicationSequence: snapshot.publicationSequence), "\(mutation)")
                fixture.shutdown()
            }

            let first = try await Task20HTTPFixture.start()
            let second = try await Task20HTTPFixture.start()
            defer { first.shutdown(); second.shutdown() }
            let snapshot = try XCTUnwrap(first.task19.publisher.visible)
            let participantID: UInt64 = 2
            let playlist = try XCTUnwrap(snapshot.media[participantID])
            let declaration = try XCTUnwrap(snapshot.participantVector.first {
                $0.participantID == participantID
            }?.declaration)
            let itemURL = try XCTUnwrap(URL(string: first.server.masterPath,
                relativeTo: first.server.baseURL)?.absoluteURL)
            for path in [first.server.masterPath,
                         try declaration.playlistURI(participantID: participantID),
                         try first.server.path(for: XCTUnwrap(playlist.initializationResources.first)),
                         try first.server.path(for: XCTUnwrap(playlist.resources.first))] {
                XCTAssertEqual(try rawRequest(port: first.server.port, target: path).status, 200)
            }
            XCTAssertNil(first.server.completedPublicationCapability(
                itemURL: itemURL, itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence + 1),
                "旧 publicationSequence 不得取得 capability")
            let capability = try XCTUnwrap(first.server.completedPublicationCapability(
                itemURL: itemURL, itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence))
            XCTAssertNil(second.server.consumeCompletedPublicationCapability(capability),
                         "另一 server 不得消费 response authority")
            XCTAssertNotNil(first.server.consumeCompletedPublicationCapability(capability))
            XCTAssertNil(first.server.consumeCompletedPublicationCapability(capability))
        }
    }

    @MainActor
    func testReview2SuccessfulSendTerminalIngressInvalidatesActiveAuthorityAndEmitsOneReprepare()
        async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let first = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(first, fixture: fixture, includeMaster: true)
        let events = LockedInts()
        let harness = try Review2LoopbackCoordinatorHarness(fixture: fixture,
            snapshot: first, onAuthorityChange: { events.append(1) })
        try await harness.prepareAndActivate()
        XCTAssertEqual(harness.coordinator.phase, .playing)
        XCTAssertEqual(harness.driver.playCallCount, 1)

        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(
            ticket: fixture.task19.publisher.ticket, now: Task19.second), .published)
        let second = try XCTUnwrap(fixture.task19.publisher.visible)
        let audio = try XCTUnwrap(second.media[2])
        let declaration = try XCTUnwrap(second.participantVector.first {
            $0.participantID == 2
        }?.declaration)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: declaration.playlistURI(participantID: 2)).status, 200)
        let conflictingKey = try XCTUnwrap(audio.resources.last)
        let conflictingPath = try fixture.server.path(for: conflictingKey)
        for _ in 0..<80 {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                          target: conflictingPath).status, 200)
        }

        XCTAssertTrue(waitUntil {
            harness.coordinator.phase == .stopping && events.values.count == 1
        }, "真实 success terminal 必须自动撤销旧 readiness/activation")
        XCTAssertEqual(harness.coordinator.invalidationCount, 1,
                       "重复语义事实只能合并到固定槽，不能反复撤销")
        XCTAssertEqual(events.values, [1],
                       "冲突 publication 只发出一次 stop/reprepare 事件")
        XCTAssertEqual(harness.driver.playCallCount, 1,
                       "撤销后不得再次产生正 rate 副作用")
    }

    func testReview2PublicationAuthorityBindsActualServedVersionBeforeFirstGETAndAcrossHorizon()
        async throws {
        let beforeFirstGET = try await Task20HTTPFixture.start()
        defer { beforeFirstGET.shutdown() }
        try beforeFirstGET.task19.offerBoth(count: 1)
        XCTAssertEqual(try beforeFirstGET.task19.publisher.publish(
            ticket: beforeFirstGET.task19.publisher.ticket,
            now: Task19.second), .published)
        let advanced = try XCTUnwrap(beforeFirstGET.task19.publisher.visible)
        try serveFullPublication(advanced, fixture: beforeFirstGET, includeMaster: true)
        let advancedURL = try masterURL(for: beforeFirstGET)
        let advancedEvidence = try consumePublication(
            fixture: beforeFirstGET, itemURL: advancedURL, snapshot: advanced)
        for entry in advanced.participantVector {
            let served = try XCTUnwrap(advancedEvidence.participants.first {
                $0.participantID == entry.participantID
            })
            let playlist = try XCTUnwrap(advanced.media[entry.participantID])
            XCTAssertEqual(served.mediaPlaylistSnapshotIdentity, playlist.identity)
            XCTAssertEqual(served.mediaPlaylistVersion, playlist.version)
        }

        let duringPlayback = try await Task20HTTPFixture.start()
        defer { duringPlayback.shutdown() }
        let first = try XCTUnwrap(duringPlayback.task19.publisher.visible)
        try serveFullPublication(first, fixture: duringPlayback, includeMaster: true)
        let itemURL = try masterURL(for: duringPlayback)
        let firstEvidence = try consumePublication(
            fixture: duringPlayback, itemURL: itemURL, snapshot: first)
        let oldAudioKey = try XCTUnwrap(first.media[2]?.resources.first)

        try duringPlayback.task19.offerBoth(count: 1)
        XCTAssertEqual(try duringPlayback.task19.publisher.publish(
            ticket: duringPlayback.task19.publisher.ticket,
            now: Task19.second), .published)
        let second = try XCTUnwrap(duringPlayback.task19.publisher.visible)
        try serveFullPublication(second, fixture: duringPlayback, includeMaster: true)
        let secondEvidence = try consumePublication(
            fixture: duringPlayback, itemURL: itemURL, snapshot: second)
        let newAudioKey = try XCTUnwrap(second.media[2]?.resources.last)
        XCTAssertTrue(secondEvidence.participants.first(where: {
            $0.participantID == 2
        })?.completedMedia.contains(where: { $0.key == newAudioKey }) == true,
        "新窗口真实响应必须进入对应版本 authority")

        XCTAssertEqual(try rawRequest(port: duringPlayback.server.port,
            target: duringPlayback.server.path(for: oldAudioKey)).status, 200,
            "availability horizon 内旧版本 backing 必须仍由同一 server 服务")
        XCTAssertTrue(firstEvidence.participants.first(where: {
            $0.participantID == 2
        })?.completedMedia.contains(where: { $0.key == oldAudioKey }) == true,
        "旧版本 authority 必须保持其实际完成的 media fact")
        XCTAssertNotEqual(
            try XCTUnwrap(firstEvidence.participants.first { $0.participantID == 2 })
                .mediaPlaylistSnapshotIdentity,
            try XCTUnwrap(secondEvidence.participants.first { $0.participantID == 2 })
                .mediaPlaylistSnapshotIdentity)
    }

    func testReview2SixtyFourPartialResponsesUnionToReadinessButHeadFailureAndGapDoNot()
        async throws {
        let completeFailures = LockedEvidenceFailures()
        let complete = try await Task20HTTPFixture.start(responseFailure: {
            completeFailures.append(($0, $1))
        })
        var completeSource: LoopbackAVPlayerPreparationEvidenceSource? = try .make(
            server: complete.server)
        defer {
            completeSource?.retirePreparation()
            complete.shutdown()
        }
        let snapshot = try XCTUnwrap(complete.task19.publisher.visible)
        let audioPlaylist = try XCTUnwrap(snapshot.media[2])
        let declaration = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration)
        let playlistPath = try declaration.playlistURI(participantID: 2)
        let directURL = try XCTUnwrap(URL(string: playlistPath,
                                         relativeTo: complete.server.baseURL)?.absoluteURL)
        let initializationKey = try XCTUnwrap(audioPlaylist.initializationResources.first)
        let mediaKey = try XCTUnwrap(audioPlaylist.resources.first)
        XCTAssertEqual(try rawRequest(port: complete.server.port,
                                      target: playlistPath).status, 200)
        XCTAssertEqual(try rawRequest(port: complete.server.port,
                                      target: try complete.server.path(for: initializationKey)).status, 200)
        let mediaPath = try complete.server.path(for: mediaKey)
        let mediaLength = try complete.resourceBytes(mediaKey).count
        let ranges = Self.partition(0..<mediaLength, count: 64)
        XCTAssertEqual(ranges.count, 64)
        for range in ranges {
            let reply = try rawRequest(port: complete.server.port, target: mediaPath,
                headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"])
            XCTAssertEqual(reply.status, 206)
            XCTAssertEqual(reply.body.count, range.count)
        }
        XCTAssertEqual(complete.server.completedEvidence(for: mediaKey)?.uniqueResponseCount, 64)
        XCTAssertTrue(complete.server.completedEvidence(for: mediaKey)?.isComplete == true)
        let compactedFacts = complete.server.preparationHistoryFactCounts
        XCTAssertEqual(compactedFacts.authorities, 1)
        XCTAssertEqual(compactedFacts.participants, 1)
        XCTAssertEqual(compactedFacts.playlists, 1)
        XCTAssertEqual(compactedFacts.resources, 2,
                       "64段range明细归约后必须保留init与completed media各一个slot锚")
        let completedCapability = try XCTUnwrap(
            complete.server.completedPublicationCapability(
                itemURL: directURL, itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence))
        for key in audioPlaylist.resources.dropFirst() {
            XCTAssertEqual(try rawRequest(
                port: complete.server.port,
                target: try complete.server.path(for: key)).status, 200)
        }
        let publicationMembership = try XCTUnwrap(
            complete.task19.publisher.aacPublicationMembershipSnapshots[2])
        let httpMembership = try XCTUnwrap(
            complete.server.aacHTTPMembershipSnapshots[2])
        XCTAssertEqual(httpMembership.count, 6)
        XCTAssertNotEqual(httpMembership.digest, publicationMembership.digest,
                          "HTTP子集摘要必须与publisher全流有序摘要域分隔")
        let completedPublication = try XCTUnwrap(
            complete.server.consumeCompletedPublicationCapability(completedCapability))
        XCTAssertEqual(try rawRequest(port: complete.server.port,
            target: mediaPath).status, 200)
        XCTAssertEqual(complete.server.aacHTTPMembershipSnapshots[2]?.count, 6,
                       "重复完整GET不得重复累计")
        XCTAssertTrue(waitUntil { !completeFailures.values.isEmpty })
        XCTAssertEqual(completeFailures.values.last?.0, mediaKey)
        XCTAssertEqual(completeFailures.values.last?.1, .capacityExceeded,
                       "同一sealed对象第65个不同response identity必须触发硬上限")
        XCTAssertEqual(complete.server.completedEvidence(for: mediaKey)?.uniqueResponseCount, 64)
        XCTAssertEqual(complete.server.completedEvidence(for: mediaKey)?.evidence, .capacityExceeded,
                       "member去重不能清空或恢复response evidence的吸收态失败")
        XCTAssertEqual(completedPublication.publicationSequence,
                       snapshot.publicationSequence,
                       "第65个response失败不能篡改此前已签发并消费的不可变authority")
        completeSource?.retirePreparation()
        completeSource = nil
        completeSource = try .make(server: complete.server)
        let alreadyServedKey = try XCTUnwrap(audioPlaylist.resources.last)
        XCTAssertEqual(try rawRequest(
            port: complete.server.port,
            target: try complete.server.path(for: alreadyServedKey)).status, 200)
        XCTAssertEqual(complete.server.aacHTTPMembershipSnapshots[2]?.count, 6,
                       "preparation history更替不得清空server/rendition聚合或重计资源claim")
        completeSource?.retirePreparation()
        completeSource = nil

        let incomplete = try await Task20HTTPFixture.start()
        var incompleteSource: LoopbackAVPlayerPreparationEvidenceSource? = try .make(
            server: incomplete.server)
        defer {
            incompleteSource?.retirePreparation()
            incomplete.shutdown()
        }
        let incompleteSnapshot = try XCTUnwrap(incomplete.task19.publisher.visible)
        let incompletePlaylist = try XCTUnwrap(incompleteSnapshot.media[2])
        let incompleteDeclaration = try XCTUnwrap(incompleteSnapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration)
        let incompletePlaylistPath = try incompleteDeclaration.playlistURI(participantID: 2)
        let incompleteURL = try XCTUnwrap(URL(string: incompletePlaylistPath,
            relativeTo: incomplete.server.baseURL)?.absoluteURL)
        let incompleteInit = try XCTUnwrap(incompletePlaylist.initializationResources.first)
        let incompleteMedia = try XCTUnwrap(incompletePlaylist.resources.first)
        XCTAssertEqual(try rawRequest(port: incomplete.server.port,
                                      target: incompletePlaylistPath).status, 200)
        XCTAssertEqual(try rawRequest(port: incomplete.server.port,
            target: try incomplete.server.path(for: incompleteInit)).status, 200)
        let incompletePath = try incomplete.server.path(for: incompleteMedia)
        XCTAssertEqual(try rawRequest(port: incomplete.server.port, method: "HEAD",
                                      target: incompletePath).status, 200)
        let incompleteLength = try incomplete.resourceBytes(incompleteMedia).count
        for range in Self.partition(0..<incompleteLength, count: 64).dropLast() {
            XCTAssertEqual(try rawRequest(port: incomplete.server.port,
                target: incompletePath,
                headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"]).status,
                206)
        }
        XCTAssertFalse(incomplete.server.completedEvidence(for: incompleteMedia)?.isComplete == true)
        XCTAssertNil(incomplete.server.completedPublicationCapability(
            itemURL: incompleteURL, itemGeneration: 19,
            publicationSequence: incompleteSnapshot.publicationSequence),
            "HEAD 与留有 byte gap 的 206 union 都不能形成 readiness")
        incompleteSource?.retirePreparation()
        incompleteSource = nil

        try await LoopbackHTTPTestingCapability.withCapability { capability in
            let failed = try await Task20HTTPFixture.start(testing:
                LoopbackHTTPTestingConfiguration(capability: capability,
                    bodyChunkBytes: 16, failAfterSuccessfulBodyChunks: 1))
            let failedSource: LoopbackAVPlayerPreparationEvidenceSource? = try .make(
                server: failed.server)
            defer {
                failedSource?.retirePreparation()
                failed.shutdown()
            }
            let failedSnapshot = try XCTUnwrap(failed.task19.publisher.visible)
            let failedPlaylist = try XCTUnwrap(failedSnapshot.media[2])
            let failedDeclaration = try XCTUnwrap(failedSnapshot.participantVector.first {
                $0.participantID == 2
            }?.declaration)
            let failedPlaylistPath = try failedDeclaration.playlistURI(participantID: 2)
            let failedURL = try XCTUnwrap(URL(string: failedPlaylistPath,
                relativeTo: failed.server.baseURL)?.absoluteURL)
            XCTAssertEqual(try rawRequest(port: failed.server.port,
                                          target: failedPlaylistPath).status, 200)
            let failedMedia = try XCTUnwrap(failedPlaylist.resources.first)
            XCTAssertEqual(try rawRequest(port: failed.server.port,
                target: try failed.server.path(for: failedMedia)).status, 200)
            XCTAssertNil(failed.server.completedPublicationCapability(
                itemURL: failedURL, itemGeneration: 19,
                publicationSequence: failedSnapshot.publicationSequence),
                "发送失败不得贡献 union 或 readiness")
        }
    }

    func testReview4StartupAcceptsValidLoopbackWhenNoLANIPv4Exists() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                nonLoopbackIPv4AddressesOverride: [])
            let fixture = try await Task20HTTPFixture.start(testing: configuration)
            defer { fixture.shutdown() }
            let evidence = fixture.server.socketBindingEvidence
            XCTAssertEqual(evidence.family, Int32(AF_INET))
            XCTAssertEqual(evidence.address, "127.0.0.1")
            XCTAssertEqual(evidence.port, fixture.server.port)
            XCTAssertTrue(evidence.requiredEndpointWasAudited)
            XCTAssertTrue(evidence.ipv6LoopbackWasRejected)
            XCTAssertEqual(evidence.rejectedNonLoopbackIPv4Count, 0,
                           "没有 LAN IPv4 是合法环境，不是 listener 绑定失败")
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                          target: fixture.server.masterPath).status, 200)
        }
    }

    func testReview4PrivateEntropyReaderAndProductionAdmissionBoundaries() async throws {
        try await LoopbackHTTPTestingCapability.withCapability { capability in
            for (fault, produced) in [
                (LoopbackHTTPTestingConfiguration.EntropyFault.failure, 0),
                (.shortRead, 15),
            ] {
                let trace = LoopbackEntropyReadTrace()
                let prepared = LockedInts()
                let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                    entropyFault: fault, entropyReadTrace: trace)
                do {
                    _ = try await LoopbackHTTPSessionFactory(testing: configuration).start(
                        itemGeneration: 19, now: { 0 }, logger: { _ in },
                        responseFailure: { _, _ in }
                    ) { token in
                        prepared.append(1)
                        let harness = try Task19Harness(loopbackSession: token)
                        try harness.initial()
                        var declaration = try Task19.declaration()
                        declaration.token = token.value
                        return LoopbackPreparedPublication(store: harness.store,
                            declaration: declaration,
                            snapshot: try XCTUnwrap(harness.publisher.visible))
                    }
                    XCTFail("私有系统熵读取失败或短读不得签发 token")
                } catch {
                    XCTAssertEqual(error as? LoopbackHTTPServerError, .randomnessUnavailable)
                }
                XCTAssertEqual(trace.attemptCount, 1)
                XCTAssertEqual(trace.lastRequestedByteCount, 16)
                XCTAssertEqual(trace.lastProducedByteCount, produced)
                XCTAssertTrue(prepared.values.isEmpty)
            }

            let soft = HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes
            let hard = HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
            let softLedger = HLSDeliveryApplicationChargeLedger()
            let softReservation = try softLedger.reserve(allocationIdentity: UUID(),
                                                         bytes: soft - 1)
            XCTAssertFalse(softLedger.shouldBackpressure)
            let softEdge = try softLedger.reserve(allocationIdentity: UUID(), bytes: 1)
            XCTAssertTrue(softLedger.shouldBackpressure)
            softLedger.release(softEdge)
            softLedger.release(softReservation)

            let hardLedger = HLSDeliveryApplicationChargeLedger()
            let atHard = try hardLedger.reserve(allocationIdentity: UUID(), bytes: hard)
            XCTAssertEqual(hardLedger.chargedBytes, hard)
            XCTAssertThrowsError(try hardLedger.reserve(allocationIdentity: UUID(), bytes: 1)) {
                XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded)
            }
            XCTAssertEqual(hardLedger.chargedBytes, hard)
            hardLedger.release(atHard)

            let sharedLedger = HLSDeliveryApplicationChargeLedger()
            let firstServer = LoopbackHTTPReservationLedger(applicationLedger: sharedLedger,
                                                             testing: capability)
            let secondServer = LoopbackHTTPReservationLedger(applicationLedger: sharedLedger,
                                                              testing: capability)
            let sharedIdentity = SealedMediaBackingIdentity(rawValue: UUID())
            let storeOwnership = try sharedLedger.reserve(
                allocationIdentity: sharedIdentity.rawValue, bytes: 64 * 1_048_576)
            let firstHTTP = try XCTUnwrap(firstServer.reserve(identity: sharedIdentity,
                                                              bytes: 64 * 1_048_576))
            XCTAssertEqual(sharedLedger.chargedBytes, 64 * 1_048_576,
                           "sealed→HTTP 同 backing 跨层引用不得重复计费")
            sharedLedger.release(storeOwnership)
            XCTAssertEqual(sharedLedger.chargedBytes, 64 * 1_048_576,
                           "ownership transfer 中间不得把仍存活的 HTTP lease 清零")
            let secondIdentity = SealedMediaBackingIdentity(rawValue: UUID())
            let secondHTTP = try XCTUnwrap(secondServer.reserve(identity: secondIdentity,
                bytes: 64 * 1_048_576))
            XCTAssertEqual(sharedLedger.chargedBytes, 128 * 1_048_576,
                           "多个 server 必须聚合到同一 Task20 HLS delivery ledger")
            firstServer.release(firstHTTP)
            secondServer.release(secondHTTP)
            XCTAssertEqual(sharedLedger.chargedBytes, 0)

            for bytes in [128 * 1_048_576 - 1, 128 * 1_048_576] {
                let ledger = LoopbackHTTPReservationLedger(
                    applicationLedger: HLSDeliveryApplicationChargeLedger(),
                    testing: capability)
                let reservation = try XCTUnwrap(ledger.reserve(
                    identity: .init(rawValue: UUID()), bytes: bytes))
                XCTAssertEqual(ledger.usage.distinctBackingBytes, bytes)
                ledger.release(reservation)
            }
            let hardBackingLedger = LoopbackHTTPReservationLedger(
                applicationLedger: HLSDeliveryApplicationChargeLedger(), testing: capability)
            XCTAssertThrowsError(try hardBackingLedger.reserve(
                identity: .init(rawValue: UUID()), bytes: 128 * 1_048_576 + 1)) {
                XCTAssertEqual($0 as? LoopbackHTTPReservationError, .hardCapacityExceeded)
            }

            let configuration = LoopbackHTTPTestingConfiguration(capability: capability,
                permitsSoftCapacitySaturation: true, pauseBeforeBodySend: true)
            let fixture = try await Task20HTTPFixture.start(testing: configuration)
            let key = try XCTUnwrap(fixture.task19.publisher.visible?.media[1]?.resources.first)
            let path = try fixture.server.path(for: key)
            var sockets: [ConnectedSocket] = []
            for _ in 0..<9 {
                let socket = try ConnectedSocket(port: fixture.server.port)
                try socket.sendOnly("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.server.port)\r\nConnection: close\r\n\r\n")
                sockets.append(socket)
            }
            XCTAssertTrue(waitUntil { fixture.server.usage.maximumActiveResponses >= 8 })
            XCTAssertEqual(fixture.server.usage.maximumActiveResponses, 8)
            XCTAssertLessThanOrEqual(fixture.server.usage.activeResponses, 8)
            fixture.server.resumePausedBodySends(testing: capability)
            sockets.forEach { $0.reset() }
            XCTAssertTrue(waitUntil { fixture.server.usage.activeResponses == 0 })
            fixture.shutdown()
        }
    }

    private struct RealTimelineEvidence {
        let authority: PlayerItemTimelineMappingAuthority
        let selection: LoopbackAudioMediaSelectionCapability
    }

    private func makeRealTimelineEvidence(
        fixture: Task20HTTPFixture,
        snapshot: HLSPublishedSnapshot,
        authorityParticipantID: UInt64,
        lifecycle: OutputLifecycleEpoch = Task19.binding().outputLifecycleEpoch
    ) throws -> RealTimelineEvidence {
        let participant = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == authorityParticipantID
        })
        let playlist = try XCTUnwrap(snapshot.media[authorityParticipantID])
        let playlistPath = try participant.declaration.playlistURI(
            participantID: authorityParticipantID)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                      target: playlistPath).status, 200)
        for key in playlist.initializationResources + playlist.resources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let itemURL = try XCTUnwrap(URL(string: playlistPath,
                                        relativeTo: fixture.server.baseURL)?.absoluteURL)
        let publication = try consumePublication(
            fixture: fixture, itemURL: itemURL, snapshot: snapshot)
        let selection = try XCTUnwrap(publication.audioSelectionCapability)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: nil,
            completedPublication: publication,
            itemURL: itemURL,
            item: item,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: selection) {
        case .ready(let authority):
            return .init(authority: authority, selection: selection)
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    /// Task21 的 AAC coverage 测试以同一真实 writer→publisher→server 链签发
    /// timeline。只完成尾部连续三秒作为 selection/endpoint 证据，刻意保留前部
    /// media 给各测试验证 HEAD、206 union 与缺口，不能用另一台 server 的 authority。
    private func makeRealTimelineEvidence(
        fixture: FinalReplacementHTTPFixture,
        snapshot: HLSPublishedSnapshot,
        lifecycle: OutputLifecycleEpoch
    ) throws -> RealTimelineEvidence {
        let participantID: UInt64 = 2
        let participant = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == participantID
        })
        let playlist = try XCTUnwrap(snapshot.media[participantID])
        let playlistPath = try participant.declaration.playlistURI(
            participantID: participantID)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                      target: playlistPath).status, 200)
        for key in playlist.initializationResources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let terminalKey = try XCTUnwrap(playlist.resources.last)
        let terminalMap = try XCTUnwrap(
            fixture.publication.store.decodeCoverageMap(for: terminalKey)
        )
        let terminalEnd = try XCTUnwrap(terminalMap.samples.last).presentationRange.end
        var selectionKeys: [HLSResourceKey] = []
        for key in playlist.resources.reversed() {
            selectionKeys.append(key)
            let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: key))
            let start = try XCTUnwrap(map.samples.first).presentationRange.start
            if CMTimeCompare(
                start.cmTime,
                try terminalEnd.subtracting(.init(value: 3, timescale: 1)).cmTime
            ) <= 0 {
                break
            }
        }
        for key in selectionKeys.reversed() {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: fixture.server.path(for: key)).status, 200)
        }
        let capability = try XCTUnwrap(
            fixture.server.completedPublicationCapability(
                itemURL: fixture.itemURL,
                itemGeneration: fixture.itemGeneration,
                publicationSequence: snapshot.publicationSequence))
        let publication = try XCTUnwrap(
            fixture.server.consumeCompletedPublicationCapability(capability))
        let selection = try XCTUnwrap(publication.audioSelectionCapability)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: fixture.itemGeneration)
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: fixture.publication.endpointAuthority,
            completedPublication: publication,
            itemURL: fixture.itemURL,
            item: item,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: selection) {
        case .ready(let authority):
            return .init(authority: authority, selection: selection)
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    private static func makeCoverageContext(
        rendition: UInt64,
        nonce: UInt64,
        timeline: PlayerItemTimelineMappingAuthority,
        selectionCapability: LoopbackAudioMediaSelectionCapability
    )
        -> LoopbackCoverageContext {
        let playhead = PreparedPlayheadIdentity(outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch,
            itemGeneration: 19, publicationSequence: timeline.publicationSequence,
            mediaTime: timeline.effectiveSourceOrigin,
            playerItemTime: Task19.time(0),
            seekNonce: nonce, renditionSelectionSlotNonce: nonce + 1,
            audioSelectionCapability: selectionCapability,
            timelineMappingAuthority: timeline)
        let observed = ObservedRenditionSetReceipt(preparedPlayheadIdentity: playhead,
            selectionFenceRevision: nonce + 2,
            orderedRenditionIdentities: [.init(rawValue: rendition)])
        return LoopbackCoverageContext(preparedPlayheadIdentity: playhead,
            observedRenditionSetReceipt: observed,
            renditionIdentity: .init(rawValue: rendition))
    }

    private func serveFullPublication(_ snapshot: HLSPublishedSnapshot,
                                      fixture: Task20HTTPFixture,
                                      includeMaster: Bool) throws {
        if includeMaster {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                          target: fixture.server.masterPath).status, 200)
        }
        for entry in snapshot.participantVector.sorted(by: {
            $0.participantID < $1.participantID
        }) {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: entry.declaration.playlistURI(
                    participantID: entry.participantID)).status, 200)
            let playlist = try XCTUnwrap(snapshot.media[entry.participantID])
            for key in playlist.initializationResources + playlist.resources {
                XCTAssertEqual(try rawRequest(port: fixture.server.port,
                    target: fixture.server.path(for: key)).status, 200)
            }
        }
    }

    func testReview3RealLoopbackSelectionSlotClassifiesUnboundBoundConflictAndInvalidLocalResource()
        async throws {
        // classifier 的 route map 与 request 必须都来自同一 frozen server。
        // participant 2/3 保持真实 AAC writer binding，不能改声明冒充 EAC3。
        let fixture = try await Task20HTTPFixture.start(audioCount: 3)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(snapshot, fixture: fixture, includeMaster: true)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: Task19.binding().outputLifecycleEpoch,
                                                itemGeneration: 19)
        let request = try fixture.server.makeAVPlayerPreparationRequest(
            item: item, publicationSequence: snapshot.publicationSequence)
        let aPath = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration.playlistURI(participantID: 2))
        let bPath = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 3
        }?.declaration.playlistURI(participantID: 3))
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: aPath).status, 200)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: bPath).status, 200)
        let aURL = try XCTUnwrap(URL(string: aPath, relativeTo: fixture.server.baseURL)?.absoluteURL)
        let bURL = try XCTUnwrap(URL(string: bPath, relativeTo: fixture.server.baseURL)?.absoluteURL)

        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        XCTAssertEqual(source.classifyAccessLogURI(aURL,
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence, selected: nil),
                       .unrelated,
                       "未绑定 slot 的合法广告 URI 只能是 uninformative，不能抢先制造 conflict")
        XCTAssertEqual(source.classifyAccessLogURI(aURL,
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence,
            selected: .init(rawValue: 2)),
                       .matching)
        XCTAssertEqual(source.classifyAccessLogURI(bURL,
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence,
            selected: .init(rawValue: 2)),
                       .conflicting)
        let invalid = URL(string: "http://127.0.0.1:\(fixture.server.port)/v1/wrong/19/audio/2/index.m3u8")!
        XCTAssertEqual(source.classifyAccessLogURI(invalid,
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence,
            selected: .init(rawValue: 2)),
                       .invalidLocalResource)
    }

    @MainActor
    func testReview3ConflictingRenditionTerminalAutomaticallyRunsOneRegistryStopAndReprepare()
        async throws {
        let fixture = try await Task20HTTPFixture.start(audioCount: 3)
        defer { fixture.shutdown() }
        let snapshot = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(snapshot, fixture: fixture, includeMaster: true)
        let harness = try Review2LoopbackCoordinatorHarness(fixture: fixture,
            snapshot: snapshot, audioRenditions: [2, 3], useManualAuthoritySink: false,
            onAuthorityChange: {})
        try await harness.prepareAndActivate()
        XCTAssertEqual(harness.coordinator.phase, .playing)

        let b = try XCTUnwrap(snapshot.media[3])
        let declaration = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 3
        }?.declaration)
        let paths = [try declaration.playlistURI(participantID: 3)]
            + (try b.initializationResources.map(fixture.server.path(for:)))
            + (try b.resources.map(fixture.server.path(for:)))
        for _ in 0..<8 {
            for path in paths {
                XCTAssertEqual(try rawRequest(port: fixture.server.port, target: path).status, 200)
            }
        }
        XCTAssertTrue(waitUntil {
            harness.coordinator.phase == .stopping && harness.hasRegisteredSuspend
        }, "真实 B full-body terminal 必须让已绑定 A 的 slot 失权并自动进入 Registry 单飞 stop")
        XCTAssertEqual(harness.coordinator.invalidationCount, 1)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
        XCTAssertEqual(harness.driver.playCallCount, 1)
    }

    func testReview3PublicationAuthorityCASNeverRegressesAcrossLiveHorizon() async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let events = LockedInts()
        let evidence = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        evidence.installCompletedPublicationEventHandler { sequence in
            events.append(Int(sequence))
        }
        let first = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(first, fixture: fixture, includeMaster: true)
        let firstAudio = try XCTUnwrap(first.media[2]?.resources.first)

        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(
            ticket: fixture.task19.publisher.ticket, now: Task19.second), .published)
        let second = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(second, fixture: fixture, includeMaster: true)
        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(
            ticket: fixture.task19.publisher.ticket, now: Task19.second * 2), .published)
        let third = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(third, fixture: fixture, includeMaster: true)

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: try fixture.server.path(for: firstAudio)).status, 200,
            "availability horizon 内旧 backing 仍应可服务")
        XCTAssertTrue(waitUntil { events.values.count >= 3 })
        XCTAssertEqual(events.values, events.values.sorted(),
                       "旧 horizon terminal 不能让 max-CAS 从 N 回退到 N-1")
        let latest = evidence.consumeLatestCompletedPublication(itemURL: try masterURL(for: fixture),
            item: .init(outputLifecycleEpoch:
                AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_502),
                itemGeneration: 19))
        XCTAssertEqual(latest?.publicationSequence, third.publicationSequence)
    }

    func testFinalAudioMediaTerminalSignsSelectionCapabilityAndPlaylistCannotSelectOrInvalidateIt()
        async throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 42_001)
        let fixture = try await FinalReview2InitialHTTPFixture.start(
            outputLifecycleEpoch: lifecycle)
        defer { fixture.shutdown() }
        let snapshot = fixture.snapshot
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        let selections = LockedSelectionCapabilities()
        source.installRenditionSelectionEventHandler {
            selections.append($0)
        }

        let audioA = try XCTUnwrap(snapshot.media[2])
        let declarationA = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration)
        let playlistA = try declarationA.playlistURI(participantID: 2)
        let itemURL = try XCTUnwrap(URL(string: fixture.server.masterPath,
                                        relativeTo: fixture.server.baseURL)?.absoluteURL)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                      target: fixture.server.masterPath).status, 200)
        try serveParticipant(1, snapshot: snapshot, server: fixture.server)
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: playlistA).status, 200)
        XCTAssertTrue(selections.values.isEmpty,
                      "playlist send terminal 不能签 selection capability 或发布 selection 事件")
        for key in audioA.initializationResources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: try fixture.server.path(for: key)).status, 200)
        }
        let firstA = try XCTUnwrap(audioA.resources.first)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: try fixture.server.path(for: firstA)).status, 200)
        XCTAssertTrue(waitUntil {
            fixture.server.completedEvidence(for: firstA)?.isComplete == true
        }, "客户端收到 body 后仍须等待 server send-terminal ledger 入账")
        let pendingItem = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: 19)
        let incompleteSelectionPublication = try consumePublication(
            server: fixture.server, itemURL: itemURL, snapshot: snapshot)
        XCTAssertNil(incompleteSelectionPublication.audioSelectionCapability)
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: nil,
            completedPublication: incompleteSelectionPublication,
            itemURL: itemURL,
            item: pendingItem,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: nil) {
        case .waitingForSelection:
            break
        case .invalid, .ready:
            XCTFail("真实 media 尚未覆盖 E-3...E 时只能 waiting，不能 invalid 或签发 mapping")
        }
        for key in audioA.resources.dropFirst() {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: try fixture.server.path(for: key)).status, 200)
        }
        XCTAssertTrue(waitUntil {
            guard selections.values.count == 1,
                  let delivered = selections.values.first,
                  delivered.renditionIdentity == .init(rawValue: 2),
                  let current = fixture.server.currentAudioSelectionCapability(
                    itemGeneration: 19,
                    publicationSequence: snapshot.publicationSequence
                  ) else { return false }
            return delivered === current
        },
                      "只有 A 的 audio media full-body terminal 才能发布 selection 事实")

        let publication = try consumePublication(
            server: fixture.server, itemURL: itemURL, snapshot: snapshot)
        let selected = try XCTUnwrap(publication.participants.first {
            $0.renditionIdentity == .init(rawValue: 2)
        })
        let selectionCapability = try XCTUnwrap(publication.audioSelectionCapability)
        let completedMedia = try XCTUnwrap(selected.completedMedia.first {
            $0.backingIdentity == selectionCapability.backingIdentity
        })
        let map = try XCTUnwrap(
            fixture.publication.store.decodeCoverageMap(for: completedMedia.key))
        let requested = selectionCapability.overlap
        XCTAssertEqual(completedMedia.backingIdentity, map.resourceIdentity)
        XCTAssertEqual(selected.mediaPlaylistSnapshotIdentity, audioA.identity)
        XCTAssertEqual(selected.mediaPlaylistVersion, audioA.version)
        let timeline: PlayerItemTimelineMappingAuthority
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: fixture.publication.audioEndpointAuthority,
            completedPublication: publication,
            itemURL: itemURL,
            item: pendingItem,
            publicationSequence: snapshot.publicationSequence,
            expectedSelection: selectionCapability) {
        case .ready(let value):
            timeline = value
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let context = Self.makeCoverageContext(rendition: 2, nonce: 41_001,
            timeline: timeline, selectionCapability: selectionCapability)
        XCTAssertNotNil(try fixture.server.verifiedCoverage(
            using: publication, context: context, requested: requested))

        let audioB = try XCTUnwrap(snapshot.media[4])
        let declarationB = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 4
        }?.declaration)
        let playlistB = try declarationB.playlistURI(participantID: 4)
        let itemURLB = itemURL
        XCTAssertEqual(try rawRequest(port: fixture.server.port, target: playlistB).status, 200)
        XCTAssertEqual(selections.values.count, 1,
                       "B playlist terminal 只能证明 playlist，不能抢占 A selection")
        for key in audioB.initializationResources + audioB.resources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: try fixture.server.path(for: key)).status, 200)
        }
        XCTAssertTrue(waitUntil {
            guard selections.values.count == 2,
                  let delivered = selections.values.last,
                  delivered.renditionIdentity == .init(rawValue: 4),
                  let current = fixture.server.currentAudioSelectionCapability(
                    itemGeneration: 19,
                    publicationSequence: snapshot.publicationSequence
                  ) else { return false }
            return delivered === current
        },
                      "B audio media full-body terminal 必须签发新的身份化 selection")
        XCTAssertNil(try fixture.server.verifiedCoverage(
            using: publication, context: context, requested: requested),
            "PreparedPlayhead 必须复验同一 response lease/backing/publication/rendition/"
                + "overlap/nonce/digest/range capability；B terminal 后 A capability 不得继续使用")

        let currentPublication = try consumePublication(
            server: fixture.server, itemURL: itemURLB, snapshot: snapshot)
        let currentSelection = try XCTUnwrap(currentPublication.audioSelectionCapability)
        XCTAssertEqual(currentSelection.renditionIdentity, .init(rawValue: 4))
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: 19)
        func assertInvalid(_ expected: LoopbackAudioMediaSelectionCapability?,
                           _ label: String) throws {
            switch try fixture.server.makePlayerItemTimelineMappingAuthority(
                endpointAuthority: nil,
                completedPublication: currentPublication,
                itemURL: itemURLB,
                item: item,
                publicationSequence: snapshot.publicationSequence,
                expectedSelection: expected) {
            case .invalid:
                break
            case .waitingForSelection, .ready:
                XCTFail("\(label) 必须立即 invalid，不能等待或签发 mapping")
            }
        }
        try assertInvalid(nil, "server 已存在 selection 时 nil 不能作为通配符")
        try assertInvalid(selectionCapability, "同 server 已被 B 替代的 A capability 已 stale")

        let foreignFixture = try await Task20HTTPFixture.start(audioCount: 1)
        defer { foreignFixture.shutdown() }
        let foreignSnapshot = try XCTUnwrap(foreignFixture.task19.publisher.visible)
        try serveParticipant(2, snapshot: foreignSnapshot, fixture: foreignFixture)
        let foreignSelection = try XCTUnwrap(
            foreignFixture.server.currentAudioSelectionCapability(
                itemGeneration: 19,
                publicationSequence: foreignSnapshot.publicationSequence))
        try assertInvalid(foreignSelection,
                          "另一 server/session 签出的 capability 不能进入当前 mapping")
    }

    func testAudioSelectionUsesFirstCompletedThreeSecondWindowInsteadOfPlaylistLiveEdge()
        async throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 42_101)
        let fixture = try await FinalReview2InitialHTTPFixture.start(
            outputLifecycleEpoch: lifecycle)
        defer { fixture.shutdown() }
        let snapshot = fixture.snapshot
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        let audio = try XCTUnwrap(snapshot.media[2])
        let declaration = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == 2
        }?.declaration)

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
                                      target: fixture.server.masterPath).status, 200)
        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: try declaration.playlistURI(participantID: 2)).status, 200)
        for key in audio.initializationResources {
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: try fixture.server.path(for: key)).status, 200)
        }

        let firstKey = try XCTUnwrap(audio.resources.first)
        let firstMap = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: firstKey))
        let prefixStart = try XCTUnwrap(firstMap.samples.first).presentationRange.start
        let liveEnd = try XCTUnwrap(
            fixture.publication.store.decodeCoverageMap(
                for: XCTUnwrap(audio.resources.last)
            )?.samples.last
        ).presentationRange.end
        let liveWindowStart = try liveEnd.subtracting(.init(value: 3, timescale: 1))
        for key in audio.resources.reversed() {
            let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: key))
            let bytes = try fixture.resourceBytes(key)
            let ranges = Self.partition(0..<bytes.count, count: 2)
            for range in ranges {
                XCTAssertEqual(try rawRequest(port: fixture.server.port,
                    target: try fixture.server.path(for: key), headers: [
                        "Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
                    ]).status, 206)
            }
            if CMTimeCompare(try XCTUnwrap(map.samples.first).presentationRange.start.cmTime,
                             liveWindowStart.cmTime) <= 0 {
                break
            }
        }
        XCTAssertNil(fixture.server.currentAudioSelectionCapability(
            itemGeneration: 19,
            publicationSequence: snapshot.publicationSequence
        ), "range union 可以形成未来完成窗口，但不能冒充一次 full-body 选择终态")

        var prefixEnd = prefixStart
        var servedCount = 0
        for key in audio.resources {
            let map = try XCTUnwrap(fixture.publication.store.decodeCoverageMap(for: key))
            let end = try XCTUnwrap(map.samples.last).presentationRange.end
            XCTAssertEqual(try rawRequest(port: fixture.server.port,
                target: try fixture.server.path(for: key)).status, 200)
            servedCount += 1
            prefixEnd = end
            if CMTimeCompare(
                prefixEnd.cmTime,
                try prefixStart.adding(.init(value: 3, timescale: 1)).cmTime
            ) >= 0 {
                break
            }
        }
        XCTAssertLessThan(servedCount, audio.resources.count,
                          "夹具必须保留未请求的 live-edge media，才能覆盖本竞态")
        XCTAssertLessThanOrEqual(
            CMTimeCompare(prefixEnd.cmTime,
                          liveWindowStart.cmTime),
            0,
            "已请求前缀不能与旧 live-edge 三秒窗口重叠")
        XCTAssertTrue(waitUntil {
            fixture.server.currentAudioSelectionCapability(
                itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence
            ) != nil
        }, "AVPlayer 已完整请求连续三秒音频后必须形成选择，不能等待未请求的 live edge")
        let selection = try XCTUnwrap(
            fixture.server.currentAudioSelectionCapability(
                itemGeneration: 19,
                publicationSequence: snapshot.publicationSequence
            )
        )
        XCTAssertLessThanOrEqual(
            CMTimeCompare(
                selection.selectionWindow.end.cmTime,
                try XCTUnwrap(audio.effectivePlaybackHorizon).cmTime
            ),
            0,
            "AAC 选择窗口不得越过当前播放列表与视频共同冻结的有效上界"
        )
        withExtendedLifetime(source) {}
    }

    @MainActor
    func testFinalRealSocketSelectionChangeReconcilesPrepareAuthorizedAndActivatedLifecycles()
        async throws {
        // 只预热深拷贝 bytes/immutable format/timing；replacement 的 graph、writer、
        // endpoint authority、publisher 与 server 仍由每个真实 invocation JIT 创建。
        try await Task21RealAACSeed.warmEncodingTemplate()
        for stage in FinalSelectionLifecycleStage.allCases {
            let harness = try await Review2LoopbackCoordinatorHarness.makeFinal(
                enablesReplacement: true)
            defer { harness.shutdownReplacement() }
            let server = try XCTUnwrap(harness.finalServer)
            let snapshot = try XCTUnwrap(harness.finalSnapshot)
            XCTAssertEqual(try rawRequest(port: server.port,
                target: server.masterPath).status, 200)
            try serveParticipant(1, snapshot: snapshot, server: server)
            try serveParticipant(2, snapshot: snapshot, server: server)
            let masterURL = try XCTUnwrap(URL(string: server.masterPath,
                relativeTo: server.baseURL)?.absoluteURL)
            XCTAssertTrue(waitForCompletedPublication(
                server: server, itemURL: masterURL,
                itemGeneration: 19, publicationSequence: snapshot.publicationSequence,
                selectedRendition: .init(rawValue: 2)))
            // `phase` 是 coordinator 正式的同步可观察边界：读取时会先排空
            // server relay 的 pending selection。这里在 B terminal 前把真实 A
            // capability 冻结为 baseline；不调用私有 consumer，也不靠 sleep。
            XCTAssertEqual(harness.coordinator.phase, .installed)
            var activation: Task<Void, Never>?
            switch stage {
            case .beforePrepare:
                break
            case .authorized:
                try await harness.prepareOnly()
                activation = await harness.startHeldActivation()
                XCTAssertEqual(harness.coordinator.phase, .authorized)
            case .activated:
                try await harness.prepareAndActivate()
                XCTAssertEqual(harness.coordinator.phase, .playing)
            }

            try serveParticipant(4, snapshot: snapshot, server: server)
            XCTAssertTrue(waitUntil {
                server.currentAudioSelectionCapability(
                    itemGeneration: 19,
                    publicationSequence: snapshot.publicationSequence)?
                    .renditionIdentity == .init(rawValue: 4)
            }, "真实 B response terminal 必须先进入 server selection authority")
            let coordinatorConsumedReplacement = await waitUntilOnMainActor {
                harness.coordinator.stopTaskCount == 1
            }
            XCTAssertTrue(coordinatorConsumedReplacement,
                          "\(stage)：B selection relay 必须先使 coordinator 消费正式 replacement authority")
            let registryRegisteredSuspend = await waitUntilOnMainActor {
                harness.hasRegisteredSuspend
            }
            XCTAssertTrue(registryRegisteredSuspend,
                          "\(stage)：coordinator 消费后 Registry 必须登记同一单飞 suspend")
            harness.releaseHeldActivation()
            await activation?.value
            let expectedPhase: AVPlayerItemCoordinatorPhase = stage == .beforePrepare
                ? .prepared : .authorized
            let replacementPrepared = await waitUntilOnMainActor(timeout: .seconds(8)) {
                harness.backendRetireCount == 1
                    && harness.currentItemGeneration == 20
                    && harness.coordinator.phase == expectedPhase
            }
            XCTAssertTrue(replacementPrepared,
                          "\(stage)：同一 stop/retire 单飞完成后必须自动绑定新 publication/item generation 并 reprepare；"
                          + "retire=\(harness.backendRetireCount)，generation=\(String(describing: harness.currentItemGeneration))，"
                          + "phase=\(harness.coordinator.phase)，error=\(harness.backendErrorDescription)")
            if stage != .beforePrepare {
                XCTAssertEqual(harness.driver.playCallCount, 2,
                    "原播放意图持有 activation 时，replacement prepare 后必须由 Registry 重新签发正速授权")
                harness.driver.emitPlaying()
                XCTAssertEqual(harness.coordinator.phase, .playing)
            }
            let retiredGraph = try XCTUnwrap(harness.retiredGraphReservation)
            XCTAssertGreaterThan(retiredGraph.applicationChargeableBytes, 0,
                "\(stage)：quiescent replacement fence 仍由 coordinator 持有，retained graph 不得报零")
            XCTAssertEqual(retiredGraph.coordinatorReservationCount, 0,
                "\(stage)：replacement retirement 后资源根不得重复计入HLS state")
            XCTAssertEqual(retiredGraph.allocationIdentityCount, 3,
                "\(stage)：quiescent HLS state只保留stop、receipt与fence")
        }
    }

    @MainActor
    func testFinalAccessLogUsesServerBoundRouteAuthorityAndRejectsUnknownMalformedLocalPaths()
        async throws {
        let harness = try await Review2LoopbackCoordinatorHarness.makeFinal()
        defer { harness.shutdownReplacement() }
        let server = try XCTUnwrap(harness.finalServer)
        let snapshot = try XCTUnwrap(harness.finalSnapshot)
        XCTAssertEqual(try rawRequest(port: server.port,
            target: server.masterPath).status, 200)
        try serveParticipant(1, snapshot: snapshot, server: server)
        try serveParticipant(2, snapshot: snapshot, server: server)
        let masterURL = try XCTUnwrap(URL(string: server.masterPath,
            relativeTo: server.baseURL)?.absoluteURL)
        XCTAssertTrue(waitForCompletedPublication(
            server: server, itemURL: masterURL,
            itemGeneration: 19, publicationSequence: snapshot.publicationSequence,
            selectedRendition: .init(rawValue: 2)))
        try await harness.prepareAndActivate()
        XCTAssertEqual(harness.coordinator.selectedRenditions, [.init(rawValue: 2)])
        let item = try XCTUnwrap(harness.currentItemIdentity)
        let aKey = try XCTUnwrap(snapshot.media[2]?.resources.first)
        let bKey = try XCTUnwrap(snapshot.media[4]?.resources.first)
        let aPath = try server.path(for: aKey)
        let bPath = try server.path(for: bKey)
        let makeURL: (String) throws -> URL = {
            try XCTUnwrap(URL(string: $0, relativeTo: server.baseURL)?.absoluteURL)
        }

        harness.coordinator.observeAccessLogURI(try makeURL(aPath), item: item)
        XCTAssertFalse(harness.hasRegisteredSuspend,
                       "server route map 中真实 A media URI 必须保持当前 publication")
        for path in [
            "/v1/\(server.sessionToken)/19/1/audio/unknown/0.m4s?p=999&a=unknown",
            aPath.replacingOccurrences(of: "\(aKey.logicalSequence).m4s",
                                       with: "999999.m4s"),
            "/v1/\(server.sessionToken)/19/1/audio/2/%2e%2e/0.m4s",
        ] {
            harness.coordinator.observeAccessLogURI(try makeURL(path), item: item)
            for _ in 0..<16 { await Task.yield() }
            XCTAssertFalse(harness.hasRegisteredSuspend,
                           "未知、不存在或畸形本地 URI 不得被误认成可选择的 B")
            XCTAssertEqual(harness.coordinator.phase, .playing)
        }

        harness.coordinator.observeAccessLogURI(try makeURL(bPath), item: item)
        XCTAssertTrue(waitUntil {
            harness.hasRegisteredSuspend && harness.coordinator.phase == .stopping
        }, "只有 server 冻结 route map 中真实 B media URI 才能触发 conflict/Registry stop")
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
    }

    func testFinalPublicationMaxCASPublishesOnlyForwardProgressAndSuppressesOldHorizonCallbacks()
        async throws {
        let fixture = try await Task20HTTPFixture.start()
        defer { fixture.shutdown() }
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        let events = LockedInts()
        source.installCompletedPublicationEventHandler { events.append(Int($0)) }
        let first = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(first, fixture: fixture, includeMaster: true)
        XCTAssertTrue(waitUntil {
            events.values == [Int(first.publicationSequence)]
        }, "首个 publication 必须等真实 send terminal/max-CAS 下游完成")
        let oldMedia = try XCTUnwrap(first.media[2]?.resources.first)
        try fixture.task19.offerBoth(count: 1)
        XCTAssertEqual(try fixture.task19.publisher.publish(
            ticket: fixture.task19.publisher.ticket, now: Task19.second), .published)
        let current = try XCTUnwrap(fixture.task19.publisher.visible)
        try serveFullPublication(current, fixture: fixture, includeMaster: true)
        XCTAssertTrue(waitUntil {
            events.values.last == Int(current.publicationSequence)
        }, "当前 publication 必须等真实 send terminal/max-CAS 下游完成")
        let countAtCurrent = events.values.count

        XCTAssertEqual(try rawRequest(port: fixture.server.port,
            target: try fixture.server.path(for: oldMedia)).status, 200,
            "availability horizon 内 N-1 backing 仍可服务")
        XCTAssertEqual(events.values.count, countAtCurrent,
                       "N 已发布后，N-1 horizon terminal 必须在 max-CAS 下游前被抑制")
        XCTAssertEqual(events.values, Array(Set(events.values)).sorted(),
                       "下游只能观察真正前进且每个 sequence 一次的 publication 值")
        let latest = source.consumeLatestCompletedPublication(itemURL: try masterURL(for: fixture),
            item: .init(outputLifecycleEpoch:
                AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 41_200),
                itemGeneration: 19))
        XCTAssertEqual(latest?.publicationSequence, current.publicationSequence)
    }

    private func serveParticipant(_ participantID: UInt64,
                                  snapshot: HLSPublishedSnapshot,
                                  fixture: Task20HTTPFixture) throws {
        try serveParticipant(participantID, snapshot: snapshot,
                             server: fixture.server)
    }

    private func serveParticipant(_ participantID: UInt64,
                                  snapshot: HLSPublishedSnapshot,
                                  server: LoopbackHTTPServer) throws {
        let entry = try XCTUnwrap(snapshot.participantVector.first {
            $0.participantID == participantID
        })
        let playlist = try XCTUnwrap(snapshot.media[participantID])
        XCTAssertEqual(try rawRequest(port: server.port,
            target: entry.declaration.playlistURI(participantID: participantID)).status, 200)
        for key in playlist.initializationResources + playlist.resources {
            XCTAssertEqual(try rawRequest(port: server.port,
                target: try server.path(for: key)).status, 200)
        }
    }

    private func masterURL(for fixture: Task20HTTPFixture) throws -> URL {
        try XCTUnwrap(URL(string: fixture.server.masterPath,
                          relativeTo: fixture.server.baseURL)?.absoluteURL)
    }

    private func waitForCompletedPublication(
        server: LoopbackHTTPServer,
        itemURL: URL,
        itemGeneration: UInt64,
        publicationSequence: UInt64,
        selectedRendition: AudioRenditionIdentity? = nil
    ) -> Bool {
        let selectionReady = waitUntil {
            guard let selectedRendition else { return true }
            return server.currentAudioSelectionCapability(
                itemGeneration: itemGeneration,
                publicationSequence: publicationSequence
            )?.renditionIdentity == selectedRendition
        }
        guard selectionReady,
              let capability = server.completedPublicationCapability(
                itemURL: itemURL, itemGeneration: itemGeneration,
                publicationSequence: publicationSequence),
              let evidence = server.consumeCompletedPublicationCapability(capability) else {
            return false
        }
        return selectedRendition == nil
            || evidence.audioSelectionCapability?.renditionIdentity == selectedRendition
    }

    private func consumePublication(fixture: Task20HTTPFixture, itemURL: URL,
                                    snapshot: HLSPublishedSnapshot) throws
        -> LoopbackCompletedPublicationEvidence {
        try consumePublication(server: fixture.server, itemURL: itemURL,
                               snapshot: snapshot)
    }

    private func consumePublication(server: LoopbackHTTPServer, itemURL: URL,
                                    snapshot: HLSPublishedSnapshot) throws
        -> LoopbackCompletedPublicationEvidence {
        guard waitUntil({ server.usage.activeResponses == 0 }) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        // active response terminal 已归零后只签发并消费一个 wrapper；不能在 polling
        // 中反复 mint/consume 来掩盖 send-terminal ledger 的真实完成边界。
        let capability = try XCTUnwrap(server.completedPublicationCapability(
            itemURL: itemURL, itemGeneration: 19,
            publicationSequence: snapshot.publicationSequence))
        return try XCTUnwrap(
            server.consumeCompletedPublicationCapability(capability))
    }

    private static func partition(_ whole: Range<Int>, count: Int) -> [Range<Int>] {
        precondition(count > 0 && whole.count >= count)
        return (0..<count).map { index in
            let lower = whole.lowerBound + whole.count * index / count
            let upper = whole.lowerBound + whole.count * (index + 1) / count
            return lower..<upper
        }
    }

    private static func etag(_ body: Data) -> String {
        "\"" + Data(SHA256.hash(data: body)).map { String(format: "%02x", $0) }.joined() + "\""
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while Date() < deadline
        return predicate()
    }

    /// MainActor 上的生产 relay 通过 DispatchQueue.main 投递；同步轮询会把它饿死。
    /// 这里仅让出执行权，不调用 coordinator 私有 consumer，也不以 sleep 猜时序。
    @MainActor
    private func waitUntilOnMainActor(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private static func rawRequest(port: UInt16, method: String = "GET", target: String,
                                   headers: [String: String] = [:], rawAdditionalHeaders: String? = nil) throws -> HTTPReply {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var fields = headers
        if fields["Host"] == nil { fields["Host"] = "127.0.0.1:\(port)" }
        fields["Connection"] = "close"
        var request = "\(method) \(target) HTTP/1.1\r\n"
        for key in fields.keys.sorted() { request += "\(key): \(fields[key]!)\r\n" }
        if let rawAdditionalHeaders { request += rawAdditionalHeaders + "\r\n" }
        request += "\r\n"
        let sent = request.withCString { Darwin.send(descriptor, $0, strlen($0), 0) }
        guard sent == request.utf8.count else { throw POSIXError(.EIO) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 { received.append(contentsOf: buffer.prefix(count)); continue }
            if count == 0 { break }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try HTTPReply(received)
    }

    private static func nonLoopbackIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        var cursor = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &text, socklen_t(text.count)) != nil else { continue }
            let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let host = String(decoding: bytes, as: UTF8.self)
            if host != "127.0.0.1" && host != "0.0.0.0" { result.append(host) }
        }
        return Array(Set(result)).sorted()
    }

    private static func canConnectIPv4(_ host: String, port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private static func canConnectIPv6(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } == 0
    }

    private func rawRequest(port: UInt16, method: String = "GET", target: String,
                            headers: [String: String] = [:], rawAdditionalHeaders: String? = nil) throws -> HTTPReply {
        try Self.rawRequest(port: port, method: method, target: target,
                            headers: headers, rawAdditionalHeaders: rawAdditionalHeaders)
    }

    private func assertCompressedAuthorityRejectsCrossedLifecycle(
        codec: HLSAudioCodec,
        nonce: UInt64
    ) async throws {
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: nonce)
        let crossedLifecycle = AudioServiceLeaseTestHarness.makeLifecycle(
            outputNonce: nonce + 1)
        let fixture = try await Task21CompressedLifecycleHTTPFixture.start(
            codec: codec,
            outputLifecycleEpoch: lifecycle)
        defer { fixture.shutdown() }
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle,
                                                itemGeneration: fixture.itemGeneration)
        let crossedItem = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: crossedLifecycle,
            itemGeneration: fixture.itemGeneration)

        XCTAssertNoThrow(try fixture.server.makeAVPlayerPreparationRequest(
            item: item,
            publicationSequence: fixture.publicationSequence))
        XCTAssertThrowsError(try fixture.server.makeAVPlayerPreparationRequest(
            item: crossedItem,
            publicationSequence: fixture.publicationSequence)) { error in
            XCTAssertEqual(error as? LoopbackHTTPServerError, .invalidConfiguration)
        }

        try await fixture.serveCompletedPublication()
        let capability = try XCTUnwrap(fixture.server.completedPublicationCapability(
            itemURL: fixture.itemURL,
            itemGeneration: fixture.itemGeneration,
            publicationSequence: fixture.publicationSequence))
        let completed = try XCTUnwrap(
            fixture.server.consumeCompletedPublicationCapability(capability))
        let selection = try XCTUnwrap(completed.audioSelectionCapability)
        XCTAssertEqual(selection.outputLifecycleEpoch, lifecycle)

        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: nil,
            completedPublication: completed,
            itemURL: fixture.itemURL,
            item: crossedItem,
            publicationSequence: fixture.publicationSequence,
            expectedSelection: selection) {
        case .invalid:
            break
        case .waitingForSelection, .ready:
            XCTFail("同 generation 的压缩音频 publication 不得跨 output lifecycle 签时间轴")
        }

        let timeline: PlayerItemTimelineMappingAuthority
        switch try fixture.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: nil,
            completedPublication: completed,
            itemURL: fixture.itemURL,
            item: item,
            publicationSequence: fixture.publicationSequence,
            expectedSelection: selection) {
        case .ready(let authority):
            timeline = authority
        case .waitingForSelection, .invalid:
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        XCTAssertEqual(timeline.outputLifecycleEpoch, lifecycle)
        XCTAssertTrue(timeline.matches(
            itemURL: fixture.itemURL,
            item: item,
            publicationSequence: fixture.publicationSequence,
            selection: selection))
        XCTAssertFalse(timeline.matches(
            itemURL: fixture.itemURL,
            item: crossedItem,
            publicationSequence: fixture.publicationSequence,
            selection: selection),
            "旧 lifecycle 的 timeline authority 不得认证同 generation 的新 item")
    }

    func testAACHTTPFinalizationChargeLeaseSurvivesQueuedTailAndRollsBackFailedInstall()
        throws {
        let ledger = HLSDeliveryApplicationChargeLedger.shared
        let bytes = LoopbackStorageLayout.current.aacHTTPFinalizationMetadataBytes
        let baseline = ledger.chargedBytes

        weak var failedInstallLease: AACHTTPFinalizationChargeLease?
        do {
            let owner = try AACHTTPFinalizationChargeLease(bytes: bytes)
            failedInstallLease = owner
            var observerAlias: AACHTTPFinalizationChargeLease? = owner
            XCTAssertEqual(ledger.chargedBytes, baseline + bytes)
            observerAlias = nil
            _ = observerAlias
        }
        XCTAssertNil(failedInstallLease,
                     "注册失败清除server/observer alias后必须归还固定metadata账")
        XCTAssertEqual(ledger.chargedBytes, baseline)

        var owner: AACHTTPFinalizationChargeLease? = try .init(bytes: bytes)
        weak let queuedLease = owner
        var queuedTail: (() -> Void)? = { [lease = try XCTUnwrap(owner)] in
            _ = lease
        }
        owner = nil
        XCTAssertNotNil(queuedLease,
                        "server retire放弃自身alias时，已排队尾沿必须继续持账")
        XCTAssertEqual(ledger.chargedBytes, baseline + bytes)
        queuedTail?()
        queuedTail = nil
        XCTAssertNil(queuedLease, "最后queued alias退出后才能归还delivery账")
        XCTAssertEqual(ledger.chargedBytes, baseline)
    }
}

private final class Task21CompressedLifecycleHTTPFixture: @unchecked Sendable {
    let publication: Task21CompressedLifecyclePublication
    let server: LoopbackHTTPServer
    let itemURL: URL
    let publicationSequence: UInt64
    let itemGeneration: UInt64

    private init(publication: Task21CompressedLifecyclePublication,
                 server: LoopbackHTTPServer) throws {
        self.publication = publication
        self.server = server
        itemGeneration = publication.declaration.itemGeneration
        publicationSequence = try XCTUnwrap(
            publication.publisher.visible?.publicationSequence)
        let path = try publication.declaration.playlistURI(participantID: 2)
        itemURL = try XCTUnwrap(URL(string: path,
                                    relativeTo: server.baseURL)?.absoluteURL)
    }

    static func start(codec: HLSAudioCodec,
                      outputLifecycleEpoch: OutputLifecycleEpoch) async throws
        -> Task21CompressedLifecycleHTTPFixture {
        let box = Task21CompressedLifecyclePublicationBox()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 20,
            now: { 0 },
            logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try Task21CompressedLifecyclePublication(
                loopbackSession: token,
                codec: codec,
                outputLifecycleEpoch: outputLifecycleEpoch)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        return try Task21CompressedLifecycleHTTPFixture(
            publication: XCTUnwrap(box.value),
            server: server)
    }

    func serveCompletedPublication() async throws {
        let snapshot = try XCTUnwrap(publication.publisher.visible)
        let playlist = try XCTUnwrap(snapshot.media[2])
        var urls = [itemURL]
        urls += try (playlist.initializationResources + playlist.resources).map {
            try XCTUnwrap(URL(string: server.path(for: $0),
                              relativeTo: server.baseURL)?.absoluteURL)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            let (body, response) = try await session.data(from: url)
            XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
            XCTAssertFalse(body.isEmpty)
        }
    }

    func shutdown() {
        _ = waitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        let ticket = server.closeAdmission()
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }
}

private final class Task21CompressedLifecyclePublication: @unchecked Sendable {
    let store: SealedMediaStore
    let declaration: HLSItemDeclaration
    let publisher: HLSPublicationCoordinator
    private let track: Task21CompressedLifecycleTrack

    init(loopbackSession: LoopbackSessionToken,
         codec: HLSAudioCodec,
         outputLifecycleEpoch: OutputLifecycleEpoch) throws {
        track = try Task21CompressedLifecycleTrack(
            codec: codec,
            outputLifecycleEpoch: outputLifecycleEpoch)
        store = SealedMediaStore(loopbackSession: loopbackSession,
                                 itemGeneration: 20)
        declaration = HLSItemDeclaration(
            itemGeneration: 20,
            token: loopbackSession.value,
            video: nil,
            audio: [.init(
                participantID: 2,
                renditionID: codec == .ac3 ? "ac3-2" : "eac3-2",
                codec: codec,
                channels: 2,
                language: nil,
                score: 100,
                peakEnvelope: codec == .ac3 ? 640_000 : 6_208_000)])
        let candidate = try store.registerAudioCandidate(
            initialization: track.initialization,
            proof: track.proof,
            declaration: declaration)
        publisher = try HLSPublicationCoordinator(
            store: store,
            participants: [.init(
                initialization: track.initialization,
                proof: track.proof,
                relay: track.relay,
                candidateTicket: candidate.ticket,
                candidate: candidate)],
            declaration: declaration,
            anchor: .init(mediaOrigin: .init(value: 0, timescale: 1),
                          utcMilliseconds: 1_788_912_000_000))
        for _ in 0..<6 {
            let packet = try track.next()
            _ = try publisher.offer(packet.object,
                                    receipt: packet.receipt,
                                    relay: packet.relay,
                                    ticket: publisher.ticket,
                                    now: 0)
        }
        guard publisher.visible != nil else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }
}

private final class Task21CompressedLifecycleTrack: @unchecked Sendable {
    let relay: SegmentReportRelay
    let initialization: SealedMediaObject
    let proof: EpochFormatProof

    private let codec: HLSAudioCodec
    private let admission: AudioBranchAdmissionIdentity
    private let collector = Task21CompressedLifecycleCollector()
    private let boundary: SegmentBoundaryCoordinator
    private let writer: SegmentedFMP4Writer
    private let timeline: SegmentTimelineValidator
    private var media: [SealedMediaObject]
    private var nextSequence: UInt64 = 0

    init(codec: HLSAudioCodec,
         outputLifecycleEpoch: OutputLifecycleEpoch) throws {
        self.codec = codec
        let binding = FMP4WriterBinding(
            outputLifecycleEpoch: outputLifecycleEpoch,
            itemGeneration: .init(rawValue: 20),
            mediaEpoch: .init(rawValue: 1),
            publicationParticipantID: .init(rawValue: 2),
            renditionIdentity: .init(rawValue: 2),
            writerIdentity: .init(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .nonce)))
        let owner = CompressedAudioBranchOwnerIdentity.audioVideo(
            outputLifecycleEpoch: binding.outputLifecycleEpoch,
            itemGeneration: binding.itemGeneration,
            mediaEpoch: binding.mediaEpoch,
            publicationParticipantID: binding.publicationParticipantID,
            renditionIdentity: binding.renditionIdentity)
        let admissionSeed = try PlaybackIdentityAllocator.shared.next(in: .nonce)
        switch codec {
        case .ac3:
            admission = .directCompressed(
                owner,
                branchGeneration: admissionSeed,
                admissionFenceRevision: admissionSeed + 1)
        case .eac3:
            admission = .eac3Aggregation(
                owner,
                branchGeneration: admissionSeed,
                admissionFenceRevision: admissionSeed + 1)
        case .aac:
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        relay = SegmentReportRelay(
            binding: binding,
            limits: .audio,
            capacity: 8,
            objectSink: collector.append)
        boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: .zero))
        let firstSource = try Self.makeAccessUnit(
            codec: codec,
            admission: admission,
            at: .zero)
        let first = firstSource.accessUnit
        let trackKind: SegmentedFMP4TrackKind = codec == .ac3 ? .ac3 : .eac3
        let accessUnitKind: SegmentAudioAccessUnitKind = codec == .ac3
            ? .ac3(sampleRate: first.sampleRate)
            : .eac3Aggregated(sampleRate: first.sampleRate,
                              sampleCount: first.sampleCount)
        try boundary.registerAudioRendition(
            binding.renditionIdentity,
            accessUnit: accessUnitKind,
            firstEffectiveStart: first.presentationStart)
        let createdWriter = try SegmentedFMP4Writer(
            binding: binding,
            trackKind: trackKind,
            sourceFormatHint: try Self.compressedAudioFormat(for: first),
            boundarySession: boundary.session,
            compressedFormatConfiguration: first.formatConfiguration,
            relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        try createdWriter.start(at: .zero)
        try Self.append(first, writer: createdWriter,
                        boundary: boundary,
                        coordinator: firstSource.coordinator)
        var presentationTimeStamp = CMTime(
            value: Int64(first.sampleCount),
            timescale: first.sampleRate)
        for _ in 1..<224 {
            let nextSource = try Self.makeAccessUnit(
                codec: codec,
                admission: admission,
                at: presentationTimeStamp)
            let accessUnit = nextSource.accessUnit
            try Self.append(accessUnit, writer: createdWriter,
                            boundary: boundary,
                            coordinator: nextSource.coordinator)
            presentationTimeStamp = CMTimeAdd(
                presentationTimeStamp,
                CMTime(value: Int64(accessUnit.sampleCount),
                       timescale: accessUnit.sampleRate))
            if collector.mediaCount >= 6 { break }
        }
        guard collector.waitFor(initializationCount: 1, mediaCount: 6,
                                timeout: 10) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let resolvedInitialization = try XCTUnwrap(collector.takeInitialization())
        let resolvedMedia = collector.takeMedia(count: 6)
        guard resolvedMedia.count == 6 else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let resolvedProof = try FinalFMP4Validator(
            binding: binding,
            mediaType: .audio).validateInitialization(resolvedInitialization)
        writer = createdWriter
        initialization = resolvedInitialization
        media = resolvedMedia
        proof = resolvedProof
        timeline = SegmentTimelineValidator(proof: resolvedProof,
                                            firstLogicalSequence: 0)
    }

    private static func makeAccessUnit(
        codec: HLSAudioCodec,
        admission: AudioBranchAdmissionIdentity,
        at presentationTimeStamp: CMTime
    ) throws
        -> (accessUnit: CompressedAudioAccessUnit,
            coordinator: AudioServiceSemanticCoordinator) {
        let seed = try PlaybackIdentityAllocator.shared.next(in: .nonce)
        switch codec {
        case .ac3:
            let harness = try Task17AC3Harness(seed: seed,
                                               admission: admission)
            return (try harness.makeAccessUnit(
                presentationTimeStamp: presentationTimeStamp),
                harness.coordinator)
        case .eac3:
            let harness = try Task17EAC3Harness(seed: seed,
                                                admission: admission)
            return (try harness.makeSixMemberAccessUnit(
                presentationBase: presentationTimeStamp),
                harness.coordinator)
        case .aac:
            throw LoopbackHTTPServerError.invalidConfiguration
        }
    }

    func next() throws -> Task19Packet {
        guard !media.isEmpty else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let object = media.removeFirst()
        let receipt = try timeline.validate(object, using: proof)
        nextSequence += 1
        return Task19Packet(object: object, receipt: receipt, relay: relay)
    }

    private static func append(
        _ accessUnit: CompressedAudioAccessUnit,
        writer: SegmentedFMP4Writer,
        boundary: SegmentBoundaryCoordinator,
        coordinator: AudioServiceSemanticCoordinator
    ) throws {
        try writer.appendCompressed(
            accessUnit.writerSubmission,
            coordinator: coordinator,
            ticket: boundary.issueCompressedAudioAppend(
                for: accessUnit,
                writerBinding: writer.binding))
    }

    private static func compressedAudioFormat(
        for accessUnit: CompressedAudioAccessUnit
    ) throws -> CMFormatDescription {
        let formatID: AudioFormatID
        switch accessUnit.codec {
        case .ac3:
            formatID = kAudioFormatAC3
        case .eac3:
            formatID = kAudioFormatEnhancedAC3
        default:
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        var stream = AudioStreamBasicDescription(
            mSampleRate: Float64(accessUnit.sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(accessUnit.sampleCount),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(accessUnit.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0)
        let cookie = accessUnit.formatConfiguration.serializedBox
        var result: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &stream,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: bytes.baseAddress,
                extensions: nil,
                formatDescriptionOut: &result)
        }
        guard status == noErr, let result else {
            throw AACRenditionFailure.framework(status)
        }
        return result
    }
}

private final class Task21CompressedLifecycleCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var objects: [SealedMediaObject] = []

    var mediaCount: Int {
        condition.withLock { objects.count(where: { $0.kind == .media }) }
    }

    func append(_ object: SealedMediaObject) {
        condition.withLock {
            objects.append(object)
            condition.broadcast()
        }
    }

    func waitFor(initializationCount: Int, mediaCount: Int,
                 timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while objects.count(where: { $0.kind == .initialization }) < initializationCount
            || objects.count(where: { $0.kind == .media }) < mediaCount {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func takeInitialization() -> SealedMediaObject? {
        condition.withLock {
            guard let index = objects.firstIndex(where: {
                $0.kind == .initialization
            }) else { return nil }
            return objects.remove(at: index)
        }
    }

    func takeMedia(count: Int) -> [SealedMediaObject] {
        condition.withLock {
            var result: [SealedMediaObject] = []
            while result.count < count,
                  let index = objects.firstIndex(where: { $0.kind == .media }) {
                result.append(objects.remove(at: index))
            }
            return result
        }
    }
}

private final class Task21CompressedLifecyclePublicationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task21CompressedLifecyclePublication?
    var value: Task21CompressedLifecyclePublication? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private enum FinalSelectionLifecycleStage: CaseIterable {
    case beforePrepare
    case authorized
    case activated
}

@MainActor
private final class Review2LoopbackCoordinatorHarness {
    let driver: Review2LoopbackDriver
    let coordinator: AVPlayerItemCoordinator
    private let backend: Review2LoopbackBackend
    private let graph: OutputGraphFixture
    private let finalInitialFixture: FinalReview2InitialHTTPFixture?

    var hasRegisteredSuspend: Bool {
        graph.registry.outputResourceContextSnapshot()?.suspend != nil
            || backend.suspendCallCount > 0
    }
    var backendRetireCount: Int { backend.retireCallCount }
    var backendErrorDescription: String { String(describing: backend.lastError) }
    var retiredGraphReservation: AVPlayerRetainedGraphReservationSnapshot? {
        backend.retiredGraphReservation
    }
    var currentItemGeneration: UInt64? { coordinator.currentItemIdentity?.itemGeneration }
    var currentItemIdentity: AVPlayerItemInstanceIdentity? { coordinator.currentItemIdentity }
    var finalServer: LoopbackHTTPServer? { finalInitialFixture?.server }
    var finalSnapshot: HLSPublishedSnapshot? { finalInitialFixture?.snapshot }

    init(fixture: Task20HTTPFixture, snapshot: HLSPublishedSnapshot,
         audioRenditions: [UInt64] = [2],
         useManualAuthoritySink: Bool = true,
         onAuthorityChange: @escaping @Sendable () -> Void,
         enablesReplacement: Bool = false) throws {
        driver = Review2LoopbackDriver()
        let evidence = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        if useManualAuthoritySink {
            coordinator = try AVPlayerItemCoordinator(driver: driver, evidenceSource: evidence)
        } else {
            coordinator = try AVPlayerItemCoordinator(driver: driver, evidenceSource: evidence)
        }
        backend = Review2LoopbackBackend(coordinator: coordinator,
                                         enablesReplacement: enablesReplacement)
        graph = try OutputGraphFixture(backendObject: backend)
        finalInitialFixture = nil
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: graph.lifecycle,
                                                itemGeneration: 19)
        backend.configure(identity: graph.lifecycle.backendIdentity, itemGeneration: 19)
        let itemURL = try XCTUnwrap(URL(string: fixture.server.masterPath,
            relativeTo: fixture.server.baseURL)?.absoluteURL)
        try coordinator.install(.init(itemURL: itemURL, item: item,
            publicationSequence: snapshot.publicationSequence,
            audioParticipants: audioRenditions.map {
                .init(renditionIdentity: .init(rawValue: $0), codec: .explicitlyNonAAC)
            },
            directAudioOnlyRendition: nil))
    }

    private init(driver: Review2LoopbackDriver,
                 coordinator: AVPlayerItemCoordinator,
                 backend: Review2LoopbackBackend,
                 graph: OutputGraphFixture,
                 finalInitialFixture: FinalReview2InitialHTTPFixture) {
        self.driver = driver
        self.coordinator = coordinator
        self.backend = backend
        self.graph = graph
        self.finalInitialFixture = finalInitialFixture
    }

    static func makeFinal(enablesReplacement: Bool = false) async throws
        -> Review2LoopbackCoordinatorHarness {
        let backend = Review2LoopbackBackend(enablesReplacement: enablesReplacement)
        let graph = try OutputGraphFixture(backendObject: backend)
        let fixture = try await FinalReview2InitialHTTPFixture.start(
            outputLifecycleEpoch: graph.lifecycle)
        let driver = Review2LoopbackDriver()
        let evidence = try LoopbackAVPlayerPreparationEvidenceSource.make(server: fixture.server)
        let coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: evidence,
            backendPublicationReplacementAuthoritySlot:
                backend.backendPublicationReplacementAuthoritySlot)
        backend.attach(coordinator)
        backend.configure(identity: graph.lifecycle.backendIdentity,
                          itemGeneration: 19)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: graph.lifecycle, itemGeneration: 19)
        let bundle = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: evidence, item: item,
            publicationSequence: fixture.snapshot.publicationSequence)
        try coordinator.install(bundle.request)
        return Review2LoopbackCoordinatorHarness(
            driver: driver, coordinator: coordinator, backend: backend,
            graph: graph, finalInitialFixture: fixture)
    }

    func prepareAndActivate() async throws {
        try await prepareOnly()
        try await activateOnly()
        driver.emitPlaying()
    }

    func prepareOnly() async throws {
        let source = try XCTUnwrap(
            graph.registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(graph.registry.startOutputPrepareOperation(source))
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(source),
              backend.prepared != nil else {
            throw backend.lastError ?? AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func activateOnly() async throws {
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce))
        XCTAssertTrue(graph.registry.startOutputActivationOperation(activation))
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(activation),
              case .armed = backend.activationResult else {
            throw backend.lastError ?? AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func startHeldActivation() async -> Task<Void, Never> {
        driver.holdPlayCompletion = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.activateOnly()
        }
        await driver.waitForPlayEntry()
        return task
    }

    func releaseHeldActivation() { driver.releasePlayCompletion() }

    func shutdownReplacement() {
        backend.shutdownReplacement()
        finalInitialFixture?.shutdown()
    }
}

@MainActor
private final class Review2LoopbackDriver: AVPlayerDriving {
    var seekAction: (() throws -> Void)?
    var rate: Float = 0
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var currentItemIdentity: AVPlayerItemInstanceIdentity?
    private var statusRelay: (@MainActor @Sendable (
        AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
    ) -> Void)?
    private var statusActivation: ActivationEpoch?
    private(set) var playCallCount = 0
    var holdPlayCompletion = false
    private var playEntered = false
    private var playEntryWaiter: CheckedContinuation<Void, Never>?
    private var playCompletion: CheckedContinuation<Void, Never>?

    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws {
        currentItemIdentity = identity
        rate = 0
        timeControlStatus = .paused
    }

    func waitUntilReady(item: AVPlayerItemInstanceIdentity) async throws
        -> AVPlayerItemInstanceIdentity { item }

    func seek(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity,
              playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt {
        try seekAction?()
        return .init(item: item, playhead: playhead, actualTime: time)
    }

    func waitForLoadedTimeRanges(item: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: FMP4PresentationRange) async throws
        -> AVPlayerLoadedRangeReceipt { .init(item: item, playhead: playhead, requested: requested) }

    func preroll(item: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt {
        .init(item: item, playhead: playhead, succeeded: true)
    }

    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        guard invocation.performPositiveRateSideEffect({
            playCallCount += 1
            rate = 1
            timeControlStatus = .waitingToPlayAtSpecifiedRate
        }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        playEntered = true
        playEntryWaiter?.resume()
        playEntryWaiter = nil
        if holdPlayCompletion {
            await withCheckedContinuation { playCompletion = $0 }
        }
    }

    func installTimeControlStatusRelay(item: AVPlayerItemInstanceIdentity,
        activation: ActivationEpoch,
        handler: @escaping @MainActor @Sendable (
            AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
        ) -> Void) throws {
        statusRelay = handler
        statusActivation = activation
    }

    func installAccessLogURIObservation(
        item: AVPlayerItemInstanceIdentity,
        classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
        handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    ) throws {}

    func cancelPendingPrerolls(item: AVPlayerItemInstanceIdentity) {}
    func pause(item: AVPlayerItemInstanceIdentity) {
        rate = 0
        timeControlStatus = .paused
    }
    func waitUntilPaused(item: AVPlayerItemInstanceIdentity) async throws {
        guard timeControlStatus == .paused else {
            throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
        }
    }
    func directState(item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
        .init(item: item, rate: rate, timeControlStatus: timeControlStatus)
    }
    func replaceCurrentItemWithNil(item: AVPlayerItemInstanceIdentity) {
        if currentItemIdentity == item { currentItemIdentity = nil }
    }
    func removeObservers(item: AVPlayerItemInstanceIdentity) {
        statusRelay = nil
        statusActivation = nil
    }
    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item: AVPlayerItemInstanceIdentity) {}
    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item: AVPlayerItemInstanceIdentity) throws {}
    func installNaturalEndTerminalHandler(
        item: AVPlayerItemInstanceIdentity,
        handler: @escaping @MainActor @Sendable (
            AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
        ) -> Void
    ) throws { _ = handler }
    func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) -> AVPlayerNaturalEndTerminalResult? { nil }

    func emitPlaying() {
        guard let item = currentItemIdentity, let activation = statusActivation else { return }
        timeControlStatus = .playing
        statusRelay?(.playing, item, activation)
    }

    func waitForPlayEntry() async {
        if playEntered { return }
        await withCheckedContinuation { playEntryWaiter = $0 }
    }

    func releasePlayCompletion() {
        holdPlayCompletion = false
        playCompletion?.resume()
        playCompletion = nil
    }
}

private final class Review2LoopbackBackend: PlaybackBackend,
    BackendPublicationReplacementAuthorityInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: AVPlayerItemCoordinator!
    private let replacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot
    private let enablesReplacement: Bool
    private var replacementFixtureValue: FinalReplacementHTTPFixture?
    private var configuredIdentity = PlaybackBackendIdentity(
        sessionIdentity: .init(sessionID: 0, requestID: UUID()), backendGeneration: 0)
    private var configuredItemGeneration: UInt64?
    private var preparedValue: PreparedAVPlayerItem?
    private var activationValue: BackendActivationResult?
    private var errorValue: Error?
    private var suspendCallCountValue = 0
    private var retireCallCountValue = 0
    private var retiredGraphReservationValue:
        AVPlayerRetainedGraphReservationSnapshot?

    @MainActor
    init(coordinator: AVPlayerItemCoordinator,
         enablesReplacement: Bool = false) {
        self.coordinator = coordinator
        self.enablesReplacement = enablesReplacement
        replacementAuthoritySlot = coordinator.backendPublicationReplacementAuthoritySlot
    }

    init(enablesReplacement: Bool) {
        coordinator = nil
        self.enablesReplacement = enablesReplacement
        replacementAuthoritySlot = .init()
    }

    @MainActor
    func attach(_ coordinator: AVPlayerItemCoordinator) {
        precondition(coordinator.backendPublicationReplacementAuthoritySlot
            === replacementAuthoritySlot)
        precondition(self.coordinator == nil)
        self.coordinator = coordinator
    }
    var identity: PlaybackBackendIdentity { lock.withLock { configuredIdentity } }
    var presentation: PlaybackPresentation? { nil }
    var outputItemGeneration: UInt64? { lock.withLock { configuredItemGeneration } }
    var backendPublicationReplacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot {
        replacementAuthoritySlot
    }
    var prepared: PreparedAVPlayerItem? { lock.withLock { preparedValue } }
    var activationResult: BackendActivationResult? { lock.withLock { activationValue } }
    var lastError: Error? { lock.withLock { errorValue } }
    var suspendCallCount: Int { lock.withLock { suspendCallCountValue } }
    var retireCallCount: Int { lock.withLock { retireCallCountValue } }
    var retiredGraphReservation: AVPlayerRetainedGraphReservationSnapshot? {
        lock.withLock { retiredGraphReservationValue }
    }

    func shutdownReplacement() {
        lock.withLock { replacementFixtureValue }?.shutdown()
    }

    func configure(identity: PlaybackBackendIdentity, itemGeneration: UInt64) {
        lock.withLock {
            configuredIdentity = identity
            configuredItemGeneration = itemGeneration
        }
    }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        do {
            let prepared = try await coordinator.prepareCurrentItem(invocation: invocation)
            lock.withLock { preparedValue = prepared }
        } catch {
            lock.withLock { errorValue = error }
            throw error
        }
    }

    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        do {
            guard enablesReplacement else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            let replacementFixture = try await FinalReplacementHTTPFixture.start(
                outputLifecycleEpoch: invocation.outputLifecycleEpoch)
            do {
                try await replacementFixture.serveInitialSelection()
                let bundle = try replacementFixture.makeBundle(invocation: invocation)
                try await coordinator.installReplacement(bundle, invocation: invocation)
                let prepared = try await coordinator.prepareCurrentItem(invocation: invocation)
                lock.withLock {
                    replacementFixtureValue = replacementFixture
                    preparedValue = prepared
                    configuredItemGeneration = prepared.item.itemGeneration
                }
            } catch {
                replacementFixture.shutdown()
                throw error
            }
        } catch {
            lock.withLock { errorValue = error }
            throw error
        }
    }

    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        do {
            let activation = try await coordinator.activate(invocation)
            lock.withLock { activationValue = activation }
            guard activation != .rejected else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
        } catch {
            lock.withLock { errorValue = error }
            throw error
        }
    }

    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async
        -> BackendSuspendResult {
        lock.withLock { suspendCallCountValue += 1 }
        do {
            let receipt = try await coordinator.stop(invocation)
            let attestation = try await coordinator.attestQuiescence(
                receipt, invocation: invocation, backendIdentity: identity)
            return .quiescent(.avPlayer(attestation))
        } catch {
            lock.withLock { errorValue = error }
            return .requiresRetirement
        }
    }

    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        do {
            try await coordinator.retireForReplacement(epoch)
            let graph = await coordinator.retainedGraphCapacitySnapshot
            lock.withLock {
                retireCallCountValue += 1
                retiredGraphReservationValue = graph
            }
            return .confirmedLocalOutputStopped
        } catch {
            lock.withLock { errorValue = error }
            return .unconfirmed
        }
    }
}

private enum Task21LoopbackCompletionMutation: CaseIterable {
    case acceptedBeforeTerminal
    case head
    case partialRange
    case failedSend
}

private struct HTTPReply {
    let status: Int
    let headers: [String: String]
    let body: Data
    init(_ bytes: Data) throws {
        let marker = Data("\r\n\r\n".utf8)
        guard let boundary = bytes.range(of: marker),
              let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw POSIXError(.EPROTO) }
        let lines = text.components(separatedBy: "\r\n")
        guard let code = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw POSIXError(.EPROTO) }
        status = code
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw POSIXError(.EPROTO) }
            parsed[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        headers = parsed
        body = Data(bytes[boundary.upperBound...])
    }
}

private final class PersistentHTTPClient {
    private let descriptor: Int32
    private let port: UInt16
    private var buffered = Data()
    init(port: UInt16) throws {
        self.port = port
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw POSIXError(.ECONNREFUSED) }
    }
    func request(target: String) throws -> HTTPReply {
        let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: keep-alive\r\n\r\n"
        let sent = request.withCString { Darwin.send(descriptor, $0, strlen($0), 0) }
        guard sent == request.utf8.count else { throw POSIXError(.EIO) }
        let marker = Data("\r\n\r\n".utf8)
        while true {
            if let boundary = buffered.range(of: marker),
               let header = String(data: buffered[..<boundary.lowerBound], encoding: .utf8) {
                let contentLength = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let headerBytes = buffered.distance(from: buffered.startIndex, to: boundary.upperBound)
                let totalCount = headerBytes + contentLength
                if buffered.count >= totalCount {
                    let response = try HTTPReply(Data(buffered.prefix(totalCount)))
                    buffered = Data(buffered.dropFirst(totalCount))
                    return response
                }
            }
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }
    deinit { Darwin.close(descriptor) }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var values: [Int] { lock.withLock { storage } }
    func append(_ value: Int) { lock.withLock { storage.append(value) } }
}

private final class LockedSelectionCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoopbackAudioMediaSelectionCapability] = []
    var values: [LoopbackAudioMediaSelectionCapability] { lock.withLock { storage } }
    func append(_ value: LoopbackAudioMediaSelectionCapability) {
        lock.withLock { storage.append(value) }
    }
}

/// Registry replacement 使用的真实 generation20 publication/server bundle。
/// request 只在 Registry 给出新 lifecycle invocation 后组装，绝不复用 generation19 capability。
private final class FinalReplacementHTTPFixture: @unchecked Sendable {
    let publication: FinalReplacementPublicationHarness
    let server: LoopbackHTTPServer
    let evidenceSource: LoopbackAVPlayerPreparationEvidenceSource
    let itemURL: URL
    let publicationSequence: UInt64
    let itemGeneration: UInt64

    private init(publication: FinalReplacementPublicationHarness,
                 server: LoopbackHTTPServer) throws {
        self.publication = publication
        self.server = server
        evidenceSource = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        let playlistPath = try publication.declaration.playlistURI(participantID: 2)
        itemURL = try XCTUnwrap(URL(string: playlistPath,
                                    relativeTo: server.baseURL)?.absoluteURL)
        publicationSequence = try XCTUnwrap(
            publication.publisher.visible?.publicationSequence)
        itemGeneration = publication.declaration.itemGeneration
    }

    static func start(
        outputLifecycleEpoch: OutputLifecycleEpoch,
        itemGeneration: UInt64 = 20,
        responseFailure:
            @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void = { _, _ in }
    ) async throws
        -> FinalReplacementHTTPFixture {
        let seed = try await Task21RealAACSeed.make(
            itemGeneration: itemGeneration,
            outputLifecycleEpoch: outputLifecycleEpoch)
        let box = FinalReplacementLockedHarness()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: itemGeneration, now: { 0 }, logger: { _ in },
            responseFailure: responseFailure
        ) { token in
            let publication = try FinalReplacementPublicationHarness(
                loopbackSession: token, seed: seed,
                itemGeneration: itemGeneration)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        return try FinalReplacementHTTPFixture(
            publication: XCTUnwrap(box.value), server: server)
    }

    func serveInitialSelection() async throws {
        let snapshot = try XCTUnwrap(publication.publisher.visible)
        var urls = [itemURL]
        let playlist = try XCTUnwrap(snapshot.media[2])
        urls += try (playlist.initializationResources + playlist.resources).map {
            try XCTUnwrap(URL(string: server.path(for: $0),
                              relativeTo: server.baseURL)?.absoluteURL)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            let (body, response) = try await session.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertFalse(body.isEmpty)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let capability = server.completedPublicationCapability(
                itemURL: itemURL, itemGeneration: itemGeneration,
                publicationSequence: publicationSequence),
               let evidence = server.consumeCompletedPublicationCapability(capability),
               evidence.audioSelectionCapability?.renditionIdentity == .init(rawValue: 2) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AVPlayerItemCoordinatorFailure.insufficientCoverage
    }

    func makeBundle(invocation: ControlTaskRegistry.BackendPrepareInvocation) throws
        -> AVPlayerItemReplacementBundle {
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: invocation.outputLifecycleEpoch,
            itemGeneration: itemGeneration)
        return try LoopbackAVPlayerPreparationBundle(
            evidenceSource: evidenceSource, item: item,
            publicationSequence: publicationSequence).replacementBundle
    }

    func resourceBytes(_ key: HLSResourceKey) throws -> Data {
        let lease = try XCTUnwrap(publication.store.acquireResponse(
            key, token: server.sessionToken, now: 0))
        defer { publication.store.release(lease, now: 0) }
        return lease.withUnsafeBytes { Data($0) }
    }

    func shutdown() {
        _ = waitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        evidenceSource.retirePreparation()
        let ticket = server.closeAdmission()
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }
}

private final class FinalReplacementLockedHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FinalReplacementPublicationHarness?
    var value: FinalReplacementPublicationHarness? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class FinalReplacementPublicationHarness: @unchecked Sendable {
    let store: SealedMediaStore
    let declaration: HLSItemDeclaration
    let publisher: HLSPublicationCoordinator
    let endpointAuthority: AACEffectiveEndpointAuthority

    init(loopbackSession: LoopbackSessionToken,
         seed: Task21RealAACSeed,
         itemGeneration: UInt64 = 20) throws {
        endpointAuthority = seed.endpointAuthority
        store = SealedMediaStore(loopbackSession: loopbackSession,
                                 itemGeneration: itemGeneration)
        var declaration = try Task19.declaration(audioOnly: true)
        declaration.token = loopbackSession.value
        declaration.itemGeneration = itemGeneration
        self.declaration = declaration
        let candidate = try store.registerAudioCandidate(
            initialization: seed.initialization,
            proof: seed.proof,
            declaration: declaration)
        publisher = try HLSPublicationCoordinator(
            store: store,
            participants: [.init(
                initialization: seed.initialization,
                proof: seed.proof,
                relay: seed.relay,
                candidateTicket: candidate.ticket,
                candidate: candidate,
                aacTerminalBinding: seed.endpointAuthority.terminalBinding)],
            declaration: declaration,
            anchor: .init(mediaOrigin: Task19.time(0),
                          utcMilliseconds: 1_788_912_000_000))
        for (index, packet) in seed.packets.enumerated() {
            _ = try publisher.offer(packet.object, receipt: packet.receipt,
                                    relay: packet.relay,
                                    ticket: publisher.ticket,
                                    now: index >= 6 ? 1_000_000_000 : 0)
        }
        var now: Int64 = 1_000_000_000
        for _ in 0..<8 where publisher.visible?.media.values.allSatisfy({
            $0.text.hasSuffix("#EXT-X-ENDLIST\n")
        }) != true {
            _ = try publisher.publish(ticket: publisher.ticket,
                                      now: now, naturalEnd: true)
            now += 1_000_000_000
        }
        guard publisher.visible?.media.values.allSatisfy({
            $0.text.hasSuffix("#EXT-X-ENDLIST\n")
        }) == true else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }
}

/// Review2 的初始 publication 与 Registry output lifecycle 同源。视频、A/B 两个
/// AAC rendition 都来自真实 system writer，并各自携带 writer 私有 terminal binding；
/// preparation request 只能由该 server 的冻结快照生成，测试不再手写 codec 身份。
private final class FinalReview2InitialPublicationHarness: @unchecked Sendable {
    let store: SealedMediaStore
    let declaration: HLSItemDeclaration
    let publisher: HLSPublicationCoordinator
    let audioEndpointAuthority: AACEffectiveEndpointAuthority
    let additionalAudioEndpointAuthority: AACEffectiveEndpointAuthority

    init(loopbackSession: LoopbackSessionToken, seed: Task21RealAVSeed) throws {
        guard let additional = seed.additionalAudio else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        audioEndpointAuthority = seed.endpointAuthority
        additionalAudioEndpointAuthority = additional.endpointAuthority
        store = SealedMediaStore(loopbackSession: loopbackSession, itemGeneration: 19)
        declaration = HLSItemDeclaration(
            itemGeneration: 19,
            token: loopbackSession.value,
            video: .init(participantID: 1, codec: seed.videoCodec,
                width: Int(seed.videoDimensions.width),
                height: Int(seed.videoDimensions.height),
                frameRateMilli: 24_000, videoRange: "SDR",
                peakEnvelope: 81_600_000),
            audio: [
                .init(participantID: 2, renditionID: "aac-2", codec: .aac,
                    channels: 2, language: "en", score: 100,
                    peakEnvelope: 264_000),
                .init(participantID: 4, renditionID: "aac-6", codec: .aac,
                    channels: 6, language: "zh", score: 300,
                    peakEnvelope: 704_000),
            ])
        publisher = try HLSPublicationCoordinator(
            store: store,
            participants: [
                .init(initialization: seed.videoInitialization,
                    proof: seed.videoProof, relay: seed.videoRelay,
                    candidateTicket: nil),
                .init(initialization: seed.audioInitialization,
                    proof: seed.audioProof, relay: seed.audioRelay,
                    candidateTicket: nil,
                    aacTerminalBinding: seed.endpointAuthority.terminalBinding),
                .init(initialization: additional.initialization,
                    proof: additional.proof, relay: additional.relay,
                    candidateTicket: nil,
                    aacTerminalBinding: additional.endpointAuthority.terminalBinding),
            ],
            declaration: declaration,
            anchor: .init(mediaOrigin: seed.sourceOrigin,
                utcMilliseconds: 1_788_912_000_000))
        let packetSets = [seed.videoPackets, seed.audioPackets,
                          additional.packets]
        let maximumCount = packetSets.map(\.count).max() ?? 0
        for index in 0..<maximumCount {
            for packets in packetSets where packets.indices.contains(index) {
                let packet = packets[index]
                _ = try publisher.offer(packet.object, receipt: packet.receipt,
                    relay: packet.relay, ticket: publisher.ticket,
                    now: index >= 6 ? 1_000_000_000 : 0)
            }
        }
        guard let visible = publisher.visible,
              visible.media[2]?.resources.contains(
                seed.endpointAuthority.receipt.terminalMedia.key) == true,
              visible.media[4]?.resources.contains(
                additional.endpointAuthority.receipt.terminalMedia.key) == true else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }
}

private final class FinalReview2InitialHTTPFixture: @unchecked Sendable {
    let publication: FinalReview2InitialPublicationHarness
    let server: LoopbackHTTPServer
    let snapshot: HLSPublishedSnapshot

    private init(publication: FinalReview2InitialPublicationHarness,
                 server: LoopbackHTTPServer,
                 snapshot: HLSPublishedSnapshot) {
        self.publication = publication
        self.server = server
        self.snapshot = snapshot
    }

    static func start(outputLifecycleEpoch: OutputLifecycleEpoch) async throws
        -> FinalReview2InitialHTTPFixture {
        let encoded = try await Task21RealAACSeed.make(
            outputLifecycleEpoch: outputLifecycleEpoch)
        let surround = try await Task21RealAACSeed.make(
            outputLifecycleEpoch: outputLifecycleEpoch,
            layoutLabels: [.c, .l, .r, .ls, .rs, .lfe])
        let seed = try await Task21RealAVSeed.make(
            audio: encoded, additionalAudioSeed: surround,
            additionalAudioParticipantID: 4)
        let box = FinalReview2InitialLockedHarness()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try FinalReview2InitialPublicationHarness(
                loopbackSession: token, seed: seed)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        let publication = try XCTUnwrap(box.value)
        return FinalReview2InitialHTTPFixture(
            publication: publication, server: server,
            snapshot: try XCTUnwrap(publication.publisher.visible))
    }

    func resourceBytes(_ key: HLSResourceKey) throws -> Data {
        let lease = try XCTUnwrap(publication.store.acquireResponse(
            key, token: server.sessionToken, now: 0))
        defer { publication.store.release(lease, now: 0) }
        return lease.withUnsafeBytes { Data($0) }
    }

    func shutdown() {
        let ticket = server.closeAdmission()
        _ = waitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }
}

private final class FinalReview2InitialLockedHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FinalReview2InitialPublicationHarness?
    var value: FinalReview2InitialPublicationHarness? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class Task20HTTPFixture: @unchecked Sendable {
    let task19: Task19Harness
    let server: LoopbackHTTPServer
    let token: String

    private init(task19: Task19Harness, server: LoopbackHTTPServer, token: String) {
        self.task19 = task19
        self.server = server
        self.token = token
    }

    static func start(now: @escaping @Sendable () -> Int64 = { 0 },
                      logger: @escaping @Sendable (String) -> Void = { _ in },
                      responseFailure: @escaping @Sendable (HLSResourceKey, CompletedMediaEvidenceError) -> Void = { _, _ in },
                      testing: LoopbackHTTPTestingConfiguration? = nil,
                      audioCount: Int = 1) async throws -> Task20HTTPFixture {
        let box = LockedHarness()
        let factory = testing.map { LoopbackHTTPSessionFactory(testing: $0) }
            ?? LoopbackHTTPSessionFactory()
        let server = try await factory.start(itemGeneration: 19, now: now,
            logger: logger, responseFailure: responseFailure) { token in
            let harness = try Task19Harness(
                loopbackSession: token, audioCount: audioCount)
            try harness.initial()
            box.value = harness
            var declaration = try Task19.declaration(audioCount: audioCount)
            declaration.token = token.value
            return LoopbackPreparedPublication(store: harness.store, declaration: declaration,
                snapshot: try XCTUnwrap(harness.publisher.visible))
        }
        guard let harness = box.value else { throw LoopbackHTTPServerError.invalidConfiguration }
        return Task20HTTPFixture(task19: harness, server: server, token: server.sessionToken)
    }

    func shutdown() {
        _ = waitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        let ticket = server.closeAdmission()
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }

    func resourceBytes(_ key: HLSResourceKey) throws -> Data {
        let lease = try XCTUnwrap(storeLease(key))
        defer { task19.store.release(lease, now: 0) }
        return lease.withUnsafeBytes { Data($0) }
    }

    private func storeLease(_ key: HLSResourceKey) throws -> HLSMediaResponseLease? {
        try task19.store.acquireResponse(key, token: token, now: 0)
    }
}

private final class LockedHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task19Harness?
    var value: Task19Harness? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64
    init(_ value: Int64) { storage = value }
    var value: Int64 {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedOptionalServer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LoopbackHTTPServer?
    var value: LoopbackHTTPServer? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedEvidenceFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(HLSResourceKey, CompletedMediaEvidenceError)] = []
    var values: [(HLSResourceKey, CompletedMediaEvidenceError)] { lock.withLock { storage } }
    func append(_ value: (HLSResourceKey, CompletedMediaEvidenceError)) {
        lock.withLock { storage.append(value) }
    }
}

private final class ConnectedSocket {
    private var descriptor: Int32
    init(port: UInt16) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw POSIXError(.ECONNREFUSED)
        }
    }
    func sendOnly(_ request: String) throws {
        let sent = request.withCString { Darwin.send(descriptor, $0, strlen($0), 0) }
        guard sent == request.utf8.count else { throw POSIXError(.EIO) }
    }

    func receiveReply() throws -> HTTPReply {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
                       socklen_t(MemoryLayout<timeval>.size))
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try HTTPReply(received)
    }

    func reset() {
        guard descriptor >= 0 else { return }
        var option = linger(l_onoff: 1, l_linger: 0)
        _ = withUnsafePointer(to: &option) {
            setsockopt(descriptor, SOL_SOCKET, SO_LINGER, $0,
                       socklen_t(MemoryLayout<linger>.size))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func sendAndReset(_ request: String) throws {
        try sendOnly(request)
        reset()
    }

    func kernelEndpoints() throws -> (
        peerFamily: Int32, peerAddress: String, peerPort: UInt16,
        localFamily: Int32, localAddress: String, localPort: UInt16
    ) {
        let peer = try endpoint(getpeername)
        let local = try endpoint(getsockname)
        return (peer.family, peer.address, peer.port,
                local.family, local.address, local.port)
    }

    private func endpoint(_ query: (Int32, UnsafeMutablePointer<sockaddr>,
                                    UnsafeMutablePointer<socklen_t>) -> Int32) throws
        -> (family: Int32, address: String, port: UInt16) {
        var value = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                query(descriptor, $0, &length)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = value.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let addressBytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return (Int32(value.sin_family), String(decoding: addressBytes, as: UTF8.self),
                UInt16(bigEndian: value.sin_port))
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

private func waitUntil(timeout: TimeInterval = 2,
                       condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    } while Date() < deadline
    return condition()
}
