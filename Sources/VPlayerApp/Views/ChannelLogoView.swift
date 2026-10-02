// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit

struct ChannelLogoView: View {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    let url: URL?
    var imagePadding: CGFloat = 20
    var placeholderVerticalPadding: CGFloat = 34

    var body: some View {
        if let url {
            CachedChannelLogo(
                url: url,
                prefersReducedResourceUsage: prefersReducedResourceUsage,
                imagePadding: imagePadding,
                placeholderVerticalPadding: placeholderVerticalPadding
            )
        } else {
            ChannelLogoPlaceholder(verticalPadding: placeholderVerticalPadding)
        }
    }
}

struct CachedChannelLogo: View {
    let url: URL
    let prefersReducedResourceUsage: Bool
    let imagePadding: CGFloat
    let placeholderVerticalPadding: CGFloat
    var memoryCachedImage: @MainActor @Sendable (URL) -> UIImage? = {
        ChannelLogoCache.shared.memoryCachedImage(for: $0)
    }
    var loadImage: @MainActor @Sendable (URL) async -> UIImage? = {
        await ChannelLogoCache.shared.image(for: $0)
    }
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? memoryCachedImage(url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(imagePadding)
            } else {
                ChannelLogoPlaceholder(verticalPadding: placeholderVerticalPadding)
            }
        }
        // URL changes and normal visibility lifecycle admit optional work. A
        // resource-preference update redraws cached artwork but never restarts
        // this task, including when the preference returns to unrestricted.
        .task(id: url) {
            image = memoryCachedImage(url)
            guard image == nil, !prefersReducedResourceUsage else { return }
            let loadedImage = await loadImage(url)
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }
}

private struct ChannelLogoPlaceholder: View {
    let verticalPadding: CGFloat

    var body: some View {
        Image(systemName: "tv")
            .resizable()
            .scaledToFit()
            .padding(.vertical, verticalPadding)
            .foregroundStyle(.secondary)
    }
}
