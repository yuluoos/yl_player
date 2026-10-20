# remaining-engineering 合并 main 与统一验证

状态：按用户授权完成本地合并及合并后统一验证；整体工程验收与发布准入仍未通过。没有推送、删除分支或清理 worktree。全部历史未完成项继续保留。

## 合并与现有成果保护

- 原 main：`978c2c5c3872d5570e3bd1a01f1a3d2e80d08f44`，合并前主目录干净。
- 分支：`codex/remaining-engineering`，提交 `11c7f5c357b5b0b46273949f327a4b0f5dae052d`；6 个提交基于上述 main，无并发分歧。
- 合并提交：`b24282a5d5812237b5c15a7f425a0a4ed264b629`，无冲突。合并树 `6e28a6e56b06340ea142fae8f3d1161a57c71d2e` 与分支树完全一致。
- 合并后测试时序修正：`0e0e3066f887deb6037855cfcbdaf26705cec5c8`，只修改 macOS 规范测试及适配后的主例副本，无生产修改。
- 最终生产范围 588 条文件／符号链接清单与分支发布台账完全一致，SHA-256 `69f6e5fc191dc55021a1f96b8a2398f8441eee84deeca9ca57521e1819053b60`。投屏、媒体拆分、P07/P08 现有成果保留；没有恢复旧 framework 布局或更改依赖。
- 历史 remaining-engineering 证据的 229 条 SHA256SUMS 全部核验通过，230 个原证据文件（含校验表）及原报告未改写。先前“尚未合并”的描述保留其历史时点，本报告记录后续合并。

## 本次实际统一验证

环境：Apple M1/arm64，macOS 27.0.1（26A434），Xcode 27.1（27A9275），Flutter 3.44.0、Dart 3.12.0、Python 3.12.14、NumPy 2.3.5。iOS 使用既有 iPhone 18 Pro Max / iOS 27.0 Simulator。两端在主目录使用全新 DerivedData 构建，重负载测试串行执行，没有复用分支 worktree 构建冒充 main 运行。

| 检查 | 本次实际结果 | 范围／限制 |
|---|---|---|
| `sh tool/check_foundation.sh` | 退出 0；Flutter/Dart 2,331 通过；Python 635 项，634 通过、1 跳过 | 显式 `YL_RUN_DECODE_PROBE=1`，实际 HEVC 探针测试执行；唯一 Python 跳过为未启用的可选 CGL GPU 探针 |
| 静态／产物／依赖 | analyze、公开接口、生成代码、投屏独立依赖、来源映射通过；451 个 Dart 文件，0 格式变化 | HEVC 56 项；VP9 218 项；FFmpeg 3 slices / 5 architectures / 57 symbols / 9 个预期拒绝检查通过，lock 不变 |
| macOS 主目录全套 | 构建退出 0；860 项，859 通过、1 失败、0 跳过；测试退出 65，严格门禁退出 1 | 原失败完整保留，不能称首轮全绿 |
| macOS 修复后定向验证 | 重建退出 0；EOF 实际播放／重播组 6/6，受影响两条路径另两轮各 2/2；运行身份门禁均退出 0 | 最终 860 个规范身份均有通过证据，依据是本轮全套加修复后回归，不是一次最终全套全绿 |
| iOS 主目录全套 | 构建退出 0；813 项，779 通过、33 失败、1 跳过；测试退出 65，严格门禁退出 1 | 33 项失败身份与分支记录逐项相同，无新增失败；仍是未通过的验收结果 |
| 跳过／来源补验 | 唯一 R19 的身份、原原因、Simulator 平台、实际 H264 不可用附件完全匹配；migration、runtime evidence、当前映射、parity 通过 | 未扩大跳过条件；实际执行数与源码方法数 iOS819/macOS866 分开记录 |
| 发布／阈值 | 两个结构检查退出 0；两个 `--require-ready` 均退出 1 | 有效台账不等于发布就绪 |
| 独立复审 | 合并复审无问题；测试修正定向复审发现 1 项遗漏，修复并复核关闭，最终 Critical0/Important0/Minor0 | 静态复审不代替运行证据 |

