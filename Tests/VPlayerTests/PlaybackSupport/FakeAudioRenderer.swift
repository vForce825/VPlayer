// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
@testable import VPlayerPlayback

final class FakeAudioRenderer: AudioRenderer, @unchecked Sendable {
    struct Snapshot: Sendable {
        let operations: [String]
        let enqueuedFormatIDs: [AudioFormatID]
        let enqueuedPTS: [CMTime]
        let requestCount: Int
        let stopRequestCount: Int
        let observationStartCount: Int
        let observationStopCount: Int
        let readinessCheckCount: Int
    }

    let identity: AudioRendererIdentity
    let mediaKind: AudioRendererMediaKind

    private let lock = NSLock()
    private var ready = false
    private var sufficient = false
    private var maximumEnqueuesPerReadyCallback = Int.max
    private var enqueuesSinceReadyCallback = 0
    private var enqueueResults: [AudioRendererEnqueueResult] = []
    private var readyHandler: (@Sendable () -> Void)?
    private var eventHandler: (@Sendable (AudioRendererEvent) -> Void)?
    private var operations: [String] = []
    private var enqueuedFormatIDs: [AudioFormatID] = []
    private var enqueuedPTS: [CMTime] = []
    private var requestCount = 0
    private var stopRequestCount = 0
    private var observationStartCount = 0
    private var observationStopCount = 0
    private var readinessCheckCount = 0
    private var attached = false

    init(identity: UInt64, mediaKind: AudioRendererMediaKind) {
        self.identity = AudioRendererIdentity(rawValue: identity)
        self.mediaKind = mediaKind
    }

    var isReadyForMoreMediaData: Bool {
        withLock {
            readinessCheckCount += 1
            return ready && enqueuesSinceReadyCallback < maximumEnqueuesPerReadyCallback
        }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        withLock { sufficient }
    }

    func configureReadiness(
        ready: Bool,
        sufficient: Bool = false,
        maximumEnqueuesPerCallback: Int = .max
    ) {
        withLock {
            self.ready = ready
            self.sufficient = sufficient
            maximumEnqueuesPerReadyCallback = maximumEnqueuesPerCallback
            enqueuesSinceReadyCallback = 0
        }
    }

    func configureEnqueueResults(_ results: [AudioRendererEnqueueResult]) {
        withLock { enqueueResults = results }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) throws -> AudioRendererEnqueueResult {
        let formatID = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map(CMFormatDescriptionGetMediaSubType) ?? 0
        return try withLock {
            guard attached else {
                throw PlaybackCoreError.audioRendererFailed("fake.not-attached")
            }
            let expectedPCM = mediaKind == .linearPCM
            guard (formatID == kAudioFormatLinearPCM) == expectedPCM else {
                throw PlaybackCoreError.audioRendererFailed("fake.mixed-media")
            }
            let scriptedResult = enqueueResults.isEmpty ? nil : enqueueResults.removeFirst()
            guard scriptedResult != .backpressured,
                  ready,
                  enqueuesSinceReadyCallback < maximumEnqueuesPerReadyCallback else {
                return .backpressured
            }
            operations.append("enqueue")
            enqueuedFormatIDs.append(formatID)
            enqueuedPTS.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            enqueuesSinceReadyCallback += 1
            return .accepted
        }
    }

    func flush() {
        withLock { operations.append("flush") }
    }

    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void) {
        withLock {
            operations.append("request")
            requestCount += 1
            readyHandler = handler
        }
    }

    func stopRequestingMediaData() {
        withLock {
            operations.append("stopRequest")
            stopRequestCount += 1
            readyHandler = nil
        }
    }

    func startObserving(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void) {
        withLock {
            operations.append("observe")
            observationStartCount += 1
            eventHandler = handler
        }
    }

    func stopObserving() {
        withLock {
            operations.append("stopObserve")
            observationStopCount += 1
            eventHandler = nil
        }
    }

    func fireReady() {
        let handler = withLock { () -> (@Sendable () -> Void)? in
            enqueuesSinceReadyCallback = 0
            return readyHandler
        }
        handler?()
    }

    func markAttached() {
        withLock { attached = true }
    }

    func emit(_ event: AudioRendererEvent) {
        withLock { eventHandler }?(event)
    }

    func captureEventHandler() -> (@Sendable (AudioRendererEvent) -> Void)? {
        withLock { eventHandler }
    }

    func captureReadyHandler() -> (@Sendable () -> Void)? {
        withLock { readyHandler }
    }

    var snapshot: Snapshot {
        withLock {
            Snapshot(
                operations: operations,
                enqueuedFormatIDs: enqueuedFormatIDs,
                enqueuedPTS: enqueuedPTS,
                requestCount: requestCount,
                stopRequestCount: stopRequestCount,
                observationStartCount: observationStartCount,
                observationStopCount: observationStopCount,
                readinessCheckCount: readinessCheckCount
            )
        }
    }

    @discardableResult
    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class FakeAudioRendererFactory: AudioRendererFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var nextIdentity: UInt64 = 1
    private var renderers: [FakeAudioRenderer] = []
    private var createError: PlaybackCoreError?
    private var nextCreateErrors: [(AudioRendererMediaKind, PlaybackCoreError)] = []

    func makeRenderer(mediaKind: AudioRendererMediaKind) throws -> any AudioRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let index = nextCreateErrors.firstIndex(where: { $0.0 == mediaKind }) {
            throw nextCreateErrors.remove(at: index).1
        }
        if let createError { throw createError }
        let renderer = FakeAudioRenderer(identity: nextIdentity, mediaKind: mediaKind)
        nextIdentity += 1
        renderers.append(renderer)
        return renderer
    }

    func configureCreateError(_ error: PlaybackCoreError?) {
        lock.withLock { createError = error }
    }

    func configureNextCreateError(
        _ error: PlaybackCoreError,
        for mediaKind: AudioRendererMediaKind
    ) {
        lock.withLock { nextCreateErrors.append((mediaKind, error)) }
    }

    var snapshot: [FakeAudioRenderer] {
        lock.lock()
        defer { lock.unlock() }
        return renderers
    }
}

