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

2026-09-30 P08补充无播放器profile十轮对照：最终对照/播放各10/10，300/310点无缺失；同源同设备battery/nominal。对照也出现第5轮约9.59MiB footprint阶跃，故该阶跃不足以证明播放器泄漏；最终首末对照+6.21875MiB、播放+14.21875MiB，不相减推算所有权。37Python、15Dart和静态检查通过，保留VM探索及元数据修正前两组证据；生产代码未改。完整Task1/2及增长对象归因仍开放，下一步原生分配/内存类别与生命周期证据，见P08报告。

2026-10-07 P08补充系统内存类别诊断：空载/播放各10/10，vmmap摘要各3/3，45Python测试通过。两组第5轮都出现Malloc Large(empty)7904K驻留脏页；独立full分配历史找到AppKit窗口快照路径约7.71M malloc，尚未与空闲区域做地址级对应，不宣称整个增长已归因/无泄漏。保留lite查询失败、full工具额外开销及严格解析拒绝；生产代码未改。完整Task1/2和对象生命周期仍开放，下一步关联区域地址与释放历史，见P08报告。

2026-10-07 P08完成空载大块地址归因与原生生命周期短观察：同地址8089600B AppKit快照ALLOC/FREE已配对，所属8110080B VM区域仍保留为空闲大块；不能外推整个进程无泄漏。播放十轮和3个受rawclock约束的heap窗口通过，live可识别核心Host/会话/解码器等，第2/8轮释放后未列出，插件级registry仍在。50Python、静态分析与独立profile验证通过；旧测试入口6→8已修正。生产代码未改，完整Task1/2及长期/后台/多播放器仍开放，下一项固定长期资源观察协议，详见P08报告。


2026-10-07 P08百轮加载/释放耐久观察完成：100/100通过，641.763245s、3104点无缺失，ac/nominal。新增固定协议/失败保留/时长准入，55Python、15Dart与静态检查通过；首末释放后footprint+25.859375MiB，第50→100轮+10.390625MiB，尚不能认定平台期或无泄漏。完整源码/协议/日志归档，生产代码未改；连续长片、后台/多播放器/低内存及完整Task1/2仍开放。下一项优先独立长周期对象生命周期归因，见P08报告。


2026-10-07 P08百轮生命周期归因：100/100播放和8/8窗口内heap/vmmap通过，60Python与静态检查通过。核心原生对象在live可识别，第10/50/100轮释放后未列出，registry仍1；后半程主要增长类别为Untagged脏页32.5M→39.5M与Malloc Small19.2M→21.4M，匿名堆分配也增加，具体所有者仍未知。没有生产改动或无泄漏/优化比例声明，完整Task1/2仍开放；下一项关联未标注区域、Dart堆指标及匿名分配来源，见P08报告。


2026-10-07 P08 Dart堆/地址关联完成：正式100/100播放、12/12窗口探针通过，66Python通过；修复硬超时/无效响应丢失，保留主动中止的初次10轮。已测非系统Dart group后半程用量下降，而Untagged脏页增加；定位一段19693568B虚拟区间的脏页176K→2944K→12.1M→18.8M，未证明其所有权或分配连续性。生产代码未改，下一项补系统group指标及地址级分配/释放历史；完整Task1/2仍开放，见P08报告。

2026-10-07 P08系统group/短程地址栈归因完成：独立10/10播放、15/15窗口探针、73Python通过。当前精确19693568B Untagged映射的VM_ALLOC栈定位到Dart Profiler SampleBlockBuffer，九次查询是同一范围的重复证据；未观测释放，不等于泄漏或过去百轮地址的所有权证明。系统group指标已补齐，初次reserved分类解析失败完整保留；修复半行日志终止采集的复审问题。生产代码未改，下一项验证Profiler开关支持并冻结独立对照协议，区分测量开销与剩余匿名增长；完整Task1/2仍开放，见P08报告。

2026-10-07 P08完成Profiler运行时开关短程对照：两组各10/10播放、9/9窗口探针，条件匹配，78Python通过。目标同大小映射脏页on192K→3056K、off保持176K，支持采样器贡献该类增长；关闭组RSS/footprint及Malloc Small仍有增长，未宣称全部解决。保留启动时间1ms变化导致的预备失败，使用严格PID/group身份并回读实际flag。无生产/SDK/Dart改动。下一项固定Profiler关闭后的百轮资源/生命周期复核；完整Task1/2仍开放，见P08报告。

2026-10-07：P08完成Profiler关闭后的百轮资源/生命周期复核，100/100播放、16/16探针和81Python测试通过；目标大小区域四次脏页均160K。第10/50/100轮FlutterEngineHandlerInfo为179/859/1709，精确每轮增加17，与14播放+3DRM通道卸载路径吻合；属于待回归和修复后对照验证的保留假设。无生产改动，不据此宣称无泄漏或全部增长已归因。下一项定向连接清理回归与修复，完整P08 Task1/2仍开放，见报告。

