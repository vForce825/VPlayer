// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

final class HLSProxyBackpressureTests: XCTestCase {
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
            XCTAssertGreaterThan(observed.peakCallbackBytes, 0)
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
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.callbackBytes, 0)
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
