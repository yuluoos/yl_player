# P02 执行记录

## 2026-10-11：内部 SRT/WebVTT 解析与媒体时间查询

基线 `fee2518875bb77ff2b437a989712938709aff939`，当前分支 `codex/fel-integration`。用户要求在其他会话执行长播放复验、弱网 ABR 工具时继续剩余项目。本轮选取 P02 独立解析基础，不占用原生构建、生成入口或播放设备。

交付 `packages/yl_player/lib/src/subtitles/subtitle_document.dart` 和对应测试，接口及限制见[内部解析契约](../specs/2026-10-11-subtitle-parsing-contract.md)。解析结果不可变，保留原始 payload/可选标识；重叠字幕以媒体时钟和正负偏移查询，半开时间区间，关闭/回退 seek 无保留状态。WebVTT position/align 保留，样式区域与 HLS timestamp-map 明确拒绝；没有网络或外部资源访问。单独限制输入、行、cue、文本及重叠数量，错误输出脱敏。

### 实施决定和验收边界

- 沿用总览指定 checkout，仅操作本轮文件。共享目录需要逐文件检查，禁止整仓暂存及改动其他会话文件。
- Task 2 的公共接入依赖尚未冻结的 Task 1。先交付内部 parser/query，不新建公开字幕命令、不更改 Pigeon ordinal，不处理视频是否继续的 PD-03。代价是本项仍不能在实际播放器显示字幕。
- 不以本地 Dart 通过替代原生/画面同步或完整 CAP-SUB。Task 1 多轨身份、字幕公开接口；Task 2 TTML、managed 网络/取消/会话、渲染；Task 3/4 高级格式与 HDR/保护输出均继续开放。

### 验证记录

测试运行目录为 `packages/yl_player`；Flutter `/Users/yy2021_8689/flutter/bin/flutter`，Dart 使用同 SDK 的 `bin/cache/dart-sdk/bin/dart`。

1. `flutter test --no-pub test/subtitle_document_test.dart` 初次执行因 SDK 缓存沙箱权限未启动；授权后实际 RED：缺少待实现库/类型，exit 1。保留 `.superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/red.log`。
2. 实现后定向 **47/47 通过**。继续补充反向 seek/偏移与参考扫描对照、微秒边界、极端输入、行/元数据预算和原子失败测试。
3. `flutter test --no-pub` 整包 **144/144 通过，exit 0**，包含新增测试，日志 `.superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/package-tests.log`。
4. 初次静态检查出现一处 if 括号风格提示，已修正；最终结果及独立复审见下方追加记录。

本轮不运行原生、模拟器、物理设备、长期播放或 UI 截图。输入素材为测试内原创字符串，未取用用户媒体或服务。完整 P02 状态仍为进行中。

### 最终复审与修复后验证

一次独立只读复审发现 Important：NOTE 块未检查箭头，缺少空行的后续字幕被静默吞掉。三个新增用例首先真实失败（空文档和有效前缀均覆盖），随后逐行校验 NOTE，整包最终 **147/147 通过、0 失败**；静态分析 **No issues found**。没有再次原生构建或设备测试。

复审另提一项文档措辞歧义：本契约前句已明确 position/align 之外的 setting 为 unsupported，后句“未知/重复/损坏已支持 setting”指已支持项的非法值；此处明确：未知名称为 unsupported，非法 align/position 值及重复已支持项为 malformed。保留实现，不改变已冻结边界；误读的成本是错误原因预期不同，不影响字幕内容安全。

复审列出的公共身份/命令、网络/取消、TTML/图形字幕、原生渲染、HDR/DRM、PD-03 均按本切片边界继续开放，不能将此次通过外推到这些项。无其他未处理 Important/Critical。

为保持其他会话播放证据的 HEAD 身份，改动保留工作区，不暂存、不提交、不推送。代价是需后续合并提交，已保留源文件指纹和原始验证日志。

