// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public protocol VideoFrameProcessing: AnyObject {
    var requiredInputFrameCount: Int { get }
    func reset(to generation: MediaGeneration)
    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    )
}

public final class PassthroughVideoProcessor: VideoFrameProcessing, @unchecked Sendable {
    public let requiredInputFrameCount = 1
    private var generation = MediaGeneration(rawValue: 0)
    private var sequence: UInt64 = 0

    public init() {}

    public func reset(to generation: MediaGeneration) {
        self.generation = generation
        sequence = 0
    }

    public func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    ) {
        guard frame.generation == generation else {
            completion(.success([]))
            return
        }
        sequence &+= 1
        completion(.success([VideoPresentationFrame(
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            generation: frame.generation,
            sequenceNumber: sequence,
            sourceAccessUnitID: frame.accessUnitID,
            formatMetadata: frame.formatMetadata
        )]))
    }
}
