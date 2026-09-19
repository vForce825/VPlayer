# Task 21 实施报告（Review 1 / Review 2 / Review 3 / Review 4）

日期：2026-09-10

分支：`codex/airplay-hls-avplayer`

Review 1 基线：`6b45f1c`

Review 2 基线：`7666e68f4db77da874fce91579ef5fc0b485c26c`

Review 3 基线：`410326c21ee401608d9ee5b1c598254e769efa7b`

## 结论

本轮按 Review 1 冻结了 `AVPlayerItemCoordinatorTests` 的 45 个 selector，其中 31 个为原 Task 21 合同、14 个为审查补充合同；审查补充 14 项与原有 2 项真实系统回环组成固定 16 项失败集合。固定 16 项最终全部通过；最后一个单 selector 修复后只执行一次最终整类回归，结果为 45/45 通过、0 skip。

本报告只说明模拟器内可重复取得的实现与证据，不把任务标记为已通过最终规格／质量审查，也不把 tvOS Simulator 结果冒充 HomePod 或物理设备验收。本轮没有运行全量测试、真机测试或 Task 22。

## 本轮闭合的生产合同

1. 正 rate 只消费既有 `ControlTaskRegistry.BackendPositiveRateInvocation`。调用 `play` 前核验 route/session/intent/fence/interval，`await play` 返回后再次核验同一 invocation；没有另建可由调用方构造的授权体系。
2. selected rendition 与 readiness 消费 Loopback 服务器在真实 full-body send terminal 后签发的单次 opaque capability。证据绑定 server/token/port、item URL/generation、publication sequence、冻结 participant、playlist snapshot 以及 init/media backing；HEAD、Range、半包、失败、旧 publication 和跨服务器证据均不能签发。
3. readiness 在 source media timeline 与 AVPlayer item timeline 间显式映射 PreparedPlayhead；seek 使用 track timescale tick，loaded ranges 异步等待并规范化合并，最终同时要求冻结的音频／视频 participant 具有共同三秒 coverage。
4. prepare/install/stop 都使用带 item/lifecycle/phase/ticket 的单飞 CAS。每个异步边界后重验身份；caller cancel 或 timeout 不产生第二条底层 stop，已有 runner 继续收敛。
5. stop 先验证 registry 的 suspend ticket／close claim，再由唯一 `OutputPlayerStopTask` 执行 cancel preroll、drain、pause 与 rate 0 确认；quiescence 后由 lifecycle cleanup owner 负责 replace nil 与 observer 清理。不同参数不能领取首任务 receipt，同参数可 join，同一成功 receipt 在 request 清理后仍可验收。
6. `SystemAVPlayerDriver` 使用 item/lifecycle/activation 身份化的单槽 waiter／KVO relay；ready、loaded、preroll、time-control、EOS、cancel、replace 与 stop 均以恰好一次终态恢复 continuation。
7. AAC 端点验证消费 Task 17 writer terminal 与 `AACEffectiveEndpointReceipt`，并与 Task 18—20 的 snapshot、response terminal 和实际服务 backing 绑定；调用方不再提供 expected UUID/index。真实 EOS 由系统 `didPlayToEndTime` 触发后落在已验证的 `B_e + N/48000`，没有经验 latency shift。
8. `SegmentedFMP4Writer` 在系统 segment callback 内不再同步等待同一 callback queue 上的 `cancelWriting()`，避免 libdispatch 自等待；取消仍由 writer lane 签署唯一失败终态。
9. checked identity、participant/rendition/dependency、KVO/waiter 与 stop 计数都受固定容量约束；registry 继续复用原有 record 与 runner，没有扩张 64 KiB owned-control allocation。

## 测试矩阵与 RED 证据

### 冻结矩阵

- 原 Task 21：31 项。
- Review 1：14 项，覆盖 registry 正 rate authority、completed-body rendition authority、跨 server／冻结 A/V readiness、stop claim/receipt、operation ticket、端点生产 validator、System driver relay、track tick/loaded-range 合并、preroll 后静止 CAS、registered suspend stop ownership、checked identity／heap backing。
- 固定失败集合：上述 14 项加原有 2 项真实 AVPlayer/Loopback 端点测试，共 16 项。
- 整类：45 项；源码无 `XCTSkip` 或 `XCTExpectFailure`。

