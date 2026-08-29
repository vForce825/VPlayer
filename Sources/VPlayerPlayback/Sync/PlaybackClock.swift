// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public protocol PlaybackClock: AnyObject {
    var currentTime: CMTime { get }
    func pause()
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float)
}
