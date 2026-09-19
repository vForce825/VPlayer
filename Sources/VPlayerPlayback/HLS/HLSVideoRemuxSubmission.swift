// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum HLSVideoRemuxSubmissionFailure: Error, Sendable, Equatable {
    case missingSourceEvidence
    case sourceMismatch
    case timelineMismatch
    case formatMismatch
    case syncAttachmentMismatch
    case invalidAnnexB
    case allocationRejected
    case sampleMaterializationFailed(OSStatus)
    case writerAttemptMismatch
}

enum HLSVideoRemuxConversion: UInt8, Sendable, Hashable {
    case strippedInBandParameterSets
    case preservedInBandParameterSets
}

extension HLSVideoSampleEntry {
    var fourCharacterCode: FourCharCode {
        switch self {
        case .avc1: 0x6176_6331
        case .avc3: 0x6176_6333
        case .hvc1: 0x6876_6331
        case .hev1: 0x6865_7631
        }
    }

    var remuxCodec: VideoCodec {
        switch self {
        case .avc1, .avc3: .h264
        case .hvc1, .hev1: .hevc
        }
    }
}

private final class HLSVideoRemuxApplicationLease: @unchecked Sendable {
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let reservation: PlaybackApplicationChargeReservation

    init(bytes: Int, ledger: HLSDeliveryApplicationChargeLedger) throws {
        self.ledger = ledger
        do {
            reservation = try ledger.reserve(allocationIdentity: UUID(), bytes: bytes)
        } catch {
            throw HLSVideoRemuxSubmissionFailure.allocationRejected
        }
    }

    deinit { ledger.release(reservation) }
}

private final class HLSVideoRemuxFormatAuthority: @unchecked Sendable {
    let timelineAuthority: HLSTimedVideoAccessUnitAuthority
    let generation: MediaGeneration
    let sampleEntry: HLSVideoSampleEntry
    let parameterSetIdentity: VideoAccessUnitSHA256
    let formatIdentity: VideoAccessUnitSHA256
    let formatDescription: CMFormatDescription
    let parameterSets: [Data]
    private let lease: HLSVideoRemuxApplicationLease

    init(
        timelineAuthority: HLSTimedVideoAccessUnitAuthority,
        generation: MediaGeneration,
        sampleEntry: HLSVideoSampleEntry,
        parameterSetIdentity: VideoAccessUnitSHA256,
        formatIdentity: VideoAccessUnitSHA256,
        formatDescription: CMFormatDescription,
        parameterSets: [Data],
        lease: HLSVideoRemuxApplicationLease
    ) {
        self.timelineAuthority = timelineAuthority
        self.generation = generation
        self.sampleEntry = sampleEntry
        self.parameterSetIdentity = parameterSetIdentity
        self.formatIdentity = formatIdentity
        self.formatDescription = formatDescription
        self.parameterSets = parameterSets
        self.lease = lease
    }
}

final class HLSVideoRemuxSubmission: @unchecked Sendable {
    let admission: VideoRemuxAdmissionProof
    let writerBinding: FMP4WriterBinding
    let formatDescription: CMFormatDescription
    let sourceBacking: VideoAccessUnitBacking
    let sourceByteRange: VideoAccessUnitByteRange
    let sourceSHA256: VideoAccessUnitSHA256
    let outputSHA256: VideoAccessUnitSHA256
    let outputContainsParameterSets: Bool
    let conversion: HLSVideoRemuxConversion
    let presentationTimeStamp: ExactMediaTime
    let decodeTimeStamp: ExactMediaTime?
    let duration: ExactMediaTime
    let isIDR: Bool
    fileprivate let formatAuthority: HLSVideoRemuxFormatAuthority
    private let lock = NSLock()
    private let output: Data
    private enum AttemptState {
        case available(previous: FMP4WriterBinding)
        case claimed(identity: UUID, binding: FMP4WriterBinding,
                     lease: HLSVideoRemuxApplicationLease)
        case materialized(identity: UUID, binding: FMP4WriterBinding,
                          lease: HLSVideoRemuxApplicationLease)
    }
    private var attemptState: AttemptState
    private weak var canonicalAttempt: HLSVideoRemuxWriterAttempt?
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private let outputLease: HLSVideoRemuxApplicationLease

