// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class PlaybackFixtureIntegrationTests: XCTestCase {
    private static let expectedFixturePaths: Set<String> = [
        "ac3-48k-5point1.mov",
        "hls/master.m3u8",
        "hls/segment0.ts",
        "interlaced-h264-mp2.ts",
        "progressive-h264-aac.ts",
    ]

    func testFixtureManifestStrictlyCoversCommittedHTTPMedia() throws {
        let baseURL = try fixtureBaseURL()
        let manifest = try FixtureHTTPClient.fetch(baseURL.appending(path: "SHA256SUMS"))
        let entries = try parseChecksumManifest(manifest)

        XCTAssertEqual(Set(entries.keys), Self.expectedFixturePaths)
        for path in Self.expectedFixturePaths.sorted() {
            let expected = try XCTUnwrap(entries[path])
            let bytes = try FixtureHTTPClient.fetch(baseURL.appending(path: path))
            XCTAssertEqual(SHA256.hash(data: bytes).hexString, expected, path)
        }
    }

    func testSyntheticAC3MOVProvidesAVAssetReaderReferenceDescription() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ac3-48k-5point1", withExtension: "mov")
        )
        let asset = AVURLAsset(url: fixtureURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let stream = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        )
        XCTAssertEqual(stream.mFormatID, kAudioFormatAC3)
        XCTAssertEqual(stream.mSampleRate, 48_000)
        XCTAssertEqual(stream.mChannelsPerFrame, 6)
        XCTAssertGreaterThanOrEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(CMSampleBufferGetSampleSize(sample, at: 0), 1_792)
        XCTAssertFalse(try copiedSampleData(sample).isEmpty)
    }

    func testProgressiveTransportStreamTraversesRealDemuxAndAssemblers() throws {
        let result = try assemble(path: "progressive-h264-aac.ts")

        try assertCommonPipelineContract(
            result,
            width: 1_280,
            height: 720,
            videoDelay: 1,
            audioCodec: .aac
        )
        XCTAssertTrue(result.videoAccessUnits.allSatisfy {
            $0.parserMetadata.isInterlaced == false
        })
        XCTAssertTrue(result.videoAccessUnits.allSatisfy {
            $0.parserMetadata.topFieldFirst != true
        })
    }

    func testProgressiveAACFixtureDecodesAssemblerFramesThroughRealPCMDecoder() throws {
        let result = try assemble(path: "progressive-h264-aac.ts")
        let source = try XCTUnwrap(result.trackSet.audio)
        let configuration = try XCTUnwrap(result.audioConfigurations.first)

        XCTAssertTrue(source.extradata.isEmpty)
        XCTAssertEqual(configuration.decoderExtradata, Data([0x11, 0x90]))

        let decoder = try FFmpegPCMAudioDecoder(
            codec: .aac,
            extradata: configuration.decoderExtradata
        )
        defer { decoder.destroy() }

        var decodedFrameCount = 0
        var continuity = AudioContinuityBuffer()
        let firstFrame = try XCTUnwrap(result.audioFrames.first)
        continuity.reset(to: firstFrame.generation)
        for frame in result.audioFrames.prefix(12) {
            guard case let .admitted(admitted) = try continuity.admit(frame) else {
                return XCTFail("fixture audio frame must pass canonical continuity admission")
            }
            let sampleBuffer = try SampleBufferBuilder.makeAudio(
                frame: admitted,
                formatDescription: configuration.formatDescription,
                forceResetDecoderBeforeDecoding: false
            )
            let sample = CompressedAudioSample(
                id: frame.id,
                sampleBuffer: sampleBuffer,
                codec: frame.codec,
                generation: frame.generation,
                presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
                duration: admitted.duration,
                continuityIslandID: admitted.continuityIslandID,
                effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
            )
            let outputs = try decoder.push(sample)
            for output in outputs {
                let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(output))
                let description = try XCTUnwrap(
                    CMAudioFormatDescriptionGetStreamBasicDescription(format)
                )
                XCTAssertEqual(description.pointee.mFormatID, kAudioFormatLinearPCM)
            }
            decodedFrameCount += outputs.count
        }

        XCTAssertGreaterThan(decodedFrameCount, 0)
    }

    func testInterlacedTransportStreamTraversesRealDemuxAndAssemblers() throws {
        let result = try assemble(path: "interlaced-h264-mp2.ts")

        try assertCommonPipelineContract(
            result,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            audioCodec: .mp2
        )
        XCTAssertTrue(result.videoAccessUnits.allSatisfy {
            $0.parserMetadata.isInterlaced == true
        })
        XCTAssertTrue(result.videoAccessUnits.allSatisfy {
            $0.parserMetadata.topFieldFirst == true
        })
    }

    func testMP2DecoderSurvivesRepeatedFlushesAtParsedFrameBoundaries() throws {
        let result = try assemble(path: "interlaced-h264-mp2.ts")
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .mp2,
            extradata: result.trackSet.audio?.extradata ?? Data()
        )
        defer { decoder.destroy() }

        var decodedFrameCount = 0
        var continuity = AudioContinuityBuffer()
        let firstFrame = try XCTUnwrap(result.audioFrames.first)
        continuity.reset(to: firstFrame.generation)
        let format = try XCTUnwrap(result.audioFormats.last)
        for frame in result.audioFrames.prefix(20) {
            decoder.flush()
            guard case let .admitted(admitted) = try continuity.admit(frame) else {
                return XCTFail("fixture audio frame must pass canonical continuity admission")
            }
            let sampleBuffer = try SampleBufferBuilder.makeAudio(
                frame: admitted,
                formatDescription: format,
                forceResetDecoderBeforeDecoding: true
            )
            let sample = CompressedAudioSample(
                id: frame.id,
                sampleBuffer: sampleBuffer,
                codec: frame.codec,
                generation: frame.generation,
                presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
                duration: admitted.duration,
                continuityIslandID: admitted.continuityIslandID,
                effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
            )
            let outputs = try decoder.push(sample)
            decodedFrameCount += outputs.count
        }

        XCTAssertEqual(decodedFrameCount, 20)
    }

    func testSingleVariantHLSUsesHTTPChildRequestAndRealAssemblers() throws {
        let result = try assemble(path: "hls/master.m3u8")
        let direct = try assemble(path: "progressive-h264-aac.ts")

        try assertCommonPipelineContract(
            result,
            width: 1_280,
            height: 720,
            videoDelay: 0,
            audioCodec: .aac
        )
        XCTAssertTrue(result.videoAccessUnits.allSatisfy {
            $0.parserMetadata.isInterlaced == false
        })
        XCTAssertEqual(
            result.demuxPackets,
            direct.demuxPackets,
            "HLS startup packets must be replayed exactly once and in original order"
        )
    }

    func testCancellingFromInitialHLSTracksDropsEveryRetainedStartupPacket() throws {
        let url = try fixtureBaseURL().appending(path: "hls/master.m3u8")
        let recorder = RawCancellingDemuxRecorder()
        let context = Unmanaged.passRetained(recorder).toOpaque()
        defer { Unmanaged<RawCancellingDemuxRecorder>.fromOpaque(context).release() }
        var handle: OpaquePointer?
        let urlBytes = Data(url.absoluteString.utf8)
        let createResult = urlBytes.withUnsafeBytes { bytes in
            vp_ffmpeg_demuxer_create(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                10_000_000,
                rawCancellingDemuxCallback,
                context,
                &handle
            )
        }
        XCTAssertEqual(createResult, 0)
        let created = try XCTUnwrap(handle)
        recorder.handle = created
        defer { vp_ffmpeg_demuxer_destroy(created) }

        XCTAssertEqual(vp_ffmpeg_demuxer_run(created), 0)
        XCTAssertEqual(
            recorder.kinds,
            [VPFF_EVENT_TRACKS.rawValue, VPFF_EVENT_CANCELLED.rawValue]
        )
        XCTAssertEqual(recorder.packetCount, 0)
    }

