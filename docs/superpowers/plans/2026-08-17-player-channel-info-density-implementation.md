# 播放页频道信息卡密度优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保留现有台标和频道标题结构，把右上角频道信息卡加宽到 560 pt，完整显示技术参数与当前节目时间，并把当前/下一节目压缩为两行。

**Architecture:** 只修改现有 `PlayerChannelInfoOverlay` 的布局，不改变媒体信息或 EPG 数据模型。DEBUG UI fixture 注入一份合成的 1080i、25→50 fps 媒体信息，让 XCUITest 在真实 tvOS SwiftUI 布局中验证卡片宽度、技术参数和节目行高度，并保存模拟器截图供人工检查。

**Tech Stack:** Swift 6、SwiftUI、tvOS 18、XCTest、XCUITest、tvOS Simulator。

## Global Constraints

- 卡片宽度固定为 560 pt，高度由内容自适应。
- 台标保持 68 × 56 pt，卡片内边距保持 20 pt，现有材质、圆角、描边和阴影不变。
- 技术参数不允许尾部省略；空间不足时最低缩放到 90%。
- 当前节目和下一节目各占一行，时间使用固定列，标题使用可伸缩列。
- 进度条位于两行之间，并从标题列起点开始。
- EPG 长标题允许尾部省略，完整语义继续由无障碍标签提供。
- 不改变 3 秒显示周期、播放门控、右上角安全区位置和遥控器交互。
- 只使用 seeded fixture 和合成媒体信息，不读取或启动真实 IPTV 源。
- 不修改或提交用户现有的 App Icon、`project.pbxproj` 和 Scheme 本地改动。

---

## File Structure

- 修改 `Sources/VPlayerApp/AppDependencies.swift`：DEBUG seeded fixture 可选发布合成媒体信息。
- 修改 `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`：520 pt 卡片、技术参数抗截断和两行 EPG。
- 修改 `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`：真实 tvOS 布局几何断言和截图附件。
- 复用 `Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift`：既有完整帧率格式测试，无需新增第二套格式化逻辑。

### Task 1: 建立合成媒体信息的 UI 回归入口

**Files:**
- Modify: `Sources/VPlayerApp/AppDependencies.swift`
- Modify: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`

**Interfaces:**
- Consumes: `-ui-playback-fixture media-information`、`AppDependencies.PlaybackMediaInformationProvider`。
- Produces: seeded 播放页中的 `PlaybackMediaInformation(width: 1920, height: 1080, scanMode: .interlaced, sourceFrameRate: 25, outputFrameRate: 50, isSmoothMotionEnhanced: true)`。

- [ ] **Step 1: 给 DEBUG UI dependencies 增加合成媒体信息 provider**

在 `AppDependencies` 的 DEBUG 区域增加：

```swift
private static func uiTestMediaInformationProvider(
    for playbackFixture: String?
) -> PlaybackMediaInformationProvider? {
    guard playbackFixture == "media-information" else { return nil }
    return {
        AsyncStream { continuation in
            continuation.yield(.some(PlaybackMediaInformation(
                width: 1_920,
                height: 1_080,
                scanMode: .interlaced,
                sourceFrameRate: MediaRational(num: 25, den: 1),
                outputFrameRate: 50,
                isSmoothMotionEnhanced: true
            )))
            continuation.finish()
        }
    }
}
```

在 `uiTesting(playbackFixture:)` 的成功和降级构造路径中都传入：

```swift
playbackMediaInformationProvider: uiTestMediaInformationProvider(
    for: playbackFixture
),
```

- [ ] **Step 2: 编写失败的 tvOS 几何回归测试**

在 `FullScreenPlayerUITests` 增加：

```swift
@MainActor
func testMediaInformationFixtureUsesWideCompactChannelCard() {
    let app = launchFixture(playback: "media-information")
    XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
    selectTab(named: "频道", in: app)
    XCTAssertTrue(app.buttons["channel.http"].wait(
        for: \.hasFocus,
        toEqual: true,
        timeout: 2
    ))
    XCUIRemote.shared.press(.select)

    let state = app.otherElements["player-acceptance-state"]
    XCTAssertTrue(state.waitForExistence(timeout: 3))
    XCTAssertEqual(state.value as? String, "playing")

    let card = app.otherElements["player-channel-info"]
    let current = app.otherElements.matching(
        NSPredicate(format: "label BEGINSWITH %@", "当前节目：")
    ).firstMatch
    let next = app.otherElements.matching(
        NSPredicate(format: "label BEGINSWITH %@", "下一节目：")
    ).firstMatch
    let technical = app.staticTexts[
        "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
    ]

    XCTAssertTrue(card.waitForExistence(timeout: 3))
    XCTAssertTrue(current.waitForExistence(timeout: 3))
    XCTAssertTrue(next.waitForExistence(timeout: 3))
    XCTAssertTrue(technical.waitForExistence(timeout: 3))
    XCTAssertEqual(card.frame.width, 520, accuracy: 2)
    XCTAssertLessThan(card.frame.height, 220)
    XCTAssertLessThan(current.frame.height, 30)
    XCTAssertLessThan(next.frame.height, 30)

    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "channel-info-density"
    screenshot.lifetime = .keepAlways
    add(screenshot)
}
```

- [ ] **Step 3: 运行新测试并确认旧布局失败**

Run:

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: FAIL。旧卡片宽度不是 520 pt，且当前/下一节目仍为时间与标题上下排列，节目元素高度超过单行上限。

### Task 2: 实现 520 pt 紧凑两行频道信息卡

**Files:**
- Modify: `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`
- Test: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`
- Test: `Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift`

