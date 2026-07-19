// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum SampleBufferBuilder {
    static let invalidDataErrorCode: Int32 = -1_448_143_362
    private static let maximumPayloadBytes = 64 * 1_024 * 1_024

    static func makeVideo(
        data: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime,
        duration: CMTime,
        isRandomAccess: Bool
    ) throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(data, video: true)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PlaybackCoreError.videoDecode(status)
        }
        if !isRandomAccess {
            guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ), CFArrayGetCount(rawAttachments) == 1 else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            guard let rawDictionary = CFArrayGetValueAtIndex(rawAttachments, 0) else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(rawDictionary)
                .takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    static func makeAudio(
        data: Data,
        formatDescription: CMAudioFormatDescription,
        presentationTimeStamp: CMTime,
        variableFramesInPacket: UInt32
    ) throws -> CMSampleBuffer {
        guard presentationTimeStamp.isNumeric,
              let byteSize = UInt32(exactly: data.count) else {
            throw PlaybackCoreError.audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
        }
        let blockBuffer = try makeBlockBuffer(data, video: false)
        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: variableFramesInPacket,
            mDataByteSize: byteSize
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        return sampleBuffer
    }

    private static func makeBlockBuffer(_ data: Data, video: Bool) throws -> CMBlockBuffer {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            if video {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            if video { throw PlaybackCoreError.videoDecode(status) }
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        status = data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: rawBuffer.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            if video { throw PlaybackCoreError.videoDecode(status) }
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        return blockBuffer
    }
}
