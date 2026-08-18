// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore
import VPlayerPlayback

private struct CappedIntrinsicWidthLayout: Layout {
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }

        let intrinsicSize = subview.sizeThatFits(.unspecified)
        let availableWidth = proposal.width.map { min($0, maximumWidth) } ?? maximumWidth
        let width = min(max(intrinsicSize.width, minimumWidth), availableWidth)
        let measuredSize = subview.sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        )
        return CGSize(width: width, height: measuredSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

private struct SlimChannelProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let progress = CGFloat(
                min(max(configuration.fractionCompleted ?? 0, 0), 1)
            )
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(Color.primary.opacity(0.68))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 5)
    }
}

struct PlayerChannelInfoAccessibilityPresentation: Equatable {
    let technicalText: String
    let currentProgrammeText: String?
    let nextProgrammeText: String?
    let currentProgrammeAccessibilityText: String?
    let nextProgrammeAccessibilityText: String?

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

    static func programmeTimeText(label _: String, programme: Programme) -> String {
        timeRange(for: programme)
    }

    private static func timeRange(for programme: Programme) -> String {
        timeText(programme.start) + " – " + timeText(programme.stop)
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour(.defaultDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(Locale(identifier: "en_GB"))
        )
    }
}

/// A compact, passive channel summary shown over the upper-right corner of
/// live playback.  The timeline is intentionally local to this view so EPG
/// refreshes do not affect playback state or the transport controls.
struct PlayerChannelInfoOverlay: View {
    let presentation: PlayerChannelPresentation
    let mediaInformation: PlaybackMediaInformation?

    private static let compactMinimumCardWidth: CGFloat = 380
    private static let programmeMinimumCardWidth: CGFloat = 480
    private static let maximumCardWidth: CGFloat = 540
    private static let programmeTimeColumnWidth: CGFloat = 148
    private static let programmeRowSpacing: CGFloat = 18
    private static let programmeContentMinimumWidth: CGFloat = 240
    private static let programmeContentMaximumWidth: CGFloat = 320

    private var minimumCardWidth: CGFloat {
        presentation.programmes.isEmpty
            ? Self.compactMinimumCardWidth
            : Self.programmeMinimumCardWidth
    }

    var body: some View {
        CappedIntrinsicWidthLayout(
            minimumWidth: minimumCardWidth,
            maximumWidth: Self.maximumCardWidth
        ) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let programmePresentation = ChannelProgrammePresentation.resolve(
                    programmes: presentation.programmes,
                    at: context.date
                )
                card(programmePresentation: programmePresentation)
            }
        }
        .allowsHitTesting(false)
        .focusable(false)
    }

    private func card(
        programmePresentation: ChannelProgrammePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            channelHeader

            if presentation.programmes.isEmpty {
                Text("暂无节目单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                programmeDetails(for: programmePresentation)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-channel-info")
    }

    private var channelHeader: some View {
        return HStack(alignment: .center, spacing: 16) {
            ChannelLogoView(
                url: presentation.logoURL,
                imagePadding: 0,
                placeholderVerticalPadding: 12
            )
                .frame(width: 76, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.request.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                technicalInformation
            }
        }
    }

    private var technicalInformation: some View {
        let media = PlaybackMediaInformationPresentation(information: mediaInformation)
        return HStack(spacing: 6) {
            if let resolution = media.visualResolutionText {
                Text(resolution)
                    .foregroundStyle(.secondary)
            }
            if media.visualResolutionText != nil, media.visualFrameRateText != nil {
                Text("·")
                    .foregroundStyle(.secondary)
            }
            if let frameRate = media.visualFrameRateText {
                if media.showsEnhancedFrameRateHighlight {
                    Text(frameRate)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.16))
                        )
                } else {
                    Text(frameRate)
                        .foregroundStyle(.secondary)
                }
            }
            if media.visualResolutionText == nil, media.visualFrameRateText == nil {
                Text(media.visualText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .allowsTightening(true)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(media.accessibilityText)
        .accessibilityIdentifier("player-channel-technical")
    }

    @ViewBuilder
    private func programmeDetails(
        for programmePresentation: ChannelProgrammePresentation
    ) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: Self.programmeRowSpacing,
            verticalSpacing: 10
        ) {
            if let current = programmePresentation.current {
                programmeRow(current, semanticLabel: "当前节目")
                GridRow {
                    Color.clear
                        .frame(width: Self.programmeTimeColumnWidth, height: 0)
                        .gridCellUnsizedAxes(.vertical)

                    ProgressView(value: programmePresentation.progress ?? 0)
                        .progressViewStyle(SlimChannelProgressViewStyle())
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("当前节目进度")
                        .accessibilityIdentifier("player-channel-progress")
                }
            } else {
                Text("暂无当前节目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
            }

            if let next = programmePresentation.next {
                programmeRow(next, semanticLabel: "下一节目")
            } else if programmePresentation.current == nil {
                Text("暂无后续节目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
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
        let isCurrent = semanticLabel == "当前节目"
        return GridRow {
            Text(
                PlayerChannelInfoAccessibilityPresentation.programmeTimeText(
                    label: semanticLabel,
                    programme: programme
                )
            )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .allowsTightening(true)
                .frame(width: Self.programmeTimeColumnWidth, alignment: .leading)

            Text(programme.title)
                .font(.caption2.weight(isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: Self.programmeContentMinimumWidth,
                    maxWidth: Self.programmeContentMaximumWidth,
                    alignment: .leading
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            semanticLabel == "当前节目"
                ? accessibility.currentProgrammeAccessibilityText ?? semanticLabel
                : accessibility.nextProgrammeAccessibilityText ?? semanticLabel
        )
    }

}
