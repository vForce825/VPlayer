#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
test -f Vendor/FFmpeg/Artifacts-iOS/FFmpeg.xcframework/Info.plist
Scripts/verify-licenses.sh
destination="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0}"
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayeriOS \
  -destination "$destination" CODE_SIGNING_ALLOWED=NO "$@"
