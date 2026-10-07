// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
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
    private let connectionState = AcceptanceSourceConnections()
    private let metrics = AcceptanceTransportMetrics()
    var transportSnapshot: (bytes: Int, start: Double?) { metrics.snapshot }
    var failureDiagnostics: [String: Any] {
        let transport = metrics.snapshot
        return ["delivered_bytes":transport.bytes,"feed_started":transport.start != nil,
                "connections":connectionState.count,"source_terminal":metrics.terminal]
    }
    let sourceURL: URL

    init(fileURL: URL) throws {
        let size = try XCTUnwrap(fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        let readiness = AcceptanceListenerReadiness()
        listener.stateUpdateHandler = { state in readiness.observe(state) }
        // Network requires the accept handler before start, including the first
        // connection. Capture initialized owners without capturing partial self.
        let connectionState = self.connectionState
        let queue = self.queue
        let metrics = self.metrics
        listener.newConnectionHandler = { connection in
            guard connectionState.accept(connection) else { connection.cancel(); return }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { _, _, _, error in
                guard error == nil else {
                    metrics.end("request: \(String(describing: error))")
                    connection.cancel(); return
                }
                do {
                    let feed = try AcceptanceSourceFeed(connection: connection, file: fileURL,
                        queue: queue, metrics: metrics)
                    let header = Data(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n" +
                        "Content-Length: \(size)\r\nConnection: close\r\n\r\n").utf8)
                    connection.send(content: header, completion: .contentProcessed { error in
                        if error == nil { feed.sendNext() }
                        else { metrics.end("header: \(String(describing: error))"); feed.close() }
                    })
                } catch { metrics.end("open: \(error)"); connection.cancel() }
            }
        }
        listener.start(queue: queue)
        do {
            try readiness.wait(until: .now() + 5)
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
                throw AcceptanceError.invalid("ready source listener has no bound port")
            }
            sourceURL = url
        } catch {
            connectionState.stop()
            listener.cancel()
            throw error
        }
    }

    func stop() {
        metrics.end("server_stop")
        connectionState.stop()
        listener.cancel()
    }
}

/// A wakeup is not readiness. Freeze the first terminal startup result.
final class AcceptanceListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<Void, AcceptanceError>?
    func observe(_ state: NWListener.State) {
        let observed: Result<Void, AcceptanceError>
        switch state {
        case .ready: observed = .success(())
        case .failed(let error): observed = .failure(.invalid("source listener failed: \(ErrorDiagnosticSnapshot(error).summary)"))
        case .cancelled: observed = .failure(.invalid("source listener cancelled before ready"))
        default: return
        }
        let first = lock.withLock {
            guard result == nil else { return false }
            result = observed
            return true
        }
        if first { signal.signal() }
    }
    func wait(until deadline: DispatchTime) throws {
        guard signal.wait(timeout: deadline) == .success else {
            throw AcceptanceError.invalid("source listener readiness timed out")
        }
        guard let result = lock.withLock({ result }) else {
            throw AcceptanceError.invalid("source listener woke without a readiness result")
        }
        try result.get()
    }
}

private final class AcceptanceSourceConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var stopped = false
    var count: Int { lock.withLock { connections.count } }
    func accept(_ connection: NWConnection) -> Bool {
        lock.withLock {
            guard !stopped, connections.count < 4 else { return false }
            connections.append(connection)
            return true
        }
    }
    func stop() {
        let pending = lock.withLock {
            stopped = true
            defer { connections.removeAll() }
            return connections
        }
        for connection in pending { connection.cancel() }
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
        guard AcceptanceClock.now - started < 299.5 else { metrics.end("feed_deadline"); close(); return }
        do {
            guard let bytes = try handle.read(upToCount: 188 * 100), !bytes.isEmpty else { metrics.end("file_eof"); close(); return }
            sent += bytes.count
            connection.send(content: bytes, completion: .contentProcessed { [self] error in
                guard error == nil else { metrics.end("send: \(String(describing: error))"); close(); return }
                metrics.delivered(bytes.count)
                let target = started + Double(sent) / 4_750_000
                queue.asyncAfter(deadline: .now() + max(0, target - AcceptanceClock.now)) {
                    self.sendNext()
                }
            })
        } catch { metrics.end("read: \(error)"); close() }
    }

    func close() { try? handle.close(); connection.cancel() }
}

