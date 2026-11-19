// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import SwiftUI
import VPlayerCore
import VPlayerPlayback

struct MacPlayerView: View {
    let session: MacPlaybackSession
    @Bindable var state: MacApplicationState
    let settings: PlaybackSettingsStore
    var hasActiveRootSheet = false
    private var overlay: MacPlayerOverlayState { session.overlay }
    @State private var showsSettings = false
    @FocusState private var playerFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                MacPlaybackHostView(session: session)
                    .accessibilityIdentifier("player.surface")
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { playerFocused = true; state.toggleFullScreen(); reveal() }
                    .onTapGesture { playerFocused = true; reveal() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("播放画面")
                    .accessibilityIdentifier("player.interaction-surface")
                if session.pictureInPicture.isActive {
                    pictureInPicturePlaceholder
                } else {
                    stateOverlay
                }
                if overlay.informationVisible {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            MacChannelInformationOverlay(presentation: session.presentation,
                                mediaInformation: session.model.mediaInformation) {
                                overlay.toggleInformation(paused: session.model.isPaused)
                            }.frame(width: min(360, geometry.size.width - 32))
                        }
                        Spacer()
                    }.padding(16).transition(.opacity)
                }
                if overlay.controlsVisible {
                    VStack {
                        Spacer()
                        controls
                    }.padding(.leading, overlay.sidebarVisible ? state.sidebar.width + 8 : 0)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 180).allowsHitTesting(false)
                    }.transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .focusable().focusEffectDisabled().focused($playerFocused)
            .onContinuousHover { phase in
                if case .active = phase { overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused) }
            }
            .onKeyPress(.space) { session.model.togglePause(); reveal(); return .handled }
            .onKeyPress("i") { overlay.toggleInformation(paused: session.model.isPaused); return .handled }
            .onKeyPress("e") { state.showsProgrammes = true; return .handled }
            .onKeyPress("l") { overlay.toggleSidebar(paused: session.model.isPaused); return .handled }
            .animation(.easeInOut(duration: 0.2), value: overlay.controlsVisible)
            .animation(.easeInOut(duration: 0.2), value: overlay.informationVisible)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            if !overlay.sidebarVisible { playerFocused = true }
            reveal()
        }
        .onDisappear { overlay.cancel() }
        .onChange(of: session.model.isPaused) { _, _ in reveal() }
        .onChange(of: session.model.hasStoppedCurrentRequest) { _, stopped in
            if stopped { Task { await state.stopPlayback(requestID: session.model.request.id) } }
        }
        .onChange(of: overlay.sidebarVisible) { wasVisible, isVisible in
            if wasVisible, !isVisible { playerFocused = true }
        }
        .onChange(of: hasActiveRootSheet) { wasShown, isShown in
            if wasShown, !isShown { playerFocused = true }
        }
        .sheet(isPresented: $state.showsProgrammes) {
            MacProgrammeGuideView(presentation: session.presentation)
        }
        .sheet(isPresented: $showsSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("播放设置").font(.title2.bold())
                MacPlaybackSettingsForm(settings: settings)
                HStack { Spacer(); Button("完成") { showsSettings = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 460)
        }
        .onChange(of: state.showsProgrammes) { wasShown, isShown in
            updateHold()
            if wasShown, !isShown { playerFocused = true }
        }
        .onChange(of: showsSettings) { wasShown, isShown in
            updateHold()
            if wasShown, !isShown { playerFocused = true }
        }
        .overlay(alignment: .topLeading) {
            if let message = session.pictureInPicture.message {
                Text(message).font(.caption).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(16)
                    .padding(.leading, overlay.sidebarVisible ? state.sidebar.width + 8 : 0)
            }
        }
    }
    private func reveal() { overlay.interact(paused: session.model.isPaused) }
    private func updateHold() { overlay.holdsControlsOpen = state.showsProgrammes || showsSettings; reveal() }
    private var pictureInPicturePlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 44))
            Text("正在画中画中播放").font(.headline)
            if let status = pictureInPictureStatusText {
                HStack(spacing: 8) {
                    if !session.model.isPaused { ProgressView().controlSize(.small) }
                    Text(status).font(.callout)
                }
            }
            Button("返回播放窗口") { session.pictureInPicture.stopForRestoration() }
        }
        .foregroundStyle(.secondary)
        .padding(24)
    }
    private var pictureInPictureStatusText: String? {
        if session.isClosing { return nil }
        if session.model.isPaused { return "已暂停" }
        switch session.model.state {
        case .preparing, .buffering, .recovering: return bufferingLabel
        default: return nil
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacPlayerProgrammeProgressView(
                title: session.presentation.request.title,
                programmes: session.presentation.programmes
            )
            if let message = session.model.playbackControlMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("player-control-message")
            }
            HStack(spacing: 16) {
                if session.model.canControlPlayback { Button {
                    session.model.togglePause(); reveal()
                } label: {
                    Image(systemName: session.model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 22, weight: .semibold)).frame(width: 34, height: 30)
                }.help(session.model.isPaused ? "继续播放（空格）" : "暂停（空格）")
                    .accessibilityLabel(session.model.isPaused ? "播放" : "暂停")
                    .accessibilityIdentifier("player.play-pause")
                }
                Button { Task { await state.stopPlayback(requestID: session.model.request.id) } } label: {
                    Label("停止", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6).frame(height: 34)
                        .contentShape(Rectangle())
                }.help("停止播放，返回频道列表（⌘.）")
                    .accessibilityLabel("停止播放").accessibilityIdentifier("player.stop")
                Button("节目单", systemImage: "list.bullet.rectangle") { state.showsProgrammes = true }
                    .help("节目单（E）").accessibilityIdentifier("player.programmes")
                Spacer()
                Button { overlay.toggleSidebar(paused: session.model.isPaused) } label: {
                    Image(systemName: "sidebar.left")
                }.help("显示或隐藏频道列表（L）").accessibilityLabel("频道列表")
                    .accessibilityIdentifier("player.channels")
                Button {
                    overlay.toggleInformation(paused: session.model.isPaused)
                } label: { Image(systemName: overlay.informationEnabled ? "info.circle.fill" : "info.circle") }
                    .help("显示或隐藏频道信息（I）").accessibilityLabel("频道信息")
                    .accessibilityIdentifier("player.information")
                Button { session.togglePictureInPicture() } label: {
                    Image(systemName: session.pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                }.help(session.pictureInPicture.isActive ? "返回播放窗口" : "画中画")
                    .accessibilityLabel(session.pictureInPicture.isActive ? "退出画中画" : "画中画")
                    .disabled(!session.pictureInPicture.isPossible && !session.pictureInPicture.isActive)
                    .accessibilityIdentifier("player.pip")
                Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                    .help("播放设置").accessibilityLabel("播放设置")
                Button { state.toggleFullScreen() } label: {
                    Image(systemName: state.isTheaterMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.help("全屏（双击画面或 ⌃⌘F）")
                    .accessibilityLabel(state.isTheaterMode ? "退出全屏" : "全屏")
                    .accessibilityIdentifier("player.fullscreen")
            }.buttonStyle(.plain)
        }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 24)
        .onHover { hovering in
            overlay.holdsControlsOpen = hovering || state.showsProgrammes || showsSettings
            if hovering, overlay.controlsVisible {
                overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused)
            }
            else { overlay.scheduleAutoHide(paused: session.model.isPaused) }
        }
    }
    private var bufferingLabel: String {
        switch session.model.state {
        case .preparing: "正在连接频道…"
        case .buffering: "正在缓冲…"
        default: "正在恢复播放…"
        }
    }
    @ViewBuilder private var stateOverlay: some View {
        if session.isClosing {
            EmptyView()
        } else if session.model.isPaused {
            Text("已暂停").padding(24)
        } else {
            switch session.model.state {
            case .preparing, .buffering, .recovering:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(bufferingLabel).font(.callout)
                }.padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .failed(let failure):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(failure.userMessage).multilineTextAlignment(.center)
                    if PlayerFailureActionPolicy.showsRetry(for: failure) { Button("重试") { session.model.retry() } }
                    Button("返回频道列表") { Task { await state.stopPlayback(requestID: session.model.request.id) } }
                }.padding(28).frame(maxWidth: 420).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            default: EmptyView()
            }
        }
    }
}

