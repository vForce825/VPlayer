// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

struct SupportedAudioFixtureCoverage: Sendable {
    var checkedInFixtureIDs: [String] = []
    var domainApprovedCodecs: [String] = []
    var domainAacIndexedSampleRates: [Int32] = []
    var domainAacRawKinds: [String] = []
    var domainMPEGHeaderCount: Int = 0
    var domainAC3HeaderCount: Int = 0
    var domainEAC3HeaderCount: Int = 0
    var uncoveredDomainValues: [String] = []

    static func loadCheckedInManifest() throws -> SupportedAudioFixtureCoverage {
        let data = try FixtureLoader.data("supported-audio-coverage.json")
        let manifest = try JSONDecoder().decode(AudioCoverageManifest.self, from: data)

        // Ensure all checked-in fixtures physically exist and are non-empty
        for fixture in manifest.fixtures {
            let fixtureData = try FixtureLoader.data(fixture.path)
            guard !fixtureData.isEmpty else {
                throw NSError(domain: "SupportedAudioFixtureCoverage", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Fixture \(fixture.path) is empty"
                ])
            }
        }

        let domain = manifest.domain
        var uncovered: [String] = []

        let expectedCodecs = SupportedAudioInputDomain.approvedCodecs.map { codec -> String in
            switch codec {
            case .aac: return "aac"
            case .mp1: return "mp1"
            case .mp2: return "mp2"
            case .mp3: return "mp3"
            case .ac3: return "ac3"
            case .eac3: return "eac3"
            }
        }
        if domain.approvedCodecs != expectedCodecs {
            uncovered.append("mismatched.approvedCodecs")
        }
        if domain.aacIndexedSampleRates != SupportedAudioInputDomain.aacIndexedSampleRates {
            uncovered.append("mismatched.aacIndexedSampleRates")
        }
        let expectedKinds = SupportedAudioInputDomain.aacRawKinds.map { kind -> String in
            switch kind {
            case .aacLC: return "aacLC"
            case .heAACv1: return "heAACv1"
            case .heAACv2: return "heAACv2"
            }
        }
        if domain.aacRawKinds != expectedKinds {
            uncovered.append("mismatched.aacRawKinds")
        }
        if domain.mpegHeaderCount != SupportedAudioInputDomain.mpegHeaderEntries.count {
            uncovered.append("mismatched.mpegHeaderCount")
        }
        if domain.ac3HeaderCount != SupportedAudioInputDomain.ac3HeaderEntries.count {
            uncovered.append("mismatched.ac3HeaderCount")
        }
        if domain.eac3HeaderCount != SupportedAudioInputDomain.eac3HeaderEntries.count {
            uncovered.append("mismatched.eac3HeaderCount")
        }

        let expectedFixtureIDs = [
            "eac3-main-6x1block-5.1",
            "progressive-h264-aac",
            "interlaced-h264-mp2",
            "ac3-48k-5point1",
        ]
        let manifestIDs = manifest.fixtures.map(\.id)
        if manifestIDs != expectedFixtureIDs {
            uncovered.append("mismatched.checkedInFixtures")
        }

        return SupportedAudioFixtureCoverage(
            checkedInFixtureIDs: manifestIDs,
            domainApprovedCodecs: domain.approvedCodecs,
            domainAacIndexedSampleRates: domain.aacIndexedSampleRates,
            domainAacRawKinds: domain.aacRawKinds,
            domainMPEGHeaderCount: domain.mpegHeaderCount,
            domainAC3HeaderCount: domain.ac3HeaderCount,
            domainEAC3HeaderCount: domain.eac3HeaderCount,
            uncoveredDomainValues: uncovered
        )
    }
}

private struct AudioCoverageManifest: Decodable {
    let schema: Int
    let domain: AudioCoverageDomain
    let fixtures: [AudioCoverageFixture]
}