**Interfaces:**
- Consumes: `ChannelProgrammePresentation.current`、`next`、`progress` 和现有 `PlaybackMediaInformationPresentation`。
- Produces: `PlayerChannelInfoOverlay` 的 520 pt 固定宽度、单行技术参数与单行 EPG row。

- [ ] **Step 1: 将卡片宽度改为 520 pt，并让无障碍标识落在真实卡片容器上**

把 `TimelineView` 外层宽度改为：

```swift
.frame(width: 520, alignment: .trailing)
```

从 `TimelineView` 移除 `.accessibilityIdentifier("player-channel-info")`，在 `card(...)` 的根 `VStack` 完成背景、描边和阴影后增加：

```swift
.accessibilityElement(children: .contain)
.accessibilityIdentifier("player-channel-info")
```

这让 UI 测试读到的是整张卡的 520 pt frame，而不是继承标识的节目子元素。

- [ ] **Step 2: 让技术参数优先占用宽度并最多缩小到 90%**

把技术参数 `Text` 的布局修饰符改为：

```swift
.font(.caption)
.foregroundStyle(.secondary)
.lineLimit(1)
.minimumScaleFactor(0.9)
.allowsTightening(true)
.layoutPriority(1)
.accessibilityLabel(accessibility.technicalText)
```

给“流畅增强”徽章增加：

```swift
.fixedSize(horizontal: true, vertical: false)
```

不修改 `PlaybackMediaInformationPresentation.visualText`，继续显示完整的 `1920×1080i · 25 fps → 50 fps`。

- [ ] **Step 3: 把 EPG row 从两层 VStack 改为单行 HStack**

在 `PlayerChannelInfoOverlay` 内增加：

```swift
private static let programmeTimeColumnWidth: CGFloat = 104
private static let programmeRowSpacing: CGFloat = 12
```

将 `programmeRow` 的显示主体改为：

