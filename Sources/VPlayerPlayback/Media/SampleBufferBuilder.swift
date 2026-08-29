// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import OSLog

enum SampleBufferBuilder {
    static let invalidDataErrorCode: Int32 = -1_448_143_362
    private static let maximumVideoPayloadBytes = 64 * 1_024 * 1_024
    private static let logger = Logger(
        subsystem: "com.vplayer.playback",
        category: "SampleBufferBuilder"
    )

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
            logger.error(
                "video sample buffer creation failed status=\(status, privacy: .public) hasBuffer=\(sampleBuffer != nil, privacy: .public)"
            )
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
        frame: AdmittedAudioFrame,
        formatDescription: CMAudioFormatDescription,
        forceResetDecoderBeforeDecoding: Bool
    ) throws -> CMSampleBuffer {
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescription
        )?.pointee,
        let frameSampleCount = UInt32(exactly: frame.frame.frameSampleCount),
        frameSampleCount > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }

        let variableFramesInPacket: UInt32
        if streamDescription.mFramesPerPacket == 0 {
            variableFramesInPacket = frameSampleCount
        } else {
            guard streamDescription.mFramesPerPacket == frameSampleCount else {
                throw PlaybackCoreError.audioFallbackDecode(
                    CompressedAudioAssembler.invalidInputErrorCode
                )
            }
            variableFramesInPacket = 0
        }

        let sampleBuffer = try makeAudioSample(
            data: frame.frame.payload,
            formatDescription: formatDescription,
            presentationTimeStamp: frame.normalizedPresentationTimeStamp,
            variableFramesInPacket: variableFramesInPacket
        )
        if frame.resetDecoderBeforeDecoding || forceResetDecoderBeforeDecoding {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        if frame.fillDiscontinuitiesWithSilence {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return sampleBuffer
    }

    static func copyingAudioSampleBufferWithResetDecoderBeforeDecoding(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> CMSampleBuffer {
        var copiedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copiedBuffer
        )
        guard status == noErr, let copiedBuffer else {
            throw PlaybackCoreError.audioFallbackDecode(status)
        }
        CMSetAttachment(
            copiedBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return copiedBuffer
    }

    static func compressedAudioPayloadByteCount(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> Int {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        let blockLength = CMBlockBufferGetDataLength(dataBuffer)
        let totalSampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        guard blockLength > 0, totalSampleSize == blockLength else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        return blockLength
    }

    private static func makeAudioSample(
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
        guard try compressedAudioPayloadByteCount(sampleBuffer) == data.count else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        return sampleBuffer
    }

    private static func makeBlockBuffer(_ data: Data, video: Bool) throws -> CMBlockBuffer {
        let maximumPayloadBytes = video
            ? maximumVideoPayloadBytes
            : AudioCodecProfileValidation.maximumRawAACAccessUnitBytes
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
            if video {
                logger.error(
                    "video block buffer creation failed status=\(status, privacy: .public) hasBuffer=\(blockBuffer != nil, privacy: .public)"
                )
                throw PlaybackCoreError.videoDecode(status)
            }
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
            if video {
                logger.error(
                    "video block buffer copy failed status=\(status, privacy: .public)"
                )
                throw PlaybackCoreError.videoDecode(status)
            }
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        return blockBuffer
    }
}
