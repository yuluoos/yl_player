# 播放器剩余工作：8 个执行计划

规划日期：2026-09-26。已将有限末段 DASH 时长推导提交为 **`5409313` — `feat: infer finite final Apple DASH period duration`**。2026-09-26 本批规划完成；2026-09-27 按用户授权交付 P08-A 的测量工具切片与 P01-Task 1/2 的有界 sidx 解析和 SegmentBase 播放，其余步骤仍按依赖推进；历史已完成子集仍有效。

唯一需求入口是[需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)。本总览负责工作顺序与责任分配，不改写需求；[架构入口](2026-09-22-playback-feasibility.md)及历史报告保留已完成阶段和证据。后续代码执行延续当前会话自行实施方式，按 `superpowers:executing-plans` 逐任务处理，不因拆计划自动创建线程或子代理。

## 1. 已完成起点与剩余边界

已交付的受限明文 DASH 路径、固定/上限选择、PD-01、Apple 对齐 PTO、单文件 SegmentList、有限末段时长推导不重新开发。JS 九脚本受控执行及三端媒体交接、普通 TCP RTMP 基础播放、TVS 集成及定向测试也已有证据。

这不代表通用 DASH 全范围、多字幕格式、弱网定量 ABR、完整业务真机播放、DRM、完整杜比映射、原生 DV 外接信号、性能与发布矩阵均已完成。每项都区分“代码缺口”和“已有代码缺少实际验收”。历史报告出现的“固定接口尚未实现”等文字是当时状态，以后续已提交阶段为准。

## 2. 计划与交付物

| 计划 | 主要剩余交付 | 前置条件与启动顺序 |
|---|---|---|
| [P01 DASH 寻址与节目时间轴](2026-09-26-remaining-01-dash.md) | SegmentBase/sidx、剩余时间轴维度、已支持编码的跨段重配 | Task 1/2 可直接开始；异编码重配消费 P03；字幕/音轨整合消费 P02 |
| [P02 多音轨与字幕](2026-09-26-remaining-02-tracks-subtitles.md) | 轨道契约、SRT/WebVTT/TTML、ASS/SSA、PGS/VobSub、实际合成与同步 | 契约/普通媒体先行；故障恢复依赖 PD-03；保护输出依赖 P06 |
| [P03 格式覆盖与受控解码](2026-09-26-remaining-03-formats-decoding.md) | 容器/编码组合、路由/制品缺口、硬解证据、分档软解预算 | 基线可立即盘点；优化及预算开放先消费 P08-A/B |
| [P04 弱网 ABR 与直播模式](2026-09-26-remaining-04-abr-live.md) | 网络轨迹、auto/caps/fixed 定量、HLS/FLV/RTMP 两模式运行时切换 | P08 基线先行；先用现有 AVC/AAC；动态范围转换依赖 PD-02 |
| [P05 JS / RTMP 业务闭环](2026-09-26-remaining-05-live-business.md) | TVS 真实构建/设备/订阅、归档复现、刷新取消、错误汇总 | 核心验收可直接做；新增直播模式接 P04；协议扩展先核查范围 |
| [P06 DRM 与受保护输出](2026-09-26-remaining-06-drm.md) | Widevine/FairPlay、许可证 POST 策略、密钥生命周期、真实安全输出 | 架构/受控测试尽早；真实播放需授权流/证书/许可证与设备 |
| [P07 杜比完整映射与输出](2026-09-26-remaining-07-dolby.md) | 独立参考、适用元数据/CM、屏幕映射、独立 DV 信号验收 | 先可行性及参考；性能消费 P08，编码能力消费 P03 |
| [P08 性能基线、优化与共同验收](2026-09-26-remaining-08-performance-release.md) | A 测量、B 基线冻结、C 瓶颈优化、D 三端真机/长期/消费者/发布回归 | **A/B 最早执行，D 最后执行**，避免把性能基线放到优化之后 |

这些是八个可分别追踪的工作包，每包再按任务/格式切片提交，并非八次大提交。未知架构的任务先交付有证据的接口/路径决定，再实现下游；不把研究门槛当已完成的功能。

## 3. 推荐执行顺序与无环交接

1. **先 P08-A/B + P01-Task 1/2**：建立可复用测量工具和现有路径基线，然后实现 SegmentBase/sidx。基线工具不要求完整字幕/DRM 等尚不存在的能力。
2. **尽早做 P06-Task 1/2、P07-Task 1**：暴露受保护输出、参考和设备条件，不拖到最后才发现架构不可行；资源缺失时继续独立工程工作。
3. **推进 P03 格式、P02 轨道/字幕契约、P05 业务验收**：沿用已支持媒体先交付，按各自原生/公开测试验证。
4. **汇合 P01-Task 3/4、P02 合成、P04 定量 ABR/直播、P05 模式接入**：已支持 codec 元数据由 P03 向 P01 提供；P01 统一时间轴向 P02 提供；P02 的轨道身份契约可先完成，避免等待完整字幕产生依赖环。
5. **完成 P06/P07 实现及条件齐备的真实验收，按证据做 P08-C，最后 P08-D**。保护 view 由 P06 向 P02 提供，P06 先测无字幕，最后再做共同合成测试，不互相等待才能起步。

“可并行”表示依赖关系允许，不授权自动开启多代理或同时占用同一设备/生成目录。原生构建、Flutter 生成入口和设备测试串行使用；各阶段沿用已有 checkout，先核对当前变更。

## 4. 需求与错误责任表

