// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import Observation
import VPlayerPlayback

/// 使用公开 AppKit 窗口承载原视频视图，避开 macOS sample-buffer PiP 的镜像裁切。
@MainActor
@Observable
final class MacPictureInPictureCoordinator {
    typealias RestoreRequest = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var message: String?
    @ObservationIgnored var onStarted: (() -> Void)?
    @ObservationIgnored var onStopped: (() -> Void)?
    @ObservationIgnored var onRestore: RestoreRequest?
    @ObservationIgnored private weak var target: (any NowPlayingPlaybackTarget)?
    @ObservationIgnored private var videoView: NSView?
    @ObservationIgnored private weak var inlineSuperview: NSView?
    @ObservationIgnored private var inlineAutoresizing: NSView.AutoresizingMask = []
    @ObservationIgnored private var identity: PresentationIdentity?
    @ObservationIgnored private var panel: MacFloatingPlayerPanel?
    @ObservationIgnored private var content: MacFloatingPlayerContent?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPause: Bool?
    @ObservationIgnored private var requestedPause: Bool?
    @ObservationIgnored private var restoreGeneration = UUID()
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var playbackAvailable = false
    @ObservationIgnored private var paused = true
    @ObservationIgnored private let persistsWindowFrame: Bool

    init(target: any NowPlayingPlaybackTarget, persistsWindowFrame: Bool = true) {
        self.target = target
        self.persistsWindowFrame = persistsWindowFrame
    }

    func install(videoView: NSView, identity: PresentationIdentity) {
        guard !isClosed, self.identity != identity else { return }
        restoreVideoView()
        self.videoView = videoView
        self.identity = identity
        isPossible = playbackAvailable
        if isActive { moveVideoIntoPanel() }
    }

    func retire(identity: PresentationIdentity) {
        guard self.identity == identity else { return }
        restoreGeneration = UUID()
        transportTask?.cancel()
        pendingPause = nil
        restoreVideoView()
        videoView = nil
        self.identity = nil
        isPossible = false
        // 恢复或后端切换时保留浮窗，下一份有效输出在原窗口继续。
    }

    func update(state: PlaybackState, paused: Bool) {
        switch state {
        case .playing, .paused, .buffering, .recovering: playbackAvailable = true
        default: playbackAvailable = false
        }
        self.paused = paused
        isPossible = !isClosed && videoView != nil && playbackAvailable
        content?.update(paused: paused, available: playbackAvailable)
    }

    func start() {
        guard !isClosed, !isActive, isPossible, let videoView, videoView.superview != nil else {
            message = "画中画尚未就绪，请在画面开始播放后重试。"
            return
        }
        message = nil
        let screen = videoView.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: 480, height: 270)
        let frame = NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 24,
            width: size.width, height: size.height)
        let panel = MacFloatingPlayerPanel(contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "VPlayer 画中画"
        panel.identifier = .init("player.picture-in-picture")
        panel.setAccessibilityLabel("VPlayer 画中画")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentAspectRatio = .init(width: 16, height: 9)
        panel.contentMinSize = .init(width: 240, height: 135)
        panel.contentMaxSize = .init(width: min(960, visible.width), height: min(540, visible.height))
        if persistsWindowFrame { panel.setFrameAutosaveName("VPlayerPictureInPicture") }
        let origin = NSPoint(x: max(visible.minX, min(panel.frame.minX, visible.maxX - panel.frame.width)),
            y: max(visible.minY, min(panel.frame.minY, visible.maxY - panel.frame.height)))
        panel.setFrameOrigin(origin)
        let content = MacFloatingPlayerContent(frame: .init(origin: .zero, size: panel.contentLayoutRect.size))
        panel.onClose = { [weak self] in self?.stopWithoutRestoration() }
        content.onPause = { [weak self] in self?.togglePause() }
        content.onRestore = { [weak self] in self?.stopForRestoration() }
        content.onClose = { [weak self] in self?.stopWithoutRestoration() }
        content.update(paused: paused, available: playbackAvailable)
        panel.contentView = content
        self.content = content
        self.panel = panel
        isActive = true
        moveVideoIntoPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content)
        onStarted?()
    }

    private func moveVideoIntoPanel() {
        guard let videoView, let content else { return }
        inlineSuperview = videoView.superview
        inlineAutoresizing = videoView.autoresizingMask
        videoView.removeFromSuperview()
        content.mount(videoView)
    }

    private func restoreVideoView() {
        guard let videoView, let inlineSuperview else { return }
        content?.unmount(videoView)
        videoView.removeFromSuperview()
        videoView.autoresizingMask = inlineAutoresizing
        videoView.frame = inlineSuperview.bounds
        inlineSuperview.addSubview(videoView)
        videoView.layoutSubtreeIfNeeded()
        self.inlineSuperview = nil
    }

    func togglePause() {
        guard !isClosed, identity != nil, playbackAvailable else { return }
        pendingPause = !(pendingPause ?? requestedPause ?? paused)
        startTransportWorker()
    }

    private func startTransportWorker() {
        guard !isClosed, let identity, pendingPause != nil else { return }
        guard transportTask == nil else { return }
        transportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.transportTask = nil
                self.requestedPause = nil
                self.startTransportWorker()
            }
            while !Task.isCancelled, !self.isClosed, self.identity == identity, let paused = self.pendingPause {
                self.pendingPause = nil
                self.requestedPause = paused
                await self.target?.setPausedFromNowPlaying(paused)
            }
        }
    }

    func stopForRestoration() {
        guard !isClosed, isActive else { return }
        let generation = UUID()
        restoreGeneration = generation
        guard let onRestore else { finishPictureInPicture(); return }
        onRestore { [weak self] restored in
            guard let self, !self.isClosed, self.isActive, self.restoreGeneration == generation else { return }
            if restored { self.finishPictureInPicture() }
            else { self.message = "暂时无法打开主窗口，可以继续在画中画中播放。" }
        }
    }

    func stopWithoutRestoration() {
        guard !isClosed, isActive else { return }
        finishPictureInPicture()
        onStopped?()
    }

    private func finishPictureInPicture() {
        restoreGeneration = UUID()
        restoreVideoView()
        content?.cancelAutoHide()
        panel?.close()
        panel = nil
        content = nil
        isActive = false
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        transportTask?.cancel()
        pendingPause = nil
        finishPictureInPicture()
        videoView = nil
        identity = nil
        isPossible = false
    }

    #if DEBUG
    var floatingWindowForTesting: NSWindow? { panel }
    #endif
}