    fileprivate init(
        admission: VideoRemuxAdmissionProof,
        writerBinding: FMP4WriterBinding,
        output: Data,
        sourceBacking: VideoAccessUnitBacking,
        sourceByteRange: VideoAccessUnitByteRange,
        sourceSHA256: VideoAccessUnitSHA256,
        outputSHA256: VideoAccessUnitSHA256,
        outputContainsParameterSets: Bool,
        conversion: HLSVideoRemuxConversion,
        presentationTimeStamp: ExactMediaTime,
        decodeTimeStamp: ExactMediaTime?,
        duration: ExactMediaTime,
        isIDR: Bool,
        formatAuthority: HLSVideoRemuxFormatAuthority,
        applicationLedger: HLSDeliveryApplicationChargeLedger,
        outputLease: HLSVideoRemuxApplicationLease
    ) {
        self.admission = admission
        self.writerBinding = writerBinding
        self.output = output
        formatDescription = formatAuthority.formatDescription
        self.sourceBacking = sourceBacking
        self.sourceByteRange = sourceByteRange
        self.sourceSHA256 = sourceSHA256
        self.outputSHA256 = outputSHA256
        self.outputContainsParameterSets = outputContainsParameterSets
        self.conversion = conversion
        self.presentationTimeStamp = presentationTimeStamp
        self.decodeTimeStamp = decodeTimeStamp
        self.duration = duration
        self.isIDR = isIDR
        self.formatAuthority = formatAuthority
        self.applicationLedger = applicationLedger
        self.outputLease = outputLease
        attemptState = .available(previous: writerBinding)
    }

    var remuxFormatAuthorityIdentity: ObjectIdentifier {
        ObjectIdentifier(formatAuthority)
    }

    var remuxFormatAuthorityWitness: AnyObject { formatAuthority }

    var remuxSubmissionIdentity: ObjectIdentifier { ObjectIdentifier(self) }

    var remuxPayloadByteCount: Int { output.count }

    func validatesFrozenIdentity() throws -> Bool {
        let currentSource = try sourceBacking.sha256(in: sourceByteRange)
        return outputSHA256 == VideoAccessUnitSHA256(bytes: output.span)
            && currentSource == sourceSHA256
            && admission.source.identity.matches(
                backing: sourceBacking,
                byteRange: sourceByteRange,
                sourceSHA256: sourceSHA256
            )
            && CMFormatDescriptionGetMediaSubType(formatDescription)
                == admission.sampleEntry.fourCharacterCode
    }

