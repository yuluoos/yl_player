# P04 弱网 ABR 与直播模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 在真实受控网络下证明自动/上限/固定选择，并交付 HLS、HTTP-FLV、RTMP 的两种直播模式与运行时切换。

**Architecture:** 复用已实现的视频选择事务，不重做固定档位接口。把公开策略、实际媒体选择、缓冲行为和可测指标关联；不同协议分别设目标，模式切换沿会话命令顺序执行，不能用偏好参数宣称达标。

**Tech Stack:** Media3、AVPlayer、既有 RTMP/HTTP-FLV 路径、Dart 集成测试、受控网络服务与单调时钟。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** 原规划 `5409313`；2026-10-11 从 `fee2518` 推进 Task 1A 网络工具和原创40秒节目，20项自测通过。Task 1播放器基线与Task 2–4仍未完成，见[执行报告](../reports/2026-09-26-remaining-04-abr-live.md)。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 固定高档遇弱网：可缓冲，不得降档（任务 2）。
- 缺档回自动时仍有 caps 或硬解约束：不能借回退放宽其他要求（任务 2）。
- 快速切模式/seek/换源与迟到回包：策略和状态必须同一会话（任务 3）。
- 暂停/后台/重连后缓存积压：不得无限累计延迟或字节（任务 3）。
- 无可信源时钟：不能把 buffered duration 或 liveOffset 当端到端直播延迟（任务 1/4）。

---

## 范围与依赖

自动、固定、caps 和 PD-01 已有实现；本计划补弱网定量与直播两模式闭合。现有 `YlBufferStrategyKind.automatic/lowLatency/smoothPlayback/bounded` 不是实测 SLO，运行时模式接口需审计后扩展。

先消费 P08-A/B 的测量工具和数值目标，P01/P03 的已支持档位可先用 AVC/AAC 子集。异编码档位映射依赖对应 P01/P03 行；HDR/SDR/Dolby 自动转换仅在 PD-02 确认后实施。RTMP 已有基础播放，不重新开发协议接收器。

## 文件与接口

- 契约：`packages/yl_player/lib/src/playback_session.dart`、`packages/yl_player_platform_interface/lib/src/options/policies.dart`、`model/video_selection.dart`、`model/playback_metrics.dart`。
- Apple：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift`、`Engines/ManagedFallback/YlFallbackBackend.swift`、`Shared/RTMP/YlRtmpPolicy.swift`、`Shared/VideoToolbox/YlVideoSubmissionQueue.swift`。
- Android：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Configuration.kt`、`YlMedia3Core.kt`、`YlRtmpRecovery.kt`。
- 新建：`packages/yl_player/example/integration_test/abr_network_profile_test.dart`、`live_mode_switch_test.dart`；`tool/playback_network/profiles.json`；`docs/superpowers/reports/2026-09-26-remaining-04-abr-live.md`。

消费既有 `Future<void> selectVideoTrack(String? trackId)`、`Future<void> setVideoConstraints(YlVideoConstraints constraints)`。任务 3 产出新的运行时直播模式命令精确签名、能力位和 ACK 规则后更新两端 Pigeon；不假定现在已有 setter。

### Task 1：可重放网络和指标

2026-10-11 Task1B采集准备已交付：首次GET启动、公开auto/caps/fixed采集及离线汇总；Python31/Dart17通过，静态分析无问题。实际原生基线尚未运行，按[采集协议](../../../tool/playback_network/capture-protocol.md)继续。

2026-10-11 Task 1A：HTTP应用层工具、三条轨迹、原创40秒节目和虚拟时钟/回环测试已完成。`latencyMs`只代表应用响应延迟，真实RTT、HTTP-FLV/RTMP与播放器基线未验收。以下综合复选框保留未完成，避免用工具通过替代完整任务。

- [ ] 创建带版本网络轨迹和 owned 两/三档节目；固定带宽、RTT、丢连接、停顿及恢复时刻，记录客户端每次分段请求和实际字节。优先应用层受控服务，不修改宿主全局网络。
- [x] 写服务自测验证按虚拟时钟执行相同轨迹；新增轨迹示例（单位固定，产品阈值不由此推出）：

```json
{"id":"down-and-recover-v1","steps":[
 {"atMs":0,"bytesPerSecond":500000,"latencyMs":40},
 {"atMs":10000,"bytesPerSecond":50000,"latencyMs":200},
 {"atMs":25000,"bytesPerSecond":500000,"latencyMs":40}]}
```

