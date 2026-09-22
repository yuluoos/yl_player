# DASH 点播接入 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development；完成任务后独立审查，不自动提交或发布。

**Goal:** 实现公共 DASH 格式契约和 Android 明文 static MPD 路由，提供真实播放与网络策略验证；Apple 明确识别并拒绝尚未实现的路由。

**Architecture:** enum 末尾追加 dash，保持现有 wire ordinal；使用相同版本 Media3 DASH 模块及现有 owned DataSource/重试策略。DASH parser 包装层在发出媒体请求前登记 BaseURL 和分段的凭据继承，显式处理未知/跨域路径；不自写媒体解复用器。

握手核查补充：仅追加枚举不能保护旧原生解码器；私有 schema 升级为 3，公共 SPI 仍为 2。Create 阶段安全拒绝混合版本，要求 Dart/native 同步重建；见[兼容说明](../../transport-compatibility.md)。

**Tech Stack:** Dart/Pigeon28、Kotlin/Media3 1.11.0、Swift、Flutter integration_test、FFmpeg（仅生成合成测试夹具）。

**Spec:** [需求基线](../specs/2026-09-20-playback-expansion-requirements.md) REQ-02/04、CAP-DASH/PERIOD、REG-API/NET/LIFE；[架构核查](2026-09-22-playback-feasibility.md)。

## Global Constraints

- Android API24、iOS15、macOS12 下限不变；不接入商业 SDK。
- 此为共同交付中的实现阶段，不宣称 Android 单端就是三端交付完成。Apple DASH 播放、DRM、完整 ABR/字幕矩阵仍是已确认范围，不能从需求删除。
- 保留当前工作区上批错误语义、FEL、文档改动；本批独立记录差异、未提交。
- 同源凭据与跨域后返回原域的继承规则必须保持；manifest、init/index/media 请求均受现有网络策略控制。
- 严格 buffer.bounded/hardwareRequired、生命周期和重试预算不放宽；敏感 URI/头/原生异常不进入公开错误。
- 不决定 PD-01/02/03。沿用现有自动选轨及画质约束，不声称手动固定与跨动态范围规则已完成。

## Task 1: 格式契约、Android 路由与 Apple 拒绝边界

**Files:**
- `packages/yl_player_platform_interface/lib/src/source/media_source.dart`、相关模型测试。
- Android/Apple `pigeons/yl_player_*.dart`、对应 `lib/src/*_codec.dart`、生成 Dart/Kotlin/Swift 文件及 codec 测试。
- Android `android/build.gradle.kts`、`YlSourceAssessment.kt`、`YlMediaSourceFactory.kt`、`YlMedia3Core.kt`；新增同目录 `YlDashManifestParser.kt`；相关 `src/test` 类。
- Apple `Shared/SourceRouting/YlSourceAssessment.swift`、`YlEngineRouter.swift`、`Shared/Session/YlApplePlayerHost.swift`；当前 canonical 路由测试与两端示例镜像/当前 inventory。
- `docs/platform-support.md` 增量说明实际覆盖、仍缺的验收项。

**Consumes:** YlNetworkSource.format/URI、既有网络策略和凭据图。
**Produces:** `YlMediaFormat.dash`（append-only ordinal10）→ 两端桥接；Android MIME `application/dash+xml`、受控 DashMediaSource；Apple 当前 `.mpd`/显式 dash 明确 incompatible。

- [x] 先运行既有相关测试；添加当前 automatic `.mpd` 路由/Apple 拒绝断言并见到行为失败，再修改代码。新增枚举的编译失败不替代行为红灯。
- [x] enum 末尾追加 dash，生成 Pigeon 并补穷尽 codec 映射。验证旧 ordinal0–9 不变及新枚举往返；不手工改生成体。
- [x] Android 增加同版本 `media3-exoplayer-dash:1.11.0`；显式 format 对无扩展名 URL 生效；自动识别 URL path 的 `.mpd`，query 不影响类型。
- [x] 通过 `DashMediaSource.Factory` 接现有 data source 与 load error policy。清晰的 static MPD 点播作为本阶段范围；动态 MPD/受保护内容遇到时明确拒绝，不能隐式走无许可证/错误 fallback 路径。
- [x] 使用真实 Media3 parser 的 BaseURL 解析接口保留 MPD→Period→AdaptationSet→Representation 祖先关系。登记最终 init/index/media URI；同源携带凭据，跨域/返回原域继续剥离，普通头保留。对无法证明继承的 URI fail closed；不得回退为“同源就带凭据”。测试同源、跨域返回、重定向、多个 BaseURL、SegmentTemplate/Timeline/List/Base 至少登记路径；不枚举无界 dynamic segments。
- [x] 解析与登记采用显式资源上限，遇到未知/无界索引且不能安全携带凭据时明确失败，不默默发送凭据。记录上限和覆盖限制。bounded buffer 仍按原路线拒绝，不谎称 MPD 缓存属于已执行媒体账本。
- [x] Apple append enum 后显式 dash/`.mpd` 在评估与加载选路前拒绝（`container.unsupported` 或严格策略 `policy.unsupported`）；不能落入 networkMatroska 默认分支。未知签名仍保守，不以关键词匹配普通 XML 宣称是可播 DASH。
- [x] 用 JDK17 执行相关 JVM 测试及完整套件；Dart interface/Android/Apple codec 测试；Apple 路由相关类和 current/historical fixture gates。Pigeon 因工作区未提交导致 git-diff 检查不适合判断漂移：记录生成前后哈希，二次生成必须无变化。
- [x] 更新平台矩阵为“实现状态/证据/缺口”；编译或 parser 测试不等于真实首帧。报告确切命令、红绿结果和限制，交独立审查。

