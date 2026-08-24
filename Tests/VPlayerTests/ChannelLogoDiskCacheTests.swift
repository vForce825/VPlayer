// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer
@testable import VPlayerCore

final class ChannelLogoDiskCacheTests: XCTestCase {
    private let maximumByteCount = 8 * 1_024 * 1_024

    func testOversizedEntryIsRejectedAndDeletedBeforeRead() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let oversized = directory.appendingPathComponent("oversized")
        try Data(repeating: 0x41, count: maximumByteCount + 1).write(to: oversized)
        let cache = try ChannelLogoDiskCache(
            directory: directory,
            capacity: maximumByteCount * 2
        )

        let data = await cache.data(
            forKey: "oversized",
            maximumByteCount: maximumByteCount
        )

        XCTAssertNil(data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
    }

    func testExactLimitEntryRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(
            directory: directory,
            capacity: maximumByteCount * 2
        )
        let expected = Data(repeating: 0x42, count: maximumByteCount)

        await cache.store(
            expected,
            forKey: "exact",
            maximumByteCount: maximumByteCount
        )
        let actual = await cache.data(
            forKey: "exact",
            maximumByteCount: maximumByteCount
        )

        XCTAssertEqual(actual, expected)
    }

    func testStoreRejectsEntryOverPerEntryLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(directory: directory, capacity: 100)

        await cache.store(
            Data(repeating: 0x43, count: 5),
            forKey: "too-large",
            maximumByteCount: 4
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("too-large").path
            )
        )
    }

    func testCapacityPruningRemovesLeastRecentlyUsedEntry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(directory: directory, capacity: 6)
        await cache.store(Data("old!".utf8), forKey: "old", maximumByteCount: 6)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: directory.appendingPathComponent("old").path
        )

        await cache.store(Data("new!".utf8), forKey: "new", maximumByteCount: 6)

        let old = await cache.data(forKey: "old", maximumByteCount: 6)
        let new = await cache.data(forKey: "new", maximumByteCount: 6)
        XCTAssertNil(old)
        XCTAssertEqual(new, Data("new!".utf8))
    }

    func testFileLogoLoaderAcceptsExactLimitAndRejectsOneByteOver() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let exactURL = directory.appendingPathComponent("exact.png")
        let oversizedURL = directory.appendingPathComponent("oversized.png")
        try Data(repeating: 0x44, count: maximumByteCount).write(to: exactURL)
        try Data(repeating: 0x45, count: maximumByteCount + 1).write(to: oversizedURL)
        let loader = LiveChannelLogoDataLoader(
            downloader: UnexpectedChannelLogoDownloader(),
            fileManager: .default
        )

        let exact = await loader.data(
            for: exactURL,
            maximumByteCount: maximumByteCount
        )
        let oversized = await loader.data(
            for: oversizedURL,
            maximumByteCount: maximumByteCount
        )

        XCTAssertEqual(exact?.count, maximumByteCount)
        XCTAssertNil(oversized)
    }

    func testRemoteLogoLoaderRejectsMismatchedReportedByteCountsAndDeletesTemporaryFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload = Data("logo".utf8)
        let cases: [(name: String, reportedByteCount: Int64)] = [
            ("under-reported", Int64(payload.count - 1)),
            ("over-reported", Int64(payload.count + 1)),
        ]

        for testCase in cases {
            let temporaryFileURL = directory.appendingPathComponent(testCase.name)
            try payload.write(to: temporaryFileURL)
            let loader = LiveChannelLogoDataLoader(
                downloader: FixedDownloadedResourceChannelLogoDownloader(
                    resource: DownloadedResource(
                        temporaryFileURL: temporaryFileURL,
                        byteCount: testCase.reportedByteCount
                    )
                ),
                fileManager: .default
            )
            let remoteURL = try XCTUnwrap(
                URL(string: "https://images.example/\(testCase.name).png")
            )

            let data = await loader.data(
                for: remoteURL,
                maximumByteCount: maximumByteCount
            )

            XCTAssertNil(data, testCase.name)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: temporaryFileURL.path),
                testCase.name
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChannelLogoDiskCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct UnexpectedChannelLogoDownloader: BoundedHTTPDownloading {
    func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource {
        _ = url
        _ = byteLimit
        throw UnexpectedChannelLogoDownloaderError.called
    }
}

private struct FixedDownloadedResourceChannelLogoDownloader: BoundedHTTPDownloading {
    let resource: DownloadedResource

    func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource {
        _ = url
        _ = byteLimit
        return resource
    }
}

private enum UnexpectedChannelLogoDownloaderError: Error {
    case called
}
