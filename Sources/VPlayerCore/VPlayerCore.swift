// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

public enum VPlayerCore {
    #if os(iOS)
    public static let deploymentTarget = "iOS 27.0"
    #else
    public static let deploymentTarget = "tvOS 27.0"
    #endif
}
