// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import Network
import VPlayerCore
import XCTest
@testable import VPlayerPlayback

struct AcceptancePCMStatistics {
    var frames = 0
    var maximumGapSamples = 0.0
    var silentWindows = 0
    var minimumRMS = Double.infinity
    var silentShortWindows = 0
    var minimumShortRMS = Double.infinity
    private var shortWindowSamples = 0
    private var shortWindowPower = 0.0
    private var observedSamples = 0
    private var pendingShortWindows: [(end: Double, rms: Double)] = []
    var checkedShortWindows = 0
    var silentWindowEndTimes: [Double] = []
    private var previousEnd: CMTime?
    private var windowSamples = 0
    private var windowPower = 0.0

    mutating func consume(_ sample: CMSampleBuffer) throws {
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBitsPerChannel, 32)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
        let count = CMSampleBufferGetNumSamples(sample)
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        XCTAssertTrue(start.isNumeric)
        if let previousEnd {
            maximumGapSamples = max(maximumGapSamples, abs(CMTimeSubtract(start, previousEnd).seconds * 48_000))
        }
        previousEnd = CMTimeAdd(start, CMTime(value: Int64(count), timescale: 48_000))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        XCTAssertEqual(length, count * 2 * MemoryLayout<Float>.stride)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw AACRenditionFailure.framework(status) }
        var nonfiniteSamples = 0
        data.withUnsafeBytes { bytes in
            for index in 0..<(length / MemoryLayout<Float>.stride) {
                let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
                if !value.isFinite { nonfiniteSamples += 1 }
                let power = Double(value) * Double(value)
                windowPower += power
                windowSamples += 1
                shortWindowPower += power
                shortWindowSamples += 1
                observedSamples += 1
                if shortWindowSamples == 240 * 2 {
                    let seconds = Double(observedSamples) / (2 * 48_000)
                    if seconds >= 0.255 {
                        let rms = sqrt(shortWindowPower / Double(shortWindowSamples))
                        pendingShortWindows.append((seconds, rms))
                        // Hold the actual last 250 ms until EOF. AC3 source padding
                        // and final AAC padding are not recurring interior mutes.
                        if pendingShortWindows.count > 50 {
                            let interior = pendingShortWindows.removeFirst()
                            checkedShortWindows += 1
                            minimumShortRMS = min(minimumShortRMS, interior.rms)
                            if interior.rms < 0.001 {
                                silentShortWindows += 1
                                if silentWindowEndTimes.count < 128 { silentWindowEndTimes.append(interior.end) }
                            }
                        }
                    }
                    shortWindowSamples = 0
                    shortWindowPower = 0
                }
                if windowSamples == 4_800 * 2 {
                    let rms = sqrt(windowPower / Double(windowSamples))
                    minimumRMS = min(minimumRMS, rms)
                    if rms < 0.001 { silentWindows += 1 }
                    windowSamples = 0
                    windowPower = 0
                }
            }
        }
        XCTAssertEqual(nonfiniteSamples, 0)
        frames += count
    }
}

/// Own a legacy header before leaving the typed reader payload's unsafe borrow.
func makeOwnedReaderFixtureSample(
    copying ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
) throws -> CMSampleBuffer {
    try ready.withUnsafeSampleBuffer { sample in
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleBufferOut: &copied)
        guard status == noErr, let copied, CMSampleBufferDataIsReady(copied) else {
            throw NSError(domain: NSOSStatusErrorDomain,
                code: Int(status == noErr ? kCMSampleBufferError_BufferNotReady : status))
        }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                target: sample, attachmentMode: mode) {
                CMSetAttachments(copied, attachments: attachments, attachmentMode: mode)
            }
        }
        // C does not annotate the new header returned through this out-pointer.
        nonisolated(unsafe) let ownedHeader = copied
        return ownedHeader
    }
}

/// Stream public TS from disk at38Mbps. The360-second source outlasts the capped
/// observation, so source EOF cannot hide growing live producer allocations.
final class AcceptanceHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hls.acceptance.source")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var stopped = false
    private let metrics = AcceptanceTransportMetrics()
    var transportSnapshot: (bytes: Int, start: Double?) { metrics.snapshot }
    let sourceURL: URL

    init(fileURL: URL) throws {
        let size = try XCTUnwrap(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed, .cancelled: ready.signal(); default: break }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
            listener.cancel()
            throw AcceptanceError.invalid("source server unavailable")
        }
        sourceURL = url
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.lock.withLock {
                guard !self.stopped, self.connections.count < 4 else { return false }
                self.connections.append(connection)
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                do {
                    let feed = try AcceptanceSourceFeed(connection: connection, file: fileURL,
                        queue: self.queue, metrics: self.metrics)
                    let header = Data(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n" +
                        "Content-Length: \(size)\r\nConnection: close\r\n\r\n").utf8)
                    connection.send(content: header, completion: .contentProcessed { error in
                        if error == nil { feed.sendNext() } else { feed.close() }
                    })
                } catch { connection.cancel() }
            }
        }
    }

    func stop() {
        let pending = lock.withLock {
            stopped = true
            defer { connections.removeAll() }
            return connections
        }
        for connection in pending { connection.cancel() }
        listener.cancel()
    }
}

