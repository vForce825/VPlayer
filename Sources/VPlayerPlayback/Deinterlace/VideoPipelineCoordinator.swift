// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

protocol YADIFFrameProcessing: AnyObject, Sendable, PlaybackTunable {
    func reset(to generation: MediaGeneration)
    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    )
    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    )
}

extension YADIFProcessor: YADIFFrameProcessing {
    func apply(_ tuning: PlaybackTuning) {
        setMaximumPendingFrames(tuning.deinterlaceBufferFrames)
    }
}

/// Synchronous callbacks into `PlaybackPipeline`.
///
/// Every callback and every mutating `VideoPipelineCoordinator` method must run on the
/// playback serial executor. `schedule` is the sole exception: it moves asynchronous
/// probe completion work back onto that executor before coordinator state is touched.
struct VideoPipelineCoordinatorHooks: Sendable {
    enum PlaybackResetScope: Sendable, Equatable {
        /// A real media discontinuity or format epoch may legitimately restart
        /// timestamps from an earlier value.
        case timeline
        /// Rebuilding only the decoder keeps the current live media timeline.
        case decoderSession
    }

    let closeAdmission: @Sendable () -> Void
    let advanceGeneration: @Sendable () -> MediaGeneration
    let resetPlayback: @Sendable (MediaGeneration, Int, PlaybackResetScope) -> Void
    let reopenAdmission: @Sendable () -> Void
    let routeDidChange: @Sendable (Int) -> Void
    let deliver: @Sendable ([VideoPresentationFrame], MediaGeneration) -> Void
    let fail: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
}

final class VideoPipelineCoordinator: @unchecked Sendable {
    private static let maximumClassificationProbeAttempts = 3
    private static let maximumDecoderSessionRestarts = 4
    // A healthy stream produces at most a short burst of undecodable access
    // units. A run this long means the reference chain is gone, which no amount
    // of further per-frame dropping repairs.
    private static let maximumConsecutivePerFrameFailures = 8

    private let decoder: any VideoDecoding
    private let passthrough: any VideoFrameProcessing
    private let yadif: any YADIFFrameProcessing
    private let probe: (any LumaScanProbing)?
    private let fieldReader = FieldMetadataReader()
    private let hooks: VideoPipelineCoordinatorHooks
    private let rawReadinessRequirementOverride: Int?
    private let metrics: PlaybackMetrics?
    private let signposts: PlaybackSignposts?

    private var generation: MediaGeneration
    private var classifier: ScanTypeClassifier
    private var normalizer: PresentationTimestampNormalizer
    private var videoFormat: CMVideoFormatDescription?
    private var previousProbeBuffer: CVPixelBuffer?
    private var classificationProbeObservationCount = 0
    private var nextProbeSubmissionID: UInt64 = 0
    private var activeProbeSubmissionID: UInt64?
    private var decoderConfigured = false
    private var waitingForRandomAccess = true
    private var routeEpoch: UInt64 = 0
    // Decode failures since the last frame that actually decoded.
    private var consecutiveDecoderSessionFailures = 0
    private var consecutivePerFrameDecodeFailures = 0
    private var stopped = false

    private(set) var route = DeinterlaceRoute.rawWhileClassifying

    var requiredVideoFrameCount: Int {
        // One completed YADIF job yields the two field-rate presentation frames
        // needed to open readiness. The processor's three-frame reference window
        // is an input requirement, not a presentation-queue requirement.
        route == .metalYADIF2x ? 2 : (rawReadinessRequirementOverride ?? 1)
    }

    init(
        decoder: any VideoDecoding,
        passthrough: any VideoFrameProcessing,
        yadif: any YADIFFrameProcessing,
        probe: (any LumaScanProbing)?,
        initialGeneration: MediaGeneration,
        classifierConfiguration: ScanClassifierConfiguration = .init(),
        rawReadinessRequirementOverride: Int? = nil,
        metrics: PlaybackMetrics? = nil,
        signposts: PlaybackSignposts? = nil,
        hooks: VideoPipelineCoordinatorHooks
    ) {
        self.decoder = decoder
        self.passthrough = passthrough
        self.yadif = yadif
        self.probe = probe
        generation = initialGeneration
        classifier = ScanTypeClassifier(
            generation: initialGeneration,
            configuration: classifierConfiguration
        )
        normalizer = PresentationTimestampNormalizer(generation: initialGeneration)
        self.rawReadinessRequirementOverride = rawReadinessRequirementOverride.map {
            max(1, $0)
        }
        self.metrics = metrics
        self.signposts = signposts
        self.hooks = hooks
        metrics?.update(scanType: .unknown)
        metrics?.update(activeRoute: .rawWhileClassifying)
    }

