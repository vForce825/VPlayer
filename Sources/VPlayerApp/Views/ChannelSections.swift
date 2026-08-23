// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

/// One run of channels in the browser: a playlist group, or the whole playlist
/// when grouping is off.
struct ChannelSection: Identifiable, Equatable {
    let id: String
    /// Nil for the single section of an ungrouped browser, which needs no header.
    let title: String?
    var channels: [Channel]
}

/// The derived channel-browser values for one SwiftUI body evaluation. Keeping
/// the filtered playlist and its sections together lets every branch of the
/// browser consume the same grouping work.
struct ChannelBrowserPresentation: Equatable {
    let filteredChannels: [Channel]
    let sections: [ChannelSection]
    let defaultFocusChannelID: String?
    let showsGroupRail: Bool

    init(
        channels: [Channel],
        searchText: String,
        grouping: ChannelGrouping
    ) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredChannels = channels
        } else {
            filteredChannels = channels.filter { channel in
                channel.displayName.localizedCaseInsensitiveContains(query)
                    || channel.groupTitle?.localizedCaseInsensitiveContains(query) == true
                    || channel.tvgName?.localizedCaseInsensitiveContains(query) == true
            }
        }
        sections = ChannelSectionBuilder.sections(
            channels: filteredChannels,
            grouping: grouping
        )
        defaultFocusChannelID = sections.first?.channels.first?.id
        showsGroupRail = grouping == .playlistGroups && sections.count > 1
    }
}

enum ChannelSectionBuilder {
    /// Where channels land when the playlist gives them no `group-title`. M3U
    /// files routinely omit it on a handful of entries, and those channels must
    /// stay reachable rather than vanish with their missing group.
    static let ungroupedTitle = "其他"
    static let flatSectionID = "channels.all"

    static func sections(
        channels: [Channel],
        grouping: ChannelGrouping
    ) -> [ChannelSection] {
        switch grouping {
        case .playlistOrder:
            return channels.isEmpty
                ? []
                : [ChannelSection(id: flatSectionID, title: nil, channels: channels)]
        case .playlistGroups:
            // Channels arrive sorted by (order, id) from AppModel.apply, so one
            // O(n) pass with a title→index map keeps both the channel order and
            // the order in which groups first appear.
            var indexByTitle: [String: Int] = [:]
            var result: [ChannelSection] = []
            for channel in channels {
                let title = resolvedGroupTitle(for: channel)
                if let index = indexByTitle[title] {
                    result[index].channels.append(channel)
                } else {
                    indexByTitle[title] = result.count
                    result.append(ChannelSection(id: title, title: title, channels: [channel]))
                }
            }
            return result
        }
    }

    private static func resolvedGroupTitle(for channel: Channel) -> String {
        let trimmed = channel.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return ungroupedTitle }
        return trimmed
    }
}
