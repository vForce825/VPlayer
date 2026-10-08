// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore
import VPlayerPlayback

@main
struct VPlayeriOSApp: App {
    private let bootstrap = LiveAppBootstrap.production()
    private let videoProcessingLifecycle = IOSVideoProcessingLifecycle()
    private let initialDependencies: AppDependencies?
    init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        if configuration.resetsPlaybackSettings {
            for key in [PlaybackSettingsStore.videoBufferSecondsKey,
                        PlaybackSettingsStore.deinterlaceBufferFramesKey,
                        ChannelBrowsingSettingsStore.storageKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #if DEBUG
        switch configuration.mode {
        case .seededFixture: initialDependencies = .uiTesting(playbackFixture: configuration.playbackFixture)
        case .acceptance: initialDependencies = .acceptance()
        case .live: initialDependencies = nil
        }
        #else
        initialDependencies = nil
        #endif
    }
    var body: some Scene {
        WindowGroup {
            IOSBootstrapView(bootstrap: bootstrap, initialDependencies: initialDependencies)
        }
    }
}

private struct IOSBootstrapView: View {
    let bootstrap: LiveAppBootstrap
    let initialDependencies: AppDependencies?
    @State private var loaded: AppDependencies?
    @State private var failure: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let dependencies = initialDependencies ?? loaded {
                IOSRootView(dependencies: dependencies)
            } else if let failure {
                VStack(spacing: 20) {
                    ContentUnavailableView("无法打开本地资料库", systemImage: "externaldrive.badge.xmark",
                        description: Text(failure))
                    Button("重试") { attempt += 1 }
                }
            } else { ProgressView("正在打开本地资料库…") }
        }
        .task(id: attempt) {
            guard initialDependencies == nil, loaded == nil else { return }
            failure = nil
            do {
                let dependencies = try await bootstrap.dependencies()
                guard !Task.isCancelled else { return }
                loaded = dependencies
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                failure = ErrorDiagnosticSnapshot(error).summary
            }
        }
    }
}
