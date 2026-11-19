// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import SwiftUI
import VPlayerCore

struct MacRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    @Bindable var state: MacApplicationState
    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var mappingChannel: Channel?
    @State private var selectedChannelID: String?
    @State private var sidebarHasKeyboardFocus = false
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
        .background(MacLibraryWindowReader(
            update: { state.registerLibraryWindow($0) },
            handleKeyShortcut: { handleWindowKeyShortcut($0) }
        ))
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
    private func handleWindowKeyShortcut(_ shortcut: MacPlayerKeyShortcut) -> Bool {
        guard let session = state.session else { return false }
        switch shortcut {
        case .escape:
            guard session.overlay.hasVisibleOverlay else { return false }
            session.overlay.hide(pointerLocation: NSEvent.mouseLocation)
            session.model.clearPlaybackControlMessage()
            return true
        case .togglePause:
            session.model.togglePause()
            session.overlay.interact(paused: session.model.isPaused)
            return true
        case .toggleInformation:
            session.overlay.toggleInformation(paused: session.model.isPaused)
            return true
        case .showProgrammes:
            state.showsProgrammes = true
            return true
        case .toggleSidebar:
            session.overlay.toggleSidebar(paused: session.model.isPaused)
            return true
        }
    }
    private func libraryView(model: AppModel, dependencies: AppDependencies) -> some View {
        let hasActiveRootSheet = state.showsSourceManager || state.showsAddSource || mappingChannel != nil
        return ZStack(alignment: .leading) {
            Group {
                if let session = state.session {
                    MacPlayerView(
                        session: session,
                        state: state,
                        settings: dependencies.playbackSettings,
                        hasActiveRootSheet: hasActiveRootSheet
                    )
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
                    MacSidebarBrowserView(
                        model: model,
                        browsingSettings: dependencies.channelBrowsingSettings,
                        playingChannelID: state.session?.model.request.channelID,
                        prefersReducedResourceUsage: prefersReducedResourceUsage,
                        searchText: $searchText,
                        selectedGroup: $selectedGroup,
                        selectedChannelID: $selectedChannelID,
                        onAddSource: { state.showsAddSource = true },
                        onManageSources: { state.showsSourceManager = true },
                        onMapEPG: { mappingChannel = $0 },
                        onFocusChanged: { focused in
                            sidebarHasKeyboardFocus = focused
                            updateSidebarFocus()
                        }
                    )
                    .frame(width: state.sidebar.width)
                    MacSidebarResizeHandle(preferences: state.sidebar)
                        .frame(width: 8)
                }
                .frame(width: state.sidebar.width + 8)
                .shadow(color: .black.opacity(state.session == nil ? 0 : 0.25), radius: 12, x: 5)
                .onHover { hovering in
                    guard let session = state.session else { return }
                    session.overlay.holdsSidebarOpen = hovering && session.overlay.sidebarVisible
                    if hovering, session.overlay.sidebarVisible {
                        session.overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused)
                    } else { session.overlay.scheduleAutoHide(paused: session.model.isPaused) }
                }
                .onContinuousHover { phase in
                    if case .active = phase, let session = state.session, session.overlay.sidebarVisible {
                        session.overlay.pointerMoved(to: NSEvent.mouseLocation, paused: session.model.isPaused)
                    }
                }
                .onDisappear {
                    sidebarHasKeyboardFocus = false
                    guard let session = state.session else { return }
                    session.overlay.holdsSidebarOpen = false
                    session.overlay.sidebarHasFocus = voiceOverEnabled
                    session.overlay.scheduleAutoHide(paused: session.model.isPaused)
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
        .onChange(of: prefersReducedResourceUsage, initial: true) { _, preferred in
            dependencies.foregroundRefreshDriver.setPrefersReducedResourceUsage(preferred)
        }
        .onChange(of: voiceOverEnabled) { _, _ in updateSidebarFocus() }
        .onChange(of: state.session?.model.request.id) { _, _ in updateSidebarFocus() }
        .onChange(of: model.activeProfile?.id) { _, _ in
            searchText = ""
            selectedGroup = nil
        }
        .onChange(of: model.channels) { _, _ in
            if let selectedGroup, !model.channels.contains(where: { ChannelSectionBuilder.resolvedGroupTitle(for: $0) == selectedGroup }) {
                self.selectedGroup = nil
            }
        }
        .alert(model.alertTitle, isPresented: Binding(
            get: {
                model.alertMessage != nil
                    && !state.showsSourceManager
                    && !state.showsAddSource
                    && mappingChannel == nil
            },
            set: { if !$0 { model.dismissAlert() } }
        )) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .sheet(isPresented: $state.showsSourceManager) { MacSourceManagerView(model: model) }
        .sheet(isPresented: $state.showsAddSource) { MacSourceEditorView(model: model, profile: nil) }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel).frame(width: 600, height: 560)
        }
    }

    private func updateSidebarFocus() {
        guard let session = state.session else { return }
        let sidebarMounted = session.overlay.sidebarVisible
        session.overlay.sidebarHasFocus = (sidebarHasKeyboardFocus && sidebarMounted) || voiceOverEnabled
        if sidebarHasKeyboardFocus, sidebarMounted {
            session.overlay.interact(paused: session.model.isPaused, revealSidebar: true)
        } else {
            session.overlay.scheduleAutoHide(paused: session.model.isPaused)
        }
    }
}

