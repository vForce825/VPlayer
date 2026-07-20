#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

usage() {
    echo "usage: $0 DEVICE_UDID {appleTemporal|metalYADIF2x} CHANNEL POSITIVE_SECONDS [M3U_URL]" >&2
}

if (( $# < 4 || $# > 5 )); then
    usage
    exit 64
fi

device_udid="$1"
algorithm="$2"
channel="$3"
duration="$4"
m3u_url="${5:-https://example.invalid/playlist.m3u}"

case "$algorithm" in
    appleTemporal|metalYADIF2x) ;;
    *)
        echo "algorithm must be appleTemporal or metalYADIF2x" >&2
        exit 64
        ;;
esac

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    echo "duration must be a positive integer number of seconds" >&2
    exit 64
fi

if [[ ! "$m3u_url" =~ ^https?:// ]]; then
    echo "M3U source must use HTTP or HTTPS" >&2
    exit 64
fi

device_details="$(xcrun devicectl device info details --device "$device_udid" 2>&1)" || {
    echo "device UDID is not available to CoreDevice" >&2
    exit 69
}
if ! rg -q 'productType: AppleTV14,1' <<<"$device_details"; then
    echo "device must resolve to AppleTV14,1 (Apple TV 4K 3rd generation)" >&2
    exit 69
fi
destination_udid="$(
    sed -nE 's/^[[:space:]]*• udid: ([A-Fa-f0-9-]+)$/\1/p' \
        <<<"$device_details" | sed -n '1p'
)"
if [[ -z "$destination_udid" ]]; then
    echo "device does not expose an xcodebuild destination UDID" >&2
    exit 69
fi

development_team="${VPLAYER_DEVELOPMENT_TEAM:-}"
if [[ -z "$development_team" ]]; then
    signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    development_team="$(
        sed -nE 's/.*"Apple Development:.*\(([A-Z0-9]{10})\)".*/\1/p' \
            <<<"$signing_identities" | sed -n '1p'
    )"
fi
if [[ ! "$development_team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "a valid Apple Development team is required for device signing" >&2
    exit 69
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
artifact_root="${VPLAYER_ACCEPTANCE_ARTIFACT_ROOT:-$repository_root/.superpowers/acceptance}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-${algorithm}-$$"
run_directory="$artifact_root/$run_id"
derived_data="$run_directory/DerivedData"
result_bundle="$run_directory/acceptance.xcresult"
acceptance_xcconfig="$run_directory/acceptance.xcconfig"
umask 077
mkdir -p "$run_directory"

encode_build_setting() {
    printf '%s' "$1" | base64 | tr -d '\n'
}
{
    printf 'VPLAYER_ACCEPTANCE_M3U_URL_B64 = %s\n' "$(encode_build_setting "$m3u_url")"
    printf 'VPLAYER_ACCEPTANCE_CHANNEL_B64 = %s\n' "$(encode_build_setting "$channel")"
    printf 'VPLAYER_ACCEPTANCE_SECONDS_B64 = %s\n' "$(encode_build_setting "$duration")"
    printf 'VPLAYER_ACCEPTANCE_ALGORITHM_B64 = %s\n' "$(encode_build_setting "$algorithm")"
} >"$acceptance_xcconfig"

interrupted=0
handle_interrupt() {
    interrupted=1
    echo "acceptance interrupted; partial artifacts remain at: $run_directory" >&2
}
trap handle_interrupt INT TERM HUP

echo "running device acceptance on verified AppleTV14,1; artifacts: $run_directory"
set +e
VPLAYER_ACCEPTANCE_M3U_URL="$m3u_url" \
VPLAYER_ACCEPTANCE_CHANNEL="$channel" \
VPLAYER_ACCEPTANCE_SECONDS="$duration" \
VPLAYER_ACCEPTANCE_ALGORITHM="$algorithm" \
xcodebuild test \
    -project "$repository_root/VPlayer.xcodeproj" \
    -scheme VPlayer \
    -configuration Debug \
    -xcconfig "$acceptance_xcconfig" \
    -destination "platform=tvOS,id=$destination_udid" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -parallel-testing-enabled NO \
    -allowProvisioningUpdates \
    -only-testing:VPlayerUITests/LongPlaybackAcceptanceTests/testLongRunningRealDevicePlayback \
    DEVELOPMENT_TEAM="$development_team"
status=$?
set -e

if (( interrupted != 0 )); then
    exit 130
fi
if (( status != 0 )); then
    echo "acceptance failed; artifacts retained at: $run_directory" >&2
    exit "$status"
fi

echo "acceptance succeeded; result bundle: $result_bundle"
