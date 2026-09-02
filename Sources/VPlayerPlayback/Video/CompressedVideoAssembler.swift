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
    private let descriptor: VideoTrackDescriptor
    private var parser: (any FFmpegParserHandle)?
    private var nextID: UInt64?
    private var parameterSets: [Data] = []
    private var formatDescription: CMVideoFormatDescription?
    private var emittedFingerprint: MediaFormatFingerprint?
    private var parserOperationID: AssemblyOperationID?

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (VideoAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding = .standalone(),
        startingID: UInt64 = 1
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
        nextID = startingID
        let operationID = try currentOperationID()
        parserOperationID = operationID
        parser = try makeParser(for: descriptor, operationID: operationID)
        try prepareExtradata(descriptor.extradata)
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
        parser = try makeParser(for: descriptor, operationID: operationID)
        try prepareExtradata(descriptor.extradata)
    }

    private func receive(_ frame: FFmpegParsedFrame) throws {
        let scan = try AnnexBScanner.scan(frame.bytes, codec: descriptor.codec)
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
        let presentationTimeStamp = frame.pts.map(descriptor.timeBase.cmTime) ?? .invalid
        let decodeTimeStamp = frame.dts.map(descriptor.timeBase.cmTime) ?? .invalid
        let isRandomAccess = frame.keyFrame == true
        let sampleBuffer = try SampleBufferBuilder.makeVideo(
            data: scan.lengthPrefixedData,
            formatDescription: formatDescription,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp,
            duration: frame.duration,
            isRandomAccess: isRandomAccess
        )
        let metadata = try makeMetadata(frame, presentationTimeStamp: presentationTimeStamp)
        eventSink(.accessUnit(CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: isRandomAccess,
            parserMetadata: metadata
        )))
    }

    private func prepareExtradata(_ extradata: Data) throws {
        guard !extradata.isEmpty else { return }
        let scan = try AnnexBScanner.scan(extradata, codec: descriptor.codec)
        try updateFormatIfNeeded(with: scan.parameterSets)
    }

    private func updateFormatIfNeeded(with incoming: [Data]) throws {
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
