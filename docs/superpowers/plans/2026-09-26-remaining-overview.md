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
