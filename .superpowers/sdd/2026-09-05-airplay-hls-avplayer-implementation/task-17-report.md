# Task 17 实施报告

## 基线与范围

- 基线提交：`1ed060e6b300ff4f8fd94412fbcac02fa4d1a137`
- 工作树：`/Users/daniel/git/VPlayer/.worktrees/airplay-hls-avplayer`
- 开始状态：干净。
- tvOS 模拟器：`Apple TV 4K (3rd generation)`，UUID `66388132-B4CD-4089-81A6-F84D94BE3A73`。
- 已完整复读 Task 17 简报、实施计划 Task 17、设计 §7.4/§7.5、平台 API 核查，以及 Task 11/13/15/16 的指定生产依赖。
- 明确不实现：Task 18 最终 fMP4 parser/validation、Task 19 publisher/store/playlist、Task 20 HTTP、Task 21 AVPlayer/真机闭环。

## TDD 状态

- 当前阶段：19 个方法的完整 `SegmentedFMP4WriterTests` 测试矩阵已一次性落盘；尚未运行 RED，尚未修改生产代码。
- 系统 writer 配置：四种轨道各自独立的单 input HLS writer、强 delegate、真实短视频/短 AAC 的 init/media callback 与盒子标记。
- 边界算法：音视频 IDR 前 flush、AAC/AC-3/聚合 E-AC-3 的首个完整 AU、纯音频一秒网格、trim 后有效 epoch 起点。
- callback 身份与容量：同步/异步/乱序/慢 callback、duplicate/stale/wrong writer/wrong sequence/wrong kind、软硬字节上限、未发布段 4/8 水位。
- ownership 终态：start/readiness/append/flush/finish/cancel/late callback，AC-3 单 lease 与 E-AC-3 六 lease 的 writer one-shot claim 及 terminal release，身份 mutation 全矩阵与析构释放。
- AAC endpoint：单 buffer/多 buffer、P/Q/L/T checked 等式、trim attachment、输入与 callback 身份替换、one-shot receipt。

### 统一 RED

- 原简报记录的模拟器 UUID `66388132-B4CD-4089-81A6-F84D94BE3A73` 已从本机消失；第一次命令在构建前被 destination 校验拒绝，未编译任何测试，基础设施结果为 `/tmp/VPlayer-task17-red-20260909-01.xcresult`。
- 唯一有效 RED 使用同型号当前 UUID `B188D2F9-B576-4C58-B68B-5B4333EAB0F2`；19 个测试方法均因目标生产接口尚不存在而未构建，编译器集中报告 24 条 `cannot find type in scope`。
- RED 结果：失败（构建失败），结果包 `/tmp/VPlayer-task17-red-20260909-02.xcresult`，完整日志 `/tmp/VPlayer-task17-red-20260909-02.log`。
- 系统 writer 配置：缺少 `SegmentedFMP4Writer`、系统 writer factory/writing/callback/configuration 适配层。
- 边界算法：缺少 `SegmentBoundaryCoordinator` 及轨道/AU/append action 类型；因 Swift 模块发射先在共用 helper 的缺失类型终止，未继续逐方法发出重复诊断。
- callback 身份/容量：缺少 binding、ticket、delivery、relay、sealed object 与容量策略类型。
- ownership 终态：缺少 input ownership、terminal receipt/failure 与压缩音频 one-shot writer claim 接线。
- AAC endpoint：缺少 writer 输入快照、P/Q/L/T checked receipt 及 one-shot endpoint claim。
- 共同根因：Task 17 尚无生产文件，测试矩阵引用的五类接口均不存在；不是既有 Task 11/13/15/16 行为失败。

## 集中实现

- `SegmentedFMP4Writer` 为每个轨道建立独立系统 writer；生产适配层真实使用 `AVAssetWriter(contentType: .mpeg4Movie)`、`.mpeg4AppleHLS`、`.indefinite` 与一个带精确 `sourceFormatHint` 的 passthrough input。writer bundle 强持有系统适配器和 delegate，delegate 仅弱引用 callback sink，避免环。
- start/readiness/append/flush/mark-finished/finish/cancel 全部经过 writer 专属 serial lane；relay 与 ownership 状态只在本地短锁中登记，不在锁中等待其他 rendition 或 publication。
- `SegmentBoundaryCoordinator` 独立维护共同逻辑序号：音视频按 1—2 秒 IDR、重编码按精确 1 秒 closed GOP，纯音频按 `T_e+i 秒`；AAC、AC-3 与聚合 E-AC-3 只在完整 AU 的允许误差窗前 flush。
- `SegmentReportRelay` 使用固定 ticket 槽、单调 ticket、writer bytes/segment 软硬水位与独立的 4/8 unpublished 水位；旧 generation、重复或 identity 不匹配 callback 只释放自己的预留，不生成对象。
- `SealedMediaObject` 在 callback 入口先以 `NSData.length` 做硬上限判断，再复制成独立 immutable backing，并冻结 binding、ticket、logical sequence、kind、range、SHA-256 与 report identity。
- 普通输入、AAC epoch backing 与 Task 16 AC-3/E-AC-3 writer submission 都保留到 writer terminal；压缩 submission 先逐字段验证并 one-shot claim，terminal 后才调用原 coordinator 恰好释放对应一张或六张 lease。
- AAC endpoint receipt 只从同一 epoch buffer identity/payload digest/trim snapshot、同一 immutable init/media callback 对象、同一 writer terminal receipt 与显式 `WriterTimelineMapping` 签发；`P = Q-L-N` 使用 checked integer，成功 receipt 为 one-shot。

## GREEN 与执行诊断

