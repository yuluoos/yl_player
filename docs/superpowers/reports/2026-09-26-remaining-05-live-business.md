# P05 JavaScript / RTMP 业务闭环

## 2026-10-11：Task 1 归档离线复核与生成工具

基线 `bdaf7bc`。本批仅交付不依赖设备、原生构建或外部服务的归档复现子项；P05 Task 1 的运行时终止与三端媒体交接复验，以及 Task 2–4 整体仍未完成。后续 Task 3 业务诊断子项见下节。

保存在工作区忽略目录 `.superpowers/sdd/2026-09-22-script-resolver/controlled-samples/` 的九份原始脚本仍可读取，不需要重新下载或改变版本。归档目录 0700，原始文件 0600；按共享 `controlled_contract.dart` 冻结哈希检查，**9/9、共 137,282 字节匹配**。它们已经离开历史 `/private/tmp` 临时目录；这仅证明当前本机工作区可取回，不代表存在异机备份。迁移或删除工作区前仍需另行保留受限归档。原始正文、来源清单和实际地址均不提交。

`generate_controlled_integration.py --verify-only` 新增只读 JSON 校验入口：保留九行分母、预期/实际哈希和字节数；缺失、哈希变化、权限不私有、非普通文件、超限及非法 UTF-8 分别给出固定诊断，不打印任意异常正文或私人路径。缺失整个归档仍输出九行不可用结果，失败返回 1；`executed: false` 明确没有执行脚本。

同一验证路径供实际生成使用。生成器先验证全部字节，使用不跟随符号链接的目录/文件描述符和私有临时文件原子替换，拒绝 tracked/未忽略目标；失败保留旧入口并清理临时文件。`--remove` 同样拒绝输出链接目录。工具面向可信本地 checkout，不宣称能够隔离恶意并发修改仓库的进程。

### 复现与证据

从仓库根目录执行：

```sh
python3 -B -m unittest discover -s packages/yl_player_source_resolver/tool -p 'test_*.py' -v
python3 -B packages/yl_player_source_resolver/tool/generate_controlled_integration.py --archive .superpowers/sdd/2026-09-22-script-resolver/controlled-samples --verify-only
```

自动回归只使用自有合成脚本，真实归档只运行只读校验，不生成含原始字节的 Dart 入口。初始回归在旧实现上复现输出符号链接可写、清理可进入链接目录、重复 manifest ID 未拒绝，以及缺少 verify-only 接口。最终结果与源码哈希见 [verification.json](evidence/2026-10-11-script-archive/verification.json)，安全归档收据见 [archive.json](evidence/2026-10-11-script-archive/archive.json)。

