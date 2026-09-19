// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

// MARK: - 诊断错误域与稳定错误码

public enum BackendDiagnosticsDomain: Sendable, Equatable {
    case hlsResource
    case hlsWriter
    case hlsEncoder
    case hlsFormat
    case hlsChannelLayout
    case hlsAVPlayer
    case hlsOutputTeardown
    case hlsStartup
    case hlsWatchdog
    case sampleBuffer
}

public enum BackendDiagnosticErrorCode: String, Sendable, Codable, CaseIterable {
    case hlsResourceCapacityExceeded = "hls.resource.capacity-exceeded"
    case hlsResourceNotFound = "hls.resource.not-found"
    case hlsResourceGone = "hls.resource.gone"
    case hlsWriterFailed = "hls.writer.failed"
    case hlsEncoderFailed = "hls.encoder.failed"
    case hlsFormatUnsupported = "hls.format.unsupported"
    case hlsChannelLayoutUnsupported = "hls.channel-layout.unsupported"
    case hlsAVPlayerItemFailed = "hls.avplayer.item-failed"
    case hlsOutputTeardownFailed = "hls.output.teardown-failed"
    case hlsStartupTimeout = "hls.startup.timeout"
    case hlsWatchdogStalled = "hls.watchdog.stalled"
    case hlsWatchdogStarvation = "hls.watchdog.starvation"
    case hlsWatchdogBacklog = "hls.watchdog.backlog"
    case hlsGeneric = "hls.generic"
}

// MARK: - 脱敏与隐私（遵守 PRIVACY.md）

public enum BackendDiagnosticsSanitizer: Sendable {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?|wss?|ftp|file)://(?:/[^\s]*|[^\s/$.?#].[^\s]*)"#,
        options: [.caseInsensitive]
    )

    private static let devicePattern = try! NSRegularExpression(
        pattern: #"(?:Apple\s*TV[^\s,)]*|Living\s*Room[^\s,)]*|Bedroom[^\s,)]*|AirPlay[^\s,)]*|HomePod[^\s,)]*)(?:\s*\([^)]*\))?"#,
        options: [.caseInsensitive]
    )

    private static let queryTokenPattern = try! NSRegularExpression(
        pattern: #"[?&](?:token|auth|key|secret|password)=[^\s&]+"#,
        options: [.caseInsensitive]
    )

    /// 严格过滤 URL、Token 与设备名，替换为规范脱敏占位符。
    public static func sanitize(errorMessage: String) -> String {
        var result = errorMessage

        // 1. 过滤具体 query tokens
        let tokenRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = queryTokenPattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: tokenRange,
            withTemplate: "?<redacted-token>"
        )

        // 2. 过滤 URLs
        let urlRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = urlPattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: urlRange,
            withTemplate: "<redacted-url>"
        )

        // 3. 过滤设备名与设备标识符
        let deviceRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = devicePattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: deviceRange,
            withTemplate: "<redacted-device>"
        )

        return result
    }

    /// 严格白名单诊断码转换：绝不回显用户 URL、Query Token 或真实设备名。
    public static func whitelistedDiagnosticCode(
        fromRawError rawError: String,
        domain: BackendDiagnosticsDomain
    ) -> String {
        // 先检查是否已有完全匹配的已知白名单码
        if let exact = BackendDiagnosticErrorCode(rawValue: rawError) {
            return exact.rawValue
        }

        switch domain {
        case .hlsResource:
            if rawError.contains("capacity") { return BackendDiagnosticErrorCode.hlsResourceCapacityExceeded.rawValue }
            if rawError.contains("notFound") || rawError.contains("404") { return BackendDiagnosticErrorCode.hlsResourceNotFound.rawValue }
            if rawError.contains("gone") || rawError.contains("410") { return BackendDiagnosticErrorCode.hlsResourceGone.rawValue }
            return "hls.resource.error"

        case .hlsWriter:
            return BackendDiagnosticErrorCode.hlsWriterFailed.rawValue

        case .hlsEncoder:
            return BackendDiagnosticErrorCode.hlsEncoderFailed.rawValue

        case .hlsFormat:
            return BackendDiagnosticErrorCode.hlsFormatUnsupported.rawValue

        case .hlsChannelLayout:
            return BackendDiagnosticErrorCode.hlsChannelLayoutUnsupported.rawValue

        case .hlsAVPlayer:
            return BackendDiagnosticErrorCode.hlsAVPlayerItemFailed.rawValue

        case .hlsOutputTeardown:
            return BackendDiagnosticErrorCode.hlsOutputTeardownFailed.rawValue

        case .hlsStartup:
            return BackendDiagnosticErrorCode.hlsStartupTimeout.rawValue

        case .hlsWatchdog:
            if rawError.contains("stall") { return BackendDiagnosticErrorCode.hlsWatchdogStalled.rawValue }
            if rawError.contains("starvation") { return BackendDiagnosticErrorCode.hlsWatchdogStarvation.rawValue }
            return BackendDiagnosticErrorCode.hlsWatchdogBacklog.rawValue

        case .sampleBuffer:
            return "sampleBuffer.error"
        }
    }
}

