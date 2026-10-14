// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import VPlayerCore
import VPlayerPlayback

struct IOSFullScreenPlayerView: View {
    @Bindable var session: IOSPlaybackSession
    @Bindable var library: AppModel
    let browsingSettings: ChannelBrowsingSettingsStore
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage
    @State private var panel: Panel?
    @State private var controls = IOSPlayerControlsVisibility()
    private enum Panel: String, Identifiable {
        case channels, programmes, more
        var id: String { rawValue }
    }
    private var model: FullScreenPlayerViewModel { session.model }
    private var allowsAutoHide: Bool {
        IOSPlayerControlsVisibility.allowsAutoHide(state: model.state,
            isPresentingSettings: panel != nil, isVoiceOverRunning: isVoiceOverRunning,
            isSceneActive: scenePhase == .active,
            hasPlaybackMessage: session.pictureInPicture.message != nil || model.playbackControlMessage != nil)
    }
    // Pin immediately when presentation conditions change, including before
    // onChange invalidates a previously scheduled timeout.
    private var areControlsVisible: Bool { controls.isVisible || !allowsAutoHide }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                IOSPlaybackHostView(session: session).ignoresSafeArea()
                // 背景手势与控件互为兄弟，暂停、换台和面板按钮不会同时触发隐藏。
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture { controls.backgroundTapped() }
                    .accessibilityHidden(true)
                centerControls
                if areControlsVisible {
                    VStack(spacing: 0) {
                        topControls
                        Spacer(minLength: 0)
                        programmeFooter(isCompact: geometry.size.width > geometry.size.height)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .statusBarHidden(!areControlsVisible)
        .background {
            IOSStatusBarAppearanceRefresh(isHidden: !areControlsVisible)
                .frame(width: 0, height: 0).accessibilityHidden(true)
        }
        // Preserve individual control labels/actions. VoiceOver pins the bars,
        // and its escape gesture remains an explicit, accessible close action.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-full-screen")
        .accessibilityAction(.escape) { close() }
        #if DEBUG
        .accessibilityValue(IOSPlaybackRouteDiagnostics.isEnabled ? "session=\(session.id.uuidString)" : "")
        .onAppear { IOSPlaybackRouteDiagnostics.record("cover-appeared") }
        .onDisappear { IOSPlaybackRouteDiagnostics.record("cover-disappeared") }
        #endif
        .task { session.start() }
        .task(id: controls.timeoutToken) {
            guard let token = controls.timeoutToken else { return }
            do { try await Task.sleep(for: IOSPlayerControlsVisibility.idleTimeout) }
            catch { return }
            guard !Task.isCancelled else { return }
            controls.timeoutCompleted(token)
        }
        .onChange(of: allowsAutoHide, initial: true) { _, allowed in
            controls.setAutoHideAllowed(allowed)
        }
        .onAppear { controls.setAutoHideAllowed(allowsAutoHide) }
        .onChange(of: model.state, initial: true) { _, _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
        .onDisappear {
            controls.setAutoHideAllowed(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .channels:
                IOSPlayerChannelPickerView(model: library, grouping: browsingSettings.grouping) { channel in
                    controls.userInteracted()
                    guard channel.id != session.presentation.request.channelID ||
                        channel.sourceProfileID != session.presentation.request.sourceProfileID else { return }
                    library.select(channel: channel)
                }
            case .programmes:
                IOSProgrammeGuideView(presentation: session.presentation)
            case .more:
                IOSPlayerMoreView(session: session, onDismiss: dismissPanel, onClose: close)
            }
        }
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button { close() } label: { controlIcon("chevron.left") }
                .accessibilityLabel("关闭播放").accessibilityIdentifier("player-back")
            Spacer(minLength: 0)
            Button {
                controls.userInteracted()
                session.pictureInPicture.start()
            } label: { controlIcon("pip.enter") }
                .disabled(!session.pictureInPicture.isPossible)
                .accessibilityLabel("画中画").accessibilityIdentifier("player-pip")
            Button { present(.more) } label: { controlIcon("ellipsis") }
                .accessibilityLabel("更多播放操作").accessibilityIdentifier("player-more")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .onTapGesture { controls.userInteracted() }
    }

    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3.weight(.medium))
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.10), in: Circle())
    }

    private var centerControls: some View {
        VStack(spacing: 16) {
            status
            if areControlsVisible, model.canControlPlayback {
                Button {
                    controls.userInteracted()
                    model.togglePause()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.title).frame(width: 72, height: 72)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(model.isPaused ? "播放" : "暂停")
                .accessibilityIdentifier("player-play-pause")
            }
        }
        .padding(24).foregroundStyle(.white)
    }

    private func programmeFooter(isCompact: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
            let programme = ChannelProgrammePresentation.resolve(programmes: session.presentation.programmes, at: tick.date)
            VStack(alignment: .leading, spacing: 10) {
                playbackMessages
                if isCompact {
                    HStack(alignment: .bottom, spacing: 24) {
                        programmeSummary(programme, isCompact: true)
                        footerActions
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    programmeSummary(programme, isCompact: false)
                    footerActions
                }
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            .contentShape(Rectangle())
            .onTapGesture { controls.userInteracted() }
        }
    }

    @ViewBuilder private var playbackMessages: some View {
        if let message = model.playbackControlMessage {
            Text(message).font(.caption).accessibilityIdentifier("player-control-message")
        }
        if let message = session.pictureInPicture.message {
            Text(message).font(.caption).accessibilityIdentifier("player-pip-message")
        }
    }

    private func programmeSummary(_ programme: ChannelProgrammePresentation, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.presentation.request.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(isCompact ? 1 : 2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("player.channel-name")
                mediaInformation
            }
            if let current = programme.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title).font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(isCompact ? 1 : 2)
                        .accessibilityIdentifier("player.current-programme")
                    HStack(spacing: 12) {
                        Text("\(current.start.formatted(date: .omitted, time: .shortened)) – \(current.stop.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: true, vertical: false)
                        if let progress = programme.progress, !isCompact {
                            ProgressView(value: progress).tint(.white.opacity(0.55))
                                .accessibilityLabel("节目播出进度")
                        }
                    }
                }
            }
            if let next = programme.next {
                Text("接下来 · \(next.title)").font(.caption).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).accessibilityIdentifier("player.next-programme")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var mediaInformation: some View {
        if model.mediaInformation?.isAudioOnly != true {
            let media = PlaybackMediaInformationPresentation(information: model.mediaInformation)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { mediaInformationItems(media) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { mediaInformationItems(media) }
            }
            .font(.footnote).monospacedDigit()
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(media.accessibilityText)
            .accessibilityIdentifier("player.media-status")
        }
    }

    @ViewBuilder private func mediaInformationItems(_ media: PlaybackMediaInformationPresentation) -> some View {
        if let resolution = media.visualResolutionText {
            Text(resolution)
        }
        if let frameRate = media.visualFrameRateText {
            if media.showsEnhancedFrameRateHighlight {
                Text(frameRate)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.2), in: Capsule())
            } else {
                Text(frameRate)
            }
        }
        if media.visualResolutionText == nil, media.visualFrameRateText == nil {
            Text(media.visualText)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button { present(.channels) } label: { footerAction("换台", symbol: "list.bullet") }
                .accessibilityIdentifier("player-channels")
            Button { present(.programmes) } label: { footerAction("节目单", symbol: "calendar") }
                .accessibilityIdentifier("player-programmes")
        }
    }

    private func footerAction(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(0.10), in: Capsule())
    }

    private func present(_ panel: Panel) {
        controls.userInteracted()
        self.panel = panel
    }

    private func dismissPanel() {
        controls.userInteracted()
        panel = nil
    }
    @ViewBuilder private var status: some View {
        if model.isPaused { EmptyView() }
        else {
            switch model.state {
            case .idle, .preparing: ProgressView("正在准备播放…").tint(.white)
            case .buffering: ProgressView("正在缓冲…").tint(.white)
            case .recovering: ProgressView("正在恢复播放…").tint(.white)
            case let .failed(failure):
                VStack(spacing: 16) {
                    Text(failure.userMessage)
                    if PlayerFailureActionPolicy.showsRetry(for: failure) {
                        Button("重试") {
                            controls.userInteracted()
                            model.retry()
                        }.accessibilityIdentifier("player-retry")
                    }
                }
                .padding(24).foregroundStyle(.white)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            case .playing, .paused, .stopped: EmptyView()
            }
        }
    }
    private func close() {
        session.close()
        onClose()
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active &&
            PlaybackIdleTimerPolicy.isDisabled(for: model.state)
    }
}

