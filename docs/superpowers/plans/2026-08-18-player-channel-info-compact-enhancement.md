# 播放页频道信息卡紧凑倍帧标签实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将右上角频道信息卡收窄为 500 pt，用绿色 `25 → 50 fps` 标签表达倍帧，并把 EPG 标题和进度条限制为 280 pt。

**Architecture:** `PlaybackMediaInformationPresentation` 分别输出分辨率文本、帧率文本和帧率是否需要绿色强调，`PlayerChannelInfoOverlay` 只负责组合与样式，不解析展示字符串。现有 seeded `media-information` fixture 继续提供合成的 1080i、25→50 fps 数据，单元测试验证格式与强调条件，XCUITest 验证真实 tvOS 布局几何并生成截图。

**Tech Stack:** Swift 6、SwiftUI、tvOS 18、XCTest、XCUITest、tvOS Simulator。

## Global Constraints

- 卡片固定宽度为 500 pt，高度继续由内容自适应。
- 台标保持 68 × 56 pt，卡片内边距保持 20 pt，现有材质、圆角、描边和阴影不变。
- 倍帧帧率显示为 `25 → 50 fps`，源帧率不重复 `fps`。
- 倍帧帧率使用 `.caption`、绿色前景、8 pt 水平与 4 pt 垂直内边距、`Color.green.opacity(0.16)` 胶囊背景。
- 无倍帧时显示普通的单帧率文本，例如 `25 fps`，不显示绿色背景。
- 完全移除独立的“流畅增强”可见文字；无障碍技术说明继续完整表达增强语义。
- 当前节目和下一节目继续各占一行；时间列保持 136 pt，标题列和进度条宽度均为 280 pt。
- 技术参数和当前节目时间不允许出现尾部省略号；技术文本最低缩放比例保持 0.9。
- 不改变 3 秒显示周期、播放门控、右上角安全区位置和遥控器交互。
- 只使用 seeded fixture 和合成媒体信息，不读取、启动或记录真实 IPTV 源。
- 不修改或提交用户现有的 App Icon、`project.pbxproj` 和 Scheme 本地改动。

---

## File Structure

- 修改 `Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift`：提供分辨率、帧率与绿色强调条件的独立展示输出。
- 修改 `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`：组合紧凑技术标签，收窄卡片，并统一 EPG 标题和进度条宽度。
- 修改 `Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift`：覆盖倍帧单位压缩、普通帧率和不完整倍帧信息。
- 修改 `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`：验证 500 pt 卡片、280 pt 进度条和完整无障碍技术说明，保存模拟器截图。

### Task 1: 实现紧凑倍帧标签与限宽 EPG

**Files:**
- Modify: `Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift`
- Modify: `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`
- Test: `Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift`
- Test: `Tests/VPlayerUITests/FullScreenPlayerUITests.swift`

**Interfaces:**
- Consumes: `PlaybackMediaInformation`、`ChannelProgrammePresentation` 和既有 seeded `-ui-playback-fixture media-information`。
- Produces: `PlaybackMediaInformationPresentation.visualResolutionText: String?`、`visualFrameRateText: String?`、`showsEnhancedFrameRateHighlight: Bool`，以及 500 pt 的 `PlayerChannelInfoOverlay`。

- [ ] **Step 1: 先写倍帧格式与强调条件的失败测试**

在 `PlaybackMediaInformationPresentationTests` 中把增强场景的视觉期望从重复单位格式改成紧凑格式，并直接验证三个展示输出：

```swift
XCTAssertEqual(subject.visualResolutionText, "1920×1080i")
XCTAssertEqual(subject.visualFrameRateText, "25 → 50 fps")
XCTAssertEqual(subject.visualText, "1920×1080i · 25 → 50 fps")
XCTAssertTrue(subject.showsEnhancedFrameRateHighlight)
```

普通逐行场景增加：

```swift
XCTAssertEqual(subject.visualResolutionText, "1920×1080p")
XCTAssertEqual(subject.visualFrameRateText, "50 fps")
XCTAssertFalse(subject.showsEnhancedFrameRateHighlight)
```

增强信息缺少输出帧率的场景保持 `1920×1080i · 25 fps`，并改为：

```swift
XCTAssertEqual(subject.visualFrameRateText, "25 fps")
XCTAssertFalse(subject.showsEnhancedFrameRateHighlight)
```

将其余增强场景的视觉期望按同一规则精确改为：

- `1280×720i · 29.97 → 59.94 fps`
- `1920×1080i · 25 → 50 fps`
- `1920×1080i · 25 → 52 fps`
- `1920×1080i · 30 → 60 fps`
- `1920×1080i · 30 → 58.79 fps`
- `1920×1080i · 30 → 61.21 fps`

删除 `badgeText` 和 `showsSmoothMotionBadge` 的旧断言；无障碍文本期望保持原样。

- [ ] **Step 2: 先写真实布局的失败测试**

在 `testMediaInformationFixtureUsesWideCompactChannelCard` 中把卡片宽度期望改为 500 pt，并查询节目进度条：

```swift
let progress = app.progressIndicators["player-channel-progress"]

XCTAssertTrue(progress.waitForExistence(timeout: 3))
XCTAssertEqual(card.frame.width, 500, accuracy: 2)
XCTAssertEqual(progress.frame.width, 280, accuracy: 2)
```