- 集中实现后的第一次原失败集合复跑先收齐 8 条生产编译诊断；统一修正 AVAssetWriter SDK throwing/sendability、guard 中 throwing expression 与 CF cast。结果包：`/tmp/VPlayer-task17-green-original-20260909-01.xcresult`。
- 第二次复跑收齐 4 条测试 fixture 编译诊断；统一修正 async `await`、弱引用声明、`@Sendable` collector 与 closure 类型推断。结果包：`/tmp/VPlayer-task17-green-original-20260909-02.xcresult`。
- 第三次原集合运行：19 个方法中 16 通过、3 失败；共同根因为 relay generation 迁移错误约束 writer identity、readiness failure 未签失败终态、E-AC-3 授权 fixture 错用 1-block 而非完整 6-block timeline AU。结果包：`/tmp/VPlayer-task17-green-original-20260909-03.xcresult`。
- 精确复跑上述 3 个失败方法：3/3 通过、0 失败、0 跳过。结果包：`/tmp/VPlayer-task17-green-failures-20260909-04.xcresult`。
- 首次整类确认在 test host 运行阶段停滞，结果包 `/tmp/VPlayer-task17-green-class-20260909-05.xcresult` 未完成，保留为 hang 诊断。重启模拟器后二分：前 10 个方法 10/10 通过（`/tmp/VPlayer-task17-hang-a-20260909-06.xcresult`），后 9 个方法 9/9 通过（`/tmp/VPlayer-task17-hang-b-20260909-07.xcresult`）。
- 第二次整类确认复现 async waiter 停滞；进程采样 `/tmp/task17-hang08.sample` 证明 XCTest 等待未完成 async 测试。根因是测试用 `Task.yield()` 误当 finish-request 屏障，可能在 fake 注册 completion 前丢失完成注入；改成显式 semaphore 握手。未完成结果包：`/tmp/VPlayer-task17-green-class-20260909-08.xcresult`。
- 精确挂起方法复跑：1/1 通过，结果包 `/tmp/VPlayer-task17-green-hang-method-20260909-09.xcresult`。
- 最终 `SegmentedFMP4WriterTests` 整类：19/19 通过、0 失败、0 跳过；Swift/C warnings-as-errors 开启。结果包：`/tmp/VPlayer-task17-green-class-20260909-10.xcresult`。
- 最小既有并集：timeline checked rational mapping、视频原 backing、AAC 系统 segment callback、AC-3 direct backing/lease、E-AC-3 六成员聚合，共 5/5 通过。结果包：`/tmp/VPlayer-task17-green-minimal-20260909-11.xcresult`。

## 真实系统证据与边界

- 最终整类中真实短 H.264 passthrough 与真实校准后 AAC epoch 都由真实 `AVAssetWriter` 产生 initialization/media callback；分别识别 `ftyp`/`moov` 与 `moof`/`mdat`，并保留 report identity。fake 只用于同步/异步顺序、readiness、失败、延迟 callback 与 finish 竞态。
- 本任务没有把裸 init+media 当成 AVPlayer 已执行 AAC 尾裁剪的证据；endpoint receipt 仅证明待发布对象声明的 `B_e+N/48000`。完整 box/timeline validation 属于 Task 18，publisher/store/playlist 属于 Task 19，HTTP 属于 Task 20，真实 AVPlayer/真机闭环属于 Task 21。

## 静态门禁与未运行范围

- `git diff --check`：通过，无输出。
- `plutil -lint VPlayer.xcodeproj/project.pbxproj`：`OK`。
- `Scripts/bootstrap.sh --check`：通过，XcodeGen 生成结果一致。
- `Scripts/verify-licenses.sh`：通过，无输出。
- 在最终 callback acceptance 修改及最终测试之后再次执行上述四项门禁：均以退出码 0 通过；`plutil` 输出 `OK`，bootstrap 输出 `1 package up to date`，其余无输出。
- 未运行完整 `VPlayerTests`、无关 Task 15/16 测试、HomePod/Apple TV 真机、playlist、HTTP 或 AVPlayer 回环。

## 精确文件范围

- `Sources/VPlayerPlayback/HLS/SegmentedFMP4Writer.swift`
- `Sources/VPlayerPlayback/HLS/SegmentBoundaryCoordinator.swift`
- `Sources/VPlayerPlayback/HLS/SegmentReportRelay.swift`
- `Sources/VPlayerPlayback/HLS/SealedMediaObject.swift`
- `Tests/VPlayerTests/Playback/HLS/SegmentedFMP4WriterTests.swift`
- `VPlayer.xcodeproj/project.pbxproj`

报告本身位于 ignored scratch 路径，不进入提交。

## 提交结果

- 提交：`7c975f0eb3af609b4d3f4541d3a7f8ba53fb185c`
- 提交信息：`feat(hls): 按轨写入有界 fMP4 分段`
- 提交包含上述精确 6 个文件，共新增/修改 3,182 行。
- 提交后 `git status --short` 无输出；仅 `.superpowers/` 报告目录与既有 `Vendor/FFmpeg/Artifacts/` 在 `--ignored` 视图中出现，没有未提交 tracked/untracked 文件。

## 正式审查返修（基线 `7c975f0eb3af609b4d3f4541d3a7f8ba53fb185c`）

### 初版 19/19 仍不足的原因

- 初版允许通用 `CMSampleBuffer + SegmentBoundaryAppendAction` 入口；调用方能绕过 Task 13 视频输出身份、Task 16 压缩音频 claim 与共同边界，并能构造、复用或跨 writer 搬运 action。
- 压缩音频在 writer 状态、ticket、容量和系统 readiness 预检前 claim；后续失败会错误处置已经 transfer 的 lease。
- 系统 append、pending ownership、cancel 与本地终态分属不同线性化路径；失败 receipt 不证明真实系统 writer 已 cancel/terminal。
- finish 只等待 media callback，cancel 不领取 continuation；callback 身份或容量拒绝也没有统一终结 candidate。
- AAC endpoint 接受裸 timeline delta，且输入/callback 完整性、report/format/range/digest/timing 与 one-shot 并发领取证据不足。
- 初版没有覆盖 closed-GOP 中间普通帧、actual callback 累计硬上限、唯一 unpublished lease、固定窗口/三 rendition/128 AU/checked sequence，以及细 timescale 的半开 AU 窗口和 sealed bytes 零重复切片。

### 一次性返修回归矩阵

