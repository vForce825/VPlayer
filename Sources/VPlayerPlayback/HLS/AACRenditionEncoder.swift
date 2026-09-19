// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation

enum AACRenditionFailure: Error, Equatable { case invalidLayout, invalidInput, capacityExceeded, budgetUnavailable, invalidPlan, busy, cancelled, framework(OSStatus), frameworkProperty(OSStatus, UInt32), calibrationMismatch, aacEncoderCookieInvariantViolation }
struct AACASBD: Sendable, Hashable {
    var sampleRate: Double = 0
    var formatID: UInt32 = 0
    var formatFlags: UInt32 = 0
    var bytesPerPacket: UInt32 = 0
    var framesPerPacket: UInt32 = 0
    var bytesPerFrame: UInt32 = 0
    var channelsPerFrame: UInt32 = 0
    var bitsPerChannel: UInt32 = 0
    var reserved: UInt32 = 0
    init(_ value: AudioStreamBasicDescription = AudioStreamBasicDescription()) {
        sampleRate = value.mSampleRate; formatID = value.mFormatID; formatFlags = value.mFormatFlags
        bytesPerPacket = value.mBytesPerPacket; framesPerPacket = value.mFramesPerPacket
        bytesPerFrame = value.mBytesPerFrame; channelsPerFrame = value.mChannelsPerFrame
        bitsPerChannel = value.mBitsPerChannel; reserved = value.mReserved
    }
    var native: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerPacket, mFramesPerPacket: framesPerPacket, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelsPerFrame, mBitsPerChannel: bitsPerChannel, mReserved: reserved)
    }
}
struct AACRenditionRequest: Sendable, Hashable {
    let layout: RenditionAudioLayout
    let capabilityVersion: String
    let inputCookie: Data
    let outputASBD: AACASBD
    let bitrate: UInt32
    let primeMethod: UInt32
    let bitrateControlMode: UInt32
    init(layout: RenditionAudioLayout, capabilityVersion: String, inputCookie: Data = Data()) throws {
        guard !capabilityVersion.isEmpty, capabilityVersion.utf8.count <= 256 else { throw AACRenditionFailure.invalidPlan }
        try AACRenditionEncoder.validateCookieCapacity(inputCookie.count)
        self.layout = layout.canonical; self.capabilityVersion = capabilityVersion; self.inputCookie = inputCookie
        let channels = UInt32(layout.labels.count)
        outputASBD = AACASBD(AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0))
        bitrate = channels == 1 ? 96_000 : channels == 2 ? 160_000 : channels <= 6 ? 320_000 : 512_000
        primeMethod = kConverterPrimeMethod_Normal
        bitrateControlMode = kAudioCodecBitRateControlMode_Constant
    }
}
struct AACCalibrationPlan: Sendable, Hashable {
    struct Entry: Sendable, Hashable { let ordinal: Int; let request: AACRenditionRequest }
    let entries: [Entry]
    let digest: Data
    // nonce 标识一次计划实例；稳定 typed digest 仅描述完整有序内容。
    let planNonce = UUID()
    init(entries: [Entry]) throws {
        guard entries.count <= 2, Set(entries.map(\.request)).count == entries.count,
              entries.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else { throw AACRenditionFailure.invalidPlan }
        self.entries = entries
        var bytes = Data("VPlayer.AACCalibrationPlan.v1".utf8)
        func field(_ tag: UInt8, _ value: Data) {
            bytes.append(tag)
            withUnsafeBytes(of: UInt64(value.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        func integer(_ tag: UInt8, _ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { field(tag, Data($0)) } }
        integer(1, UInt64(entries.count))
        for entry in entries {
            // ordinal 不属于 request signature，但完整有序 plan 必须编码位置。
            integer(2, UInt64(entry.ordinal))
            let request = entry.request, asbd = request.outputASBD
            integer(3, asbd.sampleRate.bitPattern)
            for (offset, value) in [asbd.formatID,asbd.formatFlags,asbd.bytesPerPacket,asbd.framesPerPacket,
                asbd.bytesPerFrame,asbd.channelsPerFrame,asbd.bitsPerChannel,asbd.reserved].enumerated() {
                integer(UInt8(4 + offset), UInt64(value))
            }
            integer(12, UInt64(request.layout.tag)); field(13, Data(request.layout.labels.map(\.rawValue)))
            integer(14, UInt64(request.bitrate)); integer(15, UInt64(request.primeMethod))
            field(16, request.inputCookie); field(17, Data(request.capabilityVersion.utf8))
            integer(18, UInt64(request.bitrateControlMode))
        }
        digest = Data(SHA256.hash(data: bytes))
    }
    static func build(_ requests: [AACRenditionRequest]) throws -> Self {
        var unique: [AACRenditionRequest] = []
        for request in requests where !unique.contains(request) {
            guard unique.count < 2 else { throw AACRenditionFailure.invalidPlan }
            unique.append(request)
        }
        return try Self(entries: unique.enumerated().map { Entry(ordinal: $0.offset, request: $0.element) })
    }
}
struct ConverterInstanceNonce: Sendable, Hashable { let value = UUID() }
struct AACEncoderIdentity: Sendable, Hashable { let plan: AACCalibrationPlan; let ordinal: Int; let request: AACRenditionRequest; let nonce: ConverterInstanceNonce }
struct AACFinalizedPassSignature: Sendable, Hashable {
    let identity: AACEncoderIdentity
    let actualASBD: AACASBD
    let layout: RenditionAudioLayout
    let layoutBacking: AACDataBacking
    var actualLayout: Data { layoutBacking.data }
    let leadingPrimeFrames: UInt32
    let trailingPrimeFrames: UInt32
    let packetDuration: UInt32
    let cookieBacking: AACDataBacking
    var finalizedCookie: Data { cookieBacking.data }
    let totalDecodedFrames: Int
    let decodedLeadingSampleCount: Int
}
struct AACEncodedEpoch: @unchecked Sendable {
    let identity: AACEncoderIdentity
    let buffers: [CMSampleBuffer]
    let realSampleCount: Int
    let totalDecodedFrames: Int
    let leadingFrames: Int
    let trailingFrames: Int
    let actualLeadingPrimeFrames: UInt32
    let actualTrailingPrimeFrames: UInt32
    let bandwidth: AACBandwidthEvidence
    let packetLease: AACCalibrationWorkspace.Lease
    let formatLease: AACCalibrationWorkspace.Lease
    var accountedBytes: Int { packetLease.bytes + formatLease.bytes }
}
struct AACStreamSummary: Sendable {
    let identity: AACEncoderIdentity
    let realSampleCount: Int64
    let totalDecodedFrames: Int64
    let leadingFrames: Int
    let trailingFrames: Int64
    let actualLeadingPrimeFrames: UInt32
    let actualTrailingPrimeFrames: UInt32
    let maximumRetainedPackets: Int
    let bandwidth: AACBandwidthEvidence
}
enum AACStreamPumpInput { case pcm([Float]), unavailable, endOfStream }

final class AACLiveEncodingContext: @unchecked Sendable {
    let identity = UUID()
    let encoderIdentity: AACEncoderIdentity
    let formatIdentity: ObjectIdentifier
    let calibratedLeadingFrames: Int
    private let lock = NSLock()
    private var writerBinding: FMP4WriterBinding?

    init(encoderIdentity: AACEncoderIdentity, format: CMFormatDescription,
         calibratedLeadingFrames: Int) {
        self.encoderIdentity = encoderIdentity
        formatIdentity = ObjectIdentifier(format)
        self.calibratedLeadingFrames = calibratedLeadingFrames
    }

    func bind(to binding: FMP4WriterBinding) -> Bool {
        lock.withLock {
            if let writerBinding { return writerBinding == binding }
            writerBinding = binding
            return true
        }
    }

    /// 物理 writer 迁移只能由前代 writer 私签的一次性 continuation 授权。
    /// 调用方不能仅凭一份新 binding 让同一 live context 改绑。
    func migrate(
        from previous: FMP4WriterBinding,
        to next: FMP4WriterBinding,
        using continuation: AACWriterWindowContinuation
    ) -> Bool {
        lock.withLock {
            guard writerBinding == previous,
                  continuation.authorizesContextMigration(
                    context: self, previous: previous, next: next
                  ) else { return false }
            writerBinding = next
            return true
        }
    }

    func matches(_ binding: FMP4WriterBinding) -> Bool {
        lock.withLock { writerBinding == binding }
    }
}

struct AACFinalEmissionIdentity: Sendable, Hashable {
    let ordinal: UInt64
    let evidenceDigest: Data
    let isFinalBuffer: Bool
}

/// 只能由持有真实 AudioConverter 的 encoder 签发。签发时把可变 sample buffer
/// 复制进私有 backing；writer 只在自己的 lane 内临时物化，调用方拿不到可变对象。
final class AACIncrementalEmission: @unchecked Sendable {
    let identity: AACEncoderIdentity
    let ordinal: UInt64
    let liveContextIdentity: UUID
    let isFinalBuffer: Bool
    let evidenceDigest: Data
    let bandwidth: AACBandwidthEvidence
    let packetLease: AACCalibrationWorkspace.Lease
    let formatLease: AACCalibrationWorkspace.Lease
    let frozenLease: AACCalibrationWorkspace.Lease
    let frozenByteCount: Int
    var accountedFrozenBytes: Int { frozenLease.bytes }
    let liveContext: AACLiveEncodingContext
    private let payload: NSData
    private let format: CMFormatDescription
    private let packetDescriptions: [AudioStreamPacketDescription]
    private let sampleCount: Int
    private let presentationTimeStamp: CMTime
    private let outputPresentationTimeStamp: CMTime
    private let duration: CMTime
    private let leadingTrim: CMTime?
    private let trailingTrim: CMTime?

    fileprivate init(
        identity: AACEncoderIdentity,
        ordinal: UInt64,
        sampleBuffer: CMSampleBuffer,
        isFinalBuffer: Bool,
        liveContext: AACLiveEncodingContext,
        bandwidth: AACBandwidthEvidence,
        packetLease: AACCalibrationWorkspace.Lease,
        formatLease: AACCalibrationWorkspace.Lease,
        frozenLease: AACCalibrationWorkspace.Lease
    ) throws {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              liveContext.encoderIdentity == identity,
              liveContext.formatIdentity == ObjectIdentifier(format) else {
            throw AACRenditionFailure.invalidInput
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0, byteCount <= 131_072 else {
            throw AACRenditionFailure.capacityExceeded
        }
        var frozenPayload = Data(count: byteCount)
        try frozenPayload.withUnsafeMutableBytes { bytes in
            try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: byteCount,
                destination: bytes.baseAddress!))
        }
        var descriptions: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionBytes = 0
        try AACRenditionEncoder.check(
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                sampleBuffer,
                packetDescriptionsPointerOut: &descriptions,
                sizeOut: &descriptionBytes))
        guard let descriptions,
              descriptionBytes == CMSampleBufferGetNumSamples(sampleBuffer)
                * MemoryLayout<AudioStreamPacketDescription>.stride else {
            throw AACRenditionFailure.invalidInput
        }
        guard frozenLease.bytes == (try Self.allocationCharge(
            payloadBytes: byteCount,
            packetCount: CMSampleBufferGetNumSamples(sampleBuffer))) else {
            throw AACRenditionFailure.capacityExceeded
        }
        func trim(_ key: CFString) -> CMTime? {
            guard let value = CMGetAttachment(sampleBuffer, key: key,
                                              attachmentModeOut: nil),
                  CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
            let dictionary = unsafeDowncast(value, to: NSDictionary.self)
            return CMTimeMakeFromDictionary(dictionary)
        }
        self.identity = identity
        self.ordinal = ordinal
        self.liveContextIdentity = liveContext.identity
        self.isFinalBuffer = isFinalBuffer
        self.bandwidth = bandwidth
        self.packetLease = packetLease
        self.formatLease = formatLease
        self.frozenLease = frozenLease
        frozenByteCount = byteCount
        self.liveContext = liveContext
        payload = frozenPayload as NSData
        self.format = format
        packetDescriptions = Array(
            UnsafeBufferPointer(start: descriptions,
                                count: CMSampleBufferGetNumSamples(sampleBuffer)))
        sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        outputPresentationTimeStamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        duration = CMSampleBufferGetDuration(sampleBuffer)
        leadingTrim = trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        trailingTrim = trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        var signed = try AACRenditionEncoder.emissionEvidence(sampleBuffer)
        for description in packetDescriptions {
            withUnsafeBytes(of: description.mStartOffset.bigEndian) {
                signed.append(contentsOf: $0)
            }
            withUnsafeBytes(of: description.mVariableFramesInPacket.bigEndian) {
                signed.append(contentsOf: $0)
            }
            withUnsafeBytes(of: description.mDataByteSize.bigEndian) {
                signed.append(contentsOf: $0)
            }
        }
        signed.append(Data(liveContext.identity.uuidString.utf8))
        withUnsafeBytes(of: ordinal.bigEndian) { signed.append(contentsOf: $0) }
        signed.append(isFinalBuffer ? 1 : 0)
        evidenceDigest = Data(SHA256.hash(data: signed))
    }

    static func allocationCharge(payloadBytes: Int, packetCount: Int) throws -> Int {
        let payload = payloadBytes.multipliedReportingOverflow(by: 3)
        let descriptions = packetCount.multipliedReportingOverflow(
            by: 3 * MemoryLayout<AudioStreamPacketDescription>.stride)
        let combined = payload.partialValue.addingReportingOverflow(
            descriptions.partialValue)
        let total = combined.partialValue.addingReportingOverflow(1_024)
        guard payloadBytes > 0, packetCount > 0,
              !payload.overflow, !descriptions.overflow,
              !combined.overflow, !total.overflow else {
            throw AACRenditionFailure.capacityExceeded
        }
        return total.partialValue
    }

    func materializeSampleBuffer() throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try AACRenditionEncoder.check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.length,
            flags: 0,
            blockBufferOut: &block))
        guard let block else { throw AACRenditionFailure.invalidInput }
        try AACRenditionEncoder.check(CMBlockBufferReplaceDataBytes(
            with: payload.bytes,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: payload.length))
        var buffer: CMSampleBuffer?
        try AACRenditionEncoder.check(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: sampleCount,
                presentationTimeStamp: presentationTimeStamp,
                packetDescriptions: packetDescriptions,
                sampleBufferOut: &buffer))
        guard let buffer else { throw AACRenditionFailure.invalidInput }
        if let leadingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(leadingTrim, allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let trailingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: CMTimeCopyAsDictionary(trailingTrim, allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
            buffer, newValue: outputPresentationTimeStamp))
        guard CMTimeCompare(CMSampleBufferGetDuration(buffer), duration) == 0 else {
            throw AACRenditionFailure.calibrationMismatch
        }
        return buffer
    }
}

