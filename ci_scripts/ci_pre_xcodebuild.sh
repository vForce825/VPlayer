#!/bin/sh
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
set -eu

echo "Ensuring the Xcode Metal Toolchain is installed"
xcodebuild -downloadComponent MetalToolchain
xcodebuild -showComponent MetalToolchain