private struct MacPlayerProgrammeProgressView: View {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    let title: String
    let programmes: [Programme]

    var body: some View {
        if programmes.isEmpty {
            content(at: .now)
        } else {
            TimelineView(
                .periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0),
                    by: prefersReducedResourceUsage ? 60 : 15
                )
            ) { context in
                content(at: context.date)
            }
        }
    }

    private func content(at date: Date) -> some View {
        let programme = ChannelProgrammePresentation.resolve(programmes: programmes, at: date)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("直播").font(.caption.bold())
                Text(programme.current?.title ?? title).font(.callout).lineLimit(1)
                Spacer()
                if let current = programme.current {
                    Text("\(current.start.formatted(date: .omitted, time: .shortened)) – \(current.stop.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ProgressView(value: programme.progress ?? 0)
                .tint(.white).accessibilityLabel("当前节目播出进度")
                .accessibilityValue(programme.progress.map { "\(Int($0 * 100))%" } ?? "暂无节目进度")
                .help("当前节目播出进度").accessibilityIdentifier("player.programme-progress")
        }
    }
}

struct MacChannelInformationOverlay: View {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    let presentation: PlayerChannelPresentation
    let mediaInformation: PlaybackMediaInformation?
    let onHide: () -> Void
    var body: some View {
        if presentation.programmes.isEmpty {
            content(at: .now)
        } else {
            TimelineView(
                .periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0),
                    by: prefersReducedResourceUsage ? 60 : 15
                )
            ) { context in
                content(at: context.date)
            }
        }
    }
    private func content(at date: Date) -> some View {
        let programme = ChannelProgrammePresentation.resolve(programmes: presentation.programmes, at: date)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ChannelLogoView(url: presentation.logoURL, imagePadding: 2, placeholderVerticalPadding: 8)
                    .frame(width: 46, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.request.title).font(.headline).lineLimit(2)
                    Text(PlaybackMediaInformationPresentation(information: mediaInformation).visualText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onHide) { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).help("隐藏频道信息，按 I 再次显示")
                    .accessibilityLabel("隐藏频道信息").accessibilityIdentifier("player.information.hide")
            }
            Divider()
            if let current = programme.current { programmeRow("正在播放", programme: current) }
            else { Text("暂无当前节目").font(.caption).foregroundStyle(.secondary) }
            if let next = programme.next { programmeRow("接下来", programme: next) }
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1)) }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
    private func programmeRow(_ label: String, programme: Programme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption2)
            Text(programme.title).font(.callout).lineLimit(2)
        }
    }
}

