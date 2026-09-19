// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

enum HLSVideoTranscodeBranchFailure: Error, Sendable, Equatable {
    case batchCapacityExceeded(required: Int, available: Int)
    case dataPlaneAdmissionRejected(HLSDataPlaneAdmissionPermanentRejection)
    case generationMismatch(expected: MediaGeneration, actual: MediaGeneration)
    case inputFormatChanged
    case invalidFrame(VTVideoEncoderFailure)
    case processing(VideoAtomicEncodingFailure)
    case encoder(VTVideoEncoderFailure)
    case decoder(VideoDecoderFailure)
    case cancelled
}

enum HLSVideoTranscodeBranchTerminal: Sendable, Equatable {
    case finished
    case cancelled
    case failed(HLSVideoTranscodeBranchFailure)
}

enum HLSVideoBatchAdmissionResult: Sendable, Equatable {
    case accepted
    case retry(required: Int, available: Int)
    case rejected(HLSVideoTranscodeBranchFailure)
}

typealias HLSVideoAtomicEncodingAdmissionSink = @Sendable (
    VideoAtomicEncodingEvent,
    MediaGeneration
) -> HLSVideoBatchAdmissionResult

fileprivate final class HLSVideoBatchAdmissionTail: @unchecked Sendable {
    let lease: HLSDataPlaneAdmission.Lease
    private let onRelease: @Sendable () -> Void

    init(lease: HLSDataPlaneAdmission.Lease, onRelease: @escaping @Sendable () -> Void) {
        self.lease = lease
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

/// producer 所持有的有限合并唤醒器。owner 只设置一个待消费标志并广播条件，
/// 从不在 owner/control lane 执行 producer closure 或等待 producer 队列。
final class HLSVideoInputCapacityWakeup: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = false

    func signal() {
        condition.lock()
        pending = true
        condition.broadcast()
        condition.unlock()
    }

    /// 返回一次可消费唤醒；容量状态不是此对象的 payload，producer 醒来后必须
    /// 读取 owner 的 `inputCapacityState`。
    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !pending {
            guard condition.wait(until: deadline) else { return false }
        }
        pending = false
        return true
    }
}

/// HLS decoder 的 native 输出只可在 callback/submission lane 等待此准入。
/// cancel 同步唤醒 `HLSDataPlaneAdmission`，随后才允许排 native invalidation。
final class HLSDecodedSurfaceAdmission: DecodedVideoSurfaceAdmitting, @unchecked Sendable {
    private let admission: HLSDataPlaneAdmission
    private let retirementRole: AnyObject?
    private let surfaceAllocationSize: @Sendable (IOSurface) -> Int
    private let condition = NSCondition()
    private var cancelled = false
#if DEBUG
    private var waitingScopeCountStorage = 0
    var waitingScopeCount: Int { condition.withLock { waitingScopeCountStorage } }
#endif

    init(
        admission: HLSDataPlaneAdmission,
        retirementRole: AnyObject? = nil,
        surfaceAllocationSize: @escaping @Sendable (IOSurface) -> Int = { IOSurfaceGetAllocSize($0) }
    ) {
        self.admission = admission
        self.retirementRole = retirementRole
        self.surfaceAllocationSize = surfaceAllocationSize
    }

    func admitSurface(bytes: Int) -> DecodedVideoFrameRetentionTail? {
        guard bytes >= 0 else { return nil }
        let application = bytes.addingReportingOverflow(HLSDataPlaneAdmission.applicationLeaseOverheadBytes)
        guard !application.overflow else { return nil }
        return acquire(bytes: bytes, applicationBytes: application.partialValue, scope: nil)
    }

    func admitSurface(pixelBuffer: CVPixelBuffer) -> DecodedVideoFrameRetentionTail? {
        guard let inputBytes = Self.actualBackingBytes(pixelBuffer),
              let layout = HLSYADIFOutputAllocator.Layout(source: pixelBuffer) else { return nil }
        return acquireConversion(
            inputBytes: inputBytes,
            outputBytes: layout.allocationSize,
            layout: layout,
            scope: nil
        )
    }

    func cancelSurfaceAdmission() {
        let shouldCancel = condition.withLock {
            guard !cancelled else { return false }
            cancelled = true
            condition.broadcast()
            return true
        }
        if shouldCancel { admission.cancel() }
    }

    func makeSurfaceSessionScope(
        permanentFailureSink: @escaping @Sendable () -> Void = {}
    ) -> any DecodedVideoSurfaceAdmitting {
        Scope(owner: self, permanentFailureSink: permanentFailureSink)
    }

    private func acquire(bytes: Int, applicationBytes: Int, scope: Scope?) -> DecodedVideoFrameRetentionTail? {
        condition.lock()
        while !cancelled && !(scope?.cancelled ?? false) {
            switch admission.admit(units: 1, bytes: bytes, applicationBytes: applicationBytes) {
            case let .accepted(lease):
                condition.unlock()
                return DecodedVideoFrameRetentionTail { [weak self] in
                    lease.release()
                    self?.condition.withLock { self?.condition.broadcast() }
                }
            case .temporarilyUnavailable:
#if DEBUG
                if scope != nil { waitingScopeCountStorage += 1 }
#endif
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
#if DEBUG
                if scope != nil { waitingScopeCountStorage -= 1 }
#endif
            case .cancelled:
                condition.unlock()
                return nil
            case .permanentlyRejected:
                condition.unlock()
                scope?.reportPermanentFailure()
                return nil
            }
        }
        condition.unlock()
        return nil
    }

    private func acquireConversion(
        inputBytes: Int,
        outputBytes: Int,
        layout: HLSYADIFOutputAllocator.Layout,
        scope: Scope?
    ) -> DecodedVideoFrameRetentionTail? {
        let outputs = outputBytes.multipliedReportingOverflow(by: 2)
        let payload = inputBytes.addingReportingOverflow(outputs.partialValue)
        // input/output owner（3×256）之外，预先覆盖 branch 两个 frame carrier、
        // 原子 batch carrier 和 bridge retry carrier；后续高水位转交不得补费。
        let overhead = 3 * HLSDataPlaneAdmission.applicationLeaseOverheadBytes
            + 2 * 512 + 512 + HLSDataPlaneAdmission.applicationLeaseOverheadBytes
        let application = payload.partialValue.addingReportingOverflow(overhead)
        guard !outputs.overflow, !payload.overflow, !application.overflow else {
            return nil
        }
        condition.lock()
        while !cancelled && !(scope?.cancelled ?? false) {
            // 60 是转换 batch 的既有上界，不是把同一 batch 的三块 backing 再
            // 机械拆成三槽；三份真实 byte/application 费用仍在这一 reservation 内。
            switch admission.admit(units: 1, bytes: payload.partialValue,
                                  applicationBytes: application.partialValue) {
            case let .accepted(lease):
                condition.unlock()
                guard let prepaidCapability = lease.makePrepaidCapability(
                    maximumPrepaidBytes: outputs.partialValue
                ) else {
                    lease.release()
                    return nil
                }
                let credit = HLSYADIFConversionCredit(
                    layout: layout, sourceBytes: inputBytes,
                    prepaidCapability: prepaidCapability
                ) { [weak self] in
                    lease.release()
                    self?.condition.withLock { self?.condition.broadcast() }
                }
                let outputTail = VideoOutputBackingRetentionTail(
                    conversionCredit: credit, fixedGraphRole: retirementRole
                )
                return DecodedVideoFrameRetentionTail(onRelease: {}, outputBackingTail: outputTail)
            case .temporarilyUnavailable:
#if DEBUG
                if scope != nil { waitingScopeCountStorage += 1 }
#endif
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
#if DEBUG
                if scope != nil { waitingScopeCountStorage -= 1 }
#endif
            case .cancelled:
                condition.unlock(); return nil
            case .permanentlyRejected:
                condition.unlock(); scope?.reportPermanentFailure(); return nil
            }
        }
        condition.unlock()
        return nil
    }

    fileprivate static func actualBackingBytes(_ pixelBuffer: CVPixelBuffer) -> Int? {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return nil }
        let bytes = IOSurfaceGetAllocSize(surface.takeUnretainedValue())
        return bytes > 0 ? bytes : nil
    }

    final class Scope: DecodedVideoSurfaceAdmitting, @unchecked Sendable {
        private weak var owner: HLSDecodedSurfaceAdmission?
        private let permanentFailureSink: @Sendable () -> Void
        private var permanentFailureReported = false
        fileprivate var cancelled = false
        init(
            owner: HLSDecodedSurfaceAdmission,
            permanentFailureSink: @escaping @Sendable () -> Void
        ) {
            self.owner = owner
            self.permanentFailureSink = permanentFailureSink
        }
        fileprivate func reportPermanentFailure() {
            guard let owner else { return }
            let shouldReport = owner.condition.withLock { () -> Bool in
                guard !owner.cancelled, !cancelled, !permanentFailureReported else { return false }
                permanentFailureReported = true
                return true
            }
            if shouldReport { permanentFailureSink() }
        }
        func admitSurface(bytes: Int) -> DecodedVideoFrameRetentionTail? {
            guard let owner else { return nil }
            let app = bytes.addingReportingOverflow(HLSDataPlaneAdmission.applicationLeaseOverheadBytes)
            guard !app.overflow else { return nil }
            return owner.acquire(bytes: bytes, applicationBytes: app.partialValue, scope: self)
        }
        func admitSurface(pixelBuffer: CVPixelBuffer) -> DecodedVideoFrameRetentionTail? {
            guard let inputBytes = HLSDecodedSurfaceAdmission.actualBackingBytes(pixelBuffer),
                  let layout = HLSYADIFOutputAllocator.Layout(source: pixelBuffer) else { return nil }
            return owner?.acquireConversion(inputBytes: inputBytes,
                                            outputBytes: layout.allocationSize,
                                            layout: layout, scope: self)
        }
        func cancelSurfaceAdmission() {
            guard let owner else { return }
            owner.condition.withLock { cancelled = true; owner.condition.broadcast() }
        }
        func makeSurfaceSessionScope(
            permanentFailureSink _: @escaping @Sendable () -> Void = {}
        ) -> any DecodedVideoSurfaceAdmitting { self }

    func allocateAdmittedFFmpegSurface(
        width: Int, height: Int, range: VideoFormatMetadata.Range
    ) -> (pixelBuffer: CVPixelBuffer, tail: DecodedVideoFrameRetentionTail)? {
        guard let owner else { return nil }
        guard width >= 2, height >= 2, width.isMultiple(of: 2), height.isMultiple(of: 2),
              let layout = FFmpegSurfaceLayout(width: width, height: height) else { return nil }
        let format = range == .full
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let conversionLayout = HLSYADIFOutputAllocator.Layout(
            width: width, height: height, pixelFormat: format
        ), let tail = owner.acquireConversion(
            inputBytes: layout.allocationSize,
            outputBytes: conversionLayout.allocationSize,
            layout: conversionLayout,
            scope: self
        ) else { return nil }
        let planes: [[CFString: Any]] = [
            [kIOSurfacePlaneWidth: width, kIOSurfacePlaneHeight: height,
             kIOSurfacePlaneBytesPerRow: layout.stride, kIOSurfacePlaneOffset: 0],
            [kIOSurfacePlaneWidth: width / 2, kIOSurfacePlaneHeight: height / 2,
             kIOSurfacePlaneBytesPerRow: layout.stride, kIOSurfacePlaneOffset: layout.lumaBytes],
        ]
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height,
            kIOSurfaceBytesPerRow: layout.stride, kIOSurfaceAllocSize: layout.allocationSize,
            kIOSurfacePixelFormat: format, kIOSurfacePlaneInfo: planes,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            reportPermanentFailure(); return nil
        }
        guard owner.surfaceAllocationSize(surface) <= layout.allocationSize else {
            reportPermanentFailure(); return nil
        }
        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(nil, surface, [
            kCVPixelBufferMetalCompatibilityKey as CFString: true,
        ] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            reportPermanentFailure(); return nil
        }
        let owned = pixelBuffer.takeRetainedValue()
        guard CVPixelBufferGetDataSize(owned) <= layout.allocationSize else {
            reportPermanentFailure(); return nil
        }
        return (owned, tail)
    }

    private struct FFmpegSurfaceLayout {
        let stride: Int
        let lumaBytes: Int
        let allocationSize: Int

        init?(width: Int, height: Int) {
            let rowAlignment = IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)
            let offsetAlignment = IOSurfaceGetPropertyAlignment(kIOSurfacePlaneOffset)
            guard rowAlignment > 0, offsetAlignment > 0 else { return nil }
            let strideCandidate = width.addingReportingOverflow(rowAlignment - 1)
            guard !strideCandidate.overflow else { return nil }
            stride = strideCandidate.partialValue - (strideCandidate.partialValue % rowAlignment)
            guard stride >= width else { return nil }
            let luma = stride.multipliedReportingOverflow(by: height)
            guard !luma.overflow else { return nil }
            let offsetCandidate = luma.partialValue.addingReportingOverflow(offsetAlignment - 1)
            guard !offsetCandidate.overflow else { return nil }
            let offset = offsetCandidate.partialValue - (offsetCandidate.partialValue % offsetAlignment)
            guard offset >= luma.partialValue else { return nil }
            let chroma = stride.multipliedReportingOverflow(by: height / 2)
            guard !chroma.overflow else { return nil }
            let total = offset.addingReportingOverflow(chroma.partialValue)
            guard !total.overflow else { return nil }
            lumaBytes = offset
            let allocationAlignment = IOSurfaceGetPropertyAlignment(kIOSurfaceAllocSize)
            guard allocationAlignment > 0 else { return nil }
            let allocationCandidate = total.partialValue.addingReportingOverflow(allocationAlignment - 1)
            guard !allocationCandidate.overflow else { return nil }
            allocationSize = allocationCandidate.partialValue
                - (allocationCandidate.partialValue % allocationAlignment)
        }
    }
}
}

