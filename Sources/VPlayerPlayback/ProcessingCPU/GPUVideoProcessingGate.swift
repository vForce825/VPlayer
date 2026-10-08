// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import Foundation

/// The app closes admission synchronously at impending inactivity/PiP entry.
/// Every admitted submission must commit and waitUntilScheduled before its
/// closure returns. Resource completion is a separate, explicit fence.
final class GPUVideoProcessingGate: @unchecked Sendable {
    static let shared = GPUVideoProcessingGate()
    private let lock = NSLock()
    private var foreground = false
    private var pictureInPicture = false
    private var fence = GPUVideoHandoffFence()
    private var acceptsGPU: Bool { foreground && !pictureInPicture }

    func setForeground(_ value: Bool) { update(foreground: value, pictureInPicture: nil) }
    func setPictureInPicture(_ value: Bool) { update(foreground: nil, pictureInPicture: value) }
    private func update(foreground: Bool?, pictureInPicture: Bool?) {
        lock.withLock {
            let previouslyAccepted = acceptsGPU
            if let foreground { self.foreground = foreground }
            if let pictureInPicture { self.pictureInPicture = pictureInPicture }
            if acceptsGPU && !previouslyAccepted { fence = GPUVideoHandoffFence() }
        }
    }
    /// nil means GPU work was admitted; otherwise CPU must join this exact
    /// retired fence, never a later foreground epoch's GPU work.
    func withGPUAdmission(_ operation: (GPUVideoWorkTicket) throws -> Void) throws -> GPUVideoHandoffFence? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsGPU else { return fence }
        let ticket = fence.makeTicket()
        do { try operation(ticket) }
        catch { ticket.finish(); throw error }
        return nil
    }
}

final class GPUVideoHandoffFence: @unchecked Sendable {
    private let group = DispatchGroup()
    fileprivate func makeTicket() -> GPUVideoWorkTicket {
        group.enter()
        return GPUVideoWorkTicket(group: group)
    }
    func wait(timeout: DispatchTime) -> Bool { group.wait(timeout: timeout) == .success }
}

final class GPUVideoWorkTicket: @unchecked Sendable {
    private let lock = NSLock()
    private let group: DispatchGroup
    private var finished = false
    fileprivate init(group: DispatchGroup) { self.group = group }
    func finish() {
        let release = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if release { group.leave() }
    }
}

/// iOS app-owned visual activity, separate from playback pause/stop. tvOS never
/// selects the adaptive executor and has no dependency on this facade.
@MainActor
public enum PlaybackVideoProcessingActivity {
    public static func setForeground(_ value: Bool) { GPUVideoProcessingGate.shared.setForeground(value) }
    public static func setPictureInPicture(_ value: Bool) { GPUVideoProcessingGate.shared.setPictureInPicture(value) }
}

#endif
