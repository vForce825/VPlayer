// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class PhysicalSyncDetectorTests: XCTestCase {
    func testFixturePRNGSequence() {
        var prng = HomePodAVSyncFixtureV1.PRNG()
        var intervals: [UInt64] = []
        for _ in 0..<36 {
            intervals.append(prng.nextIntervalFrames())
        }
        XCTAssertEqual(intervals.count, 36)
        // All intervals must be in [75, 121]
        for interval in intervals {
            XCTAssertGreaterThanOrEqual(interval, 75)
            XCTAssertLessThanOrEqual(interval, 121)
        }
    }

    func testSpatialCode16EncodingAndDecoding() {
        for id in 0..<UInt8(36) {
            let code = HomePodAVSyncFixtureV1.encodeSpatialCode16(eventID: id)
            let (decodedID, isValid) = HomePodAVSyncFixtureV1.decodeSpatialCode16(code)
            XCTAssertTrue(isValid)
            XCTAssertEqual(decodedID, id)
        }

        // Test corruption detection
        let validCode = HomePodAVSyncFixtureV1.encodeSpatialCode16(eventID: 10)
        let corruptedCode = validCode ^ 0x0001
        let (_, corruptedValid) = HomePodAVSyncFixtureV1.decodeSpatialCode16(corruptedCode)
        XCTAssertFalse(corruptedValid)

        // Invalid preamble (not 0b1101)
        let badPreambleCode = (validCode & 0x0FFF) | 0xE000
        let (_, badPreambleValid) = HomePodAVSyncFixtureV1.decodeSpatialCode16(badPreambleCode)
        XCTAssertFalse(badPreambleValid)
    }

    func testChirpTemplateGeneration() {
        let chirp = HomePodAVSyncFixtureV1.generateChirpTemplate()
        // 20ms at 48kHz = 960 samples
        XCTAssertEqual(chirp.count, 960)

        // Peak amplitude must not exceed -12 dBFS (10^(-12/20) ~ 0.2512)
        let maxAmp = chirp.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAmp, 0.252)
        XCTAssertGreaterThan(maxAmp, 0.24)

        // Endpoints ramped down (half cosine ramp)
        XCTAssertEqual(chirp[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(chirp[959], 0.0, accuracy: 0.001)
    }

    func testVideoOnsetDetection() throws {
        // Construct 20 video luminance samples (frame interval 4.1666ms)
        // 8 black samples (~16.0), then rising edge, then 3-point plateau (~235.0)
        var samples: [(timestamp: ExactRational, luminance: Double)] = []
        for i in 0..<8 {
            samples.append((timestamp: ExactRational(Int64(i * 4)), luminance: 16.0))
        }
        // Samples 8 and 9 form crossing
        // black = 16, white = 235, range = 219 (>= 25% of 255 = 63.75)
        // threshold = 16 + 0.5 * 219 = 125.5
        samples.append((timestamp: ExactRational(32), luminance: 50.0))
        samples.append((timestamp: ExactRational(36), luminance: 200.0))
        // Samples 10, 11, 12 form white plateau
        samples.append((timestamp: ExactRational(40), luminance: 235.0))
        samples.append((timestamp: ExactRational(44), luminance: 235.0))
        samples.append((timestamp: ExactRational(48), luminance: 235.0))

        let onset = try HomePodAVSyncAnalyzerV1.detectVideoOnset(samples: samples)
        // Crossing from 50 to 200: (125.5 - 50) / (200 - 50) = 75.5 / 150 = 151 / 300
        // Time = 32 + (151/300) * 4 = 32 + 604/300 = 32 + 151/75 = 2551/75 ~ 34.0133
        XCTAssertGreaterThan(onset, ExactRational(32))
        XCTAssertLessThan(onset, ExactRational(36))
    }

    func testVideoOnsetFailsOnLowContrast() {
        // Difference between white and black is < 25% of 255 (63.75)
        var samples: [(timestamp: ExactRational, luminance: Double)] = []
        for i in 0..<8 {
            samples.append((timestamp: ExactRational(Int64(i * 4)), luminance: 16.0))
        }
        samples.append((timestamp: ExactRational(32), luminance: 20.0))
        samples.append((timestamp: ExactRational(36), luminance: 40.0))
        samples.append((timestamp: ExactRational(40), luminance: 50.0))
        samples.append((timestamp: ExactRational(44), luminance: 50.0))
        samples.append((timestamp: ExactRational(48), luminance: 50.0))

        XCTAssertThrowsError(try HomePodAVSyncAnalyzerV1.detectVideoOnset(samples: samples))
    }

    func testAudioChirpOnsetAndFSKDecoder() throws {
        // Generate a synthetic chirp followed by FSK for event ID 7
        let chirp = HomePodAVSyncFixtureV1.generateChirpTemplate()
        var buffer: [Float] = Array(repeating: 0.0, count: 960) // 20ms pre-silence
        buffer.append(contentsOf: chirp)
        buffer.append(contentsOf: Array(repeating: 0.0, count: 960)) // 20ms silence

        // Append FSK slots for ID 7
        let word = HomePodAVSyncFixtureV1.encodeSpatialCode16(eventID: 7)
        for bitIdx in (0..<16).reversed() {
            let bit = Int((word >> bitIdx) & 1)
            buffer.append(contentsOf: HomePodAVSyncFixtureV1.generateFSKSlot(bit: bit))
        }

        let detectedOnset = try HomePodAVSyncAnalyzerV1.detectAudioOnset(pcmSamples: buffer)
        // True onset in seconds = 960 / 48000 = 0.02s = 1/50s
        let expectedOnset = try ExactRational(numerator: 1, denominator: 50)
        let diff = try (detectedOnset - expectedOnset).absVal()
        // Must be accurate within 1 sample (1/48000s)
        XCTAssertLessThan(diff, try ExactRational(numerator: 1, denominator: 40000))

        let (decodedID, isValid) = try HomePodAVSyncAnalyzerV1.decodeAudioFSK(pcmSamples: buffer)
        XCTAssertTrue(isValid)
        XCTAssertEqual(decodedID, 7)
    }
}