/// 显式 EOS 自然 drain 后由同一个 converter 唯一签发。它只证明 encoder 输出，
/// writer/publication authority 仍必须由各自 owner 继续绑定。
final class AACEncoderFinalReceipt: @unchecked Sendable {
    let identity: AACEncoderIdentity
    let summary: AACStreamSummary
    let emissionCount: UInt64
    let cumulativeDigest: Data
    let finalEmission: AACFinalEmissionIdentity
    let liveContext: AACLiveEncodingContext

    fileprivate init(summary: AACStreamSummary, emissionCount: UInt64,
                     cumulativeDigest: Data, finalEmission: AACFinalEmissionIdentity,
                     liveContext: AACLiveEncodingContext) {
        identity = summary.identity
        self.summary = summary
        self.emissionCount = emissionCount
        self.cumulativeDigest = cumulativeDigest
        self.finalEmission = finalEmission
        self.liveContext = liveContext
    }

    func matches(emissions: [AACIncrementalEmission]) -> Bool {
        guard emissionCount > 0,
              UInt64(exactly: emissions.count) == emissionCount else { return false }
        var digest = AACRenditionEncoder.initialEmissionDigest
        for (index, emission) in emissions.enumerated() {
            guard emission.identity == identity,
                  emission.liveContextIdentity == liveContext.identity,
                  emission.ordinal == UInt64(index),
                  emission.isFinalBuffer == (index == emissions.count - 1) else {
                return false
            }
            digest = AACRenditionEncoder.foldEmissionDigest(
                digest, ordinal: emission.ordinal, evidence: emission.evidenceDigest)
        }
        return digest == cumulativeDigest
            && finalEmission.ordinal == emissionCount - 1
            && finalEmission.evidenceDigest == emissions.last?.evidenceDigest
            && finalEmission.isFinalBuffer
    }
}

