// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum AACCookieStage: Sendable { case provisional, finalizedPass(Int), afterReset(Int), beforeLive, finalDrain }
extension AACCookieStage { var isLiveFinal: Bool { if case .finalDrain = self { return true }; return false } }
enum AACActualFormatStage: Sendable, Equatable { case creation, beforePass(Int), finalizedPass(Int), afterReset(Int), beforeLive, finalDrain }
enum AACLoopbackPhase: Sendable { case loadedTracks, createReader }

protocol AACCalibrationObserver: Sendable {
    func cookie(_ value: Data, at stage: AACCookieStage) -> Data
    func completedPass(_ pass: Int, lane: AACOwnedCallLane)
    func observedFormat(_ format: AACRenditionEncoder.ActualFormat)
    func actualFormat(_ format: AACRenditionEncoder.ActualFormat, at stage: AACActualFormatStage) -> AACRenditionEncoder.ActualFormat
    func observedProbe(_ samples: [Float], channels: Int)
    func loopbackPhase(_ phase: AACLoopbackPhase, lane: AACOwnedCallLane)
    func willDispose()
    func writerSegment(initialization: Bool, writerIdentity: ObjectIdentifier)
}
extension AACCalibrationObserver {
    func observedFormat(_ format: AACRenditionEncoder.ActualFormat) {}
    func actualFormat(_ format: AACRenditionEncoder.ActualFormat, at stage: AACActualFormatStage) -> AACRenditionEncoder.ActualFormat { format }
    func observedProbe(_ samples: [Float], channels: Int) {}
    func loopbackPhase(_ phase: AACLoopbackPhase, lane: AACOwnedCallLane) {}
    func willDispose() {}
    func writerSegment(initialization: Bool, writerIdentity: ObjectIdentifier) {}
}

struct AACDefaultCalibrationObserver: AACCalibrationObserver {
    func cookie(_ value: Data, at stage: AACCookieStage) -> Data { value }
    func completedPass(_ pass: Int, lane: AACOwnedCallLane) {}
}
final class AACOwnedCallLane: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var cancelled = false
    private enum CleanupState { case idle, cleaning, completed }
    private var cleanupState = CleanupState.idle
    var cancelRequested: Bool { lock.withLock { cancelled } }
    var isCancellationFinished: Bool { lock.withLock { cleanupState == .completed } }
    func enter() throws {
        try lock.withLock {
            guard !cancelled else { throw AACRenditionFailure.cancelled }
            guard !occupied else { throw AACRenditionFailure.busy }
            occupied = true
        }
    }
    func leave() { lock.withLock { occupied = false } }
    func call<T>(_ body: () throws -> T) throws -> T {
        try enter(); defer { leave() }; return try body()
    }
    func requestCancel() { lock.withLock { cancelled = true } }
    @discardableResult func finishCancellation(_ body: () -> Void) -> Bool {
        let accepted = lock.withLock {
            guard cancelled, !occupied, cleanupState == .idle else { return false }
            cleanupState = .cleaning; occupied = true; return true
        }
        guard accepted else { return false }
        body()
        lock.withLock { occupied = false; cleanupState = .completed }
        return true
    }
    // 原 runner 在在途调用终止后执行资源终态，不能从 cancel 调用栈抢占 permit。
    func cleanup(_ body: () -> Void) {
        let accepted = lock.withLock {
            guard !occupied else { return false }
            occupied = true; return true
        }
        guard accepted else { return }
        defer { leave() }; body()
    }
}
final class AACCalibrationWorkspace: @unchecked Sendable {
    enum Kind: Int, CaseIterable { case sourcePCM, aacPackets, temporaryFile, decodedPCM, correlation, nonPayload }
    /// 增量 writer 会保留一个完整共同 HLS 边界内的冻结 AAC 输入。视频 GOP
    /// 可超过一秒，因此 packet 预算必须覆盖该有界窗口，而不是只覆盖单次 pump。
    static let aacPacketCapacity = 2 * 1_024 * 1_024

    private static func capacity(for kind: Kind) -> Int {
        switch kind {
        case .aacPackets:
            aacPacketCapacity
        case .temporaryFile, .decodedPCM:
            1_048_576
        case .sourcePCM, .correlation, .nonPayload:
            524_288
        }
    }
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: AACCalibrationWorkspace?
        private let kind: Kind
        let bytes: Int
        init(owner: AACCalibrationWorkspace, kind: Kind, bytes: Int) { self.owner = owner; self.kind = kind; self.bytes = bytes }
        func release() {
            let original = lock.withLock { let result = owner; owner = nil; return result }
            original?.release(kind, bytes: bytes)
        }
        deinit { release() }
    }
    final class Reservation: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: AACCalibrationWorkspace?
        private let kind: Kind
        private var remaining: Int
        let reservedBytes: Int

        fileprivate init(owner: AACCalibrationWorkspace, kind: Kind, bytes: Int) {
            self.owner = owner
            self.kind = kind
            remaining = bytes
            reservedBytes = bytes
        }

        var unclaimedBytes: Int { lock.withLock { remaining } }

        func claim(bytes: Int) throws -> Lease {
            try lock.withLock {
                guard let owner, bytes >= 0, bytes <= remaining else {
                    throw AACRenditionFailure.capacityExceeded
                }
                remaining -= bytes
                return Lease(owner: owner, kind: kind, bytes: bytes)
            }
        }

        func releaseUnclaimed() {
            let release = lock.withLock { () -> (AACCalibrationWorkspace, Int)? in
                guard let owner else { return nil }
                let bytes = remaining
                remaining = 0
                self.owner = nil
                return (owner, bytes)
            }
            if let release { release.0.release(kind, bytes: release.1) }
        }

        deinit { releaseUnclaimed() }
    }
    private let lock = NSLock()
    private var totals = [Int](repeating: 0, count: 6)
    private var current = 0
    private var peak = 0
    var currentBytes: Int { lock.withLock { current } }
    var peakBytes: Int { lock.withLock { peak } }
    var atSoftLimit: Bool { currentBytes >= 3 * 1_024 * 1_024 }
    func acquire(_ kind: Kind, bytes: Int) throws -> Lease {
        try lock.withLock {
            let cap = Self.capacity(for: kind)
            guard bytes >= 0, bytes <= cap, totals[kind.rawValue] <= cap - bytes,
                  bytes == 0 || current < 3_145_728,
                  current <= 4_194_304 - bytes else { throw AACRenditionFailure.capacityExceeded }
            totals[kind.rawValue] += bytes; current += bytes; peak = max(peak, current)
        }
        return Lease(owner: self, kind: kind, bytes: bytes)
    }

    /// 在任何对应分配前，先在既有 kind/global cap 内取得尽可能大的预算；
    /// minimum 不可满足时不改变账本，调用者可在资源退休后重试。
    func reserveAvailable(
        _ kind: Kind,
        preferredBytes: Int,
        minimumBytes: Int
    ) throws -> Reservation {
        let reserved = try lock.withLock { () throws -> Int in
            let cap = Self.capacity(for: kind)
            guard preferredBytes >= minimumBytes, minimumBytes > 0 else {
                throw AACRenditionFailure.capacityExceeded
            }
            let kindAvailable = cap - totals[kind.rawValue]
            let globalAvailable = 4_194_304 - current
            let available = min(kindAvailable, globalAvailable)
            guard available >= minimumBytes else {
                throw AACRenditionFailure.capacityExceeded
            }
            let result = min(preferredBytes, available)
            totals[kind.rawValue] += result
            current += result
            peak = max(peak, current)
            return result
        }
        return Reservation(owner: self, kind: kind, bytes: reserved)
    }
    private func release(_ kind: Kind, bytes: Int) {
        lock.withLock { totals[kind.rawValue] -= bytes; current -= bytes }
    }
}
// 每个不可变 backing 只有一个 lease；Data 的只读别名不重复记账。
final class AACDataBacking: @unchecked Sendable, Hashable {
    let data: Data
    let lease: AACCalibrationWorkspace.Lease
    init(data: Data, lease: AACCalibrationWorkspace.Lease) { self.data = data; self.lease = lease }
    static func == (lhs: AACDataBacking, rhs: AACDataBacking) -> Bool { lhs.data == rhs.data }
    func hash(into hasher: inout Hasher) { hasher.combine(data) }
}