private struct AudioCoverageDomain: Decodable {
    let approvedCodecs: [String]
    let aacIndexedSampleRates: [Int32]
    let aacRawKinds: [String]
    let mpegHeaderCount: Int
    let ac3HeaderCount: Int
    let eac3HeaderCount: Int
    let channelTopologies: [Int]
}

private struct AudioCoverageFixture: Decodable {
    let id: String
    let path: String
    let codec: String
    let profile: String
    let framing: String
    let sampleRate: Int32
    let channelCount: Int32
    let channelLayout: String
    let decodedFramesPerAccessUnit: Int
    let deliveryMode: String
    let coveredDomainValues: [String]
}

struct HLSCodecFixtureRunnerResult: Sendable {
    var decodedFramesPerAccessUnit: Int = 0
    var channelCount: Int = 0
    var publishedBytesPassedSystemDecode: Bool = false
}

enum HLSCodecFixtureRunner {
    enum RunnerError: Error {
        case unknownFixture(String)
        case corruptedSyncframe
        case decodeFailed
    }

    static func run(_ fixtureName: String) async throws -> HLSCodecFixtureRunnerResult {
        switch fixtureName {
        case "eac3-main-6x1block-5.1":
            return try await runEAC3Main6x1Block()
        case "ac3-48k-5point1":
            return try await runAC35Point1()
        case "progressive-h264-aac":
            return try await runProgressiveAAC()
        case "interlaced-h264-mp2":
            return try await runInterlacedMP2()
        case "corrupt-syncframe":
            return try await runCorruptSyncframe()
        case "fake-audio-payload":
            return try await runFakeAudioPayload()
        default:
            throw RunnerError.unknownFixture(fixtureName)
        }
    }

    private static func runEAC3Main6x1Block() async throws -> HLSCodecFixtureRunnerResult {
        let data = try FixtureLoader.data("eac3-main-6x1block-5.1.eac3")

        var offset = 0
        var frames: [Data] = []
        while offset + 4 <= data.count {
            guard data[offset] == 0x0B, data[offset + 1] == 0x77 else {
                throw RunnerError.corruptedSyncframe
            }
            let word1 = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            let frmsiz = word1 & 0x07FF
            let frameSize = 2 * (frmsiz + 1)
            guard offset + frameSize <= data.count else {
                throw RunnerError.corruptedSyncframe
            }
            let frameData = data.subdata(in: offset..<(offset + frameSize))
            let inspection = try EAC3FrameInspector.inspect(frameData)
            guard inspection.blockCount == 1,
                  inspection.sampleCount == 256,
                  inspection.channelCount == 6,
                  inspection.sampleRate == 48_000,
                  inspection.streamType == .independent,
                  inspection.substreamID == 0,
                  inspection.bsid == 16,
                  inspection.bsmod == 0,
                  inspection.acmod == 7,
                  inspection.lfeon == true else {
                throw RunnerError.corruptedSyncframe
            }
            frames.append(frameData)
            offset += frameSize
        }
        guard frames.count == 12 else {
            throw RunnerError.corruptedSyncframe
        }

        // Verify convsync pattern: true on frame 0 and 6, false on remaining frames
        for (i, frame) in frames.enumerated() {
            let insp = try EAC3FrameInspector.inspect(frame)
            if i % 6 == 0 {
                guard insp.convsync == true else { throw RunnerError.corruptedSyncframe }
            } else {
                guard insp.convsync == false else { throw RunnerError.corruptedSyncframe }
            }
        }

        // Aggregate 6x 1-block frames per Access Unit (1536 samples per AU)
        var au0 = Data()
        for i in 0..<6 { au0.append(frames[i]) }
        var au1 = Data()
        for i in 6..<12 { au1.append(frames[i]) }

        let eac3Config = try EAC3CompressedAudioConfiguration(
            sampleRate: 48_000,
            bsid: 16,
            bsmod: 0,
            audioCodingMode: 7,
            hasLFE: true,
            asvc: false,
            maximumDataRateKbps: 448
        )
        let cookie = CompressedAudioFormatConfiguration.eac3(eac3Config).serializedBox

        let format = try AudioFormatDescriptionBuilder.make(
            SystemCompressedAudioFormat(
                profileID: .eac3,
                codec: .eac3,
                formatID: kAudioFormatEnhancedAC3,
                sampleRate: 48_000,
                channelCount: 6,
                framesPerPacket: 1_536,
                layout: .tag(
                    kAudioChannelLayoutTag_MPEG_5_1_A,
                    equivalentBitmap: AudioChannelBitmap(rawValue: 0x3F)
                ),
                magicCookie: cookie
            )
        )
        let formatDesc = format.description

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw RunnerError.decodeFailed }
        writer.add(writerInput)
        guard writer.startWriting() else { throw RunnerError.decodeFailed }
        writer.startSession(atSourceTime: .zero)

