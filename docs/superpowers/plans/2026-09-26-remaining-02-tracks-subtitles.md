# P02 多音轨与字幕 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 交付跨平台音轨身份与选择、字幕加载/切换/关闭/偏移以及确认格式的效果和同步验收。

**Architecture:** 先冻结公开字幕契约及原生桥接，再以媒体时钟驱动有界字幕解析与合成。文本、ASS 效果与图形字幕分阶段交付；字幕层必须分别适配普通、HDR 和受保护输出，不能假设像素回读。

**Tech Stack:** Dart/Pigeon、Media3、AVFoundation、现有 FFmpeg 解复用；候选开源字幕组件按制品/license/平台可行性核查后选择。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；本计划状态为未开始。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 跨 Period 同语言不同 role/重复 ID：选择身份不能绑死数组下标（任务 1）。
- seek、切字幕、关闭、正负偏移：旧 cue/位图必须立即清除（任务 2/3）。
- 损坏字幕、字体/图形资源失败：独立错误且不偷偷决定视频存活策略（任务 2/4，PD-03）。
- 字体风暴、超大位图、ASS 动画/长文本：缓存及计算有界（任务 3）。
- HDR/DRM/外接几何改变：字幕颜色、位置与受保护视频边界分别验证（任务 4）。

---

## 范围与依赖

现有 `YlTrackKind` 只有 audio/video；`YlMediaTrack` 已有 language，不能把“没有字幕实现”误报为只有 UI 缺口。现有 `selectAudioTrack` 保留。Apple DASH 共享单 AAC 的限制需要在本计划推进多音轨。

普通媒体的契约/解析可先开始；DASH 多音轨消费 P01 时间轴，其他本地/网络格式消费 P03。受保护输出合成依赖 P06；HDR 显示验收依赖相应 P07 输出行。PD-03 只阻塞“字幕故障是否终止视频”的最终行为及相应错误测试，不阻塞正常字幕、格式调查和 parser 隔离。

## 文件与接口

- 修改：`packages/yl_player/lib/src/playback_session.dart`；`packages/yl_player_platform_interface/lib/src/model/media_track.dart`、`player_state.dart`、`capabilities.dart`；该包 `platform/platform_player.dart`、`validation/state_validation.dart`、`testing/platform_conformance.dart`。
- 桥接：`packages/yl_player_apple/pigeons/yl_player_apple.dart`、`packages/yl_player_android/pigeons/yl_player_android.dart`；通过两包 `tool/generate_pigeon.sh` 生成，不手改产物。
- Apple：`Shared/DASH/YlDashDocument.swift`、`YlDashHlsCompiler.swift`、`Shared/Metrics/YlFallbackTrackCatalog.swift`、`Engines/AvPlayer/YlAvPlayerBackend.swift`、`Engines/ManagedFallback/YlFallbackBackend.swift`，均位于 Apple `darwin/yl_player_apple/Sources/yl_player_apple/`。
- Android：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Core.kt`、`YlPigeonPlayerHost.kt`。
- 新建：`docs/superpowers/specs/2026-09-26-subtitle-contract.md`、`docs/superpowers/reports/2026-09-26-remaining-02-tracks-subtitles.md`、`packages/yl_player/example/integration_test/subtitle_playback_test.dart`、`audio_track_selection_test.dart`。

消费既有 `Future<void> selectAudioTrack(String trackId)`；新增字幕 API 由任务 1 产生完整 Dart/Pigeon 签名和迁移表，再实施任务 2。此计划没有声称 `selectSubtitleTrack` 等方法已存在。

### Task 1：音轨身份和字幕契约

- [ ] 审计 audioTracks 状态、桥接 enum ordinal、旧适配器、公开 exports；规定跨段身份含语言/role/编码/内容身份，重复 ID 或缺失语言不可按数组位置漂移。选择失效规则须明确区分用户音轨与视频 PD-01。
- [ ] 形成字幕契约：外挂来源及请求策略、轨道目录、active/off、时间偏移单位/方向、样式能力、命令 ACK/失败/取消、旧适配器拒绝行为；定义所有新类型/字段/默认值与 `toString` 脱敏。尚无用户选择的错误恢复策略仅标记为 PD-03 决策项。
- [ ] 在两端现有轨道 codec 测试及 platform conformance 中先加入双语言音轨、重复语言不同 role、切段丢轨、迟到 ACK。保留旧 enum 编码或做明确协议版本协商；旧音视频 API 仍通过。
- [ ] 实现多音轨目录和真实选择；Apple DASH 使用与选中 video 同 Period 的 audio rendition group，不误将两个音轨同时混音。
- [ ] 公开测试使用两种不同音频标记验证实际切换，状态示例：

```dart
await session.selectAudioTrack(secondAudio.id);
// secondAudio 来自受控样本目录；await 已确认命令后等待音频状态收敛。
expect(player.state.audioTracks.where((t) => t.isSelected).map((t) => t.id),
       [secondAudio.id]);
