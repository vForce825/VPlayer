// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct DemuxPacket: Sendable, Equatable {
    let streamIndex: Int32
    let codec: MediaCodec
    let data: Data
    let presentationTimeStamp: CMTime
    let decodeTimeStamp: CMTime
    let duration: CMTime
    let isKey: Bool
    let isCorrupt: Bool
}

enum DemuxEvent: Sendable, Equatable {
    case tracks(DemuxTrackSet)
    case packet(DemuxPacket)
    case discontinuity(DemuxTrackSet)
    case endOfStream
    case cancelled
    case failure(PlaybackCoreError)
}

protocol MediaDemuxing: AnyObject {
    func start(url: URL, sink: @escaping @Sendable (DemuxEvent) -> Void) throws
    func cancel()
    /// Wall time the read thread has spent waiting for room in the delivery
    /// queue. This is the difference between "the source is not giving us
    /// realtime" and "we are not draining fast enough to keep reading it": if the
    /// reader never waits here, the shortfall is upstream of the app.
    var queueFullWaitNanoseconds: UInt64 { get }
}

extension MediaDemuxing {
    var queueFullWaitNanoseconds: UInt64 { 0 }
}