    func claimWriterAttempt(
        binding: FMP4WriterBinding,
        admission: WriterWindowAdmission? = nil
    ) throws -> HLSVideoRemuxWriterAttempt {
        try lock.withLock {
            guard case .available(let previous) = attemptState else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            if let admission {
                guard admission.binding == binding else {
                    throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
                }
            } else {
                guard binding == writerBinding,
                      previous == writerBinding else {
                    throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
                }
            }
            // writer-specific shell and its UUID/reference storage are charged before
            // the shell is allocated. Stale aliases retain the charge until their
            // final reference disappears; repeated resigning therefore remains under
            // the single application hard limit.
            let lease = try HLSVideoRemuxApplicationLease(
                bytes: 4_096, ledger: applicationLedger)
            if let admission,
               !admission.claimRemuxAttempt(from: previous) {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            let identity = UUID()
            attemptState = .claimed(identity: identity, binding: binding, lease: lease)
            let attempt = HLSVideoRemuxWriterAttempt(
                pending: self, writerBinding: binding,
                pendingIdentity: ObjectIdentifier(self), attemptIdentity: identity,
                applicationLease: lease)
            canonicalAttempt = attempt
            return attempt
        }
    }

    func currentWriterAttempt(
        binding: FMP4WriterBinding
    ) throws -> HLSVideoRemuxWriterAttempt {
        try lock.withLock {
            guard case .claimed(let identity, let claimed, let lease) = attemptState,
                  claimed == binding else {
                throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
            }
            if let canonicalAttempt,
               canonicalAttempt.attemptIdentity == identity,
               canonicalAttempt.writerBinding == claimed {
                return canonicalAttempt
            }
            let attempt = HLSVideoRemuxWriterAttempt(
                pending: self, writerBinding: claimed,
                pendingIdentity: ObjectIdentifier(self), attemptIdentity: identity,
                applicationLease: lease)
            canonicalAttempt = attempt
            return attempt
        }
    }

    func materializeForWriter(
        _ authority: HLSVideoRemuxWriterMaterializationAuthority,
        attempt: HLSVideoRemuxWriterAttempt
    ) throws -> CMSampleBuffer {
        try lock.withLock {
            guard attempt.belongs(to: self),
                  authority.binding == attempt.writerBinding,
                  case .claimed(let identity, let binding, let lease) = attemptState,
                  identity == attempt.attemptIdentity,
                  binding == attempt.writerBinding,
                  try validatesFrozenIdentity() else {
                throw HLSVideoRemuxSubmissionFailure.sourceMismatch
            }
            attemptState = .materialized(
                identity: identity, binding: binding, lease: lease)
            return try Self.makeSampleBuffer(
                payload: output,
                format: formatDescription,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: decodeTimeStamp,
                duration: duration,
                isIDR: isIDR
            )
        }
    }

    fileprivate func relinquishAfterAbort(_ attempt: HLSVideoRemuxWriterAttempt) -> Bool {
        lock.withLock {
            guard attempt.belongs(to: self),
                  case .claimed(let identity, let binding, _) = attemptState,
                  identity == attempt.attemptIdentity,
                  binding == attempt.writerBinding else { return false }
            attemptState = .available(previous: binding)
            if canonicalAttempt === attempt { canonicalAttempt = nil }
            return true
        }
    }

    private static func makeSampleBuffer(
        payload: Data,
        format: CMFormatDescription,
        presentationTimeStamp: ExactMediaTime,
        decodeTimeStamp: ExactMediaTime?,
        duration: ExactMediaTime,
        isIDR: Bool
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw HLSVideoRemuxSubmissionFailure.sampleMaterializationFailed(status)
        }
        status = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard status == noErr else {
            throw HLSVideoRemuxSubmissionFailure.sampleMaterializationFailed(status)
        }
        var timing = CMSampleTimingInfo(
            duration: duration.cmTime,
            presentationTimeStamp: presentationTimeStamp.cmTime,
            decodeTimeStamp: decodeTimeStamp?.cmTime ?? .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw HLSVideoRemuxSubmissionFailure.sampleMaterializationFailed(status)
        }
        if !isIDR,
           let raw = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let first = (raw as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_NotSync] = true
        }
        return sample
    }
}

/// Immutable writer-specific shell around one stable pending access unit.
final class HLSVideoRemuxWriterAttempt: @unchecked Sendable {
    let writerBinding: FMP4WriterBinding
    let pendingIdentity: ObjectIdentifier
    let attemptIdentity: UUID
    let pending: HLSVideoRemuxSubmission
    private let applicationLease: HLSVideoRemuxApplicationLease

    fileprivate init(pending: HLSVideoRemuxSubmission,
                     writerBinding: FMP4WriterBinding,
                     pendingIdentity: ObjectIdentifier,
                     attemptIdentity: UUID,
                     applicationLease: HLSVideoRemuxApplicationLease) {
        self.pending = pending
        self.writerBinding = writerBinding
        self.pendingIdentity = pendingIdentity
        self.attemptIdentity = attemptIdentity
        self.applicationLease = applicationLease
    }

    fileprivate func belongs(to pending: HLSVideoRemuxSubmission) -> Bool {
        self.pending === pending && pendingIdentity == ObjectIdentifier(pending)
    }

