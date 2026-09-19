// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

final class CompressedVideoAssembler {
    static let invalidInputErrorCode: Int32 = -1_448_143_364
    static let idExhaustedErrorCode: Int32 = -1_448_143_365

    private let generationProvider: () -> MediaGeneration
    private let eventSink: (VideoAssemblerEvent) -> Void
    private let parserFactory: any FFmpegParserFactory
    private let binding: AssemblyEpochBinding
    private let formatState: AssemblyFormatState
    /// 可选 HLS 注入接缝；本轮 RED stub 不改变 legacy sample 构造。
    private let hlsCopyOwnership: HLSVideoCopyOwnership?
    private let descriptor: VideoTrackDescriptor
    private var parser: (any FFmpegParserHandle)?
    private var nextID: UInt64?
    private var parameterSets: [Data] = []
    private var hlsParameterSetOwner: HLSVideoParameterSetRetention?
    private var formatDescription: CMVideoFormatDescription?
    private var emittedFingerprint: MediaFormatFingerprint?
    private var parserOperationID: AssemblyOperationID?
    private var lastEmittedDTS: CMTime?

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (VideoAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding = .standalone(),
        startingID: UInt64 = 1,
        hlsCopyOwnership: HLSVideoCopyOwnership? = nil
    ) throws {
        guard let descriptor = trackSet.video else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        self.descriptor = descriptor
        self.generationProvider = generationProvider
        self.eventSink = eventSink
        self.parserFactory = parserFactory
        self.formatState = formatState
        self.binding = binding
        self.hlsCopyOwnership = hlsCopyOwnership
        nextID = startingID
        let operationID = try currentOperationID()
        parserOperationID = operationID
        parser = try makeParser(for: descriptor, operationID: operationID)
        let snapshot = formatState.snapshot()
        if let owner = snapshot.hlsVideoParameterSetOwner {
            hlsParameterSetOwner = owner
            try restoreHLSFormat(from: owner)
        } else if snapshot.videoParameterSets.isEmpty {
            try prepareExtradata(descriptor.extradata)
        } else {
            try restoreFormat(from: snapshot.videoParameterSets)
        }
    }

    deinit {
        parser?.destroy()
    }

    func push(_ packet: DemuxPacket) throws {
        try ensureParserIsCurrent()
        guard packet.streamIndex == descriptor.streamIndex,
              packet.codec == .video(descriptor.codec),
              !packet.data.isEmpty else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        let pts = try exactTicks(packet.presentationTimeStamp, timeBase: descriptor.timeBase)
        let dts = try exactTicks(packet.decodeTimeStamp, timeBase: descriptor.timeBase)
        let duration = try exactDurationTicks(packet.duration, timeBase: descriptor.timeBase)
        try parser?.push(packet.data, pts: pts, dts: dts, duration: duration)
    }

    func drain() throws {
        try ensureParserIsCurrent()
        try parser?.drain()
    }

    private func makeParser(
        for descriptor: VideoTrackDescriptor,
        operationID: AssemblyOperationID
    ) throws -> any FFmpegParserHandle {
        try parserFactory.makeParser(configuration: FFmpegParserConfiguration(video: descriptor)) {
            [weak self] frame in
            guard let self, binding.accepts(operationID) else { return }
            try receive(frame)
        }
    }

    private func currentOperationID() throws -> AssemblyOperationID {
        guard let operationID = binding.currentOperationID() else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        return operationID
    }

    private func ensureParserIsCurrent() throws {
        let operationID = try currentOperationID()
        guard parserOperationID != operationID else { return }
        parser?.destroy()
        parser = nil
        parserOperationID = operationID
        lastEmittedDTS = nil
        parser = try makeParser(for: descriptor, operationID: operationID)
        if hlsCopyOwnership != nil ? hlsParameterSetOwner == nil : parameterSets.isEmpty {
            try prepareExtradata(descriptor.extradata)
        }
    }

    private func receive(_ frame: FFmpegParsedFrame) throws {
        if let hlsCopyOwnership {
            try frame.withBorrowedBytes { bytes in
            let envelope = try AnnexBScanner.measureLengthPrefixedOutput(bytes, codec: descriptor.codec)
                let temporaryLease = try hlsCopyOwnership.acquireScanTemporary(
                    bytes: try scanWorkspaceBytes(envelope)
                )
            defer { temporaryLease.release() }
                let scan = try AnnexBScanner.scan(
                    bytes,
                    codec: descriptor.codec,
                    outputCapacity: envelope.lengthPrefixedBytes,
                    parameterSetCapacity: envelope.parameterSetCount
                )
                try receiveScanned(frame, scan: scan)
            }
            return
        }
        let scan = try frame.withBorrowedBytes { try AnnexBScanner.scan($0, codec: descriptor.codec) }
        try receiveScanned(frame, scan: scan)
    }

