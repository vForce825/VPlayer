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
    private let delay: Duration
    init(delay: Duration = .seconds(5)) { self.delay = delay }
    func interact(paused: Bool, revealSidebar: Bool = false) {
        hideTask?.cancel()
        controlsVisible = true
        informationVisible = informationEnabled
        if revealSidebar { sidebarVisible = true }
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
