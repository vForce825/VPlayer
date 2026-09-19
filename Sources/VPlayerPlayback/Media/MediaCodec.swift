// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum VideoCodec: UInt8, Sendable, Hashable {
    case h264 = 1
    case hevc = 2
}

public enum AudioCodec: UInt8, Codable, Sendable, Hashable {
    case aac = 1
    case ac3 = 2
    case eac3 = 3
    case mp2 = 4
    case mp1 = 5
    case mp3 = 6
}

public enum MediaCodec: Sendable, Hashable {
    case video(VideoCodec)
    case audio(AudioCodec)
}

public enum DemuxTrackRole: UInt8, Sendable, Hashable {
    case main = 1
    case alternate = 2
    case commentary = 3
}

/// role 元数据必须区分真正缺失与显式但项目无法解释的 token；后者不能由
/// disposition fallback 洗成另一种服务语义。
public enum DemuxTrackRoleEvidence: Sendable, Hashable {
    case absent
    case resolved(DemuxTrackRole)
    case unclassifiable
}

public enum DemuxTrackService: UInt8, Sendable, Hashable {
    case independentMain = 1
    case associated = 2
    case dvs = 3
    case dependent = 4
    case joc = 5
}

/// 保留容器服务证据三态；未知token、相互冲突及未支持服务都属于不可分类。
public enum DemuxTrackServiceEvidence: Sendable, Hashable {
    case absent
    case resolved(DemuxTrackService)
    case unclassifiable
}

public struct DemuxTrackDisposition: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let `default` = Self(rawValue: 1 << 0)
    public static let forced = Self(rawValue: 1 << 1)
    public static let hearingImpaired = Self(rawValue: 1 << 2)
    public static let visualImpaired = Self(rawValue: 1 << 3)
    public static let commentary = Self(rawValue: 1 << 4)
    public static let dependent = Self(rawValue: 1 << 5)
}

public struct DemuxTrackMetadata: Sendable, Hashable {
    public let role: DemuxTrackRole?
    public let roleEvidence: DemuxTrackRoleEvidence
    public let language: String?
    public let service: DemuxTrackService?
    public let serviceEvidence: DemuxTrackServiceEvidence
    public let dispositions: DemuxTrackDisposition

    public init(
        role: DemuxTrackRole? = nil,
        roleEvidence: DemuxTrackRoleEvidence? = nil,
        language: String? = nil,
        service: DemuxTrackService? = nil,
        serviceEvidence: DemuxTrackServiceEvidence? = nil,
        dispositions: DemuxTrackDisposition = []
    ) {
        self.role = role
        self.roleEvidence = roleEvidence ?? role.map(DemuxTrackRoleEvidence.resolved) ?? .absent
        self.language = language
        let resolvedEvidence: DemuxTrackServiceEvidence
        if let serviceEvidence, let service {
            resolvedEvidence = serviceEvidence == .resolved(service)
                ? serviceEvidence
                : .unclassifiable
        } else {
            resolvedEvidence = serviceEvidence
                ?? service.map(DemuxTrackServiceEvidence.resolved)
                ?? .absent
        }
        self.serviceEvidence = resolvedEvidence
        if case let .resolved(resolved) = resolvedEvidence {
            self.service = resolved
        } else {
            self.service = nil
        }
        self.dispositions = dispositions
    }
}

public enum DemuxColorRange: UInt8, Sendable, Hashable {
    case limited = 1
    case full = 2
}

public enum DemuxColorPrimaries: UInt16, Sendable, Hashable {
    case bt709 = 1
    case bt2020 = 9
}

public enum DemuxColorTransfer: UInt16, Sendable, Hashable {
    case bt709 = 1
    case bt2020 = 14
    case bt2020_12 = 15
    case pq = 16
    case hlg = 18
}

public enum DemuxColorMatrix: UInt16, Sendable, Hashable {
    case bt709 = 1
    case bt2020Nonconstant = 9
}

public enum DemuxChromaLocation: UInt8, Sendable, Hashable {
    case left = 1
    case center = 2
    case topLeft = 3
}

public struct DemuxHDRRational: Sendable, Hashable {
    public let num: Int32
    public let den: Int32