### 有效 RED

1. Loopback completed-response authority：`/tmp/VPlayer-task21-loopback-red2-20260910.xcresult`，2/2 实际执行且失败，均因 full-body terminal 尚不能签发 capability。此前 red0/red1 为测试目标编译阻断，属于机械诊断，不计行为 RED。
2. 固定 16 项：`/tmp/VPlayer-task21-review1-target16-batch2-20260910.xcresult`，11 通过、5 失败。失败分类为端点 admission 仍要求未参与呈现的 backing、真实 A/V loaded range/coverage 未闭合，以及真实 EOS 最终时间未落在 Task 17 端点。
3. 同一剩余 5 项生产失败集合：`/tmp/VPlayer-task21-review1-failure5-batch10-20260910.xcresult`，2 通过、3 失败。一个真实 A/V selector 暴露 writer callback queue 自等待崩溃；两个真实 EOS selector 比权威端点晚约 14.5 ms。

`/tmp/VPlayer-task21-review1-failure5-batch4-20260910.xcresult` 只有 Data/Staging、没有完整 Info.plist，是被终止的未完成结果包，不计测试矩阵。真实媒体早期 URI、publication 或 payload 夹具误配也只作为 fixture 诊断，没有包装成生产行为 RED。

## GREEN 证据

测试平台均为 Apple TV 4K（第 3 代）tvOS 26.2 Simulator，arm64：

- 剩余 5 项：`/tmp/VPlayer-task21-review1-failure5-batch11-20260910.xcresult`，5/5 通过，0 skip。
- 固定 16 项：`/tmp/VPlayer-task21-review1-target16-batch12-20260910.xcresult`，16/16 通过，0 skip。
- 不同 stop 参数唯一 selector：`/tmp/VPlayer-task21-review1-stop-different-params-final5-20260910.xcresult`，1/1 通过，0 skip。
- 最后一个单 selector 修复后的单次最终整类回归：`/tmp/VPlayer-task21-review1-avplayer-coordinator-class-final2-20260910.xcresult`，45/45 通过，0 skip。

真实集成 selector 由 Task 15 `AACRenditionEncoder` 生成可解码 AAC，经 Task 17 `SegmentedFMP4Writer` 和 endpoint receipt、Task 18—20 publication/snapshot/store，再由真实 Loopback socket full-body GET 进入 AVPlayer。真实 A/V selector同时发布 H.264 video 与 selected AAC audio，并验证 master、各轨 media playlist、init/media GET 以及共同三秒 coverage。trim 删除、±1 sample 与非最终位置 mutation 修改实际服务 fMP4/trim，并通过生产 admission/validator 失败；没有使用 access log、raw Q、裸 asset 或手工 latency shift 代替正式证据。

## 静态门禁

提交前执行并记录以下四项：

1. `Scripts/bootstrap.sh --check`：工程生成一致。
2. `Scripts/verify-licenses.sh`：许可证审计通过。
3. `git diff --check`：无空白错误。
4. 生产源码检索：无 `PlayerTargetRateAuthorization`、`completedRenditions`、`renditionResponseCompleted`、helper-only endpoint evidence、生产 `Task.yield`；Task 21 测试文件恰为 45 selectors 且无 skip。

## 范围与待审

- 未运行全量测试、Release 全工程测试、真机或 HomePod 验收；这是本轮明确的执行边界。
- tvOS Simulator 的真实 AVPlayer/Loopback 测试已提供系统集成证据，但物理 AirPlay 路由与 HomePod 最终验收仍由后续规定阶段完成。
- 本提交交由根代理进行 Task 21 Review 1 规格与质量裁决；本报告不自行把 Task 21 标记完成。

## Review 2 复审返修

### 冻结合同

Review 2 在 `AVPlayerItemCoordinatorTests`、`LoopbackHTTPServerTests`、`HLSPublisherTests` 与 `SegmentedFMP4WriterTests` 中冻结 17 个 selector，集中覆盖以下生产边界：