private final class AcceptanceTransportMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var start: Double?
    private var firstTerminal: String?
    var terminal: String { lock.withLock { firstTerminal ?? "active" } }
    func end(_ reason: String) { lock.withLock { if firstTerminal == nil { firstTerminal = String(reason.prefix(384)) } } }
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
        var initializationFormat: [String: Any] = [:]
        var defaultDuration: UInt32 = 0
        var sampleDefaults: AcceptanceMP4.SampleDefaults?
        var rawSamplesURL: URL?
        var rawSamplesHandle: FileHandle?
        var rawSampleCount = 0
        var latestMediaTimescale: UInt32?
        var lastInitializationBeforeFragment = 0
        var lastReportStart: CMTime?
        var lastReportDuration: CMTime?
        var continuity = AcceptanceFragmentContinuity()
    }
    private let lock = NSLock()
    private let directory: URL
    private let rawSampleRecordLimit: Int
    private var tracks: [String: Track] = [:]
    private var failure: (any Error)?
    private var copiedBytes = 0
    private var closed = false

    init(directory: URL, rawSampleRecordLimit: Int = AcceptanceRawVideoSample.maximumRecords) {
        self.directory = directory
        // Controls may lower the limit, never raise the fixed physical bound.
        self.rawSampleRecordLimit = min(rawSampleRecordLimit, AcceptanceRawVideoSample.maximumRecords)
    }

    func receive(_ object: SealedMediaObject) {
        lock.withLock {
            guard !closed, failure == nil else { return }
            do {
                let codec = object.publicationEvidence?.format.codec ?? ""
                let kind = object.report.mediaType == .audio || codec == "mp4a.40.2" ? "audio" : "video"
                if tracks[kind] == nil {
                    guard tracks.count < 2 else { throw AcceptanceError.invalid("unexpected rendition") }
                    let url = directory.appendingPathComponent("original-\(kind).mp4")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw AcceptanceError.invalid("cannot create original capture")
                    }
                    var created = Track(kind: kind, url: url, handle: try FileHandle(forWritingTo: url))
                    if kind == "video" {
                        let samplesURL = directory.appendingPathComponent("original-video-samples.bin")
                        guard FileManager.default.createFile(atPath: samplesURL.path, contents: nil) else {
                            throw AcceptanceError.invalid("cannot create raw sample evidence")
                        }
                        created.rawSamplesURL = samplesURL
                        created.rawSamplesHandle = try FileHandle(forWritingTo: samplesURL)
                    }
                    tracks[kind] = created
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
                    track.lastInitializationBeforeFragment = track.fragments
                    // Diagnostic only: an unavailable timescale cannot change admission.
                    track.latestMediaTimescale = try? AcceptanceMP4.mediaTimescale(bytes)
                    if track.inits == 1 {
                        if kind == "video" {
                            do { track.initializationFormat = try AcceptanceMP4.videoConfiguration(bytes) }
                            catch { track.initializationFormat = ["diagnostic_error":ErrorDiagnosticSnapshot(error).summary] }
                            do { track.initializationFormat["timeline"] = try AcceptanceMP4.videoTimelineMetadata(bytes) }
                            catch { track.initializationFormat["timeline_error"] = ErrorDiagnosticSnapshot(error).summary }
                        }
                        if let format = object.publicationEvidence?.format {
                            track.initializationFormat["writer_source_subtype"] = AcceptanceReport.fourCC(format.sampleEntry)
                            track.initializationFormat["writer_declared_codec"] = format.codec
                        }
                        track.defaultDuration = try AcceptanceMP4.defaultDuration(bytes)
                        if kind == "video" { track.sampleDefaults = try AcceptanceMP4.sampleDefaults(bytes) }
                        try track.handle.write(contentsOf: bytes)
                    }
                } else {
                    if let handle = track.rawSamplesHandle {
                        let defaults = try XCTUnwrap(track.sampleDefaults)
                        let recordLimit = rawSampleRecordLimit
                        var count = track.rawSampleCount
                        try track.continuity.observe(bytes, defaultDuration: track.defaultDuration,
                            sampleDefaults: defaults) { sample in
                            guard count < recordLimit else {
                                throw AcceptanceError.invalid("raw sample evidence capacity")
                            }
                            try handle.write(contentsOf: sample.encoded())
                            count += 1
                        }
                        track.rawSampleCount = count
                    } else { try track.continuity.observe(bytes, defaultDuration: track.defaultDuration) }
                    track.fragments += 1
                    track.lastReportStart = object.report.earliestPresentationTimeStamp
                    track.lastReportDuration = object.report.duration
                    try track.handle.write(contentsOf: bytes)
                }
                tracks[kind] = track
            } catch {
                if failure == nil { failure = error }
                // A fragment may already have appended records before failing.
                // Revoke further physical writes instead of retrying stale counts.
                closeLocked()
            }
        }
    }

    var failureDiagnostics: [String: Any] {
        lock.withLock {
            ["copied_bytes":copiedBytes,
             "error":failure.map { ErrorDiagnosticSnapshot($0).summary } ?? "none",
             "tracks":tracks.values.sorted { $0.kind < $1.kind }.map { track -> [String: Any] in
                 ["kind":track.kind,"inits":track.inits,"fragments":track.fragments,
                  "writer_count":track.writers.count,"initialization_format":track.initializationFormat,
                  "raw_sample_records":track.rawSampleCount,
                  "last_init_before_fragment":track.lastInitializationBeforeFragment,
                  "raw":track.continuity.failureDiagnostics(timescale: track.latestMediaTimescale),
                  "last_report_start":track.lastReportStart.map { AcceptanceReport.time($0) as Any } ?? NSNull(),
                  "last_report_duration":track.lastReportDuration.map { AcceptanceReport.time($0) as Any } ?? NSNull()]
             }]
        }
    }

    func finish() throws -> [Track] {
        try lock.withLock {
            defer { closeLocked() }
            if let failure { throw failure }
            for track in tracks.values {
                try track.handle.synchronize()
                try track.rawSamplesHandle?.synchronize()
            }
            return tracks.values.sorted { $0.kind < $1.kind }
        }
    }
    func close() { lock.withLock { closeLocked() } }
    private func closeLocked() {
        guard !closed else { return }
        closed = true
        for track in tracks.values { try? track.handle.close(); try? track.rawSamplesHandle?.close() }
    }
}

