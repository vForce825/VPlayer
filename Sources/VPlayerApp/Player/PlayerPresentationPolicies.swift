// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerPlayback

enum FullScreenPlayerLifecyclePolicy {
    static func shouldStopOnDisappear(isPresentingSettings: Bool) -> Bool {
        !isPresentingSettings
    }
}

/// Decides when the transport controls and channel information card are mounted
/// and whether they are pinned or owned by the single playback auto-hide task.
enum PlayerControlsVisibilityPolicy {
    enum Mode: Equatable, Sendable {
        case hidden
        case pinned
        case timed
    }

    static let idleTimeout = Duration.seconds(3)

    static func mode(for state: PlaybackState) -> Mode {
        switch state {
        case .idle, .preparing, .buffering, .recovering, .paused:
            .pinned
        case .playing:
            .timed
        case .stopped, .failed:
            .hidden
        }
    }

    static func mountsOverlays(for state: PlaybackState) -> Bool {
        mountsOverlays(for: mode(for: state))
    }

    static func mountsOverlays(for mode: Mode) -> Bool {
        mode != .hidden
    }

    static func staysVisible(for state: PlaybackState) -> Bool {
        mode(for: state) == .pinned
    }
}

enum PlayerControlsVisibilityEvent: Equatable, Sendable {
    case stateChanged(PlayerControlsVisibilityPolicy.Mode)
    case userInteraction
    case mediaInformationBecameAvailable
    case timeoutCompleted(PlayerControlsAutoHideKey)
}

struct PlayerControlsAutoHideKey: Equatable, Sendable {
    let mode: PlayerControlsVisibilityPolicy.Mode
    let wakeRevision: UInt64
}

struct PlayerControlsVisibilityState: Equatable, Sendable {
    private(set) var mode: PlayerControlsVisibilityPolicy.Mode
    private(set) var wakeRevision: UInt64
    private(set) var isVisible: Bool

    init(
        mode: PlayerControlsVisibilityPolicy.Mode,
        wakeRevision: UInt64 = 0
    ) {
        self.mode = mode
        self.wakeRevision = wakeRevision
        isVisible = mode != .hidden
    }

    var key: PlayerControlsAutoHideKey {
        PlayerControlsAutoHideKey(mode: mode, wakeRevision: wakeRevision)
    }

    mutating func apply(_ event: PlayerControlsVisibilityEvent) {
        switch event {
        case let .stateChanged(nextMode):
            guard mode != nextMode else { return }
            mode = nextMode
            isVisible = nextMode != .hidden
        case .userInteraction, .mediaInformationBecameAvailable:
            guard mode == .timed else { return }
            isVisible = true
            wakeRevision &+= 1
        case let .timeoutCompleted(completedKey):
            guard mode == .timed, key == completedKey else { return }
            isVisible = false
        }
    }
}

enum PlayerControlsAutoHidePolicy {
    static func shouldSleep(for key: PlayerControlsAutoHideKey) -> Bool {
        key.mode == .timed
    }

    static func shouldHide(
        after key: PlayerControlsAutoHideKey,
        current: PlayerControlsAutoHideKey
    ) -> Bool {
        key.mode == .timed && key == current
    }
}

enum PlayerControlsCommandPolicy {
    static func handlePlayPause(
        wake: () -> Void,
        toggle: () -> Void
    ) {
        wake()
        toggle()
    }
}

enum PlayerFailureActionPolicy {
    static func showsRetry(for failure: PlaybackFailure) -> Bool {
        failure.retryDisposition == .retrySameRequest
    }
}

/// Keeps tvOS from treating uninterrupted video watching as user inactivity.
/// Paused, stopped, and failed playback deliberately return control to the
/// system so the app cannot suppress the screen saver indefinitely.
enum PlaybackIdleTimerPolicy {
    static func isDisabled(for state: PlaybackState) -> Bool {
        switch state {
        case .preparing, .buffering, .recovering, .playing:
            true
        case .idle, .paused, .stopped, .failed:
            false
        }
    }
}