    public init?(num: Int32, den: Int32) {
        guard num >= 0, den > 0 else { return nil }
        if num == 0 {
            self.num = 0
            self.den = 1
            return
        }
        let divisor = demuxRationalGCD(UInt64(num), UInt64(den))
        self.num = num / Int32(divisor)
        self.den = den / Int32(divisor)
    }

    fileprivate func isAtMostOne() -> Bool { num <= den }

    fileprivate func isLessThanOrEqual(to other: Self) -> Bool {
        Int64(num) * Int64(other.den) <= Int64(other.num) * Int64(den)
    }

    fileprivate func formsValidChromaticityPair(with other: Self) -> Bool {
        guard isAtMostOne(), other.isAtMostOne() else { return false }
        let (scaledX, xOverflow) = Int64(num).multipliedReportingOverflow(by: Int64(other.den))
        let (scaledY, yOverflow) = Int64(other.num).multipliedReportingOverflow(by: Int64(den))
        let (scaledUnit, unitOverflow) = Int64(den).multipliedReportingOverflow(by: Int64(other.den))
        guard !xOverflow, !yOverflow, !unitOverflow else { return false }
        let (sum, sumOverflow) = scaledX.addingReportingOverflow(scaledY)
        return !sumOverflow && sum <= scaledUnit
    }
}

public struct DemuxMasteringDisplayMetadata: Sendable, Hashable {
    public let redX: DemuxHDRRational
    public let redY: DemuxHDRRational
    public let greenX: DemuxHDRRational
    public let greenY: DemuxHDRRational
    public let blueX: DemuxHDRRational
    public let blueY: DemuxHDRRational
    public let whitePointX: DemuxHDRRational
    public let whitePointY: DemuxHDRRational
    public let minimumLuminance: DemuxHDRRational
    public let maximumLuminance: DemuxHDRRational

    public init?(
        redX: DemuxHDRRational,
        redY: DemuxHDRRational,
        greenX: DemuxHDRRational,
        greenY: DemuxHDRRational,
        blueX: DemuxHDRRational,
        blueY: DemuxHDRRational,
        whitePointX: DemuxHDRRational,
        whitePointY: DemuxHDRRational,
        minimumLuminance: DemuxHDRRational,
        maximumLuminance: DemuxHDRRational
    ) {
        guard redX.formsValidChromaticityPair(with: redY),
              greenX.formsValidChromaticityPair(with: greenY),
              blueX.formsValidChromaticityPair(with: blueY),
              whitePointX.formsValidChromaticityPair(with: whitePointY),
              maximumLuminance.num > 0,
              minimumLuminance.isLessThanOrEqual(to: maximumLuminance) else { return nil }
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.whitePointX = whitePointX
        self.whitePointY = whitePointY
        self.minimumLuminance = minimumLuminance
        self.maximumLuminance = maximumLuminance
    }

    public var displayPrimariesX: [DemuxHDRRational] { [redX, greenX, blueX] }
    public var displayPrimariesY: [DemuxHDRRational] { [redY, greenY, blueY] }
}

public struct DemuxContentLightLevelMetadata: Sendable, Hashable {
    public let maximumContentLightLevel: UInt16
    public let maximumFrameAverageLightLevel: UInt16

    public init?(maximumContentLightLevel: UInt16, maximumFrameAverageLightLevel: UInt16) {
        guard maximumFrameAverageLightLevel <= maximumContentLightLevel else { return nil }
        self.maximumContentLightLevel = maximumContentLightLevel
        self.maximumFrameAverageLightLevel = maximumFrameAverageLightLevel
    }
}

private func demuxRationalGCD(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 { (first, second) = (second, first % second) }
    return first == 0 ? 1 : first
}

public struct DemuxVideoMetadata: Sendable, Hashable {
    public let sampleAspectRatio: MediaRational?
    public let range: DemuxColorRange?
    public let primaries: DemuxColorPrimaries?
    public let transfer: DemuxColorTransfer?
    public let matrix: DemuxColorMatrix?
    public let chromaLocation: DemuxChromaLocation?
    public let masteringDisplay: DemuxMasteringDisplayMetadata?
    public let contentLightLevel: DemuxContentLightLevelMetadata?

