// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import VideoToolbox
@testable import VPlayerPlayback

final class FakeVideoDecoder: VideoDecoding, @unchecked Sendable {
    enum Operation: Equatable {
        case configure(MediaGeneration, VideoDecodeConfiguration)
        case decode(UInt64, MediaGeneration, VTDecodeFrameFlags)
        case finish
        case wait
        case invalidate
    }

    private let lock = NSLock()
    private(set) var operations: [Operation] = []
    var configureError: VideoDecoderFailure?
    var decodeError: VideoDecoderFailure?
    var finishError: VideoDecoderFailure?
    var waitError: VideoDecoderFailure?

    func configure(
        format _: CMVideoFormatDescription,
        generation: MediaGeneration,
        configuration: VideoDecodeConfiguration
    ) throws {
        if let configureError { throw configureError }
        lock.withLock { operations.append(.configure(generation, configuration)) }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        if let decodeError { throw decodeError }
        lock.withLock { operations.append(.decode(accessUnit.id, accessUnit.generation, flags)) }
    }

    func finishDelayedFrames() throws {
        lock.withLock { operations.append(.finish) }
        if let finishError { throw finishError }
    }

    func waitForAsynchronousFrames() throws {
        lock.withLock { operations.append(.wait) }
        if let waitError { throw waitError }
    }

    func invalidate() {
        lock.withLock { operations.append(.invalidate) }
    }

    func snapshot() -> [Operation] { lock.withLock { operations } }
}
