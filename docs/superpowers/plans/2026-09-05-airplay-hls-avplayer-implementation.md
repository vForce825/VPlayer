# AirPlay HLS + AVPlayer 双后端实施计划

> **面向执行代理：** 使用 `superpowers:subagent-driven-development` 按任务执行。用户最新要求（2026-09-12）：后续所有 subagent 使用 `gpt-5.6-terra`、medium 推理强度；Task22结束并复审后暂停，交接给其他人继续。旧“继续全部完成”和Task6暂停点均由本条覆盖；不在本次继续Task21剩余runtime验证或Task23以后。Task21保持未完成，接手者进入Task23前仍须处理Task21与Task22真实图的联合运行时门槛，预算与最终验收标准不变。

**当前检查点（2026-09-11）：Task1—20已完成，Task21尚有两项运行时证据未闭合，Task22开始整链接线。** Task21行为、三域分账与有界准入、最长URL安装期backing、Release原控制容器已验证；Release异步原allocation/free与URL最后物理holder仍未知。它们随Task22集中验证，不能记零或冒称框架内部allocation；进入Task23前处理联合门槛。不自动merge/push，尚无HomePod物理同步通过结论。

**历史检查点（2026-09-06，已被后续恢复指令取代）：** Task6原提交 `ab750c2fd0828d8263fff203e448739259765d33`，安全claim修复提交 `22eeb795320962596cd93a11e6e04dae42a47cc9`；修复轮1限定复审通过。同源Debug/Release六类各295/0/0，当时控制allocation预留59872/65536。独立栈仅按已批准有限范围验证，运行时SP/CFA及完整栈上界未取得；该数值不代表当前分支。既有构建警告作为Minor留待最终分支审查。

**目标：** 为全部 AirPlay 路由交付 HLS + AVPlayer 播放后端，保留 Metal YADIF2x、现有正式媒体范围及非 AirPlay 播放能力。

**架构：** 控制器统一拥有 AudioSession、路由、后端和输出授权；SampleBuffer 与 HLSAVPlayer 实现同一可确认静止／退休的后端协议。HLS 数据面复用 demux、解码和 Metal，progressive 安全码流 remux，其他视频经 VideoToolbox 编码，音频生成经过验证的 AAC／压缩 rendition，通过有界 loopback HTTP 交给 AVPlayer。

**技术栈：** Swift 6 strict concurrency、tvOS 26、AVFoundation／AVKit、VideoToolbox、Metal、现有 FFmpeg C ABI、libswresample、Network、CryptoKit、XCTest、XcodeGen 2.44.1。

**规格：** [已批准设计](../specs/2026-09-04-airplay-hls-avplayer-design.md)；原基线提交 `3c2aa7f8b4a7433b5b69ac3b42374c2b44a248df`、SHA-256 `8cea63cbda74853a5b5f47456384ada6796234ee3931405a8dfdba336e54ab91`。2026-09-06用户另批准第11节控制allocation与编译器瞬时栈分开验证的澄清，以当前设计该段及Task6续行裁决为准，不把原SHA称为修改后整篇SHA。设计是约束的权威；以下接口是实施分解，未重复的字段、容量、失败边和验收矩阵仍由对应设计节约束。

## 全局约束

- 只要当前输出端口集合包含 AirPlay，整条播放链就使用本机实时 HLS + `AVPlayer` 后端。
- HDMI、蓝牙和其他本地输出继续使用现有 SampleBuffer 后端，不创建编码器、HLS writer、资源服务或 `AVPlayer`。
- 隔行 H.264 在 AirPlay 后端中仍然经过现有 Metal YADIF2x；YADIF 输出的逐行帧随后交给 VideoToolbox 硬件编码，再由 `AVPlayer` 播放。
- AirPlay 后端不依据 `AVAudioSession.outputLatency` 单独平移视频 PTS。音频和视频共享同一媒体时间线，由 `AVPlayer`、tvOS 和 AirPlay 2 负责最终输出同步。
- 功能一次性交付当前播放器正式支持的完整媒体范围，不按 1080p、4K、HDR 或音频 codec 分阶段上线。
- 配置按固定 `.playback/.moviePlayback`、优先 `.longFormAudio`、该调用真实失败才 `.default` 的计划执行；AirPlay 后端仅接纳真实 long-form receipt。
- tvOS 最低版本 `26.0`；Swift `6.0`，`SWIFT_STRICT_CONCURRENCY=complete`，Swift/C warnings-as-errors。
- 控制层64KiB按第11节实际allocation归属计费，内联字段/共享backing只计一次；编译器瞬时栈另做同tvOS目标Debug/Release验证，队列捕获、Array/COW、应用box/wrapper/raw暂存不免计。此2026-09-06用户授权优先于各任务相冲突的旧临时值计费文字，所有cap/槽/端点及资源安全合同不变。
- 文档与新增说明文字使用中文；源文件沿用现有三行 SPDX 头；不新增未审计 FFmpeg 组件或外部播放依赖。
- 所有实现和生成工程文件只在 `/Users/daniel/git/VPlayer/.worktrees/airplay-hls-avplayer` 进行；每个实现任务串行派给新 subagent。
- 主工作区的三个既有修改不属于本计划；不 merge、不 push、不覆盖源流数据。真机部署使用已授权的配对 Apple TV 和已登录 Team，标识只在运行时解析，不写入源码／文档／诊断。
- 本计划的任务拆分是工程依赖划分，全部任务与正式验收完成以前不得把分支称为完整交付或 HomePod 同步已修复。
- 除新组件针对性测试外，只在公共接口变更、集成节点或真实失败需要时运行完整回归；最终运行全套。模拟器结果不能代替物理音画采集。

## 文件组织与执行约定

控制状态放在 `Sources/VPlayerPlayback/Control/`，顶层适配放在 `Pipeline/`，HLS 格式／writer／发布／HTTP／player 放在 `HLS/` 的独立职责文件。现有 codec、Metal、解码文件优先复用。测试镜像放在 `Tests/VPlayerTests/Playback/Control/`、`Playback/HLS/`，共用测试设施只放 `PlaybackSupport/`。物理采集验证器放 `Tools/PhysicalSync/`，不进入播放进程。每个任务列出的新文件必须由 XcodeGen 注册，不手改生成工程的随机 ID。

路径缩写约定：`Control/`、`Pipeline/`、`HLS/`、`Audio/`、`Video/`、`Demux/`、`Deinterlace/`、`Rendering/`、`Sync/`、`FFmpeg/`、`include/` 均相对 `Sources/VPlayerPlayback/`；`Playback/` 与 `PlaybackSupport/` 均相对 `Tests/VPlayerTests/`。已有文件的裸文件名须以 `rg --files` 在当前 worktree 解析后编辑；应用文件归 `Sources/VPlayerApp/`，不得在播放库内新建同名副本。每个示例中的具名 harness、fixture builder、measurement 均由该任务的测试支持实现，不是预先存在的 API；断言必须观察真实生产逻辑，不能以固定返回值满足示例。底层接口任务可以保持未接线，但完整功能及最终安全门槛不得因此省略。

通用命令（在上述 worktree 执行）：

```bash
Scripts/bootstrap.sh --generate
xcodebuild test -quiet -project VPlayer.xcodeproj -scheme VPlayer -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.2' -derivedDataPath /tmp/VPlayer-airplay-hls-implementation -only-testing:VPlayerTests/PlaybackIdentityAllocatorTests CODE_SIGNING_ALLOWED=NO
Scripts/bootstrap.sh --check
Scripts/verify-licenses.sh
git diff --check
```

每个任务在下列步骤里把 `-only-testing:` 换成其明确指定的测试类。记录实际 RED、GREEN、命令退出码、测试数和 xcresult 路径；首次新增类型造成的编译失败只能证明接口缺失，必须在最小可编译实现后继续用行为断言证明边界失败，再完成 GREEN。不得用源文本 grep、仅断言常量或 mock 存在作为测试。

`.superpowers/sdd/` 内简报、报告、ledger和review package是本计划忽略的工作记录，保留本地供复审，绝不 `git add -f` 纳入提交；仅规格、实施计划和最终验收文档按明确路径强制加入被忽略的 `docs/`。所有提交精确暂存任务文件，报告中的完整命令不能以省略号代替，计数必须读取实际xcresult。

## 任务依赖和规格覆盖

| 任务 | 交付 | 依赖 | 设计节 |
|---|---|---|---|
| 1 | checked 身份分配 | 无 | 5.1、12、13.1 |
| 2 | 完整路由值与后端选择 | 1 | 1、6.2 |
| 3 | 同步安全入口与控制执行器 | 1、2 | 5.1、5.2、6 |
| 4 | 有界命令及唯一清理所有权 | 1、3 | 5.1、5.2、11 |
| 5 | 有效时间预算与 deadline | 1、3、4 | 5、8、10 |
| 6 | AudioSession 固定配置与 receipt | 1—5 | 6.1 |
| 7 | 进程系统事件与 session 路由服务 | 2、3、5、6 | 6.2 |
| 8 | Backend 协议与 SampleBuffer 适配 | 1、3、4 | 5.2 |
| 9 | 控制器冷启动／暂停／接管 | 5、6、7、8 | 5.1、8 |
| 10 | 带身份 presentation 与 UI 挂载 | 8、9 | 5.3 |
| 11 | 共同媒体起点和 generation | 1、8 | 7.1、9 |
| 12 | progressive H.264／HEVC 准入 | 11 | 7.2 |
| 13 | Metal 输出与 VT 实时编码 | 11、12 | 7.3 |
| 14 | 音频输入域、服务 proof 与 lease | 1、11 | 7.4 |
| 15 | 重采样、布局与 AAC priming | 14 | 7.4 |
| 16 | AC-3／E-AC-3 压缩 AU | 14 | 7.4 |
| 17 | 分离 fMP4 writer 和 segment report | 11、13、15、16 | 7.5 |
| 18 | 最终 fMP4 格式与时序验证 | 12、13、15、16、17 | 7.2—7.5 |
| 19 | 有界 store、playlist、发布屏障 | 17、18 | 7.5、11 |
| 20 | loopback HTTP 与完成体证据 | 19 | 7.6 |
| 21 | AVPlayer item、preroll、静止 | 4、8、10、20 | 5.2、7.5 |
| 22 | HLS 音视频管线接线 | 11—21 | 7、9 |
| 23 | audio-only 串行候选选择 | 14—22 | 7.4、7.5 |
| 24 | 全路由 handoff 与系统恢复 | 6—10、22、23 | 6、8—10 |
| 25 | 分型诊断、watchdog、内存账本 | 19—24 | 10—12 |
| 26 | 全编码域 fixture 与系统回环 | 12—25 | 13.1 |
| 27 | 真机启动／热切换／长播验收 | 24—26 | 13.2 |
| 28 | 物理同步分析与隐私证据验证器 | 26 | 13.3 |
| 29 | 全分支集成、回归与发布结论 | 1—28 | 14 |

---

### Task 1: checked 身份分配器与进程耗尽终态

**文件：** 新建 `Sources/VPlayerPlayback/Control/PlaybackIdentityAllocator.swift`、`Tests/VPlayerTests/Playback/Control/PlaybackIdentityAllocatorTests.swift`；生成修改 `VPlayer.xcodeproj/project.pbxproj`。

**接口：** 无前置依赖；输出以下内部接口。此任务不迁移旧管线的计数器；任务 3—9 和各 HLS 任务在接线时逐项迁移它们。

```swift
enum PlaybackIdentityNamespace: Int, CaseIterable, Sendable {
    case session, backend, outputLifecycle, prepare, activation
    case admissionFence, routeCommit, presentation, outputItem, mediaEpoch
    case resource, controlTask, lease, deadline, sequence, subscription, nonce
}
enum PlaybackIdentityAllocationError: Error, Equatable {
    case identitySpaceExhausted
}
final class PlaybackIdentityAllocator: @unchecked Sendable {
    static let shared: PlaybackIdentityAllocator
    init(initialIssuedValue: UInt64 = 0)
    func next(in namespace: PlaybackIdentityNamespace) throws -> UInt64
    var isExhausted: Bool { get }
}
```

所有计数槽固定为 `allCases.count`，由一把锁保护；每个 namespace 独立单调，但任意槽耗尽使整个实例 sticky 耗尽。生产使用进程 `shared`；测试注入独立实例且不得改变 shared。后续新增命名空间必须显式登记到 enum；不得动态字典扩容、wrap、saturate、reset 或复用 0。

- [ ] 写失败测试，运行测试类 `PlaybackIdentityAllocatorTests`。下面测试捕捉“最大值回绕”与“仅单槽耗尽”的实际错误；另加从 1 开始、命名空间独立及 8 个并发调用者合计 1000 次签发无重复的测试。并发结果使用测试内锁保护，期望集合手工为 `1...1000`，不调用生产分配器计算期望。

```swift
func testExhaustionRejectsEveryNamespaceWithoutReusingAnIdentity() throws {
    let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
    XCTAssertEqual(try allocator.next(in: .session), UInt64.max)
    XCTAssertThrowsError(try allocator.next(in: .session)) {
        XCTAssertEqual($0 as? PlaybackIdentityAllocationError, .identitySpaceExhausted)
    }
    XCTAssertTrue(allocator.isExhausted)
    XCTAssertThrowsError(try allocator.next(in: .backend))
    XCTAssertThrowsError(try allocator.next(in: .session))
}
```

- [ ] 记录 RED：新增声明缺失先记录编译结果，再在可编译版本中暂用普通递增／仅局部耗尽，观察上述行为测试失败，随后删除该临时错误实现。
- [ ] 实现固定数组、锁与 checked 递增。临界区的完整算法如下；实现不能调用外部副作用：

```swift
lock.lock()
defer { lock.unlock() }
guard !exhausted else { throw PlaybackIdentityAllocationError.identitySpaceExhausted }
let index = namespace.rawValue
let (next, overflow) = issued[index].addingReportingOverflow(1)
guard !overflow else {
    exhausted = true
    throw PlaybackIdentityAllocationError.identitySpaceExhausted
}
issued[index] = next
return next
```

- [ ] 运行该测试类、现有 `MediaGenerationTests`、`Scripts/bootstrap.sh --check`、许可证和 diff 检查。生成工程时同时修复已确认的原有 project.yml／pbxproj 不同步，检查差异只为生成条目而无签名／部署配置变化。完整单元集在任务 9 的公共控制层集成后运行。
- [ ] 提交精确文件，提交信息 `feat(playback): 添加受检身份分配与耗尽终态`；报告包含 RED/GREEN、生成差异和提交。


### Task 2: 完整路由快照与后端选择

**文件：** 新建 `Control/PlaybackRouteIdentity.swift`、`Pipeline/PlaybackBackendSelection.swift`；修改 `Audio/AudioRendering.swift`、`Audio/AudioOutputRouteMonitor.swift`；测试 `Playback/Control/PlaybackBackendSelectionTests.swift`、现有 `Playback/AudioRenderPipelineTests.swift`。

**接口与依赖：** 任务 1；消费 `PlaybackIdentityAllocator`；输出 `PlaybackBackendKind(sampleBuffer,hlsAVPlayer)`、`PlaybackRoutePorts: OptionSet`、`PlaybackRouteSemanticIdentity`、`PlaybackBackendSelection.select(ports:actualPolicy:) throws -> PlaybackBackendKind?`。`PlaybackRoutePorts` 包含 hdmi、airPlay、bluetooth、builtIn、other；空集合表示 none。`PlaybackSessionAudioPolicy` 为 longFormAudio/default。

**规格合同：** 按设计 6.2 保存完整去标识化端口集合、backend kind、OutputConfigurationIncarnation 与仅在 session 内有效的 EndpointTopologyToken；后两者为不透明身份值，原始 UID、名称和 token 均不得进入日志或持久化。新权威路由采样只读取 currentRoute，不读取或拼接 outputLatency/ioBufferDuration/sampleRate/outputNumberOfChannels，输出格式变化通过显式 incarnation 表达。任务 7 接通新权威采样；本任务只扩展旧 monitor 的完整端口投影，旧本地路径已有 latency 字段暂留兼容但不能进入新 semantic identity。AirPlay 优先于所有其他端口，none 返回 nil，default policy 下 AirPlay 抛 airPlayLongFormUnavailable。旧 AudioOutputRouteSnapshot 保留兼容初始化器；其 `ports: PlaybackRoutePorts?` 用 nil 显式表示旧接口未提供完整集合，不能用已知空集合冒充未知。真实 monitor 通过新初始化器填入完整非可选集合（空集合确切表示无端口）；选择函数仍只接收非可选完整集合，不能从 category 反推混合端口。

- [ ] 先在 `PlaybackBackendSelectionTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let route: PlaybackRoutePorts = [.hdmi, .airPlay]
XCTAssertEqual(try PlaybackBackendSelection.select(ports: route, actualPolicy: .longFormAudio), .hlsAVPlayer)
XCTAssertThrowsError(try PlaybackBackendSelection.select(ports: route, actualPolicy: .default))
XCTAssertEqual(try PlaybackBackendSelection.select(ports: [.hdmi], actualPolicy: .default), .sampleBuffer)
XCTAssertNil(try PlaybackBackendSelection.select(ports: [], actualPolicy: .longFormAudio))
```

- [ ] 运行 `-only-testing:VPlayerTests/PlaybackBackendSelectionTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [ ] 实现：选择函数先 guard 非空，再判断 contains(.airPlay)，校验 longFormAudio；其余返回 sampleBuffer。为全部端口幂集、排列／重复、同名不同 endpoint、未知端口写行为矩阵；现有 monitor 的 HDMI 优先分支改为 AirPlay 优先且保留完整集合。
- [ ] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [ ] 精确暂存列出的文件并提交：`feat(playback): 按完整音频路由选择播放后端`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 3: 同步安全入口与串行控制执行器

**文件：** 新建 `Control/PlaybackControlExecutor.swift`、`Control/SynchronousSafetyIngressCell.swift`、`Control/PlaybackSafetySnapshot.swift`、`Control/PlaybackOutputIdentity.swift`；测试 `Playback/Control/SynchronousSafetyIngressTests.swift`。

**接口与依赖：** 任务 1、2；复用任务 2 的路由值对象，不定义重复端口／拓扑模型；输出设计 5.1/5.2 的 `PlaybackControlExecutor`、`SynchronousSafetyIngressCell`、`PendingSystemSafetyIngress`、`withSafetyIngressBarrier`，以及无后端对象依赖的 session/backend/lifecycle/prepare/activation 身份值；完整字段照设计定义。测试设施 `SafetyIngressTestHarness` 在本任务测试文件内定义，真实持有 cell/executor，仅阻塞外部调度。

**规格合同：** callback 首动作在固定锁临界区 checked depth/revision，撤许可并关闭 gate；固定 system/route fold，保留首 reset instant 和最新 root。无 Task/事件数组/逃逸闭包 mailbox。pending 时所有资源 CAS 必须消费 snapshot 返回 retry；同锁无 consume/CAS 空窗。API 调用、对象释放均出锁。

新增控制身份按独立语义登记 allocator namespace：`safetyIngress`、`systemEvent`、`mediaServices`、`interruption`、`resetRoot`、`freezeGeneration`、`intent`；不借用数据面的 `mediaEpoch`、deadline ticket 或泛化resource来掩盖这些新身份。普通callbackDepth是可增减的在途计数而非身份，仍以checked整数处理。已有namespace不重命名，新增case追加；测试列出新身份到domain的完整映射并验证各自耗尽行为。后续任务只消费这里已定义的身份，不重复创建第二套。

时钟折叠还必须覆盖“已有pre-route parent、当前未消费窗口只有began→ended而没有reset”。因此pending system值同时保留固定大小的首system事件起点／中断有效时间fold，以及首未消费reset起点的fold（共用同一个纯值fold算法，不复制逻辑）。已有parent先结算至system-window起点，再应用其中有效增量；首次派生reset票则只用first-reset fold。不得仅在reset出现时初始化所有计时，也不得为解决它保存事件数组。两份fold都计入固定state尺寸测试与后续容量账本。

- [ ] 先在 `SynchronousSafetyIngressTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = SafetyIngressTestHarness()
harness.holdExecutor()
harness.routeCallback()
XCTAssertFalse(harness.attemptPositiveRateClaim())
XCTAssertEqual(harness.scheduledDrainCount, 1)
for _ in 0..<1000 { harness.routeCallback() }
XCTAssertEqual(harness.scheduledDrainCount, 1)
harness.releaseExecutor()
XCTAssertFalse(harness.snapshot.outputPermitPresent)
```

- [ ] 运行 `-only-testing:VPlayerTests/SynchronousSafetyIngressTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [ ] 实现：用固定值状态和 NSLock/OSAllocatedUnfairLock 实现 cell；执行器复用现有 PlaybackSerialExecutor 的队列模式。明确区分安全 shadow 与 executor 资源状态。为两个线性化次序、reset/interruption fold、callback depth 溢出、连续 reset 首锚不变逐条写确定性测试。
- [ ] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [ ] 精确暂存列出的文件并提交：`feat(playback): 建立同步撤权与控制执行器`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 4: 有界命令注册与清理所有权

