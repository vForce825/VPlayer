// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

/// 独立 GPU 输出 backing 的共享尾。它不复用 decoder 输入费用；YADIF、bridge、
/// VT 和 writer 的最后一个实际 holder 共同持有同一实例才会触发退费。
public final class VideoOutputBackingRetentionTail: NSObject, @unchecked Sendable {
    /// 只附着在本输出 backing 上，绝不随 `CVBufferPropagateAttachments` 复制。
    /// 这样外部持有裸 `CVPixelBuffer` 时仍保留转换 reservation；frame/VT holder
    /// 只是同一实际 backing 的额外 owner，不能替代 buffer 本身的生命周期。
    nonisolated(unsafe) static let attachmentKey =
        "org.vplayer.video.output-backing-retention-tail" as CFString
    private let onRelease: @Sendable () -> Void
    private let fixedGraphRole: AnyObject?
    let conversionCredit: VideoConversionBackingCredit?

    public init(onRelease: @escaping @Sendable () -> Void, fixedGraphRole: AnyObject? = nil) {
        self.onRelease = onRelease
        self.fixedGraphRole = fixedGraphRole
        conversionCredit = nil
        super.init()
    }

    init(conversionCredit: VideoConversionBackingCredit, fixedGraphRole: AnyObject? = nil) {
        self.conversionCredit = conversionCredit
        self.fixedGraphRole = fixedGraphRole
        onRelease = { withExtendedLifetime(conversionCredit) {} }
        super.init()
    }

    deinit { onRelease() }
}

/// 一次 HLS 转换 reservation 的共享引用。输入 decoder tail 和两个 GPU 输出
/// tail 都持有它；因此三个独立 backing 可以共用同一笔 reservation，而不会在
/// input 或任一 output 提前析构时退费。
public class VideoConversionBackingCredit: @unchecked Sendable {
    private let onRelease: @Sendable () -> Void

    public init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

public struct VideoProcessingOutputFrame: @unchecked Sendable {
    public let frame: VideoPresentationFrame
    public let origin: PresentationOrigin
    public let resolvedFieldOrder: ResolvedFieldOrder?

    public init(
        frame: VideoPresentationFrame,
        origin: PresentationOrigin,
        resolvedFieldOrder: ResolvedFieldOrder?
    ) {
        self.frame = frame
        self.origin = origin
        self.resolvedFieldOrder = resolvedFieldOrder
    }
}

public struct VideoProcessingFrameBatch: @unchecked Sendable {
    public let firstOutput: VideoProcessingOutputFrame
    public let remainingOutputs: [VideoProcessingOutputFrame]

    public init(
        first: VideoPresentationFrame,
        remaining: [VideoPresentationFrame] = []
    ) {
        firstOutput = VideoProcessingOutputFrame(
            frame: first,
            origin: .raw,
            resolvedFieldOrder: nil
        )
        remainingOutputs = remaining.map {
            VideoProcessingOutputFrame(
                frame: $0,
                origin: .raw,
                resolvedFieldOrder: nil
            )
        }
    }

    public init(
        first: VideoProcessingOutputFrame,
        remaining: [VideoProcessingOutputFrame] = []
    ) {
        firstOutput = first
        remainingOutputs = remaining
    }

    public var first: VideoPresentationFrame { firstOutput.frame }
    public var remaining: [VideoPresentationFrame] { remainingOutputs.map(\.frame) }

    /// 编码分支必须消费带来源的完整批次，不能把第二场拆成独立命运。
    public var outputs: [VideoProcessingOutputFrame] {
        [firstOutput] + remainingOutputs
    }

    /// 旧 SampleBuffer 路径继续只观察展示帧，保持现有调用接口。
    public var frames: [VideoPresentationFrame] {
        outputs.map(\.frame)
    }
}

public enum VideoAtomicEncodingFieldOrderFailureReason: UInt8, Sendable, Equatable {
    case missing
    case assumed
    case conflicting
}

public struct VideoAtomicEncodingFailure: Error, Sendable, Equatable {
    public let sourceAccessUnitID: UInt64
    public let reason: VideoAtomicEncodingFieldOrderFailureReason

    public init(
        sourceAccessUnitID: UInt64,
        reason: VideoAtomicEncodingFieldOrderFailureReason
    ) {
        self.sourceAccessUnitID = sourceAccessUnitID
        self.reason = reason
    }
}

public enum VideoAtomicEncodingEvent: @unchecked Sendable {
    case batch(VideoProcessingFrameBatch)
    case failure(VideoAtomicEncodingFailure)
}

public typealias VideoAtomicEncodingSink = @Sendable (
    _ event: VideoAtomicEncodingEvent,
    _ generation: MediaGeneration
) -> Void

/// HLS 编码支路的同步准入结果。`retry` 表示接收方已持有同一原子 batch；调用者
/// 不能继续把两场拆开送往旧展示路径，也不能把它当作永久失败丢弃。
public enum VideoAtomicEncodingAdmissionResult: Sendable, Equatable {
    case accepted
    case retry
    case rejected
}

/// 与旧 sample-buffer 的 fire-and-forget sink 分开。实现者在返回 retry 前必须先
/// 为跨回调保留的 frame owner 计费，且只允许一个有界 pending batch。
protocol VideoAtomicEncodingAdmitting: AnyObject, Sendable {
    func submit(
        _ event: VideoAtomicEncodingEvent,
        generation: MediaGeneration
    ) -> VideoAtomicEncodingAdmissionResult
    func retryPending() -> VideoAtomicEncodingAdmissionResult
    func cancel()
    var hasPendingWork: Bool { get }
}
extension VideoAtomicEncodingAdmitting { var hasPendingWork: Bool { false } }

public enum VideoProcessingTransientDropReason: Sendable, Equatable {
    case queuePressure
    case resourcePressure
    case invalidTiming
}

public enum VideoProcessingStructuralFailure: Sendable, Equatable {
    case invalidSurface
    case surfacePool
    case rendererAttributes
    case textureMapping
    case shaderPipeline
    case commandExecution
}

public enum VideoProcessingCancellationReason: Sendable, Equatable {
    case staleGeneration
    case reset
    case draining
    case referenceWindowDiscard
}

public enum VideoProcessingResult: @unchecked Sendable {
    case produced(VideoProcessingFrameBatch)
    case transientDrop(VideoProcessingTransientDropReason)
    case structuralFailure(VideoProcessingStructuralFailure)
    case cancelled(VideoProcessingCancellationReason)
}

public protocol VideoFrameProcessing: AnyObject {
    var requiredInputFrameCount: Int { get }
    func reset(to generation: MediaGeneration)
    func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    )
}

public final class PassthroughVideoProcessor: VideoFrameProcessing, @unchecked Sendable {
    public let requiredInputFrameCount = 1
    private var generation = MediaGeneration(rawValue: 0)
    private var sequence: UInt64 = 0

    public init() {}

    public func reset(to generation: MediaGeneration) {
        self.generation = generation
        sequence = 0
    }

    public func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    ) {
        guard frame.generation == generation else {
            completion(.cancelled(.staleGeneration))
            return
        }
        sequence &+= 1
        completion(.produced(VideoProcessingFrameBatch(
            first: VideoPresentationFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                generation: frame.generation,
                sequenceNumber: sequence,
                sourceAccessUnitID: frame.accessUnitID,
                formatMetadata: frame.formatMetadata,
                retentionTail: frame.retentionTail
            )
        )))
    }
}
