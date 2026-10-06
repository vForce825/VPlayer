// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

public struct FFmpegHLSContainerInspector: HLSContainerInspecting {
    public init() {}
    public func inspect(data: Data, url: URL, deadline: UInt64) async throws -> HLSMediaFacts {
        try await inspect(data: data, url: url, deadline: deadline, completeness: .complete)
    }
    public func inspect(data: Data, url: URL, deadline: UInt64, completeness: HLSMediaCompleteness) async throws -> HLSMediaFacts {
        // GCD does not inherit task locals. The state clears this paid alias
        // before resuming its caller; playback work cannot retain it.
        let state = SourceInspectionState(input: data, diagnostics: HLSPreparationDiagnostics.current)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let now = HLSMonotonicClock.now
                    guard now < deadline else {
                        state.releaseDiagnostics(); continuation.resume(throwing: HLSSourceError.deadline); return
                    }
                    var container: Int32 = 0
                    var diagnostic = VPFFSourceDiagnostic()
                    let result = state.inspectInput(completeness: completeness,
                        timeout: Int64(min(10_000_000, (deadline-now)/1_000)), container: &container, diagnostic: &diagnostic)
                    let outcome: Result<HLSMediaFacts, any Error>
                    if state.isCancelled { outcome = .failure(CancellationError()) }
                    else if HLSMonotonicClock.now >= deadline { outcome = .failure(HLSSourceError.deadline) }
                    else if result < 0 {
                        state.rejectedContainer(diagnostic)
                        outcome = .failure(HLSSourceError.unsupportedMedia)
                    } else {
                        outcome = Result { try state.facts(url: url, container: container, deadline: deadline) }
                    }
                    state.releaseDiagnostics()
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: { state.cancel() }
    }
}

/// Only ISO unspecified 2 is absence. Matrix 0 is explicit identity/RGB;
/// reserved and out-of-range declarations must survive reconciliation then fail mapping.
enum HLSSourceVideoProjection {
    enum Failure: Error { case contradictory, unsupportedColor }
    static func colorCode(_ value: Int32) -> Int32? { value == 2 ? nil : value }
    static func dimension(_ value: Int32) -> Int32? { value > 0 ? value : nil }
    static func reconcile<T: Equatable>(parameterSet: T?, container: T?, parser: T?) throws -> T? {
        let available = [parameterSet, container, parser].compactMap { $0 }
        guard let first = available.first else { return nil }
        guard available.allSatisfy({ $0 == first }) else { throw Failure.contradictory }
        return first
    }
    static func reconcileColor<T: RawRepresentable>(parameterSet: T?, container: Int32, parser: Int32) throws -> T? where T.RawValue == UInt16 {
        guard let code = try reconcile(parameterSet: parameterSet.map { Int32($0.rawValue) }, container: colorCode(container), parser: colorCode(parser)) else { return nil }
        guard let raw = UInt16(exactly: code), let supported = T(rawValue: raw) else { throw Failure.unsupportedColor }
        return supported
    }
}

