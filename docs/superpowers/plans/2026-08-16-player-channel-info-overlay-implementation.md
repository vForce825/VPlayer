# 播放页频道信息浮层实施计划

> **供 agent worker 使用：** 必须逐任务使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`。所有执行步骤使用复选框跟踪。

**目标：** 在 tvOS 全屏播放页右上角加入复用首页 EPG 语言的频道信息卡，并在首帧出现时可靠展示 `25 fps → 50 fps  流畅增强` 等真实媒体规格。

**架构：** 应用层新增独立的频道展示上下文和共用 EPG/台标组件；播放层通过轻量媒体信息流输出分辨率、扫描方式、源帧率和输出帧率。初始播放就绪必须等待有上限的扫描分类和媒体信息组装完成，UI 则由全屏播放器统一管理信息卡与控制层的 3 秒可见性。

**技术栈：** Swift 6、SwiftUI、tvOS 18、Swift Concurrency、FFmpeg C bridge、CoreMedia、XCTest、XcodeGen。

## 全局约束

- 所有用户可见文案使用简体中文。
- `MARKETING_VERSION` 保持为 `1.3`，不得回退。
- 不显示线路数量和延迟。
- 信息卡位于右上安全区域，不可聚焦、不接受点击。
- 初始扫描分类完成或有上限回退生效前，不发布 `.playing`，不呈现第一帧。
- 稳定播放时信息卡与控制层共用 3 秒自动隐藏周期。
- 只有确认隔行扫描且启用 `metalYADIF2x` 时才显示箭头和 `流畅增强`。
- 不修改或提交主工作区中与本功能无关的 Xcode、Scheme、App Icon 本地改动。

---

## 文件结构

- 新建 `Sources/VPlayerApp/Views/ChannelProgrammePresentation.swift`：首页与播放页共用的当前节目、下一节目和进度计算。
- 新建 `Sources/VPlayerApp/Views/ChannelLogoView.swift`：首页与播放页共用的缓存台标和占位视图。
- 新建 `Sources/VPlayerApp/Player/PlayerChannelPresentation.swift`：应用层播放展示上下文。
- 新建 `Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`：右上频道信息卡纯展示视图。
- 新建 `Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift`：媒体规格文案和无障碍文案格式化。
- 新建 `Sources/VPlayerPlayback/Diagnostics/PlaybackMediaInformation.swift`：轻量产品级媒体信息结构与 provider 协议。
- 修改 `Sources/VPlayerPlayback/include/VPFFmpegDemuxer.h`、`Sources/VPlayerPlayback/FFmpeg/VPFFmpegDemuxer.c`、`Sources/VPlayerPlayback/Demux/FFmpegDemuxer.swift`、`Sources/VPlayerPlayback/Media/MediaCodec.swift`：源帧率跨 C/Swift 边界。
- 修改 `Sources/VPlayerPlayback/Deinterlace/VideoPipelineCoordinator.swift`、`Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift`、`Sources/VPlayerPlayback/Pipeline/PlaybackController.swift`：分类就绪、媒体信息发布和过期会话过滤。
- 修改 `Sources/VPlayerApp/AppDependencies.swift`、`Sources/VPlayerApp/Views/RootView.swift`、`Sources/VPlayerApp/Player/FullScreenPlayerViewModel.swift`、`Sources/VPlayerApp/Player/FullScreenPlayerView.swift`、`Sources/VPlayerApp/Player/PlayerControlsOverlay.swift`：数据接入和浮层生命周期。
- 修改 `Sources/VPlayerApp/Views/ChannelCard.swift`：使用共用 EPG/台标组件。
- 新建或修改对应 `Tests/VPlayerTests` 测试；最后用 XcodeGen 2.44.1 重新生成工程文件。

---

### 任务 1：抽取首页与播放页共用的 EPG 和台标展示单元

**文件：**
- 新建：`Sources/VPlayerApp/Views/ChannelProgrammePresentation.swift`
- 新建：`Sources/VPlayerApp/Views/ChannelLogoView.swift`
- 修改：`Sources/VPlayerApp/Views/ChannelCard.swift`
- 新建：`Tests/VPlayerTests/ChannelProgrammePresentationTests.swift`

**接口：**
- 输入：`[Programme]` 和 `Date`。
- 输出：`ChannelProgrammePresentation(current: Programme?, next: Programme?, progress: Double?)`。
- 输出视图：`ChannelLogoView(url: URL?)`，内部继续使用 `ChannelLogoCache.shared`。

- [ ] **步骤 1：编写失败的 EPG 边界测试**

```swift
@MainActor
final class ChannelProgrammePresentationTests: XCTestCase {
    func testSelectsCurrentNextAndProgressAtProgrammeBoundary() {
        let first = programme(title: "新闻", start: 0, stop: 1_800)
        let second = programme(title: "天气", start: 1_800, stop: 3_600)

        let during = ChannelProgrammePresentation.resolve(
            programmes: [first, second],
            at: date(900)
        )
        XCTAssertEqual(during.current?.title, "新闻")
        XCTAssertEqual(during.next?.title, "天气")
        XCTAssertEqual(during.progress, 0.5, accuracy: 0.0001)

        let boundary = ChannelProgrammePresentation.resolve(
            programmes: [first, second],
            at: date(1_800)
        )
        XCTAssertEqual(boundary.current?.title, "天气")
        XCTAssertNil(boundary.next)
        XCTAssertEqual(boundary.progress, 0, accuracy: 0.0001)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func programme(title: String, start: TimeInterval, stop: TimeInterval) -> Programme {
        Programme(
            id: title,
            xmltvChannelID: "channel",
            start: date(start),
            stop: date(stop),
            title: title,
            subtitle: nil,
            summary: nil,
            categories: []
        )
    }
}
```

- [ ] **步骤 2：运行测试并确认因类型不存在而失败**

运行：

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/ChannelProgrammePresentationTests
```

预期：编译失败，提示找不到 `ChannelProgrammePresentation`。

- [ ] **步骤 3：实现最小共用模型和台标视图**

```swift
struct ChannelProgrammePresentation: Equatable {
    let current: Programme?
    let next: Programme?
    let progress: Double?

    static func resolve(programmes: [Programme], at date: Date) -> Self {
        let current = programmes.first { $0.start <= date && date < $0.stop }
        let next = programmes.first { $0.start >= (current?.stop ?? date) }
        let progress = current.flatMap { programme -> Double? in
            let duration = programme.stop.timeIntervalSince(programme.start)
            guard duration > 0 else { return nil }
            return min(max(date.timeIntervalSince(programme.start) / duration, 0), 1)
        }
        return Self(current: current, next: next, progress: progress)
    }
}
```

将 `CachedChannelLogo` 和 `ChannelLogoPlaceholder` 从 `ChannelCard.swift` 移到 `ChannelLogoView.swift`，保持缓存、占位、缩放和内边距行为不变。`ChannelCard` 改为消费共用模型，不保留第二套当前/下一节目算法。

- [ ] **步骤 4：运行 EPG 测试和现有频道相关测试**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/ChannelProgrammePresentationTests \
  -only-testing:VPlayerTests/ChannelSectionsTests
```

预期：全部通过。

- [ ] **步骤 5：提交任务 1**

```bash
git add Sources/VPlayerApp/Views Tests/VPlayerTests/ChannelProgrammePresentationTests.swift
git commit -m "refactor(epg): 复用频道节目展示逻辑"
```

---

### 任务 2：将源视频帧率从 FFmpeg 安全传到 Swift 轨道描述

**文件：**
- 修改：`Sources/VPlayerPlayback/include/VPFFmpegDemuxer.h`
- 修改：`Sources/VPlayerPlayback/FFmpeg/VPFFmpegDemuxer.c`
- 修改：`Sources/VPlayerPlayback/Demux/FFmpegDemuxer.swift`
- 修改：`Sources/VPlayerPlayback/Media/MediaCodec.swift`
- 修改：`Tests/VPlayerTests/Playback/FFmpegDemuxerTests.swift`
- 修改：`Tests/VPlayerTests/Playback/MediaCodecTests.swift`
- 修改：`Tests/VPlayerTests/PlaybackSupport/DemuxEventRecorder.swift`
- 修改：`Tests/VPlayerTests/PlaybackSupport/PlaybackComponentFakes.swift`

**接口：**
- `VPFFTrack` 新增 `frame_rate_num`、`frame_rate_den`。
- `VideoTrackDescriptor` 新增 `frameRate: MediaRational?`。
- 帧率来源按 `av_guess_frame_rate(format, stream, nil)` 取得；无效值跨桥后变为 `nil`，不伪造默认帧率。

- [ ] **步骤 1：编写失败的桥接复制与非法值测试**

在 `FFmpegDemuxerTests` 增加：

```swift
func testCopiesValidVideoFrameRateAndTreatsInvalidRateAsUnknown() throws {
    let valid = FakeFFmpegDemuxBridge { handle in
        handle.emitTracks(video: .h264(frameRateNum: 25, frameRateDen: 1))
        handle.emitTerminal(VPFF_EVENT_END)
        return 0
    }
    guard case let .tracks(tracks) = try run(bridge: valid).first else {
        return XCTFail("missing tracks")
    }
    XCTAssertEqual(tracks.video?.frameRate, MediaRational(num: 25, den: 1))
}
```

同时给 `MediaCodecTests` 增加指纹/相等性覆盖，确保帧率变化能被识别为轨道变化。

- [ ] **步骤 2：运行测试并确认失败**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/FFmpegDemuxerTests \
  -only-testing:VPlayerTests/MediaCodecTests
```

预期：编译失败，提示缺少帧率字段或初始化参数。

- [ ] **步骤 3：实现 C/Swift 帧率传递**

在 C 层选择视频流后调用 `av_guess_frame_rate`，只接受正的、可装入 `int32_t` 的分子分母。`vpff_make_video_track` 接收帧率参数并填充公共结构；公共轨道相等性也比较这两个字段。Swift 层使用：

```swift
let frameRate = MediaRational(
    num: raw.frame_rate_num,
    den: raw.frame_rate_den
)
```

零值或非法值返回 `nil`，视频仍可播放。

- [ ] **步骤 4：运行桥接、媒体类型和工程配置测试**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/FFmpegDemuxerTests \
  -only-testing:VPlayerTests/MediaCodecTests \
  -only-testing:VPlayerTests/ProjectConfigurationTests
```

预期：全部通过，版本仍为 1.3。

- [ ] **步骤 5：提交任务 2**

```bash
git add Sources/VPlayerPlayback/include/VPFFmpegDemuxer.h \
  Sources/VPlayerPlayback/FFmpeg/VPFFmpegDemuxer.c \
  Sources/VPlayerPlayback/Demux/FFmpegDemuxer.swift \
  Sources/VPlayerPlayback/Media/MediaCodec.swift \
  Tests/VPlayerTests/Playback Tests/VPlayerTests/PlaybackSupport
git commit -m "feat(playback): 传递视频源帧率"
```

---

### 任务 3：新增产品级媒体信息流并让首帧等待分类完成

**文件：**
- 新建：`Sources/VPlayerPlayback/Diagnostics/PlaybackMediaInformation.swift`
- 修改：`Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift`
- 修改：`Sources/VPlayerPlayback/Pipeline/PlaybackController.swift`
- 修改：`Sources/VPlayerPlayback/Deinterlace/VideoPipelineCoordinator.swift`
- 修改：`Tests/VPlayerTests/Playback/PlaybackPipelineTests.swift`
- 修改：`Tests/VPlayerTests/Deinterlace/VideoPipelineCoordinatorTests.swift`
- 修改：`Tests/VPlayerTests/PlaybackSupport/PlaybackComponentFakes.swift`

**接口：**
- 新增 `PlaybackMediaInformation`：`width`、`height`、`scanMode`、`sourceFrameRate`、`outputFrameRate`、`isSmoothMotionEnhanced`。
- 新增 `PlaybackMediaInformationProviding`：`func playbackMediaInformation() -> AsyncStream<PlaybackMediaInformation?>`。
- `PlaybackPipelineEvent` 新增携带当前媒体代次的信息事件；`PlaybackController` 只转发当前会话的数据。

- [ ] **步骤 1：编写失败的媒体信息与就绪门控测试**

在 `PlaybackPipelineTests` 增加两类测试：

```swift
func testControllerClearsMediaInformationAcrossReplacementAndFailure() async throws {
    let first = FakeControllerPipeline()
    let second = FakeControllerPipeline()
    let controller = PlaybackController(factory: FakeControllerPipelineFactory([first, second]))
    var info = await controller.playbackMediaInformation().makeAsyncIterator()
    let initial = await info.next()
    XCTAssertNotNil(initial)
    XCTAssertNil(initial!)

    await controller.play(makeRequest(title: "first"))
    first.emit(.mediaInformation(PlaybackMediaInformation(
        width: 1_920,
        height: 1_080,
        scanMode: .interlaced,
        sourceFrameRate: MediaRational(num: 25, den: 1),
        outputFrameRate: 50,
        isSmoothMotionEnhanced: true
    )))
    let publishedEvent = await info.next()
    let published = try XCTUnwrap(publishedEvent ?? nil)
    XCTAssertEqual(published.width, 1_920)

    await controller.play(makeRequest(title: "second"))
    let cleared = await info.next()
    XCTAssertNotNil(cleared)
    XCTAssertNil(cleared!)
}
```

管线测试需要断言：`videoCoordinator.route == .rawWhileClassifying` 时即使音视频缓存已满足，也不能收到 `.ready`；分类变为 `.bypass` 或 `.metalYADIF2x` 且媒体信息组装后，才收到一次 `.ready`。

- [ ] **步骤 2：运行测试并确认失败**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackPipelineTests \
  -only-testing:VPlayerTests/VideoPipelineCoordinatorTests
```

预期：编译失败或旧逻辑过早发布 `.ready`。

- [ ] **步骤 3：实现媒体信息模型、发布流与分类门控**

模型至少包含：

```swift
public enum PlaybackScanMode: Sendable, Equatable {
    case progressive
    case interlaced
}

public struct PlaybackMediaInformation: Sendable, Equatable {
    public let width: Int32
    public let height: Int32
    public let scanMode: PlaybackScanMode
    public let sourceFrameRate: MediaRational?
    public let outputFrameRate: Double?
    public let isSmoothMotionEnhanced: Bool
}
```

管线仅在 `route != .rawWhileClassifying`、视频格式存在、当前媒体代次有效时组装信息。YADIF 2× 的 `outputFrameRate` 优先使用实际输出帧 duration 推导，并用源帧率校验；旁路输出等于源帧率。发布信息后再允许 `updateReadinessIsolated()` 发出 `.ready`。

控制器在 `play`、`stop`、失败和替换会话时向订阅者发布 `nil`；旧 session 的迟到事件通过已有 `sessionID` 检查丢弃。

- [ ] **步骤 4：运行播放管线、分类和控制器测试**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackPipelineTests \
  -only-testing:VPlayerTests/VideoPipelineCoordinatorTests \
  -only-testing:VPlayerTests/PlaybackPresentationContextTests
```

预期：全部通过；既有暂停/恢复 readiness cycle 不回归。

- [ ] **步骤 5：提交任务 3**

```bash
git add Sources/VPlayerPlayback/Diagnostics/PlaybackMediaInformation.swift \
  Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift \
  Sources/VPlayerPlayback/Pipeline/PlaybackController.swift \
  Sources/VPlayerPlayback/Deinterlace/VideoPipelineCoordinator.swift \
  Tests/VPlayerTests/Playback Tests/VPlayerTests/Deinterlace \
  Tests/VPlayerTests/PlaybackSupport
git commit -m "feat(playback): 发布首帧媒体信息"
```

---

### 任务 4：实现稳定、可无障碍朗读的媒体规格文案

**文件：**
- 新建：`Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift`
- 新建：`Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift`

**接口：**
- 输入：`PlaybackMediaInformation?`。
- 输出：`visualText`、`accessibilityText`、`showsSmoothMotionBadge`。

- [ ] **步骤 1：编写失败的格式化矩阵测试**

```swift
func testFormatsInterlacedDoubleRateWithUnitsArrowAndBenefit() {
    let subject = PlaybackMediaInformationPresentation(
        information: PlaybackMediaInformation(
            width: 1_920,
            height: 1_080,
            scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: 50,
            isSmoothMotionEnhanced: true
        )
    )
    XCTAssertEqual(subject.visualText, "1920×1080i · 25 fps → 50 fps")
    XCTAssertTrue(subject.showsSmoothMotionBadge)
    XCTAssertEqual(
        subject.accessibilityText,
        "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
    )
}
```

同一测试文件覆盖 `1080p50`、29.97/59.94、分辨率缺失不可发生、帧率为 nil、无效/超过 120 fps 值和检测中状态。

- [ ] **步骤 2：运行测试并确认失败**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests
```

预期：编译失败，提示 presentation 类型不存在。

- [ ] **步骤 3：实现纯格式化模型**

帧率格式化规则：整数不带小数；23.976、29.97、59.94 等标准值最多保留三位；不显示滚动测量值。未取得媒体信息时 `visualText` 返回 `正在检测画面规格…`。`流畅增强` 作为独立 badge，由 `showsSmoothMotionBadge` 控制，不重复拼进主字符串。

- [ ] **步骤 4：运行格式化与无障碍测试**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests
```

预期：全部通过。

- [ ] **步骤 5：提交任务 4**

```bash
git add Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift \
  Tests/VPlayerTests/PlaybackMediaInformationPresentationTests.swift
git commit -m "feat(player): 格式化播放媒体规格"
```

---

### 任务 5：接入频道展示上下文并实现右上信息卡

**文件：**
- 新建：`Sources/VPlayerApp/Player/PlayerChannelPresentation.swift`
- 新建：`Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift`
- 修改：`Sources/VPlayerApp/AppDependencies.swift`
- 修改：`Sources/VPlayerApp/Views/RootView.swift`
- 修改：`Sources/VPlayerApp/Player/FullScreenPlayerViewModel.swift`
- 修改：`Sources/VPlayerApp/Player/FullScreenPlayerView.swift`
- 修改：`Tests/VPlayerTests/FullScreenPlayerViewModelTests.swift`
- 修改：`Tests/VPlayerTests/ProjectConfigurationTests.swift`

**接口：**
- `PlayerChannelPresentation` 包含 `request`、`logoURL`、`programmes`。
- `AppDependencies` 新增媒体信息 provider，生产实现连接 `PlaybackController.playbackMediaInformation()`。
- `FullScreenPlayerViewModel.mediaInformation` 保存当前会话值，停止/重试时清空。

- [ ] **步骤 1：编写失败的展示上下文与订阅生命周期测试**

在 `FullScreenPlayerViewModelTests` 增加：

```swift
func testMediaInformationSubscriptionClearsOnRetryAndStop() async throws {
    let media = ViewModelMediaInformationFeed()
    let model = FullScreenPlayerViewModel(
        request: makeRequest(),
        engine: ViewModelPlaybackEngine(log: .init()),
        presentationProvider: { nil },
        mediaInformationProvider: { await media.stream() },
        settings: makeSettings()
    )
    model.start()
    await media.emit(PlaybackMediaInformation(
        width: 1_920,
        height: 1_080,
        scanMode: .interlaced,
        sourceFrameRate: MediaRational(num: 25, den: 1),
        outputFrameRate: 50,
        isSmoothMotionEnhanced: true
    ))
    try await eventually { model.mediaInformation?.width == 1_920 }
    await model.stop()
    XCTAssertNil(model.mediaInformation)
}
```

给 `ProjectConfigurationTests` 增加源码约束：信息卡包含 `.allowsHitTesting(false)` 和 `.focusable(false)`，且旧左上 `Text(title)` 不再存在。

- [ ] **步骤 2：运行测试并确认失败**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/FullScreenPlayerViewModelTests \
  -only-testing:VPlayerTests/ProjectConfigurationTests
```

预期：编译失败或源码约束失败。

- [ ] **步骤 3：实现应用层上下文、订阅和信息卡**

`RootView` 从当前 `PlaybackRequest.channelID` 查找频道与 `programmesByChannelID`，构造 `PlayerChannelPresentation`，但仍只把原 `PlaybackRequest` 交给播放引擎。

信息卡使用 `TimelineView(.periodic(from: .now, by: 30))`，内部消费 `ChannelProgrammePresentation.resolve`。结构固定为台标、频道名、媒体规格、当前节目时间与标题、进度条、下一节目。没有 EPG 时只显示 `暂无节目单`。卡片放入 `ZStack(alignment: .topTrailing)` 的安全边距内，并设置不可聚焦、不可点击。

- [ ] **步骤 4：运行视图模型、工程约束和 EPG 测试**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/FullScreenPlayerViewModelTests \
  -only-testing:VPlayerTests/ProjectConfigurationTests \
  -only-testing:VPlayerTests/ChannelProgrammePresentationTests \
  -only-testing:VPlayerTests/PlaybackMediaInformationPresentationTests
```

预期：全部通过。

- [ ] **步骤 5：提交任务 5**

```bash
git add Sources/VPlayerApp/AppDependencies.swift Sources/VPlayerApp/Views/RootView.swift \
  Sources/VPlayerApp/Player Tests/VPlayerTests/FullScreenPlayerViewModelTests.swift \
  Tests/VPlayerTests/ProjectConfigurationTests.swift
git commit -m "feat(player): 显示频道信息卡"
```

---

### 任务 6：统一 3 秒浮层生命周期、生成工程并完成全量验证

**文件：**
- 修改：`Sources/VPlayerApp/Player/PlayerControlsOverlay.swift`
- 修改：`Sources/VPlayerApp/Player/FullScreenPlayerView.swift`
- 修改：`Tests/VPlayerTests/FullScreenPlayerViewModelTests.swift`
- 修改：`Tests/VPlayerUITests/LongPlaybackAcceptanceTests.swift`（只增加稳定且不依赖真实网络的验收状态时）
- 修改：`VPlayer.xcodeproj/project.pbxproj`（由 XcodeGen 生成）

**接口：**
- `PlayerControlsVisibilityPolicy.idleTimeout == .seconds(3)`。
- 父级 `FullScreenPlayerView` 成为唯一自动隐藏计时器所有者。
- 信息卡和控制层使用同一个 `controlsAreVisible` 判定；失败与停止状态不显示信息卡。

- [ ] **步骤 1：扩充失败的可见性状态测试**

```swift
func testPlayerOverlayUsesOneThreeSecondSteadyPlaybackTimeout() {
    XCTAssertEqual(PlayerControlsVisibilityPolicy.idleTimeout, .seconds(3))
    XCTAssertFalse(PlayerControlsVisibilityPolicy.staysVisible(for: .playing(makeRequest())))
    XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .preparing(makeRequest())))
    XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .paused(makeRequest())))
}
```

同时通过源码约束断言 `PlayerControlsOverlay.swift` 不再包含 `hideTask`、`autoHideDelay` 或第二个 `Task.sleep`。

- [ ] **步骤 2：运行测试并确认旧 5 秒/双计时器导致失败**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176' \
  -only-testing:VPlayerTests/FullScreenPlayerViewModelTests \
  -only-testing:VPlayerTests/ProjectConfigurationTests
```