#if !targetEnvironment(simulator)
    func testDeviceUsesHardwareBothFieldsAndPassthroughForProgressiveAndInterlacedFixtures() throws {
        for path in ["progressive-h264-aac.ts", "interlaced-h264-mp2.ts"] {
            let assembled = try assemble(path: path)
            let executor = PlaybackSerialExecutor(
                label: "org.vplayer.tests.fixture.device.\(path)"
            )
            let submissionQueue = DispatchQueue(
                label: "org.vplayer.tests.fixture.device.submit.\(path)"
            )
            let processor = PassthroughVideoProcessor()
            let decoded = DeviceDecodeRecorder()
            let transitions = DeviceTransitionRecorder()
            let decoder = VideoToolboxDecoder(
                executor: executor,
                eventSink: { event in
                switch event {
                case let .frame(frame):
                    processor.submit(frame) { decoded.record($0) }
                case let .recoverableFailure(failure, _),
                     let .fatalFailure(failure, _):
                    decoded.record(failure)
                case let .submissionFailure(_, failure, _):
                    decoded.record(failure)
                case .submissionCompleted:
                    break
                case let .transitionCompleted(token, outcome):
                    transitions.record(token: token, outcome: outcome)
                }
                },
                api: SystemVideoToolboxAPI(),
                submissionQueue: submissionQueue
            )
            let format = try XCTUnwrap(assembled.videoFormats.last)
            let generation = MediaGeneration(rawValue: 1)
            let configureToken = VideoDecoderTransitionToken()

            try perform(on: executor) {
                processor.reset(to: generation)
                decoder.transition(.configure(
                    token: configureToken,
                    format: format,
                    generation: generation
                ))
            }
            submissionQueue.sync {}
            drain(executor)
            XCTAssertEqual(
                transitions.outcome(for: configureToken),
                .completed,
                path
            )
            try perform(on: executor) {
                for accessUnit in assembled.videoAccessUnits {
                    try decoder.decode(accessUnit, flags: [])
                }
            }
            submissionQueue.sync {}
            let drainToken = VideoDecoderTransitionToken()
            try perform(on: executor) {
                decoder.transition(.drainAndInvalidate(token: drainToken))
            }
            submissionQueue.sync {}
            drain(executor)
            XCTAssertEqual(transitions.outcome(for: drainToken), .completed, path)

            XCTAssertEqual(processor.requiredInputFrameCount, 1, path)
            XCTAssertTrue(decoded.failures.isEmpty, "\(path): \(decoded.failures)")
            XCTAssertGreaterThanOrEqual(decoded.presentationFrameCount, 25, path)
        }
    }
