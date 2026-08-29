// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct CompressedAudioFramingPacket {
    let data: Data
    let presentationTimeStamp: CMTime
    let pts: Int64
    let dts: Int64?
    let duration: Int64?
    let containerMarkedCorrupt: Bool
}

protocol CompressedAudioFramingStrategy: AnyObject {
    func push(_ packet: CompressedAudioFramingPacket) throws
    func drain() throws
    func destroy()
}

final class RawAACFramingStrategy: CompressedAudioFramingStrategy {
    private let receiver: (FramedCompressedAudioFrame) throws -> Void

    init(receiver: @escaping (FramedCompressedAudioFrame) throws -> Void) {
        self.receiver = receiver
    }

    func push(_ packet: CompressedAudioFramingPacket) throws {
        guard packet.data.count <= AudioCodecProfileValidation.maximumRawAACAccessUnitBytes else {
            throw AudioCodecProfileValidation.error()
        }
        try receiver(FramedCompressedAudioFrame(
            payload: packet.data,
            presentationTimeStamp: packet.presentationTimeStamp,
            parserSampleCount: nil,
            parserSampleRate: nil,
            parserChannelLayout: nil,
            containerMarkedCorrupt: packet.containerMarkedCorrupt
        ))
    }

    func drain() throws {}
    func destroy() {}
}

final class ADTSAudioFramingStrategy: CompressedAudioFramingStrategy {
    private struct Provenance {
        var byteCount: Int
        let presentationTimeStamp: CMTime
        var startedFrameCount: Int64
    }

    private static let maximumPayloadBytes = 64 * 1_024 * 1_024
    private let sampleRate: Int32
    private let receiver: (FramedCompressedAudioFrame) throws -> Void
    private var carry = Data()
    private var provenance: [Provenance] = []
    private var currentFrameCorrupt = false

    init(
        sampleRate: Int32,
        receiver: @escaping (FramedCompressedAudioFrame) throws -> Void
    ) {
        self.sampleRate = sampleRate
        self.receiver = receiver
    }

    func push(_ packet: CompressedAudioFramingPacket) throws {
        guard packet.data.count <= Self.maximumPayloadBytes - carry.count else {
            throw AudioCodecProfileValidation.error()
        }
        provenance.append(Provenance(
            byteCount: packet.data.count,
            presentationTimeStamp: packet.presentationTimeStamp,
            startedFrameCount: 0
        ))
        carry.append(packet.data)
        currentFrameCorrupt = currentFrameCorrupt || packet.containerMarkedCorrupt

        while !carry.isEmpty {
            guard hasPossibleSync(carry) else { throw AudioCodecProfileValidation.error() }
            guard carry.count >= 7 else { break }
            let bytes = [UInt8](carry.prefix(7))
            guard bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 else {
                throw AudioCodecProfileValidation.error()
            }
            let headerLength = bytes[1] & 1 == 1 ? 7 : 9
            let frameLength = Int(bytes[3] & 3) << 11
                | Int(bytes[4]) << 3
                | Int(bytes[5] >> 5)
            guard frameLength > headerLength, frameLength <= Self.maximumPayloadBytes else {
                throw AudioCodecProfileValidation.error()
            }
            guard carry.count >= frameLength else { break }
            let timestamp = try takePresentationTimeStamp()
            try receiver(FramedCompressedAudioFrame(
                payload: Data(carry.prefix(frameLength)),
                presentationTimeStamp: timestamp,
                parserSampleCount: nil,
                parserSampleRate: nil,
                parserChannelLayout: nil,
                containerMarkedCorrupt: currentFrameCorrupt
            ))
            carry.removeFirst(frameLength)
            try consumeProvenanceBytes(frameLength)
            currentFrameCorrupt = false
        }
        try collapseProvenanceForIncompleteFrame()
    }

    func drain() throws {
        guard carry.isEmpty, provenance.isEmpty else {
            throw AudioCodecProfileValidation.error()
        }
    }

    func destroy() {
        carry.removeAll(keepingCapacity: false)
        provenance.removeAll(keepingCapacity: false)
        currentFrameCorrupt = false
    }

