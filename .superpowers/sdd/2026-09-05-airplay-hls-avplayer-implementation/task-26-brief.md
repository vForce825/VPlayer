### Task 26: 完整 codec／4K／HDR／双场 fixture 系统回环

**文件：** 扩展 `Scripts/generate-playback-fixtures.sh` 与fixture manifest；新建 `Tests/VPlayerTests/Playback/HLS/HLSCodecIntegrationTests.swift`、`HLSVideoIntegrationTests.swift`；修改 `PlaybackFixtureIntegrationTests.swift`、fixture loader和project.yml资源项。

**接口与依赖：** 任务12—25；输出SupportedAudioInputDomain逐维度覆盖清单、真实输入→解码/转码→fMP4→系统decode/AVPlayer结果。

**规格合同：** 覆盖六codec全部现有profile/framing/rate维度、mono到8ch语义表、audio-only、H264/HEVC progressive/unsafeGOP、1080i25/29.97双场、2160p50/59.94、NV12/P010、SDR/HLG/PQ。fixture生成与manifest同步且可复现；无假媒体字节冒充codec成功。

- [ ] 在 `HLSCodecIntegrationTests` 写下列行为测试及设计对应的负例；具名harness／fixture runner在本任务测试支持内定义，并实际调用生产组件。

```swift
let coverage = try SupportedAudioFixtureCoverage.loadCheckedInManifest()
XCTAssertEqual(coverage.uncoveredDomainValues, [])
let result = try await HLSCodecFixtureRunner.run("eac3-main-6x1block-5.1")
XCTAssertEqual(result.decodedFramesPerAccessUnit, 1536)
XCTAssertEqual(result.channelCount, 6)
XCTAssertTrue(result.publishedBytesPassedSystemDecode)
```

- [ ] 用本任务测试类运行 RED；工具任务使用其 `swift test`／shell self-test，记录失败原因。
- [ ] 实现：生成器使用固定ffmpeg版本参数，保留小型真实fixtures和SHA manifest；full domain enumerator与测试共用parser支持表但期望样本/像素ID手算。输出YADIF每场ID贯穿Metal→VT→fMP4系统decode，AAC priming真实sample误差≤1/48000秒。真机专属测试具明确原因，不能算成通过。
- [ ] 运行针对性测试与受影响回归，记录 GREEN、产物和未完成的硬件证据；执行工程／许可证／diff检查。
- [ ] 精确暂存并提交：`test(hls): 覆盖完整编码域与系统解码回环`；根代理取得规格／质量review后才标记完成。