行为示例：`assess(network("https://example.test/movie.mpd?token=private"))` 在 Android 是已知候选路由；Apple 在尚无 DASH 实现时返回 incompatible。`YlMediaFormat.values.take(10)` 仍与旧枚举序列一致。

## Task 2: 可控 DASH 播放夹具与端到端证据

**Files:** 新增 `packages/yl_player/example/integration_test/android_dash_playback_test.dart`、`integration_test/support/dash_server.dart`、合成 `assets/test_media/dash/`，更新 example/pubspec.yaml；新增 `tool/generate_dash_fixture.sh` 与夹具来源/哈希说明。不得修改 Task1 文件。

**Consumes:** Task1 的 public dash enum 与 native route；准备夹具时可先使用 automatic `.mpd`，最终验证显式和自动两种。
**Produces:** 测试本地 HTTP 服务、有限合成媒体、真实 Flutter→Media3 首帧/seek/跨 Period/请求策略证据。

- [x] 用 FFmpeg testsrc/sine 或仓库已有自制夹具生成短 H264/AAC fMP4 DASH，保留命令、版本和 SHA；不下载第三方媒体。两 Period 使用同一 codec/质量，避免替用户决定 PD-01/02。
- [x] 本地服务记录请求，有限正文/Range 正确，敏感头只在断言中使用固定测试值；支持同源、跨域后返回原域、分段403/缺失、延迟停止等受控行为。复用已有测试风格，测试清理必须关闭 server 和 controller。
- [x] 测试首次呈现、正常播放、两个 Period 节目时间轴/边界 seek，以及显式无扩展名 MPD。断言实际 init/media 请求、公开失败、停止后无旧会话事件，不只验证源工厂类型。
- [x] 实際验证凭据：同源 manifest/init/media 带预期测试凭据；跨域/返回原域都无凭据但保留普通头。Media3 保持唯一候选引擎。
- [x] 运行目标 Android 模拟器/设备上的新集成测试（已安装 AVD 可启动，无需另行确认）。先检查 Task1 就绪，避免并行 Gradle 构建竞争。失败时定位真正原因，不能以吞掉错误或删除断言变绿。
- [x] 记录执行设备/OS、样本哈希、通过/失败/未执行及必要的构建限制。任务只负责本批相关测试，不引入固定清晰度/字幕/DRM 伪实现。

示例验证：在两 Period 各4秒的夹具中 seek 到5秒，公开节目位置应接近5秒而不是第二段的1秒；首帧事件必须属于当前 session。允许有界等待，超时视作失败。

## 完成判定

协调补充任务：主协调者负责私有 schema3 的四处 Dart/native 常量、正向 Create 夹具、旧 schema2 拒绝与资源释放/零分配测试，以及 Apple 路由执行。已先观察两端 Dart 实际接受旧 schema2 的失败断言再改实现；路线工作者保留 enum/生成/路由所有权，集成工作者保留媒体及播放器用例所有权。

实际设备验收暴露的追加修复：停止时由清理 Deferred 自取消造成的 `load.cancelled` 必须修复，所有输出借用者完成释放前不能提前确认清理；保留 active Stop 与 pending Load 取消测试。明确错误码在 Dart 层仍被统一文案覆盖，增加可信错误码到固定安全文案的共享映射，两端一致；未知错误继续通用文案，不能转发原始异常。上述修复须有行为红绿与独立审查。

Task1 和 Task2 的实际实现/测试均经审查；保留完整三端 DASH、字幕、ABR、DRM 和格式矩阵未完成项。若设备构建受阻，先排除工具环境问题，仍无法验证则明确记录，不以 JVM 通过替代播放通过。

本批实现、设备验证与独立整体复审完成；证据和未完成的完整需求见[实施记录](../reports/2026-09-22-dash-foundation.md)。未提交、未发布。
