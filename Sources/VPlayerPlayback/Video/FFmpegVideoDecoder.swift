// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// INT32_C is not imported by Swift's Clang importer, so expose the bridge
// contract's positive status to the Swift adapter and its integration tests.
let VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT: Int32 = 1

/// A decoded frame borrowed for the duration of one synchronous callback.
struct BorrowedFFmpegVideoFrame: @unchecked Sendable {
    let luma: UnsafePointer<UInt8>?
    let chromaB: UnsafePointer<UInt8>?
    let chromaR: UnsafePointer<UInt8>?
    let lumaStride: Int
    let chromaBStride: Int
    let chromaRStride: Int
    let width: Int
    let height: Int
    let token: Int64
    let isInterlaced: Bool
    let topFieldFirst: Bool
    let range: VideoFormatMetadata.Range
    let abiVersion: UInt32
    let structSize: UInt32
}

struct FFmpegVideoPushResult: Equatable, Sendable {
    let status: Int32
    let failureToken: Int64?

    static let success = Self(status: 0, failureToken: nil)

    static func liveBridge(
        status: Int32,
        failureToken: Int64,
        hasFailureToken: UInt8
    ) -> Self {
        let eligible = hasFailureToken == 1
            && failureToken > 0
            && failureToken != Int64.min
        return Self(status: status, failureToken: eligible ? failureToken : nil)
    }
}

protocol FFmpegVideoDecoderHandle: AnyObject, Sendable {
    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> FFmpegVideoPushResult
    func flush()
    func destroy()
}

protocol FFmpegVideoDecoderAPI: Sendable {
    func create(
        extradata: Data,
        threadCount: Int32,
        receiver: @escaping @Sendable (BorrowedFFmpegVideoFrame) -> Void
    ) throws -> any FFmpegVideoDecoderHandle
}

private final class LiveVideoCallbackBox: @unchecked Sendable {
    let receiver: @Sendable (BorrowedFFmpegVideoFrame) -> Void

    init(receiver: @escaping @Sendable (BorrowedFFmpegVideoFrame) -> Void) {
        self.receiver = receiver
    }
}

private func liveFFmpegVideoCallback(
    context: UnsafeMutableRawPointer?,
    frame: UnsafePointer<VPFFVideoFrame>?
) {
    guard let context, let frame else { return }
    let box = Unmanaged<LiveVideoCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let range: VideoFormatMetadata.Range
    switch frame.pointee.range {
    case VPFF_VIDEO_RANGE_VIDEO: range = .video
    case VPFF_VIDEO_RANGE_FULL: range = .full
    default: range = .unknown
    }
    box.receiver(BorrowedFFmpegVideoFrame(
        luma: frame.pointee.luma,
        chromaB: frame.pointee.chroma_b,
        chromaR: frame.pointee.chroma_r,
        lumaStride: Int(frame.pointee.luma_stride),
        chromaBStride: Int(frame.pointee.chroma_b_stride),
        chromaRStride: Int(frame.pointee.chroma_r_stride),
        width: Int(frame.pointee.width),
        height: Int(frame.pointee.height),
        token: frame.pointee.pts,
        isInterlaced: frame.pointee.is_interlaced != 0,
        topFieldFirst: frame.pointee.top_field_first != 0,
        range: range,
        abiVersion: frame.pointee.abi_version,
        structSize: frame.pointee.struct_size
    ))
}

private final class LiveFFmpegVideoDecoderHandle: FFmpegVideoDecoderHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: OpaquePointer?
    private let box: LiveVideoCallbackBox
    private let retainedBox: Unmanaged<LiveVideoCallbackBox>

    init(decoder: OpaquePointer, box: LiveVideoCallbackBox, retained: Unmanaged<LiveVideoCallbackBox>) {
        self.decoder = decoder
        self.box = box
        retainedBox = retained
    }

    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> FFmpegVideoPushResult {
        lock.withLock {
            guard let decoder else { return .success }
            var failureToken: Int64 = 0
            var hasFailureToken: UInt8 = 0
            let status = vp_ffmpeg_video_decoder_push(
                decoder,
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                token,
                &failureToken,
                &hasFailureToken
            )
            return FFmpegVideoPushResult.liveBridge(
                status: status,
                failureToken: failureToken,
                hasFailureToken: hasFailureToken
            )
        }
    }

    func flush() {
        lock.withLock {
            guard let decoder else { return }
            vp_ffmpeg_video_decoder_flush(decoder)
        }
    }

    func destroy() {
        let owned: OpaquePointer? = lock.withLock {
            defer { decoder = nil }
            return decoder
        }
        guard let owned else { return }
        vp_ffmpeg_video_decoder_destroy(owned)
        retainedBox.release()
        _ = box
    }
}