1. Registry 同一 safety-ingress 域签发的一次性正 rate capability，在 MainActor `play()` 紧邻边界消费，并在异步返回及 `.playing` KVO 发布前复验当前权威。
2. Loopback 真实 send-terminal 的单槽 success ingress、版本化 publication CAS／availability horizon，以及最多 64 个 206 响应并集形成 completed evidence；HEAD、失败与缺口均不成立。
3. 每个 AAC participant 必须绑定 Task 17 writer endpoint authority；自然 EOS 只记录同 item 的稳定 current time，不以 seek 或 `forwardPlaybackEndTime` 伪造端点。
4. backend-kind opaque quiescence proof 由 Registry 核验 item／activation／ticket／close claim／stop nonce 与 paused direct read 后关闭 interval；Controller 不再自行写入 `rateZero=true`。
5. System driver 合并相邻 loaded ranges，以固定单 timer 管理 ready／loaded／preroll／paused waiter，并以身份化单槽 relay 合并 time-control 事件。
6. `AccessLogURIClassifierV1` 区分 matching、conflicting 与 invalid local resource；A/V participant 恰好一个 video，计数及预分配容量在 append 前 checked fail-closed。
7. natural-end AAC publication 在发布前核准 writer receipt 的有效样本数、最终 endpoint 与共同边界；writer failure 的 cancel 进入固定 cleanup lane，并在签发 terminal／恢复 waiter 前完成 join。

### RED 证据

- 冻结 17 项首次有效 RED：`/tmp/VPlayer-task21-review2-red5.xcresult`，17 项全部实际执行，3 项通过、14 项行为失败、0 skip。失败覆盖正 rate capability、自动 publication 失效、版本权威、206 并集、AAC endpoint／EOS、backend quiescence、paused relay、URI classifier、单 timer／relay、natural-end publication 与 writer cleanup join。
- 集中生产实现后的首次统一运行：`/tmp/VPlayer-task21-review2-green1.xcresult`，15 项通过、2 项失败、0 skip。剩余失败仅为新版 send-terminal 事件跨 lane 投递，以及 writer callback 取消与 terminal 的 join 顺序。
- 上述两个 selector 作为同一失败集合集中返修后：`/tmp/VPlayer-task21-review2-failure2-green3.xcresult`，2/2 通过、0 skip。Loopback 以真实新版 media playlist 完整 body terminal 撤销旧权威，并由固定事件槽跨 lane 交付；writer 进入 `retiring` 后由登记的固定 cleanup lane 完成 cancel，随后才签 terminal 并恢复 finish waiter。

机械编译门禁使用 `/tmp/VPlayer-task21-review2-build5.log`，`build-for-testing` 退出码为 0。机械编译错误与临时链路诊断没有记作行为 RED，临时诊断代码也未保留在提交中。

### 最终 GREEN 证据

复用同一 build5 Derived Data，在 Apple TV 4K（第 3 代）tvOS 26.2 Simulator、arm64 上关闭并行，只统一运行冻结的 17 个 Review 2 selector：

- 结果包：`/tmp/VPlayer-task21-review2-final-final.xcresult`
- 结果：17/17 通过，0 failure，0 expected failure，0 skip。
- 执行时间：测试体 1.530 秒；结果包总流程完成。

本次最终回归没有扩大为任一整类或全量 suite。

### Review 2 静态门禁

提交前重新执行以下四项，均以退出码 0 通过：

1. `Scripts/bootstrap.sh --check`：工程生成一致。
2. `Scripts/verify-licenses.sh`：许可证审计通过。
3. `git diff --check`：无空白错误。
4. 静态检索：生产源码无旧 `PlayerTargetRateAuthorization`、`completedRenditions`、`renditionResponseCompleted`、`completedResponseTerminalObserved`，无生产 `Task.yield`，Controller 无硬编码 `rateZero: true`；`forwardPlaybackEndTime` 仅保留 `.invalid` 清理；四个 Review 2 目标测试文件无 `XCTSkip` 或 `XCTExpectFailure`。

### Review 2 范围声明

- 本轮没有运行全量测试、整类测试、真机或 HomePod 验收，也没有进入 Task 22。
- Loopback socket、206 union 与系统 AVPlayer/KVO 证据均来自 tvOS Simulator；不把模拟器结果表述为物理 AirPlay／HomePod 验收。
- 本报告只记录 Review 2 冻结合同的实现与可重复证据，仍由根代理进行最终规格／质量裁决；不自行把 Task 21 标记为完成。

## Review 3 最终复审返修

### 冻结合同与生产闭合

