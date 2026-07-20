// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox
@testable import VPlayerPlayback

final class FakeControllerPipeline: PlaybackPipelineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (PlaybackPipelineEvent) -> Void)?
    private(set) var starts: [URL] = []
    private(set) var pauses: [(Bool, UInt64)] = []
    private(set) var stopCount = 0
    private(set) var completedStopCount = 0
    private(set) var algorithms: [DeinterlaceAlgorithm] = []
    var stopAutomaticallyCompletes = true
    private var stopContinuation: CheckedContinuation<Void, Never>?
    let presentationContext: PlaybackPresentationContext?

    init(presentationContext: PlaybackPresentationContext? = nil) {
        self.presentationContext = presentationContext
    }

    func install(_ sink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }

    func start(url: URL) {
        lock.withLock { starts.append(url) }
    }

    func setPaused(_ paused: Bool, readinessCycle: UInt64) {
        lock.withLock { pauses.append((paused, readinessCycle)) }
    }

    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) {
        lock.withLock { algorithms.append(algorithm) }
    }

    func stop() async {
        let shouldWait = lock.withLock { () -> Bool in
            stopCount += 1
            return !stopAutomaticallyCompletes
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.withLock { stopContinuation = continuation }
            }
        }
        lock.withLock { completedStopCount += 1 }
    }

    func completeStop() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { stopContinuation = nil }
            return stopContinuation
        }
        continuation?.resume()
    }

    func emit(_ event: PlaybackPipelineEvent) {
        let current = lock.withLock { sink }
        current?(event)
    }

    func snapshot() -> (
        starts: [URL],
        pauses: [(Bool, UInt64)],
        algorithms: [DeinterlaceAlgorithm],
        stopCount: Int,
        completedStopCount: Int,
        isStopWaiting: Bool
    ) {
        lock.withLock {
            (
                starts,
                pauses,
                algorithms,
                stopCount,
                completedStopCount,
                stopContinuation != nil
            )
        }
    }
}

final class FakeControllerPipelineFactory: PlaybackPipelineFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FakeControllerPipeline]
    private var makeCount = 0
    private var selectedAlgorithms: [DeinterlaceAlgorithm] = []

    init(_ pipelines: [FakeControllerPipeline]) {
        queued = pipelines
    }

    func makePipeline(
        selectedAlgorithm: DeinterlaceAlgorithm,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) throws -> any PlaybackPipelineProtocol {
        try lock.withLock {
            guard !queued.isEmpty else { throw PlaybackCoreError.demuxOpen(-99) }
            makeCount += 1
            selectedAlgorithms.append(selectedAlgorithm)
            let pipeline = queued.removeFirst()
            pipeline.install(eventSink)
            return pipeline
        }
    }

    var makeCountSnapshot: Int { lock.withLock { makeCount } }
    var selectedAlgorithmsSnapshot: [DeinterlaceAlgorithm] {
        lock.withLock { selectedAlgorithms }
    }
}

final class FakePipelineDemuxer: MediaDemuxing, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (DemuxEvent) -> Void)?
    private(set) var startedURLs: [URL] = []
    private(set) var cancelCount = 0
    var startError: PlaybackCoreError?

    func start(url: URL, sink: @escaping @Sendable (DemuxEvent) -> Void) throws {
        if let startError { throw startError }
        lock.withLock {
            startedURLs.append(url)
            self.sink = sink
        }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func emit(_ event: DemuxEvent) {
        let current = lock.withLock { sink }
        current?(event)
    }

    func snapshot() -> (startedURLs: [URL], cancelCount: Int) {
        lock.withLock { (startedURLs, cancelCount) }
    }
}

final class FakePipelineVideoProcessor: VideoFrameProcessing, @unchecked Sendable {
    private typealias PendingCompletion = @Sendable () -> Void

