// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import UIKit
import VPlayerPlayback

/// Selector notifications are synchronous. Closing the shared gate here, rather
/// than in a later SwiftUI task, fences both scan and YADIF GPU submissions.
@MainActor
final class IOSVideoProcessingLifecycle: NSObject {
    private let notifications: NotificationCenter
    private let setForeground: @MainActor (Bool) -> Void

    init(notifications: NotificationCenter = .default,
         initiallyForeground: Bool? = nil,
         setForeground: @escaping @MainActor (Bool) -> Void = PlaybackVideoProcessingActivity.setForeground) {
        self.notifications = notifications
        self.setForeground = setForeground
        super.init()
        setForeground(initiallyForeground ?? (UIApplication.shared.applicationState == .active))
        notifications.addObserver(self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    @objc private func willResignActive() { setForeground(false) }
    @objc private func didBecomeActive() { setForeground(true) }
    deinit { notifications.removeObserver(self) }
}
