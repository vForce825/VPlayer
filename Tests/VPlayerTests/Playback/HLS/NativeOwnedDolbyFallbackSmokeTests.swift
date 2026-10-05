// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeOwnedDolbyFallbackSmokeTests: XCTestCase {
    func testActualAC3WriterTrialEitherPublishesCompressedOrJoinsOwnedAACRetry() async throws {
        try await assertActualWriterTrial(codec: .ac3)
    }

    func testActualEAC3WriterTrialEitherPublishesCompressedOrJoinsOwnedAACRetry() async throws {
        try await assertActualWriterTrial(codec: .eac3)
    }

    // Keep each codec independently executable: a failed AC3 trial must not hide
    // the EAC3 source-proof boundary from the same combined acceptance batch.
    private func assertActualWriterTrial(codec: VPlayerPlayback.AudioCodec) async throws {
        let bytes = try OrdinaryOwnedDolbyTS.make(codec: codec, bundle: Bundle(for: Self.self))
        XCTAssertLessThan(bytes.count, 4 * 1_024 * 1_024)
        let origin = try NativeHLSHTTPFixture(resources: ["/source.ts": .init(data: bytes, contentType: "video/mp2t")], credential: "dolby fixture")
        let probe = HLSWriterAcceptanceProbe()
        let observation = OwnedDolbyPreparationObservation()
        let factory = OwnedDolbySmokeFactory(probe: probe, observation: observation)
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress, notificationCenter: NotificationCenter())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk, monitor: monitor)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: PlaybackAudioRouteService(registry: registry, owner: owner), backendFactory: factory)
        var failure: (any Error)?
        do {
            let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "owned-dolby-\(codec.rawValue)",
                streamURL: origin.url("source.ts"), title: "Owned Dolby fixture", attributes: ["Authorization": "dolby fixture"])
            await controller.play(request)
            try await until(registry: registry) {
                guard let backend = factory.backend, registry.outputResourceContextSnapshot()?.prepared == true,
                      registry.outputResourceContextSnapshot()?.interval != nil,
                      case let .avPlayer(context)? = backend.presentation else { return false }
                return context.player.currentItem?.status == .readyToPlay && context.player.rate > 0
            }
            let backend = try XCTUnwrap(factory.backend)
            guard case let .avPlayer(context)? = backend.presentation else { throw HLSSourceError.incompleteEvidence }
            // Capture before potentially slow output-byte inspection; this
            // finite 6.144-second fixture may reach its genuine endpoint.
            let physical = try XCTUnwrap(context.player.currentItem)
            let start = context.player.currentTime().seconds
            guard start.isFinite else { throw HLSSourceError.incompleteEvidence }
            let native = probe.snapshot
            let trials = codec == .ac3 ? native.nativeAC3WriterCount : native.nativeEAC3WriterCount
            guard native.isComplete, trials > 0 else {
                XCTFail("No actual codec-specific AVAssetWriter trial occurred; candidate-only or no-trial AAC cannot count as coverage")
                throw HLSSourceError.incompleteEvidence
            }
            let audio = try await inspectPublishedAudio(XCTUnwrap(backend.generatedItemURLForTesting))
            let source = try XCTUnwrap(backend.ownedSourceForTesting)
            let original = try XCTUnwrap(observation.first)
            XCTAssertEqual(original.codec, codec)
            XCTAssertTrue(original.formatValidated)
            XCTAssertEqual(audio.sampleRate, original.sampleRate)
            XCTAssertEqual(audio.channelCount, original.channelCount)
            XCTAssertEqual(origin.deniedCount, 0)
            guard original.codec == codec, original.formatValidated, audio.sampleRate == original.sampleRate,
                  audio.channelCount == original.channelCount, origin.deniedCount == 0 else { throw HLSSourceError.incompleteEvidence }
            let outcome: String
            if audio.codec == codec {
                guard source.plan.audio == .passthrough(codec), backend.generatedBundleCallsForTesting == 1 else { throw HLSSourceError.incompleteEvidence }
                outcome = "compressed-native-writer-output"
            } else {
                guard audio.codec == .aac, source.plan.audio == .compatibleAAC,
                      backend.generatedBundleCallsForTesting == 2, observation.inspections == 1 else {
                    XCTFail("AAC output did not come from the original owned joined retry")
                    throw HLSSourceError.incompleteEvidence
                }
                // The second makeBundle is reachable only after the rejected
                // first graph's actual producer retirement returned confirmed.
                outcome = "compressed-unavailable-owned-joined-AAC-retry"
            }
            try await until(registry: registry) { context.player.currentItem === physical && context.player.currentTime().seconds > start + 0.25 }
            guard context.player.currentItem === physical, context.player.currentTime().seconds > start + 0.25,
                  audio.formatValidated else { throw HLSSourceError.incompleteEvidence }
            print("OWNED_DOLBY_TRIAL codec=\(codec.rawValue) nativeTrials=\(trials) outcome=\(outcome) progressed=true")
        } catch {
            let native = probe.snapshot
            // Failed preparation can release this weak backend before the
            // observer runs. Absence is not evidence of zero bundle attempts.
            let bundles = factory.backend.map { String($0.generatedBundleCallsForTesting) } ?? "unavailable"
            XCTFail("Owned Dolby smoke codec=\(codec.rawValue) failed: \(error); " +
                "inspections=\(observation.inspections) nativeTotal=\(native.nativeWriterCount) " +
                "AC3-trials=\(native.nativeAC3WriterCount) EAC3-trials=\(native.nativeEAC3WriterCount) bundles=\(bundles)")
            failure = error
        }
        await controller.stop(); await registry.joinOwnedTerminalCleanup(); await origin.close()
        XCTAssertNil(registry.outputResourceContextSnapshot())
        XCTAssertEqual(probe.snapshot.liveInputCount, 0)
        XCTAssertEqual(probe.snapshot.pendingCallbacks, 0)
        if let failure { throw failure }
    }
    private func until(registry: ControlTaskRegistry, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            if case let .failed(failure) = registry.playbackStateSnapshot() {
                throw failure
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else { throw HLSSourceError.deadline }
    }
    private func inspectPublishedAudio(_ itemURL: URL) async throws -> HLSSourceAudioFacts {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let playlist = try await session.data(from: itemURL)
        guard (playlist.1 as? HTTPURLResponse)?.statusCode == 200,
              let document = try HLSManifestGraph.parse(data: playlist.0, responseURL: itemURL).document(for: itemURL),
              document.kind == .media, let segment = document.segments.first, let map = segment.initialization else {
            throw HLSSourceError.incompleteEvidence
        }
        let initialization = try await session.data(from: map.url)
        let media = try await session.data(from: segment.resource.url)
        guard initialization.0.count <= 1_024 * 1_024, media.0.count <= 4 * 1_024 * 1_024,
              (initialization.1 as? HTTPURLResponse)?.statusCode == 200,
              (media.1 as? HTTPURLResponse)?.statusCode == 200 else { throw HLSSourceError.incompleteEvidence }
        let facts = try await FFmpegHLSContainerInspector().inspect(data: initialization.0 + media.0,
            url: segment.resource.url, deadline: HLSMonotonicClock.deadline(seconds: 10))
        guard facts.video == nil, facts.audio.count == 1 else { throw HLSSourceError.incompleteEvidence }
        return facts.audio[0]
    }
}

