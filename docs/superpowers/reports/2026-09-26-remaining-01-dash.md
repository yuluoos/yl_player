# P01 执行记录：sidx 与 SegmentBase

执行日期：2026-09-27。需求 REQ-02、REQ-13、REG-DIAG；起点 `4d9830ed5e0f52ff736b536af9e40ea710b97408`，分支 `codex/fel-integration`，开始时工作区干净。

以下先保留 Task 1 历史记录；最新的 Task 2 实施和验证见文末。

## Task 1 交付和能力边界

P01 Task 1 已实现：Apple 共用纯 Swift sidx v0/v1 解析、10 个原生测试、两份 owned 单文件 fMP4 夹具、Python 夹具校验和 iOS/macOS 测试发现。无第三方商业 SDK、网络调用、公共 API 或最低部署版本变更。

解析入口为 `YlDashSidx.parse(_:boxEndOffset:maxReferences:)`。输入必须恰好是一个显式大小的 sidx，支持普通和 64-bit box size，最多 1 MiB；正引用预算由调用方提供。拒绝嵌套索引、0 timescale/size/duration/count、超额引用、非零保留字段/flags、不支持的版本、截断和尾随数据。偏移、引用终点、累计媒体时钟都用 UInt64 checked arithmetic，返回原始 ticks 和 SAP，不提前换算为微秒。

CAP-DASH/SegmentBase 的整体实现仍为 `partial`，公开播放验证为 `not_run`。**Task 2 的网络取索引、不可变快照、编译器接入、播放/音频/seek 均未完成。** 原来的 `container.dash_segment_base_unsupported` 拒绝仍在，未把 parser 通过标成平台支持。Task 3/4 时间轴和重配也未完成。

## 夹具和精确契约

[夹具说明](../../../tool/dash_sidx/README.md)、[布局账本](../../../tool/dash_sidx/fixtures.json)与[输出哈希](../../../tool/dash_sidx/SHA256SUMS)记录完整偏移、时钟和 SAP。输入沿用仓库 owned synthetic `dash/period0` 视频，init 和四个 fragment 均逐字节保留，没有改写媒体时间戳。新增全局 sidx 置于 826-byte init 后，v0 结束于绝对字节 906、v1 于 914；媒体长度依次 13625、23935、31162、33734。

两版 timescale=12288、earliestPresentationTime=0、firstOffset=0、referenceID=1、每段 durationTicks=12288；均记录 SAP 1。ffprobe 确认 AVC Constrained Baseline、time_base=1/12288、4 秒时长、PTS/DTS 0/12288/24576/36864 四个关键帧。该检查不替代真实播放/seek 验收。

- v0 SHA-256：`1e062b926316fc6c250de2f6bf69e2c47066e5650f63d4498e6d4722f7589ad0`
- v1 SHA-256：`ac906877913013d6e8dff1f9fce205f82fbe3d187f10a401fcff1a5784ac3ac1`

私有 `YlDashSidxIndex` 比计划初稿多保留 `referenceID: UInt32`，方便后续 loader 校验媒体身份；其余字段签名保持。`boxEndOffset` 是资源中 box 的绝对、exclusive 终点；调用者不能传局部 Data 长度冒充。SAP 原始值只保留，不代表可独立 seek。Task 2 还必须核验 exact range、剩余总预算、取消/重定向、Int64 时间投影和随机访问子集；不引入全局 URL 缓存。

## 测试证据