    public init(
        sampleAspectRatio: MediaRational? = nil,
        range: DemuxColorRange? = nil,
        primaries: DemuxColorPrimaries? = nil,
        transfer: DemuxColorTransfer? = nil,
        matrix: DemuxColorMatrix? = nil,
        chromaLocation: DemuxChromaLocation? = nil,
        masteringDisplay: DemuxMasteringDisplayMetadata? = nil,
        contentLightLevel: DemuxContentLightLevelMetadata? = nil
    ) {
        self.sampleAspectRatio = sampleAspectRatio
        self.range = range
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.chromaLocation = chromaLocation
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
    }
}

public struct AudioChannelLayout: Sendable, Hashable {
    public let channelCount: Int32
    public let nativeMask: UInt64?

    public init(channelCount: Int32, nativeMask: UInt64?) {
        self.channelCount = channelCount
        self.nativeMask = nativeMask
    }
}

public struct VideoTrackDescriptor: Sendable, Hashable {
    public let streamIndex: Int32
    public let codec: VideoCodec
    public let timeBase: MediaRational
    public let frameRate: MediaRational?
    public let width: Int32
    public let height: Int32
    public let videoDelay: Int32
    public let fieldOrder: CodedFieldOrder
    public let extradata: Data
    public let metadata: DemuxTrackMetadata
    public let videoMetadata: DemuxVideoMetadata

    public init(
        streamIndex: Int32,
        codec: VideoCodec,
        timeBase: MediaRational,
        width: Int32,
        height: Int32,
        videoDelay: Int32,
        extradata: Data,
        frameRate: MediaRational? = nil,
        fieldOrder: CodedFieldOrder = .unknown,
        metadata: DemuxTrackMetadata = DemuxTrackMetadata(),
        videoMetadata: DemuxVideoMetadata = DemuxVideoMetadata()
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.timeBase = timeBase
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.videoDelay = videoDelay
        self.fieldOrder = fieldOrder
        self.extradata = extradata
        self.metadata = metadata
        self.videoMetadata = videoMetadata
    }
}

public struct AudioTrackDescriptor: Sendable, Hashable {
    public let streamIndex: Int32
    public let codec: AudioCodec
    public let timeBase: MediaRational
    public let sampleRate: Int32
    public let channelLayout: AudioChannelLayout
    public let extradata: Data
    public let metadata: DemuxTrackMetadata

    public init(
        streamIndex: Int32,
        codec: AudioCodec,
        timeBase: MediaRational,
        sampleRate: Int32,
        channelLayout: AudioChannelLayout,
        extradata: Data,
        metadata: DemuxTrackMetadata = DemuxTrackMetadata()
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.timeBase = timeBase
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.extradata = extradata
        self.metadata = metadata
    }
}

public struct DemuxTrackSet: Sendable, Hashable {
    public enum AudioPrimaryScope: Sendable, Hashable {
        case avProgram(index: Int32, id: Int32)
        case formatStreamTableWithoutProgram
    }

    public enum AudioPrimaryBasis: Sendable, Hashable {
        case explicitMain
        case soleAudio
        case uniqueDefault
    }

    /// 来自 C 选轨前真实容器表的定长快照；没有该回执时不得推测主服务。
    public struct AudioPrimaryEvidence: Sendable, Hashable {
        public let scope: AudioPrimaryScope
        public let selectedStreamIndex: Int32
        public let audioStreamCount: UInt32
        public let defaultAudioStreamCount: UInt32
        public let explicitMainStreamCount: UInt32
        public let unclassifiableRoleStreamCount: UInt32
        public let primaryBasis: AudioPrimaryBasis?
    }

    public let selectedProgramID: Int32?
    public let video: VideoTrackDescriptor?
    public let audio: AudioTrackDescriptor?
    public let audioPrimaryEvidence: AudioPrimaryEvidence?

    public init(
        selectedProgramID: Int32?,
        video: VideoTrackDescriptor?,
        audio: AudioTrackDescriptor?,
        audioPrimaryEvidence: AudioPrimaryEvidence? = nil
    ) {
        self.selectedProgramID = selectedProgramID
        self.video = video
        self.audio = audio
        self.audioPrimaryEvidence = audioPrimaryEvidence
    }
}