struct MacProgrammeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    let presentation: PlayerChannelPresentation
    var body: some View {
        NavigationStack {
            Group {
                if presentation.programmes.isEmpty {
                    ContentUnavailableView("暂无节目单", systemImage: "list.bullet.rectangle",
                        description: Text("请刷新节目单，或为此频道设置 EPG 映射。"))
                } else {
                    TimelineView(
                        .periodic(
                            from: Date(timeIntervalSinceReferenceDate: 0),
                            by: prefersReducedResourceUsage ? 120 : 30
                        )
                    ) { context in
                        programmeList(at: context.date)
                    }
                }
            }.navigationTitle("\(presentation.request.title) · 节目单")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }.frame(width: 680, height: 560).accessibilityIdentifier("player.programme-guide")
    }
    private func programmeList(at date: Date) -> some View {
        let current = ChannelProgrammePresentation.resolve(programmes: presentation.programmes, at: date).current
        return ScrollViewReader { proxy in
            List {
                ForEach(presentation.programmes) { programme in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 16) {
                            Text("\(programme.start.formatted(date: .abbreviated, time: .shortened))\n\(programme.stop.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(programme.title).fontWeight(current?.id == programme.id ? .semibold : .regular)
                                if let subtitle = programme.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if current?.id == programme.id { Text("正在播放").font(.caption).foregroundStyle(.tint) }
                        }
                        if let summary = programme.summary, !summary.isEmpty {
                            DisclosureGroup("节目详情") { Text(summary).font(.callout).textSelection(.enabled).padding(.vertical, 8) }
                        }
                    }.padding(.vertical, 8).id(programme.id)
                }
            }.task { if let current { proxy.scrollTo(current.id, anchor: .center) } }
        }
    }
}
