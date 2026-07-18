// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

@main
struct VPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies: VPlayerDependencies

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestResetPlaybackSettings") {
            UserDefaults.standard.removeObject(forKey: PlaybackSettingsStore.storageKey)
        }
        self.init(dependencies: arguments.contains("-ui-testing") ? .uiTesting() : .live())
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