/// 不可重复的 pair 使用权：一个 native input 只预付其对应的一个 output pair。
/// shared tail 可以跨 GPU/bridge/VT alias 存活，但不等于可以再次分配新 backing。
private final class HLSYADIFConversionCredit: VideoConversionBackingCredit, @unchecked Sendable {
    private let lock = NSLock()
    private let layout: HLSYADIFOutputAllocator.Layout
    private let sourceBytes: Int
    let prepaidCapability: HLSDataPlaneAdmission.PrepaidCapability
    private var consumed = false
    private var outputIdentities: Set<ObjectIdentifier> = []

    init(layout: HLSYADIFOutputAllocator.Layout, sourceBytes: Int,
         prepaidCapability: HLSDataPlaneAdmission.PrepaidCapability,
         onRelease: @escaping @Sendable () -> Void) {
        self.layout = layout; self.sourceBytes = sourceBytes
        self.prepaidCapability = prepaidCapability
        super.init(onRelease: onRelease)
    }

    func supportsPrepaid(ledger: HLSDeliveryApplicationChargeLedger, bytes: Int) -> Bool {
        prepaidCapability.permits(ledgerIdentity: ledger.identity, bytes: bytes)
    }

    func consume(source: CVPixelBuffer) -> HLSYADIFOutputAllocator.Layout? {
        guard let actual = HLSDecodedSurfaceAdmission.actualBackingBytes(source), actual <= sourceBytes else { return nil }
        return lock.withLock {
            guard !consumed, HLSYADIFOutputAllocator.Layout(source: source) == layout else { return nil }
            consumed = true
            return layout
        }
    }

    func bindAllocatedPair(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        let firstIdentity = ObjectIdentifier(first)
        let secondIdentity = ObjectIdentifier(second)
        guard firstIdentity != secondIdentity else { return false }
        return lock.withLock {
            guard outputIdentities.isEmpty else { return false }
            outputIdentities = [firstIdentity, secondIdentity]
            return true
        }
    }

    func ownsAllocatedPair(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        lock.withLock { outputIdentities == [ObjectIdentifier(first), ObjectIdentifier(second)] }
    }
}

/// HLS 不使用会缓存未计费 backing 的 ProgressiveSurfacePool。布局先由 source 的
/// 实际 NV12/P010 描述决定，allocation 之后逐项核实，且不传播任何费用 attachment。
final class HLSYADIFOutputAllocator: @unchecked Sendable {
    struct Layout: Sendable, Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let stride: Int
        let chromaOffset: Int
        let allocationSize: Int

        init?(source: CVPixelBuffer) {
            let description = YADIFSurfaceDescription(pixelBuffer: source)
            guard (try? YADIFSurfaceValidator.validate(description)) != nil else { return nil }
            self.init(width: description.width, height: description.height,
                      pixelFormat: description.pixelFormat)
        }

        init?(width: Int, height: Int, pixelFormat: OSType) {
            guard width >= 2, height >= 4, width.isMultiple(of: 2), height.isMultiple(of: 2) else { return nil }
            let bytesPerSample: Int
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: bytesPerSample = 1
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: bytesPerSample = 2
            default: return nil
            }
            let row = width.multipliedReportingOverflow(by: bytesPerSample)
            let rowAlignment = IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)
            let offsetAlignment = IOSurfaceGetPropertyAlignment(kIOSurfacePlaneOffset)
            let allocationAlignment = IOSurfaceGetPropertyAlignment(kIOSurfaceAllocSize)
            guard !row.overflow, rowAlignment > 0, offsetAlignment > 0, allocationAlignment > 0 else { return nil }
            let alignedRow = Self.align(row.partialValue, to: rowAlignment)
            let luma = alignedRow.multipliedReportingOverflow(by: height)
            guard !luma.overflow else { return nil }
            let offset = Self.align(luma.partialValue, to: offsetAlignment)
            let chroma = alignedRow.multipliedReportingOverflow(by: height / 2)
            guard !chroma.overflow else { return nil }
            let total = offset.addingReportingOverflow(chroma.partialValue)
            guard !total.overflow else { return nil }
            self.width = width; self.height = height
            self.pixelFormat = pixelFormat; stride = alignedRow
            chromaOffset = offset; allocationSize = Self.align(total.partialValue, to: allocationAlignment)
        }

        private static func align(_ value: Int, to alignment: Int) -> Int {
            let overflow = value.addingReportingOverflow(alignment - 1)
            guard !overflow.overflow else { return Int.max }
            return overflow.partialValue - (overflow.partialValue % alignment)
        }
    }

    private let surfaceAllocationSize: @Sendable (IOSurface) -> Int

    init(surfaceAllocationSize: @escaping @Sendable (IOSurface) -> Int = { IOSurfaceGetAllocSize($0) }) {
        self.surfaceAllocationSize = surfaceAllocationSize
    }

    func allocate(
        matching source: DecodedVideoFrame
    ) throws(YADIFFailure) -> YADIFAllocatedOutputs {
        guard let tail = source.retentionTail?.outputBackingTail,
              let credit = tail.conversionCredit as? HLSYADIFConversionCredit,
              let layout = credit.consume(source: source.pixelBuffer) else { throw .invalidPlaneLayout }
        let first = try allocate(layout: layout, matching: source.pixelBuffer, outputBackingTail: tail)
        let second = try allocate(layout: layout, matching: source.pixelBuffer, outputBackingTail: tail)
        guard credit.bindAllocatedPair(first, second) else { throw .invalidPlaneLayout }
        return .init(first: first, second: second, outputBackingTail: tail)
    }

    private func allocate(
        layout: Layout,
        matching source: CVPixelBuffer,
        outputBackingTail: VideoOutputBackingRetentionTail
    ) throws(YADIFFailure) -> CVPixelBuffer {
        let planes: [[CFString: Any]] = [
            [kIOSurfacePlaneWidth: layout.width, kIOSurfacePlaneHeight: layout.height,
             kIOSurfacePlaneBytesPerRow: layout.stride, kIOSurfacePlaneOffset: 0],
            [kIOSurfacePlaneWidth: layout.width / 2, kIOSurfacePlaneHeight: layout.height / 2,
             kIOSurfacePlaneBytesPerRow: layout.stride, kIOSurfacePlaneOffset: layout.chromaOffset],
        ]
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: layout.width, kIOSurfaceHeight: layout.height,
            kIOSurfaceBytesPerRow: layout.stride, kIOSurfaceAllocSize: layout.allocationSize,
            kIOSurfacePixelFormat: layout.pixelFormat, kIOSurfacePlaneInfo: planes,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              surfaceAllocationSize(surface) <= layout.allocationSize else { throw .invalidPlaneLayout }
        var created: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(nil, surface,
            [kCVPixelBufferMetalCompatibilityKey as CFString: true] as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw .invalidPlaneLayout }
        let output = created.takeRetainedValue()
        guard CVPixelBufferGetDataSize(output) <= layout.allocationSize,
              YADIFSurfaceDescription(pixelBuffer: output).pixelFormat == layout.pixelFormat else {
            throw .invalidPlaneLayout
        }
        try YADIFSurfaceValidator.validate(YADIFSurfaceDescription(pixelBuffer: output))
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)
        CVBufferRemoveAttachment(output, kCVImageBufferFieldCountKey)
        CVBufferRemoveAttachment(output, kCVImageBufferFieldDetailKey)
        CVBufferSetAttachment(output, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
        // credit 不是图像 metadata：不得由 source→output 或 output→其它 backing
        // 传播。但 raw output 被外部 alias 保留时，它本身必须仍强持费用尾。
        CVBufferSetAttachment(
            output,
            VideoOutputBackingRetentionTail.attachmentKey,
            outputBackingTail,
            .shouldNotPropagate
        )
        return output
    }
}

/// writer/downstream 未接纳时保留此 envelope 即保留原 batch 准入；最后 alias 释放退费。
final class HLSVideoEncodedOutputEnvelope: @unchecked Sendable {
    private let output: HLSVideoEncodedOutput
    private let admissionTail: HLSVideoBatchAdmissionTail

    fileprivate init(
        output: HLSVideoEncodedOutput,
        admissionTail: HLSVideoBatchAdmissionTail
    ) {
        self.output = output
        self.admissionTail = admissionTail
    }

    /// encoded output 只在同步借用窗内裸露；异步 writer/retry 必须同时保留本 owner。
    func withBorrowedOutput(_ body: (HLSVideoEncodedOutput) -> Void) {
        withExtendedLifetime(admissionTail) { body(output) }
    }
}

/// HomePod/AVPlayer 的隔行直播输出优先保证实时可持续性。保留完整双场仍用于
/// 测试与其它调用方；单帧模式选用每个 AU 的首张 YADIF 逐行画面，并恢复源帧时长。
enum HLSVideoTranscodeCadencePolicy: Sendable, Equatable {
    case preserveAllFields
    case firstProgressiveFramePerAccessUnit

    var outputFramesPerDecodedFrame: Int {
        switch self {
        case .preserveAllFields: 2
        case .firstProgressiveFramePerAccessUnit: 1
        }
    }

    func outputs(from batch: VideoProcessingFrameBatch) -> [VideoProcessingOutputFrame] {
        let outputs = batch.outputs
        guard self == .firstProgressiveFramePerAccessUnit,
              outputs.count == 2 else { return outputs }
        let selected = outputs[0]
        let frame = selected.frame
        let duration = CMTimeMultiply(frame.duration, multiplier: 2)
        guard duration.isNumeric, duration.epoch == 0,
              CMTimeCompare(duration, .zero) > 0 else { return outputs }
        return [VideoProcessingOutputFrame(
            frame: VideoPresentationFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: duration,
                generation: frame.generation,
                sequenceNumber: frame.sequenceNumber,
                sourceAccessUnitID: frame.sourceAccessUnitID,
                formatMetadata: frame.formatMetadata,
                retentionTail: frame.retentionTail,
                outputBackingTail: frame.outputBackingTail
            ),
            origin: selected.origin,
            resolvedFieldOrder: selected.resolvedFieldOrder
        )]
    }
}

