// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

struct NativeHLSSelectionSnapshot: Sendable {
    let item: AVPlayerItemInstanceIdentity
    let physicalItem: ObjectIdentifier
    let audioSelection: ObjectIdentifier?
    let video: HLSVideoFacts?
    let audio: HLSSourceAudioFacts?
    let audioConfigurationDigest: Data?
    let observedFrameRate: Double?
    let duration: ExactMediaTime?
    private let sourceOwner: HLSOwnedSourcePlan
    private let retention: HLSApplicationLifetimeCharge
    init(item: AVPlayerItemInstanceIdentity, physicalItem: ObjectIdentifier, audioSelection: ObjectIdentifier?,
         video: HLSVideoFacts?, audio: HLSSourceAudioFacts?, audioConfigurationDigest: Data?, observedFrameRate: Double?,
         sourceOwner: HLSOwnedSourcePlan, retention: HLSApplicationLifetimeCharge, duration: ExactMediaTime? = nil) {
        self.item = item; self.physicalItem = physicalItem; self.audioSelection = audioSelection
        self.video = video; self.audio = audio; self.audioConfigurationDigest = audioConfigurationDigest
        self.observedFrameRate = observedFrameRate; self.duration = duration; self.sourceOwner = sourceOwner; self.retention = retention
    }
    var information: PlaybackMediaInformation? {
        guard let video, video.width > 0, video.height > 0, video.scan == .progressive else { return nil }
        return .init(width: video.width, height: video.height, scanMode: .progressive,
            sourceFrameRate: video.frameRate, outputFrameRate: observedFrameRate, isSmoothMotionEnhanced: false)
    }
    func permitsTransition(from prior: Self) -> Bool {
        guard item == prior.item, physicalItem == prior.physicalItem else { return false }
        // Changed same-selection compressed configuration with unchanged source
        // facts is a contradiction. Known alternate selections remain available.
        if audioSelection == prior.audioSelection, audio == prior.audio,
           audioConfigurationDigest != prior.audioConfigurationDigest { return false }
        return true
    }
}

@MainActor
protocol NativeHLSAssetInspecting: AnyObject {
    func snapshot(item: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot
}

@MainActor
final class SystemNativeHLSAssetInspector: NativeHLSAssetInspecting {
    private let driver: SystemAVPlayerDriver
    init(driver: SystemAVPlayerDriver) { self.driver = driver }