    /// HLS 的 scan 结果在 format/fingerprint/CM block copy 全部结束前仍然活着。
    /// 费用包含 length-prefixed Data、独立参数 Data 与参数数组的实际元素槽位。
    private func receiveScanned(_ frame: FFmpegParsedFrame, scan: AnnexBScanResult) throws {
        try updateFormatIfNeeded(with: scan.parameterSets)
        guard let formatDescription else {
            return
        }

        let fingerprint: MediaFormatFingerprint
        do {
            fingerprint = try formatState.fingerprint()
        } catch {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        if fingerprint != emittedFingerprint {
            eventSink(.format(formatDescription, fingerprint))
            emittedFingerprint = fingerprint
        }
        let generation = generationProvider()
        let id = try takeNextID()
        let sourceBacking = try frame.makeVideoBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: generation,
                accessUnitID: id
            )
        )
        var presentationTimeStamp = frame.pts.map(descriptor.timeBase.cmTime) ?? .invalid
        let rawDTS = frame.dts.map(descriptor.timeBase.cmTime) ?? .invalid
        let sampleDuration = resolvedDuration(frame.duration)
        var decodeTimeStamp: CMTime = .invalid

        if rawDTS.isValid && rawDTS.isNumeric {
            if let prev = lastEmittedDTS, CMTimeCompare(rawDTS, prev) <= 0 {
                let step = (sampleDuration.isValid && sampleDuration.isNumeric && sampleDuration.value > 0)
                    ? sampleDuration
                    : CMTime(value: 1, timescale: descriptor.timeBase.den)
                decodeTimeStamp = CMTimeAdd(prev, step)
            } else {
                decodeTimeStamp = rawDTS
            }
            lastEmittedDTS = decodeTimeStamp
        } else if let prev = lastEmittedDTS {
            let step = (sampleDuration.isValid && sampleDuration.isNumeric && sampleDuration.value > 0)
                ? sampleDuration
                : CMTime(value: 1, timescale: descriptor.timeBase.den)
            decodeTimeStamp = CMTimeAdd(prev, step)
            lastEmittedDTS = decodeTimeStamp
        } else if presentationTimeStamp.isValid && presentationTimeStamp.isNumeric {
            if descriptor.videoDelay > 0,
               sampleDuration.isValid, sampleDuration.isNumeric, sampleDuration.value > 0 {
                let delay = CMTimeMultiply(sampleDuration, multiplier: descriptor.videoDelay)
                decodeTimeStamp = CMTimeSubtract(presentationTimeStamp, delay)
            } else {
                decodeTimeStamp = presentationTimeStamp
            }
            lastEmittedDTS = decodeTimeStamp
        }

