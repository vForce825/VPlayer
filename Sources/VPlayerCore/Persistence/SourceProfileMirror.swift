// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// The part of a source profile that the user typed and no remote source can
/// return: the playlist name, both URLs, and the refresh intervals.
///
/// Refresh status and snapshot pointers are deliberately absent. They describe
/// stored data, so after a purge they would be claims about rows that no longer
/// exist; leaving them out lets a restored profile start as never-refreshed,
/// which is what it is. That also keeps the mirror off the refresh path, at the
/// cost of an `updatedAt` that tracks the last edit rather than the last
/// refresh — the value a restored profile should carry anyway.
struct MirroredSourceProfile: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let m3uURLString: String
    let epgURLString: String
    let m3uRefreshIntervalRaw: Int
    let epgRefreshIntervalRaw: Int
    let createdAt: Date
    let updatedAt: Date

    init(record: SourceProfileRecord) {
        id = record.id
        name = record.name
        m3uURLString = record.m3uURLString
        epgURLString = record.epgURLString
        m3uRefreshIntervalRaw = record.m3uRefreshIntervalRaw
        epgRefreshIntervalRaw = record.epgRefreshIntervalRaw
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    /// Nil when these values cannot rebuild a profile the library can read back.
    /// The mirror is plain UserDefaults with no schema behind it, so a single
    /// malformed entry must not make every other profile unreadable.
    func makeRecord() -> SourceProfileRecord? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isRestorable(m3uURLString),
              isRestorable(epgURLString),
              RefreshInterval(rawValue: m3uRefreshIntervalRaw) != nil,
              RefreshInterval(rawValue: epgRefreshIntervalRaw) != nil else {
            return nil
        }
        return SourceProfileRecord(
            id: id,
            name: name,
            m3uURLString: m3uURLString,
            epgURLString: epgURLString,
            m3uRefreshIntervalRaw: m3uRefreshIntervalRaw,
            epgRefreshIntervalRaw: epgRefreshIntervalRaw,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func isRestorable(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), url.host != nil else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// Every mirrored profile plus the active selection, which is user-entered too:
/// restoring the playlists but not which one was on would still change what the
/// viewer sees on the next launch.
struct SourceProfileMirrorSnapshot: Codable, Equatable, Sendable {
    var profiles: [MirroredSourceProfile]
    var activeProfileID: UUID?

    static let empty = Self(profiles: [], activeProfileID: nil)
}

/// A UserDefaults copy of the source profiles, kept because the SwiftData store
/// lives somewhere the system is allowed to delete.
///
/// tvOS denies the sandbox `Library/Application Support`, so the store sits in
/// `Library/Caches`, which tvOS may evict under storage pressure. Channels,
/// programmes, and snapshots are a mirror of the remote M3U and XMLTV and come
/// back with the next refresh; the profiles themselves were typed on a remote
/// control and exist nowhere else. UserDefaults survives that eviction and
/// allows roughly 500KB on tvOS, against a few hundred bytes per profile.
/// Unchecked because `UserDefaults` carries no `Sendable` conformance while
/// being documented as thread-safe, and the mirror only ever reads and writes
/// one key through it.
public struct SourceProfileMirror: @unchecked Sendable {
    public static let storageKey = "library.sourceProfileMirror"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// An unreadable mirror reads as empty rather than as an error: the caller
    /// only ever uses it to repopulate an empty store, and refusing to launch
    /// over corrupt recovery data would be worse than losing the recovery.
    func load() -> SourceProfileMirrorSnapshot {
        guard let data = defaults.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(
                SourceProfileMirrorSnapshot.self,
                from: data
              ) else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: SourceProfileMirrorSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
