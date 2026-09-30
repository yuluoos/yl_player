# P03 格式覆盖与受控解码 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 将已确认容器/编码落实到可播放组合，并实现按设备档位有界软解及真实硬解证据。

**Architecture:** 沿用各平台原生优先路由，通过样本识别实际容器/编码，不依据扩展名宣告支持。Apple 解复用、音频解码和视频软解分别核查；每次扩展制品只启用所需模块，硬解强制与固定画质约束贯穿回退。

**Tech Stack:** Media3/MediaCodec、AVFoundation/VideoToolbox、裁剪 FFmpeg、Dart 策略/能力模型。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；2026-09-29已开始Task1组合/素材及macOS基线调查。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 扩展名与内容不符、无索引/截断媒体：实际探测并给出准确阶段错误（任务 1/2）。
- 10-bit/Profile/多声道可解但输出不支持：不声称整条播放链可用（任务 1/2）。
- 初始硬解成功而重建变软解：hardwareRequired 全生命周期校验（任务 3）。
- 软解帧重排、候选/当前共存、持续播放：内存与计算预算不能漏计（任务 3/4）。
- 解码失败时偷偷减分辨率或 HDR 降级：保留独立策略并明确失败（任务 3）。

---

## 范围与依赖

格式集合直接来自 REQ-10：MP4/MOV、MKV/WebM、FLV、MPEG-TS/PS、AVI；H.264/H.265、VP9、AV1；AAC、MP3、AC-3/E-AC-3、DTS、FLAC、Opus、Vorbis。WMV/WMA、RM/RMVB 不纳入。本计划覆盖合理组合，不计算所有格式笛卡尔积。

现有 Apple FFmpeg 制品不等于完整 FFmpeg；已有解复用及 AVC/HEVC + AAC/MP3 路线需保留。Android 已有受限 AVC/HEVC 软解证据，不能直接给 Apple/VP9/AV1 套同一限额。P08-A/B 在任何性能优化及预算定值前完成；新增无法播放路径记录无可比基线。普通格式工作可先于 P01 完成，P01 异编码跨段消费本计划结果。

## 文件与接口

- 现有制品：`packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh`、`verify_artifact.py`、`test_build_contract.sh`、`test_video_metadata.sh`。
- Apple 路由：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlOpenCoordinator.swift`、`Shared/FFmpeg/YlDemuxPipeline.swift`、`Shared/VideoToolbox/YlVideoToolboxDecoder.swift`、`YlHardwareDecoderEvidence.swift`、`Engines/ManagedFallback/YlFallbackBackend.swift`。
- Android：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Configuration.kt`、`YlMedia3Core.kt`、`YlDecoderLeaseCoordinator.kt`、`YlPlayerErrorPolicy.kt`。
- 契约：`packages/yl_player_platform_interface/lib/src/options/policies.dart`、`model/source_assessment.dart`、`model/capabilities.dart`、`model/failure.dart`。
- 新建：`docs/superpowers/reports/2026-09-26-remaining-03-formats-decoding.md`、`packages/yl_player/example/integration_test/format_matrix_test.dart`、`decoder_budget_test.dart`。

消费 `YlDecoderPolicy.systemDefault/hardwarePreferred/hardwareRequired` 和既有 source assessment；输出逐能力行的实际路由、decoder 证据、媒体格式和资源计量，不新增“canPlayEverything”式总开关。预算模型若需新字段，先用合约测试固定单位、默认值与旧适配器行为，再更新双端 schema。

### Task 1：组合矩阵与原始样本

- [x] 创建 `tool/media_matrix/cases.json`（新增），每个 REQ-10 容器/编码在三端有可追踪行；本地/HTTP、Profile、位深、声道、seekability 分列。不得用几个 AVC 文件代表全部格式。
- [x] 每行记录独立 probe 元数据、来源/授权、SHA-256、预期时长、画面/声音标记、基线是否可播放。行结构采用总览的能力字段；新增元数据结构示例：

```json
{"caseId":"FORMAT-MKV-AV1-OPUS-LOCAL","container":"matroska",
 "video":{"codec":"av1","bitDepth":8},
 "audio":{"codec":"opus","channels":2},"transport":"file",
 "implementation":"unverified","verification":"not_run"}
```