        if presentationTimeStamp.isValid, presentationTimeStamp.isNumeric,
           decodeTimeStamp.isValid, decodeTimeStamp.isNumeric,
           CMTimeCompare(presentationTimeStamp, decodeTimeStamp) < 0 {
            presentationTimeStamp = decodeTimeStamp
        }
        let isRandomAccess = frame.keyFrame == true
        let sampleBuffer: CMSampleBuffer
        if let hlsCopyOwnership {
            sampleBuffer = try SampleBufferBuilder.makeHLSOwnedVideo(
                data: scan.lengthPrefixedData,
                formatDescription: formatDescription,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: decodeTimeStamp,
                duration: sampleDuration,
                isRandomAccess: isRandomAccess,
                ownership: hlsCopyOwnership
            )
        } else {
            sampleBuffer = try SampleBufferBuilder.makeVideo(
                data: scan.lengthPrefixedData,
                formatDescription: formatDescription,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: decodeTimeStamp,
                duration: sampleDuration,
                isRandomAccess: isRandomAccess
            )
        }
        let metadata = try makeMetadata(frame, presentationTimeStamp: presentationTimeStamp)
        eventSink(.accessUnit(try CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: isRandomAccess,
            randomAccessKind: scan.randomAccessKind,
            scanClassification: frame.interlaced.map { $0 ? .interlaced : .progressive }
                ?? .unresolved,
            parserMetadata: metadata,
            sourceBacking: sourceBacking,
            sourceByteRange: sourceBacking.wholeRange
        )))
    }

    /// H.264/HEVC parser 未必能从 access unit 语法恢复 duration；此时使用 demux 已冻结的
    /// CFR track rate，避免把无 duration 的压缩样本送进 HLS remux/boundary。
    private func resolvedDuration(_ parserDuration: CMTime) -> CMTime {
        if parserDuration.isNumeric, parserDuration.value > 0 { return parserDuration }
        guard let frameRate = descriptor.frameRate else { return parserDuration }
        return CMTime(value: Int64(frameRate.den), timescale: frameRate.num)
    }

    private func prepareExtradata(_ extradata: Data) throws {
        guard !extradata.isEmpty else { return }
        if let hlsCopyOwnership {
            let bytes = extradata.span
            let envelope = try AnnexBScanner.measureLengthPrefixedOutput(bytes, codec: descriptor.codec)
            let temporaryLease = try hlsCopyOwnership.acquireScanTemporary(
                bytes: try scanWorkspaceBytes(envelope)
            )
            defer { temporaryLease.release() }
            let scan = try AnnexBScanner.scan(
                bytes,
                codec: descriptor.codec,
                outputCapacity: envelope.lengthPrefixedBytes,
                parameterSetCapacity: envelope.parameterSetCount
            )
            try updateFormatIfNeeded(with: scan.parameterSets)
            return
        }
        let scan = try AnnexBScanner.scan(extradata, codec: descriptor.codec)
        try updateFormatIfNeeded(with: scan.parameterSets)
    }

    private func scanWorkspaceBytes(
        _ envelope: (lengthPrefixedBytes: Int, parameterSetBytes: Int, parameterSetCount: Int)
    ) throws -> Int {
        let parameterSlots = envelope.parameterSetCount.multipliedReportingOverflow(
            by: MemoryLayout<Data>.stride
        )
        let payloadAndParameters = envelope.lengthPrefixedBytes.addingReportingOverflow(
            envelope.parameterSetBytes
        )
        let total = payloadAndParameters.partialValue.addingReportingOverflow(parameterSlots.partialValue)
        guard !parameterSlots.overflow, !payloadAndParameters.overflow, !total.overflow,
              total.partialValue > 0 else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        return total.partialValue
    }

    private func restoreFormat(from inheritedParameterSets: [Data]) throws {
        guard hasRequiredParameterSets(inheritedParameterSets) else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        parameterSets = inheritedParameterSets
        formatDescription = try VideoFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            parameterSets: inheritedParameterSets
        )
    }

    private func restoreHLSFormat(from owner: HLSVideoParameterSetRetention) throws {
        guard hasRequiredParameterSets(owner.entries) else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        formatDescription = try VideoFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            parameterSetOwner: owner
        )
    }

    private func updateFormatIfNeeded(with incoming: [Data]) throws {
        if hlsCopyOwnership != nil {
            try updateHLSFormatIfNeeded(with: incoming)
            return
        }
        let candidate = mergedParameterSets(incoming)
        guard candidate != parameterSets || formatDescription == nil else { return }
        guard hasRequiredParameterSets(candidate) else {
            return
        }
        let candidateDescription = try VideoFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            parameterSets: candidate
        )
        parameterSets = candidate
        formatDescription = candidateDescription
        formatState.commitVideoParameterSets(candidate)
    }

    private func updateHLSFormatIfNeeded(with incoming: [Data]) throws {
        guard let hlsCopyOwnership else { return }
        // 无新参数集时绝不制造 candidate/owner；旧 snapshot 可能正在外部持有，
        // 这条普通帧路径必须直接复用它而不是等待 owner metadata 容量。
        guard !incoming.isEmpty else { return }
        if let owner = hlsParameterSetOwner,
           formatDescription != nil,
           incomingLeavesHLSOwnerUnchanged(incoming, owner: owner) {
            return
        }
        let merged = try mergedHLSParameterSetEntries(incoming, ownership: hlsCopyOwnership)
        let candidate = merged.entries
        guard !sameEntries(candidate, hlsParameterSetOwner?.entries ?? []) || formatDescription == nil else {
            return
        }
        guard hasRequiredParameterSets(candidate) else { return }
        let owner = hlsCopyOwnership.makeParameterSetOwner(entries: candidate, ownerLease: merged.ownerLease)
        let candidateDescription = try VideoFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            parameterSetOwner: owner
        )
        // HLS 不持有与 owner 平行的裸 Data；旧 snapshot 自己延长旧 owner 的 lease。
        hlsParameterSetOwner = owner
        formatDescription = candidateDescription
        formatState.commitHLSVideoParameterSets(owner)
    }

    private func mergedHLSParameterSetEntries(
        _ incoming: [Data],
        ownership: HLSVideoCopyOwnership
    ) throws -> (entries: [HLSVideoParameterSetRetention.Entry], ownerLease: HLSDataPlaneAdmission.Lease) {
        guard !incoming.isEmpty else { return (hlsParameterSetOwner?.entries ?? [], try ownership.acquireParameterSetOwnerLease(entryCount: hlsParameterSetOwner?.entries.count ?? 0)) }
        let old = hlsParameterSetOwner?.entries ?? []
        var finalCount = 0, finalBytes = 0
        for type in parameterSetOrder() {
            let hasReplacement = incoming.contains { parameterSetType($0) == type }
            if hasReplacement {
                for (index, value) in incoming.enumerated() where parameterSetType(value) == type {
                    guard !incoming[..<index].contains(where: { parameterSetType($0) == type && $0 == value }) else { continue }
                    finalCount += 1; finalBytes += value.count
                }
            } else {
                for entry in old where parameterSetType(entry) == type { finalCount += 1; finalBytes += entry.byteCount }
            }
        }
        guard finalCount <= ownership.maximumParameterSetSnapshotCount,
              finalBytes <= ownership.maximumParameterSetSnapshotBytes else { throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode) }
        let ownerLease = try ownership.acquireParameterSetOwnerLease(entryCount: finalCount)
        let workspaceBytes = ownership.maximumParameterSetSnapshotCount * MemoryLayout<HLSVideoParameterSetRetention.Entry>.stride
        let workspace = try ownership.acquireWorkspace(bytes: workspaceBytes)
        defer { workspace.release() }
        var candidate: [HLSVideoParameterSetRetention.Entry] = []
        candidate.reserveCapacity(finalCount)
        for type in parameterSetOrder() {
            let hasReplacement = incoming.contains { parameterSetType($0) == type }
            if !hasReplacement {
                for entry in old where parameterSetType(entry) == type { candidate.append(entry) }
                continue
            }
            for (index, value) in incoming.enumerated() where parameterSetType(value) == type {
                guard !incoming[..<index].contains(where: { parameterSetType($0) == type && $0 == value }) else { continue }
                if let existing = old.first(where: { parameterSetType($0) == type && $0.matches(value) }),
                   !candidate.contains(where: { $0 === existing }) { candidate.append(existing) }
                else { candidate.append(try ownership.makeParameterSetEntry(value)) }
            }
        }
        return (candidate, ownerLease)
    }

    /// 不分配 Dictionary/Set：incoming 只替换其出现的 type，逐 type 比较其
    /// stable unique 序列与现有 owner。完全相同就绝不能申请 candidate lease。
    private func incomingLeavesHLSOwnerUnchanged(
        _ incoming: [Data], owner: HLSVideoParameterSetRetention
    ) -> Bool {
        let old = owner.entries
        for type in parameterSetOrder() where incoming.contains(where: { parameterSetType($0) == type }) {
            var oldIndex = 0
            for (index, value) in incoming.enumerated() where parameterSetType(value) == type {
                guard !incoming[..<index].contains(where: { parameterSetType($0) == type && $0 == value }) else { continue }
                while oldIndex < old.count && parameterSetType(old[oldIndex]) != type { oldIndex += 1 }
                guard oldIndex < old.count, old[oldIndex].matches(value) else { return false }
                oldIndex += 1
            }
            while oldIndex < old.count {
                if parameterSetType(old[oldIndex]) == type { return false }
                oldIndex += 1
            }
        }
        return true
    }

    private func mergedParameterSets(_ incoming: [Data]) -> [Data] {
        guard !incoming.isEmpty else { return parameterSets }
        var groups = Dictionary(grouping: parameterSets) { parameterSetType($0) }
            .mapValues(exactUniqueParameterSets)
        for (type, values) in Dictionary(grouping: incoming, by: { parameterSetType($0) }) {
            groups[type] = exactUniqueParameterSets(values)
        }
        return parameterSetOrder().flatMap { groups[$0] ?? [] }
    }

    private func exactUniqueParameterSets(_ values: [Data]) -> [Data] {
        var seen = Set<Data>()
        var result: [Data] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func hasRequiredParameterSets(_ values: [Data]) -> Bool {
        let types = Set(values.map(parameterSetType))
        switch descriptor.codec {
        case .h264:
            return types.contains(7) && types.contains(8)
        case .hevc:
            return types.contains(32) && types.contains(33) && types.contains(34)
        }
    }

    private func hasRequiredParameterSets(_ entries: [HLSVideoParameterSetRetention.Entry]) -> Bool {
        let types = Set(entries.map(parameterSetType))
        switch descriptor.codec {
        case .h264: return types.contains(7) && types.contains(8)
        case .hevc: return types.contains(32) && types.contains(33) && types.contains(34)
        }
    }

    private func parameterSetOrder() -> [UInt8] {
        switch descriptor.codec {
        case .h264: return [7, 8, 13]
        case .hevc: return [32, 33, 34]
        }
    }

    private func parameterSetType(_ data: Data) -> UInt8 {
        guard let first = data.first else { return UInt8.max }
        switch descriptor.codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    private func parameterSetType(_ entry: HLSVideoParameterSetRetention.Entry) -> UInt8 {
        entry.withBytes { bytes in
            guard !bytes.isEmpty else { return UInt8.max }
            switch descriptor.codec {
            case .h264: return bytes[0] & 0x1F
            case .hevc: return (bytes[0] >> 1) & 0x3F
            }
        }
    }

    private func sameEntries(
        _ lhs: [HLSVideoParameterSetRetention.Entry],
        _ rhs: [HLSVideoParameterSetRetention.Entry]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    private func takeNextID() throws -> UInt64 {
        guard let id = nextID else {
            throw PlaybackCoreError.videoDecode(Self.idExhaustedErrorCode)
        }
        nextID = id == UInt64.max ? nil : id + 1
        return id
    }

    private func makeMetadata(
        _ frame: FFmpegParsedFrame,
        presentationTimeStamp: CMTime
    ) throws -> VideoParserMetadata {
        guard let rawFieldOrder = UInt8(exactly: frame.fieldOrder),
              let rawPictureStructure = UInt8(exactly: frame.pictureStructure),
              let fieldOrder = CodedFieldOrder(rawValue: rawFieldOrder),
              let pictureStructure = PictureStructure(rawValue: rawPictureStructure) else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        return VideoParserMetadata(
            fieldOrder: fieldOrder,
            pictureStructure: pictureStructure,
            isInterlaced: frame.interlaced,
            repeatFirstField: frame.repeatPicture,
            topFieldFirst: frame.topFieldFirst,
            sourcePTS90k: exactNonnegative90k(presentationTimeStamp)
        )
    }

    private func exactNonnegative90k(_ time: CMTime) -> UInt64? {
        guard time.isNumeric, time.epoch == 0, time.value >= 0, time.timescale > 0 else {
            return nil
        }
        var value = UInt64(time.value)
        var multiplier: UInt64 = 90_000
        var denominator = UInt64(time.timescale)
        let firstGCD = greatestCommonDivisorForAssembly(value, denominator)
        value /= firstGCD
        denominator /= firstGCD
        let secondGCD = greatestCommonDivisorForAssembly(multiplier, denominator)
        multiplier /= secondGCD
        denominator /= secondGCD
        guard denominator == 1 else { return nil }
        let (result, overflowed) = value.multipliedReportingOverflow(by: multiplier)
        return overflowed ? nil : result
    }
}

func exactTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard time.isValid else { return nil }
    guard time.isNumeric, time.epoch == 0, time.timescale > 0 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    let negative = time.value < 0
    var valueMagnitude = time.value.magnitude
    var multiplier = UInt64(timeBase.den)
    var denominator = UInt64(time.timescale) * UInt64(timeBase.num)

    let firstGCD = greatestCommonDivisorForAssembly(valueMagnitude, denominator)
    valueMagnitude /= firstGCD
    denominator /= firstGCD
    let secondGCD = greatestCommonDivisorForAssembly(multiplier, denominator)
    multiplier /= secondGCD
    denominator /= secondGCD
    guard denominator == 1 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    let (magnitude, overflowed) = valueMagnitude.multipliedReportingOverflow(by: multiplier)
    let limit = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
    guard !overflowed, magnitude <= limit else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    if negative {
        if magnitude == UInt64(Int64.max) + 1 {
            throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
        }
        return -Int64(magnitude)
    }
    return Int64(magnitude)
}

func exactDurationTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard let value = try exactTicks(time, timeBase: timeBase) else { return nil }
    guard value >= 0 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    return value
}

func greatestCommonDivisorForAssembly(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 {
        let remainder = first % second
        first = second
        second = remainder
    }
    return first
}
