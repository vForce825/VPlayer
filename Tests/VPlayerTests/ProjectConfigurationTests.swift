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

        for forbidden in ["absoluteString", "streamURL", "query", "channelName", "rawChannel"] {
            XCTAssertFalse(signposts.contains(forbidden), "signposts reference sensitive field: \(forbidden)")
        }
        XCTAssertTrue(acceptanceView.contains("player-acceptance-metrics"))
        XCTAssertTrue(acceptanceView.contains("JSONEncoder"))
        XCTAssertFalse(acceptanceView.contains("streamURL.absoluteString"))
        XCTAssertTrue(runner.contains("VPLAYER_ACCEPTANCE_M3U_URL"))
        XCTAssertFalse(runner.contains("set -x"))
        XCTAssertFalse(runner.contains("echo \"${VPLAYER_ACCEPTANCE_M3U_URL}"))
        XCTAssertFalse(runner.contains("echo \"$VPLAYER_ACCEPTANCE_M3U_URL"))
        XCTAssertTrue(runner.contains("devicectl device info details --device \"$device_udid\""))
        XCTAssertTrue(runner.contains("productType: AppleTV14,1"))
        XCTAssertTrue(runner.contains("• udid:"))
        XCTAssertTrue(runner.contains("-destination \"platform=tvOS,id=$destination_udid\""))
        XCTAssertFalse(runner.contains("-destination \"platform=tvOS,id=$device_udid\""))
        XCTAssertTrue(runner.contains("acceptance.xcconfig"))
        XCTAssertTrue(runner.contains("-xcconfig \"$acceptance_xcconfig\""))
        XCTAssertTrue(project.contains("INFOPLIST_FILE: Tests/VPlayerUITests/Info.plist"))
        XCTAssertTrue(uiTestInfoPlist.contains("$(VPLAYER_ACCEPTANCE_M3U_URL_B64)"))
        XCTAssertTrue(acceptanceTest.contains("Data(base64Encoded:"))
        XCTAssertTrue(acceptanceTest.contains("Bundle(for: Self.self)"))
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
}
