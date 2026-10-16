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

## 2026-10-11：Task 2 HTTP403 / DNS 分类与安全提示

TVS 提交 **`b4f4888a8840451ee133b8fad40df24c3480a004`**，基线 `f7a93e9`；最终验证依赖固定播放器 **`9445637`**，包含已提交的 ASS，隔离另一会话正在进行的 PGS 与长播放改动。范围是上一节的 **LiveSource 直播订阅**，不含独立 JS/点播订阅路径。

下载边界现在抛 `AppError.subscription`，携带本地生成的安全诊断：code/category/scope/phase/retryable 和随机参考编号。HTTP403 明确表示服务器拒绝本次访问，建议确认订阅访问权限或稍后重试，不断言永久失效或 token 过期；DNS 建议检查网络/DNS 设置。DNS 只识别底层 `SocketException` 的 Dart 原生 resolver `Failed host lookup:` 前缀（已核查本机 SDK 和锁定 Dio 5.11.0 的异常包装），不以普通 connectionError 文本或跨平台含义不同的 errno 猜测。普通 Socket 连接错误、超时、其他 HTTP 状态和未知错误分别保持保守提示；retryable 仅为诊断，不新增自动重试。

请求沿用 NetworkService 代理/DoH 配置，以纯文本交给已有订阅解析器，复用 `privateFile` 开关关闭该请求的原始 HTTP 日志。诊断不保存或输出 URL、凭据、响应体、任意异常正文或堆栈；DoH 的三处日志也去掉主机/IP/原始异常，只保留事件结果和 TTL。代价是无法从新诊断恢复原始敏感上下文，排查使用安全分类和参考编号。

页面的添加、单个刷新、批量刷新及删除调用 notifier 的反馈入口，未知异常使用固定安全提示；加载错误也不再拼接任意异常。下载失败不覆盖已保存频道。批量刷新继续处理后续源，结束时保留成功/失败总数及首个安全原因，避免吞掉失败后显示全成功；这是有界汇总，不携带原始源名称或地址。HTML/空列表是否应保留旧频道的事务策略仍未改动。

独立只读复审发现一项 Important：复用正在进行的 Future 会静默丢弃不同操作，且 loading 可通过 Back 关闭，用户确实能够再次提交。确定性回归先观察缺少忙碌提示的失败，再改为明确提示等待当前操作完成后重试；第二项不执行、不排队，原请求完成后可正常重试。没有遗留 Minor，也未额外启动第二次复审。

### 本地验证

新增 **14 项**（8 项真实 provider/manager/Dio 边界，6 项 Widget 提示与忙碌交互），最终九文件 **86/86**；全项目 `flutter analyze --no-pub` 无问题。所有新增外部下载失败由适配器固定注入，相关网络旧回归仅使用自有回环服务；没有设备、模拟器、原生播放或线上 DNS/订阅请求。

```sh
flutter test --no-pub --concurrency=1 test/modules/live/features/live_subscription_errors_test.dart test/modules/live/features/live_subscription_feedback_test.dart test/modules/live/features/live_source_notifier_test.dart test/modules/live/features/live_source_parser_test.dart test/modules/live/features/live_source_management_layout_test.dart test/modules/subscription/features/source_name_edit_test.dart test/modules/network/features/network_service_test.dart test/modules/network/features/doh_resolver_test.dart test/modules/network/features/outbound_http_test.dart
flutter analyze --no-pub
dart run build_runner build --build-filter=lib/providers/live_source_provider.g.dart
```

实际 SDK 为 `/Users/yy2021_8689/flutter/bin/flutter` 及其 bundled Dart。Provider 按项目要求生成，最终生成物已同步。第一次定向 build_runner 清理了过滤范围外的 63 份原本无改动生成文件，已从明确基线逐字节恢复；修复后的生成改在隔离副本执行，只同步本项 Provider 结果。保留其 SDK 3.12 / analyzer 3.11 语言版本警告，未升级依赖。

证据如实保留：最初 provider **8 failed**；最初 Widget **3 failed**，第一项复现原始异常泄漏，后两项受前一项失败后 toast 未清理影响；初次修复 11/11、相关 85/85。首轮分析的 3 项测试导入/弃用 API 提示已消除。复审 RED **1 failed** 后，首次修复回归为 **85 passed / 1 failed**：业务断言通过，新测试 teardown 遗留 toast 队列定时器；修正夹具清理，未放宽断言或再改产品，最终 86/86。

[verification.json](evidence/2026-10-11-live-subscription-errors/verification.json) 保存跨仓版本、全部七文件及依赖清单的 SHA-256、退出码和范围；[raw-logs.json](evidence/2026-10-11-live-subscription-errors/raw-logs.json) 保留 RED、生成警告、分析和最终通过日志。最终源码、实际 TVS commit 与测试副本逐字节一致；复审只读，命令和哈希核验由执行者完成。

未将本轮证据扩展为完整 P05/Task 2 通过：JS/点播订阅、HTML/空列表事务、代理初始化/源路由、原生脚本终止与代际、播放尝试汇总、九脚本线上/归档运行及真实设备各自保持原状态。现有重命名等其他本地操作的诊断路径也不包含在下载分类承诺中。

## 2026-10-11：Task 2 HTML / 空列表刷新事务

TVS 提交 **`a8e5e639c16dab3f3d21801f0fd6960a6d43ab18`**，基线 `b4f4888`；验证依赖固定已提交播放器 **`1a20e5d`**，隔离并行 PGS 与长播放修改。范围为 LiveSource 直播订阅刷新及其共用本地存储路径，Task 2/P05 整体仍开放。

刷新先判定可识别的 HTML，再解析频道；网页、空白、空列表或无法解析出频道的响应均在保存前失败，原频道和存储文件原始字节保留。复用原解析器的 HTML 开头规则，含 BOM、前导注释；不是完整 HTML 解析器。内容失败使用安全 AppError，区分 html/noChannels 和 parse 阶段，仅描述本次响应，不猜永久失效或过期，不显示原 URL、响应体或任意异常。修复 M3U 空显示名仍遗留 pendingName、生成无名频道绕过空表检查的问题；混合 JSON 仍提交有效相邻频道。

共用保存路径先编码，再在目标目录的唯一暂存子目录中写入并 flush，完成后通过同文件系统 rename 替换正式文件；写入中途失败不会截断旧文件。FileSystemException 转为安全 persist/write 提示，暂存清理日志不携带原始路径/异常；提交后的清理失败不伪报刷新失败。批量刷新仍按源提交，HTML/空列表失败源保留原频道，其他成功源正常更新，并准确汇总成功/失败。初次添加空订阅的既有行为保留；不承诺跨源回滚、跨进程隔离或断电持久性。

新增 **13 项**回归：12 项事务测试和 1 项真实 provider/manager 批量测试，覆盖拒绝内容、旧数据逐字节保留及重新读取、失败后有效刷新、有效邻居、部分写入失败与批量部分成功。初次 RED 是 IOOverrides 子类缺少 final 的夹具编译问题，修正后行为 RED **9 passed / 11 failed**；首次 GREEN 20/20。补充空名 M3U 回归先观察 **1 failed**，修复后最终相关 **73/73**，全项目静态分析无问题，改动文件格式化及 diff 检查通过。

```sh
# 固定临时 TVS 副本，使用 /Users/yy2021_8689/flutter/bin/flutter：
flutter test --no-pub --concurrency=1 test/modules/live/features/live_source_refresh_transaction_test.dart test/modules/live/features/live_subscription_errors_test.dart test/modules/live/features/live_subscription_feedback_test.dart test/modules/live/features/live_source_notifier_test.dart test/modules/live/features/live_source_parser_test.dart test/modules/live/features/live_source_management_layout_test.dart test/modules/subscription/features/source_name_edit_test.dart
flutter analyze --no-pub
```

[verification.json](evidence/2026-10-11-live-refresh-transaction/verification.json) 记录跨仓版本、全部五份改动文件及 pubspec/lock 指纹、退出码与范围；[raw-logs.json](evidence/2026-10-11-live-refresh-transaction/raw-logs.json) 保留夹具失败、行为 RED、GREEN、最终测试和分析输出。最终实际 TVS commit、工作区与验证副本七份文件逐字节一致。本轮没有 Model/Provider 生成输入改动，无需代码生成，也未解析或升级依赖。