// MARK: - 分型 Backend 指标

/// AirPlay HLS 后端真实指标。不伪造 SampleBuffer 计数器。
public struct HLSBackendMetrics: Sendable, Codable, Equatable {
    public let accessUnitCount: UInt64
    public let decodedVideoCount: UInt64
    public let yadifDispatchCount: UInt64
    public let encodedSegmentCount: UInt64
    public let publishedSegmentCount: UInt64

    public let encoderCodec: String
    public let encoderProfile: String
    public let videoDimensions: String
    public let bitDepth: Int
    public let colorTransfer: String
    public let isHardwareAccelerated: Bool
    public let pendingFrameCount: Int

    public let writerStatus: String
    public let segmentDurationSeconds: Double
    public let playlistWindowSegmentCount: Int
    public let storeBytes: Int
    public let discontinuityCount: UInt64

    public let httpRequestCount: UInt64
    public let rangeRequestCount: UInt64
    public let httpCancelCount: UInt64
    public let httpExpiredCount: UInt64
    public let httpRejectedCount: UInt64
    public let httpErrorCount: UInt64

    public let avPlayerCurrentTimeSeconds: Double?
    public let avPlayerTimeControlStatus: String
    public let avPlayerReasonForWaiting: String?
    public let accessLogStallCount: UInt64
    public let avPlayerDroppedFrameCount: UInt64

    public let selectedAudioRendition: String?
    public let audioChannelCount: Int
    public let audioSelectionMethod: String

    public init(
        accessUnitCount: UInt64,
        decodedVideoCount: UInt64,
        yadifDispatchCount: UInt64,
        encodedSegmentCount: UInt64,
        publishedSegmentCount: UInt64,
        encoderCodec: String,
        encoderProfile: String,
        videoDimensions: String,
        bitDepth: Int,
        colorTransfer: String,
        isHardwareAccelerated: Bool,
        pendingFrameCount: Int,
        writerStatus: String,
        segmentDurationSeconds: Double,
        playlistWindowSegmentCount: Int,
        storeBytes: Int,
        discontinuityCount: UInt64,
        httpRequestCount: UInt64,
        rangeRequestCount: UInt64,
        httpCancelCount: UInt64,
        httpExpiredCount: UInt64,
        httpRejectedCount: UInt64,
        httpErrorCount: UInt64,
        avPlayerCurrentTimeSeconds: Double?,
        avPlayerTimeControlStatus: String,
        avPlayerReasonForWaiting: String?,
        accessLogStallCount: UInt64,
        avPlayerDroppedFrameCount: UInt64,
        selectedAudioRendition: String?,
        audioChannelCount: Int,
        audioSelectionMethod: String
    ) {
        self.accessUnitCount = accessUnitCount
        self.decodedVideoCount = decodedVideoCount
        self.yadifDispatchCount = yadifDispatchCount
        self.encodedSegmentCount = encodedSegmentCount
        self.publishedSegmentCount = publishedSegmentCount
        self.encoderCodec = encoderCodec
        self.encoderProfile = encoderProfile
        self.videoDimensions = videoDimensions
        self.bitDepth = bitDepth
        self.colorTransfer = colorTransfer
        self.isHardwareAccelerated = isHardwareAccelerated
        self.pendingFrameCount = pendingFrameCount
        self.writerStatus = writerStatus
        self.segmentDurationSeconds = segmentDurationSeconds
        self.playlistWindowSegmentCount = playlistWindowSegmentCount
        self.storeBytes = storeBytes
        self.discontinuityCount = discontinuityCount
        self.httpRequestCount = httpRequestCount
        self.rangeRequestCount = rangeRequestCount
        self.httpCancelCount = httpCancelCount
        self.httpExpiredCount = httpExpiredCount
        self.httpRejectedCount = httpRejectedCount
        self.httpErrorCount = httpErrorCount
        self.avPlayerCurrentTimeSeconds = avPlayerCurrentTimeSeconds
        self.avPlayerTimeControlStatus = avPlayerTimeControlStatus
        self.avPlayerReasonForWaiting = avPlayerReasonForWaiting
        self.accessLogStallCount = accessLogStallCount
        self.avPlayerDroppedFrameCount = avPlayerDroppedFrameCount
        self.selectedAudioRendition = selectedAudioRendition
        self.audioChannelCount = audioChannelCount
        self.audioSelectionMethod = audioSelectionMethod
    }
}