**文件：** 新建 `Control/OwnedControlCommand.swift`、`Control/ControlTaskRegistry.swift`、`Control/OutputResourceContext.swift`、`Control/OutputCleanupCoordinator.swift`；测试 `Playback/Control/ControlTaskRegistryTests.swift`、`OutputCleanupCoordinatorTests.swift`。为消除编译依赖环，提前在后续任务的既定文件 `Control/PlaybackOperationDeadline.swift`、`Control/ResetPreRouteDeadline.swift`、`Control/AudioSessionReactivationBudget.swift`、`Audio/AudioSessionReceipts.swift`、`Audio/AudioSessionConfigurationPlan.swift` 定义本任务实际需要的完整纯值schema，另用 `Control/AudioSessionControlIdentity.swift` 集中定义root/incarnation/drain proof和AudioSession调用／激活purpose等固定控制身份。确需追加的allocator域及映射测试也在本任务完成。

**接口与依赖：** 任务 1、3；消费任务 3 的输出身份值；输出设计的 `OwnedPostIngressControlCommand`、`ControlTaskRegistry`、`PendingOutputBarrier` 六态、Installed/Q context、单飞 suspend/retire/teardown tickets。资源强引用通过内部 `OwnedPlaybackResource: AnyObject, Sendable` 标记协议持有，任务 8 的后端协议继承此协议；本任务不依赖尚未存在的后端操作，操作在 runner 侧显式传入。`ControlCommandTestHarness` 使用真实 registry，SDK 调用用可控外部 spy。

**规格合同：** 固定槽 queued/running/terminal，claim-start 复验 gatePolicy；safetyBypass 永不等路由 gate。对象强引用由 task/context 成对转移；release-wins 单向合并，低优先 owner 返回无效。stop 的 nonce 与潜在出声 interval 关闭单赋值。停止/退休/lease release 依设计顺序，超时继续 join 原 task。

提前的schema必须保持设计完整字段和封闭变体，包含真实身份匹配关系，不能用裸整数、空类型、伪proof或旧lease generation代替。预算的checked身份／绝对边界与context携带关系、三类AudioSession phase-scoped policy的claim验证、activation terminal outcome和deactivation disposition对清理流程的影响属于本任务；有效时钟、suffix、arm与timer行为仍由Task5实现，真实SDK配置／激活／receipt签发流程及blocking lane仍由Task6实现。Task4用注入的超时信号和最底层SDK spy验证真实registry与清理状态机，不把spy成功称为系统配置证明。Task5/6补全这些已有文件，不重建第二套类型。若提前类型继续要求计划外资源行为，报告最小额外依赖再裁决，不扩写后续完整实现。

- [ ] 先在 `ControlTaskRegistryTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = ControlCommandTestHarness()
let command = try harness.enqueueActivation()
harness.ingressRouteChange()
XCTAssertFalse(harness.claimStart(command))
XCTAssertEqual(harness.positiveRateCallCount, 0)
let stop = try harness.beginSuspend()
XCTAssertEqual(try harness.beginSuspend(), stop)
XCTAssertEqual(harness.stopCallCount, 1)
```