Review 3 在 `AVPlayerItemCoordinatorTests` 与 `LoopbackHTTPServerTests` 中冻结 12 个高信息量 selector，集中闭合以下生产边界：

1. 正 rate capability 的复验、单次消费与真实 `play` side effect 全部在同一个 `SynchronousSafetyIngressCell` 临界区内执行；`.playing` KVO 发布仍复验当前 Registry 权威，撤权会进入共享 Registry suspend。
2. Loopback full-body terminal 驱动真实 `RenditionSelectionSlot` 的 `unbound`／`bound`／`invalid` 状态、nonce、证据摘要与 playhead overlap；同 publication 的 A→B 切换自动失权并触发单飞 stop／reprepare。System access-log observation 接入同一 URI classifier。
3. AVPlayer backend quiescence 由 coordinator 在真实 stop receipt 后签发私有 attestation，Registry 对 proof 执行一次性消费；调用方不能再用公开布尔值或普通结构体伪造 AVPlayer 静止。
4. live AAC prepare 绑定每个 AAC participant 的强类型 writer terminal binding，允许 writer 未完成时 install；writer terminal 后的 endpoint authority 仍绑定同一 writer、publication 与自然 EOS。
5. 自然 EOS 只做同 item 两次稳定 direct read，不 seek、不改 `currentTime`；稳定时间必须等于 Task 17 endpoint authority，served trim 删除、±1 sample 与提前终止均 fail closed。
6. 未激活的 System item 自行安装固定 paused KVO waiter；ready／loaded／preroll／paused deadline 使用有界 scheduler，第五项显式 `capacityExceeded`，EOS deadline 会取消旧槽。
7. publication sequence 以 max-CAS 前进，旧 availability horizon terminal 不会令权威从 N 回退到 N-1；publication event 由单个预拥有 drain runner 合并，不为每个事件新建 Task。
8. 安全关键 driver 协议不再提供默认 no-op；System、SampleBuffer 与测试 double 均显式实现。容量计数覆盖 retained graph、relay、timer 与 pending runner，而非只检查浅层 stride。

### RED 与批量返修证据

- 冻结 12 项有效 RED：`/tmp/VPlayer-task21-review3-red3.xcresult`，12 项全部实际执行，23 个冻结断言失败，0 skip。
- 集中生产实现后的机械编译：`/tmp/VPlayer-task21-review3-build6.log` 首次通过；最后一批 fixture／classifier 批改后的复用构建为 `/tmp/VPlayer-task21-review3-build7.log`，`TEST BUILD SUCCEEDED`。
- 首次统一 GREEN 尝试：`/tmp/VPlayer-task21-review3-green1.xcresult`，10/12 通过、2 项失败、0 skip。两个剩余失败分别是安全关键 driver fixture 缺少冻结 video participant，以及 classifier 尚未把合法 opaque AAC URI 归为同 server 的 rendition conflict；它们作为同一失败集合一次性修正，没有逐 selector 往返。

### 最终 GREEN 证据

复用同一 Derived Data，在 Apple TV 4K（第 3 代）tvOS 26.2 Simulator、arm64 上关闭并行，只统一运行冻结的 12 个 Review 3 selector：

- 结果包：`/tmp/VPlayer-task21-review3-green2.xcresult`
- 日志：`/tmp/VPlayer-task21-review3-green2.log`
- 结果：12/12 通过，0 failure，0 expected failure，0 skip。
- 测试体执行时间：1.762 秒；`xcodebuild` 最终为 `TEST EXECUTE SUCCEEDED`。

### Review 3 静态门禁与范围声明

提交前执行以下四项：

1. `Scripts/bootstrap.sh --check`：工程生成一致。
2. `Scripts/verify-licenses.sh`：许可证审计通过。
3. `git diff --check`：无空白错误。
4. 针对本次 diff 与 Task 21 生产路径的静态检索：没有新增旧 authorization／manual rendition ingress／helper-only endpoint 双轨 API，没有新增生产 `Task.yield`，Controller 没有硬编码 `rateZero: true`；两个 Review 3 目标测试文件无 `XCTSkip` 或 `XCTExpectFailure`。

本轮没有运行任何整类或全量 suite，没有运行真机或 HomePod 验收，也没有进入 Task 22。报告只记录 Review 3 冻结合同的实现与证据，仍交由根代理裁决；不自行把 Task 21 标记为完成。