private final class AcceptanceSourceFeed: @unchecked Sendable {
    let connection: NWConnection
    let handle: FileHandle
    let queue: DispatchQueue
    let metrics: AcceptanceTransportMetrics
    let started = AcceptanceClock.now
    var sent = 0

    init(connection: NWConnection, file: URL, queue: DispatchQueue, metrics: AcceptanceTransportMetrics) throws {
        self.connection = connection
        self.queue = queue
        self.metrics = metrics
        handle = try FileHandle(forReadingFrom: file)
        metrics.begin(at: started)
    }

    func sendNext() {
        // Independent source-socket safety bound. The common watchdog closes it
        // earlier at the deadline measured from before assembler.start().
        guard AcceptanceClock.now - started < 299.5 else { close(); return }
        do {
            guard let bytes = try handle.read(upToCount: 188 * 100), !bytes.isEmpty else { close(); return }
            sent += bytes.count
            connection.send(content: bytes, completion: .contentProcessed { [self] error in
                guard error == nil else { close(); return }
                metrics.delivered(bytes.count)
                let target = started + Double(sent) / 4_750_000
                queue.asyncAfter(deadline: .now() + max(0, target - AcceptanceClock.now)) {
                    self.sendNext()
                }
            })
        } catch { close() }
    }

    func close() { try? handle.close(); connection.cancel() }
}

private final class AcceptanceTransportMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var start: Double?
    func begin(at time: Double) { lock.withLock { if start == nil { start = time } } }
    func delivered(_ count: Int) { lock.withLock { bytes += count } }
    var snapshot: (bytes: Int, start: Double?) { lock.withLock { (bytes, start) } }
}

enum AcceptanceError: Error { case invalid(String) }

/// Disk-only capture of original callback bytes; never retains sealed objects,
/// publication leases, input backing or a growing array of media payloads.
final class AcceptanceCapture: @unchecked Sendable {
    struct Track {
        let kind: String
        let url: URL
        let handle: FileHandle
        var writers: Set<UInt64> = []
        var inits = 0
        var fragments = 0
        var defaultDuration: UInt32 = 0
        var continuity = AcceptanceFragmentContinuity()
    }
    private let lock = NSLock()
    private let directory: URL
    private var tracks: [String: Track] = [:]
    private var failure: (any Error)?
    private var copiedBytes = 0

    init(directory: URL) { self.directory = directory }

    func receive(_ object: SealedMediaObject) {
        lock.withLock {
            do {
                let codec = object.publicationEvidence?.format.codec ?? ""
                let kind = object.report.mediaType == .audio || codec == "mp4a.40.2" ? "audio" : "video"
                if tracks[kind] == nil {
                    guard tracks.count < 2 else { throw AcceptanceError.invalid("unexpected rendition") }
                    let url = directory.appendingPathComponent("original-\(kind).mp4")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw AcceptanceError.invalid("cannot create original capture")
                    }
                    tracks[kind] = Track(kind: kind, url: url, handle: try FileHandle(forWritingTo: url))
                }
                var track = tracks[kind]!
                track.writers.insert(object.writerIdentity.rawValue)
                let bytes = object.bytes
                guard copiedBytes + bytes.count < 1_500_000_000, track.fragments < 1_024 else {
                    throw AcceptanceError.invalid("bounded capture capacity exceeded")
                }
                copiedBytes += bytes.count
                if object.kind == .initialization {
                    track.inits += 1
                    if track.inits == 1 {
                        track.defaultDuration = try AcceptanceMP4.defaultDuration(bytes)
                        try track.handle.write(contentsOf: bytes)
                    }
                } else {
                    try track.continuity.observe(bytes, defaultDuration: track.defaultDuration)
                    track.fragments += 1
                    try track.handle.write(contentsOf: bytes)
                }
                tracks[kind] = track
            } catch { failure = error }
        }
    }

    func finish() throws -> [Track] {
        try lock.withLock {
            if let failure { throw failure }
            for track in tracks.values { try track.handle.synchronize(); try track.handle.close() }
            return tracks.values.sorted { $0.kind < $1.kind }
        }
    }
}

/// Strict read-only MP4 facts, including tfhd/trex duration defaults.
enum AcceptanceMP4 {
    struct Box { let type: String; let payload: Int; let end: Int }
    struct Fragment { let sequence: UInt32; let time: UInt64; let duration: UInt64 }

