// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVKit
import SwiftUI
import AppKit
import VPlayerPlayback

@MainActor
class PlaybackPresentationHostController: NSViewController {
    private struct Mounted {
        let identified: IdentifiedPlaybackPresentation
        let child: NSViewController
    }

    static var fixedOwnershipStateBytes: Int {
        // mountedIdentity是Mounted的计算投影，不重复为未存储的identity收费。
        MemoryLayout<Mounted?>.stride
    }

    private var mounted: Mounted?
    var mountedIdentity: PresentationIdentity? { mounted?.identified.identity }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从编码器创建播放器宿主")
    }

    var onPresentationMounted: ((IdentifiedPlaybackPresentation, AVPlayerLayer?) -> Void)?
    var onPresentationUnmounted: ((PresentationIdentity) -> Void)?
    override func loadView() {
        view = NSView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    func replace(with presentation: IdentifiedPlaybackPresentation?) {
        if let current = mounted?.identified, let presentation,
           Self.samePresentation(current, presentation) {
            return
        }
        unmountCurrent()
        guard let presentation else { return }

        let child: NSViewController
        switch presentation.presentation {
        case let .sampleBuffer(context):
            child = NSViewController()
            child.view = context.makeVideoView()
        case let .avPlayer(context):
            child = makeAVPlayerChild(context: context)
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.width, .height]
        view.addSubview(child.view)
        mounted = Mounted(identified: presentation, child: child)
        didMount(presentation, child: child)
    }

    func makeAVPlayerChild(context: AVPlayerPresentationContext) -> NSViewController {
        let controller = NSViewController()
        let surface = MacAVPlayerSurface()
        context.attach(to: surface.playerLayer)
        controller.view = surface
        return controller
    }
    func detachAVPlayerChild(context: AVPlayerPresentationContext, child: NSViewController) {
        if let surface = child.view as? MacAVPlayerSurface { context.detach(from: surface.playerLayer) }
        else { context.detach() }
    }
    func didMount(_ presentation: IdentifiedPlaybackPresentation, child: NSViewController) {
        onPresentationMounted?(presentation, (child.view as? MacAVPlayerSurface)?.playerLayer)
    }
    func willUnmount(_ presentation: IdentifiedPlaybackPresentation, child: NSViewController) {
        onPresentationUnmounted?(presentation.identity)
    }

    private func unmountCurrent() {
        guard let current = mounted else { return }
        willUnmount(current.identified, child: current.child)
        switch current.identified.presentation {
        case let .sampleBuffer(context):
            context.detach()
        case let .avPlayer(context):
            detachAVPlayerChild(context: context, child: current.child)
        }
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

@MainActor
private final class MacAVPlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
