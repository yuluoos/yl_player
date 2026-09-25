# DASH 多档位与直播业务接入 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. 用户已授权继续，保留现有功能分支；不要自动 commit、push。每个任务独立实现和复审，原生构建串行。

**Goal:** 扩展 Apple 静态 DASH 为可实际播放的兼容多档位清单，并将已完成的 JS/RTMP 能力接入用户指定的 tvs 业务入口。

**Architecture:** Apple 继续使用有界 MPD → 会话私有 HLS → AVPlayer 路线，生成多条完整节目时间轴的视频 playlist，由 AVPlayer 自动选择兼容档位；业务端使用独立 resolver 解析 javascript 引用，保留取消所有权，再交给既有 NativeVideoPlaybackSession。RTMP 绕过 HTTP 代理和 HTTP 请求头策略。

**Tech Stack:** Swift / AVFoundation、Dart / Flutter / Riverpod、现有 QuickJS resolver。不增加商业 SDK、外部协议依赖或公开 wire schema。

**Spec:** `docs/superpowers/specs/2026-09-20-playback-expansion-requirements.md` REQ-02/04/05/06/07/13 与 PD-01 的 2026-09-24 用户决定。业务仓库 `/Users/yy2021_8689/Desktop/GIt/tvs`，遵守其 AGENTS.md。

## Global Constraints

- Android API24、iOS15、macOS12 下限不变；播放器当前基线 2b24d93；tvs 起始干净。
- 现有 MPD 2 MiB、深度64、Period64、段100000、单URI8192 UTF16、累计URI4194304、单playlist2MiB/总registry4MiB上限继续按整个文档累积。
- 跨域凭据剥离不可恢复，资源共享取最严格来源；所有媒体经过原代理；URI/脚本/请求头不进入错误或日志。
- 新增 Apple 上限：每 Period 最多16个视频档位，全文最多256个 Representation（包含音频），在展开前验证；既有总资源预算共用。
- 本次 Apple 多档位只纳入同 AVC codec、同角色、对齐分段、兼容音轨、各 Period 完整相同质量梯度。不得静默映射不同格式或 HDR/SDR；复杂梯度变化仍明确拒绝。
- 固定档位跨 Period 缺失：用户明确选择自动回到自动清晰度、允许降低。自动模式支持不代表固定控制 API 已实现；PD-02/03 不代替用户决定。
- tvs 只增加已授权独立本地 resolver 包；沿用现有 provider/session/proxy，错误走 AppError，生成文件用 build_runner。
- 取消需停止原生 JS 和网络工作；旧解析结果不能发起新的 load；原始源用于显式刷新，过期未知不猜测。
- 不发起真实第三方订阅播放，不下载或记录私有脚本；使用自有或受控夹具。

## Review Focus

1. 多档位跨 Period 顺序/ID 变化：按稳定质量属性一一匹配，不依赖 XML 顺序或跨段 ID 相同。
2. 多档位时间对齐与重复身份：不兼容或歧义在媒体 emission 前拒绝，旧单档位行为保留。
3. 所有档位共同计费和凭据最严格合并：新增档位不能绕过资源预算或复活凭据。
4. 业务切台/停止发生在脚本解析期间：取消完成后旧结果不能播放，失败可安全进入已存在的备用源顺序。
5. RTMP 经 JS 或直接输入均不附带 HTTP 默认请求头、不送 HTTP 代理；业务重试不能无限重置内核恢复预算。

## Task 1: Apple DASH 兼容多档位

**Files:** `Shared/DASH/YlDashDocument.swift`、`YlDashHlsCompiler.swift`；canonical `YlDashHlsCompilerTests.swift` 及镜像、current manifest；按需要添加受控多档位媒体和 integration_test；更新平台文档及阶段报告。

**Interfaces:** 保持 `YlDashHlsCompiler.compile` 和 `YlDashHlsPresentation` 公共内部调用签名；Period 内部由单 video 扩为有界 videos，单档位生成身份继续兼容。无需新增公开清晰度接口。