- 已一次性新增 9 个行为方法，总目标类由 19 个增至 28 个；生产代码尚未修改。
- typed 授权：真实 `HLSVideoEncodedOutput`、cross-writer、sample mutation、ticket replay 与超 2 秒序列。
- claim 顺序：错误 ticket、已终态、writer hard cap、not-ready 均断言 system append 为 0、claim 为 0、lease/bundle 未变。
- writer lane/终态：append failure 必须真实 cancel；压缩 lease 只在真实 terminal 后释放；阻塞 append 与并发 cancel 确定顺序。
- finish/callback：finish↔cancel、finish completion 与 init/media 乱序、actual callback 超限、callback writer identity 错误、迟到/重复终态。
- AAC endpoint：mapping 只能由 writer callback report 产生；拒绝 subset、duplicate、同 binding 替换、额外输入与 PTS mutation；并发 one-shot 仅一个成功，receipt 只暴露定长摘要事实。
- 边界：重编码首 IDR 后 `1/30…<1s` 普通帧合法，恰 1 秒必须 IDR，早 IDR 与超时 IDR 失败；passthrough 既有 `[1,2]` 矩阵保留。
- 容量：projected 值不再由 caller 输入；actual callback 接近/超过 hard cap、三段累计；unpublished lease 绑定 relay+logical sequence 且 wrong/double release 失败。
- 有界状态：第 4 rendition、第 129 AU、sequence allocator 上溢失败；长播共同边界只保留固定窗口和最后序号。
- 额外边界：audio AU 直接检查 `start < boundary + duration`；sealed object 的 `bytes` 与冻结 backing 共用同一存储。

### 正式审查统一 RED

- 唯一统一 RED 命令只选 `SegmentedFMP4WriterTests`；结果为 build failure，0/28 方法执行、1 个目标构建失败，生产代码在 RED 前没有改动。
- 结果包：`/tmp/VPlayer-task17-review-red-20260909-12.xcresult`；完整日志：`/tmp/VPlayer-task17-review-red-20260909-12.log`。
- typed 授权：缺少 `issueVideoAppend`、`issueAACAppend`、`issueCompressedAudioAppend` 与 `appendVideo`，旧压缩/AAC API仍要求 caller action/estimated bytes。
- writer lane/终态：`finish` 仍要求 caller 估值；callback fatal/finish-cancel 的期望异步路径尚不存在。
- callback/容量：unpublished API 仍返回裸 `Bool` 且无 logical sequence lease；actual callback 与 writer sealed ledger 尚未闭合。
- bounded ledger：缺少 rendition capacity failure、固定窗口 usage、checked `SegmentSequenceAllocator` 和 128 input evidence failure。
- AAC mapping/endpoint：endpoint 仍要求裸 `WriterTimelineMapping`，receipt 缺固定 input/callback 摘要与 mapping report identity。
- 共同根因：初版 19/19 只验证了可由调用方提供的 action/estimate/mapping，没有不可伪造 typed ticket、真实 system terminal 线性化与固定容量证据；本轮 RED 是期望接口缺失，不是 Task 11/13/15/16 回归。

### 正式审查集中重构

- typed 授权：删除 writer 的通用 sample append 入口以及可构造 action；`SegmentBoundaryCoordinator` 只针对真实 `HLSVideoEncodedOutput`、AAC `CMSampleBuffer` 或 Task 16 `CompressedAudioAccessUnit` 签发一次性 ticket。ticket 绑定完整 writer binding、轨道、逻辑序号、flush 决策、sample/format/PTS，以及视频 Task 13 身份或压缩音频 admission/range/digest。writer 只保留 `appendVideo`、`appendAACEncodedEpoch` 与 `appendCompressed` 三类 typed 入口，无 flush 的 ticket 必须与 writer 当前序号完全相等，不能跳段。
- writer lane 与终态：状态、readiness、pending callback、ownership、系统 append/flush/finish/cancel 全在同一可重入 serial lane 内线性化。不可变 sample/format/ticket/capacity/readiness 预检全部先于 claim；claim 后失败以及系统 readiness/append/flush、callback fatal、finish 容量失败均先取消真实系统 writer，再签唯一终态并释放资源。finish continuation 在 finish、cancel、callback rejection 与重复/迟到 terminal 中恰好领取和恢复一次。
- callback 与容量：caller 不再提供 estimate；writer 从 sample payload 加固定 checked overhead 推导 projected charge。relay 原子地把 callback actual bytes 从 writer backlog 转入 sealed-object ledger；超 hard cap 为 fatal。media callback 自动产生绑定 relay 与 logical sequence 的一次性 unpublished lease，错误 relay、错误序号或重复释放均失败关闭。
- 有界 ledger：共同边界只保留 4 项窗口，rendition 最多 3 个，单段 input/ownership 最多 128，pending callback 最多 3，unpublished 最多 8。计数、sequence 与 byte charge 使用 checked 算术；每段 ownership 随对应 media callback reservation 冻结并在该段 callback 终结时释放，长播只保留累计计数、rolling digest 与最后序号。
- AAC mapping/endpoint：删除 caller-supplied `WriterTimelineMapping`。mapping 只由该 writer 接受的真实系统 media report 的 earliest PTS 生成并绑定 report identity；endpoint 在 writer lane 内原子 one-shot，复验同一 encoder epoch 的有序完整输入摘要、format/payload/timing/packet/trim、完整 init/media callback 摘要、binding/report/backing 与 P/Q/L/T checked 等式。terminal 与 endpoint receipt 均只含固定大小摘要，不暴露历史数组。
- 边界修正：重编码 closed-GOP 接受首 IDR 后 `<1s` 普通帧，恰 1 秒只接受 IDR，早 IDR 与超时均失败；音频使用半开区间 `start < boundary + AU duration`；`SealedMediaObject.bytes` 通过 `_read` 直接借用冻结 backing，不再按访问创建 `subdata`。

### 正式审查 GREEN

