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
}

public enum AudioDiagnosticOutputCategory: String, Codable, Sendable, Equatable {
    case hdmi
    case airPlay
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

public struct AudioRenderDiagnostics: Sendable, Equatable {
    public let automaticFlushTriggerCount: UInt64
    public let outputConfigurationTriggerCount: UInt64
    public let routeChangeTriggerCount: UInt64
    public let recoveryTransactionCount: UInt64
    public let suppressedCorrelatedTriggerCount: UInt64
    public let compressedRendererRetryCount: UInt64
    public let pcmFallbackCount: UInt64
    public let lastFallbackReason: AudioFallbackReason?
    public let startupWaitingSeconds: Double
    public let rendererReady: Bool
    public let rendererSufficient: Bool
    public let activeCodec: AudioCodec?
    public let formatFingerprint: AudioFormatFingerprintDiagnostic?
    public let outputCategory: AudioDiagnosticOutputCategory
    public let routeRevision: UInt64
    public let mediaGeneration: MediaGeneration?
    public let lastCompressedRendererFailure: AudioRendererFailureDiagnostic?
    public let acceptedCompressedMediaDurationSeconds: Double

    public init(
        automaticFlushTriggerCount: UInt64,
        outputConfigurationTriggerCount: UInt64,
        routeChangeTriggerCount: UInt64,
        recoveryTransactionCount: UInt64,
        suppressedCorrelatedTriggerCount: UInt64,
        compressedRendererRetryCount: UInt64,
        pcmFallbackCount: UInt64,
        lastFallbackReason: AudioFallbackReason?,
        startupWaitingSeconds: Double,
        rendererReady: Bool,
        rendererSufficient: Bool,
        activeCodec: AudioCodec? = nil,
        formatFingerprint: AudioFormatFingerprintDiagnostic? = nil,
        outputCategory: AudioDiagnosticOutputCategory = .other,
        routeRevision: UInt64 = 0,
        mediaGeneration: MediaGeneration? = nil,
        lastCompressedRendererFailure: AudioRendererFailureDiagnostic? = nil,
        acceptedCompressedMediaDurationSeconds: Double = 0
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
    }

    public static let zero = AudioRenderDiagnostics(
        automaticFlushTriggerCount: 0,
        outputConfigurationTriggerCount: 0,
        routeChangeTriggerCount: 0,
        recoveryTransactionCount: 0,
        suppressedCorrelatedTriggerCount: 0,
        compressedRendererRetryCount: 0,
        pcmFallbackCount: 0,
        lastFallbackReason: nil,
        startupWaitingSeconds: 0,
        rendererReady: false,
        rendererSufficient: false
    )
}

enum AudioClockMode: Sendable, Equatable {
    case standalone
    case externallyManaged
}

enum AudioRenderReadinessChange: Sendable, Equatable {
    case invalidated
    case available
}

public protocol AudioRenderPipelineProtocol: AnyObject {
    var isReadyForPlayback: Bool { get }
    var route: AudioRoute { get }
    // Diagnostics: how many times the renderer has been flushed and refilled from
    // the replay buffer. Each recovery is expensive, so a high rate shows up as
    // reduced ingest throughput rather than as an error.
    var recoveryCount: UInt64 { get }
    var diagnostics: AudioRenderDiagnostics { get }
    func configure(
        format: CMAudioFormatDescription,
        codec: AudioCodec,
        generation: MediaGeneration,
        fingerprint: MediaFormatFingerprint
    ) throws
    func enqueue(_ sample: CompressedAudioSample) throws
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

protocol AudioRenderer: AnyObject, Sendable {
    var identity: AudioRendererIdentity { get }
    var mediaKind: AudioRendererMediaKind { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer) throws
    func flush()
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
        format: CMAudioFormatDescription
    ) throws -> any PCMAudioDecoding
}

enum AudioOutputRouteCategory: Sendable, Equatable {
    case hdmi
    case airPlay
    case other
    case none
}

typealias AudioOutputCategory = AudioOutputRouteCategory

enum AudioRouteChangeReason: Sendable, Equatable {
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

struct AudioOutputRouteSnapshot: Sendable, Equatable {
    let category: AudioOutputRouteCategory
    let reason: AudioRouteChangeReason
    let revision: UInt64
}

protocol AudioRouteMonitoring: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void)
    func stop()
}

protocol AudioFormatSupportChecking: Sendable {
    func supports(
        format: CMAudioFormatDescription,
        route: AudioRoute,
        output: AudioOutputCategory
    ) -> Bool
}
