// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class CaptureSkewCalibrationTests: XCTestCase {
    func testCalibrationSkewCalculation() throws {
        // Construct 36 calibration events for beforeRun and afterRun
        // audio - video = 15ms = 15/1000 s
        // deltaFixture = 1ms = 1/1000 s
        // distance = 343mm = 0.343m
        // soundSpeed = 343 m/s -> acoustic delay = 1ms = 1/1000 s
        // correctedRaw = 15 - 1 - 1 = 13ms
        let deltaFixture = try ExactRational(numerator: 1, denominator: 1000)
        let distance = try ExactRational(numerator: 343, denominator: 1000)
        let soundSpeed = ExactRational(343)

        let events = try (0..<36).map { _ in
            CaptureSkewCalibratorV1.CalibrationEvent(
                audioOnset: try ExactRational(numerator: 15, denominator: 1000),
                videoOnset: ExactRational(0)
            )
        }

        let beforeRun = CaptureSkewCalibratorV1.CalibrationRun(
            events: events,
            deltaFixture: deltaFixture,
            calibratorDistanceMeters: distance,
            soundSpeedMetersPerSecond: soundSpeed
        )

        let afterRun = CaptureSkewCalibratorV1.CalibrationRun(
            events: events,
            deltaFixture: deltaFixture,
            calibratorDistanceMeters: distance,
            soundSpeedMetersPerSecond: soundSpeed
        )

        let result = try CaptureSkewCalibratorV1.evaluateCalibration(beforeRun: beforeRun, afterRun: afterRun)
        XCTAssertTrue(result.isCalibrationValid)
        // c = 13ms = 13/1000 s
        XCTAssertEqual(result.c, try ExactRational(numerator: 13, denominator: 1000))

        // Target measurement: audioOnset - videoOnset = 33ms
        // e_i = (audio - video) - c = 33 - 13 = 20ms
        let targetDelay = try CaptureSkewCalibratorV1.calculateTargetDelay(
            targetAudioOnset: try ExactRational(numerator: 33, denominator: 1000),
            targetVideoOnset: ExactRational(0),
            c: result.c
        )
        XCTAssertEqual(targetDelay, try ExactRational(numerator: 20, denominator: 1000))
    }

    func testCalibrationRejectsSkewDifferenceExceeding2MS() throws {
        let deltaFixture = try ExactRational(numerator: 1, denominator: 1000)
        let distance = try ExactRational(numerator: 343, denominator: 1000)
        let soundSpeed = ExactRational(343)

        // Before run: 15ms -> corrected 13ms
        let beforeEvents = try (0..<36).map { _ in
            CaptureSkewCalibratorV1.CalibrationEvent(
                audioOnset: try ExactRational(numerator: 15, denominator: 1000),
                videoOnset: ExactRational(0)
            )
        }
        let beforeRun = CaptureSkewCalibratorV1.CalibrationRun(
            events: beforeEvents,
            deltaFixture: deltaFixture,
            calibratorDistanceMeters: distance,
            soundSpeedMetersPerSecond: soundSpeed
        )

        // After run: 18ms -> corrected 16ms (difference is 3ms > 2ms threshold!)
        let afterEvents = try (0..<36).map { _ in
            CaptureSkewCalibratorV1.CalibrationEvent(
                audioOnset: try ExactRational(numerator: 18, denominator: 1000),
                videoOnset: ExactRational(0)
            )
        }
        let afterRun = CaptureSkewCalibratorV1.CalibrationRun(
            events: afterEvents,
            deltaFixture: deltaFixture,
            calibratorDistanceMeters: distance,
            soundSpeedMetersPerSecond: soundSpeed
        )

        XCTAssertThrowsError(try CaptureSkewCalibratorV1.evaluateCalibration(beforeRun: beforeRun, afterRun: afterRun))
    }

    func testTVDelayAndHomePodDelayNotSwallowedByC() throws {
        // If television adds display delay T_tv (e.g. 50ms) to target, and HomePod adds acoustic propagation T_hp (e.g. 10ms),
        // calibrator hardware has its own independent LED/emitter and does not pass through TV or HomePod.
        // Therefore c is purely capture chain bias.
        // targetAudioOnset = videoOnset + T_tv + T_av_drift + c
        let c = try ExactRational(numerator: 5, denominator: 1000) // 5ms capture bias
        let tTv = try ExactRational(numerator: 40, denominator: 1000) // 40ms TV delay
        let tHp = try ExactRational(numerator: 65, denominator: 1000) // 65ms HomePod audio delay
        // Measured target video onset includes TV delay:
        let targetVideoOnset = tTv
        // Measured target audio onset includes HomePod delay and capture bias:
        let targetAudioOnset = try tHp + c

        let e_i = try CaptureSkewCalibratorV1.calculateTargetDelay(
            targetAudioOnset: targetAudioOnset,
            targetVideoOnset: targetVideoOnset,
            c: c
        )
        // e_i should be (targetAudio - targetVideo) - c = (tHp + c - tTv) - c = tHp - tTv = 65 - 40 = 25ms!
        XCTAssertEqual(e_i, try ExactRational(numerator: 25, denominator: 1000))
    }
}
