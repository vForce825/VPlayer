# Task22 交接文档（2026-09-13）

## 交接结论

Task22「接通 HLS 音视频 backend」已完成实现、定向回归和最终复审，可以在此暂停。AirPlay 路由统一使用 HLS + AVPlayer 新后端；非 AirPlay 用户继续使用原 SampleBuffer 后端。新后端失败时关闭当前 AirPlay 启动，不回退到 SampleBuffer 或 FFmpeg PCM。Task23 及之后任务尚未开始。

当前变更是跨 Task11—22 累积的未提交 WIP。按用户要求保留现场，没有提交、推送、合并或清理 worktree。

## 代码现场

- 仓库：`/Users/daniel/git/VPlayer`
- worktree：`/Users/daniel/git/VPlayer/.worktrees/airplay-hls-avplayer`
- 分支：`codex/airplay-hls-avplayer`
- 开工基线 HEAD：`500abb3`
- 当前状态：dirty，包含 Task11—22 的已跟踪修改与新增文件；接手者不得用 reset、checkout 或 clean 丢弃这些变更。

## 已接通的生产路径

1. `PlaybackBackendFactory` 只在 AirPlay 路由选择 `HLSAVPlayerPlaybackBackend`；非 AirPlay 保持原 `SampleBufferPlaybackBackend`，不会创建 HLS writer、HTTP server 或 AVPlayer 资源。
2. `SystemHLSMediaGraphAuthority` 使用唯一 FFmpeg demux source：
   - progressive 视频走压缩 remux；
   - 已知隔行视频从第一帧走 FFmpeg 解码、Metal YADIF2x、硬件 VideoToolbox 编码；
   - 音频走压缩保真分支或 PCM→AAC 分支；
   - 音视频汇入 fragmented MP4 writer、publisher、sealed store 和 loopback HTTP server，再交给 AVPlayer。
3. `HLSMediaGraphAssembler` 只有在所有已选轨道形成真实六秒可播前缀后才签发 replacement item；自然 EOF、停止和资源退役都等待真实 receipt。
4. AirPlay HLS 的 VideoToolbox 提交使用有界无损策略。YADIF 双场输出在进入 GPU 前原子预占整个编码批次；背压时保持 FIFO，不允许半批接纳或显示型丢帧。
5. 缺失的 decoded color attachment 会从冻结输入格式补齐；与冻结签名冲突的 metadata 仍然拒绝。
6. FFmpeg C bridge 在 `avcodec_send_packet` 返回 EAGAIN 时先 drain 再重送同一 packet。自然 EOF 已成功 drain 的 session 在 retirement 时只销毁 native handle，不再发送第二个 NULL packet。
7. System 媒体图的 publication、可播前缀和终态等待共用同一个可注入预算，生产默认 120 秒；通用 publisher 默认仍为 3 秒。

主要新增入口：

- `Sources/VPlayerPlayback/Pipeline/HLSAVPlayerPlaybackBackend.swift`
- `Sources/VPlayerPlayback/HLS/SystemHLSMediaGraphAuthority.swift`
- `Sources/VPlayerPlayback/HLS/SystemHLSPublicationGraph.swift`
- `Sources/VPlayerPlayback/HLS/HLSMediaGraphAssembler.swift`
- `Sources/VPlayerPlayback/HLS/HLSOutputItemBundle.swift`
- `Sources/VPlayerPlayback/HLS/HLSVideoRemuxSubmission.swift`
- `Sources/VPlayerPlayback/HLS/HLSVideoTranscodeBranch.swift`
- `Sources/VPlayerPlayback/HLS/AudioRenditionBranch.swift`
- `Sources/VPlayerPlayback/HLS/SystemHLSAudioPCMBridge.swift`
- `Tests/VPlayerTests/Playback/HLS/HLSAVPlayerBackendTests.swift`

## 最后两项真机问题及修复

### 隔行图首帧与编码背压

已知隔行 HLS 在探测后若先尝试 VideoToolbox、再切换 FFmpeg，旧 route 回调会被隔离并形成视频 PTS 空洞。现从第一帧直接进入 FFmpeg route；同时让 YADIF2x 双输出与 VT admission 原子化，并为 HLS 使用有界无损提交策略。

### 自然 EOF 的重复 drain

FFmpeg decoder 在自然 EOF 已发送 NULL packet 并成功 drain，退役流程过去会再次发送 NULL，底层返回 `AVERROR_EOF` 后被误判为失败。现按 epoch 记录自然 drain 状态，退役时跳过第二次 EOF，只销毁同一 handle。

