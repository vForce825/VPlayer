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
    /// Matches a whole playlist against one reusable XMLTV index. Building the
    /// index once avoids re-normalizing and linearly scanning the same EPG
    /// channel corpus for every channel during an app reload.
    public static func matches(
        channels: [Channel],
        epgChannels: [EPGChannel],
        manualMappingsByChannelID: [String: String]
    ) -> [String: EPGMatchResult] {
        matches(
            channels: channels,
            epgChannels: epgChannels,
            manualMappingsByChannelID: manualMappingsByChannelID,
            cancellationCheck: {}
        )
    }

    /// Cancellation-aware variant for reload workers. The check is injected
    /// so VPlayerCore does not need to own a task or choose its cancellation
    /// policy.
    public static func matches(
        channels: [Channel],
        epgChannels: [EPGChannel],
        manualMappingsByChannelID: [String: String],
        cancellationCheck: () throws -> Void
    ) rethrows -> [String: EPGMatchResult] {
        let index = try EPGMatchIndex(
            epgChannels: epgChannels,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        var matches: [String: EPGMatchResult] = [:]
        matches.reserveCapacity(channels.count)
        for channel in channels {
            try cancellationCheck()
            let manualMapping = manualMappingsByChannelID[channel.id].map {
                ManualEPGMapping(
                    sourceProfileID: channel.sourceProfileID,
                    channelID: channel.id,
                    xmltvChannelID: $0
                )
            }
            matches[channel.id] = index.match(
                channel: channel,
                manualMapping: manualMapping
            )
        }
        return matches
    }

    public static func match(
        channel: Channel,
        epgChannels: [EPGChannel],
        manualMapping: ManualEPGMapping?
    ) -> EPGMatchResult {
        EPGMatchIndex(epgChannels: epgChannels, cancellationCheck: {}).match(
            channel: channel,
            manualMapping: manualMapping
        )
    }
}

/// Immutable lookup tables shared by every playlist-channel match in one
/// library reload.
private struct EPGMatchIndex: Sendable {
    private struct SubstitutionSignature: Hashable, Sendable {
        let originalLength: Int
        let removedIndex: Int
        let remainder: String
    }

    private let channelIDs: Set<String>
    private let candidateIDsByNormalizedName: [String: Set<String>]
    private let candidateIDsByOneDeletion: [String: Set<String>]
    private let candidateIDsBySubstitutionSignature: [SubstitutionSignature: Set<String>]

    init(
        epgChannels: [EPGChannel],
        cancellationCheck: () throws -> Void
    ) rethrows {
        var channelIDs: Set<String> = []
        var candidateIDsByNormalizedName: [String: Set<String>] = [:]
        var candidateIDsByOneDeletion: [String: Set<String>] = [:]
        var candidateIDsBySubstitutionSignature: [SubstitutionSignature: Set<String>] = [:]
        channelIDs.reserveCapacity(epgChannels.count)

        try cancellationCheck()
        for epgChannel in epgChannels {
            try cancellationCheck()
            channelIDs.insert(epgChannel.id)
            let normalizedNames = Set(epgChannel.displayNames.compactMap { displayName in
                let normalized = EPGNameNormalizer.normalize(displayName)
                return normalized.isEmpty ? nil : normalized
            })
            for normalizedName in normalizedNames {
                candidateIDsByNormalizedName[normalizedName, default: []]
                    .insert(epgChannel.id)
                guard normalizedName.count >= 5 else { continue }
                for deletion in Self.oneCharacterDeletions(of: normalizedName) {
                    candidateIDsByOneDeletion[deletion.remainder, default: []]
                        .insert(epgChannel.id)
                    candidateIDsBySubstitutionSignature[
                        SubstitutionSignature(
                            originalLength: normalizedName.count,
                            removedIndex: deletion.index,
                            remainder: deletion.remainder
                        ),
                        default: []
                    ].insert(epgChannel.id)
                }
            }
        }

        self.channelIDs = channelIDs
        self.candidateIDsByNormalizedName = candidateIDsByNormalizedName
        self.candidateIDsByOneDeletion = candidateIDsByOneDeletion
        self.candidateIDsBySubstitutionSignature = candidateIDsBySubstitutionSignature
    }

    func match(
        channel: Channel,
        manualMapping: ManualEPGMapping?
    ) -> EPGMatchResult {
        if let manualMapping,
           manualMapping.sourceProfileID == channel.sourceProfileID,
           manualMapping.channelID == channel.id,
           channelIDs.contains(manualMapping.xmltvChannelID) {
            return .matched(xmltvChannelID: manualMapping.xmltvChannelID, method: .manual)
        }

        if let tvgID = channel.tvgID,
           channelIDs.contains(tvgID) {
            return .matched(xmltvChannelID: tvgID, method: .exactID)
        }

        let channelNames = Self.normalizedNames(for: channel)
        var exactCandidateIDs: Set<String> = []
        for channelName in channelNames {
            exactCandidateIDs.formUnion(candidateIDsByNormalizedName[channelName] ?? [])
        }
        if let result = Self.result(for: exactCandidateIDs, method: .exactName) {
            return result
        }

        var fuzzyCandidateIDs: Set<String> = []
        for channelName in channelNames {
            guard channelName.count >= 5 else { continue }

            // XMLTV name is one character longer than the playlist name.
            fuzzyCandidateIDs.formUnion(candidateIDsByOneDeletion[channelName] ?? [])

            for deletion in Self.oneCharacterDeletions(of: channelName) {
                // XMLTV name is one character shorter than the playlist name.
                if deletion.remainder.count >= 5 {
                    fuzzyCandidateIDs.formUnion(
                        candidateIDsByNormalizedName[deletion.remainder] ?? []
                    )
                }

                // Equal-length names with one substitution share the same
                // remainder when the differing position is removed.
                let signature = SubstitutionSignature(
                    originalLength: channelName.count,
                    removedIndex: deletion.index,
                    remainder: deletion.remainder
                )
                fuzzyCandidateIDs.formUnion(
                    candidateIDsBySubstitutionSignature[signature] ?? []
                )
            }
        }
        if let result = Self.result(for: fuzzyCandidateIDs, method: .fuzzy) {
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

    private static func oneCharacterDeletions(
        of value: String
    ) -> [(index: Int, remainder: String)] {
        let characters = Array(value)
        return characters.indices.map { removedIndex in
            var remainder = characters
            remainder.remove(at: removedIndex)
            return (removedIndex, String(remainder))
        }
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
