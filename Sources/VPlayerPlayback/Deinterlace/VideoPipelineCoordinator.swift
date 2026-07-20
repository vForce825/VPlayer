// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

protocol YADIFFrameProcessing: AnyObject, Sendable {
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

extension YADIFProcessor: YADIFFrameProcessing {}

/// Synchronous callbacks into `PlaybackPipeline`.
///
/// Every callback and every mutating `VideoPipelineCoordinator` method must run on the
/// playback serial executor. `schedule` is the sole exception: it moves asynchronous
/// probe completion work back onto that executor before coordinator state is touched.
struct VideoPipelineCoordinatorHooks: Sendable {
    let closeAdmission: @Sendable () -> Void
    let advanceGeneration: @Sendable () -> MediaGeneration
    let resetPlayback: @Sendable (MediaGeneration, Int) -> Void
    let reopenAdmission: @Sendable () -> Void
    let routeDidChange: @Sendable (Int) -> Void
    let deliver: @Sendable ([VideoPresentationFrame], MediaGeneration) -> Void
    let notice: @Sendable (PlaybackNotice, MediaGeneration) -> Void
    let fail: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
}

final class VideoPipelineCoordinator: @unchecked Sendable {
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
    private var selectedAlgorithm: DeinterlaceAlgorithm
    private var classifier: ScanTypeClassifier
    private var normalizer: PresentationTimestampNormalizer
    private var videoFormat: CMVideoFormatDescription?
    private var previousProbeBuffer: CVPixelBuffer?
    private var decoderConfigured = false
    private var activeConfiguration: VideoDecodeConfiguration?
    private var waitingForRandomAccess = true
    private var routeEpoch: UInt64 = 0
    private var temporalRetrySuppressed = false
    private var temporalNoticeGate = TemporalNoticeGate()
    private let playbackSessionID = PlaybackSessionID(rawValue: UUID())
    private var stopped = false

    private(set) var route = DeinterlaceRoute.rawWhileClassifying

    var selectedDeinterlaceAlgorithm: DeinterlaceAlgorithm {
        selectedAlgorithm
    }

    var requiredVideoFrameCount: Int {
        route == .metalYADIF2x ? 3 : (rawReadinessRequirementOverride ?? 1)
    }

    init(
        decoder: any VideoDecoding,
        passthrough: any VideoFrameProcessing,
        yadif: any YADIFFrameProcessing,
        probe: (any LumaScanProbing)?,
        initialGeneration: MediaGeneration,
        selectedAlgorithm: DeinterlaceAlgorithm,
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
        self.selectedAlgorithm = selectedAlgorithm
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
        activeConfiguration = nil
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
        videoFormat = format
        decoderConfigured = false
        activeConfiguration = nil
        waitingForRandomAccess = true
        hooks.resetPlayback(generation, requiredVideoFrameCount)
        decoder.invalidate()
        if reopenAdmission {
            hooks.reopenAdmission()
        }
    }

    func handle(accessUnit: CompressedVideoAccessUnit) {
        guard !stopped else { return }
        guard accessUnit.generation == generation else {
            metrics?.recordStaleGenerationDrop()
            return
        }
        if waitingForRandomAccess {
            guard accessUnit.isRandomAccess, let videoFormat else { return }
            let targetConfiguration = configuration(for: route)
            do {
                try decoder.configure(
                    format: videoFormat,
                    generation: generation,
                    configuration: targetConfiguration
                )
                decoderConfigured = true
                activeConfiguration = targetConfiguration
                waitingForRandomAccess = false
            } catch let failure as VideoDecoderFailure
                where targetConfiguration == .appleTemporal && failure.isTemporalUnavailable {
                guard configureRawTemporalFallback(format: videoFormat) else { return }
            } catch let failure as VideoDecoderFailure {
                hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
                return
            } catch {
                hooks.fail(.videoDecode(-1), generation)
                return
            }
        }

        do {
            try decoder.decode(accessUnit, flags: ._EnableAsynchronousDecompression)
        } catch let failure as VideoDecoderFailure {
            if failure.isTemporalUnavailable, activeConfiguration == .appleTemporal {
                temporalRetrySuppressed = true
                emitTemporalNoticeOnce()
                switchDecoderConfiguration(
                    to: .rawTemporalFailure,
                    toleratingTemporalDrainFailure: true
                )
                return
            }
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        } catch {
            hooks.fail(.videoDecode(-1), generation)
        }
    }

    func handle(decoder event: VideoDecoderEvent) {
        guard !stopped else { return }
        switch event {
        case let .frame(frame):
            guard frame.generation == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            observe(frame, probe: nil)
            guard frame.generation == generation else { return }
            submitProbe(for: frame)
            for normalized in normalizer.push(frame, discontinuity: false) {
                process(normalized)
            }
        case let .recoverableFailure(failure, eventGeneration),
             let .fatalFailure(failure, eventGeneration):
            guard eventGeneration == generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            if failure.isTemporalUnavailable, activeConfiguration == .appleTemporal {
                temporalRetrySuppressed = true
                emitTemporalNoticeOnce()
                switchDecoderConfiguration(
                    to: .rawTemporalFailure,
                    toleratingTemporalDrainFailure: true
                )
                return
            }
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        }
    }

    func setAlgorithm(_ algorithm: DeinterlaceAlgorithm) {
        guard !stopped else { return }
        guard selectedAlgorithm != algorithm else { return }
        selectedAlgorithm = algorithm
        metrics?.update(selectedAlgorithm: algorithm)
        if algorithm != .appleTemporal {
            temporalRetrySuppressed = false
        }
        applyResolvedRoute()
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
            decoderConfigured = false
            activeConfiguration = nil
            waitingForRandomAccess = true
            hooks.resetPlayback(generation, requiredVideoFrameCount)
            decoder.invalidate()
            return
        }

