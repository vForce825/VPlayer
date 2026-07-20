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
    func configure(
        format: CMAudioFormatDescription,
        codec: AudioCodec,
        generation: MediaGeneration
    ) throws
    func enqueue(_ sample: CompressedAudioSample) throws
    func flush(to generation: MediaGeneration)
    func stop()
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
    func attach(_ renderer: any AudioRenderer)
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

enum AudioOutputCategory: Sendable, Equatable {
    case hdmi
    case airPlay
    case other
    case none
}

protocol AudioRouteMonitoring: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (AudioOutputCategory) -> Void)
    func stop()
}

protocol AudioFormatSupportChecking: Sendable {
    func supports(
        format: CMAudioFormatDescription,
        route: AudioRoute,
        output: AudioOutputCategory
    ) -> Bool
}
