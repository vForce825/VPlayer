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

    @MainActor
    func testCancelledStoreDoesNotWriteDiskEntry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(directory: directory, capacity: 100)
        let store = Task {
            await cache.store(Data("cancelled".utf8), forKey: "cancelled", maximumByteCount: 100)
        }
        // Cancel before this MainActor task yields and the store enters its actor.
        store.cancel()
        await store.value

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
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

    func testStoresWithinCapacityDoNotRescanEntireDirectoryEachTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanCounter = DirectoryScanCounter()
        let cache = try ChannelLogoDiskCache(
            directory: directory,
            capacity: 100,
            fileManager: DirectoryScanCountingFileManager(counter: scanCounter)
        )

        for index in 0..<3 {
            await cache.store(
                Data("logo".utf8), forKey: "logo-\(index)", maximumByteCount: 10
            )
        }

        XCTAssertLessThanOrEqual(scanCounter.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            3
        )
    }

    func testReplacingEntryUpdatesCapacityAccountingBeforeEviction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(directory: directory, capacity: 6)
        await cache.store(Data("aaaa".utf8), forKey: "a", maximumByteCount: 6)
        await cache.store(Data("bb".utf8), forKey: "b", maximumByteCount: 6)
        await cache.store(Data("a".utf8), forKey: "a", maximumByteCount: 6)
        await cache.store(Data("ccc".utf8), forKey: "c", maximumByteCount: 6)

        let a = await cache.data(forKey: "a", maximumByteCount: 6)
        let b = await cache.data(forKey: "b", maximumByteCount: 6)
        let c = await cache.data(forKey: "c", maximumByteCount: 6)
        XCTAssertEqual(a, Data("a".utf8))
        XCTAssertEqual(b, Data("bb".utf8))
        XCTAssertEqual(c, Data("ccc".utf8))
    }

    func testExternallyDeletedEntryIsReconciledBeforeEvictingSurvivors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ChannelLogoDiskCache(directory: directory, capacity: 6)
        await cache.store(Data("old!".utf8), forKey: "old", maximumByteCount: 6)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("old")
        )

        await cache.store(Data("new!".utf8), forKey: "new", maximumByteCount: 6)
        await cache.store(Data("ok".utf8), forKey: "last", maximumByteCount: 6)

        let new = await cache.data(forKey: "new", maximumByteCount: 6)
        let last = await cache.data(forKey: "last", maximumByteCount: 6)
        XCTAssertEqual(new, Data("new!".utf8))
        XCTAssertEqual(last, Data("ok".utf8))
    }

    func testRemoteLoaderCoalescesConcurrentCallsForSameURL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let downloader = HoldingChannelLogoDownloader(directory: directory)
        let loader = LiveChannelLogoDataLoader(
            downloader: downloader, fileManager: .default
        )
        let url = URL(string: "https://images.example/shared.png")!

        let first = Task { await loader.data(for: url, maximumByteCount: 16) }
        let firstStarted = await waitForDownloads(downloader, count: 1)
        XCTAssertTrue(firstStarted)
        let second = Task { await loader.data(for: url, maximumByteCount: 16) }
        try await Task.sleep(for: .milliseconds(50))
        let started = await downloader.startedURLs
        try await downloader.releaseAll(data: Data("logo".utf8))
        let firstData = await first.value
        let secondData = await second.value

        XCTAssertEqual(started, [url])
        XCTAssertEqual(firstData, Data("logo".utf8))
        XCTAssertEqual(secondData, Data("logo".utf8))
    }

    func testCancellingOneSameURLWaiterDoesNotCancelOtherWaiter() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let downloader = HoldingChannelLogoDownloader(directory: directory)
        let loader = LiveChannelLogoDataLoader(
            downloader: downloader, fileManager: .default
        )
        let url = URL(string: "https://images.example/cancel-shared.png")!

        let cancelled = Task { await loader.data(for: url, maximumByteCount: 16) }
        let firstStarted = await waitForDownloads(downloader, count: 1)
        XCTAssertTrue(firstStarted)
        let surviving = Task { await loader.data(for: url, maximumByteCount: 16) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(20))
        try await downloader.releaseAll(data: Data("logo".utf8))
        let cancelledData = await cancelled.value
        let survivingData = await surviving.value
        let started = await downloader.startedURLs

        XCTAssertNil(cancelledData)
        XCTAssertEqual(survivingData, Data("logo".utf8))
        XCTAssertEqual(started, [url])
    }

    func testSameURLWithDifferentByteLimitsKeepsEachCallerLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let downloader = HoldingChannelLogoDownloader(directory: directory)
        let loader = LiveChannelLogoDataLoader(
            downloader: downloader, fileManager: .default
        )
        let url = URL(string: "https://images.example/different-limits.png")!

        let small = Task { await loader.data(for: url, maximumByteCount: 3) }
        let firstStarted = await waitForDownloads(downloader, count: 1)
        XCTAssertTrue(firstStarted)
        let large = Task { await loader.data(for: url, maximumByteCount: 5) }
        let secondStarted = await waitForDownloads(downloader, count: 2)
        XCTAssertTrue(secondStarted)
        try await downloader.releaseAll(data: Data("logo".utf8))
        let smallData = await small.value
        let largeData = await large.value
        let started = await downloader.startedURLs

        XCTAssertNil(smallData)
        XCTAssertEqual(largeData, Data("logo".utf8))
        XCTAssertEqual(started, [url, url])
    }

    func testDifferentRemoteURLsUseAtMostFourConcurrentDownloadSlots() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let downloader = HoldingChannelLogoDownloader(directory: directory)
        let loader = LiveChannelLogoDataLoader(
            downloader: downloader, fileManager: .default
        )
        let urls = (0..<5).map {
            URL(string: "https://images.example/logo-\($0).png")!
        }
        let firstFour = urls.prefix(4).map { url in
            Task { await loader.data(for: url, maximumByteCount: 16) }
        }
        let fourStarted = await waitForDownloads(downloader, count: 4)
        XCTAssertTrue(fourStarted)
        let fifth = Task { await loader.data(for: urls[4], maximumByteCount: 16) }
        try await Task.sleep(for: .milliseconds(50))
        let startedBeforeRelease = await downloader.startedURLs.count

        try await downloader.releaseFirst(data: Data("logo".utf8))
        let fifthStarted = await waitForDownloads(downloader, count: 5)
        XCTAssertTrue(fifthStarted)
        try await downloader.releaseAll(data: Data("logo".utf8))
        for task in firstFour {
            let data = await task.value
            XCTAssertEqual(data, Data("logo".utf8))
        }
        let fifthData = await fifth.value
        XCTAssertEqual(fifthData, Data("logo".utf8))
        XCTAssertEqual(startedBeforeRelease, 4)
    }

    func testCancelledQueuedLogoRequestsDoNotAccumulateWhileAllSlotsAreBusy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloader = HoldingChannelLogoDownloader(directory: directory)
        let loader = LiveChannelLogoDataLoader(downloader: downloader, fileManager: .default)
        let active = (0..<4).map { index in
            Task {
                await loader.data(
                    for: URL(string: "https://images.example/held-\(index).png")!,
                    maximumByteCount: 16
                )
            }
        }
        let started = await waitForDownloads(downloader, count: 4)
        XCTAssertTrue(started)

        for index in 0..<64 {
            let queued = Task {
                await loader.data(
                    for: URL(string: "https://images.example/abandoned-\(index).png")!,
                    maximumByteCount: 16
                )
            }
            let deadline = Date().addingTimeInterval(2)
            var admitted = false
            while Date() < deadline {
                if await loader.logoTestRequestCount == 5 { admitted = true; break }
                await Task.yield()
            }
            XCTAssertTrue(admitted)
            queued.cancel()
            let data = await queued.value
            XCTAssertNil(data)
            if !admitted { break }
        }
        let pendingCount = await loader.logoTestPendingKeyCount
        let startsBeforeRelease = await downloader.startedURLs.count
        XCTAssertEqual(pendingCount, 0, "Cancelled entries must not build up behind held downloads")
        XCTAssertEqual(startsBeforeRelease, 4)
        try await downloader.releaseAll(data: Data("logo".utf8))
        for task in active { _ = await task.value }
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
                        byteCount: testCase.reportedByteCount,
                        responseURL: URL(string: "https://images.example/\(testCase.name).png")!
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

    func testDiskCacheMissDoesNotAttemptFileRemoval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = FileOperationCounter()
        let cache = try ChannelLogoDiskCache(
            directory: directory,
            capacity: 1024,
            fileManager: OperationCountingFileManager(counter: counter)
        )

        let data = await cache.data(forKey: "missing-key", maximumByteCount: 1024)
        XCTAssertNil(data)
        XCTAssertEqual(counter.removeCount, 0, "Cache miss must not invoke removeItem")
    }

    func testDiskCacheThrottlesModificationDateUpdatesWithinOneHour() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LogoDiskCacheClock(Date(timeIntervalSince1970: 2_000_000_000))
        let counter = FileOperationCounter()
        let cache = try ChannelLogoDiskCache(
            directory: directory,
            capacity: 1024,
            fileManager: OperationCountingFileManager(counter: counter),
            modificationDateRefreshInterval: 3_600,
            now: { clock.date }
        )
        await cache.store(Data("logo".utf8), forKey: "hit", maximumByteCount: 1024)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.date],
            ofItemAtPath: directory.appendingPathComponent("hit").path
        )

        clock.advance(60)
        _ = await cache.data(forKey: "hit", maximumByteCount: 1024)
        XCTAssertEqual(counter.setAttributesCount, 0, "Hit within 1 hour must not rewrite mtime")

        clock.advance(3_600)
        _ = await cache.data(forKey: "hit", maximumByteCount: 1024)
        XCTAssertEqual(counter.setAttributesCount, 1, "Hit after 1 hour must refresh mtime")
    }

    func testFastFailInMemoryLoaderClassifiesSuccessClientErrorServerErrorAndOversized() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let loader = LiveChannelLogoDataLoader.makeFastFail(configuration: configuration)

        let okURL = URL(string: "https://images.example/fast-ok.png")!
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200),
            chunks: [Data("png".utf8)]
        ))
        let okResult = await loader.loadData(for: okURL, maximumByteCount: 16)
        XCTAssertEqual(okResult, .data(Data("png".utf8)))

        let notFoundURL = URL(string: "https://images.example/fast-404.png")!
        StubURLProtocol.enqueue(.init(response: .http(statusCode: 404)))
        let notFoundResult = await loader.loadData(for: notFoundURL, maximumByteCount: 16)
        XCTAssertEqual(notFoundResult, .failed(.permanent))

        let serverErrorURL = URL(string: "https://images.example/fast-503.png")!
        StubURLProtocol.enqueue(.init(response: .http(statusCode: 503)))
        let serverErrorResult = await loader.loadData(for: serverErrorURL, maximumByteCount: 16)
        XCTAssertEqual(serverErrorResult, .failed(.transient))

        let oversizedURL = URL(string: "https://images.example/fast-oversized.png")!
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200),
            chunks: [Data(repeating: 0x41, count: 32)]
        ))
        let oversizedResult = await loader.loadData(for: oversizedURL, maximumByteCount: 16)
        XCTAssertEqual(oversizedResult, .failed(.permanent))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChannelLogoDiskCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func waitForDownloads(
        _ downloader: HoldingChannelLogoDownloader,
        count: Int
    ) async -> Bool {
        for _ in 0..<200 {
            if await downloader.startedURLs.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class DirectoryScanCounter: @unchecked Sendable {
    private let countLock = NSLock()
    private var storage = 0

    var count: Int {
        countLock.withLock { storage }
    }

    func record() {
        countLock.withLock { storage += 1 }
    }
}

private final class DirectoryScanCountingFileManager: FileManager {
    private let counter: DirectoryScanCounter

    init(counter: DirectoryScanCounter) {
        self.counter = counter
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        counter.record()
        return try super.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: mask
        )
    }
}

private actor HoldingChannelLogoDownloader: BoundedHTTPDownloading {
    private struct Pending {
        let url: URL
        let continuation: CheckedContinuation<DownloadedResource, any Error>
    }

    let directory: URL
    private var pending: [Pending] = []
    private var requests: [URL] = []
    private var releasedData: Data?

    init(directory: URL) {
        self.directory = directory
    }

    var startedURLs: [URL] { requests }

    func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource {
        _ = byteLimit
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(url)
            if let releasedData {
                do {
                    continuation.resume(returning: try makeResource(data: releasedData, responseURL: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            } else {
                pending.append(Pending(url: url, continuation: continuation))
            }
        }
    }

    func releaseFirst(data: Data) throws {
        guard !pending.isEmpty else { return }
        let item = pending.removeFirst()
        do {
            item.continuation.resume(returning: try makeResource(data: data, responseURL: item.url))
        } catch {
            item.continuation.resume(throwing: error)
            throw error
        }
    }

    func releaseAll(data: Data) throws {
        releasedData = data
        while !pending.isEmpty {
            try releaseFirst(data: data)
        }
    }

    private func makeResource(data: Data, responseURL: URL) throws -> DownloadedResource {
        let fileURL = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: fileURL)
        return DownloadedResource(
            temporaryFileURL: fileURL, byteCount: Int64(data.count),
            responseURL: responseURL
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

private final class FileOperationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var removes = 0
    private var setAttributesCalls = 0

    var removeCount: Int { lock.withLock { removes } }
    var setAttributesCount: Int { lock.withLock { setAttributesCalls } }

    func recordRemove() { lock.withLock { removes += 1 } }
    func recordSetAttributes() { lock.withLock { setAttributesCalls += 1 } }
}

private final class OperationCountingFileManager: FileManager {
    private let counter: FileOperationCounter

    init(counter: FileOperationCounter) {
        self.counter = counter
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        counter.recordRemove()
        try super.removeItem(at: URL)
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        counter.recordSetAttributes()
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class LogoDiskCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) { self.current = initial }
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

// Test-only actor-isolated observations establish admission without scheduling
// sleeps or production test hooks, and expose retained queue storage directly.
private extension LiveChannelLogoDataLoader {
    var logoTestRequestCount: Int { logoTestCollectionCount(named: "remoteRequests") }
    var logoTestPendingKeyCount: Int { logoTestCollectionCount(named: "pendingRemoteKeys") }

    func logoTestCollectionCount(named name: String) -> Int {
        guard let value = Mirror(reflecting: self).children.first(where: {
            $0.label == name
        })?.value else { return -1 }
        return Mirror(reflecting: value).children.count
    }
}