        if decoderConfigured {
            do { try decoder.finishDelayedFrames() } catch {}
            do { try decoder.waitForAsynchronousFrames() } catch {}
        }
        decoder.invalidate()
        decoderConfigured = false
        activeConfiguration = nil
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: generation)
        previousProbeBuffer = nil
    }

    private func configuration(for route: DeinterlaceRoute) -> VideoDecodeConfiguration {
        route == .appleTemporal ? .appleTemporal : .bothFields
    }

    private func performTrueFormatDrainStep(
        _ operation: () throws -> Void
    ) -> Bool {
        do {
            try operation()
            return true
        } catch let failure as VideoDecoderFailure {
            if activeConfiguration == .appleTemporal, failure.isTemporalUnavailable {
                temporalRetrySuppressed = true
                emitTemporalNoticeOnce()
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

    private func applyResolvedRoute() {
        let next = resolvedRoute()
        guard next != route else { return }
        let nextConfiguration = configuration(for: next)
        if decoderConfigured,
           let activeConfiguration,
           activeConfiguration != nextConfiguration {
            switchDecoderConfiguration(to: next)
            return
        }
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

    private func resolvedRoute() -> DeinterlaceRoute {
        if temporalRetrySuppressed,
           selectedAlgorithm == .appleTemporal,
           case .interlaced = classifier.current {
            return .rawTemporalFailure
        }
        return DeinterlaceRoute.resolve(
            scan: classifier.current,
            selected: selectedAlgorithm
        )
    }

    private func configureRawTemporalFallback(
        format: CMVideoFormatDescription
    ) -> Bool {
        let token = signposts?.begin(.modeSwitch, correlation: routeEpoch &+ 1)
        defer {
            if let token { signposts?.end(token) }
        }
        temporalRetrySuppressed = true
        route = .rawTemporalFailure
        routeEpoch &+= 1
        metrics?.update(activeRoute: .rawTemporalFailure)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        hooks.routeDidChange(requiredVideoFrameCount)
        do {
            try decoder.configure(
                format: format,
                generation: generation,
                configuration: .bothFields
            )
            decoderConfigured = true
            activeConfiguration = .bothFields
            waitingForRandomAccess = false
            emitTemporalNoticeOnce()
            return true
        } catch let failure as VideoDecoderFailure {
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        } catch {
            hooks.fail(.videoDecode(-1), generation)
        }
        return false
    }

    private func emitTemporalNoticeOnce() {
        guard temporalNoticeGate.consume(sessionID: playbackSessionID) else { return }
        metrics?.recordTemporalUnavailableNotice()
        hooks.notice(.appleTemporalUnavailable, generation)
    }

    private func switchDecoderConfiguration(
        to next: DeinterlaceRoute,
        toleratingTemporalDrainFailure: Bool = false
    ) {
        let token = signposts?.begin(.modeSwitch, correlation: routeEpoch &+ 1)
        defer {
            if let token { signposts?.end(token) }
        }
        hooks.closeAdmission()
        let toleratesOldAppleSessionFailure = toleratingTemporalDrainFailure
            || activeConfiguration == .appleTemporal
        guard performDrainStep(
            decoder.finishDelayedFrames,
            toleratingTemporalFailure: toleratesOldAppleSessionFailure
        ) else { return }
        guard performDrainStep(
            decoder.waitForAsynchronousFrames,
            toleratingTemporalFailure: toleratesOldAppleSessionFailure
        ) else { return }

        let oldGeneration = generation
        generation = hooks.advanceGeneration()
        route = next
        routeEpoch &+= 1
        metrics?.update(activeRoute: next)
        classifier.rebasePreservingClassification(generation: generation)
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: oldGeneration)
        previousProbeBuffer = nil
        decoderConfigured = false
        activeConfiguration = nil
        waitingForRandomAccess = true
        hooks.resetPlayback(generation, requiredVideoFrameCount)
        decoder.invalidate()
        hooks.reopenAdmission()
    }

    private func performDrainStep(
        _ operation: () throws -> Void,
        toleratingTemporalFailure: Bool
    ) -> Bool {
        do {
            try operation()
            return true
        } catch let failure as VideoDecoderFailure {
            if toleratingTemporalFailure, failure.isTemporalUnavailable {
                if selectedAlgorithm == .appleTemporal {
                    temporalRetrySuppressed = true
                }
                emitTemporalNoticeOnce()
                return true
            }
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
            return false
        } catch {
            hooks.fail(.videoDecode(-1), generation)
            return false
        }
    }

    private func submitProbe(for frame: DecodedVideoFrame) {
        defer { previousProbeBuffer = frame.pixelBuffer }
        guard route != .appleTemporal,
              let probe,
              let previousProbeBuffer else { return }
        let submittedGeneration = generation
        let submittedEpoch = routeEpoch
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
                guard let self,
                      !stopped,
                      generation == submittedGeneration,
                      routeEpoch == submittedEpoch else {
                    self?.metrics?.recordStaleGenerationDrop()
                    return
                }
                guard case let .success(sample) = result else { return }
                observeSupplementalProbe(frame, sample: sample)
            }
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
                case let .failure(failure):
                    hooks.fail(.metalCommand(failure.code), submittedGeneration)
                }
            }
        }

        if route == .metalYADIF2x {
            guard case let .interlaced(order) = classifier.current else { return }
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
