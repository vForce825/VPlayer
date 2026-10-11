// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import Foundation
import Observation

@MainActor
@Observable
final class MacPlayerOverlayState {
    private(set) var controlsVisible = true
    private(set) var informationVisible = true
    private(set) var informationEnabled = true
    private(set) var sidebarVisible = false
    var holdsControlsOpen = false
    var holdsSidebarOpen = false
    private var hideTask: Task<Void, Never>?
    private var dismissedPointerLocation: CGPoint?
    private let delay: Duration
    init(delay: Duration = .seconds(5)) { self.delay = delay }
    func interact(paused: Bool, revealSidebar: Bool = false) {
        dismissedPointerLocation = nil
        controlsVisible = true
        informationVisible = informationEnabled
        if revealSidebar { sidebarVisible = true }
        scheduleAutoHide(paused: paused)
    }
    func pointerMoved(to location: CGPoint, paused: Bool, revealSidebar: Bool = false) {
        guard location != dismissedPointerLocation else { return }
        interact(paused: paused, revealSidebar: revealSidebar)
    }
    func hide(pointerLocation: CGPoint) {
        cancel()
        // 布局变化产生的悬停事件不代表鼠标移动，不能立即撤销 Esc 隐藏。
        dismissedPointerLocation = pointerLocation
        controlsVisible = false
        informationVisible = false
        sidebarVisible = false
        holdsControlsOpen = false
        holdsSidebarOpen = false
    }
    func scheduleAutoHide(paused: Bool) {
        cancel()
        guard !paused, !holdsControlsOpen, !holdsSidebarOpen else { return }
        let delay = delay
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.holdsControlsOpen, !self.holdsSidebarOpen else { return }
            self.controlsVisible = false
            self.informationVisible = false
            self.sidebarVisible = false
        }
    }
    func toggleSidebar(paused: Bool) {
        sidebarVisible.toggle()
        interact(paused: paused)
    }
    func toggleInformation(paused: Bool) {
        informationEnabled.toggle()
        interact(paused: paused)
    }
    func cancel() { hideTask?.cancel(); hideTask = nil }
}