| 需求 | 负责计划/任务 | 验收落点 |
|---|---|---|
| REQ-01 三端/无商业 SDK | 全部；P08-D 汇总 | 全 CAP + REG-OS |
| REQ-02 未加密 DASH | P01 全部，P02、P04 | CAP-DASH 每个 MPD 子集独立行 |
| REQ-03 平台 DRM | P06 全部 | CAP-DRM，Android/Apple 分行 |
| REQ-04 多 Period | P01-3/4，P02-1/2，P03 解码 | CAP-PERIOD/同步/seek |
| REQ-05 自动/上限/固定 | P04-2，P01-4 | CAP-ABR/PD-01 回归 |
| REQ-06 可选 JS 模块 | P05-1/3/4 | CAP-JS 九脚本逐哈希 |
| REQ-07 RTMP 播放 | P05-2/3/4 | CAP-RTMP 基础与扩展变体分开 |
| REQ-08 两种直播模式 | P04-1/3/4，P05-4 | CAP-LIVE 三协议分别定量 |
| REQ-09 全字幕集合 | P02 全部 | CAP-SUB 格式/效果/输入类型逐行 |
| REQ-10 容器/编码 | P03-1/2/4 | CAP-FORMAT 合理组合，无遗漏确认格式 |
| REQ-11 受控软解 | P03-3/4 | CAP-DECODE/REG-DEC |
| REQ-12 完整映射/原生 DV | P07 全部 | CAP-DV-MAP 与 CAP-DV-OUT 分开 |
| REQ-13 错误清晰 | 下表各负责人；P08-D 汇总 | ERR-01–12/REG-DIAG |
| REQ-14 专业性能优化 | P08-A/B/C，P04 定量 | 实测、冻结目标、同条件前后对比 |
| REQ-15 无回归 | 每包定向，P08-D 共同验收 | REG-OS/API/NET/BUF/DEC/LIFE/AUDIO/VIEW/DIAG |

| 错误 | 责任任务 | 必须保留的区别 |
|---|---|---|
| ERR-01 HTML 非 M3U | P05-2 | 本次返回网页，不宣称各地区永久失效 |
| ERR-02 DNS、ERR-03 403 | P05-2；P01-2/P06-2 验各自网络边界 | 已知 DNS 与普通网络失败分开；403 不猜 token 过期 |
| ERR-04 JS 超时、ERR-05 宿主/结果 | P05-1/3 | 原生真正终止；缺接口与无地址分别提示 |
| ERR-06 RTMP | P05-3/4，P04-3 | 建连失败与已连接后中断分开、预算有界 |
| ERR-07 DRM | P06-2/3/4 | 拒绝、过期、超时必须有对应证据 |
| ERR-08 解码/预算 | P03-3 | 硬解不可证与资源超限，不暗中降档 |
| ERR-09 Dolby | P07-2/3 | 未支持与损坏分开，不忽略元数据 |
| ERR-10 字幕 | P02-2/3/4 | 字幕原因与视频错误分开；恢复受 PD-03 约束 |
| ERR-11 多源汇总 | P05-3 | 只记录实际尝试，有容量/截断/关联，无额外自动换源 |
| ERR-12 取消/旧会话/未知 | 全部生命周期任务；P05-3/P08-D 汇总 | 取消不弹当前故障；未知只报已知阶段和关联 ID |

每个模块先核对 `YlFailureCodes` 已有正式码，避免将需求文档早期“候选码”当成尚不存在。新增码须同一任务更新公共合约、native 映射、Dart 解码、UI 安全提示和测试。

## 5. 尚缺输入及其局部影响

| 条件 | 当前状态 | 只阻塞哪些步骤 | 仍可继续 |
|---|---|---|---|
| PD-02 HDR/SDR/Dolby 转换策略 | 未确认 | P01/P04 跨动态范围自动转换 | 同动态范围 DASH/ABR、固定格式映射 |
| PD-03 字幕失败行为 | 未确认 | P02 最终错误恢复行为 | 正常字幕、解析/资源隔离、错误分类 |
| DRM 授权资源 | 用户暂无 | P06 真实保护播放/密钥更新验收 | 契约、许可证受控传输、view/状态机原型 |
| Dolby 独立参考/容差 | 尚缺 | P07 完整画质通过结论；未证实算法的正式实现门槛 | 候选核查、现有 FEL 回归、元数据差距表 |
| 原生 DV 实际外接链 | 尚未指定 | P07 原生信号验收 | 非该链路工作、其他已具备参考的映射 |
| 最低系统/物理设备档位 | 需 P08 盘点 | 对应性能及发布行 | 可用设备上的准确结果 |
| RTMPS/增强 RTMP 支持范围 | 尚未冻结为扩展交付 | 扩展协议实现承诺 | 普通 RTMP/业务闭环及可行性核查 |

输入未到不能写“通过”，但不能拿一个输入阻塞整个升级。当前用户请求是规划，本轮不重复发起全部决定的问题；进入依赖步骤前检查需求记录，仍缺时再只问该决定。

## 6. 统一证据格式与检查入口

能力行遵循需求中的完整字段：`CAP 子编号 → REQ → 平台/最低可用系统 → 设备/输出 → 媒体/脚本哈希 → 封装/编码/Profile → 策略 → 操作 → 阈值/预期事件 → 实现状态 → 验证状态 → 证据 → 责任/解除条件`。四态实现与五态验证分列；以下内部数据值需按文档映射，不把 `not_run` 当 unsupported：

```json
{"implementation":"unverified|missing|partial|implemented",
 "verification":"not_run|external_missing|passed|failed|skipped"}
```

这里是枚举说明，非合法单行结果；真实记录只能取一个值。上述值与需求原表一一对应。报告记录源文件哈希、提交和未提交差异；只记录某次“全部通过”文本不够。

以下命令是执行者使用的入口，**本次写计划未运行它们**。路径基准为仓库根 `/Users/yy2021_8689/Desktop/Flutter/yl_player`，Flutter 为 `/Users/yy2021_8689/flutter/bin/flutter`。优先定向用例，每个有代码变化的阶段只做必要扩大回归；最终封板一次统一检查。

```sh
export PATH="/Users/yy2021_8689/flutter/bin:$PATH"
# Dart 合约：在受影响包目录运行 flutter test，新增文件必须被发现。
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player_platform_interface
flutter test
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
sh packages/yl_player_apple/tool/check_pigeon.sh
sh packages/yl_player_android/tool/check_pigeon.sh

# Android JVM：不以 JVM 通过代替 Android 媒体播放。
cd packages/yl_player_android/example/android
./gradlew :yl_player_android:testDebugUnitTest --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player

# Apple 原生入口；执行前通过 simctl 选择并验证 YL_IOS_SIMULATOR_ID。
sh tool/check_native_macos.sh --unit-only
sh tool/check_native_ios.sh --unit-only
```

