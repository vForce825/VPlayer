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
        case .avPlayer:
            guard let view = child.view as? IOSAVPlayerLayerView else { return }
            pictureInPicture?.install(playerLayer: view.playerLayer, identity: presentation.identity)
        }
    }
    override func willUnmount(_ presentation: IdentifiedPlaybackPresentation, child: UIViewController) {
        pictureInPicture?.retire(identity: presentation.identity)
    }
}

struct IOSPlaybackHostView: UIViewControllerRepresentable {
    let session: IOSPlaybackSession
    func makeUIViewController(context: Context) -> IOSPlaybackHostController {
        session.mount.connect(to: session.host)
        return session.host
    }
    func updateUIViewController(_ controller: IOSPlaybackHostController, context: Context) {
        session.mount.connect(to: controller)
    }
    static func dismantleUIViewController(_ controller: IOSPlaybackHostController, coordinator: ()) {
        // The root session owns this host while PiP minimizes the SwiftUI view.
        // Explicit session close / accepted presentation replacement detaches it.
    }
}