独立只读复审通过，无 Critical/Important/Minor；复审者读取最终日志并独立核对五份改动文件与副本一致，未运行测试。所有验证使用本机 Flutter runner、fake 适配器与临时文件，没有设备、模拟器、原生播放或外部测试服务。代理初始化/源路由、JS/点播订阅、原生终止与真实设备等剩余任务保持开放；本证据不验证另一会话的 PGS 或长播放改动。

## 2026-10-11：Task 2 代理初始化与直连源依赖

TVS 提交 **`056e0056f87171085a32a54a7f599260f6b61bc5`**，基线 `a8e5e63`；验证依赖固定播放器 **`367c0bb`**，包含已提交 PGS，隔离并行 VobSub 与长播放修改。仅修改 LivePlayer Provider、其生成文件和既有源路由测试，P05 整体仍开放。

根因是 `play()` 在识别具体源之前统一等待业务代理并创建统计会话，导致实际直连的 RTMP 与脚本解析结果也被代理失败/长期等待阻塞。现在只在现有 HTTP 媒体准备分支等待代理、准备清晰度策略并创建流量会话；两个异步等待后都检查播放代际和会话所有权，过时结果不会挂到新频道。直连 RTMP 与解析后的 HTTP/RTMP 沿用内核源及凭据作用域，不初始化未使用的业务代理；普通 HTTP 保持既有代理、HLS 选档/过滤与请求策略，没有失败后静默直连。

代理初始化失败进入既有逐源错误汇总与备用源顺序，后续直连源仍可尝试，不改变重连次数。直连加载和脚本重连没有代理吞吐数据时显式 unavailable，不以零速率伪装正在统计。这里不重构应用全局初始化或代理服务自身生命周期。

新增 **14 项**，加强原有脚本 HTTP 重连用例 1 项。首次源路由 RED **26 passed / 10 failed**，分别复现代理失败阻断、pending 超时、多余初始化、丢失源序号、备用源阻断及切台阻塞；首次 GREEN 36/36。补强脚本 HTTP 重连后先观察 **1 failed**（tracking 而非 unavailable），修正默认状态后相关 146/146、全项目分析通过。

独立只读复审发现一项流量遗漏：代理 HTTP 已播放后恢复，流量订阅仍绑定旧代际，导致直连备用源继续显示 tracking/旧速率，代理恢复也收不到新采样。复审标为 Minor；执行者按当前用户可见统计失真及本项契约改判 Important，纳入同一轮修复。新增真实恢复链路先观察 **0 passed / 2 failed**：直连备用源状态错误、实际回环代理响应字节未更新当前 Loading。恢复现在先摘除旧流量身份/订阅，只有新的代理依赖尝试才创建当前代际会话；原停止/替换/释放保护保留。修复后相关 148/148；静态分析指出新测试缺少大括号的一项 info，补齐后最终同版本相关 **148/148**、全项目分析无问题。没有遗留复审项，未进行第二次独立复审。

```sh
# 固定临时 TVS 副本，使用 /Users/yy2021_8689/flutter/bin/flutter 及 bundled Dart：
flutter test --no-pub --concurrency=1 test/modules/live/features/live_source_resolution_test.dart test/modules/live/features/live_player_notifier_test.dart test/modules/live/features/live_player_session_ownership_test.dart test/modules/live/features/live_player_stall_recovery_test.dart test/modules/live/features/live_attempt_diagnostics_test.dart test/modules/live/features/live_source_parser_test.dart test/modules/player/features/playback_source_subscriptions_test.dart test/modules/proxy/features/proxy_service_provider_test.dart test/modules/proxy/features/media_traffic_test.dart test/modules/proxy/features/m3u8_wrap_decision_test.dart
flutter analyze --no-pub
dart run build_runner build --delete-conflicting-outputs
```

Provider 按项目要求生成并在复审修复后重新生成。工具提示 `--delete-conflicting-outputs` 已移除并忽略，以及 SDK 3.12 / analyzer 3.11 版本警告，原样保留，未升级依赖。首次完整生成使两份无关生成文件与基线不同，已只在隔离副本从明确基线逐字节恢复，再运行最终分析和测试；TVS 仅同步本项生成物，第二次生成无须恢复额外文件。

[verification.json](evidence/2026-10-11-live-proxy-routing/verification.json) 保存跨仓版本、三份改动及 pubspec/lock 指纹、命令、失败与最终结果；[raw-logs.json](evidence/2026-10-11-live-proxy-routing/raw-logs.json) 保留完整 RED/GREEN、复审修复、生成警告和分析日志。实际 TVS commit、工作区与最终验证副本五份文件逐字节一致。复审者阅读源码和日志，没有独立运行测试或重算副本哈希；这些验证由执行者完成。

本轮使用 Flutter 本机 runner、fake 媒体后端和自有回环 HTTP/脚本/代理服务，未占用设备、模拟器、原生媒体播放或外部测试服务。完整 P05、原生脚本终止、线上九脚本、归档和真实设备等验收维持原状态，本项不替代这些证据。

## 2026-10-11：Task 3 运行时脚本重新解析的取消与失败恢复

TVS 提交 **`7b04b962d086b43a50e820ac19380b7ac19571bc`**，基线 `056e005`；依赖固定播放器 **`9b62610`**（含已提交 VobSub），隔离并行内嵌字幕与长播放工作。本轮补齐已有业务行为的回归覆盖，只修改原有源路由测试，没有生产代码、依赖或生成输入变更。

新增 **12 项**通过真实 notifier/controller/resolver 链路验证：已成功播放的脚本 HTTP 源发生运行时错误，在重新下载脚本的慢响应阶段停止、切台或释放 Provider，迟到成功/报错均不能加载旧源、覆盖当前状态或消耗下一次重试；失败的旧 fake 媒体实例已释放，后续明确播放仍可成功。另覆盖重新解析返回明确过期结果、HTTP403 和脚本 reported_error，每类分别测试有/无备用源：保留现有两次业务重连上限，非法结果不创建媒体实例，备用 RTMP 接管或进入安全失败状态，显式再次播放重新解析原始引用。过期仅使用明确 expiresAt，403 不推断过期；错误保留重连阶段、脚本 code/diagnosticId，并拒绝原 URL/token/任意报错正文。

首轮 **9 passed / 3 failed** 来自测试错误码预期漏写既有 `script.` 前缀，修正测试后 **12/12**；不是生产缺陷或实现 RED→GREEN。为证明新增预算/过期守卫能发现回归，仅在隔离副本分别临时将业务重连上限 2 改为 3、禁用 expiry 校验，两次测试均按预期失败：应有 3 次解析请求，分别实际 4 次和 2 次。每次注入均在 finally 中逐字节恢复，恢复后与已提交生产文件核对一致，没有将故意错误带入 TVS 或最终验证。

相关六文件 **104/104**；首轮全项目分析发现测试一处 if 缺少大括号，补齐后最终同版本仍为 **104/104**，全项目分析无问题，格式和 diff 检查通过。未改 Provider/Model，无需生成。独立只读复审 Ready，无 Critical/Important；其指出的同一格式提示已消除，没有遗留项。复审者读源码和日志，未重复运行测试或重算指纹。

```sh
# 固定临时 TVS 副本，使用 /Users/yy2021_8689/flutter/bin/flutter：
flutter test --no-pub --concurrency=1 test/modules/live/features/live_source_resolution_test.dart test/modules/live/features/live_player_notifier_test.dart test/modules/live/features/live_player_session_ownership_test.dart test/modules/live/features/live_player_stall_recovery_test.dart test/modules/live/features/live_attempt_diagnostics_test.dart test/modules/player/features/playback_source_subscriptions_test.dart
flutter analyze --no-pub
```

