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
}
