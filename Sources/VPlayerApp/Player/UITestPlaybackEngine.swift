// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerPlayback

#if DEBUG
actor UITestPlaybackEngine: PlaybackEngine {
    private let fixture: String?
    private var state: PlaybackState = .idle
    private var request: PlaybackRequest?
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PlaybackNotice>.Continuation] = [:]

    init(fixture: String?) {
        self.fixture = fixture
    }

    func events() -> AsyncStream<PlaybackState> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: PlaybackState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        eventContinuations[id] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func notices() -> AsyncStream<PlaybackNotice> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: PlaybackNotice.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        noticeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoticeContinuation(id) }
        }
        return pair.stream
    }

    func play(_ request: PlaybackRequest) async {
        self.request = request
        publish(.preparing(request))
        await Task.yield()
        if fixture == "failed" || fixture == "failed-diagnostic" {
            publish(.failed(PlaybackFailure(
                code: "ui.fixture",
                userMessage: "测试播放失败，请重试。",
                diagnosticCode: fixture == "failed-diagnostic"
                    ? "video.decode.status.-12909"
                    : nil
            )))
            return
        }
        publish(.playing(request))
    }

    func setPaused(_ paused: Bool) async {
        guard let request else { return }
        publish(paused ? .paused(request) : .playing(request))
    }

    func stop() async {
        request = nil
        publish(.stopped)
    }

    private func publish(_ state: PlaybackState) {
        self.state = state
        for continuation in eventContinuations.values {
            continuation.yield(state)
        }
    }

    private func publish(_ notice: PlaybackNotice) {
        for continuation in noticeContinuations.values {
            continuation.yield(notice)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeNoticeContinuation(_ id: UUID) {
        noticeContinuations[id] = nil
    }
}
#endif