struct AACStreamPumpResult {
    let needsInput: Bool
    let summary: AACStreamSummary?
    let finalReceipt: AACEncoderFinalReceipt?
    let waitingForWriter: Bool
    let waitingForEncoderBudget: Bool

    init(needsInput: Bool, summary: AACStreamSummary?,
         finalReceipt: AACEncoderFinalReceipt?, waitingForWriter: Bool = false,
         waitingForEncoderBudget: Bool = false) {
        self.needsInput = needsInput
        self.summary = summary
        self.finalReceipt = finalReceipt
        self.waitingForWriter = waitingForWriter
        self.waitingForEncoderBudget = waitingForEncoderBudget
    }
}
final class AACRenditionEncoder: @unchecked Sendable {
    static let maximumSignedPumpAllocationBytes =
        AACCalibrationWorkspace.aacPacketCapacity
    static let initialEmissionDigest = Data(SHA256.hash(
        data: Data("VPlayer.AACIncrementalEmission.v1".utf8)))

    static func foldEmissionDigest(
        _ previous: Data,
        ordinal: UInt64,
        evidence: Data
    ) -> Data {
        var input = previous
        withUnsafeBytes(of: ordinal.bigEndian) { input.append(contentsOf: $0) }
        input.append(evidence)
        return Data(SHA256.hash(data: input))
    }

    static func emissionEvidence(_ buffer: CMSampleBuffer) throws -> Data {
        guard CMSampleBufferIsValid(buffer),
              CMSampleBufferDataIsReady(buffer),
              let block = CMSampleBufferGetDataBuffer(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatMPEG4AAC else {
            throw AACRenditionFailure.invalidInput
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0, byteCount <= 131_072 else {
            throw AACRenditionFailure.capacityExceeded
        }
        var payload = Data(count: byteCount)
        let status = payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                       destination: $0.baseAddress!)
        }
        try check(status)
        var evidence = Data("VPlayer.AACIncrementalEmission.Buffer.v1".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { evidence.append(contentsOf: $0) }
        }
        func time(_ value: CMTime) throws {
            let exact = try ExactMediaTime(value)
            integer(exact.value)
            integer(exact.timescale)
        }
        evidence.append(Data(SHA256.hash(data: payload)))
        integer(asbd.mSampleRate.bitPattern)
        integer(asbd.mFormatID)
        integer(asbd.mFormatFlags)
        integer(asbd.mFramesPerPacket)
        integer(asbd.mChannelsPerFrame)
        integer(Int64(CMSampleBufferGetNumSamples(buffer)))
        try time(CMSampleBufferGetPresentationTimeStamp(buffer))
        try time(CMSampleBufferGetOutputPresentationTimeStamp(buffer))
        try time(CMSampleBufferGetDuration(buffer))
        for key in [kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    kCMSampleBufferAttachmentKey_TrimDurationAtEnd] {
            if let attachment = CMGetAttachment(buffer, key: key,
                                                attachmentModeOut: nil),
               CFGetTypeID(attachment) == CFDictionaryGetTypeID() {
                evidence.append(1)
                try time(CMTimeMakeFromDictionary((attachment as! CFDictionary)))
            } else {
                evidence.append(0)
            }
        }
        return Data(SHA256.hash(data: evidence))
    }

    let identity: AACEncoderIdentity
    private(set) var passSignatures: [AACFinalizedPassSignature] = []
    var finalCookie: Data { passSignatures.last?.finalizedCookie ?? Data() }
    var resetCookie: Data { resetEvidence?.cookie.data ?? Data() }
    private(set) var creationCookieDigest = Data()
    var resetCookieDigest: Data { Data(SHA256.hash(data: resetCookie)) }
    private(set) var leadingSampleCount = 0
    var terminalFailure: AACRenditionFailure? { presentationTerminal.failure }
    var mayPublishTailOrEndList: Bool { terminalFailure == nil && !lane.cancelRequested }
    let lane: AACOwnedCallLane
    let workspace: AACCalibrationWorkspace
    let presentationTerminal: AACPresentationTerminal
    private let stateLock = NSLock()
    private var baseEvidenceLease: AACCalibrationWorkspace.Lease?
    private var resetEvidence: ResetEvidence?
    private var creationFormat: ActualFormat?
    private(set) var finalizedCookieEvidence: AACMagicCookieEvidence?
    var retainedEvidenceBytes: Int {
        let baseBytes = baseEvidenceLease?.bytes ?? 0
        let resetCookieBytes = resetEvidence?.cookie.lease.bytes ?? 0
        let resetLayoutBytes = resetEvidence?.format.layoutBacking.lease.bytes ?? 0
        let finalizedCookieBytes = passSignatures.last?.cookieBacking.lease.bytes ?? 0
        let finalizedLayoutBytes = passSignatures.last?.layoutBacking.lease.bytes ?? 0
        let parsedBytes = finalizedCookieEvidence?.metadataLease.bytes ?? 0
        return baseBytes + resetCookieBytes + resetLayoutBytes + finalizedCookieBytes + finalizedLayoutBytes + parsedBytes
            + (creationFormat?.layoutBacking.lease.bytes ?? 0)
    }
    private var converter: AudioConverterRef?
    private var calibrated = false
    private var usedLiveEpoch = false
    private var liveRunning = false
    let observer: any AACCalibrationObserver

    init(identity: AACEncoderIdentity, lane: AACOwnedCallLane, workspace: AACCalibrationWorkspace,
         observer: any AACCalibrationObserver, presentationTerminal: AACPresentationTerminal) throws {
        self.identity = identity; self.lane = lane; self.workspace = workspace; self.observer = observer
        self.presentationTerminal = presentationTerminal
        guard identity.ordinal >= 0, identity.ordinal < identity.plan.entries.count,
              identity.plan.entries[identity.ordinal].request == identity.request else { throw AACRenditionFailure.invalidPlan }
        baseEvidenceLease = try workspace.acquire(.nonPayload, bytes: 8_192 + identity.request.inputCookie.count)
        var source = Self.pcmFormat(channels: identity.request.layout.labels.count)
        var destination = identity.request.outputASBD.native
        try lane.call { try Self.check(AudioConverterNew(&source, &destination, &converter)) }
        do {
            var layout = identity.request.layout.audioToolbox
            try property(kAudioConverterInputChannelLayout, value: &layout)
            try property(kAudioConverterOutputChannelLayout, value: &layout)
            var bitrate = identity.request.bitrate, prime = identity.request.primeMethod
            var bitrateMode = identity.request.bitrateControlMode
            try property(kAudioCodecPropertyBitRateControlMode, value: &bitrateMode)
            try property(kAudioConverterEncodeBitRate, value: &bitrate)
            do {
                try property(kAudioConverterPrimeMethod, value: &prime)
            } catch AACRenditionFailure.frameworkProperty(kAudioConverterErr_PropertyNotSupported, kAudioConverterPrimeMethod)
                where prime == kConverterPrimeMethod_Normal {
                // 48kHz PCM→AAC 没有 SRC；该 codec 不提供 SRC priming 属性。
                // 只允许正常模式，真实延迟仍必须由两次完整系统回环证明。
            }
            if !identity.request.inputCookie.isEmpty {
                try identity.request.inputCookie.withUnsafeBytes { data in
                    try lane.call { try Self.check(AudioConverterSetProperty(converter!, kAudioConverterDecompressionMagicCookie, UInt32(data.count), data.baseAddress!)) }
                }
            }
            creationFormat = try actualFormat(at: .creation)
            // provisional A 只用于证据，不能成为 final cookie。
            creationCookieDigest = Data(SHA256.hash(data: try cookie(at: .provisional).data))
        } catch { dispose(); throw error }
    }
    deinit { dispose() }