[verification.json](evidence/2026-10-11-live-runtime-refresh/verification.json) 保存跨仓版本、测试/直接生产输入及 pubspec/lock 六份指纹和真实退出码；[raw-logs.json](evidence/2026-10-11-live-runtime-refresh/raw-logs.json) 保留预期错误、两次故意回归、最终测试及分析日志。实际 TVS commit、工作区和最终副本逐字节一致。

验证只使用本机 Flutter runner、fake 媒体后端与自有回环服务，没有设备、模拟器、原生媒体播放或外部测试服务。取消后的负断言是在受控服务响应关闭后观察 50ms，再验证新播放可成功，是有界业务状态证据，不证明原生 VM/HTTP/设备资源彻底释放。范围是现有运行时失败触发的重新解析，不新增主动到期定时器；完整 P05、三端、九脚本线上/归档、真实媒体、完整订阅/代理和全部失败汇总验收保持原状态。

## 2026-10-11：Task 1 九脚本逐项契约表

本轮基线 **`305af43`**。将分散在共享受控夹具和历史执行记录中的参数、宿主调用、请求要求、有效期与刷新语义合并为下表，并关联每份冻结原始字节。此次只做离线资料核对和归档哈希验证，没有重新执行 JavaScript、下载真实源、生成设备入口或运行播放器。历史运行观察来自 [2026-09-22 验收记录](2026-09-22-script-resolver.md#冻结脚本验收表)，不是新的三端通过结论。

“同步/异步”区分三个界面：八份联网样本使用同步 mytv 宿主调用，Dart 异步提供传输并通过 Future 交付解析结果；JS-09 无宿主网络等待。历史记录未逐份保存 main 是否为 async/Promise，统一明确记为**未单独取证**，不能由同步宿主调用或 Dart Future 推断入口形式。历史观察的成功返回表示均为 JSON 字符串；这也不能证明入口一定同步。

| 标识 | 裸查询参数 | 成功宿主调用 / 请求 | 已验证的请求与结果要求 | 同步/异步界面 | 有效期 / 刷新 |
|---|---|---|---|---|---|
| JS-01 | `id=bjws4k` | mytv.get ×1 / GET | GET；正文含 data.video_stream[].stream_url；error 优先于 url。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-02 | `id=cctv1` | mytv.request ×1 / GET | GET；受控响应依据 x-emas-gw-t 时间戳构造 AES-CBC/PKCS7 密文；需 parseItems。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-03 | `id=zhonghe` | mytv.get ×1 / GET | GET；Host 必须匹配初始 authority，验证后由传输层逐跳生成；正文含 data[].httpUrl。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-04 | `id=ch01` | mytv.fetch ×1 / GET | GET；JSON stream_url。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-05 | `id=hnws` | mytv.get ×1 / GET | GET；需 parseItems；JSON resultSet[].url；结果含播放请求头。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-06 | `id=dfws` | mytv.post ×1 / POST | POST；请求正文严格为两个 UTF-8 字节 `{}`；JSON dt[] 匹配频道。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-07 | `id=szws` | mytv.get ×1 / GET | GET；需 parseItems；结果请求头中的同值重复 Referer 合并；仅验证生成路径摘要、签名和时间字段结构。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-08 | `id=xjws` | mytv.fetch ×1 / GET | GET；JSON data[] 通过 Id 匹配频道并读取 PlayStreamUrl。 | 同步宿主；Dart Future | 未知；显式再次解析 |
| JS-09 | `id=01` | 无 / 无 | 无宿主网络请求；仅验证生成路径摘要和 auth_key 结构，网络失败夹具不适用。 | 无宿主请求；Dart Future | 未知；显式再次解析 |

所有“请求要求”均为冻结样本的受控契约，非线上服务完整协议或所有请求头清单。表中频道参数来自已提交安全夹具；不公开原始脚本、实际服务地址、凭据、密钥或签名值。JS-07/09 的真实返回地址只按摘要/结构验证；本表不暗示可直接访问这些媒体。JS-05/07 的结果含播放请求头，其余受控结果不含；传入内核时仍按既有来源凭据作用域处理。

共享夹具对每份样本连续解析两次并断言 `expiresAt == null`；联网样本合计宿主调用 2 次，JS-09 为 0 次。刷新是再次解析同一原始引用/参数，**不是自动续期**；没有明确 expiry 就保持未知，不从 URL/token/签名时间字段猜有效期。主机失败夹具对八份联网样本各断言一次调用和安全 host 阶段错误，JS-09 不适用。上述执行结果沿用历史记录，当前只核对夹具断言及其原始字节身份。

本次只读归档复核 **9/9、137,282 字节匹配**，`executed: false`；九行参数与 SHA-256 和共享清单一致。完整逐项数据见 [contracts.json](evidence/2026-10-11-nine-script-contracts/contracts.json)，原始字节收据见 [archive.json](evidence/2026-10-11-nine-script-contracts/archive.json)，输入资料指纹与检查范围见 [verification.json](evidence/2026-10-11-nine-script-contracts/verification.json)。归档仍只证明当前工作区可取回，不证明异机备份或未来持久性。

这是资料与验收映射子项，无生产代码/依赖变化，按文档风险只做字段、哈希、链接和范围核对，不重复 Flutter/设备测试。P05 的原生资源释放、完整业务构建、当前九脚本线上兼容性和三端真实媒体验收仍开放。

独立只读复审 Ready，无 Critical/Important/Minor。复审核对公开夹具、历史记录和表格/JSON 的一致性，认可本项只关闭资料整理行；未执行归档命令或重算哈希，也未读取私有正文。哈希与链接验证由执行者完成。


## 2026-10-11：Task 1 本机 native / HTTP 资源释放证据

固定基线 **`3eb2d391d09cfcb68d1dd1ec0f4e869e0ddc7a34`**，在归档副本加入本轮三个测试/入口文件，隔离并行字幕和长播放工作。生产代码、依赖、TVS 均未改动。本轮只关闭下面的本机证据子项，三端原生终止/媒体交接及完整 P05 继续开放。

新增独立 C harness，以测试编译单元包装真实 QuickJS 创建/释放调用，计数在真实释放函数返回之后更新；生产构建没有观察器或测试开关。CPU 夹具先等待公开 main 调用中的第二次真实中断回调，确认已持续执行循环；宿主夹具先取到真实宿主请求，再分别经历 cancel/timeout，连续三轮、每批四个任务，共 **48 个终止任务**。观察 terminal 状态时检查 context/runtime 释放计数，拒绝迟到 reply，销毁 caller handle，再执行一次成功解析。合计 **60 个 context 和 60 个 runtime 创建/释放配对**（含12次新解析），重复满容量批次同时检查 admission 没有遗留占用。真实 pthread_join 沿用生产 destroy 路径；本项没有另做操作系统线程/堆对象清点。

新增 **12 项** Dart 回归，交叉覆盖脚本下载/宿主 HTTP、等待响应头/未结束响应体、cancel/timeout/dispose。夹具使用 raw TCP socket，服务端保留响应与 socket；响应体场景另用仅转发真实 dart:io 请求的测试观察器，等客户端收到首个非空 chunk 后才执行取消/释放（超时用例也要求先观察该 chunk），再检查对端 EOF 或 SocketException，必须在夹具关闭之前观察到客户端断连；不把 HttpResponse.done 或取消 Future 完成当作断连。之后通过当前 resolver（dispose 后新建）执行新的真实回环宿主请求并解析成功。断连等待有5秒界限，证明该测试窗口内的传输释放，不宣称远端在取消 Future 返回前已收到 FIN。

首轮12/12通过，表明已有实现符合新增断言，没有为获得 RED 重写生产代码。隔离副本故意省略 `JS_FreeRuntime`，释放计数断言失败；故意移除 HTTP abort 的请求中止与 client.close，取消在5秒内无法结束，测试失败，随后夹具收尾也达到 runner 的30秒测试超时。两种故意回归均自动恢复原字节。最初两个实验编译窗口可能重叠，因此另做原生已恢复条件下的**串行 HTTP 重跑**，仍同样失败；该串行结果才作为 HTTP 敏感性证据，首轮日志保留但不用于隔离结论。

恢复后逐字节核对两个生产输入，再运行最终验证：解析模块 **53/53**，模块静态分析无问题；ASan/UBSan 下既有 native harness **183 checks**、新增 cleanup harness **438 checks**，均0 failures。Dart 格式与 diff 检查通过。第一次格式命令在完成格式检查后因沙箱阻止用户遥测状态写入而退出1；权限范围内重跑退出0，没有改动 SDK 或依赖。

```sh
# 固定归档副本，项目已有依赖配置映射到副本，不执行 pub resolve：
SANITIZE=1 sh packages/yl_player_source_resolver/tool/test_native.sh
# cwd: packages/yl_player_source_resolver
/Users/yy2021_8689/flutter/bin/flutter test --no-pub --concurrency=1
/Users/yy2021_8689/flutter/bin/flutter analyze --no-pub
```

[verification.json](evidence/2026-10-11-native-resource-cleanup/verification.json) 保存基线、关键输入与新测试指纹、退出码及边界；[raw-logs.json](evidence/2026-10-11-native-resource-cleanup/raw-logs.json) 保存初次通过、故意回归及最终验证日志。没有使用设备、模拟器、原生媒体播放、真实脚本服务或外部测试环境。本机 sanitizer 和直接释放观察并非全堆无泄漏证明，未运行 LeakSanitizer；Android/iOS/其他主机、九脚本线上行为、真实媒体及长播放仍需各自验收。

独立只读复审发现两项 Important 同步缺口：context 创建早于进入 main 循环，服务端 flush 早于客户端接收正文。两项均接受并在同一轮修正为上述实际执行/读取就绪观察。先在隔离副本加入就绪断言而未接入观察器，native 因就绪计数未达4失败；HTTP 因首块等待5秒超时失败，并在随后解析10秒超时中暴露预期取消的差异。接入真实观察后重新运行全部模块测试、分析和 native sanitizer 检查，结果如上。没有遗留复审项，未进行第二次独立复审；复审者只读代码和当时日志，未执行测试、重算哈希或审查后续证据文档，最终同步修正及文档核对由执行者完成。


## 2026-10-11：Task 2 直播失败提示与长摘要可读性

TVS 提交 **`60d838fbe0ddbc4b7088baadfd89f60331cd8cec`**，基线 `7b04b96`；依赖固定播放器 **`a66cc3abde06a3e7485cd805d2072d1fa2686564`**（含已提交 MP4 字幕及长播放报告）。验证使用归档副本，已有解析依赖映射到固定源码，没有升级依赖或使用设备。

逐源失败摘要现在保留已知原因，并显示中文环节：地址检查、启动播放、播放中断、重新连接。可用的脚本/内核关联编号沿已知 startup/AppError 包装解包，复用既有 diagnostics 的128字符 ASCII token 校验；URL、查询串、换行（含末尾CRLF）、非ASCII、空值和超长编号不进入用户提示，缺少编号时不编造。原始错误正文、地址、请求头及脚本参数不拼入摘要，403不推断过期或永久失效，DNS保留已知解析失败原因。摘要给出检查网络/源配置、重新选择频道或其他线路的明确手动建议。

保留前8条实际尝试及源序号、顺序与省略次数，诊断字符串仍单独保存。没有更改两次业务重连、RTMP不额外重连、失败分类、逐源回退或旧请求代际隔离。既有预览和全屏沿用同一状态；不是增加自动重试、自动换源或新的诊断上报。

独立只读复审发现一项 Important：最多8个128字符编号会加重原有 Text 裁切，末尾建议和参考编号可能读不到。接受并在同一轮修正为共享错误展示：操作提示固定可见，完整摘要可触摸滚动和 TV 方向/Page 键滚动；预览不再由禁用的全屏焦点包装屏蔽详情，仍禁止在错误时进入播放全屏。全屏详情位于播放手势之上、控制栏/频道抽屉之下，点击仍可唤回控制栏，抽屉打开时详情退出TV焦点。补测还发现全屏原有早期上下键换台处理抢占错误滚动，错误态现交给详情与现有控件，正常播放快捷键保持。

新增 **8项**（4项业务、4项 widget），并加强原有汇总/重连/脱敏断言。业务首次 RED **5 passed / 7 failed**，修复后12/12，首轮相关130/130、全项目分析通过。复审 UI RED **0 passed / 3 failed**，补入滚动后3/3；新增 TV 全屏场景再暴露快捷键问题（相关 **133 passed / 1 failed**），修复后 widget4/4。最终相同版本相关 **134/134**、全项目分析无问题、7份文件格式和 diff 检查通过。

widget 测试通过真实控制器生成八条失败与最长合法编号，在360像素预览、844×390全屏和1.5倍文字缩放下检查触摸滚动与最后编号的可见坐标、固定操作提示、全屏控制栏唤回；TV预览/全屏均断言方向键使滚动位置变化且不触发换台。平台服务使用测试替身，不启动媒体、模拟器或设备。此证据不覆盖所有屏幕、字体、实际遥控器或系统辅助功能差异。

```sh
# 固定 TVS 副本，使用 /Users/yy2021_8689/flutter/bin/flutter：
flutter test --no-pub --concurrency=1 test/modules/live/features/live_error_message_test.dart test/modules/live/features/live_attempt_diagnostics_test.dart test/modules/live/features/live_source_resolution_test.dart test/modules/live/features/live_player_notifier_test.dart test/modules/live/features/live_player_session_ownership_test.dart test/modules/live/features/live_player_stall_recovery_test.dart test/modules/live/features/live_player_view_behavior_test.dart test/modules/live/features/live_line_swipe_test.dart test/modules/live/features/live_redesign_test.dart test/modules/player/features/playback_source_subscriptions_test.dart
flutter analyze --no-pub
```

没有修改生成输入，无须 build_runner。[verification.json](evidence/2026-10-11-live-error-guidance/verification.json) 保存两个仓库的版本、关键输入指纹、最终命令与退出码；[raw-logs.json](evidence/2026-10-11-live-error-guidance/raw-logs.json) 保留业务 RED/GREEN、复审 UI 与快捷键失败及最终结果。实际 TVS commit、工作区和最终副本逐字节一致。

复审者只读代码及初轮日志，没有独立运行测试或核对哈希；其唯一 Important 已修正，无遗留项，未进行第二次独立复审。修正及证据由执行者验证。未扩展其他非逐源错误的分类，完整 P05、真实原生媒体、实际设备/遥控器、线上订阅与九脚本验收保持开放。


## 2026-10-11：Task 4 TVS 三端入口与构建依赖离线清单

固定播放器 **`896e471f69560c3a79830ebad9a59067d96f77a0`**、TVS **`60d838fbe0ddbc4b7088baadfd89f60331cd8cec`**。本项完成三端构建前的资料核对，未运行构建、依赖解析、设备或模拟器。本仓仅更新验收文档和证据，TVS 没有新提交；下列配置只代表这两个版本和当前本地生成状态。

TVS `1.2.1+6` 声明 Dart `>=3.12.0 <4.0.0`、Flutter `>=3.44.0`；当前本地 SDK 文件为 Flutter3.44.0 / Dart3.12.0，SDK 源码指纹另行记录。仓库确有 **android、ios、macos** runner，未有 linux/windows/web 目录；生成插件清单中的其他平台条目不能作为 TVS 支持那些平台的证据。

`pubspec.lock` 的五个本地 path 包均指向当前播放器工作区：`yl_player`、`yl_player_android`、`yl_player_apple`、`yl_player_platform_interface` 为0.2.0-dev.2，`yl_player_source_resolver` 为0.1.0-dev.1；其中 Android/Apple/interface 通过 overrides 接入。XML7.0.1/dbus0.7.15 保持原锁。绝对 path 是本机路径，不是可移植的发布依赖；换工作区须重新映射并重新核对锁及生成状态。

| 平台 | 当前入口和声明配置 | 原生依赖与待验边界 |
| --- | --- | --- |
| Android | Gradle wrapper8.14；TVS AGP8.11.1 / Kotlin2.2.20；Java/Kotlin17。app 的 compile/min/target/NDK 继承 Flutter；本轮读取的 SDK 默认分别36/24/36/28.2.13676358，并非 app 自行固定值。ABI 为 arm64-v8a、armeabi-v7a、x86_64。 | 本地播放器插件声明 AGP9.0.1 / Kotlin2.3.20、compile36/min24、Media3 1.11.0、coroutines1.7.1。两处 AGP/Kotlin 声明不同，**有效解析版本及兼容性尚未构建确认**，不能仅凭文本宣布冲突。CMake 引用 `android/libnode/<ABI>/libnode.so`，三份均存在；头文件声明 Node18.20.4，不据此宣称二进制同版本。 |
| iOS | Runner 与 Podfile 最低15.0；Runner Debug/Profile/Release 手动签名、team为空。项目链接并嵌入 NodeMobile.xcframework。 | NodeMobile 本地存在，Info.plist 声明 ios-arm64 和 ios-arm64_x86_64-simulator；播放器 Apple 包最低iOS15/macOS12。模拟器与设备签名构建均未执行；team为空说明仓库未给出签名团队，不代表已探测本机证书或签名能力。 |
| macOS | Runner/Podfile 最低12.0；项目 Release/Profile 明确 ARCHS=arm64 且排除x86_64，Debug 使用 ONLY_ACTIVE_ARCH，不能称所有配置均显式限定arm64。 | 打包脚本固定 Node22.15.1 darwin-arm64 归档，SHA-256 与当前归档一致；打包时提取、strip 并按构建签名设置签名。Node运行时仅arm64，不能据播放器通用架构桥宣称 TVS 支持Intel。应用构建、签名和运行仍待验。 |

Apple 两端当前开启 **SwiftPM + CocoaPods**。逐项将 `.flutter-plugins-dependencies` 的 native_build 条目与生成 Package.swift、Podfile.lock 对照：iOS17个插件中13个走SwiftPM、3个走Pods、1个 Dart-only；macOS15个中12个走SwiftPM、2个走Pods、1个 Dart-only；Android20个中19个 native_build、1个 Dart-only。全部52个平台条目的已安装 pubspec 版本与 Pub 锁一致（跨平台重复包分别核对）。Pod锁中的插件 podspec 版本可能不同于 Dart 包版本，不混为一谈。两个 Pod锁均记录 CocoaPods1.16.2，这不证明当前已安装的 CocoaPods 版本。

生成 SwiftPM 聚合包声明的 iOS13/macOS10.15 不替代 app 与播放器要求的 iOS15/macOS12。播放器 `yl_player_apple` 出现在生成 SwiftPM 包内，因此不能因 Podfile.lock 没列它就判断依赖遗漏。**上述生成文件是本机观察值，未重新生成或证明全新解析可复现。** 独立 resolver 通过 native code asset hook 编译 QuickJS，仅允许 Android/iOS/macOS，不属于 Flutter 插件注册表或 Pod；旧 `libfastdev_quickjs_runtime.so` 不能替代它的构建验证。

原生资源清点包括 Android三个 libnode、iOS两个 NodeMobile slice、播放器三个 YlFFmpegBridge slice、macOS一个 Node归档，共 **9份二进制/归档**，均记录字节数和SHA-256。XCFramework 的架构是 Info.plist 声明，本轮没有执行二进制架构、符号或链接兼容性检查。Android `libnode/` 和 iOS `NodeMobile.xcframework/` 被 TVS Git 忽略，当前存在不代表全新 clone 可取得；应按项目可信制品来源另行准备并核对。macOS Node归档与播放器桥二进制有Git跟踪且当前字节匹配固定提交；除macOS归档的仓库固定哈希比对外，其余哈希是本轮观察指纹，不是外部来源真实性证明。

实际构建待验清单（**以下命令未运行**，cwd 为 TVS，使用对应 Flutter SDK）：

```sh
flutter build apk --debug --no-pub
flutter build ios --simulator --debug --no-pub
flutter build ios --debug --no-codesign --no-pub
flutter build macos --debug --no-pub
```

Android 先准备 SDK/NDK/JDK/CMake 与三ABI Node资源，构建时保存实际 AGP/Kotlin 解析结果；release 当前使用 debug signing，不构成发行签名证明。iOS 先准备 Xcode、NodeMobile、混合依赖缓存；无签名设备目标构建只验编译链接，后续仍需配置团队/profile并单独验签名构建。macOS 先准备 Xcode、混合依赖缓存及归档，核对目标架构与打包签名步骤。`--no-pub` 只跳过 Pub，不保证 Gradle/Pods/SwiftPM 不联网；本轮没有检查工具安装完整性或这些缓存。实际构建可以在后续隔离环境执行，本清单不把它们计为已通过。

本轮离线核对记录 **41份输入文件**指纹；所有有Git跟踪的输入均匹配固定提交，Apple插件路由集合与 native_build 清单一致，52个平台插件版本一致，macOS Node固定哈希匹配，采集期间两个仓库HEAD未变。逐项数据及检查边界见 [inventory.json](evidence/2026-10-11-tvs-build-inventory/inventory.json)；最终指纹复核见 [verification.json](evidence/2026-10-11-tvs-build-inventory/verification.json)。这是资料子项，未修改业务源码或依赖，也未重跑 Flutter 测试。完整 Task4、三端构建、实际订阅/九脚本和真实媒体/长播放仍保持开放。

可用 [verify.py](evidence/2026-10-11-tvs-build-inventory/verify.py) 在原环境复核输入、已安装插件 pubspec 与固定提交的字节一致性（不执行 Flutter 或原生工具）；缺少或改变输入会失败，换路径后生成清单中的绝对插件路径也须重新采集。本轮复核退出0：41份输入、其中29份Git基线输入、52份平台插件pubspec全部匹配。

```sh
python3 docs/superpowers/reports/evidence/2026-10-11-tvs-build-inventory/verify.py --player /Users/yy2021_8689/Desktop/Flutter/yl_player --tvs /Users/yy2021_8689/Desktop/GIt/tvs --sdk /Users/yy2021_8689/flutter
```

独立只读复审通过，无Critical/Important/Minor；复审者独立运行复核脚本，并另行核对52项插件版本与锁、Apple路由集合、runner、原生制品纳入/忽略状态和报告配置声明。实际构建兼容性、有效AGP/Kotlin解析、签名、全新依赖复现、原生架构/符号与真实媒体未作判断，仍是明确待验项；未审查或修改并行字幕工作。


## 2026-10-11：Task 4 RTMPS／增强 RTMP 可行性与验收缺口

本项完成计划要求的**可行性核查**，不扩展已承诺支持范围。源码基线 **`d0feaafca7c22307a7ecaed03b803a1e948eb8ca`**；未修改播放器、TVS、依赖或支持矩阵。RTMPS、增强RTMP、其他RTMP编码和纯音频继续保持不支持；历史普通RTMP受控验收见 [基础阶段报告](2026-09-22-rtmp-foundation.md)，本轮不重计为新测试。

核查分为传输、RTMP/FLV封装和媒体解码三层：TLS可承载经典或增强包，**RTMPS与增强RTMP是独立维度**。上游E-RTMP v2描述FourCC、多音视频轨、扩展元数据和重连通知；不能从“支持HEVC解码”推得“支持增强RTMP”。本次只将它作为候选协议参考，没有冻结全部v2能力为产品范围。[Veovera规范](https://github.com/veovera/enhanced-rtmp/blob/main/docs/enhanced/enhanced-rtmp-v2.md)

| 组合 | 当前实现与不支持原因 | 可行路径及相对成本（工程判断，非工期承诺） | 解除缺口所需输入／证据 |
| --- | --- | --- | --- |
| TCP RTMP + classic AVC/H.264 + 可选AAC | 已有有界自有接收器；Android送Media3 FLV，Apple送custom AVIO/FLV与既有解码路径。并非所有AVC/AAC profile都已验。 | 既有基线，维护成本；不因本表扩大HTTP策略、bounded、VOD或seek支持。 | 三端当前版本、最低系统/物理设备、真实授权源、AV同步及长播放继续验收；历史受控证据不代替本轮运行。 |
| RTMPS + 同一classic子集 | Android地址策略及Apple validate拒绝secure源，返回 `network.protocol_unsupported`；传输分别为普通Socket、NWConnection `.tcp`。公共Dart URI可表示RTMPS，但resolver媒体转换仍拒绝。 | **优先候选：系统TLS包裹既有RTMP字节传输**。中等成本：主机身份、信任、超时/取消、状态/错误映射及重连都须接入；保留现有解码器，不需要仅为TLS替换FFmpeg。 | 授权RTMPS播放端点（不能只给推流地址）、实际端口/SNI/信任条件；有效证书、过期/错误主机/不可信证书、握手挂起/取消、断流恢复和三端输出证据。 |
| 单视频增强RTMP，FourCC AVC/HEVC/AV1/VP9等 | 两端视频门限要求classic codec ID7且拒绝扩展头位；AVC专用配置/NAL校验、关键帧启动及消费者也依赖旧布局。连FourCC AVC都不能当classic AVC放行。 | 高成本：分版本解析/协商、配置与时间戳转换、原生解封装接入；按单一codec/profile逐项冻结。仅删除门限会把未知包交给不匹配消费者。 | 独立发送端及服务器的**播放输出**样本，FourCC/配置/帧/时间戳收据；每种codec的硬解可用性、无可用解码器失败、取消/重连及输出质量。AV1/VP9不从HEVC路径推定。 |
| 增强音频或classic非AAC（如MP3）；视频仍可为AVC | 两端只接受音频SoundFormat10及限定AAC配置；MP3或增强音频先触发 `container.unsupported`。其他容器可播同编码不能绕过这里。 | 中高成本：新增音频封装/配置解析、时钟与格式切换、平台音频解码能力；增强AAC与classic AAC也要分开。 | 对每个纳入的音频codec分别准备配置和包样本、声道/采样率/延迟、AV同步、格式变化、缺失解码能力验证。 |
| audio-only RTMP（包括classic AAC） | FLV header要求视频配置，传输启动还等待视频关键帧；Apple fallback也要求视频。不是只改一个音频codec判断。合法AAC纯音频可能走启动等待/期限失败，**不承诺已在准入阶段得到专用纯音频错误**。 | 中高成本：无视频就绪语义、音频时钟、无视频首帧/租约处理、暂停/恢复/完成与UI状态；两端单独验证。 | 持续音频、延迟/始终无视频、晚到视频、stop/替换、无声与可听输出用例；明确Ready不等于VideoFirstFrame。 |
| E-RTMP多轨、ModEx/HDR元数据、重连通知等扩展 | 当前classic adapter只有启动时视频/可选音频配置，后续轨道配置变化会拒绝；不支持完整扩展语义。 | 很高成本：轨道身份/选择、时间基、颜色信息、协商与资源预算；服务器重连通知另需目的地/凭据范围策略。不自动把广播多轨变成播放ABR。 | 先冻结v2具体子集，再给独立互操作样本；未知包、超大包、跨轨时间戳、轨道增删、重定向与预算耗尽负例，HDR另验元数据及实际显示。 |

当前拒绝的源码依据为 [Android策略](../../../packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlRtmpSourcePolicy.kt)、[FLV适配](../../../packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlRtmpFlvStream.kt)、[传输](../../../packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlRtmpTransport.kt)，以及 [Apple策略](../../../packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/RTMP/YlRtmpPolicy.swift)、[FLV协议](../../../packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/RTMP/YlRtmpProtocol.swift)、[传输](../../../packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/RTMP/YlRtmpByteSource.swift)；上述未来输入均为待办，没有连接真实订阅或测试服务器。

候选方案比较：

| 候选 | 适用层与依据 | 集成成本和安全边界 |
| --- | --- | --- |
| Android SSLSocket/SSLParameters；Apple Network.framework TLS | 系统传输候选。Android从API24提供端点身份验证配置；Apple提供TLS选项与TCP组合。它们不是RTMP播放器。见[Android官方API](https://developer.android.com/reference/javax/net/ssl/SSLParameters#setEndpointIdentificationAlgorithm(java.lang.String))、[Apple官方说明](https://developer.apple.com/videos/play/wwdc2019/713/)。 | 对classic RTMPS改动范围相对小，建议先独立评估。保留原始主机用于SNI和身份验证，不能因先解析IP而丢失主机；明确受信任CA、主机匹配、TLS失败永久/瞬态分类。禁止信任全部证书、关验证或自动降级明文。 |
| 自有增强解析 + Media3／Apple既有媒体管线 | 复用现有媒体管线的开源/系统组合。锁定Media3 **1.11.0** 的FLV视频reader仍只接受AVC codec ID7，不能把官方“FLV支持”理解为增强FLV支持。见[版本化源码](https://raw.githubusercontent.com/androidx/media/1.11.0/libraries/extractor/src/main/java/androidx/media3/extractor/flv/VideoTagPayloadReader.java)、[格式层次说明](https://developer.android.com/media/media3/exoplayer/supported-formats)。 | 需要扩展/替换对应extractor或提供有界样本接口，并审查Apple桥能传递的codec/config/时间戳。保持hardwareRequired与HDR既有约束，不能以软件降级或丢元数据换取“能播”；所选codec/profile必须独立验收。 |
| FFmpeg原生RTMPS／librtmp；或仅评估FFmpeg增强FLV demux | 上游提供RTMPS/TLS和可选librtmp路线；可作为协议/解封装候选，**不代表当前应用已集成**。见[官方协议文档](https://ffmpeg.org/ffmpeg-protocols.html)。 | 当前Apple FFmpeg9.0.1构建明确 `--disable-network`、仅file协议，RTMP靠自有custom AVIO。若启用FFmpeg网络或librtmp，需要重新冻结制品/依赖、平台切片、许可清单、包体与取消/重连/请求范围；不是改URL即可。TLS后端的主机校验能力需单独审查，不能只依赖“验证证书”开关。仅复用demux也需证明本制品与桥覆盖所选增强包，不能据上游整体能力推定。 |

以上相对成本是基于当前架构的推断，没有做性能基准或排期估算。建议先将 **classic AVC/AAC over RTMPS** 与其负例单独冻结，再评估单codec增强方案；这是未来实施建议，本次不启用能力、不替用户作范围承诺。RTMPT/RTMPE、发布、userinfo认证、DVR、服务器跳转也不随TLS自动获得支持。

安全与验收约束沿用既有契约：TLS握手须纳入单次准备的绝对期限并可由stop/replace取消，恢复共享会话原预算，成功连上不能补充次数；HTTP头、HTTP managed策略和严格bounded不得静默映射。服务器地址/查询、凭据、证书私密材料和原始服务端错误不进入公共提示。增强包的长度、轨道数量、内存、配置变化和未知扩展须有界且明确拒绝；TLS加密不使媒体包可信。真实源样本只记录受控编号/哈希和必要格式元数据，不公开签名播放地址。

本轮仅阅读源码、现有测试和上游一手资料，复核输入指纹与链接；**没有执行Flutter/JVM/Swift测试、原生构建、媒体、TLS互操作或设备测试**。既有Android/Apple拒绝用例只是源码证据，本次不报告为通过。外部网页核查于2026-10-11，版本化Media3源固定为1.11.0；其他可变网页不是已冻结的上游源码快照，未来实施须重新固定版本。[sources.json](evidence/2026-10-11-rtmp-variants/sources.json) 记录资料与用途，[verification.json](evidence/2026-10-11-rtmp-variants/verification.json) 记录本地基线、指纹和范围。可行性表完成，协议实现、真实样本、三端兼容/安全/媒体与完整P05仍开放。

本轮最终资料校验：18份本地源码/配置/历史证据输入逐字节匹配基线，SHA-256已记录；8个既有本地引用目标存在，6份官方资料均在报告对应论断处引用，新增验证收据存在，限定文档diff检查通过。此处PASS仅为资料一致性，不是协议或播放测试通过。

独立只读复审Ready，无Critical/Important/Minor；复审者重新核对18份基线字节/指纹、9个本地链接（含验证收据）、6份官方引用和文档diff，均通过。协议运行、TLS互操作、解码输出、真实源、三端/设备、制品实际能力、性能/工期及完整P05未作判断；上述限制保持开放。未审查并行字幕与benchmark改动。


## 2026-10-11：Task 2 首次添加无效订阅不落盘

TVS提交 **`6749e233fb3dd3e35d9bb1eba96715b632d76c11`**，基线 `60d838f`；验证固定播放器 **`4e13f07c7529a8c6e16871ca172a64264869c9c0`**。此项补齐前次HTML/空列表刷新事务明确留下的首次添加路径，不扩大到并发写入或跨进程事务。

原先 `LiveSourceManager.add` 直接保存解析结果，即使网页或无有效频道也会创建空订阅，之后同URL重试还会被重复检查阻止。本次在写入前复用已有HTML识别及零频道校验；失败时既有订阅文件逐字节保留，首次空目录不创建文件或暂存目录，同URL获得有效内容后可以正常再次添加。部分有效JSON继续只保存有效频道，不拒绝整个混合列表。

共享内容错误工厂沿用 `html`／`noChannels`、`phase=parse`、`retryable=false` 与安全参考编号，按操作显示“添加订阅失败／未添加订阅”或既有“刷新订阅失败／未更新频道”。不把网页解释为永久失效或token过期，正文、URL与凭据不进入提示或诊断；既有 `safeLiveSourceOperationError` 保留这些安全错误。Provider、UI、生成输入和依赖未改变，未运行build_runner。

新增 **11项**：HTML含伪装TXT频道、空正文、空M3U、畸形JSON、空频道名，分别覆盖无存储和已有存储，并检查安全错误、重新打开、同URL成功重试；另有混合JSON成功添加与旧源保留。首次RED **1 passed / 10 failed**，失败均观察到不应发生的持久化；修复后11/11。完整相关套件最终 **75/75**、全项目静态分析无问题、3份文件格式与限定diff检查通过。初次分析发现一处字符串插值冗余花括号，修正后重跑相同75项及分析通过。

```sh
# 固定TVS归档副本中运行；既有package_config映射到固定播放器源码，不执行pub resolve。
flutter test --no-pub --concurrency=1 test/modules/live/features/live_source_add_transaction_test.dart test/modules/live/features/live_source_refresh_transaction_test.dart test/modules/live/features/live_source_notifier_test.dart test/modules/live/features/live_source_parser_test.dart test/modules/live/features/live_subscription_feedback_test.dart test/modules/live/features/live_subscription_errors_test.dart test/modules/player/features/playback_source_subscriptions_test.dart
flutter analyze --no-pub
```

[verification.json](evidence/2026-10-11-live-source-add/verification.json) 保存两仓版本、命令与15份输入指纹；[raw-logs.json](evidence/2026-10-11-live-source-add/raw-logs.json) 保存RED、GREEN、初次lint及最终结果。第一次RED包装命令在测试结束后误用了zsh只读变量，随后用Python子进程在未修改源码条件下重跑确认退出1；证据采用后者。三份提交文件及其相关输入与实际测试副本逐字节一致，TVS提交后工作区干净。

独立只读复审无未解决问题：确认写入前拒绝、原数据保留、失败后重试及既有反馈安全错误通路；复审者读取75项通过日志，未执行测试，最终分析及指纹由执行者确认。测试替换下载边界，使用真实解析和临时文件，不连接设备、模拟器、原生媒体或外部服务。并发写入、其他CRUD错误转换、实际订阅/媒体与完整P05继续开放；并行字幕和长播放改动保留。


## 2026-10-12：订阅重命名反馈入口互斥

TVS 提交 `c991032104bea2f14963dcb1b48ebac0fe28469c`，基线 `6749e23`；
播放器固定归档 `866afa00d25ffa7f256a0d3583ae791d35683325`。
另一边继续字幕工作，本轮只使用归档快照验证，没有运行设备、模拟器、原生构建、
真实订阅请求或媒体播放。P05 整体仍未完成。

`renameWithFeedback` 原先独立显示 loading，绕过其他订阅反馈操作共用的繁忙保护。
慢刷新读入旧名称后，重命名可以先落盘，随后刷新把旧名称写回；重命名与删除也能
交错写文件。本轮把重命名接入已有 `_runWithFeedback`：繁忙时明确提示等待后重试，
不执行被拒绝的动作；正常完成或失败后解除占用。成功提示、mounted 判断和本地
名称更新保留，失败经既有安全转换给出参考编号，不再直接记录任意读取异常。
表单现有的空名称校验不变。没有新增队列、重试策略、依赖或存储格式。

新增五项使用真实 Provider、真实管理器与临时文件的 widget 测试，仅替换路径服务和
Dio 响应：刷新成功/403 期间重命名被拒绝且随后可重试、改名期间删除/再次改名被拒绝、
读取失败提示安全且后续恢复。最终测试逐项对基线运行，五次均以预期行为缺失退出 1；
修复版本相关 **85/85，0 失败、0 跳过**，全 TVS `flutter analyze --no-pub` 无问题，
三文件格式检查和差异检查通过。Provider 生成同步，23 份输入与实际 TVS 提交逐字节核对。

验证过程中保留了环境失败：首次快照缺依赖图；测试 Dio 最初建在 fake async 区域导致
等待，修正后得到有效 RED；过滤生成首次清理了 62 份其他生成文件，造成测试加载与
分析失败，恢复固定基线后重新通过。无关模型生成空白变化已剔除，最终回归再次通过。
生成器现有的旧选项忽略/SDK 与 analyzer 语言版本提示没有被解释为产品分析失败，
未为此升级依赖。Flutter 首次异常处理自动枚举了宿主工具/设备，未启动 App；
原始诊断中的环境细节不进入公开证据。有效原始输出、命令、哈希和失败摘要见
[验证收据](evidence/2026-10-12-live-source-rename/verification.json)与
[原始测试日志](evidence/2026-10-12-live-source-rename/raw-logs.json)。

一次独立只读复审确认无 Critical/Important/Minor 代码问题；复审读取代码和日志，
没有独立重跑测试。其 RED 记录注意事项已通过最终五项分别运行补齐；没有第二次复审。
裁定与边界：本轮只保证共用反馈入口之间互斥。预设导入仍直接调用 `notifier.add`，
直接 CRUD、跨 Provider/实例/进程写入不在此保证内，不能声称所有 UI 写入均已隔离。
真实订阅、设备/原生构建、取消、代理生命周期、失败汇总和九脚本版本未重新验收；
这些判断仍保留原证据或待办，避免把局部回归解释为完整业务验收。


## 2026-10-13：直接订阅变更共用操作保护

TVS 提交 `dafccb0ab532eaf97373acc8e80c8b237112e72d`，基线 `c991032`，
播放器固定 `89cc246dc741cedb4c74e7214dcdddb0143ea966`。本轮承接上一项
反馈入口之外的缺口：预设导入直接调用 `LiveSourceNotifier.add`，原先能够与
刷新同时读写整份列表，且导入可能报告成功后被迟到刷新覆盖。

同一 Notifier 的 add、refresh、delete、refreshAll 和重命名动作现在共享准入，
在首个 await 前占用，完成或异常后解除。冲突调用返回带 `busy/operation`、
`retryable=true` 和随机安全参考编号的 AppError，调用方可稍后手动重试；
没有排队或自动重试。批量刷新仍逐源执行，保留成功和失败的既有语义。
反馈入口在显示 loading 前检查直接操作，避免即时繁忙失败留下加载界面。
预设导入沿现有 AppError 路径进入失败状态，而非冒充完成。

新增20项：12组直接操作交错、删除首个文件等待前占用、4类失败后重试、
真实预设导入与直播刷新冲突，以及反馈/直接操作双向互斥。使用真实直播 Provider、
管理器与临时文件，替换路径与Dio响应；预设VOD分支使用替身且不宣称验证该分支。
有效基线运行9通过/16失败：16项新准入行为缺失，4项新增原错误恢复保护与5项旧用例通过。
修复后定向25/25；11个相关测试文件最终 **108/108，0失败、0跳过**。
全TVS分析无问题，5文件格式与diff检查通过；27份输入与实际提交逐字节匹配。

中间失败均保留：初始测试错误地把AppError当Exception，修正断言后重新取得有效RED；
首次实现24通过/1失败暴露即时busy后的loading残留，提前检查后通过；新增测试一处
大括号lint修正后分析通过并重跑108项。Provider按现有锁生成；过滤生成影响的63份
其他生成文件/空白变化在快照中恢复为基线，没有混入提交。既有生成选项忽略和语言
版本提示没有触发依赖升级。命令、输入哈希、失败摘要和原始有效日志见
[验证收据](evidence/2026-10-13-live-source-mutation/verification.json)与
[原始日志](evidence/2026-10-13-live-source-mutation/raw-logs.json)。

一次独立只读复审Ready，无Critical/Important/Minor；复审读取源码和日志，未自行
执行测试，无第二次复审。裁定：本轮保证限定在同一LiveSourceNotifier。直接Manager、
多Notifier/容器/进程仍不隔离；预设VOD/live仍是已有并行、可能部分成功的导入，
没有跨模块原子性；其他非busy CRUD错误规范化未改变。真实订阅、设备、原生构建、
媒体和完整P05仍开放。并行字幕工作保留，本轮不占设备或测试服务。


## 2026-10-13：本地订阅存储与校验错误安全化

TVS `0530bd79a89d4a4ddd8cb9a68ef867a9b0153b4f`，验证基线 `dafccb0`，
播放器归档 `0a4e70b3c7f9348d89573840af03cddd96863d6b`。只修改8份归属文件，
未修改模型/Provider生成输入或依赖；另一个任务的详情/历史页、路由及字幕工作保留。

重复添加与不存在源原先直接抛出含URL异常；本地JSON/模型/文件读取异常也会向调用方
携带原始细节。`getAll` 现在先读取字节，仅将支持平台POSIX的ENOENT(2)视为不存在，
其他IO归为storage/read；UTF8、JSON及模型类型错误归为storage/invalidStoredData。
已有零字节、空白、错误结构或内容的文件不再作为空数据库继续写入；所有相关CRUD
在读取失败后停止，保留原字节。合法 `[]`、文件不存在、缺少可选channels的旧数据兼容。
重复/源不存在/空改名使用安全operation分类与参考编号，重命名不再包装原始读取异常。
页面首次加载失败接入安全指南，未知异常仍只显示安全通用提示，保留重试入口。

新增19项：初始15项存储与校验用例（2兼容通过、13基线失败），3项页面指导RED，
以及复审数值边界保护。坏内容用例同时检查读取和全部CRUD、无下载、无暂存残留、
字节不变和内容修复后恢复；真实管理器/临时文件配合权限失败IO替身。初始定向15/15；
扩大回归一项旧重命名提示断言发现错误缺显式“失败”表述，补齐后126/126。
复审边界加入后最终 **127/127，0失败、0跳过**，全TVS分析无问题，8文件格式/diff通过。
30份相关输入与实际提交逐字节匹配；没有为本轮运行build_runner。

独立只读复审提出一个Important源码疑点：`epgIndex:1e999`可能先变成Infinity，继而
模型toInt抛UnsupportedError。作者按原样加入夹具后，现有实现已安全拒绝，测试1/1通过；
独立本地Dart探针确认当前锁定SDK的jsonDecode直接抛FormatException，未进入模型转换。
裁定该疑点在当前SDK未复现，不增加未经证实必要的catch；保留数值回归作为以后SDK
变化的检测。没有第二次复审，不将初始源码推测写成已运行失败，也不宣称新增catch修复。
复审未自行跑Flutter测试，其余结论依据源码与日志。命令/哈希/失败摘要/探针见
[验证收据](evidence/2026-10-13-live-source-storage/verification.json)和
[原始日志](evidence/2026-10-13-live-source-storage/raw-logs.json)。

裁定：已有空白文件视为损坏，不自动清空、修复或挑选有效条目；用户需检查数据或恢复
备份，应用正常清空时仍保存合法 `[]`。这可能改变手动置空文件的旧行为，是防止覆盖的
预期取舍。备份恢复操作本身未实现/验收；非POSIX、跨实例/进程隔离、真实订阅、设备、
原生构建、播放与整个P05继续开放。最终提交证据由作者核对，固定快照测试不冒充另一
任务并行工作区的整体验收。本轮未占用设备或真实服务。

## 2026-10-16：当前依赖下的业务复验与完整 App 编译

本轮基线播放器 `d32ba4f`、TVS `a4d1ca1`；TVS 交付提交 `9082ee5`。
使用本机隔离副本并映射本地 path
依赖。遵守不占用测试设备的约束：没有启动模拟器、安装 App 或播放媒体。

- 九份原始归档仍为 9/9 哈希匹配。当前日期复验发现 JS-07 的输出路径与历史摘要
  不同；受控探针证明它依赖环境日期。为该脚本的测试环境固定 2026-09-22 12:00 UTC，
  保留原始脚本字节、冻结清单和原预期路径摘要，生产 resolver 继续使用真实时钟。
  新增 Date 构造、调用、now/parse/UTC 与其他脚本不受影响的检查。
- 最新解析器与九脚本合计 74 项通过（55 项常规、19 项受控）。原生 ASan/UBSan
  183 + 438 项断言通过，60 个 context/runtime 创建释放配对。上述证据仅为本机
  QuickJS 与受控 HTTP，不替代三端媒体交接、全堆或实际订阅可用性。
- TVS 直播及订阅相关回归 305 项通过，包含 P04 实际模式接入和新增 7 项验收输入/
  有界采集测试。新增 Flutter SDK `integration_test` 及其必要传递依赖，未升级
  原有包。全项目静态分析通过。
- 新增 `integration_test/live_subscription_playback_test.dart`，接入真实直播视图、
  notifier、原生播放器和 resolver，在临时数据库与订阅存储中验证受控频道、模式
  切换、刷新保留、慢脚本切台/停止。提供操作说明、输入哈希与安全有界收据。
  本轮编译入口并测试其辅助逻辑，**未在设备执行入口**。九份原脚本仍用 resolver
  专用受控入口；TVS 入口不宣称已经完成九脚本实播、断流重连或物理音画验证。

完整 App 的 Android debug APK、macOS debug App 已编译成功。iOS 默认多架构
模拟器构建在 Flutter 的 `lipo -verify_arch arm64 x86_64` 调用失败：框架实际包含
两种架构，当前工具拒绝该调用。明确 `ARCHS=arm64` 的 generic simulator 编译成功，
未改共享 SDK 或提高最低系统版本；默认双架构命令仍失败，不能记为通过。
无签名 iOS 设备架构 App 也已编译成功；签名/安装/运行未验证。
最终构建指纹与命令见[本轮验证归档](evidence/2026-10-16-p05-business/validation.json)。

已有 RTMP acceptance 工具测试 9 项中 3 项通过，另 6 项在启动前因缺少固定
`mediamtx.tar.gz` 归档失败；本轮未下载、运行或占用 MediaMTX 服务。归档生成器
回归另行记录。第三方插件的 KGP/SwiftPM 迁移提示与 Swift 编译警告保留，不据此
升级无关依赖。默认 iOS 多架构构建、签名与真机输出、三端取消释放、九脚本实际
媒体交接、在线订阅抽验、RTMP 故障注入和 P08 长播/SLO 仍开放。

独立复审提出两项 Important：播放推进后仍须核对同一健康会话；Provider 同步
释放不足以证明其异步清理完成。两项已先复现失败再修正，7 项辅助回归通过，
并重跑业务回归与入口编译。另修正刷新收据的当前频道关联；未重新发起复审。
收据仅声明 `ownedCleanupCompleted`，`providerAsyncCleanupVerified` 固定为 false。
设备、私有脚本正文、临时路径映射和默认 iOS 多架构修复不由该次只读复审验证。
复现九脚本可用归档中的 `controlled-host.py`，只输出摘要/结果并自动删除私有入口；
其本轮复跑 19 项通过，源码与证据哈希见 validation.json。
