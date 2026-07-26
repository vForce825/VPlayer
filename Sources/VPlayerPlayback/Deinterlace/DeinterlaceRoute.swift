// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

public enum DeinterlaceRoute: Equatable, Sendable {
    case rawWhileClassifying
    case bypass
    case metalYADIF2x

    public static func resolve(scan: ScanType) -> DeinterlaceRoute {
        switch scan {
        case .unknown:
            .rawWhileClassifying
        case .progressive, .progressiveSegmentedFrame:
            .bypass
        case .interlaced:
            .metalYADIF2x
        }
    }
}
