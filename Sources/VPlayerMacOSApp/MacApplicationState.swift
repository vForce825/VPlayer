// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import Foundation
import Observation
import VPlayerCore
import VPlayerPlayback

@MainActor
@Observable
final class MacApplicationState {
    let sidebar: MacSidebarPreferences
    private(set) var dependencies: AppDependencies?
    private(set) var model: AppModel?
    private(set) var session: MacPlaybackSession?
    private(set) var startupError: String?
    var isLoading = false
    var showsSourceManager = false
    var showsAddSource = false
    var isTheaterMode = false
    @ObservationIgnored private(set) weak var libraryWindow: NSWindow?
    @ObservationIgnored var openLibraryWindow: (() -> Void)?
    private let bootstrap = LiveAppBootstrap.production()
    private var replacementTask: Task<Void, Never>?
    private var replacementGeneration = UUID()
    private var requestedPlaybackID: UUID?

    init() {
        #if DEBUG
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        if configuration.mode == .seededFixture,
           let defaults = UserDefaults(suiteName: "com.vforce.vplayer.ui-tests.desktop") {
            if configuration.resetsPlaybackSettings { defaults.removeObject(forKey: MacSidebarPreferences.widthKey) }
            sidebar = MacSidebarPreferences(defaults: defaults)
            return
        }
        #endif
        sidebar = MacSidebarPreferences()
    }
    #if DEBUG
    init(dependenciesForTesting: AppDependencies) {
        sidebar = MacSidebarPreferences()
        dependencies = dependenciesForTesting
        model = AppModel(repository: dependenciesForTesting.repository, refresh: dependenciesForTesting.refresh,
            libraryChanges: dependenciesForTesting.libraryChanges)
    }
    #endif
    func load() async {
        guard dependencies == nil, !isLoading else { return }
        isLoading = true
        startupError = nil
        defer { isLoading = false }
        do {
            let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
            if configuration.resetsPlaybackSettings {
                for key in [PlaybackSettingsStore.videoBufferSecondsKey, PlaybackSettingsStore.deinterlaceBufferFramesKey,
                            ChannelBrowsingSettingsStore.storageKey] { UserDefaults.standard.removeObject(forKey: key) }
            }
            let loaded: AppDependencies
            #if DEBUG
            if configuration.mode == .seededFixture { loaded = .uiTesting(playbackFixture: configuration.playbackFixture) }
            else { loaded = try await bootstrap.dependencies() }
            #else
            _ = configuration
            loaded = try await bootstrap.dependencies()
            #endif
            let model = AppModel(repository: loaded.repository, refresh: loaded.refresh, libraryChanges: loaded.libraryChanges)
            guard await loaded.openInitialLibrary(using: model) else {
                startupError = model.alertMessage ?? "无法载入本地资料库，请重试。"
                return
            }
            try Task.checkCancellation()
            self.model = model
            dependencies = loaded
            loaded.foregroundRefreshDriver.activate()
        } catch is CancellationError { return }
        catch { startupError = ErrorDiagnosticSnapshot(error).summary }
    }
    func replaceSession(for request: PlaybackRequest?) {
        guard requestedPlaybackID != request?.id else { return }
        requestedPlaybackID = request?.id
        let pending = replacementTask
        pending?.cancel()
        let generation = UUID()
        replacementGeneration = generation
        let previous = session
        session = nil
        replacementTask = Task { @MainActor [weak self] in
            await pending?.value
            await previous?.close()
            guard let self, !Task.isCancelled, self.replacementGeneration == generation,
                  let request, let dependencies = self.dependencies else { return }
            let next = MacPlaybackSession(presentation: self.presentation(for: request), dependencies: dependencies)
            next.onStopped = { [weak self, weak next] in
                guard let self, self.session === next else { return }
                Task { await self.stopPlayback() }
            }
            next.pictureInPicture.onStopped = { [weak self, weak next] in
                guard let self, self.session === next, self.libraryWindow?.isVisible != true else { return }
                Task { await self.stopPlayback() }
            }
            next.pictureInPicture.onRestore = { [weak self] completion in
                guard let self else { completion(false); return }
                self.restoreLibraryWindow(completion: completion)
            }
            self.session = next
            next.start()
        }
    }
    func presentation(for request: PlaybackRequest) -> PlayerChannelPresentation {
        let channel = model?.channels.first { $0.id == request.channelID }
        return .init(request: request, logoURL: channel?.logoURL,
            programmes: model?.programmesByChannelID[request.channelID] ?? [])
    }
    func refreshPresentation() {
        guard let session else { return }
        session.updatePresentation(presentation(for: session.model.request))
    }
    func stopPlayback() async {
        requestedPlaybackID = nil
        replacementGeneration = UUID()
        let pending = replacementTask
        pending?.cancel()
        replacementTask = nil
        let previous = session
        session = nil
        model?.dismissPlayback()
        await pending?.value
        await previous?.close()
    }
    func shutdown() async {
        dependencies?.foregroundRefreshDriver.deactivate()
        await stopPlayback()
    }
    func refresh() {
        guard let model, let profile = model.activeProfile else { return }
        Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
            await model.refresh(profileID: profile.id, resource: .epg)
        }
    }
    func registerLibraryWindow(_ window: NSWindow?) {
        if let window { libraryWindow = window }
    }
    func libraryWindowWillClose(_ window: NSWindow) {
        guard window === libraryWindow, session?.pictureInPicture.isActive != true else { return }
        Task { await stopPlayback() }
    }
    private func restoreLibraryWindow(completion: @escaping @MainActor (Bool) -> Void) {
        NSApp.activate()
        if libraryWindow?.isMiniaturized == true { libraryWindow?.deminiaturize(nil) }
        if libraryWindow?.isVisible != true { openLibraryWindow?() }
        Task { @MainActor [weak self] in
            for _ in 0..<50 {
                if let window = self?.libraryWindow, window.isVisible {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                    completion(true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { completion(false); return }
            }
            completion(false)
        }
    }
    func toggleFullScreen() {
        guard let window = libraryWindow else { return }
        window.toggleFullScreen(nil)
    }
}
