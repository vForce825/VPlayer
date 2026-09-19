// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

/// 选中音频轨的生产 PCM 桥。压缩 AU 仅在本桥内物化为 CMSampleBuffer，随后同步交给
/// FFmpeg；输出 PCM 立即转为 interleaved Float，调用方不得保存 decoder callback backing。
final class SystemHLSAudioPCMBridge: @unchecked Sendable {
    private let configuration: CompressedAudioRenderConfiguration
    private let decoder: FFmpegPCMAudioDecoder
    private let lock = NSLock()
    private var ended = false

    init(configuration: CompressedAudioRenderConfiguration,
         copyOwnership: HLSAudioCopyOwnership) throws {
        self.configuration = configuration
        decoder = try FFmpegPCMAudioDecoder(codec: configuration.codec,
                                            extradata: configuration.decoderExtradata,
                                            hlsCopyOwnership: copyOwnership)
    }

    func push(_ timed: HLSTimedAudioAccessUnit) throws -> [[Float]] {
        guard timed.source.codec == configuration.codec,
              timed.timing.presentationTimeStamp.cmTime.isNumeric,
              timed.timing.duration?.cmTime.isNumeric == true,
              !lock.withLock({ ended }) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode)
        }
        let sample = try makeCompressedSample(timed)
        var output: [[Float]] = []
        try decoder.pushStreamingForHLS(sample) { pcm in output.append(try Self.interleavedFloats(pcm)) }
        return output
    }

    func drainForNaturalEOF() throws -> [[Float]] {
        guard !lock.withLock({ ended }) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.destroyedErrorCode)
        }
        let output = try decoder.drainForNaturalEOF().map(Self.interleavedFloats)
        lock.withLock { ended = true }
        return output
    }

    func destroy() { lock.withLock { ended = true }; decoder.destroy() }

    private func makeCompressedSample(_ timed: HLSTimedAudioAccessUnit) throws -> CompressedAudioSample {
        var block: CMBlockBuffer?
        let payload = timed.source.payload as NSData
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.length, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: payload.bytes, blockBuffer: block,
                                            offsetIntoDestination: 0, dataLength: payload.length) == kCMBlockBufferNoErr else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode)
        }
        let frames = UInt32(timed.source.frameSampleCount)
        guard frames > 0 else { throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode) }
        var description = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: frames, mDataByteSize: UInt32(payload.length))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: configuration.formatDescription, sampleCount: 1,
            presentationTimeStamp: timed.timing.presentationTimeStamp.cmTime,
            packetDescriptions: &description, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw PlaybackCoreError.audioFormatDescription(status) }
        return .init(id: timed.source.id, sampleBuffer: sample, codec: timed.source.codec,
                     generation: .init(rawValue: timed.generation.rawValue),
                     presentationTimeStamp: timed.timing.presentationTimeStamp.cmTime,
                     duration: timed.timing.duration!.cmTime,
                     continuityIslandID: .init(rawValue: timed.generation.rawValue))
    }

    private static func interleavedFloats(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let block = CMSampleBufferGetDataBuffer(sample) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)
        }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length % MemoryLayout<Float>.stride == 0 else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)
        }
        let count = length / MemoryLayout<Float>.stride
        let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: floats, count: count))
    }
}
