// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation

/// How the channel browser lays a playlist out. Playlists disagree on how much
/// `group-title` is worth: some carry a careful taxonomy, others one bucket for
/// everything, so the choice belongs to the viewer rather than to the file.
enum ChannelGrouping: String, CaseIterable, Equatable, Sendable {
    /// Sections per `group-title`, in the order the playlist introduces them.
    case playlistGroups
    /// One flat run of tiles in the playlist's own order.
    case playlistOrder
}

@MainActor
@Observable
final class ChannelBrowsingSettingsStore {
    static let storageKey = "channels.grouping"

    private let defaults: UserDefaults

    var grouping: ChannelGrouping {
        didSet {
            guard oldValue != grouping else { return }
            defaults.set(grouping.rawValue, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Grouping is the default because most IPTV playlists ship a usable
        // group-title; the flat order is the opt-out.
        self.grouping = defaults.string(forKey: Self.storageKey)
            .flatMap(ChannelGrouping.init(rawValue:)) ?? .playlistGroups
    }
}
