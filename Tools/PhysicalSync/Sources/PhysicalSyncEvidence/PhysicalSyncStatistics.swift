// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct PhysicalSyncEvaluationResult: Equatable, Sendable {
    public let medianAbsoluteMilliseconds: ExactRational
    public let p95AbsoluteMilliseconds: ExactRational
    public let maxAbsoluteMilliseconds: ExactRational
    public let signedMedianMilliseconds: ExactRational
    public let driftMillisecondsPerMinute: ExactRational
    public let passesThresholds: Bool

    public init(
        medianAbsoluteMilliseconds: ExactRational,
        p95AbsoluteMilliseconds: ExactRational,
        maxAbsoluteMilliseconds: ExactRational,
        signedMedianMilliseconds: ExactRational,
        driftMillisecondsPerMinute: ExactRational,
        passesThresholds: Bool
    ) {
        self.medianAbsoluteMilliseconds = medianAbsoluteMilliseconds
        self.p95AbsoluteMilliseconds = p95AbsoluteMilliseconds
        self.maxAbsoluteMilliseconds = maxAbsoluteMilliseconds
        self.signedMedianMilliseconds = signedMedianMilliseconds
        self.driftMillisecondsPerMinute = driftMillisecondsPerMinute
        self.passesThresholds = passesThresholds
    }
}

public enum PhysicalSyncStatisticsError: Error, Equatable, Sendable {
    case invalidEventCount(expected: Int, actual: Int)
    case nonMonotonicElapsed
    case arithmeticOverflow
    case detectorFailure(String)
    case calibrationFailed(String)
}

public enum PhysicalSyncStatistics {
    public static func evaluate(eventOffsetsMilliseconds: [ExactRational], elapsedSeconds: [ExactRational]) throws -> PhysicalSyncEvaluationResult {
        guard eventOffsetsMilliseconds.count == 36 else {
            throw PhysicalSyncStatisticsError.invalidEventCount(expected: 36, actual: eventOffsetsMilliseconds.count)
        }
        guard elapsedSeconds.count == 36 else {
            throw PhysicalSyncStatisticsError.invalidEventCount(expected: 36, actual: elapsedSeconds.count)
        }

        for i in 0..<35 {
            if !(elapsedSeconds[i] < elapsedSeconds[i + 1]) {
                throw PhysicalSyncStatisticsError.nonMonotonicElapsed
            }
        }

        // Absolute offsets
        let absoluteOffsets = try eventOffsetsMilliseconds.map { try $0.absVal() }
        let sortedAbs = absoluteOffsets.sorted()

        // 18th and 19th items (1-indexed) -> indices 17 and 18
        let sumMedianAbs = try sortedAbs[17] + sortedAbs[18]
        let medianAbs = try sumMedianAbs / ExactRational(2)

        // 35th item (1-indexed) -> index 34
        let p95Abs = sortedAbs[34]

        // 36th item (1-indexed) -> index 35
        let maxAbs = sortedAbs[35]

        // Signed median: 18th and 19th items of sorted signed offsets
        let sortedSigned = eventOffsetsMilliseconds.sorted()
        let sumMedianSigned = try sortedSigned[17] + sortedSigned[18]
        let signedMedian = try sumMedianSigned / ExactRational(2)

        // Theil-Sen estimator: all 630 slopes (e_j - e_i) / (elapsed_j - elapsed_i) * 60 (ms/min)
        var slopes: [ExactRational] = []
        slopes.reserveCapacity(630)
        for i in 0..<36 {
            for j in (i + 1)..<36 {
                let deltaE = try eventOffsetsMilliseconds[j] - eventOffsetsMilliseconds[i]
                let deltaT = try elapsedSeconds[j] - elapsedSeconds[i]
                let slopePerSec = try deltaE / deltaT
                let slopePerMin = try slopePerSec * ExactRational(60)
                slopes.append(slopePerMin)
            }
        }

        let sortedSlopes = slopes.sorted()
        // 315th and 316th items (1-indexed) -> indices 314 and 315
        let sumDrift = try sortedSlopes[314] + sortedSlopes[315]
        let drift = try sumDrift / ExactRational(2)

        let passes = try medianAbs <= ExactRational(40) &&
                     p95Abs <= ExactRational(80) &&
                     maxAbs <= ExactRational(100) &&
                     drift.absVal() <= ExactRational(1)

        return PhysicalSyncEvaluationResult(
            medianAbsoluteMilliseconds: medianAbs,
            p95AbsoluteMilliseconds: p95Abs,
            maxAbsoluteMilliseconds: maxAbs,
            signedMedianMilliseconds: signedMedian,
            driftMillisecondsPerMinute: drift,
            passesThresholds: passes
        )
    }

