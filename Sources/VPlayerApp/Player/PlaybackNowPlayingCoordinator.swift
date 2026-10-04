// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import NowPlaying
import Observation
import OSLog
import UIKit
import VPlayerPlayback

@MainActor
protocol NowPlayingPlaybackTarget: AnyObject {
    func setPausedFromNowPlaying(_ paused: Bool) async
    func stopFromNowPlaying() async
}

@MainActor
protocol NowPlayingSessionPublishing: AnyObject {
    func requestPrimary() async throws
}

@MainActor
private final class SystemNowPlayingSession: NowPlayingSessionPublishing {
    private let session: MediaSession<PlaybackNowPlayingModel>

    init(_ model: PlaybackNowPlayingModel) { session = MediaSession(model) }

    func requestPrimary() async throws {
        try await session.requestToBecomeApplicationPrimary()
    }
}

/// The session observes this metadata model, which only weakly refers to the
/// playback owner. The playback owner does not own the MediaSession itself.
@MainActor
@Observable
final class PlaybackNowPlayingModel: MediaSessionRepresentable {
    let id = UUID().uuidString
    private var presentation: PlayerChannelPresentation
    private var metadataDate = Date.now
    private var state: PlaybackState = .idle
    private var isValid = true
    private var artwork: Artwork?
    @ObservationIgnored private weak var owner: (any NowPlayingPlaybackTarget)?

    init(owner: any NowPlayingPlaybackTarget, presentation: PlayerChannelPresentation) {
        self.owner = owner
        self.presentation = presentation
        updateArtwork()
    }

    var content: (any MediaContentRepresentable)? {
        guard isValid else { return nil }
        let programme = presentation.programmes.first {
            $0.start <= metadataDate && metadataDate < $0.stop
        }
        let request = presentation.request
        return GenericContent(
            id: "\(request.sourceProfileID.uuidString)/\(request.channelID)",
            title: programme?.title ?? request.title,
            subtitle: programme == nil ? nil : request.title,
            type: .video,
            duration: .live,
            artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard isValid else { return nil }
        let systemState: MediaPlaybackSnapshot.PlaybackState
        switch state {
        case .playing: systemState = .playing(rate: 1)
        case .paused: systemState = .paused
        case .preparing, .buffering, .recovering: systemState = .buffering
        case .idle, .stopped, .failed: systemState = .stopped
        }
        // Live streams have no supported elapsed-time/seek window. Do not use
        // the programme's EPG duration as a seekable playback duration.
        return MediaPlaybackSnapshot(state: systemState)
    }

    var commands: [MediaCommand] {
        guard isValid, owner != nil else { return [] }
        switch state {
        case .playing, .paused:
            return [
                .play { [weak self] in await self?.setPaused(false) },
                .pause { [weak self] in await self?.setPaused(true) },
                .stop { [weak self] in await self?.stop() },
            ]
        case .preparing, .buffering, .recovering:
            return [.stop { [weak self] in await self?.stop() }]
        case .idle, .stopped, .failed:
            return []
        }
    }

    func setPaused(_ paused: Bool) async {
        guard isValid else { return }
        switch state {
        case .playing, .paused: await owner?.setPausedFromNowPlaying(paused)
        case .idle, .preparing, .buffering, .recovering, .stopped, .failed: break
        }
    }

    func stop() async {
        guard isValid else { return }
        await owner?.stopFromNowPlaying()
    }

    func update(_ newState: PlaybackState) { state = newState }

    func matches(_ request: PlaybackRequest) -> Bool { presentation.request.id == request.id }

    func updatePresentation(_ presentation: PlayerChannelPresentation) {
        guard isValid, self.presentation.request.id == presentation.request.id else { return }
        let logoChanged = self.presentation.logoURL != presentation.logoURL
        self.presentation = presentation
        metadataDate = .now
        if logoChanged || artwork == nil { updateArtwork() }
    }

    func refreshProgramme(at date: Date) {
        metadataDate = date
        if artwork == nil { updateArtwork() }
    }

    func nextProgrammeBoundary(after date: Date) -> Date? {
        presentation.programmes.lazy.flatMap { [$0.start, $0.stop] }
            .filter { $0 > date }.min()
    }

    func invalidate() {
        isValid = false
        owner = nil
        artwork = nil
        state = .stopped
    }

    private func updateArtwork() {
        artwork = nil
        guard let url = presentation.logoURL,
              let image = ChannelLogoCache.shared.memoryCachedImage(for: url),
              let data = image.pngData(), data.count <= 1_024 * 1_024 else { return }
        // The shared cache already downsampled this image. Retain at most one
        // bounded encoded thumbnail; the provider performs no network work and
        // captures neither a UIKit image nor the playback owner.
        artwork = Artwork(id: "\(presentation.request.channelID)/\(url.absoluteString)") { _ in
            try ArtworkRepresentation(data: data)
        }
    }
}

/// One coordinator per AppDependencies instance. Owner tokens fence metadata,
/// commands, timer callbacks and late stop completions across player replacement.
@MainActor
final class PlaybackNowPlayingCoordinator {
    typealias SessionFactory = @MainActor (PlaybackNowPlayingModel) -> any NowPlayingSessionPublishing

