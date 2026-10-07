// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers
import VPlayerCore

struct HLSVideoRemuxWriterMaterializationAuthority: Sendable {
    let binding: FMP4WriterBinding

    fileprivate init(binding: FMP4WriterBinding) { self.binding = binding }
}

/// writer 创建后只允许私有系统 adapter 一次绑定；factory/proxy 不能签发或替换 session。
final class SegmentedFMP4CallbackContext: @unchecked Sendable {
    let binding: FMP4WriterBinding
    let session: SegmentBoundarySession
    private let sourceIdentity: ObjectIdentifier
    private let lock = NSLock()
    private var adapterIdentity: ObjectIdentifier?
    private var writerIdentity: ObjectIdentifier?
    private weak var relay: SegmentReportRelay?
    private var terminal = false
    fileprivate init(binding: FMP4WriterBinding, session: SegmentBoundarySession, source: CMFormatDescription,
                     relay: SegmentReportRelay) {
        self.binding = binding; self.session = session; sourceIdentity = ObjectIdentifier(source); self.relay = relay
    }
    fileprivate func bind(adapter: AnyObject, writer: ObjectIdentifier, source: CMFormatDescription) throws {
        try lock.withLock {
            guard adapterIdentity == nil, sourceIdentity == ObjectIdentifier(source) else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
            adapterIdentity = ObjectIdentifier(adapter); writerIdentity = writer
        }
    }
    fileprivate var isBound: Bool { lock.withLock { adapterIdentity != nil } }
    fileprivate func accepts(adapter: any SegmentedFMP4SystemWriting, writer: ObjectIdentifier) -> Bool {
        lock.withLock { adapterIdentity == ObjectIdentifier(adapter) && writerIdentity == writer }
    }
    func belongs(to relay: SegmentReportRelay) -> Bool {
        lock.withLock { self.relay === relay && adapterIdentity != nil }
    }
    var isTerminal: Bool { lock.withLock { terminal } }
    fileprivate func markTerminal() { lock.withLock { terminal = true } }
}

/// 私有 delegate 对原始 callback 签发；消费后丢弃原始 backing，只留下固定大小事实。
final class SegmentedFMP4SystemCallbackCapsule: @unchecked Sendable {
    private let lock = NSLock()
    private let context: SegmentedFMP4CallbackContext
    private let writerIdentity: ObjectIdentifier
    private let type: AVAssetSegmentType
    private let report: SegmentedFMP4SystemReportEvidence
    private let digest: Data
    private let format: SegmentedFMP4FrozenFormat?
    private var originalBytes: Data?
    fileprivate init(context: SegmentedFMP4CallbackContext, writer: ObjectIdentifier, bytes: Data,
                     type: AVAssetSegmentType, report: SegmentedFMP4SystemReportEvidence, source: CMFormatDescription) {
        self.context = context; writerIdentity = writer; self.type = type; self.report = report
        digest = Data(SHA256.hash(data: bytes)); originalBytes = bytes
        format = SegmentedFMP4FrozenFormat(source)
    }
    fileprivate func consume(context expected: SegmentedFMP4CallbackContext, adapter: any SegmentedFMP4SystemWriting,
                             writer: ObjectIdentifier, bytes: Data, type: AVAssetSegmentType,
                             report: SegmentedFMP4SystemReportEvidence) -> (Data, SegmentedFMP4FrozenFormat?)? {
        lock.withLock {
            guard context === expected, context.accepts(adapter: adapter, writer: writer), writerIdentity == writer,
                  self.type == type, let originalBytes, originalBytes.count == bytes.count,
                  digest == Data(SHA256.hash(data: bytes)), report.callbackCapsule === self,
                  self.report.systemReport === report.systemReport,
                  self.report.systemProvenance === report.systemProvenance,
                  self.report.mediaType == report.mediaType,
                  self.report.hasUniqueMatchingTrack == report.hasUniqueMatchingTrack,
                  sameTime(self.report.earliestPresentationTimeStamp, report.earliestPresentationTimeStamp),
                  sameTime(self.report.duration, report.duration) else { return nil }
            self.originalBytes = nil
            return (originalBytes, format)
        }
    }
    private func sameTime(_ lhs: CMTime?, _ rhs: CMTime?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.some(lhs), .some(rhs)):
            return lhs.value == rhs.value && lhs.timescale == rhs.timescale && lhs.flags == rhs.flags && lhs.epoch == rhs.epoch
        default: return false
        }
    }
}

/// 从 writer 冻结的系统格式描述读取，不从 playlist 声明或最终 MP4 深解析反推。
struct SegmentedFMP4FrozenFormat: Sendable, Equatable {
    let codec: String
    let sampleEntry: FourCharCode
    let channels: Int
    let sampleRate: UInt32
    let width: Int
    let height: Int
    let lumaBitDepth: UInt8
    let chromaBitDepth: UInt8
    let videoRange: String
    let configurationDigest: Data
    fileprivate init?(_ format: CMFormatDescription) {
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
            sampleEntry = CMFormatDescriptionGetMediaSubType(format)
            width = 0; height = 0
            lumaBitDepth = 0; chromaBitDepth = 0
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
            channels = Int(asbd.mChannelsPerFrame)
            guard asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
                  asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
                  asbd.mSampleRate <= Double(UInt32.max) else { return nil }
            sampleRate = UInt32(asbd.mSampleRate)
            var cookieSize = 0
            guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize),
                  cookieSize > 0, cookieSize <= 65_536 else { return nil }
            configurationDigest = Data(SHA256.hash(data: Data(bytes: cookie, count: cookieSize)))
            switch asbd.mFormatID {
            case kAudioFormatMPEG4AAC: codec = "mp4a.40.2"
            case kAudioFormatAC3: codec = "ac-3"
            case kAudioFormatEnhancedAC3: codec = "ec-3"
            default: return nil
            }
            videoRange = ""
        } else {
            sampleEntry = CMFormatDescriptionGetMediaSubType(format)
            width = Int(CMVideoFormatDescriptionGetDimensions(format).width)
            height = Int(CMVideoFormatDescriptionGetDimensions(format).height)
            channels = 0
            sampleRate = 0
            guard let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] else { return nil }
            if let avc = atoms["avcC"] as? Data, avc.count >= 4 {
                configurationDigest = Data(SHA256.hash(data: avc))
                codec = String(format: "avc1.%02X%02X%02X", avc[1], avc[2], avc[3]).lowercased()
                lumaBitDepth = 8; chromaBitDepth = 8
            } else if let hevc = atoms["hvcC"] as? Data, hevc.count >= 19,
                      hevc[17] & 0xF8 == 0xF8, hevc[18] & 0xF8 == 0xF8 {
                configurationDigest = Data(SHA256.hash(data: hevc))
                lumaBitDepth = 8 + (hevc[17] & 0x07)
                chromaBitDepth = 8 + (hevc[18] & 0x07)
                let space = ["", "A", "B", "C"][Int(hevc[1] >> 6)]
                let flags = hevc[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                var reversed: UInt32 = 0
                for bit in 0..<32 { reversed |= ((flags >> bit) & 1) << (31 - bit) }
                var constraints = Array(hevc[6..<12])
                while constraints.last == 0 { constraints.removeLast() }
                codec = "hvc1.\(space)\(hevc[1] & 31).\(String(reversed, radix: 16).uppercased()).\(hevc[1] & 32 == 0 ? "L" : "H")\(hevc[12])"
                    + constraints.map { String(format: ".%02X", $0) }.joined()
            } else { return nil }
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { videoRange = "PQ" }
            else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { videoRange = "HLG" }
            else { videoRange = "SDR" }
        }
    }

    /// 跨 MediaEpoch 只冻结 item 选择属性；decoder configuration 由新 init 单独封存。
    func hasSameItemSelection(as other: Self) -> Bool {
        codec == other.codec
            && sampleEntry == other.sampleEntry
            && channels == other.channels
            && sampleRate == other.sampleRate
            && width == other.width
            && height == other.height
            && lumaBitDepth == other.lumaBitDepth
            && chromaBitDepth == other.chromaBitDepth
            && videoRange == other.videoRange
    }
}

/// 真实系统 callback 的唯一封存点；绑定正式 committed boundary、冻结格式与准确 callback 字节。
/// Only an actual writer constructor, after frozen-mode and continuation checks,
/// can issue this origin. No raw Data or absent encoded evidence can create it.
final class SourceAACWriterOrigin: @unchecked Sendable {
    let identity = UUID()
    let authority: SourceAACRenditionAuthority
    let binding: FMP4WriterBinding
    let predecessorBinding: FMP4WriterBinding?
    fileprivate init(authority: SourceAACRenditionAuthority, binding: FMP4WriterBinding,
                     predecessor: FMP4WriterBinding?) {
        self.authority = authority; self.binding = binding; predecessorBinding = predecessor
    }
}

final class SegmentedFMP4PublicationEvidence: @unchecked Sendable {
    let format: SegmentedFMP4FrozenFormat
    let boundary: SegmentCommittedBoundary?
    let session: SegmentBoundarySession
    let frameDuration: ExactMediaTime?
    let writerSource: SegmentedFMP4CallbackContext
    fileprivate(set) var sourceAAC: SourceAACCallbackEvidence?
    fileprivate(set) var dolbyInitialization: DolbyWriterInitializationEvidence?
    private let binding: FMP4WriterBinding
    private let callback: SegmentCallbackTicket
    private let kind: SealedMediaObjectKind
    private let sequence: UInt64
    private let reportIdentity: UUID
    private let digest: Data
    fileprivate init(format: SegmentedFMP4FrozenFormat, boundary: SegmentCommittedBoundary?,
                     session: SegmentBoundarySession, frameDuration: ExactMediaTime?, binding: FMP4WriterBinding,
                     callback: SegmentCallbackTicket, kind: SealedMediaObjectKind, sequence: UInt64,
                     reportIdentity: UUID, bytes: Data, writerSource: SegmentedFMP4CallbackContext) {
        self.format = format; self.boundary = boundary; self.session = session; self.frameDuration = frameDuration
        self.binding = binding; self.callback = callback; self.kind = kind; self.sequence = sequence
        self.reportIdentity = reportIdentity; digest = Data(SHA256.hash(data: bytes))
        self.writerSource = writerSource
    }
    func matches(_ object: SealedMediaObject) -> Bool {
        object.binding == binding && object.callbackTicket == callback && object.kind == kind
            && object.logicalSequence == sequence && object.report.identity == reportIdentity && object.digest == digest
    }
}

struct SegmentedFMP4SystemConfiguration: @unchecked Sendable {
    // 仅视频使用：90k/48k 与常用整帧、1001 系帧时长均可精确表达；音频保持原生尺度。
    let videoMediaTimeScale: CMTimeScale = 720_000
    let contentTypeIdentifier: String
    let outputFileTypeProfile: String
    let preferredOutputSegmentInterval: CMTime
    let mediaType: AVMediaType
    let outputSettingsAreNil: Bool
    let sourceFormatHintIdentity: ObjectIdentifier?
    let inputCount: Int
    let callbackContext: SegmentedFMP4CallbackContext?
    let initialMovieFragmentSequenceNumber: Int
    let producesCombinableFragments = true
    init(contentTypeIdentifier: String, outputFileTypeProfile: String, preferredOutputSegmentInterval: CMTime,
         mediaType: AVMediaType, outputSettingsAreNil: Bool, sourceFormatHintIdentity: ObjectIdentifier?, inputCount: Int,
         callbackContext: SegmentedFMP4CallbackContext? = nil,
         initialMovieFragmentSequenceNumber: Int = 1) {
        self.contentTypeIdentifier = contentTypeIdentifier; self.outputFileTypeProfile = outputFileTypeProfile
        self.preferredOutputSegmentInterval = preferredOutputSegmentInterval; self.mediaType = mediaType
        self.outputSettingsAreNil = outputSettingsAreNil; self.sourceFormatHintIdentity = sourceFormatHintIdentity
        self.inputCount = inputCount; self.callbackContext = callbackContext
        self.initialMovieFragmentSequenceNumber = initialMovieFragmentSequenceNumber
    }
}

protocol SegmentedFMP4SystemCallbackSink: AnyObject, Sendable {
    func receiveSystemSegment(
        writerObjectIdentity: ObjectIdentifier,
        bytes: Data,
        type: AVAssetSegmentType,
        report: SegmentedFMP4SystemReportEvidence
    )
}

protocol SegmentedFMP4SystemWriting: AnyObject, Sendable {
    var objectIdentity: ObjectIdentifier { get }
    var failureDiagnostic: ErrorDiagnosticSnapshot? { get }
    func startWriting(at sourceTime: CMTime) -> Bool
    func appendAwaitingReadiness(
        _ sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    ) async throws
    func flushSegment() -> Bool
    func markInputAsFinished()
    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void)
    func cancelWriting()
}

extension SegmentedFMP4SystemWriting {
    var failureDiagnostic: ErrorDiagnosticSnapshot? { nil }
}

/// Synchronous admission belongs only to inspection adapters. Native admission
/// must retain and await the same sample when the receiver declines readiness.
protocol SegmentedFMP4SynchronousSystemWriting: SegmentedFMP4SystemWriting {
    var isReadyForMoreMediaData: Bool { get }
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

extension SegmentedFMP4SynchronousSystemWriting {
    /// 既有 inspection adapter 保留立即 append；真实系统 adapter 必须覆盖异步入口。
    func appendAwaitingReadiness(
        _ sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    ) async throws {
        try sampleBuffer.withUnsafeSampleBuffer { buffer in
            guard append(buffer) else { throw SegmentedFMP4WriterFailure.diagnosedSystemFailure() }
        }
    }
}

protocol SegmentedFMP4SystemWriterFactory: Sendable {
    func makeWriter(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting
}

final class AVAssetSegmentedFMP4SystemWriterFactory: SegmentedFMP4SystemWriterFactory, @unchecked Sendable {
    private let acceptanceProbe: HLSWriterAcceptanceProbe?
    init(acceptanceProbe: HLSWriterAcceptanceProbe? = nil) { self.acceptanceProbe = acceptanceProbe }
    func makeWriter(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting {
        try AVAssetSegmentedFMP4SystemWriter(
            configuration: configuration,
            sourceFormatHint: sourceFormatHint,
            callbackSink: callbackSink,
            acceptanceProbe: acceptanceProbe
        )
    }
}

private final class AVAssetSegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    weak var callbackSink: (any SegmentedFMP4SystemCallbackSink)?
    private let mediaType: AVMediaType
    private let context: SegmentedFMP4CallbackContext?
    private let source: CMFormatDescription

    init(callbackSink: any SegmentedFMP4SystemCallbackSink, mediaType: AVMediaType,
         context: SegmentedFMP4CallbackContext?, source: CMFormatDescription) {
        self.callbackSink = callbackSink
        self.mediaType = mediaType
        self.context = context; self.source = source
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let report = SegmentedFMP4SystemReportProvenance.from(systemReport: segmentReport, mediaType: mediaType)
        let evidence: SegmentedFMP4SystemReportEvidence
        if let context {
            let capsule = SegmentedFMP4SystemCallbackCapsule(context: context, writer: ObjectIdentifier(writer),
                bytes: segmentData, type: segmentType, report: report, source: source)
            evidence = .init(callback: report, capsule: capsule)
        } else { evidence = report }
        callbackSink?.receiveSystemSegment(
            writerObjectIdentity: ObjectIdentifier(writer),
            bytes: segmentData,
            type: segmentType,
            report: evidence
        )
    }
}

/// 只有本文件中的真实 delegate 可以从实际系统 report 签发；不持有 reference，避免引用环。
final class SegmentedFMP4SystemReportProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private let systemReport: AVAssetSegmentReport
    private let mediaType: AVMediaType
    private let start: CMTime
    private let duration: CMTime
    private var boundReferenceIdentity: UUID?

    private init(report: AVAssetSegmentReport, mediaType: AVMediaType, start: CMTime, duration: CMTime) {
        systemReport = report
        self.mediaType = mediaType
        self.start = start
        self.duration = duration
    }

    /// 不接受 caller 提供的时间或信任标志；直接从真实 AVAssetSegmentReport 冻结事实。
    fileprivate static func from(systemReport: AVAssetSegmentReport?, mediaType: AVMediaType) -> SegmentedFMP4SystemReportEvidence {
        let evidence = SegmentedFMP4SystemReportEvidence.from(systemReport: systemReport, mediaType: mediaType)
        guard let systemReport, evidence.hasUniqueMatchingTrack,
              let start = evidence.earliestPresentationTimeStamp,
              let duration = evidence.duration else { return evidence }
        return SegmentedFMP4SystemReportEvidence(attesting: evidence, provenance: Self(
            report: systemReport, mediaType: mediaType, start: start, duration: duration))
    }

    /// 第一个准确 reference 唯一绑定该资格；随后即使事实完全相同，也不能搬到第二个 reference。
    func bind(referenceIdentity: UUID, evidence: SegmentedFMP4SystemReportEvidence) -> Bool {
        lock.withLock {
            guard boundReferenceIdentity == nil,
                  evidence.systemProvenance === self,
                  evidence.hasUniqueMatchingTrack,
                  matchesFacts(report: evidence.systemReport, mediaType: evidence.mediaType,
                      start: evidence.earliestPresentationTimeStamp, duration: evidence.duration) else { return false }
            boundReferenceIdentity = referenceIdentity
            return true
        }
    }

    func accepts(reference: SegmentReportReference, mediaType: AVMediaType) -> Bool {
        lock.withLock {
            reference.systemProvenance === self
                && boundReferenceIdentity == reference.identity
                && reference.hasUniqueMatchingTrack
                && self.mediaType == mediaType
                && matchesFacts(report: reference.systemReport, mediaType: reference.mediaType,
                    start: reference.earliestPresentationTimeStamp, duration: reference.duration)
        }
    }

    private func matchesFacts(report: AVAssetSegmentReport?, mediaType: AVMediaType?, start: CMTime?, duration: CMTime?) -> Bool {
        guard report === systemReport, self.mediaType == mediaType,
              let start, let duration else { return false }
        return sameTime(self.start, start) && sameTime(self.duration, duration)
    }

    /// 比较完整冻结表示，不能以约分或 CMTimeCompare 丢失 flags/epoch 的差异。
    private func sameTime(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        lhs.value == rhs.value && lhs.timescale == rhs.timescale
            && lhs.flags == rhs.flags && lhs.epoch == rhs.epoch
    }
}

/// 新 header 由本次 append 独占；共享的媒体 backing 由输入 owner 持续保留。
/// 原 header 留在 typed 票据的只读证据链中，不跨 executor 发送该借用别名。
private func nativeReadySample(
    copying sample: CMSampleBuffer
) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    var copied: CMSampleBuffer?
    let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
        sampleBuffer: sample, sampleBufferOut: &copied)
    guard status == noErr else {
        throw SegmentedFMP4WriterFailure.systemError(PlaybackErrorDiagnostics.snapshot(
            NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "HLS native sample header 复制失败"])))
    }
    guard let copied, ObjectIdentifier(copied) != ObjectIdentifier(sample) else {
        throw SegmentedFMP4WriterFailure.systemError(PlaybackErrorDiagnostics.snapshot(
            NSError(domain: "VPlayerHLS.NativeReadySample", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "HLS sample 复制未返回独立 header"])))
    }
    guard CMSampleBufferDataIsReady(copied) else {
        throw SegmentedFMP4WriterFailure.systemError(PlaybackErrorDiagnostics.snapshot(
            NSError(domain: "VPlayerHLS.NativeReadySample", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "HLS native append 输入数据尚未 ready"])))
    }
    // CreateCopy 仅承诺传播附件；HLS 样本的 decoder control 也包含非传播附件。
    for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
            target: sample, attachmentMode: mode) {
            CMSetAttachments(copied, attachments: attachments, attachmentMode: mode)
        }
    }
    // C out-pointer 缺少返回值独占注解；CreateCopy 已创建独立 header。
    // 仅此局部桥接绕过区域推断；媒体 backing 仍只读且由原 owner 保留。
    nonisolated(unsafe) let nativeHeader = copied
    return CMReadySampleBuffer(unsafeBuffer: nativeHeader)
}

private indirect enum NativeAttachmentFacts: Sendable, Equatable {
    case dictionary([String: NativeAttachmentFacts])
    case array([NativeAttachmentFacts])
    case string(String)
    case number(String, String)
    case data(Data)

    /// CMSetAttachments applies CMSetAttachment to each key/value; an empty
    /// dictionary cannot recreate the source's internal dictionary allocation.
    /// Freeze the key/value facts, not nil versus allocated-but-empty storage.
    /// Only buffer-level dictionaries use this rule, separately for each valid
    /// mode. A present key with an empty nested value remains a real attachment.
    /// https://developer.apple.com/documentation/coremedia/cmsetattachments(_:attachments:attachmentmode:)
    static func freezeBufferDictionary(_ dictionary: CFDictionary?) throws -> NativeAttachmentFacts {
        guard let dictionary else { return .dictionary([:]) }
        return try freeze(dictionary as NSDictionary)
    }

    static func freeze(_ value: Any) throws -> NativeAttachmentFacts {
        if let dictionary = value as? NSDictionary {
            var result: [String: NativeAttachmentFacts] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    #if DEBUG
                    print("HLS_NATIVE_SAMPLE_MISMATCH stage=freeze-attachment-key")
                    #endif
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                result[key] = try freeze(value)
            }
            return .dictionary(result)
        }
        if let array = value as? NSArray { return .array(try array.map { try freeze($0) }) }
        if let data = value as? Data { return .data(data) }
        if let number = value as? NSNumber {
            return .number(String(cString: number.objCType), number.stringValue)
        }
        if let string = value as? String { return .string(string) }
        #if DEBUG
        print("HLS_NATIVE_SAMPLE_MISMATCH stage=freeze-attachment-value")
        #endif
        throw SegmentedFMP4WriterFailure.sourceFormatMismatch
    }
}

/// sample 对象身份由原 typed 票据保留；此快照证明 native 副本携带相同媒体事实。
private struct NativeSampleFacts: Sendable, Equatable {
    let format: ObjectIdentifier?
    let timing: [String]
    let sizes: [Int]
    let attachments: [NativeAttachmentFacts?]
    let payloadDigest: Data?

    /// Keep the exact guard while identifying which native header boundary failed.
    /// Only bounded scalar facts are logged, never attachments, headers or payload.
    func matches(_ other: Self, stage: StaticString) -> Bool {
        guard self == other else {
            #if DEBUG
            let timingIndex = timing.indices.first {
                !other.timing.indices.contains($0) || timing[$0] != other.timing[$0]
            }
            let actualTime = timingIndex.map { timing[$0] } ?? "none"
            let expectedTime = timingIndex.flatMap {
                other.timing.indices.contains($0) ? other.timing[$0] : nil
            } ?? "none"
            func dictionaryCount(_ value: NativeAttachmentFacts?) -> Int {
                guard let value else { return -1 }
                if case .dictionary(let entries) = value { return entries.count }
                return -2
            }
            print("HLS_NATIVE_SAMPLE_MISMATCH stage=\(stage) "
                + "formatEqual=\(format == other.format) "
                + "timingCount=\(timing.count)/\(other.timing.count) "
                + "timingIndex=\(timingIndex ?? -1) actualTime=\(actualTime) expectedTime=\(expectedTime) "
                + "sampleCount=\(sizes.count)/\(other.sizes.count) sizesEqual=\(sizes == other.sizes) "
                + "sampleAttachmentsEqual=\(attachments[0] == other.attachments[0]) "
                + "propagatingAttachmentsEqual=\(attachments[1] == other.attachments[1]) "
                + "propagatingAttachmentCount=\(dictionaryCount(attachments[1]))/\(dictionaryCount(other.attachments[1])) "
                + "privateAttachmentsEqual=\(attachments[2] == other.attachments[2]) "
                + "privateAttachmentCount=\(dictionaryCount(attachments[2]))/\(dictionaryCount(other.attachments[2])) "
                + "payloadEqual=\(payloadDigest == other.payloadDigest)")
            #endif
            return false
        }
        return true
    }

    static func freeze(_ sample: CMSampleBuffer) throws -> NativeSampleFacts {
        func exact(_ time: CMTime) -> String {
            "\(time.value)/\(time.timescale)/\(time.flags.rawValue)/\(time.epoch)"
        }
        let count = CMSampleBufferGetNumSamples(sample)
        var timing = [exact(CMSampleBufferGetDuration(sample)),
            exact(CMSampleBufferGetPresentationTimeStamp(sample)),
            exact(CMSampleBufferGetDecodeTimeStamp(sample)),
            exact(CMSampleBufferGetOutputPresentationTimeStamp(sample)),
            exact(CMSampleBufferGetOutputDuration(sample))]
        for index in 0..<count {
            var info = CMSampleTimingInfo()
            let status = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &info)
            guard status == noErr else {
                #if DEBUG
                print("HLS_NATIVE_SAMPLE_MISMATCH stage=freeze-timing sampleCount=\(count) index=\(index) status=\(status)")
                #endif
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            timing.append(contentsOf: [exact(info.duration),
                exact(info.presentationTimeStamp), exact(info.decodeTimeStamp)])
        }
        let sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(sample,
            createIfNecessary: false).map { $0 as NSArray }
        let propagating = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
            target: sample, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let privateAttachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
            target: sample, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        let attachments: [NativeAttachmentFacts?] = [
            try sampleAttachments.map { try NativeAttachmentFacts.freeze($0) },
            try NativeAttachmentFacts.freezeBufferDictionary(propagating),
            try NativeAttachmentFacts.freezeBufferDictionary(privateAttachments),
        ]
        let digest: Data?
        if let block = CMSampleBufferGetDataBuffer(sample) {
            digest = try nativeSamplePayloadDigest(block)
        } else { digest = nil }
        return NativeSampleFacts(format: CMSampleBufferGetFormatDescription(sample).map(ObjectIdentifier.init),
            timing: timing, sizes: (0..<count).map { CMSampleBufferGetSampleSize(sample, at: $0) },
            attachments: attachments, payloadDigest: digest)
    }
}

/// Hash every currently readable block without allocating a payload-sized copy.
/// CoreMedia keeps each pointer valid while its block buffer is retained. Borrow
/// synchronously, including noncontiguous references, and never cache a digest:
/// native/source mutation must still be detected at every evidence checkpoint.
func nativeSamplePayloadDigest(_ block: CMBlockBuffer) throws -> Data {
    try withExtendedLifetime(block) {
        let length = CMBlockBufferGetDataLength(block)
        var offset = 0
        var hasher = SHA256()
        while offset < length {
            var contiguousLength = 0
            var totalLength = 0
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: offset,
                lengthAtOffsetOut: &contiguousLength, totalLengthOut: &totalLength,
                dataPointerOut: &pointer)
            guard status == noErr, let pointer, totalLength == length,
                  contiguousLength > 0, contiguousLength <= length - offset else {
                throw SegmentedFMP4WriterFailure.diagnosedSystemFailure("native.payloadDigest", status: status)
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: pointer, count: contiguousLength))
            offset += contiguousLength
        }
        return Data(hasher.finalize())
    }
}

/// One inline gate serializes native calls; it never owns a sample, waiter, or task.
/// Callbacks may enter the outer writer lane, so they must not acquire this gate:
/// failure diagnostics use separate storage and callback retirement is queued.
struct SegmentedFMP4NativeWriterCalls: ~Copyable, Sendable {
    private enum State { case configured, writing, inputFinished, finishing, cancelled }
    private let state = Mutex(State.configured)

    init() {}

    func start(_ body: () -> Bool) -> Bool {
        state.withLock {
            guard $0 == .configured, body() else { return false }
            $0 = .writing
            return true
        }
    }