/// HLS branch 暂时满时，YADIF 回调不能把双场 batch 丢回旧展示路径。这个 bridge
/// 在返回 `.retry` 前为所持 pixel buffer alias 建立独立 application reservation；
/// retry 成功时才交给 branch，取消/拒绝时立即释放。它只保留一个 batch，因而不能把
/// 下游堵塞扩展为无界 Metal callback 队列。
final class HLSVideoAtomicBackpressureBridge: VideoAtomicEncodingAdmitting,
    @unchecked Sendable {
    private final class PendingCharge: @unchecked Sendable {
        private let ledger: HLSDeliveryApplicationChargeLedger
        private var reservation: PlaybackApplicationChargeReservation?

        init(batch: VideoProcessingFrameBatch,
             ledger: HLSDeliveryApplicationChargeLedger) throws {
            // conversion pair 已以同一 ledger 在 native admission 预付；bridge 仅
            // 延长该 pair/frame owner，不能对相同 backing 再创建 application charge。
            let payloadBytes = try HLSVideoTranscodeBranch.rawPayloadBytes(batch.outputs)
            if let credit = HLSVideoTranscodeBranch.sharedPrepaidCredit(for: batch.outputs),
               credit.supportsPrepaid(ledger: ledger, bytes: payloadBytes) {
                self.ledger = ledger
                reservation = nil
                return
            }
            let charged = payloadBytes.addingReportingOverflow(
                HLSDataPlaneAdmission.applicationLeaseOverheadBytes
            )
            guard !charged.overflow else {
                throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
            }
            self.ledger = ledger
            reservation = try ledger.reserve(allocationIdentity: .stable(UUID()),
                                              bytes: charged.partialValue)
        }

        func release() {
            if let reservation {
                self.reservation = nil
                ledger.release(reservation)
            }
        }

        deinit { release() }
    }

    private struct Pending {
        let event: VideoAtomicEncodingEvent
        let generation: MediaGeneration
        let charge: PendingCharge
    }

    private let branch: HLSVideoTranscodeBranch
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var cancelled = false
    private var capacityWakeup: (@Sendable () -> Void)?
    private var acceptedWakeup: (@Sendable () -> Void)?
    private var capacitySignalCount = 0
    private var retryAttemptCount = 0
    private var lastRetryResult: VideoAtomicEncodingAdmissionResult?

    init(
        branch: HLSVideoTranscodeBranch,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared
    ) {
        self.branch = branch
        ledger = applicationLedger
    }

    var hasPendingBatch: Bool { lock.withLock { !pending.isEmpty } }
    var hasPendingWork: Bool { hasPendingBatch }

    /// writer/encoder 真正释放最后一个 batch alias 时调用。回调只通知拥有生产 lane
    /// 的上层；bridge 自己绝不创建每包 Task 或轮询重试。
    func installCapacityWakeup(_ wakeup: @escaping @Sendable () -> Void) {
        lock.withLock { capacityWakeup = wakeup }
    }

    func installAcceptedWakeup(_ wakeup: @escaping @Sendable () -> Void) {
        lock.withLock { acceptedWakeup = wakeup }
    }

    func signalCapacityReleased() {
        let wakeup = lock.withLock {
            capacitySignalCount += 1
            return capacityWakeup
        }
        wakeup?()
    }

    private func signalAccepted() {
        let wakeup = lock.withLock { acceptedWakeup }
        wakeup?()
    }

    func submit(
        _ event: VideoAtomicEncodingEvent,
        generation: MediaGeneration
    ) -> VideoAtomicEncodingAdmissionResult {
        #if DEBUG
        if case let .failure(failure) = event {
            PlaybackDiagnosticTracker.shared.append(
                "atomic_failure_event_\(failure.reason)_au\(failure.sourceAccessUnitID)"
            )
        }
        #endif
        let result: VideoAtomicEncodingAdmissionResult = lock.withLock {
            guard !cancelled else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("atomic_reject_cancelled")
                #endif
                return .rejected
            }
            if !pending.isEmpty {
                guard case let .batch(batch) = event else {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("atomic_reject_pending_nonbatch")
                    #endif
                    return .rejected
                }
                do {
                    pending.append(.init(event: event, generation: generation,
                                         charge: try PendingCharge(batch: batch, ledger: ledger)))
                    return .retry
                } catch {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("atomic_reject_pending_charge_\(error)")
                    #endif
                    return .rejected
                }
            }
            return submitLocked(event, generation: generation, retainOnRetry: true)
        }
        if result == .accepted { signalAccepted() }
        return result
    }

    func retryPending() -> VideoAtomicEncodingAdmissionResult {
        let result: VideoAtomicEncodingAdmissionResult = lock.withLock {
            retryAttemptCount += 1
            guard !cancelled, !pending.isEmpty else {
                lastRetryResult = .rejected
                return .rejected
            }
            while !pending.isEmpty {
                let first = pending[0]
                switch branch.receive(first.event, generation: first.generation) {
                case .accepted:
                    pending.removeFirst()
                    first.charge.release()
                case .retry:
                    lastRetryResult = .retry
                    return .retry
                case .rejected:
                    pending.removeFirst()
                    first.charge.release()
                    lastRetryResult = .rejected
                    return .rejected
                }
            }
            lastRetryResult = .accepted
            return .accepted
        }
        if result == .accepted { signalAccepted() }
        return result
    }

    var capacityStateForDiagnostics: String {
        let snapshot = lock.withLock {
            (pending.count, capacitySignalCount, retryAttemptCount, lastRetryResult)
        }
        return "pending=\(snapshot.0),signals=\(snapshot.1)," +
            "retries=\(snapshot.2),last=\(String(describing: snapshot.3))," +
            "branch={\(branch.capacityStateForDiagnostics)}"
    }

    func cancel() {
        let shouldCancel = closeAdmissionForRetirement()
        if shouldCancel { branch.cancel() }
    }

    /// 退休的第一阶段只撤销 bridge 准入及其 pending charge；encoder 的实际
    /// cancel 必须由 owner 在 decoder/YADIF barrier 后通过同一个 receipt 发起。
    @discardableResult
    func closeAdmissionForRetirement() -> Bool {
        lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            let toRelease = pending
            pending.removeAll()
            toRelease.forEach { $0.charge.release() }
            return true
        }
    }

    private func submitLocked(
        _ event: VideoAtomicEncodingEvent,
        generation: MediaGeneration,
        retainOnRetry: Bool
    ) -> VideoAtomicEncodingAdmissionResult {
        switch branch.receive(event, generation: generation) {
        case .accepted:
            return .accepted
        case let .rejected(failure):
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("atomic_reject_branch_\(failure)")
            #endif
            return .rejected
        case .retry:
            guard retainOnRetry, case let .batch(batch) = event else { return .rejected }
            do {
                pending.append(.init(event: event, generation: generation,
                                     charge: try PendingCharge(batch: batch, ledger: ledger)))
                return .retry
            } catch {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("atomic_reject_retry_charge_\(error)")
                #endif
                return .rejected
            }
        }
    }
}

/// HLS 隔行 owner 的真实输入信用。它与旧 PlaybackPipeline 使用相同的
/// “handle 成功后以 decoder identity 建账、仅 matching submissionCompleted 退账”
/// 规则，避免 VideoToolbox 自己的 backlog shedding 成为 HLS 丢 GOP 策略。
final class HLSVideoBranch: @unchecked Sendable {
    /// native output 与 coordinator FIFO 共享的单一、不可变 surface 信用边界。
    static let decodedSurfaceCreditCapacity = 60
    typealias DecoderFactory = (
        any DecodedVideoSurfaceAdmitting,
        @escaping @Sendable (VideoDecoderEvent) -> Void
    ) -> any VideoDecoding
    /// 正式 HLS 图由此 factory 在 provider 已存在后构造真实 YADIF，防止生产
    /// 调用者无意使用默认未计费 pool；`yadif` 仅兼容可控 fake 注入。
    typealias YADIFFactory = @Sendable (HLSYADIFOutputAllocator) -> any YADIFFrameProcessing
    typealias FailureSink = @Sendable (PlaybackCoreError, MediaGeneration) -> Void
    enum InputCapacityState: Sendable, Equatable {
        case available
        case temporarilyUnavailable
        case cancelled
    }
    enum SubmissionDisposition: Sendable, Equatable {
        case accepted
        case retry
        case discardedByDecoder
        case invalidInput
        case cancelled
        case identityMissing
        case bookkeepingConflict
    }
    private struct Submission: Hashable {
        let accessUnitID: UInt64
        let identity: VideoDecoderEventIdentity
    }

    /// The lane closure owns this object as well as the map.  A synchronous
    /// stop may close admission while the closure is queued, but may not return
    /// its pre-paid source lease before that closure has either handed it to
    /// native decode or conclusively declined the AU.
    private final class PendingInput: @unchecked Sendable {
        let lease: HLSDataPlaneAdmission.Lease
        init(lease: HLSDataPlaneAdmission.Lease) { self.lease = lease }
    }
    private final class RetirementContext: @unchecked Sendable {
        let owner: HLSVideoBranch
        let preparationRole: FrozenPreparationVideoRetirementRole?
        let completion: @Sendable (Bool) -> Void
        var completionDelivered = false
        init(owner: HLSVideoBranch, preparationRole: FrozenPreparationVideoRetirementRole?,
             completion: @escaping @Sendable (Bool) -> Void) {
            self.owner = owner
            self.preparationRole = preparationRole
            self.completion = completion
        }
    }

    /// 一个 EOF 只有一个 owner completion 槽；重复请求不会无限累积 waiter。
    private enum NaturalEOFState {
        case idle
        case nativeDraining(HLSVideoTranscodeBranch.FinishCompletion)
        case bridgeDraining(HLSVideoTranscodeBranch.FinishCompletion)
        case encoderFinishing(HLSVideoTranscodeBranch.FinishCompletion)
        case terminal(Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>)
    }

    private let executor: PlaybackSerialExecutor
    private let decoder: any VideoDecoding
    private let decoderRelay: HLSVideoDecoderRelay
    /// coordinator 的 closure 只弱捕获本 owner；这里必须强持 hook relay，避免
    /// 构造结束后格式换代/取消仍静默落到默认回调。
    private let coordinatorHooks: HLSVideoBranchHooks
    private let coordinator: VideoPipelineCoordinator
    private let bridge: HLSVideoAtomicBackpressureBridge
    private let transcodeBranch: HLSVideoTranscodeBranch
    private let failureSink: FailureSink
    private let inputAdmission: HLSDataPlaneAdmission
    private let decodedSurfaceAdmission: HLSDataPlaneAdmission
    private let decodedSurfaceProvider: HLSDecodedSurfaceAdmission
    /// 同一 FrozenPreparationOwner 的唯一 19KiB reservation 由该角色续命；不另收费。
    private let preparationRole: FrozenPreparationVideoRetirementRole?
    private let lock = NSLock()
    private var stopped = false
    private var admissionOpen = true
    private var generation: MediaGeneration
    /// 只在 `executor` 的格式安装任务中读写。首次 format 属于初始图安装，不能
    /// 伪造一次 generation 退休；后续真实格式变化才交给 coordinator 换代。
    private var hasInstalledFormat = false
    private var outstanding: Set<Submission> = []
    /// 只统计当前 decoder identity 实际交付的 frame；压缩 AU 的提交数不能替代它。
    private var decodedFrameCount = 0
    /// 已在 caller 线程取得的有限输入槽。只有取得槽后才可 capture AU 进 lane，
    /// 因而 executor 排队本身不能变成未计费、无界的 source owner 队列。
    private var pendingAdmissions: [UInt64: PendingInput] = [:]
    private var outstandingInputLeases: [Submission: HLSDataPlaneAdmission.Lease] = [:]
    private var naturalEOFState = NaturalEOFState.idle
    /// EOF closure 与 submit 可能来自不同 producer thread。只有已经登记到
    /// pendingAdmissions 的 AU 均由 owner lane 接管（或明确拒绝）后才能启动
    /// native drain；不能依赖两个 executor.submit 恰好按调用时间排队。
    private var naturalEOFDrainStarted = false
    /// 只有第一个 stop 可登记真实 retirement receipt；重复调用明确失败关闭，
    /// 不新增 Task 或 waiter，也不重发 native cancel。
    private var stopRetirementStarted = false
    private var retirementContext: RetirementContext?
    /// 只由 decoder→YADIF→encoder 的同一条实际 receipt 链写入；正式 bundle
    /// 在首个 stop（可能是内部 noop）后可读取它，绝不能靠 terminal snapshot 猜测。
    private var confirmedRetirementReceipt = false
    /// producer 强持 wakeup；owner 只弱注册，不能形成 owner → callback → owner 环。
    private weak var inputCapacityWakeup: HLSVideoInputCapacityWakeup?
    private let maximumOutstanding = 8

    /// 默认生产构造保留 VT 与 FFmpeg routing；实际格式由随后 replaceFormat 的
    /// track/assembler 描述驱动，绝不从 fixture 尺寸或 codec 常量猜测。
    static func makeRoutingDecoderFactory(
        executor: PlaybackSerialExecutor,
        tuning: PlaybackTuning,
        metrics: PlaybackMetrics? = nil,
        signposts: PlaybackSignposts? = nil
    ) -> DecoderFactory {
        { surfaceAdmission, eventSink in
            let relay = RoutingVideoDecoderChildRelay()
            let vt: VideoToolboxDecoder
            if let metrics, let signposts {
                vt = VideoToolboxDecoder(
                    executor: executor, tuning: tuning,
                    diagnostics: (metrics: metrics, signposts: signposts),
                    submissionPolicy: .externallyBoundedLossless,
                    surfaceAdmission: surfaceAdmission
                ) { relay.receive($0, from: .videoToolbox) }
            } else {
                vt = VideoToolboxDecoder(
                    executor: executor,
                    eventSink: { relay.receive($0, from: .videoToolbox) },
                    api: SystemVideoToolboxAPI(),
                    tuning: tuning,
                    submissionPolicy: .externallyBoundedLossless,
                    surfaceAdmission: surfaceAdmission
                )
            }
            let ffmpeg = FFmpegVideoDecoder(
                executor: executor,
                eventSink: { relay.receive($0, from: .ffmpeg) },
                surfaceAdmission: surfaceAdmission,
                metrics: metrics
            )
            let decoder = RoutingVideoDecoder(
                videoToolbox: vt,
                ffmpeg: ffmpeg,
                // 本 factory 只在两秒 probe 已确认隔行后建立。首帧直接走
                // FFmpeg，避免在首个携带隔行 picture metadata 的 IDR 才切路由，
                // 从而把仍在返回的 VT 重排尾帧隔离掉。
                initialRoute: .ffmpeg,
                eventSink: eventSink
            )
            relay.install(decoder)
            return decoder
        }
    }

