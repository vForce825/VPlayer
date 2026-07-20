// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

enum AppLaunchMode: Equatable {
    case live
    case seededFixture
    case acceptance
}

struct AppLaunchConfiguration {
    let mode: AppLaunchMode
    let resetsPlaybackSettings: Bool
    let playbackFixture: String?

    init(arguments: [String]) {
        let fixtureFlags = arguments.indices.filter { arguments[$0] == "-ui-fixture" }
        let acceptanceFlags = arguments.indices.filter {
            arguments[$0] == "-acceptance-playback"
        }
        #if DEBUG
        if acceptanceFlags.count == 1 && fixtureFlags.isEmpty {
            mode = .acceptance
        } else if acceptanceFlags.isEmpty,
                  fixtureFlags.count == 1,
           let flagIndex = fixtureFlags.first,
           arguments.indices.contains(flagIndex + 1),
           arguments[flagIndex + 1] == "seeded" {
            mode = .seededFixture
        } else {
            mode = .live
        }
        #else
        if acceptanceFlags.isEmpty,
           fixtureFlags.count == 1,
           let flagIndex = fixtureFlags.first,
           arguments.indices.contains(flagIndex + 1),
           arguments[flagIndex + 1] == "seeded" {
            mode = .seededFixture
        } else {
            mode = .live
        }
        #endif
        resetsPlaybackSettings = arguments.contains("-uiTestResetPlaybackSettings")
        let playbackFixtureFlags = arguments.indices.filter {
            arguments[$0] == "-ui-playback-fixture"
        }
        if playbackFixtureFlags.count == 1,
           let flagIndex = playbackFixtureFlags.first,
           arguments.indices.contains(flagIndex + 1) {
            playbackFixture = arguments[flagIndex + 1]
        } else {
            playbackFixture = nil
        }
    }
}

#if DEBUG
struct AcceptanceSourcePrefill: Equatable {
    static let encodedM3UKey = "VPLAYER_ACCEPTANCE_M3U_URL_B64"

    let name: String
    let m3uURLString: String
    let epgURLString: String

    static func isActive(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.filter { $0 == "-acceptance-playback" }.count == 1
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        guard isActive(arguments: arguments),
              let encoded = environment[encodedM3UKey],
              let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return Self(
            name: "Device Acceptance",
            m3uURLString: value,
            epgURLString: "https://example.invalid/acceptance.xml"
        )
    }
}
#endif

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
            self.init(dependencies: .uiTesting(playbackFixture: configuration.playbackFixture))
        case .acceptance:
            #if DEBUG
            self.init(dependencies: .acceptance())
            #else
            self.init(dependencies: .live())
            #endif
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