## 验证证据

### Apple TV 真机

- 设备：`客厅AppleTV`
- 设备 ID：`00008110-001E35400E06201E`
- 序列号：`CF5MWPWDDW`
- Team：`Jiahui Qiu`（`5P4CLYG8G2`）
- 测试：`HLSAVPlayerBackendTests/testProductionInterlacedGraphUsesYADIF2xAndFailsClosedWithoutHardwareEncoder`
- 结果：1/1 通过，0 失败，85.184 秒。
- xcresult：`/tmp/VPlayer-task22-device-dd/Logs/Test/Test-VPlayer-2026.09.13_14-38-28-+0800.xcresult`

该测试完整经过隔行解码、Metal YADIF2x、硬件 VT 编码、音视频 publication、自然 EOF 和资源退役。

### tvOS Simulator

- 聚焦合并回归：全部所选用例通过，57.380 秒。覆盖 production graph、YADIF/编码 admission、暂停恢复、metadata、VideoToolbox 无损策略、FFmpeg route/retirement、长节目 token 与两个 384+ writer window。
- xcresult：`/tmp/VPlayer-task22-dd/Logs/Test/Test-VPlayer-2026.09.13_14-55-12-+0800.xcresult`
- 最终预算修复单测：通过；xcresult 为 `/tmp/VPlayer-task22-dd/Logs/Test/Test-VPlayer-2026.09.13_15-00-30-+0800.xcresult`。
- 最终 `HLSAVPlayerBackendTests` 整类复跑：7/7 通过，0 失败；xcresult 为 `/tmp/VPlayer-task22-dd/Logs/Test/Test-VPlayer-2026.09.13_15-04-41-+0800.xcresult`。

整类第一次复跑的两个 progressive 用例因本机 `127.0.0.1:19022` fixture server 未启动而得到 `demuxOpen(-61)`；启动固定只读 fixture server 后同一测试类全部通过，因此该次失败属于 runner 前置条件，不是生产回归。fixture server 在验证后已退出。

### Fixture 完整性

- `task22-interlaced-h264-mp2-16s.ts`：`f7047bc940d30a338eb3b65b6abb15820cfb14cb9b4fb63a891def9eb42989d1`
- `task22-progressive-h264-aac-0.8s-short.ts`：`e148b4042c298ddd72df5d2cc7c2d8c58b35dab950f45e7b1a294a8ad4a4633e`
- `task22-progressive-h264-aac-15.4s-eof.ts`：`84439b99401eb1b35e38c7581f270ecd3dc88364b1edc4e3f872d720f7697a40`
- `task22-progressive-h264-aac-16s.ts`：`4db670eef1f5ce2d1d4dc89da6c6a601ba97427ff2676c27304456641919c137`

## 最终复审

独立 Terra 中等强度复审确认：此前“前缀等待固定 20 秒、与 publication 120 秒不一致”的 Important 已解决；生产 publication、prefix、terminal 等待均来自同一注入预算，没有新的 Critical 或 Important。复审认为当前诊断注入测试证明三处配置一致；如果后续继续强化，可再增加真实超时行为测试，但这不是未关闭的 Critical/Important。

## 接手注意事项

- 不要把 HomePod `outputLatency` 人工加到视频 PTS；当前方案依赖 AVPlayer/AirPlay 2 的系统时钟和缓冲策略。
- 不要恢复 AirPlay→SampleBuffer 或 AirPlay→FFmpeg PCM fallback；当前合同是 AirPlay 新后端 fail-closed。
- 不要让非 AirPlay 路径创建任何 HLS/AVPlayer 资源。
- 不要把 HLS 的无损 VT 策略扩散到实时 SampleBuffer 显示路径；后者保留原实时丢帧策略。
- progressive fixture 测试依赖 `VPLAYER_TASK22_FIXTURE_BASE_URL`，缺省为 `http://127.0.0.1:19022`。scheme 不应永久写入临时环境变量。
- 继续开发前先阅读本文件与 `.superpowers/sdd/2026-09-05-airplay-hls-avplayer-implementation/task22-f-full-media-backend-report.md`，再从 Task23 单独切分目标。

## 尚未宣称的证据

真机测试已经证明完整媒体图和硬件路径能闭合，但现场没有人进行嘴型/声音的主观采集，也没有声学测量设备，因此不能宣称 HomePod 物理音画同步已经完成人工验收。Task28 的物理同步证据工具和 Task23—29 均未开始。
