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
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count == fileSize,
              data.count <= maximumByteCount else {
            try? fileManager.removeItem(at: fileURL)
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
            try data.write(to: fileURL(forKey: key), options: .atomic)
            try pruneIfNeeded()
        } catch {
            // Disk caching is best-effort; the memory cache already owns the image.
        }
    }

    func removeData(forKey key: String) {
        try? fileManager.removeItem(at: fileURL(forKey: key))
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
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
        guard totalSize > capacity else { return }
        for entry in entries.sorted(by: { $0.modificationDate < $1.modificationDate }) {
            try? fileManager.removeItem(at: entry.url)
            totalSize = max(0, totalSize - entry.size)
            if totalSize <= capacity { break }
        }
    }
}