- 原失败集合第一次编译（9 个新增方法）在生产模块集中报告 1 个缺失 payload identity 类型及其 `Hashable/Equatable` 连带错误，结果包 `/tmp/VPlayer-task17-review-green-original-20260909-13.xcresult`。
- 第二次编译只剩 warnings-as-errors 下 1 个 CFDictionary 强转诊断，结果包 `/tmp/VPlayer-task17-review-green-original-20260909-14.xcresult`；第三次编译只剩测试内 2 个 async autoclosure 机械诊断，结果包 `/tmp/VPlayer-task17-review-green-original-20260909-15.xcresult`。
- 首次进入行为层：新增 9 个方法中 6 通过、3 失败；失败分别为 finish 容量拒绝未 cancel、wrong-writer fixture 同时改变 rendition 而未能签票、4-byte `Data` inline 存储不能作为共享 heap backing 的指针 oracle。结果包 `/tmp/VPlayer-task17-review-green-original-20260909-16.xcresult`。
- 集中修复后精确复跑 3 个失败方法：2 通过、1 个 inline backing oracle 失败，结果包 `/tmp/VPlayer-task17-review-green-failures-20260909-17.xcresult`；改用 64-byte 堆 backing 后该方法 1/1 通过，结果包 `/tmp/VPlayer-task17-review-green-failures-20260909-18.xcresult`。因此统一 RED 对应的 9 个原失败方法最终 9/9 通过。
- 第一次目标整类确认执行 28 个方法，27 通过、1 个旧边界方法失败；失败原因是第 4 个无效 E-AC-3 rendition 先命中容量而非 codec 语义错误，同时 Xcode 的额外并行 clone 出现一次模拟器 launch 拒绝。结果包 `/tmp/VPlayer-task17-review-green-class-20260909-19.xcresult`。调整无副作用校验顺序后，原失败方法 1/1 通过，结果包 `/tmp/VPlayer-task17-review-green-old-failure-20260909-20.xcresult`。
- 关闭并行 clone 后目标整类 28/28 通过、0 失败、0 跳过，结果包 `/tmp/VPlayer-task17-review-green-class-20260909-21.xcresult`；直接受影响的 Task 11/13/15/16 最小既有并集 5/5 通过，结果包 `/tmp/VPlayer-task17-review-green-minimal-20260909-22.xcresult`。
- 提交前静态审计进一步发现 ownership 虽受单段输入上限保护、但初版仍到整个 writer terminal 才清空；改为随每个 media reservation 冻结和释放，并补强 claim 竞态失败及无 flush 序号跳跃的失败关闭。最终目标整类再次 28/28 通过，结果包 `/tmp/VPlayer-task17-review-green-class-20260909-23.xcresult`；最终最小既有并集再次 5/5 通过，结果包 `/tmp/VPlayer-task17-review-green-minimal-20260909-24.xcresult`。
- 最后静态审计把 relay 接受的真实 backing identity、range、digest 与 report identity 固化成定长 callback acceptance evidence；writer 在同一 lane 冻结该证据，AAC endpoint 逐项匹配，因此“复用同一 report 与相同 bytes、但替换 backing”的同 binding 对象也失败关闭。受影响方法 3/3 通过，结果包 `/tmp/VPlayer-task17-review-green-affected-20260909-25.xcresult`（命令中的一个旧方法名未匹配，随后由整类覆盖）。
- 最终目标整类再次 28/28 通过、0 失败、0 跳过，包含真实短 H.264 与短 AAC 的系统 init/media callback，结果包 `/tmp/VPlayer-task17-review-green-class-20260909-26.xcresult`；最终最小既有并集再次 5/5 通过，结果包 `/tmp/VPlayer-task17-review-green-minimal-20260909-27.xcresult`。两批均启用 Swift warnings-as-errors。
- 最小既有并集精确方法：Task 15 真实 AAC HLS init/media callback、Task 16 AC-3 原 backing、Task 16 E-AC-3 六成员聚合、Task 11 timeline checked rational、Task 13 视频原 Annex-B backing，共 5 个方法。

### 正式审查静态门禁与剩余边界

- `git diff --check`：通过，无输出。
- `plutil -lint VPlayer.xcodeproj/project.pbxproj`：通过，`OK`。
- `Scripts/bootstrap.sh --check`：通过，`1 package up to date`。
- `Scripts/verify-licenses.sh`：通过，无输出。
- 最终仍未运行完整 `VPlayerTests`、无关 Task 15/16 测试、HomePod/Apple TV 真机、Task 18 parser/box validation、Task 19 publisher/store/playlist、Task 20 HTTP 或 Task 21 AVPlayer 回环。
- 真实系统证据仍由目标整类内的短 H.264 与短 AAC 测试通过真实 `AVAssetWriter` 产生 init/media callback；fake 仅覆盖可控时序、容量与失败交错。
- 当前剩余风险限于后续任务边界：Task 18 尚未验证完整 fMP4 box/timeline，Task 19 尚未消费 unpublished lease；本提交没有提前实现这些能力。

### 正式审查返修提交

- 提交：`b823b82e5f8a2a732012114b572982c023ab877d`
- 提交信息：`fix(hls): 收紧分轨 writer 授权与终态`
- 精确提交 5 个文件，共新增 2,378 行、删除 672 行；报告为 ignored scratch，未进入提交。
- 提交后 `git status --short` 无输出。

## 正式审查第二轮返修（基线 `b823b82e5f8a2a732012114b572982c023ab877d`）

### 一次性回归矩阵与统一 RED

- 本轮先一次性增加 7 个行为方法，目标类由 28 个增至 35 个；统一 RED 前仅修改测试，没有修改生产代码。
- `testBoundarySessionRejectsForgedIssuerRenditionAndPostIssueMutationAndAbortsFailedAppend`：覆盖正式 session issuer、多轨共享、伪造 issuer/rendition、签票后 sample mutation、失败 append abort 后重试。
- `testCompressedWriterUsesFrozenFormatConfigurationBeforeTask16Claim`：覆盖 writer 构造时冻结的 Task 16 受信配置以及 claim 前 codec/rate/channel/layout/config box 全量复验。
- `testAACEndpointDerivesCountsOrderingAndTrimPlacementFromActualBuffers`：覆盖从有序实际 buffer 推导 N/Q/L/P、首尾 trim 唯一性、连续性与 caller 整数不可作为信任根。
- `testSegmentCallbackReleasesBacklogButRetainsAC3AndEAC3OwnershipUntilTerminal`：覆盖 callback 只释放 writer backlog，AC-3/E-AC-3 ownership 保留到真实 terminal。
- `testAACBatchAndCallbackCASAccountWholeProjectedAndRemainingBacklog`：覆盖 AAC whole-batch running projected sum，以及 callback 以 remaining backlog + sealed + actual 在同一 CAS 计费。
- `testPublicationSinkReentrantCancelObservesFullyCommittedCallbackState`：覆盖 relay 内部接纳/ledger/terminal commit 先于 writer lane 外发布，sink 重入 cancel 观察到完整状态。
- `testSlowInitializationUsesIndependentSlotFromThreeMediaReservations`：覆盖 init 独立固定控制/字节槽；慢 init 时允许 3 个 media reservation，第 4 个失败关闭。
- 唯一统一 RED 命令只选择 `SegmentedFMP4WriterTests`；结果为 build failure，7 个新增方法均未进入执行，共 14 条编译诊断。
- 失败分为五个共同根因：缺正式 boundary session/事务；writer 未冻结压缩配置且仍接受 caller `expectedIdentity`；AAC endpoint 仍接受 caller `claim`；缺 terminal ownership 使用量/生命周期；callback 重入所需的提交后发布接口尚未接线。
- 结果包：`/tmp/VPlayer-task17-review2-red-20260909-01.xcresult`；完整日志：`/tmp/VPlayer-task17-review2-red-20260909-01.log`。

