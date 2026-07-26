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

#if DEBUG
enum AcceptanceLaunchSelection {
    static func isSelected(arguments: [String]) -> Bool {
        arguments.filter { $0 == "-acceptance-playback" }.count == 1
            && !arguments.contains("-ui-fixture")
    }
}
#endif

struct AcceptanceFocusPolicy: Equatable {
    enum RootTab: Hashable {
        case channels
        case sources
        case settings
    }

    enum SourceControl: Hashable {
        case add
        case playlistRefresh
        case epgRefresh
    }

    enum PlayerControl: Hashable {
        case back
        case playPause
        case settings
    }

    let isEnabled: Bool

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self {
        #if DEBUG
        Self(isEnabled: AcceptanceLaunchSelection.isSelected(arguments: arguments))
        #else
        Self(isEnabled: false)
        #endif
    }

    var initialRootTab: RootTab {
        isEnabled ? .sources : .channels
    }

    var initialSourceControl: SourceControl? {
        isEnabled ? .add : nil
    }

    var sourceControlAfterEditorDismissal: SourceControl? {
        isEnabled ? .playlistRefresh : nil
    }

    var focusesFirstChannel: Bool {
        isEnabled
    }

    var initialPlayerControl: PlayerControl {
        isEnabled ? .settings : .playPause
    }
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
        if AcceptanceLaunchSelection.isSelected(arguments: arguments) {
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
        // Release builds never honor test-only launch flags: seeded fixtures,
        // the fake playback engine, and acceptance harness paths are DEBUG-only.
        _ = fixtureFlags
        _ = acceptanceFlags
        mode = .live
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
    static let encodedEPGKey = "VPLAYER_ACCEPTANCE_EPG_URL_B64"

    let name: String
    let m3uURLString: String
    let epgURLString: String

    static func isActive(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        AcceptanceLaunchSelection.isSelected(arguments: arguments)
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        guard isActive(arguments: arguments),
              let m3uURLString = decodedHTTPURL(
                from: environment[encodedM3UKey]
              ) else {
            return nil
        }
        let epgURLString: String
        if let encodedEPG = environment[encodedEPGKey] {
            guard let decodedEPG = decodedHTTPURL(from: encodedEPG) else { return nil }
            epgURLString = decodedEPG
        } else {
            epgURLString = "https://example.invalid/acceptance.xml"
        }
        return Self(
            name: "Device Acceptance",
            m3uURLString: m3uURLString,
            epgURLString: epgURLString
        )
    }

    private static func decodedHTTPURL(from encoded: String?) -> String? {
        guard let encoded,
              let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return value
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
            self.init(dependencies: .live())
        case .seededFixture:
            #if DEBUG
            self.init(dependencies: .uiTesting(playbackFixture: configuration.playbackFixture))
            #else
            self.init(dependencies: .live())
            #endif
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
