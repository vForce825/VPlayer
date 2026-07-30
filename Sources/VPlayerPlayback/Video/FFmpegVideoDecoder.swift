// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

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

protocol FFmpegVideoDecoderHandle: AnyObject, Sendable {
    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> Int32
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

    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> Int32 {
        lock.withLock {
            guard let decoder else { return 0 }
            return vp_ffmpeg_video_decoder_push(
                decoder,
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                token
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
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldComplete else { return }
        let accessUnitID = accessUnitID
        let generation = generation
        let eventSink = eventSink
        executor.submit {
            eventSink(.submissionCompleted(
                accessUnitID: accessUnitID,
                generation: generation
            ))
        }
    }
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
    private struct ActiveSession {
        let handle: any FFmpegVideoDecoderHandle
        let generation: MediaGeneration
        let epoch: UInt64
        let colorAttachments: [CFString: Any]
    }

    /// CMBlockBuffer is a CoreFoundation type with no Sendable conformance, and
    /// the bytes are immutable for the unit's lifetime.
    private struct SubmittedUnit: @unchecked Sendable {
        let blockBuffer: CMBlockBuffer
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

    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let api: any FFmpegVideoDecoderAPI
    private let surfacePool: ProgressiveSurfacePool
    private let submissionQueue: DispatchQueue
    private let metrics: PlaybackMetrics?
    private let sessionTransitionSink: (@Sendable (UInt64) -> Void)?

    private let stateLock = NSLock()
    private var active: ActiveSession?
    /// The decoder reorders, so the unit a frame came from is found by the token
    /// carried through FFmpeg rather than by arrival order.
    private var pending: [Int64: PendingUnit] = [:]
    private var nextToken: Int64 = 1
    private var sessionEpoch: UInt64 = 0

    init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void,
        api: any FFmpegVideoDecoderAPI = LiveFFmpegVideoDecoderAPI(),
        surfacePool: ProgressiveSurfacePool = ProgressiveSurfacePool(),
        submissionQueue: DispatchQueue = DispatchQueue(
            label: "org.vplayer.playback.decode.ffmpeg",
            qos: .userInitiated
        ),
        metrics: PlaybackMetrics? = nil,
        sessionTransitionSink: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.executor = executor
        self.eventSink = eventSink
        self.api = api
        self.surfacePool = surfacePool
        self.submissionQueue = submissionQueue
        self.metrics = metrics
        self.sessionTransitionSink = sessionTransitionSink
    }

    func configure(
        format: CMVideoFormatDescription,
        generation: MediaGeneration
    ) throws {
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
            throw VideoDecoderFailure.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)
        }
        let extradata = Self.avccRecord(from: format)
        let attachments = Self.colorAttachments(from: format)
        let (replacementEpoch, previous) = stateLock.withLock {
            () -> (UInt64, ActiveSession?) in
            sessionEpoch &+= 1
            let previous = active
            active = nil
            pending.removeAll(keepingCapacity: true)
            return (sessionEpoch, previous)
        }
        sessionTransitionSink?(replacementEpoch)
        try submissionQueue.sync {
            // `push`, teardown and installation all share this queue. The epoch
            // was bumped before waiting for it, so queued old work drains as a
            // cancellation and every accepted unit still runs its completion.
            previous?.handle.destroy()
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
                    generation: generation,
                    epoch: replacementEpoch,
                    colorAttachments: attachments
                )
                return true
            }
            guard installed else {
                handle.destroy()
                throw VideoDecoderFailure.sessionCreate(kVTInvalidSessionErr)
            }
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        metrics?.recordDecoderSession(
            summary: "codec=avc1 \(dimensions.width)x\(dimensions.height) route=ffmpeg"
                + " threads=\(ProcessInfo.processInfo.activeProcessorCount)"
        )
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        let completion = FFmpegDecodeCompletionLease(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation,
            executor: executor,
            eventSink: eventSink
        )
        guard let blockBuffer = CMSampleBufferGetDataBuffer(accessUnit.sampleBuffer) else {
            throw VideoDecoderFailure.badData(kVTParameterErr)
        }
        let submitted = stateLock.withLock { () -> SubmittedUnit? in
            guard let session = active,
                  session.generation == accessUnit.generation else { return nil }
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
            return SubmittedUnit(
                blockBuffer: blockBuffer,
                generation: accessUnit.generation,
                epoch: session.epoch,
                token: issued
            )
        }
        guard let submitted else {
            completion.schedule()
            return
        }

