// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import VPlayerCore
@testable import VPlayerPlayback

/// Weak observations distinguish dropping local references from real deallocation.
/// This owner never retains the graph, a publication prefix or native media.
private final class AcceptanceGraphRetirementObservation {
    private weak var authority: SystemHLSMediaGraphAuthority?
    private weak var graph: AcceptanceObservedGraph?
    private weak var assembler: HLSMediaGraphAssembler?

    init(authority: SystemHLSMediaGraphAuthority, graph: AcceptanceObservedGraph,
         assembler: HLSMediaGraphAssembler) {
        self.authority = authority
        self.graph = graph
        self.assembler = assembler
    }

    var allReleased: Bool { authority == nil && graph == nil && assembler == nil }
}

/// Dedicated target only. Portable checks never substitute for these observations.
@MainActor
final class PersistentHLSAcceptanceTests: XCTestCase {
    private var decodeDiagnostics: [String: Any] = [:]
    func testFiveMinuteOriginalNativePlaybackAndRetirement() async throws {
        let wholeTestStart = AcceptanceClock.now
        let environment = ProcessInfo.processInfo.environment
        let head = try XCTUnwrap(environment["HLS_ACCEPTANCE_HEAD"])
        let tree = try XCTUnwrap(environment["HLS_ACCEPTANCE_TREE"])
        let role = try XCTUnwrap(environment["HLS_ACCEPTANCE_ROLE"])
        let expectedFixture = try XCTUnwrap(environment["HLS_ACCEPTANCE_FIXTURE_SHA256"])
        #if HLS_ACCEPTANCE_BASELINE
        XCTAssertEqual(role, "baseline")
        #else
        XCTAssertEqual(role, "candidate")
        let probe = HLSWriterAcceptanceProbe()
        #endif
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "persistent-360s.ts",
            withExtension: nil, subdirectory: "HLSAcceptance"), "Generate the runner-local public fixture first")
        let handle = try FileHandle(forReadingFrom: file)
        var digest = SHA256()
        while true {
            let count = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else { return 0 }
                digest.update(data: chunk)
                return chunk.count
            }
            if count == 0 { break }
        }
        try handle.close()
        let fixture = digest.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fixture, expectedFixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try AcceptanceHTTPServer(fileURL: file)
        defer { server.stop() }
        let capture = AcceptanceCapture(directory: directory)
        let firstFailure = AcceptanceFailureCapture()
        let ledgerBefore = ledgers()
        let identity = PlaybackSessionIdentity(sessionID: 30_000,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000030000")!)
        let lifecycle = OutputLifecycleEpoch(backendIdentity:
            .init(sessionIdentity: identity, backendGeneration: 30_001), outputNonce: 30_002)
        #if HLS_ACCEPTANCE_BASELINE
        var authority: SystemHLSMediaGraphAuthority? = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 300_000_000_000, failureSink: { firstFailure.record($0, origin: "authority") })
        #else
        var authority: SystemHLSMediaGraphAuthority? = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 300_000_000_000, acceptanceProbe: probe,
            failureSink: { firstFailure.record($0, origin: "authority") })
        #endif
        authority!.publicationForTesting.installBeforeReceiveForTesting { capture.receive($0) }
        var graph: AcceptanceObservedGraph? = AcceptanceObservedGraph(authority: authority!)
        var assembler: HLSMediaGraphAssembler? = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: .shared, graph: graph!)
        let retiredOwners = AcceptanceGraphRetirementObservation(
            authority: authority!, graph: graph!, assembler: assembler!)
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        let collector = AcceptanceSampleCollector()
        let startedUnix = Date().timeIntervalSince1970
        let start = AcceptanceClock.now
        let cpuStart = try processCPUSeconds()
        // The one299.5-second source/player deadline starts BEFORE prebuffer.
        let watchdog = AcceptancePlaybackDeadline(player: player, server: server, start: start)
        // Capture weak values, never the caller's mutable optional boxes. Parent
        // roots stay alive until cancel + join; the task handle owns no graph.
        let sampler = Task { @MainActor [weak graph, weak authority] in
            do {
                var nextSample = 0.0
                while !watchdog.hasStopped && !Task.isCancelled {
                    let wall = AcceptanceClock.now - start
                    if wall >= nextSample && nextSample < 300 {
                        guard let graph, authority != nil else {
                            throw AcceptanceError.invalid("active sampler lost graph ownership")
                        }
                        var sample = AcceptanceReport.sample(wall: wall, footprint: try nativeFootprint(),
                            packets: graph.packetCount, eof: graph.hasEOF,
                            packetAge: max(0, AcceptanceClock.now - graph.lastPacketTime))
                        #if !HLS_ACCEPTANCE_BASELINE
                        let value = probe.snapshot
                        guard value.isComplete else { throw AcceptanceError.invalid("native diagnostic capacity exceeded") }
                        sample.merge(diagnosticFields(value)) { _, new in new }
                        sample.merge(try ledgerSample(authority!)) { _, new in new }
                        #endif
                        collector.append(sample)
                        nextSample += 5
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch is CancellationError { }
            catch { firstFailure.record(ErrorDiagnosticSnapshot(error), origin: "sampler"); collector.fail(error); watchdog.stop() }
        }
        defer { sampler.cancel(); watchdog.stop() }
        var report: [String: Any] = [:]
        var stopObservation: [String: Any] = [:]
        var renditions: [[String: Any]] = []
        var retiredGraphDiagnostics: [String: Any] = [:]
        var stage = "await_playable_prefix"
        var playbackBeganAt: Double?
        var firstMediaTime: Double?
        var lastTime = 0.0
        var lastProgress = start
        do {
            var prefix: AVPlayerItemReplacementBundle? = try await assembler!.startUntilPlayablePrefix()
            stage = "await_native_item_ready"
            var item: AVPlayerItem? = AVPlayerItem(url: prefix!.request.itemURL)
            // The assembler owns the active prefix. This local URL consumer must
            // not keep its preparation evidence/history alive past retirement.
            prefix = nil
            player.replaceCurrentItem(with: item)
            let readyDeadline = min(start + 299.5, AcceptanceClock.now + 15)
            while item?.status == .unknown && AcceptanceClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard item?.status == .readyToPlay else {
                throw AcceptanceError.invalid("native item never ready: \(String(describing: item?.error))")
            }
            guard !watchdog.hasStopped else { throw AcceptanceError.invalid("preparation consumed the observation window") }
            let playbackStart = AcceptanceClock.now
            let initialMedia = player.currentTime().seconds
            let mediaStart = initialMedia.isFinite ? initialMedia : 0
            var firstProgress: Double?
            playbackBeganAt = playbackStart
            firstMediaTime = mediaStart
            lastTime = mediaStart
            lastProgress = playbackStart
            stage = "playing"
            player.play()
            while !watchdog.hasStopped {
                let now = AcceptanceClock.now
                let media = player.currentTime().seconds
                if media.isFinite && media > lastTime {
                    if firstProgress == nil { firstProgress = now }
                    lastTime = media
                    lastProgress = now
                }
                guard now - lastProgress < 5 else { throw AcceptanceError.invalid("AVPlayer clock stalled for five seconds") }
                try await Task.sleep(for: .milliseconds(20))
            }
            stage = "post_stop_observations"
            let samples = try collector.snapshot()
            let measured = try XCTUnwrap(watchdog.measuredSeconds)
            XCTAssertGreaterThanOrEqual(measured, 299)
            XCTAssertLessThanOrEqual(measured, 300, "Actual native source/player observation exceeded the cap")
            let media = player.currentTime().seconds - mediaStart
            let cpuSeconds = try processCPUSeconds() - cpuStart
            stopObservation = ["fully_validated":false,"wall_seconds":measured,
                "playback_wall_seconds":start + measured - playbackStart,"prebuffer_seconds":playbackStart - start,
                "media_seconds":AcceptanceReport.finite(media),"sample_count":samples.count,
                "sampled_peak_footprint_bytes":samples.compactMap { $0["footprint_bytes"] as? UInt64 }.max() ?? 0,
                "ledger_before":ledgerBefore]
            let transport = server.transportSnapshot
            // Request telemetry only after the common source/player deadline.
            // SDK27: fetchAccessLog(completionHandler:) delivers a sending log;
            // reduce it inside the callback and retain only scalar observations.
            let access = AcceptanceAccessLogCapture(deadline: AcceptanceClock.now + 2)
            item?.fetchAccessLog(completionHandler: { log in
                let events = log?.events
                access.complete(droppedFrames: events?.reduce(0) { $0 + $1.numberOfDroppedVideoFrames },
                    stalls: events?.reduce(0) { $0 + $1.numberOfStalls }, at: AcceptanceClock.now)
            })
            stage = "joined_retirement"
            let cleanupStart = AcceptanceClock.now
            player.replaceCurrentItem(with: nil)
            item = nil
            sampler.cancel()
            await sampler.value
            let retired = await assembler!.retireAndAwaitReceipt()
            XCTAssertTrue(retired)
            retiredGraphDiagnostics = graphDiagnostics(assembler: assembler, graph: graph)
            // Retirement joins native work; final app charges follow actual last
            // aliases. Drop all harness roots after the sampler has really exited.
            assembler = nil
            graph = nil
            authority = nil
            let retireDeadline = AcceptanceClock.now + 10
            while (ledgers() != ledgerBefore || !retiredOwners.allReleased)
                && AcceptanceClock.now < retireDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let tracks = try capture.finish()
            let cleanupSeconds = AcceptanceClock.now - cleanupStart
            stopObservation["cleanup_joined"] = retired
            stopObservation["cleanup_seconds"] = cleanupSeconds
            stopObservation["ledger_after"] = ledgers()
            let ownersReleased = retiredOwners.allReleased
            stopObservation["harness_graph_owners_released"] = ownersReleased
            #if !HLS_ACCEPTANCE_BASELINE
            stopObservation.merge(AcceptanceReport.retirement(probe.snapshot)) { _, new in new }
            #endif
            guard ownersReleased, ledgers() == ledgerBefore else {
                throw AcceptanceError.invalid("retired graph charges did not return to the initialized ledger baseline")
            }
            // Retirement is physically joined before any remaining telemetry wait
            // or timeout failure. This wait is outside playback and cleanup time.
            let accessWaitStart = AcceptanceClock.now
            while !access.hasResult && AcceptanceClock.now < access.deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let accessSnapshot = try access.finish()
            let accessWaitSeconds = AcceptanceClock.now - accessWaitStart
            stage = "offline_decode"
            let decodeStart = AcceptanceClock.now
            for track in tracks { renditions.append(try await decode(track)) }
            let decodeSeconds = AcceptanceClock.now - decodeStart
            report = ["schema":1,"role":role,"native_evidence":true,"head":head,"tree":tree,
                "overlay_sha256":environment["HLS_ACCEPTANCE_OVERLAY_SHA256"] ?? "",
                "measurement_sha256":environment["HLS_ACCEPTANCE_MEASUREMENT_SHA256"] ?? "",
                "fixture_sha256":fixture,"os":ProcessInfo.processInfo.operatingSystemVersionString,
                "device":deviceIdentity(),"started_unix":startedUnix,"completed_unix":Date().timeIntervalSince1970,
                "wall_seconds":measured,"media_seconds":media,
                "playback_wall_seconds":max(0, start + measured - playbackStart),"prebuffer_seconds":playbackStart - start,
                "warmup_seconds":60,"sample_interval_seconds":5,"samples":samples,"renditions":renditions,
                "ledger_before":ledgerBefore,"ledger_after":ledgers(),"original_fragment_bytes":true,
                "physical_homepod_verified":false,"playback_cpu_seconds":cpuSeconds,
                "startup_seconds":(firstProgress ?? playbackStart) - start,
                "first_clock_advance_seconds":(firstProgress ?? playbackStart) - playbackStart,
                "cleanup_seconds":cleanupSeconds,"decode_seconds":decodeSeconds,
                "access_log_wait_seconds":accessWaitSeconds,"access_log_status":accessSnapshot.status.rawValue,
                "whole_test_seconds":AcceptanceClock.now - wholeTestStart,
                "route":"local-loopback-AVPlayer; physical HomePod and AirPlay unavailable",
                "paced_transport_bps":38_000_000,"ts_muxrate_bps":37_000_000,
                "source_bytes_delivered":transport.bytes,
                "measured_transport_bps":Double(transport.bytes) * 8 / max(0.001, start + measured - (transport.start ?? start))]
            report["dropped_video_frames"] = accessSnapshot.droppedFrames.map { $0 as Any } ?? NSNull()
            report["access_log_stalls"] = accessSnapshot.stalls.map { $0 as Any } ?? NSNull()
            #if !HLS_ACCEPTANCE_BASELINE
            let final = probe.snapshot
            guard final.isComplete else { throw AcceptanceError.invalid("incomplete native diagnostics") }
            report.merge(AcceptanceReport.retirement(final)) { _, new in new }
            report["ledger_policy"] = ledgerPolicy()
            report["global_maximum_charged_bytes"] = HLSDeliveryApplicationChargeLedger.shared.maximumChargedBytes
            #endif
        } catch {
            // Capture before cleanup cancels writers/demux and overwrites stages.
            // This diagnostic is not an acceptance report or a baseline measurement.
            var failure: [String: Any] = ["role":role,"stage":stage,
                "error":ErrorDiagnosticSnapshot(error).summary,
                "whole_test_seconds":AcceptanceClock.now - wholeTestStart,
                "task_cancelled":Task.isCancelled,"watchdog_stopped":watchdog.hasStopped,
                "first_runtime_failure":firstFailure.snapshot,
                "transport":server.failureDiagnostics,"capture":capture.failureDiagnostics,
                "player":failurePlayerState(player),
                "prebuffer_seconds":AcceptanceReport.finite(playbackBeganAt.map { $0 - start }),
                "first_media_seconds":AcceptanceReport.finite(firstMediaTime),
                "last_advancing_media_seconds":AcceptanceReport.finite(playbackBeganAt == nil ? nil : lastTime),
                "stop_observation":stopObservation,"completed_decode_results":renditions,"decode":decodeDiagnostics,
                "history":acceptanceDiagnosticHistoryTail(PlaybackDiagnosticTracker.shared.recentHistory)]
            failure.merge(retiredGraphDiagnostics.isEmpty
                ? graphDiagnostics(assembler: assembler, graph: graph) : retiredGraphDiagnostics) { _, new in new }
            failure.merge(AcceptanceReport.failureTiming(elapsed: AcceptanceClock.now - start,
                stopped: watchdog.measuredSeconds, playbackStart: playbackBeganAt.map { $0 - start },
                lastProgress: playbackBeganAt == nil ? nil : lastProgress - start)) { _, new in new }
            if let bytes = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
                print("HLS_ACCEPTANCE_FAILURE=" + String(decoding: bytes, as: UTF8.self))
            }
            let cleanupStart = AcceptanceClock.now
            watchdog.stop()
            player.replaceCurrentItem(with: nil)
            sampler.cancel()
            await sampler.value
            let retired = if let assembler { await assembler.retireAndAwaitReceipt() }
                else { stopObservation["cleanup_joined"] as? Bool ?? false }
            assembler = nil
            graph = nil
            authority = nil
            print("HLS_ACCEPTANCE_FAILURE_CLEANUP=retired:\(retired),seconds:\(AcceptanceClock.now - cleanupStart)")
            throw error
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("HLS_ACCEPTANCE_REPORT=" + String(decoding: bytes, as: UTF8.self))
    }

    /// Read once on failure, before pause/removal changes the actual player state.
    private func failurePlayerState(_ player: AVPlayer) -> [String: Any] {
        var result: [String: Any] = ["status":player.status.rawValue,
            "time_control_status":player.timeControlStatus.rawValue,
            "waiting_reason":player.reasonForWaitingToPlay.map { String($0.rawValue.prefix(256)) as Any } ?? NSNull(),
            "rate":AcceptanceReport.finite(Double(player.rate)),
            "current_time":AcceptanceReport.time(player.currentTime()),
            "automatically_waits":player.automaticallyWaitsToMinimizeStalling,
            "error":player.error.map { ErrorDiagnosticSnapshot($0).summary as Any } ?? NSNull(),
            "has_current_item":player.currentItem != nil]
        if let item = player.currentItem {
            result["item"] = ["status":item.status.rawValue,
                "error":item.error.map { ErrorDiagnosticSnapshot($0).summary as Any } ?? NSNull(),
                "current_time":AcceptanceReport.time(item.currentTime()),
                "duration":AcceptanceReport.time(item.duration),
                "buffer_empty":item.isPlaybackBufferEmpty,"buffer_full":item.isPlaybackBufferFull,
                "likely_to_keep_up":item.isPlaybackLikelyToKeepUp,
                "loaded":AcceptanceReport.ranges(item.loadedTimeRanges),
                "seekable":AcceptanceReport.ranges(item.seekableTimeRanges)] as [String: Any]
        }
        return result
    }

    private func graphDiagnostics(assembler: HLSMediaGraphAssembler?,
                                  graph: AcceptanceObservedGraph?) -> [String: Any] {
        ["assembler_phase":assembler.map { String(describing: $0.currentPhase) } ?? "released",
         "authority_failure":graph?.failureDiagnostic?.summary ?? "none",
         "producer_packets":graph?.packetCount ?? 0,"producer_eof":graph?.hasEOF ?? false,
         "last_demux_control":graph?.lastControlDiagnostic ?? "none"]
    }

    private func ledgers() -> [String: Int] {
        // Resource bootstrap also charges application. Initialize it before
        // reading either total, including the very first cold-process sample.
        let resource = PlaybackResourceContextLedger.shared
        return ["application":HLSDeliveryApplicationChargeLedger.shared.chargedBytes,
                "resource":resource.chargedBytes]
    }
    private func deviceIdentity() -> String {
        let environment = ProcessInfo.processInfo.environment
        #if targetEnvironment(simulator)
        return "simulator:" + (environment["SIMULATOR_UDID"] ?? "missing-identity") + ":" +
            (environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "missing-model")
        #else
        return "physical:" + (environment["HLS_ACCEPTANCE_DEVICE_ID"] ?? "missing-identity")
        #endif
    }
    private func processCPUSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw AcceptanceError.invalid("getrusage failed") }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private func nativeFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw AcceptanceError.invalid("TASK_VM_INFO unavailable: \(result)") }
        return info.phys_footprint
    }
    #if !HLS_ACCEPTANCE_BASELINE
    private func ledgerPolicy() -> [String: Any] {
        let store = PlaybackCapacityEnvelope.current.sealedMediaStoreLimit
        return ["application_soft_bytes":HLSDeliveryApplicationChargeLedger.softCapBytes,
                "application_hard_bytes":HLSDeliveryApplicationChargeLedger.hardCapBytes,
                "store_soft_bytes":store.softBytes,"store_hard_bytes":store.hardBytes,
                "resource_hard_bytes":PlaybackResourceContextLedger.hardBytes,
                "store_observation":"body_subtotal_excludes_metadata"]
    }
    private func ledgerSample(_ authority: SystemHLSMediaGraphAuthority) throws -> [String: Any] {
        let publication = authority.publicationForTesting
        // Existing graph -> store lock ordering. No object/lease escapes the read.
        let usage = try publication.withActivePublication { publication.store?.usage }
        return ["application_charged_bytes":HLSDeliveryApplicationChargeLedger.shared.chargedBytes,
                "resource_charged_bytes":PlaybackResourceContextLedger.shared.chargedBytes,
                "store_body_bytes":(usage?.residentBytes ?? 0) + (usage?.reservedBytes ?? 0),
                "store_should_backpressure":usage?.shouldBackpressure ?? false]
    }
    private func diagnosticFields(_ value: HLSWriterAcceptanceSnapshot) -> [String: Any] {
        ["live_inputs":value.liveInputCount,"live_bytes":value.liveInputBytes,"evidence":value.evidenceCount,
         "callbacks":value.pendingCallbacks,"hard_inputs":value.hardInputCount,"hard_bytes":value.hardInputBytes,
         "hard_evidence":value.hardEvidenceCount,"hard_callbacks":value.hardCallbackCount,
         "accepted_inputs":value.acceptedInputCount,"released_inputs":value.releasedInputCount]
    }
    #endif
    private func decode(_ track: AcceptanceCapture.Track) async throws -> [String: Any] {
        decodeDiagnostics = ["kind":track.kind,"stage":"load_tracks","initialization_format":track.initializationFormat]
        let asset = AVURLAsset(url: track.url)
        let type: AVMediaType = track.kind == "audio" ? .audio : .video
        let loaded = try await asset.loadTracks(withMediaType: type)
        let source = try XCTUnwrap(loaded.first)
        decodeDiagnostics["stage"] = "load_formats"
        let formats = try await source.load(.formatDescriptions)
        decodeDiagnostics["reader_formats"] = formats.prefix(4).map { AcceptanceReport.format($0) }
        if let bytes = try? JSONSerialization.data(withJSONObject: decodeDiagnostics, options: [.sortedKeys]) {
            print("HLS_ACCEPTANCE_DECODE_FORMAT=" + String(decoding: bytes, as: UTF8.self))
        }
        if track.kind == "video" { return try await decodeVideo(track, asset: asset, source: source) }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = track.kind == "audio" ? [
            AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,
            AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false
        ] : [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output))
        let provider = reader.outputProvider(for: output)
        var frames = 0
        defer {
            decodeDiagnostics["reader_status"] = reader.status.rawValue
            decodeDiagnostics["decoded_frames"] = frames
            decodeDiagnostics["reader_error"] = reader.error.map { ErrorDiagnosticSnapshot($0).summary as Any } ?? NSNull()
            if reader.status == .reading { reader.cancelReading() }
        }
        decodeDiagnostics["stage"] = "reader_start"
        try reader.start()
        decodeDiagnostics["stage"] = "reader_output"
        var audio = AcceptancePCMStatistics()
        var first: CMTime?
        var previousEnd: CMTime?
        var gap = 0.0
        while let ready = try await provider.next() {
            let sample = try makeOwnedReaderFixtureSample(copying: ready)
            if track.kind == "audio" { try audio.consume(sample) }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            guard time.isNumeric, duration.isNumeric, duration.seconds > 0 else {
                throw AcceptanceError.invalid("decoded timestamp/duration unavailable")
            }
            if first == nil { first = time }
            if let previousEnd { gap = max(gap, abs(CMTimeSubtract(time, previousEnd).seconds)) }
            previousEnd = CMTimeAdd(time, duration)
            frames += CMSampleBufferGetNumSamples(sample)
            if track.kind == "video", CMSampleBufferGetImageBuffer(sample) == nil {
                throw AcceptanceError.invalid("video was not really decoded")
            }
        }
        guard reader.status == .completed, let first, let previousEnd else {
            throw AcceptanceError.invalid("incomplete native decode: \(String(describing: reader.error))")
        }
        var result: [String: Any] = ["kind":track.kind,"writer_count":track.writers.count,
            "init_count":track.inits,"fragments":track.fragments,"decoded_frames":frames,
            "decoded_seconds":CMTimeSubtract(previousEnd, first).seconds,"maximum_gap_seconds":gap]
        result.merge(AcceptanceReport.fragment(track.continuity)) { _, new in new }
        if track.kind == "audio" { result.merge(AcceptanceReport.audio(audio)) { _, new in new } }
        return result
    }
    private func decodeVideo(_ track: AcceptanceCapture.Track, asset: AVAsset, source: AVAssetTrack) async throws -> [String: Any] {
        let reader = try AVAssetReader(asset: asset)
        let originalReader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let originalOutput = AVAssetReaderTrackOutput(track: source, outputSettings: nil)
        guard reader.canAdd(output), originalReader.canAdd(originalOutput) else {
            throw AcceptanceError.invalid("video timing reader cannot add output")
        }
        let provider = reader.outputProvider(for: output)
        let originalProvider = originalReader.outputProvider(for: originalOutput)
        var timing = AcceptanceVideoTiming()
        var decodedCursor = AcceptanceVideoReaderCursor(kind: .decoded)
        var originalCursor = AcceptanceVideoReaderCursor(kind: .original)
        var mapping: AcceptanceVideoTimelineMapping?
        defer {
            decodeDiagnostics["reader_status"] = reader.status.rawValue
            decodeDiagnostics["original_reader_status"] = originalReader.status.rawValue
            decodeDiagnostics["original_reader_error"] = originalReader.error.map { ErrorDiagnosticSnapshot($0).summary as Any } ?? NSNull()
            decodeDiagnostics["decoded_frames"] = timing.frames
            decodeDiagnostics["sample_timing"] = timing.diagnostics
            decodeDiagnostics["decoded_cursor"] = decodedCursor.diagnostics
            decodeDiagnostics["original_cursor"] = originalCursor.diagnostics
            decodeDiagnostics["raw"] = track.continuity.failureDiagnostics(timescale: track.latestMediaTimescale, mapping: mapping)
            decodeDiagnostics["reader_error"] = reader.error.map { ErrorDiagnosticSnapshot($0).summary as Any } ?? NSNull()
            if reader.status == .reading { reader.cancelReading() }
            if originalReader.status == .reading { originalReader.cancelReading() }
        }
        decodeDiagnostics["stage"] = "video_timeline_mapping"
        mapping = AcceptanceVideoTimelineMapping(segments: try await source.load(.segments))
        decodeDiagnostics["stage"] = "paired_video_reader_start"
        try originalReader.start()
        try reader.start()
        decodeDiagnostics["stage"] = "paired_video_timing"
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
                throw AcceptanceError.invalid("decoded video has no original sample timing")
            }
        }
        while let original = try await originalProvider.next() {
            if try originalCursor.consumesMedia(original) {
                throw AcceptanceError.invalid("original video sample has no decoded image")
            }
        }
        guard reader.status == .completed, originalReader.status == .completed,
              let seconds = timing.decodedSeconds else {
            throw AcceptanceError.invalid("paired video read incomplete")
        }
        try track.continuity.requireVideoCoverage(timing, timescale: track.latestMediaTimescale,
            mapping: XCTUnwrap(mapping))
        var result: [String: Any] = ["kind":"video","writer_count":track.writers.count,
            "init_count":track.inits,"fragments":track.fragments,"decoded_frames":timing.frames,
            "decoded_seconds":seconds,"maximum_gap_seconds":timing.maximumGapSeconds,
            "missing_decoded_durations":timing.missingDecodedDurations,
            "decoded_cursor":decodedCursor.diagnostics,"original_cursor":originalCursor.diagnostics,
            "raw":track.continuity.failureDiagnostics(timescale: track.latestMediaTimescale, mapping: mapping),
            "timing_evidence":"original compressed duration matched to every decoded PTS and native-mapped raw fragment endpoints"]
        result.merge(AcceptanceReport.fragment(track.continuity)) { _, new in new }
        return result
    }

}

