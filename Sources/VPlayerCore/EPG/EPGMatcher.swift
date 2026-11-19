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
        try cancellationCheck()
        guard !channels.isEmpty, !epgChannels.isEmpty else { return [:] }
        var index = try EPGMatchIndex(
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
            matches[channel.id] = try index.match(
                channel: channel,
                manualMapping: manualMapping,
                cancellationCheck: cancellationCheck
            )
        }
        return matches
    }

    public static func match(
        channel: Channel,
        epgChannels: [EPGChannel],
        manualMapping: ManualEPGMapping?
    ) -> EPGMatchResult {
        guard !epgChannels.isEmpty else { return .unmatched }
        var index = EPGMatchIndex(epgChannels: epgChannels, cancellationCheck: {})
        return index.match(
            channel: channel,
            manualMapping: manualMapping,
            cancellationCheck: {}
        )
    }
}

/// Lookup tables shared by every playlist-channel match in one library reload.
/// Fuzzy signature indices are materialized lazily on the first channel that
/// misses manual, exact-ID, and exact-name lookups.
private struct EPGMatchIndex: Sendable {
    private struct SubstitutionSignature: Hashable, Sendable {
        let originalLength: Int
        let removedIndex: Int
        let remainder: String
    }

    private struct FuzzyTables: Sendable {
        let candidateIDsByOneDeletion: [String: Set<String>]
        let candidateIDsBySubstitutionSignature: [SubstitutionSignature: Set<String>]
    }

    private let channelIDs: Set<String>
    private let candidateIDsByNormalizedName: [String: Set<String>]
    private var fuzzyTables: FuzzyTables?

    init(
        epgChannels: [EPGChannel],
        cancellationCheck: () throws -> Void
    ) rethrows {
        var channelIDs: Set<String> = []
        var candidateIDsByNormalizedName: [String: Set<String>] = [:]
        channelIDs.reserveCapacity(epgChannels.count)

        try cancellationCheck()
        for epgChannel in epgChannels {
            try cancellationCheck()
            channelIDs.insert(epgChannel.id)
            var normalizedNames: Set<String> = []
            for displayName in epgChannel.displayNames {
                try cancellationCheck()
                let normalized = EPGNameNormalizer.normalize(displayName)
                try cancellationCheck()
                if !normalized.isEmpty { normalizedNames.insert(normalized) }
            }
            for normalizedName in normalizedNames {
                try cancellationCheck()
                candidateIDsByNormalizedName[normalizedName, default: []]
                    .insert(epgChannel.id)
            }
        }

        self.channelIDs = channelIDs
        self.candidateIDsByNormalizedName = candidateIDsByNormalizedName
        fuzzyTables = nil
    }

    mutating func match(
        channel: Channel,
        manualMapping: ManualEPGMapping?,
        cancellationCheck: () throws -> Void
    ) rethrows -> EPGMatchResult {
        try cancellationCheck()
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

        let channelNames = try Self.normalizedNames(
            for: channel, cancellationCheck: cancellationCheck
        )
        var exactCandidateIDs: Set<String> = []
        for channelName in channelNames {
            try cancellationCheck()
            exactCandidateIDs.formUnion(candidateIDsByNormalizedName[channelName] ?? [])
        }
        if let result = Self.result(for: exactCandidateIDs, method: .exactName) {
            return result
        }

        var eligibleFuzzyNames: [String] = []
        for channelName in channelNames {
            try cancellationCheck()
            if EPGNameNormalizer.isFuzzyMatchEligible(channelName) {
                eligibleFuzzyNames.append(channelName)
            }
        }
        guard !eligibleFuzzyNames.isEmpty else { return .unmatched }

        let fuzzyTables = try ensureFuzzyTables(cancellationCheck: cancellationCheck)
        var fuzzyCandidateIDs: Set<String> = []
        for channelName in eligibleFuzzyNames {
            try cancellationCheck()

            // XMLTV name is one character longer than the playlist name.
            fuzzyCandidateIDs.formUnion(fuzzyTables.candidateIDsByOneDeletion[channelName] ?? [])

            let originalLength = channelName.count
            try Self.forEachOneCharacterDeletion(
                of: channelName, cancellationCheck: cancellationCheck
            ) { removedIndex, remainder in
                // XMLTV name is one character shorter than the playlist name.
                if EPGNameNormalizer.isFuzzyMatchEligible(remainder) {
                    fuzzyCandidateIDs.formUnion(
                        candidateIDsByNormalizedName[remainder] ?? []
                    )
                }

                // Equal-length names with one substitution share the same
                // remainder when the differing position is removed.
                let signature = SubstitutionSignature(
                    originalLength: originalLength,
                    removedIndex: removedIndex,
                    remainder: remainder
                )
                fuzzyCandidateIDs.formUnion(
                    fuzzyTables.candidateIDsBySubstitutionSignature[signature] ?? []
                )
            }
        }
        if let result = Self.result(for: fuzzyCandidateIDs, method: .fuzzy) {
            return result
        }

        return .unmatched
    }