final class FakeAudioSynchronizer: AudioRenderSynchronizing, @unchecked Sendable {
    struct Removal: @unchecked Sendable {
        let renderer: any AudioRenderer
        let time: CMTime
        let completion: @Sendable (Bool) -> Void
    }

    private let lock = NSLock()
    private var clockTime = CMTime.zero
    private var currentTimeReads = 0
    private var currentRate: Float = 0
    private var attached: [AudioRendererIdentity] = []
    private var operations: [String] = []
    private var rateChanges: [(Float, CMTime)] = []
    private var removals: [Removal] = []
    private var attachError: PlaybackCoreError?
    private var nextAttachError: PlaybackCoreError?

    func currentTime() -> CMTime {
        withLock {
            currentTimeReads += 1
            return clockTime
        }
    }
    var rate: Float { withLock { currentRate } }

    func setCurrentTime(_ value: CMTime) {
        withLock { clockTime = value }
    }

    func attach(_ renderer: any AudioRenderer) throws {
        try withLock {
            if let nextAttachError {
                self.nextAttachError = nil
                throw nextAttachError
            }
            if let attachError { throw attachError }
            operations.append("attach:\(renderer.identity.rawValue)")
            attached.append(renderer.identity)
        }
        (renderer as? FakeAudioRenderer)?.markAttached()
    }

    func configureAttachError(_ error: PlaybackCoreError?) {
        withLock { attachError = error }
    }

    func configureNextAttachError(_ error: PlaybackCoreError) {
        withLock { nextAttachError = error }
    }

    func remove(
        _ renderer: any AudioRenderer,
        at time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        withLock {
            operations.append("remove:\(renderer.identity.rawValue)")
            removals.append(Removal(renderer: renderer, time: time, completion: completion))
        }
    }

    func setRate(_ rate: Float, time: CMTime) {
        withLock {
            operations.append("rate:\(rate)")
            currentRate = rate
            clockTime = time
            rateChanges.append((rate, time))
        }
    }

    func completeRemoval(index: Int = 0, didRemove: Bool = true) {
        let completion = withLock { removals[index].completion }
        completion(didRemove)
    }

    func releaseRemoval(index: Int = 0) {
        withLock { removals.remove(at: index) }
    }

    var operationSnapshot: [String] { withLock { operations } }
    var attachedSnapshot: [AudioRendererIdentity] { withLock { attached } }
    var rateSnapshot: [(Float, CMTime)] { withLock { rateChanges } }
    var removalCount: Int { withLock { removals.count } }
    var currentTimeReadCount: Int { withLock { currentTimeReads } }