新原生测试写入 canonical `tool/consumer_fixtures/apple_flutter/RunnerTests/`，按仓库现有同步机制更新两端镜像。读取 `main_example_tests.py --help` 后使用其实际参数完成 inventory/result-bundle 验证；不能猜测不存在的同步开关。新增 suite 要有真实测试发现与结果身份，避免跑旧二进制冒充通过。

公开测试统一从 example 目录执行：

```sh
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
# 用该计划已创建的具体测试文件替换下例，macOS 与 iOS 逐个跑。
flutter test integration_test/apple_dash_segment_base_test.dart -d macos
flutter test integration_test/apple_dash_timeline_edges_test.dart -d macos
flutter test integration_test/protected_view_probe_test.dart -d macos
# YL_IOS_SIMULATOR_ID 必须是已核验设备；不要使用占位设备 ID。
flutter test integration_test/apple_dash_segment_base_test.dart -d "$YL_IOS_SIMULATOR_ID"
flutter test integration_test/apple_dash_timeline_edges_test.dart -d "$YL_IOS_SIMULATOR_ID"
# Android runner 使用已核验 YL_ANDROID_DEVICE_ID；选择包含 Android 用例的文件。
sh ../../../tool/run_android_integration.sh integration_test/format_matrix_test.dart
```

新增文件在其任务完成前不存在；执行时不能靠缺文件/空套件得到通过。RTMP 按 `tool/rtmp_acceptance/README.md` 固定发送端版本与哈希，TVS 按 P05 的独立仓库命令运行。iOS/Android 设备、架构及实际 runner 均须核验。

最终 P08-D 先查看 `tool/check_player_v2.sh` 当前参数和 stage 清单再运行合适入口。已有 full 入口是 `sh tool/check_player_v2.sh --aggregate-full`；无设备的 `--no-device` 不能作为设备验收，也不能与 `--stage` 组合。消费者/原生大套件已有通过记录时，只有新代码影响或发现问题才扩大重跑，文档编辑只检查格式、链接与覆盖表。

## 7. 规划完成检查

- [x] REQ-01–15、全部 CAP、ERR-01–12 和 REG 均有责任计划。
- [x] 已交付子集不列为从零开发；固定选择、运行时 caps、末段时长等历史状态已区分。
- [x] 性能 A/B 在优化前；DRM/杜比可行性尽早；共享接口无循环等待。
- [x] 每包有当前边界、代码入口、任务、验证命令、提交和证据要求。
- [x] 新 API/文件标为拟新增，未知架构先产生精确契约，不冒充现有接口。
- [x] 不引入商业 SDK、静默降画质、全局系统下限变化或虚假验收。

2026-09-27 已从 **P08-A 的测量工具/可用设备盘点**切入；[执行报告](../reports/2026-09-26-remaining-08-performance-release.md)记录当前边界。P01-Task 1 的 sidx 夹具/解析及 iOS/macOS 各 123 项定向回归已通过；[P01 执行报告](../reports/2026-09-26-remaining-01-dash.md)记录边界。随后 P01-Task 2 已完成有界取索引和 SegmentBase 播放：最终 iOS/macOS 各 134 项原生测试及三端各 2 项公开实播通过；支持范围与物理声音/最低系统等限制详见报告。P01-Task 3 已交付精确大时基换算、七维媒体夹具与映射实验；通用时间轴、公开路径音画同步及跨编码重配仍未完成，详见同一报告。

2026-09-27 P06-Task 1 已交付三端 Debug 原生显示原型与保护视图契约；clear 原型各1项通过只证明 view 布线，不代表 CAP-DRM。P06-Task 2 已交付 Dart 配置、独立有界许可证 POST、明确错误及旧适配器拒绝，381 项 Dart 回归通过；下一步 Task 3 原生桥接/系统密钥与会话生命周期；[报告](../reports/2026-09-26-remaining-06-drm.md)保留真实授权、保护解码与输出链缺口。

2026-09-27 P06 Task 3A 已实现 Android 内部系统密钥边界与代际生命周期测试；生产 Media3/保护输出/Pigeon 和 Apple 接入尚未完成，Task 3 仍进行中。内部 driver 要求 API28+ 实际安全级别证据，API24–27 受保护路径继续拒绝；整包下限不变。当前公开 adapter 仍拒绝 DRM，详见 P06 报告。

2026-09-27 P06 Task 3B1 已完成内部 Media3 DRM 会话消费与安全 decoder 查询边界；3B2 保护输出/候选事务、3B3 Pigeon/许可证连接仍未完成。生产 DRM 准入保持拒绝，CAP-DRM 不变。

2026-09-28 P06 Task 3B2 完成 Android 原生安全视图与内部 Media3 候选/原子回滚路线；3B3 公共描述符、Pigeon/许可证桥接尚未完成。公开 DRM 准入继续拒绝，CAP-DRM 不变。

2026-09-28 P06 Task 3B3 已完成 Android 公开 schema5 DRM 许可证/保护视图 ACK 桥接及 Task2 POST 连接，3B 工程集成完成。457 项 Android 原生测试通过（另3项既有外部 RTMP 跳过），289 项相关 Dart 回归及102项 Apple adapter 兼容回归通过。Android 保护路线须 API29+ 并通过逐会话密钥/实际 decoder/output 检查；CAP-DRM 未完成。下一项 Apple 3C，授权真机和物理输出验收仍留 Task4，详见 P06 报告。

2026-09-28 P06 Task3C1 已交付内部 Apple AVContentKeySession/SPC/CKC 生命周期，14项FairPlay测试包含在最终双端各32项定向通过记录中；macOS复核前全量561通过。iOS完整复验stdout644通过/3跳过，但Xcode收尾卡住，完整结果包验收仍未完成；详见P06报告。下一项3C2接生产AVPlayerLayer、候选事务和Pigeon，Apple公开DRM准入仍关闭，CAP-DRM未完成。


