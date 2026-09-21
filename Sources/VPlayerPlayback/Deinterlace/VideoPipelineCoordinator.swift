// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum YADIFFrameAdmission: Sendable, Equatable {
    case accepted
    case retry
}

protocol YADIFFrameProcessing: AnyObject, Sendable, PlaybackTunable {
    func reset(to generation: MediaGeneration)
    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    )
    /// HLS 仅在此原子入口取得 GPU/ready-job 容量；普通展示仍使用 `submit`。
    func trySubmit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    ) -> YADIFFrameAdmission
    func installCapacityReleaseSink(_ sink: @escaping @Sendable () -> Void)
    /// 下游原子编码 bridge 已持有 retry batch 时暂停 ready-job 调度；已有 GPU
    /// 命令仍可完成，但其 completion 会在同一 owner lane 建立此门禁。
    func setSubmissionSchedulingPaused(_ paused: Bool)
    /// A lifetime barrier, not a media-result channel. Every admitted submit
    /// resolves through its own completion; this callback fires exactly once
    /// after all work preceding the barrier has released its resources.
    func drain(completion: @escaping @Sendable () -> Void)
}

extension YADIFFrameProcessing {
    func trySubmit(normalized frame: NormalizedDecodedFrame, order: ResolvedFieldOrder,
                   discontinuity: Bool,
                   completion: @escaping @Sendable (VideoProcessingResult) -> Void) -> YADIFFrameAdmission {
        submit(normalized: frame, order: order, discontinuity: discontinuity, completion: completion)
        return .accepted
    }
    func installCapacityReleaseSink(_: @escaping @Sendable () -> Void) {}
    func setSubmissionSchedulingPaused(_: Bool) {}
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
    let submissionRejected: @Sendable (UInt64, VideoDecoderEventIdentity) -> Void
    let decoderInvalidationBegan: @Sendable (VideoDecoderInvalidationTicket) -> Void
    let decoderInvalidationFinished: @Sendable (
        VideoDecoderInvalidationTicket,
        VideoDecoderInvalidationResolution
    ) -> Void
    let reopenAdmission: @Sendable () -> Void
    let routeDidChange: @Sendable (Int) -> Void
    let deliver: @Sendable ([VideoPresentationFrame], MediaGeneration) -> Void
    let fail: @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
}

struct VideoDecoderInvalidationTicket: Sendable, Equatable {
    let token: VideoDecoderTransitionToken
    let generation: MediaGeneration
}

enum VideoDecoderInvalidationResolution: Sendable, Equatable {
    /// The old session is gone (or already unusable), so the pending format
    /// transaction may atomically install its new audio/video configuration.
    case commit
    /// The invalidation failed in a way that makes the format transaction unsafe.
    case fail(VideoDecoderFailure)
}

enum VideoRecoveryCause: Sendable, Equatable {
    case noFrame
    case stall
    case sessionFailure
    case processingStructural
}

enum VideoRecoveryDecision: Sendable, Equatable {
    case none
    case recover(VideoRecoveryCause)
    case exhausted(VideoRecoveryCause)
}

/// Per-media-epoch recovery state shared by every decoder liveness signal.
///
/// A decoder attempt is fenced separately from the media epoch. Starting a new
/// attempt rearms the consecutive-no-output detector, but only a true format or
/// discontinuity boundary replenishes the finite recovery total.
struct VideoRecoveryBudget: Sendable {
    private static let noFrameThreshold = 12

    private let maximumRecoveriesPerMediaEpoch: Int
    private let maximumStructuralRecoveriesPerMediaEpoch: Int
    private var consecutiveNoFrameCount = 0
    private var recoveryInFlight = false
    private var exhausted = false

    private(set) var recoveriesConsumed = 0
    private(set) var structuralRecoveriesConsumed = 0

    init(
        maximumRecoveriesPerMediaEpoch: Int,
        maximumStructuralRecoveriesPerMediaEpoch: Int = 2
    ) {
        self.maximumRecoveriesPerMediaEpoch = max(0, maximumRecoveriesPerMediaEpoch)
        self.maximumStructuralRecoveriesPerMediaEpoch = max(
            0,
            maximumStructuralRecoveriesPerMediaEpoch
        )
    }

    mutating func observe(
        _ disposition: VideoDecoderSubmissionDisposition
    ) -> VideoRecoveryDecision {
        switch disposition {
        case .produced:
            consecutiveNoFrameCount = 0
            return .none
        case .cancelled:
            return .none
        case .noFrame:
            guard !recoveryInFlight, !exhausted else { return .none }
            consecutiveNoFrameCount += 1
            guard consecutiveNoFrameCount >= Self.noFrameThreshold else { return .none }
            return requestRecovery(for: .noFrame)
        }
    }

    mutating func requestRecovery(
        for cause: VideoRecoveryCause
    ) -> VideoRecoveryDecision {
        guard !recoveryInFlight, !exhausted else { return .none }
        consecutiveNoFrameCount = 0
        if cause == .processingStructural,
           structuralRecoveriesConsumed >= maximumStructuralRecoveriesPerMediaEpoch {
            exhausted = true
            return .exhausted(cause)
        }
        guard recoveriesConsumed < maximumRecoveriesPerMediaEpoch else {
            exhausted = true
            return .exhausted(cause)
        }
        recoveriesConsumed += 1
        if cause == .processingStructural {
            structuralRecoveriesConsumed += 1
        }
        recoveryInFlight = true
        return .recover(cause)
    }

    mutating func beginDecoderAttempt() {
        guard !exhausted else { return }
        consecutiveNoFrameCount = 0
        recoveryInFlight = false
    }

    mutating func beginMediaEpoch() {
        consecutiveNoFrameCount = 0
        recoveryInFlight = false
        exhausted = false
        recoveriesConsumed = 0
        structuralRecoveriesConsumed = 0
    }
}

