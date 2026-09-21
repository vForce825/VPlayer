// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct VideoFormatMetadata: Sendable, Equatable {
    public enum Range: Sendable, Equatable { case video, full, unknown }
    public enum Matrix: Sendable, Equatable { case bt601, bt709, bt2020, identity, unknown }
    public enum Transfer: Sendable, Equatable { case bt709, pq, hlg, linear, unknown }
    public enum Primaries: Sendable, Equatable { case bt709, bt2020, unknown }

    public struct ChromaLocation: Sendable, Equatable {
        public let topField: String?
        public let bottomField: String?

        public init(topField: String?, bottomField: String?) {
            self.topField = topField
            self.bottomField = bottomField
        }
    }

    public struct HDRStaticMetadata: Sendable, Equatable {
        public let masteringDisplayColorVolume: Data?
        public let contentLightLevelInfo: Data?

        public init(masteringDisplayColorVolume: Data?, contentLightLevelInfo: Data?) {
            self.masteringDisplayColorVolume = masteringDisplayColorVolume
            self.contentLightLevelInfo = contentLightLevelInfo
        }
    }

    public let dimensions: CMVideoDimensions
    public let bitDepth: Int
    public let range: Range
    public let matrix: Matrix
    public let transfer: Transfer
    public let primaries: Primaries
    public let cleanAperture: CGRect?
    public let chromaLocation: ChromaLocation
    public let hdrStaticMetadata: HDRStaticMetadata
    public let sampleAspectRatio: MediaRational?

    public init(
        dimensions: CMVideoDimensions,
        bitDepth: Int,
        range: Range,
        matrix: Matrix,
        transfer: Transfer,
        primaries: Primaries,
        cleanAperture: CGRect?,
        chromaLocation: ChromaLocation,
        hdrStaticMetadata: HDRStaticMetadata,
        sampleAspectRatio: MediaRational? = nil
    ) {
        self.dimensions = dimensions
        self.bitDepth = bitDepth
        self.range = range
        self.matrix = matrix
        self.transfer = transfer
        self.primaries = primaries
        self.cleanAperture = cleanAperture
        self.chromaLocation = chromaLocation
        self.hdrStaticMetadata = hdrStaticMetadata
        self.sampleAspectRatio = sampleAspectRatio
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dimensions.width == rhs.dimensions.width
            && lhs.dimensions.height == rhs.dimensions.height
            && lhs.bitDepth == rhs.bitDepth
            && lhs.range == rhs.range
            && lhs.matrix == rhs.matrix
            && lhs.transfer == rhs.transfer
            && lhs.primaries == rhs.primaries
            && lhs.cleanAperture == rhs.cleanAperture
            && lhs.chromaLocation == rhs.chromaLocation
            && lhs.hdrStaticMetadata == rhs.hdrStaticMetadata
            && lhs.sampleAspectRatio == rhs.sampleAspectRatio
    }
}

public final class DecodedVideoFrameRetentionTail: @unchecked Sendable {
    private let onRelease: @Sendable () -> Void
    /// HLS 专用：decoder 输入与未来 YADIF pair 的同一 conversion reservation。
    /// 不附着到 CoreVideo attachment，避免被复制到不相同的 backing。
    let outputBackingTail: VideoOutputBackingRetentionTail?
    public init(
        onRelease: @escaping @Sendable () -> Void,
        outputBackingTail: VideoOutputBackingRetentionTail? = nil
    ) {
        self.onRelease = onRelease
        self.outputBackingTail = outputBackingTail
    }
    deinit { onRelease() }
}

/// 原生 decoder 在把输出交给应用侧之前取得的 surface owner。
///
/// HLS 将实现安装在 VT/FFmpeg 的 submission callback lane；普通播放保持
/// `nil`，因此不改变旧的 callback 或展示所有权。
protocol DecodedVideoSurfaceAdmitting: AnyObject, Sendable {
    /// 返回的 tail 必须随最终 `DecodedVideoFrame` 的最后一个 holder 存活。
    /// `nil` 表示取消或永久拒绝，调用者不得捕获/复制该输出。
    func admitSurface(bytes: Int) -> DecodedVideoFrameRetentionTail?
    /// VT 已经给出真实 backing 时，HLS 可按真实输入和未来输出 pair 一起准入。
    func admitSurface(pixelBuffer: CVPixelBuffer) -> DecodedVideoFrameRetentionTail?
    /// 先关闭等待者，再由 caller 排 native invalidation，避免 stop 卡在 callback。
    func cancelSurfaceAdmission()
    /// 每个 native session 都有自己的 scope；永久拒绝必须带着该 session 的
    /// identity 走 decoder 的既有 fatal 路径。取消仍只返回 nil，不触发此回调。
    func makeSurfaceSessionScope(
        permanentFailureSink: @escaping @Sendable () -> Void
    ) -> any DecodedVideoSurfaceAdmitting
    /// HLS 的 FFmpeg 输出可选择提供明确 backing 契约的 surface：费用先于
    /// allocation，非 HLS 返回 nil 后保持既有 pool 行为。
    func allocateAdmittedFFmpegSurface(
        width: Int, height: Int, range: VideoFormatMetadata.Range
    ) -> (pixelBuffer: CVPixelBuffer, tail: DecodedVideoFrameRetentionTail)?
}

