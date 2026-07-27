// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerCore
@testable import VPlayerPlayback

final class ProjectConfigurationTests: XCTestCase {
    func testDeploymentTargetIsTVOS18() {
        XCTAssertEqual(VPlayerCore.deploymentTarget, "tvOS 18.0")
        XCTAssertEqual(PlaybackFoundation.contractVersion, 1)
    }

    func testPlaybackMetalAndFutureVideoFixturesHaveExplicitTargetConfiguration() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let generatedProject = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VPlayer.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(
            projectYAML.contains("- path: Sources/VPlayerPlayback"),
            "the recursive playback source root must keep future .metal files in the target"
        )
        XCTAssertTrue(
            projectYAML.contains(
                "- path: Tests/Fixtures/Video\n        type: folder\n        buildPhase: resources"
            ),
            "future video fixtures must be copied as a folder resource when introduced"
        )
        XCTAssertTrue(generatedProject.contains("Shaders.metal in Sources"))
        XCTAssertTrue(generatedProject.contains("Video in Resources"))
    }

    func testAcceptanceDiagnosticsAndRunnerKeepSensitivePayloadsOutOfLogsAndArtifacts() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let signposts = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/VPlayerPlayback/Diagnostics/PlaybackSignposts.swift"
            ),
            encoding: .utf8
        )
        let acceptanceView = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/VPlayerApp/Player/FullScreenPlayerView.swift"
            ),
            encoding: .utf8
        )
        let acceptanceStatePresentation = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/VPlayerApp/Player/AcceptancePlaybackStatePresentation.swift"
            ),
            encoding: .utf8
        )
        let runner = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/run-device-acceptance.sh"
            ),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let acceptanceTest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Tests/VPlayerUITests/LongPlaybackAcceptanceTests.swift"
            ),
            encoding: .utf8
        )
        let uiTestInfoPlist = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Tests/VPlayerUITests/Info.plist"
            ),
            encoding: .utf8
        )
        let signalTest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/test-device-acceptance-signal.sh"
            ),
            encoding: .utf8
        )
        let signingResolver = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/resolve-acceptance-development-team.sh"
            ),
            encoding: .utf8
        )
        let signingTest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/test-device-acceptance-signing.sh"
            ),
            encoding: .utf8
        )
        let sourceEditor = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/VPlayerApp/Views/SourceProfileEditorView.swift"
            ),
            encoding: .utf8
        )

        for forbidden in ["absoluteString", "streamURL", "query", "channelName", "rawChannel"] {
            XCTAssertFalse(signposts.contains(forbidden), "signposts reference sensitive field: \(forbidden)")
        }
        XCTAssertTrue(acceptanceView.contains("player-acceptance-metrics"))
        XCTAssertTrue(acceptanceView.contains("JSONEncoder"))
        XCTAssertTrue(acceptanceView.contains("acceptanceMetricsJSON = \"unavailable\""))
        XCTAssertFalse(acceptanceView.contains("streamURL.absoluteString"))
        XCTAssertTrue(acceptanceView.contains("player-acceptance-state"))
        XCTAssertTrue(acceptanceView.contains(
            "AcceptancePlaybackStatePresentation(state: model.state).value"
        ))
        XCTAssertTrue(acceptanceView.contains("if acceptanceStateEnabled"))
        XCTAssertTrue(acceptanceStatePresentation.contains("#if DEBUG"))
        XCTAssertTrue(acceptanceStatePresentation.contains("failure.code"))
        for forbidden in ["request.", "streamURL", "channelID", "title", "userMessage"] {
            XCTAssertFalse(
                acceptanceStatePresentation.contains(forbidden),
                "acceptance state presentation references sensitive field: \(forbidden)"
            )
        }
        XCTAssertTrue(runner.contains("VPLAYER_ACCEPTANCE_M3U_URL"))
        XCTAssertTrue(runner.contains("VPLAYER_ACCEPTANCE_EPG_URL"))
        XCTAssertFalse(runner.contains("set -x"))
        XCTAssertFalse(runner.contains("echo \"${VPLAYER_ACCEPTANCE_M3U_URL}"))
        XCTAssertFalse(runner.contains("echo \"$VPLAYER_ACCEPTANCE_M3U_URL"))
        XCTAssertFalse(runner.contains("echo \"${VPLAYER_ACCEPTANCE_EPG_URL}"))
        XCTAssertFalse(runner.contains("echo \"$VPLAYER_ACCEPTANCE_EPG_URL"))
        XCTAssertTrue(runner.contains("devicectl device info details --device \"$device_udid\""))
        XCTAssertTrue(runner.contains("productType: AppleTV14,1"))
        XCTAssertTrue(runner.contains("• udid:"))
        XCTAssertTrue(runner.contains("-destination \"platform=tvOS,id=$destination_udid\""))
        XCTAssertFalse(runner.contains("-destination \"platform=tvOS,id=$device_udid\""))
        XCTAssertTrue(runner.contains("acceptance.xcconfig"))
        XCTAssertTrue(runner.contains("-xcconfig \"$acceptance_xcconfig\""))
        XCTAssertTrue(runner.contains("security find-certificate"))
        XCTAssertTrue(runner.contains("resolve_acceptance_development_team"))
        XCTAssertTrue(runner.contains("-a -Z -p -c \"Apple Development:\""))
        XCTAssertTrue(signingResolver.contains("signing_fingerprint"))
        XCTAssertTrue(signingResolver.contains("openssl x509"))
        XCTAssertTrue(signingResolver.contains("OU=([A-Z0-9]{10})"))
        XCTAssertFalse(signingResolver.contains("printf '%s\\n' \"$selected_certificate\""))
        XCTAssertTrue(signingTest.contains("TEAMWRONG1"))
        XCTAssertTrue(signingTest.contains("TEAMRIGHT1"))
        XCTAssertTrue(signingTest.contains("Apple Development: Duplicate Name"))
        XCTAssertFalse(runner.contains("Apple Development:.*\\(([A-Z0-9]{10})\\)"))
        XCTAssertFalse(runner.contains("VPLAYER_ACCEPTANCE_M3U_URL=\"$m3u_url\""))
        XCTAssertFalse(runner.contains("VPLAYER_ACCEPTANCE_CHANNEL=\"$channel\""))
        XCTAssertTrue(runner.contains("child_pid=$!"))
        XCTAssertTrue(runner.contains("wait \"$child_pid\""))
        XCTAssertTrue(runner.contains("kill -\"$signal\" -- \"-$child_pid\""))
        XCTAssertTrue(runner.contains("rg -a -F -q -- \"$m3u_url\""))
        XCTAssertTrue(runner.contains("rg -a -F -q -- \"$epg_url\""))
        XCTAssertTrue(signalTest.contains("VPLAYER_ACCEPTANCE_SIGNAL_TEST_MODE=1"))
        XCTAssertTrue(signalTest.contains("VPLAYER_ACCEPTANCE_PREFLIGHT_SIGNAL_TEST_MODE=1"))
        XCTAssertTrue(signalTest.contains("run_prechild_signal_test HUP"))
        XCTAssertTrue(signalTest.contains("[[ \"$status\" == \"130\" ]]"))
        XCTAssertTrue(runner.contains("abort_if_signaled"))
        XCTAssertTrue(project.contains("INFOPLIST_FILE: Tests/VPlayerUITests/Info.plist"))
        XCTAssertTrue(uiTestInfoPlist.contains("$(VPLAYER_ACCEPTANCE_M3U_URL_B64)"))
        XCTAssertTrue(uiTestInfoPlist.contains("$(VPLAYER_ACCEPTANCE_EPG_URL_B64)"))
        XCTAssertTrue(acceptanceTest.contains("Data(base64Encoded:"))
        XCTAssertTrue(acceptanceTest.contains("Bundle(for: Self.self)"))
        XCTAssertTrue(acceptanceTest.contains("ContinuousClock()"))
        XCTAssertTrue(acceptanceTest.contains("json != \"unavailable\""))
        XCTAssertTrue(acceptanceTest.contains("player-acceptance-state"))
        XCTAssertTrue(acceptanceTest.contains("stateElement: stateElement"))
        XCTAssertTrue(acceptanceTest.contains("case playbackFailed(code: String)"))
        XCTAssertTrue(acceptanceTest.contains("case preparationTimedOut"))
        let stableRouteBody = try XCTUnwrap(
            acceptanceTest.components(separatedBy: "private func awaitStableRoute(").dropFirst().first?
                .components(separatedBy: "private func activeHeartbeat(").first
        )
        let stateRead = try XCTUnwrap(stableRouteBody.range(
            of: "let state = try playbackState(from: stateElement)"
        ))
        let metricsRead = try XCTUnwrap(stableRouteBody.range(
            of: "if let snapshot = try? snapshot(from: element)"
        ))
        XCTAssertLessThan(stateRead.lowerBound, metricsRead.lowerBound)
        XCTAssertTrue(acceptanceTest.contains("app.launchEnvironment = configuration.encodedEnvironment"))
        XCTAssertTrue(acceptanceTest.contains("private func selectTab("))
        XCTAssertTrue(acceptanceTest.contains("private func activateContent("))
        XCTAssertFalse(acceptanceTest.contains("private func focus("))
        XCTAssertTrue(acceptanceTest.contains(
            "try AcceptanceTabFocusNavigator.focusAndSelect("
        ))
        XCTAssertTrue(acceptanceTest.contains("target: AcceptanceNavigationTarget"))
        XCTAssertTrue(acceptanceTest.contains("targetHasFocus: { tab.hasFocus }"))
        XCTAssertFalse(acceptanceTest.contains("XCTAssertTrue(element.hasFocus)"))
        XCTAssertFalse(acceptanceTest.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(acceptanceTest.contains("typeText(m3u"))
        XCTAssertTrue(sourceEditor.contains("text: .constant(m3uFieldPresentation.displayedValue)"))
        XCTAssertTrue(sourceEditor.contains("text: .constant(epgFieldPresentation.displayedValue)"))
        XCTAssertTrue(sourceEditor.contains("text: $m3uURLString"))
        XCTAssertFalse(sourceEditor.contains(".accessibilityValue("))
        XCTAssertTrue(sourceEditor.contains(
            "@FocusState private var focusedTarget: SourceProfileEditorFocusPolicy.Target?"
        ))
        XCTAssertTrue(sourceEditor.contains(
            ".focused($focusedTarget, equals: .save)"
        ))
        XCTAssertTrue(sourceEditor.contains(
            "if let initialTarget = focusPolicy.initialTarget"
        ))
        XCTAssertTrue(sourceEditor.contains(
            ".defaultFocus($focusedTarget, initialTarget)"
        ))
        XCTAssertEqual(
            sourceEditor.components(separatedBy: "await Task.yield()").count - 1,
            1
        )
        XCTAssertTrue(sourceEditor.contains("focusedTarget = initialTarget"))
        XCTAssertFalse(sourceEditor.contains("@Namespace private var editorFocus"))
        XCTAssertFalse(sourceEditor.contains(".prefersDefaultFocus("))
        XCTAssertFalse(sourceEditor.contains(".focusScope(editorFocus)"))
    }

    func testProductionSourcesKeepTask12ForbiddenControlsAndCopiesAbsent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        let sourceURLs = enumerator.compactMap { $0 as? URL }.filter {
            ["swift", "metal", "c", "h"].contains($0.pathExtension)
        }
        let source = try sourceURLs.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(source.contains("thermalState"))
        XCTAssertFalse(source.contains("waitUntilCompleted"))
        let deinterlace = try sourceURLs
            .filter { $0.path.contains("/Deinterlace/") }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(deinterlace.contains("CVPixelBufferLockBaseAddress"))
    }

    func testAcceptanceFocusWiringCoversEveryRealFlowBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
        }

        let launch = try source("Sources/VPlayerApp/VPlayerApp.swift")
        let root = try source("Sources/VPlayerApp/Views/RootView.swift")
        let profiles = try source("Sources/VPlayerApp/Views/SourceProfilesView.swift")
        let editor = try source("Sources/VPlayerApp/Views/SourceProfileEditorView.swift")
        let settings = try source("Sources/VPlayerApp/Settings/PlaybackSettingsView.swift")
        let channels = try source("Sources/VPlayerApp/Views/ChannelBrowserView.swift")
        let playerControls = try source("Sources/VPlayerApp/Player/PlayerControlsOverlay.swift")
        let acceptanceTest = try source(
            "Tests/VPlayerUITests/LongPlaybackAcceptanceTests.swift"
        )

        XCTAssertTrue(launch.contains("struct AcceptanceFocusPolicy"))
        XCTAssertTrue(launch.contains("AcceptanceLaunchSelection.isSelected(arguments: arguments)"))
        XCTAssertTrue(root.contains("TabView(selection: $selectedTab)"))
        XCTAssertTrue(root.contains("focusPolicy.initialRootTab"))
        XCTAssertTrue(profiles.contains(
            "@FocusState private var focusedControl: AcceptanceFocusPolicy.SourceControl?"
        ))
        XCTAssertTrue(profiles.contains(".focused($focusedControl, equals: .add)"))
        XCTAssertTrue(profiles.contains("focusTarget: .playlistRefresh"))
        XCTAssertTrue(profiles.contains("focusTarget: .epgRefresh"))
        XCTAssertTrue(profiles.contains(".focused($focusedControl, equals: focusTarget)"))
        XCTAssertTrue(profiles.contains("if let initialControl = focusPolicy.initialSourceControl"))
        XCTAssertTrue(profiles.contains(".defaultFocus($focusedControl, initialControl)"))
        XCTAssertEqual(
            profiles.components(separatedBy: "await Task.yield()").count - 1,
            1
        )
        XCTAssertTrue(profiles.contains("guard !model.profiles.isEmpty else { return }"))
        XCTAssertTrue(profiles.contains("focusedControl = target"))
        XCTAssertFalse(profiles.contains("@Environment(\\.resetFocus)"))
        XCTAssertFalse(profiles.contains("@Namespace private var sourceFocus"))
        XCTAssertFalse(profiles.contains(".prefersDefaultFocus("))
        XCTAssertFalse(profiles.contains(".focusScope(sourceFocus)"))
        XCTAssertFalse(profiles.contains("resetFocus(in: sourceFocus)"))
        XCTAssertTrue(profiles.contains("focusPolicy.sourceControlAfterEditorDismissal"))
        XCTAssertFalse(profiles.contains("placesSourceAddInContent"))
        XCTAssertFalse(profiles.contains(".toolbar"))
        XCTAssertTrue(profiles.contains(
            "statusIdentifier: \"source.status.playlist\""
        ))
        XCTAssertTrue(profiles.contains(
            "statusIdentifier: \"source.status.epg\""
        ))
        XCTAssertTrue(profiles.contains(".accessibilityIdentifier(statusIdentifier)"))
        XCTAssertTrue(editor.contains(
            "@FocusState private var focusedTarget: SourceProfileEditorFocusPolicy.Target?"
        ))
        XCTAssertTrue(editor.contains(".focused($focusedTarget, equals: .save)"))
        XCTAssertTrue(editor.contains("if let initialTarget = focusPolicy.initialTarget"))
        XCTAssertTrue(editor.contains(".defaultFocus($focusedTarget, initialTarget)"))
        XCTAssertEqual(
            editor.components(separatedBy: "await Task.yield()").count - 1,
            1
        )
        XCTAssertTrue(editor.contains("focusedTarget = initialTarget"))
        XCTAssertFalse(editor.contains("@Namespace private var editorFocus"))
        XCTAssertFalse(editor.contains(".prefersDefaultFocus("))
        XCTAssertFalse(editor.contains(".focusScope(editorFocus)"))
        XCTAssertFalse(editor.contains("placesSaveInContent"))
        XCTAssertFalse(editor.contains(".confirmationAction"))
        XCTAssertEqual(
            editor.components(separatedBy: ".textInputAutocapitalization(.never)").count - 1,
            2
        )
        XCTAssertEqual(
            editor.components(separatedBy: ".autocorrectionDisabled()").count - 1,
            2
        )
        // The picture settings are plain selection rows now; nothing on the
        // screen needs a scoped default focus target.
        XCTAssertFalse(settings.contains(".prefersDefaultFocus("))
        XCTAssertFalse(settings.contains(".focusScope("))
        XCTAssertTrue(channels.contains(
            "@FocusState private var focusedElement: ChannelBrowserFocus?"
        ))
        XCTAssertTrue(channels.contains(
            ".focused($focusedElement, equals: .channel(channel.id))"
        ))
        XCTAssertTrue(channels.contains(
            ".defaultFocus($focusedElement, defaultFocusElement)"
        ))
        XCTAssertTrue(channels.contains("focusPolicy.focusesFirstChannel"))
        XCTAssertTrue(playerControls.contains("@FocusState private var focusedControl"))
        XCTAssertTrue(playerControls.contains(".defaultFocus($focusedControl, initialControl)"))
        XCTAssertTrue(playerControls.contains("focusedControl = initialControl"))
        XCTAssertFalse(playerControls.contains("resetFocus(in: playerFocus)"))
        XCTAssertTrue(playerControls.contains("focusPolicy.initialPlayerControl"))
        XCTAssertTrue(acceptanceTest.contains("enum AcceptanceTab: Int"))
        XCTAssertTrue(acceptanceTest.contains("case channels = 0"))
        XCTAssertTrue(acceptanceTest.contains("case sources = 1"))
        XCTAssertTrue(acceptanceTest.contains("case settings = 2"))
        XCTAssertTrue(acceptanceTest.contains("maximumFocusAcquisitionPresses = 8"))
        XCTAssertTrue(acceptanceTest.contains("normalizationLeftPresses = 3"))
        XCTAssertTrue(acceptanceTest.contains("AcceptanceTabFocusNavigator.focusAndSelect("))
        XCTAssertFalse(acceptanceTest.contains("for _ in 0..<12"))
        XCTAssertFalse(acceptanceTest.contains(
            "[.down, .right, .up, .left]"
        ))
        XCTAssertTrue(acceptanceTest.contains("try activateContent("))
        XCTAssertTrue(acceptanceTest.contains(
            "app.staticTexts[\"source.status.playlist\"]"
        ))
        XCTAssertFalse(acceptanceTest.contains("app.staticTexts[\"刷新成功\"]"))
        XCTAssertTrue(acceptanceTest.contains("AcceptanceRefreshOutcomeGuard.activate("))
        XCTAssertTrue(acceptanceTest.contains("AcceptanceRefreshOutcomeGuard.classify("))
        XCTAssertFalse(acceptanceTest.contains("element.hasFocus"))
    }
}