    func appendAwaitingReadiness(_ appendImmediately: () throws -> Bool) async throws {
        while true {
            let appended = try state.withLock {
                try Task.checkCancellation()
                guard $0 == .writing else { throw CancellationError() }
                return try appendImmediately()
            }
            try Task.checkCancellation()
            if appended { return }
            // The receiver documents false as not-ready. Keep the one admitted
            // sample on this existing task; no lock/native call spans suspension.
            // This cancellable delay only paces retries, never proves retirement.
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func flush(_ body: () -> Bool) -> Bool {
        state.withLock { $0 == .writing && body() }
    }

    func finishInput(_ body: () -> Void) {
        state.withLock {
            guard $0 == .writing else { return }
            $0 = .inputFinished
            body()
        }
    }

    func finishWriting(_ body: () -> Void) -> Bool {
        state.withLock {
            guard $0 == .inputFinished else { return false }
            $0 = .finishing
            body()
            return true
        }
    }

    func cancel(_ body: () -> Void) {
        state.withLock {
            guard $0 != .cancelled else { return }
            $0 = .cancelled
            // The synchronous native append has returned before this can enter.
            // No new append can cross this fence, even if its task starts late.
            body()
        }
    }
}

private final class AVAssetSegmentedFMP4SystemWriter: SegmentedFMP4SystemWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let receiver: AVAssetWriterInput.SampleBufferReceiver
    private let segmentDelegate: AVAssetSegmentDelegate
    private let calls = SegmentedFMP4NativeWriterCalls()
    // Both mutexes are inline; adding the native fence creates no lock owner or
    // per-input allocation. Diagnostics never take the native-call mutex.
    private let startFailureDiagnostic = Mutex<ErrorDiagnosticSnapshot?>(nil)

    init(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink,
        acceptanceProbe: HLSWriterAcceptanceProbe? = nil
    ) throws {
        guard configuration.contentTypeIdentifier == UTType.mpeg4Movie.identifier,
              configuration.outputFileTypeProfile == AVFileTypeProfile.mpeg4AppleHLS.rawValue,
              CMTIME_IS_INDEFINITE(configuration.preferredOutputSegmentInterval),
              configuration.outputSettingsAreNil,
              configuration.sourceFormatHintIdentity == ObjectIdentifier(sourceFormatHint),
              configuration.inputCount == 1,
              HLSWriterSequencePolicy.supportedRange.contains(configuration.initialMovieFragmentSequenceNumber) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        let nativeAudioSubtype = CMFormatDescriptionGetMediaType(sourceFormatHint) == kCMMediaType_Audio
            ? CMFormatDescriptionGetMediaSubType(sourceFormatHint) : nil
        acceptanceProbe?.nativeWriterConstructed(trackKind: nativeAudioSubtype == kAudioFormatAC3 ? .ac3
            : (nativeAudioSubtype == kAudioFormatEnhancedAC3 ? .eac3 : nil))
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
        // Physical windows form one uniform fragment stream. Configure the native
        // writer before start; callback bytes and codec/timing metadata stay untouched.
        writer.initialMovieFragmentSequenceNumber = configuration.initialMovieFragmentSequenceNumber
        writer.producesCombinableFragments = configuration.producesCombinableFragments
        let segmentDelegate = AVAssetSegmentDelegate(
            callbackSink: callbackSink,
            mediaType: configuration.mediaType,
            context: configuration.callbackContext, source: sourceFormatHint
        )
        writer.delegate = segmentDelegate
        let input = AVAssetWriterInput(
            mediaType: configuration.mediaType,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        if configuration.mediaType == .video { input.mediaTimeScale = configuration.videoMediaTimeScale }
        guard writer.canAdd(input) else {
            let codec = CMFormatDescriptionGetMediaSubType(sourceFormatHint)
            if codec == kAudioFormatAC3 || codec == kAudioFormatEnhancedAC3 || codec == kAudioFormatMPEG4AAC {
                throw SegmentedFMP4WriterFailure.unsupportedCompressedAudioFormat
            }
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let receiver = writer.inputReceiver(for: input)
        self.writer = writer
        self.receiver = receiver
        self.segmentDelegate = segmentDelegate
        try configuration.callbackContext?.bind(adapter: self, writer: ObjectIdentifier(writer), source: sourceFormatHint)
    }

    var objectIdentity: ObjectIdentifier { ObjectIdentifier(writer) }
    var failureDiagnostic: ErrorDiagnosticSnapshot? {
        startFailureDiagnostic.withLock { $0 }
            ?? writer.error.map { PlaybackErrorDiagnostics.snapshot($0) }
    }

    func startWriting(at sourceTime: CMTime) -> Bool {
        calls.start {
            do { try writer.start() }
            catch {
                startFailureDiagnostic.withLock {
                    if $0 == nil { $0 = PlaybackErrorDiagnostics.snapshot(error) }
                }
                return false
            }
            writer.startSession(atSourceTime: sourceTime)
            return true
        }
    }

    func appendAwaitingReadiness(
        _ sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    ) async throws {
        // An async receiver append can still be executing after Task.cancel().
        // cancelWriting must never overlap that native call or a late entry.
        try await calls.appendAwaitingReadiness { try receiver.appendImmediately(sampleBuffer) }
    }

    func flushSegment() -> Bool {
        calls.flush {
            writer.flushSegment()
            return writer.status == .writing && writer.error == nil
        }
    }

    func markInputAsFinished() { calls.finishInput { receiver.finish() } }

    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) {
        let began = calls.finishWriting {
            writer.finishWriting { [weak self] in
                guard let self else { return }
                completion(self.writer.status == .completed && self.writer.error == nil)
            }
        }
        if !began { completion(false) }
    }

    func cancelWriting() { calls.cancel { writer.cancelWriting() } }
}

final class FMP4InputOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void = {}) {
        releaseBody = release
    }

    func release() {
        let body = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseBody = nil }
            return releaseBody
        }
        body?()
    }

    deinit { release() }
}

enum SegmentedFMP4WriterFailure: Error, Sendable, Equatable {
    case invalidSystemConfiguration
    case illegalState
    case sourceFormatMismatch
    case boundaryMismatch
    case notReady
    case systemFailure
    case systemError(ErrorDiagnosticSnapshot)
    case compressedIdentityMismatch
    case aacEndpointMismatch
    case inputEvidenceCapacityExceeded
    case terminalOwnershipCapacityExceeded
    case rolloverRequired
    case newGenerationRequired
    case unsupportedCompressedAudioFormat
    case compressedAudioCompatibilityRequired
    case relayCapacityExceeded
    case arithmeticOverflow

    /// Debug localization only: an unexplained failure never becomes capability
    /// rejection. Static sites, line numbers and OSStatus expose no media or URLs.
    static func diagnosedSystemFailure(_ stage: StaticString = #function,
                                       line: UInt = #line, status: OSStatus? = nil) -> Self {
#if DEBUG
        print("HLS_WRITER_SYSTEM_FAILURE stage=\(stage) line=\(line) status=\(status.map { String($0) } ?? "none")")
#endif
        return .systemFailure
    }
}

/// writer 只接收连续逐帧 cadence。源视频的正向缺帧必须在转码分支内
/// 补齐，不能将不连续时间轴推迟到 AVAssetWriter/HLS 发布层。
enum SegmentedFMP4VideoCadencePolicy: Sendable, Equatable {
    case strict

    func accepts(
        previousDuration: ExactMediaTime,
        expectedNextPTS: ExactMediaTime,
        duration: ExactMediaTime,
        presentationTimeStamp: ExactMediaTime
    ) -> Bool {
        guard previousDuration == duration else { return false }
        return expectedNextPTS == presentationTimeStamp
    }
}

/// 单个系统 writer 的有界 ownership 窗口；达到软阈值时只允许在共同边界 rollover。
struct SegmentedFMP4WriterOwnershipLimits: Sendable, Equatable {
    let rolloverThreshold: Int
    let hardCapacity: Int

    static let standard = Self(rolloverThreshold: 256, hardCapacity: 384)
    static let video = Self(rolloverThreshold: 512, hardCapacity: 1024)
    static let audio = Self(rolloverThreshold: 512, hardCapacity: 640)
}

enum WriterWindowCadence: Sendable, Equatable {
    case video(duration: ExactMediaTime, nextPTS: ExactMediaTime)
    case remuxVideo(duration: ExactMediaTime, nextDecodeTimeStamp: ExactMediaTime)
    case compressed(duration: ExactMediaTime, nextPTS: ExactMediaTime)
}

/// A terminal-and-drained physical writer may issue exactly one successor claim.
/// The logical media epoch and participant identity remain unchanged.
final class WriterWindowContinuation: @unchecked Sendable {
    private enum State { case issued, rejected, claimed(FMP4WriterBinding) }
    private let lock = NSLock()
    let predecessorTerminal: SegmentedFMP4WriterTerminalReceipt
    let trackKind: SegmentedFMP4TrackKind
    let frozenFormat: SegmentedFMP4FrozenFormat
    let cadence: WriterWindowCadence?
    fileprivate let nextMovieFragmentSequenceNumber: Int
    fileprivate let inputAdmission: WriterInputAdmission
    fileprivate let maximumObservedInputBytes: Int
    fileprivate let remuxFormatAuthorityWitness: AnyObject?
    fileprivate let remuxBitrateEnvelope: VideoBitrateEnvelope?
    fileprivate let compressedBackingAdmission: HLSDataPlaneAdmission
    fileprivate let sourceAACBinding: SourceAACWriterTerminalBinding?
    private var state: State = .issued

    fileprivate init(
        predecessorTerminal: SegmentedFMP4WriterTerminalReceipt,
        trackKind: SegmentedFMP4TrackKind,
        frozenFormat: SegmentedFMP4FrozenFormat,
        cadence: WriterWindowCadence?,
        nextMovieFragmentSequenceNumber: Int,
        inputAdmission: WriterInputAdmission,
        maximumObservedInputBytes: Int,
        remuxFormatAuthorityWitness: AnyObject?,
        remuxBitrateEnvelope: VideoBitrateEnvelope?,
        compressedBackingAdmission: HLSDataPlaneAdmission,
        sourceAACBinding: SourceAACWriterTerminalBinding? = nil
    ) {
        self.sourceAACBinding = sourceAACBinding
        self.inputAdmission = inputAdmission
        self.maximumObservedInputBytes = maximumObservedInputBytes
        self.remuxFormatAuthorityWitness = remuxFormatAuthorityWitness
        self.remuxBitrateEnvelope = remuxBitrateEnvelope
        self.compressedBackingAdmission = compressedBackingAdmission
        self.nextMovieFragmentSequenceNumber = nextMovieFragmentSequenceNumber
        self.predecessorTerminal = predecessorTerminal
        self.trackKind = trackKind
        self.frozenFormat = frozenFormat
        self.cadence = cadence
    }

    fileprivate func claim(
        next: FMP4WriterBinding,
        trackKind: SegmentedFMP4TrackKind,
        frozenFormat: SegmentedFMP4FrozenFormat
    ) -> Bool {
        lock.withLock {
            guard case .issued = state else { return false }
            state = .rejected
            let previous = predecessorTerminal.binding
            guard predecessorTerminal.terminalReason == .finished,
                  self.trackKind == trackKind,
                  self.frozenFormat == frozenFormat || (self.trackKind == .video && self.frozenFormat.hasSameItemSelection(as: frozenFormat)),
                  next.outputLifecycleEpoch == previous.outputLifecycleEpoch,
                  next.itemGeneration == previous.itemGeneration,
                  next.mediaEpoch == previous.mediaEpoch,
                  next.publicationParticipantID == previous.publicationParticipantID,
                  next.renditionIdentity == previous.renditionIdentity,
                  next.writerIdentity != previous.writerIdentity else { return false }
            state = .claimed(next)
            return true
        }
    }

    fileprivate func authorizes(predecessor: FMP4WriterBinding,
                                successor: FMP4WriterBinding,
                                trackKind: SegmentedFMP4TrackKind) -> Bool {
        lock.withLock {
            predecessor == predecessorTerminal.binding
                && self.trackKind == trackKind
                && { if case .claimed(let value) = state { value == successor } else { false } }()
        }
    }
}

/// Zero-payload capability created with a successor writer. It can authorize one
/// pending remux attempt; media ownership remains in the stable pending core.
final class WriterWindowAdmission: @unchecked Sendable {
    private let lock = NSLock()
    fileprivate let continuation: WriterWindowContinuation
    let binding: FMP4WriterBinding
    let trackKind: SegmentedFMP4TrackKind
    private var remuxAttemptClaimed = false
    private var remuxBuilderClaimed = false
    private var initializationClaimed = false

    fileprivate init(continuation: WriterWindowContinuation,
                     binding: FMP4WriterBinding,
                     trackKind: SegmentedFMP4TrackKind) {
        self.continuation = continuation
        self.binding = binding
        self.trackKind = trackKind
    }

    func claimRemuxAttempt(from predecessor: FMP4WriterBinding) -> Bool {
        lock.withLock {
            guard !remuxAttemptClaimed,
                  trackKind == .video,
                  continuation.authorizes(
                    predecessor: predecessor, successor: binding, trackKind: .video
                  ) else { return false }
            remuxAttemptClaimed = true
            return true
        }
    }

    func claimRemuxBuilder(from predecessor: FMP4WriterBinding) -> Bool {
        lock.withLock {
            guard !remuxBuilderClaimed,
                  trackKind == .video,
                  continuation.authorizes(
                    predecessor: predecessor, successor: binding, trackKind: .video
                  ) else { return false }
            remuxBuilderClaimed = true
            return true
        }
    }

    func claimInitializationCompatibility(
        _ successorInitialization: SealedMediaObject,
        successorProof: EpochFormatProof,
        predecessorInitialization: SealedMediaObject,
        predecessorProof: EpochFormatProof,
        canonicalInitialization: SealedMediaObject,
        canonicalProof: EpochFormatProof,
        relay: SegmentReportRelay
    ) -> WriterInitializationCompatibility? {
        lock.withLock {
            guard !initializationClaimed,
                  predecessorProof.binding == continuation.predecessorTerminal.binding,
                  predecessorProof.matches(initialization: predecessorInitialization),
                  successorProof.binding == binding,
                  successorProof.matches(initialization: successorInitialization),
                  canonicalProof.matches(initialization: canonicalInitialization),
                  successorProof.mediaType == predecessorProof.mediaType,
                  canonicalProof.mediaType == successorProof.mediaType,
                  let predecessorEvidence = predecessorInitialization.publicationEvidence,
                  let successorEvidence = successorInitialization.publicationEvidence,
                  let canonicalEvidence = canonicalInitialization.publicationEvidence,
                  predecessorEvidence.session === successorEvidence.session,
                  canonicalEvidence.session === successorEvidence.session,
                  predecessorEvidence.format == successorEvidence.format,
                  canonicalEvidence.format == successorEvidence.format,
                  successorEvidence.writerSource.binding == binding,
                  successorEvidence.writerSource.belongs(to: relay),
                  let canonicalIdentity = try? FMP4ObjectIdentity(canonicalInitialization),
                  let successorIdentity = try? FMP4ObjectIdentity(successorInitialization),
                  let predecessorFacts = try? SealedDecodeCoverageMap
                    .initializationCompatibilityFacts(
                        predecessorInitialization,
                        mediaType: predecessorProof.mediaType),
                  let successorFacts = try? SealedDecodeCoverageMap
                    .initializationCompatibilityFacts(
                        successorInitialization,
                        mediaType: successorProof.mediaType),
                  let canonicalFacts = try? SealedDecodeCoverageMap
                    .initializationCompatibilityFacts(
                        canonicalInitialization,
                        mediaType: canonicalProof.mediaType),
                  predecessorFacts == successorFacts,
                  canonicalFacts == successorFacts else { return nil }
            initializationClaimed = true
            return WriterInitializationCompatibility(
                predecessorProof: predecessorProof,
                successorProof: successorProof,
                canonicalInitializationIdentity: canonicalIdentity,
                successorInitializationIdentity: successorIdentity,
                facts: successorFacts)
        }
    }
}

final class WriterInitializationCompatibility: @unchecked Sendable {
    let predecessorProofIdentity: UUID
    let successorProofIdentity: UUID
    let facts: FMP4InitializationCompatibilityFacts
    private let canonicalInitializationIdentity: FMP4ObjectIdentity
    private let successorInitializationIdentity: FMP4ObjectIdentity

    fileprivate init(
        predecessorProof: EpochFormatProof,
        successorProof: EpochFormatProof,
        canonicalInitializationIdentity: FMP4ObjectIdentity,
        successorInitializationIdentity: FMP4ObjectIdentity,
        facts: FMP4InitializationCompatibilityFacts
    ) {
        predecessorProofIdentity = predecessorProof.identity
        successorProofIdentity = successorProof.identity
        self.canonicalInitializationIdentity = canonicalInitializationIdentity
        self.successorInitializationIdentity = successorInitializationIdentity
        self.facts = facts
    }

    func authorizes(canonicalInitialization: SealedMediaObject,
                    canonicalProof: EpochFormatProof,
                    successorProof: EpochFormatProof) -> Bool {
        guard let canonical = try? FMP4ObjectIdentity(canonicalInitialization),
              let canonicalFacts = try? SealedDecodeCoverageMap
                .initializationCompatibilityFacts(
                    canonicalInitialization, mediaType: canonicalProof.mediaType) else {
            return false
        }
        return canonicalProof.matches(initializationIdentity: canonical)
            && canonical == canonicalInitializationIdentity
            && canonicalFacts == facts
            && successorProof.identity == successorProofIdentity
            && successorProof.initializationIdentity == successorInitializationIdentity
    }
}

enum SegmentedFMP4WriterTerminalReason: UInt8, Sendable, Hashable {
    case finished = 1
    case cancelled = 2
    case failed = 3
}

struct SegmentedFMP4WriterTerminalReceipt: Sendable, Hashable {
    let identity: UUID
    let binding: FMP4WriterBinding
    let terminalReason: SegmentedFMP4WriterTerminalReason
    let inputCount: Int
    let initializationCallbackCount: Int
    let mediaCallbackCount: Int
    let lastLogicalSequence: UInt64?
    let callbackEvidenceCount: Int
    let callbackEvidenceDigest: Data
    let lastCallbackReportIdentity: UUID?
}

/// 单个物理 writer 对 encoder 增量流的累计绑定；它不是跨 writer/publication
/// authority，后继 window owner 必须继续绑定各窗口 terminal receipt。
struct AACIncrementalWriterReceipt: Sendable, Hashable {
    let identity: UUID
    let binding: FMP4WriterBinding
    let encoderIdentity: AACEncoderIdentity
    let inputCount: UInt64
    let inputDigest: Data
    let realSampleCount: Int64
    let totalDecodedFrames: Int64
    let leadingFrames: Int
    let trailingFrames: Int64
}

/// 单个物理 AAC writer 窗口的真实终态。全局输入累计来自 writer lane，
/// callback 累计来自系统 callback 接纳；调用方没有填写 count/digest 的入口。
struct AACWriterWindowTerminalReceipt: Sendable, Hashable {
    let identity: UUID
    let binding: FMP4WriterBinding
    let encoderIdentity: AACEncoderIdentity
    let firstGlobalOrdinal: UInt64
    let nextGlobalOrdinal: UInt64
    let windowInputCount: UInt64
    let cumulativeInputCount: UInt64
    let cumulativeInputDigest: Data
    let systemTerminal: SegmentedFMP4WriterTerminalReceipt
    let callbackEvidenceCount: Int
    let callbackEvidenceDigest: Data
    let mediaMembership: AACMediaMembershipSnapshot
    let firstMedia: AACEndpointSealedObjectEvidence?
    let terminalMedia: AACEndpointSealedObjectEvidence?
    let mapping: AACWriterWindowMappingReceipt
}

struct AACWriterWindowMappingReceipt: Sendable, Hashable {
    let binding: FMP4WriterBinding
    let reportIdentity: UUID
    let inputPhysicalStart: ExactMediaTime
    let inputPhysicalEnd: ExactMediaTime
    let inputEffectiveStart: ExactMediaTime
    let inputEffectiveEnd: ExactMediaTime
    let writtenPhysicalStart: ExactMediaTime
    let writtenPhysicalEnd: ExactMediaTime
    let writtenEffectiveStart: ExactMediaTime
    let writtenEffectiveEnd: ExactMediaTime
    let offset: ExactMediaTime
}

final class AACPrefixPlaybackMappingReceipt: @unchecked Sendable {
    let publicationSequence: UInt64
    let mapping: AACWriterTimelineMappingReceipt
    let completedLeaf: AACMediaMembershipLeaf
    private let rendition: AACRenditionTerminalBinding

    fileprivate init(publicationSequence: UInt64,
                     mapping: AACWriterTimelineMappingReceipt,
                     completedLeaf: AACMediaMembershipLeaf,
                     rendition: AACRenditionTerminalBinding) {
        self.publicationSequence = publicationSequence
        self.mapping = mapping
        self.completedLeaf = completedLeaf
        self.rendition = rendition
    }

    func belongs(to rendition: AACRenditionTerminalBinding) -> Bool {
        self.rendition === rendition
    }
}

struct AACRenditionWriterFinalReceipt: @unchecked Sendable {
    let identity: UUID
    let binding: FMP4WriterBinding
    let encoderIdentity: AACEncoderIdentity
    let sampleRate: Int32
    let inputCount: UInt64
    let inputDigest: Data
    let realSampleCount: Int64
    let totalDecodedFrames: Int64
    let leadingFrames: Int
    let trailingFrames: Int64
    let systemTerminal: SegmentedFMP4WriterTerminalReceipt
    let terminalBinding: AACWriterTerminalBinding
    let callbackMembership: AACCallbackMembershipReceipt
    let firstMedia: AACEndpointSealedObjectEvidence
    let terminalMedia: AACEndpointSealedObjectEvidence
    let lastEffectiveEnd: ExactMediaTime
    let terminalPhysicalEnd: ExactMediaTime
}

/// rendition 级稳定 mapping owner；后继物理 writer 必须重新取得自己的真实
/// init/首 media mapping，且 offset 不得静默偏离首窗口。
final class AACRenditionTerminalBinding: @unchecked Sendable {
    private let lock = NSLock()
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: AudioItemGenerationIdentity
    let mediaEpoch: AudioMediaEpochIdentity
    let publicationParticipantID: AudioPublicationParticipantIdentity
    let renditionIdentity: AudioRenditionIdentity
    private var offset: ExactMediaTime?
    private var lastBinding: FMP4WriterBinding?
    private var windowCount = 0
    fileprivate let callbackMembership = AACMediaMembershipAccumulator()
    private let callbackIssuer = UUID()
    private var firstCallbackLeaf: AACMediaMembershipLeaf?
    private var terminalCallbackLeaf: AACMediaMembershipLeaf?
    private var firstMedia: AACEndpointSealedObjectEvidence?
    private var terminalMedia: AACEndpointSealedObjectEvidence?
    private var firstInitialization: AACEndpointSealedObjectEvidence?
    private var pendingInitialization: (FMP4WriterBinding, AACEndpointSealedObjectEvidence)?
    private var lastWindowMapping: AACWriterWindowMappingReceipt?
    private var firstMapping: AACWriterTimelineMappingReceipt?
    private var prefixReceipt: AACPrefixPlaybackMappingReceipt?
    private var writerFinal: AACRenditionWriterFinalReceipt?
    private var publicationIssuer: UUID?
    private var publicationReceipt: AACPublicationMembershipReceipt?
    private var publicationSealObserver:
        (identity: UUID, body: @Sendable (AACPublicationMembershipReceipt) -> Void)?
    private var httpIssuer: UUID?
    private var httpReceipt: AACHTTPMembershipReceipt?
    private var finalAuthority: AACEffectiveEndpointAuthority?

    fileprivate init(_ binding: FMP4WriterBinding) {
        outputLifecycleEpoch = binding.outputLifecycleEpoch
        itemGeneration = binding.itemGeneration
        mediaEpoch = binding.mediaEpoch
        publicationParticipantID = binding.publicationParticipantID
        renditionIdentity = binding.renditionIdentity
    }

    fileprivate func accept(_ mapping: AACWriterTimelineMappingReceipt) -> Bool {
        lock.withLock {
            let binding = mapping.binding
            guard binding.outputLifecycleEpoch == outputLifecycleEpoch,
                  binding.itemGeneration == itemGeneration,
                  binding.mediaEpoch == mediaEpoch,
                  binding.publicationParticipantID == publicationParticipantID,
                  binding.renditionIdentity == renditionIdentity,
                  pendingInitialization?.0 == binding,
                  lastBinding?.writerIdentity != binding.writerIdentity else { return false }
            if let offset, offset != mapping.offset { return false }
            if let previous = lastWindowMapping {
                guard previous.inputPhysicalEnd == mapping.inputPhysicalBase,
                      previous.inputEffectiveEnd == mapping.inputEffectiveBase,
                      previous.writtenPhysicalEnd == mapping.writtenPhysicalBase,
                      previous.writtenEffectiveEnd == mapping.writtenEffectiveBase else {
                    return false
                }
            }
            offset = mapping.offset
            if firstMapping == nil { firstMapping = mapping }
            lastBinding = binding
            pendingInitialization = nil
            windowCount += 1
            return true
        }
    }

    func issuePrefixMapping(publicationSequence: UInt64,
                            mapping: AACWriterTimelineMappingReceipt,
                            completedLeaf: AACMediaMembershipLeaf,
                            admission: AACPublicationLeafAdmission)
        -> AACPrefixPlaybackMappingReceipt? {
        lock.withLock {
            guard publicationSequence > 0,
                  let publicationIssuer,
                  admission.belongs(to: publicationIssuer),
                  firstMapping != nil,
                  mapping.binding.outputLifecycleEpoch == outputLifecycleEpoch,
                  mapping.binding.itemGeneration == itemGeneration,
                  mapping.binding.mediaEpoch == mediaEpoch,
                  mapping.binding.publicationParticipantID == publicationParticipantID,
                  mapping.binding.renditionIdentity == renditionIdentity,
                  mapping.offset == offset,
                  admission.leaf == completedLeaf,
                  completedLeaf.outputLifecycleEpoch == outputLifecycleEpoch,
                  completedLeaf.itemGeneration == itemGeneration,
                  completedLeaf.mediaEpoch == mediaEpoch,
                  completedLeaf.publicationParticipantID == publicationParticipantID,
                  completedLeaf.renditionIdentity == renditionIdentity,
                  callbackMembership.snapshot.firstLogicalSequence
                    .map({ completedLeaf.logicalSequence >= $0 }) == true,
                  callbackMembership.snapshot.lastLogicalSequence
                    .map({ completedLeaf.logicalSequence <= $0 }) == true else { return nil }
            if let prefixReceipt {
                if prefixReceipt.publicationSequence == publicationSequence {
                    guard prefixReceipt.completedLeaf == completedLeaf else { return nil }
                    return prefixReceipt
                }
                guard prefixReceipt.publicationSequence < publicationSequence else { return nil }
            }
            let receipt = AACPrefixPlaybackMappingReceipt(
                publicationSequence: publicationSequence,
                mapping: mapping,
                completedLeaf: completedLeaf,
                rendition: self)
            prefixReceipt = receipt
            return receipt
        }
    }

    func acceptsPublicationAdmission(_ admission: AACPublicationLeafAdmission) -> Bool {
        lock.withLock {
            guard let publicationIssuer,
                  admission.belongs(to: publicationIssuer) else { return false }
            let leaf = admission.leaf
            return leaf.outputLifecycleEpoch == outputLifecycleEpoch
                && leaf.itemGeneration == itemGeneration
                && leaf.mediaEpoch == mediaEpoch
                && leaf.publicationParticipantID == publicationParticipantID
                && leaf.renditionIdentity == renditionIdentity
        }
    }

    func prefixMapping(for publication: UInt64) -> AACPrefixPlaybackMappingReceipt? {
        lock.withLock {
            guard prefixReceipt?.publicationSequence == publication else { return nil }
            return prefixReceipt
        }
    }

    fileprivate func acceptCallback(_ leaf: AACMediaMembershipLeaf,
                                    evidence: AACEndpointSealedObjectEvidence) -> Bool {
        lock.withLock {
            guard leaf.outputLifecycleEpoch == outputLifecycleEpoch,
                  leaf.itemGeneration == itemGeneration,
                  leaf.mediaEpoch == mediaEpoch,
                  leaf.publicationParticipantID == publicationParticipantID,
                  leaf.renditionIdentity == renditionIdentity,
                  callbackMembership.accept(leaf) == .accepted else { return false }
            if firstCallbackLeaf == nil {
                firstCallbackLeaf = leaf
                firstMedia = evidence
            }
            terminalCallbackLeaf = leaf
            terminalMedia = evidence
            return true
        }
    }

    fileprivate func acceptInitialization(
        _ evidence: AACEndpointSealedObjectEvidence,
        binding: FMP4WriterBinding
    ) -> Bool {
        lock.withLock {
            guard evidence.key.kind == .initialization,
                  evidence.key.itemGeneration == itemGeneration.rawValue,
                  evidence.key.mediaEpoch == mediaEpoch.rawValue,
                  evidence.key.participantID == publicationParticipantID.rawValue,
                  binding.outputLifecycleEpoch == outputLifecycleEpoch,
                  binding.itemGeneration == itemGeneration,
                  binding.mediaEpoch == mediaEpoch,
                  binding.publicationParticipantID == publicationParticipantID,
                  binding.renditionIdentity == renditionIdentity,
                  pendingInitialization == nil,
                  lastBinding?.writerIdentity != binding.writerIdentity else { return false }
            if firstInitialization == nil { firstInitialization = evidence }
            pendingInitialization = (binding, evidence)
            return true
        }
    }

    fileprivate func sealWindowMapping(_ receipt: AACWriterWindowMappingReceipt) -> Bool {
        lock.withLock {
            guard receipt.binding == lastBinding,
                  receipt.offset == offset,
                  receipt.inputPhysicalStart != receipt.inputPhysicalEnd,
                  receipt.inputEffectiveStart != receipt.inputEffectiveEnd,
                  receipt.writtenPhysicalStart != receipt.writtenPhysicalEnd,
                  receipt.writtenEffectiveStart != receipt.writtenEffectiveEnd else { return false }
            lastWindowMapping = receipt
            return true
        }
    }

