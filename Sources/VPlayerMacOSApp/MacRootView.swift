// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import SwiftUI
import VPlayerCore

struct MacRootView: View {
    private enum SidebarFocus: Hashable { case search, channels, group, profile }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var sidebarFocus: SidebarFocus?
    @Bindable var state: MacApplicationState
    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var mappingChannel: Channel?
    @State private var selectedChannelID: String?
    var body: some View {
        Group {
            if let model = state.model, let dependencies = state.dependencies {
                libraryView(model: model, dependencies: dependencies)
            } else if let error = state.startupError {
                VStack(spacing: 20) {
                    ContentUnavailableView("无法打开本地资料库", systemImage: "externaldrive.badge.xmark",
                        description: Text(error))
                    Button("重试") { Task { await state.load() } }
                }
            } else { ProgressView("正在打开本地资料库…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .toolbar {
            if state.session == nil {
                ToolbarItemGroup {
                    Button("添加播放列表", systemImage: "plus") { state.showsAddSource = true }
                        .help("添加播放列表（⌘N）").accessibilityIdentifier("sources.add")
                    Button("管理播放列表", systemImage: "play.square.stack") { state.showsSourceManager = true }
                        .accessibilityIdentifier("sources.manage")
                    SettingsLink { Image(systemName: "gearshape") }.help("设置")
                }
            }
        }
        .navigationTitle(state.session.map { "VPlayer - \($0.presentation.request.title)" } ?? "VPlayer")
        .toolbarVisibility(.visible, for: .windowToolbar)
        .background(MacLibraryWindowReader(update: { state.registerLibraryWindow($0) }, hidePlaybackControls: {
            guard let session = state.session else { return false }
            session.overlay.hide(pointerLocation: NSEvent.mouseLocation)
            return true
        }))
        .onAppear { state.openLibraryWindow = { openWindow(id: "library") } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if notification.object as? NSWindow === state.libraryWindow { state.isTheaterMode = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if notification.object as? NSWindow === state.libraryWindow { state.isTheaterMode = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow { state.libraryWindowWillClose(window) }
        }
    }
    private func libraryView(model: AppModel, dependencies: AppDependencies) -> some View {
        ZStack(alignment: .leading) {
            Group {
                if let session = state.session {
                    MacPlayerView(session: session, state: state, settings: dependencies.playbackSettings)
                        .id(session.model.request.id)
                } else {
                    ContentUnavailableView("选择一个频道开始播放", systemImage: "play.rectangle",
                        description: Text(model.channels.isEmpty ? "添加 M3U 播放列表，即可浏览频道与节目单。" : "双击频道或按回车播放，直播将在右侧显示。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.08))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, state.session == nil ? state.sidebar.width + 8 : 0)
            if state.session == nil || state.session?.overlay.sidebarVisible == true {
                HStack(spacing: 0) {
                    browser(model: model, dependencies: dependencies)
                        .frame(width: state.sidebar.width)
                    MacSidebarResizeHandle(preferences: state.sidebar)
                        .frame(width: 8)
                }
                .frame(width: state.sidebar.width + 8)
                .shadow(color: .black.opacity(state.session == nil ? 0 : 0.25), radius: 12, x: 5)
                .onHover { hovering in
                    guard let session = state.session else { return }
                    session.overlay.holdsSidebarOpen = hovering
                    if hovering, session.overlay.sidebarVisible {
                        session.overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused)
                    } else { session.overlay.scheduleAutoHide(paused: session.model.isPaused) }
                }
                .onContinuousHover { phase in
                    if case .active = phase, let session = state.session, session.overlay.sidebarVisible {
                        session.overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else if let session = state.session {
                Color.clear.frame(width: 12).contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            session.overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused, revealSidebar: true)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.session?.overlay.sidebarVisible)
        .onChange(of: model.presentedPlaybackRequest) { _, request in state.replaceSession(for: request) }
        .onChange(of: sidebarFocus) { _, _ in updateSidebarFocus() }
        .onChange(of: voiceOverEnabled) { _, _ in updateSidebarFocus() }
        .onChange(of: state.session?.model.request.id) { _, _ in updateSidebarFocus() }
        .onChange(of: model.programmesByChannelID) { _, _ in state.refreshPresentation() }
        .onChange(of: model.channels) { _, _ in
            state.refreshPresentation()
            if let selectedGroup, !model.channels.contains(where: { ChannelSectionBuilder.resolvedGroupTitle(for: $0) == selectedGroup }) {
                self.selectedGroup = nil
            }
        }
        .task {
            while !Task.isCancelled {
                await model.maintainProgrammeWindow()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil },
            set: { if !$0 { model.dismissAlert() } })) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .sheet(isPresented: $state.showsSourceManager) { MacSourceManagerView(model: model) }
        .sheet(isPresented: $state.showsAddSource) { MacSourceEditorView(model: model, profile: nil) }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel).frame(width: 600, height: 560)
        }
    }
    private func browser(model: AppModel, dependencies: AppDependencies) -> some View {
        let grouped = dependencies.channelBrowsingSettings.grouping == .playlistGroups
        let presentation = ChannelBrowserPresentation(channels: model.channels, searchText: searchText,
            grouping: dependencies.channelBrowsingSettings.grouping)
        let channels = presentation.filteredChannels.filter { !grouped || selectedGroup == nil || ChannelSectionBuilder.resolvedGroupTitle(for: $0) == selectedGroup }
        return VStack(spacing: 0) {
            HStack {
                Text(model.activeProfile?.name ?? "频道资料库").font(.headline).lineLimit(1)
                Spacer()
                Text("\(channels.count)").foregroundStyle(.secondary).monospacedDigit()
            }.padding(16)
            if model.profiles.count > 1 {
                Picker("播放列表", selection: Binding(get: { model.activeProfile?.id }, set: { id in
                    guard let id else { return }; selectedGroup = nil
                    Task { _ = await model.activate(profileID: id) }
                })) {
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.focused($sidebarFocus, equals: .profile)
                    .padding(.horizontal, 16).padding(.bottom, 12).disabled(model.isLoading)
            }
            TextField("搜索频道或分组", text: $searchText)
                .focused($sidebarFocus, equals: .search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityIdentifier("channels.search")
            if grouped, presentation.sections.count > 1 {
                Picker("频道分组", selection: $selectedGroup) {
                    Text("全部分组").tag(Optional<String>.none)
                    ForEach(presentation.sections) { section in
                        Text(section.title ?? "其他").tag(Optional(section.title ?? "其他"))
                    }
                }.focused($sidebarFocus, equals: .group)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if model.isLoading { ProgressView().controlSize(.small).padding(12) }
            if model.channels.isEmpty {
                ContentUnavailableView("暂无频道", systemImage: "tv",
                    description: Text("添加或刷新播放列表后，频道会出现在这里。"))
                Button("添加播放列表") { state.showsAddSource = true }.padding(.bottom, 24)
            } else if channels.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: $selectedChannelID) {
                    ForEach(channels) { channel in
                        MacChannelRow(channel: channel, programmes: model.programmesByChannelID[channel.id] ?? [],
                            playing: state.session?.model.request.channelID == channel.id)
                            .tag(channel.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.select(channel: channel) }
                            .contextMenu {
                                Button("播放频道") { model.select(channel: channel) }
                                Button("设置 EPG 映射…") { mappingChannel = channel }
                            }
                            .accessibilityIdentifier("channel.\(channel.id)")
                    }
                }.listStyle(.inset)
                .focused($sidebarFocus, equals: .channels)
                .onKeyPress(.return) {
                    guard let selectedChannelID, let channel = channels.first(where: { $0.id == selectedChannelID }) else { return .ignored }
                    model.select(channel: channel)
                    return .handled
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label("直播", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                if model.staleEPGCoverageEnd != nil { Label("节目单待更新", systemImage: "clock.badge.exclamationmark") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.background(.background)
    }

    private func updateSidebarFocus() {
        guard let session = state.session else { return }
        session.overlay.sidebarHasFocus = sidebarFocus != nil || voiceOverEnabled
        if sidebarFocus != nil {
            session.overlay.interact(paused: session.model.isPaused, revealSidebar: true)
        } else {
            session.overlay.scheduleAutoHide(paused: session.model.isPaused)
        }
    }
}

private struct MacSidebarResizeHandle: NSViewRepresentable {
    let preferences: MacSidebarPreferences
    func makeNSView(context: Context) -> ResizeView { ResizeView(preferences: preferences) }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.setAccessibilityValue(Int(preferences.width))
    }
    final class ResizeView: NSView {
        private let preferences: MacSidebarPreferences
        private var dragStart: (x: CGFloat, width: Double)?
        init(preferences: MacSidebarPreferences) {
            self.preferences = preferences
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityLabel("调整频道列表宽度")
            setAccessibilityIdentifier("channels.resize")
            toolTip = "拖动调整频道列表宽度，下次打开时保留"
        }
        required init?(coder: NSCoder) { nil }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
        override func mouseDown(with event: NSEvent) {
            dragStart = (event.locationInWindow.x, preferences.width)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            preferences.resize(to: dragStart.width + event.locationInWindow.x - dragStart.x)
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func accessibilityPerformIncrement() -> Bool {
            preferences.resize(to: preferences.width + 20)
            return true
        }
        override func accessibilityPerformDecrement() -> Bool {
            preferences.resize(to: preferences.width - 20)
            return true
        }
    }
}

private struct MacChannelRow: View {
    let channel: Channel
    let programmes: [Programme]
    let playing: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let programme = ChannelProgrammePresentation.resolve(programmes: programmes, at: context.date)
            HStack(spacing: 12) {
                ChannelLogoView(url: channel.logoURL, imagePadding: 3, placeholderVerticalPadding: 8)
                    .frame(width: 42, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.displayName).fontWeight(playing ? .semibold : .regular).lineLimit(1)
                    Text(programme.current?.title ?? "暂无当前节目").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption) }
            }.padding(.vertical, 5)
        }
    }
}

private struct MacLibraryWindowReader: NSViewRepresentable {
    let update: @MainActor (NSWindow?) -> Void
    let hidePlaybackControls: @MainActor () -> Bool
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.update = update
        view.hidePlaybackControls = hidePlaybackControls
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) {
        view.update = update
        view.hidePlaybackControls = hidePlaybackControls
    }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.stopMonitoring() }
    final class WindowView: NSView {
        var update: (@MainActor (NSWindow?) -> Void)?
        var hidePlaybackControls: (@MainActor () -> Bool)?
        private var keyMonitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            update?(window)
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard event.keyCode == 53,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                          let window = self?.window, event.window === window,
                          window.attachedSheet == nil else { return false }
                    return self?.hidePlaybackControls?() == true
                }
                return handled ? nil : event
            }
        }
        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}
