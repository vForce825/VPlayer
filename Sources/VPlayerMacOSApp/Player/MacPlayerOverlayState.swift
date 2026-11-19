// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import Foundation
import Observation

@MainActor
@Observable
final class MacPlayerOverlayState {
    struct CarryOver: Equatable {
        let informationEnabled: Bool
        let sidebarVisible: Bool
        let holdsSidebarOpen: Bool
        let sidebarHasFocus: Bool
    }

    private(set) var controlsVisible = true
    private(set) var informationVisible = true
    private(set) var informationEnabled = true
    private(set) var sidebarVisible = false
    var holdsControlsOpen = false
    var holdsSidebarOpen = false
    var sidebarHasFocus = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var autoHideDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var dismissedPointerLocation: CGPoint?
    @ObservationIgnored private let delay: Duration
    #if DEBUG
    @ObservationIgnored private(set) var hideTaskCreationCountForTesting = 0
    #endif

    init(delay: Duration = .seconds(5)) { self.delay = delay }

    var hasVisibleOverlay: Bool {
        controlsVisible || informationVisible || sidebarVisible
    }

    func snapshotForChannelSwitch() -> CarryOver {
        CarryOver(
            informationEnabled: informationEnabled,
            sidebarVisible: sidebarVisible,
            holdsSidebarOpen: sidebarVisible && holdsSidebarOpen,
            sidebarHasFocus: sidebarHasFocus
        )
    }

    func applyChannelSwitchCarryOver(_ carryOver: CarryOver, paused: Bool) {
        informationEnabled = carryOver.informationEnabled
        informationVisible = carryOver.informationEnabled
        sidebarVisible = carryOver.sidebarVisible
        holdsSidebarOpen = carryOver.sidebarVisible && carryOver.holdsSidebarOpen
        sidebarHasFocus = carryOver.sidebarHasFocus
        interact(paused: paused, revealSidebar: carryOver.sidebarVisible)
    }

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
        guard hasVisibleOverlay,
              !paused,
              !holdsControlsOpen,
              !(sidebarVisible && holdsSidebarOpen),
              !sidebarHasFocus else {
            cancel()
            return
        }
        autoHideDeadline = ContinuousClock.now.advanced(by: delay)
        guard hideTask == nil else { return }
        #if DEBUG
        hideTaskCreationCountForTesting += 1
        #endif
        hideTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, let deadline = self.autoHideDeadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining <= .zero { break }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.autoHideDeadline = nil
            guard !self.holdsControlsOpen,
                  !(self.sidebarVisible && self.holdsSidebarOpen),
                  !self.sidebarHasFocus else { return }
            self.controlsVisible = false
            self.informationVisible = false
            self.sidebarVisible = false
        }
    }

    func toggleSidebar(paused: Bool) {
        sidebarVisible.toggle()
        if !sidebarVisible {
            holdsSidebarOpen = false
        }
        interact(paused: paused)
    }

    func toggleInformation(paused: Bool) {
        informationEnabled.toggle()
        interact(paused: paused)
    }

    func cancel() {
        hideTask?.cancel()
        hideTask = nil
        autoHideDeadline = nil
    }
}