- [ ] 运行 `-only-testing:VPlayerTests/ControlTaskRegistryTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [ ] 实现：状态枚举表达允许边；只有锁内 claim 改状态，runner 出锁调用。清理使用现有资源登记而非复制 lease 向量。测试所有 pending 形态的成功/取消/迟到结果和单次 disposition；未停止旧对象时 factory 副作用始终零。
- [ ] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [ ] 精确暂存列出的文件并提交：`feat(playback): 添加有界命令与唯一清理所有权`；提交后写 subagent 报告，等待根代理规格／质量复核。

#### Task 4a: 普通有界registry与group登记

**范围与文件：** 这是Task4内部第一个串行检查点，不是独立功能交付。只实现 `Control/OwnedControlCommand.swift`、`Control/ControlTaskRegistry.swift` 及 `Playback/Control/ControlTaskRegistryTests.swift`；必要的基本task/group/resource/owner身份放在上述值类型文件，allocator域与映射测试、生成工程按需修改。Task4b的AudioSession证明与Task4c的六态资源图不在本检查点提前实现。

**合同：** 使用真实Task3 executor/cell及非空authority接收者；完整接收安全snapshot，禁止锁内再次读取cell。实现四类普通gatePolicy、queued/running/terminal、running cancel-requested、每资源单slot、固定普通16槽／安全最多16槽且soft8、池隔离及副作用前背压。queued activation在route关闭时取消；speculative-rate-zero仅route-pending时park，system/semantic失配取消；safetyBypass可在closed gate claim；routeNeutral不因route-only pending停住。其acquire reservation已queued/running时的interruption也只折叠、不得取消，media-services reset仍取消（设计113、154行）；不能把data-plane完整epoch/fence快照规则套给无输出reservation。ticket/group/resource/owner必须准确绑定，group可封口并join准确子记录，取消queued直接terminal，running保留到真实completion，禁止group等待自身。完整资源形态与phase-scoped证明检查由后续两个检查点补入同一registry。

**验证与交接：** 先可编译行为RED，再以真实registry验证上述边界和callback先于runner claim；SDK spy只数真正claim后的调用。测试容量耗尽、重复/迟到claim或completion、group seal及slot不提前复用。记录实际命令与xcresult、实测固定record/group容量；工程/许可证/diff检查后精确提交，报告 `task-4a-report.md`。独立规格／质量审查通过才派新agent进入4b。Task4总体在4c审查通过以前仍未完成。

#### Task 4b: 完整共享schema与AudioSession phase policy

**范围与文件：** 消费4a，新建 `Control/PlaybackOperationDeadline.swift`、`Control/ResetPreRouteDeadline.swift`、`Control/AudioSessionReactivationBudget.swift`、`Audio/AudioSessionReceipts.swift`、`Audio/AudioSessionConfigurationPlan.swift`、`Control/AudioSessionControlIdentity.swift` 建立最小完整纯值依赖；补全 `Control/OwnedControlCommand.swift`／`Control/ControlTaskRegistry.swift` 中三类AudioSession phase-scoped policy，扩充 `Playback/Control/ControlTaskRegistryTests.swift`。复用4a身份与registry，禁止第二套slot/证明模型；确需新增allocator域时只追加并补映射测试，工程依XcodeGen生成。

**合同：** root/incarnation/drain proof、parent/reset-pre-route/reactivation票、process/configured/active receipt、configuration attempt/step、activation purpose/terminal outcome与六态deactivation disposition使用完整字段及封闭变体。逐字段检查phase、owner/context/lease、proof/plan/attempt和适用epoch/fence；route-only fence与interruption对inactive configuration的例外不能套普通data-plane全字段规则。只定义Task4清理需要的checked绝对deadline；有效时钟/suffix/arm/timer留Task5，真实SDK调用及receipt签发留Task6。无假proof／空schema／旧generation替代。

**证明边界补定：** acquisition ownership proof绑定准确acquisition ticket、session、lease、context nonce及不可复用ownership nonce；reset post-configuration proof绑定准确incarnation identity、reset drain proof identity、retained context nonce、lease、已提交generation、post-configuration stage identity及不可复用proof nonce。call identity绑定准确owned record与lease/context、media-services incarnation及该次activation purpose所需身份，不能用裸call nonce作为deactivate权威。inactive proof封闭为reservation初始失活、准确activation未调用、准确activation返回失败、无未决activation时的interruption失活四类；reservation仅由真实reservation握手且没有继承active责任时产生，不能由“存在lease”推断。active authority封闭为匹配active receipt或准确call返回成功，后者即使丧失receipt提交权仍须保留deactivate责任。

4b只建立完整schema、在唯一registry内保存已登记的当前phase值并验证匹配；登记是4c资源所有权CAS的内部接口，不是claim调用者传入expected proof即自行认证。真实drain proof只能由4c资源收敛CAS签发，真实SDK outcome与receipt由Task6接入；4b测试明确只验证登记值与命令的匹配、失效和终态映射，不声称证明真实drain。共同资源形态schema可含准确无资源、同backend的Q、准确retained-successor；但reset drain结果必须限制为设计第311行的无lease/backend/monitor或带准确lease/monitor的新retained-successor，不能包含Q，Q只用于普通interruption drain。所有身份字段必须由checked allocator取得；定义纯值不等于获得签发权限。

普通interruption proof的epoch是实际资源drain签发时的epoch；attempt的epoch则必须严格匹配当前snapshot。按设计第329行，drain先于ended时，ended推进epoch但不凭通知重签proof，仍逐字段消费owner当前登记的准确proof与session/generation/context。再次began必须失效旧proof和attempt，由新drain CAS登记新proof；不能用epoch大小关系代替身份匹配。覆盖drain先到、ended先到和下一轮began拒绝旧proof三条路径，4c负责真实资源签发/失效接线。

为使上述撤销在合并通知窗口内仍准确，本检查点另修改 `Control/PlaybackSafetySnapshot.swift`、`Control/SynchronousSafetyIngressCell.swift` 及 `Playback/Control/SynchronousSafetyIngressTests.swift`：在 `PendingSystemSafetyIngress` 保存固定的 `interruptionBeganObserved`，每次began置true，同锁apply消费后随pending复位false。它记录未消费窗口中的发生事实，不是最终interruption state，也不是事件列表。registry与4c资源owner据它撤销旧proof/attempt，不以epoch/freezeGeneration差值猜测是否发生began。确定性验证：旧状态已began时，新窗口began→ended与ended→ended可有相同最终epoch/freeze增量，但该标记必须不同；消费后下一窗口纯ended/route不能继承旧true。重跑既有安全入口/allocator/registry测试并重测shadow和总容量。

activation一次性消费必须拒绝A完成→合法B完成→旧A再次登记，而非只拒绝最近一次重放。增加opaque纯值 `AudioSessionActivationInvocationIdentity`，只由专用checked allocator域签发，序号不可外部构造；所有activate policy携带它，reactivation attempt的attemptNonce使用同一opaque类型并与policy invocation完全相等。acquisition/commit-reset的新合法激活事务安装时才签票，重放登记或claim不能自动换票。Authority仅保留同issuer、同域已消费的最高identity和准确record，后继只能推进边界，不保存历史集合；原准确record仍可提交。issuer为不复用的固定来源值，可用进程级checked issuer序列标识allocator，不能用可复用对象地址或在proof中保留allocator对象引用。相应共享schema、allocator及域映射/耗尽测试在本检查点修改，新增固定来源字段计入容量；不同issuer、旧attempt搭配新invocation及历史重放均拒绝，专用域耗尽仍全局sticky fail-closed。

**验证与交接：** TDD先证明错误phase/owner/proof/step被拒、正确inactive配置可跨允许的route/interruption变化、release/reset/真实不匹配取消。覆盖queued notInvoked与running结果的准确终态、迟到成功不能被当成已失活、同一AudioSession slot前record未terminal不得复用。测固定值/record尺寸并更新容量核对。精确提交报告 `task-4b-report.md`，独立审查通过才派新agent进入4c。

#### Task 4c: 六态资源转移与唯一清理责任链

**范围与文件：** 消费4a/4b，主要实现OutputResourceContext、OutputCleanupCoordinator、OutputCleanupCoordinatorTests；按集成需要补同一registry及其测试。交付Task4父条目和直接设计中剩余全部context/ownership/cleanup行为。

**合同：** 六态PendingOutputBarrier、Installed/Q、准确强引用成对转移、release-wins、owner优先级、单飞suspend/retire/teardown、stop nonce与潜在出声close claim单赋值。factory no-object/迟到对象、同session successor claim、route-monitor→activation outcome→必要deactivate→lease release均走同一有界owner图；任何超时保留原task并poison barrier，不提前释放或放行第二输出。自当前delivery派生的cleanup要等ACK，cleanup owner登记在父group且不等待自身。SDK调用出锁，resource强引用转移到owned runner以后才释放。

本检查点必须把4b内部phase登记入口接入真实资源CAS；reset/interruption drain proof由实际旧资源与group终态同锁签发并登记，不能复用测试构造器或由“当前无对象”反推。reset必须完成backend teardown，Q不满足reset drain；普通interruption才允许同backend的Q。证明创建、准确资源形态、lease/context/binding和预算继承必须一次转移，不允许先登记证明再补资源。

清理图接线同时修正pool归属：设计第789行明确audio-session recovery属于soft8/hard16的安全池；现有4b统一audioSession gate尚落在普通池，不符合该容量合同。4c必须让唯一audioSessionRecovery slot（configuration、commit activation、reactivation与后续deactivation顺序复用）使用安全保留容量，且不改变各自phase/epoch/veto验证。验证普通16槽耗尽时安全audio-session命令仍可登记、普通任务不能借安全池、安全池耗尽在SDK副作用前拒绝且不重复记录。此缺口必须在父Task4完成前关闭，不能用64KiB总字节未超限替代pool隔离证明。

为使checked身份耗尽后仍能清理既有资源，在可能取得lease、产生candidate、安装lifecycle或再次授予正rate以前，同一资源CAS先保证固定`CleanupReservation`已保留完整最终清理路径的票据、父cleanup owner/group、必要context转换nonce及安全容量；不足则拒绝新副作用。reservation只占同一固定registry的安全保留容量，不新增执行队列或command phase，转移资源时才在同一步把预留票安装为queued record。整个lease按原唯一audioSessionRecovery槽顺序复用configuration/activation/deactivation，不另占停用槽。handoff只转移原预留责任，不短暂归还/重复计费；普通pause和再次激活不得耗尽最后的终态清理reserve，若补齐失败就用已有reserve进入sticky终态并join原唯一链。身份空间耗尽以后不再调用allocator签发、不复用已消费票；后续事件只加入同一最高终态owner。测试既有对象在耗尽后仍实际停止/退休/释放、迟到factory落回原清理链、新acquire/factory/activation为零；完整计费且不放宽安全hard16、普通16、单record或总控制容量。

资源权威嵌入既有registry Authority，coordinator只能委托同一内部组合CAS，不从持锁commit回调再次调用public transaction。为兑现六态停用责任，在原audioSessionRecovery slot增加cleanup deactivation的准确payload和typed completion；它不是第四类activation purpose，也不创建第二lane。只有同一资源context的`.requiresDeactivate`可claim并转`.deactivationInFlight`，验证准确active/call authority、lease/context/cleanup owner和预留票；route关闭或普通终态不阻止安全停用。media reset若已把准确旧物理incarnation置`.invalidatedByMediaServicesReset`，尚未claim的停用不得再调用SDK；已经running的原record仍须等真实terminal及lane permit归还，不能提前释放lease。generic complete不能绕过准确停用结果。真实SDK和lane仍在Task6接线。

**验证与交接：** TDD覆盖所有pending形态的成功/取消/迟到结果、弱引用释放oracle、低优先owner失效、原task join、准确资源单次disposition、旧停止/退休未确认时factory调用为零。以真实registry/coordinator运行，外部spy只替代SDK；测试经过4b完整typed disposition。精确提交报告 `task-4c-report.md`，独立审查后核对父Task4合同全项才能标Task4完成并进入Task5。

本检查点进一步采用以下两个串行内部审查点；它们不是分期上线，也不删减上述合同。4c1独立审查后才派新agent实施4c2；只有两者完成且完整资源图逐项验证后，父4c与Task4才能完成。

##### Task 4c1: 预留清理容量与原子资源交接接口

**范围与文件：** 修改同一`ControlTaskRegistry.swift`、`OwnedControlCommand.swift`、必要的`AudioSessionControlIdentity.swift`/receipt schema；在既定`OutputResourceContext.swift`建立本检查点实际需要的完整预留/资源引用/转移载荷。测试`ControlTaskRegistryTests.swift`及资源转移相关`OutputCleanupCoordinatorTests.swift`。完整六态和coordinator状态机留4c2；不在此检查点自行宣称真实drain proof已签发。

**合同：** 完成4c上述安全池归属与固定`CleanupReservation`合同，仍为普通16/安全soft8-hard16的唯一registry；内部组合CAS与资源权威使用同一个executor/cell锁，不嵌套public transaction。预留身份、容量、资源引用和owner成对转移，任何失败不留下半份承诺；保留queued/running/terminal三态，不把reserved容量当已可执行命令。唯一AudioSession槽顺序复用，准确cleanup deactivation从requires转inFlight并经typed terminal进入settled，reset对queued/running的区别保持4c合同。结果产生后由原owned record强持有，只有准确单次CAS可移入资源owner或预留清理owner，最后引用释放在出锁runner；不创建第二资源权威或逃逸裸对象。

任何`.returnedSuccess` activation record在准确停用责任被同锁转入匹配资源/cleanup owner以前都不得retire，当前缺少owned context也必须保留原record并fail-closed，不能把“测试未建SDK对象”变成生产豁免。已有context的notInvoked/returnedFailure同样要移交准确inactive disposition。需要成功后retire的既有4b fixture应接真实资源入口，保留历史重放/合法新attempt/准确原record提交的所有行为断言；纯policy测试若不移交资源，则明确断言记录继续保留。禁止测试模式开关或旁路停用责任表；Task6真实调用仍须先完成资源接纳。

**验证：** TDD证明普通池满不阻断安全AudioSession、安全池不能借给普通任务、安全hard耗尽在SDK前拒绝；预留失败全有或全无、allocator耗尽后仍可消费既有固定清理票而不签发、新副作用为零；准确资源只转移一次、失效ticket不能执行commit、commit处于唯一executor、最后deinit在锁外；同槽停用准确结果和reset两侧。测包括reservation/group/引用/authority的全部固定值，维持单record2KiB与控制64KiB硬上限。此处是可组合接口测试，完整停止/退休/释放图及其全部竞态由4c2在真实coordinator中验证，不能以这些接口测试替代。

**交接：** 精确提交并写`task-4c1-report.md`，含API、完整计费、RED/GREEN、其余4c责任的明确指针；独立审查后进入4c2，父4c/4仍未完成。

##### Task 4c2: 完整资源状态机与收敛证明

**范围与文件：** 消费已审查4a/4b/4c1的同一registry/executor/资源预留接口，完成`OutputResourceContext.swift`的六态与Installed/Q、`OutputCleanupCoordinator.swift`及对应测试；按整图集成需要补既定registry，不重建第二类型或第二模型。

为完成整图仍守住固定容量，本任务允许对已有`OwnedControlCommand.swift`和`AudioSessionControlIdentity.swift`做无损表示收敛：control record的resource/owner/group从其不可变完整controlTaskTicket只读派生，不重复存储且不保留可传入不一致值的构造接口；SystemRecoveryLeaseBinding中的proof/plan/parent/pre-route ticket/inherited constraint从唯一incarnation只读派生，真正独立的receipt/state/binding仍完整保存。完整匹配字段与一次性身份不变，复核全部原构造点和受影响4a/4b/4c测试，实际重测record/state/多准备峰。readyToCommit按ordinary/inactive互斥值、reset资源binding按acquiring/retained互斥值封闭，不增加平行optional或第二权威；不改变现有ticket自身结构，不新增池/计数器或放宽cap。

最终acquisition交接依赖的必要路由纯值schema提前在本任务建立：新建既定`Control/RouteObservationState.swift`的完整open/pending固定值，准确stable commit/authority字段补在`PlaybackRouteIdentity.swift`；继续复用`ResetPreRouteDeadline.swift`已有的`RouteUnavailableDeadlineTicket`和`RouteObservationTicket`，不重定义、不另建计数器。按设计160/269/303完整匹配session、monitor、system/configuration/activation/fence/route revision及open generation；保留pending折叠字段。Task4c2只负责最终交接CAS中完整资源与必要pending/deadline/ticket/唯一sampler record的原子准备/安装，Task5补计时行为，Task7接真实通知/getter/stability，不在这里提前运行SDK。固定空间和checked溢出/容量失败边界一起验证，parent原样继承。

后继claim/rebase与Q reprepare所需的最小固定稳定候选、完整`RouteStabilityTicket`及同Authority的typed采样结果接纳、arm/commit具名CAS也在本任务建立，继续使用既有checked域。准确sampler原record、现存observation ticket、当前完整authority及已登记候选/稳定票必须逐项匹配；不得提供接受任意stable UInt64、伪造字段或test-mode的安装入口。arm与commit使用同一锁内clock校验完整120ms，旧回调、过期原route/parent窗口、ABA及旧generation/activation/fence不能提交；普通和reset分支遵守设计303—305的不同前置，reset的开gate、创建commit、retained rebase和清准确binding仍为一次CAS。此处只前移资源图所需固定值与原子准入，真实getter、endpoint映射、通知/sampler/timer执行与完整路由算法仍Task7，通用有效时间预算仍Task5。新增值及同时准备峰计入固定空间。

ordinary D也提前登记最小准确arm以满足设计339的真实继承：在PendingRouteObservation唯一ordinary deadline state保存完整D与独立checked arm nonce，完整arm ticket按需只读投影，不复制第二份D identity、不以deadlineNonce冒充arm。handoff/首次ordinary D准入同时准备并登记，重arm只经同Authority具名接口；前交接与post分支没有该state。Task5接实际timer执行。reset消费CAS就把旧D/arm移入唯一inherited constraint，旧post stage在入口结算并使旧arm失效、保存carried remaining及最早lineage；draining封闭payload携带该constraint，drain/config期间carried值dormant，后续root/retained begin只转交。D已到或remaining为0由入口当场timeout，不等drain后推导；新增值、真实继承/旧arm与重arm拒绝/准备失败峰一起验证计费。

纯process/configured/active receipt由本registry准确typed terminal事实在资源CAS内构造与签发，Task6负责实际SDK与lane驱动，不另签第二份receipt；为实际配置generation新增同一checked allocator的`audioSessionConfigurationGeneration`域，修改`PlaybackIdentityAllocator.swift`及对应耗尽测试，新增8字节counter纳入完整固定计费。有效process receipt复用不换generation，实际新配置才换发，reset使旧receipt失效；不建立独立计数器。原冻结parent必须作为真实acquisition admission的必要输入，从waiting起逐态携带，不能到configuration才补一个新parent。

通用`registerAudioSessionPhase`不得让调用方以字段自洽的phase/receipt/configurationProgress注入权威；删除或收紧该入口，真实事实只通过同Authority具名begin、准确claim-start、typed completion及settle/commit CAS产生。Task4b现有claim-once、新attempt、迟到/reset、capability/fallback正向fixture迁入真实coordinator发行链，保留原oracle，不以删测、改负例、legacy/test-mode或独立配置历史表维持通过。ordinary/post-reactivation缺少的入口仅按既有purpose/policy最小补齐，不增加SDK职责或第二发行器；错误pure phase仍可用于拒绝伪造负例。

配置generation的消耗点收紧为真实权威提交：候选process receipt只携带checked `authoritativeBase + 1` 的预期值，以唯一receipt nonce、attempt/epoch及context区分候选；不能在未交接阶段消耗generation域。普通handoff或reset commit在全部其他可失败的容量/身份准备完成后，最后消费既有generation域并要求等于准确base的后继，随即不可失败安装，保证设计321的每incarnation exactly-once；复用process receipt不消费。任何溢出或counter/base失配均按现有失败关闭合同处理，不回滚/校准counter、不另建计数器；旧候选也不能仅凭相同预期generation取得权威。验证候选被取消后reset、连续两incarnation、重放和最后提交前的准备失败不消耗generation。

**合同：** 完成父4c与Task4全部尚未交付的真实资源行为：六态逐边强引用转移、release-wins、最高owner、唯一suspend/retire/teardown、潜在出声区间单赋值close claim、准确factory no-object/迟到对象与successor claim、ACK/monitor→activation outcome→必要deactivate→lease release顺序、超时原task/permit持续join且poison barrier。使用4c1预留接口覆盖实际allocator耗尽后的整条既有资源清理，任何时刻不放行第二输出。普通interruption/reset drain proof只由准确旧资源和group terminal的同锁CAS签发并登记；reset不能Q，普通interruption可Q，重复began撤销旧proof，ended不伪造证明。预算、context/lease/monitor/binding与proof一次移交。

首个reset在进程尚无reservation/资源时允许无旧group的明确empty-drain来源分支，不人为创建无SDK工作的占位group。该来源必须由准确最新root物化/收敛CAS在完整权威账本确认无潜在生产者、无强资源/runner/lane责任后记录或消费；具名proof签发仍在同Authority并且一次性。不能事后从root/generation加当前nil反推，也不能覆盖有旧acquire或已释放资源链的原始drain责任；旧root、在途record、未退休owned结果、迟到lease及重复签发必须拒绝或返回原准确实例。新增固定来源值完整计费。

保留lease的reset分支使用具名`beginRetainedOutputResetConfiguration(owner:mandatorySuffix:)`，在同CAS依据准确旧group-drain事实签proof，将原lease/parent/唯一pre-route与新incarnation/binding、首条inactive配置record一起移交，必要的新workGroup和预留也成包准备安装。caller不传可替换的proof/parent/inherited constraint，继承约束由本Authority现存ordinary/post状态导出；原`issueOutputDrainProof(...reset)`不能单独发行retained proof，可只读已准确提交的实例。当前session的pre-route起点仍为首未消费reset入口及其clock fold，不以drain完成时刻重锚；同session新root原样移交ticket/state并只收紧边界。所有准备失败保留原清理owner/reserve，不发布半份proof/binding、不提前消费generation；无session的既有empty分支不变。

有current session的首reset消费CAS必须当场签发完整pre-route ticket/state/binding，而非只结算parent后到drain结束再签。为同步处理该CAS的checked失败，允许修改`PlaybackControlExecutor.swift`、`SynchronousSafetyIngressCell.swift`及受影响同步入口测试：applyIngress返回具名applied/failed(PlaybackSafetyFailure)，另有初始化时一次成对登记、同样捕获唯一Authority的非失败terminal hook。cell同锁调用原failClosed、一次交付失败/撤权事实、清pending并拒绝本次目标操作；terminal hook不签身份、不调用SDK、不析构、不重入、不再失败，不能变成第二普通折叠入口或无界retry。正常路径仍一次apply，既有cleanup后续可继续；完整新增固定捕获/准备值计费。

合并通知对post stage还须保留首began的真实截止时刻：PendingSystemSafetyIngress以`firstInterruptionBeganIngressInstant?`替代独立beganObserved Bool存储，原属性只读投影为非nil。首began在同锁实际采样一次，消费清空，不保事件数组；未消费began→ended→reset中，stage结算到首began或更早首reset，ended本身不恢复它。依设计275，合法恢复CAS安装新attempt时就以原stage/remaining恢复有效时钟，随后reactivation调用耗时也计入stage/parent，不等success才启动。parent/reset-pre-route仍按各自clock fold和freeze causes结算，不一律使用stage截止；覆盖事件顺序/零时刻/迟到调用，并重计shadow与完整固定容量。

首reset的保守后缀由真实acquisition admission必传`resetRecoveryMandatorySuffix`，在context逐shape保存同一个固定UInt64（增加8字节）；checked小于原parent cap，不提供0/default占位。reset acquisition沿用已有admission.mandatorySuffix保存。Task5从实际可能路径精确计算该输入，4c2纯值测试只注入明确需求；同session后续要求只能增、边界只能紧。reset binding封闭enum的draining载荷用`OutputResetDrainingBinding`携准确pre-route binding及入口已结算的唯一inherited constraint，以表达有首票但尚无drain proof的阶段，不伪造proof、不增加平行资源shape。

4c1低层owned-result接纳不得通过缺context时的便利构造产生无parent/suffix的正式资源上下文；只消费真实ordinary/reset admission已建立的准确context。既有真实owned fixture迁入正式准入链，近耗尽测试先准入再耗尽，保留原weak/迟到责任/同CAS失败原子性/预签最终清理oracle，不新增第二套admission或默认0/test-mode。若generic claim包装因此无合法生产用途可移除，原准确源claim+后继准备的不半提交语义及共用prepare→不可失败install原语仍必须由具名settle实际使用和测试。能启动资源生产的generic acquire/factory也不得在无context时先发SDK，合法来源的迟到返回始终归原record及清理链。

为使近耗尽fixture经过真实generation从0到1的配置交接，允许既有allocator构造期seed增加可选的准确已登记namespace：指定时只有该域取initialIssuedValue，其余域从0起；未指定保留原all-domain seed语义，生产默认全0。仍使用同一26域固定数组、checked next/sticky/issuer算法，不增持久字段、运行期setter或counter校准。保留原全域测试，新增单域隔离、最后max一次及跨域sticky验证；真实Q/successor在准入后耗尽目标域，不伪造权威generation。

reset binding实际移交还需要既定`ResetPreRouteRecoveryDeadlineState`及其准确arm纯值，在已有`ResetPreRouteDeadline.swift`按设计669完整前移，不新增独立`boundaryInstant?`快照来替代有效时间状态。唯一state绑定既有ticket/parent，保存mandatorySuffix、boundaryEffectiveElapsed、accumulatedEffectiveTime、runningSince、freezeGeneration与准确deadlineArm；同Authority的具名转移/更新CAS保持原parent与ticket身份，累计值不倒退、suffix不减、boundary不后移、冻结无arm，旧binding/arm无权。资源claim/commit从这份state及同一锁内clock checked重算边界，不能接受外部Bool“尚未超时”。Task5仍完成通用有效时间算法、事件驱动冻结/恢复与timer执行，复用此schema和唯一状态，不再复制一份预算；本轮只把真实图的绑定/原子准入需要落实，并计入容量和测试。

post-config也沿用唯一有效时间状态：在已有deadline文件以`PostConfigurationRouteState(budget, runningSince?, freezeGeneration)`包装现有`PostConfigurationRouteBudget`，不重复累计值或造绝对reset D。sampler/stability候选的边界改为封闭ordinary(D)或postConfiguration(准确transition/stage)引用；后者在同Authority查唯一stage及锁内clock读取剩余量，pending的ordinary deadline为nil。按设计275/317/319保留准确stage/lineage、继承ordinary绝对constraint与parent夹紧、原remaining和attempt变更规则，成功stable CAS一次完成stage/rebase/清binding；通用事件冻结恢复及timer执行仍Task5/7，不建立第二份状态或普通路由窗口。

真实ordinary/post-reactivation准入所需设计671完整`AudioSessionReactivationBudgetState(ticket, basePhase, freezeCauses, cutoffArmTicket?)`前移至已有`AudioSessionReactivationBudget.swift`。basePhase只有awaitingActivation/activatedAwaitingFirstProgress，freezeCauses是UInt8三bit；phase只保存唯一state，原budget变只读投影，不复制parent累计。arm保存完整budget identity、现有opaque AudioSessionActivationInvocationIdentity作为attempt identity、parent freeze generation、cutoff与checked arm nonce，不复制整份嵌套proof或转裸整数；当前完整proof/context仍在同Authority逐项核验。具名begin/typed completion/settle和准确arm使用锁内clock验证严格cutoff、blockers、原parent及ordinary D/post stage；route bit不阻activation。普通begin只在真实snapshot允许自动恢复时运行，不能接收resumeAuthorized Bool代替授权；若需显式resume，必须先明确准确session/owner/context/interruption epoch及本Authority真实proof约束的具名同锁用户请求，不能伪造ended(true)或公开veto setter。Task5补通用有效时间/事件/timer，Task9连接真实用户命令，复用唯一状态和身份；新增完整值及嵌套准备峰计费。

Q reprepare或同session successor开始新一轮工作以前，旧workGroup不能重新打开。用具名CAS在准确旧workGroup及其descendants sealed、terminal、相关record已退休且不存在仍依赖旧reservation完成的SDK/owned runner责任后，在原child group位置换发不可复用的新group/owner；`CleanupReservationTicket`整值随workGroup变化并由CAS返回新版，ownerGroup与reservation nonce可保持稳定，不保存initial/current双workGroup兼容别名。新group与所有需要补齐的task/转换身份先准备，再与资源context、准确phase/proof绑定及同一预算一次安装；完整旧ticket不能取得新一轮操作权，仍为2 groups与原8项安全承诺。轮换条件未满足时只join；准备失败保持原责任/预留不出现半提交，并以原最终清理票进入sticky终态。覆盖连续两轮Q reprepare/successor、旧票与旧group拒绝、失败原子性、耗尽后清理与全部固定容量。

普通可retain恢复的owner命令使用未承诺安全池，不能消耗最终reserved owner后再靠轮换补票维持终态能力。准确当前owner task可从当次reservation.ownerGroup唯一committedCleanup slot的完整record在同锁派生；在途升级terminal只join原record，已真实退休则消费最终预签owner，旧callback仍携原完整ticket，不查询current续权。advance、终态完成及预算均使用实际原任务，已消费身份不重开，最早anchor不续杯。

具名用户控制事务：Task4c2前移pause/resume最窄typed请求/result与一次登记Authority hook，`OutputUserControlRequest`携kind、完整session、准确expectedOwner?、contextNonce、interruptionEpoch、mediaServicesEpoch及resetPreRouteBinding?，不交Bool授权、可变snapshot/inout或每次callback；nil owner是准确预期而非通配，reset身份即使context未换也必须重验。先消费pending/retry并核验当前图，再同锁结算parent/pre-route/stage各原时钟，准备所有身份/command/arm，最后一次不可失败安装Cell与Authority；失败沿原terminal hook收敛，无半发布。唯一PlaybackSafetySnapshot.userPaused保存真实用户意图，freeze变化共用checked freezeGeneration域，无变化不换票；ended(true)不清pause，route bit独立解除。依设计315，合法resume早于proof或旧activation terminal时接受intent并返回typed waiting，不能因尚无proof丢弃；此时不激活，等真实registered proof和原record terminal、最新身份/预算齐备再安装唯一attempt。ready时可同CAS准备attempt；当前准确reset binding同样支持对应purpose，新reset/root/context supersession使旧请求失权。inactive普通resume仅清真实pause并保留有效active；began时可清userPause但绝不清interruption veto/bit或创建attempt。覆盖early intent、三cause任意顺序、旧request/owner/epoch、失败耗尽及旧arm；计入全部hook捕获、snapshot和嵌套prepare峰，Task9只连接此接口。

早期resume在准确旧record退出时的后继交付采用具名typed retirement/settle结果，返回该CAS实际准备安装的完整follow-up ControlTaskTicket?，不以contextNonce查current作为旧回调获取新任务的路径。Bool retire仅供正式资源图外的纯任务，图内记录范围按下段准确reservation判定。仅当原record准确terminal且mayDiscard（owned/deactivation责任已转移）时，允许私有replacingRetiredCommandIndex在本锁内预览将退休的那个槽；全部身份/command/cycle候选先准备，最后同CAS删除旧record、安装唯一attempt并返回准确新ticket，失败不提前删除且沿既有终态收敛。实际typed terminal/settle/retire接线不得依赖异步补做第二动作；后续Task5/6仅据返回登记锁外runner，新命令仍须独立claim-start，worker不连续调用SDK。最终具名签名由4c2报告给出。

typed退休范围补定：最终只保留`retireOutputControlRecord(_:) -> OutputControlRecordRetirement`这一具名入口，不保留先前audio命名的并行别名。ordinary drain proof可在原terminal records尚未退休时发行，因此最后阻塞新cycle的可能是owner/retirement/sampler而非audio slot；当前正式资源图准确reservation的owner/work/descendant原record一律由本入口执行terminal+mayDiscard核验、完整准备及同CAS退休/后继交付。Bool retire仅保留给不属于当前正式资源图的纯任务，不能旁路图内自动prepare；纯容量fixture只预留reservation不等于正式资源图。旧reservation/descendant或尚有owned/deactivation责任不得被排除index绕过；截止/stop/reset/release只收敛旧责任而不新激活。补真实最后非audio record、重放及失败保留源测试，Task5/6消费最终返回型。

具名控制同锁失败交付复用第3初始化receiver，`OutputControlRequest`最终只有user、retire、interruptionDrain、routeSample、suspend五种固定分支及对应`OutputControlApplication`，不新增第4hook；三个receiver仍只由同Cell一次持有并捕获唯一Authority。外部仅提供各分支的具名API，内部共同dispatch私有，不公开可扩展请求总线、snapshot/inout或caller closure。准备失败必须同锁failClosed、一次非失败terminal fold、保留原record并拒绝，不能利用通用transaction的Result把clockOverflow等错误推迟到下一barrier。user与新proof分支按resourceOwnership拒绝终态；retire、已取消的准确旧sample及准确旧suspend结果在已failClosed后仍允许纯清理，但不得改变输出shadow、发布新路由事实、创建attempt或签新身份。业务deadline仍走terminated而非伪造SafetyFailure。覆盖非allocator的clockOverflow、身份耗尽同CAS撤权以及随后准确旧record清理归零；重计两个closed enum的最大stride、三个hook捕获与真实嵌套峰，最终签名见报告。

proof-last交付范围补定：普通中断证明唯一由`settleOutputInterruptionDrain(owner:) -> OutputInterruptionDrainSettlement`具名入口发行，结果rejected或settled(proof,followUp:完整ControlTaskTicket?)。旧issueOutputDrainProof不能保留普通发行旁路；reset既有empty/已登记分支按原合同保留。该入口使用第3receiver的准确interruptionDrain(owner)分支。当前准确owner、真实旧group/records/无输出shape、retain disposition、普通configured generation及无新reset先核验，proof和shared reactivation全候选准备完后同CAS登记proof/context/phase/唯一attempt并返回准确后继；不能临时写Authority proof再准备回滚，不能接caller proof或授权Bool。共享helper若需本地proof候选，只能由此私有真实发行路径供给。没有intent或仍有blocker时可只settled(proof,nil)并等待；proof先、intent先、record先都不能漏准备，也不得人为禁止record先退休。失败同锁failClosed不半发布；stop/reset/release不恢复。补两顺序/重复settle/新began旧owner/准备失败与截止测试，重计proof、返回enum和全部嵌套峰，Task5/6消费本CAS后继再独立claim-start。

route cause证据来源补定：routeUnavailable加入/清除和parent时钟变更只由`completeOutputRouteSample`准确typed currentRoute结果CAS驱动，完整核验claim/ticket/双epoch/generation/active/context后按同锁clock结算。notification的observedRoute只是hint，不能直接或经routeSemantic/handoff semantic投影进入budget/factory/stability；它只撤权、关gate及折叠pending，unknown/coalesced/伪none不加清cause，firstEventObservedInstant不能用于route cause或回推none起点；只有下述准确open观察分支可用其真实首入口instant锚定ordinary D。保留仍有效的既有权威事实/原因直到准确新结果，reset/new-session按原binding/epoch规则失效；已有准确none可携route bit执行reactivation，fresh非none只清route bit，system/user各自独立。route bit只冻结parent，post stage绝不因none冻结，仍按原stage硬边界计时。不得新增Cell第二份route时钟或事件表。原notification直接冻结RED属于测试来源假设错误，记录偏差后改用真实typed getter取得目标行为RED/GREEN，覆盖两向cause变化、合并/unknown通知及stage继续计时。

普通open观察首anchor的限域补定：设计269/273要求已open、准确active receipt/generation/双epoch/fence/session/monitor仍匹配时，首个beginRouteObservation的真实锁内入口instant锚定唯一ordinary D，不能因executor drain延迟重新取得完整窗口。该分支允许复用firstRouteEventObservedInstant；它只是被准确现有authority授权的起点，不是observedRoute hint或none事实，也不允许据此加入/清除route freeze cause。尚未handoff的acquisition仍只把该字段用于诊断，并从真实handoff CAS建立D；reset pre-route/新epoch及缺active分支不得用旧首instant新造D。完整准备pending/ticket/arm/唯一sampler后同CAS安装，合并通知只保留最早D；验证延迟drain、多通知、跨began/reset及超时后的准确原责任，计入新增私有准备值的真实同时存活峰，cap不变。

route事实schema及接线最终补定：用唯一`OutputAuthoritativeRoute.unknown/none/available(完整PlaybackRouteSemanticIdentity)`替换Authority的Optional semantic，旧semantic只读投影；typed getter用`OutputRouteSampleResult.none/available`，available必须拒空ports/非法semantic，不为none伪造backend或incarnation。旧nil的SDK错误/重试职责迁入明确既有路径，不用nil兼作none/unknown，保留原D和单飞责任。第3receiver再加准确routeSample(claim,result)，闭合请求现为user/retire/interruptionDrain/routeSample/suspend五种具名分支，仍只有3 hooks且common dispatch私有。完整claim重验、同锁clock结算各原时钟、freeze/arm/command/phase全候选准备完成后一次不可失败安装Authority与Cell；只改变真实route事实对应的freeze generation与checked admission fence，不改userPaused/veto，post stage不因route冻结。旧sample只收敛原record，不改新fact/clock或重开边界。重计唯一fact enum、携完整claim/result的最大request/application及所有嵌套峰，cap不变；覆盖unknown与none、available空ports、hint不改事实、typed两向、三cause顺序/旧arm/失败与边界。

typed route事实变化与策略失败确认补定：现有OutputControlApplication.routeSampled精确携freezeGeneration、audioAdmissionFenceRevision、gateOpen三字段；唯一OutputAuthoritativeRoute整值变化时先从既有admissionFence域checked签发，再与fact/取消结果/Authority snapshot及Cell shadow同CAS安装，同值不推进，失败不半发布。已有实际process receipt为.default且最新candidate语义为AirPlay时，typed结果不打开gate，但可由该准确candidate和现有receipt投影进入120ms闭门稳定确认；不得用optional != longFormAudio把缺receipt当合法策略。D/parent更早边界仍优先；准确最新样本达到稳定后才完整准备并安装原terminal transition/清理链，然后抛既有PlaybackBackendSelectionError.airPlayLongFormUnavailable，不混作routeUnavailable或SafetyFailure。无新policy Bool/状态/计数器，非AirPlay两种实际policy不变；补A→B→A/none、同值fence不变、旧票失效、mixed AirPlay语义不一致拒绝、default闭门及最终原资源归零，新增返回字段和真实嵌套准备峰重计。

phase准备表示优化：允许RegisteredAudioSessionPhase容器所持identity/incarnation及保持原替换语义所需的parent/configurationAttempt改为可变引用值，所含完整ticket/identity内部仍不可变且不能复用。唯一Authority共享private prepare只能更新锁内局部phase候选，不得把权威phase直接inout传入可失败准备；checked身份及全部字段先准备，最后整体不可失败安装。显式写齐新phase各字段并清旧purpose-only引用，实际新增identity/policy/字段临时值计费，以移除第二份同时存活的整phase。不能为省复制新加oldPhase.parent==currentParent等门槛，旧容器可能属于上一合法cold-start/recovery阶段，新phase继续取当前已验证context parent与process.attemptLineage；当前尚无跨阶段parent入口时，将该专项接线测试交Task5/9，不为fixture造parent setter或提前完整预算任务。既有ordinary/post、新session复用、取消/失败不改Authority及全部容量回归仍要通过，最终generic phase注入接口须删除。

phase负例迁移的纯校验边界：允许把既有configurationProgress与对应process/inactive receipt的policy/preferredFailure/capability/attempt/plan一致性最小提取为RegisteredAudioSessionPhase内部只读predicate，Authority调用同一实现。三purpose正例必须走真实capability(false)及配置/claim/typed settle；原篡改负例改为基于真实发行phase副本逐字段改动、验证predicate拒绝，缺receipt或未complete也拒绝。当前snapshot epoch/generation、registered proof/binding/context等权威准入仍留同Authority，不能以predicate为充分授权，不新增setter/proposal/第二状态或保留generic注入以便测试。保留原字段一致性oracle，说明测试层级迁移；纯提取不冒称新的独立行为RED，新增临时值如有计费。

phase负例的引用一致性分层：同样允许将现有phase内incarnation/binding/receipt的必需存在及自包含session/root/parent/plan/receipt identity/purpose引用相等，最小提取为少量具名只读predicate，由生产Authority实际消费；不加入存储、test-only helper、任意matcher参数或回调。当前snapshot epoch、current generation、registered proof、真实context/资源/Q/group/时钟/permit仍由Authority验证，pure true不构成授权。只有旧setter才能篡改的内部字段，用真实phase副本验证同一predicate；合法外部ticket/policy/request仍能表达的错误身份/旧proof/旧epoch等，保留真实claim拒绝覆盖，不能一律降为pure测试。最终报告逐原oracle说明迁移层级及生产消费位置，实际临时成本计费，纯提取不虚构新行为RED。

首reset acquisition的旧删binding负例不能强制抽成pure phase谓词：该phase.incarnation合法为nil，是否需要pre-route只能由真实context.resetAcquisitionBinding判断。删除generic注册后，以真实reset admission→lease→具名配置逐关键步骤验证context/pre-route绑定非nil且phase完整相等，错误parent不安装/替换phase，正确请求成功，新root使旧claim失效且迟到结果仍归原责任。先unwrap权威binding，不能用nil==nil假通过；不得加caller expectedBinding/Bool或任意phase检查入口制造旧setter窗口。报告明确这是闭合构造与当前Authority matcher的不变量覆盖，原caller删binding输入已不存在，并给出generic API无声明/调用的静态检索和完整构建证据，不称执行了不可达nil拒绝。

暂停截止同锁交付补定：第3初始化receiver增加第五种具名`suspend(action)`，action仅准确完整ticket的timeout或完整receipt的complete，外部保持原两具名API，不增加hook、任意事务/closure或公开失败注入口。Authority据真实当前workGroup及适用descendants的原prepare/activation terminal与mayDiscard验证drain，不接受caller priorActivationDrained Bool。两种动作均在同锁重算最早1秒suspend/既有cleanup边界，receipt先于迟到timer返回也不能越过严格截止取得preserved恢复；到界先完整准备最高terminal owner及原清理预算再不可失败安装，原stop/receipt只准确join，timedOut不可撤销且不开readiness。不可表示的时钟加法是clockOverflow，走既有.failed→Cell failClosed/terminal，不能伪装成正常业务deadline或返回false后永不收敛；正常业务到期不伪造SafetyFailure。具名结果只表达本CAS接纳/终态事实，Cell同锁撤权，终态后旧结果仍能纯清理。最终准确类型与五分支最大stride、三个hook、所有真实嵌套准备峰重新计费，cap不变。Task5/8/9接线复用，不再根据caller Bool或timer先后来决定静止。

sampler单次调用合同补定：设计119/279规定每个currentRoute request、lane permit与owned sampler record严格一一对应，每次真实返回都结束原record。设计269的“同一runner”只表示同一逻辑采样器与固定slot单飞，不得把已terminal票重开或把一个running record反复用作SDK请求。none、在途样本被更新通知穿越或available后的idle新通知需要继续采样时，由唯一Authority同CAS准备新不可复用record并替换准确terminal+mayDiscard原槽、更新pending.sampler；旧source不能取得新调用权。真实in-flight取消仍join原结果，idle queued可直接取消；所有可失败的身份/record/绑定准备先完成，失败沿既有同锁terminal保留原清理责任。原D/parent/post不续杯，同semantic保留首matching anchor，只失效旧arm，semantic改变才重置120ms。无新增API/持久字段/slot/lane，新增准备与返回重叠仍必须计入完整固定峰；Task6/7/9消费最终新票接线。

**验证与交接：** 用真实registry/coordinator覆盖父4c的全部shape、成功/取消/迟到/超时/竞争矩阵与弱引用/锁外释放oracle，SDK spy不复制状态机决策；验证4c1接口在整图中实际使用，而非只保留死代码。精确提交报告`task-4c2-report.md`并逐项映射父Task4合同到代码/测试。独立审查和父合同核对均通过后才标4c及Task4完成，再进入Task5。

### Task 5: 冷启动／恢复／清理有效时间预算

固定预算请求/结果分支允许同步修改其现有声明文件 `Control/OutputResourceContext.swift`，仅修改本任务具名闭合类型和必要容量接线。

**文件：** 补全Task4已建立纯值schema的 `Control/PlaybackOperationDeadline.swift`、`Control/ResetPreRouteDeadline.swift`、`Control/AudioSessionReactivationBudget.swift`；测试 `Playback/Control/PlaybackDeadlineTests.swift`。根据Task4c2最终接口交接，可为本任务的唯一时钟适配、具名timer投递与parent阶段移交，最小修改同一 `Control/ControlTaskRegistry.swift`、`Control/PlaybackControlExecutor.swift`、`Control/SynchronousSafetyIngressCell.swift` 及其受影响测试；确需新文件时仅限 `Control/PlaybackMonotonicClock.swift`、`Control/PlaybackDeadlineScheduler.swift` 和测试 `PlaybackSupport/ManualPlaybackClock.swift`，新文件依XcodeGen生成工程引用。不得新建第二Authority或另一套预算/票据。

**接口与依赖：** 任务 1、3、4；输出设计所有 deadline ticket/state，注入 `PlaybackMonotonicClock`（`nowNanoseconds: UInt64`），测试 `ManualPlaybackClock` 仅在 PlaybackSupport。

**规格合同：** 实现设计规定的 cold-start/recovery 外层预算、1秒 suspend、5秒绝对 teardown、3秒 route unavailable、reset pre-route 同 parent 计时和 freeze-cause 规则；不重锚、不续杯，suffix admission 精确有理计算，溢出失败。deadline 到期只撤权/发布失败，原 task/permit 保留直到归零。

Task4c2已实现唯一parent/pre-route/post/reactivation状态、ordinary arm及若干具名边界入口；本任务补齐其通用算法和timer交付，直接复用最终接口，不从snapshot查询给旧callback续权，不再签process receipt、proof或sampler权威。必须以同一锁内clock重算并严格比较当前有效时间，准备失败同锁failClosed且准确旧责任仍可清理。跨cold-start首次媒体进展后进入recovery的专项接线使用当前已验证context parent，不新增旧phase parent必须相等的错误门槛。真实SDK调用/lane、通知与getter、后端媒体和controller产品接线仍各属Task6/7/8/9及后续任务；本任务的有界scheduler只调度固定具名票据，不成为第二状态机。

同锁预算交付补定：复用第3初始化receiver，在既有私有 `OutputControlRequest` 增加唯一 `.budget(PlaybackBudgetControlAction)` 固定分支，不增加hook或第二Authority。完整timer盘点后，action固定为八类：`.resetPreRouteTimer(完整arm)`、`.postConfigurationTimer(完整arm)`、`.mediaProgress(完整receipt)`、`.acquisitionTimer(AudioSessionAcquisitionDeadline)`、`.cleanupTimer(CleanupBudgetTicket)`、`.ordinaryRouteTimer(RouteUnavailableDeadlineArmTicket)`、`.reactivationTimer(AudioSessionReactivationCutoffArmTicket)`、`.playbackOperationTimer(PlaybackOperationDeadlineArmTicket)`；suspend继续既有独立分支。封闭结果仅含rejected、对应准确deadline/arm与精确remaining、progressCompleted，外层复用terminated/failed。公共仅保留原具名timer函数的映射与新增 `rearmOutputResetPreRouteDeadline`、`rearmOutputPostConfigurationRouteDeadline`、`completePlaybackMediaProgress` 及parent timer具名API，不开放总线或caller closure/Bool授权。post arm是完整transition/stage/generation/parent/attemptNonce/freezeGeneration的不可变投影；提前唤醒只重排同票，不挪用或重签activation attemptNonce，冻结/恢复/新attempt使旧票失权。parent arm引用准确parent identity/freezeGeneration并按当前唯一parent读取cap/origin/累计，提前唤醒同票重排；ordinary按既定规则换checked arm，reactivation按设计671保持同票，不混用各自重排语义。全部timer在同Cell锁内重新读取时钟、严格校验身份与边界、失败同锁failClosed；原running任务/permit与reserve仍由准确清理链持有到归零。所有返回/捕获/请求及真实嵌套峰完整计费，不以旧函数曾存在为由遗留generic transaction的异步失败双轨。

有界scheduler的准确rearm结果另携同Authority锁内checked准备的绝对 `notAfterInstant`，调度直接消费该单调时刻，不在锁外以当前时间重新加remaining而推迟截止；它只是当前准确票的调度投影，不增加第二预算或action/hook。取消/在途回调恢复必须核验完整准确票，不能按kind取消新版或以wrapping revision复用旧身份。调度器全部固定存储、引用/捕获及交付临时峰计入现有控制cap，不能因旧容量测试未覆盖它就视为免费；真实Dispatch与注入测试时钟必须保持可解释的一致时间域，不能因手动时钟原点不同制造即时无限重排。

为在原64KiB控制上限内完整容纳scheduler，可把其唯一timer source放入既有executor串行队列，并最小压缩私有 `Group` 的重复常驻身份字段：三个真实内部构造路径已保证group与owner引用同一完整resourceIdentity，内部可存一份resourceIdentity及原owner/group checked nonce，计算属性还原完整原票。公共 `ControlTaskGroupTicket`、父链接完整票、32个group容量及全部完整身份校验保持不变，不把外来不自洽票静默归一化，不以index或裸nonce替代授权。重算计算属性临时值、source/capture与同步ingress重叠的实际峰；补完整owner/resource伪造拒绝、层级join/释放及轮换后旧票拒绝，不能只减容量公式或借用独立system/route预算掩盖超额。

首次审查修复补定：同一 class-bound `PlaybackMonotonicClock` 对象负责读时钟和创建同域 timer；允许最小封闭 `PlaybackDeadlineTimer` 协议，仅提供 handler、绝对时刻 schedule、activate 和 cancel。默认实现使用 Dispatch uptime；Manual 实现只随 advance/set 越过边界或显式一次 early-wake 投递，静止的原点0/100不得重复唤醒。Registry/Executor/Cell 共用同一实例，不保留任意闭包时钟暗中配 Dispatch timer 的混域路径；限前述允许文件，真实 adapter 存储、引用/捕获与生命周期完整计费，不能仅把 existential stride 当作全部增量。

原 suspend `.timeout(完整ticket)` 分支须同时完成当前票准入与到期判定，scheduler 不得先覆盖槽再让 Authority 拒绝旧票。提前到达返回小型 `.rearmed(remainingNanoseconds, notAfterInstant)`，输入的完整票由同一同步请求准确保留，不在返回值再复制一份完整票；边界为原 suspend 与当前 cleanup 的最小值，提前唤醒重排原票，旧票拒绝不得碰新版槽。不新增第九 budget action 或第四 hook。容量须按所有 `OutputControlApplication` 分支的最大 stride 核算，而非只看 suspend 路径。

私有scheduler的调度结果同样不应再次复制完整suspend票到最大enum，可沿同次准确Delivery保留原票，仅以独立可选绝对时刻承接小rearm；所有delivery/result/小返回仍计真实重叠。budget私有decision可缩为无payload普通terminal，以及仅携确有变动的settled parent/reset state的reset terminal；在同一Cell锁内取唯一current构造最终候选，不跨CAS。容量测试按明确组成、实际分支max与总cap验证，不把“terminal峰一定大于decision峰”当作规格不变量；返回enum最大槽、局部副本及reset候选重叠不能遗漏。

budget 分支的判定局部值与 terminal/reset 准备不得未经证明就算互斥 max。允许私有判定 callee 返回封闭 decision 后，仍在同一 Cell 锁内完成 terminal 准备；逐 case 核算 decision 最大分支与外层准备真实重叠。reset 的候选与 terminal 等全部可失败准备完成后统一安装，不先更新 reset/parent 再失败；不能改为 snapshot 查 current 后另一个 CAS 给旧回调续权。原64KiB上限不变，若仍超额先给实际分解，由主控裁决最小变更。

媒体进展receipt携完整intervalKey、session/context、双epoch/fence与stable route commit，CAS复验当前installed对象/interval/lifecycle/item/activation、active receipt、route gate/permit/readiness、Cell实际pause/veto及严格parent边界；不凭activation SDK返回完成，也不要求已返回的activation command仍running。只有准确进展才能同CAS完成parent及同谱系reactivation。完成后parent可为nil；随后真实reset/open-route/已有typed用户resume及recovery transition必须在各自接纳CAS由同一私有helper建立或加入正确parent，再派生pre-route/phase，不能等第二次caller动作补预算。未完成cold/recovery始终沿用原票。新增45秒recovery按真实route/active/user/system原因立即运行或冻结，不无条件冻结后依赖虚构none→available；reset继续按pre-route特例从真实起点计时。当前没有生产登记者的format/backend/full-rebuild等trigger不提前伪造callback nonce或intent revision，其准确producer接线由Task9复用本helper完成。

- [ ] 先在 `PlaybackDeadlineTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let clock = ManualPlaybackClock(nowNanoseconds: 0)
let allocator = PlaybackIdentityAllocator()
let session = PlaybackSessionIdentity(
    sessionID: try allocator.next(in: .session), requestID: UUID()
)
let budget = try CleanupBudgetTicket(
    predecessorIdentity: .session(session), anchorInstant: clock.nowNanoseconds,
    nonce: try allocator.next(in: .deadline)
)
clock.advance(nanoseconds: 4_000_000_000)
XCTAssertEqual(budget.remainingNanoseconds(at: clock.nowNanoseconds), 1_000_000_000)
clock.advance(nanoseconds: 1_000_000_000)
XCTAssertTrue(budget.isExpired(at: clock.nowNanoseconds))
```

- [ ] 运行 `-only-testing:VPlayerTests/PlaybackDeadlineTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [ ] 实现：所有时刻以 checked UInt64 单调纳秒存储；有效时钟累加 running 窗口，暂停/中断冻结不改 anchor。按照设计 13.1 的边界矩阵写等号±1ns、owner 更替、reset storm、expired late-success 与 arm 失效测试。
- [ ] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [ ] 精确暂存列出的文件并提交：`feat(playback): 统一冷启动与恢复时间预算`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 6: AudioSession 固定配置、阻塞调用 lane 与 receipt