extension DecodedVideoSurfaceAdmitting {
    func admitSurface(pixelBuffer: CVPixelBuffer) -> DecodedVideoFrameRetentionTail? {
        admitSurface(bytes: CVPixelBufferGetDataSize(pixelBuffer))
    }
    func makeSurfaceSessionScope(
        permanentFailureSink _: @escaping @Sendable () -> Void = {}
    ) -> any DecodedVideoSurfaceAdmitting { self }
    func allocateAdmittedFFmpegSurface(
        width _: Int, height _: Int, range _: VideoFormatMetadata.Range
    ) -> (pixelBuffer: CVPixelBuffer, tail: DecodedVideoFrameRetentionTail)? { nil }
}

public struct DecodedVideoFrame: @unchecked Sendable {
    public let accessUnitID: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let generation: MediaGeneration
    public let parserMetadata: VideoParserMetadata
    public let formatMetadata: VideoFormatMetadata
    let retentionTail: DecodedVideoFrameRetentionTail?

    public init(
        accessUnitID: UInt64,
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        parserMetadata: VideoParserMetadata,
        formatMetadata: VideoFormatMetadata,
        retentionTail: DecodedVideoFrameRetentionTail? = nil
    ) {
        self.accessUnitID = accessUnitID
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.generation = generation
        self.parserMetadata = parserMetadata
        self.formatMetadata = formatMetadata
        self.retentionTail = retentionTail
    }
}

public enum VideoDecoderFailure: Error, Sendable, Equatable {
    case sessionCreate(OSStatus)
    case softwareDecoder
    case badData(OSStatus)
    case malfunction(OSStatus)
    case backpressureTimeout
}

/// Identifies one decoder transition and, after a successful configure, the
/// decoder session established by that transition.
///
/// Tokens are deliberately opaque and freshly generated. Media generation is
/// not enough to fence a same-generation session replacement or route switch.
public struct VideoDecoderTransitionToken: Sendable, Hashable {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

public enum VideoDecoderTransitionOutcome: Sendable, Equatable {
    case completed
    case failed(VideoDecoderFailure)
}

public enum VideoDecoderTransition: @unchecked Sendable {
    case configure(
        token: VideoDecoderTransitionToken,
        format: CMVideoFormatDescription,
        generation: MediaGeneration
    )
    /// 自然 EOF：排空 native 延迟帧，但保留当前 session 与事件 identity。
    case drain(token: VideoDecoderTransitionToken)
    case drainAndInvalidate(token: VideoDecoderTransitionToken)
    case invalidate(token: VideoDecoderTransitionToken)
}

public struct VideoDecoderEventIdentity: Sendable, Hashable {
    public let generation: MediaGeneration
    public let transitionToken: VideoDecoderTransitionToken

    public init(
        generation: MediaGeneration,
        transitionToken: VideoDecoderTransitionToken
    ) {
        self.generation = generation
        self.transitionToken = transitionToken
    }
}

public enum VideoDecoderSubmissionDisposition: Sendable, Equatable {
    case produced
    case noFrame
    case cancelled
}

public enum VideoDecoderTransitionRequirement: Sendable, Equatable {
    /// The current media format remains valid, but the decoder implementation
    /// or native session must change before this access unit is submitted.
    case reconfigure
}

public enum VideoDecoderEvent: @unchecked Sendable {
    case frame(DecodedVideoFrame, identity: VideoDecoderEventIdentity)
    case recoverableFailure(VideoDecoderFailure, identity: VideoDecoderEventIdentity)
    case fatalFailure(VideoDecoderFailure, identity: VideoDecoderEventIdentity)
    /// A submission that could not be handed to the decode session at all.
    ///
    /// Submission does not happen on the caller's thread, so the failure cannot
    /// come back as a `throw` from `decode`. It carries the same failures the
    /// synchronous path used to raise and is classified identically.
    case submissionFailure(
        accessUnitID: UInt64,
        failure: VideoDecoderFailure,
        identity: VideoDecoderEventIdentity
    )
    /// The decoder has finished with one submitted access unit, whether it
    /// produced a frame, dropped it, or rejected it asynchronously.
    ///
    /// This is deliberately separate from `frame`: reordered decoders can
    /// produce zero or multiple frames for a submission, while admission needs
    /// exactly one release signal for every accepted access unit.
    case submissionCompleted(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity,
        disposition: VideoDecoderSubmissionDisposition
    )
    /// Native transition work has finished. The token lets the coordinator
    /// reject a superseded configure without reopening admission.
    case transitionCompleted(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    )
}

public protocol VideoDecoding: AnyObject {
    func prepareConfiguration(
        for accessUnit: CompressedVideoAccessUnit,
        format: CMVideoFormatDescription
    )
    func transition(_ transition: VideoDecoderTransition)
    func transitionRequirement(
        for accessUnit: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement?
    /// Hands an access unit to the decoder. Submission is asynchronous, so a
    /// failure to submit arrives as `VideoDecoderEvent.submissionFailure`
    /// rather than as a `throw`; the signature stays throwing for decoders that
    /// can reject a unit outright. Every call that returns normally must later
    /// emit exactly one matching `submissionCompleted`; a call that throws was
    /// rejected synchronously and emits no completion.
    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws
    func setTuning(_ tuning: PlaybackTuning)
}

public extension VideoDecoding {
    func prepareConfiguration(
        for _: CompressedVideoAccessUnit,
        format _: CMVideoFormatDescription
    ) {}

    func transitionRequirement(
        for _: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement? { nil }

    func setTuning(_ tuning: PlaybackTuning) {}
}
