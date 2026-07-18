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
}