    func encodeEpoch(_ samples: [Float]) throws -> AACEncodedEpoch {
        var claimed = false
        do {
            try beginLive()
            claimed = true
            defer { stateLock.withLock { liveRunning = false } }
            try validateBeforeLive()
            let pass = try encodePass(samples)
            try validateLiveFinal(pass)
            let n = samples.count / identity.request.layout.labels.count
            return try makeEpoch(pass: pass, realFrames: n, leading: leadingSampleCount)
        } catch {
            if !claimed { throw error }
            presentationTerminal.fail((error as? AACRenditionFailure) ?? .calibrationMismatch)
            dispose()
            throw error
        }
    }
    func markVisible() { presentationTerminal.markVisible() }
    private final class StreamState {
        let sourceLease: AACCalibrationWorkspace.Lease
        let packetLease: AACCalibrationWorkspace.Lease
        let formatLease: AACCalibrationWorkspace.Lease
        let format: CMAudioFormatDescription
        let bandwidth: AACPayloadBandwidthWindow
        let input: AACStreamingPCMInput
        let frozen: AACFinalizedPassSignature
        let liveContext: AACLiveEncodingContext
        let maximumPacket: UInt32
        let tailCount: Int
        var pending: [Packet] = []
        var output: [UInt8]
        var q: Int64 = 0, emittedQ: Int64 = 0, maximumRetained = 0
        var firstEmitted = false
        var emissionCount: UInt64 = 0
        var cumulativeDigest = AACRenditionEncoder.initialEmissionDigest
        var lastEmissionEvidence: Data?
        init(encoder: AACRenditionEncoder, frozen: AACFinalizedPassSignature, maximumPacket: UInt32) throws {
            sourceLease = try encoder.workspace.acquire(.sourcePCM, bytes: 262_144)
            packetLease = try encoder.workspace.acquire(.aacPackets, bytes: 131_072)
            formatLease = try encoder.workspace.acquire(.nonPayload, bytes: 8_192 + frozen.finalizedCookie.count + frozen.actualLayout.count)
            format = try encoder.makeFormat(asbd: frozen.actualASBD, cookie: frozen.finalizedCookie)
            bandwidth = try AACPayloadBandwidthWindow(configuredBitrate: encoder.identity.request.bitrate, workspace: encoder.workspace)
            input = AACStreamingPCMInput(channels: encoder.identity.request.layout.labels.count, lane: encoder.lane)
            self.frozen = frozen; self.maximumPacket = maximumPacket
            liveContext = AACLiveEncodingContext(
                encoderIdentity: encoder.identity,
                format: format,
                calibratedLeadingFrames: encoder.leadingSampleCount)
            tailCount = Int((Int64(encoder.leadingSampleCount) + Int64(frozen.trailingPrimeFrames) + 1_023) / 1_024) + 2
            guard tailCount < 32, maximumPacket > 0, maximumPacket <= 65_536 else { throw AACRenditionFailure.capacityExceeded }
            pending.reserveCapacity(64)
            output = [UInt8](repeating: 0, count: Int(maximumPacket))
        }
    }
    private var stream: StreamState?

