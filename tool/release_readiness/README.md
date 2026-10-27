# Release readiness inventory

P08-D 的离线汇总入口。当前需求基线的全部 33 个 CAP/ERR/REG 组分别登记
Android、iOS、macOS，共99行；另有性能目标、消费者、远程CI三个必要门槛。
这是组级索引，具体格式/脚本/链路子行仍由 P01–P07 报告维护。它不会执行构建、
联网、播放、设备发现、模拟器、GPU或性能采样。

```sh
# 0 = 台账结构/证据有效；输出仍可能 releaseReady=false。
python3 -B tool/release_readiness/check.py
# 0 = 所有组的完整验收声明有效且源码匹配；1 = 仍有缺口；2 = 输入/证据无效。
python3 -B tool/release_readiness/check.py --require-ready
# 测试已进入 check_foundation.sh 的既有 playback_benchmark 发现入口。
python3 -B -m unittest discover -s tool/playback_benchmark -p test_release_readiness.py
```

`inventory.json`记录审核基线commit、需求文档hash、源码/制品文件清单、报告hash、
各组独立的implementation和verification及下一步动作。报告存在、编译成功、
历史单项通过、模拟器成功均不能自动把整组改为passed。当前所有完整组仍开放；
历史通过留在报告，`not_run`意为**尚未完成当前整组共同验收**，不抹去已执行子项。
`failed`保留已知必需项失败，具体组及最新后续动作以台账为准；`external_missing`
列授权/原始参考/物理链/最低OS/Intel/正式性能目标等缺项。具体问题见对应报告。
实现状态implemented也不意味着性能或设备验证完成。

源码范围：Git可见的`packages/`全部文件（排除名为`example`、`test`、`tests`、
`Tests`的目录）及根`pubspec.yaml`/`pubspec.lock`，包含原生制品和各包依赖声明、
未忽略的新增文件及删除。版本化framework链接同时绑定链接文本与范围内目标文件；
越界/缺失目标拒绝。源码hash为按键排序、紧凑ASCII JSON文件hash表的SHA-256。
文档/测试或单纯HEAD变化不使未改产品源码失效；产品源码、依赖或制品变化则令
`sourceMatches=false`、`currentPasses=0`并阻止ready，保留原验证状态和历史证据。
此范围不宣称覆盖外部TVS checkout、已忽略的构建输出、机器环境或远程服务；
实际消费者/CI验收必须绑定它们使用的具体制品和运行条件。

需求表新增、重复、遗漏、平台错配、未知状态、证据修改/缺失、重复JSON键、非有限数、
超限JSON及路径越界均被拒绝。证据引用使用仓库内相对普通文件，不跟随符号链接。
失败CLI只输出固定提示，不回显载荷、路径或异常。默认JSON上限1MiB；证据/单源码
16MiB，源码累计256MiB；路径数/条目数均有界。大原始日志应使用分片及可审核清单，
不能把超限报错当验收失败或自动删去证据。

## 完整验收声明

历史报告的kind为`report`，不能直接成为通过凭据。将某组改为passed之前，必须
完成该组全部适用子行的人工证据复核，implementation=implemented，并增加
kind=`acceptance`的独立JSON，row.acceptance必须引用它。格式如下（这里是结构说明，
不是现有验收证据）：

```json
{
  "schemaVersion": 1,
  "requirement": "CAP-DASH",
  "platform": "macos",
  "sourceHash": "<当前已验证源码清单的SHA-256>",
  "requirementsHash": "<已验收需求文档的SHA-256>",
  "coverage": "full",
  "outcome": "passed",
  "checks": [{"id": "<已完整复核的子项ID>", "outcome": "passed"}],
  "artifacts": [{"path": "<仓库内证据文件>", "sha256": "<该文件SHA-256>"}]
}
```

检查器要求身份、完整覆盖声明、冻结sourceHash及requirementsHash一致，非空/不重复checks全为passed，
每份artifact存在且hash相符。失败/跳过/部分范围不得写成完整声明。门槛行用对应
PERF-BASELINE / RELEASE-CONSUMERS / RELEASE-CI及platform=all。
这是**经人工审阅的验收声明校验器**，不理解每种原始日志、不能证明声明真实，也不
自行证明画质、授权、物理输出或性能数字。`releaseReady`仅表示所登记完整声明在此
源码范围内齐备；发布、标签、上传仍需明确发布指令。仓库当前没有任何完整声明。

维护时先复核变化和影响范围，再更新源清单/报告hash及必要行；不要自动将新源码
或新报告重新盖章为通过。重新计算source_snapshot可用于生成待审核清单；更新后
旧sourceHash或requirementsHash验收声明必须重新验证，不能只改它的hash。性能门槛只有按需求第7节
取得合格基线并在优化前冻结版本化目标才可通过。现有公开首帧事件smoke、暂停回读
和历史有限长播均不能伪造成这一完整门槛；本轮没有创建虚构thresholds.json数字。

当前产品决定以需求v2.2为准：PD-01、PD-02、PD-03均已确认。历史P08计划中的
“PD-02/03尚未确认”不是当前阻塞；具体DRM/Dolby/设备/参考缺口仍需独立解决。

## P08 combined engineering and readiness entry

`YL_FLUTTER=/path/to/flutter sh tool/check_p08.sh --validate` runs all benchmark
Python tests, all example Dart unit tests, the threshold registry and the current
release inventory. A successful diagnostic run explicitly does not admit a
release. `sh tool/check_p08.sh --require-ready` requires both the source-bound
performance registry and the full CAP/ERR/REG/consumer/CI inventory. Missing
qualified baselines exit 1; malformed evidence exits 2. Neither command publishes.
