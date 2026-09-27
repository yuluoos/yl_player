# P01 DASH 寻址与节目时间轴 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 补齐 Apple SegmentBase/sidx，按覆盖矩阵推进剩余 DASH 时间轴和跨段重配，并保持三端公开行为一致。

**Architecture:** 保留 Android Media3 和 Apple 会话私有 HLS 适配。先以纯字节索引解析与有界异步取索引扩展 SegmentBase，不在同步 MPD 编译器中发起网络请求；独立轨道偏移和裁剪先用原始媒体证明路径可行。

**Tech Stack:** Dart、Swift/AVFoundation、Kotlin/Media3、ISO BMFF、既有受控 DASH 服务。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**规划起点：** `5409313`；2026-09-27 从干净的 `4d9830e` 执行 Task 1，有界解析及两端原生回归已通过。Task 2 已接通有界子集并通过三端主机/模拟器自动化播放，Task 3/4 尚未完成；详见[执行报告](../reports/2026-09-26-remaining-01-dash.md)。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 畸形/嵌套 sidx、整数溢出或巨大引用数：拒绝且不无限下载（任务 1/2）。
- Range 返回整文件、错误 Content-Range、跨域返回原域：保持预算及凭据剥离（任务 2）。
- 不同音视频原点、边界裁剪、gap/overlap：不能靠移动时间戳掩盖不同步（任务 3）。
- 新 Period 重配与 seek/cancel 同时发生：旧结果不能覆盖新会话（任务 4）。
- 上限隐藏的原始轨道畸形、未知中间段时长：不能过滤后误接受（任务 3/4）。

---

## 范围与依赖

已有 Template/Timeline/List、单文件 SegmentList、对齐 PTO、有限末段时长、档位增删和固定/上限事务，不重复开发。Apple 当前仍是兼容 static AVC/AAC 子集；Android 已有 Media3 SegmentBase 路径，需补本项目契约证据。

任务 1/2 可立即执行，不依赖 DRM/字幕/PD-02。任务 4 的异编码重配依赖 P03 已验证对应解码路径；音轨/字幕切段接 P02。不同动态范围仅在 PD-02 已确认后纳入自动切换。managed、bounded、hardwareRequired 在 Apple DASH 的既有拒绝保持，直到有实现与单独验收，不能顺手改成支持。

## 文件与接口