    private let lock = NSLock()
    let requiredInputFrameCount: Int
    private(set) var resetGenerations: [MediaGeneration] = []
    private(set) var submittedMetadata: [VideoParserMetadata] = []
    private var automaticallyCompletes = true
    private var pendingCompletions: [PendingCompletion] = []

    init(requiredInputFrameCount: Int = 1) {
        self.requiredInputFrameCount = requiredInputFrameCount
    }

    func reset(to generation: MediaGeneration) {
        lock.withLock { resetGenerations.append(generation) }
    }

    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (Result<[VideoPresentationFrame], PlaybackFailure>) -> Void
    ) {
        let result = Result<[VideoPresentationFrame], PlaybackFailure>.success([
            VideoPresentationFrame(
                storage: .pixelBuffer(frame.pixelBuffer),
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                generation: frame.generation,
                sequenceNumber: frame.accessUnitID,
                sourceAccessUnitID: frame.accessUnitID,
                formatMetadata: frame.formatMetadata
            ),
        ])
        let shouldComplete = lock.withLock { () -> Bool in
            submittedMetadata.append(frame.parserMetadata)
            if !automaticallyCompletes {
                pendingCompletions.append { completion(result) }
            }
            return automaticallyCompletes
        }
        if shouldComplete { completion(result) }
    }

    func setAutomaticallyCompletes(_ value: Bool) {
        lock.withLock { automaticallyCompletes = value }
    }

    func completePending() {
        let completions = lock.withLock { () -> [PendingCompletion] in
            defer { pendingCompletions.removeAll(keepingCapacity: false) }
            return pendingCompletions
        }
        for completion in completions { completion() }
    }

    func snapshot() -> (resets: [MediaGeneration], metadata: [VideoParserMetadata]) {
        lock.withLock { (resetGenerations, submittedMetadata) }
    }
}

final class FakePipelineYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var resetGenerations: [MediaGeneration] = []
    private(set) var submittedOrders: [ResolvedFieldOrder] = []

    func reset(to generation: MediaGeneration) {
        lock.withLock { resetGenerations.append(generation) }
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        lock.withLock { submittedOrders.append(order) }
        completion(.success([
            VideoPresentationFrame(
                storage: .pixelBuffer(frame.frame.pixelBuffer),
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.fieldDuration,
                generation: frame.frame.generation,
                sequenceNumber: frame.frame.accessUnitID,
                sourceAccessUnitID: frame.frame.accessUnitID,
                formatMetadata: frame.frame.formatMetadata
            ),
        ]))
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        completion(.success([]))
    }
}

final class FakePipelineVideoRenderer: PlaybackVideoRendering, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var frames: [VideoPresentationFrame] = []
    private(set) var flushes: [MediaGeneration] = []
    private(set) var resetCount = 0

    func enqueue(_ frame: VideoPresentationFrame) {
        lock.withLock { frames.append(frame) }
    }

    func flush(to generation: MediaGeneration) {
        lock.withLock {
            flushes.append(generation)
            frames.removeAll(keepingCapacity: true)
        }
    }

    func draw(targetMediaTime _: CMTime, drawable _: any CAMetalDrawable) -> VideoRenderDecision {
        VideoRenderDecision(action: .waiting, sourceAccessUnitID: nil, sequenceNumber: nil, droppedFrameCount: 0)
    }

    func resetPresentationTiming() {
        lock.withLock { resetCount += 1 }
    }

    func snapshot() -> (frames: [VideoPresentationFrame], flushes: [MediaGeneration], resets: Int) {
        lock.withLock { (frames, flushes, resetCount) }
    }
}