- [x] 先写编译器行为测试：两个不同尺寸/码率 AVC 档位生成两个真实完整视频列表；跨 Period ID/顺序变化仍正确映射；音频组共享；不兼容、歧义、分段不齐、预算超限拒绝；观察旧实现有意义的失败。
- [x] 实现受限梯度解析/验证，整个解析完成后才调用媒体 URL closure。精确有界有理数对齐，不能通过 Double 四舍五入认定相等。新增 representation 硬上限并文档化。
- [x] 生成每个视频梯度的私有 playlist，统一 discontinuity、真实 bandwidth/resolution/codecs，不声明未经证明的 independent segments。所有档位的媒体都沿用既有来源图。
- [x] 跑 compiler + loader 回归，核对 canonical 镜像/hash/current inventory。macOS/iOS 聚焦原生测试串行；不得顺便全套。
- [x] 受控真实多编码档位夹具验证 macOS/iOS 公共 firstFrame、跨 Period 和 seek；若只证明播放器消费多档位，不声称弱网 ABR 上下切换或硬上限已验收。记录实际选择/请求可观察证据与限制。
- [x] 更新永久报告、平台支持；任务自检和独立复审。

## Task 2: tvs JS/RTMP 业务接入

**Files:** tvs 的 `lib/utils/live_source_url.dart`、`live_player_controller.dart`、`lib/providers/live_player_provider.dart`、`lib/services/native_video_playback_session.dart`（仅需要时）、`pubspec.yaml`/lock/generated wiring、对应目标 tests。加载 tvs edit-workflow 和必要领域 skill。

**Interfaces:** 使用 `YlScriptResolver.resolve(YlScriptReference.parse(input))`、`YlScriptResolution.result/cancel`、`YlResolvedMedia.toNetworkSource()`（实际类型以当前模块为准），适配既有 NativeVideoMedia，不丢失解析请求要求及 live intent。

- [x] 阅读目标及上下游和最近测试，先添加失败用例：合法 RTMP 不跳过、脚本进入解析、错误分类、RTMPS明确拒绝、地址脱敏。
- [x] 接入本地 resolver；保留每次任务所有权和 generation；stop/dispose/replacement 等待取消；JS 原始引用用于重试刷新，不把旧 token 当永久源。
- [x] RTMP 直接进入内核，不进入 HTTP 代理、不自动追加 HTTP 请求头；失败聚合保留本次实际源序号与安全原因，数量/文案有界，不增加换源策略。
- [x] 检查现有业务 reconnect 和内核三次终身恢复的边界；RTMP 内核终止后避免相同源重开循环。HTTP 原策略不退化。
- [x] 执行必要 pub get / build_runner（仅项目约定）、目标 URL/controller/provider/session tests 和 analyze；不启动设备或修改另一个仓库。所有外部仓库写入正常申请工具权限，不绕过 sandbox。
- [x] 记录实际检查、未执行真实订阅/真机证据；任务自检和独立复审。

## Task 3: 清理已知 RTMP 测试工具残留引用

**Files:** `tool/rtmp_acceptance/run.py`、`test_run.py`；对应阶段报告追加修复记录，历史评审结论不改写。

**Interfaces:** `Proxy.reader` 结束时从 `Proxy.tasks` 移除 reader 自身；不改变网络协议、播放器或 cleanup receipt 语义。

- [x] 添加不创建套接字/进程的 EOF 重复连接用例，断言 active 为零且 task 集合为空；旧实现应因保留已完成 owner 而失败。
- [x] 独立命名 reader owner 与 forwarding child，在 finally 移除 owner；保留现有取消和关闭顺序。
- [x] 执行工具最小回归及既有清理测试；播放器未变，无需重复三端播放。独立复审聚焦该范围。

## 完成边界

三个任务分别交付代码、回归及独立复审。PD-01 已确认但完整固定档位接口、严格上限、跨动态范围和梯度增删不是本批支持声明。全部未完成目标继续保留；不能把本次多档位适配等同通用 DASH 升级已完成。

## 整批复审收尾

- [x] 三项独立任务复审及整批复审完成；Apple/runner 无阻塞发现。
- [x] 集中修复 tvs 脚本由 HTTP 切换为 RTMP 后的同源重开边界、真实启动包装中的结构化错误丢失，以及断连文案误报恢复耗尽。
- [x] 覆盖实际调用链的回归通过后，对修复增量进行一次复审，更新最终测试数量和验收报告。
