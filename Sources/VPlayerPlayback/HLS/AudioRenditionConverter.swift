// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum AudioRenditionOutput { case fidelity, stereo }
struct AudioRenditionPCMBlock {
    let samples: [Float]
    let channelCount: Int
    let presentationTimeStamp: CMTime
    var sampleRate: Int { 48_000 }
    var frameCount: Int { samples.count / max(1, channelCount) }
}
final class AudioRenditionConverter {
    let outputLayout: RenditionAudioLayout
    private(set) var nextSourceSampleIndex: Int64 = 0
    private(set) var outputSampleCount: Int64 = 0
    private let inputChannels: Int
    private let inputRate: Int
    private var native: OpaquePointer?
    private var drained = false
    init(inputLabels: [RenditionChannelLabel], inputRate: Int, output: AudioRenditionOutput) throws {
        let input = try RenditionAudioLayout(labels: inputLabels)
        outputLayout = try output == .stereo ? RenditionAudioLayout(labels: [.l,.r]) : input.canonical
        inputChannels = inputLabels.count
        self.inputRate = inputRate
        guard inputRate >= 1, inputRate <= 0xFFFFFF else { throw AACRenditionFailure.invalidInput }
        let matrix: [Double]
        if output == .stereo {
            let downmix = try StereoDownmixMatrixV1(labels: inputLabels)
            matrix = downmix.left + downmix.right
        } else {
            matrix = outputLayout.labels.flatMap { label in inputLabels.map { $0 == label ? 1.0 : 0.0 } }
        }
        let status = vp_ffmpeg_audio_converter_create(inputLabels.map(\.rawValue), Int32(inputChannels),
            outputLayout.labels.map(\.rawValue), Int32(outputLayout.labels.count), Int32(inputRate), matrix, &native)
        guard status == 0, native != nil else { throw AACRenditionFailure.framework(status) }
    }
    deinit { vp_ffmpeg_audio_converter_destroy(native) }
    /// Decoder PTS, not decoded-frame arrival order, determines source coverage.
    /// Quantize once to the nearest source sample (container time bases may be coarser).
    func convert(_ decoded: SystemHLSDecodedPCMBlock) throws -> AudioRenditionPCMBlock {
        try convert(decoded.samples, sourceSampleIndex: sourceSampleIndex(for: decoded))
    }

    /// Materialize only one admitted silence chunk. The graph pumps it before asking
    /// for another, so an ordinary multi-second gap never becomes one large allocation
    /// or gets compressed out of the timeline. Its cancellation/publication fences still
    /// bound how much work can run ahead. Direct array calls retain their per-call cap.
    func fillGap(before decoded: SystemHLSDecodedPCMBlock) throws -> AudioRenditionPCMBlock? {
        let index = try sourceSampleIndex(for: decoded)
        guard index > nextSourceSampleIndex else { return nil }
        var frames = Int(min(16_384, index - nextSourceSampleIndex))
        // Low explicit rates can expand one source chunk beyond the native output
        // cap. Capacity includes the current SRC delay and does not consume input;
        // find an admissible chunk before allocating or changing either sample clock.
        var capacity = vp_ffmpeg_audio_converter_capacity(native, Int32(frames))
        while capacity == -EOVERFLOW, frames > 1 {
            frames /= 2
            capacity = vp_ffmpeg_audio_converter_capacity(native, Int32(frames))
        }
        guard capacity != -EOVERFLOW else { throw AACRenditionFailure.capacityExceeded }
        guard capacity > 0 else { throw AACRenditionFailure.framework(capacity) }
        return try convert([Float](repeating: 0, count: frames * inputChannels),
                           sourceSampleIndex: nextSourceSampleIndex)
    }