### 第二轮集中实现

- 正式边界授权改为 `SegmentBoundarySession` 与一次性事务 ticket：writer 构造时冻结唯一 session；ticket 绑定 writer/rendition/track/sequence/flush、视频 IDR 与 payload backing/digest、AAC format/payload/timing，以及压缩音频 codec/rate/channels/sample-count/config/admission/range/digest/PTS。签发只预留状态，系统 append 成功后才提交；预检、claim 或 append 失败均 abort，不提前推进正式共同边界。
- 压缩 writer 构造时冻结真实 `CompressedAudioFormatConfiguration`，并在 Task 16 claim 前逐字段验证 AU 与 `dac3/dec3` 序列化配置；删除 caller `expectedIdentity` 参数。AAC endpoint 删除 caller 四元组 claim，改为从实际有序 buffer 的 packet sample-count、duration、trim attachment、format、payload 与 PTS 连续性推导并冻结 N/Q/L/P。
- writer projected backlog 与 source ownership 分账：media callback 仅关闭 projected reservation，视频/AAC/AC-3/E-AC-3 ownership 保留到真实 finish/cancel/failure terminal；terminal ownership 使用固定 384 槽，任何溢出均在系统副作用前显式失败。
- AAC 批量预检使用 checked running projected sum；relay 在同一 CAS 验证 `remaining backlog + media sealed + actual` 后才提交 sealed ledger，fatal callback 不留下部分 sealed mutation。初始化对象使用独立 1 MiB 字节槽，且不占 media 的 3 个 reservation。
- relay 接纳与外部 publication 分离：writer 先在自身 lane 内移除 pending、记录 callback evidence/终态，再由独立串行 publication queue 调用 sink；重入 cancel/finish 只能观察完整提交后的状态。

### 第二轮 GREEN

- 新增失败集合首次进入行为层：7 个方法中 5 个通过、2 个失败；共同根因分别为 AAC fixture 的后续输出 PTS 未包含首 trim，以及第二个 AC-3 AU 错误复用 Task 16 单 interval authorization。结果包 `/tmp/VPlayer-task17-review2-green-new-20260909-04.xcresult`。
- 精确复跑原 2 个失败方法后 AAC 已通过，AC-3 ownership fixture 仍失败，结果包 `/tmp/VPlayer-task17-review2-green-failures-20260909-05.xcresult`；改为第二个 AU 使用独立真实 Task 16 授权后，该方法 1/1 通过，结果包 `/tmp/VPlayer-task17-review2-green-failures-20260909-06.xcresult`。统一 RED 对应新增方法最终 7/7 通过。
- 首次整类为 32/35：第 129 AU fixture 在到达 writer 固定容量前预留了状态 mutation；system flush failure fixture 重复登记同一 AAC rendition；压缩 track bundle fixture 缺构造时冻结配置。结果包 `/tmp/VPlayer-task17-review2-green-class-20260909-07.xcresult`。三项集中修复后的原失败方法 3/3 通过，结果包 `/tmp/VPlayer-task17-review2-green-old-failures-20260909-08.xcresult`。
- 集中修复后整类 35/35 通过，结果包 `/tmp/VPlayer-task17-review2-green-class-20260909-09.xcresult`。提交前自审继续收紧 fatal callback 原子 ledger、terminal ownership 固定上限与 init 独立控制槽后，整类仍为 35/35，结果包 `/tmp/VPlayer-task17-review2-green-class-20260909-10.xcresult`。
- 最终关闭并行 clone 后，`SegmentedFMP4WriterTests` 35/35 通过、0 失败、0 跳过，Swift/C warnings-as-errors 开启；其中真实短 H.264 与真实短 AAC 均由 `AVAssetWriter` 产生 initialization/media callback。结果包 `/tmp/VPlayer-task17-review2-green-class-20260909-12.xcresult`。
- 直接依赖最小既有并集 5/5 通过、0 失败、0 跳过：Task 15 真实 AAC HLS callback、Task 16 AC-3 原 backing、Task 16 E-AC-3 完整聚合、Task 11 checked rational timeline、Task 13 原 Annex-B backing。结果包 `/tmp/VPlayer-task17-review2-green-minimal-20260909-11.xcresult`。

### 第二轮静态门禁与未运行范围

- `git diff --check`：通过，无输出。
- `plutil -lint VPlayer.xcodeproj/project.pbxproj`：通过，`OK`。
- `Scripts/bootstrap.sh --check`：通过，`1 package up to date`。
- `Scripts/verify-licenses.sh`：通过，无输出。
- 未运行完整 `VPlayerTests`、无关 Task 15/16 方法、HomePod/Apple TV 真机、Task 18 parser/box validation、Task 19 publisher/store/playlist、Task 20 HTTP 或 Task 21 AVPlayer 回环。
- 当前剩余风险仅是后续任务边界：本轮 receipt 证明 writer 内部授权、callback 与 ownership 事实；完整 fMP4 box/timeline 仍由 Task 18 验证，unpublished lease 的持久化与发布仍由 Task 19 实现。

### 第二轮精确文件范围

