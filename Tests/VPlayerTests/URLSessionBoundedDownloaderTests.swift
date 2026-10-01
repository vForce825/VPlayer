// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network
import XCTest
@testable import VPlayerCore

@MainActor
final class URLSessionBoundedDownloaderTests: XCTestCase {
    nonisolated(unsafe) private var downloadsDirectory: URL!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "URLSessionBoundedDownloaderTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
    }

    func testRefreshRequestAdapterUsesExactResourceCaps() async {
        let url = URL(string: "https://example.test/resource")!
        let (downloader, _) = makeDownloader()

        for (resource, limit) in [
            (RefreshResource.playlist, Int64(10 * 1_024 * 1_024)),
            (.epg, Int64(200 * 1_024 * 1_024))
        ] {
            StubURLProtocol.enqueue(.init(
                response: .http(statusCode: 200, headers: ["Content-Length": "\(limit + 1)"])
            ))

            let error = await captureError {
                try await downloader.download(RemoteResourceRequest(url: url, resource: resource))
            }

            XCTAssertEqual(error as? RemoteDownloadError, .responseTooLarge(limit: limit))
        }
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testExactLimitSucceedsAcrossChunksAndTransfersFileOwnership() async throws {
        StubURLProtocol.enqueue(.init(chunks: [Data("1234".utf8), Data("567890".utf8)]))
        let (downloader, configuration) = makeDownloader()
        let boundedDownloader: any BoundedHTTPDownloading = downloader

        let result = try await boundedDownloader.download(url: request().url, byteLimit: 10)

        XCTAssertEqual(result.byteCount, 10)
        XCTAssertEqual(try Data(contentsOf: result.temporaryFileURL), Data("1234567890".utf8))
        XCTAssertEqual(result.temporaryFileURL.deletingLastPathComponent(), downloadsDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.temporaryFileURL.path))
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 180)
        XCTAssertTrue(configuration.waitsForConnectivity)
        try FileManager.default.removeItem(at: result.temporaryFileURL)
    }

    func testSequentialDownloadsReuseOneSession() async throws {
        SessionIdentityURLProtocol.reset()
        defer { SessionIdentityURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionIdentityURLProtocol.self]
        let downloader = URLSessionBoundedDownloader(
            configuration: configuration,
            downloadsDirectory: downloadsDirectory
        )

        for index in 0..<2 {
            let result = try await downloader.download(
                url: URL(string: "https://session-identity.example/logo-\(index).png")!,
                byteLimit: 16
            )
            XCTAssertEqual(try Data(contentsOf: result.temporaryFileURL), Data("logo".utf8))
            try FileManager.default.removeItem(at: result.temporaryFileURL)
        }

        let taskIdentifiers = SessionIdentityURLProtocol.taskIdentifiers
        XCTAssertEqual(taskIdentifiers.count, 2)
        XCTAssertEqual(taskIdentifiers, [1, 2], "同一 URLSession 的 taskIdentifier 应连续增长")
    }

    func testConcurrentDownloadsKeepTheirLimitsAndTemporaryFilesIndependent() async throws {
        StubURLProtocol.enqueue(.init(
            chunks: [Data("small".utf8)], callbackDelay: 0.1
        ))
        StubURLProtocol.enqueue(.init(
            chunks: [Data("large".utf8)], callbackDelay: 0.1
        ))
        let (downloader, _) = makeDownloader()
        let smallURL = URL(string: "https://example.test/small.png")!
        let largeURL = URL(string: "https://example.test/large.png")!

        let small = Task { try await downloader.download(url: smallURL, byteLimit: 4) }
        await waitUntil { StubURLProtocol.requests.count == 1 }
        let large = Task { try await downloader.download(url: largeURL, byteLimit: 5) }
        let smallError = await captureError { try await small.value }
        let largeResource = try await large.value

        XCTAssertEqual(smallError as? RemoteDownloadError, .responseTooLarge(limit: 4))
        XCTAssertEqual(try Data(contentsOf: largeResource.temporaryFileURL), Data("large".utf8))
        try FileManager.default.removeItem(at: largeResource.temporaryFileURL)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testUnknownLengthOverflowFailsAtElevenBytesAndRemovesPartialFile() async {
        StubURLProtocol.enqueue(.init(chunks: [Data("123456".utf8), Data("78901".utf8)]))
        let (downloader, _) = makeDownloader()

        let error = await captureError {
            try await downloader.download(url: self.request().url, byteLimit: 10)
        }

        XCTAssertEqual(error as? RemoteDownloadError, .responseTooLarge(limit: 10))
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testDeclaredLengthOverLimitRejectsBeforeWritingBody() async {
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200, headers: ["Content-Length": "11"]),
            chunks: [Data("12345678901".utf8)]
        ))
        let (downloader, _) = makeDownloader()

        let error = await captureError {
            try await downloader.download(url: self.request().url, byteLimit: 10)
        }

        XCTAssertEqual(error as? RemoteDownloadError, .responseTooLarge(limit: 10))
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testHTTPErrorAndNonHTTPResponseAreRejectedAndCleaned() async {
        StubURLProtocol.enqueue(.init(response: .http(statusCode: 500), chunks: [Data("secret".utf8)]))
        StubURLProtocol.enqueue(.init(response: .nonHTTP, chunks: [Data("body".utf8)]))
        let (downloader, _) = makeDownloader()

        let httpError = await captureError {
            try await downloader.download(url: self.request().url, byteLimit: 10)
        }
        let invalidError = await captureError {
            try await downloader.download(url: self.request().url, byteLimit: 10)
        }

        XCTAssertEqual(httpError as? RemoteDownloadError, .httpStatus(500))
        XCTAssertEqual(invalidError as? RemoteDownloadError, .invalidResponse)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testCancellationClosesAndRemovesPartialFile() async {
        StubURLProtocol.enqueue(.init(
            chunks: [Data("partial".utf8), Data("late".utf8), Data("later".utf8)],
            completes: false,
            callbackDelay: 0.05
        ))
        let (downloader, _) = makeDownloader()
        let operation = Task { try await downloader.download(url: self.request().url, byteLimit: 100) }
        await waitUntil { StubURLProtocol.deliveredChunkCount == 1 }

        operation.cancel()
        let error = await captureError { try await operation.value }
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(error as? RemoteDownloadError, .cancelled)
        XCTAssertEqual(StubURLProtocol.deliveredChunkCount, 1)
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopLoadingCount, 1)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testNonRemoteSchemeIsRejectedWithoutStartingURLSession() async {
        let (downloader, _) = makeDownloader()
        let fileURL = URL(fileURLWithPath: "/tmp/list.m3u")

        let error = await captureError {
            try await downloader.download(url: fileURL, byteLimit: 10)
        }

        XCTAssertEqual(error as? RemoteDownloadError, .invalidResponse)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testValidRemoteRedirectIsFollowedAndDownloaded() async throws {
        let redirectedURL = URL(string: "https://cdn.example.test/list.m3u")!
        StubURLProtocol.enqueue(.init(response: .redirect(location: redirectedURL)))
        StubURLProtocol.enqueue(.init(chunks: [Data("redirected".utf8)]))
        let (downloader, _) = makeDownloader()

        let result = try await downloader.download(url: request().url, byteLimit: 10)

        XCTAssertEqual(try Data(contentsOf: result.temporaryFileURL), Data("redirected".utf8))
        XCTAssertEqual(StubURLProtocol.requests.compactMap(\.url), [request().url, redirectedURL])
        try FileManager.default.removeItem(at: result.temporaryFileURL)
    }

    func testFileCustomAndHostlessRedirectsAreRejectedBeforeWriting() async {
        let invalidTargets = [
            URL(fileURLWithPath: "/tmp/redirected-list.m3u"),
            URL(string: "vplayer://receiver/list.m3u")!,
            URL(string: "https:/missing-host/list.m3u")!
        ]

        for target in invalidTargets {
            StubURLProtocol.enqueue(.init(response: .redirect(location: target)))
            let (downloader, _) = makeDownloader()

            let error = await captureError {
                try await downloader.download(url: self.request().url, byteLimit: 10)
            }

            XCTAssertEqual(error as? RemoteDownloadError, .invalidResponse, target.absoluteString)
            await assertDownloadsDirectoryBecomesEmpty()
        }
        XCTAssertEqual(StubURLProtocol.requests.count, invalidTargets.count)
    }

    func testFinalHTTPResponseURLMustRemainRemoteBeforeWriting() async {
        StubURLProtocol.enqueue(.init(
            response: .httpAt(
                url: URL(fileURLWithPath: "/tmp/final-list.m3u"),
                statusCode: 200
            ),
            chunks: [Data("must-not-be-written".utf8)]
        ))
        let (downloader, _) = makeDownloader()

        let error = await captureError {
            try await downloader.download(url: self.request().url, byteLimit: 100)
        }

        XCTAssertEqual(error as? RemoteDownloadError, .invalidResponse)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testNonpositiveByteLimitIsRejectedWithoutStartingURLSession() async {
        let (downloader, _) = makeDownloader()

        for limit: Int64 in [0, -1] {
            let error = await captureError {
                try await downloader.download(url: self.request().url, byteLimit: limit)
            }

            XCTAssertEqual(error as? RemoteDownloadError, .invalidResponse)
        }

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testRedactedURLRemovesCredentialsQueryAndFragment() {
        XCTAssertEqual(
            RedactedURL.string(
                URL(string: "https://user:pass@example.test/list?token=secret#x")!
            ),
            "https://example.test/list"
        )
    }

    func testRedactedURLRemovesUserWithoutPassword() {
        XCTAssertEqual(
            RedactedURL.string(URL(string: "https://user@example.test/list")!),
            "https://example.test/list"
        )
    }

    func testRedactedURLLeavesNormalURLUnchanged() {
        XCTAssertEqual(
            RedactedURL.string(URL(string: "https://example.test/list.m3u")!),
            "https://example.test/list.m3u"
        )
    }

    func testEPERMMappingsAreRestrictedToLocalHosts() {
        let permissionError = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EPERM)
                )
            ]
        )

        let local = NetworkFailureMapper.map(
            permissionError,
            for: URL(string: "http://iptv.router/list.m3u")!
        )
        let publicHost = NetworkFailureMapper.map(
            permissionError,
            for: URL(string: "https://example.com/list.m3u")!
        )

        XCTAssertEqual(local.code, "network.localPermissionDenied")
        XCTAssertTrue(local.message.contains("请在“设置”中允许 VPlayer 访问本地网络后重试。"))
        XCTAssertTrue(local.message.contains("NSPOSIXErrorDomain(1)"))
        XCTAssertTrue(local.message.contains("NSURLErrorDomain(-1004)"))
        XCTAssertEqual(publicHost.code, "network.connectionFailed")
        XCTAssertTrue(publicHost.message.contains("NSPOSIXErrorDomain(1)"))
        XCTAssertFalse(publicHost.message.contains("允许 VPlayer 访问本地网络"))
        XCTAssertNotEqual(publicHost.message, local.message)
    }

    func testNetworkFailuresDistinguishCausesAndPreserveSystemCodes() {
        let cases: [(URLError.Code, String)] = [
            (.timedOut, "network.timeout"),
            (.cannotFindHost, "network.dns"),
            (.dnsLookupFailed, "network.dns"),
            (.cannotConnectToHost, "network.connectionFailed"),
            (.notConnectedToInternet, "network.offline"),
            (.secureConnectionFailed, "network.tls"),
            (.serverCertificateUntrusted, "network.tls"),
            (.cancelled, "network.cancelled")
        ]
        for (code, expected) in cases {
            let failure = NetworkFailureMapper.map(
                URLError(code), for: URL(string: "https://example.test/live")!
            )
            XCTAssertEqual(failure.code, expected, "系统错误码 \(code.rawValue)")
            XCTAssertTrue(failure.message.contains(NSURLErrorDomain))
            XCTAssertTrue(failure.message.contains(String(code.rawValue)))
        }
    }

    func testUnknownNetworkFailurePreservesItsTypeAndReasonWithoutAddresses() {
        let failure = NetworkFailureMapper.map(
            DiagnosticDownloadError(
                errorDescription: "解码资源失败，原因标记 codec-42；https://user:pass@example.test/live?token=secret；/Users/private/cache.bin"
            ),
            for: URL(string: "https://example.test/live")!
        )
        XCTAssertEqual(failure.code, "network.unknown")
        XCTAssertTrue(failure.message.contains("DiagnosticDownloadError"))
        XCTAssertTrue(failure.message.contains("codec-42"))
        XCTAssertFalse(failure.message.contains("example.test"))
        XCTAssertFalse(failure.message.contains("secret"))
        XCTAssertFalse(failure.message.contains("/Users/private"))
    }

    func testDiagnosticSnapshotBoundsUnicodeTextAndPreservesTheErrorCode() {
        let snapshot = ErrorDiagnosticSnapshot(
            typeName: String(repeating: "错误类型", count: 100),
            code: "diagnostic.code.42",
            message: String(repeating: "中文原始说明", count: 200)
        )
        XCTAssertLessThanOrEqual(snapshot.typeName.utf8.count, 128)
        XCTAssertLessThanOrEqual(snapshot.summary.utf8.count, 128 + 3 + 256)
        XCTAssertTrue(snapshot.summary.contains("diagnostic.code.42"))
        XCTAssertFalse(snapshot.summary.contains("�"))
        XCTAssertEqual(String(describing: snapshot), snapshot.summary)
        XCTAssertEqual(ErrorDiagnosticSnapshot(snapshot), snapshot)
    }

    func testDiagnosticSnapshotDoesNotRetainTheOriginalError() {
        weak var original: NSError?
        let snapshot = autoreleasepool {
            let error = NSError(domain: "OriginalDomain", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "原始说明 codec-42"
            ])
            original = error
            return ErrorDiagnosticSnapshot(error)
        }
        XCTAssertNil(original)
        XCTAssertTrue(snapshot.summary.contains("OriginalDomain(42)"))
        XCTAssertTrue(snapshot.summary.contains("codec-42"))
    }

    func testWrappedNetworkFailureIncludesUnderlyingCause() {
        let error = NSError(domain: "OuterDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "下载请求失败",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [
                NSLocalizedDescriptionKey: "原始超时说明"
            ])
        ])
        let failure = NetworkFailureMapper.map(error, for: URL(string: "https://example.test/live")!)
        XCTAssertEqual(failure.code, "network.timeout")
        XCTAssertTrue(failure.message.contains("OuterDomain(42)"))
        XCTAssertTrue(failure.message.contains("NSURLErrorDomain(-1001)"))
        XCTAssertTrue(failure.message.contains("原始超时说明"))
    }

    func testWrappedStorageFailureIsNotClassifiedAsNetworkFailure() {
        let error = NSError(domain: "StoreDomain", code: 42, userInfo: [
            NSUnderlyingErrorKey: CocoaError(.fileWriteOutOfSpace)
        ])
        XCTAssertFalse(NetworkFailureMapper.isNetworkError(error))
    }

    func testNetworkPOSIXErrorsDistinguishTimeoutConnectionAndOffline() {
        let cases: [(POSIXErrorCode, String)] = [
            (.ETIMEDOUT, "network.timeout"),
            (.ECONNREFUSED, "network.connectionFailed"),
            (.ENETUNREACH, "network.offline")
        ]
        for (code, expected) in cases {
            let failure = NetworkFailureMapper.map(
                NWError.posix(code), for: URL(string: "https://example.test/live")!
            )
            XCTAssertEqual(failure.code, expected)
            XCTAssertTrue(failure.message.contains(String(code.rawValue)))
        }
    }

    func testDNSPolicyDenialMapsOnlyForLocalHosts() {
        let policyDenied = NWError.dns(-65_570)

        XCTAssertEqual(
            NetworkFailureMapper.map(
                policyDenied,
                for: URL(string: "http://receiver.local/list.m3u")!
            ).code,
            "network.localPermissionDenied"
        )
        XCTAssertEqual(
            NetworkFailureMapper.map(
                policyDenied,
                for: URL(string: "https://example.com/list.m3u")!
            ).code,
            "network.dns"
        )
    }

    func testLocalHostClassifierCoversPrivateLoopbackAndLocalSuffixesConservatively() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let localURLs = [
            "http://router/list",
            "http://box.local/list",
            "http://box.lan/list",
            "http://box.home.arpa/list",
            "http://127.0.0.1/list",
            "http://10.0.0.1/list",
            "http://172.31.0.1/list",
            "http://192.168.1.1/list",
            "http://169.254.1.1/list",
            "http://[::1]/list",
            "http://[fe80::1]/list"
        ]

        for value in localURLs {
            XCTAssertEqual(
                NetworkFailureMapper.map(error, for: URL(string: value)!).code,
                "network.localPermissionDenied",
                value
            )
        }
        for value in ["https://example.com/list", "http://172.32.0.1/list", "http://8.8.8.8/list"] {
            XCTAssertEqual(
                NetworkFailureMapper.map(error, for: URL(string: value)!).code,
                "network.connectionFailed",
                value
            )
        }
    }

    private func makeDownloader() -> (URLSessionBoundedDownloader, URLSessionConfiguration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (
            URLSessionBoundedDownloader(
                configuration: configuration,
                downloadsDirectory: downloadsDirectory
            ),
            configuration
        )
    }

    private func request() -> RemoteResourceRequest {
        RemoteResourceRequest(
            url: URL(string: "https://example.test/list.m3u")!,
            resource: .playlist
        )
    }

    private func downloadedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func assertDownloadsDirectoryBecomesEmpty(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil { self.downloadedFiles().isEmpty }
        XCTAssertTrue(downloadedFiles().isEmpty, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func captureError<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> (any Error)? {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }
}

private struct DiagnosticDownloadError: LocalizedError, Sendable {
    let errorDescription: String?
}

private final class SessionIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var identifiers: [Int] = []

        func append(_ identifier: Int) {
            lock.withLock { identifiers.append(identifier) }
        }

        var snapshot: [Int] {
            lock.withLock { identifiers }
        }

        func reset() {
            lock.withLock { identifiers.removeAll() }
        }
    }

    private static let state = State()

    static var taskIdentifiers: [Int] { state.snapshot }
    static func reset() { state.reset() }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "session-identity.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.append(task?.taskIdentifier ?? -1)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("logo".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