final class FakePipelineAudio: AudioRenderPipelineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var ready = false
    var selectedRoute = VPlayerPlayback.AudioRoute.systemCompressed
    private(set) var configured: [(VPlayerPlayback.AudioCodec, MediaGeneration)] = []
    private(set) var samples: [CompressedAudioSample] = []
    private(set) var flushes: [MediaGeneration] = []
    private(set) var stopCount = 0
    var stopAutomaticallyCompletes = true
    var enqueueError: PlaybackCoreError?
    private var flushHandler: (@Sendable (MediaGeneration) -> Void)?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    var isReadyForPlayback: Bool { lock.withLock { ready } }
    var route: VPlayerPlayback.AudioRoute { lock.withLock { selectedRoute } }

    func configure(
        format _: CMAudioFormatDescription,
        codec: VPlayerPlayback.AudioCodec,
        generation: MediaGeneration
    ) throws {
        lock.withLock { configured.append((codec, generation)) }
    }

    func enqueue(_ sample: CompressedAudioSample) throws {
        if let enqueueError { throw enqueueError }
        lock.withLock { samples.append(sample) }
    }

    func flush(to generation: MediaGeneration) {
        let handler = lock.withLock { () -> (@Sendable (MediaGeneration) -> Void)? in
            flushes.append(generation)
            samples.removeAll(keepingCapacity: true)
            return flushHandler
        }
        handler?(generation)
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }

    func stopAwaitingRendererRemoval() async {
        let shouldWait = lock.withLock { () -> Bool in
            stopCount += 1
            return !stopAutomaticallyCompletes
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.withLock { stopContinuations.append(continuation) }
            }
        }
    }

    func completeStop() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { stopContinuations.removeAll(keepingCapacity: false) }
            return stopContinuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func setReady(_ value: Bool) { lock.withLock { ready = value } }

    func setFlushHandler(_ handler: (@Sendable (MediaGeneration) -> Void)?) {
        lock.withLock { flushHandler = handler }
    }

    func snapshot() -> (
        configured: [(VPlayerPlayback.AudioCodec, MediaGeneration)],
        samples: [CompressedAudioSample],
        flushes: [MediaGeneration],
        stops: Int,
        isStopWaiting: Bool
    ) {
        lock.withLock {
            (configured, samples, flushes, stopCount, !stopContinuations.isEmpty)
        }
    }
}

final class FakePipelineClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTime = CMTime.zero
    private(set) var pauses = 0
    private(set) var anchors: [(CMTime, CMTime, Float)] = []

    var currentTime: CMTime { lock.withLock { storedTime } }
    func mediaTime(forHostTime hostTime: CMTime) -> CMTime { hostTime }
    func pause() { lock.withLock { pauses += 1 } }
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        lock.withLock {
            storedTime = mediaTime
            anchors.append((mediaTime, hostTime, rate))
        }
    }
    func setTime(_ time: CMTime) { lock.withLock { storedTime = time } }
    func snapshot() -> (pauses: Int, anchors: [(CMTime, CMTime, Float)]) {
        lock.withLock { (pauses, anchors) }
    }
}

