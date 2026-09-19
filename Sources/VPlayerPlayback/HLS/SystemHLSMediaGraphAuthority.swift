// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import Metal

/// 渐进视频即将推进共同边界前，必须先让已排队音频追到上一视频时刻。
/// 隔行分支的安全终点由转码输出的 `writtenThrough` 单独证明，不能复用输入 PTS。
enum HLSMediaGraphAudioDrainPolicy {
    enum InterlacedTrigger: Sendable {
        case audioSampleQueued
        case videoSampleSubmitted
    }

    /// writer 输出已协作暂停后，音频可以且必须一次追到已证明的安全终点。
    /// 再加固定批量上限会在视频异步输出跳跃时永久累积段落差。
    static let interlacedMaximumCount: Int? = nil

    static func drainBeforeVideo(
        pendingAudioCount: Int,
        hasAudioBranch: Bool,
        hasInterlacedVideoBranch: Bool,
        previousVideoPTS: CMTime?
    ) -> CMTime? {
        guard pendingAudioCount > 0,
              hasAudioBranch,
              !hasInterlacedVideoBranch else { return nil }
        return previousVideoPTS
    }

    static func drainBehindInterlacedVideo(
        pendingAudioCount: Int,
        writtenThrough: CMTime?,
        trigger: InterlacedTrigger
    ) -> CMTime? {
        switch trigger {
        case .audioSampleQueued, .videoSampleSubmitted:
            break
        }
        guard pendingAudioCount > 0, let writtenThrough,
              writtenThrough.isNumeric, writtenThrough.epoch == 0 else { return nil }
        let safeEnd = CMTimeSubtract(writtenThrough, CMTime(value: 1, timescale: 1))
        guard safeEnd.isNumeric, safeEnd.epoch == 0,
              CMTimeCompare(safeEnd, .zero) > 0 else { return nil }
        return safeEnd
    }
}

/// 隔行链路的在途水位必须按真实 decoder frame 计算。压缩 AU 可以合法地不产出
/// frame；若按已提交 AU 假定每个都有两场输出，第一次无输出就会让目标永久不可达。
enum HLSInterlacedOutputWatermark {
    private static let retainedDecodedFrameCount = 30

    static func targetOutputCount(
        decodedFrameCount: Int,
        outputFramesPerDecodedFrame: Int
    ) -> Int? {
        guard decodedFrameCount > retainedDecodedFrameCount,
              outputFramesPerDecodedFrame > 0 else { return nil }
        let value = (decodedFrameCount - retainedDecodedFrameCount)
            .multipliedReportingOverflow(by: outputFramesPerDecodedFrame)
        return value.overflow ? Int.max : value.partialValue
    }
}

/// 视频输入容量关闭时，媒体 worker 必须继续读取后到的音频包，不能原地等待。
/// FIFO 仍保持固定上限，防止上游异常交错把压缩 AU 变成无界内存。
enum HLSInterlacedDeferredInputPolicy {
    enum Action: Sendable, Equatable {
        case enqueue
        case enqueueToReachAudioBoundary
        case waitForCapacity
        case rejectAudioBoundaryStall
    }

    static let maximumCount = 256
    /// TS 中音视频是交错到达的。writer 若因音频边界暂停，必须允许
    /// 单一 media worker 跨过少量视频 AU 继续读到音频；64 帧对 25i
    /// 等价于 2.56 秒源时间，足以覆盖正常 PES 交错，且仍严格有界。
    static let audioBoundaryEscapeCount = 64
    static let maximumAudioBoundaryCount = maximumCount + audioBoundaryEscapeCount

    static func action(
        currentCount: Int,
        requiresAudioBoundaryProgress: Bool
    ) -> Action {
        guard currentCount >= 0 else { return .waitForCapacity }
        if currentCount < maximumCount { return .enqueue }
        guard requiresAudioBoundaryProgress else { return .waitForCapacity }
        return currentCount < maximumAudioBoundaryCount
            ? .enqueueToReachAudioBoundary
            : .rejectAudioBoundaryStall
    }

    static func canEnqueue(currentCount: Int) -> Bool {
        action(
            currentCount: currentCount,
            requiresAudioBoundaryProgress: false
        ) == .enqueue
    }
}

/// 隔行直播必须让 GPU 命令有有限重叠，并保留每个输入帧的两个场时间点。
/// YADIFProcessor 自身仍以 ready queue、surface credit 和下游原子准入共同限流。
enum HLSInterlacedYADIFPolicy {
    static let maximumInFlight = 3
    static let cadence: HLSVideoTranscodeCadencePolicy =
        .preserveAllFields

    static func outputFrameRate(for sourceFrameRate: MediaRational) -> MediaRational? {
        let doubled = Int64(sourceFrameRate.num).multipliedReportingOverflow(by: 2)
        guard !doubled.overflow,
              let numerator = Int32(exactly: doubled.partialValue) else { return nil }
        return MediaRational(num: numerator, den: sourceFrameRate.den)
    }
}

/// 单 source item 的生产媒体图 owner。demux callback 只移交带 admission tail 的事件；
/// 唯一 worker 顺序执行 timeline、音视频 writer、publisher 与自然 EOF。
final class SystemHLSMediaGraphAuthority: SystemHLSDeliveryGraphAuthority, @unchecked Sendable {
    private final class BoundaryHolder: @unchecked Sendable {
        let value: SegmentBoundaryCoordinator
        init(_ value: SegmentBoundaryCoordinator) { self.value = value }
    }

    /// HLS 离线生成没有 render synchronizer；YADIF 只要求一个稳定、不会把
    /// GPU 完成时间误当媒体时间的时钟。离线/HLS 转码不存在实时晚到丢帧，
    /// currentTime 固定返回 .zero，绝不因输入端时间戳超前而诱发伪超时丢帧。
    private final class HLSGenerationClock: PlaybackClock, @unchecked Sendable {
        var currentTime: CMTime { .zero }
        func pause() {}
        func anchor(mediaTime _: CMTime, atHostTime _: CMTime, rate _: Float) {}
        func setRate(_: Float) {}
    }

    /// VT 的输出格式只能在第一帧回调后取得，因此 writer 在该回调中以真实
    /// CMSampleBuffer format description 建立，不能猜测隔行源的压缩格式。
    private final class InterlacedVideoOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let appendGate = NSLock()
        private let writerQueue = DispatchQueue(
            label: "org.vplayer.hls.interlaced-video-writer",
            qos: .userInitiated)
        private let publication: SystemHLSPublicationGraph
        private var binding: FMP4WriterBinding
        private let boundary: SegmentBoundaryCoordinator
        private let expectedVideoStart: CMTime
        private let outputSemaphore: DispatchSemaphore
        private let inputCapacityWakeup: HLSVideoInputCapacityWakeup
        private weak var authority: SystemHLSMediaGraphAuthority?
        private var writer: SegmentedFMP4Writer?
        private var lastWrittenPTS: CMTime?
        private var lastWrittenDuration: CMTime?
        private var lastWrittenSourceIdentity: VideoEncodingFrameIdentity?
        private var firstOutputFormat: CMFormatDescription?
        private var writtenOutputCount = 0
        private var diagnosticStage = "idle"
        private var pending: [HLSVideoEncodedOutputEnvelope] = []
        private var pendingRolloverWriter: SegmentedFMP4Writer?
        private var processing = false
        private var rolloverActive = false
        private var audioFlushActive = false
        private var audioFlushContinuation: CheckedContinuation<Bool, Never>?
        /// appendGate 保护。异步 block 尚未在 writerQueue 落入 pending 前也必须
        /// 算作排队，否则窗口收尾会过早重开快路径并让后来的帧越序。
        private var scheduledPendingCount = 0
        private var boundaryRetryCount = 0
        private var finishContinuation: CheckedContinuation<Void, Error>?

        init(publication: SystemHLSPublicationGraph, binding: FMP4WriterBinding,
             boundary: SegmentBoundaryCoordinator, expectedVideoStart: CMTime,
             outputSemaphore: DispatchSemaphore,
             inputCapacityWakeup: HLSVideoInputCapacityWakeup,
             authority: SystemHLSMediaGraphAuthority) {
            self.publication = publication
            self.binding = binding
            self.boundary = boundary
            self.expectedVideoStart = expectedVideoStart
            self.outputSemaphore = outputSemaphore
            self.inputCapacityWakeup = inputCapacityWakeup
            self.authority = authority
            boundary.installAudioBoundaryAdvanceSink { [weak self] in
                guard let self else { return }
                self.writerQueue.async { [weak self] in
                    self?.drainPending()
                }
            }
        }