private struct MacSidebarBrowserView: View {
    private enum SidebarFocus: Hashable { case search, channels, group, profile }

    private struct BrowserCache: Equatable {
        let channels: [Channel]
        let searchText: String
        let grouping: ChannelGrouping
        let selectedGroup: String?
        let presentation: ChannelBrowserPresentation
        let allGroupSections: [ChannelSection]
        let displayedChannels: [Channel]

        static func build(
            channels: [Channel],
            searchText: String,
            grouping: ChannelGrouping,
            selectedGroup: String?
        ) -> BrowserCache {
            let presentation = ChannelBrowserPresentation(
                channels: channels,
                searchText: searchText,
                grouping: grouping
            )
            let grouped = grouping == .playlistGroups
            let allGroupSections = grouped
                ? ChannelSectionBuilder.sections(channels: channels, grouping: .playlistGroups)
                : []
            let displayedChannels: [Channel]
            if grouped, let selectedGroup {
                displayedChannels = presentation.filteredChannels.filter {
                    ChannelSectionBuilder.resolvedGroupTitle(for: $0) == selectedGroup
                }
            } else {
                displayedChannels = presentation.filteredChannels
            }
            return BrowserCache(
                channels: channels,
                searchText: searchText,
                grouping: grouping,
                selectedGroup: selectedGroup,
                presentation: presentation,
                allGroupSections: allGroupSections,
                displayedChannels: displayedChannels
            )
        }
    }

    let model: AppModel
    let browsingSettings: ChannelBrowsingSettingsStore
    let playingChannelID: String?
    let prefersReducedResourceUsage: Bool
    @Binding var searchText: String
    @Binding var selectedGroup: String?
    @Binding var selectedChannelID: String?
    let onAddSource: () -> Void
    let onManageSources: () -> Void
    let onMapEPG: (Channel) -> Void
    let onFocusChanged: (Bool) -> Void

    @FocusState private var sidebarFocus: SidebarFocus?
    @State private var cache: BrowserCache
    @State private var programmeClockDate = Date()

    private var programmeClockKey: ProgrammeClockKey {
        ProgrammeClockKey(
            active: !model.programmesByChannelID.isEmpty,
            intervalSeconds: prefersReducedResourceUsage ? 120 : 30
        )
    }

    init(
        model: AppModel,
        browsingSettings: ChannelBrowsingSettingsStore,
        playingChannelID: String?,
        prefersReducedResourceUsage: Bool,
        searchText: Binding<String>,
        selectedGroup: Binding<String?>,
        selectedChannelID: Binding<String?>,
        onAddSource: @escaping () -> Void,
        onManageSources: @escaping () -> Void,
        onMapEPG: @escaping (Channel) -> Void,
        onFocusChanged: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.browsingSettings = browsingSettings
        self.playingChannelID = playingChannelID
        self.prefersReducedResourceUsage = prefersReducedResourceUsage
        _searchText = searchText
        _selectedGroup = selectedGroup
        _selectedChannelID = selectedChannelID
        self.onAddSource = onAddSource
        self.onManageSources = onManageSources
        self.onMapEPG = onMapEPG
        self.onFocusChanged = onFocusChanged
        _cache = State(initialValue: BrowserCache.build(
            channels: model.channels,
            searchText: searchText.wrappedValue,
            grouping: browsingSettings.grouping,
            selectedGroup: selectedGroup.wrappedValue
        ))
    }

