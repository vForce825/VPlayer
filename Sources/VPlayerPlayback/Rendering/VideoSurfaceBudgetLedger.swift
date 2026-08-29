// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
import IOSurface

struct VideoSurfaceBudgetSnapshot: Sendable, Equatable {
    let limit: Int
    let retainedBytes: Int
    let retainedSurfaceCount: Int
    let referenceCount: Int
}

final class VideoSurfaceBudgetLedger: @unchecked Sendable {
    static let defaultLimit = 512 * 1_024 * 1_024

    private struct Entry {
        let bytes: Int
        var references: Int
    }

    private let lock = NSLock()
    private let limit: Int
    private var entries: [IOSurfaceID: Entry] = [:]
    private var retainedBytes = 0

    init(limit: Int = VideoSurfaceBudgetLedger.defaultLimit) {
        self.limit = max(1, limit)
    }

    @discardableResult
    func retain(_ frame: VideoPresentationFrame) -> Bool {
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer) else { return false }
        let identifier = IOSurfaceGetID(surface.takeUnretainedValue())
        let bytes = max(1, frame.estimatedStorageBytes)
        return lock.withLock {
            if var entry = entries[identifier] {
                entry.references += 1
                entries[identifier] = entry
                return true
            }
            guard bytes <= limit - retainedBytes else { return false }
            entries[identifier] = Entry(bytes: bytes, references: 1)
            retainedBytes += bytes
            return true
        }
    }

    func release(_ frame: VideoPresentationFrame) {
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer) else { return }
        let identifier = IOSurfaceGetID(surface.takeUnretainedValue())
        lock.withLock {
            guard var entry = entries[identifier] else { return }
            entry.references -= 1
            if entry.references > 0 {
                entries[identifier] = entry
            } else {
                entries[identifier] = nil
                retainedBytes = max(0, retainedBytes - entry.bytes)
            }
        }
    }

    var snapshot: VideoSurfaceBudgetSnapshot {
        lock.withLock {
            VideoSurfaceBudgetSnapshot(
                limit: limit,
                retainedBytes: retainedBytes,
                retainedSurfaceCount: entries.count,
                referenceCount: entries.values.reduce(0) { $0 + $1.references }
            )
        }
    }
}