**状态：已完成。** 原实现ab750c2、修复22eeb79；原审查Important 1经真实owner溢出RED和同锁修复关闭，限定复审通过。最终Debug/Release各295/0/0、allocation59872/65536。普通准确截止用例首跑即GREEN，不将此前已关门的false断言冒称开→关RED；运行时栈/真实接线/物理同步限制见顶部。完成此任务后暂停，Task7不自动开始。

**文件：** 修改 `Audio/PlaybackAudioSessionOwner.swift`；新建 `Control/AudioSessionBlockingCallLane.swift`；补全Task4已有的 `Audio/AudioSessionReceipts.swift`、`Audio/AudioSessionConfigurationPlan.swift`，消费 `Control/AudioSessionControlIdentity.swift`；修改 `Tests/VPlayerTests/SystemAudioSessionConfiguratorTests.swift`，新建 `Playback/Control/AudioSessionLifecycleTests.swift`。中间迁移另允许把现有旧owner实现封装到 `Audio/LegacyPlaybackAudioSessionOwner.swift`，最小修改 `Pipeline/PlaybackController.swift` 的默认构造类型引用；仅为Task9整合前保留现有App入口，不前移完整controller。

**接口与依赖：** 任务 1—5；复用任务 2 的实际 policy 值；输出 Process/Configured/Active receipt、activation terminal outcome 和 deactivation disposition；owner 不再内联阻塞 MainActor。

本任务的“owner不再内联”准确指新 `PlaybackAudioSessionOwner` 组件：它只依赖注入的同一Registry/lane/底层SDK适配器，不提供sharedInstance、默认生产便利构造或自动全局runtime。组件测试运行真实owner→Registry→lane→typed completion/settle，只替代最底层SDK，不用伪proof/phase或test mode。新的真实SDK适配器接受显式传入的AVAudioSession并正常编译，但本阶段App不创建新owner/adapter；默认controller仍只有一个真实系统构造点，明确指向Legacy owner，旧观察者与旧SDK路径一并封装其中，不能同时安装新runtime。旧owning协议和旧owner测试明确标记仅供该中间路径，保持现有App可播放；不把legacy的两lease/同步通知oracle冒称新合同。Task9必须在同一次正式接线中删除Legacy实现/观察者/旧协议与默认构造引用，再创建唯一新runtime；不得以永久兼容层保留两套SDK所有者。本阶段不部署、不称全App已迁到lane，Task2暂留getter继续按原Task7边界迁移。

receipt纯值与一次签发已经前移至Task4c2的准确typed terminal资源CAS；本任务接每次真实SDK结果、lane permit归还及步骤驱动，让该唯一入口产生/提升receipt，不另造并行签发器或资源图。复用实际process receipt不换generation；新增配置generation沿同一checked域，生命周期验证仍须使用真实SDK适配与最底层spy。

lane同CAS接缝补定：允许最小同步 `Control/ControlTaskRegistry.swift`、`Control/OutputResourceContext.swift`、`Control/PlaybackControlExecutor.swift`、`Control/SynchronousSafetyIngressCell.swift` 及其直接受影响测试。在既有第三receiver的私有封闭request中增加唯一 `.audioSessionCall`，仅含claim/complete；Authority持唯一permit，lane只执行由准确queued record/policy在同锁claim返回的不可变单SDK请求。复用完整不可复用原票及固定operation识别请求，不允许caller提交任意phase/proof/active Bool或闭包。忙时record原位queued，真实audio/route入口不能裸claim到running再于另一把锁抢permit；不新增第四hook、第二Authority、无界等待队列或并行SDK owner。提取既有typed complete/settle/retire的私有持锁helper，不嵌套公开transaction。

真实SDK completion在同一Cell持锁区间fold通知、记录准确物理结果、terminal原record、归还permit并按仍有效权限准备/安装准确后继；后继只有queued票，离锁后仍需独立claim。route私有完成结果须区分“已结清但结果丢弃”“已接纳事实”“结清且失败”并携本CAS实际安装的replacement/followUp，不再用Bool推断是否结清，也不在回调后查current补权限。Cell仅对具名已返回completion允许在fold已failClosed后继续准确结清与原图授权清理，保持sticky failure/veto/用户暂停、不开gate/不签active/不安装普通业务后继；普通claim及其他cleanup请求无此例外。错误票不能归还别人的permit；真实returnedSuccess和原record terminal/permit结清不因后继checked准备失败回滚，迟到success仍保留准确deactivate责任。新增enum最大stride对全部user/retire等路径的影响、permit/绑定/lane/SDK引用和请求返回捕获重叠必须完整计入原cap；Task5最终接口与容量通过后才开始实施，超限先给具体分解，不以预检估计作为通过证明。

不得通过通用phase注册安装调用方构造的receipt或配置进度；消费4c2收口后的具名begin/claim-start/typed completion/settle入口。实际fallback与multichannel能力位必须来自对应SDK结果，不能通过改写一份字段自洽的phase替代调用事实；fixture同样走真实发行链。

lease reservation证明补定：旧fixture手填 `AcquisitionConfiguredLeaseOwnershipProof` 只描述此前图层的外部握手输入，不能代替本任务新owner的真实发行链。允许新增一个具名lease-registration/handshake资源入口，核验准确原acquisition ticket/context/reservation和唯一lease/lane责任，由同checked allocator现有 `.lease/.nonce` 域生成leaseID/ownershipNonce，全部准备后安装/交付，重复/错票/耗尽不多发行或留下裸资源。优先复用既有资源准入/settle持锁helper，不签process/configured/active receipt、不把无SDK的reservation伪装成lane请求、不增加hook或通用caller-proof setter。真实lease对象、monitor registration与accumulator snapshot的归属及测试底层替代边界须明确；不得凭伪monitor/proof跳过handoff，真实通知/路由monitor执行仍Task7、controller仍Task9。新增API/返回/存储与实际峰计费，超出已允许文件/资源CAS的依赖先报告。

