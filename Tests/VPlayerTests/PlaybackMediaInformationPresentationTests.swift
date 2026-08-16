// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore
@testable import VPlayerPlayback

final class PlaybackMediaInformationPresentationTests: XCTestCase {
    func testFormatsInterlacedDoubleRateWithUnitsArrowAndBenefit() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: 50,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 25 fps → 50 fps")
        XCTAssertTrue(subject.showsSmoothMotionBadge)
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
        )
        XCTAssertFalse(subject.accessibilityText.contains("→"))
        XCTAssertFalse(subject.visualText.contains("流畅增强"))
    }

    func testFormatsProgressiveOutputAsOneFrameRateWithoutEnhancementBadge() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 50, den: 1),
                outputFrameRate: 50,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p · 50 fps")
        XCTAssertFalse(subject.showsSmoothMotionBadge)
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 逐行扫描，每秒 50 帧"
        )
        XCTAssertFalse(subject.visualText.contains("→"))
    }

    func testProgressiveEnhancementFlagDoesNotShowSmoothMotionBadgeOrArrow() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: 50,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p · 50 fps")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 逐行扫描，每秒 50 帧")
        XCTAssertFalse(subject.showsSmoothMotionBadge)
        XCTAssertFalse(subject.visualText.contains("→"))
    }

    func testProgressiveRatesKeepRealValuesAwayFromStandardFrameRateCenters() {
        let thirtyPointFour = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 304, den: 10),
                outputFrameRate: 30.4,
                isSmoothMotionEnhanced: false
            )
        )
        let sixtyPointFour = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 604, den: 10),
                outputFrameRate: 60.4,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(thirtyPointFour.visualText, "1920×1080p · 30.4 fps")
        XCTAssertEqual(sixtyPointFour.visualText, "1920×1080p · 60.4 fps")
    }

    func testFormatsStandardNtscRatesWithoutRuntimeJitter() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_280,
                height: 720,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30_000, den: 1_001),
                outputFrameRate: 59.932,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1280×720i · 29.97 fps → 59.94 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1280 乘 720 隔行扫描，从每秒 29.97 帧增强到每秒 59.94 帧"
        )
    }

    func testEnhancedOutputWithinTwoPercentOfDoubleSourceRateUsesStableDoubleRate() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: 49.2,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 25 fps → 50 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
        )
        XCTAssertTrue(subject.showsSmoothMotionBadge)
    }

    func testEnhancedNtscOutputWithinTwoPercentOfDoubleSourceRateUsesStableDoubleRate() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_280,
                height: 720,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30_000, den: 1_001),
                outputFrameRate: 58.9,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1280×720i · 29.97 fps → 59.94 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1280 乘 720 隔行扫描，从每秒 29.97 帧增强到每秒 59.94 帧"
        )
    }

    func testEnhancedOutputOutsideDoubleSourceToleranceKeepsMeasuredRate() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: 52,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 25 fps → 52 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 52 帧"
        )
        XCTAssertTrue(subject.showsSmoothMotionBadge)
    }

    func testEnhancedOutputAtLowerTwoPercentBoundaryUsesStableDoubleRate() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30, den: 1),
                outputFrameRate: 58.8,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 30 fps → 60 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 隔行扫描，从每秒 30 帧增强到每秒 60 帧"
        )
    }

    func testEnhancedOutputAtUpperTwoPercentBoundaryUsesStableDoubleRate() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30, den: 1),
                outputFrameRate: 61.2,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 30 fps → 60 fps")
        XCTAssertEqual(
            subject.accessibilityText,
            "1920 乘 1080 隔行扫描，从每秒 30 帧增强到每秒 60 帧"
        )
    }

    func testEnhancedOutputJustOutsideTwoPercentBoundaryKeepsMeasuredRate() {
        let lower = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30, den: 1),
                outputFrameRate: 58.79,
                isSmoothMotionEnhanced: true
            )
        )
        let upper = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 30, den: 1),
                outputFrameRate: 61.21,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(lower.visualText, "1920×1080i · 30 fps → 58.79 fps")
        XCTAssertEqual(upper.visualText, "1920×1080i · 30 fps → 61.21 fps")
    }

    func testFormatsFilmRateWithAtMostThreeDecimalPlaces() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 3_840,
                height: 2_160,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 24_000, den: 1_001),
                outputFrameRate: 23.9764,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "3840×2160p · 23.976 fps")
        XCTAssertEqual(subject.accessibilityText, "3840 乘 2160 逐行扫描，每秒 23.976 帧")
    }

    func testUsesAvailableFrameRateWhenSourceFrameRateIsMissing() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: nil,
                outputFrameRate: 50,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p · 50 fps")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 逐行扫描，每秒 50 帧")
        XCTAssertFalse(subject.showsSmoothMotionBadge)
    }

    func testOmitsArrowWhenEnhancedInterlacedRateIsIncomplete() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: nil,
                isSmoothMotionEnhanced: true
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080i · 25 fps")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 隔行扫描，每秒 25 帧")
        XCTAssertTrue(subject.showsSmoothMotionBadge)
        XCTAssertFalse(subject.visualText.contains("→"))
    }

    func testFallsBackToValidOutputWhenSourceRateExceedsSupportedLimit() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 121, den: 1),
                outputFrameRate: 60,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p · 60 fps")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 逐行扫描，每秒 60 帧")
    }

    func testOmitsInvalidAndOutOfRangeFrameRatesInsteadOfShowingPseudoValues() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: nil,
                outputFrameRate: .infinity,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 逐行扫描")
        XCTAssertFalse(subject.visualText.contains("inf"))
    }

    func testFallsBackToValidSourceWhenOutputRateIsInvalid() {
        let subject = PlaybackMediaInformationPresentation(
            information: PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .progressive,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: -1,
                isSmoothMotionEnhanced: false
            )
        )

        XCTAssertEqual(subject.visualText, "1920×1080p · 25 fps")
        XCTAssertEqual(subject.accessibilityText, "1920 乘 1080 逐行扫描，每秒 25 帧")
    }

    func testShowsDetectionCopyBeforeMediaInformationArrives() {
        let subject = PlaybackMediaInformationPresentation(information: nil)

        XCTAssertEqual(subject.visualText, "正在检测画面规格…")
        XCTAssertEqual(subject.accessibilityText, "正在检测画面规格…")
        XCTAssertFalse(subject.showsSmoothMotionBadge)
    }

    func testPlayerChannelInfoAccessibilityUsesChineseSemanticsWithoutBadgeDuplication() {
        let current = programme(title: "新闻", start: 0, stop: 1_800)
        let next = programme(title: "天气", start: 1_800, stop: 3_600)
        let enhanced = PlaybackMediaInformation(
            width: 1_920,
            height: 1_080,
            scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: 50,
            isSmoothMotionEnhanced: true
        )

        let subject = PlayerChannelInfoAccessibilityPresentation(
            information: enhanced,
            current: current,
            next: next
        )

        XCTAssertEqual(
            subject.technicalText,
            "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
        )
        XCTAssertEqual(subject.currentProgrammeText, "当前节目：新闻")
        XCTAssertEqual(subject.nextProgrammeText, "下一节目：天气")
        XCTAssertNil(subject.badgeText)

        let incomplete = PlaybackMediaInformation(
            width: 1_920,
            height: 1_080,
            scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: nil,
            isSmoothMotionEnhanced: true
        )
        XCTAssertEqual(
            PlayerChannelInfoAccessibilityPresentation(
                information: incomplete,
                current: nil,
                next: nil
            ).badgeText,
            "流畅增强"
        )
    }

    func testNextProgrammeAccessibilityUsesOnlyItsStartTime() {
        let current = programme(title: "新闻", start: 0, stop: 1_800)
        let next = programme(title: "天气", start: 1_800, stop: 3_600)

        let subject = PlayerChannelInfoAccessibilityPresentation(
            information: nil,
            current: current,
            next: next
        )

        let startTime = next.start.formatted(date: .omitted, time: .shortened)
        let stopTime = next.stop.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(
            subject.nextProgrammeAccessibilityText,
            "下一节目：天气，时间 \(startTime)"
        )
        XCTAssertFalse(subject.nextProgrammeAccessibilityText?.contains(stopTime) ?? false)
    }

    private func programme(title: String, start: TimeInterval, stop: TimeInterval) -> Programme {
        Programme(
            id: title,
            xmltvChannelID: "channel",
            start: Date(timeIntervalSince1970: start),
            stop: Date(timeIntervalSince1970: stop),
            title: title,
            subtitle: nil,
            summary: nil,
            categories: []
        )
    }
}