- `Sources/VPlayerPlayback/HLS/SegmentBoundaryCoordinator.swift`
- `Sources/VPlayerPlayback/HLS/SegmentReportRelay.swift`
- `Sources/VPlayerPlayback/HLS/SegmentedFMP4Writer.swift`
- `Tests/VPlayerTests/Playback/HLS/SegmentedFMP4WriterTests.swift`
- 本报告位于 ignored scratch 路径，不进入提交。

### 第二轮返修提交

- 提交：`3492d8a21955eb1e422b06e3e2e89f2c8b771212`。
- 提交信息：`fix(hls): 闭合 writer 会话与回调账本`。
- 精确提交上述 4 个文件，共新增 1,473 行、删除 367 行；报告未进入提交。

## 第三轮限定返修（基线 `3492d8a21955eb1e422b06e3e2e89f2c8b771212`）

### 一次性回归矩阵与统一 RED

- 本轮先一次性新增 6 个行为方法，目标类由 35 个增至 41 个；统一 RED 前只修改目标测试文件，没有修改生产代码。
- inspection 隔离：视频与音频各重复 inspection 后，正式 session 首票的逻辑序号与 flush 决策必须和未 inspection 的 coordinator 完全相同。
- AAC 正式事务：覆盖 49 个 AU 在同一 epoch 内跨 1 秒边界、snapshot 失败后原 session 可立即复用、fresh coordinator 拒绝、第 48 次系统 append 失败只 abort 尚未提交的边界并能由新 writer 在同一序号重签。
- 压缩格式：AC-3/E-AC-3 source hint 均携带真实非空 `dac3/dec3` bytes；缺失 cookie 与末字节 mutation 必须在 system factory 和 Task 16 claim 前失败。
- bounded rollover：以可注入 1/2 ownership 阈值覆盖三个 writer 周期；每个旧 writer 到共同边界返回显式 rollover、真实 finish 后才释放 workspace，逻辑序号连续为 0/1/2。
- publication capability：覆盖 wrong relay、重复 consume、恶意 scheduler 重复执行同一 delivery body，以及 terminal close 后迟到 capability。
- 唯一统一 RED 在测试模块 emit 阶段停止：0/6 新方法执行，首个共同 helper 的缺失 `SegmentedFMP4WriterOwnershipLimits` 类型产生 1 条主诊断；模块发射因此没有继续重复报告其余期望接口。共同根因是生产代码尚无 rollover policy，且 AAC 内签、one-shot publication 与 cookie 绑定接口尚未实现。
- RED 结果包：`/tmp/VPlayer-task17-review3-red-20260909-01.xcresult`；完整日志：`/tmp/VPlayer-task17-review3-red-20260909-01.log`。

### 第三轮集中实现

- inspection 状态与正式 ticket 状态完全隔离：现有 inspection 顺序仍可观察边界算法，但只在独立副本推进；正式 session 只由系统 append 成功后的 ticket commit 推进。AAC writer 先在正式状态副本上预演整批边界，再在自身 lane 内逐 AU `issue -> preflight -> prepare -> system append -> commit`，不再接收调用方预签的 ticket 数组。snapshot、fresh coordinator、容量与 rollover 预检都发生在首张正式 ticket 前；第 N 次系统 append 失败只 abort 当前未提交 ticket，并通过真实系统 cancel 进入 terminal。
- 压缩 source hint 在 system factory 前读取 `CMAudioFormatDescriptionGetMagicCookie`，要求非空且逐字等于 Task 16 冻结配置的 `serializedBox`；相同 ASBD 但缺失或变异 `dac3/dec3` 均失败关闭。构造阶段失败的 writer 不再在 deinit 访问尚未创建的系统 writer。
- writer ownership 使用可注入的软 rollover／硬容量窗口；达到软阈值后只在下一个共同边界返回显式 `rolloverRequired`，不签票、不 flush、不 append。调用方可在旧 writer 真实 finish 后，用同一 boundary session 和新 writer identity 对未消费 AU 重签；旧 writer 的 source ownership 仅在真实 terminal 释放。
- callback acceptance 改为绑定 relay identity 的 opaque one-shot capability。relay 在固定容量表中保存待领取对象，writer 完成 callback ledger 后在自身 lane 内原子领取并投递到串行 publication queue；错误 relay、重复领取、重复执行调度 closure 与 terminal 后迟到领取都不会再次调用 sink。terminal 会撤销尚未领取的 capability，已经领取的任务仍保持 callback commit 先于外部 sink 的顺序。

### 第三轮 GREEN

- 集中实现后首次执行新增 6 方法：5 通过、1 个压缩 source 方法因“构造失败对象 deinit 访问尚未创建的 system writer”崩溃；结果包 `/tmp/VPlayer-task17-review3-green-attempt1-20260909.xcresult`。修复构造失败析构路径后，原失败方法 1/1 通过，结果包 `/tmp/VPlayer-task17-review3-green-failed-method-20260909.xcresult`。
- 新增 6 方法随后统一复跑 6/6 通过、0 失败、0 跳过，结果包 `/tmp/VPlayer-task17-review3-green-six-20260909.xcresult`。
- 直接受影响的 20 个既有方法首轮 19/20 通过；唯一失败是旧压缩配置 fixture 将 alternate configuration 与原 access unit 的 source cookie 混用，新的逐字绑定正确拒绝。结果包 `/tmp/VPlayer-task17-review3-green-direct-20260909.xcresult`。机械迁移时首次精确复跑暴露测试调用点误改的编译诊断，结果包 `/tmp/VPlayer-task17-review3-green-direct-failed-20260909.xcresult`；更正为 source hint 携带同一 alternate `dac3` 后，原失败方法 1/1 通过，结果包 `/tmp/VPlayer-task17-review3-green-direct-failed2-20260909.xcresult`。
- `SegmentedFMP4WriterTests` 最终整类 41/41 通过、0 失败、0 跳过，Swift/C warnings-as-errors 开启；其中真实短 H.264 与真实短 AAC 用例继续由系统 `AVAssetWriter` 产生 initialization/media callback。结果包 `/tmp/VPlayer-task17-review3-green-class-20260909.xcresult`。
- 实际修改接口的 Task 11/13/15/16 最小既有并集 5/5 通过、0 失败、0 跳过：Task 15 真实 AAC HLS callback、Task 16 AC-3 原 backing、Task 16 E-AC-3 完整聚合、Task 11 checked rational timeline、Task 13 原 Annex-B backing。结果包 `/tmp/VPlayer-task17-review3-green-minimal-20260909.xcresult`。

