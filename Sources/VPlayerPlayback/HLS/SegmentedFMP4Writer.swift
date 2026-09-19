// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

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
final class SegmentedFMP4PublicationEvidence: @unchecked Sendable {
    let format: SegmentedFMP4FrozenFormat
    let boundary: SegmentCommittedBoundary?
    let session: SegmentBoundarySession
    let frameDuration: ExactMediaTime?
    let writerSource: SegmentedFMP4CallbackContext
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
    init(contentTypeIdentifier: String, outputFileTypeProfile: String, preferredOutputSegmentInterval: CMTime,
         mediaType: AVMediaType, outputSettingsAreNil: Bool, sourceFormatHintIdentity: ObjectIdentifier?, inputCount: Int,
         callbackContext: SegmentedFMP4CallbackContext? = nil) {
        self.contentTypeIdentifier = contentTypeIdentifier; self.outputFileTypeProfile = outputFileTypeProfile
        self.preferredOutputSegmentInterval = preferredOutputSegmentInterval; self.mediaType = mediaType
        self.outputSettingsAreNil = outputSettingsAreNil; self.sourceFormatHintIdentity = sourceFormatHintIdentity
        self.inputCount = inputCount; self.callbackContext = callbackContext
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
    var isReadyForMoreMediaData: Bool { get }
    func startWriting(at sourceTime: CMTime) -> Bool
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
    func flushSegment() -> Bool
    func markInputAsFinished()
    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void)
    func cancelWriting()
}