    init(
        executor: PlaybackSerialExecutor,
        decoderFactory: DecoderFactory,
        passthrough: VideoFrameProcessing,
        yadif: YADIFFrameProcessing,
        yadifFactory: YADIFFactory? = nil,
        probe: (any LumaScanProbing)?,
        initialGeneration: MediaGeneration,
        transcodeBranch: HLSVideoTranscodeBranch,
        preparationRole: FrozenPreparationVideoRetirementRole? = nil,
        inputAdmission: HLSDataPlaneAdmission? = nil,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
        decoderTransitionDeadline: DispatchTimeInterval = .seconds(5),
        decoderTransitionDeadlineScheduler: VideoPipelineCoordinator.DecoderTransitionDeadlineScheduler? = nil,
        failureSink: @escaping FailureSink = { _, _ in }
    ) {
        self.executor = executor
        generation = initialGeneration
        self.failureSink = failureSink
        self.inputAdmission = inputAdmission ?? HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: applicationLedger
        )
        // decoder surface 的 60 个信用在 normalizer/reference/ready/inflight 和
        // owner FIFO 间共享；这些 holder 不是可相加的多套池。它也不是压缩输入
        // 的 8 槽或“每 AU 一帧”假设；额外 native callback 保持借用并在
        // submission lane 等待最后一个 tail 释放。
        decodedSurfaceAdmission = HLSDataPlaneAdmission(capacity: Self.decodedSurfaceCreditCapacity,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: applicationLedger)
        decodedSurfaceProvider = HLSDecodedSurfaceAdmission(
            admission: decodedSurfaceAdmission, retirementRole: preparationRole
        )
        let resolvedYADIF = yadifFactory?(HLSYADIFOutputAllocator()) ?? yadif
        let relay = HLSVideoDecoderRelay()
        decoderRelay = relay
        self.decoder = decoderFactory(decodedSurfaceProvider) { [weak relay] event in relay?.forward(event) }
        self.transcodeBranch = transcodeBranch
        self.preparationRole = preparationRole
        bridge = HLSVideoAtomicBackpressureBridge(branch: transcodeBranch, applicationLedger: applicationLedger)
        let owner = HLSVideoBranchHooks()
        coordinatorHooks = owner
        coordinator = VideoPipelineCoordinator(
            decoder: decoder, passthrough: passthrough, yadif: resolvedYADIF, probe: probe,
            initialGeneration: initialGeneration,
            decoderTransitionDeadline: decoderTransitionDeadline,
            decoderTransitionDeadlineScheduler: decoderTransitionDeadlineScheduler,
            atomicEncodingAdmission: bridge,
            // 一个 decoder submission 可以合法地产生多帧。FIFO 必须直接共享
            // native output surface 的已预费信用边界，而不是压缩 AU 的 8 槽。
            maximumHLSPendingYADIFFrames: Self.decodedSurfaceCreditCapacity,
            hooks: owner.hooks
        )
        owner.install(owner: self)
        relay.install(owner: self)
        transcodeBranch.installCapacityReleaseSink { [weak bridge] in
            bridge?.signalCapacityReleased()
        }
        bridge.installCapacityWakeup { [weak self] in
            self?.executor.submit { [weak self] in self?.retryIfPending() }
        }
        bridge.installAcceptedWakeup { [weak self] in
            self?.executor.submit { [weak self] in self?.finishNaturalEOFIfBridgeDrained() }
        }
        let transcodeGeneration = transcodeBranch.generation
        transcodeBranch.installTerminalFailureSink { [weak self] failure in
            self?.fail(
                .metalCommand("hls.atomicEncoding.branch.\(failure)"),
                transcodeGeneration
            )
        }
    }

    /// 先预占一个固定输入槽再 capture AU；completion 为 true 才表示 decoder
    /// ownership 已接管，false 表示 caller 仍保留其预费 source owner。
    func submit(_ accessUnit: CompressedVideoAccessUnit,
                completion: @escaping @Sendable (Bool) -> Void) {
        submitClassified(accessUnit) { completion($0 == .accepted) }
    }

    /// 生产媒体图需要区分“容量暂不可用”和“decoder 明确拒绝当前 AU”。二值接口
    /// 继续供既有调用者使用；只有此接口可以决定等待、推进到下一 AU 或失败闭合。
    func submitClassified(
        _ accessUnit: CompressedVideoAccessUnit,
        completion: @escaping @Sendable (SubmissionDisposition) -> Void
    ) {
        guard let sourceBacking = accessUnit.sourceBacking,
              let sourceRange = accessUnit.sourceByteRange else {
            completion(.invalidInput); return
        }
        let applicationBytes = sourceRange.length.addingReportingOverflow(
            HLSDataPlaneAdmission.applicationLeaseOverheadBytes
        )
        guard !applicationBytes.overflow else { completion(.invalidInput); return }
        guard case let .accepted(lease) = inputAdmission.admit(
            units: 1,
            bytes: sourceRange.length,
            applicationBytes: applicationBytes.partialValue
        ) else { completion(.retry); return }
        let pending = PendingInput(lease: lease)
        let reservationFailure = lock.withLock { () -> SubmissionDisposition? in
            guard !stopped else { return .cancelled }
            guard admissionOpen,
                  outstanding.count + pendingAdmissions.count < maximumOutstanding else {
                return .retry
            }
            guard !pendingAdmissions.keys.contains(accessUnit.id),
                  !outstanding.contains(where: { $0.accessUnitID == accessUnit.id }) else {
                return .bookkeepingConflict
            }
            // 同时强持 AU 的真实 immutable backing 与 admission lease；slot 不是
            // 所有权替身，最后只在 matching submissionCompleted 或 owner 终态退费。
            guard sourceBacking.identity.generation == accessUnit.generation,
                  sourceBacking.identity.accessUnitID == accessUnit.id else {
                return .invalidInput
            }
            pendingAdmissions[accessUnit.id] = pending
            return nil
        }
        guard let reservationFailure else {
            executor.submit { [weak self, pending] in
                guard let owner = self else {
                    completion(.cancelled)
                    return
                }
                let eligibilityFailure = owner.lock.withLock {
                    () -> SubmissionDisposition? in
                    guard !owner.stopped else { return .cancelled }
                    guard owner.pendingAdmissions[accessUnit.id] === pending else {
                        return .bookkeepingConflict
                    }
                    // 自然 EOF 关闭的是新 AU 准入；已经预付并排进 owner lane 的
                    // AU 仍必须交 native。其他关闭状态等待权威容量重开。
                    if owner.admissionOpen { return nil }
                    if case .nativeDraining = owner.naturalEOFState { return nil }
                    return .retry
                }
                if let eligibilityFailure {
                    owner.releasePendingInput(
                        accessUnitID: accessUnit.id, pending: pending)
                    completion(eligibilityFailure)
                    return
                }
                guard owner.coordinator.handle(accessUnit: accessUnit) else {
                    owner.releasePendingInput(
                        accessUnitID: accessUnit.id, pending: pending)
                    completion(.discardedByDecoder)
                    return
                }
                guard let identity = owner.coordinator.currentDecoderIdentity,
                      identity.generation == accessUnit.generation else {
                    owner.releasePendingInput(
                        accessUnitID: accessUnit.id, pending: pending)
                    completion(.identityMissing)
                    return
                }
                // Do not re-check `stopped` here. stop can race after handle has
                // entered native decode; that submitted AU keeps its lease until
                // the matching decoder completion, even though normal frames are ignored.
                let inserted = owner.lock.withLock {
                    guard owner.pendingAdmissions[accessUnit.id] === pending else {
                        return false
                    }
                    _ = owner.pendingAdmissions.removeValue(forKey: accessUnit.id)
                    let submission = Submission(
                        accessUnitID: accessUnit.id, identity: identity)
                    let inserted = owner.outstanding.insert(submission).inserted
                    if inserted {
                        owner.outstandingInputLeases[submission] = pending.lease
                    }
                    return inserted
                }
                completion(inserted ? .accepted : .bookkeepingConflict)
                owner.beginNaturalEOFDrainIfReady()
            }
            return
        }
        completion(reservationFailure)
    }

    private func releasePendingInput(accessUnitID: UInt64, pending: PendingInput) {
        lock.withLock {
            if pendingAdmissions[accessUnitID] === pending {
                _ = pendingAdmissions.removeValue(forKey: accessUnitID)
            }
        }
        notifyInputCapacityChange()
        beginNaturalEOFDrainIfReady()
    }

    func receiveDecoderEvent(_ event: VideoDecoderEvent) {
        executor.submit { [weak self] in
            guard let self else { return }
            if case let .submissionCompleted(accessUnitID, identity, _) = event {
                let released = self.lock.withLock { () -> Bool in
                    let submission = Submission(accessUnitID: accessUnitID, identity: identity)
                    guard self.outstanding.remove(submission) != nil else { return false }
                    _ = self.outstandingInputLeases.removeValue(forKey: submission)
                    return true
                }
                // stop/fail 后仍必须接收准确 completion 来释放 native decoder
                // 最后 alias；重复、旧 identity 不得触碰任何其他 lease。
                guard released else { return }
                self.notifyInputCapacityChange()
            }
            // stop 后 matching transition receipt 仍是退休链的唯一推进事实；由
            // coordinator 依据 pending token/generation 过滤，不能在 owner 外层吞掉。
            if case .transitionCompleted = event {
                self.coordinator.handle(decoder: event)
                return
            }
            guard !self.lock.withLock({ self.stopped }) else { return }
            if case let .frame(frame, identity) = event,
               identity == self.coordinator.currentDecoderIdentity,
               frame.generation == identity.generation {
                self.lock.withLock {
                    let next = self.decodedFrameCount.addingReportingOverflow(1)
                    self.decodedFrameCount = next.overflow ? Int.max : next.partialValue
                }
            }
            self.coordinator.handle(decoder: event)
        }
    }

    func replaceFormat(_ format: CMVideoFormatDescription,
                       streamFieldOrder: CodedFieldOrder = .unknown) {
        executor.submit { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            if self.hasInstalledFormat {
                self.coordinator.replaceFormat(format, streamFieldOrder: streamFieldOrder)
            } else {
                self.hasInstalledFormat = true
                self.coordinator.installFormatForCurrentGeneration(
                    format,
                    streamFieldOrder: streamFieldOrder
                )
            }
        }
    }

    /// 音频 branch 的真实时间线原点必须经 owner lane 交给 coordinator；不能由
    /// 测试或调用方绕开 owner 直接触碰其可变状态。
    func observeAudioTimelineOrigin(_ presentationTimeStamp: CMTime) {
        executor.submit { [weak self] in
            self?.coordinator.observeAudioTimelineOrigin(presentationTimeStamp)
        }
    }

    /// 自然 EOF 的唯一入口。它关闭新 AU，但保留已经进入 native/configuration
    /// lane 的工作，直到 native → normalizer/FIFO → YADIF → bridge → encoder
    /// finish receipt 的完整链路真实完成。
    func finishNaturally(completion: @escaping HLSVideoTranscodeBranch.FinishCompletion) {
        let begin = lock.withLock { () -> Bool in
            guard !stopped else {
                return false
            }
            guard case .idle = naturalEOFState else {
                return false
            }
            admissionOpen = false
            naturalEOFState = .nativeDraining(completion)
            naturalEOFDrainStarted = false
            return true
        }
        guard begin else {
            completion(.failure(.cancelled))
            return
        }
        notifyInputCapacityChange()
        executor.submit { [weak self] in
            self?.beginNaturalEOFDrainIfReady()
        }
    }

    /// 只在 owner lane 调用。它既是 EOF 初始 closure 的门，也是此前已预占、
    /// 但晚于 EOF closure 入队的 AU closure 完结后的推进点。
    private func beginNaturalEOFDrainIfReady() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !stopped,
                  case .nativeDraining = naturalEOFState,
                  !naturalEOFDrainStarted,
                  pendingAdmissions.isEmpty else { return false }
            naturalEOFDrainStarted = true
            return true
        }
        guard shouldStart else { return }
        coordinator.drainForNaturalEOF { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .completed:
                    self.lock.withLock {
                        guard case let .nativeDraining(completion) = self.naturalEOFState else { return }
                        self.naturalEOFState = .bridgeDraining(completion)
                    }
                    self.finishNaturalEOFIfBridgeDrained()
                case let .failed(failure):
                    self.resolveNaturalEOF(.failure(.decoder(failure)))
                }
        }
    }

    func stop(emergency: Bool) { retire(emergency: emergency) { _ in } }

    func retire(emergency: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let start = lock.withLock { () -> (RetirementContext?, HLSVideoTranscodeBranch.FinishCompletion?, Bool) in
            if confirmedRetirementReceipt { return (nil, nil, true) }
            guard !stopRetirementStarted else { return (nil, nil, false) }
            stopRetirementStarted = true
            stopped = true
            let context = RetirementContext(owner: self, preparationRole: preparationRole,
                                            completion: completion)
            retirementContext = context
            return (context, takeNaturalEOFCompletionLocked(.failure(.cancelled)), false)
        }
        guard let context = start.0 else { completion(start.2); return }
        inputAdmission.cancel()
        decodedSurfaceProvider.cancelSurfaceAdmission()
        _ = bridge.closeAdmissionForRetirement()
        start.1?(.failure(.cancelled))
        notifyInputCapacityChange()
        executor.submit {
            context.owner.coordinator.stop(emergency: emergency) { decoderAndYADIFRetired in
                // 一个成员失败不撤销其它成员的实际释放义务；最终 bool 仍 fail-closed。
                context.owner.transcodeBranch.cancel { encoderConfirmed in
                    context.owner.completeRetirement(
                        context, confirmed: decoderAndYADIFRetired && encoderConfirmed
                    )
                }
            }
        }
    }

    private func completeRetirement(_ context: RetirementContext, confirmed: Bool) {
        let completion = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            guard retirementContext === context else { return nil }
            guard !context.completionDelivered else { return nil }
            context.completionDelivered = true
            // 未确认并不等于原生控制尾已经退出；保留唯一固定 context 继续接住
            // 迟到的实际释放事实，不能借 false 把 owner/原角色提前释放。
            if confirmed {
                confirmedRetirementReceipt = true
                retirementContext = nil
            }
            return context.completion
        }
        completion?(confirmed)
    }

    private func retryIfPending() {
        guard !lock.withLock({ stopped }), bridge.hasPendingBatch else { return }
        _ = coordinator.retryPendingAtomicEncoding()
    }

    fileprivate func closeAdmission() {
        lock.withLock { admissionOpen = false }
        notifyInputCapacityChange()
    }
    fileprivate func reopenAdmission() {
        lock.withLock {
            guard !stopped, case .idle = naturalEOFState else { return }
            admissionOpen = true
        }
        notifyInputCapacityChange()
    }
    /// 下一装配批持有此对象并在自己的 producer lane 等待。信号为可合并的唤醒，
    /// 不携带容量授权；每次苏醒后仍须同锁读取 `inputCapacityState`。
    func installInputCapacityWakeup(_ wakeup: HLSVideoInputCapacityWakeup) {
        lock.withLock { inputCapacityWakeup = wakeup }
        notifyInputCapacityChange()
    }
    /// 仅供同模块诊断与 owner 生命周期测试观察；不授予任何提交能力。
    var hasOpenInputAdmission: Bool { lock.withLock { !stopped && admissionOpen } }
    /// producer 每次被唤醒都须以此同锁状态复验，不能缓存旧通知 payload。
    var inputCapacityState: InputCapacityState { lock.withLock { inputCapacityStateLocked() } }
    var decodedFrameCountForOutputWatermark: Int { lock.withLock { decodedFrameCount } }
    var capacityStateForDiagnostics: String {
        lock.withLock {
            "stopped=\(stopped),open=\(admissionOpen)," +
                "outstanding=\(outstanding.count),pending=\(pendingAdmissions.count)," +
                "availableUnits=\(inputAdmission.availableUnits)," +
                "atomic={\(bridge.capacityStateForDiagnostics)}"
        }
    }
    fileprivate func advanceGeneration() -> MediaGeneration {
        let advanced = lock.withLock {
            () -> (MediaGeneration, HLSVideoTranscodeBranch.FinishCompletion?) in
            guard generation.rawValue < UInt64.max else {
                // 不允许 generation 回绕并使迟到 callback 获得新一代身份；关闭准入，
                // 保持当前不可复用 identity，等待 owner 的终态清理。
                stopped = true
                admissionOpen = false
                return (generation, takeNaturalEOFCompletionLocked(.failure(.cancelled)))
            }
            generation = MediaGeneration(rawValue: generation.rawValue + 1)
            // generation 推进与撤销旧 EOF 完成权必须在同一把锁内完成；否则
            // encoder callback 可在两者之间抢到成功。只取出 closure，绝不在锁内
            // 执行用户 completion。
            return (generation, takeNaturalEOFCompletionLocked(.failure(.cancelled)))
        }
        advanced.1?(.failure(.cancelled))
        return advanced.0
    }
    fileprivate func rejectSubmission(_ accessUnitID: UInt64, _ identity: VideoDecoderEventIdentity) {
        lock.withLock {
            let submission = Submission(accessUnitID: accessUnitID, identity: identity)
            _ = outstanding.remove(submission)
            _ = outstandingInputLeases.removeValue(forKey: submission)
        }
        notifyInputCapacityChange()
    }
    fileprivate func fail(_ error: PlaybackCoreError, _ generation: MediaGeneration) {
        let shouldReport = lock.withLock { () -> Bool in
            guard self.generation == generation, !stopped else { return false }
            return true
        }
        guard shouldReport else { return }
        // fatal 不是 encoder 的旁路取消：它必须占用与外部 stop 相同的唯一退休
        // context，随后由 decoder transition、YADIF barrier 和 encoder receipt 确认。
        retire(emergency: false) { _ in }
        failureSink(error, generation)
    }
    fileprivate func scheduleOnOwnerLane(_ operation: @escaping @Sendable () -> Void) {
        executor.submit(operation)
    }

    private func notifyInputCapacityChange() {
        let notification = lock.withLock { () -> (HLSVideoInputCapacityWakeup?, Bool) in
            (inputCapacityWakeup, stopped)
        }
        // `signal` 只写入布尔待消费标志并广播，不能执行或等待 producer 工作。
        notification.0?.signal()
        if notification.1 {
            // terminal 信号已经送出；若期间换了新注册，不得误清除它。
            lock.withLock {
                if inputCapacityWakeup === notification.0 {
                    inputCapacityWakeup = nil
                }
            }
        }
    }

    private func inputCapacityStateLocked() -> InputCapacityState {
        let state: InputCapacityState
        if stopped {
            state = .cancelled
        } else if admissionOpen,
                  outstanding.count + pendingAdmissions.count < maximumOutstanding,
                  inputAdmission.availableUnits > 0 {
            state = .available
        } else {
            state = .temporarilyUnavailable
        }
        return state
    }

    private func transcodeFinishAfterNaturalDrain() {
        transcodeBranch.finish { [weak self] result in
            self?.resolveNaturalEOF(result)
        }
    }

    private func finishNaturalEOFIfBridgeDrained() {
        guard !bridge.hasPendingBatch else { return }
        let shouldFinish = lock.withLock { () -> Bool in
            guard !stopped, case let .bridgeDraining(completion) = naturalEOFState else {
                return false
            }
            naturalEOFState = .encoderFinishing(completion)
            return true
        }
        guard shouldFinish else { return }
        transcodeFinishAfterNaturalDrain()
    }

    private func resolveNaturalEOF(
        _ result: Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>
    ) {
        let completion = lock.withLock { takeNaturalEOFCompletionLocked(result) }
        completion?(result)
    }

    /// 调用者已持有 `lock`。终态写入和 waiter 取走必须属于同一个临界区；
    /// 外部 encoder/native callback 不得在 stop、fail 或换代的中间确认成功。
    private func takeNaturalEOFCompletionLocked(
        _ result: Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>
    ) -> HLSVideoTranscodeBranch.FinishCompletion? {
        let waiter: HLSVideoTranscodeBranch.FinishCompletion
        switch naturalEOFState {
        case let .nativeDraining(completion), let .bridgeDraining(completion),
             let .encoderFinishing(completion):
            waiter = completion
        case .idle, .terminal:
            return nil
        }
        naturalEOFState = .terminal(result)
        return waiter
    }
}