struct LiveFFmpegVideoDecoderAPI: FFmpegVideoDecoderAPI {
    func create(
        extradata: Data,
        threadCount: Int32,
        receiver: @escaping @Sendable (BorrowedFFmpegVideoFrame) -> Void
    ) throws -> any FFmpegVideoDecoderHandle {
        let box = LiveVideoCallbackBox(receiver: receiver)
        let retained = Unmanaged.passRetained(box)
        var created: OpaquePointer?
        let status = extradata.withUnsafeBytes { raw -> Int32 in
            vp_ffmpeg_video_decoder_create(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                threadCount,
                liveFFmpegVideoCallback,
                retained.toOpaque(),
                &created
            )
        }
        guard status == 0, let created else {
            retained.release()
            throw VideoDecoderFailure.sessionCreate(OSStatus(status))
        }
        return LiveFFmpegVideoDecoderHandle(
            decoder: created,
            box: box,
            retained: retained
        )
    }
}

private final class FFmpegDecodeCompletionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let accessUnitID: UInt64
    private let identity: VideoDecoderEventIdentity
    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void

    init(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity,
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.accessUnitID = accessUnitID
        self.identity = identity
        self.executor = executor
        self.eventSink = eventSink
    }

    func schedule(
        disposition: @escaping @Sendable () -> VideoDecoderSubmissionDisposition
    ) {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldComplete else { return }
        let accessUnitID = accessUnitID
        let identity = identity
        let eventSink = eventSink
        executor.submit {
            eventSink(.submissionCompleted(
                accessUnitID: accessUnitID,
                identity: identity,
                disposition: disposition()
            ))
        }
    }

    func schedule(_ disposition: VideoDecoderSubmissionDisposition) {
        schedule(disposition: { disposition })
    }
}

private final class FFmpegPushProductionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var didProduce = false

    func markProduced() {
        lock.withLock { didProduce = true }
    }

    var produced: Bool { lock.withLock { didProduce } }
}

/// Software H.264 decoding for the content VideoToolbox cannot hardware decode.
///
/// Interlaced H.264 has no hardware path on Apple silicon — forcing it fails
/// outright — so VideoToolbox falls back to its own software decoder, which
/// manages around twenty frames a second against a 25 fps source on this
/// hardware. Every downstream symptom (submission blocking, the submission queue
/// skipping to the next keyframe, readiness closing, the audio renderer
/// recovering) follows from that shortfall. FFmpeg's decoder handles the same
/// stream at 7.2x realtime on a single thread, and threads across frames.
final class FFmpegVideoDecoder: VideoDecoding, @unchecked Sendable {
    private static let maximumPendingUnitCount = 64

    private struct ActiveSession: @unchecked Sendable {
        let handle: any FFmpegVideoDecoderHandle
        let identity: VideoDecoderEventIdentity
        let epoch: UInt64
        let colorAttachments: [CFString: Any]
    }

    /// CMBlockBuffer is a CoreFoundation type with no Sendable conformance, and
    /// the bytes are immutable for the unit's lifetime.
    private struct SubmittedUnit: @unchecked Sendable {
        let blockBuffer: CMBlockBuffer
        let accessUnitID: UInt64
        let generation: MediaGeneration
        let epoch: UInt64
        let token: Int64
    }

    private struct PendingUnit {
        let id: UInt64
        let presentationTimeStamp: CMTime
        let duration: CMTime
        let parserMetadata: VideoParserMetadata
        let epoch: UInt64
    }

    private struct ClaimedFrameDelivery: Hashable {
        let epoch: UInt64
        let token: Int64
    }

    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let api: any FFmpegVideoDecoderAPI
    private let surfacePool: ProgressiveSurfacePool
    private let submissionQueue: DispatchQueue
    private let submissionStartSink: (@Sendable (UInt64) -> Void)?
    private let metrics: PlaybackMetrics?
    private let sessionTransitionSink: (@Sendable (UInt64) -> Void)?