    var formatDescription: CMFormatDescription { pending.formatDescription }
    var presentationTimeStamp: ExactMediaTime { pending.presentationTimeStamp }
    var decodeTimeStamp: ExactMediaTime? { pending.decodeTimeStamp }
    var duration: ExactMediaTime { pending.duration }
    var isIDR: Bool { pending.isIDR }
    var outputSHA256: VideoAccessUnitSHA256 { pending.outputSHA256 }
    var remuxPayloadByteCount: Int { pending.remuxPayloadByteCount }
    var remuxFormatAuthorityIdentity: ObjectIdentifier {
        pending.remuxFormatAuthorityIdentity
    }
    var remuxFormatAuthorityWitness: AnyObject { pending.remuxFormatAuthorityWitness }
    var admission: VideoRemuxAdmissionProof { pending.admission }

    func validatesFrozenIdentity() throws -> Bool {
        try pending.validatesFrozenIdentity()
    }

    func materializeForWriter(
        _ authority: HLSVideoRemuxWriterMaterializationAuthority
    ) throws -> CMSampleBuffer {
        try pending.materializeForWriter(authority, attempt: self)
    }

    @discardableResult
    func relinquishAfterAbort() -> Bool {
        pending.relinquishAfterAbort(self)
    }
}

final class HLSVideoRemuxSubmissionBuilder: @unchecked Sendable {
    let writerBinding: FMP4WriterBinding
    let formatDescription: CMFormatDescription
    private let authority: HLSVideoRemuxFormatAuthority
    private let ledger: HLSDeliveryApplicationChargeLedger

    init(
        resuming predecessor: HLSVideoRemuxSubmissionBuilder,
        binding: FMP4WriterBinding,
        admission: WriterWindowAdmission
    ) throws {
        guard admission.binding == binding,
              admission.claimRemuxBuilder(from: predecessor.writerBinding) else {
            throw HLSVideoRemuxSubmissionFailure.writerAttemptMismatch
        }
        writerBinding = binding
        formatDescription = predecessor.formatDescription
        authority = predecessor.authority
        ledger = predecessor.ledger
    }

