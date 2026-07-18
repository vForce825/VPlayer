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
            .appendingPathComponent("URLSessionBoundedDownloaderTests-(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
    }

    func testRemoteResourceRequestsUseExactResourceCaps() {
        let url = URL(string: "https://example.test/resource")!

        XCTAssertEqual(
            RemoteResourceRequest(url: url, resource: .playlist).byteLimit,
            10 * 1_024 * 1_024
        )
        XCTAssertEqual(
            RemoteResourceRequest(url: url, resource: .epg).byteLimit,
            200 * 1_024 * 1_024
        )
    }

    func testExactLimitSucceedsAcrossChunksAndTransfersFileOwnership() async throws {
        StubURLProtocol.enqueue(.init(chunks: [Data("1234".utf8), Data("567890".utf8)]))
        let (downloader, configuration) = makeDownloader(limit: 10)

        let result = try await downloader.download(request())

        XCTAssertEqual(result.byteCount, 10)
        XCTAssertEqual(try Data(contentsOf: result.temporaryFileURL), Data("1234567890".utf8))
        XCTAssertEqual(result.temporaryFileURL.deletingLastPathComponent(), downloadsDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.temporaryFileURL.path))
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 180)
        XCTAssertTrue(configuration.waitsForConnectivity)
        try FileManager.default.removeItem(at: result.temporaryFileURL)
    }

    func testUnknownLengthOverflowFailsAtElevenBytesAndRemovesPartialFile() async {
        StubURLProtocol.enqueue(.init(chunks: [Data("123456".utf8), Data("78901".utf8)]))
        let (downloader, _) = makeDownloader(limit: 10)

        let error = await captureError { try await downloader.download(self.request()) }

        XCTAssertEqual(error as? RemoteDownloadError, .responseTooLarge(limit: 10))
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testDeclaredLengthOverLimitRejectsBeforeWritingBody() async {
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200, headers: ["Content-Length": "11"]),
            chunks: [Data("12345678901".utf8)]
        ))
        let (downloader, _) = makeDownloader(limit: 10)

        let error = await captureError { try await downloader.download(self.request()) }

        XCTAssertEqual(error as? RemoteDownloadError, .responseTooLarge(limit: 10))
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testHTTPErrorAndNonHTTPResponseAreRejectedAndCleaned() async {
        StubURLProtocol.enqueue(.init(response: .http(statusCode: 500), chunks: [Data("secret".utf8)]))
        StubURLProtocol.enqueue(.init(response: .nonHTTP, chunks: [Data("body".utf8)]))
        let (downloader, _) = makeDownloader(limit: 10)

        let httpError = await captureError { try await downloader.download(self.request()) }
        let invalidError = await captureError { try await downloader.download(self.request()) }

        XCTAssertEqual(httpError as? RemoteDownloadError, .httpStatus(500))
        XCTAssertEqual(invalidError as? RemoteDownloadError, .invalidResponse)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testCancellationClosesAndRemovesPartialFile() async {
        StubURLProtocol.enqueue(.init(chunks: [Data("partial".utf8)], completes: false))
        let (downloader, _) = makeDownloader(limit: 100)
        let operation = Task { try await downloader.download(request()) }
        await waitUntil { !self.downloadedFiles().isEmpty }

        operation.cancel()
        let error = await captureError { try await operation.value }

        XCTAssertEqual(error as? RemoteDownloadError, .cancelled)
        await assertDownloadsDirectoryBecomesEmpty()
    }

    func testNonRemoteSchemeIsRejectedWithoutStartingURLSession() async {
        let (downloader, _) = makeDownloader(limit: 10)
        let fileRequest = RemoteResourceRequest(
            url: URL(fileURLWithPath: "/tmp/list.m3u"),
            resource: .playlist
        )

        let error = await captureError { try await downloader.download(fileRequest) }

        XCTAssertEqual(error as? RemoteDownloadError, .invalidResponse)
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
        XCTAssertEqual(local.message, "请在“设置”中允许 VPlayer 访问本地网络后重试。")
        XCTAssertEqual(publicHost.code, "network.connectionFailed")
        XCTAssertNotEqual(publicHost.message, local.message)
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
            "network.connectionFailed"
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

    private func makeDownloader(
        limit: Int64
    ) -> (URLSessionBoundedDownloader, URLSessionConfiguration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (
            URLSessionBoundedDownloader(
                configuration: configuration,
                downloadsDirectory: downloadsDirectory,
                byteLimit: { _ in limit }
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
