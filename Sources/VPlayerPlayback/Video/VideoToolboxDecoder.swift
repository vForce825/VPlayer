// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

private final class DecodeSubmissionWindow: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private let waitInterval: TimeInterval
    private var counts: [VTSessionID: Int] = [:]

    init(capacity: Int, waitInterval: TimeInterval) {
        self.capacity = max(1, capacity)
        self.waitInterval = max(0, waitInterval)
    }

    func claim(sessionID: VTSessionID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: waitInterval)
        while counts[sessionID, default: 0] >= capacity {
            guard condition.wait(until: deadline) else { return false }
        }
        counts[sessionID, default: 0] += 1
        return true
    }

    func release(sessionID: VTSessionID) {
        condition.lock()
        if let count = counts[sessionID], count > 1 {
            counts[sessionID] = count - 1
        } else {
            counts.removeValue(forKey: sessionID)
        }
        condition.broadcast()
        condition.unlock()
    }

    func reset(sessionID: VTSessionID) {
        condition.lock()
        counts.removeValue(forKey: sessionID)
        condition.broadcast()
        condition.unlock()
    }
}

/// Bounds how much undecoded work may queue ahead of the decode session.
///
/// Submission runs off the playback executor, so nothing upstream slows down
/// when decode does — which is the point, but it also means a decoder that has
/// fallen behind would accumulate access units until memory ran out. The bound
/// converts that into dropped frames, and drops to the next random-access point
/// rather than an arbitrary unit: every frame between a gap and the next
/// keyframe references pictures that were never decoded, so submitting them
/// only produces a run of reference-missing failures.
final class DecodeSubmissionBacklog: @unchecked Sendable {
    enum Admission: Equatable {
        case submit
        case skip
    }

    private let lock = NSLock()
    private var depth: Int
    private var pending = 0
    private var skipping = false
    private var maximumPending = 0

    init(depth: Int) {
        self.depth = max(1, depth)
    }

    func admit(isRandomAccess: Bool) -> Admission {
        lock.withLock {
            if skipping {
                // Resume only once the decoder has actually caught up; resuming
                // at the bound just overflows again on the next unit.
                guard isRandomAccess, pending <= depth / 2 else { return .skip }
                skipping = false
            } else if pending >= depth {
                skipping = true
                return .skip
            }
            pending += 1
            maximumPending = max(maximumPending, pending)
            return .submit
        }
    }

    func complete() {
        lock.withLock { pending = max(0, pending - 1) }
    }

    /// A rebuilt session decodes from its own first random-access unit, so a
    /// skip left over from the previous one would drop a whole further GOP.
    func resumeAfterSessionChange() {
        lock.withLock { skipping = false }
    }

    func setDepth(_ newDepth: Int) {
        lock.withLock { depth = max(1, newDepth) }
    }

    var maximumDepth: Int {
        lock.withLock { maximumPending }
    }
}

/// Written on the submission queue, read on the playback executor when an
/// output comes back: the executor can no longer read the session itself.
private final class SessionIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: (id: VTSessionID, generation: MediaGeneration)?

    func set(id: VTSessionID, generation: MediaGeneration) {
        lock.withLock { identity = (id, generation) }
    }

    func clear() {
        lock.withLock { identity = nil }
    }

    func matches(id: VTSessionID, generation: MediaGeneration) -> Bool {
        lock.withLock { identity?.id == id && identity?.generation == generation }
    }
}

/// Cancels submissions queued against a session that is being replaced or
/// invalidated.
///
/// Without it, tearing a session down would have to wait behind every access
/// unit already queued for it — on the playback executor, which is the thread
/// this whole change exists to keep free. Cancelling is also the more faithful
/// outcome: those units belong to the generation being abandoned, so their
/// output would be discarded on arrival anyway.
final class SubmissionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    var value: UInt64 { lock.withLock { current } }

    func bump() {
        lock.withLock { current &+= 1 }
    }
}

private final class DecodeSubmissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let releaseAction: @Sendable () -> Void

    init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    func releaseOnce() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { releaseAction() }
    }
}