final class VideoPipelineCoordinator: @unchecked Sendable {
    typealias DecoderTransitionDeadlineScheduler = @Sendable (
        DispatchTimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void

    private struct PendingDecoderConfiguration {
        let token: VideoDecoderTransitionToken
        let identity: VideoDecoderEventIdentity
        let accessUnit: CompressedVideoAccessUnit
    }

    private struct PendingDecoderInvalidation {
        let token: VideoDecoderTransitionToken
        let generation: MediaGeneration
        var reopenAdmission: Bool
    }

    private struct PendingNaturalDrain {
        let token: VideoDecoderTransitionToken
        let generation: MediaGeneration
        let completion: @Sendable (VideoDecoderTransitionOutcome) -> Void
        var nativeDrainCompleted = false
        var yadifDrainRequested = false
    }
    private struct PendingStopRetirement {
        let token: VideoDecoderTransitionToken
        let completion: @Sendable (Bool) -> Void
    }

    private struct ProcessingAdmissionFloor: Sendable {
        let generation: MediaGeneration
        let minimumAccessUnitID: UInt64
        let minimumOutputPTS: CMTime
    }

    private static let maximumClassificationProbeAttempts = 3
    private static let maximumDecoderSessionRestarts = 4
    private static let defaultDecoderTransitionDeadline: DispatchTimeInterval = .seconds(5)
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
    private let atomicEncodingSink: VideoAtomicEncodingSink?
    private let atomicEncodingAdmission: (any VideoAtomicEncodingAdmitting)?
    private let maximumHLSPendingYADIFFrames: Int
    /// 首次 install 尚无旧 HLS owner；不能先 cancel 注入的当前 bridge，
    /// 否则第一个 YADIF batch 会被永久拒绝。后续真正换代才退休旧 owner。
    private var hasInstalledMediaEpoch = false
    private let decoderTransitionDeadline: DispatchTimeInterval
    private let decoderTransitionDeadlineScheduler: DecoderTransitionDeadlineScheduler

    private var generation: MediaGeneration
    private var classifier: ScanTypeClassifier
    private var normalizer: PresentationTimestampNormalizer
    private var videoFormat: CMVideoFormatDescription?
    private var streamFieldOrder: CodedFieldOrder = .unknown
    private var previousProbeBuffer: CVPixelBuffer?
    private var completedClassificationProbeCount = 0
    private var nextProbeSubmissionID: UInt64 = 0
    private var activeProbeSubmissionID: UInt64?
    private var activeProbeSignpostLifetime: PlaybackSignpostLifetime?
    private var decoderConfigured = false
    private var waitingForRandomAccess = true
    private var hasSkippedInitialInterlacedGOP = false
    private var activeDecoderIdentity: VideoDecoderEventIdentity?
    private var pendingDecoderConfiguration: PendingDecoderConfiguration?
    private var pendingDecoderInvalidation: PendingDecoderInvalidation?
    private var pendingNaturalDrain: PendingNaturalDrain?
    private var pendingStopRetirement: PendingStopRetirement?
    private var decoderTransitionDeadlineRevision: UInt64 = 0
    private var routeEpoch: UInt64 = 0
    private var processingAdmissionFloor: ProcessingAdmissionFloor?
    // Decode failures since the current decoder attempt began.
    private var consecutivePerFrameDecodeFailures = 0
    private var recoveryBudget = VideoRecoveryBudget(
        maximumRecoveriesPerMediaEpoch: maximumDecoderSessionRestarts
    )
    private var stopped = false
    private struct PendingHLSYADIF {
        let frame: NormalizedDecodedFrame
        let order: ResolvedFieldOrder
        let completion: @Sendable (VideoProcessingResult) -> Void
    }
    /// Already-admitted decoder callbacks can arrive after HLS closes source
    /// admission. Keep their normalized ownership FIFO and bounded by the
    /// owner's actual pre-paid input window; do not turn that legal tail into
    /// a second `.retry` failure or a display-path GPU drop.
    private var pendingHLSYADIF: [PendingHLSYADIF] = []

    private(set) var route = DeinterlaceRoute.rawWhileClassifying

    /// Startup classification is unresolved until the coordinator has selected
    /// either the passthrough or YADIF presentation path. Playback readiness
    /// uses this semantic state instead of duplicating route comparisons.
    var isClassificationResolved: Bool {
        route != .rawWhileClassifying
    }

    var requiredVideoFrameCount: Int {
        // One completed YADIF job yields the two field-rate presentation frames
        // needed to open readiness. The processor's three-frame reference window
        // is an input requirement, not a presentation-queue requirement.
        route == .metalYADIF2x ? 2 : (rawReadinessRequirementOverride ?? 1)
    }

    var currentDecoderIdentity: VideoDecoderEventIdentity? {
        pendingDecoderConfiguration?.identity ?? activeDecoderIdentity
    }

    var isDecoderTransitionPending: Bool {
        pendingDecoderConfiguration != nil || pendingDecoderInvalidation != nil
    }

    init(
        decoder: any VideoDecoding,
        passthrough: any VideoFrameProcessing,
        yadif: any YADIFFrameProcessing,
        probe: (any LumaScanProbing)?,
        initialGeneration: MediaGeneration,
        classifierConfiguration: ScanClassifierConfiguration = .init(),
        rawReadinessRequirementOverride: Int? = nil,
        decoderTransitionDeadline: DispatchTimeInterval =
            VideoPipelineCoordinator.defaultDecoderTransitionDeadline,
        decoderTransitionDeadlineScheduler: DecoderTransitionDeadlineScheduler? = nil,
        metrics: PlaybackMetrics? = nil,
        signposts: PlaybackSignposts? = nil,
        atomicEncodingSink: VideoAtomicEncodingSink? = nil,
        atomicEncodingAdmission: (any VideoAtomicEncodingAdmitting)? = nil,
        maximumHLSPendingYADIFFrames: Int = 8,
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
        self.decoderTransitionDeadline = decoderTransitionDeadline
        let rawDeadlineScheduler: DecoderTransitionDeadlineScheduler =
            decoderTransitionDeadlineScheduler ?? { delay, operation in
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + delay,
                    execute: operation
                )
            }
        self.decoderTransitionDeadlineScheduler = { delay, operation in
            rawDeadlineScheduler(delay) {
                hooks.schedule(operation)
            }
        }
        self.metrics = metrics
        self.signposts = signposts
        self.atomicEncodingSink = atomicEncodingSink
        self.atomicEncodingAdmission = atomicEncodingAdmission
        self.maximumHLSPendingYADIFFrames = max(1, maximumHLSPendingYADIFFrames)
        self.hooks = hooks
        yadif.installCapacityReleaseSink { [weak self] in
            hooks.schedule { [weak self] in self?.retryPendingHLSYADIF() }
        }
        normalizer.beginAwaitingAudioTimelineOrigin()
        metrics?.update(scanType: .unknown)
        metrics?.update(activeRoute: .rawWhileClassifying)
    }

