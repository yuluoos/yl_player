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
