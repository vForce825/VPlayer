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

struct ProgrammeClockKey: Equatable, Sendable {
    let active: Bool
    let intervalSeconds: Int
}

enum ProgrammeClockTicker {
    static func nextTickDelay(after date: Date = Date(), intervalSeconds: Int) -> Duration {
        let interval = max(1, intervalSeconds)
        let remainder = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Double(interval))
        let normalizedRemainder = remainder < 0 ? remainder + Double(interval) : remainder
        let remaining = max(0.25, Double(interval) - normalizedRemainder)
        return .milliseconds(Int((remaining * 1_000).rounded(.up)))
    }

    @MainActor
    static func run(
        for key: ProgrammeClockKey,
        onTick: @MainActor (Date) -> Void
    ) async {
        guard key.active else { return }
        onTick(Date())
        while !Task.isCancelled {
            let delay = nextTickDelay(after: Date(), intervalSeconds: key.intervalSeconds)
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onTick(Date())
        }
    }
}
