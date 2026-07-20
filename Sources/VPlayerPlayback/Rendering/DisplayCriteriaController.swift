// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit
import Foundation
import UIKit

@MainActor
public protocol DisplayCriteriaManaging: AnyObject {
    var preferredDisplayCriteria: AVDisplayCriteria? { get set }
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

@MainActor
public final class WindowDisplayCriteriaManager: DisplayCriteriaManaging {
    private weak var manager: AVDisplayManager?

    public init(window: UIWindow) {
        manager = window.avDisplayManager
    }

    public var preferredDisplayCriteria: AVDisplayCriteria? {
        get { manager?.preferredDisplayCriteria }
        set { manager?.preferredDisplayCriteria = newValue }
    }
}

@MainActor
public final class DisplayCriteriaController: NSObject {
    typealias CriteriaFactory = (Float, CMFormatDescription) -> AVDisplayCriteria

    private let manager: DisplayCriteriaManaging
    private let notificationCenter: NotificationCenter
    private let criteriaFactory: CriteriaFactory
    private let displayLink: DisplayLinkControlling
    private let readiness: DisplayReadinessControlling
    private var isFullScreen = false
    private var isSwitchingMode = false

    init(
        manager: DisplayCriteriaManaging,
        notificationCenter: NotificationCenter = .default,
        criteriaFactory: @escaping CriteriaFactory = {
            AVDisplayCriteria(refreshRate: $0, formatDescription: $1)
        },
        displayLink: DisplayLinkControlling,
        readiness: DisplayReadinessControlling
    ) {
        self.manager = manager
        self.notificationCenter = notificationCenter
        self.criteriaFactory = criteriaFactory
        self.displayLink = displayLink
        self.readiness = readiness
    }

    public func enterFullScreen(
        formatDescription: CMFormatDescription,
        outputFrameRate: Float
    ) {
        guard outputFrameRate.isFinite, outputFrameRate > 0 else { return }
        if !isFullScreen {
            notificationCenter.addObserver(
                self,
                selector: #selector(modeSwitchStarted),
                name: .AVDisplayManagerModeSwitchStart,
                object: nil
            )
            notificationCenter.addObserver(
                self,
                selector: #selector(modeSwitchEnded),
                name: .AVDisplayManagerModeSwitchEnd,
                object: nil
            )
            isFullScreen = true
        }
        manager.preferredDisplayCriteria = criteriaFactory(outputFrameRate, formatDescription)
    }

    public func leaveFullScreen() {
        let wasSwitchingMode = isSwitchingMode
        if isFullScreen {
            notificationCenter.removeObserver(
                self,
                name: .AVDisplayManagerModeSwitchStart,
                object: nil
            )
            notificationCenter.removeObserver(
                self,
                name: .AVDisplayManagerModeSwitchEnd,
                object: nil
            )
        }
        isFullScreen = false
        isSwitchingMode = false
        displayLink.pause()
        if wasSwitchingMode {
            _ = readiness.reanchorAfterDisplayModeSwitch()
        }
        manager.preferredDisplayCriteria = nil
    }

    @objc private func modeSwitchStarted() {
        guard isFullScreen, !isSwitchingMode else { return }
        isSwitchingMode = true
        displayLink.pause()
        readiness.closeForDisplayModeSwitch()
    }

    @objc private func modeSwitchEnded() {
        guard isFullScreen, isSwitchingMode else { return }
        isSwitchingMode = false
        if readiness.reanchorAfterDisplayModeSwitch() {
            displayLink.resetPresentationTiming()
            displayLink.resume()
        }
    }
}
