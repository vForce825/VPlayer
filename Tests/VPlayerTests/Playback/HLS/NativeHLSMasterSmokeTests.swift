// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeHLSMasterSmokeTests: XCTestCase {
    func testRealAVPlayerNativeAndManagedHLSPrepareSelectedTracksAndProgressWithoutGeneratedGraph() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task22-progressive-h264-aac-16s", withExtension: "ts"))
        let bytes = try Data(contentsOf: file)
        for managed in [false, true] {
            let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nmedia.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\nmedia.m3u8\n"
            let media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:16\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:16,\npart.ts\n#EXT-X-ENDLIST\n"
            let origin = try NativeHLSHTTPFixture(resources: [
                "/master.m3u8": .init(data: Data(master.utf8), contentType: "application/vnd.apple.mpegurl"),
                "/media.m3u8": .init(data: Data(media.utf8), contentType: "application/vnd.apple.mpegurl"),
                "/part.ts": .init(data: bytes, contentType: "video/mp2t")], credential: managed ? "ordinary fixture" : nil)
            var failure: (any Error)?
            do {
                try await withController { controller, registry, factory in
                    let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "native-real-\(managed)",
                        streamURL: origin.url("master.m3u8"), title: "Native real fixture",
                        attributes: managed ? ["Authorization": "ordinary fixture"] : [:])
                    await controller.play(request)
                    try await until(registry: registry) {
                        guard registry.outputResourceContextSnapshot()?.prepared == true,
                              registry.outputResourceContextSnapshot()?.interval != nil,
                              let backend = factory.backend, let player = backend.presentation?.avPlayerForNativeSmoke else { return false }
                        return player.currentItem?.status == .readyToPlay && player.rate > 0
                    }
                    let backend = try XCTUnwrap(factory.backend)
                    XCTAssertEqual(backend.routedTransportForTesting, managed ? .proxy : .native)
                    XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
                    let player = try XCTUnwrap(backend.presentation?.avPlayerForNativeSmoke)
                    let physical = try XCTUnwrap(player.currentItem)
                    let started = player.currentTime().seconds
                    guard started.isFinite else { throw HLSSourceError.incompleteEvidence }
                    let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
                    XCTAssertTrue(coordinator.isPrepared)
                    let source = coordinator.owned
                    XCTAssertTrue(source.facts.complete)
                    XCTAssertEqual(source.facts.media.first?.video?.frameRate, MediaRational(num: 25, den: 1))
                    XCTAssertEqual(source.facts.media.first?.video?.colorTransfer, .bt709)
                    let selected = try await SystemNativeHLSAssetInspector(driver: XCTUnwrap(playerDriver(backend))).snapshot(item: coordinator.item, source: source)
                    XCTAssertNotNil(selected.video)
                    XCTAssertEqual(selected.audio?.codec, .aac)
                    try await until(registry: registry) { player.currentItem === physical && player.currentTime().seconds > started + 0.25 }
                    guard player.currentItem === physical, player.currentTime().seconds > started + 0.25,
                          backend.generatedBundleCallsForTesting == 0,
                          backend.routedTransportForTesting == (managed ? .proxy : .native),
                          selected.video != nil, selected.audio?.codec == .aac, selected.audio?.channelCount == 2,
                          source.facts.complete, source.facts.media.first?.video?.frameRate == MediaRational(num: 25, den: 1),
                          source.facts.media.first?.video?.colorTransfer == .bt709, origin.deniedCount == 0 else { throw HLSSourceError.incompleteEvidence }
                    XCTAssertEqual(origin.deniedCount, 0)
                    print("NATIVE_HLS_REAL_SELECTED_FORMAT managed=\(managed) video=\(selected.video?.width ?? 0)x\(selected.video?.height ?? 0) audio=AAC progressed=true")
                }
            } catch { failure = error }
            await origin.close()
            if let failure { throw failure }
        }
    }

    private func playerDriver(_ backend: HLSAVPlayerPlaybackBackend) -> SystemAVPlayerDriver? { backend.nativeSystemDriverForTesting }
    private func until(registry: ControlTaskRegistry, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else {
            XCTFail("Real native HLS failed to prepare/progress: \(String(describing: registry.outputResourceContextSnapshot()))")
            throw HLSSourceError.deadline
        }
    }
    private func withController(_ body: (PlaybackController, ControlTaskRegistry, NativeSmokeFactory) async throws -> Void) async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress, notificationCenter: NotificationCenter())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk, monitor: monitor)
        let factory = NativeSmokeFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: PlaybackAudioRouteService(registry: registry, owner: owner), backendFactory: factory)
        var failure: (any Error)?
        do { try await body(controller, registry, factory) } catch { failure = error }
        await controller.stop(); await registry.joinOwnedTerminalCleanup()
        XCTAssertNil(registry.outputResourceContextSnapshot())
        if let failure { throw failure }
    }
}

private extension PlaybackPresentation {
    var avPlayerForNativeSmoke: AVPlayer? {
        if case let .avPlayer(context) = self { return context.player }
        return nil
    }
}

private final class NativeSmokeFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let lock = NSLock()
    private weak var result: HLSAVPlayerPlaybackBackend?
    var backend: HLSAVPlayerPlaybackBackend? { lock.withLock { result } }
    // Explicit test envelope permits the public committed 720p/25 fixture on a
    // simulator. It supplies no source facts and changes no production policy.
    private let factory = SystemPlaybackBackendFactory(sourceDependencies: { context in
        var dependencies = HLSNativeSourceDependencies(context: context)
        dependencies.capabilities = { _, _ in
            .init(videoFormats: [.init(codec: .h264, profiles: [66, 77, 100], maximumLevel: 52,
                maximumWidth: 1_920, maximumHeight: 1_080, maximumFrameRate: MediaRational(num: 60, den: 1)!,
                bitDepths: [8], chromaFormats: [1], tiers: [.main], videoRanges: [.sdr])], nativeAudioCodecs: [.aac],
                supportsWebVTT: true, supportsGenerated: false, supportsInBandClosedCaptions: true)
        }
        return dependencies
    })
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        throw HLSSourceError.unboundOwner
    }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        let value = try await factory.makeBackend(kind: kind, identity: identity, tuning: tuning, channelID: channelID,
            url: url, sourceContext: sourceContext, eventSink: eventSink)
        lock.withLock { result = value as? HLSAVPlayerPlaybackBackend }
        return value
    }
}