2026-09-28 P06 Task3C2/Task3工程集成完成：Apple FairPlay HLS独立保护输出、schema5许可证/视图ACK与候选音频事务已实现。最终macOS完整571项、iOS定向242项、相关Dart203项通过；无新增跳过。iOS本次不代表完整suite通过，此前完整结果包问题仍保留。Task4授权真机、HDCP/外接/HDR和字幕合成仍external_missing，CAP-DRM未完成；不阻塞其他可执行计划。

2026-09-28 P06 Task4A 验收准备已实现：私有模板、离线预检、缺项报告及基础生命周期入口。空资源表三端均external_missing（退出2、0网络请求）；基础入口未运行授权设备，不能替代完整Task4B/HDCP/物理验收，CAP-DRM保持未完成。下一独立项为P07 Task1参考/设备/映射差距冻结。

2026-09-28 P07-Task1部分完成：FEL/HDR基线6个检查程序通过，候选固定版本/源码调查、24行三平台参考调查台账及8项校验测试已交付。原始FEL、独立参考/容差与候选三端构建仍未齐备，Task1整体、CAP-DV-MAP/OUT均未完成；不得把合成算术或公开LFS样本声明当作完整画质证据。详见P07报告。

2026-09-28 P07-Task1B1补齐libdovi/libplacebo三端arm64候选构建和官方P5首份输入盘点；macOS libplacebo13通过/1 GPU跳过，libdovi2单测/5 C API预期匹配。构建没有接入生产或证明画质；独立参考/容差、原始FEL及实际GPU/设备输出仍缺，Task1/完整杜比仍未完成。

2026-09-29 P07 Task1B2新增当前Mac的CGL实跑证据：上游GPU条件测试返回成功，覆盖浮点往返/10-bit位对齐；显式研究测试发现13通过，默认12通过/1 GPU跳过。没有真实FEL、独立显示参考或移动端/原生DV输出验收；Task1及CAP-DV-MAP/OUT仍未完成，详见P07报告。

2026-09-29 P07独立参考相关工作保持未完成，按顺序推进P03 Task1：17份原创格式夹具、102调查行及macOS51条file/http/错误扩展名实验。17条正常路径完成公共生命周期、31条有效素材缺口、3条损坏拒绝；默认基线匹配不等于格式全部通过。Task2可消费明确的容器/解码/seek缺口；音画标记、其他平台与完整CAP-FORMAT仍待验，详见P03报告。

2026-09-29 P03 Task2推进MP4探测结果到AVPlayer的传递：新增无扩展名本地/错误扩展名HTTP与截断负例；新版Apple系统使用公开MIME接口。旧系统、其他容器/音频、HEVC seek及完整输出验收保持未完成，范围与实跑证据见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03继续修复6条HEVC seek缺口：普通解码序列正确过滤随机访问RASL，保留连续播放及FEL分支；支持边界与证据见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)，整体CAP仍未完成。