/// Bounded completion state shared by the real SDK callback and short controls.
/// No AVPlayerItem, access log, event array, graph or media owner is retained here.
final class AcceptanceAccessLogCapture: @unchecked Sendable {
    enum Status: String, Sendable { case available, unavailable, timedOut = "timed_out" }
    struct Snapshot: Sendable, Equatable {
        let status: Status
        let droppedFrames: Int?
        let stalls: Int?
        static let timedOut = Self(status: .timedOut, droppedFrames: nil, stalls: nil)
    }
    let deadline: Double
    private let lock = NSLock()
    private var value: Snapshot?
    init(deadline: Double) { self.deadline = deadline }
    var hasResult: Bool { lock.withLock { value != nil } }
    func complete(droppedFrames: Int?, stalls: Int?, at instant: Double) {
        lock.withLock {
            guard value == nil else { return }
            guard instant.isFinite, instant < deadline else { value = .timedOut; return }
            value = .init(status: droppedFrames == nil && stalls == nil ? .unavailable : .available,
                droppedFrames: droppedFrames, stalls: stalls)
        }
    }
    func finish() throws -> Snapshot {
        try lock.withLock {
            let result = value ?? .timedOut
            value = result
            guard result.status != .timedOut else {
                throw AcceptanceError.invalid("AVPlayer access-log callback exceeded the two-second post-stop deadline")
            }
            return result
        }
    }
}

/// Independent queue closes both the source and player at their COMMON deadline.
/// It is never restarted after prebuffer. Actual elapsed beyond300 still fails.
private final class AcceptancePlaybackDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let player: AVPlayer
    private let server: AcceptanceHTTPServer
    private let start: Double
    private let timer: DispatchSourceTimer
    private var measured: Double?
    init(player: AVPlayer, server: AcceptanceHTTPServer, start: Double) {
        self.player = player
        self.server = server
        self.start = start
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hls.acceptance.deadline", qos: .userInteractive))
        timer.schedule(deadline: .now() + max(0, 299.5 - (AcceptanceClock.now - start)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.stop() }
        timer.resume()
    }
    var measuredSeconds: Double? { lock.withLock { measured } }
    var hasStopped: Bool { measuredSeconds != nil }
    func stop() {
        lock.withLock {
            guard measured == nil else { return }
            player.pause()
            server.stop()
            measured = AcceptanceClock.now - start
            timer.cancel()
        }
    }
}