/// Strict read-only MP4 facts, including tfhd/trex duration defaults.
enum AcceptanceMP4 {
    struct Box { let type: String; let start: Int; let payload: Int; let end: Int }
    struct SampleDefaults { let trackID: UInt32; let duration: UInt32; let size: UInt32 }
    struct Fragment {
        let sequence: UInt32; let time: UInt64; let duration: UInt64; let sampleCount: Int
        let presentationMatchesDecode: Bool
    }

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
                start: position, payload: position + header, end: position + size))
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
        try sampleDefaults(bytes).duration
    }
    static func sampleDefaults(_ bytes: Data) throws -> SampleDefaults {
        let moov = try one("moov", boxes(bytes))
        let mvex = try one("mvex", boxes(bytes, moov.payload, moov.end))
        let trex = try one("trex", boxes(bytes, mvex.payload, mvex.end))
        guard trex.payload + 24 <= trex.end else { throw AcceptanceError.invalid("short trex") }
        return SampleDefaults(trackID: u32(bytes, trex.payload + 4),
            duration: u32(bytes, trex.payload + 12), size: u32(bytes, trex.payload + 16))
    }
    static func videoConfiguration(_ bytes: Data) throws -> [String: Any] {
        let moov = try one("moov", boxes(bytes))
        let trak = try one("trak", boxes(bytes, moov.payload, moov.end))
        let mdia = try one("mdia", boxes(bytes, trak.payload, trak.end))
        let minf = try one("minf", boxes(bytes, mdia.payload, mdia.end))
        let stbl = try one("stbl", boxes(bytes, minf.payload, minf.end))
        let stsd = try one("stsd", boxes(bytes, stbl.payload, stbl.end))
        guard stsd.payload + 8 <= stsd.end, u32(bytes, stsd.payload + 4) == 1 else {
            throw AcceptanceError.invalid("video diagnostic stsd entry count")
        }
        let entries = try boxes(bytes, stsd.payload + 8, stsd.end)
        guard entries.count == 1, let entry = entries.first, entry.payload + 78 <= entry.end else {
            throw AcceptanceError.invalid("video diagnostic sample entry")
        }
        var result: [String: Any] = ["sample_entry":entry.type]
        for box in try boxes(bytes, entry.payload + 78, entry.end) where ["avcC", "hvcC"].contains(box.type) {
            guard box.end - box.payload <= 65_536 else {
                result[box.type] = ["bytes":box.end - box.payload,"diagnostic_omitted":true]
                continue
            }
            let payload = bytes.subdata(in: box.payload..<box.end)
            result[box.type] = AcceptanceReport.configuration(payload)
        }
        return result
    }

    static func mediaTimescale(_ bytes: Data) throws -> UInt32 {
        let moov = try one("moov", boxes(bytes))
        let trak = try one("trak", boxes(bytes, moov.payload, moov.end))
        let mdia = try one("mdia", boxes(bytes, trak.payload, trak.end))
        let mdhd = try one("mdhd", boxes(bytes, mdia.payload, mdia.end))
        guard mdhd.payload + 4 <= mdhd.end, bytes[mdhd.payload] <= 1 else {
            throw AcceptanceError.invalid("short/unsupported mdhd")
        }
        let offset = mdhd.payload + (bytes[mdhd.payload] == 0 ? 12 : 20)
        guard offset + 4 <= mdhd.end else { throw AcceptanceError.invalid("short mdhd timescale") }
        let timescale = u32(bytes, offset)
        guard timescale > 0 else { throw AcceptanceError.invalid("zero mdhd timescale") }
        return timescale
    }

    /// Diagnostic only. Preserve the actual native edit metadata without assuming
    /// that an edit list exists or using these bytes to guess a reader offset.
    static func videoTimelineMetadata(_ bytes: Data) throws -> [String: Any] {
        let moov = try one("moov", boxes(bytes))
        let movie = try boxes(bytes, moov.payload, moov.end)
        let trak = try one("trak", movie)
        let track = try boxes(bytes, trak.payload, trak.end)
        let mvhd = try one("mvhd", movie)
        guard mvhd.payload + 4 <= mvhd.end, bytes[mvhd.payload] <= 1 else {
            throw AcceptanceError.invalid("short/unsupported diagnostic mvhd")
        }
        let scaleOffset = mvhd.payload + (bytes[mvhd.payload] == 0 ? 12 : 20)
        guard scaleOffset + 4 <= mvhd.end else { throw AcceptanceError.invalid("short diagnostic movie timescale") }
        let edits = track.filter { $0.type == "edts" }
        guard edits.count <= 1 else { throw AcceptanceError.invalid("duplicate diagnostic edts") }
        var result: [String: Any] = ["movie_timescale":u32(bytes, scaleOffset),
            "media_timescale":try mediaTimescale(bytes),"edit_container_count":edits.count]
        guard let edit = edits.first else { return result }
        let list = try one("elst", boxes(bytes, edit.payload, edit.end))
        guard list.payload + 8 <= list.end, bytes[list.payload] <= 1 else {
            throw AcceptanceError.invalid("short/unsupported diagnostic elst")
        }
        let version = bytes[list.payload]
        let count = u32(bytes, list.payload + 4)
        result["edit_version"] = version
        result["edit_count"] = count
        let entrySize = version == 0 ? 12 : 20
        guard count <= 8, Int(count) * entrySize == list.end - list.payload - 8 else {
            throw AcceptanceError.invalid("diagnostic edit list bounds")
        }
        var entries: [[String: Any]] = []
        for index in 0..<Int(count) {
            let offset = list.payload + 8 + index * entrySize
            let duration = version == 0 ? UInt64(u32(bytes, offset)) : u64(bytes, offset)
            let mediaTime = version == 0 ? Int64(Int32(bitPattern: u32(bytes, offset + 4))) :
                Int64(bitPattern: u64(bytes, offset + 8))
            entries.append(["duration_movie_ticks":duration,"media_time_ticks":mediaTime,
                "rate_16_16_bits":u32(bytes, offset + entrySize - 4)])
        }
        result["edits"] = entries
        return result
    }

    static func fragment(_ bytes: Data, defaultDuration: UInt32, sampleDefaults: SampleDefaults? = nil,
        onSample: ((AcceptanceRawVideoSample) throws -> Void)? = nil) throws -> Fragment {
        let top = try boxes(bytes)
        let mdat = try one("mdat", top)
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
        var sizeDefault = sampleDefaults?.size ?? 0
        let flags = u32(bytes, tfhd.payload) & 0x00ff_ffff
        if onSample != nil {
            guard let sampleDefaults, sampleDefaults.trackID == u32(bytes, tfhd.payload + 4), flags & 1 == 0 else {
                throw AcceptanceError.invalid("raw sample track/relative addressing unavailable")
            }
        }
        var position = tfhd.payload + 8
        if flags & 1 != 0 { position += 8 }
        if flags & 2 != 0 { position += 4 }
        if flags & 8 != 0 {
            guard position + 4 <= tfhd.end else { throw AcceptanceError.invalid("short tfhd duration") }
            durationDefault = u32(bytes, position)
            position += 4
        }
        if flags & 0x10 != 0 {
            guard position + 4 <= tfhd.end else { throw AcceptanceError.invalid("short tfhd sample size") }
            sizeDefault = u32(bytes, position); position += 4
        }
        if flags & 0x20 != 0 { position += 4 }
        guard position <= tfhd.end else { throw AcceptanceError.invalid("short tfhd defaults") }
        let time: UInt64
        if bytes[tfdt.payload] == 1 {
            guard tfdt.payload + 12 <= tfdt.end else { throw AcceptanceError.invalid("short tfdt") }
            time = u64(bytes, tfdt.payload + 4)
        } else { time = UInt64(u32(bytes, tfdt.payload + 4)) }
        var duration: UInt64 = 0
        var sampleCount = 0
        var presentationMatchesDecode = true
        var dataPosition: Int?
        let runs = track.filter { $0.type == "trun" }
        guard !runs.isEmpty else { throw AcceptanceError.invalid("missing trun") }
        for run in runs {
            guard run.payload + 8 <= run.end else { throw AcceptanceError.invalid("short trun") }
            let flags = u32(bytes, run.payload) & 0x00ff_ffff
            let count = u32(bytes, run.payload + 4)
            guard count > 0 && count <= 65_536 else { throw AcceptanceError.invalid("trun sample count") }
            let total = sampleCount.addingReportingOverflow(Int(count))
            guard !total.overflow else { throw AcceptanceError.invalid("native sample count overflow") }
            sampleCount = total.partialValue
            var position = run.payload + 8
            if flags & 1 != 0 {
                guard position + 4 <= run.end else { throw AcceptanceError.invalid("short trun data offset") }
                // One traf and no absolute base: ISO BMFF defines the base as
                // this moof, including when default-base-is-moof is implicit.
                dataPosition = moof.start + Int(Int32(bitPattern: u32(bytes, position)))
                position += 4
            }
            if flags & 4 != 0 { position += 4 }
            for _ in 0..<count {
                let size = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) +
                    (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                guard position + size <= run.end else { throw AcceptanceError.invalid("short trun sample") }
                let value = flags & 0x100 != 0 ? u32(bytes, position) : durationDefault
                guard value > 0 else { throw AcceptanceError.invalid("missing native sample duration") }
                let sum = duration.addingReportingOverflow(UInt64(value))
                guard !sum.overflow else { throw AcceptanceError.invalid("native duration overflow") }
                if flags & 0x800 != 0 {
                    // The acceptance fixture has no reordered frames. A nonzero
                    // composition offset makes tfdt unsuitable as a raw PTS.
                    presentationMatchesDecode = presentationMatchesDecode && u32(bytes, position + size - 4) == 0
                }
                if let onSample {
                    let sampleSizeOffset = position + (flags & 0x100 != 0 ? 4 : 0)
                    let sampleSize = flags & 0x200 != 0 ? u32(bytes, sampleSizeOffset) : sizeDefault
                    guard presentationMatchesDecode, sampleSize > 0, let dataStart = dataPosition,
                          dataStart >= mdat.payload, dataStart <= mdat.end,
                          Int(sampleSize) <= mdat.end - dataStart else {
                        throw AcceptanceError.invalid("raw sample payload range or composition time unavailable")
                    }
                    let timestamp = time.addingReportingOverflow(duration)
                    guard !timestamp.overflow else { throw AcceptanceError.invalid("raw sample timestamp overflow") }
                    let dataEnd = dataStart + Int(sampleSize)
                    var hasher = SHA256()
                    bytes.withUnsafeBytes { buffer in
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[dataStart..<dataEnd]))
                    }
                    try onSample(AcceptanceRawVideoSample(time: timestamp.partialValue, duration: value,
                        size: sampleSize, digest: Data(hasher.finalize())))
                    dataPosition = dataEnd
                }
                duration = sum.partialValue
                position += size
            }
        }
        let sequence = u32(bytes, mfhd.payload + 4)
        guard sequence > 0 else { throw AcceptanceError.invalid("zero mfhd") }
        return Fragment(sequence: sequence, time: time, duration: duration, sampleCount: sampleCount,
            presentationMatchesDecode: presentationMatchesDecode)
    }
}