2026-09-29 P03推进FLV点播：修复本地拒绝及HTTP onDemand仍按直播处理的问题，保留automatic/live网络FLV与RTMP原行为；三条格式缺口修复证据及未完成边界见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03推进FLAC：系统音频转换器接入、精确PCM与三条MKV生命周期通过；五目标桥接制品重建可复现，FFmpeg模块未扩展。完整格式/输出/跨平台验收仍开放，见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03推进独立MPEG-TS点播：受检188字节AVC/AC-3三条公开路径及策略回归通过，修正零基时间与seek关键帧定位；五目标制品独立复建一致。更广格式、严格策略、设备与输出验收仍开放，详见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03推进AVI点播：受检Baseline AVC/MP3三条公开路径、移除idx1后的本地跳转和错误/策略测试通过；五架构制品独立复建一致，仅扩展AVI解复用。完整格式、输出和跨设备验收仍开放，见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03推进Opus制品前置：原生CELT-only mono/stereo解码及独立PCM参考校验；SILK/hybrid明确拒绝。尚未启用播放器路由，trim/preroll接入和完整Opus/WebM仍是后续项，见[P03报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

2026-09-29 P03继续接入普通Matroska AVC/Opus CELT播放：显式首尾裁剪、seek预解码与PCM目标裁剪、固定安全错误。仅family0 mono/stereo48k；切换到另一Opus音轨先明确拒绝并保留当前播放。SILK/hybrid、完整WebM、严格策略、物理输出与跨端验收仍未完成，Task1/Task2不勾选。最终证据见P03执行报告。

2026-09-29 P03 Opus继续：活动会话切入/切出Opus复用seek事务，补齐代次隔离、容器回退、PCM裁剪与时钟锚点；暂停状态和播放意图保留。范围仍为CELT子集，完整Opus/WebM与Task1/Task2仍开放；细节和验证见P03报告。

2026-09-29 P03 Opus模式扩展：已用固定开源libopus1.6.1替换native Opus/swresample，SILK/hybrid/CELT family0 mono/stereo PCM及五目标可重建制品通过。完整Opus/WebM、严格策略、物理输出和跨端验收仍开放；不勾选Task1/Task2，最终公开验证见P03报告。

2026-09-30 P03 Vorbis切片：普通Matroska mono/stereo 44.1/48k通过native FFmpeg解码、200ms预解码、PCM目标裁剪及活动音轨切换；零CodecDelay与严格策略边界明确。64项macOS原生回归、5项公开Vorbis策略/切轨、3条严格格式路径通过；无商业SDK，Xiph参考库仅测试使用。物理输出/多声道/WebM视频/跨平台仍待完成，Task1/Task2不勾选；完整矩阵证据见P03报告。

2026-09-30 P03 VP9切片：普通可seek Matroska/WebM Profile0、8-bit420 SDR固定尺寸/可见单帧包接入系统硬解，每次创建/seek重建均验证实际hardware；未引入VP9软件decoder或商业SDK。VP9/Opus file/http/改名三路径和3项异常策略已实测通过，原生67项与路由矩阵7项通过；Vorbis旧样本非零CodecDelay继续明确拒绝。完整Task1/Task2/Task3不勾选；AV1、广泛VP9 Profile、物理影音/最低系统/跨端验收仍开放，最终矩阵见P03报告。

2026-09-30 P03 Task3推进AV1实际会话调查：M1/macOS27下AVC对照6次×96帧硬解通过，AV1 Main8/Main10三策略×两次创建共12次均-12906。新增可复用探测、完整性/对照门禁，未启用产品AV1。P08资源/热基线缺失，软件预算保持未测不准入；不得套Android限额。下一步补P08测量或在AV1硬解设备采证，Task1/2/3和CAP均仍开放，详见P03报告。

2026-09-30 P08 Task1补齐macOS进程资源采样子项：CPU/RSS/physical footprint、电源和系统热状态，三次公开AVC硬解播放均通过、94点无缺失；25项Python、8项Dart与静态检查通过。仅debug测量链路，正式呈现/受控profile-release基线、GPU/媒体账本及长期资源仍未完成；完整Task1/2和AV1软件预算继续开放，详见P08报告。

2026-09-30 P08 Task1新增macOS14.4+ Debug暂停显示层回读：明确BT.709原创素材3次×4段×9点颜色匹配、释放后无层；12项Dart与静态检查通过。保留旧未标注素材容差失败及两项失败清理Minor；回读不能替代首帧/物理呈现、音频/同步或正式基线，完整Task1/2继续开放，见P08报告。

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

2026-10-07：P08补齐系统isolate group与短程地址栈归因，10/10播放、15/15探针和73Python通过。本次19,693,568B映射直接定位为Dart Profiler SampleBlockBuffer；不外推过去地址/全部增长/无泄漏。原始失败与最终证据已保留，无生产变更。下一项验证Profiler开关及固定对照；完整P08 Task1/2仍开放。

2026-10-07：P08完成Profiler运行时on/off对照，各10/10播放、9/9探针和78Python通过；关闭后目标大小区域脏页短程保持176K，仍有其余增长。下一项固定关闭Profiler的百轮资源/生命周期复核；没有生产修改、优化比例或完整P08完成声明。

2026-10-07：P08完成Profiler关闭后的百轮资源/生命周期复核，100/100播放、16/16探针和81Python测试通过；目标大小区域四次脏页均160K。第10/50/100轮FlutterEngineHandlerInfo为179/859/1709，精确每轮增加17，与14播放+3DRM通道卸载路径吻合；属于待回归和修复后对照验证的保留假设。无生产改动，不据此宣称无泄漏或全部增长已归因。下一项定向连接清理回归与修复，完整P08 Task1/2仍开放，见报告。

2026-10-07：P08修复macOS host通道卸载记录保留，保存原连接号并按公开API清理，覆盖重复detach/外部新连接/存活peer；3项真实引擎回归RED→GREEN、完整原生589/589与7项工具测试通过。相同Profiler-off百轮100/100、16/16通过，释放后HandlerInfo由179/859/1709变为9/9/9；无SDK/生成代码改动。non-object后半程仍增加20,136个/1,127,792B，下一项有界分配栈归因；不报告全局无泄漏或性能比例，完整P08 Task1/2仍开放，见报告。

2026-10-07：P08完成剩余分配短程调用树归因，最终10/10播放、9/9探针、86Python通过。保留首次non-object空树归因失败，并冻结全类别v2；完整原树无损压缩归档。栈与heap定位部分增长为Timeline事件/异步轨道元数据（Profiler已off但Timeline仍ring），不是全部百轮增长或泄漏判定。无生产改动；下一项验证Timeline控制并冻结独立对照，完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成Timeline流独立启用/关闭对照，正式两组各10/10播放、9/9探针，92Python通过。保留HTTP枚举列表编码失败的预备整组，不计通过；按本机Dart源码修正并重跑。Profiler均off，Timeline四流/空流实际回读成立，关闭后已定位事件/异步元数据类型三窗不再增长；其余内存指标仍有变化。无生产/SDK改动，不作全局无泄漏或性能比例结论。下一项Profiler与Timeline双关闭、无MSL百轮复核；完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成Profiler/Timeline双关闭、无MSL百轮资源复核，100/100播放、16/16探针、96Python通过，732.713140s/3220点全acnominal。释放后核心类型未列出，HandlerInfo9/9/9；后半程non-object仍+172个/38,288B、RSS/footprint各+1,851,392B，不判稳定平台/全局无泄漏或优化比例。全部证据归档，无生产改动。下一项连续长片协议与验证，残余变化保留观察；完整P08 Task1/2仍开放，见报告。

2026-10-07：P08新增同会话20分钟连续播放验证，并修复长素材暴露的Apple桥接长度前缀误判：合法avcC/hvcC包不再被Annex B嗅探改写。真实100包19→0损坏、149边界检查通过、五目标重建逐字节一致、原生589/589、Dart18、Python102通过。两次起播失败完整保留；修复后241点/1200.928800s连续性及清理通过。footprint播放期+568,705,408B，释放后仍高于起播，RSS也有明显变化；电源234battery/7ac，非恒定基线。不宣称资源稳定/无泄漏/物理音画或完整Task1/2完成；下一项优先长播内存增长归因，详见P08报告。

2026-10-07：P08完成单会话长播内存分类取证及两项采集器留证修正，109Python通过；预备失败完整保留。最终241点/1200.908652s、12/12探针合格，但五个进度比超限及累计−5.794652s使连续性complete=false，未改门槛。三窗PCM173→28145→53793、Token199→28171→53818，heap15.37→277.19→517.49MB；诊断开关已回读关闭，Dart组堆未同量级增长。下一项音频完成回调持有/释放回归与定向修复验证；不宣称全部所有权/无泄漏/性能通过，完整P08 Task1/2仍开放，见报告。

2026-10-08：P08修复已播放PCM被完成闭包持续持有的问题；真实AVAudioEngine20缓冲RED(20个/163840B残留)→GREEN，重复及flush/dispose延迟回归通过，音频21/21、全macOS原生592/592、工具7/7。相同20分钟协议241点/1200.972374s，12探针合格，PCM46/46/46、Token71/72/72；完成容器/dispatch source仍累积，heap首末+35,672,400B。三个进度区间仍使complete=false，不声称连续性/全局内存通过。下一项残余回调/计时器生命周期及无heap干扰连续性验证；完整P08 Task1/2开放，见报告。

2026-10-08：P08完成残余回调/计时器的短时原生归因，200回调已执行仍持有200标记；引用树与分配栈定位本机系统音频Command路径及200个计时器，stop/reset后释放。16槽位10采集/6不适用、112Python通过，保留初次配置失败；无生产改动，不计性能/连续性或全局无泄漏通过。下一项验证保留播放完成时序的有界回调方案；无heap长播、残余增长修复及完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成音频同步对象局部优化，回调独立释放并共享每renderer一把锁；200缓冲锁增长200→0的原生RED/GREEN通过，音频24/24、全macOS原生595/595、工具7/7，零失败/跳过且实际方法身份一致。系统逐缓冲计时器/完成外壳仍增长，不宣称整体有界或长播通过；下一项比较保持完成语义的替代回调策略，完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成三种音频回调在固定/暂停变速场景的六组对照，1200回调/3220时钟点/36探针、116Python通过；保留所有15项不可配对时钟。只有playedBack保留200完成外壳及Command计时器，暂停后仍有5回调。生产代码未改，不直接替换完成语义；下一项验证rendered内部通知与有界输出完成调度原型，整体增长修复及完整P08 Task1/2仍开放，见报告。

2026-10-08：P08完成有界输出回收实验原型，14项Swift行为与最终121项Python回归通过（含复审补齐播放窗口有效时钟门槛）；两组原生双节点各200次完整配对，队列峰值6/12。候选分别30/42次早于参考playedBack回调（最多0.133ms），按预冻结零容差门槛两组complete=false，未接入生产，未将派发先后当物理音频结论。完整失败证据保留；下一项明确输出完成契约与设备进度依据，不以经验延时调参替代证明。系统计时器增长、无heap长播和完整P08 Task1/2仍开放，见报告。

2026-10-08：P08明确音频输出完成契约，session结束改用当前代待完成缓冲数，不以时长归零或渲染时钟到末尾代替播放完成。新增三项回归覆盖末尾时钟、暂停在途及零时长/旧代隔离；等价旧时长判断实际RED→GREEN，27音频、598全macOS、7工具通过，零失败/跳过，镜像599/669核对。生产仍用playedBack，未接入失败期限原型。下一项在保留行为下拆分资源释放/媒体时钟/最终排空责任；系统计时器增长、无heap长播和完整P08 Task1/2仍开放，见输出完成契约及报告。

2026-10-08：P08完成双阶段资源/播放通知及媒体时钟/排空职责拆分，生产输出仍由同次playedBack触发；资源先释放时保守保留全局字节/时间预算，不能提前推进时钟或排空。五项新增回归、32音频、最终603全macOS通过；首次602/603失败完整保留，诊断证实占位AV输入可在旧回调前TLS失败，改为受控本地输入后原租约断言及健康断言1/1通过。共享镜像604/669一致，无iOS运行或内存改善声明。下一项验证明确最终音频边界与容量约束，系统计时器增长/无heap长播/完整P08仍开放，见报告。

2026-10-08：P08完成真实尾部/容量分组实验，12 Swift 模型、5采集器及完整127 Python通过；四个原生场景404通知/1438观察/12heap，短流与暂停EOF正确排空、容量有界。200缓冲按8分组仍保留25完成外壳，逐缓冲对照200，停止后才消失；分组不作为长播增长修复准入，生产未改。下一项验证资源预算退还与最终输出排空独立的实验契约，系统增长/无heap长播/完整P08仍开放，见报告及输出完成契约§7。

2026-10-08：P08完成独立资源预算/最终排空工具实验，真实ledger在普通rendered后退还PCM字节/时间，EOF仅一个真实尾部playedBack；10 Swift模型、最终134 Python通过。三组原生2004通知/3753观察/11heap，200与2000缓冲断供点都只有一块8192B/21333µs尾部、零完成外壳，EOF后仅1个外壳。尚未证明系统下游工作集或批准断供尾部等待，productionAdmission/downstreamBoundProven均false；生产未改，下一项先明确尾部等待及连续性/下游资源边界，再做生产适配，详见报告与契约§8。

2026-10-08：P08完成工具级100ms连续尾部等待限额与当前代单向playedBack兼容回退，14 Swift/5采集器/139完整工具通过。无MSL、播放中无heap的节点tap验证：2000缓冲2048000帧无丢失/重复/内部静音；主动断供组108.058ms回退、100缓冲帧序完整，保留14282内部零值帧及61完成外壳。回退恢复已知系统保留，因此生产准入/下游有界均仍false；下一项制定连续有限点播适配范围并补齐媒体时钟/控制与长播，完整P08开放，详见契约§9及报告。

2026-10-08：P08完成默认关闭的音频尾部候选接入设计，拆为准入策略、输出通知、renderer 预算/排空、时钟/控制、真实验收五项，见[实施计划](2026-10-08-apple-audio-terminal-integration.md)。首阶段仅 macOS 本地有限可 seek 点播，明确排除 buffer.bounded，保留其硬约束与原播放路径；默认 legacy、不接入商业 SDK。已核查生产 token、首次 PCM 提交锚点、回调锁序与无 display tick 定时观察边界。本项仅文档自审与路径核验，未改生产或执行测试，不计内存修复/正式准入；下一项执行子计划 Task 1，完整 P08 Task1/2 仍开放。

2026-10-08：音频尾部候选接入子计划 Task 1 已完成内部纯准入策略，四项新增回归实际RED→GREEN，音频36/36、夹具4/4、镜像发现669/608核对。尚无生产调用点，默认播放未变；来源元数据/PCM/输出检查和正式准入仍待后续验证。下一项为[子计划 Task 2](2026-10-08-apple-audio-terminal-integration.md)输出通知模式，完整P08保持开放。

2026-10-08：音频尾部候选接入 Task 2 完成明确输出模式与默认兼容桥接，实际双PCM rendered/playedBack及拒绝输入两项RED→GREEN，音频41/41、夹具4/4、镜像669/613核对。renderer仍用旧入口，候选未启用，无内存/物理音画结论；下一项为[子计划 Task 3](2026-10-08-apple-audio-terminal-integration.md)真实预算/最终排空。完整P08保持开放。

2026-10-08：音频尾部接入 Task3完成内部显式renderer预算接管、提交时钟与最终排空；默认上下文nil。新增15项，核心及三处边界实际RED→GREEN，最终音频56/56、夹具4/4、镜像669/628核对；真实AAC转换器单块8192B仅计费一次，输出为可控通知。session/自动timer/路由和长播尚未接入或验收，不计生产准入/整体有界；下一项[Task4](2026-10-08-apple-audio-terminal-integration.md)，完整P08开放。


2026-10-08：音频尾部接入 Task4完成默认关闭的内部session来源准入、首次PCM提交锚点、独立10ms目标timer及配置失效失败链。新增11项；最终音频60+session53共113/113、夹具4/4、发现676/639核对。timer缺失、失效后静默play和钩子锁顺序均实际RED→GREEN；受控音频/视频尾部完成不等于物理输出验收。[下一项Task5](2026-10-08-apple-audio-terminal-integration.md)补真实节点、完整套件、独立长播/资源和全计划复审；默认未启用、整体有界未证明，完整P08开放。


2026-10-08：音频尾部候选接入Task5完成真实节点/实际converter与session验证和不准入报告。复审前macOS644/644、iOS arm64编译通过；无heap长播1200.317s/57840640帧/0顺序错误及内部零帧通过，释放后ledger0。独立heap两组四阶段采齐但tap帧断言失败，原始失败保留；释放后clock崩溃实际RED→GREEN修复。子计划完成不代表全部实验通过或正式准入：默认关闭、下游整体有界未证明，物理音画/设备/最低OS继续开放，详见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-10-08：五项音频接入子计划完成一次独立复审，唯一Important暂停重入问题实际RED→GREEN修复；修复后完整macOS645/645、0失败/0跳过及iOS arm64编译通过，无deferred minor。长播/heap仍明确绑定复审前421103c版本，未宣称修复后二进制重新测量；正式准入保持关闭，完整P08仍开放。


2026-10-08：完成cf094a7修复后版本的独立节点长播/资源复测，源码/二进制/素材与645/645套件身份完全一致，无实现改动。candidate无heap长播241采样/1200.300s/57840640帧，顺序错误与内部零帧0、最终回调一致、释放后ledger0，闭合最终版本长播身份缺口。独立资源两组frame/order仍失败，legacy中段heap8秒超时，7/8份有效快照；失败/超时保留，资源和正式准入均未通过。下一项优先采样干扰/超时的可验证取证方法，完整P08、物理音画/设备/最低系统及整体资源上界保持开放，见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-10-09：P08完成自然EOF后资源采样方法：legacy/candidate各1000和2000块四组均帧序完整、0内部零帧，12/12heap在原8秒限额内有效。排空后legacy完成回调对象1000/2000，candidate未单独识别；不能据此推出播放中整体资源有界。暂停采样假设在无heap回归中失败并已废弃，证据保留。音频66/66、最终Python9/9、夹具4/4通过；复审发现部分表格误收，RED→GREEN补齐总节点/字节核对并离线重验全部原始输出。生产未改、候选默认关闭；下一项真实解码有限长片无heap连续观察，live-heap干扰、物理音画/设备/最低系统、整体上界及完整P08仍开放，见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-10-09：P08推进真实解码连续观察，短程发现静音AAC首PCM PTS−21000µs触发现有兼容回退，实际rendered提交0，不能用submissionAnchor=true冒充候选。修复观测器三项复审问题并保留两次失败：音频67/67、Python8/8、夹具4/4通过，但候选短程门禁未通过，20分钟长程未执行。下一项处理真实AAC负起始PTS/预滚与候选兼容，再短程→长程；不修改生产开关，不宣称物理音画或完整P08通过，见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-10-09：P08修复候选AAC一次初始预滚：按样本裁去负时间部分，保留正时间样本和分配预算，默认legacy/iOS/bounded不变。初始及复审问题实际RED→GREEN；最终macOS651/651、iOS arm64编译、Python8/8和夹具4/4通过。同版本真实短程30.027s通过；长程1201.131s/241点无候选回退，但在860.818–865.827s窗口发生1次视频drop，XCTest/严格门禁均失败，未重试或放宽。下一项细分drop路径与调度证据，完整P08及正式准入仍开放，见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

2026-10-09视频drop诊断推进：六类原因及最多16条标量事件已完成，最终macOS655/655、iOS arm64编译、Python10/10、夹具4/4；同版本短程30.025s通过。目标1200s长程在870.888s因音频引擎错误提前失败，10次drop全为队列等待超时，事件期间调度仍在调用而媒体位置不动。下一项采集音频错误完整安全详情及配置失效/启动失败分支时序，定位时钟停滞根因。长程验收和候选准入仍未完成，不能倒推上轮单次drop原因。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-video-drop-diagnostics-observations.json)。