2026-10-07：P08修复macOS host通道卸载记录保留，保存原连接号并按公开API清理，覆盖重复detach/外部新连接/存活peer；3项真实引擎回归RED→GREEN、完整原生589/589与7项工具测试通过。相同Profiler-off百轮100/100、16/16通过，释放后HandlerInfo由179/859/1709变为9/9/9；无SDK/生成代码改动。non-object后半程仍增加20,136个/1,127,792B，下一项有界分配栈归因；不报告全局无泄漏或性能比例，完整P08 Task1/2仍开放，见报告。

2026-10-07：P08完成剩余分配短程调用树归因，最终10/10播放、9/9探针、86Python通过。保留首次non-object空树归因失败，并冻结全类别v2；完整原树无损压缩归档。栈与heap定位部分增长为Timeline事件/异步轨道元数据（Profiler已off但Timeline仍ring），不是全部百轮增长或泄漏判定。无生产改动；下一项验证Timeline控制并冻结独立对照，完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成Timeline流独立启用/关闭对照，正式两组各10/10播放、9/9探针，92Python通过。保留HTTP枚举列表编码失败的预备整组，不计通过；按本机Dart源码修正并重跑。Profiler均off，Timeline四流/空流实际回读成立，关闭后已定位事件/异步元数据类型三窗不再增长；其余内存指标仍有变化。无生产/SDK改动，不作全局无泄漏或性能比例结论。下一项Profiler与Timeline双关闭、无MSL百轮复核；完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成Profiler/Timeline双关闭、无MSL百轮资源复核，100/100播放、16/16探针、96Python通过，732.713140s/3220点全acnominal。释放后核心类型未列出，HandlerInfo9/9/9；后半程non-object仍+172个/38,288B、RSS/footprint各+1,851,392B，不判稳定平台/全局无泄漏或优化比例。全部证据归档，无生产改动。下一项连续长片协议与验证，残余变化保留观察；完整P08 Task1/2仍开放，见报告。

2026-10-07：P08新增同会话20分钟连续播放验证，并修复长素材暴露的Apple桥接长度前缀误判：合法avcC/hvcC包不再被Annex B嗅探改写。真实100包19→0损坏、149边界检查通过、五目标重建逐字节一致、原生589/589、Dart18、Python102通过。两次起播失败完整保留；修复后241点/1200.928800s连续性及清理通过。footprint播放期+568,705,408B，释放后仍高于起播，RSS也有明显变化；电源234battery/7ac，非恒定基线。不宣称资源稳定/无泄漏/物理音画或完整Task1/2完成；下一项优先长播内存增长归因，详见P08报告。

2026-10-07：P08完成单会话长播内存分类取证及两项采集器留证修正，109Python通过；预备失败完整保留。最终241点/1200.908652s、12/12探针合格，但五个进度比超限及累计−5.794652s使连续性complete=false，未改门槛。三窗PCM173→28145→53793、Token199→28171→53818，heap15.37→277.19→517.49MB；诊断开关已回读关闭，Dart组堆未同量级增长。下一项音频完成回调持有/释放回归与定向修复验证；不宣称全部所有权/无泄漏/性能通过，完整P08 Task1/2仍开放，见报告。

2026-10-08：P08修复已播放PCM被完成闭包持续持有的问题；真实AVAudioEngine20缓冲RED(20个/163840B残留)→GREEN，重复及flush/dispose延迟回归通过，音频21/21、全macOS原生592/592、工具7/7。相同20分钟协议241点/1200.972374s，12探针合格，PCM46/46/46、Token71/72/72；完成容器/dispatch source仍累积，heap首末+35,672,400B。三个进度区间仍使complete=false，不声称连续性/全局内存通过。下一项残余回调/计时器生命周期及无heap干扰连续性验证；完整P08 Task1/2开放，见报告。

2026-10-08 P08完成残余音频回调/计时器有界归因：独立原生200缓冲全部回调后仍保留200标记，反向引用指向系统AVAudioPlayerNodeImpl::Command，分配栈确认该路径创建200个dispatch source；stop/reset后该分支及标记消失。最终16槽位10采集/6不适用、112Python通过；预备格式配置失败完整保留。生产代码未改，不外推全部匿名所有权/系统版本或性能通过。下一项验证保持播放完成时序的有界回调方案，无heap长播连续性及完整Task1/2仍开放，详见报告。

2026-10-08 P08修复逐缓冲同步锁累积：每renderer完成回调共享一把锁，独立保留一次性payload所有权，不改dataPlayedBack/时钟/重置行为。200缓冲原生资源回归锁2→202实际RED，修复后3/3/3/3 GREEN；24音频、595全macOS原生、7工具通过，镜像及运行身份一致。系统计时器和200个完成外壳仍保留，不计整体内存有界/长播通过。下一项比较回调时序与保留策略，无heap连续性和完整Task1/2仍开放，见报告。

2026-10-08 P08完成回调模式×固定/暂停变速六组原生对照：1200回调、3220时钟点、36探针合格，116Python通过。consumed/rendered未见200完成外壳及Command计时器，playedBack两场景均保留200；暂停后仍有5个playedBack回调，10跨动作/5空时钟配对保留排除。未改生产API，不将节点时钟/报告延迟当物理播放。下一项验证rendered通知+有界输出完成调度原型，必须覆盖暂停在途完成、变速、未知延迟/时间戳和旧代隔离；计时器修复、无heap长播与完整Task1/2仍开放，见报告。

