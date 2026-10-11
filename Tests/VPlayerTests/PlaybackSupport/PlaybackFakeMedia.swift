// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import VPlayerPlayback

enum PlaybackFakeMedia {
    static func tracks(
        videoExtradata: Data = Data(),
        audioExtradata: Data = Data([0x12, 0x10]),
        videoFrameRate: MediaRational? = nil,
        videoFieldOrder: CodedFieldOrder = .unknown
    ) -> DemuxTrackSet {
        DemuxTrackSet(
            selectedProgramID: 1,
            video: VideoTrackDescriptor(
                streamIndex: 100,
                codec: .h264,
                timeBase: MediaRational(num: 1, den: 90_000)!,
                width: 1_920,
                height: 1_080,
                videoDelay: 0,
                extradata: videoExtradata,
                frameRate: videoFrameRate,
                fieldOrder: videoFieldOrder
            ),
            audio: AudioTrackDescriptor(
                streamIndex: 101,
                codec: .aac,
                timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000,
                channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                extradata: audioExtradata
            )
        )
    }

    static func audioOnlyTracks(
        audioExtradata: Data = Data([0x12, 0x10])
    ) -> DemuxTrackSet {
        DemuxTrackSet(
            selectedProgramID: 1,
            video: nil,
            audio: AudioTrackDescriptor(
                streamIndex: 101,
                codec: .aac,
                timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000,
                channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                extradata: audioExtradata
            )
        )
    }

    static func videoFormat() throws -> CMVideoFormatDescription {
        var value: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.videoFormatDescription(status) }
        return value
    }

    static func audioFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var value: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.audioFormatDescription(status) }
        return value
    }

    static func audioConfiguration(
        fingerprint: MediaFormatFingerprint,
        decoderExtradata: Data = Data([0x12, 0x10])
    ) throws -> CompressedAudioRenderConfiguration {
        CompressedAudioRenderConfiguration(
            formatDescription: try audioFormat(),
            codec: .aac,
            decoderExtradata: decoderExtradata,
            fingerprint: fingerprint
        )
    }

    static func audioSystemFingerprintComponent(
        magicCookie: Data? = Data()
    ) -> AudioSystemFormatFingerprintComponent {
        AudioSystemFormatFingerprintComponent(
            profileID: .aacLC,
            formatID: kAudioFormatMPEG4AAC,
            sampleRate: 48_000,
            channelCount: 2,
            framesPerPacket: 1_024,
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: magicCookie
        )
    }

    static func audioFrame(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        duration: CMTime
    ) -> CompressedAudioFrame {
        return CompressedAudioFrame(
            id: id,
            payload: Data([UInt8(truncatingIfNeeded: id), 0xA5]),
            codec: .aac,
            generation: generation,
            presentationTimeStamp: pts,
            duration: duration,
            frameSampleCount: 1_024
        )
    }

    static func videoPacket(
        marker: UInt8,
        pts: Int64 = 90_000,
        isCorrupt: Bool = false
    ) -> DemuxPacket {
        DemuxPacket(
            streamIndex: 100,
            codec: .video(.h264),
            data: Data([marker]),
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            decodeTimeStamp: CMTime(value: pts - 3_000, timescale: 90_000),
            duration: CMTime(value: 3_000, timescale: 90_000),
            isKey: true,
            isCorrupt: isCorrupt
        )
    }

    static func audioPacket(id: UInt8, isCorrupt: Bool = false) -> DemuxPacket {
        let payload = Data([id, 0xAA])
        let frameLength = 7 + payload.count
        var data = Data([
            0xFF, 0xF1, 0x4C,
            UInt8(0x80 | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
        data.append(payload)
        return DemuxPacket(
            streamIndex: 101,
            codec: .audio(.aac),
            data: data,
            presentationTimeStamp: CMTime(value: Int64(id) * 1_920, timescale: 90_000),
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: isCorrupt
        )
    }

    static func accessUnit(
        id: UInt64,
        generation: MediaGeneration,
        randomAccess: Bool,
        pts: CMTime? = nil,
        duration: CMTime? = nil,
        data: Data = Data([0x00, 0x00, 0x00, 0x01])
    ) throws -> CompressedVideoAccessUnit {
        let format = try videoFormat()
        let buffer = try SampleBufferBuilder.makeVideo(
            data: data,
            formatDescription: format,
            presentationTimeStamp: pts ?? CMTime(value: Int64(id), timescale: 25),
            decodeTimeStamp: .invalid,
            duration: duration ?? CMTime(value: 1, timescale: 25),
            isRandomAccess: randomAccess
        )
        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: generation,
                accessUnitID: id
            ),
            bytes: data
        )
        return try CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: buffer,
            generation: generation,
            isRandomAccess: randomAccess,
            parserMetadata: parserMetadata(interlaced: false),
            sourceBacking: backing,
            sourceByteRange: backing.wholeRange
        )
    }

    static func decodedFrame(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        interlaced: Bool,
        duration: CMTime = CMTime(value: 1, timescale: 25),
        pictureStructure: PictureStructure = .frame,
        dimensions: CMVideoDimensions = CMVideoDimensions(width: 16, height: 16),
        bitDepth: Int = 8
    ) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PlaybackCoreError.videoDecode(status)
        }
        let sourcePTS90k = pts.isNumeric
            ? UInt64(max(
                0,
                CMTimeConvertScale(pts, timescale: 90_000, method: .default).value
            ))
            : nil
        return DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            generation: generation,
            parserMetadata: VideoParserMetadata(
                fieldOrder: interlaced ? .tt : .progressive,
                pictureStructure: pictureStructure,
                isInterlaced: interlaced,
                repeatFirstField: false,
                topFieldFirst: interlaced ? true : nil,
                sourcePTS90k: sourcePTS90k
            ),
            formatMetadata: VideoFormatMetadata(
                dimensions: dimensions,
                bitDepth: bitDepth,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(masteringDisplayColorVolume: nil, contentLightLevelInfo: nil)
            )
        )
    }

    static func parserMetadata(interlaced: Bool) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: interlaced ? .tt : .progressive,
            pictureStructure: .frame,
            isInterlaced: interlaced,
            repeatFirstField: false,
            topFieldFirst: interlaced ? true : nil,
            sourcePTS90k: nil
        )
    }
}