2026-10-09音频归因完成：限定进程系统日志证实上轮870.888s失败由默认音频输出路由变化引起IO中断及引擎配置失效；保留12条脱敏记录，不推断更早单drop原因。测试探针已补齐32条有界分支/安全错误详情、启动失败前缀、原生节点时钟；最终macOS656/656、Python13/13、夹具4/4，冻结30.025s短程通过。下一项为明确输出配置失效提示及重新加载指引，随后验收带路由监测的长程/实际恢复；本轮未更改生产行为或重跑长程，候选准入仍关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)及[证据](../../../tool/playback_benchmark/macos-audio-failure-cause-observations.json)。


2026-10-09音频提示完成：Swift/Dart为render.audio_engine_failed统一提供检查音频设备并重新加载媒体的固定指引，保持render分类、retryable=false和旧图停止策略。公开边界RED→GREEN，定向原生9/9、Dart Apple112/112/接口123/123、夹具4/4、iOS arm64编译通过；本轮未重跑完整原生或长程验收。下一项验证显式Load重建恢复及旧图隔离，再完成带路由记录的1200s长程；候选默认和准入继续关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)。


2026-10-09显式重载恢复完成：默认false的内部音频注入贯通typed Host Load，真实解码/原生输出两场景覆盖配置失效→新session重载，以及启动失败使首次重载被拒→后续显式重载成功；旧图和迟到回调隔离、旧命令拒绝、新音频时钟/首帧/位置恢复、最终账本0均验证。最终macOS658/658、0失败/0跳过、夹具4/4、发现678/659和iOS arm64编译通过。本项为进程内受控通知/原生失效输出，真实设备切换未验收。下一项带路由记录的1200s长程，历史失败与候选准入关闭不变；见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-audio-reload-recovery-observations.json)。