容量接缝补定：允许 `AudioSessionCleanupDeactivationRequest` 私有消重 `call.record.group == reservation.ownerGroup` 的重复字段，保留原record nonce、完整phase/source/reservation，并计算还原完整call；内部唯一真实构造须保证等式，不归一化外来不自洽票。另允许最小修改 `Control/OwnedControlCommand.swift`：内部audio终态只存封闭notInvoked／returnedFailure固定码／returnedSuccess，公开完整outcome由该record原ticket和payload原phase identity计算还原；禁止读取当前Authority补身份。现有cancel/typed complete是准确生产写者，外来写入须完整验call，错票拒绝且不污染原值。公开票/phase/outcome、固定池/slot数量和terminal责任不变；按实际下一最大payload重测两池stride，所有call/outcome计算投影及与新lane请求/返回同时存活的峰完整计费，不把单字段缩小当成必然池收益，不改cap。

Task6→7最小producer补定：允许新增 `Audio/PlaybackAudioSessionRegistration.swift`，并最小修改 `Control/PlaybackRouteIdentity.swift`、`Control/RouteObservationState.swift`。lane单次currentRoute在内部生成固定上限ports与带真实随机session salt的不可逆endpoint fingerprint，释放原始route/UID；不读其他标量getter。设计279的lane token细化为基础端点证据，设计301带pending语义的最终incarnation由既有Authority在同一次lane completion CAS核验fresh claim后发行/沿用，复用现有checked `.nonce` 域。candidate基线/token/output-config值、pending清位、typed事实接纳、安全字段、record terminal/permit归还及准确followUp共同准备安装，不先结清后另CAS。旧样本/通知穿越只结清，不发行身份或清位；latest none不造endpoint token并失效最后非空比较基线，下一非空重新发行；output-config pending可在latest none消费并保留其当前incarnation。此为单次SDK规范化与签发接缝，不前移完整Task7服务或新增第二Authority。

registration必须真实绑定准确acquisition的有界sink、沿原CAS交接同一relay，并按callback/delivery/sampler责任关闭；可以尚无OS observer，但不是只含session/lifecycle的空marker。真实lease/proof/registration在资源图全有或全无，底层通知替代器经真实入口测试，不能手填monitor绕过handoff。Task7负责永久listener、notification/ABA解析和120ms服务，Task9才接App唯一runtime。实施者须先给固定端点数量、UID/data-source/port规范编码上限与超限明确失败政策，并计排序scratch/hasher/随机源/对象引用/所有enum与存活峰；salt必须真实随机，失败终止registration。不得无界Array/String先物化后仅按摘要字节记账，原始值及token均不进入日志/反射/持久化，不借用其他独立cap。

投影固定边界定稿：最多32个输出端点；UID非空且UTF-8不超过256字节，portType.rawValue非空且不超过64字节；selectedDataSource缺省使用显式tag，存在时dataSourceID必须可精确表示为Int64（固定8字节），不读取设备名/dataSourceName。逐字段域tag/长度前缀与32字节真实随机session salt进行流式SHA-256，每端点32字节摘要放固定32×32=1024字节scratch，定长原地排序且保留多成员重复，再生成组合摘要；单字段scratch256字节。允许Apple系统CommonCrypto/Security，须真实tvOS编译与ABI、CSPRNG失败路径核验，不加第三方。数量/编码超限、非法ID或随机失败均明确失败，不截断/不当none；此为实现容量边界，不声称Apple硬件上限。原8端点提案估算816应至少加768成1584，再叠加真实桥接引用与请求/返回等重叠；最终超cap仍须升级，不默降端点数。

同锁helper组织允许Registry内私有短生命周期 `AudioSessionLockedOperations` 值视图，仅持原Authority、同allocator引用和本CAS instant，不保存新phase/context/permit状态，不增常驻字段。原具名helper可按原语义迁入，避免公共transaction重入；视图不得逃逸到对象/record/闭包或跨await/返回授权，SDK与资源析构仍锁外。每层self/参数/返回的实际重叠均计费，不能只算一份24字节。

registration通知准入补定：既有第三receiver可增加独立封闭 `.registrationIngress(完整registration身份)`，只供Cell具名 `receiveRegisteredRoute` 在同一持锁区间验证准确handle、完整身份、当前资源归属及未closing/stopped后立即走原route fold。validated/rejected不离锁成为可复用权限，不放进SDK claim/complete，不加第四hook或caller Bool。旧回调拒绝不得修改新session的revision/pending/gate，也不得因旧身份与当前route不同而毒化新session；复用原callbackDepth及锁外wake/退出语义。close/换session前后竞争走真实入口测试，request/result及每层实参存活完整计费。

旧图层API迁移补定：不为fixture保留第二套AudioSession/route独立claim、分离complete后再settle的生产入口。非audio/sampler通用claimStart保留，audio/sampler必须走唯一组合claim；旧typed complete/settle保留为私有持锁helper供同一组合CAS复用。若具名薄包装有必要，必须完整转发同组合动作及精确结果，不分离结清或隐藏followUp。允许直接迁移 `Playback/Control/ControlTaskRegistryTests.swift`、`OutputCleanupCoordinatorTests.swift`、`PlaybackDeadlineTests.swift` 的受影响图fixture与观察点；保留旧错票/重放/过期/迟到及准确清理责任oracle，terminal-before-retire观察改由组合结果与实际资源后态证明，不删成空断言。既有图层测试可替代底层SDK事实，新owner生命周期测试仍必须运行真实owner/lane/registration。先验证代表fixture再机械迁移，不重新审查已完成任务、不引入test mode或第二状态机。

唯一SDK绑定补定：Authority一次绑定真实lane对象，相同对象可幂等，不同lane/SDK在acquire claim、随机获取或SDK调用前拒绝；owner构造/工厂明确失败，不留下可start的未绑定半对象。普通release/stop/reset不清绑定，claim与complete都核验同一绑定，错owner不能结算或归还原permit。沿现有资源/初始化入口，不加第四hook/namespace；图层SDK事实测试也使用真实绑定。当前lane仅持queue+sdk，不增加通向Registry/owner的常驻反向引用而形成永久强环；临时队列捕获按真实退出路径计费。补sameRegistry不同SDK拒绝、错binding completion保持原permit、正确绑定迟到清理及销毁边界；新增常驻引用、绑定参数及初始化重叠均纳入最终容量，不把唯一构造假设后移Task9。

真实registration的fixture迁移边界：所有会采样的Acquiring/ResetAcquiring→Stable/OutputGraph fixture经真实registerAudioSessionLease及随机salt，不允许nil-registration claim、手填semantic旁路或给生产handle加任意lifetime anchor/test hook。旧逃逸快照/析构oracle分开保留：真实采样链对真实handle使用weak，保留escaped metadata，准确release runner归属前后仍活；去除fixture自身临时强引用后在明确executor外释放runner并立即验证weak归零，backend仍可用spy验证析构线程。weak本身不测线程，lease/monitor可实际共用同handle，不硬套原三对象计数。任意lease/monitor的锁外析构spy继续在不采样的纯资源OwnedResourceFixture验证同一实际资源准入、monitor-stop/confirmedInactive释放及claimOwnedResourceReleaseRunner；外部ownership输入仅是该资源层边界，不能冒称新owner握手事实或进入新route语义。分别命名与报告覆盖，不静默删除旧断言、不增加生产测试接口。

SDK桥接有界化补定：仅现有adapter/lane/registration内允许借用公开ObjC outputs/UID/portType getter的NSArray/NSString，避免先物化Swift Array/String再反桥接；采用编译期已知无参selector和返回类型验证，不用外来selector、KVC或私有API。保留系统对象准确生命周期，先验端点count≤32及字符串UTF16 length，再以CFStringGetBytes向既有scratch按字段实际上限转换（UID256、port64、lossByte0、external=false），已转换字符数必须等于全部UTF16长度且usedBytes非空/不超限；部分转换或类型异常明确invalid，不截断/伪none，不用nil buffer无界预扫描或NSData。真实编译及ARC/Unmanaged生命周期核验，并覆盖Unicode多字节边界、超限、非法转换、集合超限/类型异常的底层适配路径。原始值仍仅lane内，所有借用引用、CF调用局部及实际ABI/并发峰计费，不把拒绝后的摘要长度当拒绝前有界证明。

后继交付补定：用具名单次typed completion接收者交付已经结清的固定结果及原request/permit身份，不新增async/continuation或caller闭包授权。接收者始发时绑定原请求，最多一个随在途请求存活的引用，不建接收者字典/队列或额外Authority状态；在Cell锁外、共享executor上同步交付，只能折叠已给结果或安排owned后继，不读current补旧票，不在锁内回调。claim启动结果区分started/parked/rejected；关闭能发起currentRoute却只返Bool吞completion的入口，真实Task7 sampler调用必须绑定接收者，ordinary audio自动链复用内部固定接收逻辑而不前移120ms。若防止入口错用需在原claim中增加封闭audio/sampler request family，只能缩窄可领类别，SDK operation仍由准确record/policy派生，不能由caller任选，不加Cell hook。迟到或已关闭的接收者仍须面对已结清原record/permit的结果，补准确followUp交付身份、销毁和重入测试；接收者引用、参数、返回及队列退出重叠完整计费。

随机源绑定消重补定：lane提供固定makeEndpointSalt能力，新owner不重复保存lane已唯一绑定的SDK existential，图fixture也只用该已绑定SDK产生随机salt。CSPRNG操作不是AudioSession lane request，不领取permit或签发权威，失败仍准确结清原acquire且不得部分注册。移除重复引用的实际节省纳入总账，但不能单凭省16字节宣称容量通过。

sticky清理准入澄清：正常cleanupOwnership prelude已ready后，具有准确原deactivationRequest及safetyBypass的queued record仍可由组合claim领取唯一permit，必须继续经既有claimStart完整验证reservation/lease/source/mediaServicesEpoch及binding；不能用incoming.failure非空一刀挡住预签合法deactivate。普通audio/sampler在sticky下仍拒绝，不修改失败/veto/gate。此不是扩大Cell prelude.rejected的例外：该分支仍只允许实际returned completion继续结清，不允许claim或其他cleanup请求穿越。

投递退出容量补定：允许最小私有单次投递对象，仅持准确原request、owner、receiver，不存Registry/快照/权限状态，不加池、等待队列或issuer。独立claim并装箱的helper必须完整返回后再enqueue，队列只捕获该对象与lane引用，公共invoke/sample不再借持完整ticket的多层start转发栈。原public参数尚未返回仍计费，不依赖编译器尾调用或最后使用优化；对象完整字段、模型内分配开销、每处引用/实参都计入。特别核验旧投递正在completion回调或退出、新后继已装箱/queued的双对象峰，permit已归还不意味着旧对象已释放；与并发user准备、SDK投影/CF调用及所有operations/outcome计算投影合账。单次交付、原身份、锁外销毁与重入合同不变；新表示须实际ABI/行为验证，仍超限须报告，不改cap、端点上限或固定池。

reactivation嵌套容量补定：允许在现有私有AudioSessionLockedOperations内，把准确原票/activation call/context/phase及原接纳前置验证、到期判定与既有timeout结清、最后settle物化按真正函数返回分阶段执行，避免settle的完整context/phase/record/receipt/relay/pending与验证helper第二context同时存活。先验证原票，再判断准确到期；不得先对current phase超时再验证迟到旧票。封闭eligible/rejected/expired分类只供本次同Cell/CAS私有调用链消费，不逃逸为权限，不加持久状态/hook/第二Authority。timeout前验证临时大值也须退出，不把原重叠简单搬入另一层helper。保留原拒绝/过期原因、timeout清理、真实物理结果结清和晚到deactivate责任，并以错票不清新版、严格截止与真实owner/late测试及完整ABI/峰值验证；不凭拆分本身宣称容量通过。

completion包裹层消重补定：同一私有单次投递范围内，唯一owner.receive可接固定result与原delivery引用，不在worker→owner→sync捕获重复携完整returned值；在executor内从原box的permit/receiver即时构造现有complete action，Registry/Cell组合API、box原字段和准确结清合同不变。result、每处box/self/receiver引用、sync捕获、request/permit等属性投影，以及延后构造returned/action的临时实值全部计费；包裹层预计节省不能当作最终净收益。不读current补票，不增状态或权限，原接收者身份/重入/关闭/迟到/销毁用例与完整三峰须同源验证。

route嵌套容量补定：Authority可增加私有只读currentRouteAuthority(context: inout OutputResourceContext)，仅beginOutputRouteSample及prepareAndCompleteRouteSample在已持准确且尚未修改context的位置借用；旧无参入口仍自身准确加载后委托。route timeout可增加同样私有inout重载，复用原beginOutputTransitionLocked(context: inout...)；旧nonce入口先准确加载校验再委托。借用不得逃逸/保存或重新复制完整context，不以未提交候选取代原Authority事实；保持旧提前返回、已提交context转换、poison及候选/证明清除次序，回返后不以旧局部覆盖新context。公开API/原票/状态不变，view/inout引用/返回全部计费，并验证route错票/严格截止/通知穿越/耗尽清理；不因去掉一个4608字节副本就宣称全峰通过。

dataSource校验叶消重：允许借原NSNumber为CFNumber，以CFNumberGetValue的sInt64Type写固定Int64，不再构造第二NSNumber比较。先验CoreFoundation类型；只有转换返回true才接纳，false虽写入best-attempt值也必须invalid。CFBoolean单独规范为精确0/1保持旧语义，其他类型invalid。实测NSNumber(UInt64.max)桥接会被CF按有符号位接纳，故先有界借公开objCType首1字节，对C/S/I/L/Q无符号编码用固定UInt64检验不大于Int64.max，超限立即invalid，再进入原CF路径；保持NSNumber强生命周期覆盖其inner pointer，不扫描/字符串化或造新对象。原NSNumber/CF引用、类型指针/标量、固定整数与CF参数全计费；保留Int64上下界、UInt64(Int64.max)与其+1/max邻接、小数/NaN/Infinity/Bool的真实adapter测试，selector/身份/隐私与编码边界不变。

acquisition启动栈补定：同一私有box优化内，startAcquisition可只dispatch(prepareAcquisition(...))；私有prepareAcquisition先完成原claim/random/register/begin及现private prepare装箱，真正返回后才enqueue，不再跨SDK持salt/registration/first票和第二层public invoke实参。原身份、绑定、no-lease失败结清与public返回合同不变，无新状态/API/池。原startAcquisition未返回的ticket/owner/receiver144字节及prepared/dispatch引用仍计费，并单独核对prepareAcquisition/注册失败阶段本身与旧box回调或退出的重叠，不能只核SDK投影期。