[证据清单](evidence/2026-10-11-subtitle-parser/manifest.json)记录源码/测试/契约 SHA-256、命令和原始日志哈希，红灯及最终结果一并保留。下一步仍是 Task 1 的字幕公开命令/身份契约，再接媒体会话和画面；PD-03 仅限制故障恢复决策。

用户随后明确要求 commit 后继续；提交前核对三个源码/契约指纹与四份原始日志一致，147 项与静态分析证据有效。本提交只包含 P02 文件；P04 已独立提交为 b8a83c9。

## 2026-10-11：Task 1A 字幕公开 Dart 契约

解析切片已提交 `a8acb0b`；通用日志忽略规则排除的四份原始证据另补提交 `fd24126`。以 `fd24126` 为本切片起点，沿用当前 checkout；并行会话后续提交的 `a50767b` 和未提交 ABR 改动不属于本项。

### 交付和决定

新增公开 YlExternalSubtitle/YlSubtitleTrack/YlSubtitleState/YlSubtitleFormat，包含请求策略、语言/role/内容身份、VobSub 成对资源和有限目录校验。YlPlayerState 默认关闭字幕，copyWith/equality/hash 包含字幕快照。现有音视频轨道 ordinal 不变；Dart capability 末尾追加三项，可选 SPI 与 capability 双门禁保护旧适配器。

会话增加 replaceExternalSubtitles、selectSubtitleTrack(null 即关闭)、setSubtitleOffset。列表在派发前复制；成功或失败回包后重新检查会话，切源、Stop、Dispose 后不能返回旧会话成功。命令不乐观发布字幕状态，格式身份不构成播放支持声明。详见[公开契约](../specs/2026-09-26-subtitle-contract.md)。

Task 1A 只完成 Dart 合约，native schema/生成文件保持不变，且当前原生适配器不广告三项字幕能力。后续才能落实下载取消、同会话命令顺序、原子替换、实际 cue/画面合成。多音轨真实选择和 PD-03 没有被此契约决定；Task 1 整体与 CAP-SUB 仍开放。

### 失败与回归

- 新合约与会话用例均先实际 RED（缺失 API），随后定向 9/9 和 23/23；再补公开导出和权威状态/失败回滚检查。
- 平台接口首轮130通过/2失败，原因输出为旧 conformance.timeout（原门限80ms）；保持用例/门限不变的串行运行132/132。保留首轮失败，不将其称作确定的根因修复。
- Apple 首轮109通过/3失败，其中两项是旧“全 Dart/native enum 对等”假设，另一项是执行目录不符合 schema 文件相对路径。Android 首轮79通过/2失败，同为枚举预期。
- 兼容测试改为精确原生子集，仅排除三项尚未进入 native 的字幕能力，并新增“原生不广告字幕、状态默认关闭”的断言。从仓库根正确入口执行，Apple113/113、Android82/82；播放器171/171。
- 静态分析最终 No issues found。Pigeon schema/生成物 git diff 为空；为避免共享生成/原生构建冲突，本轮不重生成、不运行原生构建或设备。此项不冒充新的 Pigeon-generation/native gate。

一次独立复审无 Important/Critical。非阻断建议暂缓：session 测试 matcher 检查 code/scope，尚未额外锁定 unsupported category/retryable=false；实现通过既有 _exception 正确返回这两项。后续可补强化断言。

最终集中验收和源码指纹见下方追加记录；初轮失败保留，不以最终成功抹去。下一项为可用适配器的字幕加载/取消与媒体时钟渲染接入，期间继续推进 TTML 和 Task 1 音轨身份。

最终冻结源码的集中命令：从仓库根运行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`，**498/498、0失败、exit 0**。原80ms/30ms测试门限未修改；静态检查无问题。四个包覆盖数为132/171/113/82。[契约证据清单](evidence/2026-10-11-subtitle-contract/manifest.json)保存15份源码/测试/规范指纹与7份原始日志；本切片将独立提交，不包含并行网络工具与example验收改动。
