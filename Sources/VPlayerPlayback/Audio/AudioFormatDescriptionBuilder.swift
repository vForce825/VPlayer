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

    static func make(_ format: SystemCompressedAudioFormat) throws -> BuiltAudioFormat {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
        }
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(format.sampleRate),
            mFormatID: format.formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: format.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(format.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var coreAudioLayout = try makeCoreAudioLayout(
            format.layout,
            channelCount: format.channelCount
        )
        var result: CMAudioFormatDescription?
        let status = withCookie(format.magicCookie) { cookiePointer, cookieSize in
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
        _ layout: CoreAudioLayoutSpec,
        channelCount: Int32
    ) throws -> AudioToolbox.AudioChannelLayout {
        switch layout {
        case let .tag(tag, equivalentBitmap):
            guard tag != kAudioChannelLayoutTag_UseChannelBitmap,
                  tag & 0xFFFF == UInt32(channelCount),
                  equivalentBitmap.rawValue != 0,
                  equivalentBitmap.rawValue.nonzeroBitCount == channelCount else {
                throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: tag,
                mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        case let .bitmap(bitmap):
            let supportedMask: UInt32 = (1 << 18) - 1
            guard bitmap.rawValue != 0,
                  bitmap.rawValue & ~supportedMask == 0,
                  bitmap.rawValue.nonzeroBitCount == channelCount else {
                throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelBitmap,
                mChannelBitmap: bitmap,
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        case let .discrete(count):
            guard count > 0, count == UInt32(exactly: channelCount) else {
                throw PlaybackCoreError.audioFallbackDecode(invalidLayoutErrorCode)
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count,
                mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        }
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