```swift
let isCurrent = semanticLabel == "当前节目"
return HStack(alignment: .firstTextBaseline, spacing: Self.programmeRowSpacing) {
    Text(PlayerChannelInfoAccessibilityPresentation.programmeTimeText(
        label: semanticLabel,
        programme: programme
    ))
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .frame(width: Self.programmeTimeColumnWidth, alignment: .leading)

    Text(programme.title)
        .font(.subheadline.weight(isCurrent ? .semibold : .medium))
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

保留现有 `.accessibilityElement(children: .ignore)` 和完整无障碍标签。

- [ ] **Step 4: 收紧 EPG 行距并对齐进度条**

把 `programmeDetails` 根 `VStack` 间距由 12 改为 8，并给当前节目进度条增加：

```swift
.padding(
    .leading,
    Self.programmeTimeColumnWidth + Self.programmeRowSpacing
)
```

现有“只有无当前节目时才显示无后续节目占位”的条件保持原样。

- [ ] **Step 5: 运行回归测试并确认通过**

Run:

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests \
  -only-testing:VPlayerTests/ProjectConfigurationTests
```

Expected: PASS。卡片宽 520 pt、高度小于 220 pt，两条节目元素均为单行高度，完整技术参数无障碍文本存在。

- [ ] **Step 6: 提交功能实现**

```bash
git add Sources/VPlayerApp/AppDependencies.swift \
  Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift \
  Tests/VPlayerUITests/FullScreenPlayerUITests.swift
git commit -m "fix(player): 优化频道信息卡尺寸与节目密度"
```

### Task 3: 模拟器视觉检查与完整验证

**Files:**
- Inspect: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`
- Inspect: latest `Test-VPlayer-*.xcresult` screenshot attachment

**Interfaces:**
- Consumes: `channel-info-density` XCTest screenshot attachment。
- Produces: 对 520 pt 卡片、完整技术参数、两行 EPG 和右上安全区的人工视觉结论。

- [ ] **Step 1: 重新运行截图测试，生成最新 xcresult**

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: PASS，xcresult 包含名为 `channel-info-density` 的 keepAlways 截图。

- [ ] **Step 2: 从最新 xcresult 导出并查看截图**

```bash
VPLAYER_RESULT_BUNDLE=$(ls -td \
  /Users/daniel/Library/Developer/Xcode/DerivedData/VPlayer-*/Logs/Test/Test-VPlayer-*.xcresult \
  | head -1)
VPLAYER_SCREENSHOT_DIR=$(mktemp -d)
xcrun xcresulttool export attachments \
  --path "$VPLAYER_RESULT_BUNDLE" \
  --output-path "$VPLAYER_SCREENSHOT_DIR"
rg -n 'channel-info-density' "$VPLAYER_SCREENSHOT_DIR/manifest.json"
```

从 `manifest.json` 读取对应导出文件名，使用本地图片查看工具打开该 PNG，人工确认：

- 卡片仍位于右上角，未遮挡底部控制。
- 台标与频道标题结构和改动前一致。
- `1920×1080i · 25 fps → 50 fps` 与“流畅增强”均无截断或重叠。
- 当前、下一节目各一行，进度条从标题列开始。
- 卡片不显得横向过宽或纵向臃肿。

- [ ] **Step 3: 运行完整安全回归**

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests

xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests

xcodebuild build -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -configuration Release -destination 'generic/platform=tvOS Simulator'
```

Expected: 单元测试和播放器 seeded UI 测试全部通过，Release 构建退出码为 0。不得运行 `LiveStartupUITests` 或长时真实源验收。

- [ ] **Step 4: 检查 diff、隐私和工作树边界**

```bash
git diff --check
git status --short
git diff --stat HEAD^..HEAD
```

只允许计划列出的 3 个功能/测试文件发生变化。扫描新增行中的 URL、IPv4/IPv6、`token`、`auth`、`password`、`secret` 和 API key 模式；预期零匹配。确认主工作区原有 App Icon、工程文件和 Scheme 修改未进入提交。

### Task 4: 将频道名称缩小一个语义级别并重新截图