    private func sourceSampleIndex(for decoded: SystemHLSDecodedPCMBlock) throws -> Int64 {
        guard !drained, decoded.sampleRate == inputRate, decoded.channelCount == inputChannels,
              !decoded.samples.isEmpty, decoded.samples.count % inputChannels == 0,
              decoded.samples.count / inputChannels <= 16_384,
              decoded.samples.allSatisfy({ $0.isFinite }),
              decoded.presentationTimeStamp.isNumeric, decoded.presentationTimeStamp.epoch == 0 else {
            throw AACRenditionFailure.invalidInput
        }
        let delta = CMTimeSubtract(decoded.presentationTimeStamp, CMTime(value: 10, timescale: 1))
        let index = CMTimeConvertScale(delta, timescale: Int32(inputRate), method: .roundHalfAwayFromZero)
        guard index.isNumeric, index.epoch == 0, index.timescale == Int32(inputRate),
              !index.value.addingReportingOverflow(Int64(decoded.samples.count / inputChannels)).overflow else {
            throw AACRenditionFailure.invalidInput
        }
        return index.value
    }

    func convert(_ samples: [Float], sourceSampleIndex: Int64) throws -> AudioRenditionPCMBlock {
        guard !drained, samples.count % inputChannels == 0, samples.count / inputChannels <= 16_384,
              samples.allSatisfy({ $0.isFinite }) else { throw AACRenditionFailure.invalidInput }
        let frames = samples.count / inputChannels
        let (end, overflow) = sourceSampleIndex.addingReportingOverflow(Int64(frames))
        guard !overflow else { throw AACRenditionFailure.invalidInput }
        let pts = try timestamp()
        if end <= nextSourceSampleIndex { return block([], pts: pts) }
        let gap = sourceSampleIndex > nextSourceSampleIndex ? sourceSampleIndex - nextSourceSampleIndex : 0
        guard gap <= 16_384 else { throw AACRenditionFailure.capacityExceeded }
        let overlap = min(Int64(frames), max(0, nextSourceSampleIndex - sourceSampleIndex))
        guard gap + Int64(frames) - overlap <= 16_384 else { throw AACRenditionFailure.capacityExceeded }
        var input = [Float](repeating: 0, count: Int(gap) * inputChannels)
        input.append(contentsOf: samples.dropFirst(Int(overlap) * inputChannels))
        let output = try convertNative(input)
        nextSourceSampleIndex = end
        return block(output, pts: pts)
    }
    func drain() throws -> AudioRenditionPCMBlock {
        let pts = try timestamp()
        if drained { return block([], pts: pts) }
        var result: [Float] = []
        while true {
            let tail = try convertNative([])
            if tail.isEmpty { break }
            guard result.count + tail.count <= 131_072 * outputLayout.labels.count else { throw AACRenditionFailure.capacityExceeded }
            result.append(contentsOf: tail)
        }
        drained = true
        return block(result, pts: pts)
    }
    private func timestamp() throws -> CMTime {
        let (value, overflow) = outputSampleCount.addingReportingOverflow(480_000)
        guard !overflow else { throw AACRenditionFailure.invalidInput }
        return CMTime(value: value, timescale: 48_000)
    }
    private func block(_ samples: [Float], pts: CMTime) -> AudioRenditionPCMBlock {
        AudioRenditionPCMBlock(samples: samples, channelCount: outputLayout.labels.count, presentationTimeStamp: pts)
    }
    private func convertNative(_ input: [Float]) throws -> [Float] {
        let frames = Int32(input.count / inputChannels)
        let capacity = vp_ffmpeg_audio_converter_capacity(native, frames)
        guard capacity != -EOVERFLOW else { throw AACRenditionFailure.capacityExceeded }
        guard capacity > 0 else { throw AACRenditionFailure.framework(capacity) }
        var output = [Float](repeating: 0, count: Int(capacity) * outputLayout.labels.count)
        let converted = input.withUnsafeBufferPointer { source in
            vp_ffmpeg_audio_converter_convert(native, source.baseAddress, frames, &output, capacity)
        }
        guard converted >= 0 else { throw AACRenditionFailure.framework(converted) }
        output.removeLast(output.count - Int(converted) * outputLayout.labels.count)
        let (next, overflow) = outputSampleCount.addingReportingOverflow(Int64(converted))
        guard !overflow else { throw AACRenditionFailure.invalidInput }
        outputSampleCount = next
        return output
    }
}
