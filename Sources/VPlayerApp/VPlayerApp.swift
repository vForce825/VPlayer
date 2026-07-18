// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

@main
struct VPlayerApp: App {
    private let dependencies: VPlayerDependencies

    init() {
        self.init(dependencies: .production())
    }

    init(dependencies: VPlayerDependencies) {
        self.dependencies = dependencies
        dependencies.launch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