## Review 4 最终收口

日期：2026-09-11

基线：`500abb3`

### 最终复审问题与生产修复

Review 4 把剩余 Critical／Important 风险集中为三组，并一次性闭合：

1. AAC writer 将 endpoint authority 的校验、claim、binding 构造与 terminal seal／failure 收拢到同一 writer lane 状态机。失败会原子锁定终态，并发 loser 不能覆盖；兼容 receipt 入口也只能执行同一原子流程，不能再旁路 claim 或留下 pending binding。
2. `BackendPositiveRateInvocation` 不再长期复制完整 source task 与 interval，只保存 nonce、冻结 activation 和 Registry capability。调用方通过可失败的 `currentSnapshot` 在原 Registry transaction 内同时核验 output permit、完整 activation、suspend／owner、backend／lifecycle、record phase、result invalidation 与 safety snapshot；撤权或关闭 interval 后返回 `nil`，不会崩溃或泄露已失效权威。`OutputPlayerStopTask` 也不再重复持有完整 item，而由 coordinator 在领取结果时传入当前 item 并复验 lifecycle。
3. Loopback publication binding、selection capability 与 timeline authority 全部冻结 `OutputLifecycleEpoch`。AAC、AC-3 与 E-AC-3 即使复用同一 generation，只要跨 output lifecycle，就不能读取旧 playlist／init／media、选择旧 rendition 或取得 timeline readiness。

### RED 与集中返修证据

- 首次最终 23 项集合：`/tmp/VPlayer-task21-final23-01.xcresult`，23 项实际执行，15 项通过、8 项失败；失败集中在跨 lifecycle 压缩音频夹具与 retained graph 容量。
- retained graph 诊断：`/tmp/VPlayer-task21-breakdown-diag1.xcresult`，旧实现实测 2272 字节，超过 2048 字节上限；没有通过提高上限或漏记对象绕过。
- AAC authority 并发失败 RED：`/tmp/VPlayer-task21-writer-finalA-red2.xcresult`；修复后定向结果 `/tmp/VPlayer-task21-writer-finalA-green2.xcresult` 为 4/4 通过。
- AC-3／E-AC-3 跨 lifecycle 定向结果：`/tmp/VPlayer-task21-C-compressed-lifecycle-green5.xcresult`，2/2 通过。

### 最终 GREEN 与容量证据

测试平台为 Apple TV 4K（第 3 代）tvOS 26.2 Simulator、arm64；启用并行测试基础设施并限制为一个 worker，仅运行冻结目标：

- 容量相关集合：`/tmp/VPlayer-task21-reviewB-final2.xcresult`，9/9 通过。
- 完整 current snapshot 谓词定向回归：`/tmp/VPlayer-task21-authority-snapshot-final1.xcresult`，4/4 通过。
- 最终组合集合：`/tmp/VPlayer-task21-final23-03.xcresult`，23/23 通过，0 failure、0 expected failure、0 skip。

allocator 实测 retained graph 的常见安装路径为 2000 字节，较长 URL 路径为 2016 字节，均不超过 2048 字节；其中 coordinator 根对象 496 字节、stop task 64 字节。capability 与 receipt 加 replacement fence 属于互斥生命周期尾部，账本按真实峰值预留，同时单独计入会与两者重叠的 stop task。

### Review 4 静态门禁与范围

提交前重新执行 `git diff --check`、`Scripts/bootstrap.sh --check` 与 `Scripts/verify-licenses.sh`，均通过。Task 21 生产路径没有旧 authorization／manual rendition ingress、helper-only endpoint 双轨 API、生产 `Task.yield` 或 Controller 硬编码 `rateZero: true`；目标测试没有 `XCTSkip` 或 `XCTExpectFailure`。

本轮没有运行全量或整类 suite，没有运行真机、AirPlay 或 HomePod 验收，也没有进入 Task 22。模拟器结果只证明 Task 21 的 AVPlayer／Loopback 生产合同，不冒充物理链路最终验收。

2026-09-11 补充：上述 GREEN 是最终独立审查前的测试检查点。Astra 复核正在核实 replacement slot 锁的容量归属和清理后重复 stop 的终态领取合同；在问题闭合前，Task 21 仍处于审查中。