| 检查 | 结果 | 条件 |
|---|---|---|
| 新夹具 Python RED→GREEN | 缺夹具/账本失败后，2/2 通过 | 独立比对原始 fragment 字节和 SHA-256 |
| 新原生 parser RED | 10 实际执行：9 失败、1 通过、0 跳过 | 未实现 stub 返回 unsupportedIndex；失败包括正常解析和资源错误映射 |
| macOS 定向 GREEN | 123/123 通过，0 失败/跳过 | 新 sidx 10 + 现有 compiler/loader 113 |
| iOS 定向 GREEN | 123/123 通过，0 失败/跳过 | 与 macOS 相同三个 suite |
| 完整发现清单 | iOS 624 / macOS 540 校验通过 | 此处是 source/PBX inventory，不能说所有用例本次全部运行 |
| main_example_migration / runtime_evidence | 4/4、9/9 通过 | 清单和真实结果身份工具回归 |
| native_apple_scripts | 7/7 通过 | 首次沙箱禁止 ps；提权重跑通过，无代码修补 |
| 夹具哈希 / shell 语法 / diff whitespace | 通过 | `shasum -c`、`sh -n`、`git diff --check` |

macOS：Apple Silicon arm64 / MacBook Pro，macOS 27.0 (26A428)。iOS：iPhone 18 Pro 模拟器 arm64，iOS 27.0 (24A434)，device ID `A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`。均为 debug/native XCTest。本次没有最低系统、Intel、物理 iOS 或 Android 媒体播放证据；没有把未运行当作通过。两端已有 stale-file/build-script 警告，测试结果无 failure。

执行命令（从仓库根，两个平台串行）使用现有原生入口相同 xcodebuild 参数，限定三个受影响 suite，之后调用 `main_example_tests.verify_result_bundle` 对比 canonical 方法集合与 xcresult 真实身份：

```sh
python3 tool/run_with_display_awake.py xcodebuild test \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -quiet -sdk macosx \
  -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner \
  -parallel-testing-enabled NO \
  -derivedDataPath packages/yl_player/example/build/native-macos-tests \
  -destination 'platform=macOS' \
  -only-testing:RunnerTests/YlDashSidxTests \
  -only-testing:RunnerTests/YlDashHlsCompilerTests \
  -only-testing:RunnerTests/YlDashResourceLoaderTests \
  -resultBundlePath .superpowers/sdd/2026-09-26-remaining-01-dash/sidx-macos-green.xcresult
```

iOS 先在 example 执行 `flutter build ios --simulator --debug --config-only`，随后同一命令换为 `-sdk iphonesimulator`、`ios/Runner.xcworkspace`、`build/native-ios-tests`、`-destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6'` 和独立 `sidx-ios-green.xcresult`。本轮启动的模拟器已恢复关闭；iOS/macOS 四份 Flutter 生成配置均核对为 `lib/main.dart`。

原始 RED/GREEN log、xcresult、`{macos,ios}-evidence/{tests,summary,case-identities}.json` 和 `final-code-hashes.json` 保存在本计划的本机忽略目录 `.superpowers/sdd/2026-09-26-remaining-01-dash/`。当前计划未结束，保留可复现材料；不假称远程 CI 制品。

## 独立复核及决定

一次 fresh-context 只读复核未发现 Critical、Important 或 Minor；复核独立校验夹具、两端镜像/PBX/inventory 和 whitespace，没有重复启动原生构建。执行者随后核对两端 123 个真实测试身份。无暂缓 Minor。

- 沿用既有 checkout/分支：工作区干净且用户持续授权；代价是依赖限定文件范围提交。
- 解析精确的单个显式 sidx，不扫描任意 MP4：保留确定的资源预算和偏移；代价是 Task 2 必须负责索引范围/box 定位。
- 使用私有无 payload 错误，映射已有 `container.unsupported` / `resource.exhausted`：避免未接通能力先增加公共错误 ABI；代价是公开细分仍需 loader 接入时验证。
- SAP 只保留，referenceID 额外保留：不凭元数据宣称可 seek；代价是后续接入必须做媒体身份和随机访问校验。
- 当前交付为独立 Task 1：代价是 SegmentBase 仍保持明确拒绝，Task 2 尚需实施。
- 复核未判断 HTTP Range/凭据/取消、播放/音频/seek、独立 A/V 原点/裁剪/gap/overlap/被 caps 隐藏的畸形时间轴及重配代际隔离；这些确属 Task 2–4，继续留在计划，不删除要求。代价是通用 DASH 能力未闭合。最终报告/状态由执行者补齐；原生实测不依赖复核者复跑来背书。