2026-10-09真实解码长程门禁通过：冻结同版本短程30.028s后执行正式1201.179s/241点长程，播放drop0/orderErrors0、无候选回退或配置失效；音频累计偏差+1.555s、最大选帧滞后23125µs，XCTest和原严格采集器均通过。释放阶段独立保留一次队列超时，释放后两点ledger0/pendingfalse。未重复全套原生/iOS，历史失败证据保持不变。下一项自然EOF与尾部排空，实际设备切换、物理音画、平台矩阵及整体资源上界仍开放；准入继续关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-route-monitored-long-observations.json)。


2026-10-09真实解码自然EOF通过：4.021s AVC/AAC文件从起点播放至自然完成；正常与真实尾回调受控暂停两场景均验证188次rendered退还、1次尾部playedBack、音频资源归零后公开completed且只发布一次，迟到回调/close后事件隔离有效。复审覆盖缺口已修正，最终音频及受控EOF79/79、夹具4/4、发现678/661通过，43份证据归档。本轮无生产修改、不重跑iOS/长程；下一项真实解码EOF后独立资源对照，实际设备/物理音画/平台矩阵及整体资源上界继续开放，准入保持关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)和[证据](../../../tool/playback_benchmark/macos-decoded-natural-eof-observations.json)。


2026-10-09真实解码EOF后资源对照完成：同一4.021s素材默认/候选两独立进程、同源码/二进制指纹，6/6正式heap在原8s内通过完整性与PID校验；完成时音频资源0，总ledger92944，close后两点均ledger0/原生输出停止。候选188 rendered+1 playedBack，默认189 playedBack。定向4/4、正式各1/1、资源工具25/25、夹具4/4、发现678/663通过，119份证据归档。ACK超时继续播放的复审问题已修复；分组与dispose后清除的运行标志已分开。进程总堆关闭后仍增加，单对照不代表统计性改善或整体有界。下一项扩大真实解码EOF资源对照的播放长度矩阵；实际设备/物理音画/平台矩阵及整体资源上界继续开放，候选准入关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-decoded-eof-resource-observations.json)。


