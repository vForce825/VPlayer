// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation

public enum AudioRoute: Sendable, Equatable {
    case systemCompressed
    case ffmpegPCM
}

public enum AudioFallbackReason: String, Codable, Sendable, Equatable {
    case repeatedCompressedRendererFailure
    case systemDecoderUnavailable
    case compressedRendererNoProgressAfterRebuild
}

public enum AudioDiagnosticOutputCategory: String, Codable, Sendable, Equatable {
    case hdmi
    case airPlay
    case bluetooth
    case other
    case none
}

public struct AudioFormatFingerprintDiagnostic: Codable, Sendable, Equatable {
    public let value: String

    public init?(value: String) {
        let bytes = value.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let validated = Self(value: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid bounded audio format fingerprint"
            )
        }
        self = validated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct AudioRendererFailureDiagnostic: Codable, Sendable, Equatable {
    public let domain: String
    public let code: Int

    public init?(domain: String, code: Int) {
        let bytes = domain.utf8
        guard !bytes.isEmpty,
              bytes.count <= 96,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 46
                      || byte == 95
              }) else { return nil }
        self.domain = domain
        self.code = code
    }

    init?(sanitizedRepresentation: String) {
        guard let separator = sanitizedRepresentation.lastIndex(of: ":"),
              separator != sanitizedRepresentation.startIndex,
              let code = Int(sanitizedRepresentation[sanitizedRepresentation.index(after: separator)...]) else {
            return nil
        }
        self.init(domain: String(sanitizedRepresentation[..<separator]), code: code)
    }

    public var representation: String { "\(domain):\(code)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let domain = try container.decode(String.self, forKey: .domain)
        let code = try container.decode(Int.self, forKey: .code)
        guard let validated = Self(domain: domain, code: code) else {
            throw DecodingError.dataCorruptedError(
                forKey: .domain,
                in: container,
                debugDescription: "invalid bounded audio renderer failure domain"
            )
        }
        self = validated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case code
    }
}

public enum PlaybackAnchorLeadTimePolicy {
    public static let minimumLeadTime = CMTime(value: 100, timescale: 1_000) // 100ms
    public static let defaultSafetyMargin = CMTime(value: 100, timescale: 1_000) // 100ms

    public static func compute(
        outputLatency: TimeInterval,
        ioBufferDuration: TimeInterval,
        safetyMargin: CMTime = defaultSafetyMargin
    ) -> CMTime {
        let totalLatencySeconds = max(0, outputLatency) + max(0, ioBufferDuration)
        let latencyCMTime = CMTime(seconds: totalLatencySeconds, preferredTimescale: 1_000)
        let combined = CMTimeAdd(latencyCMTime, safetyMargin)
        guard combined.isNumeric else { return minimumLeadTime }
        return CMTimeCompare(combined, minimumLeadTime) > 0 ? combined : minimumLeadTime
    }
}

public struct AudioRenderDiagnostics: Sendable, Equatable {
    public static let zero = AudioRenderDiagnostics()

    public internal(set) var automaticFlushTriggerCount: UInt64 = 0
    public internal(set) var outputConfigurationTriggerCount: UInt64 = 0
    public internal(set) var routeChangeTriggerCount: UInt64 = 0
    public internal(set) var recoveryTransactionCount: UInt64 = 0
    public internal(set) var suppressedCorrelatedTriggerCount: UInt64 = 0
    public internal(set) var compressedRendererRetryCount: UInt64 = 0
    public internal(set) var pcmFallbackCount: UInt64 = 0
    public internal(set) var lastFallbackReason: AudioFallbackReason?
    public internal(set) var startupWaitingSeconds: Double = 0
    public internal(set) var rendererReady: Bool = false
    public internal(set) var rendererSufficient: Bool = false
    public internal(set) var activeCodec: AudioCodec?
    public internal(set) var formatFingerprint: AudioFormatFingerprintDiagnostic?
    public internal(set) var outputCategory: AudioDiagnosticOutputCategory = .other
    public internal(set) var routeRevision: UInt64 = 0
    public internal(set) var mediaGeneration: MediaGeneration?
    public internal(set) var lastCompressedRendererFailure: AudioRendererFailureDiagnostic?
    public internal(set) var acceptedCompressedMediaDurationSeconds: Double = 0
    public internal(set) var pendingSampleCount: Int = 0
    public internal(set) var rendererRequestArmed: Bool = false
    public internal(set) var rendererBackpressureCount: UInt64 = 0
    public internal(set) var rendererRequestRearmCount: UInt64 = 0
    public internal(set) var automaticFlushNoProgressCount: UInt64 = 0
    public internal(set) var lastAcceptedPTSSeconds: Double?
    public internal(set) var lastRendererProgressAgeSeconds: Double?

