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

    public init(
        streamIndex: Int32,
        codec: VideoCodec,
        timeBase: MediaRational,
        width: Int32,
        height: Int32,
        videoDelay: Int32,
        extradata: Data,
        frameRate: MediaRational? = nil,
        fieldOrder: CodedFieldOrder = .unknown
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
    }
}

public struct AudioTrackDescriptor: Sendable, Hashable {
    public let streamIndex: Int32
    public let codec: AudioCodec
    public let timeBase: MediaRational
    public let sampleRate: Int32
    public let channelLayout: AudioChannelLayout
    public let extradata: Data

    public init(
        streamIndex: Int32,
        codec: AudioCodec,
        timeBase: MediaRational,
        sampleRate: Int32,
        channelLayout: AudioChannelLayout,
        extradata: Data
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.timeBase = timeBase
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.extradata = extradata
    }
}

public struct DemuxTrackSet: Sendable, Hashable {
    public let selectedProgramID: Int32?
    public let video: VideoTrackDescriptor?
    public let audio: AudioTrackDescriptor?

    public init(
        selectedProgramID: Int32?,
        video: VideoTrackDescriptor?,
        audio: AudioTrackDescriptor?
    ) {
        self.selectedProgramID = selectedProgramID
        self.video = video
        self.audio = audio
    }
}