    func replaceFormat(
        _ format: CMVideoFormatDescription,
        streamFieldOrder: CodedFieldOrder = .unknown
    ) {
        guard !stopped else { return }
        performTrueFormatChange(
            format: format,
            streamFieldOrder: streamFieldOrder,
            reopenAdmission: true,
            resetsTimeline: false
        )
    }

    func beginDiscontinuity() {
        guard !stopped else { return }
        performTrueFormatChange(
            format: nil,
            streamFieldOrder: .unknown,
            reopenAdmission: false,
            resetsTimeline: true
        )
    }

    func observeAudioTimelineOrigin(_ presentationTimeStamp: CMTime) {
        guard !stopped else { return }
        for normalized in normalizer.observeAudioTimelineOrigin(presentationTimeStamp) {
            process(normalized)
        }
    }

    /// HLS producer 在下游释放容量后显式驱动重试；这里不依赖下一帧碰巧到达，
    /// 也不把 retry batch 交给 sample-buffer 的 display callback。
    @discardableResult
    func retryPendingAtomicEncoding() -> Bool {
        guard !stopped, let atomicEncodingAdmission else { return false }
        switch atomicEncodingAdmission.retryPending() {
        case .accepted:
            yadif.setSubmissionSchedulingPaused(false)
            retryPendingHLSYADIF()
            reopenAdmissionIfSafe()
            return true
        case .retry:
            return false
        case .rejected:
            yadif.setSubmissionSchedulingPaused(true)
            hooks.fail(.metalCommand("hls.atomicEncoding.retry"), generation)
            return false
        }
    }

    func installFormatForCurrentGeneration(
        _ format: CMVideoFormatDescription,
        streamFieldOrder: CodedFieldOrder = .unknown
    ) {
        guard !stopped else { return }
        // 初始 HLS owner 不经历 format retirement，但 processor 仍必须绑定到
        // 当前 generation；否则 Passthrough/YADIF 会把所有第一代 frame 当 stale。
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        videoFormat = format
        decoderConfigured = false
        waitingForRandomAccess = true
        hasSkippedInitialInterlacedGOP = false
        activeDecoderIdentity = nil
        pendingDecoderConfiguration = nil
        pendingDecoderInvalidation?.reopenAdmission = true
        recoveryBudget.beginMediaEpoch()
        apply(streamFieldOrder: streamFieldOrder)
    }

