// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct HLSTimelineGeneration: RawRepresentable, Sendable, Hashable, Comparable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum HLSMediaOriginSource: Sendable, Hashable {
    case videoIDR
    case completeAudioAccessUnit
}

struct ExactMediaTime: Sendable, Hashable {
    let value: Int64
    let timescale: Int32

    init(value: Int64, timescale: Int32) {
        precondition(timescale > 0)
        let divisor = greatestCommonDivisor(value.magnitude, UInt64(timescale))
        self.value = value / Int64(divisor)
        self.timescale = timescale / Int32(divisor)
    }

    init(_ time: CMTime) throws {
        guard time.isNumeric, time.epoch == 0, time.timescale > 0 else {
            throw HLSTimelineError.invalidTime
        }
        self.init(value: time.value, timescale: time.timescale)
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }

    func adding(_ other: Self) throws -> Self { try combining(other, subtract: false) }
    func subtracting(_ other: Self) throws -> Self { try combining(other, subtract: true) }

    private func combining(_ other: Self, subtract: Bool) throws -> Self {
        let divisor = greatestCommonDivisor(UInt64(timescale), UInt64(other.timescale))
        let leftMultiplier = Int128(other.timescale) / Int128(divisor)
        let rightMultiplier = Int128(timescale) / Int128(divisor)
        let commonScale = Int128(timescale) * leftMultiplier
        // 两个 Int64 分子乘 Int32 比例时，中间值可能超过 Int64，但相消、约分后的
        // 结果仍完全可表示。必须在 signed 128-bit 域完成乘加，再以 commonScale
        // 的余数求最终公因数；只有约分后的分子/分母仍放不回公开表示时才失败。
        let left = Int128(value) * leftMultiplier
        let rightMultiplierWithSign = subtract ? -rightMultiplier : rightMultiplier
        let result = left + Int128(other.value) * rightMultiplierWithSign
        let commonScale64 = UInt64(commonScale)
        let resultDivisor = greatestCommonDivisor(
            UInt64(result.magnitude % UInt128(commonScale64)), commonScale64
        )
        guard let reducedValue = Int64(exactly: result / Int128(resultDivisor)),
              let reducedScale = Int32(exactly: commonScale64 / resultDivisor) else {
            throw HLSTimelineError.arithmeticOverflow
        }
        return Self(value: reducedValue, timescale: reducedScale)
    }
}

struct MediaOriginReceipt: Sendable, Hashable {
    let generation: HLSTimelineGeneration
    let sourceTime: ExactMediaTime
    let effectiveStart: ExactMediaTime
    let source: HLSMediaOriginSource
}

/// 只能由持有当前 output binding 的 timeline 从真实 origin 与完整音频 AU 签发。
final class HLSTimelineCompressedAudioCandidatePlan: @unchecked Sendable, Hashable {
    fileprivate let timelineIssuer: HLSTimelineCoordinator
    let outputBinding: CompressedAudioOutputPlanBinding
    let sharedControlExecutor: PlaybackControlExecutor
    fileprivate let timelineBinding: AssemblyEpochBinding
    fileprivate let operationID: AssemblyOperationID
    let generation: HLSTimelineGeneration
    let originReceipt: MediaOriginReceipt
    let accessUnitInterval: CompressedAudioAccessUnitInterval
    let mediaOrigin: CMTime
    let firstAuthorizedAccessUnitStart: CMTime
    let originDecision: CompressedAudioOriginDecision

    fileprivate init(
        timelineIssuer: HLSTimelineCoordinator,
        outputBinding: CompressedAudioOutputPlanBinding,
        sharedControlExecutor: PlaybackControlExecutor,
        timelineBinding: AssemblyEpochBinding,
        operationID: AssemblyOperationID,
        generation: HLSTimelineGeneration,
        originReceipt: MediaOriginReceipt,
        accessUnitInterval: CompressedAudioAccessUnitInterval,
        firstAuthorizedAccessUnitStart: CMTime,
        originDecision: CompressedAudioOriginDecision
    ) {
        self.timelineIssuer = timelineIssuer
        self.outputBinding = outputBinding
        self.sharedControlExecutor = sharedControlExecutor
        self.timelineBinding = timelineBinding
        self.operationID = operationID
        self.generation = generation
        self.originReceipt = originReceipt
        self.accessUnitInterval = accessUnitInterval
        mediaOrigin = originReceipt.sourceTime.cmTime
        self.firstAuthorizedAccessUnitStart = firstAuthorizedAccessUnitStart
        self.originDecision = originDecision
    }

    var isCurrent: Bool { timelineIssuer.acceptsCompressedAudioCandidatePlan(self) }

