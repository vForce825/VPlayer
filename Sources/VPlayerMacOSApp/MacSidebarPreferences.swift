// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import Foundation
import Observation

@MainActor
@Observable
final class MacSidebarPreferences {
    static let widthKey = "mac.sidebar.width"
    static let defaultWidth = 260.0
    private let defaults: UserDefaults
    private(set) var width: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        width = Self.clamped(defaults.object(forKey: Self.widthKey) as? Double ?? Self.defaultWidth)
    }

    func resize(to width: Double) {
        self.width = Self.clamped(width)
        defaults.set(self.width, forKey: Self.widthKey)
    }

    private static func clamped(_ width: Double) -> Double {
        width.isFinite ? min(360, max(220, width)) : defaultWidth
    }
}