    private func takePresentationTimeStamp() throws -> CMTime {
        guard !provenance.isEmpty else { throw AudioCodecProfileValidation.error() }
        let current = provenance[0]
        let (sampleOffset, overflow) = current.startedFrameCount
            .multipliedReportingOverflow(by: 1_024)
        guard !overflow else { throw AudioCodecProfileValidation.error() }
        let timestamp = CMTimeAdd(
            current.presentationTimeStamp,
            CMTime(value: sampleOffset, timescale: sampleRate)
        )
        guard timestamp.isNumeric else { throw AudioCodecProfileValidation.error() }
        let (nextCount, incrementOverflow) = current.startedFrameCount
            .addingReportingOverflow(1)
        guard !incrementOverflow else { throw AudioCodecProfileValidation.error() }
        provenance[0].startedFrameCount = nextCount
        return timestamp
    }

    private func consumeProvenanceBytes(_ byteCount: Int) throws {
        var remaining = byteCount
        while remaining > 0 {
            guard !provenance.isEmpty, provenance[0].byteCount > 0 else {
                throw AudioCodecProfileValidation.error()
            }
            if remaining < provenance[0].byteCount {
                provenance[0].byteCount -= remaining
                remaining = 0
            } else {
                remaining -= provenance[0].byteCount
                provenance.removeFirst()
            }
        }
    }

    private func collapseProvenanceForIncompleteFrame() throws {
        guard !carry.isEmpty else {
            guard provenance.isEmpty else { throw AudioCodecProfileValidation.error() }
            return
        }
        guard let first = provenance.first else { throw AudioCodecProfileValidation.error() }
        let byteCount = provenance.reduce(into: 0) { $0 += $1.byteCount }
        guard byteCount == carry.count else { throw AudioCodecProfileValidation.error() }
        provenance = [Provenance(
            byteCount: carry.count,
            presentationTimeStamp: first.presentationTimeStamp,
            startedFrameCount: first.startedFrameCount
        )]
    }

    private func hasPossibleSync(_ data: Data) -> Bool {
        guard data.first == 0xFF else { return false }
        return data.count == 1 || data[data.index(after: data.startIndex)] & 0xF6 == 0xF0
    }
}

final class FFmpegCompressedAudioFramingStrategy: CompressedAudioFramingStrategy {
    private final class State {
        // libavcodec's parser API does not report which input push contributed
        // each output. Retain one conservative taint bit until output or drain
        // proves the buffered prefix was consumed; this stays bounded even when
        // the parser delays a unit across arbitrarily many packets.
        var pendingCorruptProvenance = false
        var activeOutputCorrupt = false
        var emittedOutput = false
    }

    private let parser: any FFmpegParserHandle
    private let state: State

    init(
        source: AudioTrackDescriptor,
        parserFactory: any FFmpegParserFactory,
        receiver: @escaping (FramedCompressedAudioFrame) throws -> Void
    ) throws {
        let state = State()
        self.state = state
        parser = try parserFactory.makeParser(
            configuration: FFmpegParserConfiguration(audio: source)
        ) { parsed in
            state.emittedOutput = true
            guard let pts = parsed.pts else { throw AudioCodecProfileValidation.error() }
            let timestamp = source.timeBase.cmTime(forFFmpegValue: pts)
            guard timestamp.isNumeric else { throw AudioCodecProfileValidation.error() }
            try receiver(FramedCompressedAudioFrame(
                payload: parsed.bytes,
                presentationTimeStamp: timestamp,
                parserSampleCount: parsed.frameSamples,
                parserSampleRate: parsed.sampleRate,
                parserChannelLayout: parsed.channelLayout,
                containerMarkedCorrupt: state.activeOutputCorrupt
            ))
        }
    }

    func push(_ packet: CompressedAudioFramingPacket) throws {
        state.activeOutputCorrupt = state.pendingCorruptProvenance
            || packet.containerMarkedCorrupt
        state.emittedOutput = false
        defer { state.activeOutputCorrupt = false }
        try parser.push(
            packet.data,
            pts: packet.pts,
            dts: packet.dts,
            duration: packet.duration
        )
        if packet.containerMarkedCorrupt {
            state.pendingCorruptProvenance = true
        } else if state.emittedOutput {
            state.pendingCorruptProvenance = false
        }
    }

    func drain() throws {
        state.activeOutputCorrupt = state.pendingCorruptProvenance
        state.emittedOutput = false
        defer { state.activeOutputCorrupt = false }
        try parser.drain()
        state.pendingCorruptProvenance = false
    }

    func destroy() {
        parser.destroy()
    }
}