private struct IOSPlayerMoreView: View {
    let session: IOSPlaybackSession
    let onDismiss: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        informationView
                    } label: { Label("画面信息", systemImage: "info.circle") }
                    .accessibilityIdentifier("player-media-information")
                    NavigationLink {
                        settingsView
                    } label: { Label("播放设置", systemImage: "gearshape") }
                    .accessibilityIdentifier("player-settings")
                }
                Section {
                    Button("停止播放", role: .destructive, action: onClose)
                        .accessibilityIdentifier("player-stop")
                }
            }
            .navigationTitle("更多播放操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneButton(identifier: "player.more.done") }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var settingsView: some View {
        List {
            PlaybackSettingsSections(playback: session.settings)
            PlaybackSettingsResetSection(playback: session.settings)
        }
        .navigationTitle("播放设置")
        .toolbar { doneButton(identifier: "player.settings.done") }
    }

    private var informationView: some View {
        let presentation = PlaybackMediaInformationPresentation(information: session.model.mediaInformation)
        return List {
            Section("画面") {
                if session.model.mediaInformation?.isAudioOnly == true {
                    Text("仅音频，当前播放源没有视频画面。")
                } else {
                    Text(presentation.visualText.isEmpty ? "暂未取得画面信息" : presentation.visualText)
                        .accessibilityLabel(presentation.accessibilityText.isEmpty ? "暂未取得画面信息" : presentation.accessibilityText)
                }
            }
            if let output = presentation.airPlayOutputText {
                Section("输出") { Text(output) }
            }
        }
        .navigationTitle("画面信息")
        .toolbar { doneButton(identifier: "player.media.done") }
    }

    @ToolbarContentBuilder private func doneButton(identifier: String) -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("完成", action: onDismiss).accessibilityIdentifier(identifier)
        }
    }
}