    static func u32(_ bytes: Data, _ offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }
    static func u64(_ bytes: Data, _ offset: Int) -> UInt64 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
    }
    static func boxes(_ bytes: Data, _ start: Int = 0, _ end: Int? = nil) throws -> [Box] {
        let end = end ?? bytes.count
        var position = start
        var result: [Box] = []
        while position < end {
            guard position + 8 <= end, result.count < 1_024 else { throw AcceptanceError.invalid("MP4 box bounds") }
            let size32 = u32(bytes, position)
            let header = size32 == 1 ? 16 : 8
            guard position + header <= end else { throw AcceptanceError.invalid("MP4 extended box") }
            let size64 = size32 == 1 ? u64(bytes, position + 8) : UInt64(size32 == 0 ? end - position : Int(size32))
            guard let size = Int(exactly: size64), size >= header, size <= end - position else {
                throw AcceptanceError.invalid("MP4 box size")
            }
            result.append(.init(type: String(decoding: bytes[(position+4)..<(position+8)], as: UTF8.self),
                payload: position + header, end: position + size))
            position += size
        }
        return result
    }
    static func one(_ kind: String, _ boxes: [Box]) throws -> Box {
        let values = boxes.filter { $0.type == kind }
        guard values.count == 1 else { throw AcceptanceError.invalid("missing/duplicate \(kind)") }
        return values[0]
    }
    static func defaultDuration(_ bytes: Data) throws -> UInt32 {
        let moov = try one("moov", boxes(bytes))
        let mvex = try one("mvex", boxes(bytes, moov.payload, moov.end))
        let trex = try one("trex", boxes(bytes, mvex.payload, mvex.end))
        guard trex.payload + 24 <= trex.end else { throw AcceptanceError.invalid("short trex") }
        return u32(bytes, trex.payload + 12)
    }
    static func fragment(_ bytes: Data, defaultDuration: UInt32) throws -> Fragment {
        let top = try boxes(bytes)
        _ = try one("mdat", top)
        let moof = try one("moof", top)
        let children = try boxes(bytes, moof.payload, moof.end)
        let mfhd = try one("mfhd", children)
        let traf = try one("traf", children)
        let track = try boxes(bytes, traf.payload, traf.end)
        let tfdt = try one("tfdt", track)
        let tfhd = try one("tfhd", track)
        guard mfhd.payload + 8 <= mfhd.end, tfdt.payload + 8 <= tfdt.end,
              tfhd.payload + 8 <= tfhd.end, bytes[tfdt.payload] <= 1 else {
            throw AcceptanceError.invalid("short fragment headers")
        }
        var durationDefault = defaultDuration
        let flags = u32(bytes, tfhd.payload) & 0x00ff_ffff
        var position = tfhd.payload + 8
        if flags & 1 != 0 { position += 8 }
        if flags & 2 != 0 { position += 4 }
        if flags & 8 != 0 {
            guard position + 4 <= tfhd.end else { throw AcceptanceError.invalid("short tfhd duration") }
            durationDefault = u32(bytes, position)
        }
        let time: UInt64
        if bytes[tfdt.payload] == 1 {
            guard tfdt.payload + 12 <= tfdt.end else { throw AcceptanceError.invalid("short tfdt") }
            time = u64(bytes, tfdt.payload + 4)
        } else { time = UInt64(u32(bytes, tfdt.payload + 4)) }
        var duration: UInt64 = 0
        let runs = track.filter { $0.type == "trun" }
        guard !runs.isEmpty else { throw AcceptanceError.invalid("missing trun") }
        for run in runs {
            guard run.payload + 8 <= run.end else { throw AcceptanceError.invalid("short trun") }
            let flags = u32(bytes, run.payload) & 0x00ff_ffff
            let count = u32(bytes, run.payload + 4)
            guard count > 0 && count <= 65_536 else { throw AcceptanceError.invalid("trun sample count") }
            var position = run.payload + 8
            if flags & 1 != 0 { position += 4 }
            if flags & 4 != 0 { position += 4 }
            for _ in 0..<count {
                let size = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) +
                    (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                guard position + size <= run.end else { throw AcceptanceError.invalid("short trun sample") }
                let value = flags & 0x100 != 0 ? u32(bytes, position) : durationDefault
                guard value > 0 else { throw AcceptanceError.invalid("missing native sample duration") }
                let sum = duration.addingReportingOverflow(UInt64(value))
                guard !sum.overflow else { throw AcceptanceError.invalid("native duration overflow") }
                duration = sum.partialValue
                position += size
            }
        }
        let sequence = u32(bytes, mfhd.payload + 4)
        guard sequence > 0 else { throw AcceptanceError.invalid("zero mfhd") }
        return Fragment(sequence: sequence, time: time, duration: duration)
    }
}

