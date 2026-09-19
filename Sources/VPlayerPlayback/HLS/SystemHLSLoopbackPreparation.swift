// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 媒体仓库的过期时长统一使用纳秒；这里必须提供同单位的单调时钟，不能混入
/// Unix 毫秒，否则已移出播放列表的分片会被错误保留数十天并最终耗尽容量。
enum SystemHLSLoopbackClock {
    static func nanoseconds(uptimeNanoseconds: UInt64) -> Int64 {
        Int64(clamping: uptimeNanoseconds)
    }

    static func nowNanoseconds() -> Int64 {
        nanoseconds(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

/// 仅以 publisher 已可见的真实 snapshot 启动同一 store 的 loopback，并从同一 server
/// 签发 AVPlayer replacement；不能以 playlist 字符串或源 URL 直接构造 item。
enum SystemHLSLoopbackPreparation {
    struct Prepared: @unchecked Sendable {
        let server: LoopbackHTTPServer
        let replacement: AVPlayerItemReplacementBundle
    }

    static func start(store: SealedMediaStore, declaration: HLSItemDeclaration,
                      snapshot: HLSPublishedSnapshot, token: LoopbackSessionToken,
                      item: AVPlayerItemInstanceIdentity) async throws -> Prepared {
        let server = try await LoopbackHTTPServer.start(
            store: store, declaration: declaration, publishedSnapshot: snapshot,
            sessionCapability: token,
            now: SystemHLSLoopbackClock.nowNanoseconds, logger: { _ in }
        )
        return try Prepared(
            server: server,
            replacement: LoopbackAVPlayerPreparationBundle(
                server: server, item: item).replacementBundle)
    }
}