/// Fixed-size disk evidence emitted in raw trun/decode order. The same 65,536
/// sample ceiling used by the parser bounds the entire finite acceptance sidecar
/// to 3 MiB; no sample payload or growing evidence array is retained.
struct AcceptanceRawVideoSample {
    static let recordBytes = 48
    static let maximumRecords = 65_536
    let time: UInt64
    let duration: UInt32
    let size: UInt32
    let digest: Data
    init(time: UInt64, duration: UInt32, size: UInt32, digest: Data) {
        self.time = time; self.duration = duration; self.size = size; self.digest = digest
    }
    init(encoded: Data) throws {
        guard encoded.count == Self.recordBytes else { throw AcceptanceError.invalid("incomplete raw sample evidence") }
        time = AcceptanceMP4.u64(encoded, 0)
        duration = AcceptanceMP4.u32(encoded, 8)
        size = AcceptanceMP4.u32(encoded, 12)
        digest = encoded.subdata(in: 16..<48)
    }
    func encoded() throws -> Data {
        guard digest.count == 32, duration > 0, size > 0 else { throw AcceptanceError.invalid("invalid raw sample evidence") }
        var result = Data(capacity: Self.recordBytes)
        var time = self.time.bigEndian; var duration = self.duration.bigEndian; var size = self.size.bigEndian
        withUnsafeBytes(of: &time) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &duration) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(digest)
        return result
    }
}

/// Every compressed reader sample is associated with the next raw sample ordinal
/// by exact size and SHA-256 before any timestamp translation is derived or used.
/// Duplicate payloads cannot select another ordinal. Every duration and translated
/// timestamp must match, so a first-frame-only offset never establishes coverage.
struct AcceptanceVideoByteTiming {
    struct ReaderSample {
        var size: Int
        var digest: Data
        var pts: CMTime
        var duration: CMTime
    }
    let timescale: Int32
    private(set) var frames = 0
    private var translation: ExactMediaTime?
    private var firstRaw: ExactMediaTime?
    private var rawEnd: ExactMediaTime?
    private var readerEnd: ExactMediaTime?
    private var latest: [String: Any] = [:]
    init(timescale: Int32) { self.timescale = timescale }
    mutating func observe(raw: AcceptanceRawVideoSample, reader: ReaderSample) throws {
        latest = ["ordinal":frames,"raw_ticks":raw.time,"raw_duration_ticks":raw.duration,
            "raw_size":raw.size,"reader_size":reader.size,"reader_pts":AcceptanceReport.time(reader.pts),
            "reader_duration":AcceptanceReport.time(reader.duration),
            "raw_sha256":raw.digest.map { String(format: "%02x", $0) }.joined(),
            "reader_sha256":reader.digest.map { String(format: "%02x", $0) }.joined()]
        guard timescale > 0, frames < AcceptanceRawVideoSample.maximumRecords,
              raw.digest.count == 32, raw.digest == reader.digest, raw.size > 0,
              Int(raw.size) == reader.size, raw.duration > 0, let ticks = Int64(exactly: raw.time) else {
            throw AcceptanceError.invalid("compressed reader does not match the next raw sample payload")
        }
        let rawPTS = ExactMediaTime(value: ticks, timescale: timescale)
        let rawDuration = ExactMediaTime(value: Int64(raw.duration), timescale: timescale)
        let readerPTS = try ExactMediaTime(reader.pts)
        let readerDuration = try ExactMediaTime(reader.duration)
        guard rawDuration == readerDuration else { throw AcceptanceError.invalid("raw/reader sample duration mismatch") }
        let candidate = try readerPTS.subtracting(rawPTS)
        if let translation {
            guard translation == candidate else { throw AcceptanceError.invalid("raw/reader timestamp translation changed") }
        }
        if let rawEnd, let readerEnd {
            guard rawEnd == rawPTS, readerEnd == readerPTS else {
                throw AcceptanceError.invalid("raw/reader sample ordinal has a gap or overlap")
            }
        }
        let nextRawEnd = try rawPTS.adding(rawDuration)
        let nextReaderEnd = try readerPTS.adding(readerDuration)
        if firstRaw == nil { firstRaw = rawPTS }
        translation = candidate; rawEnd = nextRawEnd; readerEnd = nextReaderEnd
        frames += 1
    }
    func presentationTime(forRawTime time: CMTime) throws -> CMTime {
        let raw = try ExactMediaTime(time)
        guard frames > 0, let translation, let firstRaw, let rawEnd,
              CMTimeCompare(raw.cmTime, firstRaw.cmTime) >= 0,
              CMTimeCompare(raw.cmTime, rawEnd.cmTime) <= 0 else {
            throw AcceptanceError.invalid("raw endpoint lacks complete byte-verified sample coverage")
        }
        return try raw.adding(translation).cmTime
    }
    var diagnostics: [String: Any] {
        ["authority":"every raw trun/mdat sample matched by ordinal, size, SHA-256 and exact duration",
         "verified_samples":frames,"record_limit":AcceptanceRawVideoSample.maximumRecords,
         "translation":translation.map { AcceptanceReport.time($0.cmTime) as Any } ?? NSNull(),
         "latest":latest]
    }
}

