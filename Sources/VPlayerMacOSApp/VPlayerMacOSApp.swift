// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import SwiftUI

@main
struct VPlayerMacOSApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
    @State private var state = MacApplicationState()
    var body: some Scene {
        Window("VPlayer", id: "library") {
            MacLibrarySceneContent(state: state, delegate: delegate)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MacPlayerCommands(state: state) }
        Settings {
            MacSettingsSceneContent(state: state, delegate: delegate)
        }
    }
}

private struct MacLibrarySceneContent: View {
    @Environment(\.openWindow) private var openWindow
    let state: MacApplicationState
    let delegate: MacApplicationDelegate
    var body: some View {
        MacRootView(state: state)
            .frame(minWidth: 900, minHeight: 600)
            .onAppear { wireReopen() }
            .task {
                wireReopen()
                await state.load()
            }
    }
    private func wireReopen() {
        let reopen = { openWindow(id: "library") }
        delegate.state = state
        delegate.openLibraryWindow = reopen
        state.openLibraryWindow = reopen
    }
}

private struct MacSettingsSceneContent: View {
    @Environment(\.openWindow) private var openWindow
    let state: MacApplicationState
    let delegate: MacApplicationDelegate
    var body: some View {
        Group {
            if let dependencies = state.dependencies {
                MacSettingsView(dependencies: dependencies)
            } else if let error = state.startupError {
                VStack(spacing: 16) {
                    ContentUnavailableView("无法打开本地资料库", systemImage: "externaldrive.badge.xmark",
                        description: Text(error))
                    Button("重试") { Task { await state.load() } }
                }
                .padding(24)
                .frame(width: 440, height: 260)
            } else {
                ProgressView("正在打开资料库…").padding(40)
            }
        }
        .onAppear { wireReopen() }
        .task {
            wireReopen()
            await state.load()
        }
    }
    private func wireReopen() {
        let reopen = { openWindow(id: "library") }
        delegate.state = state
        delegate.openLibraryWindow = reopen
        state.openLibraryWindow = reopen
    }
}

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: MacApplicationState?
    var openLibraryWindow: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = state?.libraryWindow, window.isVisible {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        if let openLibraryWindow {
            openLibraryWindow()
            return false
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task { await state.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MacPlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Bindable var state: MacApplicationState
    var body: some Commands {
        CommandGroup(replacing: .singleWindowList) {
            Button("显示主窗口") {
                openWindow(id: "library")
                NSApp.activate()
            }
            .keyboardShortcut("1", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("添加播放列表…") {
                openWindow(id: "library")
                NSApp.activate()
                Task {
                    if state.model == nil { await state.load() }
                    guard state.model != nil else { return }
                    state.showsAddSource = true
                }
            }
            .keyboardShortcut("n")
            .disabled(state.isLoading)
            Button("管理播放列表…") {
                openWindow(id: "library")
                NSApp.activate()
                Task {
                    if state.model == nil { await state.load() }
                    guard state.model != nil else { return }
                    state.showsSourceManager = true
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(state.isLoading)
        }
        CommandMenu("播放") {
            Button(state.session?.model.isPaused == true ? "继续播放" : "暂停") { state.session?.model.togglePause() }
                .keyboardShortcut("p").disabled(state.session?.model.canControlPlayback != true)
            Button("停止播放") { state.requestStopPlayback() }
                .keyboardShortcut(".").disabled(state.session == nil)
            Button("显示或隐藏频道列表") {
                guard let session = state.session else { return }
                session.overlay.toggleSidebar(paused: session.model.isPaused)
            }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(state.session == nil)
            Button("显示或隐藏频道信息") {
                guard let session = state.session else { return }
                session.overlay.toggleInformation(paused: session.model.isPaused)
            }.keyboardShortcut("i").disabled(state.session == nil)
            Button("节目单…") {
                guard state.session != nil else { return }
                state.showsProgrammes = true
            }.keyboardShortcut("e").disabled(state.session == nil)
            Divider()
            Button("进入或退出全屏") { state.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!state.isLibraryWindowVisible)
            Button(state.session?.pictureInPicture.isActive == true ? "退出画中画" : "画中画") {
                state.session?.togglePictureInPicture()
            }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.session?.pictureInPicture.isPossible != true && state.session?.pictureInPicture.isActive != true)
            Divider()
            Button("刷新当前列表的频道与节目单") { state.refresh() }
                .keyboardShortcut("r")
                .disabled(state.model?.activeProfile == nil || state.model?.isLoading == true || state.isActiveProfileRefreshing)
        }
    }
}