private final class HLSVideoDecoderRelay: @unchecked Sendable {
    private weak var owner: HLSVideoBranch?
    func install(owner: HLSVideoBranch) { self.owner = owner }
    func forward(_ event: VideoDecoderEvent) { owner?.receiveDecoderEvent(event) }
}

private final class HLSVideoBranchHooks: @unchecked Sendable {
    private weak var owner: HLSVideoBranch?
    func install(owner: HLSVideoBranch) { self.owner = owner }
    lazy var hooks = VideoPipelineCoordinatorHooks(
        closeAdmission: { [weak self] in self?.owner?.closeAdmission() },
        advanceGeneration: { [weak self] in self?.owner?.advanceGeneration() ?? MediaGeneration(rawValue: 0) },
        resetPlayback: { _, _, _ in }, submissionRejected: { [weak self] id, identity in self?.owner?.rejectSubmission(id, identity) },
        decoderInvalidationBegan: { _ in }, decoderInvalidationFinished: { _, _ in },
        reopenAdmission: { [weak self] in self?.owner?.reopenAdmission() }, routeDidChange: { _ in }, deliver: { _, _ in },
        fail: { [weak self] error, generation in self?.owner?.fail(error, generation) },
        // processor/decoder completion 能从任意 callback 栈到达。只把工作投回
        // owner 的单一 lane，绝不在 bridge/encoder 锁内同步重入 coordinator。
        schedule: { [weak self] operation in
            guard let owner = self?.owner else { return }
            owner.scheduleOnOwnerLane(operation)
        }
    )
}

/// 把逐个源帧产生的原子处理批次串行送入硬编码器。
///
/// YADIF 的两个场拥有同一个接纳结果：容量不足、格式变化或代际错误时整批释放；
/// 接纳后则保持批内和跨批 FIFO，并且任一时刻最多只有一个编码 callback 未决。
enum HLSVideoGapPolicy: Sendable, Equatable {
    case strict
    case fillForwardGaps(maximumSyntheticFrameCount: Int)

    struct Resolution: Sendable, Equatable {
        let syntheticFrameCount: Int
        let canonicalNextPresentationTimeStamp: CMTime
    }

    func resolve(
        previousPresentationTimeStamp: CMTime,
        previousDuration: CMTime,
        nextPresentationTimeStamp: CMTime
    ) throws -> Resolution {
        guard previousPresentationTimeStamp.isNumeric,
              previousDuration.isNumeric,
              nextPresentationTimeStamp.isNumeric,
              previousPresentationTimeStamp.epoch == 0,
              previousDuration.epoch == 0,
              nextPresentationTimeStamp.epoch == 0,
              CMTimeCompare(previousDuration, .zero) > 0 else {
            throw VTVideoEncoderFailure.invalidTime
        }
        let expected = CMTimeAdd(previousPresentationTimeStamp, previousDuration)
        guard expected.isNumeric else {
            throw VTVideoEncoderFailure.arithmeticOverflow
        }
        let comparison = CMTimeCompare(nextPresentationTimeStamp, expected)
        guard case let .fillForwardGaps(maximumSyntheticFrameCount) = self else {
            guard comparison == 0 else {
                throw comparison < 0
                    ? VTVideoEncoderFailure.nonIncreasingPresentationTimestamp
                    : VTVideoEncoderFailure.invalidTime
            }
            return Resolution(
                syntheticFrameCount: 0,
                canonicalNextPresentationTimeStamp: expected
            )
        }
        guard maximumSyntheticFrameCount > 0 else {
            throw VTVideoEncoderFailure.invalidTime
        }
        guard CMTimeCompare(nextPresentationTimeStamp, previousPresentationTimeStamp) > 0 else {
            throw VTVideoEncoderFailure.nonIncreasingPresentationTimestamp
        }
        if comparison == 0 {
            return Resolution(
                syntheticFrameCount: 0,
                canonicalNextPresentationTimeStamp: expected
            )
        }

        // 广播 MPEG-TS 的 90 kHz 时钟偶尔会在固定场率边界旁偏一个 tick。
        // HLS writer 需要严格连续的采样网格，因此把下一真实场吸附到最近的场边界；
        // 距离最近边界最多只有半个场，真正跨过的完整边界仍各自生成补帧。
        let halfDuration = CMTimeMultiplyByRatio(
            previousDuration,
            multiplier: 1,
            divisor: 2
        )
        guard halfDuration.isNumeric,
              CMTimeCompare(halfDuration, .zero) > 0 else {
            throw VTVideoEncoderFailure.invalidTime
        }
        if comparison < 0 {
            let distance = CMTimeSubtract(expected, nextPresentationTimeStamp)
            guard distance.isNumeric,
                  CMTimeCompare(distance, halfDuration) <= 0 else {
                throw VTVideoEncoderFailure.nonIncreasingPresentationTimestamp
            }
            return Resolution(
                syntheticFrameCount: 0,
                canonicalNextPresentationTimeStamp: expected
            )
        }

        var lower = expected
        for count in 1...maximumSyntheticFrameCount {
            let upper = CMTimeAdd(lower, previousDuration)
            guard upper.isNumeric else {
                throw VTVideoEncoderFailure.arithmeticOverflow
            }
            let result = CMTimeCompare(upper, nextPresentationTimeStamp)
            if result == 0 {
                return Resolution(
                    syntheticFrameCount: count,
                    canonicalNextPresentationTimeStamp: upper
                )
            }
            if result > 0 {
                let lowerDistance = CMTimeSubtract(nextPresentationTimeStamp, lower)
                let upperDistance = CMTimeSubtract(upper, nextPresentationTimeStamp)
                if CMTimeCompare(lowerDistance, upperDistance) <= 0 {
                    return Resolution(
                        syntheticFrameCount: count - 1,
                        canonicalNextPresentationTimeStamp: lower
                    )
                }
                return Resolution(
                    syntheticFrameCount: count,
                    canonicalNextPresentationTimeStamp: upper
                )
            }
            lower = upper
        }
        let distance = CMTimeSubtract(nextPresentationTimeStamp, lower)
        if distance.isNumeric, CMTimeCompare(distance, halfDuration) <= 0 {
            return Resolution(
                syntheticFrameCount: maximumSyntheticFrameCount,
                canonicalNextPresentationTimeStamp: lower
            )
        }
        throw VTVideoEncoderFailure.invalidTime
    }
}

