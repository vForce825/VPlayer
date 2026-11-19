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
    private(set) var isLibraryWindowVisible = false
    private(set) var isRefreshing = false
    var isLoading = false
    var showsSourceManager = false
    var showsAddSource = false
    var showsProgrammes = false
    var isTheaterMode = false
    @ObservationIgnored private(set) weak var libraryWindow: NSWindow?
    @ObservationIgnored var openLibraryWindow: (() -> Void)?
    @ObservationIgnored private let bootstrap = LiveAppBootstrap.production()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var replacementTask: Task<Void, Never>?
    @ObservationIgnored private var replacementGeneration = UUID()
    @ObservationIgnored private var requestedPlaybackID: UUID?
    @ObservationIgnored private var pendingOverlayCarryOver: MacPlayerOverlayState.CarryOver?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var programmeWindowTask: Task<Void, Never>?
    @ObservationIgnored private var isObservingModel = false

    var isActiveProfileRefreshing: Bool {
        if isRefreshing { return true }
        guard let profile = model?.activeProfile else { return false }
        return profile.m3uStatus.state == .refreshing || profile.epgStatus.state == .refreshing
    }

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
        startModelObservers()
    }
    #endif
    func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard dependencies == nil else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }
    private func performLoad() async {
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
            startModelObservers()
            loaded.foregroundRefreshDriver.activate()
        } catch is CancellationError { return }
        catch { startupError = ErrorDiagnosticSnapshot(error).summary }
    }
    private func startModelObservers() {
        guard !isObservingModel, let model else { return }
        isObservingModel = true
        observePlaybackRequest(syncCurrent: model.presentedPlaybackRequest != nil)
        observePresentationMetadata(syncCurrent: false)
        programmeWindowTask?.cancel()
        programmeWindowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let model = self?.model else { return }
                await model.maintainProgrammeWindow()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    private func stopModelObservers() {
        isObservingModel = false
        programmeWindowTask?.cancel()
        programmeWindowTask = nil
    }
    private func observePlaybackRequest(syncCurrent: Bool) {
        guard isObservingModel, let model else { return }
        let request = withObservationTracking {
            model.presentedPlaybackRequest
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePlaybackRequest(syncCurrent: true)
            }
        }
        if syncCurrent {
            replaceSession(for: request)
        }
    }
    private func observePresentationMetadata(syncCurrent: Bool) {
        guard isObservingModel, let model else { return }
        withObservationTracking {
            _ = model.programmesByChannelID
            _ = model.channels
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePresentationMetadata(syncCurrent: true)
            }
        }
        if syncCurrent {
            refreshPresentation()
        }
    }
    func replaceSession(for request: PlaybackRequest?) {
        guard requestedPlaybackID != request?.id else { return }
        requestedPlaybackID = request?.id
        let pending = replacementTask
        pending?.cancel()
        let generation = UUID()
        replacementGeneration = generation
        let previous = session
        if request == nil {
            pendingOverlayCarryOver = nil
            showsProgrammes = false
            session = nil
        } else if pendingOverlayCarryOver == nil, let previous, !previous.isClosing {
            pendingOverlayCarryOver = previous.overlay.snapshotForChannelSwitch()
        }
        replacementTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.replacementGeneration == generation {
                    self.replacementTask = nil
                }
            }
            await pending?.value
            await previous?.close()
            guard let self, !Task.isCancelled, self.replacementGeneration == generation else { return }
            guard let request, let dependencies = self.dependencies else {
                if self.session === previous { self.session = nil }
                self.pendingOverlayCarryOver = nil
                return
            }
            let next = MacPlaybackSession(presentation: self.presentation(for: request), dependencies: dependencies)
            if let carryOver = self.pendingOverlayCarryOver {
                next.overlay.applyChannelSwitchCarryOver(carryOver, paused: next.model.isPaused)
                self.pendingOverlayCarryOver = nil
            }
            next.onStopped = { [weak self, weak next] in
                guard let self, let next, self.session === next else { return }
                Task { await self.stopPlayback(requestID: next.model.request.id) }
            }
            next.pictureInPicture.onStopped = { [weak self, weak next] in
                guard let self, let next, self.session === next else { return }
                guard !self.isLibraryWindowVisiblyOnScreen else { return }
                Task { await self.stopPlayback(requestID: next.model.request.id) }
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
    func requestStopPlayback() {
        guard let requestID = requestedPlaybackID else { return }
        Task { await stopPlayback(requestID: requestID) }
    }
    func stopPlayback(requestID: UUID? = nil) async {
        if let requestID, requestedPlaybackID != requestID { return }
        requestedPlaybackID = nil
        pendingOverlayCarryOver = nil
        showsProgrammes = false
        let generation = UUID()
        replacementGeneration = generation
        let pending = replacementTask
        pending?.cancel()
        let previous = session
        session = nil
        model?.dismissPlayback()
        let task = Task { @MainActor [weak self] in
            await pending?.value
            await previous?.close()
            if let self, self.replacementGeneration == generation {
                self.replacementTask = nil
            }
        }
        replacementTask = task
        await task.value
    }
    func shutdown() async {
        stopModelObservers()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        dependencies?.foregroundRefreshDriver.deactivate()
        await stopPlayback()
    }
    func refresh() {
        guard !isActiveProfileRefreshing, let model, let profile = model.activeProfile else { return }
        isRefreshing = true
        refreshTask = Task { @MainActor [weak self] in
            defer {
                self?.isRefreshing = false
                self?.refreshTask = nil
            }
            await model.refresh(profileID: profile.id, resource: .playlist)
            guard !Task.isCancelled else { return }
            await model.refresh(profileID: profile.id, resource: .epg)
        }
    }
    func registerLibraryWindow(_ window: NSWindow?) {
        if let window {
            libraryWindow = window
            isLibraryWindowVisible = true
            isTheaterMode = window.styleMask.contains(.fullScreen)
        }
    }
    func libraryWindowWillClose(_ window: NSWindow) {
        guard window === libraryWindow else { return }
        isLibraryWindowVisible = false
        isTheaterMode = false
        guard session?.pictureInPicture.isActive != true else { return }
        requestStopPlayback()
    }
    private var isLibraryWindowVisiblyOnScreen: Bool {
        guard let window = libraryWindow else { return false }
        return Self.isWindowVisiblyOnScreen(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOnActiveSpace: window.isOnActiveSpace,
            occlusionState: window.occlusionState
        )
    }
    static func isWindowVisiblyOnScreen(
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool,
        occlusionState: NSWindow.OcclusionState
    ) -> Bool {
        isVisible && !isMiniaturized && isOnActiveSpace && occlusionState.contains(.visible)
    }
    private func restoreLibraryWindow(completion: @escaping @MainActor (Bool) -> Void) {
        NSApp.activate()
        if libraryWindow?.isMiniaturized == true { libraryWindow?.deminiaturize(nil) }
        if libraryWindow?.isVisible != true { openLibraryWindow?() }
        Task { @MainActor [weak self] in
            for _ in 0..<50 {
                if let window = self?.libraryWindow, window.isVisible {
                    self?.isLibraryWindowVisible = true
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
        guard isLibraryWindowVisible, let window = libraryWindow else { return }
        window.toggleFullScreen(nil)
    }

    #if DEBUG
    var hasInFlightReplacementForTesting: Bool { replacementTask != nil }
    #endif
}
