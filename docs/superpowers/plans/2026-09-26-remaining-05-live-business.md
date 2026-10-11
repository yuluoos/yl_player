# P05 JavaScript / RTMP 业务闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 完成 TVS 真实构建、设备播放、订阅与九脚本可复现验收，并闭合实际源尝试的错误信息。

**Architecture:** 保留可选 QuickJS 解析模块和内核自有 RTMP 接收器。TVS 负责订阅与频道尝试，解析结果交内核；直连协议不依赖无关代理初始化，刷新/切台/取消均按任务代际关联。

**Tech Stack:** Flutter TVS、yl_player_source_resolver/QuickJS、yl_player RTMP、受控 HTTP/MediaMTX 验收工具。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；2026-10-11 从 `bdaf7bc` 开始 Task 1 的归档离线复核子项，见[阶段报告](../reports/2026-09-26-remaining-05-live-business.md)。三端/业务运行复验仍未完成。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 订阅返回 HTML/403/DNS：明确阶段，不假设永久失效或 token 过期（任务 2）。
- 脚本超时/取消后仍占资源或迟到覆盖频道：原生终止与业务代际都验证（任务 1/3）。
- 代理失败却阻断直连 RTMP/JS：按源所需能力初始化（任务 2）。
- 全部源失败只剩最后一条、汇总无限增长：有界记录实际尝试，保持关联（任务 3）。
- 受控九脚本通过但线上变化/归档丢失：版本与在线抽验分开（任务 1/4）。

---

## 范围与依赖

九脚本受控执行和三端媒体交接、基础 RTMP 已完成；TVS 已有集成及 93 项定向测试记录，但完整原生构建/真实设备/订阅验收未完成。不得把历史日志里的“跳过不支持”直接当当前实现状态。

本计划可立即开始受控与构建验收，不依赖 DRM。P04 运行时直播模式在其完成后接入。普通 RTMP classic AVC + 可选 AAC 为已有范围；RTMPS、增强 RTMP、其他编码和 audio-only 先核查，扩展变体未自动获准成为必交范围。

## 文件与接口

TVS 根目录：`/Users/yy2021_8689/Desktop/GIt/tvs`；执行前读其 AGENTS、git status、依赖锁文件，不撤销用户工作。
- 现有 TVS：`lib/utils/live_player_controller.dart`、`live_source_url.dart`、`live_source_manager.dart`、`live_source_parser.dart`、`playback_source_subscriptions.dart`、`subscription_utils.dart`；`lib/services/subscription_import_service.dart`。
- 现有 TVS 测试：`test/modules/live/features/live_source_resolution_test.dart`、`live_player_session_ownership_test.dart`、`live_player_stall_recovery_test.dart`、`live_source_parser_test.dart`；`test/modules/player/features/playback_source_subscriptions_test.dart`。
- 解析模块：`packages/yl_player_source_resolver/lib/src/script_resolver.dart`、`script_models.dart`、`script_http.dart`、`native_runtime.dart`。
- 受控发送端：`tool/rtmp_acceptance/README.md`、`run.py`、`test_run.py`。
- 新建：`docs/superpowers/reports/2026-09-26-remaining-05-live-business.md`；TVS `integration_test/live_subscription_playback_test.dart`。

消费现有 `YlScriptResolution.result: Future<YlResolvedSource>`、`cancel(): Future<void>` 和 `diagnosticId`；媒体仍用 Player.load。业务汇总不塞进单次 `YlFailure`，也不增加未经要求的自动换源策略。

### Task 1：九脚本恢复与可复现回归

- [x] 对照冻结样本账本核实九份原始字节仍在工作区受控私有目录，逐个 SHA-256 检查 9/9；源正文/真实地址未进入公开仓库。确认已离开历史临时目录且当前可取回；异机备份不在本轮证据内。
- [x] 提供离线 `--verify-only` 收据和生成器回归入口，保留失败行、固定安全诊断与原始字节，不执行脚本或生成设备入口。
- [ ] 为每脚本保留参数/宿主调用/同步异步/请求要求/有效期/刷新表，原始无 expiry 的结果继续标未知，不从 token 猜期限。
- [ ] 跑已有受控宿主与三端原生终止/媒体交接用例；缺接口与无有效地址分别断言。新增失效场景先失败后修复，不重写已通过解析器。
- [ ] 对 native cancel/timeout 记录 VM 与 HTTP 真正释放证据，下一次解析可继续；取消 Future 完成不等同仅隐藏迟到结果。
- [ ] 提交新增回归与可取回账本，保留历史哈希；新版脚本另建版本行。