private final class OwnedDolbyPreparationObservation: @unchecked Sendable {
    private let lock = NSLock()
    struct Audio: Sendable {
        let codec: VPlayerPlayback.AudioCodec?
        let sampleRate: Int32
        let channelCount: Int32
        let formatValidated: Bool
    }
    private var audio: Audio?
    private var count = 0
    var first: Audio? { lock.withLock { audio } }
    var inspections: Int { lock.withLock { count } }
    func record(_ facts: HLSCompatibilityFacts) {
        lock.withLock {
            count += 1
            if audio == nil, let first = facts.media.first?.audio.first {
                audio = .init(codec: first.codec, sampleRate: first.sampleRate, channelCount: first.channelCount, formatValidated: first.formatValidated)
            }
        }
    }
}
private final class OwnedDolbySmokeFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let lock = NSLock()
    private weak var created: HLSAVPlayerPlaybackBackend?
    private let factory: SystemPlaybackBackendFactory
    var backend: HLSAVPlayerPlaybackBackend? { lock.withLock { created } }
    init(probe: HLSWriterAcceptanceProbe, observation: OwnedDolbyPreparationObservation) {
        factory = SystemPlaybackBackendFactory(hlsAcceptanceProbe: probe, sourceDependencies: { context in
            var dependencies = HLSNativeSourceDependencies(context: context)
            dependencies.capabilities = { facts, _ in
                observation.record(facts)
                let candidates = facts.media.flatMap(\.audio).compactMap { audio -> HLSCompressedAudioAdmissionCandidate? in
                    guard let codec = audio.codec, codec == .ac3 || codec == .eac3,
                          audio.formatValidated, audio.service == .independentMain else { return nil }
                    return .init(codec: codec, profile: audio.profile, sampleRate: audio.sampleRate,
                        channelCount: audio.channelCount, channelMask: audio.channelMask,
                        decoderConfiguration: audio.decoderConfiguration, outputRouteIdentifier: "ordinary-fixture-native-writer-trial",
                        requiresAACCompatibilityRendition: false)
                }
                // A test-only proposal gets the fixture to the actual writer.
                // No canAdd, emitted-init or output result is fabricated here.
                return .init(compressedAudioCodecs: [.ac3, .eac3, .aac], compressedAudioAdmissionCandidates: candidates, supportsGenerated: true)
            }
            return dependencies
        })
    }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend { throw HLSSourceError.unboundOwner }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, sourceContext: PlaybackSourceContext?, eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        let value = try await factory.makeBackend(kind: kind, identity: identity, tuning: tuning, channelID: channelID,
            url: url, sourceContext: sourceContext, eventSink: eventSink)
        lock.withLock { created = value as? HLSAVPlayerPlaybackBackend }
        return value
    }
}

