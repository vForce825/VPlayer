// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct PlayerNoticeBanner: View {
    let notice: PlaybackNotice

    var body: some View {
        Text(notice.message)
            .font(.headline)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("player-capability-notice")
            .allowsHitTesting(false)
            .focusable(false)
    }
}
