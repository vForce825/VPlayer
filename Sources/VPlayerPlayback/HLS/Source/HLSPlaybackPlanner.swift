// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum HLSPlaybackPlanner {
    public static func makePlan(source: ResolvedPlaybackSource, facts: HLSCompatibilityFacts,
                                capabilities: HLSOutputCapabilities) throws -> HLSPlaybackPlan {
        guard let owner = source.context.owner, facts.owner == owner, facts.resolutionGeneration == source.generation,
              source.withCurrentResolution(owner: owner, generation: source.generation, operation: { true }) == true else { throw HLSSourceError.staleResolution }
        guard facts.complete, !facts.media.isEmpty, facts.media.count <= HLSManifestGraph.maximumDocuments,
              facts.inspectedBytes > 0, facts.inspectedBytes <= HLSCompatibilityProbe.maximumBytes,
              Set(facts.media.map(\.url)).count == facts.media.count else { throw HLSSourceError.incompleteEvidence }
        if case let .hls(graph) = source.topology {
            guard graph.unsupportedFeatures.isEmpty, graph.documents.count <= HLSManifestGraph.maximumDocuments,
                  let root = graph.document(for: graph.rootURL) else { throw HLSSourceError.unsupportedMedia }
            let documents = graph.orderedDocuments
            let urls = Set(documents.filter { $0.kind == .media }.map(\.responseURL))
            guard urls == Set(facts.media.map(\.url)), documents.count == graph.documents.count else { throw HLSSourceError.incompleteEvidence }
            if facts.media.allSatisfy({ nativeMedia($0, owner: owner, capabilities: capabilities) }) &&
                declarationsMatch(graph: graph, facts: facts, capabilities: capabilities) {
                return HLSPlaybackPlan(owner: owner, resolutionGeneration: source.generation,
                    transport: source.requiresManagedTransport ? .proxy : .native, video: .source, audio: .source,
                    selectedServiceURL: nil, formatFingerprint: facts.formatFingerprint)
            }
            // The caller must explicitly select a service first. Never silently
            // collapse ABR, alternate audio, subtitles or trick-play relationships.
            guard root.kind == .media, documents.count == 1 else { throw HLSSourceError.unsupportedMedia }
        } else {
            guard facts.media.count == 1, facts.media[0].url == source.responseURL else { throw HLSSourceError.incompleteEvidence }
        }
        guard capabilities.supportsGenerated, facts.media.count == 1 else { throw HLSSourceError.unsupportedMedia }
        let media = facts.media[0]
        guard !media.hasUnsupportedTracks, media.container != .unknown, media.container != .webVTT,
              media.audio.count == 1, let audio = media.audio.first, audio.codec != nil else { throw HLSSourceError.unsupportedMedia }
        let videoDecision: HLSPlaybackPlan.Video
        if let video = media.video {
            guard let codec = video.codec, video.parameterSetsValidated, !video.requiresNativeRec601Color,
                  capabilities.videoProfiles[codec]?.contains(video.profile) == true else { throw HLSSourceError.unsupportedMedia }
            switch video.scan {
            case .progressive: videoDecision = .remux
            case .interlaced: videoDecision = .deinterlaceAndEncode
            case .unknown, .contradictory: throw HLSSourceError.unsupportedMedia
            }
        } else { videoDecision = .source }
        let audioDecision = HLSAudioProcessingPolicy.select(source: audio, capabilities: capabilities, hasVideo: media.video != nil)
        let dolby: Bool
        switch audioDecision { case .passthrough(.ac3), .passthrough(.eac3): dolby = true; default: dolby = false }
        let configuration = dolby ? capabilities.verifiedCompressedAudioConfigurations.first { !$0.requiresAACCompatibilityRendition && $0.matches(audio) } : nil
        let candidate = dolby && configuration == nil ? capabilities.compressedAudioAdmissionCandidates.first { !$0.requiresAACCompatibilityRendition && $0.matches(audio) } : nil
        return HLSPlaybackPlan(owner: owner, resolutionGeneration: source.generation, transport: .generated,
            video: videoDecision, audio: audioDecision, selectedServiceURL: source.responseURL,
            formatFingerprint: facts.formatFingerprint, compressedAudioConfiguration: configuration,
            compressedAudioAdmissionCandidate: candidate)
    }

    private static func nativeMedia(_ media: HLSMediaFacts, owner: PlaybackSourceOwner, capabilities: HLSOutputCapabilities) -> Bool {
        guard !media.hasUnsupportedTracks else { return false }
        if media.container == .webVTT { return capabilities.supportsWebVTT && media.video == nil && media.audio.isEmpty }
        guard media.container == .mpegTS || media.container == .fragmentedMP4,
              media.video != nil || !media.audio.isEmpty else { return false }
        if let video = media.video {
            guard capabilities.videoFormats.contains(where: { $0.matches(video) }),
                  video.codec != .hevc || media.container == .fragmentedMP4 else { return false }
        }
        return media.audio.allSatisfy { audio in
            guard audio.formatValidated, audio.service == .independentMain, let codec = audio.codec,
                  capabilities.nativeAudioCodecs.contains(codec), audio.sampleRate > 0, audio.channelCount > 0,
                  audio.channelMask.nonzeroBitCount == audio.channelCount else { return false }
            if codec == .ac3 || codec == .eac3 {
                return capabilities.nativeAudioAdmissionCandidates.contains { $0.matches(audio, owner: owner) }
            }
            return codec == .aac && HLSAudioProcessingPolicy.supportsSourceLC(audio)
        }
    }

    private static func declarationsMatch(graph: HLSManifestGraph, facts: HLSCompatibilityFacts, capabilities: HLSOutputCapabilities) -> Bool {
        let media = Dictionary(uniqueKeysWithValues: facts.media.map { ($0.url, $0) })
        func factual(_ url: URL) -> HLSMediaFacts? {
            guard let document = graph.document(for: url), document.kind == .media else { return nil }
            return media[document.responseURL]
        }
        for document in graph.orderedDocuments where document.kind == .master {
            for rendition in document.renditions {
                switch rendition.attributes["TYPE"] {
                case "AUDIO":
                    if let url = rendition.url {
                        guard let fact = factual(url), fact.video == nil, fact.audio.count == 1 else { return false }
                        if let channels = rendition.attributes["CHANNELS"] {
                            guard let count = Int32(channels), count == fact.audio[0].channelCount else { return false }
                        }
                    }
                case "VIDEO": guard let url = rendition.url, factual(url)?.video != nil else { return false }
                case "SUBTITLES": guard capabilities.supportsWebVTT, let url = rendition.url, factual(url)?.container == .webVTT else { return false }
                case "CLOSED-CAPTIONS":
                    guard rendition.url == nil, capabilities.supportsInBandClosedCaptions,
                          let identifier = rendition.attributes["INSTREAM-ID"] else { return false }
                    if !["CC1", "CC2", "CC3", "CC4"].contains(identifier) {
                        guard identifier.hasPrefix("SERVICE"), let number = Int(identifier.dropFirst(7)),
                              (1...63).contains(number), identifier == "SERVICE\(number)" else { return false }
                    }
                default: return false
                }
            }
            for variant in document.variants + document.iframeVariants {
                guard let base = factual(variant.url) else { return false }
                var relevant = [base]
                for type in ["AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS"] {
                    guard let group = variant.attributes[type], group != "NONE" else { continue }
                    let members = document.renditions.filter { $0.attributes["TYPE"] == type && $0.attributes["GROUP-ID"] == group }
                    guard !members.isEmpty else { return false }
                    for member in members {
                        if let url = member.url { guard let item = factual(url) else { return false }; relevant.append(item) }
                        else if type == "AUDIO" {
                            guard base.audio.count == 1 else { return false }
                            if let channels = member.attributes["CHANNELS"] {
                                guard let count = Int32(channels), count == base.audio[0].channelCount else { return false }
                            }
                        }
                    }
                }
                guard declaredAttributes(variant.attributes, media: relevant, capabilities: capabilities) else { return false }
            }
        }
        return true
    }

    private static func declaredAttributes(_ attributes: [String: String], media: [HLSMediaFacts], capabilities: HLSOutputCapabilities) -> Bool {
        let videos = media.compactMap(\.video), audio = media.flatMap(\.audio)
        if let value = attributes["CODECS"] {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let codecs = fields.compactMap(HLSDeclaredCodec.init)
            guard !fields.isEmpty, fields.count <= 32, codecs.count == fields.count,
                  videos.allSatisfy({ video in codecs.contains { $0.matches(video: video) } }),
                  audio.allSatisfy({ track in codecs.contains { $0.matches(audio: track) } }),
                  codecs.allSatisfy({ codec in videos.contains { codec.matches(video: $0) } || audio.contains { codec.matches(audio: $0) } || (codec == .webVTT && media.contains { $0.container == .webVTT }) }) else { return false }
        }
        if let value = attributes["RESOLUTION"] {
            let parts = value.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let width = Int32(parts[0]), let height = Int32(parts[1]), width > 0, height > 0,
                  !videos.isEmpty, videos.allSatisfy({ $0.width == width && $0.height == height }) else { return false }
        }
        if let value = attributes["FRAME-RATE"] {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  pieces.count == 1 || pieces[1].count <= 3, let declared = Double(value), declared.isFinite, declared > 0,
                  !videos.isEmpty else { return false }
            for video in videos {
                guard let rate = video.frameRate, Double(rate.num) / Double(rate.den) <= declared + 0.0005,
                      capabilities.videoFormats.contains(where: { $0.matches(video) && declared <= Double($0.maximumFrameRate.num) / Double($0.maximumFrameRate.den) + 0.0005 }) else { return false }
            }
        }
        if let value = attributes["VIDEO-RANGE"] {
            let ranges: [String: HLSVideoRange] = ["SDR": .sdr, "PQ": .pq, "HLG": .hlg]
            guard let range = ranges[value], !videos.isEmpty, videos.allSatisfy({ $0.videoRange == range }) else { return false }
        }
        return attributes["HDCP-LEVEL"] == nil || attributes["HDCP-LEVEL"] == "NONE"
    }
}