    public static func evaluate(eventOffsetsMilliseconds: [Int64], elapsedSeconds: [Int64]) throws -> PhysicalSyncEvaluationResult {
        let offsets = eventOffsetsMilliseconds.map { ExactRational($0) }
        let elapsed = try elapsedSeconds.map { try ExactRational(numerator: $0, denominator: 1) }
        return try evaluate(eventOffsetsMilliseconds: offsets, elapsedSeconds: elapsed)
    }

    public static func evaluate(eventOffsetsMilliseconds: [Double], elapsedSeconds: [Double]) throws -> PhysicalSyncEvaluationResult {
        let offsets = try eventOffsetsMilliseconds.map { try ExactRational(numerator: Int64(round($0 * 1000)), denominator: 1000) }
        let elapsed = try elapsedSeconds.map { try ExactRational(numerator: Int64(round($0 * 1000)), denominator: 1000) }
        return try evaluate(eventOffsetsMilliseconds: offsets, elapsedSeconds: elapsed)
    }
}

public enum HomePodAVSyncFixtureV1 {
    public static let prngSeed: UInt64 = 0x6A09E667F3BCC909
    public static let totalEventsCount: Int = 36

    public struct PRNG {
        public var state: UInt64
        public init(seed: UInt64 = HomePodAVSyncFixtureV1.prngSeed) {
            self.state = seed
        }
        public mutating func nextIntervalFrames() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            state &*= 2685821657736338717
            return 75 + (state % 47)
        }
    }

    public static func computeCRC4ITU(high12Bits: UInt16) -> UInt8 {
        var rem = UInt32(high12Bits) << 4
        let poly: UInt32 = 0x13 // x^4 + x + 1
        for i in (4...15).reversed() {
            if (rem & (1 << i)) != 0 {
                rem ^= (poly << (i - 4))
            }
        }
        return UInt8(rem & 0x0F)
    }

    public static func encodeSpatialCode16(eventID: UInt8) -> UInt16 {
        let high12 = (UInt16(0xD) << 8) | UInt16(eventID)
        let crc = computeCRC4ITU(high12Bits: high12)
        return (high12 << 4) | UInt16(crc)
    }

    public static func decodeSpatialCode16(_ word: UInt16) -> (eventID: UInt8, isValid: Bool) {
        let high4 = UInt8((word >> 12) & 0xF)
        guard high4 == 0xD else { return (0, false) }
        let eventID = UInt8((word >> 4) & 0xFF)
        let crc = UInt8(word & 0xF)
        let high12 = UInt16(word >> 4)
        let expectedCRC = computeCRC4ITU(high12Bits: high12)
        return (eventID, crc == expectedCRC)
    }

    public static func generateChirpTemplate() -> [Float] {
        let sampleRate: Double = 48000.0
        let duration: Double = 0.020 // 20ms
        let sampleCount = 960
        let f0: Double = 2000.0
        let f1: Double = 8000.0
        let k = (f1 - f0) / duration
        let peakAmp: Double = pow(10.0, -12.0 / 20.0)

        var samples = [Float](repeating: 0.0, count: sampleCount)
        for n in 0..<sampleCount {
            let t = Double(n) / sampleRate
            let phi = 2.0 * Double.pi * (f0 * t + 0.5 * k * t * t)
            var val = peakAmp * sin(phi)

            // Half cosine ramp over first 48 and last 48 samples
            if n < 48 {
                let w = 0.5 * (1.0 - cos(Double.pi * Double(n) / 48.0))
                val *= w
            } else if n >= sampleCount - 48 {
                let w = 0.5 * (1.0 - cos(Double.pi * Double(sampleCount - n) / 48.0))
                val *= w
            }
            samples[n] = Float(val)
        }
        return samples
    }

    public static func generateFSKSlot(bit: Int) -> [Float] {
        let sampleRate: Double = 48000.0
        let toneDuration: Double = 0.012 // 12ms = 576 samples
        let toneSampleCount = 576
        let silenceSampleCount = 48 // 1ms = 48 samples
        let freq: Double = (bit == 1) ? 6000.0 : 3000.0
        let peakAmp: Double = pow(10.0, -12.0 / 20.0)

        var samples = [Float](repeating: 0.0, count: toneSampleCount + silenceSampleCount)
        for n in 0..<toneSampleCount {
            let t = Double(n) / sampleRate
            let val = peakAmp * sin(2.0 * Double.pi * freq * t)
            samples[n] = Float(val)
        }
        return samples
    }
}