    public init(
        automaticFlushTriggerCount: UInt64 = 0,
        outputConfigurationTriggerCount: UInt64 = 0,
        routeChangeTriggerCount: UInt64 = 0,
        recoveryTransactionCount: UInt64 = 0,
        suppressedCorrelatedTriggerCount: UInt64 = 0,
        compressedRendererRetryCount: UInt64 = 0,
        pcmFallbackCount: UInt64 = 0,
        lastFallbackReason: AudioFallbackReason? = nil,
        startupWaitingSeconds: Double = 0,
        rendererReady: Bool = false,
        rendererSufficient: Bool = false,
        activeCodec: AudioCodec? = nil,
        formatFingerprint: AudioFormatFingerprintDiagnostic? = nil,
        outputCategory: AudioDiagnosticOutputCategory = .other,
        routeRevision: UInt64 = 0,
        mediaGeneration: MediaGeneration? = nil,
        lastCompressedRendererFailure: AudioRendererFailureDiagnostic? = nil,
        acceptedCompressedMediaDurationSeconds: Double = 0,
        pendingSampleCount: Int = 0,
        rendererRequestArmed: Bool = false,
        rendererBackpressureCount: UInt64 = 0,
        rendererRequestRearmCount: UInt64 = 0,
        automaticFlushNoProgressCount: UInt64 = 0,
        lastAcceptedPTSSeconds: Double? = nil,
        lastRendererProgressAgeSeconds: Double? = nil
    ) {
        self.automaticFlushTriggerCount = automaticFlushTriggerCount
        self.outputConfigurationTriggerCount = outputConfigurationTriggerCount
        self.routeChangeTriggerCount = routeChangeTriggerCount
        self.recoveryTransactionCount = recoveryTransactionCount
        self.suppressedCorrelatedTriggerCount = suppressedCorrelatedTriggerCount
        self.compressedRendererRetryCount = compressedRendererRetryCount
        self.pcmFallbackCount = pcmFallbackCount
        self.lastFallbackReason = lastFallbackReason
        self.startupWaitingSeconds = startupWaitingSeconds
        self.rendererReady = rendererReady
        self.rendererSufficient = rendererSufficient
        self.activeCodec = activeCodec
        self.formatFingerprint = formatFingerprint
        self.outputCategory = outputCategory
        self.routeRevision = routeRevision
        self.mediaGeneration = mediaGeneration
        self.lastCompressedRendererFailure = lastCompressedRendererFailure
        self.acceptedCompressedMediaDurationSeconds = acceptedCompressedMediaDurationSeconds
        self.pendingSampleCount = max(0, pendingSampleCount)
        self.rendererRequestArmed = rendererRequestArmed
        self.rendererBackpressureCount = rendererBackpressureCount
        self.rendererRequestRearmCount = rendererRequestRearmCount
        self.automaticFlushNoProgressCount = automaticFlushNoProgressCount
        self.lastAcceptedPTSSeconds = lastAcceptedPTSSeconds?.isFinite == true
            ? lastAcceptedPTSSeconds
            : nil
        self.lastRendererProgressAgeSeconds = lastRendererProgressAgeSeconds.flatMap { age in
            age.isFinite && age >= 0 ? age : nil
        }
    }
}

enum AudioClockMode: Sendable, Equatable {
    case standalone
    case externallyManaged
}

public enum AudioRenderReadinessChange: Sendable, Equatable {
    case invalidated
    case available
}