- [ ] 分别采集 auto/caps/fixed 与 HLS/HTTP-FLV/RTMP 两模式基线，按 P08 冻结升降档时间、振荡、再缓冲和延迟目标。无可信源时钟时 end-to-end latency 记 unavailable，其他指标照测。
- [ ] 提交网络工具与基线报告，优化代码此时尚未开始。

### Task 2：ABR 与固定/上限行为

- [ ] 在新增公开测试中先固定预期：auto 随网络变化在可解码集合选择；caps 下没有超限请求/输出；fixed 弱网保持选择，即使缓冲也不能自动变低。
- [ ] 对同一 fixed 先穿越“仍存在”再穿越“确实缺失”的 Period，断言缺失才回 auto；回跳保留 auto，caps 独立有效。使用实际请求和输出几何佐证，不能只看 UI 的 trackId。
- [ ] 分别测试命令准备失败回滚、更新 caps 与 seek 竞态、重复档位但 codec 不同的身份；保持原始 MPD 校验，不让隐藏非法轨道通过。
- [ ] 仅针对实测失败优化引擎选档/预加载/切换，保留 system 限制和资源预算；PD-02 未确认时只测同动态范围，报告其余依赖行。
- [ ] 运行 `abr_network_profile_test.dart` 三端公开路径及原 fixed/caps 回归，提交 ABR 定量阶段。

### Task 3：直播模式运行时事务

2026-10-11 Task3B公共契约切片：新增Dart状态/可选SPI和Session入口，三重门禁、32条待结算上限及旧会话完成隔离。现有原生adapter未声明能力，默认映射和桥接schema不变；后端命令排序/状态屏障/回滚仍属Task3C，不能把可控后端测试当作原生事务验收。

- [x] 审计当前 load 策略映射，冻结新增运行时命令：有效 session、smooth 默认、能力拒绝、命令确认时机、失败回滚、多个命令先后次序；buffer.bounded 独立边界不得被模式切换覆盖。2026-10-11 Task3A交付[源码审计与未来契约](../specs/2026-10-11-live-mode-runtime-contract.md)，24份固定提交源码/49处锚点；新API、桥接与运行时行为尚未实现，本项勾选仅表示设计交付。
- [ ] 对 HLS、HTTP-FLV、RTMP 分别写失败测试：smooth→lowLatency→smooth、切换中断流、后台恢复、快速切台、stop/dispose；不得将 live 时间 seek 偷换成 seekToLiveEdge。
- [ ] 实现协议对应目标缓存/追帧和安全追实时条件；必要重开必须有代际隔离、恢复预算与可观察缓冲，不能无限刷新连接。
- [ ] 用 owned 源真实播放验证画面/声音仍推进，模式确认后状态与实际策略一致；低延迟追赶不会留下旧音频或无界缓存。
- [ ] 提交两端实现、双端桥接、`live_mode_switch_test.dart` 及指标记录。

### Task 4：指标验收和业务接入

2026-10-11 Task4A离线汇总准备：预登记三模式×缓存×轮次，校验归档SHA256并重算单轮结果，保留失败/超时/未运行记录和分组p50/p95；环境与缓存标签仅为声明。工具交付不等于重复实测或SLO验收，以下复选框继续开放，见[离线协议](../../../tool/playback_network/experiment-protocol.md)。

- [ ] 按原样本/网络/设备重复测量，保留失败与超时次数、p50/p95、冷暖缓存，比较冻结目标；不为达标只删慢样本。
- [ ] P05 业务侧显示默认模式和切换失败安全提示，代理未参与的链路流量记不可用，不记 0；UI 数据由实际 session 状态驱动。
- [ ] 报告三协议目标、实现、实际结果及不适用组合，明确低延迟允许的弱网卡顿取舍已来自需求。PD-02 相关变更另记决定及实验，不能自动降 SDR。
- [ ] 提交阶段报告并交 P08 长播/低档设备验收。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。

### 2026-10-16 可离线功能进度

Task3C/3D 的双端 schema 6、模式事务、HLS 缓冲/追赶与 FLV/RTMP 有界重建策略已实现，
Task4 的 TVS 实际模式展示和安全切换入口已接入；新增公开三协议采集入口。
原复选框包含真实播放/测量的复合验收条件，继续保留未勾选。已完成的细分项：

- [x] 双端完整快照/ACK 精确 revision 屏障、顺序和取消，以及旧 factory 标签兼容。
- [x] 原生策略代码及无设备单元/策略检查，TVS 模式状态与安全反馈接入。
- [x] `live_mode_switch_test.dart` 采集入口及其离线校验。
- [ ] 三协议实际播放、弱网 ABR/fixed/caps 定量及真实恢复/输出证据。
- [ ] 对冻结数值目标进行同条件重复测量，并交 P08 完整验收。