#endif

    private func fixtureBaseURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["VPLAYER_FIXTURE_BASE_URL"] else {
            throw XCTSkip("run through Scripts/run-playback-integration-tests.sh")
        }
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertNotNil(url.port)
        return url
    }

    private func parseChecksumManifest(_ data: Data) throws -> [String: String] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[1].isEmpty else {
                XCTFail("invalid SHA256SUMS line: \(line)")
                continue
            }
            let digest = String(fields[0])
            let path = String(fields[2])
            XCTAssertEqual(digest.count, 64)
            XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertFalse(path.hasPrefix("/"))
            XCTAssertFalse(path.contains("\\"))
            XCTAssertFalse(path.utf8.contains(0))
            XCTAssertTrue(path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
            XCTAssertNil(entries.updateValue(digest, forKey: path), "duplicate path: \(path)")
        }
        return entries
    }

    private func assemble(path: String) throws -> AssembledFixture {
        let url = try fixtureBaseURL().appending(path: path)
        let recorder = DemuxEventRecorder()
        let demuxer = FFmpegDemuxer()
        try demuxer.start(url: url, sink: recorder.record)
        let events = recorder.waitForTerminal(timeout: 20)

        guard case .endOfStream? = events.last else {
            let counts = events.reduce(into: (tracks: 0, discontinuities: 0, packets: 0)) {
                counts, event in
                switch event {
                case .tracks: counts.tracks += 1
                case .discontinuity: counts.discontinuities += 1
                case .packet: counts.packets += 1
                case .endOfStream, .cancelled, .failure: break
                }
            }
            XCTFail(
                "demux did not reach end of stream: " +
                    "tracks=\(counts.tracks), discontinuities=\(counts.discontinuities), " +
                    "packets=\(counts.packets), " +
                    "terminal=\(events.last.map(String.init(describing:)) ?? "none"), " +
                    "raw=\(RawDemuxDiagnostic.run(url: url))"
            )
            throw FixtureIntegrationFailure.missingEndOfStream
        }
        let tracksIndex = try XCTUnwrap(events.firstIndex { event in
            if case .tracks = event { return true }
            return false
        })
        let packetIndex = try XCTUnwrap(events.firstIndex { event in
            if case .packet = event { return true }
            return false
        })
        XCTAssertLessThan(tracksIndex, packetIndex)
        XCTAssertFalse(events[..<tracksIndex].contains { event in
            if case .packet = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .failure = event { return true }
            return false
        })

        guard case let .tracks(trackSet) = events[tracksIndex] else {
            throw FixtureIntegrationFailure.missingTracks
        }
        let output = AssemblerOutputRecorder()
        let generation = MediaGeneration(rawValue: 1)
        let state = AssemblyFormatState(trackSet: trackSet)
        let videoAssembler = try CompressedVideoAssembler(
            trackSet: trackSet,
            generationProvider: { generation },
            eventSink: output.record,
            formatState: state
        )
        let audioAssembler = try CompressedAudioAssembler(
            trackSet: trackSet,
            generationProvider: { generation },
            eventSink: output.record,
            formatState: state
        )

        for event in events {
            switch event {
            case let .packet(packet) where packet.streamIndex == trackSet.video?.streamIndex:
                try videoAssembler.push(packet)
            case let .packet(packet) where packet.streamIndex == trackSet.audio?.streamIndex:
                try audioAssembler.push(packet)
            default:
                continue
            }
        }
        try videoAssembler.drain()
        try audioAssembler.drain()
        return output.result(
            trackSet: trackSet,
            demuxPackets: events.compactMap { event in
                guard case let .packet(packet) = event else { return nil }
                return packet
            }
        )
    }

    private func assertCommonPipelineContract(
        _ result: AssembledFixture,
        width: Int32,
        height: Int32,
        videoDelay: Int32,
        audioCodec: VPlayerPlayback.AudioCodec
    ) throws {
        let video = try XCTUnwrap(result.trackSet.video)
        let audio = try XCTUnwrap(result.trackSet.audio)
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(video.width, width)
        XCTAssertEqual(video.height, height)
        XCTAssertEqual(video.videoDelay, videoDelay)
        XCTAssertEqual(audio.codec, audioCodec)
        XCTAssertGreaterThanOrEqual(result.videoAccessUnits.count, 25)
        XCTAssertGreaterThanOrEqual(result.audioFrames.count, 40)
        XCTAssertFalse(result.videoFormats.isEmpty)
        XCTAssertFalse(result.audioFormats.isEmpty)
        XCTAssertEqual(PassthroughVideoProcessor().requiredInputFrameCount, 1)

        let videoPTS = result.videoAccessUnits.map {
            CMSampleBufferGetPresentationTimeStamp($0.sampleBuffer)
        }
        try assertBFramePresentationTimeline(videoPTS)
        try assertStrictlyMonotonic(result.audioFrames.map(\.presentationTimeStamp))
    }

    private func assertBFramePresentationTimeline(_ decodeOrder: [CMTime]) throws {
        XCTAssertFalse(decodeOrder.isEmpty)
        XCTAssertTrue(decodeOrder.allSatisfy(\.isNumeric))
        XCTAssertTrue(
            zip(decodeOrder, decodeOrder.dropFirst()).contains { earlier, later in
                CMTimeCompare(earlier, later) > 0
            },
            "the two-B-frame fixture must expose presentation timestamps out of decode order"
        )

        let presentationOrder = decodeOrder.sorted {
            CMTimeCompare($0, $1) < 0
        }
        try assertStrictlyMonotonic(presentationOrder)
        let expectedCadence = CMTime(value: 1, timescale: 25)
        for (earlier, later) in zip(presentationOrder, presentationOrder.dropFirst()) {
            XCTAssertEqual(
                CMTimeCompare(CMTimeSubtract(later, earlier), expectedCadence),
                0,
                "presentation cadence must be exactly 1/25 second"
            )
        }
    }

    private func assertStrictlyMonotonic(_ times: [CMTime]) throws {
        XCTAssertFalse(times.isEmpty)
        XCTAssertTrue(times.allSatisfy(\.isNumeric))
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertLessThan(CMTimeCompare(earlier, later), 0)
        }
    }