final class AcceptanceRawVideoReader {
    private let handle: FileHandle
    private(set) var timing: AcceptanceVideoByteTiming
    init(url: URL, timescale: UInt32) throws {
        guard let scale = Int32(exactly: timescale), scale > 0 else {
            throw AcceptanceError.invalid("raw video evidence timescale unavailable")
        }
        handle = try FileHandle(forReadingFrom: url)
        timing = AcceptanceVideoByteTiming(timescale: scale)
    }
    deinit { try? handle.close() }
    func close() { try? handle.close() }
    func observe(reader: AcceptanceVideoByteTiming.ReaderSample) throws {
        guard let bytes = try handle.read(upToCount: AcceptanceRawVideoSample.recordBytes), !bytes.isEmpty else {
            throw AcceptanceError.invalid("compressed reader sample has no raw sample ordinal")
        }
        try timing.observe(raw: AcceptanceRawVideoSample(encoded: bytes), reader: reader)
    }
    func observe(original: CMSampleBuffer) throws {
        let size = CMSampleBufferGetTotalSampleSize(original)
        guard CMSampleBufferGetNumSamples(original) == 1, size > 0,
              let block = CMSampleBufferGetDataBuffer(original), CMBlockBufferGetDataLength(block) >= size else {
            throw AcceptanceError.invalid("compressed reader payload unavailable")
        }
        let digest = try withExtendedLifetime(block) {
            var hasher = SHA256()
            var offset = 0
            while offset < size {
                var length = 0; var total = 0; var pointer: UnsafeMutablePointer<CChar>?
                let status = CMBlockBufferGetDataPointer(block, atOffset: offset,
                    lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &pointer)
                guard status == noErr, let pointer, total >= size, length > 0, length <= total - offset else {
                    throw AcceptanceError.invalid("compressed reader payload borrow failed")
                }
                let count = min(length, size - offset)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: count))
                offset += count
            }
            return Data(hasher.finalize())
        }
        try observe(reader: .init(size: size, digest: digest,
            pts: CMSampleBufferGetPresentationTimeStamp(original), duration: CMSampleBufferGetDuration(original)))
    }
    func finish() throws {
        defer { close() }
        guard timing.frames > 0, try handle.read(upToCount: 1)?.isEmpty != false else {
            throw AcceptanceError.invalid("raw sample evidence has unread records")
        }
    }
}

/// Native metadata describes the normalized track timeline, not the raw tfdt origin.
/// https://developer.apple.com/documentation/avfoundation/avpartialasyncproperty/segments
/// https://developer.apple.com/documentation/coremedia/cmtimemapping/source
/// Only a single nonempty unit-rate mapping is supported. All retained state is scalar.
struct AcceptanceVideoTimelineMapping {
    struct Segment: Sendable {
        let source: CMTimeRange
        let target: CMTimeRange
        let isEmpty: Bool
    }
    let segmentCount: Int
    let segment: Segment?

    init(segmentCount: Int, segment: Segment?) {
        self.segmentCount = segmentCount; self.segment = segment
    }
    init(segments: [AVAssetTrackSegment]) {
        segmentCount = segments.count
        // Retain at most one scalar snapshot, even for an unsupported edit list.
        segment = segments.first.map {
            Segment(source: $0.timeMapping.source, target: $0.timeMapping.target, isEmpty: $0.isEmpty)
        }
    }
    func presentationTime(forMediaTime time: CMTime) throws -> CMTime {
        guard segmentCount == 1, let segment, !segment.isEmpty else {
            throw AcceptanceError.invalid("video requires one nonempty native timeline mapping")
        }
        let sourceStart = try ExactMediaTime(segment.source.start)
        let targetStart = try ExactMediaTime(segment.target.start)
        let sourceDuration = try ExactMediaTime(segment.source.duration)
        let targetDuration = try ExactMediaTime(segment.target.duration)
        guard sourceDuration.value > 0, sourceDuration == targetDuration else {
            throw AcceptanceError.invalid("video native timeline mapping must have positive unit rate")
        }
        let sourceEnd = try sourceStart.adding(sourceDuration)
        _ = try targetStart.adding(targetDuration)
        let mediaTime = try ExactMediaTime(time)
        // The last exclusive sample endpoint may equal sourceEnd. Never
        // extrapolate a translation past the metadata's covered media range.
        guard CMTimeCompare(mediaTime.cmTime, sourceStart.cmTime) >= 0,
              CMTimeCompare(mediaTime.cmTime, sourceEnd.cmTime) <= 0 else {
            throw AcceptanceError.invalid("raw video endpoint is outside the native mapping")
        }
        return try targetStart.adding(mediaTime.subtracting(sourceStart)).cmTime
    }
    func requirePresentationCoverage(first: CMTime, end: CMTime) throws {
        guard let segment else { throw AcceptanceError.invalid("missing native track mapping") }
        let sourceEnd = try ExactMediaTime(segment.source.start).adding(ExactMediaTime(segment.source.duration)).cmTime
        guard CMTimeCompare(first, try presentationTime(forMediaTime: segment.source.start)) == 0,
              CMTimeCompare(end, try presentationTime(forMediaTime: sourceEnd)) == 0 else {
            throw AcceptanceError.invalid("reader does not cover the native track timeline")
        }
    }
    var diagnostics: [String: Any] {
        var result: [String: Any] = ["authority":"AVAssetTrack.segments normalized track metadata, not raw tfdt origin",
            "segment_count":segmentCount]
        if let segment {
            result["is_empty"] = segment.isEmpty
            result["source_start"] = AcceptanceReport.time(segment.source.start)
            result["source_duration"] = AcceptanceReport.time(segment.source.duration)
            result["target_start"] = AcceptanceReport.time(segment.target.start)
            result["target_duration"] = AcceptanceReport.time(segment.target.duration)
        }
        return result
    }
}

struct AcceptanceFragmentContinuity {
    private var lastSequence: UInt32?
    private var nextDecodeTime: UInt64?
    private var firstDecodeTime: UInt64?
    private var totalSamples = 0
    private var lastDecodeTime: UInt64?
    private var lastDuration: UInt64?
    private(set) var rawSequenceContinuous = true
    private(set) var rawTimeContinuous = true
    private(set) var rawPresentationMatchesDecode = true
    mutating func observe(_ bytes: Data, defaultDuration: UInt32, sampleDefaults: AcceptanceMP4.SampleDefaults? = nil,
        onSample: ((AcceptanceRawVideoSample) throws -> Void)? = nil) throws {
        let facts = try AcceptanceMP4.fragment(bytes, defaultDuration: defaultDuration,
            sampleDefaults: sampleDefaults, onSample: onSample)
        rawPresentationMatchesDecode = rawPresentationMatchesDecode && facts.presentationMatchesDecode
        if let previous = lastSequence {
            rawSequenceContinuous = rawSequenceContinuous && UInt64(facts.sequence) == UInt64(previous) + 1
        }
        if let expected = nextDecodeTime { rawTimeContinuous = rawTimeContinuous && facts.time == expected }
        let end = facts.time.addingReportingOverflow(facts.duration)
        guard !end.overflow else { throw AcceptanceError.invalid("native decode time overflow") }
        let samples = totalSamples.addingReportingOverflow(facts.sampleCount)
        guard !samples.overflow else { throw AcceptanceError.invalid("native total sample count overflow") }
        totalSamples = samples.partialValue
        if firstDecodeTime == nil { firstDecodeTime = facts.time }
        lastSequence = facts.sequence
        lastDecodeTime = facts.time
        lastDuration = facts.duration
        nextDecodeTime = end.partialValue
    }