/// SampleBuffer 本地渲染后端指标。
public struct SampleBufferBackendMetrics: Sendable, Codable, Equatable {
    public let scanType: String
    public let activeRoute: String
    public let decoderCallbacksPerSecond: Double
    public let yadifKernelDispatchCount: UInt64
    public let droppedVideoFrames: UInt64
    public let videoRendererTotalFrameCount: UInt64
    public let videoRendererDroppedFrameCount: UInt64
    public let audioRecoveryCount: UInt64

    public init(
        scanType: String,
        activeRoute: String,
        decoderCallbacksPerSecond: Double,
        yadifKernelDispatchCount: UInt64,
        droppedVideoFrames: UInt64,
        videoRendererTotalFrameCount: UInt64,
        videoRendererDroppedFrameCount: UInt64,
        audioRecoveryCount: UInt64
    ) {
        self.scanType = scanType
        self.activeRoute = activeRoute
        self.decoderCallbacksPerSecond = decoderCallbacksPerSecond
        self.yadifKernelDispatchCount = yadifKernelDispatchCount
        self.droppedVideoFrames = droppedVideoFrames
        self.videoRendererTotalFrameCount = videoRendererTotalFrameCount
        self.videoRendererDroppedFrameCount = videoRendererDroppedFrameCount
        self.audioRecoveryCount = audioRecoveryCount
    }
}

/// 依设计 12：分型诊断指标聚合体。
/// 公共字段统一；各 backend 独占对应分型 payload，不交叉伪造。
public struct BackendPlaybackMetrics: Sendable, Codable, Equatable {
    public let state: String
    public let backendKind: String
    public let trackMode: String
    public let sessionGeneration: UInt64
    public let backendGeneration: UInt64
    public let routeCategory: String
    public let isAirPlay: Bool
    public let mediaTimeSeconds: Double?
    public let physFootprintBytes: UInt64
    public let osProcAvailableMemoryBytes: UInt64

    public let sampleBufferMetrics: SampleBufferBackendMetrics?
    public let hlsMetrics: HLSBackendMetrics?

    public init(
        state: String,
        backendKind: String,
        trackMode: String,
        sessionGeneration: UInt64,
        backendGeneration: UInt64,
        routeCategory: String,
        isAirPlay: Bool,
        mediaTimeSeconds: Double?,
        physFootprintBytes: UInt64,
        osProcAvailableMemoryBytes: UInt64,
        sampleBufferMetrics: SampleBufferBackendMetrics?,
        hlsMetrics: HLSBackendMetrics?
    ) {
        self.state = state
        self.backendKind = backendKind
        self.trackMode = trackMode
        self.sessionGeneration = sessionGeneration
        self.backendGeneration = backendGeneration
        self.routeCategory = routeCategory
        self.isAirPlay = isAirPlay
        self.mediaTimeSeconds = mediaTimeSeconds
        self.physFootprintBytes = physFootprintBytes
        self.osProcAvailableMemoryBytes = osProcAvailableMemoryBytes
        self.sampleBufferMetrics = sampleBufferMetrics
        self.hlsMetrics = hlsMetrics
    }
}