    func installProcessingAdmissionFloor(
        generation: MediaGeneration,
        minimumAccessUnitID: UInt64,
        minimumOutputPTS: CMTime
    ) {
        guard !stopped,
              generation == self.generation,
              minimumOutputPTS.isNumeric else { return }
        processingAdmissionFloor = ProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: minimumAccessUnitID,
            minimumOutputPTS: minimumOutputPTS
        )
    }

    private func performTrueFormatChange(
        format: CMVideoFormatDescription?,
        streamFieldOrder: CodedFieldOrder,
        reopenAdmission: Bool,
        resetsTimeline: Bool
    ) {
        failPendingNaturalDrain()
        if hasInstalledMediaEpoch {
            atomicEncodingAdmission?.cancel()
        }
        hooks.closeAdmission()
        pendingHLSYADIF.removeAll(keepingCapacity: false)
        let shouldDrain = decoderConfigured

        let oldGeneration = generation
        generation = hooks.advanceGeneration()
        hasInstalledMediaEpoch = true
        processingAdmissionFloor = nil
        routeEpoch &+= 1
        route = .rawWhileClassifying
        metrics?.update(scanType: .unknown)
        metrics?.update(activeRoute: .rawWhileClassifying)
        classifier.reset(generation: generation)
        if resetsTimeline {
            normalizer.reset(generation: generation)
            normalizer.beginAwaitingAudioTimelineOrigin()
        } else {
            normalizer.rebindDecoderGeneration(generation)
        }
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: oldGeneration)
        previousProbeBuffer = nil
        completedClassificationProbeCount = 0
        clearActiveProbeSubmission()
        videoFormat = format
        decoderConfigured = false
        waitingForRandomAccess = true
        hasSkippedInitialInterlacedGOP = false
        activeDecoderIdentity = nil
        pendingDecoderConfiguration = nil
        recoveryBudget.beginMediaEpoch()
        apply(streamFieldOrder: streamFieldOrder)
        hooks.resetPlayback(generation, requiredVideoFrameCount, .timeline)
        beginDecoderInvalidation(
            generation: generation,
            drain: shouldDrain,
            reopenAdmission: reopenAdmission
        )
    }

    private func apply(streamFieldOrder: CodedFieldOrder) {
        self.streamFieldOrder = streamFieldOrder
        guard let change = classifier.observeStreamFieldOrder(
            streamFieldOrder,
            generation: generation
        ) else { return }
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    @discardableResult
    func handle(accessUnit: CompressedVideoAccessUnit) -> Bool {
        guard !stopped else {
            recordHLSIDRRejection(accessUnit, reason: "stopped")
            return false
        }
        guard accessUnit.generation == generation else {
            metrics?.recordStaleGenerationDrop()
            recordHLSIDRRejection(accessUnit, reason: "generation")
            return false
        }
        guard pendingDecoderConfiguration == nil,
              pendingDecoderInvalidation == nil else {
            recordHLSIDRRejection(accessUnit, reason: "transition")
            return false
        }
        if waitingForRandomAccess {
            guard accessUnit.isRandomAccess, let videoFormat else {
                recordHLSIDRRejection(accessUnit, reason: "awaitingRandomAccess")
                return false
            }
            if !hasSkippedInitialInterlacedGOP,
               atomicEncodingAdmission == nil,
               accessUnit.parserMetadata.isInterlaced == true,
               CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264 {
                // 实机观察到首个隔行 GOP 偶发块状损坏；等下一个随机访问点再呈现。
                hasSkippedInitialInterlacedGOP = true
                return false
            }
            beginDecoderConfiguration(
                format: videoFormat,
                retaining: accessUnit
            )
            return true
        }
        if decoder.transitionRequirement(for: accessUnit) == .reconfigure {
            guard accessUnit.isRandomAccess, let videoFormat else {
                recordHLSIDRRejection(accessUnit, reason: "reconfigureWithoutProof")
                return false
            }
            beginDecoderConfiguration(
                format: videoFormat,
                retaining: accessUnit
            )
            return true
        }

        do {
            try decoder.decode(accessUnit, flags: ._EnableAsynchronousDecompression)
            return true
        } catch let failure as VideoDecoderFailure {
            recordHLSIDRRejection(accessUnit, reason: "decode.\(failure)")
            handleSubmissionFailure(failure, generation: generation)
            return false
        } catch {
            recordHLSIDRRejection(accessUnit, reason: "decode.unknown")
            hooks.fail(.videoDecode(-1), generation)
            return false
        }
    }

    private func recordHLSIDRRejection(
        _ accessUnit: CompressedVideoAccessUnit,
        reason: String
    ) {
        #if DEBUG
        guard atomicEncodingAdmission != nil, accessUnit.isRandomAccess else { return }
        PlaybackDiagnosticTracker.shared.append(
            "g_video_idr_reject_\(reason)_au\(accessUnit.id)")
        #endif
    }

    private func beginDecoderConfiguration(
        format: CMVideoFormatDescription,
        retaining accessUnit: CompressedVideoAccessUnit
    ) {
        hooks.closeAdmission()
        let token = VideoDecoderTransitionToken()
        let identity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: token
        )
        activeDecoderIdentity = nil
        decoderConfigured = false
        waitingForRandomAccess = true
        pendingDecoderConfiguration = PendingDecoderConfiguration(
            token: token,
            identity: identity,
            accessUnit: accessUnit
        )
        let deadlineRevision = armDecoderTransitionDeadline()
        decoder.prepareConfiguration(for: accessUnit, format: format)
        decoder.transition(.configure(
            token: token,
            format: format,
            generation: generation
        ))
        scheduleDecoderTransitionDeadline(
            token: token,
            generation: generation,
            revision: deadlineRevision
        )
    }

    private func beginDecoderInvalidation(
        generation: MediaGeneration,
        drain: Bool,
        reopenAdmission: Bool
    ) {
        let token = VideoDecoderTransitionToken()
        pendingDecoderInvalidation = PendingDecoderInvalidation(
            token: token,
            generation: generation,
            reopenAdmission: reopenAdmission
        )
        let ticket = VideoDecoderInvalidationTicket(
            token: token,
            generation: generation
        )
        hooks.decoderInvalidationBegan(ticket)
        let deadlineRevision = armDecoderTransitionDeadline()
        if drain {
            decoder.transition(.drainAndInvalidate(token: token))
        } else {
            decoder.transition(.invalidate(token: token))
        }
        scheduleDecoderTransitionDeadline(
            token: token,
            generation: generation,
            revision: deadlineRevision
        )
    }

    private func armDecoderTransitionDeadline() -> UInt64 {
        decoderTransitionDeadlineRevision &+= 1
        return decoderTransitionDeadlineRevision
    }

    private func cancelDecoderTransitionDeadline() {
        decoderTransitionDeadlineRevision &+= 1
    }

    private func scheduleDecoderTransitionDeadline(
        token: VideoDecoderTransitionToken,
        generation: MediaGeneration,
        revision: UInt64
    ) {
        decoderTransitionDeadlineScheduler(decoderTransitionDeadline) { [weak self] in
            self?.handleDecoderTransitionDeadline(
                token: token,
                generation: generation,
                revision: revision
            )
        }
    }

    private func handleDecoderTransitionDeadline(
        token: VideoDecoderTransitionToken,
        generation expectedGeneration: MediaGeneration,
        revision: UInt64
    ) {
        guard !stopped,
              decoderTransitionDeadlineRevision == revision,
              generation == expectedGeneration else { return }

        if let pending = pendingDecoderConfiguration,
           pending.token == token,
           pending.identity.generation == expectedGeneration {
            cancelDecoderTransitionDeadline()
            pendingDecoderConfiguration = nil
            activeDecoderIdentity = nil
            decoderConfigured = false
            waitingForRandomAccess = true
            hooks.submissionRejected(pending.accessUnit.id, pending.identity)
            metrics?.recordVideoDecodeFailure(kind: "transitionTimeout", status: 0)
            hooks.fail(.videoDecoderTransitionTimeout, expectedGeneration)
            return
        }

        guard let pending = pendingDecoderInvalidation,
              pending.token == token,
              pending.generation == expectedGeneration else { return }
        cancelDecoderTransitionDeadline()
        pendingDecoderInvalidation = nil
        activeDecoderIdentity = nil
        decoderConfigured = false
        waitingForRandomAccess = true
        metrics?.recordVideoDecodeFailure(kind: "transitionTimeout", status: 0)
        hooks.fail(.videoDecoderTransitionTimeout, expectedGeneration)
    }

    /// Submission failures reach here from two directions — a decoder that
    /// rejects a unit on the caller's thread, and the asynchronous
    /// `submissionFailure` event from one that hands submission to its own
    /// queue. Both mean the same thing, so both get the same recovery.
    private enum SubmissionFailureHandling {
        case continueCurrentAttempt
        case recoveryStarted
        case terminal
    }

    @discardableResult
    private func handleSubmissionFailure(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) -> SubmissionFailureHandling {
        if failure == .backpressureTimeout {
            handleRecoveryDecision(recoveryBudget.requestRecovery(for: .stall))
            return isDecoderTransitionPending ? .recoveryStarted : .terminal
        }
        recordDecodeFailureDiagnostic(failure)
        if Self.isPerFrameDecodeFailure(failure) {
            handlePerFrameDecodeFailure(failure, generation: generation)
            return isDecoderTransitionPending ? .recoveryStarted : .continueCurrentAttempt
        }
        if Self.requiresDecoderSessionRestart(failure) {
            restartDecoderAfterSessionFailure(failure, generation: generation)
            return isDecoderTransitionPending ? .recoveryStarted : .terminal
        }
        hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        return .terminal
    }

    func handle(decoder event: VideoDecoderEvent) {
        // stop 后仍必须消费自己的 transition receipt；不能因 stopped early-return
        // 遗失 native invalidate 已执行的事实。
        if case let .transitionCompleted(token, outcome) = event {
            completeDecoderTransition(token: token, outcome: outcome)
            return
        }
        guard !stopped else { return }
        switch event {
        case .transitionCompleted:
            return
        case let .frame(frame, identity):
            guard identity == activeDecoderIdentity,
                  frame.generation == identity.generation else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            // A frame arrived, so whatever broke decoding has cleared.
            consecutivePerFrameDecodeFailures = 0
            _ = recoveryBudget.observe(.produced)
            observe(frame, probe: nil)
            guard frame.generation == generation else { return }
            submitProbe(for: frame)
            for normalized in normalizer.push(frame, discontinuity: false) {
                process(normalized)
            }
        case let .submissionFailure(_, failure, identity):
            guard identity == activeDecoderIdentity else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            handleSubmissionFailure(failure, generation: identity.generation)
        case let .submissionCompleted(_, identity, disposition):
            guard identity == activeDecoderIdentity else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            handleRecoveryDecision(recoveryBudget.observe(disposition))
        case let .recoverableFailure(failure, identity):
            guard identity == activeDecoderIdentity else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            recordDecodeFailureDiagnostic(failure)
            if Self.requiresDecoderSessionRestart(failure) {
                restartDecoderAfterSessionFailure(failure, generation: identity.generation)
                return
            }
            handlePerFrameDecodeFailure(failure, generation: identity.generation)
        case let .fatalFailure(failure, identity):
            guard identity == activeDecoderIdentity else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            recordDecodeFailureDiagnostic(failure)
            hooks.fail(PlaybackPipeline.coreError(for: failure), identity.generation)
        }
    }

    private func completeDecoderTransition(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    ) {
        if let pending = pendingStopRetirement, pending.token == token {
            pendingStopRetirement = nil
            let nativeConfirmed: Bool
            if case .completed = outcome { nativeConfirmed = true } else { nativeConfirmed = false }
            // YADIF drain 的 cutoff 同时覆盖 inFlight、submissionAttempts 与
            // commandSubmissionsInProgress；这里只在实际 barrier 后给 stop receipt。
            yadif.drain { [weak self] in
                self?.hooks.schedule {
                    pending.completion(nativeConfirmed)
                }
            }
            return
        }
        if let pending = pendingNaturalDrain,
           pending.token == token,
           pending.generation == generation {
            switch outcome {
            case let .failed(failure):
                pendingNaturalDrain = nil
                pending.completion(.failed(failure))
            case .completed:
                // `drain()` 返回的 normalizer 尾必须走与正常帧完全相同的
                // process/FIFO 路径，不能跳过 HLS 的 trySubmit 背压协议。
                var advanced = pending
                advanced.nativeDrainCompleted = true
                pendingNaturalDrain = advanced
                for normalized in normalizer.drain() { process(normalized) }
                advanceNaturalDrainIfReady()
            }
            return
        }
        if let pending = pendingDecoderInvalidation,
           pending.token == token,
           pending.generation == generation {
            cancelDecoderTransitionDeadline()
            pendingDecoderInvalidation = nil
            let ticket = VideoDecoderInvalidationTicket(
                token: pending.token,
                generation: pending.generation
            )
            switch outcome {
            case .completed:
                hooks.decoderInvalidationFinished(ticket, .commit)
                if pending.reopenAdmission { reopenAdmissionIfSafe() }
            case let .failed(failure):
                recordDecodeFailureDiagnostic(failure)
                if Self.isRecoverableDecodeSubmissionFailure(failure) {
                    metrics?.recordVideoDrop(source: .decoderRecoverable)
                    hooks.decoderInvalidationFinished(ticket, .commit)
                    if pending.reopenAdmission { reopenAdmissionIfSafe() }
                } else {
                    hooks.decoderInvalidationFinished(ticket, .fail(failure))
                    hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
                }
            }
            return
        }
        guard let pending = pendingDecoderConfiguration,
              pending.token == token,
              pending.identity.generation == generation else { return }
        cancelDecoderTransitionDeadline()
        pendingDecoderConfiguration = nil
        switch outcome {
        case let .failed(failure):
            // 配置阶段未交 native decode；以 pending identity 接受的 AU 必须由
            // owner 精确退还输入 credit，不能等待不存在的 submissionCompleted。
            hooks.submissionRejected(pending.accessUnit.id, pending.identity)
            recordDecodeFailureDiagnostic(failure)
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        case .completed:
            activeDecoderIdentity = pending.identity
            decoderConfigured = true
            waitingForRandomAccess = false
            recoveryBudget.beginDecoderAttempt()
            consecutivePerFrameDecodeFailures = 0
            do {
                try decoder.decode(pending.accessUnit, flags: ._EnableAsynchronousDecompression)
                reopenAdmissionIfSafe()
                beginNativeNaturalDrainIfReady()
            } catch let failure as VideoDecoderFailure {
                hooks.submissionRejected(pending.accessUnit.id, pending.identity)
                if handleSubmissionFailure(failure, generation: generation)
                    == .continueCurrentAttempt {
                    reopenAdmissionIfSafe()
                }
            } catch {
                hooks.submissionRejected(pending.accessUnit.id, pending.identity)
                hooks.fail(.videoDecode(-1), generation)
            }
        }
    }

    private func handleRecoveryDecision(_ decision: VideoRecoveryDecision) {
        switch decision {
        case .none:
            break
        case .recover:
            restartDecoderForRecovery()
        case let .exhausted(cause):
            let failure: VideoDecoderFailure
            switch cause {
            case .noFrame, .stall:
                failure = .backpressureTimeout
            case .sessionFailure:
                failure = .malfunction(kVTVideoDecoderMalfunctionErr)
            case .processingStructural:
                // Structural recovery is handled together with its typed failure
                // by `handleProcessingStructuralFailure`.
                return
            }
            hooks.fail(PlaybackPipeline.coreError(for: failure), generation)
        }
    }

    func applyTuning(_ tuning: PlaybackTuning) {
        guard !stopped else { return }
        yadif.apply(tuning)
        decoder.setTuning(tuning)
    }

    func stop(emergency: Bool, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard !stopped else { completion(false); return }
        failPendingNaturalDrain()
        stopped = true
        atomicEncodingAdmission?.cancel()
        cancelDecoderTransitionDeadline()
        // 配置期的 AU 已由 owner 按 transition identity 入账，但尚未交给
        // native decode，因而不会有 submissionCompleted。停止必须在丢弃
        // pending 配置前精确拒绝它；已经成功调用 decode 的 AU 则不在这里
        // 处理，仍由 matching completion 释放其 owner lease。
        if let pending = pendingDecoderConfiguration {
            hooks.submissionRejected(pending.accessUnit.id, pending.identity)
        }
        processingAdmissionFloor = nil
        pendingHLSYADIF.removeAll(keepingCapacity: false)
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
            completedClassificationProbeCount = 0
            clearActiveProbeSubmission()
            decoderConfigured = false
            waitingForRandomAccess = true
            activeDecoderIdentity = nil
            pendingDecoderConfiguration = nil
            pendingDecoderInvalidation = nil
            hooks.resetPlayback(generation, requiredVideoFrameCount, .timeline)
            let token = VideoDecoderTransitionToken()
            pendingStopRetirement = .init(token: token, completion: completion)
            decoder.transition(.invalidate(token: token))
            return
        }

        let token = VideoDecoderTransitionToken()
        pendingStopRetirement = .init(token: token, completion: completion)
        decoder.transition(.drainAndInvalidate(token: token))
        decoderConfigured = false
        activeDecoderIdentity = nil
        pendingDecoderConfiguration = nil
        pendingDecoderInvalidation = nil
        normalizer.reset(generation: generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: generation)
        previousProbeBuffer = nil
        completedClassificationProbeCount = 0
        clearActiveProbeSubmission()
    }

    /// 正常 EOF 不得复用 stop：关闭新输入后保留当前 native session identity，
    /// 等 native delayed callback 与 YADIF 最后一个 window tail 全部退休。
    func drainForNaturalEOF(
        completion: @escaping @Sendable (VideoDecoderTransitionOutcome) -> Void
    ) {
        guard !stopped, pendingNaturalDrain == nil else {
            completion(.failed(.malfunction(kVTInvalidSessionErr)))
            return
        }
        hooks.closeAdmission()
        let token = VideoDecoderTransitionToken()
        pendingNaturalDrain = PendingNaturalDrain(
            token: token,
            generation: generation,
            completion: completion
        )
        beginNativeNaturalDrainIfReady()
    }

    /// 配置完成才会在 owner lane 真正调用 decode。EOF 不能越过已接纳的配置 AU
    /// 启动 native drain；也不能等待 submissionCompleted，因为 delayed frame 正需 drain。
    private func beginNativeNaturalDrainIfReady() {
        guard let pending = pendingNaturalDrain,
              pending.generation == generation,
              !pending.nativeDrainCompleted,
              pendingDecoderConfiguration == nil else { return }
        decoder.transition(.drain(token: pending.token))
    }

    /// native drain 的完成只说明解码器不再产生旧帧；normalizer/FIFO/GPU 仍可
    /// 持有尾帧。因此这三个阶段必须由各自真实完成事件依次推进。
    private func advanceNaturalDrainIfReady() {
        guard !stopped, var pending = pendingNaturalDrain,
              pending.generation == generation,
              pending.nativeDrainCompleted,
              pendingHLSYADIF.isEmpty,
              !pending.yadifDrainRequested else { return }
        pending.yadifDrainRequested = true
        pendingNaturalDrain = pending
        let token = pending.token
        yadif.drain { [weak self] in
            self?.hooks.schedule { [weak self] in
                guard let self,
                      let current = self.pendingNaturalDrain,
                      current.token == token,
                      current.generation == self.generation,
                      current.yadifDrainRequested,
                      !self.stopped,
                      self.pendingHLSYADIF.isEmpty else { return }
                self.pendingNaturalDrain = nil
                current.completion(.completed)
            }
        }
    }

    private func failPendingNaturalDrain() {
        guard let pending = pendingNaturalDrain else { return }
        pendingNaturalDrain = nil
        pending.completion(.failed(.malfunction(kVTInvalidSessionErr)))
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
        metrics?.recordVideoDrop(source: .decoderRecoverable)
        handleRecoveryDecision(recoveryBudget.requestRecovery(for: .sessionFailure))
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

    private func restartDecoderForRecovery() {
        hooks.closeAdmission()
        let oldGeneration = generation
        generation = hooks.advanceGeneration()
        processingAdmissionFloor = nil
        routeEpoch &+= 1
        classifier.rebasePreservingClassification(generation: generation)
        normalizer.rebindDecoderGeneration(generation)
        passthrough.reset(to: generation)
        yadif.reset(to: generation)
        probe?.stop(generation: oldGeneration)
        previousProbeBuffer = nil
        completedClassificationProbeCount = 0
        clearActiveProbeSubmission()
        decoderConfigured = false
        waitingForRandomAccess = true
        activeDecoderIdentity = nil
        pendingDecoderConfiguration = nil
        hooks.resetPlayback(generation, requiredVideoFrameCount, .decoderSession)
        beginDecoderInvalidation(
            generation: generation,
            drain: false,
            reopenAdmission: true
        )
    }

    private func submitProbe(for frame: DecodedVideoFrame) {
        defer { previousProbeBuffer = frame.pixelBuffer }
        guard route == .rawWhileClassifying,
              let probe,
              let previousProbeBuffer else { return }
        let submittedGeneration = generation
        let submittedEpoch = routeEpoch
        if activeProbeSubmissionID == nil {
            nextProbeSubmissionID &+= 1
            let submissionID = nextProbeSubmissionID
            activeProbeSubmissionID = submissionID
            let token = signposts?.begin(.scanProbe, correlation: frame.accessUnitID)
            activeProbeSignpostLifetime = PlaybackSignpostLifetime(
                signposts: signposts,
                token: token
            )
            let accepted = probe.submit(
                current: frame.pixelBuffer,
                previous: previousProbeBuffer,
                generation: submittedGeneration
            ) { [weak self] result in
                guard let self else { return }
                hooks.schedule { [weak self] in
                    guard let self else { return }
                    if activeProbeSubmissionID == submissionID {
                        clearActiveProbeSubmission()
                    }
                    guard !stopped,
                          generation == submittedGeneration,
                          routeEpoch == submittedEpoch else {
                        metrics?.recordStaleGenerationDrop()
                        return
                    }
                    completedClassificationProbeCount += 1
                    switch result {
                    case let .success(sample):
                        observeSupplementalProbe(frame, sample: sample)
                    case .failure:
                        observeProbeFailure(frame)
                    }
                    if route == .rawWhileClassifying,
                       completedClassificationProbeCount
                           >= Self.maximumClassificationProbeAttempts {
                        resolveAfterProbeBudget(frame)
                    }
                }
            }
            if !accepted, activeProbeSubmissionID == submissionID {
                clearActiveProbeSubmission()
                resolveAfterProbeBudget(frame)
            }
        }
    }

    private func clearActiveProbeSubmission() {
        activeProbeSubmissionID = nil
        activeProbeSignpostLifetime?.finish()
        activeProbeSignpostLifetime = nil
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
        completedClassificationProbeCount = 0
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
        completedClassificationProbeCount = 0
        metrics?.update(scanType: change.current)
        applyResolvedRoute()
    }

    private func process(_ normalized: NormalizedDecodedFrame) {
        let submittedGeneration = generation
        let submittedEpoch = routeEpoch
        let submittedAccessUnitID = normalized.frame.accessUnitID
        let submittedPresentationTimeStamp = normalized.presentationTimeStamp
        let completion: @Sendable (VideoProcessingResult) -> Void = { [weak self] result in
            guard let self else { return }
            // YADIF 会在 completion 返回后立即调度下一个 ready job，而 production
            // owner lane 是异步的。原子 data-plane 准入本身是锁保护的同步合同，
            // 因此必须在 GPU callback 返回前完成；owner lane 只处理控制副作用。
            let preadmission: VideoAtomicEncodingAdmissionResult?
            if case let .produced(batch) = result, let atomicEncodingAdmission {
                yadif.setSubmissionSchedulingPaused(true)
                preadmission = atomicEncodingAdmission.submit(
                    .batch(batch), generation: submittedGeneration
                )
                if preadmission == .accepted {
                    yadif.setSubmissionSchedulingPaused(false)
                }
            } else {
                preadmission = nil
            }
            hooks.schedule { [weak self] in
                guard let self else { return }
                var keepYADIFSchedulingPaused = false
                defer {
                    if atomicEncodingAdmission != nil, !keepYADIFSchedulingPaused {
                        yadif.setSubmissionSchedulingPaused(false)
                    }
                }
                guard !stopped,
                      generation == submittedGeneration,
                      routeEpoch == submittedEpoch else {
                    metrics?.recordStaleGenerationDrop()
                    return
                }
                if let floor = processingAdmissionFloor {
                    guard floor.generation == submittedGeneration,
                          submittedAccessUnitID >= floor.minimumAccessUnitID else {
                        return
                    }
                }
                switch result {
                case let .produced(batch):
                    if let preadmission {
                        switch preadmission {
                        case .accepted:
                            return
                        case .retry:
                            // bridge 已经以独立收费 owner 持有完整 batch。立刻关上
                            // 上游 admission，等待 producer 调用 retryPending… 后再开。
                            yadif.setSubmissionSchedulingPaused(true)
                            keepYADIFSchedulingPaused = true
                            hooks.closeAdmission()
                            return
                        case .rejected:
                            yadif.setSubmissionSchedulingPaused(true)
                            keepYADIFSchedulingPaused = true
                            hooks.fail(.metalCommand("hls.atomicEncoding.submit"),
                                       submittedGeneration)
                            return
                        }
                    }
                    if let atomicEncodingSink {
                        if let floor = processingAdmissionFloor {
                            guard batch.outputs.allSatisfy({ output in
                                let frame = output.frame
                                return frame.generation == floor.generation
                                    && frame.sourceAccessUnitID >= floor.minimumAccessUnitID
                                    && frame.presentationTimeStamp.isNumeric
                                    && CMTimeCompare(
                                        frame.presentationTimeStamp,
                                        floor.minimumOutputPTS
                                    ) >= 0
                            }) else { return }
                        }
                        atomicEncodingSink(.batch(batch), submittedGeneration)
                        return
                    }
                    let frames = batch.frames
                    let admittedFrames: [VideoPresentationFrame]
                    if let floor = processingAdmissionFloor {
                        admittedFrames = frames.filter { frame in
                            frame.generation == floor.generation
                                && frame.sourceAccessUnitID >= floor.minimumAccessUnitID
                                && frame.presentationTimeStamp.isNumeric
                                && CMTimeCompare(
                                    frame.presentationTimeStamp,
                                    floor.minimumOutputPTS
                                ) >= 0
                        }
                    } else {
                        admittedFrames = frames
                    }
                    if !admittedFrames.isEmpty {
                        hooks.deliver(admittedFrames, submittedGeneration)
                    }
                case let .transientDrop(reason):
                    guard admitsNonFrameProcessingCompletion(
                        presentationTimeStamp: submittedPresentationTimeStamp
                    ) else { return }
                    switch reason {
                    case .queuePressure:
                        // YADIF records the two discarded fields at the point
                        // where the bounded queue rejects the input. Recording
                        // again here would count one input as three drops.
                        break
                    case .resourcePressure, .invalidTiming:
                        metrics?.recordVideoDrop(source: .deinterlaceFailure)
                    }
                case let .structuralFailure(failure):
                    guard admitsNonFrameProcessingCompletion(
                        presentationTimeStamp: submittedPresentationTimeStamp
                    ) else { return }
                    metrics?.recordVideoDrop(source: .deinterlaceFailure)
                    handleProcessingStructuralFailure(failure)
                case .cancelled:
                    guard admitsNonFrameProcessingCompletion(
                        presentationTimeStamp: submittedPresentationTimeStamp
                    ) else { return }
                    break
                }
            }
        }

        if route == .metalYADIF2x {
            let order: ResolvedFieldOrder
            if atomicEncodingSink != nil || atomicEncodingAdmission != nil {
                switch fieldOrderAdmission(for: normalized.frame) {
                case let .reliable(reliableOrder):
                    order = reliableOrder
                case let .failure(reason):
                    let failure = VideoAtomicEncodingFailure(
                        sourceAccessUnitID: normalized.frame.accessUnitID,
                        reason: reason
                    )
                    if let atomicEncodingAdmission {
                        switch atomicEncodingAdmission.submit(
                            .failure(failure), generation: submittedGeneration
                        ) {
                        case .accepted:
                            break
                        case .retry:
                            yadif.setSubmissionSchedulingPaused(true)
                            hooks.closeAdmission()
                        case .rejected:
                            yadif.setSubmissionSchedulingPaused(true)
                            hooks.fail(.metalCommand("hls.atomicEncoding.failure"),
                                       submittedGeneration)
                        }
                    } else {
                        atomicEncodingSink?(.failure(failure), submittedGeneration)
                    }
                    return
                }
            } else if case let .interlaced(o) = classifier.current {
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
            if atomicEncodingAdmission != nil {
                // A released GPU slot must not let a newer decoder callback
                // overtake the already retained FIFO head.
                if !pendingHLSYADIF.isEmpty {
                    enqueueHLSYADIF(normalized, order: order, completion: completion,
                                    generation: submittedGeneration)
                    return
                }
                switch yadif.trySubmit(normalized: normalized, order: order,
                                      discontinuity: false, completion: completion) {
                case .accepted: break
                case .retry:
                    enqueueHLSYADIF(normalized, order: order, completion: completion,
                                    generation: submittedGeneration)
                }
            } else {
                yadif.submit(normalized: normalized, order: order, discontinuity: false, completion: completion)
            }
            return
        }

        passthrough.submit(normalizedFrame(from: normalized), completion: completion)
    }

    private func retryPendingHLSYADIF() {
        guard !stopped,
              atomicEncodingAdmission?.hasPendingWork != true,
              let pending = pendingHLSYADIF.first else { return }
        switch yadif.trySubmit(normalized: pending.frame, order: pending.order,
                              discontinuity: false, completion: pending.completion) {
        case .accepted:
            pendingHLSYADIF.removeFirst()
            reopenAdmissionIfSafe()
            advanceNaturalDrainIfReady()
        case .retry: break
        }
    }

    private func enqueueHLSYADIF(_ frame: NormalizedDecodedFrame, order: ResolvedFieldOrder,
                                 completion: @escaping @Sendable (VideoProcessingResult) -> Void,
                                 generation: MediaGeneration) {
        guard pendingHLSYADIF.count < maximumHLSPendingYADIFFrames else {
            hooks.fail(.metalCommand("hls.yadif.pending"), generation); return
        }
        pendingHLSYADIF.append(.init(frame: frame, order: order, completion: completion))
        hooks.closeAdmission()
    }

    private func reopenAdmissionIfSafe() {
        guard !stopped, pendingHLSYADIF.isEmpty, pendingDecoderConfiguration == nil,
              pendingDecoderInvalidation == nil, atomicEncodingAdmission?.hasPendingWork != true else { return }
        hooks.reopenAdmission()
    }

    private enum FieldOrderAdmission {
        case reliable(ResolvedFieldOrder)
        case failure(VideoAtomicEncodingFieldOrderFailureReason)
    }

    /// 编码路径只认可当前帧或当前格式的直接证据，不能借用分类器保留的旧场序。
    private func fieldOrderAdmission(
        for frame: DecodedVideoFrame
    ) -> FieldOrderAdmission {
        var candidates: [ResolvedFieldOrder] = []
        candidates.reserveCapacity(5)

        if let coded = frame.parserMetadata.fieldOrder,
           let order = resolvedOrder(coded, source: .parser) {
            candidates.append(order)
        }
        if let topFieldFirst = frame.parserMetadata.topFieldFirst {
            candidates.append(ResolvedFieldOrder(
                parity: topFieldFirst ? .top : .bottom,
                confidence: .signaled,
                source: .parser
            ))
        }
        // pictureStructure 只说明当前 picture 是顶场还是底场，并不说明展示场序。
        // 编码 admission 必须分别读取像素与格式两层，才能看见两者互相矛盾。
        let pixelEvidence = fieldReader.read(
            formatDescription: nil,
            pixelBuffer: frame.pixelBuffer
        )
        if let pixelOrder = pixelEvidence.fieldOrder {
            candidates.append(pixelOrder)
        }
        let formatEvidence = fieldReader.read(
            formatDescription: videoFormat,
            pixelBuffer: nil
        )
        if let formatOrder = formatEvidence.fieldOrder {
            candidates.append(formatOrder)
        }
        if let streamOrder = resolvedOrder(streamFieldOrder, source: .stream) {
            candidates.append(streamOrder)
        }

        guard let first = candidates.first else {
            if case let .interlaced(classified) = classifier.current,
               classified.confidence == .assumed || classified.source == .none {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("atomic_field_assumed_empty")
                #endif
                return .failure(.assumed)
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("atomic_field_missing")
            #endif
            return .failure(.missing)
        }
        guard candidates.allSatisfy({ candidate in
            candidate.confidence != .assumed && candidate.source != .none
        }) else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("atomic_field_assumed_candidate")
            #endif
            return .failure(.assumed)
        }
        guard candidates.dropFirst().allSatisfy({ $0.parity == first.parity }) else {
            #if DEBUG
            let detail = candidates.map {
                "\($0.parity)-\($0.source)-\($0.confidence)"
            }.joined(separator: "_")
            PlaybackDiagnosticTracker.shared.append("atomic_field_conflict_\(detail)")
            #endif
            return .failure(.conflicting)
        }
        return .reliable(first)
    }

    private func resolvedOrder(
        _ coded: CodedFieldOrder,
        source: FieldEvidenceSource
    ) -> ResolvedFieldOrder? {
        let parity: FieldParity
        switch coded {
        case .tt, .bt:
            parity = .top
        case .bb, .tb:
            parity = .bottom
        case .unknown, .progressive:
            return nil
        }
        return ResolvedFieldOrder(
            parity: parity,
            confidence: .signaled,
            source: source
        )
    }

    private func admitsNonFrameProcessingCompletion(
        presentationTimeStamp: CMTime
    ) -> Bool {
        guard let floor = processingAdmissionFloor else { return true }
        return presentationTimeStamp.isNumeric
            && CMTimeCompare(presentationTimeStamp, floor.minimumOutputPTS) >= 0
    }

    private func handleProcessingStructuralFailure(
        _ failure: VideoProcessingStructuralFailure
    ) {
        switch recoveryBudget.requestRecovery(for: .processingStructural) {
        case .none:
            break
        case .recover:
            restartDecoderForRecovery()
        case .exhausted:
            hooks.fail(Self.coreError(for: failure), generation)
        }
    }

    private static func coreError(
        for failure: VideoProcessingStructuralFailure
    ) -> PlaybackCoreError {
        switch failure {
        case .invalidSurface:
            .metalCommand("yadif.surface.invalid")
        case .surfacePool:
            .metalCommand("yadif.surface.pool")
        case .rendererAttributes:
            .metalCommand("yadif.renderer.attributes")
        case .textureMapping:
            .metalCommand("yadif.texture.mapping")
        case .shaderPipeline:
            .metalCommand("yadif.shader.pipeline")
        case .commandExecution:
            .metalCommand("yadif.command.execution")
        }
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
            formatMetadata: frame.formatMetadata,
            retentionTail: frame.retentionTail
        )
    }
}