final class FakePlaybackDisplay: PlaybackDisplayControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var operations: [String] = []
    private var clearAutoCompletes = true
    private var clearContinuations: [CheckedContinuation<Void, Never>] = []
    var clearAutomaticallyCompletes: Bool {
        get { lock.withLock { clearAutoCompletes } }
        set { lock.withLock { clearAutoCompletes = newValue } }
    }
    var isClearWaiting: Bool { lock.withLock { !clearContinuations.isEmpty } }
    func pauseSubmission() { lock.withLock { operations.append("pause") } }
    func resumeSubmission() { lock.withLock { operations.append("resume") } }
    func resetPresentationTiming() { lock.withLock { operations.append("reset") } }
    func updateDisplayCriteria(
        formatDescription _: CMFormatDescription,
        outputFrameRate: Float
    ) { lock.withLock { operations.append("criteria:\(outputFrameRate)") } }
    func clearDisplayCriteria() async {
        let shouldWait = lock.withLock {
            operations.append("clear")
            return !clearAutoCompletes
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !clearAutoCompletes else { return true }
                clearContinuations.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func completeClear() {
        let continuations = lock.withLock {
            clearAutoCompletes = true
            let pending = clearContinuations
            clearContinuations.removeAll()
            return pending
        }
        for continuation in continuations { continuation.resume() }
    }
    func snapshot() -> [String] { lock.withLock { operations } }
}

final class FakePlaybackAssemblerBuilder: PlaybackAssemblerBuilding, @unchecked Sendable {
    final class Video: VideoAccessUnitAssembling {
        private(set) var packets: [DemuxPacket] = []
        private(set) var resetTracks: [DemuxTrackSet] = []
        var pushError: PlaybackCoreError?
        var drainError: PlaybackCoreError?
        private(set) var drainCount = 0
        func push(_ packet: DemuxPacket) throws {
            if let pushError { throw pushError }
            packets.append(packet)
        }
        func drain() throws {
            drainCount += 1
            if let drainError { throw drainError }
        }
        func reset(for trackSet: DemuxTrackSet) throws { resetTracks.append(trackSet) }
    }

    final class Audio: AudioSampleAssembling {
        private(set) var packets: [DemuxPacket] = []
        private(set) var resetTracks: [DemuxTrackSet] = []
        var pushError: PlaybackCoreError?
        var drainError: PlaybackCoreError?
        private(set) var drainCount = 0
        func push(_ packet: DemuxPacket) throws {
            if let pushError { throw pushError }
            packets.append(packet)
        }
        func drain() throws {
            drainCount += 1
            if let drainError { throw drainError }
        }
        func reset(for trackSet: DemuxTrackSet) throws { resetTracks.append(trackSet) }
    }

    let video = Video()
    let audio = Audio()

    func makeVideo(
        trackSet _: DemuxTrackSet,
        generationProvider _: @escaping @Sendable () -> MediaGeneration,
        eventSink _: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState _: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling { video }

    func makeAudio(
        trackSet _: DemuxTrackSet,
        generationProvider _: @escaping @Sendable () -> MediaGeneration,
        eventSink _: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState _: AssemblyFormatState
    ) throws -> any AudioSampleAssembling { audio }
}

final class AssemblerBackedPlaybackBuilder: PlaybackAssemblerBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var formatFingerprints: [MediaFormatFingerprint] = []

    func makeVideo(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (VideoAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any VideoAccessUnitAssembling {
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            var sps = AssemblerTestFixtures.h264SPS
            if bytes.first == 2 { sps[3] = 0x20 }
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: AssemblerTestFixtures.h264AccessUnit(sps: sps),
                pts: pts,
                dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                keyFrame: true
            ))
        }
        return try CompressedVideoAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: { [weak self] event in
                if case let .format(_, fingerprint) = event {
                    self?.lock.withLock { self?.formatFingerprints.append(fingerprint) }
                }
                eventSink(event)
            },
            parserFactory: parserFactory,
            formatState: formatState
        )
    }

    func makeAudio(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping @Sendable () -> MediaGeneration,
        eventSink: @escaping @Sendable (AudioAssemblerEvent) -> Void,
        formatState: AssemblyFormatState
    ) throws -> any AudioSampleAssembling {
        try CompressedAudioAssembler(
            trackSet: trackSet,
            generationProvider: generationProvider,
            eventSink: { [weak self] event in
                if case let .format(_, _, fingerprint) = event {
                    self?.lock.withLock { self?.formatFingerprints.append(fingerprint) }
                }
                eventSink(event)
            },
            formatState: formatState
        )
    }

    var formatFingerprintsSnapshot: [MediaFormatFingerprint] {
        lock.withLock { formatFingerprints }
    }
}

enum PlaybackFakeMedia {
    static func tracks(videoExtradata: Data = Data(), audioExtradata: Data = Data([0x12, 0x10])) -> DemuxTrackSet {
        DemuxTrackSet(
            selectedProgramID: 1,
            video: VideoTrackDescriptor(
                streamIndex: 100,
                codec: .h264,
                timeBase: MediaRational(num: 1, den: 90_000)!,
                width: 1_920,
                height: 1_080,
                videoDelay: 0,
                extradata: videoExtradata
            ),
            audio: AudioTrackDescriptor(
                streamIndex: 101,
                codec: .aac,
                timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000,
                channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                extradata: audioExtradata
            )
        )
    }