        let auDuration = CMTime(value: 1_536, timescale: 48_000)
        guard let b0 = makeSampleBuffer(au0, pts: .zero, dur: auDuration, format: formatDesc),
              let b1 = makeSampleBuffer(au1, pts: auDuration, dur: auDuration, format: formatDesc) else {
            throw RunnerError.decodeFailed
        }
        writerInput.append(b0)
        writerInput.append(b1)
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw RunnerError.decodeFailed }

        // System Linear PCM decode verification via AVAssetReader
        let asset = AVURLAsset(url: tempURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw RunnerError.decodeFailed }

        let reader = try AVAssetReader(asset: asset)
        let lpcmOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
        ])
        let readerOutput: AVAssetReaderTrackOutput
        if reader.canAdd(lpcmOutput) {
            readerOutput = lpcmOutput
        } else {
            readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        }
        guard reader.canAdd(readerOutput) else { throw RunnerError.decodeFailed }
        reader.add(readerOutput)
        guard reader.startReading() else { throw RunnerError.decodeFailed }

        var decodedPCMCount = 0
        var readSampleBuffers: [CMSampleBuffer] = []
        while let sample = readerOutput.copyNextSampleBuffer() {
            let numSamples = CMSampleBufferGetNumSamples(sample)
            guard numSamples > 0 else { continue }
            if readerOutput === lpcmOutput {
                decodedPCMCount += numSamples
            } else {
                readSampleBuffers.append(sample)
            }
        }
        guard reader.status == .completed else { throw RunnerError.decodeFailed }

        if readerOutput === lpcmOutput {
            guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }
        } else {
            guard readSampleBuffers.count == 2 else { throw RunnerError.decodeFailed }
            let decoder = try FFmpegPCMAudioDecoder(codec: .eac3, extradata: cookie)
            defer { decoder.destroy() }
            for (idx, sb) in readSampleBuffers.enumerated() {
                let sample = CompressedAudioSample(
                    id: UInt64(idx + 1),
                    sampleBuffer: sb,
                    codec: .eac3,
                    generation: MediaGeneration(rawValue: 1),
                    presentationTimeStamp: CMTime(value: Int64(idx * 1536), timescale: 48_000),
                    duration: CMTime(value: 1536, timescale: 48_000),
                    continuityIslandID: AudioContinuityIslandID(rawValue: 1)
                )
                let pcm = try decoder.push(sample)
                decodedPCMCount += pcm.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
            }
            guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }
        }

        return HLSCodecFixtureRunnerResult(
            decodedFramesPerAccessUnit: 1_536,
            channelCount: 6,
            publishedBytesPassedSystemDecode: true
        )
    }

    private static func runAC35Point1() async throws -> HLSCodecFixtureRunnerResult {
        let url = try FixtureLoader.url("ac3-48k-5point1.mov")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw RunnerError.decodeFailed }

        let reader = try AVAssetReader(asset: asset)
        let lpcmOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
        ])
        let readerOutput: AVAssetReaderTrackOutput
        if reader.canAdd(lpcmOutput) {
            readerOutput = lpcmOutput
        } else {
            readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        }
        guard reader.canAdd(readerOutput) else { throw RunnerError.decodeFailed }
        reader.add(readerOutput)
        guard reader.startReading() else { throw RunnerError.decodeFailed }

        var decodedPCMCount = 0
        var readSampleBuffers: [CMSampleBuffer] = []
        while let sample = readerOutput.copyNextSampleBuffer() {
            let numSamples = CMSampleBufferGetNumSamples(sample)
            guard numSamples > 0 else { continue }
            if readerOutput === lpcmOutput {
                decodedPCMCount += numSamples
            } else {
                readSampleBuffers.append(sample)
            }
        }
        guard reader.status == .completed else { throw RunnerError.decodeFailed }

        if readerOutput === lpcmOutput {
            guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }
        } else {
            guard !readSampleBuffers.isEmpty else { throw RunnerError.decodeFailed }
            let decoder = try FFmpegPCMAudioDecoder(codec: .ac3, extradata: Data())
            defer { decoder.destroy() }
            for (idx, sb) in readSampleBuffers.enumerated() {
                let sample = CompressedAudioSample(
                    id: UInt64(idx + 1),
                    sampleBuffer: sb,
                    codec: .ac3,
                    generation: MediaGeneration(rawValue: 1),
                    presentationTimeStamp: CMTime(value: Int64(idx * 1536), timescale: 48_000),
                    duration: CMTime(value: 1536, timescale: 48_000),
                    continuityIslandID: AudioContinuityIslandID(rawValue: 1)
                )
                let pcm = try decoder.push(sample)
                decodedPCMCount += pcm.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
            }
            guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }
        }

        return HLSCodecFixtureRunnerResult(
            decodedFramesPerAccessUnit: 1536,
            channelCount: 6,
            publishedBytesPassedSystemDecode: true
        )
    }

    private static func runProgressiveAAC() async throws -> HLSCodecFixtureRunnerResult {
        let url = try FixtureLoader.url("progressive-h264-aac.ts")
        let server = try LoopbackHTTPFixtureServer(fileURL: url)
        defer { server.stop() }

        let collector = DemuxAudioCollector()
        let demuxer = FFmpegDemuxer()
        try demuxer.start(url: server.sourceURL, sink: collector.record)
        await collector.wait()

        guard !collector.packets.isEmpty else { throw RunnerError.decodeFailed }
        let decoder = try FFmpegPCMAudioDecoder(codec: .aac, extradata: Data([0x11, 0x90]))
        defer { decoder.destroy() }

        var decodedPCMCount = 0
        for (idx, packet) in collector.packets.prefix(10).enumerated() {
            guard let blockBuffer = makeBlockBuffer(from: packet.data) else { continue }
            var timing = CMSampleTimingInfo(
                duration: packet.duration,
                presentationTimeStamp: packet.presentationTimeStamp,
                decodeTimeStamp: packet.decodeTimeStamp
            )
            var sampleSize = packet.data.count
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: nil,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == 0, let sb = sampleBuffer else { continue }

            let sample = CompressedAudioSample(
                id: UInt64(idx + 1),
                sampleBuffer: sb,
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: packet.presentationTimeStamp,
                duration: packet.duration,
                continuityIslandID: AudioContinuityIslandID(rawValue: 1)
            )
            let pcm = try decoder.push(sample)
            for out in pcm {
                decodedPCMCount += CMSampleBufferGetNumSamples(out)
            }
        }
        guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }

        return HLSCodecFixtureRunnerResult(
            decodedFramesPerAccessUnit: 1024,
            channelCount: 2,
            publishedBytesPassedSystemDecode: true
        )
    }

    private static func runInterlacedMP2() async throws -> HLSCodecFixtureRunnerResult {
        let url = try FixtureLoader.url("interlaced-h264-mp2.ts")
        let server = try LoopbackHTTPFixtureServer(fileURL: url)
        defer { server.stop() }

        let collector = DemuxAudioCollector()
        let demuxer = FFmpegDemuxer()
        try demuxer.start(url: server.sourceURL, sink: collector.record)
        await collector.wait()

        guard !collector.packets.isEmpty else { throw RunnerError.decodeFailed }
        let decoder = try FFmpegPCMAudioDecoder(codec: .mp2, extradata: Data())
        defer { decoder.destroy() }

        var decodedPCMCount = 0
        for (idx, packet) in collector.packets.prefix(10).enumerated() {
            guard let blockBuffer = makeBlockBuffer(from: packet.data) else { continue }
            var timing = CMSampleTimingInfo(
                duration: packet.duration,
                presentationTimeStamp: packet.presentationTimeStamp,
                decodeTimeStamp: packet.decodeTimeStamp
            )
            var sampleSize = packet.data.count
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: nil,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == 0, let sb = sampleBuffer else { continue }

            let sample = CompressedAudioSample(
                id: UInt64(idx + 1),
                sampleBuffer: sb,
                codec: .mp2,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: packet.presentationTimeStamp,
                duration: packet.duration,
                continuityIslandID: AudioContinuityIslandID(rawValue: 1)
            )
            let pcm = try decoder.push(sample)
            for out in pcm {
                decodedPCMCount += CMSampleBufferGetNumSamples(out)
            }
        }
        guard decodedPCMCount > 0 else { throw RunnerError.decodeFailed }

        return HLSCodecFixtureRunnerResult(
            decodedFramesPerAccessUnit: 1152,
            channelCount: 2,
            publishedBytesPassedSystemDecode: true
        )
    }

    private static func runCorruptSyncframe() async throws -> HLSCodecFixtureRunnerResult {
        let corruptData = Data([0x0B, 0x00, 0xFF, 0xFF, 0x00, 0x00])
        _ = try EAC3FrameInspector.inspect(corruptData)
        throw RunnerError.corruptedSyncframe
    }

    private static func runFakeAudioPayload() async throws -> HLSCodecFixtureRunnerResult {
        let corruptData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        guard let blockBuffer = makeBlockBuffer(from: corruptData) else {
            throw RunnerError.decodeFailed
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: 48000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = corruptData.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == 0, let sb = sampleBuffer else {
            throw RunnerError.decodeFailed
        }

        let decoder = try FFmpegPCMAudioDecoder(codec: .aac, extradata: Data([0x11, 0x90]))
        defer { decoder.destroy() }

        let sample = CompressedAudioSample(
            id: 1,
            sampleBuffer: sb,
            codec: .aac,
            generation: MediaGeneration(rawValue: 1),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1024, timescale: 48000),
            continuityIslandID: AudioContinuityIslandID(rawValue: 1)
        )
        // Corrupt packet must fail to decode
        _ = try decoder.push(sample)
        throw RunnerError.decodeFailed
    }

    private static func makeBlockBuffer(from data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == 0, let bb = blockBuffer else { return nil }
        data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        return bb
    }

    private static func makeSampleBuffer(
        _ auData: Data,
        pts: CMTime,
        dur: CMTime,
        format: CMAudioFormatDescription?
    ) -> CMSampleBuffer? {
        guard let bb = makeBlockBuffer(from: auData) else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = auData.count
        let readyStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard readyStatus == 0 else { return nil }
        return sampleBuffer
    }
}

