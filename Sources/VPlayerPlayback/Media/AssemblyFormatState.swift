// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

final class AssemblyFormatState {
    private(set) var trackSet: DemuxTrackSet
    private(set) var videoParameterSets: [Data]
    private(set) var audioSystemFormat: AudioSystemFormatFingerprintComponent?

    init(
        trackSet: DemuxTrackSet,
        videoParameterSets: [Data] = [],
        audioSystemFormat: AudioSystemFormatFingerprintComponent? = nil
    ) {
        self.trackSet = trackSet
        self.videoParameterSets = videoParameterSets
        self.audioSystemFormat = audioSystemFormat
    }

    func resetVideo(for trackSet: DemuxTrackSet) {
        self.trackSet = trackSet
        videoParameterSets = []
    }

    func resetAudio(for trackSet: DemuxTrackSet) {
        self.trackSet = trackSet
        audioSystemFormat = nil
    }

    func commitVideoParameterSets(_ parameterSets: [Data]) {
        videoParameterSets = parameterSets
    }

    func commitAudioSystemFormat(_ format: AudioSystemFormatFingerprintComponent?) {
        audioSystemFormat = format
    }

    func fingerprint() throws -> MediaFormatFingerprint {
        try MediaFormatFingerprint(
            trackSet: trackSet,
            videoParameterSets: videoParameterSets,
            audioSystemFormat: audioSystemFormat
        )
    }
}
