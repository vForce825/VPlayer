// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore
import VPlayerPlayback

struct PlayerChannelInfoAccessibilityPresentation: Equatable {
    let technicalText: String
    let currentProgrammeText: String?
    let nextProgrammeText: String?
    let currentProgrammeAccessibilityText: String?
    let nextProgrammeAccessibilityText: String?
    let badgeText: String?

    init(
        information: PlaybackMediaInformation?,
        current: Programme?,
        next: Programme?
    ) {
        let media = PlaybackMediaInformationPresentation(information: information)
        technicalText = media.accessibilityText
        currentProgrammeText = current.map { Self.programmeText(label: "当前节目", programme: $0) }
        nextProgrammeText = next.map { Self.programmeText(label: "下一节目", programme: $0) }
        currentProgrammeAccessibilityText = current.map {
            Self.programmeAccessibilityText(label: "当前节目", programme: $0)
        }
        nextProgrammeAccessibilityText = next.map {
            Self.programmeAccessibilityText(label: "下一节目", programme: $0)
        }
        badgeText = media.showsSmoothMotionBadge && !media.accessibilityText.contains("增强")
            ? "流畅增强"
            : nil
    }

    private static func programmeText(label: String, programme: Programme) -> String {
        "\(label)：\(programme.title)"
    }

    private static func programmeAccessibilityText(
        label: String,
        programme: Programme
    ) -> String {
        "\(programmeText(label: label, programme: programme))，时间 \(programmeTimeText(label: label, programme: programme))"
    }

    static func programmeTimeText(label: String, programme: Programme) -> String {
        label == "下一节目"
            ? timeText(programme.start)
            : timeRange(for: programme)
    }

    private static func timeRange(for programme: Programme) -> String {
        timeText(programme.start) + " – " + timeText(programme.stop)
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// A compact, passive channel summary shown over the upper-right corner of
/// live playback.  The timeline is intentionally local to this view so EPG
/// refreshes do not affect playback state or the transport controls.
struct PlayerChannelInfoOverlay: View {
    let presentation: PlayerChannelPresentation
    let mediaInformation: PlaybackMediaInformation?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let programmePresentation = ChannelProgrammePresentation.resolve(
                programmes: presentation.programmes,
                at: context.date
            )
            card(programmePresentation: programmePresentation)
        }
        .frame(width: 430, alignment: .trailing)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityIdentifier("player-channel-info")
    }

    private func card(
        programmePresentation: ChannelProgrammePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            channelHeader

            if presentation.programmes.isEmpty {
                Text("暂无节目单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                programmeDetails(for: programmePresentation)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private var channelHeader: some View {
        let accessibility = PlayerChannelInfoAccessibilityPresentation(
            information: mediaInformation,
            current: nil,
            next: nil
        )
        return HStack(alignment: .center, spacing: 14) {
            ChannelLogoView(url: presentation.logoURL)
                .frame(width: 68, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.request.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    Text(PlaybackMediaInformationPresentation(information: mediaInformation).visualText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(accessibility.technicalText)

                    if PlaybackMediaInformationPresentation(information: mediaInformation).showsSmoothMotionBadge {
                        Text("流畅增强")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.16))
                            )
                            .accessibilityLabel(accessibility.badgeText ?? "流畅增强")
                            .accessibilityHidden(accessibility.badgeText == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func programmeDetails(
        for programmePresentation: ChannelProgrammePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = programmePresentation.current {
                programmeRow(current, semanticLabel: "当前节目")
                ProgressView(value: programmePresentation.progress ?? 0)
                    .tint(.accentColor)
                    .accessibilityLabel("当前节目进度")
            } else {
                Text("暂无当前节目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let next = programmePresentation.next {
                programmeRow(next, semanticLabel: "下一节目")
            } else if programmePresentation.current == nil {
                Text("暂无后续节目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func programmeRow(
        _ programme: Programme,
        semanticLabel: String
    ) -> some View {
        let accessibility = PlayerChannelInfoAccessibilityPresentation(
            information: nil,
            current: semanticLabel == "当前节目" ? programme : nil,
            next: semanticLabel == "下一节目" ? programme : nil
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(
                PlayerChannelInfoAccessibilityPresentation.programmeTimeText(
                    label: semanticLabel,
                    programme: programme
                )
            )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(programme.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            semanticLabel == "当前节目"
                ? accessibility.currentProgrammeAccessibilityText ?? semanticLabel
                : accessibility.nextProgrammeAccessibilityText ?? semanticLabel
        )
    }

    private func timeRange(for programme: Programme) -> String {
        timeText(programme.start) + " – " + timeText(programme.stop)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
