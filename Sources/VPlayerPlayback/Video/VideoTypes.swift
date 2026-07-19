// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

public enum CodedFieldOrder: UInt8, Sendable, Equatable {
    case unknown, progressive, tt, bb, tb, bt
}

public enum PictureStructure: UInt8, Sendable, Equatable {
    case unknown, frame, topField, bottomField
}

public struct VideoParserMetadata: Sendable, Equatable {
    public let fieldOrder: CodedFieldOrder?
    public let pictureStructure: PictureStructure?
    public let isInterlaced: Bool?
    public let repeatFirstField: Bool
    public let topFieldFirst: Bool?
    public let sourcePTS90k: UInt64?

    public init(
        fieldOrder: CodedFieldOrder?,
        pictureStructure: PictureStructure?,
        isInterlaced: Bool?,
        repeatFirstField: Bool,
        topFieldFirst: Bool?,
        sourcePTS90k: UInt64?
    ) {
        self.fieldOrder = fieldOrder
        self.pictureStructure = pictureStructure
        self.isInterlaced = isInterlaced
        self.repeatFirstField = repeatFirstField
        self.topFieldFirst = topFieldFirst
        self.sourcePTS90k = sourcePTS90k
    }
}

public struct CompressedVideoAccessUnit: @unchecked Sendable {
    public let id: UInt64
    public let sampleBuffer: CMSampleBuffer
    public let generation: MediaGeneration
    public let isRandomAccess: Bool
    public let parserMetadata: VideoParserMetadata

    public init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        generation: MediaGeneration,
        isRandomAccess: Bool,
        parserMetadata: VideoParserMetadata
    ) {
        self.id = id
        self.sampleBuffer = sampleBuffer
        self.generation = generation
        self.isRandomAccess = isRandomAccess
        self.parserMetadata = parserMetadata
    }
}

enum VideoAssemblerEvent: @unchecked Sendable {
    case format(CMVideoFormatDescription, MediaFormatFingerprint)
    case accessUnit(CompressedVideoAccessUnit)
}

final class AssemblyFormatState {
    private(set) var trackSet: DemuxTrackSet
    private(set) var videoParameterSets: [Data]
    private(set) var audioCookie: Data?

    init(
        trackSet: DemuxTrackSet,
        videoParameterSets: [Data] = [],
        audioCookie: Data? = nil
    ) {
        self.trackSet = trackSet
        self.videoParameterSets = videoParameterSets
        self.audioCookie = audioCookie
    }

    func resetVideo(for trackSet: DemuxTrackSet) {
        self.trackSet = trackSet
        videoParameterSets = []
    }

    func resetAudio(for trackSet: DemuxTrackSet) {
        self.trackSet = trackSet
        audioCookie = nil
    }

    func commitVideoParameterSets(_ parameterSets: [Data]) {
        videoParameterSets = parameterSets
    }

    func commitAudioCookie(_ cookie: Data?) {
        audioCookie = cookie
    }

    func fingerprint() throws -> MediaFormatFingerprint {
        try MediaFormatFingerprint(
            trackSet: trackSet,
            videoParameterSets: videoParameterSets,
            audioCookie: audioCookie
        )
    }
}