    // 每次只借用当前 PCM 块；暂缺输入返回有界暂停状态，只有显式 EOS 才执行 drain。
    // 生产者与 append 都运行在 Fill 之外，可在同一 owned runner 交替推进两个 rendition。
    func pumpSigned(
        _ offered: AACStreamPumpInput,
        append: (AACIncrementalEmission) throws -> Void
    ) throws -> AACStreamPumpResult {
        var claimed = false
        var fillBegan = false
        do {
            if stream == nil {
                try beginLive()
                claimed = true
                try validateBeforeLive()
                guard let frozen = passSignatures.last else { throw AACRenditionFailure.invalidInput }
                var maximumPacket: UInt32 = 0
                try query(kAudioConverterPropertyMaximumOutputPacketSize, into: &maximumPacket)
                stream = try StreamState(encoder: self, frozen: frozen, maximumPacket: maximumPacket)
            } else {
                try stateLock.withLock {
                    guard !liveRunning else { throw AACRenditionFailure.busy }
                    liveRunning = true
                }
                claimed = true
            }
            defer { stateLock.withLock { liveRunning = false } }
            guard mayPublishTailOrEndList, let state = stream else { throw terminalFailure ?? .cancelled }
            let pendingPayloadBytes = state.pending.reduce(0) { $0 + $1.data.count }
            let maximumNextPayload = pendingPayloadBytes.addingReportingOverflow(
                Int(state.maximumPacket))
            let maximumNextPackets = state.pending.count.addingReportingOverflow(1)
            guard !maximumNextPayload.overflow, !maximumNextPackets.overflow else {
                throw AACRenditionFailure.capacityExceeded
            }
            let firstFillCharge = try AACIncrementalEmission.allocationCharge(
                payloadBytes: maximumNextPayload.partialValue,
                packetCount: maximumNextPackets.partialValue)
                .addingReportingOverflow(1_024)
            guard !firstFillCharge.overflow,
                  firstFillCharge.partialValue
                    <= AACCalibrationWorkspace.aacPacketCapacity else {
                // StreamState 的 retained bound 应保证所有允许的 maximumPacket
                // 至少能完成一次 Fill；若数学上不成立是永久合同错误，不可重试。
                throw AACRenditionFailure.calibrationMismatch
            }
            let reservation: AACCalibrationWorkspace.Reservation
            do {
                reservation = try workspace.reserveAvailable(
                    .aacPackets,
                    preferredBytes: Self.maximumSignedPumpAllocationBytes,
                    minimumBytes: firstFillCharge.partialValue)
            } catch AACRenditionFailure.capacityExceeded {
                // 尚未接受输入、尚未 Fill；既有 writer ownership 退休后可由调用方
                // 原样重试，不能把暂时余额不足升级为 encoder 终态。
                throw AACRenditionFailure.budgetUnavailable
            }
            try state.input.offer(offered)
            if !state.input.hasInput, !state.input.ended {
                return AACStreamPumpResult(needsInput: true, summary: nil, finalReceipt: nil)
            }
            func emitPrefix(_ count: Int, endTrim: Int64 = 0,
                            isFinalBuffer: Bool = false) throws {
                guard mayPublishTailOrEndList else { throw terminalFailure ?? .cancelled }
                let packets = Array(state.pending.prefix(count))
                let payloadBytes = packets.reduce(0) { $0 + $1.data.count }
                let emissionLease = try reservation.claim(bytes:
                    AACIncrementalEmission.allocationCharge(
                        payloadBytes: payloadBytes,
                        packetCount: packets.count))
                let buffer = try makeBuffer(packets: Array(state.pending.prefix(count)), format: state.format, decodedStart: state.emittedQ,
                    leading: state.firstEmitted ? 0 : Int64(leadingSampleCount), trailing: endTrim,
                    epochLeading: Int64(leadingSampleCount), packetDuration: state.frozen.packetDuration)
                let ordinal = state.emissionCount
                let next = ordinal.addingReportingOverflow(1)
                guard !next.overflow else { throw AACRenditionFailure.capacityExceeded }
                let emission = try AACIncrementalEmission(
                    identity: identity,
                    ordinal: ordinal,
                    sampleBuffer: buffer,
                    isFinalBuffer: isFinalBuffer,
                    liveContext: state.liveContext,
                    bandwidth: state.bandwidth.evidence,
                    packetLease: state.packetLease,
                    formatLease: state.formatLease,
                    frozenLease: emissionLease)
                try append(emission)
                state.emissionCount = next.partialValue
                state.cumulativeDigest = Self.foldEmissionDigest(
                    state.cumulativeDigest,
                    ordinal: ordinal,
                    evidence: emission.evidenceDigest)
                state.lastEmissionEvidence = emission.evidenceDigest
                state.firstEmitted = true
                state.emittedQ += Int64(count) * 1_024
                state.pending.removeFirst(count)
            }
            // 一块最多 16384 frame，加上固定 priming/tail，32 次 Fill 是显式工作上限。
            for _ in 0..<32 {
                guard mayPublishTailOrEndList else { throw terminalFailure ?? .cancelled }
                let retainedPayload = state.pending.reduce(0) { $0 + $1.data.count }
                let possiblePayload = retainedPayload.addingReportingOverflow(
                    Int(state.maximumPacket))
                let possiblePackets = state.pending.count.addingReportingOverflow(1)
                guard !possiblePayload.overflow, !possiblePackets.overflow else {
                    throw AACRenditionFailure.capacityExceeded
                }
                let possibleCharge = try AACIncrementalEmission.allocationCharge(
                    payloadBytes: possiblePayload.partialValue,
                    packetCount: possiblePackets.partialValue)
                    .addingReportingOverflow(1_024)
                guard !possibleCharge.overflow else {
                    throw AACRenditionFailure.capacityExceeded
                }
                guard reservation.unclaimedBytes >= possibleCharge.partialValue else {
                    return AACStreamPumpResult(
                        needsInput: false,
                        summary: nil,
                        finalReceipt: nil,
                        waitingForEncoderBudget: true)
                }
                var count: UInt32 = 1, description = AudioStreamPacketDescription()
                fillBegan = true
                let status = try state.output.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(state.input.channels),
                        mDataByteSize: state.maximumPacket, mData: bytes.baseAddress))
                    return try lane.call {
                        AudioConverterFillComplexBuffer(converter!, aacStreamingPCMInput,
                            Unmanaged.passUnretained(state.input).toOpaque(), &count, &list, &description)
                    }
                }
                if let failure = state.input.failure { throw failure }
                let paused = status == AACStreamingPCMInput.needsInputStatus
                if paused {
                    guard !state.input.ended, !state.input.hasInput else { throw AACRenditionFailure.calibrationMismatch }
                    if count == 0 {
                        return AACStreamPumpResult(
                            needsInput: true, summary: nil, finalReceipt: nil)
                    }
                } else { try Self.check(status) }
                if count == 0 {
                    guard state.input.sawEOS, state.input.totalFrames > 0 else { throw AACRenditionFailure.invalidInput }
                    let final = Pass(identity: identity, packets: state.pending, cookieBacking: try cookie(at: .finalDrain),
                        format: try actualFormat(), packetLease: state.packetLease, bandwidth: state.bandwidth.evidence)
                    try validateLiveFinal(final)
                    let trailing = state.q - Int64(leadingSampleCount) - state.input.totalFrames
                    guard trailing >= 0, trailing < Int64(state.pending.count) * 1_024 else { throw AACRenditionFailure.calibrationMismatch }
                    if !state.firstEmitted {
                        let prefix = leadingSampleCount / 1_024 + 1
                        if state.pending.count > prefix, Int64(state.pending.count - prefix) * 1_024 > trailing { try emitPrefix(prefix) }
                    }
                    try emitPrefix(state.pending.count, endTrim: trailing,
                                   isFinalBuffer: true)
                    let summary = AACStreamSummary(identity: identity, realSampleCount: state.input.totalFrames, totalDecodedFrames: state.q,
                        leadingFrames: leadingSampleCount, trailingFrames: trailing, actualLeadingPrimeFrames: final.prime.leadingFrames,
                        actualTrailingPrimeFrames: final.prime.trailingFrames, maximumRetainedPackets: state.maximumRetained,
                        bandwidth: state.bandwidth.evidence)
                    guard state.emissionCount > 0,
                          let lastEmissionEvidence = state.lastEmissionEvidence else {
                        throw AACRenditionFailure.calibrationMismatch
                    }
                    let finalReceipt = AACEncoderFinalReceipt(
                        summary: summary,
                        emissionCount: state.emissionCount,
                        cumulativeDigest: state.cumulativeDigest,
                        finalEmission: AACFinalEmissionIdentity(
                            ordinal: state.emissionCount - 1,
                            evidenceDigest: lastEmissionEvidence,
                            isFinalBuffer: true),
                        liveContext: state.liveContext)
                    stream = nil
                    return AACStreamPumpResult(
                        needsInput: false,
                        summary: summary,
                        finalReceipt: finalReceipt)
                }
                guard count == 1, state.pending.count < 64, description.mStartOffset >= 0, description.mDataByteSize > 0,
                      UInt64(description.mStartOffset) + UInt64(description.mDataByteSize) <= state.maximumPacket,
                      description.mVariableFramesInPacket == 0 || description.mVariableFramesInPacket == 1_024 else { throw AACRenditionFailure.capacityExceeded }
                let retained = state.pending.reduce(Int(state.maximumPacket)) { $0 + 2 * ($1.data.count + MemoryLayout<AudioStreamPacketDescription>.stride) }
                guard retained + 2 * (Int(description.mDataByteSize) + MemoryLayout<AudioStreamPacketDescription>.stride) <= 131_072 else {
                    throw AACRenditionFailure.capacityExceeded
                }
                try state.bandwidth.append(payloadBytes: Int(description.mDataByteSize), packetFrames: 1_024)
                let offset = Int(description.mStartOffset)
                let data = Data(state.output[offset..<(offset + Int(description.mDataByteSize))])
                description.mStartOffset = 0
                state.pending.append(Packet(data: data, description: description))
                state.maximumRetained = max(state.maximumRetained, state.pending.count)
                let (next, overflow) = state.q.addingReportingOverflow(1_024)
                guard !overflow, next <= Int64.max - 480_000 else { throw AACRenditionFailure.capacityExceeded }
                state.q = next
                if !state.firstEmitted {
                    let prefix = leadingSampleCount / 1_024 + 1
                    if state.pending.count >= prefix + state.tailCount { try emitPrefix(prefix) }
                }
                while state.firstEmitted, state.pending.count > state.tailCount { try emitPrefix(1) }
                if paused {
                    return AACStreamPumpResult(needsInput: true, summary: nil, finalReceipt: nil)
                }
            }
            throw AACRenditionFailure.capacityExceeded
        } catch {
            if claimed {
                stateLock.withLock { liveRunning = false }
                if !fillBegan,
                   let failure = error as? AACRenditionFailure,
                   failure == .capacityExceeded || failure == .budgetUnavailable {
                    throw error
                }
                presentationTerminal.fail((error as? AACRenditionFailure) ?? .calibrationMismatch)
                dispose()
            }
            throw error
        }
    }

    func pump(
        _ offered: AACStreamPumpInput,
        append: (CMSampleBuffer) throws -> Void
    ) throws -> AACStreamPumpResult {
        try pumpSigned(offered) { try append($0.materializeSampleBuffer()) }
    }

    /// 校准完成后冻结的真实输出格式；writer 必须在首个增量 emission 前用同一
    /// cookie/ASBD 建立，不能从调用者声明反推。
    func incrementalFormatDescription() throws -> CMAudioFormatDescription {
        guard let signature = passSignatures.last,
              signature.identity == identity else {
            throw AACRenditionFailure.invalidInput
        }
        return try makeFormat(
            asbd: signature.actualASBD,
            cookie: signature.finalizedCookie)
    }
    func encodeStream(nextPCM: () throws -> [Float]?, append: (CMSampleBuffer) throws -> Void) throws -> AACStreamSummary {
        do {
            while true {
                guard mayPublishTailOrEndList else { throw terminalFailure ?? .cancelled }
                let offered = try nextPCM().map(AACStreamPumpInput.pcm) ?? .endOfStream
                if let summary = try pump(offered, append: append).summary { return summary }
            }
        } catch {
            presentationTerminal.fail((error as? AACRenditionFailure) ?? .calibrationMismatch)
            dispose()
            throw error
        }
    }
    private func beginLive() throws {
        try stateLock.withLock {
            if let failure = terminalFailure { throw failure }
            guard !liveRunning else { throw AACRenditionFailure.busy }
            guard calibrated, !usedLiveEpoch else { throw AACRenditionFailure.invalidInput }
            usedLiveEpoch = true
            liveRunning = true
        }
    }
    private func validateBeforeLive() throws {
        do {
            let before = try cookie(at: .beforeLive)
            guard before.data == resetCookie else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            guard let resetEvidence, try actualFormat(at: .beforeLive) == resetEvidence.format else { throw AACRenditionFailure.calibrationMismatch }
        } catch {
            presentationTerminal.fail((error as? AACRenditionFailure) ?? .calibrationMismatch)
            throw error
        }
    }
    static func validateCookieCapacity(_ size: Int) throws {
        guard size >= 0, size <= 524_288 else { throw AACRenditionFailure.capacityExceeded }
    }
    static func pcmFormat(channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }
    private func property<T>(_ key: AudioConverterPropertyID, value: inout T) throws {
        try withUnsafePointer(to: &value) { pointer in
            try lane.call { try Self.checkProperty(AudioConverterSetProperty(converter!, key, UInt32(MemoryLayout<T>.size), pointer), key: key) }
        }
    }
    private func query<T>(_ key: AudioConverterPropertyID, into value: inout T) throws {
        var size: UInt32 = 0
        try lane.call { try Self.checkProperty(AudioConverterGetPropertyInfo(converter!, key, &size, nil), key: key) }
        guard size == MemoryLayout<T>.size else { throw AACRenditionFailure.calibrationMismatch }
        try withUnsafeMutablePointer(to: &value) { pointer in
            try lane.call { try Self.checkProperty(AudioConverterGetProperty(converter!, key, &size, pointer), key: key) }
        }
        guard size == MemoryLayout<T>.size else { throw AACRenditionFailure.calibrationMismatch }
    }
    private func dataProperty(_ key: AudioConverterPropertyID) throws -> AACDataBacking {
        var size: UInt32 = 0
        try lane.call { try Self.checkProperty(AudioConverterGetPropertyInfo(converter!, key, &size, nil), key: key) }
        try Self.validateCookieCapacity(Int(size))
        let lease = try workspace.acquire(.nonPayload, bytes: Int(size))
        guard size > 0 else {
            var byte: UInt8 = 0
            try lane.call { try Self.checkProperty(AudioConverterGetProperty(converter!, key, &size, &byte), key: key) }
            guard size == 0 else { throw AACRenditionFailure.capacityExceeded }
            return AACDataBacking(data: Data(), lease: lease)
        }
        var result = Data(count: Int(size))
        let capacity = size
        try result.withUnsafeMutableBytes { bytes in
            try lane.call { try Self.checkProperty(AudioConverterGetProperty(converter!, key, &size, bytes.baseAddress!), key: key) }
        }
        guard size <= capacity else { throw AACRenditionFailure.capacityExceeded }
        result.count = Int(size)
        return AACDataBacking(data: result, lease: lease)
    }
    func cookie(at stage: AACCookieStage) throws -> AACDataBacking {
        let raw = try dataProperty(kAudioConverterCompressionMagicCookie)
        let value = observer.cookie(raw.data, at: stage)
        try Self.validateCookieCapacity(value.count)
        if value == raw.data { return raw }
        return AACDataBacking(data: value, lease: try workspace.acquire(.nonPayload, bytes: value.count))
    }
    func reset() throws { try lane.call { try Self.check(AudioConverterReset(converter!)) } }
    func dispose() {
        lane.cleanup { disposeWithBorrowedPermit() }
    }
    // 调用者已经持有唯一 permit，所有 backing 与 native 对象一起进入终态。
    func disposeWithBorrowedPermit() {
        guard let native = converter else { return }
        observer.willDispose()
        AudioConverterDispose(native)
        converter = nil
        stream = nil
        baseEvidenceLease = nil
        resetEvidence = nil
        creationFormat = nil
        passSignatures = []
        finalizedCookieEvidence = nil
        calibrated = false
    }
    static func check(_ status: OSStatus) throws { if status != noErr { throw AACRenditionFailure.framework(status) } }
    private static func checkProperty(_ status: OSStatus, key: UInt32) throws {
        if status != noErr { throw AACRenditionFailure.frameworkProperty(status, key) }
    }

    struct Pass {
        let identity: AACEncoderIdentity
        let packets: [Packet]
        let cookieBacking: AACDataBacking
        let format: ActualFormat
        let packetLease: AACCalibrationWorkspace.Lease
        let bandwidth: AACBandwidthEvidence
        var cookie: Data { cookieBacking.data }
        var asbd: AACASBD { format.asbd }
        var layout: Data { format.layoutBacking.data }
        var prime: AudioConverterPrimeInfo { AudioConverterPrimeInfo(leadingFrames: format.leadingPrimeFrames, trailingFrames: format.trailingPrimeFrames) }
        var packetDuration: UInt32 { format.asbd.framesPerPacket }
        var totalFrames: Int { packets.reduce(0) { $0 + Int($1.description.mVariableFramesInPacket == 0 ? packetDuration : $1.description.mVariableFramesInPacket) } }
    }
    struct ActualFormat: Hashable {
        let asbd: AACASBD
        let layoutBacking: AACDataBacking
        let leadingPrimeFrames: UInt32
        let trailingPrimeFrames: UInt32
    }
    struct ResetEvidence {
        let identity: AACEncoderIdentity
        let cookie: AACDataBacking
        let format: ActualFormat
    }
    struct Packet {
        let data: Data
        let description: AudioStreamPacketDescription
    }

    func encodePass(_ samples: [Float], cookieStage: AACCookieStage = .finalDrain,
                    sourceLease borrowedLease: AACCalibrationWorkspace.Lease? = nil, expectedStart: ActualFormat? = nil) throws -> Pass {
        let startStage: AACActualFormatStage
        let endStage: AACActualFormatStage
        if case .finalizedPass(let index) = cookieStage { startStage = .beforePass(index); endStage = .finalizedPass(index) }
        else { startStage = .beforeLive; endStage = .finalDrain }
        let before = try actualFormat(at: startStage)
        let expected = cookieStage.isLiveFinal ? resetEvidence?.format : expectedStart ?? creationFormat
        guard before == expected else { throw AACRenditionFailure.calibrationMismatch }
        let channels = identity.request.layout.labels.count
        guard !samples.isEmpty, samples.count % channels == 0, samples.count / channels <= 16_384,
              samples.count * 4 <= 524_288, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw AACRenditionFailure.invalidInput }
        let sourceLease = try borrowedLease ?? workspace.acquire(.sourcePCM, bytes: samples.count * 4)
        defer { withExtendedLifetime(sourceLease) {} }
        var maximumPacket: UInt32 = 0
        try query(kAudioConverterPropertyMaximumOutputPacketSize, into: &maximumPacket)
        guard maximumPacket > 0, maximumPacket <= 524_288 else { throw AACRenditionFailure.capacityExceeded }
        let packetLease = try workspace.acquire(.aacPackets, bytes: 524_288)
        let bandwidth = try AACPayloadBandwidthWindow(configuredBitrate: identity.request.bitrate, workspace: workspace)
        var packets: [Packet] = []; packets.reserveCapacity(64)
        var totalBytes = Int(maximumPacket)
        try samples.withUnsafeBufferPointer { source in
            let input = AACPCMInput(pointer: source.baseAddress!, frames: samples.count / channels, channels: channels)
            let opaque = Unmanaged.passUnretained(input).toOpaque()
            var output = [UInt8](repeating: 0, count: Int(maximumPacket))
            while true {
                var count: UInt32 = 1
                var description = AudioStreamPacketDescription()
                try output.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: maximumPacket, mData: bytes.baseAddress))
                    try lane.call {
                        try Self.check(AudioConverterFillComplexBuffer(converter!, aacPCMInput, opaque, &count, &list, &description))
                    }
                }
                if count == 0 { break }
                guard count == 1, packets.count < 64, description.mStartOffset >= 0,
                      description.mDataByteSize > 0,
                      UInt64(description.mStartOffset) + UInt64(description.mDataByteSize) <= maximumPacket else { throw AACRenditionFailure.capacityExceeded }
                // 原 AU 与 CoreMedia backing 在物化时短暂并存，预先按两份物理存储计入上限。
                totalBytes += 2 * (Int(description.mDataByteSize) + MemoryLayout<AudioStreamPacketDescription>.stride)
                guard totalBytes <= 524_288 else { throw AACRenditionFailure.capacityExceeded }
                let offset = Int(description.mStartOffset)
                try bandwidth.append(payloadBytes: Int(description.mDataByteSize), packetFrames: description.mVariableFramesInPacket == 0 ? 1_024 : description.mVariableFramesInPacket)
                let data = Data(output[offset..<(offset + Int(description.mDataByteSize))])
                description.mStartOffset = 0
                packets.append(Packet(data: data, description: description))
            }
            guard input.offset == input.frames, input.sawEOS else { throw AACRenditionFailure.calibrationMismatch }
        }
        let format = try actualFormat(at: endStage)
        let cookie = try cookie(at: cookieStage)
        guard !cookie.data.isEmpty else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        guard packets.allSatisfy({
            $0.description.mVariableFramesInPacket == 0 || $0.description.mVariableFramesInPacket == format.asbd.framesPerPacket
        }) else { throw AACRenditionFailure.calibrationMismatch }
        return Pass(identity: identity, packets: packets, cookieBacking: cookie, format: format, packetLease: packetLease, bandwidth: bandwidth.evidence)
    }
    private func actualFormat(at stage: AACActualFormatStage = .finalDrain) throws -> ActualFormat {
        var actual = AudioStreamBasicDescription(), prime = AudioConverterPrimeInfo()
        try query(kAudioConverterCurrentOutputStreamDescription, into: &actual)
        try query(kAudioConverterPrimeInfo, into: &prime)
        let layout = try dataProperty(kAudioConverterOutputChannelLayout)
        let result = ActualFormat(asbd: AACASBD(actual), layoutBacking: layout,
            leadingPrimeFrames: prime.leadingFrames, trailingPrimeFrames: prime.trailingFrames)
        observer.observedFormat(result)
        guard actual.mSampleRate == 48_000, actual.mFormatID == kAudioFormatMPEG4AAC,
              actual.mChannelsPerFrame == identity.request.layout.labels.count, actual.mFramesPerPacket == 1_024,
              actual.mFormatFlags == 0,
              layout.data.count >= MemoryLayout<AudioToolbox.AudioChannelLayout>.size else { throw AACRenditionFailure.calibrationMismatch }
        let actualTag = layout.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard actualTag == identity.request.layout.tag else { throw AACRenditionFailure.calibrationMismatch }
        let observed = observer.actualFormat(result, at: stage)
        if let creationFormat {
            guard observed.asbd == creationFormat.asbd, observed.layoutBacking == creationFormat.layoutBacking,
                  observed.leadingPrimeFrames == creationFormat.leadingPrimeFrames else { throw AACRenditionFailure.calibrationMismatch }
            // creation trailing=0，EOS trailing 与输入 N 有关；只在同类阶段完整比较。
        }
        return observed
    }

    func signature(pass: Pass, leading: Int) -> AACFinalizedPassSignature {
        AACFinalizedPassSignature(identity: pass.identity, actualASBD: pass.asbd, layout: identity.request.layout, layoutBacking: pass.format.layoutBacking,
            leadingPrimeFrames: pass.prime.leadingFrames, trailingPrimeFrames: pass.prime.trailingFrames,
            packetDuration: pass.packetDuration, cookieBacking: pass.cookieBacking,
            totalDecodedFrames: pass.totalFrames, decodedLeadingSampleCount: leading)
    }
    func readResetEvidence(index: Int) throws -> ResetEvidence {
        ResetEvidence(identity: identity, cookie: try cookie(at: .afterReset(index)), format: try actualFormat(at: .afterReset(index)))
    }
    func finalize(first: AACFinalizedPassSignature, second: AACFinalizedPassSignature, firstReset: ResetEvidence) throws {
        guard first.identity == identity, second.identity == identity, firstReset.identity == identity else { throw AACRenditionFailure.invalidPlan }
        guard first == second else {
            if first.finalizedCookie != second.finalizedCookie { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            throw AACRenditionFailure.calibrationMismatch
        }
        try reset()
        let secondReset = try readResetEvidence(index: 2)
        guard firstReset.cookie.data == secondReset.cookie.data else {
            throw AACRenditionFailure.aacEncoderCookieInvariantViolation
        }
        guard firstReset.format == secondReset.format else { throw AACRenditionFailure.calibrationMismatch }
        // 两份签名共用最终不可变 cookie backing，不保留第一 pass 的第二份副本。
        passSignatures = [second,second]
        finalizedCookieEvidence = try AACMagicCookieEvidence(backing: second.cookieBacking,
            configuredBitrate: identity.request.bitrate, workspace: workspace)
        resetEvidence = secondReset
        leadingSampleCount = second.decodedLeadingSampleCount; calibrated = true
    }
    private func validateLiveFinal(_ pass: Pass) throws {
        guard pass.identity == identity, let signature = passSignatures.last else { throw AACRenditionFailure.invalidPlan }
        guard let finalizedCookieEvidence else { throw AACRenditionFailure.invalidPlan }
        let live = try AACMagicCookieEvidence(backing: pass.cookieBacking, configuredBitrate: identity.request.bitrate, workspace: workspace)
        try finalizedCookieEvidence.validateLive(live)
        guard pass.asbd == signature.actualASBD, pass.layout == signature.actualLayout,
              pass.prime.leadingFrames == signature.leadingPrimeFrames,
              pass.packetDuration == signature.packetDuration else { throw AACRenditionFailure.calibrationMismatch }
        // trailing prime 随本 epoch 的 N 变化，只记录实际值；P 仍由 Q-L-N 推导。
    }
    func makeFormat(asbd: AACASBD, cookie: Data) throws -> CMAudioFormatDescription {
        var native = asbd.native, layout = identity.request.layout.audioToolbox
        var format: CMAudioFormatDescription?
        try cookie.withUnsafeBytes { bytes in
            try Self.check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &native,
                layoutSize: MemoryLayout<AudioToolbox.AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: bytes.count, magicCookie: bytes.baseAddress, extensions: nil, formatDescriptionOut: &format))
        }
        guard let format else { throw AACRenditionFailure.calibrationMismatch }
        return format
    }

    private func makeBuffer(packets: [Packet], format: CMAudioFormatDescription, decodedStart: Int64,
                            leading: Int64, trailing: Int64, epochLeading: Int64, packetDuration: UInt32) throws -> CMSampleBuffer {
        guard !packets.isEmpty, packets.count <= 64 else { throw AACRenditionFailure.capacityExceeded }
        let packetBytes = packets.reduce(0) { $0 + $1.data.count }
        let frames = packets.reduce(Int64(0)) { $0 + Int64($1.description.mVariableFramesInPacket == 0 ? packetDuration : $1.description.mVariableFramesInPacket) }
        guard leading >= 0, trailing >= 0, leading + trailing <= frames else { throw AACRenditionFailure.calibrationMismatch }
        var block: CMBlockBuffer?
        try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: packetBytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: packetBytes, flags: 0, blockBufferOut: &block))
        guard let block else { throw AACRenditionFailure.calibrationMismatch }
        var descriptions: [AudioStreamPacketDescription] = []; descriptions.reserveCapacity(packets.count)
        var offset = 0
        for packet in packets {
            try packet.data.withUnsafeBytes { bytes in
                try Self.check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: offset, dataLength: bytes.count))
            }
            var description = packet.description; description.mStartOffset = Int64(offset)
            descriptions.append(description); offset += packet.data.count
        }
        let pts = CMTime(value: 480_000 + decodedStart - epochLeading, timescale: 48_000)
        var buffer: CMSampleBuffer?
        try Self.check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: packets.count,
            presentationTimeStamp: pts, packetDescriptions: descriptions, sampleBufferOut: &buffer))
        guard let buffer else { throw AACRenditionFailure.calibrationMismatch }
        if leading > 0 {
            CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(CMTime(value: leading, timescale: 48_000), allocator: kCFAllocatorDefault)!, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if trailing > 0 {
            CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: CMTimeCopyAsDictionary(CMTime(value: trailing, timescale: 48_000), allocator: kCFAllocatorDefault)!, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        try Self.check(CMSampleBufferSetOutputPresentationTimeStamp(buffer,
            newValue: leading > 0 ? CMTime(value: 10, timescale: 1) : pts))
        return buffer
    }

    func makeEpoch(pass: Pass, realFrames: Int, leading: Int) throws -> AACEncodedEpoch {
        guard pass.identity == identity else { throw AACRenditionFailure.invalidPlan }
        let trailing = pass.totalFrames - leading - realFrames
        guard leading >= 0, trailing >= 0, !pass.packets.isEmpty else { throw AACRenditionFailure.calibrationMismatch }
        let formal = calibrated ? passSignatures.last : nil
        let cookieBytes = formal?.finalizedCookie ?? pass.cookie
        let formatLease = try workspace.acquire(.nonPayload, bytes: 1_024 + cookieBytes.count + pass.layout.count)
        var asbd = (formal?.actualASBD ?? pass.asbd).native, layout = identity.request.layout.audioToolbox
        var format: CMAudioFormatDescription?
        try cookieBytes.withUnsafeBytes { cookie in
            try Self.check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioToolbox.AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: cookie.count, magicCookie: cookie.baseAddress, extensions: nil, formatDescriptionOut: &format))
        }
        guard let format else { throw AACRenditionFailure.calibrationMismatch }
        var groups: [Range<Int>] = []
        var prefix = 0, prefixFrames = 0
        while prefix < pass.packets.count, prefixFrames <= leading {
            prefixFrames += Int(pass.packets[prefix].description.mVariableFramesInPacket == 0 ? pass.packetDuration : pass.packets[prefix].description.mVariableFramesInPacket)
            prefix += 1
        }
        guard prefixFrames > leading else { throw AACRenditionFailure.calibrationMismatch }
        groups.append(0..<prefix)
        for index in prefix..<pass.packets.count { groups.append(index..<(index + 1)) }
        // 尾端全 trim 的 AU 与其前一 buffer 合并，短 epoch 自然首尾共用。
        while groups.count > 1 {
            let lastFrames = groups.last!.reduce(0) { $0 + Int(pass.packets[$1].description.mVariableFramesInPacket == 0 ? pass.packetDuration : pass.packets[$1].description.mVariableFramesInPacket) }
            if lastFrames > trailing { break }
            let end = groups.removeLast().upperBound
            let start = groups.removeLast().lowerBound
            groups.append(start..<end)
        }
        var buffers: [CMSampleBuffer] = []; buffers.reserveCapacity(groups.count)
        var q = 0
        for (index, range) in groups.enumerated() {
            let packetBytes = range.reduce(0) { $0 + pass.packets[$1].data.count }
            var block: CMBlockBuffer?
            try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: packetBytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: packetBytes, flags: 0, blockBufferOut: &block))
            guard let block else { throw AACRenditionFailure.calibrationMismatch }
            var descriptions: [AudioStreamPacketDescription] = []; var offset = 0; var frames = 0
            for packetIndex in range {
                let packet = pass.packets[packetIndex]
                try packet.data.withUnsafeBytes { bytes in
                    try Self.check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: bytes.count))
                }
                var description = packet.description; description.mStartOffset = Int64(offset)
                descriptions.append(description); offset += packet.data.count
                frames += Int(description.mVariableFramesInPacket == 0 ? pass.packetDuration : description.mVariableFramesInPacket)
            }
            let startTrim = index == 0 ? leading : 0
            let endTrim = index == groups.count - 1 ? trailing : 0
            guard startTrim + endTrim <= frames else { throw AACRenditionFailure.calibrationMismatch }
            var buffer: CMSampleBuffer?
            let pts = CMTime(value: 480_000 + Int64(q - leading), timescale: 48_000)
            try Self.check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                dataBuffer: block, formatDescription: format, sampleCount: range.count,
                presentationTimeStamp: pts, packetDescriptions: descriptions, sampleBufferOut: &buffer))
            guard let buffer else { throw AACRenditionFailure.calibrationMismatch }
            if startTrim > 0 {
                CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    value: CMTimeCopyAsDictionary(CMTime(value: Int64(startTrim), timescale: 48_000), allocator: kCFAllocatorDefault)!, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            if endTrim > 0 {
                CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                    value: CMTimeCopyAsDictionary(CMTime(value: Int64(endTrim), timescale: 48_000), allocator: kCFAllocatorDefault)!, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            try Self.check(CMSampleBufferSetOutputPresentationTimeStamp(buffer, newValue: index == 0 ? CMTime(value: 10, timescale: 1) : pts))
            buffers.append(buffer); q += frames
        }
        return AACEncodedEpoch(identity: identity, buffers: buffers, realSampleCount: realFrames,
            totalDecodedFrames: pass.totalFrames, leadingFrames: leading, trailingFrames: trailing,
            actualLeadingPrimeFrames: pass.prime.leadingFrames, actualTrailingPrimeFrames: pass.prime.trailingFrames,
            bandwidth: pass.bandwidth, packetLease: pass.packetLease, formatLease: formatLease)
    }
}

