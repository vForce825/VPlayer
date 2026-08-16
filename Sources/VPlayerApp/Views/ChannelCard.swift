// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftUI
import VPlayerCore

/// Grid tile for one channel. The logo is the tile: it spans the full card
/// width in 16:9, with the name as a compact caption underneath and the live
/// EPG state smaller still. Every slot renders even without EPG data so all
/// tiles in a grid row keep the same height.
struct ChannelCard: View {
    let channel: Channel
    let programmes: [Programme]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let presentation = ChannelProgrammePresentation.resolve(
                programmes: programmes,
                at: context.date
            )
            VStack(alignment: .leading, spacing: 12) {
                logo

                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                epgFooter(presentation: presentation)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func epgFooter(presentation: ChannelProgrammePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.current?.title ?? "暂无当前节目")
                .font(.caption2)
                .lineLimit(1)

            ProgressView(value: presentation.progress ?? 0)
                .accessibilityLabel("当前节目进度")
                .opacity(presentation.current == nil ? 0 : 1)

            Text(nextProgrammeLine(for: presentation.next) ?? " ")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    /// A fixed 16:9 plate keeps every tile aligned regardless of how the source
    /// logo is proportioned, and gives channels without a logo the same weight.
    private var logo: some View {
        Rectangle()
            .fill(.thinMaterial)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ChannelLogoView(url: channel.logoURL)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func nextProgrammeLine(for next: Programme?) -> String? {
        guard let next else {
            return nil
        }
        return "接下来 \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)"
    }
}