/// Repackages unchanged public fixture syncframes into ordinary single-program
/// TS with exact frame PTS/PCR. No encoder or FFmpeg muxer is used.
private enum OrdinaryOwnedDolbyTS {
    static func make(codec: VPlayerPlayback.AudioCodec, bundle: Bundle) throws -> Data {
        let frames: [Data], sampleCount: Int64
        if codec == .eac3 {
            let bytes = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "eac3-main-6x1block-5.1", withExtension: "eac3")))
            var values: [Data] = [], offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 7 else { throw HLSSourceError.incompleteEvidence }
                let size = 2 * ((Int(bytes[offset + 2] & 7) << 8 | Int(bytes[offset + 3])) + 1)
                guard size <= bytes.count - offset else { throw HLSSourceError.incompleteEvidence }
                let frame = bytes.subdata(in: offset..<(offset + size))
                guard try EAC3FrameInspector.inspect(frame).sampleCount == 256 else { throw HLSSourceError.incompleteEvidence }
                values.append(frame); offset += size
            }
            frames = values; sampleCount = 256
        } else {
            let bytes = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "ac3-48k-5point1", withExtension: "mov")))
            var offset = 0, found: Data?
            while offset + 8 <= bytes.count {
                let size = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
                guard size >= 8, size <= bytes.count - offset else { throw HLSSourceError.incompleteEvidence }
                if bytes[(offset + 4)..<(offset + 8)] == Data("mdat".utf8) {
                    guard size >= 1_800 else { throw HLSSourceError.incompleteEvidence }
                    found = bytes.subdata(in: (offset + 8)..<(offset + 8 + 1_792)); break
                }
                offset += size
            }
            let frame = try XCTUnwrap(found)
            guard try AC3FrameInspector.inspect(frame).sampleCount == 1_536 else { throw HLSSourceError.incompleteEvidence }
            frames = [frame]; sampleCount = 1_536
        }
        guard !frames.isEmpty else { throw HLSSourceError.incompleteEvidence }
        var result = Data(), continuity: UInt8 = 0, sectionContinuity: UInt8 = 0
        let totalFrames = Int(192 * 1_536 / sampleCount)
        for index in 0..<totalFrames {
            if index % 48 == 0 { result += psi(codec: codec, continuity: sectionContinuity); sectionContinuity = (sectionContinuity + 1) & 15 }
            let frame = frames[index % frames.count], pts = Int64(index) * sampleCount * 90_000 / 48_000
            let length = frame.count + 8
            let stamp: [UInt8] = [0x21 | UInt8((pts >> 29) & 14), UInt8((pts >> 22) & 255), UInt8((pts >> 14) & 254) | 1,
                                  UInt8((pts >> 7) & 255), UInt8((pts << 1) & 254) | 1]
            let pes = Data([0, 0, 1, 0xBD, UInt8(length >> 8), UInt8(length & 255), 0x80, 0x80, 5] + stamp) + frame
            var offset = 0
            while offset < pes.count {
                let first = offset == 0, count = min(first ? 176 : 184, pes.count - offset)
                let adaptation = 183 - count
                var packet: [UInt8] = [0x47, first ? 0x41 : 1, 0, (count == 184 ? 0x10 : 0x30) | continuity]
                if count < 184 {
                    packet.append(UInt8(adaptation))
                    if adaptation > 0 {
                        packet.append(first ? 0x10 : 0)
                        if first { packet += [UInt8((pts >> 25) & 255), UInt8((pts >> 17) & 255), UInt8((pts >> 9) & 255), UInt8((pts >> 1) & 255), UInt8((pts & 1) << 7) | 0x7E, 0] }
                        packet += Array(repeating: 0xFF, count: adaptation - (first ? 7 : 1))
                    }
                }
                packet += pes[offset..<(offset + count)]; result += Data(packet)
                continuity = (continuity + 1) & 15; offset += count
            }
        }
        return result
    }
    private static func psi(codec: VPlayerPlayback.AudioCodec, continuity: UInt8) -> Data {
        func packet(pid: UInt16, section: [UInt8]) -> Data {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in section {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc << 1 ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7) }
            }
            let bytes = [UInt8(0)] + section + [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
            return Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(truncatingIfNeeded: pid), 0x10 | continuity] + bytes + Array(repeating: 0xFF, count: 184 - bytes.count))
        }
        return packet(pid: 0, section: [0, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0]) +
            packet(pid: 0x1000, section: [2, 0xB0, 24, 0, 1, 0xC1, 0, 0, 0xE1, 0, 0xF0, 0, codec == .eac3 ? 0x87 : 0x81, 0xE1, 0, 0xF0, 6, 5, 4] + Array((codec == .eac3 ? "EAC3" : "AC-3").utf8))
    }
}
