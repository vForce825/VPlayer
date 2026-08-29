// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import UIKit

@MainActor
public final class SampleBufferVideoView: UIView {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let displayLayer = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("SampleBufferVideoView requires AVSampleBufferDisplayLayer")
        }
        return displayLayer
    }

    var videoRenderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }

    var windowDidChange: ((UIWindow?) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        windowDidChange?(window)
    }
}
