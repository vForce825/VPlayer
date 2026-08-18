// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit

struct ChannelLogoView: View {
    let url: URL?
    var imagePadding: CGFloat = 20
    var placeholderVerticalPadding: CGFloat = 34

    var body: some View {
        if let url {
            CachedChannelLogo(
                url: url,
                imagePadding: imagePadding,
                placeholderVerticalPadding: placeholderVerticalPadding
            )
        } else {
            ChannelLogoPlaceholder(verticalPadding: placeholderVerticalPadding)
        }
    }
}

private struct CachedChannelLogo: View {
    let url: URL
    let imagePadding: CGFloat
    let placeholderVerticalPadding: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? ChannelLogoCache.shared.memoryCachedImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(imagePadding)
            } else {
                ChannelLogoPlaceholder(verticalPadding: placeholderVerticalPadding)
            }
        }
        .task(id: url) {
            image = nil
            let loadedImage = await ChannelLogoCache.shared.image(for: url)
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