public enum HomePodAVSyncAnalyzerV1 {
    public static func detectVideoOnset(samples: [(timestamp: ExactRational, luminance: Double)], fullRange: Double = 255.0) throws -> ExactRational {
        guard samples.count >= 12 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Insufficient video samples (< 12)")
        }

        // 1. Pre-8 sample median: black
        let pre8 = samples[0..<8].map { $0.luminance }.sorted()
        let black = (pre8[3] + pre8[4]) / 2.0

        // 2. Post-onset local plateau max 3-point median: white
        var maxPlateauMedian: Double = -Double.greatestFiniteMagnitude
        for i in 8..<(samples.count - 2) {
            let window = [samples[i].luminance, samples[i + 1].luminance, samples[i + 2].luminance].sorted()
            let med = window[1]
            if med > maxPlateauMedian {
                maxPlateauMedian = med
            }
        }
        let white = maxPlateauMedian

        // 3. Contrast threshold: (white - black) >= 25% full range
        guard (white - black) >= (0.25 * fullRange) else {
            throw PhysicalSyncStatisticsError.detectorFailure("Contrast too low: \(white - black) < \(0.25 * fullRange)")
        }

        let threshold = black + 0.5 * (white - black)

        // 4. Linear interpolation on first crossing
        for i in 7..<(samples.count - 1) {
            let y1 = samples[i].luminance
            let y2 = samples[i + 1].luminance
            if (y1 <= threshold && y2 >= threshold) || (y1 >= threshold && y2 <= threshold) {
                guard y1 != y2 else { continue }
                let alpha = (threshold - y1) / (y2 - y1)
                guard alpha >= 0.0 && alpha <= 1.0 else { continue }

                // In exact rational
                let numAlpha = Int64(round(alpha * 1_000_000.0))
                let alphaRational = try ExactRational(numerator: numAlpha, denominator: 1_000_000)
                let deltaT = try samples[i + 1].timestamp - samples[i].timestamp
                let offset = try deltaT * alphaRational
                return try samples[i].timestamp + offset
            }
        }