protocol SegmentedFMP4SystemWriterFactory: Sendable {
    func makeWriter(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting
}

final class AVAssetSegmentedFMP4SystemWriterFactory: SegmentedFMP4SystemWriterFactory, @unchecked Sendable {
    func makeWriter(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting {
        try AVAssetSegmentedFMP4SystemWriter(
            configuration: configuration,
            sourceFormatHint: sourceFormatHint,
            callbackSink: callbackSink
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

private final class AVAssetSegmentedFMP4SystemWriter: SegmentedFMP4SystemWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let segmentDelegate: AVAssetSegmentDelegate

    init(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws {
        guard configuration.contentTypeIdentifier == UTType.mpeg4Movie.identifier,
              configuration.outputFileTypeProfile == AVFileTypeProfile.mpeg4AppleHLS.rawValue,
              CMTIME_IS_INDEFINITE(configuration.preferredOutputSegmentInterval),
              configuration.outputSettingsAreNil,
              configuration.sourceFormatHintIdentity == ObjectIdentifier(sourceFormatHint),
              configuration.inputCount == 1 else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
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
        input.expectsMediaDataInRealTime = false
        if configuration.mediaType == .video { input.mediaTimeScale = configuration.videoMediaTimeScale }
        guard writer.canAdd(input) else { throw SegmentedFMP4WriterFailure.invalidSystemConfiguration }
        writer.add(input)
        self.writer = writer
        self.input = input
        self.segmentDelegate = segmentDelegate
        try configuration.callbackContext?.bind(adapter: self, writer: ObjectIdentifier(writer), source: sourceFormatHint)
    }

    var objectIdentity: ObjectIdentifier { ObjectIdentifier(writer) }
    var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    func startWriting(at sourceTime: CMTime) -> Bool {
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: sourceTime)
        return true
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool { input.append(sampleBuffer) }

    func flushSegment() -> Bool {
        writer.flushSegment()
        return writer.status == .writing && writer.error == nil
    }

    func markInputAsFinished() { input.markAsFinished() }

    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) {
        writer.finishWriting { [weak self] in
            guard let self else { return }
            completion(self.writer.status == .completed && self.writer.error == nil)
        }
    }

    func cancelWriting() { writer.cancelWriting() }
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
    case compressedIdentityMismatch
    case aacEndpointMismatch
    case inputEvidenceCapacityExceeded
    case terminalOwnershipCapacityExceeded
    case rolloverRequired
    case relayCapacityExceeded
    case arithmeticOverflow
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
    static let audio = Self(rolloverThreshold: 96, hardCapacity: 256)
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
    private var state: State = .issued

    fileprivate init(
        predecessorTerminal: SegmentedFMP4WriterTerminalReceipt,
        trackKind: SegmentedFMP4TrackKind,
        frozenFormat: SegmentedFMP4FrozenFormat,
        cadence: WriterWindowCadence?
    ) {
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
    private var state: State = .issued
    var nextPhysicalStart: ExactMediaTime? { accounting.nextPhysicalStart }

    fileprivate init(receipt: AACWriterWindowTerminalReceipt,
                     accounting: AACIncrementalStreamAccounting,
                     context: AACLiveEncodingContext,
                     renditionBinding: AACRenditionTerminalBinding) {
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
    let retainedTerminalOwnershipCount: Int
    let pendingCallbackCount: Int
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
            terminal = .failure(.systemFailure)
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
                  writer.systemWriter.append(sampleBuffer),
                  writer.state == .started else { return nil }
            return AppendSuccessAuthority(writer: writer, ticket: ticket, sampleIdentity: sampleIdentity)
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
        case .aac, .ac3, .eac3:
            return 256
        }
    }

    let binding: FMP4WriterBinding
    let trackKind: SegmentedFMP4TrackKind
    private let sourceFormatHint: CMFormatDescription
    private let frozenFormat: SegmentedFMP4FrozenFormat
    private let videoCadencePolicy: SegmentedFMP4VideoCadencePolicy
    private let boundarySession: SegmentBoundarySession
    private let compressedFormatConfiguration: CompressedAudioFormatConfiguration?
    private let ownershipLimits: SegmentedFMP4WriterOwnershipLimits
    private let recordAppendFailureOrdinal: Int?
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
    private var retainedTerminalOwnerships: [FMP4InputOwnership] = []
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
    private var pendingCallbacks: [PendingCallback] = []
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
    }
    private struct AppendPreflightAdmission {
        var flushTicket: SegmentCallbackTicket?
    }
    private enum ReadinessFailurePolicy {
        case terminal
        case recoverable
    }
    private var remuxVideoCadence: RemuxVideoCadence?
    private var compressedCadence: CompressedCadence?
    private var remuxFormatAuthorityWitness: AnyObject?
    private var cadenceIsValid = true
    private let callbackContext: SegmentedFMP4CallbackContext
    private var ownsPublicationSource = false
    private var inputCount = 0
    private var initializationCallbackCount = 0
    private var mediaCallbackCount = 0
    private var lastLogicalSequence: UInt64?
    private var callbackEvidenceCount = 0
    private var callbackEvidenceDigest = Data(SHA256.hash(data: Data()))
    private var initializationBackingIdentity: SealedMediaBackingIdentity?
    private var lastCallbackReportIdentity: UUID?
    private var finishSystemSucceeded = false
    private var finishContinuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
    private var storedTerminalReceipt: SegmentedFMP4WriterTerminalReceipt?
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
        recordAppendFailureOrdinal: Int? = nil
    ) throws {
        self.binding = binding
        self.trackKind = trackKind
        self.sourceFormatHint = sourceFormatHint
        self.videoCadencePolicy = videoCadencePolicy
        guard let frozenFormat = SegmentedFMP4FrozenFormat(sourceFormatHint) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        self.frozenFormat = frozenFormat
        self.boundarySession = boundarySession
        self.compressedFormatConfiguration = compressedFormatConfiguration
        self.ownershipLimits = ownershipLimits ?? (trackKind == .video ? .video : (trackKind == .aac ? .audio : .standard))
        self.recordAppendFailureOrdinal = recordAppendFailureOrdinal
        self.relay = relay
        guard aacContinuation == nil || writerWindowContinuation == nil else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        if let continuation = aacContinuation {
            guard trackKind == .aac,
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
            aacRenditionTerminalBinding = trackKind == .aac
                ? AACRenditionTerminalBinding(binding) : nil
            aacWriterWindowAdmission = nil
        }
        if let continuation = writerWindowContinuation {
            guard trackKind != .aac,
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
                guard trackKind == .ac3 || trackKind == .eac3 else {
                    throw SegmentedFMP4WriterFailure.sourceFormatMismatch
                }
                compressedCadence = .init(duration: duration, nextPTS: nextPTS)
            case nil:
                break
            }
        } else {
            writerWindowAdmission = nil
        }
        aacTerminalBinding = trackKind == .aac
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
            callbackContext: callbackContext
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

    var usage: SegmentedFMP4WriterUsage {
        withLane {
            SegmentedFMP4WriterUsage(
                retainedTerminalOwnershipCount: retainedTerminalOwnerships.count,
                pendingCallbackCount: pendingCallbacks.count
            )
        }
    }

    var incrementalAACCommittedInputCount: UInt64 {
        withLane { incrementalAACAccounting?.inputCount ?? 0 }
    }

    var isAACWriterWindowRolloverPending: Bool {
        withLane { trackKind == .aac && rolloverPending && state == .started }
    }

    var aacCallbackMembershipSnapshot: AACMediaMembershipSnapshot? {
        aacRenditionTerminalBinding?.callbackMembership.snapshot
    }

    func start(at sourceTime: CMTime) throws {
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
                systemWriter.cancelWriting()
                _ = signTerminalIsolated(.failed)
                throw SegmentedFMP4WriterFailure.systemFailure
            }
            guard state != .terminal else { throw SegmentedFMP4WriterFailure.systemFailure }
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
                    ownership: FMP4InputOwnership {
                        withExtendedLifetime(output) {}
                    }
                )
            }
        } catch {
            ticket.abort(binding: binding, session: boundarySession)
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
                let sample = try attempt.materializeForWriter(
                    HLSVideoRemuxWriterMaterializationAuthority(binding: binding)
                )
                try appendAfterPreflightIsolated(
                    sample,
                    ticket: ticket,
                    sampleIdentity: identity,
                    ownership: FMP4InputOwnership {
                        withExtendedLifetime(attempt.pending) {}
                    },
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
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                guard retainedTerminalOwnerships.count < ownershipLimits.hardCapacity,
                      ticket.prepare(
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
                    _ = submission.accessUnit.confirmWriterTerminal(using: coordinator)
                }
                retainedTerminalOwnerships.append(ownership)
                guard appendAndCommitIsolated(sampleBuffer, ticket: ticket, sampleIdentity: identity) else {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                try recordAppendIsolated(sampleBuffer, ticket: ticket)
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
        guard trackKind == .aac,
              !epoch.buffers.isEmpty,
              coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
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
                    retainedTerminalOwnerships.append(FMP4InputOwnership {
                        withExtendedLifetime(epoch) {}
                    })
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
                        epoch.buffers[index], ticket: ticket, sampleIdentity: identities[index]
                    ) else {
                        systemWriter.cancelWriting()
                        _ = signTerminalIsolated(.failed)
                        throw SegmentedFMP4WriterFailure.systemFailure
                    }
                    appendedAny = true
                    try failRecordAppendIfRequestedIsolated()
                    try recordAppendIsolated(epoch.buffers[index], ticket: ticket)
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

    func appendAACIncremental(
        _ emission: AACIncrementalEmission,
        coordinator: SegmentBoundaryCoordinator
    ) throws -> AACIncrementalAppendResult {
        guard trackKind == .aac,
              coordinator.session === boundarySession else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        return try withLane {
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
            guard systemWriter.isReadyForMoreMediaData else { return .retryLater }

            let buffer: CMSampleBuffer
            do { buffer = try emission.materializeSampleBuffer() }
            catch { throw SegmentedFMP4WriterFailure.aacEndpointMismatch }
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
                      retainedTerminalOwnerships.count < ownershipLimits.hardCapacity,
                      ticket.prepare(binding: binding, trackKind: trackKind,
                                     sampleIdentity: identity,
                                     session: boundarySession) else {
                    throw SegmentedFMP4WriterFailure.boundaryMismatch
                }
                retainedTerminalOwnerships.append(FMP4InputOwnership {
                    withExtendedLifetime(emission) {}
                })
                guard appendAndCommitIsolated(buffer, ticket: ticket,
                                              sampleIdentity: identity) else {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                systemAppendSucceeded = true
                try failRecordAppendIfRequestedIsolated()
                try recordAppendIsolated(buffer, ticket: ticket)
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
            incrementalAACAccounting = prospective
            incrementalAACNextOrdinal = nextCount.partialValue
            incrementalAACDigest = nextDigest
            incrementalAACLiveContext = emission.liveContext
            if windowFirstPhysicalStart == nil {
                windowFirstPhysicalStart = physical
                windowFirstOutputStart = output
                windowLeadingFrames = leading
            }
            return .appended
        }
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
                if let receipt = storedTerminalReceipt { return .success(receipt) }
                guard state == .started else {
                    return .failure(SegmentedFMP4WriterFailure.illegalState)
                }
                guard mediaPendingCallbackCount < Self.pendingCallbackCapacity,
                      relay.canReserve(projectedByteCount: currentSegmentProjectedBytes) else {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    return .failure(SegmentedFMP4WriterFailure.illegalState)
                }
                do {
                    let ticket = try relay.reserve(
                        kind: .media,
                        logicalSequence: lastLogicalSequence ?? 0,
                        projectedByteCount: currentSegmentProjectedBytes
                    )
                    pendingCallbacks.append(.init(
                        ticket: ticket,
                        kind: .media,
                        logicalSequence: lastLogicalSequence ?? 0,
                        boundary: currentPublicationBoundary,
                        frameDuration: currentFrameDuration
                    ))
                } catch {
                    systemWriter.cancelWriting()
                    _ = signTerminalIsolated(.failed)
                    return .failure(error)
                }
                state = .finishing
                finishContinuation = continuation
                systemWriter.markInputAsFinished()
                systemWriter.finishWriting { [weak self] succeeded in
                    self?.finishSystemDidComplete(succeeded)
                }
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    /// 中间窗口真实 finish + callback/publication ownership 全部收敛后才签发接管权。
    /// 它不接收 encoder final receipt，也不封存 P/ENDLIST。
    func finishAACWriterWindow() async throws -> AACWriterWindowContinuation {
        guard trackKind == .aac else { throw SegmentedFMP4WriterFailure.aacEndpointMismatch }
        let drainTask = Task { [relay, callbackContext] in
            await relay.waitForPublicationDrain(source: callbackContext)
        }
        let terminal = try await finish()
        guard let drain = await drainTask.value,
              relay.accepts(drain, source: callbackContext) else {
            throw SegmentedFMP4WriterFailure.systemFailure
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
                mediaMembership: renditionBinding.callbackMembership.snapshot,
                firstMedia: firstAACMediaEvidence,
                terminalMedia: terminalAACMediaEvidence,
                mapping: mapping)
            windowContinuationIssued = true
            return AACWriterWindowContinuation(
                receipt: receipt, accounting: accounting, context: context,
                renditionBinding: renditionBinding)
        }
    }

    /// Finishes one non-AAC physical writer without ending the logical encoder or
    /// audio branch. The continuation is signed only after system terminal and
    /// publication drain have both completed.
    func finishWriterWindow() async throws -> WriterWindowContinuation {
        guard trackKind != .aac else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let drainTask = Task { [relay, callbackContext] in
            await relay.waitForPublicationDrain(source: callbackContext)
        }
        let terminal = try await finish()
        guard let drain = await drainTask.value,
              relay.accepts(drain, source: callbackContext) else {
            throw SegmentedFMP4WriterFailure.systemFailure
        }
        return try withLane {
            guard terminal == storedTerminalReceipt,
                  terminal.terminalReason == .finished,
                  rolloverPending,
                  !windowContinuationIssued else {
                throw SegmentedFMP4WriterFailure.illegalState
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
            windowContinuationIssued = true
            return WriterWindowContinuation(
                predecessorTerminal: terminal,
                trackKind: trackKind,
                frozenFormat: frozenFormat,
                cadence: cadence)
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
        var mustJoinRegisteredCleanup = false
        let result: (
            SegmentedFMP4WriterTerminalReceipt,
            CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
        )? = withLane {
            if let storedTerminalReceipt { return (storedTerminalReceipt, nil) }
            if state == .retiring {
                mustJoinRegisteredCleanup = true
                return nil
            }
            systemWriter.cancelWriting()
            let continuation = finishContinuation
            finishContinuation = nil
            return (signTerminalIsolated(.cancelled), continuation)
        }
        if mustJoinRegisteredCleanup {
            cleanupGroup.wait()
            return withLane { storedTerminalReceipt! }
        }
        guard let result else { preconditionFailure("缺失 writer 终态") }
        result.1?.resume(throwing: SegmentedFMP4WriterFailure.illegalState)
        relay.notifyPublicationDrainIfReady()
        return result.0
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
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(SegmentedFMP4WriterFailure.systemFailure)
                return
            }
            let kind: SealedMediaObjectKind
            switch type {
            case .initialization: kind = .initialization
            case .separable: kind = .media
            @unknown default:
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(SegmentedFMP4WriterFailure.systemFailure)
                return
            }
            guard let index = pendingCallbacks.firstIndex(where: { $0.kind == kind }) else {
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(SegmentedFMP4WriterFailure.systemFailure)
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
                    cancelSystemWriter = true
                    continuation = beginFailureRetirementIsolated()
                    continuationResult = .failure(SegmentedFMP4WriterFailure.systemFailure)
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
                        acceptance: acceptance
                    )
                    guard schedulePublicationIsolated(acceptance) else {
                        throw SegmentedFMP4WriterFailure.systemFailure
                    }
                } catch {
                    cancelSystemWriter = true
                    continuation = beginFailureRetirementIsolated()
                    continuationResult = .failure(error)
                    return
                }
            case .discarded, .fatal:
                cancelSystemWriter = true
                continuation = beginFailureRetirementIsolated()
                continuationResult = .failure(SegmentedFMP4WriterFailure.systemFailure)
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
                ?? .failure(SegmentedFMP4WriterFailure.systemFailure))
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
        let snapshot = try makeAACSnapshot(epoch)
        guard let terminal = storedTerminalReceipt,
              terminal.terminalReason == .finished,
              let frozen = aacSnapshot,
              frozen.epochIdentity == snapshot.epochIdentity,
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
            throw SegmentedFMP4WriterFailure.systemFailure
        }
        guard retainedTerminalOwnerships.count < ownershipLimits.hardCapacity,
              ticket.prepare(
            binding: binding,
            trackKind: trackKind,
            sampleIdentity: sampleIdentity,
            session: boundarySession
        ) else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        retainedTerminalOwnerships.append(ownership)
        guard appendAndCommitIsolated(sampleBuffer, ticket: ticket, sampleIdentity: sampleIdentity) else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.systemFailure
        }
        try recordAppendIsolated(sampleBuffer, ticket: ticket)
    }

    /// remux 的所有可恢复准入必须发生在一次性 payload claim 之前。
    private func preflightRemuxAdmissionIsolated(
        _ attempt: HLSVideoRemuxWriterAttempt,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity
    ) throws -> AppendPreflightAdmission {
        let charge = attempt.remuxPayloadByteCount.addingReportingOverflow(
            Self.sampleChargeOverhead
        )
        guard !charge.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        return try preflightAppendCoreIsolated(
            facts: AppendPreflightFacts(
                formatDescription: attempt.formatDescription,
                duration: attempt.duration,
                presentationTimeStamp: attempt.presentationTimeStamp,
                decodeTimeStamp: attempt.decodeTimeStamp
                    ?? attempt.presentationTimeStamp,
                projectedCharge: charge.partialValue
            ),
            ticket: ticket,
            sampleIdentity: sampleIdentity,
            readinessFailurePolicy: .recoverable
        )
    }

    private func appendAndCommitIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity
    ) -> Bool {
        guard let authority = AppendSuccessAuthority.append(
            sampleBuffer, using: self, ticket: ticket, sampleIdentity: sampleIdentity
        ) else { return false }
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
        } else if trackKind == .ac3 || trackKind == .eac3,
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

    private func preflightTypedIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity
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
        } else if trackKind == .ac3 || trackKind == .eac3 {
            duration = try ExactMediaTime(CMSampleBufferGetDuration(sampleBuffer))
            presentation = try ExactMediaTime(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            decode = presentation
        } else {
            duration = nil
            presentation = nil
            decode = nil
        }
        return try preflightAppendCoreIsolated(
            facts: AppendPreflightFacts(
                formatDescription: format,
                duration: duration,
                presentationTimeStamp: presentation,
                decodeTimeStamp: decode,
                projectedCharge: try Self.projectedCharge(sampleBuffer)
            ),
            ticket: ticket,
            sampleIdentity: sampleIdentity,
            readinessFailurePolicy: .terminal
        )
    }

    /// sample 与 remux 冻结字段在进入此处前已被各自权威入口转换成同一组只读事实。
    /// 共用规则只维护一份；readiness 的终态策略由调用入口显式选择。
    private func preflightAppendCoreIsolated(
        facts: AppendPreflightFacts,
        ticket: SegmentBoundaryAppendTicket,
        sampleIdentity: SegmentBoundarySampleIdentity,
        readinessFailurePolicy: ReadinessFailurePolicy
    ) throws -> AppendPreflightAdmission {
        guard state == .started else { throw SegmentedFMP4WriterFailure.illegalState }
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
        } else if trackKind == .ac3 || trackKind == .eac3 {
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
        let effectiveRolloverThreshold = trackKind == .aac
            && incrementalAACLiveContext != nil
            ? min(ownershipLimits.rolloverThreshold, 32)
            : ownershipLimits.rolloverThreshold
        if ticket.requiresFlushBeforeAppend,
           retainedTerminalOwnerships.count >= effectiveRolloverThreshold {
            rolloverPending = true
            throw SegmentedFMP4WriterFailure.rolloverRequired
        }
        guard retainedTerminalOwnerships.count < ownershipLimits.hardCapacity else {
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
        guard systemWriter.isReadyForMoreMediaData else {
            if readinessFailurePolicy == .terminal {
                // 已物化 typed sample 的系统 readiness 是运行时失败；remux 则在唯一
                // payload claim 前以 recoverable 策略返回，不取消仍可继续的 writer。
                systemWriter.cancelWriting()
                _ = signTerminalIsolated(.failed)
            }
            throw SegmentedFMP4WriterFailure.notReady
        }
        var flushTicket: SegmentCallbackTicket?
        if ticket.requiresFlushBeforeAppend, currentSegmentInputCount > 0 {
            guard mediaPendingCallbackCount < Self.pendingCallbackCapacity else {
                throw SegmentedFMP4WriterFailure.illegalState
            }
            flushTicket = try relay.reserve(
                kind: .media,
                logicalSequence: ticket.logicalSequence - 1,
                projectedByteCount: currentSegmentProjectedBytes
            )
        }
        return AppendPreflightAdmission(flushTicket: flushTicket)
    }

    private func flushIfRequiredIsolated(
        _ ticket: SegmentBoundaryAppendTicket,
        admission: inout AppendPreflightAdmission
    ) throws {
        guard ticket.requiresFlushBeforeAppend else { return }
        // rollover 后的新 writer 会从全局非零序号开始；它没有本地旧段可 flush。
        guard currentSegmentInputCount > 0 else { return }
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
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.systemFailure
        }
        currentSegmentProjectedBytes = 0
        currentSegmentInputCount = 0
        currentPublicationBoundary = nil
        currentFrameDuration = nil
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
        preview: [SegmentBoundaryInspection]
    ) throws {
        guard state == .started else { throw SegmentedFMP4WriterFailure.illegalState }
        guard !rolloverPending, buffers.count == preview.count else {
            throw SegmentedFMP4WriterFailure.rolloverRequired
        }
        let totalOwnerships = retainedTerminalOwnerships.count.addingReportingOverflow(buffers.count)
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
                if retainedTerminalOwnerships.count + index >= ownershipLimits.rolloverThreshold {
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
        guard systemWriter.isReadyForMoreMediaData else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.notReady
        }
    }

    private func recordAppendIsolated(
        _ sampleBuffer: CMSampleBuffer,
        ticket: SegmentBoundaryAppendTicket
    ) throws {
        let charge = try Self.projectedCharge(sampleBuffer)
        let projected = currentSegmentProjectedBytes.addingReportingOverflow(charge)
        let nextInput = inputCount.addingReportingOverflow(1)
        let nextSegmentInput = currentSegmentInputCount.addingReportingOverflow(1)
        guard !projected.overflow, !nextInput.overflow, !nextSegmentInput.overflow else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        currentSegmentProjectedBytes = projected.partialValue
        inputCount = nextInput.partialValue
        currentSegmentInputCount = nextSegmentInput.partialValue
        lastLogicalSequence = ticket.logicalSequence
    }

    private func failRecordAppendIfRequestedIsolated() throws {
        let nextOrdinal = inputCount.addingReportingOverflow(1)
        guard !nextOrdinal.overflow else {
            throw SegmentedFMP4WriterFailure.arithmeticOverflow
        }
        guard recordAppendFailureOrdinal != nextOrdinal.partialValue else {
            systemWriter.cancelWriting()
            _ = signTerminalIsolated(.failed)
            throw SegmentedFMP4WriterFailure.systemFailure
        }
    }

    private func finishSystemDidComplete(_ succeeded: Bool) {
        var continuation: CheckedContinuation<SegmentedFMP4WriterTerminalReceipt, Error>?
        var result: Result<SegmentedFMP4WriterTerminalReceipt, Error>?
        var requiresCleanup = false
        withLane {
            guard state == .finishing else { return }
            guard succeeded else {
                requiresCleanup = true
                continuation = beginFailureRetirementIsolated()
                result = .failure(SegmentedFMP4WriterFailure.systemFailure)
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
                ?? .failure(SegmentedFMP4WriterFailure.systemFailure))
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
        acceptance: SegmentCallbackAcceptance
    ) throws {
        let byteRange = AudioServiceByteRange(offset: 0, length: bytes.count)
        let digest = Data(SHA256.hash(data: bytes))
        guard acceptance.reportIdentity == report.identity,
              acceptance.byteRange == byteRange,
              acceptance.digest == digest else {
            throw SegmentedFMP4WriterFailure.systemFailure
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
        switch kind {
        case .initialization:
            let next = initializationCallbackCount.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            initializationCallbackCount = next.partialValue
            initializationBackingIdentity = acceptance.backingIdentity
            if trackKind == .aac {
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
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                aacWriterWindowAdmission?.recordInitialization(object)
            }
        case .media:
            let next = mediaCallbackCount.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            mediaCallbackCount = next.partialValue
            if trackKind == .aac {
                guard let leaf = acceptance.aacMediaMembershipLeaf else {
                    throw SegmentedFMP4WriterFailure.systemFailure
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
                guard aacRenditionTerminalBinding?.acceptCallback(
                    leaf, evidence: object) == true else {
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                if firstAACMediaEvidence == nil { firstAACMediaEvidence = object }
                terminalAACMediaEvidence = object
            }
            if trackKind == .aac,
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
        if reason != .finished { aacTerminalBinding?.fail(reason) }
        if ownsPublicationSource { relay.closePublications() }
        let tickets = pendingCallbacks.map(\.ticket)
        let releases = retainedTerminalOwnerships
        retainedTerminalOwnerships.removeAll(keepingCapacity: true)
        pendingCallbacks.removeAll(keepingCapacity: true)
        tickets.forEach { relay.discard($0) }
        releases.forEach { $0.release() }
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
        cleanupQueue.async { [self] in
            systemWriter?.cancelWriting()
            withLane {
                guard state == .retiring else { return }
                _ = signTerminalIsolated(.failed)
            }
            if let continuation {
                resumeAfterPublications(continuation, with: result)
            }
            cleanupGroup.leave()
        }
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
        guard !epoch.buffers.isEmpty,
              // 一个完整 encoder epoch 可以跨多个 segment；128 是单 segment
              // 的证据上限，epoch 总输入仍由本 writer 的 ownership hard cap 封顶。
              epoch.buffers.count <= ownershipLimits.hardCapacity else {
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
        guard !combinedInputCount.overflow,
              !combinedReal.overflow,
              !combinedTotal.overflow,
              combinedInputCount.partialValue <= ownershipLimits.hardCapacity else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
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

    private func makeCompressedSampleBuffer(
        _ accessUnit: CompressedAudioAccessUnit
    ) throws -> CMSampleBuffer {
        let payload = accessUnit.payload
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { throw SegmentedFMP4WriterFailure.systemFailure }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copied == noErr else { throw SegmentedFMP4WriterFailure.systemFailure }
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: Int64(accessUnit.sampleCount),
                timescale: accessUnit.sampleRate
            ),
            presentationTimeStamp: accessUnit.presentationStart,
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: sourceFormatHint,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { throw SegmentedFMP4WriterFailure.systemFailure }
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
            throw SegmentedFMP4WriterFailure.systemFailure
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
