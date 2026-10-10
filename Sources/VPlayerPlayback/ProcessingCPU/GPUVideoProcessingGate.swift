// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import Foundation
import os

/// The app closes admission synchronously at impending inactivity/PiP entry.
/// Every admitted submission must commit and waitUntilScheduled before its
/// closure returns. Resource completion is a separate, explicit fence.
final class GPUVideoProcessingGate: @unchecked Sendable {
    static let shared = GPUVideoProcessingGate()
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "org.vplayer.playback", category: "iOSVideoProcessing")
    private var foreground = false
    private var pictureInPicture = false
    private var fence = GPUVideoHandoffFence()
    private var acceptsGPU: Bool { foreground && !pictureInPicture }

    func setForeground(_ value: Bool) { update(foreground: value, pictureInPicture: nil) }
    func setPictureInPicture(_ value: Bool) { update(foreground: nil, pictureInPicture: value) }
    private func update(foreground: Bool?, pictureInPicture: Bool?) {
        let change = lock.withLock { () -> (foreground: Bool, pip: Bool, metal: Bool)? in
            let oldForeground = self.foreground
            let oldPiP = self.pictureInPicture
            let previouslyAccepted = acceptsGPU
            if let foreground { self.foreground = foreground }
            if let pictureInPicture { self.pictureInPicture = pictureInPicture }
            if acceptsGPU && !previouslyAccepted { fence = GPUVideoHandoffFence(inheriting: fence.outstandingTickets) }
            guard oldForeground != self.foreground || oldPiP != self.pictureInPicture else { return nil }
            return (self.foreground, self.pictureInPicture, acceptsGPU)
        }
        if let change {
            // State transitions only; no media identifiers or per-frame log traffic.
            Self.logger.info("IOS_VIDEO_ACTIVITY foreground=\(change.foreground, privacy: .public) pip=\(change.pip, privacy: .public) metal=\(change.metal, privacy: .public)")
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
    private let lock = NSLock()
    private var tickets: [GPUVideoWorkTicket]
    init(inheriting tickets: [GPUVideoWorkTicket] = []) { self.tickets = tickets }
    var outstandingTickets: [GPUVideoWorkTicket] {
        lock.withLock {
            tickets.removeAll { $0.isFinished }
            return tickets
        }
    }
    fileprivate func makeTicket() -> GPUVideoWorkTicket {
        lock.withLock {
            tickets.removeAll { $0.isFinished }
            let ticket = GPUVideoWorkTicket()
            tickets.append(ticket)
            return ticket
        }
    }
    func wait(timeout: DispatchTime) -> Bool {
        outstandingTickets.allSatisfy { $0.wait(timeout: timeout) }
    }
}

final class GPUVideoWorkTicket: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var finished = false
    fileprivate init() { group.enter() }
    var isFinished: Bool { lock.withLock { finished } }
    fileprivate func wait(timeout: DispatchTime) -> Bool { group.wait(timeout: timeout) == .success }
    func finish() {
        lock.withLock {
            guard !finished else { return }
            group.leave()
            finished = true
        }
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
