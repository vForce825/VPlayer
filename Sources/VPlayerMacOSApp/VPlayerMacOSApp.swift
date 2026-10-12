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
            MacRootView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .task { delegate.state = state; await state.load() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MacPlayerCommands(state: state) }
        Settings {
            if let dependencies = state.dependencies {
                MacSettingsView(dependencies: dependencies)
            } else { ProgressView("正在打开资料库…").padding(40) }
        }
    }
}

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: MacApplicationState?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task { await state.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MacPlayerCommands: Commands {
    @Bindable var state: MacApplicationState
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加播放列表…") { state.showsAddSource = true }
                .keyboardShortcut("n").disabled(state.model == nil)
            Button("管理播放列表…") { state.showsSourceManager = true }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(state.model == nil)
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
            Divider()
            Button("进入或退出全屏") { state.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button(state.session?.pictureInPicture.isActive == true ? "退出画中画" : "画中画") {
                state.session?.togglePictureInPicture()
            }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.session?.pictureInPicture.isPossible != true && state.session?.pictureInPicture.isActive != true)
            Divider()
            Button("刷新当前列表的频道与节目单") { state.refresh() }
                .keyboardShortcut("r").disabled(state.model?.activeProfile == nil || state.model?.isLoading == true)
        }
    }
}