    fileprivate func sealFinal(accounting: AACIncrementalStreamAccounting,
                               terminal: SegmentedFMP4WriterTerminalReceipt,
                               terminalBinding: AACWriterTerminalBinding)
        throws -> AACRenditionWriterFinalReceipt {
        try lock.withLock {
            if let writerFinal { return writerFinal }
            guard terminal.terminalReason == .finished,
                  terminal.binding == lastBinding,
                  terminalBinding.binding == terminal.binding,
                  let firstMapping, let lastWindowMapping,
                  lastWindowMapping.binding == terminal.binding,
                  let terminalCallbackLeaf, let firstMedia, let terminalMedia,
                  let sampleRate = accounting.sampleRate,
                  callbackMembership.snapshot.pendingCount == 0,
                  callbackMembership.snapshot.lastLogicalSequence
                    == terminalCallbackLeaf.logicalSequence else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let lastEffectiveEnd = try firstMapping.writtenEffectiveBase.adding(
                ExactMediaTime(value: accounting.realSampleCount,
                               timescale: sampleRate))
            let terminalPhysicalEnd = try firstMapping.writtenPhysicalBase.adding(
                ExactMediaTime(value: accounting.totalDecodedFrames,
                               timescale: sampleRate))
            guard lastEffectiveEnd == lastWindowMapping.writtenEffectiveEnd,
                  terminalPhysicalEnd == lastWindowMapping.writtenPhysicalEnd else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let callback = AACCallbackMembershipReceipt(
                snapshot: callbackMembership.snapshot,
                terminalLeaf: terminalCallbackLeaf,
                issuer: callbackIssuer)
            let receipt = AACRenditionWriterFinalReceipt(
                identity: UUID(), binding: terminal.binding,
                encoderIdentity: accounting.encoderIdentity,
                sampleRate: sampleRate,
                inputCount: accounting.inputCount,
                inputDigest: accounting.inputDigest,
                realSampleCount: accounting.realSampleCount,
                totalDecodedFrames: accounting.totalDecodedFrames,
                leadingFrames: accounting.leadingFrames,
                trailingFrames: accounting.trailingFrames,
                systemTerminal: terminal,
                terminalBinding: terminalBinding,
                callbackMembership: callback,
                firstMedia: firstMedia,
                terminalMedia: terminalMedia,
                lastEffectiveEnd: lastEffectiveEnd,
                terminalPhysicalEnd: terminalPhysicalEnd)
            writerFinal = receipt
            try attemptFinalSealLocked()
            return receipt
        }
    }

    func acceptPublicationAdmission(_ admission: AACPublicationLeafAdmission,
                                    issuer: UUID) -> Bool {
        lock.withLock {
            let leaf = admission.leaf
            guard admission.belongs(to: issuer),
                  leaf.outputLifecycleEpoch == outputLifecycleEpoch,
                  leaf.itemGeneration == itemGeneration,
                  leaf.mediaEpoch == mediaEpoch,
                  leaf.publicationParticipantID == publicationParticipantID,
                  leaf.renditionIdentity == renditionIdentity,
                  publicationIssuer == nil || publicationIssuer == issuer else { return false }
            publicationIssuer = issuer
            return true
        }
    }

    func acceptPublication(_ receipt: AACPublicationMembershipReceipt,
                           issuer: UUID) throws {
        let observer = try lock.withLock {
            () throws -> (@Sendable (AACPublicationMembershipReceipt) -> Void)? in
            guard publicationReceipt == nil,
                  publicationIssuer == issuer,
                  receipt.belongs(to: issuer),
                  let terminalCallbackLeaf,
                  receipt.terminalLeaf == terminalCallbackLeaf,
                  receipt.snapshot == callbackMembership.snapshot,
                  receipt.snapshot.pendingCount == 0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            publicationReceipt = receipt
            try attemptFinalSealLocked()
            return publicationSealObserver?.body
        }
        observer?(receipt)
    }

    /// server 只可登记一个弱捕获的固定通知槽；若 publication 已先封存，登记返回前
    /// 补发同一真实 receipt。通知始终在 rendition lock 外调用，避免 publisher/store
    /// 与 server lane 形成反向锁序。
    func installPublicationSealObserver(
        _ observer: @escaping @Sendable (AACPublicationMembershipReceipt) -> Void
    ) -> UUID? {
        let result = lock.withLock {
            () -> (UUID, AACPublicationMembershipReceipt?)? in
            guard publicationSealObserver == nil else { return nil }
            let identity = UUID()
            publicationSealObserver = (identity, observer)
            return (identity, publicationReceipt)
        }
        guard let (identity, receipt) = result else { return nil }
        if let receipt { observer(receipt) }
        return identity
    }

    func removePublicationSealObserver(_ identity: UUID) {
        lock.withLock {
            guard publicationSealObserver?.identity == identity else { return }
            publicationSealObserver = nil
        }
    }

    func acceptHTTP(_ receipt: AACHTTPMembershipReceipt,
                    issuer: UUID) throws {
        try lock.withLock {
            guard httpReceipt == nil,
                  receipt.belongs(to: issuer),
                  let publicationReceipt,
                  receipt.terminalLeaf == publicationReceipt.terminalLeaf,
                  receipt.snapshot.pendingCount == 0,
                  receipt.snapshot.count <= publicationReceipt.snapshot.count else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            httpIssuer = issuer
            httpReceipt = receipt
            try attemptFinalSealLocked()
        }
    }

    var sealedPublicationReceipt: AACPublicationMembershipReceipt? {
        lock.withLock { publicationReceipt }
    }

    var sealedHTTPReceipt: AACHTTPMembershipReceipt? {
        lock.withLock { httpReceipt }
    }

    var finalWriterReceipt: AACRenditionWriterFinalReceipt? {
        lock.withLock { writerFinal }
    }

    var endpointAuthority: AACEffectiveEndpointAuthority? {
        lock.withLock { finalAuthority }
    }

    func owns(_ authority: AACEffectiveEndpointAuthority) -> Bool {
        lock.withLock {
            finalAuthority === authority
                && authority.renditionBinding === self
                && authority.publicationMembership === publicationReceipt
                && authority.httpMembership === httpReceipt
        }
    }

    private func attemptFinalSealLocked() throws {
        guard finalAuthority == nil,
              let writerFinal, let publicationReceipt, let httpReceipt,
              let firstInitialization, let firstMapping,
              let lastWindowMapping, let terminalCallbackLeaf,
              let firstMedia, let terminalMedia else { return }
        guard publicationReceipt.snapshot == writerFinal.callbackMembership.snapshot,
              publicationReceipt.terminalLeaf == terminalCallbackLeaf,
              httpReceipt.terminalLeaf == terminalCallbackLeaf,
              firstMapping.sampleRate == writerFinal.sampleRate,
              lastWindowMapping.offset == firstMapping.offset,
              Int(exactly: writerFinal.inputCount) != nil else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let leading = Int64(writerFinal.leadingFrames)
        let realDuration = ExactMediaTime(
            value: writerFinal.realSampleCount, timescale: writerFinal.sampleRate)
        let physicalDuration = ExactMediaTime(
            value: writerFinal.totalDecodedFrames, timescale: writerFinal.sampleRate)
        let writtenEffectiveBase = try firstMapping.inputEffectiveBase.adding(
            firstMapping.offset)
        let effectiveEnd = try writtenEffectiveBase.adding(realDuration)
        let physicalEnd = try firstMapping.writtenPhysicalBase.adding(physicalDuration)
        guard writtenEffectiveBase == firstMapping.writtenEffectiveBase,
              effectiveEnd == lastWindowMapping.writtenEffectiveEnd,
              physicalEnd == lastWindowMapping.writtenPhysicalEnd else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let receipt = AACEffectiveEndpointReceipt(
            writerReceiptIdentity: writerFinal.systemTerminal.identity,
            binding: writerFinal.binding,
            encoderIdentity: writerFinal.encoderIdentity,
            sampleRate: writerFinal.sampleRate,
            inputPhysicalBase: firstMapping.inputPhysicalBase,
            inputEffectiveBase: firstMapping.inputEffectiveBase,
            writtenPhysicalBase: firstMapping.writtenPhysicalBase,
            writtenEffectiveBase: firstMapping.writtenEffectiveBase,
            timelineOffset: firstMapping.offset,
            realSampleCount: writerFinal.realSampleCount,
            totalDecodedFrames: writerFinal.totalDecodedFrames,
            leadingFrames: leading,
            trailingFrames: writerFinal.trailingFrames,
            inputEvidenceCount: Int(writerFinal.inputCount),
            inputEvidenceDigest: writerFinal.inputDigest,
            callbackEvidenceCount: Int(writerFinal.callbackMembership.snapshot.count),
            callbackEvidenceDigest: writerFinal.callbackMembership.snapshot.digest,
            mappingReportIdentity: firstMapping.reportIdentity,
            initializationBackingIdentity: firstInitialization.backingIdentity,
            firstMedia: firstMedia,
            terminalMedia: terminalMedia,
            terminalLogicalSequence: terminalCallbackLeaf.logicalSequence,
            lastEffectiveEnd: effectiveEnd,
            terminalPhysicalEnd: physicalEnd)
        finalAuthority = AACEffectiveEndpointAuthority(
            receipt: receipt,
            terminal: writerFinal.systemTerminal,
            initialization: firstInitialization,
            media: firstMedia == terminalMedia ? [firstMedia] : [firstMedia, terminalMedia],
            terminalBinding: writerFinal.terminalBinding,
            renditionBinding: self,
            publicationMembership: publicationReceipt,
            httpMembership: httpReceipt)
    }

    var acceptedWindowCount: Int { lock.withLock { windowCount } }
}

/// 前代 writer 真实 terminal 后私签的一次性接管权。构造器对调用方不可见；
/// `claim` 与 live-context migration 是同一不可回退消费序列。
final class AACWriterWindowContinuation: @unchecked Sendable {
    private enum State { case issued, rejected, claimed(FMP4WriterBinding), migrated }
    private let lock = NSLock()
    fileprivate let receipt: AACWriterWindowTerminalReceipt
    fileprivate let accounting: AACIncrementalStreamAccounting
    fileprivate let context: AACLiveEncodingContext
    fileprivate let renditionBinding: AACRenditionTerminalBinding
    fileprivate let nextMovieFragmentSequenceNumber: Int
    fileprivate let inputAdmission: WriterInputAdmission
    fileprivate let maximumObservedInputBytes: Int
    private var state: State = .issued
    var nextPhysicalStart: ExactMediaTime? { accounting.nextPhysicalStart }
    var mediaMembershipSnapshot: AACMediaMembershipSnapshot { receipt.mediaMembership }

    fileprivate init(receipt: AACWriterWindowTerminalReceipt,
                     accounting: AACIncrementalStreamAccounting,
                     context: AACLiveEncodingContext,
                     renditionBinding: AACRenditionTerminalBinding,
                     nextMovieFragmentSequenceNumber: Int,
                     inputAdmission: WriterInputAdmission,
                     maximumObservedInputBytes: Int) {
        self.inputAdmission = inputAdmission
        self.maximumObservedInputBytes = maximumObservedInputBytes
        self.nextMovieFragmentSequenceNumber = nextMovieFragmentSequenceNumber
        self.receipt = receipt
        self.accounting = accounting
        self.context = context
        self.renditionBinding = renditionBinding
    }

    fileprivate func claim(next: FMP4WriterBinding) -> Bool {
        lock.withLock {
            guard case .issued = state else { return false }
            // consume 的线性化点先于目标验证；任何失败都永久烧毁 capability。
            state = .rejected
            guard receipt.systemTerminal.terminalReason == .finished,
                  receipt.systemTerminal.binding == receipt.binding,
                  receipt.nextGlobalOrdinal == receipt.cumulativeInputCount,
                  next.outputLifecycleEpoch == receipt.binding.outputLifecycleEpoch,
                  next.itemGeneration == receipt.binding.itemGeneration,
                  next.mediaEpoch == receipt.binding.mediaEpoch,
                  next.publicationParticipantID == receipt.binding.publicationParticipantID,
                  next.renditionIdentity == receipt.binding.renditionIdentity,
                  next.writerIdentity != receipt.binding.writerIdentity else { return false }
            state = .claimed(next)
            return true
        }
    }

    func authorizesContextMigration(
        context: AACLiveEncodingContext,
        previous: FMP4WriterBinding,
        next: FMP4WriterBinding
    ) -> Bool {
        lock.withLock {
            guard self.context === context,
                  previous == receipt.binding,
                  case .claimed(let claimed) = state,
                  claimed == next else { return false }
            state = .migrated
            return true
        }
    }
}

/// 后继物理 writer 在取得一次性 continuation 后私签的 publisher 准入。
/// 初始化与首段 mapping 都由该 writer 的真实 callback 填充，调用方只能转交原对象。
final class AACWriterInitializationCompatibility: @unchecked Sendable {
    let predecessorProofIdentity: UUID
    let successorProofIdentity: UUID
    private let canonicalInitializationIdentity: FMP4ObjectIdentity
    private let successorInitializationIdentity: FMP4ObjectIdentity

    fileprivate init(predecessorProof: EpochFormatProof,
                     successorProof: EpochFormatProof,
                     canonicalInitializationIdentity: FMP4ObjectIdentity,
                     successorInitializationIdentity: FMP4ObjectIdentity) {
        predecessorProofIdentity = predecessorProof.identity
        successorProofIdentity = successorProof.identity
        self.canonicalInitializationIdentity = canonicalInitializationIdentity
        self.successorInitializationIdentity = successorInitializationIdentity
    }

    func authorizes(canonicalInitialization: SealedMediaObject,
                    canonicalProof: EpochFormatProof,
                    successorProof: EpochFormatProof) -> Bool {
        guard let canonical = try? FMP4ObjectIdentity(canonicalInitialization) else { return false }
        return canonicalProof.matches(initializationIdentity: canonical)
            && canonical == canonicalInitializationIdentity
            && successorProof.identity == successorProofIdentity
            && successorProof.initializationIdentity == successorInitializationIdentity
    }
}

final class AACWriterWindowAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let rendition: AACRenditionTerminalBinding
    private let predecessorBinding: FMP4WriterBinding
    let binding: FMP4WriterBinding
    private var initialization: AACEndpointSealedObjectEvidence?
    private var mapping: AACWriterTimelineMappingReceipt?
    private var initializationClaimed = false

    fileprivate init(continuation: AACWriterWindowContinuation,
                     binding: FMP4WriterBinding) {
        rendition = continuation.renditionBinding
        predecessorBinding = continuation.receipt.binding
        self.binding = binding
    }

    fileprivate func recordInitialization(_ evidence: AACEndpointSealedObjectEvidence) {
        lock.withLock {
            precondition(initialization == nil || initialization == evidence,
                         "writer window initialization 只能冻结一次")
            initialization = evidence
        }
    }

    fileprivate func recordMapping(_ receipt: AACWriterTimelineMappingReceipt) {
        lock.withLock {
            precondition(receipt.binding == binding,
                         "writer window mapping 必须来自准入 writer")
            precondition(mapping == nil || mapping == receipt,
                         "writer window mapping 只能冻结一次")
            mapping = receipt
        }
    }

    func claimInitializationCompatibility(
        _ object: SealedMediaObject,
        proof: EpochFormatProof,
        predecessorInitialization: SealedMediaObject,
        predecessorProof: EpochFormatProof,
        canonicalInitialization: SealedMediaObject,
        canonicalProof: EpochFormatProof,
        relay: SegmentReportRelay,
        terminalBinding: AACWriterTerminalBinding?,
        renditionBinding: AACRenditionTerminalBinding?
    ) -> AACWriterInitializationCompatibility? {
        lock.withLock {
            guard !initializationClaimed,
                  renditionBinding === rendition,
                  terminalBinding?.binding == binding,
                  predecessorProof.binding == predecessorBinding,
                  predecessorProof.matches(initialization: predecessorInitialization),
                  proof.binding == binding,
                  let initialization,
                  initialization == AACEndpointSealedObjectEvidence(object),
                  canonicalProof.matches(initialization: canonicalInitialization),
                  let predecessorEvidence = predecessorInitialization.publicationEvidence,
                  let canonicalEvidence = canonicalInitialization.publicationEvidence,
                  let evidence = object.publicationEvidence,
                  predecessorEvidence.session === evidence.session,
                  canonicalEvidence.session === evidence.session,
                  predecessorEvidence.format.hasSameItemSelection(as: evidence.format),
                  canonicalEvidence.format.hasSameItemSelection(as: evidence.format),
                  evidence.matches(object),
                  evidence.writerSource.binding == binding,
                  evidence.writerSource.belongs(to: relay),
                  let canonicalIdentity = try? FMP4ObjectIdentity(canonicalInitialization),
                  let successorIdentity = try? FMP4ObjectIdentity(object) else { return nil }
            initializationClaimed = true
            return AACWriterInitializationCompatibility(
                predecessorProof: predecessorProof,
                successorProof: proof,
                canonicalInitializationIdentity: canonicalIdentity,
                successorInitializationIdentity: successorIdentity)
        }
    }

    func accepts(_ receipt: AACWriterTimelineMappingReceipt,
                 renditionBinding: AACRenditionTerminalBinding?) -> Bool {
        lock.withLock {
            initializationClaimed
                && renditionBinding === rendition
                && receipt.binding == binding
                && mapping == receipt
        }
    }
}

enum AACIncrementalAppendResult: Sendable, Equatable {
    case appended
    case retryLater
}

/// 单 writer lane 内的已提交累计值。queried prime 只随最终 encoder summary
/// 记录，不参与 L/P 相等判断；L/P 始终来自首尾 trim 与 Q-L-N。
struct AACIncrementalStreamAccounting: Sendable {
    let encoderIdentity: AACEncoderIdentity
    let inputCount: UInt64
    let inputDigest: Data
    let realSampleCount: Int64
    let totalDecodedFrames: Int64
    let leadingFrames: Int
    let trailingFrames: Int64
    let sampleRate: Int32?
    let firstPhysicalStart: ExactMediaTime?
    let firstOutputStart: ExactMediaTime?
    let nextPhysicalStart: ExactMediaTime?
    let nextOutputStart: ExactMediaTime?
    let sawFinalEmission: Bool
    let liveContextIdentity: UUID?
    let lastEmissionEvidenceDigest: Data?

    init(
        encoderIdentity: AACEncoderIdentity,
        inputCount: UInt64,
        inputDigest: Data,
        realSampleCount: Int64,
        totalDecodedFrames: Int64,
        leadingFrames: Int,
        trailingFrames: Int64,
        sampleRate: Int32? = nil,
        firstPhysicalStart: ExactMediaTime? = nil,
        firstOutputStart: ExactMediaTime? = nil,
        nextPhysicalStart: ExactMediaTime? = nil,
        nextOutputStart: ExactMediaTime? = nil,
        sawFinalEmission: Bool = false,
        liveContextIdentity: UUID? = nil,
        lastEmissionEvidenceDigest: Data? = nil
    ) {
        self.encoderIdentity = encoderIdentity
        self.inputCount = inputCount
        self.inputDigest = inputDigest
        self.realSampleCount = realSampleCount
        self.totalDecodedFrames = totalDecodedFrames
        self.leadingFrames = leadingFrames
        self.trailingFrames = trailingFrames
        self.sampleRate = sampleRate
        self.firstPhysicalStart = firstPhysicalStart
        self.firstOutputStart = firstOutputStart
        self.nextPhysicalStart = nextPhysicalStart
        self.nextOutputStart = nextOutputStart
        self.sawFinalEmission = sawFinalEmission
        self.liveContextIdentity = liveContextIdentity
        self.lastEmissionEvidenceDigest = lastEmissionEvidenceDigest
    }

    func matches(summary: AACStreamSummary) -> Bool {
        encoderIdentity == summary.identity
            && realSampleCount == summary.realSampleCount
            && totalDecodedFrames == summary.totalDecodedFrames
            && leadingFrames == summary.leadingFrames
            && trailingFrames == summary.trailingFrames
    }

    static func firstEmissionIsValid(
        decodedFrames: Int64,
        leadingFrames: Int64,
        trailingFrames: Int64
    ) -> Bool {
        guard decodedFrames > leadingFrames,
              leadingFrames >= 0,
              trailingFrames >= 0 else { return false }
        let untrimmedTail = decodedFrames.subtractingReportingOverflow(trailingFrames)
        return !untrimmedTail.overflow && leadingFrames <= untrimmedTail.partialValue
    }
}

struct SegmentedFMP4WriterUsage: Sendable, Equatable {
    let liveInputCount: Int
    let liveInputBytes: Int
    let inputAllocationCount: UInt64
    let inputReleaseCount: UInt64
    let segmentEvidenceCount: Int
    let segmentEvidenceSequenceCount: Int
    let pendingCallbackCount: Int
    let initializationCount: Int
    let mediaCallbackCount: Int
    let rolloverReason: WriterContinuationDecision?
    let lastNativeFragment: WriterNativeFragmentFacts?
    var retainedTerminalOwnershipCount: Int { liveInputCount }
}

struct AACEffectiveEndpointReceipt: Sendable, Hashable {
    let writerReceiptIdentity: UUID
    let binding: FMP4WriterBinding
    let encoderIdentity: AACEncoderIdentity
    let sampleRate: Int32
    let inputPhysicalBase: ExactMediaTime
    let inputEffectiveBase: ExactMediaTime
    let writtenPhysicalBase: ExactMediaTime
    let writtenEffectiveBase: ExactMediaTime
    let timelineOffset: ExactMediaTime
    let realSampleCount: Int64
    let totalDecodedFrames: Int64
    let leadingFrames: Int64
    let trailingFrames: Int64
    let inputEvidenceCount: Int
    let inputEvidenceDigest: Data
    let callbackEvidenceCount: Int
    let callbackEvidenceDigest: Data
    let mappingReportIdentity: UUID
    let initializationBackingIdentity: SealedMediaBackingIdentity
    let firstMedia: AACEndpointSealedObjectEvidence
    let terminalMedia: AACEndpointSealedObjectEvidence
    let terminalLogicalSequence: UInt64
    let lastEffectiveEnd: ExactMediaTime
    let terminalPhysicalEnd: ExactMediaTime
}

struct AACEndpointSealedObjectEvidence: Sendable, Hashable {
    let key: HLSResourceKey
    let backingIdentity: SealedMediaBackingIdentity
    let sealedDigest: Data
    let byteCount: Int
    let reportIdentity: UUID

    fileprivate init(_ object: SealedMediaObject) {
        key = HLSResourceKey(object)
        backingIdentity = object.backing.identity
        sealedDigest = object.digest
        byteCount = object.byteRange.length
        reportIdentity = object.report.identity
    }

    fileprivate init(key: HLSResourceKey,
                     backingIdentity: SealedMediaBackingIdentity,
                     sealedDigest: Data, byteCount: Int,
                     reportIdentity: UUID) {
        self.key = key
        self.backingIdentity = backingIdentity
        self.sealedDigest = sealedDigest
        self.byteCount = byteCount
        self.reportIdentity = reportIdentity
    }
}

/// Task17 writer terminal 唯一签发的 AAC 尾端 admission 能力。
/// 它冻结真实 append/callback digest 与 sealed backing；调用方不能填写 expected UUID/index。
final class AACWriterTerminalBinding: @unchecked Sendable {
    private enum Terminal {
        case success(AACEffectiveEndpointAuthority)
        case failure(SegmentedFMP4WriterFailure)
        case writerCancelled

        var result: Result<AACEffectiveEndpointAuthority, Error> {
            switch self {
            case let .success(authority):
                return .success(authority)
            case let .failure(error):
                return .failure(error)
            case .writerCancelled:
                return .failure(CancellationError())
            }
        }
    }

    private struct Waiter {
        let identity: UUID
        let continuation: CheckedContinuation<AACEffectiveEndpointAuthority, Error>
    }
    let binding: FMP4WriterBinding
    private let lock = NSLock()
    private var frozenTimelineMapping: AACWriterTimelineMappingReceipt?
    private weak var renditionAnchor: AACRenditionTerminalBinding?
    private var terminal: Terminal?
    private var waiter: Waiter?
    private var pendingCancellation: UUID?

    fileprivate init(binding: FMP4WriterBinding) { self.binding = binding }

#if DEBUG
    func inspectPreparationBindingAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        lock.withLock {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body("共享原AAC terminal binding（归属待完整账核对）", pointer, malloc_size(pointer))
            let lockPointer = UnsafeRawPointer(Unmanaged.passUnretained(lock).toOpaque())
            body("共享原AAC terminal binding锁（归属待核）", lockPointer, malloc_size(lockPointer))
            inspectNativePreparationWeakSideTable("AAC terminal binding", self, body)
        }
    }
