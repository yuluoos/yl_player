# P01 执行记录：有界 sidx 解析

执行日期：2026-09-27。需求 REQ-02、REQ-13、REG-DIAG；起点 `4d9830ed5e0f52ff736b536af9e40ea710b97408`，分支 `codex/fel-integration`，开始时工作区干净。

## 交付和能力边界

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
