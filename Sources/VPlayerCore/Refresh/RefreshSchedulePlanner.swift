// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct RefreshSchedulePlanner: Sendable {
    private static let minimumBackgroundDelay: TimeInterval = 15 * 60

    public init() {}

    public func dueResources(for profile: SourceProfile, now: Date) -> Set<RefreshResource> {
        Set(RefreshResource.allCases.filter { resource in
            let schedule = schedule(for: resource, in: profile)
            return schedule.interval.isDue(lastSuccessAt: schedule.lastSuccessAt, now: now)
        })
    }

    public func nextBackgroundDate(for profiles: [SourceProfile], now: Date) -> Date? {
        let earliestAllowedDate = now.addingTimeInterval(Self.minimumBackgroundDelay)
        let candidates = profiles.flatMap { profile in
            RefreshResource.allCases.compactMap { resource -> Date? in
                let schedule = schedule(for: resource, in: profile)
                guard schedule.interval != .manual else { return nil }
                guard let lastSuccessAt = schedule.lastSuccessAt else {
                    return earliestAllowedDate
                }
                return lastSuccessAt.addingTimeInterval(TimeInterval(schedule.interval.rawValue))
            }
        }
        guard let earliestCandidate = candidates.min() else { return nil }
        return max(earliestCandidate, earliestAllowedDate)
    }

    private func schedule(
        for resource: RefreshResource,
        in profile: SourceProfile
    ) -> (interval: RefreshInterval, lastSuccessAt: Date?) {
        switch resource {
        case .playlist:
            return (profile.m3uRefreshInterval, profile.m3uStatus.lastSuccessAt)
        case .epg:
            return (profile.epgRefreshInterval, profile.epgStatus.lastSuccessAt)
        }
    }
}