    var body: some View {
        let grouped = browsingSettings.grouping == .playlistGroups
        let displayedChannels = cache.displayedChannels
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.activeProfile?.name ?? "频道资料库").font(.headline).lineLimit(1)
                Spacer()
                refreshStatusIndicator
                Text("\(displayedChannels.count)").foregroundStyle(.secondary).monospacedDigit()
            }.padding(16)
            if model.profiles.count > 1 {
                Picker("播放列表", selection: Binding(get: { model.activeProfile?.id }, set: { id in
                    guard let id, id != model.activeProfile?.id else { return }
                    selectedGroup = nil
                    searchText = ""
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
            if grouped, cache.allGroupSections.count > 1 {
                Picker("频道分组", selection: $selectedGroup) {
                    Text("全部分组").tag(Optional<String>.none)
                    ForEach(cache.allGroupSections) { section in
                        let title = section.title ?? ChannelSectionBuilder.ungroupedTitle
                        Text(title).tag(Optional(title))
                    }
                }.focused($sidebarFocus, equals: .group)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if model.isLoading { ProgressView().controlSize(.small).padding(12) }
            if model.channels.isEmpty {
                ContentUnavailableView("暂无频道", systemImage: "tv",
                    description: Text("添加或刷新播放列表后，频道会出现在这里。"))
                Button("添加播放列表", action: onAddSource).padding(.bottom, 24)
            } else if displayedChannels.isEmpty {
                emptyFilterState
            } else {
                channelList(channels: displayedChannels, referenceDate: programmeClockDate)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label("直播", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                if model.staleEPGCoverageEnd != nil { Label("节目单待更新", systemImage: "clock.badge.exclamationmark") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(.background)
        .onChange(of: sidebarFocus) { _, next in onFocusChanged(next != nil) }
        .onChange(of: model.channels) { _, _ in recomputeCache() }
        .onChange(of: searchText) { _, _ in recomputeCache() }
        .onChange(of: browsingSettings.grouping) { _, _ in recomputeCache() }
        .onChange(of: selectedGroup) { _, _ in recomputeCache() }
        .task(id: programmeClockKey) {
            await ProgrammeClockTicker.run(for: programmeClockKey) { date in
                programmeClockDate = date
            }
        }
    }

    @ViewBuilder
    private var refreshStatusIndicator: some View {
        if let profile = model.activeProfile {
            if profile.m3uStatus.state == .refreshing || profile.epgStatus.state == .refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .help("正在刷新当前播放列表")
                    .accessibilityLabel("正在刷新")
                    .accessibilityIdentifier("channels.refreshing")
            } else if profile.m3uStatus.state == .failed || profile.epgStatus.state == .failed {
                Button(action: onManageSources) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(refreshFailureSummary(for: profile))
                .accessibilityLabel("刷新失败，查看播放列表状态")
                .accessibilityIdentifier("channels.refresh-failed")
            }
        }
    }

    private func refreshFailureSummary(for profile: SourceProfile) -> String {
        var parts: [String] = []
        if profile.m3uStatus.state == .failed {
            parts.append("频道刷新失败：\(profile.m3uStatus.errorSummary ?? "请重试")")
        }
        if profile.epgStatus.state == .failed {
            parts.append("节目单刷新失败：\(profile.epgStatus.errorSummary ?? "请重试")")
        }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherGroupMatches = cache.presentation.filteredChannels.count
        if let selectedGroup, !trimmedQuery.isEmpty, otherGroupMatches > 0 {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "“\(selectedGroup)”分组中无匹配频道",
                    systemImage: "magnifyingglass",
                    description: Text("其他分组中有 \(otherGroupMatches) 个匹配频道。")
                )
                Button("显示全部分组") { self.selectedGroup = nil }
                    .accessibilityIdentifier("channels.clear-group-filter")
            }
            .padding(.bottom, 16)
        } else if let selectedGroup {
            VStack(spacing: 12) {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "“\(selectedGroup)”分组暂无频道",
                        systemImage: "tv"
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
                Button("显示全部分组") { self.selectedGroup = nil }
                    .accessibilityIdentifier("channels.clear-group-filter")
            }
            .padding(.bottom, 16)
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func channelList(channels: [Channel], referenceDate: Date) -> some View {
        List(selection: $selectedChannelID) {
            ForEach(channels) { channel in
                MacChannelRow(
                    channel: channel,
                    programmes: model.programmesByChannelID[channel.id] ?? [],
                    playing: playingChannelID == channel.id,
                    referenceDate: referenceDate
                )
                .tag(channel.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.select(channel: channel) }
                .contextMenu {
                    Button("播放频道") { model.select(channel: channel) }
                    Button("设置 EPG 映射…") { onMapEPG(channel) }
                }
                .accessibilityIdentifier("channel.\(channel.id)")
            }
        }
        .listStyle(.inset)
        .focused($sidebarFocus, equals: .channels)
        .onKeyPress(.return) {
            guard let selectedChannelID, let channel = channels.first(where: { $0.id == selectedChannelID }) else { return .ignored }
            model.select(channel: channel)
            return .handled
        }
    }

    private func recomputeCache() {
        let next = BrowserCache.build(
            channels: model.channels,
            searchText: searchText,
            grouping: browsingSettings.grouping,
            selectedGroup: selectedGroup
        )
        if next != cache {
            cache = next
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
        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            preferences.commitWidth()
        }
        override func accessibilityPerformIncrement() -> Bool {
            preferences.resize(to: preferences.width + 20)
            preferences.commitWidth()
            return true
        }
        override func accessibilityPerformDecrement() -> Bool {
            preferences.resize(to: preferences.width - 20)
            preferences.commitWidth()
            return true
        }
    }
}

private struct MacChannelRow: View {
    let channel: Channel
    let programmes: [Programme]
    let playing: Bool
    let referenceDate: Date
    var body: some View {
        let programme = ChannelProgrammePresentation.resolve(programmes: programmes, at: referenceDate)
        return HStack(spacing: 12) {
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

enum MacPlayerKeyShortcut: Equatable {
    case escape
    case togglePause
    case toggleInformation
    case showProgrammes
    case toggleSidebar

    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool,
        isEditingText: Bool
    ) -> MacPlayerKeyShortcut? {
        guard modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return nil
        }
        if keyCode == 53 {
            return .escape
        }
        guard !isEditingText, !isRepeat else { return nil }
        if keyCode == 49 {
            return .togglePause
        }
        switch charactersIgnoringModifiers?.lowercased() {
        case "i": return .toggleInformation
        case "e": return .showProgrammes
        case "l": return .toggleSidebar
        default: return nil
        }
    }
}

private struct MacLibraryWindowReader: NSViewRepresentable {
    let update: @MainActor (NSWindow?) -> Void
    let handleKeyShortcut: @MainActor (MacPlayerKeyShortcut) -> Bool
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.update = update
        view.handleKeyShortcut = handleKeyShortcut
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) {
        view.update = update
        view.handleKeyShortcut = handleKeyShortcut
    }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.stopMonitoring() }
    final class WindowView: NSView {
        var update: (@MainActor (NSWindow?) -> Void)?
        var handleKeyShortcut: (@MainActor (MacPlayerKeyShortcut) -> Bool)?
        private var keyMonitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            update?(window)
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let window = self?.window,
                          event.window === window,
                          window.attachedSheet == nil else { return false }
                    let isEditingText = (window.firstResponder is NSTextView) || (window.firstResponder is NSTextField)
                    guard let shortcut = MacPlayerKeyShortcut.resolve(
                        keyCode: event.keyCode,
                        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                        modifierFlags: event.modifierFlags,
                        isRepeat: event.isARepeat,
                        isEditingText: isEditingText
                    ) else { return false }
                    return self?.handleKeyShortcut?(shortcut) == true
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