借用ABI证据口径补定：仅本任务具名phase验证链可用同tvOS目标、同源码/Swift6配置的-Onone canonical SIL证明实际借用，不机械对每层只读self再计完整phase，也不靠优化/内联/尾调用缩短生命。同时核caller与callee完整链，不能只见@in_guaranteed就扣除；caller/callee真实alloc_stack/copy_addr/完整物化、返回值、字段投影、access/pointer及闭包环境仍计。若大trivial aggregate的SIL不足判复制，补同目标IRGen/必要汇编，不能按SSA值数量猜存储；证据缺失维持保守全stride。原66856等准确标为旧全stride保守源值模型，不冒称已测真实栈复制或RSS，不整体改写已完成Task5基线挤容量。Authority私有matchesPurpose/matchesResetBinding/matchesConfiguredReceipt及必要调用点若需显式inout，可只借同一已验local phase，不改公开schema/字段/判定、独占/无逃逸合同，改前列具名范围。语义依据为[Swift官方SIL参数约定](https://github.com/swiftlang/swift/blob/main/docs/SIL/Types.md#function-types)，源码是否实际借用仍须本地编译证据；最终同源容量核对后才能认可扣除。

completion后继分类容量补定：仅现有applyAudioSessionCall的两个具名准备点允许私有封闭分类→真正返回→既有begin helper，避免外层完整context跨新配置/transition准备存活。准确原returned/purpose的物理结清与接纳不变；失败配置/activation的terminal transition仍在原record retirement之前，普通acquisition配置/activation及retained reset后继仍在retirement之后，不合并或移动两处时序。分类只携原资源所需contextNonce、必要parent和封闭kind，保留incoming.failure、followUp缺省、reservation非terminal、disposition/poison、资源阶段、retained用途及accepted/operation全部原条件；不得从当前补旧票或把分类离本Cell/CAS当权限。begin helper继续完整验nonce/parent/phase/期限并全准备后安装，真实returned责任不因后继失败回滚；新增分类/字段/引用及terminal和后继两分支完整计费。只改同Registry私有接缝，不扩大公开API/状态/池，不动receipt发行规则；验证fallback、multichannel、reset/retained、失败teardown及封存reservation晚到清理，仍以完整三峰与同源回归判定容量。

固定scratch分配叶补定：仅lane.project允许将withUnsafeTemporaryAllocation闭包改为显式raw allocation；同目标已实测单请求1280会占1536，最终用摘要1024与字段256两个固定块，各自同函数defer无条件释放，1024块对齐满足摘要类型。先验count/none仍在分配前，两个typed view只覆盖各自块，类型绑定/初始化及已写count边界准确，只有不可变值摘要返回、不逃逸指针或SDK对象；任何非法编码/dataSource及早退都走相同释放。不得增加池/缓存/状态/API或缩上限；本体按实际分配上界而非仅请求字节记账，所有raw pointer、视图、allocate/deallocate实参、defer环境与新增局部/返回完整计费。保留真实SDK适配/Unicode/数值异常、32端点/排序重复语义和生命周期覆盖；移除闭包层的估计节省不是完整容量结论，必须更新三峰模型。

摘要比较叶补定：仅PlaybackRouteIdentity.swift的SessionEndpointFingerprint.precedes可改为first/second/third/fourth四个UInt64字段按各自bigEndian值依序比较，首个不同字段决定结果，全部相等返回false，严格等价原32字节lexicographicallyPrecedes，不改存储/编码/哈希/身份或去重。保留固定有界排序和重复多成员语义、所有标识隐私；实际self/other参数、字段投影/端序转换/比较临时与Bool返回按新叶核算。用测试侧原字节序比较作独立oracle，覆盖全部32个字节位置、0x7f/0x80/0xff边界、相等和反向，并重跑端点顺序不敏感/重复/salt/Unicode矩阵；不得把候选65443及93余量当完整三峰上界，准备/装箱等剩余证据仍须核验。

claim前置记录作用域补定：仅既有Authority.applyAudioSessionCall.claim可将binding、准确原queued票、family、sticky清理特例、单permit忙态及原record policy的SDK operation派生提入私有封闭分类，完整返回后再进入原audio claimStart或route begin。严格保持现顺序：身份/queued/family/sticky先验，permit忙则原parked，只有permit空才派生operation并检查采样handle；不能提前因policy/handle不同把原parked变rejected。分类可含既有rejected/parked或具名operation，不携完整record、registration/context或逃逸权限，不让caller选择operation；同一Cell/CAS内后续仍完整验证原票/phase/资源/期限，领取permit与running原子安装不变。阶段间可省去原864字节record跨begin生命周期，但分类字段/参数/返回及新claim真实record仍完整计费；验证错binding/family/sticky、忙态、queued取消、重入sampler严格截止和准确返回责任，不增状态/API/队列或扩大到通用claim重写。

prepare/install转发借用证据补定：仅本任务提取的AudioSessionLockedOperations.prepareCommand、prepareReservedCleanup及installPreparedCommand三个纯转发可在同源Onone canonical完整caller/callee证据成立时，不机械增加额外PreparedCommand返回槽或整值形参副本。两个prepare必须直接转交原caller的out地址，install必须同址借原prepared；每层view/self、Authority/allocator投影、指针/其他参数仍计。caller的if-let prepared/Optional物化及Authority.install的record/Optional写入实值不能删；加载Optional已释放后的安装期与加载期取准确max，不把不同生命周期误叠加，也不整体重写Task5原基线或修改prepare/install业务逻辑。最终源码变动后刷新同源证据，若新增复制则重新计费。

permit私有存储补定：仅唯一Authority内部audioSessionPermit可将重复完整permit改为封闭recordNonce与operation；公开permit/request/returned/action、原delivery完整请求和record身份不变，不新增issuer、状态机、缓存或索引授权。同一Authority全部record准入必须来自原checked且不回绕的controlTask域或其未消费预留票；在途原record不可由通用complete、retire、release、reset、stop或替换提前终结/删除，generic complete必须像generic claim一样拒绝所有audio/deactivation payload及sampler。准确组合completion先按传入完整ticket找到仍running/cancelRequested的原record，再验证原lane绑定和紧凑nonce/operation；不能只用nonce找票、从current补旧identity或在错票后归还permit。只有原typed物理完成分支清permit，原业务接纳/迟到责任/后继签发语义不变。新增错完整group但同nonce、错operation、错binding及正确completion重放负例，拒绝后保持原record在途和单飞，最后准确原请求结清且后继只发行一次。实际Optional紧凑表示、构造/比较投影及全三峰净差须同目标ABI与同源回归验证；预计固定减少112不是实际总净收益或容量通过，不扣公开票、box或固定池。

reset activation原票作用域补定：仅Operations.settleOutputResetConfigurationActivation可把完整ticket找index、原record/identity、terminal/completed且未invalidated/transferred、原returnedSuccess call与原context.pendingActivationCall相等、call.record相等及matchesAudio完整验证提为私有只读helper。原expire→加载context/binding/inactive与非release/poison检查仍在helper之前，原可变phase/incarnation/inactive/generation/postRoute/preRoute/relay/lease与严格期限检查仍在之后。helper只借同一尚未修改的inout context、不取第二context，真正返回原(index, identity)小结果后才准备phase/receipt/command，不返回Bool再查current补票，不跨Cell/CAS或retire使用index。caller不另存一份长期identity/index；所有短时投影、helper参数/Optional返回及验证阶段真实record/call/phase链照计。generation预测、所有checked nonce、预备sampler/failureBudget/failureOwner、最后消费generation、失败先安装owner再throw以及成功receipt/责任/准确sampler安装次序一字不改。目标只结束原record864/call232跨安装存活，不改Task5基线/公开schema/资源状态；预计少1096仍非总cap，必须同源ABI/SIL与错票、严格截止、generation耗尽、迟到清理/重放和完整三峰验证。

共享安装叶补定：仅Authority.installPreparedCommand提取一个不可失败Void安装leaf，原非optional入口委托后仍返回原完整prepared.ticket；leaf借同一prepared，原record Optional非nil才把原Optional直接写commands[原index]，随后仅按原reservedStage标记consumed，不再if-let解包完整record再包Optional，nil join不写不consume。只在私有PreparedCommand增具名mutating Void转发，用于借原本地Optional payload，不修改字段；transition的preparedOwner可由let改var，两个末端安装改为原preparedSuspend与preparedOwner按既有顺序可变optional chaining到同一个leaf，不能复制安装决策。原两个Optional大值、所有准备/guard/失败/转换/finishedPause删除、context提交和terminate/seal次序不变，不提前安装或新建box/closure/池。新同源Onone完整caller→转发→共享leaf必须证明无992 unwrap/self副本、nil判别临时在直写前释放、至多一个864写Optional；原返回ticket合同不删，只有transition原忽略返回的Void路径不造120返回。所有新增地址/view/Authority引用/标量和prepare/安装/提交阶段分别计费；若lowering未消掉复制，继续按实际计费而非硬减。新增重入sample在准确deadline前/等于/后及parent优先、nil join/双安装/finishedPause替换/准备失败无部分消费的行为验证，与reset分段同源合算，不把条件候选64721当上界。受限route判断→timeout完整返回备选、整个资源getter/setter重构均未获本条授权。

audio claim截止作用域补定：仅Operations.claimStart原reactivateConfiguredGeneration截止分支允许私有三态continueClaim/rejectWithoutTimeout/timeout(contextNonce)分类。caller先确认原record为reactivate；helper按原顺序读当前phase，同Operations.instant检查reactivationAllowsWorkLocked，phase缺失或允许时继续、禁止且context缺失时原样false，否则只返回准确原context nonce，完整phase/context真正结束后才调用原nonce timeout再false。原acquire/factory、acquisition expiry和reset preRoute expiry仍在前，monitor/delivery/context/group及matchesAudio仍在后；不新增phase与record身份前验，不改成cancel、不以旧context覆盖timeout提交。分类不存储、不逃逸当前Cell/CAS、不构成权限、不重查补原record；原queued record864仍跨timeout计费。helper、enum/返回、reactivationAllows验证期的context/parent/stage及所有投影/引用/小参数分别计峰，预计结束6528重叠不作最终容量通过。保留phase nil、允许、禁止但无context原语义，补真实owner回调后准确queued activation到期不调用SDK且走原清理，并复核严格截止/parent/迟到返回及完整三峰。共享安装叶已准范围内允许给原prepared参数显式borrowing以核同址；若-Onone仍复制完整992则照计，不扩大成公开表示或权限改造。

容量计费续行裁决（2026-09-06用户已批准，覆盖前述相冲突的临时值计费与暂停要求）：64KiB约束实际持有的控制固定存储、队列/捕获、应用堆对象及固定暂存；编译器瞬时栈在同tvOS目标Debug/Release独立验证，不逐SIL值槽并入allocation账本。实施者先列allocation归属表：所有者、实例/容量上界、实测或可证明保守的分配字节、准备/队列/回调重入同时存活与实际释放点；内联字段不重复计，Array/COW backing、escaping captures/box/wrapper/raw分配及allocator取整不漏计，framework opaque与编译器栈分开说明。固定结构可按预留上界在初始化/已有admission前保证，不新建第二资源权威/队列，不提前实现后续全媒体ledger；Task6报告提供后续接全局ledger的同一分配归属。更新现有容量API/测试名称和断言以准确表达新模型；69993、65520等旧源码临时式保存到诊断证据或作为非cap指标，不能保留命名Current却与现码无关的失败式，也不能仅删assert/skip而无新的真实allocation门槛。保留32槽、32端点及全部局部/全局cap，不扩改资源getter/setter，不再为几字节临时值微调生产表示。补真实owner接收者回调后准确queued activation在原deadline−1/等于/超过及parent先到时的行为，核不进SDK、准确timeout/迟到清理和原身份，既有分开的图层/owner用例不代替该组合。独立栈验证给出编译配置、目标码/运行证据与明确覆盖/盲区，不把单帧当整链，不自定新栈cap或把仅无崩溃当完整证明；模拟器/静态证据不冒充HomePod验收。按更新后的模型完成六类同源回归、Debug/Release验证、工程/许可证/diff检查，自审后提交Task6源码并报审；此用户授权解除暂停，但不自动宣布任何门槛通过。

allocation与独立栈证据执行细则：Array backing可依据同Swift SDK frozen body/本轮目标IR给出tail offset，与公开capacity×stride及allocator取整合成可证明保守上界；不对element base调用malloc_size、猜指针减header或增加生产私有ABI接口。类对象按真实实例allocation计费，弱引用的实际side-table、escaping捕获、数组短时filter等仍列生命周期，不能用字段stride重复或漏算。独立栈采用同tvOS arm64 Simulator实际Debug(-Onone)/Release(-O)产物与四组有限路径：SDK同步重入、receiver重入/截止、reset提交成功/失败、retirement再次激活/renew/expired。记录源SHA/编译配置/目标/产物UUID，禁混旧对象或把带testability/coverage产物称纯发行码。结合完整具名函数目标码、unwind、动态metadata/输入驱动SP分类及可取得的测试侧/调试器SP-CFA观测；单帧不冒充全链、异步不同线程不拼链、内联不重复加、间接/外部及未采样点列为盲区。所跑范围无实际栈异常且动态来源/同步重入有界性风险已检查，可报告有限验证完成与盲区，不要求未获批准的全程序栈上界或新栈cap。物理TV/RSS仍在既有整合/最终验收，不新增Task6半成品部署。若需要新增测量支持，只限测试或既有Scripts职责并先列具体路径，不造生产hook、第二状态机或新fixture决策副本。

allocation封口补定：允许仅在既有lane.failure叶借编译期公开NSError.domain selector返回的NSString并准确比较固定NSOSStatusErrorDomain，避免应用侧物化未知长度Swift String；保持原osStatus/unknown分类与Int32 clamping语义，不增加缓存、生产探针或新SDK调用步骤。先保存真实owner失败路径的domain/code行为基线（已知域、未知长域及code边界），再核同源IR与实际常量桥接/Error→NSError分配，不把新增wrapper免计为opaque。executor.sync外部进入实际有32-byte环境及48-byte Block；可在同一64KiB固定reservation中保守预留34×80＝2720，分别覆盖32个owned runner、1个lane completion及1个串行用户入口。这是有界App producer接线合同与预留，不是当前已实现34并发，也不是32record池自动限制所有公开API调用者。当前具体调用来源逐项说明，Task9正式runtime必须验证producer准入/单飞及该预留覆盖；不能凭该数新增队列、限流器、第二Authority或放宽cap。receiver截止组合沿既有图合同先准确退休已结束且不再有采样/稳定责任的原source并消费真实followUp，然后移动时钟并领取预持原activation；available/stability原source不得无条件删除。

计量支持文件范围：允许最小修改`Control/PlaybackIdentityAllocator.swift`、`Control/PlaybackMonotonicClock.swift`，只在现有capacity职责旁增加私有issuer/counter/timer wrapper的只读allocation计算，供Registry唯一reservation引用；无新字段、缓存、ledger或测试专用访问口。初始化校验只针对确定的构建/ABI固定shape，不能把运行中容量耗尽或用户输入错误改为precondition。允许新增`Scripts/collect_playback_stack.rb`，只读本轮两配置产物和source manifest并生成中文目标码/unwind/UUID/SP调整证据；使用安全argv、许可证头，缺符号、工具失败或manifest失配不得空表报通过。先用已知动态setter验证提取边界，最终对冻结后的Debug/Release运行，不构建/修改生产或靠正则求和冒充全栈上界。LLDB批次仅任务scratch及模拟器测试宿主，用于读SP/CFA/运行库，不能改变用户应用或真机设置。

**规格合同：** 每 lane request 恰好一次 SDK 调用；固定 longForm→真实失败default→multichannel→activation。process receipt 跨普通 lease 保留，reset 才重建；AirPlay default 在 factory 前失败。queued cancel/notInvoked、returnedFailure/success、late success 需要 deactivate 等全部终态齐全。

- [x] 先在 `AudioSessionLifecycleTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
try await harness.acquire()
XCTAssertEqual(harness.categoryPolicies, [.longFormAudio, .default])
XCTAssertEqual(harness.actualPolicy, .default)
await harness.release()
try await harness.acquire()
XCTAssertEqual(harness.categoryPolicies.count, 2)
```

- [x] 运行 `-only-testing:VPlayerTests/AudioSessionLifecycleTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [x] 实现：测试设施替代最底层 AVAudioSession SDK 调用，真实 owner/lane/receipt 状态必须运行。用 semaphore 控制永久阻塞、重入通知和迟到 success；保证主线程和 safety ingress 继续，lane 一直单飞且未收敛前不能启动第二 lease。保留非 AirPlay default fallback 能力。
- [x] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [x] 精确暂存列出的文件并提交：`refactor(playback): 分离音频会话配置激活与清理`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 7: 进程系统监听与会话路由稳定服务

**文件：** 新建 `Audio/SystemAudioEventMonitor.swift`、`Audio/PlaybackAudioRouteService.swift`；补全Task4已提前建立纯值schema的`Control/RouteObservationState.swift`；修改 `Audio/AudioOutputRouteMonitor.swift`、`Audio/AudioRenderPipeline.swift`；测试 `Playback/Control/PlaybackAudioRouteServiceTests.swift`。

**接口与依赖：** 任务 2、3、5、6；输出设计的 system snapshot、route notification evidence、stable commit、session monitor stop receipt。测试 `RouteServiceTestHarness` 注入通知/getter/clock，真实路由服务运行。

Task4c2已提前提供必要稳定候选/票据与同Authority typed结果、arm/commit、资源claim/rebase CAS；本任务接入真实getter/stability执行并补完整路由算法，消费该唯一签发入口，不另建stable commit issuer或第二状态机。

Task6已获准前移单次getter的有界去标识化证据与同completion CAS最终route身份发行，以及真实acquisition registration/sink/handoff/close核心。本任务消费其最终接口，不重做endpoint issuer或另造monitor；永久listener、notification/ABA与output-configuration事件解析、120ms执行及真实route service生命周期仍在本任务完成。

中间App路径采用明确Legacy隔离：允许新增 `Audio/LegacyAudioOutputRouteMonitor.swift` 完整承接旧monitor、SDK provider和observer；`AudioRenderPipeline` 系统便利构造要求必填 `routeMonitor`，不保留隐式默认重载。仅在 `Pipeline/PlaybackPipeline.swift` 的现有SystemPlaybackPipelineFactory构造点显式注入Legacy，不前移Task9 runtime、不添加运行时开关。直接构造旧monitor的 `Playback/AudioRenderPipelineTests.swift` 名称/引用明确标Legacy；其他fixture仅按实际接口影响最小修改。新 `AudioOutputRouteMonitor` 作为注入新service源的无SDK本地适配器，start/stop仅附加/分离有界消费者订阅，不能创建系统observer、签route身份、关闭session registration或额外getter；准确初始投影尚未取得前保持未取得route。resample及output-configuration需准确session/backend/lifecycle/callback绑定，不借无身份reason制造恢复授权。既有snapshot的latency字段仅归旧路径，新适配器不读SDK或伪称默认标量为物理事实。Task7只完成新组件链和外部注入缝，Task8/9接线还须替换旧消费者无身份resample/自主恢复语义，不能仅喂入新snapshot便宣称完整单owner。

稳定计时接缝补定：采用controller拥有的长期PlaybackAudioRouteService内唯一固定稳定source，沿Registry.makePlaybackDeadlineTimer使用相同clock/executor；本预算scheduler＋稳定服务的组合固定两个source，不是全App所有业务timer的总数。保留既有八budget槽与action，不增owned slot或隐式队列。服务只持一个准确稳定票槽和固定handler；session registration仍逐会话创建/停止，旧stop准确收敛后才能重绑服务，不按会话重复创建未收敛source。允许ControlTaskRegistry增加无新存储的同域now只读投影，仅作早醒调度提示；早醒只重排原ticket.deadlineInstant，到期移走本次准确槽并只调用原commit CAS一次，nil/throw不能无限重排，后续重签必须来自新的合法样本。原arm签发、首semantic anchor与最终同Cell边界/身份复验不变；不能读current给旧业务回调补票，finish/cancel不能抹新票。stop清排期不替代callback depth/sampler/ACK责任，也不在handler等待自己。新source、wrapper、票/引用、固定handler/capture、queued/executing及两个源同时到期的真实重叠均计费；真正route服务新增表示按既有4KiB总账，Authority/owned或共用payload增长仍在64KiB账，不能互借或发明第三预算。允许最小修改Tests/VPlayerTests/PlaybackSupport/ManualPlaybackClock.swift为固定两个weak槽、锁外固定二元投递与每源有界合并；第三源仍拒绝，取消后已queued回调仍可迟到，原单源测试语义保留。新增route service测试须验证早醒无自旋、同semantic不续杯、旧wake不清新票、严格外层deadline、双源同时到期及停止/ACK；owned总账沿Task6最终真实模型在同测试中复用并合计新分支，不盲沿旧65520。上述是Task7范围授权，Task6 gate前不实施，完整容量未证明时必须报告，不改cap。

**规格合同：** 系统监听生命周期为进程，route monitor 为 session；先同步撤权再单飞读取新 route。初始无 callback 也 fresh sample；getter pending/none/ABA、配置 receipt 与 epoch 对齐后才 commit。路由变化不配置/停用 AudioSession；stop join callback depth、sampler 与 ACK，避免自等待。

- [x] 先在 `PlaybackAudioRouteServiceTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = RouteServiceTestHarness(initialPorts: [.airPlay])
try await harness.acquireWithoutNotification()
await harness.advanceThroughStabilityWindow()
XCTAssertEqual(harness.committedBackend, .hlsAVPlayer)
XCTAssertEqual(harness.routeGetterMaximumConcurrency, 1)
XCTAssertEqual(harness.categoryCallCount, 1)
```

- [x] 运行 `-only-testing:VPlayerTests/PlaybackAudioRouteServiceTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [x] 实现：按设计 6.2 实现固定 accumulator、单次 `currentRoute` getter 成功/失败归一化、endpoint incarnation、稳定窗口与所有 ticket 校验；将 AudioRenderPipeline 的路由输入改为外部注入，避免双 monitor。旧本地接口继续由适配提供；不读取outputLatency、ioBufferDuration、sampleRate或outputNumberOfChannels。
- [x] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [x] 精确暂存列出的文件并提交：`feat(playback): 提升路由服务并同步处理系统事件`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 8: 统一 Backend 生命周期与 SampleBuffer 适配

**文件：** 新建 `Pipeline/PlaybackBackend.swift`、`Pipeline/SampleBufferPlaybackBackend.swift`；消费 `Control/PlaybackOutputIdentity.swift`；修改 `Pipeline/PlaybackPipeline.swift`、`Sync/PlaybackReadinessGate.swift`；测试 `Playback/Control/SampleBufferBackendTests.swift`，共用 `PlaybackSupport/BackendTestHarness.swift`。

**接口与依赖：** 任务 1、3、4；消费已有 session/backend/lifecycle/prepare/activation 身份及 `OwnedPlaybackResource`，输出设计 5.2 的完整 prepare/reprepare/activate/suspend/retire/stop 协议和 receipt。后端协议继承资源标记协议，保持任务 4 → 8 的单向依赖。

**规格合同：** prepare 始终 rate0 且暂停时仍可预卷；prepared 不等于 playing。suspendPreserved 与 requiresRetirement 严格区分，renderer 停止/队列关闭/移除真实完成才确认。controller 是唯一正 rate owner；旧 pipeline 的内部 ready 自动播放必须移到 permit 接口。

- [x] 先在 `SampleBufferBackendTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = BackendTestHarness.sampleBuffer()
try await harness.prepare(initiallyPaused: true)
XCTAssertTrue(harness.isPrepared)
XCTAssertEqual(harness.clockRate, 0)
await harness.activateCurrentPermit()
XCTAssertEqual(harness.clockRate, 1)
await harness.suspendAndConfirm()
XCTAssertEqual(harness.clockRate, 0)
```

- [x] 运行 `-only-testing:VPlayerTests/SampleBufferBackendTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [x] 实现：用 adapter 复用现有数据面，不复制 PlaybackPipeline。保留旧 factory 测试注入桥接直至 Task9 完成替换；真实 renderer 停止异步依赖用现有 fake，断言的是 adapter 的事件与许可结果。
- [x] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [x] 精确暂存列出的文件并提交：`refactor(playback): 为现有管线提供可确认生命周期后端`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 9: 控制器统一冷启动、授权、暂停和接管

**文件：** 重构 `Pipeline/PlaybackController.swift`；新建 `Pipeline/PlaybackBackendFactory.swift`、`Control/PlaybackControllerState.swift`；修改 `Control/PlaybackControlExecutor.swift`、`Control/SynchronousSafetyIngressCell.swift`、`Pipeline/PlaybackSessionEventRelay.swift`、`Tests/VPlayerTests/PlaybackControllerTests.swift`；新建 `Playback/Control/BackendOwnershipTests.swift`。

**接口与依赖：** 任务 1—8；消费后端协议、route/receipt/control/deadline，产出控制器统一资源状态和 typed backend event sink。HLS factory 此时注入测试实现；生产路由开关在 Task22/24 接通真实后端。

**规格合同：** 使用 pending/installed/Q 六类资源形态取代独立 optional 所有权；新请求 admission 同时建立 deadline。factory late result 只能原 owner 清理。pause 只更新 intent，prepared 后最新许可一次激活。潜在出声区间最大重叠1；旧停止未确认禁止 successor。

Task6的中间Legacy编译/运行边界在本任务必须关闭：在同一次正式runtime接线中移除 `Audio/LegacyPlaybackAudioSessionOwner.swift`、其通知观察者、旧owning协议及默认构造引用，让唯一生产构造注入Task6真实owner/lane与同一Registry；不能先启用新runtime再留下旧observer恢复SDK。允许同步迁移直接受影响的 `SystemAudioSessionConfiguratorTests.swift`、`PlaybackSupport/PlaybackComponentFakes.swift` 与旧协议调用方。旧测试逐oracle映射到真实新链：两lease重叠、release隐式停用、通知同步恢复的旧预期按新合同改写，其余fallback/能力位/process复用/stale拒绝/用户pause/失败诊断等覆盖不得静默删除。最终全套与静态引用检查必须证明Legacy口已不存在，不能留下默认播放不可用的占位适配器。

Task7的Legacy路由边界同次关闭：删除 `Audio/LegacyAudioOutputRouteMonitor.swift`、旧SDK providers/observer/缓冲队列及SystemPlaybackPipelineFactory显式Legacy构造，让新runtime向SampleBuffer适配器提供准确route输入。删除只服务该实现的直接fixture，将有价值的投影/旧订阅隔离oracle迁到真实新链，不保留逐通知getter/latency读取oracle。结合Task8后端适配替换旧无身份resample和自主route恢复入口，保持唯一controller恢复权；无SDK的纯消费者协议可继续复用。不得让Legacy monitor与新process/session listener同时在生产路径运行。

实际allocation接线验证沿Task6最终归属表：其executor同步捕获预留按32个已准入owned runner、1个lane completion及1个串行用户入口合计34个producer，并非公开API或固定record池天然限制任意caller。接通真实runtime时逐项核对所有外部sync调用者的准入/单飞与原始、映射错误的退出重叠；额外来源及旧runtime弱引用holder的退出尾部必须按其实际生命周期进入同一既有预算，不能把取消source视为同步释放。不得为满足预留擅自增加队列、限流器或第二Authority，也不扩大cap；不成立的假设须在本任务报告并最小修正后验证，不把候选预留当已证的整App并发事实。

接通任务3的同锁安全shadow时，必须提供受准确session/owner、interruption epoch和恢复proof约束的显式resume/activation提交入口，落实设计中`ended(false) -> endedAwaitingExplicitResume -> 同session显式resume -> 准确drain proof及activation成功`的授权链。普通barrier现有output-only写权限不能自行清除interruption veto；不得以伪造`ended(true)`通知、直接公开Bool setter或只改controller旁路字段代替。新callback若先线性化，该入口必须retry或拒绝旧proof；显式resume本身不代表activation成功。Task24再以真实后端恢复验证同一入口，不另建第二条授权路径。

- [x] 先在 `BackendOwnershipTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = BackendOwnershipTestHarness()
await harness.playLocal()
harness.holdOldStopConfirmation()
await harness.requestAirPlay()
XCTAssertEqual(harness.backendCreationCount, 1)
harness.confirmOldStopAndRetirement()
await harness.drain()
XCTAssertEqual(harness.backendCreationCount, 2)
XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
```

- [x] 运行 `-only-testing:VPlayerTests/BackendOwnershipTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [x] 实现：控制器 actor 为门面，所有状态 CAS 进入共享控制执行器；异步命令由 registry runner 执行。迁移所有身份 &+=；事件 relay 改为设计容量和 control channel。覆盖设计 5、8、13.1 的冷启动/暂停/factory取消/stop/new-play/cleanup timeout 配对顺序。运行完整 VPlayerTests。
- [x] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [x] 精确暂存列出的文件并提交：`refactor(playback): 用统一所有权状态驱动播放控制`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 10: 带身份的 presentation 流与 UI 挂载

**文件：** 新建 `Rendering/PlaybackPresentation.swift`、`Rendering/PlaybackPresentationRelay.swift`、`Rendering/AVPlayerPresentationContext.swift`、`Sources/VPlayerApp/Player/AVPlayerPlayerView.swift`；修改 `FullScreenPlayerViewModel.swift`、`FullScreenPlayerView.swift`、`AppDependencies.swift`、`PlaybackContracts.swift`；测试 `Playback/Control/PresentationRelayTests.swift` 和 `FullScreenPlayerViewModelTests.swift`。

**接口与依赖：** 任务 8、9；完整采用设计 5.3 的枚举、PresentationIdentity、replacement、mount ownership 和 presentations() throws stream；AVPlayer context 包装注入 player，尚不启动播放。

**规格合同：** 单订阅，bufferingNewest(1)，A→nil→B 合并仍 detachA 后 attachB。subscription generation 与 mount nonce 阻断旧 defer；termination 单飞无裸 Task，终态 desired nil 后 finish。AVPlayerViewController 关闭系统 controls，复用现有频道 UI。

- [x] 先在 `PresentationRelayTests` 写下列行为测试，补齐本任务规格对应的边界矩阵。测试中具名 harness 在本任务测试文件或声明的 PlaybackSupport 文件实现，只替代 SDK／时钟，不复制生产决策。

```swift
let harness = PresentationRelayTestHarness()
try harness.subscribe()
harness.publishSampleBufferA()
harness.consumeLatest()
harness.publishNil()
harness.publishAVPlayerB()
harness.consumeLatest()
XCTAssertEqual(harness.mountEvents, [.attachA, .detachA, .attachB])
```

- [x] 运行 `-only-testing:VPlayerTests/PresentationRelayTests`，保存预期 RED。若首先因缺失声明而不能编译，补最小声明后继续验证真正的行为 RED。
- [x] 实现：relay 固定 current/buffer/in-flight 三个 envelope；UI MainActor 上用 ownership CAS 安装／拆卸。测试第二订阅拒绝、同 identity 新 subscription 接管、旧 termination/defer、ABA、终态、controller 不等 UI detach 即停止后端。
- [x] 运行相同针对性测试及本任务修改接口的已有测试；新增文件后执行工程生成与检查，检查许可证和 diff。记录实际 GREEN、xcresult 与残留问题。
- [x] 精确暂存列出的文件并提交：`feat(player): 按后端身份替换播放器呈现`；提交后写 subagent 报告，等待根代理规格／质量复核。

### Task 11: Demux 元数据与共同媒体起点

**文件：** 修改 `Demux/DemuxTypes.swift`、`Demux/FFmpegDemuxer.swift`、`FFmpeg/VPFFmpegDemuxer.c`、`include/VPFFmpegDemuxer.h`；新建 `HLS/HLSTimelineCoordinator.swift`、`HLS/OutputFormatSignature.swift`；测试 `Playback/HLS/HLSTimelineTests.swift` 和现有 FFmpegDemuxerTests。

**接口与依赖：** 任务1、8；输出扩展轨道 descriptor、不可变 mediaOrigin、OutputFormatSignature、WriterTimelineMapping。C ABI 使用版本化附加结构，不改变已有80-byte结构的读取约定。

**规格合同：** 按设计7.1以首个可靠视频IDR/完整音频AU建立共同起点，初始T_e=10s；audio-only不等待视频。PTS/DTS精确有理换算、B帧DTS、格式漂移、EOS/discontinuity均有generation边界。传递轨道role/language/service、像素比例/颜色/HDR；缺失证据不得默认main。

- [x] 在 `HLSTimelineTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = HLSTimelineTestHarness.audioOnly()
try harness.appendAudio(pts: CMTime(value: 90_000, timescale: 90_000), samples: 1024, sampleRate: 48_000)
XCTAssertEqual(harness.mediaOrigin, CMTime(value: 1, timescale: 1))
XCTAssertEqual(harness.firstOutputPTS, CMTime(value: 10, timescale: 1))
XCTAssertEqual(harness.videoResourceCount, 0)
```

- [x] 运行 `-only-testing:VPlayerTests/HLSTimelineTests`，记录接口缺失与后续行为 RED。
- [x] 实现：新增映射器只消费现有DemuxEvent，不持有renderer。使用CMTime/checked整数保留源时间，禁止按callback arrival造PTS。测试原点两侧音频trim、缺IDR、负/无效时间、DTS与PTS关系、30-bit/33-bit边界；C与Swift新增字段逐一ABI和真实fixture验证。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 建立完整轨道元数据与共同时间线`，按报告合同提交给根代理复核。

### Task 12: H.264／HEVC 逐 AU 检查和 remux 准入

**文件：** 新建 `HLS/VideoAccessUnitInspector.swift`、`HLS/VideoRemuxEligibility.swift`、`HLS/VideoBitrateEnvelope.swift`；修改 `Video/AnnexBScanner.swift`、`Video/CompressedVideoAssembler.swift`；测试 `Playback/HLS/VideoRemuxEligibilityTests.swift`。

**接口与依赖：** 任务11；输出设计VideoRemuxDecision、逐AU proof、参数集签名与bitrate envelope；消费原始backing/range和完整轨道metadata。

**规格合同：** 逐NAL区分IDR/CRA，检查closed GOP、DTS、参数集与profile/level、VUI/SEI、avc1/avc3/hvc1/hev1，≤60fps，HDR/4K范围按设计7.2。unsafe GOP走硬编码而不是降画质；未知/unsupported输入明确错误。

- [x] 在 `VideoRemuxEligibilityTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = VideoRemuxEligibilityTestHarness()
let idr = try harness.inspectFixture("h264-idr-closed-gop")
XCTAssertEqual(idr.path, .remux)
let cra = try harness.inspectFixture("hevc-cra-open-gop")
XCTAssertEqual(cra.path, .transcode)
XCTAssertThrowsError(try harness.inspectFixture("progressive-120fps"))
```

- [x] 运行 `-only-testing:VPlayerTests/VideoRemuxEligibilityTests`，记录接口缺失与后续行为 RED。
- [x] 实现：有界bit reader与NAL scanner只读既有backing，fixture含真实参数集和手工期望字段；每个AU更新GOP证据，参数漂移提前请求item重建。测试设计13.1中四种sample-entry、首段后续AU参数集变化、HDR SEI、错DTS、码率上界和字节身份。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 校验视频码流并选择直通或硬编码`，按报告合同提交给根代理复核。

### Task 13: 保留 Metal YADIF2x 并接入 VT 硬编码

**文件：** 新建 `HLS/VTVideoEncoder.swift`、`HLS/VideoEncodingFrame.swift`、`HLS/HLSVideoTranscodeBranch.swift`；修改 `Deinterlace/VideoPipelineCoordinator.swift`、`Video/VideoFrameProcessing.swift`、`Video/VideoFormatMetadataReader.swift`；测试 `Playback/HLS/VTVideoEncoderTests.swift`、现有YADIF golden tests。

**接口与依赖：** 任务11、12；输出HLSVideoEncoding.encode(frame:)、finish()/cancel()/terminal；VideoEncodingFrame携带backing lease、PTS、duration、field parity、origin、format signature。

**规格合同：** 只允许可靠field order，保持P与P+D/2两场各D/2；NV12/P010→H.264 High或HEVC Main/Main10，硬件必须实际启用、closed GOP、无B帧、1秒keyframe，保留HLG/PQ/MDCV/CLLI/pasp。隔行High10/HEVC仍依非目标拒绝，不扩大软件解码支持。

- [x] 在 `VTVideoEncoderTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = VTVideoEncoderTestHarness(fieldOrder: .topFieldFirst)
try await harness.encodeInterlacedFixture(frameDuration: CMTime(value: 1, timescale: 25))
XCTAssertEqual(harness.encodedPTS, [CMTime.zero, CMTime(value: 1, timescale: 50)])
XCTAssertEqual(harness.encodedFieldIDs, [.top, .bottom])
XCTAssertTrue(harness.requiresHardwareEncoder)
```

- [x] 运行 `-only-testing:VPlayerTests/VTVideoEncoderTests`，记录接口缺失与后续行为 RED。
- [x] 实现：独立封装VTCompressionSession API，保持input lease至callback/terminal；编码串行背压，不能在慢callback时drop第二场。复用Metal实现并新增禁止assumed分支，保留现有SampleBuffer处理。模拟器做真实Metal+fake VT边界，硬编true与最终系统解码交由任务26/27真机。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 将 Metal 双场输出接入 VideoToolbox 硬编码`，按报告合同提交给根代理复核。

### Task 14: 完整音频输入域、主服务证明与分支 lease

**文件：** 新建 `HLS/SupportedAudioInputDomain.swift`、`HLS/AudioServiceSemantic.swift`、`HLS/AudioServiceBranchLeases.swift`、`HLS/PCMConsumerSubscriptions.swift`；修改现有AAC/AC3/EAC3/MPEG profiles与AC3 inspector；测试 `Playback/HLS/AudioServiceSemanticTests.swift`、`AudioServiceLeaseTests.swift`。

**接口与依赖：** 任务1、11；输出设计7.4的receipt/input proof/admitted sidecar、两态owner、stable PCM admission、固定三槽lease。

**规格合同：** 正式六codec/profile/framing/rate全域来自现有parser唯一表。associated/dvs/dependent/joc/unknown整代失败；stale proof只清自己，不影响当前。decoder每proof全局一次，compressed分支各一次，PCM每unit×subscription一次；close/held/transfer所有释放边与fence同CAS。

- [x] 在 `AudioServiceSemanticTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = AudioServiceSemanticTestHarness()
try harness.admitMainEAC3Syncframe()
XCTAssertEqual(harness.decoderPushCount, 1)
harness.deliverCurrentAssociatedServiceProof()
XCTAssertEqual(harness.failure, .unsupportedAudioServiceSemantic)
XCTAssertEqual(harness.aacAppendCountAfterFailure, 0)
XCTAssertEqual(harness.compressedAppendCountAfterFailure, 0)
```

- [x] 运行 `-only-testing:VPlayerTests/AudioServiceSemanticTests`，记录接口缺失与后续行为 RED。
- [x] 实现：扩展header和container角色解析，以定长proof与backing/range摘要绑定。共享executor签发lease并登记现有有界wrapper；按照设计438—495及900—906实现严格状态图、候选隔离和逐字段负例。支持域测试逐维度枚举，避免复制白名单。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 验证音频服务语义并约束分支所有权`，按报告合同提交给根代理复核。

### Task 15: 显式声道转换、48kHz AAC 与 priming 校准

**文件：** 新建 `HLS/AudioRenditionConverter.swift`、`HLS/StereoDownmixMatrix.swift`、`HLS/AACRenditionEncoder.swift`、`HLS/AACPrimingCalibrator.swift`、`HLS/AACMagicCookieEvidence.swift`；新增 `FFmpeg/VPFFmpegAudioConverter.c`、`include/VPFFmpegAudioConverter.h`；测试 `Playback/HLS/AudioRenditionConverterTests.swift`、`AACPrimingCalibratorTests.swift`。

**接口与依赖：** 任务14；输出每rendition独立converter/encoder、AAC final cookie、trim-aware samples和WriterTimelineMapping；C bridge仅使用已审计libswresample。

**规格合同：** 设计7.4声道label表逐行显式reorder，mono等幅复制，StereoDownmixMatrixV1固定binary64系数与Float32舍入/LFE0，输出48kHz。AAC mono96/stereo160/3—6ch320/7—8ch512kbps；两次reset校准L，并按生命周期冻结reset态R与完整EOS/drain终态B：`R1 == R2 == beforeLive`、`B1 == B2`，正式format只使用B2。live终态cookie须经严格ESDS解析，除唯一`maxBitrate`统计字段可在冻结envelope内收敛外，其余结构与原字节必须等于B2；真实AU与fMP4带宽仍独立验界。首尾trim/中段回环，非法cookie或实际带宽漂移走整presentation终态。

- [x] 在 `AudioRenditionConverterTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = AudioRenditionConverterTestHarness(inputLayout: .fivePointOne)
let output = try harness.convertSingleChannelImpulses()
XCTAssertEqual(output.sampleRate, 48_000)
XCTAssertEqual(output.stereoLFEPeak, 0)
XCTAssertEqual(output.fidelityChannelCount, 6)
XCTAssertTrue(output.allChannelLabelsMatchGolden)
```

- [x] 运行 `-only-testing:VPlayerTests/AudioRenditionConverterTests`，记录接口缺失与后续行为 RED。
- [x] 实现：每输出SwrContext显式matrix/layout/rate，使用swr_get_delay容量并完整drain。AudioConverter属性请求每次独立，cookie有512KiB子预算。按设计Golden脉冲、短epoch首尾同buffer；创建态A只作证据，严格验证两次reset态R相等、两pass终态B逐字节相等、首次正式PCM前仍为R。live完整drain后的cookie通过有界ESDS typed parser比较：tag/长度层级/flags/ASC/SL/avgBitrate/bufferSizeDB及全部非`maxBitrate`原字节必须等于B2，`maxBitrate`须不超过`ceil(1.25 × configuredBitrate)`，且不能替代实际AU一秒窗口与fMP4 envelope检查。正式format始终原样引用B2。系统decoder对真实Apple-HLS writer产物自然EOS/drain，证明全部AU、sample0、中段连续性及源尾样本都存在，并分别记录raw解码范围`Q`与输入buffer的有效范围`N`；不得把拼接init+media得到的裸`AVURLAsset`、按`N`裁出的PCM或segment report的raw范围冒充AVPlayer最终呈现端点。`B_e+N/48000`的播放器可见尾端仍由任务17—21从writer receipt、playlist、HTTP到真实AVPlayer逐层闭合。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 保留声道布局并编码校准后的 AAC`，按报告合同提交给根代理复核。

### Task 16: AC-3／E-AC-3 完整压缩 AU 与候选边界

**文件：** 新建 `HLS/CompressedAudioAccessUnit.swift`、`HLS/EAC3AccessUnitAssembler.swift`、`HLS/CompressedAudioConfiguration.swift`；测试 `Playback/HLS/EAC3AccessUnitAssemblerTests.swift`、`CompressedAudioOriginTests.swift`。

**接口与依赖：** 任务14；输出完整AU bundle/aggregation proof、dac3/dec3配置与eligible plan，完整admission identity贯穿writer。

**规格合同：** EAC3 syncframe按1/2/3/6 blocks凑六blocks/1536samples；partial 1—6张lease有界，结构失败只淘汰压缩候选，服务失败整代失败。mediaOrigin切AU在冻结participant前ineligible，不能降声道。AC3合法44.1k帧长交替保留。

- [x] 在 `EAC3AccessUnitAssemblerTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = EAC3AggregationTestHarness()
for _ in 0..<6 { try harness.appendMainSyncframe(blockCount: 1) }
XCTAssertEqual(harness.outputAccessUnits.count, 1)
XCTAssertEqual(harness.outputAccessUnits[0].sampleCount, 1536)
XCTAssertEqual(harness.transferredLeaseCount, 6)
XCTAssertEqual(harness.releasedLeaseCount, 0)
harness.confirmWriterTerminal()
XCTAssertEqual(harness.releasedLeaseCount, 6)
```

- [x] 运行 `-only-testing:VPlayerTests/EAC3AccessUnitAssemblerTests`，记录接口缺失与后续行为 RED。
- [x] 实现：解析convsync、strmtyp/substreamid、bsid/bsmod/asvc和data-rate，不声称Atmos。唯一CAS将held lease整体转bundle；writer expected身份逐字段复验。覆盖6×1、3×2、2×3、1×6、错序/重复/半AU/EOS/disco/owner退休。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 聚合并验证 AC-3 与 E-AC-3 压缩音频`，按报告合同提交给根代理复核。

### Task 17: 按轨分离的 fMP4 writer 与共同分段边界

**文件：** 新建 `HLS/SegmentedFMP4Writer.swift`、`HLS/SegmentBoundaryCoordinator.swift`、`HLS/SegmentReportRelay.swift`、`HLS/SealedMediaObject.swift`；测试 `Playback/HLS/SegmentedFMP4WriterTests.swift`。

**接口与依赖：** 任务11、13、15、16；输出immutable init/media objects、segment reports、每rendition独立writer与terminal receipt。

**规格合同：** AVAssetWriter .mpeg4Movie + .mpeg4AppleHLS，每轨单独writer；共同边界C_i精确按设计7.5，视频IDR／音频AU不跨切，AAC trim和WriterTimelineMapping保留。回调先有界计费再接纳，4/8段unpublished背压与控制relay独立归零。Apple-HLS segment模式下不得假定拼接init+media后的`AVURLAsset`会保留AAC尾trim，也不得把segment report的raw `Q`回填为有效`N`。本任务必须从同一输入buffer与immutable callback backing产出`AACEffectiveEndpointReceipt(B_e,N,Q,L,P)`，并让保持AU相同而删除end trim、把end trim改为±1 sample、提前附到非最终buffer的负例全部失败；receipt只证明待发布的有效端点，不能声称AVPlayer已经执行裁尾。任务18—20必须保持该receipt与playlist/HTTP对象身份，任务21再由真实AVPlayer证明epoch最终只呈现到`B_e+N/48000`；该端到端负例未绿以前不得完成集成。

- [x] 在 `SegmentedFMP4WriterTests` 写下列行为测试和本任务规格矩阵；具名 harness 在对应测试文件定义，调用真实生产组件，fixture 字段使用独立手工期望。

```swift
let harness = SegmentedFMP4WriterTestHarness.audioVideo()
try await harness.appendOneSecondClosedGOPAndAudio()
try await harness.flushCommonBoundary()
XCTAssertEqual(harness.videoWriterTrackCount, 1)
XCTAssertEqual(harness.audioWriterTrackCount, 1)
XCTAssertTrue(harness.sealedObjectsAreImmutable)
XCTAssertEqual(harness.audioAccessUnitsCutAcrossBoundary, 0)
```

- [x] 运行 `-only-testing:VPlayerTests/SegmentedFMP4WriterTests`，记录接口缺失与后续行为 RED。
- [x] 实现：封装writer append readiness、flushSegment和delegate callbacks；使用独立serial writer lane，不在控制锁里调用AVFoundation。fake验证慢callback/failure/取消，真实writer验证init/media可解析；retain源lease直到真实input terminal。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult，不以fake结果替代真实codec或系统回环。
- [x] 精确暂存并提交：`feat(hls): 按轨写入有界 fMP4 分段`，按报告合同提交给根代理复核。

### Task 18: 轻量 fMP4 分段健全性与时间线校验

**文件：** 新建 `HLS/FinalFMP4Validator.swift`、`HLS/SegmentTimelineValidator.swift`；测试 `Playback/HLS/FinalFMP4ValidationTests.swift`。

**接口与依赖：** 任务12—17；保持精简与下游兼容，输出 epoch format proof≤512bytes、segment receipt≤128bytes 与真实 backing/range/digest 身份；publisher 只接受验证过的同一 backing。

**规格合同（防过度工程化与轻量设计）：**
禁止在 Swift 层重复实现全量 ISO-BMFF 盒结构反序列化、递归语法树解析与字段级位变异破坏测试（系统组件 AVAssetWriter 产物绝大多数场景天然合规，深层字段测试性价比低）。
仅执行分段边界与关键时间线的轻量健全性检查：
1. **Init 段健全性**：验证非空，且前部包含合法的顶级 box 标头（`ftyp` 与 `moov`），未发生短读或截断。
2. **Media 分段健全性**：验证非空，包含顶级分段标头（`moof` 与 `mdat`），payload 长度符合基本边界。
3. **时间线连续性校验**：由 `SegmentTimelineValidator` 基于分段 report 与时间戳，复验时长合法性（单调递增、无时间戳倒退、无异常空洞），防止上游生成错乱分段。
4. **发布凭据签发**：验证通过后签发 `epoch format proof` 与 `segment receipt`，供任务 19 的 CAS 发布屏障使用；拒绝空数据、截断数据或时间倒退分段。
5. 详细的视频色彩空间（NCLX/HDR/SEI）及硬件解码兼容性验证统一交由任务 21/26 真实系统与 AVPlayer 回环完成，不在本任务中做冗余解析。

- [x] 在 `FinalFMP4ValidationTests` 写轻量健全性与时间线行为测试；具名 harness 在对应测试文件定义，调用真实生产组件。

```swift
let harness = FinalFMP4ValidationTestHarness()
let validSegment = try harness.validSegmentFixture()
XCTAssertNoThrow(try harness.validate(validSegment))
let truncatedSegment = try harness.truncatedSegmentFixture()
XCTAssertThrowsError(try harness.validate(truncatedSegment))
XCTAssertEqual(harness.publishedInvalidObjectCount, 0)
```

- [x] 运行 `-only-testing:VPlayerTests/FinalFMP4ValidationTests`，记录接口缺失与后续行为 RED。
- [x] 实现：轻量快速扫描顶级 box 4-byte 标头与分段大小，结合 segment timeline 检查后签发 proof，避免深度递归 AST 与大量状态机变异。
- [x] 运行针对性测试、被修改接口的既有测试及工程／许可证／diff检查；记录 GREEN 和 xcresult。
- [x] 精确暂存并提交：`feat(hls): 轻量校验 fMP4 分段健全性与时间线`，按报告合同提交给根代理复核。

### Task 19: 有界媒体 store、清单与共同发布屏障

**文件：** 新建 `HLS/SealedMediaStore.swift`、`HLS/HLSPlaylistSerializer.swift`、`HLS/HLSPublicationCoordinator.swift`、`HLS/PublicationCoverage.swift`；测试 `Playback/HLS/HLSPublisherTests.swift`、`HLSResourceStoreTests.swift`。

**接口与依赖：** 任务17、18；输出immutable master/media snapshots、participant vector、publication transaction、coverage、availability tombstone与response lease。

**规格合同：** 设计7.5/11全部容量与时间窗；6/7段共同首发、冻结CODECS/CHANNELS/bandwidth、仅master有INDEPENDENT-SEGMENTS、audio-only不建master。publication CAS逐participant验证同epoch proof/receipt，cleanup先退participant再停writer；对象按完整backing计费，不按Range slice计费。

- [x] 在 `HLSPublisherTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = HLSPublisherTestHarness(participantCount: 2)
try harness.sealVideoSegments(count: 6)
XCTAssertNil(harness.visibleMaster)
try harness.sealAudioSegments(count: 6)
XCTAssertNotNil(harness.visibleMaster)
XCTAssertEqual(harness.visibleParticipantCount, 2)
XCTAssertEqual(harness.invalidPublicationCount, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：serializer从冻结模型生成精确UTF8，禁止运行期漂移。store reservation先于分配；snapshot lease、response lease、retirement与availability horizon同域线性化。测试全部cap±1、跨epoch、旧transaction、audio lag、backlog、keep-alive pin和带宽笛卡尔包络。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(hls): 有界发布完整多轨 HLS 清单`；根代理取得规格／质量review后才标记完成。

### Task 20: Loopback HTTP 与真实完成响应证据

**文件：** 新建 `HLS/LoopbackHTTPServer.swift`、`HLS/LoopbackRequestParser.swift`、`HLS/HTTPRange.swift`、`HLS/LoopbackAuthorization.swift`、`HLS/CompletedMediaEvidence.swift`；修改 `project.yml` 加入Network.framework；测试 `Playback/HLS/LoopbackHTTPServerTests.swift`、`HTTPRangeTests.swift`。

**接口与依赖：** 任务19；输出ephemeral IPv4 localhost URL、16byte CSPRNG capability token、GET/HEAD/Range response、CompletedInitBodyEvidenceState与CompletedMediaBodyEvidenceState。

**规格合同：** 只bind127.0.0.1，严格peer/Host/token/method/path/generation；设计7.6 parser/header/connection/send块上限。HEAD不授完整body证明；206要按实际成功发送union证明，最多64 response identities，capacityExceeded吸收态；close与acquire同锁，404/410/416语义精确。

- [x] 在 `LoopbackHTTPServerTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = try await LoopbackHTTPTestHarness.start()
let reply = try await harness.getRange("bytes=0-3")
XCTAssertEqual(reply.status, 206)
XCTAssertEqual(reply.body, Data([0, 1, 2, 3]))
XCTAssertFalse(harness.hasCompleteMediaBodyEvidence)
let head = try await harness.head()
XCTAssertEqual(head.body.count, 0)
XCTAssertFalse(harness.hasCompleteMediaBodyEvidence)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：使用NWListener显式requiredLocalEndpoint，监听器ready后才返回URL；随机失败不启动。HTTP parser增量有界，无percent绕过/路径遍历/多Range/请求走私；send completion逐块登记，失败/取消不计。真实socket测试攻击输入与生命周期，日志不得出现token。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(hls): 提供受限 loopback HTTP 媒体服务`；根代理取得规格／质量review后才标记完成。

### Task 21: AVPlayer item、预卷、播放授权与静止确认

**文件：** 新建 `HLS/AVPlayerItemCoordinator.swift`、`HLS/AVPlayerDriver.swift`、`HLS/AVPlayerQuiescence.swift`；修改 `Rendering/AVPlayerPresentationContext.swift`；测试 `Playback/HLS/AVPlayerItemCoordinatorTests.swift`。

**接口与依赖：** 任务4、8、10、20；输出AVPlayer ready/selected rendition/PreparedPlayhead、BackendActivationResult、AVPlayerQuiescenceReceipt；使用OutputPlayerStopTask唯一暂停。

**规格合同：** 保持rate0装item，自动缓冲等待，设计3秒preroll、共同coverage及真实HTTP init/media证据；不手工输出latency shift。KVO/event匹配item/lifecycle/activation，系统waiting↔playing仅属于当前授权。stop cancel preroll→pause→rate0确认→replace nil→KVO移除。AAC尾端必须消费任务17的`AACEffectiveEndpointReceipt`并绑定任务18—20保持的同一playlist/HTTP backing；真实AVPlayer须证明epoch最终只呈现到`B_e+N/48000`。保持AU不变而删除end trim、把end trim改为±1 sample或提前附到非最终buffer时，端点验证必须失败，不能以segment report的raw `Q`或裸拼接asset替代。

- [x] 在 `AVPlayerItemCoordinatorTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = AVPlayerCoordinatorTestHarness()
try await harness.prepareWithCoverage(seconds: 3)
XCTAssertEqual(harness.playerRate, 0)
await harness.activateCurrentPermit()
XCTAssertEqual(harness.playCallCount, 1)
await harness.beginSuspendTwice()
XCTAssertEqual(harness.pauseCallCount, 1)
XCTAssertFalse(harness.canReplaceItemBeforeRateZero)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：SDK交互在规定lane/actor，所有handler带准确身份；AVPlayer driver注入用于确定性竞态，真实AVPlayer+loopback单独集成验证。运行design prepared playhead、selected音轨、无access-log、body delivery、stale KVO、cancel/stop的完整矩阵。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [ ] 精确暂存并提交：`feat(hls): 用 AVPlayer 授权播放并确认本地输出静止`；根代理取得规格／质量review后才标记完成。

### Task 22: 接通 HLS 音视频 backend

**文件：** 新建 `Pipeline/HLSAVPlayerPlaybackBackend.swift`、`HLS/HLSOutputItemBundle.swift`、`HLS/HLSVideoBranch.swift`、`HLS/AudioRenditionBranch.swift`；修改 `Pipeline/PlaybackBackendFactory.swift`；测试 `Playback/HLS/HLSAVPlayerBackendTests.swift`。

**接口与依赖：** 任务11—21；输出可正式创建的HLSAVPlayer backend，将demux→remux或Metal/VT、audio→AAC/压缩、writer→publisher→HTTP→AVPlayer接线。

**规格合同：** 每个item bundle独占资源，source request HTTP(S)仅demux读取；AVPlayer只读loopback。非AirPlay工厂零创建HLS资源；AirPlay只走新backend且失败无SampleBuffer后备。codec/capability/profile/format变化在发布前验证，真实backpressure贯穿上游。

- [x] 在 `HLSAVPlayerBackendTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = HLSAVPlayerBackendTestHarness.progressiveAAC()
try await harness.prepare()
XCTAssertEqual(harness.inputReaderCount, 1)
XCTAssertEqual(harness.playerSourceHost, "127.0.0.1")
XCTAssertEqual(harness.playerRate, 0)
XCTAssertTrue(harness.allAdvertisedRenditionsValidated)
await harness.stopAndDrain()
XCTAssertEqual(harness.outstandingResourceLeaseCount, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：分支各自职责文件，不把所有逻辑堆进backend。producer/readiness/diagnostic与cleanup control流分开，运行data-plane全链接测试；在注入writer/HTTP/player失败时确认资源归零与零无效publication。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(playback): 接入 AirPlay HLS AVPlayer 音视频后端`；根代理取得规格／质量review后才标记完成。

> 2026-09-13：Task 22 实现、验证与提交已闭合（commit 95ff113），交接证据见 `docs/superpowers/reports/task-22-handoff.md`。现由 Antigravity 接手继续执行 Task 23—29。

### Task 23: audio-only 保真候选与串行选择

**文件：** 新建 `HLS/AudioOnlyItemSelector.swift`、`HLS/AudioOnlyCandidateBundle.swift`、`HLS/CandidateBranchDrainFences.swift`；修改HLS backend和audio branch；测试 `Playback/HLS/AudioOnlyItemSelectorTests.swift`。

**接口与依赖：** 任务14—21、22；输出selection transaction、candidate ticket/cleanup group、direct media item和compatibilityStereo诊断。

**规格合同：** 不等待IDR，不建video/Metal/VT/master；同声道压缩→同声道AAC→stereo，源stereo去重。所有可选候选先共同6/7段门槛；5秒probe/1秒cleanup，外层19/20、13/14、7/8秒后缀判定。保真生成失败不能伪装成route只支持stereo。

- [x] 在 `AudioOnlyItemSelectorTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = AudioOnlySelectorTestHarness.fivePointOne()
harness.failCompressedProbe()
try await harness.select()
XCTAssertEqual(harness.selectedRendition, .fidelityAAC)
XCTAssertEqual(harness.maximumConcurrentProbes, 1)
XCTAssertEqual(harness.videoResourceCount, 0)
XCTAssertEqual(harness.masterPlaylistCount, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：候选开始物化前领取item/participant，loser cleanup只关自己的compressed/PCM subscription；shared decoder每proof仍一次。selection cleanup封口完整group，超时继续原stop task，禁止后继绕过；覆盖设计音频lease状态与候选所有竞态。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(hls): 支持保真 audio-only 串行候选播放`；根代理取得规格／质量review后才标记完成。

### Task 24: 全路由热切换、中断、重置与格式恢复

**文件：** 新建 `Control/PlaybackRecoveryCoordinator.swift`、`Control/MediaServicesResetRecovery.swift`；修改Controller、AudioSessionOwner、route service、两Backend与format coordinator；测试 `Playback/Control/PlaybackRecoveryTests.swift`、现有PlaybackControllerTests。

**接口与依赖：** 任务6—10、22、23；输出设计8—10统一recovery事务，所有后端正式接线。

**规格合同：** HDMI↔AirPlay、AirPlay endpoint变化、none、用户pause、interruption、连续reset、format/item变化按最高owner和同parent预算收敛。旧输出静止/退休后才后继；route-only零setCategory/deactivate，不重置generation；resets才重跑固定配置。

- [x] 在 `PlaybackRecoveryTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = PlaybackRecoveryTestHarness()
await harness.playThroughHDMI()
await harness.switchToAirPlay()
await harness.switchToHDMI()
XCTAssertEqual(harness.backendHistory, [.sampleBuffer, .hlsAVPlayer, .sampleBuffer])
XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
XCTAssertEqual(harness.categoryCallCount, 1)
XCTAssertEqual(harness.routeOnlyDeactivateCount, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：恢复事务一个slot，每await回executor重验owner/fence/receipt/route/intent/budget。依设计13.1逐对排列reset/ended/stop/newplay/factory late/cleanup timeout，预算不可续杯、poisoned屏障直到准确清理确认。运行完整VPlayerTests和UI挂载测试。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(playback): 完成双后端路由与系统恢复`；根代理取得规格／质量review后才标记完成。

### Task 25: 分型诊断、watchdog 与全局资源账本

**文件：** 新建 `HLS/PlaybackApplicationChargeLedger.swift`、`HLS/HLSPlaybackWatchdog.swift`、`Diagnostics/BackendPlaybackMetrics.swift`；修改PlaybackMetrics、PlaybackSignposts、App acceptance展示、PRIVACY.md；测试 `Playback/HLS/HLSCapacityTests.swift`、`Playback/BackendDiagnosticsTests.swift`。

**接口与依赖：** 任务19—24；输出设计11全局及分层reservation/charge ownership、分型metrics、稳定错误码和watchdog重建请求。

**规格合同：** 所有媒体/encoder/writer/store/snapshot/HTTP/control lease先计费，release对应owner恰一次。HD/4K的全部设计hard cap、自动笛卡尔包络推导，Surface/bytes无重复计费。诊断不伪造SampleBuffer计数，不输出URL/token/设备名。HLS stalled/backlog/watchdog只走统一recovery。

- [x] 在 `HLSCapacityTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let harness = HLSCapacityTestHarness()
let object = try harness.reserveSealedObject(bytes: 1_048_576)
let rangeLease = try harness.pinRange(object, lower: 0, upper: 1)
XCTAssertEqual(harness.chargedSealedBytes, 1_048_576)
harness.retireObject(object)
XCTAssertEqual(harness.chargedSealedBytes, 1_048_576)
harness.release(rangeLease)
XCTAssertEqual(harness.chargedSealedBytes, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：容量参数从设计11逐值声明于封闭配置而非散落magic numbers；测试行为cap±1、慢producer/consumer、backlog、oldHTTP pin、最长播放进展；用示例恶意URL/设备名注入错误对象并断言输出只含白名单代码。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`feat(playback): 约束 HLS 全局资源并提供分型诊断`；根代理取得规格／质量review后才标记完成。

### Task 26: 完整 codec／4K／HDR／双场 fixture 系统回环

**文件：** 扩展 `Scripts/generate-playback-fixtures.sh` 与fixture manifest；新建 `Tests/VPlayerTests/Playback/HLS/HLSCodecIntegrationTests.swift`、`HLSVideoIntegrationTests.swift`；修改 `PlaybackFixtureIntegrationTests.swift`、fixture loader和project.yml资源项。

**接口与依赖：** 任务12—25；输出SupportedAudioInputDomain逐维度覆盖清单、真实输入→解码/转码→fMP4→系统decode/AVPlayer结果。

**规格合同：** 覆盖六codec全部现有profile/framing/rate维度、mono到8ch语义表、audio-only、H264/HEVC progressive/unsafeGOP、1080i25/29.97双场、2160p50/59.94、NV12/P010、SDR/HLG/PQ。fixture生成与manifest同步且可复现；无假媒体字节冒充codec成功。

- [x] 在 `HLSCodecIntegrationTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let coverage = try SupportedAudioFixtureCoverage.loadCheckedInManifest()
XCTAssertEqual(coverage.uncoveredDomainValues, [])
let result = try await HLSCodecFixtureRunner.run("eac3-main-6x1block-5.1")
XCTAssertEqual(result.decodedFramesPerAccessUnit, 1536)
XCTAssertEqual(result.channelCount, 6)
XCTAssertTrue(result.publishedBytesPassedSystemDecode)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：生成器使用固定ffmpeg版本参数，保留小型真实fixtures和SHA manifest；full domain enumerator与测试共用parser支持表但期望样本/像素ID手算。输出YADIF每场ID贯穿Metal→VT→fMP4系统decode，AAC priming真实sample误差≤1/48000秒。真机专属测试具明确原因，不能算成通过。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`test(hls): 覆盖完整编码域与系统解码回环`；根代理取得规格／质量review后才标记完成。

### Task 27: Apple TV 真机启动、热切换与两小时长播

**文件：** 修改 `Scripts/run-device-acceptance.sh`、`Scripts/run-playback-integration-tests.sh`、`Tests/VPlayerUITests/LongPlaybackAcceptanceTests.swift`；新建 `Scripts/run-airplay-hls-acceptance.sh`、`docs/superpowers/validation/2026-09-05-airplay-hls-functional-validation.md`。

**接口与依赖：** 任务24—26；输出真机功能/内部时序报告、mediastreamvalidator/hlsreport、两小时phys_footprint序列和cap结论。

**规格合同：** 仅运行已授权设备/Team；设备识别本地运行时解析、脱敏报告。设计13.2逐矩阵路由/codec/启动/暂停/换台/睡眠恢复；两小时使用7200次绝对单调时窗读取、841…900与7141…7200两个60项窗口的向下取整中位数、32MiB增长、1.5GiB最大footprint、256MiB最低available memory及各backlog hard cap，不用p95/斜率替代该协议；AAC校准另按3轮预热＋20轮测量协议执行。内部PTS不当作声学同步。无法访问设备先用现有CLI唤醒/重连安全检查。

- [x] 在 `LongPlaybackAcceptanceTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let measurement = try LongPlaybackMemoryMeasurement(samples: fixtureSamples)
XCTAssertTrue(measurement.hasCompleteTwoHourCoverage)
XCTAssertLessThanOrEqual(measurement.maximumFootprintBytes, measurement.allowedFootprintBytes)
XCTAssertTrue(measurement.noUnboundedGrowth)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：将measurement分析器放测试支持而非产品入口；shell脚本参数校验、仅绑定loopback fixture服务、退出时回收自建进程。真实设备输出只报告实际完成矩阵，缺外部路由控制则记录可验证范围。部署与测试已有授权，无需重复请求。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`test(playback): 添加 AirPlay 真机与长播验收`；根代理取得规格／质量review后才标记完成。

### Task 28: 物理音画同步分析与脱敏证据验证

**文件：** 新建 `Tools/PhysicalSync/Package.swift`、`Sources/PhysicalSyncEvidence/` 中 `CanonicalCBOR.swift`、`PhysicalSyncStatistics.swift`、`PhysicalSyncEnvironment.swift`、`ArchivePrivacyAdmission.swift`、`ControlArchiveValidator.swift`，对应Tests；新建中文运行README。

**接口与依赖：** 任务26；独立macOS Swift工具，不链接进tvOS app；输出设计13.3严格schema、36事件统计、calibration/before/target/after envelope与validator。

**规格合同：** 严格执行设计13.3的可复算物理证明、median/p95/max/TheilSen、校准不确定度、硬件环境/几何、公开WirelessAudioSync事务和逐帧pre-write隐私。canonical schemas、计数/byte/time上限、三份capture hash、UI/remote evidence必须完整；没有画面+声压采集则不得输出通过。

- [x] 在 `PhysicalSyncEvidenceTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: Array(repeating: 20, count: 36), elapsedSeconds: (0..<36).map { $0 * 10 })
XCTAssertEqual(result.medianAbsoluteMilliseconds, 20)
XCTAssertEqual(result.p95AbsoluteMilliseconds, 20)
XCTAssertEqual(result.driftMillisecondsPerMinute, 0)
XCTAssertTrue(result.passesThresholds)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：在工具目录swift test完成严格整数/rational/CBOR及golden变异测试；允许ROI外像素注入不得改变sealed bytes/digest，header后modal/自由文字使该帧及后续零写入。没有可用相机/麦克风/校准硬件时分析器仍需完成，报告明确物理采集缺项，不能伪造测量。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`test(playback): 实现物理音画同步证据校验工具`；根代理取得规格／质量review后才标记完成。

### Task 29: 全分支接线复核与最终验收结论

**文件：** 复查任务1—28所有修改；更新中文validation报告和本计划完成标记；按检查产生具体修复文件。

**接口与依赖：** 任务1—28；输出真实完整测试、代码review和可合并状态；不自动merge或push。

**规格合同：** 设计第14节一次性交付门槛逐项核对，所有正式范围有实现与真实验证证据；本地功能与资源成本回归。完整分支review一次，修复波一次，残留按ledger裁决。物理采集缺失单独标为未完成门槛。

- [x] 在 `VPlayerTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let result = try AcceptanceMatrix.loadReport()
XCTAssertEqual(result.missingFunctionalRequirements, [])
XCTAssertEqual(result.maximumPotentiallyAudibleOutputs, 1)
XCTAssertEqual(result.nonAirPlayHLSResourceCreations, 0)
```

- [x] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [x] 实现：上述AcceptanceMatrix为测试报告工具，不是生产逻辑或固定返回值；从实际xcresult/运行产物汇总。运行Scripts/test.sh、bootstrap/license、fixture self-tests、device矩阵、可用物理校验、git diff --check；读结果而非仅退出码。最终review后报告提交、变更、证据、限制和所有ledger Ruling。
- [x] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [x] 精确暂存并提交：`docs(playback): 记录双后端实施与验收结果`；根代理取得规格／质量review后才标记完成。