@MainActor
private final class MacFloatingPlayerPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { onClose?() }
}

@MainActor
private final class MacFloatingPlayerContent: NSView {
    var onPause: (() -> Void)?
    var onRestore: (() -> Void)?
    var onClose: (() -> Void)?
    private weak var videoView: NSView?
    private var tracking: NSTrackingArea?
    private var hideTask: Task<Void, Never>?
    private var paused = true
    private let pauseButton = NSButton()
    private let restoreButton = NSButton()
    private let closeButton = NSButton()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        configure(pauseButton, symbol: "pause.fill", label: "暂停", identifier: "pip.play-pause", action: #selector(pausePlayback))
        configure(restoreButton, symbol: "pip.exit", label: "返回播放窗口", identifier: "pip.restore", action: #selector(restorePlayback))
        configure(closeButton, symbol: "xmark", label: "关闭画中画", identifier: "pip.close", action: #selector(closePlayback))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, symbol: String, label: String, identifier: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        button.layer?.cornerRadius = 16
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.target = self
        button.action = action
        addSubview(button)
    }
    func mount(_ view: NSView) {
        videoView = view
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view, positioned: .below, relativeTo: nil)
        view.layoutSubtreeIfNeeded()
    }
    func unmount(_ view: NSView) {
        if videoView === view { videoView = nil }
    }
    override func layout() {
        super.layout()
        videoView?.frame = bounds
        closeButton.frame = .init(x: 10, y: 10, width: 32, height: 32)
        restoreButton.frame = .init(x: bounds.width - 42, y: 10, width: 32, height: 32)
        pauseButton.frame = .init(x: (bounds.width - 40) / 2, y: bounds.height - 50, width: 40, height: 40)
        pauseButton.layer?.cornerRadius = 20
    }
    func update(paused: Bool, available: Bool) {
        let changed = self.paused != paused
        self.paused = paused
        let label = paused ? "播放" : "暂停"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: label)
        pauseButton.setAccessibilityLabel(label)
        pauseButton.toolTip = label
        pauseButton.isEnabled = available
        if changed || hideTask == nil { revealControls() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }
    override func mouseEntered(with event: NSEvent) { revealControls() }
    override func mouseMoved(with event: NSEvent) { revealControls() }
    override func mouseExited(with event: NSEvent) { revealControls() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRestore?() }
        else { window?.performDrag(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let videoView, hit === videoView || hit?.isDescendant(of: videoView) == true { return self }
        return hit
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onPause?() }
        else if event.keyCode == 53 { onRestore?() }
        else { super.keyDown(with: event) }
    }
    private func revealControls() {
        cancelAutoHide()
        for button in [pauseButton, restoreButton, closeButton] { button.isHidden = false }
        guard !paused else { return }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            for button in [self.pauseButton, self.restoreButton, self.closeButton] { button.isHidden = true }
        }
    }
    func cancelAutoHide() { hideTask?.cancel(); hideTask = nil }
    @objc private func pausePlayback() { onPause?() }
    @objc private func restorePlayback() { onRestore?() }
    @objc private func closePlayback() { onClose?() }
}
