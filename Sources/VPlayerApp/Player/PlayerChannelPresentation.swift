// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore
import VPlayerPlayback

/// The channel-side context that accompanies a playback request in the UI.
///
/// The playback engine continues to receive only `request`; logo and EPG data
/// are presentation concerns and stay out of the engine contract.
struct PlayerChannelPresentation: Equatable {
    let request: PlaybackRequest
    let logoURL: URL?
    let programmes: [Programme]
}