    func replaceFormat(_ format: CMVideoFormatDescription) {
        guard !stopped else { return }
        performTrueFormatChange(format: format, reopenAdmission: true)
    }

    func beginDiscontinuity() {
        guard !stopped else { return }
        performTrueFormatChange(format: nil, reopenAdmission: false)
    }

    func installFormatForCurrentGeneration(_ format: CMVideoFormatDescription) {
        guard !stopped else { return }
        videoFormat = format
        decoderConfigured = false
        waitingForRandomAccess = true
    }

    private func performTrueFormatChange(
        format: CMVideoFormatDescription?,
        reopenAdmission: Bool
    ) {
        hooks.closeAdmission()
        if decoderConfigured {
            guard performTrueFormatDrainStep(decoder.finishDelayedFrames) else { return }
            guard performTrueFormatDrainStep(decoder.waitForAsynchronousFrames) else { return }
        }

        let oldGeneration = generation
        generation = hooks.advanceGeneration()
        routeEpoch &+= 1
        route = .rawWhileClassifying
        metrics?.update(scanType: .unknown)
        metrics?.update(activeRoute: .rawWhileClassifying)
        classifier.reset(generation: generation)
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: oldGeneration)
        previousProbeBuffer = nil
        classificationProbeObservationCount = 0
        activeProbeSubmissionID = nil
        videoFormat = format
        decoderConfigured = false
        waitingForRandomAccess = true
        hooks.resetPlayback(generation, requiredVideoFrameCount, .timeline)
        decoder.invalidate()
        if reopenAdmission {
            hooks.reopenAdmission()
        }
    }

    @discardableResult
    func handle(accessUnit: CompressedVideoAccessUnit) -> Bool {
        guard !stopped else { return false }
        guard accessUnit.generation == generation else {
            metrics?.recordStaleGenerationDrop()
            return false
        }
        if waitingForRandomAccess {
            guard accessUnit.isRandomAccess, let videoFormat else { return false }
            do {
                try decoder.configure(format: videoFormat, generation: generation)
                decoderConfigured = true
                waitingForRandomAccess = false
            } catch let failure as VideoDecoderFailure {
                recordDecodeFailureDiagnostic(failure)
                hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
                return false
            } catch {
                hooks.fail(.videoDecode(-1), generation)
                return false
            }
        }

        do {
            try decoder.decode(accessUnit, flags: ._EnableAsynchronousDecompression)
            return true
        } catch let failure as VideoDecoderFailure {
            handleSubmissionFailure(failure, generation: generation)
            return false
        } catch {
            hooks.fail(.videoDecode(-1), generation)
            return false
        }
    }

    /// Submission failures reach here from two directions — a decoder that
    /// rejects a unit on the caller's thread, and the asynchronous
    /// `submissionFailure` event from one that hands submission to its own
    /// queue. Both mean the same thing, so both get the same recovery.
    private func handleSubmissionFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) {
        if failure == .backpressureTimeout {
            restartDecoderAfterBackpressureTimeout()
            return
        }
        recordDecodeFailureDiagnostic(failure)
        if Self.isPerFrameDecodeFailure(failure) {
            handlePerFrameDecodeFailure(failure, generation: generation)
            return
        }
        if Self.requiresDecoderSessionRestart(failure) {
            restartDecoderAfterSessionFailure(failure, generation: generation)
            return
        }
        hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
    }

    func handle(decoder event: VideoDecoderEvent) {
        guard !stopped else { return }
        switch event {
        case let .frame(frame):
            guard frame.generation == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            // A frame arrived, so whatever broke decoding has cleared.
            consecutiveDecoderSessionFailures = 0
            consecutivePerFrameDecodeFailures = 0
            observe(frame, probe: nil)
            guard frame.generation == generation else { return }
            submitProbe(for: frame)
            for normalized in normalizer.push(frame, discontinuity: false) {
                process(normalized)
            }
        case let .submissionFailure(failure, eventGeneration):
            guard eventGeneration == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            handleSubmissionFailure(failure, generation: eventGeneration)
        case .submissionCompleted:
            // Admission accounting belongs to PlaybackPipeline. A completion
            // carries no decoded media and must not affect routing or recovery.
            break
        case let .recoverableFailure(failure, eventGeneration):
            guard eventGeneration == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            recordDecodeFailureDiagnostic(failure)
            if Self.requiresDecoderSessionRestart(failure) {
                restartDecoderAfterSessionFailure(failure, generation: eventGeneration)
                return
            }
            handlePerFrameDecodeFailure(failure, generation: eventGeneration)
        case let .fatalFailure(failure, eventGeneration):
            guard eventGeneration == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            recordDecodeFailureDiagnostic(failure)
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        }
    }

    func applyTuning(_ tuning: PlaybackTuning) {
        guard !stopped else { return }
        yadif.apply(tuning)
        decoder.setTuning(tuning)
    }

    func stop(emergency: Bool) {
        guard !stopped else { return }
        stopped = true
        hooks.closeAdmission()
        if emergency {
            let oldGeneration = generation
            generation = hooks.advanceGeneration()
            route = .rawWhileClassifying
            routeEpoch &+= 1
            metrics?.update(scanType: .unknown)
            metrics?.update(activeRoute: .rawWhileClassifying)
            classifier.reset(generation: generation)
            normalizer.reset(generation: generation)
            passthrough.reset(to: generation)
            yadif.reset(to: generation)
            probe?.stop(generation: oldGeneration)
            previousProbeBuffer = nil
            classificationProbeObservationCount = 0
            activeProbeSubmissionID = nil
            decoderConfigured = false
            waitingForRandomAccess = true
            hooks.resetPlayback(generation, requiredVideoFrameCount, .timeline)
            decoder.invalidate()
            return
        }

        if decoderConfigured {
            do { try decoder.finishDelayedFrames() } catch {}
            do { try decoder.waitForAsynchronousFrames() } catch {}
        }
        decoder.invalidate()
        decoderConfigured = false
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: generation)
        previousProbeBuffer = nil
        classificationProbeObservationCount = 0
        activeProbeSubmissionID = nil
    }

    private static func diagnosticName(for failure: VideoDecoderFailure) -> (String, Int32) {
        switch failure {
        case let .badData(status): ("badData", status)
        case let .malfunction(status): ("malfunction", status)
        case let .sessionCreate(status): ("sessionCreate", status)
        case .softwareDecoder: ("softwareDecoder", 0)
        case .backpressureTimeout: ("backpressureTimeout", 0)
        }
    }

    private func recordDecodeFailureDiagnostic(_ failure: VideoDecoderFailure) {
        let (kind, status) = Self.diagnosticName(for: failure)
        metrics?.recordVideoDecodeFailure(kind: kind, status: status)
    }

    // Corrupt or unreferenced access units: the session is healthy, this one
    // frame cannot be decoded, and the next one usually can. Dropping is right.
    private static func isPerFrameDecodeFailure(
        _ failure: VideoDecoderFailure
    ) -> Bool {
        switch failure {
        case let .badData(status):
            status == kVTVideoDecoderBadDataErr
                || status == VideoToolboxDecoder.legacyCodecBadDataErr
                || status == VideoToolboxDecoder.transientNoFrameStatus
                || status == kVTVideoDecoderReferenceMissingErr
        default:
            false
        }
    }

    // A malfunctioning or withdrawn decompression session does not heal by
    // itself: every later submission fails identically. Counting these as
    // per-frame drops turned one bad moment into permanently frozen video while
    // access units kept arriving — the session has to be rebuilt instead.
    private static func requiresDecoderSessionRestart(
        _ failure: VideoDecoderFailure
    ) -> Bool {
        switch failure {
        case let .malfunction(status):
            status == kVTVideoDecoderMalfunctionErr
                || status == kVTSessionMalfunctionErr
                || status == kVTVideoDecoderNotAvailableNowErr
                || status == kVTVideoDecoderRemovedErr
        default:
            false
        }
    }

    private static func isRecoverableDecodeSubmissionFailure(
        _ failure: VideoDecoderFailure
    ) -> Bool {
        isPerFrameDecodeFailure(failure) || requiresDecoderSessionRestart(failure)
    }

    // One undecodable access unit is normal on a live feed and is simply
    // dropped. A sustained run is not: it means the decoder has lost its
    // reference chain, and every later frame fails identically no matter how
    // many are discarded — video froze while access units kept arriving. Rebuild
    // and resume from the next random-access point instead.
    private func handlePerFrameDecodeFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) {
        metrics?.recordVideoDrop(source: .decoderRecoverable)
        consecutivePerFrameDecodeFailures += 1
        guard consecutivePerFrameDecodeFailures > Self.maximumConsecutivePerFrameFailures else {
            return
        }
        consecutivePerFrameDecodeFailures = 0
        restartDecoderAfterSessionFailure(failure, generation: generation)
    }

    // Rebuilding costs the frames up to the next random-access point, so a
    // session that will not come back must be reported rather than restarted
    // forever: silently dropping every frame is the failure mode this replaces.
    private func restartDecoderAfterSessionFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) {
        consecutiveDecoderSessionFailures += 1
        guard consecutiveDecoderSessionFailures <= Self.maximumDecoderSessionRestarts else {
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
            return
        }
        metrics?.recordVideoDrop(source: .decoderRecoverable)
        restartDecoderAfterBackpressureTimeout()
    }

    private func performTrueFormatDrainStep(
        _ operation: () throws -> Void
    ) -> Bool {
        do {
            try operation()
            return true
        } catch let failure as VideoDecoderFailure {
            if Self.isRecoverableDecodeSubmissionFailure(failure) {
                metrics?.recordVideoDrop(source: .decoderRecoverable)
                return true
            }
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        } catch {
            hooks.fail(.videoDecode(-1), generation)
        }
        return false
    }

    private func observe(_ frame: DecodedVideoFrame, probe sample: ContentProbeSample?) {
        let observation = ScanObservation(
            generation: frame.generation,
            parser: frame.parserMetadata,
            decodedFields: fieldReader.read(
                formatDescription: videoFormat,
                pixelBuffer: frame.pixelBuffer
            ),
            probe: sample,
            presentationTimeStamp: frame.presentationTimeStamp
        )
        guard let change = classifier.observe(observation) else { return }
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    /// Every route decodes the same way — both fields woven into one frame per
    /// coded frame — so a route change only redirects finished frames to a
    /// different processor. Nothing about the decode session changes with it.
    private func applyResolvedRoute() {
        let next = DeinterlaceRoute.resolve(scan: classifier.current)
        guard next != route else { return }
        let token = signposts?.begin(.modeSwitch, correlation: routeEpoch &+ 1)
        defer {
            if let token { signposts?.end(token) }
        }
        route = next
        routeEpoch &+= 1
        metrics?.update(activeRoute: next)
        yadif.reset(to: generation)
        hooks.routeDidChange(requiredVideoFrameCount)
    }

    private func restartDecoderAfterBackpressureTimeout() {
        hooks.closeAdmission()
        let oldGeneration = generation
        generation = hooks.advanceGeneration()
        routeEpoch &+= 1
        classifier.rebasePreservingClassification(generation: generation)
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: oldGeneration)
        previousProbeBuffer = nil
        classificationProbeObservationCount = 0
        activeProbeSubmissionID = nil
        decoderConfigured = false
        waitingForRandomAccess = true
        hooks.resetPlayback(generation, requiredVideoFrameCount, .decoderSession)
        decoder.invalidate()
        hooks.reopenAdmission()
    }

    private func submitProbe(for frame: DecodedVideoFrame) {
        defer { previousProbeBuffer = frame.pixelBuffer }
        guard route == .rawWhileClassifying,
              let probe,
              let previousProbeBuffer else { return }
        let submittedGeneration = generation
        let submittedEpoch = routeEpoch
        if route == .rawWhileClassifying { classificationProbeObservationCount += 1 }
        let shouldResolveStartup = route == .rawWhileClassifying
            && classificationProbeObservationCount
                >= Self.maximumClassificationProbeAttempts
        if activeProbeSubmissionID == nil {
            nextProbeSubmissionID &+= 1
            let submissionID = nextProbeSubmissionID
            activeProbeSubmissionID = submissionID
            let token = signposts?.begin(.scanProbe, correlation: frame.accessUnitID)
            let signposts = signposts
            probe.submit(
                current: frame.pixelBuffer,
                previous: previousProbeBuffer,
                generation: submittedGeneration
            ) { [weak self] result in
                if let token { signposts?.end(token) }
                guard let self else { return }
                hooks.schedule { [weak self] in
                    guard let self else { return }
                    if activeProbeSubmissionID == submissionID {
                        activeProbeSubmissionID = nil
                    }
                    guard !stopped,
                          generation == submittedGeneration,
                          routeEpoch == submittedEpoch else {
                        metrics?.recordStaleGenerationDrop()
                        return
                    }
                    switch result {
                    case let .success(sample):
                        observeSupplementalProbe(frame, sample: sample)
                    case .failure:
                        observeProbeFailure(frame)
                    }
                }
            }
        }
        if shouldResolveStartup, route == .rawWhileClassifying {
            resolveAfterProbeBudget(frame)
        }
    }

    private func observeSupplementalProbe(
        _ frame: DecodedVideoFrame,
        sample: ContentProbeSample
    ) {
        let observation = ScanObservation(
            generation: frame.generation,
            parser: frame.parserMetadata,
            decodedFields: fieldReader.read(
                formatDescription: videoFormat,
                pixelBuffer: frame.pixelBuffer
            ),
            probe: sample,
            presentationTimeStamp: frame.presentationTimeStamp
        )
        guard let change = classifier.observeSupplementalProbe(observation) else { return }
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    private func observeProbeFailure(_ frame: DecodedVideoFrame) {
        let observation = ScanObservation(
            generation: frame.generation,
            parser: frame.parserMetadata,
            decodedFields: fieldReader.read(
                formatDescription: videoFormat,
                pixelBuffer: frame.pixelBuffer
            ),
            probe: nil,
            presentationTimeStamp: frame.presentationTimeStamp
        )
        guard let change = classifier.observeProbeFailure(observation) else { return }
        classificationProbeObservationCount = 0
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    private func resolveAfterProbeBudget(_ frame: DecodedVideoFrame) {
        let observation = ScanObservation(
            generation: frame.generation,
            parser: frame.parserMetadata,
            decodedFields: fieldReader.read(
                formatDescription: videoFormat,
                pixelBuffer: frame.pixelBuffer
            ),
            probe: nil,
            presentationTimeStamp: frame.presentationTimeStamp
        )
        guard let change = classifier.resolveAfterProbeBudget(observation) else { return }
        classificationProbeObservationCount = 0
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    private func process(_ normalized: NormalizedDecodedFrame) {
        let submittedGeneration = generation
        let submittedEpoch = routeEpoch
        let completion: @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void = { [weak self] result in
            guard let self else { return }
            hooks.schedule { [weak self] in
                guard let self,
                      !stopped,
                      generation == submittedGeneration,
                      routeEpoch == submittedEpoch else {
                    self?.metrics?.recordStaleGenerationDrop()
                    return
                }
                switch result {
                case let .success(frames):
                    hooks.deliver(frames, submittedGeneration)
                case .failure:
                    metrics?.recordVideoDrop(source: .deinterlaceFailure)
                    hooks.deliver([], submittedGeneration)
                }
            }
        }

        if route == .metalYADIF2x {
            let order: ResolvedFieldOrder
            if case let .interlaced(o) = classifier.current {
                order = o
            } else if case let .progressiveSegmentedFrame(o?) = classifier.current {
                order = o
            } else {
                order = ResolvedFieldOrder(
                    parity: .top,
                    confidence: .assumed,
                    source: .contentProbe
                )
            }
            yadif.submit(
                normalized: normalized,
                order: order,
                discontinuity: false,
                completion: completion
            )
            return
        }

        passthrough.submit(normalizedFrame(from: normalized), completion: completion)
    }

    private func normalizedFrame(from normalized: NormalizedDecodedFrame) -> DecodedVideoFrame {
        let frame = normalized.frame
        return DecodedVideoFrame(
            accessUnitID: frame.accessUnitID,
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: normalized.presentationTimeStamp,
            duration: normalized.frameDuration,
            generation: frame.generation,
            parserMetadata: frame.parserMetadata,
            formatMetadata: frame.formatMetadata
        )
    }
}
