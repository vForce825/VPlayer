// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerPlayback

struct PlaybackMediaInformationPresentation: Sendable {
    private static let detectingText = "正在检测画面规格…"
    private static let maximumFrameRate = 120.0

    private let information: PlaybackMediaInformation?

    init(information: PlaybackMediaInformation?) {
        self.information = information
    }

    var visualText: String {
        guard let information else { return Self.detectingText }

        let resolution = Self.visualResolutionText(for: information)
        let smoothMotionEnhancementIsActive = Self.smoothMotionEnhancementIsActive(for: information)
        let rates = Self.frameRateValues(
            for: information,
            smoothMotionEnhancementIsActive: smoothMotionEnhancementIsActive
        )
        let rateText: String?

        if smoothMotionEnhancementIsActive,
           let source = rates.source,
           let output = rates.output {
            rateText = "\(Self.formatFrameRate(source)) fps → \(Self.formatFrameRate(output)) fps"
        } else if let rate = rates.output ?? rates.source {
            rateText = "\(Self.formatFrameRate(rate)) fps"
        } else {
            rateText = nil
        }

        return [resolution, rateText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var accessibilityText: String {
        guard let information else { return Self.detectingText }

        let resolution = Self.accessibilityResolutionText(for: information)
        let smoothMotionEnhancementIsActive = Self.smoothMotionEnhancementIsActive(for: information)
        let rates = Self.frameRateValues(
            for: information,
            smoothMotionEnhancementIsActive: smoothMotionEnhancementIsActive
        )
        let rateText: String?

        if smoothMotionEnhancementIsActive,
           let source = rates.source,
           let output = rates.output {
            rateText = "从每秒 \(Self.formatFrameRate(source)) 帧增强到每秒 \(Self.formatFrameRate(output)) 帧"
        } else if let rate = rates.output ?? rates.source {
            rateText = "每秒 \(Self.formatFrameRate(rate)) 帧"
        } else {
            rateText = nil
        }

        return [resolution, rateText]
            .compactMap { $0 }
            .joined(separator: "，")
    }

    var showsSmoothMotionBadge: Bool {
        guard let information else { return false }
        return Self.smoothMotionEnhancementIsActive(for: information)
    }

    private static func visualResolutionText(
        for information: PlaybackMediaInformation
    ) -> String? {
        guard information.width > 0, information.height > 0 else { return nil }
        return "\(information.width)×\(information.height)\(scanSuffix(for: information.scanMode))"
    }

    private static func accessibilityResolutionText(
        for information: PlaybackMediaInformation
    ) -> String? {
        guard information.width > 0, information.height > 0 else {
            return scanLabel(for: information.scanMode)
        }
        return "\(information.width) 乘 \(information.height) \(scanLabel(for: information.scanMode))"
    }

    private static func scanSuffix(for scanMode: PlaybackScanMode) -> String {
        switch scanMode {
        case .progressive:
            "p"
        case .interlaced:
            "i"
        }
    }

    private static func scanLabel(for scanMode: PlaybackScanMode) -> String {
        switch scanMode {
        case .progressive:
            "逐行扫描"
        case .interlaced:
            "隔行扫描"
        }
    }

    private static func smoothMotionEnhancementIsActive(
        for information: PlaybackMediaInformation
    ) -> Bool {
        information.scanMode == .interlaced && information.isSmoothMotionEnhanced
    }

    private static func frameRateValues(
        for information: PlaybackMediaInformation,
        smoothMotionEnhancementIsActive: Bool
    ) -> (source: Double?, output: Double?) {
        let source = normalizedFrameRate(
            information.sourceFrameRate.map { Double($0.num) / Double($0.den) }
        )
        let output = normalizedFrameRate(information.outputFrameRate)

        guard smoothMotionEnhancementIsActive,
              let source,
              let output else {
            return (source: source, output: output)
        }

        let expectedOutput = source * 2
        guard expectedOutput.isFinite,
              expectedOutput > 0,
              expectedOutput <= maximumFrameRate,
              abs(output - expectedOutput)
                <= expectedOutput * 0.02
                    + max(expectedOutput.ulp, output.ulp) * 4 else {
            return (source: source, output: output)
        }
        return (source: source, output: expectedOutput)
    }

    private static func normalizedFrameRate(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              value > 0,
              value <= maximumFrameRate else {
            return nil
        }

        let scaled = (value * 1_000).rounded()
        guard scaled > 0, scaled <= maximumFrameRate * 1_000 else { return nil }
        return scaled / 1_000
    }

    private static func formatFrameRate(_ value: Double) -> String {
        let scaled = Int((value * 1_000).rounded())
        let whole = scaled / 1_000
        let fraction = scaled % 1_000
        guard fraction != 0 else { return String(whole) }

        let rawFractionText = String(fraction)
        let paddedFractionText = String(repeating: "0", count: 3 - rawFractionText.count)
            + rawFractionText
        let fractionText = paddedFractionText.replacingOccurrences(
            of: "0+$",
            with: "",
            options: .regularExpression
        )
        return "\(whole).\(fractionText)"
    }
}