final class AACPresentationTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: AACRenditionFailure?
    private var visible = false
    private var publications = 0
    private let publish: @Sendable (AACRenditionFailure) -> Void
    init(publish: @escaping @Sendable (AACRenditionFailure) -> Void = { _ in }) { self.publish = publish }
    var failure: AACRenditionFailure? { lock.withLock { storedFailure } }
    var publicationCount: Int { lock.withLock { publications } }
    func markVisible() { lock.withLock { visible = true } }
    func fail(_ error: AACRenditionFailure) {
        let shouldPublish = lock.withLock {
            guard storedFailure == nil else { return false }
            storedFailure = error
            if visible { publications += 1 }
            return visible
        }
        if shouldPublish { publish(error) }
    }
}
final class AACCallbackAccumulator: @unchecked Sendable {
    struct SegmentEvent {
        let writerIdentity: ObjectIdentifier
        let encoderIdentity: AACEncoderIdentity
        let initialization: Bool
        let payload: Data
    }
    private struct Slot { let metadata: Data; let event: SegmentEvent? }
    private let lock = NSLock()
    private var values = [Slot?](repeating: nil, count: 8)
    private var storedCount = 0, bytes = 0, payloadBytes = 0
    var count: Int { lock.withLock { storedCount } }
    func append(_ data: Data) throws {
        try lock.withLock { try appendLocked(metadata: data, event: nil) }
    }
    func append(_ event: SegmentEvent) throws {
        try lock.withLock {
            guard !event.payload.isEmpty, event.payload.count <= 524_288 - payloadBytes else { throw AACRenditionFailure.capacityExceeded }
            if storedCount == 0 {
                guard event.initialization else { throw AACRenditionFailure.calibrationMismatch }
            } else {
                guard let first = values[0]?.event, !event.initialization,
                      first.writerIdentity == event.writerIdentity, first.encoderIdentity == event.encoderIdentity else {
                    throw AACRenditionFailure.invalidPlan
                }
            }
            // 事件只保留固定身份/类型元数据；segment backing 归临时 fMP4 的 1MiB 子账本。
            try appendLocked(metadata: Data(), event: event)
            payloadBytes += event.payload.count
        }
    }
    private func appendLocked(metadata: Data, event: SegmentEvent?) throws {
        let cost = metadata.count + (event == nil ? 0 : MemoryLayout<Slot>.stride + MemoryLayout<SegmentEvent>.stride)
        guard storedCount < 8, cost <= 8_192 - bytes else { throw AACRenditionFailure.capacityExceeded }
        values[storedCount] = Slot(metadata: metadata, event: event)
        storedCount += 1; bytes += cost
    }
    func materialize(at url: URL) throws {
        try lock.withLock {
            guard storedCount >= 2, values[0]?.event?.initialization == true else { throw AACRenditionFailure.calibrationMismatch }
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AACRenditionFailure.calibrationMismatch }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for index in 0..<storedCount {
                guard let event = values[index]?.event else { throw AACRenditionFailure.calibrationMismatch }
                try handle.write(contentsOf: event.payload)
            }
            // 文件与 segment backing 的瞬时并存已按 2×payload 在 1MiB 内预检。
        }
    }
    func releaseAll() {
        lock.withLock {
            for index in 0..<8 { values[index] = nil }
            storedCount = 0; bytes = 0; payloadBytes = 0
        }
    }
}
// 仅用于 Task15 的临时校准/回环；正式 publisher 与 m4s 编排仍由后续任务负责。
private final class AACProofSegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let accumulator = AACCallbackAccumulator()
    private let identity: AACEncoderIdentity
    private let observer: any AACCalibrationObserver
    private let lane: AACOwnedCallLane
    private let lock = NSLock()
    private var storedFailure: Error?
    private let metadataLease: AACCalibrationWorkspace.Lease
    let fileLease: AACCalibrationWorkspace.Lease
    init(identity: AACEncoderIdentity, workspace: AACCalibrationWorkspace, lane: AACOwnedCallLane, observer: any AACCalibrationObserver) throws {
        self.identity = identity; self.observer = observer; self.lane = lane
        metadataLease = try workspace.acquire(.nonPayload, bytes: 8_192)
        fileLease = try workspace.acquire(.temporaryFile, bytes: 1_048_576)
    }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.withLock {
            guard storedFailure == nil, !lane.cancelRequested else { return }
            do {
                guard segmentType == .initialization || segmentType == .separable else { throw AACRenditionFailure.calibrationMismatch }
                try accumulator.append(.init(writerIdentity: ObjectIdentifier(writer), encoderIdentity: identity,
                    initialization: segmentType == .initialization, payload: segmentData))
                observer.writerSegment(initialization: segmentType == .initialization, writerIdentity: ObjectIdentifier(writer))
            } catch { storedFailure = error }
        }
    }
    func materialize(at url: URL) throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            try accumulator.materialize(at: url)
            accumulator.releaseAll()
        }
    }
}
final class AACCalibrationReceipt: @unchecked Sendable {
    let encoders: [AACRenditionEncoder]
    private let lane: AACOwnedCallLane
    private let terminal: AACPresentationTerminal
    init(encoders: [AACRenditionEncoder], lane: AACOwnedCallLane, terminal: AACPresentationTerminal) {
        self.encoders = encoders; self.lane = lane; self.terminal = terminal
    }
    func encoder(for identity: AACEncoderIdentity) throws -> AACRenditionEncoder {
        guard !lane.cancelRequested, terminal.failure == nil, identity.ordinal >= 0, identity.ordinal < encoders.count,
              encoders[identity.ordinal].identity == identity else { throw AACRenditionFailure.invalidPlan }
        return encoders[identity.ordinal]
    }
}
final class AACPrimingCalibrator: @unchecked Sendable {
    let workspace = AACCalibrationWorkspace()
    let lane = AACOwnedCallLane()
    let presentationTerminal: AACPresentationTerminal
    private let lock = NSLock()
    private var running = false
    private var committedReceipt: AACCalibrationReceipt?
    var receipt: AACCalibrationReceipt? {
        lock.withLock { lane.cancelRequested || presentationTerminal.failure != nil ? nil : committedReceipt }
    }
    private let observer: any AACCalibrationObserver
    init(observer: any AACCalibrationObserver = AACDefaultCalibrationObserver(),
         onPresentationFailure: @escaping @Sendable (AACRenditionFailure) -> Void = { _ in }) {
        self.observer = observer
        presentationTerminal = AACPresentationTerminal(publish: onPresentationFailure)
    }
    func calibrate(plan: AACCalibrationPlan) async throws -> AACCalibrationReceipt {
        // 外部 plan 再验证完整向量；所有检查先于 transaction/converter 副作用。
        _ = try AACCalibrationPlan(entries: plan.entries)
        try lock.withLock {
            guard !running, committedReceipt == nil else { throw AACRenditionFailure.busy }
            guard !lane.cancelRequested else { throw AACRenditionFailure.cancelled }
            if let failure = presentationTerminal.failure { throw failure }
            running = true
        }
        defer { lock.withLock { running = false } }
        var encoders: [AACRenditionEncoder] = []; encoders.reserveCapacity(2)
        do {
            for entry in plan.entries {
                let identity = AACEncoderIdentity(plan: plan, ordinal: entry.ordinal, request: entry.request, nonce: ConverterInstanceNonce())
                let encoder = try AACRenditionEncoder(identity: identity, lane: lane, workspace: workspace,
                    observer: observer, presentationTerminal: presentationTerminal)
                encoders.append(encoder)
                let first = try await calibratePass(encoder, index: 1)
                observer.completedPass(1, lane: lane)
                try encoder.reset()
                let firstReset = try encoder.readResetEvidence(index: 1)
                let second = try await calibratePass(encoder, index: 2, expectedStart: firstReset.format)
                observer.completedPass(2, lane: lane)
                try encoder.finalize(first: first, second: second, firstReset: firstReset)
            }
            let result = AACCalibrationReceipt(encoders: encoders, lane: lane, terminal: presentationTerminal)
            try lock.withLock {
                guard !lane.cancelRequested else { throw AACRenditionFailure.cancelled }
                committedReceipt = result
            }
            return result
        } catch {
            for encoder in encoders { encoder.dispose() }
            throw error
        }
    }
    func cancel() { lane.requestCancel() }
    // 仅由原 runner 在在途 operation terminal 后调用；外部 cancel 栈不得执行资源终态。
    func finishOnOwnedRunner() throws {
        guard lane.cancelRequested || presentationTerminal.failure != nil else { throw AACRenditionFailure.invalidInput }
        let retained = try lock.withLock {
            guard !running else { throw AACRenditionFailure.busy }
            return committedReceipt
        }
        lane.requestCancel()
        let completed = lane.finishCancellation {
            for encoder in retained?.encoders ?? [] { encoder.disposeWithBorrowedPermit() }
        }
        guard completed || lane.isCancellationFinished else { throw AACRenditionFailure.busy }
        lock.withLock { committedReceipt = nil }
    }
    private func calibratePass(_ encoder: AACRenditionEncoder, index: Int,
                               expectedStart: AACRenditionEncoder.ActualFormat? = nil) async throws -> AACFinalizedPassSignature {
        let channels = encoder.identity.request.layout.labels.count
        let sourceLease = try workspace.acquire(.sourcePCM, bytes: 16_384 * channels * 4)
        defer { sourceLease.release() }
        // 固定有界宽带序列用于测量样本延迟；primeInfo 不参与 L 的计算。
        var source = [Float](); source.reserveCapacity(16_384 * channels)
        var state: UInt32 = 0x71a2b3c4
        for frame in 0..<16_384 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value: Float = frame < 256 || frame >= 16_128 ? 0 : Float(Int32(bitPattern: state) >> 17) / 32_768
            for _ in 0..<channels { source.append(value) }
        }
        observer.observedProbe(source, channels: channels)
        let pass = try encoder.encodePass(source, cookieStage: .finalizedPass(index), sourceLease: sourceLease, expectedStart: expectedStart)
        let raw = try encoder.makeEpoch(pass: pass, realFrames: pass.totalFrames, leading: 0)
        let decoded = try await AACSystemLoopback.decode(epoch: raw, lane: lane, workspace: workspace, observer: observer)
        let correlationLease = try workspace.acquire(.correlation, bytes: 524_288)
        defer { correlationLease.release() }
        let leading = try Self.leadingOffset(source: source, decoded: decoded.rawSamples, channels: channels, maximumOffset: 8_192)
        guard pass.totalFrames - leading - 16_384 >= 0 else { throw AACRenditionFailure.calibrationMismatch }
        return encoder.signature(pass: pass, leading: leading)
    }
    static func leadingOffset(source: [Float], decoded: [Float], channels: Int, maximumOffset: Int) throws -> Int {
        guard channels > 0, channels <= 8, source.count % channels == 0, decoded.count % channels == 0,
              source.count / channels >= 128, source.count / channels <= 16_384,
              decoded.count / channels <= 32_768, maximumOffset >= 0, maximumOffset <= 8_192,
              source.allSatisfy({ $0.isFinite && abs($0) <= 1 }), decoded.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw AACRenditionFailure.invalidInput }
        let frames = source.count / channels
        let start = frames >= 4_096 ? 1_024 : 0
        let width = min(2_048, frames - start)
        let upper = min(maximumOffset, decoded.count / channels - start - width)
        guard upper >= 0 else { throw AACRenditionFailure.calibrationMismatch }
        // 量化后只做整数乘加；最大 2048×32767²，远低于 Int64 上界。
        let a = (0..<width).map { Int64((Double(source[(start + $0) * channels]) * 32_767).rounded()) }
        let b = (0..<(decoded.count / channels)).map { Int64((Double(decoded[$0 * channels]) * 32_767).rounded()) }
        var best = Int64.min, second = Int64.min, offset = 0
        for candidate in 0...upper {
            var sum: Int64 = 0
            for index in 0..<width { sum += a[index] * b[start + candidate + index] }
            if sum > best { second = best; best = sum; offset = candidate } else { second = max(second, sum) }
        }
        guard best > 0, best > second else { throw AACRenditionFailure.calibrationMismatch }
        return offset
    }
}
// 容器 reader 的隐式 priming trim 不用于 L 的测量；只借用原样 AAC AU 与 packet 边界。
private final class AACReaderPacketInput {
    static let needsInputStatus: OSStatus = 0x76706E69
    private(set) var retained: CMSampleBuffer?
    private var pointer: UnsafeMutablePointer<Int8>?
    private var descriptions: UnsafePointer<AudioStreamPacketDescription>?
    private var count = 0, index = 0
    private let maximumPackets: Int
    private let supplied = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var hasher = SHA256()
    private(set) var packets = 0
    var ended = false
    var sawEOS = false
    let lane: AACOwnedCallLane
    var evidence: AACPacketSequenceEvidence { .init(accessUnitCount: packets, digest: Data(hasher.finalize())) }
    init(lane: AACOwnedCallLane, maximumPackets: Int = 64) {
        self.lane = lane; self.maximumPackets = maximumPackets
        supplied.initialize(to: AudioStreamPacketDescription())
        hasher.update(data: Data("VPlayer.AACPacketSequence.v2".utf8))
    }
    deinit { supplied.deinitialize(count: 1); supplied.deallocate() }
    func install(_ buffer: CMSampleBuffer, maximumBytes: Int) throws {
        guard retained == nil else { throw AACRenditionFailure.busy }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw AACRenditionFailure.calibrationMismatch }
        let packetCount = CMSampleBufferGetNumSamples(buffer)
        var descriptionBytes = 0, contiguousBytes = 0, totalBytes = 0
        try AACRenditionEncoder.check(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer,
            packetDescriptionsPointerOut: &descriptions, sizeOut: &descriptionBytes))
        try AACRenditionEncoder.check(CMBlockBufferGetDataPointer(block, atOffset: 0,
            lengthAtOffsetOut: &contiguousBytes, totalLengthOut: &totalBytes, dataPointerOut: &pointer))
        guard packetCount > 0, packetCount <= 64, packetCount <= maximumPackets - packets, totalBytes > 0, totalBytes <= maximumBytes,
              contiguousBytes == totalBytes, let pointer, let descriptions,
              descriptionBytes == packetCount * MemoryLayout<AudioStreamPacketDescription>.stride else { throw AACRenditionFailure.capacityExceeded }
        var offset = 0
        for position in 0..<packetCount {
            let description = descriptions[position], bytes = Int(descriptions[position].mDataByteSize)
            guard description.mStartOffset == Int64(offset), bytes > 0, bytes <= totalBytes - offset,
                  description.mVariableFramesInPacket == 0 || description.mVariableFramesInPacket == 1_024 else {
                throw AACRenditionFailure.calibrationMismatch
            }
            for value: UInt32 in [1_024,description.mVariableFramesInPacket,description.mDataByteSize] {
                withUnsafeBytes(of: value.bigEndian) { hasher.update(bufferPointer: $0) }
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer.advanced(by: offset), count: bytes))
            offset += bytes
        }
        guard offset == totalBytes else { throw AACRenditionFailure.calibrationMismatch }
        retained = buffer; count = packetCount; index = 0; packets += packetCount
    }
    func releaseConsumed() {
        retained = nil; pointer = nil; descriptions = nil; count = 0; index = 0
    }
    func provide(_ packetCount: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>,
                 outputDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        packetCount.pointee = 0
        data.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer())
        outputDescriptions?.pointee = nil
        guard !lane.cancelRequested else { return kAudio_ParamError }
        if index == count {
            releaseConsumed()
            if ended { sawEOS = true; return noErr }
            return Self.needsInputStatus
        }
        guard let pointer, let descriptions else { return kAudio_ParamError }
        let original = descriptions[index]
        supplied.pointee = original
        // 描述符偏移仅相对于本次借用的原 AU 起点，原 reader 描述符与字节保持不变。
        supplied.pointee.mStartOffset = 0
        packetCount.pointee = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: 0, mDataByteSize: original.mDataByteSize,
            mData: UnsafeMutableRawPointer(pointer.advanced(by: Int(original.mStartOffset))))
        outputDescriptions?.pointee = supplied
        index += 1
        return noErr
    }
}
private func aacReaderPacketInput(_ converter: AudioConverterRef, _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>, _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { packetCount.pointee = 0; return kAudio_ParamError }
    return Unmanaged<AACReaderPacketInput>.fromOpaque(context).takeUnretainedValue().provide(packetCount, data: data, outputDescriptions: descriptions)
}
struct AACPacketSequenceEvidence: Sendable, Equatable { let accessUnitCount: Int; let digest: Data }
struct AACWriterInputTimingEvidence: Sendable {
    let rawDecodedFrames: Int64
    let effectiveSampleCount: Int64
    let effectiveStartPTS: CMTime
    let effectiveEndPTS: CMTime
    let leadingTrimFrames: Int64
    let trailingTrimFrames: Int64
}
// 只观测传给 writer 的时间/附件；不从拼接 asset 反推 presentation 起止。
private struct AACWriterInputTimingAccumulator {
    let leading: Int64
    private var raw: Int64 = 0, effective: Int64 = 0, trailing: Int64 = 0
    init(leading: Int64) { self.leading = leading }
    mutating func append(_ buffer: CMSampleBuffer) throws {
        func trim(_ key: CFString) throws -> Int64 {
            guard let value = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) else { return 0 }
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { throw AACRenditionFailure.calibrationMismatch }
            let time = CMTimeMakeFromDictionary((value as! CFDictionary))
            let scaled = CMTimeConvertScale(time, timescale: 48_000, method: .default)
            guard time.isNumeric, scaled.value >= 0, CMTimeCompare(time, scaled) == 0 else {
                throw AACRenditionFailure.calibrationMismatch
            }
            return scaled.value
        }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, count <= 64, raw <= 163_840 - Int64(count) * 1_024, trailing == 0 else {
            throw AACRenditionFailure.capacityExceeded
        }
        let frames = Int64(count) * 1_024
        let start = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        let end = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        guard start == (raw == 0 ? leading : 0), start <= frames, end <= frames - start,
              CMTimeCompare(CMSampleBufferGetDuration(buffer), CMTime(value: frames, timescale: 48_000)) == 0,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), CMTime(value: 480_000 + raw - leading, timescale: 48_000)) == 0,
              CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp(buffer), CMTime(value: 480_000 + effective, timescale: 48_000)) == 0,
              CMTimeCompare(CMSampleBufferGetOutputDuration(buffer), CMTime(value: frames - start - end, timescale: 48_000)) == 0 else {
            throw AACRenditionFailure.calibrationMismatch
        }
        raw += frames; effective += frames - start - end; trailing = end
    }
    func seal(realFrames: Int64) throws -> AACWriterInputTimingEvidence {
        guard effective == realFrames, raw == leading + effective + trailing else { throw AACRenditionFailure.calibrationMismatch }
        return .init(rawDecodedFrames: raw, effectiveSampleCount: effective,
            effectiveStartPTS: CMTime(value: 480_000, timescale: 48_000),
            effectiveEndPTS: CMTime(value: 480_000 + effective, timescale: 48_000),
            leadingTrimFrames: leading, trailingTrimFrames: trailing)
    }
}
struct AACSystemDecodedPCM: @unchecked Sendable {
    let rawSamples: [Float]
    let rawFrameCount: Int
    let rawFirstPTS: CMTime
    let rawEndPTS: CMTime
    let inputTiming: AACWriterInputTimingEvidence
    let packetIdentity: AACPacketSequenceEvidence
    let rawReaderFormat: AACASBD
    let rawReaderCookie: AACDataBacking
    let writerCookieEvidence: AACMagicCookieEvidence
    let didDrainNaturally: Bool
    let lease: AACCalibrationWorkspace.Lease
    let metadataLease: AACCalibrationWorkspace.Lease
}
enum AACSystemLoopback {
    struct StreamEvidence: @unchecked Sendable {
        let rawFrameCount: Int64
        let rawFirstPTS: CMTime
        let rawEndPTS: CMTime
        // 这些是 raw PCM 中的内容观测窗口，不是裁尾后的播放数据。
        let rawFirstContentWindow: [Float]
        let rawMiddleContentWindow: [Float]
        let rawLastContentWindow: [Float]
        let rawWindowStartFrames: [Int64]
        let writerCookieEvidence: AACMagicCookieEvidence
        var writerDecoderSpecificInfo: Data { writerCookieEvidence.decoderSpecificInfo }
        var writerESDS: Data { writerCookieEvidence.backing.data }
        let summary: AACStreamSummary
        let inputTiming: AACWriterInputTimingEvidence
        let inputPacketIdentity: AACPacketSequenceEvidence
        let packetIdentity: AACPacketSequenceEvidence
        let rawReaderFormat: AACASBD
        let rawReaderCookie: AACDataBacking
        let didDrainNaturally: Bool
        let decodedLease: AACCalibrationWorkspace.Lease
        let metadataLease: AACCalibrationWorkspace.Lease
    }
    private struct RawDecodeResult {
        let rawFrameCount: Int64
        let rawFirstPTS: CMTime
        let rawEndPTS: CMTime
        let observations: [[Float]]
        let packetIdentity: AACPacketSequenceEvidence
        let rawReaderFormat: AACASBD
        let rawReaderCookie: AACDataBacking
        let decodedLease: AACCalibrationWorkspace.Lease
        let metadataLease: AACCalibrationWorkspace.Lease
    }
    private static func makeWriter(format: CMAudioFormatDescription, delegate: AACProofSegmentDelegate,
                                   lane: AACOwnedCallLane) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try lane.call { AVAssetWriter(contentType: .mpeg4Movie) }
        let input = try lane.call { () throws -> AVAssetWriterInput in
            writer.movieTimeScale = 48_000
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(value: 1, timescale: 1)
            writer.initialSegmentStartTime = CMTime(value: 10, timescale: 1)
            writer.delegate = delegate
            let value = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            value.expectsMediaDataInRealTime = false
            guard writer.canAdd(value) else { throw AACRenditionFailure.calibrationMismatch }
            writer.add(value)
            guard writer.startWriting() else { throw writer.error ?? AACRenditionFailure.calibrationMismatch }
            writer.startSession(atSourceTime: CMTime(value: 10, timescale: 1))
            return value
        }
        return (writer,input)
    }
    private static func finishWriter(_ writer: AVAssetWriter, input: AVAssetWriterInput, delegate: AACProofSegmentDelegate,
                                     url: URL, lane: AACOwnedCallLane) async throws {
        try lane.call { input.markAsFinished() }
        try lane.enter()
        await writer.finishWriting()
        lane.leave()
        try lane.call {}
        guard writer.status == .completed else { throw writer.error ?? AACRenditionFailure.calibrationMismatch }
        try lane.call { try delegate.materialize(at: url) }
    }
    private static func readWriterEvidence(url: URL, format: CMAudioFormatDescription, bitrate: UInt32,
                                           workspace: AACCalibrationWorkspace) throws -> AACMagicCookieEvidence {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard fileSize > 0, fileSize <= 524_288 else { throw AACRenditionFailure.capacityExceeded }
        let copyLease = try workspace.acquire(.nonPayload, bytes: fileSize)
        defer { withExtendedLifetime(copyLease) {} }
        let file = try Data(contentsOf: url)
        let esds = try AACWriterESDS.extract(from: file)
        let backing = AACDataBacking(data: esds, lease: try workspace.acquire(.nonPayload, bytes: esds.count))
        let evidence = try AACMagicCookieEvidence(backing: backing, configuredBitrate: bitrate,
            workspace: workspace, writerRepresentation: true)
        var cookieSize = 0
        guard let pointer = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize) else {
            throw AACRenditionFailure.calibrationMismatch
        }
        try AACRenditionEncoder.validateCookieCapacity(cookieSize)
        let sourceBacking = AACDataBacking(data: Data(bytes: pointer, count: cookieSize),
            lease: try workspace.acquire(.nonPayload, bytes: cookieSize))
        let original = try AACMagicCookieEvidence(backing: sourceBacking, configuredBitrate: bitrate, workspace: workspace)
        try original.validateWriterDecoderConfiguration(evidence)
        return evidence
    }
    static func decodeStream(encoder: AACRenditionEncoder, realFrames: Int64,
                             nextPCM: @escaping () throws -> [Float]?) async throws -> StreamEvidence {
        guard realFrames >= 8_192, realFrames <= 131_072, let frozen = encoder.passSignatures.last,
              let baseline = encoder.finalizedCookieEvidence else { throw AACRenditionFailure.invalidInput }
        let lane = encoder.lane, workspace = encoder.workspace
        let delegate = try AACProofSegmentDelegate(identity: encoder.identity, workspace: workspace, lane: lane, observer: encoder.observer)
        let formatLease = try workspace.acquire(.nonPayload, bytes: 8_192 + baseline.backing.data.count)
        defer { withExtendedLifetime((delegate,formatLease)) {} }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vplayer-aac-stream-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try encoder.makeFormat(asbd: frozen.actualASBD, cookie: baseline.backing.data)
        let (writer,input) = try makeWriter(format: format, delegate: delegate, lane: lane)
        defer { lane.cleanup { if writer.status == .writing { writer.cancelWriting() } } }
        var timing = AACWriterInputTimingAccumulator(leading: Int64(frozen.decodedLeadingSampleCount))
        let expected = AACReaderPacketInput(lane: lane, maximumPackets: 160)
        var sourceFrames: Int64 = 0, payloadBytes = 0, bufferCount = 0
        let channels = encoder.identity.request.layout.labels.count
        let summary = try encoder.encodeStream(nextPCM: {
            guard let samples = try nextPCM() else {
                guard sourceFrames == realFrames else { throw AACRenditionFailure.invalidInput }
                return nil
            }
            guard samples.count % channels == 0, samples.count / channels <= 16_384,
                  Int64(samples.count / channels) <= realFrames - sourceFrames else { throw AACRenditionFailure.capacityExceeded }
            sourceFrames += Int64(samples.count / channels)
            return samples
        }, append: { buffer in
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw AACRenditionFailure.calibrationMismatch }
            payloadBytes += CMBlockBufferGetDataLength(block); bufferCount += 1
            guard payloadBytes + bufferCount * 256 + 131_072 <= 524_288 else { throw AACRenditionFailure.capacityExceeded }
            try timing.append(buffer)
            try lane.call { try expected.install(buffer, maximumBytes: 524_288) }
            expected.releaseConsumed()
            try lane.call {
                guard input.isReadyForMoreMediaData, input.append(buffer) else { throw writer.error ?? AACRenditionFailure.calibrationMismatch }
            }
        })
        let inputTiming = try timing.seal(realFrames: realFrames)
        guard inputTiming.rawDecodedFrames == summary.totalDecodedFrames,
              inputTiming.trailingTrimFrames == summary.trailingFrames else { throw AACRenditionFailure.calibrationMismatch }
        try await finishWriter(writer, input: input, delegate: delegate, url: url, lane: lane)
        let writerEvidence = try readWriterEvidence(url: url, format: format, bitrate: encoder.identity.request.bitrate, workspace: workspace)
        // live pump 的 AU backing 已释放；reader 独占同一个固定 512KiB 子账本。
        let packetLease = try workspace.acquire(.aacPackets, bytes: 524_288)
        defer { withExtendedLifetime(packetLease) {} }
        let starts = [Int64(summary.leadingFrames),Int64(summary.leadingFrames) + realFrames / 2,
            Int64(summary.leadingFrames) + realFrames - 4_096]
        let raw = try await decodeRaw(url: url, format: format, expectedIdentity: expected.evidence,
            expectedFrames: summary.totalDecodedFrames, channels: channels, maximumBufferBytes: 524_288,
            windowStarts: starts, lane: lane, workspace: workspace, observer: encoder.observer)
        return StreamEvidence(rawFrameCount: raw.rawFrameCount, rawFirstPTS: raw.rawFirstPTS, rawEndPTS: raw.rawEndPTS,
            rawFirstContentWindow: raw.observations[0], rawMiddleContentWindow: raw.observations[1], rawLastContentWindow: raw.observations[2],
            rawWindowStartFrames: starts, writerCookieEvidence: writerEvidence, summary: summary, inputTiming: inputTiming,
            inputPacketIdentity: expected.evidence, packetIdentity: raw.packetIdentity, rawReaderFormat: raw.rawReaderFormat,
            rawReaderCookie: raw.rawReaderCookie, didDrainNaturally: true, decodedLease: raw.decodedLease, metadataLease: raw.metadataLease)
    }
    static func decode(epoch: AACEncodedEpoch, lane: AACOwnedCallLane = AACOwnedCallLane(),
                       workspace: AACCalibrationWorkspace = AACCalibrationWorkspace(),
                       observer: any AACCalibrationObserver = AACDefaultCalibrationObserver()) async throws -> AACSystemDecodedPCM {
        guard let first = epoch.buffers.first, let format = CMSampleBufferGetFormatDescription(first),
              epoch.buffers.count <= 64 else { throw AACRenditionFailure.invalidInput }
        let delegate = try AACProofSegmentDelegate(identity: epoch.identity, workspace: workspace, lane: lane, observer: observer)
        let inputLease = try workspace.acquire(.nonPayload, bytes: 8_192)
        defer { withExtendedLifetime((delegate,inputLease)) {} }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vplayer-aac-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let (writer,input) = try makeWriter(format: format, delegate: delegate, lane: lane)
        defer { lane.cleanup { if writer.status == .writing { writer.cancelWriting() } } }
        let expected = AACReaderPacketInput(lane: lane)
        var timing = AACWriterInputTimingAccumulator(leading: Int64(epoch.leadingFrames))
        for buffer in epoch.buffers {
            try timing.append(buffer)
            try lane.call { try expected.install(buffer, maximumBytes: 524_288) }
            expected.releaseConsumed()
            try lane.call {
                guard input.isReadyForMoreMediaData, input.append(buffer) else { throw writer.error ?? AACRenditionFailure.calibrationMismatch }
            }
        }
        let inputTiming = try timing.seal(realFrames: Int64(epoch.realSampleCount))
        guard inputTiming.trailingTrimFrames == Int64(epoch.trailingFrames) else { throw AACRenditionFailure.calibrationMismatch }
        try await finishWriter(writer, input: input, delegate: delegate, url: url, lane: lane)
        let writerEvidence = try readWriterEvidence(url: url, format: format, bitrate: epoch.identity.request.bitrate, workspace: workspace)
        let retainedBytes = epoch.buffers.reduce(65_536) { sum, buffer in
            sum + 4 * (CMSampleBufferGetDataBuffer(buffer).map(CMBlockBufferGetDataLength) ?? 0)
                + 2 * CMSampleBufferGetNumSamples(buffer) * MemoryLayout<AudioStreamPacketDescription>.stride
        }
        guard retainedBytes < 524_288 else { throw AACRenditionFailure.capacityExceeded }
        let raw = try await decodeRaw(url: url, format: format, expectedIdentity: expected.evidence,
            expectedFrames: Int64(epoch.totalDecodedFrames), channels: epoch.identity.request.layout.labels.count,
            maximumBufferBytes: 524_288 - retainedBytes, windowStarts: [], lane: lane, workspace: workspace, observer: observer)
        return AACSystemDecodedPCM(rawSamples: raw.observations[0], rawFrameCount: Int(raw.rawFrameCount),
            rawFirstPTS: raw.rawFirstPTS, rawEndPTS: raw.rawEndPTS, inputTiming: inputTiming, packetIdentity: raw.packetIdentity,
            rawReaderFormat: raw.rawReaderFormat, rawReaderCookie: raw.rawReaderCookie, writerCookieEvidence: writerEvidence,
            didDrainNaturally: true, lease: raw.decodedLease, metadataLease: raw.metadataLease)
    }
    private static func decodeRaw(url: URL, format expectedFormat: CMAudioFormatDescription,
                                  expectedIdentity: AACPacketSequenceEvidence, expectedFrames: Int64, channels: Int,
                                  maximumBufferBytes: Int, windowStarts: [Int64], lane: AACOwnedCallLane,
                                  workspace: AACCalibrationWorkspace, observer: any AACCalibrationObserver) async throws -> RawDecodeResult {
        guard expectedFrames > 0, expectedFrames <= 163_840, expectedIdentity.accessUnitCount <= 160,
              Int64(expectedIdentity.accessUnitCount) * 1_024 == expectedFrames,
              windowStarts.isEmpty ? expectedFrames <= 32_768 : windowStarts.count == 3 else { throw AACRenditionFailure.capacityExceeded }
        let metadataLease = try workspace.acquire(.nonPayload, bytes: 32_768)
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        try lane.enter()
        do { tracks = try await asset.loadTracks(withMediaType: .audio); lane.leave() }
        catch { lane.leave(); throw error }
        observer.loopbackPhase(.loadedTracks, lane: lane)
        // await terminal 与下一次 reader 创建是两个独立的 permit phase。
        try lane.call {}
        guard tracks.count == 1, let track = tracks.first else { throw AACRenditionFailure.calibrationMismatch }
        let reader = try lane.call {
            observer.loopbackPhase(.createReader, lane: lane)
            return try AVAssetReader(asset: asset)
        }
        defer { lane.cleanup { if reader.status == .reading { reader.cancelReading() } } }
        let output = try lane.call { () throws -> AVAssetReaderTrackOutput in
            let value = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            value.alwaysCopiesSampleData = false
            guard reader.canAdd(value) else { throw AACRenditionFailure.calibrationMismatch }
            reader.add(value)
            guard reader.startReading() else { throw reader.error ?? AACRenditionFailure.calibrationMismatch }
            return value
        }
        var current = try lane.call { output.copyNextSampleBuffer() }
        guard let format = current.flatMap(CMSampleBufferGetFormatDescription),
              let inputDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let expectedDescription = CMAudioFormatDescriptionGetStreamBasicDescription(expectedFormat) else {
            throw AACRenditionFailure.calibrationMismatch
        }
        var source = inputDescription.pointee
        guard AACASBD(source) == AACASBD(expectedDescription.pointee), source.mFormatID == kAudioFormatMPEG4AAC,
              source.mFormatFlags == 0, source.mSampleRate == 48_000, source.mFramesPerPacket == 1_024,
              source.mChannelsPerFrame == channels else { throw AACRenditionFailure.calibrationMismatch }
        var cookieSize = 0
        guard let cookiePointer = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize) else {
            throw AACRenditionFailure.calibrationMismatch
        }
        try AACRenditionEncoder.validateCookieCapacity(cookieSize)
        let cookie = AACDataBacking(data: Data(bytes: cookiePointer, count: cookieSize),
            lease: try workspace.acquire(.nonPayload, bytes: cookieSize))
        var destination = AACRenditionEncoder.pcmFormat(channels: channels)
        var decoder: AudioConverterRef?
        try lane.call { try AACRenditionEncoder.check(AudioConverterNew(&source, &destination, &decoder)) }
        guard let decoder else { throw AACRenditionFailure.calibrationMismatch }
        defer { lane.cleanup { AudioConverterDispose(decoder) } }
        try cookie.data.withUnsafeBytes { bytes in
            try lane.call { try AACRenditionEncoder.check(AudioConverterSetProperty(decoder, kAudioConverterDecompressionMagicCookie,
                UInt32(bytes.count), bytes.baseAddress!)) }
        }
        // 原样 cookie/AU/PTS 进入系统解码器；不读 primeInfo、不补帧、不按 N 裁写 PCM。
        let pcmLease = try workspace.acquire(.decodedPCM, bytes: 1_048_576)
        let starts = windowStarts.isEmpty ? [Int64(0)] : windowStarts
        let width = windowStarts.isEmpty ? Int(expectedFrames) : 4_096
        var observations = [[Float]](repeating: [], count: starts.count)
        for index in starts.indices {
            guard starts[index] >= 0, starts[index] <= expectedFrames - Int64(width) else { throw AACRenditionFailure.calibrationMismatch }
            observations[index].reserveCapacity(width * channels)
        }
        var decoded = [Float](repeating: 0, count: 4_096 * channels)
        guard (observations.reduce(0) { $0 + $1.capacity } + decoded.capacity) * 4 <= 1_048_576 else {
            throw AACRenditionFailure.capacityExceeded
        }
        let input = AACReaderPacketInput(lane: lane, maximumPackets: expectedIdentity.accessUnitCount)
        var firstPTS: CMTime?, endPTS = CMTime.invalid
        var consumedFrames: Int64 = 0, decodedFrames: Int64 = 0
        var emptyMarkers = 0
        while true {
            if let buffer = current {
                if CMSampleBufferGetNumSamples(buffer) == 0 {
                    guard emptyMarkers < 8, CMSampleBufferGetTotalSampleSize(buffer) == 0,
                          CMSampleBufferGetDataBuffer(buffer).map(CMBlockBufferGetDataLength) ?? 0 == 0 else {
                        throw AACRenditionFailure.capacityExceeded
                    }
                    emptyMarkers += 1
                    current = nil
                    current = try lane.call { output.copyNextSampleBuffer() }
                    continue
                }
                guard let currentFormat = CMSampleBufferGetFormatDescription(buffer),
                      CMFormatDescriptionEqual(currentFormat, otherFormatDescription: format) else { throw AACRenditionFailure.calibrationMismatch }
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                if let firstPTS {
                    let expectedPTS = CMTimeAdd(firstPTS, CMTime(value: consumedFrames, timescale: 48_000))
                    guard CMTimeCompare(pts, expectedPTS) == 0 else { throw AACRenditionFailure.calibrationMismatch }
                } else { firstPTS = pts }
                let count = Int64(CMSampleBufferGetNumSamples(buffer)) * 1_024
                guard CMTimeCompare(CMSampleBufferGetDuration(buffer), CMTime(value: count, timescale: 48_000)) == 0 else {
                    throw AACRenditionFailure.calibrationMismatch
                }
                consumedFrames += count
                endPTS = CMTimeAdd(pts, CMSampleBufferGetDuration(buffer))
                try lane.call { try input.install(buffer, maximumBytes: maximumBufferBytes) }
            } else {
                guard reader.status == .completed else { throw reader.error ?? AACRenditionFailure.calibrationMismatch }
                input.ended = true
            }
            var paused = false, drained = false
            for _ in 0..<64 {
                var frames: UInt32 = 4_096, outputBytes: UInt32 = 0
                let status = try decoded.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                    let status = try lane.call {
                        AudioConverterFillComplexBuffer(decoder, aacReaderPacketInput, Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
                    }
                    outputBytes = list.mBuffers.mDataByteSize
                    return status
                }
                guard !lane.cancelRequested else { throw AACRenditionFailure.cancelled }
                paused = status == AACReaderPacketInput.needsInputStatus
                if !paused { try AACRenditionEncoder.check(status) }
                guard frames <= 4_096, outputBytes == frames * UInt32(channels * 4),
                      decodedFrames <= expectedFrames - Int64(frames) else { throw AACRenditionFailure.calibrationMismatch }
                for index in starts.indices {
                    let lower = max(decodedFrames, starts[index]), upper = min(decodedFrames + Int64(frames), starts[index] + Int64(width))
                    if lower < upper {
                        observations[index].append(contentsOf: decoded[(Int(lower - decodedFrames) * channels)..<(Int(upper - decodedFrames) * channels)])
                    }
                }
                decodedFrames += Int64(frames)
                if paused { break }
                if frames == 0 {
                    guard input.ended, input.sawEOS else { throw AACRenditionFailure.calibrationMismatch }
                    drained = true; break
                }
            }
            if drained { break }
            guard paused, !input.ended else { throw AACRenditionFailure.capacityExceeded }
            current = nil
            current = try lane.call { output.copyNextSampleBuffer() }
        }
        guard input.evidence == expectedIdentity, consumedFrames == expectedFrames, decodedFrames == expectedFrames,
              observations.allSatisfy({ $0.count == width * channels }), let firstPTS, endPTS.isNumeric else {
            throw AACRenditionFailure.calibrationMismatch
        }
        return RawDecodeResult(rawFrameCount: decodedFrames, rawFirstPTS: firstPTS, rawEndPTS: endPTS,
            observations: observations, packetIdentity: input.evidence, rawReaderFormat: AACASBD(source), rawReaderCookie: cookie,
            decodedLease: pcmLease, metadataLease: metadataLease)
    }
}
