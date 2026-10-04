// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation

/// Visits the currently fetched batch synchronously after retrieval. Implementors
/// do not retain the visitor or log history. The driver owns identity validation
/// and scalar classification so delayed SDK completion cannot bypass its fences.
@MainActor
protocol AVPlayerLogReading: AnyObject {
    func readAccessLog(item: AVPlayerItem, visitURI: @MainActor (String) -> Void) async -> Int
    func readErrorLogCount(item: AVPlayerItem) async -> Int
}

@MainActor
final class SystemAVPlayerLogReader: AVPlayerLogReading {
    func readAccessLog(item: AVPlayerItem, visitURI: @MainActor (String) -> Void) async -> Int {
        let log = await item.accessLog
        guard let events = log?.events else { return 0 }
        // Coalescing can combine multiple notifications, including a conflict
        // followed by a matching URI. Fold the whole returned batch, not its tail.
        // Re-scanning also handles SDK log resets without an assumed stable index
        // or retained raw URI/history. All state carried out is scalar.
        for event in events {
            if let uri = event.uri { visitURI(uri) }
        }
        return events.count
    }

    func readErrorLogCount(item: AVPlayerItem) async -> Int {
        let log = await item.errorLog
        return log?.events.count ?? 0
    }
}
