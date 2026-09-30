# P08 性能基线、优化与共同验收 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 先建立可信性能基线，再针对证据优化，最后汇总最低系统、真实设备、长期稳定性及发布回归。

**Architecture:** 分为 A 测量工具、B 冻结基线、C 按瓶颈优化、D 最终验收四个执行段。A/B 先于其他计划的性能改动，D 在能力实现之后；同一报告记录源文件身份和方法变化，不能用最终结果倒推基线。

**Tech Stack:** Flutter integration tests、原生 Instruments/Android profiling、单调时钟、现有 check_player_v2/consumer/原生检查工具。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；2026-09-27 已开始执行 Task 1/A 的首个测量工具切片，完整 A/B 尚未完成。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 首帧从 Load 返回才计时或解码完成当呈现：测量起止必须真实（任务 A）。
- 失败/超时样本被删除、冷暖缓存混合：统计必须保留全体试验（任务 A/B）。
- 新功能原来不能播：不得伪造优化百分比（任务 B）。
- 长播/低内存/后台/多播放器导致泄漏：短单测通过不能替代（任务 C/D）。
- 缺真机/最低系统/Intel/DRM链路却报全绿：实现与验证状态分开（任务 D）。

---

## 范围与依赖

**执行顺序：A/B 尽早，C 随已测瓶颈，D 最后。** 不要求等 P01–P07 全部完成才开始 P08；每个新功能若没有旧可播路径，使用绝对目标，并保留已有路径的非退化基线。

没有统一已冻结性能数字；应按需求第 7 节实测后冻结，不在规划时编造“首帧小于 N 秒”。原生模拟器/集成已通过的历史证据保留，无法替代物理 iOS、Android API24 低内存/32-bit、Intel macOS、最低 OS、长期负载和消费包验证。

## 文件与接口

- 现有公开指标：`packages/yl_player_platform_interface/lib/src/model/playback_metrics.dart`；`packages/yl_player/example/integration_test/state_update_cadence_test.dart`。
- 现有检查：`tool/check_player_v2.sh`、`check_native_android.sh`、`check_native_ios.sh`、`check_native_macos.sh`、`check_public_surface.sh`、`check_publication.sh`、`check_consumers.sh`、`check_apple_consumer.sh`。
- 原生真实发现：`tool/consumer_fixtures/apple_flutter/main_example_tests.py`。
- 新建：`tool/playback_benchmark/README.md`、`summarize.py`、`test_summarize.py`、`thresholds.json`；`packages/yl_player/example/integration_test/playback_benchmark_test.dart`；`docs/superpowers/reports/2026-09-26-remaining-08-performance-release.md`。

消费实际 Player.load/Session 命令与 `YlPlaybackMetrics`；`loadToReady`、`loadToFirstFrame`、`liveOffset` 不能互相替代。任务 A 产出的 JSONL 是 B/C/D 共同输入；性能数据不含 URL/token/原生异常。

### Task 1：A — 可信测量和统计工具（进行中）