示例不是已验证支持声明；真实条目必须补齐媒体哈希、平台和证据。

- [ ] 在 `format_matrix_test.dart` 为每个实际夹具先固定首帧、音频时标、seek 恢复、结束与释放断言；错误扩展名但同字节应保持探测结果一致。损坏/无索引行有明确预期，而不是一律允许失败。
- [ ] 运行现有路由获得通过/失败列表，记录缺解复用、缺decoder、缺输出三类原因；已有通过路径成为回归基线，提交夹具与差距报告。

### Task 2：按缺口扩展解复用与音频

- [ ] 按 Task 1 结果依次处理 WebM/网络或本地 FLV、TS/PS、AVI 路由缺口；每个组合先加入实际播放失败测试，再扩展探测/解复用。缺索引 seek 是单独行为，不能为首帧成功忽略。
- [ ] 对 AC-3/E-AC-3、DTS、FLAC、Opus、Vorbis 的解码/声道布局/音频输出逐项实测；系统支持与 fallback 支持分开。多声道输出或降混必须保留明确布局规则，不能将有音频轨当作有声音。
- [ ] 修改裁剪构建时记录开源依赖版本、启用模块、license、二进制架构和大小；只增加有对应样本的模块，保留 product 禁用网络边界，不能引入商业 SDK。
- [ ] 运行制品 contract/metadata checks 和格式公开套件，验证 macOS arm64/x86_64、iOS device/simulator 构建切片；实际 Intel/真机播放另记，不能由交叉编译代替。
- [ ] 按容器/音频能力切片提交，支持文档只新增已实测组合。

### Task 3：视频解码与回退预算

- [ ] 先测试各平台 H.264/H.265、VP9、AV1 的硬解可用/不可用和 Profile/位深差异；将 decoder 选择与实际 hardware 证据对齐，未知状态不得当硬解。
- [ ] 消费 P08 的设备基线，为每 codec/设备档位/分辨率/fps 冻结软解支持及 CPU/RSS/热阈值。无数据的档位不自动开放，使用已有明确失败路径。
- [ ] 构造硬解失败、切段重建、decoder lease 争用、软解超限测试，锁定错误码 `decoder.unavailable` / `resource.exhausted` 与 scope。公开断言示例：

```dart
// hardwareRequired + 已证明只能软解的 owned 样本：
expect(failure.code, YlFailureCodes.decoderUnavailable);
expect(failure.retryable, isFalse);
// failure 由测试捕获实际 YlPlayerException.failure，不能自行构造通过断言。
```

- [ ] 实现最小缺失解码路径；分配前校验尺寸/帧率/重排深度，运行中资源超限有界结束，不修改固定清晰度或动态范围。软件路径无权报告硬解。
- [ ] 跑 `decoder_budget_test.dart` 和真实重建/多播放器用例；每个已开启的软件 codec 独立提交和报告。

### Task 4：组合封板与跨计划交接

- [ ] 对已支持组合跑播放/暂停/seek/倍速/切音轨/后台/释放，校验输出图像和音频标记；对连续创建销毁及长播记录资源回收和增长曲线。
- [ ] 将准确 codec/profile/色彩/输出能力交 P01 跨段、P02 字幕、P04 ABR、P07 映射，不能以 MIME 字符串代替完整兼容条件。
- [ ] 所有已确认格式必须有行；不成立的组合附技术证据，真正无法满足的确认范围保留缺口并提出产品变更，不能自行删掉。
- [ ] 运行对应原生/公开检查及本次修改影响的旧音频/FEL 回归，提交报告并进入 P08 共同验收。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。

