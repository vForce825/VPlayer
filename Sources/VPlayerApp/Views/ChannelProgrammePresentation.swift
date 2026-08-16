// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

struct ChannelProgrammePresentation: Equatable {
    let current: Programme?
    let next: Programme?
    let progress: Double?

    static func resolve(programmes: [Programme], at date: Date) -> Self {
        let current = programmes.first { $0.start <= date && date < $0.stop }
        let next = programmes.first { $0.start >= (current?.stop ?? date) }
        let progress = current.flatMap { programme -> Double? in
            let duration = programme.stop.timeIntervalSince(programme.start)
            guard duration > 0 else { return nil }
            return min(max(date.timeIntervalSince(programme.start) / duration, 0), 1)
        }
        return Self(current: current, next: next, progress: progress)
    }
}