本轮没有重跑历史受控宿主、VM/HTTP 真正释放、iOS/Android/macOS 媒体交接或 TVS 业务用例。九脚本的参数、同步宿主调用、请求要求、未知 expiry 与显式再次解析契约继续沿用[历史逐脚本验收表](2026-09-22-script-resolver.md#冻结脚本验收表)及共享测试；没有从 token 推断期限，也没有把本轮哈希成功计入运行时或线上可用性通过。

### 执行范围决定

沿用现有受限归档，做可重复只读复核及生成器回归；不重复恢复相同字节，也不生成设备入口。理由是归档已在非临时工作区且本轮无需设备；代价是本轮不提供异机备份或新的运行时兼容证据。

独立只读复审结论 Ready，无 Critical/Important/Minor 问题；核对了 17/17 GREEN、源文件哈希、安全收据和范围标注，未读取私有正文。复审未评估的订阅错误/代理路由/业务代际及汇总、VM/HTTP 释放/三端交接、线上服务、异机备份和恶意并发进程隔离均继续保持未验证或明确非承诺范围；分别仍需业务回归、运行时证据、在线抽验、独立备份及可信工作区条件。

## 2026-10-11：Task 3 有界业务失败诊断

TVS 实现提交 **`b81524b1829501b6c7a07ab14accef4ea138f855`**，基线 `b96ddbd5d27fe0f23f2d291228c89c16bb358fc5`；播放器验证依赖固定 **`79dbfad`**。本仓库本次提交保存计划状态与验证证据，生产改动只在 TVS 的 `live_player_controller.dart`、`video_playback_error.dart`，新增 `live_attempt_diagnostics_test.dart`。未修改依赖、Provider、生成模型或播放器核心。

既有 `_LiveAttemptFailures` 已有前 **8 条**上限，超过部分只增加省略计数；本轮保留这项规则及原顺序。`LivePlayerError.message` 继续保存面向用户的原因，新增 `diagnostics` 保存相同实际失败/跳过源的序号与 `validation/opening/playback/reconnecting` 阶段。播放器错误保留 code/category/scope/retryable/diagnosticId；脚本错误保留其实际提供的 code/phase/scope/retryable/diagnosticId，不臆造脚本 category。未知异常只记 `code=unknown`。任意异常正文、URL、请求头、参数、原生堆栈不进入新诊断字段；元数据仅接受最长 128 字符的既定安全字符集，否则固定脱敏。

保留原有 HTTP 至多两次业务重连、RTMP 核心耗尽后不另建同源重连的预算。测试覆盖 1/10 脚本失败和 2/10 RTMP 建连失败、前 8 条与省略 2 条、跳过与实际 open 区别、原始异常包装解包、元数据脱敏，以及 replace/stop/dispose 后迟到旧失败不替换当前状态或额外 stop。

### 验证与限制

新增 8 项：旧实现 **6 failed / 2 passed**，失败均为缺少 diagnostics；实现后 **8/8**。随后在固定临时副本运行以下五个测试文件，共 **76/76**，包含新增 8 项；变更三文件 `flutter analyze --no-pub` 无问题，格式化与 diff 检查通过。

```sh
flutter test --no-pub --concurrency=1 test/modules/live/features/live_attempt_diagnostics_test.dart test/modules/live/features/live_player_notifier_test.dart test/modules/live/features/live_player_session_ownership_test.dart test/modules/live/features/live_player_stall_recovery_test.dart test/modules/live/features/live_source_resolution_test.dart
flutter analyze --no-pub lib/utils/live_player_controller.dart lib/utils/video_playback_error.dart test/modules/live/features/live_attempt_diagnostics_test.dart
```

实际 SDK `/Users/yy2021_8689/flutter/bin/flutter`。临时 TVS 副本由基线提交加三文件改动构成，播放器五包由 `79dbfad` 归档；复用 TVS 现有锁定依赖图和缓存，只在临时 package config 重映射包根路径。所有最终源文件与实际 TVS 提交逐字节一致。源指纹、跨仓提交、命令与原始结果见 [verification.json](evidence/2026-10-11-live-attempt-diagnostics/verification.json) 和 [raw-logs.json](evidence/2026-10-11-live-attempt-diagnostics/raw-logs.json)。

保留两次准备失败：直接在 TVS 上跑时，并行 TTML 代码使用 TVS XML 6.6.1 不具备的 `parseEvents.validateNamespace` 参数，未运行到用例；第一次临时副本遗漏已有 package_graph.json，补齐后才得到上述语义 RED。两者均未通过修改锁文件、放宽断言或改动另一会话源码绕过。**当时未验证最新 TTML 与 TVS 锁定依赖的集成**；后续已在下节完成对齐与实际消费者复验，该历史失败记录保留。

独立只读复审无 Critical/Important/Minor；执行者随后确认完整测试与静态分析实际输出。仅推进 Task 3 的汇总子项，Task 3/P05 整体未关闭：订阅 HTML/403/DNS 与代理依赖、原生取消后 VM/HTTP 真正释放、到期刷新完整行为、三端交接/TVS 真机、线上源可用性仍分别需要对应证据；本地业务回归不替代这些验收。

## 2026-10-11：最新 TTML 与 TVS 依赖兼容修复

TVS 修复提交 **`6ef7601`**，起点 `b81524b`；验证直接在实际 TVS 工作区执行，播放器源码为本仓 **`5772bc1`**（TTML 实现 `8cc69e3`），不再使用旧播放器快照。已解除上一节的 XML 依赖兼容限制；没有占用测试设备。

根因是 TVS 锁文件和 package config 仍选 XML 6.6.1，而当前 `yl_player` 已声明 `xml: ^7.0.1`，TTML 需要 7.x 的 `parseEvents(validateNamespace/withNamespace)` 接口。另外锁定的 dbus 0.7.14 仍约束 XML 6.x。用户授权修复兼容后执行 `flutter pub get --offline`，包管理器只更新 **XML 6.6.1 → 7.0.1、dbus 0.7.14 → 0.7.15** 及哈希；后者允许 XML 6/7。pubspec、SDK、overrides 和其他依赖未改，未手工编辑 lockfile，也未放宽 TTML 命名空间验证。

新增 `test/modules/player/features/ttml_dependency_compatibility_test.dart` 的 4 项消费者回归通过真实公共控制器和 `YlPlayerView` 执行 TTML：带前缀的元素/样式、实体解码与显示/off、未声明元素/属性前缀的严格拒绝及原目录保留、TTML 换 SRT。平台 fake 仅提供状态和展示表面，未替代字幕解析。首次修复后 3/4 通过，渲染项发现 TVS fake 默认没有 textureId；补齐已有 fake 的纹理标识后重跑，不修改生产渲染或降低断言。

最终同一次运行覆盖上述 4 项与前节 76 项业务回归，**80/80 通过**；TVS **全项目** `flutter analyze --no-pub` 无问题。`flutter pub get --offline --enforce-lockfile` 返回 0，锁文件没有再次变动。所有测试使用本机 Flutter test runner、fake 与自有本地夹具，未启动模拟器、连接物理设备或真实播放。

```sh
# 在 TVS 根目录，以 /Users/yy2021_8689/flutter/bin/flutter 执行：
flutter pub get --offline --enforce-lockfile
flutter test --no-pub --concurrency=1 test/modules/player/features/ttml_dependency_compatibility_test.dart test/modules/live/features/live_attempt_diagnostics_test.dart test/modules/live/features/live_player_notifier_test.dart test/modules/live/features/live_player_session_ownership_test.dart test/modules/live/features/live_player_stall_recovery_test.dart test/modules/live/features/live_source_resolution_test.dart
flutter analyze --no-pub
```

[verification.json](evidence/2026-10-11-ttml-tvs-compatibility/verification.json) 保存跨仓提交、实际源指纹、变更依赖和退出码；[raw-logs.json](evidence/2026-10-11-ttml-tvs-compatibility/raw-logs.json) 保留初始 XML 编译 RED、解析结果、夹具修正前失败及最终全部输出。pub 工具提示的其他可更新包及既有插件 Swift Package Manager 警告原样保留，未扩大为无关依赖升级。

独立只读复审无 Critical/Important/Minor。设备解码/原生输出、Linux DBus 服务运行及完整 TTML 标准符合性均不由本轮证明；这些范围仍需各自环境与验收。此次兼容修复没有关闭 P05/P02 的其余功能与真实设备任务。

## 2026-10-11：Task 2 订阅内容解析

TVS 提交 **`f7a93e95beed98715433f7c43a8158b4438f14ea`**，基线 `6ef7601`；播放器依赖固定已提交 **`ffc4682`**（包含当前 TTML 与 XML 7 约束）。仅修改 TVS `live_source_parser.dart` 和原有解析测试；未改依赖、源路由、重试或播放策略。Task 2/P05 整体仍开放。

JSON 现在逐组、逐条检查类型：畸形频道或分组不会丢掉相邻有效频道；可选 group/logo 类型错误按缺失处理，必填 name/url 空白或类型错误跳过。有效 JSON 中的 `,#genre#` 不再触发 TXT 解析；解码失败时只有存在真正的 TXT 分组行才按 TXT 处理，保留 `[News]`、`{News}` 分组名。M3U 以双引号属性外的逗号分隔显示名，属性只从分隔符之前提取；未闭合属性仅丢弃该条。可识别的 HTML 文档开头（含前导注释）返回空结果，不导入其中的 TXT 示例。原 URL 拆分与无频道/无法识别内容的空结果契约保留；此处不是完整 HTML 语法验证器，也未新增下载错误分类。

新增 13 项解析回归，最终解析文件 29 项。首轮新增 9 项在旧实现上共 **17 passed / 8 failed**，修复后 25/25；初次相关回归 57/57。独立只读复审发现括号 TXT 分组误判（Important）和 HTML 前导注释漏判（Minor）。执行者按导入网页频道并持久化的实际影响，将后者也纳入 Important 修复：新增 4 项（含畸形 JSON 不误回退的守卫），观察 **26 passed / 3 failed**，一轮修复后相关回归 **61/61**，全项目静态分析无问题；仅格式化改动文件，diff 检查通过。没有遗留 Minor，也没有将复审后的修复描述为再次独立复审通过。

```sh
# 固定临时 TVS 副本中，以 /Users/yy2021_8689/flutter/bin/flutter 执行：
flutter test --no-pub --concurrency=1 test/modules/live/features/live_source_parser_test.dart test/modules/live/features/live_source_notifier_test.dart test/modules/live/features/live_source_resolution_test.dart test/modules/player/features/playback_source_subscriptions_test.dart
flutter analyze --no-pub
```

副本由 TVS 基线归档加本轮两文件、播放器五包固定归档构成；复用已有锁定依赖缓存并重映射临时 package config、复制 package graph，隔离其他会话尚未提交的 ASS 与长播放改动。最终两文件及 pubspec/lock 已与实际 TVS 提交和验证副本逐字节核对。[verification.json](evidence/2026-10-11-live-subscription-parser/verification.json) 保存跨仓版本、指纹、命令与退出码；[raw-logs.json](evidence/2026-10-11-live-subscription-parser/raw-logs.json) 保留初始和复审 RED、全部 GREEN 与分析输出。

本轮只使用本机测试 runner、fake 与自有夹具，未启动设备、模拟器、原生播放或外部测试服务。复审未运行命令或独立核对副本哈希，由执行者完成这些核验。HTTP403/DNS、安全阶段提示、代理依赖与刷新事务仍需后续业务实现/回归；原生取消和资源释放、真机、线上订阅/九脚本仍需各自验收。空结果仍可能由现有 manager 写入刷新结果，本轮不承诺保留此前频道；已通过的内容解析测试不关闭这些任务，也不验证并行未提交功能。