2026-10-09真实解码EOF资源长度矩阵完成：同源4/30/60s前缀、两路径六独立进程正式6/6通过、18/18 heap在原8s内有效；提交188/1407/2813，两路径一致。初次三组中两组因configured在途ACK事件使collector失败，保留后修复为采样前等待ACK清空，以新身份重跑完整矩阵，未放宽空记录/heap期限。定向4/4、资源27/27、矩阵3/3、夹具4/4、发现678/663通过，372份证据归档。默认EOF堆增量随长度增大，候选较小；各组单次且加载基线不同，不推断整体有界或统计性改善。close后账本均0。下一项对象级归因音频回调/框架/测试保留量，其他设备及平台验收独立开放，候选准入关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)及[证据](../../../tool/playback_benchmark/macos-decoded-resource-length-observations.json)。


2026-10-09真实解码EOF堆类型级归因完成：复用已提交18份heap，严格身份/hash/长度/PID/全表守恒；保留重复标签、空TYPE与缺失类型null。默认LifecycleCompletion识别188/1407/2778，candidate未单独识别；扣各自configured基线后，60s相对4s默认增1,631,664B，其中四类回调相关标签1,032,096B，candidate对应192B（总增169,216B）。通用闭包包含测试包装，non-object仍大，不能据此确定全部所有者或根因。冻结源码确认完成容器会清空资源捕获；容器存活不等于PCM未释放。复审三个校验缺口已修复，离线10/10、资源27/27、矩阵3/3通过；没有新原生/heap/iOS/长程运行。下一项透明转交回调对照，精确持有链及生产/测试成本分离仍开放，准入保持关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)和[派生证据](../../../tool/playback_benchmark/macos-decoded-heap-attribution-observations.json)。


2026-10-09测试回调透明转交对照完成：同版本默认/候选×包装/透明四独立进程正式4/4、12/12 heap有效，每组2813提交且自然EOF/关闭后释放通过。透明callback计数为unobserved/null；默认透明仍识别2813完成容器和3108 dispatch source，通用Closure context减少5624，说明包装影响部分类型计数但不能解释全部保留。两项复审P2经RED→GREEN修复，定向4/4、工具45/45、夹具4/4、发现678/663，194份证据归档；无生产改动，无完整native/iOS/长程重跑。下一项定位透明默认路径stop/图拆除释放边界，精确成本/持有链/整体有界及其他平台设备验收仍开放，准入保持关闭。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)及[证据](../../../tool/playback_benchmark/macos-callback-wrapper-observations.json)。


2026-10-09自然EOF后stop边界对照完成：默认透明hold/stop两独立进程正式2/2、8/8 heap有效，均先自然EOF和等待>=2s；stop中间快照保持engine运行与原四节点附着。hold仍列出2813完成容器，stop后不再列出且dispatch3110→221；本次变化发生于完整图拆除之前，不等于零存活/精确原生持有链。定向4/4、工具50/50、夹具4/4、发现678/663，独立复审无P1/P2，140份证据归档；无生产修改。最终复审发现实际观察间隔hold4.998s/stop18.620s，显式sleep虽均约2s，尚不能排除额外等待效应。下一项分段测量stop前后延迟并补覆盖更长间隔的纯等待对照，然后再验证重播/seek及评估回收策略。候选准入、整体有界和其他设备平台验收仍开放。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-stop-boundary-observations.json)。
