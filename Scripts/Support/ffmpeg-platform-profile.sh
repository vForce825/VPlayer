#!/bin/bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

# Trusted, closed profiles shared by build/audit/promotion. No filesystem access,
# path inference, or arbitrary SDK/architecture overrides are allowed here.
ffmpeg_select_platform() {
  case "${1:-}" in
    tvos)
      ffmpeg_platform=tvos
      ffmpeg_required_symbols=system-symbol-allowlist.txt
      ffmpeg_display_name=tvOS
      ffmpeg_artifact_directory=Artifacts
      ffmpeg_work_suffix=''
      ffmpeg_device_sdk=appletvos
      ffmpeg_simulator_sdk=appletvsimulator
      ffmpeg_simulator_architectures='arm64,x86_64'
      ffmpeg_device_platform_id=3
      ffmpeg_simulator_platform_id=8
      ;;
    ios)
      ffmpeg_platform=ios
      ffmpeg_required_symbols=system-symbol-allowlist-ios.txt
      ffmpeg_display_name=iOS
      ffmpeg_artifact_directory=Artifacts-iOS
      ffmpeg_work_suffix=/ios
      ffmpeg_device_sdk=iphoneos
      ffmpeg_simulator_sdk=iphonesimulator
      ffmpeg_simulator_architectures=arm64
      ffmpeg_device_platform_id=2
      ffmpeg_simulator_platform_id=7
      ;;
    *) echo 'FFmpeg platform must be tvos or ios' >&2; return 64 ;;
  esac
}

ffmpeg_archive_needs_thinning() {
  [[ "$ffmpeg_platform" == tvos && "${1:-}" == simulator ]]
}
