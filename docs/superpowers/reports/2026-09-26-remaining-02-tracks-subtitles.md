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
