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
    private var native: OpaquePointer?
    private var drained = false
    init(inputLabels: [RenditionChannelLabel], inputRate: Int, output: AudioRenditionOutput) throws {
        let input = try RenditionAudioLayout(labels: inputLabels)
        outputLayout = try output == .stereo ? RenditionAudioLayout(labels: [.l,.r]) : input.canonical
        inputChannels = inputLabels.count
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
    func convert(_ samples: [Float], sourceSampleIndex: Int64) throws -> AudioRenditionPCMBlock {
        guard !drained, samples.count % inputChannels == 0, samples.count / inputChannels <= 16_384,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw AACRenditionFailure.invalidInput }
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