2026-10-08：P08完成有界输出回收实验原型，14项Swift行为与最终121项Python回归通过（含复审补齐播放窗口有效时钟门槛）；两组原生双节点各200次完整配对，队列峰值6/12。候选分别30/42次早于参考playedBack回调（最多0.133ms），按预冻结零容差门槛两组complete=false，未接入生产，未将派发先后当物理音频结论。完整失败证据保留；下一项明确输出完成契约与设备进度依据，不以经验延时调参替代证明。系统计时器增长、无heap长播和完整P08 Task1/2仍开放，见报告。

2026-10-08：P08明确音频输出完成契约，session结束改用当前代待完成缓冲数，不以时长归零或渲染时钟到末尾代替播放完成。新增三项回归覆盖末尾时钟、暂停在途及零时长/旧代隔离；等价旧时长判断实际RED→GREEN，27音频、598全macOS、7工具通过，零失败/跳过，镜像599/669核对。生产仍用playedBack，未接入失败期限原型。下一项在保留行为下拆分资源释放/媒体时钟/最终排空责任；系统计时器增长、无heap长播和完整P08 Task1/2仍开放，见输出完成契约及报告。

2026-10-08：P08完成双阶段资源/播放通知及媒体时钟/排空职责拆分，生产输出仍由同次playedBack触发；资源先释放时保守保留全局字节/时间预算，不能提前推进时钟或排空。五项新增回归、32音频、最终603全macOS通过；首次602/603失败完整保留，诊断证实占位AV输入可在旧回调前TLS失败，改为受控本地输入后原租约断言及健康断言1/1通过。共享镜像604/669一致，无iOS运行或内存改善声明。下一项验证明确最终音频边界与容量约束，系统计时器增长/无heap长播/完整P08仍开放，见报告。

2026-10-08：P08完成默认关闭的音频尾部候选接入设计，拆为准入策略、输出通知、renderer 预算/排空、时钟/控制、真实验收五项，见[实施计划](2026-10-08-apple-audio-terminal-integration.md)。首阶段仅 macOS 本地有限可 seek 点播，明确排除 buffer.bounded，保留其硬约束与原播放路径；默认 legacy、不接入商业 SDK。已核查生产 token、首次 PCM 提交锚点、回调锁序与无 display tick 定时观察边界。本项仅文档自审与路径核验，未改生产或执行测试，不计内存修复/正式准入；下一项执行子计划 Task 1，完整 P08 Task1/2 仍开放。

2026-10-08：音频尾部候选接入子计划 Task 1 已完成内部纯准入策略，四项新增回归实际RED→GREEN，音频36/36、夹具4/4、镜像发现669/608核对。尚无生产调用点，默认播放未变；来源元数据/PCM/输出检查和正式准入仍待后续验证。下一项为[子计划 Task 2](2026-10-08-apple-audio-terminal-integration.md)输出通知模式，完整P08保持开放。

2026-10-08：音频尾部候选接入 Task 2 完成明确输出模式与默认兼容桥接，实际双PCM rendered/playedBack及拒绝输入两项RED→GREEN，音频41/41、夹具4/4、镜像669/613核对。renderer仍用旧入口，候选未启用，无内存/物理音画结论；下一项为[子计划 Task 3](2026-10-08-apple-audio-terminal-integration.md)真实预算/最终排空。完整P08保持开放。

2026-10-08：音频尾部接入 Task3完成内部显式renderer预算接管、提交时钟与最终排空；默认上下文nil。新增15项，核心及三处边界实际RED→GREEN，最终音频56/56、夹具4/4、镜像669/628核对；真实AAC转换器单块8192B仅计费一次，输出为可控通知。session/自动timer/路由和长播尚未接入或验收，不计生产准入/整体有界；下一项[Task4](2026-10-08-apple-audio-terminal-integration.md)，完整P08开放。


2026-10-08：音频尾部接入 Task4完成默认关闭的内部session来源准入、首次PCM提交锚点、独立10ms目标timer及配置失效失败链。新增11项；最终音频60+session53共113/113、夹具4/4、发现676/639核对。timer缺失、失效后静默play和钩子锁顺序均实际RED→GREEN；受控音频/视频尾部完成不等于物理输出验收。[下一项Task5](2026-10-08-apple-audio-terminal-integration.md)补真实节点、完整套件、独立长播/资源和全计划复审；默认未启用、整体有界未证明，完整P08开放。

2026-10-16 Task D离线准备：完成33组CAP/ERR/REG×三平台及性能/消费者/CI三个门槛的可执行台账，分别保留实现、验证和缺项；校验需求覆盖、报告hash、源码/制品身份与完整验收声明。该子项可先于最终设备验收执行，不将整个D或P08勾选。当前PD-01/02/03均已确认，以需求v2.2为准；历史计划未确认字样不再构成阻塞。没有冻结虚构性能数字，没有重跑设备/长播，详见报告与tool/release_readiness/README.md。
