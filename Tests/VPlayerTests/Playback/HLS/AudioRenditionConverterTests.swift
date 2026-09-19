// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class AudioRenditionConverterTests: XCTestCase {
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

    func testNonFiniteOutOfRangeAndOversizedInputFailWithoutAdvancingClock() throws {
        let converter = try AudioRenditionConverter(inputLabels: [.c], inputRate: 48_000, output: .stereo)
        for samples: [Float] in [[.nan],[.infinity],[1.01],[-1.01],[Float](repeating: 0, count: 16_385)] {
            XCTAssertThrowsError(try converter.convert(samples, sourceSampleIndex: 0))
            XCTAssertEqual(converter.outputSampleCount, 0)
        }
        XCTAssertThrowsError(try converter.convert([0], sourceSampleIndex: 20_000))
        XCTAssertThrowsError(try converter.convert([0], sourceSampleIndex: Int64.max))
        XCTAssertTrue(try converter.convert([0], sourceSampleIndex: Int64.min).samples.isEmpty)
    }
}