#if !targetEnvironment(simulator)
    private func perform(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () throws -> Void
    ) throws {
        let completed = expectation(description: "fixture device operation")
        let result = ThrowingResultBox()
        executor.submit {
            do { try operation() } catch { result.store(error) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 30)
        if let error = result.error { throw error }
    }

    private func drain(_ executor: PlaybackSerialExecutor) {
        let completed = expectation(description: "fixture device callback drain")
        executor.submit { completed.fulfill() }
        wait(for: [completed], timeout: 30)
    }

    private func performWithoutThrowing(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () -> Void
    ) {
        let completed = expectation(description: "fixture device cleanup")
        executor.submit {
            operation()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 30)
    }
#endif
}

private struct RawDemuxDiagnostic: CustomStringConvertible {
    var trackCount = 0
    var discontinuityCount = 0
    var packetCount = 0
    var terminalKind: Int32?
    var terminalStage: Int32?
    var terminalError: Int32?
    var runResult: Int32?

    static func run(url: URL) -> Self {
        let recorder = RawDemuxDiagnosticRecorder()
        let context = Unmanaged.passRetained(recorder).toOpaque()
        defer { Unmanaged<RawDemuxDiagnosticRecorder>.fromOpaque(context).release() }
        var handle: OpaquePointer?
        let urlBytes = Data(url.absoluteString.utf8)
        let createResult = urlBytes.withUnsafeBytes { bytes in
            vp_ffmpeg_demuxer_create(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                10_000_000,
                rawDemuxDiagnosticCallback,
                context,
                &handle
            )
        }
        guard createResult == 0, let handle else {
            var result = recorder.value
            result.runResult = createResult
            return result
        }
        defer { vp_ffmpeg_demuxer_destroy(handle) }
        let runResult = vp_ffmpeg_demuxer_run(handle)
        var result = recorder.value
        result.runResult = runResult
        return result
    }

