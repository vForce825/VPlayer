// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

/// Decoder timestamps describe complete source AUs, including samples before the
/// selected media origin. The converter alone trims overlap and fills bounded gaps.
struct SystemHLSDecodedPCMBlock {
    let samples: [Float]
    let channelCount: Int
    let sampleRate: Int
    let presentationTimeStamp: CMTime
}

/// 选中音频轨的生产 PCM 桥。压缩 AU 仅在本桥内物化为 CMSampleBuffer，随后同步交给
/// FFmpeg；输出 PCM 立即转为 interleaved Float，调用方不得保存 decoder callback backing。
final class SystemHLSAudioPCMBridge: @unchecked Sendable {
    private let configuration: CompressedAudioRenderConfiguration
    private let decoder: FFmpegPCMAudioDecoder
    private let lock = NSLock()
    private var ended = false
    private var generation: HLSTimelineGeneration?

    init(configuration: CompressedAudioRenderConfiguration,
         copyOwnership: HLSAudioCopyOwnership) throws {
        self.configuration = configuration
        decoder = try FFmpegPCMAudioDecoder(codec: configuration.codec,
                                            extradata: configuration.decoderExtradata,
                                            hlsCopyOwnership: copyOwnership)
    }

    func push(_ timed: HLSTimedAudioAccessUnit) throws -> [SystemHLSDecodedPCMBlock] {
        guard timed.source.codec == configuration.codec,
              timed.timing.presentationTimeStamp.cmTime.isNumeric,
              timed.timing.duration?.cmTime.isNumeric == true,
              !lock.withLock({ ended }) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode)
        }
        // This decoder/converter/encoder epoch has one origin. Until the media graph
        // replaces that epoch, a timeline reset must fail explicitly, never masquerade
        // as overlapping PCM on the previous clock and silently discard new content.
        try lock.withLock {
            guard generation == nil || generation == timed.generation else {
                throw HLSPublicationFailure.identityMismatch
            }
            generation = timed.generation
        }
        let sample = try makeCompressedSample(timed)
        var output: [SystemHLSDecodedPCMBlock] = []
        try decoder.pushStreamingForHLS(sample) { pcm in output.append(try Self.interleavedPCM(pcm)) }
        return output
    }

    func drainForNaturalEOF() throws -> [SystemHLSDecodedPCMBlock] {
        guard !lock.withLock({ ended }) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.destroyedErrorCode)
        }
        let output = try decoder.drainForNaturalEOF().map(Self.interleavedPCM)
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
        guard let frames = UInt32(exactly: timed.source.frameSampleCount), frames > 0 else { throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode) }
        // Timeline shortens the visible interval of an AU crossing the origin,
        // but the codec must decode that entire AU with its original normalized PTS.
        let decodePTS: CMTime
        switch timed.boundaryDecision {
        case .unchanged:
            decodePTS = timed.timing.presentationTimeStamp.cmTime
        case .trimLeading(let trim):
            guard trim.value > 0,
                  CMTimeCompare(trim.cmTime, timed.source.duration) < 0 else {
                throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode)
            }
            decodePTS = CMTimeSubtract(timed.timing.presentationTimeStamp.cmTime, trim.cmTime)
        }
        guard decodePTS.isNumeric, decodePTS.epoch == 0 else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidPacketErrorCode)
        }
        var description = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: frames, mDataByteSize: UInt32(payload.length))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: configuration.formatDescription, sampleCount: 1,
            presentationTimeStamp: decodePTS,
            packetDescriptions: &description, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw PlaybackCoreError.audioFormatDescription(status) }
        return .init(id: timed.source.id, sampleBuffer: sample, codec: timed.source.codec,
                     generation: .init(rawValue: timed.generation.rawValue),
                     presentationTimeStamp: decodePTS,
                     duration: timed.source.duration,
                     continuityIslandID: .init(rawValue: timed.generation.rawValue))
    }

    private static func interleavedPCM(_ sample: CMSampleBuffer) throws -> SystemHLSDecodedPCMBlock {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 8,
              asbd.mBytesPerFrame == 4 * asbd.mChannelsPerFrame,
              asbd.mSampleRate.isFinite, asbd.mSampleRate >= 1, asbd.mSampleRate <= 0xFF_FFFF,
              asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
              CMSampleBufferGetPresentationTimeStamp(sample).isNumeric,
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
        let channels = Int(asbd.mChannelsPerFrame)
        guard count % channels == 0,
              count / channels == CMSampleBufferGetNumSamples(sample) else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)
        }
        let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
        return SystemHLSDecodedPCMBlock(
            samples: Array(UnsafeBufferPointer(start: floats, count: count)),
            channelCount: channels, sampleRate: Int(asbd.mSampleRate),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample))
    }
}
