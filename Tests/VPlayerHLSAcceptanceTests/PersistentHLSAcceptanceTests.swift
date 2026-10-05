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

/// Dedicated target only. Portable checks never substitute for these observations.
@MainActor
final class PersistentHLSAcceptanceTests: XCTestCase {
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
        let ledgerBefore = ledgers()
        let identity = PlaybackSessionIdentity(sessionID: 30_000,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000030000")!)
        let lifecycle = OutputLifecycleEpoch(backendIdentity:
            .init(sessionIdentity: identity, backendGeneration: 30_001), outputNonce: 30_002)
        #if HLS_ACCEPTANCE_BASELINE
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 300_000_000_000)
        #else
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle,
            publicationDeadlineNanoseconds: 300_000_000_000, acceptanceProbe: probe)
        #endif
        authority.publicationForTesting.installBeforeReceiveForTesting { capture.receive($0) }
        let graph = AcceptanceObservedGraph(authority: authority)
        let assembler = HLSMediaGraphAssembler(sourceURL: server.sourceURL,
            applicationLedger: .shared, graph: graph)
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        let collector = AcceptanceSampleCollector()
        let startedUnix = Date().timeIntervalSince1970
        let start = AcceptanceClock.now
        let cpuStart = try processCPUSeconds()
        // The one299.5-second source/player deadline starts BEFORE prebuffer.
        let watchdog = AcceptancePlaybackDeadline(player: player, server: server, start: start)
        let sampler = Task { @MainActor in
            do {
                var nextSample = 0.0
                while !watchdog.hasStopped && !Task.isCancelled {
                    let wall = AcceptanceClock.now - start
                    if wall >= nextSample && nextSample < 300 {
                        var sample = AcceptanceReport.sample(wall: wall, footprint: try nativeFootprint(),
                            packets: graph.packetCount, eof: graph.hasEOF,
                            packetAge: max(0, AcceptanceClock.now - graph.lastPacketTime))
                        #if !HLS_ACCEPTANCE_BASELINE
                        let value = probe.snapshot
                        guard value.isComplete else { throw AcceptanceError.invalid("native diagnostic capacity exceeded") }
                        sample.merge(diagnosticFields(value)) { _, new in new }
                        #endif
                        collector.append(sample)
                        nextSample += 5
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch is CancellationError { }
            catch { collector.fail(error); watchdog.stop() }
        }
        defer { sampler.cancel(); watchdog.stop() }
        var report: [String: Any] = [:]
        do {
            let prefix = try await assembler.startUntilPlayablePrefix()
            let item = AVPlayerItem(url: prefix.request.itemURL)
            player.replaceCurrentItem(with: item)
            let readyDeadline = min(start + 299.5, AcceptanceClock.now + 15)
            while item.status == .unknown && AcceptanceClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard item.status == .readyToPlay else {
                throw AcceptanceError.invalid("native item never ready: \(String(describing: item.error))")
            }
            guard !watchdog.hasStopped else { throw AcceptanceError.invalid("preparation consumed the observation window") }
            let playbackStart = AcceptanceClock.now
            let initialMedia = player.currentTime().seconds
            let mediaStart = initialMedia.isFinite ? initialMedia : 0
            var firstProgress: Double?
            var lastTime = mediaStart
            var lastProgress = playbackStart
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
            let samples = try collector.snapshot()
            let measured = try XCTUnwrap(watchdog.measuredSeconds)
            XCTAssertGreaterThanOrEqual(measured, 299)
            XCTAssertLessThanOrEqual(measured, 300, "Actual native source/player observation exceeded the cap")
            let media = player.currentTime().seconds - mediaStart
            let cpuSeconds = try processCPUSeconds() - cpuStart
            let transport = server.transportSnapshot
            let access = item.accessLog()?.events
            let dropped = access?.reduce(0) { $0 + $1.numberOfDroppedVideoFrames }
            let stalls = access?.reduce(0) { $0 + $1.numberOfStalls }
            let cleanupStart = AcceptanceClock.now
            player.replaceCurrentItem(with: nil)
            let retired = await assembler.retireAndAwaitReceipt()
            XCTAssertTrue(retired)
            let retireDeadline = AcceptanceClock.now + 10
            while ledgers() != ledgerBefore && AcceptanceClock.now < retireDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let tracks = try capture.finish()
            let cleanupSeconds = AcceptanceClock.now - cleanupStart
            let decodeStart = AcceptanceClock.now
            var renditions: [[String: Any]] = []
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
                "whole_test_seconds":AcceptanceClock.now - wholeTestStart,
                "route":"local-loopback-AVPlayer; physical HomePod and AirPlay unavailable",
                "paced_transport_bps":38_000_000,"ts_muxrate_bps":37_000_000,
                "source_bytes_delivered":transport.bytes,
                "measured_transport_bps":Double(transport.bytes) * 8 / max(0.001, start + measured - (transport.start ?? start))]
            report["dropped_video_frames"] = dropped.map { $0 as Any } ?? NSNull()
            report["access_log_stalls"] = stalls.map { $0 as Any } ?? NSNull()
            #if !HLS_ACCEPTANCE_BASELINE
            let final = probe.snapshot
            guard final.isComplete else { throw AcceptanceError.invalid("incomplete native diagnostics") }
            report.merge(AcceptanceReport.retirement(final)) { _, new in new }
            #endif
        } catch {
            player.pause()
            server.stop()
            player.replaceCurrentItem(with: nil)
            _ = await assembler.retireAndAwaitReceipt()
            throw error
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("HLS_ACCEPTANCE_REPORT=" + String(decoding: bytes, as: UTF8.self))
    }

    private func ledgers() -> [String: Int] {
        ["application":HLSDeliveryApplicationChargeLedger.shared.chargedBytes,
         "resource":PlaybackResourceContextLedger.shared.chargedBytes]
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
    private func diagnosticFields(_ value: HLSWriterAcceptanceSnapshot) -> [String: Any] {
        ["live_inputs":value.liveInputCount,"live_bytes":value.liveInputBytes,"evidence":value.evidenceCount,
         "callbacks":value.pendingCallbacks,"hard_inputs":value.hardInputCount,"hard_bytes":value.hardInputBytes,
         "hard_evidence":value.hardEvidenceCount,"hard_callbacks":value.hardCallbackCount,
         "accepted_inputs":value.acceptedInputCount,"released_inputs":value.releasedInputCount]
    }
    #endif
    private func decode(_ track: AcceptanceCapture.Track) async throws -> [String: Any] {
        let asset = AVURLAsset(url: track.url)
        let type: AVMediaType = track.kind == "audio" ? .audio : .video
        let loaded = try await asset.loadTracks(withMediaType: type)
        let source = try XCTUnwrap(loaded.first)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = track.kind == "audio" ? [
            AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,
            AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false
        ] : [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output))
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        var audio = AcceptancePCMStatistics()
        var frames = 0
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