    private let stateLock = NSLock()
    private var active: ActiveSession?
    /// The decoder reorders, so the unit a frame came from is found by the token
    /// carried through FFmpeg rather than by arrival order.
    private var pending: [Int64: PendingUnit] = [:]
    private var nextToken: Int64 = 1
    private var sessionEpoch: UInt64 = 0
    private var activePushTracker: (epoch: UInt64, tracker: FFmpegPushProductionTracker)?
    /// `deliver` removes a token from `pending` before posting the frame to the
    /// playback executor. Track that exact hand-off so a native push failure can
    /// preserve only frames already copied before the failure was observed.
    private var claimedFrameDeliveries: Set<ClaimedFrameDelivery> = []
    private var nativeFailureDeliveryPermits: Set<ClaimedFrameDelivery> = []
    /// A native failure retires the session before already-admitted submissions
    /// necessarily reach the native queue. Keep only its identity so those
    /// submissions can release their completion leases as cancelled. A real
    /// transition clears this fence immediately.
    private var retiredCancellationIdentity: VideoDecoderEventIdentity?

    init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void,
        api: any FFmpegVideoDecoderAPI = LiveFFmpegVideoDecoderAPI(),
        surfacePool: ProgressiveSurfacePool = ProgressiveSurfacePool(),
        submissionQueue: DispatchQueue = DispatchQueue(
            label: "org.vplayer.playback.decode.ffmpeg",
            qos: .userInitiated
        ),
        submissionStartSink: (@Sendable (UInt64) -> Void)? = nil,
        metrics: PlaybackMetrics? = nil,
        sessionTransitionSink: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.executor = executor
        self.eventSink = eventSink
        self.api = api
        self.surfacePool = surfacePool
        self.submissionQueue = submissionQueue
        self.submissionStartSink = submissionStartSink
        self.metrics = metrics
        self.sessionTransitionSink = sessionTransitionSink
    }

    func transition(_ transition: VideoDecoderTransition) {
        switch transition {
        case let .configure(token, format, generation):
            let identity = VideoDecoderEventIdentity(
                generation: generation,
                transitionToken: token
            )
            let (replacementEpoch, previous) = beginTransition()
            submissionQueue.async { [self] in
                let outcome: VideoDecoderTransitionOutcome
                do {
                    try configureIsolated(
                        format: format,
                        identity: identity,
                        replacementEpoch: replacementEpoch,
                        previous: previous
                    )
                    outcome = .completed
                } catch let failure as VideoDecoderFailure {
                    outcome = .failed(failure)
                } catch {
                    outcome = .failed(.sessionCreate(kVTVideoDecoderMalfunctionErr))
                }
                completeTransition(token: token, outcome: outcome)
            }
        case let .drainAndInvalidate(token):
            let (_, previous) = beginTransition()
            submissionQueue.async { [self] in
                let outcome: VideoDecoderTransitionOutcome
                if let previous {
                    let result = previous.handle.push(
                        UnsafeRawBufferPointer(start: nil, count: 0),
                        token: 0
                    )
                    outcome = result.status == 0
                        ? .completed
                        : .failed(Self.failure(forNativeStatus: result.status))
                    previous.handle.destroy()
                } else {
                    outcome = .completed
                }
                completeTransition(token: token, outcome: outcome)
            }
        case let .invalidate(token):
            let (_, previous) = beginTransition()
            submissionQueue.async { [self] in
                previous?.handle.destroy()
                completeTransition(token: token, outcome: .completed)
            }
        }
    }

    private func beginTransition() -> (epoch: UInt64, previous: ActiveSession?) {
        let transition = stateLock.withLock { () -> (UInt64, ActiveSession?) in
            sessionEpoch &+= 1
            let previous = active
            active = nil
            pending.removeAll(keepingCapacity: true)
            activePushTracker = nil
            claimedFrameDeliveries.removeAll(keepingCapacity: true)
            nativeFailureDeliveryPermits.removeAll(keepingCapacity: true)
            retiredCancellationIdentity = nil
            return (sessionEpoch, previous)
        }
        sessionTransitionSink?(transition.0)
        return transition
    }

    private func completeTransition(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    ) {
        let eventSink = eventSink
        executor.submit {
            eventSink(.transitionCompleted(token: token, outcome: outcome))
        }
    }

    private func configureIsolated(
        format: CMVideoFormatDescription,
        identity: VideoDecoderEventIdentity,
        replacementEpoch: UInt64,
        previous: ActiveSession?
    ) throws {
        // `beginTransition` already fenced the old identity. Tear down that
        // native owner before any candidate validation/create can fail so an
        // unsupported replacement cannot strand an unreachable live handle.
        previous?.handle.destroy()
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
            throw VideoDecoderFailure.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)
        }
        let extradata = Self.avccRecord(from: format)
        let attachments = Self.colorAttachments(from: format)
        // `push`, teardown and installation all share this queue. The epoch was
        // bumped before enqueue, so queued old work drains as cancellation.
        let handle = try api.create(
            extradata: extradata,
            threadCount: Int32(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            receiver: { [weak self] frame in
                self?.deliver(frame)
            }
        )
        let installed = stateLock.withLock { () -> Bool in
            guard sessionEpoch == replacementEpoch, active == nil else { return false }
            active = ActiveSession(
                handle: handle,
                identity: identity,
                epoch: replacementEpoch,
                colorAttachments: attachments
            )
            return true
        }
        guard installed else {
            handle.destroy()
            throw VideoDecoderFailure.sessionCreate(kVTInvalidSessionErr)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        metrics?.recordDecoderSession(
            summary: "codec=avc1 \(dimensions.width)x\(dimensions.height) route=ffmpeg"
                + " threads=\(ProcessInfo.processInfo.activeProcessorCount)"
        )
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        guard let identity = stateLock.withLock({
            active?.identity ?? retiredCancellationIdentity
        }),
              identity.generation == accessUnit.generation else {
            throw VideoDecoderFailure.sessionCreate(kVTInvalidSessionErr)
        }
        let completion = FFmpegDecodeCompletionLease(
            accessUnitID: accessUnit.id,
            identity: identity,
            executor: executor,
            eventSink: eventSink
        )
        guard let blockBuffer = CMSampleBufferGetDataBuffer(accessUnit.sampleBuffer) else {
            throw VideoDecoderFailure.badData(kVTParameterErr)
        }
        let admission = stateLock.withLock {
            () -> (
                submitted: SubmittedUnit?,
                retired: (handle: any FFmpegVideoDecoderHandle, epoch: UInt64)?
            ) in
            guard let session = active,
                  session.identity == identity else { return (nil, nil) }
            guard pending.count < Self.maximumPendingUnitCount else {
                return (nil, retireSessionLocked(
                    epoch: session.epoch,
                    // Capacity retirement never licenses a claimed callback.
                    nativeFailure: nil
                ))
            }
            let issued = nextToken
            nextToken &+= 1
            pending[issued] = PendingUnit(
                id: accessUnit.id,
                presentationTimeStamp: CMSampleBufferGetOutputPresentationTimeStamp(
                    accessUnit.sampleBuffer
                ),
                duration: CMSampleBufferGetOutputDuration(accessUnit.sampleBuffer),
                parserMetadata: accessUnit.parserMetadata,
                epoch: session.epoch
            )
            return (
                SubmittedUnit(
                    blockBuffer: blockBuffer,
                    accessUnitID: accessUnit.id,
                    generation: accessUnit.generation,
                    epoch: session.epoch,
                    token: issued
                ),
                nil
            )
        }
        if let retired = admission.retired {
            sessionTransitionSink?(retired.epoch)
            submissionQueue.async { retired.handle.destroy() }
            report(
                .backpressureTimeout,
                accessUnitID: accessUnit.id,
                identity: identity
            )
            completion.schedule(.noFrame)
            return
        }
        let submitted = admission.submitted
        guard let submitted else {
            completion.schedule(.cancelled)
            return
        }

        // Decoding is the expensive thing this class does and it must not land on
        // the playback executor, which also runs demux admission and readiness.
        // Both generation and session epoch are re-checked on the queue. A
        // same-generation rebuild is still a different reference chain, so an
        // old queued unit must release its credit without entering the new one.
        let submissionStartSink = submissionStartSink
        submissionQueue.async { [weak self] in
            submissionStartSink?(submitted.accessUnitID)
            guard let self else {
                completion.schedule(.cancelled)
                return
            }
            let token = submitted.token
            guard let current = stateLock.withLock({ active }),
                  current.identity == identity,
                  current.epoch == submitted.epoch else {
                stateLock.withLock { _ = pending.removeValue(forKey: token) }
                metrics?.recordStaleGenerationDrop()
                completion.schedule(.cancelled)
                return
            }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                submitted.blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == noErr, let dataPointer, lengthAtOffset == totalLength else {
                stateLock.withLock { _ = pending.removeValue(forKey: token) }
                report(
                    .badData(status == noErr ? kVTParameterErr : status),
                    accessUnitID: submitted.accessUnitID,
                    identity: identity
                )
                completion.schedule(.noFrame)
                return
            }

            let production = FFmpegPushProductionTracker()
            guard stateLock.withLock({ () -> Bool in
                guard active?.identity == identity,
                      active?.epoch == submitted.epoch else { return false }
                activePushTracker = (submitted.epoch, production)
                return true
            }) else {
                stateLock.withLock { _ = pending.removeValue(forKey: token) }
                completion.schedule(.cancelled)
                return
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = current.handle.push(
                UnsafeRawBufferPointer(start: dataPointer, count: totalLength),
                token: token
            )
            stateLock.withLock {
                if activePushTracker?.epoch == submitted.epoch,
                   activePushTracker?.tracker === production {
                    activePushTracker = nil
                }
            }
            metrics?.recordVideoDecodeSubmission(
                milliseconds: max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            )
            guard result.status == 0 else {
                guard let retired = retireSession(
                    epoch: submitted.epoch,
                    nativeFailure: result
                ) else {
                    completion.schedule(.cancelled)
                    return
                }
                sessionTransitionSink?(retired.epoch)
                retired.handle.destroy()
                report(
                    Self.failure(forNativeStatus: result.status),
                    accessUnitID: submitted.accessUnitID,
                    identity: identity
                )
                completion.schedule(.noFrame)
                return
            }
            completion.schedule(disposition: { [weak self] in
                guard let self,
                      stateLock.withLock({
                          active?.identity == identity
                              && active?.epoch == submitted.epoch
                      }) else { return .cancelled }
                return production.produced ? .produced : .noFrame
            })
        }
    }

    private func retireSession(
        epoch: UInt64,
        nativeFailure: FFmpegVideoPushResult
    ) -> (handle: any FFmpegVideoDecoderHandle, epoch: UInt64)? {
        stateLock.withLock {
            retireSessionLocked(
                epoch: epoch,
                nativeFailure: nativeFailure
            )
        }
    }

    /// Must be called while `stateLock` is held so capacity admission and
    /// retirement remain one atomic state transition.
    private func retireSessionLocked(
        epoch: UInt64,
        nativeFailure: FFmpegVideoPushResult?
    ) -> (handle: any FFmpegVideoDecoderHandle, epoch: UInt64)? {
        guard let active, active.epoch == epoch else { return nil }
        let failureBelongsToCurrentEpoch = nativeFailure?.failureToken.map { token in
            pending[token]?.epoch == epoch
                || claimedFrameDeliveries.contains(ClaimedFrameDelivery(epoch: epoch, token: token))
        } ?? false
        let deliveryPermits = failureBelongsToCurrentEpoch
            ? claimedFrameDeliveries
            : []
        sessionEpoch &+= 1
        self.active = nil
        retiredCancellationIdentity = active.identity
        pending.removeAll(keepingCapacity: true)
        activePushTracker = nil
        claimedFrameDeliveries.removeAll(keepingCapacity: true)
        nativeFailureDeliveryPermits = deliveryPermits
        return (active.handle, sessionEpoch)
    }

    private static func failure(forNativeStatus status: Int32) -> VideoDecoderFailure {
        if status == VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT {
            return .badData(kVTVideoDecoderUnsupportedDataFormatErr)
        }
        return .badData(OSStatus(status))
    }

    private func report(
        _ failure: VideoDecoderFailure,
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity
    ) {
        let eventSink = eventSink
        executor.submit {
            eventSink(.submissionFailure(
                accessUnitID: accessUnitID,
                failure: failure,
                identity: identity
            ))
        }
    }

    private func deliver(_ frame: BorrowedFFmpegVideoFrame) {
        guard frame.abiVersion == VPFF_VIDEO_DECODER_ABI_VERSION,
              Int(frame.structSize) >= MemoryLayout<VPFFVideoFrame>.size,
              let luma = frame.luma,
              let chromaB = frame.chromaB,
              let chromaR = frame.chromaR else { return }
        let state = stateLock.withLock {
            () -> (
                PendingUnit,
                ActiveSession,
                FFmpegPushProductionTracker?,
                ClaimedFrameDelivery
            )? in
            guard let active,
                  let unit = pending.removeValue(forKey: frame.token),
                  unit.epoch == active.epoch else { return nil }
            let claim = ClaimedFrameDelivery(epoch: active.epoch, token: frame.token)
            claimedFrameDeliveries.insert(claim)
            let tracker = activePushTracker?.epoch == active.epoch
                ? activePushTracker?.tracker
                : nil
            return (unit, active, tracker, claim)
        }
        guard let (unit, session, production, claim) = state else { return }

        guard let pixelBuffer = makePixelBuffer(
            width: frame.width,
            height: frame.height,
            luma: luma,
            lumaStride: frame.lumaStride,
            chromaB: chromaB,
            chromaBStride: frame.chromaBStride,
            chromaR: chromaR,
            chromaRStride: frame.chromaRStride,
            range: frame.range,
            attachments: session.colorAttachments
        ) else {
            cancelClaimedFrameDelivery(claim)
            metrics?.recordVideoDrop(source: .decoderRecoverable)
            return
        }

        guard let formatMetadata = try? VideoFormatMetadataReader.read(from: pixelBuffer) else {
            cancelClaimedFrameDelivery(claim)
            metrics?.recordVideoDrop(source: .decoderRecoverable)
            return
        }
        let decoded = DecodedVideoFrame(
            accessUnitID: unit.id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: unit.presentationTimeStamp,
            duration: unit.duration,
            generation: session.identity.generation,
            parserMetadata: Self.merged(unit.parserMetadata, with: frame),
            formatMetadata: formatMetadata
        )
        metrics?.recordDecoderCallback()
        let expectedEpoch = session.epoch
        let identity = session.identity
        let eventSink = eventSink
        executor.submit { [weak self] in
            guard let self else { return }
            let admitted = stateLock.withLock { () -> Bool in
                if active?.epoch == expectedEpoch,
                   active?.identity == identity {
                    return claimedFrameDeliveries.remove(claim) != nil
                }
                if nativeFailureDeliveryPermits.remove(claim) != nil { return true }
                claimedFrameDeliveries.remove(claim)
                return false
            }
            guard admitted else {
                metrics?.recordStaleGenerationDrop()
                return
            }
            production?.markProduced()
            eventSink(.frame(decoded, identity: identity))
        }
    }

    private func cancelClaimedFrameDelivery(_ claim: ClaimedFrameDelivery) {
        stateLock.withLock {
            claimedFrameDeliveries.remove(claim)
            nativeFailureDeliveryPermits.remove(claim)
        }
    }

    /// The decoder produces three planes and the pipeline consumes two. The
    /// interleave is the only conversion, and it happens in the shim rather than
    /// through swscale, which this FFmpeg build deliberately does not include —
    /// and rather than here, because a per-byte loop over half a million pixels
    /// costs more than the decode it is serving.
    private func makePixelBuffer(
        width: Int,
        height: Int,
        luma: UnsafePointer<UInt8>,
        lumaStride: Int,
        chromaB: UnsafePointer<UInt8>,
        chromaBStride: Int,
        chromaR: UnsafePointer<UInt8>,
        chromaRStride: Int,
        range: VideoFormatMetadata.Range,
        attachments: [CFString: Any]
    ) -> CVPixelBuffer? {
        guard width >= 2, height >= 2, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            return nil
        }
        let pixelFormat = range == .full
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let output = try? surfacePool.allocate(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        ) else { return nil }

        // The decoder reports colour through the stream's own signalling, which
        // the format description already carries; the reader downstream expects
        // to find it on the buffer.
        if !attachments.isEmpty {
            CVBufferSetAttachments(output, attachments as CFDictionary, .shouldPropagate)
        }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let lumaOut = CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let chromaOut = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }

        vp_ffmpeg_video_write_biplanar(
            luma,
            Int32(lumaStride),
            chromaB,
            Int32(chromaBStride),
            chromaR,
            Int32(chromaRStride),
            lumaOut.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBytesPerRowOfPlane(output, 0),
            chromaOut.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBytesPerRowOfPlane(output, 1),
            Int32(width),
            Int32(height)
        )
        return output
    }

    private static func merged(
        _ parserMetadata: VideoParserMetadata,
        with frame: BorrowedFFmpegVideoFrame
    ) -> VideoParserMetadata {
        // The parser reads the stream's own signalling; the decoder reports what
        // it actually produced. Prefer the parser and fall back to the decoder.
        VideoParserMetadata(
            fieldOrder: parserMetadata.fieldOrder,
            pictureStructure: parserMetadata.pictureStructure,
            isInterlaced: (parserMetadata.isInterlaced ?? false) || frame.isInterlaced,
            repeatFirstField: parserMetadata.repeatFirstField,
            topFieldFirst: parserMetadata.topFieldFirst
                ?? (frame.isInterlaced ? frame.topFieldFirst : nil),
            sourcePTS90k: parserMetadata.sourcePTS90k
        )
    }

    static func colorAttachments(from format: CMVideoFormatDescription) -> [CFString: Any] {
        guard let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] else {
            return [:]
        }
        let carried: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferContentLightLevelInfoKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
        ]
        return carried.reduce(into: [:]) { result, key in
            if let value = extensions[key] { result[key] = value }
        }
    }

    /// FFmpeg's H.264 decoder takes the avcC record as extradata and reads
    /// length-prefixed NAL units, which is exactly what the sample buffers carry.
    static func avccRecord(from format: CMVideoFormatDescription) -> Data {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        guard let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? [String: Any],
            let record = atoms["avcC"] as? Data else {
            return Data()
        }
        return record
    }
}