        throw PhysicalSyncStatisticsError.detectorFailure("Video onset threshold crossing not found")
    }

    public static func detectAudioOnset(pcmSamples: [Float], sampleRate: Double = 48000.0) throws -> ExactRational {
        let template = HomePodAVSyncFixtureV1.generateChirpTemplate()
        let tLen = template.count // 960
        guard pcmSamples.count >= tLen + 960 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Insufficient audio samples")
        }

        // Subtract pre-event 20ms (960 samples) mean
        var preSum: Double = 0
        for i in 0..<960 {
            preSum += Double(pcmSamples[i])
        }
        let preMean = Float(preSum / 960.0)

        var zeroMeanSamples = [Float](repeating: 0, count: pcmSamples.count)
        for i in 0..<pcmSamples.count {
            zeroMeanSamples[i] = pcmSamples[i] - preMean
        }

        // Template stats
        var tSum: Double = 0
        for s in template { tSum += Double(s) }
        let tMean = tSum / Double(tLen)
        var tEnergy: Double = 0
        for s in template {
            let diff = Double(s) - tMean
            tEnergy += diff * diff
        }

        // Normalized cross-correlation
        var corr = [Double](repeating: 0, count: zeroMeanSamples.count - tLen + 1)
        var bestLag = 0
        var maxCorr: Double = -Double.greatestFiniteMagnitude

        for lag in 0..<corr.count {
            var dot: Double = 0
            var sEnergy: Double = 0
            var sSum: Double = 0
            for i in 0..<tLen {
                let v = Double(zeroMeanSamples[lag + i])
                sSum += v
            }
            let sMean = sSum / Double(tLen)
            for i in 0..<tLen {
                let sv = Double(zeroMeanSamples[lag + i]) - sMean
                let tv = Double(template[i]) - tMean
                dot += sv * tv
                sEnergy += sv * sv
            }
            let denom = sqrt(sEnergy * tEnergy)
            let c = denom > 1e-9 ? (dot / denom) : 0.0
            corr[lag] = c
            if c > maxCorr {
                maxCorr = c
                bestLag = lag
            }
        }

        // Check peak coefficient >= 0.80
        guard maxCorr >= 0.80 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Audio peak correlation too low: \(maxCorr) < 0.80")
        }

        // Check secondary peak: >= 0.10 higher than any peak > 5ms (240 samples) away
        let minLagDist = Int(round(0.005 * sampleRate)) // 240
        for lag in 0..<corr.count {
            if abs(lag - bestLag) > minLagDist {
                if (maxCorr - corr[lag]) < 0.10 {
                    throw PhysicalSyncStatisticsError.detectorFailure("Ambiguous audio chirp correlation peak")
                }
            }
        }

        // 3-point parabolic interpolation
        guard bestLag > 0 && bestLag < corr.count - 1 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Peak at audio boundary")
        }
        let y0 = corr[bestLag - 1]
        let y1 = corr[bestLag]
        let y2 = corr[bestLag + 1]
        let denom = 2.0 * (y0 - 2.0 * y1 + y2)
        guard abs(denom) > 1e-9 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Degenerate parabolic peak")
        }
        let delta = (y0 - y2) / denom
        guard abs(delta) <= 1.0 else {
            throw PhysicalSyncStatisticsError.detectorFailure("Parabolic peak delta > 1")
        }

        let peakSample = Double(bestLag) + delta
        let onsetSecNum = Int64(round(peakSample * 1_000_000.0 / sampleRate))
        return try ExactRational(numerator: onsetSecNum, denominator: 1_000_000)
    }

    public static func decodeAudioFSK(pcmSamples: [Float], sampleRate: Double = 48000.0, chirpOnsetSample: Int? = nil) throws -> (eventID: UInt8, isValid: Bool) {
        // Goertzel filter helper
        func goertzelEnergy(samples: [Float], targetFreq: Double, rate: Double) -> Double {
            let k = Int(round(Double(samples.count) * targetFreq / rate))
            let omega = (2.0 * Double.pi * Double(k)) / Double(samples.count)
            let coeff = 2.0 * cos(omega)
            var q1: Double = 0.0
            var q2: Double = 0.0
            for s in samples {
                let q0 = coeff * q1 - q2 + Double(s)
                q2 = q1
                q1 = q0
            }
            return q1 * q1 + q2 * q2 - coeff * q1 * q2
        }

        let startSample: Int
        if let given = chirpOnsetSample {
            startSample = given
        } else {
            let onset = try detectAudioOnset(pcmSamples: pcmSamples, sampleRate: sampleRate)
            startSample = Int(round(onset.toDouble() * sampleRate))
        }

        // Chirp (960) + silence (20ms = 960) = 1920 samples after onset
        var offset = startSample + 1920
        let slotToneSamples = 576
        let slotTotalSamples = 624 // 576 + 48 gap

        guard pcmSamples.count >= offset + 16 * slotTotalSamples else {
            throw PhysicalSyncStatisticsError.detectorFailure("Audio buffer too short for 16 FSK slots")
        }

        var decodedWord: UInt16 = 0
        for bitIdx in (0..<16).reversed() {
            let slotSlice = Array(pcmSamples[offset..<(offset + slotToneSamples)])
            let e0 = goertzelEnergy(samples: slotSlice, targetFreq: 3000.0, rate: sampleRate)
            let e1 = goertzelEnergy(samples: slotSlice, targetFreq: 6000.0, rate: sampleRate)
            let bit = e1 > e0 ? 1 : 0
            decodedWord |= (UInt16(bit) << bitIdx)
            offset += slotTotalSamples
        }

        let (eventID, isValid) = HomePodAVSyncFixtureV1.decodeSpatialCode16(decodedWord)
        return (eventID, isValid)
    }
}