    static func == (
        lhs: HLSTimelineCompressedAudioCandidatePlan,
        rhs: HLSTimelineCompressedAudioCandidatePlan
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct NormalizedSampleTiming: Sendable, Hashable {
    let presentationTimeStamp: ExactMediaTime
    let decodeTimeStamp: ExactMediaTime?
    let duration: ExactMediaTime?
}

/// 只有 timeline 在实际 emission 时能附加的进程内签发身份。
final class HLSTimedVideoAccessUnitAuthority: @unchecked Sendable {
    fileprivate init() {}
}

struct HLSTimedVideoAccessUnit: @unchecked Sendable {
    let source: CompressedVideoAccessUnit
    let generation: HLSTimelineGeneration
    let timing: NormalizedSampleTiming
    fileprivate let origin: MediaOriginReceipt
    fileprivate let authority: HLSTimedVideoAccessUnitAuthority

    fileprivate init(
        source: CompressedVideoAccessUnit,
        generation: HLSTimelineGeneration,
        timing: NormalizedSampleTiming,
        origin: MediaOriginReceipt,
        authority: HLSTimedVideoAccessUnitAuthority
    ) {
        self.source = source
        self.generation = generation
        self.timing = timing
        self.origin = origin
        self.authority = authority
    }

    var remuxTimelineIdentity: ObjectIdentifier { ObjectIdentifier(authority) }
    var remuxTimelineAuthority: HLSTimedVideoAccessUnitAuthority { authority }

    /// 重新读取同一 AU 的原始 timing/backing，并复算 origin 平移。
    func validatesRemuxSource(
        admission: VideoRemuxAdmissionProof,
        backing: VideoAccessUnitBacking,
        byteRange: VideoAccessUnitByteRange
    ) -> Bool {
        guard generation == origin.generation,
              generation.rawValue == source.generation.rawValue,
              admission.generation == source.generation,
              source.id == backing.identity.accessUnitID,
              source.sourceBacking === backing,
              source.sourceByteRange == byteRange,
              let sourceSHA256 = source.sourceSHA256,
              admission.source.identity.matches(
                backing: backing,
                byteRange: byteRange,
                sourceSHA256: sourceSHA256
              ),
              let rawPTS = try? ExactMediaTime(
                CMSampleBufferGetPresentationTimeStamp(source.sampleBuffer)
              ),
              let rawDuration = try? ExactMediaTime(
                CMSampleBufferGetDuration(source.sampleBuffer)
              ),
              rawDuration.value > 0,
              admission.source.presentationTimeStamp == rawPTS,
              admission.source.duration == rawDuration,
              let sourceDelta = try? rawPTS.subtracting(origin.sourceTime),
              let mappedPTS = try? origin.effectiveStart.adding(sourceDelta),
              mappedPTS == timing.presentationTimeStamp,
              timing.duration == rawDuration else { return false }

        let sourceDTS = CMSampleBufferGetDecodeTimeStamp(source.sampleBuffer)
        if sourceDTS.isNumeric {
            guard let rawDTS = try? ExactMediaTime(sourceDTS),
                  admission.source.decodeTimeStamp == rawDTS,
                  let decodeDelta = try? rawDTS.subtracting(origin.sourceTime),
                  let mappedDTS = try? origin.effectiveStart.adding(decodeDelta),
                  timing.decodeTimeStamp == mappedDTS else { return false }
        } else if admission.source.decodeTimeStamp != nil || timing.decodeTimeStamp != nil {
            return false
        }
        return true
    }
}

enum HLSAudioBoundaryDecision: Sendable, Hashable {
    case unchanged
    case trimLeading(ExactMediaTime)
}

struct HLSTimedAudioAccessUnit: Sendable {
    let source: CompressedAudioFrame
    let generation: HLSTimelineGeneration
    let timing: NormalizedSampleTiming
    let boundaryDecision: HLSAudioBoundaryDecision
}

enum HLSGenerationEndReason: Sendable, Equatable {
    case formatChange
    case timelineReset
    case endOfStream
    case cancelled
    case failed(PlaybackCoreError)
}

enum HLSTimelineTerminal: Sendable, Equatable {
    case endOfStream
    case noEligibleOrigin
    case cancelled
    case failed(PlaybackCoreError)
}

enum HLSTimelineEvent: @unchecked Sendable {
    case originEstablished(MediaOriginReceipt)
    /// 已通过本 generation 格式漂移检查的真实压缩音频配置。production HLS 图用它
    /// 构造唯一 FFmpeg decoder；不能从 codec 名称猜 extradata 或 sample description。
    case audioFormat(CompressedAudioRenderConfiguration)
    case videoSample(HLSTimedVideoAccessUnit)
    case audioSample(HLSTimedAudioAccessUnit)
    case generationEnded(HLSTimelineGeneration, reason: HLSGenerationEndReason)
    case terminal(HLSTimelineTerminal)
}

enum HLSTimelineError: Error, Equatable {
    case invalidTime
    case arithmeticOverflow
    case sourceBeforeOrigin
    case pendingAudioColdStartSpanExceeded
    case pendingAudioColdStartByteBudgetExceeded
    case terminal
}

struct WriterTimelineMapping: Sendable, Hashable {
    let delta: ExactMediaTime

    func writtenTime(for source: ExactMediaTime) throws -> ExactMediaTime {
        let result = try source.adding(delta)
        guard result.value >= 0 else { throw HLSTimelineError.sourceBeforeOrigin }
        return result
    }

    func effectiveWrittenBase(inputEffectiveBase: ExactMediaTime) throws -> ExactMediaTime {
        let result = try inputEffectiveBase.adding(delta)
        guard result.value >= 0 else { throw HLSTimelineError.sourceBeforeOrigin }
        return result
    }
}

final class HLSTimelineCoordinator {
    private struct FormatReplaySeed {
        let target: FormatDriftTarget
        let formatSnapshot: AssemblyFormatSnapshot
        let audioFormat: CompressedAudioRenderConfiguration?
        let audioFingerprint: MediaFormatFingerprint?
        let videoFormat: CMVideoFormatDescription?
        let videoFingerprint: MediaFormatFingerprint?
    }

    private enum FormatDriftTarget {
        case audio(CompressedAudioRenderConfiguration)
        case video(CMVideoFormatDescription, MediaFormatFingerprint)

        var blocksAudio: Bool {
            if case .audio = self { return true }
            return false
        }

        var blocksVideo: Bool {
            if case .video = self { return true }
            return false
        }

        func matches(_ configuration: CompressedAudioRenderConfiguration) -> Bool {
            guard case let .audio(target) = self else { return false }
            return target.fingerprint == configuration.fingerprint
                && target.codec == configuration.codec
                && target.decoderExtradata == configuration.decoderExtradata
                && CMFormatDescriptionEqual(
                    target.formatDescription,
                    otherFormatDescription: configuration.formatDescription
                )
        }

        func matches(
            _ format: CMVideoFormatDescription,
            fingerprint: MediaFormatFingerprint
        ) -> Bool {
            guard case let .video(targetFormat, targetFingerprint) = self else {
                return false
            }
            return targetFingerprint == fingerprint
                && CMFormatDescriptionEqual(
                    targetFormat,
                    otherFormatDescription: format
                )
        }
    }

    private final class GenerationState {
        let generation: HLSTimelineGeneration
        let tracks: DemuxTrackSet
        let binding: AssemblyEpochBinding
        let formatState: AssemblyFormatState
        var acceptedFormatSnapshot: AssemblyFormatSnapshot
        var scanClassifier: ScanTypeClassifier
        var audioAssembler: CompressedAudioAssembler?
        var videoAssembler: CompressedVideoAssembler?
        var audioFormat: CompressedAudioRenderConfiguration?
        var audioFingerprint: MediaFormatFingerprint?
        var videoFormat: CMVideoFormatDescription?
        var videoFingerprint: MediaFormatFingerprint?
        var canonicalFingerprint: MediaFormatFingerprint?
        var pendingFormatDrift: FormatDriftTarget?
        var replayTarget: FormatDriftTarget?
        var pendingAudio: [CompressedAudioFrame] = []
        var pendingAudioBytes = 0
        var pendingAudioMinimumStart: ExactMediaTime?
        var pendingAudioMaximumEnd: ExactMediaTime?
        var origin: MediaOriginReceipt?
        var latestCompleteAudioAccessUnitInterval: CompressedAudioAccessUnitInterval?

        init(
            generation: HLSTimelineGeneration,
            tracks: DemuxTrackSet,
            formatSnapshot: AssemblyFormatSnapshot? = nil
        ) {
            self.generation = generation
            self.tracks = tracks
            formatState = AssemblyFormatState(
                trackSet: tracks,
                videoParameterSets: formatSnapshot?.videoParameterSets ?? [],
                hlsVideoParameterSetOwner: formatSnapshot?.hlsVideoParameterSetOwner,
                audioSystemFormat: formatSnapshot?.audioSystemFormat
            )
            acceptedFormatSnapshot = formatSnapshot ?? AssemblyFormatSnapshot(
                videoParameterSets: [],
                audioSystemFormat: nil
            )
            scanClassifier = ScanTypeClassifier(
                generation: MediaGeneration(rawValue: generation.rawValue)
            )
            binding = AssemblyEpochBinding(epochID: AssemblyEpochID(
                timelineEpoch: TimelineEpochID(rawValue: generation.rawValue),
                instanceToken: generation.rawValue
            ))
        }
    }

    private static let effectiveStart = ExactMediaTime(value: 10, timescale: 1)
    /// 未知 origin 时不得靠淘汰旧 AU 猜测安全边界，冷启动支持域容纳大 GOP（如 4K 广播流）。
    private static let maximumPendingAudioColdStartSpan = ExactMediaTime(
        value: 15,
        timescale: 1
    )
    private static let maximumPendingAudioBytes = 4 * 1_024 * 1_024
    private let parserFactory: any FFmpegParserFactory
    private let hlsVideoCopyOwnership: HLSVideoCopyOwnership?
    private let compressedAudioOutputPlanBinding: CompressedAudioOutputPlanBinding?
    private let sharedControlExecutor: PlaybackControlExecutor?
    /// 独立身份避免在初始化期间把 timeline 自身暴露给跨 coordinator 的 claim。
    private let compressedAudioPlanIssuer = NSObject()
    private var claimedCompressedAudioOutputPlanBinding = false
    private var generation = HLSTimelineGeneration(rawValue: 0)
    private let timedVideoAuthority = HLSTimedVideoAccessUnitAuthority()
    private var state: GenerationState?
    private var emissions: [HLSTimelineEvent] = []
    private var terminalDelivered = false
    private var callbackFailure: Error?

    init(
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        compressedAudioOutputPlanBinding: CompressedAudioOutputPlanBinding? = nil,
        hlsVideoCopyOwnership: HLSVideoCopyOwnership? = nil
    ) {
        self.parserFactory = parserFactory
        self.hlsVideoCopyOwnership = hlsVideoCopyOwnership
        self.compressedAudioOutputPlanBinding = compressedAudioOutputPlanBinding
        sharedControlExecutor = compressedAudioOutputPlanBinding?.sharedControlExecutor
        if let compressedAudioOutputPlanBinding {
            claimedCompressedAudioOutputPlanBinding = compressedAudioOutputPlanBinding
                .sharedControlExecutor.sync {
                    compressedAudioOutputPlanBinding.claimTimeline(compressedAudioPlanIssuer)
                }
        }
    }

    /// 不接收 raw origin、interval、codec 或 admission；全部从当前状态与既有 binding 读取。
    func makeCompressedAudioCandidatePlan() -> HLSTimelineCompressedAudioCandidatePlan? {
        if let sharedControlExecutor {
            return sharedControlExecutor.sync { makeCompressedAudioCandidatePlanIsolated() }
        }
        return makeCompressedAudioCandidatePlanIsolated()
    }

    private func makeCompressedAudioCandidatePlanIsolated() -> HLSTimelineCompressedAudioCandidatePlan? {
        guard claimedCompressedAudioOutputPlanBinding,
              let outputBinding = compressedAudioOutputPlanBinding,
              let sharedControlExecutor,
              outputBinding.sharedControlExecutor === sharedControlExecutor,
              outputBinding.isClaimed(by: compressedAudioPlanIssuer),
              outputBinding.isCurrent(),
              let state,
              let audio = state.tracks.audio,
              audio.streamIndex == outputBinding.sourceStreamIndex,
              audio.codec == outputBinding.codec,
              audio.sampleRate == outputBinding.sourceSampleRate,
              let origin = state.origin,
              origin.generation == state.generation,
              let interval = state.latestCompleteAudioAccessUnitInterval,
              let operationID = state.binding.currentOperationID(),
              let eligibility = try? CompressedAudioOriginPlanner.evaluate(
                  codec: audio.codec,
                  accessUnitInterval: interval,
                  mediaOrigin: origin.sourceTime.cmTime,
                  itemGeneration: outputBinding.itemGeneration
              ),
              eligibility.authorizes(itemGeneration: outputBinding.itemGeneration),
              case let .eligible(eligibleUnit) = eligibility.decision else { return nil }
        let firstStart = eligibleUnit == .currentAccessUnit ? interval.start : interval.end
        return HLSTimelineCompressedAudioCandidatePlan(
            timelineIssuer: self,
            outputBinding: outputBinding,
            sharedControlExecutor: sharedControlExecutor,
            timelineBinding: state.binding,
            operationID: operationID,
            generation: state.generation,
            originReceipt: origin,
            accessUnitInterval: interval,
            firstAuthorizedAccessUnitStart: firstStart,
            originDecision: eligibility.decision
        )
    }

    fileprivate func acceptsCompressedAudioCandidatePlan(
        _ plan: HLSTimelineCompressedAudioCandidatePlan
    ) -> Bool {
        if let sharedControlExecutor {
            return sharedControlExecutor.sync {
                acceptsCompressedAudioCandidatePlanIsolated(plan)
            }
        }
        return acceptsCompressedAudioCandidatePlanIsolated(plan)
    }

    private func acceptsCompressedAudioCandidatePlanIsolated(
        _ plan: HLSTimelineCompressedAudioCandidatePlan
    ) -> Bool {
        guard plan.timelineIssuer === self,
              let outputBinding = compressedAudioOutputPlanBinding,
              let sharedControlExecutor,
              plan.sharedControlExecutor === sharedControlExecutor,
              outputBinding.sharedControlExecutor === sharedControlExecutor,
              plan.outputBinding === outputBinding,
              outputBinding.isClaimed(by: compressedAudioPlanIssuer),
              let state,
              state.binding === plan.timelineBinding,
              state.binding.accepts(plan.operationID),
              state.generation == plan.generation,
              state.origin == plan.originReceipt else {
            return false
        }
        return true
    }

    func consume(_ event: DemuxEvent) throws -> [HLSTimelineEvent] {
        if let sharedControlExecutor {
            return try sharedControlExecutor.sync { try consumeIsolated(event) }
        }
        return try consumeIsolated(event)
    }

    private func consumeIsolated(_ event: DemuxEvent) throws -> [HLSTimelineEvent] {
        if terminalDelivered {
            switch event {
            case .endOfStream, .cancelled, .failure:
                return []
            case .tracks, .packet, .discontinuity:
                break
            }
            throw HLSTimelineError.terminal
        }
        emissions.removeAll(keepingCapacity: true)
        callbackFailure = nil
        switch event {
        case let .tracks(tracks):
            guard state == nil else { throw HLSTimelineError.terminal }
            try install(tracks)
        case let .packet(packet):
            guard let state else { throw HLSTimelineError.invalidTime }
            try push(packet, to: state)
            try throwCallbackFailure()
            if let replayState = try finishPendingFormatDrift(for: state) {
                try push(packet, to: replayState)
                try throwCallbackFailure()
                _ = try finishPendingFormatDrift(for: replayState)
            }
        case let .discontinuity(tracks, reason):
            try endGeneration(reason == .formatChange ? .formatChange : .timelineReset)
            generation = try nextGeneration(after: generation)
            try install(tracks)
        case .endOfStream:
            if let state {
                try state.audioAssembler?.drain()
                try state.videoAssembler?.drain()
                try throwCallbackFailure()
                let hasOrigin = state.origin != nil
                endGenerationWithoutDrain(.endOfStream)
                emissions.append(.terminal(hasOrigin ? .endOfStream : .noEligibleOrigin))
            } else {
                emissions.append(.terminal(.noEligibleOrigin))
            }
            terminalDelivered = true
        case .cancelled:
            endGenerationWithoutDrain(.cancelled)
            emissions.append(.terminal(.cancelled))
            terminalDelivered = true
        case let .failure(error):
            endGenerationWithoutDrain(.failed(error))
            emissions.append(.terminal(.failed(error)))
            terminalDelivered = true
        }
        return emissions
    }

    func normalize(
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime,
        duration: CMTime,
        relativeTo origin: MediaOriginReceipt
    ) throws -> NormalizedSampleTiming {
        let presentation = try ExactMediaTime(presentationTimeStamp)
        let sourceDelta = try presentation.subtracting(origin.sourceTime)
        guard sourceDelta.value >= 0 else { throw HLSTimelineError.sourceBeforeOrigin }
        let mappedPresentation = try origin.effectiveStart.adding(sourceDelta)
        let mappedDecode: ExactMediaTime?
        if decodeTimeStamp.isValid {
            let decode = try ExactMediaTime(decodeTimeStamp)
            let decodeDelta = try decode.subtracting(origin.sourceTime)
            let candidate = try origin.effectiveStart.adding(decodeDelta)
            guard candidate.value >= 0 else { throw HLSTimelineError.sourceBeforeOrigin }
            mappedDecode = candidate
        } else {
            mappedDecode = nil
        }
        let mappedDuration: ExactMediaTime?
        if duration.isValid {
            let candidate = try ExactMediaTime(duration)
            guard candidate.value >= 0 else { throw HLSTimelineError.invalidTime }
            mappedDuration = candidate
        } else {
            mappedDuration = nil
        }
        return NormalizedSampleTiming(
            presentationTimeStamp: mappedPresentation,
            decodeTimeStamp: mappedDecode,
            duration: mappedDuration
        )
    }

    @discardableResult
    private func install(
        _ tracks: DemuxTrackSet,
        replaySeed: FormatReplaySeed? = nil
    ) throws -> GenerationState {
        let installed = GenerationState(
            generation: generation,
            tracks: tracks,
            formatSnapshot: replaySeed?.formatSnapshot
        )
        installed.replayTarget = replaySeed?.target
        installed.audioFormat = replaySeed?.audioFormat
        installed.audioFingerprint = replaySeed?.audioFingerprint
        installed.videoFormat = replaySeed?.videoFormat
        installed.videoFingerprint = replaySeed?.videoFingerprint
        if let fieldOrder = tracks.video?.fieldOrder {
            _ = installed.scanClassifier.observeStreamFieldOrder(
                fieldOrder,
                generation: MediaGeneration(rawValue: generation.rawValue)
            )
        }
        if tracks.audio != nil {
            installed.audioAssembler = try CompressedAudioAssembler(
                trackSet: tracks,
                generationProvider: { MediaGeneration(rawValue: installed.generation.rawValue) },
                eventSink: { [weak self, weak installed] event in
                    guard let self, callbackFailure == nil,
                          let installed, state === installed else { return }
                    do { try receiveAudio(event, state: installed) }
                    catch { callbackFailure = error }
                },
                parserFactory: parserFactory,
                formatState: installed.formatState,
                binding: installed.binding
            )
        }
        if tracks.video != nil {
            installed.videoAssembler = try CompressedVideoAssembler(
                trackSet: tracks,
                generationProvider: { MediaGeneration(rawValue: installed.generation.rawValue) },
                eventSink: { [weak self, weak installed] event in
                    guard let self, callbackFailure == nil,
                          let installed, state === installed else { return }
                    do { try receiveVideo(event, state: installed) }
                    catch { callbackFailure = error }
                },
                parserFactory: parserFactory,
                formatState: installed.formatState,
                binding: installed.binding,
                hlsCopyOwnership: hlsVideoCopyOwnership
            )
        }
        state = installed
        return installed
    }

    private func push(_ packet: DemuxPacket, to state: GenerationState) throws {
        if let audio = state.tracks.audio,
           packet.streamIndex == audio.streamIndex,
           packet.codec == .audio(audio.codec) {
            try state.audioAssembler?.push(packet)
        } else if let video = state.tracks.video,
                  packet.streamIndex == video.streamIndex,
                  packet.codec == .video(video.codec) {
            try state.videoAssembler?.push(packet)
        }
    }

    private func finishPendingFormatDrift(
        for pushedState: GenerationState
    ) throws -> GenerationState? {
        guard state === pushedState,
              let replayTarget = pushedState.pendingFormatDrift else {
            return nil
        }
        let tracks = pushedState.tracks
        let seed = FormatReplaySeed(
            target: replayTarget,
            formatSnapshot: pushedState.acceptedFormatSnapshot,
            audioFormat: replayTarget.blocksVideo ? pushedState.audioFormat : nil,
            audioFingerprint: replayTarget.blocksVideo ? pushedState.audioFingerprint : nil,
            videoFormat: replayTarget.blocksAudio ? pushedState.videoFormat : nil,
            videoFingerprint: replayTarget.blocksAudio ? pushedState.videoFingerprint : nil
        )
        endGenerationWithoutDrain(.formatChange)
        generation = try nextGeneration(after: generation)
        return try install(tracks, replaySeed: seed)
    }

    private func receiveAudio(_ event: AudioAssemblerEvent, state: GenerationState) throws {
        switch event {
        case let .format(configuration):
            recordAudioFormat(configuration, state: state)
        case let .frame(frame):
            guard state.pendingFormatDrift == nil,
                  state.replayTarget?.blocksAudio != true else {
                return
            }
            state.latestCompleteAudioAccessUnitInterval = try CompressedAudioAccessUnitInterval(
                start: frame.presentationTimeStamp,
                end: CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            )
            if state.tracks.video == nil, state.origin == nil {
                let receipt = MediaOriginReceipt(
                    generation: state.generation,
                    sourceTime: try ExactMediaTime(frame.presentationTimeStamp),
                    effectiveStart: Self.effectiveStart,
                    source: .completeAudioAccessUnit
                )
                state.origin = receipt
                emissions.append(.originEstablished(receipt))
            }
            guard let origin = state.origin else {
                try retainPendingAudio(frame, state: state)
                return
            }
            try emitAudio(frame, relativeTo: origin, state: state)
        case .decodeBreak:
            break
        }
    }

    private func receiveVideo(_ event: VideoAssemblerEvent, state: GenerationState) throws {
        switch event {
        case let .format(format, fingerprint):
            recordVideoFormat(format, fingerprint: fingerprint, state: state)
        case let .accessUnit(accessUnit):
            guard state.pendingFormatDrift == nil,
                  state.replayTarget?.blocksVideo != true else {
                return
            }
            let mediaGeneration = MediaGeneration(rawValue: state.generation.rawValue)
            _ = state.scanClassifier.observe(ScanObservation(
                generation: mediaGeneration,
                parser: accessUnit.parserMetadata,
                decodedFields: FieldMetadataEvidence(
                    fieldCount: nil,
                    fieldOrder: nil,
                    source: .none
                ),
                probe: nil,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(
                    accessUnit.sampleBuffer
                )
            ))
            let isIDR = accessUnit.randomAccessKind == .h264IDR ||
                accessUnit.randomAccessKind == .hevcIDR
            if state.origin == nil,
               state.tracks.audio == nil || state.audioFormat != nil,
               state.videoFormat != nil,
               scanClassificationIsResolved(state.scanClassifier.current),
               isIDR {
                let receipt = MediaOriginReceipt(
                    generation: state.generation,
                    sourceTime: try ExactMediaTime(
                        CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer)
                    ),
                    effectiveStart: Self.effectiveStart,
                    source: .videoIDR
                )
                state.origin = receipt
                emissions.append(.originEstablished(receipt))
                try flushPendingAudio(relativeTo: receipt, state: state)
            }
            guard let origin = state.origin else { return }
            let timing = try normalize(
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(accessUnit.sampleBuffer),
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(accessUnit.sampleBuffer),
                duration: CMSampleBufferGetDuration(accessUnit.sampleBuffer),
                relativeTo: origin
            )
            emissions.append(.videoSample(HLSTimedVideoAccessUnit(
                source: accessUnit,
                generation: state.generation,
                timing: timing,
                origin: origin,
                authority: timedVideoAuthority
            )))
        }
    }

    private func recordAudioFormat(
        _ configuration: CompressedAudioRenderConfiguration,
        state: GenerationState
    ) {
        guard state.pendingFormatDrift == nil else { return }
        if let replayTarget = state.replayTarget, replayTarget.blocksAudio {
            guard replayTarget.matches(configuration) else { return }
            state.replayTarget = nil
        }
        if let previous = state.audioFormat,
           (previous.codec != configuration.codec
            || previous.decoderExtradata != configuration.decoderExtradata
            || !CMFormatDescriptionEqual(
                previous.formatDescription,
                otherFormatDescription: configuration.formatDescription
            )) {
            state.pendingFormatDrift = .audio(configuration)
            return
        }
        if let canonical = state.canonicalFingerprint,
           canonical != configuration.fingerprint {
            state.pendingFormatDrift = .audio(configuration)
            return
        }
        let firstAcceptedFormat = state.audioFormat == nil
        state.audioFormat = configuration
        state.audioFingerprint = configuration.fingerprint
        state.acceptedFormatSnapshot = state.formatState.snapshot()
        establishCanonicalFingerprintIfComplete(
            configuration.fingerprint,
            driftTarget: .audio(configuration),
            state: state
        )
        if firstAcceptedFormat {
            emissions.append(.audioFormat(configuration))
        }
    }

    private func recordVideoFormat(
        _ format: CMVideoFormatDescription,
        fingerprint: MediaFormatFingerprint,
        state: GenerationState
    ) {
        guard state.pendingFormatDrift == nil else { return }
        if let replayTarget = state.replayTarget, replayTarget.blocksVideo {
            guard replayTarget.matches(format, fingerprint: fingerprint) else { return }
            state.replayTarget = nil
        }
        if let previous = state.videoFormat,
           !CMFormatDescriptionEqual(previous, otherFormatDescription: format) {
            state.pendingFormatDrift = .video(format, fingerprint)
            return
        }
        if let canonical = state.canonicalFingerprint,
           canonical != fingerprint {
            state.pendingFormatDrift = .video(format, fingerprint)
            return
        }
        state.videoFormat = format
        state.videoFingerprint = fingerprint
        state.acceptedFormatSnapshot = state.formatState.snapshot()
        establishCanonicalFingerprintIfComplete(
            fingerprint,
            driftTarget: .video(format, fingerprint),
            state: state
        )
    }

    private func establishCanonicalFingerprintIfComplete(
        _ fingerprint: MediaFormatFingerprint,
        driftTarget: FormatDriftTarget,
        state: GenerationState
    ) {
        guard state.pendingFormatDrift == nil,
              state.tracks.audio == nil || state.audioFormat != nil,
              state.tracks.video == nil || state.videoFormat != nil else {
            return
        }
        if let canonical = state.canonicalFingerprint {
            if canonical != fingerprint {
                state.pendingFormatDrift = driftTarget
            }
        } else {
            state.canonicalFingerprint = fingerprint
        }
    }

    private func scanClassificationIsResolved(_ scan: ScanType) -> Bool {
        if case .unknown = scan { return false }
        return true
    }

    private func retainPendingAudio(
        _ frame: CompressedAudioFrame,
        state: GenerationState
    ) throws {
        let interval = try audioInterval(frame)
        let byteCount = frame.payload.count
        let (newByteCount, byteOverflow) = state.pendingAudioBytes
            .addingReportingOverflow(byteCount)
        guard !byteOverflow, newByteCount <= Self.maximumPendingAudioBytes else {
            throw HLSTimelineError.pendingAudioColdStartByteBudgetExceeded
        }

        let minimumStart: ExactMediaTime
        if let current = state.pendingAudioMinimumStart {
            let delta = try interval.start.subtracting(current)
            minimumStart = delta.value < 0 ? interval.start : current
        } else {
            minimumStart = interval.start
        }
        let maximumEnd: ExactMediaTime
        if let current = state.pendingAudioMaximumEnd {
            let delta = try interval.end.subtracting(current)
            maximumEnd = delta.value > 0 ? interval.end : current
        } else {
            maximumEnd = interval.end
        }
        let span = try maximumEnd.subtracting(minimumStart)
        let spanExcess = try span.subtracting(Self.maximumPendingAudioColdStartSpan)
        guard spanExcess.value <= 0 else {
            throw HLSTimelineError.pendingAudioColdStartSpanExceeded
        }

        state.pendingAudio.append(frame)
        state.pendingAudioBytes = newByteCount
        state.pendingAudioMinimumStart = minimumStart
        state.pendingAudioMaximumEnd = maximumEnd
    }

    private func flushPendingAudio(
        relativeTo origin: MediaOriginReceipt,
        state: GenerationState
    ) throws {
        let pending = state.pendingAudio
        state.pendingAudio.removeAll(keepingCapacity: false)
        state.pendingAudioBytes = 0
        state.pendingAudioMinimumStart = nil
        state.pendingAudioMaximumEnd = nil
        for frame in pending {
            try emitAudio(frame, relativeTo: origin, state: state)
        }
    }

    private func emitAudio(
        _ frame: CompressedAudioFrame,
        relativeTo origin: MediaOriginReceipt,
        state: GenerationState
    ) throws {
        let interval = try audioInterval(frame)
        let sourceStart = interval.start
        let sourceEnd = interval.end
        let endDelta = try sourceEnd.subtracting(origin.sourceTime)
        guard endDelta.value > 0 else { return }

        let startDelta = try sourceStart.subtracting(origin.sourceTime)
        let timing: NormalizedSampleTiming
        let decision: HLSAudioBoundaryDecision
        if startDelta.value < 0 {
            let leadingTrim = try origin.sourceTime.subtracting(sourceStart)
            timing = NormalizedSampleTiming(
                presentationTimeStamp: origin.effectiveStart,
                decodeTimeStamp: nil,
                duration: endDelta
            )
            decision = .trimLeading(leadingTrim)
        } else {
            timing = try normalize(
                presentationTimeStamp: frame.presentationTimeStamp,
                decodeTimeStamp: .invalid,
                duration: frame.duration,
                relativeTo: origin
            )
            decision = .unchanged
        }
        emissions.append(.audioSample(HLSTimedAudioAccessUnit(
            source: frame,
            generation: state.generation,
            timing: timing,
            boundaryDecision: decision
        )))
    }

    private func audioInterval(
        _ frame: CompressedAudioFrame
    ) throws -> (start: ExactMediaTime, end: ExactMediaTime) {
        let start = try ExactMediaTime(frame.presentationTimeStamp)
        let duration = try ExactMediaTime(frame.duration)
        guard duration.value > 0 else { throw HLSTimelineError.invalidTime }
        return (start, try start.adding(duration))
    }

    private func endGeneration(_ reason: HLSGenerationEndReason) throws {
        guard let state else { return }
        try state.audioAssembler?.drain()
        try state.videoAssembler?.drain()
        try throwCallbackFailure()
        state.binding.invalidate()
        emissions.append(.generationEnded(state.generation, reason: reason))
        self.state = nil
    }

    private func endGenerationWithoutDrain(_ reason: HLSGenerationEndReason) {
        guard let state else { return }
        state.binding.invalidate()
        emissions.append(.generationEnded(state.generation, reason: reason))
        self.state = nil
    }

    private func nextGeneration(after current: HLSTimelineGeneration) throws -> HLSTimelineGeneration {
        let (next, overflow) = current.rawValue.addingReportingOverflow(1)
        guard !overflow else { throw HLSTimelineError.arithmeticOverflow }
        return HLSTimelineGeneration(rawValue: next)
    }

    private func throwCallbackFailure() throws {
        guard let failure = callbackFailure else { return }
        callbackFailure = nil
        state?.binding.invalidate()
        state = nil
        terminalDelivered = true
        throw failure
    }
}

private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 { (first, second) = (second, first % second) }
    return first == 0 ? 1 : first
}