    static func videoFormat() throws -> CMVideoFormatDescription {
        var value: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.videoFormatDescription(status) }
        return value
    }

    static func audioFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var value: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &value
        )
        guard status == noErr, let value else { throw PlaybackCoreError.audioFormatDescription(status) }
        return value
    }

    static func audioSample(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        duration: CMTime
    ) throws -> CompressedAudioSample {
        let format = try audioFormat()
        let buffer = try SampleBufferBuilder.makeAudio(
            data: Data([0x00]),
            formatDescription: format,
            presentationTimeStamp: pts,
            variableFramesInPacket: UInt32(max(1, duration.seconds * 48_000))
        )
        return CompressedAudioSample(
            id: id,
            sampleBuffer: buffer,
            codec: .aac,
            generation: generation,
            presentationTimeStamp: pts,
            duration: duration
        )
    }

    static func videoPacket(marker: UInt8, pts: Int64 = 90_000) -> DemuxPacket {
        DemuxPacket(
            streamIndex: 100,
            codec: .video(.h264),
            data: Data([marker]),
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            decodeTimeStamp: CMTime(value: pts - 3_000, timescale: 90_000),
            duration: CMTime(value: 3_000, timescale: 90_000),
            isKey: true,
            isCorrupt: false
        )
    }

    static func audioPacket(id: UInt8) -> DemuxPacket {
        let payload = Data([id, 0xAA])
        let frameLength = 7 + payload.count
        var data = Data([
            0xFF, 0xF1, 0x4C,
            UInt8(0x80 | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
        data.append(payload)
        return DemuxPacket(
            streamIndex: 101,
            codec: .audio(.aac),
            data: data,
            presentationTimeStamp: CMTime(value: Int64(id) * 1_920, timescale: 90_000),
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )
    }

    static func accessUnit(id: UInt64, generation: MediaGeneration, randomAccess: Bool) throws -> CompressedVideoAccessUnit {
        let format = try videoFormat()
        let buffer = try SampleBufferBuilder.makeVideo(
            data: Data([0x00, 0x00, 0x00, 0x01]),
            formatDescription: format,
            presentationTimeStamp: CMTime(value: Int64(id), timescale: 25),
            decodeTimeStamp: .invalid,
            duration: CMTime(value: 1, timescale: 25),
            isRandomAccess: randomAccess
        )
        return CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: buffer,
            generation: generation,
            isRandomAccess: randomAccess,
            parserMetadata: parserMetadata(interlaced: false)
        )
    }

    static func decodedFrame(
        id: UInt64,
        generation: MediaGeneration,
        pts: CMTime,
        interlaced: Bool
    ) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PlaybackCoreError.videoDecode(status)
        }
        let sourcePTS90k = pts.isNumeric
            ? UInt64(max(
                0,
                CMTimeConvertScale(pts, timescale: 90_000, method: .default).value
            ))
            : nil
        return DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 25),
            generation: generation,
            parserMetadata: VideoParserMetadata(
                fieldOrder: interlaced ? .tb : .progressive,
                pictureStructure: .frame,
                isInterlaced: interlaced,
                repeatFirstField: false,
                topFieldFirst: interlaced,
                sourcePTS90k: sourcePTS90k
            ),
            formatMetadata: VideoFormatMetadata(
                dimensions: CMVideoDimensions(width: 16, height: 16),
                bitDepth: 8,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(masteringDisplayColorVolume: nil, contentLightLevelInfo: nil)
            )
        )
    }

    static func parserMetadata(interlaced: Bool) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: interlaced ? .tb : .progressive,
            pictureStructure: .frame,
            isInterlaced: interlaced,
            repeatFirstField: false,
            topFieldFirst: interlaced,
            sourcePTS90k: nil
        )
    }
}