public protocol AudioRenderPipelineProtocol: AnyObject {
    var isReadyForPlayback: Bool { get }
    var route: AudioRoute { get }
    var currentRouteSnapshot: AudioOutputRouteSnapshot? { get }
    var anchorLeadTime: CMTime { get }
    // Diagnostics: how many times the renderer has been flushed and refilled from
    // the replay buffer. Each recovery is expensive, so a high rate shows up as
    // reduced ingest throughput rather than as an error.
    var recoveryCount: UInt64 { get }
    var diagnostics: AudioRenderDiagnostics { get }
    func configure(
        _ configuration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration
    ) throws
    func enqueue(_ sample: CompressedAudioSample) throws
    func activateContinuityIsland(
        _ islandID: AudioContinuityIslandID,
        generation: MediaGeneration
    )
    func updateRecoveryFloor(_ floor: CMTime?)
    func prepareAnchor(
        at commonPTS: CMTime,
        in islandID: AudioContinuityIslandID
    ) throws
    func setSharedTimelineOpened(_ opened: Bool)
    func flush(to generation: MediaGeneration)
    func stop()
    func stopAwaitingRendererRemoval() async
}

public extension AudioRenderPipelineProtocol {
    func stopAwaitingRendererRemoval() async {
        stop()
    }

    var recoveryCount: UInt64 { 0 }
    var diagnostics: AudioRenderDiagnostics { .zero }
    var currentRouteSnapshot: AudioOutputRouteSnapshot? { nil }
    var anchorLeadTime: CMTime {
        if let snapshot = currentRouteSnapshot {
            return PlaybackAnchorLeadTimePolicy.compute(
                outputLatency: snapshot.outputLatency,
                ioBufferDuration: snapshot.ioBufferDuration
            )
        }
        return PlaybackAnchorLeadTimePolicy.minimumLeadTime
    }
    func setSharedTimelineOpened(_: Bool) {}
}

struct AudioRendererIdentity: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }
}

enum AudioRendererMediaKind: Sendable, Equatable {
    case compressed
    case linearPCM
}

enum AudioRendererEvent: Sendable, Equatable {
    case failed(String)
    case automaticFlush(CMTime?)
    case outputConfigurationChanged
}

enum AudioRendererEnqueueResult: Sendable, Equatable {
    case accepted
    case backpressured
}

protocol AudioRenderer: AnyObject, Sendable {
    var identity: AudioRendererIdentity { get }
    var mediaKind: AudioRendererMediaKind { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer) throws -> AudioRendererEnqueueResult
    func flush()
    // A demand opportunity only. The pipeline must correlate a post-reset
    // acceptance and backpressure edge before treating this as queue consumption.
    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
    func startObserving(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void)
    func stopObserving()
}

protocol AudioRendererFactory: Sendable {
    func makeRenderer(mediaKind: AudioRendererMediaKind) throws -> any AudioRenderer
}

protocol AudioRenderSynchronizing: AnyObject, Sendable {
    func currentTime() -> CMTime
    var rate: Float { get }
    func attach(_ renderer: any AudioRenderer) throws
    func remove(
        _ renderer: any AudioRenderer,
        at time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void
    )
    func setRate(_ rate: Float, time: CMTime)
}

protocol PCMAudioDecoding: AnyObject, Sendable {
    func push(_ sample: CompressedAudioSample) throws -> [CMSampleBuffer]
    func flush()
    func destroy()
}

protocol PCMAudioDecoderFactory: Sendable {
    func makeDecoder(
        codec: AudioCodec,
        extradata: Data
    ) throws -> any PCMAudioDecoding
}

public enum AudioOutputRouteCategory: Sendable, Equatable {
    case hdmi
    case airPlay
    case bluetooth
    case other
    case none
}

public typealias AudioOutputCategory = AudioOutputRouteCategory

public enum AudioRouteChangeReason: Sendable, Equatable {
    case initial
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRoute
    case routeConfigurationChange
    case unknown
}

public struct AudioOutputRouteSnapshot: Sendable, Equatable {
    public let category: AudioOutputRouteCategory
    public let reason: AudioRouteChangeReason
    public let revision: UInt64
    public let outputLatency: TimeInterval
    public let ioBufferDuration: TimeInterval

    public init(
        category: AudioOutputRouteCategory,
        reason: AudioRouteChangeReason,
        revision: UInt64,
        outputLatency: TimeInterval = 0,
        ioBufferDuration: TimeInterval = 0
    ) {
        self.category = category
        self.reason = reason
        self.revision = revision
        self.outputLatency = outputLatency
        self.ioBufferDuration = ioBufferDuration
    }

    public static func == (lhs: AudioOutputRouteSnapshot, rhs: AudioOutputRouteSnapshot) -> Bool {
        lhs.category == rhs.category
            && lhs.reason == rhs.reason
            && lhs.revision == rhs.revision
    }
}

public protocol AudioRouteMonitoring: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void)
    func stop()
}