2026-09-27：公开首帧事件计时 probe、严格 JSONL 统计和 macOS 三次 smoke 已实现；事件到达不等同最终可见呈现，暂不冻结性能目标。完整状态见[执行报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-09-30：补齐 macOS 进程内 CPU/RSS/physical footprint、电源和系统热状态采样；预定三次公开 AVC 播放均通过，94 点无缺失。创建超时/迟到释放、阶段隔离和按实际时间加权统计已测试；原始试次与构建配置指纹归档。该子项仅为 debug 测量工具 smoke，GPU/媒体账本、正式呈现、受控基线和 AV1 软件预算仍未完成，完整 Task 1/2 不勾选。

2026-09-30：补齐 macOS 14.4+ Debug 暂停显示层像素回读；独立验证的 BT.709 AVC 素材三次×四段×九点颜色匹配，释放后无残留层。旧未标注素材颜色容差失败保留；新素材不代表该问题修复。回读包含主动暂停，不能替代首帧/最终屏幕呈现或正式基线，Task 1/2 继续进行中。

- [ ] 定义每次运行记录：runId、caseId、commit、sourceHash、buildMode、dependency/artifact版本、device/OS/架构、power/thermal、output、mediaHash、networkProfile、cacheState、attempt、outcome、startedUs、firstPresentedUs、seek/同步/资源观察。未观察值用 null，不用 0。
- [ ] 在公共 Load 调用前启动单调 Stopwatch，关联本次 Session 首次真实呈现事件；额外记录 JS/许可证/网络分阶段。禁止在 ready 或 Load 返回时才开始计时。
- [x] 新统计工具先写失败测试，定义接口：

```python
# 新增 tool/playback_benchmark/summarize.py
# summarize(rows: list[dict]) -> dict
# rows 每次尝试都有 outcome；成功时 firstFrameUs 是从调用前到呈现的差值。
from summarize import summarize
import unittest

class SummaryTests(unittest.TestCase):
    def test_failures_remain_visible_and_missing_is_not_zero(self):
        result = summarize([
            {"outcome": "passed", "firstFrameUs": 100},
            {"outcome": "timeout", "firstFrameUs": None},
            {"outcome": "passed", "firstFrameUs": 300},
        ])
        self.assertEqual(result["attempts"], 3)
        self.assertEqual(result["passed"], 2)
        self.assertEqual(result["timeouts"], 1)
        self.assertEqual(result["firstFrameUs"]["p50"], 200)
        self.assertEqual(result["firstFrameUs"]["p95"], 300)
```

p50 采用常规 median（偶数取中间均值），p95 采用 nearest-rank；样本量不足仍报告 n，不靠两次样本声明正式 SLO。失败样本不混入成功耗时但必须计入尝试/失败率；全失败耗时统计为 null。

- [x] 实现 JSONL 校验/摘要和 mock 时钟测试：CLI 入口先拒绝缺 source/device 身份的正式验收输入、负时长和不同条件混并；`summarize` 消费校验后的同组统计字段，为失败率/分组/全失败补行为测试。
- [ ] 运行 `python3 -m unittest discover -s tool/playback_benchmark -p 'test_*.py'`，预期实际发现上述测试并通过，不引入未声明 pytest 依赖。真实现有播放路径验证一次首帧边界后提交测量工具。

### Task 2：B — 基线采集与目标冻结（优化前）

- [ ] 枚举可用物理设备/模拟器及实际最低系统缺口，冻结媒体/网络/缓存条件；短播确认画面音频正确后才纳入性能样本。
- [ ] 分别记录首帧、seek 目标附近首帧与稳定窗口、TVS 全链切台、初始/再缓冲、AV/字幕同步误差、CPU/RSS/GPU账本/热状态、长播增长/释放；只有可信源时钟才能测端到端直播延迟。
- [ ] 在 `thresholds.json` 按平台/设备档位/协议建立版本化目标，字段包括样本数、预热、允许失败数、p50/p95、最大偏差/增长、不可退化阈值、证据来源。数值须来自基线与产品取舍，不能在实施优化后补写。
- [ ] 新增能力基线不可播时记录 `baselineComparable=false`，使用绝对正确性/性能目标；不要输出无意义改善百分比。
- [ ] 提交基线报告和阈值版本，随后 P03/P04/P07 及 C 才能据此优化；设备缺失仅阻塞相关档位数字，其他实测可继续。

### Task 3：C — 基于瓶颈优化（每个瓶颈一个切片）

- [ ] 用 Instruments/Android profiling 与媒体账本定位实际瓶颈；在本计划报告为每个候选登记“现象→调用栈/队列→目标文件→预期指标→回归风险”，没有证据的缓存/并发改写不立项。
- [ ] 对正确性缺陷先写行为失败测试；纯性能改动固定前后 benchmark，避免编写只镜像实现的测试。不得为减少首帧放宽鉴权、缓冲限额或硬解/画质要求。
- [ ] 实施最小切片，重跑相同条件基线及直接受影响的音频/FEL/生命周期测试；保留失败/超时和热状态，样本变化则版本化并重测受影响基线。
- [ ] 只有达到冻结目标或明确记录仍有差距时提交真实结果，不把不显著差异写成提升；需改变产品取舍则回到需求决定，而非偷偷松阈值。
- [ ] 汇总每个平台/档位的 before/after、资源预算及剩余瓶颈；不承诺所有优化都必须产生百分比改善。

### Task 4：D — 跨平台封板与发布门槛（最后做）

- [ ] 汇总 P01–P07 每个 CAP/ERR 和所有 REG 行，读取最终 sourceHash/commit；区分已实现未验证、外部缺输入、失败、跳过。PD-02/03 未确认的依赖行不能被总报告吞掉。
- [ ] 在 Android API24/低内存/相关32-bit、iOS真机/最低版本、macOS最低版本/Intel 与 Apple Silicon 上按实际能力验收；缺设备列明型号/OS需求和下一可执行步骤，不以模拟器或 Rosetta 替代全部结论。
- [ ] 按 Task B 已冻结时长/次数运行长播、循环加载释放、多播放器、后台/前台、seek/切台/重连/热状态测试，观察资源回收及音画；DRM/杜比只接受各自授权/参考/实际输出证据。
- [ ] 先定向通过，再运行一次本次改动对应的 full aggregate、消费者/包生成检查和远程 CI。最低系统编译、实际运行、制品架构、消费者 CocoaPods/SPM 分开记录；不重复为文档变动跑全部媒体测试。
- [ ] 更新发布支持矩阵、迁移说明、错误码表、依赖/制品来源及版本；报告远程 CI 实际链接与源身份。创建版本标签、推送、发布包属于明确发布动作，未收到该动作授权时只准备可审核产物。
- [ ] 整体复核通过后提交封板报告。仍有已确认能力未实现/未验收时只能报部分交付，不能宣布整个升级完成。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。

2026-09-30 P08显示回读的两项失败清理问题已修复：独立限时清理、未确认创建不提前报告已清理；19项定向Dart、静态检查及真实播放3/3通过。未标注素材色差、正式呈现时序和受控性能基线仍开放，完整Task1/2未完成，见执行报告。

2026-09-30 P08色彩参考判定修正：验证系统回读原色附件可能规范化为未指定，改为结合实际Core Image色彩空间判断；新增不改变解码样本的BT.601元数据对照。23项定向Dart、静态检查通过；BT.709/BT.601各3次正例通过，旧未标注素材1 reference-unqualified/2 skipped，不能计作其画质通过。未改生产色彩策略；完整Task1/2、物理呈现及受控性能基线仍开放，下一项继续呈现观测边界和测量协议，见P08报告。

2026-09-30 P08完成呈现边界审计和profile测量入口验证：修复Python工具误收public-event为baseline，27项测试通过；本机arm64 profile实际3/3通过，协议预先固定并保留参数/双架构构建失败。未改SDK或默认架构，不计正式呈现基线、Intel/universal或release通过；完整Task1/2保持开放，见P08报告及measurement-protocol.md。

2026-09-30 P08新增无暂停系统渲染统计工具：独立profile连续播放3/3，保留39条样本/33条统计，各窗口总计数增长64、丢帧/损坏增量0；21项Dart与静态检查、旧Debug暂停回读3/3通过。原始累计延迟保留，不能解释为首帧、单次卡顿或同步误差；显式示例profile开关不改生产API/默认构建。完整Task1/2及正式基线继续开放，详见P08报告。

2026-09-30 P08新增profile十轮创建/播放/释放资源观察：10/10通过，311点无缺失、battery/nominal；33项Python、15项Dart与静态检查通过。首末释放后端点RSS增加10.9375MiB、footprint增加13.984375MiB，完整保留并待归因，不宣称泄漏或完全回收。资源入口复用独立清理/创建不确定性保护；完整Task1/2、正式基线及长播仍开放，下一项优先定位该增长来源，见P08报告。