        // Decoding is the expensive thing this class does and it must not land on
        // the playback executor, which also runs demux admission and readiness.
        // Both generation and session epoch are re-checked on the queue. A
        // same-generation rebuild is still a different reference chain, so an
        // old queued unit must release its credit without entering the new one.
        submissionQueue.async { [weak self] in
            defer { completion.schedule() }
            guard let self else { return }
            let generation = submitted.generation
            let token = submitted.token
            guard let current = stateLock.withLock({ active }),
                  current.generation == generation,
                  current.epoch == submitted.epoch else {
                stateLock.withLock { _ = pending.removeValue(forKey: token) }
                metrics?.recordStaleGenerationDrop()
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
                report(.badData(status == noErr ? kVTParameterErr : status), generation: generation)
                return
            }

            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = current.handle.push(
                UnsafeRawBufferPointer(start: dataPointer, count: totalLength),
                token: token
            )
            metrics?.recordVideoDecodeSubmission(
                milliseconds: max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            )
            guard result == 0 else {
                stateLock.withLock { _ = pending.removeValue(forKey: token) }
                report(.badData(OSStatus(result)), generation: generation)
                return
            }
        }
    }

    private func report(_ failure: VideoDecoderFailure, generation: MediaGeneration) {
        let eventSink = eventSink
        executor.submit { eventSink(.submissionFailure(failure, generation: generation)) }
    }

    func finishDelayedFrames() throws {
        // Waits for units already queued rather than cancelling them, matching
        // the drain the VideoToolbox route performs.
        submissionQueue.sync {
            guard let session = stateLock.withLock({ active }) else { return }
            _ = session.handle.push(UnsafeRawBufferPointer(start: nil, count: 0), token: 0)
        }
    }

    func waitForAsynchronousFrames() throws {}

    func invalidate() {
        let (invalidatedEpoch, previous) = stateLock.withLock {
            () -> (UInt64, ActiveSession?) in
            sessionEpoch &+= 1
            let previous = active
            active = nil
            pending.removeAll(keepingCapacity: true)
            return (sessionEpoch, previous)
        }
        sessionTransitionSink?(invalidatedEpoch)
        submissionQueue.sync { previous?.handle.destroy() }
    }

    private func deliver(_ frame: BorrowedFFmpegVideoFrame) {
        guard frame.abiVersion == VPFF_VIDEO_DECODER_ABI_VERSION,
              Int(frame.structSize) >= MemoryLayout<VPFFVideoFrame>.size,
              let luma = frame.luma,
              let chromaB = frame.chromaB,
              let chromaR = frame.chromaR else { return }
        let state = stateLock.withLock { () -> (PendingUnit, ActiveSession)? in
            guard let active,
                  let unit = pending.removeValue(forKey: frame.token),
                  unit.epoch == active.epoch else { return nil }
            return (unit, active)
        }
        guard let (unit, session) = state else { return }

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
            metrics?.recordVideoDrop(source: .decoderRecoverable)
            return
        }

        guard let formatMetadata = try? VideoFormatMetadataReader.read(from: pixelBuffer) else {
            metrics?.recordVideoDrop(source: .decoderRecoverable)
            return
        }
        let decoded = DecodedVideoFrame(
            accessUnitID: unit.id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: unit.presentationTimeStamp,
            duration: unit.duration,
            generation: session.generation,
            parserMetadata: Self.merged(unit.parserMetadata, with: frame),
            formatMetadata: formatMetadata
        )
        metrics?.recordDecoderCallback()
        let expectedEpoch = session.epoch
        let eventSink = eventSink
        executor.submit { [weak self] in
            guard let self,
                  stateLock.withLock({ active?.epoch == expectedEpoch }) else {
                self?.metrics?.recordStaleGenerationDrop()
                return
            }
            eventSink(.frame(decoded))
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
            topFieldFirst: parserMetadata.topFieldFirst ?? frame.topFieldFirst,
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
/// VideoToolbox falls back to a software decoder that delivers about twenty
/// frames a second against a 25 fps source. FFmpeg decodes the same stream at
/// 7.2x realtime on one thread.
final class RoutingVideoDecoder: VideoDecoding, @unchecked Sendable {
    private let videoToolbox: any VideoDecoding
    private let ffmpeg: any VideoDecoding
    private let lock = NSLock()
    private var active: (any VideoDecoding)?
    private var format: CMVideoFormatDescription?
    private var generation = MediaGeneration(rawValue: 0)
    private var isOnFFmpeg = false

    init(videoToolbox: any VideoDecoding, ffmpeg: any VideoDecoding) {
        self.videoToolbox = videoToolbox
        self.ffmpeg = ffmpeg
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

    func configure(format: CMVideoFormatDescription, generation: MediaGeneration) throws {
        let useFFmpeg = Self.prefersFFmpeg(for: format)
        let selected: any VideoDecoding = useFFmpeg ? ffmpeg : videoToolbox
        let previous = lock.withLock { () -> (any VideoDecoding)? in
            let stale = active === selected ? nil : active
            active = selected
            isOnFFmpeg = useFFmpeg
            self.format = format
            self.generation = generation
            return stale
        }
        previous?.invalidate()
        try selected.configure(format: format, generation: generation)
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        try switchToFFmpegIfNeeded(for: accessUnit)
        guard let active = lock.withLock({ active }) else {
            throw VideoDecoderFailure.sessionCreate(kVTInvalidSessionErr)
        }
        try active.decode(accessUnit, flags: flags)
    }

    /// Format descriptions frequently do not admit that a stream is field coded;
    /// the parser reads it from the pictures themselves. Switching only on a
    /// random-access unit means the new decoder opens on a keyframe rather than
    /// mid-GOP, where it would emit nothing usable until the next one anyway.
    private func switchToFFmpegIfNeeded(for accessUnit: CompressedVideoAccessUnit) throws {
        guard accessUnit.parserMetadata.isInterlaced == true, accessUnit.isRandomAccess else {
            return
        }
        let pending = lock.withLock { () -> (CMVideoFormatDescription, MediaGeneration)? in
            guard !isOnFFmpeg,
                  let format,
                  generation == accessUnit.generation,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
                return nil
            }
            return (format, generation)
        }
        guard let (format, generation) = pending else { return }
        try ffmpeg.configure(format: format, generation: generation)
        let previous = lock.withLock { () -> (any VideoDecoding)? in
            let stale = active
            active = ffmpeg
            isOnFFmpeg = true
            return stale === ffmpeg ? nil : stale
        }
        previous?.invalidate()
    }

    func finishDelayedFrames() throws {
        try lock.withLock { active }?.finishDelayedFrames()
    }

    func waitForAsynchronousFrames() throws {
        try lock.withLock { active }?.waitForAsynchronousFrames()
    }

    func invalidate() {
        let current = lock.withLock { () -> (any VideoDecoding)? in
            defer {
                active = nil
                isOnFFmpeg = false
                format = nil
            }
            return active
        }
        current?.invalidate()
    }

    func setTuning(_ tuning: PlaybackTuning) {
        videoToolbox.setTuning(tuning)
        ffmpeg.setTuning(tuning)
    }
}
