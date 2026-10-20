# 已合并工程分支归档清理

在 main 合并提交 `0b00db46` 上执行，仅清理用户指定的两个本地分支；未改动生产源码、测试或既有验证记录，未推送或删除远端分支。

| 分支 | 已合入的 tip | 清理结果 |
|---|---|---|
| `codex/p03-engineering-completion` | `3c7d8755` | 干净 worktree 已移除，分支使用 `git branch -d` 删除 |
| `codex/p04-engineering` | `98153c37` | worktree 原已归档，本次删除剩余已合并分支，保留应用归档 |

两条分支均在删除前确认是 main 的祖先，Git bundle 创建后通过 verify 和 tip 校验。私有归档分别位于 `.git/codex-archives/p03-engineering-completion-20261020` 和 `.git/codex-archives/p04-engineering-20261020`，附恢复说明与 SHA-256 清单。bundle 所需基线均保留在 main 历史中。

P03 worktree 属于另一聊天，应用工具拒绝接管，因此使用仓库私有归档。其跟踪文件没有未提交改动、没有未跟踪非忽略文件；19 个忽略本地设置单独归档并逐字节校验，635 个可重建缓存文件随 worktree 清理。忽略文件中无额外验证日志。P04 的现有 archived_worktree 附件仍可供恢复。

[P03 合并验证报告](2026-10-20-p03-main-merge.md)、[P04 合并验证报告](2026-10-20-p04-weak-network-merge.md)及其原始证据保持不变；已有证据校验清单已复核。此轮仅归档清理，不重复运行未改变源码的测试。`codex/p02-tracks-subtitles` 及其 worktree 未动。

[清理收据](evidence/2026-10-20-merged-branch-cleanup/cleanup.json)记录提交、归档校验值及实际删除结果。