    private let makeSession: SessionFactory
    private(set) var current: PlaybackNowPlayingModel?
    private var ownerID: UUID?
    private var latestOwnerID: UUID?
    private var session: (any NowPlayingSessionPublishing)?
    private var requestedOwnerID: UUID?
    private var wantsSession = false
    private var primaryRequestTask: Task<Void, Never>?
    private var programmeTask: Task<Void, Never>?

    convenience init() {
        self.init(makeSession: { SystemNowPlayingSession($0) })
    }

    init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    deinit {
        primaryRequestTask?.cancel()
        programmeTask?.cancel()
    }

    @discardableResult
    func begin(owner: any NowPlayingPlaybackTarget, presentation: PlayerChannelPresentation) -> UUID {
        current?.invalidate()
        session = nil
        wantsSession = false
        let id = UUID()
        ownerID = id
        latestOwnerID = id
        current = PlaybackNowPlayingModel(owner: owner, presentation: presentation)
        scheduleProgrammeUpdate(owner: id)
        return id
    }

    func update(_ state: PlaybackState, owner id: UUID) {
        guard ownerID == id, let current else { return }
        switch state {
        case .stopped:
            end(owner: id)
            return
        case let .preparing(request), let .buffering(request), let .recovering(request),
             let .playing(request), let .paused(request):
            // FullScreenPlayerViewModel also checks the request; the coordinator
            // cannot promote an unrelated shared-engine event into this session.
            guard current.matches(request) else { return }
        case .idle, .failed:
            break
        }
        current.update(state)
        if case .failed = state {
            session = nil
            wantsSession = false
            return
        }
        switch state {
        case .playing, .paused:
            if !wantsSession {
                wantsSession = true
                requestedOwnerID = nil
                startPrimaryWorkerIfNeeded()
            }
        case .idle, .preparing, .buffering, .recovering, .stopped, .failed:
            break
        }
    }

    func updatePresentation(_ presentation: PlayerChannelPresentation, owner id: UUID) {
        guard ownerID == id else { return }
        current?.updatePresentation(presentation)
        scheduleProgrammeUpdate(owner: id)
    }

    func owns(_ id: UUID) -> Bool { ownerID == id }

    /// Unlike active ownership, this remains true after this owner ends, until
    /// a replacement begins. It fences delayed physical engine teardown.
    func isLatestOwner(_ id: UUID) -> Bool { latestOwnerID == id }

    func end(owner id: UUID) {
        guard ownerID == id else { return }
        ownerID = nil
        current?.invalidate()
        current = nil
        session = nil
        wantsSession = false
        programmeTask?.cancel()
        programmeTask = nil
    }

    private func startPrimaryWorkerIfNeeded() {
        guard primaryRequestTask == nil else { return }
        primaryRequestTask = Task { @MainActor [weak self] in
            // A cancelled request can still complete physically. Never overlap
            // primary requests: after the old one settles, publish the newest
            // desired session. The await retains only that session, not self.
            while let operation = self?.takePrimaryRequest() {
                do { try await operation.session.requestPrimary() }
                catch {
                    // Publication failure is nonfatal; do not feed it into the
                    // media engine or apply a late error to a replacement owner.
                    if self?.owns(operation.owner) == true {
                        Logger(subsystem: "com.vforce.vplayer", category: "NowPlaying")
                            .warning("Now Playing publication failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
            self?.primaryRequestTask = nil
        }
    }

    private func takePrimaryRequest() -> (owner: UUID, session: any NowPlayingSessionPublishing)? {
        guard wantsSession, let ownerID, requestedOwnerID != ownerID, let current else { return nil }
        // Construct the replacement only after the old primary operation has
        // physically returned, keeping creation and activation in one lane.
        let session = makeSession(current)
        self.session = session
        requestedOwnerID = ownerID
        return (ownerID, session)
    }

    private func scheduleProgrammeUpdate(owner id: UUID) {
        programmeTask?.cancel()
        programmeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  let delay = self?.nextProgrammeDelay(owner: id) {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard !Task.isCancelled, self?.ownerID == id else { return }
                self?.current?.refreshProgramme(at: .now)
            }
        }
    }

    private func nextProgrammeDelay(owner id: UUID) -> TimeInterval? {
        guard ownerID == id else { return nil }
        let now = Date.now
        guard let next = current?.nextProgrammeBoundary(after: now) else { return nil }
        return min(max(next.timeIntervalSince(now), 0.05), 3_600)
    }
}