**Files:**
- Modify: `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`
- Inspect: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`
- Inspect: latest `channel-info-density` screenshot attachment

**Interfaces:**
- Consumes: `ChannelHeaderPresentation.title` 与现有频道标题单行布局。
- Produces: `.subheadline.weight(.semibold)` 的频道名称；台标、技术参数、EPG、卡片尺寸和行为保持不变。

- [ ] **Step 1: 记录修改前视觉基线**

复用 Task 3 已导出的可见模拟器截图，确认当前频道名称使用 `.headline.weight(.semibold)`，作为仅比较标题字号的视觉基线。此项属于用户要求的视觉微调，不新增只检查字体常量的脆弱测试。

- [ ] **Step 2: 仅将频道名称缩小一级**

在 `PlayerChannelInfoOverlay.card(...)` 的频道名称 `Text` 上，将：

```swift
.font(.headline.weight(.semibold))
```

改为：

```swift
.font(.subheadline.weight(.semibold))
```

不得修改台标、技术参数、徽章、EPG、卡片宽高、内边距、3 秒周期、安全区或交互。

- [ ] **Step 3: 运行 seeded UI 回归并导出新截图**

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: PASS，并生成非黑场的 `channel-info-density` keepAlways 截图。实际查看新 PNG，确认频道名称明显缩小一级但仍清晰，且其余布局与修改前一致。

- [ ] **Step 4: 运行播放器 UI 回归并提交**

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests

git add Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift
git commit -m "style(player): 缩小频道信息卡标题字号"
```

Expected: 6 项 seeded 播放器 UI 测试全部通过；不运行 `LiveStartupUITests` 或真实源验收。

### Task 5: 消除技术参数与当前节目时间截断

**Files:**
- Modify: `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`
- Modify: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`
- Inspect: latest `channel-info-density` screenshot attachment

**Interfaces:**
- Consumes: `PlayerChannelInfoOverlay` 现有 520 pt 卡片、104 pt 时间列，以及 Task 4 确认的 `.subheadline.weight(.semibold)` 频道名称。
- Produces: 560 pt 卡片、136 pt 时间列、完整 `1920×1080i · 25 fps → 50 fps` 与完整当前节目时间范围。

- [ ] **Step 1: 将 UI 几何回归期望改为 560 pt 并确认 RED**

在 `testMediaInformationFixtureUsesWideCompactChannelCard` 中把：

```swift
XCTAssertEqual(card.frame.width, 520, accuracy: 2)
```

改为：

```swift
XCTAssertEqual(card.frame.width, 560, accuracy: 2)
```

运行：

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: FAIL，旧实现仍为 520 pt。

- [ ] **Step 2: 加宽卡片和时间列**

在 `PlayerChannelInfoOverlay` 中只修改以下两个常量：

```swift
private static let programmeTimeColumnWidth: CGFloat = 136
```

以及：

```swift
.frame(width: 560, alignment: .trailing)
```

保留 Task 4 的 `.subheadline.weight(.semibold)` 频道名称、`caption2` EPG、8 pt 主间距、技术参数 90% 最低缩放、流畅增强徽章、台标、内边距和自适应高度。

- [ ] **Step 3: 运行 GREEN 并导出新截图**

重新运行 Step 1 的 focused test。Expected: PASS，并生成非黑场的 `channel-info-density` keepAlways 截图。

从这次 focused xcresult 导出附件并实际查看，确认：

- 技术参数完整显示为 `1920×1080i · 25 fps → 50 fps`，无省略号。
- 当前节目时间范围完整显示，无省略号。
- “流畅增强”徽章、节目标题、进度条和底部控制无重叠。
- 560 pt 卡片仍位于右上安全区，整体宽度可接受。

- [ ] **Step 4: 运行播放器 UI 回归并提交**

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests

git add Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift \
  Tests/VPlayerUITests/FullScreenPlayerUITests.swift
git commit -m "fix(player): 完整显示频道技术与时间信息"
```

Expected: 6 项 seeded 播放器 UI 测试全部通过；不运行 `LiveStartupUITests` 或真实源验收。
