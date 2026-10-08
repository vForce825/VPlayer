// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import OSLog
import SwiftUI
import VPlayerCore
import VPlayerPlayback

private struct LiveDependenciesRootView: View {
    private enum LoadState {
        case loading
        case failed(ErrorDiagnosticSnapshot)
        case ready
    }

    let bootstrap: LiveAppBootstrap
    @State private var dependencies: VPlayerDependencies?
    @State private var loadState = LoadState.loading
    @State private var loadAttempt = 0

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("正在打开本地资料库…")
                    .accessibilityIdentifier("library.runtime.loading")
            case .failed(let diagnostic):
                VStack(spacing: 28) {
                    ContentUnavailableView(
                        "无法打开本地资料库",
                        systemImage: "externaldrive.badge.xmark",
                        description: Text("本地资料暂时无法打开，请重试。\n\(diagnostic.summary)")
                    )
                    Button("重试") {
                        loadAttempt += 1
                    }
                    .accessibilityIdentifier("library.runtime.retry")
                }
            case .ready:
                if let dependencies {
                    RootView(dependencies: dependencies)
                }
            }
        }
        .task(id: loadAttempt) {
            guard dependencies == nil else { return }
            loadState = .loading
            do {
                let loadedDependencies = try await bootstrap.dependencies()
                guard !Task.isCancelled else { return }
                dependencies = loadedDependencies
                loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let diagnostic = ErrorDiagnosticSnapshot(error)
                launchLogger.error(
                    "本地资料库启动失败（\(diagnostic.typeName, privacy: .public)；\(diagnostic.summary, privacy: .private)）。"
                )
                loadState = .failed(diagnostic)
            }
        }
    }
}

@main
struct VPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies: VPlayerDependencies?
    private let liveBootstrap: LiveAppBootstrap?
    private let foregroundRefreshDriver: ForegroundRefreshDriver
    private let backgroundRefreshRegistrar: BackgroundRefreshRegistrar

    init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        if configuration.resetsPlaybackSettings {
            UserDefaults.standard.removeObject(
                forKey: PlaybackSettingsStore.videoBufferSecondsKey
            )
            UserDefaults.standard.removeObject(
                forKey: PlaybackSettingsStore.deinterlaceBufferFramesKey
            )
            UserDefaults.standard.removeObject(forKey: ChannelBrowsingSettingsStore.storageKey)
        }
        switch configuration.mode {
        case .live:
            self.init(liveBootstrap: .production())
        case .seededFixture:
            #if DEBUG
            self.init(dependencies: .uiTesting(playbackFixture: configuration.playbackFixture))
            #else
            self.init(liveBootstrap: .production())
            #endif
        case .acceptance:
            #if DEBUG
            self.init(dependencies: .acceptance())
            #else
            self.init(liveBootstrap: .production())
            #endif
        }
    }

    init(dependencies: VPlayerDependencies) {
        self.dependencies = dependencies
        liveBootstrap = nil
        foregroundRefreshDriver = dependencies.foregroundRefreshDriver
        backgroundRefreshRegistrar = dependencies.backgroundRefreshRegistrar
        backgroundRefreshRegistrar.register()
    }

    init(liveBootstrap: LiveAppBootstrap) {
        dependencies = nil
        self.liveBootstrap = liveBootstrap
        foregroundRefreshDriver = liveBootstrap.foregroundRefreshDriver
        backgroundRefreshRegistrar = liveBootstrap.backgroundRefreshRegistrar
        // BGTaskScheduler requires every launch handler to be registered before
        // application launch completes. The lightweight registrar can do that
        // synchronously while its closures await the shared detached runtime.
        backgroundRefreshRegistrar.register()
    }

    var body: some Scene {
        WindowGroup {
            if let dependencies {
                RootView(dependencies: dependencies)
            } else if let liveBootstrap {
                LiveDependenciesRootView(bootstrap: liveBootstrap)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            handleScenePhase(phase)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            foregroundRefreshDriver.activate()
        case .inactive, .background:
            foregroundRefreshDriver.deactivate()
            backgroundRefreshRegistrar.scheduleNext()
        @unknown default:
            foregroundRefreshDriver.deactivate()
            backgroundRefreshRegistrar.scheduleNext()
        }
    }
}

private let launchLogger = Logger(subsystem: "com.vforce.vplayer", category: "Launch")