### 第三轮静态门禁、范围与风险

- `git diff --check`：通过，无输出。
- `plutil -lint VPlayer.xcodeproj/project.pbxproj`：通过，`OK`。
- `Scripts/bootstrap.sh --check`：通过，`1 package up to date`。
- `Scripts/verify-licenses.sh`：通过，无输出。
- 本轮精确修改 `SegmentBoundaryCoordinator.swift`、`SegmentReportRelay.swift`、`SegmentedFMP4Writer.swift` 与 `SegmentedFMP4WriterTests.swift`；报告为 ignored scratch，不进入提交。
- 未运行完整 `VPlayerTests`、无关 Task 15/16 测试、HomePod/Apple TV 真机、Task 18 完整 fMP4 box/timeline parser、Task 19 publisher/store/playlist、Task 20 HTTP 或 Task 21 AVPlayer 回环。
- 剩余风险严格位于后续任务边界：本轮 rollover 只提供共同边界上的显式 writer 交接合同，未实现 Task 19 的自动 writer 管理或发布；真实系统用例证明 callback 产生与身份闭合，不替代 Task 18 的完整 box/timeline 验证。

### 第三轮返修提交

- 提交：`906a693b64c5ef0202854d47f9f5205dc1505714`。
- 提交信息：`fix(hls): 隔离 writer 检查并闭合发布能力`。
- 精确提交 4 个文件，共新增 844 行、删除 179 行；本报告位于 ignored scratch 路径，未进入提交。
- 提交后 `git status --short` 无输出，工作树中的跟踪与普通未跟踪文件均为空。

## 第四轮限定返修（基线 `906a693b64c5ef0202854d47f9f5205dc1505714`）

### 范围与统一 RED

- 本轮唯一需求来源为 `task-17-review4-findings.md`，仅处理不透明 append-success authority、未领取 publication capability 的终态回滚、正式与 inspection accessor 分离。开始时 `git status --short` 无输出，分支为 `codex/airplay-hls-avplayer`。
- 一次性新增 4 个方法，目标类由 41 个增至 45 个：`testPreparedVideoTicketCannotCommitWithoutSuccessfulSystemAppend`、`testPreparedAudioTicketCannotAdvanceAudioStateBeforeWriterAppend`、`testClosePublicationsRollsBackOnlyUnclaimedInitializationAndMediaOwnership`、`testFormalBoundaryAccessorsFollowWriterCommitsAndIgnoreInspection`。
- 首次统一 RED：0 通过／4 失败／0 跳过。视频合法票据的无授权 `commit()` 返回 true，重签失去边界前 flush；未领取 init/media 关闭后仍有 83 bytes、2 个 unpublished 和被占用的逻辑序号；正式 accessor 在真实生产 writer 提交后仍停在 0。AAC 用例最初误取第 49 个 AU，提前命中边界窗口校验，尚未验证该方法的目标行为。
- 仅机械修正测试：AAC 改取首个跨 48,000-sample 边界的第 48 个 AU；sequence 回滚断言使用 `XCTAssertNoThrow`，使四种领取组合全部执行。同一个四方法目标集合补正 RED：0 通过／4 失败／0 跳过，AAC 的合法 prepared ticket 同样能无系统 append 直接 commit。两次 RED 之间以及补正 RED 完成前，生产文件均未修改。
- 两次结果包分别为 `/tmp/VPlayer-task17-review4-red-20260909.xcresult`、`/tmp/VPlayer-task17-review4-red-corrected-20260909.xcresult`；同前缀 `.log` 保存完整命令输出。失败均进入行为执行层，第二次四个方法均因目标根因失败。

### 集中实现与自审

- `SegmentedFMP4Writer.AppendSuccessAuthority` 的构造器为 `private`，唯一签发入口为 writer 实现文件内的 `fileprivate append`；该入口亲自调用准确 `systemWriter.append(sampleBuffer)`，仅返回 true 且 writer 未进入终态时创建 authority，不接受调用方声明的成功布尔值。普通同模块文件、coordinator、ticket 调用方和 `@testable` helper 均无法调用构造器或签发入口；测试没有授权构造后门。
- authority 冻结完整 writer binding、轨道、正式 session 实例、sample identity，以及准确 ticket 的强引用。ticket 的 transaction 为不可变私有字段，一张 ticket 唯一对应一个 transaction，因此准确实例绑定也锁定该 transaction，且不会因释放后复用地址而串票。消费在 authority 的锁内 one-shot，cross-writer、wrong session、wrong ticket/sample 与 replay 均拒绝；authority 只在 writer lane 的单次 append/commit 栈内存活，不进入历史集合、不暴露给外部。
- `ticket.commit(authority:)` 必须先消费匹配 authority 才能调用正式 coordinator commit。保留缺省 nil 仅用于显式拒绝无授权调用；`prepare` 本身只预留，失败 `commit` 不推进正式状态，`abort` 后同一边界可以重签。视频、AAC、AC-3/E-AC-3 三种入口集中调用同一私有 append/commit 路径；已有整类测试继续覆盖错 writer/session/sample、append failure、replay、重签与 terminal 交错。
- `closePublications` 在 relay 原锁内关闭 admission 并枚举仍未领取的对象：init 按准确 byte range 扣除初始化字节；media 消费该对象独有 lease，原子删除 unpublished entry、sequence 与相应 media bytes；最后清空 capability 表。共享私有释放函数先逐项验证再扣账，重复 close/release 不重扣。已领取并交给下游调度的对象不在该表中，保留原账；对应 media 仍由下游 lease 释放，已领取 init 的字节仍计费。
- relay usage 补充 capability 数、init/media 分别计费数。四种 init/media 已领取／未领取组合、已领取但尚未运行的调度、重复 close、迟到 consume、重复调度与 release 均检查准确账目；未领取 media 的序号也可重新预留，证明不是仅把可见计数清零。
- `commonBoundaries` 与 `usage` 返回正式 `boundaryWindow/videoOffset/audioStates`；算法测试明确使用 `inspectionCommonBoundaries` 与 `inspectionUsage`。新增回归在从未 inspection 时经生产 writer 连续提交 0/1/2，再让 inspection 独立走到 3，正式窗口始终保持 0/1/2；AAC 正式边界也验证 10/11 秒推进。
- 自审确认没有新的可构造授权入口、没有持久 authority 集合或引用环；close 与 consume 共用同一锁，先赢的一方唯一拥有对应对象的转交或回滚权；所有新增注释与本报告均为中文。