/// Request UIKit's appearance pass after SwiftUI changes the status-bar
/// preference inside a full-screen presentation. Update only on visibility
/// transitions, rather than on playback model refreshes.
private struct IOSStatusBarAppearanceRefresh: UIViewRepresentable {
    let isHidden: Bool
    func makeUIView(context: Context) -> IOSStatusBarAppearanceRefreshView {
        let view = IOSStatusBarAppearanceRefreshView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: IOSStatusBarAppearanceRefreshView, context: Context) {
        view.requestAppearanceUpdate(isHidden: isHidden)
    }
}

private final class IOSStatusBarAppearanceRefreshView: UIView {
    private var lastHidden: Bool?
    func requestAppearanceUpdate(isHidden: Bool) {
        guard lastHidden != isHidden else { return }
        lastHidden = isHidden
        invalidateAppearance()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { invalidateAppearance() }
    }
    private func invalidateAppearance() {
        // Let SwiftUI finish propagating the preference before UIKit reads it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            // The nearest responder can be SwiftUI's containing controller;
            // the presented controller owns the full-screen status preference.
            var controller = self.window?.rootViewController
            while let current = controller {
                current.setNeedsStatusBarAppearanceUpdate()
                controller = current.presentedViewController
            }
        }
    }
}

/// iOS presentation-only state. The view owns a single cancellation-aware task;
/// its token also rejects late completions across hide/show and pinned periods.
/// Playback/session ownership and the tvOS visibility policy are independent.
struct IOSPlayerControlsVisibility: Equatable, Sendable {
    static let idleTimeout = Duration.seconds(3)
    private(set) var isVisible = true
    private var autoHideAllowed = false
    private var revision: UInt64 = 0
    var timeoutToken: UInt64? { autoHideAllowed && isVisible ? revision : nil }

    static func allowsAutoHide(state: PlaybackState, isPresentingSettings: Bool,
                              isVoiceOverRunning: Bool, isSceneActive: Bool,
                              hasPlaybackMessage: Bool) -> Bool {
        guard case .playing = state else { return false }
        return !isPresentingSettings && !isVoiceOverRunning && isSceneActive && !hasPlaybackMessage
    }

    mutating func setAutoHideAllowed(_ allowed: Bool) {
        guard autoHideAllowed != allowed else { return }
        autoHideAllowed = allowed
        isVisible = true
        revision &+= 1
    }

    mutating func backgroundTapped() {
        guard autoHideAllowed else { return }
        isVisible.toggle()
        revision &+= 1
    }

    mutating func userInteracted() {
        isVisible = true
        revision &+= 1
    }

    mutating func timeoutCompleted(_ token: UInt64) {
        guard timeoutToken == token else { return }
        isVisible = false
    }
}
