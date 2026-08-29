// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct CompressedAudioFrame: Sendable {
    public let id: UInt64
    public let payload: Data
    public let codec: AudioCodec
    public let generation: MediaGeneration
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let frameSampleCount: Int32

    public init(
        id: UInt64,
        payload: Data,
        codec: AudioCodec,
        generation: MediaGeneration,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        frameSampleCount: Int32
    ) {
        self.id = id
        self.payload = payload
        self.codec = codec
        self.generation = generation
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.frameSampleCount = frameSampleCount
    }
}

public struct CompressedAudioSample: @unchecked Sendable {
    public let id: UInt64
    public let sampleBuffer: CMSampleBuffer
    public let codec: AudioCodec
    public let generation: MediaGeneration
    public let presentationTimeStamp: CMTime
    public let effectiveCoverageStartPTS: CMTime
    public let duration: CMTime
    public let continuityIslandID: AudioContinuityIslandID

    public init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        codec: AudioCodec,
        generation: MediaGeneration,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        continuityIslandID: AudioContinuityIslandID,
        effectiveCoverageStartPTS: CMTime? = nil
    ) {
        self.id = id
        self.sampleBuffer = sampleBuffer
        self.codec = codec
        self.generation = generation
        self.presentationTimeStamp = presentationTimeStamp
        self.effectiveCoverageStartPTS = effectiveCoverageStartPTS
            ?? presentationTimeStamp
        self.duration = duration
        self.continuityIslandID = continuityIslandID
    }
}

public enum AudioDecodeBreakReason: UInt8, Sendable, Equatable {
    case corruptPacket
    case framingReset
    case invalidFrame
}

public enum AudioAssemblerEvent: @unchecked Sendable {
    case format(CompressedAudioRenderConfiguration)
    case frame(CompressedAudioFrame)
    case decodeBreak(AudioDecodeBreakReason)
}
