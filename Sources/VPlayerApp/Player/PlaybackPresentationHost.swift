// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVKit
import SwiftUI
import UIKit
import VPlayerPlayback

@MainActor
final class PlaybackPresentationHostController: UIViewController {
    typealias AVPlayerControllerFactory = @MainActor () -> AVPlayerViewController

    private struct Mounted {
        let identified: IdentifiedPlaybackPresentation
        let child: UIViewController
    }

    static var fixedOwnershipStateBytes: Int {
        // mountedIdentity是Mounted的计算投影，不重复为未存储的identity收费。
        MemoryLayout<Mounted?>.stride
    }

    private let avPlayerControllerFactory: AVPlayerControllerFactory
    private var mounted: Mounted?
    var mountedIdentity: PresentationIdentity? { mounted?.identified.identity }

    init(
        avPlayerControllerFactory: @escaping AVPlayerControllerFactory = AVPlayerViewController.init
    ) {
        self.avPlayerControllerFactory = avPlayerControllerFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从编码器创建播放器宿主")
    }

    func replace(with presentation: IdentifiedPlaybackPresentation?) {
        if let current = mounted?.identified, let presentation,
           Self.samePresentation(current, presentation) {
            return
        }
        unmountCurrent()
        guard let presentation else { return }

        let child: UIViewController
        switch presentation.presentation {
        case let .sampleBuffer(context):
            child = UIViewController()
            child.view = context.makeVideoView()
        case let .avPlayer(context):
            let playerController = avPlayerControllerFactory()
            context.attach(to: playerController)
            child = playerController
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        mounted = Mounted(identified: presentation, child: child)
    }

    private func unmountCurrent() {
        guard let current = mounted else { return }
        switch current.identified.presentation {
        case let .sampleBuffer(context):
            context.detach()
        case let .avPlayer(context):
            if let controller = current.child as? AVPlayerViewController {
                context.detach(from: controller)
                controller.player = nil
            } else {
                context.detach()
            }
        }
        current.child.willMove(toParent: nil)
        current.child.view.removeFromSuperview()
        current.child.removeFromParent()
        mounted = nil
    }

    private static func samePresentation(
        _ lhs: IdentifiedPlaybackPresentation,
        _ rhs: IdentifiedPlaybackPresentation
    ) -> Bool {
        guard lhs.identity == rhs.identity else { return false }
        switch (lhs.presentation, rhs.presentation) {
        case let (.sampleBuffer(left), .sampleBuffer(right)):
            return left === right
        case let (.avPlayer(left), .avPlayer(right)):
            return left === right
        default:
            return false
        }
    }
}

@MainActor
final class PlaybackPresentationHostMount: PlaybackPresentationMounting {
    private weak var host: PlaybackPresentationHostController?
    private var desired: IdentifiedPlaybackPresentation?

    func connect(to nextHost: PlaybackPresentationHostController) {
        guard host !== nextHost else { return }
        host?.replace(with: nil)
        host = nextHost
        nextHost.replace(with: desired)
    }

    func disconnect(from expectedHost: PlaybackPresentationHostController) {
        guard host === expectedHost else { return }
        expectedHost.replace(with: nil)
        host = nil
    }

    func attach(_ presentation: IdentifiedPlaybackPresentation) {
        desired = presentation
        host?.replace(with: presentation)
    }

    func detach(_ presentation: IdentifiedPlaybackPresentation) {
        guard let desired, Self.samePresentation(desired, presentation) else { return }
        host?.replace(with: nil)
        self.desired = nil
    }

    func detachAll() {
        host?.replace(with: nil)
        desired = nil
    }

    private static func samePresentation(
        _ lhs: IdentifiedPlaybackPresentation,
        _ rhs: IdentifiedPlaybackPresentation
    ) -> Bool {
        guard lhs.identity == rhs.identity else { return false }
        switch (lhs.presentation, rhs.presentation) {
        case let (.sampleBuffer(left), .sampleBuffer(right)):
            return left === right
        case let (.avPlayer(left), .avPlayer(right)):
            return left === right
        default:
            return false
        }
    }
}

struct PlaybackPresentationHostView: UIViewControllerRepresentable {
    let mount: PlaybackPresentationHostMount

    typealias Coordinator = PlaybackPresentationHostMount

    func makeCoordinator() -> Coordinator {
        mount
    }

    func makeUIViewController(context _: Context) -> PlaybackPresentationHostController {
        let host = PlaybackPresentationHostController()
        mount.connect(to: host)
        return host
    }

    func updateUIViewController(
        _ controller: PlaybackPresentationHostController,
        context _: Context
    ) {
        mount.connect(to: controller)
    }

    static func dismantleUIViewController(
        _ controller: PlaybackPresentationHostController,
        coordinator: Coordinator
    ) {
        coordinator.disconnect(from: controller)
    }
}
