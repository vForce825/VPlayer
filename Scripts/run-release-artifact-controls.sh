#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Tiny native compiler controls only; no simulator launch or production build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vplayer-release-controls.XXXXXX")"
trap 'rm -rf "$work"' EXIT
guard="$root/Scripts/verify-release-artifacts.py"
python3 -B "$root/Scripts/Tests/test_release_artifacts.py"
cat > "$work/control.c" <<'C'
__attribute__((noinline)) int release_guard_control(int *pointer, int index) {
    return pointer[index] + index;
}
int main(int count, char **values) {
    (void)values;
    int numbers[2] = {1, 2};
    return release_guard_control(numbers, count & 1);
}
C
cat > "$work/control.swift" <<'SWIFT'
@inline(never) public func releaseGuardControl(_ value: Int) -> Int {
    if value > 0 { return value + 1 }
    return value - 1
}
SWIFT
expect_rejected() {
    local sdk="$1" artifact="$2" category="$3"
    if python3 -B "$guard" scan --sdk "$sdk" --artifact "$artifact" > "$work/rejected.json"; then
        echo 'RELEASE_ARTIFACT_CONTROL_FAILED=instrumented_artifact_accepted' >&2
        exit 1
    fi
    # A malformed control does not prove an instrumentation detector works.
    python3 - "$work/rejected.json" "$category" <<'PY'
import json, pathlib, sys
line = pathlib.Path(sys.argv[1]).read_text().strip()
assert line.startswith('RELEASE_ARTIFACT_GUARD=')
result = json.loads(line.split('=', 1)[1])
assert result['status'] == 'failed'
assert result['reason'] in sys.argv[2].split(',')
PY
}
for sdk in iphoneos iphonesimulator appletvos appletvsimulator; do
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    test "$(xcrun --sdk "$sdk" --show-sdk-version)" = '27.0'
    case "$sdk" in
        iphoneos) target='arm64-apple-ios27.0' ;;
        iphonesimulator) target='arm64-apple-ios27.0-simulator' ;;
        appletvos) target='arm64-apple-tvos27.0' ;;
        appletvsimulator) target='arm64-apple-tvos27.0-simulator' ;;
    esac
    common=(-target "$target" -isysroot "$sdk_path" -O2)
    xcrun clang "${common[@]}" -c "$work/control.c" -o "$work/$sdk-clean.o"
    python3 -B "$guard" scan --sdk "$sdk" --artifact "$work/$sdk-clean.o"
    xcrun clang "${common[@]}" -fprofile-instr-generate -fcoverage-mapping \
        -c "$work/control.c" -o "$work/$sdk-coverage.o"
    expect_rejected "$sdk" "$work/$sdk-coverage.o" 'instrumentation_section,instrumentation_symbol'
    xcrun clang "${common[@]}" -fsanitize=address -c "$work/control.c" -o "$work/$sdk-asan.o"
    expect_rejected "$sdk" "$work/$sdk-asan.o" 'instrumentation_symbol'
    xcrun clang "${common[@]}" -fsanitize=undefined -c "$work/control.c" -o "$work/$sdk-ubsan.o"
    expect_rejected "$sdk" "$work/$sdk-ubsan.o" 'instrumentation_symbol'
    xcrun clang "${common[@]}" -fsanitize-coverage=inline-8bit-counters \
        -c "$work/control.c" -o "$work/$sdk-sancov.o"
    expect_rejected "$sdk" "$work/$sdk-sancov.o" 'instrumentation_section,instrumentation_symbol'
    xcrun clang "${common[@]}" -fprofile-arcs -ftest-coverage \
        -c "$work/control.c" -o "$work/$sdk-gcov.o"
    expect_rejected "$sdk" "$work/$sdk-gcov.o" 'instrumentation_section,instrumentation_symbol'
    xcrun clang "${common[@]}" -finstrument-functions -c "$work/control.c" -o "$work/$sdk-functions.o"
    expect_rejected "$sdk" "$work/$sdk-functions.o" 'instrumentation_symbol'
    xcrun swiftc -target "$target" -sdk "$sdk_path" -O -parse-as-library -emit-object \
        -module-name ReleaseGuardControl "$work/control.swift" -o "$work/$sdk-swift-clean.o"
    python3 -B "$guard" scan --sdk "$sdk" --artifact "$work/$sdk-swift-clean.o"
    xcrun swiftc -target "$target" -sdk "$sdk_path" -O -parse-as-library -emit-object \
        -profile-generate -profile-coverage-mapping -module-name ReleaseGuardControl \
        "$work/control.swift" -o "$work/$sdk-swift-coverage.o"
    expect_rejected "$sdk" "$work/$sdk-swift-coverage.o" 'instrumentation_section,instrumentation_symbol'
    # Archive membership must be checked even when bad code would be dead-stripped.
    xcrun ar -rc "$work/$sdk-clean.a" "$work/$sdk-clean.o"
    python3 -B "$guard" scan --sdk "$sdk" --artifact "$work/$sdk-clean.a"
    xcrun ar -rc "$work/$sdk-bad.a" "$work/$sdk-clean.o" "$work/$sdk-coverage.o"
    expect_rejected "$sdk" "$work/$sdk-bad.a" 'instrumentation_section,instrumentation_symbol'
    if [[ "$sdk" == *simulator ]]; then
        xcrun clang "${common[@]}" "$work/control.c" -o "$work/$sdk-clean"
        python3 -B "$guard" scan --sdk "$sdk" --artifact "$work/$sdk-clean"
        xcrun clang "${common[@]}" -fprofile-instr-generate -fcoverage-mapping \
            "$work/control.c" -o "$work/$sdk-instrumented"
        xcrun strip -x "$work/$sdk-instrumented"
        expect_rejected "$sdk" "$work/$sdk-instrumented" 'instrumentation_section,instrumentation_symbol'
    fi
    echo "RELEASE_ARTIFACT_NATIVE_CONTROLS_PASSED=$sdk"
done
echo 'RELEASE_ARTIFACT_NATIVE_CONTROLS_SCOPE=compiler-controls-only'
