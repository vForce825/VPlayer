// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

final class HLSProxyBackpressureTests: XCTestCase {
    func testKnownBodyEnvelopePrepaysWholeCoalescedCallbackAndEveryHeldAlias() throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        try withExtendedLifetime(transfer) {
            let baseline = budget.usage.bytes
            var envelope: HLSProxyBudget.BodyEnvelope? = try transfer.reserveBodyEnvelope(responseLength: 720_040)
            XCTAssertEqual(envelope?.maximumCallbackBytes, 720_040)
            XCTAssertEqual(budget.usage.bytes, baseline + 2 * 720_040)
            XCTAssertTrue(try XCTUnwrap(envelope).accepts(393_216), "Observed ordinary CFNetwork callback")
            XCTAssertFalse(try XCTUnwrap(envelope).accepts(720_041))
            var nativeSendAlias = envelope
            envelope = nil
            XCTAssertEqual(budget.usage.bytes, baseline + 2 * 720_040)
            withExtendedLifetime(nativeSendAlias) {}
            nativeSendAlias = nil
            XCTAssertEqual(budget.usage.bytes, baseline)
        }
    }

    func testUnknownAndLargeResponseEnvelopesShareExistingDomainAndTransferCaps() throws {
        let budget = try HLSProxyBudget()
        let baseline = budget.usage.bytes
        var transfers: [HLSProxyBudget.Lease] = []
        var envelopes: [HLSProxyBudget.BodyEnvelope] = []
        for index in 0..<8 {
            let transfer = try budget.admitTransfer()
            transfers.append(transfer)
            let envelope = try transfer.reserveBodyEnvelope(responseLength: index.isMultiple(of: 2) ? nil : 32 * 1_024 * 1_024)
            envelopes.append(envelope)
            XCTAssertEqual(envelope.maximumCallbackBytes, 1_024 * 1_024)
            XCTAssertTrue(envelope.accepts(327_680), "Observed ordinary CFNetwork callback")
            XCTAssertFalse(envelope.accepts(1_024 * 1_024 + 1))
        }
        XCTAssertEqual(HLSProxyBudget.domainBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(HLSProxyBudget.maximumTransfers, 8)
        XCTAssertEqual(HLSProxyBudget.maximumConnections, 16)
        XCTAssertEqual(budget.usage.bytes, baseline + 8 * (512 * 1_024 + 2 * 1_024 * 1_024))
        XCTAssertLessThanOrEqual(budget.usage.bytes, HLSProxyBudget.domainBytes)
        XCTAssertThrowsError(try budget.admitTransfer())
        envelopes.removeAll()
        transfers.removeAll()
        XCTAssertEqual(budget.usage.bytes, baseline)
        XCTAssertEqual(budget.usage.transfers, 0)
    }

    func testBodyEnvelopeFailsBeforeAdmissionWhenSharedDomainCannotPay() throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        let remaining = HLSProxyBudget.domainBytes - budget.usage.bytes
        let occupied = try budget.reserve(bytes: remaining - 2 * HLSProxyBudget.transferBufferBytes + 1)
        try withExtendedLifetime((transfer, occupied)) {
            let before = budget.usage.bytes
            XCTAssertThrowsError(try transfer.reserveBodyEnvelope(responseLength: nil))
            XCTAssertEqual(budget.usage.bytes, before)
            XCTAssertEqual(budget.usage.transfers, 1)
        }
    }

    func testQueuedCallbackAfterCancellationCannotEnterAnotherHeldBodyOrSend() throws {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL,
            generation: 1, topology: .media(Data([0x47])))
        let budget = try HLSProxyBudget()
        let registry = try HLSProxyResourceRegistry(source: source, budget: budget)
        let path = try registry.register(url: context.entryURL, kind: .segment, mediaType: .transportStream)
        let io = HLSProxyIOCounters()
        // No socket or URLSession task is started. Deliver an ordinary queued
        // delegate callback after the real cancel path has revoked admission.
        let connection = HLSProxyConnection(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            lease: try budget.admitConnection(), io: io)
        let upstream = HLSProxyUpstream(resource: try registry.lease(path: path), method: .get,
            range: nil, connection: connection, transfer: try budget.admitTransfer())
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: context.entryURL)
        defer { task.cancel(); session.invalidateAndCancel() }
        upstream.cancel()
        let baseline = budget.usage.bytes
        let rejectedResponse = expectation(description: "Late response rejected before body reservation")
        let response = try XCTUnwrap(HTTPURLResponse(url: context.entryURL, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "720040"]))
        upstream.urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
            rejectedResponse.fulfill()
        }
        wait(for: [rejectedResponse], timeout: 1)
        upstream.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x47, count: 393_216))
        XCTAssertEqual(io.snapshot.callbacks, 0)
        XCTAssertEqual(io.snapshot.peakCallbacks, 0)
        XCTAssertEqual(io.snapshot.largestCallback, 0)
        XCTAssertEqual(io.snapshot.pendingSendAliases, 0)
        XCTAssertEqual(io.snapshot.peakPendingSendAliases, 0)
        XCTAssertEqual(budget.usage.bytes, baseline)
    }

    func testOrdinaryLargeRangedResponseRemainsByteExactAndReleasesBodyEnvelope() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        XCTAssertGreaterThan(media.count, 393_216)
        XCTAssertLessThan(media.count, HLSProxyBudget.transferBufferBytes)
        let origin = try NativeHLSHTTPFixture(resources: [
            "/media.ts": .init(data: media, contentType: "video/mp2t")], credential: "ordinary proxy fixture")
        let context = try sourceContext(url: origin.url("media.ts"), attributes: ["Authorization": "ordinary proxy fixture"])
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(media.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let client = URLSession(configuration: .ephemeral)
        var failure: (any Error)?
        do {
            var request = URLRequest(url: proxy.itemURL)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let result = try await client.data(for: request)
            let response = try XCTUnwrap(result.1 as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(media.count - 1)/\(media.count)")
            XCTAssertEqual(result.0, media)
            XCTAssertEqual(proxy.observedIO.rejectedOversizedCallbacks, 0)
            XCTAssertEqual(proxy.observedIO.peakCallbacks, 1)
            XCTAssertLessThanOrEqual(proxy.observedIO.peakCallbackBytes, media.count)
            XCTAssertEqual(origin.deniedCount, 0)
        } catch { failure = error }
        client.invalidateAndCancel()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.callbacks, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
        if let failure { throw failure }
    }

    func testInterruptedKnownLengthOriginReleasesBodyEnvelopeAfterFailedRead() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        let origin = try NativeHLSHTTPFixture(resources: ["/media.ts": .init(data: media,
            contentType: "video/mp2t", disconnectAfterBodyBytes: 64 * 1_024)])
        let context = try sourceContext(url: origin.url("media.ts"))
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(media.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let client = URLSession(configuration: .ephemeral)
        var rejected = false
        do { _ = try await client.data(from: proxy.itemURL) } catch { rejected = true }
        client.invalidateAndCancel()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(rejected, "A truncated known-length upstream response must not appear complete")
        XCTAssertGreaterThan(origin.requestCount, 0)
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.callbacks, 0)
        XCTAssertEqual(proxy.observedIO.callbackBytes, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
    }

    func testSlowNativeSocketReaderBackpressuresOneUpstreamCallbackAndCancellationJoins() async throws {
        // Virtual 32 MiB ordinary source from one 512 KiB block. The fixture sends
        // only one 32 KiB chunk at a time; it does not allocate a 32 MiB copy.
        let block = Data(repeating: 0x47, count: 512 * 1_024)
        let origin = try NativeHLSHTTPFixture(resources: ["/stream.ts": .init(data: block, contentType: "video/mp2t", repetitions: 64)])
        let context = try sourceContext(url: origin.url("stream.ts"))
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(block.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let reader = SlowProxySocket()
        var failure: (any Error)?
        do {
            try await reader.start(proxy.itemURL)
            let deadline = ContinuousClock.now + .seconds(5)
            while proxy.observedIO.callbackBytes == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard proxy.observedIO.callbackBytes > 0 else {
                let observed = proxy.observedIO
                XCTFail("No held proxy data callback: peak=\(observed.peakCallbackBytes) " +
                    "largest=\(observed.largestCallback) rejected=\(observed.rejectedOversizedCallbacks) " +
                    "pending-send=\(observed.pendingSendAliases) transfers=\(proxy.admissionUsage.transfers) " +
                    "origin-requests=\(origin.requestCount)")
                throw HLSSourceError.deadline
            }
            // No reads are registered. Wait while the native send holds the one
            // original data callback; this verifies the real socket/delegate path.
            try await Task.sleep(for: .milliseconds(50))
            let observed = proxy.observedIO
            XCTAssertGreaterThan(observed.callbackBytes, 0, "A callback must still be held after the no-read interval")
            XCTAssertGreaterThan(observed.pendingSendAliases, 0)
            XCTAssertEqual(observed.callbacks, 1)
            XCTAssertEqual(observed.peakCallbacks, 1)
            XCTAssertGreaterThan(observed.peakCallbackBytes, 0)
            XCTAssertGreaterThanOrEqual(proxy.admissionUsage.bytes, 2 * HLSProxyBudget.transferBufferBytes,
                "The body window must remain prepaid while native send is blocked")
            XCTAssertLessThanOrEqual(observed.peakCallbackBytes, HLSProxyBudget.transferBufferBytes)
            XCTAssertLessThanOrEqual(observed.largestCallback, HLSProxyBudget.transferBufferBytes)
            XCTAssertLessThanOrEqual(observed.peakPendingSendAliases, HLSProxyBudget.transferBufferBytes + 16 * 1_024)
            XCTAssertEqual(observed.rejectedOversizedCallbacks, 0)
            XCTAssertEqual(proxy.admissionUsage.transfers, 1)
            XCTAssertLessThanOrEqual(proxy.admissionUsage.bytes, HLSProxyBudget.domainBytes)
        } catch { failure = error }
        await reader.close()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.callbackBytes, 0)
        XCTAssertEqual(proxy.observedIO.callbacks, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
        // These are owned callback/lease bounds, not aggregate SDK-buffer or RSS measurements.
        if let failure { throw failure }
    }
}

private final class SlowProxySocket: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.vplayer.tests.slow-proxy-reader")
    private let callbacks = DispatchGroup()
    private var connection: NWConnection?
    private var ready: CheckedContinuation<Void, any Error>?
    private var stopped: CheckedContinuation<Void, Never>?
    private var done = false
    func start(_ url: URL) async throws {
        guard let port = url.port, let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else { throw HLSSourceError.invalidURL }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.state(state) }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { ready = continuation }
            connection.start(queue: queue)
        }
        let request = Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
        callbacks.enter()
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: request, completion: .contentProcessed { [callbacks] error in
                callbacks.leave()
                if error == nil { continuation.resume() } else { continuation.resume(throwing: HLSSourceError.network) }
            })
        }
    }
    private func state(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let pending = lock.withLock { defer { ready = nil }; return ready }; pending?.resume()
        case .failed: connection?.cancel()
        case .cancelled:
            let values = lock.withLock { done = true; defer { ready = nil; stopped = nil }; return (ready, stopped) }
            values.0?.resume(throwing: HLSSourceError.network); values.1?.resume()
        default: break
        }
    }
    func close() async {
        guard let connection else { return }
        connection.cancel()
        await withCheckedContinuation { continuation in
            let finished = lock.withLock { () -> Bool in if done { return true }; stopped = continuation; return false }
            if finished { continuation.resume() }
        }
        await withCheckedContinuation { continuation in callbacks.notify(queue: queue) { continuation.resume() } }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        connection.stateUpdateHandler = nil
    }
}