    @discardableResult
    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class FakePCMAudioDecoder: PCMAudioDecoding, @unchecked Sendable {
    typealias PushBody = @Sendable (CompressedAudioSample) throws -> [CMSampleBuffer]

    private let lock = NSLock()
    private let pushBody: PushBody
    private var pushError: PlaybackCoreError?
    private var pushedIDs: [UInt64] = []
    private var flushCount = 0
    private var destroyCount = 0

    init(pushBody: @escaping PushBody) {
        self.pushBody = pushBody
    }

    func push(_ sample: CompressedAudioSample) throws -> [CMSampleBuffer] {
        let error = withLock { () -> PlaybackCoreError? in
            pushedIDs.append(sample.id)
            return pushError
        }
        if let error { throw error }
        return try pushBody(sample)
    }

    func configurePushError(_ error: PlaybackCoreError?) {
        withLock { pushError = error }
    }

    func flush() { withLock { flushCount += 1 } }
    func destroy() { withLock { destroyCount += 1 } }

    var pushedIDSnapshot: [UInt64] { withLock { pushedIDs } }
    var flushCountSnapshot: Int { withLock { flushCount } }
    var destroyCountSnapshot: Int { withLock { destroyCount } }

    @discardableResult
    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakePCMAudioDecoderFactory: PCMAudioDecoderFactory, @unchecked Sendable {
    struct Creation: Sendable, Equatable {
        let codec: VPlayerPlayback.AudioCodec
        let extradata: Data
    }

    private let lock = NSLock()
    var createError: PlaybackCoreError?
    var pushBody: FakePCMAudioDecoder.PushBody
    private var decoders: [FakePCMAudioDecoder] = []
    private var creations: [Creation] = []

    init(pushBody: @escaping FakePCMAudioDecoder.PushBody) {
        self.pushBody = pushBody
    }

    func makeDecoder(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data
    ) throws -> any PCMAudioDecoding {
        if let createError { throw createError }
        let decoder = FakePCMAudioDecoder(pushBody: pushBody)
        lock.withLock {
            creations.append(Creation(codec: codec, extradata: extradata))
            decoders.append(decoder)
        }
        return decoder
    }

    var snapshot: [FakePCMAudioDecoder] {
        lock.lock()
        defer { lock.unlock() }
        return decoders
    }

    var creationSnapshot: [Creation] {
        lock.withLock { creations }
    }
}

final class FakeFFmpegAudioDecoderAPI: FFmpegAudioDecoderAPI, @unchecked Sendable {
    struct OutputScript: Sendable {
        let samples: [Float]
        let frames: Int
        let rate: Int32
        let channels: Int32
        let channelOrder: VPFFChannelOrder
        let mask: UInt64?

        init(
            samples: [Float],
            frames: Int,
            rate: Int32,
            channels: Int32,
            channelOrder: VPFFChannelOrder,
            mask: UInt64?
        ) {
            self.samples = samples
            self.frames = frames
            self.rate = rate
            self.channels = channels
            self.channelOrder = channelOrder
            self.mask = mask
        }

        static func stereo(frames: Int) -> OutputScript {
            OutputScript(
                samples: [Float](repeating: 0, count: frames * 2),
                frames: frames,
                rate: 48_000,
                channels: 2,
                channelOrder: VPFF_CHANNEL_ORDER_NATIVE,
                mask: 3
            )
        }
    }

    private final class Handle: FFmpegAudioDecoderHandle, @unchecked Sendable {
        private weak var owner: FakeFFmpegAudioDecoderAPI?
        private let receiver: @Sendable (BorrowedFFmpegPCMFrame) -> Void
        private var destroyed = false

        init(
            owner: FakeFFmpegAudioDecoderAPI,
            receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
        ) {
            self.owner = owner
            self.receiver = receiver
        }

        func push(_ bytes: Data, token: Int64) -> Int32 {
            guard !destroyed, let owner else { return FFmpegPCMAudioDecoder.destroyedErrorCode }
            return owner.push(bytes: bytes, token: token, receiver: receiver)
        }

        func flush() { owner?.recordFlush() }

        func destroy() {
            guard !destroyed else { return }
            destroyed = true
            owner?.recordDestroy()
        }
    }

    var outputScripts: [[OutputScript]] = []
    var overrideToken: Int64?
    var overrideABIVersion: UInt32?
    var overrideStructSize: UInt32?
    var pushResult: Int32 = 0
    private let lock = NSLock()
    private var tokens: [Int64] = []
    private var allocated: [(UnsafeMutablePointer<Float>, Int)] = []
    private var flushes = 0
    private var destroys = 0

    deinit {
        for (pointer, _) in allocated { pointer.deallocate() }
    }

    func create(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws -> any FFmpegAudioDecoderHandle {
        _ = codec
        _ = extradata
        return Handle(owner: self, receiver: receiver)
    }

    private func push(
        bytes: Data,
        token: Int64,
        receiver: @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) -> Int32 {
        _ = bytes
        lock.lock()
        tokens.append(token)
        let scripts = outputScripts.isEmpty ? [] : outputScripts.removeFirst()
        let callbackToken = overrideToken ?? token
        let result = pushResult
        lock.unlock()

        for script in scripts {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: script.samples.count)
            pointer.initialize(from: script.samples, count: script.samples.count)
            lock.lock()
            allocated.append((pointer, script.samples.count))
            lock.unlock()
            receiver(BorrowedFFmpegPCMFrame(
                interleaved: UnsafePointer(pointer),
                frameCount: script.frames,
                sampleRate: script.rate,
                channels: script.channels,
                token: callbackToken,
                abiVersion: overrideABIVersion ?? VPFF_AUDIO_DECODER_ABI_VERSION,
                structSize: overrideStructSize ?? UInt32(MemoryLayout<VPFFPCMFrame>.stride),
                channelOrder: script.channelOrder,
                hasChannelLayoutMask: script.mask == nil ? 0 : 1,
                reserved: (0, 0, 0),
                channelLayoutMask: script.mask ?? 0
            ))
        }
        return result
    }

    func mutateLastBorrowedMemory() {
        lock.lock()
        let copied = allocated
        lock.unlock()
        for (pointer, count) in copied {
            pointer.update(repeating: 99, count: count)
        }
    }

    fileprivate func recordFlush() { lock.lock(); flushes += 1; lock.unlock() }
    fileprivate func recordDestroy() { lock.lock(); destroys += 1; lock.unlock() }
    var pushedTokens: [Int64] { lock.lock(); defer { lock.unlock() }; return tokens }
    var flushCount: Int { lock.lock(); defer { lock.unlock() }; return flushes }
    var destroyCount: Int { lock.lock(); defer { lock.unlock() }; return destroys }
}

final class FakeAudioRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AudioOutputRouteSnapshot) -> Void)?
    private var startCount = 0
    private var stopCount = 0
    private var resampleCount = 0
    private var nextResampleSnapshot: AudioOutputRouteSnapshot?
    private let initialCategory: AudioOutputRouteCategory

    init(initialCategory: AudioOutputRouteCategory = .other) {
        self.initialCategory = initialCategory
    }

    func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void) {
        lock.lock()
        self.handler = handler
        startCount += 1
        lock.unlock()
        handler(AudioOutputRouteSnapshot(
            category: initialCategory,
            reason: .initial,
            revision: 0
        ))
    }

    func stop() {
        lock.lock()
        handler = nil
        stopCount += 1
        lock.unlock()
    }

    func emit(_ snapshot: AudioOutputRouteSnapshot) {
        lock.lock()
        let copied = handler
        lock.unlock()
        copied?(snapshot)
    }

    func setNextResampleSnapshot(_ snapshot: AudioOutputRouteSnapshot) {
        lock.withLock { nextResampleSnapshot = snapshot }
    }

    func resample(reason _: AudioRouteChangeReason) {
        let delivery = lock.withLock { () -> (
            (@Sendable (AudioOutputRouteSnapshot) -> Void)?,
            AudioOutputRouteSnapshot?
        ) in
            resampleCount += 1
            defer { nextResampleSnapshot = nil }
            return (handler, nextResampleSnapshot)
        }
        if let snapshot = delivery.1 { delivery.0?(snapshot) }
    }

    var resampleCountSnapshot: Int { lock.withLock { resampleCount } }
}

