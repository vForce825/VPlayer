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
    @ObservationIgnored private var messageDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPause: Bool?
    @ObservationIgnored private var requestedPause: Bool?
    @ObservationIgnored private var restoreGeneration = UUID()
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var playbackAvailable = false
    @ObservationIgnored private var paused = true
    @ObservationIgnored private var failureMessage: String?
    @ObservationIgnored private let persistsWindowFrame: Bool
    @ObservationIgnored private let messageDuration: Duration

    init(
        target: any NowPlayingPlaybackTarget,
        persistsWindowFrame: Bool = true,
        messageDuration: Duration = .seconds(4)
    ) {
        self.target = target
        self.persistsWindowFrame = persistsWindowFrame
        self.messageDuration = messageDuration
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
        isRestoring = false
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
        case .playing, .paused, .buffering, .recovering:
            playbackAvailable = true
            failureMessage = nil
        case .failed(let failure):
            playbackAvailable = false
            failureMessage = failure.userMessage
        default:
            playbackAvailable = false
            failureMessage = nil
        }
        self.paused = paused
        isPossible = !isClosed && videoView != nil && playbackAvailable
        content?.update(paused: paused, available: playbackAvailable, failureMessage: failureMessage)
        if case .failed = state, isActive, !isRestoring {
            stopForRestoration()
        }
    }

    func start() {
        guard !isClosed, !isActive, isPossible, let videoView, videoView.superview != nil else {
            showMessage("画中画尚未就绪，请在画面开始播放后重试。")
            return
        }
        clearMessage()
        let screen = videoView.window?.screen ?? NSScreen.main
        let fallbackVisible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: 480, height: 270)
        let frame = NSRect(x: fallbackVisible.maxX - size.width - 24, y: fallbackVisible.minY + 24,
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
        if persistsWindowFrame { panel.setFrameAutosaveName("VPlayerPictureInPicture") }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let targetVisible = Self.targetVisibleFrame(
            for: panel.frame,
            screens: screens,
            fallbackVisibleFrame: fallbackVisible
        )
        panel.contentMaxSize = .init(width: min(960, targetVisible.width), height: min(540, targetVisible.height))
        let clamped = Self.clampedFrame(panel.frame, within: targetVisible)
        if clamped.size != panel.frame.size {
            panel.setFrame(clamped, display: false)
        } else {
            panel.setFrameOrigin(clamped.origin)
        }
        let content = MacFloatingPlayerContent(frame: .init(origin: .zero, size: panel.contentLayoutRect.size))
        panel.onClose = { [weak self] in self?.stopWithoutRestoration() }
        content.onPause = { [weak self] in self?.togglePause() }
        content.onRestore = { [weak self] in self?.stopForRestoration() }
        content.onClose = { [weak self] in self?.stopWithoutRestoration() }
        content.update(paused: paused, available: playbackAvailable, failureMessage: failureMessage)
        content.updateMessage(message)
        panel.contentView = content
        self.content = content
        self.panel = panel
        isActive = true
        moveVideoIntoPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content)
        onStarted?()
    }

    static func targetVisibleFrame(
        for frame: NSRect,
        screens: [NSRect],
        fallbackVisibleFrame: NSRect
    ) -> NSRect {
        var bestScreen: NSRect?
        var bestArea: CGFloat = 0
        for candidate in screens {
            let overlap = candidate.intersection(frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestScreen = candidate
            }
        }
        return bestScreen ?? fallbackVisibleFrame
    }

    static func clampedFrame(_ frame: NSRect, within visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = max(visible.minX, min(frame.minX, visible.maxX - width))
        let y = max(visible.minY, min(frame.minY, visible.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func clampedFrame(
        _ frame: NSRect,
        screens: [NSRect],
        fallbackVisibleFrame: NSRect
    ) -> NSRect {
        let target = targetVisibleFrame(
            for: frame,
            screens: screens,
            fallbackVisibleFrame: fallbackVisibleFrame
        )
        return clampedFrame(frame, within: target)
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
        guard !isClosed, isActive, !isRestoring else { return }
        isRestoring = true
        let generation = UUID()
        restoreGeneration = generation
        guard let onRestore else { finishPictureInPicture(); return }
        onRestore { [weak self] restored in
            guard let self, !self.isClosed, self.isActive, self.restoreGeneration == generation else { return }
            self.isRestoring = false
            if restored {
                self.finishPictureInPicture()
            } else {
                let fallback = self.failureMessage != nil
                    ? "播放失败，暂时无法打开主窗口。"
                    : "暂时无法打开主窗口，可以继续在画中画中播放。"
                self.showMessage(fallback)
            }
        }
    }

    func stopWithoutRestoration() {
        guard !isClosed, isActive else { return }
        finishPictureInPicture()
        onStopped?()
    }

    private func finishPictureInPicture() {
        restoreGeneration = UUID()
        isRestoring = false
        clearMessage()
        restoreVideoView()
        content?.cancelAutoHide()
        panel?.close()
        panel = nil
        content = nil
        isActive = false
    }

    private func showMessage(_ text: String) {
        messageDismissTask?.cancel()
        message = text
        content?.updateMessage(text)
        let duration = messageDuration
        messageDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.clearMessage()
        }
    }

    func clearMessage() {
        messageDismissTask?.cancel()
        messageDismissTask = nil
        message = nil
        content?.updateMessage(nil)
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
    var displayedFloatingMessageForTesting: String? { content?.displayedMessageForTesting }
    var controlsHiddenForTesting: Bool { content?.controlsHiddenForTesting ?? true }
    func simulateMouseExitedForTesting() { content?.simulateMouseExitedForTesting() }
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
    private var failureMessage: String?
    private var toastMessage: String?
    private let pauseButton = NSButton()
    private let restoreButton = NSButton()
    private let closeButton = NSButton()
    private let statusContainer = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
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
        configureStatusBanner()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureStatusBanner() {
        statusContainer.wantsLayer = true
        statusContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        statusContainer.layer?.cornerRadius = 10
        statusContainer.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byTruncatingTail
        statusContainer.addSubview(statusLabel)
        addSubview(statusContainer)
    }

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
        layoutStatusBanner()
    }
    private func layoutStatusBanner() {
        guard !statusContainer.isHidden else { return }
        let horizontalInset: CGFloat = 16
        let maxTextWidth = max(120, bounds.width - horizontalInset * 2 - 20)
        let measured = statusLabel.sizeThatFits(NSSize(width: maxTextWidth, height: 72))
        let containerWidth = min(bounds.width - horizontalInset * 2, measured.width + 20)
        let containerHeight = min(72, measured.height + 14)
        let y = max(48, (bounds.height - containerHeight) / 2)
        statusContainer.frame = NSRect(
            x: (bounds.width - containerWidth) / 2,
            y: y,
            width: containerWidth,
            height: containerHeight
        )
        statusLabel.frame = NSRect(
            x: 10,
            y: 7,
            width: containerWidth - 20,
            height: containerHeight - 14
        )
    }
    func update(paused: Bool, available: Bool, failureMessage: String?) {
        let changed = self.paused != paused || self.failureMessage != failureMessage
        self.paused = paused
        self.failureMessage = failureMessage
        let label = paused ? "播放" : "暂停"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: label)
        pauseButton.setAccessibilityLabel(label)
        pauseButton.toolTip = label
        pauseButton.isEnabled = available
        refreshStatusBanner()
        if changed || hideTask == nil { revealControls() }
    }
    func updateMessage(_ message: String?) {
        toastMessage = message
        refreshStatusBanner()
    }
    private func refreshStatusBanner() {
        let text = failureMessage ?? toastMessage
        if let text, !text.isEmpty {
            statusLabel.stringValue = text
            statusContainer.isHidden = false
            layoutStatusBanner()
        } else {
            statusLabel.stringValue = ""
            statusContainer.isHidden = true
        }
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
    override func mouseExited(with event: NSEvent) { hideControlsIfAllowed() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRestore?() }
        else { window?.performDrag(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let videoView, hit === videoView || hit?.isDescendant(of: videoView) == true { return self }
        if hit === statusContainer || hit === statusLabel { return self }
        return hit
    }
    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 49, !event.isARepeat { onPause?() }
        else if event.keyCode == 53, !event.isARepeat { onRestore?() }
        else { super.keyDown(with: event) }
    }
    private func revealControls() {
        cancelAutoHide()
        for button in [pauseButton, restoreButton, closeButton] { button.isHidden = false }
        guard !paused, failureMessage == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !self.paused, self.failureMessage == nil else { return }
            for button in [self.pauseButton, self.restoreButton, self.closeButton] { button.isHidden = true }
        }
    }
    private func hideControlsIfAllowed() {
        cancelAutoHide()
        guard !paused, failureMessage == nil else { return }
        for button in [pauseButton, restoreButton, closeButton] { button.isHidden = true }
    }
    func cancelAutoHide() { hideTask?.cancel(); hideTask = nil }
    @objc private func pausePlayback() { onPause?() }
    @objc private func restorePlayback() { onRestore?() }
    @objc private func closePlayback() { onClose?() }

    #if DEBUG
    var displayedMessageForTesting: String? { statusContainer.isHidden ? nil : statusLabel.stringValue }
    var controlsHiddenForTesting: Bool {
        pauseButton.isHidden && restoreButton.isHidden && closeButton.isHidden
    }
    func simulateMouseExitedForTesting() { hideControlsIfAllowed() }
    #endif
}