    var description: String {
        "tracks=\(trackCount), discontinuities=\(discontinuityCount), " +
            "packets=\(packetCount), terminalKind=\(terminalKind.map(String.init) ?? "none"), " +
            "terminalStage=\(terminalStage.map(String.init) ?? "none"), " +
            "terminalError=\(terminalError.map(String.init) ?? "none"), " +
            "runResult=\(runResult.map(String.init) ?? "none")"
    }
}

private final class RawDemuxDiagnosticRecorder: @unchecked Sendable {
    private var stored = RawDemuxDiagnostic()

    func record(_ event: VPFFDemuxEvent) {
        switch event.kind {
        case VPFF_EVENT_TRACKS:
            stored.trackCount += 1
        case VPFF_EVENT_DISCONTINUITY:
            stored.discontinuityCount += 1
        case VPFF_EVENT_PACKET:
            stored.packetCount += 1
        case VPFF_EVENT_END, VPFF_EVENT_CANCELLED, VPFF_EVENT_ERROR:
            stored.terminalKind = Int32(event.kind.rawValue)
            stored.terminalStage = Int32(event.error_stage.rawValue)
            stored.terminalError = event.ffmpeg_error
        default:
            break
        }
    }

    var value: RawDemuxDiagnostic { stored }
}

private func rawDemuxDiagnosticCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<RawDemuxDiagnosticRecorder>.fromOpaque(context)
        .takeUnretainedValue()
        .record(event.pointee)
}

private final class RawCancellingDemuxRecorder {
    var handle: OpaquePointer?
    private(set) var kinds: [UInt32] = []
    private(set) var packetCount = 0