final class FakeAudioFormatSupportChecker:
    SystemAudioDecodeCapabilityChecking,
    PCMOutputFormatValidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    var compressedSupported = true
    var pcmSupported = true
    var requireRouteMatchingFormat = false
    private var checks: [(AudioRoute, AudioOutputCategory)] = []
    private var formatIDs: [AudioFormatID] = []

    func supportsDecoding(formatID: AudioFormatID) -> Bool {
        lock.withLock { compressedSupported }
    }

    func isValidPCMOutput(_ format: CMAudioFormatDescription) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks.append((.ffmpegPCM, .none))
        let formatID = CMFormatDescriptionGetMediaSubType(format)
        formatIDs.append(formatID)
        if requireRouteMatchingFormat {
            guard formatID == kAudioFormatLinearPCM else { return false }
        }
        return pcmSupported
    }

    var checkSnapshot: [(AudioRoute, AudioOutputCategory)] {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    var formatIDSnapshot: [AudioFormatID] {
        lock.lock()
        defer { lock.unlock() }
        return formatIDs
    }
}

final class FakeCoreAudioDecodeCapabilityChecker:
    SystemAudioDecodeCapabilityChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    var supported = true
    private var formatIDs: [AudioFormatID] = []

    func supportsDecoding(formatID: AudioFormatID) -> Bool {
        lock.withLock {
            formatIDs.append(formatID)
            return supported
        }
    }

    var formatIDSnapshot: [AudioFormatID] {
        lock.withLock { formatIDs }
    }
}

final class FakePCMOutputFormatValidator: PCMOutputFormatValidating, @unchecked Sendable {
    private let lock = NSLock()
    var supported = true
    private var formatIDs: [AudioFormatID] = []

    func isValidPCMOutput(_ format: CMAudioFormatDescription) -> Bool {
        lock.withLock {
            formatIDs.append(CMFormatDescriptionGetMediaSubType(format))
            return supported
        }
    }

    var formatIDSnapshot: [AudioFormatID] {
        lock.withLock { formatIDs }
    }
}
