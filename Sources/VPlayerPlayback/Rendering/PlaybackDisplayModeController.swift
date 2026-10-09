// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

/// The platform display-mode boundary; media clocks and presentation ownership
/// stay in the shared context. iPhone has no HDMI mode matching contract.
@MainActor
protocol PlaybackDisplayModeControlling: AnyObject {
    func enterFullScreen(formatDescription: CMFormatDescription, outputFrameRate: Float)
    func leaveFullScreen()
}

@MainActor
public protocol DisplayLinkControlling: AnyObject {
    func pause()
    func resetPresentationTiming()
    func resume()
}

@MainActor
public protocol DisplayReadinessControlling: AnyObject {
    func closeForDisplayModeSwitch()
    func reanchorAfterDisplayModeSwitch() -> Bool
}

#if os(iOS)
@MainActor
final class IOSDisplayModeController: PlaybackDisplayModeControlling {
    func enterFullScreen(formatDescription: CMFormatDescription, outputFrameRate: Float) {}
    func leaveFullScreen() {}
}
#endif