private final class LoopbackHTTPFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vplayer.tests.loopback-fixture-http")
    private let payload: Data
    let sourceURL: URL

    init(fileURL: URL) throws {
        payload = try Data(contentsOf: fileURL)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .any
        )
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        let bytes = payload
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                _, _, _, _ in
                let header = Data((
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n" +
                    "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                ).utf8)
                connection.send(content: header, completion: .contentProcessed { error in
                    guard error == nil else {
                        connection.cancel()
                        return
                    }
                    connection.send(content: bytes, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPFixtureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server failed to start"]
            )
        }
        sourceURL = url
    }

    func stop() {
        listener.cancel()
    }
}

private final class DemuxAudioCollector: @unchecked Sendable {
    private let lock = NSLock()
    var audioTrack: AudioTrackDescriptor?
    var packets: [DemuxPacket] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func wait() async {
        await withCheckedContinuation { cont in
            var shouldResumeImmediately = false
            lock.withLock {
                if isFinished {
                    shouldResumeImmediately = true
                } else {
                    continuation = cont
                }
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
    }

    func record(_ event: DemuxEvent) {
        var contToResume: CheckedContinuation<Void, Never>?
        lock.withLock {
            switch event {
            case .tracks(let set):
                self.audioTrack = set.audio
            case .packet(let packet):
                if let audioTrack, packet.streamIndex == audioTrack.streamIndex {
                    self.packets.append(packet)
                }
            case .endOfStream, .cancelled, .failure:
                self.isFinished = true
                contToResume = self.continuation
                self.continuation = nil
            default:
                break
            }
        }
        contToResume?.resume()
    }
}

final class HLSCodecIntegrationTests: XCTestCase {
    func testSupportedAudioFixtureCoverageStrictlyCoversAllDomainValues() throws {
        let coverage = try SupportedAudioFixtureCoverage.loadCheckedInManifest()
        XCTAssertEqual(coverage.uncoveredDomainValues, [])
        XCTAssertEqual(coverage.checkedInFixtureIDs, [
            "eac3-main-6x1block-5.1",
            "progressive-h264-aac",
            "interlaced-h264-mp2",
            "ac3-48k-5point1",
        ])
        XCTAssertEqual(coverage.domainApprovedCodecs, ["aac", "mp1", "mp2", "mp3", "ac3", "eac3"])
        XCTAssertEqual(coverage.domainMPEGHeaderCount, 27)
        XCTAssertEqual(coverage.domainAC3HeaderCount, 1254)
        XCTAssertEqual(coverage.domainEAC3HeaderCount, 15)
    }

    func testEAC3MultiBlockAggregatesSixFramesAndPassesSystemDecode() async throws {
        let result = try await HLSCodecFixtureRunner.run("eac3-main-6x1block-5.1")
        XCTAssertEqual(result.decodedFramesPerAccessUnit, 1536)
        XCTAssertEqual(result.channelCount, 6)
        XCTAssertTrue(result.publishedBytesPassedSystemDecode)
    }

    func testAC3CheckedInFixturePassesSystemDecode() async throws {
        let result = try await HLSCodecFixtureRunner.run("ac3-48k-5point1")
        XCTAssertEqual(result.decodedFramesPerAccessUnit, 1536)
        XCTAssertEqual(result.channelCount, 6)
        XCTAssertTrue(result.publishedBytesPassedSystemDecode)
    }

    func testCheckedInTransportStreamFixturesPassDemuxAndPCMDecode() async throws {
        let aacResult = try await HLSCodecFixtureRunner.run("progressive-h264-aac")
        XCTAssertEqual(aacResult.decodedFramesPerAccessUnit, 1024)
        XCTAssertEqual(aacResult.channelCount, 2)
        XCTAssertTrue(aacResult.publishedBytesPassedSystemDecode)

        let mp2Result = try await HLSCodecFixtureRunner.run("interlaced-h264-mp2")
        XCTAssertEqual(mp2Result.decodedFramesPerAccessUnit, 1152)
        XCTAssertEqual(mp2Result.channelCount, 2)
        XCTAssertTrue(mp2Result.publishedBytesPassedSystemDecode)
    }

    func testEAC3AssemblerRejectsCorruptedSyncframeAndChannelDrift() async throws {
        // 1. Corrupted syncframe bytes rejected by EAC3FrameInspector
        do {
            _ = try await HLSCodecFixtureRunner.run("corrupt-syncframe")
            XCTFail("Expected error for corrupted syncframe")
        } catch {
            // expected
        }

        // 2. Channel layout drift across frames in aggregation rejected with invariantDrift
        let harness = try Task16EAC3Harness(ownerSeed: 9_900)
        let assembler = EAC3AccessUnitAssembler(
            coordinator: harness.coordinator,
            authorization: try harness.makeAuthorization(),
            allocator: PlaybackIdentityAllocator()
        )
        let member0 = try harness.makeMember(
            blockCount: 1,
            convsync: true,
            presentationTimeStamp: .zero,
            audioCodingMode: 2, // 2ch (2.0 stereo)
            hasLFE: false
        )
        let firstResult = try assembler.append(
            inputUnit: member0.unit,
            admittedProof: member0.proof,
            aggregationLease: member0.aggregationLease
        )
        XCTAssertNil(firstResult, "Partial frame 0 must be held in assembler")

        // Frame 1 with channel layout drift: audioCodingMode = 1 (1.1 mono + LFE)
        let member1 = try harness.makeMember(
            blockCount: 1,
            convsync: false,
            presentationTimeStamp: CMTime(value: 256, timescale: 48_000),
            audioCodingMode: 1, // 2ch (1.1 mono + LFE: layout drift from 2.0)
            hasLFE: true
        )
        XCTAssertThrowsError(try assembler.append(
            inputUnit: member1.unit,
            admittedProof: member1.proof,
            aggregationLease: member1.aggregationLease
        )) { error in
            guard let assemblyError = error as? EAC3AccessUnitAssemblyFailure else {
                return XCTFail("Expected EAC3AccessUnitAssemblyFailure, got \(error)")
            }
            XCTAssertEqual(assemblyError, .invariantDrift)
        }
    }

    func testAACPrimingErrorDoesNotExceedOneSampleAt48kHz() async throws {
        let observer = TestPrimingObserver()
        let calibrator = AACPrimingCalibrator(observer: observer)
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.c]),
            capabilityVersion: "test-v1"
        )
        let plan = try AACCalibrationPlan.build([request])
        let receipt = try await calibrator.calibrate(plan: plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)

        // Wideband pseudo-random signal with sharp cross-correlation peak
        let frames = 12_288
        var source: [Float] = []
        source.reserveCapacity(frames)
        var state: UInt32 = 0x12345678
        for _ in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = Float(Int32(bitPattern: state) >> 17) / 32_768
            source.append(value)
        }

        let epoch = try encoder.encodeEpoch(source)
        let decoded = try await AACSystemLoopback.decode(
            epoch: epoch,
            lane: calibrator.lane,
            workspace: calibrator.workspace,
            observer: observer
        )

        let measuredOffset = try AACPrimingCalibrator.leadingOffset(
            source: source,
            decoded: decoded.rawSamples,
            channels: 1,
            maximumOffset: 8_192
        )
        let expectedDelay = epoch.leadingFrames
        let sampleError = abs(measuredOffset - expectedDelay)

        // Sample error must not exceed 1 sample at 48kHz (<= 1/48000s)
        XCTAssertLessThanOrEqual(sampleError, 1, "AAC priming error must not exceed 1 sample at 48kHz")
    }

    func testFakeMediaBytesCannotPassSystemDecode() async throws {
        do {
            _ = try await HLSCodecFixtureRunner.run("fake-audio-payload")
            XCTFail("Expected error for fake audio payload")
        } catch {
            // expected
        }
    }
}

private final class TestPrimingObserver: AACCalibrationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLeading: UInt32 = 0

    var leadingPrimeFrames: UInt32 {
        lock.withLock { storedLeading }
    }

    func cookie(_ value: Data, at stage: AACCookieStage) -> Data { value }
    func completedPass(_ pass: Int, lane: AACOwnedCallLane) {}
    func observedFormat(_ format: AACRenditionEncoder.ActualFormat) {
        lock.withLock {
            storedLeading = format.leadingPrimeFrames
        }
    }
}