/// Emits the admission-release event exactly once, including paths where
/// VideoToolbox never produces an image callback.
private final class DecodeCompletionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let accessUnitID: UInt64
    private let generation: MediaGeneration
    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void

    init(
        accessUnitID: UInt64,
        generation: MediaGeneration,
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.accessUnitID = accessUnitID
        self.generation = generation
        self.executor = executor
        self.eventSink = eventSink
    }

    func schedule() {
        guard let event = takeEvent() else { return }
        let eventSink = eventSink
        executor.submit { eventSink(event) }
    }

    /// Used when output handling is already on the playback executor, so the
    /// completion cannot overtake the frame or failure produced by that output.
    func deliverIsolated() {
        guard let event = takeEvent() else { return }
        eventSink(event)
    }

    private func takeEvent() -> VideoDecoderEvent? {
        lock.withLock {
            guard !completed else { return nil }
            completed = true
            return .submissionCompleted(
                accessUnitID: accessUnitID,
                generation: generation
            )
        }
    }
}

/// Keeps callback-owned completions reachable from teardown. VideoToolbox may
/// discard pending callbacks when a session is invalidated, so relying on the
/// callback alone would leak admission credit for those access units.
private final class DecodeCompletionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [VTSessionID: [ObjectIdentifier: DecodeCompletionLease]] = [:]

    func insert(_ lease: DecodeCompletionLease, sessionID: VTSessionID) {
        lock.withLock {
            leases[sessionID, default: [:]][ObjectIdentifier(lease)] = lease
        }
    }

    func remove(_ lease: DecodeCompletionLease, sessionID: VTSessionID) {
        lock.withLock {
            leases[sessionID]?.removeValue(forKey: ObjectIdentifier(lease))
            if leases[sessionID]?.isEmpty == true {
                leases.removeValue(forKey: sessionID)
            }
        }
    }

    func completeAll(sessionID: VTSessionID) {
        let pending = lock.withLock {
            leases.removeValue(forKey: sessionID).map { Array($0.values) } ?? []
        }
        for lease in pending { lease.schedule() }
    }
}