### Task 2：订阅与源路由错误

- [x] 2026-10-11 完成内容解析子项：JSON 畸形条目隔离、M3U 引号内逗号/属性边界、JSON/TXT 判别和 HTML（含前导注释）误导入回归。TVS `f7a93e9`；解析29项、相关61/61，全项目分析通过，固定已提交播放器 `ffc4682`，未占用设备。下列下载分类、提示、代理和完整 Task 2 仍开放。
- [ ] 在 TVS 原测试加入受控 M3U/HTML、HTTP403、DNS失败、畸形条目、空列表。HTTP403 只说明服务器拒绝，HTML 只说明这次拿到网页。
- [ ] 添加代理启动失败但源为直连 RTMP、脚本返回直连 HTTP 的用例；先确认失败，再按实际请求依赖拆分初始化等待。确实依赖代理的源不能擅自绕过请求策略。
- [ ] 运行 TVS 定向测试：

```sh
cd /Users/yy2021_8689/Desktop/GIt/tvs
/Users/yy2021_8689/flutter/bin/flutter test test/modules/live/features/live_source_parser_test.dart test/modules/live/features/live_source_resolution_test.dart test/modules/player/features/playback_source_subscriptions_test.dart
```

- [ ] 提示输出失败环节、已知原因、建议和安全关联；直连无法提供代理吞吐时保留 unavailable。分别在 TVS 和播放器仓库提交本仓改动，报告准确的两个 commit。

### Task 3：刷新、竞态与失败汇总

- [ ] 先加入：A 频道脚本慢回包→切 B→A 返回；到期刷新中 stop/dispose；刷新失败保留/结束当前 session 按既有契约；RTMP 重连耗尽。不得将字幕/DRM 产品选择套到这里。
- [x] 核查业务已有上限为前 8 条、保留顺序并附省略次数；保留既有换源行为、HTTP 两次业务重连与 RTMP 不额外重连规则，未新增重试策略。2026-10-11 TVS `b81524b`。
- [x] 汇总保留真正尝试/跳过的源；`LivePlayerError.diagnostics` 独立保存安全阶段、已有分类与 diagnosticId，用户原因仍在 message。新增 source=1/10 脚本与 source=2/10 RTMP、元数据脱敏、旧请求 replace/stop/dispose 回归。
- [x] 2026-10-11 本地业务回归 76/76（含新增 8 项）、变更静态分析通过；固定播放器 `79dbfad` 验证，隔离并行 TTML 与 TVS XML 依赖差异。此结果不替代原生资源释放/真机验收。
- [x] 随后完成 TTML/TVS 依赖对齐：TVS `6ef7601` 仅更新 XML 7.0.1、dbus 0.7.15；当前 TTML 实际消费者与业务回归 80/80、全项目分析及严格离线锁复现通过，解除上一项的旧播放器快照限制。未占用设备。
- [ ] 跑 session ownership/stall recovery 测试，检查真实取消与预算，不因 error.retryable 自动无界重试；提交生命周期及错误闭环。

### Task 4：完整 App 和实际订阅验收

- [ ] 记录 TVS 声明的平台入口、插件版本/锁文件/本地依赖，分别构建其实际支持的平台；播放器独立 example 继续承担三端覆盖，不能假设 TVS 已有三端 runner。
- [ ] 构建采用对应项目实际配置：Android debug APK、iOS simulator/签名真机、macOS app。命令和签名限制写报告；缺 runner 或签名记为外部/工程缺口，不能以 mocked widget tests 代替。
- [ ] 在 owned M3U + 九脚本受控服务 + owned RTMP 上跑真实 TVS 首帧/音频/快速切台/断流/刷新/停止；服务日志、session IDs 和业务 UI 关联，测试名写入 `integration_test/live_subscription_playback_test.dart`。
- [ ] 对用户已给订阅仅按可用性抽验，记录时间、响应类型和哈希，不在公共日志打印内容中的签名地址。受地区/服务变动影响的失败单独记录，不修改夹具使其通过。
- [ ] RTMPS/增强变体输出可行性表：现有不支持原因、系统/开源候选、成本/安全边界、真实样本缺口。未冻结扩展范围前保留明确不支持，不假称所有 RTMP 家族完成。
- [ ] 提交业务验收报告与跨仓版本对应关系；P04 模式完成后补其实际 TVS 切换证据，交 P08 持续播放验收。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。
