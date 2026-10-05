// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
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
        var timing = AcceptanceVideoTiming()
        var decodedCursor = AcceptanceVideoReaderCursor(kind: .decoded)
        var originalCursor = AcceptanceVideoReaderCursor(kind: .original)
        defer {
            var observation = timing.diagnostics
            observation["entry"] = String(describing: entry)
            observation["reader_status"] = reader.status.rawValue
            observation["original_reader_status"] = originalReader.status.rawValue
            observation["decoded_cursor"] = decodedCursor.diagnostics
            observation["original_cursor"] = originalCursor.diagnostics
            if let evidence = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) {
                print("HLS_ACCEPTANCE_REMUX_TIMING=" + String(decoding: evidence, as: UTF8.self))
            }
            if reader.status == .reading { reader.cancelReading() }
            if originalReader.status == .reading { originalReader.cancelReading() }
        }
        try originalReader.start()
        try reader.start()
        while let ready = try await provider.next() {
            guard try decodedCursor.consumesMedia(ready) else { continue }
            var paired = false
            while let original = try await originalProvider.next() {
                guard try originalCursor.consumesMedia(original) else { continue }
                try timing.observe(decoded: makeOwnedReaderFixtureSample(copying: ready),
                    original: makeOwnedReaderFixtureSample(copying: original))
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
        guard reader.status == .completed, originalReader.status == .completed,
              timing.frames > 0, timing.frames == timed.count else {
            throw AcceptanceError.invalid("short paired video decode incomplete")
        }
        try captured.continuity.requireVideoCoverage(timing, timescale: captured.latestMediaTimescale)
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
        bad = decoded; bad.hasImage = false
        XCTAssertThrowsError(try imageCursor.consumesMedia(bad))
        bad = decoded; bad.blockSize = 4
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

    private func checkVideoTimingEvidence() throws {
        let start = CMTime(value: 10, timescale: 1)
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
        XCTAssertNoThrow(try original.requireVideoCoverage(complete, timescale: 48_000))
        var extraFrame = AcceptanceVideoTiming()
        for pts in [start, CMTimeAdd(start, CMTime(value: 1, timescale: 2))] {
            try extraFrame.observe(decodedPTS: pts, decodedDuration: .invalid,
                originalPTS: pts, originalDuration: CMTime(value: 1, timescale: 2),
                decodedCount: 1, originalCount: 1)
        }
        XCTAssertThrowsError(try original.requireVideoCoverage(extraFrame, timescale: 48_000),
            "Matching first/end timestamps cannot hide an extra decoded sample")
        var twoRawSamples = AcceptanceFragmentContinuity()
        try twoRawSamples.observe(fragment(sequence: 1, time: 480_000), defaultDuration: 24_000)
        try twoRawSamples.observe(fragment(sequence: 2, time: 504_000), defaultDuration: 24_000)
        XCTAssertThrowsError(try twoRawSamples.requireVideoCoverage(complete, timescale: 48_000),
            "Matching first/end timestamps cannot hide a missing decoded sample")
        XCTAssertThrowsError(try original.requireVideoCoverage(timing, timescale: 48_000),
            "Equal decoded and raw frame counts plus exact raw endpoints are mandatory")
        var shortEnd = AcceptanceVideoTiming()
        try shortEnd.observe(decodedPTS: start, decodedDuration: .invalid, originalPTS: start,
            originalDuration: duration, decodedCount: 1, originalCount: 1)
        XCTAssertThrowsError(try original.requireVideoCoverage(shortEnd, timescale: 48_000),
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
    private func fragment(sequence: UInt32, time: UInt32) -> Data {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data {
            word(UInt32(payload.count + 8)) + Data(name.utf8) + payload
        }
        let header = box("mfhd", word(0) + word(sequence))
        let track = box("tfhd", word(0) + word(1)) + box("tfdt", word(0) + word(time)) +
            box("trun", word(0) + word(1))
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