    init(
        reference: HLSTimedVideoAccessUnit,
        admission: VideoRemuxAdmissionProof,
        writerBinding: FMP4WriterBinding,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared
    ) throws {
        guard let backing = reference.source.sourceBacking,
              let range = reference.source.sourceByteRange else {
            throw HLSVideoRemuxSubmissionFailure.missingSourceEvidence
        }
        guard reference.validatesRemuxSource(
            admission: admission, backing: backing, byteRange: range
        ) else {
            throw HLSVideoRemuxSubmissionFailure.sourceMismatch
        }
        guard admission.sampleEntry.remuxCodec == admission.source.codec,
              admission.source.containsInBandParameterSets else {
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        let measured = try Self.measure(
            backing: backing, range: range, codec: admission.source.codec,
            includeParameterSets: true
        )
        // 参数 Data、NSData bridge 与 CMFormatDescription 内部配置拷贝可同时存活。
        let parameterPeak = measured.parameterSetBytes.multipliedReportingOverflow(by: 3)
        let charge = parameterPeak.partialValue.addingReportingOverflow(4_096)
        guard !parameterPeak.overflow, !charge.overflow else {
            throw HLSVideoRemuxSubmissionFailure.allocationRejected
        }
        let formatLease = try HLSVideoRemuxApplicationLease(
            bytes: charge.partialValue, ledger: applicationLedger
        )
        let collectedParameterSets = try Self.collectParameterSets(
            backing: backing, range: range, codec: admission.source.codec
        )
        let parameterSets = try Self.canonicalParameterSets(
            collectedParameterSets, admission: admission
        )
        let format = try Self.makeFormatDescription(
            parameterSets: parameterSets,
            admission: admission
        )
        self.writerBinding = writerBinding
        formatDescription = format
        ledger = applicationLedger
        authority = HLSVideoRemuxFormatAuthority(
            timelineAuthority: reference.remuxTimelineAuthority,
            generation: admission.generation,
            sampleEntry: admission.sampleEntry,
            parameterSetIdentity: admission.parameterSetIdentity,
            formatIdentity: admission.formatIdentity,
            formatDescription: format,
            parameterSets: parameterSets,
            lease: formatLease
        )
    }

    func makeSubmission(
        for timed: HLSTimedVideoAccessUnit,
        admission: VideoRemuxAdmissionProof
    ) throws -> HLSVideoRemuxSubmission {
        guard admission.generation == authority.generation,
              admission.sampleEntry == authority.sampleEntry,
              admission.parameterSetIdentity == authority.parameterSetIdentity,
              admission.formatIdentity == authority.formatIdentity else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("fail_sub_gen_\(admission.generation == authority.generation)_entry_\(admission.sampleEntry == authority.sampleEntry)_ps_\(admission.parameterSetIdentity == authority.parameterSetIdentity)_fmt_\(admission.formatIdentity == authority.formatIdentity)")
            #endif
            throw HLSVideoRemuxSubmissionFailure.formatMismatch
        }
        guard timed.remuxTimelineAuthority === authority.timelineAuthority else {
            throw HLSVideoRemuxSubmissionFailure.timelineMismatch
        }
        guard let backing = timed.source.sourceBacking,
              let range = timed.source.sourceByteRange,
              let sourceSHA256 = timed.source.sourceSHA256 else {
            throw HLSVideoRemuxSubmissionFailure.missingSourceEvidence
        }
        guard timed.validatesRemuxSource(
            admission: admission, backing: backing, byteRange: range
        ) else {
            throw HLSVideoRemuxSubmissionFailure.sourceMismatch
        }
        let isIDR = admission.source.randomAccessKind == .h264IDR
            || admission.source.randomAccessKind == .hevcIDR
        let sourceIsSync = Self.isSync(timed.source.sampleBuffer)
        guard sourceIsSync == isIDR else {
            throw HLSVideoRemuxSubmissionFailure.syncAttachmentMismatch
        }
        let preserve = admission.parameterSetDisposition == .preserveInBand
        let measured = try Self.measure(
            backing: backing,
            range: range,
            codec: admission.source.codec,
            includeParameterSets: preserve
        )
        guard measured.containsParameterSets == admission.sourceContainsInBandParameterSets else {
            throw HLSVideoRemuxSubmissionFailure.sourceMismatch
        }
        // 构造容量、冻结 Data 与 writer 的 CMBlockBuffer 在峰值可同时存在。
        let payloadPeak = measured.outputBytes.multipliedReportingOverflow(by: 3)
        let charge = payloadPeak.partialValue.addingReportingOverflow(512)
        guard !payloadPeak.overflow, !charge.overflow else {
            throw HLSVideoRemuxSubmissionFailure.allocationRejected
        }
        let outputLease = try HLSVideoRemuxApplicationLease(
            bytes: charge.partialValue, ledger: ledger
        )
        let output = try Self.materialize(
            backing: backing,
            range: range,
            codec: admission.source.codec,
            includeParameterSets: preserve,
            expectedByteCount: measured.outputBytes
        )
        return HLSVideoRemuxSubmission(
            admission: admission,
            writerBinding: writerBinding,
            output: output,
            sourceBacking: backing,
            sourceByteRange: range,
            sourceSHA256: sourceSHA256,
            outputSHA256: VideoAccessUnitSHA256(bytes: output.span),
            outputContainsParameterSets: preserve && measured.containsParameterSets,
            conversion: preserve ? .preservedInBandParameterSets : .strippedInBandParameterSets,
            presentationTimeStamp: timed.timing.presentationTimeStamp,
            decodeTimeStamp: timed.timing.decodeTimeStamp,
            duration: timed.timing.duration!,
            isIDR: isIDR,
            formatAuthority: authority,
            applicationLedger: ledger,
            outputLease: outputLease
        )
    }

    private struct Measurement {
        var outputBytes = 0
        var parameterSetBytes = 0
        var containsParameterSets = false
    }

