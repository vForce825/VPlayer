// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

/// Grid tile for one channel: identity on the first row, then the live EPG
/// state. Every slot renders even without EPG data so all tiles in a grid row
/// keep the same height.
struct ChannelCard: View {
    let channel: Channel
    let programmes: [Programme]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let current = currentProgramme(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    logo
                    Text(channel.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(current?.title ?? "暂无当前节目")
                    .font(.subheadline)
                    .foregroundStyle(current == nil ? .secondary : .primary)
                    .lineLimit(1)

                ProgressView(
                    value: current.map { progress(for: $0, at: context.date) } ?? 0
                )
                .accessibilityLabel("当前节目进度")
                .opacity(current == nil ? 0 : 1)

                Text(nextProgrammeLine(at: context.date) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        .frame(width: 84, height: 56)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var logoPlaceholder: some View {
        Image(systemName: "tv")
            .resizable()
            .scaledToFit()
            .padding(16)
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
