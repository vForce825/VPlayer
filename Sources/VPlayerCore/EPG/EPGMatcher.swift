// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum EPGMatchMethod: String, Equatable, Sendable {
    case manual
    case exactID
    case exactName
    case fuzzy
}

public enum EPGMatchResult: Equatable, Sendable {
    case matched(xmltvChannelID: String, method: EPGMatchMethod)
    case ambiguous([String])
    case unmatched

    public var xmltvChannelID: String? {
        if case let .matched(id, _) = self {
            return id
        }
        return nil
    }
}

public enum EPGMatcher {
    public static func match(
        channel: Channel,
        epgChannels: [EPGChannel],
        manualMapping: ManualEPGMapping?
    ) -> EPGMatchResult {
        if let manualMapping,
           manualMapping.sourceProfileID == channel.sourceProfileID,
           manualMapping.channelID == channel.id,
           epgChannels.contains(where: { $0.id == manualMapping.xmltvChannelID }) {
            return .matched(xmltvChannelID: manualMapping.xmltvChannelID, method: .manual)
        }

        if let tvgID = channel.tvgID,
           let result = result(for: Set(epgChannels.filter { $0.id == tvgID }.map(\.id)), method: .exactID) {
            return result
        }

        let channelNames = normalizedNames(for: channel)
        if let result = result(
            for: candidateIDs(in: epgChannels) { epgChannel in
                epgChannel.displayNames.contains { channelNames.contains(EPGNameNormalizer.normalize($0)) }
            },
            method: .exactName
        ) {
            return result
        }

        if let result = result(
            for: candidateIDs(in: epgChannels) { epgChannel in
                epgChannel.displayNames.contains { displayName in
                    channelNames.contains { EPGNameNormalizer.isConservativeFuzzyMatch($0, displayName) }
                }
            },
            method: .fuzzy
        ) {
            return result
        }

        return .unmatched
    }

    private static func normalizedNames(for channel: Channel) -> Set<String> {
        Set([channel.tvgID, channel.tvgName, channel.displayName].compactMap { name in
            guard let name else { return nil }
            let normalized = EPGNameNormalizer.normalize(name)
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func candidateIDs(
        in epgChannels: [EPGChannel],
        where predicate: (EPGChannel) -> Bool
    ) -> Set<String> {
        Set(epgChannels.lazy.filter(predicate).map(\.id))
    }

    private static func result(for candidateIDs: Set<String>, method: EPGMatchMethod) -> EPGMatchResult? {
        switch candidateIDs.count {
        case 0:
            nil
        case 1:
            .matched(xmltvChannelID: candidateIDs.first!, method: method)
        default:
            .ambiguous(candidateIDs.sorted())
        }
    }
}
