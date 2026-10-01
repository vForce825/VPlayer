// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

actor ChannelLogoDiskCache {
    private struct Entry {
        let url: URL
        let size: Int
        let modificationDate: Date
    }

    private let directory: URL
    private let capacity: Int
    private let fileManager: FileManager
    private var knownTotalSize: Int?
    private var storesSinceScan = 0
    private let reconciliationInterval = 32

    init(
        directory: URL,
        capacity: Int,
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.capacity = capacity
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func data(forKey key: String, maximumByteCount: Int) -> Data? {
        let fileURL = fileURL(forKey: key)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard maximumByteCount >= 0,
              let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumByteCount else {
            removeData(forKey: key)
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count == fileSize,
              data.count <= maximumByteCount else {
            removeData(forKey: key)
            return nil
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        return data
    }

    func store(_ data: Data, forKey key: String, maximumByteCount: Int) {
        guard maximumByteCount >= 0,
              data.count <= maximumByteCount,
              data.count <= capacity else {
            return
        }
        do {
            let url = fileURL(forKey: key)
            let previousSize = regularFileSize(at: url) ?? 0
            try data.write(to: url, options: .atomic)
            if let knownTotalSize {
                let remaining = max(0, knownTotalSize - previousSize)
                let (updated, overflow) = remaining.addingReportingOverflow(data.count)
                self.knownTotalSize = overflow ? Int.max : updated
                storesSinceScan += 1
            }
            let needsCapacityScan = self.knownTotalSize.map { $0 > capacity } ?? true
            if needsCapacityScan || storesSinceScan >= reconciliationInterval {
                try pruneIfNeeded()
            }
        } catch {
            knownTotalSize = nil
            // Disk caching is best-effort; the memory cache already owns the image.
        }
    }

    func removeData(forKey key: String) {
        let url = fileURL(forKey: key)
        let size = regularFileSize(at: url) ?? 0
        do {
            try fileManager.removeItem(at: url)
            if let knownTotalSize {
                self.knownTotalSize = max(0, knownTotalSize - size)
            }
        } catch {
            // 缺失文件不改变缓存，其余失败交给下一次全目录核算修正。
            if fileManager.fileExists(atPath: url.path) { knownTotalSize = nil }
        }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }

    private func regularFileSize(at url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize, size >= 0 else { return nil }
        return size
    }

    private func pruneIfNeeded() throws {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        var entries: [Entry] = []
        var totalSize = 0
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            let (sum, overflow) = totalSize.addingReportingOverflow(size)
            totalSize = overflow ? Int.max : sum
            entries.append(Entry(
                url: fileURL,
                size: size,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        guard totalSize > capacity else {
            knownTotalSize = totalSize
            storesSinceScan = 0
            return
        }
        for entry in entries.sorted(by: { $0.modificationDate < $1.modificationDate }) {
            do {
                try fileManager.removeItem(at: entry.url)
                totalSize = max(0, totalSize - entry.size)
            } catch { continue }
            if totalSize <= capacity { break }
        }
        knownTotalSize = totalSize
        storesSinceScan = 0
    }
}