### 精确测试命令与 GREEN

以下参数数组展开后，与实际执行命令逐参数相同；每次均使用新结果包，未覆盖既有证据。模拟器经 `xcrun simctl list devices available` 确认为 tvOS 26.2 的 Apple TV 4K，UUID 为 `B188D2F9-B576-4C58-B68B-5B4333EAB0F2`。

```bash
task17_common=(test -quiet -project VPlayer.xcodeproj -scheme VPlayer
  -destination 'platform=tvOS Simulator,id=B188D2F9-B576-4C58-B68B-5B4333EAB0F2'
  -parallel-testing-enabled NO -derivedDataPath /tmp/VPlayer-task17-dd
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES)
task17_new=(
  -only-testing:VPlayerTests/SegmentedFMP4WriterTests/testPreparedVideoTicketCannotCommitWithoutSuccessfulSystemAppend
  -only-testing:VPlayerTests/SegmentedFMP4WriterTests/testPreparedAudioTicketCannotAdvanceAudioStateBeforeWriterAppend
  -only-testing:VPlayerTests/SegmentedFMP4WriterTests/testClosePublicationsRollsBackOnlyUnclaimedInitializationAndMediaOwnership
  -only-testing:VPlayerTests/SegmentedFMP4WriterTests/testFormalBoundaryAccessorsFollowWriterCommitsAndIgnoreInspection)
xcodebuild "${task17_common[@]}" -resultBundlePath /tmp/VPlayer-task17-review4-red-20260909.xcresult "${task17_new[@]}" > /tmp/VPlayer-task17-review4-red-20260909.log 2>&1
xcodebuild "${task17_common[@]}" -resultBundlePath /tmp/VPlayer-task17-review4-red-corrected-20260909.xcresult "${task17_new[@]}" > /tmp/VPlayer-task17-review4-red-corrected-20260909.log 2>&1
xcodebuild "${task17_common[@]}" -resultBundlePath /tmp/VPlayer-task17-review4-green-new-20260909.xcresult "${task17_new[@]}" > /tmp/VPlayer-task17-review4-green-new-20260909.log 2>&1
xcodebuild "${task17_common[@]}" -resultBundlePath /tmp/VPlayer-task17-review4-green-class-20260909.xcresult -only-testing:VPlayerTests/SegmentedFMP4WriterTests > /tmp/VPlayer-task17-review4-green-class-20260909.log 2>&1
xcodebuild "${task17_common[@]}" -resultBundlePath /tmp/VPlayer-task17-review4-green-minimal-20260909.xcresult \
  -only-testing:VPlayerTests/AACPrimingCalibratorTests/testHLSCalibrationUsesNamedStrongDelegateAndRealInitMediaEvents \
  -only-testing:VPlayerTests/CompressedAudioOriginTests/testAC3DirectAccessUnitPreservesExactInputBackingAtEveryPrimaryRate \
  -only-testing:VPlayerTests/EAC3AccessUnitAssemblerTests/testEveryLegalGroupingProducesOneOrdered1536SampleAccessUnit \
  -only-testing:VPlayerTests/HLSTimelineTests/testExactRationalPTSAndDTSPreserveCompositionOffsetAndRejectInvalidOrOverflowingInput \
  -only-testing:VPlayerTests/VideoAccessUnitBackingTests/testAssemblerPublishesOriginalAnnexBBackingAndDigestWithAccessUnit \
  > /tmp/VPlayer-task17-review4-green-minimal-20260909.log 2>&1
```

- 集中实现后新增四方法首次 GREEN：4/4 通过、0 失败、0 跳过，结果包 `/tmp/VPlayer-task17-review4-green-new-20260909.xcresult`。
- 最终 `SegmentedFMP4WriterTests` 整类：45/45 通过、0 失败、0 跳过，结果包 `/tmp/VPlayer-task17-review4-green-class-20260909.xcresult`。
- Task 11/13/15/16 直接依赖最小并集：5/5 通过、0 失败、0 跳过，结果包 `/tmp/VPlayer-task17-review4-green-minimal-20260909.xcresult`。三批均启用 Swift/C warnings-as-errors；通过数由 `xcrun xcresulttool get test-results summary --path <结果包>` 核对。
- 新增时序/所有权回归调用真实生产 coordinator、writer、relay；可控 system 边界使用既有窄 fake。整类保留的短 H.264 与短 AAC 用例，以及最小依赖的 AAC 用例，仍由真实 `AVAssetWriter` 产生 init/media callback，不以 fake 替代这部分系统证据。

### 静态门禁、精确文件与剩余边界

- `git diff --check`：通过，无输出。
- `plutil -lint VPlayer.xcodeproj/project.pbxproj`：通过，`OK`。
- `Scripts/bootstrap.sh --check`：通过，`1 package up to date`。
- `Scripts/verify-licenses.sh`：通过，无输出。
- 本轮精确文件为 `SegmentBoundaryCoordinator.swift`、`SegmentReportRelay.swift`、`SegmentedFMP4Writer.swift`、`SegmentedFMP4WriterTests.swift` 与本报告。按本轮最新交接要求，本报告作为准确单文件强制暂存，不带入 `.superpowers` 目录的其他忽略文档。提交信息为 `fix(hls): 封闭分段提交授权并回滚未领取发布账本`，最终 SHA 随交接返回，可由包含本节的提交元数据核验。
- 本轮明确保留 Deferred Minor：`capacity == Int.max` 时 `capacity + 1` 的溢出风险，未改动该表达式，留给最终全分支 review 决定。
- 未运行全量 `VPlayerTests`、无关 Task 15/16 方法、HomePod/Apple TV 真机、Task 18 parser/box validation、Task 19 publisher/store/playlist、Task 20 HTTP 或 Task 21 AVPlayer 回环。真实系统 callback 证据不替代这些后续任务的完整验证。
