// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct IOSChannelRow: View {
    let channel: Channel
    let programmes: [Programme]
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
            let programme = ChannelProgrammePresentation.resolve(programmes: programmes, at: tick.date)
            HStack(spacing: 14) {
                ChannelLogoView(url: channel.logoURL, imagePadding: 5, placeholderVerticalPadding: 12)
                    .frame(width: 72, height: 48)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(channel.displayName).font(.headline)
                    Text(programme.current?.title ?? "暂无当前节目")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let progress = programme.progress { ProgressView(value: progress) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.circle").foregroundStyle(.tint)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
    }
}
