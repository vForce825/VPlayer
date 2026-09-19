// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerPlayback

#if DEBUG
actor UITestPlaybackEngine: PlaybackEngine, PlaybackPresentationControlling {
    private let fixture: String?
    private var state: PlaybackState = .idle
    private var request: PlaybackRequest?
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var presentationMountNonce: UInt64 = 0

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

    func play(_ request: PlaybackRequest) async {
        self.request = request
        publish(.preparing(request))
        await Task.yield()
        if fixture == "preparing" {
            return
        }
        if fixture == "buffering" {
            publish(.buffering(request))
            return
        }
        if fixture == "recovering" {
            publish(.recovering(request))
            return
        }
        if let fixture, [
            "failed",
            "failed-diagnostic",
            "failed-choose-channel",
            "failed-do-not-retry",
        ].contains(fixture) {
            let retryDisposition: PlaybackRetryDisposition = switch fixture {
            case "failed-choose-channel": .chooseAnotherChannel
            case "failed-do-not-retry": .doNotRetry
            default: .retrySameRequest
            }
            let userMessage = switch retryDisposition {
            case .retrySameRequest: "测试播放失败，请重试。"
            case .chooseAnotherChannel: "该频道无法播放，请选择其他频道。"
            case .doNotRetry: "播放已结束。"
            }
            publish(.failed(PlaybackFailure(
                code: "ui.fixture",
                userMessage: userMessage,
                diagnosticCode: fixture == "failed-diagnostic"
                    ? "video.decode.status.-12909"
                    : nil,
                retryDisposition: retryDisposition
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

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        AsyncStream { continuation in continuation.finish() }
    }

    func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        let (next, overflow) = presentationMountNonce.addingReportingOverflow(1)
        guard !overflow else { return .exhausted }
        presentationMountNonce = next
        return .claimed(.init(
            subscriptionGeneration: replacement.subscriptionGeneration,
            presentationIdentity: replacement.desired?.identity,
            mountNonce: next
        ))
    }

    func failPresentationControl() {
        request = nil
        publish(.failed(.init(
            code: "presentation.identity.exhausted",
            userMessage: "播放器呈现身份已耗尽。",
            retryDisposition: .doNotRetry
        )))
    }

    private func publish(_ state: PlaybackState) {
        self.state = state
        for continuation in eventContinuations.values {
            continuation.yield(state)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

}
#endif