2026-09-29 Task1进度：17份原创夹具/102调查行、独立颜色与声道音调验证、macOS51条公开路径观测及逐项现状回归入口已交付。公共生命周期成功17条，有效素材缺口31条，损坏输入拒绝3条；默认回归匹配不得计为51条格式支持。完整Task1的输出标记/音频时标及其他平台仍待验，详见[执行报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 Task2首个切片：修复已探测/显式MP4格式在AVPlayer资产创建时丢失的问题；本地`.bin`、无扩展名及HTTP`.bin`通过严格生命周期回归，截断文件保持拒绝。公开MIME接口门槛为macOS14/iOS17；部署下限保持不变，旧系统缺口及iOS实测保留。容器/音频扩展、HEVC seek、完整Task1输出验收均未完成。

2026-09-29 HEVC跳转切片：普通HEVC解码序列增加CRA/BLA随机访问RASL过滤；MOV/Main10 MKV的6条本地/HTTP/改名路径通过前向2秒、反向1.25秒及自然结束严格测试。完整输出、跨平台/最低系统、其他Profile及格式/音频扩展仍未完成，Task1/Task2不整体勾选。

2026-09-29 Task2 FLV点播切片：本地FLV启用真实准备路径，HTTP显式onDemand使用随机访问传输；三条AVC/MP3路径通过前后seek及结束，nonRange三意图和原有直播重连回归通过。其他音频/容器、完整输出、跨平台/最低系统验收仍未完成。

2026-09-29 Task2 FLAC切片：新增桥接ID及STREAMINFO传递，系统转换器支持受检16/24位mono/stereo；两份48kHz夹具通过独立PCM逐样本核对，MKV AVC/FLAC三条公开路径通过双向seek与自然结束。WebM完整解码链、FLAC其他位深/多声道、物理输出/同步和其他平台仍未完成。

2026-09-29 Task2独立MPEG-TS切片：188字节AVC/AC-3的file/http/同字节改名文件通过时间轴、双向seek、结束与释放；补齐相对时间、有限关键帧定位和明确错误提示。192/204仅探测测试，严格策略/live、其他codec/平台/物理输出仍未验收；WebM/PS/AVI等缺口及Task1整体仍开放。

2026-09-29 Task2 AVI切片：只增加AVI demuxer，受检Baseline AVC/MP3的file/http/改名路径及本地移除idx1后的双向seek/结束通过；补齐受限PTS和关键帧定位、明确错误。其他Profile/codec、OpenDML/大文件、物理输出/同步/跨平台以及WebM/PS等仍待完成。

2026-09-29 Task2 Opus前置制品：新增原生CELT-only Opus桥接及所需swresample，mono/stereo独立PCM对照；SILK/hybrid在输出差异解决前明确拒绝。Swift路由尚未启用，容器trim/seek preroll和公开播放器验证为下一切片；Task1/Task2和完整Opus/WebM仍未完成，最终构建与验证证据见执行报告。

2026-09-29 P03继续接入普通Matroska AVC/Opus CELT播放：显式首尾裁剪、seek预解码与PCM目标裁剪、固定安全错误。仅family0 mono/stereo48k；切换到另一Opus音轨先明确拒绝并保留当前播放。SILK/hybrid、完整WebM、严格策略、物理输出与跨端验收仍未完成，Task1/Task2不勾选。最终证据见P03执行报告。

2026-09-29 P03 Opus继续：活动会话切入/切出Opus复用seek事务，补齐代次隔离、容器回退、PCM裁剪与时钟锚点；暂停状态和播放意图保留。范围仍为CELT子集，完整Opus/WebM与Task1/Task2仍开放；细节和验证见P03报告。

2026-09-29 P03 Opus模式扩展：已用固定开源libopus1.6.1替换native Opus/swresample，SILK/hybrid/CELT family0 mono/stereo PCM及五目标可重建制品通过。完整Opus/WebM、严格策略、物理输出和跨端验收仍开放；不勾选Task1/Task2，最终公开验证见P03报告。

2026-09-30 P03 Vorbis切片：普通Matroska mono/stereo 44.1/48k通过native FFmpeg解码、200ms预解码、PCM目标裁剪及活动音轨切换；零CodecDelay与严格策略边界明确。64项macOS原生回归、5项公开Vorbis策略/切轨、3条严格格式路径通过；无商业SDK，Xiph参考库仅测试使用。物理输出/多声道/WebM视频/跨平台仍待完成，Task1/Task2不勾选；完整矩阵证据见P03报告。