public enum CaptureSkewCalibratorV1 {
    public struct CalibrationEvent: Sendable {
        public let audioOnset: ExactRational
        public let videoOnset: ExactRational
        public init(audioOnset: ExactRational, videoOnset: ExactRational) {
            self.audioOnset = audioOnset
            self.videoOnset = videoOnset
        }
    }

    public struct CalibrationRun: Sendable {
        public let events: [CalibrationEvent]
        public let deltaFixture: ExactRational
        public let calibratorDistanceMeters: ExactRational
        public let soundSpeedMetersPerSecond: ExactRational

        public init(
            events: [CalibrationEvent],
            deltaFixture: ExactRational,
            calibratorDistanceMeters: ExactRational,
            soundSpeedMetersPerSecond: ExactRational
        ) {
            self.events = events
            self.deltaFixture = deltaFixture
            self.calibratorDistanceMeters = calibratorDistanceMeters
            self.soundSpeedMetersPerSecond = soundSpeedMetersPerSecond
        }

        public func calculateCorrectedRaw() throws -> [ExactRational] {
            guard events.count == 36 else {
                throw PhysicalSyncStatisticsError.invalidEventCount(expected: 36, actual: events.count)
            }
            let acousticDelay = try calibratorDistanceMeters / soundSpeedMetersPerSecond
            return try events.map { event in
                let raw = try event.audioOnset - event.videoOnset
                let step1 = try raw - deltaFixture
                return try step1 - acousticDelay
            }
        }

        public func calculateMedianCorrectedRaw() throws -> ExactRational {
            let corrected = try calculateCorrectedRaw()
            let sorted = corrected.sorted()
            let sum = try sorted[17] + sorted[18]
            return try sum / ExactRational(2)
        }
    }

    public struct CalibrationResult: Sendable {
        public let cBefore: ExactRational
        public let cAfter: ExactRational
        public let skewDifferenceMilliseconds: ExactRational
        public let c: ExactRational
        public let isCalibrationValid: Bool
    }

    public static func evaluateCalibration(beforeRun: CalibrationRun, afterRun: CalibrationRun) throws -> CalibrationResult {
        let cBefore = try beforeRun.calculateMedianCorrectedRaw()
        let cAfter = try afterRun.calculateMedianCorrectedRaw()

        let diff = try (cBefore - cAfter).absVal()
        let diffMs = try diff.toMilliseconds()

        guard diffMs <= ExactRational(2) else {
            throw PhysicalSyncStatisticsError.calibrationFailed("Calibration skew difference \(diffMs)ms exceeds 2ms threshold")
        }

        let sum = try cBefore + cAfter
        let c = try sum / ExactRational(2)

        return CalibrationResult(
            cBefore: cBefore,
            cAfter: cAfter,
            skewDifferenceMilliseconds: diffMs,
            c: c,
            isCalibrationValid: true
        )
    }

    public static func calculateTargetDelay(targetAudioOnset: ExactRational, targetVideoOnset: ExactRational, c: ExactRational) throws -> ExactRational {
        let rawTarget = try targetAudioOnset - targetVideoOnset
        return try rawTarget - c
    }
}