private final class AACPCMInput {
    let pointer: UnsafePointer<Float>
    let frames: Int
    let channels: Int
    var offset = 0
    var sawEOS = false
    init(pointer: UnsafePointer<Float>, frames: Int, channels: Int) { self.pointer = pointer; self.frames = frames; self.channels = channels }
}

private final class AACStreamingPCMInput {
    static let needsInputStatus: OSStatus = 0x76706E69
    let channels: Int
    let lane: AACOwnedCallLane
    var current: NSData?
    var offset = 0
    var totalFrames: Int64 = 0
    var ended = false
    var sawEOS = false
    var failure: Error?
    var hasInput: Bool { current != nil }
    init(channels: Int, lane: AACOwnedCallLane) { self.channels = channels; self.lane = lane }
    func offer(_ input: AACStreamPumpInput) throws {
        guard !lane.cancelRequested else { throw AACRenditionFailure.cancelled }
        switch input {
        case .unavailable: return
        case .endOfStream:
            guard current == nil, !ended else { throw AACRenditionFailure.invalidInput }
            ended = true
        case .pcm(let samples):
            guard current == nil, !ended else { throw AACRenditionFailure.busy }
            guard !samples.isEmpty, samples.count % channels == 0, samples.count / channels <= 16_384,
                  samples.count <= 32_768, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw AACRenditionFailure.invalidInput }
            let (next, overflow) = totalFrames.addingReportingOverflow(Int64(samples.count / channels))
            guard !overflow else { throw AACRenditionFailure.capacityExceeded }
            // 两个 rendition 各自最多 256KiB，包含调用者数组与稳定 callback backing。
            current = samples.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress!, length: samples.count * 4) }
            offset = 0; totalFrames = next
        }
    }
    func provide(_ requested: Int) throws -> (pointer: UnsafeMutableRawPointer?, frames: Int) {
        guard !lane.cancelRequested else { throw AACRenditionFailure.cancelled }
        if let current, offset == current.length / (channels * 4) { self.current = nil; offset = 0 }
        guard let current else {
            if ended { sawEOS = true }
            return (nil, 0)
        }
        guard requested > 0 else { throw AACRenditionFailure.invalidInput }
        let frames = min(requested, current.length / (channels * 4) - offset)
        let pointer = UnsafeMutableRawPointer(mutating: current.bytes.advanced(by: offset * channels * 4))
        offset += frames
        return (pointer, frames)
    }
}
private func aacStreamingPCMInput(_ converter: AudioConverterRef, _ count: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>, _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { count.pointee = 0; return kAudio_ParamError }
    let input = Unmanaged<AACStreamingPCMInput>.fromOpaque(context).takeUnretainedValue()
    do {
        let result = try input.provide(Int(count.pointee))
        count.pointee = UInt32(result.frames)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(input.channels),
            mDataByteSize: UInt32(result.frames * input.channels * 4), mData: result.pointer)
        descriptions?.pointee = nil
        return result.frames == 0 && !input.ended ? AACStreamingPCMInput.needsInputStatus : noErr
    } catch {
        input.failure = error; count.pointee = 0; return kAudio_ParamError
    }
}

private func aacPCMInput(_ converter: AudioConverterRef, _ count: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>, _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { count.pointee = 0; return kAudio_ParamError }
    let input = Unmanaged<AACPCMInput>.fromOpaque(context).takeUnretainedValue()
    let frames = min(Int(count.pointee), input.frames - input.offset)
    count.pointee = UInt32(frames)
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(input.channels), mDataByteSize: UInt32(frames * input.channels * 4),
        mData: frames == 0 ? nil : UnsafeMutableRawPointer(mutating: input.pointer.advanced(by: input.offset * input.channels)))
    input.offset += frames
    if frames == 0 { input.sawEOS = true }
    descriptions?.pointee = nil
    return noErr
}
