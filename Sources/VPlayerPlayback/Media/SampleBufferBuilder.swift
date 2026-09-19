// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import Foundation
import OSLog

enum HLSOwnedBlockAdmissionError: Error, Equatable {
    case cancelled
}

/// HLS 视频复制链共用同一 application ledger 的三个局部域：转换中的短暂
/// Data、参数集快照和最终 CoreMedia backing。它们彼此独立可取消，不能把
/// 上游 parser 或 GPU 的既有 credit 当成压缩字节的费用。
final class HLSVideoCopyOwnership: @unchecked Sendable {
    let blockAdmission: HLSOwnedBlockAdmission
    /// VT native callback 使用独立的可取消等待域；关闭它不能影响 assembler。
    let compressedOutputBlockAdmission: HLSOwnedBlockAdmission
    /// scan 结果的 Data 与参数数组在 format/fingerprint/CM copy 前一直存活。
    /// 它与嵌套的 pointer/canonical workspace 分域，仍共用同一 global ledger。
    private let scanAdmission: HLSDataPlaneAdmission
    private let workspaceAdmission: HLSDataPlaneAdmission
    private let parameterSetAdmission: HLSDataPlaneAdmission
    private let parameterOwnerAdmission: HLSDataPlaneAdmission
    private let compressedOutputAdmission: HLSDataPlaneAdmission
    let maximumParameterSetSnapshotCount: Int
    let maximumParameterSetSnapshotBytes: Int