    private static func measure(
        backing: VideoAccessUnitBacking,
        range: VideoAccessUnitByteRange,
        codec: VideoCodec,
        includeParameterSets: Bool
    ) throws -> Measurement {
        var result = Measurement()
        do {
            try AnnexBScanner.visitNALUnits(in: backing, range: range, codec: codec) { view, bytes in
                if view.isParameterSet {
                    result.containsParameterSets = true
                    let total = result.parameterSetBytes.addingReportingOverflow(bytes.count)
                    guard !total.overflow else { throw HLSVideoRemuxSubmissionFailure.invalidAnnexB }
                    result.parameterSetBytes = total.partialValue
                    if !includeParameterSets { return }
                }
                let framed = bytes.count.addingReportingOverflow(4)
                let total = result.outputBytes.addingReportingOverflow(framed.partialValue)
                guard !framed.overflow, !total.overflow,
                      total.partialValue <= AnnexBScanner.maximumAccessUnitBytes else {
                    throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
                }
                result.outputBytes = total.partialValue
            }
        } catch let error as HLSVideoRemuxSubmissionFailure {
            throw error
        } catch {
            throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
        }
        guard result.outputBytes > 0 else { throw HLSVideoRemuxSubmissionFailure.invalidAnnexB }
        return result
    }

    private static func collectParameterSets(
        backing: VideoAccessUnitBacking,
        range: VideoAccessUnitByteRange,
        codec: VideoCodec
    ) throws -> [Data] {
        var result: [Data] = []
        do {
            try AnnexBScanner.visitNALUnits(in: backing, range: range, codec: codec) { view, bytes in
                if view.isParameterSet {
                    result.append(bytes.withUnsafeBytes { rawBytes in Data(rawBytes) })
                }
            }
        } catch {
            throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
        }
        return result
    }