struct AcceptanceFragmentContinuity {
    private var lastSequence: UInt32?
    private var nextDecodeTime: UInt64?
    private(set) var rawSequenceContinuous = true
    private(set) var rawTimeContinuous = true
    mutating func observe(_ bytes: Data, defaultDuration: UInt32) throws {
        let facts = try AcceptanceMP4.fragment(bytes, defaultDuration: defaultDuration)
        if let previous = lastSequence {
            rawSequenceContinuous = rawSequenceContinuous && UInt64(facts.sequence) == UInt64(previous) + 1
        }
        if let expected = nextDecodeTime { rawTimeContinuous = rawTimeContinuous && facts.time == expected }
        let end = facts.time.addingReportingOverflow(facts.duration)
        guard !end.overflow else { throw AcceptanceError.invalid("native decode time overflow") }
        lastSequence = facts.sequence
        nextDecodeTime = end.partialValue
    }
}

final class AcceptanceSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [[String: Any]] = []
    private var failure: (any Error)?
    func append(_ value: [String: Any]) {
        lock.withLock {
            guard samples.count < 61 else { failure = AcceptanceError.invalid("sample capacity"); return }
            samples.append(value)
        }
    }
    func fail(_ error: any Error) { lock.withLock { failure = error } }
    func snapshot() throws -> [[String: Any]] {
        try lock.withLock { if let failure { throw failure }; return samples }
    }
}

/// Read-only observation preserves each admitted event and its original owner.
final class AcceptanceObservedGraph: HLSMediaGraphAssembler.DeliveryGraph, @unchecked Sendable {
    private let graph: SystemHLSDeliveryGraph
    private let lock = NSLock()
    private var packets = 0
    private var eof = false
    private var lastPacket = AcceptanceClock.now
    init(authority: SystemHLSMediaGraphAuthority) { graph = SystemHLSDeliveryGraph(authority: authority) }
    var packetCount: Int { lock.withLock { packets } }
    var hasEOF: Bool { lock.withLock { eof } }
    var lastPacketTime: Double { lock.withLock { lastPacket } }
    var failureDiagnostic: ErrorDiagnosticSnapshot? { graph.failureDiagnostic }
    func accept(_ event: AdmittedDemuxEvent) {
        event.withBorrowedEvent { borrowed in
            lock.withLock {
                switch borrowed {
                case .packet: packets += 1; lastPacket = AcceptanceClock.now
                case .endOfStream: eof = true
                default: break
                }
            }
        }
        graph.accept(event)
    }
    func waitUntilPlayablePrefix() async -> HLSMediaGraphAssembler.HLSMediaGraphPlayablePrefix? {
        await graph.waitUntilPlayablePrefix()
    }
    func finishNaturalEOF() async -> Bool { await graph.finishNaturalEOF() }
    func retireAndAwaitReceipt() async -> Bool { await graph.retireAndAwaitReceipt() }
}

/// Native negative controls and long observations share these reporting functions.
enum AcceptanceReport {
    static func audio(_ value: AcceptancePCMStatistics) -> [String: Any] {
        ["decoded_frames":value.frames,"maximum_gap_seconds":value.maximumGapSamples / 48_000,
         "interior_silent_windows":value.silentShortWindows,"checked_interior_windows":value.checkedShortWindows]
    }
    static func fragment(_ value: AcceptanceFragmentContinuity) -> [String: Any] {
        ["raw_mfhd_continuous":value.rawSequenceContinuous,"raw_tfdt_continuous":value.rawTimeContinuous]
    }
    static func sample(wall: Double, footprint: UInt64, packets: Int, eof: Bool, packetAge: Double) -> [String: Any] {
        ["wall_seconds":wall,"footprint_bytes":footprint,"producer_packets":packets,
         "producer_eof":eof,"producer_packet_age_seconds":packetAge]
    }
    #if !HLS_ACCEPTANCE_BASELINE
    static func retirement(_ value: HLSWriterAcceptanceSnapshot) -> [String: Any] {
        ["native_writer_count":value.nativeWriterCount,"final_live_inputs":value.liveInputCount,
         "final_live_bytes":value.liveInputBytes,"final_evidence":value.evidenceCount,
         "final_callbacks":value.pendingCallbacks,"allocated_inputs":value.acceptedInputCount,
         "released_inputs":value.releasedInputCount]
    }
    #endif
}

/// ContinuousClock includes suspension/sleep; media time cannot masquerade as wall time.
enum AcceptanceClock {
    private static let origin = ContinuousClock.now
    static var now: Double {
        let parts = origin.duration(to: ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