    func requireVideoCoverage(_ timing: AcceptanceVideoTiming, timescale: UInt32?,
        mapping: AcceptanceVideoTimelineMapping, byteTiming: AcceptanceVideoByteTiming) throws {
        guard rawSequenceContinuous, rawTimeContinuous, rawPresentationMatchesDecode, totalSamples > 0,
              timing.frames == totalSamples, byteTiming.frames == totalSamples,
              let first = firstDecodeTime, let end = nextDecodeTime,
              let startTicks = Int64(exactly: first), let endTicks = Int64(exactly: end),
              let timescale, let scale = Int32(exactly: timescale), scale > 0,
              let firstPTS = timing.firstPTS, let lastEnd = timing.lastEnd else {
            throw AcceptanceError.invalid("decoded video does not cover every raw fragment sample and endpoint")
        }
        let mappedFirst = try byteTiming.presentationTime(forRawTime: CMTime(value: startTicks, timescale: scale))
        let mappedEnd = try byteTiming.presentationTime(forRawTime: CMTime(value: endTicks, timescale: scale))
        guard CMTimeCompare(firstPTS, mappedFirst) == 0, CMTimeCompare(lastEnd, mappedEnd) == 0 else {
            throw AcceptanceError.invalid("decoded video does not cover the mapped raw fragment endpoints")
        }
        try mapping.requirePresentationCoverage(first: firstPTS, end: lastEnd)
    }

    func failureDiagnostics(timescale: UInt32?, mapping: AcceptanceVideoTimelineMapping? = nil,
        byteTiming: AcceptanceVideoByteTiming? = nil) -> [String: Any] {
        let scale = timescale.flatMap { $0 > 0 ? Double($0) : nil }
        let endSeconds = scale.flatMap { scale in nextDecodeTime.map { Double($0) / scale } }
        var result: [String: Any] = ["raw_mfhd_continuous":rawSequenceContinuous,"raw_tfdt_continuous":rawTimeContinuous,
                "raw_presentation_matches_decode":rawPresentationMatchesDecode,
                "raw_sample_count":totalSamples,
                "first_raw_tfdt":firstDecodeTime.map { $0 as Any } ?? NSNull(),
                "last_raw_mfhd":lastSequence.map { $0 as Any } ?? NSNull(),
                "last_raw_tfdt":lastDecodeTime.map { $0 as Any } ?? NSNull(),
                "last_raw_duration":lastDuration.map { $0 as Any } ?? NSNull(),
                "last_raw_end":nextDecodeTime.map { $0 as Any } ?? NSNull(),
                "latest_init_timescale":timescale.map { $0 as Any } ?? NSNull(),
                "last_raw_end_seconds":AcceptanceReport.finite(endSeconds)]
        if let mapping {
            result["timeline_mapping"] = mapping.diagnostics
        }
        if let byteTiming {
            result["byte_timing"] = byteTiming.diagnostics
            if let timescale, let scale = Int32(exactly: timescale), scale > 0 {
                for (key, value) in [("mapped_first_raw_pts", firstDecodeTime), ("mapped_last_raw_end", nextDecodeTime)] {
                    if let value, let ticks = Int64(exactly: value),
                       let mapped = try? byteTiming.presentationTime(forRawTime: CMTime(value: ticks, timescale: scale)) {
                        result[key] = AcceptanceReport.time(mapped)
                    }
                }
            }
        }
        return result
    }
}

/// AVAssetReader emits timed, payload-free markers as well as media, including
/// decoded output: https://developer.apple.com/videos/play/wwdc2020/10090/ (8:57).
/// The typed content discriminator rules out tagged and sample-reference payloads:
/// https://developer.apple.com/documentation/coremedia/cmsamplebuffer/contenttype-swift.enum/markeronly
/// This acceptance cursor skips only zero-duration/untimed markers, not media gaps.
/// It retains scalar evidence only; reader calls and owned copies stay at the caller.
struct AcceptanceVideoReaderCursor {
    enum Kind: Equatable { case decoded, original }
    struct Snapshot: Sendable {
        var count: Int
        var contentType: CMSampleBuffer.ContentType
        var duration: CMTime
        var valid = true
        var ready = true
        var totalSize = 0
        var blockSize: Int?
        var hasImage = false
        var hasFormat = false
    }
    // A finite run permits ordinary start/end state markers without allowing a
    // broken provider to spin forever before a media sample or terminal nil.
    static let maximumConsecutiveMarkers = 8
    let kind: Kind
    private(set) var skippedMarkers = 0
    private(set) var consecutiveMarkers = 0
    private(set) var maximumMarkerRun = 0
    private var latest: Snapshot?

    init(kind: Kind) { self.kind = kind }

    var diagnostics: [String: Any] {
        var value: [String: Any] = ["skipped_markers":skippedMarkers,
            "consecutive_markers":consecutiveMarkers,"maximum_marker_run":maximumMarkerRun,
            "marker_run_limit":Self.maximumConsecutiveMarkers]
        if let latest {
            value["latest"] = ["count":latest.count,"content_type":String(describing: latest.contentType),
                "duration":AcceptanceReport.time(latest.duration),"valid":latest.valid,"ready":latest.ready,
                "total_size":latest.totalSize,"block_size":latest.blockSize.map { $0 as Any } ?? NSNull(),
                "has_image":latest.hasImage,"has_format":latest.hasFormat]
        }
        return value
    }