        func append(_ envelope: HLSVideoEncodedOutputEnvelope) {
            // 普通 AVAssetWriter append 保留在 VT 的串行提交链上；真机把每一帧都
            // 搬到另一条队列会让 AVAssetWriterInput 在窗口末端阻塞。只有 rollover
            // 才转交拥有 backing 的 envelope，确保异步 finish 不等待当前 callback。
            appendGate.lock()
            if rolloverActive || audioFlushActive || !boundary.interlacedVideoLeadHasCapacity {
                rolloverActive = true
                scheduledPendingCount += 1
                appendGate.unlock()
                enqueue(envelope)
                return
            }
            var appendResult: Result<SegmentedFMP4Writer?, Error>?
            envelope.withBorrowedOutput { output in
                appendResult = Result { try beginAppend(output) }
            }
            guard let appendResult else {
                appendGate.unlock()
                reportFailure(envelope, error: HLSVideoRemuxSubmissionFailure.writerAttemptMismatch)
                return
            }
            switch appendResult {
            case .success(nil):
                appendGate.unlock()
            case .success(let rollover?):
                rolloverActive = true
                scheduledPendingCount += 1
                appendGate.unlock()
                writerQueue.async { [self, envelope, rollover] in
                    pendingRolloverWriter = rollover
                    pending.append(envelope)
                    appendGate.withLock { scheduledPendingCount -= 1 }
                    drainPending()
                }
            case .failure(SegmentBoundaryFailure.ticketMismatch):
                rolloverActive = true
                scheduledPendingCount += 1
                appendGate.unlock()
                enqueue(envelope)
            case .failure(let error):
                appendGate.unlock()
                reportFailure(envelope, error: error)
            }
        }

        private func enqueue(_ envelope: HLSVideoEncodedOutputEnvelope) {
            writerQueue.async { [self, envelope] in
                lock.withLock { diagnosticStage = "queued" }
                pending.append(envelope)
                appendGate.withLock { scheduledPendingCount -= 1 }
                drainPending()
            }
        }

