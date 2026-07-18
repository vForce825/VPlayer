// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

enum AppLaunchMode: Equatable {
    case live
    case seededFixture
}

struct AppLaunchConfiguration {
    let mode: AppLaunchMode
    let resetsPlaybackSettings: Bool

    init(arguments: [String]) {
        let fixtureFlags = arguments.indices.filter { arguments[$0] == "-ui-fixture" }
        if fixtureFlags.count == 1,
           let flagIndex = fixtureFlags.first,
           arguments.indices.contains(flagIndex + 1),
           arguments[flagIndex + 1] == "seeded" {
            mode = .seededFixture
        } else {
            mode = .live
        }
        resetsPlaybackSettings = arguments.contains("-uiTestResetPlaybackSettings")
    }
}

@main
struct VPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies: VPlayerDependencies

    init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        if configuration.resetsPlaybackSettings {
            UserDefaults.standard.removeObject(forKey: PlaybackSettingsStore.storageKey)
        }
        switch configuration.mode {
        case .live:
            self.init(dependencies: .live())
        case .seededFixture:
            self.init(dependencies: .uiTesting())
        }
    }

    init(dependencies: VPlayerDependencies) {
        self.dependencies = dependencies
        dependencies.backgroundRefreshRegistrar.register()
        dependencies.launch()
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            handleScenePhase(phase)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            dependencies.foregroundRefreshDriver.activate()
        case .inactive, .background:
            dependencies.foregroundRefreshDriver.deactivate()
            dependencies.backgroundRefreshRegistrar.scheduleNext()
        @unknown default:
            dependencies.foregroundRefreshDriver.deactivate()
            dependencies.backgroundRefreshRegistrar.scheduleNext()
        }
    }
}