final class HLSVideoTranscodeBranch: @unchecked Sendable {
    typealias SurfaceLeaseFactory = @Sendable (
        VideoProcessingOutputFrame
    ) -> VideoEncodingSurfaceLease
    typealias OutputSink = @Sendable (HLSVideoEncodedOutputEnvelope) -> Void
    typealias FinishCompletion = @Sendable (
        Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>
    ) -> Void

    private enum State {
        case running
        case finishing
        case cancelling
        case terminal(HLSVideoTranscodeBranchTerminal)
    }

    private struct QueuedFrame: @unchecked Sendable {
        let token: UInt64
        let frame: VideoEncodingFrame
        let admissionTail: HLSVideoBatchAdmissionTail
    }

    /// 一个真实 YADIF surface 可被顺序提交多次，但它的底层信用只能归还一次。
    /// reservoir 关闭后，最后一个实际 encoder callback 才释放原 lease。
    private final class GapFillLeaseReservoir: @unchecked Sendable {
        private let lock = NSLock()
        private var underlying: VideoEncodingSurfaceLease?
        private var outstanding = 0
        private var closed = false

        init(_ underlying: VideoEncodingSurfaceLease) {
            self.underlying = underlying
        }

        func makeLease() -> VideoEncodingSurfaceLease? {
            lock.withLock {
                guard !closed, underlying != nil else { return nil }
                outstanding += 1
                return VideoEncodingSurfaceLease { [self] in
                    releaseOne()
                }
            }
        }

        func close() {
            let release = lock.withLock { () -> VideoEncodingSurfaceLease? in
                guard !closed else { return nil }
                closed = true
                guard outstanding == 0 else { return nil }
                defer { underlying = nil }
                return underlying
            }
            release?.release()
        }

        private func releaseOne() {
            let release = lock.withLock { () -> VideoEncodingSurfaceLease? in
                guard outstanding > 0 else { return nil }
                outstanding -= 1
                guard closed, outstanding == 0 else { return nil }
                defer { underlying = nil }
                return underlying
            }
            release?.release()
        }

        deinit { close() }
    }

    private struct GapFillReference: @unchecked Sendable {
        let identity: VideoEncodingFrameIdentity
        let pixelBuffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let duration: CMTime
        let presentationOrigin: PresentationOrigin
        let reliableFieldOrder: ResolvedFieldOrder?
        let inputFormatSignature: VideoEncodingInputFormatSignature
        let admissionTail: HLSVideoBatchAdmissionTail
        let reservoir: GapFillLeaseReservoir
    }

    private final class TerminalSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HLSVideoTranscodeBranchTerminal?

        var value: HLSVideoTranscodeBranchTerminal? {
            lock.withLock { stored }
        }

