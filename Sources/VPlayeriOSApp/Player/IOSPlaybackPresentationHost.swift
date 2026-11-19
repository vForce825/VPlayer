// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import SwiftUI
import UIKit
import VPlayerPlayback

@MainActor
private final class IOSAVPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else { preconditionFailure("AVPlayerLayer required") }
        return layer
    }
}

@MainActor
final class IOSPlaybackHostController: PlaybackPresentationHostController {
    private weak var pictureInPicture: IOSPictureInPictureCoordinator?
    init(pictureInPicture: IOSPictureInPictureCoordinator) {
        self.pictureInPicture = pictureInPicture
        super.init()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Coder initialization is unavailable") }
    override func makeAVPlayerChild(context: AVPlayerPresentationContext) -> UIViewController {
        let controller = UIViewController()
        let playerView = IOSAVPlayerLayerView()
        playerView.backgroundColor = .black
        playerView.playerLayer.videoGravity = .resizeAspect
        context.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        context.attach(to: playerView.playerLayer)
        controller.view = playerView
        return controller
    }
    override func didMount(_ presentation: IdentifiedPlaybackPresentation, child: UIViewController) {
        switch presentation.presentation {
        case .sampleBuffer:
            guard let layer = child.view.layer as? AVSampleBufferDisplayLayer else { return }
            pictureInPicture?.install(sampleBufferDisplayLayer: layer, identity: presentation.identity)
        case let .avPlayer(context):
            guard let view = child.view as? IOSAVPlayerLayerView else { return }
            let identity = presentation.identity
            guard context.setPictureInPictureTransportHandler({ [weak pictureInPicture] paused in
                pictureInPicture?.requestPlayerTransport(paused: paused, identity: identity)
            }, for: view.playerLayer) else { return }
            pictureInPicture?.install(playerLayer: view.playerLayer, identity: identity)
        }
    }
    override func detachAVPlayerChild(context: AVPlayerPresentationContext, child: UIViewController) {
        guard let view = child.view as? IOSAVPlayerLayerView else { return }
        context.detach(from: view.playerLayer)
    }
    override func willUnmount(_ presentation: IdentifiedPlaybackPresentation, child: UIViewController) {
        if case let .avPlayer(context) = presentation.presentation,
           let view = child.view as? IOSAVPlayerLayerView {
            _ = context.setPictureInPictureTransportHandler(nil, for: view.playerLayer)
        }
        pictureInPicture?.retire(identity: presentation.identity)
    }
}

@MainActor
final class IOSPlaybackHostContainerController: UIViewController {
    private(set) weak var session: IOSPlaybackSession?
    private var mountGeneration: UInt64 = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    func attach(session: IOSPlaybackSession) {
        if let previousSession = self.session, previousSession !== session {
            detachIfOwned()
        }
        let host = session.host
        self.session = session
        session.mount.connect(to: host)
        if host.parent !== self {
            if let previousParent = host.parent {
                host.willMove(toParent: nil)
                host.viewIfLoaded?.removeFromSuperview()
                host.removeFromParent()
                if let previousContainer = previousParent as? IOSPlaybackHostContainerController {
                    previousContainer.noteHostTransferred()
                }
            }
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
            mountGeneration = session.noteHostMounted(in: self)
        } else if host.view.superview !== view {
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
        }
    }

    private func noteHostTransferred() {
        mountGeneration = 0
    }

    func detachIfOwned() {
        guard let session else { return }
        let host = session.host
        guard host.parent === self else { return }
        host.willMove(toParent: nil)
        host.viewIfLoaded?.removeFromSuperview()
        host.removeFromParent()
        session.noteHostUnmounted(generation: mountGeneration)
        mountGeneration = 0
    }
}

struct IOSPlaybackHostView: UIViewControllerRepresentable {
    let session: IOSPlaybackSession
    func makeUIViewController(context: Context) -> IOSPlaybackHostContainerController {
        let container = IOSPlaybackHostContainerController()
        container.attach(session: session)
        return container
    }
    func updateUIViewController(_ controller: IOSPlaybackHostContainerController, context: Context) {
        controller.attach(session: session)
    }
    static func dismantleUIViewController(_ controller: IOSPlaybackHostContainerController, coordinator: ()) {
        // The root session owns `session.host` while PiP minimizes the SwiftUI cover.
        // Detach only from this container if it still owns `session.host`, never
        // disconnecting `session.mount` or stripping a newer cover's view.
        controller.detachIfOwned()
    }
}