预期：3 秒断言或双计时器约束失败。

- [ ] **步骤 3：移除子视图计时器并统一父级状态**

`PlayerControlsOverlay` 只负责焦点、按钮和 `isPaused` 文案，不再保存可见性状态，也不再渲染旧左上频道标题。`FullScreenPlayerView` 在进入 `.playing`、收到遥控器移动、媒体信息从 nil 变为首个有效值时只启动一套 3 秒任务；暂停固定显示，失败和停止隐藏频道卡并交给现有状态浮层。

- [ ] **步骤 4：重新生成工程文件**

```bash
mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate --spec project.yml
git diff --check
```

检查生成差异只包含新 Swift 文件/测试的工程引用和既有 1.3 配置，不得带入主工作区的签名、Scheme 或 App Icon 改动。

- [ ] **步骤 5：运行完整测试套件**

```bash
xcodebuild test -project VPlayer.xcodeproj -scheme VPlayer \
  -destination 'platform=tvOS Simulator,id=9EC3C3B6-6E6B-447C-B47F-FC5B688F4176'
```

预期：`** TEST SUCCEEDED **`，没有测试失败。

- [ ] **步骤 6：运行格式和范围检查**

```bash
git diff --check
rg -n 'MARKETING_VERSION: "1.3"' project.yml
rg -n 'MARKETING_VERSION = 1.3;' VPlayer.xcodeproj/project.pbxproj
git status --short
```