expect(player.state.sessionId, session.id);
```

- [ ] 运行 Dart 合约、两端 Pigeon check 和多音轨公开套件；提交契约与多音轨阶段。

### Task 2：SRT/WebVTT/TTML 基础链路

- [ ] 按任务 1 已冻结接口创建 `packages/yl_player_platform_interface/test/subtitle_contract_test.dart` 和各 parser 测试；下列 owned 字幕是时间偏移基准，正偏移约定必须在契约说明：

```text
1
00:00:01,000 --> 00:00:02,000
one

2
00:00:01,500 --> 00:00:03,000
two
```

- [ ] 夹具断言：1.6 秒有两个 cue，3.1 秒无 cue；若正偏移定义为延后显示，+500ms 后 1.2 秒无 cue、2.1 秒有两个。seek 回 0 后不得残留；关闭字幕应立即清除，不等待下一帧字幕事件。
- [ ] 添加内嵌/外挂、BOM/换行、长文本、无效时间、TTML namespace/style/region、WebVTT position/align 用例；冻结 TTML 可实现子集，已确认效果缺口逐条追踪，不用“SRT 可用”概括全部文本字幕。
- [ ] 实现有界解析、以媒体时钟为准的 cue 选择、外部资源 managed 网络与取消，拒绝无限外部引用。字幕缓存独立计量，不能宣称媒体 buffer.bounded 自动覆盖。
- [ ] 跑新增公开套件：播放/暂停/倍速/seek/切段/换源；原始损坏原因映射 ERR-10，最终是否结束视频仅按已确认 PD-03 实装；提交文本字幕阶段。

### Task 3：ASS/SSA 与 PGS/VobSub 效果

- [ ] 为 libass 等候选及位图解码路线核查实际平台制品、开源许可证、字体加载和渲染预算；报告保留版本/hash/包含模块，不能把上游能力当现有 FFmpeg 制品能力。
- [ ] 新建效果样本：字体回退、描边、定位、动画/重叠、PGS palette 更新、VobSub idx/sub 配对和透明度；参考帧由独立 renderer/人工标注生成，记录时间点和像素容差。
- [ ] 先建失败测试，再按 ASS/SSA、PGS、VobSub 三个独立可提交切片实现。超大位图/字体/高频事件必须在分配前受限；生命周期和字体缓存共享边界需显式计量。
- [ ] 对照固定时间点截图与图形框范围，验证首帧、seek 后、跨段后、字幕关闭。测试不只断言“存在某像素”或 parser 无抛错。
- [ ] 跑各格式 parser/native 测试和三端效果套件；提交各切片并记录实现/验证行。

### Task 4：故障策略、HDR 与受保护合成

- [ ] 在实施故障恢复前确认需求基线是否已记录 PD-03；未确认则只提交安全错误分类与隔离机制，不私设“字幕错就停视频/忽略错误”默认值。
- [ ] 消费 P06 的受保护 view 契约，测试字幕叠层、尺寸旋转、画面裁切、多个播放器、后台恢复、外接重连；不读取 DRM 视频像素来合成字幕。
- [ ] 在已验证 HDR 路线上核对字幕亮度和颜色，字幕存在不能强制转 SDR；字体/图形资源失败保持稳定错误码和无秘密诊断。
- [ ] 运行三端同一字幕时标样本并记录同步分布及最坏偏差；PD-03、受保护资源缺失只标注相关行无法验收，不影响普通字幕已通过行。
- [ ] 完成 CAP-SUB 全格式组合清单与多音轨报告，提交最终集成切片。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。

### 2026-10-11 独立解析切片

从 `fee2518` 开始推进内部 SRT/WebVTT 有界解析与媒体时间查询；已覆盖重叠、正负偏移、关闭、seek、损坏输入及资源预算，整包 Dart 144/144 通过。当前没有公开字幕 API、网络/原生/画面接入，不将 Task 1/2 或 CAP-SUB 标为完成。Task 1 身份/命令契约、TTML 和完整渲染继续开放；精确限制、后续复审及验证以[执行报告](../reports/2026-09-26-remaining-02-tracks-subtitles.md)为准。长播放与弱网 ABR 由其他会话继续。
