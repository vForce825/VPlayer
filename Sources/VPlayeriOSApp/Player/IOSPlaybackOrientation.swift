// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import os
import Observation
import VPlayerPlayback

@MainActor
@Observable
final class IOSActivePlaybackSessionBox {
    var session: IOSPlaybackSession?
}

@MainActor
final class IOSApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = IOSWindowSceneDelegate.self
        return configuration
    }
}

/// 方向限制属于当前窗口的全屏播放，画中画、关闭播放和其他窗口不继承限制。
@MainActor
final class IOSWindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    // SwiftUI 使用自己的场景代理转发回调，scene.delegate 并非本实例。
    private static let delegates = NSMapTable<UIWindowScene, IOSWindowSceneDelegate>.weakToWeakObjects()
    private var owner: UUID?
    private var forceLandscape = false
    private var priorOrientation: UIInterfaceOrientation?
    private var orientationRevision: UInt64 = 0
    private var observationRevision: UInt64 = 0
    private weak var playback: PlaybackSettingsStore?
    private weak var sessionBox: IOSActivePlaybackSessionBox?
    private weak var boundWindow: UIWindow?
    private static let logger = Logger(subsystem: "com.vforce.vplayer", category: "播放方向")

    static func delegate(for scene: UIWindowScene?) -> IOSWindowSceneDelegate? {
        guard let scene else { return nil }
        return delegates.object(forKey: scene)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Self.delegates.setObject(self, forKey: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let windowScene = scene as? UIWindowScene { Self.delegates.removeObject(forKey: windowScene) }
        forceLandscape = false
        priorOrientation = nil
        owner = nil
        orientationRevision &+= 1
        observationRevision &+= 1
        playback = nil
        sessionBox = nil
        boundWindow = nil
    }

    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        forceLandscape ? .landscape : .allButUpsideDown
    }

    func bind(owner: UUID, playback: PlaybackSettingsStore, sessionBox: IOSActivePlaybackSessionBox, window: UIWindow) {
        guard self.owner != owner || self.playback !== playback || self.sessionBox !== sessionBox || boundWindow !== window else {
            return
        }
        self.owner = owner
        self.playback = playback
        self.sessionBox = sessionBox
        boundWindow = window
        observationRevision &+= 1
        observePreference()
    }

    private func observePreference() {
        let revision = observationRevision
        let forceLandscape = withObservationTracking {
            let activeSession = sessionBox?.session
            return playback?.forceLandscapePlayback == true &&
                activeSession?.isFullScreenPresented == true && activeSession?.isClosing == false
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationRevision == revision else { return }
                self.observePreference()
            }
        }
        guard let window = boundWindow else { return }
        setForceLandscape(forceLandscape, window: window)
    }

    private func setForceLandscape(_ forceLandscape: Bool, window: UIWindow) {
        guard self.forceLandscape != forceLandscape else { return }
        #if DEBUG
        IOSPlaybackRouteDiagnostics.record("orientation-force:\(forceLandscape)")
        #endif
        if forceLandscape {
            priorOrientation = window.windowScene?.effectiveGeometry.interfaceOrientation
        }
        self.forceLandscape = forceLandscape
        let target = forceLandscape ? UIInterfaceOrientationMask.landscape : restoredOrientation
        if !forceLandscape {
            priorOrientation = nil
        }
        requestOrientation(target, in: window)
    }

    func release(owner: UUID, window: UIWindow) {
        guard self.owner == owner else { return }
        observationRevision &+= 1
        playback = nil
        sessionBox = nil
        boundWindow = nil
        setForceLandscape(false, window: window)
        self.owner = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard forceLandscape, let window = (scene as? UIWindowScene)?.keyWindow else { return }
        requestOrientation(.landscape, in: window)
    }

    /// 退出强制横屏时优先恢复进入播放前的界面方向，避免系统开启竖排方向锁定时
    /// 被横向握持的硬件陀螺仪方向锁死在横屏。
    static func restoredOrientationMask(for priorOrientation: UIInterfaceOrientation?) -> UIInterfaceOrientationMask {
        switch priorOrientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portrait, .portraitUpsideDown, .unknown, nil: return .portrait
        @unknown default: return .portrait
        }
    }

    private var restoredOrientation: UIInterfaceOrientationMask {
        Self.restoredOrientationMask(for: priorOrientation)
    }

    private func requestOrientation(_ target: UIInterfaceOrientationMask, in window: UIWindow) {
        orientationRevision &+= 1
        let revision = orientationRevision
        // 呈现、换台和退出动画完成后，UIKit 才能读取新的方向范围。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyOrientation(target, in: window, revision: revision, attemptsRemaining: 4)
        }
    }

    private func applyOrientation(_ target: UIInterfaceOrientationMask, in window: UIWindow,
                                  revision: UInt64, attemptsRemaining: Int) {
        guard orientationRevision == revision, let scene = window.windowScene else { return }
        var controller = window.rootViewController
        var transition: (any UIViewControllerTransitionCoordinator)?
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            if let coordinator = current.transitionCoordinator { transition = coordinator }
            controller = current.presentedViewController
        }
        if let transition, transition.animate(alongsideTransition: nil, completion: { [weak self, weak window] _ in
            DispatchQueue.main.async {
                guard let self, let window else { return }
                self.applyOrientation(target, in: window, revision: revision, attemptsRemaining: attemptsRemaining)
            }
        }) { return }
        let mask = forceLandscape ? UIInterfaceOrientationMask.landscape : target
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self, weak window] error in
            guard let self, self.orientationRevision == revision, let window else { return }
            // SwiftUI 的控制器可能在退出动画后下一轮才更新方向缓存；只重试当前请求。
            if attemptsRemaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    self.applyOrientation(target, in: window, revision: revision, attemptsRemaining: attemptsRemaining - 1)
                }
            } else {
                Self.logger.error("无法调整播放方向：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// 挂载在全屏播放器外层（`.id(active.id)` 之外），换台时保持方向偏好与退出前方向连续，
/// 不在会话切换间隙释放方向限制。
struct IOSPlaybackOrientationPreference: UIViewRepresentable {
    let playback: PlaybackSettingsStore
    let sessionBox: IOSActivePlaybackSessionBox

    func makeUIView(context: Context) -> IOSPlaybackOrientationView { IOSPlaybackOrientationView() }
    func updateUIView(_ view: IOSPlaybackOrientationView, context: Context) {
        view.update(playback: playback, sessionBox: sessionBox)
    }
    static func dismantleUIView(_ view: IOSPlaybackOrientationView, coordinator: ()) { view.detach() }
}

final class IOSPlaybackOrientationView: UIView {
    private let owner = UUID()
    private weak var playback: PlaybackSettingsStore?
    private weak var sessionBox: IOSActivePlaybackSessionBox?
    private weak var attachedWindow: UIWindow?

    func update(playback: PlaybackSettingsStore, sessionBox: IOSActivePlaybackSessionBox) {
        self.playback = playback
        self.sessionBox = sessionBox
        applyPreference()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 面板或画中画过渡可能暂时移除 UIKit 视图，保留窗口连接直到实际拆除。
        if window != nil { applyPreference() }
    }
    func detach() {
        if let window = attachedWindow {
            IOSWindowSceneDelegate.delegate(for: window.windowScene)?.release(owner: owner, window: window)
        }
        attachedWindow = nil
    }
    private func applyPreference() {
        if let window, attachedWindow !== window {
            detach()
            attachedWindow = window
        }
        guard let window = attachedWindow, let playback, let sessionBox else { return }
        IOSWindowSceneDelegate.delegate(for: window.windowScene)?
            .bind(owner: owner, playback: playback, sessionBox: sessionBox, window: window)
    }
}