#endif

    var endpointAuthority: AACEffectiveEndpointAuthority? {
        lock.withLock {
            guard case let .success(authority) = terminal else { return nil }
            return authority
        }
    }

    /// 只读映射来自 writer 首个真实 media report；它不读取、更不消费 terminal
    /// authority，因此普通 response terminal 与 publication max-CAS 不依赖 EOS。
    var timelineMappingReceipt: AACWriterTimelineMappingReceipt? {
        lock.withLock { frozenTimelineMapping }
    }

    /// writer terminal 只有一个固定通知槽；prepare 不轮询，也不能注册无界 waiter。
    func awaitEndpointAuthority() async throws -> AACEffectiveEndpointAuthority {
        let identity = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Result<AACEffectiveEndpointAuthority, Error>? in
                    if let terminal { return terminal.result }
                    if pendingCancellation == identity {
                        pendingCancellation = nil
                        return .failure(CancellationError())
                    }
                    guard waiter == nil else {
                        return .failure(AVPlayerItemCoordinatorFailure.capacityExceeded)
                    }
                    waiter = .init(identity: identity, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        }, onCancel: { [weak self] in
            self?.cancelWaiter(identity)
        })
    }

    fileprivate func seal(_ authority: AACEffectiveEndpointAuthority) {
        let continuation = lock.withLock {
            if case let .success(existing)? = terminal {
                precondition(existing === authority, "writer terminal binding 只能封存一次")
                return nil as CheckedContinuation<AACEffectiveEndpointAuthority, Error>?
            }
            precondition(terminal == nil, "失败/取消的 writer 不得封存 endpoint authority")
            terminal = .success(authority)
            let continuation = waiter?.continuation
            waiter = nil
            pendingCancellation = nil
            return continuation
        }
        continuation?.resume(returning: authority)
    }

    /// writer 失败或取消也是 binding 的一次性终态；必须同时结束现有及未来 waiter。
    fileprivate func fail(_ reason: SegmentedFMP4WriterTerminalReason) {
        let terminal: Terminal
        switch reason {
        case .failed:
            terminal = .failure(.diagnosedSystemFailure("aac.terminal.failed"))
        case .cancelled:
            terminal = .writerCancelled
        case .finished:
            preconditionFailure("成功 finish 后由 sealed endpoint authority 结束 binding")
        }
        let continuation = lock.withLock {
            guard self.terminal == nil else {
                return nil as CheckedContinuation<AACEffectiveEndpointAuthority, Error>?
            }
            self.terminal = terminal
            let continuation = waiter?.continuation
            waiter = nil
            pendingCancellation = nil
            return continuation
        }
        if case let .failure(error) = terminal.result {
            continuation?.resume(throwing: error)
        }
    }

    /// finish 已成功、但 endpoint 的 receipt/backing 身份校验失败时，成功 authority
    /// 已不可能再签发；用同一错误一次性结束固定槽，避免 prepare 永久等待。
    fileprivate func failEndpointValidation(_ failure: SegmentedFMP4WriterFailure) {
        let continuation = lock.withLock {
            guard terminal == nil else {
                return nil as CheckedContinuation<AACEffectiveEndpointAuthority, Error>?
            }
            terminal = .failure(failure)
            let continuation = waiter?.continuation
            waiter = nil
            pendingCancellation = nil
            return continuation
        }
        continuation?.resume(throwing: failure)
    }

    fileprivate func freezeTimelineMapping(
        _ receipt: AACWriterTimelineMappingReceipt,
        renditionAnchor: AACRenditionTerminalBinding
    ) {
        lock.withLock {
            precondition(receipt.binding == binding,
                         "writer timeline mapping 必须绑定同一 writer")
            precondition(frozenTimelineMapping == nil || frozenTimelineMapping == receipt,
                         "writer timeline mapping 只能冻结一次")
            precondition(self.renditionAnchor == nil || self.renditionAnchor === renditionAnchor,
                         "writer timeline mapping 只能绑定同一稳定rendition")
            frozenTimelineMapping = receipt
            self.renditionAnchor = renditionAnchor
        }
    }

    func acceptsRenditionAnchor(
        _ rendition: AACRenditionTerminalBinding,
        mapping: AACWriterTimelineMappingReceipt
    ) -> Bool {
        lock.withLock {
            renditionAnchor === rendition
                && frozenTimelineMapping == mapping
                && mapping.binding == binding
        }
    }

    private func cancelWaiter(_ identity: UUID) {
        let continuation = lock.withLock {
            guard let waiter else {
                pendingCancellation = identity
                return nil as CheckedContinuation<AACEffectiveEndpointAuthority, Error>?
            }
            guard waiter.identity == identity else { return nil }
            self.waiter = nil
            return waiter.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

final class AACEffectiveEndpointAuthority: @unchecked Sendable {
    let receipt: AACEffectiveEndpointReceipt
    let terminal: SegmentedFMP4WriterTerminalReceipt
    let initialization: AACEndpointSealedObjectEvidence
    let media: [AACEndpointSealedObjectEvidence]
    let terminalBinding: AACWriterTerminalBinding
    let renditionBinding: AACRenditionTerminalBinding?
    let publicationMembership: AACPublicationMembershipReceipt?
    let httpMembership: AACHTTPMembershipReceipt?
    private let lock = NSLock()
    private var consumed = false

    fileprivate init(receipt: AACEffectiveEndpointReceipt,
                     terminal: SegmentedFMP4WriterTerminalReceipt,
                     initialization: SealedMediaObject,
                     media: [SealedMediaObject],
                     terminalBinding: AACWriterTerminalBinding) {
        self.receipt = receipt
        self.terminal = terminal
        self.initialization = .init(initialization)
        self.media = media.map(AACEndpointSealedObjectEvidence.init)
        self.terminalBinding = terminalBinding
        renditionBinding = nil
        publicationMembership = nil
        httpMembership = nil
    }

    fileprivate init(receipt: AACEffectiveEndpointReceipt,
                     terminal: SegmentedFMP4WriterTerminalReceipt,
                     initialization: AACEndpointSealedObjectEvidence,
                     media: [AACEndpointSealedObjectEvidence],
                     terminalBinding: AACWriterTerminalBinding,
                     renditionBinding: AACRenditionTerminalBinding,
                     publicationMembership: AACPublicationMembershipReceipt,
                     httpMembership: AACHTTPMembershipReceipt) {
        self.receipt = receipt
        self.terminal = terminal
        self.initialization = initialization
        self.media = media
        self.terminalBinding = terminalBinding
        self.renditionBinding = renditionBinding
        self.publicationMembership = publicationMembership
        self.httpMembership = httpMembership
    }

    func consume() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

/// writer 首个真实媒体回调冻结的双时间域映射。它先于 terminal 可用，供
/// publisher 把物理 fMP4 区间与有效播放区间一起冻结；它本身不授予 EOS 权限。
struct AACWriterTimelineMappingReceipt: Sendable, Hashable {
    let binding: FMP4WriterBinding
    let reportIdentity: UUID
    let sampleRate: Int32
    let inputPhysicalBase: ExactMediaTime
    let inputEffectiveBase: ExactMediaTime
    let writtenPhysicalBase: ExactMediaTime
    let writtenEffectiveBase: ExactMediaTime
    let offset: ExactMediaTime

    /// 首个 input buffer 同时冻结 raw physical PTS 与 output effective PTS；
    /// 首个 writer report 只提供 physical base。effective mapping 必须由二者
    /// 的精确差值推导，调用方不能直接把 report PTS 冒充 effective base。
    fileprivate init(binding: FMP4WriterBinding,
         reportIdentity: UUID, sampleRate: Int32,
         inputPhysicalBase: ExactMediaTime, inputEffectiveBase: ExactMediaTime,
         writtenPhysicalBase: ExactMediaTime, leadingFrames: Int64) throws {
        guard sampleRate > 0, leadingFrames >= 0,
              inputEffectiveBase == (try inputPhysicalBase.adding(
                ExactMediaTime(value: leadingFrames, timescale: sampleRate))) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let offset = try writtenPhysicalBase.subtracting(inputPhysicalBase)
        self.binding = binding
        self.reportIdentity = reportIdentity
        self.sampleRate = sampleRate
        self.inputPhysicalBase = inputPhysicalBase
        self.inputEffectiveBase = inputEffectiveBase
        self.writtenPhysicalBase = writtenPhysicalBase
        self.writtenEffectiveBase = try inputEffectiveBase.adding(offset)
        self.offset = offset
    }
}

final class SegmentedFMP4Writer: SegmentedFMP4SystemCallbackSink, @unchecked Sendable {
    /// 构造器私有；唯一签发入口把一次真实系统 append 的成功结果绑定到准确事务。
    final class AppendSuccessAuthority: @unchecked Sendable {
        private let lock = NSLock()
        private let binding: FMP4WriterBinding
        private let trackKind: SegmentedFMP4TrackKind
        private let session: SegmentBoundarySession
        private let ticket: SegmentBoundaryAppendTicket
        private let sampleIdentity: SegmentBoundarySampleIdentity
        private var consumed = false

        private init(
            writer: SegmentedFMP4Writer,
            ticket: SegmentBoundaryAppendTicket,
            sampleIdentity: SegmentBoundarySampleIdentity
        ) {
            binding = writer.binding
            trackKind = writer.trackKind
            session = writer.boundarySession
            self.ticket = ticket
            self.sampleIdentity = sampleIdentity
        }

        /// 仅 writer 实现文件可调用；没有接受 caller 提供的成功布尔值的入口。
        fileprivate static func append(
            _ sampleBuffer: CMSampleBuffer,
            using writer: SegmentedFMP4Writer,
            ticket: SegmentBoundaryAppendTicket,
            sampleIdentity: SegmentBoundarySampleIdentity
        ) -> AppendSuccessAuthority? {
            guard writer.state == .started,
                  let inspection = writer.systemWriter as? any SegmentedFMP4SynchronousSystemWriting,
                  inspection.append(sampleBuffer),
                  writer.state == .started else { return nil }
            return AppendSuccessAuthority(writer: writer, ticket: ticket, sampleIdentity: sampleIdentity)
        }

        /// 资格仍只由真实 native append 返回签发；取消后的晚成功不会成为 commit 资格。
        fileprivate static func appendAwaitingReadiness(
            _ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
            using writer: SegmentedFMP4Writer,
            operationIdentity: UUID,
            ticket: SegmentBoundaryAppendTicket,
            sampleIdentity: SegmentBoundarySampleIdentity
        ) async throws -> AppendSuccessAuthority {
            try Task.checkCancellation()
            try await writer.systemWriter.appendAwaitingReadiness(sample)
            try Task.checkCancellation()
            return try writer.withLane {
                guard writer.state == .started,
                      writer.awaitingAppend?.identity == operationIdentity else {
                    throw SegmentedFMP4WriterFailure.illegalState
                }
                return AppendSuccessAuthority(writer: writer, ticket: ticket,
                                              sampleIdentity: sampleIdentity)
            }
        }

        func consume(
            binding: FMP4WriterBinding,
            trackKind: SegmentedFMP4TrackKind,
            sampleIdentity: SegmentBoundarySampleIdentity,
            session: SegmentBoundarySession,
            ticket: SegmentBoundaryAppendTicket
        ) -> Bool {
            lock.withLock {
                guard !consumed,
                      self.binding == binding,
                      self.trackKind == trackKind,
                      self.sampleIdentity == sampleIdentity,
                      self.session === session,
                      self.ticket === ticket else { return false }
                consumed = true
                return true
            }
        }
    }

    private enum State {
        case idle
        case started
        case finishing
        case retiring
        case terminal
    }

    private struct PendingCallback {
        let ticket: SegmentCallbackTicket
        let kind: SealedMediaObjectKind
        let logicalSequence: UInt64
        var boundary: SegmentCommittedBoundary? = nil
        var frameDuration: ExactMediaTime? = nil
    }

    private struct AACSnapshot {
        let epochIdentity: AACEncoderIdentity
        let inputCount: Int
        let inputDigest: Data
        let sampleRate: Int32
        let firstPhysicalStart: ExactMediaTime
        let firstOutputStart: ExactMediaTime
        let realSampleCount: Int
        let totalDecodedFrames: Int
        let leadingFrames: Int
        let trailingFrames: Int
    }

    private static let sampleChargeOverhead = 64
    private static let pendingCallbackCapacity = 3

    private var inputEvidenceCapacity: Int {
        switch trackKind {
        case .video:
            return 512
        case .aac:
            return 320
        case .ac3, .eac3:
            return 256
        }
    }

    let binding: FMP4WriterBinding
    let trackKind: SegmentedFMP4TrackKind
    private let sourceFormatHint: CMFormatDescription
    private let frozenFormat: SegmentedFMP4FrozenFormat
    private let videoCadencePolicy: SegmentedFMP4VideoCadencePolicy
    private let boundarySession: SegmentBoundarySession
    let compressedFormatConfiguration: CompressedAudioFormatConfiguration?
    private let ownershipLimits: SegmentedFMP4WriterOwnershipLimits
    private let recordAppendFailureOrdinal: Int?
#if DEBUG
    private var nativeInputAliasObserver: (@Sendable (CMBlockBuffer) -> Void)?

    /// Bounded regression observation of the actual paid block. Install once
    /// before start; the normal path has no closure or additional native owner.
    func observeNativeInputAliasesForTesting(
        _ observer: @escaping @Sendable (CMBlockBuffer) -> Void
    ) throws {
        try withLane {
            guard state == .idle, nativeInputAliasObserver == nil else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            nativeInputAliasObserver = observer
        }
    }
#endif
    private let relay: SegmentReportRelay
    private let lane: DispatchQueue
    private let laneKey = DispatchSpecificKey<UUID>()
    private let laneIdentity = UUID()
    private let publicationQueue: DispatchQueue
    private let publicationGroup = DispatchGroup()
    private let cleanupQueue: DispatchQueue
    private let cleanupGroup = DispatchGroup()
    private var systemWriter: (any SegmentedFMP4SystemWriting)!
    private var state: State = .idle
    private let acceptanceObservation: HLSWriterAcceptanceProbe.Rendition?
    private let inputAdmission: WriterInputAdmission
    private let compressedBackingAdmission: HLSDataPlaneAdmission
    private let segmentEvidence: WriterSegmentEvidence
    private let usesExplicitOwnershipLimits: Bool
    private var rolloverReason: WriterContinuationDecision?
    private var lastNativeFragment: WriterNativeFragmentFacts?
    private var maximumObservedInputBytes = 0
    private var boundaryReserve: WriterBoundaryReserve?
    private var aacSnapshot: AACSnapshot?
    private var aacSnapshotRevision: UInt64 = 0
    private var incrementalAACNextOrdinal: UInt64 = 0
    private var incrementalAACDigest = AACRenditionEncoder.initialEmissionDigest
    private var incrementalAACAccounting: AACIncrementalStreamAccounting?
    private var incrementalAACReceipt: AACIncrementalWriterReceipt?
    private var incrementalAACLiveContext: AACLiveEncodingContext?
    private let incrementalAACFirstGlobalOrdinal: UInt64
    private var windowFirstPhysicalStart: ExactMediaTime?
    private var windowFirstOutputStart: ExactMediaTime?
    private var windowSampleRate: Int32?
    private var windowLeadingFrames: Int64 = 0
    private var firstAACMediaEvidence: AACEndpointSealedObjectEvidence?
    private var terminalAACMediaEvidence: AACEndpointSealedObjectEvidence?
    private var windowContinuationIssued = false
    private var pendingCallbacks: [PendingCallback] = [] {
        didSet { acceptanceObservation?.callbacksChanged(by: pendingCallbacks.count - oldValue.count) }
    }
    private var currentSegmentProjectedBytes = 0
    private var currentSegmentInputCount = 0
    private var currentPublicationBoundary: SegmentCommittedBoundary?
    private var currentFrameDuration: ExactMediaTime?
    private struct VideoCadence {
        let duration: ExactMediaTime
        let nextPTS: ExactMediaTime
    }
    private var videoCadence: VideoCadence?
    private struct RemuxVideoCadence {
        let duration: ExactMediaTime
        let lastDecodeTimeStamp: ExactMediaTime
        let nextDecodeTimeStamp: ExactMediaTime
        let requiresExactNext: Bool
    }
    private struct CompressedCadence {
        let duration: ExactMediaTime
        let nextPTS: ExactMediaTime
    }
    private struct AppendPreflightFacts {
        let formatDescription: CMFormatDescription
        let duration: ExactMediaTime?
        let presentationTimeStamp: ExactMediaTime?
        let decodeTimeStamp: ExactMediaTime?
        let projectedCharge: Int
        let sampleCount: Int
        var remuxBitrateEnvelope: VideoBitrateEnvelope? = nil
    }
    private struct AppendPreflightAdmission {
        var flushTicket: SegmentCallbackTicket?
        var inputLifetime: WriterInputLifetime?
        let inputBytes: Int
        let remuxByteBudget: WriterRemuxByteBudget?
        let evidence: WriterSegmentEvidence.Reservation
    }
    private enum ReadinessFailurePolicy {
        case terminal
        case recoverable
        case awaiting
    }
    private struct AwaitingAppend: Sendable {
        let identity: UUID
        let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
        let ticket: SegmentBoundaryAppendTicket
        let sampleIdentity: SegmentBoundarySampleIdentity
        let native: Task<AppendSuccessAuthority, Error>
        let facts: NativeSampleFacts
        let evidence: WriterSegmentEvidence.Reservation
        let validatesSource: @Sendable (NativeSampleFacts) throws -> Bool
    }
    private var awaitingAppend: AwaitingAppend?
    private var awaitingAACBatch: UUID?
    private var finishRequested = false
    private var remuxVideoCadence: RemuxVideoCadence?
    private var compressedCadence: CompressedCadence?
    private var remuxFormatAuthorityWitness: AnyObject?
    private var remuxBitrateEnvelope: VideoBitrateEnvelope?
    private var cadenceIsValid = true
    private let callbackContext: SegmentedFMP4CallbackContext
    private var ownsPublicationSource = false
    private var inputCount = 0
    private var initializationCallbackCount = 0
    private var mediaCallbackCount = 0
    private let initialMovieFragmentSequenceNumber: Int
    private var lastLogicalSequence: UInt64?
    private let windowCallbackMembership = AACMediaMembershipAccumulator()
    private var callbackEvidenceCount = 0
    private var callbackEvidenceDigest = Data(SHA256.hash(data: Data()))
    private var initializationBackingIdentity: SealedMediaBackingIdentity?
    private var lastCallbackReportIdentity: UUID?
    private var finishSystemSucceeded = false
    private var finishContinuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
    private var storedTerminalReceipt: SegmentedFMP4WriterTerminalReceipt?
    private var firstSystemFailureDiagnostic: ErrorDiagnosticSnapshot?
    private var firstTypedCallbackFailure: SegmentedFMP4WriterFailure?
    private weak var compressedCapacityWakeup: WriterCapacityWakeup?
    /// endpoint receipt/authority 与 terminal binding 必须在 writer lane 内作为
    /// 一个不可分割的终态推进。成功后的并发 loser 只能被拒绝，不能再把
    /// 已封存的 binding 覆盖成 failure。
    private enum AACEndpointResolution {
        case open
        case authoritySealed
        case failed
    }
    private var endpointResolution: AACEndpointResolution = .open
    private var timelineMappingReceipt: AACWriterTimelineMappingReceipt?
    private var rolloverPending = false
    let compressedSourceLayout: AudioChannelLayout?
    let sourceAACConfiguration: SourceAACWriterConfiguration?
    let sourceAACTerminalBinding: SourceAACWriterTerminalBinding?
    private let sourceAACOrigin: SourceAACWriterOrigin?
    let aacTerminalBinding: AACWriterTerminalBinding?
    let aacRenditionTerminalBinding: AACRenditionTerminalBinding?
    let aacWriterWindowAdmission: AACWriterWindowAdmission?
    let writerWindowAdmission: WriterWindowAdmission?

    init(
        binding: FMP4WriterBinding,
        trackKind: SegmentedFMP4TrackKind,
        sourceFormatHint: CMFormatDescription,
        boundarySession: SegmentBoundarySession,
        compressedFormatConfiguration: CompressedAudioFormatConfiguration?,
        videoCadencePolicy: SegmentedFMP4VideoCadencePolicy = .strict,
        ownershipLimits: SegmentedFMP4WriterOwnershipLimits? = nil,
        relay: SegmentReportRelay,
        systemFactory: any SegmentedFMP4SystemWriterFactory,
        aacContinuation: AACWriterWindowContinuation? = nil,
        writerWindowContinuation: WriterWindowContinuation? = nil,
        recordAppendFailureOrdinal: Int? = nil,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
        acceptanceProbe: HLSWriterAcceptanceProbe? = nil,
        sourceAACConfiguration: SourceAACWriterConfiguration? = nil,
        compressedSourceLayout: AudioChannelLayout? = nil
    ) throws {
        self.binding = binding
        self.trackKind = trackKind
        self.sourceFormatHint = sourceFormatHint
        self.sourceAACConfiguration = sourceAACConfiguration
        self.compressedSourceLayout = compressedSourceLayout
        if let compressedSourceLayout {
            guard trackKind == .ac3 || trackKind == .eac3,
                  compressedFormatConfiguration != nil,
                  try CompressedAudioChannelPositions.bitmap(in: sourceFormatHint)
                    == CompressedAudioChannelPositions.bitmap(from: compressedSourceLayout) else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
        }
        if let sourceAACConfiguration {
            guard trackKind == .aac, aacContinuation == nil,
                  compressedFormatConfiguration == nil,
                  CMFormatDescriptionEqual(sourceFormatHint, otherFormatDescription: sourceAACConfiguration.sourceFormatHint),
                  sourceAACConfiguration.authority.stream.isCurrent else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
        } else if writerWindowContinuation?.sourceAACBinding != nil {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        self.videoCadencePolicy = videoCadencePolicy
        guard let frozenFormat = SegmentedFMP4FrozenFormat(sourceFormatHint) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        self.frozenFormat = frozenFormat
        self.boundarySession = boundarySession
        self.compressedFormatConfiguration = compressedFormatConfiguration
        self.ownershipLimits = ownershipLimits ?? (trackKind == .video ? .video : (trackKind == .aac ? .audio : .standard))
        usesExplicitOwnershipLimits = ownershipLimits != nil
        maximumObservedInputBytes = aacContinuation?.maximumObservedInputBytes
            ?? writerWindowContinuation?.maximumObservedInputBytes ?? 0
        acceptanceObservation = acceptanceProbe?.register(binding: binding,
            hardInputCount: self.ownershipLimits.hardCapacity,
            hardInputBytes: trackKind == .video ? FMP4WriterLimits.video.writerHardByteCount
                : FMP4WriterLimits.audio.writerHardByteCount,
            hardEvidenceCount: (trackKind == .video ? 512 : (trackKind == .aac ? 320 : 256)) * 4,
            hardCallbackCount: Self.pendingCallbackCapacity + 1)
        inputAdmission = aacContinuation?.inputAdmission ?? writerWindowContinuation?.inputAdmission
            ?? WriterInputAdmission(capacity: self.ownershipLimits.hardCapacity,
            maximumBytes: trackKind == .video ? FMP4WriterLimits.video.writerHardByteCount
                : FMP4WriterLimits.audio.writerHardByteCount,
            applicationLedger: applicationLedger, observation: acceptanceObservation)
        compressedBackingAdmission = writerWindowContinuation?.compressedBackingAdmission
            ?? HLSDataPlaneAdmission(capacity: self.ownershipLimits.hardCapacity,
            maximumBytes: FMP4WriterLimits.audio.writerHardByteCount, applicationLedger: applicationLedger)
        segmentEvidence = WriterSegmentEvidence(sampleCapacity: trackKind == .video ? 512 : (trackKind == .aac ? 320 : 256),
            applicationLedger: applicationLedger, observation: acceptanceObservation)
        self.recordAppendFailureOrdinal = recordAppendFailureOrdinal
        self.relay = relay
        guard aacContinuation == nil || writerWindowContinuation == nil else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        if let continuation = aacContinuation {
            guard trackKind == .aac, sourceAACConfiguration == nil,
                  continuation.claim(next: binding),
                  continuation.context.migrate(
                    from: continuation.receipt.binding,
                    to: binding,
                    using: continuation
                  ) else { throw SegmentedFMP4WriterFailure.aacEndpointMismatch }
            incrementalAACAccounting = continuation.accounting
            incrementalAACNextOrdinal = continuation.accounting.inputCount
            incrementalAACDigest = continuation.accounting.inputDigest
            incrementalAACLiveContext = continuation.context
            incrementalAACFirstGlobalOrdinal = continuation.accounting.inputCount
            aacRenditionTerminalBinding = continuation.renditionBinding
            aacWriterWindowAdmission = AACWriterWindowAdmission(
                continuation: continuation, binding: binding)
        } else {
            incrementalAACFirstGlobalOrdinal = 0
            aacRenditionTerminalBinding = trackKind == .aac && sourceAACConfiguration == nil
                ? AACRenditionTerminalBinding(binding) : nil
            aacWriterWindowAdmission = nil
        }
        if let continuation = writerWindowContinuation {
            remuxFormatAuthorityWitness = continuation.remuxFormatAuthorityWitness
            remuxBitrateEnvelope = continuation.remuxBitrateEnvelope
            guard trackKind != .aac || sourceAACConfiguration != nil,
                  continuation.claim(next: binding, trackKind: trackKind,
                                     frozenFormat: frozenFormat) else {
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            writerWindowAdmission = WriterWindowAdmission(
                continuation: continuation, binding: binding, trackKind: trackKind)
            switch continuation.cadence {
            case let .video(duration, nextPTS):
                guard trackKind == .video else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                videoCadence = .init(duration: duration, nextPTS: nextPTS)
            case let .remuxVideo(duration, nextDecodeTimeStamp):
                guard trackKind == .video else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                remuxVideoCadence = .init(
                    duration: duration,
                    lastDecodeTimeStamp: try nextDecodeTimeStamp.subtracting(duration),
                    nextDecodeTimeStamp: nextDecodeTimeStamp,
                    requiresExactNext: true)
            case let .compressed(duration, nextPTS):
                guard trackKind == .ac3 || trackKind == .eac3 || sourceAACConfiguration != nil else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                compressedCadence = .init(duration: duration, nextPTS: nextPTS)
            case nil:
                break
            }
        } else {
            writerWindowAdmission = nil
        }
        if let sourceAACConfiguration {
            let origin = SourceAACWriterOrigin(authority: sourceAACConfiguration.authority, binding: binding,
                predecessor: writerWindowContinuation?.predecessorTerminal.binding)
            sourceAACOrigin = origin
            if let continuation = writerWindowContinuation {
                guard let previous = continuation.sourceAACBinding,
                      previous.configuration.authority === sourceAACConfiguration.authority else {
                    throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
                }
                try previous.beginWindow(origin: origin, predecessor: continuation.predecessorTerminal)
                sourceAACTerminalBinding = previous
            } else {
                sourceAACTerminalBinding = try SourceAACWriterTerminalBinding(origin: origin,
                    configuration: sourceAACConfiguration, applicationLedger: applicationLedger)
            }
        } else { sourceAACOrigin = nil; sourceAACTerminalBinding = nil }
        initialMovieFragmentSequenceNumber = aacContinuation?.nextMovieFragmentSequenceNumber
            ?? writerWindowContinuation?.nextMovieFragmentSequenceNumber ?? 1
        aacTerminalBinding = trackKind == .aac && sourceAACConfiguration == nil
            ? AACWriterTerminalBinding(binding: binding) : nil
        callbackContext = SegmentedFMP4CallbackContext(binding: binding, session: boundarySession,
            source: sourceFormatHint, relay: relay)
        lane = DispatchQueue(label: "org.vplayer.hls.fmp4-writer.\(binding.writerIdentity.rawValue)")
        publicationQueue = DispatchQueue(
            label: "org.vplayer.hls.fmp4-writer-publication.\(binding.writerIdentity.rawValue)"
        )
        cleanupQueue = DispatchQueue(
            label: "org.vplayer.hls.fmp4-writer-cleanup.\(binding.writerIdentity.rawValue)"
        )
        lane.setSpecific(key: laneKey, value: laneIdentity)
        guard self.ownershipLimits.rolloverThreshold > 0,
              self.ownershipLimits.rolloverThreshold < self.ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        try Self.validateFrozenFormat(
            trackKind: trackKind,
            sourceFormatHint: sourceFormatHint,
            compressedConfiguration: compressedFormatConfiguration
        )
        let mediaType: AVMediaType = trackKind == .video ? .video : .audio
        let configuration = SegmentedFMP4SystemConfiguration(
            contentTypeIdentifier: UTType.mpeg4Movie.identifier,
            outputFileTypeProfile: AVFileTypeProfile.mpeg4AppleHLS.rawValue,
            preferredOutputSegmentInterval: .indefinite,
            mediaType: mediaType,
            outputSettingsAreNil: true,
            sourceFormatHintIdentity: ObjectIdentifier(sourceFormatHint),
            inputCount: 1,
            callbackContext: callbackContext,
            initialMovieFragmentSequenceNumber: initialMovieFragmentSequenceNumber
        )
        systemWriter = try systemFactory.makeWriter(
            configuration: configuration,
            sourceFormatHint: sourceFormatHint,
            callbackSink: self
        )
        guard !callbackContext.isBound || callbackContext.accepts(adapter: systemWriter, writer: systemWriter.objectIdentity) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        if callbackContext.isBound {
            try relay.bindPublicationSource(callbackContext)
            ownsPublicationSource = true
        }
    }

    deinit {
        withLane {
            guard state != .terminal, let systemWriter else { return }
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.cancelled)
        }
        relay.notifyPublicationDrainIfReady()
    }

    var terminalReceipt: SegmentedFMP4WriterTerminalReceipt? {
        withLane { storedTerminalReceipt }
    }

    /// A declaration ceiling derived from the admitted decoder configuration.
    /// This does not enlarge media/cache budgets; measured bytes still enforce it.
    static func audioPeakEnvelope(configuration: CompressedAudioFormatConfiguration?) -> UInt64 {
        if case let .eac3(value) = configuration {
            return max(2_048_000, UInt64(value.maximumDataRateKbps) * 1_000 + 256_000)
        }
        return 2_048_000
    }

    var usage: SegmentedFMP4WriterUsage {
        withLane {
            SegmentedFMP4WriterUsage(
                liveInputCount: inputAdmission.usage.count,
                liveInputBytes: inputAdmission.usage.bytes,
                inputAllocationCount: inputAdmission.allocationCount,
                inputReleaseCount: inputAdmission.releaseCount,
                segmentEvidenceCount: segmentEvidence.sampleCount,
                segmentEvidenceSequenceCount: segmentEvidence.sequenceCount,
                pendingCallbackCount: pendingCallbacks.count,
                initializationCount: initializationCallbackCount,
                mediaCallbackCount: mediaCallbackCount,
                rolloverReason: rolloverReason,
                lastNativeFragment: lastNativeFragment
            )
        }
    }

    var incrementalAACCommittedInputCount: UInt64 {
        withLane { incrementalAACAccounting?.inputCount ?? 0 }
    }

    var isAACWriterWindowRolloverPending: Bool {
        withLane { trackKind == .aac && sourceAACConfiguration == nil && rolloverPending && state == .started }
    }

    var aacCallbackMembershipSnapshot: AACMediaMembershipSnapshot? {
        aacRenditionTerminalBinding?.callbackMembership.snapshot
    }

    func start(at requestedTime: CMTime) throws {
        let sourceTime = sourceAACConfiguration?.firstPresentationTime.cmTime ?? requestedTime
        try withLane {
            guard sourceTime.isNumeric, sourceTime.epoch == 0, state == .idle else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            let ticket = try relay.reserve(
                kind: .initialization,
                logicalSequence: 0,
                projectedByteCount: 0
            )
            pendingCallbacks.append(.init(
                ticket: ticket,
                kind: .initialization,
                logicalSequence: 0
            ))
            guard systemWriter.startWriting(at: sourceTime) else {
                let failure = systemFailureIsolated()
                systemWriter.cancelWriting()
                _ = signTerminalIsolated(.failed)
                throw failure
            }
            guard state == .idle else { throw systemFailureIsolated() }
            state = .started
        }
    }

    func appendVideo(
        _ output: HLSVideoEncodedOutput,
        ticket: SegmentBoundaryAppendTicket
    ) throws {
        let identity = try SegmentBoundaryCoordinator.videoIdentity(output)
        do {
            try withLane {
                try appendTypedIsolated(
                    output.sampleBuffer,
                    ticket: ticket,
                    sampleIdentity: identity,
                    ownership: FMP4InputOwnership()
                )
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    func appendVideoAwaitingReadiness(
        _ output: HLSVideoEncodedOutput,
        ticket: SegmentBoundaryAppendTicket
    ) async throws {
        do {
            try Task.checkCancellation()
            let identity = try SegmentBoundaryCoordinator.videoIdentity(output)
            let operation = try withLane {
                var admission = try preflightTypedIsolated(output.sampleBuffer,
                    ticket: ticket, sampleIdentity: identity,
                    readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                return try beginAwaitingAppendIsolated(output.sampleBuffer,
                    ticket: ticket, sampleIdentity: identity,
                    ownership: FMP4InputOwnership(),
                    validatesSource: { try NativeSampleFacts.freeze(output.sampleBuffer) == $0 },
                    admission: &admission)
            }
            try await completeAwaitingAppend(operation)
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    func appendRemuxVideoAwaitingReadiness(
        _ submission: HLSVideoRemuxSubmission,
        ticket: SegmentBoundaryAppendTicket
    ) async throws {
        let attempt: HLSVideoRemuxWriterAttempt
        do { attempt = try submission.currentWriterAttempt(binding: binding) }
        catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        try await appendRemuxVideoAwaitingReadiness(attempt, ticket: ticket)
    }

    func appendRemuxVideoAwaitingReadiness(
        _ attempt: HLSVideoRemuxWriterAttempt,
        ticket: SegmentBoundaryAppendTicket
    ) async throws {
        do {
            try Task.checkCancellation()
            guard trackKind == .video, attempt.writerBinding == binding else {
                throw SegmentedFMP4WriterFailure.boundaryMismatch
            }
            let identity = try SegmentBoundaryCoordinator.remuxVideoIdentity(attempt)
            let operation = try withLane {
                guard remuxFormatAuthorityWitness == nil
                    || remuxFormatAuthorityWitness === attempt.remuxFormatAuthorityWitness else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                // rollover、票据及容量仍在唯一 payload claim 前验证。
                var admission = try preflightRemuxAdmissionIsolated(attempt,
                    ticket: ticket, sampleIdentity: identity,
                    readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                try flushIfRequiredIsolated(ticket, admission: &admission)
                let sample = try attempt.materializeForWriter(
                    HLSVideoRemuxWriterMaterializationAuthority(binding: binding))
                return try beginAwaitingAppendIsolated(sample, ticket: ticket,
                    sampleIdentity: identity,
                    ownership: FMP4InputOwnership(),
                    validatesSource: { _ in try attempt.validatesFrozenIdentity() },
                    admission: &admission)
            }
            try await completeAwaitingAppend(operation) {
                self.remuxFormatAuthorityWitness = attempt.remuxFormatAuthorityWitness
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            _ = attempt.relinquishAfterAbort()
            throw error
        }
    }

    func appendRemuxVideo(
        _ submission: HLSVideoRemuxSubmission,
        ticket: SegmentBoundaryAppendTicket
    ) throws {
        guard trackKind == .video else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        let attempt: HLSVideoRemuxWriterAttempt
        do {
            attempt = try submission.currentWriterAttempt(binding: binding)
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        try appendRemuxVideo(attempt, ticket: ticket)
    }

    func appendRemuxVideo(
        _ attempt: HLSVideoRemuxWriterAttempt,
        ticket: SegmentBoundaryAppendTicket
    ) throws {
        guard trackKind == .video,
              attempt.writerBinding == binding else {
            ticket.abort(binding: binding, session: boundarySession)
            _ = attempt.relinquishAfterAbort()
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        do {
            let identity = try SegmentBoundaryCoordinator.remuxVideoIdentity(attempt)
            try withLane {
                guard remuxFormatAuthorityWitness == nil
                        || remuxFormatAuthorityWitness === attempt.remuxFormatAuthorityWitness else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                var admission = try preflightRemuxAdmissionIsolated(
                    attempt, ticket: ticket, sampleIdentity: identity
                )
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                try flushIfRequiredIsolated(ticket, admission: &admission)
                let sample = try attempt.materializeForWriter(
                    HLSVideoRemuxWriterMaterializationAuthority(binding: binding)
                )
                try appendAfterPreflightIsolated(
                    sample,
                    ticket: ticket,
                    sampleIdentity: identity,
                    ownership: FMP4InputOwnership(),
                    admission: &admission
                )
                remuxFormatAuthorityWitness = attempt.remuxFormatAuthorityWitness
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            _ = attempt.relinquishAfterAbort()
            throw error
        }
    }

    /// Service proofs retain raw source PTS; only the private timeline mapping
    /// translates native samples and boundary identity into the same output time.
    func installCompressedCapacityWakeup(_ wakeup: WriterCapacityWakeup) throws {
        try withLane {
            guard compressedCapacityWakeup == nil || compressedCapacityWakeup === wakeup else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            try inputAdmission.installCapacityWakeup(wakeup)
            try relay.installCapacityWakeup(wakeup)
            compressedCapacityWakeup = wakeup
        }
    }

    func appendSourceAACAwaitingReadiness(_ unit: SourceAACAccessUnit,
                                         boundary: SegmentBoundaryCoordinator) async throws {
        try Task.checkCancellation()
        guard let configuration = sourceAACConfiguration, let origin = sourceAACOrigin,
              let terminalBinding = sourceAACTerminalBinding,
              configuration.authority === unit.configuration.authority, unit.binding == binding,
              boundary.session === boundarySession, terminalBinding.acceptsInput(unit, origin: origin) else {
            throw SourceAACFailure.sourceMismatch
        }
        let ticket = try boundary.issueSourceAACAppend(for: unit, writerBinding: binding)
        do {
            let identity = SegmentBoundaryCoordinator.sourceAACIdentity(unit)
            let projected = unit.payload.count.addingReportingOverflow(Self.sampleChargeOverhead)
            guard !projected.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            let operation = try withLane {
                var admission = try preflightAppendCoreIsolated(facts: .init(
                    formatDescription: sourceFormatHint, duration: unit.duration,
                    presentationTimeStamp: unit.presentationStart, decodeTimeStamp: unit.presentationStart,
                    projectedCharge: projected.partialValue, sampleCount: 1), ticket: ticket,
                    sampleIdentity: identity, readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                let prepared = try makeSourceAACSampleBuffer(unit)
                let sample = prepared.sample
                return try beginAwaitingAppendIsolated(sample, ticket: ticket, sampleIdentity: identity,
                    ownership: FMP4InputOwnership(), validatesSource: { _ in unit.validates() },
                    admission: &admission, claimOwnership: {
                        guard terminalBinding.acceptsInput(unit, origin: origin), unit.claimForAppend() else {
                            throw SourceAACFailure.sourceAlreadyConsumed
                        }
                        prepared.lifetime.markNativeAdopted()
                    })
            }
            try await completeAwaitingAppend(operation) {
                try terminalBinding.recordInput(unit, origin: origin)
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    /// Natural source drain is independent from finishWriterWindow().
    func finishSourceAAC() async throws -> SourceAACFinalSeal {
        guard let origin = sourceAACOrigin, let sourceAACTerminalBinding else {
            throw SourceAACFailure.writerBindingMismatch
        }
        let terminal = try await finish()
        return try withLane {
            try sourceAACTerminalBinding.finishWindow(origin: origin, terminal: terminal)
            return try sourceAACTerminalBinding.sealSourceEOF(origin: origin, terminal: terminal)
        }
    }

    func appendMappedCompressedAwaitingReadiness(
        _ submission: CompressedAudioWriterSubmission,
        timed: HLSTimedAudioAccessUnit,
        coordinator: AudioServiceSemanticCoordinator,
        boundary: SegmentBoundaryCoordinator,
        nativeTail: DolbyAudioPayloadLifetime
    ) async throws {
        try Task.checkCancellation()
        guard boundary.session === boundarySession,
              timed.validatesCompressedSubmission(submission),
              let frozen = compressedFormatConfiguration,
              frozen == submission.formatConfiguration,
              let lastUse = submission.accessUnit.writerLastUseReceipt else {
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        guard coordinator.hasCompressedWriterSubmissionCapacity else {
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let ownerBindingMatches: Bool
        switch submission.admissionIdentity {
        case let .directCompressed(owner, _, _), let .eac3Aggregation(owner, _, _):
            switch owner {
            case let .audioVideo(lifecycle, item, epoch, participant, rendition),
                 let .audioOnly(lifecycle, _, _, item, epoch, participant, rendition):
                ownerBindingMatches = lifecycle == binding.outputLifecycleEpoch && item == binding.itemGeneration
                    && epoch == binding.mediaEpoch && participant == binding.publicationParticipantID
                    && rendition == binding.renditionIdentity
            }
        case .decoder: ownerBindingMatches = false
        }
        guard ownerBindingMatches else { throw SegmentedFMP4WriterFailure.compressedIdentityMismatch }
        let expected = CompressedAudioWriterExpectedIdentity(codec: frozen.codec,
            admissionIdentity: submission.admissionIdentity, formatConfiguration: frozen)
        guard expected.accepts(submission),
              trackKind == (frozen.codec == .ac3 ? .ac3 : .eac3) else {
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        let ticket = try boundary.issueMappedCompressedAudioAppend(submission, timed: timed, writerBinding: binding)
        do {
            let identity = try SegmentBoundaryCoordinator.mappedCompressedIdentity(submission, timed: timed)
            let projected = submission.accessUnit.payloadRange.length.addingReportingOverflow(Self.sampleChargeOverhead)
            guard !projected.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            let operation = try withLane {
                var admission = try preflightAppendCoreIsolated(facts: .init(
                    formatDescription: sourceFormatHint,
                    duration: ExactMediaTime(value: Int64(submission.accessUnit.sampleCount), timescale: submission.accessUnit.sampleRate),
                    presentationTimeStamp: timed.timing.presentationTimeStamp, decodeTimeStamp: timed.timing.presentationTimeStamp,
                    projectedCharge: projected.partialValue, sampleCount: 1), ticket: ticket,
                    sampleIdentity: identity, readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                var backingLifetime: WriterInputLifetime?
                let sample = try makeCompressedSampleBuffer(submission.accessUnit,
                    presentationStart: timed.timing.presentationTimeStamp.cmTime, nativeTail: nativeTail,
                    retainedLifetime: { backingLifetime = $0 })
                guard let backingLifetime else { throw SegmentedFMP4WriterFailure.illegalState }
                return try beginAwaitingAppendIsolated(sample, ticket: ticket, sampleIdentity: identity,
                    ownership: FMP4InputOwnership {
                        _ = coordinator.finishCompressedAudioWriterLastUse(lastUse)
                    }, validatesSource: { _ in
                        timed.validatesCompressedSubmission(submission) && expected.accepts(submission)
                    }, admission: &admission, claimOwnership: {
                        guard timed.validatesCompressedSubmission(submission),
                              coordinator.claimCompressedAudioWriterSubmission(submission, expectedIdentity: expected) else {
                            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
                        }
                        backingLifetime.markNativeAdopted()
                    })
            }
            try await completeAwaitingAppend(operation)
            guard timed.validatesCompressedSubmission(submission) else {
                throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    func appendCompressedAwaitingReadiness(
        _ submission: CompressedAudioWriterSubmission,
        coordinator: AudioServiceSemanticCoordinator,
        ticket: SegmentBoundaryAppendTicket
    ) async throws {
        if Task.isCancelled {
            ticket.abort(binding: binding, session: boundarySession)
            throw CancellationError()
        }
        guard let frozenConfiguration = compressedFormatConfiguration else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        let expectedKind: SegmentedFMP4TrackKind = frozenConfiguration.codec == .ac3 ? .ac3 : .eac3
        let expectedIdentity = CompressedAudioWriterExpectedIdentity(
            codec: frozenConfiguration.codec,
            admissionIdentity: submission.accessUnit.admissionIdentity,
            formatConfiguration: frozenConfiguration
        )
        let submittedLifecycle: OutputLifecycleEpoch?
        switch submission.admissionIdentity {
        case .directCompressed(let owner, _, _), .eac3Aggregation(let owner, _, _):
            switch owner {
            case .audioVideo(let lifecycle, _, _, _, _),
                 .audioOnly(let lifecycle, _, _, _, _, _, _):
                submittedLifecycle = lifecycle
            }
        case .decoder:
            submittedLifecycle = nil
        }
        guard submittedLifecycle == binding.outputLifecycleEpoch,
              trackKind == expectedKind,
              expectedIdentity.accepts(submission) else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        guard coordinator.hasCompressedWriterSubmissionCapacity else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let sampleBuffer = try makeCompressedSampleBuffer(submission.accessUnit)
        let identity = try SegmentBoundaryCoordinator.compressedIdentity(submission.accessUnit)
        do {
            let operation = try withLane {
                var admission = try preflightTypedIsolated(sampleBuffer,
                    ticket: ticket, sampleIdentity: identity,
                    readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                // The owner is constructed only after the coordinator grants the claim.
                // A rejected preflight leaves the transferred producer lease untouched.
                return try beginAwaitingAppendIsolated(sampleBuffer, ticket: ticket,
                    sampleIdentity: identity,
                    ownership: FMP4InputOwnership {
                        _ = submission.accessUnit.confirmWriterInputLastUse(using: coordinator)
                    },
                    validatesSource: { _ in expectedIdentity.accepts(submission) },
                    admission: &admission, claimOwnership: {
                        guard coordinator.claimCompressedAudioWriterSubmission(submission,
                            expectedIdentity: expectedIdentity) else {
                            systemWriter.cancelWriting()
                            _ = signTerminalIsolated(.failed)
                            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
                        }
                    })
            }
            try await completeAwaitingAppend(operation)
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    func appendCompressed(
        _ submission: CompressedAudioWriterSubmission,
        coordinator: AudioServiceSemanticCoordinator,
        ticket: SegmentBoundaryAppendTicket
    ) throws {
        guard let frozenConfiguration = compressedFormatConfiguration else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        let expectedKind: SegmentedFMP4TrackKind = frozenConfiguration.codec == .ac3 ? .ac3 : .eac3
        let expectedIdentity = CompressedAudioWriterExpectedIdentity(
            codec: frozenConfiguration.codec,
            admissionIdentity: submission.accessUnit.admissionIdentity,
            formatConfiguration: frozenConfiguration
        )
        let submittedLifecycle: OutputLifecycleEpoch?
        switch submission.admissionIdentity {
        case .directCompressed(let owner, _, _), .eac3Aggregation(let owner, _, _):
            switch owner {
            case .audioVideo(let lifecycle, _, _, _, _),
                 .audioOnly(let lifecycle, _, _, _, _, _, _):
                submittedLifecycle = lifecycle
            }
        case .decoder:
            submittedLifecycle = nil
        }
        guard submittedLifecycle == binding.outputLifecycleEpoch,
              trackKind == expectedKind,
              expectedIdentity.accepts(submission) else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
        guard coordinator.hasCompressedWriterSubmissionCapacity else {
            ticket.abort(binding: binding, session: boundarySession)
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let sampleBuffer = try makeCompressedSampleBuffer(submission.accessUnit)
        let identity = try SegmentBoundaryCoordinator.compressedIdentity(submission.accessUnit)
        do {
            try withLane {
                var admission = try preflightTypedIsolated(
                    sampleBuffer, ticket: ticket, sampleIdentity: identity
                )
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                try flushIfRequiredIsolated(ticket, admission: &admission)
                guard state == .started else {
                    throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
                }
                guard ticket.prepare(
                        binding: binding,
                        trackKind: trackKind,
                        sampleIdentity: identity,
                        session: boundarySession
                      ), coordinator.claimCompressedAudioWriterSubmission(
                        submission,
                        expectedIdentity: expectedIdentity
                      ) else {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
                }
                let ownership = FMP4InputOwnership {
                    _ = submission.accessUnit.confirmWriterInputLastUse(using: coordinator)
                }
                let nativeSample = try makeNativeInputIsolated(sampleBuffer, ownership: ownership, admission: &admission)
                guard appendAndCommitIsolated(nativeSample, ticket: ticket, sampleIdentity: identity) else {
                    let failure = systemFailureIsolated()
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw failure
                }
                try recordAppendIsolated(sampleBuffer, ticket: ticket, evidence: admission.evidence)
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
            throw error
        }
    }

    func appendAACEncodedEpoch(
        _ epoch: AACEncodedEpoch,
        coordinator: SegmentBoundaryCoordinator
    ) throws {
        guard trackKind == .aac, sourceAACConfiguration == nil,
              !epoch.buffers.isEmpty,
              coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        // Bound this live batch before allocating identities and boundary previews.
        // The fixed-size snapshot also accounts for already released earlier batches.
        guard epoch.buffers.count <= ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
        }
        let snapshotBaseline = withLane { (aacSnapshotRevision, aacSnapshot) }
        let snapshot = try makeAACSnapshot(
            epoch,
            extending: snapshotBaseline.1
        )
        let identities = try epoch.buffers.map(SegmentBoundaryCoordinator.aacIdentity)
        let preview = try coordinator.previewAACAppends(
            for: epoch.buffers,
            rendition: binding.renditionIdentity,
            writerBinding: binding
        )
        try withLane {
            guard aacSnapshotRevision == snapshotBaseline.0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            try preflightAACBatchIsolated(epoch.buffers, preview: preview)
            let nextSnapshotRevision = aacSnapshotRevision.addingReportingOverflow(1)
            guard !nextSnapshotRevision.overflow else {
                throw SegmentedFMP4WriterFailure.arithmeticOverflow
            }
            var appendedAny = false
            for index in epoch.buffers.indices {
                var ticket: SegmentBoundaryAppendTicket?
                do {
                    ticket = try coordinator.issueAACAppend(
                        for: epoch.buffers[index],
                        rendition: binding.renditionIdentity,
                        writerBinding: binding
                    )
                    guard let ticket else { throw SegmentedFMP4WriterFailure.boundaryMismatch }
                    var admission = try preflightTypedIsolated(
                        epoch.buffers[index],
                        ticket: ticket,
                        sampleIdentity: identities[index]
                    )
                    defer { discardUnusedFlushAdmissionIsolated(&admission) }
                    try flushIfRequiredIsolated(ticket, admission: &admission)
                    guard ticket.prepare(
                        binding: binding,
                        trackKind: trackKind,
                        sampleIdentity: identities[index],
                        session: boundarySession
                    ) else {
                        throw SegmentedFMP4WriterFailure.boundaryMismatch
                    }
                    let nativeSample = try makeNativeInputIsolated(epoch.buffers[index],
                        ownership: FMP4InputOwnership(), admission: &admission,
                        outputTiming: epoch.outputTiming(at: index))
                    // AVAssetWriter 的 delegate 可在 append 返回前同步交付首个 media
                    // report。批量 AAC 路径必须先以本批真实首帧冻结输入时间域，令该
                    // callback 能签发 prefix mapping；失败路径随后会终结当前 writer，
                    // 不会把这个尚未发布的窗口继续复用。
                    if windowFirstPhysicalStart == nil {
                        windowFirstPhysicalStart = snapshot.firstPhysicalStart
                        windowFirstOutputStart = snapshot.firstOutputStart
                        windowLeadingFrames = Int64(snapshot.leadingFrames)
                        windowSampleRate = snapshot.sampleRate
                    }
                    guard appendAndCommitIsolated(
                        nativeSample, ticket: ticket, sampleIdentity: identities[index]
                    ) else {
                        let failure = systemFailureIsolated()
                        systemWriter.cancelWriting()
                        _ = signTerminalIsolated(.failed)
                        throw failure
                    }
                    appendedAny = true
                    try recordAppendIsolated(epoch.buffers[index], ticket: ticket, evidence: admission.evidence)
                } catch {
                    ticket?.abort(binding: binding, session: boundarySession)
                    if appendedAny, state == .started {
                        systemWriter.cancelWriting()
                        _ = signTerminalIsolated(.failed)
                    }
                    throw error
                }
            }
            // 只有整批真实 append 与 writer 账本均成功后才提交快照。失败会终结
            // 当前物理 writer，但不能让未完成批次污染可读累计状态。
            aacSnapshot = snapshot
            aacSnapshotRevision = nextSnapshotRevision.partialValue
        }
    }

    func appendAACEncodedEpochAwaitingReadiness(
        _ epoch: AACEncodedEpoch,
        coordinator: SegmentBoundaryCoordinator
    ) async throws {
        try Task.checkCancellation()
        guard trackKind == .aac, sourceAACConfiguration == nil, !epoch.buffers.isEmpty,
              coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        guard epoch.buffers.count <= ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
        }
        let baseline = withLane { (aacSnapshotRevision, aacSnapshot) }
        let snapshot = try makeAACSnapshot(epoch, extending: baseline.1)
        let identities = try epoch.buffers.map(SegmentBoundaryCoordinator.aacIdentity)
        let preview = try coordinator.previewAACAppends(for: epoch.buffers,
            rendition: binding.renditionIdentity, writerBinding: binding)
        let batchIdentity = UUID()
        let revision = try withLane {
            guard aacSnapshotRevision == baseline.0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            try preflightAACBatchIsolated(epoch.buffers, preview: preview, awaitsReadiness: true)
            let next = aacSnapshotRevision.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            awaitingAACBatch = batchIdentity
            return next.partialValue
        }
        do {
            for index in epoch.buffers.indices {
                try Task.checkCancellation()
                let operation = try withLane {
                    guard awaitingAACBatch == batchIdentity else {
                        throw SegmentedFMP4WriterFailure.illegalState
                    }
                    let ticket = try coordinator.issueAACAppend(for: epoch.buffers[index],
                        rendition: binding.renditionIdentity, writerBinding: binding)
                    do {
                        var admission = try preflightTypedIsolated(epoch.buffers[index],
                            ticket: ticket, sampleIdentity: identities[index],
                            readinessFailurePolicy: .awaiting, batchIdentity: batchIdentity)
                        defer { discardUnusedFlushAdmissionIsolated(&admission) }
                        if windowFirstPhysicalStart == nil {
                            windowFirstPhysicalStart = snapshot.firstPhysicalStart
                            windowFirstOutputStart = snapshot.firstOutputStart
                            windowLeadingFrames = Int64(snapshot.leadingFrames)
                            windowSampleRate = snapshot.sampleRate
                        }
                        return try beginAwaitingAppendIsolated(epoch.buffers[index],
                            ticket: ticket, sampleIdentity: identities[index],
                            ownership: FMP4InputOwnership(),
                            validatesSource: { try NativeSampleFacts.freeze(epoch.buffers[index]) == $0 },
                            admission: &admission, outputTiming: epoch.outputTiming(at: index),
                            batchIdentity: batchIdentity)
                    } catch {
                        ticket.abort(binding: binding, session: boundarySession)
                        throw error
                    }
                }
                try await completeAwaitingAppend(operation)
            }
            try withLane {
                guard state == .started, awaitingAACBatch == batchIdentity else {
                    throw SegmentedFMP4WriterFailure.illegalState
                }
                aacSnapshot = snapshot
                aacSnapshotRevision = revision
                awaitingAACBatch = nil
                if finishRequested { try beginFinishIsolated() }
            }
        } catch {
            // Keep the batch gate closed until retirement has atomically changed state.
            // Clearing it here would let a concurrent append/finish enter between samples.
            if error is CancellationError { requestCancellation() }
            else { requestAppendFailureRetirement() }
            await withCheckedContinuation { continuation in
                cleanupGroup.notify(queue: cleanupQueue) { continuation.resume() }
            }
            throw error
        }
    }

    func appendAACIncremental(
        _ emission: AACIncrementalEmission,
        coordinator: SegmentBoundaryCoordinator
    ) throws -> AACIncrementalAppendResult {
        guard trackKind == .aac, sourceAACConfiguration == nil,
              coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        return try withLane {
            guard state == .started, !finishRequested, awaitingAppend == nil,
                  awaitingAACBatch == nil else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            guard let prepared = try prepareAACIncrementalIsolated(emission,
                awaitsReadiness: false) else { return .retryLater }
            let buffer = prepared.buffer
            let identity = try SegmentBoundaryCoordinator.aacIdentity(buffer)
            var ticket: SegmentBoundaryAppendTicket?
            var systemAppendSucceeded = false
            do {
                ticket = try coordinator.issueAACAppend(
                    for: buffer,
                    rendition: binding.renditionIdentity,
                    writerBinding: binding)
                guard let ticket else {
                    throw SegmentedFMP4WriterFailure.boundaryMismatch
                }
                var admission = try preflightTypedIsolated(
                    buffer, ticket: ticket, sampleIdentity: identity
                )
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                try flushIfRequiredIsolated(ticket, admission: &admission)
                guard state == .started,
                      ticket.prepare(binding: binding, trackKind: trackKind,
                                     sampleIdentity: identity,
                                     session: boundarySession) else {
                    throw SegmentedFMP4WriterFailure.boundaryMismatch
                }
                emission.markWriterAccepted()
                let nativeSample = try makeNativeInputIsolated(buffer, ownership: FMP4InputOwnership(),
                    admission: &admission, outputTiming: emission.outputTiming)
                guard appendAndCommitIsolated(nativeSample, ticket: ticket,
                                              sampleIdentity: identity) else {
                    let failure = systemFailureIsolated()
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw failure
                }
                systemAppendSucceeded = true
                try recordAppendIsolated(buffer, ticket: ticket, evidence: admission.evidence)
            } catch {
                ticket?.abort(binding: binding, session: boundarySession)
                if systemAppendSucceeded, state == .started {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                }
                throw error
            }
            // 只有系统 append、ticket commit 与 writer 账本全部成功后，才一次提交
            // 增量 snapshot/ordinal/digest；暂时不可写返回时这些值保持不变。
            commitAACPreparationIsolated(prepared, emission: emission)
            return .appended
        }
    }

    private struct AACAppendPreparation {
        let buffer: CMSampleBuffer
        let accounting: AACIncrementalStreamAccounting
        let nextOrdinal: UInt64
        let digest: Data
        let physical: ExactMediaTime
        let output: ExactMediaTime
        let leading: Int64
    }

    private func prepareAACIncrementalIsolated(
        _ emission: AACIncrementalEmission,
        awaitsReadiness: Bool
    ) throws -> AACAppendPreparation? {
        guard incrementalAACReceipt == nil else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        guard emission.identity == emission.liveContext.encoderIdentity,
              ((incrementalAACLiveContext === emission.liveContext
                && emission.liveContext.matches(binding))
                || (incrementalAACLiveContext == nil
                    && emission.liveContext.bind(to: binding))),
              incrementalAACNextOrdinal == emission.ordinal else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        if !awaitsReadiness, !(try synchronousReadinessIsolated()) { return nil }

        let buffer = try emission.materializeSampleBuffer()
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              CMFormatDescriptionEqual(format, otherFormatDescription: sourceFormatHint),
              ObjectIdentifier(format) == emission.liveContext.formatIdentity,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatMPEG4AAC,
              asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
              let sampleRate = Int32(exactly: asbd.mSampleRate),
              sampleRate == 48_000,
              asbd.mFramesPerPacket > 0,
              CMSampleBufferGetNumSamples(buffer) > 0 else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let decodedProduct = CMSampleBufferGetNumSamples(buffer)
            .multipliedReportingOverflow(by: Int(asbd.mFramesPerPacket))
        guard !decodedProduct.overflow,
              let decoded = Int64(exactly: decodedProduct.partialValue) else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        let leading = try trim(buffer,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            sampleRate: sampleRate)
        let trailing = try trim(buffer,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
            sampleRate: sampleRate)
        let trims = leading.addingReportingOverflow(trailing)
        let effective = decoded.subtractingReportingOverflow(trims.partialValue)
        guard !trims.overflow, !effective.overflow, effective.partialValue >= 0,
              leading <= decoded, trailing <= decoded,
              emission.isFinalBuffer || trailing == 0,
              emission.ordinal == 0 || leading == 0,
              emission.ordinal != 0
                || leading == Int64(emission.liveContext.calibratedLeadingFrames),
              let leadingInt = Int(exactly: leading) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let duration = try ExactMediaTime(CMSampleBufferGetDuration(buffer))
        guard duration == ExactMediaTime(value: decoded, timescale: sampleRate) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let physical = try ExactMediaTime(
            CMSampleBufferGetPresentationTimeStamp(buffer))
        let output = try ExactMediaTime(
            CMSampleBufferGetOutputPresentationTimeStamp(buffer))
        let previous = incrementalAACAccounting
        if let previous {
            guard previous.encoderIdentity == emission.identity,
                  previous.sampleRate == sampleRate,
                  previous.nextPhysicalStart == physical,
                  previous.nextOutputStart == output,
                  !previous.sawFinalEmission else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
        } else {
            guard AACIncrementalStreamAccounting.firstEmissionIsValid(
                decodedFrames: decoded,
                leadingFrames: leading,
                trailingFrames: trailing),
                  output == (try physical.adding(
                ExactMediaTime(value: leading, timescale: sampleRate))) else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
        }
        let nextCount = incrementalAACNextOrdinal.addingReportingOverflow(1)
        let previousDecoded = previous?.totalDecodedFrames ?? 0
        let nextDecoded = previousDecoded.addingReportingOverflow(decoded)
        let previousReal = previous?.realSampleCount ?? 0
        let nextReal = previousReal.addingReportingOverflow(effective.partialValue)
        guard !nextCount.overflow, !nextDecoded.overflow, !nextReal.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        let nextDigest = AACRenditionEncoder.foldEmissionDigest(
            incrementalAACDigest,
            ordinal: emission.ordinal,
            evidence: emission.evidenceDigest)
        let prospective = AACIncrementalStreamAccounting(
            encoderIdentity: emission.identity,
            inputCount: nextCount.partialValue,
            inputDigest: nextDigest,
            realSampleCount: nextReal.partialValue,
            totalDecodedFrames: nextDecoded.partialValue,
            leadingFrames: previous?.leadingFrames ?? leadingInt,
            trailingFrames: trailing,
            sampleRate: sampleRate,
            firstPhysicalStart: previous?.firstPhysicalStart ?? physical,
            firstOutputStart: previous?.firstOutputStart ?? output,
            nextPhysicalStart: try physical.adding(duration),
            nextOutputStart: try output.adding(
                ExactMediaTime(value: effective.partialValue,
                               timescale: sampleRate)),
            sawFinalEmission: emission.isFinalBuffer,
            liveContextIdentity: emission.liveContextIdentity,
            lastEmissionEvidenceDigest: emission.evidenceDigest)
        return AACAppendPreparation(buffer: buffer, accounting: prospective,
            nextOrdinal: nextCount.partialValue, digest: nextDigest,
            physical: physical, output: output, leading: leading)
    }

    private func commitAACPreparationIsolated(
        _ prepared: AACAppendPreparation,
        emission: AACIncrementalEmission
    ) {
        incrementalAACAccounting = prepared.accounting
        incrementalAACNextOrdinal = prepared.nextOrdinal
        incrementalAACDigest = prepared.digest
        incrementalAACLiveContext = emission.liveContext
        if windowFirstPhysicalStart == nil {
            windowFirstPhysicalStart = prepared.physical
            windowFirstOutputStart = prepared.output
            windowLeadingFrames = prepared.leading
        }
    }

    func appendAACIncrementalAwaitingReadiness(
        _ emission: AACIncrementalEmission,
        coordinator: SegmentBoundaryCoordinator
    ) async throws -> AACIncrementalAppendResult {
        try Task.checkCancellation()
        guard trackKind == .aac, sourceAACConfiguration == nil, coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let admitted = try withLane { () throws -> (AwaitingAppend, AACAppendPreparation) in
            guard state == .started, !finishRequested, awaitingAppend == nil,
                  awaitingAACBatch == nil, let prepared = try prepareAACIncrementalIsolated(emission,
                    awaitsReadiness: true) else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            let identity = try SegmentBoundaryCoordinator.aacIdentity(prepared.buffer)
            let ticket = try coordinator.issueAACAppend(for: prepared.buffer,
                rendition: binding.renditionIdentity, writerBinding: binding)
            do {
                var admission = try preflightTypedIsolated(prepared.buffer,
                    ticket: ticket, sampleIdentity: identity,
                    readinessFailurePolicy: .awaiting)
                defer { discardUnusedFlushAdmissionIsolated(&admission) }
                let operation = try beginAwaitingAppendIsolated(prepared.buffer,
                    ticket: ticket, sampleIdentity: identity,
                    ownership: FMP4InputOwnership(),
                    // 此 header 是 writer 从不可变 emission 私有物化的，外部没有 header
                    // alias；复核签出它的 live context，无需再分配一次 payload。
                    validatesSource: { [binding] _ in
                        emission.identity == emission.liveContext.encoderIdentity
                            && emission.liveContext.matches(binding)
                    },
                    admission: &admission, outputTiming: emission.outputTiming,
                    claimOwnership: { emission.markWriterAccepted() })
                return (operation, prepared)
            } catch {
                ticket.abort(binding: binding, session: boundarySession)
                throw error
            }
        }
        try await completeAwaitingAppend(admitted.0) {
            self.commitAACPreparationIsolated(admitted.1, emission: emission)
        }
        return .appended
    }

    func sealAACIncrementalStream(
        _ final: AACEncoderFinalReceipt
    ) throws -> AACIncrementalWriterReceipt {
        try withLane {
            guard incrementalAACReceipt == nil,
                  let accounting = incrementalAACAccounting,
                  final.identity == accounting.encoderIdentity,
                  final.liveContext.matches(binding),
                  final.liveContext.identity == accounting.liveContextIdentity,
                  incrementalAACNextOrdinal == final.emissionCount,
                  incrementalAACDigest == final.cumulativeDigest,
                  accounting.inputCount == final.emissionCount,
                  accounting.inputDigest == final.cumulativeDigest,
                  accounting.sawFinalEmission,
                  accounting.matches(summary: final.summary),
                  final.emissionCount > 0,
                  final.finalEmission.ordinal == final.emissionCount - 1,
                  final.finalEmission.isFinalBuffer,
                  final.finalEmission.evidenceDigest
                    == accounting.lastEmissionEvidenceDigest else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let receipt = AACIncrementalWriterReceipt(
                identity: UUID(),
                binding: binding,
                encoderIdentity: final.identity,
                inputCount: final.emissionCount,
                inputDigest: final.cumulativeDigest,
                realSampleCount: final.summary.realSampleCount,
                totalDecodedFrames: final.summary.totalDecodedFrames,
                leadingFrames: final.summary.leadingFrames,
                trailingFrames: final.summary.trailingFrames)
            incrementalAACReceipt = receipt
            return receipt
        }
    }

    func finish() async throws -> SegmentedFMP4WriterTerminalReceipt {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<SegmentedFMP4WriterTerminalReceipt, Error>? = withLane {
                if let firstTypedCallbackFailure { return .failure(firstTypedCallbackFailure) }
                if let receipt = storedTerminalReceipt { return .success(receipt) }
                guard state == .started, !finishRequested else {
                    return .failure(SegmentedFMP4WriterFailure.illegalState)
                }
                finishRequested = true
                finishContinuation = continuation
                // 已准入的 append 仍可提交；后续输入已被封闭。native 返回后才 finish。
                guard awaitingAppend == nil, awaitingAACBatch == nil else { return nil }
                do { try beginFinishIsolated() }
                catch {
                    finishContinuation = nil
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    return .failure(error)
                }
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    private func beginFinishIsolated() throws {
        guard state == .started, finishRequested, awaitingAppend == nil,
              awaitingAACBatch == nil, (currentSegmentInputCount == 0 ||
                (mediaPendingCallbackCount < Self.pendingCallbackCapacity &&
                 relay.canReserve(projectedByteCount: currentSegmentProjectedBytes))) else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        if currentSegmentInputCount > 0 {
            _ = try nextMovieFragmentSequenceNumberIsolated()
            let ticket = try relay.reserve(kind: .media, logicalSequence: lastLogicalSequence ?? 0,
                projectedByteCount: currentSegmentProjectedBytes)
            pendingCallbacks.append(.init(ticket: ticket, kind: .media,
                logicalSequence: lastLogicalSequence ?? 0, boundary: currentPublicationBoundary,
                frameDuration: currentFrameDuration))
        }
        state = .finishing
        systemWriter.markInputAsFinished()
        systemWriter.finishWriting { [weak self] succeeded in
            self?.finishSystemDidComplete(succeeded)
        }
    }

    /// 中间窗口真实 finish + callback/publication ownership 全部收敛后才签发接管权。
    /// 它不接收 encoder final receipt，也不封存 P/ENDLIST。
    func finishAACWriterWindow() async throws -> AACWriterWindowContinuation {
        guard trackKind == .aac, sourceAACConfiguration == nil else { throw SegmentedFMP4WriterFailure.aacEndpointMismatch }
        let drainTask = Task { [relay, callbackContext] in
            await relay.waitForPublicationDrain(source: callbackContext)
        }
        let terminal = try await finish()
        guard let drain = await drainTask.value,
              relay.accepts(drain, source: callbackContext) else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
        return try withLane {
            guard terminal == storedTerminalReceipt,
                  terminal.terminalReason == .finished,
                  rolloverPending,
                  !windowContinuationIssued,
                  let accounting = incrementalAACAccounting,
                  let context = incrementalAACLiveContext,
                  let renditionBinding = aacRenditionTerminalBinding,
                  !accounting.sawFinalEmission else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let localCount = accounting.inputCount.subtractingReportingOverflow(
                incrementalAACFirstGlobalOrdinal)
            guard !localCount.overflow,
                  UInt64(exactly: terminal.inputCount) == localCount.partialValue,
                  let timelineMappingReceipt,
                  let inputPhysicalStart = windowFirstPhysicalStart,
                  let inputEffectiveStart = windowFirstOutputStart,
                  let inputPhysicalEnd = accounting.nextPhysicalStart,
                  let inputEffectiveEnd = accounting.nextOutputStart else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let mapping = AACWriterWindowMappingReceipt(
                binding: binding,
                reportIdentity: timelineMappingReceipt.reportIdentity,
                inputPhysicalStart: inputPhysicalStart,
                inputPhysicalEnd: inputPhysicalEnd,
                inputEffectiveStart: inputEffectiveStart,
                inputEffectiveEnd: inputEffectiveEnd,
                writtenPhysicalStart: timelineMappingReceipt.writtenPhysicalBase,
                writtenPhysicalEnd: try inputPhysicalEnd.adding(timelineMappingReceipt.offset),
                writtenEffectiveStart: timelineMappingReceipt.writtenEffectiveBase,
                writtenEffectiveEnd: try inputEffectiveEnd.adding(timelineMappingReceipt.offset),
                offset: timelineMappingReceipt.offset)
            guard renditionBinding.sealWindowMapping(mapping) else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let receipt = AACWriterWindowTerminalReceipt(
                identity: UUID(), binding: binding,
                encoderIdentity: accounting.encoderIdentity,
                firstGlobalOrdinal: incrementalAACFirstGlobalOrdinal,
                nextGlobalOrdinal: accounting.inputCount,
                windowInputCount: localCount.partialValue,
                cumulativeInputCount: accounting.inputCount,
                cumulativeInputDigest: accounting.inputDigest,
                systemTerminal: terminal,
                callbackEvidenceCount: callbackEvidenceCount,
                callbackEvidenceDigest: callbackEvidenceDigest,
                mediaMembership: windowCallbackMembership.snapshot,
                firstMedia: firstAACMediaEvidence,
                terminalMedia: terminalAACMediaEvidence,
                mapping: mapping)
            let nextFragment = try nextMovieFragmentSequenceNumberIsolated()
            windowContinuationIssued = true
            return AACWriterWindowContinuation(
                receipt: receipt, accounting: accounting, context: context,
                renditionBinding: renditionBinding,
                nextMovieFragmentSequenceNumber: nextFragment, inputAdmission: inputAdmission,
                maximumObservedInputBytes: maximumObservedInputBytes)
        }
    }

    /// Finishes one non-AAC physical writer without ending the logical encoder or
    /// audio branch. The continuation is signed only after system terminal and
    /// publication drain have both completed.
    func finishWriterWindow() async throws -> WriterWindowContinuation {
        guard trackKind != .aac || sourceAACConfiguration != nil else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let drainTask = Task { [relay, callbackContext] in
            await relay.waitForPublicationDrain(source: callbackContext)
        }
        let terminal = try await finish()
        guard let drain = await drainTask.value,
              relay.accepts(drain, source: callbackContext) else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
        return try withLane {
            guard terminal == storedTerminalReceipt,
                  terminal.terminalReason == .finished,
                  rolloverPending,
                  !windowContinuationIssued else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            if let origin = sourceAACOrigin, let sourceAACTerminalBinding {
                try sourceAACTerminalBinding.finishWindow(origin: origin, terminal: terminal)
            }
            let cadence: WriterWindowCadence?
            if let value = remuxVideoCadence {
                cadence = .remuxVideo(
                    duration: value.duration,
                    nextDecodeTimeStamp: value.nextDecodeTimeStamp)
            } else if let value = videoCadence {
                cadence = .video(duration: value.duration, nextPTS: value.nextPTS)
            } else if let value = compressedCadence {
                cadence = .compressed(duration: value.duration, nextPTS: value.nextPTS)
            } else {
                cadence = nil
            }
            let nextFragment = try nextMovieFragmentSequenceNumberIsolated()
            windowContinuationIssued = true
            return WriterWindowContinuation(
                predecessorTerminal: terminal,
                trackKind: trackKind,
                frozenFormat: frozenFormat,
                cadence: cadence,
                nextMovieFragmentSequenceNumber: nextFragment, inputAdmission: inputAdmission,
                maximumObservedInputBytes: maximumObservedInputBytes,
                remuxFormatAuthorityWitness: remuxFormatAuthorityWitness,
                remuxBitrateEnvelope: remuxBitrateEnvelope, compressedBackingAdmission: compressedBackingAdmission,
                sourceAACBinding: sourceAACTerminalBinding)
        }
    }

    /// 真正 EOS 后封存最后物理 writer 与全 rendition callback 累计；不接收
    /// 调用方提供的 count/digest/media 数组。
    func finishAACRendition(
        _ final: AACEncoderFinalReceipt
    ) async throws -> AACRenditionWriterFinalReceipt {
        let accounting = try withLane { () throws -> AACIncrementalStreamAccounting in
            if incrementalAACReceipt == nil {
                _ = try sealAACIncrementalStream(final)
            }
            guard let accounting = incrementalAACAccounting,
                  accounting.inputCount == final.emissionCount,
                  accounting.inputDigest == final.cumulativeDigest,
                  accounting.sawFinalEmission else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            return accounting
        }
        let terminal = try await finish()
        return try withLane {
            guard let renditionBinding = aacRenditionTerminalBinding,
                  let terminalBinding = aacTerminalBinding,
                  let timelineMappingReceipt,
                  let inputPhysicalStart = windowFirstPhysicalStart,
                  let inputEffectiveStart = windowFirstOutputStart,
                  let inputPhysicalEnd = accounting.nextPhysicalStart,
                  let inputEffectiveEnd = accounting.nextOutputStart else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let mapping = AACWriterWindowMappingReceipt(
                binding: binding,
                reportIdentity: timelineMappingReceipt.reportIdentity,
                inputPhysicalStart: inputPhysicalStart,
                inputPhysicalEnd: inputPhysicalEnd,
                inputEffectiveStart: inputEffectiveStart,
                inputEffectiveEnd: inputEffectiveEnd,
                writtenPhysicalStart: timelineMappingReceipt.writtenPhysicalBase,
                writtenPhysicalEnd: try inputPhysicalEnd.adding(timelineMappingReceipt.offset),
                writtenEffectiveStart: timelineMappingReceipt.writtenEffectiveBase,
                writtenEffectiveEnd: try inputEffectiveEnd.adding(timelineMappingReceipt.offset),
                offset: timelineMappingReceipt.offset)
            guard renditionBinding.sealWindowMapping(mapping) else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            return try renditionBinding.sealFinal(
                accounting: accounting, terminal: terminal,
                terminalBinding: terminalBinding)
        }
    }

    @discardableResult
    func cancel() -> SegmentedFMP4WriterTerminalReceipt {
        requestCancellation()
        // 兼容同步调用方的终态返回；等待始终发生在 writer lane 外。
        cleanupGroup.wait()
        return withLane { storedTerminalReceipt! }
    }

    func cancelAwaitingCompletion() async -> SegmentedFMP4WriterTerminalReceipt {
        requestCancellation()
        await withCheckedContinuation { continuation in
            cleanupGroup.notify(queue: cleanupQueue) { continuation.resume() }
        }
        return withLane { storedTerminalReceipt! }
    }

    /// 图层 retire 必须先发出取消，再等待自己的 worker；这里不等待在途输入归来。
    func requestCancellation() {
        let action = withLane { () -> (CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?, Bool) in
            guard state != .terminal, state != .retiring else { return (nil, false) }
            state = .retiring
            cleanupGroup.enter()
            return (takeFinishContinuationIsolated(), true)
        }
        guard action.1 else { return }
        scheduleRetirementCleanup(action.0,
            result: .failure(CancellationError()), reason: .cancelled)
    }

    private func requestAppendFailureRetirement() {
        let action = withLane { () -> (CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?, Error)? in
            guard state != .terminal, state != .retiring else { return nil }
            let failure = systemFailureIsolated()
            return (beginFailureRetirementIsolated(), failure)
        }
        if let action { scheduleFailureCleanup(action.0, result: .failure(action.1)) }
    }

    func receiveSystemSegment(
        writerObjectIdentity: ObjectIdentifier,
        bytes: Data,
        type: AVAssetSegmentType,
        report: SegmentedFMP4SystemReportEvidence
    ) {
        var continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
        var continuationResult: Result<SegmentedFMP4WriterTerminalReceipt, Error>?
        var cancelSystemWriter = false
        withLane {
            guard state != .terminal, state != .retiring else { return }
            guard writerObjectIdentity == systemWriter.objectIdentity else {
                let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.writerIdentity")
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(failure)
                return
            }
            let kind: SealedMediaObjectKind
            switch type {
            case .initialization: kind = .initialization
            case .separable: kind = .media
            @unknown default:
                let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.type")
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(failure)
                return
            }
            guard let index = pendingCallbacks.firstIndex(where: { $0.kind == kind }) else {
                let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.pending")
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(failure)
                return
            }
            let pending = pendingCallbacks[index]
            let trustedBytes: Data
            let trustedFormat: SegmentedFMP4FrozenFormat?
            if callbackContext.isBound {
                guard let capsule = report.callbackCapsule,
                      let trusted = capsule.consume(context: callbackContext, adapter: systemWriter,
                        writer: writerObjectIdentity, bytes: bytes, type: type, report: report),
                      cadenceIsValid else {
                    let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.provenance")
                    cancelSystemWriter = true
                    continuation = beginFailureRetirementIsolated()
                    continuationResult = .failure(failure)
                    return
                }
                trustedBytes = trusted.0; trustedFormat = trusted.1
            } else { trustedBytes = bytes; trustedFormat = nil }
            let reportReference = SegmentReportReference(evidence: report)
            let publicationEvidence: SegmentedFMP4PublicationEvidence?
            if let format = trustedFormat {
                publicationEvidence = SegmentedFMP4PublicationEvidence(format: format, boundary: pending.boundary,
                    session: boundarySession, frameDuration: pending.frameDuration, binding: binding,
                    callback: pending.ticket, kind: kind, sequence: pending.logicalSequence,
                    reportIdentity: reportReference.identity, bytes: trustedBytes, writerSource: callbackContext)
            } else { publicationEvidence = nil }
            let delivery = SegmentCallbackDelivery(
                binding: binding,
                writerIdentity: binding.writerIdentity,
                ticket: pending.ticket,
                logicalSequence: pending.logicalSequence,
                kind: kind,
                bytes: trustedBytes as NSData,
                report: reportReference,
                publicationEvidence: publicationEvidence
            )
            if kind == .media, callbackContext.isBound {
                do {
                    let actual = try WriterNativeFragmentFacts.read(trustedBytes)
                    let expected = initialMovieFragmentSequenceNumber.addingReportingOverflow(mediaCallbackCount)
                    guard !expected.overflow, actual.sequence == expected.partialValue,
                          lastNativeFragment.map({ actual.decodeTime > $0.decodeTime }) ?? true else {
                        throw SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.fragmentSequence")
                    }
                    lastNativeFragment = actual
                    acceptanceObservation?.observed(logicalSequence: pending.logicalSequence,
                        nativeSequence: actual.sequence)
                } catch {
#if DEBUG
                    print("HLS_WRITER_CALLBACK_FAILURE stage=fragmentFacts track=\(trackKind.rawValue) " +
                        "inputs=\(inputCount) initialization=\(initializationCallbackCount) media=\(mediaCallbackCount) " +
                        "typedCallback=\(firstTypedCallbackFailure != nil)")
#endif
                    cancelSystemWriter = true
                    continuation = beginFailureRetirementIsolated()
                    continuationResult = .failure(error)
                    return
                }
            }
            let result = relay.receive(delivery)
            switch result {
            case let .accepted(acceptance):
                pendingCallbacks.remove(at: index)
                do {
                    try recordCallbackIsolated(
                        kind: kind,
                        logicalSequence: pending.logicalSequence,
                        bytes: trustedBytes,
                        report: reportReference,
                        acceptance: acceptance,
                        publicationEvidence: publicationEvidence
                    )
                    if kind == .media { try segmentEvidence.retireVerified(sequence: pending.logicalSequence) }
                    inputAdmission.signalCapacityChange()
                    guard schedulePublicationIsolated(acceptance) else {
                        throw SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.publication")
                    }
                } catch {
#if DEBUG
                    print("HLS_WRITER_CALLBACK_FAILURE stage=record track=\(trackKind.rawValue) " +
                        "inputs=\(inputCount) initialization=\(initializationCallbackCount) media=\(mediaCallbackCount) " +
                        "typedCallback=\(firstTypedCallbackFailure != nil)")
#endif
                    cancelSystemWriter = true
                    continuation = beginFailureRetirementIsolated()
                    continuationResult = .failure(error)
                    return
                }
            case .discarded:
                let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.discarded")
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(failure)
                return
            case .fatal:
#if DEBUG
                if case let .fatal(reason) = result {
                    print("HLS_WRITER_CALLBACK_FAILURE stage=relay reason=\(reason) track=\(trackKind.rawValue)")
                }
#endif
                let failure = SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.relay")
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(failure)
                return
            }
            if state == .finishing,
               finishSystemSucceeded,
               pendingCallbacks.isEmpty {
                let receipt = signTerminalIsolated(.finished)
                continuation = takeFinishContinuationIsolated()
                continuationResult = .success(receipt)
            }
        }
        if cancelSystemWriter {
            scheduleFailureCleanup(continuation, result: continuationResult
                ?? .failure(SegmentedFMP4WriterFailure.diagnosedSystemFailure()))
            return
        }
        if let continuation, let continuationResult {
            resumeAfterPublications(continuation, with: continuationResult)
        }
    }

    func makeAACEffectiveEndpointReceipt(
        epoch: AACEncodedEpoch,
        initializationObject: SealedMediaObject,
        mediaObjects: [SealedMediaObject]
    ) throws -> AACEffectiveEndpointReceipt {
        // 兼容旧调用点的 receipt 投影不再拥有独立 claim；它必须先走唯一的
        // authority 原子终态，从而不可能在返回 receipt 后留下 binding pending。
        try makeAACEffectiveEndpointAuthority(
            epoch: epoch,
            initializationObject: initializationObject,
            mediaObjects: mediaObjects).receipt
    }

    private func makeAACEffectiveEndpointReceiptIsolated(
        epoch: AACEncodedEpoch,
        initializationObject: SealedMediaObject,
        mediaObjects: [SealedMediaObject]
    ) throws -> AACEffectiveEndpointReceipt {
        guard let terminal = storedTerminalReceipt,
              terminal.terminalReason == .finished,
              let frozen = aacSnapshot,
              frozen.epochIdentity == epoch.identity,
              frozen.inputCount == epoch.buffers.count,
              terminal.inputCount == frozen.inputCount else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        // Verify the supplied historical inputs against committed accounting. This
        // folds them into a fixed-size digest; it does not admit or retain inputs.
        let snapshot = try makeAACSnapshot(epoch)
        guard frozen.epochIdentity == snapshot.epochIdentity,
              frozen.inputCount == snapshot.inputCount,
              frozen.inputDigest == snapshot.inputDigest,
              frozen.sampleRate == snapshot.sampleRate,
              frozen.firstPhysicalStart == snapshot.firstPhysicalStart,
              frozen.firstOutputStart == snapshot.firstOutputStart,
              frozen.realSampleCount == snapshot.realSampleCount,
              frozen.totalDecodedFrames == snapshot.totalDecodedFrames,
              frozen.leadingFrames == snapshot.leadingFrames,
              frozen.trailingFrames == snapshot.trailingFrames,
              terminal.inputCount == snapshot.inputCount,
              initializationObject.kind == .initialization,
              initializationObject.binding == binding,
              initializationObject.backing.identity == initializationBackingIdentity,
              !mediaObjects.isEmpty,
              mediaObjects.allSatisfy({ $0.kind == .media && $0.binding == binding }),
              initializationCallbackCount == 1,
              mediaObjects.count == mediaCallbackCount,
              let mapping = timelineMappingReceipt,
              mapping.sampleRate == snapshot.sampleRate,
              mapping.inputPhysicalBase == snapshot.firstPhysicalStart,
              mapping.inputEffectiveBase == snapshot.firstOutputStart,
              let firstMediaObject = mediaObjects.first,
              let terminalMediaObject = mediaObjects.last,
              terminal.lastLogicalSequence == terminalMediaObject.logicalSequence,
              terminal.lastCallbackReportIdentity == terminalMediaObject.report.identity else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let real = Int64(snapshot.realSampleCount)
        let total = Int64(snapshot.totalDecodedFrames)
        let leading = Int64(snapshot.leadingFrames)
        let trailing = Int64(snapshot.trailingFrames)
        let sum = leading.addingReportingOverflow(real)
        let all = sum.partialValue.addingReportingOverflow(trailing)
        guard !sum.overflow, !all.overflow, all.partialValue == total else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let suppliedCallbackDigest = Self.callbackDigest(
            objects: [initializationObject] + mediaObjects
        )
        guard suppliedCallbackDigest == callbackEvidenceDigest,
              callbackEvidenceCount == 1 + mediaObjects.count,
              mediaObjects.first?.report.identity == mapping.reportIdentity else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let sampleRate = snapshot.sampleRate
        let inputEffectiveBase = try mapping.inputPhysicalBase.adding(
            ExactMediaTime(value: leading, timescale: sampleRate))
        let writtenEffectiveBase = try mapping.inputEffectiveBase.adding(mapping.offset)
        let end = try writtenEffectiveBase.adding(
            ExactMediaTime(value: real, timescale: sampleRate))
        let terminalPhysicalEnd = try mapping.writtenPhysicalBase.adding(
            ExactMediaTime(value: total, timescale: sampleRate))
        let physicalEndFromEffective = try end.adding(
            ExactMediaTime(value: trailing, timescale: sampleRate))
        guard inputEffectiveBase == mapping.inputEffectiveBase,
              writtenEffectiveBase == mapping.writtenEffectiveBase,
              terminalPhysicalEnd == physicalEndFromEffective else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        return AACEffectiveEndpointReceipt(
            writerReceiptIdentity: terminal.identity,
            binding: binding,
            encoderIdentity: epoch.identity,
            sampleRate: sampleRate,
            inputPhysicalBase: mapping.inputPhysicalBase,
            inputEffectiveBase: mapping.inputEffectiveBase,
            writtenPhysicalBase: mapping.writtenPhysicalBase,
            writtenEffectiveBase: mapping.writtenEffectiveBase,
            timelineOffset: mapping.offset,
            realSampleCount: real,
            totalDecodedFrames: total,
            leadingFrames: leading,
            trailingFrames: trailing,
            inputEvidenceCount: snapshot.inputCount,
            inputEvidenceDigest: snapshot.inputDigest,
            callbackEvidenceCount: callbackEvidenceCount,
            callbackEvidenceDigest: callbackEvidenceDigest,
            mappingReportIdentity: mapping.reportIdentity,
            initializationBackingIdentity: initializationObject.backing.identity,
            firstMedia: AACEndpointSealedObjectEvidence(firstMediaObject),
            terminalMedia: AACEndpointSealedObjectEvidence(terminalMediaObject),
            terminalLogicalSequence: terminalMediaObject.logicalSequence,
            lastEffectiveEnd: end,
            terminalPhysicalEnd: terminalPhysicalEnd
        )
    }

    func makeAACEffectiveEndpointAuthority(
        epoch: AACEncodedEpoch,
        initializationObject: SealedMediaObject,
        mediaObjects: [SealedMediaObject]
    ) throws -> AACEffectiveEndpointAuthority {
        try withLane {
            guard case .open = endpointResolution else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            do {
                guard mediaObjects.count <= 128 else {
                    throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
                }
                let receipt = try makeAACEffectiveEndpointReceiptIsolated(
                    epoch: epoch,
                    initializationObject: initializationObject,
                    mediaObjects: mediaObjects)
                guard let terminal = storedTerminalReceipt,
                      terminal.identity == receipt.writerReceiptIdentity,
                      let aacTerminalBinding else {
                    throw SegmentedFMP4WriterFailure.aacEndpointMismatch
                }
                let authority = AACEffectiveEndpointAuthority(
                    receipt: receipt,
                    terminal: terminal,
                    initialization: initializationObject,
                    media: mediaObjects,
                    terminalBinding: aacTerminalBinding)
                endpointResolution = .authoritySealed
                aacTerminalBinding.seal(authority)
                return authority
            } catch {
                let failure = error as? SegmentedFMP4WriterFailure
                    ?? .aacEndpointMismatch
                if case .open = endpointResolution,
                   storedTerminalReceipt?.terminalReason == .finished {
                    endpointResolution = .failed
                    aacTerminalBinding?.failEndpointValidation(failure)
                }
                throw error
            }
        }
    }

    private func makeNativeInputIsolated(_ sample: CMSampleBuffer,
                                         ownership: FMP4InputOwnership,
                                         admission: inout AppendPreflightAdmission,
                                         outputTiming: WriterInputOutputTiming = .calculated) throws -> CMSampleBuffer {
        guard outputTiming.matchesSource(sample) else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
        guard let prepaid = admission.inputLifetime else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        admission.inputLifetime = nil
        prepaid.markNativeAdopted()
        // Both the local occupancy and wrapper metadata were reserved before any
        // flush, single-use materialization or producer claim. Only native FreeBlock
        // (or failed-construction rollback) may now return the admitted resources.
        let lifetime = WriterInputLifetime {
            ownership.release()
            prepaid.releaseBacking()
        }
        let native = try SampleBufferBuilder.makeWriterInputSample(sample, lifetime: lifetime, outputTiming: outputTiming)
        guard try NativeSampleFacts.freeze(native).matches(
            NativeSampleFacts.freeze(sample), stage: "input-wrapper") else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
#if DEBUG
        if let nativeInputAliasObserver {
            guard let block = CMSampleBufferGetDataBuffer(native) else {
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            nativeInputAliasObserver(block)
        }
#endif
        return native
    }

    private func appendTypedIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        ownership: FMP4InputOwnership
    ) throws {
        var admission = try preflightTypedIsolated(
            sampleBuffer, ticket: ticket, sampleIdentity: sampleIdentity
        )
        defer { discardUnusedFlushAdmissionIsolated(&admission) }
        try appendAfterPreflightIsolated(
            sampleBuffer,
            ticket: ticket,
            sampleIdentity: sampleIdentity,
            ownership: ownership,
            admission: &admission
        )
    }

    private func appendAfterPreflightIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        ownership: FMP4InputOwnership,
        admission: inout AppendPreflightAdmission
    ) throws {
        try flushIfRequiredIsolated(ticket, admission: &admission)
        guard state == .started else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
        guard ticket.prepare(
            binding: binding,
            trackKind: trackKind,
            sampleIdentity: sampleIdentity,
            session: boundarySession
        ) else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        let nativeSample = try makeNativeInputIsolated(sampleBuffer, ownership: ownership, admission: &admission)
        guard appendAndCommitIsolated(nativeSample, ticket: ticket, sampleIdentity: sampleIdentity) else {
            let failure = systemFailureIsolated()
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw failure
        }
        try recordAppendIsolated(sampleBuffer, ticket: ticket, evidence: admission.evidence)
    }

    /// lane 只负责准入及所有权登记；系统等待由唯一在途 Task 持有。
    private func beginAwaitingAppendIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        ownership: @autoclosure () -> FMP4InputOwnership,
        validatesSource: @escaping @Sendable (NativeSampleFacts) throws -> Bool,
        admission: inout AppendPreflightAdmission,
        outputTiming: WriterInputOutputTiming = .calculated,
        batchIdentity: UUID? = nil,
        claimOwnership: () throws -> Void = {}
    ) throws -> AwaitingAppend {
        guard outputTiming.matchesSource(sampleBuffer) else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
        let facts = try NativeSampleFacts.freeze(sampleBuffer)
        // 上游提交后只读使用同一冻结 sample。跨 executor 传递 CoreMedia 的 ready
        // 容器；账本也只在其同步借用中读取，所有 backing owner 保留到 native 归来。
        guard try validatesSource(facts) else {
            #if DEBUG
            print("HLS_NATIVE_SAMPLE_MISMATCH stage=source-before-append")
            #endif
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        try flushIfRequiredIsolated(ticket, admission: &admission)
        guard state == .started, awaitingAppend == nil,
              awaitingAACBatch == batchIdentity,
              (!finishRequested || batchIdentity != nil),
              ticket.prepare(binding: binding, trackKind: trackKind,
                             sampleIdentity: sampleIdentity, session: boundarySession) else {
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        try claimOwnership()
        let nativeSample = try makeNativeInputIsolated(sampleBuffer, ownership: ownership(),
            admission: &admission, outputTiming: outputTiming)
        let sample = try nativeReadySample(copying: nativeSample)
        guard try sample.withUnsafeSampleBuffer({ try NativeSampleFacts.freeze($0) })
            .matches(facts, stage: "ready-header") else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        let identity = UUID()
        let native = Task { [self, sample, ticket, sampleIdentity] in
            try await AppendSuccessAuthority.appendAwaitingReadiness(sample, using: self,
                operationIdentity: identity, ticket: ticket, sampleIdentity: sampleIdentity)
        }
        let operation = AwaitingAppend(identity: identity, sample: sample,
            ticket: ticket, sampleIdentity: sampleIdentity, native: native,
            facts: facts, evidence: admission.evidence, validatesSource: validatesSource)
        awaitingAppend = operation
        return operation
    }

    private func completeAwaitingAppend(
        _ operation: AwaitingAppend,
        afterCommit: () throws -> Void = {}
    ) async throws {
        do {
            let authority = try await withTaskCancellationHandler {
                try await operation.native.value
            } onCancel: {
                self.requestCancellation()
            }
            try Task.checkCancellation()
            try withLane {
                if let firstTypedCallbackFailure { throw firstTypedCallbackFailure }
                guard state == .started, awaitingAppend?.identity == operation.identity else {
                    throw CancellationError()
                }
                try operation.sample.withUnsafeSampleBuffer { sample in
                    guard try NativeSampleFacts.freeze(sample)
                        .matches(operation.facts, stage: "native-return") else {
                        throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                    }
                    guard try operation.validatesSource(operation.facts) else {
                        #if DEBUG
                        print("HLS_NATIVE_SAMPLE_MISMATCH stage=source-after-append")
                        #endif
                        throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                    }
                    guard commitAppendIsolated(sample, ticket: operation.ticket,
                        sampleIdentity: operation.sampleIdentity, authority: authority) else {
                        throw SegmentedFMP4WriterFailure.boundaryMismatch
                    }
                    try recordAppendIsolated(sample, ticket: operation.ticket, evidence: operation.evidence)
                }
                try afterCommit()
                awaitingAppend = nil
                if finishRequested, awaitingAACBatch == nil { try beginFinishIsolated() }
            }
        } catch {
            operation.ticket.abort(binding: binding, session: boundarySession)
            let failure: Error = withLane {
                if state == .retiring || state == .terminal { return error }
                if error is CancellationError { return error }
                if let typed = error as? SegmentedFMP4WriterFailure { return typed }
                if firstSystemFailureDiagnostic == nil {
                    firstSystemFailureDiagnostic = systemWriter.failureDiagnostic
                        ?? PlaybackErrorDiagnostics.snapshot(error)
                }
                return systemFailureIsolated()
            }
            if error is CancellationError { requestCancellation() }
            else { requestAppendFailureRetirement() }
            await withCheckedContinuation { continuation in
                cleanupGroup.notify(queue: cleanupQueue) { continuation.resume() }
            }
            throw failure
        }
    }

    /// remux 的所有可恢复准入必须发生在一次性 payload claim 之前。
    private func preflightRemuxAdmissionIsolated(
        _ attempt: HLSVideoRemuxWriterAttempt,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        readinessFailurePolicy: ReadinessFailurePolicy = .recoverable
    ) throws -> AppendPreflightAdmission {
        guard (remuxFormatAuthorityWitness == nil
                || remuxFormatAuthorityWitness === attempt.remuxFormatAuthorityWitness),
              remuxBitrateEnvelope == nil || remuxBitrateEnvelope == attempt.admission.bitrateEnvelope else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        let charge = attempt.remuxPayloadByteCount.addingReportingOverflow(
            Self.sampleChargeOverhead
        )
        guard !charge.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        let admission = try preflightAppendCoreIsolated(
            facts: AppendPreflightFacts(
                formatDescription: attempt.formatDescription,
                duration: attempt.duration,
                presentationTimeStamp: attempt.presentationTimeStamp,
                decodeTimeStamp: attempt.decodeTimeStamp
                    ?? attempt.presentationTimeStamp,
                projectedCharge: charge.partialValue,
                sampleCount: 1,
                remuxBitrateEnvelope: attempt.admission.bitrateEnvelope
            ),
            ticket: ticket,
            sampleIdentity: sampleIdentity,
            readinessFailurePolicy: readinessFailurePolicy
        )
        // Bind the capacity evidence before a flush can issue a continuation for
        // this still-pending AU. Builder retries retain this same format authority.
        remuxFormatAuthorityWitness = attempt.remuxFormatAuthorityWitness
        remuxBitrateEnvelope = attempt.admission.bitrateEnvelope
        return admission
    }

    private func appendAndCommitIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity
    ) -> Bool {
        guard let authority = AppendSuccessAuthority.append(
            sampleBuffer, using: self, ticket: ticket, sampleIdentity: sampleIdentity
        ) else { return false }
        return commitAppendIsolated(sampleBuffer, ticket: ticket,
            sampleIdentity: sampleIdentity, authority: authority)
    }

    private func commitAppendIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        authority: AppendSuccessAuthority
    ) -> Bool {
        guard ticket.commit(authority: authority), let boundary = ticket.committedBoundary else { return false }
        if currentSegmentInputCount == 0 {
            currentPublicationBoundary = boundary
            currentFrameDuration = try? ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer))
        }
        if trackKind == .video,
           let duration = try? ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer)),
           let pts = try? ExactMediaTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
            if case .videoRemux = sampleIdentity {
                let rawDTS = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
                let decode = (rawDTS.isNumeric ? try? ExactMediaTime(rawDTS) : nil) ?? pts
                if let nextDecode = try? decode.adding(duration) {
                    remuxVideoCadence = RemuxVideoCadence(
                        duration: remuxVideoCadence?.duration ?? duration,
                        lastDecodeTimeStamp: decode,
                        nextDecodeTimeStamp: nextDecode,
                        requiresExactNext: false
                    )
                }
            } else if let next = try? pts.adding(duration) {
                videoCadence = VideoCadence(
                    duration: videoCadence?.duration ?? duration,
                    nextPTS: next
                )
            }
        } else if trackKind == .ac3 || trackKind == .eac3 || sourceAACConfiguration != nil,
                  let duration = try? ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer)),
                  let pts = try? ExactMediaTime(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                  let next = try? pts.adding(duration) {
            compressedCadence = CompressedCadence(
                duration: compressedCadence?.duration ?? duration,
                nextPTS: next)
        }
        return true
    }

    private func validateContinuationIsolated(facts: AppendPreflightFacts,
                                              ticket: SegmentBoundaryAppendTicket) throws -> WriterRemuxByteBudget? {
        let rate: Int, samplesPerInput: Int
        if trackKind == .video {
            guard let duration = facts.duration, duration.value > 0,
                  let value = Int(exactly: duration.value) else { throw SegmentedFMP4WriterFailure.invalidSystemConfiguration }
            rate = Int(duration.timescale); samplesPerInput = value
        } else {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint)?.pointee,
                  let sampleRate = Int(exactly: asbd.mSampleRate), sampleRate > 0 else { throw SegmentedFMP4WriterFailure.invalidSystemConfiguration }
            rate = sampleRate; samplesPerInput = trackKind == .aac ? 1_024 : 1_536
        }
        let seconds = CMTimeGetSeconds(boundarySession.maximumBoundaryDuration)
        guard seconds.isFinite, seconds > 0, seconds <= 60 else { throw SegmentedFMP4WriterFailure.invalidSystemConfiguration }
        let maximum = max(maximumObservedInputBytes, facts.projectedCharge)
        // The legacy byte reserve remains unchanged for encoded video and audio.
        // Remux keeps the same 2N+2 count reserve, with bytes calculated separately.
        let countCharge = facts.remuxBitrateEnvelope == nil ? maximum : 1
        let segment = try WriterBoundaryReserve(samplesPerSecond: rate, samplesPerAccessUnit: samplesPerInput,
            maximumBoundarySeconds: Int(ceil(seconds)), delayedPreviousInputs: 0, pendingPumpInputs: 0,
            interleavedInputs: 0, maximumInputBytes: countCharge, pendingOutputCallbacks: Self.pendingCallbackCapacity)
        let reserve = try WriterBoundaryReserve(samplesPerSecond: rate, samplesPerAccessUnit: samplesPerInput,
            maximumBoundarySeconds: Int(ceil(seconds)), delayedPreviousInputs: segment.segmentInputCount,
            pendingPumpInputs: trackKind == .aac ? 32 : 0, interleavedInputs: 2,
            maximumInputBytes: countCharge, pendingOutputCallbacks: Self.pendingCallbackCapacity)
        let remuxByteBudget: WriterRemuxByteBudget?
        if let envelope = facts.remuxBitrateEnvelope, let duration = facts.duration {
            remuxByteBudget = try WriterRemuxByteBudget(segmentInputCount: segment.segmentInputCount,
                declaredBitsPerSecond: envelope.declaredBitsPerSecond, frameDuration: duration)
        } else {
            remuxByteBudget = nil
        }
        let byteCapacity = trackKind == .video ? FMP4WriterLimits.video.writerHardByteCount : FMP4WriterLimits.audio.writerHardByteCount
        // Match private callback-authorized store limits before a one-shot claim:
        // six seconds of admitted <=60p video fits384; <=48k AAC fits320.
        // Larger/unknown cadence does not become another physical window.
        let metadataCapacity = min(inputEvidenceCapacity, trackKind == .video ? 384 : (trackKind == .aac ? 320 : 256))
        guard WriterDecodeCoveragePolicy.accepts(trackKind: trackKind,
                samplesPerSecond: rate, samplesPerAccessUnit: samplesPerInput,
                segmentInputCount: segment.segmentInputCount) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        guard reserve.fits(inputCapacity: ownershipLimits.hardCapacity, evidenceCapacity: metadataCapacity,
            inputByteCapacity: byteCapacity, outputCallbackCapacity: Self.pendingCallbackCapacity) else {
            rolloverReason = .rejectUnsupported
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        maximumObservedInputBytes = maximum; boundaryReserve = reserve
        let live = inputAdmission.usage
        // Between boundaries reserve the remaining path to THIS cut, not another
        // whole segment on every input; one retained predecessor still fits.
        let remaining = (ticket.requiresFlushBeforeAppend ? segment.segmentInputCount
            : max(1, segment.segmentInputCount - currentSegmentInputCount))
            + (trackKind == .aac ? 32 : 0) + 2
        let forwardBytes: Int
        if let remuxByteBudget {
            forwardBytes = try remuxByteBudget.forwardBytes(maximumInputBytes: maximum,
                currentSegmentBytes: ticket.requiresFlushBeforeAppend ? 0 : currentSegmentProjectedBytes,
                currentSegmentInputCount: ticket.requiresFlushBeforeAppend ? 0 : currentSegmentInputCount,
                nextInputBytes: facts.projectedCharge)
        } else {
            let bytes = remaining.multipliedReportingOverflow(by: maximum)
            guard !bytes.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            forwardBytes = bytes.partialValue
        }
        let willFlushCurrentSegment = ticket.requiresFlushBeforeAppend && currentSegmentInputCount > 0
        if currentSegmentInputCount == 0, !rolloverPending,
           !(try hasNextBoundaryHeadroomIsolated(remuxByteBudget: remuxByteBudget)) {
            // A new physical writer cannot erase predecessor native occupancy.
            // This is retryable admission pressure, not another rollover request.
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let decision = WriterContinuationPolicy.decide(
            boundary: try .beforeAppend(isSafeBoundary: ticket.requiresFlushBeforeAppend,
                currentNativeSequence: nextMovieFragmentSequenceNumberIsolated(),
                hasCurrentSegment: currentSegmentInputCount > 0),
            capacity: .init(liveCount: willFlushCurrentSegment ? 0 : live.count,
                liveBytes: willFlushCurrentSegment ? 0 : live.bytes,
                hardCount: ownershipLimits.hardCapacity, hardBytes: byteCapacity,
                nextBoundaryReserveCount: remaining, nextBoundaryReserveBytes: forwardBytes,
                pendingCallbacks: mediaPendingCallbackCount, callbackCapacity: Self.pendingCallbackCapacity),
            formatChanged: false)
        switch decision {
        case .continueCurrent: break
        case .rolloverAtBoundary:
            rolloverReason = decision; rolloverPending = true
            throw SegmentedFMP4WriterFailure.rolloverRequired
        case .newGeneration:
            rolloverReason = decision
            throw SegmentedFMP4WriterFailure.newGenerationRequired
        case .backpressure:
            throw SegmentedFMP4WriterFailure.relayCapacityExceeded
        case .rejectUnsupported:
            rolloverReason = decision
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        return remuxByteBudget
    }

    private func preflightTypedIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        readinessFailurePolicy: ReadinessFailurePolicy = .terminal,
        batchIdentity: UUID? = nil
    ) throws -> AppendPreflightAdmission {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        let duration: ExactMediaTime?
        let presentation: ExactMediaTime?
        let decode: ExactMediaTime?
        if trackKind == .video {
            duration = try ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer))
            presentation = try ExactMediaTime(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            let rawDTS = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            decode = rawDTS.isNumeric ? try ExactMediaTime(rawDTS) : presentation
        } else if trackKind == .ac3 || trackKind == .eac3 || sourceAACConfiguration != nil {
            duration = try ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer))
            presentation = try ExactMediaTime(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            decode = presentation
        } else {
            duration = try ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer))
            presentation = try ExactMediaTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let rawDTS = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            decode = rawDTS.isNumeric ? try ExactMediaTime(rawDTS) : nil
        }
        return try preflightAppendCoreIsolated(
            facts: AppendPreflightFacts(
                formatDescription: format,
                duration: duration,
                presentationTimeStamp: presentation,
                decodeTimeStamp: decode,
                projectedCharge: try Self.projectedCharge(sampleBuffer),
                sampleCount: CMSampleBufferGetNumSamples(sampleBuffer)
            ),
            ticket: ticket,
            sampleIdentity: sampleIdentity,
            readinessFailurePolicy: readinessFailurePolicy,
            batchIdentity: batchIdentity
        )
    }

    /// sample 与 remux 冻结字段在进入此处前已被各自权威入口转换成同一组只读事实。
    /// 共用规则只维护一份；readiness 的终态策略由调用入口显式选择。
    private func preflightAppendCoreIsolated(
        facts: AppendPreflightFacts,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        readinessFailurePolicy: ReadinessFailurePolicy,
        batchIdentity: UUID? = nil
    ) throws -> AppendPreflightAdmission {
        if let firstTypedCallbackFailure { throw firstTypedCallbackFailure }
        guard state == .started, awaitingAppend == nil,
              awaitingAACBatch == batchIdentity,
              (!finishRequested || batchIdentity != nil) else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        guard ticket.accepts(
            binding: binding,
            trackKind: trackKind,
            sampleIdentity: sampleIdentity,
            session: boundarySession
        ) else { throw SegmentedFMP4WriterFailure.boundaryMismatch }
        let formatMatches: Bool
        if CMFormatDescriptionEqual(facts.formatDescription, otherFormatDescription: sourceFormatHint) {
            formatMatches = true
        } else if trackKind == .video,
                  CMFormatDescriptionGetMediaType(facts.formatDescription) == kCMMediaType_Video,
                  CMFormatDescriptionGetMediaSubType(facts.formatDescription) == CMFormatDescriptionGetMediaSubType(sourceFormatHint) {
            let dim1 = CMVideoFormatDescriptionGetDimensions(facts.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(sourceFormatHint)
            formatMatches = (dim1.width == dim2.width && dim1.height == dim2.height)
        } else {
            formatMatches = false
        }
        guard formatMatches else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        if trackKind == .video {
            guard let duration = facts.duration,
                  let pts = facts.presentationTimeStamp,
                  let decode = facts.decodeTimeStamp else {
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            let valid: Bool
            if case .videoRemux = sampleIdentity {
                valid = duration.value > 0
                    && (remuxVideoCadence.map {
                        $0.duration == duration
                            && ($0.requiresExactNext
                                ? $0.nextDecodeTimeStamp == decode
                                : CMTimeCompare(
                                    decode.cmTime,
                                    $0.lastDecodeTimeStamp.cmTime) > 0)
                    } ?? true)
            } else {
                valid = duration.value > 0
                    && (videoCadence.map {
                        videoCadencePolicy.accepts(
                            previousDuration: $0.duration,
                            expectedNextPTS: $0.nextPTS,
                            duration: duration,
                            presentationTimeStamp: pts
                        )
                    } ?? true)
            }
            if !valid {
                cadenceIsValid = false
                // 无真实 callback context 的既有 inspection writer 永远不签 publication evidence。
                if callbackContext.isBound {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
            }
            _ = try pts.adding(duration)
        } else if trackKind == .ac3 || trackKind == .eac3 || sourceAACConfiguration != nil {
            guard let duration = facts.duration,
                  let pts = facts.presentationTimeStamp,
                  duration.value > 0,
                  compressedCadence.map({
                    $0.duration == duration && $0.nextPTS == pts
                  }) ?? true else {
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            _ = try pts.adding(duration)
        }
        let remuxByteBudget: WriterRemuxByteBudget?
        if usesExplicitOwnershipLimits {
            remuxByteBudget = nil
        } else {
            remuxByteBudget = try validateContinuationIsolated(facts: facts, ticket: ticket)
        }
        if !ticket.requiresFlushBeforeAppend {
            guard currentSegmentInputCount < inputEvidenceCapacity else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("fail_iec_3370_\(trackKind)_\(currentSegmentInputCount)_\(inputEvidenceCapacity)")
                #endif
                throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
            }
        }
        if rolloverPending {
            throw SegmentedFMP4WriterFailure.rolloverRequired
        }
        // AAC workspace 必须还能抵达下一个一秒共同边界。32 个真实 emission 的
        // soft 窗口小于 48 kHz/1024 packet 的边界间距；到边界时即使配置的通用
        // ownership 阈值更大，也先 rollover，避免旧 frozen ownership 占满预算。
        if ticket.requiresFlushBeforeAppend, usesExplicitOwnershipLimits,
           inputCount >= ownershipLimits.rolloverThreshold {
            rolloverReason = .rolloverAtBoundary
            rolloverPending = true
            throw SegmentedFMP4WriterFailure.rolloverRequired
        }
        guard inputAdmission.usage.count < ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let projected = currentSegmentProjectedBytes.addingReportingOverflow(
            facts.projectedCharge
        )
        guard !projected.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        guard relay.canReserve(projectedByteCount: projected.partialValue) else {
            throw SegmentedFMP4WriterFailure.relayCapacityExceeded
        }
        if ticket.requiresFlushBeforeAppend {
            guard ticket.logicalSequence > 0 else {
                throw SegmentedFMP4WriterFailure.boundaryMismatch
            }
            let expected = (lastLogicalSequence ?? ticket.logicalSequence - 1)
                .addingReportingOverflow(1)
            guard !expected.overflow, ticket.logicalSequence == expected.partialValue else {
                throw SegmentedFMP4WriterFailure.boundaryMismatch
            }
        } else if let lastLogicalSequence {
            guard ticket.logicalSequence == lastLogicalSequence else {
                throw SegmentedFMP4WriterFailure.boundaryMismatch
            }
        }
        if readinessFailurePolicy != .awaiting, !(try synchronousReadinessIsolated()) {
            if readinessFailurePolicy == .terminal {
                // 已物化 typed sample 的系统 readiness 是运行时失败；remux 则在唯一
                // payload claim 前以 recoverable 策略返回，不取消仍可继续的 writer。
                systemWriter.cancelWriting()
                _ = signTerminalIsolated(.failed)
            }
            throw SegmentedFMP4WriterFailure.notReady
        }
        guard let pts = facts.presentationTimeStamp, let duration = facts.duration else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        let inputLifetime = try inputAdmission.admit(bytes: facts.projectedCharge,
            sampleCount: facts.sampleCount)
        let evidence = try segmentEvidence.reserve(sequence: ticket.logicalSequence,
            sample: sampleIdentity, pts: pts, dts: facts.decodeTimeStamp,
            duration: duration, projectedBytes: facts.projectedCharge)
        var flushTicket: SegmentCallbackTicket?
        if ticket.requiresFlushBeforeAppend, currentSegmentInputCount > 0 {
            // The existing segment and the newly opened segment both need a
            // representable mfhd sequence; never let AVAssetWriter wrap to zero.
            _ = try nextMovieFragmentSequenceNumberIsolated(additionalFragments: 1)
            guard mediaPendingCallbackCount < Self.pendingCallbackCapacity else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            flushTicket = try relay.reserve(
                kind: .media,
                logicalSequence: ticket.logicalSequence - 1,
                projectedByteCount: currentSegmentProjectedBytes
            )
        }
        return AppendPreflightAdmission(flushTicket: flushTicket, inputLifetime: inputLifetime,
            inputBytes: facts.projectedCharge, remuxByteBudget: remuxByteBudget, evidence: evidence)
    }

    private func hasNextBoundaryHeadroomIsolated(excluding admission: AppendPreflightAdmission? = nil,
                                                remuxByteBudget: WriterRemuxByteBudget? = nil) throws -> Bool {
        guard let boundaryReserve else { throw SegmentedFMP4WriterFailure.illegalState }
        let nextCount = boundaryReserve.segmentInputCount + (trackKind == .aac ? 32 : 0) + 2
        let nextBytes: Int
        if let budget = remuxByteBudget ?? admission?.remuxByteBudget {
            nextBytes = try budget.forwardBytes(maximumInputBytes: maximumObservedInputBytes)
        } else {
            let bytes = nextCount.multipliedReportingOverflow(by: maximumObservedInputBytes)
            guard !bytes.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            nextBytes = bytes.partialValue
        }
        let live = inputAdmission.usage
        // A paid pending input belongs to the forward reservation, never to the
        // surviving predecessor. Its rollback cannot release another native alias.
        let pendingCount = admission?.inputLifetime == nil ? 0 : 1
        let pendingBytes = pendingCount == 0 ? 0 : (admission?.inputBytes ?? 0)
        let hardCount = min(ownershipLimits.hardCapacity, inputAdmission.capacity)
        let byteLimit = min(inputAdmission.maximumBytes, trackKind == .video
            ? FMP4WriterLimits.video.writerHardByteCount : FMP4WriterLimits.audio.writerHardByteCount)
        return nextCount <= hardCount && nextBytes <= byteLimit
            && live.count - pendingCount <= hardCount - nextCount
            && live.bytes - pendingBytes <= byteLimit - nextBytes
            && incrementalAACLiveContext?.hasNextWriterBoundaryHeadroom != false
    }

    private func flushIfRequiredIsolated(
        _ ticket: SegmentBoundaryAppendTicket,
        admission: inout AppendPreflightAdmission
    ) throws {
        guard ticket.requiresFlushBeforeAppend else { return }
        // rollover 后的新 writer 会从全局非零序号开始；它没有本地旧段可 flush。
        guard currentSegmentInputCount > 0 else {
            if !usesExplicitOwnershipLimits, !(try hasNextBoundaryHeadroomIsolated(excluding: admission)) {
                throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
            }
            if incrementalAACLiveContext?.hasNextWriterBoundaryHeadroom == false {
                throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
            }
            return
        }
        guard let callbackTicket = admission.flushTicket else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        admission.flushTicket = nil
        let prior = ticket.logicalSequence - 1
        pendingCallbacks.append(.init(
            ticket: callbackTicket,
            kind: .media,
            logicalSequence: prior,
            boundary: currentPublicationBoundary,
            frameDuration: currentFrameDuration
        ))
        guard systemWriter.flushSegment() else {
            let failure = systemFailureIsolated()
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw failure
        }
        currentSegmentProjectedBytes = 0
        currentSegmentInputCount = 0
        currentPublicationBoundary = nil
        currentFrameDuration = nil
        guard state == .started else {
            // flush can synchronously deliver an initialization that fails the
            // emitted-layout proof while the native call itself still succeeds.
            // Its retained typed rejection survives concurrent native cleanup.
            throw systemFailureIsolated("flush.state")
        }
        if !usesExplicitOwnershipLimits {
            let live = inputAdmission.usage
            let precedingCount = live.count - (admission.inputLifetime == nil ? 0 : 1)
            if !(try hasNextBoundaryHeadroomIsolated(excluding: admission))
                || precedingCount >= ownershipLimits.rolloverThreshold {
                rolloverReason = .rolloverAtBoundary; rolloverPending = true
                throw SegmentedFMP4WriterFailure.rolloverRequired
            }
        }
    }

    private func discardUnusedFlushAdmissionIsolated(
        _ admission: inout AppendPreflightAdmission
    ) {
        guard let ticket = admission.flushTicket else { return }
        admission.flushTicket = nil
        _ = relay.discard(ticket)
    }

    /// 在签发任何正式 ticket 前完成整个 AAC 批次的不变量、容量与 rollover 预检。
    private func preflightAACBatchIsolated(
        _ buffers: [CMSampleBuffer],
        preview: [SegmentBoundaryInspection],
        awaitsReadiness: Bool = false
    ) throws {
        guard state == .started, !finishRequested, awaitingAppend == nil,
                  awaitingAACBatch == nil else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        guard !rolloverPending, buffers.count == preview.count else {
            throw SegmentedFMP4WriterFailure.rolloverRequired
        }
        let totalOwnerships = inputAdmission.usage.count.addingReportingOverflow(buffers.count)
        guard !totalOwnerships.overflow,
              totalOwnerships.partialValue <= ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        var segmentInputs = currentSegmentInputCount
        var projectedBytes = currentSegmentProjectedBytes
        for index in buffers.indices {
            guard let format = CMSampleBufferGetFormatDescription(buffers[index]),
                  CMFormatDescriptionEqual(format, otherFormatDescription: sourceFormatHint) else {
                throw SegmentedFMP4WriterFailure.sourceFormatMismatch
            }
            if preview[index].requiresFlushBeforeAppend {
                if usesExplicitOwnershipLimits, inputCount + index >= ownershipLimits.rolloverThreshold {
                    rolloverPending = true
                    throw SegmentedFMP4WriterFailure.rolloverRequired
                }
                segmentInputs = 0
                projectedBytes = 0
            }
            let nextInputs = segmentInputs.addingReportingOverflow(1)
            guard !nextInputs.overflow,
                  nextInputs.partialValue <= inputEvidenceCapacity else {
                throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
            }
            let charge = try Self.projectedCharge(buffers[index])
            let nextBytes = projectedBytes.addingReportingOverflow(charge)
            guard !nextBytes.overflow,
                  relay.canReserve(projectedByteCount: nextBytes.partialValue) else {
                throw SegmentedFMP4WriterFailure.arithmeticOverflow
            }
            segmentInputs = nextInputs.partialValue
            projectedBytes = nextBytes.partialValue
        }
        if !awaitsReadiness, !(try synchronousReadinessIsolated()) {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.notReady
        }
    }

    private func synchronousReadinessIsolated() throws -> Bool {
        guard let inspection = systemWriter as? any SegmentedFMP4SynchronousSystemWriting else {
            throw SegmentedFMP4WriterFailure.illegalState
        }
        return inspection.isReadyForMoreMediaData
    }

    private func recordAppendIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        evidence: WriterSegmentEvidence.Reservation
    ) throws {
        do {
            try failRecordAppendIfRequestedIsolated()
            let charge = try Self.projectedCharge(sampleBuffer)
            let projected = currentSegmentProjectedBytes.addingReportingOverflow(charge)
            let nextInput = inputCount.addingReportingOverflow(1)
            let nextSegmentInput = currentSegmentInputCount.addingReportingOverflow(1)
            guard !projected.overflow, !nextInput.overflow, !nextSegmentInput.overflow,
                  evidence.sequence == ticket.logicalSequence else {
                throw SegmentedFMP4WriterFailure.arithmeticOverflow
            }
            try segmentEvidence.commit(evidence)
            currentSegmentProjectedBytes = projected.partialValue
            inputCount = nextInput.partialValue
            currentSegmentInputCount = nextSegmentInput.partialValue
            lastLogicalSequence = ticket.logicalSequence
            acceptanceObservation?.observed(logicalSequence: lastLogicalSequence,
                nativeSequence: lastNativeFragment?.sequence)
        } catch {
            // Native append/ticket commit cannot be undone. Every entry point,
            // including synchronous video, remux and compressed, fails closed.
            if state == .started, awaitingAppend == nil {
                systemWriter.cancelWriting()
                _ = signTerminalIsolated(.failed)
            }
            throw error
        }
    }

    private func failRecordAppendIfRequestedIsolated() throws {
        let nextOrdinal = inputCount.addingReportingOverflow(1)
        guard !nextOrdinal.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        guard recordAppendFailureOrdinal != nextOrdinal.partialValue else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
    }

    /// 必须在 cancel/retire 前读取系统首错；这些操作可能覆盖 AVAssetWriter.error。
    private func systemFailureIsolated(_ stage: StaticString = #function,
                                       line: UInt = #line) -> SegmentedFMP4WriterFailure {
#if DEBUG
        print("HLS_WRITER_FAILURE_SELECTION stage=\(stage) line=\(line) track=\(trackKind.rawValue) " +
            "state=\(state) inputs=\(inputCount) initialization=\(initializationCallbackCount) media=\(mediaCallbackCount) " +
            "pending=\(pendingCallbacks.count) typedCallback=\(firstTypedCallbackFailure != nil) retainedSystem=\(firstSystemFailureDiagnostic != nil)")
#endif
        if let firstTypedCallbackFailure { return firstTypedCallbackFailure }
        if firstSystemFailureDiagnostic == nil {
            firstSystemFailureDiagnostic = systemWriter.failureDiagnostic
        }
        if let diagnostic = firstSystemFailureDiagnostic {
#if DEBUG
            print("HLS_WRITER_FAILURE_SELECTED stage=\(stage) line=\(line) category=systemError")
#endif
            return .systemError(diagnostic)
        }
        return .diagnosedSystemFailure(stage, line: line)
    }

    private func finishSystemDidComplete(_ succeeded: Bool) {
        var continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
        var result: Result<SegmentedFMP4WriterTerminalReceipt, Error>?
        var requiresCleanup = false
        withLane {
            guard state == .finishing else { return }
            guard succeeded else {
                let failure = systemFailureIsolated()
                requiresCleanup = true
                continuation = beginFailureRetirementIsolated()
                result = .failure(failure)
                return
            }
            finishSystemSucceeded = true
            if pendingCallbacks.isEmpty {
                let receipt = signTerminalIsolated(.finished)
                continuation = takeFinishContinuationIsolated()
                result = .success(receipt)
            }
        }
        if requiresCleanup {
            scheduleFailureCleanup(continuation, result: result
                ?? .failure(SegmentedFMP4WriterFailure.diagnosedSystemFailure()))
            return
        }
        if let continuation, let result {
            resumeAfterPublications(continuation, with: result)
        }
    }

    private func recordCallbackIsolated(
        kind: SealedMediaObjectKind,
        logicalSequence: UInt64,
        bytes: Data,
        report: SegmentReportReference,
        acceptance: SegmentCallbackAcceptance,
        publicationEvidence: SegmentedFMP4PublicationEvidence?
    ) throws {
        let byteRange = AudioServiceByteRange(offset: 0, length: bytes.count)
        let digest = Data(SHA256.hash(data: bytes))
        guard acceptance.reportIdentity == report.identity,
              acceptance.byteRange == byteRange,
              acceptance.digest == digest else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure("callback.seal")
        }
        let nextEvidence = callbackEvidenceCount.addingReportingOverflow(1)
        guard !nextEvidence.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        callbackEvidenceCount = nextEvidence.partialValue
        callbackEvidenceDigest = Self.rollDigest(
            callbackEvidenceDigest,
            pieces: [
                Data([kind.rawValue]),
                Self.bytes(logicalSequence),
                Data(report.identity.uuidString.utf8),
                Data(acceptance.backingIdentity.rawValue.uuidString.utf8),
                Self.bytes(UInt64(acceptance.byteRange.offset)),
                Self.bytes(UInt64(acceptance.byteRange.length)),
                acceptance.digest,
            ]
        )
        lastCallbackReportIdentity = report.identity
        if let origin = sourceAACOrigin, let sourceAACTerminalBinding {
            guard let publicationEvidence else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
            do {
                publicationEvidence.sourceAAC = try sourceAACTerminalBinding.acceptCallback(origin: origin,
                    kind: kind, sequence: logicalSequence, bytes: bytes, report: report,
                    samples: kind == .media ? segmentEvidence.samples(for: logicalSequence) : [])
            } catch is CompressedAudioInitializationRejection {
                firstTypedCallbackFailure = .compressedAudioCompatibilityRequired
                throw SegmentedFMP4WriterFailure.compressedAudioCompatibilityRequired
            }
        }
        if kind == .initialization, let compressedSourceLayout, let compressedFormatConfiguration {
            guard let publicationEvidence else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
            do {
                publicationEvidence.dolbyInitialization = try DolbyWriterInitializationEvidence.validate(bytes,
                    configuration: compressedFormatConfiguration, sourceLayout: compressedSourceLayout)
            } catch is CompressedAudioInitializationRejection {
#if DEBUG
                print("HLS_DOLBY_INITIALIZATION_REJECT track=\(trackKind.rawValue) " +
                    "sourceMask=\(compressedSourceLayout.nativeMask ?? 0) bytes=\(bytes.count)")
#endif
                firstTypedCallbackFailure = .compressedAudioCompatibilityRequired
                throw SegmentedFMP4WriterFailure.compressedAudioCompatibilityRequired
            }
        }
        switch kind {
        case .initialization:
            let next = initializationCallbackCount.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            initializationCallbackCount = next.partialValue
            initializationBackingIdentity = acceptance.backingIdentity
            if trackKind == .aac, sourceAACConfiguration == nil {
                let object = AACEndpointSealedObjectEvidence(
                    key: HLSResourceKey(
                        itemGeneration: binding.itemGeneration.rawValue,
                        mediaEpoch: binding.mediaEpoch.rawValue,
                        participantID: binding.publicationParticipantID.rawValue,
                        logicalSequence: logicalSequence,
                        kind: .initialization),
                    backingIdentity: acceptance.backingIdentity,
                    sealedDigest: acceptance.digest,
                    byteCount: acceptance.byteRange.length,
                    reportIdentity: report.identity)
                guard aacRenditionTerminalBinding?.acceptInitialization(
                    object, binding: binding) == true else {
                    throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
                }
                aacWriterWindowAdmission?.recordInitialization(object)
            }
        case .media:
            let next = mediaCallbackCount.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            mediaCallbackCount = next.partialValue
            if trackKind == .aac, sourceAACConfiguration == nil {
                guard let leaf = acceptance.aacMediaMembershipLeaf else {
                    throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
                }
                let object = AACEndpointSealedObjectEvidence(
                    key: HLSResourceKey(
                        itemGeneration: binding.itemGeneration.rawValue,
                        mediaEpoch: binding.mediaEpoch.rawValue,
                        participantID: binding.publicationParticipantID.rawValue,
                        logicalSequence: logicalSequence,
                        kind: .media
                    ),
                    backingIdentity: acceptance.backingIdentity,
                    sealedDigest: acceptance.digest,
                    byteCount: acceptance.byteRange.length,
                    reportIdentity: report.identity
                )
                guard windowCallbackMembership.accept(leaf) == .accepted,
                      aacRenditionTerminalBinding?.acceptCallback(
                    leaf, evidence: object) == true else {
                    throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
                }
                if firstAACMediaEvidence == nil { firstAACMediaEvidence = object }
                terminalAACMediaEvidence = object
            }
            if trackKind == .aac, sourceAACConfiguration == nil,
               timelineMappingReceipt == nil,
               let inputPhysical = windowFirstPhysicalStart
                    ?? aacSnapshot?.firstPhysicalStart,
               let inputEffective = windowFirstOutputStart
                    ?? aacSnapshot?.firstOutputStart,
               let sampleRate = incrementalAACAccounting?.sampleRate
                    ?? windowSampleRate ?? aacSnapshot?.sampleRate,
               let written = report.earliestPresentationTimeStamp {
                let mapping = try AACWriterTimelineMappingReceipt(
                    binding: binding,
                    reportIdentity: report.identity,
                    sampleRate: sampleRate,
                    inputPhysicalBase: inputPhysical,
                    inputEffectiveBase: inputEffective,
                    writtenPhysicalBase: try ExactMediaTime(written),
                    leadingFrames: windowFirstPhysicalStart == nil
                        ? Int64(aacSnapshot?.leadingFrames ?? 0)
                        : windowLeadingFrames
                )
                guard aacRenditionTerminalBinding?.accept(mapping) == true else {
                    throw SegmentedFMP4WriterFailure.aacEndpointMismatch
                }
                timelineMappingReceipt = mapping
                guard let rendition = aacRenditionTerminalBinding,
                      let terminalBinding = aacTerminalBinding else {
                    throw SegmentedFMP4WriterFailure.aacEndpointMismatch
                }
                terminalBinding.freezeTimelineMapping(
                    mapping, renditionAnchor: rendition)
                aacWriterWindowAdmission?.recordMapping(mapping)
            }
        }
    }

    private func signTerminalIsolated(
        _ reason: SegmentedFMP4WriterTerminalReason
    ) -> SegmentedFMP4WriterTerminalReceipt {
        if let storedTerminalReceipt { return storedTerminalReceipt }
        state = .terminal
        awaitingAACBatch = nil
        let receipt = SegmentedFMP4WriterTerminalReceipt(
            identity: UUID(),
            binding: binding,
            terminalReason: reason,
            inputCount: inputCount,
            initializationCallbackCount: initializationCallbackCount,
            mediaCallbackCount: mediaCallbackCount,
            lastLogicalSequence: lastLogicalSequence,
            callbackEvidenceCount: callbackEvidenceCount,
            callbackEvidenceDigest: callbackEvidenceDigest,
            lastCallbackReportIdentity: lastCallbackReportIdentity
        )
        storedTerminalReceipt = receipt
        if reason != .finished {
            aacTerminalBinding?.fail(reason)
            sourceAACTerminalBinding?.fail()
        }
        if ownsPublicationSource { relay.closePublications() }
        let tickets = pendingCallbacks.map(\.ticket)
        if reason != .finished { inputAdmission.cancel(); compressedBackingAdmission.cancel() }
        segmentEvidence.discardUnverified()
        pendingCallbacks.removeAll(keepingCapacity: true)
        tickets.forEach { relay.discard($0) }
        // 只有真实终态路径可设置；普通 close/finish 值类型不能签发 publication drain。
        callbackContext.markTerminal()
        if reason != .cancelled {
            publicationQueue.async { [relay] in relay.notifyPublicationDrainIfReady() }
        }
        return receipt
    }

    private func takeFinishContinuationIsolated(
    ) -> CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>? {
        defer { finishContinuation = nil }
        return finishContinuation
    }

    /// 系统 writer 的 callback 栈不能同步 cancel 自己。先在 writer lane 把状态收敛为
    /// retiring，再把唯一取消登记到固定 cleanup lane；取消返回后才签发 terminal 并恢复 waiter。
    private func beginFailureRetirementIsolated(
    ) -> CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>? {
        precondition(state != .terminal && state != .retiring)
        state = .retiring
        cleanupGroup.enter()
        return takeFinishContinuationIsolated()
    }

    private func scheduleFailureCleanup(
        _ continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?,
        result: Result<SegmentedFMP4WriterTerminalReceipt, Error>
    ) {
        scheduleRetirementCleanup(continuation, result: result, reason: .failed)
    }

    private func scheduleRetirementCleanup(
        _ continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?,
        result: Result<SegmentedFMP4WriterTerminalReceipt, Error>,
        reason: SegmentedFMP4WriterTerminalReason
    ) {
        let native = withLane { awaitingAppend?.native }
        native?.cancel()
        cleanupQueue.async { [self] in
            systemWriter?.cancelWriting()
            Task { [self] in
                // native 可能晚成功；取消封闭的事务已不能签发 append 资格。
                // backing、pending callback 和 admission ownership 至此才可释放。
                if let native { _ = await native.result }
                withLane {
                    guard state == .retiring else { return }
                    awaitingAppend = nil
                    _ = signTerminalIsolated(reason)
                }
                if let continuation {
                    resumeAfterPublications(continuation, with: result)
                }
                relay.notifyPublicationDrainIfReady()
                cleanupGroup.leave()
            }
        }
    }

    /// Apple HLS separable callbacks each contain one movie fragment. Advance by
    /// emitted media callbacks, excluding initialization and unrelated writer IDs.
    /// Pending callbacks are included only while checking live-writer capacity;
    /// terminal-and-drained continuations have none.
    private func nextMovieFragmentSequenceNumberIsolated(additionalFragments: Int = 0) throws -> Int {
        let completedAndPending = mediaCallbackCount.addingReportingOverflow(mediaPendingCallbackCount)
        let count = completedAndPending.partialValue.addingReportingOverflow(additionalFragments)
        let next = initialMovieFragmentSequenceNumber.addingReportingOverflow(count.partialValue)
        guard !completedAndPending.overflow, !count.overflow, !next.overflow,
              HLSWriterSequencePolicy.supportedRange.contains(next.partialValue) else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        return next.partialValue
    }

    private var mediaPendingCallbackCount: Int {
        pendingCallbacks.reduce(into: 0) { count, pending in
            if pending.kind == .media { count += 1 }
        }
    }

    private func schedulePublicationIsolated(_ acceptance: SegmentCallbackAcceptance) -> Bool {
        relay.consumePublication(acceptance) { [publicationQueue, publicationGroup] body in
            publicationGroup.enter()
            publicationQueue.async {
                body()
                publicationGroup.leave()
            }
        }
    }

    private func resumeAfterPublications(
        _ continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>,
        with result: Result<SegmentedFMP4WriterTerminalReceipt, Error>
    ) {
        publicationQueue.async {
            continuation.resume(with: result)
        }
    }

    private func makeAACSnapshot(
        _ epoch: AACEncodedEpoch,
        extending previous: AACSnapshot? = nil
    ) throws -> AACSnapshot {
        guard !epoch.buffers.isEmpty else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
        }
        var digest = Data(SHA256.hash(data: Data()))
        var totalDecodedFrames = 0
        var leadingFrames = 0
        var trailingFrames = 0
        var sampleRate: Int32?
        var expectedStart: CMTime?
        for (index, buffer) in epoch.buffers.enumerated() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  CMFormatDescriptionEqual(format, otherFormatDescription: sourceFormatHint),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFormatID == kAudioFormatMPEG4AAC,
                  asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
                  let bufferSampleRate = Int32(exactly: asbd.mSampleRate),
                  bufferSampleRate == 48_000,
                  asbd.mFramesPerPacket > 0,
                  CMSampleBufferGetNumSamples(buffer) > 0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let packetFrames = Int(asbd.mFramesPerPacket)
            if let sampleRate, sampleRate != bufferSampleRate {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            sampleRate = bufferSampleRate
            let decoded = CMSampleBufferGetNumSamples(buffer).multipliedReportingOverflow(by: packetFrames)
            let nextTotal = totalDecodedFrames.addingReportingOverflow(decoded.partialValue)
            guard !decoded.overflow, !nextTotal.overflow else {
                throw SegmentedFMP4WriterFailure.arithmeticOverflow
            }
            let startTrim = try trim(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                sampleRate: bufferSampleRate)
            let endTrim = try trim(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                sampleRate: bufferSampleRate)
            guard startTrim <= Int64(decoded.partialValue),
                  endTrim <= Int64(decoded.partialValue),
                  (index == 0 || startTrim == 0),
                  (index == epoch.buffers.count - 1 || endTrim == 0) else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let outputStart = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
            if let expectedStart, CMTimeCompare(outputStart, expectedStart) != 0 {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let expectedDuration = CMTime(value: Int64(decoded.partialValue),
                                          timescale: bufferSampleRate)
            guard CMTimeCompare(CMSampleBufferGetDuration(buffer), expectedDuration) == 0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            let effectiveFrames = Int64(decoded.partialValue) - startTrim - endTrim
            guard effectiveFrames >= 0 else {
                throw SegmentedFMP4WriterFailure.aacEndpointMismatch
            }
            expectedStart = CMTimeAdd(
                outputStart,
                CMTime(value: effectiveFrames, timescale: bufferSampleRate)
            )
            totalDecodedFrames = nextTotal.partialValue
            if index == 0 { leadingFrames = Int(startTrim) }
            if index == epoch.buffers.count - 1 { trailingFrames = Int(endTrim) }
            digest = Self.rollDigest(digest,
                pieces: try inputEvidencePieces(buffer, sampleRate: bufferSampleRate))
        }
        let trims = leadingFrames.addingReportingOverflow(trailingFrames)
        let real = totalDecodedFrames.subtractingReportingOverflow(trims.partialValue)
        guard !trims.overflow, !real.overflow, real.partialValue >= 0,
              epoch.realSampleCount == real.partialValue,
              epoch.totalDecodedFrames == totalDecodedFrames,
              epoch.leadingFrames == leadingFrames,
              epoch.trailingFrames == trailingFrames,
              epoch.actualLeadingPrimeFrames == UInt32(exactly: leadingFrames),
              epoch.actualTrailingPrimeFrames == UInt32(exactly: trailingFrames),
              let sampleRate else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let firstPhysicalStart = try ExactMediaTime(
            CMSampleBufferGetPresentationTimeStamp(epoch.buffers[0]))
        let firstOutputStart = try ExactMediaTime(
            CMSampleBufferGetOutputPresentationTimeStamp(epoch.buffers[0]))
        guard firstOutputStart == (try firstPhysicalStart.adding(
            ExactMediaTime(value: Int64(leadingFrames), timescale: sampleRate))) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let current = AACSnapshot(
            epochIdentity: epoch.identity,
            inputCount: epoch.buffers.count,
            inputDigest: digest,
            sampleRate: sampleRate,
            firstPhysicalStart: firstPhysicalStart,
            firstOutputStart: firstOutputStart,
            realSampleCount: real.partialValue,
            totalDecodedFrames: totalDecodedFrames,
            leadingFrames: leadingFrames,
            trailingFrames: trailingFrames
        )
        guard let previous else {
            return current
        }
        // 一个 writer/binding 就是一个媒体证据域。encoder identity 变化必须换新
        // writer；否则 snapshot 重置而 callback/段序列继续累积会形成分裂 authority。
        guard previous.epochIdentity == current.epochIdentity else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        guard previous.sampleRate == current.sampleRate,
              previous.trailingFrames == 0,
              current.leadingFrames == 0 else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let priorPhysicalEnd = try previous.firstPhysicalStart.adding(
            ExactMediaTime(value: Int64(previous.totalDecodedFrames),
                           timescale: previous.sampleRate))
        let priorEffectiveEnd = try previous.firstOutputStart.adding(
            ExactMediaTime(value: Int64(previous.realSampleCount),
                           timescale: previous.sampleRate))
        guard priorPhysicalEnd == current.firstPhysicalStart,
              priorEffectiveEnd == current.firstOutputStart else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let combinedInputCount = previous.inputCount.addingReportingOverflow(
            current.inputCount)
        let combinedReal = previous.realSampleCount.addingReportingOverflow(
            current.realSampleCount)
        let combinedTotal = previous.totalDecodedFrames.addingReportingOverflow(
            current.totalDecodedFrames)
        // These cumulative scalars and digest do not own native inputs or retain
        // per-sample evidence. Live capacity is enforced by inputAdmission and
        // segmentEvidence, independently of the persistent writer's lifetime count.
        guard !combinedInputCount.overflow,
              !combinedReal.overflow,
              !combinedTotal.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        var combinedDigest = previous.inputDigest
        for buffer in epoch.buffers {
            combinedDigest = Self.rollDigest(
                combinedDigest,
                pieces: try inputEvidencePieces(buffer,
                    sampleRate: current.sampleRate))
        }
        return AACSnapshot(
            epochIdentity: current.epochIdentity,
            inputCount: combinedInputCount.partialValue,
            inputDigest: combinedDigest,
            sampleRate: current.sampleRate,
            firstPhysicalStart: previous.firstPhysicalStart,
            firstOutputStart: previous.firstOutputStart,
            realSampleCount: combinedReal.partialValue,
            totalDecodedFrames: combinedTotal.partialValue,
            leadingFrames: previous.leadingFrames,
            trailingFrames: current.trailingFrames
        )
    }

    private func inputEvidencePieces(_ buffer: CMSampleBuffer,
                                     sampleRate: Int32) throws -> [Data] {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let block = CMSampleBufferGetDataBuffer(buffer) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let status = payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: $0.baseAddress!
            )
        }
        guard status == noErr else { throw SegmentedFMP4WriterFailure.aacEndpointMismatch }
        let physicalTiming = try ExactMediaTime(CMSampleBufferGetPresentationTimeStamp(buffer))
        let outputTiming = try ExactMediaTime(
            CMSampleBufferGetOutputPresentationTimeStamp(buffer))
        let duration = try ExactMediaTime(CMSampleBufferGetDuration(buffer))
        let sampleCount = CMSampleBufferGetNumSamples(buffer)
        return [
            Data(ObjectIdentifier(buffer).debugDescription.utf8),
            Data(ObjectIdentifier(format).debugDescription.utf8),
            Data(SHA256.hash(data: payload)),
            Self.bytes(physicalTiming.value),
            Self.bytes(Int64(physicalTiming.timescale)),
            Self.bytes(outputTiming.value),
            Self.bytes(Int64(outputTiming.timescale)),
            Self.bytes(duration.value),
            Self.bytes(Int64(duration.timescale)),
            Self.bytes(Int64(sampleCount)),
            Self.bytes(try trim(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                sampleRate: sampleRate)),
            Self.bytes(try trim(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                                sampleRate: sampleRate)),
        ]
    }

    private func trim(_ buffer: CMSampleBuffer, key: CFString,
                      sampleRate: Int32) throws -> Int64 {
        guard let attachment = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) else { return 0 }
        guard CFGetTypeID(attachment) == CFDictionaryGetTypeID() else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let time = CMTimeMakeFromDictionary((attachment as! CFDictionary))
        let scaled = CMTimeConvertScale(time, timescale: sampleRate, method: .default)
        guard time.isNumeric, time.epoch == 0, scaled.value >= 0,
              CMTimeCompare(time, scaled) == 0 else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        return scaled.value
    }

    private func makeSourceAACSampleBuffer(_ unit: SourceAACAccessUnit) throws
        -> (sample: CMSampleBuffer, lifetime: WriterInputLifetime) {
        let charge = unit.payload.count.addingReportingOverflow(HLSOwnedBlockAdmission.fixedOwnerMetadataBytes)
        guard !charge.overflow, let lease = compressedBackingAdmission.acquire(units: 1,
            bytes: unit.payload.count, applicationBytes: charge.partialValue) else {
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        // The producer proof/paid source backing follows the actual block alias,
        // never physical writer completion or a copied NSData no-copy wrapper.
        let lifetime = WriterInputLifetime(capacityWakeup: withLane { compressedCapacityWakeup }) { [admission = compressedBackingAdmission, lease, unit] in
            lease.release(); withExtendedLifetime((admission, unit)) {}
        }
        let block = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(copying: unit.payload, lifetime: lifetime)
        var timing = CMSampleTimingInfo(duration: unit.duration.cmTime,
            presentationTimeStamp: unit.presentationStart.cmTime, decodeTimeStamp: .invalid)
        var size = unit.payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: sourceFormatHint, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
        return (sample, lifetime)
    }

    private func makeCompressedSampleBuffer(
        _ accessUnit: CompressedAudioAccessUnit,
        presentationStart: CMTime? = nil,
        nativeTail: DolbyAudioPayloadLifetime? = nil,
        retainedLifetime: ((WriterInputLifetime) -> Void)? = nil
    ) throws -> CMSampleBuffer {
        let payload = accessUnit.payload
        let charge = payload.count.addingReportingOverflow(HLSOwnedBlockAdmission.fixedOwnerMetadataBytes)
        guard !charge.overflow, let lease = compressedBackingAdmission.acquire(units: 1,
            bytes: payload.count, applicationBytes: charge.partialValue) else {
            throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
        }
        let lifetime = WriterInputLifetime(capacityWakeup: nativeTail == nil ? nil : withLane { compressedCapacityWakeup }) { [admission = compressedBackingAdmission, lease, nativeTail] in
            lease.release()
            withExtendedLifetime((admission, nativeTail)) {}
        }
        retainedLifetime?(lifetime)
        let block = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(copying: payload, lifetime: lifetime)
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: Int64(accessUnit.sampleCount),
                timescale: accessUnit.sampleRate
            ),
            presentationTimeStamp: presentationStart ?? accessUnit.presentationStart,
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: sourceFormatHint,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure("compressed.sampleBuffer", status: status)
        }
        return sample
    }

    private static func validateFrozenFormat(
        trackKind: SegmentedFMP4TrackKind,
        sourceFormatHint: CMFormatDescription,
        compressedConfiguration: CompressedAudioFormatConfiguration?
    ) throws {
        switch trackKind {
        case .video, .aac:
            guard compressedConfiguration == nil else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
        case .ac3, .eac3:
            guard let compressedConfiguration,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint)?.pointee else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
            var cookieSize = 0
            guard let cookiePointer = CMAudioFormatDescriptionGetMagicCookie(
                sourceFormatHint,
                sizeOut: &cookieSize
            ), cookieSize > 0 else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
            let sourceConfigurationBytes = Data(bytes: cookiePointer, count: cookieSize)
            let expectedCodec: AudioCodec = trackKind == .ac3 ? .ac3 : .eac3
            let expectedFormatID = trackKind == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3
            let channelFacts: (mode: UInt8, lfe: Bool) = switch compressedConfiguration {
            case let .ac3(value): (value.audioCodingMode, value.hasLFE)
            case let .eac3(value): (value.audioCodingMode, value.hasLFE)
            }
            let baseChannels: UInt32 = switch channelFacts.mode {
            case 0: 2
            case 1: 1
            case 2: 2
            case 3, 4: 3
            case 5, 6: 4
            case 7: 5
            default: 0
            }
            let expectedChannels = baseChannels + (channelFacts.lfe ? 1 : 0)
            guard compressedConfiguration.codec == expectedCodec,
                  sourceConfigurationBytes == compressedConfiguration.serializedBox,
                  compressedConfiguration.sampleRate == Int32(asbd.mSampleRate),
                  asbd.mFormatID == expectedFormatID,
                  asbd.mFramesPerPacket == 1_536,
                  asbd.mChannelsPerFrame == expectedChannels,
                  (try? compressedConfiguration.validateFinalBoxes([
                      compressedConfiguration.serializedBox,
                  ])) != nil else {
                throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
            }
        }
    }

    private static func projectedCharge(_ sampleBuffer: CMSampleBuffer) throws -> Int {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw SegmentedFMP4WriterFailure.diagnosedSystemFailure()
        }
        let result = CMBlockBufferGetDataLength(block).addingReportingOverflow(Self.sampleChargeOverhead)
        guard !result.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        return result.partialValue
    }

    private static func callbackDigest(objects: [SealedMediaObject]) -> Data {
        objects.reduce(Data(SHA256.hash(data: Data()))) { digest, object in
            rollDigest(digest, pieces: [
                Data([object.kind.rawValue]),
                bytes(object.logicalSequence),
                Data(object.report.identity.uuidString.utf8),
                Data(object.backing.identity.rawValue.uuidString.utf8),
                bytes(UInt64(object.byteRange.offset)),
                bytes(UInt64(object.byteRange.length)),
                object.digest,
            ])
        }
    }

    private static func rollDigest(_ prior: Data, pieces: [Data]) -> Data {
        var input = prior
        for piece in pieces {
            input.append(bytes(UInt64(piece.count)))
            input.append(piece)
        }
        return Data(SHA256.hash(data: input))
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private func withLane<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: laneKey) == laneIdentity {
            return try body()
        }
        return try lane.sync(execute: body)
    }
}
