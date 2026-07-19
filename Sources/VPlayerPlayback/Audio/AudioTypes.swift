// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct CompressedAudioSample: @unchecked Sendable {
    public let id: UInt64
    public let sampleBuffer: CMSampleBuffer
    public let codec: AudioCodec
    public let generation: MediaGeneration
    public let presentationTimeStamp: CMTime
    public let duration: CMTime

    public init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        codec: AudioCodec,
        generation: MediaGeneration,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        self.id = id
        self.sampleBuffer = sampleBuffer
        self.codec = codec
        self.generation = generation
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }
}

public enum AudioAssemblerEvent: @unchecked Sendable {
    case format(CMAudioFormatDescription, AudioCodec, MediaFormatFingerprint)
    case sample(CompressedAudioSample)
}
