// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
#if os(macOS)
import AppKit

@MainActor
public final class SampleBufferVideoView: NSView {
    private let sampleLayer = AVSampleBufferDisplayLayer()
    var displayLayer: AVSampleBufferDisplayLayer { sampleLayer }
    public var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer { displayLayer }
    var videoRenderer: AVSampleBufferVideoRenderer { sampleLayer.sampleBufferRenderer }
    var windowDidChange: ((NSWindow?) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        sampleLayer.backgroundColor = NSColor.black.cgColor
        sampleLayer.videoGravity = .resizeAspect
        // AppKit 管理宿主图层；视频使用独立子图层，避免其坐标变换进入画中画。
        layer?.addSublayer(sampleLayer)
        updateVideoGeometry()
    }
    public override var wantsUpdateLayer: Bool { true }
    public override func layout() {
        super.layout()
        updateVideoGeometry()
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVideoGeometry()
    }
    private func updateVideoGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleLayer.frame = bounds
        sampleLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateVideoGeometry()
        windowDidChange?(window)
    }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateVideoGeometry()
    }
}
#else
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

    public var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer { displayLayer }
    var videoRenderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }

    var windowDidChange: ((UIWindow?) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        #if os(tvOS)
        // 输出模式匹配与视频层的动态范围是独立设置。即使用户固定 HDR 输出，
        // 也应允许视频层使用 HDR；默认的 standard 会把内容限制到 SDR。
        // 保留系统自动色调映射，让系统根据当前输出能力处理 HLG/PQ/SDR。
        displayLayer.preferredDynamicRange = .high
        #endif
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

#endif
