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
    private let hlsCopyOwnership: HLSAudioCopyOwnership?

    init(hlsCopyOwnership: HLSAudioCopyOwnership? = nil, receiver: @escaping (FramedCompressedAudioFrame) throws -> Void) {
        self.hlsCopyOwnership = hlsCopyOwnership
        self.receiver = receiver
    }

    func push(_ packet: CompressedAudioFramingPacket) throws {
        let lease = hlsCopyOwnership?.admit(.framing, bytes: packet.data.count)
        guard hlsCopyOwnership == nil || lease != nil else { throw AudioCodecProfileValidation.error() }
        guard packet.data.count <= AudioCodecProfileValidation.maximumRawAACAccessUnitBytes else {
            throw AudioCodecProfileValidation.error()
        }
        try receiver(FramedCompressedAudioFrame(
            payload: packet.data,
            presentationTimeStamp: packet.presentationTimeStamp,
            parserSampleCount: nil,
            parserSampleRate: nil,
            parserChannelLayout: nil,
            containerMarkedCorrupt: packet.containerMarkedCorrupt,
            hlsCopyTail: lease.map(HLSAudioCopyTail.init)
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
    private let hlsCopyOwnership: HLSAudioCopyOwnership?
    private var carry = Data()
    private var provenance: [Provenance] = []
    private var currentFrameCorrupt = false
    /// 每段 lease 只覆盖 carry 中连续且明确的 byte range。不能把一个整包
    /// lease 交给首帧，否则同包的后续帧/残余 carry 会在首帧释放后失去费用。
    private struct CarryLeaseSegment {
        var byteCount: Int
        let lease: HLSDataPlaneAdmission.Lease
    }
    private static let maximumLeaseSegments = 96
    private var carryLeases: [CarryLeaseSegment] = []

    init(
        sampleRate: Int32,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil,
        receiver: @escaping (FramedCompressedAudioFrame) throws -> Void
    ) {
        self.sampleRate = sampleRate
        self.hlsCopyOwnership = hlsCopyOwnership
        self.receiver = receiver
    }

    func push(_ packet: CompressedAudioFramingPacket) throws {
        guard packet.data.count <= Self.maximumPayloadBytes - carry.count else {
            throw AudioCodecProfileValidation.error()
        }
        // 在 carry.append 复制前，按将进入 carry 的实际 ownership range 取得费用。
        let newSegments = try makeLeaseSegments(for: packet.data)
        guard carryLeases.count + newSegments.count <= Self.maximumLeaseSegments else {
            throw AudioCodecProfileValidation.error()
        }
        provenance.append(Provenance(
            byteCount: packet.data.count,
            presentationTimeStamp: packet.presentationTimeStamp,
            startedFrameCount: 0
        ))
        carry.append(packet.data)
        carryLeases.append(contentsOf: newSegments)
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
            // Data(carry.prefix) 是新的 backing；先为该准确 frame range 收费，再复制。
            let outputLease = hlsCopyOwnership?.admit(.framing, bytes: frameLength)
            guard hlsCopyOwnership == nil || outputLease != nil else {
                throw AudioCodecProfileValidation.error()
            }
            let payload = Data(carry.prefix(frameLength))
            try receiver(FramedCompressedAudioFrame(
                payload: payload,
                presentationTimeStamp: timestamp,
                parserSampleCount: nil,
                parserSampleRate: nil,
                parserChannelLayout: nil,
                containerMarkedCorrupt: currentFrameCorrupt,
                hlsCopyTail: outputLease.map(HLSAudioCopyTail.init)
            ))
            consumeLeaseBytes(frameLength)
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
        carryLeases.removeAll(keepingCapacity: false)
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

    /// 分段边界只在可确定的 ADTS frame 边界或当前未完成 frame 的尾部建立。
    /// 因而任何 segment 都只归属一个将来帧或剩余 carry，不需要把整包 lease
    /// 共享给多个最后 holder。
    private func makeLeaseSegments(for data: Data) throws -> [CarryLeaseSegment] {
        guard let ownership = hlsCopyOwnership else { return [] }
        guard !data.isEmpty else { return [] }
        var lengths: [Int] = []
        let availableSegments = Self.maximumLeaseSegments - carryLeases.count
        guard availableSegments >= 0 else { throw AudioCodecProfileValidation.error() }
        func appendLength(_ length: Int) throws {
            guard length > 0, lengths.count < availableSegments else {
                throw AudioCodecProfileValidation.error()
            }
            lengths.append(length)
        }
        var offset = 0
        if !carry.isEmpty {
            guard carry.count + data.count >= 7 else {
                try appendLength(data.count)
                return try admitSegments(lengths, ownership: ownership)
            }
            let header = try combinedHeader(with: data)
            let headerLength = header[1] & 1 == 1 ? 7 : 9
            let frameLength = Int(header[3] & 3) << 11 | Int(header[4]) << 3 | Int(header[5] >> 5)
            guard frameLength > headerLength, frameLength <= Self.maximumPayloadBytes else {
                throw AudioCodecProfileValidation.error()
            }
            let needed = frameLength - carry.count
            guard needed > 0 else { throw AudioCodecProfileValidation.error() }
            let first = min(needed, data.count)
            try appendLength(first); offset = first
            if first < needed { return try admitSegments(lengths, ownership: ownership) }
        }
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 7 else { try appendLength(remaining); break }
            let b0 = data[data.index(data.startIndex, offsetBy: offset)]
            let b1 = data[data.index(data.startIndex, offsetBy: offset + 1)]
            guard b0 == 0xFF, b1 & 0xF6 == 0xF0 else { throw AudioCodecProfileValidation.error() }
            let b3 = data[data.index(data.startIndex, offsetBy: offset + 3)]
            let b4 = data[data.index(data.startIndex, offsetBy: offset + 4)]
            let b5 = data[data.index(data.startIndex, offsetBy: offset + 5)]
            let length = Int(b3 & 3) << 11 | Int(b4) << 3 | Int(b5 >> 5)
            let headerLength = b1 & 1 == 1 ? 7 : 9
            guard length > headerLength, length <= Self.maximumPayloadBytes else { throw AudioCodecProfileValidation.error() }
            let segmentLength = min(length, remaining)
            try appendLength(segmentLength); offset += segmentLength
            if segmentLength < length { break }
        }
        return try admitSegments(lengths, ownership: ownership)
    }

    private func combinedHeader(with data: Data) throws -> [UInt8] {
        var result: [UInt8] = []
        for value in carry.prefix(7) { result.append(value) }
        if result.count < 7 {
            for value in data.prefix(7 - result.count) { result.append(value) }
        }
        guard result.count == 7 else { throw AudioCodecProfileValidation.error() }
        return result
    }

    private func admitSegments(_ lengths: [Int], ownership: HLSAudioCopyOwnership) throws -> [CarryLeaseSegment] {
        var result: [CarryLeaseSegment] = []
        for length in lengths where length > 0 {
            guard let lease = ownership.admit(.framing, bytes: length) else {
                throw AudioCodecProfileValidation.error()
            }
            result.append(CarryLeaseSegment(byteCount: length, lease: lease))
        }
        return result
    }

    private func consumeLeaseBytes(_ byteCount: Int) {
        guard hlsCopyOwnership != nil else { return }
        var remaining = byteCount
        while remaining > 0 {
            precondition(!carryLeases.isEmpty && carryLeases[0].byteCount > 0)
            if remaining < carryLeases[0].byteCount {
                // makeLeaseSegments guarantees this branch cannot occur for a complete frame.
                preconditionFailure("ADTS lease segment 不得跨越 frame ownership 边界")
            }
            remaining -= carryLeases[0].byteCount
            carryLeases.removeFirst().lease.release()
        }
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
    private let hlsCopyOwnership: HLSAudioCopyOwnership?

    init(
        source: AudioTrackDescriptor,
        parserFactory: any FFmpegParserFactory,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil,
        receiver: @escaping (FramedCompressedAudioFrame) throws -> Void
    ) throws {
        let state = State()
        self.state = state
        self.hlsCopyOwnership = hlsCopyOwnership
        parser = try parserFactory.makeParser(
            configuration: FFmpegParserConfiguration(audio: source)
        ) { parsed in
            state.emittedOutput = true
            guard let pts = parsed.pts else { throw AudioCodecProfileValidation.error() }
            let timestamp = source.timeBase.cmTime(forFFmpegValue: pts)
            guard timestamp.isNumeric else { throw AudioCodecProfileValidation.error() }
            let payload: Data
            let tail: HLSAudioCopyTail?
            if let ownership = hlsCopyOwnership {
                let byteCount = parsed.withBorrowedBytes { $0.count }
                guard let lease = ownership.admit(.framing, bytes: byteCount) else {
                    throw AudioCodecProfileValidation.error()
                }
                payload = parsed.withBorrowedBytes { bytes in
                    bytes.withUnsafeBytes { raw in
                        guard let baseAddress = raw.baseAddress, !raw.isEmpty else { return Data() }
                        return Data(bytes: baseAddress, count: raw.count)
                    }
                }
                tail = HLSAudioCopyTail(lease)
            } else {
                payload = parsed.legacyUnadmittedBytes()
                tail = nil
            }
            try receiver(FramedCompressedAudioFrame(
                payload: payload,
                presentationTimeStamp: timestamp,
                parserSampleCount: parsed.frameSamples,
                parserSampleRate: parsed.sampleRate,
                parserChannelLayout: parsed.channelLayout,
                containerMarkedCorrupt: state.activeOutputCorrupt,
                hlsCopyTail: tail
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
