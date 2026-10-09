// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import UIKit
import VPlayerPlayback

/// Selector notifications are synchronous. Closing the shared gate here, rather
/// than in a later SwiftUI task, fences both scan and YADIF GPU submissions.
@MainActor
final class IOSVideoProcessingLifecycle: NSObject {
    override init() {
        super.init()
        PlaybackVideoProcessingActivity.setForeground(UIApplication.shared.applicationState == .active)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    @objc private func willResignActive() { PlaybackVideoProcessingActivity.setForeground(false) }
    @objc private func didBecomeActive() { PlaybackVideoProcessingActivity.setForeground(true) }
    deinit { NotificationCenter.default.removeObserver(self) }
}
