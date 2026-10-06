#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

# 普通环境与 tvOS step1 计费模拟各冷启三次；所有操作只针对已验证的模拟器 UDID。
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-release-startup.XXXXXX")"
derived_data="${VPLAYER_STARTUP_DERIVED_DATA:-$evidence/DerivedData}"
configuration="Release"
simulator_udid=""
simulator_data_path=""
prefix=""
bundle_id=""
launched=0
fail() { printf '失败：%s\n证据目录：%s\n' "$1" "$evidence" >&2; exit 1; }
collect_process_logs() {
    [[ -n "$prefix" && -n "$simulator_data_path" ]] || return 0
    # launch 的绝对日志路径属于模拟器命名空间，主机需要从 dataPath 复制出来。
    for stream in stdout stderr; do
        if [[ -f "$simulator_data_path$prefix.$stream.log" ]]; then
            cp "$simulator_data_path$prefix.$stream.log" "$prefix.$stream.log"
        fi
    done
}
print_failed_process_logs() {
    [[ -n "$prefix" ]] || return 0
    local stream
    # 只输出本次 launch 的日志，逐文件限 8KiB；不扫描其他进程或历史启动。
    for stream in launch stdout stderr; do
        printf '\n失败启动日志（最多 8192 字节）：%s.%s.log\n' "$prefix" "$stream" >&2
        if [[ -f "$prefix.$stream.log" ]]; then
            head -c 8192 "$prefix.$stream.log" >&2 || true
            printf '\n' >&2
        else
            printf '日志尚不可用\n' >&2
        fi
    done
}
cleanup() {
    local status=$?
    if [[ "$status" != 0 ]]; then
        # 在终止精确 App 进程前保存故障证据，避免 CI 只留下临时目录路径。
        collect_process_logs || true
        print_failed_process_logs || true
    fi
    if [[ "$launched" == 1 ]]; then
        xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
    fi
    collect_process_logs || true
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '证据目录：%s\n构建日志：%s/build.log\n' "$evidence" "$evidence"
xcrun simctl list devices booted -j > "$evidence/simulators.json"
simulator_selection="$(python3 - "$evidence/simulators.json" <<'PY'
import json, os, sys
devices = json.load(open(sys.argv[1]))["devices"]
wanted = os.environ.get("TVOS_SIMULATOR_UDID", "")
name = os.environ.get("TVOS_SIMULATOR_NAME", "Apple TV 4K (3rd generation)")
candidates = [d for runtime, group in devices.items() if ".tvOS-" in runtime
              for d in group if d.get("isAvailable") and d["state"] == "Booted"
              and (d["udid"].lower() == wanted.lower() if wanted else d["name"] == name)]
if len(candidates) != 1:
    sys.exit("必须唯一指定已启动的 tvOS 模拟器；请设置 TVOS_SIMULATOR_UDID。禁止真机及 booted 别名。")
print(candidates[0]["udid"])
print(candidates[0]["dataPath"])
PY
)" || fail '未找到唯一的已启动 tvOS 模拟器'
simulator_udid="${simulator_selection%%$'\n'*}"
simulator_data_path="${simulator_selection#*$'\n'}"
printf '模拟器 UDID：%s；构建配置：%s；增量构建目录：%s\n' "$simulator_udid" "$configuration" "$derived_data"
# 清除调用环境的模拟器子进程开关，保证普通启动没有继承注入或验收设置。
for variable in ${!SIMCTL_CHILD_@}; do unset "$variable"; done
# 构建输出同时进入 CI 日志与本地证据；超时终止前也能看到最后的编译进展。
# 保留 pipefail，避免 tee 成功掩盖构建失败。
xcodebuild build -project "$repository_root/VPlayer.xcodeproj" -scheme VPlayer \
    -configuration "$configuration" -sdk appletvsimulator \
    -destination "platform=tvOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived_data" CLANG_ENABLE_CODE_COVERAGE=NO \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$evidence/build.log" || fail '模拟器构建失败'
app="$derived_data/Build/Products/$configuration-appletvsimulator/VPlayer.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
sdk="$(xcrun --sdk appletvsimulator --show-sdk-path)"
probe="$evidence/tvos_allocator_budget_probe.dylib"
xcrun clang -O2 -Wall -Wextra -Werror -dynamiclib \
    -target "$(uname -m)-apple-tvos27.0-simulator" -isysroot "$sdk" \
    "$repository_root/Scripts/Support/tvos_allocator_budget_probe.c" -o "$probe"
codesign --force --sign - "$probe" > "$evidence/probe-sign.log" 2>&1
xcrun simctl install "$simulator_udid" "$app" || fail '安装模拟器 App 失败'
for mode in normal step1; do
    for attempt in 1 2 3; do
        prefix="$evidence/$mode-$attempt"
        printf '冷启动：%s，第 %s/3 次\n' "$mode" "$attempt"
        xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
        launch=(xcrun simctl launch --stdout="$prefix.stdout.log" --stderr="$prefix.stderr.log"
                "$simulator_udid" "$bundle_id")
        launched=1
        if [[ "$mode" == step1 ]]; then
            SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$probe" "${launch[@]}" > "$prefix.launch.log" 2>&1 || fail '计费模拟启动失败'
        else
            "${launch[@]}" > "$prefix.launch.log" 2>&1 || fail '普通环境启动失败'
        fi
        pid="$(awk -F ': ' '/: [0-9]+$/ { print $NF }' "$prefix.launch.log")"
        [[ "$pid" =~ ^[0-9]+$ ]] || fail '启动没有返回有效进程 PID'
        for poll in 1 2 3 4; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || fail "$mode 第 $attempt 次进程退出，可能触发启动断言"
            state="$(ps -p "$pid" -o stat=)" || fail '启动进程已经退出'
            [[ "$state" != *Z* ]] || fail '启动进程已成为僵尸进程'
            ps -p "$pid" -o pid,stat,etime,command >> "$prefix.process.log"
            xcrun simctl spawn "$simulator_udid" launchctl list > "$prefix.launchctl.log"
            service_pid="$(awk -v name="UIKitApplication:$bundle_id[" 'index($3, name) == 1 { print $1 }' "$prefix.launchctl.log")"
            [[ "$service_pid" == "$pid" ]] || fail '模拟器 App 服务 PID 不匹配或已退出'
        done
        collect_process_logs
        if [[ "$mode" == step1 ]]; then
            /usr/bin/grep -q '仅模拟 tvOS xzone step1 计费取整' "$prefix.stderr.log" || fail '未确认计费探针注入'
        fi
        printf '通过：%s 第 %s 次，PID %s 持续存活 4 秒；证据：%s.*.log\n' "$mode" "$attempt" "$pid" "$prefix"
    done
done
printf '通过：六次冷启动均持续存活；证据目录：%s\n' "$evidence"