    init(
        maximumPayloadBytes: Int,
        capacity: Int = 4,
        maximumRetainedBytes: Int? = nil,
        parameterSetSnapshotMaximumCount: Int = AnnexBScanner.maximumParameterSetCount,
        parameterSetSnapshotMaximumBytes: Int = AnnexBScanner.maximumParameterSetBytes,
        applicationLedger: HLSDeliveryApplicationChargeLedger
    ) {
        precondition((1...AnnexBScanner.maximumParameterSetCount).contains(parameterSetSnapshotMaximumCount))
        precondition((1...AnnexBScanner.maximumParameterSetBytes).contains(parameterSetSnapshotMaximumBytes))
        maximumParameterSetSnapshotCount = parameterSetSnapshotMaximumCount
        maximumParameterSetSnapshotBytes = parameterSetSnapshotMaximumBytes
        blockAdmission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: maximumPayloadBytes,
            capacity: capacity,
            maximumRetainedBytes: maximumRetainedBytes,
            applicationLedger: applicationLedger
        )
        compressedOutputBlockAdmission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: maximumPayloadBytes,
            capacity: capacity,
            maximumRetainedBytes: maximumRetainedBytes,
            applicationLedger: applicationLedger
        )
        let scratchMaximum = Self.checkedScratchMaximum(maximumPayloadBytes)
        scanAdmission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: scratchMaximum,
            applicationLedger: applicationLedger
        )
        workspaceAdmission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: scratchMaximum,
            applicationLedger: applicationLedger
        )
        // native output 临时 Data 与独立 sample 附件复制在最终 owned block
        // 建立前短暂重叠；它不能借用 scan/workspace 或 assembler 的容量。
        compressedOutputAdmission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: Self.checkedCompressedOutputTemporaryMaximum(maximumPayloadBytes),
            applicationLedger: applicationLedger
        )
        // 每个 snapshot 仍严格受 64 项/1MiB 限制；本域仅显式覆盖一次
        // current 与一次 candidate 的复制重叠。更早的外部 snapshot 会占住
        // 自己的 lease，从而让下一次更新等待其释放，而不是等待当前 owner 自己。
        parameterSetAdmission = HLSDataPlaneAdmission(
            capacity: parameterSetSnapshotMaximumCount * 2,
            maximumBytes: parameterSetSnapshotMaximumBytes * 2,
            applicationLedger: applicationLedger
        )
        let ownerBytes = parameterSetSnapshotMaximumCount * MemoryLayout<HLSVideoParameterSetRetention.Entry>.stride
        parameterOwnerAdmission = HLSDataPlaneAdmission(
            capacity: 2, maximumBytes: ownerBytes * 2, applicationLedger: applicationLedger
        )
    }

    func acquireScanTemporary(bytes: Int) throws -> HLSDataPlaneAdmission.Lease {
        try acquire(from: scanAdmission, bytes: bytes)
    }

    func acquireWorkspace(bytes: Int) throws -> HLSDataPlaneAdmission.Lease {
        try acquire(from: workspaceAdmission, bytes: bytes)
    }

    func acquireCompressedOutputTemporary(bytes: Int) throws -> HLSDataPlaneAdmission.Lease {
        try acquire(from: compressedOutputAdmission, bytes: bytes)
    }

    /// 外部 cancel 先唤醒 native callback 内的等待者；实际 invalidate 仍由
    /// encoder 的 workQueue lane 完成并签发 receipt。
    func cancelCompressedOutputAdmission() {
        compressedOutputAdmission.cancel()
        compressedOutputBlockAdmission.cancel()
    }

    func makeParameterSetEntry(_ parameterSet: Data) throws -> HLSVideoParameterSetRetention.Entry {
        let lease = try acquire(from: parameterSetAdmission, bytes: parameterSet.count)
        // 参数集会穿越 parser callback 的借用窗口，因此在创建独立 owner 前先
        // 取得新副本的准入；不能把 scan 结果的临时 Data 当成已被本 owner 计费。
        var copied = Data()
        copied.reserveCapacity(parameterSet.count)
        copied.append(parameterSet)
        return .init(bytes: copied, lease: lease)
    }

    func makeParameterSetOwner(
        entries: [HLSVideoParameterSetRetention.Entry]
    ) throws -> HLSVideoParameterSetRetention {
        try makeParameterSetOwner(entries: entries,
                                  ownerLease: acquireParameterSetOwnerLease(entryCount: entries.count))
    }
    func acquireParameterSetOwnerLease(entryCount: Int) throws -> HLSDataPlaneAdmission.Lease {
        let bytes = entryCount.multipliedReportingOverflow(
            by: MemoryLayout<HLSVideoParameterSetRetention.Entry>.stride
        )
        guard !bytes.overflow else { throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode) }
        let lease = try acquire(from: parameterOwnerAdmission, bytes: max(1, bytes.partialValue))
        return lease
    }
    func makeParameterSetOwner(entries: [HLSVideoParameterSetRetention.Entry], ownerLease: HLSDataPlaneAdmission.Lease) -> HLSVideoParameterSetRetention {
        HLSVideoParameterSetRetention(entries: entries, ownership: self, ownerLease: ownerLease)
    }

    private func acquire(
        from admission: HLSDataPlaneAdmission,
        bytes: Int
    ) throws -> HLSDataPlaneAdmission.Lease {
        guard bytes > 0 else {
            throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
        let charged = bytes.addingReportingOverflow(HLSOwnedBlockAdmission.fixedOwnerMetadataBytes)
        guard !charged.overflow else {
            throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
        switch admission.waitForAdmission(bytes: bytes, applicationBytes: charged.partialValue) {
        case let .accepted(lease):
            guard let lease = lease as? HLSDataPlaneAdmission.Lease else {
                throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
            }
            return lease
        case .cancelled:
            throw HLSOwnedBlockAdmissionError.cancelled
        case .permanentlyRejected:
            throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
    }

    private static func checkedScratchMaximum(_ maximumPayloadBytes: Int) -> Int {
        precondition(maximumPayloadBytes > 0)
        let parameterSlots = AnnexBScanner.maximumParameterSetCount
            * MemoryLayout<Data>.stride
        let payloadAndParameters = maximumPayloadBytes
            .addingReportingOverflow(AnnexBScanner.maximumParameterSetBytes)
        let total = payloadAndParameters.partialValue.addingReportingOverflow(parameterSlots)
        precondition(!payloadAndParameters.overflow && !total.overflow)
        return total.partialValue
    }

    private static func checkedCompressedOutputTemporaryMaximum(_ maximumPayloadBytes: Int) -> Int {
        let total = maximumPayloadBytes.addingReportingOverflow(
            SampleBufferBuilder.compressedSampleAttachmentMetadataBytes
        )
        precondition(!total.overflow)
        return total.partialValue
    }

    #if DEBUG
    func waitUntilParameterSetAdmissionWaits(_ expected: Int) -> Bool {
        for _ in 0..<100 {
            if parameterSetAdmission.waitingCount >= expected { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
    var parameterSetAdmissionWaitingCount: Int { parameterSetAdmission.waitingCount }
    #endif
}

/// 当前 stub 只为保持参数集的 legacy `Data` 行为提供类型接缝；完整视频
/// 接线会把每次新复制的 lease 绑到该对象的最后一个快照/epoch alias。
final class HLSVideoParameterSetRetention: @unchecked Sendable {
    final class Entry: @unchecked Sendable {
        private let bytes: Data
        private let lease: HLSDataPlaneAdmission.Lease
        init(bytes: Data, lease: HLSDataPlaneAdmission.Lease) { self.bytes = bytes; self.lease = lease }
        var byteCount: Int { bytes.count }
        func withBytes<Result>(_ body: (borrowing Span<UInt8>) throws -> Result) rethrows -> Result {
            try body(bytes.span)
        }

        /// 只在 Data 的同步借用窗内比较，避免向 assembler 重新泄漏裸 Data。
        func matches(_ value: Data) -> Bool {
            value.withUnsafeBytes { rawValue in
                let valueBytes = rawValue.bindMemory(to: UInt8.self)
                return withBytes { bytes in
                    guard bytes.count == valueBytes.count else { return false }
                    for index in 0..<bytes.count where bytes[index] != valueBytes[index] {
                        return false
                    }
                    return true
                }
            }
        }
    }
    let entries: [Entry]
    private let ownership: HLSVideoCopyOwnership
    private let ownerLease: HLSDataPlaneAdmission.Lease
    init(entries: [Entry], ownership: HLSVideoCopyOwnership, ownerLease: HLSDataPlaneAdmission.Lease) {
        self.entries = entries
        self.ownership = ownership
        self.ownerLease = ownerLease
    }
    var count: Int { entries.count }
    func withEntry<Result>(at index: Int, _ body: (borrowing Span<UInt8>) throws -> Result) rethrows -> Result {
        try entries[index].withBytes(body)
    }

    /// fingerprint 的完整 canonical 临时工作区也必须在同一 application ledger
    /// 中先获准入；SHA-256 的固定 32 字节结果不能替代该工作区的真实费用。
    func withTemporaryCanonicalWorkspace<Result>(
        bytes: Int,
        _ body: () throws -> Result
    ) throws -> Result {
        let lease = try ownership.acquireWorkspace(bytes: bytes)
        defer { lease.release() }
        return try body()
    }
}

/// HLS 独立 block 的局部准入域。它只关闭自身的 producer，不影响同一 application ledger 的其他域。
final class HLSOwnedBlockAdmission: @unchecked Sendable {
    /// 每个独立 block 的 owner/custom-source context 动态预付费用。
    /// 它不代表、更不覆盖既有 19KiB 固定 owner 图；后者仍待完整媒体图接线核定。
    static let fixedOwnerMetadataBytes = 256

    #if DEBUG
    enum ConstructionMode: CaseIterable, Equatable {
        case normal
        case failBeforeAllocation
        case failAllocation
        case failAfterAllocation
        case failAfterAllocationFreeBeforeReturn
        case failAfterAllocationFreeDuringFailureCleanup
    }
    #endif

    private let localAdmission: HLSDataPlaneAdmission
    let maximumPayloadBytes: Int
    #if DEBUG
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let lock = NSLock()
    fileprivate private(set) var constructionMode: ConstructionMode
    private var allocationCount = 0, freeCount = 0, refConCount = 0, chargeSnapshot = -1, freeAtCreateFailure = -1
    #endif

    init(
        maximumPayloadBytes: Int,
        capacity: Int = 4,
        maximumRetainedBytes: Int? = nil,
        applicationLedger: HLSDeliveryApplicationChargeLedger
    ) {
        self.maximumPayloadBytes = maximumPayloadBytes
        #if DEBUG
        self.constructionMode = .normal
        ledger = applicationLedger
        #endif
        localAdmission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: maximumRetainedBytes ?? maximumPayloadBytes,
            applicationLedger: applicationLedger
        )
    }

    #if DEBUG
    convenience init(
        maximumPayloadBytes: Int,
        capacity: Int = 4,
        maximumRetainedBytes: Int? = nil,
        applicationLedger: HLSDeliveryApplicationChargeLedger,
        constructionMode: ConstructionMode
    ) {
        self.init(
            maximumPayloadBytes: maximumPayloadBytes,
            capacity: capacity,
            maximumRetainedBytes: maximumRetainedBytes,
            applicationLedger: applicationLedger
        )
        self.constructionMode = constructionMode
    }
    #endif

    var usage: HLSDataPlaneAdmissionUsage { localAdmission.usage }
    #if DEBUG
    var allocationAttemptCount: Int { lock.withLock { allocationCount } }
    var freeBlockCount: Int { lock.withLock { freeCount } }
    var refConReleaseCount: Int { lock.withLock { refConCount } }
    var debugAllocationChargeSnapshot: Int { lock.withLock { chargeSnapshot } }
    var debugFreeBlockCountBeforeFailureCleanup: Int { lock.withLock { freeAtCreateFailure } }
    #endif

    func cancel() { localAdmission.cancel() }

    #if DEBUG
    func waitUntilWaitingCount(_ expected: Int) -> Bool {
        for _ in 0..<100 { if localAdmission.waitingCount >= expected { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
    fileprivate func allocated() { lock.withLock { allocationCount += 1; chargeSnapshot = ledger.chargedBytes } }
    fileprivate func freed() { lock.withLock { freeCount += 1 } }
    fileprivate func released() { lock.withLock { refConCount += 1 } }
    fileprivate func recordCreateFailureFreeCount() { lock.withLock { freeAtCreateFailure = freeCount } }
    #endif
    fileprivate func acquire(
        bytes: Int,
        applicationMetadataBytes: Int = 0
    ) throws -> HLSDataPlaneAdmission.Lease {
        guard applicationMetadataBytes >= 0 else {
            throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
        let payloadAndMetadata = bytes.addingReportingOverflow(applicationMetadataBytes)
        let charge = payloadAndMetadata.partialValue.addingReportingOverflow(Self.fixedOwnerMetadataBytes)
        guard !payloadAndMetadata.overflow, !charge.overflow else {
            throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
        switch localAdmission.waitForAdmission(bytes: bytes, applicationBytes: charge.partialValue) {
        case let .accepted(lease):
            guard let concreteLease = lease as? HLSDataPlaneAdmission.Lease else {
                throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
            }
            return concreteLease
        case .cancelled: throw HLSOwnedBlockAdmissionError.cancelled
        case .permanentlyRejected: throw PlaybackCoreError.videoDecode(SampleBufferBuilder.invalidDataErrorCode)
        }
    }
}

private final class HLSOwnedBlockContext {
    let admission: HLSOwnedBlockAdmission
    private let lock = NSLock()
    private var refConAvailable = true
    var lease: HLSDataPlaneAdmission.Lease?
    init(_ admission: HLSOwnedBlockAdmission, _ lease: HLSDataPlaneAdmission.Lease) {
        self.admission = admission
        self.lease = lease
    }
    func claimRefCon() -> Bool {
        lock.withLock {
            guard refConAvailable else { return false }
            refConAvailable = false
            return true
        }
    }
    func release() {
        lease = nil
        #if DEBUG
        admission.released()
        #endif
    }
}
private func hlsOwnedAllocate(_ refCon: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    guard let refCon else { return nil }
    let context = Unmanaged<HLSOwnedBlockContext>.fromOpaque(refCon).takeUnretainedValue()
    #if DEBUG
    context.admission.allocated()
    if context.admission.constructionMode == .failAllocation { return nil }
    #endif
    return malloc(size)
}
private func hlsOwnedFree(_ refCon: UnsafeMutableRawPointer?, _ block: UnsafeMutableRawPointer, _: Int) {
    guard let refCon else { return }
    let borrowed = Unmanaged<HLSOwnedBlockContext>.fromOpaque(refCon).takeUnretainedValue()
    guard borrowed.claimRefCon() else { return }
    let context = Unmanaged<HLSOwnedBlockContext>.fromOpaque(refCon).takeRetainedValue()
    #if DEBUG
    context.admission.freed()
    #endif
    free(block)
    context.release()
}

enum SampleBufferBuilder {
    static let invalidDataErrorCode: Int32 = -1_448_143_362
    private static let maximumVideoPayloadBytes = 64 * 1_024 * 1_024
    /// attachment 计划在 native callback 内先以这个严格上界获准入，再对实际
    /// 已验证的键数计算最终 owner 费用。任意未知/超限图都在复制前失败。
    static let compressedSampleAttachmentMetadataBytes = 2_048
    private static let attachmentEntryMetadataBytes = 64
    private static let attachmentContainerMetadataBytes = 128
    private static let maximumCopiedAttachmentEntries = 16
    private static let logger = Logger(
        subsystem: "com.vplayer.playback",
        category: "SampleBufferBuilder"
    )

    static func makeVideo(
        data: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime,
        duration: CMTime,
        isRandomAccess: Bool
    ) throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(data, video: true)
        return try makeVideo(
            blockBuffer: blockBuffer,
            dataLength: data.count,
            formatDescription: formatDescription,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp,
            duration: duration,
            isRandomAccess: isRandomAccess
        )
    }

    /// HLS 专用路径：在 Data 临时转换仍被单独 reservation 覆盖时，把实际
    /// length-prefixed 字节复制进带最后 alias tail 的 CMBlockBuffer。
    static func makeHLSOwnedVideo(
        data: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime,
        duration: CMTime,
        isRandomAccess: Bool,
        ownership: HLSVideoCopyOwnership
    ) throws -> CMSampleBuffer {
        let blockBuffer = try makeHLSOwnedBlockBuffer(
            copying: data,
            admission: ownership.blockAdmission
        )
        return try makeVideo(
            blockBuffer: blockBuffer,
            dataLength: data.count,
            formatDescription: formatDescription,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp,
            duration: duration,
            isRandomAccess: isRandomAccess
        )
    }

    static func copyHLSOwnedCompressedVideoSample(
        _ source: CMSampleBuffer,
        ownership: HLSVideoCopyOwnership
    ) throws -> CMSampleBuffer {
        guard CMSampleBufferGetNumSamples(source) == 1,
              let block = CMSampleBufferGetDataBuffer(source),
              let format = CMSampleBufferGetFormatDescription(source) else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= ownership.blockAdmission.maximumPayloadBytes else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let temporaryBytes = length.addingReportingOverflow(compressedSampleAttachmentMetadataBytes)
        guard !temporaryBytes.overflow else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        // 先覆盖 Data 和附件复制的临时重叠，再读取 native block；最终 owned
        // block 的 lease 另行持有到所有 CoreMedia alias 释放为止。
        let temporaryLease = try ownership.acquireCompressedOutputTemporary(
            bytes: temporaryBytes.partialValue
        )
        defer { temporaryLease.release() }
        let attachmentMetadataBytes = try validatedAttachmentMetadataBytes(from: source)
        // VT 可给出合法但尚未 materialize 的 lazy CMBlockBuffer。它仍属于
        // native source，不是新的 application copy；先确保可读，再进行下方已
        // 预付的 Data/owned-block 双重实际复制。
        let assureStatus = CMBlockBufferAssureBlockMemory(block)
        guard assureStatus == noErr else { throw PlaybackCoreError.videoDecode(assureStatus) }
        var payload = Data(count: length)
        let status = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw PlaybackCoreError.videoDecode(status) }
        let blockBuffer = try makeHLSOwnedBlockBuffer(
            copying: payload,
            admission: ownership.compressedOutputBlockAdmission,
            applicationMetadataBytes: attachmentMetadataBytes
        )
        let copied = try makeVideo(
            blockBuffer: blockBuffer,
            dataLength: payload.count,
            formatDescription: format,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source),
            duration: CMSampleBufferGetDuration(source),
            // source 的 sample attachment 是权威语义，随后整体深拷贝，不能只
            // 从 NotSync 推导一个字段后丢弃其余 per-sample metadata。
            isRandomAccess: true
        )
        copyBufferAttachments(from: source, to: copied)
        try copySampleAttachments(from: source, to: copied)
        return copied
    }

    private static func copyBufferAttachments(from source: CMSampleBuffer, to destination: CMSampleBuffer) {
        // sample-buffer 自身与每 sample 的 attachments 是两套 CoreMedia 合同；
        // 两个 propagation mode 都要保留，不能只复制常见的 NotSync。
        for index in 0..<4 { let key = bufferAttachmentKey(index)
            var mode = kCMAttachmentMode_ShouldNotPropagate
            guard let value = CMGetAttachment(source, key: key, attachmentModeOut: &mode) else {
                continue
            }
            CMSetAttachment(destination, key: key, value: value, attachmentMode: mode)
        }
    }

    private static func copySampleAttachments(
        from source: CMSampleBuffer,
        to destination: CMSampleBuffer
    ) throws {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) else {
            return
        }
        guard CFArrayGetCount(attachments) == 1,
              let sourceValue = CFArrayGetValueAtIndex(attachments, 0),
              let destinationAttachments = CMSampleBufferGetSampleAttachmentsArray(
                  destination, createIfNecessary: true
              ),
              CFArrayGetCount(destinationAttachments) == 1,
              let destinationValue = CFArrayGetValueAtIndex(destinationAttachments, 0) else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let sourceDictionary = Unmanaged<CFDictionary>.fromOpaque(sourceValue).takeUnretainedValue()
        let destinationDictionary = Unmanaged<CFMutableDictionary>.fromOpaque(destinationValue)
            .takeUnretainedValue()
        for index in 0..<12 { let key = sampleAttachmentKey(index)
            guard let value = CFDictionaryGetValue(
                sourceDictionary, Unmanaged.passUnretained(key).toOpaque()
            ) else { continue }
            if CFEqual(key, kCMSampleAttachmentKey_HEVCTemporalLevelInfo) {
                try copyHEVCTemporalLevelInfo(value, to: destinationDictionary)
                continue
            }
            CFDictionarySetValue(destinationDictionary,
                                 Unmanaged.passUnretained(key).toOpaque(), value)
        }
    }

    private static func sampleAttachmentKey(_ index: Int) -> CFString { switch index { case 0: kCMSampleAttachmentKey_NotSync; case 1: kCMSampleAttachmentKey_PartialSync; case 2: kCMSampleAttachmentKey_HasRedundantCoding; case 3: kCMSampleAttachmentKey_IsDependedOnByOthers; case 4: kCMSampleAttachmentKey_DependsOnOthers; case 5: kCMSampleAttachmentKey_EarlierDisplayTimesAllowed; case 6: kCMSampleAttachmentKey_DisplayImmediately; case 7: kCMSampleAttachmentKey_DoNotDisplay; case 8: kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess; case 9: kCMSampleAttachmentKey_HEVCStepwiseTemporalSubLayerAccess; case 10: kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType; default: kCMSampleAttachmentKey_HEVCTemporalLevelInfo } }
    private static func bufferAttachmentKey(_ index: Int) -> CFString { switch index { case 0: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding; case 1: kCMSampleBufferAttachmentKey_DrainAfterDecoding; case 2: kCMSampleBufferAttachmentKey_ResumeOutput; default: kCMSampleBufferAttachmentKey_ForceKeyFrame } }

    private static func validatedAttachmentMetadataBytes(from source: CMSampleBuffer) throws -> Int {
        var copiedEntryCount = 0
        var copiedContainerCount = 0
        var copiedDataByteCount = 0
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            guard let dictionary = CMCopyDictionaryOfAttachments(
                allocator: kCFAllocatorDefault, target: source, attachmentMode: mode
            ) else { continue }
            let count = CFDictionaryGetCount(dictionary)
            guard count >= 0, count <= maximumCopiedAttachmentEntries else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            var keys = Array<UnsafeRawPointer?>(repeating: nil, count: count)
            var values = Array<UnsafeRawPointer?>(repeating: nil, count: count)
            CFDictionaryGetKeysAndValues(dictionary, &keys, &values)
            for index in 0..<count {
                guard let key = keys[index], let value = values[index],
                      isSupportedBufferAttachment(key: key, value: value) else {
                    throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
                }
            }
            let entries = copiedEntryCount.addingReportingOverflow(count)
            let containers = copiedContainerCount.addingReportingOverflow(count == 0 ? 0 : 1)
            guard !entries.overflow, !containers.overflow else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            copiedEntryCount = entries.partialValue
            copiedContainerCount = containers.partialValue
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) {
            guard CFArrayGetCount(attachments) == 1,
                  let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            let dictionary = Unmanaged<CFDictionary>.fromOpaque(rawDictionary).takeUnretainedValue()
            let count = CFDictionaryGetCount(dictionary)
            var knownCount = 0
            for index in 0..<12 { let key = sampleAttachmentKey(index)
                guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else {
                    continue
                }
                guard isSupportedSampleAttachment(key: key, value: value) else {
                    throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
                }
                knownCount += 1
            }
            guard count == knownCount else { throw PlaybackCoreError.videoDecode(invalidDataErrorCode) }
            let sampleEntries = copiedEntryCount.addingReportingOverflow(knownCount)
            let sampleContainers = copiedContainerCount.addingReportingOverflow(count == 0 ? 0 : 1)
            guard !sampleEntries.overflow, !sampleContainers.overflow else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            copiedEntryCount = sampleEntries.partialValue
            copiedContainerCount = sampleContainers.partialValue
            if CFDictionaryGetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCTemporalLevelInfo).toOpaque()
            ) != nil {
                // 外层 temporal entry 已包含在 knownCount。这里预付独立 nested
                // dictionary、其余七个 entry，以及两份固定长度 CFData 的内容。
                let nestedEntries = copiedEntryCount.addingReportingOverflow(7)
                let nestedContainers = copiedContainerCount.addingReportingOverflow(1)
                let nestedData = copiedDataByteCount.addingReportingOverflow(10)
                guard !nestedEntries.overflow, !nestedContainers.overflow, !nestedData.overflow else {
                    throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
                }
                copiedEntryCount = nestedEntries.partialValue
                copiedContainerCount = nestedContainers.partialValue
                copiedDataByteCount = nestedData.partialValue
            }
        }
        guard copiedEntryCount <= maximumCopiedAttachmentEntries else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let entries = copiedEntryCount.multipliedReportingOverflow(by: attachmentEntryMetadataBytes)
        let containers = copiedContainerCount.multipliedReportingOverflow(by: attachmentContainerMetadataBytes)
        let entryAndContainer = entries.partialValue.addingReportingOverflow(containers.partialValue)
        let total = entryAndContainer.partialValue.addingReportingOverflow(copiedDataByteCount)
        guard !entries.overflow, !containers.overflow, !entryAndContainer.overflow, !total.overflow,
              total.partialValue <= compressedSampleAttachmentMetadataBytes else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        return total.partialValue
    }

    private static func isSupportedBufferAttachment(key: UnsafeRawPointer, value: UnsafeRawPointer) -> Bool {
        let key = Unmanaged<CFString>.fromOpaque(key).takeUnretainedValue()
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        let isBoolean = CFGetTypeID(object) == CFBooleanGetTypeID()
        if CFEqual(key, kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding) ||
            CFEqual(key, kCMSampleBufferAttachmentKey_DrainAfterDecoding) ||
            CFEqual(key, kCMSampleBufferAttachmentKey_ForceKeyFrame) {
            return isBoolean
        }
        return CFEqual(key, kCMSampleBufferAttachmentKey_ResumeOutput) &&
            CFGetTypeID(object) == CFNumberGetTypeID()
    }

    private static func isSupportedSampleAttachment(key: CFString, value: UnsafeRawPointer) -> Bool {
        if CFEqual(key, kCMSampleAttachmentKey_HEVCTemporalLevelInfo) { return validHEVCTemporalLevelInfo(value) }
        if CFEqual(key, kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType) {
            return CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()) == CFNumberGetTypeID()
        }
        return CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()) == CFBooleanGetTypeID()
    }

    private static func validHEVCTemporalLevelInfo(_ value: UnsafeRawPointer) -> Bool {
        guard CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()) == CFDictionaryGetTypeID() else { return false }
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(value).takeUnretainedValue()
        guard CFDictionaryGetCount(dictionary) == 7 else { return false }
        for index in 0..<5 {
            let key = temporalLevelNumberKey(index)
            guard let item = CFDictionaryGetValue(
                dictionary, Unmanaged.passUnretained(key).toOpaque()
            ), CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(item).takeUnretainedValue()) == CFNumberGetTypeID() else {
                return false
            }
        }
        guard let compatibility = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags).toOpaque()), let constraint = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags).toOpaque()) else { return false }
        return CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(compatibility).takeUnretainedValue()) == CFDataGetTypeID() && CFDataGetLength(Unmanaged<CFData>.fromOpaque(compatibility).takeUnretainedValue()) == 4 && CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(constraint).takeUnretainedValue()) == CFDataGetTypeID() && CFDataGetLength(Unmanaged<CFData>.fromOpaque(constraint).takeUnretainedValue()) == 6
    }

    private static func copyHEVCTemporalLevelInfo(_ value: UnsafeRawPointer, to destination: CFMutableDictionary) throws {
        guard validHEVCTemporalLevelInfo(value),
              let copied = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault, 7, Unmanaged<CFDictionary>.fromOpaque(value).takeUnretainedValue()
              ),
              let compatibility = CFDictionaryGetValue(
                copied, Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags).toOpaque()
              ),
              let constraint = CFDictionaryGetValue(
                copied, Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags).toOpaque()
              ),
              let copiedCompatibility = CFDataCreateCopy(
                kCFAllocatorDefault, Unmanaged<CFData>.fromOpaque(compatibility).takeUnretainedValue()
              ),
              let copiedConstraint = CFDataCreateCopy(
                kCFAllocatorDefault, Unmanaged<CFData>.fromOpaque(constraint).takeUnretainedValue()
              ) else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        CFDictionarySetValue(
            copied,
            Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags).toOpaque(),
            Unmanaged.passUnretained(copiedCompatibility).toOpaque()
        )
        CFDictionarySetValue(
            copied,
            Unmanaged.passUnretained(kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags).toOpaque(),
            Unmanaged.passUnretained(copiedConstraint).toOpaque()
        )
        CFDictionarySetValue(destination, Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCTemporalLevelInfo).toOpaque(), Unmanaged.passUnretained(copied).toOpaque())
    }

    private static func temporalLevelNumberKey(_ index: Int) -> CFString {
        switch index {
        case 0: kCMHEVCTemporalLevelInfoKey_TemporalLevel
        case 1: kCMHEVCTemporalLevelInfoKey_ProfileSpace
        case 2: kCMHEVCTemporalLevelInfoKey_TierFlag
        case 3: kCMHEVCTemporalLevelInfoKey_ProfileIndex
        default: kCMHEVCTemporalLevelInfoKey_LevelIndex
        }
    }

    private static func makeVideo(
        blockBuffer: CMBlockBuffer,
        dataLength: Int,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime,
        duration: CMTime,
        isRandomAccess: Bool
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleSize = dataLength
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            logger.error(
                "video sample buffer creation failed status=\(status, privacy: .public) hasBuffer=\(sampleBuffer != nil, privacy: .public)"
            )
            throw PlaybackCoreError.videoDecode(status)
        }
        if !isRandomAccess {
            guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ), CFArrayGetCount(rawAttachments) == 1 else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            guard let rawDictionary = CFArrayGetValueAtIndex(rawAttachments, 0) else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(rawDictionary)
                .takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    /// 仅为 HLS 复制接管提供的同步借用入口；Span 的地址不会离开本调用。
    static func makeHLSOwnedBlockBuffer(
        copying bytes: borrowing Span<UInt8>,
        admission: HLSOwnedBlockAdmission,
        applicationMetadataBytes: Int = 0
    ) throws -> CMBlockBuffer {
        guard bytes.count > 0, bytes.count <= admission.maximumPayloadBytes else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let lease = try admission.acquire(bytes: bytes.count,
                                          applicationMetadataBytes: applicationMetadataBytes)
        let context = HLSOwnedBlockContext(admission, lease)
        let refCon = Unmanaged.passRetained(context).toOpaque()
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: hlsOwnedAllocate,
            FreeBlock: hlsOwnedFree,
            refCon: refCon
        )
        var blockBuffer: CMBlockBuffer?
        #if DEBUG
        let length = admission.constructionMode == .failBeforeAllocation ? 0 : bytes.count
        #else
        let length = bytes.count
        #endif
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: nil,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        var createStatus = status
        #if DEBUG
        if status == noErr {
            switch admission.constructionMode {
            case .failAfterAllocationFreeBeforeReturn:
                blockBuffer = nil
                createStatus = kCMBlockBufferBadPointerParameterErr
            case .failAfterAllocationFreeDuringFailureCleanup:
                createStatus = kCMBlockBufferBadPointerParameterErr
            default:
                break
            }
        }
        #endif
        #if DEBUG
        if createStatus != noErr { admission.recordCreateFailureFreeCount() }
        #endif
        guard createStatus == noErr, let block = blockBuffer else {
            // 某些失败返回仍可能交回临时 block；先释放该真实输出，让 FreeBlock
            // 在安全的 context 强引用仍在作用域内取得唯一 refCon。
            blockBuffer = nil
            if context.claimRefCon() { Unmanaged<HLSOwnedBlockContext>.fromOpaque(refCon).takeRetainedValue().release() }
            throw PlaybackCoreError.videoDecode(createStatus)
        }
        #if DEBUG
        let offset = admission.constructionMode == .failAfterAllocation ? bytes.count + 1 : 0
        #else
        let offset = 0
        #endif
        let copyStatus: OSStatus = bytes.withUnsafeBytes { raw in CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: bytes.count) }
        guard copyStatus == noErr else { throw PlaybackCoreError.videoDecode(copyStatus) }
        return block
    }

    /// 兼容已有 Data 调用点的薄桥；真实入口仍是上方不可逃逸 Span。
    static func makeHLSOwnedBlockBuffer(
        copying data: Data,
        admission: HLSOwnedBlockAdmission,
        applicationMetadataBytes: Int = 0
    ) throws -> CMBlockBuffer {
        try makeHLSOwnedBlockBuffer(copying: data.span, admission: admission,
                                    applicationMetadataBytes: applicationMetadataBytes)
    }

    static func makeAudio(
        frame: AdmittedAudioFrame,
        formatDescription: CMAudioFormatDescription,
        forceResetDecoderBeforeDecoding: Bool
    ) throws -> CMSampleBuffer {
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescription
        )?.pointee,
        let frameSampleCount = UInt32(exactly: frame.frame.frameSampleCount),
        frameSampleCount > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }

        let variableFramesInPacket: UInt32
        if streamDescription.mFramesPerPacket == 0 {
            variableFramesInPacket = frameSampleCount
        } else {
            guard streamDescription.mFramesPerPacket == frameSampleCount else {
                throw PlaybackCoreError.audioFallbackDecode(
                    CompressedAudioAssembler.invalidInputErrorCode
                )
            }
            variableFramesInPacket = 0
        }

        let sampleBuffer = try makeAudioSample(
            data: frame.frame.payload,
            formatDescription: formatDescription,
            presentationTimeStamp: frame.normalizedPresentationTimeStamp,
            variableFramesInPacket: variableFramesInPacket
        )
        if frame.resetDecoderBeforeDecoding || forceResetDecoderBeforeDecoding {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        if frame.fillDiscontinuitiesWithSilence {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return sampleBuffer
    }

    static func copyingAudioSampleBufferWithResetDecoderBeforeDecoding(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> CMSampleBuffer {
        var copiedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copiedBuffer
        )
        guard status == noErr, let copiedBuffer else {
            throw PlaybackCoreError.audioFallbackDecode(status)
        }
        CMSetAttachment(
            copiedBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return copiedBuffer
    }

    static func compressedAudioPayloadByteCount(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> Int {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        let blockLength = CMBlockBufferGetDataLength(dataBuffer)
        let totalSampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        guard blockLength > 0, totalSampleSize == blockLength else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        return blockLength
    }

    private static func makeAudioSample(
        data: Data,
        formatDescription: CMAudioFormatDescription,
        presentationTimeStamp: CMTime,
        variableFramesInPacket: UInt32
    ) throws -> CMSampleBuffer {
        guard presentationTimeStamp.isNumeric,
              let byteSize = UInt32(exactly: data.count) else {
            throw PlaybackCoreError.audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
        }
        let blockBuffer = try makeBlockBuffer(data, video: false)
        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: variableFramesInPacket,
            mDataByteSize: byteSize
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        guard try compressedAudioPayloadByteCount(sampleBuffer) == data.count else {
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        return sampleBuffer
    }

    private static func makeBlockBuffer(_ data: Data, video: Bool) throws -> CMBlockBuffer {
        let maximumPayloadBytes = video
            ? maximumVideoPayloadBytes
            : AudioCodecProfileValidation.maximumRawAACAccessUnitBytes
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            if video {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            throw PlaybackCoreError.audioFallbackDecode(
                CompressedAudioAssembler.invalidInputErrorCode
            )
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            if video {
                logger.error(
                    "video block buffer creation failed status=\(status, privacy: .public) hasBuffer=\(blockBuffer != nil, privacy: .public)"
                )
                throw PlaybackCoreError.videoDecode(status)
            }
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        status = data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: rawBuffer.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            if video {
                logger.error(
                    "video block buffer copy failed status=\(status, privacy: .public)"
                )
                throw PlaybackCoreError.videoDecode(status)
            }
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        return blockBuffer
    }
}
