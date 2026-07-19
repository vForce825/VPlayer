// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

public struct FFmpegComponentSnapshot: Sendable, Equatable {
    public let protocols: [String]
    public let demuxers: [String]
    public let parsers: [String]
    public let decoders: [String]
    public let configuration: String
    public let version: UInt32
}

public enum FFmpegInventory {
    public static func snapshot() -> FFmpegComponentSnapshot {
        func names(_ kind: VPFFComponentKind) -> [String] {
            (0..<vp_ffmpeg_component_count(kind)).compactMap { index in
                vp_ffmpeg_component_name(kind, index).map(String.init(cString:))
            }.sorted()
        }

        let configuration = vp_ffmpeg_configuration().map(String.init(cString:)) ?? ""
        return FFmpegComponentSnapshot(
            protocols: names(VPFF_COMPONENT_PROTOCOL),
            demuxers: names(VPFF_COMPONENT_DEMUXER),
            parsers: names(VPFF_COMPONENT_PARSER),
            decoders: names(VPFF_COMPONENT_DECODER),
            configuration: configuration,
            version: vp_ffmpeg_version()
        )
    }
}