/// Picks the decoder that can actually keep up with the stream in front of it.
///
/// VideoToolbox is the right answer for progressive content: the hardware path
/// costs almost nothing. It is the wrong answer for field-coded H.264, which has
/// no hardware path on Apple silicon at all — forcing it fails outright — so
final class RoutingVideoDecoderChildRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: RoutingVideoDecoder?

    func install(_ target: RoutingVideoDecoder) {
        lock.withLock { self.target = target }
    }

    func receive(_ event: VideoDecoderEvent, from route: RoutingVideoDecoder.Route) {
        lock.withLock { target }?.receive(event, from: route)
    }
}

/// VideoToolbox falls back to a software decoder that delivers about twenty
/// frames a second against a 25 fps source. FFmpeg decodes the same stream at
/// 7.2x realtime on one thread.
final class RoutingVideoDecoder: VideoDecoding, @unchecked Sendable {
    enum Route: Sendable, Equatable {
        case videoToolbox
        case ffmpeg
    }

    private struct Session {
        let route: Route
        let decoder: any VideoDecoding
        let identity: VideoDecoderEventIdentity
    }

    private struct PendingTransition {
        let route: Route
        let decoder: any VideoDecoding
        let token: VideoDecoderTransitionToken
        let identity: VideoDecoderEventIdentity?
    }

