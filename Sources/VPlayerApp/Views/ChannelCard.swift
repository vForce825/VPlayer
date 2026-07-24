// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

/// Grid tile for one channel. Logo and name carry the tile; the live EPG state
/// stays a small secondary footer beneath them. Every slot renders even without
/// EPG data so all tiles in a grid row keep the same height.
struct ChannelCard: View {
    let channel: Channel
    let programmes: [Programme]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let current = currentProgramme(at: context.date)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    logo
                    Text(channel.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }

                epgFooter(current: current, at: context.date)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func epgFooter(current: Programme?, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(current?.title ?? "暂无当前节目")
                .font(.caption)
                .lineLimit(1)

            ProgressView(value: current.map { progress(for: $0, at: date) } ?? 0)
                .accessibilityLabel("当前节目进度")
                .opacity(current == nil ? 0 : 1)

            Text(nextProgrammeLine(at: date) ?? " ")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var logo: some View {
        Group {
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        logoPlaceholder
                    }
                }
            } else {
                logoPlaceholder
            }
        }
        .frame(width: 132, height: 88)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var logoPlaceholder: some View {
        Image(systemName: "tv")
            .resizable()
            .scaledToFit()
            .padding(22)
            .foregroundStyle(.secondary)
    }

    private func currentProgramme(at date: Date) -> Programme? {
        programmes.first { $0.start <= date && date < $0.stop }
    }

    private func nextProgrammeLine(at date: Date) -> String? {
        guard let next = programmes.first(where: { $0.start >= date }) else {
            return nil
        }
        return "接下来 \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)"
    }

    private func progress(for programme: Programme, at date: Date) -> Double {
        let duration = programme.stop.timeIntervalSince(programme.start)
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(programme.start) / duration, 0), 1)
    }
}