    private static func canonicalParameterSets(
        _ parameterSets: [Data],
        admission: VideoRemuxAdmissionProof
    ) throws -> [Data] {
        let expected = admission.source.parameterSets
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for bytes in parameterSets {
            guard let first = bytes.first else {
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            let type: UInt8
            switch admission.source.codec {
            case .h264: type = first & 0x1F
            case .hevc: type = (first >> 1) & 0x3F
            }
            let digest = VideoAccessUnitSHA256(bytes: bytes.span)
            switch (admission.source.codec, type) {
            case (.h264, 7), (.hevc, 33):
                guard digest == expected.spsSHA256 else {
                    throw HLSVideoRemuxSubmissionFailure.formatMismatch
                }
                if sps == nil { sps = bytes }
            case (.h264, 8), (.hevc, 34):
                guard digest == expected.ppsSHA256 else {
                    throw HLSVideoRemuxSubmissionFailure.formatMismatch
                }
                if pps == nil { pps = bytes }
            case (.hevc, 32):
                guard digest == expected.vpsSHA256 else {
                    throw HLSVideoRemuxSubmissionFailure.formatMismatch
                }
                if vps == nil { vps = bytes }
            default:
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("fail_canon_type_\(type)")
                #endif
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
        }
        switch admission.source.codec {
        case .h264:
            guard let sps, let pps else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("fail_canon_h264_sps_\(sps != nil)_pps_\(pps != nil)")
                #endif
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            return [sps, pps]
        case .hevc:
            guard let vps, let sps, let pps else {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("fail_canon_hevc_vps_\(vps != nil)_sps_\(sps != nil)_pps_\(pps != nil)")
                #endif
                throw HLSVideoRemuxSubmissionFailure.formatMismatch
            }
            return [vps, sps, pps]
        }
    }

    private static func makeFormatDescription(
        parameterSets: [Data],
        admission: VideoRemuxAdmissionProof
    ) throws -> CMFormatDescription {
        let inspectedExtensions = try formatExtensions(from: admission.source.format)
        let stable = parameterSets.map { $0 as NSData }
        var pointers = stable.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = stable.map(\.length)
        var canonical: CMFormatDescription?
        let status: OSStatus
        switch admission.source.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: stable.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &canonical
            )
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: stable.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: inspectedExtensions,
                formatDescriptionOut: &canonical
            )
        }
        guard status == noErr, let canonical else {
            throw HLSVideoRemuxSubmissionFailure.sampleMaterializationFailed(status)
        }
        let canonicalExtensions = CMFormatDescriptionGetExtensions(canonical)
            ?? ([:] as NSDictionary)
        let merged = NSMutableDictionary(dictionary: canonicalExtensions)
        for (key, value) in inspectedExtensions as NSDictionary {
            merged[key] = value
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(canonical)
        var rebuilt: CMVideoFormatDescription?
        let rebuild = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: admission.sampleEntry.fourCharacterCode,
            width: dimensions.width,
            height: dimensions.height,
            extensions: merged,
            formatDescriptionOut: &rebuilt
        )
        guard rebuild == noErr, let rebuilt else {
            throw HLSVideoRemuxSubmissionFailure.sampleMaterializationFailed(rebuild)
        }
        return rebuilt
    }

    private static func formatExtensions(
        from format: VideoAccessUnitFormatSummary
    ) throws -> CFDictionary {
        let result = NSMutableDictionary()
        if let range = format.range {
            result[kCMFormatDescriptionExtension_FullRangeVideo] = range == .full
        }
        if let primaries = format.primaries {
            result[kCMFormatDescriptionExtension_ColorPrimaries] = switch primaries {
            case .bt709: kCVImageBufferColorPrimaries_ITU_R_709_2
            case .bt2020: kCVImageBufferColorPrimaries_ITU_R_2020
            }
        }
        if let transfer = format.transfer {
            result[kCMFormatDescriptionExtension_TransferFunction] = switch transfer {
            case .bt709: kCVImageBufferTransferFunction_ITU_R_709_2
            case .bt2020, .bt2020_12: kCVImageBufferTransferFunction_ITU_R_2020
            case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
            }
        }
        if let matrix = format.matrix {
            result[kCMFormatDescriptionExtension_YCbCrMatrix] = switch matrix {
            case .bt709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case .bt2020Nonconstant: kCVImageBufferYCbCrMatrix_ITU_R_2020
            }
        }
        if let chroma = format.chromaLocation {
            let value: CFString = switch chroma {
            case .left: kCVImageBufferChromaLocation_Left
            case .center: kCVImageBufferChromaLocation_Center
            case .topLeft: kCVImageBufferChromaLocation_TopLeft
            }
            result[kCMFormatDescriptionExtension_ChromaLocationTopField] = value
            result[kCMFormatDescriptionExtension_ChromaLocationBottomField] = value
        }
        if let aspect = format.sampleAspectRatio {
            result[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: aspect.num,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: aspect.den,
            ] as NSDictionary
        }
        if let mastering = format.masteringDisplay {
            result[kCMFormatDescriptionExtension_MasteringDisplayColorVolume]
                = try masteringDisplayBytes(mastering) as NSData
        }
        if let light = format.contentLightLevel {
            var bytes = Data()
            appendBigEndian(light.maximumContentLightLevel, to: &bytes)
            appendBigEndian(light.maximumFrameAverageLightLevel, to: &bytes)
            result[kCMFormatDescriptionExtension_ContentLightLevelInfo] = bytes as NSData
        }
        return result
    }

    private static func masteringDisplayBytes(
        _ value: DemuxMasteringDisplayMetadata
    ) throws -> Data {
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

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func materialize(
        backing: VideoAccessUnitBacking,
        range: VideoAccessUnitByteRange,
        codec: VideoCodec,
        includeParameterSets: Bool,
        expectedByteCount: Int
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedByteCount)
        do {
            try AnnexBScanner.visitNALUnits(in: backing, range: range, codec: codec) { view, bytes in
                if view.isParameterSet && !includeParameterSets { return }
                guard let length = UInt32(exactly: bytes.count) else {
                    throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
                }
                var bigEndian = length.bigEndian
                Swift.withUnsafeBytes(of: &bigEndian) { result.append(contentsOf: $0) }
                bytes.withUnsafeBytes { result.append(contentsOf: $0) }
            }
        } catch let error as HLSVideoRemuxSubmissionFailure {
            throw error
        } catch {
            throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
        }
        guard result.count == expectedByteCount else {
            throw HLSVideoRemuxSubmissionFailure.invalidAnnexB
        }
        return result
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false
        ) else { return true }
        let attachments = raw as NSArray
        guard let first = attachments.firstObject as? NSDictionary else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