    private let videoToolbox: any VideoDecoding
    private let ffmpeg: any VideoDecoding
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let lock = NSLock()
    private var active: Session?
    private var pendingTransition: PendingTransition?
    private var format: CMVideoFormatDescription?
    private var generation = MediaGeneration(rawValue: 0)
    private var requestedRoute: Route?

    init(
        videoToolbox: any VideoDecoding,
        ffmpeg: any VideoDecoding,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.videoToolbox = videoToolbox
        self.ffmpeg = ffmpeg
        self.eventSink = eventSink
    }

    /// A field count above one is the format description stating that the coded
    /// pictures are fields — the one case VideoToolbox has no hardware path for.
    ///
    /// Streams frequently do not say so here, and the parser learns it from the
    /// pictures instead. Routing on *that* is not wired up, and must not be until
    /// the planar-to-biplanar conversion below stops costing more than it saves:
    /// measured on device, the FFmpeg route spent 104 ms a frame against
    /// VideoToolbox's 35 ms, almost all of it in the scalar chroma interleave.
    static func prefersFFmpeg(for format: CMVideoFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
            return false
        }
        let fieldCount = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_FieldCount
        ) as? NSNumber
        return (fieldCount?.intValue ?? 1) > 1
    }

    func transition(_ transition: VideoDecoderTransition) {
        switch transition {
        case let .configure(token, format, generation):
            let route = lock.withLock { () -> Route in
                defer { requestedRoute = nil }
                if let requestedRoute { return requestedRoute }
                return Self.prefersFFmpeg(for: format) ? .ffmpeg : .videoToolbox
            }
            let selected: any VideoDecoding = route == .ffmpeg ? ffmpeg : videoToolbox
            let identity = VideoDecoderEventIdentity(
                generation: generation,
                transitionToken: token
            )
            let stale = lock.withLock {
                () -> [(route: Route, decoder: any VideoDecoding)] in
                var stale: [(Route, any VideoDecoding)] = []
                if let active, active.route != route {
                    stale.append((active.route, active.decoder))
                }
                if let pendingTransition, pendingTransition.route != route,
                   !stale.contains(where: { $0.0 == pendingTransition.route }) {
                    stale.append((pendingTransition.route, pendingTransition.decoder))
                }
                active = nil
                pendingTransition = PendingTransition(
                    route: route,
                    decoder: selected,
                    token: token,
                    identity: identity
                )
                self.format = format
                self.generation = generation
                return stale
            }
            for staleRoute in stale {
                staleRoute.decoder.transition(.invalidate(
                    token: VideoDecoderTransitionToken()
                ))
            }
            selected.transition(transition)
        case let .drainAndInvalidate(token), let .invalidate(token):
            let target = lock.withLock {
                () -> (route: Route, decoder: any VideoDecoding)? in
                let target: (route: Route, decoder: any VideoDecoding)?
                if let pendingTransition {
                    target = (pendingTransition.route, pendingTransition.decoder)
                } else if let active {
                    target = (active.route, active.decoder)
                } else {
                    target = nil
                }
                active = nil
                if let target {
                    pendingTransition = PendingTransition(
                        route: target.route,
                        decoder: target.decoder,
                        token: token,
                        identity: nil
                    )
                } else {
                    pendingTransition = nil
                }
                format = nil
                requestedRoute = nil
                return target
            }
            guard let target else {
                eventSink(.transitionCompleted(token: token, outcome: .completed))
                return
            }
            target.decoder.transition(transition)
        }
    }

    func transitionRequirement(
        for accessUnit: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement? {
        lock.withLock {
            guard pendingTransition == nil,
                  active?.route == .videoToolbox,
                  accessUnit.generation == generation,
                  accessUnit.isRandomAccess,
                  accessUnit.parserMetadata.isInterlaced == true,
                  let format,
                  CMFormatDescriptionGetMediaSubType(format)
                      == kCMVideoCodecType_H264 else { return nil }
            requestedRoute = .ffmpeg
            return .reconfigure
        }
    }

    func receive(_ event: VideoDecoderEvent, from route: Route) {
        switch event {
        case let .transitionCompleted(token, outcome):
            let shouldForward = lock.withLock { () -> Bool in
                guard let pendingTransition,
                      pendingTransition.route == route,
                      pendingTransition.token == token else { return false }
                defer { self.pendingTransition = nil }
                if outcome == .completed, let identity = pendingTransition.identity {
                    active = Session(
                        route: route,
                        decoder: pendingTransition.decoder,
                        identity: identity
                    )
                }
                return true
            }
            if shouldForward { eventSink(event) }
        case let .submissionCompleted(accessUnitID, identity, disposition):
            let matches = lock.withLock {
                active?.route == route && active?.identity == identity
            }
            eventSink(.submissionCompleted(
                accessUnitID: accessUnitID,
                identity: identity,
                disposition: matches ? disposition : .cancelled
            ))
        case let .frame(_, identity),
             let .recoverableFailure(_, identity),
             let .fatalFailure(_, identity),
             let .submissionFailure(_, _, identity):
            let matches = lock.withLock {
                active?.route == route && active?.identity == identity
            }
            if matches { eventSink(event) }
        }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        guard let active = lock.withLock({ active }),
              active.identity.generation == accessUnit.generation else {
            throw VideoDecoderFailure.sessionCreate(kVTInvalidSessionErr)
        }
        try active.decoder.decode(accessUnit, flags: flags)
    }

    func setTuning(_ tuning: PlaybackTuning) {
        videoToolbox.setTuning(tuning)
        ffmpeg.setTuning(tuning)
    }
}