    func record(_ event: VPFFDemuxEvent) {
        kinds.append(event.kind.rawValue)
        if event.kind == VPFF_EVENT_PACKET {
            packetCount += 1
        } else if event.kind == VPFF_EVENT_TRACKS, let handle {
            vp_ffmpeg_demuxer_cancel(handle)
        }
    }
}

private func rawCancellingDemuxCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<RawCancellingDemuxRecorder>.fromOpaque(context)
        .takeUnretainedValue()
        .record(event.pointee)
}

private enum FixtureIntegrationFailure: Error {
    case missingEndOfStream
    case missingTracks
    case invalidHTTPResponse
    case requestTimedOut
}

private struct AssembledFixture {
    let trackSet: DemuxTrackSet
    let demuxPackets: [DemuxPacket]
    let videoFormats: [CMVideoFormatDescription]
    let videoAccessUnits: [CompressedVideoAccessUnit]
    let audioConfigurations: [CompressedAudioRenderConfiguration]
    let audioFormats: [CMAudioFormatDescription]
    let audioFrames: [CompressedAudioFrame]
}

private final class AssemblerOutputRecorder {
    private var videoFormats: [CMVideoFormatDescription] = []
    private var videoAccessUnits: [CompressedVideoAccessUnit] = []
    private var audioConfigurations: [CompressedAudioRenderConfiguration] = []
    private var audioFormats: [CMAudioFormatDescription] = []
    private var audioFrames: [CompressedAudioFrame] = []

    func record(_ event: VideoAssemblerEvent) {
        switch event {
        case let .format(format, _): videoFormats.append(format)
        case let .accessUnit(accessUnit): videoAccessUnits.append(accessUnit)
        }
    }

    func record(_ event: AudioAssemblerEvent) {
        switch event {
        case let .format(configuration):
            audioConfigurations.append(configuration)
            audioFormats.append(configuration.formatDescription)
        case let .frame(frame):
            audioFrames.append(frame)
        case .decodeBreak:
            break
        }
    }

    func result(
        trackSet: DemuxTrackSet,
        demuxPackets: [DemuxPacket]
    ) -> AssembledFixture {
        AssembledFixture(
            trackSet: trackSet,
            demuxPackets: demuxPackets,
            videoFormats: videoFormats,
            videoAccessUnits: videoAccessUnits,
            audioConfigurations: audioConfigurations,
            audioFormats: audioFormats,
            audioFrames: audioFrames
        )
    }
}

private final class FixtureHTTPClient: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    static func fetch(_ url: URL) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        let completed = DispatchSemaphore(value: 0)
        let result = FixtureHTTPClient()
        session.dataTask(with: url) { data, response, error in
            result.store(data: data, response: response, error: error)
            completed.signal()
        }.resume()
        guard completed.wait(timeout: .now() + 20) == .success else {
            session.invalidateAndCancel()
            throw FixtureIntegrationFailure.requestTimedOut
        }
        session.finishTasksAndInvalidate()
        return try result.value()
    }

    private func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    private func value() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let data else {
            throw FixtureIntegrationFailure.invalidHTTPResponse
        }
        return data
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

#if !targetEnvironment(simulator)
private final class ThrowingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

private final class DeviceDecodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailures: [VideoDecoderFailure] = []
    private var storedPresentationFrameCount = 0

    func record(_ result: VideoProcessingResult) {
        lock.lock()
        if case let .produced(batch) = result {
            storedPresentationFrameCount += batch.frames.count
        }
        lock.unlock()
    }

    func record(_ failure: VideoDecoderFailure) {
        lock.lock()
        storedFailures.append(failure)
        lock.unlock()
    }

    var failures: [VideoDecoderFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }

    var presentationFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPresentationFrameCount
    }
}

private final class DeviceTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [VideoDecoderTransitionToken: VideoDecoderTransitionOutcome] = [:]

    func record(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    ) {
        lock.withLock { outcomes[token] = outcome }
    }

    func outcome(
        for token: VideoDecoderTransitionToken
    ) -> VideoDecoderTransitionOutcome? {
        lock.withLock { outcomes[token] }
    }
}
#endif
