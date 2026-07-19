// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

final class CompressedAudioAssembler {
    static let invalidInputErrorCode: Int32 = -1_448_208_897
    static let idExhaustedErrorCode: Int32 = -1_448_208_899

    private static let maximumPayloadBytes = 64 * 1_024 * 1_024
    private static let aacSampleRates: [Int32] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
        22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]
    private static let aacChannelCounts: [Int32] = [0, 1, 2, 3, 4, 5, 6, 8]

    private let generationProvider: () -> MediaGeneration
    private let eventSink: (AudioAssemblerEvent) -> Void
    private let parserFactory: any FFmpegParserFactory
    private let formatState: AssemblyFormatState
    private var descriptor: AudioTrackDescriptor
    private var parser: (any FFmpegParserHandle)?
    private var nextID: UInt64?
    private var formatDescription: CMAudioFormatDescription?
    private var currentCookie: Data?
    private var emittedFingerprint: MediaFormatFingerprint?
    private var aacCarry = Data()
    private var aacTimestampProvenance: [ADTSTimestampProvenance] = []

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (AudioAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        startingID: UInt64 = 1
    ) throws {
        guard let descriptor = trackSet.audio else {
            throw PlaybackCoreError.audioFallbackDecode(Self.invalidInputErrorCode)
        }
        self.descriptor = descriptor
        self.generationProvider = generationProvider
        self.eventSink = eventSink
        self.parserFactory = parserFactory
        self.formatState = formatState
        nextID = startingID
        try configure(for: descriptor)
    }

    deinit {
        parser?.destroy()
    }

    func push(_ packet: DemuxPacket) throws {
        guard packet.streamIndex == descriptor.streamIndex,
              packet.codec == .audio(descriptor.codec),
              !packet.data.isEmpty,
              packet.presentationTimeStamp.isNumeric else {
            throw validationError()
        }
        let pts = try audioExactTicks(
            packet.presentationTimeStamp,
            timeBase: descriptor.timeBase
        )
        let presentationTimeStamp = descriptor.timeBase.cmTime(forFFmpegValue: pts)
        guard presentationTimeStamp.isNumeric else { throw validationError() }
        if descriptor.codec == .aac {
            if descriptor.extradata.isEmpty {
                try consumeADTS(packet.data, presentationTimeStamp: presentationTimeStamp)
            } else {
                guard !Self.hasADTSSync(packet.data) else { throw validationError() }
                try emitSample(
                    data: packet.data,
                    presentationTimeStamp: presentationTimeStamp,
                    frameSamples: 1_024
                )
            }
            return
        }
        let dts = try audioOptionalTicks(packet.decodeTimeStamp, timeBase: descriptor.timeBase)
        let duration = try audioOptionalDurationTicks(packet.duration, timeBase: descriptor.timeBase)
        try parser?.push(packet.data, pts: pts, dts: dts, duration: duration)
    }

    func drain() throws {
        if descriptor.codec == .aac {
            guard aacCarry.isEmpty, aacTimestampProvenance.isEmpty else {
                throw validationError()
            }
            return
        }
        try parser?.drain()
    }

    func reset(for trackSet: DemuxTrackSet) throws {
        guard let descriptor = trackSet.audio else { throw validationError() }
        parser?.destroy()
        parser = nil
        self.descriptor = descriptor
        formatState.resetAudio(for: trackSet)
        formatDescription = nil
        currentCookie = nil
        emittedFingerprint = nil
        aacCarry.removeAll(keepingCapacity: false)
        aacTimestampProvenance.removeAll(keepingCapacity: false)
        try configure(for: descriptor)
    }

    private func configure(for descriptor: AudioTrackDescriptor) throws {
        guard descriptor.sampleRate > 0,
              descriptor.channelLayout.channelCount > 0 else {
            throw validationError()
        }
        if descriptor.codec == .aac {
            guard parser == nil else { throw validationError() }
            if !descriptor.extradata.isEmpty {
                let cookie = try validateASC(descriptor.extradata)
                try installFormat(cookie: cookie)
            }
            return
        }
        let built = try AudioFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            sampleRate: descriptor.sampleRate,
            channelLayout: descriptor.channelLayout,
            cookie: nil
        )
        formatDescription = built.description
        formatState.commitAudioCookie(nil)
        parser = try makeParser(for: descriptor)
    }

    private func makeParser(
        for descriptor: AudioTrackDescriptor
    ) throws -> any FFmpegParserHandle {
        try parserFactory.makeParser(configuration: FFmpegParserConfiguration(audio: descriptor)) {
            [weak self] frame in
            guard let self else { return }
            try receive(frame)
        }
    }

    private func receive(_ frame: FFmpegParsedFrame) throws {
        guard descriptor.codec != .aac,
              !frame.bytes.isEmpty,
              frame.bytes.count <= Self.maximumPayloadBytes,
              frame.sampleRate == descriptor.sampleRate,
              frame.channels == descriptor.channelLayout.channelCount,
              let pts = frame.pts else {
            throw validationError()
        }
        if let parserLayout = frame.channelLayout {
            guard parserLayout.channelCount == descriptor.channelLayout.channelCount else {
                throw validationError()
            }
            if let parserMask = parserLayout.nativeMask,
               let selectedMask = descriptor.channelLayout.nativeMask,
               parserMask != selectedMask {
                throw validationError()
            }
        }
        switch descriptor.codec {
        case .aac:
            throw validationError()
        case .mp2:
            guard frame.frameSamples == 1_152 else { throw validationError() }
        case .ac3:
            guard frame.frameSamples == 1_536 else { throw validationError() }
        case .eac3:
            guard [256, 512, 768, 1_536].contains(frame.frameSamples) else {
                throw validationError()
            }
        }
        let presentationTimeStamp = descriptor.timeBase.cmTime(forFFmpegValue: pts)
        guard presentationTimeStamp.isNumeric else { throw validationError() }
        try emitSample(
            data: frame.bytes,
            presentationTimeStamp: presentationTimeStamp,
            frameSamples: frame.frameSamples
        )
    }

    private func consumeADTS(
        _ data: Data,
        presentationTimeStamp: CMTime
    ) throws {
        guard data.count <= Self.maximumPayloadBytes - aacCarry.count else {
            throw validationError()
        }
        aacTimestampProvenance.append(ADTSTimestampProvenance(
            byteCount: data.count,
            presentationTimeStamp: presentationTimeStamp,
            startedFrameCount: 0
        ))
        aacCarry.append(data)

        while !aacCarry.isEmpty {
            guard Self.hasPossibleADTSSync(aacCarry) else { throw validationError() }
            guard aacCarry.count >= 7 else { break }
            let header = try parseADTSHeader(aacCarry)
            guard aacCarry.count >= header.headerLength,
                  aacCarry.count >= header.frameLength else { break }
            let presentationTimeStamp = try takeAACPresentationTimeStamp()
            let payloadStart = aacCarry.index(
                aacCarry.startIndex,
                offsetBy: header.headerLength
            )
            let payloadEnd = aacCarry.index(
                aacCarry.startIndex,
                offsetBy: header.frameLength
            )
            let payload = Data(aacCarry[payloadStart..<payloadEnd])
            try installFormat(cookie: header.cookie)
            try emitSample(
                data: payload,
                presentationTimeStamp: presentationTimeStamp,
                frameSamples: 1_024
            )
            aacCarry = Data(aacCarry.dropFirst(header.frameLength))
            try consumeAACProvenanceBytes(header.frameLength)
        }
        try collapseAACProvenanceForIncompleteFrame()
    }

    private func parseADTSHeader(_ data: Data) throws -> ADTSHeader {
        guard data.count >= 7 else { throw validationError() }
        let bytes = [UInt8](data.prefix(7))
        guard bytes[0] == 0xFF,
              bytes[1] & 0xF6 == 0xF0,
              bytes[2] >> 6 == 1 else {
            throw validationError()
        }
        let frequencyIndex = Int((bytes[2] >> 2) & 0x0F)
        guard frequencyIndex < Self.aacSampleRates.count,
              Self.aacSampleRates[frequencyIndex] == descriptor.sampleRate else {
            throw validationError()
        }
        let channelConfiguration = Int(((bytes[2] & 1) << 2) | (bytes[3] >> 6))
        guard channelConfiguration > 0,
              channelConfiguration < Self.aacChannelCounts.count,
              Self.aacChannelCounts[channelConfiguration] == descriptor.channelLayout.channelCount,
              bytes[6] & 0x03 == 0 else {
            throw validationError()
        }
        let headerLength = bytes[1] & 1 == 1 ? 7 : 9
        let frameLength = Int(bytes[3] & 0x03) << 11
            | Int(bytes[4]) << 3
            | Int(bytes[5] >> 5)
        guard frameLength >= headerLength,
              frameLength <= Self.maximumPayloadBytes else {
            throw validationError()
        }
        let cookie = Data([
            UInt8((2 << 3) | (frequencyIndex >> 1)),
            UInt8(((frequencyIndex & 1) << 7) | (channelConfiguration << 3)),
        ])
        return ADTSHeader(
            headerLength: headerLength,
            frameLength: frameLength,
            cookie: cookie
        )
    }

    private func validateASC(_ data: Data) throws -> Data {
        guard data.count == 2 else { throw validationError() }
        let bytes = [UInt8](data)
        let audioObjectType = Int(bytes[0] >> 3)
        let frequencyIndex = Int((bytes[0] & 0x07) << 1 | bytes[1] >> 7)
        let channelConfiguration = Int((bytes[1] >> 3) & 0x0F)
        guard audioObjectType == 2,
              frequencyIndex < Self.aacSampleRates.count,
              Self.aacSampleRates[frequencyIndex] == descriptor.sampleRate,
              channelConfiguration > 0,
              channelConfiguration < Self.aacChannelCounts.count,
              Self.aacChannelCounts[channelConfiguration] == descriptor.channelLayout.channelCount,
              bytes[1] & 0x07 == 0 else {
            throw validationError()
        }
        return data
    }

    private func installFormat(cookie: Data) throws {
        guard !cookie.isEmpty else { throw validationError() }
        guard cookie != currentCookie || formatDescription == nil else { return }
        let built = try AudioFormatDescriptionBuilder.make(
            codec: .aac,
            sampleRate: descriptor.sampleRate,
            channelLayout: descriptor.channelLayout,
            cookie: cookie
        )
        formatDescription = built.description
        currentCookie = cookie
        formatState.commitAudioCookie(cookie)
    }

    private func emitSample(
        data: Data,
        presentationTimeStamp: CMTime,
        frameSamples: Int32
    ) throws {
        guard let formatDescription,
              !data.isEmpty,
              data.count <= Self.maximumPayloadBytes,
              presentationTimeStamp.isNumeric,
              frameSamples > 0 else {
            throw validationError()
        }
        let fingerprint: MediaFormatFingerprint
        do {
            fingerprint = try formatState.fingerprint()
        } catch {
            throw validationError()
        }
        if fingerprint != emittedFingerprint {
            eventSink(.format(formatDescription, descriptor.codec, fingerprint))
            emittedFingerprint = fingerprint
        }
        let generation = generationProvider()
        let duration = CMTime(value: Int64(frameSamples), timescale: descriptor.sampleRate)
        let variableFrames = descriptor.codec == .eac3 ? UInt32(frameSamples) : 0
        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            data: data,
            formatDescription: formatDescription,
            presentationTimeStamp: presentationTimeStamp,
            variableFramesInPacket: variableFrames
        )
        let id = try takeNextID()
        eventSink(.sample(CompressedAudioSample(
            id: id,
            sampleBuffer: sampleBuffer,
            codec: descriptor.codec,
            generation: generation,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration
        )))
    }

    private func takeAACPresentationTimeStamp() throws -> CMTime {
        guard !aacTimestampProvenance.isEmpty else {
            throw validationError()
        }
        let provenance = aacTimestampProvenance[0]
        let (sampleOffset, multipliedOverflow) = provenance.startedFrameCount
            .multipliedReportingOverflow(by: 1_024)
        guard !multipliedOverflow else { throw validationError() }
        let presentationTimeStamp = CMTimeAdd(
            provenance.presentationTimeStamp,
            CMTime(value: sampleOffset, timescale: descriptor.sampleRate)
        )
        guard presentationTimeStamp.isNumeric else { throw validationError() }
        let (nextFrameCount, incrementOverflow) = provenance.startedFrameCount
            .addingReportingOverflow(1)
        guard !incrementOverflow else { throw validationError() }
        aacTimestampProvenance[0].startedFrameCount = nextFrameCount
        return presentationTimeStamp
    }

    private func consumeAACProvenanceBytes(_ byteCount: Int) throws {
        var remaining = byteCount
        while remaining > 0 {
            guard !aacTimestampProvenance.isEmpty else { throw validationError() }
            let available = aacTimestampProvenance[0].byteCount
            guard available > 0 else { throw validationError() }
            if remaining < available {
                aacTimestampProvenance[0].byteCount = available - remaining
                remaining = 0
            } else {
                remaining -= available
                aacTimestampProvenance.removeFirst()
            }
        }
    }

    private func collapseAACProvenanceForIncompleteFrame() throws {
        guard !aacCarry.isEmpty else {
            guard aacTimestampProvenance.isEmpty else { throw validationError() }
            return
        }
        guard let first = aacTimestampProvenance.first else { throw validationError() }
        var totalBytes = 0
        for provenance in aacTimestampProvenance {
            let (sum, overflow) = totalBytes.addingReportingOverflow(provenance.byteCount)
            guard !overflow else { throw validationError() }
            totalBytes = sum
        }
        guard totalBytes == aacCarry.count else { throw validationError() }
        aacTimestampProvenance = [ADTSTimestampProvenance(
            byteCount: aacCarry.count,
            presentationTimeStamp: first.presentationTimeStamp,
            startedFrameCount: first.startedFrameCount
        )]
    }

    private func takeNextID() throws -> UInt64 {
        guard let id = nextID else {
            throw PlaybackCoreError.audioFallbackDecode(Self.idExhaustedErrorCode)
        }
        nextID = id == UInt64.max ? nil : id + 1
        return id
    }

    private func validationError() -> PlaybackCoreError {
        .audioFallbackDecode(Self.invalidInputErrorCode)
    }

    private static func hasADTSSync(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] & 0xF6 == 0xF0
    }

    private static func hasPossibleADTSSync(_ data: Data) -> Bool {
        guard let first = data.first, first == 0xFF else { return false }
        return data.count == 1 || hasADTSSync(data)
    }
}

private struct ADTSHeader {
    let headerLength: Int
    let frameLength: Int
    let cookie: Data
}

private struct ADTSTimestampProvenance {
    var byteCount: Int
    let presentationTimeStamp: CMTime
    var startedFrameCount: Int64
}

private func audioExactTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64 {
    do {
        guard let value = try exactTicks(time, timeBase: timeBase) else {
            throw PlaybackCoreError.audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
        }
        return value
    } catch {
        throw PlaybackCoreError.audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
    }
}

private func audioOptionalTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard time.isValid else { return nil }
    return try audioExactTicks(time, timeBase: timeBase)
}

private func audioOptionalDurationTicks(
    _ time: CMTime,
    timeBase: MediaRational
) throws -> Int64? {
    guard let value = try audioOptionalTicks(time, timeBase: timeBase), value >= 0 else {
        if !time.isValid { return nil }
        throw PlaybackCoreError.audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
    }
    return value
}