    func snapshot(item identity: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot {
        let temporary = try HLSApplicationLifetimeCharge(bytes: 2 * 1_024 * 1_024)
        let retained = try HLSApplicationLifetimeCharge(bytes: 8 * 1_024)
        let callback = try driver.reserveSDKCallbackLease(.logFetch)
        defer { withExtendedLifetime((temporary, callback)) {} }
        guard source.sourceIsCurrent, let item = driver.nativeCurrentItem(identity) else { throw HLSSourceError.staleResolution }
        // Capture ALL identities before the first asynchronous SDK load. Selecting
        // new identities after loading old formats would manufacture a mixed seal.
        let selected = item.currentMediaSelection
        let presentationSize = item.presentationSize
        let tracks = item.tracks.filter(\.isEnabled)
        guard tracks.count <= 16 else { throw HLSSourceError.capacity }
        let trackIDs = tracks.map(ObjectIdentifier.init)
        let assets = tracks.map(\.assetTrack)
        let assetIDs = assets.map { $0.map(ObjectIdentifier.init) }
        var audioGroup: AVMediaSelectionGroup?, subtitleGroup: AVMediaSelectionGroup?
        func validate() throws {
            try Task.checkCancellation()
            guard source.sourceIsCurrent, driver.nativeCurrentItem(identity) === item,
                  item.presentationSize == presentationSize else { throw HLSSourceError.staleResolution }
            let current = item.tracks.filter(\.isEnabled)
            guard current.map(ObjectIdentifier.init) == trackIDs,
                  current.map({ $0.assetTrack.map(ObjectIdentifier.init) }) == assetIDs else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            for group in [audioGroup, subtitleGroup].compactMap({ $0 }) {
                guard selected.selectedMediaOption(in: group).map(ObjectIdentifier.init) ==
                    item.currentMediaSelection.selectedMediaOption(in: group).map(ObjectIdentifier.init) else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            }
        }
        audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        try validate()
        subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        try validate()
        let selectedAudio = audioGroup.flatMap { selected.selectedMediaOption(in: $0) }
        let expectsAudio = selectedAudio != nil || source.facts.media.contains { !$0.audio.isEmpty }
        let expectsVideo = source.facts.media.contains { $0.video != nil }
        var video: HLSVideoFacts?, audio: HLSSourceAudioFacts?, audioDigest: Data?, observedRate: Double?
        for asset in assets {
            // A nil SDK track can be non-audio text. The final expected-audio
            // and expected-video guards still require real selected format proof.
            guard let asset else { continue }
            let type = try await asset.load(.mediaType)
            try validate()
            if type != .video && type != .audio { continue }
            let formats = try await asset.load(.formatDescriptions)
            try validate()
            guard formats.count == 1, let format = formats.first else { throw HLSSourceError.incompleteEvidence }
            if type == .video {
                guard video == nil else { throw HLSSourceError.unsupportedMedia }
                let actual = try Self.videoFacts(format, expected: source.facts)
                let rate = try await asset.load(.nominalFrameRate)
                try validate()
                if rate.isFinite, rate > 0 {
                    if let expected = actual.frameRate {
                        guard abs(Double(rate) - Double(expected.num) / Double(expected.den)) <= 0.02 else { throw HLSSourceError.unsupportedMedia }
                    }
                    observedRate = Double(rate)
                }
                video = actual
            } else {
                guard audio == nil else { throw HLSSourceError.unsupportedMedia }
                let actual = try Self.audioFacts(format, expected: source.facts)
                audio = actual.0; audioDigest = actual.1
            }
            // A second SDK read rejects configuration changes within this load
            // stack even when the selected track object and dimensions stay equal.
            let currentFormats = try await asset.load(.formatDescriptions)
            try validate()
            guard currentFormats.count == 1, let currentFormat = currentFormats.first,
                  CMFormatDescriptionEqual(format, otherFormatDescription: currentFormat) else { throw HLSSourceError.unsupportedMedia }
        }
        guard !expectsAudio || audio != nil, !expectsVideo || video != nil else { throw HLSSourceError.incompleteEvidence }
        try validate()
        var duration: ExactMediaTime?
        if case let .hls(graph) = source.source.topology {
            let media = graph.orderedDocuments.filter { $0.kind == .media }
            let end = Data("#EXT-X-ENDLIST".utf8)
            let endCR = Data("#EXT-X-ENDLIST\r".utf8)
            if !media.isEmpty, media.allSatisfy({ $0.rawData.split(separator: 10).contains { Data($0) == end || Data($0) == endCR } }) {
                let time = try await item.asset.load(.duration)
                try validate()
                if let value = try? ExactMediaTime(time), value.value > 0 { duration = value }
            }
        }
        return .init(item: identity, physicalItem: ObjectIdentifier(item), audioSelection: selectedAudio.map(ObjectIdentifier.init),
            video: video, audio: audio, audioConfigurationDigest: audioDigest, observedFrameRate: observedRate,
            sourceOwner: source, retention: retained, duration: duration)
    }

    private static func videoFacts(_ format: CMFormatDescription, expected: HLSCompatibilityFacts) throws -> HLSVideoFacts {
        let codec: VideoCodec
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_H264, 0x61766333: codec = .h264
        case kCMVideoCodecType_HEVC, 0x68657631: codec = .hevc
        default: throw HLSSourceError.unsupportedMedia
        }
        var count = 0, nalLength: Int32 = 0
        func parameter(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status: OSStatus
            if codec == .h264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            } else {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            }
            guard status == noErr, let pointer, size > 0, size <= HLSVideoConfigurationFingerprint.maximumBytes,
                  count > 0, count <= HLSVideoConfigurationFingerprint.maximumParameterSets else { throw HLSSourceError.incompleteEvidence }
            return Data(bytes: pointer, count: size)
        }
        let first = try parameter(0)
        var sets = [first], bytes = first.count
        let originalCount = count
        for index in 1..<originalCount {
            let next = try parameter(index)
            guard count == originalCount, next.count <= HLSVideoConfigurationFingerprint.maximumBytes - bytes else { throw HLSSourceError.byteLimit }
            bytes += next.count; sets.append(next)
        }
        let digest = try HLSVideoConfigurationFingerprint.make(codec: codec, parameterSets: sets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard let matching = expected.media.compactMap(\.video).first(where: {
            $0.codec == codec && $0.parameterSetsValidated && $0.scan == .progressive &&
                $0.configurationFingerprint == digest && $0.width == dimensions.width && $0.height == dimensions.height
        }) else { throw HLSSourceError.unsupportedMedia }
        if matching.videoRange == .pq || matching.videoRange == .hlg {
            guard AVPlayer.eligibleForHDRPlayback else { throw HLSSourceError.unsupportedMedia }
        }
        return matching
    }
    private static func audioFacts(_ format: CMFormatDescription, expected: HLSCompatibilityFacts) throws -> (HLSSourceAudioFacts, Data) {
        guard let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { throw HLSSourceError.incompleteEvidence }
        let asbd = pointer.pointee
        guard asbd.mSampleRate.isFinite, asbd.mSampleRate > 0, asbd.mSampleRate <= 192_000,
              asbd.mSampleRate.rounded() == asbd.mSampleRate, (1...8).contains(asbd.mChannelsPerFrame) else { throw HLSSourceError.unsupportedMedia }
        let codec: AudioCodec
        switch asbd.mFormatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = .aac
        case kAudioFormatAC3: codec = .ac3
        case kAudioFormatEnhancedAC3: codec = .eac3
        default: throw HLSSourceError.unsupportedMedia
        }
        let positions = try CompressedAudioChannelPositions.bitmap(in: format)
        guard positions.nonzeroBitCount == asbd.mChannelsPerFrame else { throw HLSSourceError.incompleteEvidence }
        var size = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size)
        guard size >= 0, size <= 64 * 1_024, size == 0 || cookie != nil else { throw HLSSourceError.byteLimit }
        let bytes = cookie.map { Data(bytes: $0, count: size) } ?? Data()
        let configuration = codec == .aac ? try NativeAACDecoderConfiguration.extract(bytes) : bytes
        guard let matching = expected.media.flatMap(\.audio).first(where: {
            $0.codec == codec && $0.formatValidated && $0.service == .independentMain &&
                $0.sampleRate == Int32(asbd.mSampleRate) && $0.channelCount == Int32(asbd.mChannelsPerFrame) &&
                $0.channelMask == UInt64(positions) && ($0.decoderConfiguration.isEmpty || $0.decoderConfiguration == configuration)
        }) else { throw HLSSourceError.unsupportedMedia }
        return (matching, Data(SHA256.hash(data: configuration)))
    }
}