## 本阶段代码 SHA-256

- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashSidx.swift`：`e22c3664b782cf9123e9caf3b3f96e6c50f0df0f37046ae6f06a7ccff6ad9d63`
- `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashSidxTests.swift`：`c62a81cc86a1622deed6c0c3f6306661ec6afecf5a317bcc81d36dd2fdd31639`
- `tool/dash_sidx/generate_fixture.py`：`c15516d5ca3f1b6c3a590e4bd8f32244087a1f031ec2756d0e89df05408bc80f`
- `tool/dash_sidx/test_fixture.py`：`b940b396452ae121eecdcd9d2be109e222ad893ac9fa9066d8511addeec48b16`
- `tool/dash_sidx/fixtures.json`：`e68d081e344772c74d9c641a811900acebd2b1a8439ef478f61317e8a825d8c8`
- `tool/check_foundation.sh`：`7439d55727160b9d4adbaabaf29291fa253d3abccfe3f2a343f3d03fac24942e`
- `tool/consumer_fixtures/apple_flutter/main_example_tests.py`：`f1706a646222c6cdc62f0082ad0b35be7dc20ca14bcfda081638832c8afce5b2`

下一项：P01 Task 2，先固定有界 HTTP indexRange 响应/取消规则和失败测试，再接入不可变快照、SegmentBase 编译与真实播放。


## Task 2：SegmentBase 网络与实际播放

2026-09-27 从干净的 `7bd9815706b4020078f16c6e7f2676c422c61eff` 开始。**已接通 Apple 有界 SegmentBase 子集并完成三端模拟器/主机自动化播放验证。** 上文 Task 1 的“尚未开放”是历史状态；通用时间轴、跨编码重配等 Task 3/4 仍未实现。

### 实现范围与接口

- `YlDashDocument.indexRequests(_:final:credentialsStripped:)` 只做有界、无网络的继承/地址发现；正式编译仍校验全部原始表示，再应用固定档位或 caps。
- 私有 `YlDashIndexRequest: Hashable` 包含 `url: URL`、`start: Int64`、`length: Int`、`credentialsStripped: Bool`。包含剥离位，避免同 URL 的不同凭据祖先分支共享身份。
- `YlDashResolvedIndex` 包含 `index: YlDashSidxIndex`、`effectiveURL: URL`、`credentialsStripped: Bool`、`resourceLength: Int64`；`YlDashManifestSnapshot.indexes` 是不可变 `[YlDashIndexRequest: YlDashResolvedIndex]`。
- compiler 增加默认空的 `indexes` 参数；仅 loader 的 `compile(snapshot)` 传入已接受快照，原有直接编译测试/调用保持默认空。document 初始化接收同一映射，无全局 URL 缓存。
- URLSession delegate 只交付 MPD/索引字节；现有后台 preflight 顺序取索引、解析、编译并在取消锁下发布。MPD 与全部索引共用一个 deadline，不能每换索引重置总超时；取消清空注册表和快照、终止所有任务，未完成候选不能发布。
- 206 必须返回精确闭区间、有效且大于终点的总文件长度、匹配的 Content-Length（若声明）、identity/无内容编码与完整精确 body。200 在 response 阶段明确拒绝，不读取整文件再跳过；416、错范围、截断、额外数据、重定向循环均安全失败。
- 每索引最多 1 MiB，全部索引声明字节最多 4 MiB；共享 100000 引用预算，保持原表示/URI/playlist 上限。每次跳转重建 Range 和 Accept-Encoding，跨域后返回原域仍剥离凭据，普通头保留。
- 支持声明有限时长、AVC/AAC、初始化 range、完整单个显式 sidx v0/v1、平面引用、SAP=1/delta=0、EPT 与 PTO 精确同原点及完整 Period 覆盖。支持继承与原有初始化外部 sourceURL 解析；同文件索引重定向后的初始化/媒体沿实际目标与剥离状态处理。嵌套索引、任意裁剪、SAP 未证明子集、未知时长、非对齐时间轴均未被顺手放开。

### 最终验证

| 检查 | 实际结果 | 证据边界 |
|---|---|---|
| macOS native | 134/134，通过、0 跳过 | sidx/compiler/loader/header-policy；包括新增 8 项 loader 用例 |
| iOS native | 134/134，通过、0 跳过 | 相同 canonical 选定身份，与 xcresult 一一核对 |
| macOS SegmentBase | v0/v1 2/2 通过 | 公开 load/ready/firstFrame、音轨选中/画面几何、时间推进、2200ms/500ms seek、同 session、caps 快照复用 |
| iOS SegmentBase | v0/v1 2/2 通过 | 相同测试及精确索引/初始化/媒体 Range、凭据断言 |
| Android SegmentBase | v0/v1 2/2 通过 | 同一 owned 媒体；允许 Media3 合并初始化/索引相邻范围，核对覆盖及媒体起点、seek 和凭据 |
| macOS 既有 HLS | 2/2 通过 | 首帧/texture 和失败候选不拆当前会话；单独运行成功 |
| 示例 Dart 单元 | 24/24 通过 | 新夹具 2 项与所有原有示例测试 |
| 定向 Dart 分析 | 5 文件无问题 | 两个公开入口、服务、夹具、夹具测试 |
| inventory / 工具回归 | iOS 632、macOS 548 发现；4/4 和 9/9 通过 | 总发现数不等于本轮全量原生执行数 |

macOS 27.0 (26A428) / arm64 MacBook Pro；iOS 27.0 (24A434) / arm64 iPhone 18 Pro Simulator；Android 16 API36 / arm64-v8a `sdk_google_atv64_arm64`、既有 TV 1536 MiB AVD。Android 起初 adb 列表为空，进一步盘点发现已安装 AVD，使用 `-read-only -no-snapshot -no-window -no-audio -port 5580` 启动并运行成功，未安装 SDK。不是物理设备、API24 或低版本 iOS/macOS 验收。

公开测试观察首帧事件、有效画面几何、选中音轨和持续播放时钟；**未录制扬声器输出，未量化 A/V 同步。** Android 模拟器禁用了主机音频输出，macOS runner 有 `Failed to foreground app; open returned 1`，不据此宣称可见窗口或物理声音验收。该限制保留在 P08 真实设备/呈现/同步验证，不把选中音轨等同于测得音频波形。

### RED→GREEN 与独立复核

新增 5 项 loader 行为测试在实现前全部失败于旧 SegmentBase 拒绝；夹具测试在生成器缺失时失败，随后通过。首次接入回归 127/128：索引响应被按绝对偏移重复切片；改为交付已切好的 range 数据后 130/130 通过。

一次只读独立复核提出 2 个 Important、无 Critical/Minor，执行者在一次修复阶段解决：

1. 极端 `indexRange=Int64.max-Int64.max` 在 `start + length - 1` 中触发中间值溢出。新原生测试实际复现应用崩溃，再改为 `start + (length - 1)`（输入已保证闭区间可表示），最终两端安全返回 `network.range_invalid`。
2. Dart 服务 `childRequests` 原本只统计 `.m4s`，漏掉新 `.mp4`。初次 macOS 公开测试完成播放/seek 后在精确索引断言失败；修正分类，并要求音频/视频各有一次索引请求，caps/seek 后计数保持，避免 0=0 和空凭据循环伪通过。最终两端和 Android 均通过。

中途一次机械替换编译错误已修正；一次原生 RED 被 Flutter 临时 listener 配置污染，恢复 lib/main.dart 后才取得真正的崩溃 RED。一次 macOS 多文件集成运行中 SegmentBase 2 项已通过，但第二个 HLS 应用调试连接启动失败；HLS 独立重跑 2/2 通过。均保留失败日志，不把基础设施失败算成行为通过。

### 样本身份

由 `dash_segment_base_fixture.dart` 从原始 `dash/period0` 逐字节拼接音视频并插入 global sidx；没有转码、重封装样本或改 tfdt。独立单元测试核对 init、每段 bytes、范围、时钟和 SAP。视频输出与 Task 1 两份文件完全同哈希。通过同一 Dart 生成器实际导出后的身份如下：

- `v0-indexed-0.mp4`：103362 bytes，SHA-256 `1e062b926316fc6c250de2f6bf69e2c47066e5650f63d4498e6d4722f7589ad0`
- `v0-indexed-1.mp4`：35046 bytes，SHA-256 `c87492e88e69aaf99a03b9f7745b1b0b9f3a743365d15158fc3a8c78df234cc0`
- `v0.mpd`：911 bytes，SHA-256 `6b4a3310d687a8969248db9f4158b97af7ffe8d36c9330f7e8133f5b30d9f8b1`
- `v1-indexed-0.mp4`：103370 bytes，SHA-256 `ac906877913013d6e8dff1f9fce205f82fbe3d187f10a401fcff1a5784ac3ac1`
- `v1-indexed-1.mp4`：35054 bytes，SHA-256 `2d98822d3fefe384303e8a0e1d373bc145666a4f278e2d4a4fa01b5d1ac24310`
- `v1.mpd`：911 bytes，SHA-256 `ed2b82b574b9bf281a8459fb24bbcbde72db9f90c1bfd54d8a156271be090073`

### 命令与本机证据

原生使用 Task 1 相同 Xcode 入口和四个 `-only-testing:RunnerTests/` suite：`YlDashSidxTests`、`YlDashHlsCompilerTests`、`YlDashResourceLoaderTests`、`YlHlsHeaderPolicyTests`。最终 bundle 为 `base-final-macos.xcresult` / `base-final-ios.xcresult`，对应 `base-final-*-evidence/{tests,summary,case-identities}.json`；没有用旧二进制或只靠 log 的 passed 字样作证。

从 example 执行：

```sh
flutter test integration_test/apple_dash_segment_base_test.dart -d macos --reporter expanded
flutter test integration_test/apple_dash_segment_base_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --reporter expanded
flutter test integration_test/hls_playback_test.dart -d macos --reporter expanded
YL_ANDROID_DEVICE_ID=emulator-5580 sh ../../../tool/run_android_integration.sh integration_test/android_dash_segment_base_test.dart
flutter test test
```

证据均在本计划忽略目录 `.superpowers/sdd/2026-09-26-remaining-01-dash/`：`base-public-macos-final.log`（SegmentBase 通过及第二个应用启动失败）、`hls-public-macos-final.log`、`base-public-ios-final.log`、`base-public-android.log`、`base-example-tests.log`、`base-review-red2.xcresult`、`playback-fixture-hashes.json`。保留阶段日志，不假称远端 CI 制品。

### 决定、保留范围和后续

- 继续已授权的既有 checkout，限定文件提交；代价是依靠精确暂存隔离工作。
- 200 整文件直接拒绝，所有取索引共用 deadline；代价是不支持忽略 HTTP Range 的服务器。
- 平面单 box/SAP1/完整 Period 为首个验收子集；代价是通用索引扫描、裁剪及其他 SAP 行仍未完成。
- 复核未覆盖的独立 A/V 原点、gap/overlap/裁剪和 decoder 重配继续属于 Task 3/4；原始轨道仍先于 caps 验证，不缩减需求。
- `referenceID` 不等于 MPD Representation ID，不能凭字符串相等推断媒体身份；保留字段，不虚构额外身份保证。
- 物理音频、真实屏幕呈现、最低系统和长期表现未测；代价是本次只交付列出的自动化主机/模拟器证据。无暂缓 Minor。

下一项为 P01 Task 3：补剩余时间轴维度的原始媒体、可行性和边界实验，再实现可准确表达的子集。PD-02/字幕/跨编码依赖保持，不将通用 DASH 标记完成。

### Task 2 最终代码 SHA-256

- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashDocument.swift`：`cf352a8aea2ee23ef925e3c3345efb1eee0b0c1a7e78db6bb5891cdadba23dd2`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashHlsCompiler.swift`：`82995b4dbba407dfa6e844210f0fb20c623ea1517cf9fb036fbd125e1b0b0a99`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashSidx.swift`：`9fdcb679b721be619983f9ab5c3f3af64d50c3b85ee821b5344d27f7dac0f2e0`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsResourceLoader.swift`：`5d624a443f57a24266e0900e4517d3feabcee792cdfd2997be47039d0f1cee5d`
- `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift`：`c7bb1303c359dd863d253a35d95aa28abe29bb0ef42f35d5635586550030cf05`
- `tool/consumer_fixtures/apple_flutter/main_example_tests.py`：`ab7854bf11cab0a85dbd90ab52046dfdfaf6ec67713ce9b5fba44713e2aba54f`
- `packages/yl_player/example/integration_test/support/dash_server.dart`：`0b084adabdcdd88c432e457cc1e2a3ebe743eef1ebdcd9bc5db2c2e05b8cb664`
- `packages/yl_player/example/integration_test/support/dash_segment_base_fixture.dart`：`c1f64e522aec4a6dd2bf69bc907c721ee67a780a5e31ab28987ff45864c58c3b`
- `packages/yl_player/example/integration_test/apple_dash_segment_base_test.dart`：`0af095ef4233ead56f442c8a43955e2fa6b2f20d45dea68a0fd12cef5058c6c4`
- `packages/yl_player/example/integration_test/android_dash_segment_base_test.dart`：`5b8659ec17375e36ae28a8ec3b8880f9ac982b6dd92780c356e39d45c6a1cf87`
- `packages/yl_player/example/test/dash_segment_base_fixture_test.dart`：`ab31980f3bb172e3cdcf7d8765b10e414aea48920869f605e00a508da562a913`

## Task 3：精确换算与剩余时间轴实验（2026-09-27）

基线 `9707c9d2255589e762e7f7e64a2b533561414904`。本轮只放行一个可准确表达的子集：最终整数值可表示、但直接相乘会溢出的时基换算。`rescaleExact` 先约去分子/分母公因数，确认余下分母为 1 后才 checked multiply；显式时长转 ticks 与末段 ticks 转微秒共用这一边界。真实结果溢出、非整数微秒端点及被 caps 隐藏的原始非法轨道仍拒绝。没有生产重封装、平移媒体时间戳或商业 SDK。

### CAP-DASH / CAP-PERIOD 子行

| 子行 | 本轮证据 / 精确预期 | 结论和剩余步骤 |
| --- | --- | --- |
| 可整除的大时基 | 同一 AVC/AAC 媒体，MPD ticks/scale 同乘 10^9；两段各 4 秒，总 8 秒 | 已实现；公开 API 边界 seek 与取消替换已测，严格逐帧/音频同步验收仍缺 |
| 独立 A/V PTO | 原始编码 payload 的离线副本：video +10s、audio +20s；DASH 应均映射 [0,4) | 当前直接 HLS 实验实际 duration=14s；0.5/2.5/3.45/3.8s 均未在 2 秒采样窗口拿到图像。**需要新的映射/播放路径或重封装方案**；未证明所有 AVFoundation 路径不可行，继续拒绝 |
| Period 端点裁剪 | 原始媒体到 4s，要求 [0,3.5) | 仅改 EXTINF 的实验实际 duration=4s，3.8s 仍输出白帧/PTS 3.791667。**需要样本裁剪或新播放路径**，此快捷做法无效；继续拒绝 |
| gap | P0=[0,4)、空缺=[4,5)、P1=[5,9) | 无补洞/时间映射实验，**无法判断**可用实现；连续 HLS 基线仅 8s 不能充当目标 9s。需保留空缺的时钟/渲染模型，继续拒绝 |
| overlap | P0=[0,4)、P1=[3,7)，[3,4) 重叠 | **无法判断**；需要明确重叠样本归属与原始媒体播放实验，不能简单拼成 8s；继续拒绝 |
| 未知中间时长 | 首段 duration 和下一段 start 均未声明；媒体自然结束为 4s | **无法判断**清单边界权威；末段推导算法不推广到中间段，继续拒绝 |
| 多 BaseURL | period0/、period1/ 两个同长但色块不同的候选 | **无法判断**候选/故障切换实现；需要 URL 选择、粘性凭据及资源身份契约；继续拒绝 |
| 非整数微秒端点 | 8 帧 × 512 / 12288 = 1/3s，即 1000000/3µs | 当前 Int64 微秒节目边界无法精确表达；需有理数时间契约或明确精度政策，继续拒绝，不作四舍五入放行 |

七行均有 `assets/test_media/dash_timeline/{id}.mpd`、原始/明确标注的离线派生媒体、`matrix.json` 预期和 SHA256SUMS。公开负向测试读取这七份真实清单，断言 `container.unsupported`、无媒体子请求、旧会话继续可播。当前错误码仍为通用容器不支持；上表提供诊断维度，不冒充已有七个独立公开错误码。

### 原始时标与可行性实验

自有 FFmpeg 8.0.1 生成的 Period0 是红/绿/蓝/白，Period1 是黄/青/品红/黑，每色一秒；每段四个音频标记依次为 440/880/1320/1760 Hz。`tool/dash_timeline/verify_markers.py` 独立解码媒体字节，八个中点色块 RGB 容差 ≤5，半秒窗口测频误差 ≤4 Hz。ffprobe 的原始视频为 1/12288，首 PTS=0、末 PTS=48640、末 duration=512；AAC 为 1/48000，首 PTS=-1024（priming）、末 PTS=191488、末 duration=512。负 priming 如实保留。

`reference.vtt` 只建立节目时钟/色块/频率标签，**不是字幕呈现验收**。独立 PTO 的离线派生文件只改 tfdt/sidx，测试检查所有其他 box（含 mdat）不变。生产路径没有采用此改写。

macOS 27 (Apple M1) 上的 `probe.swift` 使用 AVPlayerItemVideoOutput 测直接 HLS 候选。基线总长 8s，实测如下；RGB 由解码 buffer 中心读取：

| seek | 显示 PTS | RGB | 预期 |
| --- | --- | --- | --- |
| 0.5 | 0.5 | 254,0,0 | 红 |
| 3.8 | 3.791667 | 255,255,255 | 前段白 |
| 4.0 | 4.0 | 254,255,1 | 后段黄 |
| 4.2 | 4.166667 | 254,255,1 | 后段黄 |
| 7.5 | 7.5 | 0,0,0 | 黑 |

这是**直接 HLS 图像实验**，不是实际 `player.load` DASH 投影图像捕获。probe 静音、无音频 tap，离线 tone 检查不等于公开路径音频同步或物理扬声器验收。尚需将公开播放器的显示帧和输出音频统一采集，测量边界首个新段声音及同步误差；不把 Task 3 全项勾完。

`clip.m3u8` 刻意让声明时长短于样本，是失败假设实验，不作为合规 HLS 产品夹具。HLS 的 EXTINF 应与媒体样本时长对应：[RFC 8216](https://www.rfc-editor.org/rfc/rfc8216)。实验只否定这个快捷方案，不证明任意新路径都不可行。

### 检查与复现

新增 native 正向换算测试已实际 RED（抛 Playback operation failed）；修复后 macOS DASH compiler/loader/sidx 三组 **133/133**、0 skipped，xcresult 身份逐项核对。两份例程 RunnerTests 与 canonical 保持一致，发现总量 iOS 634 / macOS 550 只是静态清单，不是本轮全量执行数。

macOS 公开套件 **2/2**：总长 8s、3.8/4.0/4.2/0.5s seek 后时钟推进/选中音轨、会话身份、取消候选无后续媒体请求、迟到事件隔离，以及七维拒绝保留旧会话。日志存在 foreground warning，测试运行器正常执行并通过；不把它当作前台可见证据。

Python 夹具校验 **4/4**，原始色块/音频参考独立解码通过；example 原生迁移 **4/4**、运行证据工具 **9/9**，新增 Dart 文件分析 0 issues。iOS 27 模拟器公开套件 **2/2**、原生同三组 **133/133**（0 skipped）也已通过，xcresult 身份核对完成。独立只读复核无 Critical / Important / Minor；没有因此扩大能力声明。

复现命令：

```sh
python3 -B -m unittest discover -s tool/dash_timeline -p 'test_*.py'
python3 -B tool/dash_timeline/verify_markers.py
# 实验编译与三个 URL 见 tool/dash_timeline/README.md
cd packages/yl_player/example
flutter test integration_test/apple_dash_timeline_edges_test.dart -d macos
flutter test integration_test/apple_dash_timeline_edges_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
```

本机原始证据仍在 `.superpowers/sdd/2026-09-26-remaining-01-dash/`：`time-red.xcresult`、`time-macos-green.xcresult`、`time-macos-evidence/`、`time-ios-green.xcresult`、`time-ios-evidence/`、`time-public-macos.log`、`time-public-ios.log`、`time-marker-reference.json`、`time-probe-{baseline,independent,clip}.json`。实验工具与媒体哈希已纳入版本管理，夹具测试接入 `tool/check_foundation.sh`，本轮只运行受影响入口，不宣称整个 foundation/release gate 通过。Android 路径未修改，本轮无新增 Android 实播；最低系统、物理设备和定量音画同步留待 P08。

Task 3 收尾：关闭本轮启动的本地 HTTP 服务和 iOS 模拟器；四份 Apple 生成配置恢复 `lib/main.dart`。未 push。Task 3 的剩余架构/同步项及 Task 4 依赖继续保留。

### Task 3 最终源文件 SHA-256

- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashDocument.swift`：`c5a720b4f6cf9faa56b09a82f70f69cdfe7ad0b31a9adc228881a3d62c7df4f7`
- `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashHlsCompilerTests.swift`：`c9c638f532c0ee2f90345210bf47837e6c6540343f8022335692cea7a2fafe7b`
- `tool/consumer_fixtures/apple_flutter/main_example_tests.py`：`3f1765240d8af8527caf799e7e22382f5349779d76e8cd485c445ac973400bcf`
- `packages/yl_player/example/integration_test/support/dash_server.dart`：`f255891762c448169386e6668807ad3c1b850f94488f9e73fb8c86160cba9c0b`
- `packages/yl_player/example/integration_test/apple_dash_timeline_edges_test.dart`：`6f5b2236cf26fc37340c22ff3605dcb457f798eba71cfbf552f9d13377a49bb9`
- `tool/dash_timeline/generate_fixture.py`：`924084ed0627c491e6244da48a4bc4c0d367fd5f26be945524f95aa063299830`
- `tool/dash_timeline/verify_markers.py`：`2555dc9536b5806f23ee85eb8a63439e397daae9fbb0138654e05b2c526d0214`
- `tool/dash_timeline/probe.swift`：`4221c814cfd0ce81d54022638fc101fdc4cea407b8dd26c64c28eb4895001add`
- `tool/dash_timeline/test_fixtures.py`：`8b9f7d34809544711595087de9fb177a06c02b152302df315a4bd0a2b74968cd`
