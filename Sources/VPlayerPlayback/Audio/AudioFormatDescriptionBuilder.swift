// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

struct BuiltAudioFormat {
    let description: CMAudioFormatDescription
    let streamDescription: AudioStreamBasicDescription
}

enum AudioFormatDescriptionBuilder {
    static let invalidLayoutErrorCode: Int32 = -1_448_208_898

    static func make(
        codec: AudioCodec,
        sampleRate: Int32,
        channelLayout: AudioChannelLayout,
        cookie: Data?
    ) throws -> BuiltAudioFormat {
        guard sampleRate > 0, channelLayout.channelCount > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
        }
        let formatID: AudioFormatID
        let framesPerPacket: UInt32
        switch codec {
        case .aac:
            formatID = kAudioFormatMPEG4AAC
            framesPerPacket = 1_024
        case .ac3:
            formatID = kAudioFormatAC3
            framesPerPacket = 1_536
        case .eac3:
            formatID = kAudioFormatEnhancedAC3
            framesPerPacket = 0
        case .mp2:
            formatID = kAudioFormatMPEGLayer2
            framesPerPacket = 1_152
        }
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelLayout.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var coreAudioLayout = try makeCoreAudioLayout(channelLayout)
        var result: CMAudioFormatDescription?
        let status = withCookie(cookie) { cookiePointer, cookieSize in
            withUnsafePointer(to: &coreAudioLayout) { layoutPointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &streamDescription,
                    layoutSize: MemoryLayout<AudioToolbox.AudioChannelLayout>.size,
                    layout: layoutPointer,
                    magicCookieSize: cookieSize,
                    magicCookie: cookiePointer,
                    extensions: nil,
                    formatDescriptionOut: &result
                )
            }
        }
        guard status == noErr, let result else {
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        return BuiltAudioFormat(description: result, streamDescription: streamDescription)
    }

    private static func makeCoreAudioLayout(
        _ layout: AudioChannelLayout
    ) throws -> AudioToolbox.AudioChannelLayout {
        if let nativeMask = layout.nativeMask {
            let supportedMask: UInt64 = (1 << 18) - 1
            guard nativeMask != 0,
                  nativeMask & ~supportedMask == 0,
                  nativeMask.nonzeroBitCount == layout.channelCount,
                  let bitmap = UInt32(exactly: nativeMask) else {
                throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelBitmap,
                mChannelBitmap: AudioChannelBitmap(rawValue: bitmap),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        }
        guard let count = UInt32(exactly: layout.channelCount) else {
            throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
        }
        return AudioToolbox.AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count,
            mChannelBitmap: AudioChannelBitmap(rawValue: 0),
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: (AudioChannelDescription(),)
        )
    }

    private static func withCookie<Result>(
        _ cookie: Data?,
        body: (UnsafeRawPointer?, Int) throws -> Result
    ) rethrows -> Result {
        guard let cookie else { return try body(nil, 0) }
        return try cookie.withUnsafeBytes { rawBuffer in
            try body(rawBuffer.baseAddress, rawBuffer.count)
        }
    }
}
