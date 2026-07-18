// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Plan: @unchecked Sendable {
        enum Response: @unchecked Sendable {
            case http(statusCode: Int, headers: [String: String] = [:])
            case nonHTTP
            case none
        }

        var response: Response
        var chunks: [Data]
        var error: NSError?
        var completes: Bool

        init(
            response: Response = .http(statusCode: 200),
            chunks: [Data] = [],
            error: NSError? = nil,
            completes: Bool = true
        ) {
            self.response = response
            self.chunks = chunks
            self.error = error
            self.completes = completes
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [Plan] = []
        private var requests: [URLRequest] = []
        private var stopCount = 0

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

        func snapshot() -> (requests: [URLRequest], stopCount: Int) {
            lock.withLock { (requests, stopCount) }
        }

        func reset() {
            lock.withLock {
                plans = []
                requests = []
                stopCount = 0
            }
        }
    }

    private static let state = State()

    static func enqueue(_ plan: Plan) {
        state.enqueue(plan)
    }

    static var requests: [URLRequest] {
        state.snapshot().requests
    }

    static var stopLoadingCount: Int {
        state.snapshot().stopCount
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

        switch plan.response {
        case let .http(statusCode, headers):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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

        for chunk in plan.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if let error = plan.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else if plan.completes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.state.recordStop()
    }
}
