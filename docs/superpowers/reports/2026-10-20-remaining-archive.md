# remaining-engineering 已合并分支归档清理

按用户授权，基于 main `483acae66764100a9aaee138731a1ecad30f0cd1` 清理已合并分支及对应 worktree。此次只新增归档记录，没有修改生产代码或测试，也没有操作远端。

- `codex/remaining-engineering` 原分支头 `11c7f5c357b5b0b46273949f327a4b0f5dae052d` 已完整进入 main，归档后仍可从 main 历史到达。
- Codex 已将 `/Users/yy2021_8689/.codex/worktrees/remaining-engineering/yl_player` 标记为 `archived_worktree`，可通过应用恢复。活动 worktree 注册与目录已移除。
- 已用 `git branch -d codex/remaining-engineering` 安全删除本地分支。其他 worktree 未操作。
- 归档前，将被忽略的 25 份研究日志、进度与复审文件（127,125 字节）复制到主目录 `.superpowers/sdd/2026-10-20-remaining-engineering-archived-worktree/`。归档前后逐项 SHA-256 一致；保留原始字节，继续忽略，不加入 Git。其余被忽略内容为可重建的构建、依赖、生成注册及本地环境缓存。
- 原工程 229 条与合并验证 183 条证据哈希全部核验一致；原报告、发布台账和未完成项保持原样。

[工程报告](2026-10-20-remaining-engineering.md)及[main 统一验证记录](2026-10-20-remaining-main-merge.md)继续作为实际验收依据：macOS 全套加修复后回归累计覆盖 860 个通过身份；iOS 779 通过、33 项既有失败、1 跳过。归档没有把这些失败改成通过，整体发布仍未通过。

P04 自动恢复升档、P07 完整有效映射／独立参考及物理 DV 链路、P08 历史 ready 等待根因／系统资源 A5 上界及完整性能准入，以及真机、最低 OS、DRM、外接与远程 CI 等既有缺口全部保留。完整逐项清单仍在发布台账和合并证据中。

恢复时可使用应用归档身份，或从原分支头重新创建分支。研究日志已移至主目录，历史日志中的旧 worktree 路径保留其来源语义；不要改写历史收据。本次未重复运行功能测试，因为代码与测试内容均未改变。

[归档收据](evidence/2026-10-20-remaining-archive/archive.json)记录应用附件身份、25 份文件哈希、分支删除及归档后核对结果。
