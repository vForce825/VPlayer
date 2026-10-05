#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Exact reference eligibility precedes candidate playback. No retries or failure fallback.
set -euo pipefail
candidate="$(git rev-parse --show-toplevel)"
cd "$candidate"
head="${1:?Exact candidate SHA required}"
[[ "$head" =~ ^[0-9a-f]{40}$ && "$(git rev-parse HEAD)" == "$head" ]]
old=36f9f00044db05b707e25ea470b0da3cec62682c
root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hls-comparison.XXXXXX")"
echo "HLS_COMPARISON_DIRECTORY=$root"
# Actual Swift observations must pass the shared report predicates before the
# candidate source/player window. Candidate products are reused for that run.
VPLAYER_HLS_ACCEPTANCE_DERIVED_DATA="$root/CandidateDerivedData" \
  ./Scripts/run-persistent-hls-acceptance.sh --controls-only --duration-seconds 300 \
  --head "$head" --output "$root/native-controls.json"
# The obsolete PR branch may already be deleted. Fetch only its approved exact
# source commit when checkout's reachable objects do not include that baseline.
if ! git cat-file -e "$old^{commit}" 2>/dev/null; then
  git fetch --no-write-fetch-head origin "$old"
fi
[[ "$(git rev-parse --verify "$old^{commit}")" == "$old" ]]
# This exact old tree has a reviewed sequence-as-seconds publication clock defect.
# Verify the immutable source blobs and freeze the decision/policy BEFORE candidate
# execution. No old checkout/build/playback and no arbitrary runtime-failure fallback.
python3 Scripts/Support/persistent_hls_acceptance.py freeze-ineligible \
  Scripts/Support/hls-baseline-eligibility.json --head "$head" \
  --fixture Tests/Fixtures/HLSAcceptance/persistent-360s.ts --output "$root/ineligible-baseline.json"
chmod a-w "$root/ineligible-baseline.json"
echo "BASELINE_INELIGIBLE_SHA256=$(shasum -a 256 "$root/ineligible-baseline.json" | awk '{print $1}')"
cat "$root/ineligible-baseline.json"
VPLAYER_HLS_ACCEPTANCE_DERIVED_DATA="$root/CandidateDerivedData" \
  ./Scripts/run-persistent-hls-acceptance.sh --duration-seconds 300 --head "$head" \
  --ineligible-baseline "$root/ineligible-baseline.json" --output "$root/candidate.json"
# Valid measured-reference validation remains available in the lower-level runner;
# this known-ineligible reference never supplies thresholds or improvement claims.
cat "$root/candidate.json" "$root/candidate.json.verdict.json"