/// A bounded public AAC cookie may be raw ASC or an ES descriptor. Ignore only
/// transport bitrate fields; retain and validate the complete decoder config.
private enum NativeAACDecoderConfiguration {
    static func extract(_ bytes: Data) throws -> Data {
        if (try? AudioSpecificConfig.parse(bytes)) != nil { return bytes }
        var offset = 0
        if bytes.count >= 12, bytes[4..<8] == Data("esds".utf8) { offset = 12 }
        func descriptor(_ tag: UInt8, end: Int) throws -> Range<Int> {
            guard offset < end, bytes[offset] == tag else { throw HLSSourceError.incompleteEvidence }
            offset += 1
            var count = 0, value = 0
            while true {
                guard offset < end, count < 4 else { throw HLSSourceError.incompleteEvidence }
                let byte = bytes[offset]; offset += 1; count += 1; value = value * 128 + Int(byte & 127)
                if byte & 128 == 0 { break }
            }
            guard value <= end - offset else { throw HLSSourceError.incompleteEvidence }
            return offset..<(offset + value)
        }
        let es = try descriptor(3, end: bytes.count)
        guard es.count >= 3, bytes[es.lowerBound + 2] == 0 else { throw HLSSourceError.incompleteEvidence }
        offset += 3
        let decoder = try descriptor(4, end: es.upperBound)
        guard decoder.count >= 13, bytes[decoder.lowerBound] == 0x40, bytes[decoder.lowerBound + 1] >> 2 == 5 else { throw HLSSourceError.incompleteEvidence }
        offset += 13
        let specific = try descriptor(5, end: decoder.upperBound)
        guard specific.count <= 64 else { throw HLSSourceError.byteLimit }
        let result = bytes.subdata(in: specific)
        _ = try AudioSpecificConfig.parse(result)
        return result
    }
}
