// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct RefreshSchedulePlanner: Sendable {
    public struct PlannedRefresh: Equatable, Sendable {
        public let profileID: UUID
        public let resources: Set<RefreshResource>
    }

    private static let minimumBackgroundDelay: TimeInterval = 15 * 60
    private static let failureBaseCooldown: TimeInterval = 15 * 60

    public init() {}

    public func dueResources(for profile: SourceProfile, now: Date) -> Set<RefreshResource> {
        Set(RefreshResource.allCases.filter { resource in
            let schedule = schedule(for: resource, in: profile)
            guard schedule.interval.isDue(lastSuccessAt: schedule.status.lastSuccessAt, now: now) else {
                return false
            }
            if let cooldownEnd = Self.failureCooldownEnd(
                status: schedule.status,
                interval: schedule.interval
            ) {
                return now >= cooldownEnd
            }
            return true
        })
    }

    /// 同一轮调度按资源 URL 去重；协调器负责写回所有关联配置。
    public func dueRefreshes(for profiles: [SourceProfile], now: Date) -> [PlannedRefresh] {
        var scheduled: [RefreshResource: Set<SourceURLIdentity>] = [:]
        return profiles.compactMap { profile in
            let resources = Set(dueResources(for: profile, now: now).filter { resource in
                scheduled[resource, default: []].insert(
                    SourceURLIdentity(url: profile.sourceURL(for: resource))
                ).inserted
            })
            guard !resources.isEmpty else { return nil }
            return PlannedRefresh(profileID: profile.id, resources: resources)
        }
    }

    public func nextBackgroundDate(for profiles: [SourceProfile], now: Date) -> Date? {
        let earliestAllowedDate = now.addingTimeInterval(Self.minimumBackgroundDelay)
        let candidates = profiles.flatMap { profile in
            RefreshResource.allCases.compactMap { resource -> Date? in
                let schedule = schedule(for: resource, in: profile)
                guard schedule.interval != .manual else { return nil }
                let scheduledDate = schedule.status.lastSuccessAt.map {
                    $0.addingTimeInterval(TimeInterval(schedule.interval.rawValue))
                } ?? earliestAllowedDate
                if let cooldownEnd = Self.failureCooldownEnd(
                    status: schedule.status,
                    interval: schedule.interval
                ) {
                    return max(scheduledDate, cooldownEnd)
                }
                return scheduledDate
            }
        }
        guard let earliestCandidate = candidates.min() else { return nil }
        return max(earliestCandidate, earliestAllowedDate)
    }

    private static func failureCooldownEnd(
        status: ResourceRefreshStatus,
        interval: RefreshInterval
    ) -> Date? {
        guard interval != .manual,
              status.state == .failed,
              let lastAttemptAt = status.lastAttemptAt else {
            return nil
        }
        let cap = TimeInterval(interval.rawValue)
        let exponent = max(0, min(status.consecutiveFailureCount - 1, 10))
        let cooldown = min(cap, failureBaseCooldown * Double(1 << exponent))
        return lastAttemptAt.addingTimeInterval(cooldown)
    }

    private func schedule(
        for resource: RefreshResource,
        in profile: SourceProfile
    ) -> (interval: RefreshInterval, status: ResourceRefreshStatus) {
        switch resource {
        case .playlist:
            return (profile.m3uRefreshInterval, profile.m3uStatus)
        case .epg:
            return (profile.epgRefreshInterval, profile.epgStatus)
        }
    }
}