        private func beginAppend(
            _ output: HLSVideoEncodedOutput
        ) throws -> SegmentedFMP4Writer? {
            lock.withLock { diagnosticStage = "requiringFormat" }
            let format = try requireFormat(output)
            lock.withLock {
                if firstOutputFormat == nil { firstOutputFormat = format }
                diagnosticStage = "makingWriter"
            }
            let active = try writer ?? makeWriter(
                format: format, continuation: nil, initial: true,
                startTime: CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer))
            do {
                lock.withLock { diagnosticStage = "issuingBoundaryTicket" }
                let ticket = try boundary.issueVideoAppend(
                    for: output,
                    writerBinding: binding
                )
                lock.withLock { diagnosticStage = "writerAppend" }
                try active.appendVideo(
                    output,
                    ticket: ticket)
                lock.withLock {
                    diagnosticStage = "written"
                    lastWrittenPTS = CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer)
                    lastWrittenDuration = CMSampleBufferGetDuration(output.sampleBuffer)
                    lastWrittenSourceIdentity = output.sourceIdentity
                    writtenOutputCount += 1
                }
                outputSemaphore.signal()
                return nil
            } catch SegmentedFMP4WriterFailure.rolloverRequired {
                return active
            }
        }

        private func drainPending() {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            guard !appendGate.withLock({ audioFlushActive }) else {
                grantAudioFlushIfPossible()
                return
            }
            guard !processing else { return }
            guard let envelope = pending.first else {
                beginFinishIfRequested()
                return
            }
            guard boundary.interlacedVideoLeadHasCapacity else {
                lock.withLock { diagnosticStage = "waitingAudioBoundary" }
                // 容量 producer 可能正在等 video branch；同一 media worker
                // 必须立即被唤醒，才能跨过已交错的视频 AU 读到音频。
                inputCapacityWakeup.signal()
                return
            }
            processing = true
            lock.withLock { diagnosticStage = "appending" }
            do {
                if let rollover = pendingRolloverWriter {
                    pendingRolloverWriter = nil
                    beginRollover(rollover, envelope: envelope)
                    return
                }
                var appendResult: Result<SegmentedFMP4Writer?, Error>?
                envelope.withBorrowedOutput { output in
                    appendResult = Result { try beginAppend(output) }
                }
                guard let appendResult else {
                    throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
                }
                let rollover = try appendResult.get()
                guard let rollover else {
                    completeCurrentEnvelope()
                    return
                }
                beginRollover(rollover, envelope: envelope)
            } catch SegmentBoundaryFailure.ticketMismatch {
                retryCurrentEnvelope(envelope)
            } catch {
                failCurrentEnvelope(envelope, error: error)
            }
        }

        private func beginRollover(
            _ rollover: SegmentedFMP4Writer,
            envelope: HLSVideoEncodedOutputEnvelope
        ) {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            Task {
                lock.withLock { diagnosticStage = "finishingWindow" }
                let result: Result<WriterWindowContinuation, Error>
                do { result = .success(try await rollover.finishWriterWindow()) }
                catch { result = .failure(error) }
                writerQueue.async { [self, envelope] in
                    do {
                        lock.withLock { diagnosticStage = "installingSuccessor" }
                        let continuation = try result.get()
                        lock.withLock { diagnosticStage = "successorBinding" }
                        binding = try successorBinding(after: binding)
                        var successorResult: Result<Void, Error>?
                        envelope.withBorrowedOutput { output in
                            successorResult = Result {
                                lock.withLock { diagnosticStage = "successorMakeWriter" }
                                let successor = try makeWriter(
                                    format: try requireFormat(output),
                                    continuation: continuation,
                                    initial: false, startTime: .zero)
                                lock.withLock { diagnosticStage = "successorBoundaryTicket" }
                                let ticket = try boundary.issueVideoAppend(
                                    for: output, writerBinding: binding)
                                lock.withLock { diagnosticStage = "successorAppend" }
                                try successor.appendVideo(
                                    output,
                                    ticket: ticket)
                                lock.withLock { diagnosticStage = "successorAppended" }
                                lock.withLock {
                                    lastWrittenPTS = CMSampleBufferGetPresentationTimeStamp(
                                        output.sampleBuffer)
                                    lastWrittenDuration = CMSampleBufferGetDuration(
                                        output.sampleBuffer)
                                    lastWrittenSourceIdentity = output.sourceIdentity
                                    writtenOutputCount += 1
                                }
                            }
                        }
                        guard let successorResult else {
                            throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
                        }
                        try successorResult.get()
                        outputSemaphore.signal()
                        completeCurrentEnvelope()
                    } catch SegmentBoundaryFailure.ticketMismatch {
                        retryCurrentEnvelope(envelope)
                    } catch {
                        failCurrentEnvelope(envelope, error: error)
                    }
                }
            }
        }

        private func completeCurrentEnvelope() {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            if !pending.isEmpty { pending.removeFirst() }
            processing = false
            boundaryRetryCount = 0
            if pending.isEmpty {
                appendGate.withLock {
                    if scheduledPendingCount == 0 { rolloverActive = false }
                }
            }
            drainPending()
        }

        private func grantAudioFlushIfPossible() {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            guard !processing, let continuation = audioFlushContinuation else { return }
            audioFlushContinuation = nil
            continuation.resume(returning: true)
        }

        private func retryCurrentEnvelope(_ envelope: HLSVideoEncodedOutputEnvelope) {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            boundaryRetryCount += 1
            guard boundaryRetryCount <= 5_000 else {
                failCurrentEnvelope(envelope, error: SegmentBoundaryFailure.ticketMismatch)
                return
            }
            processing = false
            lock.withLock { diagnosticStage = "waitingBoundaryTicket" }
            writerQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
                drainPending()
            }
        }

        private func failCurrentEnvelope(
            _ envelope: HLSVideoEncodedOutputEnvelope,
            error: Error
        ) {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            envelope.withBorrowedOutput { output in
                let pts = CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer)
                let stage = lock.withLock { diagnosticStage }
                authority?.fail(PlaybackCoreError.videoSampleBuffer(
                    "task22.interlaced.output pts=\(pts.value)/\(pts.timescale) " +
                    "expected=\(expectedVideoStart.value)/\(expectedVideoStart.timescale) " +
                    "stage=\(stage) " +
                    "context=\(failureContext(output)) " +
                    "underlying=\(String(reflecting: error))"))
            }
            completeCurrentEnvelope()
        }

        private func reportFailure(
            _ envelope: HLSVideoEncodedOutputEnvelope,
            error: Error
        ) {
            envelope.withBorrowedOutput { output in
                let pts = CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer)
                let stage = lock.withLock { diagnosticStage }
                authority?.fail(PlaybackCoreError.videoSampleBuffer(
                    "task22.interlaced.output pts=\(pts.value)/\(pts.timescale) " +
                    "expected=\(expectedVideoStart.value)/\(expectedVideoStart.timescale) " +
                    "stage=\(stage) " +
                    "context=\(failureContext(output)) " +
                    "underlying=\(String(reflecting: error))"))
            }
        }

        private func failureContext(_ output: HLSVideoEncodedOutput) -> String {
            let sample = output.sampleBuffer
            let duration = CMSampleBufferGetDuration(sample)
            let format = CMSampleBufferGetFormatDescription(sample)
            let snapshot = lock.withLock {
                (
                    lastWrittenPTS,
                    lastWrittenDuration,
                    firstOutputFormat,
                    writtenOutputCount,
                    lastWrittenSourceIdentity
                )
            }
            let formatMatches = if let format, let first = snapshot.2 {
                CMFormatDescriptionEqual(format, otherFormatDescription: first)
            } else {
                false
            }
            let dimensions = format.map { CMVideoFormatDescriptionGetDimensions($0) }
            let lastPTS = snapshot.0.map { "\($0.value)/\($0.timescale)" } ?? "nil"
            let lastDuration = snapshot.1.map { "\($0.value)/\($0.timescale)" } ?? "nil"
            let dimensionsText = dimensions.map { "\($0.width)x\($0.height)" } ?? "nil"
            let lastSource = snapshot.4.map {
                "au\($0.accessUnitID)-seq\($0.sequenceNumber)-g\($0.generation.rawValue)"
            } ?? "nil"
            let currentSource = output.sourceIdentity
            return "duration=\(duration.value)/\(duration.timescale) " +
                "lastPTS=\(lastPTS) " +
                "lastDuration=\(lastDuration) " +
                "formatMatchesFirst=\(formatMatches) " +
                "dimensions=\(dimensionsText) " +
                "lastSource=\(lastSource) " +
                "currentSource=au\(currentSource.accessUnitID)" +
                "-seq\(currentSource.sequenceNumber)-g\(currentSource.generation.rawValue) " +
                "written=\(snapshot.3)"
        }

        private func makeWriter(
            format: CMFormatDescription, continuation: WriterWindowContinuation?,
            initial: Bool, startTime: CMTime
        ) throws -> SegmentedFMP4Writer {
            let currentBinding = binding
            let created = try publication.makeRelay(
                binding: currentBinding, mediaType: .video, limits: .video,
                initial: initial
            ) { relay in
                try SegmentedFMP4Writer(
                    binding: currentBinding, trackKind: .video, sourceFormatHint: format,
                    boundarySession: boundary.session,
                    compressedFormatConfiguration: nil,
                    videoCadencePolicy: .strict, relay: relay,
                    systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
                    writerWindowContinuation: continuation)
            }
            try created.start(at: startTime)
            writer = created
            return created
        }

        private func successorBinding(after previous: FMP4WriterBinding) throws
            -> FMP4WriterBinding {
            FMP4WriterBinding(
                outputLifecycleEpoch: previous.outputLifecycleEpoch,
                itemGeneration: previous.itemGeneration,
                mediaEpoch: previous.mediaEpoch,
                publicationParticipantID: previous.publicationParticipantID,
                renditionIdentity: previous.renditionIdentity,
                writerIdentity: .init(rawValue:
                    try PlaybackIdentityAllocator.shared.next(in: .nonce)))
        }

        private func requireFormat(_ output: HLSVideoEncodedOutput) throws
            -> CMFormatDescription {
            guard let value = CMSampleBufferGetFormatDescription(output.sampleBuffer) else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            return value
        }

        func finish() async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                writerQueue.async { [self] in
                    guard finishContinuation == nil else {
                        continuation.resume(
                            throwing: SegmentedFMP4WriterFailure.illegalState)
                        return
                    }
                    finishContinuation = continuation
                    drainPending()
                }
            }
        }

        private func beginFinishIfRequested() {
            dispatchPrecondition(condition: .onQueue(writerQueue))
            guard !processing, pending.isEmpty,
                  let continuation = finishContinuation else { return }
            finishContinuation = nil
            guard let writer else {
                continuation.resume(
                    throwing: HLSVideoRemuxSubmissionFailure.writerAttemptMismatch)
                return
            }
            processing = true
            Task {
                let result: Result<Void, Error>
                do { _ = try await writer.finish(); result = .success(()) }
                catch { result = .failure(error) }
                writerQueue.async { [self] in
                    processing = false
                    continuation.resume(with: result)
                }
            }
        }

        var writtenThrough: CMTime? { lock.withLock { lastWrittenPTS } }
        var outputCount: Int { lock.withLock { writtenOutputCount } }
        var requiresAudioBoundaryProgress: Bool {
            lock.withLock { diagnosticStage == "waitingAudioBoundary" }
        }

        func beginAudioFlush() async -> Bool {
            let claimed = appendGate.withLock { () -> Bool in
                guard !audioFlushActive else { return false }
                audioFlushActive = true
                return true
            }
            guard claimed else { return false }
            return await withCheckedContinuation { continuation in
                writerQueue.async { [self] in
                    guard appendGate.withLock({ audioFlushActive }) else {
                        continuation.resume(returning: false)
                        return
                    }
                    guard audioFlushContinuation == nil else {
                        continuation.resume(returning: false)
                        return
                    }
                    audioFlushContinuation = continuation
                    grantAudioFlushIfPossible()
                }
            }
        }

        func endAudioFlush() {
            appendGate.withLock { audioFlushActive = false }
            writerQueue.async { [self] in drainPending() }
        }
        var stageForDiagnostics: String { lock.withLock { diagnosticStage } }

        func cancel() {
            appendGate.withLock { audioFlushActive = false }
            writerQueue.async { [self] in
                if let continuation = audioFlushContinuation {
                    audioFlushContinuation = nil
                    continuation.resume(returning: false)
                }
                _ = writer?.cancel()
            }
        }
    }
    private enum State { case reading, playable, finishing, retiring, retired, failed }

    private let condition = NSCondition()
    private let lifecycle: OutputLifecycleEpoch
    private let itemGeneration: UInt64
    private let publication: SystemHLSPublicationGraph
    private let publicationDeadlineNanoseconds: Int64
    private let publicationWaitInterval: TimeInterval
    private let timeline = HLSTimelineCoordinator()
    private let stream: AsyncStream<AdmittedDemuxEvent>
    private let streamContinuation: AsyncStream<AdmittedDemuxEvent>.Continuation
    private var worker: Task<Void, Never>!
    private var state: State = .reading
    private var terminalResult: Bool?
    private var failureDescription: String?
    private var diagnosticStage = "configured"
    private var loopbackServer: LoopbackHTTPServer?

    // 以下只由 worker 访问，retire 在 worker 终止后才释放。
    private var tracks: DemuxTrackSet?
    private var retainedTrackOwner: AdmittedDemuxEvent?
    private var boundary: SegmentBoundaryCoordinator?
    private var mediaEpoch: AudioMediaEpochIdentity?
    private var videoBinding: FMP4WriterBinding?
    private var videoWriter: SegmentedFMP4Writer?
    private var interlacedVideoBranch: HLSVideoBranch?
    private var interlacedVideoOutput: InterlacedVideoOutput?
    private var interlacedInputWakeup: HLSVideoInputCapacityWakeup?
    private let interlacedOutputSemaphore = DispatchSemaphore(value: 0)
    private var interlacedSubmittedCount = 0
    private let interlacedGenerationClock = HLSGenerationClock()
    private var pendingInterlacedVideo: [(HLSTimedVideoAccessUnit, VideoAccessUnitInspectionProof)] = []
    private var interlacedProbeStart: CMTime?
    private var interlacedProbeEnd = CMTime.zero
    private var interlacedProbeBytes: UInt64 = 0
    private var videoInspection: VideoAccessUnitInspectionSession?
    private var videoEligibility: VideoRemuxEligibility?
    private var videoBuilder: HLSVideoRemuxSubmissionBuilder?
    private var videoFrameRateConfigured = false
    private var audioConfiguration: CompressedAudioRenderConfiguration?
    private var audioCalibration: AACCalibrationReceipt?
    private var audioBridge: SystemHLSAudioPCMBridge?
    private var audioConverter: AudioRenditionConverter?
    private var audioBranch: AudioRenditionBranch?
    private var pendingAudio: [HLSTimedAudioAccessUnit] = []
    private var maxVideoPTS: CMTime?
    private var sourcePCMIndex: Int64 = 0
    #if DEBUG
    private var previousRandomAccessDiagnostic: (
        pts: ExactMediaTime,
        dts: ExactMediaTime?,
        digest: VideoAccessUnitSHA256,
        accessUnitID: UInt64
    )?
    #endif

    init(
        lifecycle: OutputLifecycleEpoch,
        publicationDeadlineNanoseconds: Int64 = 120_000_000_000
    ) throws {
        guard publicationDeadlineNanoseconds > 0 else {
            throw HLSPublicationFailure.invalidDuration
        }
        self.lifecycle = lifecycle
        itemGeneration = lifecycle.outputNonce
        self.publicationDeadlineNanoseconds = publicationDeadlineNanoseconds
        publicationWaitInterval = TimeInterval(publicationDeadlineNanoseconds)
            / 1_000_000_000
        publication = try SystemHLSPublicationGraph(
            itemGeneration: lifecycle.outputNonce,
            publicationDeadlineNanoseconds: publicationDeadlineNanoseconds)
        let pair = AsyncStream<AdmittedDemuxEvent>.makeStream()
        stream = pair.stream
        streamContinuation = pair.continuation
        worker = Task { [weak self] in await self?.run() }
    }

    func append(_ admitted: AdmittedDemuxEvent) {
        switch streamContinuation.yield(admitted) {
        case .enqueued:
            if admitted.isTerminal { streamContinuation.finish() }
        case .dropped:
            fail(AVPlayerItemCoordinatorFailure.capacityExceeded)
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private func run() async {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("g_run_started")
        #endif
        do {
            for await admitted in stream {
                try Task.checkCancellation()
                var borrowed: DemuxEvent?
                admitted.withBorrowedEvent { borrowed = $0 }
                guard let borrowed else { continue }
                switch borrowed {
                case .tracks(let value), .discontinuity(let value, _):
                    tracks = value
                    retainedTrackOwner = admitted
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.set("g_got_tracks")
                    #endif
                default:
                    break
                }
                for event in try timeline.consume(borrowed) {
                    try await consume(event)
                }
            }
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("g_run_err_\(diagnosticStage)_\(type(of: error)).\(error)")
            #endif
            fail(error)
        }
    }

    private func consume(_ event: HLSTimelineEvent) async throws {
        switch event {
        case .originEstablished:
            setDiagnosticStage("timeline.origin")
            break
        case .audioFormat(let configuration):
            setDiagnosticStage("audio.configure")
            try await configureAudio(configuration)
        case .audioSample(let timed):
            setDiagnosticStage("audio.append")
            let isAheadOfVideo = maxVideoPTS.map {
                CMTimeCompare(timed.timing.presentationTimeStamp.cmTime, $0) > 0
            } ?? true
            if audioBranch == nil || interlacedVideoBranch != nil || !pendingAudio.isEmpty || isAheadOfVideo {
                guard pendingAudio.count < 2048 else {
                    PlaybackDiagnosticTracker.shared.set("cap_pending_audio_\(pendingAudio.count)")
                    throw HLSPublicationFailure.capacityExceeded
                }
                pendingAudio.append(timed)
                if interlacedVideoBranch != nil {
                    try await flushInterlacedAudioIfSafe(trigger: .audioSampleQueued)
                    try await drainPendingInterlacedVideoIfPossible()
                }
            } else {
                try await appendAudio(timed)
            }
        case .videoSample(let timed):
            setDiagnosticStage("video.append")
            if let drainThrough = HLSMediaGraphAudioDrainPolicy.drainBeforeVideo(
                pendingAudioCount: pendingAudio.count,
                hasAudioBranch: audioBranch != nil,
                hasInterlacedVideoBranch: interlacedVideoBranch != nil,
                previousVideoPTS: maxVideoPTS
            ) {
                setDiagnosticStage("audio.flushBeforeVideo")
                try await flushPendingAudio(through: drainThrough)
                setDiagnosticStage("video.append")
            }
            let currentPTS = timed.timing.presentationTimeStamp.cmTime
            if let previous = maxVideoPTS {
                if CMTimeCompare(currentPTS, previous) > 0 {
                    maxVideoPTS = currentPTS
                }
            } else {
                maxVideoPTS = currentPTS
            }
            try await appendVideo(timed)
            if audioBranch == nil {
                setDiagnosticStage("audio.installWriter")
                try installAudioWriterIfReady()
            }
            // TS 交错顺序允许首批视频早于 audio format。writer 尚未具备完整格式证明时，
            // 保留已经 admission 的音频，不能清空后调用一个尚不存在的 branch。
            if audioBranch != nil, interlacedVideoOutput != nil {
                try await flushInterlacedAudioIfSafe(trigger: .videoSampleSubmitted)
            } else if audioBranch != nil {
                if !pendingAudio.isEmpty, let effectiveVideoPTS = maxVideoPTS {
                    setDiagnosticStage("audio.flushPending")
                    PlaybackDiagnosticTracker.shared.set("fpa_cnt\(pendingAudio.count)_v\(effectiveVideoPTS.value / Int64(effectiveVideoPTS.timescale))")
                    try await flushPendingAudio(through: effectiveVideoPTS)
                }
            }
        case .generationEnded:
            break
        case .terminal(.endOfStream):
            setDiagnosticStage("naturalEOF.begin")
            try await finishNaturalEOFIsolated()
        case .terminal(.cancelled):
            throw PlaybackCoreError.videoSampleBuffer("task22.timeline.cancelled")
        case .terminal(.noEligibleOrigin):
            throw PlaybackCoreError.videoSampleBuffer("task22.timeline.noEligibleOrigin")
        case .terminal(.failed(let error)):
            throw error
        }
    }

    private func flushInterlacedAudioIfSafe(
        trigger: HLSMediaGraphAudioDrainPolicy.InterlacedTrigger
    ) async throws {
        guard audioBranch != nil, let interlacedVideoOutput else { return }
        setDiagnosticStage("audio.flushBehindVideo")
        let safeAudioEnd = HLSMediaGraphAudioDrainPolicy.drainBehindInterlacedVideo(
            pendingAudioCount: pendingAudio.count,
            writtenThrough: interlacedVideoOutput.writtenThrough,
            trigger: trigger)
        guard let safeAudioEnd,
              CMTimeCompare(safeAudioEnd, interlacedProbeStart ?? .zero) > 0,
              await interlacedVideoOutput.beginAudioFlush() else { return }
        do {
            try await flushPendingAudio(
                through: safeAudioEnd,
                maximumCount: HLSMediaGraphAudioDrainPolicy.interlacedMaximumCount)
            interlacedVideoOutput.endAudioFlush()
        } catch {
            interlacedVideoOutput.endAudioFlush()
            throw error
        }
    }

    private func configureAudio(_ configuration: CompressedAudioRenderConfiguration) async throws {
        if let existing = audioConfiguration {
            guard existing.fingerprint == configuration.fingerprint else {
                throw HLSPublicationFailure.identityMismatch
            }
            return
        }
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "system-hls-task22-v1")
        let receipt = try await AACPrimingCalibrator().calibrate(
            plan: AACCalibrationPlan.build([request]))
        guard receipt.encoders.count == 1 else { throw AACRenditionFailure.calibrationMismatch }
        audioConfiguration = configuration
        audioCalibration = receipt
    }

    private func appendVideo(_ timed: HLSTimedVideoAccessUnit) async throws {
        guard let track = tracks?.video else {
            throw PlaybackCoreError.videoSampleBuffer("task22.videoTrack")
        }
        guard let backing = timed.source.sourceBacking else {
            throw PlaybackCoreError.videoSampleBuffer("task22.sourceBacking")
        }
        guard let byteRange = timed.source.sourceByteRange else {
            throw PlaybackCoreError.videoSampleBuffer("task22.sourceByteRange")
        }
        guard let sourceSHA256 = timed.source.sourceSHA256 else {
            throw PlaybackCoreError.videoSampleBuffer("task22.sourceSHA256")
        }
        guard let duration = timed.timing.duration else {
            throw PlaybackCoreError.videoSampleBuffer("task22.duration")
        }
        if videoInspection == nil {
            videoInspection = VideoAccessUnitInspectionSession(
                generation: timed.source.generation, codec: track.codec)
            videoEligibility = try VideoRemuxEligibility(
                generation: timed.source.generation, track: track,
                sampleEntry: track.codec == .h264 ? .avc3 : .hev1)
        }
        let sourcePTS = try ExactMediaTime(
            CMSampleBufferGetPresentationTimeStamp(timed.source.sampleBuffer))
        var sourceTiming = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            timed.source.sampleBuffer,
            entryCount: 1,
            arrayToFill: &sourceTiming,
            entriesNeededOut: nil)
        let resolvedDTS: ExactMediaTime?
        if timingStatus == noErr, sourceTiming.decodeTimeStamp.isValid, sourceTiming.decodeTimeStamp.isNumeric {
            resolvedDTS = try ExactMediaTime(sourceTiming.decodeTimeStamp)
        } else if let normalizedDTS = timed.timing.decodeTimeStamp {
            resolvedDTS = normalizedDTS
        } else {
            resolvedDTS = nil
        }
        let proof = try videoInspection!.inspect(.init(
            backing: backing, byteRange: byteRange, sourceSHA256: sourceSHA256,
            codec: track.codec, scanClassification: timed.source.scanClassification,
            presentationTimeStamp: sourcePTS,
            decodeTimeStamp: resolvedDTS,
            duration: try ExactMediaTime(CMSampleBufferGetDuration(timed.source.sampleBuffer)),
            expectedFormat: track))
        #if DEBUG
        if proof.randomAccessKind == .h264IDR || proof.randomAccessKind == .hevcIDR {
            if let previous = previousRandomAccessDiagnostic,
               let elapsed = try? sourcePTS.subtracting(previous.pts),
               elapsed.value <= 0 {
                let samePayload = previous.digest == sourceSHA256
                let sameDTS = previous.dts == resolvedDTS
                PlaybackDiagnosticTracker.shared.append(
                    "cap_idr_noninc_same_payload_\(samePayload)" +
                    "_same_dts_\(sameDTS)" +
                    "_au_\(previous.accessUnitID)_\(proof.identity.accessUnitID)"
                )
            }
            previousRandomAccessDiagnostic = (
                sourcePTS,
                resolvedDTS,
                sourceSHA256,
                proof.identity.accessUnitID
            )
        }
        #endif
        let decision = try videoEligibility!.evaluate(proof)
        guard let admission = decision.proof else {
            guard decision.transcodeReason == .interlaced, !decision.requiresNewItem else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            try await appendInterlacedVideo(timed, track: track, inspection: proof)
            return
        }
        if !videoFrameRateConfigured {
            try publication.configureVideo(frameRate: track.frameRate)
            videoFrameRateConfigured = true
        }
        if boundary == nil {
            boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
                epochStart: timed.timing.presentationTimeStamp.cmTime,
                videoMode: .passthrough,
                minimumPassthroughInterval: CMTime(value: 90, timescale: 100),
                maximumPassthroughInterval: CMTime(value: 6, timescale: 1)))
            mediaEpoch = .init(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .mediaEpoch))
        }
        if videoWriter == nil {
            guard let boundary, let mediaEpoch else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            let binding = try makeBinding(mediaEpoch: mediaEpoch)
            let builder = try HLSVideoRemuxSubmissionBuilder(
                reference: timed, admission: admission, writerBinding: binding)
            let writer = try publication.makeRelay(
                binding: binding, mediaType: .video, limits: .video) { relay in
                try SegmentedFMP4Writer(
                    binding: binding, trackKind: .video,
                    sourceFormatHint: builder.formatDescription,
                    boundarySession: boundary.session,
                    compressedFormatConfiguration: nil, relay: relay,
                    systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
            }
            try writer.start(at: timed.timing.presentationTimeStamp.cmTime)
            videoBinding = binding
            videoBuilder = builder
            videoWriter = writer
        }
        guard duration.value > 0, let builder = videoBuilder,
              let writer = videoWriter, let boundary, let binding = videoBinding else {
            throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
        }
        let submission = try builder.makeSubmission(for: timed, admission: admission)
        do {
            try writer.appendRemuxVideo(
                submission,
                ticket: try boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: binding))
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            let continuation = try await writer.finishWriterWindow()
            let nextBinding = FMP4WriterBinding(
                outputLifecycleEpoch: binding.outputLifecycleEpoch,
                itemGeneration: binding.itemGeneration,
                mediaEpoch: binding.mediaEpoch,
                publicationParticipantID: binding.publicationParticipantID,
                renditionIdentity: binding.renditionIdentity,
                writerIdentity: .init(rawValue:
                    try PlaybackIdentityAllocator.shared.next(in: .nonce)))
            let nextWriter = try publication.makeRelay(
                binding: nextBinding, mediaType: .video, limits: .video,
                initial: false) { relay in
                try SegmentedFMP4Writer(
                    binding: nextBinding, trackKind: .video,
                    sourceFormatHint: builder.formatDescription,
                    boundarySession: boundary.session,
                    compressedFormatConfiguration: nil, relay: relay,
                    systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
                    writerWindowContinuation: continuation)
            }
            let admission = try requireVideoWindowAdmission(nextWriter)
            let nextBuilder = try HLSVideoRemuxSubmissionBuilder(
                resuming: builder, binding: nextBinding, admission: admission)
            let attempt = try submission.claimWriterAttempt(
                binding: nextBinding, admission: admission)
            try nextWriter.start(at: .zero)
            try nextWriter.appendRemuxVideo(
                attempt, ticket: try boundary.issueRemuxVideoAppend(for: attempt))
            videoBinding = nextBinding
            videoBuilder = nextBuilder
            videoWriter = nextWriter
        }
    }

    private func appendInterlacedVideo(
        _ timed: HLSTimedVideoAccessUnit, track: VideoTrackDescriptor,
        inspection: VideoAccessUnitInspectionProof
    ) async throws {
        guard let sourceFrameRate = track.frameRate,
              let outputFrameRate = HLSInterlacedYADIFPolicy.outputFrameRate(
                for: sourceFrameRate
              ) else {
            throw HLSPublicationFailure.invalidPlaylist
        }
        if !videoFrameRateConfigured {
            try publication.configureVideo(frameRate: outputFrameRate)
            videoFrameRateConfigured = true
        }
        if interlacedVideoBranch == nil {
            guard let byteRange = timed.source.sourceByteRange,
                  let duration = timed.timing.duration else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            let byteCount = interlacedProbeBytes.addingReportingOverflow(
                UInt64(byteRange.length))
            guard !byteCount.overflow else { throw VTVideoEncoderFailure.arithmeticOverflow }
            interlacedProbeBytes = byteCount.partialValue
            let start = interlacedProbeStart ?? timed.timing.presentationTimeStamp.cmTime
            interlacedProbeStart = start
            interlacedProbeEnd = CMTimeAdd(
                timed.timing.presentationTimeStamp.cmTime, duration.cmTime)
            guard HLSInterlacedDeferredInputPolicy.canEnqueue(
                currentCount: pendingInterlacedVideo.count
            ) else {
                throw deferredInterlacedVideoCapacityFailure(phase: "probe")
            }
            pendingInterlacedVideo.append((timed, inspection))
            guard CMTimeCompare(
                CMTimeSubtract(interlacedProbeEnd, start), CMTime(seconds: 2, preferredTimescale: 1_000_000)
            ) >= 0 else { return }

            guard boundary == nil, videoWriter == nil else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
                // 两秒 probe 结束后会按原顺序回放整个 pending 窗口；边界原点必须
                // 对应窗口首帧，而不是触发 probe 完成的末帧。
                epochStart: start,
                videoMode: .passthrough,
                minimumPassthroughInterval: CMTime(value: 90, timescale: 100)))
            let mediaEpoch = AudioMediaEpochIdentity(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .mediaEpoch))
            let binding = try makeBinding(mediaEpoch: mediaEpoch)
            let input = try videoInputSignature(inspection.format)
            let bitrate = try VTVideoBitratePolicy.freeze(
                firstTwoSecondsByteCount: interlacedProbeBytes,
                width: input.width, height: input.height,
                bitDepth: input.bitDepth, dynamicRange: input.dynamicRange)
            let encoder = try VTVideoEncoder(configuration: .init(
                generation: timed.source.generation, inputFormat: input,
                frameRate: outputFrameRate,
                bitrate: bitrate, maximumPendingFrameCount: 8))
            let inputWakeup = HLSVideoInputCapacityWakeup()
            let output = InterlacedVideoOutput(
                publication: publication, binding: binding, boundary: boundary,
                expectedVideoStart: start, outputSemaphore: interlacedOutputSemaphore,
                inputCapacityWakeup: inputWakeup,
                authority: self)
            let transcode = HLSVideoTranscodeBranch(
                generation: timed.source.generation, inputFormat: input,
                maximumPendingFrameCount: 8,
                // 直播源在 decoder 恢复期可能丢弃直到下一个 IDR；当前
                // 50fps 场时间轴已实测到 4.52s 空洞。上限覆盖 10s，
                // 同时保持有界，且所有合成帧只共享上一张 surface。
                gapPolicy: .fillForwardGaps(maximumSyntheticFrameCount: 500),
                cadencePolicy: HLSInterlacedYADIFPolicy.cadence,
                encoder: encoder,
                outputSink: { output.append($0) })
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else {
                throw PlaybackCoreError.metalCommand("task22.hls-yadif.device")
            }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
                  let cache else {
                throw PlaybackCoreError.metalCommand("task22.hls-yadif.texture-cache")
            }
            let executor = PlaybackSerialExecutor(label: "org.vplayer.hls.interlaced")
            let allocator = HLSYADIFOutputAllocator()
            let submitter = try YADIFSystemCommandSubmitter(
                device: device, commandQueue: queue, textureCache: cache)
            let outputAllocator: YADIFOutputAllocator = {
                try allocator.allocate(matching: $0)
            }
            let yadif = try YADIFProcessor(
                commandSubmitter: submitter, surfacePool: ProgressiveSurfacePool(),
                outputAllocator: outputAllocator,
                clock: interlacedGenerationClock,
                maximumInFlight: HLSInterlacedYADIFPolicy.maximumInFlight,
                maximumPendingFrames: 8)
            let branch = HLSVideoBranch(
                executor: executor,
                decoderFactory: HLSVideoBranch.makeRoutingDecoderFactory(
                    executor: executor, tuning: .default),
                passthrough: PassthroughVideoProcessor(),
                yadif: yadif,
                probe: nil, initialGeneration: timed.source.generation,
                transcodeBranch: transcode,
                failureSink: { [weak self] error, _ in self?.fail(error) })
            branch.installInputCapacityWakeup(inputWakeup)
            self.boundary = boundary
            self.mediaEpoch = mediaEpoch
            videoBinding = binding
            interlacedVideoOutput = output
            interlacedVideoBranch = branch
            interlacedInputWakeup = inputWakeup
            guard let format = CMSampleBufferGetFormatDescription(timed.source.sampleBuffer) else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            branch.replaceFormat(format, streamFieldOrder: track.fieldOrder)
            branch.observeAudioTimelineOrigin(timed.timing.presentationTimeStamp.cmTime)

            let pending = pendingInterlacedVideo
            pendingInterlacedVideo.removeAll(keepingCapacity: false)
            for (sample, _) in pending { try await submitInterlacedVideo(sample, to: branch) }
            return
        }
        guard let interlacedVideoBranch else {
            throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
        }
        try await makeRoomForInterlacedVideo(in: interlacedVideoBranch)
        pendingInterlacedVideo.append((timed, inspection))
        try await drainPendingInterlacedVideoIfPossible()
    }

    /// 只在压缩 AU FIFO 达到常规上限时等待真实 decoder 容量。
    /// 这里不等待 encoder/writer 输出水位；branch 自身的 admission 已是
    /// 有界的，而等输出会占住唯一 media worker，使音频无法推进分段边界。
    private func makeRoomForInterlacedVideo(
        in branch: HLSVideoBranch
    ) async throws {
        guard let output = interlacedVideoOutput,
              let wakeup = interlacedInputWakeup else {
            throw PlaybackCoreError.videoSampleBuffer(
                "task22.interlaced.capacityOwnerMissing submitted=\(interlacedSubmittedCount)")
        }
        while true {
            let action = HLSInterlacedDeferredInputPolicy.action(
                currentCount: pendingInterlacedVideo.count,
                requiresAudioBoundaryProgress: output.requiresAudioBoundaryProgress)
            switch action {
            case .enqueue:
                return
            case .enqueueToReachAudioBoundary:
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(
                    "g_deferred_video_audio_escape_\(pendingInterlacedVideo.count)"
                )
                #endif
                return
            case .rejectAudioBoundaryStall:
                throw deferredInterlacedVideoCapacityFailure(
                    phase: "running.audioBoundaryEscape")
            case .waitForCapacity:
                guard let oldest = pendingInterlacedVideo.first else {
                    throw deferredInterlacedVideoCapacityFailure(
                        phase: "running.invalidCount")
                }
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append(
                    "g_deferred_video_backpressure_\(pendingInterlacedVideo.count)"
                )
                #endif
                let effectiveAccessUnit = try accessUnit(
                    oldest.0.source, timing: oldest.0.timing)
                if try await attemptInterlacedVideo(
                    effectiveAccessUnit,
                    in: branch,
                    waitsForOutputWatermark: false
                ) {
                    pendingInterlacedVideo.removeFirst()
                    continue
                }
                let signalled = await Task.detached(priority: .userInitiated) {
                    wakeup.wait(timeout: 30)
                }.value
                if !signalled, !output.requiresAudioBoundaryProgress {
                    throw PlaybackCoreError.videoSampleBuffer(
                        "task22.interlaced.capacityTimeout submitted=\(interlacedSubmittedCount) " +
                        "output=\(output.outputCount) " +
                        "stage=\(output.stageForDiagnostics) " +
                        "input=\(branch.capacityStateForDiagnostics)")
                }
                // 无论是 branch 释放容量，还是 writer 进入等音频边界，
                // 都必须重新读取所有者的实时状态，唤醒本身不携带容量。
            }
        }
    }

    private func deferredInterlacedVideoCapacityFailure(
        phase: String
    ) -> PlaybackCoreError {
        let branchState = interlacedVideoBranch?.capacityStateForDiagnostics ?? "missing"
        let writerStage = interlacedVideoOutput?.stageForDiagnostics ?? "missing"
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set(
            "cap_deferred_video_\(pendingInterlacedVideo.count)_\(writerStage)")
        #endif
        return PlaybackCoreError.videoSampleBuffer(
            "task22.interlaced.deferredCapacity phase=\(phase) " +
            "count=\(pendingInterlacedVideo.count) writer=\(writerStage) " +
            "input=\(branchState)")
    }

    private func submitInterlacedVideo(
        _ timed: HLSTimedVideoAccessUnit, to branch: HLSVideoBranch
    ) async throws {
        // timeline 已把首个可播放 AU 平移到有效媒体原点；decoder/YADIF/VT 必须
        // 接收同一个显式 PTS，不能让 writer 在末端再补偿而破坏双场时序。
        let effectiveAccessUnit = try accessUnit(
            timed.source, timing: timed.timing)
        guard let wakeup = interlacedInputWakeup else {
            throw PlaybackCoreError.videoSampleBuffer(
                "task22.interlaced.inputWakeupMissing submitted=\(interlacedSubmittedCount)")
        }
        for _ in 0..<512 {
            if try await attemptInterlacedVideo(
                effectiveAccessUnit,
                in: branch,
                waitsForOutputWatermark: true
            ) {
                return
            }
            let signalled = await Task.detached(priority: .userInitiated) {
                // 真机 AVAssetWriter 在 window rollover 时会暂时阻塞下游释放；
                // 与输出等待使用同一有界预算，不能用普通 append 的 5 秒误杀。
                wakeup.wait(timeout: 30)
            }.value
            guard signalled else {
                            throw PlaybackCoreError.videoSampleBuffer(
                                "task22.interlaced.capacityTimeout submitted=\(interlacedSubmittedCount) " +
                                "output=\(interlacedVideoOutput?.outputCount ?? -1) " +
                                "stage=\(interlacedVideoOutput?.stageForDiagnostics ?? "missing") " +
                                "input=\(branch.capacityStateForDiagnostics)")
            }
        }
        throw PlaybackCoreError.videoSampleBuffer(
            "task22.interlaced.capacityRetryExhausted submitted=\(interlacedSubmittedCount)")
    }

    private func drainPendingInterlacedVideoIfPossible() async throws {
        guard let branch = interlacedVideoBranch else { return }
        while let pending = pendingInterlacedVideo.first {
            let effectiveAccessUnit = try accessUnit(
                pending.0.source, timing: pending.0.timing)
            guard try await attemptInterlacedVideo(
                effectiveAccessUnit,
                in: branch,
                waitsForOutputWatermark: false
            ) else { return }
            pendingInterlacedVideo.removeFirst()
        }
    }

    /// 返回 true 表示当前 AU 已由 decoder 接管或被 decoder 明确消费为丢帧；
    /// false 仅表示容量暂不可用，调用方必须保留同一 AU 的所有权。
    private func attemptInterlacedVideo(
        _ effectiveAccessUnit: CompressedVideoAccessUnit,
        in branch: HLSVideoBranch,
        waitsForOutputWatermark: Bool
    ) async throws -> Bool {
        switch branch.inputCapacityState {
        case .cancelled:
            throw PlaybackCoreError.videoSampleBuffer(
                "task22.interlaced.inputCancelled submitted=\(interlacedSubmittedCount)")
        case .temporarilyUnavailable:
            return false
        case .available:
            break
        }
        let disposition = await withCheckedContinuation { continuation in
            branch.submitClassified(effectiveAccessUnit) {
                continuation.resume(returning: $0)
            }
        }
        switch disposition {
        case .accepted:
            interlacedSubmittedCount += 1
            guard waitsForOutputWatermark,
                  let targetOutputCount = HLSInterlacedOutputWatermark.targetOutputCount(
                    decodedFrameCount: branch.decodedFrameCountForOutputWatermark,
                    outputFramesPerDecodedFrame:
                        HLSInterlacedYADIFPolicy.cadence.outputFramesPerDecodedFrame
                  ) else { return true }
            let published = await Task.detached(priority: .userInitiated) {
                self.waitForInterlacedOutputs(target: targetOutputCount)
            }.value
            guard published else {
                throw PlaybackCoreError.videoSampleBuffer(
                    "task22.interlaced.outputTimeout submitted=\(interlacedSubmittedCount) " +
                    "output=\(interlacedVideoOutput?.outputCount ?? -1) " +
                    "target=\(targetOutputCount) " +
                    "stage=\(interlacedVideoOutput?.stageForDiagnostics ?? "missing")")
            }
            return true
        case .discardedByDecoder:
            #if DEBUG
            if effectiveAccessUnit.isRandomAccess {
                PlaybackDiagnosticTracker.shared.append(
                    "g_video_discard_idr_au\(effectiveAccessUnit.id)")
            }
            #endif
            return true
        case .retry:
            return false
        case .cancelled:
            throw PlaybackCoreError.videoSampleBuffer(
                "task22.interlaced.inputCancelled submitted=\(interlacedSubmittedCount)")
        case .invalidInput, .identityMissing, .bookkeepingConflict:
            throw PlaybackCoreError.videoSampleBuffer(
                "task22.interlaced.inputRejected submitted=\(interlacedSubmittedCount) " +
                "reason=\(disposition)")
        }
    }

    private func waitForInterlacedOutputs(target: Int) -> Bool {
        while (interlacedVideoOutput?.outputCount ?? 0) < target {
            // 真机上的 AVAssetWriter window 收尾包含系统 terminal 与发布 drain；
            // 多窗口离线转码时可能明显超过一次普通 append 的时长。
            guard interlacedOutputSemaphore.wait(timeout: .now() + 30) == .success else {
                return false
            }
        }
        return true
    }

    private func accessUnit(
        _ source: CompressedVideoAccessUnit, timing: NormalizedSampleTiming
    ) throws -> CompressedVideoAccessUnit {
        guard let backing = source.sourceBacking, let byteRange = source.sourceByteRange else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        guard let duration = timing.duration else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        var timingInfo = CMSampleTimingInfo(
            duration: duration.cmTime,
            presentationTimeStamp: timing.presentationTimeStamp.cmTime,
            decodeTimeStamp: timing.decodeTimeStamp?.cmTime ?? .invalid)
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: source.sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleBufferOut: &copied)
        guard status == noErr, let copied else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        let normalized90k = CMTimeConvertScale(
            timing.presentationTimeStamp.cmTime,
            timescale: 90_000,
            method: .roundHalfAwayFromZero)
        guard normalized90k.isNumeric, normalized90k.epoch == 0,
              normalized90k.value >= 0,
              let normalizedPTS90k = UInt64(exactly: normalized90k.value) else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        let metadata = VideoParserMetadata(
            fieldOrder: source.parserMetadata.fieldOrder,
            pictureStructure: source.parserMetadata.pictureStructure,
            isInterlaced: source.parserMetadata.isInterlaced,
            repeatFirstField: source.parserMetadata.repeatFirstField,
            topFieldFirst: source.parserMetadata.topFieldFirst,
            // decoder 后的 normalizer 信任该 transport PTS；HLS 图必须把它与已经
            // 平移到 10 秒的 sample timing 一并重绑，否则 YADIF/VT 会恢复源 TS PTS。
            sourcePTS90k: normalizedPTS90k)
        return try CompressedVideoAccessUnit(
            id: source.id, sampleBuffer: copied, generation: source.generation,
            isRandomAccess: source.isRandomAccess,
            randomAccessKind: source.randomAccessKind,
            scanClassification: source.scanClassification,
            parserMetadata: metadata,
            sourceBacking: backing, sourceByteRange: byteRange)
    }

    private func videoInputSignature(
        _ format: VideoAccessUnitFormatSummary
    ) throws -> VideoEncodingInputFormatSignature {
        guard format.bitDepthLuma == format.bitDepthChroma,
              format.bitDepthLuma == 8 || format.bitDepthLuma == 10,
              format.chromaFormatIDC == 1 else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        let range: VideoFormatMetadata.Range = format.range == .full ? .full : .video
        let primaries: VideoFormatMetadata.Primaries = format.primaries == .bt2020 ? .bt2020 : .bt709
        let transfer: VideoFormatMetadata.Transfer
        switch format.transfer { case .pq?: transfer = .pq; case .hlg?: transfer = .hlg; default: transfer = .bt709 }
        let matrix: VideoFormatMetadata.Matrix = format.matrix == .bt2020Nonconstant ? .bt2020 : .bt709
        let pixelFormat: OSType = switch (format.bitDepthLuma, range) {
        case (10, .full): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (10, _): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (_, .full): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        default: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let chroma: String? = switch format.chromaLocation {
        case .left?: kCVImageBufferChromaLocation_Left as String
        case .center?: kCVImageBufferChromaLocation_Center as String
        case .topLeft?: kCVImageBufferChromaLocation_TopLeft as String
        case nil: nil
        }
        return VideoEncodingInputFormatSignature(
            pixelFormat: pixelFormat, width: format.width, height: format.height,
            bitDepth: format.bitDepthLuma, range: range,
            primaries: primaries, transfer: transfer, matrix: matrix,
            cleanAperture: nil, sampleAspectRatio: format.sampleAspectRatio,
            chromaLocation: .init(topField: chroma, bottomField: chroma),
            masteringDisplayColorVolume: try masteringDisplayBytes(format.masteringDisplay),
            contentLightLevelInfo: contentLightLevelBytes(format.contentLightLevel))
    }

    private func masteringDisplayBytes(_ value: DemuxMasteringDisplayMetadata?) throws -> Data? {
        guard let value else { return nil }
        func scaled(_ rational: DemuxHDRRational, by scale: Int64) throws -> UInt64 {
            let product = Int64(rational.num).multipliedReportingOverflow(by: scale)
            guard !product.overflow,
                  product.partialValue % Int64(rational.den) == 0 else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            return UInt64(product.partialValue / Int64(rational.den))
        }
        var bytes = Data()
        for component in [
            value.greenX, value.greenY, value.blueX, value.blueY,
            value.redX, value.redY, value.whitePointX, value.whitePointY,
        ] {
            guard let encoded = UInt16(exactly: try scaled(component, by: 50_000)) else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            appendBigEndian(encoded, to: &bytes)
        }
        for component in [value.maximumLuminance, value.minimumLuminance] {
            guard let encoded = UInt32(exactly: try scaled(component, by: 10_000)) else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            appendBigEndian(encoded, to: &bytes)
        }
        return bytes
    }

    private func contentLightLevelBytes(_ value: DemuxContentLightLevelMetadata?) -> Data? {
        guard let value else { return nil }
        var bytes = Data()
        appendBigEndian(value.maximumContentLightLevel, to: &bytes)
        appendBigEndian(value.maximumFrameAverageLightLevel, to: &bytes)
        return bytes
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func requireVideoWindowAdmission(
        _ writer: SegmentedFMP4Writer
    ) throws -> WriterWindowAdmission {
        guard let admission = writer.writerWindowAdmission else {
            throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
        }
        return admission
    }

    private func installAudioWriterIfReady() throws {
        guard audioBranch == nil, let configuration = audioConfiguration,
              let encoder = audioCalibration?.encoders.first,
              let track = tracks?.audio, let boundary, let mediaEpoch else { return }
        let inputLayout = try RenditionAudioLayout(native: track.channelLayout)
        let converter = try AudioRenditionConverter(
            inputLabels: inputLayout.canonical.labels,
            inputRate: Int(track.sampleRate), output: .stereo)
        let ownership = HLSAudioCopyOwnership(
            maximumCompressedBytes: 1 * 1_024 * 1_024,
            maximumPCMBytes: 8 * 1_024 * 1_024, capacity: 8)
        let bridge = try SystemHLSAudioPCMBridge(
            configuration: configuration, copyOwnership: ownership)
        let binding = try makeBinding(mediaEpoch: mediaEpoch)
        let effectiveStart = CMTime(value: 10, timescale: 1)
        try boundary.registerAudioRendition(
            binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: effectiveStart)
        let format = try encoder.incrementalFormatDescription()
        let writer = try makeAACWriter(
            binding: binding, format: format, boundary: boundary,
            continuation: nil, initial: true)
        try writer.start(at: effectiveStart)
        let initialBinding = binding
        let graph = publication
        let boundaryHolder = BoundaryHolder(boundary)
        let branch = AudioRenditionBranch(
            encoder: encoder, writer: writer, coordinator: boundary,
            writerWindowFactory: { [weak graph, boundaryHolder, format] continuation in
                guard let graph else { throw AACRenditionFailure.cancelled }
                let next = FMP4WriterBinding(
                    outputLifecycleEpoch: initialBinding.outputLifecycleEpoch,
                    itemGeneration: initialBinding.itemGeneration,
                    mediaEpoch: initialBinding.mediaEpoch,
                    publicationParticipantID: initialBinding.publicationParticipantID,
                    renditionIdentity: initialBinding.renditionIdentity,
                    writerIdentity: .init(rawValue:
                        try PlaybackIdentityAllocator.shared.next(in: .nonce)))
                return try Self.makeAACWriter(
                    publication: graph, binding: next, format: format,
                    boundary: boundaryHolder.value,
                    continuation: continuation, initial: false)
            })
        audioConverter = converter
        audioBridge = bridge
        audioBranch = branch
    }

    private func makeAACWriter(binding: FMP4WriterBinding, format: CMFormatDescription,
                               boundary: SegmentBoundaryCoordinator,
                               continuation: AACWriterWindowContinuation?, initial: Bool)
        throws -> SegmentedFMP4Writer {
        try Self.makeAACWriter(
            publication: publication, binding: binding, format: format,
            boundary: boundary, continuation: continuation, initial: initial)
    }

    private static func makeAACWriter(
        publication: SystemHLSPublicationGraph, binding: FMP4WriterBinding,
        format: CMFormatDescription, boundary: SegmentBoundaryCoordinator,
        continuation: AACWriterWindowContinuation?, initial: Bool
    ) throws -> SegmentedFMP4Writer {
        try publication.makeRelay(
            binding: binding, mediaType: .audio, limits: .audio, initial: initial) { relay in
            try SegmentedFMP4Writer(
                binding: binding, trackKind: .aac, sourceFormatHint: format,
                boundarySession: boundary.session,
                compressedFormatConfiguration: nil, relay: relay,
                systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
                aacContinuation: continuation)
        }
    }

    private func appendAudio(_ timed: HLSTimedAudioAccessUnit) async throws {
        guard let bridge = audioBridge, let converter = audioConverter,
              let branch = audioBranch, let track = tracks?.audio else {
            throw AACRenditionFailure.invalidInput
        }
        for decoded in try bridge.push(timed) {
            let frames = decoded.count / Int(track.channelLayout.channelCount)
            let converted = try converter.convert(decoded, sourceSampleIndex: sourcePCMIndex)
            sourcePCMIndex = try checkedAdd(sourcePCMIndex, Int64(frames))
            if !converted.samples.isEmpty { try await pump(converted, into: branch) }
        }
    }

    private func flushPendingAudio(
        through videoPTS: CMTime?, maximumCount: Int? = nil
    ) async throws {
        guard audioBranch != nil else { return }
        var consumedCount = 0
        while let first = pendingAudio.first {
            if let maximumCount, consumedCount >= maximumCount { return }
            if let videoPTS,
               CMTimeCompare(first.timing.presentationTimeStamp.cmTime, videoPTS) > 0 {
                return
            }
            try await appendAudio(first)
            pendingAudio.removeFirst()
            consumedCount += 1
        }
    }

    private func pump(
        _ block: AudioRenditionPCMBlock,
        into branch: AudioRenditionBranch
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            do {
                let result = try await settleAudioPump(
                    try branch.pump(.pcm(block.samples)), branch: branch)
                guard !result.waitingForWriter, !result.waitingForEncoderBudget else {
                    throw AACRenditionFailure.capacityExceeded
                }
                return
            } catch AACRenditionFailure.budgetUnavailable {
                guard ContinuousClock.now < deadline else {
                    throw AACRenditionFailure.capacityExceeded
                }
                do {
                    try await Task.sleep(for: .milliseconds(2))
                } catch {
                    throw AACRenditionFailure.cancelled
                }
            }
        }
    }

    /// 一个 pump 的 workspace reservation 是有界窗口。窗口耗尽不代表输入无效；先让
    /// branch 释放已提交 batch，再以 `.unavailable` 继续同一 encoder epoch。writer rollover
    /// 也在这里收敛，调用方只有在两种 backpressure 都解除后才能提交下一块 PCM。
    private func settleAudioPump(
        _ initial: AACStreamPumpResult,
        branch: AudioRenditionBranch
    ) async throws -> AACStreamPumpResult {
        var result = initial
        for _ in 0..<64 {
            if result.waitingForWriter {
                guard let retried = try await branch.retryPendingAcrossWriterWindow() else {
                    throw AACRenditionFailure.busy
                }
                result = retried
                continue
            }
            if result.waitingForEncoderBudget {
                result = try branch.pump(.unavailable)
                continue
            }
            return result
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("cap_settle_loop64")
        #endif
        throw AACRenditionFailure.capacityExceeded
    }

    private func finishNaturalEOFIsolated() async throws {
        condition.withLock { state = .finishing }
        if let interlacedVideoBranch, !pendingInterlacedVideo.isEmpty {
            setDiagnosticStage("naturalEOF.deferredVideo")
            while let pending = pendingInterlacedVideo.first {
                try await submitInterlacedVideo(pending.0, to: interlacedVideoBranch)
                pendingInterlacedVideo.removeFirst()
            }
        }
        publication.beginNaturalEnd()
        let finishedInterlacedVideo: Bool
        if let interlacedVideoBranch {
            setDiagnosticStage("naturalEOF.video")
            let finished = await withCheckedContinuation { continuation in
                interlacedVideoBranch.finishNaturally { result in
                    continuation.resume(returning: result)
                }
            }
            _ = try finished.get()
            guard let interlacedVideoOutput else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            try await interlacedVideoOutput.finish()
            try await flushPendingAudio(through: nil)
            finishedInterlacedVideo = true
        } else {
            finishedInterlacedVideo = false
            try await flushPendingAudio(through: nil)
        }
        setDiagnosticStage("naturalEOF.audioDrain")
        guard let bridge = audioBridge, let converter = audioConverter,
              let branch = audioBranch,
              let track = tracks?.audio else { throw AACRenditionFailure.invalidInput }
        for decoded in try bridge.drainForNaturalEOF() {
            let frames = decoded.count / Int(track.channelLayout.channelCount)
            let converted = try converter.convert(decoded, sourceSampleIndex: sourcePCMIndex)
            sourcePCMIndex = try checkedAdd(sourcePCMIndex, Int64(frames))
            if !converted.samples.isEmpty { try await pump(converted, into: branch) }
        }
        let tail = try converter.drain()
        if !tail.samples.isEmpty { try await pump(tail, into: branch) }
        setDiagnosticStage("naturalEOF.audioEncoder")
        let terminal = try await settleAudioPump(
            try branch.pump(.endOfStream), branch: branch)
        guard terminal.finalReceipt != nil else { throw AACRenditionFailure.invalidInput }
        setDiagnosticStage("naturalEOF.audioWriter")
        _ = try await branch.finishRendition()
        if !finishedInterlacedVideo {
            setDiagnosticStage("naturalEOF.video")
            guard let videoWriter else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            _ = try await videoWriter.finish()
        }
        try publication.finishNaturalEnd()
        setDiagnosticStage("naturalEOF.complete")
        condition.withLock { terminalResult = true; condition.broadcast() }
    }

    func awaitAllTrackPlayablePrefix(minimumSeconds: Int) async
        -> AVPlayerItemReplacementBundle? {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("g_awaitPrefix_start")
        #endif
        guard minimumSeconds == 3 else { return nil }
        do {
            let readiness = Task.detached(priority: .userInitiated) {
                try self.publication.waitForVisible(
                    until: Date().addingTimeInterval(self.publicationWaitInterval))
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("g_waitVisible_started")
            #endif
            guard let ready = try await readiness.value else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("g_waitVisible_nil")
                #endif
                return nil
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("g_waitVisible_ready")
            #endif
            let item = AVPlayerItemInstanceIdentity(
                outputLifecycleEpoch: lifecycle, itemGeneration: itemGeneration)
            let prepared = try await SystemHLSLoopbackPreparation.start(
                store: ready.0, declaration: ready.1, snapshot: ready.2,
                token: publication.token, item: item)
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("g_loopback_ready")
            #endif
            condition.withLock {
                loopbackServer = prepared.server
                state = .playable
            }
            return prepared.replacement
        } catch {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("g_awaitPrefix_fail")
            #endif
            fail(error)
            return nil
        }
    }

    func finishAllTracksAtNaturalEOF() async -> Bool {
        await Task.detached { self.waitForTerminalResult() }.value
    }

    private func waitForTerminalResult() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        // 可播前缀只覆盖开头三秒，剩余媒体仍在离线生成；真机硬件编码和
        // 多个 writer window 的自然收尾不能被一个短于剩余节目时长的上限截断。
        let deadline = Date().addingTimeInterval(publicationWaitInterval)
        while terminalResult == nil && condition.wait(until: deadline) {}
        return terminalResult == true
    }

    var publicationDeadlineNanosecondsForDiagnostics: Int64 {
        publicationDeadlineNanoseconds
    }

    var playablePrefixWaitIntervalForDiagnostics: TimeInterval {
        publicationWaitInterval
    }

    var terminalWaitIntervalForDiagnostics: TimeInterval {
        publicationWaitInterval
    }

    func retireAllResourcesAndAwaitReceipt() async -> Bool {
        let shouldRetire = condition.withLock { () -> Bool in
            if state == .retired { return false }
            guard state != .retiring else { return false }
            state = .retiring
            return true
        }
        if !shouldRetire { return condition.withLock { state == .retired } }
        streamContinuation.finish()
        worker.cancel()
        _ = await worker.value
        audioBranch?.cancel()
        audioBridge?.destroy()
        let interlacedRetired: Bool
        if let interlacedVideoBranch {
            interlacedRetired = await withCheckedContinuation { continuation in
                interlacedVideoBranch.retire(emergency: false) { continuation.resume(returning: $0) }
            }
        } else {
            interlacedRetired = true
        }
        interlacedVideoOutput?.cancel()
        _ = videoWriter?.cancel()
        publication.close()
        if let server = condition.withLock({ loopbackServer }) {
            let ticket = server.closeAdmission()
            do {
                try server.drain(cleanupTicket: ticket)
                try server.retire(cleanupTicket: ticket)
            } catch {
                condition.withLock { state = .failed }
                return false
            }
        }
        guard interlacedRetired else {
            condition.withLock { state = .failed }
            return false
        }
        condition.withLock { state = .retired }
        return true
    }

    private func makeBinding(mediaEpoch: AudioMediaEpochIdentity) throws -> FMP4WriterBinding {
        FMP4WriterBinding(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: .init(rawValue: itemGeneration), mediaEpoch: mediaEpoch,
            publicationParticipantID: .init(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .resource)),
            renditionIdentity: .init(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .resource)),
            writerIdentity: .init(rawValue:
                try PlaybackIdentityAllocator.shared.next(in: .nonce)))
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("cap_checked_add")
            #endif
            throw AACRenditionFailure.capacityExceeded
        }
        return result.partialValue
    }

    private func fail(_ error: Error) {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("fail_\(diagnosticStage)_\(type(of: error)).\(error)")
        #endif
        condition.withLock {
            state = .failed
            if failureDescription == nil {
                failureDescription = "\(diagnosticStage): \(String(reflecting: error))"
            }
            terminalResult = false
            condition.broadcast()
        }
        publication.recordFailure(error)
    }

    var failureDescriptionForDiagnostics: String? {
        condition.withLock { failureDescription }
    }

    private func setDiagnosticStage(_ value: String) {
        #if DEBUG
        if value != "video.append" && value != "audio.append" && value != "audio.flushBehindVideo" {
            PlaybackDiagnosticTracker.shared.set("g_\(value)")
        }
        #endif
        condition.withLock { diagnosticStage = value }
    }
}
