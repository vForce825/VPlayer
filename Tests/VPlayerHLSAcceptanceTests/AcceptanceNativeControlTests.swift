// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Network
import XCTest
@testable import VPlayerCore
@testable import VPlayerPlayback

#if !HLS_ACCEPTANCE_BASELINE
/// Short controls run on the candidate before either capped observation. These
/// exercise native components, not a second playback or resource-stability run.
final class AcceptanceNativeControlTests: XCTestCase {
    /// Same real IDR bytes and production admission/writer path, paired packaging.
    /// Canonical production output must decode; legacy outcome is diagnostic.
    private func checkCanonicalVideoDecode() async throws {
        let cases: [(VideoCodec, String, HLSVideoSampleEntry, HLSVideoSampleEntry)] = [
            (.h264, "control-avc.h264", .avc3, .avc1), (.hevc, "control-hevc.h265", .hev1, .hvc1)]
        for (codecIndex, testCase) in cases.enumerated() {
            let (codec, name, legacy, canonical) = testCase
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: nil, subdirectory: "HLSAcceptance"))
            let bytes = try Data(contentsOf: url)
            guard !bytes.isEmpty, bytes.count <= 1_048_576 else { throw AcceptanceError.invalid("video control AU bound") }
            let scan = try AnnexBScanner.scan(bytes, codec: codec)
            XCTAssertEqual(scan.randomAccessKind, codec == .h264 ? .h264IDR : .hevcIDR)
            let track = VideoTrackDescriptor(streamIndex: 0, codec: codec,
                timeBase: MediaRational(num: 1, den: 25)!, width: 1280, height: 720,
                videoDelay: 0, extradata: scan.parameterSets.reduce(into: Data()) {
                    $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1)
                }, frameRate: MediaRational(num: 25, den: 1), fieldOrder: .progressive)
            for (entryIndex, entry) in [legacy, canonical].enumerated() {
                do {
                    let frames = try await decodeRemuxControl(bytes: bytes, track: track, entry: entry,
                        writerBinding: binding(UInt64(60 + codecIndex * 2 + entryIndex)))
                    if entry == canonical { XCTAssertGreaterThan(frames, 0) }
                    print("HLS_ACCEPTANCE_REMUX_CONTROL=entry:\(entry),decoded_frames:\(frames)")
                } catch {
                    print("HLS_ACCEPTANCE_REMUX_CONTROL=entry:\(entry),error:\(ErrorDiagnosticSnapshot(error).summary)")
                    if entry == canonical { throw error }
                }
            }
        }
    }

    private func decodeRemuxControl(bytes: Data, track: VideoTrackDescriptor,
        entry: HLSVideoSampleEntry, writerBinding: FMP4WriterBinding) async throws -> Int {
        let timeline = HLSTimelineCoordinator()
        _ = try timeline.consume(.tracks(DemuxTrackSet(selectedProgramID: 1, video: track, audio: nil)))
        var timed: [HLSTimedVideoAccessUnit] = []
        for index in 0..<12 {
            let events = try timeline.consume(.packet(DemuxPacket(streamIndex: 0, codec: .video(track.codec),
                data: bytes, presentationTimeStamp: CMTime(value: Int64(index), timescale: 25),
                decodeTimeStamp: CMTime(value: Int64(index), timescale: 25),
                duration: CMTime(value: 1, timescale: 25), isKey: true, isCorrupt: false)))
            timed.append(contentsOf: events.compactMap { if case .videoSample(let value) = $0 { value } else { nil } })
        }
        timed.append(contentsOf: try timeline.consume(.endOfStream).compactMap {
            if case .videoSample(let value) = $0 { value } else { nil }
        })
        let first = try XCTUnwrap(timed.first, "Real parser/timeline must emit the short video control")
        var inspection = VideoAccessUnitInspectionSession(generation: first.source.generation, codec: track.codec)
        let eligibility = try VideoRemuxEligibility(generation: first.source.generation, track: track, sampleEntry: entry)
        let admissions = try timed.map { unit -> VideoRemuxAdmissionProof in
            let proof = try inspection.inspect(.init(backing: XCTUnwrap(unit.source.sourceBacking),
                byteRange: XCTUnwrap(unit.source.sourceByteRange), sourceSHA256: XCTUnwrap(unit.source.sourceSHA256),
                codec: track.codec, scanClassification: unit.source.scanClassification,
                presentationTimeStamp: ExactMediaTime(CMSampleBufferGetPresentationTimeStamp(unit.source.sampleBuffer)),
                decodeTimeStamp: ExactMediaTime(CMSampleBufferGetDecodeTimeStamp(unit.source.sampleBuffer)),
                duration: ExactMediaTime(CMSampleBufferGetDuration(unit.source.sampleBuffer)), expectedFormat: track))
            return try XCTUnwrap(eligibility.evaluate(proof).proof)
        }
        let builder = try HLSVideoRemuxSubmissionBuilder(reference: first,
            admission: admissions[0], writerBinding: writerBinding)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(builder.formatDescription), entry.fourCharacterCode)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = AcceptanceCapture(directory: directory)
        defer { capture.close() }
        let holder = AcceptanceControlRelayHolder()
        let relay = SegmentReportRelay(binding: writerBinding, limits: .video, capacity: 4) { object in
            capture.receive(object)
            _ = holder.relay?.releaseForControl(object)
        }
        holder.relay = relay
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
            epochStart: first.timing.presentationTimeStamp.cmTime, videoMode: .passthrough))
        let writer = try SegmentedFMP4Writer(binding: writerBinding, trackKind: .video,
            sourceFormatHint: builder.formatDescription, boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        do {
            try writer.start(at: first.timing.presentationTimeStamp.cmTime)
            for (index, unit) in timed.enumerated() {
                let submission = try builder.makeSubmission(for: unit, admission: admissions[index])
                XCTAssertEqual(submission.outputContainsParameterSets, entry == .avc3 || entry == .hev1)
                var expected = Data()
                try AnnexBScanner.visitNALUnits(in: XCTUnwrap(unit.source.sourceBacking),
                    range: XCTUnwrap(unit.source.sourceByteRange), codec: track.codec) { _, bytes in
                    let nal = bytes.withUnsafeBytes { Data($0) }
                    let type = track.codec == .h264 ? nal[0] & 0x1F : (nal[0] >> 1) & 0x3F
                    let parameter = track.codec == .h264 ? [UInt8(7), 8].contains(type) : [UInt8(32), 33, 34].contains(type)
                    if parameter && (entry == .avc1 || entry == .hvc1) { return }
                    var length = UInt32(nal.count).bigEndian
                    withUnsafeBytes(of: &length) { expected.append(contentsOf: $0) }
                    expected.append(nal)
                }
                XCTAssertEqual(submission.outputSHA256, VideoAccessUnitSHA256(bytes: expected.span),
                    "Only configuration NALs may change; all other bytes and order must survive")
                try await writer.appendRemuxVideoAwaitingReadiness(submission,
                    ticket: boundary.issueRemuxVideoAppend(for: submission, writerBinding: writerBinding))
            }
            _ = try await writer.finish()
        } catch { _ = await writer.cancelAwaitingCompletion(); throw error }
        _ = await writer.cancelAwaitingCompletion()
        guard let captured = try capture.finish().first, captured.inits == 1 else {
            throw AcceptanceError.invalid("short native writer did not emit one initialization")
        }
        let asset = AVURLAsset(url: captured.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AcceptanceError.invalid("short native output has no video track") }
        let reader = try AVAssetReader(asset: asset)
        let originalReader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let originalOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output), originalReader.canAdd(originalOutput) else {
            throw AcceptanceError.invalid("short video reader cannot add output")
        }
        let provider = reader.outputProvider(for: output)
        let originalProvider = originalReader.outputProvider(for: originalOutput)
        let rawReader = try AcceptanceRawVideoReader(url: XCTUnwrap(captured.rawSamplesURL),
            timescale: XCTUnwrap(captured.latestMediaTimescale))
        defer { rawReader.close() }
        var timing = AcceptanceVideoTiming()
        var decodedCursor = AcceptanceVideoReaderCursor(kind: .decoded)
        var originalCursor = AcceptanceVideoReaderCursor(kind: .original)
        var mapping: AcceptanceVideoTimelineMapping?
        defer {
            var observation = timing.diagnostics
            observation["entry"] = String(describing: entry)
            observation["reader_status"] = reader.status.rawValue
            observation["original_reader_status"] = originalReader.status.rawValue
            observation["decoded_cursor"] = decodedCursor.diagnostics
            observation["original_cursor"] = originalCursor.diagnostics
            observation["initialization_format"] = captured.initializationFormat
            observation["raw"] = captured.continuity.failureDiagnostics(timescale: captured.latestMediaTimescale,
                mapping: mapping, byteTiming: rawReader.timing)
            if let evidence = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) {
                print("HLS_ACCEPTANCE_REMUX_TIMING=" + String(decoding: evidence, as: UTF8.self))
            }
            if reader.status == .reading { reader.cancelReading() }
            if originalReader.status == .reading { originalReader.cancelReading() }
        }
        mapping = AcceptanceVideoTimelineMapping(segments: try await track.load(.segments))
        try originalReader.start()
        try reader.start()
        while let ready = try await provider.next() {
            guard try decodedCursor.consumesMedia(ready) else { continue }
            var paired = false
            while let original = try await originalProvider.next() {
                guard try originalCursor.consumesMedia(original) else { continue }
                let originalSample = try makeOwnedReaderFixtureSample(copying: original)
                try rawReader.observe(original: originalSample)
                try timing.observe(decoded: makeOwnedReaderFixtureSample(copying: ready),
                    original: originalSample)
                paired = true
                break
            }
            guard paired else {
                throw AcceptanceError.invalid("short decoded video has no original timing")
            }
        }
        while let original = try await originalProvider.next() {
            if try originalCursor.consumesMedia(original) {
                throw AcceptanceError.invalid("short original video has no decoded image")
            }
        }
        try rawReader.finish()
        guard reader.status == .completed, originalReader.status == .completed,
              timing.frames > 0, timing.frames == timed.count else {
            throw AcceptanceError.invalid("short paired video decode incomplete")
        }
        try captured.continuity.requireVideoCoverage(timing, timescale: captured.latestMediaTimescale,
            mapping: XCTUnwrap(mapping), byteTiming: rawReader.timing)
        return timing.frames
    }

    private func checkVideoReaderMarkerEvidence() throws {
        typealias Snapshot = AcceptanceVideoReaderCursor.Snapshot
        let marker = Snapshot(count: 0, contentType: .markerOnly, duration: .zero)
        let compressed = Snapshot(count: 1, contentType: .dataBuffer,
            duration: CMTime(value: 1, timescale: 25), totalSize: 4, blockSize: 4, hasFormat: true)
        let decoded = Snapshot(count: 1, contentType: .pixelBuffer, duration: .invalid,
            hasImage: true, hasFormat: true)
        for kind in [AcceptanceVideoReaderCursor.Kind.decoded, .original] {
            var cursor = AcceptanceVideoReaderCursor(kind: kind)
            // Use a real typed marker too: no unsafe header escapes its borrow.
            let zero = CMReadySampleBuffer<Never>(markerAt: .zero, duration: .zero)
            XCTAssertFalse(try cursor.consumesMedia(CMReadySampleBuffer(zero)))
            let untimed = CMReadySampleBuffer<Never>(markerAt: .invalid)
            XCTAssertFalse(try cursor.consumesMedia(CMReadySampleBuffer(untimed)))
            let mediaGap = CMReadySampleBuffer<Never>(markerAt: .zero, duration: CMTime(value: 1, timescale: 25))
            XCTAssertThrowsError(try cursor.consumesMedia(CMReadySampleBuffer(mediaGap)),
                "A real typed marker with positive duration must not hide a media gap")
            XCTAssertTrue(try cursor.consumesMedia(kind == .decoded ? decoded : compressed))
            XCTAssertEqual(cursor.consecutiveMarkers, 0)
            // Trailing markers are consumed to EOF, never counted as extra media.
            XCTAssertFalse(try cursor.consumesMedia(marker))
            XCTAssertEqual(cursor.skippedMarkers, 3)
            XCTAssertEqual(cursor.maximumMarkerRun, 2)
            XCTAssertTrue(try cursor.consumesMedia(kind == .decoded ? decoded : compressed),
                "An extra real sample after a trailing marker must not disappear")
        }

        var markerFaults: [Snapshot] = []
        for duration in [CMTime(value: 1, timescale: 25), CMTime(value: -1, timescale: 25),
                         .indefinite, .positiveInfinity,
                         CMTime(value: 0, timescale: 1, flags: .valid, epoch: 1)] {
            var bad = marker; bad.duration = duration; markerFaults.append(bad)
        }
        for type in [CMSampleBuffer.ContentType.dataBuffer, .pixelBuffer, .taggedBuffers, .sampleReference] {
            var bad = marker; bad.contentType = type; markerFaults.append(bad)
        }
        var bad = marker; bad.blockSize = 0; markerFaults.append(bad)
        bad = marker; bad.blockSize = 4; markerFaults.append(bad)
        bad = marker; bad.hasImage = true; markerFaults.append(bad)
        bad = marker; bad.hasFormat = true; markerFaults.append(bad)
        bad = marker; bad.totalSize = 4; markerFaults.append(bad)
        bad = marker; bad.valid = false; markerFaults.append(bad)
        bad = marker; bad.ready = false; markerFaults.append(bad)
        for kind in [AcceptanceVideoReaderCursor.Kind.decoded, .original] {
            for fault in markerFaults {
                var cursor = AcceptanceVideoReaderCursor(kind: kind)
                XCTAssertThrowsError(try cursor.consumesMedia(fault))
                XCTAssertEqual(cursor.skippedMarkers, 0, "Malformed empty buffers cannot be discarded")
            }
            var cursor = AcceptanceVideoReaderCursor(kind: kind)
            for _ in 0..<AcceptanceVideoReaderCursor.maximumConsecutiveMarkers {
                XCTAssertFalse(try cursor.consumesMedia(marker))
            }
            XCTAssertThrowsError(try cursor.consumesMedia(marker), "An unbounded marker stream must fail")
            XCTAssertEqual(cursor.skippedMarkers, AcceptanceVideoReaderCursor.maximumConsecutiveMarkers)
            XCTAssertTrue(try cursor.consumesMedia(kind == .decoded ? decoded : compressed))
            XCTAssertFalse(try cursor.consumesMedia(marker), "A real sample resets only the consecutive limit")
            XCTAssertEqual(cursor.maximumMarkerRun, AcceptanceVideoReaderCursor.maximumConsecutiveMarkers)
        }

        var mediaFaults: [Snapshot] = []
        for count in [-1, 2] { var bad = compressed; bad.count = count; mediaFaults.append(bad) }
        bad = compressed; bad.blockSize = nil; mediaFaults.append(bad)
        bad = compressed; bad.blockSize = 0; mediaFaults.append(bad)
        bad = compressed; bad.blockSize = 3; mediaFaults.append(bad)
        bad = compressed; bad.totalSize = 0; mediaFaults.append(bad)
        bad = compressed; bad.hasImage = true; mediaFaults.append(bad)
        bad = compressed; bad.hasFormat = false; mediaFaults.append(bad)
        bad = compressed; bad.contentType = .sampleReference; mediaFaults.append(bad)
        for fault in mediaFaults {
            var cursor = AcceptanceVideoReaderCursor(kind: .original)
            XCTAssertThrowsError(try cursor.consumesMedia(fault), "Nonempty malformed data must fail")
        }
        var imageCursor = AcceptanceVideoReaderCursor(kind: .decoded)
        var raster = decoded; raster.totalSize = 1_414_080
        XCTAssertTrue(try imageCursor.consumesMedia(raster),
            "The native reader reports positive raster bytes for a valid decoded image")
        XCTAssertEqual(imageCursor.skippedMarkers, 0)
        bad = raster; bad.hasImage = false
        XCTAssertThrowsError(try imageCursor.consumesMedia(bad))
        bad = raster; bad.blockSize = 4
        XCTAssertThrowsError(try imageCursor.consumesMedia(bad))
        XCTAssertThrowsError(try imageCursor.consumesMedia(compressed))
        var originalCursor = AcceptanceVideoReaderCursor(kind: .original)
        XCTAssertThrowsError(try originalCursor.consumesMedia(decoded))
        bad = compressed; bad.blockSize = 5
        XCTAssertTrue(try originalCursor.consumesMedia(bad),
            "Sufficient extra logical backing remains a real sample, never a skipped marker")
        XCTAssertEqual(originalCursor.skippedMarkers, 0)
        bad = compressed; bad.duration = .invalid
        XCTAssertTrue(try originalCursor.consumesMedia(bad),
            "A real sample with missing timing reaches the exact timing verifier; it is never a marker")
        var timing = AcceptanceVideoTiming()
        XCTAssertThrowsError(try timing.observe(decodedPTS: .zero, decodedDuration: .invalid,
            originalPTS: .zero, originalDuration: bad.duration, decodedCount: 1, originalCount: 1))
    }

    private func checkRawVideoByteEvidence() throws {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(name.utf8) + payload }
        func fragment(_ dataOffset: UInt32, count: UInt32 = 2, sequence: UInt32 = 1, time: UInt32 = 1_000) -> Data {
            var run = word(0x301) + word(count) + word(dataOffset)
            for _ in 0..<count { run.append(word(4) + word(4)) }
            let track = box("tfhd", word(0x020000) + word(1)) + box("tfdt", word(0) + word(time)) + box("trun", run)
            return box("moof", box("mfhd", word(0) + word(sequence)) + box("traf", track))
        }
        let payload = Data([1, 2, 3, 4, 1, 2, 3, 4])
        let rawFragment = fragment(UInt32(fragment(0).count + 8)) + box("mdat", payload)
        var samples: [AcceptanceRawVideoSample] = []
        _ = try AcceptanceMP4.fragment(rawFragment, defaultDuration: 0,
            sampleDefaults: .init(trackID: 1, duration: 0, size: 0)) { samples.append($0) }
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.time), [1_000, 1_004])
        XCTAssertEqual(samples.map(\.size), [4, 4])
        XCTAssertEqual(samples.map(\.duration), [4, 4])
        let digest = Data(SHA256.hash(data: Data([1, 2, 3, 4])))
        XCTAssertEqual(samples.map(\.digest), [digest, digest])
        XCTAssertEqual(AcceptanceRawVideoSample.recordBytes * AcceptanceRawVideoSample.maximumRecords, 3 * 1_024 * 1_024)
        let first = AcceptanceRawVideoSample(time: 1_000, duration: 4, size: 4, digest: digest)
        let second = AcceptanceRawVideoSample(time: 1_004, duration: 4, size: 4, digest: digest)
        XCTAssertEqual(try AcceptanceRawVideoSample(encoded: first.encoded()).time, 1_000)
        var proof = AcceptanceVideoByteTiming(timescale: 100)
        let reader = AcceptanceVideoByteTiming.ReaderSample(size: 4, digest: digest,
            pts: .zero, duration: CMTime(value: 4, timescale: 100))
        try proof.observe(raw: first, reader: reader)
        var next = reader; next.pts = CMTime(value: 4, timescale: 100)
        try proof.observe(raw: second, reader: next)
        XCTAssertEqual(proof.frames, 2, "Duplicate payloads are verified by ordinal, not looked up by hash")
        XCTAssertEqual(CMTimeCompare(try proof.presentationTime(forRawTime: CMTime(value: 1_008, timescale: 100)),
            CMTime(value: 8, timescale: 100)), 0)
        for fault in [0, 1, 2, 3] {
            var value = AcceptanceVideoByteTiming(timescale: 100)
            try value.observe(raw: first, reader: reader)
            var wrong = next
            if fault == 0 { wrong.digest = Data(SHA256.hash(data: Data([4, 3, 2, 1]))) }
            if fault == 1 { wrong.pts = .zero }
            if fault == 2 { wrong.duration = CMTime(value: 5, timescale: 100) }
            if fault == 3 { wrong.size = 3 }
            XCTAssertThrowsError(try value.observe(raw: second, reader: wrong))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("samples")
        try (first.encoded() + second.encoded()).write(to: url)
        let complete = try AcceptanceRawVideoReader(url: url, timescale: 100)
        defer { complete.close() }
        try complete.observe(reader: reader); try complete.observe(reader: next)
        XCTAssertNoThrow(try complete.finish())
        let missing = try AcceptanceRawVideoReader(url: url, timescale: 100)
        defer { missing.close() }
        try missing.observe(reader: reader)
        XCTAssertThrowsError(try missing.finish(), "An unread raw sample cannot disappear")
        let extra = try AcceptanceRawVideoReader(url: url, timescale: 100)
        defer { extra.close() }
        try extra.observe(reader: reader); try extra.observe(reader: next)
        XCTAssertThrowsError(try extra.observe(reader: next), "An extra reader sample has no raw ordinal")
        let interruptedURL = directory.appendingPathComponent("interrupted-samples")
        try first.encoded().dropLast().write(to: interruptedURL)
        let interrupted = try AcceptanceRawVideoReader(url: interruptedURL, timescale: 100)
        defer { interrupted.close() }
        XCTAssertThrowsError(try interrupted.observe(reader: reader), "An interrupted fixed-size record must fail")

        // A one-record control limit produces a partial-fragment failure with
        // two ordinary samples; no large or stress input is needed.
        let capture = AcceptanceCapture(directory: directory, rawSampleRecordLimit: 1)
        defer { capture.close() }
        let writerBinding = binding(75)
        func object(_ bytes: Data, kind: SealedMediaObjectKind, sequence: UInt64) -> SealedMediaObject {
            SealedMediaObject(binding: writerBinding, writerIdentity: writerBinding.writerIdentity,
                callbackTicket: .init(rawValue: sequence), logicalSequence: sequence, kind: kind,
                sourceBytes: bytes as NSData,
                report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: .zero)),
                publicationLease: nil)
        }
        let trex = box("trex", word(0) + word(1) + word(1) + word(4) + word(4) + word(0))
        capture.receive(object(box("moov", box("mvex", trex)), kind: .initialization, sequence: 0))
        capture.receive(object(rawFragment, kind: .media, sequence: 1))
        let firstFailure = try XCTUnwrap(capture.failureDiagnostics["error"] as? String)
        XCTAssertTrue(firstFailure.contains("raw sample evidence capacity"))
        let sidecar = directory.appendingPathComponent("original-video-samples.bin")
        XCTAssertEqual(try Data(contentsOf: sidecar).count, AcceptanceRawVideoSample.recordBytes)
        let oneSample = fragment(UInt32(fragment(0, count: 1).count + 8), count: 1, sequence: 2, time: 1_008) +
            box("mdat", Data([1, 2, 3, 4]))
        capture.receive(object(oneSample, kind: .media, sequence: 2))
        XCTAssertEqual(try Data(contentsOf: sidecar).count, AcceptanceRawVideoSample.recordBytes,
            "A failed fragment permanently revokes later physical evidence admission")
        XCTAssertEqual(capture.failureDiagnostics["error"] as? String, firstFailure)
        XCTAssertThrowsError(try capture.finish())
    }

    private func checkVideoTimelineMapping() throws {
        let mediaStart = CMTime(value: 10, timescale: 1)
        let second = CMTime(value: 1, timescale: 1)
        let digest = Data(SHA256.hash(data: Data([1, 2, 3, 4])))
        var byteTiming = AcceptanceVideoByteTiming(timescale: 48_000)
        try byteTiming.observe(raw: .init(time: 480_000, duration: 48_000, size: 4, digest: digest),
            reader: .init(size: 4, digest: digest, pts: .zero, duration: second))
        let source = CMTimeRange(start: mediaStart, duration: second)
        let target = CMTimeRange(start: .zero, duration: second)
        let mapping = AcceptanceVideoTimelineMapping(segmentCount: 1,
            segment: .init(source: source, target: target, isEmpty: false))
        XCTAssertEqual(CMTimeCompare(try mapping.presentationTime(forMediaTime: mediaStart), .zero), 0)
        XCTAssertEqual(CMTimeCompare(try mapping.presentationTime(forMediaTime: CMTime(value: 11, timescale: 1)), second), 0)
        XCTAssertThrowsError(try mapping.presentationTime(forMediaTime: CMTime(value: 9, timescale: 1)))
        XCTAssertThrowsError(try mapping.presentationTime(forMediaTime: CMTime(value: 12, timescale: 1)))
        let shifted = AcceptanceVideoTimelineMapping(segmentCount: 1, segment: .init(
            source: CMTimeRange(start: CMTime(value: 41, timescale: 3), duration: second),
            target: CMTimeRange(start: CMTime(value: 7, timescale: 5), duration: second), isEmpty: false))
        XCTAssertEqual(CMTimeCompare(try shifted.presentationTime(forMediaTime: CMTime(value: 44, timescale: 3)),
            CMTime(value: 12, timescale: 5)), 0, "Translation comes from container metadata, never a hardcoded ten seconds")
        for count in [0, 2] {
            let unsupported = AcceptanceVideoTimelineMapping(segmentCount: count,
                segment: .init(source: source, target: target, isEmpty: false))
            XCTAssertThrowsError(try unsupported.presentationTime(forMediaTime: mediaStart))
        }
        let empty = AcceptanceVideoTimelineMapping(segmentCount: 1,
            segment: .init(source: source, target: target, isEmpty: true))
        XCTAssertThrowsError(try empty.presentationTime(forMediaTime: mediaStart))
        let absent = AcceptanceVideoTimelineMapping(segmentCount: 1, segment: nil)
        XCTAssertThrowsError(try absent.presentationTime(forMediaTime: mediaStart))
        for duration in [CMTime.invalid, .zero, .indefinite, CMTime(value: -1, timescale: 1),
                         CMTime(value: 2, timescale: 1)] {
            let unsupported = AcceptanceVideoTimelineMapping(segmentCount: 1, segment: .init(
                source: source, target: CMTimeRange(start: .zero, duration: duration), isEmpty: false))
            XCTAssertThrowsError(try unsupported.presentationTime(forMediaTime: mediaStart))
        }
        let invalidSource = AcceptanceVideoTimelineMapping(segmentCount: 1, segment: .init(
            source: CMTimeRange(start: .invalid, duration: second), target: target, isEmpty: false))
        XCTAssertThrowsError(try invalidSource.presentationTime(forMediaTime: mediaStart))

        var raw = AcceptanceFragmentContinuity()
        try raw.observe(fragment(sequence: 1, time: 480_000), defaultDuration: 48_000)
        var complete = AcceptanceVideoTiming()
        try complete.observe(decodedPTS: .zero, decodedDuration: .invalid, originalPTS: .zero,
            originalDuration: second, decodedCount: 1, originalCount: 1)
        XCTAssertNoThrow(try raw.requireVideoCoverage(complete, timescale: 48_000, mapping: mapping, byteTiming: byteTiming))
        let normalized = AcceptanceVideoTimelineMapping(segmentCount: 1,
            segment: .init(source: target, target: target, isEmpty: false))
        XCTAssertNoThrow(try raw.requireVideoCoverage(complete, timescale: 48_000, mapping: normalized, byteTiming: byteTiming),
            "Native identity metadata does not expose the byte-proven raw fragment origin")
        let identity = AcceptanceVideoTimelineMapping(segmentCount: 1,
            segment: .init(source: source, target: source, isEmpty: false))
        XCTAssertThrowsError(try raw.requireVideoCoverage(complete, timescale: 48_000, mapping: identity, byteTiming: byteTiming),
            "Equal spans cannot excuse a wrong container-derived translation")
        var short = AcceptanceVideoTiming()
        try short.observe(decodedPTS: .zero, decodedDuration: .invalid, originalPTS: .zero,
            originalDuration: CMTime(value: 1, timescale: 2), decodedCount: 1, originalCount: 1)
        XCTAssertThrowsError(try raw.requireVideoCoverage(short, timescale: 48_000, mapping: mapping, byteTiming: byteTiming))
        var extra = AcceptanceVideoTiming()
        for pts in [CMTime.zero, CMTime(value: 1, timescale: 2)] {
            try extra.observe(decodedPTS: pts, decodedDuration: .invalid, originalPTS: pts,
                originalDuration: CMTime(value: 1, timescale: 2), decodedCount: 1, originalCount: 1)
        }
        XCTAssertThrowsError(try raw.requireVideoCoverage(extra, timescale: 48_000, mapping: mapping, byteTiming: byteTiming),
            "Translation never overrides raw sample counts")
        for offset in [Int32(-1), 1] {
            var reordered = AcceptanceFragmentContinuity()
            try reordered.observe(fragment(sequence: 1, time: 480_000, compositionOffset: offset), defaultDuration: 48_000)
            XCTAssertThrowsError(try reordered.requireVideoCoverage(complete, timescale: 48_000, mapping: mapping, byteTiming: byteTiming),
                "Raw decode time is not a presentation coordinate when composition offsets are nonzero")
        }
        var zeroOffset = AcceptanceFragmentContinuity()
        try zeroOffset.observe(fragment(sequence: 1, time: 480_000, compositionOffset: 0), defaultDuration: 48_000)
        XCTAssertNoThrow(try zeroOffset.requireVideoCoverage(complete, timescale: 48_000, mapping: mapping, byteTiming: byteTiming))
        let diagnostics = raw.failureDiagnostics(timescale: 48_000, mapping: mapping, byteTiming: byteTiming)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(diagnostics))
        XCTAssertNotNil(diagnostics["mapped_first_raw_pts"])
    }

    private func checkVideoTimingEvidence() throws {
        let start = CMTime(value: 10, timescale: 1)
        let digest = Data(SHA256.hash(data: Data([1, 2, 3, 4])))
        var byteTiming = AcceptanceVideoByteTiming(timescale: 48_000)
        try byteTiming.observe(raw: .init(time: 480_000, duration: 48_000, size: 4, digest: digest),
            reader: .init(size: 4, digest: digest, pts: start, duration: CMTime(value: 1, timescale: 1)))
        let range = CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 1))
        let identity = AcceptanceVideoTimelineMapping(segmentCount: 1,
            segment: .init(source: range, target: range, isEmpty: false))
        let duration = CMTime(value: 1, timescale: 25)
        var timing = AcceptanceVideoTiming()
        try timing.observe(decodedPTS: start, decodedDuration: .invalid, originalPTS: start,
            originalDuration: duration, decodedCount: 1, originalCount: 1)
        let next = CMTimeAdd(start, duration)
        let longer = CMTime(value: 3, timescale: 50)
        try timing.observe(decodedPTS: next, decodedDuration: longer, originalPTS: next,
            originalDuration: longer, decodedCount: 1, originalCount: 1)
        XCTAssertEqual(timing.frames, 2)
        XCTAssertEqual(timing.missingDecodedDurations, 1)
        XCTAssertEqual(try XCTUnwrap(timing.decodedSeconds), 0.1, accuracy: 0.000001)
        XCTAssertEqual(timing.maximumGapSeconds, 0)
        for invalid in [CMTime.invalid, .zero, CMTime(value: -1, timescale: 25)] {
            var value = AcceptanceVideoTiming()
            XCTAssertThrowsError(try value.observe(decodedPTS: start, decodedDuration: .invalid,
                originalPTS: start, originalDuration: invalid, decodedCount: 1, originalCount: 1))
        }
        for mismatch in [CMTime.invalid, CMTimeAdd(start, duration)] {
            var value = AcceptanceVideoTiming()
            XCTAssertThrowsError(try value.observe(decodedPTS: mismatch, decodedDuration: duration,
                originalPTS: start, originalDuration: duration, decodedCount: 1, originalCount: 1))
        }
        var mismatchDuration = AcceptanceVideoTiming()
        XCTAssertThrowsError(try mismatchDuration.observe(decodedPTS: start, decodedDuration: longer,
            originalPTS: start, originalDuration: duration, decodedCount: 1, originalCount: 1))
        var missing = AcceptanceVideoTiming()
        try missing.observe(decodedPTS: start, decodedDuration: .invalid, originalPTS: start,
            originalDuration: duration, decodedCount: 1, originalCount: 1)
        let gap = CMTimeAdd(next, duration)
        XCTAssertThrowsError(try missing.observe(decodedPTS: gap, decodedDuration: .invalid,
            originalPTS: gap, originalDuration: duration, decodedCount: 1, originalCount: 1))
        var original = AcceptanceFragmentContinuity()
        try original.observe(fragment(sequence: 1, time: 480_000), defaultDuration: 48_000)
        var complete = AcceptanceVideoTiming()
        try complete.observe(decodedPTS: start, decodedDuration: .invalid, originalPTS: start,
            originalDuration: CMTime(value: 1, timescale: 1), decodedCount: 1, originalCount: 1)
        XCTAssertNoThrow(try original.requireVideoCoverage(complete, timescale: 48_000, mapping: identity, byteTiming: byteTiming))
        var extraFrame = AcceptanceVideoTiming()
        for pts in [start, CMTimeAdd(start, CMTime(value: 1, timescale: 2))] {
            try extraFrame.observe(decodedPTS: pts, decodedDuration: .invalid,
                originalPTS: pts, originalDuration: CMTime(value: 1, timescale: 2),
                decodedCount: 1, originalCount: 1)
        }
        XCTAssertThrowsError(try original.requireVideoCoverage(extraFrame, timescale: 48_000, mapping: identity, byteTiming: byteTiming),
            "Matching first/end timestamps cannot hide an extra decoded sample")
        var twoRawSamples = AcceptanceFragmentContinuity()
        try twoRawSamples.observe(fragment(sequence: 1, time: 480_000), defaultDuration: 24_000)
        try twoRawSamples.observe(fragment(sequence: 2, time: 504_000), defaultDuration: 24_000)
        XCTAssertThrowsError(try twoRawSamples.requireVideoCoverage(complete, timescale: 48_000, mapping: identity, byteTiming: byteTiming),
            "Matching first/end timestamps cannot hide a missing decoded sample")
        XCTAssertThrowsError(try original.requireVideoCoverage(timing, timescale: 48_000, mapping: identity, byteTiming: byteTiming),
            "Equal decoded and raw frame counts plus exact raw endpoints are mandatory")
        var shortEnd = AcceptanceVideoTiming()
        try shortEnd.observe(decodedPTS: start, decodedDuration: .invalid, originalPTS: start,
            originalDuration: duration, decodedCount: 1, originalCount: 1)
        XCTAssertThrowsError(try original.requireVideoCoverage(shortEnd, timescale: 48_000, mapping: identity, byteTiming: byteTiming),
            "The last frame endpoint cannot be inferred from nominal FPS")
        var batched = AcceptanceVideoTiming()
        XCTAssertThrowsError(try batched.observe(decodedPTS: start, decodedDuration: .invalid,
            originalPTS: start, originalDuration: duration, decodedCount: 1, originalCount: 2))
    }

    private func checkFailureDiagnosticSerialization() throws {
        let stopped = AcceptanceReport.failureTiming(elapsed: 314.4, stopped: 299.5, playbackStart: 35.1, lastProgress: 299.48)
        XCTAssertEqual(stopped["source_observation_seconds"] as? Double, 299.5)
        XCTAssertEqual(try XCTUnwrap(stopped["playback_wall_seconds"] as? Double), 264.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stopped["post_stop_seconds"] as? Double), 14.9, accuracy: 0.001)
        let overrun = AcceptanceReport.failureTiming(elapsed: 301, stopped: nil, playbackStart: nil, lastProgress: nil)
        XCTAssertEqual(overrun["source_observation_seconds"] as? Double, 301, "Do not mask an actual missing stop")
        for value in [Double?.none, .some(.nan), .some(.infinity), .some(-.infinity)] {
            XCTAssertTrue(AcceptanceReport.finite(value) is NSNull)
        }
        XCTAssertEqual(AcceptanceReport.finite(2.5) as? Double, 2.5)
        let ranges = (0..<12).map { NSValue(timeRange: CMTimeRange(
            start: CMTime(value: Int64($0), timescale: 1), duration: CMTime(value: 1, timescale: 1))) }
        let bounded = AcceptanceReport.ranges(ranges)
        XCTAssertEqual(bounded["total_count"] as? Int, 12)
        XCTAssertEqual((bounded["ranges"] as? [[String: Any]])?.count, 8)
        let payload: [String: Any] = ["indefinite":AcceptanceReport.time(.indefinite),
            "invalid":AcceptanceReport.time(.invalid),"ranges":bounded]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        _ = try JSONSerialization.data(withJSONObject: payload)

        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data {
            word(UInt32(payload.count + 8)) + Data(name.utf8) + payload
        }
        for version in [UInt8(0), 1] {
            let mdhd = Data([version, 0, 0, 0]) + Data(repeating: 0, count: version == 0 ? 8 : 16) +
                word(48_000) + Data(repeating: 0, count: version == 0 ? 8 : 12)
            let initialization = box("moov", box("trak", box("mdia", box("mdhd", mdhd))))
            XCTAssertEqual(try AcceptanceMP4.mediaTimescale(initialization), 48_000)
        }
        func wide(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        let movieHeader = box("mvhd", word(0) + word(0) + word(0) + word(600) + word(0))
        let mediaHeader = box("mdhd", word(0) + word(0) + word(0) + word(48_000) + word(0))
        let media = box("mdia", mediaHeader)
        let noEdit = box("moov", movieHeader + box("trak", media))
        XCTAssertEqual(try AcceptanceMP4.videoTimelineMetadata(noEdit)["edit_container_count"] as? Int, 0)
        for version in [UInt8(0), 1] {
            let values = version == 0 ? word(600) + word(480_000) : wide(600) + wide(480_000)
            let editList = box("elst", Data([version, 0, 0, 0]) + word(1) + values + word(0x0001_0000))
            let initialization = box("moov", movieHeader + box("trak", media + box("edts", editList)))
            let observed = try AcceptanceMP4.videoTimelineMetadata(initialization)
            XCTAssertEqual(observed["movie_timescale"] as? UInt32, 600)
            XCTAssertEqual(observed["media_timescale"] as? UInt32, 48_000)
            let entries = try XCTUnwrap(observed["edits"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0]["media_time_ticks"] as? Int64, 480_000)
            XCTAssertEqual(entries[0]["duration_movie_ticks"] as? UInt64, 600)
            XCTAssertEqual(entries[0]["rate_16_16_bits"] as? UInt32, 0x0001_0000)
        }
        XCTAssertThrowsError(try AcceptanceMP4.mediaTimescale(box("moov", Data())))

        var observed = AcceptanceFragmentContinuity()
        try observed.observe(fragment(sequence: 11, time: 48_000), defaultDuration: 1_024)
        try observed.observe(fragment(sequence: 12, time: 49_024), defaultDuration: 1_024)
        let before = observed.failureDiagnostics(timescale: 48_000)
        XCTAssertEqual(before["first_raw_tfdt"] as? UInt64, 48_000)
        XCTAssertEqual(before["last_raw_mfhd"] as? UInt32, 12)
        XCTAssertEqual(before["last_raw_end"] as? UInt64, 50_048)
        // A real reset fragment parses successfully but fails both continuity facts.
        try observed.observe(fragment(sequence: 1, time: 0), defaultDuration: 1_024)
        let reset = observed.failureDiagnostics(timescale: 48_000)
        XCTAssertEqual(reset["raw_mfhd_continuous"] as? Bool, false)
        XCTAssertEqual(reset["raw_tfdt_continuous"] as? Bool, false)
        XCTAssertEqual(reset["last_raw_tfdt"] as? UInt64, 0)
        XCTAssertEqual(reset["last_raw_end"] as? UInt64, 1_024)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reset))
    }

    private func checkFirstFailureCapture() {
        let capture = AcceptanceFailureCapture()
        let first = ErrorDiagnosticSnapshot(typeName: "OriginalFailure", message: "native callback rejected")
        capture.record(first, origin: "authority")
        capture.record(ErrorDiagnosticSnapshot(CancellationError()), origin: "sampler")
        XCTAssertEqual(capture.snapshot["error"], first.summary)
        XCTAssertEqual(capture.snapshot["origin"], "authority")
        XCTAssertLessThanOrEqual(capture.snapshot["history"]?.utf8.count ?? 0, 8_192)
        let unicode = String(repeating: "🔬", count: 3_000) + "end"
        let tail = acceptanceDiagnosticHistoryTail(unicode)
        XCTAssertLessThanOrEqual(tail.utf8.count, 8_192)
        XCTAssertTrue(tail.hasSuffix("end"))
        XCTAssertTrue(unicode.hasSuffix(tail))
        XCTAssertFalse(tail.contains("\u{FFFD}"))
    }

    private func checkListenerReadiness() throws {
        let ready = AcceptanceListenerReadiness()
        ready.observe(.ready)
        try ready.wait(until: .now())
        let cancelled = AcceptanceListenerReadiness()
        cancelled.observe(.cancelled)
        cancelled.observe(.ready)
        XCTAssertThrowsError(try cancelled.wait(until: .now()))
        let failed = AcceptanceListenerReadiness()
        failed.observe(.failed(.posix(.EADDRINUSE)))
        failed.observe(.ready)
        XCTAssertThrowsError(try failed.wait(until: .now())) { error in
            XCTAssertTrue(String(describing: error).contains("source listener failed"))
            XCTAssertTrue(String(describing: error).contains(String(POSIXErrorCode.EADDRINUSE.rawValue)), "Preserve the actual POSIX error code")
        }
        let pending = AcceptanceListenerReadiness()
        pending.observe(.setup)
        XCTAssertThrowsError(try pending.wait(until: .now()))
    }

    private func checkSourceServerFirstRequest() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Data(repeating: 0x47, count: 188 * 100)
        try expected.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = try AcceptanceHTTPServer(fileURL: file)
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (received, response) = try await session.data(from: server.sourceURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(received, expected, "The first accepted request must deliver the exact public test bytes")
    }

    private func checkAccessLogCompletionStates() throws {
        let completed = AcceptanceAccessLogCapture(deadline: 2)
        completed.complete(droppedFrames: 3, stalls: 1, at: 1)
        let observed = try completed.finish()
        XCTAssertEqual(observed.status, .available)
        XCTAssertEqual(observed.droppedFrames, 3)
        XCTAssertEqual(observed.stalls, 1)
        completed.complete(droppedFrames: 99, stalls: 99, at: 1.5)
        XCTAssertEqual(try completed.finish(), observed, "Only the first completion is observable")

        let unavailable = AcceptanceAccessLogCapture(deadline: 2)
        unavailable.complete(droppedFrames: nil, stalls: nil, at: 1)
        let absent = try unavailable.finish()
        XCTAssertEqual(absent.status, .unavailable)
        XCTAssertNil(absent.droppedFrames)
        XCTAssertNil(absent.stalls)

        let timeout = AcceptanceAccessLogCapture(deadline: 2)
        XCTAssertThrowsError(try timeout.finish())
        timeout.complete(droppedFrames: 0, stalls: 0, at: 3)
        XCTAssertThrowsError(try timeout.finish(), "Late delivery cannot convert timeout into success")
        let late = AcceptanceAccessLogCapture(deadline: 2)
        late.complete(droppedFrames: 0, stalls: 0, at: 2)
        XCTAssertThrowsError(try late.finish(), "A callback must finish before its deadline")
    }

    func testNativeObservationControlsRejectFiveFaults() async throws {
        try checkVideoReaderMarkerEvidence()
        try checkRawVideoByteEvidence()
        try checkVideoTimelineMapping()
        try checkVideoTimingEvidence()
        try await checkCanonicalVideoDecode()
        try checkFailureDiagnosticSerialization()
        checkFirstFailureCapture()
        try checkListenerReadiness()
        try await checkSourceServerFirstRequest()
        try checkAccessLogCompletionStates()
        var positive: [String: Any] = [:]
        var negative: [String: Any] = [:]

        // Real CMSampleBuffer PCM enters the exact long-run meter and serializer.
        var pcm = [Float](repeating: 0.1, count: 48_000 * 2)
        let clean = try meter(pcm)
        positive["mute"] = AcceptanceReport.audio(clean)
        for index in (12_768 * 2)..<((12_768 + 1_008) * 2) { pcm[index] = 0 }
        let muted = try meter(pcm)
        XCTAssertEqual(clean.silentShortWindows, 0)
        XCTAssertGreaterThanOrEqual(muted.silentShortWindows, 3)
        negative["mute"] = AcceptanceReport.audio(muted)

        // Actual MP4 bytes go through the exact capture parser and continuity state.
        var continuous = AcceptanceFragmentContinuity()
        var wrapped = AcceptanceFragmentContinuity()
        for (index, sequence) in [UInt32(1), 2, 3].enumerated() {
            try continuous.observe(fragment(sequence: sequence, time: UInt32(index * 1_024)), defaultDuration: 1_024)
        }
        for (index, sequence) in [UInt32.max - 1, UInt32.max, 1].enumerated() {
            try wrapped.observe(fragment(sequence: sequence, time: UInt32(index * 1_024)), defaultDuration: 1_024)
        }
        XCTAssertTrue(continuous.rawSequenceContinuous)
        XCTAssertFalse(wrapped.rawSequenceContinuous)
        positive["wrap"] = AcceptanceReport.fragment(continuous)
        negative["wrap"] = AcceptanceReport.fragment(wrapped)

        // Retain a real CoreMedia alias after the original backing owner is gone.
        let probe = HLSWriterAcceptanceProbe()
        let observation = try XCTUnwrap(probe.register(binding: binding(41), hardInputCount: 1,
            hardInputBytes: 16, hardEvidenceCount: 1, hardCallbackCount: 1))
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputs = WriterInputAdmission(capacity: 1, maximumBytes: 16,
            applicationLedger: ledger, observation: observation)
        var original: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: inputs.admit(bytes: 4))
        var retained: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithBufferReference(allocator: kCFAllocatorDefault,
            referenceBuffer: try XCTUnwrap(original), offsetToData: 0, dataLength: 4,
            flags: 0, blockBufferOut: &retained), noErr)
        original = nil
        try withExtendedLifetime(XCTUnwrap(retained)) {
            XCTAssertEqual(probe.snapshot.liveInputCount, 1)
            XCTAssertGreaterThan(ledger.chargedBytes, 0)
            negative["retained_input"] = AcceptanceReport.retirement(probe.snapshot)
        }
        retained = nil
        XCTAssertEqual(probe.snapshot.liveInputCount, 0)
        XCTAssertEqual(ledger.chargedBytes, 0)
        positive["retained_input"] = AcceptanceReport.retirement(probe.snapshot)

        // The real SegmentedFMP4Writer reserves its initialization callback. Only
        // its inspection adapter withholds delivery; no probe count is fabricated.
        let callbackProbe = HLSWriterAcceptanceProbe()
        let writerBinding = binding(42)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let relay = SegmentReportRelay(binding: writerBinding, limits: .audio,
            capacity: 4, objectSink: { _ in })
        let writer = try SegmentedFMP4Writer(binding: writerBinding, trackKind: .aac,
            sourceFormatHint: aacFormat(), boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: WithheldInitializationFactory(), acceptanceProbe: callbackProbe)
        defer { _ = writer.cancel() }
        try writer.start(at: .zero)
        XCTAssertEqual(writer.usage.pendingCallbackCount, 1)
        XCTAssertEqual(callbackProbe.snapshot.pendingCallbacks, 1)
        negative["lost_callback"] = AcceptanceReport.retirement(callbackProbe.snapshot)
        _ = writer.cancel()
        XCTAssertEqual(callbackProbe.snapshot.pendingCallbacks, 0)
        positive["lost_callback"] = AcceptanceReport.retirement(callbackProbe.snapshot)

        // Controlled footprint observations use the same collector and serialization.
        let flat = AcceptanceSampleCollector()
        let growing = AcceptanceSampleCollector()
        for index in 0..<60 {
            flat.append(AcceptanceReport.sample(wall: Double(index * 5), footprint: 100 * 1_024 * 1_024,
                packets: index * 100, eof: false, packetAge: 0))
            growing.append(AcceptanceReport.sample(wall: Double(index * 5),
                footprint: UInt64(100 + index) * 1_024 * 1_024, packets: index * 100, eof: false, packetAge: 0))
        }
        positive["footprint_growth"] = ["samples":try flat.snapshot()]
        negative["footprint_growth"] = ["samples":try growing.snapshot()]
        let result: [String: Any] = ["schema":1,"kind":"native_component_fault_controls",
            "positive":positive,"negative":negative]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        // The runner must pass this actual observation into the production report
        // validator's shared predicates before it may start the capped runs.
        print("HLS_ACCEPTANCE_CONTROLS=" + String(decoding: bytes, as: UTF8.self))
    }

    private func meter(_ pcm: [Float]) throws -> AcceptancePCMStatistics {
        let bytes = pcm.withUnsafeBytes { Data($0) }
        let sample = try PCMSampleBufferBuilder.make(bytes: bytes, frameCount: 48_000,
            sampleRate: 48_000, channels: 2, channelOrder: .native, channelLayoutMask: 3,
            presentationTimeStamp: .zero)
        var result = AcceptancePCMStatistics()
        try result.consume(sample)
        return result
    }
    private func binding(_ value: UInt64) -> FMP4WriterBinding {
        let session = PlaybackSessionIdentity(sessionID: value,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        return FMP4WriterBinding(outputLifecycleEpoch: .init(backendIdentity:
            .init(sessionIdentity: session, backendGeneration: value), outputNonce: value),
            itemGeneration: .init(rawValue: value), mediaEpoch: .init(rawValue: value),
            publicationParticipantID: .init(rawValue: value), renditionIdentity: .init(rawValue: value),
            writerIdentity: .init(rawValue: value))
    }
    private func aacFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let cookie = Data([0x11, 0x90])
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
                extensions: nil, formatDescriptionOut: &format)
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
    private func fragment(sequence: UInt32, time: UInt32, compositionOffset: Int32? = nil) -> Data {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data {
            word(UInt32(payload.count + 8)) + Data(name.utf8) + payload
        }
        let header = box("mfhd", word(0) + word(sequence))
        let run = word(compositionOffset == nil ? 0 : 0x800) + word(1) +
            (compositionOffset.map { word(UInt32(bitPattern: $0)) } ?? Data())
        let track = box("tfhd", word(0) + word(1)) + box("tfdt", word(0) + word(time)) + box("trun", run)
        return box("moof", header + box("traf", track)) + box("mdat", Data([1, 2, 3, 4]))
    }
}

private final class AcceptanceControlRelayHolder: @unchecked Sendable {
    weak var relay: SegmentReportRelay?
}

private struct WithheldInitializationFactory: SegmentedFMP4SystemWriterFactory {
    func makeWriter(configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription, callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting { WithheldInitializationWriter() }
}

/// Inspection adapter only: successful start deliberately never sends the reserved
/// initialization callback, making the real writer/probe pending state observable.
private final class WithheldInitializationWriter: SegmentedFMP4SystemWriting, @unchecked Sendable {
    var objectIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    func startWriting(at sourceTime: CMTime) -> Bool { true }
    func appendAwaitingReadiness(_ sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) async throws {
        throw AcceptanceError.invalid("callback control must not submit media")
    }
    func flushSegment() -> Bool { false }
    func markInputAsFinished() { }
    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func cancelWriting() { }
}
#endif
