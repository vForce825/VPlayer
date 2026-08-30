// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

final class CompressedAudioAssembler {
    static let invalidInputErrorCode: Int32 = -1_448_208_897
    static let idExhaustedErrorCode: Int32 = -1_448_208_899

    private let generationProvider: () -> MediaGeneration
    private let eventSink: (AudioAssemblerEvent) -> Void
    private let parserFactory: any FFmpegParserFactory
    private let formatState: AssemblyFormatState
    private var descriptor: AudioTrackDescriptor
    private var profile: any CompressedAudioCodecProfile
    private var framer: (any CompressedAudioFramingStrategy)?
    private var nextID: UInt64?
    private var systemFormat: SystemCompressedAudioFormat?
    private var formatDescription: CMAudioFormatDescription?
    private var emittedFingerprint: MediaFormatFingerprint?

    private struct AudioUnitRejection: Error {
        let reason: AudioDecodeBreakReason
    }

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (AudioAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        startingID: UInt64 = 1
    ) throws {
        guard let descriptor = trackSet.audio else { throw Self.validationError() }
        self.descriptor = descriptor
        profile = try AudioCodecProfileRegistry.profile(for: descriptor)
        self.generationProvider = generationProvider
        self.eventSink = eventSink
        self.parserFactory = parserFactory
        self.formatState = formatState
        nextID = startingID
        try configureProfileAndFramer()
    }

    deinit {
        framer?.destroy()
    }

    func push(_ packet: DemuxPacket) throws {
        guard packet.streamIndex == descriptor.streamIndex,
              packet.codec == .audio(descriptor.codec),
              !packet.data.isEmpty,
              packet.presentationTimeStamp.isNumeric else {
            throw Self.validationError()
        }
        let pts = try audioExactTicks(packet.presentationTimeStamp, timeBase: descriptor.timeBase)
        let presentationTimeStamp = descriptor.timeBase.cmTime(forFFmpegValue: pts)
        guard presentationTimeStamp.isNumeric else { throw Self.validationError() }
        let framedPacket = CompressedAudioFramingPacket(
            data: packet.data,
            presentationTimeStamp: presentationTimeStamp,
            pts: pts,
            dts: try audioOptionalTicks(packet.decodeTimeStamp, timeBase: descriptor.timeBase),
            duration: try audioOptionalDurationTicks(packet.duration, timeBase: descriptor.timeBase),
            containerMarkedCorrupt: packet.isCorrupt
        )
        do {
            try framer?.push(framedPacket)
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch let rejection as AudioUnitRejection {
            try rejectCurrentUnit(reason: rejection.reason)
        } catch {
            try rejectCurrentUnit(reason: .framingReset)
        }
    }

    func drain() throws {
        do {
            try framer?.drain()
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch let rejection as AudioUnitRejection {
            try rejectCurrentUnit(reason: rejection.reason)
        } catch {
            try rejectCurrentUnit(reason: .framingReset)
        }
    }

    func reset(for trackSet: DemuxTrackSet) throws {
        guard let descriptor = trackSet.audio else { throw Self.validationError() }
        framer?.destroy()
        framer = nil
        self.descriptor = descriptor
        profile = try AudioCodecProfileRegistry.profile(for: descriptor)
        formatState.resetAudio(for: trackSet)
        systemFormat = nil
        formatDescription = nil
        emittedFingerprint = nil
        try configureProfileAndFramer()
    }

    private func configureProfileAndFramer() throws {
        guard descriptor.sampleRate > 0, descriptor.channelLayout.channelCount > 0 else {
            throw Self.validationError()
        }
        if let initial = try profile.initialSystemFormat(source: descriptor) {
            try install(initial)
        }
        framer = try makeFramer()
    }

    private func makeFramer() throws -> any CompressedAudioFramingStrategy {
        let receiver: (FramedCompressedAudioFrame) throws -> Void = { [weak self] frame in
            guard let self else { return }
            try receive(frame)
        }
        switch profile.framing {
        case .rawAAC:
            return RawAACFramingStrategy(receiver: receiver)
        case .adts:
            return ADTSAudioFramingStrategy(
                sampleRate: descriptor.sampleRate,
                receiver: receiver
            )
        case .ffmpegParser:
            return try FFmpegCompressedAudioFramingStrategy(
                source: descriptor,
                parserFactory: parserFactory,
                receiver: receiver
            )
        }
    }

    private func receive(_ framed: FramedCompressedAudioFrame) throws {
        let inspected: InspectedCompressedAudioFrame
        do {
            inspected = try profile.inspect(framed, source: descriptor)
        } catch {
            throw AudioUnitRejection(reason: profile.decodeBreakReason(
                forRejected: framed,
                source: descriptor
            ))
        }
        do {
            try install(inspected.systemFormat)
            guard let formatDescription else { throw Self.validationError() }
            let fingerprint = try formatState.fingerprint()
            if fingerprint != emittedFingerprint {
                eventSink(.format(CompressedAudioRenderConfiguration(
                    formatDescription: formatDescription,
                    codec: descriptor.codec,
                    decoderExtradata: inspected.decoderExtradata,
                    fingerprint: fingerprint
                )))
                emittedFingerprint = fingerprint
            }
            let id = try takeNextID()
            let generation = generationProvider()
            let duration = CMTime(
                value: Int64(inspected.sampleCount),
                timescale: inspected.systemFormat.sampleRate
            )
            guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
                throw Self.validationError()
            }
            eventSink(.frame(CompressedAudioFrame(
                id: id,
                payload: inspected.payload,
                codec: descriptor.codec,
                generation: generation,
                presentationTimeStamp: framed.presentationTimeStamp,
                duration: duration,
                frameSampleCount: inspected.sampleCount
            )))
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch {
            throw AudioUnitRejection(reason: .invalidFrame)
        }
    }

    private func install(_ newFormat: SystemCompressedAudioFormat) throws {
        guard newFormat.codec == descriptor.codec else { throw Self.validationError() }
        guard systemFormat != newFormat || formatDescription == nil else { return }
        let built = try AudioFormatDescriptionBuilder.make(newFormat)
        systemFormat = newFormat
        formatDescription = built.description
        formatState.commitAudioSystemFormat(AudioSystemFormatFingerprintComponent(newFormat))
    }

    private func rejectCurrentUnit(reason: AudioDecodeBreakReason) throws {
        framer?.destroy()
        framer = nil
        framer = try makeFramer()
        eventSink(.decodeBreak(reason))
    }

    private func takeNextID() throws -> UInt64 {
        guard let id = nextID else {
            throw PlaybackCoreError.audioFallbackDecode(Self.idExhaustedErrorCode)
        }
        nextID = id == UInt64.max ? nil : id + 1
        return id
    }

    fileprivate static func validationError() -> PlaybackCoreError {
        .audioFallbackDecode(invalidInputErrorCode)
    }
}

private func audioExactTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64 {
    do {
        guard let value = try exactTicks(time, timeBase: timeBase) else {
            throw CompressedAudioAssembler.validationError()
        }
        return value
    } catch {
        throw CompressedAudioAssembler.validationError()
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
        throw CompressedAudioAssembler.validationError()
    }
    return value
}