预期：无空白错误；`project.yml` 三个目标均为 1.3；工程文件 Debug/Release 共六处为 1.3；状态只包含本计划相关文件。

- [ ] **步骤 7：提交任务 6**

```bash
git add Sources/VPlayerApp/Player Tests/VPlayerTests Tests/VPlayerUITests \
  VPlayer.xcodeproj/project.pbxproj
git commit -m "test(player): 验证频道信息浮层生命周期"
```

---

## 最终验收清单

- [ ] 右上信息卡在进入频道后立即显示频道、台标和 EPG。
- [ ] 媒体检测阶段显示 `正在检测画面规格…`，不显示技术空值。
- [ ] 第一帧、`.playing` 和完整媒体规格同时出现。
- [ ] 25 fps 隔行源走 YADIF 2× 时显示 `25 fps → 50 fps` 和 `流畅增强`。
- [ ] 普通逐行流只显示分辨率、`p` 和单一帧率。
- [ ] 没有 EPG、台标或帧率时按中文规格降级。
- [ ] 信息卡不可聚焦、不影响底部控制焦点。
- [ ] 信息卡与控制层稳定播放 3 秒后共同隐藏，遥控器可以共同唤回。
- [ ] 快速换台、重试、失败和退出不会显示旧频道媒体信息。
- [ ] `MARKETING_VERSION` 仍为 1.3。
- [ ] 全量 XCTest 通过。