public final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
    // Legacy Codec Manager bad-data status; VTErrors.h lists it beside
    // kVTVideoDecoderBadDataErr and tvOS hardware decoders still return it.
    static let legacyCodecBadDataErr: OSStatus = -8_969
    // The tvOS 18 simulator can report an isolated positive callback status
    // with no image after a corrupt access unit. VTErrors.h defines real
    // VideoToolbox failures as negative values, so preserve this exact observed
    // value as a recoverable per-frame data failure without masking other codes.
    static let transientNoFrameStatus: OSStatus = 1
    private static let logger = Logger(
        subsystem: "com.vplayer.playback",
        category: "VideoToolboxDecoder"
    )

    private struct ActiveSession {
        let session: any VideoToolboxSession
        let id: VTSessionID
        let generation: MediaGeneration
    }

    private struct DecodeToken: @unchecked Sendable {
        let accessUnitID: UInt64
        let generation: MediaGeneration
        let parserMetadata: VideoParserMetadata
    }

    /// Pixel formats this pipeline can actually turn into a Metal texture.
    ///
    /// Ordered by preference and deliberately narrower than what VideoToolbox
    /// will produce: `VideoFormatMetadataReader` rejects anything else, so
    /// asking for a format that is not on this list buys a decode session that
    /// fails on its first frame.
    static let renderablePixelFormats: [UInt32] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    ]

    private struct ClassifiedFailure {
        let failure: VideoDecoderFailure
        let isRecoverable: Bool
    }

    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let api: any VideoToolboxAPI
    private let compatibilityCheck: PixelBufferCompatibilityCheck
    private let submissionWindow: DecodeSubmissionWindow
    private let metrics: PlaybackMetrics?
    private let signposts: PlaybackSignposts?

    /// Everything below is confined to `submissionQueue`.
    ///
    /// Handing an access unit to VideoToolbox blocks — on a busy decoder for
    /// tens of milliseconds per frame — so it cannot run on the playback
    /// executor that also admits demuxed packets, completes deinterlace jobs and
    /// updates readiness. Saturating that executor stops the read path and takes
    /// the whole session down; here it costs frames instead.
    private let submissionQueue: DispatchQueue
    private var active: ActiveSession?
    private var submissionsSinceDepthSample = 0

    private let submissionEpoch: SubmissionEpoch
    private let sessionIdentity = SessionIdentityBox()
    private let completionRegistry = DecodeCompletionRegistry()
    private let backlog: DecodeSubmissionBacklog
    private let tuningBox = TuningBox()

    public convenience init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.init(
            executor: executor,
            eventSink: eventSink,
            api: SystemVideoToolboxAPI(),
            compatibilityCheck: VideoFormatMetadataReader.systemCompatibilityCheck,
            metrics: nil,
            signposts: nil
        )
    }

    convenience init(
        executor: PlaybackSerialExecutor,
        tuning: PlaybackTuning,
        diagnostics: (metrics: PlaybackMetrics, signposts: PlaybackSignposts),
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.init(
            executor: executor,
            eventSink: eventSink,
            api: SystemVideoToolboxAPI(),
            compatibilityCheck: VideoFormatMetadataReader.systemCompatibilityCheck,
            tuning: tuning,
            metrics: diagnostics.metrics,
            signposts: diagnostics.signposts
        )
    }

    init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void,
        api: any VideoToolboxAPI,
        compatibilityCheck: @escaping PixelBufferCompatibilityCheck = VideoFormatMetadataReader.systemCompatibilityCheck,
        maximumInFlightDecodeCount: Int = 8,
        inFlightWaitInterval: TimeInterval = 0.25,
        tuning: PlaybackTuning = .default,
        submissionQueue: DispatchQueue = DispatchQueue(
            label: "org.vplayer.playback.decode.submit",
            qos: .userInitiated
        ),
        submissionEpoch: SubmissionEpoch = SubmissionEpoch(),
        metrics: PlaybackMetrics? = nil,
        signposts: PlaybackSignposts? = nil
    ) {
        self.submissionQueue = submissionQueue
        self.executor = executor
        self.eventSink = eventSink
        self.api = api
        self.compatibilityCheck = compatibilityCheck
        submissionWindow = DecodeSubmissionWindow(
            capacity: maximumInFlightDecodeCount,
            waitInterval: inFlightWaitInterval
        )
        backlog = DecodeSubmissionBacklog(depth: tuning.decodeSubmissionQueueDepth)
        self.submissionEpoch = submissionEpoch
        tuningBox.value = tuning
        self.metrics = metrics
        self.signposts = signposts
    }

    public func setTuning(_ tuning: PlaybackTuning) {
        tuningBox.value = tuning
        backlog.setDepth(tuning.decodeSubmissionQueueDepth)
        // The output pool floor is fixed when the session is built, so a change
        // reaches the decoder at the next configure rather than immediately.
    }

    public func configure(
        format: CMVideoFormatDescription,
        generation: MediaGeneration
    ) throws {
        submissionEpoch.bump()
        backlog.resumeAfterSessionChange()
        try submissionQueue.sync {
            try configureIsolated(format: format, generation: generation)
        }
    }

    private func configureIsolated(
        format: CMVideoFormatDescription,
        generation: MediaGeneration
    ) throws {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        guard subtype == kCMVideoCodecType_H264 ||
              subtype == kCMVideoCodecType_HEVC ||
              subtype == kCMVideoCodecType_MPEG2Video ||
              subtype == kCMVideoCodecType_MPEG4Video else {
            throw VideoDecoderFailure.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)
        }

        let selection = try makeSession(format: format)
        let candidate = selection.session
        let tuning = tuningBox.value
        let outputPoolFloor = tuning.decoderOutputPoolFloor(
            for: CMVideoFormatDescriptionGetDimensions(format)
        )

        // Both fields woven into one frame per coded frame, which is what the
        // deinterlacer takes as input. It is also the decoder default, so a
        // decoder that does not implement the property is already doing this.
        let fieldModeStatus = api.setProperty(
            candidate,
            key: kVTDecompressionPropertyKey_FieldMode as String,
            value: .string(kVTDecompressionProperty_FieldMode_BothFields as String)
        )
        guard fieldModeStatus == noErr || fieldModeStatus == kVTPropertyNotSupportedErr else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.sessionCreate(fieldModeStatus)
        }

        // Interlaced H.264 has no hardware path on Apple silicon, so this
        // stream decodes in software — measured at 54 ms a frame against a
        // 40 ms budget at 25 fps, with the output callback landing exactly when
        // the submitting call returns, which is what a synchronous decode looks
        // like. The software decoder is single-threaded unless asked otherwise.
        let threadCountStatus = api.setProperty(
            candidate,
            key: kVTDecompressionPropertyKey_ThreadCount as String,
            value: .unsigned32(UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount)))
        )
        guard threadCountStatus == noErr || threadCountStatus == kVTPropertyNotSupportedErr else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.sessionCreate(threadCountStatus)
        }

        // Set last, so a decoder that rejects it cannot mask a field-mode
        // failure that says something far more useful. The default pool ages
        // buffers out, and this pipeline legitimately holds a known number of
        // them at once; reallocating an IOSurface per frame is exactly the kind
        // of cost that shows up as submission time.
        let poolStatus = api.setProperty(
            candidate,
            key: kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount as String,
            value: .unsigned32(UInt32(outputPoolFloor))
        )
        guard poolStatus == noErr || poolStatus == kVTPropertyNotSupportedErr else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.sessionCreate(poolStatus)
        }

        let hardware = api.copyProperty(
            candidate,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as String
        )
        guard hardware.status == noErr || hardware.status == kVTPropertyNotSupportedErr else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.sessionCreate(hardware.status)
        }
        guard hardware.status == kVTPropertyNotSupportedErr
            || hardware.value == .boolean(true) else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.softwareDecoder
        }
        // Both tolerances above accept `kVTPropertyNotSupportedErr`, so on their
        // own they prove nothing: a session that never reported its acceleration
        // and one that reported hardware look identical afterwards. Record what
        // actually came back.
        metrics?.recordDecoderSession(
            summary: Self.sessionSummary(
                format: format,
                pixelFormatChoice: selection.choice,
                outputPoolFloor: poolStatus == noErr ? outputPoolFloor : nil,
                fieldModeStatus: fieldModeStatus,
                threadCountStatus: threadCountStatus,
                hardwareStatus: hardware.status,
                hardwareValue: hardware.value
            )
        )

        let previous = active
        active = ActiveSession(
            session: candidate,
            id: candidate.id,
            generation: generation
        )
        sessionIdentity.set(id: candidate.id, generation: generation)
        if let previous {
            completionRegistry.completeAll(sessionID: previous.id)
            submissionWindow.reset(sessionID: previous.id)
            api.invalidate(previous.session)
        }
    }

    private struct SessionSelection {
        let session: any VideoToolboxSession
        let choice: String
    }

    /// Builds the session against the decoder's own output format where that is
    /// something this renderer can map.
    ///
    /// Naming a pixel format constrains the decoder, and a constraint it cannot
    /// meet natively is satisfied by converting every frame on the way out. The
    /// only way to ask what it would have produced is to create the session
    /// unconstrained and read its preference back, so that is the first attempt
    /// and the named formats are the fallback.
    private func makeSession(format: CMVideoFormatDescription) throws -> SessionSelection {
        let decoderSpecification: [String: VTPropertyValue] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: .boolean(true),
        ]
        var attributes: [String: VTPropertyValue] = [
            kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
            kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
        ]
        let candidate = try create(
            format: format,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: attributes
        )
        let preferred = fastestRenderablePixelFormat(of: candidate)
        if let preferred, preferred.isDecoderPreference {
            return SessionSelection(
                session: candidate,
                choice: "native(\(Self.formatName(preferred.format)))"
            )
        }
        // Whatever this session would have produced is not what we can use, and
        // it has served its purpose as a question.
        api.invalidate(candidate)

        // Either the decoder would not say what it prefers, or what it prefers
        // cannot be rendered. Name what it should produce instead.
        let choice: String
        if let preferred {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] =
                .unsigned32(preferred.format)
            choice = "fastestRenderable(\(Self.formatName(preferred.format)))"
        } else {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = .array(
                Self.renderablePixelFormats.map { .unsigned32($0) }
            )
            choice = "listed"
        }
        return SessionSelection(
            session: try create(
                format: format,
                decoderSpecification: decoderSpecification,
                imageBufferAttributes: attributes
            ),
            choice: choice
        )
    }

    private func create(
        format: CMVideoFormatDescription,
        decoderSpecification: [String: VTPropertyValue],
        imageBufferAttributes: [String: VTPropertyValue]
    ) throws -> any VideoToolboxSession {
        let creation = api.createSession(
            format: format,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes
        )
        guard creation.status == noErr, let session = creation.session else {
            if let session = creation.session { api.invalidate(session) }
            throw VideoDecoderFailure.sessionCreate(creation.status)
        }
        return session
    }

    private func fastestRenderablePixelFormat(
        of session: any VideoToolboxSession
    ) -> (format: UInt32, isDecoderPreference: Bool)? {
        let supported = api.copyProperty(
            session,
            key: kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance as String
        )
        guard supported.status == noErr,
              case let .array(entries) = supported.value else { return nil }
        let formats: [UInt32] = entries.compactMap {
            guard case let .unsigned32(value) = $0 else { return nil }
            return value
        }
        guard let best = formats.first(where: { Self.renderablePixelFormats.contains($0) })
        else { return nil }
        return (best, formats.first == best)
    }

    /// Decode outputs handed back by VideoToolbox that are still waiting for the
    /// playback executor to process them. Each one retains a decoder output
    /// buffer, so if this grows and stays high the session runs out of buffers
    /// and the *next* submission blocks — on the very executor whose backlog is
    /// holding them. That is a loop the decoder cannot escape on its own.
    private let outstandingOutputs = OutstandingOutputCounter()

    public func decode(
        _ accessUnit: CompressedVideoAccessUnit,
        flags: VTDecodeFrameFlags
    ) throws {
        let completion = DecodeCompletionLease(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation,
            executor: executor,
            eventSink: eventSink
        )
        guard backlog.admit(isRandomAccess: accessUnit.isRandomAccess) == .submit else {
            metrics?.recordVideoDrop(source: .decodeSubmissionBacklog)
            completion.schedule()
            return
        }
        let epoch = submissionEpoch.value
        let backlog = backlog
        let metrics = metrics
        submissionQueue.async { [weak self] in
            defer {
                backlog.complete()
                metrics?.recordDecodeSubmissionDepth(backlog.maximumDepth)
            }
            guard let self else {
                completion.schedule()
                return
            }
            // The session this unit was meant for has already been torn down;
            // submitting to its replacement would decode a frame whose
            // references were never sent.
            guard submissionEpoch.value == epoch else {
                metrics?.recordStaleGenerationDrop()
                completion.schedule()
                return
            }
            submitIsolated(accessUnit, flags: flags, completion: completion)
        }
    }

    private func submitIsolated(
        _ accessUnit: CompressedVideoAccessUnit,
        flags: VTDecodeFrameFlags,
        completion: DecodeCompletionLease
    ) {
        guard let active, accessUnit.generation == active.generation else {
            completion.schedule()
            return
        }
        let token = DecodeToken(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation,
            parserMetadata: accessUnit.parserMetadata
        )
        let sessionID = active.id
        sampleFramesBeingDecoded(active)
        guard submissionWindow.claim(sessionID: sessionID) else {
            report(.backpressureTimeout, generation: accessUnit.generation)
            completion.schedule()
            return
        }
        let submissionLease = DecodeSubmissionLease { [submissionWindow] in
            submissionWindow.release(sessionID: sessionID)
        }
        completionRegistry.insert(completion, sessionID: sessionID)
        let executor = executor
        var decodeFlags = flags
        decodeFlags.insert(._EnableAsynchronousDecompression)
        // Temporal processing only ever meant the decoder's own deinterlace,
        // which this pipeline does on the GPU instead.
        decodeFlags.remove(._EnableTemporalProcessing)
        let signpostLifetime = PlaybackSignpostLifetime(
            signposts: signposts,
            token: signposts?.begin(.videoToolboxDecode, correlation: accessUnit.id)
        )
        let metrics = metrics
        let submissionStartedAt = ProcessInfo.processInfo.systemUptime
        let status = api.decode(
            active.session,
            sampleBuffer: accessUnit.sampleBuffer,
            flags: decodeFlags,
            frameOptions: nil
        ) { [weak self, outstandingOutputs, completionRegistry] output in
            submissionLease.releaseOnce()
            completionRegistry.remove(completion, sessionID: sessionID)
            // Against the submission's own duration this says what the
            // submission was waiting for. Equal means the decode ran to
            // completion inside the call and the wall time is compute; much
            // longer means the call blocked on something the decoder needed and
            // the decode itself happened afterwards.
            metrics?.recordDecodeCallbackLatency(
                milliseconds: max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - submissionStartedAt) * 1_000
                )
            )
            metrics?.recordDecoderCallback()
            signpostLifetime.finish()
            metrics?.recordDecoderOutputQueued(outstanding: outstandingOutputs.enter())
            executor.submit { [weak self] in
                outstandingOutputs.leave()
                self?.handle(output: output, token: token, sessionID: sessionID)
                completion.deliverIsolated()
            }
        }
        metrics?.recordVideoDecodeSubmission(
            milliseconds: max(
                0,
                (ProcessInfo.processInfo.systemUptime - submissionStartedAt) * 1_000
            )
        )
        guard status == noErr else {
            submissionLease.releaseOnce()
            completionRegistry.remove(completion, sessionID: sessionID)
            signpostLifetime.finish()
            let classified = Self.classify(status)
            if !classified.isRecoverable {
                Self.logger.error(
                    "decode submission failed status=\(status, privacy: .public)"
                )
            }
            report(classified.failure, generation: accessUnit.generation)
            completion.schedule()
            return
        }
    }

    /// Distinguishes a decoder that is slow from one that is merely backed up:
    /// a submission that blocks while the decoder holds nothing is compute,
    /// while one that blocks with a full pipeline is waiting for buffers this
    /// app has not returned yet.
    private func sampleFramesBeingDecoded(_ session: ActiveSession) {
        submissionsSinceDepthSample += 1
        guard submissionsSinceDepthSample >= 4 else { return }
        submissionsSinceDepthSample = 0
        let result = api.copyProperty(
            session.session,
            key: kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded as String
        )
        guard result.status == noErr,
              case let .unsigned32(count) = result.value else { return }
        metrics?.recordFramesBeingDecoded(Int(count))
    }

    private func report(_ failure: VideoDecoderFailure, generation: MediaGeneration) {
        let eventSink = eventSink
        executor.submit { eventSink(.submissionFailure(failure, generation: generation)) }
    }

    /// Flushes, and so waits for units already queued rather than cancelling
    /// them: a caller asking the decoder to emit what it is holding means the
    /// ones it has not been handed yet too. Teardown paths follow this with
    /// `invalidate`, which is where cancellation belongs.
    public func finishDelayedFrames() throws {
        try submissionQueue.sync {
            guard let active else { return }
            let status = api.finishDelayedFrames(active.session)
            guard status == noErr else {
                Self.logger.error(
                    "finish delayed frames failed status=\(status, privacy: .public)"
                )
                throw Self.classify(status).failure
            }
        }
    }

    public func waitForAsynchronousFrames() throws {
        try submissionQueue.sync {
            guard let active else { return }
            let status = api.waitForAsynchronousFrames(active.session)
            guard status == noErr else {
                Self.logger.error(
                    "wait for asynchronous frames failed status=\(status, privacy: .public)"
                )
                throw Self.classify(status).failure
            }
        }
    }

    public func invalidate() {
        submissionEpoch.bump()
        backlog.resumeAfterSessionChange()
        sessionIdentity.clear()
        submissionQueue.sync {
            guard let current = active else { return }
            active = nil
            completionRegistry.completeAll(sessionID: current.id)
            submissionWindow.reset(sessionID: current.id)
            api.invalidate(current.session)
        }
    }

    static func sessionSummary(
        format: CMVideoFormatDescription?,
        pixelFormatChoice: String,
        outputPoolFloor: Int?,
        fieldModeStatus: OSStatus?,
        threadCountStatus: OSStatus? = nil,
        hardwareStatus: OSStatus,
        hardwareValue: VTPropertyValue?
    ) -> String {
        let field = fieldModeStatus.map { $0 == noErr ? "applied" : "unsupported(\($0))" }
            ?? "n/a"
        let threads = threadCountStatus.map {
            $0 == noErr
                ? "threads=\(max(1, ProcessInfo.processInfo.activeProcessorCount))"
                : "threads=unsupported(\($0))"
        } ?? "threads=n/a"
        let hardware: String
        if hardwareStatus == kVTPropertyNotSupportedErr {
            hardware = "unreported"
        } else if hardwareValue == .boolean(true) {
            hardware = "yes"
        } else {
            hardware = "no"
        }
        var codec = "unknown"
        if let format {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            codec = "\(formatName(CMFormatDescriptionGetMediaSubType(format)))"
                + " \(dimensions.width)x\(dimensions.height)"
        }
        let pool = outputPoolFloor.map(String.init) ?? "unsupported"
        return "codec=\(codec) pixelFormat=\(pixelFormatChoice)"
            + " pool=\(pool) fieldMode=\(field) \(threads) hardware=\(hardware)"
    }

    /// Four-character codes read far better than their decimal values in a
    /// metrics blob that is only ever read by a human.
    static func formatName(_ code: UInt32) -> String {
        let characters = (0..<4).compactMap { index -> Character? in
            let byte = UInt8((code >> UInt32((3 - index) * 8)) & 0xFF)
            guard (0x20...0x7E).contains(byte) else { return nil }
            return Character(UnicodeScalar(byte))
        }
        return characters.count == 4 ? String(characters) : String(code)
    }

    private func handle(
        output: VTDecodeOutput,
        token: DecodeToken,
        sessionID: VTSessionID
    ) {
        guard sessionIdentity.matches(id: sessionID, generation: token.generation) else {
            metrics?.recordStaleGenerationDrop()
            return
        }

        guard output.status == noErr else {
            let classified = Self.classify(output.status)
            if !classified.isRecoverable {
                Self.logger.error(
                    "decode callback failed status=\(output.status, privacy: .public) infoFlags=\(output.infoFlags.rawValue, privacy: .public) hasImage=\(output.imageBuffer != nil, privacy: .public)"
                )
            }
            emit(classified, generation: token.generation)
            return
        }
        guard let pixelBuffer = output.imageBuffer else {
            if output.infoFlags.contains(.frameDropped)
                || output.infoFlags.contains(.frameInterrupted) {
                metrics?.recordVideoDrop(source: .decoderSubmission)
                return
            }
            emit(
                Self.classify(kVTVideoDecoderMalfunctionErr),
                generation: token.generation
            )
            return
        }

        do {
            let formatMetadata = try VideoFormatMetadataReader.read(
                from: pixelBuffer,
                compatibilityCheck: compatibilityCheck
            )
            eventSink(.frame(DecodedVideoFrame(
                accessUnitID: token.accessUnitID,
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: output.presentationTimeStamp,
                duration: output.duration,
                generation: token.generation,
                parserMetadata: token.parserMetadata,
                formatMetadata: formatMetadata
            )))
        } catch let failure as VideoDecoderFailure {
            emit(
                ClassifiedFailure(failure: failure, isRecoverable: false),
                generation: token.generation
            )
        } catch {
            emit(
                ClassifiedFailure(
                    failure: .malfunction(kVTVideoDecoderMalfunctionErr),
                    isRecoverable: false
                ),
                generation: token.generation
            )
        }
    }

    private func emit(_ classified: ClassifiedFailure, generation: MediaGeneration) {
        if classified.isRecoverable {
            eventSink(.recoverableFailure(classified.failure, generation: generation))
        } else {
            eventSink(.fatalFailure(classified.failure, generation: generation))
        }
    }

    private static func classify(_ status: OSStatus) -> ClassifiedFailure {
        switch status {
        case kVTVideoDecoderBadDataErr,
             legacyCodecBadDataErr,
             transientNoFrameStatus,
             kVTVideoDecoderReferenceMissingErr:
            return ClassifiedFailure(failure: .badData(status), isRecoverable: true)
        case kVTVideoDecoderUnsupportedDataFormatErr:
            return ClassifiedFailure(failure: .badData(status), isRecoverable: false)
        case kVTVideoDecoderMalfunctionErr,
             kVTSessionMalfunctionErr,
             kVTVideoDecoderNotAvailableNowErr,
             kVTVideoDecoderRemovedErr:
            return ClassifiedFailure(failure: .malfunction(status), isRecoverable: true)
        default:
            return ClassifiedFailure(failure: .malfunction(status), isRecoverable: false)
        }
    }
}

/// Settings arrive on the main actor and are read on the submission queue.
private final class TuningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = PlaybackTuning.default

    var value: PlaybackTuning {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Guarded by its own lock: incremented on the VideoToolbox callback thread and
/// decremented on the playback executor.
private final class OutstandingOutputCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func enter() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func leave() {
        lock.withLock { count = max(0, count - 1) }
    }
}