private final class SourceInspectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    // Owned by one synchronous native/Swift work item. Only cancellation uses the lock.
    private var videos: [HLSVideoFacts] = []
    private var pendingAudio: [(VPFFSourceTrack, Data, Data, Data)] = []
    private var unsupported = false
    private var input: Data?
    private var diagnostics: HLSPreparationDiagnostics?
    init(input: Data, diagnostics: HLSPreparationDiagnostics?) { self.input = input; self.diagnostics = diagnostics }
    func rejectedContainer(_ diagnostic: VPFFSourceDiagnostic) { diagnostics?.rejectedContainer(diagnostic) }
    func releaseDiagnostics() { diagnostics = nil }
    /// Dispatch captures this small owner, not a separate input Data alias.
    /// Release the media backing synchronously after native cleanup and before
    /// resuming the awaiting caller or entering the independent AAC phase.
    func inspectInput(completeness: HLSMediaCompleteness, timeout: Int64, container: inout Int32,
                      diagnostic: inout VPFFSourceDiagnostic) -> Int32 {
        defer { input = nil }
        guard let bytes = input else { return -1 }
        return bytes.withUnsafeBytes { buffer in
            vp_ffmpeg_inspect_source_bytes_with_completeness_and_diagnostics(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                completeness == .prefix ? 1 : 0, timeout, { context in
                    guard let context else { return 1 }
                    return Unmanaged<SourceInspectionState>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                }, { context, track in
                    guard let context, let track else { return }
                    Unmanaged<SourceInspectionState>.fromOpaque(context).takeUnretainedValue().receive(track.pointee)
                }, Unmanaged.passUnretained(self).toOpaque(), &container, &diagnostic)
        }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func receive(_ track: VPFFSourceTrack) {
        guard track.sample_size <= 256*1_024, track.extradata_size <= 64*1_024, track.audio_format_sample_size <= 65_536,
              track.sample_size == 0 || track.sample != nil, track.extradata_size == 0 || track.extradata != nil,
              track.audio_format_sample_size == 0 || track.audio_format_sample != nil else { unsupported = true; return }
        let sample = track.sample.map { Data(bytes: $0, count: track.sample_size) } ?? Data()
        let extra = track.extradata.map { Data(bytes: $0, count: track.extradata_size) } ?? Data()
        switch track.media_type {
        case 1: videos.append(videoFacts(track, sample: sample, extra: extra))
        case 2:
            let format = track.audio_format_sample.map { Data(bytes: $0, count: track.audio_format_sample_size) } ?? Data()
            var scalar = track
            scalar.sample = nil; scalar.extradata = nil; scalar.audio_format_sample = nil
            pendingAudio.append((scalar, sample, extra, format))
        default: unsupported = true
        }
    }
    func facts(url: URL, container: Int32, deadline: UInt64) throws -> HLSMediaFacts {
        // Container, BSF and AVC workspaces have closed. At most one AAC decoder
        // overlaps these bounded retained headers/first audio frames.
        var audio: [HLSSourceAudioFacts] = []
        for (track, sample, extra, formatSample) in pendingAudio {
            if isCancelled { throw CancellationError() }
            guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
            var observed: VPFFSourceAACFormat?
            if track.codec == VPFF_CODEC_AAC && extra.isEmpty && !formatSample.isEmpty {
                var format = VPFFSourceAACFormat()
                let now = HLSMonotonicClock.now
                let result = formatSample.withUnsafeBytes { bytes in
                    vp_ffmpeg_inspect_adts_format(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        Int64(min(500_000, deadline > now ? (deadline-now)/1_000 : 0)), { context in
                            guard let context else { return 1 }
                            return Unmanaged<SourceInspectionState>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                        }, Unmanaged.passUnretained(self).toOpaque(), &format)
                }
                if result == 0 { observed = format }
            }
            audio.append(audioFacts(track, sample: sample, extra: extra, observed: observed, isTS: container == 1))
        }
        pendingAudio.removeAll()
        if isCancelled { throw CancellationError() }
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard !videos.isEmpty || !audio.isEmpty else {
            diagnostics?.reject(.noTracks)
            throw HLSSourceError.unsupportedMedia
        }
        return HLSMediaFacts(url: url, container: container == 1 ? .mpegTS : container == 2 ? .fragmentedMP4 : .isoBMFF,
            video: videos.first, audio: audio, hasUnsupportedTracks: unsupported || videos.count > 1)
    }
    private func videoFacts(_ track: VPFFSourceTrack, sample: Data, extra: Data) -> HLSVideoFacts {
        let codec: VideoCodec? = track.codec == VPFF_CODEC_H264 ? .h264 : track.codec == VPFF_CODEC_HEVC ? .hevc : nil
        guard let codec else { return HLSVideoFacts(codec: nil, profile: track.profile, scan: .unknown, parameterSetsValidated: false) }
        do {
            guard track.video_timing_conflict == 0 else { throw HLSSourceVideoProjection.Failure.contradictory }
            let units = try annexBUnits(sample)
            let spsUnits = units.filter { codec == .h264 ? $0[0] & 31 == 7 : ($0[0] >> 1) & 63 == 33 }
            guard let sps = spsUnits.first, spsUnits.allSatisfy({ $0 == sps }) else { throw HLSSourceError.incompleteEvidence }
            let bytes = Array(sps)
            let proof = try VideoSequenceParameterSetInspector.sourceProof(bytes, codec: codec)
            let flags = try VideoSequenceParameterSetInspector.sourceScanFlags(bytes, codec: codec)
            let format = try VideoSequenceParameterSetInspector.sourceFormat(bytes, codec: codec)
            if extra.first == 1 {
                if codec == .h264 {
                    guard extra.count >= 7, extra[1] == proof.profileIDC, UInt32(extra[2]) == proof.compatibilityFlags,
                          extra[3] == proof.levelIDC else { throw HLSSourceVideoProjection.Failure.contradictory }
                } else {
                    guard extra.count >= 23 else { throw HLSSourceError.incompleteEvidence }
                    let compatibility = extra[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let constraints = extra[6..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    guard extra[1] >> 6 == 0, extra[1] & 31 == proof.profileIDC,
                          ((extra[1] & 32) != 0) == (format.tier == .high), extra[12] == proof.levelIDC,
                          compatibility == proof.compatibilityFlags, constraints == proof.hevcConstraintIndicatorFlags,
                          extra[16] & 3 == proof.chromaFormatIDC, (extra[17] & 7) + 8 == proof.bitDepthLuma,
                          (extra[18] & 7) + 8 == proof.bitDepthChroma else { throw HLSSourceVideoProjection.Failure.contradictory }
                }
            }
            _ = try HLSSourceVideoProjection.reconcile(parameterSet: proof.width, container: HLSSourceVideoProjection.dimension(track.width), parser: HLSSourceVideoProjection.dimension(track.parser_width))
            _ = try HLSSourceVideoProjection.reconcile(parameterSet: proof.height, container: HLSSourceVideoProjection.dimension(track.height), parser: HLSSourceVideoProjection.dimension(track.parser_height))
            let primaries = try HLSSourceVideoProjection.reconcileColor(parameterSet: format.primaries, container: track.color_primaries, parser: track.parser_color_primaries)
            let transfer = try HLSSourceVideoProjection.reconcileColor(parameterSet: format.transfer, container: track.color_transfer, parser: track.parser_color_transfer)
            let matrix = try HLSSourceVideoProjection.reconcileColor(parameterSet: format.matrix, container: track.color_matrix, parser: track.parser_color_matrix)
            let observedRate = MediaRational(num: track.frame_rate_num, den: track.frame_rate_den)
            let rate = try HLSSourceVideoProjection.reconcile(parameterSet: format.frameRate, container: Optional<MediaRational>.none, parser: observedRate)
            let interlaced = track.interlaced_frames > 0 || track.container_field_order == 2
            let contradiction = (flags.progressiveOnly && interlaced) || (flags.interlacedOnly && track.container_field_order == 1) ||
                (track.container_field_order == 1 && track.interlaced_frames > 0)
            let scan: HLSScanEvidence
            if contradiction { scan = .contradictory }
            else if interlaced || flags.interlacedOnly { scan = .interlaced }
            else if flags.progressiveOnly || track.progressive_frames >= 8 { scan = .progressive }
            else { scan = .unknown }
            let profileMatches = track.profile < 0 || (track.profile & 255) == Int32(proof.profileIDC)
            let range: HLSVideoRange?
            switch transfer { case .bt709: range = .sdr; case .pq: range = .pq; case .hlg: range = .hlg; default: range = nil }
            return HLSVideoFacts(codec: codec, profile: Int32(proof.profileIDC), scan: profileMatches ? scan : .contradictory,
                parameterSetsValidated: profileMatches && !contradiction,
                configurationFingerprint: try HLSVideoConfigurationFingerprint.make(codec: codec, parameterSets: units),
                width: proof.width, height: proof.height, chromaFormat: proof.chromaFormatIDC, bitDepth: proof.bitDepthLuma, level: proof.levelIDC,
                parserProgressiveFrames: track.progressive_frames, parserInterlacedFrames: track.interlaced_frames,
                compatibilityFlags: proof.compatibilityFlags, constraintIndicatorFlags: proof.hevcConstraintIndicatorFlags,
                tier: format.tier == .main ? .main : .high, frameRate: rate,
                explicitSequenceFrameRate: codec == .h264 && flags.progressiveOnly ? format.frameRate : nil,
                videoRange: range,
                colorPrimaries: primaries, colorTransfer: transfer, colorMatrix: matrix, sampleEntry: sampleEntry(track.sample_entry))
        } catch HLSSourceVideoProjection.Failure.contradictory {
            return HLSVideoFacts(codec: codec, profile: track.profile, scan: .contradictory, parameterSetsValidated: false)
        } catch { return HLSVideoFacts(codec: codec, profile: track.profile, scan: .unknown, parameterSetsValidated: false) }
    }
    private func audioFacts(_ track: VPFFSourceTrack, sample: Data, extra: Data, observed: VPFFSourceAACFormat?, isTS: Bool) -> HLSSourceAudioFacts {
        let codecs: [VPFFCodec: AudioCodec] = [VPFF_CODEC_AAC: .aac, VPFF_CODEC_AC3: .ac3, VPFF_CODEC_EAC3: .eac3,
            VPFF_CODEC_MP1: .mp1, VPFF_CODEC_MP2: .mp2, VPFF_CODEC_MP3: .mp3]
        let codec = codecs[track.codec]
        var rate = track.sample_rate, channels = track.channels, mask = track.channel_mask, profile = track.profile
        var configuration = extra, validated = false
        var service: HLSSourceAudioService = track.audio_stream_count == 1 && track.is_dependent == 0 && track.is_commentary == 0 && track.has_unclassified_role == 0 ? .independentMain : .unknown
        if track.is_dependent != 0 { service = .dependent }
        if track.is_commentary != 0 { service = .associated }
        do {
            switch codec {
            case .aac:
                let ascData: Data
                if extra.isEmpty {
                    guard let observed else { throw HLSSourceError.incompleteEvidence }
                    rate = observed.sample_rate; channels = observed.channels; mask = observed.channel_mask; profile = observed.profile
                    guard profile == 1, sample.count >= 7, sample[0] == 255, sample[1] & 0xF6 == 0xF0, sample[2] >> 6 == 1 else { throw HLSSourceError.incompleteEvidence }
                    let frequency = (sample[2] >> 2) & 15, layout = ((sample[2] & 1) << 2) | (sample[3] >> 6)
                    ascData = Data([16 | (frequency >> 1), (frequency << 7) | (layout << 3)])
                } else { ascData = extra }
                let asc = try AudioSpecificConfig.parse(ascData)
                guard (rate == 0 || rate == asc.outputSampleRate), (channels == 0 || channels == asc.outputChannelCount) else { throw HLSSourceError.incompleteEvidence }
                rate = asc.outputSampleRate; channels = asc.outputChannelCount
                switch asc.kind { case .aacLC: profile = 1; case .heAACv1: profile = 4; case .heAACv2: profile = 28 }
                let masks: [Int32: UInt64] = [1: 4, 2: 3, 3: 7, 4: 0x107, 5: 0x37, 6: 0x3F, 8: 0x63F]
                let expected = masks[channels] ?? 0
                guard expected != 0, mask == 0 || mask == expected else { throw HLSSourceError.incompleteEvidence }
                mask = expected
                let descriptor = AudioTrackDescriptor(streamIndex: track.stream_index, codec: .aac, timeBase: MediaRational(num: 1, den: rate)!,
                    sampleRate: rate, channelLayout: AudioChannelLayout(channelCount: channels, nativeMask: mask), extradata: extra)
                let facts = try AACAudioCodecProfile(source: descriptor).inspect(FramedCompressedAudioFrame(payload: sample,
                    presentationTimeStamp: .zero, parserSampleCount: nil, parserSampleRate: nil, parserChannelLayout: nil, containerMarkedCorrupt: false), source: descriptor)
                configuration = facts.decoderExtradata; validated = true
            case .ac3:
                let header = try AC3FrameInspector.inspect(sample)
                validated = (rate == 0 || rate == header.sampleRate) && (channels == 0 || channels == header.channelCount)
                rate = header.sampleRate; channels = header.channelCount; profile = Int32(header.bsid)
                let expected = dolbyMask(header.acmod, header.lfeon)
                validated = validated && layoutMatches(mask, expected)
                if mask == 0 { mask = expected }
                if header.acmod == 0 { service = .unknown }
                if header.bsmod != 0 { service = .associated }
            case .eac3:
                let header = try EAC3FrameInspector.inspect(sample)
                validated = (rate == 0 || rate == header.sampleRate) && (channels == 0 || channels == header.channelCount)
                rate = header.sampleRate; channels = header.channelCount; profile = Int32(header.bsid)
                let expected = dolbyMask(header.acmod, header.lfeon)
                validated = validated && layoutMatches(mask, expected)
                if mask == 0 { mask = expected }
                if header.streamType == .dependent { service = .dependent }
                else if header.streamType != .independent || header.substreamID != 0 || header.acmod == 0 || header.hasJOC != false { service = .unknown }
                if let bsmod = header.bsmod, bsmod != 0 { service = .associated }
            default: break
            }
        } catch { validated = false }
        let priming: HLSSourceAudioPriming
        if track.has_explicit_priming != 0 { priming = .explicit(leadingSamples: track.leading_samples, trailingSamples: track.trailing_samples) }
        else if isTS && track.observed_audio_packets > 0 && track.invalid_audio_timestamps == 0 { priming = .notSignaledPreserveTimestamps }
        else { priming = .unknown }
        return HLSSourceAudioFacts(codec: codec, profile: profile, sampleRate: rate, channelCount: channels, channelMask: mask,
            decoderConfiguration: configuration, priming: priming, service: service, formatValidated: validated)
    }
    private func dolbyMask(_ acmod: UInt8, _ lfe: Bool) -> UInt64 {
        let masks: [UInt64] = [3, 4, 3, 7, 0x103, 0x107, 0x603, 0x607]
        return masks[Int(acmod)] | (lfe ? 8 : 0)
    }
    private func layoutMatches(_ actual: UInt64, _ expected: UInt64) -> Bool {
        if actual == 0 || actual == expected { return true }
        // Standard Dolby surround channels may use the equivalent CoreAudio side
        // or back naming. Compare semantic positions, not a channel count alone.
        func normalized(_ mask: UInt64) -> UInt64 {
            (mask & ~UInt64(0x600)) | (mask & 0x200 != 0 ? 0x10 : 0) | (mask & 0x400 != 0 ? 0x20 : 0)
        }
        return normalized(actual) == normalized(expected)
    }
    private func sampleEntry(_ value: UInt32) -> String? {
        guard value != 0 else { return nil }
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) }
        return String(bytes: bytes, encoding: .ascii)
    }
    private func annexBUnits(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        var starts: [(Int, Int)] = [], index = 0
        while index+3 <= bytes.count {
            if bytes[index] == 0 && bytes[index+1] == 0 {
                if bytes[index+2] == 1 { starts.append((index, index+3)); index += 3; continue }
                if index+4 <= bytes.count && bytes[index+2] == 0 && bytes[index+3] == 1 { starts.append((index, index+4)); index += 4; continue }
            }
            index += 1
        }
        guard !starts.isEmpty, starts.count <= 64 else { throw HLSSourceError.incompleteEvidence }
        return try starts.enumerated().map { offset, start in
            var end = offset+1 < starts.count ? starts[offset+1].0 : bytes.count
            while end > start.1 && bytes[end-1] == 0 { end -= 1 }
            guard end > start.1 else { throw HLSSourceError.incompleteEvidence }
            return Data(bytes[start.1..<end])
        }
    }
}