技术说明使用任意元素类型查询，避免 SwiftUI 将拆分后的视觉文字暴露为多个 `StaticText`：

```swift
let technical = app.descendants(matching: .any)[
    "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
]
```

保留卡片高度、当前/下一节目单行高度和截图附件断言。

- [ ] **Step 3: 运行失败测试并确认 RED**

Run:

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: FAIL。旧展示仍包含 `25 fps → 50 fps`，不存在 `showsEnhancedFrameRateHighlight`，卡片宽度为 560 pt，进度条也没有 280 pt 的稳定标识和宽度。

- [ ] **Step 4: 实现独立的视觉展示输出**

在 `PlaybackMediaInformationPresentation` 中增加私有展示结构：

```swift
private struct VisualParts: Sendable {
    let resolution: String?
    let frameRate: String?
    let highlightsFrameRate: Bool
}
```

增加公开给同一模块视图使用的计算属性：

```swift
var visualResolutionText: String? { visualParts.resolution }
var visualFrameRateText: String? { visualParts.frameRate }
var showsEnhancedFrameRateHighlight: Bool { visualParts.highlightsFrameRate }
```

`visualParts` 使用既有的 `smoothMotionEnhancementIsActive` 和 `frameRateValues`：当增强状态成立且源、输出帧率都有效时，返回 `"源 → 输出 fps"` 并把 `highlightsFrameRate` 设为 `true`；否则返回单帧率 `"输出或源 fps"` 并设为 `false`。`visualText` 使用 `" · "` 连接非空的分辨率和帧率；媒体信息为空时仍返回 `正在检测画面规格…`。删除 `showsSmoothMotionBadge`。

- [ ] **Step 5: 实现 500 pt 技术标签和 280 pt EPG 内容列**

在 `PlayerChannelInfoOverlay` 中：

```swift
private static let programmeContentColumnWidth: CGFloat = 280
```

将外层宽度改为：

```swift
.frame(width: 500, alignment: .trailing)
```

删除 `PlayerChannelInfoAccessibilityPresentation.badgeText`，并把对应测试重命名为 `testPlayerChannelInfoAccessibilityUsesChineseSemantics`。把单个技术 `Text` 和独立“流畅增强”徽章替换为以下不可拆分技术信息视图：

```swift
private var technicalInformation: some View {
    let media = PlaybackMediaInformationPresentation(information: mediaInformation)
    return HStack(spacing: 6) {
        if let resolution = media.visualResolutionText {
            Text(resolution)
                .foregroundStyle(.secondary)
        }
        if media.visualResolutionText != nil, media.visualFrameRateText != nil {
            Text("·")
                .foregroundStyle(.secondary)
        }
        if let frameRate = media.visualFrameRateText {
            if media.showsEnhancedFrameRateHighlight {
                Text(frameRate)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.16))
                    )
            } else {
                Text(frameRate)
                    .foregroundStyle(.secondary)
            }
        }
        if media.visualResolutionText == nil, media.visualFrameRateText == nil {
            Text(media.visualText)
                .foregroundStyle(.secondary)
        }
    }
    .font(.caption)
    .lineLimit(1)
    .minimumScaleFactor(0.9)
    .allowsTightening(true)
    .layoutPriority(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(media.accessibilityText)
    .accessibilityIdentifier("player-channel-technical")
}
```

在 `channelHeader` 中直接使用 `technicalInformation`。

节目标题固定为：

```swift
.frame(width: Self.programmeContentColumnWidth, alignment: .leading)
```

进度条固定宽度并增加稳定测试标识：

```swift
.frame(width: Self.programmeContentColumnWidth)
.padding(
    .leading,
    Self.programmeTimeColumnWidth + Self.programmeRowSpacing
)
.accessibilityLabel("当前节目进度")
.accessibilityIdentifier("player-channel-progress")
```

- [ ] **Step 6: 运行 GREEN 测试**

Run:

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests/testMediaInformationFixtureUsesWideCompactChannelCard
```

Expected: PASS。倍帧单位只出现一次，只有完整倍帧状态需要绿色强调，卡片宽 500 pt，进度条宽 280 pt。

- [ ] **Step 7: 跑播放器 seeded UI 回归并导出截图**

Run:

```bash
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer \
  -derivedDataPath /tmp/VPlayerChannelInfoDensityDerivedData-20260817 \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerUITests/FullScreenPlayerUITests
```

Expected: 6/6 PASS，最新 xcresult 含 `channel-info-density` 截图。只允许使用 seeded fixture；不得运行 `LiveStartupUITests`、`LongPlaybackAcceptanceTests` 或任何真实源回归。

- [ ] **Step 8: 检查隐私、diff 与提交边界**

Run:

```bash
git diff --check
git status --short
git diff --stat
git diff -U0 | rg -n 'https?://|([0-9]{1,3}\.){3}[0-9]{1,3}|token|auth|password|secret|api[_-]?key' || true
```

Expected: 功能 diff 只涉及本任务列出的 4 个文件；新增行不含真实 URL、IP 地址、令牌、认证信息、密码、密钥或个人源数据。

- [ ] **Step 9: 提交实现**

```bash
git add Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift \
  Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift \
  Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift \
  Tests/VPlayerUITests/FullScreenPlayerUITests.swift
git commit -m "fix(player): 收紧频道信息与倍帧标签"
```