仓库内路径：
- 修改：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashDocument.swift`、`YlDashHlsCompiler.swift`。
- 修改：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsResourceLoader.swift`（实际 DASH preflight/snapshot 在此）、`YlHlsMediaProxy.swift`、`YlHlsHeaderPolicy.swift`。
- 对齐：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDashManifestParser.kt`。
- 原生测试：`tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashHlsCompilerTests.swift`、`YlDashResourceLoaderTests.swift`；通过现有同步工具更新示例 iOS/macOS 镜像和测试发现清单。
- 新建：同一 Apple `Shared/DASH/` 下 `YlDashSidx.swift`；`packages/yl_player/example/integration_test/apple_dash_segment_base_test.dart`、`apple_dash_timeline_edges_test.dart`；`docs/superpowers/reports/2026-09-26-remaining-01-dash.md`。

消费现有 `YlDashHlsCompiler.compile(data:finalManifestURL:sourceURL:credentialsStripped:videoConstraints:fixedTrackId:manifestURL:mediaURL:) throws -> YlDashHlsPresentation`。保持同步纯编译边界；任务 2 如需新增“索引已解析快照”参数，先在报告记录精确 Swift 类型和所有调用点，再修改生产与测试。不得用全局 URL 缓存传递隐式状态。

### Task 1：有界 sidx 解析

- [x] 生成 owned fMP4 单文件的 v0/v1 sidx 夹具，记录 box 起点/终点、timescale、earliestPresentationTime、firstOffset、reference 类型和 SAP；哈希纳入样本账本。区分字节偏移和媒体时间单位。
- [x] 新增 `YlDashSidxTests.swift`，先定义下列**私有接口**，固定此阶段只接受平面 media references；嵌套索引必须明确拒绝，不能伪装媒体段：

```swift
struct YlDashSidxReference: Equatable {
  let offset: UInt64
  let length: UInt64
  let durationTicks: UInt64
  let startsWithSAP: Bool
  let sapType: UInt8
  let sapDeltaTicks: UInt32
}
struct YlDashSidxIndex {
  let referenceID: UInt32 // 保留供后续 loader 校验媒体身份；私有接口
  let timescale: UInt32
  let earliestPresentationTimeTicks: UInt64
  let references: [YlDashSidxReference]
}
enum YlDashSidx {
  // Task 1 已实现；函数体在失败用例确认后加入。
  static func parse(_ data: Data, boxEndOffset: UInt64,
                    maxReferences: Int) throws -> YlDashSidxIndex
}
// 一个 boxEndOffset=100、firstOffset=20、引用大小 30/40 的夹具：
// fixtureBytes 来自本任务构造的原始 sidx 字节，不能由被测 parser 生成。
let index = try YlDashSidx.parse(fixtureBytes, boxEndOffset: 100, maxReferences: 2)
XCTAssertEqual(index.references.map(\.offset), [120, 150])
XCTAssertEqual(index.references.map(\.length), [30, 40])
```

- [x] 对 0 timescale、截断、overflow、reference_type=1、0/超限引用先观察失败；测试输入来自构造的字节，不依赖解析器自产输出。时间投影使用返回的 timescale/起始时间，不能用 durationTicks 当微秒；非随机访问边界不能不经验证直接宣告可 seek。
- [x] 用 checked arithmetic 计算 box 终点 + firstOffset + 累计 size；先做数量/字节/时间预算，再分配数组。沿用现有安全错误，不输出完整 URL。
- [x] 跑总览 Apple 原生检查入口，证明两端发现并执行新增用例；提交 `feat: parse bounded DASH sidx references`。

### Task 2：SegmentBase 从网络到真实播放

- [x] 扩展 `integration_test/support/dash_server.dart`，添加单文件 `Initialization range` + `indexRange` 清单；服务记录每次 Range、凭据过滤和取消。基准样本采用单 Period AVC/AAC，避免同时引入编码变更。
- [x] 在 loader 测试固定：索引只读取预算内字节；206 必须验证范围；200 整体响应只能在明确有限字节规则内处理，否则拒绝；416、错范围、重定向循环均可安全失败。
- [x] 按既有异步 preflight 生命周期读取索引并生成不可变 segment descriptors，再交编译器；取消时终止索引请求，失败候选不替换当前会话。BaseURL、继承、Range 及跨域粘性剥离沿用既有规则。
- [x] 新公开测试通过 `player.load` 播放、seek 后观察首帧和音频推进；断言真实请求范围匹配夹具、session 不变、position 单调（主动 seek 除外）。Android 对同一夹具补实际播放证据，不以 Media3 文档代替本项目运行。
- [x] 运行新增公开套件及原生 loader/compiler 相关回归；提交 `feat: play indexed SegmentBase DASH on Apple`。仅将验证过的 sidx 子集更新为支持。

Task 2 验证边界：音频采用选中音轨与播放时钟观察，物理可听输出/同步及最低系统仍由 P08 验收；仅支持报告列明的索引子集。

### Task 3：时间轴剩余维度与可行性收敛

- [ ] 新建覆盖行：独立音/视频 PTO、Period 端点裁剪、gap、overlap、未知中间时长、多 BaseURL、非精确微秒换算，各有最小清单/原始媒体及预期节目时标。未知中间时长不能擅自用末段算法补齐。
- [ ] 用非生产重封装的原始媒体建立 AV/字幕时标参考；在报告给出“私有 HLS 可精确表达/需要重封装或新路径/无法判断”的实际实验结果。没有证据时保留具体拒绝与后续架构步骤，不能写通用 DASH 完成。
- [ ] 对可表达的子集先增加失败测试，再逐子集实现。时间换算在一个边界执行，使用 checked rational arithmetic；不能先筛选上限再校验原始 timeline。
- [ ] 公开测试在边界前、边界上、边界后 seek，核对节目时长、实际图像时标与音频标记；取消重开不混用旧资源。把无法完成的已确认范围列为架构缺口，不能自行删范围。
- [ ] 按独立子集提交，报告每个 CAP-DASH/CAP-PERIOD 子行的实现和验证状态。

### Task 4：已支持解码路径的跨 Period 重配

- [ ] 消费 P03 已验收编码组合和 P02 轨道身份规则；为同编码改分辨率、异编码同动态范围、音轨增删各建夹具。重配允许缓冲窗口由 P08 基线实测冻结后写入行内。
- [ ] 测试覆盖真实边界播放/往返 seek/重配中 cancel。固定档位存在时弱网不得降低；缺档按 PD-01 进入自动且仍不超独立 caps：

```dart
await session.selectVideoTrack(highTrack.id);
await session.seekTo(nextPeriodStart);
// nextPeriodStart / highTrack 来自 fixture 的确切目录；等待新段公开状态后：
expect(player.state.videoSelection.fixedTrackId, isNull);
expect(player.state.sessionId, session.id);
expect(player.state.failure, isNull);
```

- [ ] 实现按会话/命令代际隔离的 decoder/item 重配，提交后发布实际目录/几何，失败保持既有回滚语义。不同动态范围自动转换在 PD-02 确认前不实现默认策略。
- [ ] iOS/macOS/Android 跑同一节目时标样本，记录第一新段画面与声音时标、缓冲窗口、资源释放；提交阶段报告。完成本任务仍不代表 P02 字幕和 P04 弱网 ABR 已完成。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

2026-09-27 Task 1/2 已执行索引解析、三端有界 SegmentBase 自动化播放、两端原生回归和测试身份核对。其余未勾选项仍是未来步骤，不代表通用 DASH 完成。