        func set(_ terminal: HLSVideoTranscodeBranchTerminal) {
            lock.withLock { stored = terminal }
        }
    }

    /// 默认 lease 用独立 owner 保持 pixel buffer，直到 encoder callback 或终态回收。
    private final class PixelBufferLeaseOwner: @unchecked Sendable {
        private let lock = NSLock()
        private var pixelBuffer: CVPixelBuffer?

        init(_ pixelBuffer: CVPixelBuffer) {
            self.pixelBuffer = pixelBuffer
        }

        func release() {
            lock.withLock { pixelBuffer = nil }
        }
    }

    let generation: MediaGeneration
    let inputFormat: VideoEncodingInputFormatSignature

    private let encoder: any HLSVideoEncoding
    private let gapPolicy: HLSVideoGapPolicy
    private let cadencePolicy: HLSVideoTranscodeCadencePolicy
    private let admission: HLSDataPlaneAdmission
    private let workQueue: DispatchQueue
    private let surfaceLeaseFactory: SurfaceLeaseFactory
    private let outputSink: OutputSink
    private var capacityReleaseSink: (@Sendable () -> Void)?
    private var terminalFailureSink: (@Sendable (HLSVideoTranscodeBranchFailure) -> Void)?
    private let terminalSnapshot = TerminalSnapshot()
    private let submissionLock = NSLock()
    private var acceptsSubmissions = true

    /// 以下状态只在 workQueue 上访问。
    private var state = State.running
    private var waiting: [QueuedFrame] = []
    /// 25i 的两个场必须同时进入 VT 流水线；上层 batch admission
    /// 仍以有界 surface lease 约束总量，这里只打开一个场对的并行度。
    private static let maximumEncoderSubmissionsInFlight = 2
    private var active: [UInt64: QueuedFrame] = [:]
    private var driveIsActive = false
    private var nextToken: UInt64 = 1
    private var finishWasRequested = false
    private var finishCompletions: [FinishCompletion] = []
    private var finishReceipt: HLSVideoEncoderFinishReceipt?
    private var frozenHardwareProof: VTHardwareEncoderProof?
    private var publishedFrameCount: UInt64 = 0
    private var gapFillReference: GapFillReference?
    private var encoderCancellationWasRequested = false
    /// 只由 encoder 的 cancel completion 写入；terminal 枚举本身不能替代该事实。
    private var encoderRetirementReceipt: Bool?
    /// failure 已先发起 encoder cancel 时，owner 仍可消费同一实际回执。这里只允许
    /// 一个退休请求等待，避免把重复 stop 变成无界 callback 队列。
    private var encoderRetirementWaiter: (@Sendable (Bool) -> Void)?

    convenience init(
        generation: MediaGeneration,
        inputFormat: VideoEncodingInputFormatSignature,
        maximumPendingFrameCount: Int,
        gapPolicy: HLSVideoGapPolicy = .strict,
        cadencePolicy: HLSVideoTranscodeCadencePolicy = .preserveAllFields,
        admission: HLSDataPlaneAdmission? = nil,
        encoder: any HLSVideoEncoding,
        outputSink: @escaping OutputSink
    ) {
        self.init(
            generation: generation,
            inputFormat: inputFormat,
            maximumPendingFrameCount: maximumPendingFrameCount,
            gapPolicy: gapPolicy,
            cadencePolicy: cadencePolicy,
            admission: admission,
            encoder: encoder,
            workQueue: DispatchQueue(
                label: "org.vplayer.playback.hls.video-transcode-branch",
                qos: .userInitiated
            ),
            surfaceLeaseFactory: { output in
                let owner = PixelBufferLeaseOwner(output.frame.pixelBuffer)
                return VideoEncodingSurfaceLease { owner.release() }
            },
            outputSink: outputSink
        )
    }

    init(
        generation: MediaGeneration,
        inputFormat: VideoEncodingInputFormatSignature,
        maximumPendingFrameCount: Int,
        gapPolicy: HLSVideoGapPolicy = .strict,
        cadencePolicy: HLSVideoTranscodeCadencePolicy = .preserveAllFields,
        admission: HLSDataPlaneAdmission? = nil,
        encoder: any HLSVideoEncoding,
        workQueue: DispatchQueue,
        surfaceLeaseFactory: @escaping SurfaceLeaseFactory,
        outputSink: @escaping OutputSink
    ) {
        self.generation = generation
        self.inputFormat = inputFormat
        self.gapPolicy = gapPolicy
        self.cadencePolicy = cadencePolicy
        self.admission = admission ?? HLSDataPlaneAdmission(
            capacity: max(0, maximumPendingFrameCount),
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
        )
        self.encoder = encoder
        self.workQueue = workQueue
        self.surfaceLeaseFactory = surfaceLeaseFactory
        self.outputSink = outputSink
    }

    var terminal: HLSVideoTranscodeBranchTerminal? {
        terminalSnapshot.value
    }

    var capacityStateForDiagnostics: String {
        let accepting = submissionLock.withLock { acceptsSubmissions }
        return "accepts=\(accepting),availableUnits=\(admission.availableUnits)," +
            "terminal=\(String(describing: terminalSnapshot.value))"
    }

    /// 由同一 HLS graph 的 bridge 安装；不是测试时钟，且只在 admission tail
    /// 的最后一个实际 owner 释放后触发。
    func installCapacityReleaseSink(_ sink: @escaping @Sendable () -> Void) {
        submissionLock.withLock { capacityReleaseSink = sink }
    }

    /// encoder/work queue 的首个真实失败必须主动通知 owner；不能等待下一批输入
    /// 碰巧到达后，再把已经关闭的 admission 误报成新的 submit 失败。
    func installTerminalFailureSink(
        _ sink: @escaping @Sendable (HLSVideoTranscodeBranchFailure) -> Void
    ) {
        submissionLock.withLock { terminalFailureSink = sink }
    }

    /// 正式 bundle 使用此返回值保留原 batch 并在 `.retry` 后重试；
    /// 不能接到丢弃返回值的旧 `VideoAtomicEncodingSink`。
    var admittedAtomicEncodingSink: HLSVideoAtomicEncodingAdmissionSink {
        { [weak self] event, generation in
            self?.receive(event, generation: generation) ?? .rejected(.cancelled)
        }
    }

    @discardableResult
    func receive(
        _ event: VideoAtomicEncodingEvent,
        generation eventGeneration: MediaGeneration
    ) -> HLSVideoBatchAdmissionResult {
        submissionLock.withLock {
            guard acceptsSubmissions else { return .rejected(.cancelled) }
            guard eventGeneration == generation else {
                return .rejected(.generationMismatch(
                    expected: generation,
                    actual: eventGeneration
                ))
            }
            switch event {
            case let .failure(failure):
                acceptsSubmissions = false
                workQueue.async { [self] in failIsolated(.processing(failure)) }
                return .accepted
            case let .batch(batch):
                do {
                    try preflight(batch.outputs)
                    let measured = try measureAdmission(batch.outputs)
                    let result: HLSDataPlaneAdmissionResult
                    if let prepaid = Self.sharedPrepaidCredit(for: batch.outputs) {
                        result = admission.admitPrepaid(
                            units: batch.outputs.count, bytes: measured.payloadBytes,
                            capability: prepaid.prepaidCapability
                        )
                    } else {
                        result = admission.admit(
                            units: batch.outputs.count, bytes: measured.payloadBytes,
                            applicationBytes: measured.applicationBytes
                        )
                    }
                    switch result {
                    case let .accepted(lease):
                        let tail = HLSVideoBatchAdmissionTail(lease: lease) { [weak self] in
                            let sink = self?.submissionLock.withLock { self?.capacityReleaseSink }
                            sink?()
                        }
                        workQueue.async { [self] in
                            receiveIsolated(event, generation: eventGeneration, admissionTail: tail)
                        }
                        return .accepted
                    case let .temporarilyUnavailable(required, available):
                        return .retry(
                            required: required,
                            available: available
                        )
                    case .cancelled:
                        acceptsSubmissions = false
                        workQueue.async { [self] in cancelIsolated() }
                        return .rejected(.cancelled)
                    case let .permanentlyRejected(rejection):
                        let failure: HLSVideoTranscodeBranchFailure
                        if case let .invalidUnits(required, capacity) = rejection {
                            failure = .batchCapacityExceeded(
                                required: required,
                                available: capacity
                            )
                        } else {
                            failure = .dataPlaneAdmissionRejected(rejection)
                        }
                        acceptsSubmissions = false
                        workQueue.async { [self] in failIsolated(failure) }
                        return .rejected(failure)
                    }
                } catch let failure as HLSVideoTranscodeBranchFailure {
                    acceptsSubmissions = false
                    workQueue.async { [self] in failIsolated(failure) }
                    return .rejected(failure)
                } catch {
                    let failure = HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
                    acceptsSubmissions = false
                    workQueue.async { [self] in failIsolated(failure) }
                    return .rejected(failure)
                }
            }
        }
    }

    func finish(completion: @escaping FinishCompletion) {
        submissionLock.withLock { acceptsSubmissions = false }
        workQueue.async { [self] in
            switch state {
            case .running:
                closeGapFillReferenceIsolated()
                state = .finishing
                finishCompletions.append(completion)
                driveIsolated()
            case .finishing:
                finishCompletions.append(completion)
            case .cancelling:
                completion(.failure(.cancelled))
            case .terminal(.finished):
                if let finishReceipt {
                    completion(.success(finishReceipt))
                } else {
                    completion(.failure(.encoder(.noEncodedOutput)))
                }
            case .terminal(.cancelled):
                completion(.failure(.cancelled))
            case let .terminal(.failed(failure)):
                completion(.failure(failure))
            }
        }
    }

    func cancel(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        submissionLock.withLock { acceptsSubmissions = false }
        admission.cancel()
        workQueue.async { [self] in
            cancelIsolated(completion: completion)
        }
    }

    private func receiveIsolated(
        _ event: VideoAtomicEncodingEvent,
        generation eventGeneration: MediaGeneration,
        admissionTail: HLSVideoBatchAdmissionTail
    ) {
        guard eventGeneration == generation else {
            return
        }
        guard case .running = state else {
            return
        }

        switch event {
        case let .failure(failure):
            failIsolated(.processing(failure))
        case let .batch(batch):
            admitIsolated(batch, admissionTail: admissionTail)
        }
    }

    private func admitIsolated(
        _ batch: VideoProcessingFrameBatch,
        admissionTail: HLSVideoBatchAdmissionTail
    ) {
        let outputs = cadencePolicy.outputs(from: batch)
        do {
            try preflight(outputs)
        } catch let failure as HLSVideoTranscodeBranchFailure {
            failIsolated(failure)
            return
        } catch {
            failIsolated(.invalidFrame(.invalidPixelBuffer))
            return
        }

        var timingAdjustment = CMTime.zero
        do {
            if let first = outputs.first {
                if let gapFrames = try makeGapFillFramesIsolated(before: first) {
                    timingAdjustment = gapFrames.timingAdjustment
                    if !gapFrames.frames.isEmpty {
                        try enqueueIsolated(
                            gapFrames.frames,
                            admissionTail: gapFrames.admissionTail)
                    }
                }
            }
        } catch let failure as VTVideoEncoderFailure {
            failIsolated(.invalidFrame(failure))
            return
        } catch {
            failIsolated(.invalidFrame(.arithmeticOverflow))
            return
        }

        // 所有不产生 owner 的预检已经通过，编码 lease 从原子接纳成功点开始。
        let leases = outputs.map(surfaceLeaseFactory)
        let prepared: [VideoEncodingFrame]
        var nextGapFillReference: GapFillReference?
        do {
            prepared = try zip(outputs, leases).enumerated().map { index, pair in
                let (output, lease) = pair
                let frame = output.frame
                let adjustedPresentationTimeStamp = CMTimeAdd(
                    frame.presentationTimeStamp,
                    timingAdjustment
                )
                guard adjustedPresentationTimeStamp.isNumeric else {
                    throw VTVideoEncoderFailure.arithmeticOverflow
                }
                materializeMissingFrozenFormatAttachments(on: frame.pixelBuffer)
                // VideoEncodingFrame 是 VT native input 的最后一个明确 holder。
                // 不依赖 presentation struct 存活，也不把 credit 作为 HDR
                // attachment 传播给其它 backing。
                let outputBackingTail = frame.outputBackingTail
                let retainedSurfaceLease = VideoEncodingSurfaceLease {
                    lease.release()
                    withExtendedLifetime(admissionTail) {}
                    withExtendedLifetime(outputBackingTail) {}
                }
                let identity = VideoEncodingFrameIdentity(
                    generation: frame.generation,
                    accessUnitID: frame.sourceAccessUnitID,
                    sequenceNumber: frame.sequenceNumber
                )
                let encodingLease: VideoEncodingSurfaceLease
                if index == outputs.count - 1,
                   case .fillForwardGaps = gapPolicy {
                    let reservoir = GapFillLeaseReservoir(retainedSurfaceLease)
                    guard let lease = reservoir.makeLease() else {
                        throw VTVideoEncoderFailure.invalidTime
                    }
                    encodingLease = lease
                    nextGapFillReference = GapFillReference(
                        identity: identity,
                        pixelBuffer: frame.pixelBuffer,
                        presentationTimeStamp: adjustedPresentationTimeStamp,
                        duration: frame.duration,
                        presentationOrigin: output.origin,
                        reliableFieldOrder: output.resolvedFieldOrder,
                        inputFormatSignature: inputFormat,
                        admissionTail: admissionTail,
                        reservoir: reservoir
                    )
                } else {
                    encodingLease = retainedSurfaceLease
                }
                return try VideoEncodingFrame(
                    identity: identity,
                    pixelBuffer: frame.pixelBuffer,
                    surfaceLease: encodingLease,
                    presentationTimeStamp: adjustedPresentationTimeStamp,
                    duration: frame.duration,
                    presentationOrigin: output.origin,
                    reliableFieldOrder: output.resolvedFieldOrder,
                    inputFormatSignature: inputFormat
                )
            }
        } catch let failure as VTVideoEncoderFailure {
            nextGapFillReference?.reservoir.close()
            for lease in leases { lease.release() }
            failIsolated(.invalidFrame(failure))
            return
        } catch {
            nextGapFillReference?.reservoir.close()
            for lease in leases { lease.release() }
            failIsolated(.invalidFrame(.invalidPixelBuffer))
            return
        }

        do {
            try enqueueIsolated(prepared, admissionTail: admissionTail)
        } catch let failure as VTVideoEncoderFailure {
            nextGapFillReference?.reservoir.close()
            failIsolated(.invalidFrame(failure))
            return
        } catch {
            nextGapFillReference?.reservoir.close()
            failIsolated(.invalidFrame(.arithmeticOverflow))
            return
        }
        gapFillReference = nextGapFillReference
        driveIsolated()
    }

    private func makeGapFillFramesIsolated(
        before next: VideoProcessingOutputFrame
    ) throws -> (
        frames: [VideoEncodingFrame],
        admissionTail: HLSVideoBatchAdmissionTail,
        timingAdjustment: CMTime
    )? {
        guard let reference = gapFillReference else {
            return nil
        }
        gapFillReference = nil
        defer { reference.reservoir.close() }
        guard case .metalYADIF = reference.presentationOrigin,
              case .metalYADIF = next.origin else {
            throw VTVideoEncoderFailure.invalidTime
        }
        let resolution = try gapPolicy.resolve(
            previousPresentationTimeStamp: reference.presentationTimeStamp,
            previousDuration: reference.duration,
            nextPresentationTimeStamp: next.frame.presentationTimeStamp
        )
        let timingAdjustment = CMTimeSubtract(
            resolution.canonicalNextPresentationTimeStamp,
            next.frame.presentationTimeStamp
        )
        guard timingAdjustment.isNumeric else {
            throw VTVideoEncoderFailure.arithmeticOverflow
        }
        if CMTimeCompare(timingAdjustment, .zero) != 0 {
            PlaybackDiagnosticTracker.shared.append(
                "video_gap_snap_us_\(Int64((CMTimeGetSeconds(timingAdjustment) * 1_000_000).rounded()))"
            )
        }
        let count = resolution.syntheticFrameCount
        guard count > 0 else {
            return ([], reference.admissionTail, timingAdjustment)
        }
        guard count <= Int(UInt32.max) else {
            throw VTVideoEncoderFailure.arithmeticOverflow
        }
        var frames: [VideoEncodingFrame] = []
        frames.reserveCapacity(count)
        var presentationTimeStamp = CMTimeAdd(
            reference.presentationTimeStamp,
            reference.duration
        )
        for ordinal in 1...count {
            guard let surfaceLease = reference.reservoir.makeLease() else {
                throw VTVideoEncoderFailure.invalidTime
            }
            frames.append(try VideoEncodingFrame(
                identity: VideoEncodingFrameIdentity(
                    generation: reference.identity.generation,
                    accessUnitID: reference.identity.accessUnitID,
                    sequenceNumber: reference.identity.sequenceNumber,
                    gapFillOrdinal: UInt32(ordinal)
                ),
                pixelBuffer: reference.pixelBuffer,
                surfaceLease: surfaceLease,
                presentationTimeStamp: presentationTimeStamp,
                duration: reference.duration,
                presentationOrigin: reference.presentationOrigin,
                reliableFieldOrder: reference.reliableFieldOrder,
                inputFormatSignature: reference.inputFormatSignature
            ))
            presentationTimeStamp = CMTimeAdd(
                presentationTimeStamp,
                reference.duration
            )
        }
        return (frames, reference.admissionTail, timingAdjustment)
    }

    private func enqueueIsolated(
        _ frames: [VideoEncodingFrame],
        admissionTail: HLSVideoBatchAdmissionTail
    ) throws {
        guard let tokenCount = UInt64(exactly: frames.count) else {
            throw VTVideoEncoderFailure.arithmeticOverflow
        }
        let nextFreeToken = nextToken.addingReportingOverflow(tokenCount)
        guard !nextFreeToken.overflow else {
            throw VTVideoEncoderFailure.arithmeticOverflow
        }
        var token = nextToken
        for frame in frames {
            waiting.append(QueuedFrame(
                token: token,
                frame: frame,
                admissionTail: admissionTail
            ))
            token += 1
        }
        nextToken = nextFreeToken.partialValue
    }

    private func driveIsolated() {
        guard !driveIsActive else { return }
        driveIsActive = true
        defer { driveIsActive = false }

        while active.count < Self.maximumEncoderSubmissionsInFlight,
              !waiting.isEmpty {
            let queued = waiting.removeFirst()
            // completion 只捕获纯标量 token。若跨队列 closure 捕获整个 queued，
            // 失败时同一场对的 admission tail 会一直活到迟到 callback 被消费。
            let token = queued.token
            active[token] = queued
            encoder.encode(frame: queued.frame) { [weak self] result in
                guard let self else { return }
                workQueue.async { [weak self] in
                    self?.handleEncoderResultIsolated(result, token: token)
                }
            }
        }
        guard case .finishing = state, waiting.isEmpty, active.isEmpty,
              !finishWasRequested else { return }
        finishWasRequested = true
        encoder.finish { [weak self] result in
            guard let self else { return }
            workQueue.async { [weak self] in
                self?.handleFinishIsolated(result)
            }
        }
    }

    private func handleEncoderResultIsolated(
        _ result: Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>,
        token: UInt64
    ) {
        guard let active = active.removeValue(forKey: token),
              active.token == token else {
            // 已退休 generation、重复或迟到 callback 没有发布权。
            return
        }
        if case .terminal = state { return }
        switch result {
        case let .failure(failure):
            failIsolated(.encoder(failure))
        case let .success(output):
            guard output.sourceIdentity == active.frame.identity,
                  output.sourceIdentity.generation == generation,
                  output.hardwareProof.generation == generation,
                  output.inputFormatSignature == inputFormat,
                  output.presentationOrigin == active.frame.presentationOrigin else {
                failIsolated(.encoder(.unexpectedOutputFormat))
                return
            }
            if let frozenHardwareProof {
                guard output.hardwareProof == frozenHardwareProof else {
                    failIsolated(.encoder(.unexpectedOutputFormat))
                    return
                }
            } else {
                guard output.hardwareProof.firstOutputIdentity == active.frame.identity else {
                    failIsolated(.encoder(.unexpectedOutputFormat))
                    return
                }
                frozenHardwareProof = output.hardwareProof
            }
            let nextPublishedCount = publishedFrameCount.addingReportingOverflow(1)
            guard !nextPublishedCount.overflow else {
                failIsolated(.encoder(.arithmeticOverflow))
                return
            }
            publishedFrameCount = nextPublishedCount.partialValue
            outputSink(HLSVideoEncodedOutputEnvelope(
                output: output,
                admissionTail: active.admissionTail
            ))
            driveIsolated()
        }
    }

    private func handleFinishIsolated(
        _ result: Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
    ) {
        guard case .finishing = state else { return }
        switch result {
        case let .failure(failure):
            failIsolated(.encoder(failure))
        case let .success(receipt):
            guard receipt.generation == generation,
                  receipt.encodedFrameCount == publishedFrameCount,
                  let frozenHardwareProof,
                  receipt.hardwareProof == frozenHardwareProof else {
                failIsolated(.encoder(.unexpectedOutputFormat))
                return
            }
            finishReceipt = receipt
            state = .terminal(.finished)
            terminalSnapshot.set(.finished)
            let completions = finishCompletions
            finishCompletions.removeAll(keepingCapacity: false)
            for completion in completions { completion(.success(receipt)) }
        }
    }

    private func cancelIsolated(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        switch state {
        case .terminal(.finished):
            // EOF finish 已由 encoder 的真实 native lane invalidate；向 encoder
            // 查询其保存的实际事实，不重新发 invalidate。
            encoder.cancel(completion: completion)
            return
        case .terminal(.cancelled):
            // 本分支只在 encoder cancel receipt 为 true 后写入 cancelled。
            completion(true)
            return
        case .terminal(.failed):
            if let encoderRetirementReceipt {
                completion(encoderRetirementReceipt)
            } else if encoderRetirementWaiter == nil {
                encoderRetirementWaiter = completion
            } else {
                // 同一实际 cancel 已在飞行；第二个等待申请不能取代原 owner。
                completion(false)
            }
            return
        case .cancelling:
            // 重复请求不能把尚未收到的 native receipt 洗成成功，也不再发 cancel。
            completion(false)
            return
        case .running, .finishing:
            break
        }
        active.removeAll(keepingCapacity: false)
        closeGapFillReferenceIsolated()
        releaseWaitingIsolated()
            // branch 不能先把 cancelled 快照当作 encoder 已退役；等编码器真实
            // native receipt 后才发布终态并释放唯一 finish waiter。
            state = .cancelling
            encoder.cancel { [weak self] confirmed in
                self?.workQueue.async { [weak self] in
                    guard let self, case .cancelling = self.state else { return }
                    self.encoderRetirementReceipt = confirmed
                    guard confirmed else { completion(false); return }
                    self.state = .terminal(.cancelled)
                    self.terminalSnapshot.set(.cancelled)
                    let completions = self.finishCompletions
                    self.finishCompletions.removeAll(keepingCapacity: false)
                    for waiter in completions { waiter(.failure(.cancelled)) }
                    completion(true)
                }
            }
        return
    }

    private func failIsolated(_ failure: HLSVideoTranscodeBranchFailure) {
        guard case .terminal = state else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append("atomic_branch_failed_\(failure)")
            #endif
            let failureSink = submissionLock.withLock {
                acceptsSubmissions = false
                return terminalFailureSink
            }
            active.removeAll(keepingCapacity: false)
            closeGapFillReferenceIsolated()
            releaseWaitingIsolated()
            state = .terminal(.failed(failure))
            terminalSnapshot.set(.failed(failure))
            cancelEncoderOnceIsolated()
            let completions = finishCompletions
            finishCompletions.removeAll(keepingCapacity: false)
            for completion in completions { completion(.failure(failure)) }
            failureSink?(failure)
            return
        }
    }

    private func cancelEncoderOnceIsolated() {
        guard !encoderCancellationWasRequested else { return }
        encoderCancellationWasRequested = true
        encoder.cancel { [weak self] confirmed in
            self?.workQueue.async { [weak self] in
                guard let self else { return }
                self.encoderRetirementReceipt = confirmed
                let waiter = self.encoderRetirementWaiter
                self.encoderRetirementWaiter = nil
                waiter?(confirmed)
            }
        }
    }

    private func releaseWaitingIsolated() {
        let waiting = waiting
        self.waiting.removeAll(keepingCapacity: false)
        for queued in waiting { queued.frame.surfaceLease.release() }
    }

    private func closeGapFillReferenceIsolated() {
        let reference = gapFillReference
        gapFillReference = nil
        reference?.reservoir.close()
    }

    private func formatMatches(_ frame: VideoPresentationFrame) -> Bool {
        let metadata = frame.formatMetadata
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == inputFormat.pixelFormat,
              CVPixelBufferGetWidth(frame.pixelBuffer) == Int(inputFormat.width),
              CVPixelBufferGetHeight(frame.pixelBuffer) == Int(inputFormat.height),
              metadata.dimensions.width == inputFormat.width,
              metadata.dimensions.height == inputFormat.height,
              metadata.bitDepth == Int(inputFormat.bitDepth),
              metadata.range == inputFormat.range,
              metadata.primaries == inputFormat.primaries || metadata.primaries == .unknown,
              metadata.transfer == inputFormat.transfer || metadata.transfer == .unknown,
              metadata.matrix == inputFormat.matrix || metadata.matrix == .unknown,
              optionalEvidence(metadata.chromaLocation.topField,
                               matches: inputFormat.chromaLocation.topField),
              optionalEvidence(metadata.chromaLocation.bottomField,
                               matches: inputFormat.chromaLocation.bottomField),
              optionalEvidence(metadata.sampleAspectRatio,
                               matches: inputFormat.sampleAspectRatio),
              optionalEvidence(metadata.hdrStaticMetadata.masteringDisplayColorVolume,
                               matches: inputFormat.masteringDisplayColorVolume),
              optionalEvidence(metadata.hdrStaticMetadata.contentLightLevelInfo,
                               matches: inputFormat.contentLightLevelInfo) else {
            return false
        }
        return cleanApertureMatches(metadata.cleanAperture)
    }

    /// 解码器和 Metal 输出可以合法缺少颜色附件，但 VT 编码器的输入边界必须是
    /// 完整、不可变的冻结格式。这里只补空缺，不覆盖任何已有值；已有矛盾值仍由
    /// `preflight`／VT 的严格校验 fail-closed。
    private func materializeMissingFrozenFormatAttachments(on pixelBuffer: CVPixelBuffer) {
        setAttachmentIfMissing(
            kCVImageBufferColorPrimariesKey,
            value: inputFormat.primaries.vtValue as CFString,
            on: pixelBuffer
        )
        setAttachmentIfMissing(
            kCVImageBufferTransferFunctionKey,
            value: inputFormat.transfer.vtValue as CFString,
            on: pixelBuffer
        )
        setAttachmentIfMissing(
            kCVImageBufferYCbCrMatrixKey,
            value: inputFormat.matrix.vtValue as CFString,
            on: pixelBuffer
        )
        if let top = inputFormat.chromaLocation.topField {
            setAttachmentIfMissing(
                kCVImageBufferChromaLocationTopFieldKey,
                value: top as CFString,
                on: pixelBuffer
            )
        }
        if let bottom = inputFormat.chromaLocation.bottomField {
            setAttachmentIfMissing(
                kCVImageBufferChromaLocationBottomFieldKey,
                value: bottom as CFString,
                on: pixelBuffer
            )
        }
        if let aspect = inputFormat.sampleAspectRatio {
            let value = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: NSNumber(
                    value: aspect.num
                ),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: NSNumber(
                    value: aspect.den
                ),
            ] as CFDictionary
            setAttachmentIfMissing(kCVImageBufferPixelAspectRatioKey, value: value, on: pixelBuffer)
        }
        if let aperture = inputFormat.cleanAperture {
            let value = [
                kCMFormatDescriptionKey_CleanApertureWidthRational as String: [
                    NSNumber(value: aperture.width.num), NSNumber(value: aperture.width.den),
                ],
                kCMFormatDescriptionKey_CleanApertureHeightRational as String: [
                    NSNumber(value: aperture.height.num), NSNumber(value: aperture.height.den),
                ],
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational as String: [
                    NSNumber(value: aperture.horizontalOffset.num),
                    NSNumber(value: aperture.horizontalOffset.den),
                ],
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational as String: [
                    NSNumber(value: aperture.verticalOffset.num),
                    NSNumber(value: aperture.verticalOffset.den),
                ],
            ] as CFDictionary
            setAttachmentIfMissing(kCVImageBufferCleanApertureKey, value: value, on: pixelBuffer)
        }
        if let mastering = inputFormat.masteringDisplayColorVolume {
            setAttachmentIfMissing(
                kCVImageBufferMasteringDisplayColorVolumeKey,
                value: mastering as CFData,
                on: pixelBuffer
            )
        }
        if let light = inputFormat.contentLightLevelInfo {
            setAttachmentIfMissing(
                kCVImageBufferContentLightLevelInfoKey,
                value: light as CFData,
                on: pixelBuffer
            )
        }
    }

    private func setAttachmentIfMissing(
        _ key: CFString,
        value: CFTypeRef,
        on pixelBuffer: CVPixelBuffer
    ) {
        guard CVBufferCopyAttachment(pixelBuffer, key, nil) == nil else { return }
        CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
    }

    private func optionalEvidence<Value: Equatable>(
        _ observed: Value?, matches expected: Value?
    ) -> Bool {
        observed == nil || observed == expected
    }

    private func cleanApertureMatches(_ rect: CGRect?) -> Bool {
        switch (inputFormat.cleanAperture, rect) {
        case (nil, nil):
            true
        case let (signature?, rect?):
            rational(signature.width, equals: rect.width)
                && rational(signature.height, equals: rect.height)
                && signedRational(
                    signature.horizontalOffset,
                    equals: rect.midX - CGFloat(inputFormat.width) / 2
                )
                && signedRational(
                    signature.verticalOffset,
                    equals: rect.midY - CGFloat(inputFormat.height) / 2
                )
        case (_?, nil):
            true
        case (nil, _?):
            false
        }
    }

    private func rational(_ value: MediaRational, equals scalar: CGFloat) -> Bool {
        CGFloat(value.num) / CGFloat(value.den) == scalar
    }

    private func signedRational(
        _ value: SignedMediaRational,
        equals scalar: CGFloat
    ) -> Bool {
        CGFloat(value.num) / CGFloat(value.den) == scalar
    }

    private func preflight(_ outputs: [VideoProcessingOutputFrame]) throws {
        for output in outputs {
            let frame = output.frame
            guard frame.generation == generation else {
                throw HLSVideoTranscodeBranchFailure.generationMismatch(
                    expected: generation,
                    actual: frame.generation
                )
            }
            guard formatMatches(frame) else {
                throw HLSVideoTranscodeBranchFailure.inputFormatChanged
            }
            guard frame.presentationTimeStamp.isNumeric,
                  frame.presentationTimeStamp.epoch == 0,
                  frame.duration.isNumeric,
                  frame.duration.epoch == 0,
                  CMTimeCompare(frame.duration, .zero) > 0 else {
                throw HLSVideoTranscodeBranchFailure.invalidFrame(.invalidTime)
            }
        }
    }

    private func measureAdmission(
        _ outputs: [VideoProcessingOutputFrame]
    ) throws -> (payloadBytes: Int, applicationBytes: Int) {
        let payloadBytes = try Self.rawPayloadBytes(outputs)
        let frameOverhead = outputs.count.multipliedReportingOverflow(by: 512)
        guard !frameOverhead.overflow else {
            throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
        }
        let withFrames = payloadBytes.addingReportingOverflow(frameOverhead.partialValue)
        let withBatch = withFrames.partialValue.addingReportingOverflow(512)
        guard !withFrames.overflow, !withBatch.overflow else {
            throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
        }
        return (payloadBytes, withBatch.partialValue)
    }

    fileprivate static func rawPayloadBytes(
        _ outputs: [VideoProcessingOutputFrame]
    ) throws -> Int {
        var payloadBytes = 0
        for output in outputs {
            let pixelBuffer = output.frame.pixelBuffer
            var frameBytes = CVPixelBufferGetDataSize(pixelBuffer)
            if frameBytes == 0, CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
                for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                    let planeBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                        .multipliedReportingOverflow(
                            by: CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                        )
                    guard !planeBytes.overflow else {
                        throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
                    }
                    let total = frameBytes.addingReportingOverflow(planeBytes.partialValue)
                    guard !total.overflow else {
                        throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
                    }
                    frameBytes = total.partialValue
                }
            }
            let total = payloadBytes.addingReportingOverflow(frameBytes)
            guard !total.overflow else {
                throw HLSVideoTranscodeBranchFailure.invalidFrame(.arithmeticOverflow)
            }
            payloadBytes = total.partialValue
        }
        return payloadBytes
    }

    /// 只有同一 conversion credit 产生的完整双场才可转交预付 backing；任一
    /// 非 HLS/legacy frame、拆分 batch 或伪造 tail 都继续走旧的安全收费。
    fileprivate static func sharedPrepaidCredit(
        for outputs: [VideoProcessingOutputFrame]
    ) -> HLSYADIFConversionCredit? {
        guard outputs.count == 2,
              let first = outputs[0].frame.outputBackingTail?.conversionCredit as? HLSYADIFConversionCredit,
              let second = outputs[1].frame.outputBackingTail?.conversionCredit as? HLSYADIFConversionCredit,
              first === second,
              rawBuffer(outputs[0].frame.pixelBuffer, owns: outputs[0].frame.outputBackingTail),
              rawBuffer(outputs[1].frame.pixelBuffer, owns: outputs[1].frame.outputBackingTail),
              first.ownsAllocatedPair(outputs[0].frame.pixelBuffer, outputs[1].frame.pixelBuffer) else { return nil }
        return first
    }

    private static func rawBuffer(
        _ pixelBuffer: CVPixelBuffer,
        owns tail: VideoOutputBackingRetentionTail?
    ) -> Bool {
        guard let tail,
              let attachment = CVBufferCopyAttachment(
                pixelBuffer, VideoOutputBackingRetentionTail.attachmentKey, nil
              ) else { return false }
        return (attachment as AnyObject) === tail
    }
}
