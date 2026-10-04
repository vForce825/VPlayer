// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class AudioRenditionConverterTests: XCTestCase {
    func testMediaGraphNativePCMImpulsesPreserveEveryStereoChannel() throws {
        // 输入按 FFmpeg native mask 的置位顺序排列；golden 不从生产 label/matrix 推导。
        // 必须调用 installAudioWriterIfReady 使用的同一入口，不能人工提供正确标签。
        let rows: [(mask: UInt64, stereo: [[Float]])] = [
            (0x4, [[1,1]]),
            (0x3, [[1,0],[0,1]]),
            (0x7, [[0.58578646,0],[0,0.58578646],[0.41421357,0.41421357]]),
            (0x33, [[0.58578646,0],[0,0.58578646],[0.41421357,0],[0,0.41421357]]),
            (0x603, [[0.58578646,0],[0,0.58578646],[0.41421357,0],[0,0.41421357]]),
            (0x107, [[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323],[0.29289323,0.29289323]]),
            (0x37, [[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323],[0.29289323,0],[0,0.29289323]]),
            (0x607, [[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323],[0.29289323,0],[0,0.29289323]]),
            (0x3f, [[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323],[0,0],[0.29289323,0],[0,0.29289323]]),
            (0x60f, [[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323],[0,0],[0.29289323,0],[0,0.29289323]]),
            (0x137, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0.22654092,0],[0,0.22654092],[0.22654092,0.22654092]]),
            (0x707, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0.22654092,0.22654092],[0.22654092,0],[0,0.22654092]]),
            (0x13f, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0,0],[0.22654092,0],[0,0.22654092],[0.22654092,0.22654092]]),
            (0x70f, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0,0],[0.22654092,0.22654092],[0.22654092,0],[0,0.22654092]]),
            (0x637, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0.22654092,0],[0,0.22654092],[0.22654092,0],[0,0.22654092]]),
            (0x63f, [[0.32037723,0],[0,0.32037723],[0.22654092,0.22654092],[0,0],[0.22654092,0],[0,0.22654092],[0.22654092,0],[0,0.22654092]]),
        ]
        for row in rows {
            let channels = row.stereo.count
            let track = AudioTrackDescriptor(
                streamIndex: 0, codec: .aac,
                timeBase: try XCTUnwrap(MediaRational(num: 1, den: 48_000)),
                sampleRate: 48_000,
                channelLayout: .init(channelCount: Int32(channels), nativeMask: row.mask),
                extradata: Data())
            let converter = try SystemHLSMediaGraphAuthority.makeAudioConverter(for: track)
            XCTAssertEqual(converter.outputLayout.labels, [.l, .r])
            for channel in 0..<channels {
                var nativePCM = [Float](repeating: 0, count: channels * 64)
                nativePCM[channel] = 1
                let block = try converter.convert(
                    nativePCM, sourceSampleIndex: converter.nextSourceSampleIndex)
                XCTAssertEqual(block.frameCount, 64)
                XCTAssertEqual(Array(block.samples.prefix(2)), row.stereo[channel],
                    "native mask \(String(row.mask, radix: 16)), PCM channel \(channel)")
                XCTAssertTrue(block.samples.dropFirst(2).allSatisfy { $0 == 0 })
            }
            XCTAssertTrue(try converter.drain().samples.isEmpty)
        }
    }

    func testExplicitPositive24BitSampleRatesAreNotNarrowedByConverter() throws {
        for rate in [4_000, 384_000] {
            do {
                let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: rate, output: .fidelity)
                var frames = 0
                for source in stride(from: 0, to: rate, by: 1_024) {
                    frames += try converter.convert([Float](repeating: 0.1, count: min(1_024, rate - source)), sourceSampleIndex: Int64(source)).frameCount
                }
                frames += try converter.drain().frameCount
                XCTAssertEqual(frames, 48_000)
            } catch { XCTAssertEqual(error as? AACRenditionFailure, .capacityExceeded, "显式 AAC rate \(rate) 不得被窄白名单拒绝") }
        }
        for rate in [0, -1, 0x1000000] {
            XCTAssertThrowsError(try AudioRenditionConverter(inputLabels: [.c], inputRate: rate, output: .fidelity))
        }
    }
    // 独立的手工合同：同声道数的不同集合必须逐行命中，倒序输入验证显式重排。
    func testNineLayoutsAndPermutationsPreserveEveryGoldenImpulse() throws {
        let rows: [([RenditionChannelLabel], UInt32)] = [
            ([.c,.l,.r], kAudioChannelLayoutTag_AAC_3_0),
            ([.l,.r,.ls,.rs], kAudioChannelLayoutTag_AAC_Quadraphonic),
            ([.c,.l,.r,.cs], kAudioChannelLayoutTag_AAC_4_0),
            ([.c,.l,.r,.ls,.rs], kAudioChannelLayoutTag_AAC_5_0),
            ([.c,.l,.r,.ls,.rs,.lfe], kAudioChannelLayoutTag_AAC_5_1),
            ([.c,.l,.r,.ls,.rs,.cs], kAudioChannelLayoutTag_AAC_6_0),
            ([.c,.l,.r,.ls,.rs,.cs,.lfe], kAudioChannelLayoutTag_AAC_6_1),
            ([.c,.l,.r,.ls,.rs,.rls,.rrs], kAudioChannelLayoutTag_AAC_7_0),
            ([.c,.l,.r,.ls,.rs,.rls,.rrs,.lfe], kAudioChannelLayoutTag_AAC_7_1_B),
        ]
        let goldenStereo: [[[Float]]] = [
            [[0.41421357,0.41421357],[0.58578646,0],[0,0.58578646]],
            [[0.58578646,0],[0,0.58578646],[0.41421357,0],[0,0.41421357]],
            [[0.29289323,0.29289323],[0.41421357,0],[0,0.41421357],[0.29289323,0.29289323]],
            [[0.29289323,0.29289323],[0.41421357,0],[0,0.41421357],[0.29289323,0],[0,0.29289323]],
            [[0.29289323,0.29289323],[0.41421357,0],[0,0.41421357],[0.29289323,0],[0,0.29289323],[0,0]],
            [[0.22654092,0.22654092],[0.32037723,0],[0,0.32037723],[0.22654092,0],[0,0.22654092],[0.22654092,0.22654092]],
            [[0.22654092,0.22654092],[0.32037723,0],[0,0.32037723],[0.22654092,0],[0,0.22654092],[0.22654092,0.22654092],[0,0]],
            [[0.22654092,0.22654092],[0.32037723,0],[0,0.32037723],[0.22654092,0],[0,0.22654092],[0.22654092,0],[0,0.22654092]],
            [[0.22654092,0.22654092],[0.32037723,0],[0,0.32037723],[0.22654092,0],[0,0.22654092],[0.22654092,0],[0,0.22654092],[0,0]],
        ]
        for (row, (labels, tag)) in rows.enumerated() {
            for input in [labels, Array(labels.reversed())] {
                let converter = try AudioRenditionConverter(inputLabels: input, inputRate: 48_000, output: .fidelity)
                let stereo = try AudioRenditionConverter(inputLabels: input, inputRate: 48_000, output: .stereo)
                XCTAssertEqual(converter.outputLayout.labels, labels)
                XCTAssertEqual(converter.outputLayout.tag, tag)
                for label in input {
                    var samples = [Float](repeating: 0, count: input.count * 64)
                    samples[input.firstIndex(of: label)!] = 1
                    let block = try converter.convert(samples, sourceSampleIndex: converter.nextSourceSampleIndex)
                    XCTAssertEqual(block.sampleRate, 48_000)
                    XCTAssertEqual(block.samples.firstIndex(of: 1), labels.firstIndex(of: label))
                    XCTAssertEqual(block.samples.filter { $0 != 0 }.count, 1)
                    let downmixed = try stereo.convert(samples, sourceSampleIndex: stereo.nextSourceSampleIndex)
                    XCTAssertEqual(Array(downmixed.samples.prefix(2)), goldenStereo[row][labels.firstIndex(of: label)!])
                }
                XCTAssertTrue(try stereo.convert([Float](repeating: 1, count: input.count * 64),
                    sourceSampleIndex: stereo.nextSourceSampleIndex).samples.allSatisfy { $0 == 1 })
                XCTAssertTrue(try converter.drain().samples.isEmpty)
            }
        }
    }

    func testMatrixBinary64GoldenCoefficientsAndSilentLFE() throws {
        let labels: [RenditionChannelLabel] = [.c,.l,.r,.ls,.rs,.rls,.rrs,.lfe]
        let matrix = try StereoDownmixMatrixV1(labels: labels)
        XCTAssertEqual(StereoDownmixMatrixV1.alpha.bitPattern, 0x3FE6A09E667F3BCD)
        XCTAssertEqual(matrix.gain, 0.32037724101704074, accuracy: 1e-15)
        XCTAssertEqual(matrix.left, [0.22654091966098644,0.32037724101704074,0,0.22654091966098644,0,0.22654091966098644,0,0])
        XCTAssertEqual(matrix.right, [0.22654091966098644,0,0.32037724101704074,0,0.22654091966098644,0,0.22654091966098644,0])
        let converter = try AudioRenditionConverter(inputLabels: labels, inputRate: 48_000, output: .stereo)
        for (index, expected) in [(0,Float(0.22654091966098644)), (1,Float(0.32037724101704074)), (7,Float(0))] {
            var samples = [Float](repeating: 0, count: 64 * 8)
            samples[index] = 1
            let block = try converter.convert(samples, sourceSampleIndex: converter.nextSourceSampleIndex)
            XCTAssertEqual(block.samples[0], expected)
        }
    }

    func testEveryMatrixLabelAndFullScaleRowStayDeterministic() throws {
        let labels: [RenditionChannelLabel] = [.c,.l,.r,.ls,.rs,.cs,.lfe]
        let converter = try AudioRenditionConverter(inputLabels: labels, inputRate: 48_000, output: .stereo)
        let expected: [[Float]] = [[0.22654092,0.22654092],[0.32037723,0],[0,0.32037723],[0.22654092,0],[0,0.22654092],[0.22654092,0.22654092],[0,0]]
        for channel in 0..<7 {
            var samples = [Float](repeating: 0, count: 7 * 64)
            samples[channel] = 1
            let block = try converter.convert(samples, sourceSampleIndex: converter.nextSourceSampleIndex)
            XCTAssertEqual(Array(block.samples.prefix(2)), expected[channel])
        }
        let full = try converter.convert([Float](repeating: 1, count: 7 * 64), sourceSampleIndex: converter.nextSourceSampleIndex)
        XCTAssertTrue(full.samples.allSatisfy { $0 == 1 })
    }

    func testMonoDuplicatesAtEqualAmplitudeAndStereoHasOneSemanticRendition() throws {
        let mono = try AudioRenditionConverter(inputLabels: [.c], inputRate: 48_000, output: .stereo)
        XCTAssertEqual(try mono.convert([0.25,-0.5], sourceSampleIndex: 0).samples, [0.25,0.25,-0.5,-0.5])
        let fidelity = try AudioRenditionConverter(inputLabels: [.c], inputRate: 48_000, output: .fidelity)
        XCTAssertEqual(fidelity.outputLayout.tag, kAudioChannelLayoutTag_Mono)
        let stereo = try AACRenditionRequest(layout: RenditionAudioLayout(labels: [.l,.r]), capabilityVersion: "fixture")
        XCTAssertEqual(try AACCalibrationPlan.build([stereo,stereo]).entries.count, 1)
    }

    func testUnsupportedMissingDuplicateAndFutureLabelsFailBeforeNativeAllocation() {
        let invalid: [[RenditionChannelLabel]] = [[], [.unknown], [.discrete], [.l,.l], [.l], [.l,.r,.lc], [.l,.r,.height], [.l,.r,.ls,.cs]]
        for labels in invalid {
            XCTAssertThrowsError(try AudioRenditionConverter(inputLabels: labels, inputRate: 48_000, output: .fidelity))
            XCTAssertThrowsError(try AudioRenditionConverter(inputLabels: labels, inputRate: 48_000, output: .stereo))
        }
        XCTAssertThrowsError(try RenditionAudioLayout(native: AudioChannelLayout(channelCount: 6, nativeMask: nil)))
        XCTAssertThrowsError(try RenditionAudioLayout(native: AudioChannelLayout(channelCount: 5, nativeMask: 0x3f)))
    }

    func testNativeMasksUseExactSemanticMapping() throws {
        XCTAssertEqual(try RenditionAudioLayout(native: AudioChannelLayout(channelCount: 6, nativeMask: 0x3f)).labels, [.l,.r,.c,.lfe,.ls,.rs])
        XCTAssertEqual(try RenditionAudioLayout(native: AudioChannelLayout(channelCount: 8, nativeMask: 0x63f)).labels, [.l,.r,.c,.lfe,.rls,.rrs,.ls,.rs])
        XCTAssertThrowsError(try RenditionAudioLayout(native: AudioChannelLayout(channelCount: 4, nativeMask: 0xc03)))
    }

    func testResampleUsesDelayAndDrainsExactIntegerSampleClock() throws {
        for rate in [7_350,8_000,11_025,22_050,44_100] {
            let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: rate, output: .fidelity)
            var outputFrames = 0
            var source = 0
            while source < rate * 3 {
                let count = min(137, rate * 3 - source)
                let block = try converter.convert([Float](repeating: 0.1, count: count), sourceSampleIndex: Int64(source))
                XCTAssertEqual(block.presentationTimeStamp, CMTime(value: 480_000 + Int64(outputFrames), timescale: 48_000))
                outputFrames += block.frameCount
                source += count
            }
            let tail = try converter.drain()
            XCTAssertGreaterThan(tail.frameCount, 0)
            outputFrames += tail.frameCount
            XCTAssertEqual(outputFrames, 144_000)
            XCTAssertEqual(converter.outputSampleCount, 144_000)
            XCTAssertTrue(try converter.drain().samples.isEmpty)
        }
    }

    func testProductionPCMBridgePreservesFirstOffsetAndMissingAccessUnitGap() throws {
        let (bridge, converter) = try makeTimedBridge()
        defer { bridge.destroy() }
        let first = try XCTUnwrap(bridge.push(timedPacket(id: 1, sampleIndex: 12_000)).first)
        XCTAssertEqual(first.presentationTimeStamp, CMTime(value: 492_000, timescale: 48_000))
        let a = try converter.convert(first)
        XCTAssertEqual(a.frameCount, 12_000 + 1_024)
        XCTAssertTrue(a.samples.prefix(24_000).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(a.samples.dropFirst(24_000)), first.samples.map { min(1, max(-1, $0)) })
        let second = try XCTUnwrap(bridge.push(timedPacket(id: 2, sampleIndex: 14_048)).first)
        XCTAssertTrue(second.samples.contains { abs($0) > 1 },
                      "real AAC decoder fixture must exercise finite codec headroom")
        let b = try converter.convert(second)
        XCTAssertEqual(b.presentationTimeStamp, CMTime(value: 493_024, timescale: 48_000))
        XCTAssertEqual(b.frameCount, 2_048)
        XCTAssertTrue(b.samples.prefix(2_048).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(b.samples.dropFirst(2_048)), second.samples.map { min(1, max(-1, $0)) })
        XCTAssertEqual(converter.nextSourceSampleIndex, 15_072)
    }

    func testProductionBridgeThroughAACWriterRetainsOffsetAndGapInEffectiveTime() async throws {
        let (bridge, converter) = try makeTimedBridge()
        defer { bridge.destroy() }
        var pcm: [Float] = []
        for (id, index): (UInt64, Int64) in [(1, 12_000), (2, 14_048)] {
            for decoded in try bridge.push(timedPacket(id: id, sampleIndex: index)) {
                pcm += try converter.convert(decoded).samples
            }
        }
        for decoded in try bridge.drainForNaturalEOF() { pcm += try converter.convert(decoded).samples }
        pcm += try converter.drain().samples
        XCTAssertEqual(pcm.count, 15_072 * 2)
        let request = try AACRenditionRequest(layout: RenditionAudioLayout(labels: [.l, .r]),
                                             capabilityVersion: "review-timing")
        let receipt = try await AACPrimingCalibrator().calibrate(plan: AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(receipt.encoders.first)
        let epoch = try encoder.encodeEpoch(pcm)
        let decoded = try await AACSystemLoopback.decode(epoch: epoch)
        XCTAssertEqual(decoded.inputTiming.effectiveStartPTS, CMTime(value: 10, timescale: 1))
        XCTAssertEqual(decoded.inputTiming.effectiveSampleCount, 15_072)
        XCTAssertEqual(decoded.inputTiming.effectiveEndPTS, CMTime(value: 495_072, timescale: 48_000))
        let leading = epoch.leadingFrames
        // Lossy coding can ring around transitions; observe windows safely inside
        // the first silence, the missing-AU gap and the later loud tone marker.
        let early = decoded.rawSamples[(leading * 2)..<((leading + 10_000) * 2)]
        XCTAssertLessThan(early.reduce(0.0) { $0 + Double($1 * $1) } / Double(early.count), 0.000001)
        let gap = decoded.rawSamples[((leading + 13_400) * 2)..<((leading + 13_672) * 2)]
        XCTAssertLessThan(gap.reduce(0.0) { $0 + Double($1 * $1) } / Double(gap.count), 0.0001)
        let marker = decoded.rawSamples[((leading + 14_304) * 2)..<((leading + 14_816) * 2)]
        XCTAssertGreaterThan(marker.reduce(0.0) { $0 + Double($1 * $1) } / Double(marker.count), 0.1)
    }

    func testProductionPCMBridgeRestoresPreTrimPTSAndDropsLeadingSamplesExactlyOnce() throws {
        let (bridge, converter) = try makeTimedBridge()
        defer { bridge.destroy() }
        let decoded = try XCTUnwrap(bridge.push(timedPacket(id: 1, sampleIndex: -512, trim: 512)).first)
        XCTAssertEqual(decoded.presentationTimeStamp, CMTime(value: 479_488, timescale: 48_000))
        XCTAssertEqual(decoded.samples.count, 2_048, "decoder retains the complete AU")
        let converted = try converter.convert(decoded)
        XCTAssertEqual(converted.presentationTimeStamp, CMTime(value: 10, timescale: 1))
        XCTAssertEqual(converted.frameCount, 512)
        XCTAssertEqual(converted.samples, Array(decoded.samples.dropFirst(1_024)).map { min(1, max(-1, $0)) })
        XCTAssertEqual(converter.nextSourceSampleIndex, 512)
    }

    func testProductionPCMBridgeRejectsNewOriginGenerationInsteadOfJoiningOldClock() throws {
        let (bridge, _) = try makeTimedBridge()
        defer { bridge.destroy() }
        _ = try bridge.push(timedPacket(id: 1, sampleIndex: 0))
        let first = try timedPacket(id: 2, sampleIndex: 0)
        let reset = HLSTimedAudioAccessUnit(source: first.source,
            generation: .init(rawValue: 2), timing: first.timing,
            boundaryDecision: first.boundaryDecision)
        XCTAssertThrowsError(try bridge.push(reset)) {
            XCTAssertEqual($0 as? HLSPublicationFailure, .identityMismatch)
        }
    }

    func testProductionTimedPCMStreamsOneSecondGapInBoundedBlocks() throws {
        let (bridge, converter) = try makeTimedBridge()
        defer { bridge.destroy() }
        let decoded = try XCTUnwrap(bridge.push(timedPacket(id: 1, sampleIndex: 48_000)).first)
        var frames = 0
        var blocks = 0
        while let silence = try converter.fillGap(before: decoded) {
            XCTAssertLessThanOrEqual(silence.frameCount, 16_384)
            XCTAssertTrue(silence.samples.allSatisfy { $0 == 0 })
            XCTAssertEqual(silence.presentationTimeStamp, CMTime(value: 480_000 + Int64(frames), timescale: 48_000))
            frames += silence.frameCount
            blocks += 1
        }
        XCTAssertEqual(frames, 48_000)
        XCTAssertEqual(blocks, 3)
        let audio = try converter.convert(decoded)
        XCTAssertEqual(audio.presentationTimeStamp, CMTime(value: 11, timescale: 1))
        XCTAssertEqual(audio.frameCount, 1_024)
        XCTAssertEqual(converter.outputSampleCount, 49_024)
    }

    func testLowExplicitRateGapChoosesChunksWithinNativeSRCCapacity() throws {
        let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: 4_000, output: .fidelity)
        // 16,384 source frames would require 196,608 output frames before delay.
        // Rejection must not advance either clock or poison subsequent smaller input.
        XCTAssertThrowsError(try converter.convert([Float](repeating: 0, count: 16_384), sourceSampleIndex: 0)) {
            XCTAssertEqual($0 as? AACRenditionFailure, .capacityExceeded)
        }
        XCTAssertEqual(converter.nextSourceSampleIndex, 0)
        XCTAssertEqual(converter.outputSampleCount, 0)
        let decoded = SystemHLSDecodedPCMBlock(samples: [Float](repeating: 0.1, count: 1_024),
            channelCount: 1, sampleRate: 4_000, presentationTimeStamp: CMTime(value: 15, timescale: 1))
        var frames = 0
        var chunks = 0
        while let silence = try converter.fillGap(before: decoded) {
            XCTAssertGreaterThan(silence.frameCount, 0)
            XCTAssertLessThanOrEqual(silence.frameCount, 131_072)
            XCTAssertEqual(silence.presentationTimeStamp, CMTime(value: 480_000 + Int64(frames), timescale: 48_000))
            XCTAssertTrue(silence.samples.allSatisfy { $0 == 0 })
            frames += silence.frameCount
            chunks += 1
        }
        XCTAssertGreaterThan(chunks, 1)
        XCTAssertEqual(converter.nextSourceSampleIndex, 20_000)
        frames += try converter.convert(decoded).frameCount
        frames += try converter.drain().frameCount
        XCTAssertEqual(frames, (20_000 + 1_024) * 12)
        XCTAssertEqual(converter.nextSourceSampleIndex, 21_024)
        XCTAssertEqual(converter.outputSampleCount, Int64(frames))
    }

    func testTimedPCMRejectsChangedFormatAndInvalidTimeBeforeAdvancingClock() throws {
        let (_, converter) = try makeTimedBridge()
        for block in [
            SystemHLSDecodedPCMBlock(samples: [0, 0], channelCount: 2, sampleRate: 44_100,
                                     presentationTimeStamp: CMTime(value: 10, timescale: 1)),
            SystemHLSDecodedPCMBlock(samples: [0], channelCount: 1, sampleRate: 48_000,
                                     presentationTimeStamp: CMTime(value: 10, timescale: 1)),
            SystemHLSDecodedPCMBlock(samples: [0, 0], channelCount: 2, sampleRate: 48_000,
                                     presentationTimeStamp: .invalid),
        ] {
            XCTAssertThrowsError(try converter.convert(block))
            XCTAssertEqual(converter.outputSampleCount, 0)
        }
    }

    private func makeTimedBridge() throws -> (SystemHLSAudioPCMBridge, AudioRenditionConverter) {
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90, 0x56, 0xE5, 0]))
        var configuration: CompressedAudioRenderConfiguration?
        let assembler = try CompressedAudioAssembler(trackSet: tracks,
            generationProvider: { .init(rawValue: 1) }, eventSink: {
                if case .format(let value) = $0 { configuration = value }
            }, formatState: AssemblyFormatState(trackSet: tracks))
        try assembler.push(AssemblerTestFixtures.audioPacket(data: Self.timedPayload, codec: .aac))
        let bridge = try SystemHLSAudioPCMBridge(configuration: XCTUnwrap(configuration),
            copyOwnership: HLSAudioCopyOwnership(maximumCompressedBytes: 1_048_576,
                                                 maximumPCMBytes: 8_388_608, capacity: 8))
        return (bridge, try SystemHLSMediaGraphAuthority.makeAudioConverter(for: XCTUnwrap(tracks.audio)))
    }

    private func timedPacket(id: UInt64, sampleIndex: Int64, trim: Int64 = 0) throws -> HLSTimedAudioAccessUnit {
        let source = CompressedAudioFrame(id: id,
            payload: id == 2 ? Self.loudSecondPayload : Self.timedPayload, codec: .aac,
            generation: .init(rawValue: 1), presentationTimeStamp: CMTime(value: sampleIndex, timescale: 48_000),
            duration: CMTime(value: 1_024, timescale: 48_000), frameSampleCount: 1_024)
        return HLSTimedAudioAccessUnit(source: source, generation: .init(rawValue: 1),
            timing: NormalizedSampleTiming(
                presentationTimeStamp: .init(value: 480_000 + sampleIndex + trim, timescale: 48_000),
                decodeTimeStamp: nil, duration: .init(value: 1_024 - trim, timescale: 48_000)),
            boundaryDecision: trim == 0 ? .unchanged : .trimLeading(.init(value: trim, timescale: 48_000)))
    }

    // FFmpeg 7.1.5 native AAC, stereo 48 kHz, first AU from a 997 Hz sine at 0.99.
    // Raw payload is retained so these regressions use the production FFmpeg decoder.
    private static let loudSecondPayload = Data(base64Encoded: "IUxs/gf8f8f8S9lrutVWSO7SYpLtJq//D+f3aeer1d8f1+uvqwmuf/2/97Bd3X/7f9bCXehN1Qh+YsGLs7Oz+w1MvnsgCZgwcm06Ig+5EjztgZ3q4T02rbe0zqRtMM3MV5j0XQs7kOVcDvNyrNar8gzYcezmzWV9flKocQcCSkWzHtxkmhSPrwxwkmdnYjIyPGul2cGBgZ3cJCQkGBjbu4SEhIMDA0ru7hISEhJGfGJaLE53hkMNxElGvkZPQ7MNu4kJl6VHFaSN4NTNJz248KSLJyCepT0ECzwc0XUP23rnVWLxTmbKPC69ca1PtFZjgsjZpGNjlKo2QGBJNWTHtxwmhYXrwxw+TaGBjy3+k6pCdDAwM7uEhISDAwM7uEhISDAwMDO7uEhISEkc9liXOegEJMKWhkbhrubZp6yB4rrbhduxtijY5qq7ccMcMcJpJsJpJnaSaRnbCaSZ2dpcduHr2PXsevb/8P5/dp56vV3x/X66+rAf/t/72Adf/t/1sIAAAAAAAAAAAAAAAAAAOA==")!
    private static let timedPayload = Data(base64Encoded: "3gIATGF2YzYxLjE5LjEwMQBCVR/////4AnLnDCJp2ZF7Z63+urjUvma3Jkkk7I9BAd1dw6O0jbVs5izDpLRvnXxO4tm9les83ei0l0L/uQCXkzTpcVxwPCA3N5bxlzbmrsnZWfdVaR1ViuLYTT1kz1qnMWacKzDl7FcvWzhWac1ZdxbLuLa3GxcbFtsXGxcbFxvB3Xa7rW67W66bOmzps6bOmzps6bOmzpsabOmzps6LOiziSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSiSnininnyX4ooooooooooooooooooooooooooooooopwfi8WnZkXtnrf66uNS+ZrcmSSTsPQQAAAAAAAAAAAAAAAAAAAcA=")!

    func testFiniteDecoderHeadroomClipsOnlyAtAACOutputBoundary() throws {
        let converter = try AudioRenditionConverter(inputLabels: [.l, .r], inputRate: 48_000, output: .fidelity)
        let result = try converter.convert([1.0002205, -1.01, 0.5, -0.5], sourceSampleIndex: 0)
        XCTAssertEqual(result.samples, [1, -1, 0.5, -0.5])
    }

    func testInRangeHighAmplitudeSRCContinuesThroughOvershootAndDrain() throws {
        for rate in [24_000, 32_000, 44_100] {
            let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: rate, output: .fidelity)
            let input = (0..<rate).map { Float(($0 / 20) % 2 == 0 ? -0.99 : 0.99) }
            var output: [Float] = []
            for start in stride(from: 0, to: rate, by: 1_024) {
                output += try converter.convert(Array(input[start..<min(start + 1_024, rate)]),
                                                sourceSampleIndex: Int64(start)).samples
            }
            output += try converter.drain().samples
            XCTAssertEqual(output.count, 48_000)
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
            XCTAssertTrue(output.contains { abs($0) == 1 })
        }
    }

    func testGapOverlapAndOriginUseSourceIndexOnlyForCoverage() throws {
        let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: 48_000, output: .fidelity)
        let a = try converter.convert([0.25,0.5], sourceSampleIndex: 2)
        XCTAssertEqual(a.samples, [0,0,0.25,0.5])
        XCTAssertEqual(a.presentationTimeStamp, CMTime(value: 10, timescale: 1))
        let b = try converter.convert([-0.5,0.75], sourceSampleIndex: 3)
        XCTAssertEqual(b.samples, [0.75])
        XCTAssertEqual(b.presentationTimeStamp, CMTime(value: 480_004, timescale: 48_000))
        XCTAssertTrue(try converter.convert([0.1], sourceSampleIndex: 0).samples.isEmpty)
        XCTAssertEqual(converter.outputSampleCount, 5)
    }

    func testNonFiniteAndOversizedInputFailWithoutAdvancingClock() throws {
        let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: 48_000, output: .stereo)
        for samples: [Float] in [[.nan],[.infinity],[-.infinity],[Float](repeating: 0, count: 16_385)] {
            XCTAssertThrowsError(try converter.convert(samples, sourceSampleIndex: 0))
            XCTAssertEqual(converter.outputSampleCount, 0)
        }
        XCTAssertThrowsError(try converter.convert([0], sourceSampleIndex: 20_000))
        XCTAssertThrowsError(try converter.convert([0], sourceSampleIndex: Int64.max))
        XCTAssertTrue(try converter.convert([0], sourceSampleIndex: Int64.min).samples.isEmpty)
    }
}
