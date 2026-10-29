# P07 CM4 原始输入与长形式对照本地合并和清理（2026-10-29）

按用户授权，将实现提交 `73aab34259965686f7d26489286ecc3f6648d984` 从 `dde14f64ec54758aacf01cb661e33d6eeee93bad` 快进合并到本地 main，无冲突。本记录作为随后文档提交，不追加实现。

## 合并验证

| 检查 | 结果 |
| --- | --- |
| 合并前身份 | 两边工作区干净，80 个候选文件、43 个原始证据文件哈希匹配 |
| main P07 全套 | 120 项：119 通过、1 项既有 CGL 未启用跳过；宿主解码/P8/短长CM4/NumPy 2.3.5 已启用 |
| main 台账测试 | 15 项通过 |
| 发布/性能门禁 | 结构各退出 0；require-ready 各退出 1，完整资格仍未就绪 |
| 影响范围 | 播放器、依赖和 CI 相对基线空 diff；合并树等于实现树 |

同源码身份绑定的默认/研究 Rust 各 7 项、12帧长形式独立 FFmpeg 精确字段对照、六类原始 RPU 负例及独立复审按集中验收规则复用。复审无可操作发现，未扩大为任意规范输入或设备资格。

## 清理结果

已确认本轮分支完全包含于 main，解除本聊天工作树的分支关联并删除 `codex/p07-cm4-wire-contracts`。本聊天工作树 `/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player` 保持干净、detached 于实现提交。

应用 archive_worktree 拒绝删除该目录，返回 `The task's primary checkout cannot be removed.`。因此工作树目录尚未清除；没有用 shell 删除绕过主工作区保护。清理仅涉及本轮分支，不删除其他分支/工作树，也不清理保留证据所需的源素材和研究构建。

## 保留验收和未完成项

[实现及集中验收记录](2026-10-29-p07-cm4-wire-contracts.md)、原始失败/RED/GREEN、六类小型原始 RPU、trace、工具身份和复审全部保留。其“未提交/合并”是当时快照，当前状态以本合并记录为准。

真实压缩/use_previous 片源、任意畸形语法/版本、跨 ID/缺头/默认 DM、未知 level、完整 CM/trim/NLQ/重采样/目标映射、独立 FEL 目标及冻结容差、物理 DV 继续开放。本轮仅验证内存 trace sink 的失败无输出，没有新增 CLI 输出文件发布路径验收。默认固定解析器与显式研究补丁边界保持；effective_metadata_resolved=false，CAP-DV-MAP/OUT 不提升。

P02/P03/P05 的设备、最低 OS、硬件、热稳态、业务来源，P06 DRM 授权，P08 READY 同次因果链和系统 A5 上界均保留。另一聊天的 iOS 恢复源码、工作树、分支、设备及进程未操作。

台账仅追加本报告引用，102 行 implementation/verification/acceptance/nextAction 不变，生产源哈希仍为 `b4651f1fd23bf40cbc2384b2a0f39c0f0f90b0f736ca918b71aa25a895972eb5`。未推送、未发布。

[合并与清理证据](evidence/2026-10-29-p07-cm4-wire-main-merge/)。