基础完整矩阵绑定合并提交。随后只改 macOS 测试的两个等待谓词，生产源码、Dart/Python、接口、依赖、其他测试及 iOS 源码不变，因此沿用其本轮结果；变更的 macOS 测试重新构建并运行。构建警告与 XCTest QoS/main-thread 运行警告保留，没有据此宣称性能准入。

## macOS 全套发现与修正

唯一失败为 `YlMacosAudioTests/testActualDecodedLegacyEOFSuspendResumeDoesNotAutoplay()`：内部状态已完成，但异步公开状态尚未交付，立即断言完成通知次数出现 `0 != 1`；同次运行后续次数断言为 1，均通过。生产 `send → outbound.enqueue → MainActor Task` 明确异步交付，测试此前只等待内部 `.completed`。

在原 10 秒窗口内同时等待内部及公开完成，保留后续精确次数等于 1 的断言。定向复审发现同 helper 重播 EOF 也有同样遗漏，补充等待 `completions() >= 2`，后续精确等于 2 的断言保留。没有增加固定 sleep、延长超时、换成 mock、扩大 skip 或更改生产回调。资源归零、迟到回调隔离、前后台不自动播放、重播与帧断言全部保留。规范源经媒体拆分 adapter 同步到主例副本，来源校验通过。

首轮完整失败、原断言位置、实际活动与附件，以及三轮修正后结果共同归档。原失败没有被后续通过覆盖。

## 保留的全部未完成项

以原[工程报告](2026-10-20-remaining-engineering.md)和[完整发布台账](../../../tool/release_readiness/inventory.json)为持续清单；本次未提高任何能力的验收状态。102 行仍为 67 implemented、34 partial、1 unreviewed；验证仍为 30 external_missing、3 failed、69 not_run、0 passed。本次 evidence 的 `release.json` 保存所有逐项 blocker 和 nextAction，`thresholds.json` 保存全部阈值缺口。

- **iOS 原生验收**：保留全部 33 个失败身份与详情。R19 和 FLV 附件实际记录 H264 硬件不可用；有些错误明确为 decoder.unavailable，有些只显示泛化错误，不能把全部私有根因视为已查明。需有正向硬件证据的 iOS 设备逐项复验。
- **P08**：历史 119.084ms 原生 ready 等待根因、系统内部资源 A5 上界、完整平台性能准入仍开放。候选默认关闭；本轮 Debug 功能测试不能替代 Profile 长播／性能资格。
- **P04**：实际 AVPlayer 自动恢复升档尚未通过，保留正式诊断的未升档结果；不能用手动强制切档替代自动恢复。
- **P07**：完整有效 DM/trim 继承及适用 CM/NLQ 映射、真实 use_previous 素材、独立目标与帧生成对应／容差、物理 DV 输出链路仍开放。已有原始 FEL 和逐帧关联证据保持有效，不重复要求已有素材。
- **其他既有发布缺口**：真机、最低 OS、低内存、32 位、Intel 等平台矩阵，商业 DRM 授权链路、外接输出和源绑定远程 CI。未新增这些环境的通过证明；本机检查不覆盖它们。

## 证据与恢复

[本轮证据目录](evidence/2026-10-20-remaining-main-merge/README.md)保存命令、环境、预检、全套与定向运行身份、实际失败和跳过、能力与资源附件、源码保护核对、独立复审、发布缺口、原始／脱敏／压缩哈希。

本轮原始 xcresult 与 DerivedData 留在 `/private/tmp/yl-remaining-main-merge-qiu5k5ok`，版本化日志与附件不依赖该临时目录长期存在。`codex/remaining-engineering` 和对应 managed worktree 继续保留，未推送远端。