    mutating func consumesMedia(_ ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws -> Bool {
        let contentType = ready.contentType
        let snapshot = ready.withUnsafeSampleBuffer { sample in
            Snapshot(count: CMSampleBufferGetNumSamples(sample), contentType: contentType,
                duration: CMSampleBufferGetDuration(sample), valid: CMSampleBufferIsValid(sample),
                ready: CMSampleBufferDataIsReady(sample), totalSize: CMSampleBufferGetTotalSampleSize(sample),
                blockSize: CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) },
                hasImage: CMSampleBufferGetImageBuffer(sample) != nil,
                hasFormat: CMSampleBufferGetFormatDescription(sample) != nil)
        }
        return try consumesMedia(snapshot)
    }

    mutating func consumesMedia(_ sample: Snapshot) throws -> Bool {
        latest = sample
        guard sample.valid, sample.ready, sample.count >= 0 else {
            throw AcceptanceError.invalid("\(kind) video reader returned an invalid buffer")
        }
        if sample.count == 0 {
            guard sample.contentType == .markerOnly, sample.totalSize == 0,
                  sample.blockSize == nil, !sample.hasImage, !sample.hasFormat,
                  !sample.duration.isValid || (sample.duration.isNumeric && sample.duration.epoch == 0 &&
                      CMTimeCompare(sample.duration, .zero) == 0) else {
                throw AcceptanceError.invalid("\(kind) video reader empty buffer carries media or duration")
            }
            guard consecutiveMarkers < Self.maximumConsecutiveMarkers else {
                throw AcceptanceError.invalid("\(kind) video reader marker run exceeded its bound")
            }
            consecutiveMarkers += 1
            skippedMarkers += 1
            maximumMarkerRun = max(maximumMarkerRun, consecutiveMarkers)
            return false
        }
        guard sample.count == 1, sample.hasFormat else {
            throw AcceptanceError.invalid("\(kind) video reader must return one formatted media sample")
        }
        switch kind {
        case .decoded:
            guard sample.contentType == .pixelBuffer, sample.hasImage,
                  sample.blockSize == nil else {
                throw AcceptanceError.invalid("decoded video reader sample has no sole image payload")
            }
        case .original:
            // A reader may expose more logical backing than the declared sample
            // uses. Require enough bytes, without imposing an undocumented equality.
            guard sample.contentType == .dataBuffer, !sample.hasImage, sample.totalSize > 0,
                  let blockSize = sample.blockSize, blockSize >= sample.totalSize else {
                throw AcceptanceError.invalid("original video reader sample has inconsistent compressed backing")
            }
        }
        consecutiveMarkers = 0
        return true
    }
}

/// One decoded image must match one original compressed sample. The original
/// container duration is authoritative when AVAssetReader omits image duration.
/// Only timing scalars survive each pair; no media owner or nominal FPS is used.
struct AcceptanceVideoTiming {
    private(set) var frames = 0
    private(set) var firstPTS: CMTime?
    private(set) var lastEnd: CMTime?
    private(set) var maximumGapSeconds = 0.0
    private(set) var missingDecodedDurations = 0
    private var firstPair: [String: Any]?
    private var latestPair: [String: Any] = [:]
    var decodedSeconds: Double? {
        guard let firstPTS, let lastEnd else { return nil }
        return CMTimeSubtract(lastEnd, firstPTS).seconds
    }
    var diagnostics: [String: Any] {
        ["first_pair":firstPair ?? [:],"latest_pair":latestPair,"matched_frames":frames,
         "missing_decoded_durations":missingDecodedDurations]
    }
    mutating func observe(decoded: CMSampleBuffer, original: CMSampleBuffer) throws {
        guard CMSampleBufferGetImageBuffer(decoded) != nil else {
            throw AcceptanceError.invalid("video was not really decoded")
        }
        try observe(decodedPTS: CMSampleBufferGetPresentationTimeStamp(decoded),
            decodedDuration: CMSampleBufferGetDuration(decoded),
            originalPTS: CMSampleBufferGetPresentationTimeStamp(original),
            originalDuration: CMSampleBufferGetDuration(original),
            decodedCount: CMSampleBufferGetNumSamples(decoded), originalCount: CMSampleBufferGetNumSamples(original))
    }
    mutating func observe(decodedPTS: CMTime, decodedDuration: CMTime,
        originalPTS: CMTime, originalDuration: CMTime, decodedCount: Int, originalCount: Int) throws {
        latestPair = ["decoded_pts":AcceptanceReport.time(decodedPTS),"decoded_duration":AcceptanceReport.time(decodedDuration),
            "original_pts":AcceptanceReport.time(originalPTS),"original_duration":AcceptanceReport.time(originalDuration),
            "decoded_count":decodedCount,"original_count":originalCount]
        if firstPair == nil { firstPair = latestPair }
        guard decodedCount == 1, originalCount == 1,
              decodedPTS.isNumeric, originalPTS.isNumeric,
              decodedPTS.epoch == 0, originalPTS.epoch == 0,
              CMTimeCompare(decodedPTS, originalPTS) == 0 else {
            throw AcceptanceError.invalid("decoded video PTS must match one original compressed sample")
        }
        guard originalDuration.isNumeric, originalDuration.epoch == 0, originalDuration.seconds > 0 else {
            throw AcceptanceError.invalid("original compressed video sample duration unavailable")
        }
        if decodedDuration.isValid {
            guard decodedDuration.isNumeric, decodedDuration.epoch == 0,
                  CMTimeCompare(decodedDuration, originalDuration) == 0 else {
                throw AcceptanceError.invalid("decoded video duration contradicts original sample")
            }
        } else { missingDecodedDurations += 1 }
        if let lastEnd {
            let gap = abs(CMTimeSubtract(decodedPTS, lastEnd).seconds)
            guard gap.isFinite, gap <= 1.0 / 90_000 else {
                throw AcceptanceError.invalid("decoded video gap or overlap against original duration")
            }
            maximumGapSeconds = max(maximumGapSeconds, gap)
        }
        let end = CMTimeAdd(originalPTS, originalDuration)
        guard end.isNumeric, CMTimeCompare(end, originalPTS) > 0 else {
            throw AcceptanceError.invalid("original video endpoint unavailable")
        }
        if firstPTS == nil { firstPTS = decodedPTS }
        lastEnd = end
        frames += 1
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

/// Dedicated serial observations cannot inherit the player's executor. The only
/// history is the existing 61-record collector; each callback borrows owners for
/// one read. A delayed read remains a real delayed sample and fails the unchanged
/// cadence validator. Timer deadlines are diagnostics, never reported timestamps.
final class AcceptanceIndependentSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hls.acceptance.sampler", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var cancelled = false
    private let start: Double
    private let intervalSeconds: Double
    private let collector: AcceptanceSampleCollector
    private let shouldStop: @Sendable () -> Bool
    private let onFailure: @Sendable (any Error) -> Void
    // Serial-queue confined, including release during physical join.
    private var observe: (@Sendable (Double) throws -> [String: Any])?
    private var observations = 0

    init(start: Double, collector: AcceptanceSampleCollector, intervalSeconds: Double = 5,
         shouldStop: @escaping @Sendable () -> Bool,
         observe: @escaping @Sendable (Double) throws -> [String: Any],
         onFailure: @escaping @Sendable (any Error) -> Void) {
        precondition(start.isFinite && intervalSeconds.isFinite && intervalSeconds > 0)
        self.start = start
        self.intervalSeconds = intervalSeconds
        self.collector = collector
        self.shouldStop = shouldStop
        self.observe = observe
        self.onFailure = onFailure
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: intervalSeconds, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        guard !lock.withLock({ cancelled }) else { return }
        guard !shouldStop() else { cancel(); return }
        let observedAt = AcceptanceClock.now
        guard observedAt - start < 300 else { cancel(); return }
        do {
            guard observations < 61, let observe else {
                throw AcceptanceError.invalid("independent sample capacity")
            }
            var value = try observe(observedAt - start)
            value["wall_seconds"] = observedAt - start
            value["sample_read_seconds"] = AcceptanceClock.now - observedAt
            // Cumulative drift from the expected ordinal. Coalesced/missed timer
            // ticks remain visible here and in actual wall gaps, never backfilled.
            value["sample_schedule_drift_seconds"] = max(0, observedAt - start - Double(observations) * intervalSeconds)
            collector.append(value)
            observations += 1
        } catch {
            collector.fail(error)
            cancel()
            onFailure(error)
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        timer.cancel()
    }

    /// Join the actual in-flight read before any caller releases graph roots.
    /// No reader closure, borrowed owner or callback survives this queue fence.
    func join() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                observe = nil
                continuation.resume()
            }
        }
    }

    deinit { timer.cancel() }
}