    private mutating func ensureFuzzyTables(
        cancellationCheck: () throws -> Void
    ) rethrows -> FuzzyTables {
        if let fuzzyTables { return fuzzyTables }
        var candidateIDsByOneDeletion: [String: Set<String>] = [:]
        var candidateIDsBySubstitutionSignature: [SubstitutionSignature: Set<String>] = [:]
        for (normalizedName, ids) in candidateIDsByNormalizedName {
            try cancellationCheck()
            guard EPGNameNormalizer.isFuzzyMatchEligible(normalizedName) else {
                continue
            }
            let originalLength = normalizedName.count
            try Self.forEachOneCharacterDeletion(
                of: normalizedName,
                cancellationCheck: cancellationCheck
            ) { removedIndex, remainder in
                candidateIDsByOneDeletion[remainder, default: []].formUnion(ids)
                candidateIDsBySubstitutionSignature[
                    SubstitutionSignature(
                        originalLength: originalLength,
                        removedIndex: removedIndex,
                        remainder: remainder
                    ),
                    default: []
                ].formUnion(ids)
            }
        }
        let built = FuzzyTables(
            candidateIDsByOneDeletion: candidateIDsByOneDeletion,
            candidateIDsBySubstitutionSignature: candidateIDsBySubstitutionSignature
        )
        fuzzyTables = built
        return built
    }

    private static func normalizedNames(
        for channel: Channel,
        cancellationCheck: () throws -> Void
    ) rethrows -> Set<String> {
        var result: Set<String> = []
        for name in [channel.tvgID, channel.tvgName, channel.displayName] {
            try cancellationCheck()
            guard let name else { continue }
            let normalized = EPGNameNormalizer.normalize(name)
            try cancellationCheck()
            if !normalized.isEmpty { result.insert(normalized) }
        }
        return result
    }

    private static func forEachOneCharacterDeletion(
        of value: String,
        cancellationCheck: () throws -> Void,
        body: (Int, String) -> Void
    ) rethrows {
        // Enforce the budget before allocating or traversing grapheme clusters,
        // even if a future caller forgets to check eligibility.
        guard EPGNameNormalizer.isFuzzyMatchEligible(value) else { return }
        var remainder = String()
        remainder.reserveCapacity(value.utf8.count)
        var removedIndex = 0
        var currentIndex = value.startIndex
        while currentIndex < value.endIndex {
            try cancellationCheck()
            let nextIndex = value.index(after: currentIndex)
            if !EPGNameNormalizer.isProtectedSemanticCharacter(value[currentIndex]) {
                remainder.removeAll(keepingCapacity: true)
                remainder.append(contentsOf: value[..<currentIndex])
                remainder.append(contentsOf: value[nextIndex...])
                body(removedIndex, remainder)
            }
            currentIndex = nextIndex
            removedIndex += 1
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
