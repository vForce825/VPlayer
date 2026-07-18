// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct ChannelRow: View {
    let channel: Channel
    let programmes: [Programme]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 24) {
                logo

                VStack(alignment: .leading, spacing: 10) {
                    Text(channel.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if let current = currentProgramme(at: context.date) {
                        Text(current.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        ProgressView(value: progress(for: current, at: context.date))
                            .accessibilityLabel("当前节目进度")
                    } else {
                        Text("暂无当前节目")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let next = nextProgramme(at: context.date) {
                        Text("接下来 \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let logoURL = channel.logoURL {
            AsyncImage(url: logoURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                }
            }
            .frame(width: 96, height: 64)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: "tv")
                .resizable()
                .scaledToFit()
                .padding(18)
                .frame(width: 96, height: 64)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func currentProgramme(at date: Date) -> Programme? {
        programmes.first { $0.start <= date && date < $0.stop }
    }

    private func nextProgramme(at date: Date) -> Programme? {
        programmes.first { $0.start >= date }
    }

    private func progress(for programme: Programme, at date: Date) -> Double {
        let duration = programme.stop.timeIntervalSince(programme.start)
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(programme.start) / duration, 0), 1)
    }
}