/// Keep a valid UTF-8 tail within the fixed diagnostic byte cap.
func acceptanceDiagnosticHistoryTail(_ text: String) -> String {
    let tail = text.utf8.suffix(8_192).drop(while: { ($0 & 0xC0) == 0x80 })
    return String(decoding: tail, as: UTF8.self)
}

/// Freeze the earliest authority failure before retirement changes tracker stages.
final class AcceptanceFailureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: [String: String]?
    func record(_ diagnostic: ErrorDiagnosticSnapshot, origin: String) {
        lock.withLock {
            guard first == nil else { return }
            first = ["origin":origin,"error":diagnostic.summary,
                     "history":acceptanceDiagnosticHistoryTail(PlaybackDiagnosticTracker.shared.recentHistory)]
        }
    }
    var snapshot: [String: String] { lock.withLock { first ?? [:] } }
}

/// Read-only observation preserves each admitted event and its original owner.
final class AcceptanceObservedGraph: HLSMediaGraphAssembler.DeliveryGraph, @unchecked Sendable {
    private let graph: SystemHLSDeliveryGraph
    private let lock = NSLock()
    private var packets = 0
    private var eof = false
    private var lastControl = "none"
    private var lastPacket = AcceptanceClock.now
    init(authority: SystemHLSMediaGraphAuthority) { graph = SystemHLSDeliveryGraph(authority: authority) }
    var lastControlDiagnostic: String { lock.withLock { lastControl } }
    var packetCount: Int { lock.withLock { packets } }
    var hasEOF: Bool { lock.withLock { eof } }
    var lastPacketTime: Double { lock.withLock { lastPacket } }
    var failureDiagnostic: ErrorDiagnosticSnapshot? { graph.failureDiagnostic }
    func accept(_ event: AdmittedDemuxEvent) {
        event.withBorrowedEvent { borrowed in
            lock.withLock {
                switch borrowed {
                case .packet: packets += 1; lastPacket = AcceptanceClock.now
                case .endOfStream: eof = true; lastControl = "eof"
                case .tracks: lastControl = "tracks"
                case .discontinuity: lastControl = "discontinuity"
                case .cancelled: lastControl = "cancelled"
                case .failure(let error): lastControl = ErrorDiagnosticSnapshot(error).summary
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
    static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8(truncatingIfNeeded: value >> 24),UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),UInt8(truncatingIfNeeded: value)], encoding: .ascii)
            ?? String(format: "%08x", value)
    }
    static func configuration(_ data: Data) -> [String: Any] {
        var result: [String: Any] = ["bytes":data.count,
            "prefix_base64":data.prefix(64).base64EncodedString()]
        if data.count <= 65_536 { result["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return result
    }
    static func format(_ format: CMFormatDescription) -> [String: Any] {
        let type = CMFormatDescriptionGetMediaType(format)
        var result: [String: Any] = ["media_type":fourCC(type),"subtype":fourCC(CMFormatDescriptionGetMediaSubType(format))]
        if type == kCMMediaType_Video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            result["width"] = dimensions.width; result["height"] = dimensions.height
            let atoms = CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            for name in ["avcC", "hvcC"] {
                if let data = atoms?[name] as? Data { result[name] = configuration(data) }
            }
        }
        return result
    }
    static func failureTiming(elapsed: Double, stopped: Double?, playbackStart: Double?, lastProgress: Double?) -> [String: Any] {
        let observation = stopped ?? elapsed
        return ["source_observation_seconds":finite(observation),"source_clock_elapsed_seconds":finite(elapsed),
            "post_stop_seconds":finite(stopped.map { elapsed - $0 }),
            "playback_wall_seconds":finite(playbackStart.map { observation - $0 }),
            "last_clock_progress_age_seconds":finite(lastProgress.map { observation - $0 })]
    }
    /// Failure diagnostics must survive indefinite/invalid native times.
    static func finite(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }
    static func time(_ value: CMTime) -> [String: Any] {
        ["value":value.value,"timescale":value.timescale,"epoch":value.epoch,
         "flags":value.flags.rawValue,"seconds":finite(value.seconds)]
    }
    static func ranges(_ values: [NSValue]) -> [String: Any] {
        ["total_count":values.count,"ranges":values.prefix(8).map { value -> [String: Any] in
            let range = value.timeRangeValue
            return ["start":time(range.start),"duration":time(range.duration),"end":time(CMTimeRangeGetEnd(range))]
        }]
    }
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
    /// Cumulative release observations, in monotonic wall-clock seconds. A maximum
    /// covers only released inputs until retirement. Coverage of every admitted
    /// input requires count == released_inputs == allocated_inputs, no final live
    /// inputs, and a complete probe. Rollback is included. These are diagnostics,
    /// never acceptance thresholds, and cannot prove a future residence bound.
    static func inputResidence(_ value: HLSWriterAcceptanceSnapshot) -> [String: Any] {
        ["released_input_residence_count":value.releasedInputResidenceCount,
         "maximum_released_input_residence_seconds":value.maximumReleasedInputResidenceSeconds]
    }
    static func inputResidenceRenditions(_ values: [HLSWriterRenditionAcceptanceSnapshot]) -> [[String: Any]] {
        values.sorted { $0.renditionIdentity.rawValue < $1.renditionIdentity.rawValue }.map { value in
            var result: [String: Any] = ["rendition_identity":value.renditionIdentity.rawValue,
                "latest_writer_identity":value.latestWriterIdentity.rawValue,
                "live_inputs":value.usage.liveInputCount,"live_bytes":value.usage.liveInputBytes,
                "accepted_inputs":value.usage.acceptedInputCount,"released_inputs":value.usage.releasedInputCount]
            result.merge(inputResidence(value.usage)) { _, new in new }
            return result
        }
    }
    static func retirement(_ value: HLSWriterAcceptanceSnapshot) -> [String: Any] {
        var result: [String: Any] = ["native_writer_count":value.nativeWriterCount,"final_live_inputs":value.liveInputCount,
         "final_live_bytes":value.liveInputBytes,"final_evidence":value.evidenceCount,
         "final_callbacks":value.pendingCallbacks,"allocated_inputs":value.acceptedInputCount,
         "released_inputs":value.releasedInputCount]
        result.merge(inputResidence(value)) { _, new in new }
        return result
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
