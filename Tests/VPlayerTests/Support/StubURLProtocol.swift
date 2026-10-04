// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Withholds one chunk without blocking a URLSession or callback queue.
    final class ChunkDeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private let onDeliveryAttempt: @Sendable () -> Void
        private var isReleased = false
        private var pendingDelivery: (@Sendable () -> Void)?

        init(onDeliveryAttempt: @escaping @Sendable () -> Void) {
            self.onDeliveryAttempt = onDeliveryAttempt
        }

        fileprivate func deliverWhenReleased(_ operation: @escaping @Sendable () -> Void) {
            let delivery: @Sendable () -> Void = { [onDeliveryAttempt] in
                operation()
                onDeliveryAttempt()
            }
            let deliverNow = lock.withLock {
                if isReleased { return true }
                precondition(pendingDelivery == nil, "Use a separate gate for each chunk")
                pendingDelivery = delivery
                return false
            }
            if deliverNow { delivery() }
        }

        func release() {
            let delivery = lock.withLock {
                isReleased = true
                let delivery = pendingDelivery
                pendingDelivery = nil
                return delivery
            }
            delivery?()
        }
    }

    struct Plan: @unchecked Sendable {
        enum Response: @unchecked Sendable {
            case http(statusCode: Int, headers: [String: String] = [:])
            case httpAt(url: URL, statusCode: Int, headers: [String: String] = [:])
            case redirect(statusCode: Int = 302, location: URL)
            case nonHTTP
            case none
        }

        var response: Response
        var chunks: [Data]
        var error: NSError?
        var completes: Bool
        var callbackDelay: TimeInterval
        var chunkDeliveryGates: [Int: ChunkDeliveryGate]

        init(
            response: Response = .http(statusCode: 200),
            chunks: [Data] = [],
            error: NSError? = nil,
            completes: Bool = true,
            callbackDelay: TimeInterval = 0.001,
            chunkDeliveryGates: [Int: ChunkDeliveryGate] = [:]
        ) {
            self.response = response
            self.chunks = chunks
            self.error = error
            self.completes = completes
            self.callbackDelay = callbackDelay
            self.chunkDeliveryGates = chunkDeliveryGates
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [Plan] = []
        private var requests: [URLRequest] = []
        private var stopCount = 0
        private var deliveredChunkCount = 0

        func enqueue(_ plan: Plan) {
            lock.withLock { plans.append(plan) }
        }

        func takePlan(for request: URLRequest) -> Plan? {
            lock.withLock {
                requests.append(request)
                guard !plans.isEmpty else { return nil }
                return plans.removeFirst()
            }
        }

        func recordStop() {
            lock.withLock { stopCount += 1 }
        }

        func recordDeliveredChunk() {
            lock.withLock { deliveredChunkCount += 1 }
        }

        func snapshot() -> (requests: [URLRequest], stopCount: Int, deliveredChunkCount: Int) {
            lock.withLock { (requests, stopCount, deliveredChunkCount) }
        }

        func reset() {
            lock.withLock {
                plans = []
                requests = []
                stopCount = 0
                deliveredChunkCount = 0
            }
        }
    }

    private static let state = State()
    private static let callbackQueue = DispatchQueue(
        label: "VPlayerTests.StubURLProtocol.callbacks",
        attributes: .concurrent
    )
    private let deliveryLock = NSLock()
    private var isStopped = false

    static func enqueue(_ plan: Plan) {
        state.enqueue(plan)
    }

    static var requests: [URLRequest] {
        state.snapshot().requests
    }

    static var stopLoadingCount: Int {
        state.snapshot().stopCount
    }

    static var deliveredChunkCount: Int {
        state.snapshot().deliveredChunkCount
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let plan = Self.state.takePlan(for: request) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        schedule(after: plan.callbackDelay) { [self] in
            deliverResponse(for: plan)
        }
    }

    private func deliverResponse(for plan: Plan) {
        guard !stopped else { return }
        switch plan.response {
        case let .http(statusCode, headers):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case let .httpAt(url, statusCode, headers):
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case let .redirect(statusCode, location):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: location),
                redirectResponse: response
            )
            return
        case .nonHTTP:
            client?.urlProtocol(
                self,
                didReceive: URLResponse(
                    url: request.url!,
                    mimeType: nil,
                    expectedContentLength: -1,
                    textEncodingName: nil
                ),
                cacheStoragePolicy: .notAllowed
            )
        case .none:
            break
        }

        deliver(plan: plan, chunkAt: 0)
    }

    private func deliver(plan: Plan, chunkAt index: Int) {
        if let gate = plan.chunkDeliveryGates[index] {
            gate.deliverWhenReleased { [self] in
                deliverChunk(plan: plan, at: index)
            }
        } else {
            deliverChunk(plan: plan, at: index)
        }
    }

    private func deliverChunk(plan: Plan, at index: Int) {
        // Recheck after a gate opens, including when stopLoading arrived before
        // the withheld callback was scheduled.
        guard !stopped else { return }
        guard index < plan.chunks.count else {
            if let error = plan.error {
                client?.urlProtocol(self, didFailWithError: error)
            } else if plan.completes {
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        Self.state.recordDeliveredChunk()
        client?.urlProtocol(self, didLoad: plan.chunks[index])
        schedule(after: plan.callbackDelay) { [self] in
            deliver(plan: plan, chunkAt: index + 1)
        }
    }

    override func stopLoading() {
        deliveryLock.withLock { isStopped = true }
        Self.state.recordStop()
    }

    private var stopped: Bool {
        deliveryLock.withLock { isStopped }
    }

    private func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) {
        Self.callbackQueue.asyncAfter(deadline: .now() + delay, execute: operation)
    }
}
